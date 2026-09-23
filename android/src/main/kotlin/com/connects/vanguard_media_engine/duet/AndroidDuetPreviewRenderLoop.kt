package com.connects.vanguard_media_engine.duet

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import android.view.Surface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

// -----------------------------------------------------------------------------
// VG-DUET-SLICE-4B-C: Render loop / threading owner for the Duet preview
// (Android sibling of the iOS Duet preview render loop).
// -----------------------------------------------------------------------------
//
// Owns exactly one thing beyond its collaborators: the "vg.duet.render"
// HandlerThread plus the AndroidDuetPreviewCompositor confined to it. It is a
// pure pump between three loopers it does not own:
//
//   - mainHandler:    the ONLY place the active-playback targetPtsProvider is
//                     executed. The provider result crosses to the other
//                     threads as a plain Long; no clock object ever does.
//   - decoderHandler: the ONLY place AndroidDuetSourceVideoDecoder methods
//                     (rebindOutputSurface / stepFrame / seekTo and the
//                     videoWidth/videoHeight reads) are invoked.
//   - render thread:  the ONLY place compositor methods run (attach/detach,
//                     setLayout, setSourceVideoSize, drawFrame, release).
//
// Deliberately absent: Flutter, TextureRegistry, MethodChannel, session-state
// mutation, and any read of AndroidDuetPreviewClock. The loop neither owns nor
// consults a clock; every target PTS arrives as a scalar argument or via the
// mainHandler-sampled provider.
//
// Decoder op discipline: at most ONE decoder op is in flight on decoderHandler
// at a time. Requests arriving while one is in flight coalesce into a single
// pending slot (latest wins; a pending Bind is retargeted rather than dropped,
// and Unbind is terminal), so a slow decoder absorbs bursts of ticks/seeks
// instead of queueing them.
//
// Output-loss discipline: [handleOutputSurfaceLost] flips the no-submit flag
// and bumps the surface generation synchronously on the calling thread, so an
// in-flight decoder op that completes afterwards can never swap into the dead
// surface; the EGL-side detach then happens asynchronously on the render
// thread. Presents carry the generation they were requested under and are
// dropped on mismatch.

class AndroidDuetPreviewRenderLoop(
    private val mainHandler: Handler,
    private val decoderHandler: Handler,
    private val decoderProvider: () -> AndroidDuetSourceVideoDecoder?,
    /**
     * Optional callback invoked on the main thread each time [attachOutputSurface]
     * succeeds and [compositor.cameraInputSurface] is non-null. The callback carries
     * no Surface argument — the coordinator reads [cameraInputSurface] through the
     * sink interface (backend-owned consumer endpoint), avoiding raw Surface transfer
     * through the callback payload. The coordinator uses this to start
     * [AndroidDuetCameraSource] reliably without relying on an immediate
     * post-attach synchronous read of [cameraInputSurface] (which would race the
     * async render-thread bootstrap).
     *
     * Fired on every successful [attachOutputSurface] where cameraInputSurface is
     * non-null (not just the first). The coordinator's [startCameraSourceIfNeeded]
     * is idempotent — it no-ops when cameraSource is already running — so repeat
     * calls are harmless. Firing on re-attach also gives retry when a prior
     * transient CameraX failure nulled cameraSource. Never called if the
     * compositor bootstrap fails.
     */
    private val cameraInputSurfaceReady: (() -> Unit)? = null,
    /**
     * Diagnostic-only backend selection, computed by
     * [AndroidDuetPreviewBackendFactory.selectForLayoutConfig] from the
     * attach-time layoutConfigMap. Defaults to the production GLES selection.
     */
    private val backendSelection: AndroidDuetPreviewBackendSelection = AndroidDuetPreviewBackendFactory.selectDefault(),
) : AndroidDuetForegroundSink {

    companion object {
        private const val TAG = "DuetPreviewRenderLoop"

        /** Active-mode tick cadence (~30 fps preview). */
        private const val TICK_INTERVAL_MS = 33L

        /**
         * Camera idle redraw cadence (~30 fps) — fires only when camera is
         * active but the decoder is paused/held so camera frames stay live.
         */
        private const val CAMERA_IDLE_REDRAW_MS = 33L

        /**
         * When a decoder op reported a newly rendered frame, the present waits
         * (by re-posting, never blocking the render thread) for the
         * SurfaceTexture frame-available signal before drawing, bounded to
         * MAX_PRESENT_WAIT_ATTEMPTS * PRESENT_WAIT_DELAY_MS total.
         */
        private const val PRESENT_WAIT_DELAY_MS = 5L
        private const val MAX_PRESENT_WAIT_ATTEMPTS = 10
    }

    // -- Owned render thread + compositor (render-thread-confined) -------------

    private val renderThread = HandlerThread("vg.duet.render").apply { start() }
    private val renderHandler = Handler(renderThread.looper)

    /** Render-thread-only; every touch happens via [renderHandler]. */
    private val compositor: AndroidDuetPreviewBackend = AndroidDuetPreviewBackendFactory.create(backendSelection)

    init {
        Log.i(
            TAG,
            "ANDROID_DUET_PREVIEW_BACKEND_SELECTED " +
                "requested=${backendSelection.requested.name.lowercase()} " +
                "actual=${backendSelection.actual.name.lowercase()} " +
                "fallbackReason=${backendSelection.fallbackReason ?: "none"}",
        )
    }

    /**
     * Whether the decoder has been (re)bound to [compositor]'s decoder input
     * surface. Render-thread-confined: written only inside render-thread
     * tasks, so re-attach after output loss can skip the codec rebuild.
     */
    private var decoderBound = false

    /**
     * Backend-owned BufferQueue consumer endpoint (SurfaceTexture for GLES,
     * ImageReader/HardwareBuffer for Vulkan) exposed to CameraX through the
     * [AndroidDuetForegroundSink] contract. Allocated inside [compositor] during
     * the first [attachOutputSurface] call on the render thread. The render loop
     * owns this surface; the foreground provider must NOT create, release, or
     * transfer it — it reads it once in [AndroidDuetForegroundProvider.start].
     *
     * Prefer using the [cameraInputSurfaceReady] constructor callback rather
     * than polling this property, because the compositor bootstraps EGL
     * asynchronously on the render thread. The property returns null until
     * the first render-thread task for [attachOutputSurface] completes.
     * The callback is the only guaranteed delivery point.
     */
    override val cameraInputSurface: android.view.Surface? get() = compositor.cameraInputSurface

    // -- Submission gating ------------------------------------------------------

    /**
     * Bumped synchronously on every attach, output loss and stop. Presents
     * capture the generation of the request that produced them and are dropped
     * on mismatch, so frames decoded for a previous surface never swap.
     */
    private val surfaceGeneration = AtomicInteger(0)

    /** True only between a successful attach and the next loss/stop. */
    private val canSubmit = AtomicBoolean(false)

    private val isStopped = AtomicBoolean(false)

    // -- Active-mode state ------------------------------------------------------

    @Volatile
    private var isActive = false

    @Volatile
    private var activePtsProvider: (() -> Long)? = null

    /** One-shot diagnostic latch for the startActive idle-redraw suppression marker. */
    private val activeIdleRedrawSuppressionLogged = AtomicBoolean(false)

    /**
     * Whether the current green-screen background needs source-video
     * decoding ([AndroidDuetGreenScreenBackground.usesSourceVideo]). Read by
     * [startActive] and [tickRunnable] indirectly via [setGreenScreenBackground]
     * to decide whether active playback should drive the decoder at all.
     * Written from any thread that calls [setGreenScreenBackground]; only ever
     * read on the render thread, so plain volatile is enough.
     */
    @Volatile
    private var backgroundUsesSourceVideo = true

    /** One-shot diagnostic latch for the static-background no-decoder-ticks marker. */
    private val staticBackgroundNoDecoderTicksLogged = AtomicBoolean(false)

    // -- Decoder op queue: one in flight, one coalesced pending -----------------

    private sealed class DecoderOp {
        data class Bind(val surface: Surface, val targetPtsMs: Long, val generation: Int) : DecoderOp()
        data class Step(val targetPtsMs: Long, val generation: Int) : DecoderOp()
        data class Seek(val targetPtsMs: Long, val generation: Int) : DecoderOp()
        class Unbind(val finalPtsMs: Long, val done: CountDownLatch) : DecoderOp()
    }

    private val opLock = Any()
    private var opInFlight = false
    private var pendingOp: DecoderOp? = null

    // -- Public API -------------------------------------------------------------

    /**
     * Attaches the borrowed output [surface] to the compositor, applies the
     * layout, binds the decoder to the compositor's input surface (first
     * attach only; the ingest survives output loss so re-attach skips the
     * rebuild) and presents the frame at [targetPtsMs]. Asynchronous; safe
     * from any thread.
     */
    fun attachOutputSurface(
        surface: Surface,
        widthPx: Int,
        heightPx: Int,
        sourceRect: VGDuetPixelRect,
        cameraRect: VGDuetPixelRect,
        targetPtsMs: Long,
        foregroundRotation: VGDuetForegroundRotation = VGDuetForegroundRotation.IDENTITY,
        sourceScaleMode: AndroidDuetLayerScaleMode = AndroidDuetLayerScaleMode.ASPECT_FILL,
        cameraScaleMode: AndroidDuetLayerScaleMode = AndroidDuetLayerScaleMode.ASPECT_FILL,
    ) {
        if (isStopped.get()) return
        val generation = surfaceGeneration.incrementAndGet()
        renderHandler.post {
            if (isStopped.get()) return@post
            // A newer attach/loss superseded this one before it ran.
            if (generation != surfaceGeneration.get()) return@post
            if (!compositor.attachOutputSurface(surface, widthPx, heightPx)) return@post
            compositor.setLayerScaleModes(sourceScaleMode, cameraScaleMode)
            compositor.setLayout(sourceRect, cameraRect)
            compositor.setForegroundRotation(
                foregroundRotation.rotationDegrees, foregroundRotation.anchorX, foregroundRotation.anchorY,
            )
            canSubmit.set(true)
            // Ensure camera idle pump is running so camera frames are presented
            // even before the decoder binds or active recording starts.
            startCameraIdleRedraw()
            // Notify the coordinator that cameraInputSurface is ready.
            // compositor.attachOutputSurface (which calls ensureCore on the first call)
            // allocates the camera SurfaceTexture/Surface synchronously on this render
            // thread. We must post back to mainHandler so the coordinator can start
            // CameraX (which requires the main thread).
            //
            // The callback carries no Surface argument: the coordinator reads
            // cameraInputSurface through the AndroidDuetForegroundSink interface
            // (backend-owned BufferQueue consumer endpoint). This avoids passing raw
            // Surface through the callback payload while keeping the render loop as
            // the authoritative owner of the graphics consumer.
            //
            // Fired on every successful attachOutputSurface where cameraInputSurface
            // is non-null — no once-only flag. The coordinator's startCameraSourceIfNeeded
            // is idempotent (session-identity, previewRenderLoop/previewProducer non-null,
            // surface.isValid, and cameraSource non-null guards), so repeat calls when
            // already running are harmless. Firing on re-attach gives retry after a
            // transient CameraX failure that nulled cameraSource.
            val camSurface = compositor.cameraInputSurface
            if (camSurface != null) {
                val cb = cameraInputSurfaceReady
                if (cb != null) {
                    mainHandler.post { cb() }
                }
            }
            val input = compositor.decoderInputSurface ?: return@post
            if (!decoderBound) {
                decoderBound = true
                submitDecoderOp(DecoderOp.Bind(input, targetPtsMs, generation))
            } else {
                submitDecoderOp(DecoderOp.Step(targetPtsMs, generation))
            }
        }
    }

    /**
     * Output loss (e.g. Flutter surface cleanup). Blocks nothing: flips the
     * no-submit flag and generation immediately on the calling thread so no
     * in-flight work can swap into the dying surface, then detaches the EGL
     * window surface asynchronously on the render thread. The decoder stays
     * bound to the compositor's (surviving) input surface.
     */
    fun handleOutputSurfaceLost() {
        surfaceGeneration.incrementAndGet()
        canSubmit.set(false)
        if (isStopped.get()) return
        renderHandler.post { compositor.detachOutputSurface() }
    }

    /** Steps the decoder to [targetPtsMs] and presents that frame once. */
    fun renderInitialFrame(targetPtsMs: Long) {
        if (isStopped.get()) return
        submitDecoderOp(DecoderOp.Step(targetPtsMs, surfaceGeneration.get()))
    }

    /**
     * Enters active playback: a render-thread tick fires every
     * [TICK_INTERVAL_MS], asks [mainHandler] to evaluate [targetPtsProvider]
     * (the provider NEVER runs on the render or decoder thread) and submits
     * the resulting scalar PTS as a decode/present op. Slow decodes coalesce;
     * ticks never queue behind each other.
     */
    fun startActive(targetPtsProvider: () -> Long) {
        if (isStopped.get()) return
        activePtsProvider = targetPtsProvider
        isActive = true
        if (!backgroundUsesSourceVideo) {
            // Static (solid color / image) background: no source frame will
            // ever be drawn, so sustained decoder Step ticks would only churn
            // the codec for a frame nothing shows. The camera idle redraw pump
            // already drives ~30 fps drawFrame calls (background + masked
            // camera), so it takes over from the decoder tick loop.
            logStaticBackgroundNoDecoderTicksOnce()
            renderHandler.removeCallbacks(tickRunnable)
            startCameraIdleRedraw()
            return
        }
        // Active decoder-driven presentation owns drawFrame while active. The
        // camera idle redraw must not run concurrently: its drawFrame consumes
        // the compositor's pending source frame before postPresentAttempt sees
        // it, forcing the present to wait out its bounded retry budget and
        // presenting decoded frames late/unevenly. Every active tick ends in a
        // present that draws the camera too, so the camera stays live without
        // it. Idle redraw resumes on pause/hold via stopTicking().
        stopCameraIdleRedraw()
        if (activeIdleRedrawSuppressionLogged.compareAndSet(false, true)) {
            Log.d(TAG, "ANDROID_DUET_RENDER_LOOP_ACTIVE_IDLE_REDRAW_SUPPRESSED")
        }
        renderHandler.removeCallbacks(tickRunnable)
        renderHandler.post(tickRunnable)
    }

    private fun logStaticBackgroundNoDecoderTicksOnce() {
        if (staticBackgroundNoDecoderTicksLogged.compareAndSet(false, true)) {
            Log.i(TAG, "ANDROID_DUET_GREENSCREEN_STATIC_BACKGROUND_NO_DECODER_TICKS")
        }
    }

    /** Leaves active playback, then steps to and presents [targetPtsMs] as the held frame. */
    fun pauseAndHold(targetPtsMs: Long) {
        if (isStopped.get()) return
        stopTicking()
        submitDecoderOp(DecoderOp.Step(targetPtsMs, surfaceGeneration.get()))
    }

    /** Leaves active playback, seeks the decoder to [targetPtsMs] and presents the result. */
    fun seekAndHold(targetPtsMs: Long) {
        if (isStopped.get()) return
        stopTicking()
        submitDecoderOp(DecoderOp.Seek(targetPtsMs, surfaceGeneration.get()))
    }

    /**
     * Applies new layout rects and redraws immediately with the currently
     * latched frame; while holding (not active) it additionally steps to
     * [targetPtsMs] so the held frame matches the caller's timeline position.
     */
    fun updateLayout(
        sourceRect: VGDuetPixelRect,
        cameraRect: VGDuetPixelRect,
        targetPtsMs: Long,
        foregroundRotation: VGDuetForegroundRotation = VGDuetForegroundRotation.IDENTITY,
        sourceScaleMode: AndroidDuetLayerScaleMode = AndroidDuetLayerScaleMode.ASPECT_FILL,
        cameraScaleMode: AndroidDuetLayerScaleMode = AndroidDuetLayerScaleMode.ASPECT_FILL,
    ) {
        if (isStopped.get()) return
        val generation = surfaceGeneration.get()
        renderHandler.post {
            if (isStopped.get()) return@post
            compositor.setLayerScaleModes(sourceScaleMode, cameraScaleMode)
            compositor.setLayout(sourceRect, cameraRect)
            compositor.setForegroundRotation(
                foregroundRotation.rotationDegrees, foregroundRotation.anchorX, foregroundRotation.anchorY,
            )
            if (generation == surfaceGeneration.get() && canSubmit.get()) {
                compositor.drawFrame()
            }
        }
        if (!isActive) {
            submitDecoderOp(DecoderOp.Step(targetPtsMs, generation))
        }
    }

    // -- Green-screen (render thread forwarding) --------------------------------

    /**
     * Enables or disables green-screen compositing in the compositor. Posts to
     * the render thread so the compositor's render-thread-only state is always
     * mutated on the correct thread. No ML inside the loop.
     */
    override fun setGreenScreenEnabled(enabled: Boolean) {
        if (isStopped.get()) return
        renderHandler.post {
            if (isStopped.get()) return@post
            compositor.setGreenScreenEnabled(enabled)
        }
    }

    /**
     * Debug/opt-in seam (Camera2 GPU green-screen source): forwards the live
     * camera feed's normalized display rotation and mirror state to the
     * compositor. Posts to the render thread, mirroring [setGreenScreenEnabled]'s
     * posting style so the compositor's render-thread-only state is always
     * mutated on the correct thread.
     */
    override fun setCameraFrameTransform(rotationDegrees: Int, mirrorHorizontal: Boolean) {
        if (isStopped.get()) return
        renderHandler.post {
            if (isStopped.get()) return@post
            compositor.setCameraFrameTransform(rotationDegrees, mirrorHorizontal)
        }
    }

    /**
     * Delivers a new segmentation mask to the compositor for the next draw.
     * Posts to the render thread; the compositor's AtomicReference absorbs
     * any thread-safety concern between this post and the next drawFrame.
     * No ML runs inside the render loop.
     */
    override fun updateGreenScreenMask(frame: AndroidDuetSegmentationFrame) {
        if (isStopped.get()) return
        renderHandler.post {
            if (isStopped.get()) return@post
            compositor.updateGreenScreenMask(frame)
        }
    }

    /**
     * Debug-only (RND diagnostic): forwards a raw mask visualization mode
     * ("mask_direct" | "mask_mapped" | "mask_direct_mirror_x" |
     * "mask_direct_flip_y", or null/anything else to disable) to the
     * compositor. Posts to the render thread, mirroring
     * [setGreenScreenEnabled]'s posting style so the compositor's
     * render-thread-only state is always mutated on the correct thread. Safe
     * to call after [stopBlocking] — checked before posting and again inside
     * the posted task, matching every other post in this class.
     */
    fun setGreenScreenDebugView(view: String?) {
        if (isStopped.get()) return
        renderHandler.post {
            if (isStopped.get()) return@post
            compositor.setGreenScreenDebugView(view)
        }
    }

    /**
     * Debug-only (RND diagnostic): forwards a static solid-color background
     * mode (e.g. "solid_teal", or null/anything else to disable) to the
     * compositor. Posts to the render thread, mirroring
     * [setGreenScreenDebugView]'s posting style so the compositor's
     * render-thread-only state is always mutated on the correct thread. Safe
     * to call after [stopBlocking] — checked before posting and again inside
     * the posted task, matching every other post in this class.
     */
    fun setGreenScreenBackgroundMode(mode: String?) {
        if (isStopped.get()) return
        renderHandler.post {
            if (isStopped.get()) return@post
            compositor.setGreenScreenBackgroundMode(mode)
        }
    }

    /**
     * Forwards a new green-screen background spec to the compositor. When
     * this changes whether the background needs source-video decoding
     * ([AndroidDuetGreenScreenBackground.usesSourceVideo]) while active
     * playback is running, switches the active pump accordingly: static
     * backgrounds hand off to the camera idle redraw pump (see [startActive]);
     * switching back to video resumes decoder-driven ticking.
     */
    fun setGreenScreenBackground(background: AndroidDuetGreenScreenBackground) {
        if (isStopped.get()) return
        val wasUsingSourceVideo = backgroundUsesSourceVideo
        val usesSourceVideo = background.usesSourceVideo
        backgroundUsesSourceVideo = usesSourceVideo
        renderHandler.post {
            if (isStopped.get()) return@post
            compositor.setGreenScreenBackground(background)
        }
        if (isActive && wasUsingSourceVideo != usesSourceVideo) {
            if (!usesSourceVideo) {
                logStaticBackgroundNoDecoderTicksOnce()
                renderHandler.removeCallbacks(tickRunnable)
                startCameraIdleRedraw()
            } else {
                stopCameraIdleRedraw()
                renderHandler.removeCallbacks(tickRunnable)
                renderHandler.post(tickRunnable)
            }
        }
    }

    /**
     * Delivers a GPU-resident (HardwareBuffer-backed) segmentation mask to
     * the compositor on the SAME serialized render lane as every other
     * compositor call, mirroring [updateGreenScreenMask]. Ownership of
     * [hardwareBuffer] transfers to this call regardless of outcome (see
     * [AndroidDuetPreviewBackend.updateGreenScreenMaskHardwareBuffer]): if
     * the loop is stopped, or the post fails because the render looper has
     * already quit, [hardwareBuffer] is closed here so it is never leaked.
     */
    override fun updateGreenScreenMaskHardwareBuffer(
        hardwareBuffer: android.hardware.HardwareBuffer,
        widthPx: Int,
        heightPx: Int,
        timestampUs: Long,
        onReleased: ((android.hardware.HardwareBuffer) -> Unit)?,
        acquireFenceFd: Int,
    ) {
        if (isStopped.get()) {
            closeFenceFdQuietly(acquireFenceFd)
            releaseGpuMaskBuffer(hardwareBuffer, onReleased)
            return
        }
        val posted = renderHandler.post {
            if (isStopped.get()) {
                closeFenceFdQuietly(acquireFenceFd)
                releaseGpuMaskBuffer(hardwareBuffer, onReleased)
                return@post
            }
            compositor.updateGreenScreenMaskHardwareBuffer(
                hardwareBuffer, widthPx, heightPx, timestampUs, onReleased, acquireFenceFd,
            )
        }
        if (!posted) {
            closeFenceFdQuietly(acquireFenceFd)
            releaseGpuMaskBuffer(hardwareBuffer, onReleased)
        }
    }

    private fun closeFenceFdQuietly(fd: Int) {
        if (fd < 0) return
        try {
            ParcelFileDescriptor.adoptFd(fd).close()
        } catch (_: Throwable) {}
    }

    private fun releaseGpuMaskBuffer(
        hardwareBuffer: android.hardware.HardwareBuffer,
        onReleased: ((android.hardware.HardwareBuffer) -> Unit)?,
    ) {
        if (onReleased != null) {
            onReleased(hardwareBuffer)
        } else {
            try { hardwareBuffer.close() } catch (_: Throwable) {}
        }
    }

    // -- Live take recorder surface (ANDROID-DUET-SLICE-1A) ---------------------

    /**
     * Attaches [target] (a live take recorder's encoder input surface) to the
     * compositor on the render thread. [onResult] lands on [mainHandler] with
     * true once the compositor accepted the surface — from that point every
     * new camera frame the preview latches is also drawn into it — or false
     * when the loop is stopped, the render looper is gone, or the compositor
     * rejected / failed EGL setup (nothing attached). Safe from any thread.
     */
    fun attachSegmentRecorder(
        target: AndroidDuetSegmentRecorderSurfaceTarget,
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
     * Detaches the attached take recorder surface (if any) on the render
     * thread; the compositor destroys only its EGL wrapper, never the
     * recorder-owned Surface. [onDetached] lands on [mainHandler] once no
     * render-thread work can touch the encoder surface any more, so the
     * caller may then finish/release the recorder. After [stopBlocking] the
     * compositor's release has already dropped the surface, so the callback
     * fires immediately. Idempotent; safe from any thread.
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

    /**
     * Terminal teardown, bounded by [timeoutMs] per stage and best-effort
     * throughout (never throws, even on timeout):
     * 1. stop ticking and all frame submissions immediately,
     * 2. unbind the decoder from the compositor's input surface on the
     *    decoder thread via rebindOutputSurface(null, [finalPtsMs]) and wait,
     * 3. release the compositor on the render thread and wait,
     * 4. quit the render thread and join, bounded.
     *
     * Idempotent. If (2) times out, (3) proceeds anyway: the compositor's
     * release tolerates teardown errors by contract.
     */
    fun stopBlocking(finalPtsMs: Long, timeoutMs: Long = 1000L) {
        if (!isStopped.compareAndSet(false, true)) return
        try {
            stopTicking()
            stopCameraIdleRedraw()
            canSubmit.set(false)
            surfaceGeneration.incrementAndGet()

            val unbindDone = CountDownLatch(1)
            submitDecoderOp(DecoderOp.Unbind(finalPtsMs, unbindDone))
            if (Looper.myLooper() != decoderHandler.looper) {
                awaitQuietly(unbindDone, timeoutMs)
            }
            // else: called on the decoder thread itself; waiting would
            // deadlock, so the queued unbind runs after this call returns.

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

    // -- Active ticking ---------------------------------------------------------

    private val tickRunnable = object : Runnable {
        override fun run() {
            if (isStopped.get() || !isActive) return
            val provider = activePtsProvider ?: return
            mainHandler.post {
                // Re-check on main: pause/seek/stop may have landed since.
                if (isStopped.get() || !isActive || activePtsProvider !== provider) return@post
                val targetPtsMs = try {
                    provider()
                } catch (t: Throwable) {
                    Log.w(TAG, "targetPtsProvider threw: ${t.message}")
                    return@post
                }
                submitDecoderOp(DecoderOp.Step(targetPtsMs, surfaceGeneration.get()))
            }
            renderHandler.postDelayed(this, TICK_INTERVAL_MS)
        }
    }

    /**
     * Camera-only idle redraw: fires on the render thread at ~30 fps when the
     * decoder is paused/held so camera frames remain live. Does NOT submit
     * any decoder ops and does NOT queue unbounded work (coalesced: only one
     * re-post pending at a time). Output surface loss gates the swap inside
     * drawFrame (returns false when no window surface); the loop keeps running
     * but swaps silently fail until the output is re-attached.
     */
    private val cameraIdleRedrawRunnable = object : Runnable {
        override fun run() {
            if (isStopped.get()) return
            // Only draw if the compositor has a pending camera frame or we have
            // at least one latched camera frame to re-present.
            if (canSubmit.get() && compositor.hasPendingCameraFrame) {
                compositor.drawFrame()
            }
            renderHandler.postDelayed(this, CAMERA_IDLE_REDRAW_MS)
        }
    }

    private fun startCameraIdleRedraw() {
        renderHandler.removeCallbacks(cameraIdleRedrawRunnable)
        renderHandler.post(cameraIdleRedrawRunnable)
    }

    private fun stopCameraIdleRedraw() {
        renderHandler.removeCallbacks(cameraIdleRedrawRunnable)
    }

    private fun stopTicking() {
        isActive = false
        activePtsProvider = null
        renderHandler.removeCallbacks(tickRunnable)
        // Keep camera idle redraw running — camera must remain live during pause.
        startCameraIdleRedraw()
    }

    /**
     * Drains render activity in preparation for [AndroidDuetCameraSource.stop].
     *
     * Must be called (on any thread) **before** cameraSource.stop() in the
     * stop ordering:
     *   beginRelease → prepareForCameraStop() → cameraSource.stop() →
     *   stopBlocking(finalPts) → finishRelease
     *
     * Effects (idempotent — safe to call when already stopped):
     *   - Stops the active-mode tick pump (so no new Step ops arrive).
     *   - Stops the camera-idle redraw loop (so no drawFrame calls are
     *     scheduled while CameraX is draining its last OES frame).
     *   - Sets canSubmit=false and bumps surfaceGeneration so any pending
     *     postPresent tasks that already queued on the render thread drop
     *     their swap on the generation/canSubmit guard.
     *
     * [stopBlocking] is still required afterwards to unbind the decoder and
     * release the compositor; it is safe to call it after this method
     * (shutdown steps are idempotent).
     */
    fun prepareForCameraStop() {
        // Stop render-thread tick/redraw pumps immediately from the calling thread.
        isActive = false
        activePtsProvider = null
        renderHandler.removeCallbacks(tickRunnable)
        renderHandler.removeCallbacks(cameraIdleRedrawRunnable)
        // Block swap acceptance and bump generation so any already-queued
        // postPresent tasks (racing on the render thread) see a stale generation
        // and skip eglSwapBuffers. This prevents a CameraX OES write racing a
        // concurrent drawFrame → updateTexImage while stop() is in flight.
        canSubmit.set(false)
        surfaceGeneration.incrementAndGet()
    }

    // -- Decoder op queue -------------------------------------------------------

    private fun submitDecoderOp(op: DecoderOp) {
        if (isStopped.get() && op !is DecoderOp.Unbind) return
        synchronized(opLock) {
            if (opInFlight) {
                pendingOp = pendingOp?.let { coalesce(it, op) } ?: op
                return
            }
            opInFlight = true
        }
        postDecoderOp(op)
    }

    /**
     * Merges the coalesced pending op with a newer request. Latest wins,
     * except a pending Bind is retargeted (never dropped, or the decoder would
     * stay on its headless sink) and Unbind is terminal in both directions.
     */
    private fun coalesce(pending: DecoderOp, incoming: DecoderOp): DecoderOp {
        if (pending is DecoderOp.Unbind) return pending
        if (incoming is DecoderOp.Unbind) return incoming
        if (pending is DecoderOp.Bind) {
            return when (incoming) {
                is DecoderOp.Bind -> incoming
                is DecoderOp.Step ->
                    pending.copy(targetPtsMs = incoming.targetPtsMs, generation = incoming.generation)
                is DecoderOp.Seek ->
                    pending.copy(targetPtsMs = incoming.targetPtsMs, generation = incoming.generation)
                is DecoderOp.Unbind -> incoming
            }
        }
        return incoming
    }

    private fun postDecoderOp(op: DecoderOp) {
        if (decoderHandler.post { runDecoderOp(op) }) return
        // Decoder looper is gone: drop this op and anything pending, and never
        // leave an Unbind waiter hanging.
        if (op is DecoderOp.Unbind) op.done.countDown()
        val dropped: DecoderOp?
        synchronized(opLock) {
            dropped = pendingOp
            pendingOp = null
            opInFlight = false
        }
        if (dropped is DecoderOp.Unbind) dropped.done.countDown()
    }

    private fun onDecoderOpFinished() {
        val next: DecoderOp
        synchronized(opLock) {
            val pending = pendingOp
            if (pending == null) {
                opInFlight = false
                return
            }
            pendingOp = null
            next = pending
        }
        postDecoderOp(next)
    }

    // -- Decoder ops (decoder thread only) --------------------------------------

    private fun runDecoderOp(op: DecoderOp) {
        try {
            when (op) {
                is DecoderOp.Bind -> runBindOp(op)
                is DecoderOp.Step -> runStepOp(op)
                is DecoderOp.Seek -> runSeekOp(op)
                is DecoderOp.Unbind -> runUnbindOp(op)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Decoder op ${op.javaClass.simpleName} threw: ${t.message}")
            if (op is DecoderOp.Unbind) op.done.countDown()
        } finally {
            onDecoderOpFinished()
        }
    }

    private fun runBindOp(op: DecoderOp.Bind) {
        if (isStopped.get()) return
        val decoder = decoderProvider()
        val bound = decoder != null && try {
            decoder.rebindOutputSurface(op.surface, op.targetPtsMs)
        } catch (t: Throwable) {
            Log.w(TAG, "rebindOutputSurface threw: ${t.message}")
            false
        }
        if (!bound) {
            // Let a later attach retry the bind instead of stepping into it.
            renderHandler.post { decoderBound = false }
            return
        }
        postPresent(op.generation, expectNewFrame = true, decoder!!.videoWidth, decoder.videoHeight, decoder.videoRotationDegrees)
    }

    private fun runStepOp(op: DecoderOp.Step) {
        if (isStopped.get()) return
        val decoder = decoderProvider()
        if (decoder == null) {
            postPresent(op.generation, expectNewFrame = false, 0, 0, 0)
            return
        }
        val result = decoder.stepFrame(op.targetPtsMs)
        postPresent(op.generation, result.advancedToNewFrame, decoder.videoWidth, decoder.videoHeight, decoder.videoRotationDegrees)
    }

    private fun runSeekOp(op: DecoderOp.Seek) {
        if (isStopped.get()) return
        val decoder = decoderProvider()
        if (decoder == null) {
            postPresent(op.generation, expectNewFrame = false, 0, 0, 0)
            return
        }
        val reached = decoder.seekTo(op.targetPtsMs)
        postPresent(op.generation, expectNewFrame = reached, decoder.videoWidth, decoder.videoHeight, decoder.videoRotationDegrees)
    }

    private fun runUnbindOp(op: DecoderOp.Unbind) {
        try {
            decoderProvider()?.rebindOutputSurface(null, op.finalPtsMs)
        } catch (t: Throwable) {
            Log.w(TAG, "Unbind rebindOutputSurface(null) threw: ${t.message}")
        } finally {
            op.done.countDown()
        }
    }

    // -- Present (render thread only) -------------------------------------------

    private fun postPresent(
        generation: Int,
        expectNewFrame: Boolean,
        videoWidthPx: Int,
        videoHeightPx: Int,
        videoRotationDegrees: Int,
    ) {
        postPresentAttempt(generation, expectNewFrame, videoWidthPx, videoHeightPx, videoRotationDegrees, attempt = 0, delayMs = 0L)
    }

    private fun postPresentAttempt(
        generation: Int,
        expectNewFrame: Boolean,
        videoWidthPx: Int,
        videoHeightPx: Int,
        videoRotationDegrees: Int,
        attempt: Int,
        delayMs: Long,
    ) {
        val task = Runnable {
            if (isStopped.get()) return@Runnable
            // Video size/rotation applies regardless of generation: it
            // describes the source stream, which survives output loss.
            if (videoWidthPx > 0 && videoHeightPx > 0) {
                compositor.setSourceVideoMetadata(videoWidthPx, videoHeightPx, videoRotationDegrees)
            }
            if (generation != surfaceGeneration.get() || !canSubmit.get()) return@Runnable
            if (expectNewFrame && !compositor.hasPendingSourceFrame && attempt < MAX_PRESENT_WAIT_ATTEMPTS) {
                // Decoder rendered but the frame-available signal has not
                // arrived yet; re-post instead of blocking the render thread.
                postPresentAttempt(generation, true, 0, 0, 0, attempt + 1, PRESENT_WAIT_DELAY_MS)
                return@Runnable
            }
            compositor.drawFrame()
        }
        if (delayMs > 0) {
            renderHandler.postDelayed(task, delayMs)
        } else {
            renderHandler.post(task)
        }
    }

    // -- Helpers ----------------------------------------------------------------

    private fun awaitQuietly(latch: CountDownLatch, timeoutMs: Long) {
        try {
            latch.await(timeoutMs.coerceAtLeast(0L), TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }
}
