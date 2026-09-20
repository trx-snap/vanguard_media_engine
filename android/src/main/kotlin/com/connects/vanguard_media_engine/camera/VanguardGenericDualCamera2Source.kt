package com.connects.vanguard_media_engine.camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.util.Size
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * VanguardGenericDualCamera2Source
 *
 * Direct Camera2 concurrent dual-camera preview capture source.
 *
 * Bypasses CameraX's hard-coded dependency on `CameraManager.concurrentCameraIds`
 * and directly allocates, configures, and streams two independent Camera2 pipelines
 * (Front + Back) into Flutter [TextureRegistry.SurfaceTextureEntry]s.
 *
 * Used for devices whose hardware ISP supports dual-camera streaming but whose
 * vendor HAL omitted the `concurrentCameraIds` table (e.g. Samsung Galaxy A/S series,
 * Xiaomi, OnePlus).
 */
class VanguardGenericDualCamera2Source(
    private val context: Context,
    private val frontTextureEntry: TextureRegistry.SurfaceTextureEntry? = null,
    private val backTextureEntry: TextureRegistry.SurfaceTextureEntry? = null,
    private val frontCameraId: String = "1",
    private val backCameraId: String = "0",
    private val targetWidth: Int = 1080,
    private val targetHeight: Int = 1920,
    // Compositor-provided external surfaces — when non-null, bypass SurfaceTextureEntry entirely.
    // The compositor owns sizing and lifecycle of these surfaces; this source must not
    // call setDefaultBufferSize() or release() on them.
    private val externalFrontSurface: Surface? = null,
    private val externalBackSurface: Surface? = null,
) : IVanguardDualCameraSource {

    companion object {
        private const val TAG = "VanguardGenericDualCam"
        private const val OPEN_TIMEOUT_SECONDS = 4L
        private const val SESSION_TIMEOUT_SECONDS = 4L
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    // Background thread for Camera2 operations
    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null

    // Dual Stream State
    private var isRunning = false
    private var isStarting = false
    @Volatile private var stopRequested = false

    // Front Camera resources
    private var frontCameraDevice: CameraDevice? = null
    private var frontCaptureSession: CameraCaptureSession? = null
    private var frontSurface: Surface? = null

    // Back Camera resources
    private var backCameraDevice: CameraDevice? = null
    private var backCaptureSession: CameraCaptureSession? = null
    private var backSurface: Surface? = null

    // True when this source streams into compositor-owned external surfaces instead
    // of allocating its own Surfaces from Flutter SurfaceTextureEntry instances.
    private val usingExternalSurfaces = externalFrontSurface != null && externalBackSurface != null

    override val running: Boolean get() = isRunning
    override val frontTextureId: Long get() = frontTextureEntry?.id() ?: -1L
    override val backTextureId: Long get() = backTextureEntry?.id() ?: -1L

    @SuppressLint("MissingPermission")
    override fun start(
        onStarted: (Map<String, Any>) -> Unit,
        onError: (Exception) -> Unit,
    ) {
        if (isRunning || isStarting) {
            Log.w(TAG, "start() called while already running or starting — ignored")
            return
        }

        stopRequested = false
        isStarting = true
        Log.i(TAG, "start() — Front: $frontCameraId, Back: $backCameraId (${targetWidth}x$targetHeight)")

        ensureCameraThread()
        val handler = cameraHandler ?: Handler(Looper.getMainLooper())

        Thread {
            val frontOpenLatch = CountDownLatch(1)
            val backOpenLatch = CountDownLatch(1)
            val openFailed = AtomicBoolean(false)
            var failureMessage: String? = null

            // 1. Open Front Camera
            try {
                cameraManager.openCamera(frontCameraId, object : CameraDevice.StateCallback() {
                    override fun onOpened(camera: CameraDevice) {
                        Log.i(TAG, "Front camera $frontCameraId opened")
                        frontCameraDevice = camera
                        frontOpenLatch.countDown()
                    }

                    override fun onDisconnected(camera: CameraDevice) {
                        Log.w(TAG, "Front camera $frontCameraId disconnected")
                        camera.close()
                        frontCameraDevice = null
                        openFailed.set(true)
                        failureMessage = "Front camera $frontCameraId disconnected"
                        frontOpenLatch.countDown()
                    }

                    override fun onError(camera: CameraDevice, error: Int) {
                        Log.e(TAG, "Front camera $frontCameraId error: $error")
                        camera.close()
                        frontCameraDevice = null
                        openFailed.set(true)
                        failureMessage = "Front camera $frontCameraId error code=$error"
                        frontOpenLatch.countDown()
                    }
                }, handler)
            } catch (t: Throwable) {
                Log.e(TAG, "openCamera front $frontCameraId failed: ${t.message}", t)
                openFailed.set(true)
                failureMessage = "Failed to open front camera $frontCameraId: ${t.message}"
                frontOpenLatch.countDown()
            }

            // 2. Open Back Camera
            try {
                cameraManager.openCamera(backCameraId, object : CameraDevice.StateCallback() {
                    override fun onOpened(camera: CameraDevice) {
                        Log.i(TAG, "Back camera $backCameraId opened")
                        backCameraDevice = camera
                        backOpenLatch.countDown()
                    }

                    override fun onDisconnected(camera: CameraDevice) {
                        Log.w(TAG, "Back camera $backCameraId disconnected")
                        camera.close()
                        backCameraDevice = null
                        openFailed.set(true)
                        failureMessage = "Back camera $backCameraId disconnected"
                        backOpenLatch.countDown()
                    }

                    override fun onError(camera: CameraDevice, error: Int) {
                        Log.e(TAG, "Back camera $backCameraId error: $error")
                        camera.close()
                        backCameraDevice = null
                        openFailed.set(true)
                        failureMessage = "Back camera $backCameraId error code=$error"
                        backOpenLatch.countDown()
                    }
                }, handler)
            } catch (t: Throwable) {
                Log.e(TAG, "openCamera back $backCameraId failed: ${t.message}", t)
                openFailed.set(true)
                failureMessage = "Failed to open back camera $backCameraId: ${t.message}"
                backOpenLatch.countDown()
            }

            // Wait for both camera opens
            val frontOk = frontOpenLatch.await(OPEN_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            val backOk = backOpenLatch.await(OPEN_TIMEOUT_SECONDS, TimeUnit.SECONDS)

            if (stopRequested) {
                Log.w(TAG, "start() aborted: stop was requested during camera open")
                cleanupInternal()
                isStarting = false
                return@Thread
            }

            if (!frontOk || !backOk || openFailed.get() || frontCameraDevice == null || backCameraDevice == null) {
                val err = failureMessage ?: "Timeout opening cameras (frontOk=$frontOk, backOk=$backOk)"
                Log.e(TAG, "Dual camera open failed: $err")
                cleanupInternal()
                isStarting = false
                mainHandler.post { onError(IllegalStateException(err)) }
                return@Thread
            }

            Log.i(TAG, "Both cameras opened! Configuring preview sessions...")

            val frontSize = getBestPreviewSize(frontCameraId, targetWidth, targetHeight)
            val backSize = getBestPreviewSize(backCameraId, targetWidth, targetHeight)
            Log.i(TAG, "Preview buffer sizes: Front ${frontSize.width}x${frontSize.height}, Back ${backSize.width}x${backSize.height}")

            // Configure Front Session
            val frontDevice = frontCameraDevice!!
            val backDevice = backCameraDevice!!

            val frontSrf: Surface
            val backSrf: Surface
            if (usingExternalSurfaces) {
                // Compositor already sized and owns these surfaces — use directly.
                frontSrf = externalFrontSurface!!
                backSrf = externalBackSurface!!
                Log.i(TAG, "Using external compositor surfaces for front/back camera streams")
            } else {
                val frontTex = frontTextureEntry!!
                val frontSurfaceTexture = frontTex.surfaceTexture()
                frontSurfaceTexture.setDefaultBufferSize(frontSize.width, frontSize.height)
                frontSrf = Surface(frontSurfaceTexture).also { frontSurface = it }

                val backTex = backTextureEntry!!
                val backSurfaceTexture = backTex.surfaceTexture()
                backSurfaceTexture.setDefaultBufferSize(backSize.width, backSize.height)
                backSrf = Surface(backSurfaceTexture).also { backSurface = it }
            }

            val frontSessionLatch = CountDownLatch(1)
            val backSessionLatch = CountDownLatch(1)
            val sessionFailed = AtomicBoolean(false)

            try {
                @Suppress("DEPRECATION")
                frontDevice.createCaptureSession(listOf(frontSrf), object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        Log.i(TAG, "Front capture session configured")
                        frontCaptureSession = session
                        try {
                            val req = frontDevice.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                                addTarget(frontSrf)
                                set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                            }.build()
                            session.setRepeatingRequest(req, null, handler)
                            Log.i(TAG, "Front repeating preview request active")
                        } catch (t: Throwable) {
                            Log.e(TAG, "Front repeating request error", t)
                            sessionFailed.set(true)
                        }
                        frontSessionLatch.countDown()
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        Log.e(TAG, "Front session configuration failed")
                        sessionFailed.set(true)
                        frontSessionLatch.countDown()
                    }
                }, handler)

                @Suppress("DEPRECATION")
                backDevice.createCaptureSession(listOf(backSrf), object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        Log.i(TAG, "Back capture session configured")
                        backCaptureSession = session
                        try {
                            val req = backDevice.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                                addTarget(backSrf)
                                set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                            }.build()
                            session.setRepeatingRequest(req, null, handler)
                            Log.i(TAG, "Back repeating preview request active")
                        } catch (t: Throwable) {
                            Log.e(TAG, "Back repeating request error", t)
                            sessionFailed.set(true)
                        }
                        backSessionLatch.countDown()
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        Log.e(TAG, "Back session configuration failed")
                        sessionFailed.set(true)
                        backSessionLatch.countDown()
                    }
                }, handler)

                val frontSessOk = frontSessionLatch.await(SESSION_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                val backSessOk = backSessionLatch.await(SESSION_TIMEOUT_SECONDS, TimeUnit.SECONDS)

                if (stopRequested) {
                    Log.w(TAG, "start() aborted: stop was requested during session configuration")
                    cleanupInternal()
                    isStarting = false
                    return@Thread
                }

                if (!frontSessOk || !backSessOk || sessionFailed.get()) {
                    Log.e(TAG, "Dual capture sessions failed: frontSessOk=$frontSessOk, backSessOk=$backSessOk")
                    cleanupInternal()
                    isStarting = false
                    mainHandler.post { onError(IllegalStateException("Failed to configure dual capture sessions")) }
                    return@Thread
                }

                isRunning = true
                isStarting = false
                Log.i(TAG, "SUCCESS: Generic Dual Camera streaming! Front: #${frontTextureId}, Back: #${backTextureId}")

                val resultMap: Map<String, Any> = mapOf(
                    "textureId" to frontTextureId,
                    "backTextureId" to backTextureId,
                    "outputWidth" to targetWidth,
                    "outputHeight" to targetHeight,
                    "frontBufferWidth" to frontSize.width,
                    "frontBufferHeight" to frontSize.height,
                    "backBufferWidth" to backSize.width,
                    "backBufferHeight" to backSize.height,
                    "frontDeviceId" to frontCameraId,
                    "backDeviceId" to backCameraId,
                )

                mainHandler.post { onStarted(resultMap) }

            } catch (t: Throwable) {
                Log.e(TAG, "Session creation exception", t)
                cleanupInternal()
                isStarting = false
                mainHandler.post { onError(if (t is Exception) t else Exception(t)) }
            }
        }.start()
    }

    override fun stop() {
        stopRequested = true
        Log.i(TAG, "stop() requested")
        val handler = cameraHandler
        val thread = cameraThread
        cameraThread = null
        cameraHandler = null

        if (handler != null) {
            handler.post {
                cleanupInternal()
                // Drain asynchronous framework callbacks before quitting looper
                handler.postDelayed({
                    try {
                        thread?.quitSafely()
                    } catch (t: Throwable) {
                        Log.w(TAG, "thread.quitSafely error: ${t.message}")
                    }
                }, 150)
            }
        } else {
            cleanupInternal()
            try {
                thread?.quitSafely()
            } catch (_: Throwable) {}
        }
    }

    private fun cleanupInternal() {
        try {
            frontCaptureSession?.stopRepeating()
            frontCaptureSession?.close()
        } catch (t: Throwable) { Log.w(TAG, "frontCaptureSession.close failed: ${t.message}") }
        frontCaptureSession = null

        try {
            backCaptureSession?.stopRepeating()
            backCaptureSession?.close()
        } catch (t: Throwable) { Log.w(TAG, "backCaptureSession.close failed: ${t.message}") }
        backCaptureSession = null

        try { frontCameraDevice?.close() } catch (t: Throwable) { Log.w(TAG, "frontCameraDevice.close failed: ${t.message}") }
        frontCameraDevice = null

        try { backCameraDevice?.close() } catch (t: Throwable) { Log.w(TAG, "backCameraDevice.close failed: ${t.message}") }
        backCameraDevice = null

        try { frontSurface?.release() } catch (t: Throwable) {}
        frontSurface = null

        try { backSurface?.release() } catch (t: Throwable) {}
        backSurface = null

        isRunning = false
        isStarting = false
        Log.i(TAG, "cleanupInternal: Dual camera capture sessions cleanly released")
    }

    private fun getBestPreviewSize(cameraId: String, targetW: Int, targetH: Int): Size {
        return try {
            val chars = cameraManager.getCameraCharacteristics(cameraId)
            val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val sizes = map?.getOutputSizes(SurfaceTexture::class.java) ?: return Size(targetW, targetH)
            val targetMax = maxOf(targetW, targetH)
            val targetMin = minOf(targetW, targetH)

            // 1. Exact match in sensor orientation (e.g. 1920x1080)
            val exact = sizes.firstOrNull {
                (it.width == targetMax && it.height == targetMin) || (it.width == targetMin && it.height == targetMax)
            }
            if (exact != null) return exact

            // 2. Closest 16:9 ratio >= 720p
            val targetRatio = targetMax.toDouble() / targetMin.toDouble()
            val ratioMatches = sizes.filter {
                val r = maxOf(it.width, it.height).toDouble() / minOf(it.width, it.height).toDouble()
                kotlin.math.abs(r - targetRatio) < 0.05
            }
            ratioMatches.maxByOrNull { it.width * it.height } ?: sizes[0]
        } catch (t: Throwable) {
            Log.w(TAG, "getBestPreviewSize for $cameraId error: ${t.message}")
            Size(targetW, targetH)
        }
    }

    private fun ensureCameraThread() {
        if (cameraThread == null) {
            cameraThread = HandlerThread("VanguardGenericDualCamThread").apply {
                start()
                cameraHandler = Handler(looper)
            }
        }
    }
}
