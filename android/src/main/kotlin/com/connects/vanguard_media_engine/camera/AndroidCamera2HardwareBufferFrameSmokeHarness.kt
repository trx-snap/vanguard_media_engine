package com.connects.vanguard_media_engine.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
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
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Phase 3-Unit J: diagnostic-only Android Camera2 single-camera PRIVATE
 * ImageReader HardwareBuffer frame smoke harness.
 *
 * Opens exactly one Camera2 device, configures a single ImageFormat.PRIVATE
 * [ImageReader] with [HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE], receives one
 * image, obtains its non-null [HardwareBuffer], records its metadata, and
 * tears down buffer/image/session/device/reader deterministically when
 * CAMERA is already granted. Requires API 29+. Never creates a preview UI,
 * MediaRecorder, CameraX session, dual/concurrent open, or C++/JNI/Vulkan
 * AHardwareBuffer import. Diagnostic/capability foundation only.
 */
class AndroidCamera2HardwareBufferFrameSmokeHarness(private val context: Context) {

    companion object {
        private const val TAG = "AndroidCamera2HardwareBufferFrameSmokeHarness"
        private const val DEFAULT_TIMEOUT_MS = 8000L
        private const val MIN_TIMEOUT_MS = 2000L
        private const val MAX_TIMEOUT_MS = 20000L
        private const val DEFAULT_MAX_WIDTH = 640
        private const val DEFAULT_MAX_HEIGHT = 480
        private const val MIN_DIMENSION = 160
        private const val MAX_DIMENSION = 1920
        private const val CLOSE_WAIT_MS = 2000L
        private const val IMAGE_READER_MAX_IMAGES = 2
        private const val FENCE_AWAIT_MS = 1000L
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
            hardwareBufferAvailable: Boolean = false,
            hardwareBufferClosed: Boolean = false,
            imageClosed: Boolean = false,
            sessionClosed: Boolean = false,
            deviceClosed: Boolean = false,
            imageReaderClosed: Boolean = false,
            frameTimestampNs: Long? = null,
            hardwareBufferWidth: Int? = null,
            hardwareBufferHeight: Int? = null,
            hardwareBufferFormat: Int? = null,
            hardwareBufferLayers: Int? = null,
            hardwareBufferUsage: Long? = null,
            syncFenceAwaited: Boolean = false,
            syncFenceClosed: Boolean = false,
        ): Map<String, Any?> {
            val durationMs = SystemClock.elapsedRealtime() - startElapsed
            val success = decision == "frameCaptured" &&
                frameReceived && hardwareBufferAvailable && hardwareBufferClosed &&
                imageClosed && sessionClosed && deviceClosed && imageReaderClosed
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
                "hardwareBufferAvailable" to hardwareBufferAvailable,
                "hardwareBufferClosed" to hardwareBufferClosed,
                "imageClosed" to imageClosed,
                "sessionClosed" to sessionClosed,
                "deviceClosed" to deviceClosed,
                "imageReaderClosed" to imageReaderClosed,
                "cameraId" to selectedCameraId,
                "selectedLensFacing" to selectedLensFacing,
                "selectedWidth" to selectedWidth,
                "selectedHeight" to selectedHeight,
                "imageFormatName" to "PRIVATE",
                "frameTimestampNs" to frameTimestampNs,
                "hardwareBufferWidth" to hardwareBufferWidth,
                "hardwareBufferHeight" to hardwareBufferHeight,
                "hardwareBufferFormat" to hardwareBufferFormat,
                "hardwareBufferLayers" to hardwareBufferLayers,
                "hardwareBufferUsage" to hardwareBufferUsage,
                "syncFenceAwaited" to syncFenceAwaited,
                "syncFenceClosed" to syncFenceClosed,
                "decision" to decision,
                "reasons" to reasons.toList(),
                "events" to events.toList(),
                "diagnostics" to diagnostics.toMap(),
                "durationMs" to durationMs,
            )
        }

        // Guard 0: API level below 29 (required for the 5-arg PRIVATE ImageReader/HardwareBuffer path).
        if (apiLevel < Build.VERSION_CODES.Q) {
            reasons.add("api_below_29")
            return buildResult("apiUnsupported")
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

        // Guard 5: no PRIVATE output sizes.
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
        val privateSizes = try {
            streamConfigurationMap?.getOutputSizes(ImageFormat.PRIVATE)?.toList() ?: emptyList()
        } catch (t: Throwable) {
            Log.w(TAG, "getOutputSizes(PRIVATE, $cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
            diagnostics["outputSizesError"] = "${t.javaClass.simpleName}: ${t.message}"
            emptyList()
        }
        val positivePrivateSizes = privateSizes.filter { it.width > 0 && it.height > 0 }
        if (positivePrivateSizes.isEmpty()) {
            reasons.add("no_private_output_sizes")
            return buildResult("unsupportedStream")
        }

        val selectedSize = selectPrivateSize(positivePrivateSizes, maxWidth, maxHeight)
        selectedWidth = selectedSize.width
        selectedHeight = selectedSize.height

        // All guards passed — allocate resources.
        val handlerThread = HandlerThread("VGCamera2HardwareBufferFrameSmoke")
        handlerThread.start()
        val bgHandler = Handler(handlerThread.looper)
        val imageReader = ImageReader.newInstance(
            selectedWidth, selectedHeight, ImageFormat.PRIVATE, IMAGE_READER_MAX_IMAGES,
            HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
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
        val hardwareBufferAvailableFlag = AtomicBoolean(false)
        val hardwareBufferClosedFlag = AtomicBoolean(false)
        val imageClosedFlag = AtomicBoolean(false)
        val sessionClosedFlag = AtomicBoolean(false)
        val deviceClosedFlag = AtomicBoolean(false)
        val imageReaderClosedFlag = AtomicBoolean(false)
        val frameTimestampNs = AtomicLong(-1L)
        val hardwareBufferWidth = AtomicInteger(-1)
        val hardwareBufferHeight = AtomicInteger(-1)
        val hardwareBufferFormat = AtomicInteger(-1)
        val hardwareBufferLayers = AtomicInteger(-1)
        val hardwareBufferUsage = AtomicLong(-1L)
        val syncFenceAwaitedFlag = AtomicBoolean(false)
        val syncFenceClosedFlag = AtomicBoolean(false)
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
                    val hwBuf = image.hardwareBuffer
                    if (hwBuf == null) {
                        if (terminalReached.compareAndSet(false, true)) {
                            events.add("hardwareBufferUnavailable")
                            decisionRef.set("hardwareBufferUnavailable")
                            reasons.add("hardware_buffer_unavailable")
                        } else {
                            ignoredCaptureFailuresAfterTerminal.incrementAndGet()
                        }
                    } else {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                val fence = image.fence
                                try {
                                    fence.await(Duration.ofMillis(FENCE_AWAIT_MS))
                                    syncFenceAwaitedFlag.set(true)
                                } finally {
                                    fence.close()
                                    syncFenceClosedFlag.set(true)
                                }
                            }

                            if (frameReceivedFlag.compareAndSet(false, true)) {
                                frameTimestampNs.set(image.timestamp)
                                hardwareBufferAvailableFlag.set(true)
                                hardwareBufferWidth.set(hwBuf.width)
                                hardwareBufferHeight.set(hwBuf.height)
                                hardwareBufferFormat.set(hwBuf.format)
                                hardwareBufferLayers.set(hwBuf.layers)
                                hardwareBufferUsage.set(hwBuf.usage)
                                events.add("onImageAvailable")
                                if (terminalReached.compareAndSet(false, true)) {
                                    decisionRef.set("frameCaptured")
                                }
                            }
                        } finally {
                            hwBuf.close()
                            hardwareBufferClosedFlag.set(true)
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
            hardwareBufferAvailable = hardwareBufferAvailableFlag.get(),
            hardwareBufferClosed = hardwareBufferClosedFlag.get(),
            imageClosed = imageClosedFlag.get(),
            sessionClosed = sessionClosedFlag.get(),
            deviceClosed = deviceClosedFlag.get(),
            imageReaderClosed = imageReaderClosedFlag.get(),
            frameTimestampNs = frameTimestampNs.get().let { if (it < 0) null else it },
            hardwareBufferWidth = hardwareBufferWidth.get().let { if (it < 0) null else it },
            hardwareBufferHeight = hardwareBufferHeight.get().let { if (it < 0) null else it },
            hardwareBufferFormat = hardwareBufferFormat.get().let { if (it < 0) null else it },
            hardwareBufferLayers = hardwareBufferLayers.get().let { if (it < 0) null else it },
            hardwareBufferUsage = hardwareBufferUsage.get().let { if (it < 0) null else it },
            syncFenceAwaited = syncFenceAwaitedFlag.get(),
            syncFenceClosed = syncFenceClosedFlag.get(),
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

    private fun selectPrivateSize(sizes: List<Size>, maxWidth: Int, maxHeight: Int): Size {
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
