package com.connects.vanguard_media_engine.rtc

/**
 * Functional interface for publishing egress video frames from the Vanguard True-DAG engine
 * into an RTC real-time transport pipeline.
 *
 * ## Transport Abstraction
 * This contract is a pure transport abstraction. Concrete implementations in future phases
 * may adapt frames to LiveKit (`VideoSource.capturerObserver`), raw WebRTC (`CapturerObserver`),
 * or diagnostic loopback pipelines.
 *
 * ## Ownership & Boundary Invariants
 * - **Video Only**: This publisher handles video frames exclusively.
 * - **No Room / Audio Ownership**: Room lifecycle, signaling tokens, ICE state, participant
 *   rosters, and audio tracks are managed entirely outside Vanguard in the application layer.
 * - **Non-blocking / Scoped Borrow**: Implementations must be non-blocking and adhere to the
 *   scoped-borrow semantics of [RealtimeVideoFrame].
 */
fun interface RtcVideoFramePublisher {
    /**
     * Publishes a processed [RealtimeVideoFrame] to the underlying RTC transport pipeline.
     *
     * @param frame The video frame snapshot under scoped-borrow semantics.
     * @return [RtcVideoFrameDeliveryResult] indicating acceptance, backpressure drop, or failure.
     */
    fun publishFrame(frame: RealtimeVideoFrame): RtcVideoFrameDeliveryResult
}
