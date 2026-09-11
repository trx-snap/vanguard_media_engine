package com.example.vanguard_media_engine_example

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.Bundle
import android.os.DeadObjectException
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.os.RemoteException
import android.os.SystemClock
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.ByteBufferExtractor
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenter
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenterResult
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.CompatibilityList
import org.tensorflow.lite.gpu.GpuDelegate
import org.tensorflow.lite.gpu.GpuDelegateFactory

class MainActivity : FlutterActivity() {

    private var activeSession: ProbeSession? = null
    private var activeTfliteGpuSession: TfliteGpuProbeSession? = null
    private var activeTfliteGpuIsolatedSession: TfliteGpuIsolatedProbeSession? = null

    // Diagnostic-only: Android Duet deterministic GLES export composition proof
    // (see AndroidDuetGlesExportCompositionSmokeCoordinator). Bridge-only wiring;
    // all harness logic lives in the diagnostics package coordinator/harness pair.
    private val duetGlesExportCompositionCoordinator by lazy {
        com.connects.vanguard_media_engine.diagnostics.AndroidDuetGlesExportCompositionSmokeCoordinator(
            Handler(Looper.getMainLooper()),
        )
    }

    // Diagnostic-only: Android Duet deterministic per-frame GLES mask upload export proof
    // (see AndroidDuetGlesDynamicMaskExportSmokeCoordinator). Bridge-only wiring;
    // all harness logic lives in the diagnostics package coordinator/harness pair.
    private val duetGlesDynamicMaskExportCoordinator by lazy {
        com.connects.vanguard_media_engine.diagnostics.AndroidDuetGlesDynamicMaskExportSmokeCoordinator(
            Handler(Looper.getMainLooper()),
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                if (call.method == METHOD_NAME) {
                    runGpuCategoryMaskProbe(result)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TFLITE_GPU_CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                if (call.method == TFLITE_GPU_METHOD_NAME) {
                    runTfliteGpuProbe(result)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TFLITE_GPU_ISOLATED_CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                if (call.method == TFLITE_GPU_ISOLATED_METHOD_NAME) {
                    runTfliteGpuIsolatedProbe(call, result)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DUET_GLES_PIXEL_PROOF_CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                if (call.method == DUET_GLES_PIXEL_PROOF_METHOD_NAME) {
                    runAndroidDuetGlesPixelProof(result)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DUET_GLES_EXPORT_COMPOSITION_CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                val args = call.arguments as? Map<*, *>
                if (!duetGlesExportCompositionCoordinator.handleMethodCall(call.method, args, result)) {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DUET_GLES_DYNAMIC_MASK_EXPORT_CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                val args = call.arguments as? Map<*, *>
                if (!duetGlesDynamicMaskExportCoordinator.handleMethodCall(call.method, args, result)) {
                    result.notImplemented()
                }
            }
    }

    private fun runAndroidDuetGlesPixelProof(result: MethodChannel.Result) {
        try {
            val harness = com.connects.vanguard_media_engine.diagnostics.AndroidDuetGlesPixelProofSmokeHarness()
            val proofResult = harness.run()
            result.success(proofResult)
        } catch (t: Throwable) {
            val fallback = mapOf(
                "pass" to false,
                "marker" to "ANDROID_DUET_GLES_PIXEL_PROOF_PHYSICAL_FAIL",
                "proofBoundary" to "android_duet_gles_pixel_proof_synthetic_mask_upload_and_blend_only",
                "failureReason" to "unexpected_exception:${t.javaClass.simpleName}:${t.message}",
                "tolerance" to 1,
                "maxDelta" to -1,
                "sampleCount" to 0,
                "gates" to emptyMap<String, Boolean>(),
                "details" to mapOf("error" to (t.message ?: t.toString())),
                "nonClaims" to listOf(
                    "No ML human matte quality claim (synthetic mask patterns only)",
                    "No CameraX or OES external texture claim (sampler2D synthetic camera used)",
                    "No live preview lifecycle or SurfaceTexture concurrency claim",
                    "No export MP4, MediaCodec, or A/V sync claim",
                    "No GPU delegate promotion or TFLite/MediaPipe runtime claim",
                ),
            )
            result.success(fallback)
        }
    }

    private fun runGpuCategoryMaskProbe(result: MethodChannel.Result) {
        // Reject non-debuggable builds using ApplicationInfo.FLAG_DEBUGGABLE
        val isDebuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!isDebuggable) {
            val failLog = "ANDROID_DUET_GPU_CATEGORY_MASK_PROBE_FAIL code=not_debuggable message=Probe rejected: app is not debuggable"
            Log.e(TAG, failLog)
            println(failLog)
            result.error("NOT_DEBUGGABLE", "Probe rejected: app is not debuggable", null)
            return
        }

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            val failLog = "ANDROID_DUET_GPU_CATEGORY_MASK_PROBE_FAIL code=permission_denied message=Camera permission not granted"
            Log.e(TAG, failLog)
            println(failLog)
            result.error("PERMISSION_DENIED", "Camera permission not granted", null)
            return
        }

        if (activeSession != null || activeTfliteGpuSession != null || activeTfliteGpuIsolatedSession != null) {
            val failLog = "ANDROID_DUET_GPU_CATEGORY_MASK_PROBE_FAIL code=probe_already_running message=Probe is already running"
            Log.e(TAG, failLog)
            println(failLog)
            result.error("PROBE_ALREADY_RUNNING", "Probe is already running", null)
            return
        }

        val startLog = "ANDROID_DUET_GPU_CATEGORY_MASK_PROBE_START"
        Log.i(TAG, startLog)
        println(startLog)

        val session = ProbeSession(this, result) {
            activeSession = null
        }
        activeSession = session
        session.start()
    }

    override fun onDestroy() {
        activeSession?.cancel()
        activeSession = null
        activeTfliteGpuSession?.cancel()
        activeTfliteGpuSession = null
        activeTfliteGpuIsolatedSession?.cancel()
        activeTfliteGpuIsolatedSession = null
        duetGlesExportCompositionCoordinator.disposeAll()
        duetGlesDynamicMaskExportCoordinator.disposeAll()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "DuetGpuCategoryProbe"
        private const val CHANNEL_NAME = "vanguard_media_engine_example/gpu_category_mask_probe"
        private const val METHOD_NAME = "runGpuCategoryMaskProbe"
        private const val MODEL_ASSET_PATH = "selfie_segmenter.tflite"
        private const val TARGET_FRAMES = 30
        private const val PROBE_TIMEOUT_MS = 25_000L

        // Deterministic GLES matte-upload and composited-pixel proof (Stage 1).
        private const val DUET_GLES_PIXEL_PROOF_CHANNEL_NAME =
            "vanguard_media_engine_example/duet_gles_pixel_proof"
        private const val DUET_GLES_PIXEL_PROOF_METHOD_NAME =
            "runAndroidDuetGlesPixelProof"

        // Diagnostic-only Duet GLES export composition proof (see
        // AndroidDuetGlesExportCompositionSmokeCoordinator); the method name is
        // owned by the coordinator itself.
        private const val DUET_GLES_EXPORT_COMPOSITION_CHANNEL_NAME =
            "vanguard_media_engine_example/duet_gles_export_composition"

        // Diagnostic-only Duet GLES dynamic mask export proof (see
        // AndroidDuetGlesDynamicMaskExportSmokeCoordinator).
        private const val DUET_GLES_DYNAMIC_MASK_EXPORT_CHANNEL_NAME =
            "vanguard_media_engine_example/duet_gles_dynamic_mask_export"

        // Raw TFLite GPU Interpreter diagnostic probe (example-only).
        private const val TFLITE_TAG = "DuetTfliteGpuProbe"
        private const val TFLITE_GPU_CHANNEL_NAME = "vanguard_media_engine_example/tflite_gpu_probe"
        private const val TFLITE_GPU_METHOD_NAME = "runTfliteGpuProbe"
        private const val TFLITE_GPU_THREAD_NAME = "DuetTfliteGpuProbe-GPU"
        private const val TFLITE_PROBE_TIMEOUT_MS = 25_000L
        private const val TFLITE_CLOSE_WAIT_MS = 1_500L

        private fun logTfliteGpu(line: String) {
            Log.i(TFLITE_TAG, line)
            println(line)
        }

        private fun logTfliteGpuFail(code: String, message: String, throwable: Throwable?) {
            val line = "ANDROID_DUET_TFLITE_GPU_PROBE_FAIL code=$code message=$message"
            Log.e(TFLITE_TAG, line, throwable)
            println(line)
        }

        // Out-of-process forced raw TFLite GPU diagnostic probe (example-only).
        // Parent side; the child lives in TfliteGpuIsolatedProbeService (:gpuprobe).
        private const val ISOLATED_TAG = "DuetTfliteGpuIsolated"
        private const val TFLITE_GPU_ISOLATED_CHANNEL_NAME = "vanguard_media_engine_example/tflite_gpu_isolated_probe"
        private const val TFLITE_GPU_ISOLATED_METHOD_NAME = "runTfliteGpuIsolatedProbe"
        private const val ISOLATED_ARG_MODEL_ASSET_PATH = "modelAssetPath"
        private const val ISOLATED_DEFAULT_MODEL_ASSET_PATH = "selfie_segmenter.tflite"
        private const val ISOLATED_ARG_DELEGATE_MODE = "delegateMode"
        private const val ISOLATED_DEFAULT_DELEGATE_MODE = "compat_best_or_default"
        private const val ISOLATED_ARG_REPEAT_COUNT = "repeatCount"
        private const val ISOLATED_DEFAULT_REPEAT_COUNT = 5
        private const val ISOLATED_MAX_REPEAT_COUNT = 30
        private val ISOLATED_VALID_DELEGATE_MODES = setOf(
            "compat_best_or_default",
            "forced_default",
            "sustained_speed",
            "force_opencl",
            "force_opengl",
        )
        private const val ISOLATED_PROBE_TIMEOUT_MS = 30_000L
        private const val ISOLATED_MODE_FORCED_GPU_COMPLETED = "forced_gpu_completed"
        private const val ISOLATED_MODE_CHILD_PROBE_FAILED = "child_probe_failed"
        private const val ISOLATED_MODE_CHILD_DIED = "child_process_died_parent_survived"
        private const val ISOLATED_MODE_TIMEOUT = "timeout"
        private const val ISOLATED_MODE_PARENT_FAILED = "parent_failed"
        private const val ISOLATED_ALIVE_AFTER_CHILD_DEATH =
            "ANDROID_DUET_TFLITE_GPU_ISOLATED_PARENT_ALIVE_AFTER_CHILD_DEATH"
        private const val ISOLATED_ALIVE_AFTER_RESULT =
            "ANDROID_DUET_TFLITE_GPU_ISOLATED_PARENT_ALIVE_AFTER_RESULT"

        private fun logIsolated(line: String) {
            Log.i(ISOLATED_TAG, line)
            println(line)
        }

        private fun logIsolatedFail(code: String, message: String, throwable: Throwable?) {
            val line = "ANDROID_DUET_TFLITE_GPU_ISOLATED_PARENT_FAIL code=$code message=$message"
            Log.e(ISOLATED_TAG, line, throwable)
            println(line)
        }

        /**
         * Relative Android asset path check: non-empty, no leading slash
         * (absolute), no ".." traversal, no backslash, no control characters.
         */
        private fun isValidIsolatedModelAssetPath(path: String): Boolean {
            if (path.isEmpty()) return false
            if (path.startsWith("/")) return false
            if (path.contains("..")) return false
            if (path.contains("\\")) return false
            if (path.any { it.isISOControl() }) return false
            return true
        }

        private fun isValidIsolatedDelegateMode(mode: String): Boolean =
            ISOLATED_VALID_DELEGATE_MODES.contains(mode)
    }

    private class ProbeSession(
        private val activity: MainActivity,
        private val result: MethodChannel.Result,
        private val onFinished: () -> Unit,
    ) {
        private val mainHandler = Handler(Looper.getMainLooper())
        private val resultCompleted = AtomicBoolean(false)
        private val isTerminated = AtomicBoolean(false)
        private val inFlight = AtomicBoolean(false)
        private val framesCompleted = AtomicInteger(0)

        private var cameraProvider: ProcessCameraProvider? = null
        private var segmenter: ImageSegmenter? = null
        private var lastTimestampMs = Long.MIN_VALUE

        private var firstWidth = 0
        private var firstHeight = 0
        private var firstZeroCount = 0L
        private var firstNonZeroCount = 0L

        private var lastWidth = 0
        private var lastHeight = 0
        private var lastZeroCount = 0L
        private var lastNonZeroCount = 0L

        private val gpuExecutor: ExecutorService = Executors.newSingleThreadExecutor { r ->
            Thread(r, "DuetGpuProbe-GPU").apply { isDaemon = true }
        }
        private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor { r ->
            Thread(r, "DuetGpuProbe-Analysis").apply { isDaemon = true }
        }

        private val timeoutRunnable = Runnable {
            handleFailure(
                "timeout",
                "Probe timed out after ${PROBE_TIMEOUT_MS}ms (frames=${framesCompleted.get()})",
                null,
            )
        }

        fun start() {
            mainHandler.postDelayed(timeoutRunnable, PROBE_TIMEOUT_MS)

            gpuExecutor.execute {
                try {
                    val baseOptions = BaseOptions.builder()
                        .setModelAssetPath(MODEL_ASSET_PATH)
                        .setDelegate(Delegate.GPU)
                        .build()
                    val options = ImageSegmenter.ImageSegmenterOptions.builder()
                        .setBaseOptions(baseOptions)
                        .setRunningMode(RunningMode.VIDEO)
                        .setOutputCategoryMask(true)
                        .setOutputConfidenceMasks(false)
                        .build()
                    val created = ImageSegmenter.createFromOptions(activity.applicationContext, options)
                    if (isTerminated.get()) {
                        try { created.close() } catch (_: Throwable) {}
                        return@execute
                    }
                    segmenter = created

                    val readyLog = "ANDROID_DUET_GPU_CATEGORY_MASK_SEGMENTER_READY delegate=GPU mode=VIDEO output=category_mask"
                    Log.i(TAG, readyLog)
                    println(readyLog)

                    mainHandler.post {
                        if (!isTerminated.get()) {
                            startCamera()
                        }
                    }
                } catch (t: Throwable) {
                    handleFailure(
                        "mediapipe_init_failed",
                        "Failed to initialize MediaPipe GPU segmenter: ${t.message}",
                        t,
                    )
                }
            }
        }

        private fun startCamera() {
            if (activity.isFinishing || activity.isDestroyed || isTerminated.get()) return
            try {
                val cameraProviderFuture = ProcessCameraProvider.getInstance(activity)
                cameraProviderFuture.addListener({
                    try {
                        if (isTerminated.get()) return@addListener
                        val provider = cameraProviderFuture.get()
                        cameraProvider = provider

                        val imageAnalysis = ImageAnalysis.Builder()
                            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                            .build()

                        imageAnalysis.setAnalyzer(analysisExecutor) { proxy ->
                            handleImageProxy(proxy)
                        }

                        val cameraSelector = CameraSelector.DEFAULT_FRONT_CAMERA
                        provider.unbindAll()
                        provider.bindToLifecycle(activity, cameraSelector, imageAnalysis)
                    } catch (t: Throwable) {
                        handleFailure("camerax_bind_failed", "CameraX bindToLifecycle failed: ${t.message}", t)
                    }
                }, ContextCompat.getMainExecutor(activity))
            } catch (t: Throwable) {
                handleFailure("camerax_init_failed", "CameraX getInstance failed: ${t.message}", t)
            }
        }

        private fun handleImageProxy(proxy: ImageProxy) {
            if (isTerminated.get() || framesCompleted.get() >= TARGET_FRAMES) {
                proxy.close()
                return
            }
            if (!inFlight.compareAndSet(false, true)) {
                // Drop frame if GPU executor is still working on previous frame
                proxy.close()
                return
            }

            val bitmap: Bitmap
            val timestampMs: Long
            try {
                bitmap = toUprightBitmap(proxy)
                timestampMs = proxy.imageInfo.timestamp / 1_000_000L
            } catch (t: Throwable) {
                proxy.close()
                inFlight.set(false)
                Log.w(TAG, "Frame bitmap conversion failed: ${t.message}")
                return
            } finally {
                proxy.close()
            }

            try {
                gpuExecutor.execute {
                    try {
                        if (isTerminated.get()) {
                            try { bitmap.recycle() } catch (_: Throwable) {}
                            return@execute
                        }
                        processFrameOnGpu(bitmap, timestampMs)
                    } catch (t: Throwable) {
                        handleFailure("gpu_processing_failed", "GPU processing error: ${t.message}", t)
                    } finally {
                        inFlight.set(false)
                    }
                }
            } catch (e: RejectedExecutionException) {
                try { bitmap.recycle() } catch (_: Throwable) {}
                inFlight.set(false)
            }
        }

        private fun processFrameOnGpu(bitmap: Bitmap, timestampMs: Long) {
            val seg = segmenter ?: throw IllegalStateException("Segmenter is null on GPU thread")

            // Strictly increasing timestamp (VIDEO mode contract)
            val ts = if (timestampMs <= lastTimestampMs) lastTimestampMs + 1 else timestampMs
            lastTimestampMs = ts

            var mpImage: MPImage? = null
            var result: ImageSegmenterResult? = null
            try {
                mpImage = BitmapImageBuilder(bitmap).build()
                result = seg.segmentForVideo(mpImage, ts)

                val maskOpt = result.categoryMask()
                val mask = maskOpt.orElse(null)
                    ?: throw IllegalStateException("No category mask returned in ImageSegmenterResult")

                val width = mask.width
                val height = mask.height
                if (width <= 0 || height <= 0) {
                    throw IllegalStateException("Invalid mask dimensions: width=$width, height=$height")
                }

                val buffer: ByteBuffer = ByteBufferExtractor.extract(mask, MPImage.IMAGE_FORMAT_ALPHA)
                val totalBytes = buffer.remaining()
                val pixelCount = (width * height).toLong()
                if (totalBytes.toLong() < pixelCount) {
                    throw IllegalStateException("Buffer remaining ($totalBytes) is less than required ($pixelCount)")
                }

                val dup = buffer.duplicate()
                var zeroCount = 0L
                var nonZeroCount = 0L
                val bytesToRead = minOf(totalBytes.toLong(), pixelCount).toInt()
                val chunk = ByteArray(minOf(bytesToRead, 4096))
                var readSoFar = 0
                while (readSoFar < bytesToRead) {
                    val count = minOf(chunk.size, bytesToRead - readSoFar)
                    dup.get(chunk, 0, count)
                    for (i in 0 until count) {
                        if (chunk[i].toInt() == 0) {
                            zeroCount++
                        } else {
                            nonZeroCount++
                        }
                    }
                    readSoFar += count
                }

                val count = framesCompleted.incrementAndGet()

                if (count == 1) {
                    firstWidth = width
                    firstHeight = height
                    firstZeroCount = zeroCount
                    firstNonZeroCount = nonZeroCount
                    val firstLog = "ANDROID_DUET_GPU_CATEGORY_MASK_FIRST width=$width height=$height zero=$zeroCount nonZero=$nonZeroCount format=uint8_category"
                    Log.i(TAG, firstLog)
                    println(firstLog)
                }

                if (count % 5 == 0 || count == TARGET_FRAMES) {
                    val progLog = "ANDROID_DUET_GPU_CATEGORY_MASK_PROGRESS frames=$count"
                    Log.i(TAG, progLog)
                    println(progLog)
                }

                lastWidth = width
                lastHeight = height
                lastZeroCount = zeroCount
                lastNonZeroCount = nonZeroCount

                if (count >= TARGET_FRAMES) {
                    handlePass()
                }
            } finally {
                try {
                    result?.categoryMask()?.orElse(null)?.close()
                } catch (_: Throwable) {}
                try {
                    mpImage?.close()
                } catch (_: Throwable) {}
                try {
                    bitmap.recycle()
                } catch (_: Throwable) {}
            }
        }

        private fun handlePass() {
            if (isTerminated.compareAndSet(false, true)) {
                mainHandler.removeCallbacks(timeoutRunnable)

                mainHandler.post {
                    try {
                        cameraProvider?.unbindAll()
                    } catch (t: Throwable) {
                        Log.w(TAG, "Failed to unbind camera: ${t.message}")
                    }
                }

                try {
                    segmenter?.close()
                    val closeLog = "ANDROID_DUET_GPU_CATEGORY_MASK_CLOSE_PASS"
                    Log.i(TAG, closeLog)
                    println(closeLog)
                } catch (t: Throwable) {
                    Log.w(TAG, "segmenter.close() threw: ${t.message}")
                }
                segmenter = null

                val passLog = "ANDROID_DUET_GPU_CATEGORY_MASK_PROBE_PASS frames=${framesCompleted.get()} width=$lastWidth height=$lastHeight zero=$lastZeroCount nonZero=$lastNonZeroCount"
                Log.i(TAG, passLog)
                println(passLog)

                val payload = mapOf(
                    "pass" to true,
                    "frames" to framesCompleted.get(),
                    "width" to lastWidth,
                    "height" to lastHeight,
                    "firstZero" to firstZeroCount,
                    "firstNonZero" to firstNonZeroCount,
                    "lastZero" to lastZeroCount,
                    "lastNonZero" to lastNonZeroCount,
                )

                completeResult { it.success(payload) }
                cleanupExecutors()
                onFinished()
            }
        }

        fun handleFailure(code: String, message: String, throwable: Throwable?) {
            if (isTerminated.compareAndSet(false, true)) {
                mainHandler.removeCallbacks(timeoutRunnable)

                val failLog = "ANDROID_DUET_GPU_CATEGORY_MASK_PROBE_FAIL code=$code message=$message"
                Log.e(TAG, failLog, throwable)
                println(failLog)

                mainHandler.post {
                    try {
                        cameraProvider?.unbindAll()
                    } catch (t: Throwable) {
                        Log.w(TAG, "Failed to unbind camera: ${t.message}")
                    }
                }

                if (Thread.currentThread().name == "DuetGpuProbe-GPU") {
                    try {
                        segmenter?.close()
                    } catch (t: Throwable) {
                        Log.w(TAG, "segmenter.close() threw: ${t.message}")
                    }
                    segmenter = null
                } else {
                    val latch = CountDownLatch(1)
                    try {
                        gpuExecutor.execute {
                            try {
                                segmenter?.close()
                            } catch (t: Throwable) {
                                Log.w(TAG, "segmenter.close() threw: ${t.message}")
                            }
                            segmenter = null
                            latch.countDown()
                        }
                        latch.await(1000, TimeUnit.MILLISECONDS)
                    } catch (_: Throwable) {
                        latch.countDown()
                    }
                }

                completeResult { it.error(code, message, throwable?.stackTraceToString()) }
                cleanupExecutors()
                onFinished()
            }
        }

        fun cancel() {
            handleFailure("cancelled", "Probe cancelled", null)
        }

        private fun completeResult(action: (MethodChannel.Result) -> Unit) {
            if (resultCompleted.compareAndSet(false, true)) {
                mainHandler.post {
                    try {
                        action(result)
                    } catch (t: Throwable) {
                        Log.e(TAG, "MethodChannel.Result completion failed: ${t.message}", t)
                    }
                }
            }
        }

        private fun cleanupExecutors() {
            Thread({
                try {
                    analysisExecutor.shutdown()
                    gpuExecutor.shutdown()
                    analysisExecutor.awaitTermination(1, TimeUnit.SECONDS)
                    gpuExecutor.awaitTermination(1, TimeUnit.SECONDS)
                } catch (_: Throwable) {}
            }, "DuetGpuProbe-Shutdown").start()
        }

        private fun toUprightBitmap(proxy: ImageProxy): Bitmap {
            val raw = proxy.toBitmap()
            val rotation = proxy.imageInfo.rotationDegrees
            if (rotation % 360 == 0) return raw
            val matrix = Matrix().apply { postRotate(rotation.toFloat()) }
            val rotated = Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, matrix, true)
            if (rotated !== raw) {
                try { raw.recycle() } catch (_: Throwable) {}
            }
            return rotated
        }
    }

    // ── Example-only raw TensorFlow Lite GPU Interpreter diagnostic probe ────
    //
    // Diagnostic evidence only. This does NOT enable anything in production and
    // does not touch the Duet ladder (mediapipe_cpu -> mlkit). It exists because
    // MediaPipe Tasks GPU native-aborted on SM-A566B / Android 16
    // (image_frame.cc Format UNKNOWN) for both confidence and category masks, so
    // we need proof about the raw TFLite GPU delegate itself, owning the tensor
    // buffers directly, without any MediaPipe packet/image conversion layer.
    //
    // Ownership / threading:
    //   * CompatibilityList, GpuDelegate and Interpreter are created, invoked
    //     and closed on exactly one owned single-thread executor (GPU thread).
    //     Interpreter is closed before the delegate, both on that thread.
    //   * CameraX ImageAnalysis (front camera, no preview) delivers frames on an
    //     owned analysis thread; the analyzer copies the ImageProxy into an
    //     upright Bitmap, closes the proxy immediately, then hands the bitmap to
    //     the GPU thread. At most one frame is in flight; extras are dropped.
    //   * MethodChannel.Result is completed exactly once, on the main thread.
    //   * Cleanup (camera unbind, TFLite close, executor shutdown) runs on
    //     success, catchable failure, native timeout and Activity destroy.
    //   * A vendor-driver native abort (SIGABRT) kills the process; that is
    //     acceptable diagnostic evidence and no signal handler is installed.
    private fun runTfliteGpuProbe(result: MethodChannel.Result) {
        // Reject non-debuggable builds using ApplicationInfo.FLAG_DEBUGGABLE.
        val isDebuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!isDebuggable) {
            logTfliteGpuFail("not_debuggable", "Probe rejected: app is not debuggable", null)
            result.error("NOT_DEBUGGABLE", "Probe rejected: app is not debuggable", null)
            return
        }

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            logTfliteGpuFail("permission_denied", "Camera permission not granted", null)
            result.error("PERMISSION_DENIED", "Camera permission not granted", null)
            return
        }

        if (activeTfliteGpuSession != null || activeSession != null || activeTfliteGpuIsolatedSession != null) {
            logTfliteGpuFail("probe_already_running", "Another example probe is already running", null)
            result.error("PROBE_ALREADY_RUNNING", "Another example probe is already running", null)
            return
        }

        logTfliteGpu("ANDROID_DUET_TFLITE_GPU_PROBE_START")

        val session = TfliteGpuProbeSession(this, result) { finished ->
            if (activeTfliteGpuSession === finished) {
                activeTfliteGpuSession = null
            }
        }
        activeTfliteGpuSession = session
        session.start()
    }

    private class TfliteGpuProbeSession(
        private val activity: MainActivity,
        private val result: MethodChannel.Result,
        private val onFinished: (TfliteGpuProbeSession) -> Unit,
    ) {
        private class OutputSpec(
            val index: Int,
            val shape: IntArray,
            val type: DataType,
            val expectedBytes: Int,
            val buffer: ByteBuffer,
        )

        private class OutputStats(
            val index: Int,
            val bytes: Int,
            val min: Double,
            val max: Double,
            val positive: Long,
            val nonZero: Long,
            val nan: Long,
            val integerValued: Boolean,
        )

        private val mainHandler = Handler(Looper.getMainLooper())
        private val resultCompleted = AtomicBoolean(false)
        private val isTerminated = AtomicBoolean(false)
        private val inFlight = AtomicBoolean(false)
        private val framesCompleted = AtomicInteger(0)
        private val cameraUnbound = CountDownLatch(1)

        // Main-thread owned.
        private var cameraProvider: ProcessCameraProvider? = null

        // GPU-thread owned. Touched only from gpuExecutor tasks.
        private var modelBuffer: ByteBuffer? = null
        private var gpuDelegate: GpuDelegate? = null
        private var interpreter: Interpreter? = null
        private var inputBuffer: ByteBuffer? = null
        private var inputShape: IntArray = IntArray(0)
        private var inputType: DataType = DataType.FLOAT32
        private var inputWidth = 0
        private var inputHeight = 0
        private var pixelScratch: IntArray = IntArray(0)
        private var outputSpecs: List<OutputSpec> = emptyList()
        private var firstFrameStats: List<OutputStats> = emptyList()
        private var lastFrameStats: List<OutputStats> = emptyList()

        @Volatile
        private var gpuThread: Thread? = null

        private val gpuExecutor: ExecutorService = Executors.newSingleThreadExecutor { r ->
            Thread(r, TFLITE_GPU_THREAD_NAME).apply {
                isDaemon = true
                gpuThread = this
            }
        }
        private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor { r ->
            Thread(r, "DuetTfliteGpuProbe-Analysis").apply { isDaemon = true }
        }

        private val timeoutRunnable = Runnable {
            handleFailure(
                "timeout",
                "Probe timed out after ${TFLITE_PROBE_TIMEOUT_MS}ms (frames=${framesCompleted.get()})",
                null,
            )
        }

        fun start() {
            mainHandler.postDelayed(timeoutRunnable, TFLITE_PROBE_TIMEOUT_MS)
            try {
                gpuExecutor.execute { initializeOnGpuThread() }
            } catch (e: RejectedExecutionException) {
                handleFailure("gpu_executor_rejected", "GPU executor rejected init task: ${e.message}", e)
            }
        }

        fun cancel() {
            handleFailure("cancelled", "Probe cancelled (Activity destroyed)", null)
        }

        // ── GPU thread: init ─────────────────────────────────────────────────

        private fun initializeOnGpuThread() {
            if (isTerminated.get()) return

            val delegateOptions = resolveDelegateOptions() ?: return
            if (isTerminated.get()) return

            val model: ByteBuffer
            try {
                model = loadModelIntoDirectBuffer()
            } catch (t: Throwable) {
                handleFailure(
                    "model_load_failed",
                    "Failed to load $MODEL_ASSET_PATH into a direct ByteBuffer: ${t.message}",
                    t,
                )
                return
            }
            modelBuffer = model

            val created: Interpreter
            try {
                val delegate = GpuDelegate(delegateOptions)
                gpuDelegate = delegate
                val options = Interpreter.Options()
                options.addDelegate(delegate)
                created = Interpreter(model, options)
                interpreter = created
                created.allocateTensors()
            } catch (t: Throwable) {
                handleFailure(
                    "interpreter_init_failed",
                    "Failed to create Interpreter with standalone GpuDelegate: ${t.message}",
                    t,
                )
                return
            }

            try {
                inspectAndAllocateTensors(created)
            } catch (t: Throwable) {
                handleFailure("tensor_layout_unsupported", "${t.message}", t)
                return
            }

            val readyLog = "ANDROID_DUET_TFLITE_GPU_INTERPRETER_READY" +
                " inputShape=${formatShape(inputShape)}" +
                " inputType=$inputType" +
                " outputShape=${outputSpecs.joinToString("|") { formatShape(it.shape) }}" +
                " outputType=${outputSpecs.joinToString("|") { it.type.toString() }}" +
                " outputCount=${outputSpecs.size}" +
                " inputBytes=${inputBuffer?.capacity() ?: 0}" +
                " outputBytes=${outputSpecs.joinToString("|") { it.expectedBytes.toString() }}"
            logTfliteGpu(readyLog)

            mainHandler.post {
                if (!isTerminated.get()) {
                    startCamera()
                }
            }
        }

        private fun resolveDelegateOptions(): GpuDelegateFactory.Options? {
            try {
                val compatibilityList = CompatibilityList()
                try {
                    val supported = compatibilityList.isDelegateSupportedOnThisDevice
                    var line = "ANDROID_DUET_TFLITE_GPU_COMPAT supported=$supported delegate=standalone"
                    if (!supported) {
                        logTfliteGpu(line)
                        handleFailure(
                            "gpu_delegate_unsupported",
                            "CompatibilityList reports the standalone GPU delegate is unsupported on this device",
                            null,
                        )
                        return null
                    }
                    val options = compatibilityList.bestOptionsForThisDevice
                    line += " precisionLossAllowed=${options.isPrecisionLossAllowed}" +
                        " inferencePreference=${options.inferencePreference}"
                    logTfliteGpu(line)
                    return options
                } finally {
                    try {
                        compatibilityList.close()
                    } catch (t: Throwable) {
                        Log.w(TFLITE_TAG, "CompatibilityList.close() threw: ${t.message}")
                    }
                }
            } catch (t: Throwable) {
                handleFailure(
                    "gpu_compat_check_failed",
                    "CompatibilityList check failed (native GPU library load or query): ${t.message}",
                    t,
                )
                return null
            }
        }

        private fun loadModelIntoDirectBuffer(): ByteBuffer {
            val bytes = activity.assets.open(MODEL_ASSET_PATH).use { it.readBytes() }
            if (bytes.size < 8) {
                throw IllegalStateException("model asset too small (${bytes.size} bytes)")
            }
            // TFLite flatbuffer file identifier "TFL3" lives at offset 4.
            val magic = String(bytes, 4, 4, Charsets.US_ASCII)
            if (magic != "TFL3") {
                throw IllegalStateException("model asset is not a TFL3 flatbuffer (identifier=$magic)")
            }
            val buffer = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder())
            buffer.put(bytes)
            buffer.rewind()
            return buffer
        }

        private fun inspectAndAllocateTensors(interp: Interpreter) {
            val inputCount = interp.inputTensorCount
            if (inputCount != 1) {
                throw IllegalStateException("Unsupported input tensor count=$inputCount (expected 1)")
            }
            val inTensor = interp.getInputTensor(0)
            val shape = inTensor.shape()
            val type = inTensor.dataType()
            if (shape.size != 4 || shape[0] != 1 || shape[3] != 3 || shape[1] <= 0 || shape[2] <= 0) {
                throw IllegalStateException(
                    "Unsupported input shape=${formatShape(shape)} (expected NHWC [1,h,w,3])",
                )
            }
            if (type != DataType.FLOAT32 && type != DataType.UINT8) {
                throw IllegalStateException("Unsupported input type=$type (expected FLOAT32 or UINT8)")
            }
            val expectedInputBytes = shape[1].toLong() * shape[2].toLong() * 3L * type.byteSize().toLong()
            if (expectedInputBytes <= 0L || expectedInputBytes > Int.MAX_VALUE.toLong()) {
                throw IllegalStateException("Input byte size out of range: $expectedInputBytes")
            }
            if (inTensor.numBytes().toLong() != expectedInputBytes) {
                throw IllegalStateException(
                    "Input tensor numBytes=${inTensor.numBytes()} != expected $expectedInputBytes",
                )
            }

            val outputCount = interp.outputTensorCount
            if (outputCount < 1) {
                throw IllegalStateException("Unsupported output tensor count=$outputCount (expected >= 1)")
            }
            val specs = ArrayList<OutputSpec>(outputCount)
            for (i in 0 until outputCount) {
                val outTensor = interp.getOutputTensor(i)
                val outShape = outTensor.shape()
                val outType = outTensor.dataType()
                if (outType != DataType.FLOAT32 && outType != DataType.UINT8 && outType != DataType.INT8) {
                    throw IllegalStateException(
                        "Unsupported output[$i] type=$outType (expected FLOAT32, UINT8 or INT8)",
                    )
                }
                if (outShape.isEmpty()) {
                    throw IllegalStateException("Unsupported output[$i] scalar/empty shape")
                }
                var elements = 1L
                for (dim in outShape) {
                    if (dim <= 0) {
                        throw IllegalStateException(
                            "Unsupported output[$i] shape=${formatShape(outShape)} (non-positive dim)",
                        )
                    }
                    elements *= dim.toLong()
                }
                val expected = elements * outType.byteSize().toLong()
                if (expected <= 0L || expected > Int.MAX_VALUE.toLong()) {
                    throw IllegalStateException("Output[$i] byte size out of range: $expected")
                }
                if (outTensor.numBytes().toLong() != expected) {
                    throw IllegalStateException(
                        "Output[$i] tensor numBytes=${outTensor.numBytes()} != expected $expected",
                    )
                }
                val buffer = ByteBuffer.allocateDirect(expected.toInt()).order(ByteOrder.nativeOrder())
                specs.add(OutputSpec(i, outShape, outType, expected.toInt(), buffer))
            }

            inputShape = shape
            inputType = type
            inputHeight = shape[1]
            inputWidth = shape[2]
            pixelScratch = IntArray(inputWidth * inputHeight)
            inputBuffer = ByteBuffer.allocateDirect(expectedInputBytes.toInt()).order(ByteOrder.nativeOrder())
            outputSpecs = specs
        }

        // ── Main thread: CameraX ─────────────────────────────────────────────

        private fun startCamera() {
            if (isTerminated.get()) return
            if (activity.isFinishing || activity.isDestroyed) {
                handleFailure("activity_unavailable", "Activity is finishing/destroyed before camera start", null)
                return
            }
            try {
                val cameraProviderFuture = ProcessCameraProvider.getInstance(activity)
                cameraProviderFuture.addListener({
                    if (isTerminated.get()) return@addListener
                    try {
                        val provider = cameraProviderFuture.get()
                        cameraProvider = provider

                        val imageAnalysis = ImageAnalysis.Builder()
                            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                            .build()
                        imageAnalysis.setAnalyzer(analysisExecutor) { proxy ->
                            handleImageProxy(proxy)
                        }

                        provider.unbindAll()
                        provider.bindToLifecycle(activity, CameraSelector.DEFAULT_FRONT_CAMERA, imageAnalysis)
                        logTfliteGpu("ANDROID_DUET_TFLITE_GPU_CAMERA_BOUND selector=front useCase=image_analysis preview=none")
                    } catch (t: Throwable) {
                        handleFailure("camerax_bind_failed", "CameraX bindToLifecycle failed: ${t.message}", t)
                    }
                }, ContextCompat.getMainExecutor(activity))
            } catch (t: Throwable) {
                handleFailure("camerax_init_failed", "CameraX getInstance failed: ${t.message}", t)
            }
        }

        private fun postCameraUnbind() {
            mainHandler.post {
                try {
                    cameraProvider?.unbindAll()
                } catch (t: Throwable) {
                    Log.w(TFLITE_TAG, "Failed to unbind camera: ${t.message}")
                } finally {
                    cameraProvider = null
                    cameraUnbound.countDown()
                }
            }
        }

        // ── Analysis thread ──────────────────────────────────────────────────

        private fun handleImageProxy(proxy: ImageProxy) {
            if (isTerminated.get() || framesCompleted.get() >= TARGET_FRAMES) {
                proxy.close()
                return
            }
            if (!inFlight.compareAndSet(false, true)) {
                // GPU thread still busy with the previous frame: drop this one.
                proxy.close()
                return
            }

            val bitmap: Bitmap
            val timestampMs: Long
            try {
                timestampMs = proxy.imageInfo.timestamp / 1_000_000L
                bitmap = imageProxyToUprightBitmap(proxy)
            } catch (t: Throwable) {
                inFlight.set(false)
                Log.w(TFLITE_TAG, "Frame bitmap conversion failed: ${t.message}")
                return
            } finally {
                proxy.close()
            }

            try {
                gpuExecutor.execute {
                    try {
                        if (isTerminated.get()) {
                            return@execute
                        }
                        processFrameOnGpu(bitmap, timestampMs)
                    } catch (t: Throwable) {
                        handleFailure(
                            "gpu_inference_failed",
                            "GPU inference error at frame ${framesCompleted.get() + 1}: ${t.message}",
                            t,
                        )
                    } finally {
                        recycleQuietly(bitmap)
                        inFlight.set(false)
                    }
                }
            } catch (e: RejectedExecutionException) {
                recycleQuietly(bitmap)
                inFlight.set(false)
            }
        }

        // ── GPU thread: inference ────────────────────────────────────────────

        private fun processFrameOnGpu(source: Bitmap, timestampMs: Long) {
            val interp = interpreter ?: throw IllegalStateException("Interpreter is null on GPU thread")
            val input = inputBuffer ?: throw IllegalStateException("Input buffer missing on GPU thread")
            if (outputSpecs.isEmpty()) throw IllegalStateException("Output specs missing on GPU thread")

            fillInputFromBitmap(source, input)

            val outputs = HashMap<Int, Any>(outputSpecs.size)
            for (spec in outputSpecs) {
                spec.buffer.rewind()
                outputs[spec.index] = spec.buffer
            }
            interp.runForMultipleInputsOutputs(arrayOf<Any>(input), outputs)

            val stats = ArrayList<OutputStats>(outputSpecs.size)
            for (spec in outputSpecs) {
                val liveBytes = interp.getOutputTensor(spec.index).numBytes()
                if (liveBytes != spec.expectedBytes || spec.buffer.capacity() != spec.expectedBytes) {
                    throw IllegalStateException(
                        "Output[${spec.index}] byte capacity mismatch: tensor=$liveBytes buffer=${spec.buffer.capacity()} expected=${spec.expectedBytes}",
                    )
                }
                stats.add(computeStats(spec))
            }

            val count = framesCompleted.incrementAndGet()
            lastFrameStats = stats

            if (count == 1) {
                firstFrameStats = stats
                logTfliteGpu(
                    "ANDROID_DUET_TFLITE_GPU_FIRST frames=1 ${formatPrimaryStats(stats)}" +
                        " timestampMs=$timestampMs${formatExtraOutputs(stats)}",
                )
            }
            if (count % 5 == 0 || count == TARGET_FRAMES) {
                logTfliteGpu("ANDROID_DUET_TFLITE_GPU_PROGRESS frames=$count")
            }
            if (count >= TARGET_FRAMES) {
                handlePass()
            }
        }

        private fun fillInputFromBitmap(source: Bitmap, input: ByteBuffer) {
            var scaled: Bitmap? = null
            try {
                scaled = if (source.width == inputWidth && source.height == inputHeight) {
                    source
                } else {
                    Bitmap.createScaledBitmap(source, inputWidth, inputHeight, true)
                }
                scaled.getPixels(pixelScratch, 0, inputWidth, 0, 0, inputWidth, inputHeight)
            } finally {
                if (scaled != null && scaled !== source) {
                    recycleQuietly(scaled)
                }
            }

            input.rewind()
            if (inputType == DataType.FLOAT32) {
                for (argb in pixelScratch) {
                    input.putFloat(((argb shr 16) and 0xFF) / 255f)
                    input.putFloat(((argb shr 8) and 0xFF) / 255f)
                    input.putFloat((argb and 0xFF) / 255f)
                }
            } else {
                for (argb in pixelScratch) {
                    input.put(((argb shr 16) and 0xFF).toByte())
                    input.put(((argb shr 8) and 0xFF).toByte())
                    input.put((argb and 0xFF).toByte())
                }
            }
            input.rewind()
        }

        private fun computeStats(spec: OutputSpec): OutputStats {
            val buf = spec.buffer
            buf.rewind()
            var min = Double.POSITIVE_INFINITY
            var max = Double.NEGATIVE_INFINITY
            var positive = 0L
            var nonZero = 0L
            var nan = 0L
            when (spec.type) {
                DataType.FLOAT32 -> {
                    val floats = buf.asFloatBuffer()
                    val n = spec.expectedBytes / 4
                    for (i in 0 until n) {
                        val v = floats.get(i).toDouble()
                        if (v.isNaN()) {
                            nan++
                            nonZero++
                            continue
                        }
                        if (v < min) min = v
                        if (v > max) max = v
                        if (v > 0.0) positive++
                        if (v != 0.0) nonZero++
                    }
                }
                DataType.UINT8 -> {
                    for (i in 0 until spec.expectedBytes) {
                        val v = (buf.get(i).toInt() and 0xFF).toDouble()
                        if (v < min) min = v
                        if (v > max) max = v
                        if (v > 0.0) positive++
                        if (v != 0.0) nonZero++
                    }
                }
                DataType.INT8 -> {
                    for (i in 0 until spec.expectedBytes) {
                        val v = buf.get(i).toInt().toDouble()
                        if (v < min) min = v
                        if (v > max) max = v
                        if (v > 0.0) positive++
                        if (v != 0.0) nonZero++
                    }
                }
                else -> throw IllegalStateException("Unsupported output[${spec.index}] type=${spec.type}")
            }
            buf.rewind()
            return OutputStats(
                index = spec.index,
                bytes = spec.expectedBytes,
                min = min,
                max = max,
                positive = positive,
                nonZero = nonZero,
                nan = nan,
                integerValued = spec.type != DataType.FLOAT32,
            )
        }

        // ── Terminal paths ───────────────────────────────────────────────────

        /** GPU thread only. Closes Interpreter before GpuDelegate. Returns the first Throwable, if any. */
        private fun closeTfliteOnGpuThread(): Throwable? {
            var error: Throwable? = null
            try {
                interpreter?.close()
            } catch (t: Throwable) {
                Log.w(TFLITE_TAG, "Interpreter.close() threw: ${t.message}")
                if (error == null) error = t
            }
            interpreter = null
            try {
                gpuDelegate?.close()
            } catch (t: Throwable) {
                Log.w(TFLITE_TAG, "GpuDelegate.close() threw: ${t.message}")
                if (error == null) error = t
            }
            gpuDelegate = null
            inputBuffer = null
            outputSpecs = emptyList()
            modelBuffer = null
            return error
        }

        private fun closeTfliteFromAnyThread() {
            if (Thread.currentThread() === gpuThread) {
                val error = closeTfliteOnGpuThread()
                logTfliteGpu("ANDROID_DUET_TFLITE_GPU_CLOSE_AFTER_FAIL ok=${error == null}")
                return
            }
            val latch = CountDownLatch(1)
            try {
                gpuExecutor.execute {
                    try {
                        val error = closeTfliteOnGpuThread()
                        logTfliteGpu("ANDROID_DUET_TFLITE_GPU_CLOSE_AFTER_FAIL ok=${error == null}")
                    } finally {
                        latch.countDown()
                    }
                }
                if (!latch.await(TFLITE_CLOSE_WAIT_MS, TimeUnit.MILLISECONDS)) {
                    Log.w(
                        TFLITE_TAG,
                        "TFLite close did not finish within ${TFLITE_CLOSE_WAIT_MS}ms; close task stays queued on the GPU thread",
                    )
                }
            } catch (e: RejectedExecutionException) {
                Log.w(TFLITE_TAG, "GPU executor rejected close task: ${e.message}")
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }

        /** GPU thread only (reached from processFrameOnGpu). */
        private fun handlePass() {
            if (!isTerminated.compareAndSet(false, true)) return
            mainHandler.removeCallbacks(timeoutRunnable)
            postCameraUnbind()

            val frames = framesCompleted.get()
            val passInputShape = inputShape
            val passInputType = inputType
            val passOutputShape = outputSpecs.joinToString("|") { formatShape(it.shape) }
            val passOutputs = outputSpecs.map { spec ->
                mapOf(
                    "index" to spec.index,
                    "shape" to spec.shape.toList(),
                    "type" to spec.type.toString(),
                    "bytes" to spec.expectedBytes,
                )
            }
            val first = firstFrameStats
            val last = lastFrameStats

            val closeError = closeTfliteOnGpuThread()
            if (closeError != null) {
                val message = "Interpreter/GpuDelegate close threw after $frames frames: ${closeError.message}"
                logTfliteGpuFail("close_failed", message, closeError)
                completeResult { it.error("close_failed", message, closeError.stackTraceToString()) }
            } else {
                logTfliteGpu("ANDROID_DUET_TFLITE_GPU_CLOSE_PASS")
                logTfliteGpu(
                    "ANDROID_DUET_TFLITE_GPU_PROBE_PASS frames=$frames" +
                        " inputShape=${formatShape(passInputShape)} inputType=$passInputType" +
                        " outputShape=$passOutputShape" +
                        " ${formatPrimaryStats(last)}${formatExtraOutputs(last)}",
                )
                val payload = mapOf(
                    "pass" to true,
                    "route" to "raw_tflite_interpreter_standalone_gpu_delegate",
                    "frames" to frames,
                    "inputShape" to passInputShape.toList(),
                    "inputType" to passInputType.toString(),
                    "outputs" to passOutputs,
                    "first" to first.map { statsToMap(it) },
                    "last" to last.map { statsToMap(it) },
                )
                completeResult { it.success(payload) }
            }
            finishSession()
        }

        /** Any thread. */
        fun handleFailure(code: String, message: String, throwable: Throwable?) {
            if (!isTerminated.compareAndSet(false, true)) return
            mainHandler.removeCallbacks(timeoutRunnable)
            logTfliteGpuFail(code, message, throwable)
            postCameraUnbind()
            closeTfliteFromAnyThread()
            completeResult { it.error(code, message, throwable?.stackTraceToString()) }
            finishSession()
        }

        private fun finishSession() {
            cleanupExecutors()
            mainHandler.post { onFinished(this) }
        }

        private fun completeResult(action: (MethodChannel.Result) -> Unit) {
            if (resultCompleted.compareAndSet(false, true)) {
                mainHandler.post {
                    try {
                        action(result)
                    } catch (t: Throwable) {
                        Log.e(TFLITE_TAG, "MethodChannel.Result completion failed: ${t.message}", t)
                    }
                }
            }
        }

        private fun cleanupExecutors() {
            Thread({
                try {
                    cameraUnbound.await(2, TimeUnit.SECONDS)
                } catch (_: InterruptedException) {
                }
                try { analysisExecutor.shutdown() } catch (_: Throwable) {}
                try { gpuExecutor.shutdown() } catch (_: Throwable) {}
                try { analysisExecutor.awaitTermination(2, TimeUnit.SECONDS) } catch (_: Throwable) {}
                try { gpuExecutor.awaitTermination(2, TimeUnit.SECONDS) } catch (_: Throwable) {}
            }, "DuetTfliteGpuProbe-Shutdown").apply { isDaemon = true }.start()
        }

        // ── Formatting helpers ───────────────────────────────────────────────

        private fun formatShape(shape: IntArray): String = shape.joinToString(",", "[", "]")

        private fun formatValue(value: Double, integerValued: Boolean): String {
            if (value.isNaN() || value.isInfinite()) return value.toString()
            return if (integerValued) value.toLong().toString() else String.format(Locale.US, "%.6f", value)
        }

        private fun formatPrimaryStats(stats: List<OutputStats>): String {
            val s = stats.firstOrNull() ?: return "outputMin=NA outputMax=NA positive=0 nonZero=0"
            return "outputMin=${formatValue(s.min, s.integerValued)}" +
                " outputMax=${formatValue(s.max, s.integerValued)}" +
                " positive=${s.positive} nonZero=${s.nonZero} nan=${s.nan} bytes=${s.bytes}"
        }

        private fun formatExtraOutputs(stats: List<OutputStats>): String {
            if (stats.size <= 1) return ""
            return " outputs=" + stats.drop(1).joinToString(";") { s ->
                "{index=${s.index} min=${formatValue(s.min, s.integerValued)}" +
                    " max=${formatValue(s.max, s.integerValued)}" +
                    " positive=${s.positive} nonZero=${s.nonZero} nan=${s.nan} bytes=${s.bytes}}"
            }
        }

        private fun statsToMap(s: OutputStats): Map<String, Any> = mapOf(
            "index" to s.index,
            "bytes" to s.bytes,
            "min" to s.min,
            "max" to s.max,
            "positive" to s.positive,
            "nonZero" to s.nonZero,
            "nan" to s.nan,
        )

        private fun recycleQuietly(bitmap: Bitmap) {
            try {
                if (!bitmap.isRecycled) bitmap.recycle()
            } catch (_: Throwable) {
            }
        }
    }

    // ── Example-only OUT-OF-PROCESS forced raw TFLite GPU diagnostic probe ──
    //
    // Diagnostic evidence only. Does NOT enable anything in production and does
    // not touch the Duet ladder (mediapipe_cpu -> mlkit -> none); there is no
    // raw_tflite_gpu production tier.
    //
    // Why a child process:
    //   MediaPipe Tasks GPU SIGABRTs below the JVM on SM-A566B / Android 16, and
    //   the in-process raw TFLite probe above respects CompatibilityList
    //   (supported=false there) so it never invokes the GPU delegate. The only
    //   way to learn what a FORCED raw GPU delegate does on such a device is to
    //   run it where a vendor/native abort kills a disposable child process.
    //
    // Parent contract (this Activity, main Flutter process):
    //   * bindService(BIND_AUTO_CREATE) to TfliteGpuIsolatedProbeService, which
    //     the manifest places in android:process=":gpuprobe".
    //   * IBinder.DeathRecipient + ServiceConnection death callbacks convert a
    //     child crash into a NORMAL payload (code=child_process_died) instead of
    //     killing this process.
    //   * MethodChannel.Result completes exactly once, on the main thread.
    //   * The binding is released on success / failure / timeout / onDestroy.
    //   * Parent timeout is ISOLATED_PROBE_TIMEOUT_MS (<= 30 s); Dart waits 35 s.
    //   * After every terminal path the parent logs an ALIVE marker to prove it
    //     survived.
    private fun runTfliteGpuIsolatedProbe(call: MethodCall, result: MethodChannel.Result) {
        val isDebuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!isDebuggable) {
            logIsolatedFail("not_debuggable", "Probe rejected: app is not debuggable", null)
            result.error("NOT_DEBUGGABLE", "Probe rejected: app is not debuggable", null)
            return
        }

        val args = call.arguments as? Map<*, *>
        val requestedModelAssetPath = args?.get(ISOLATED_ARG_MODEL_ASSET_PATH) as? String
        val modelAssetPath: String
        if (requestedModelAssetPath == null) {
            modelAssetPath = ISOLATED_DEFAULT_MODEL_ASSET_PATH
        } else if (isValidIsolatedModelAssetPath(requestedModelAssetPath)) {
            modelAssetPath = requestedModelAssetPath
        } else {
            val message = "modelAssetPath failed validation: $requestedModelAssetPath"
            logIsolatedFail("invalid_model_asset_path", message, null)
            result.error("invalid_model_asset_path", message, null)
            return
        }

        val requestedDelegateMode = args?.get(ISOLATED_ARG_DELEGATE_MODE) as? String
        val delegateMode: String
        if (requestedDelegateMode == null) {
            delegateMode = ISOLATED_DEFAULT_DELEGATE_MODE
        } else if (isValidIsolatedDelegateMode(requestedDelegateMode)) {
            delegateMode = requestedDelegateMode
        } else {
            val message = "delegateMode failed validation: $requestedDelegateMode" +
                " (expected one of $ISOLATED_VALID_DELEGATE_MODES)"
            logIsolatedFail("invalid_delegate_mode", message, null)
            result.error("invalid_delegate_mode", message, null)
            return
        }

        val repeatCountArgPresent = args?.containsKey(ISOLATED_ARG_REPEAT_COUNT) == true
        val requestedRepeatCount = args?.get(ISOLATED_ARG_REPEAT_COUNT) as? Number
        val repeatCount: Int
        if (!repeatCountArgPresent) {
            repeatCount = ISOLATED_DEFAULT_REPEAT_COUNT
        } else if (requestedRepeatCount != null && requestedRepeatCount.toInt() in 1..ISOLATED_MAX_REPEAT_COUNT) {
            repeatCount = requestedRepeatCount.toInt()
        } else {
            val message = "repeatCount failed validation (expected Number in 1..$ISOLATED_MAX_REPEAT_COUNT): " +
                "${args?.get(ISOLATED_ARG_REPEAT_COUNT)}"
            logIsolatedFail("invalid_repeat_count", message, null)
            result.error("invalid_repeat_count", message, null)
            return
        }

        if (activeSession != null || activeTfliteGpuSession != null || activeTfliteGpuIsolatedSession != null) {
            logIsolatedFail("probe_already_running", "Another example probe is already running", null)
            result.error("PROBE_ALREADY_RUNNING", "Another example probe is already running", null)
            return
        }

        logIsolated(
            "ANDROID_DUET_TFLITE_GPU_ISOLATED_PARENT_START parentPid=${Process.myPid()}" +
                " parentProcess=${TfliteGpuIsolatedProbeService.currentProcessName()}" +
                " service=${TfliteGpuIsolatedProbeService::class.java.name}" +
                " childProcessSuffix=:gpuprobe timeoutMs=$ISOLATED_PROBE_TIMEOUT_MS model=$modelAssetPath" +
                " delegateMode=$delegateMode repeatCount=$repeatCount",
        )

        val session = TfliteGpuIsolatedProbeSession(this, result, modelAssetPath, delegateMode, repeatCount) { finished ->
            if (activeTfliteGpuIsolatedSession === finished) {
                activeTfliteGpuIsolatedSession = null
            }
        }
        activeTfliteGpuIsolatedSession = session
        session.start()
    }

    private class TfliteGpuIsolatedProbeSession(
        private val activity: MainActivity,
        private val result: MethodChannel.Result,
        private val modelAssetPath: String,
        private val delegateMode: String,
        private val repeatCount: Int,
        private val onFinished: (TfliteGpuIsolatedProbeSession) -> Unit,
    ) {
        private val mainHandler = Handler(Looper.getMainLooper())
        private val resultCompleted = AtomicBoolean(false)
        private val isTerminated = AtomicBoolean(false)
        private val startedAt = SystemClock.elapsedRealtime()
        private val parentPid = Process.myPid()

        // Main-thread owned binding state.
        private var bound = false
        private var serviceBinder: IBinder? = null
        private var deathLinked = false
        private var connectedOnce = false

        @Volatile
        private var childPid = -1

        @Volatile
        private var childProcess: String? = null

        @Volatile
        private var childStarted = false

        /** Invoked on a binder thread when the :gpuprobe process dies. */
        private val deathRecipient = IBinder.DeathRecipient { handleChildDeath("binderDied") }

        /** Receives child messages on the main thread. */
        private val replyMessenger = Messenger(
            Handler(
                Looper.getMainLooper(),
                Handler.Callback { msg ->
                    handleChildMessage(msg)
                    true
                },
            ),
        )

        private val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                onConnected(service)
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                handleChildDeath("onServiceDisconnected")
            }

            override fun onBindingDied(name: ComponentName?) {
                handleChildDeath("onBindingDied")
            }

            override fun onNullBinding(name: ComponentName?) {
                handleFailure("null_binding", "Service returned a null binder from onBind", null)
            }
        }

        private val timeoutRunnable = Runnable { handleTimeout() }

        /** Main thread. */
        fun start() {
            mainHandler.postDelayed(timeoutRunnable, ISOLATED_PROBE_TIMEOUT_MS)
            val intent = Intent(activity, TfliteGpuIsolatedProbeService::class.java)
            val accepted: Boolean
            try {
                accepted = activity.bindService(intent, connection, Context.BIND_AUTO_CREATE)
                // Context.bindService: the connection must be released with
                // unbindService even when bindService returns false.
                bound = true
            } catch (t: Throwable) {
                handleFailure("bind_failed", "bindService threw: ${t.javaClass.simpleName}: ${t.message}", t)
                return
            }
            if (!accepted) {
                handleFailure("bind_failed", "bindService returned false (service unavailable or not permitted)", null)
                return
            }
            logIsolated("ANDROID_DUET_TFLITE_GPU_ISOLATED_PARENT_BIND_REQUESTED parentPid=$parentPid flags=BIND_AUTO_CREATE")
        }

        /** Main thread (Activity.onDestroy). */
        fun cancel() {
            handleFailure("cancelled", "Probe cancelled (Activity destroyed)", null)
        }

        // ── Main thread: ServiceConnection ──────────────────────────────────

        private fun onConnected(binder: IBinder?) {
            if (isTerminated.get()) {
                Log.w(ISOLATED_TAG, "onServiceConnected after termination; ignoring")
                return
            }
            if (binder == null) {
                handleFailure("null_binding", "onServiceConnected delivered a null binder", null)
                return
            }
            if (connectedOnce) {
                // The system re-created the child (BIND_AUTO_CREATE) after it
                // died, and no death callback reached us first. Treat as death.
                handleChildDeath("reconnect_after_death")
                return
            }
            connectedOnce = true
            serviceBinder = binder
            try {
                binder.linkToDeath(deathRecipient, 0)
                deathLinked = true
            } catch (e: RemoteException) {
                handleChildDeath("linkToDeath")
                return
            }
            logIsolated(
                "ANDROID_DUET_TFLITE_GPU_ISOLATED_PARENT_CONNECTED parentPid=$parentPid" +
                    " binderAlive=${binder.isBinderAlive} deathLinked=true elapsedMs=${elapsedMs()}",
            )

            val command = Message.obtain(null, TfliteGpuIsolatedProbeService.MSG_RUN_PROBE)
            command.replyTo = replyMessenger
            command.data = Bundle().apply {
                putString(TfliteGpuIsolatedProbeService.KEY_MODEL_ASSET_PATH, modelAssetPath)
                putString(TfliteGpuIsolatedProbeService.KEY_DELEGATE_MODE, delegateMode)
                putInt(TfliteGpuIsolatedProbeService.KEY_REPEAT_COUNT, repeatCount)
            }
            try {
                Messenger(binder).send(command)
                logIsolated(
                    "ANDROID_DUET_TFLITE_GPU_ISOLATED_PARENT_COMMAND_SENT what=MSG_RUN_PROBE model=$modelAssetPath" +
                        " delegateMode=$delegateMode repeatCount=$repeatCount",
                )
            } catch (e: DeadObjectException) {
                handleChildDeath("send_dead_object")
            } catch (e: RemoteException) {
                handleFailure("command_send_failed", "Messenger.send(MSG_RUN_PROBE) failed: ${e.message}", e)
            }
        }

        // ── Main thread: child messages ─────────────────────────────────────

        private fun handleChildMessage(msg: Message) {
            when (msg.what) {
                TfliteGpuIsolatedProbeService.MSG_PROBE_STARTED -> {
                    childPid = msg.arg1
                    childProcess = msg.data.getString(TfliteGpuIsolatedProbeService.KEY_PROCESS_NAME)
                    childStarted = true
                    logIsolated(
                        "ANDROID_DUET_TFLITE_GPU_ISOLATED_PARENT_CHILD_STARTED childPid=$childPid" +
                            " childProcess=$childProcess parentPid=$parentPid elapsedMs=${elapsedMs()}",
                    )
                }
                TfliteGpuIsolatedProbeService.MSG_PROBE_RESULT -> {
                    if (isTerminated.get()) {
                        Log.w(ISOLATED_TAG, "Late child result ignored (session already terminated)")
                        return
                    }
                    val jsonText = msg.data.getString(TfliteGpuIsolatedProbeService.KEY_RESULT_JSON)
                    if (jsonText == null) {
                        handleFailure("child_reply_invalid", "MSG_PROBE_RESULT carried no result JSON", null)
                        return
                    }
                    val child: Map<String, Any?>
                    try {
                        child = TfliteGpuIsolatedProbeService.jsonToCodecMap(jsonText)
                    } catch (t: Throwable) {
                        handleFailure("child_reply_invalid", "Failed to parse child result JSON: ${t.message}", t)
                        return
                    }
                    handleChildReply(child)
                }
                else -> Log.w(ISOLATED_TAG, "Ignoring unknown child message what=${msg.what}")
            }
        }

        private fun handleChildReply(child: Map<String, Any?>) {
            if (!isTerminated.compareAndSet(false, true)) return
            val childPass = child["pass"] == true
            val childCode = (child["code"] as? String) ?: "unknown"
            val childMessage = (child["message"] as? String) ?: ""
            val nonZeroTotal = (child["outputNonZeroTotal"] as? Number)?.toLong() ?: 0L
            val reportedChildPid = (child["childPid"] as? Number)?.toInt() ?: childPid
            val gpuCompleted = childPass && nonZeroTotal > 0L
            val mode = if (gpuCompleted) ISOLATED_MODE_FORCED_GPU_COMPLETED else ISOLATED_MODE_CHILD_PROBE_FAILED
            val code = when {
                gpuCompleted -> "ok"
                childPass -> "zero_output_coverage"
                else -> childCode
            }
            logIsolated(
                "ANDROID_DUET_TFLITE_GPU_ISOLATED_PARENT_CHILD_REPLY mode=$mode code=$code" +
                    " childPass=$childPass outputNonZeroTotal=$nonZeroTotal childPid=$reportedChildPid" +
                    " delegateMode=$delegateMode repeatCount=$repeatCount" +
                    " compatSupported=${(child["compat"] as? Map<*, *>)?.get("supported")} bypass=true" +
                    " elapsedMs=${elapsedMs()}",
            )

            val payload = LinkedHashMap<String, Any?>()
            payload["pass"] = gpuCompleted
            payload["mode"] = mode
            payload["code"] = code
            payload["message"] = childMessage
            payload["route"] = TfliteGpuIsolatedProbeService.ROUTE
            payload["parentPid"] = parentPid
            payload["childPid"] = reportedChildPid
            payload["childProcess"] = childProcess ?: child["childProcess"]
            payload["childStarted"] = childStarted
            payload["childDied"] = false
            payload["delegateMode"] = delegateMode
            payload["repeatCount"] = repeatCount
            payload["parentAlive"] = true
            payload["parentAliveMarker"] = ISOLATED_ALIVE_AFTER_RESULT
            payload["elapsedMs"] = elapsedMs()
            payload["child"] = child
            finish(ISOLATED_ALIVE_AFTER_RESULT) { it.success(payload) }
        }

        // ── Any thread: terminal paths ──────────────────────────────────────

        private fun handleChildDeath(source: String) {
            if (!isTerminated.compareAndSet(false, true)) return
            val elapsed = elapsedMs()
            logIsolated(
                "ANDROID_DUET_TFLITE_GPU_ISOLATED_PARENT_CHILD_DIED source=$source childPid=$childPid" +
                    " childProcess=$childProcess childStarted=$childStarted parentPid=$parentPid" +
                    " delegateMode=$delegateMode repeatCount=$repeatCount" +
                    " thread=${Thread.currentThread().name} elapsedMs=$elapsed",
            )
            val message = "Child process :gpuprobe died before replying (source=$source," +
                " childStarted=$childStarted); parent observed binder death and survived"

            val payload = LinkedHashMap<String, Any?>()
            payload["pass"] = false
            payload["mode"] = ISOLATED_MODE_CHILD_DIED
            payload["code"] = "child_process_died"
            payload["message"] = message
            payload["route"] = TfliteGpuIsolatedProbeService.ROUTE
            payload["parentPid"] = parentPid
            payload["childPid"] = childPid
            payload["childProcess"] = childProcess
            payload["childStarted"] = childStarted
            payload["childDied"] = true
            payload["deathSource"] = source
            payload["delegateMode"] = delegateMode
            payload["repeatCount"] = repeatCount
            payload["parentAlive"] = true
            payload["parentAliveMarker"] = ISOLATED_ALIVE_AFTER_CHILD_DEATH
            payload["elapsedMs"] = elapsed
            payload["child"] = null
            finish(ISOLATED_ALIVE_AFTER_CHILD_DEATH) { it.success(payload) }
        }

        private fun handleTimeout() {
            if (!isTerminated.compareAndSet(false, true)) return
            val message = "Parent timed out after ${ISOLATED_PROBE_TIMEOUT_MS}ms with neither child reply nor" +
                " child death (childStarted=$childStarted childPid=$childPid)"
            logIsolatedFail("timeout", message, null)
            finish(ISOLATED_ALIVE_AFTER_CHILD_DEATH) {
                it.error("timeout", message, detailsMap(ISOLATED_MODE_TIMEOUT, null))
            }
        }

        private fun handleFailure(code: String, message: String, throwable: Throwable?) {
            if (!isTerminated.compareAndSet(false, true)) return
            logIsolatedFail(code, message, throwable)
            finish(ISOLATED_ALIVE_AFTER_CHILD_DEATH) {
                it.error(code, message, detailsMap(ISOLATED_MODE_PARENT_FAILED, throwable))
            }
        }

        private fun detailsMap(mode: String, throwable: Throwable?): Map<String, Any?> = mapOf(
            "mode" to mode,
            "route" to TfliteGpuIsolatedProbeService.ROUTE,
            "parentPid" to parentPid,
            "childPid" to childPid,
            "childProcess" to childProcess,
            "childStarted" to childStarted,
            "delegateMode" to delegateMode,
            "repeatCount" to repeatCount,
            "parentAlive" to true,
            "parentAliveMarker" to ISOLATED_ALIVE_AFTER_CHILD_DEATH,
            "elapsedMs" to elapsedMs(),
            "stack" to throwable?.stackTraceToString(),
        )

        /**
         * Runs the terminal sequence on the main thread: cancel timeout, release
         * the binding, log the alive-proof marker, complete the result once.
         */
        private fun finish(aliveMarker: String, action: (MethodChannel.Result) -> Unit) {
            val runnable = Runnable {
                mainHandler.removeCallbacks(timeoutRunnable)
                releaseBinding()
                logIsolated(
                    "$aliveMarker parentPid=$parentPid" +
                        " mainThread=${Looper.myLooper() == Looper.getMainLooper()}" +
                        " childPid=$childPid elapsedMs=${elapsedMs()}",
                )
                completeResult(action)
                onFinished(this@TfliteGpuIsolatedProbeSession)
            }
            if (Looper.myLooper() == Looper.getMainLooper()) {
                runnable.run()
            } else {
                mainHandler.post(runnable)
            }
        }

        /** Main thread only. */
        private fun releaseBinding() {
            val binder = serviceBinder
            if (binder != null && deathLinked) {
                try {
                    binder.unlinkToDeath(deathRecipient, 0)
                } catch (t: Throwable) {
                    Log.w(ISOLATED_TAG, "unlinkToDeath threw (child already dead?): ${t.message}")
                }
            }
            deathLinked = false
            serviceBinder = null
            if (bound) {
                bound = false
                try {
                    activity.unbindService(connection)
                    logIsolated("ANDROID_DUET_TFLITE_GPU_ISOLATED_PARENT_UNBOUND parentPid=$parentPid")
                } catch (t: Throwable) {
                    Log.w(ISOLATED_TAG, "unbindService threw: ${t.message}")
                }
            }
        }

        /** Main thread only. */
        private fun completeResult(action: (MethodChannel.Result) -> Unit) {
            if (resultCompleted.compareAndSet(false, true)) {
                try {
                    action(result)
                } catch (t: Throwable) {
                    Log.e(ISOLATED_TAG, "MethodChannel.Result completion failed: ${t.message}", t)
                }
            }
        }

        private fun elapsedMs(): Long = SystemClock.elapsedRealtime() - startedAt
    }
}

/** Copies an ImageProxy into an upright Bitmap (rotation applied). Caller closes the proxy. */
private fun imageProxyToUprightBitmap(proxy: ImageProxy): Bitmap {
    val raw = proxy.toBitmap()
    val rotation = proxy.imageInfo.rotationDegrees
    if (rotation % 360 == 0) return raw
    val matrix = Matrix().apply { postRotate(rotation.toFloat()) }
    val rotated = Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, matrix, true)
    if (rotated !== raw) {
        try {
            raw.recycle()
        } catch (_: Throwable) {
        }
    }
    return rotated
}
