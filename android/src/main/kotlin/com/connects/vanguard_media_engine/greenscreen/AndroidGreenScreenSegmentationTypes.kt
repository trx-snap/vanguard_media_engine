package com.connects.vanguard_media_engine.greenscreen

import android.hardware.HardwareBuffer
import java.nio.ByteBuffer

// -----------------------------------------------------------------------------
// VG-GREEN-SCREEN: Neutral segmentation contract owned by the green-screen
// package.
// -----------------------------------------------------------------------------
//
// GreenScreen is an independent, reusable camera/effect transform capability
// (segmentation backend selection, mask contract, temporal smoothing) and must
// not be owned by the Duet multi-input compositor. These types are the
// dependency-direction foundation: the Duet package's equivalent identifiers
// (`AndroidDuetSegmentationFrame`, `DuetSegmentationMaskFormat`) are kept as
// source-compatible type aliases onto these neutral definitions so existing
// Duet call sites keep compiling without duet owning the contract.
//
// Byte-for-byte port of the previous duet-owned contract
// (`com.connects.vanguard_media_engine.duet.AndroidDuetSegmentationFrame` /
// `AndroidDuetSegmentationBackend.kt`); only the package and identifier names
// changed.

/** Segmentation backend identifiers shared by every green-screen segmentation ladder/allowlist. */
object AndroidGreenScreenSegmentationBackend {
    const val MEDIAPIPE_GPU = "mediapipe_gpu"
    const val MEDIAPIPE_GPU_GRAPH = "mediapipe_gpu_graph"
    const val MEDIAPIPE_CPU = "mediapipe_cpu"
    const val MLKIT = "mlkit"
    const val NONE = "none"
    /** Standalone TensorFlow Lite GPU delegate backend — debug/smoke opt-in only; not default primary. */
    const val RAW_TFLITE_GPU = "raw_tflite_gpu"
}

/**
 * Byte layout of [AndroidGreenScreenSegmentationFrame.maskBytes].
 *
 * - [FLOAT32_CONFIDENCE]: native-order float32 per pixel in [0, 1], stride 4.
 *   This is the ML Kit raw-mask layout and is preserved byte-identical.
 * - [UINT8_ALPHA]: one unsigned byte per pixel in [0, 255], stride 1, already
 *   scaled to GL LUMINANCE. Produced by the MediaPipe backend after converting
 *   a confidence (float32) or category (uint8 index) mask on the analysis
 *   thread, so the render thread uploads it as-is.
 */
enum class GreenScreenSegmentationMaskFormat(val key: String, val bytesPerPixel: Int) {
    FLOAT32_CONFIDENCE("float32_confidence", 4),
    UINT8_ALPHA("uint8_alpha", 1),
}

/**
 * Immutable, self-owned segmentation mask from one analysis frame.
 *
 * The bytes are owned by this frame (copied or converted before the source
 * image / backend result is released). Callers may retain this object
 * indefinitely and must treat [maskBytes] as read-only.
 */
class AndroidGreenScreenSegmentationFrame private constructor(
    /** Owned mask buffer — single channel, row-major, layout per [format]. */
    val maskBytes: ByteBuffer,
    val width: Int,
    val height: Int,
    val timestampMs: Long,
    val backend: String,
    val format: GreenScreenSegmentationMaskFormat,
) {
    companion object {
        /**
         * Factory: copies [source] (only [source.remaining()] bytes from the
         * current position) into a new direct ByteBuffer. The [source]
         * position is NOT advanced. [format] defaults to the ML Kit float32
         * layout so the existing ML Kit path stays byte-identical.
         */
        fun copyFrom(
            source: ByteBuffer,
            width: Int,
            height: Int,
            timestampMs: Long,
            backend: String,
            format: GreenScreenSegmentationMaskFormat = GreenScreenSegmentationMaskFormat.FLOAT32_CONFIDENCE,
        ): AndroidGreenScreenSegmentationFrame {
            val bytes = ByteBuffer.allocateDirect(source.remaining())
            val savedPos = source.position()
            bytes.put(source)
            source.position(savedPos)
            bytes.rewind()
            return AndroidGreenScreenSegmentationFrame(bytes, width, height, timestampMs, backend, format)
        }

        /**
         * Factory: adopts an already-owned direct buffer produced by a backend
         * conversion step (no additional copy). The caller must not retain or
         * mutate [ownedBytes] after this call. Validates that the buffer holds
         * at least width * height * bytesPerPixel bytes.
         */
        fun adoptOwned(
            ownedBytes: ByteBuffer,
            width: Int,
            height: Int,
            timestampMs: Long,
            backend: String,
            format: GreenScreenSegmentationMaskFormat,
        ): AndroidGreenScreenSegmentationFrame {
            val required = width.toLong() * height.toLong() * format.bytesPerPixel
            require(width > 0 && height > 0) { "Mask dimensions must be positive (${width}x$height)" }
            require(ownedBytes.capacity() >= required) {
                "Mask buffer too small for ${width}x$height ${format.key}: " +
                    "have ${ownedBytes.capacity()}, need $required"
            }
            ownedBytes.rewind()
            return AndroidGreenScreenSegmentationFrame(ownedBytes, width, height, timestampMs, backend, format)
        }
    }

    /** True when [maskBytes] holds at least one full mask for [width]x[height] in [format]. */
    val isComplete: Boolean
        get() = maskBytes.capacity() >= width.toLong() * height.toLong() * format.bytesPerPixel

    override fun toString(): String =
        "AndroidGreenScreenSegmentationFrame(${width}x${height} backend=$backend format=${format.key} " +
            "ts=$timestampMs bytes=${maskBytes.capacity()})"
}

/** Result of segmenting one analysis frame. */
sealed class GreenScreenSegmentationOutcome {
    /** A mask the caller may forward to a compositor/renderer. */
    class Mask(val frame: AndroidGreenScreenSegmentationFrame) : GreenScreenSegmentationOutcome()

    /**
     * A GPU-resident mask backed by an owned [HardwareBuffer], for a GPU segmentation backend
     * that produces its result directly on the GPU instead of a CPU-readable mask buffer.
     *
     * Ownership: the backend transfers ownership of [hardwareBuffer] to this outcome the moment
     * it is constructed and passed to `completion`. From that point, exactly one of the
     * following must happen to [hardwareBuffer]: it is handed off exactly once to a GPU mask
     * consumer that takes ownership, or it is closed directly by the caller if it is not in a
     * state to deliver it (stopped/terminal). No code path may both deliver and close it, and no
     * path may do neither. GPU masks never pass through [AndroidGreenScreenMaskTemporalSmoother];
     * temporal smoothing operates on CPU [Mask] frames only.
     */
    class GpuMask(
        val hardwareBuffer: HardwareBuffer,
        val widthPx: Int,
        val heightPx: Int,
        val timestampUs: Long,
    ) : GreenScreenSegmentationOutcome()

    /**
     * No mask for this frame, backend still healthy (e.g. no media image, or
     * the backend was closed while the frame was in flight). Never triggers
     * ladder movement.
     */
    class Skipped(val reason: String) : GreenScreenSegmentationOutcome()

    /**
     * Backend failure. The caller closes this backend and walks the ladder
     * downward (e.g. mediapipe_cpu -> mlkit -> none).
     */
    class Failure(
        val reason: String,
        val message: String,
        val cause: Throwable? = null,
    ) : GreenScreenSegmentationOutcome()
}

/**
 * Machine reason keys surfaced in degrade/fallback diagnostics.
 *
 * The `MEDIAPIPE_*` constants (no rung suffix) are the CPU-rung reasons. The
 * `MEDIAPIPE_GPU_*` constants are the GPU-rung equivalents. The
 * `RAW_TFLITE_GPU_*` constants cover the standalone TFLite GPU delegate rung.
 * The `*Failed`/`*Result`/`*Mismatch` helper functions pick the right constant
 * for whichever rung reports the failure.
 */
object GreenScreenSegmentationFailureReason {
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

    /** Reason when a backend's `segment` throws synchronously. */
    fun segmentThrew(backendId: String): String = "${backendId}_segment_threw"

    /** Reason when a backend's `open` throws. */
    fun initFailed(backendId: String): String = when (backendId) {
        AndroidGreenScreenSegmentationBackend.MEDIAPIPE_GPU  -> MEDIAPIPE_GPU_INIT_FAILED
        AndroidGreenScreenSegmentationBackend.MEDIAPIPE_GPU_GRAPH -> "${backendId}_init_failed"
        AndroidGreenScreenSegmentationBackend.MEDIAPIPE_CPU  -> MEDIAPIPE_INIT_FAILED
        AndroidGreenScreenSegmentationBackend.MLKIT          -> MLKIT_INIT_FAILED
        AndroidGreenScreenSegmentationBackend.RAW_TFLITE_GPU -> RAW_TFLITE_GPU_INIT_FAILED
        else                                                 -> "${backendId}_init_failed"
    }

    /** Reason when image -> Bitmap conversion fails on a MediaPipe or TFLite rung. */
    fun frameConvertFailed(backendId: String): String = when (backendId) {
        AndroidGreenScreenSegmentationBackend.MEDIAPIPE_GPU  -> MEDIAPIPE_GPU_FRAME_CONVERT_FAILED
        AndroidGreenScreenSegmentationBackend.MEDIAPIPE_GPU_GRAPH -> "${backendId}_frame_convert_failed"
        AndroidGreenScreenSegmentationBackend.RAW_TFLITE_GPU -> RAW_TFLITE_GPU_FRAME_CONVERT_FAILED
        else                                                 -> MEDIAPIPE_FRAME_CONVERT_FAILED
    }

    /** Reason when inference throws on a segmentation rung. */
    fun inferenceFailed(backendId: String): String = when (backendId) {
        AndroidGreenScreenSegmentationBackend.MEDIAPIPE_GPU  -> MEDIAPIPE_GPU_INFERENCE_FAILED
        AndroidGreenScreenSegmentationBackend.MEDIAPIPE_GPU_GRAPH -> "${backendId}_inference_failed"
        AndroidGreenScreenSegmentationBackend.RAW_TFLITE_GPU -> RAW_TFLITE_GPU_INFERENCE_FAILED
        else                                                 -> MEDIAPIPE_INFERENCE_FAILED
    }

    /** Reason when a rung returns no confidence masks / empty output. */
    fun emptyResult(backendId: String): String = when (backendId) {
        AndroidGreenScreenSegmentationBackend.MEDIAPIPE_GPU  -> MEDIAPIPE_GPU_EMPTY_RESULT
        AndroidGreenScreenSegmentationBackend.RAW_TFLITE_GPU -> RAW_TFLITE_GPU_EMPTY_RESULT
        else                                                 -> MEDIAPIPE_EMPTY_RESULT
    }

    /** Reason when a rung's output mask dimensions/buffer are invalid. */
    fun maskSizeMismatch(backendId: String): String = when (backendId) {
        AndroidGreenScreenSegmentationBackend.MEDIAPIPE_GPU  -> MEDIAPIPE_GPU_MASK_SIZE_MISMATCH
        AndroidGreenScreenSegmentationBackend.RAW_TFLITE_GPU -> RAW_TFLITE_GPU_MASK_SIZE_MISMATCH
        else                                                 -> MEDIAPIPE_MASK_SIZE_MISMATCH
    }
}
