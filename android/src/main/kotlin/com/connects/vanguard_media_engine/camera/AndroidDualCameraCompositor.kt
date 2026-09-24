// AndroidDualCameraCompositor.kt
// Slice 1: Native Dual-Camera Compositor Core.
//
// Manages a 30fps GPU render loop for the dual-camera pipeline.
// Backend is selected from a caller-supplied BackendCapabilityReport:
//   - Vulkan supported  → VkSurfaceKHR swapchain direct render (zero-copy, no CPU readback).
//   - GLES only         → EGL context + GlesMultiCamSpatialCompositor.
//
// Invariants:
//   - No Camera2 / CameraDevice / CameraManager usage. Provides input Surfaces only.
//   - No TextureRegistry interaction. Receives outputSurface from caller (SurfaceProducer).
//   - start() / stop() are safe to call from any thread; render loop runs on HandlerThread.
//   - updateLayout() is thread-safe (AtomicReference).
//   - stop() is idempotent and always releases all GPU and surface resources.
//   - Vulkan init failure falls back to GLES; GLES failure throws IllegalStateException.

package com.connects.vanguard_media_engine.camera

import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.HardwareBuffer
import android.media.ImageReader
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.PixelCopy
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.BackendCapabilityReport
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock

private const val TAG = "AndroidDualCamCompositor"
private const val FRAME_INTERVAL_MS = 33L // ~30fps

/**
 * Dual-camera GPU compositor. Allocates camera input surfaces and renders a composited
 * frame to [outputSurface] on every 30fps tick.
 *
 * @param backendCapability Pre-probed backend report from the caller (VanguardNativeBridge).
 *   Vulkan is preferred; GLES is the fallback.
 *
 * Call [start] to select the backend, allocate surfaces, and begin rendering.
 * Pass [frontInputSurface] and [backInputSurface] to a camera source to stream into.
 * Call [updateLayout] at any time to change the composited layout.
 * Call [stop] to cleanly shut down all GPU and surface resources.
 */
class AndroidDualCameraCompositor(
    private val outputSurface: Surface,
    private val backendCapability: BackendCapabilityReport,
    private val canvasWidth: Int = 1080,
    private val canvasHeight: Int = 1920,
    private val cameraInputWidth: Int = maxOf(canvasWidth, canvasHeight),
    private val cameraInputHeight: Int = minOf(canvasWidth, canvasHeight),
) {

    // ── Public layout params ────────────────────────────────────────────────

    data class LayoutParams(
        val layoutMode: String = "pip",           // "pip" | "splitScreen"
        val anchor: String = "bottomRight",        // "topLeft"|"topRight"|"bottomLeft"|"bottomRight"|"freeFloating"
        val splitDirection: String = "leftRight",  // "topBottom" | "leftRight"
        val splitRatio: Double = 0.5,
        val pipWidthFraction: Double = 0.3,
        val pipCenterX: Double = 0.5,             // normalized [0,1]; only used when anchor == "freeFloating"
        val pipCenterY: Double = 0.5,             // normalized [0,1]; only used when anchor == "freeFloating"
        val pipCornerRadius: Double = 24.0,
        val isFrontPrimary: Boolean = false,      // front feed occupies the primary role when true
    )

    companion object {
        /**
         * Parses a Dart-side VGLivePreviewConfig.toMap() into [LayoutParams].
         *
         * Fail-safe: unknown/missing values fall back to [LayoutParams] defaults.
         * Never throws.
         */
        fun parseConfigMap(config: Map<*, *>?): LayoutParams {
            if (config == null) return LayoutParams()

            val layoutMode = (config["layoutMode"] as? String) ?: "pip"

            // PiP sub-map
            val pipMap = config["pipLayout"] as? Map<*, *>
            val anchor = (pipMap?.get("anchor") as? String) ?: "bottomRight"
            val pipWidthFraction = (pipMap?.get("widthFraction") as? Number)?.toDouble() ?: 0.3
            val pipCenterX = (pipMap?.get("centerX") as? Number)?.toDouble() ?: 0.5
            val pipCenterY = (pipMap?.get("centerY") as? Number)?.toDouble() ?: 0.5
            val pipCornerRadius = (pipMap?.get("cornerRadius") as? Number)?.toDouble() ?: 24.0

            // Split sub-map — Dart key is "direction", NOT "splitDirection"
            val splitMap = config["splitLayout"] as? Map<*, *>
            val splitDirection = (splitMap?.get("direction") as? String) ?: "leftRight"
            val splitRatio = (splitMap?.get("splitRatio") as? Number)?.toDouble() ?: 0.5

            // Flat top-level key — NOT nested under pipLayout/splitLayout.
            val isFrontPrimary = (config["isFrontPrimary"] as? Boolean) ?: false

            return LayoutParams(
                layoutMode = layoutMode,
                anchor = anchor,
                splitDirection = splitDirection,
                splitRatio = splitRatio,
                pipWidthFraction = pipWidthFraction,
                pipCenterX = pipCenterX,
                pipCenterY = pipCenterY,
                pipCornerRadius = pipCornerRadius,
                isFrontPrimary = isFrontPrimary,
            )
        }
    }

    // ── Internal state ──────────────────────────────────────────────────────

    @Volatile var isVulkanBackend: Boolean = false
        private set

    private val started = AtomicBoolean(false)
    private val stopped = AtomicBoolean(false)

    private val currentLayout = AtomicReference(LayoutParams())

    // Render thread
    private var renderThread: HandlerThread? = null
    private var renderHandler: Handler? = null

    // Vulkan path resources
    private var frontImageReader: ImageReader? = null
    private var backImageReader: ImageReader? = null
    private val nativeSessionHandle = AtomicLong(0L)

    // GLES path resources
    private var frontSurfaceTexture: SurfaceTexture? = null
    private var backSurfaceTexture: SurfaceTexture? = null
    private var frontGlesTexId: Int = 0
    private var backGlesTexId: Int = 0

    // Surfaces exposed to camera sources
    @Volatile private var _frontInputSurface: Surface? = null
    @Volatile private var _backInputSurface: Surface? = null

    val frontInputSurface: Surface
        get() = _frontInputSurface ?: error("Compositor not started")

    val backInputSurface: Surface
        get() = _backInputSurface ?: error("Compositor not started")

    // ── Frame snapshot for photo capture ────────────────────────────────────
    // Architecturally parallel to iOS's _lastCompositedBuffer: a lock-guarded
    // reference to the most recently read-back composited frame, refreshed by
    // PixelCopy after every successful render. The lock is held only for a
    // trivial reference read/write — JPEG encoding happens outside of it.
    private val bitmapLock = ReentrantLock()
    private var snapshotBitmap: Bitmap? = null
    private var lastCompositedBitmap: Bitmap? = null
    private val pixelCopyInFlight = AtomicBoolean(false)

    /**
     * Optional sink for composited frames, invoked on the compositor's render
     * thread exactly once per successful PixelCopy readback (i.e. at most
     * once per rendered frame, never for a skipped/failed readback). The
     * [Bitmap] passed to the sink is **borrowed** and valid only for the
     * duration of the call — implementations must copy any pixels they need
     * and return promptly; they must never retain, recycle, or mutate it,
     * and must never block (the render loop's next PixelCopy request is
     * gated on this call returning). Any exception thrown by the sink is
     * caught and logged so it can never disrupt rendering.
     */
    @Volatile var onFrameRendered: ((Bitmap) -> Unit)? = null

    /** Output canvas width in pixels, as configured at construction. */
    val outputWidth: Int get() = canvasWidth

    /** Output canvas height in pixels, as configured at construction. */
    val outputHeight: Int get() = canvasHeight

    /** True once at least one composited frame has been successfully read back. */
    val hasRenderedFrame: Boolean
        get() {
            bitmapLock.lock()
            try {
                return lastCompositedBitmap != null
            } finally {
                bitmapLock.unlock()
            }
        }

    // ── Public API ──────────────────────────────────────────────────────────

    /**
     * Probe backend, allocate input surfaces, and start the 30fps render loop.
     * Safe to call from any thread. Must only be called once.
     */
    fun start() {
        check(started.compareAndSet(false, true)) { "AndroidDualCameraCompositor already started" }
        check(!stopped.get()) { "AndroidDualCameraCompositor already stopped" }

        Log.i(TAG, "start() canvasWidth=$canvasWidth canvasHeight=$canvasHeight")

        // Backend selection from the pre-probed capability report supplied at construction.
        Log.i(TAG, "BackendCapability: vulkan=${backendCapability.vulkanSupported} gles=${backendCapability.glesSupported}")

        val useVulkan = backendCapability.vulkanSupported

        // Create native session (Vulkan swapchain or GLES EGL context).
        val handle = VanguardNativeBridge.nativeCreateDualCamSession(
            outputSurface,
            canvasWidth,
            canvasHeight,
            useVulkan,
        )

        if (handle == 0L) {
            if (useVulkan) {
                Log.w(TAG, "Vulkan session creation failed, attempting GLES fallback")
                val glesHandle = VanguardNativeBridge.nativeCreateDualCamSession(
                    outputSurface,
                    canvasWidth,
                    canvasHeight,
                    false,
                )
                if (glesHandle == 0L) {
                    throw IllegalStateException("No GPU backend available: both Vulkan and GLES session creation failed")
                }
                isVulkanBackend = false
                nativeSessionHandle.set(glesHandle)
                Log.i(TAG, "GLES fallback session created handle=$glesHandle")
            } else {
                throw IllegalStateException("No GPU backend available: GLES session creation failed")
            }
        } else {
            isVulkanBackend = useVulkan
            nativeSessionHandle.set(handle)
            Log.i(TAG, "GPU session created backend=${if (useVulkan) "Vulkan" else "GLES"} handle=$handle")
        }

        // Start the render loop thread FIRST so allocateGlesInputSurfaces()
        // can post work to renderHandler immediately.
        val thread = HandlerThread("DualCamCompositor").also { it.start() }
        renderThread = thread
        renderHandler = Handler(thread.looper)

        // Allocate camera input surfaces (GLES path posts to renderHandler).
        if (isVulkanBackend) {
            allocateVulkanInputSurfaces()
        } else {
            allocateGlesInputSurfaces()
        }

        // Pre-allocate the PixelCopy readback target for photo capture snapshots.
        snapshotBitmap = Bitmap.createBitmap(canvasWidth, canvasHeight, Bitmap.Config.ARGB_8888)

        scheduleNextFrame()

        Log.i(TAG, "Render loop started backend=${if (isVulkanBackend) "Vulkan" else "GLES"}")
    }

    /**
     * Atomically update the composited layout. Safe to call from any thread.
     * The next rendered frame picks up the new params.
     */
    fun updateLayout(params: LayoutParams) {
        currentLayout.set(params)
        Log.d(TAG, "updateLayout mode=${params.layoutMode} anchor=${params.anchor}")
    }

    /**
     * Returns a caller-owned copy of the most recently composited frame, or
     * `null` if no frame has been captured yet (e.g. called immediately after
     * [start], before the first PixelCopy readback completes).
     *
     * Thread-safe and callable from any thread. Mirrors iOS's snapshot
     * pattern: the internal lock is held only long enough to copy the
     * [Bitmap] reference's pixel data — JPEG encoding and disk I/O must
     * happen on the returned copy, outside of any compositor-owned lock.
     */
    fun captureSnapshot(): Bitmap? {
        bitmapLock.lock()
        try {
            return lastCompositedBitmap?.copy(Bitmap.Config.ARGB_8888, false)
        } finally {
            bitmapLock.unlock()
        }
    }

    /**
     * Stop the render loop and release all GPU and surface resources.
     * Idempotent. Safe to call from any thread.
     */
    fun stop() {
        if (!stopped.compareAndSet(false, true)) {
            return // already stopped or never started
        }
        Log.i(TAG, "stop()")

        // Stop the render loop — wait for in-flight frame to finish.
        val latch = CountDownLatch(1)
        val handler = renderHandler
        if (handler != null) {
            handler.removeCallbacksAndMessages(null)
            handler.post { latch.countDown() }
        } else {
            latch.countDown()
        }
        if (!latch.await(2, TimeUnit.SECONDS)) {
            Log.w(TAG, "Timed out waiting for render thread to drain")
        }

        renderThread?.quitSafely()
        try { renderThread?.join(1000) } catch (_: InterruptedException) {}
        renderThread = null
        renderHandler = null

        // Destroy native session (Vulkan idle wait or GLES context release).
        val handle = nativeSessionHandle.getAndSet(0L)
        if (handle != 0L) {
            VanguardNativeBridge.nativeDestroyDualCamSession(handle)
            Log.d(TAG, "Native session destroyed handle=$handle")
        }

        // Release Vulkan ImageReaders.
        frontImageReader?.close()
        frontImageReader = null
        backImageReader?.close()
        backImageReader = null

        // Release GLES SurfaceTextures.
        frontSurfaceTexture?.release()
        frontSurfaceTexture = null
        backSurfaceTexture?.release()
        backSurfaceTexture = null

        // Release input Surfaces.
        _frontInputSurface?.release()
        _frontInputSurface = null
        _backInputSurface?.release()
        _backInputSurface = null

        // Clear the frame sink before releasing snapshot resources so no
        // caller can be invoked with (or retain) a bitmap that is about to
        // be recycled.
        onFrameRendered = null

        // Release frame snapshot resources.
        bitmapLock.lock()
        try {
            lastCompositedBitmap = null
            snapshotBitmap?.recycle()
            snapshotBitmap = null
        } finally {
            bitmapLock.unlock()
        }

        Log.i(TAG, "stop() complete")
    }

    // ── Private: input surface allocation ──────────────────────────────────

    private fun allocateVulkanInputSurfaces() {
        // ImageFormat.PRIVATE with USAGE_GPU_SAMPLED_IMAGE → AHardwareBuffer for zero-copy Vulkan import.
        // Camera sensors stream in native landscape orientation (e.g. 1920x1080). Passing cameraInputWidth
        // x cameraInputHeight prevents Camera HAL from squeezing the 16:9 stream into portrait, and lets
        // Vulkan's 90/270 degree rotation and aspect-fill correctly resolve to 9:16 portrait.
        val front = ImageReader.newInstance(
            cameraInputWidth, cameraInputHeight, ImageFormat.PRIVATE, /* maxImages= */ 3,
            HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
        )
        val back = ImageReader.newInstance(
            cameraInputWidth, cameraInputHeight, ImageFormat.PRIVATE, /* maxImages= */ 3,
            HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
        )
        frontImageReader = front
        backImageReader = back
        _frontInputSurface = front.surface
        _backInputSurface = back.surface
        Log.d(TAG, "Vulkan ImageReaders allocated ${cameraInputWidth}x${cameraInputHeight}")
    }

    private fun allocateGlesInputSurfaces() {
        // Must generate OpenGL textures. The EGL context was established in nativeCreateDualCamSession.
        // We allocate the SurfaceTextures on the render thread where the context is current.
        val latch = CountDownLatch(1)
        renderHandler?.post {
            try {
                val texIds = IntArray(2)
                GLES20.glGenTextures(2, texIds, 0)
                frontGlesTexId = texIds[0]
                backGlesTexId = texIds[1]

                val front = SurfaceTexture(frontGlesTexId).apply {
                    setDefaultBufferSize(cameraInputWidth, cameraInputHeight)
                }
                val back = SurfaceTexture(backGlesTexId).apply {
                    setDefaultBufferSize(cameraInputWidth, cameraInputHeight)
                }
                frontSurfaceTexture = front
                backSurfaceTexture = back
                _frontInputSurface = Surface(front)
                _backInputSurface = Surface(back)
                Log.d(TAG, "GLES SurfaceTextures allocated texIds=[${texIds[0]},${texIds[1]}]")
            } finally {
                latch.countDown()
            }
        }
        // Post is synchronous here since we call this before scheduleNextFrame.
        // If renderHandler is null (shouldn't be), fall through and surfaces stay null.
        if (renderHandler != null && !latch.await(2, TimeUnit.SECONDS)) {
            Log.e(TAG, "GLES SurfaceTexture allocation timed out")
        }
    }

    // ── Private: render loop ────────────────────────────────────────────────

    private fun scheduleNextFrame() {
        if (stopped.get()) return
        renderHandler?.postDelayed(::renderFrame, FRAME_INTERVAL_MS)
    }

    private fun renderFrame() {
        if (stopped.get()) return
        val handle = nativeSessionHandle.get()
        if (handle == 0L) return

        val params = currentLayout.get()
        val layoutJson = buildLayoutJson(params)

        val composited = if (isVulkanBackend) {
            renderFrameVulkan(handle, layoutJson)
        } else {
            renderFrameGles(handle, layoutJson)
        }

        if (composited) {
            captureFrameSnapshot()
        }

        scheduleNextFrame()
    }

    private fun renderFrameVulkan(handle: Long, layoutJson: String): Boolean {
        val front = frontImageReader ?: return false
        val back = backImageReader ?: return false

        // Acquire latest available images (non-blocking — drop frame if none available yet).
        val frontImage = try { front.acquireLatestImage() } catch (_: Throwable) { null }
        val backImage = try { back.acquireLatestImage() } catch (_: Throwable) { null }

        var composited = false
        try {
            val frontAhb = frontImage?.hardwareBuffer
            val backAhb = backImage?.hardwareBuffer
            try {
                // Only composite when both camera frames are available.
                if (frontAhb != null && backAhb != null) {
                    composited = VanguardNativeBridge.nativeDualCamCompositeFrame(
                        handle,
                        frontAhb,
                        backAhb,
                        layoutJson,
                    )
                    if (!composited) {
                        Log.w(TAG, "nativeDualCamCompositeFrame returned false")
                    }
                }
            } finally {
                // Always close AHBs regardless of which were null — prevents FD leaks.
                frontAhb?.close()
                backAhb?.close()
            }
        } finally {
            // Release images back to the ImageReader pool.
            frontImage?.close()
            backImage?.close()
        }
        return composited
    }

    private fun renderFrameGles(handle: Long, layoutJson: String): Boolean {
        val frontSt = frontSurfaceTexture ?: return false
        val backSt = backSurfaceTexture ?: return false

        // Update SurfaceTexture with latest camera frame.
        frontSt.updateTexImage()
        backSt.updateTexImage()

        // Delegate to native GLES compositor (drawSpatialComposite + eglSwapBuffers).
        val ok = VanguardNativeBridge.nativeDualCamCompositeFrame(
            handle,
            null, // no AHardwareBuffer in GLES path
            null,
            layoutJson,
        )
        if (!ok) {
            Log.w(TAG, "nativeDualCamCompositeFrame (GLES) returned false")
        }
        return ok
    }

    // ── Private: frame snapshot readback ────────────────────────────────────

    /**
     * Issues an async PixelCopy readback of [outputSurface] into the
     * pre-allocated [snapshotBitmap], swapping it into [lastCompositedBitmap]
     * under [bitmapLock] on success. Never blocks the render loop: skips this
     * frame's readback if a previous PixelCopy request is still in flight
     * (avoids overlapping writes into the same target Bitmap), and any
     * failure is logged without disrupting rendering.
     */
    private fun captureFrameSnapshot() {
        val target = snapshotBitmap ?: return
        val handler = renderHandler ?: return
        if (stopped.get()) return

        if (!pixelCopyInFlight.compareAndSet(false, true)) {
            return
        }

        try {
            PixelCopy.request(outputSurface, target, { copyResult ->
                try {
                    if (copyResult == PixelCopy.SUCCESS) {
                        bitmapLock.lock()
                        try {
                            lastCompositedBitmap = target
                        } finally {
                            bitmapLock.unlock()
                        }
                        try {
                            onFrameRendered?.invoke(target)
                        } catch (t: Throwable) {
                            Log.w(TAG, "captureFrameSnapshot: onFrameRendered threw: ${t.javaClass.simpleName}: ${t.message}")
                        }
                    } else {
                        Log.w(TAG, "captureFrameSnapshot: PixelCopy failed with result=$copyResult")
                    }
                } finally {
                    // Reset only after the sink has finished reading `target` — this is
                    // what makes the hand-off race-free: no new PixelCopy request can be
                    // issued into `target` while a sink call is still in progress.
                    pixelCopyInFlight.set(false)
                }
            }, handler)
        } catch (t: Throwable) {
            pixelCopyInFlight.set(false)
            Log.w(TAG, "captureFrameSnapshot: PixelCopy.request threw: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    // ── Private: layout JSON serialization ─────────────────────────────────

    private fun buildLayoutJson(params: LayoutParams): String {
        // Matches the strict resolver in the existing JNI code (ParseLayoutJson).
        // pipCenterX/pipCenterY are passed unconditionally; the C++ side uses
        // them only when anchor == "freeFloating".
        return """{"layoutMode":"${params.layoutMode}","pipAnchor":"${params.anchor}","splitDirection":"${params.splitDirection}","splitRatio":${params.splitRatio},"pipWidthFraction":${params.pipWidthFraction},"pipCenterX":${params.pipCenterX},"pipCenterY":${params.pipCenterY},"pipCornerRadius":${params.pipCornerRadius},"isFrontPrimary":${params.isFrontPrimary}}"""
    }

    // ── finalize guard ──────────────────────────────────────────────────────

    protected fun finalize() {
        if (!stopped.get()) {
            Log.w(TAG, "finalize() called without stop() — calling stop() defensively")
            stop()
        }
    }
}
