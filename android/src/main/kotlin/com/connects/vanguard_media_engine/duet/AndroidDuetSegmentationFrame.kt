package com.connects.vanguard_media_engine.duet

import java.nio.ByteBuffer

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Immutable owned mask contract for one segmentation result.
// -----------------------------------------------------------------------------
//
// Backend buffers (ML Kit SegmentationMask, MediaPipe MPImage) are only valid
// inside the producing callback / until the result is closed. Every backend
// copies or converts the mask into a frame it owns before handing it to the
// adapter, so callers outside the callback own the data safely.
//
// Fields:
//   - [maskBytes]  : single-channel mask, row-major, layout described by [format].
//   - [width]      : mask width in pixels.
//   - [height]     : mask height in pixels.
//   - [timestampMs]: camera frame timestamp (ImageInfo.timestamp / 1e6),
//                    monotonic per adapter run.
//   - [backend]    : which backend produced this mask (DuetSegmentationBackend.*).
//   - [format]     : byte layout discriminator (see [DuetSegmentationMaskFormat]).
//                    The compositor MUST dispatch its upload on this value;
//                    the two layouts differ in stride and must never be
//                    interpreted as one another.

/**
 * Byte layout of [AndroidDuetSegmentationFrame.maskBytes].
 *
 * - [FLOAT32_CONFIDENCE]: native-order float32 per pixel in [0, 1], stride 4.
 *   This is the ML Kit raw-mask layout and is preserved byte-identical.
 * - [UINT8_ALPHA]: one unsigned byte per pixel in [0, 255], stride 1, already
 *   scaled to GL LUMINANCE. Produced by the MediaPipe backend after converting
 *   a confidence (float32) or category (uint8 index) mask on the analysis
 *   thread, so the render thread uploads it as-is.
 */
enum class DuetSegmentationMaskFormat(val key: String, val bytesPerPixel: Int) {
    FLOAT32_CONFIDENCE("float32_confidence", 4),
    UINT8_ALPHA("uint8_alpha", 1),
}

/**
 * Immutable, self-owned segmentation mask from one analysis frame.
 *
 * The bytes are owned by this frame (copied or converted before the source
 * ImageProxy / backend result is released). Callers may retain this object
 * indefinitely and must treat [maskBytes] as read-only.
 */
class AndroidDuetSegmentationFrame private constructor(
    /** Owned mask buffer — single channel, row-major, layout per [format]. */
    val maskBytes: ByteBuffer,
    val width: Int,
    val height: Int,
    val timestampMs: Long,
    val backend: String,
    val format: DuetSegmentationMaskFormat,
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
            format: DuetSegmentationMaskFormat = DuetSegmentationMaskFormat.FLOAT32_CONFIDENCE,
        ): AndroidDuetSegmentationFrame {
            val bytes = ByteBuffer.allocateDirect(source.remaining())
            val savedPos = source.position()
            bytes.put(source)
            source.position(savedPos)
            bytes.rewind()
            return AndroidDuetSegmentationFrame(bytes, width, height, timestampMs, backend, format)
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
            format: DuetSegmentationMaskFormat,
        ): AndroidDuetSegmentationFrame {
            val required = width.toLong() * height.toLong() * format.bytesPerPixel
            require(width > 0 && height > 0) { "Mask dimensions must be positive (${width}x$height)" }
            require(ownedBytes.capacity() >= required) {
                "Mask buffer too small for ${width}x$height ${format.key}: " +
                    "have ${ownedBytes.capacity()}, need $required"
            }
            ownedBytes.rewind()
            return AndroidDuetSegmentationFrame(ownedBytes, width, height, timestampMs, backend, format)
        }
    }

    /** True when [maskBytes] holds at least one full mask for [width]x[height] in [format]. */
    val isComplete: Boolean
        get() = maskBytes.capacity() >= width.toLong() * height.toLong() * format.bytesPerPixel

    override fun toString(): String =
        "AndroidDuetSegmentationFrame(${width}x${height} backend=$backend format=${format.key} " +
            "ts=$timestampMs bytes=${maskBytes.capacity()})"
}
