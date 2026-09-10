package com.connects.vanguard_media_engine.duet

import androidx.camera.core.ImageProxy

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Segmentation backend seam behind the single CameraX
// analyzer facade (AndroidDuetGreenScreenAdapter).
// -----------------------------------------------------------------------------
//
// One backend instance == one live segmenter. The adapter owns the production
// ladder (mediapipe_cpu -> mlkit -> none/PiP), the single-in-flight gate and
// every ImageProxy close; backends only turn one ImageProxy into one outcome.
// mediapipe_gpu is not part of the production ladder (physical proof on
// SM-A566B showed a native SIGABRT during GPU result conversion); it remains
// latent/experimental — see AndroidDuetSegmentationBackendSelector.
//
// Contract for implementations:
//   - [open] is called once, from the adapter's analysis thread, before the
//     first [segment]. It must block the calling thread until the backend is
//     actually ready (or definitively failed) — implementations that own a
//     dedicated lifecycle thread (e.g. MediaPipe) block the caller on that
//     thread's creation work. It may throw; a throw means "this backend is
//     unavailable" and the adapter walks the ladder.
//   - [segment] must invoke [completion] exactly once, synchronously or
//     asynchronously (e.g. on an owned worker thread), and must never close
//     [proxy]. The proxy stays valid until [completion] is invoked; the
//     backend must not touch it afterwards.
//   - [close] is idempotent, never throws, and may be called from any thread
//     (main thread on stop / layout switch / dispose, analysis thread on
//     degradation, or an owned worker thread during its own failure handling).
//     After [close], any late [segment] call must complete with
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

/**
 * Machine reason keys surfaced in `green_screen_degraded` / `green_screen_fallback`.
 *
 * The `MEDIAPIPE_*` constants (no rung suffix) are the CPU-rung reasons and are
 * kept byte-for-byte for backward compatibility with existing consumers. The
 * `MEDIAPIPE_GPU_*` constants are the GPU-rung equivalents added for the
 * `mediapipe_gpu` rung. The `*Failed`/`*Result`/`*Mismatch` helper functions
 * pick the right constant for whichever MediaPipe rung reports the failure.
 */
object DuetSegmentationFailureReason {
    const val MEDIAPIPE_INIT_FAILED          = "mediapipe_init_failed"
    const val MEDIAPIPE_INFERENCE_FAILED     = "mediapipe_inference_failed"
    const val MEDIAPIPE_FRAME_CONVERT_FAILED = "mediapipe_frame_convert_failed"
    const val MEDIAPIPE_EMPTY_RESULT         = "mediapipe_empty_result"
    const val MEDIAPIPE_MASK_SIZE_MISMATCH   = "mediapipe_mask_size_mismatch"

    const val MEDIAPIPE_GPU_INIT_FAILED          = "mediapipe_gpu_init_failed"
    const val MEDIAPIPE_GPU_INFERENCE_FAILED     = "mediapipe_gpu_inference_failed"
    const val MEDIAPIPE_GPU_FRAME_CONVERT_FAILED = "mediapipe_gpu_frame_convert_failed"
    const val MEDIAPIPE_GPU_EMPTY_RESULT         = "mediapipe_gpu_empty_result"
    const val MEDIAPIPE_GPU_MASK_SIZE_MISMATCH   = "mediapipe_gpu_mask_size_mismatch"

    const val MLKIT_INIT_FAILED              = "mlkit_init_failed"
    const val MLKIT_FAILURE                  = "mlkit_failure"

    /** Reason when a backend's [AndroidDuetSegmentationBackend.segment] throws synchronously. */
    fun segmentThrew(backendId: String): String = "${backendId}_segment_threw"

    /** Reason when a backend's [AndroidDuetSegmentationBackend.open] throws. */
    fun initFailed(backendId: String): String = when (backendId) {
        DuetSegmentationBackend.MEDIAPIPE_GPU -> MEDIAPIPE_GPU_INIT_FAILED
        DuetSegmentationBackend.MEDIAPIPE_CPU -> MEDIAPIPE_INIT_FAILED
        DuetSegmentationBackend.MLKIT         -> MLKIT_INIT_FAILED
        else                                  -> "${backendId}_init_failed"
    }

    /** Reason when [ImageProxy] -> Bitmap/MPImage conversion fails on a MediaPipe rung. */
    fun frameConvertFailed(backendId: String): String =
        if (backendId == DuetSegmentationBackend.MEDIAPIPE_GPU) MEDIAPIPE_GPU_FRAME_CONVERT_FAILED
        else MEDIAPIPE_FRAME_CONVERT_FAILED

    /** Reason when `ImageSegmenter.segmentForVideo` throws on a MediaPipe rung. */
    fun inferenceFailed(backendId: String): String =
        if (backendId == DuetSegmentationBackend.MEDIAPIPE_GPU) MEDIAPIPE_GPU_INFERENCE_FAILED
        else MEDIAPIPE_INFERENCE_FAILED

    /** Reason when a MediaPipe rung returns no confidence masks. */
    fun emptyResult(backendId: String): String =
        if (backendId == DuetSegmentationBackend.MEDIAPIPE_GPU) MEDIAPIPE_GPU_EMPTY_RESULT
        else MEDIAPIPE_EMPTY_RESULT

    /** Reason when a MediaPipe rung's confidence mask dimensions/buffer are invalid. */
    fun maskSizeMismatch(backendId: String): String =
        if (backendId == DuetSegmentationBackend.MEDIAPIPE_GPU) MEDIAPIPE_GPU_MASK_SIZE_MISMATCH
        else MEDIAPIPE_MASK_SIZE_MISMATCH
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
