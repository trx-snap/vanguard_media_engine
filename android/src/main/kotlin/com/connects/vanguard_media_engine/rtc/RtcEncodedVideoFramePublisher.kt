package com.connects.vanguard_media_engine.rtc

/**
 * Functional interface for publishing encoded egress video frames from the Vanguard True-DAG engine
 * into an RTC real-time transport pipeline or network publisher.
 *
 * ## Transport Abstraction
 * This contract is a pure transport abstraction. Concrete implementations in future phases
 * may adapt frames to WebRTC, LiveKit, RTMP, or diagnostic loopback pipelines.
 *
 * ## Ownership & Boundary Invariants
 * - **Video Only**: This publisher handles encoded video frames exclusively.
 * - **No Room / Audio Ownership**: Room lifecycle, signaling tokens, ICE state, participant
 *   rosters, and audio tracks are managed entirely outside Vanguard in the application layer.
 * - **Scoped-Borrow Contract**: Implementations must adhere to the scoped-borrow contract of
 *   [RtcEncodedVideoFrame]. Publishers must NOT retain references to [RtcEncodedVideoFrame.encodedData]
 *   after [publishFrame] returns and must NOT mutate the buffer position or limit.
 */
fun interface RtcEncodedVideoFramePublisher {
    /**
     * Publishes an encoded [RtcEncodedVideoFrame] to the underlying transport publisher.
     *
     * @param frame The encoded video frame snapshot under scoped-borrow semantics.
     * @return [RtcVideoFrameDeliveryResult] indicating acceptance, backpressure drop, or failure.
     */
    fun publishFrame(frame: RtcEncodedVideoFrame): RtcVideoFrameDeliveryResult
}
