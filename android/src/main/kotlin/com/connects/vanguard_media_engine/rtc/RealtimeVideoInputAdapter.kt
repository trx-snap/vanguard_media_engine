package com.connects.vanguard_media_engine.rtc

/**
 * Lifecycle state taxonomy for [RealtimeVideoInputAdapter].
 */
enum class RealtimeVideoInputState {
    /** Input adapter is idle and not accepting ingress video frames. */
    IDLE,

    /** Input adapter is started and actively ingesting video frames into downstream DAG sink. */
    STARTED,

    /** Input adapter is temporarily paused; incoming frames are dropped as not-ready. */
    PAUSED,

    /** Input adapter encountered an unrecoverable failure. */
    FAILED,

    /** Input adapter has been permanently terminated and released. */
    DISPOSED,
}

/**
 * Video-only ingress adapter managing the lifecycle, frame validation, and delivery counters for ingesting
 * incoming remote RTC video frames into a generic [RtcVideoFrameSink].
 *
 * ## Video-Only Domain Invariants
 * - **Video Only**: Handles video frame ingress exclusively. Zero ownership or awareness of
 *   room signaling, connection tokens, participant rosters, active speaker events, or audio streams.
 *   Room orchestration and audio capture/mixing are strictly forbidden in Vanguard.
 * - **Frame Validation**: Validates generic [RealtimeVideoFrame] envelope and buffer format attributes
 *   via [RtcVideoFrameValidator] before forwarding to downstream sinks, rejecting invalid frames early.
 * - **DAG Ingress Seam**: Acts as the boundary adapter forwarding remote RTC video frames to the
 *   Vanguard True-DAG engine (e.g. C++ `StreamSourceNode`) for downstream filtering, transform, and composition.
 * - **No Direct Display**: Does not directly render to display surfaces; presentation is scheduled
 *   through DAG graph topology for generation-aware playhead evaluation.
 * - **Transport Agnostic**: Operates against the generic [RtcVideoFrameSink] contract without
 *   coupling to concrete WebRTC, LiveKit, or network transport implementations.
 * - **No Buffer Retention or Closure**: Adheres strictly to the scoped-borrow contract of [RealtimeVideoFrame].
 *   This adapter does not retain references to [RealtimeVideoFrame.hardwareBuffer] after [ingestFrame]
 *   returns and never closes the underlying hardware buffer. Buffer lifecycle remains owned by the producing pipeline.
 * - **Thread-Safe**: All public lifecycle transitions, frame ingestion invocations, and telemetry snapshot
 *   queries are synchronized for safe multi-threaded execution.
 *
 * @property sink Downstream generic RTC video frame sink destination.
 */
class RealtimeVideoInputAdapter(
    private val sink: RtcVideoFrameSink,
) {
    private var state: RealtimeVideoInputState = RealtimeVideoInputState.IDLE
    private var acceptedFrames: Long = 0L
    private var droppedBackpressureFrames: Long = 0L
    private var droppedNotReadyFrames: Long = 0L
    private var unsupportedFormatFrames: Long = 0L
    private var failedFrames: Long = 0L
    private var lastError: String? = null

    /**
     * Starts video frame ingress delivery.
     *
     * Transitions [RealtimeVideoInputState.IDLE] or [RealtimeVideoInputState.PAUSED] to [RealtimeVideoInputState.STARTED].
     * Idempotent if already [RealtimeVideoInputState.STARTED].
     * Fails if currently in terminal [RealtimeVideoInputState.FAILED] or [RealtimeVideoInputState.DISPOSED].
     */
    @Synchronized
    fun start(): Map<String, Any?> {
        return when (state) {
            RealtimeVideoInputState.IDLE,
            RealtimeVideoInputState.PAUSED -> {
                state = RealtimeVideoInputState.STARTED
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=STARTED",
                )
            }
            RealtimeVideoInputState.STARTED -> {
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=STARTED;idempotent=true",
                )
            }
            RealtimeVideoInputState.FAILED,
            RealtimeVideoInputState.DISPOSED -> {
                mapOf(
                    "pass" to false,
                    "state" to state.name,
                    "raw" to "status=INVALID_STATE;state=${state.name}",
                )
            }
        }
    }

    /**
     * Pauses video frame ingress delivery.
     *
     * Transitions [RealtimeVideoInputState.STARTED] to [RealtimeVideoInputState.PAUSED].
     * Idempotent if already [RealtimeVideoInputState.IDLE] or [RealtimeVideoInputState.PAUSED].
     * Fails if currently in terminal [RealtimeVideoInputState.FAILED] or [RealtimeVideoInputState.DISPOSED].
     */
    @Synchronized
    fun pause(): Map<String, Any?> {
        return when (state) {
            RealtimeVideoInputState.STARTED -> {
                state = RealtimeVideoInputState.PAUSED
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=PAUSED",
                )
            }
            RealtimeVideoInputState.IDLE,
            RealtimeVideoInputState.PAUSED -> {
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=PAUSED;idempotent=true",
                )
            }
            RealtimeVideoInputState.FAILED,
            RealtimeVideoInputState.DISPOSED -> {
                mapOf(
                    "pass" to false,
                    "state" to state.name,
                    "raw" to "status=INVALID_STATE;state=${state.name}",
                )
            }
        }
    }

    /**
     * Resumes video frame ingress delivery.
     *
     * Transitions [RealtimeVideoInputState.PAUSED] or [RealtimeVideoInputState.IDLE] to [RealtimeVideoInputState.STARTED].
     * Idempotent if already [RealtimeVideoInputState.STARTED].
     * Fails if currently in terminal [RealtimeVideoInputState.FAILED] or [RealtimeVideoInputState.DISPOSED].
     */
    @Synchronized
    fun resume(): Map<String, Any?> {
        return when (state) {
            RealtimeVideoInputState.PAUSED,
            RealtimeVideoInputState.IDLE -> {
                state = RealtimeVideoInputState.STARTED
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=STARTED",
                )
            }
            RealtimeVideoInputState.STARTED -> {
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=STARTED;idempotent=true",
                )
            }
            RealtimeVideoInputState.FAILED,
            RealtimeVideoInputState.DISPOSED -> {
                mapOf(
                    "pass" to false,
                    "state" to state.name,
                    "raw" to "status=INVALID_STATE;state=${state.name}",
                )
            }
        }
    }

    /**
     * Stops video frame ingress delivery and returns adapter to idle.
     *
     * Transitions [RealtimeVideoInputState.STARTED] or [RealtimeVideoInputState.PAUSED] to [RealtimeVideoInputState.IDLE].
     * Idempotent if already [RealtimeVideoInputState.IDLE].
     * Fails if currently in terminal [RealtimeVideoInputState.FAILED] or [RealtimeVideoInputState.DISPOSED].
     */
    @Synchronized
    fun stop(): Map<String, Any?> {
        return when (state) {
            RealtimeVideoInputState.STARTED,
            RealtimeVideoInputState.PAUSED -> {
                state = RealtimeVideoInputState.IDLE
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=IDLE",
                )
            }
            RealtimeVideoInputState.IDLE -> {
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "raw" to "status=IDLE;idempotent=true",
                )
            }
            RealtimeVideoInputState.FAILED,
            RealtimeVideoInputState.DISPOSED -> {
                mapOf(
                    "pass" to false,
                    "state" to state.name,
                    "raw" to "status=INVALID_STATE;state=${state.name}",
                )
            }
        }
    }

    /**
     * Ingests an incoming remote [RealtimeVideoFrame] to the downstream sink if started.
     *
     * If the adapter is in [RealtimeVideoInputState.DISPOSED], [RealtimeVideoInputState.FAILED],
     * [RealtimeVideoInputState.PAUSED], or [RealtimeVideoInputState.IDLE], the frame is dropped as not-ready
     * and [droppedNotReadyFrames] counter is incremented.
     *
     * If [RealtimeVideoInputState.STARTED], validates frame metadata via [RtcVideoFrameValidator.validate]
     * before delegating to [RtcVideoFrameSink.onFrame]. If validation fails, immediately returns
     * the rejection result and updates [unsupportedFormatFrames] (or [failedFrames]) without calling the sink.
     * Updates counters based on delivery status. Does not retain or close [RealtimeVideoFrame.hardwareBuffer].
     */
    @Synchronized
    fun ingestFrame(frame: RealtimeVideoFrame): RtcVideoFrameDeliveryResult {
        if (state != RealtimeVideoInputState.STARTED) {
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
            sink.onFrame(frame)
        } catch (t: Throwable) {
            failedFrames++
            val err = "sink_exception: ${t.message}"
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
     * Transitions the adapter to [RealtimeVideoInputState.FAILED] unless already disposed,
     * recording [reason] in [lastError].
     */
    @Synchronized
    fun fail(reason: String): Map<String, Any?> {
        if (state != RealtimeVideoInputState.DISPOSED) {
            state = RealtimeVideoInputState.FAILED
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
     * Permanently disposes the adapter and transitions to terminal [RealtimeVideoInputState.DISPOSED].
     * Idempotent.
     */
    @Synchronized
    fun dispose(): Map<String, Any?> {
        state = RealtimeVideoInputState.DISPOSED
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
