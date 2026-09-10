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
import java.util.concurrent.atomic.AtomicBoolean

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: MediaPipe Tasks Vision ImageSegmenter backend (CPU).
// -----------------------------------------------------------------------------
//
// Primary rung of the segmentation ladder (`mediapipe_cpu`). Slice 1 scope:
//   - CPU delegate only (GPU is deferred), RunningMode.VIDEO, synchronous
//     segmentForVideo on the CameraX analysis thread.
//   - Input: CameraX YUV_420_888 ImageProxy -> ARGB_8888 Bitmap (rotated
//     upright by ImageInfo.rotationDegrees so the mask has the same
//     orientation semantics as the ML Kit raw mask) -> MPImage.
//   - Output: the model's person confidence mask (float32) converted on this
//     thread into a UINT8_ALPHA frame (stride 1). The frame is tagged with
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
// Threading: [open] / [segment] run on the single CameraX analysis thread;
// [close] may run on the main thread (stop / dispose) or the analysis thread
// (degradation). The segmenter handle is swapped atomically; a segment() call
// racing close() observes null and completes with Skipped.

class AndroidDuetMediaPipeSegmentationBackend(
    private val context: Context,
    private val modelAssetPath: String,
) : AndroidDuetSegmentationBackend {

    companion object {
        private const val TAG = "DuetMediaPipeSeg"
    }

    override val backendId: String = DuetSegmentationBackend.MEDIAPIPE_CPU

    private val closed = AtomicBoolean(false)

    /** Live segmenter; null before [open] and after [close]. */
    @Volatile private var segmenter: ImageSegmenter? = null

    /** Analysis-thread-only monotonic guard for segmentForVideo timestamps. */
    private var lastTimestampMs = Long.MIN_VALUE

    /** Analysis-thread-only scratch for the float32 -> uint8 conversion. */
    private var floatScratch = FloatArray(0)

    private var loggedMaskLayout = false

    // ── AndroidDuetSegmentationBackend ─────────────────────────────────────────

    override fun open() {
        check(!closed.get()) { "MediaPipe backend already closed" }
        if (segmenter != null) return
        val baseOptions = BaseOptions.builder()
            .setModelAssetPath(modelAssetPath)
            .setDelegate(Delegate.CPU)
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
            throw IllegalStateException("MediaPipe backend closed during open()")
        }
        segmenter = created
        Log.i(TAG, "open() — ImageSegmenter ready (asset=$modelAssetPath, delegate=CPU, mode=VIDEO)")
    }

    override fun segment(
        proxy: ImageProxy,
        timestampMs: Long,
        completion: (DuetSegmentationOutcome) -> Unit,
    ) {
        val seg = segmenter
        if (seg == null || closed.get()) {
            completion(DuetSegmentationOutcome.Skipped("mediapipe_closed"))
            return
        }

        // 1. YUV_420_888 -> upright ARGB bitmap. Only the MediaPipe rung pays
        //    this conversion; ML Kit consumes the media image directly.
        val bitmap: Bitmap = try {
            toUprightBitmap(proxy)
        } catch (t: Throwable) {
            completion(
                DuetSegmentationOutcome.Failure(
                    DuetSegmentationFailureReason.MEDIAPIPE_FRAME_CONVERT_FAILED,
                    "ImageProxy -> Bitmap conversion failed: ${t.message}",
                    t,
                )
            )
            return
        }

        // 2. Strictly increasing timestamp (VIDEO mode contract).
        val ts = if (timestampMs <= lastTimestampMs) lastTimestampMs + 1 else timestampMs
        lastTimestampMs = ts

        // 3. Synchronous inference + mask conversion.
        var mpImage: MPImage? = null
        var result: ImageSegmenterResult? = null
        val outcome: DuetSegmentationOutcome = try {
            mpImage = BitmapImageBuilder(bitmap).build()
            result = seg.segmentForVideo(mpImage, ts)
            extractPersonMask(result, ts)
        } catch (t: Throwable) {
            DuetSegmentationOutcome.Failure(
                DuetSegmentationFailureReason.MEDIAPIPE_INFERENCE_FAILED,
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

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val seg = segmenter
        segmenter = null
        try { seg?.close() } catch (t: Throwable) {
            Log.w(TAG, "ImageSegmenter.close() threw: ${t.message}")
        }
        floatScratch = FloatArray(0)
        Log.d(TAG, "close() — ImageSegmenter released")
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
                DuetSegmentationFailureReason.MEDIAPIPE_EMPTY_RESULT,
                "ImageSegmenter returned no confidence masks (outputConfidenceMasks=true)",
            )
        }
        val mask = masks[masks.size - 1]
        val width = mask.width
        val height = mask.height
        if (width <= 0 || height <= 0) {
            return DuetSegmentationOutcome.Failure(
                DuetSegmentationFailureReason.MEDIAPIPE_MASK_SIZE_MISMATCH,
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
                DuetSegmentationFailureReason.MEDIAPIPE_MASK_SIZE_MISMATCH,
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
                "ANDROID_DUET_GREENSCREEN_MEDIAPIPE_MASK_FIRST width=$width height=$height " +
                    "masks=${masks.size} personIndex=${masks.size - 1} format=vec32f1->uint8_alpha",
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
