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
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.view.TextureRegistry
import java.time.Duration
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * P3-MULTICAM-NODE-SINGLE-CAM-INGEST-DESCRIPTOR-SPATIAL-RENDER: bounded
 * diagnostic proof harness combining the Camera2 single-frame ImageReader
 * lifecycle pattern of [AndroidCamera2HardwareBufferFrameSmokeHarness] with
 * the native dynamic-descriptor GLES/OES spatial render route (see
 * android_phase3_multicam_single_cam_ingest_spatial_render_jni.cpp).
 *
 * Opens exactly one Camera2 device, configures a single
 * `ImageFormat.YUV_420_888` [ImageReader] with the API 29+ 5-arg overload and
 * [HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE], receives one image, obtains its
 * non-null [HardwareBuffer], and -- while still holding that HardwareBuffer
 * open -- calls the native route with it (always the OES primary) plus a
 * synthetic solid-blue RGBA_8888 HardwareBuffer (always the 2D secondary),
 * laid out by the caller-supplied Dart descriptor via the existing
 * `ComputeMultiCamLayout()` and rendered by the existing GLES spatial
 * compositor. Close ordering is strict: acquire image -> obtain
 * HardwareBuffer -> await SyncFence (API 33+) -> call native -> close
 * HardwareBuffer -> close Image (`finally`); the HardwareBuffer/Image are
 * never closed before the native call returns.
 *
 * Kotlin is dumb transport for the descriptor: [parseDescriptor] validates
 * only map shape/type and fails closed before any camera or native work for
 * a shape-malformed map. It performs no enum-*value* validation -- an
 * unrecognized-but-well-typed enum string (e.g. `layoutMode: "invalidMode"`)
 * is passed through untouched, and native (the sole layout authority)
 * rejects it with its own explicit `descriptorParse`/`lastError` reason
 * after a full camera open/capture, so the malformed-descriptor lane still
 * exercises setup/permission/open/session/frame explicitly before failing
 * closed at the render stage.
 *
 * Requires API 29+. Never opens a second/concurrent camera, never touches
 * Vulkan, never records or exports. Diagnostic/capability proof only.
 */
class AndroidCamera2SingleCamIngestSpatialSmokeHarness(private val context: Context) {

    companion object {
        private const val TAG = "AndroidCamera2SingleCamIngestSpatialSmokeHarness"
        private const val DEFAULT_TIMEOUT_MS = 10000L
        private const val MIN_TIMEOUT_MS = 3000L
        private const val MAX_TIMEOUT_MS = 30000L
        private const val DEFAULT_MAX_WIDTH = 640
        private const val DEFAULT_MAX_HEIGHT = 480
        private const val MIN_DIMENSION = 160
        private const val MAX_DIMENSION = 1920
        private const val CLOSE_WAIT_MS = 2000L
        private const val IMAGE_READER_MAX_IMAGES = 2
        private const val FENCE_AWAIT_MS = 1000L

        const val PROOF_BOUNDARY =
            "single_camera_ingest_buffer_queue_dynamic_descriptor_spatial_gles_oes_render_readback_only_no_concurrent_camera_no_vulkan_no_recording_no_export_no_product"

        fun exceptionResult(t: Throwable): Map<String, Any?> {
            val reason = "exception:${t.javaClass.simpleName.ifEmpty { "unknown_exception" }}"
            return mapOf(
                "success" to false,
                "started" to true,
                "decision" to "nativeRenderFailed",
                "reasons" to listOf(reason),
                "events" to emptyList<String>(),
                "diagnostics" to emptyMap<String, Any?>(),
                "proofBoundary" to PROOF_BOUNDARY,
                "raw" to "status=FAIL;lastError=$reason",
                "metrics" to emptyMap<String, String>(),
                "lastError" to reason,
                "durationMs" to 0,
            )
        }
    }

    // Instance-scoped so an external cancel() (from the coordinator's dispose
    // path) can force a prompt, best-effort terminal transition regardless of
    // which internal thread run() is on.
    private val terminalReached = AtomicBoolean(false)
    private val decisionRef = AtomicReference("openError")
    private val reasons = Collections.synchronizedList(mutableListOf<String>())
    private val openLatch = CountDownLatch(1)
    private val configureLatch = CountDownLatch(1)
    private val frameLatch = CountDownLatch(1)

    /**
     * Best-effort external cancellation. Safe to call before, during, or
     * after [run]. Forces any in-progress lifecycle waits to unblock so
     * cleanup can proceed promptly.
     */
    fun cancel() {
        if (terminalReached.compareAndSet(false, true)) {
            decisionRef.set("disposed")
            reasons.add("disposed_during_run")
        }
        openLatch.countDown()
        configureLatch.countDown()
        frameLatch.countDown()
    }

    fun run(surfaceProducer: TextureRegistry.SurfaceProducer, args: Map<*, *>?): Map<String, Any?> {
        val startElapsed = SystemClock.elapsedRealtime()
        val apiLevel = Build.VERSION.SDK_INT
        val hasCameraPermission = hasCameraPermission()
        val requestedCameraId = (args?.get("cameraId") as? String)?.trim()
        val timeoutMs = clampLong((args?.get("timeoutMs") as? Number)?.toLong(), DEFAULT_TIMEOUT_MS, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
        val maxWidth = clampInt((args?.get("maxWidth") as? Number)?.toInt(), DEFAULT_MAX_WIDTH, MIN_DIMENSION, MAX_DIMENSION)
        val maxHeight = clampInt((args?.get("maxHeight") as? Number)?.toInt(), DEFAULT_MAX_HEIGHT, MIN_DIMENSION, MAX_DIMENSION)
        val descriptorRaw = args?.get("descriptor") as? Map<*, *>

        val textureId = surfaceProducer.id()
        val events = Collections.synchronizedList(mutableListOf<String>())
        val diagnosticsMap = Collections.synchronizedMap(mutableMapOf<String, Any?>())

        var attemptedOpen = false
        var selectedCameraId: String? = null
        var selectedLensFacing = "unknown"
        var selectedWidth = 0
        var selectedHeight = 0
        val nativeRawRef = AtomicReference("")
        val nativeMetricsRef = AtomicReference<Map<String, String>>(emptyMap())

        fun buildResult(
            decision: String,
            opened: Boolean = false,
            sessionConfigured: Boolean = false,
            repeatingStarted: Boolean = false,
            frameReceived: Boolean = false,
            hardwareBufferAvailable: Boolean = false,
            hardwareBufferClosed: Boolean = false,
            imageClosed: Boolean = false,
            syncFenceAwaited: Boolean = false,
            syncFenceClosed: Boolean = false,
            nativeInvoked: Boolean = false,
            syntheticBufferAllocated: Boolean = false,
            syntheticBufferClosed: Boolean = false,
            sessionClosed: Boolean = false,
            deviceClosed: Boolean = false,
            imageReaderClosed: Boolean = false,
        ): Map<String, Any?> {
            val durationMs = SystemClock.elapsedRealtime() - startElapsed
            val nativeRaw = nativeRawRef.get()
            val nativeMetrics = nativeMetricsRef.get()
            val nativePass = nativeRaw.startsWith("status=PASS;")
            val success = decision == "singleCamIngestSpatialRenderPassed" &&
                frameReceived && hardwareBufferAvailable && hardwareBufferClosed &&
                imageClosed && nativeInvoked && nativePass &&
                sessionClosed && deviceClosed && imageReaderClosed &&
                syntheticBufferClosed
            Log.i(
                TAG,
                "decision=$decision success=$success attemptedOpen=$attemptedOpen opened=$opened " +
                    "frameReceived=$frameReceived nativeInvoked=$nativeInvoked cameraId=$selectedCameraId " +
                    "durationMs=$durationMs",
            )
            return mapOf(
                "success" to success,
                "started" to true,
                "textureId" to textureId,
                "apiLevel" to apiLevel,
                "hasCameraPermission" to hasCameraPermission,
                "attemptedOpen" to attemptedOpen,
                "opened" to opened,
                "sessionConfigured" to sessionConfigured,
                "repeatingStarted" to repeatingStarted,
                "frameReceived" to frameReceived,
                "cameraId" to selectedCameraId,
                "selectedLensFacing" to selectedLensFacing,
                "selectedWidth" to selectedWidth,
                "selectedHeight" to selectedHeight,
                "imageFormatName" to "YUV_420_888",
                "hardwareBufferAvailable" to hardwareBufferAvailable,
                "hardwareBufferClosed" to hardwareBufferClosed,
                "imageClosed" to imageClosed,
                "syncFenceAwaited" to syncFenceAwaited,
                "syncFenceClosed" to syncFenceClosed,
                "syntheticBufferAllocated" to syntheticBufferAllocated,
                "syntheticBufferClosed" to syntheticBufferClosed,
                "nativeInvoked" to nativeInvoked,
                "sessionClosed" to sessionClosed,
                "deviceClosed" to deviceClosed,
                "imageReaderClosed" to imageReaderClosed,
                "proofBoundary" to PROOF_BOUNDARY,
                "raw" to nativeRaw,
                "metrics" to nativeMetrics,
                "lastError" to (nativeMetrics["lastError"] ?: ""),
                "decision" to decision,
                "reasons" to reasons.toList(),
                "events" to events.toList(),
                "diagnostics" to diagnosticsMap.toMap(),
                "durationMs" to durationMs,
            )
        }

        // Guard 0: API level below 29 (required for the 5-arg YUV_420_888/HardwareBuffer path).
        if (apiLevel < Build.VERSION_CODES.Q) {
            reasons.add("api_below_29")
            return buildResult("apiUnsupported")
        }

        // Guard 0a: external cancellation raced ahead of run() even starting.
        if (terminalReached.get()) {
            return buildResult(decisionRef.get())
        }

        // Guard 0b: descriptor shape/type guard -- Kotlin is dumb transport
        // only; it never validates enum *values* (native is the sole layout
        // authority for that). Fails closed before any camera or native work.
        val parsedDescriptor = parseDescriptor(descriptorRaw)
        if (parsedDescriptor == null) {
            reasons.add("malformed_descriptor_shape")
            return buildResult("malformedDescriptorShape")
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
            return buildResult("cameraPermissionDenied")
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
        val yuvSizes = try {
            streamConfigurationMap?.getOutputSizes(ImageFormat.YUV_420_888)?.toList() ?: emptyList()
        } catch (t: Throwable) {
            Log.w(TAG, "getOutputSizes(YUV_420_888, $cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
            diagnosticsMap["outputSizesError"] = "${t.javaClass.simpleName}: ${t.message}"
            emptyList()
        }
        val positiveYuvSizes = yuvSizes.filter { it.width > 0 && it.height > 0 }
        if (positiveYuvSizes.isEmpty()) {
            reasons.add("no_supported_yuv_size")
            return buildResult("no_supported_yuv_size")
        }

        val selectedSize = selectYuvSize(positiveYuvSizes, maxWidth, maxHeight)
        selectedWidth = selectedSize.width
        selectedHeight = selectedSize.height

        // All guards passed -- allocate resources.
        val flutterSurface = try {
            surfaceProducer.setSize(selectedWidth, selectedHeight)
            surfaceProducer.getSurface()
        } catch (t: Throwable) {
            Log.w(TAG, "surfaceProducer setSize/getSurface failed: ${t.javaClass.simpleName}: ${t.message}")
            diagnosticsMap["surfaceProducerError"] = "${t.javaClass.simpleName}: ${t.message}"
            null
        }
        if (flutterSurface == null) {
            reasons.add("surface_producer_surface_unavailable")
            return buildResult("surfaceUnavailable")
        }

        // A stable `val` (never a `var`) so the non-null smart cast below
        // survives capture by the ImageReader listener lambda further down --
        // Kotlin cannot smart-cast a captured `var` even when it is never
        // reassigned after capture.
        val syntheticRgbaBuffer: HardwareBuffer? = try {
            HardwareBuffer.create(
                selectedWidth,
                selectedHeight,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "synthetic RGBA HardwareBuffer.create failed: ${t.javaClass.simpleName}: ${t.message}")
            diagnosticsMap["syntheticBufferAllocationError"] = "${t.javaClass.simpleName}: ${t.message}"
            null
        }
        if (syntheticRgbaBuffer == null) {
            reasons.add("synthetic_buffer_allocation_failed")
            return buildResult("syntheticBufferAllocationFailed", syntheticBufferAllocated = false)
        }

        val handlerThread = HandlerThread("VGCamera2SingleCamIngestSpatialSmoke")
        val imageReader: ImageReader
        try {
            handlerThread.start()
            imageReader = ImageReader.newInstance(
                selectedWidth, selectedHeight, ImageFormat.YUV_420_888, IMAGE_READER_MAX_IMAGES,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "ImageReader.newInstance failed: ${t.javaClass.simpleName}: ${t.message}")
            diagnosticsMap["imageReaderAllocationError"] = "${t.javaClass.simpleName}: ${t.message}"
            handlerThread.quitSafely()
            var syntheticBufferClosedOnAllocationFailure = false
            try {
                syntheticRgbaBuffer.close()
                syntheticBufferClosedOnAllocationFailure = true
            } catch (closeT: Throwable) {
                Log.w(TAG, "synthetic RGBA HardwareBuffer.close() after ImageReader allocation failure failed: ${closeT.javaClass.simpleName}: ${closeT.message}")
            }
            reasons.add("image_reader_allocation_failed")
            return buildResult(
                "imageReaderAllocationFailed",
                syntheticBufferAllocated = true,
                syntheticBufferClosed = syntheticBufferClosedOnAllocationFailure,
            )
        }
        val bgHandler = Handler(handlerThread.looper)

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
        val syncFenceAwaitedFlag = AtomicBoolean(false)
        val syncFenceClosedFlag = AtomicBoolean(false)
        val nativeInvokedFlag = AtomicBoolean(false)
        val sessionClosedFlag = AtomicBoolean(false)
        val deviceClosedFlag = AtomicBoolean(false)
        val imageReaderClosedFlag = AtomicBoolean(false)
        val ignoredCaptureFailuresAfterTerminal = AtomicInteger(0)

        val nativeBridge = VanguardNativeBridge(
            VanguardLifecycleObserver(VanguardDiagnostics()),
            VanguardDiagnostics(),
            null,
        )

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
                            decisionRef.set("cameraIngestUnsupported")
                            reasons.add("yuv_ahb_import_unsupported_format")
                        } else {
                            ignoredCaptureFailuresAfterTerminal.incrementAndGet()
                        }
                    } else {
                        try {
                            if (terminalReached.get()) {
                                return@setOnImageAvailableListener
                            }
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
                                hardwareBufferAvailableFlag.set(true)
                                events.add("onImageAvailable")

                                // Native/render/import/release call happens
                                // while the HardwareBuffer is still open --
                                // it is closed only in the finally below,
                                // never before native returns.
                                nativeInvokedFlag.set(true)
                                val raw = try {
                                    nativeBridge.runAndroidDagPhase3SingleCamIngestSpatialRenderSmoke(
                                        flutterSurface,
                                        hwBuf,
                                        syntheticRgbaBuffer,
                                        selectedWidth,
                                        selectedHeight,
                                        parsedDescriptor.layoutMode,
                                        parsedDescriptor.pipAnchor,
                                        parsedDescriptor.pipCenterX,
                                        parsedDescriptor.pipCenterY,
                                        parsedDescriptor.pipWidthFraction,
                                        parsedDescriptor.pipAspectRatio,
                                        parsedDescriptor.pipMarginFraction,
                                        parsedDescriptor.splitDirection,
                                        parsedDescriptor.splitRatio,
                                    )
                                } catch (t: Throwable) {
                                    Log.w(TAG, "runAndroidDagPhase3SingleCamIngestSpatialRenderSmoke failed: ${t.javaClass.simpleName}: ${t.message}")
                                    "status=EXCEPTION;lastError=exception:${t.javaClass.simpleName.ifEmpty { "unknown_exception" }}"
                                }
                                nativeRawRef.set(raw)
                                val nativeMetrics = parseNativeResult(raw)
                                nativeMetricsRef.set(nativeMetrics)
                                events.add("nativeRenderAttempted")

                                if (terminalReached.compareAndSet(false, true)) {
                                    val descriptorParseOk = nativeMetrics["descriptorParse"] == "success"
                                    val cameraIngestOk = nativeMetrics["cameraDescribe"] == "success" &&
                                        nativeMetrics["importCamera"] == "success" &&
                                        nativeMetrics["primaryTargetOk"] == "true"
                                    when {
                                        raw.startsWith("status=PASS;") -> {
                                            decisionRef.set("singleCamIngestSpatialRenderPassed")
                                        }
                                        !descriptorParseOk -> {
                                            decisionRef.set("descriptorRejected")
                                            reasons.add("descriptor_rejected:${nativeMetrics["descriptorParseLastError"] ?: "unknown"}")
                                        }
                                        !cameraIngestOk -> {
                                            decisionRef.set("cameraIngestUnsupported")
                                            reasons.add("yuv_ahb_import_unsupported_format")
                                        }
                                        else -> {
                                            decisionRef.set("nativeRenderFailed")
                                            reasons.add("native_render_failed")
                                            diagnosticsMap["nativeRenderResult"] = raw.take(400)
                                        }
                                    }
                                }
                                frameLatch.countDown()
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
                        diagnosticsMap["captureFailureReason"] = failure.reason
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
                decisionRef.set("cameraPermissionDenied")
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
                        decisionRef.set("camera_open_timeout")
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
                                                decisionRef.set("no_frame_within_timeout")
                                                reasons.add("no_frame_within_timeout")
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
        } finally {
            // Cleanup ordering: stop/abort repeating, close session (wait briefly),
            // close device (wait briefly), unregister ImageReader listener, close
            // ImageReader, close the synthetic buffer, quit HandlerThread. Never
            // releases surfaceProducer -- that is the coordinator's job.
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
                diagnosticsMap["ignoredCaptureFailuresAfterTerminal"] = ignoredCaptureFailuresAfterTerminal.get()
            }

            handlerThread.quitSafely()
        }

        var syntheticBufferClosed = false
        try {
            syntheticRgbaBuffer.close()
            syntheticBufferClosed = true
        } catch (t: Throwable) {
            Log.w(TAG, "synthetic RGBA HardwareBuffer.close() failed: ${t.javaClass.simpleName}: ${t.message}")
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
            syncFenceAwaited = syncFenceAwaitedFlag.get(),
            syncFenceClosed = syncFenceClosedFlag.get(),
            nativeInvoked = nativeInvokedFlag.get(),
            syntheticBufferAllocated = true,
            syntheticBufferClosed = syntheticBufferClosed,
            sessionClosed = sessionClosedFlag.get(),
            deviceClosed = deviceClosedFlag.get(),
            imageReaderClosed = imageReaderClosedFlag.get(),
        )
    }

    private data class ParsedDescriptor(
        val layoutMode: String,
        val pipAnchor: String,
        val pipCenterX: Double,
        val pipCenterY: Double,
        val pipWidthFraction: Double,
        val pipAspectRatio: Double,
        val pipMarginFraction: Double,
        val splitDirection: String,
        val splitRatio: Double,
    )

    // Shape/type parsing only -- no enum-value validation, no clamping, no
    // rect derivation (native owns all of that). Every field must be
    // present and of the exact expected type; anything else returns null so
    // the caller fails closed before any camera/native work.
    private fun parseDescriptor(descriptor: Map<*, *>?): ParsedDescriptor? {
        if (descriptor == null) return null
        val layoutMode = descriptor["layoutMode"] as? String ?: return null
        val pipAnchor = descriptor["pipAnchor"] as? String ?: return null
        val splitDirection = descriptor["splitDirection"] as? String ?: return null
        val pipCenterX = (descriptor["pipCenterX"] as? Number)?.toDouble() ?: return null
        val pipCenterY = (descriptor["pipCenterY"] as? Number)?.toDouble() ?: return null
        val pipWidthFraction = (descriptor["pipWidthFraction"] as? Number)?.toDouble() ?: return null
        val pipAspectRatio = (descriptor["pipAspectRatio"] as? Number)?.toDouble() ?: return null
        val pipMarginFraction = (descriptor["pipMarginFraction"] as? Number)?.toDouble() ?: return null
        val splitRatio = (descriptor["splitRatio"] as? Number)?.toDouble() ?: return null
        return ParsedDescriptor(
            layoutMode = layoutMode,
            pipAnchor = pipAnchor,
            pipCenterX = pipCenterX,
            pipCenterY = pipCenterY,
            pipWidthFraction = pipWidthFraction,
            pipAspectRatio = pipAspectRatio,
            pipMarginFraction = pipMarginFraction,
            splitDirection = splitDirection,
            splitRatio = splitRatio,
        )
    }

    private fun parseNativeResult(raw: String): Map<String, String> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        return parsed
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
