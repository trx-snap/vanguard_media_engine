package com.connects.vanguard_media_engine.rtc

/**
 * Lifecycle state taxonomy for [RealtimeVideoOutputAdapter].
 */
enum class RealtimeVideoOutputState {
    /** Output adapter is idle and not accepting egress video frames. */
    IDLE,

    /** Output adapter is started and actively publishing video frames to downstream transport. */
    STARTED,

    /** Output adapter is temporarily paused; incoming frames are dropped as not-ready. */
    PAUSED,

    /** Output adapter encountered an unrecoverable failure. */
    FAILED,

    /** Output adapter has been permanently terminated and released. */
    DISPOSED,
}

/**
 * Video-only egress adapter managing the lifecycle, frame validation, and delivery counters for publishing
 * processed Vanguard DAG frames to a generic [RtcVideoFramePublisher].
 *
 * ## Video-Only Domain Invariants
 * - **Video Only**: Handles video frame egress exclusively. Zero ownership or awareness of
 *   room signaling, connection tokens, participant rosters, active speaker events, or audio streams.
 *   Room orchestration and audio capture/mixing are strictly forbidden in Vanguard.
 * - **Frame Validation**: Validates generic [RealtimeVideoFrame] envelope and buffer format attributes
 *   via [RtcVideoFrameValidator] before forwarding to downstream publishers, rejecting invalid frames early.
 * - **Transport Agnostic**: Operates against the generic [RtcVideoFramePublisher] contract without
 *   coupling to concrete WebRTC, LiveKit, or network transport implementations.
 * - **No Buffer Retention or Closure**: Adheres strictly to the scoped-borrow contract of [RealtimeVideoFrame].
 *   This adapter does not retain references to [RealtimeVideoFrame.hardwareBuffer] after [publishFrame]
 *   returns and never closes the underlying hardware buffer. Buffer lifecycle remains owned by the producing pipeline.
 * - **Thread-Safe**: All public lifecycle transitions, frame delivery invocations, and telemetry snapshot
 *   queries are synchronized for safe multi-threaded execution.
 *
 * @property publisher Downstream generic RTC video frame publisher destination.
 */
class RealtimeVideoOutputAdapter(
    private val publisher: RtcVideoFramePublisher,
) {
    private var state: RealtimeVideoOutputState = RealtimeVideoOutputState.IDLE
    private var acceptedFrames: Long = 0L
    private var droppedBackpressureFrames: Long = 0L
    private var droppedNotReadyFrames: Long = 0L
    private var unsupportedFormatFrames: Long = 0L
    private var failedFrames: Long = 0L
    private var lastError: String? = null

    /**
     * Starts video frame egress delivery.
     *
     * Transitions [RealtimeVideoOutputState.IDLE] or [RealtimeVideoOutputState.PAUSED] to [RealtimeVideoOutputState.STARTED].
     * Idempotent if already [RealtimeVideoOutputState.STARTED].
     * Fails if currently in terminal [RealtimeVideoOutputState.FAILED] or [RealtimeVideoOutputState.DISPOSED].
     */
    @Synchronized
    fun start(): Map<String, Any?> {
        return when (state) {
            RealtimeVideoOutputState.IDLE,
            RealtimeVideoOutputState.PAUSED -> {
                state = RealtimeVideoOutputState.STARTED
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=STARTED",
                )
            }
            RealtimeVideoOutputState.STARTED -> {
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=STARTED;idempotent=true",
                )
            }
            RealtimeVideoOutputState.FAILED,
            RealtimeVideoOutputState.DISPOSED -> {
                mapOf(
                    "pass" to false,
                    "state" to state.name,
                    "raw" to "status=INVALID_STATE;state=${state.name}",
                )
            }
        }
    }

    /**
     * Pauses video frame egress delivery.
     *
     * Transitions [RealtimeVideoOutputState.STARTED] to [RealtimeVideoOutputState.PAUSED].
     * Idempotent if already [RealtimeVideoOutputState.IDLE] or [RealtimeVideoOutputState.PAUSED].
     * Fails if currently in terminal [RealtimeVideoOutputState.FAILED] or [RealtimeVideoOutputState.DISPOSED].
     */
    @Synchronized
    fun pause(): Map<String, Any?> {
        return when (state) {
            RealtimeVideoOutputState.STARTED -> {
                state = RealtimeVideoOutputState.PAUSED
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=PAUSED",
                )
            }
            RealtimeVideoOutputState.IDLE,
            RealtimeVideoOutputState.PAUSED -> {
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=PAUSED;idempotent=true",
                )
            }
            RealtimeVideoOutputState.FAILED,
            RealtimeVideoOutputState.DISPOSED -> {
                mapOf(
                    "pass" to false,
                    "state" to state.name,
                    "raw" to "status=INVALID_STATE;state=${state.name}",
                )
            }
        }
    }

    /**
     * Resumes video frame egress delivery.
     *
     * Transitions [RealtimeVideoOutputState.PAUSED] or [RealtimeVideoOutputState.IDLE] to [RealtimeVideoOutputState.STARTED].
     * Idempotent if already [RealtimeVideoOutputState.STARTED].
     * Fails if currently in terminal [RealtimeVideoOutputState.FAILED] or [RealtimeVideoOutputState.DISPOSED].
     */
    @Synchronized
    fun resume(): Map<String, Any?> {
        return when (state) {
            RealtimeVideoOutputState.PAUSED,
            RealtimeVideoOutputState.IDLE -> {
                state = RealtimeVideoOutputState.STARTED
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=STARTED",
                )
            }
            RealtimeVideoOutputState.STARTED -> {
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=STARTED;idempotent=true",
                )
            }
            RealtimeVideoOutputState.FAILED,
            RealtimeVideoOutputState.DISPOSED -> {
                mapOf(
                    "pass" to false,
                    "state" to state.name,
                    "raw" to "status=INVALID_STATE;state=${state.name}",
                )
            }
        }
    }

    /**
     * Stops video frame egress delivery and returns adapter to idle.
     *
     * Transitions [RealtimeVideoOutputState.STARTED] or [RealtimeVideoOutputState.PAUSED] to [RealtimeVideoOutputState.IDLE].
     * Idempotent if already [RealtimeVideoOutputState.IDLE].
     * Fails if currently in terminal [RealtimeVideoOutputState.FAILED] or [RealtimeVideoOutputState.DISPOSED].
     */
    @Synchronized
    fun stop(): Map<String, Any?> {
        return when (state) {
            RealtimeVideoOutputState.STARTED,
            RealtimeVideoOutputState.PAUSED -> {
                state = RealtimeVideoOutputState.IDLE
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=IDLE",
                )
            }
            RealtimeVideoOutputState.IDLE -> {
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=IDLE;idempotent=true",
                )
            }
            RealtimeVideoOutputState.FAILED,
            RealtimeVideoOutputState.DISPOSED -> {
                mapOf(
                    "pass" to false,
                    "state" to state.name,
                    "raw" to "status=INVALID_STATE;state=${state.name}",
                )
            }
        }
    }

    /**
     * Publishes a processed [RealtimeVideoFrame] to the downstream publisher if started.
     *
     * If the adapter is in [RealtimeVideoOutputState.DISPOSED], [RealtimeVideoOutputState.FAILED],
     * [RealtimeVideoOutputState.PAUSED], or [RealtimeVideoOutputState.IDLE], the frame is dropped as not-ready
     * and [droppedNotReadyFrames] counter is incremented.
     *
     * If [RealtimeVideoOutputState.STARTED], validates frame metadata via [RtcVideoFrameValidator.validate]
     * before delegating to [RtcVideoFramePublisher.publishFrame]. If validation fails, immediately returns
     * the rejection result and updates [unsupportedFormatFrames] (or [failedFrames]) without calling the publisher.
     * Updates counters based on delivery status. Does not retain or close [RealtimeVideoFrame.hardwareBuffer].
     */
    @Synchronized
    fun publishFrame(frame: RealtimeVideoFrame): RtcVideoFrameDeliveryResult {
        if (state != RealtimeVideoOutputState.STARTED) {
            droppedNotReadyFrames++
            return RtcVideoFrameDeliveryResult.droppedNotReady(
                "status=DROPPED_NOT_READY;state=${state.name}"
            )
        }

        val validation = RtcVideoFrameValidator.validate(frame)
        if (!validation.accepted) {
            when (validation.status) {
                RtcVideoFrameDeliveryStatus.UNSUPPORTED_FORMAT -> unsupportedFormatFrames++
                RtcVideoFrameDeliveryStatus.FAILED -> failedFrames++
                else -> unsupportedFormatFrames++
            }
            return validation
        }

        val result = try {
            publisher.publishFrame(frame)
        } catch (t: Throwable) {
            failedFrames++
            val err = "publisher_exception: ${t.message}"
            lastError = err
            return RtcVideoFrameDeliveryResult.failed(err)
        }

        when (result.status) {
            RtcVideoFrameDeliveryStatus.ACCEPTED -> {
                acceptedFrames++
            }
            RtcVideoFrameDeliveryStatus.DROPPED_BACKPRESSURE -> {
                droppedBackpressureFrames++
            }
            RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY -> {
                droppedNotReadyFrames++
            }
            RtcVideoFrameDeliveryStatus.UNSUPPORTED_FORMAT -> {
                unsupportedFormatFrames++
            }
            RtcVideoFrameDeliveryStatus.FAILED -> {
                failedFrames++
            }
        }

        return result
    }

    /**
     * Transitions the adapter to [RealtimeVideoOutputState.FAILED] unless already disposed,
     * recording [reason] in [lastError].
     */
    @Synchronized
    fun fail(reason: String): Map<String, Any?> {
        if (state != RealtimeVideoOutputState.DISPOSED) {
            state = RealtimeVideoOutputState.FAILED
            lastError = reason
            return mapOf(
                "pass" to true,
                "state" to state.name,
                "raw" to "status=FAILED;reason=$reason",
                "lastError" to lastError,
            )
        }
        return mapOf(
            "pass" to false,
            "state" to state.name,
            "raw" to "status=DISPOSED;cannot_fail_disposed=true",
            "lastError" to lastError,
        )
    }

    /**
     * Permanently disposes the adapter and transitions to terminal [RealtimeVideoOutputState.DISPOSED].
     * Idempotent.
     */
    @Synchronized
    fun dispose(): Map<String, Any?> {
        state = RealtimeVideoOutputState.DISPOSED
        return mapOf(
            "pass" to true,
            "state" to state.name,
            "raw" to "status=DISPOSED",
        )
    }

    /**
     * Returns an immutable snapshot map of current lifecycle state and delivery counters.
     */
    @Synchronized
    fun snapshot(): Map<String, Any?> = mapOf(
        "state" to state.name,
        "acceptedFrames" to acceptedFrames,
        "droppedBackpressureFrames" to droppedBackpressureFrames,
        "droppedNotReadyFrames" to droppedNotReadyFrames,
        "unsupportedFormatFrames" to unsupportedFormatFrames,
        "failedFrames" to failedFrames,
        "lastError" to lastError,
    )
}
