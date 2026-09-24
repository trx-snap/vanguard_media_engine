package com.connects.vanguard_media_engine.greenscreen

import android.graphics.Bitmap
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Surface
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

// -----------------------------------------------------------------------------
// Independent single-camera/single-output render loop for the GreenScreen
// preview capability.
// -----------------------------------------------------------------------------
//
// Replaces AndroidDuetPreviewRenderLoop for GreenScreen, which previously ran
// that loop with `decoderProvider = { null }` — no decoder was ever bound, so
// every decoder-op/active-ticking code path in the Duet loop was dead weight
// for this capability. This loop has no decoderHandler, no decoderProvider,
// no source-video clock, no Duet layout modes, and no Duet session
// assumptions: it only pumps a ~30fps camera-idle redraw once an output
// surface is attached, exactly matching the observable cadence GreenScreen
// already relied on via the Duet loop's camera-idle-redraw pump (GreenScreen
// never calls startActive(), so that pump was always the sole frame source).
//
// Owns exactly one thing: the "vg.greenscreen.render" HandlerThread plus the
// AndroidGreenScreenPreviewBackend confined to it (built by [backendFactory];
// AndroidGreenScreenPreviewCompositor by default). It is a pure pump
// between two loopers it does not own:
//   - mainHandler:   the ONLY place [cameraInputSurfaceReady] is invoked, so
//                    the coordinator can start Camera2 (which requires the
//                    main thread) without racing the render thread's async
//                    EGL bootstrap.
//   - render thread: the ONLY place compositor methods run (attach/detach,
//                    setLayout, drawFrame, release).
//
// Output-loss discipline: [handleOutputSurfaceLost] flips the no-submit flag
// and bumps the surface generation synchronously on the calling thread, so
// swap acceptance is blocked immediately; the EGL-side detach then happens
// asynchronously on the render thread.
//
// Backend selection: [backendFactory] builds the primary backend; when its
// very first attach fails because its bootstrap never produced a camera
// input surface (e.g. the GPU-resident backend's EGL/ES 3.1/TFLite bootstrap
// or model validation) and a [fallbackBackendFactory] is supplied, the
// primary is released and the fallback takes over on the render thread
// BEFORE [cameraInputSurfaceReady] ever fires, so the camera is only ever
// bound to the backend that actually survived bootstrap. State delivered
// before that swap (enabled flag, background, camera transform) is replayed
// onto the fallback. A failed attach whose bootstrap DID produce a camera
// surface (transient window-surface failure) keeps the primary for the next
// attach, and a later re-attach failure never swaps backends.

class AndroidGreenScreenPreviewRenderLoop(
    private val mainHandler: Handler,
    /**
     * Optional callback invoked on the main thread each time [attachOutputSurface]
     * succeeds and [compositor.cameraInputSurface] is non-null. The surface passed
     * is compositor-owned (valid for the lifetime of this render loop). The
     * coordinator uses this to start the camera source reliably without relying
     * on an immediate post-attach synchronous read of [cameraInputSurface] (which
     * would race the async render-thread bootstrap).
     *
     * Fired on every successful [attachOutputSurface] where cameraInputSurface is
     * non-null (not just the first) — the coordinator's camera-start is expected
     * to be idempotent, so repeat calls are harmless. Firing on re-attach also
     * gives retry when a prior transient camera failure nulled the camera source.
     * Never called if the compositor bootstrap fails.
     */
    private val cameraInputSurfaceReady: ((Surface) -> Unit)? = null,
    /**
     * Builds the render-thread-confined preview backend. Invoked once, on the
     * constructing thread; the product must defer every GL/EGL/model step to
     * its own [AndroidGreenScreenPreviewBackend.attachOutputSurface].
     * Default preserves the historical hardcoded CPU-mask compositor.
     */
    backendFactory: () -> AndroidGreenScreenPreviewBackend = { AndroidGreenScreenPreviewCompositor() },
    /**
     * Optional backend used when the primary backend's FIRST attach fails.
     * Invoked on the render thread at most once. Null = no fallback (attach
     * failure leaves the loop idle exactly as before this seam existed).
     */
    private val fallbackBackendFactory: (() -> AndroidGreenScreenPreviewBackend)? = null,
) {

    companion object {
        private const val TAG = "GreenScreenPreviewRenderLoop"

        /** Camera idle redraw cadence (~30 fps) — the sole frame source for this loop. */
        private const val CAMERA_REDRAW_MS = 33L

        /** JPEG quality for a still photo of the composited preview (VG-LIVE-GREENSCREEN-PHOTO). */
        private const val PHOTO_JPEG_QUALITY = 92

        /** Per-photo worker thread name for row-flip + JPEG encode (never the render thread). */
        private const val PHOTO_ENCODE_THREAD_NAME = "vg.greenscreen.photo"
    }

    /** Committed still photo of the composited preview: the JPEG file and its pixel size. */
    class CompositePhotoOutcome(
        val file: File,
        val widthPx: Int,
        val heightPx: Int,
        val fileSizeBytes: Long,
    )

    // -- Owned render thread + compositor (render-thread-confined) -------------

    private val renderThread = HandlerThread("vg.greenscreen.render").apply { start() }
    private val renderHandler = Handler(renderThread.looper)

    /**
     * Render-thread-only; every touch happens via [renderHandler]. Volatile
     * only so the main-thread [cameraInputSurface] read observes a fallback
     * swap (which always precedes the first [cameraInputSurfaceReady] post).
     */
    @Volatile
    private var compositor: AndroidGreenScreenPreviewBackend = backendFactory()

    /**
     * True once the primary backend was replaced by [fallbackBackendFactory]'s
     * product. Set on the render thread before [cameraInputSurfaceReady] fires,
     * so the coordinator can read it from that callback to pick the matching
     * camera-source configuration.
     */
    @Volatile
    var usingFallbackBackend: Boolean = false
        private set

    /** Render-thread-only: fallback is allowed only before the first successful attach. */
    private var hasAttachedOnce = false

    // Latest backend state received before/around attach, replayed onto a
    // fallback backend so it starts from the same configuration the primary
    // would have had. Render-thread-only.
    private var latestGreenScreenEnabled: Boolean? = null
    private var latestBackground: AndroidGreenScreenBackground? = null
    private var latestCameraTransform: Pair<Int, Boolean>? = null

    /**
     * The compositor's camera input surface — allocated inside [compositor]
     * during the first [attachOutputSurface] call.
     *
     * Prefer using the [cameraInputSurfaceReady] constructor callback rather
     * than polling this property, because the compositor bootstraps EGL
     * asynchronously on the render thread. The property returns null until
     * the first render-thread task for [attachOutputSurface] completes.
     * The callback is the only guaranteed delivery point.
     */
    val cameraInputSurface: Surface? get() = compositor.cameraInputSurface

    // -- Submission gating ------------------------------------------------------

    /**
     * Bumped synchronously on every attach, output loss and stop. Present
     * tasks capture the generation of the request that produced them and are
     * dropped on mismatch, so a stale render-thread task never swaps after a
     * newer attach/loss/stop superseded it.
     */
    private val surfaceGeneration = AtomicInteger(0)

    /** True only between a successful attach and the next loss/stop. */
    private val canSubmit = AtomicBoolean(false)

    private val isStopped = AtomicBoolean(false)

    // -- Public API -------------------------------------------------------------

    /**
     * Attaches the borrowed output [surface] to the compositor and applies the
     * layout. Asynchronous; safe from any thread.
     */
    fun attachOutputSurface(
        surface: Surface,
        widthPx: Int,
        heightPx: Int,
        sourceRect: AndroidGreenScreenPixelRect,
        cameraRect: AndroidGreenScreenPixelRect,
    ) {
        if (isStopped.get()) return
        val generation = surfaceGeneration.incrementAndGet()
        renderHandler.post {
            if (isStopped.get()) return@post
            // A newer attach/loss superseded this one before it ran.
            if (generation != surfaceGeneration.get()) return@post
            if (!attachWithFallback(surface, widthPx, heightPx)) return@post
            hasAttachedOnce = true
            compositor.setLayout(sourceRect, cameraRect)
            canSubmit.set(true)
            // Ensure the redraw pump is running so camera frames are presented
            // as soon as they arrive.
            startRedrawPump()
            // Notify the coordinator that cameraInputSurface is ready. The
            // compositor allocates the camera SurfaceTexture/Surface
            // synchronously on this render thread inside attachOutputSurface;
            // we must post back to mainHandler so the coordinator can start
            // the camera (which requires the main thread).
            val camSurface = compositor.cameraInputSurface
            if (camSurface != null) {
                val cb = cameraInputSurfaceReady
                if (cb != null) {
                    mainHandler.post { cb(camSurface) }
                }
            }
        }
    }

    /**
     * Render-thread only. Attaches on the current backend; when that is the
     * primary's first-ever attach, it fails, and the primary's bootstrap left
     * no camera input surface behind (core failure, not a transient window
     * failure), releases the primary, swaps in the fallback (replaying the
     * latest enabled/background/transform state) and retries once. Returns
     * the final attach result.
     */
    private fun attachWithFallback(surface: Surface, widthPx: Int, heightPx: Int): Boolean {
        val primary = compositor
        if (primary.attachOutputSurface(surface, widthPx, heightPx)) return true
        if (hasAttachedOnce || usingFallbackBackend) return false
        // Bootstrap survived (camera surface exists): only the window attach
        // failed, which the next attach may recover on this same backend.
        if (primary.cameraInputSurface != null) return false
        val factory = fallbackBackendFactory ?: return false

        Log.w(
            TAG,
            "ANDROID_GREENSCREEN_GPU_RESIDENT_FALLBACK primary=${primary.javaClass.simpleName} " +
                "reason=first_attach_bootstrap_failed -> fallback backend",
        )
        try { primary.release() } catch (t: Throwable) {
            Log.w(TAG, "primary backend release after failed attach threw: ${t.message}")
        }
        val fallback = try {
            factory()
        } catch (t: Throwable) {
            Log.w(TAG, "fallback backend factory threw: ${t.message}")
            return false
        }
        compositor = fallback
        usingFallbackBackend = true
        latestGreenScreenEnabled?.let { fallback.setGreenScreenEnabled(it) }
        latestBackground?.let { fallback.setGreenScreenBackground(it) }
        latestCameraTransform?.let { (rotation, mirror) -> fallback.setCameraFrameTransform(rotation, mirror) }
        val attached = fallback.attachOutputSurface(surface, widthPx, heightPx)
        Log.i(
            TAG,
            "ANDROID_GREENSCREEN_GPU_RESIDENT_FALLBACK_RESULT backend=${fallback.javaClass.simpleName} attached=$attached",
        )
        return attached
    }

    /**
     * Output loss (e.g. Flutter surface cleanup). Blocks nothing: flips the
     * no-submit flag and generation immediately on the calling thread so no
     * in-flight work can swap into the dying surface, then detaches the EGL
     * window surface asynchronously on the render thread. The camera stays
     * bound to the compositor's (surviving) input surface.
     */
    fun handleOutputSurfaceLost() {
        surfaceGeneration.incrementAndGet()
        canSubmit.set(false)
        if (isStopped.get()) return
        renderHandler.post { compositor.detachOutputSurface() }
    }

    /**
     * Applies new layout rects and redraws immediately with the currently
     * latched frame.
     */
    fun updateLayout(sourceRect: AndroidGreenScreenPixelRect, cameraRect: AndroidGreenScreenPixelRect) {
        if (isStopped.get()) return
        val generation = surfaceGeneration.get()
        renderHandler.post {
            if (isStopped.get()) return@post
            compositor.setLayout(sourceRect, cameraRect)
            if (generation == surfaceGeneration.get() && canSubmit.get()) {
                compositor.drawFrame()
            }
        }
    }

    /**
     * Enables or disables green-screen compositing in the compositor. Posts to
     * the render thread so the compositor's render-thread-only state is always
     * mutated on the correct thread. No ML inside the loop.
     */
    fun setGreenScreenEnabled(enabled: Boolean) {
        if (isStopped.get()) return
        renderHandler.post {
            if (isStopped.get()) return@post
            latestGreenScreenEnabled = enabled
            compositor.setGreenScreenEnabled(enabled)
        }
    }

    /**
     * Forwards the live camera feed's normalized display rotation and mirror
     * state to the compositor. Posts to the render thread, mirroring
     * [setGreenScreenEnabled]'s posting style. This is backend-parity
     * plumbing only: the current GLES compositor's [AndroidGreenScreenPreviewBackend.setCameraFrameTransform]
     * implementation no-ops, matching the proven Duet GLES route where the
     * camera SurfaceTexture's own transform matrix already delivers a
     * display-correct camera feed.
     */
    fun setCameraFrameTransform(rotationDegrees: Int, mirrorHorizontal: Boolean) {
        if (isStopped.get()) return
        renderHandler.post {
            if (isStopped.get()) return@post
            latestCameraTransform = rotationDegrees to mirrorHorizontal
            compositor.setCameraFrameTransform(rotationDegrees, mirrorHorizontal)
        }
    }

    /**
     * Delivers a new CPU segmentation mask to the compositor for the next draw.
     * Posts to the render thread; the compositor's AtomicReference absorbs
     * any thread-safety concern between this post and the next drawFrame.
     * No ML runs inside the render loop itself; a self-contained backend
     * (AndroidGreenScreenGpuResidentPreviewBackend) ignores these frames.
     */
    fun updateGreenScreenMask(frame: AndroidGreenScreenSegmentationFrame) {
        if (isStopped.get()) return
        renderHandler.post {
            if (isStopped.get()) return@post
            compositor.updateGreenScreenMask(frame)
        }
    }

    /** Forwards a new green-screen background spec to the compositor. */
    fun setGreenScreenBackground(background: AndroidGreenScreenBackground) {
        if (isStopped.get()) return
        renderHandler.post {
            if (isStopped.get()) return@post
            latestBackground = background
            compositor.setGreenScreenBackground(background)
        }
    }

    // -- Live recording encoder surface (render-thread seam) --------------------

    /**
     * Attaches [target] (a live recording's encoder input surface) to the
     * backend on the render thread. [onResult] lands on [mainHandler] with
     * true once the backend accepted the surface — from that point every new
     * camera frame the preview latches is also composited into it — or false
     * when the loop is stopped, the render looper is gone, or the backend
     * rejected / failed EGL setup (nothing attached). Safe from any thread.
     */
    fun attachSegmentRecorder(
        target: AndroidGreenScreenSegmentRecorderSurfaceTarget,
        onResult: (Boolean) -> Unit,
    ) {
        if (isStopped.get()) {
            mainHandler.post { onResult(false) }
            return
        }
        val posted = renderHandler.post {
            val ok = if (isStopped.get()) {
                false
            } else {
                try {
                    compositor.setSegmentRecorderTarget(target)
                } catch (t: Throwable) {
                    Log.w(TAG, "setSegmentRecorderTarget threw: ${t.message}")
                    false
                }
            }
            mainHandler.post { onResult(ok) }
        }
        if (!posted) {
            mainHandler.post { onResult(false) }
        }
    }

    /**
     * Detaches the attached recorder surface (if any) on the render thread;
     * the backend destroys only its EGL wrapper, never the recorder-owned
     * Surface. [onDetached] lands on [mainHandler] once no render-thread work
     * can touch the encoder surface any more, so the caller may then
     * finish/release the recorder. After [stopBlocking] the backend's release
     * has already dropped the surface, so the callback fires immediately.
     * Idempotent; safe from any thread.
     */
    fun detachSegmentRecorder(onDetached: (() -> Unit)? = null) {
        val done = {
            if (onDetached != null) mainHandler.post { onDetached() }
        }
        if (isStopped.get()) {
            done()
            return
        }
        val posted = renderHandler.post {
            if (!isStopped.get()) {
                try {
                    compositor.setSegmentRecorderTarget(null)
                } catch (t: Throwable) {
                    Log.w(TAG, "setSegmentRecorderTarget(null) threw: ${t.message}")
                }
            }
            done()
        }
        if (!posted) done()
    }

    // -- Still photo of the composited preview (VG-LIVE-GREENSCREEN-PHOTO) ----

    /**
     * Captures the composited preview exactly as it is presented now and
     * commits it as a JPEG at [outputFile]. [onResult] lands on [mainHandler]
     * exactly once with the committed file, or with a failure whose message
     * is a diagnostic token; on failure no file is left at [outputFile].
     * Safe from any thread.
     *
     * Mechanism: on the render thread a one-shot read-back is armed on the
     * backend ([AndroidGreenScreenPreviewBackend.setCompositeCaptureRequest])
     * and one [AndroidGreenScreenPreviewBackend.drawFrame] is issued
     * immediately (the same pattern [updateLayout] uses), which re-composites
     * the currently latched camera frame, mask and background -- exactly what
     * the texture shows -- reads the composite back before its swap, and
     * presents it again. The backend resolves the request before that draw
     * returns; a draw that never reached its composite (output lost, backend
     * released) is failed here instead of leaving the request armed for a
     * later, unrelated frame. Only the pixel read happens on the render
     * thread: row-flipping, JPEG encoding and file I/O run on a per-photo
     * worker thread, so preview pacing and an active recording are never
     * blocked on encoding. The recorder's encoder pass is gated on a newly
     * latched camera frame, so this extra draw never duplicates a recorded
     * frame.
     */
    fun captureCompositePhoto(
        outputFile: File,
        onResult: (Result<CompositePhotoOutcome>) -> Unit,
    ) {
        val deliver: (Result<CompositePhotoOutcome>) -> Unit = { result ->
            mainHandler.post { onResult(result) }
        }
        if (isStopped.get()) {
            deliver(Result.failure(IllegalStateException("render_loop_stopped")))
            return
        }
        val generation = surfaceGeneration.get()
        val posted = renderHandler.post {
            if (isStopped.get()) {
                deliver(Result.failure(IllegalStateException("render_loop_stopped")))
                return@post
            }
            // A loss/stop/re-attach since the request means the frame the
            // caller saw is gone (or nothing is being presented at all).
            if (generation != surfaceGeneration.get() || !canSubmit.get()) {
                deliver(Result.failure(IllegalStateException("output_surface_unavailable")))
                return@post
            }
            val request = object : AndroidGreenScreenCompositeCaptureRequest {
                var resolved = false

                override fun onCaptured(rgbaBottomUp: ByteBuffer, widthPx: Int, heightPx: Int) {
                    resolved = true
                    encodeCompositePhotoAsync(rgbaBottomUp, widthPx, heightPx, outputFile, deliver)
                }

                override fun onFailed(reason: String) {
                    resolved = true
                    deliver(Result.failure(IllegalStateException(reason)))
                }
            }
            val armed = try {
                compositor.setCompositeCaptureRequest(request)
            } catch (t: Throwable) {
                Log.w(TAG, "setCompositeCaptureRequest threw: ${t.message}")
                false
            }
            if (!armed) {
                deliver(Result.failure(IllegalStateException("backend_rejected_capture")))
                return@post
            }
            try {
                compositor.drawFrame()
            } catch (t: Throwable) {
                Log.w(TAG, "drawFrame for composite photo threw: ${t.message}")
            }
            if (!request.resolved) {
                // The draw returned before compositing (no window surface /
                // released): disarm so no later frame resolves this request.
                try { compositor.setCompositeCaptureRequest(null) } catch (_: Throwable) {}
                deliver(Result.failure(IllegalStateException("frame_not_composited")))
            }
        }
        if (!posted) {
            deliver(Result.failure(IllegalStateException("render_thread_unavailable")))
        }
    }

    /**
     * Hands the raw read-back to a per-photo worker thread for row-flip +
     * JPEG encode + commit, delivering the outcome through [deliver]. Called
     * on the render thread; returns immediately.
     */
    private fun encodeCompositePhotoAsync(
        rgbaBottomUp: ByteBuffer,
        widthPx: Int,
        heightPx: Int,
        outputFile: File,
        deliver: (Result<CompositePhotoOutcome>) -> Unit,
    ) {
        val worker = Thread(
            { deliver(encodeCompositePhoto(rgbaBottomUp, widthPx, heightPx, outputFile)) },
            PHOTO_ENCODE_THREAD_NAME,
        )
        try {
            worker.start()
        } catch (t: Throwable) {
            Log.w(TAG, "photo encode thread start failed: ${t.message}")
            deliver(Result.failure(IllegalStateException("encode_thread_start_failed", t)))
        }
    }

    /**
     * Worker-thread JPEG commit of one composite read-back:
     *   1. row-flip the GL bottom-left pixels to image top-left, forcing every
     *      alpha byte opaque (the composite is opaque over its background and
     *      the framebuffer alpha is not meaningful; an opaque ARGB_8888 bitmap
     *      also keeps the premultiplied encode path exact),
     *   2. wrap the pixels in an ARGB_8888 [Bitmap] (RGBA byte order matches
     *      GL_RGBA read-back),
     *   3. encode to "<output>.tmp",
     *   4. validate the temp is non-empty, rename it to [outputFile] and
     *      validate the final file.
     * Every failure deletes the temp and the final path and returns a failure
     * whose message is a diagnostic token. Never throws.
     */
    private fun encodeCompositePhoto(
        rgbaBottomUp: ByteBuffer,
        widthPx: Int,
        heightPx: Int,
        outputFile: File,
    ): Result<CompositePhotoOutcome> {
        val tmpFile = File(outputFile.path + ".tmp")
        var bitmap: Bitmap? = null
        try {
            if (widthPx <= 0 || heightPx <= 0) {
                return Result.failure(IllegalStateException("invalid_capture_size"))
            }
            val rowBytes = widthPx * 4
            val totalBytes = rowBytes * heightPx
            if (rgbaBottomUp.capacity() < totalBytes) {
                return Result.failure(IllegalStateException("capture_buffer_too_small"))
            }
            val startNs = System.nanoTime()

            // 1. Row flip + opaque alpha.
            val source = ByteArray(totalBytes)
            rgbaBottomUp.rewind()
            rgbaBottomUp.get(source, 0, totalBytes)
            val topDown = ByteArray(totalBytes)
            for (row in 0 until heightPx) {
                System.arraycopy(source, (heightPx - 1 - row) * rowBytes, topDown, row * rowBytes, rowBytes)
            }
            var alphaIndex = 3
            while (alphaIndex < totalBytes) {
                topDown[alphaIndex] = 0xFF.toByte()
                alphaIndex += 4
            }

            // 2. Bitmap.
            val bmp = Bitmap.createBitmap(widthPx, heightPx, Bitmap.Config.ARGB_8888)
            bitmap = bmp
            bmp.copyPixelsFromBuffer(ByteBuffer.wrap(topDown))
            bmp.setHasAlpha(false)

            // 3. JPEG -> temp.
            deleteQuietly(tmpFile)
            val encoded = FileOutputStream(tmpFile).use { out ->
                val ok = bmp.compress(Bitmap.CompressFormat.JPEG, PHOTO_JPEG_QUALITY, out)
                out.flush()
                ok
            }
            if (!encoded) {
                deleteQuietly(tmpFile)
                return Result.failure(IllegalStateException("jpeg_encode_failed"))
            }
            if (tmpFile.length() <= 0L) {
                deleteQuietly(tmpFile)
                return Result.failure(IllegalStateException("jpeg_output_empty"))
            }

            // 4. Commit + validate.
            val renamed = try { tmpFile.renameTo(outputFile) } catch (_: Throwable) { false }
            if (!renamed) {
                deleteQuietly(tmpFile)
                deleteQuietly(outputFile)
                return Result.failure(IllegalStateException("commit_rename_failed"))
            }
            val finalLength = outputFile.length()
            if (!outputFile.isFile || finalLength <= 0L) {
                deleteQuietly(outputFile)
                return Result.failure(IllegalStateException("commit_validation_failed"))
            }
            Log.i(
                TAG,
                "ANDROID_LIVE_GREENSCREEN_PHOTO_ENCODED file=${outputFile.absolutePath} " +
                    "size=${widthPx}x$heightPx bytes=$finalLength " +
                    "encodeMs=${"%.1f".format((System.nanoTime() - startNs) / 1_000_000.0)}",
            )
            return Result.success(CompositePhotoOutcome(outputFile, widthPx, heightPx, finalLength))
        } catch (t: Throwable) {
            Log.w(TAG, "composite photo encode failed: ${t.javaClass.simpleName}: ${t.message}")
            deleteQuietly(tmpFile)
            deleteQuietly(outputFile)
            return Result.failure(IllegalStateException("encode_exception:${t.javaClass.simpleName}", t))
        } finally {
            try { bitmap?.recycle() } catch (_: Throwable) {}
        }
    }

    private fun deleteQuietly(file: File) {
        try {
            if (file.exists()) file.delete()
        } catch (_: Throwable) {}
    }

    /**
     * Drains render activity in preparation for the camera source's stop.
     *
     * Must be called (on any thread) **before** cameraSource.stop() in the
     * stop ordering:
     *   beginRelease → prepareForCameraStop() → cameraSource.stop() →
     *   stopBlocking() → finishRelease
     *
     * Effects (idempotent — safe to call when already stopped):
     *   - Stops the redraw pump (so no drawFrame calls are scheduled while
     *     the camera is draining its last OES frame).
     *   - Sets canSubmit=false and bumps surfaceGeneration so any pending
     *     render-thread tasks that already queued drop their swap on the
     *     generation/canSubmit guard.
     *
     * [stopBlocking] is still required afterwards to release the compositor;
     * it is safe to call it after this method (shutdown steps are idempotent).
     */
    fun prepareForCameraStop() {
        renderHandler.removeCallbacks(redrawRunnable)
        canSubmit.set(false)
        surfaceGeneration.incrementAndGet()
    }

    /**
     * Terminal teardown, bounded by [timeoutMs] and best-effort throughout
     * (never throws, even on timeout):
     * 1. stop the redraw pump and all frame submissions immediately,
     * 2. release the compositor on the render thread and wait,
     * 3. quit the render thread and join, bounded.
     *
     * Idempotent.
     */
    fun stopBlocking(timeoutMs: Long = 1000L) {
        if (!isStopped.compareAndSet(false, true)) return
        try {
            renderHandler.removeCallbacks(redrawRunnable)
            canSubmit.set(false)
            surfaceGeneration.incrementAndGet()

            if (Looper.myLooper() == renderHandler.looper) {
                try { compositor.release() } catch (_: Throwable) {}
            } else {
                val releaseDone = CountDownLatch(1)
                val posted = renderHandler.post {
                    try { compositor.release() } catch (_: Throwable) {}
                    releaseDone.countDown()
                }
                if (posted) {
                    awaitQuietly(releaseDone, timeoutMs)
                } else {
                    // Render looper already gone; no GL work can be pending.
                    try { compositor.release() } catch (_: Throwable) {}
                }
            }

            renderThread.quitSafely()
            if (Thread.currentThread() !== renderThread) {
                try {
                    renderThread.join(timeoutMs.coerceAtLeast(0L))
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "stopBlocking best-effort teardown hit: ${t.message}")
        }
    }

    // -- Diagnostics (bounded, render-thread-safe, never mutates state) --------

    /**
     * Bounded diagnostics snapshot for regression tooling. Executes directly
     * when already called from the render thread; otherwise posts to it and
     * blocks the caller for at most [timeoutMs] so main/plugin-thread callers
     * can never stall indefinitely. On post failure, timeout, or an
     * exception inside the capture, returns a best-effort map carrying a
     * `diagnosticsUnavailable` reason instead of throwing. Never mutates
     * compositor or render-loop state.
     */
    fun diagnosticsSnapshot(timeoutMs: Long = 250L): Map<String, Any?> {
        if (Looper.myLooper() == renderHandler.looper) {
            return try {
                captureDiagnosticsSnapshot()
            } catch (t: Throwable) {
                Log.w(TAG, "diagnosticsSnapshot capture threw: ${t.message}")
                fallbackDiagnosticsSnapshot("capture_exception")
            }
        }

        val captured = arrayOfNulls<Map<String, Any?>>(1)
        val latch = CountDownLatch(1)
        val posted = try {
            renderHandler.post {
                try {
                    captured[0] = captureDiagnosticsSnapshot()
                } catch (t: Throwable) {
                    Log.w(TAG, "diagnosticsSnapshot capture threw: ${t.message}")
                } finally {
                    latch.countDown()
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "diagnosticsSnapshot post threw: ${t.message}")
            false
        }
        if (!posted) return fallbackDiagnosticsSnapshot("post_failed")

        val completed = awaitQuietly(latch, timeoutMs)
        if (!completed) return fallbackDiagnosticsSnapshot("timeout")
        return captured[0] ?: fallbackDiagnosticsSnapshot("capture_failed")
    }

    /** Render-thread-only: reads compositor + render-loop state, mutates nothing. */
    private fun captureDiagnosticsSnapshot(): Map<String, Any?> {
        val snapshot = LinkedHashMap<String, Any?>()
        snapshot["usingFallbackBackend"] = usingFallbackBackend
        snapshot["hasAttachedOnce"] = hasAttachedOnce
        snapshot["canSubmit"] = canSubmit.get()
        snapshot["stopped"] = isStopped.get()
        snapshot["backendDiagnostics"] = try {
            compositor.diagnosticsSnapshot()
        } catch (t: Throwable) {
            Log.w(TAG, "compositor diagnosticsSnapshot threw: ${t.message}")
            null
        }
        return snapshot
    }

    private fun fallbackDiagnosticsSnapshot(reason: String): Map<String, Any?> {
        val snapshot = LinkedHashMap<String, Any?>()
        snapshot["diagnosticsUnavailable"] = reason
        snapshot["usingFallbackBackend"] = usingFallbackBackend
        snapshot["stopped"] = isStopped.get()
        return snapshot
    }

    // -- Camera redraw pump ------------------------------------------------------

    /**
     * The sole frame source for this loop: fires on the render thread at
     * ~30 fps whenever an output is attached, presenting a new camera frame
     * as soon as one arrives. Does not queue unbounded work (coalesced: only
     * one re-post pending at a time). Output surface loss gates the swap
     * inside drawFrame (returns false when no window surface); the loop keeps
     * running but swaps silently fail until the output is re-attached.
     */
    private val redrawRunnable = object : Runnable {
        override fun run() {
            if (isStopped.get()) return
            if (canSubmit.get() && compositor.hasPendingCameraFrame) {
                compositor.drawFrame()
            }
            renderHandler.postDelayed(this, CAMERA_REDRAW_MS)
        }
    }

    private fun startRedrawPump() {
        renderHandler.removeCallbacks(redrawRunnable)
        renderHandler.post(redrawRunnable)
    }

    // -- Helpers ----------------------------------------------------------------

    private fun awaitQuietly(latch: CountDownLatch, timeoutMs: Long): Boolean {
        return try {
            latch.await(timeoutMs.coerceAtLeast(0L), TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
    }
}
