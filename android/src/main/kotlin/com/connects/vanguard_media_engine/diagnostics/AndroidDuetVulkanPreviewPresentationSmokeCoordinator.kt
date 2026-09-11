package com.connects.vanguard_media_engine.diagnostics

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.codec.AndroidDagSourceInspector
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import org.json.JSONObject
import java.io.File
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class AndroidDuetVulkanPreviewPresentationSmokeCoordinator(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VgDuetVulkanPresent"
        private const val METHOD_NAME = "runAndroidDuetVulkanPreviewPresentationSmoke"
        private const val PROOF_BOUNDARY =
            "native_android_duet_vulkan_preview_presentation_surfaceproducer_ahb_no_readback_diagnostic_only_no_production_preview_no_export"
        private const val PASS_MARKER = "ANDROID_DUET_VULKAN_PREVIEW_PRESENTATION_PHYSICAL_PASS"
        private const val FAIL_MARKER = "ANDROID_DUET_VULKAN_PREVIEW_PRESENTATION_PHYSICAL_FAIL"

        private const val DEFAULT_TIMEOUT_MS = 10000L
        private const val MIN_TIMEOUT_MS = 3000L
        private const val MAX_TIMEOUT_MS = 30000L
        private const val MAX_FRAMES_LIMIT = 600
        private const val DEFAULT_MAX_FRAMES = 60
        private const val DEFAULT_SURFACE_WIDTH = 720
        private const val DEFAULT_SURFACE_HEIGHT = 1280
        private const val FENCE_WAIT_MS = 1000L

        private val GATE_KEYS = listOf(
            "argumentValidationOk",
            "surfaceAcquireOk",
            "nativeWindowOk",
            "vulkanSetupOk",
            "swapchainCreateOk",
            "cameraFrameAcquireOk",
            "decoderFrameAcquireOk",
            "cameraImportOk",
            "decoderImportOk",
            "resolveOk",
            "maskUploadOk",
            "blendRenderNoReadbackOk",
            "swapchainPresentOk",
            "resourceReleaseOk",
            "diagnosticTeardownOk",
            "allNativeLanesPass",
        )

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME

        private fun clampLong(value: Long?, default: Long, min: Long, max: Long): Long {
            if (value == null) return default
            return value.coerceIn(min, max)
        }

        private fun clampInt(value: Int?, default: Int, min: Int, max: Int): Int {
            if (value == null) return default
            return value.coerceIn(min, max)
        }
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vg-duet-vulkan-presentation-smoke").apply { isDaemon = true }
    }
    private val active = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)
    private val currentProducer = AtomicReference<TextureRegistry.SurfaceProducer?>(null)

    private data class AcquiredSurfaceProducer(
        val producer: TextureRegistry.SurfaceProducer,
        val surface: Surface?,
        val textureId: Long,
    )

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        if (method != METHOD_NAME) return false
        runSmoke(args, result)
        return true
    }

    fun disposeAll() {
        if (disposed.compareAndSet(false, true)) {
            executor.shutdown()
            val producer = currentProducer.getAndSet(null)
            releaseSurfaceProducerOnMain(producer)
        }
    }

    private fun acquireSurfaceProducerOnMain(
        width: Int,
        height: Int,
        timeoutMs: Long,
    ): AcquiredSurfaceProducer {
        if (Looper.myLooper() == mainHandler.looper) {
            if (disposed.get()) {
                throw IllegalStateException("coordinator_disposed")
            }
            val producer = textureRegistry.createSurfaceProducer()
            currentProducer.set(producer)
            producer.setSize(width, height)
            val surface = producer.getSurface()
            val textureId = producer.id()
            return AcquiredSurfaceProducer(producer, surface, textureId)
        }

        val latch = CountDownLatch(1)
        val resultRef = AtomicReference<AcquiredSurfaceProducer?>()
        val errorRef = AtomicReference<Throwable?>()
        val timedOut = AtomicBoolean(false)

        val posted = mainHandler.post {
            try {
                if (disposed.get()) {
                    errorRef.set(IllegalStateException("coordinator_disposed"))
                    return@post
                }
                val producer = textureRegistry.createSurfaceProducer()
                currentProducer.set(producer)
                if (timedOut.get() || disposed.get()) {
                    val p = currentProducer.getAndSet(null)
                    try { p?.release() } catch (_: Throwable) {}
                    return@post
                }
                producer.setSize(width, height)
                val surface = producer.getSurface()
                val textureId = producer.id()
                if (timedOut.get() || disposed.get()) {
                    val p = currentProducer.getAndSet(null)
                    try { p?.release() } catch (_: Throwable) {}
                    return@post
                }
                resultRef.set(AcquiredSurfaceProducer(producer, surface, textureId))
            } catch (t: Throwable) {
                val p = currentProducer.getAndSet(null)
                try { p?.release() } catch (_: Throwable) {}
                errorRef.set(t)
            } finally {
                latch.countDown()
            }
        }

        if (!posted) {
            throw RuntimeException("surface_producer_post_failed")
        }

        if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
            timedOut.set(true)
            val p = currentProducer.getAndSet(null)
            releaseSurfaceProducerOnMain(p)
            throw RuntimeException("surface_acquire_timeout")
        }

        val err = errorRef.get()
        if (err != null) {
            val p = currentProducer.getAndSet(null)
            releaseSurfaceProducerOnMain(p)
            throw RuntimeException(err.message ?: err.javaClass.simpleName, err)
        }

        return resultRef.get() ?: throw RuntimeException("surface_acquire_failed")
    }

    private fun releaseSurfaceProducerOnMain(producer: TextureRegistry.SurfaceProducer?) {
        if (producer == null) return
        if (Looper.myLooper() == mainHandler.looper) {
            try {
                producer.release()
            } catch (t: Throwable) {
                Log.w(TAG, "surfaceProducer.release() failed on main thread", t)
            }
            return
        }
        val latch = CountDownLatch(1)
        val posted = mainHandler.post {
            try {
                producer.release()
            } catch (t: Throwable) {
                Log.w(TAG, "surfaceProducer.release() failed on main thread", t)
            } finally {
                latch.countDown()
            }
        }
        if (posted) {
            try {
                latch.await(2000L, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
    }

    private fun runSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        if (disposed.get()) {
            result.success(makeFailedMap("coordinator_disposed"))
            return
        }
        if (!active.compareAndSet(false, true)) {
            result.success(makeFailedMap("smoke_already_active"))
            return
        }
        try {
            executor.execute {
                try {
                    val payload = executeInternal(args)
                    mainHandler.post { result.success(payload) }
                } catch (t: Throwable) {
                    Log.e(TAG, "$METHOD_NAME failed", t)
                    mainHandler.post {
                        result.success(makeFailedMap("exception:${t.javaClass.simpleName}:${t.message}"))
                    }
                } finally {
                    active.set(false)
                }
            }
        } catch (t: Throwable) {
            active.set(false)
            Log.e(TAG, "$METHOD_NAME could not be scheduled", t)
            result.success(makeFailedMap("executor_rejected:${t.javaClass.simpleName}"))
        }
    }

    private fun hasCameraPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun executeInternal(args: Map<*, *>?): Map<String, Any?> {
        val startedMs = SystemClock.elapsedRealtime()
        val gates = LinkedHashMap<String, Boolean>().apply {
            for (key in GATE_KEYS) put(key, false)
        }
        val details = LinkedHashMap<String, Any?>()
        var failureReason: String? = null

        fun fail(reason: String) {
            if (failureReason == null) failureReason = reason
        }

        // 1. Argument validation
        val clipPath = args?.get("clipPath") as? String
        val timeoutMs = clampLong((args?.get("timeoutMs") as? Number)?.toLong(), DEFAULT_TIMEOUT_MS, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
        val maxFrames = clampInt((args?.get("maxFrames") as? Number)?.toInt(), DEFAULT_MAX_FRAMES, 1, MAX_FRAMES_LIMIT)
        val surfaceWidth = clampInt((args?.get("surfaceWidth") as? Number)?.toInt(), DEFAULT_SURFACE_WIDTH, 16, 4096)
        val surfaceHeight = clampInt((args?.get("surfaceHeight") as? Number)?.toInt(), DEFAULT_SURFACE_HEIGHT, 16, 4096)

        if (clipPath.isNullOrBlank()) {
            gates["argumentValidationOk"] = false
            fail("clipPath_missing")
        } else {
            val f = File(clipPath)
            if (!f.isFile || !f.canRead()) {
                gates["argumentValidationOk"] = false
                fail("clipPath_not_readable")
            } else {
                gates["argumentValidationOk"] = true
            }
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            fail("api_level_below_29")
        }
        if (!hasCameraPermission()) {
            fail("camera_permission_denied")
        }

        if (failureReason != null) {
            return buildFinalMap(gates, failureReason, details, startedMs, null)
        }

        // 2. Acquire real Flutter SurfaceProducer surface
        var surfaceProducer: TextureRegistry.SurfaceProducer? = null
        var flutterSurface: Surface? = null
        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
        var decoderImageReader: ImageReader? = null
        var decoderHandlerThread: HandlerThread? = null
        val decoderImageQueue = LinkedBlockingQueue<Image>(3)

        var cameraManager: CameraManager? = null
        var cameraDevice: CameraDevice? = null
        var cameraSession: CameraCaptureSession? = null
        var cameraImageReader: ImageReader? = null
        var cameraHandlerThread: HandlerThread? = null
        val cameraImageQueue = LinkedBlockingQueue<Image>(3)

        var nativeResultMap: Map<String, Any?>? = null

        try {
            val acquired = acquireSurfaceProducerOnMain(surfaceWidth, surfaceHeight, timeoutMs)
            surfaceProducer = acquired.producer
            flutterSurface = acquired.surface
            if (flutterSurface == null || !flutterSurface.isValid) {
                gates["surfaceAcquireOk"] = false
                throw RuntimeException("surface_acquire_failed")
            }
            gates["surfaceAcquireOk"] = true
            details["textureId"] = acquired.textureId
            details["surfaceWidth"] = surfaceWidth
            details["surfaceHeight"] = surfaceHeight

            // 3. Setup Decoder
            val insp = AndroidDagSourceInspector().inspect(clipPath!!)
            if (!insp.pass || insp.extractor == null || insp.format == null) {
                throw RuntimeException("inspection_failed:${insp.failureReason}")
            }
            extractor = insp.extractor
            val format = insp.format
            val mime = insp.mime
            format.setInteger(MediaFormat.KEY_ROTATION, 0)

            val decoderName = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .firstOrNull { info -> !info.isEncoder && info.isHardwareAccelerated && info.supportedTypes.any { it.equals(mime, true) } }
                ?.name ?: throw RuntimeException("no_hardware_decoder_for_$mime")

            decoderHandlerThread = HandlerThread("VgDuetDecPres").apply { start() }
            decoderImageReader = ImageReader.newInstance(
                insp.width, insp.height, ImageFormat.PRIVATE, 4, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE
            ).apply {
                setOnImageAvailableListener({ r ->
                    try {
                        val img = r.acquireNextImage()
                        if (img != null && !decoderImageQueue.offer(img)) img.close()
                    } catch (_: Throwable) {}
                }, Handler(decoderHandlerThread.looper))
            }

            codec = MediaCodec.createByCodecName(decoderName)
            codec.configure(format, decoderImageReader.surface, null, 0)
            codec.start()

            // 4. Setup Camera
            cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val cameraId = cameraManager.cameraIdList.firstOrNull {
                cameraManager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
            } ?: cameraManager.cameraIdList.firstOrNull() ?: throw RuntimeException("no_camera")

            val characteristics = cameraManager.getCameraCharacteristics(cameraId)
            val streamConfigMap = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val sizes = streamConfigMap?.getOutputSizes(ImageFormat.YUV_420_888)?.filter { it.width > 0 && it.height > 0 } ?: emptyList()
            if (sizes.isEmpty()) throw RuntimeException("no_yuv_sizes")
            val camSize = sizes.first()

            cameraHandlerThread = HandlerThread("VgDuetCamPres").apply { start() }
            val camBgHandler = Handler(cameraHandlerThread.looper)
            cameraImageReader = ImageReader.newInstance(
                camSize.width, camSize.height, ImageFormat.YUV_420_888, 4, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE
            ).apply {
                setOnImageAvailableListener({ r ->
                    try {
                        val img = r.acquireLatestImage()
                        if (img != null && !cameraImageQueue.offer(img)) img.close()
                    } catch (_: Throwable) {}
                }, camBgHandler)
            }

            val camOpenLatch = CountDownLatch(1)
            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    cameraDevice = camera
                    camOpenLatch.countDown()
                }
                override fun onDisconnected(camera: CameraDevice) {
                    cameraDevice = camera
                    camOpenLatch.countDown()
                }
                override fun onError(camera: CameraDevice, error: Int) {
                    cameraDevice = camera
                    camOpenLatch.countDown()
                }
            }, camBgHandler)

            if (!camOpenLatch.await(timeoutMs, TimeUnit.MILLISECONDS) || cameraDevice == null) {
                throw RuntimeException("camera_open_failed_or_timeout")
            }

            val camSessionLatch = CountDownLatch(1)
            val reqBuilder = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
            reqBuilder.addTarget(cameraImageReader.surface)

            cameraDevice!!.createCaptureSession(listOf(cameraImageReader.surface), object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    cameraSession = session
                    camSessionLatch.countDown()
                }
                override fun onConfigureFailed(session: CameraCaptureSession) {
                    camSessionLatch.countDown()
                }
            }, camBgHandler)

            if (!camSessionLatch.await(timeoutMs, TimeUnit.MILLISECONDS) || cameraSession == null) {
                throw RuntimeException("camera_session_failed_or_timeout")
            }

            cameraSession!!.setRepeatingRequest(reqBuilder.build(), null, camBgHandler)

            // 5. Feed decoder & acquire frames
            var inputDone = false
            for (i in 0 until maxFrames) {
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(0)
                    if (inIdx >= 0) {
                        val buf = codec.getInputBuffer(inIdx)
                        if (buf != null) {
                            val size = extractor.readSampleData(buf, 0)
                            if (size < 0) {
                                codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }
                }

                val info = MediaCodec.BufferInfo()
                val outIdx = codec.dequeueOutputBuffer(info, 10000)
                if (outIdx >= 0) {
                    val renderable = info.size > 0
                    codec.releaseOutputBuffer(outIdx, renderable)
                    if (renderable) break
                }
            }

            val decoderImage = decoderImageQueue.poll(timeoutMs, TimeUnit.MILLISECONDS)
            gates["decoderFrameAcquireOk"] = decoderImage != null
            if (decoderImage == null) throw RuntimeException("decoder_acquire_timeout")

            val cameraImage = cameraImageQueue.poll(timeoutMs, TimeUnit.MILLISECONDS)
            gates["cameraFrameAcquireOk"] = cameraImage != null
            if (cameraImage == null) {
                decoderImage.close()
                throw RuntimeException("camera_acquire_timeout")
            }

            // 6. Native Invoke with open HardwareBuffers
            var decBuf: HardwareBuffer? = null
            var camBuf: HardwareBuffer? = null
            try {
                decBuf = decoderImage.hardwareBuffer
                camBuf = cameraImage.hardwareBuffer
                if (decBuf == null || camBuf == null) throw RuntimeException("hardware_buffer_null")

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    try {
                        val dFence = decoderImage.fence
                        if (dFence.isValid) dFence.await(Duration.ofMillis(FENCE_WAIT_MS))
                        dFence.close()
                    } catch (_: Throwable) {}
                    try {
                        val cFence = cameraImage.fence
                        if (cFence.isValid) cFence.await(Duration.ofMillis(FENCE_WAIT_MS))
                        cFence.close()
                    } catch (_: Throwable) {}
                }

                val bridge = VanguardNativeBridge(
                    VanguardLifecycleObserver(VanguardDiagnostics()),
                    VanguardDiagnostics(),
                    null
                )
                val rawJson = bridge.renderAndroidDuetVulkanPreviewPresentation(
                    flutterSurface, surfaceWidth, surfaceHeight,
                    camBuf, camSize.width, camSize.height,
                    decBuf, insp.width, insp.height
                )
                nativeResultMap = parseNativeJson(rawJson)
            } finally {
                try { decBuf?.close() } catch (_: Throwable) {}
                try { camBuf?.close() } catch (_: Throwable) {}
                try { decoderImage.close() } catch (_: Throwable) {}
                try { cameraImage.close() } catch (_: Throwable) {}
            }

        } catch (t: Throwable) {
            fail(t.message ?: t.javaClass.simpleName)
        } finally {
            // 7. Cleanup
            try {
                cameraSession?.stopRepeating()
                cameraSession?.abortCaptures()
                cameraSession?.close()
            } catch (_: Throwable) {}

            try {
                cameraDevice?.close()
            } catch (_: Throwable) {}

            try { cameraImageReader?.close() } catch (_: Throwable) {}
            cameraHandlerThread?.quitSafely()

            try {
                while (true) {
                    val img = decoderImageQueue.poll() ?: break
                    img.close()
                }
            } catch (_: Throwable) {}
            try {
                while (true) {
                    val img = cameraImageQueue.poll() ?: break
                    img.close()
                }
            } catch (_: Throwable) {}

            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { decoderImageReader?.close() } catch (_: Throwable) {}
            decoderHandlerThread?.quitSafely()
            try { extractor?.release() } catch (_: Throwable) {}

            // Release producer (SurfaceProducer owns surface lifecycle, do not directly release surface)
            try {
                val producerToRelease = currentProducer.getAndSet(null) ?: surfaceProducer
                releaseSurfaceProducerOnMain(producerToRelease)
            } catch (_: Throwable) {}
            surfaceProducer = null
        }

        return buildFinalMap(gates, failureReason, details, startedMs, nativeResultMap)
    }

    private fun buildFinalMap(
        gates: MutableMap<String, Boolean>,
        failureReason: String?,
        details: MutableMap<String, Any?>,
        startedMs: Long,
        nativeResultMap: Map<String, Any?>?
    ): Map<String, Any?> {
        details["elapsedMs"] = SystemClock.elapsedRealtime() - startedMs

        if (nativeResultMap != null) {
            for (key in GATE_KEYS) {
                if (nativeResultMap[key] == true) {
                    gates[key] = true
                }
            }
            if (nativeResultMap["gates"] is Map<*, *>) {
                val nGates = nativeResultMap["gates"] as Map<*, *>
                for (key in GATE_KEYS) {
                    if (nGates[key] == true) {
                        gates[key] = true
                    }
                }
            }
            if (nativeResultMap["details"] is Map<*, *>) {
                val nDetails = nativeResultMap["details"] as Map<String, Any?>
                details.putAll(nDetails)
            }
        }

        val allNativeLanesPass = (nativeResultMap?.get("allNativeLanesPass") == true)
        gates["allNativeLanesPass"] = allNativeLanesPass

        val pass = GATE_KEYS.all { gates[it] == true }
        val status = if (pass) "PASS" else if (nativeResultMap?.get("status") == "UNSUPPORTED") "UNSUPPORTED" else "FAIL"

        val map = LinkedHashMap<String, Any?>()
        map["pass"] = pass
        map["status"] = status
        map["marker"] = if (pass) PASS_MARKER else FAIL_MARKER
        map["proofBoundary"] = PROOF_BOUNDARY
        map["failureReason"] = if (pass) "" else (failureReason ?: nativeResultMap?.get("failureReason") as? String ?: "unknown")

        for (key in GATE_KEYS) {
            map[key] = gates[key] == true
        }
        map["gates"] = LinkedHashMap(gates)
        map["allNativeLanesPass"] = allNativeLanesPass
        map["details"] = details
        map["raw"] = nativeResultMap?.get("raw") ?: JSONObject(map as Map<*, *>).toString()

        return map
    }

    private fun parseNativeJson(raw: String): Map<String, Any?> {
        return try {
            val json = JSONObject(raw)
            val map = LinkedHashMap<String, Any?>()
            val keys = json.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                map[key] = convertJsonValue(json.opt(key))
            }
            map["raw"] = raw
            map
        } catch (t: Throwable) {
            mapOf("pass" to false, "status" to "FAIL", "failureReason" to "native_result_not_json", "raw" to raw)
        }
    }

    private fun convertJsonValue(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> {
            val m = LinkedHashMap<String, Any?>()
            val k = value.keys()
            while (k.hasNext()) { val key = k.next(); m[key] = convertJsonValue(value.opt(key)) }
            m
        }
        else -> value
    }

    private fun makeFailedMap(reason: String): Map<String, Any?> {
        val gates = LinkedHashMap<String, Boolean>().apply {
            for (k in GATE_KEYS) put(k, false)
        }
        return mapOf(
            "pass" to false,
            "status" to "FAIL",
            "marker" to FAIL_MARKER,
            "proofBoundary" to PROOF_BOUNDARY,
            "failureReason" to reason,
            "allNativeLanesPass" to false,
            "gates" to gates,
            "details" to emptyMap<String, Any?>(),
            "raw" to "{}",
        )
    }
}
