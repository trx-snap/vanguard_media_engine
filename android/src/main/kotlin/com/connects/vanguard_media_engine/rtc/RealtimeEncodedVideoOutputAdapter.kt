package com.connects.vanguard_media_engine.rtc

/**
 * Lifecycle state taxonomy for [RealtimeEncodedVideoOutputAdapter].
 */
enum class RealtimeEncodedVideoOutputState {
    /** Encoded output adapter is idle and not accepting egress frames. */
    IDLE,

    /** Encoded output adapter is started and actively publishing frames to downstream transport. */
    STARTED,

    /** Encoded output adapter is temporarily paused; incoming frames are dropped as not-ready. */
    PAUSED,

    /** Encoded output adapter encountered an unrecoverable failure. */
    FAILED,

    /** Encoded output adapter has been permanently terminated and released. */
    DISPOSED,
}

/**
 * Transport-neutral video egress adapter managing the lifecycle, first-keyframe gating,
 * delivery counters, and backpressure propagation for publishing encoded Vanguard DAG frames
 * to a generic [RtcEncodedVideoFramePublisher].
 *
 * ## Domain Invariants
 * - **Video Only**: Handles encoded video frame egress exclusively. Zero ownership or awareness of
 *   room signaling, connection tokens, participant rosters, active speaker events, or audio streams.
 *   Room orchestration and audio capture/mixing are strictly forbidden in Vanguard.
 * - **First-Keyframe Gating**: Delta frames arriving after [start] or [resume] before the first
 *   accepted keyframe are dropped as [RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY] with
 *   `reason=awaiting_keyframe`. The first accepted keyframe opens delta frame delivery.
 *   Keyframe gating is reset on start, resume, pause, stop, fail, and dispose so any new stream
 *   or post-pause session always begins cleanly with a keyframe.
 * - **Backpressure Preservation**: Propagates publisher [RtcVideoFrameDeliveryStatus.DROPPED_BACKPRESSURE]
 *   and tracks backpressure drops in telemetry counters without resetting the keyframe gate.
 * - **Transport Agnostic**: Operates against the generic [RtcEncodedVideoFramePublisher] contract
 *   without coupling to concrete WebRTC, LiveKit, RTMP, or network socket implementations.
 * - **No Buffer Retention or Mutation**: Adheres strictly to the scoped-borrow contract of [RtcEncodedVideoFrame].
 *   Never stores or mutates the position or limit of [RtcEncodedVideoFrame.encodedData].
 * - **Thread-Safe**: All public lifecycle transitions, frame delivery invocations, and telemetry
 *   snapshot queries are synchronized for safe multi-threaded execution.
 *
 * @property publisher Downstream generic RTC encoded video frame publisher destination.
 */
class RealtimeEncodedVideoOutputAdapter(
    private val publisher: RtcEncodedVideoFramePublisher,
) {
    private var state: RealtimeEncodedVideoOutputState = RealtimeEncodedVideoOutputState.IDLE
    private var keyframeGateOpen: Boolean = false
    private var acceptedFrames: Long = 0L
    private var droppedBackpressureFrames: Long = 0L
    private var droppedNotReadyFrames: Long = 0L
    private var failedFrames: Long = 0L
    private var lastError: String? = null

    /**
     * Starts encoded video frame egress delivery.
     *
     * Transitions [RealtimeEncodedVideoOutputState.IDLE] or [RealtimeEncodedVideoOutputState.PAUSED]
     * to [RealtimeEncodedVideoOutputState.STARTED].
     * Resets the first-keyframe gate so delivery must commence with a keyframe.
     * Idempotent if already [RealtimeEncodedVideoOutputState.STARTED].
     * Fails if currently in terminal [RealtimeEncodedVideoOutputState.FAILED] or [RealtimeEncodedVideoOutputState.DISPOSED].
     */
    @Synchronized
    fun start(): Map<String, Any?> {
        return when (state) {
            RealtimeEncodedVideoOutputState.IDLE,
            RealtimeEncodedVideoOutputState.PAUSED -> {
                state = RealtimeEncodedVideoOutputState.STARTED
                keyframeGateOpen = false
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "keyframeGateOpen" to keyframeGateOpen,
                    "raw" to "status=STARTED",
                )
            }
            RealtimeEncodedVideoOutputState.STARTED -> {
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "keyframeGateOpen" to keyframeGateOpen,
                    "raw" to "status=STARTED;idempotent=true",
                )
            }
            RealtimeEncodedVideoOutputState.FAILED,
            RealtimeEncodedVideoOutputState.DISPOSED -> {
                mapOf(
                    "pass" to false,
                    "state" to state.name,
                    "keyframeGateOpen" to keyframeGateOpen,
                    "raw" to "status=INVALID_STATE;state=${state.name}",
                )
            }
        }
    }

    /**
     * Pauses encoded video frame egress delivery.
     *
     * Transitions [RealtimeEncodedVideoOutputState.STARTED] to [RealtimeEncodedVideoOutputState.PAUSED].
     * Resets the keyframe gate so subsequent resume requires a fresh keyframe.
     * Idempotent if already [RealtimeEncodedVideoOutputState.IDLE] or [RealtimeEncodedVideoOutputState.PAUSED].
     * Fails if currently in terminal [RealtimeEncodedVideoOutputState.FAILED] or [RealtimeEncodedVideoOutputState.DISPOSED].
     */
    @Synchronized
    fun pause(): Map<String, Any?> {
        return when (state) {
            RealtimeEncodedVideoOutputState.STARTED -> {
                state = RealtimeEncodedVideoOutputState.PAUSED
                keyframeGateOpen = false
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "keyframeGateOpen" to keyframeGateOpen,
                    "raw" to "status=PAUSED",
                )
            }
            RealtimeEncodedVideoOutputState.IDLE,
            RealtimeEncodedVideoOutputState.PAUSED -> {
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "keyframeGateOpen" to keyframeGateOpen,
                    "raw" to "status=PAUSED;idempotent=true",
                )
            }
            RealtimeEncodedVideoOutputState.FAILED,
            RealtimeEncodedVideoOutputState.DISPOSED -> {
                mapOf(
                    "pass" to false,
                    "state" to state.name,
                    "keyframeGateOpen" to keyframeGateOpen,
                    "raw" to "status=INVALID_STATE;state=${state.name}",
                )
            }
        }
    }

    /**
     * Resumes encoded video frame egress delivery after a pause.
     *
     * Transitions [RealtimeEncodedVideoOutputState.PAUSED] or [RealtimeEncodedVideoOutputState.IDLE]
     * to [RealtimeEncodedVideoOutputState.STARTED].
     * Resets the keyframe gate so delta frames before the first post-resume keyframe are gated.
     * Idempotent if already [RealtimeEncodedVideoOutputState.STARTED].
     * Fails if currently in terminal [RealtimeEncodedVideoOutputState.FAILED] or [RealtimeEncodedVideoOutputState.DISPOSED].
     */
    @Synchronized
    fun resume(): Map<String, Any?> {
        return when (state) {
            RealtimeEncodedVideoOutputState.PAUSED,
            RealtimeEncodedVideoOutputState.IDLE -> {
                state = RealtimeEncodedVideoOutputState.STARTED
                keyframeGateOpen = false
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "keyframeGateOpen" to keyframeGateOpen,
                    "raw" to "status=STARTED",
                )
            }
            RealtimeEncodedVideoOutputState.STARTED -> {
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "keyframeGateOpen" to keyframeGateOpen,
                    "raw" to "status=STARTED;idempotent=true",
                )
            }
            RealtimeEncodedVideoOutputState.FAILED,
            RealtimeEncodedVideoOutputState.DISPOSED -> {
                mapOf(
                    "pass" to false,
                    "state" to state.name,
                    "keyframeGateOpen" to keyframeGateOpen,
                    "raw" to "status=INVALID_STATE;state=${state.name}",
                )
            }
        }
    }

    /**
     * Stops encoded video frame egress delivery and returns adapter to idle.
     *
     * Transitions [RealtimeEncodedVideoOutputState.STARTED] or [RealtimeEncodedVideoOutputState.PAUSED]
     * to [RealtimeEncodedVideoOutputState.IDLE].
     * Resets the keyframe gate. Idempotent if already [RealtimeEncodedVideoOutputState.IDLE].
     * Fails if currently in terminal [RealtimeEncodedVideoOutputState.FAILED] or [RealtimeEncodedVideoOutputState.DISPOSED].
     */
    @Synchronized
    fun stop(): Map<String, Any?> {
        return when (state) {
            RealtimeEncodedVideoOutputState.STARTED,
            RealtimeEncodedVideoOutputState.PAUSED -> {
                state = RealtimeEncodedVideoOutputState.IDLE
                keyframeGateOpen = false
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "keyframeGateOpen" to keyframeGateOpen,
                    "raw" to "status=IDLE",
                )
            }
            RealtimeEncodedVideoOutputState.IDLE -> {
                mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "keyframeGateOpen" to keyframeGateOpen,
                    "raw" to "status=IDLE;idempotent=true",
                )
            }
            RealtimeEncodedVideoOutputState.FAILED,
            RealtimeEncodedVideoOutputState.DISPOSED -> {
                mapOf(
                    "pass" to false,
                    "state" to state.name,
                    "keyframeGateOpen" to keyframeGateOpen,
                    "raw" to "status=INVALID_STATE;state=${state.name}",
                )
            }
        }
    }

    /**
     * Publishes an encoded [RtcEncodedVideoFrame] to the downstream publisher if started and gated.
     *
     * - If [state] is not [RealtimeEncodedVideoOutputState.STARTED], drops the frame as
     *   [RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY] and increments [droppedNotReadyFrames].
     * - If [state] is [RealtimeEncodedVideoOutputState.STARTED] but [keyframeGateOpen] is false and
     *   [frame.isKeyFrame] is false, drops the delta frame as [RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY]
     *   with `reason=awaiting_keyframe` and increments [droppedNotReadyFrames].
     * - When a keyframe or subsequent delta is forwarded, delegates to [RtcEncodedVideoFramePublisher.publishFrame].
     *   If the publisher accepts a keyframe, opens the keyframe gate for subsequent delta frames.
     * - Backpressure drops from the publisher are recorded in [droppedBackpressureFrames] and propagated.
     * - Adheres strictly to the scoped-borrow contract: does not retain or mutate [RtcEncodedVideoFrame.encodedData].
     */
    @Synchronized
    fun publishFrame(frame: RtcEncodedVideoFrame): RtcVideoFrameDeliveryResult {
        if (state != RealtimeEncodedVideoOutputState.STARTED) {
            droppedNotReadyFrames++
            return RtcVideoFrameDeliveryResult.droppedNotReady(
                "status=DROPPED_NOT_READY;state=${state.name}"
            )
        }

        if (!keyframeGateOpen && !frame.isKeyFrame) {
            droppedNotReadyFrames++
            return RtcVideoFrameDeliveryResult.droppedNotReady(
                "status=DROPPED_NOT_READY;reason=awaiting_keyframe"
            )
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
                if (frame.isKeyFrame) {
                    keyframeGateOpen = true
                }
            }
            RtcVideoFrameDeliveryStatus.DROPPED_BACKPRESSURE -> {
                droppedBackpressureFrames++
            }
            RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY -> {
                droppedNotReadyFrames++
            }
            RtcVideoFrameDeliveryStatus.UNSUPPORTED_FORMAT -> {
                failedFrames++
            }
            RtcVideoFrameDeliveryStatus.FAILED -> {
                failedFrames++
            }
        }

        return result
    }

    /**
     * Transitions the adapter to [RealtimeEncodedVideoOutputState.FAILED] unless already disposed,
     * recording [reason] in [lastError] and resetting the keyframe gate.
     */
    @Synchronized
    fun fail(reason: String): Map<String, Any?> {
        if (state != RealtimeEncodedVideoOutputState.DISPOSED) {
            state = RealtimeEncodedVideoOutputState.FAILED
            keyframeGateOpen = false
            lastError = reason
            return mapOf(
                "pass" to true,
                "state" to state.name,
                "keyframeGateOpen" to keyframeGateOpen,
                "raw" to "status=FAILED;reason=$reason",
                "lastError" to lastError,
            )
        }
        return mapOf(
            "pass" to false,
            "state" to state.name,
            "keyframeGateOpen" to keyframeGateOpen,
            "raw" to "status=DISPOSED;cannot_fail_disposed=true",
            "lastError" to lastError,
        )
    }

    /**
     * Permanently disposes the adapter and transitions to terminal [RealtimeEncodedVideoOutputState.DISPOSED].
     * Resets the keyframe gate. Idempotent.
     */
    @Synchronized
    fun dispose(): Map<String, Any?> {
        state = RealtimeEncodedVideoOutputState.DISPOSED
        keyframeGateOpen = false
        return mapOf(
            "pass" to true,
            "state" to state.name,
            "keyframeGateOpen" to keyframeGateOpen,
            "raw" to "status=DISPOSED",
        )
    }

    /**
     * Returns the current lifecycle state under the adapter lock.
     */
    @Synchronized
    fun currentState(): RealtimeEncodedVideoOutputState = state

    /**
     * Returns whether the first-keyframe gate is currently open.
     */
    @Synchronized
    fun isKeyframeGateOpen(): Boolean = keyframeGateOpen

    /**
     * Returns an immutable snapshot map of current lifecycle state, keyframe gate status, and delivery counters.
     */
    @Synchronized
    fun snapshot(): Map<String, Any?> = mapOf(
        "state" to state.name,
        "keyframeGateOpen" to keyframeGateOpen,
        "acceptedFrames" to acceptedFrames,
        "droppedBackpressureFrames" to droppedBackpressureFrames,
        "droppedNotReadyFrames" to droppedNotReadyFrames,
        "failedFrames" to failedFrames,
        "lastError" to lastError,
    )
}
