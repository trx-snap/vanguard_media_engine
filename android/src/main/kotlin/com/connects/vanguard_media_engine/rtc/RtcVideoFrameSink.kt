package com.connects.vanguard_media_engine.rtc

/**
 * Functional interface for ingesting incoming remote RTC video frames into the Vanguard True-DAG engine.
 *
 * ## DAG Ingress Seam
 * This sink receives remote RTC video frames from transport adapters and forwards them into
 * the Vanguard True-DAG processing pipeline (e.g. C++ `StreamSourceNode`) for filtering,
 * spatial transformation, composition, and presentation.
 *
 * ## Ownership & Boundary Invariants
 * - **No Direct Display**: This interface does not directly render to display surfaces; frames
 *   are scheduled through DAG graph topology for generation-aware playhead evaluation.
 * - **No Audio**: Audio tracks from remote participants are managed and routed entirely
 *   outside Vanguard by the host application (ConnectsApp).
 * - **Scoped Borrow**: Implementations must adhere to the scoped-borrow semantics of [RealtimeVideoFrame].
 */
fun interface RtcVideoFrameSink {
    /**
     * Ingests an incoming remote [RealtimeVideoFrame] into the Vanguard DAG pipeline.
     *
     * @param frame The remote video frame snapshot under scoped-borrow semantics.
     * @return [RtcVideoFrameDeliveryResult] indicating acceptance, congestion drop, or failure.
     */
    fun onFrame(frame: RealtimeVideoFrame): RtcVideoFrameDeliveryResult
}
