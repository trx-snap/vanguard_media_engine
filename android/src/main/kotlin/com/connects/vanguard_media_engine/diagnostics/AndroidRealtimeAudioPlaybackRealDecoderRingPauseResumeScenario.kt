package com.connects.vanguard_media_engine.diagnostics

import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSinkBridge
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.REAL_RING_DRAIN_WAIT_BOUND_MS
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.SCENARIO_REAL_DECODER_RING_PAUSE_RESUME_TO_EOS
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.FailClosed

// ── AndroidRealtimeAudioPlaybackRealDecoderRingPauseResumeScenario (P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER-RING-PAUSE-RESUME, Y19) ─
//
// Scenario 15: the ONE isolated real-decoder ring PAUSE/RESUME proof. Runs
// after Scenario 14 (Y18c) and reuses its exact route: the diagnostics-owned
// [AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource] feeds the
// PRODUCTION [VanguardRealtimeAudioPlaybackSinkBridge] through the Y18a
// `frameSource` seam with NO state machine, no session, no production feed.
//
// Order (coordinator thread; every ring control executes on the ring-owner
// thread, every sink control on the sink thread):
//   ring open -> sink start/ready -> ring Start -> sink allowDrain
//   -> wait for the first productive sink drain (played, framesRead > 0)
//      while the ring is still ingesting (!ingestComplete)
//   -> ring.quiesceFeedForPause: the owner holds the feed at its NEXT clean
//      boundary while the sink is still draining (in steady state the owner
//      is stall-bound inside the pump's make-room loop and can only reach a
//      clean boundary while drains free room; once the sink is parked no
//      such boundary is reachable any more)
//   -> sink.requestPark + awaitParked   (sink parks BEFORE the ring pauses)
//   -> ring.pauseTransport               (native Pause + processed proof)
//   -> bounded hold >= [MIN_PAUSE_HOLD_MS], below the sink's explicit
//      maxPauseHoldMs (= hold + [SINK_PAUSE_HOLD_MARGIN_MS])
//   -> ring.assertPausedHoldFrozen       (snapshot-only frozen proof)
//   -> ring.resumeTransport              (native Resume + processed proof)
//   -> sink.unpark + awaitRunning
//   -> sink drains to the NATIVE eosDrained verdict -> ring close (final
//      snapshot, destroy, join), exactly like Y18c.
//
// Deadline: the shared absolute deadline is the smoke deadline plus
// [DEADLINE_EXTENSION_MS] (recorded as `y19DeadlineBudgetMs`). Every wait is
// bounded; nothing here retries, seeks, flushes, or feeds anything back.
//
// Honest non-claims: diagnostic proof only. No product/editor/app/ConnectsApp/
// iOS/streaming/cache, no seek, no flush, no dead object, no feedback control
// loop, no pacing correction, no resampling, no currentPosition authority
// switch, no A/V sync closure, no fleet claim.
class AndroidRealtimeAudioPlaybackRealDecoderRingPauseResumeScenario(
    private val config: SmokeConfig,
    private val isDisposed: () -> Boolean,
    // Registers / clears the live sink + ring for the coordinator's disposeAll().
    private val bindActive: (
        VanguardRealtimeAudioPlaybackSinkBridge?,
        AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource?,
    ) -> Unit,
) {
    companion object {
        // Ring pause hold: at least this long (the native hold proof needs
        // worker paused waits), configurable upward through pauseHoldMs.
        const val MIN_PAUSE_HOLD_MS = 200L
        // Sink park cap = hold + margin (covers pause ack, hold assert and
        // resume ack round trips on the owner thread).
        const val SINK_PAUSE_HOLD_MARGIN_MS = 2_000L
        // Per-scenario deadline extension over the smoke deadline.
        const val DEADLINE_EXTENSION_MS = 5_000L
        const val CONTROL_TIMEOUT_MS = 5_000L
        const val FIRST_PLAY_TIMEOUT_MS = 5_000L
        const val SINK_READY_TIMEOUT_MS = 5_000L
        const val JOIN_TIMEOUT_MS = 3_000L
        const val POLL_SLICE_MS = 2L
        const val HOLD_SLICE_MS = 20L
    }

    // Coordinator-thread ordering facts handed to the lane evaluator; every
    // wall value is relative to the scenario start, -1 when never reached.
    class Facts {
        var coordinatorThreadId = -1L
        var pauseHoldMs = -1L
        var sinkMaxPauseHoldMs = -1L
        var deadlineBudgetMs = -1L
        var realDecoderSourceUsed = false
        var stateMachineSourceUsed = false
        var sinkReadyBeforeTransportStart = false
        var drainAllowedAfterTransportStart = false
        var firstPlayObserved = false
        var sinkFramesReadAtFirstPlay = -1L
        var ingestCompleteAtFirstPlay = true
        var quiesceAckOk = false
        var ringQuiescedObserved = false
        var ingestCompleteAtQuiesce = true
        var sinkFramesReadAtQuiesce = -1L
        var sinkParkRequested = false
        var sinkParked = false
        var sinkPhaseAtRingPause = "none"
        var sinkFramesReadAtPark = -1L
        var ringPauseAckOk = false
        var ringPausedObserved = false
        var sinkParkedBeforeRingPause = false
        var holdSleptMs = -1L
        var holdAssertAckOk = false
        var ringPausedDuringHold = false
        var sinkPhaseAfterHold = "none"
        var sinkFramesReadAfterHold = -1L
        var ringResumeAckOk = false
        var ringPausedAfterResume = true
        var sinkPhaseAtRingResume = "none"
        var sinkUnparked = false
        var sinkRunning = false
        var sinkUnparkAfterRingResume = false
        var sinkFramesReadAtUnpark = -1L
        var sinkExited = false
        var sinkJoined = false
        var ringClosed = false
        var ringOpenWallMs = -1L
        var sinkReadyWallMs = -1L
        var transportStartedWallMs = -1L
        var drainAllowedWallMs = -1L
        var firstPlayWallMs = -1L
        var quiesceAckWallMs = -1L
        var sinkParkedWallMs = -1L
        var ringPauseRequestedWallMs = -1L
        var ringPauseAckWallMs = -1L
        var holdAssertWallMs = -1L
        var ringResumeAckWallMs = -1L
        var sinkUnparkRequestedWallMs = -1L
        var sinkRunningWallMs = -1L
        var sinkExitedWallMs = -1L
    }

    fun run(): ScenarioOutcome {
        val outcome = ScenarioOutcome(SCENARIO_REAL_DECODER_RING_PAUSE_RESUME_TO_EOS)
        val f = Facts()
        val wallStart = SystemClock.elapsedRealtime()
        fun wall(): Long = SystemClock.elapsedRealtime() - wallStart
        f.coordinatorThreadId = Thread.currentThread().id
        val window = config.maxFramesPerMix
        val holdMs = maxOf(config.pauseHoldMs, MIN_PAUSE_HOLD_MS)
        val sinkMaxPauseHoldMs = holdMs + SINK_PAUSE_HOLD_MARGIN_MS
        val deadlineBudgetMs = config.deadlineMs + DEADLINE_EXTENSION_MS
        val deadlineAtMs = wallStart + deadlineBudgetMs
        f.pauseHoldMs = holdMs
        f.sinkMaxPauseHoldMs = sinkMaxPauseHoldMs
        f.deadlineBudgetMs = deadlineBudgetMs
        var ring: AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource? = null
        var sink: VanguardRealtimeAudioPlaybackSinkBridge? = null
        var geometry: AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Geometry? = null
        val m = outcome.metrics
        m["deadObjectInjectAfterFrames"] = 0L
        m["seekTargetSecArmed"] = 0.0
        m["enableAudioFocusResponse"] = false
        m["enableAudioRoutingResponse"] = false
        m["realRingMaxFramesPerMix"] = window
        m["realRingSourceRingCapacityFrames"] =
            AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.DEFAULT_SOURCE_RING_CAPACITY_FRAMES
        m["realRingOutputRingCapacityFrames"] =
            AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.DEFAULT_OUTPUT_RING_CAPACITY_FRAMES
        m["realRingDrainWaitBoundMs"] = REAL_RING_DRAIN_WAIT_BOUND_MS
        m["y19PauseHoldMs"] = holdMs
        m["y19MinPauseHoldMs"] = MIN_PAUSE_HOLD_MS
        m["y19SinkMaxPauseHoldMs"] = sinkMaxPauseHoldMs
        m["y19DeadlineBudgetMs"] = deadlineBudgetMs
        m["y19ControlTimeoutMs"] = CONTROL_TIMEOUT_MS
        try {
            if (isDisposed()) throw FailClosed("coordinator_disposed")
            require(window in 1..VanguardRealtimePlaybackNativeSession.MAX_FRAMES_PER_MIX_CAP, "real_ring_geometry_invalid:$window")
            require(sinkMaxPauseHoldMs < deadlineBudgetMs, "real_ring_pause_hold_exceeds_deadline:$sinkMaxPauseHoldMs:$deadlineBudgetMs")

            val r = AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource(
                AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Config(
                    sourcePath = config.sourcePath,
                    maxDurationSec = config.maxDurationSec,
                    maxFramesPerMix = window,
                    deadlineAtMs = deadlineAtMs,
                    drainWaitBoundMs = REAL_RING_DRAIN_WAIT_BOUND_MS,
                    threadName = "Y19RealRingOwner",
                ),
            )
            ring = r
            bindActive(null, r)
            require(r.open(deadlineBudgetMs), "real_ring_open_failed:${r.currentFailureReason}:${r.currentStage}")
            f.ringOpenWallMs = wall()
            val g = r.frozenGeometry ?: throw FailClosed("real_ring_geometry_missing")
            geometry = g

            // Production sink from the FROZEN real geometry, frame source only,
            // with an EXPLICIT pause hold cap that covers the ring cycle.
            val sinkConfig = VanguardRealtimeAudioPlaybackSinkBridge.Config(
                stateMachine = null,
                sampleRate = g.sampleRate,
                channelCount = g.channelCount,
                maxFramesPerMix = window,
                declaredFrameCount = g.expectedFrames,
                gain = config.gain,
                maxPauseHoldMs = sinkMaxPauseHoldMs,
                deadlineAtMs = deadlineAtMs,
                threadName = "Y19RealRingSink",
                externallyCancelled = { isDisposed() },
                frameSource = r,
            )
            f.realDecoderSourceUsed = sinkConfig.frameSource === r
            f.stateMachineSourceUsed = sinkConfig.stateMachine != null
            val k = VanguardRealtimeAudioPlaybackSinkBridge(sinkConfig)
            sink = k
            bindActive(k, r)
            require(k.start(), "sink_start_rejected")
            require(k.awaitReady(SINK_READY_TIMEOUT_MS), "sink_not_ready:${k.currentExitReason}")
            f.sinkReadyWallMs = wall()
            f.sinkReadyBeforeTransportStart = k.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.READY

            require(r.startTransport(deadlineBudgetMs), "real_ring_start_failed:${r.currentFailureReason}:${r.currentStage}")
            f.transportStartedWallMs = wall()
            k.allowDrain()
            f.drainAllowedWallMs = wall()
            f.drainAllowedAfterTransportStart = f.drainAllowedWallMs >= f.transportStartedWallMs

            // 1. First productive playback while the ring is still ingesting.
            awaitFirstPlay(k, r)
            f.firstPlayObserved = true
            f.firstPlayWallMs = wall()
            f.sinkFramesReadAtFirstPlay = k.framesRead
            f.ingestCompleteAtFirstPlay = r.ingestCompleteObserved
            require(!f.ingestCompleteAtFirstPlay, "real_ring_ingest_complete_before_pause")

            // 2. Hold the feed at the next clean boundary (sink still draining).
            f.quiesceAckOk = r.quiesceFeedForPause(CONTROL_TIMEOUT_MS)
            f.quiesceAckWallMs = wall()
            require(f.quiesceAckOk, "real_ring_quiesce_failed:${r.currentFailureReason}:${r.currentStage}")
            f.ringQuiescedObserved = r.isFeedQuiesced
            f.ingestCompleteAtQuiesce = r.ingestCompleteObserved
            f.sinkFramesReadAtQuiesce = k.framesRead
            require(!f.ingestCompleteAtQuiesce, "real_ring_ingest_complete_at_quiesce")

            // 3. Sink parks FIRST.
            f.sinkParkRequested = k.requestPark()
            require(f.sinkParkRequested, "sink_park_rejected:${k.phase}")
            f.sinkParked = k.awaitParked(CONTROL_TIMEOUT_MS)
            require(f.sinkParked, "sink_not_parked:${k.phase}:${k.currentExitReason}")
            f.sinkParkedWallMs = wall()
            f.sinkFramesReadAtPark = k.framesRead
            f.sinkPhaseAtRingPause = k.phase.name

            // 4. Ring pause (native Pause + processed-snapshot proof, owner thread).
            f.ringPauseRequestedWallMs = wall()
            f.ringPauseAckOk = r.pauseTransport(CONTROL_TIMEOUT_MS)
            f.ringPauseAckWallMs = wall()
            require(f.ringPauseAckOk, "real_ring_pause_failed:${r.currentFailureReason}:${r.currentStage}")
            f.ringPausedObserved = r.isTransportPaused
            f.sinkParkedBeforeRingPause = f.sinkParked && f.sinkParkedWallMs <= f.ringPauseRequestedWallMs

            // 5. Bounded hold (monotonic clock; disposal / sink exit / ring failure abort it).
            f.holdSleptMs = holdPaused(k, r, holdMs)

            // 6. Snapshot-only frozen proof after the hold.
            f.holdAssertAckOk = r.assertPausedHoldFrozen(CONTROL_TIMEOUT_MS)
            f.holdAssertWallMs = wall()
            require(f.holdAssertAckOk, "real_ring_hold_assert_failed:${r.currentFailureReason}:${r.currentStage}")
            f.ringPausedDuringHold = r.isTransportPaused
            f.sinkPhaseAfterHold = k.phase.name
            f.sinkFramesReadAfterHold = k.framesRead

            // 7. Ring resume (native Resume + processed-snapshot proof, owner thread).
            f.ringResumeAckOk = r.resumeTransport(CONTROL_TIMEOUT_MS)
            f.ringResumeAckWallMs = wall()
            require(f.ringResumeAckOk, "real_ring_resume_failed:${r.currentFailureReason}:${r.currentStage}")
            f.ringPausedAfterResume = r.isTransportPaused
            f.sinkPhaseAtRingResume = k.phase.name

            // 8. Sink unparks AFTER the ring resumed.
            f.sinkUnparkRequestedWallMs = wall()
            f.sinkUnparked = k.unpark()
            require(f.sinkUnparked, "sink_unpark_rejected:${k.phase}")
            f.sinkRunning = k.awaitRunning(CONTROL_TIMEOUT_MS)
            require(f.sinkRunning, "sink_not_running:${k.phase}:${k.currentExitReason}")
            f.sinkRunningWallMs = wall()
            f.sinkUnparkAfterRingResume = f.sinkUnparkRequestedWallMs >= f.ringResumeAckWallMs
            f.sinkFramesReadAtUnpark = k.framesRead

            // 9. Drain to the native EOS verdict and close, like Y18c.
            f.sinkExited = k.awaitExit(deadlineBudgetMs)
            f.sinkExitedWallMs = wall()
            require(f.sinkExited, "sink_not_exited:${k.currentExitReason}")
            f.sinkJoined = k.join(JOIN_TIMEOUT_MS)
            require(f.sinkJoined, "sink_not_joined:${k.currentExitReason}")
            f.ringClosed = r.close(deadlineBudgetMs)
            require(f.ringClosed, "real_ring_close_failed:${r.currentFailureReason}:${r.currentStage}")
        } catch (e: FailClosed) {
            outcome.failureReason = e.reason
        } catch (t: Throwable) {
            outcome.failureReason = "exception:${t.javaClass.simpleName}:${t.message}"
        } finally {
            val k = sink
            val r = ring
            try {
                k?.cancel()
                if (k != null && !f.sinkJoined) f.sinkJoined = k.join(JOIN_TIMEOUT_MS)
            } catch (_: Throwable) {}
            try {
                if (r != null && !f.ringClosed) f.ringClosed = r.close(JOIN_TIMEOUT_MS)
            } catch (_: Throwable) {}
            bindActive(null, null)
            val sinkTelemetry = k?.telemetry()
            val ringTelemetry = r?.telemetry()
            if (outcome.failureReason.isBlank() && ringTelemetry != null && ringTelemetry.failureReason.isNotBlank()) {
                outcome.failureReason = "real_ring:${ringTelemetry.failureReason}"
            }
            if (outcome.failureReason.isBlank() && sinkTelemetry != null &&
                sinkTelemetry.exitReason != VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS
            ) {
                outcome.failureReason = "sink_exit:${sinkTelemetry.exitReason}"
            }
            AndroidRealtimeAudioPlaybackRealDecoderRingPauseResumeLaneEvaluator.evaluate(
                sink = sinkTelemetry,
                ring = ringTelemetry,
                sinkClock = k?.clockSnapshot(),
                geometry = geometry,
                facts = f,
                config = config,
                out = outcome,
            )
            m["scenarioWallMs"] = wall()
            m["failureReason"] = outcome.failureReason
        }
        return outcome
    }

    private fun require(condition: Boolean, reason: String) {
        if (!condition) throw FailClosed(reason)
    }

    // Bounded wait for the sink's first productive drain + AudioTrack.play.
    private fun awaitFirstPlay(
        k: VanguardRealtimeAudioPlaybackSinkBridge,
        r: AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource,
    ) {
        val untilMs = SystemClock.elapsedRealtime() + FIRST_PLAY_TIMEOUT_MS
        while (!(k.hasPlayed && k.framesRead > 0L)) {
            if (isDisposed()) throw FailClosed("coordinator_disposed")
            if (k.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.EXITED) {
                throw FailClosed("sink_exited_before_first_play:${k.currentExitReason}")
            }
            if (r.currentStage == AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.FAILED) {
                throw FailClosed("real_ring_failed_before_first_play:${r.currentFailureReason}")
            }
            if (SystemClock.elapsedRealtime() >= untilMs) throw FailClosed("sink_first_play_timeout")
            SystemClock.sleep(POLL_SLICE_MS)
        }
    }

    // Bounded paused hold on the coordinator thread; returns the slept ms
    // (monotonic). Aborts on disposal, sink exit or ring failure.
    private fun holdPaused(
        k: VanguardRealtimeAudioPlaybackSinkBridge,
        r: AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource,
        holdMs: Long,
    ): Long {
        val startNs = System.nanoTime()
        val holdNs = holdMs * 1_000_000L
        while (true) {
            val elapsedNs = System.nanoTime() - startNs
            if (elapsedNs >= holdNs) return elapsedNs / 1_000_000L
            if (isDisposed()) throw FailClosed("coordinator_disposed")
            if (k.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.EXITED) {
                throw FailClosed("sink_exited_during_hold:${k.currentExitReason}")
            }
            if (r.currentStage == AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.FAILED) {
                throw FailClosed("real_ring_failed_during_hold:${r.currentFailureReason}")
            }
            val remainingMs = (holdNs - elapsedNs + 999_999L) / 1_000_000L
            SystemClock.sleep(minOf(HOLD_SLICE_MS, remainingMs).coerceAtLeast(1L))
        }
    }
}
