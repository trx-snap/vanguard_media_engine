package com.connects.vanguard_media_engine.duet

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.util.Log
import androidx.camera.core.ImageProxy
import org.tensorflow.lite.Interpreter
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
// Model: selfie_multiclass_256x256.tflite
//   Input  tensor: [1, 256, 256, 3] float32, RGB normalized [0, 1]
//   Output tensor: [1, 256, 256, 6] float32, class 0 = background
//   Person alpha:  (1.0f - output[class=0]).coerceIn(0f, 1f) -> uint8 [0,255]
//
// Threading: one owned single-thread executor for all lifecycle work. GpuDelegate
// contexts require single-thread affinity; this satisfies that requirement.
// open() blocks the caller (analysis thread) until ready or failed.
// segment() posts to the worker thread and fires completion exactly once.
// close() is idempotent, never throws, closes Interpreter before GpuDelegate.

private const val TAG                  = "DuetRawTfliteGpu"
private const val MODEL_ASSET          = "selfie_multiclass_256x256.tflite"
private const val TFL3_MAGIC_BYTE0     = 0x18.toByte() // FlatBuffers TFL3 magic
private const val MODEL_W              = 256
private const val MODEL_H              = 256
private const val MODEL_C_IN           = 3
private const val MODEL_C_OUT          = 6
private const val BACKGROUND_CLASS_IDX = 0
private const val CLOSE_TIMEOUT_MS     = 2_000L

class AndroidDuetRawTfliteGpuSegmentationBackend(
    private val context: Context,
) : AndroidDuetSegmentationBackend {

    override val backendId: String get() = DuetSegmentationBackend.RAW_TFLITE_GPU

    private val closed    = AtomicBoolean(false)
    private var loggedFirstMask = false

    /** Owned single-thread executor; created in open(). */
    @Volatile private var executor: ExecutorService? = null

    /** The backing thread, captured for same-thread close() detection. */
    @Volatile private var ownedThread: Thread? = null

    // ── Owned-thread-only state (never touched from other threads) ────────────

    private var gpuDelegate:  GpuDelegate?  = null
    private var interpreter:  Interpreter?  = null
    private var inputBuffer:  ByteBuffer?   = null
    private var outputBuffer: ByteBuffer?   = null

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

        // 3. Create GpuDelegate using default options. Per architecture decision,
        //    we use standalone GpuDelegate even if CompatibilityList reports unsupported.
        val gpuDel = GpuDelegate(GpuDelegateFactory.Options())
        gpuDelegate = gpuDel

        // 4. Create Interpreter with GpuDelegate.
        val options = Interpreter.Options().apply {
            addDelegate(gpuDel)
        }
        val interp = Interpreter(modelBytes, options)
        interpreter = interp

        // 5. Allocate tensors.
        interp.allocateTensors()

        // 6. Verify input tensor: [1, 256, 256, 3] float32.
        val inputTensor = interp.getInputTensor(0)
        val inputShape  = inputTensor.shape()
        if (inputShape.size != 4 ||
            inputShape[0] != 1 ||
            inputShape[1] != MODEL_H ||
            inputShape[2] != MODEL_W ||
            inputShape[3] != MODEL_C_IN
        ) {
            throw IllegalStateException(
                "Input tensor shape mismatch: expected [1,$MODEL_H,$MODEL_W,$MODEL_C_IN] " +
                    "got ${inputShape.toList()}"
            )
        }
        if (inputTensor.dataType() != org.tensorflow.lite.DataType.FLOAT32) {
            throw IllegalStateException(
                "Input tensor dtype mismatch: expected FLOAT32, got ${inputTensor.dataType()}"
            )
        }

        // 7. Verify output tensor: [1, 256, 256, 6] float32.
        val outputTensor = interp.getOutputTensor(0)
        val outputShape  = outputTensor.shape()
        if (outputShape.size != 4 ||
            outputShape[0] != 1 ||
            outputShape[1] != MODEL_H ||
            outputShape[2] != MODEL_W ||
            outputShape[3] != MODEL_C_OUT
        ) {
            throw IllegalStateException(
                "Output tensor shape mismatch: expected [1,$MODEL_H,$MODEL_W,$MODEL_C_OUT] " +
                    "got ${outputShape.toList()}"
            )
        }
        if (outputTensor.dataType() != org.tensorflow.lite.DataType.FLOAT32) {
            throw IllegalStateException(
                "Output tensor dtype mismatch: expected FLOAT32, got ${outputTensor.dataType()}"
            )
        }

        // 8. Allocate direct native-order float32 input and output buffers.
        val pixelCount = MODEL_H * MODEL_W
        inputBuffer = ByteBuffer.allocateDirect(pixelCount * MODEL_C_IN * 4)
            .apply { order(ByteOrder.nativeOrder()) }
        outputBuffer = ByteBuffer.allocateDirect(pixelCount * MODEL_C_OUT * 4)
            .apply { order(ByteOrder.nativeOrder()) }

        Log.i(
            TAG,
            "ANDROID_DUET_RAW_TFLITE_GPU_READY " +
                "model=$MODEL_ASSET " +
                "inputShape=[1,$MODEL_H,$MODEL_W,$MODEL_C_IN] " +
                "outputShape=[1,$MODEL_H,$MODEL_W,$MODEL_C_OUT]",
        )
    }

    private fun loadModelBytes(): ByteBuffer {
        val assetManager = context.applicationContext?.assets ?: context.assets
        val stream: InputStream = try {
            assetManager.open(MODEL_ASSET)
        } catch (t: Throwable) {
            throw IllegalStateException(
                "Cannot open model asset '$MODEL_ASSET' from Android assets: ${t.message}", t,
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
        val interp = interpreter
        if (interp == null || closed.get()) {
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

        // 2. Scale to 256x256 if needed. Keep source bitmap alive until pixel extraction completes.
        val scaled: Bitmap = if (bitmap.width == MODEL_W && bitmap.height == MODEL_H) {
            bitmap
        } else {
            Bitmap.createScaledBitmap(bitmap, MODEL_W, MODEL_H, true)
        }

        // 3. Fill float32 RGB input buffer: normalize to [0, 1].
        inBuf.rewind()
        val pixels = IntArray(MODEL_W * MODEL_H)
        scaled.getPixels(pixels, 0, MODEL_W, 0, 0, MODEL_W, MODEL_H)
        // Recycle scaled bitmap if it's a different instance from the original.
        if (scaled !== bitmap) {
            try { scaled.recycle() } catch (_: Throwable) {}
        }
        try { bitmap.recycle() } catch (_: Throwable) {}

        for (pixel in pixels) {
            val r = ((pixel shr 16) and 0xFF) / 255f
            val g = ((pixel shr 8)  and 0xFF) / 255f
            val b = ( pixel         and 0xFF) / 255f
            inBuf.putFloat(r)
            inBuf.putFloat(g)
            inBuf.putFloat(b)
        }
        inBuf.rewind()

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

        // 5. Extract background confidence (class 0) and compute person alpha.
        //    Output layout: [1, H, W, 6], stride = 6 floats per pixel.
        //    Person alpha = (1.0f - bgConf).coerceIn(0f, 1f) -> uint8 [0,255].
        val pixelCount = MODEL_W * MODEL_H
        val maskBuf = ByteBuffer.allocateDirect(pixelCount).apply { order(ByteOrder.nativeOrder()) }
        val outFloats = outBuf.asFloatBuffer()
        for (i in 0 until pixelCount) {
            val baseIdx = i * MODEL_C_OUT + BACKGROUND_CLASS_IDX
            val bgConf = outFloats.get(baseIdx).coerceIn(0f, 1f)
            val alpha = ((1f - bgConf) * 255f).toInt().toByte()
            maskBuf.put(alpha)
        }
        maskBuf.rewind()

        if (!loggedFirstMask) {
            loggedFirstMask = true
            Log.i(
                TAG,
                "ANDROID_DUET_GREENSCREEN_RAW_TFLITE_GPU_MASK_FIRST " +
                    "width=$MODEL_W height=$MODEL_H format=uint8_alpha",
            )
        }

        val frame = try {
            AndroidDuetSegmentationFrame.adoptOwned(
                ownedBytes  = maskBuf,
                width       = MODEL_W,
                height      = MODEL_H,
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

        completion(DuetSegmentationOutcome.Mask(frame))
    }

    // ── Owned-thread: close resources ─────────────────────────────────────────

    /**
     * Closes Interpreter before GpuDelegate (TFLite contract), then clears
     * tensor buffers. Must run on the owned thread.
     */
    private fun closeOwnedResourcesQuietly() {
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
