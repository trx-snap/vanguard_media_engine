package com.connects.vanguard_media_engine.duet

import androidx.camera.core.ImageProxy

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Segmentation backend seam behind the single CameraX
// analyzer facade (AndroidDuetGreenScreenAdapter).
// -----------------------------------------------------------------------------
//
// One backend instance == one live segmenter. The adapter owns the ladder
// (mediapipe_cpu -> mlkit -> none/PiP), the single-in-flight gate and every
// ImageProxy close; backends only turn one ImageProxy into one outcome.
//
// Contract for implementations:
//   - [open] runs once, on the analysis thread, before the first [segment].
//     It may block (model load) and may throw; a throw means "this backend is
//     unavailable" and the adapter walks the ladder.
//   - [segment] must invoke [completion] exactly once, synchronously or
//     asynchronously, and must never close [proxy]. The proxy stays valid until
//     [completion] is invoked; the backend must not touch it afterwards.
//   - [close] is idempotent, never throws, and may be called from any thread
//     (main thread on stop / layout switch / dispose, analysis thread on
//     degradation). After [close], any late [segment] call must complete with
//     [DuetSegmentationOutcome.Skipped].

/** Result of segmenting one analysis frame. */
sealed class DuetSegmentationOutcome {
    /** A mask the adapter may forward to the compositor. */
    class Mask(val frame: AndroidDuetSegmentationFrame) : DuetSegmentationOutcome()

    /**
     * No mask for this frame, backend still healthy (e.g. no media image, or
     * the backend was closed while the frame was in flight). Never triggers
     * ladder movement.
     */
    class Skipped(val reason: String) : DuetSegmentationOutcome()

    /**
     * Backend failure. The adapter closes this backend and moves down the
     * ladder: MediaPipe -> ML Kit (non-terminal `green_screen_degraded`),
     * ML Kit -> none (terminal `green_screen_fallback` / safe PiP).
     */
    class Failure(
        val reason: String,
        val message: String,
        val cause: Throwable? = null,
    ) : DuetSegmentationOutcome()
}

/** Machine reason keys surfaced in `green_screen_degraded` / `green_screen_fallback`. */
object DuetSegmentationFailureReason {
    const val MEDIAPIPE_INIT_FAILED          = "mediapipe_init_failed"
    const val MEDIAPIPE_INFERENCE_FAILED     = "mediapipe_inference_failed"
    const val MEDIAPIPE_FRAME_CONVERT_FAILED = "mediapipe_frame_convert_failed"
    const val MEDIAPIPE_EMPTY_RESULT         = "mediapipe_empty_result"
    const val MEDIAPIPE_MASK_SIZE_MISMATCH   = "mediapipe_mask_size_mismatch"
    const val MLKIT_INIT_FAILED              = "mlkit_init_failed"
    const val MLKIT_FAILURE                  = "mlkit_failure"

    /** Reason when a backend's [AndroidDuetSegmentationBackend.segment] throws synchronously. */
    fun segmentThrew(backendId: String): String = "${backendId}_segment_threw"

    /** Reason when a backend's [AndroidDuetSegmentationBackend.open] throws. */
    fun initFailed(backendId: String): String = when (backendId) {
        DuetSegmentationBackend.MEDIAPIPE_CPU -> MEDIAPIPE_INIT_FAILED
        DuetSegmentationBackend.MLKIT         -> MLKIT_INIT_FAILED
        else                                  -> "${backendId}_init_failed"
    }
}

interface AndroidDuetSegmentationBackend {
    /** One of [DuetSegmentationBackend] (`mediapipe_cpu`, `mlkit`). */
    val backendId: String

    /** Loads the segmenter. Called once on the analysis thread; may throw. */
    fun open()

    /**
     * Segments [proxy] captured at [timestampMs] (camera clock, monotonic).
     * Invokes [completion] exactly once; never closes [proxy].
     */
    fun segment(
        proxy: ImageProxy,
        timestampMs: Long,
        completion: (DuetSegmentationOutcome) -> Unit,
    )

    /** Releases the segmenter. Idempotent; never throws. */
    fun close()
}
