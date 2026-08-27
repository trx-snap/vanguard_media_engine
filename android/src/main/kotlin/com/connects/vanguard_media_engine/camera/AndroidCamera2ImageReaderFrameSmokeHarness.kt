package com.connects.vanguard_media_engine.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.util.Size
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Phase 3-Unit I: diagnostic-only Android Camera2 single-camera ImageReader
 * frame smoke harness.
 *
 * Opens exactly one Camera2 device, configures a single YUV_420_888
 * [ImageReader] capture session, receives one image, closes it, and tears
 * down session/device/reader deterministically when CAMERA is already
 * granted. Never creates a SurfaceTexture, Flutter Texture, MediaRecorder,
 * CameraX session, preview UI, or permission UI, and never uses
 * PRIVATE/HardwareBuffer output. Diagnostic/capability foundation only.
 */
class AndroidCamera2ImageReaderFrameSmokeHarness(private val context: Context) {

    companion object {
        private const val TAG = "AndroidCamera2ImageReaderFrameSmokeHarness"
        private const val DEFAULT_TIMEOUT_MS = 8000L
        private const val MIN_TIMEOUT_MS = 2000L
        private const val MAX_TIMEOUT_MS = 20000L
        private const val DEFAULT_MAX_WIDTH = 640
        private const val DEFAULT_MAX_HEIGHT = 480
        private const val MIN_DIMENSION = 160
        private const val MAX_DIMENSION = 1920
        private const val CLOSE_WAIT_MS = 2000L
        private const val IMAGE_READER_MAX_IMAGES = 2
    }

    fun run(args: Map<*, *>?): Map<String, Any?> {
        val startElapsed = SystemClock.elapsedRealtime()
        val apiLevel = Build.VERSION.SDK_INT
        val hasCameraPermission = hasCameraPermission()
        val requestedCameraId = (args?.get("cameraId") as? String)?.trim()
        val timeoutMs = clampLong((args?.get("timeoutMs") as? Number)?.toLong(), DEFAULT_TIMEOUT_MS, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
        val maxWidth = clampInt((args?.get("maxWidth") as? Number)?.toInt(), DEFAULT_MAX_WIDTH, MIN_DIMENSION, MAX_DIMENSION)
        val maxHeight = clampInt((args?.get("maxHeight") as? Number)?.toInt(), DEFAULT_MAX_HEIGHT, MIN_DIMENSION, MAX_DIMENSION)

        val events = mutableListOf<String>()
        val reasons = mutableListOf<String>()
        val diagnostics = mutableMapOf<String, Any?>()

        var attemptedOpen = false
        var selectedCameraId: String? = null
        var selectedLensFacing = "unknown"
        var selectedWidth = 0
        var selectedHeight = 0

        fun buildResult(
            decision: String,
            opened: Boolean = false,
            sessionConfigured: Boolean = false,
            repeatingStarted: Boolean = false,
            frameReceived: Boolean = false,
            imageClosed: Boolean = false,
            sessionClosed: Boolean = false,
            deviceClosed: Boolean = false,
            imageReaderClosed: Boolean = false,
            frameTimestampNs: Long? = null,
            framePlaneCount: Int? = null,
        ): Map<String, Any?> {
            val durationMs = SystemClock.elapsedRealtime() - startElapsed
            val success = decision == "frameCaptured" &&
                frameReceived && imageClosed && sessionClosed && deviceClosed && imageReaderClosed
            Log.i(
                TAG,
                "decision=$decision success=$success attemptedOpen=$attemptedOpen opened=$opened " +
                    "frameReceived=$frameReceived cameraId=$selectedCameraId durationMs=$durationMs",
            )
            return mapOf(
                "success" to success,
                "apiLevel" to apiLevel,
                "hasCameraPermission" to hasCameraPermission,
                "attemptedOpen" to attemptedOpen,
                "opened" to opened,
                "sessionConfigured" to sessionConfigured,
                "repeatingStarted" to repeatingStarted,
                "frameReceived" to frameReceived,
                "imageClosed" to imageClosed,
                "sessionClosed" to sessionClosed,
                "deviceClosed" to deviceClosed,
                "imageReaderClosed" to imageReaderClosed,
                "cameraId" to selectedCameraId,
                "selectedLensFacing" to selectedLensFacing,
                "selectedWidth" to selectedWidth,
                "selectedHeight" to selectedHeight,
                "imageFormatName" to "YUV_420_888",
                "frameTimestampNs" to frameTimestampNs,
                "framePlaneCount" to framePlaneCount,
                "decision" to decision,
                "reasons" to reasons.toList(),
                "events" to events.toList(),
                "diagnostics" to diagnostics.toMap(),
                "durationMs" to durationMs,
            )
        }

        // Guard 1: no CameraManager.
        val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        if (cameraManager == null) {
            reasons.add("camera_manager_unavailable")
            return buildResult("cameraManagerUnavailable")
        }

        val cameraIds = try {
            cameraManager.cameraIdList.toList()
        } catch (t: Throwable) {
            Log.w(TAG, "getCameraIdList failed: ${t.javaClass.simpleName}: ${t.message}")
            diagnostics["cameraIdListError"] = "${t.javaClass.simpleName}: ${t.message}"
            emptyList()
        }

        // Guard 2: no cameras.
        if (cameraIds.isEmpty()) {
            reasons.add("no_camera_available")
            return buildResult("noCamera")
        }

        val cameraId: String = if (!requestedCameraId.isNullOrBlank()) {
            requestedCameraId
        } else {
            cameraIds.firstOrNull { lensFacingName(cameraManager, it) == "back" } ?: cameraIds.first()
        }
        selectedCameraId = cameraId
        selectedLensFacing = lensFacingName(cameraManager, cameraId)

        // Guard 3: permission absent.
        if (!hasCameraPermission) {
            reasons.add("camera_permission_absent")
            return buildResult("permissionRequired")
        }

        // Guard 4: invalid requested camera id.
        if (!requestedCameraId.isNullOrBlank() && !cameraIds.contains(requestedCameraId)) {
            reasons.add("requested_camera_id_not_found")
            return buildResult("cameraUnavailable")
        }

        // Guard 5: no YUV_420_888 output sizes.
        val characteristics = try {
            cameraManager.getCameraCharacteristics(cameraId)
        } catch (t: Throwable) {
            Log.w(TAG, "getCameraCharacteristics($cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
            diagnostics["cameraCharacteristicsError"] = "${t.javaClass.simpleName}: ${t.message}"
            null
        }
        val streamConfigurationMap = try {
            characteristics?.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        } catch (t: Throwable) {
            Log.w(TAG, "SCALER_STREAM_CONFIGURATION_MAP($cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
            diagnostics["streamConfigurationMapError"] = "${t.javaClass.simpleName}: ${t.message}"
            null
        }
        val yuvSizes = try {
            streamConfigurationMap?.getOutputSizes(ImageFormat.YUV_420_888)?.toList() ?: emptyList()
        } catch (t: Throwable) {
            Log.w(TAG, "getOutputSizes(YUV_420_888, $cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
            diagnostics["outputSizesError"] = "${t.javaClass.simpleName}: ${t.message}"
            emptyList()
        }
        val positiveYuvSizes = yuvSizes.filter { it.width > 0 && it.height > 0 }
        if (positiveYuvSizes.isEmpty()) {
            reasons.add("no_yuv_420_888_output_sizes")
            return buildResult("unsupportedStream")
        }

        val selectedSize = selectYuvSize(positiveYuvSizes, maxWidth, maxHeight)
        selectedWidth = selectedSize.width
        selectedHeight = selectedSize.height

        // All guards passed — allocate resources.
        val handlerThread = HandlerThread("VGCamera2ImageReaderFrameSmoke")
        handlerThread.start()
        val bgHandler = Handler(handlerThread.looper)
        val imageReader = ImageReader.newInstance(
            selectedWidth, selectedHeight, ImageFormat.YUV_420_888, IMAGE_READER_MAX_IMAGES,
        )

        val openLatch = CountDownLatch(1)
        val configureLatch = CountDownLatch(1)
        val frameLatch = CountDownLatch(1)
        val deviceClosedLatch = CountDownLatch(1)
        val sessionClosedLatch = CountDownLatch(1)

        val deviceRef = AtomicReference<CameraDevice?>(null)
        val sessionRef = AtomicReference<CameraCaptureSession?>(null)
        val openedFlag = AtomicBoolean(false)
        val sessionConfiguredFlag = AtomicBoolean(false)
        val repeatingStartedFlag = AtomicBoolean(false)
        val frameReceivedFlag = AtomicBoolean(false)
        val imageClosedFlag = AtomicBoolean(false)
        val sessionClosedFlag = AtomicBoolean(false)
        val deviceClosedFlag = AtomicBoolean(false)
        val imageReaderClosedFlag = AtomicBoolean(false)
        val frameTimestampNs = AtomicLong(-1L)
        val framePlaneCount = AtomicInteger(-1)
        val terminalReached = AtomicBoolean(false)
        val decisionRef = AtomicReference("openError")
        val ignoredCaptureFailuresAfterTerminal = AtomicInteger(0)

        attemptedOpen = true

        try {
            imageReader.setOnImageAvailableListener({ reader ->
                val image = try {
                    reader.acquireLatestImage()
                } catch (t: Throwable) {
                    Log.w(TAG, "acquireLatestImage failed: ${t.javaClass.simpleName}: ${t.message}")
                    null
                } ?: return@setOnImageAvailableListener
                try {
                    if (frameReceivedFlag.compareAndSet(false, true)) {
                        frameTimestampNs.set(image.timestamp)
                        framePlaneCount.set(image.planes.size)
                        events.add("onImageAvailable")
                        if (terminalReached.compareAndSet(false, true)) {
                            decisionRef.set("frameCaptured")
                        }
                    }
                } finally {
                    image.close()
                    imageClosedFlag.set(true)
                }
                frameLatch.countDown()
            }, bgHandler)

            val captureCallback = object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureFailed(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    failure: CaptureFailure,
                ) {
                    if (terminalReached.compareAndSet(false, true)) {
                        events.add("onCaptureFailed")
                        decisionRef.set("captureFailed")
                        reasons.add("capture_failed")
                        diagnostics["captureFailureReason"] = failure.reason
                    } else {
                        ignoredCaptureFailuresAfterTerminal.incrementAndGet()
                    }
                    frameLatch.countDown()
                }
            }

            val deviceStateCallback = object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    events.add("onOpened")
                    openedFlag.set(true)
                    deviceRef.set(device)
                    openLatch.countDown()
                }

                override fun onClosed(device: CameraDevice) {
                    events.add("onDeviceClosed")
                    deviceClosedFlag.set(true)
                    deviceClosedLatch.countDown()
                }

                override fun onDisconnected(device: CameraDevice) {
                    events.add("onDisconnected")
                    if (terminalReached.compareAndSet(false, true)) {
                        decisionRef.set("openDisconnected")
                        reasons.add("camera_disconnected")
                    }
                    try {
                        device.close()
                    } catch (t: Throwable) {
                        Log.w(TAG, "device.close() on disconnect failed: ${t.javaClass.simpleName}: ${t.message}")
                    }
                    openLatch.countDown()
                    deviceClosedLatch.countDown()
                    sessionClosedLatch.countDown()
                    frameLatch.countDown()
                    configureLatch.countDown()
                }

                override fun onError(device: CameraDevice, error: Int) {
                    events.add("onError:$error")
                    if (terminalReached.compareAndSet(false, true)) {
                        decisionRef.set("openError")
                        reasons.add("camera_open_error")
                        diagnostics["errorCode"] = error
                    }
                    try {
                        device.close()
                    } catch (t: Throwable) {
                        Log.w(TAG, "device.close() on error failed: ${t.javaClass.simpleName}: ${t.message}")
                    }
                    openLatch.countDown()
                    deviceClosedLatch.countDown()
                    sessionClosedLatch.countDown()
                    frameLatch.countDown()
                    configureLatch.countDown()
                }
            }

            events.add("openCameraRequested")
            try {
                cameraManager.openCamera(cameraId, deviceStateCallback, bgHandler)
            } catch (e: SecurityException) {
                reasons.add("camera_permission_absent")
                diagnostics["openCameraError"] = "${e.javaClass.simpleName}: ${e.message}"
                terminalReached.set(true)
                decisionRef.set("permissionRequired")
                openLatch.countDown()
            } catch (t: Throwable) {
                Log.w(TAG, "openCamera failed: ${t.javaClass.simpleName}: ${t.message}")
                diagnostics["openCameraError"] = "${t.javaClass.simpleName}: ${t.message}"
                reasons.add("camera_open_threw")
                terminalReached.set(true)
                decisionRef.set("openError")
                openLatch.countDown()
            }

            if (!terminalReached.get()) {
                val openedInTime = openLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
                if (!openedInTime) {
                    events.add("openTimeout")
                    if (terminalReached.compareAndSet(false, true)) {
                        decisionRef.set("openTimeout")
                        reasons.add("camera_open_timeout")
                    }
                } else if (!terminalReached.get() && openedFlag.get()) {
                    val device = deviceRef.get()
                    if (device != null) {
                        try {
                            val requestBuilder = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                            requestBuilder.addTarget(imageReader.surface)

                            val sessionStateCallback = object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(session: CameraCaptureSession) {
                                    events.add("onConfigured")
                                    sessionRef.set(session)
                                    sessionConfiguredFlag.set(true)
                                    configureLatch.countDown()
                                }

                                override fun onConfigureFailed(session: CameraCaptureSession) {
                                    events.add("onConfigureFailed")
                                    if (terminalReached.compareAndSet(false, true)) {
                                        decisionRef.set("sessionConfigureFailed")
                                        reasons.add("session_configure_failed")
                                    }
                                    configureLatch.countDown()
                                }

                                override fun onClosed(session: CameraCaptureSession) {
                                    events.add("onSessionClosed")
                                    sessionClosedFlag.set(true)
                                    sessionClosedLatch.countDown()
                                }
                            }

                            events.add("createCaptureSessionRequested")
                            device.createCaptureSession(
                                listOf(imageReader.surface), sessionStateCallback, bgHandler,
                            )

                            val configuredInTime = configureLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
                            if (!configuredInTime) {
                                events.add("sessionConfigureTimeout")
                                if (terminalReached.compareAndSet(false, true)) {
                                    decisionRef.set("sessionConfigureTimeout")
                                    reasons.add("session_configure_timeout")
                                }
                            } else if (!terminalReached.get() && sessionConfiguredFlag.get()) {
                                val session = sessionRef.get()
                                if (session != null) {
                                    try {
                                        session.setRepeatingRequest(requestBuilder.build(), captureCallback, bgHandler)
                                        repeatingStartedFlag.set(true)
                                        events.add("repeatingRequestStarted")

                                        val frameInTime = frameLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
                                        if (!frameInTime) {
                                            events.add("frameTimeout")
                                            if (terminalReached.compareAndSet(false, true)) {
                                                decisionRef.set("frameTimeout")
                                                reasons.add("frame_timeout")
                                            }
                                        } else if (!terminalReached.get() && frameReceivedFlag.get()) {
                                            if (terminalReached.compareAndSet(false, true)) {
                                                decisionRef.set("frameCaptured")
                                            }
                                        }
                                    } catch (t: Throwable) {
                                        Log.w(TAG, "setRepeatingRequest failed: ${t.javaClass.simpleName}: ${t.message}")
                                        diagnostics["setRepeatingRequestError"] = "${t.javaClass.simpleName}: ${t.message}"
                                        if (terminalReached.compareAndSet(false, true)) {
                                            decisionRef.set("repeatingRequestFailed")
                                            reasons.add("repeating_request_failed")
                                        }
                                    }
                                }
                            }
                        } catch (t: Throwable) {
                            Log.w(TAG, "createCaptureSession failed: ${t.javaClass.simpleName}: ${t.message}")
                            diagnostics["createCaptureSessionError"] = "${t.javaClass.simpleName}: ${t.message}"
                            if (terminalReached.compareAndSet(false, true)) {
                                decisionRef.set("sessionConfigureFailed")
                                reasons.add("session_configure_threw")
                            }
                        }
                    }
                }
            }
        } finally {
            // Cleanup ordering: stop/abort repeating, close session (wait briefly),
            // close device (wait briefly), unregister ImageReader listener, close
            // ImageReader, quit HandlerThread. Runs after timeout, error, or success.
            val session = sessionRef.get()
            if (session != null) {
                try {
                    session.stopRepeating()
                } catch (t: Throwable) {
                    Log.w(TAG, "session.stopRepeating() failed: ${t.javaClass.simpleName}: ${t.message}")
                }
                try {
                    session.abortCaptures()
                } catch (t: Throwable) {
                    Log.w(TAG, "session.abortCaptures() failed: ${t.javaClass.simpleName}: ${t.message}")
                }
                try {
                    session.close()
                } catch (t: Throwable) {
                    Log.w(TAG, "session.close() failed: ${t.javaClass.simpleName}: ${t.message}")
                }
                try {
                    sessionClosedLatch.await(CLOSE_WAIT_MS, TimeUnit.MILLISECONDS)
                } catch (t: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }

            val device = deviceRef.get()
            if (device != null) {
                try {
                    device.close()
                } catch (t: Throwable) {
                    Log.w(TAG, "device.close() failed: ${t.javaClass.simpleName}: ${t.message}")
                }
                try {
                    deviceClosedLatch.await(CLOSE_WAIT_MS, TimeUnit.MILLISECONDS)
                } catch (t: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }

            try {
                imageReader.setOnImageAvailableListener(null, null)
            } catch (t: Throwable) {
                Log.w(TAG, "imageReader listener unregister failed: ${t.javaClass.simpleName}: ${t.message}")
            }
            try {
                imageReader.close()
            } catch (t: Throwable) {
                Log.w(TAG, "imageReader.close() failed: ${t.javaClass.simpleName}: ${t.message}")
            }
            imageReaderClosedFlag.set(true)

            if (ignoredCaptureFailuresAfterTerminal.get() > 0) {
                diagnostics["ignoredCaptureFailuresAfterTerminal"] = ignoredCaptureFailuresAfterTerminal.get()
            }

            handlerThread.quitSafely()
        }

        return buildResult(
            decision = decisionRef.get(),
            opened = openedFlag.get(),
            sessionConfigured = sessionConfiguredFlag.get(),
            repeatingStarted = repeatingStartedFlag.get(),
            frameReceived = frameReceivedFlag.get(),
            imageClosed = imageClosedFlag.get(),
            sessionClosed = sessionClosedFlag.get(),
            deviceClosed = deviceClosedFlag.get(),
            imageReaderClosed = imageReaderClosedFlag.get(),
            frameTimestampNs = frameTimestampNs.get().let { if (it < 0) null else it },
            framePlaneCount = framePlaneCount.get().let { if (it < 0) null else it },
        )
    }

    private fun hasCameraPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun lensFacingName(cameraManager: CameraManager, cameraId: String): String {
        return try {
            when (cameraManager.getCameraCharacteristics(cameraId).get(CameraCharacteristics.LENS_FACING)) {
                CameraCharacteristics.LENS_FACING_FRONT -> "front"
                CameraCharacteristics.LENS_FACING_BACK -> "back"
                CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
                else -> "unknown"
            }
        } catch (t: Throwable) {
            Log.w(TAG, "getCameraCharacteristics($cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
            "unknown"
        }
    }

    private fun selectYuvSize(sizes: List<Size>, maxWidth: Int, maxHeight: Int): Size {
        val fitting = sizes.filter { it.width <= maxWidth && it.height <= maxHeight }
        val pool = if (fitting.isNotEmpty()) fitting else sizes
        return pool.minWith(compareBy { it.width.toLong() * it.height.toLong() })
    }

    private fun clampLong(raw: Long?, default: Long, min: Long, max: Long): Long {
        return (raw ?: default).coerceIn(min, max)
    }

    private fun clampInt(raw: Int?, default: Int, min: Int, max: Int): Int {
        val value = raw?.takeIf { it > 0 } ?: default
        return value.coerceIn(min, max)
    }
}
