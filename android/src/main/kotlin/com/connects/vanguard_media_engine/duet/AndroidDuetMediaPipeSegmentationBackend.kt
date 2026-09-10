package com.connects.vanguard_media_engine.duet

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.util.Log
import androidx.camera.core.ImageProxy
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.ByteBufferExtractor
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenter
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenterResult
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: MediaPipe Tasks Vision ImageSegmenter backend.
// -----------------------------------------------------------------------------
//
// Parameterized over [backendId] / [delegate] so the same class implements both
// the `mediapipe_gpu` (Delegate.GPU) and `mediapipe_cpu` (Delegate.CPU) rungs.
// Use the [gpu] / [cpu] factory functions to construct either variant. Only
// `mediapipe_cpu` is on the production ladder; `mediapipe_gpu` is latent/
// experimental (see [gpu]'s doc comment for the physical-abort rationale).
//   - RunningMode.VIDEO, [modelAssetPath] is the bundled selfie segmenter model.
//   - Input: CameraX YUV_420_888 ImageProxy -> ARGB_8888 Bitmap (rotated
//     upright by ImageInfo.rotationDegrees so the mask has the same
//     orientation semantics as the ML Kit raw mask) -> MPImage.
//   - Output: the model's person confidence mask (float32) converted into a
//     UINT8_ALPHA frame (stride 1). The frame is tagged with
//     [DuetSegmentationMaskFormat.UINT8_ALPHA] so the compositor never reads
//     it through the float32 (stride 4) ML Kit path.
//   - Category masks are deliberately NOT requested: for single-channel selfie
//     models MediaPipe encodes them as 0 = person / 255 = unlabeled, which is
//     the inverse of the natural alpha and easy to misread.
//   - Timestamps: VIDEO mode requires strictly increasing timestamps. The
//     adapter already passes camera-clock ms (ImageInfo.timestamp / 1e6) made
//     monotonic; this class re-guards so a MediaPipe timestamp error can never
//     originate here.
//
// Threading (both CPU and GPU rungs): each backend instance owns exactly one
// single-thread executor created lazily in [open]. ALL MediaPipe lifecycle
// work — ImageSegmenter creation, segmentForVideo, and (when possible)
// ImageSegmenter.close — runs on that one owned thread, never on the CameraX
// analysis thread and never concurrently with itself. This removes the CPU
// rung's latent race (segmentForVideo used to run directly on the analysis
// thread) and gives the GPU delegate the single-thread affinity GL/GPU
// contexts require.
//   - [open] blocks the calling thread (the analysis thread, per the backend
//     contract) until the owned thread has created the ImageSegmenter or
//     failed; a creation failure makes [open] throw so the adapter walks the
//     ladder. If [close] races [open], the created segmenter is closed on the
//     owned thread and never leaked.
//   - [segment] posts the frame to the owned thread and returns immediately;
//     [completion] fires exactly once, from the owned thread, once inference
//     (or a conversion/inference failure) completes. The ImageProxy is only
//     touched before [completion] fires; the adapter closes it afterwards.
//   - [close] is idempotent and never throws. Called from the owned thread
//     itself (e.g. while running inside a segment() completion during
//     handleBackendFailure) it closes the segmenter inline — posting-and-
//     waiting there would deadlock the owned thread against itself. Called
//     from any other thread, it posts the close to the owned thread and waits
//     with a bounded timeout before shutting the executor down, so a stuck
//     native call cannot hang the caller (main thread on stop/dispose)
//     forever.

class AndroidDuetMediaPipeSegmentationBackend private constructor(
    private val context: Context,
    private val modelAssetPath: String,
    override val backendId: String,
    private val delegate: Delegate,
) : AndroidDuetSegmentationBackend {

    companion object {
        private const val TAG = "DuetMediaPipeSeg"

        /** Bounded wait for [close] to finish on the owned thread before it is force-shut-down. */
        private const val CLOSE_TIMEOUT_MS = 1_500L

        /**
         * GPU-delegate rung (`mediapipe_gpu`). EXPERIMENTAL / NOT PRODUCTION-
         * PROVEN: a physical smoke test on SM-A566B (Android 16) showed this
         * configuration (Delegate.GPU + outputConfidenceMasks(true)) can
         * open() successfully and then native-abort (SIGABRT,
         * image_frame.cc:291 "Format UNKNOWN = 0") inside the confidence-mask
         * result converter on the first frame — a crash below the JVM that no
         * try/catch here can intercept. AndroidDuetSegmentationBackendSelector
         * deliberately excludes this rung from the production ladder; this
         * factory remains only for manual/offline investigation of a
         * non-crashing GPU mask extraction path.
         */
        fun gpu(context: Context, modelAssetPath: String) =
            AndroidDuetMediaPipeSegmentationBackend(
                context, modelAssetPath, DuetSegmentationBackend.MEDIAPIPE_GPU, Delegate.GPU,
            )

        /** CPU-delegate rung (`mediapipe_cpu`). */
        fun cpu(context: Context, modelAssetPath: String) =
            AndroidDuetMediaPipeSegmentationBackend(
                context, modelAssetPath, DuetSegmentationBackend.MEDIAPIPE_CPU, Delegate.CPU,
            )
    }

    private val closed = AtomicBoolean(false)

    /** Owned single-thread executor for open/segment/close; created in [open], null before/after. */
    @Volatile private var executor: ExecutorService? = null

    /** The one thread backing [executor], so [close] can detect same-thread calls. */
    @Volatile private var ownedThread: Thread? = null

    /** Live segmenter; touched only on [ownedThread]. Null before [open] and after [close]. */
    private var segmenter: ImageSegmenter? = null

    /** Owned-thread-only monotonic guard for segmentForVideo timestamps. */
    private var lastTimestampMs = Long.MIN_VALUE

    /** Owned-thread-only scratch for the float32 -> uint8 conversion. */
    private var floatScratch = FloatArray(0)

    private var loggedMaskLayout = false

    // ── AndroidDuetSegmentationBackend ─────────────────────────────────────────

    override fun open() {
        check(!closed.get()) { "MediaPipe backend ($backendId) already closed" }
        check(executor == null) { "MediaPipe backend ($backendId) already opened" }

        val executorService = Executors.newSingleThreadExecutor { r ->
            Thread(r, "DuetMediaPipe-$backendId").also { ownedThread = it }.apply { isDaemon = true }
        }
        executor = executorService

        val latch = CountDownLatch(1)
        var creationError: Throwable? = null
        executorService.execute {
            try {
                val baseOptions = BaseOptions.builder()
                    .setModelAssetPath(modelAssetPath)
                    .setDelegate(delegate)
                    .build()
                val options = ImageSegmenter.ImageSegmenterOptions.builder()
                    .setBaseOptions(baseOptions)
                    .setRunningMode(RunningMode.VIDEO)
                    .setOutputConfidenceMasks(true)
                    .setOutputCategoryMask(false)
                    .build()
                val created = ImageSegmenter.createFromOptions(context, options)
                if (closed.get()) {
                    // close() raced open(): never leak the handle.
                    try { created.close() } catch (_: Throwable) {}
                } else {
                    segmenter = created
                }
            } catch (t: Throwable) {
                creationError = t
            } finally {
                latch.countDown()
            }
        }
        latch.await()

        val error = creationError
        if (error != null) {
            shutdownExecutorQuietly(executorService)
            throw IllegalStateException(
                "MediaPipe backend ($backendId) failed to open: ${error.message}", error,
            )
        }
        if (closed.get() || segmenter == null) {
            shutdownExecutorQuietly(executorService)
            throw IllegalStateException("MediaPipe backend ($backendId) closed during open()")
        }
        Log.i(
            TAG,
            "open() — ImageSegmenter ready (id=$backendId, asset=$modelAssetPath, " +
                "delegate=$delegate, mode=VIDEO)",
        )
    }

    override fun segment(
        proxy: ImageProxy,
        timestampMs: Long,
        completion: (DuetSegmentationOutcome) -> Unit,
    ) {
        if (closed.get()) {
            completion(DuetSegmentationOutcome.Skipped("mediapipe_closed"))
            return
        }
        val executorService = executor
        if (executorService == null) {
            completion(DuetSegmentationOutcome.Skipped("mediapipe_closed"))
            return
        }
        try {
            executorService.execute { segmentOnOwnedThread(proxy, timestampMs, completion) }
        } catch (t: RejectedExecutionException) {
            if (closed.get()) {
                completion(DuetSegmentationOutcome.Skipped("mediapipe_closed"))
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
        val executorService = executor
        if (executorService == null) {
            // Never opened (or open() failed before the executor was assigned).
            return
        }

        if (Thread.currentThread() === ownedThread) {
            // Already running on the owned thread (e.g. inside a segment()
            // completion during handleBackendFailure) — close inline. Posting
            // and waiting here would deadlock the thread against itself.
            closeSegmenterQuietly()
            executorService.shutdown()
            return
        }

        val latch = CountDownLatch(1)
        try {
            executorService.execute {
                closeSegmenterQuietly()
                latch.countDown()
            }
        } catch (t: RejectedExecutionException) {
            // Owned thread already gone; nothing left to close natively.
            latch.countDown()
        }

        val closedInTime = try {
            latch.await(CLOSE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!closedInTime) {
            Log.w(TAG, "close() ($backendId) timed out after ${CLOSE_TIMEOUT_MS}ms waiting for " +
                "owned thread; forcing executor shutdown")
            executorService.shutdownNow()
        } else {
            executorService.shutdown()
        }
    }

    // ── Owned-thread work ───────────────────────────────────────────────────────

    private fun segmentOnOwnedThread(
        proxy: ImageProxy,
        timestampMs: Long,
        completion: (DuetSegmentationOutcome) -> Unit,
    ) {
        val seg = segmenter
        if (seg == null || closed.get()) {
            completion(DuetSegmentationOutcome.Skipped("mediapipe_closed"))
            return
        }

        // 1. YUV_420_888 -> upright ARGB bitmap. Only the MediaPipe rungs pay
        //    this conversion; ML Kit consumes the media image directly.
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

        // 2. Strictly increasing timestamp (VIDEO mode contract).
        val ts = if (timestampMs <= lastTimestampMs) lastTimestampMs + 1 else timestampMs
        lastTimestampMs = ts

        // 3. Inference + mask conversion, both on this owned thread.
        var mpImage: MPImage? = null
        var result: ImageSegmenterResult? = null
        val outcome: DuetSegmentationOutcome = try {
            mpImage = BitmapImageBuilder(bitmap).build()
            result = seg.segmentForVideo(mpImage, ts)
            extractPersonMask(result, ts)
        } catch (t: Throwable) {
            DuetSegmentationOutcome.Failure(
                DuetSegmentationFailureReason.inferenceFailed(backendId),
                "ImageSegmenter.segmentForVideo failed: ${t.javaClass.simpleName}: ${t.message}",
                t,
            )
        } finally {
            closeResultQuietly(result)
            val image = mpImage
            if (image != null) {
                // MPImage.close() releases the bitmap container (recycles the bitmap).
                try { image.close() } catch (_: Throwable) {}
            } else {
                try { bitmap.recycle() } catch (_: Throwable) {}
            }
        }
        completion(outcome)
    }

    /** Closes [segmenter] (if any) and clears owned-thread scratch state. Must run on [ownedThread]. */
    private fun closeSegmenterQuietly() {
        val seg = segmenter
        segmenter = null
        if (seg != null) {
            try { seg.close() } catch (t: Throwable) {
                Log.w(TAG, "ImageSegmenter.close() threw ($backendId): ${t.message}")
            }
        }
        floatScratch = FloatArray(0)
        Log.d(TAG, "close() — ImageSegmenter released ($backendId)")
    }

    private fun shutdownExecutorQuietly(executorService: ExecutorService) {
        executor = null
        try { executorService.shutdown() } catch (_: Throwable) {}
    }

    // ── Frame conversion ───────────────────────────────────────────────────────

    /**
     * Converts the YUV_420_888 proxy to an ARGB_8888 bitmap rotated upright by
     * [ImageProxy.getImageInfo].rotationDegrees (clockwise, CameraX semantics),
     * matching the orientation ML Kit applies via InputImage.fromMediaImage.
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

    /**
     * Picks the person confidence mask out of [result] and converts it to a
     * UINT8_ALPHA frame. For the single-channel selfie model MediaPipe reports
     * either one confidence mask (person) or two (background, person); the
     * last entry is the person channel in both layouts.
     */
    private fun extractPersonMask(result: ImageSegmenterResult, timestampMs: Long): DuetSegmentationOutcome {
        val masks = result.confidenceMasks().orElse(null)
        if (masks == null || masks.isEmpty()) {
            return DuetSegmentationOutcome.Failure(
                DuetSegmentationFailureReason.emptyResult(backendId),
                "ImageSegmenter returned no confidence masks (outputConfidenceMasks=true)",
            )
        }
        val mask = masks[masks.size - 1]
        val width = mask.width
        val height = mask.height
        if (width <= 0 || height <= 0) {
            return DuetSegmentationOutcome.Failure(
                DuetSegmentationFailureReason.maskSizeMismatch(backendId),
                "Confidence mask has invalid dimensions ${width}x$height",
            )
        }
        val pixelCount = width * height

        // Confidence masks are VEC32F1: native-order float32 per pixel.
        val floatBytes: ByteBuffer = ByteBufferExtractor.extract(mask, MPImage.IMAGE_FORMAT_VEC32F1)
        val floats = floatBytes.duplicate().order(ByteOrder.nativeOrder()).asFloatBuffer()
        floats.rewind()
        if (floats.remaining() < pixelCount) {
            return DuetSegmentationOutcome.Failure(
                DuetSegmentationFailureReason.maskSizeMismatch(backendId),
                "Confidence mask buffer holds ${floats.remaining()} floats, need $pixelCount " +
                    "for ${width}x$height",
            )
        }
        if (floatScratch.size < pixelCount) floatScratch = FloatArray(pixelCount)
        val scratch = floatScratch
        floats.get(scratch, 0, pixelCount)

        // float32 [0,1] -> uint8 [0,255] with the same truncating quantisation the
        // compositor applies to ML Kit floats, so both rungs key identically.
        val alpha = ByteBuffer.allocateDirect(pixelCount)
        for (i in 0 until pixelCount) {
            val f = scratch[i]
            val clamped = if (f.isNaN()) 0f else f.coerceIn(0f, 1f)
            alpha.put(i, (clamped * 255f).toInt().toByte())
        }
        alpha.rewind()

        if (!loggedMaskLayout) {
            loggedMaskLayout = true
            Log.i(
                TAG,
                "ANDROID_DUET_GREENSCREEN_MEDIAPIPE_MASK_FIRST id=$backendId width=$width " +
                    "height=$height masks=${masks.size} personIndex=${masks.size - 1} " +
                    "format=vec32f1->uint8_alpha",
            )
        }

        return DuetSegmentationOutcome.Mask(
            AndroidDuetSegmentationFrame.adoptOwned(
                ownedBytes  = alpha,
                width       = width,
                height      = height,
                timestampMs = timestampMs,
                backend     = backendId,
                format      = DuetSegmentationMaskFormat.UINT8_ALPHA,
            )
        )
    }

    private fun closeResultQuietly(result: ImageSegmenterResult?) {
        if (result == null) return
        try {
            result.confidenceMasks().orElse(null)?.forEach { m ->
                try { m.close() } catch (_: Throwable) {}
            }
        } catch (_: Throwable) {}
        try {
            result.categoryMask().orElse(null)?.let { m ->
                try { m.close() } catch (_: Throwable) {}
            }
        } catch (_: Throwable) {}
    }
}
