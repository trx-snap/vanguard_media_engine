package com.connects.vanguard_media_engine.duet

import android.annotation.SuppressLint
import android.util.Log
import androidx.camera.core.ImageProxy
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.SegmentationMask
import com.google.mlkit.vision.segmentation.Segmenter
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: ML Kit Selfie Segmentation backend (fallback rung).
// -----------------------------------------------------------------------------
//
// Second rung of the segmentation ladder (`mlkit`). This is the pre-existing
// ML Kit path lifted out of AndroidDuetGreenScreenAdapter verbatim:
//   - STREAM_MODE selfie segmenter with raw-size mask output.
//   - InputImage.fromMediaImage(proxy.image, rotationDegrees) — no Bitmap.
//   - The float32 mask buffer is copied inside the success callback into a
//     FLOAT32_CONFIDENCE frame (byte-identical to the previous behaviour).
//   - A failed mask copy is a Skipped outcome (logged, non-fatal), exactly as
//     before; only ML Kit's own failure listener produces a Failure, which the
//     adapter turns into the terminal `green_screen_fallback`.
//
// Threading: [segment] is called on the analysis thread; ML Kit Task listeners
// fire on the main thread, where [completion] runs. [close] may run on the
// main or analysis thread.

class AndroidDuetMlKitSegmentationBackend : AndroidDuetSegmentationBackend {

    companion object {
        private const val TAG = "DuetMlKitSeg"
    }

    override val backendId: String = DuetSegmentationBackend.MLKIT

    private val closed = AtomicBoolean(false)
    private val segmenterRef = AtomicReference<Segmenter?>(null)

    override fun open() {
        check(!closed.get()) { "ML Kit backend already closed" }
        if (segmenterRef.get() != null) return
        val options = SelfieSegmenterOptions.Builder()
            .setDetectorMode(SelfieSegmenterOptions.STREAM_MODE)
            .enableRawSizeMask()
            .build()
        val segmenter = Segmentation.getClient(options)
        if (!segmenterRef.compareAndSet(null, segmenter) || closed.get()) {
            try { segmenter.close() } catch (_: Throwable) {}
            if (closed.get()) throw IllegalStateException("ML Kit backend closed during open()")
        }
        Log.i(TAG, "open() — ML Kit Selfie Segmenter (STREAM_MODE, raw mask) created")
    }

    @SuppressLint("UnsafeOptInUsageError")
    override fun segment(
        proxy: ImageProxy,
        timestampMs: Long,
        completion: (DuetSegmentationOutcome) -> Unit,
    ) {
        val segmenter = segmenterRef.get()
        if (segmenter == null || closed.get()) {
            completion(DuetSegmentationOutcome.Skipped("mlkit_closed"))
            return
        }
        val mediaImage = proxy.image
        if (mediaImage == null) {
            Log.w(TAG, "segment(): proxy.image is null — skipping")
            completion(DuetSegmentationOutcome.Skipped("no_media_image"))
            return
        }

        val inputImage = InputImage.fromMediaImage(mediaImage, proxy.imageInfo.rotationDegrees)
        segmenter.process(inputImage)
            .addOnSuccessListener { mask: SegmentationMask ->
                val outcome = try {
                    DuetSegmentationOutcome.Mask(
                        AndroidDuetSegmentationFrame.copyFrom(
                            source      = mask.buffer,
                            width       = mask.width,
                            height      = mask.height,
                            timestampMs = timestampMs,
                            backend     = backendId,
                            format      = DuetSegmentationMaskFormat.FLOAT32_CONFIDENCE,
                        )
                    )
                } catch (t: Throwable) {
                    Log.w(TAG, "Mask copy threw: ${t.message}")
                    DuetSegmentationOutcome.Skipped("mlkit_mask_copy_failed")
                }
                completion(outcome)
            }
            .addOnFailureListener { e: Exception ->
                Log.w(TAG, "Segmentation failed: ${e.message}")
                completion(
                    DuetSegmentationOutcome.Failure(
                        DuetSegmentationFailureReason.MLKIT_FAILURE,
                        "ML Kit segmentation failed: ${e.message}",
                        e,
                    )
                )
            }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val segmenter = segmenterRef.getAndSet(null)
        try { segmenter?.close() } catch (t: Throwable) {
            Log.w(TAG, "Segmenter.close() threw: ${t.message}")
        }
        Log.d(TAG, "close() — segmenter closed")
    }
}
