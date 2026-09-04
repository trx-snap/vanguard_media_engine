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
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.util.Range
import android.util.Size
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs

/**
 * P3-CAM-THERMAL-ACT-FPS-REQUEST-ACTION: diagnostic-only Android Camera2
 * single-camera repeating-request AE target FPS range mutation smoke.
 *
 * Opens exactly one real Camera2 device, configures a single YUV_420_888
 * [ImageReader]-backed capture session, starts a repeating request with an
 * initial [CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE], then - using a
 * synthetic serious-thermal policy tuple mirrored from
 * `vg_camera2_thermal_load_shedding_policy.dart` (thermalState=serious,
 * wasRecording=true, hadSecondaryCamera=false, minFpsFloor=15) - mutates the
 * same [CaptureRequest.Builder] to a strictly-lower-upper AE FPS range,
 * re-tags it, and re-issues the repeating request on the same session.
 *
 * PASS requires observing at least two *consecutive* completed captures
 * tagged with the updated request after the second `setRepeatingRequest`
 * call - never by reading local builder state - guarding against the
 * in-flight race where stale frames from the initial range arrive after the
 * switch. Never opens a second camera, never reconfigures the session
 * (`sessionConfigureCount == 1`), never touches PowerManager/OS thermal
 * listeners, never starts a real recording/MediaRecorder/encoder, and never
 * touches the renderer or product UI. Diagnostic/capability foundation only.
 */
class AndroidCamera2ThermalFpsActionSmokeHarness(private val context: Context) {

    companion object {
        private const val TAG = "AndroidCamera2ThermalFpsActionSmokeHarness"
        private const val DEFAULT_TIMEOUT_MS = 8000L
        private const val MIN_TIMEOUT_MS = 2000L
        private const val MAX_TIMEOUT_MS = 20000L
        private const val DEFAULT_MAX_WIDTH = 640
        private const val DEFAULT_MAX_HEIGHT = 480
        private const val MIN_DIMENSION = 160
        private const val MAX_DIMENSION = 1920
        private const val CLOSE_WAIT_MS = 2000L
        private const val IMAGE_READER_MAX_IMAGES = 2
        private const val MIN_FPS_FLOOR = 15
        private const val THERMAL_STATE_RAW_SERIOUS = 2
        private const val REQUEST_TAG_INITIAL = "vg-thermal-fps-initial"
        private const val REQUEST_TAG_UPDATED = "vg-thermal-fps-updated"

        const val PROOF_BOUNDARY = "single_camera_repeating_request_ae_fps_range_mutation_" +
            "synthetic_thermal_no_forced_heat_no_recording_no_encoder"

        /**
         * Mirrors `VGCamera2ThermalLoadSheddingPlanner._calculateReducedFps` in
         * vg_camera2_thermal_load_shedding_policy.dart exactly, with minFpsFloor=15.
         */
        private fun calculateReducedFps(currentFps: Int): Int {
            if (currentFps > 30) return 30
            if (currentFps > 24) return 24
            if (currentFps > MIN_FPS_FLOOR) return MIN_FPS_FLOOR
            if (currentFps > 1) return currentFps - 1
            return 1
        }

        private fun selectInitialRange(ranges: List<Range<Int>>): Range<Int> {
            val preferred = ranges.filter { it.upper >= 30 }
            val pool = if (preferred.isNotEmpty()) preferred else ranges
            return pool.maxWithOrNull(compareBy<Range<Int>> { it.upper }.thenBy { it.lower })!!
        }

        private fun selectReducedRange(candidates: List<Range<Int>>, targetFps: Int): Range<Int> {
            return candidates.minWithOrNull(
                compareBy<Range<Int>> { abs(it.upper - targetFps) }.thenByDescending { it.upper },
            )!!
        }

        private fun rangeToMap(range: Range<Int>?): Map<String, Int>? =
            range?.let { mapOf("lower" to it.lower, "upper" to it.upper) }
    }

    fun run(args: Map<*, *>?): Map<String, Any?> {
        val startElapsed = SystemClock.elapsedRealtime()
        val apiLevel = Build.VERSION.SDK_INT
        val hasCameraPermission = hasCameraPermission()
        val requestedCameraId = (args?.get("cameraId") as? String)?.trim()
        val timeoutMs = clampLong((args?.get("timeoutMs") as? Number)?.toLong(), DEFAULT_TIMEOUT_MS, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
        val maxWidth = clampInt((args?.get("maxWidth") as? Number)?.toInt(), DEFAULT_MAX_WIDTH, MIN_DIMENSION, MAX_DIMENSION)
        val maxHeight = clampInt((args?.get("maxHeight") as? Number)?.toInt(), DEFAULT_MAX_HEIGHT, MIN_DIMENSION, MAX_DIMENSION)

        val events = Collections.synchronizedList(mutableListOf<String>())
        val reasons = Collections.synchronizedList(mutableListOf<String>())
        val diagnostics = Collections.synchronizedMap(mutableMapOf<String, Any?>())

        var attemptedOpen = false
        var selectedCameraId: String? = null
        var selectedLensFacing = "unknown"
        var selectedWidth = 0
        var selectedHeight = 0
        var initialAeRange: Range<Int>? = null
        var reducedAeRange: Range<Int>? = null
        var policyTargetFps = 0

        val openedFlag = AtomicBoolean(false)
        val sessionConfiguredFlag = AtomicBoolean(false)
        val initialRepeatingStartedFlag = AtomicBoolean(false)
        val updatedRepeatingStartedFlag = AtomicBoolean(false)
        val initialCaptureCompletedFlag = AtomicBoolean(false)
        val updatedConsecutiveCount = AtomicInteger(0)
        val updatedTwoReached = AtomicBoolean(false)
        val frozenUpdatedConsecutiveCount = AtomicInteger(0)
        val sessionClosedFlag = AtomicBoolean(false)
        val deviceClosedFlag = AtomicBoolean(false)
        val imageReaderClosedFlag = AtomicBoolean(false)
        val sessionConfigureCount = AtomicInteger(0)
        val hardwareAppliedRangeConfirmedFlag = AtomicBoolean(false)
        val aeRangeReadFlag = AtomicBoolean(false)
        val expectUpdatedPhase = AtomicBoolean(false)
        val terminalReached = AtomicBoolean(false)
        val decisionRef = AtomicReference("openError")

        fun buildResult(decision: String): Map<String, Any?> {
            val durationMs = SystemClock.elapsedRealtime() - startElapsed
            val opened = openedFlag.get()
            val sessionConfigured = sessionConfiguredFlag.get()
            val initialRepeatingStarted = initialRepeatingStartedFlag.get()
            val updatedRepeatingStarted = updatedRepeatingStartedFlag.get()
            val initialCaptureCompleted = initialCaptureCompletedFlag.get()
            // Once two consecutive updated completions are observed, the proof is frozen: later
            // cleanup/shutdown capture failures or stale/late callbacks must never reset this count
            // or downgrade the outcome, so the live counter is only read before the proof lands.
            val updatedTwoReachedProof = updatedTwoReached.get()
            val updatedConsecutiveCaptureCount = if (updatedTwoReachedProof) {
                frozenUpdatedConsecutiveCount.get()
            } else {
                updatedConsecutiveCount.get()
            }
            val updatedCaptureCompleted = updatedTwoReachedProof || updatedConsecutiveCaptureCount >= 1
            val sessionClosed = sessionClosedFlag.get()
            val deviceClosed = deviceClosedFlag.get()
            val imageReaderClosed = imageReaderClosedFlag.get()
            val reducedStrictlyLower = initialAeRange != null && reducedAeRange != null &&
                reducedAeRange!!.upper < initialAeRange!!.upper
            // Fail closed: a present-but-mismatched CONTROL_AE_TARGET_FPS_RANGE result key means the
            // hardware never actually applied the reduced range, so the mutation claim cannot pass.
            val aeFpsRangeResultMismatch = reasons.contains("ae_fps_range_result_mismatch")
            val aeTargetFpsRangeMutated = decision == "fpsRangeMutated" &&
                updatedTwoReachedProof &&
                !aeFpsRangeResultMismatch
            val success = decision == "fpsRangeMutated" &&
                hasCameraPermission &&
                opened &&
                sessionConfigured &&
                initialRepeatingStarted &&
                updatedRepeatingStarted &&
                initialCaptureCompleted &&
                updatedCaptureCompleted &&
                updatedTwoReachedProof &&
                reducedStrictlyLower &&
                sessionClosed &&
                deviceClosed &&
                imageReaderClosed &&
                sessionConfigureCount.get() == 1 &&
                !aeFpsRangeResultMismatch &&
                aeTargetFpsRangeMutated
            Log.i(
                TAG,
                "decision=$decision success=$success attemptedOpen=$attemptedOpen opened=$opened " +
                    "updatedConsecutiveCaptureCount=$updatedConsecutiveCaptureCount cameraId=$selectedCameraId " +
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
                "sessionConfigured" to sessionConfigured,
                "initialRepeatingStarted" to initialRepeatingStarted,
                "updatedRepeatingStarted" to updatedRepeatingStarted,
                "initialCaptureCompleted" to initialCaptureCompleted,
                "updatedCaptureCompleted" to updatedCaptureCompleted,
                "updatedConsecutiveCaptureCount" to updatedConsecutiveCaptureCount,
                "cameraId" to selectedCameraId,
                "selectedLensFacing" to selectedLensFacing,
                "selectedWidth" to selectedWidth,
                "selectedHeight" to selectedHeight,
                "imageFormatName" to "YUV_420_888",
                "templateUsed" to "TEMPLATE_PREVIEW",
                "initialAeTargetFpsRange" to rangeToMap(initialAeRange),
                "reducedAeTargetFpsRange" to rangeToMap(reducedAeRange),
                "policyTargetFps" to policyTargetFps,
                "syntheticPolicyInput" to true,
                "thermalStateRaw" to THERMAL_STATE_RAW_SERIOUS,
                "wasRecordingPolicyInput" to true,
                "hadSecondaryCameraPolicyInput" to false,
                "recordingActive" to false,
                "aeTargetFpsRangeMutated" to aeTargetFpsRangeMutated,
                "captureRequestUpdated" to aeTargetFpsRangeMutated,
                "repeatingRequestMutated" to aeTargetFpsRangeMutated,
                "hardwareAppliedRangeConfirmed" to hardwareAppliedRangeConfirmedFlag.get(),
                "frameCadenceChangeProven" to false,
                "sessionConfigureCount" to sessionConfigureCount.get(),
                "surfaceCount" to 1,
                "reusedRequestBuilder" to (initialRepeatingStarted && updatedRepeatingStarted),
                "sessionClosed" to sessionClosed,
                "deviceClosed" to deviceClosed,
                "imageReaderClosed" to imageReaderClosed,
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
                "cameraSessionReconfigured" to false,
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

        // Guard 5: no YUV_420_888 output sizes.
        if (positiveYuvSizes.isEmpty()) {
            reasons.add("no_yuv_420_888_output_sizes")
            return buildResult("unsupportedStream")
        }

        val selectedSize = selectYuvSize(positiveYuvSizes, maxWidth, maxHeight)
        selectedWidth = selectedSize.width
        selectedHeight = selectedSize.height

        val aeAvailableRanges = try {
            characteristics?.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                ?.toList()
                ?.filter { it.upper > 0 && it.lower > 0 && it.upper >= it.lower }
                ?: emptyList()
        } catch (t: Throwable) {
            Log.w(TAG, "CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES($cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
            diagnostics["aeAvailableTargetFpsRangesError"] = "${t.javaClass.simpleName}: ${t.message}"
            emptyList()
        }

        // Guard 6: no advertised AE target FPS ranges.
        if (aeAvailableRanges.isEmpty()) {
            reasons.add("no_ae_target_fps_ranges")
            return buildResult("unsupportedAeFpsRanges")
        }

        val initial = selectInitialRange(aeAvailableRanges)
        initialAeRange = initial
        policyTargetFps = calculateReducedFps(initial.upper)
        val reducedCandidates = aeAvailableRanges.filter { it.upper < initial.upper }

        // Guard 7: no supported range with a strictly lower upper bound.
        if (reducedCandidates.isEmpty()) {
            reasons.add("no_lower_fps_range_available")
            return buildResult("noLowerFpsRangeAvailable")
        }

        val reduced = selectReducedRange(reducedCandidates, policyTargetFps)
        reducedAeRange = reduced

        // All guards passed - allocate resources.
        val handlerThread = HandlerThread("VGCamera2ThermalFpsActionSmoke")
        handlerThread.start()
        val bgHandler = Handler(handlerThread.looper)
        val imageReader = ImageReader.newInstance(
            selectedWidth, selectedHeight, ImageFormat.YUV_420_888, IMAGE_READER_MAX_IMAGES,
        )

        val openLatch = CountDownLatch(1)
        val configureLatch = CountDownLatch(1)
        val initialCaptureLatch = CountDownLatch(1)
        val updatedTwoLatch = CountDownLatch(1)
        val deviceClosedLatch = CountDownLatch(1)
        val sessionClosedLatch = CountDownLatch(1)

        val deviceRef = AtomicReference<CameraDevice?>(null)
        val sessionRef = AtomicReference<CameraCaptureSession?>(null)

        attemptedOpen = true

        try {
            imageReader.setOnImageAvailableListener({ reader ->
                try {
                    reader.acquireLatestImage()?.close()
                } catch (t: Throwable) {
                    Log.w(TAG, "acquireLatestImage/close failed: ${t.javaClass.simpleName}: ${t.message}")
                }
            }, bgHandler)

            val captureCallback = object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    result: TotalCaptureResult,
                ) {
                    val tag = request.tag
                    if (terminalReached.get()) {
                        // Proof (or another terminal decision) already landed - post-terminal
                        // callbacks must never mutate counters/reasons/diagnostics.
                        events.add("ignoredAfterTerminal:completed:$tag")
                        return
                    }
                    if (!expectUpdatedPhase.get()) {
                        if (tag == REQUEST_TAG_INITIAL) {
                            events.add("onCaptureCompleted:initial")
                            if (initialCaptureCompletedFlag.compareAndSet(false, true)) {
                                initialCaptureLatch.countDown()
                            }
                        }
                        return
                    }
                    // expectUpdatedPhase == true
                    if (tag != REQUEST_TAG_UPDATED) {
                        // Stale frame from the pre-switch pipeline - guards the in-flight race (C3).
                        events.add("staleTagObservedDuringUpdatedPhase")
                        if (!updatedTwoReached.get()) {
                            updatedConsecutiveCount.set(0)
                        }
                        return
                    }
                    events.add("onCaptureCompleted:updated")
                    if (aeRangeReadFlag.compareAndSet(false, true)) {
                        val observed = try {
                            // Reading back requires CaptureResult.Key, not CaptureRequest.Key - these
                            // are distinct nested types in the Camera2 API despite sharing a name.
                            result.get(CaptureResult.CONTROL_AE_TARGET_FPS_RANGE)
                        } catch (t: Throwable) {
                            Log.w(TAG, "read CONTROL_AE_TARGET_FPS_RANGE failed: ${t.javaClass.simpleName}: ${t.message}")
                            null
                        }
                        when {
                            observed == null -> {
                                reasons.add("ae_fps_range_result_key_missing")
                                hardwareAppliedRangeConfirmedFlag.set(false)
                            }
                            observed == reduced -> {
                                hardwareAppliedRangeConfirmedFlag.set(true)
                            }
                            else -> {
                                reasons.add("ae_fps_range_result_mismatch")
                                hardwareAppliedRangeConfirmedFlag.set(false)
                                diagnostics["observedAeTargetFpsRange"] = rangeToMap(observed)
                            }
                        }
                    }
                    val newCount = updatedConsecutiveCount.incrementAndGet()
                    if (newCount >= 2 && updatedTwoReached.compareAndSet(false, true)) {
                        frozenUpdatedConsecutiveCount.set(newCount)
                        updatedTwoLatch.countDown()
                    }
                }

                override fun onCaptureFailed(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    failure: CaptureFailure,
                ) {
                    val tag = request.tag
                    if (terminalReached.get()) {
                        // Proof (or another terminal decision) already landed - post-terminal
                        // callbacks must never mutate counters/reasons/diagnostics.
                        events.add("ignoredAfterTerminal:failed:$tag")
                        return
                    }
                    events.add("onCaptureFailed:$tag")
                    // The two-updated-completions proof, once reached, is frozen: a failure that
                    // races in before the main thread flips terminalReached must not reset the
                    // counter or downgrade the decision away from fpsRangeMutated.
                    val proofAlreadyReached = updatedTwoReached.get()
                    if (tag == REQUEST_TAG_UPDATED && !proofAlreadyReached && !terminalReached.get()) {
                        updatedConsecutiveCount.set(0)
                    }
                    if (!proofAlreadyReached && terminalReached.compareAndSet(false, true)) {
                        decisionRef.set("captureFailed")
                        reasons.add("capture_failed")
                        diagnostics["captureFailureReason"] = failure.reason
                    }
                    initialCaptureLatch.countDown()
                    updatedTwoLatch.countDown()
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
                    initialCaptureLatch.countDown()
                    updatedTwoLatch.countDown()
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
                    initialCaptureLatch.countDown()
                    updatedTwoLatch.countDown()
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
                                    sessionConfigureCount.incrementAndGet()
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
                                        requestBuilder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, initial)
                                        requestBuilder.setTag(REQUEST_TAG_INITIAL)
                                        session.setRepeatingRequest(requestBuilder.build(), captureCallback, bgHandler)
                                        initialRepeatingStartedFlag.set(true)
                                        events.add("initialRepeatingRequestStarted")

                                        val initialInTime = initialCaptureLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
                                        if (!initialInTime) {
                                            events.add("initialRangeTimeout")
                                            if (terminalReached.compareAndSet(false, true)) {
                                                decisionRef.set("initialRangeNeverObserved")
                                                reasons.add("initial_range_never_observed")
                                            }
                                        } else if (!terminalReached.get() && initialCaptureCompletedFlag.get()) {
                                            // Synthetic serious-thermal load-shedding action - mirrors the Dart
                                            // policy tuple exactly; never touches PowerManager/OS thermal state.
                                            events.add("syntheticThermalActionTriggered")
                                            try {
                                                expectUpdatedPhase.set(true)
                                                requestBuilder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, reduced)
                                                requestBuilder.setTag(REQUEST_TAG_UPDATED)
                                                session.setRepeatingRequest(requestBuilder.build(), captureCallback, bgHandler)
                                                updatedRepeatingStartedFlag.set(true)
                                                events.add("updatedRepeatingRequestStarted")

                                                val updatedInTime = updatedTwoLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
                                                if (!updatedInTime) {
                                                    events.add("updatedRangeTimeout")
                                                    if (terminalReached.compareAndSet(false, true)) {
                                                        decisionRef.set("updatedRangeNeverObserved")
                                                        reasons.add("updated_range_never_observed")
                                                    }
                                                } else if (!terminalReached.get() && updatedTwoReached.get()) {
                                                    if (terminalReached.compareAndSet(false, true)) {
                                                        decisionRef.set("fpsRangeMutated")
                                                    }
                                                }
                                            } catch (t: Throwable) {
                                                Log.w(TAG, "updated setRepeatingRequest failed: ${t.javaClass.simpleName}: ${t.message}")
                                                diagnostics["updatedSetRepeatingRequestError"] = "${t.javaClass.simpleName}: ${t.message}"
                                                if (terminalReached.compareAndSet(false, true)) {
                                                    decisionRef.set("updatedRepeatingRequestFailed")
                                                    reasons.add("updated_repeating_request_failed")
                                                }
                                            }
                                        }
                                    } catch (t: Throwable) {
                                        Log.w(TAG, "initial setRepeatingRequest failed: ${t.javaClass.simpleName}: ${t.message}")
                                        diagnostics["initialSetRepeatingRequestError"] = "${t.javaClass.simpleName}: ${t.message}"
                                        if (terminalReached.compareAndSet(false, true)) {
                                            decisionRef.set("initialRepeatingRequestFailed")
                                            reasons.add("initial_repeating_request_failed")
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
            // Cleanup ordering matches AndroidCamera2ImageReaderFrameSmokeHarness: stop/abort
            // repeating, close session (wait briefly), close device (wait briefly), unregister
            // ImageReader listener, close ImageReader, quit+join HandlerThread. Runs after
            // timeout, error, or success.
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
