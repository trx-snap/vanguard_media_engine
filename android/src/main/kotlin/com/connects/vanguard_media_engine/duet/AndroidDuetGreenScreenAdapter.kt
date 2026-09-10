package com.connects.vanguard_media_engine.duet

import android.annotation.SuppressLint
import android.util.Log
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.SegmentationMask
import com.google.mlkit.vision.segmentation.Segmenter
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: ML Kit Selfie Segmentation adapter for Duet preview.
// -----------------------------------------------------------------------------
//
// Responsibilities — strictly bounded:
//   - Creates a ML Kit Selfie Segmenter in STREAM_MODE with raw mask output.
//   - Wraps the segmenter as a CameraX ImageAnalysis.Analyzer (single-in-flight,
//     drop-stale).
//   - Copies the mask buffer before leaving the success callback.
//   - Reports masks via [onMask] and fallback events via [onFallback].
//   - Idempotent start/stop; closes Segmenter on stop.
//   - Always closes ImageProxy on every path (success/failure/drop).
//   - No EventChannel wiring; no ML Kit on the render thread.
//
// Threading:
//   - start/stop called on main thread.
//   - Analyzer runs on the CameraX analysis executor (dedicated, single thread).
//   - onMask/onFallback may fire on the analysis executor; callers post to
//     their own threads as needed.

class AndroidDuetGreenScreenAdapter(
    /** Called with each successfully copied mask frame. May fire off main thread. */
    private val onMask: (AndroidDuetSegmentationFrame) -> Unit,
    /**
     * Called when the adapter degrades from [previousBackend] to [currentBackend].
     * [reason] is a machine key; [userMessage] is English prose for logging.
     * May fire off main thread.
     */
    private val onFallback: (
        previousBackend: String,
        currentBackend: String,
        reason: String,
        userMessage: String,
    ) -> Unit,
) : ImageAnalysis.Analyzer {

    companion object {
        private const val TAG = "DuetGreenScreenAdapter"
    }

    // ── State ──────────────────────────────────────────────────────────────────

    private val isRunning = AtomicBoolean(false)
    private val inFlight  = AtomicBoolean(false)

    // Hold the live segmenter in a typed holder. Segmenter itself is not
    // parameterizable as AtomicReference<Segmenter<SegmentationMask>> because
    // Segmenter is an interface with a type parameter and Kotlin's type system
    // requires an explicit raw-type workaround. We use a private wrapper.
    private data class SegmenterHolder(val segmenter: Segmenter)
    private val holderRef = AtomicReference<SegmenterHolder?>(null)

    // ── Public API ─────────────────────────────────────────────────────────────

    /**
     * Creates the ML Kit segmenter and arms the analyzer. Idempotent: if
     * already running, logs and returns immediately.
     */
    fun start() {
        if (!isRunning.compareAndSet(false, true)) {
            Log.w(TAG, "start() called while already running — ignored")
            return
        }
        val options = SelfieSegmenterOptions.Builder()
            .setDetectorMode(SelfieSegmenterOptions.STREAM_MODE)
            .enableRawSizeMask()
            .build()
        val segmenter = Segmentation.getClient(options)
        holderRef.set(SegmenterHolder(segmenter))
        Log.d(TAG, "start() — ML Kit Selfie Segmenter (STREAM_MODE, raw mask) created")
    }

    /**
     * Stops the analyzer and closes the ML Kit segmenter. Idempotent: if not
     * running, logs and returns immediately.
     */
    fun stop() {
        if (!isRunning.compareAndSet(true, false)) {
            Log.d(TAG, "stop() called while not running — ignored")
            return
        }
        val holder = holderRef.getAndSet(null)
        try { holder?.segmenter?.close() } catch (t: Throwable) {
            Log.w(TAG, "Segmenter.close() threw: ${t.message}")
        }
        Log.d(TAG, "stop() — segmenter closed")
    }

    // ── ImageAnalysis.Analyzer ─────────────────────────────────────────────────

    @SuppressLint("UnsafeOptInUsageError")
    override fun analyze(proxy: ImageProxy) {
        // Drop stale: if a previous frame is still in flight, close and skip.
        if (!inFlight.compareAndSet(false, true)) {
            Log.v(TAG, "analyze(): frame dropped (previous still in flight)")
            proxy.close()
            return
        }

        if (!isRunning.get()) {
            inFlight.set(false)
            proxy.close()
            return
        }

        val holder = holderRef.get()
        if (holder == null) {
            inFlight.set(false)
            proxy.close()
            return
        }

        val mediaImage = proxy.image
        if (mediaImage == null) {
            Log.w(TAG, "analyze(): proxy.image is null — skipping")
            inFlight.set(false)
            proxy.close()
            return
        }

        val timestampMs = System.currentTimeMillis()
        val inputImage = InputImage.fromMediaImage(mediaImage, proxy.imageInfo.rotationDegrees)

        holder.segmenter.process(inputImage)
            .addOnSuccessListener { mask: SegmentationMask ->
                try {
                    val frame = AndroidDuetSegmentationFrame.copyFrom(
                        source      = mask.buffer,
                        width       = mask.width,
                        height      = mask.height,
                        timestampMs = timestampMs,
                        backend     = DuetSegmentationBackend.MLKIT,
                    )
                    onMask(frame)
                } catch (t: Throwable) {
                    Log.w(TAG, "Mask copy/callback threw: ${t.message}")
                } finally {
                    inFlight.set(false)
                    proxy.close()
                }
            }
            .addOnFailureListener { e: Exception ->
                Log.w(TAG, "Segmentation failed: ${e.message}")
                val prevBackend = DuetSegmentationBackend.MLKIT
                val nextBackend = DuetSegmentationBackend.NONE
                val reason = "mlkit_failure"
                val userMessage = "ML Kit segmentation failed: ${e.message}. Falling back to no green-screen."
                Log.w(TAG, "[GreenScreen fallback] $prevBackend -> $nextBackend ($reason): $userMessage")
                try {
                    onFallback(prevBackend, nextBackend, reason, userMessage)
                } catch (t: Throwable) {
                    Log.w(TAG, "onFallback threw: ${t.message}")
                }
                inFlight.set(false)
                proxy.close()
            }
    }

    /** Metadata describing this analyzer for use in CameraSource binding. */
    fun fallbackMetadata(): Map<String, Any?> = mapOf(
        "backend"   to DuetSegmentationBackend.MLKIT,
        "mode"      to "STREAM_MODE",
        "rawMask"   to true,
        "maxWidth"  to 256,
        "maxHeight" to 256,
    )
}
