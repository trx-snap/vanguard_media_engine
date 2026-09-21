package com.connects.vanguard_media_engine.greenscreen

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
// VG-GREEN-SCREEN: ML Kit Selfie Segmentation backend (fallback rung).
// -----------------------------------------------------------------------------
//
// Byte-for-byte port of
// `com.connects.vanguard_media_engine.duet.AndroidDuetMlKitSegmentationBackend`
// (only the package, class name, and referenced backend/outcome/frame types
// changed) — GreenScreen segmentation is an independent, reusable capability
// and must not be owned by the Duet compositor package. The Duet class is
// kept as a source-compatible type alias onto this one.
//
// Second rung of the segmentation ladder (`mlkit`):
//   - STREAM_MODE selfie segmenter with raw-size mask output.
//   - InputImage.fromMediaImage(proxy.image, rotationDegrees) — no Bitmap.
//   - The float32 mask buffer is copied inside the success callback into a
//     FLOAT32_CONFIDENCE frame (byte-identical to the previous behaviour).
//   - A failed mask copy is a Skipped outcome (logged, non-fatal), exactly as
//     before; only ML Kit's own failure listener produces a Failure, which the
//     filter node turns into the terminal `green_screen_fallback`.
//
// Threading: [segment] is called on the analysis thread; ML Kit Task listeners
// fire on the main thread, where [completion] runs. [close] may run on the
// main or analysis thread.

class AndroidGreenScreenMlKitSegmentationBackend : AndroidGreenScreenImageProxySegmentationBackend {

    companion object {
        private const val TAG = "GreenScreenMlKitSeg"
    }

    override val backendId: String = AndroidGreenScreenSegmentationBackend.MLKIT

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
        completion: (GreenScreenSegmentationOutcome) -> Unit,
    ) {
        val segmenter = segmenterRef.get()
        if (segmenter == null || closed.get()) {
            completion(GreenScreenSegmentationOutcome.Skipped("mlkit_closed"))
            return
        }
        val mediaImage = proxy.image
        if (mediaImage == null) {
            Log.w(TAG, "segment(): proxy.image is null — skipping")
            completion(GreenScreenSegmentationOutcome.Skipped("no_media_image"))
            return
        }

        val inputImage = InputImage.fromMediaImage(mediaImage, proxy.imageInfo.rotationDegrees)
        segmenter.process(inputImage)
            .addOnSuccessListener { mask: SegmentationMask ->
                val outcome = try {
                    GreenScreenSegmentationOutcome.Mask(
                        AndroidGreenScreenSegmentationFrame.copyFrom(
                            source      = mask.buffer,
                            width       = mask.width,
                            height      = mask.height,
                            timestampMs = timestampMs,
                            backend     = backendId,
                            format      = GreenScreenSegmentationMaskFormat.FLOAT32_CONFIDENCE,
                        )
                    )
                } catch (t: Throwable) {
                    Log.w(TAG, "Mask copy threw: ${t.message}")
                    GreenScreenSegmentationOutcome.Skipped("mlkit_mask_copy_failed")
                }
                completion(outcome)
            }
            .addOnFailureListener { e: Exception ->
                Log.w(TAG, "Segmentation failed: ${e.message}")
                completion(
                    GreenScreenSegmentationOutcome.Failure(
                        GreenScreenSegmentationFailureReason.MLKIT_FAILURE,
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
