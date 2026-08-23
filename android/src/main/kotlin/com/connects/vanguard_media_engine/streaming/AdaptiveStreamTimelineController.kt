package com.connects.vanguard_media_engine.streaming

import com.connects.vanguard_media_engine.codec.AndroidDagTimelineClock

/**
 * Vanguard Android True-DAG Phase 4C4E: Adaptive stream timeline and rebase controller.
 *
 * Normalizes stream presentation timestamps (PTS) against a monotonic timeline clock,
 * manages seamless rebasing on seek or rendition step, suppresses duplicates, drops out-of-order
 * or late samples, rejects too-far-future samples with retryable semantics, and coordinates
 * with [AdaptiveStreamLiveOffsetPolicy].
 *
 * ## Verification Invariants
 * - **Metadata Only**: Operates strictly on numeric timestamps and sequence indices.
 *   Never imports, allocates, or retains HardwareBuffer, Image, Surface, Media3, or ExoPlayer instances.
 * - **Deterministic Evaluation**: Pure thread-safe state machine for timeline normalization.
 * - **Rebase Continuity**: Resets sample anchors and increments generationId on seek or ABR step.
 */
enum class AdaptiveStreamTimelineDecisionStatus {
    ACCEPTED,
    DROPPED_LATE,
    DROPPED_OUT_OF_ORDER,
    DROPPED_DUPLICATE,
    REBASED,
    FAILED,
}

data class AdaptiveStreamTimelineDecision(
    val status: AdaptiveStreamTimelineDecisionStatus,
    val raw: String,
    val retryable: Boolean = false,
    val timelinePositionUs: Long? = null,
    val generationId: Long = 0L,
) {
    val accepted: Boolean
        get() = status == AdaptiveStreamTimelineDecisionStatus.ACCEPTED ||
            status == AdaptiveStreamTimelineDecisionStatus.REBASED
}

class AdaptiveStreamTimelineController(
    val lateThresholdUs: Long = 250_000L,
    val maxFutureLeadUs: Long = 1_000_000L,
    val liveOffsetPolicy: AdaptiveStreamLiveOffsetPolicy = AdaptiveStreamLiveOffsetPolicy(),
) {
    init {
        require(lateThresholdUs > 0L) {
            "lateThresholdUs must be > 0, got $lateThresholdUs"
        }
        require(maxFutureLeadUs > 0L) {
            "maxFutureLeadUs must be > 0, got $maxFutureLeadUs"
        }
    }

    private val timelineClock = AndroidDagTimelineClock()

    var acceptedFrames: Long = 0L
        private set
    var droppedLateFrames: Long = 0L
        private set
    var droppedOutOfOrderFrames: Long = 0L
        private set
    var droppedDuplicateFrames: Long = 0L
        private set
    var failedFrames: Long = 0L
        private set
    var rebaseCount: Long = 0L
        private set
    var generationId: Long = 0L
        private set
    var lastAcceptedPtsUs: Long? = null
        private set
    var lastAcceptedFrameIndex: Long? = null
        private set
    var lastSeenFrameIndex: Long? = null
        private set
    var isStarted: Boolean = false
        private set

    /**
     * Initializes the timeline anchor against monotonic frame time.
     */
    @Synchronized
    fun start(frameTimeNanos: Long, initialMediaPtsUs: Long = 0L): Map<String, Any?> {
        if (frameTimeNanos < 0L || initialMediaPtsUs < 0L) {
            return mapOf(
                "pass" to false,
                "raw" to "status=FAILED;reason=invalid_start_params;frameTimeNanos=$frameTimeNanos;initialMediaPtsUs=$initialMediaPtsUs",
                "generationId" to generationId,
            )
        }
        timelineClock.start(frameTimeNanos, initialMediaPtsUs)
        isStarted = true
        lastAcceptedPtsUs = null
        lastAcceptedFrameIndex = null
        return mapOf(
            "pass" to true,
            "raw" to "status=OK;started;frameTimeNanos=$frameTimeNanos;initialMediaPtsUs=$initialMediaPtsUs",
            "generationId" to generationId,
        )
    }

    /**
     * Rebases the timeline anchor on seek or rendition step, incrementing generationId
     * and resetting last-accepted bounds to the new media anchor.
     */
    @Synchronized
    fun rebase(reason: String, frameTimeNanos: Long, mediaPtsUs: Long): AdaptiveStreamTimelineDecision {
        if (frameTimeNanos < 0L || mediaPtsUs < 0L) {
            failedFrames++
            return AdaptiveStreamTimelineDecision(
                status = AdaptiveStreamTimelineDecisionStatus.FAILED,
                raw = "status=FAILED;reason=invalid_rebase_params;frameTimeNanos=$frameTimeNanos;mediaPtsUs=$mediaPtsUs",
                retryable = false,
                timelinePositionUs = null,
                generationId = generationId,
            )
        }

        generationId++
        rebaseCount++
        lastAcceptedPtsUs = null
        lastAcceptedFrameIndex = null
        timelineClock.start(frameTimeNanos, mediaPtsUs)
        isStarted = true

        return AdaptiveStreamTimelineDecision(
            status = AdaptiveStreamTimelineDecisionStatus.REBASED,
            raw = "status=REBASED;reason=$reason;generationId=$generationId;mediaPtsUs=$mediaPtsUs;frameTimeNanos=$frameTimeNanos",
            retryable = false,
            timelinePositionUs = mediaPtsUs,
            generationId = generationId,
        )
    }

    /**
     * Evaluates a streaming sample against the timeline clock, checking order, duplicates,
     * late arrival, future lead, and applying live-offset speed adjustments.
     */
    @Synchronized
    fun evaluate(
        frameIndex: Long,
        samplePtsUs: Long,
        arrivalFrameTimeNanos: Long,
        currentLiveOffsetMs: Long? = null,
        rebuffered: Boolean = false,
    ): AdaptiveStreamTimelineDecision {
        if (frameIndex < 0L || samplePtsUs < 0L || arrivalFrameTimeNanos < 0L) {
            failedFrames++
            return AdaptiveStreamTimelineDecision(
                status = AdaptiveStreamTimelineDecisionStatus.FAILED,
                raw = "status=FAILED;reason=negative_input;frameIndex=$frameIndex;samplePtsUs=$samplePtsUs;arrivalFrameTimeNanos=$arrivalFrameTimeNanos",
                retryable = false,
                timelinePositionUs = null,
                generationId = generationId,
            )
        }

        if (!isStarted) {
            timelineClock.start(arrivalFrameTimeNanos, samplePtsUs)
            isStarted = true
        }

        // Duplicate check
        if ((lastAcceptedFrameIndex != null && frameIndex == lastAcceptedFrameIndex) ||
            (lastAcceptedPtsUs != null && samplePtsUs == lastAcceptedPtsUs)
        ) {
            droppedDuplicateFrames++
            return AdaptiveStreamTimelineDecision(
                status = AdaptiveStreamTimelineDecisionStatus.DROPPED_DUPLICATE,
                raw = "status=DROPPED_DUPLICATE;frameIndex=$frameIndex;samplePtsUs=$samplePtsUs;lastAcceptedIndex=$lastAcceptedFrameIndex;lastAcceptedPtsUs=$lastAcceptedPtsUs",
                retryable = false,
                timelinePositionUs = samplePtsUs,
                generationId = generationId,
            )
        }

        // Out-of-order check
        if ((lastAcceptedFrameIndex != null && frameIndex < lastAcceptedFrameIndex!!) ||
            (lastAcceptedPtsUs != null && samplePtsUs < lastAcceptedPtsUs!!)
        ) {
            droppedOutOfOrderFrames++
            return AdaptiveStreamTimelineDecision(
                status = AdaptiveStreamTimelineDecisionStatus.DROPPED_OUT_OF_ORDER,
                raw = "status=DROPPED_OUT_OF_ORDER;frameIndex=$frameIndex;samplePtsUs=$samplePtsUs;lastAcceptedIndex=$lastAcceptedFrameIndex;lastAcceptedPtsUs=$lastAcceptedPtsUs",
                retryable = false,
                timelinePositionUs = samplePtsUs,
                generationId = generationId,
            )
        }

        val currentTimelinePositionUs = timelineClock.currentPositionUs(arrivalFrameTimeNanos)

        // Late drop check
        if (samplePtsUs + lateThresholdUs < currentTimelinePositionUs) {
            droppedLateFrames++
            return AdaptiveStreamTimelineDecision(
                status = AdaptiveStreamTimelineDecisionStatus.DROPPED_LATE,
                raw = "status=DROPPED_LATE;frameIndex=$frameIndex;samplePtsUs=$samplePtsUs;currentTimelinePositionUs=$currentTimelinePositionUs;lateThresholdUs=$lateThresholdUs",
                retryable = false,
                timelinePositionUs = currentTimelinePositionUs,
                generationId = generationId,
            )
        }

        // Future lead check
        if (samplePtsUs - currentTimelinePositionUs > maxFutureLeadUs) {
            failedFrames++
            // Do NOT advance lastAccepted / lastSeen state on retryable future sample
            return AdaptiveStreamTimelineDecision(
                status = AdaptiveStreamTimelineDecisionStatus.FAILED,
                raw = "status=FAILED;reason=too_far_in_future;frameIndex=$frameIndex;samplePtsUs=$samplePtsUs;currentTimelinePositionUs=$currentTimelinePositionUs;maxFutureLeadUs=$maxFutureLeadUs",
                retryable = true,
                timelinePositionUs = currentTimelinePositionUs,
                generationId = generationId,
            )
        }

        var liveOffsetSuffix = ""
        if (currentLiveOffsetMs != null) {
            val speedDecision = liveOffsetPolicy.evaluate(currentLiveOffsetMs, rebuffered)
            if (speedDecision.pass) {
                timelineClock.setPlaybackSpeed(speedDecision.recommendedSpeed, arrivalFrameTimeNanos)
            }
            liveOffsetSuffix = ";liveOffsetStatus=${speedDecision.status};speed=${speedDecision.recommendedSpeed}"
        }

        acceptedFrames++
        lastAcceptedFrameIndex = frameIndex
        lastAcceptedPtsUs = samplePtsUs
        lastSeenFrameIndex = frameIndex

        return AdaptiveStreamTimelineDecision(
            status = AdaptiveStreamTimelineDecisionStatus.ACCEPTED,
            raw = "status=ACCEPTED;frameIndex=$frameIndex;samplePtsUs=$samplePtsUs;timelinePositionUs=$currentTimelinePositionUs;generationId=$generationId$liveOffsetSuffix",
            retryable = false,
            timelinePositionUs = currentTimelinePositionUs,
            generationId = generationId,
        )
    }

    /**
     * Resets all internal counters, state, and timeline clock.
     */
    @Synchronized
    fun reset(initialPtsUs: Long = 0L): Map<String, Any?> {
        acceptedFrames = 0L
        droppedLateFrames = 0L
        droppedOutOfOrderFrames = 0L
        droppedDuplicateFrames = 0L
        failedFrames = 0L
        rebaseCount = 0L
        generationId = 0L
        lastAcceptedPtsUs = null
        lastAcceptedFrameIndex = null
        lastSeenFrameIndex = null
        isStarted = false
        timelineClock.reset(initialPtsUs)
        return mapOf(
            "pass" to true,
            "raw" to "status=OK;reset;initialPtsUs=$initialPtsUs",
        )
    }

    /**
     * Returns a snapshot of the current controller telemetry.
     */
    @Synchronized
    fun snapshot(): Map<String, Any?> {
        return mapOf(
            "acceptedFrames" to acceptedFrames,
            "droppedLateFrames" to droppedLateFrames,
            "droppedOutOfOrderFrames" to droppedOutOfOrderFrames,
            "droppedDuplicateFrames" to droppedDuplicateFrames,
            "failedFrames" to failedFrames,
            "rebaseCount" to rebaseCount,
            "generationId" to generationId,
            "lastAcceptedPtsUs" to lastAcceptedPtsUs,
            "lastAcceptedFrameIndex" to lastAcceptedFrameIndex,
            "lastSeenFrameIndex" to lastSeenFrameIndex,
            "isStarted" to isStarted,
            "playbackSpeed" to timelineClock.playbackSpeed,
            "isPlaying" to timelineClock.isPlaying,
        )
    }
}
