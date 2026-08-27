package com.connects.vanguard_media_engine.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
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
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Phase 3-Unit L: diagnostic-only Android Camera2 PRIVATE ImageReader
 * HardwareBuffer native-render multi-frame render loop smoke harness.
 *
 * Extends the Unit K single-frame native-render smoke lifecycle into a
 * bounded multi-frame diagnostic loop: it creates one existing Phase 4A
 * native DAG/Vulkan smoke session (offscreen output surface) and renders
 * exactly [targetFrameCount] camera-produced HardwareBuffers through it via
 * [VanguardNativeBridge]. Requires API 29+. Never adds a preview UI,
 * MediaRecorder, CameraX session, dual/concurrent open, or new C++/JNI entry
 * points. Diagnostic/capability foundation only — Unit K itself is left
 * untouched and remains single-frame.
 */
class AndroidCamera2NativeRenderLoopSmokeHarness(private val context: Context) {

    companion object {
        private const val TAG = "AndroidCamera2NativeRenderLoopSmokeHarness"
        private const val DEFAULT_TIMEOUT_MS = 10000L
        private const val MIN_TIMEOUT_MS = 3000L
        private const val MAX_TIMEOUT_MS = 30000L
        private const val DEFAULT_MAX_WIDTH = 640
        private const val DEFAULT_MAX_HEIGHT = 480
        private const val MIN_DIMENSION = 160
        private const val MAX_DIMENSION = 1920
        private const val DEFAULT_FRAME_COUNT = 5
        private const val MIN_FRAME_COUNT = 2
        private const val MAX_FRAME_COUNT = 30
        private const val CLOSE_WAIT_MS = 2000L
        private const val IMAGE_READER_MAX_IMAGES = 3
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
        val targetFrameCount = clampInt((args?.get("frameCount") as? Number)?.toInt(), DEFAULT_FRAME_COUNT, MIN_FRAME_COUNT, MAX_FRAME_COUNT)

        val events = mutableListOf<String>()
        val reasons = mutableListOf<String>()
        val diagnosticsMap = mutableMapOf<String, Any?>()
        val nativeRenderRawFrames = mutableListOf<String>()

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
            renderedFrames: Int = 0,
            hardwareBufferFrameCount: Int = 0,
            hardwareBufferClosedCount: Int = 0,
            imageClosedCount: Int = 0,
            syncFenceAwaitedCount: Int = 0,
            syncFenceClosedCount: Int = 0,
            firstFrameTimestampNs: Long? = null,
            lastFrameTimestampNs: Long? = null,
            monotonicFrameTimestamps: Boolean = true,
            finalNativeRenderRaw: String? = null,
            sessionClosed: Boolean = false,
            deviceClosed: Boolean = false,
            imageReaderClosed: Boolean = false,
            nativeSessionCreated: Boolean = false,
            nativeSessionDestroyed: Boolean = false,
            outputSurfaceReleased: Boolean = false,
            surfaceTextureReleased: Boolean = false,
        ): Map<String, Any?> {
            val durationMs = SystemClock.elapsedRealtime() - startElapsed
            val allRawPassed = nativeRenderRawFrames.isNotEmpty() &&
                nativeRenderRawFrames.all { it.startsWith("status=PASS;") }
            val success = decision == "nativeRenderLoopPassed" &&
                renderedFrames == targetFrameCount && allRawPassed &&
                sessionClosed && deviceClosed && imageReaderClosed &&
                nativeSessionCreated && nativeSessionDestroyed &&
                outputSurfaceReleased && surfaceTextureReleased &&
                reasons.isEmpty()
            Log.i(
                TAG,
                "decision=$decision success=$success attemptedOpen=$attemptedOpen opened=$opened " +
                    "renderedFrames=$renderedFrames targetFrameCount=$targetFrameCount " +
                    "cameraId=$selectedCameraId durationMs=$durationMs",
            )
            return mapOf(
                "success" to success,
                "apiLevel" to apiLevel,
                "hasCameraPermission" to hasCameraPermission,
                "attemptedOpen" to attemptedOpen,
                "opened" to opened,
                "sessionConfigured" to sessionConfigured,
                "repeatingStarted" to repeatingStarted,
                "cameraId" to selectedCameraId,
                "selectedLensFacing" to selectedLensFacing,
                "selectedWidth" to selectedWidth,
                "selectedHeight" to selectedHeight,
                "imageFormatName" to "PRIVATE",
                "targetFrameCount" to targetFrameCount,
                "renderedFrames" to renderedFrames,
                "hardwareBufferFrameCount" to hardwareBufferFrameCount,
                "hardwareBufferClosedCount" to hardwareBufferClosedCount,
                "imageClosedCount" to imageClosedCount,
                "syncFenceAwaitedCount" to syncFenceAwaitedCount,
                "syncFenceClosedCount" to syncFenceClosedCount,
                "firstFrameTimestampNs" to firstFrameTimestampNs,
                "lastFrameTimestampNs" to lastFrameTimestampNs,
                "monotonicFrameTimestamps" to monotonicFrameTimestamps,
                "nativeRenderRawFrames" to nativeRenderRawFrames.toList(),
                "finalNativeRenderRaw" to finalNativeRenderRaw,
                "sessionClosed" to sessionClosed,
                "deviceClosed" to deviceClosed,
                "imageReaderClosed" to imageReaderClosed,
                "nativeSessionCreated" to nativeSessionCreated,
                "nativeSessionDestroyed" to nativeSessionDestroyed,
                "outputSurfaceReleased" to outputSurfaceReleased,
                "surfaceTextureReleased" to surfaceTextureReleased,
                "decision" to decision,
                "reasons" to reasons.toList(),
                "events" to events.toList(),
                "diagnostics" to diagnosticsMap.toMap(),
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
            diagnosticsMap["cameraIdListError"] = "${t.javaClass.simpleName}: ${t.message}"
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
            diagnosticsMap["cameraCharacteristicsError"] = "${t.javaClass.simpleName}: ${t.message}"
            null
        }
        val streamConfigurationMap = try {
            characteristics?.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        } catch (t: Throwable) {
            Log.w(TAG, "SCALER_STREAM_CONFIGURATION_MAP($cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
            diagnosticsMap["streamConfigurationMapError"] = "${t.javaClass.simpleName}: ${t.message}"
            null
        }
        val privateSizes = try {
            streamConfigurationMap?.getOutputSizes(ImageFormat.PRIVATE)?.toList() ?: emptyList()
        } catch (t: Throwable) {
            Log.w(TAG, "getOutputSizes(PRIVATE, $cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
            diagnosticsMap["outputSizesError"] = "${t.javaClass.simpleName}: ${t.message}"
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
        val handlerThread = HandlerThread("VGCamera2NativeRenderLoopSmoke")
        handlerThread.start()
        val bgHandler = Handler(handlerThread.looper)
        val imageReader = ImageReader.newInstance(
            selectedWidth, selectedHeight, ImageFormat.PRIVATE, IMAGE_READER_MAX_IMAGES,
            HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
        )
        val outputSurfaceTexture = SurfaceTexture(false).apply {
            setDefaultBufferSize(selectedWidth, selectedHeight)
        }
        val outputSurface = Surface(outputSurfaceTexture)

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
        val renderedFrames = AtomicInteger(0)
        val hardwareBufferFrameCount = AtomicInteger(0)
        val hardwareBufferClosedCount = AtomicInteger(0)
        val imageClosedCount = AtomicInteger(0)
        val syncFenceAwaitedCount = AtomicInteger(0)
        val syncFenceClosedCount = AtomicInteger(0)
        val firstFrameTimestampNs = AtomicLong(-1L)
        val lastFrameTimestampNs = AtomicLong(-1L)
        val monotonicFrameTimestampsFlag = AtomicBoolean(true)
        val finalNativeRenderRawRef = AtomicReference<String?>(null)
        val sessionClosedFlag = AtomicBoolean(false)
        val deviceClosedFlag = AtomicBoolean(false)
        val imageReaderClosedFlag = AtomicBoolean(false)
        val terminalReached = AtomicBoolean(false)
        val decisionRef = AtomicReference("openError")
        val ignoredCaptureFailuresAfterTerminal = AtomicInteger(0)
        val ignoredFramesAfterTerminal = AtomicInteger(0)

        var nativeSessionCreated = false
        var nativeSessionDestroyed = false
        var outputSurfaceReleased = false
        var surfaceTextureReleased = false
        var nativeBridge: VanguardNativeBridge? = null
        var sessionId: String? = null

        try {
            // ── Create the Phase 4A native DAG/Vulkan smoke session against the offscreen surface ──
            val diagnostics = VanguardDiagnostics()
            val bridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            nativeBridge = bridge
            val createResult = try {
                bridge.createAndroidDagPhase4ADecoderSmokeSession(
                    outputSurface, selectedWidth, selectedHeight,
                )
            } catch (t: Throwable) {
                Log.w(TAG, "createAndroidDagPhase4ADecoderSmokeSession failed: ${t.javaClass.simpleName}: ${t.message}")
                diagnosticsMap["nativeSessionCreateError"] = "${t.javaClass.simpleName}: ${t.message}"
                ""
            }
            if (!createResult.startsWith("status=OK;")) {
                reasons.add("native_session_create_failed")
                diagnosticsMap["nativeCreateResult"] = createResult.take(200)
                decisionRef.set("nativeSessionFailed")
            } else {
                val parsedSessionId = if (createResult.contains("sessionId=")) {
                    createResult.substringAfter("sessionId=").substringBefore(";").let { if (it.isNotBlank()) it else null }
                } else {
                    null
                }
                if (parsedSessionId == null) {
                    reasons.add("native_session_id_parse_failed")
                    diagnosticsMap["nativeCreateResult"] = createResult.take(200)
                    decisionRef.set("nativeSessionFailed")
                } else {
                    sessionId = parsedSessionId
                    nativeSessionCreated = true
                    val activeBridge = bridge
                    val activeSessionId = parsedSessionId

                    // Only now do we actually attempt to open the camera.
                    attemptedOpen = true

                    imageReader.setOnImageAvailableListener({ reader ->
                        val image = try {
                            reader.acquireLatestImage()
                        } catch (t: Throwable) {
                            Log.w(TAG, "acquireLatestImage failed: ${t.javaClass.simpleName}: ${t.message}")
                            null
                        } ?: return@setOnImageAvailableListener
                        try {
                            if (terminalReached.get()) {
                                try {
                                    image.hardwareBuffer?.close()
                                } catch (t: Throwable) {
                                    Log.w(TAG, "post-terminal hardwareBuffer.close() failed: ${t.javaClass.simpleName}: ${t.message}")
                                }
                                ignoredFramesAfterTerminal.incrementAndGet()
                                return@setOnImageAvailableListener
                            }
                            val hwBuf = image.hardwareBuffer
                            if (hwBuf == null) {
                                if (terminalReached.compareAndSet(false, true)) {
                                    events.add("hardwareBufferUnavailable")
                                    decisionRef.set("hardwareBufferUnavailable")
                                    reasons.add("hardware_buffer_unavailable")
                                    frameLatch.countDown()
                                } else {
                                    ignoredFramesAfterTerminal.incrementAndGet()
                                }
                            } else {
                                hardwareBufferFrameCount.incrementAndGet()
                                try {
                                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                        val fence = image.fence
                                        try {
                                            fence.await(Duration.ofMillis(FENCE_AWAIT_MS))
                                            syncFenceAwaitedCount.incrementAndGet()
                                        } finally {
                                            fence.close()
                                            syncFenceClosedCount.incrementAndGet()
                                        }
                                    }

                                    val frameIndex = renderedFrames.get()
                                    val renderRaw = try {
                                        activeBridge.renderAndroidDagPhase4ADecoderSmokeFrame(
                                            activeSessionId,
                                            hwBuf,
                                            selectedWidth,
                                            selectedHeight,
                                            image.timestamp / 1000,
                                            frameIndex,
                                        )
                                    } catch (t: Throwable) {
                                        Log.w(TAG, "renderAndroidDagPhase4ADecoderSmokeFrame failed: ${t.javaClass.simpleName}: ${t.message}")
                                        "status=EXCEPTION;${t.javaClass.simpleName}:${t.message}"
                                    }
                                    nativeRenderRawFrames.add(renderRaw)
                                    events.add("nativeRenderAttempted:frameIndex=$frameIndex")

                                    if (renderRaw.startsWith("status=PASS;")) {
                                        finalNativeRenderRawRef.set(renderRaw)
                                        val ts = image.timestamp
                                        if (firstFrameTimestampNs.get() < 0) {
                                            firstFrameTimestampNs.set(ts)
                                        }
                                        val previousTs = lastFrameTimestampNs.get()
                                        if (previousTs >= 0 && ts <= previousTs) {
                                            monotonicFrameTimestampsFlag.set(false)
                                        }
                                        lastFrameTimestampNs.set(ts)
                                        val newCount = renderedFrames.incrementAndGet()
                                        events.add("nativeRenderPassed:renderedFrames=$newCount")
                                        if (newCount >= targetFrameCount) {
                                            if (terminalReached.compareAndSet(false, true)) {
                                                decisionRef.set("nativeRenderLoopPassed")
                                                frameLatch.countDown()
                                            }
                                        }
                                    } else {
                                        if (terminalReached.compareAndSet(false, true)) {
                                            decisionRef.set("nativeRenderFailed")
                                            reasons.add("native_render_failed")
                                            diagnosticsMap["nativeRenderResult"] = renderRaw.take(200)
                                            frameLatch.countDown()
                                        } else {
                                            ignoredFramesAfterTerminal.incrementAndGet()
                                        }
                                    }
                                } finally {
                                    hwBuf.close()
                                    hardwareBufferClosedCount.incrementAndGet()
                                }
                            }
                        } finally {
                            image.close()
                            imageClosedCount.incrementAndGet()
                        }
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
                                diagnosticsMap["captureFailureReason"] = failure.reason
                                frameLatch.countDown()
                            } else {
                                ignoredCaptureFailuresAfterTerminal.incrementAndGet()
                            }
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
                                diagnosticsMap["errorCode"] = error
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
                        diagnosticsMap["openCameraError"] = "${e.javaClass.simpleName}: ${e.message}"
                        terminalReached.set(true)
                        decisionRef.set("permissionRequired")
                        openLatch.countDown()
                    } catch (t: Throwable) {
                        Log.w(TAG, "openCamera failed: ${t.javaClass.simpleName}: ${t.message}")
                        diagnosticsMap["openCameraError"] = "${t.javaClass.simpleName}: ${t.message}"
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

                                                val allFramesInTime = frameLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
                                                if (!allFramesInTime) {
                                                    events.add("frameTimeout")
                                                    if (terminalReached.compareAndSet(false, true)) {
                                                        decisionRef.set("frameTimeout")
                                                        reasons.add("frame_timeout")
                                                    }
                                                }
                                            } catch (t: Throwable) {
                                                Log.w(TAG, "setRepeatingRequest failed: ${t.javaClass.simpleName}: ${t.message}")
                                                diagnosticsMap["setRepeatingRequestError"] = "${t.javaClass.simpleName}: ${t.message}"
                                                if (terminalReached.compareAndSet(false, true)) {
                                                    decisionRef.set("repeatingRequestFailed")
                                                    reasons.add("repeating_request_failed")
                                                }
                                            }
                                        }
                                    }
                                } catch (t: Throwable) {
                                    Log.w(TAG, "createCaptureSession failed: ${t.javaClass.simpleName}: ${t.message}")
                                    diagnosticsMap["createCaptureSessionError"] = "${t.javaClass.simpleName}: ${t.message}"
                                    if (terminalReached.compareAndSet(false, true)) {
                                        decisionRef.set("sessionConfigureFailed")
                                        reasons.add("session_configure_threw")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } finally {
            // Cleanup ordering: stop/abort repeating, close session (wait briefly),
            // close device (wait briefly), unregister ImageReader listener, close
            // ImageReader, destroy native session (if created), release output
            // surface, release SurfaceTexture, quit HandlerThread.
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

            if (nativeSessionCreated) {
                val sid = sessionId
                val bridge = nativeBridge
                if (bridge != null && sid != null) {
                    try {
                        val destroyResult = bridge.destroyAndroidDagPhase4ADecoderSmokeSession(sid)
                        if (destroyResult.startsWith("status=OK;")) {
                            nativeSessionDestroyed = true
                        } else {
                            diagnosticsMap["nativeSessionDestroyResult"] = destroyResult.take(200)
                            reasons.add("native_session_destroy_failed")
                        }
                    } catch (t: Throwable) {
                        Log.w(TAG, "destroyAndroidDagPhase4ADecoderSmokeSession failed: ${t.javaClass.simpleName}: ${t.message}")
                        diagnosticsMap["nativeSessionDestroyError"] = "${t.javaClass.simpleName}: ${t.message}"
                        reasons.add("native_session_destroy_failed")
                    }
                } else {
                    diagnosticsMap["nativeSessionDestroySkippedReason"] = "bridgeOrSessionIdMissing"
                    reasons.add("native_session_destroy_not_invoked")
                }
            }

            try {
                outputSurface.release()
            } catch (t: Throwable) {
                Log.w(TAG, "outputSurface.release() failed: ${t.javaClass.simpleName}: ${t.message}")
            }
            outputSurfaceReleased = true

            try {
                outputSurfaceTexture.release()
            } catch (t: Throwable) {
                Log.w(TAG, "outputSurfaceTexture.release() failed: ${t.javaClass.simpleName}: ${t.message}")
            }
            surfaceTextureReleased = true

            if (ignoredCaptureFailuresAfterTerminal.get() > 0) {
                diagnosticsMap["ignoredCaptureFailuresAfterTerminal"] = ignoredCaptureFailuresAfterTerminal.get()
            }
            if (ignoredFramesAfterTerminal.get() > 0) {
                diagnosticsMap["ignoredFramesAfterTerminal"] = ignoredFramesAfterTerminal.get()
            }

            handlerThread.quitSafely()
        }

        return buildResult(
            decision = decisionRef.get(),
            opened = openedFlag.get(),
            sessionConfigured = sessionConfiguredFlag.get(),
            repeatingStarted = repeatingStartedFlag.get(),
            renderedFrames = renderedFrames.get(),
            hardwareBufferFrameCount = hardwareBufferFrameCount.get(),
            hardwareBufferClosedCount = hardwareBufferClosedCount.get(),
            imageClosedCount = imageClosedCount.get(),
            syncFenceAwaitedCount = syncFenceAwaitedCount.get(),
            syncFenceClosedCount = syncFenceClosedCount.get(),
            firstFrameTimestampNs = firstFrameTimestampNs.get().let { if (it < 0) null else it },
            lastFrameTimestampNs = lastFrameTimestampNs.get().let { if (it < 0) null else it },
            monotonicFrameTimestamps = monotonicFrameTimestampsFlag.get(),
            finalNativeRenderRaw = finalNativeRenderRawRef.get(),
            sessionClosed = sessionClosedFlag.get(),
            deviceClosed = deviceClosedFlag.get(),
            imageReaderClosed = imageReaderClosedFlag.get(),
            nativeSessionCreated = nativeSessionCreated,
            nativeSessionDestroyed = nativeSessionDestroyed,
            outputSurfaceReleased = outputSurfaceReleased,
            surfaceTextureReleased = surfaceTextureReleased,
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
