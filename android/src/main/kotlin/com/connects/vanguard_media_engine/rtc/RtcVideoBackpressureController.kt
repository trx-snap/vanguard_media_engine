package com.connects.vanguard_media_engine.rtc

/**
 * Backpressure strategy taxonomy for [RtcVideoBackpressureController].
 */
enum class RtcVideoBackpressureMode {
    /**
     * Signals a drop for older or currently queued work in favor of the latest available video frame.
     *
     * Note: Because [RtcVideoBackpressureController] does not own frame memory buffers,
     * it signals a backpressure drop with reason `replace_in_flight_deferred`. Downstream callers
     * should drop older queued work when this mode is handled in future implementations.
     */
    LATEST_FRAME_WINS,

    /**
     * Drops incoming video frames immediately when in-flight frames reach [RtcVideoBackpressureController.maxInFlightFrames].
     */
    DROP_WHEN_BUSY,
}

/**
 * Video-only backpressure controller for bounding real-time frame flow into RTC transport adapters.
 *
 * ## Video-Only Domain Invariants
 * - **Video Only**: Handles video frame flow gating exclusively. Zero ownership or awareness of
 *   room signaling, connection tokens, participant rosters, active speaker events, or audio streams.
 *   Room orchestration and audio capture/mixing are strictly forbidden in Vanguard.
 * - **Bounded Real-Time Policy**: Prevents unbounded frame accumulation in downstream encoder or
 *   transport queues, preserving sub-second latency for real-time video delivery.
 * - **No Buffer Ownership**: This controller does not store, retain, copy, or close [RealtimeVideoFrame]
 *   hardware buffers. It strictly manages numeric counters and gating decisions.
 * - **Thread-Safe**: All state mutations and telemetry reads are synchronized for safe concurrent execution.
 *
 * @param maxInFlightFrames Maximum allowed concurrent in-flight frames (must be > 0).
 * @param mode Backpressure resolution mode when in-flight capacity is reached.
 */
class RtcVideoBackpressureController(
    val maxInFlightFrames: Int = 1,
    val mode: RtcVideoBackpressureMode = RtcVideoBackpressureMode.LATEST_FRAME_WINS,
) {
    init {
        require(maxInFlightFrames > 0) {
            "maxInFlightFrames must be > 0, got $maxInFlightFrames"
        }
    }

    private var acceptedFrames: Long = 0L
    private var droppedFrames: Long = 0L
    private var completedFrames: Long = 0L
    private var failedFrames: Long = 0L
    private var inFlightFrames: Int = 0
    private var latestAcceptedFrameIndex: Long? = null
    private var latestDroppedFrameIndex: Long? = null

    /**
     * Evaluates whether a video frame identified by [frameIndex] can be accepted into the transport pipeline.
     *
     * @param frameIndex Non-negative sequential frame identifier.
     * @return [RtcVideoFrameDeliveryResult] indicating accepted status, backpressure drop, or parameter failure.
     */
    @Synchronized
    fun tryAccept(frameIndex: Long): RtcVideoFrameDeliveryResult {
        if (frameIndex < 0L) {
            failedFrames++
            return RtcVideoFrameDeliveryResult.failed(
                reason = "invalid_frame_index: $frameIndex",
                retryable = false,
            )
        }

        if (inFlightFrames < maxInFlightFrames) {
            inFlightFrames++
            acceptedFrames++
            latestAcceptedFrameIndex = frameIndex
            return RtcVideoFrameDeliveryResult.accepted(
                raw = "status=ACCEPTED;frameIndex=$frameIndex;inFlight=$inFlightFrames;max=$maxInFlightFrames",
            )
        }

        droppedFrames++
        latestDroppedFrameIndex = frameIndex

        return when (mode) {
            RtcVideoBackpressureMode.DROP_WHEN_BUSY -> {
                RtcVideoFrameDeliveryResult.droppedBackpressure(
                    raw = "status=DROPPED_BACKPRESSURE;mode=DROP_WHEN_BUSY;frameIndex=$frameIndex;inFlight=$inFlightFrames;max=$maxInFlightFrames",
                )
            }
            RtcVideoBackpressureMode.LATEST_FRAME_WINS -> {
                RtcVideoFrameDeliveryResult.droppedBackpressure(
                    raw = "status=DROPPED_BACKPRESSURE;mode=LATEST_FRAME_WINS;reason=replace_in_flight_deferred;frameIndex=$frameIndex;inFlight=$inFlightFrames;max=$maxInFlightFrames",
                )
            }
        }
    }

    /**
     * Marks an in-flight frame delivery as completed, decrementing the in-flight counter.
     *
     * Idempotent: If [inFlightFrames] is already zero, completes without throwing.
     *
     * @param frameIndex Optional identifier of the completed frame for diagnostic logging.
     * @return Telemetry map reflecting the completion update.
     */
    @Synchronized
    fun markComplete(frameIndex: Long? = null): Map<String, Any?> {
        if (inFlightFrames > 0) {
            inFlightFrames--
            completedFrames++
        }
        return mapOf(
            "pass" to true,
            "inFlightFrames" to inFlightFrames,
            "completedFrames" to completedFrames,
            "frameIndex" to frameIndex,
            "raw" to "status=COMPLETE;frameIndex=$frameIndex;inFlight=$inFlightFrames;completed=$completedFrames",
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
        droppedFrames = 0L
        completedFrames = 0L
        failedFrames = 0L
        inFlightFrames = 0
        latestAcceptedFrameIndex = null
        latestDroppedFrameIndex = null
        return mapOf(
            "pass" to true,
            "raw" to "status=RESET",
            "snapshot" to snapshot(),
        )
    }

    /**
     * Returns an immutable snapshot map of current backpressure telemetry and configuration.
     */
    @Synchronized
    fun snapshot(): Map<String, Any?> = mapOf(
        "maxInFlightFrames" to maxInFlightFrames,
        "mode" to mode.name,
        "acceptedFrames" to acceptedFrames,
        "droppedFrames" to droppedFrames,
        "completedFrames" to completedFrames,
        "failedFrames" to failedFrames,
        "inFlightFrames" to inFlightFrames,
        "latestAcceptedFrameIndex" to latestAcceptedFrameIndex,
        "latestDroppedFrameIndex" to latestDroppedFrameIndex,
    )
}
