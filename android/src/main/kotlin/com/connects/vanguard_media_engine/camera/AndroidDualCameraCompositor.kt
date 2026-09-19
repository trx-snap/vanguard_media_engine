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
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.BackendCapabilityReport
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

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
    )

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

        Log.i(TAG, "stop() complete")
    }

    // ── Private: input surface allocation ──────────────────────────────────

    private fun allocateVulkanInputSurfaces() {
        // ImageFormat.PRIVATE with USAGE_GPU_SAMPLED_IMAGE → AHardwareBuffer for zero-copy Vulkan import.
        val front = ImageReader.newInstance(
            canvasWidth, canvasHeight, ImageFormat.PRIVATE, /* maxImages= */ 3,
            HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
        )
        val back = ImageReader.newInstance(
            canvasWidth, canvasHeight, ImageFormat.PRIVATE, /* maxImages= */ 3,
            HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
        )
        frontImageReader = front
        backImageReader = back
        _frontInputSurface = front.surface
        _backInputSurface = back.surface
        Log.d(TAG, "Vulkan ImageReaders allocated ${canvasWidth}x${canvasHeight}")
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
                    setDefaultBufferSize(canvasWidth, canvasHeight)
                }
                val back = SurfaceTexture(backGlesTexId).apply {
                    setDefaultBufferSize(canvasWidth, canvasHeight)
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

        if (isVulkanBackend) {
            renderFrameVulkan(handle, layoutJson)
        } else {
            renderFrameGles(handle, layoutJson)
        }

        scheduleNextFrame()
    }

    private fun renderFrameVulkan(handle: Long, layoutJson: String) {
        val front = frontImageReader ?: return
        val back = backImageReader ?: return

        // Acquire latest available images (non-blocking — drop frame if none available yet).
        val frontImage = try { front.acquireLatestImage() } catch (_: Throwable) { null }
        val backImage = try { back.acquireLatestImage() } catch (_: Throwable) { null }

        try {
            val frontAhb = frontImage?.hardwareBuffer
            val backAhb = backImage?.hardwareBuffer
            try {
                // Only composite when both camera frames are available.
                if (frontAhb != null && backAhb != null) {
                    val ok = VanguardNativeBridge.nativeDualCamCompositeFrame(
                        handle,
                        frontAhb,
                        backAhb,
                        layoutJson,
                    )
                    if (!ok) {
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
    }

    private fun renderFrameGles(handle: Long, layoutJson: String) {
        val frontSt = frontSurfaceTexture ?: return
        val backSt = backSurfaceTexture ?: return

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
    }

    // ── Private: layout JSON serialization ─────────────────────────────────

    private fun buildLayoutJson(params: LayoutParams): String {
        // Matches the strict resolver in the existing JNI code (ParseLayoutJson).
        // pipCenterX/pipCenterY are passed unconditionally; the C++ side uses
        // them only when anchor == "freeFloating".
        return """{"layoutMode":"${params.layoutMode}","pipAnchor":"${params.anchor}","splitDirection":"${params.splitDirection}","splitRatio":${params.splitRatio},"pipWidthFraction":${params.pipWidthFraction},"pipCenterX":${params.pipCenterX},"pipCenterY":${params.pipCenterY}}"""
    }

    // ── finalize guard ──────────────────────────────────────────────────────

    protected fun finalize() {
        if (!stopped.get()) {
            Log.w(TAG, "finalize() called without stop() — calling stop() defensively")
            stop()
        }
    }
}
