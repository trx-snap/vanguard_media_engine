package com.connects.vanguard_media_engine.rtc

/**
 * Diagnostic no-op implementation of [RtcVideoFramePublisher] for unit testing and contract verification.
 *
 * ## Diagnostic & Video-Only Invariants
 * - **Diagnostic Only**: This publisher performs no actual network or WebRTC/LiveKit transport encoding.
 * - **Video Only**: Operates strictly on [RealtimeVideoFrame] instances. Vanguard RTC video publishers
 *   have zero ownership of room signaling, network tokens, participant rosters, or audio streams.
 *   Room orchestration and audio capture/mixing are strictly forbidden in Vanguard.
 * - **No Buffer Retention or Closure**: Adheres strictly to the scoped-borrow contract of [RealtimeVideoFrame].
 *   This publisher does not retain references to [RealtimeVideoFrame.hardwareBuffer] after [publishFrame]
 *   returns and never closes the underlying hardware buffer.
 *
 * @param maxAcceptedFrames Maximum number of frames to accept before simulating downstream backpressure drops.
 * @param initiallyReady Initial readiness state of the publisher.
 */
class NoOpRtcVideoFramePublisher(
    private val maxAcceptedFrames: Int = Int.MAX_VALUE,
    private val initiallyReady: Boolean = true,
) : RtcVideoFramePublisher {

    private var isReady: Boolean = initiallyReady
    private var acceptedFrames: Long = 0L
    private var droppedBackpressureFrames: Long = 0L
    private var droppedNotReadyFrames: Long = 0L
    private var failedFrames: Long = 0L
    private var lastTimestampNs: Long = -1L
    private var lastFrameIndex: Long = -1L

    /**
     * Updates the readiness state of this publisher.
     *
     * When not ready, subsequent calls to [publishFrame] will return [RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY].
     */
    @Synchronized
    fun setReady(ready: Boolean) {
        isReady = ready
    }

    /**
     * Returns whether this publisher is currently marked ready.
     */
    @Synchronized
    fun isReady(): Boolean = isReady

    /**
     * Publishes a [RealtimeVideoFrame] according to the configured readiness and backpressure limits.
     *
     * Does not retain or close [RealtimeVideoFrame.hardwareBuffer].
     */
    @Synchronized
    override fun publishFrame(frame: RealtimeVideoFrame): RtcVideoFrameDeliveryResult {
        if (!isReady) {
            droppedNotReadyFrames++
            return RtcVideoFrameDeliveryResult.droppedNotReady(
                "status=DROPPED_NOT_READY;reason=publisher_not_ready"
            )
        }

        if (acceptedFrames >= maxAcceptedFrames.toLong()) {
            droppedBackpressureFrames++
            return RtcVideoFrameDeliveryResult.droppedBackpressure(
                "status=DROPPED_BACKPRESSURE;reason=maxAcceptedFrames_reached"
            )
        }

        acceptedFrames++
        lastTimestampNs = frame.timestampNs
        lastFrameIndex = frame.frameIndex

        return RtcVideoFrameDeliveryResult.accepted(
            "status=ACCEPTED;frameIndex=${frame.frameIndex};timestampNs=${frame.timestampNs}"
        )
    }

    /**
     * Records a simulated delivery failure for diagnostic tracking.
     */
    @Synchronized
    fun recordFailure() {
        failedFrames++
    }

    /**
     * Returns an immutable snapshot map of all internal counters and state.
     */
    @Synchronized
    fun snapshot(): Map<String, Any?> = mapOf(
        "ready" to isReady,
        "maxAcceptedFrames" to maxAcceptedFrames,
        "acceptedFrames" to acceptedFrames,
        "droppedBackpressureFrames" to droppedBackpressureFrames,
        "droppedNotReadyFrames" to droppedNotReadyFrames,
        "failedFrames" to failedFrames,
        "lastTimestampNs" to lastTimestampNs,
        "lastFrameIndex" to lastFrameIndex,
    )

    /**
     * Resets all internal counters to zero and restores readiness to [initiallyReady].
     */
    @Synchronized
    fun reset() {
        isReady = initiallyReady
        acceptedFrames = 0L
        droppedBackpressureFrames = 0L
        droppedNotReadyFrames = 0L
        failedFrames = 0L
        lastTimestampNs = -1L
        lastFrameIndex = -1L
    }
}
