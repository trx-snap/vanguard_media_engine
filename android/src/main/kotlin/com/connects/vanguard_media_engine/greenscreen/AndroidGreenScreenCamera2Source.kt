package com.connects.vanguard_media_engine.greenscreen

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Front-camera source for the independent, tracked-assets-only green-screen segmentation path.
 *
 * Camera2 owns one capture session with two targets:
 *   - the preview/compositor camera preview [Surface]
 *   - a CPU-plane-readable [ImageReader] (YUV_420_888, no HardwareBuffer usage flags)
 *
 * The ImageReader target feeds [AndroidGreenScreenCleanSegmentationPipeline] directly with each
 * acquired [Image] (never wrapped as an `androidx.camera.core.ImageProxy` — that wrapping was
 * proven on physical SM-A566B hardware to make CameraX/ML Kit's ImageProxy handling recurse into a
 * native StackOverflowError), which runs the same production segmentation ladder as Duet
 * (mediapipe_cpu -> mlkit) and delivers CPU mask frames via [onMask]. This path never opens the
 * MediaPipe GPU graph or its untracked binary graph / JNI library.
 *
 * [analysisEnabled] (default true, preserving every behavior above) selects whether the CPU
 * analysis target exists at all. With `false` (used when the preview backend performs its own
 * segmentation, e.g. AndroidGreenScreenGpuResidentPreviewBackend) the capture session has the
 * preview Surface as its only target: no ImageReader is created, no
 * [AndroidGreenScreenCleanSegmentationPipeline] is opened, and `onMask` is never invoked.
 */
class AndroidGreenScreenCamera2Source(
    private val context: Context,
    private val analysisEnabled: Boolean = true,
) {

    companion object {
        private const val TAG = "GreenScreenCam2Source"
        private const val MAX_IMAGES = 3

        /**
         * Analysis geometry target, matching the proven meshed Duet green-screen path
         * (see AndroidDuetCameraSource's ImageAnalysis ResolutionSelector: 16:9 aspect-ratio
         * family + ResolutionStrategy(Size(256, 144), FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)),
         * so this independent Camera2 path's analysis stream sees the same field of view as the
         * live preview instead of a 4:3 crop with a different FOV.
         */
        private const val TARGET_ANALYSIS_WIDTH = 256
        private const val TARGET_ANALYSIS_HEIGHT = 144
        private val TARGET_ANALYSIS_SIZE = Size(TARGET_ANALYSIS_WIDTH, TARGET_ANALYSIS_HEIGHT)

        /** Tolerance (relative) around the 16:9 ratio used to classify a Size as "16:9 family". */
        private const val SIXTEEN_BY_NINE_RATIO_TOLERANCE = 0.08

        /**
         * Bounded wait, per close callback, for Camera2's async session/device onClosed dispatch
         * to drain on the handler thread before stop() quits/joins that thread. Camera2 posts
         * these close callbacks (e.g. CameraDeviceImpl$ClientStateCallback.onClosed) to the same
         * Handler passed to openCamera()/createCaptureSession(); quitting that thread's Looper
         * before they run makes the late post crash with "Handler sending message to a Handler on
         * a dead thread". Kept short so stop() stays bounded, not indefinite.
         */
        private const val CLOSE_DRAIN_TIMEOUT_MS = 300L
    }

    private val running = AtomicBoolean(false)
    private val stopped = AtomicBoolean(true)

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    // Counted down by the corresponding StateCallback.onClosed(), which Camera2 dispatches
    // asynchronously on the handler thread; stop() awaits these (bounded) before quitting it.
    @Volatile private var cameraCloseLatch: CountDownLatch? = null
    @Volatile private var sessionCloseLatch: CountDownLatch? = null
    @Volatile private var pipeline: AndroidGreenScreenCleanSegmentationPipeline? = null
    @Volatile private var cameraRotationDegrees: Int = 0
    @Volatile private var acquiredFrameCount: Long = 0
    @Volatile private var submittedFrameCount: Long = 0
    @Volatile private var skippedFrameCount: Long = 0
    // Thread-safe breakdown of skippedFrameCount by the pipeline's lastRejectReason,
    // reported in the stop() summary and diagnosticsSnapshot().
    private val skippedFrameCountLock = Any()
    private val skippedFrameCountByReason = LinkedHashMap<String, Long>()

    fun start(
        targetSurface: Surface,
        onCameraFrameTransform: (rotationDegrees: Int, mirrorHorizontal: Boolean) -> Unit = { _, _ -> },
        onMask: (AndroidGreenScreenSegmentationFrame) -> Unit,
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
            failStart(onError, IllegalStateException("Camera2 green screen requires Android Q+"))
            return
        }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED) {
            failStart(onError, SecurityException("CAMERA permission not granted for Camera2 green screen"))
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
        cameraRotationDegrees = normalizeCameraRotationDegrees(sensorOrientation)
        val cameraMirrorHorizontal = true // frontCameraId() only ever selects LENS_FACING_FRONT.
        Log.i(
            TAG,
            "ANDROID_GREENSCREEN_CAMERA2_SOURCE_TRANSFORM cameraId=$cameraId " +
                "sensorOrientation=$sensorOrientation cameraRotationDegrees=$cameraRotationDegrees " +
                "mirror=$cameraMirrorHorizontal",
        )
        onCameraFrameTransform(cameraRotationDegrees, true)

        val ht = HandlerThread("vg.greenscreen.cam2")
        ht.start()
        val h = Handler(ht.looper)
        thread = ht
        handler = h

        // CPU analysis target (ImageReader + clean segmentation pipeline) only
        // when analysis is enabled. Preview-only mode (analysisEnabled=false)
        // creates neither and never calls onMask.
        var analysisSurface: Surface? = null
        if (analysisEnabled) {
            val analysisSize = try {
                chooseAnalysisSize(cameraManager, cameraId)
            } catch (t: Throwable) {
                Log.w(TAG, "chooseAnalysisSize failed; falling back to $TARGET_ANALYSIS_SIZE", t)
                TARGET_ANALYSIS_SIZE
            }

            val reader = try {
                ImageReader.newInstance(
                    analysisSize.width,
                    analysisSize.height,
                    ImageFormat.YUV_420_888,
                    MAX_IMAGES,
                )
            } catch (t: Throwable) {
                failStart(onError, IllegalStateException("ImageReader target creation failed", t))
                return
            }
            imageReader = reader

            val pipe = AndroidGreenScreenCleanSegmentationPipeline(
                context = context.applicationContext ?: context,
                onMask = onMask,
            )
            if (!pipe.open()) {
                failStart(onError, IllegalStateException("Green screen segmentation pipeline failed to open"))
                return
            }
            pipeline = pipe

            reader.setOnImageAvailableListener({ availableReader ->
                drainLatestImage(availableReader)
            }, h)
            analysisSurface = reader.surface
        } else {
            Log.i(TAG, "ANDROID_GREENSCREEN_CAMERA2_SOURCE_PREVIEW_ONLY analysisEnabled=false")
        }

        try {
            cameraCloseLatch = CountDownLatch(1)
            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    if (stopped.get()) {
                        camera.close()
                        return
                    }
                    cameraDevice = camera
                    configureSession(camera, targetSurface, analysisSurface, h, onStarted, onError)
                }

                override fun onDisconnected(camera: CameraDevice) {
                    Log.w(TAG, "Camera2 green screen source disconnected")
                    camera.close()
                    if (!stopped.get()) onError(IllegalStateException("Camera2 green screen source disconnected"))
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    Log.w(TAG, "Camera2 green screen source error=$error")
                    camera.close()
                    if (!stopped.get()) onError(IllegalStateException("Camera2 green screen source error=$error"))
                }

                override fun onClosed(camera: CameraDevice) {
                    cameraCloseLatch?.countDown()
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
        // Camera2 dispatches the corresponding onClosed() callbacks asynchronously on the
        // handler thread below; drain them here (bounded) before quitting/joining that thread,
        // or the late dispatch posts to a dead Handler and crashes.
        try { sessionCloseLatch?.await(CLOSE_DRAIN_TIMEOUT_MS, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) {}
        try { cameraCloseLatch?.await(CLOSE_DRAIN_TIMEOUT_MS, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) {}
        try { imageReader?.close() } catch (_: Throwable) {}
        try { pipeline?.close() } catch (_: Throwable) {}
        captureSession = null
        cameraDevice = null
        imageReader = null
        pipeline = null
        cameraCloseLatch = null
        sessionCloseLatch = null
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
        snapshot["proofLevel"] = "android_green_screen_camera2_clean_segmentation_source_v1"
        snapshot["source"] = if (analysisEnabled) "camera2_front_clean_segmentation_cpu" else "camera2_front_preview_only"
        snapshot["analysisEnabled"] = analysisEnabled
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

    /** [analysisSurface] is null in preview-only mode (analysisEnabled=false): the preview Surface is the sole target. */
    private fun configureSession(
        camera: CameraDevice,
        previewSurface: Surface,
        analysisSurface: Surface?,
        handler: Handler,
        onStarted: () -> Unit,
        onError: (Exception) -> Unit,
    ) {
        try {
            sessionCloseLatch = CountDownLatch(1)
            camera.createCaptureSession(
                listOfNotNull(previewSurface, analysisSurface),
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
                                if (analysisSurface != null) addTarget(analysisSurface)
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
                        onError(IllegalStateException("Camera2 green screen source session configure failed"))
                    }

                    override fun onClosed(session: CameraCaptureSession) {
                        sessionCloseLatch?.countDown()
                    }
                },
                handler,
            )
        } catch (e: Exception) {
            onError(e)
        }
    }

    private fun drainLatestImage(reader: ImageReader) {
        // Check pipeline capacity BEFORE acquireLatestImage(), not after. The ImageReader has
        // only MAX_IMAGES(3) slots; acquiring an Image the pipeline cannot accept yet (busy with
        // the single in-flight frame) leaves it unclosed until a later drain, and enough of those
        // in flight makes the next acquireLatestImage() throw
        // IllegalStateException("maxImages has already been acquired"), starving the stream.
        val currentPipeline = pipeline
        if (currentPipeline == null || !currentPipeline.canAcceptCameraInput()) {
            skippedFrameCount += 1
            val reason = if (currentPipeline == null) "pipeline_missing" else "input_capacity_full"
            synchronized(skippedFrameCountLock) {
                skippedFrameCountByReason[reason] = (skippedFrameCountByReason[reason] ?: 0L) + 1L
            }
            Log.v(TAG, "clean segmentation frame skipped before acquire: $reason")
            return
        }
        var image: Image? = null
        var handoffAccepted = false
        try {
            val acquired = reader.acquireLatestImage() ?: return
            image = acquired
            acquiredFrameCount += 1
            val timestampMs = acquired.timestamp / 1_000_000L
            val submitted = currentPipeline.processImageAsync(
                image = acquired,
                rotationDegrees = cameraRotationDegrees,
                timestampMs = timestampMs,
            ) {
                try { acquired.close() } catch (_: Throwable) {}
            }
            if (!submitted) {
                skippedFrameCount += 1
                val reason = currentPipeline.lastRejectReason
                synchronized(skippedFrameCountLock) {
                    skippedFrameCountByReason[reason] = (skippedFrameCountByReason[reason] ?: 0L) + 1L
                }
                // Verbose only: per-frame skips are expected under normal single-in-flight
                // backpressure; the aggregate lands in the stop() summary.
                Log.v(TAG, "clean segmentation frame skipped: $reason")
            } else {
                handoffAccepted = true
                submittedFrameCount += 1
            }
        } catch (t: Throwable) {
            Log.w(TAG, "drainLatestImage failed: ${t.javaClass.simpleName}: ${t.message}", t)
        } finally {
            if (!handoffAccepted) {
                try { image?.close() } catch (_: Throwable) {}
            }
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

    /**
     * Selects the YUV_420_888 analysis output size using the same geometry policy as the proven
     * meshed Duet path (AndroidDuetCameraSource.bindPreview()'s analysisResolutionSelector):
     * prefer the 16:9 aspect-ratio family, target [TARGET_ANALYSIS_SIZE] (256x144), and pick the
     * closest supported 16:9 size using closest-higher-then-lower behavior. Only when no 16:9-ish
     * size is available at all does this fall back to the closest size by aspect-ratio distance
     * across every supported size (logged as a warning) — 4:3 is never silently preferred over an
     * available 16:9 option.
     */
    private fun chooseAnalysisSize(cameraManager: CameraManager, cameraId: String): Size {
        val map = cameraManager
            .getCameraCharacteristics(cameraId)
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: return TARGET_ANALYSIS_SIZE
        val sizes = map.getOutputSizes(ImageFormat.YUV_420_888)?.toList().orEmpty()
        if (sizes.isEmpty()) return TARGET_ANALYSIS_SIZE

        val sixteenByNineSizes = sizes.filter { isSixteenByNineFamily(it) }
        val chosen = if (sixteenByNineSizes.isNotEmpty()) {
            pickClosestToTargetSize(sixteenByNineSizes)
        } else {
            Log.w(
                TAG,
                "chooseAnalysisSize: no 16:9-family YUV_420_888 size among $sizes; " +
                    "falling back to closest-aspect-ratio selection instead of 4:3",
            )
            pickClosestByAspectRatio(sizes)
        }
        val result = chosen ?: TARGET_ANALYSIS_SIZE
        Log.i(TAG, "ANDROID_GREENSCREEN_CAMERA2_SOURCE_ANALYSIS_SIZE chosen=$result target=$TARGET_ANALYSIS_SIZE")
        return result
    }

    private fun isSixteenByNineFamily(size: Size): Boolean {
        val ratio = size.width.toDouble() / size.height.toDouble()
        val targetRatio = TARGET_ANALYSIS_WIDTH.toDouble() / TARGET_ANALYSIS_HEIGHT.toDouble()
        return kotlin.math.abs(ratio - targetRatio) <= SIXTEEN_BY_NINE_RATIO_TOLERANCE
    }

    /**
     * Among [candidates] (already filtered to the 16:9 family), picks the smallest size whose
     * width is >= [TARGET_ANALYSIS_WIDTH] (closest from above); if none qualify, picks the
     * largest size below the target width (closest from below). Mirrors CameraX's
     * ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER used by the proven Duet path.
     */
    private fun pickClosestToTargetSize(candidates: List<Size>): Size? {
        val higherOrEqual = candidates
            .filter { it.width >= TARGET_ANALYSIS_WIDTH }
            .minWithOrNull(compareBy({ it.width }, { it.height }))
        if (higherOrEqual != null) return higherOrEqual
        return candidates
            .filter { it.width < TARGET_ANALYSIS_WIDTH }
            .maxWithOrNull(compareBy({ it.width }, { it.height }))
    }

    /** Fallback used only when no 16:9-family size exists at all: closest size by aspect-ratio distance to the target. */
    private fun pickClosestByAspectRatio(candidates: List<Size>): Size? {
        val targetRatio = TARGET_ANALYSIS_WIDTH.toDouble() / TARGET_ANALYSIS_HEIGHT.toDouble()
        return candidates.minWithOrNull(
            compareBy<Size> { kotlin.math.abs((it.width.toDouble() / it.height.toDouble()) - targetRatio) }
                .thenBy { kotlin.math.abs(it.width * it.height - TARGET_ANALYSIS_WIDTH * TARGET_ANALYSIS_HEIGHT) }
        )
    }
}
