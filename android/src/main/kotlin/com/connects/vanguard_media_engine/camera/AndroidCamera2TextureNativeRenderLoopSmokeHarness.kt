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
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Phase 3-Unit M: diagnostic-only Android Camera2 PRIVATE ImageReader
 * HardwareBuffer Flutter-texture native-render loop smoke harness.
 *
 * Extends the Unit L offscreen-surface native-render multi-frame loop into a
 * Flutter-visible proof: it creates the existing Phase 4B1 native texture
 * playback session against a real `TextureRegistry.SurfaceProducer` surface,
 * bumps its generation once, and renders exactly [targetFrameCount]
 * camera-produced HardwareBuffers through it via [VanguardNativeBridge].
 * Requires API 29+. Never adds a preview UI, MediaRecorder, CameraX session,
 * dual/concurrent open, or new C++/JNI entry points. Diagnostic/capability
 * foundation only.
 *
 * Open/configure/render/teardown stay in this one class on purpose: they
 * share `terminalReached`, the three latches, and the single cleanup
 * `finally` block, and splitting them into micro-files would fragment that
 * atomic terminal-state/cleanup ownership.
 */
class AndroidCamera2TextureNativeRenderLoopSmokeHarness(private val context: Context) {

    companion object {
        private const val TAG = "AndroidCamera2TextureNativeRenderLoopSmokeHarness"
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

    // Instance-scoped so an external cancel() (from the coordinator's dispose
    // path, on the Flutter platform thread) can force a prompt, best-effort
    // terminal transition regardless of which internal thread run() is on.
    private val terminalReached = AtomicBoolean(false)
    private val decisionRef = AtomicReference("openError")
    private val reasons = Collections.synchronizedList(mutableListOf<String>())
    private val openLatch = CountDownLatch(1)
    private val configureLatch = CountDownLatch(1)
    private val frameLatch = CountDownLatch(1)

    /**
     * Best-effort external cancellation. Safe to call before, during, or
     * after [run]. Forces any in-progress lifecycle waits to unblock so
     * cleanup can proceed promptly; the eventual [run] result reports
     * decision=disposed when this wins the terminal race.
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
        val targetFrameCount = clampInt((args?.get("frameCount") as? Number)?.toInt(), DEFAULT_FRAME_COUNT, MIN_FRAME_COUNT, MAX_FRAME_COUNT)

        val textureId = surfaceProducer.id()
        val events = Collections.synchronizedList(mutableListOf<String>())
        val diagnosticsMap = Collections.synchronizedMap(mutableMapOf<String, Any?>())
        val nativeRenderRawFrames = Collections.synchronizedList(mutableListOf<String>())

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
            nativeGenerationId: Long = 0L,
            nativeSessionDestroyed: Boolean = false,
        ): Map<String, Any?> {
            val durationMs = SystemClock.elapsedRealtime() - startElapsed
            val allRawPassed = nativeRenderRawFrames.isNotEmpty() &&
                nativeRenderRawFrames.all { it.startsWith("status=PASS;") }
            val fenceOk = if (apiLevel >= Build.VERSION_CODES.TIRAMISU) {
                syncFenceAwaitedCount == renderedFrames && syncFenceClosedCount == renderedFrames
            } else {
                true
            }
            val success = apiLevel >= Build.VERSION_CODES.Q &&
                hasCameraPermission &&
                opened && sessionConfigured && repeatingStarted &&
                decision == "textureNativeRenderLoopPassed" &&
                renderedFrames == targetFrameCount && allRawPassed &&
                hardwareBufferClosedCount == renderedFrames &&
                imageClosedCount == renderedFrames &&
                fenceOk &&
                monotonicFrameTimestamps &&
                nativeSessionCreated && nativeSessionDestroyed &&
                sessionClosed && deviceClosed && imageReaderClosed &&
                reasons.isEmpty()
            Log.i(
                TAG,
                "decision=$decision success=$success attemptedOpen=$attemptedOpen opened=$opened " +
                    "renderedFrames=$renderedFrames targetFrameCount=$targetFrameCount " +
                    "cameraId=$selectedCameraId textureId=$textureId durationMs=$durationMs",
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
                "nativeSessionCreated" to nativeSessionCreated,
                "nativeGenerationId" to nativeGenerationId,
                "nativeSessionDestroyed" to nativeSessionDestroyed,
                "sessionClosed" to sessionClosed,
                "deviceClosed" to deviceClosed,
                "imageReaderClosed" to imageReaderClosed,
                "surfaceProducerReleased" to false,
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

        // Guard: external cancellation raced ahead of run() even starting.
        if (terminalReached.get()) {
            return buildResult(decisionRef.get())
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
        val handlerThread = HandlerThread("VGCamera2TextureNativeRenderLoopSmoke")
        handlerThread.start()
        val bgHandler = Handler(handlerThread.looper)
        val imageReader = ImageReader.newInstance(
            selectedWidth, selectedHeight, ImageFormat.PRIVATE, IMAGE_READER_MAX_IMAGES,
            HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
        )

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
        val ignoredCaptureFailuresAfterTerminal = AtomicInteger(0)
        val ignoredFramesAfterTerminal = AtomicInteger(0)

        var nativeSessionCreated = false
        var nativeGenerationId = 0L
        var nativeSessionDestroyed = false
        var nativeBridge: VanguardNativeBridge? = null
        var sessionId: String? = null

        try {
            // ── Set up the Flutter-visible surface before allocating the native session ──
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
                decisionRef.set("nativeSessionFailed")
            } else {
                // ── Create the Phase 4B1 native texture playback session against the Flutter surface ──
                val diagnostics = VanguardDiagnostics()
                val bridge = VanguardNativeBridge(
                    VanguardLifecycleObserver(diagnostics),
                    diagnostics,
                    null,
                )
                nativeBridge = bridge
                val createResult = try {
                    bridge.createAndroidDagPhase4B1TexturePlaybackSession(
                        flutterSurface, selectedWidth, selectedHeight,
                    )
                } catch (t: Throwable) {
                    Log.w(TAG, "createAndroidDagPhase4B1TexturePlaybackSession failed: ${t.javaClass.simpleName}: ${t.message}")
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

                        // Bump the generation exactly once — every rendered frame uses this id.
                        val bumpResult = try {
                            bridge.bumpAndroidDagPhase4B1TexturePlaybackGeneration(parsedSessionId)
                        } catch (t: Throwable) {
                            Log.w(TAG, "bumpAndroidDagPhase4B1TexturePlaybackGeneration failed: ${t.javaClass.simpleName}: ${t.message}")
                            diagnosticsMap["nativeGenerationBumpError"] = "${t.javaClass.simpleName}: ${t.message}"
                            ""
                        }
                        val parsedGenerationId = if (bumpResult.startsWith("status=OK;")) {
                            bumpResult.substringAfter("generationId=").substringBefore(";").toLongOrNull()
                        } else {
                            null
                        }
                        if (parsedGenerationId == null || parsedGenerationId <= 0L) {
                            reasons.add("native_generation_bump_failed")
                            diagnosticsMap["nativeGenerationBumpResult"] = bumpResult.take(200)
                            decisionRef.set("nativeSessionFailed")
                        } else {
                            nativeGenerationId = parsedGenerationId
                            val activeBridge = bridge
                            val activeSessionId = parsedSessionId
                            val activeGenerationId = parsedGenerationId

                            // Only now do we actually attempt to open the camera.
                            attemptedOpen = true

                            imageReader.setOnImageAvailableListener({ reader ->
                                val image = try {
                                    reader.acquireLatestImage()
                                } catch (t: Throwable) {
                                    Log.w(TAG, "acquireLatestImage failed: ${t.javaClass.simpleName}: ${t.message}")
                                    null
                                } ?: return@setOnImageAvailableListener
                                // Only frames actually attempted against the native render path count
                                // toward hardwareBufferClosedCount/imageClosedCount, which must equal
                                // renderedFrames on success; post-terminal frames close their resources
                                // too but are tallied solely via ignoredFramesAfterTerminal diagnostics.
                                var countedFrame = true
                                try {
                                    if (terminalReached.get()) {
                                        countedFrame = false
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
                                                activeBridge.renderAndroidDagPhase4B1TexturePlaybackFrameForGeneration(
                                                    activeSessionId,
                                                    hwBuf,
                                                    selectedWidth,
                                                    selectedHeight,
                                                    image.timestamp / 1000,
                                                    frameIndex,
                                                    activeGenerationId,
                                                    0,
                                                )
                                            } catch (t: Throwable) {
                                                Log.w(TAG, "renderAndroidDagPhase4B1TexturePlaybackFrameForGeneration failed: ${t.javaClass.simpleName}: ${t.message}")
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
                                                        decisionRef.set("textureNativeRenderLoopPassed")
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
                                    if (countedFrame) {
                                        imageClosedCount.incrementAndGet()
                                    }
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
                                    if (terminalReached.get()) {
                                        events.add("onOpenedAfterTerminal")
                                        openedFlag.set(true)
                                        deviceRef.set(device)
                                        try {
                                            device.close()
                                        } catch (t: Throwable) {
                                            Log.w(TAG, "device.close() on late open failed: ${t.javaClass.simpleName}: ${t.message}")
                                        }
                                        openLatch.countDown()
                                        configureLatch.countDown()
                                        frameLatch.countDown()
                                        return
                                    }
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
                                                    if (terminalReached.get()) {
                                                        events.add("onConfiguredAfterTerminal")
                                                        sessionRef.set(session)
                                                        sessionConfiguredFlag.set(true)
                                                        try {
                                                            session.close()
                                                        } catch (t: Throwable) {
                                                            Log.w(TAG, "session.close() on late configure failed: ${t.javaClass.simpleName}: ${t.message}")
                                                        }
                                                        configureLatch.countDown()
                                                        frameLatch.countDown()
                                                        return
                                                    }
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
                }
            }
        } finally {
            // Cleanup ordering: stop/abort repeating, close session (wait briefly),
            // close device (wait briefly), unregister ImageReader listener, close
            // ImageReader, destroy native session (if created), quit HandlerThread.
            // Never releases surfaceProducer — that is the coordinator's job.
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
                        val destroyResult = bridge.destroyAndroidDagPhase4B1TexturePlaybackSession(sid)
                        if (destroyResult.startsWith("status=OK;")) {
                            nativeSessionDestroyed = true
                        } else {
                            diagnosticsMap["nativeSessionDestroyResult"] = destroyResult.take(200)
                            reasons.add("native_session_destroy_failed")
                        }
                    } catch (t: Throwable) {
                        Log.w(TAG, "destroyAndroidDagPhase4B1TexturePlaybackSession failed: ${t.javaClass.simpleName}: ${t.message}")
                        diagnosticsMap["nativeSessionDestroyError"] = "${t.javaClass.simpleName}: ${t.message}"
                        reasons.add("native_session_destroy_failed")
                    }
                } else {
                    diagnosticsMap["nativeSessionDestroySkippedReason"] = "bridgeOrSessionIdMissing"
                    reasons.add("native_session_destroy_not_invoked")
                }
            }

            if (ignoredCaptureFailuresAfterTerminal.get() > 0) {
                diagnosticsMap["ignoredCaptureFailuresAfterTerminal"] = ignoredCaptureFailuresAfterTerminal.get()
            }
            if (ignoredFramesAfterTerminal.get() > 0) {
                diagnosticsMap["ignoredFramesAfterTerminal"] = ignoredFramesAfterTerminal.get()
            }

            if (decisionRef.get() == "disposed" && attemptedOpen) {
                val lateSession = sessionRef.get()
                if (lateSession != null) {
                    try {
                        lateSession.close()
                    } catch (t: Throwable) {
                        Log.w(TAG, "late session.close() failed: ${t.javaClass.simpleName}: ${t.message}")
                    }
                }
                if (!sessionClosedFlag.get() && (lateSession != null || sessionConfiguredFlag.get())) {
                    try {
                        sessionClosedLatch.await(CLOSE_WAIT_MS, TimeUnit.MILLISECONDS)
                    } catch (t: InterruptedException) {
                        Thread.currentThread().interrupt()
                    }
                }

                val lateDevice = deviceRef.get()
                if (lateDevice != null) {
                    try {
                        lateDevice.close()
                    } catch (t: Throwable) {
                        Log.w(TAG, "late device.close() failed: ${t.javaClass.simpleName}: ${t.message}")
                    }
                }
                if (!deviceClosedFlag.get()) {
                    try {
                        deviceClosedLatch.await(CLOSE_WAIT_MS, TimeUnit.MILLISECONDS)
                    } catch (t: InterruptedException) {
                        Thread.currentThread().interrupt()
                    }
                }

                try {
                    sessionRef.get()?.close()
                } catch (t: Throwable) {
                    Log.w(TAG, "final late session.close() failed: ${t.javaClass.simpleName}: ${t.message}")
                }
                try {
                    deviceRef.get()?.close()
                } catch (t: Throwable) {
                    Log.w(TAG, "final late device.close() failed: ${t.javaClass.simpleName}: ${t.message}")
                }
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
            nativeGenerationId = nativeGenerationId,
            nativeSessionDestroyed = nativeSessionDestroyed,
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
