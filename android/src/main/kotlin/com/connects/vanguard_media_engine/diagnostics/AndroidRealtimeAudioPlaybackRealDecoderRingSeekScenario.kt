package com.connects.vanguard_media_engine.diagnostics

import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSinkBridge
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.REAL_RING_DRAIN_WAIT_BOUND_MS
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.SCENARIO_REAL_DECODER_RING_SEEK_TO_EOS
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.FailClosed

// ── AndroidRealtimeAudioPlaybackRealDecoderRingSeekScenario (P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER-RING-SEEK, Y20) ─
//
// Scenario 16: the ONE isolated real-decoder ring TRUE FORWARD SEEK proof.
// Runs after Scenario 15 (Y19) and reuses the Y18c route exactly: the
// diagnostics-owned [AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource]
// feeds the PRODUCTION [VanguardRealtimeAudioPlaybackSinkBridge] through the
// Y18a `frameSource` seam with NO state machine, no session, no production
// feed. It proves a true content skip: target frame T strictly past the
// hold frame H, skipped = T - H > 0, expected playable frames =
// expectedFrames - skipped.
//
// Hold / target derivation (from the FROZEN geometry, never hardcoded): the
// native worker rejects a Seek command until its one-second realtime timing
// gate closed, i.e. until the dispatch cursor passed
// F1 = ceil(8192 / window) * window + sampleRate frames. H is therefore the
// first window-aligned frame past F1 plus [HOLD_MARGIN_WINDOWS] windows, and
// T = H + the largest window-aligned skip not exceeding [SEEK_SKIP_SEC]
// seconds; both must leave at least one output ring of post-seek content
// before the aligned expectedFrames. (The packet's illustrative H = 20480 at
// 48 kHz lies below that native gate and would fail closed with
// timing_window_unavailable; the derived H is reported as telemetry.)
//
// Order (coordinator thread; every ring control executes on the ring-owner
// thread, every sink control on the sink thread):
//   ring open -> sink start/ready -> ring Start -> sink allowDrain
//   -> ring.quiesceFeedForSeek(H): feed cap armed at H, feed runs under it
//      (drains serviced) and is held at exactly H at a clean boundary
//   -> wait for the PRODUCTION sink to drain every pushed frame to H
//      (framesRead == H; the sink is the sole output consumer, the ring
//      never drains privately)
//   -> sink.requestSeekPark + awaitParked   (sink seek-parked BEFORE the seek)
//   -> sink.requestFlush(expectedFrames - T, T) + awaitFlushed
//   -> ring.seekTransport(T): native quiescence proof at H (snapshot only),
//      native joint seek to T, generator + extractor + codec re-anchor,
//      post-seek lockstep prefill, ack-only output ack consume (zero discard)
//   -> sink.unpark + awaitRunning (sink epoch opens at T on the flushed track)
//   -> sink drains to the NATIVE seek-aware eosDrained verdict -> ring close
//      (final snapshot, destroy, join), exactly like Y18c/Y19.
//
// Deadline: the shared absolute deadline is the smoke deadline plus
// [DEADLINE_EXTENSION_MS] (recorded as `y20DeadlineBudgetMs`). Every wait is
// bounded; nothing here retries, pauses, or feeds anything back.
//
// Honest non-claims: diagnostic proof only. No product/editor/app/ConnectsApp/
// iOS/streaming/cache, no pause/resume in this scenario, no dead object, no
// feedback control loop, no pacing correction, no resampling, no exact
// keyframe landing claim (extractor landing at or before T is reported), no
// currentPosition authority switch, no A/V sync closure, no fleet claim.
class AndroidRealtimeAudioPlaybackRealDecoderRingSeekScenario(
    private val config: SmokeConfig,
    private val isDisposed: () -> Boolean,
    // Registers / clears the live sink + ring for the coordinator's disposeAll().
    private val bindActive: (
        VanguardRealtimeAudioPlaybackSinkBridge?,
        AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource?,
    ) -> Unit,
) {
    companion object {
        // Windows of margin past the native one-second timing gate so the
        // dispatch that closes the gate is provably inside the pre-seek span.
        const val HOLD_MARGIN_WINDOWS = 8L
        // Forward skip length (window-aligned down) between H and T.
        const val SEEK_SKIP_SEC = 0.5
        // Per-scenario deadline extension over the smoke deadline.
        const val DEADLINE_EXTENSION_MS = 5_000L
        const val CONTROL_TIMEOUT_MS = 5_000L
        // The feed hold may need more than one realtime second to be reached
        // (H lies past the native one-second gate) plus decode slack.
        const val HOLD_TIMEOUT_MS = 15_000L
        // The owner-executed seek covers native quiescence, the joint seek,
        // the media re-anchor and the post-seek prefill decode.
        const val SEEK_TIMEOUT_MS = 10_000L
        const val SINK_DRAIN_TO_HOLD_SLACK_MS = 5_000L
        const val SINK_READY_TIMEOUT_MS = 5_000L
        const val JOIN_TIMEOUT_MS = 3_000L
        const val POLL_SLICE_MS = 2L
    }

    // Coordinator-thread ordering facts handed to the lane evaluator; every
    // wall value is relative to the scenario start, -1 when never reached.
    class Facts {
        var coordinatorThreadId = -1L
        var deadlineBudgetMs = -1L
        var realDecoderSourceUsed = false
        var stateMachineSourceUsed = false
        var sinkReadyBeforeTransportStart = false
        var drainAllowedAfterTransportStart = false
        // Derived seek geometry.
        var window = -1L
        var sampleRate = -1L
        var expectedFrames = -1L
        var nativeTimingGateFrames = -1L
        var holdFrame = -1L
        var targetFrame = -1L
        var skipFrames = -1L
        var expectedPlayableFrames = -1L
        var postSeekExpectedFrames = -1L
        var holdAboveNativeTimingGate = false
        // Hold.
        var holdAckOk = false
        var holdAckWallMs = -1L
        var feedHeldObserved = false
        var firstPlayObservedAtHold = false
        var ingestCompleteAtHold = true
        var sinkFramesReadAtHoldAck = -1L
        var sinkDrainedToHold = false
        var sinkDrainedToHoldWallMs = -1L
        var sinkFramesReadAtHoldDrained = -1L
        var ringFramesReadBySinkAtHoldDrained = -1L
        // Sink seek park + flush BEFORE the native seek.
        var sinkSeekParkRequested = false
        var sinkParked = false
        var sinkParkedWallMs = -1L
        var sinkPhaseAtFlush = "none"
        var sinkFramesReadAtPark = -1L
        var sinkFlushRequested = false
        var sinkFlushed = false
        var sinkFlushedWallMs = -1L
        var sinkFlushCountAtRingSeek = -1
        var sinkPhaseAtRingSeek = "none"
        // Ring seek.
        var ringSeekRequestedWallMs = -1L
        var ringSeekAckOk = false
        var ringSeekAckWallMs = -1L
        var sinkParkedBeforeRingSeek = false
        var sinkFlushedBeforeRingSeek = false
        var ringSeekExercisedObserved = false
        var ringSeekInProgressAfterAck = true
        var ringFeedHeldAfterSeek = true
        var ringEffectiveExpectedFramesAfterSeek = -1L
        var sinkFramesReadAtRingSeekAck = -1L
        // Sink unpark AFTER the ring seek.
        var sinkUnparkRequestedWallMs = -1L
        var sinkUnparked = false
        var sinkRunning = false
        var sinkRunningWallMs = -1L
        var sinkUnparkAfterRingSeek = false
        var sinkFramesReadAtUnpark = -1L
        // Drain to EOS and close.
        var sinkExited = false
        var sinkExitedWallMs = -1L
        var sinkJoined = false
        var ringClosed = false
        var ringOpenWallMs = -1L
        var sinkReadyWallMs = -1L
        var transportStartedWallMs = -1L
        var drainAllowedWallMs = -1L
    }

    fun run(): ScenarioOutcome {
        val outcome = ScenarioOutcome(SCENARIO_REAL_DECODER_RING_SEEK_TO_EOS)
        val f = Facts()
        val wallStart = SystemClock.elapsedRealtime()
        fun wall(): Long = SystemClock.elapsedRealtime() - wallStart
        f.coordinatorThreadId = Thread.currentThread().id
        val window = config.maxFramesPerMix
        val deadlineBudgetMs = config.deadlineMs + DEADLINE_EXTENSION_MS
        val deadlineAtMs = wallStart + deadlineBudgetMs
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
        m["y20DeadlineBudgetMs"] = deadlineBudgetMs
        m["y20ControlTimeoutMs"] = CONTROL_TIMEOUT_MS
        m["y20HoldTimeoutMs"] = HOLD_TIMEOUT_MS
        m["y20SeekTimeoutMs"] = SEEK_TIMEOUT_MS
        m["y20HoldMarginWindows"] = HOLD_MARGIN_WINDOWS
        m["y20SeekSkipSec"] = SEEK_SKIP_SEC
        m["y20SinkMaxSeekHoldMs"] = config.maxSeekHoldMs
        m["y20HoldFrameDerivation"] =
            "align_up(ceil(native_timing_warmup / window) * window + sample_rate + 1) + hold_margin_windows * window"
        try {
            if (isDisposed()) throw FailClosed("coordinator_disposed")
            require(window in 1..VanguardRealtimePlaybackNativeSession.MAX_FRAMES_PER_MIX_CAP, "real_ring_geometry_invalid:$window")
            require(config.maxSeekHoldMs in 1 until deadlineBudgetMs, "real_ring_seek_hold_cap_invalid:${config.maxSeekHoldMs}:$deadlineBudgetMs")

            val r = AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource(
                AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Config(
                    sourcePath = config.sourcePath,
                    maxDurationSec = config.maxDurationSec,
                    maxFramesPerMix = window,
                    deadlineAtMs = deadlineAtMs,
                    drainWaitBoundMs = REAL_RING_DRAIN_WAIT_BOUND_MS,
                    threadName = "Y20RealRingOwner",
                ),
            )
            ring = r
            bindActive(null, r)
            require(r.open(deadlineBudgetMs), "real_ring_open_failed:${r.currentFailureReason}:${r.currentStage}")
            f.ringOpenWallMs = wall()
            val g = r.frozenGeometry ?: throw FailClosed("real_ring_geometry_missing")
            geometry = g

            // Derive H / T / skip from the frozen geometry (class comment).
            deriveSeekGeometry(f, g)
            m["y20HoldFrame"] = f.holdFrame
            m["y20TargetFrame"] = f.targetFrame
            m["y20SkipFrames"] = f.skipFrames
            m["y20ExpectedPlayableFrames"] = f.expectedPlayableFrames
            m["y20PostSeekExpectedFrames"] = f.postSeekExpectedFrames
            m["y20NativeTimingGateFrames"] = f.nativeTimingGateFrames

            // Production sink from the FROZEN real geometry, frame source only,
            // with the smoke's seek hold cap (covers the ring's whole seek).
            val sinkConfig = VanguardRealtimeAudioPlaybackSinkBridge.Config(
                stateMachine = null,
                sampleRate = g.sampleRate,
                channelCount = g.channelCount,
                maxFramesPerMix = window,
                declaredFrameCount = g.expectedFrames,
                gain = config.gain,
                maxSeekHoldMs = config.maxSeekHoldMs,
                deadlineAtMs = deadlineAtMs,
                threadName = "Y20RealRingSink",
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

            // 1. Arm the feed cap at H right away (the feed is still far below
            //    H) and block until the owner holds the feed exactly there.
            f.holdAckOk = r.quiesceFeedForSeek(f.holdFrame, HOLD_TIMEOUT_MS)
            f.holdAckWallMs = wall()
            require(f.holdAckOk, "real_ring_seek_hold_failed:${r.currentFailureReason}:${r.currentStage}")
            f.feedHeldObserved = r.isFeedHeldForSeek
            f.firstPlayObservedAtHold = k.hasPlayed && k.framesRead > 0L
            f.ingestCompleteAtHold = r.ingestCompleteObserved
            f.sinkFramesReadAtHoldAck = k.framesRead
            require(f.firstPlayObservedAtHold, "sink_not_played_at_hold:${k.framesRead}")
            require(!f.ingestCompleteAtHold, "real_ring_ingest_complete_at_hold")

            // 2. The production sink drains every pushed frame up to H (the
            //    ring never drains privately).
            awaitSinkDrainedToHold(k, r, f.holdFrame, g.sampleRate)
            f.sinkDrainedToHold = true
            f.sinkDrainedToHoldWallMs = wall()
            f.sinkFramesReadAtHoldDrained = k.framesRead
            f.ringFramesReadBySinkAtHoldDrained = r.framesReadBySinkObserved

            // 3. Sink seek-parks FIRST.
            f.sinkSeekParkRequested = k.requestSeekPark()
            require(f.sinkSeekParkRequested, "sink_seek_park_rejected:${k.phase}")
            f.sinkParked = k.awaitParked(CONTROL_TIMEOUT_MS)
            require(f.sinkParked, "sink_not_parked:${k.phase}:${k.currentExitReason}")
            f.sinkParkedWallMs = wall()
            f.sinkFramesReadAtPark = k.framesRead
            f.sinkPhaseAtFlush = k.phase.name

            // 4. Sink flush with the post-seek read budget and the target.
            f.sinkFlushRequested = k.requestFlush(f.postSeekExpectedFrames, f.targetFrame)
            require(f.sinkFlushRequested, "sink_flush_rejected:${k.phase}")
            f.sinkFlushed = k.awaitFlushed(CONTROL_TIMEOUT_MS)
            require(f.sinkFlushed, "sink_not_flushed:${k.phase}:${k.currentExitReason}")
            f.sinkFlushedWallMs = wall()
            f.sinkFlushCountAtRingSeek = k.currentFlushCount
            f.sinkPhaseAtRingSeek = k.phase.name

            // 5. Ring seek (owner thread: native quiescence proof, native joint
            //    seek, re-anchor, prefill, ack-only ack consume).
            f.ringSeekRequestedWallMs = wall()
            f.ringSeekAckOk = r.seekTransport(f.targetFrame, SEEK_TIMEOUT_MS)
            f.ringSeekAckWallMs = wall()
            require(f.ringSeekAckOk, "real_ring_seek_failed:${r.currentFailureReason}:${r.currentStage}")
            f.sinkParkedBeforeRingSeek = f.sinkParked && f.sinkParkedWallMs <= f.ringSeekRequestedWallMs
            f.sinkFlushedBeforeRingSeek = f.sinkFlushed && f.sinkFlushedWallMs <= f.ringSeekRequestedWallMs
            f.ringSeekExercisedObserved = r.seekExercisedObserved
            f.ringSeekInProgressAfterAck = r.isSeekInProgress
            f.ringFeedHeldAfterSeek = r.isFeedHeldForSeek
            f.ringEffectiveExpectedFramesAfterSeek = r.effectiveExpectedFramesObserved
            f.sinkFramesReadAtRingSeekAck = k.framesRead

            // 6. Sink unparks AFTER the ring seek (epoch opens at T).
            f.sinkUnparkRequestedWallMs = wall()
            f.sinkUnparked = k.unpark()
            require(f.sinkUnparked, "sink_unpark_rejected:${k.phase}")
            f.sinkRunning = k.awaitRunning(CONTROL_TIMEOUT_MS)
            require(f.sinkRunning, "sink_not_running:${k.phase}:${k.currentExitReason}")
            f.sinkRunningWallMs = wall()
            f.sinkUnparkAfterRingSeek = f.sinkUnparkRequestedWallMs >= f.ringSeekAckWallMs
            f.sinkFramesReadAtUnpark = k.framesRead

            // 7. Drain to the native seek-aware EOS verdict and close, like Y18c.
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
            AndroidRealtimeAudioPlaybackRealDecoderRingSeekLaneEvaluator.evaluate(
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

    // H / T / skip from the frozen geometry (class comment); fails closed
    // when the aligned timeline cannot host the gate, the hold, the skip and
    // one output ring of post-seek content.
    private fun deriveSeekGeometry(f: Facts, g: AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Geometry) {
        val window = g.maxFramesPerMix.toLong()
        val sampleRate = g.sampleRate.toLong()
        val expectedFrames = g.expectedFrames
        val outputRing = AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.DEFAULT_OUTPUT_RING_CAPACITY_FRAMES.toLong()
        fun alignUp(v: Long): Long = (v + window - 1L) / window * window
        fun alignDown(v: Long): Long = v / window * window
        val timingF0 = alignUp(AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.NATIVE_TIMING_WARMUP_FRAMES)
        val timingF1 = timingF0 + sampleRate
        val holdFrame = alignUp(timingF1 + 1L) + HOLD_MARGIN_WINDOWS * window
        val skipFrames = alignDown((SEEK_SKIP_SEC * sampleRate).toLong())
        val targetFrame = holdFrame + skipFrames
        f.window = window
        f.sampleRate = sampleRate
        f.expectedFrames = expectedFrames
        f.nativeTimingGateFrames = timingF1
        f.holdFrame = holdFrame
        f.targetFrame = targetFrame
        f.skipFrames = skipFrames
        f.expectedPlayableFrames = expectedFrames - skipFrames
        f.postSeekExpectedFrames = expectedFrames - targetFrame
        f.holdAboveNativeTimingGate = holdFrame > timingF1
        require(holdFrame > 0L && holdFrame % window == 0L, "y20_hold_frame_invalid:$holdFrame:$window")
        require(skipFrames >= window, "y20_skip_too_small:$skipFrames:$window")
        require(targetFrame > holdFrame && targetFrame % window == 0L, "y20_target_frame_invalid:$targetFrame:$holdFrame")
        require(
            targetFrame + outputRing <= expectedFrames,
            "y20_timeline_too_short_for_seek:$expectedFrames:$targetFrame:$outputRing",
        )
        require(f.holdAboveNativeTimingGate, "y20_hold_below_native_timing_gate:$holdFrame:$timingF1")
    }

    // Bounded wait until the production sink has read exactly the hold frame
    // count (the worker pushes the last pre-seek window at realtime pace).
    private fun awaitSinkDrainedToHold(
        k: VanguardRealtimeAudioPlaybackSinkBridge,
        r: AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource,
        holdFrame: Long,
        sampleRate: Int,
    ) {
        val budgetMs = holdFrame * 1_000L / sampleRate.toLong() + SINK_DRAIN_TO_HOLD_SLACK_MS
        val untilMs = SystemClock.elapsedRealtime() + budgetMs
        while (true) {
            val read = k.framesRead
            if (read > holdFrame) throw FailClosed("sink_read_past_hold:$read:$holdFrame")
            if (read == holdFrame && r.framesReadBySinkObserved == holdFrame) return
            if (isDisposed()) throw FailClosed("coordinator_disposed")
            if (k.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.EXITED) {
                throw FailClosed("sink_exited_before_hold_drained:${k.currentExitReason}")
            }
            if (r.currentStage == AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.FAILED) {
                throw FailClosed("real_ring_failed_before_hold_drained:${r.currentFailureReason}")
            }
            if (SystemClock.elapsedRealtime() >= untilMs) throw FailClosed("sink_hold_drain_timeout:$read:$holdFrame")
            SystemClock.sleep(POLL_SLICE_MS)
        }
    }
}
