package com.connects.vanguard_media_engine.greenscreen

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.Image
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import android.view.Surface
import androidx.core.content.ContextCompat
import java.util.LinkedHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Front-camera source for the MediaPipe GPU green-screen path.
 *
 * Camera2 owns one capture session with two targets:
 *   - the preview/compositor camera preview [Surface]
 *   - an [ImageReader] created with [HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE]
 *
 * The ImageReader target feeds [AndroidGreenScreenGpuPipeline], producing
 * GPU-resident masks delivered via [onGpuMask].
 */
class AndroidGreenScreenCamera2Source(private val context: Context) {

    companion object {
        private const val TAG = "GreenScreenCam2Source"
        private const val TARGET_SHORT_SIDE = 256
        private const val MAX_IMAGES = 3
    }

    private val running = AtomicBoolean(false)
    private val stopped = AtomicBoolean(true)

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    @Volatile private var pipeline: AndroidGreenScreenGpuPipeline? = null
    @Volatile private var acquiredFrameCount: Long = 0
    @Volatile private var submittedFrameCount: Long = 0
    @Volatile private var skippedFrameCount: Long = 0
    // Thread-safe breakdown of skippedFrameCount by the pipeline's lastRejectReason,
    // reported in the stop() summary and diagnosticsSnapshot().
    private val skippedFrameCountLock = Any()
    private val skippedFrameCountByReason = LinkedHashMap<String, Long>()
    // Coalesces AndroidGreenScreenGpuPipeline.onInputCapacityAvailable posts (which can fire
    // once per released in-flight permit, from any thread) into at most one pending re-drain on
    // the camera handler at a time, so a burst of releases cannot flood the handler with posts.
    private val capacityRetryPosted = AtomicBoolean(false)

    fun start(
        targetSurface: Surface,
        onCameraFrameTransform: (rotationDegrees: Int, mirrorHorizontal: Boolean) -> Unit = { _, _ -> },
        onGpuMask: (HardwareBuffer, Int, Int, Long, ((HardwareBuffer) -> Unit)?, Int) -> Unit,
        onStarted: () -> Unit = {},
        onError: (Exception) -> Unit = {},
    ) {
        if (!running.compareAndSet(false, true)) {
            Log.w(TAG, "start() called while already running")
            return
        }
        stopped.set(false)
        acquiredFrameCount = 0
        submittedFrameCount = 0
        skippedFrameCount = 0
        synchronized(skippedFrameCountLock) {
            skippedFrameCountByReason.clear()
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            failStart(onError, IllegalStateException("Camera2 GPU green screen requires Android Q+"))
            return
        }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED) {
            failStart(onError, SecurityException("CAMERA permission not granted for Camera2 GPU green screen"))
            return
        }
        if (!targetSurface.isValid) {
            failStart(onError, IllegalStateException("Target preview surface is invalid"))
            return
        }

        val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        if (cameraManager == null) {
            failStart(onError, IllegalStateException("CameraManager unavailable"))
            return
        }
        val cameraId = try {
            frontCameraId(cameraManager)
        } catch (t: Throwable) {
            failStart(onError, IllegalStateException("No front camera available", t))
            return
        }

        // Derive the front camera's display transform from its own characteristics
        // (sensor mounting angle) so the compositor can correct the live camera feed instead of
        // rendering it sideways/unmirrored. Best-effort: a read failure
        // degrades to identity (0 deg) rather than failing start().
        val sensorOrientation = try {
            cameraManager.getCameraCharacteristics(cameraId).get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        } catch (t: Throwable) {
            Log.w(TAG, "SENSOR_ORIENTATION($cameraId) read failed: ${t.javaClass.simpleName}: ${t.message}")
            0
        }
        // The ImageReader delivers frames in raw sensor space, and the compositor
        // expects the rotation to apply as the sensor's own mounting angle (verified against
        // a physical-device proof: sensorOrientation=270 requires rotation=270 to land upright).
        val cameraRotationDegrees = normalizeCameraRotationDegrees(sensorOrientation)
        val cameraMirrorHorizontal = true // frontCameraId() only ever selects LENS_FACING_FRONT.
        Log.i(
            TAG,
            "ANDROID_GREENSCREEN_CAMERA2_SOURCE_TRANSFORM cameraId=$cameraId " +
                "sensorOrientation=$sensorOrientation cameraRotationDegrees=$cameraRotationDegrees " +
                "mirror=$cameraMirrorHorizontal",
        )
        onCameraFrameTransform(cameraRotationDegrees, true)

        val analysisSize = try {
            chooseAnalysisSize(cameraManager, cameraId)
        } catch (t: Throwable) {
            Log.w(TAG, "chooseAnalysisSize failed; falling back to 320x240", t)
            Size(320, 240)
        }

        val ht = HandlerThread("vg.greenscreen.cam2")
        ht.start()
        val h = Handler(ht.looper)
        thread = ht
        handler = h

        val reader = try {
            ImageReader.newInstance(
                analysisSize.width,
                analysisSize.height,
                ImageFormat.YUV_420_888,
                MAX_IMAGES,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )
        } catch (t: Throwable) {
            failStart(onError, IllegalStateException("ImageReader GPU target creation failed", t))
            return
        }
        imageReader = reader

        val pipe = AndroidGreenScreenGpuPipeline(
            context = context.applicationContext ?: context,
            widthPx = analysisSize.width,
            heightPx = analysisSize.height,
            modelSelection = 1,
            enableMaskBufferPool = true,
            onInputCapacityAvailable = { onPipelineInputCapacityAvailable() },
            onGpuMask = onGpuMask,
        )
        if (!pipe.open()) {
            failStart(onError, IllegalStateException("MediaPipe GPU graph pipeline failed to open"))
            return
        }
        pipeline = pipe

        reader.setOnImageAvailableListener({ availableReader ->
            drainLatestImage(availableReader)
        }, h)

        try {
            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    if (stopped.get()) {
                        camera.close()
                        return
                    }
                    cameraDevice = camera
                    configureSession(camera, targetSurface, reader.surface, h, onStarted, onError)
                }

                override fun onDisconnected(camera: CameraDevice) {
                    Log.w(TAG, "Camera2 GPU source disconnected")
                    camera.close()
                    if (!stopped.get()) onError(IllegalStateException("Camera2 GPU source disconnected"))
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    Log.w(TAG, "Camera2 GPU source error=$error")
                    camera.close()
                    if (!stopped.get()) onError(IllegalStateException("Camera2 GPU source error=$error"))
                }
            }, h)
        } catch (e: Exception) {
            failStart(onError, e)
        }
    }

    fun stop() {
        stopped.set(true)
        running.set(false)
        try { imageReader?.setOnImageAvailableListener(null, null) } catch (_: Throwable) {}
        try { captureSession?.stopRepeating() } catch (_: Throwable) {}
        try { captureSession?.abortCaptures() } catch (_: Throwable) {}
        try { captureSession?.close() } catch (_: Throwable) {}
        try { cameraDevice?.close() } catch (_: Throwable) {}
        try { imageReader?.close() } catch (_: Throwable) {}
        try { pipeline?.close() } catch (_: Throwable) {}
        captureSession = null
        cameraDevice = null
        imageReader = null
        pipeline = null
        val ht = thread
        thread = null
        handler = null
        try {
            ht?.quitSafely()
            ht?.join(500)
        } catch (_: Throwable) {
        }
        val skipReasons = synchronized(skippedFrameCountLock) {
            skippedFrameCountByReason.entries.joinToString(",") { "${it.key}:${it.value}" }
        }
        Log.i(
            TAG,
            "ANDROID_GREENSCREEN_CAMERA2_SOURCE_SUMMARY " +
                "acquired=$acquiredFrameCount submitted=$submittedFrameCount skipped=$skippedFrameCount " +
                "skipReasons=[$skipReasons]",
        )
        Log.d(TAG, "ANDROID_GREENSCREEN_CAMERA2_SOURCE_CLOSE_PASS")
    }

    /**
     * Returns a point-in-time snapshot of runtime diagnostics for this camera source.
     * Safe to call while running or after stop. Does not mutate state or block on media work.
     */
    fun diagnosticsSnapshot(): Map<String, Any?> {
        val snapshot = LinkedHashMap<String, Any?>()
        snapshot["proofLevel"] = "android_green_screen_camera2_gpu_source_v1"
        snapshot["source"] = "camera2_front_gpu_hardwarebuffer"
        snapshot["running"] = running.get()
        snapshot["stopped"] = stopped.get()
        snapshot["acquiredFrameCount"] = acquiredFrameCount
        snapshot["submittedFrameCount"] = submittedFrameCount
        snapshot["skippedFrameCount"] = skippedFrameCount
        val skipReasonsCopy: Map<String, Long> = synchronized(skippedFrameCountLock) {
            LinkedHashMap(skippedFrameCountByReason)
        }
        snapshot["skipReasons"] = skipReasonsCopy
        snapshot["pipeline"] = pipeline?.diagnosticsSnapshot()
        return snapshot
    }

    private fun configureSession(
        camera: CameraDevice,
        previewSurface: Surface,
        analysisSurface: Surface,
        handler: Handler,
        onStarted: () -> Unit,
        onError: (Exception) -> Unit,
    ) {
        try {
            camera.createCaptureSession(
                listOf(previewSurface, analysisSurface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        if (stopped.get()) {
                            session.close()
                            return
                        }
                        captureSession = session
                        try {
                            val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                                addTarget(previewSurface)
                                addTarget(analysisSurface)
                                set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                            }.build()
                            session.setRepeatingRequest(request, null, handler)
                            Log.i(TAG, "ANDROID_GREENSCREEN_CAMERA2_SOURCE_STARTED")
                            onStarted()
                        } catch (e: Exception) {
                            onError(e)
                        }
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        onError(IllegalStateException("Camera2 GPU source session configure failed"))
                    }
                },
                handler,
            )
        } catch (e: Exception) {
            onError(e)
        }
    }

    private fun drainLatestImage(reader: ImageReader) {
        // Camera-pressure fix: check pipeline capacity BEFORE acquireLatestImage(), not after.
        // The ImageReader has only MAX_IMAGES(3) slots; acquiring an Image the pipeline cannot
        // accept yet (MAX_INPUT_IN_FLIGHT already owned by MediaPipe) leaves it unclosed until a
        // later drain, and enough of those in flight makes the next acquireLatestImage() throw
        // IllegalStateException("maxImages has already been acquired"), starving the stream.
        val currentPipeline = pipeline
        if (currentPipeline != null && !currentPipeline.canAcceptCameraInput()) {
            skippedFrameCount += 1
            val reason = "input_capacity_full"
            synchronized(skippedFrameCountLock) {
                skippedFrameCountByReason[reason] = (skippedFrameCountByReason[reason] ?: 0L) + 1L
            }
            Log.v(TAG, "GPU graph frame skipped before acquire: $reason")
            return
        }
        var image: Image? = null
        var frameOwnership: CameraFrameOwnership? = null
        var handoffAccepted = false
        try {
            image = reader.acquireLatestImage() ?: return
            acquiredFrameCount += 1
            val buffer = image.hardwareBuffer
            if (buffer == null) {
                Log.v(TAG, "ImageReader frame has no HardwareBuffer")
                return
            }
            frameOwnership = CameraFrameOwnership(image, buffer)
            val pipe = pipeline ?: run {
                return
            }
            val owner = frameOwnership
            val submitted = pipe.processCameraHardwareBufferAsync(
                cameraHardwareBuffer = buffer,
                widthPx = image.width,
                heightPx = image.height,
                timestampUs = image.timestamp / 1_000L,
            ) {
                owner.close()
            }
            if (!submitted) {
                skippedFrameCount += 1
                val reason = pipe.lastRejectReason
                synchronized(skippedFrameCountLock) {
                    skippedFrameCountByReason[reason] = (skippedFrameCountByReason[reason] ?: 0L) + 1L
                }
                // Verbose only: per-frame skips are expected under MediaPipe
                // backpressure; the aggregate lands in the stop() summary.
                Log.v(TAG, "GPU graph frame skipped: $reason")
            } else {
                handoffAccepted = true
                submittedFrameCount += 1
            }
        } catch (t: Throwable) {
            Log.w(TAG, "drainLatestImage failed: ${t.javaClass.simpleName}: ${t.message}", t)
        } finally {
            if (!handoffAccepted) {
                frameOwnership?.close()
            } else {
                image = null
            }
            try { image?.close() } catch (_: Throwable) {}
        }
    }

    /**
     * [AndroidGreenScreenGpuPipeline.onInputCapacityAvailable] callback: capacity may have
     * freed up, so post one coalesced re-drain of the current [imageReader] back onto the camera
     * handler thread. Runs from whatever thread released the permit (MediaPipe's callback thread
     * or the GL worker); [capacityRetryPosted] ensures at most one pending post regardless of how
     * many permits release in a burst.
     */
    private fun onPipelineInputCapacityAvailable() {
        if (!capacityRetryPosted.compareAndSet(false, true)) return
        val h = handler
        if (h == null) {
            capacityRetryPosted.set(false)
            return
        }
        val posted = try {
            h.post {
                capacityRetryPosted.set(false)
                if (stopped.get() || !running.get()) return@post
                val reader = imageReader ?: return@post
                drainLatestImage(reader)
            }
        } catch (t: Throwable) {
            false
        }
        if (!posted) {
            capacityRetryPosted.set(false)
        }
    }

    private class CameraFrameOwnership(
        private val image: Image,
        private val hardwareBuffer: HardwareBuffer,
    ) {
        private val closed = AtomicBoolean(false)

        fun close() {
            if (!closed.compareAndSet(false, true)) return
            try { hardwareBuffer.close() } catch (_: Throwable) {}
            try { image.close() } catch (_: Throwable) {}
        }
    }

    private fun failStart(onError: (Exception) -> Unit, error: Exception) {
        Log.w(TAG, "start failed: ${error.message}", error)
        stop()
        onError(error)
    }

    /** Normalizes any integer degrees to a cardinal 0/90/180/270 value; anything else maps to 0. */
    private fun normalizeCameraRotationDegrees(degrees: Int): Int {
        return when (((degrees % 360) + 360) % 360) {
            0 -> 0
            90 -> 90
            180 -> 180
            270 -> 270
            else -> 0
        }
    }

    private fun frontCameraId(cameraManager: CameraManager): String {
        for (id in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(id)
            if (chars.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT) {
                return id
            }
        }
        throw IllegalStateException("No front-facing camera")
    }

    private fun chooseAnalysisSize(cameraManager: CameraManager, cameraId: String): Size {
        val map = cameraManager
            .getCameraCharacteristics(cameraId)
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: return Size(320, 240)
        val sizes = map.getOutputSizes(ImageFormat.YUV_420_888)?.toList().orEmpty()
        if (sizes.isEmpty()) return Size(320, 240)
        return sizes.minWithOrNull(
            compareBy<Size> { kotlin.math.abs(minOf(it.width, it.height) - TARGET_SHORT_SIDE) }
                .thenBy { it.width * it.height }
        ) ?: Size(320, 240)
    }
}
