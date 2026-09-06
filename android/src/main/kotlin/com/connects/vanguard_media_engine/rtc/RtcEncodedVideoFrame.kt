package com.connects.vanguard_media_engine.rtc

import java.nio.ByteBuffer

/**
 * Envelope carrying an encoded video frame snapshot from Vanguard True-DAG pipeline
 * for egress transport publishing.
 *
 * ## Scoped-Borrow Semantics
 * - **Caller-Owned Buffer**: [encodedData] is owned by the caller/producing pipeline.
 * - **No Retention**: Downstream publishers and adapters must NOT retain references to [encodedData]
 *   after frame delivery returns.
 * - **No Mutation**: Publishers and adapters must NOT mutate the [ByteBuffer.position],
 *   [ByteBuffer.limit], or underlying bytes of [encodedData].
 * - **Video Only**: Encapsulates encoded video payload exclusively. No audio data, room signaling,
 *   or transport session state.
 *
 * @property encodedData Direct or heap [ByteBuffer] containing encoded NALU/frame bytes. Must have remaining bytes.
 * @property codec Codec identifier string (e.g., "video/avc", "video/hevc", "video/x-vnd.on2.vp8", "video/x-vnd.on2.vp9", "video/av01"). Must not be blank.
 * @property isKeyFrame True if this frame is an IDR / keyframe; false for delta/P/B frames.
 * @property ptsUs Presentation timestamp in microseconds (nonnegative).
 * @property dtsUs Decode timestamp in microseconds (nonnegative).
 * @property frameIndex Monotonically increasing 0-based frame counter (nonnegative).
 */
data class RtcEncodedVideoFrame(
    val encodedData: ByteBuffer,
    val codec: String,
    val isKeyFrame: Boolean,
    val ptsUs: Long,
    val dtsUs: Long,
    val frameIndex: Long,
) {
    init {
        require(codec.isNotBlank()) { "codec must not be blank" }
        require(encodedData.remaining() > 0) {
            "encodedData must have remaining bytes (remaining=${encodedData.remaining()})"
        }
        require(ptsUs >= 0L) { "ptsUs must be nonnegative (ptsUs=$ptsUs)" }
        require(dtsUs >= 0L) { "dtsUs must be nonnegative (dtsUs=$dtsUs)" }
        require(frameIndex >= 0L) { "frameIndex must be nonnegative (frameIndex=$frameIndex)" }
    }

    override fun toString(): String =
        "RtcEncodedVideoFrame(codec=$codec, isKeyFrame=$isKeyFrame, ptsUs=$ptsUs, dtsUs=$dtsUs, " +
            "frameIndex=$frameIndex, remainingBytes=${encodedData.remaining()})"
}
