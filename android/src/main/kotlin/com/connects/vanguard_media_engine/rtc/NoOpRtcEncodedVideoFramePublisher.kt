package com.connects.vanguard_media_engine.rtc

/**
 * Diagnostic no-op implementation of [RtcEncodedVideoFramePublisher] for unit testing and contract verification.
 *
 * ## Diagnostic & Video-Only Invariants
 * - **Diagnostic Only**: This publisher performs no actual network or WebRTC/LiveKit/RTMP transport encoding.
 * - **Video Only**: Operates strictly on [RtcEncodedVideoFrame] instances. Vanguard RTC video publishers
 *   have zero ownership of room signaling, network tokens, participant rosters, or audio streams.
 * - **No Buffer Retention**: Adheres strictly to the scoped-borrow contract of [RtcEncodedVideoFrame].
 *   This publisher does not retain references to [RtcEncodedVideoFrame.encodedData] after [publishFrame]
 *   returns and does not mutate the buffer position or limit.
 *
 * @param maxAcceptedFrames Maximum number of frames to accept before simulating downstream backpressure drops.
 * @param initiallyReady Initial readiness state of the publisher.
 */
class NoOpRtcEncodedVideoFramePublisher(
    private var maxAcceptedFrames: Long = Long.MAX_VALUE,
    private val initiallyReady: Boolean = true,
) : RtcEncodedVideoFramePublisher {

    constructor(maxAcceptedFrames: Int, initiallyReady: Boolean = true) :
        this(maxAcceptedFrames.toLong(), initiallyReady)

    private var isReady: Boolean = initiallyReady
    private var acceptedFrames: Long = 0L
    private var droppedBackpressureFrames: Long = 0L
    private var droppedNotReadyFrames: Long = 0L
    private var failedFrames: Long = 0L

    // First frame metadata
    private var firstPtsUs: Long = -1L
    private var firstDtsUs: Long = -1L
    private var firstFrameIndex: Long = -1L
    private var firstCodec: String? = null
    private var firstIsKeyFrame: Boolean? = null
    private var firstRemainingBytes: Int = -1

    // Last frame metadata
    private var lastPtsUs: Long = -1L
    private var lastDtsUs: Long = -1L
    private var lastFrameIndex: Long = -1L
    private var lastCodec: String? = null
    private var lastIsKeyFrame: Boolean? = null
    private var lastRemainingBytes: Int = -1

    /**
     * Updates the readiness state of this publisher.
     * When not ready, subsequent calls to [publishFrame] return [RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY].
     */
    @Synchronized
    fun setReady(ready: Boolean) {
        isReady = ready
    }

    /**
     * Updates the maximum accepted frames limit to simulate downstream backpressure.
     */
    @Synchronized
    fun setMaxAcceptedFrames(max: Long) {
        maxAcceptedFrames = max
    }

    /**
     * Returns whether this publisher is currently marked ready.
     */
    @Synchronized
    fun isReady(): Boolean = isReady

    /**
     * Publishes an [RtcEncodedVideoFrame] according to configured readiness and backpressure limits.
     * Does not retain or mutate [RtcEncodedVideoFrame.encodedData].
     */
    @Synchronized
    override fun publishFrame(frame: RtcEncodedVideoFrame): RtcVideoFrameDeliveryResult {
        if (!isReady) {
            droppedNotReadyFrames++
            return RtcVideoFrameDeliveryResult.droppedNotReady(
                "status=DROPPED_NOT_READY;reason=publisher_not_ready"
            )
        }

        if (acceptedFrames >= maxAcceptedFrames) {
            droppedBackpressureFrames++
            return RtcVideoFrameDeliveryResult.droppedBackpressure(
                "status=DROPPED_BACKPRESSURE;reason=maxAcceptedFrames_reached"
            )
        }

        acceptedFrames++
        val remaining = frame.encodedData.remaining()

        if (acceptedFrames == 1L) {
            firstPtsUs = frame.ptsUs
            firstDtsUs = frame.dtsUs
            firstFrameIndex = frame.frameIndex
            firstCodec = frame.codec
            firstIsKeyFrame = frame.isKeyFrame
            firstRemainingBytes = remaining
        }

        lastPtsUs = frame.ptsUs
        lastDtsUs = frame.dtsUs
        lastFrameIndex = frame.frameIndex
        lastCodec = frame.codec
        lastIsKeyFrame = frame.isKeyFrame
        lastRemainingBytes = remaining

        return RtcVideoFrameDeliveryResult.accepted(
            "status=ACCEPTED;frameIndex=${frame.frameIndex};ptsUs=${frame.ptsUs};isKeyFrame=${frame.isKeyFrame}"
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
        "firstPtsUs" to firstPtsUs,
        "firstDtsUs" to firstDtsUs,
        "firstFrameIndex" to firstFrameIndex,
        "firstCodec" to firstCodec,
        "firstIsKeyFrame" to firstIsKeyFrame,
        "firstRemainingBytes" to firstRemainingBytes,
        "lastPtsUs" to lastPtsUs,
        "lastDtsUs" to lastDtsUs,
        "lastFrameIndex" to lastFrameIndex,
        "lastCodec" to lastCodec,
        "lastIsKeyFrame" to lastIsKeyFrame,
        "lastRemainingBytes" to lastRemainingBytes,
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
        firstPtsUs = -1L
        firstDtsUs = -1L
        firstFrameIndex = -1L
        firstCodec = null
        firstIsKeyFrame = null
        firstRemainingBytes = -1
        lastPtsUs = -1L
        lastDtsUs = -1L
        lastFrameIndex = -1L
        lastCodec = null
        lastIsKeyFrame = null
        lastRemainingBytes = -1
    }
}
