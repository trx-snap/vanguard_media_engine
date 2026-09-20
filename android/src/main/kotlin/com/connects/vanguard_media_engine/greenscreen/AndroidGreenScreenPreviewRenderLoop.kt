package com.connects.vanguard_media_engine.greenscreen

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Surface
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
// AndroidGreenScreenPreviewCompositor confined to it. It is a pure pump
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
) {

    companion object {
        private const val TAG = "GreenScreenPreviewRenderLoop"

        /** Camera idle redraw cadence (~30 fps) — the sole frame source for this loop. */
        private const val CAMERA_REDRAW_MS = 33L
    }

    // -- Owned render thread + compositor (render-thread-confined) -------------

    private val renderThread = HandlerThread("vg.greenscreen.render").apply { start() }
    private val renderHandler = Handler(renderThread.looper)

    /** Render-thread-only; every touch happens via [renderHandler]. */
    private val compositor: AndroidGreenScreenPreviewBackend = AndroidGreenScreenPreviewCompositor()

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
            if (!compositor.attachOutputSurface(surface, widthPx, heightPx)) return@post
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
            compositor.setCameraFrameTransform(rotationDegrees, mirrorHorizontal)
        }
    }

    /**
     * Delivers a new CPU segmentation mask to the compositor for the next draw.
     * Posts to the render thread; the compositor's AtomicReference absorbs
     * any thread-safety concern between this post and the next drawFrame.
     * No ML runs inside the render loop.
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
            compositor.setGreenScreenBackground(background)
        }
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

    private fun awaitQuietly(latch: CountDownLatch, timeoutMs: Long) {
        try {
            latch.await(timeoutMs.coerceAtLeast(0L), TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }
}
