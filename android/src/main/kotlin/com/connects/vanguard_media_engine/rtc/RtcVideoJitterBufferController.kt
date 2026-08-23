package com.connects.vanguard_media_engine.rtc

/**
 * Status taxonomy for real-time video jitter buffer decisions.
 */
enum class RtcVideoJitterDecisionStatus {
    /**
     * Frame arrived within the valid playout timing window and monotonic sequence.
     */
    ACCEPTED,

    /**
     * Frame arrived past its target playout time plus maximum late threshold and was dropped.
     */
    DROPPED_LATE,

    /**
     * Frame arrived with an older sequence index or older timestamp than accepted history and was dropped.
     */
    DROPPED_OUT_OF_ORDER,

    /**
     * Frame has already been accepted (identical sequence index or timestamp) and was dropped as a duplicate.
     */
    DROPPED_DUPLICATE,

    /**
     * Evaluation failed due to invalid arguments (e.g. negative timestamp) or unrecoverable timing anomaly.
     */
    FAILED,
}

/**
 * Result data class for [RtcVideoJitterBufferController] evaluation.
 *
 * @param status Evaluation verdict.
 * @param raw Diagnostic details string.
 * @param retryable Whether a failed frame evaluation may be retried or indicates a transient condition.
 */
data class RtcVideoJitterDecision(
    val status: RtcVideoJitterDecisionStatus,
    val raw: String,
    val retryable: Boolean = false,
) {
    val accepted: Boolean
        get() = status == RtcVideoJitterDecisionStatus.ACCEPTED

    companion object {
        fun accepted(raw: String = "status=ACCEPTED"): RtcVideoJitterDecision =
            RtcVideoJitterDecision(status = RtcVideoJitterDecisionStatus.ACCEPTED, raw = raw)

        fun droppedLate(raw: String = "status=DROPPED_LATE"): RtcVideoJitterDecision =
            RtcVideoJitterDecision(status = RtcVideoJitterDecisionStatus.DROPPED_LATE, raw = raw)

        fun droppedOutOfOrder(raw: String = "status=DROPPED_OUT_OF_ORDER"): RtcVideoJitterDecision =
            RtcVideoJitterDecision(status = RtcVideoJitterDecisionStatus.DROPPED_OUT_OF_ORDER, raw = raw)

        fun droppedDuplicate(raw: String = "status=DROPPED_DUPLICATE"): RtcVideoJitterDecision =
            RtcVideoJitterDecision(status = RtcVideoJitterDecisionStatus.DROPPED_DUPLICATE, raw = raw)

        fun failed(reason: String, retryable: Boolean = false): RtcVideoJitterDecision =
            RtcVideoJitterDecision(
                status = RtcVideoJitterDecisionStatus.FAILED,
                raw = "status=FAILED;reason=$reason",
                retryable = retryable,
            )
    }
}

/**
 * Video-only, metadata-only jitter buffer controller for modeling real-time video frame timing,
 * playout delay budgeting, late drop thresholds, and sequence ordering.
 *
 * ## Official Android & Media3 Design Baseline
 * - **Metadata-Only / Zero Frame Retention**: Per official Android ImageReader documentation,
 *   holding unreleased Image/HardwareBuffer handles exhausts buffer queues and stalls video producers.
 *   This controller operates strictly on numeric timestamps and sequence metadata; it never imports,
 *   accepts, retains, or closes HardwareBuffer or Image objects.
 * - **Media3 Live Offset Model**: Models live timeline offset, playout delay, late threshold drops,
 *   and future timestamp bounds without claiming real Media3 or WebRTC transport integration.
 * - **Video-Only Domain Invariant**: Zero ownership of room signaling, tokens, participants,
 *   active speaker detection, audio routing, or audio mixing.
 * - **Thread-Safe**: All state mutations and telemetry reads are synchronized for safe multi-threaded execution.
 *
 * @param targetPlayoutDelayNs Target delay buffer in nanoseconds added to frame timestamp for playout scheduling (default 66.6ms).
 * @param maxLateThresholdNs Maximum allowed lateness in nanoseconds past target playout time before frame is dropped (default 100ms).
 * @param maxFutureThresholdNs Maximum allowed lead time in nanoseconds ahead of current arrival time before frame fails (default 250ms).
 */
class RtcVideoJitterBufferController(
    val targetPlayoutDelayNs: Long = 66_666_666L,
    val maxLateThresholdNs: Long = 100_000_000L,
    val maxFutureThresholdNs: Long = 250_000_000L,
) {
    init {
        require(targetPlayoutDelayNs > 0L) {
            "targetPlayoutDelayNs must be > 0, got $targetPlayoutDelayNs"
        }
        require(maxLateThresholdNs > 0L) {
            "maxLateThresholdNs must be > 0, got $maxLateThresholdNs"
        }
        require(maxFutureThresholdNs > 0L) {
            "maxFutureThresholdNs must be > 0, got $maxFutureThresholdNs"
        }
    }

    private var acceptedFrames: Long = 0L
    private var droppedLateFrames: Long = 0L
    private var droppedOutOfOrderFrames: Long = 0L
    private var droppedDuplicateFrames: Long = 0L
    private var failedFrames: Long = 0L
    private var lastAcceptedFrameIndex: Long? = null
    private var lastAcceptedTimestampNs: Long? = null
    private var lastSeenFrameIndex: Long? = null

    /**
     * Evaluates whether a video frame identified by [frameIndex] and [timestampNs] arriving at [arrivalTimeNs]
     * can be accepted for playout scheduling.
     *
     * @param frameIndex Non-negative sequential frame identifier.
     * @param timestampNs Non-negative presentation timestamp in nanoseconds.
     * @param arrivalTimeNs Non-negative local arrival timestamp in nanoseconds.
     * @return [RtcVideoJitterDecision] indicating accept/drop/fail status with diagnostic telemetry.
     */
    @Synchronized
    fun evaluate(frameIndex: Long, timestampNs: Long, arrivalTimeNs: Long): RtcVideoJitterDecision {
        if (frameIndex < 0L || timestampNs < 0L || arrivalTimeNs < 0L) {
            failedFrames++
            return RtcVideoJitterDecision.failed(
                reason = "invalid_negative_argument: frameIndex=$frameIndex, timestampNs=$timestampNs, arrivalTimeNs=$arrivalTimeNs",
                retryable = false,
            )
        }

        val lastIndex = lastAcceptedFrameIndex
        val lastTs = lastAcceptedTimestampNs
        val lastSeen = lastSeenFrameIndex

        if (lastIndex != null && frameIndex == lastIndex) {
            droppedDuplicateFrames++
            return RtcVideoJitterDecision.droppedDuplicate(
                raw = "status=DROPPED_DUPLICATE;frameIndex=$frameIndex;lastAcceptedFrameIndex=$lastIndex",
            )
        }

        if (lastTs != null && timestampNs == lastTs) {
            droppedDuplicateFrames++
            return RtcVideoJitterDecision.droppedDuplicate(
                raw = "status=DROPPED_DUPLICATE;frameIndex=$frameIndex;timestampNs=$timestampNs;lastAcceptedTimestampNs=$lastTs",
            )
        }

        if ((lastIndex != null && frameIndex < lastIndex) || (lastTs != null && timestampNs < lastTs) || (lastSeen != null && frameIndex <= lastSeen)) {
            droppedOutOfOrderFrames++
            return RtcVideoJitterDecision.droppedOutOfOrder(
                raw = "status=DROPPED_OUT_OF_ORDER;frameIndex=$frameIndex;timestampNs=$timestampNs;lastAcceptedIndex=$lastIndex;lastAcceptedTimestampNs=$lastTs;lastSeenFrameIndex=$lastSeen",
            )
        }

        val targetPlayoutTimeNs = timestampNs + targetPlayoutDelayNs

        if (arrivalTimeNs - targetPlayoutTimeNs > maxLateThresholdNs) {
            val lateDeltaNs = arrivalTimeNs - targetPlayoutTimeNs
            droppedLateFrames++
            return RtcVideoJitterDecision.droppedLate(
                raw = "status=DROPPED_LATE;frameIndex=$frameIndex;timestampNs=$timestampNs;arrivalTimeNs=$arrivalTimeNs;targetPlayoutTimeNs=$targetPlayoutTimeNs;delayNs=$lateDeltaNs;maxLateThresholdNs=$maxLateThresholdNs",
            )
        }

        if (targetPlayoutTimeNs - arrivalTimeNs > maxFutureThresholdNs) {
            val futureDeltaNs = targetPlayoutTimeNs - arrivalTimeNs
            failedFrames++
            return RtcVideoJitterDecision.failed(
                reason = "too_far_in_future: frameIndex=$frameIndex;timestampNs=$timestampNs;arrivalTimeNs=$arrivalTimeNs;targetPlayoutTimeNs=$targetPlayoutTimeNs;futureDeltaNs=$futureDeltaNs;maxFutureThresholdNs=$maxFutureThresholdNs",
                retryable = true,
            )
        }

        acceptedFrames++
        lastAcceptedFrameIndex = frameIndex
        lastAcceptedTimestampNs = timestampNs
        lastSeenFrameIndex = frameIndex

        return RtcVideoJitterDecision.accepted(
            raw = "status=ACCEPTED;frameIndex=$frameIndex;timestampNs=$timestampNs;targetPlayoutTimeNs=$targetPlayoutTimeNs;arrivalTimeNs=$arrivalTimeNs",
        )
    }

    /**
     * Resets all internal counters and state to their initial values.
     *
     * @return Telemetry map confirming the reset.
     */
    @Synchronized
    fun reset(): Map<String, Any?> {
        acceptedFrames = 0L
        droppedLateFrames = 0L
        droppedOutOfOrderFrames = 0L
        droppedDuplicateFrames = 0L
        failedFrames = 0L
        lastAcceptedFrameIndex = null
        lastAcceptedTimestampNs = null
        lastSeenFrameIndex = null
        return mapOf(
            "pass" to true,
            "raw" to "status=RESET",
            "snapshot" to snapshot(),
        )
    }

    /**
     * Returns an immutable snapshot map of current jitter buffer telemetry and configuration.
     */
    @Synchronized
    fun snapshot(): Map<String, Any?> = mapOf(
        "targetPlayoutDelayNs" to targetPlayoutDelayNs,
        "maxLateThresholdNs" to maxLateThresholdNs,
        "maxFutureThresholdNs" to maxFutureThresholdNs,
        "acceptedFrames" to acceptedFrames,
        "droppedLateFrames" to droppedLateFrames,
        "droppedOutOfOrderFrames" to droppedOutOfOrderFrames,
        "droppedDuplicateFrames" to droppedDuplicateFrames,
        "failedFrames" to failedFrames,
        "lastAcceptedFrameIndex" to lastAcceptedFrameIndex,
        "lastAcceptedTimestampNs" to lastAcceptedTimestampNs,
        "lastSeenFrameIndex" to lastSeenFrameIndex,
    )
}
