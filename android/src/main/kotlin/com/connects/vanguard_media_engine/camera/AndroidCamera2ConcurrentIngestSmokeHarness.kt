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
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.Image
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.util.Size
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * P3-CAM-CONCURRENT: diagnostic-only Android Camera2 dual-camera concurrent
 * PRIVATE AHardwareBuffer ingest smoke harness.
 *
 * Requires API 30+. Selects a concurrent-capable camera pair from
 * [CameraManager.concurrentCameraIds], confirms
 * [CameraManager.isConcurrentSessionConfigurationSupported], opens both
 * cameras before configuring either capture session, configures one PRIVATE
 * [ImageReader] session per camera, starts repeating preview requests,
 * captures at least one AHardwareBuffer frame from each camera, hands each
 * frame to the new P3 native ingest JNI route, and tears down
 * deterministically. Kotlin remains the sole owner of Camera2
 * device/session lifecycle; native only validates admission and
 * imports/releases the AHardwareBuffer per ingest call. No PiP, split
 * layout, compositor, recording/export, or app wiring.
 */
class AndroidCamera2ConcurrentIngestSmokeHarness(private val context: Context) {

    companion object {
        private const val TAG = "AndroidCamera2ConcurrentIngestSmokeHarness"
        private const val DEFAULT_TIMEOUT_MS = 10000L
        private const val MIN_TIMEOUT_MS = 2000L
        private const val MAX_TIMEOUT_MS = 20000L
        private const val DEFAULT_MAX_WIDTH = 640
        private const val DEFAULT_MAX_HEIGHT = 480
        private const val MIN_DIMENSION = 160
        private const val MAX_DIMENSION = 1920
        private const val CLOSE_WAIT_MS = 2000L
        private const val IMAGE_READER_MAX_IMAGES = 2
        private const val FENCE_AWAIT_MS = 1000L
        private const val PROOF_BOUNDARY =
            "android_camera2_dual_camera_concurrent_private_ahardwarebuffer_ingest_validation_" +
                "no_pip_no_split_no_compositor_no_recording_no_export"

        private fun extractSessionId(raw: String): String? {
            for (part in raw.split(";")) {
                val kv = part.split("=")
                if (kv.size == 2 && kv[0] == "sessionId") return kv[1]
            }
            return null
        }
    }

    private class CameraSlot(val cameraId: String) {
        var device: CameraDevice? = null
        var session: CameraCaptureSession? = null
        var imageReader: ImageReader? = null
        var pendingRequestBuilder: CaptureRequest.Builder? = null
        val frameReceivedFlag = AtomicBoolean(false)
        val deviceClosedLatch = CountDownLatch(1)
        val sessionClosedLatch = CountDownLatch(1)
        var lastImage: Image? = null
        var lastHardwareBuffer: HardwareBuffer? = null
        var frameTimestampNs: Long = -1L
        var frameWidth: Int = 0
        var frameHeight: Int = 0
        var ingestRaw: String = "status=FAIL;reason=not_run"
    }

    fun run(args: Map<*, *>?): Map<String, Any?> {
        val startElapsed = SystemClock.elapsedRealtime()
        val apiLevel = Build.VERSION.SDK_INT
        val hasCameraPermission = hasCameraPermission()
        val timeoutMs = clampLong((args?.get("timeoutMs") as? Number)?.toLong(), DEFAULT_TIMEOUT_MS, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
        val maxWidth = clampInt((args?.get("maxWidth") as? Number)?.toInt(), DEFAULT_MAX_WIDTH, MIN_DIMENSION, MAX_DIMENSION)
        val maxHeight = clampInt((args?.get("maxHeight") as? Number)?.toInt(), DEFAULT_MAX_HEIGHT, MIN_DIMENSION, MAX_DIMENSION)

        val events = mutableListOf<String>()
        val reasons = mutableListOf<String>()
        val diagnostics = mutableMapOf<String, Any?>()

        var selectedCameraIds: List<String> = emptyList()
        val openedCameraCount = AtomicInteger(0)
        val configuredSessionCount = AtomicInteger(0)
        val capturedFrameCount = AtomicInteger(0)
        val nativeIngestPassCount = AtomicInteger(0)
        val syncFenceAwaitedCount = AtomicInteger(0)
        val syncFenceClosedCount = AtomicInteger(0)
        var nativeCreateRaw = "status=FAIL;reason=not_run"
        var nativeDestroyRaw = "status=FAIL;reason=not_run"

        fun buildResult(decision: String): Map<String, Any?> {
            val durationMs = SystemClock.elapsedRealtime() - startElapsed
            val pass = decision == "ingested" &&
                openedCameraCount.get() == 2 && configuredSessionCount.get() == 2 &&
                capturedFrameCount.get() == 2 && nativeIngestPassCount.get() == 2 &&
                nativeDestroyRaw.startsWith("status=PASS")
            Log.i(
                TAG,
                "decision=$decision pass=$pass selectedCameraIds=$selectedCameraIds " +
                    "openedCameraCount=${openedCameraCount.get()} configuredSessionCount=${configuredSessionCount.get()} " +
                    "capturedFrameCount=${capturedFrameCount.get()} nativeIngestPassCount=${nativeIngestPassCount.get()} " +
                    "durationMs=$durationMs",
            )
            return mapOf(
                "pass" to pass,
                "decision" to decision,
                "reasons" to reasons.toList(),
                "apiLevel" to apiLevel,
                "hasCameraPermission" to hasCameraPermission,
                "selectedCameraIds" to selectedCameraIds,
                "openedCameraCount" to openedCameraCount.get(),
                "configuredSessionCount" to configuredSessionCount.get(),
                "capturedFrameCount" to capturedFrameCount.get(),
                "nativeIngestPassCount" to nativeIngestPassCount.get(),
                "syncFenceAwaitedCount" to syncFenceAwaitedCount.get(),
                "syncFenceClosedCount" to syncFenceClosedCount.get(),
                "nativeCreateRaw" to nativeCreateRaw,
                "nativeDestroyRaw" to nativeDestroyRaw,
                "events" to events.toList(),
                "diagnostics" to diagnostics.toMap(),
                "proofBoundary" to PROOF_BOUNDARY,
                "durationMs" to durationMs,
            )
        }

        // Guard 0: API level below 30 (required for concurrentCameraIds /
        // isConcurrentSessionConfigurationSupported).
        if (apiLevel < Build.VERSION_CODES.R) {
            reasons.add("api_below_30")
            return buildResult("unsupportedApi")
        }

        // Guard 1: permission absent.
        if (!hasCameraPermission) {
            reasons.add("camera_permission_absent")
            return buildResult("permissionRequired")
        }

        // Guard 2: no CameraManager.
        val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        if (cameraManager == null) {
            reasons.add("camera_manager_unavailable")
            return buildResult("cameraManagerUnavailable")
        }

        // Guard 3: no concurrent camera combination advertised.
        val concurrentSets = try {
            cameraManager.concurrentCameraIds
        } catch (t: Throwable) {
            Log.w(TAG, "concurrentCameraIds failed: ${t.javaClass.simpleName}: ${t.message}")
            diagnostics["concurrentCameraIdsError"] = "${t.javaClass.simpleName}: ${t.message}"
            emptySet()
        }
        val candidateSet = concurrentSets.firstOrNull { it.size >= 2 }
        if (candidateSet == null) {
            reasons.add("no_concurrent_camera_combination")
            return buildResult("concurrentNotSupported")
        }
        val cameraIds = selectConcurrentCameraPair(cameraManager, candidateSet, diagnostics)
        selectedCameraIds = cameraIds

        // Guard 4: PRIVATE output sizes for both cameras.
        val selectedSizes = mutableMapOf<String, Size>()
        for (id in cameraIds) {
            val characteristics = try {
                cameraManager.getCameraCharacteristics(id)
            } catch (t: Throwable) {
                Log.w(TAG, "getCameraCharacteristics($id) failed: ${t.javaClass.simpleName}: ${t.message}")
                diagnostics["cameraCharacteristicsError:$id"] = "${t.javaClass.simpleName}: ${t.message}"
                null
            }
            val streamConfigurationMap = try {
                characteristics?.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            } catch (t: Throwable) {
                diagnostics["streamConfigurationMapError:$id"] = "${t.javaClass.simpleName}: ${t.message}"
                null
            }
            val privateSizes = try {
                streamConfigurationMap?.getOutputSizes(ImageFormat.PRIVATE)?.toList() ?: emptyList()
            } catch (t: Throwable) {
                diagnostics["outputSizesError:$id"] = "${t.javaClass.simpleName}: ${t.message}"
                emptyList()
            }
            val positiveSizes = privateSizes.filter { it.width > 0 && it.height > 0 }
            if (positiveSizes.isEmpty()) {
                reasons.add("no_private_output_sizes:$id")
                return buildResult("unsupportedStream")
            }
            selectedSizes[id] = selectPrivateSize(positiveSizes, maxWidth, maxHeight)
        }

        // All static guards passed — allocate resources.
        val handlerThread = HandlerThread("VGCamera2ConcurrentIngestSmoke")
        handlerThread.start()
        val bgHandler = Handler(handlerThread.looper)
        val bgExecutor = Executor { command -> bgHandler.post(command) }

        val slots = cameraIds.map { id -> CameraSlot(id) }
        for (slot in slots) {
            val size = selectedSizes[slot.cameraId]!!
            slot.imageReader = ImageReader.newInstance(
                size.width, size.height, ImageFormat.PRIVATE, IMAGE_READER_MAX_IMAGES,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )
        }

        val terminalReached = AtomicBoolean(false)
        val decisionRef = AtomicReference("openError")

        val nativeDiagnostics = VanguardDiagnostics()
        val nativeBridge = VanguardNativeBridge(
            lifecycleObserver = VanguardLifecycleObserver(nativeDiagnostics),
            diagnostics = nativeDiagnostics,
            codecAdapter = null,
        )
        var nativeSessionId: String? = null
        var nativeDestroyed = false

        try {
            // Guard 5: isConcurrentSessionConfigurationSupported.
            val sessionConfigurationsByCameraId = slots.associate { slot ->
                val outputConfig = OutputConfiguration(slot.imageReader!!.surface)
                val sessionConfig = SessionConfiguration(
                    SessionConfiguration.SESSION_REGULAR,
                    listOf(outputConfig),
                    bgExecutor,
                    object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(session: CameraCaptureSession) {}
                        override fun onConfigureFailed(session: CameraCaptureSession) {}
                    },
                )
                slot.cameraId to sessionConfig
            }

            val concurrentConfigSupported = try {
                cameraManager.isConcurrentSessionConfigurationSupported(sessionConfigurationsByCameraId)
            } catch (t: Throwable) {
                Log.w(TAG, "isConcurrentSessionConfigurationSupported failed: ${t.javaClass.simpleName}: ${t.message}")
                diagnostics["isConcurrentSessionConfigurationSupportedError"] = "${t.javaClass.simpleName}: ${t.message}"
                false
            }
            events.add("isConcurrentSessionConfigurationSupported:$concurrentConfigSupported")
            if (!concurrentConfigSupported) {
                reasons.add("concurrent_session_configuration_unsupported")
                terminalReached.set(true)
                decisionRef.set("concurrentNotSupported")
            }

            // Native session create — validates cameraSourceNodeId admission ahead of ingest.
            if (!terminalReached.get()) {
                nativeCreateRaw = nativeBridge.createAndroidDagPhase3CameraConcurrentIngestSession(
                    cameraIds.toTypedArray(),
                )
                nativeSessionId = extractSessionId(nativeCreateRaw)
                events.add("nativeCreate:$nativeCreateRaw")
                if (nativeSessionId == null || !nativeCreateRaw.startsWith("status=PASS")) {
                    reasons.add("native_create_failed")
                    if (terminalReached.compareAndSet(false, true)) {
                        decisionRef.set("nativeIngestFailed")
                    }
                }
            }

            // Open both cameras before configuring either session.
            if (!terminalReached.get()) {
                val openLatch = CountDownLatch(slots.size)
                for (slot in slots) {
                    val deviceStateCallback = object : CameraDevice.StateCallback() {
                        override fun onOpened(device: CameraDevice) {
                            events.add("onOpened:${slot.cameraId}")
                            slot.device = device
                            openedCameraCount.incrementAndGet()
                            openLatch.countDown()
                        }

                        override fun onClosed(device: CameraDevice) {
                            events.add("onDeviceClosed:${slot.cameraId}")
                            slot.deviceClosedLatch.countDown()
                        }

                        override fun onDisconnected(device: CameraDevice) {
                            events.add("onDisconnected:${slot.cameraId}")
                            if (terminalReached.compareAndSet(false, true)) {
                                decisionRef.set("openDisconnected")
                                reasons.add("camera_disconnected:${slot.cameraId}")
                            }
                            try {
                                device.close()
                            } catch (t: Throwable) {
                                Log.w(TAG, "device.close() on disconnect failed: ${t.javaClass.simpleName}: ${t.message}")
                            }
                            openLatch.countDown()
                            slot.deviceClosedLatch.countDown()
                        }

                        override fun onError(device: CameraDevice, error: Int) {
                            events.add("onError:${slot.cameraId}:$error")
                            if (terminalReached.compareAndSet(false, true)) {
                                decisionRef.set("openError")
                                reasons.add("camera_open_error:${slot.cameraId}")
                                diagnostics["errorCode:${slot.cameraId}"] = error
                            }
                            try {
                                device.close()
                            } catch (t: Throwable) {
                                Log.w(TAG, "device.close() on error failed: ${t.javaClass.simpleName}: ${t.message}")
                            }
                            openLatch.countDown()
                            slot.deviceClosedLatch.countDown()
                        }
                    }

                    events.add("openCameraRequested:${slot.cameraId}")
                    try {
                        cameraManager.openCamera(slot.cameraId, deviceStateCallback, bgHandler)
                    } catch (e: SecurityException) {
                        reasons.add("camera_permission_absent:${slot.cameraId}")
                        diagnostics["openCameraError:${slot.cameraId}"] = "${e.javaClass.simpleName}: ${e.message}"
                        if (terminalReached.compareAndSet(false, true)) {
                            decisionRef.set("permissionRequired")
                        }
                        openLatch.countDown()
                    } catch (t: Throwable) {
                        Log.w(TAG, "openCamera(${slot.cameraId}) failed: ${t.javaClass.simpleName}: ${t.message}")
                        diagnostics["openCameraError:${slot.cameraId}"] = "${t.javaClass.simpleName}: ${t.message}"
                        reasons.add("camera_open_threw:${slot.cameraId}")
                        if (terminalReached.compareAndSet(false, true)) {
                            decisionRef.set("openError")
                        }
                        openLatch.countDown()
                    }
                }

                val openedInTime = openLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
                if (!openedInTime) {
                    events.add("openTimeout")
                    if (terminalReached.compareAndSet(false, true)) {
                        decisionRef.set("openTimeout")
                        reasons.add("camera_open_timeout")
                    }
                }
            }

            // Configure one session per camera.
            if (!terminalReached.get() && openedCameraCount.get() == slots.size) {
                val configureLatch = CountDownLatch(slots.size)
                for (slot in slots) {
                    val device = slot.device
                    if (device == null) {
                        configureLatch.countDown()
                        continue
                    }
                    try {
                        val requestBuilder = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                        requestBuilder.addTarget(slot.imageReader!!.surface)
                        slot.pendingRequestBuilder = requestBuilder

                        val sessionStateCallback = object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(session: CameraCaptureSession) {
                                events.add("onConfigured:${slot.cameraId}")
                                slot.session = session
                                configuredSessionCount.incrementAndGet()
                                configureLatch.countDown()
                            }

                            override fun onConfigureFailed(session: CameraCaptureSession) {
                                events.add("onConfigureFailed:${slot.cameraId}")
                                if (terminalReached.compareAndSet(false, true)) {
                                    decisionRef.set("sessionConfigurationRejected")
                                    reasons.add("session_configure_failed:${slot.cameraId}")
                                }
                                configureLatch.countDown()
                            }

                            override fun onClosed(session: CameraCaptureSession) {
                                events.add("onSessionClosed:${slot.cameraId}")
                                slot.sessionClosedLatch.countDown()
                            }
                        }

                        val outputConfig = OutputConfiguration(slot.imageReader!!.surface)
                        val sessionConfig = SessionConfiguration(
                            SessionConfiguration.SESSION_REGULAR,
                            listOf(outputConfig),
                            bgExecutor,
                            sessionStateCallback,
                        )
                        events.add("createCaptureSessionRequested:${slot.cameraId}")
                        device.createCaptureSession(sessionConfig)
                    } catch (t: Throwable) {
                        Log.w(TAG, "createCaptureSession(${slot.cameraId}) failed: ${t.javaClass.simpleName}: ${t.message}")
                        diagnostics["createCaptureSessionError:${slot.cameraId}"] = "${t.javaClass.simpleName}: ${t.message}"
                        if (terminalReached.compareAndSet(false, true)) {
                            decisionRef.set("sessionConfigurationRejected")
                            reasons.add("session_configure_threw:${slot.cameraId}")
                        }
                        configureLatch.countDown()
                    }
                }

                val configuredInTime = configureLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
                if (!configuredInTime) {
                    events.add("configureTimeout")
                    if (terminalReached.compareAndSet(false, true)) {
                        decisionRef.set("configureTimeout")
                        reasons.add("session_configure_timeout")
                    }
                }
            }

            // Start repeating preview requests and capture at least one frame per camera.
            if (!terminalReached.get() && configuredSessionCount.get() == slots.size) {
                val frameLatch = CountDownLatch(slots.size)
                for (slot in slots) {
                    val session = slot.session
                    val requestBuilder = slot.pendingRequestBuilder
                    if (session == null || requestBuilder == null) {
                        frameLatch.countDown()
                        continue
                    }

                    slot.imageReader!!.setOnImageAvailableListener({ reader ->
                        val image = try {
                            reader.acquireLatestImage()
                        } catch (t: Throwable) {
                            Log.w(TAG, "acquireLatestImage(${slot.cameraId}) failed: ${t.javaClass.simpleName}: ${t.message}")
                            null
                        } ?: return@setOnImageAvailableListener

                        val hwBuf = image.hardwareBuffer
                        if (hwBuf == null) {
                            reasons.add("hardware_buffer_unavailable:${slot.cameraId}")
                            image.close()
                            return@setOnImageAvailableListener
                        }

                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            val fence = image.fence
                            try {
                                fence.await(Duration.ofMillis(FENCE_AWAIT_MS))
                                syncFenceAwaitedCount.incrementAndGet()
                            } catch (t: Throwable) {
                                Log.w(TAG, "fence.await(${slot.cameraId}) failed: ${t.javaClass.simpleName}: ${t.message}")
                            } finally {
                                fence.close()
                                syncFenceClosedCount.incrementAndGet()
                            }
                        }

                        if (slot.frameReceivedFlag.compareAndSet(false, true)) {
                            // The Image must stay open for the HardwareBuffer to remain
                            // valid; both are closed together after native ingest below.
                            slot.frameTimestampNs = image.timestamp
                            slot.frameWidth = hwBuf.width
                            slot.frameHeight = hwBuf.height
                            slot.lastImage = image
                            slot.lastHardwareBuffer = hwBuf
                            events.add("onImageAvailable:${slot.cameraId}")
                            capturedFrameCount.incrementAndGet()
                            frameLatch.countDown()
                        } else {
                            hwBuf.close()
                            image.close()
                        }
                    }, bgHandler)

                    val captureCallback = object : CameraCaptureSession.CaptureCallback() {
                        override fun onCaptureFailed(
                            session: CameraCaptureSession,
                            request: CaptureRequest,
                            failure: CaptureFailure,
                        ) {
                            events.add("onCaptureFailed:${slot.cameraId}")
                            diagnostics["captureFailureReason:${slot.cameraId}"] = failure.reason
                        }
                    }

                    try {
                        session.setRepeatingRequest(requestBuilder.build(), captureCallback, bgHandler)
                        events.add("repeatingRequestStarted:${slot.cameraId}")
                    } catch (t: Throwable) {
                        Log.w(TAG, "setRepeatingRequest(${slot.cameraId}) failed: ${t.javaClass.simpleName}: ${t.message}")
                        diagnostics["setRepeatingRequestError:${slot.cameraId}"] = "${t.javaClass.simpleName}: ${t.message}"
                        reasons.add("repeating_request_failed:${slot.cameraId}")
                        frameLatch.countDown()
                    }
                }

                val frameInTime = frameLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
                if (!frameInTime) {
                    events.add("frameTimeout")
                    if (terminalReached.compareAndSet(false, true)) {
                        decisionRef.set("frameTimeout")
                        reasons.add("frame_timeout")
                    }
                }
            }

            // Native ingest — one call per camera that captured a frame, made while
            // its owning Image is still open (required for HardwareBuffer validity).
            val ingestSessionId = nativeSessionId
            if (ingestSessionId != null) {
                val expectedIngestCount = capturedFrameCount.get()
                for (slot in slots) {
                    val hwBuf = slot.lastHardwareBuffer
                    if (hwBuf != null) {
                        slot.ingestRaw = try {
                            nativeBridge.ingestAndroidDagPhase3CameraConcurrentFrame(
                                sessionId = ingestSessionId,
                                cameraSourceNodeId = slot.cameraId,
                                hardwareBuffer = hwBuf,
                                width = slot.frameWidth,
                                height = slot.frameHeight,
                                cameraTimestampNs = slot.frameTimestampNs,
                                frameIndex = 0,
                                generationId = 1L,
                                rotationDegrees = 0,
                                mirrorHorizontal = false,
                            )
                        } catch (t: Throwable) {
                            "status=FAIL;reason=ingest_threw:${t.javaClass.simpleName}"
                        }
                        events.add("nativeIngest:${slot.cameraId}:${slot.ingestRaw}")
                        if (slot.ingestRaw.startsWith("status=PASS")) {
                            nativeIngestPassCount.incrementAndGet()
                        } else {
                            reasons.add("native_ingest_failed:${slot.cameraId}")
                        }
                    }
                    try {
                        hwBuf?.close()
                    } catch (t: Throwable) {
                        Log.w(TAG, "hwBuf.close() failed: ${t.javaClass.simpleName}: ${t.message}")
                    }
                    try {
                        slot.lastImage?.close()
                    } catch (t: Throwable) {
                        Log.w(TAG, "image.close() failed: ${t.javaClass.simpleName}: ${t.message}")
                    }
                    slot.lastHardwareBuffer = null
                    slot.lastImage = null
                }
                if (nativeIngestPassCount.get() < expectedIngestCount &&
                    terminalReached.compareAndSet(false, true)
                ) {
                    decisionRef.set("nativeIngestFailed")
                }
            }

            // Native session destroy.
            val destroySessionId = nativeSessionId
            if (destroySessionId != null) {
                nativeDestroyRaw = nativeBridge.destroyAndroidDagPhase3CameraConcurrentIngestSession(destroySessionId)
                events.add("nativeDestroy:$nativeDestroyRaw")
                nativeDestroyed = true
                if (!nativeDestroyRaw.startsWith("status=PASS") &&
                    terminalReached.compareAndSet(false, true)
                ) {
                    decisionRef.set("destroyFailed")
                    reasons.add("native_destroy_failed")
                }
            }

            if (terminalReached.compareAndSet(false, true)) {
                decisionRef.set("ingested")
            }
        } finally {
            // Safety net: close any HardwareBuffer/Image left open by an exception
            // that interrupted the main flow before the ingest step closed them.
            for (slot in slots) {
                try {
                    slot.lastHardwareBuffer?.close()
                } catch (t: Throwable) {
                    Log.w(TAG, "hwBuf.close() cleanup failed: ${t.javaClass.simpleName}: ${t.message}")
                }
                try {
                    slot.lastImage?.close()
                } catch (t: Throwable) {
                    Log.w(TAG, "image.close() cleanup failed: ${t.javaClass.simpleName}: ${t.message}")
                }
                slot.lastHardwareBuffer = null
                slot.lastImage = null
            }

            // Safety net: destroy the native session if the main flow didn't reach it.
            val cleanupSessionId = nativeSessionId
            if (cleanupSessionId != null && !nativeDestroyed) {
                nativeDestroyRaw = nativeBridge.destroyAndroidDagPhase3CameraConcurrentIngestSession(cleanupSessionId)
                events.add("nativeDestroy:$nativeDestroyRaw")
            }

            // Deterministic teardown: stopRepeating -> abortCaptures -> close
            // sessions -> close devices -> close ImageReaders -> quit handler thread.
            for (slot in slots) {
                val session = slot.session
                if (session != null) {
                    try {
                        session.stopRepeating()
                    } catch (t: Throwable) {
                        Log.w(TAG, "stopRepeating(${slot.cameraId}) failed: ${t.javaClass.simpleName}: ${t.message}")
                    }
                    try {
                        session.abortCaptures()
                    } catch (t: Throwable) {
                        Log.w(TAG, "abortCaptures(${slot.cameraId}) failed: ${t.javaClass.simpleName}: ${t.message}")
                    }
                }
            }
            for (slot in slots) {
                val session = slot.session
                if (session != null) {
                    try {
                        session.close()
                    } catch (t: Throwable) {
                        Log.w(TAG, "session.close(${slot.cameraId}) failed: ${t.javaClass.simpleName}: ${t.message}")
                    }
                    try {
                        slot.sessionClosedLatch.await(CLOSE_WAIT_MS, TimeUnit.MILLISECONDS)
                    } catch (t: InterruptedException) {
                        Thread.currentThread().interrupt()
                    }
                }
            }
            for (slot in slots) {
                val device = slot.device
                if (device != null) {
                    try {
                        device.close()
                    } catch (t: Throwable) {
                        Log.w(TAG, "device.close(${slot.cameraId}) failed: ${t.javaClass.simpleName}: ${t.message}")
                    }
                    try {
                        slot.deviceClosedLatch.await(CLOSE_WAIT_MS, TimeUnit.MILLISECONDS)
                    } catch (t: InterruptedException) {
                        Thread.currentThread().interrupt()
                    }
                }
            }
            for (slot in slots) {
                val reader = slot.imageReader
                if (reader != null) {
                    try {
                        reader.setOnImageAvailableListener(null, null)
                    } catch (t: Throwable) {
                        Log.w(TAG, "imageReader listener unregister(${slot.cameraId}) failed: ${t.javaClass.simpleName}: ${t.message}")
                    }
                    try {
                        reader.close()
                    } catch (t: Throwable) {
                        Log.w(TAG, "imageReader.close(${slot.cameraId}) failed: ${t.javaClass.simpleName}: ${t.message}")
                    }
                }
            }

            handlerThread.quitSafely()
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

    private fun selectConcurrentCameraPair(
        cameraManager: CameraManager,
        candidateSet: Set<String>,
        diagnostics: MutableMap<String, Any?>,
    ): List<String> {
        val sortedIds = candidateSet.toList().sorted()
        val facingById = mutableMapOf<String, Int>()
        for (id in sortedIds) {
            try {
                val facing = cameraManager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
                if (facing != null) facingById[id] = facing
            } catch (t: Throwable) {
                diagnostics["lensFacingError:$id"] = "${t.javaClass.simpleName}: ${t.message}"
            }
        }
        val frontId = sortedIds.firstOrNull { facingById[it] == CameraCharacteristics.LENS_FACING_FRONT }
        val backId = sortedIds.firstOrNull { facingById[it] == CameraCharacteristics.LENS_FACING_BACK }
        if (frontId != null && backId != null && frontId != backId) {
            return listOf(frontId, backId).sorted()
        }
        return sortedIds.take(2)
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
