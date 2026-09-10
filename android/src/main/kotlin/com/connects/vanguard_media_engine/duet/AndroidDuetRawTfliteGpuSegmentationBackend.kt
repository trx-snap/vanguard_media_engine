package com.connects.vanguard_media_engine.duet

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.SystemClock
import android.util.Log
import androidx.camera.core.ImageProxy
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.CompatibilityList
import org.tensorflow.lite.gpu.GpuDelegate
import org.tensorflow.lite.gpu.GpuDelegateFactory
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Standalone raw TensorFlow Lite GPU delegate backend.
// -----------------------------------------------------------------------------
//
// Backend ID: `raw_tflite_gpu` (DuetSegmentationBackend.RAW_TFLITE_GPU).
// This backend is NOT the default production primary. It is opt-in only, via
// `debugSegmentationBackend = "raw_tflite_gpu"` in the session layoutConfigMap,
// exercised exclusively by the dedicated physical smoke harness.
//
// On open failure or inference failure this backend degrades to mediapipe_cpu
// via the existing adapter/selector ladder (raw_tflite_gpu -> mediapipe_cpu ->
// mlkit -> none/PiP). Default production ladder is unchanged.
//
// Model: configurable via modelAssetPath (default selfie_multiclass_256x256.tflite)
//   Default input  tensor: [1, 256, 256, 3] float32, RGB normalized [0, 1]
//   Default output tensor: [1, 256, 256, 6] float32, class 0 = background
//   Person alpha:  (1.0f - output[class=0]).coerceIn(0f, 1f) -> uint8 [0,255]
//   Single-channel models: alpha = value.coerceIn(0,1)*255 (SINGLE_CHANNEL_MASK mode)
//
// Threading: one owned single-thread executor for all lifecycle work. GpuDelegate
// contexts require single-thread affinity; this satisfies that requirement.
// open() blocks the caller (analysis thread) until ready or failed.
// segment() posts to the worker thread and fires completion exactly once.
// close() is idempotent, never throws, closes Interpreter before GpuDelegate.

private const val TAG                 = "DuetRawTfliteGpu"
private const val DEFAULT_MODEL_ASSET = "selfie_multiclass_256x256.tflite"
private const val BACKGROUND_CLASS_IDX = 0
private const val CLOSE_TIMEOUT_MS    = 2_000L

// Debug-only allowlist for the GPU delegate mode. Invalid values supplied via
// layoutConfigMap["debugRawTfliteGpuDelegateMode"] fall back to the default
// and are validated/warned in AndroidDuetSessionCoordinator.
private val DELEGATE_MODE_ALLOWLIST = setOf(
    "compat_best_or_default",
    "forced_default",
    "sustained_speed",
    "force_opencl",
    "force_opengl",
)

/**
 * How to interpret the float32 output per pixel.
 *
 * SINGLE_CHANNEL_MASK: output has 1 channel; alpha = value.coerceIn(0,1)*255.
 * MULTICLASS_BG_ZERO:  output has >1 channels; alpha = (1 - bgClass0).coerceIn(0,1)*255.
 *                      This is the default for selfie_multiclass_256x256.tflite (6 classes).
 */
private enum class OutputMode {
    SINGLE_CHANNEL_MASK,
    MULTICLASS_BG_ZERO,
}

/**
 * Owned-thread-only tensor metadata inspected after allocateTensors().
 * Private to this file; cleared on close. No new file needed.
 */
private data class TensorConfig(
    val inputWidth:     Int,
    val inputHeight:    Int,
    val inputChannels:  Int = 3,
    val outputWidth:    Int,
    val outputHeight:   Int,
    val outputChannels: Int,
    val outputMode:     OutputMode,
)

class AndroidDuetRawTfliteGpuSegmentationBackend(
    private val context: Context,
    /**
     * Internal debug-only delegate mode, validated against [DELEGATE_MODE_ALLOWLIST].
     * Controls how [GpuDelegateFactory.Options] are constructed in [initOnOwnedThread].
     * Default: `"compat_best_or_default"` — same as production behaviour.
     * Do NOT use to promote raw_tflite_gpu to the production ladder.
     */
    private val delegateMode: String = "compat_best_or_default",
    /**
     * Asset-relative path of the TFLite model to load.
     * Must be a member of [AndroidDuetSegmentationBackendSelector.RAW_TFLITE_GPU_MODEL_ALLOWLIST].
     * Default: [DEFAULT_MODEL_ASSET] ("selfie_multiclass_256x256.tflite").
     */
    private val modelAssetPath: String = DEFAULT_MODEL_ASSET,
) : AndroidDuetSegmentationBackend {

    override val backendId: String get() = DuetSegmentationBackend.RAW_TFLITE_GPU

    private val closed          = AtomicBoolean(false)
    private var loggedFirstMask = false

    /** Owned-thread-only phase-latency telemetry; diagnostic only, never affects results. */
    private val phaseTelemetry = AndroidDuetRawTfliteGpuPhaseTelemetry()

    /** Owned single-thread executor; created in open(). */
    @Volatile private var executor: ExecutorService? = null

    /** The backing thread, captured for same-thread close() detection. */
    @Volatile private var ownedThread: Thread? = null

    // ── Owned-thread-only state (never touched from other threads) ────────────

    private var gpuDelegate:  GpuDelegate?  = null
    private var interpreter:  Interpreter?  = null
    private var inputBuffer:  ByteBuffer?   = null
    private var outputBuffer: ByteBuffer?   = null

    /**
     * Populated by [initOnOwnedThread] after tensor inspection; cleared in
     * [closeOwnedResourcesQuietly]. All segment work reads this; if null the
     * backend was never successfully initialised or has been closed.
     */
    private var tensorConfig: TensorConfig? = null

    // ── AndroidDuetSegmentationBackend ────────────────────────────────────────

    override fun open() {
        check(!closed.get()) { "raw_tflite_gpu backend already closed" }
        check(executor == null) { "raw_tflite_gpu backend already opened" }

        val exec = Executors.newSingleThreadExecutor { r ->
            Thread(r, "DuetRawTfliteGpu").also { ownedThread = it }.apply { isDaemon = true }
        }
        executor = exec

        val latch = CountDownLatch(1)
        var initError: Throwable? = null

        exec.execute {
            try {
                initOnOwnedThread()
            } catch (t: Throwable) {
                initError = t
                closeOwnedResourcesQuietly()
            } finally {
                latch.countDown()
            }
        }

        latch.await()

        val err = initError
        if (err != null) {
            shutdownExecutorQuietly(exec)
            throw IllegalStateException(
                "raw_tflite_gpu backend failed to open: ${err.message}", err,
            )
        }
        if (closed.get()) {
            shutdownExecutorQuietly(exec)
            throw IllegalStateException("raw_tflite_gpu backend closed during open()")
        }
    }

    override fun segment(
        proxy: ImageProxy,
        timestampMs: Long,
        completion: (DuetSegmentationOutcome) -> Unit,
    ) {
        if (closed.get()) {
            completion(DuetSegmentationOutcome.Skipped("raw_tflite_gpu_closed"))
            return
        }
        val exec = executor
        if (exec == null) {
            completion(DuetSegmentationOutcome.Skipped("raw_tflite_gpu_closed"))
            return
        }
        try {
            exec.execute {
                try {
                    segmentOnOwnedThread(proxy, timestampMs, completion)
                } catch (t: Throwable) {
                    completion(
                        DuetSegmentationOutcome.Failure(
                            DuetSegmentationFailureReason.inferenceFailed(backendId),
                            "raw_tflite_gpu segment task failed: ${t.javaClass.simpleName}: ${t.message}",
                            t,
                        )
                    )
                }
            }
        } catch (t: RejectedExecutionException) {
            if (closed.get()) {
                completion(DuetSegmentationOutcome.Skipped("raw_tflite_gpu_closed"))
            } else {
                completion(
                    DuetSegmentationOutcome.Failure(
                        DuetSegmentationFailureReason.inferenceFailed(backendId),
                        "segment() executor rejected task: ${t.message}",
                        t,
                    )
                )
            }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val exec = executor ?: return

        if (Thread.currentThread() === ownedThread) {
            // Same-thread call (e.g. from inside a segment() completion during
            // handleBackendFailure). Close inline to avoid deadlock.
            closeOwnedResourcesQuietly()
            exec.shutdown()
            Log.d(TAG, "ANDROID_DUET_RAW_TFLITE_GPU_CLOSE_PASS (inline same-thread)")
            return
        }

        val latch = CountDownLatch(1)
        try {
            exec.execute {
                closeOwnedResourcesQuietly()
                latch.countDown()
            }
        } catch (t: RejectedExecutionException) {
            latch.countDown()
        }

        val closedInTime = try {
            latch.await(CLOSE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!closedInTime) {
            Log.w(TAG, "close() timed out after ${CLOSE_TIMEOUT_MS}ms; forcing executor shutdown")
            exec.shutdownNow()
        } else {
            exec.shutdown()
        }
        Log.d(TAG, "ANDROID_DUET_RAW_TFLITE_GPU_CLOSE_PASS")
    }

    // ── Owned-thread: init ────────────────────────────────────────────────────

    private fun initOnOwnedThread() {
        // 1. Load model bytes into a direct native-order ByteBuffer.
        val modelBytes = loadModelBytes()

        // 2. Verify TFL3 magic (first byte of a valid .tflite FlatBuffer).
        //    A valid TFLite FlatBuffer's first 4 bytes encode the root table offset
        //    (little-endian int). The flatbuffer identifier at bytes [4..7] is "TFL3".
        //    We guard on a non-empty buffer as a minimal sanity check; a deeper
        //    magic check would require reading the identifier field from the buffer.
        if (modelBytes.capacity() < 8) {
            throw IllegalStateException("Model too small (${modelBytes.capacity()} bytes) — not a valid .tflite")
        }
        // Verify FlatBuffer identifier "TFL3" at offset 4.
        val id0 = modelBytes.get(4)
        val id1 = modelBytes.get(5)
        val id2 = modelBytes.get(6)
        val id3 = modelBytes.get(7)
        val identOk = id0 == 'T'.code.toByte() &&
            id1 == 'F'.code.toByte() &&
            id2 == 'L'.code.toByte() &&
            id3 == '3'.code.toByte()
        if (!identOk) {
            throw IllegalStateException(
                "Model flatbuffer identifier mismatch: " +
                    "${id0.toInt().toChar()}${id1.toInt().toChar()}" +
                    "${id2.toInt().toChar()}${id3.toInt().toChar()} (expected TFL3)"
            )
        }

        // 3. Build GpuDelegateFactory.Options by delegateMode, mirroring the
        //    verified pattern from TfliteGpuIsolatedProbeService.
        //    CompatibilityList is queried once then closed; bestDelegateOptions is
        //    used only for compat_best_or_default when the device is supported.
        var bestDelegateOptions: GpuDelegateFactory.Options? = null
        var compatSupported: Boolean? = null
        try {
            val compatibilityList = CompatibilityList()
            try {
                val supported = compatibilityList.isDelegateSupportedOnThisDevice
                compatSupported = supported
                if (supported) {
                    try {
                        bestDelegateOptions = compatibilityList.bestOptionsForThisDevice
                    } catch (t: Throwable) {
                        Log.w(TAG, "CompatibilityList.bestOptionsForThisDevice threw: ${t.message}")
                    }
                }
            } finally {
                try { compatibilityList.close() } catch (t: Throwable) {
                    Log.w(TAG, "CompatibilityList.close() threw: ${t.message}")
                }
            }
        } catch (t: Throwable) {
            compatSupported = null
            Log.w(TAG, "CompatibilityList construction failed: ${t.javaClass.simpleName}: ${t.message}")
        }

        val gpuOptions: GpuDelegateFactory.Options
        val optionsSource: String
        when (delegateMode) {
            "compat_best_or_default" -> {
                if (bestDelegateOptions != null) {
                    gpuOptions = bestDelegateOptions
                    optionsSource = "compat_best_options"
                } else {
                    gpuOptions = GpuDelegateFactory.Options()
                    optionsSource = "compat_default_options"
                }
            }
            "forced_default" -> {
                gpuOptions = GpuDelegateFactory.Options()
                optionsSource = "forced_default_options"
            }
            "sustained_speed" -> {
                gpuOptions = GpuDelegateFactory.Options().apply {
                    setInferencePreference(GpuDelegateFactory.Options.INFERENCE_PREFERENCE_SUSTAINED_SPEED)
                }
                optionsSource = "sustained_speed_options"
            }
            "force_opencl" -> {
                gpuOptions = GpuDelegateFactory.Options().apply {
                    setForceBackend(GpuDelegateFactory.Options.GpuBackend.OPENCL)
                }
                optionsSource = "force_opencl_options"
            }
            "force_opengl" -> {
                gpuOptions = GpuDelegateFactory.Options().apply {
                    setForceBackend(GpuDelegateFactory.Options.GpuBackend.OPENGL)
                }
                optionsSource = "force_opengl_options"
            }
            else -> {
                // Should not reach here — coordinator validates against DELEGATE_MODE_ALLOWLIST
                // before constructing the backend. Defensive fallback.
                gpuOptions = GpuDelegateFactory.Options()
                optionsSource = "unknown_fallback_options"
                Log.w(TAG, "Unknown delegateMode='$delegateMode'; using default GpuDelegateFactory.Options")
            }
        }

        val gpuDel = GpuDelegate(gpuOptions)
        gpuDelegate = gpuDel

        // 4. Create Interpreter with GpuDelegate.
        val options = Interpreter.Options().apply {
            addDelegate(gpuDel)
        }
        val interp = Interpreter(modelBytes, options)
        interpreter = interp

        // 5. Allocate tensors.
        interp.allocateTensors()

        // 6. Validate input tensor count and shape dynamically.
        //    Must be exactly 1 input tensor, NHWC rank-4 [1, h, w, 3], float32 only.
        //    UINT8 input is rejected for the live GPU path in this slice.
        val inputTensorCount = interp.inputTensorCount
        if (inputTensorCount != 1) {
            throw IllegalStateException(
                "Expected 1 input tensor, got $inputTensorCount (model=$modelAssetPath)"
            )
        }
        val inputTensor = interp.getInputTensor(0)
        if (inputTensor.dataType() != org.tensorflow.lite.DataType.FLOAT32) {
            throw IllegalStateException(
                "Input tensor dtype must be FLOAT32 for the live GPU path; " +
                    "got ${inputTensor.dataType()} (model=$modelAssetPath). " +
                    "UINT8 models are not supported in this slice."
            )
        }
        val inputShape = inputTensor.shape()
        if (inputShape.size != 4 || inputShape[0] != 1 || inputShape[3] != 3) {
            throw IllegalStateException(
                "Input tensor must be NHWC rank-4 [1,h,w,3]; " +
                    "got ${inputShape.toList()} (model=$modelAssetPath)"
            )
        }
        val inputH = inputShape[1]
        val inputW = inputShape[2]
        if (inputH <= 0 || inputW <= 0) {
            throw IllegalStateException(
                "Input tensor has non-positive spatial dimensions: h=$inputH w=$inputW " +
                    "(model=$modelAssetPath)"
            )
        }

        // 7. Validate output tensor count and shape dynamically.
        //    Supported output shapes (all float32):
        //      [1, h, w, 1]   → SINGLE_CHANNEL_MASK (alpha = value)
        //      [1, h, w, C>1] → MULTICLASS_BG_ZERO  (alpha = 1 - class0)
        //      [1, h, w]      → implicit single channel → SINGLE_CHANNEL_MASK
        //    Non-positive dimensions and unsupported rank are rejected.
        val outputTensorCount = interp.outputTensorCount
        if (outputTensorCount != 1) {
            throw IllegalStateException(
                "Expected 1 output tensor, got $outputTensorCount (model=$modelAssetPath)"
            )
        }
        val outputTensor = interp.getOutputTensor(0)
        if (outputTensor.dataType() != org.tensorflow.lite.DataType.FLOAT32) {
            throw IllegalStateException(
                "Output tensor dtype must be FLOAT32; " +
                    "got ${outputTensor.dataType()} (model=$modelAssetPath)"
            )
        }
        val outputShape = outputTensor.shape()
        val outputH: Int
        val outputW: Int
        val outputC: Int
        val outputMode: OutputMode
        when (outputShape.size) {
            4 -> {
                // [1, h, w, C]
                if (outputShape[0] != 1) {
                    throw IllegalStateException(
                        "Output tensor batch dim must be 1; got ${outputShape.toList()} (model=$modelAssetPath)"
                    )
                }
                outputH = outputShape[1]
                outputW = outputShape[2]
                outputC = outputShape[3]
                if (outputH <= 0 || outputW <= 0 || outputC <= 0) {
                    throw IllegalStateException(
                        "Output tensor has non-positive dimension(s): " +
                            "h=$outputH w=$outputW C=$outputC (model=$modelAssetPath)"
                    )
                }
                outputMode = if (outputC == 1) OutputMode.SINGLE_CHANNEL_MASK
                             else OutputMode.MULTICLASS_BG_ZERO
            }
            3 -> {
                // [1, h, w] — implicit single channel
                if (outputShape[0] != 1) {
                    throw IllegalStateException(
                        "Output tensor batch dim must be 1; got ${outputShape.toList()} (model=$modelAssetPath)"
                    )
                }
                outputH = outputShape[1]
                outputW = outputShape[2]
                outputC = 1
                if (outputH <= 0 || outputW <= 0) {
                    throw IllegalStateException(
                        "Output tensor has non-positive spatial dimensions: " +
                            "h=$outputH w=$outputW (model=$modelAssetPath)"
                    )
                }
                outputMode = OutputMode.SINGLE_CHANNEL_MASK
            }
            else -> throw IllegalStateException(
                "Unsupported output tensor rank ${outputShape.size}; " +
                    "expected 3 [1,h,w] or 4 [1,h,w,C]; got ${outputShape.toList()} (model=$modelAssetPath)"
            )
        }

        // 8. Store tensor config.
        val config = TensorConfig(
            inputWidth     = inputW,
            inputHeight    = inputH,
            inputChannels  = 3,
            outputWidth    = outputW,
            outputHeight   = outputH,
            outputChannels = outputC,
            outputMode     = outputMode,
        )
        tensorConfig = config

        // 9. Allocate direct native-order float32 input and output buffers using
        //    the interpreter's reported byte counts (not fixed constants).
        inputBuffer = ByteBuffer.allocateDirect(inputTensor.numBytes())
            .apply { order(ByteOrder.nativeOrder()) }
        outputBuffer = ByteBuffer.allocateDirect(outputTensor.numBytes())
            .apply { order(ByteOrder.nativeOrder()) }

        Log.i(
            TAG,
            "ANDROID_DUET_RAW_TFLITE_GPU_READY " +
                "model=$modelAssetPath " +
                "delegateMode=$delegateMode " +
                "optionsSource=$optionsSource " +
                "compatSupported=$compatSupported " +
                "inputShape=${inputShape.toList()} " +
                "outputShape=${outputShape.toList()}",
        )
    }

    private fun loadModelBytes(): ByteBuffer {
        val assetManager = context.applicationContext?.assets ?: context.assets
        val stream: InputStream = try {
            assetManager.open(modelAssetPath)
        } catch (t: Throwable) {
            throw IllegalStateException(
                "Cannot open model asset '$modelAssetPath' from Android assets: ${t.message}", t,
            )
        }
        return stream.use { s ->
            val raw = s.readBytes()
            ByteBuffer.allocateDirect(raw.size).apply {
                order(ByteOrder.nativeOrder())
                put(raw)
                rewind()
            }
        }
    }

    // ── Owned-thread: segment ─────────────────────────────────────────────────

    private fun segmentOnOwnedThread(
        proxy: ImageProxy,
        @Suppress("UNUSED_PARAMETER") timestampMs: Long,
        completion: (DuetSegmentationOutcome) -> Unit,
    ) {
        val entryNs = SystemClock.elapsedRealtimeNanos()

        val interp = interpreter
        val config = tensorConfig
        if (interp == null || config == null || closed.get()) {
            completion(DuetSegmentationOutcome.Skipped("raw_tflite_gpu_closed"))
            return
        }

        val inBuf  = inputBuffer
        val outBuf = outputBuffer
        if (inBuf == null || outBuf == null) {
            completion(DuetSegmentationOutcome.Skipped("raw_tflite_gpu_closed"))
            return
        }

        // 1. Convert YUV_420_888 proxy to an upright ARGB_8888 Bitmap.
        val bitmap: Bitmap = try {
            toUprightBitmap(proxy)
        } catch (t: Throwable) {
            completion(
                DuetSegmentationOutcome.Failure(
                    DuetSegmentationFailureReason.frameConvertFailed(backendId),
                    "ImageProxy -> Bitmap conversion failed: ${t.message}",
                    t,
                )
            )
            return
        }
        val convertDoneNs = SystemClock.elapsedRealtimeNanos()

        // 2. Scale to config.inputWidth x config.inputHeight if needed.
        val scaled: Bitmap = if (bitmap.width == config.inputWidth && bitmap.height == config.inputHeight) {
            bitmap
        } else {
            Bitmap.createScaledBitmap(bitmap, config.inputWidth, config.inputHeight, true)
        }

        // 3. Fill float32 RGB input buffer: normalize to [0, 1].
        inBuf.rewind()
        val pixelCount = config.inputWidth * config.inputHeight
        val pixels = IntArray(pixelCount)
        scaled.getPixels(pixels, 0, config.inputWidth, 0, 0, config.inputWidth, config.inputHeight)
        // Recycle scaled bitmap if it's a different instance from the original.
        if (scaled !== bitmap) {
            try { scaled.recycle() } catch (_: Throwable) {}
        }
        try { bitmap.recycle() } catch (_: Throwable) {}
        val scaleAndPixelsDoneNs = SystemClock.elapsedRealtimeNanos()

        for (pixel in pixels) {
            val r = ((pixel shr 16) and 0xFF) / 255f
            val g = ((pixel shr 8)  and 0xFF) / 255f
            val b = ( pixel         and 0xFF) / 255f
            inBuf.putFloat(r)
            inBuf.putFloat(g)
            inBuf.putFloat(b)
        }
        inBuf.rewind()
        val inputFillDoneNs = SystemClock.elapsedRealtimeNanos()

        // 4. Run inference.
        outBuf.rewind()
        try {
            interp.run(inBuf, outBuf)
        } catch (t: Throwable) {
            completion(
                DuetSegmentationOutcome.Failure(
                    DuetSegmentationFailureReason.inferenceFailed(backendId),
                    "TFLite Interpreter.run failed: ${t.javaClass.simpleName}: ${t.message}",
                    t,
                )
            )
            return
        }
        outBuf.rewind()
        val inferenceDoneNs = SystemClock.elapsedRealtimeNanos()

        // 5. Extract alpha mask using dynamic output config.
        //    Output layout: [1, outH, outW, outC], stride = outC floats per pixel.
        //    SINGLE_CHANNEL_MASK: alpha = value.coerceIn(0,1)*255
        //    MULTICLASS_BG_ZERO:  alpha = (1 - bgClass0).coerceIn(0,1)*255
        val outPixelCount = config.outputWidth * config.outputHeight
        val maskBuf = ByteBuffer.allocateDirect(outPixelCount).apply { order(ByteOrder.nativeOrder()) }
        val outFloats = outBuf.asFloatBuffer()
        when (config.outputMode) {
            OutputMode.SINGLE_CHANNEL_MASK -> {
                for (i in 0 until outPixelCount) {
                    val value = outFloats.get(i).coerceIn(0f, 1f)
                    val alpha = (value * 255f).toInt().toByte()
                    maskBuf.put(alpha)
                }
            }
            OutputMode.MULTICLASS_BG_ZERO -> {
                for (i in 0 until outPixelCount) {
                    val baseIdx = i * config.outputChannels + BACKGROUND_CLASS_IDX
                    val bgConf = outFloats.get(baseIdx).coerceIn(0f, 1f)
                    val alpha = ((1f - bgConf) * 255f).toInt().toByte()
                    maskBuf.put(alpha)
                }
            }
        }
        maskBuf.rewind()

        if (!loggedFirstMask) {
            loggedFirstMask = true
            Log.i(
                TAG,
                "ANDROID_DUET_GREENSCREEN_RAW_TFLITE_GPU_MASK_FIRST " +
                    "width=${config.outputWidth} height=${config.outputHeight} format=uint8_alpha",
            )
        }

        val frame = try {
            AndroidDuetSegmentationFrame.adoptOwned(
                ownedBytes  = maskBuf,
                width       = config.outputWidth,
                height      = config.outputHeight,
                timestampMs = timestampMs,
                backend     = backendId,
                format      = DuetSegmentationMaskFormat.UINT8_ALPHA,
            )
        } catch (t: Throwable) {
            completion(
                DuetSegmentationOutcome.Failure(
                    DuetSegmentationFailureReason.maskSizeMismatch(backendId),
                    "adoptOwned failed: ${t.message}",
                    t,
                )
            )
            return
        }
        val maskExtractDoneNs = SystemClock.elapsedRealtimeNanos()

        recordPhaseTelemetryQuietly(
            entryNs               = entryNs,
            convertDoneNs         = convertDoneNs,
            scaleAndPixelsDoneNs  = scaleAndPixelsDoneNs,
            inputFillDoneNs       = inputFillDoneNs,
            inferenceDoneNs       = inferenceDoneNs,
            maskExtractDoneNs     = maskExtractDoneNs,
        )

        completion(DuetSegmentationOutcome.Mask(frame))
    }

    /**
     * Converts monotonic elapsedRealtimeNanos phase marks into per-phase ms
     * deltas and forwards them to [phaseTelemetry]. Diagnostic only: never
     * throws back into the hot path, never affects the Mask outcome already
     * built by the caller.
     */
    private fun recordPhaseTelemetryQuietly(
        entryNs: Long,
        convertDoneNs: Long,
        scaleAndPixelsDoneNs: Long,
        inputFillDoneNs: Long,
        inferenceDoneNs: Long,
        maskExtractDoneNs: Long,
    ) {
        try {
            phaseTelemetry.recordMask(
                convertMs        = (convertDoneNs - entryNs) / 1_000_000L,
                scaleAndPixelsMs = (scaleAndPixelsDoneNs - convertDoneNs) / 1_000_000L,
                inputFillMs      = (inputFillDoneNs - scaleAndPixelsDoneNs) / 1_000_000L,
                inferenceMs      = (inferenceDoneNs - inputFillDoneNs) / 1_000_000L,
                maskExtractMs    = (maskExtractDoneNs - inferenceDoneNs) / 1_000_000L,
                totalMs          = (maskExtractDoneNs - entryNs) / 1_000_000L,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "phase telemetry record failed: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    // ── Owned-thread: close resources ─────────────────────────────────────────

    /**
     * Closes Interpreter before GpuDelegate (TFLite contract), then clears
     * tensor buffers and config. Must run on the owned thread.
     */
    private fun closeOwnedResourcesQuietly() {
        try { phaseTelemetry.logSummary() } catch (t: Throwable) {
            Log.w(TAG, "phase telemetry summary failed: ${t.message}")
        }

        val interp = interpreter
        interpreter = null
        if (interp != null) {
            try { interp.close() } catch (t: Throwable) {
                Log.w(TAG, "Interpreter.close() threw: ${t.message}")
            }
        }

        val gpu = gpuDelegate
        gpuDelegate = null
        if (gpu != null) {
            try { gpu.close() } catch (t: Throwable) {
                Log.w(TAG, "GpuDelegate.close() threw: ${t.message}")
            }
        }

        inputBuffer  = null
        outputBuffer = null
        tensorConfig = null
    }

    // ── Frame conversion ──────────────────────────────────────────────────────

    /**
     * Converts the YUV_420_888 proxy to an ARGB_8888 bitmap rotated upright by
     * [ImageProxy.getImageInfo].rotationDegrees (clockwise, CameraX semantics).
     * Duplicated locally from AndroidDuetMediaPipeSegmentationBackend; kept
     * private to avoid cross-class coupling.
     */
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

    // ── Utilities ─────────────────────────────────────────────────────────────

    private fun shutdownExecutorQuietly(exec: ExecutorService) {
        executor = null
        try { exec.shutdown() } catch (_: Throwable) {}
    }
}
