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
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * P3-CAM-THERMAL-ACT-RESOLUTION-RECONFIG-DIAGNOSTIC: diagnostic-only Android
 * Camera2 single-camera session reconfiguration smoke.
 *
 * Opens exactly one real Camera2 device, configures a first YUV_420_888
 * [ImageReader]-backed capture session at an initial size, starts a
 * repeating request and observes at least one completed capture/frame, then
 * - driven by an opt-in Dart `reduceResolution` thermal policy decision
 * (never invented natively) - closes the first session/reader and
 * reconfigures a *second* session on the *same* still-open [CameraDevice] at
 * a strictly smaller supported YUV_420_888 size, again observing at least
 * one completed capture/frame before deterministic cleanup.
 *
 * Never reopens the camera device (`cameraDeviceOpenCount == 1`), never
 * opens a secondary camera, never starts a real recording/MediaRecorder/
 * encoder, and never touches the renderer or product UI/CameraX path.
 * Diagnostic/capability foundation only - not a production CameraX
 * actuation proof.
 */
class AndroidCamera2ThermalResolutionReconfigureSmokeHarness(private val context: Context) {

    companion object {
        private const val TAG = "AndroidCamera2ThermalResolutionReconfigureSmokeHarness"
        private const val DEFAULT_TIMEOUT_MS = 10000L
        private const val MIN_TIMEOUT_MS = 2000L
        private const val MAX_TIMEOUT_MS = 20000L
        private const val DEFAULT_MAX_WIDTH = 640
        private const val DEFAULT_MAX_HEIGHT = 480
        private const val MIN_DIMENSION = 160
        private const val MAX_DIMENSION = 1920
        private const val CLOSE_WAIT_MS = 2000L
        private const val IMAGE_READER_MAX_IMAGES = 2
        private const val THERMAL_STATE_RAW_SERIOUS = 2

        const val PROOF_BOUNDARY = "single_camera_resolution_session_reconfigure_policy_derived_" +
            "no_forced_heat_no_recording_no_encoder_no_product"

        private fun sizeToMap(size: Size?): Map<String, Int>? =
            size?.let { mapOf("width" to it.width, "height" to it.height) }

        private fun area(size: Size): Long = size.width.toLong() * size.height.toLong()
    }

    fun run(args: Map<*, *>?): Map<String, Any?> {
        val startElapsed = SystemClock.elapsedRealtime()
        val apiLevel = Build.VERSION.SDK_INT
        val hasCameraPermission = hasCameraPermission()
        val requestedCameraId = (args?.get("cameraId") as? String)?.trim()
        val timeoutMs = clampLong((args?.get("timeoutMs") as? Number)?.toLong(), DEFAULT_TIMEOUT_MS, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
        val maxWidth = clampInt((args?.get("maxWidth") as? Number)?.toInt(), DEFAULT_MAX_WIDTH, MIN_DIMENSION, MAX_DIMENSION)
        val maxHeight = clampInt((args?.get("maxHeight") as? Number)?.toInt(), DEFAULT_MAX_HEIGHT, MIN_DIMENSION, MAX_DIMENSION)
        val policyDecision = (args?.get("policyDecision") as? String)?.trim() ?: "reduceResolution"
        val policyTargetResolutionScale = (args?.get("policyTargetResolutionScale") as? Number)?.toDouble() ?: 0.5

        val events = Collections.synchronizedList(mutableListOf<String>())
        val reasons = Collections.synchronizedList(mutableListOf<String>())
        val diagnostics = Collections.synchronizedMap(mutableMapOf<String, Any?>())

        var attemptedOpen = false
        var selectedCameraId: String? = null
        var selectedLensFacing = "unknown"
        var initialSize: Size? = null
        var reducedSize: Size? = null

        val openedFlag = AtomicBoolean(false)
        val cameraDeviceOpenCount = java.util.concurrent.atomic.AtomicInteger(0)
        val firstSessionConfiguredFlag = AtomicBoolean(false)
        val firstRepeatingStartedFlag = AtomicBoolean(false)
        val firstFrameObservedFlag = AtomicBoolean(false)
        val firstSessionClosedFlag = AtomicBoolean(false)
        val firstReaderClosedFlag = AtomicBoolean(false)
        val secondSessionConfiguredFlag = AtomicBoolean(false)
        val secondRepeatingStartedFlag = AtomicBoolean(false)
        val secondFrameObservedFlag = AtomicBoolean(false)
        val secondSessionClosedFlag = AtomicBoolean(false)
        val secondReaderClosedFlag = AtomicBoolean(false)
        val deviceClosedFlag = AtomicBoolean(false)
        val sessionConfigureCount = java.util.concurrent.atomic.AtomicInteger(0)
        val terminalReached = AtomicBoolean(false)
        val decisionRef = AtomicReference("openError")
        // Set immediately before the deliberate first-session stopRepeating/abortCaptures/close
        // sequence starts; a first-session onCaptureFailed caused by that deliberate teardown
        // (after a first frame was already observed) must not downgrade the proof.
        val firstSessionReconfigureClosing = AtomicBoolean(false)

        fun buildResult(decision: String): Map<String, Any?> {
            val durationMs = SystemClock.elapsedRealtime() - startElapsed
            val opened = openedFlag.get()
            val firstSessionConfigured = firstSessionConfiguredFlag.get()
            val firstRepeatingStarted = firstRepeatingStartedFlag.get()
            val firstFrameObserved = firstFrameObservedFlag.get()
            val firstSessionClosed = firstSessionClosedFlag.get()
            val firstReaderClosed = firstReaderClosedFlag.get()
            val secondSessionConfigured = secondSessionConfiguredFlag.get()
            val secondRepeatingStarted = secondRepeatingStartedFlag.get()
            val secondFrameObserved = secondFrameObservedFlag.get()
            val secondSessionClosed = secondSessionClosedFlag.get()
            val secondReaderClosed = secondReaderClosedFlag.get()
            val deviceClosed = deviceClosedFlag.get()
            val sameCameraDeviceReused = cameraDeviceOpenCount.get() == 1
            val initialArea = initialSize?.let { area(it) }
            val reducedArea = reducedSize?.let { area(it) }
            val reducedStrictlyLower = initialArea != null && reducedArea != null && reducedArea < initialArea
            val resolutionReconfigured = decision == "resolutionReconfigured"
            val success = decision == "resolutionReconfigured" &&
                hasCameraPermission &&
                opened &&
                firstSessionConfigured &&
                firstRepeatingStarted &&
                firstFrameObserved &&
                firstSessionClosed &&
                firstReaderClosed &&
                secondSessionConfigured &&
                secondRepeatingStarted &&
                secondFrameObserved &&
                secondSessionClosed &&
                secondReaderClosed &&
                deviceClosed &&
                sameCameraDeviceReused &&
                cameraDeviceOpenCount.get() == 1 &&
                sessionConfigureCount.get() == 2 &&
                reducedStrictlyLower
            Log.i(
                TAG,
                "decision=$decision success=$success attemptedOpen=$attemptedOpen opened=$opened " +
                    "cameraId=$selectedCameraId initialSize=$initialSize reducedSize=$reducedSize " +
                    "durationMs=$durationMs",
            )
            return mapOf(
                "success" to success,
                "pass" to success,
                "decision" to decision,
                "reasons" to reasons.toList(),
                "events" to events.toList(),
                "diagnostics" to diagnostics.toMap(),
                "proofBoundary" to PROOF_BOUNDARY,
                "apiLevel" to apiLevel,
                "hasCameraPermission" to hasCameraPermission,
                "attemptedOpen" to attemptedOpen,
                "opened" to opened,
                "cameraDeviceOpenCount" to cameraDeviceOpenCount.get(),
                "sameCameraDeviceReused" to sameCameraDeviceReused,
                "cameraId" to selectedCameraId,
                "selectedLensFacing" to selectedLensFacing,
                "initialSize" to sizeToMap(initialSize),
                "reducedSize" to sizeToMap(reducedSize),
                "initialArea" to initialArea,
                "reducedArea" to reducedArea,
                "policyDecision" to policyDecision,
                "policyTargetResolutionScale" to policyTargetResolutionScale,
                "policyDerivedResolutionTarget" to true,
                "syntheticPolicyInput" to true,
                "thermalStateRaw" to THERMAL_STATE_RAW_SERIOUS,
                "wasRecordingPolicyInput" to true,
                "hadSecondaryCameraPolicyInput" to false,
                "recordingActive" to false,
                "firstSessionConfigured" to firstSessionConfigured,
                "firstRepeatingStarted" to firstRepeatingStarted,
                "firstFrameObserved" to firstFrameObserved,
                "firstSessionClosed" to firstSessionClosed,
                "firstReaderClosed" to firstReaderClosed,
                "secondSessionConfigured" to secondSessionConfigured,
                "secondRepeatingStarted" to secondRepeatingStarted,
                "secondFrameObserved" to secondFrameObserved,
                "secondSessionClosed" to secondSessionClosed,
                "secondReaderClosed" to secondReaderClosed,
                "deviceClosed" to deviceClosed,
                "sessionConfigureCount" to sessionConfigureCount.get(),
                "surfaceCountPerSession" to 1,
                "resolutionReconfigured" to resolutionReconfigured,
                "cameraSessionReconfigured" to resolutionReconfigured,
                "frameCadenceChangeProven" to false,
                "durationMs" to durationMs,
                // Nonclaims - explicit boundaries this smoke never crosses.
                "realForcedOverheat" to false,
                "powerManagerThermalStateMutated" to false,
                "osThermalListenerTriggered" to false,
                "mediaRecorderCreated" to false,
                "encoderTouched" to false,
                "rendererTouched" to false,
                "productUiTouched" to false,
                "secondaryCameraOpened" to false,
                "secondaryCameraDisabled" to false,
                "productCameraSessionTouched" to false,
                "cameraXPathProven" to false,
                "productionRecordingRebindProven" to false,
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

        // Guard 3: permission absent - check first; no open is ever attempted without it.
        if (!hasCameraPermission) {
            reasons.add("camera_permission_absent")
            return buildResult("permissionRequired")
        }

        // Guard 4: invalid requested camera id.
        if (!requestedCameraId.isNullOrBlank() && !cameraIds.contains(requestedCameraId)) {
            reasons.add("requested_camera_id_not_found")
            return buildResult("cameraUnavailable")
        }

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

        // Guard 5: need at least two positive YUV_420_888 sizes.
        if (positiveYuvSizes.size < 2) {
            reasons.add("no_yuv_420_888_output_sizes")
            return buildResult("unsupportedStream")
        }

        val initial = selectInitialSize(positiveYuvSizes, maxWidth, maxHeight)
        initialSize = initial

        // Guard 6: invalid policy decision/scale - validated against the Dart-derived policy,
        // never invented natively.
        if (policyDecision != "reduceResolution" ||
            policyTargetResolutionScale <= 0.0 ||
            policyTargetResolutionScale > 1.0
        ) {
            reasons.add("invalid_policy_decision")
            return buildResult("invalidPolicyDecision")
        }

        val reduced = selectReducedSize(positiveYuvSizes, initial, policyTargetResolutionScale)

        // Guard 7: no supported size with a strictly lower area.
        if (reduced == null) {
            reasons.add("no_lower_resolution_available")
            return buildResult("noLowerResolutionAvailable")
        }
        reducedSize = reduced

        // All guards passed - allocate resources.
        val handlerThread = HandlerThread("VGCamera2ThermalResolutionReconfigureSmoke")
        handlerThread.start()
        val bgHandler = Handler(handlerThread.looper)
        val firstReader = ImageReader.newInstance(
            initial.width, initial.height, ImageFormat.YUV_420_888, IMAGE_READER_MAX_IMAGES,
        )
        val secondReader = ImageReader.newInstance(
            reduced.width, reduced.height, ImageFormat.YUV_420_888, IMAGE_READER_MAX_IMAGES,
        )

        val openLatch = CountDownLatch(1)
        val firstConfigureLatch = CountDownLatch(1)
        val firstFrameLatch = CountDownLatch(1)
        val firstSessionClosedLatch = CountDownLatch(1)
        val secondConfigureLatch = CountDownLatch(1)
        val secondFrameLatch = CountDownLatch(1)
        val secondSessionClosedLatch = CountDownLatch(1)
        val deviceClosedLatch = CountDownLatch(1)

        val deviceRef = AtomicReference<CameraDevice?>(null)
        val firstSessionRef = AtomicReference<CameraCaptureSession?>(null)
        val secondSessionRef = AtomicReference<CameraCaptureSession?>(null)

        attemptedOpen = true

        try {
            firstReader.setOnImageAvailableListener({ reader ->
                try {
                    val image = reader.acquireLatestImage()
                    if (image != null) {
                        if (firstFrameObservedFlag.compareAndSet(false, true)) {
                            events.add("firstImageAvailable")
                            firstFrameLatch.countDown()
                        }
                        image.close()
                    }
                } catch (t: Throwable) {
                    Log.w(TAG, "first acquireLatestImage/close failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }, bgHandler)

            secondReader.setOnImageAvailableListener({ reader ->
                try {
                    val image = reader.acquireLatestImage()
                    if (image != null) {
                        if (secondFrameObservedFlag.compareAndSet(false, true)) {
                            events.add("secondImageAvailable")
                            secondFrameLatch.countDown()
                        }
                        image.close()
                    }
                } catch (t: Throwable) {
                    Log.w(TAG, "second acquireLatestImage/close failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }, bgHandler)

            val firstCaptureCallback = object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureFailed(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    failure: CaptureFailure,
                ) {
                    // Shutdown capture failures after success must never downgrade the proof.
                    if (terminalReached.get()) {
                        events.add("ignoredAfterTerminal:firstCaptureFailed")
                        return
                    }
                    // A first-session capture failure caused by the deliberate policy-derived
                    // stopRepeating/abortCaptures/close teardown (after a first frame was already
                    // observed) is expected and must not downgrade the proof.
                    if (firstFrameObservedFlag.get() && firstSessionReconfigureClosing.get()) {
                        events.add("ignoredDuringReconfigure:firstCaptureFailed")
                        return
                    }
                    events.add("onCaptureFailed:first")
                    if (terminalReached.compareAndSet(false, true)) {
                        decisionRef.set("captureFailed")
                        reasons.add("first_capture_failed")
                        diagnostics["firstCaptureFailureReason"] = failure.reason
                    }
                    firstFrameLatch.countDown()
                }
            }

            val secondCaptureCallback = object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureFailed(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    failure: CaptureFailure,
                ) {
                    if (terminalReached.get()) {
                        events.add("ignoredAfterTerminal:secondCaptureFailed")
                        return
                    }
                    events.add("onCaptureFailed:second")
                    if (terminalReached.compareAndSet(false, true)) {
                        decisionRef.set("captureFailed")
                        reasons.add("second_capture_failed")
                        diagnostics["secondCaptureFailureReason"] = failure.reason
                    }
                    secondFrameLatch.countDown()
                }
            }

            val deviceStateCallback = object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    events.add("onOpened")
                    openedFlag.set(true)
                    cameraDeviceOpenCount.incrementAndGet()
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
                    firstSessionClosedLatch.countDown()
                    secondSessionClosedLatch.countDown()
                    firstConfigureLatch.countDown()
                    secondConfigureLatch.countDown()
                    firstFrameLatch.countDown()
                    secondFrameLatch.countDown()
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
                    firstSessionClosedLatch.countDown()
                    secondSessionClosedLatch.countDown()
                    firstConfigureLatch.countDown()
                    secondConfigureLatch.countDown()
                    firstFrameLatch.countDown()
                    secondFrameLatch.countDown()
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
                        // -- First session: configure at the initial size, start repeating, observe a frame. --
                        try {
                            val firstRequestBuilder = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                            firstRequestBuilder.addTarget(firstReader.surface)

                            val firstSessionStateCallback = object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(session: CameraCaptureSession) {
                                    events.add("onFirstConfigured")
                                    firstSessionRef.set(session)
                                    firstSessionConfiguredFlag.set(true)
                                    sessionConfigureCount.incrementAndGet()
                                    firstConfigureLatch.countDown()
                                }

                                override fun onConfigureFailed(session: CameraCaptureSession) {
                                    events.add("onFirstConfigureFailed")
                                    if (terminalReached.compareAndSet(false, true)) {
                                        decisionRef.set("firstSessionConfigureFailed")
                                        reasons.add("first_session_configure_failed")
                                    }
                                    firstConfigureLatch.countDown()
                                }

                                override fun onClosed(session: CameraCaptureSession) {
                                    events.add("onFirstSessionClosed")
                                    firstSessionClosedFlag.set(true)
                                    firstSessionClosedLatch.countDown()
                                }
                            }

                            events.add("createFirstCaptureSessionRequested")
                            device.createCaptureSession(
                                listOf(firstReader.surface), firstSessionStateCallback, bgHandler,
                            )

                            val firstConfiguredInTime = firstConfigureLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
                            if (!firstConfiguredInTime) {
                                events.add("firstSessionConfigureTimeout")
                                if (terminalReached.compareAndSet(false, true)) {
                                    decisionRef.set("firstSessionConfigureTimeout")
                                    reasons.add("first_session_configure_timeout")
                                }
                            } else if (!terminalReached.get() && firstSessionConfiguredFlag.get()) {
                                val firstSession = firstSessionRef.get()
                                if (firstSession != null) {
                                    try {
                                        firstSession.setRepeatingRequest(
                                            firstRequestBuilder.build(), firstCaptureCallback, bgHandler,
                                        )
                                        firstRepeatingStartedFlag.set(true)
                                        events.add("firstRepeatingRequestStarted")

                                        val firstFrameInTime = firstFrameLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
                                        if (!firstFrameInTime) {
                                            events.add("firstFrameTimeout")
                                            if (terminalReached.compareAndSet(false, true)) {
                                                decisionRef.set("firstFrameNeverObserved")
                                                reasons.add("first_frame_never_observed")
                                            }
                                        } else if (!terminalReached.get() && firstFrameObservedFlag.get()) {
                                            // -- Policy-derived reconfiguration: stop/close the first session/reader,
                                            // keep the CameraDevice open, then configure the second (reduced) session. --
                                            events.add("policyDerivedReconfigureTriggered")
                                            firstSessionReconfigureClosing.set(true)
                                            try {
                                                firstSession.stopRepeating()
                                            } catch (t: Throwable) {
                                                Log.w(TAG, "firstSession.stopRepeating() failed: ${t.javaClass.simpleName}: ${t.message}")
                                            }
                                            try {
                                                firstSession.abortCaptures()
                                            } catch (t: Throwable) {
                                                Log.w(TAG, "firstSession.abortCaptures() failed: ${t.javaClass.simpleName}: ${t.message}")
                                            }
                                            try {
                                                firstSession.close()
                                            } catch (t: Throwable) {
                                                Log.w(TAG, "firstSession.close() failed: ${t.javaClass.simpleName}: ${t.message}")
                                            }
                                            val firstClosedInTime = firstSessionClosedLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
                                            if (!firstClosedInTime) {
                                                events.add("firstSessionCloseTimeout")
                                                if (terminalReached.compareAndSet(false, true)) {
                                                    decisionRef.set("firstSessionCloseTimeout")
                                                    reasons.add("first_session_close_timeout")
                                                }
                                            }
                                            try {
                                                firstReader.setOnImageAvailableListener(null, null)
                                            } catch (t: Throwable) {
                                                Log.w(TAG, "firstReader listener unregister failed: ${t.javaClass.simpleName}: ${t.message}")
                                            }
                                            try {
                                                firstReader.close()
                                            } catch (t: Throwable) {
                                                Log.w(TAG, "firstReader.close() failed: ${t.javaClass.simpleName}: ${t.message}")
                                            }
                                            firstReaderClosedFlag.set(true)

                                            if (!terminalReached.get() && firstSessionClosedFlag.get()) {
                                                // -- Second session: configure at the policy-derived reduced size on
                                                // the same still-open CameraDevice, start repeating, observe a frame. --
                                                try {
                                                    val secondRequestBuilder =
                                                        device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                                                    secondRequestBuilder.addTarget(secondReader.surface)

                                                    val secondSessionStateCallback = object : CameraCaptureSession.StateCallback() {
                                                        override fun onConfigured(session: CameraCaptureSession) {
                                                            events.add("onSecondConfigured")
                                                            secondSessionRef.set(session)
                                                            secondSessionConfiguredFlag.set(true)
                                                            sessionConfigureCount.incrementAndGet()
                                                            secondConfigureLatch.countDown()
                                                        }

                                                        override fun onConfigureFailed(session: CameraCaptureSession) {
                                                            events.add("onSecondConfigureFailed")
                                                            if (terminalReached.compareAndSet(false, true)) {
                                                                decisionRef.set("secondSessionConfigureFailed")
                                                                reasons.add("second_session_configure_failed")
                                                            }
                                                            secondConfigureLatch.countDown()
                                                        }

                                                        override fun onClosed(session: CameraCaptureSession) {
                                                            events.add("onSecondSessionClosed")
                                                            secondSessionClosedFlag.set(true)
                                                            secondSessionClosedLatch.countDown()
                                                        }
                                                    }

                                                    events.add("createSecondCaptureSessionRequested")
                                                    device.createCaptureSession(
                                                        listOf(secondReader.surface), secondSessionStateCallback, bgHandler,
                                                    )

                                                    val secondConfiguredInTime =
                                                        secondConfigureLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
                                                    if (!secondConfiguredInTime) {
                                                        events.add("secondSessionConfigureTimeout")
                                                        if (terminalReached.compareAndSet(false, true)) {
                                                            decisionRef.set("secondSessionConfigureTimeout")
                                                            reasons.add("second_session_configure_timeout")
                                                        }
                                                    } else if (!terminalReached.get() && secondSessionConfiguredFlag.get()) {
                                                        val secondSession = secondSessionRef.get()
                                                        if (secondSession != null) {
                                                            try {
                                                                secondSession.setRepeatingRequest(
                                                                    secondRequestBuilder.build(), secondCaptureCallback, bgHandler,
                                                                )
                                                                secondRepeatingStartedFlag.set(true)
                                                                events.add("secondRepeatingRequestStarted")

                                                                val secondFrameInTime =
                                                                    secondFrameLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
                                                                if (!secondFrameInTime) {
                                                                    events.add("secondFrameTimeout")
                                                                    if (terminalReached.compareAndSet(false, true)) {
                                                                        decisionRef.set("secondFrameNeverObserved")
                                                                        reasons.add("second_frame_never_observed")
                                                                    }
                                                                } else if (!terminalReached.get() && secondFrameObservedFlag.get()) {
                                                                    if (terminalReached.compareAndSet(false, true)) {
                                                                        decisionRef.set("resolutionReconfigured")
                                                                    }
                                                                }
                                                            } catch (t: Throwable) {
                                                                Log.w(TAG, "second setRepeatingRequest failed: ${t.javaClass.simpleName}: ${t.message}")
                                                                diagnostics["secondSetRepeatingRequestError"] = "${t.javaClass.simpleName}: ${t.message}"
                                                                if (terminalReached.compareAndSet(false, true)) {
                                                                    decisionRef.set("secondRepeatingRequestFailed")
                                                                    reasons.add("second_repeating_request_failed")
                                                                }
                                                            }
                                                        }
                                                    }
                                                } catch (t: Throwable) {
                                                    Log.w(TAG, "second createCaptureSession failed: ${t.javaClass.simpleName}: ${t.message}")
                                                    diagnostics["secondCreateCaptureSessionError"] = "${t.javaClass.simpleName}: ${t.message}"
                                                    if (terminalReached.compareAndSet(false, true)) {
                                                        decisionRef.set("secondSessionConfigureFailed")
                                                        reasons.add("second_session_configure_threw")
                                                    }
                                                }
                                            }
                                        }
                                    } catch (t: Throwable) {
                                        Log.w(TAG, "first setRepeatingRequest failed: ${t.javaClass.simpleName}: ${t.message}")
                                        diagnostics["firstSetRepeatingRequestError"] = "${t.javaClass.simpleName}: ${t.message}"
                                        if (terminalReached.compareAndSet(false, true)) {
                                            decisionRef.set("firstRepeatingRequestFailed")
                                            reasons.add("first_repeating_request_failed")
                                        }
                                    }
                                }
                            }
                        } catch (t: Throwable) {
                            Log.w(TAG, "first createCaptureSession failed: ${t.javaClass.simpleName}: ${t.message}")
                            diagnostics["firstCreateCaptureSessionError"] = "${t.javaClass.simpleName}: ${t.message}"
                            if (terminalReached.compareAndSet(false, true)) {
                                decisionRef.set("firstSessionConfigureFailed")
                                reasons.add("first_session_configure_threw")
                            }
                        }
                    }
                }
            }
        } finally {
            // Cleanup ordering: stop/abort/close whichever session is still open (wait
            // briefly), close the device (wait briefly), unregister+close both
            // ImageReaders, quit+join the HandlerThread. Runs after timeout, error, or
            // success. Never reopens the CameraDevice.
            val secondSession = secondSessionRef.get()
            if (secondSession != null) {
                try {
                    secondSession.stopRepeating()
                } catch (t: Throwable) {
                    Log.w(TAG, "secondSession.stopRepeating() failed: ${t.javaClass.simpleName}: ${t.message}")
                }
                try {
                    secondSession.abortCaptures()
                } catch (t: Throwable) {
                    Log.w(TAG, "secondSession.abortCaptures() failed: ${t.javaClass.simpleName}: ${t.message}")
                }
                try {
                    secondSession.close()
                } catch (t: Throwable) {
                    Log.w(TAG, "secondSession.close() failed: ${t.javaClass.simpleName}: ${t.message}")
                }
                try {
                    secondSessionClosedLatch.await(CLOSE_WAIT_MS, TimeUnit.MILLISECONDS)
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

            if (!firstReaderClosedFlag.get()) {
                try {
                    firstReader.setOnImageAvailableListener(null, null)
                } catch (t: Throwable) {
                    Log.w(TAG, "firstReader listener unregister (final) failed: ${t.javaClass.simpleName}: ${t.message}")
                }
                try {
                    firstReader.close()
                } catch (t: Throwable) {
                    Log.w(TAG, "firstReader.close() (final) failed: ${t.javaClass.simpleName}: ${t.message}")
                }
                firstReaderClosedFlag.set(true)
            }

            try {
                secondReader.setOnImageAvailableListener(null, null)
            } catch (t: Throwable) {
                Log.w(TAG, "secondReader listener unregister failed: ${t.javaClass.simpleName}: ${t.message}")
            }
            try {
                secondReader.close()
            } catch (t: Throwable) {
                Log.w(TAG, "secondReader.close() failed: ${t.javaClass.simpleName}: ${t.message}")
            }
            secondReaderClosedFlag.set(true)

            handlerThread.quitSafely()
            try {
                handlerThread.join(CLOSE_WAIT_MS)
            } catch (t: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }

        return buildResult(decisionRef.get())
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

    /** Largest supported size fitting within `maxWidth`/`maxHeight`; else the smallest supported size. */
    private fun selectInitialSize(sizes: List<Size>, maxWidth: Int, maxHeight: Int): Size {
        val fitting = sizes.filter { it.width <= maxWidth && it.height <= maxHeight }
        return if (fitting.isNotEmpty()) {
            fitting.maxWith(compareBy { area(it) })
        } else {
            sizes.minWith(compareBy { area(it) })
        }
    }

    /**
     * Selects the policy-derived reduced size: prefers supported sizes fitting within
     * `initial * scale` on both dimensions with a strictly lower area, choosing the largest
     * such candidate; falls back to the largest supported size with a strictly lower area than
     * [initial] when no size fits the scaled bound. Returns `null` when no supported size has a
     * strictly lower area than [initial].
     */
    private fun selectReducedSize(sizes: List<Size>, initial: Size, scale: Double): Size? {
        val boundedWidth = (initial.width * scale)
        val boundedHeight = (initial.height * scale)
        val initialArea = area(initial)
        val preferred = sizes.filter {
            it.width <= boundedWidth && it.height <= boundedHeight && area(it) < initialArea
        }
        if (preferred.isNotEmpty()) {
            return preferred.maxWith(compareBy { area(it) })
        }
        val lowerArea = sizes.filter { area(it) < initialArea }
        return if (lowerArea.isNotEmpty()) lowerArea.maxWith(compareBy { area(it) }) else null
    }

    private fun clampLong(raw: Long?, default: Long, min: Long, max: Long): Long {
        return (raw ?: default).coerceIn(min, max)
    }

    private fun clampInt(raw: Int?, default: Int, min: Int, max: Int): Int {
        val value = raw?.takeIf { it > 0 } ?: default
        return value.coerceIn(min, max)
    }
}
