package com.connects.vanguard_media_engine.duet

import java.nio.ByteBuffer

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Immutable owned mask contract for one segmentation result.
// -----------------------------------------------------------------------------
//
// The ML Kit SegmentationMask buffer is only valid for the duration of the
// onSuccess callback. AndroidDuetGreenScreenAdapter copies the raw bytes before
// returning, so callers outside the callback own the data safely.
//
// Fields:
//   - [maskBytes]  : single-channel float32 (values 0.0–1.0) or uint8 (0–255)
//                    copied out of the ML Kit buffer; ownership is this frame.
//   - [width]      : mask width in pixels.
//   - [height]     : mask height in pixels.
//   - [timestampMs]: System.currentTimeMillis() captured at analysis dispatch.
//   - [backend]    : which backend produced this mask (DuetSegmentationBackend.*).

/**
 * Immutable, self-owned segmentation mask from one analysis frame.
 *
 * The bytes are a direct copy made inside the ML Kit success callback before
 * the ImageProxy is closed. Callers may retain this object indefinitely.
 */
class AndroidDuetSegmentationFrame private constructor(
    /** Copied raw mask buffer — single channel, float32 LE, row-major. */
    val maskBytes: ByteBuffer,
    val width: Int,
    val height: Int,
    val timestampMs: Long,
    val backend: String,
) {
    companion object {
        /**
         * Factory: copies [source] (only [source.remaining()] bytes from the
         * current position) into a new heap-allocated direct ByteBuffer.
         * The [source] position is NOT advanced.
         */
        fun copyFrom(
            source: ByteBuffer,
            width: Int,
            height: Int,
            timestampMs: Long,
            backend: String,
        ): AndroidDuetSegmentationFrame {
            val bytes = ByteBuffer.allocateDirect(source.remaining())
            val savedPos = source.position()
            bytes.put(source)
            source.position(savedPos)
            bytes.rewind()
            return AndroidDuetSegmentationFrame(bytes, width, height, timestampMs, backend)
        }
    }

    override fun toString(): String =
        "AndroidDuetSegmentationFrame(${width}x${height} backend=$backend ts=$timestampMs bytes=${maskBytes.capacity()})"
}
