package com.connects.vanguard_media_engine.duet

import android.hardware.HardwareBuffer
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
     * A GPU-resident mask backed by an owned [HardwareBuffer], for a future
     * GPU segmentation backend (e.g. a MediaPipe GPU graph) that produces its
     * result directly on the GPU instead of a CPU-readable mask buffer.
     *
     * Ownership: the backend transfers ownership of [hardwareBuffer] to this
     * outcome the moment it is constructed and passed to `completion`. From
     * that point, exactly one of the following must happen to [hardwareBuffer]:
     *   - it is handed off exactly once to
     *     [AndroidDuetGreenScreenAdapter]'s `onGpuMask` callback (which in turn
     *     hands it to [AndroidDuetPreviewRenderLoop.updateGreenScreenMaskHardwareBuffer],
     *     which always takes ownership — closing it itself on every
     *     stopped/failed-post path), or
     *   - it is closed directly by the adapter if the adapter is not in a
     *     state to deliver it (stopped/terminal).
     * No code path may both deliver and close it, and no path may do neither.
     * GPU masks never pass through [AndroidDuetMaskTemporalSmoother]; temporal
     * smoothing operates on CPU [Mask] frames only.
     */
    class GpuMask(
        val hardwareBuffer: HardwareBuffer,
        val widthPx: Int,
        val heightPx: Int,
        val timestampUs: Long,
    ) : DuetSegmentationOutcome()

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
 * `mediapipe_gpu` rung. The `RAW_TFLITE_GPU_*` constants cover the new
 * standalone TFLite GPU delegate rung. The `*Failed`/`*Result`/`*Mismatch`
 * helper functions pick the right constant for whichever rung reports the failure.
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

    // ── raw_tflite_gpu rung reasons ───────────────────────────────────────────
    const val RAW_TFLITE_GPU_INIT_FAILED          = "raw_tflite_gpu_init_failed"
    const val RAW_TFLITE_GPU_INFERENCE_FAILED     = "raw_tflite_gpu_inference_failed"
    const val RAW_TFLITE_GPU_FRAME_CONVERT_FAILED = "raw_tflite_gpu_frame_convert_failed"
    const val RAW_TFLITE_GPU_EMPTY_RESULT         = "raw_tflite_gpu_empty_result"
    const val RAW_TFLITE_GPU_MASK_SIZE_MISMATCH   = "raw_tflite_gpu_mask_size_mismatch"
    const val RAW_TFLITE_GPU_TENSOR_MISMATCH      = "raw_tflite_gpu_tensor_mismatch"

    /** Reason when a backend's [AndroidDuetSegmentationBackend.segment] throws synchronously. */
    fun segmentThrew(backendId: String): String = "${backendId}_segment_threw"

    /** Reason when a backend's [AndroidDuetSegmentationBackend.open] throws. */
    fun initFailed(backendId: String): String = when (backendId) {
        DuetSegmentationBackend.MEDIAPIPE_GPU  -> MEDIAPIPE_GPU_INIT_FAILED
        DuetSegmentationBackend.MEDIAPIPE_GPU_GRAPH -> "${backendId}_init_failed"
        DuetSegmentationBackend.MEDIAPIPE_CPU  -> MEDIAPIPE_INIT_FAILED
        DuetSegmentationBackend.MLKIT          -> MLKIT_INIT_FAILED
        DuetSegmentationBackend.RAW_TFLITE_GPU -> RAW_TFLITE_GPU_INIT_FAILED
        else                                   -> "${backendId}_init_failed"
    }

    /** Reason when [ImageProxy] -> Bitmap conversion fails on a MediaPipe or TFLite rung. */
    fun frameConvertFailed(backendId: String): String = when (backendId) {
        DuetSegmentationBackend.MEDIAPIPE_GPU  -> MEDIAPIPE_GPU_FRAME_CONVERT_FAILED
        DuetSegmentationBackend.MEDIAPIPE_GPU_GRAPH -> "${backendId}_frame_convert_failed"
        DuetSegmentationBackend.RAW_TFLITE_GPU -> RAW_TFLITE_GPU_FRAME_CONVERT_FAILED
        else                                   -> MEDIAPIPE_FRAME_CONVERT_FAILED
    }

    /** Reason when inference throws on a segmentation rung. */
    fun inferenceFailed(backendId: String): String = when (backendId) {
        DuetSegmentationBackend.MEDIAPIPE_GPU  -> MEDIAPIPE_GPU_INFERENCE_FAILED
        DuetSegmentationBackend.MEDIAPIPE_GPU_GRAPH -> "${backendId}_inference_failed"
        DuetSegmentationBackend.RAW_TFLITE_GPU -> RAW_TFLITE_GPU_INFERENCE_FAILED
        else                                   -> MEDIAPIPE_INFERENCE_FAILED
    }

    /** Reason when a rung returns no confidence masks / empty output. */
    fun emptyResult(backendId: String): String = when (backendId) {
        DuetSegmentationBackend.MEDIAPIPE_GPU  -> MEDIAPIPE_GPU_EMPTY_RESULT
        DuetSegmentationBackend.RAW_TFLITE_GPU -> RAW_TFLITE_GPU_EMPTY_RESULT
        else                                   -> MEDIAPIPE_EMPTY_RESULT
    }

    /** Reason when a rung's output mask dimensions/buffer are invalid. */
    fun maskSizeMismatch(backendId: String): String = when (backendId) {
        DuetSegmentationBackend.MEDIAPIPE_GPU  -> MEDIAPIPE_GPU_MASK_SIZE_MISMATCH
        DuetSegmentationBackend.RAW_TFLITE_GPU -> RAW_TFLITE_GPU_MASK_SIZE_MISMATCH
        else                                   -> MEDIAPIPE_MASK_SIZE_MISMATCH
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
