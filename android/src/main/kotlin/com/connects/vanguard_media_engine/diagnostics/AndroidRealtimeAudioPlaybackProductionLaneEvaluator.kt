package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioTrack
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSinkBridge
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSinkTelemetry
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackDecoderFeed
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackPresentationClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackClockCorrelation
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.DEAD_OBJECT_PUBLICATION_LAG_BUDGET_MS
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.DEFAULT_BACKWARD_SEEK_TARGET_SEC
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.DEFAULT_DUCK_GAIN
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_AUDIO_TRACK_RELEASED_ONCE
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_BACKWARD_CLOCK_CORRELATION
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_BACKWARD_DECODER_REANCHOR
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_BACKWARD_DRIFT_SAMPLE_BOUNDED
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_BACKWARD_NO_FEEDBACK
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_BACKWARD_POSITION_QUERY_REBASE
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_BACKWARD_POST_SEEK_FRAME_ACCOUNTING
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_BACKWARD_SEEK_ADMISSION
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_BACKWARD_SEEK_CLOCK_EPOCH_REBASE
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_BACKWARD_SEEK_COMMAND
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_BACKWARD_SEEK_QUIESCE_ACCOUNTING
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_BACKWARD_SEEK_REPEATED_REJECT
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_BACKWARD_SINK_FLUSH_AT_SEEK
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_BACKWARD_STALE_GENERATION_REJECTED
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_BOUNDED_PAUSE_RESUME
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CHECKSUM_IDENTITY
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CLOCK_ANCHORED
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CLOCK_AUTHORITY_UNCHANGED
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CLOCK_CORRELATION_TELEMETRY
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CLOCK_EPOCH_BALANCED
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CLOCK_MONOTONIC
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CLOCK_OBSERVATION_NO_FEEDBACK
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CLOCK_PAUSE_FROZEN
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CURRENT_POSITION_POLLER_MONOTONIC
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CURRENT_POSITION_QUERY_SURFACE
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CURRENT_POSITION_READ_COUNTER_ISOLATION
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_DRIFT_SAMPLE_GENERATION_PINNED
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_DRIFT_SAMPLE_NO_FEEDBACK
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_DRIFT_SAMPLE_WORKER_OWNED
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_DEAD_OBJECT_CLOCK_EPOCH
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_DEAD_OBJECT_RECOVERY
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_DEAD_OBJECT_REMAINDER
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_DECODER_SEEK_REANCHOR
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_FOCUS_DUCK_RESTORE
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_FOCUS_MONITOR_TEARDOWN
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_FOCUS_NOISY_TERMINAL_PAUSE
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_FOCUS_PERMANENT_LOSS_PAUSE
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_FOCUS_SETUP
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_FOCUS_TRANSIENT_PAUSE_RESUME
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_FORMAT_PROBE
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_NATIVE_AUDIO_CLOCK_SNAPSHOT_PUBLISHED
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_NONZERO_GAIN
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_NO_FEEDBACK
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_PLAYTHROUGH_ACCOUNTING
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_POSITION_AT_EOS_NO_RUNAWAY
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_POSITION_QUERY_DEAD_OBJECT_REBASE
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_POSITION_QUERY_PAUSE_HOLD_FROZEN
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_POSITION_QUERY_POST_TEARDOWN_LATCHED
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_POSITION_QUERY_REPEATED_SEEK_BASE_ADVANCE
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_POSITION_QUERY_SEEK_BASE_ADVANCE
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_POST_SEEK_DRAIN
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_PRE_ROLL
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_PRESENTATION_LAG_BOUNDED
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_PRESENTATION_LAG_TELEMETRY
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_PROOF_BOUNDARY
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_REPEATED_SEEK_COMMAND
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_REPEATED_SEEK_CUMULATIVE_ACCOUNTING
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_REPEATED_SEEK_THIRD_REJECT
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_RING_FRAME_SOURCE
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_ROUTING_MONITOR_TEARDOWN
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_ROUTING_SETUP
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_ROUTE_CHANGE_OBSERVATION
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_ROUTE_DISCONNECT_RESUME_BLOCKED
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_ROUTE_DISCONNECT_TERMINAL_PAUSE
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_SEEK_CLOCK_EPOCH
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_SEEK_COMMAND
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_SEEK_QUIESCE_ACCOUNTING
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_SINK_FLUSH_AT_SEEK
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_STALE_GENERATION_REJECTED
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_START
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_THREAD_OWNERSHIP
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_TRANSPORT_DISPOSED
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.PROOF_BOUNDARY
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.PROOF_BOUNDARY_TOKENS
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.REQUIRED_LANES

// Per-invocation Y8a/Y8b/Y9/Y10b/Y11b/Y12/Y13/Y17 smoke arguments, shared by scenario sequencing
// (coordinator) and lane evaluation (this file).
data class SmokeConfig(
    val sourcePath: String,
    val maxDurationSec: Double,
    val maxFramesPerMix: Int,
    val gain: Float,
    val deadlineMs: Long,
    val pauseHoldMs: Long,
    val maxPauseHoldMs: Long,
    val stopAfterMs: Long,
    val deadObjectInjectAfterFrames: Long,
    // Y9 forward-seek scenario arguments.
    val seekTargetSec: Double,
    val preSeekHoldWindows: Int,
    val maxSeekHoldMs: Long,
    // Y10b repeated forward-seek scenario arguments.
    val secondSeekTargetSec: Double,
    // Y11b focus response arguments.
    val duckGain: Float = DEFAULT_DUCK_GAIN,
    // Y17 backward-seek scenario arguments.
    val seekBackward: Boolean = false,
    val backwardSeekTargetSec: Double = DEFAULT_BACKWARD_SEEK_TARGET_SEC,
)

// Per-scenario expected AudioTrack instance/dead-object accounting.
data class SinkExpectation(
    val audioTracksCreated: Int,
    val oldTrackReleases: Int,
    val deadObjectsInjected: Long,
    val deadObjectsObserved: Long,
)

// Lanes and metrics collected for one scenario run; mutated in place by the
// evaluation functions below and read back by the coordinator for reporting.
class ScenarioOutcome(val name: String) {
    val lanes = linkedMapOf<String, Boolean>()
    val metrics = linkedMapOf<String, Any?>()
    var failureReason = ""
}

// Y13 off-thread poller metrics for the presentation-clock query surface scenario.
data class PresentationClockPollerMetrics(
    val pollCount: Long,
    val validCount: Long,
    val regressionCount: Long,
    val frameReadCount: Long,
    val usReadCount: Long,
    val lastFrame: Long,
    val lastUs: Long,
    val minFrame: Long,
    val maxFrame: Long,
    val minUs: Long,
    val maxUs: Long,
    val threadId: Long,
    val joined: Boolean,
    val error: String,
    val coordinatorThreadId: Long = 0L,
)

// Pure lane evaluation, A-prime dead-object base-step decomposition, and lane
// aggregation for the Y8a/Y8b/Y9/Y10b/Y11b/Y12/Y13 production smoke coordinator. Every function
// here reads already-captured session/sink/clock snapshots; none owns a
// thread, session, handler, AudioTrack instance, or lifecycle decision.
object AndroidRealtimeAudioPlaybackProductionLaneEvaluator {

    fun evaluateCommon(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        expect: SinkExpectation,
        out: ScenarioOutcome,
        coordinatorThreadId: Long,
    ) {
        val fmt = final.format ?: throw AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.FailClosed("format_missing")
        val sink = final.sink ?: throw AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.FailClosed("sink_missing")
        val clock = final.clock ?: throw AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.FailClosed("clock_missing")
        val declared = fmt.declaredFrameCount

        out.lanes[LANE_FORMAT_PROBE] = fmt.sampleRate > 0 && fmt.channelCount in 1..2 && declared > 0L && fmt.sourceMime.isNotBlank()
        out.lanes[LANE_PRE_ROLL] = final.preRollFrames > 0L && (final.preRollRingFullObserved || final.preRollFrames == declared) &&
            final.preRollStatePrepared && final.preRollFrames <= declared
        out.lanes[LANE_START] = final.startAccepted && final.startGeneration == final.prepareGeneration + 1L &&
            final.sinkReadyBeforeTransportStart && final.drainAllowedAfterTransportStart &&
            sink.drainCallsBeforeAllow == 0L && sink.firstDrainAtMs >= final.drainAllowedAtMs && sink.drainCalls > 0L
        out.lanes[LANE_NONZERO_GAIN] = sink.audioTrackInitOk && sink.gainSetOk && sink.gainValue > 0f && sink.played &&
            sink.initialPlayState == AudioTrack.PLAYSTATE_PLAYING && sink.audioTracksCreated == expect.audioTracksCreated &&
            sink.framesWrittenToSink > 0L
        out.lanes[LANE_CLOCK_ANCHORED] = clock.anchoredCount > 0L && clock.timestampSuccessCount > 0L &&
            sink.timestampPollSuccesses == clock.timestampSuccessCount && sink.clockWriterBoundOnSinkThread &&
            clock.writerThreadId == sink.threadId && clock.consistent
        out.lanes[LANE_CLOCK_MONOTONIC] = !clock.faulted && clock.regressionCount == 0L && clock.monotonicViolationCount == 0L &&
            clock.rejectedCount == 0L && sink.clockRejectedCount == 0L && clock.positionFrames >= 0L
        out.lanes[LANE_CLOCK_EPOCH_BALANCED] = clock.epochOpenCount == clock.epochCloseCount && clock.epochOpenCount > 0 && !clock.epochOpen &&
            sink.clockEpochOpenCalls == clock.epochOpenCount && sink.clockEpochCloseCalls == clock.epochCloseCount &&
            sink.currentEpoch == VanguardRealtimeAudioPlaybackSinkBridge.EPOCH_NONE
        // Final release exactly once on every scenario; the dead-object
        // scenario additionally released the old instance exactly once
        // through its own counter, so created == final + old releases.
        out.lanes[LANE_AUDIO_TRACK_RELEASED_ONCE] = sink.releaseCount == 1 && sink.releaseExecutedOnSinkThread && final.sinkJoined &&
            sink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.EXITED &&
            sink.deadObjectOldTrackReleaseCount == expect.oldTrackReleases &&
            sink.audioTracksCreated == sink.releaseCount + sink.deadObjectOldTrackReleaseCount &&
            sink.deadObjectInjectedCount == expect.deadObjectsInjected && sink.deadObjectObservedCount == expect.deadObjectsObserved &&
            (sink.syntheticDeadObjectInjectAfterFrames > 0L) == (expect.deadObjectsInjected > 0L)
        out.lanes[LANE_TRANSPORT_DISPOSED] = final.transportDisposeCalls == 1 &&
            final.transportStateAfterDispose == VanguardRealtimePlaybackTransportStateMachine.State.DISPOSED &&
            final.transportState == VanguardRealtimePlaybackTransportStateMachine.State.DISPOSED &&
            final.state == VanguardRealtimeAudioPlaybackSession.State.DISPOSED && final.transportStopAccepted &&
            final.transportFailedCallbacks == 0
        val focusMonitorThreadOk = if (final.focus.monitorThreadId > 0L) {
            final.focus.monitorThreadId != coordinatorThreadId &&
                final.focus.monitorThreadId != sink.threadId &&
                final.focus.monitorThreadId != final.decoderThreadId
        } else {
            true
        }
        val routingMonitorThreadOk = if (final.routing.monitorThreadId > 0L) {
            final.routing.monitorThreadId != coordinatorThreadId &&
                final.routing.monitorThreadId != sink.threadId &&
                final.routing.monitorThreadId != final.decoderThreadId &&
                final.routing.monitorThreadId != final.focus.monitorThreadId
        } else {
            true
        }
        out.lanes[LANE_THREAD_OWNERSHIP] = final.decoderThreadId > 0L && sink.threadId > 0L && final.decoderThreadId != sink.threadId &&
            final.decoderThreadId != coordinatorThreadId && sink.threadId != coordinatorThreadId &&
            !final.decoderThreadIsTransportOwner && !sink.threadIsTransportOwner &&
            final.decoderIngestCallbacksOnOwner > 0L && final.decoderIngestCallbacksOffOwner == 0L &&
            final.listenerCallbacksOnOwner > 0L && final.listenerCallbacksOffOwner == 0L &&
            sink.audioTrackCallsOffSinkThread == 0L && clock.offWriterThreadCalls == 0L && clock.writerThreadId == sink.threadId &&
            focusMonitorThreadOk && routingMonitorThreadOk
        out.lanes[LANE_NO_FEEDBACK] = sink.drainRequestSizeChanges == 0L && sink.timestampMaxPollsInOnePass <= 1L &&
            sink.timestampPollAttempts <= sink.productiveDrainPasses &&
            sink.timestampPollAttempts == clock.timestampSuccessCount + clock.timestampUnavailableCount &&
            clock.snapshotCallsFromWriterThread == sink.clockSnapshotsAtPark + sink.clockSnapshotsAtDeadObjectRecovery &&
            sink.timestampPollsWhileParked == 0L
        out.lanes[LANE_PROOF_BOUNDARY] = PROOF_BOUNDARY_TOKENS.all { PROOF_BOUNDARY.contains(it) }
    }

    fun evaluatePlaythrough(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        holdStart: VanguardRealtimeAudioPlaybackSession.Snapshot,
        holdEnd: VanguardRealtimeAudioPlaybackSession.Snapshot,
        stateAtCompletion: VanguardRealtimeAudioPlaybackSession.State,
        config: SmokeConfig,
        out: ScenarioOutcome,
        pauseStartQueryFrames: Long = -1L,
        pauseStartQueryUs: Long = -1L,
        pauseEndQueryFrames: Long = -1L,
        pauseEndQueryUs: Long = -1L,
        poller: PresentationClockPollerMetrics? = null,
    ) {
        if (final.format == null) return
        val sink = final.sink ?: return
        val clock = final.clock ?: return
        val atPause = final.clockAtPauseAck
        val beforeResume = final.clockBeforeResume
        val afterResume = final.clockAfterResume
        val hs = holdStart.sink
        val he = holdEnd.sink
        val hsClock = holdStart.clock
        val heClock = holdEnd.clock

        out.metrics["stateAtCompletion"] = stateAtCompletion.name
        out.metrics["holdStartDrainCalls"] = hs?.drainCalls ?: -1L
        out.metrics["holdEndDrainCalls"] = he?.drainCalls ?: -1L
        out.metrics["holdStartClockPosition"] = hsClock?.positionFrames ?: -1L
        out.metrics["holdEndClockPosition"] = heClock?.positionFrames ?: -1L
        out.metrics["holdStartClockUpdateCount"] = hsClock?.updateCount ?: -1L
        out.metrics["holdEndClockUpdateCount"] = heClock?.updateCount ?: -1L
        out.metrics["pauseStartQueryFrames"] = pauseStartQueryFrames
        out.metrics["pauseStartQueryUs"] = pauseStartQueryUs
        out.metrics["pauseEndQueryFrames"] = pauseEndQueryFrames
        out.metrics["pauseEndQueryUs"] = pauseEndQueryUs
        if (poller != null) {
            out.metrics["pollerRegressionCount"] = poller.regressionCount
            out.metrics["pollerValidCount"] = poller.validCount
        }

        out.lanes[LANE_PLAYTHROUGH_ACCOUNTING] = playthroughAccountingOk(final, stateAtCompletion)
        out.lanes[LANE_CHECKSUM_IDENTITY] = checksumIdentityOk(final)
        out.lanes[LANE_CLOCK_PAUSE_FROZEN] = atPause != null && beforeResume != null && afterResume != null &&
            hs != null && he != null && hsClock != null && heClock != null &&
            !atPause.epochOpen && atPause.epochId == 0 && atPause.provenance == VanguardRealtimePlaybackPresentationClock.Provenance.RESET &&
            beforeResume.positionFrames == atPause.positionFrames && beforeResume.updateCount == atPause.updateCount && !beforeResume.epochOpen &&
            heClock.positionFrames == hsClock.positionFrames && heClock.updateCount == hsClock.updateCount &&
            he.drainCalls == hs.drainCalls && he.framesWrittenToSink == hs.framesWrittenToSink &&
            he.timestampPollAttempts == hs.timestampPollAttempts &&
            sink.positionAtPark == atPause.positionFrames && sink.timestampPollsWhileParked == 0L && sink.clockSnapshotsAtPark == 1L &&
            afterResume.epochOpen && afterResume.epochId == 1 && afterResume.epochBaseOffsetFrames == atPause.positionFrames &&
            afterResume.positionFrames >= atPause.positionFrames && clock.positionFrames >= atPause.positionFrames &&
            clock.epochOpenCount == 2 && clock.epochCloseCount == 2 && sink.epochClosedAtPark == 0 && sink.epochOpenedAtUnpark == 1
        out.lanes[LANE_BOUNDED_PAUSE_RESUME] = final.pauseAccepted && final.resumeAccepted &&
            final.pauseGeneration == final.startGeneration && final.resumeGeneration == final.startGeneration &&
            sink.parkCount == 1 && sink.unparkCount == 1 && sink.audioTracksCreated == 1 &&
            sink.playStateAtPark == AudioTrack.PLAYSTATE_PAUSED && sink.playStateAfterUnpark == AudioTrack.PLAYSTATE_PLAYING &&
            sink.parkedPlayStateViolations == 0L && sink.parkExecutedOnSinkThread && sink.unparkExecutedOnSinkThread &&
            sink.parkedHoldMs >= config.pauseHoldMs && sink.parkedHoldMs <= config.maxPauseHoldMs &&
            final.pauseHoldObservedMs >= config.pauseHoldMs && final.pauseHoldObservedMs <= config.maxPauseHoldMs &&
            holdStart.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED && holdEnd.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
            holdStart.transportState == VanguardRealtimePlaybackTransportStateMachine.State.PAUSED &&
            holdEnd.transportState == VanguardRealtimePlaybackTransportStateMachine.State.PAUSED
        out.lanes[LANE_POSITION_QUERY_PAUSE_HOLD_FROZEN] = pauseStartQueryFrames >= 0L &&
            pauseStartQueryUs >= 0L &&
            pauseEndQueryFrames >= pauseStartQueryFrames &&
            pauseEndQueryUs >= pauseStartQueryUs &&
            pauseEndQueryFrames == pauseStartQueryFrames &&
            pauseEndQueryUs == pauseStartQueryUs &&
            (atPause == null || pauseStartQueryFrames == atPause.positionFrames) &&
            (poller == null || poller.regressionCount == 0L)
    }

    // Shared by the EOS scenarios (Y8a playthrough, Y8b dead object, Y9
    // forward seek). `expectedTotal` is the declared count for a straight
    // playthrough and H + (declared - T) across the one forward seek (C7).
    fun playthroughAccountingOk(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        stateAtCompletion: VanguardRealtimeAudioPlaybackSession.State,
        expectedTotal: Long = final.format?.declaredFrameCount ?: -1L,
    ): Boolean {
        if (final.format == null || expectedTotal <= 0L) return false
        val sink = final.sink ?: return false
        val reply = final.terminalReply
        return stateAtCompletion == VanguardRealtimeAudioPlaybackSession.State.COMPLETED &&
            sink.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS && sink.eosDrainedObserved &&
            sink.framesReadFromTransport == expectedTotal && sink.framesWrittenToSink == expectedTotal &&
            final.decoderExitReason == VanguardRealtimePlaybackDecoderFeed.EXIT_EOS && final.decoderAcceptedFrames == expectedTotal &&
            reply != null && reply.pushedFrames == expectedTotal && reply.drainedFrames == expectedTotal && reply.discardedFrames == 0L &&
            final.transportCompletedCallbacks == 1 && final.transportFailedCallbacks == 0 && final.failureReason.isBlank()
    }

    fun checksumIdentityOk(final: VanguardRealtimeAudioPlaybackSession.Snapshot): Boolean {
        val sink = final.sink ?: return false
        val reply = final.terminalReply ?: return false
        return final.decoderChecksumHex.isNotBlank() &&
            final.decoderChecksumHex.equals(reply.pushedChecksumHex, ignoreCase = true) &&
            final.decoderChecksumHex.equals(reply.drainedChecksumHex, ignoreCase = true) &&
            final.decoderChecksumHex.equals(sink.checksumHex, ignoreCase = true)
    }

    // Y8b lanes: the ONE armed synthetic dead object was recovered on the
    // sink thread with a same-parameter instance, the clock epoch was
    // closed/reopened at baseFrame = frames written with a non-negative base
    // step whose decomposition (frames lost with the dead instance + clock
    // publication lag) holds, and exactly the unwritten
    // remainder landed on the replacement; the run then reached EOS with
    // full accounting and checksum identity, and the final release still
    // happened exactly once.
    fun evaluateDeadObjectRecovery(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterRecovery: VanguardRealtimeAudioPlaybackSession.Snapshot,
        stateAtCompletion: VanguardRealtimeAudioPlaybackSession.State,
        config: SmokeConfig,
        out: ScenarioOutcome,
        afterRecoveryQueryFrames: Long = -1L,
        afterRecoveryQueryUs: Long = -1L,
        postTeardownFrames: Long = -1L,
        postTeardownUs: Long = -1L,
        poller: PresentationClockPollerMetrics? = null,
    ) {
        val fmt = final.format ?: return
        val sink = final.sink ?: return
        val clock = final.clock ?: return
        val arSink = afterRecovery.sink
        val arClock = afterRecovery.clock
        val declared = fmt.declaredFrameCount

        out.metrics["stateAtCompletion"] = stateAtCompletion.name
        out.metrics["afterRecoverySinkExitReason"] = arSink?.exitReason ?: "none"
        out.metrics["afterRecoveryFramesWritten"] = arSink?.framesWrittenToSink ?: -1L
        out.metrics["afterRecoveryClockEpochId"] = arClock?.epochId ?: -1
        out.metrics["afterRecoveryClockEpochOpen"] = arClock?.epochOpen ?: false
        out.metrics["afterRecoveryClockEpochBase"] = arClock?.epochBaseOffsetFrames ?: -1L
        out.metrics["afterRecoveryClockPosition"] = arClock?.positionFrames ?: -1L
        out.metrics["afterRecoveryClockTimestampSuccessCount"] = arClock?.timestampSuccessCount ?: -1L
        out.metrics["afterRecoveryQueryFrames"] = afterRecoveryQueryFrames
        out.metrics["afterRecoveryQueryUs"] = afterRecoveryQueryUs
        out.metrics["postTeardownCurrentPositionFrames"] = postTeardownFrames
        out.metrics["postTeardownCurrentPositionUs"] = postTeardownUs
        if (poller != null) {
            out.metrics["pollerRegressionCount"] = poller.regressionCount
            out.metrics["pollerValidCount"] = poller.validCount
        }

        out.lanes[LANE_PLAYTHROUGH_ACCOUNTING] = playthroughAccountingOk(final, stateAtCompletion)
        out.lanes[LANE_CHECKSUM_IDENTITY] = checksumIdentityOk(final)
        out.lanes[LANE_DEAD_OBJECT_RECOVERY] = sink.syntheticDeadObjectInjectAfterFrames == config.deadObjectInjectAfterFrames &&
            sink.deadObjectInjectedCount == 1L && sink.deadObjectObservedCount == 1L && sink.deadObjectRecoveryCount == 1 &&
            sink.deadObjectOldTrackReleaseCount == 1 && sink.deadObjectRecoveryExecutedOnSinkThread &&
            sink.deadObjectNewTrackInitOk && sink.deadObjectNewTrackVolumeOk && sink.deadObjectNewTrackPlayOk &&
            sink.deadObjectNewTrackPlayState == AudioTrack.PLAYSTATE_PLAYING && sink.deadObjectNewTrackSameBuffer &&
            sink.deadObjectNewTrackBufferFrames == sink.audioTrackBufferFrames && sink.audioTrackBufferFrames > 0 &&
            sink.audioTracksCreated == 2 && sink.releaseCount == 1 && sink.gainValue == config.gain &&
            sink.deadObjectRecoveryWallMs >= 0L && sink.deadObjectTimestampPollsDuringRecovery == 0L &&
            sink.parkCount == 0 && sink.unparkCount == 0 && sink.audioTrackCallsOffSinkThread == 0L &&
            arSink != null && arSink.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_RUNNING &&
            arSink.deadObjectRecoveryCount == 1 && arSink.audioTracksCreated == 2 && arSink.releaseCount == 0 &&
            sink.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS && final.failureReason.isBlank()
        out.lanes[LANE_DEAD_OBJECT_CLOCK_EPOCH] = arClock != null &&
            sink.deadObjectEpochBeforeRecovery == 0 && sink.deadObjectEpochOpenedAfterRecovery == 1 &&
            sink.deadObjectEpochCloseAccepted && sink.deadObjectEpochOpenAccepted &&
            sink.clockSnapshotsAtDeadObjectRecovery == 1L && sink.clockSnapshotsAtPark == 0L &&
            sink.deadObjectPositionBeforeRecovery >= 0L &&
            sink.deadObjectBaseFrameAfterRecovery == sink.deadObjectFramesWrittenBeforeRecovery &&
            sink.deadObjectBaseStepFrames == sink.deadObjectBaseFrameAfterRecovery - sink.deadObjectPositionBeforeRecovery &&
            sink.deadObjectBaseStepFrames >= 0L && sink.deadObjectBaseStepBounded &&
            deadObjectBaseStepDecompositionOk(sink, config, fmt.sampleRate) &&
            arClock.epochId == 1 && arClock.epochBaseOffsetFrames == sink.deadObjectBaseFrameAfterRecovery &&
            arClock.positionFrames >= sink.deadObjectPositionBeforeRecovery &&
            clock.epochOpenCount == 2 && clock.epochCloseCount == 2 && clock.baseClampCount == 0L &&
            clock.timestampSuccessCount > arClock.timestampSuccessCount && clock.anchoredCount > arClock.anchoredCount &&
            clock.positionFrames >= sink.deadObjectBaseFrameAfterRecovery && !clock.epochOpen && clock.epochId == 1 &&
            sink.rebasedClampCount == 0L
        out.lanes[LANE_DEAD_OBJECT_REMAINDER] = sink.deadObjectRemainderAccountingOk &&
            sink.deadObjectSliceBytesAtRecovery > 0L &&
            sink.deadObjectUnwrittenBytesAtRecovery in 1L..sink.deadObjectSliceBytesAtRecovery &&
            sink.deadObjectBufferPositionAtRecovery >= 0L &&
            sink.deadObjectRemainderFramesExpected > 0L &&
            sink.deadObjectRemainderFramesExpected * 2L * fmt.channelCount == sink.deadObjectUnwrittenBytesAtRecovery &&
            sink.deadObjectRemainderFramesWrittenOnNewTrack == sink.deadObjectRemainderFramesExpected &&
            sink.deadObjectFramesWrittenBeforeRecovery >= config.deadObjectInjectAfterFrames &&
            sink.deadObjectFramesWrittenBeforeRecovery < declared &&
            sink.deadObjectFramesReadAtRecovery >= sink.deadObjectFramesWrittenBeforeRecovery &&
            sink.deadObjectFramesReadAtRecovery <= declared &&
            sink.framesWrittenToSink == declared && sink.framesReadFromTransport == declared

        val preRecoveryPos = sink.deadObjectPositionBeforeRecovery
        out.lanes[LANE_POSITION_QUERY_DEAD_OBJECT_REBASE] = (poller == null || poller.regressionCount == 0L) &&
            afterRecoveryQueryFrames >= 0L &&
            afterRecoveryQueryUs >= 0L &&
            preRecoveryPos >= 0L &&
            afterRecoveryQueryFrames >= preRecoveryPos &&
            postTeardownFrames >= 0L &&
            postTeardownUs >= 0L &&
            postTeardownFrames >= clock.positionFrames &&
            postTeardownUs >= clock.positionUs
    }

    // Base-step decomposition (A-prime). With W = frames written before
    // recovery, H = content head consumed at the dead object, P = last
    // published position, B = track buffer frames, M = one mix window:
    //   step = W - P = (W - H) + (H - P).
    //   Loss bound: when H was readable, 0 <= W - H <= B + M (frames lost
    //     with the dead instance never exceed what could sit in its buffer
    //     plus one mix window) and the sink's own decomposition flag holds.
    //   Publication lag: if the clock was ANCHORED or EXTRAPOLATED at
    //     recovery, step <= B + M + framesFor(DEAD_OBJECT_PUBLICATION_LAG_BUDGET_MS);
    //     if RESET or STALE only the sign claim (step >= 0) is asserted and
    //     the values are reported.
    fun deadObjectBaseStepDecompositionOk(
        sink: VanguardRealtimeAudioPlaybackSinkTelemetry,
        config: SmokeConfig,
        sampleRate: Int,
    ): Boolean {
        val w = sink.deadObjectFramesWrittenBeforeRecovery
        val h = sink.deadObjectContentHeadAtDeadObject
        val p = sink.deadObjectPositionBeforeRecovery
        val step = sink.deadObjectBaseStepFrames
        val lossBound = sink.audioTrackBufferFrames.toLong() + config.maxFramesPerMix.toLong()
        if (step < 0L || w < 0L || p < 0L) return false
        if (h >= 0L) {
            val lost = w - h
            if (lost !in 0L..lossBound) return false
            if (sink.deadObjectWrittenAheadOfHeadFrames != lost) return false
            if (sink.deadObjectPublicationLagFrames != h - p) return false
            if (!sink.deadObjectBaseStepDecompositionOk) return false
        }
        return when (sink.deadObjectClockProvenanceAtRecovery) {
            VanguardRealtimePlaybackPresentationClock.Provenance.ANCHORED.name,
            VanguardRealtimePlaybackPresentationClock.Provenance.EXTRAPOLATED.name,
            -> step <= lossBound + sampleRate.toLong() * DEAD_OBJECT_PUBLICATION_LAG_BUDGET_MS / 1_000L
            VanguardRealtimePlaybackPresentationClock.Provenance.RESET.name,
            VanguardRealtimePlaybackPresentationClock.Provenance.STALE.name,
            -> true
            else -> false
        }
    }

    // Y9 lanes: the ONE forward seek ran in the frozen order with quiescent
    // pre-seek accounting at the window-aligned hold frame H, the transport
    // seek left PAUSED with generation + 1 into an empty output ring, the
    // AudioTrack was flushed exactly once on the sink thread while PAUSED
    // before/after, the decoder re-anchored on its own thread with the
    // deliberate stale probe rejected before JNI and the post-seek pre-roll
    // landing while still PAUSED, the seek clock epoch opened at T as a
    // deliberate discontinuity (base never clamped, clock never faulted),
    // and the run reached EOS with H + (declared - T) accounting and
    // checksum identity paired with the decoder landing assertions.
    fun evaluateForwardSeek(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterSeek: VanguardRealtimeAudioPlaybackSession.Snapshot,
        stateAtCompletion: VanguardRealtimeAudioPlaybackSession.State,
        config: SmokeConfig,
        out: ScenarioOutcome,
        afterSeekQueryFrames: Long = -1L,
        afterSeekQueryUs: Long = -1L,
        poller: PresentationClockPollerMetrics? = null,
    ) {
        val fmt = final.format ?: return
        val sink = final.sink ?: return
        val clock = final.clock ?: return
        val q = final.seek
        val d = q.decoder
        val declared = fmt.declaredFrameCount
        val window = config.maxFramesPerMix.toLong()
        val hold = q.holdFrame
        val target = q.targetFrame
        val postSeekExpected = declared - target
        val expectedTotal = hold + postSeekExpected
        val reply = final.terminalReply
        val pre = q.preSeekReply
        val postPause = q.postPauseReply
        val post = q.postSeekReply
        val postPreRoll = q.postSeekPreRollReply
        val asSink = afterSeek.sink
        val asClock = afterSeek.clock
        val clockAtPark = q.clockAtPark
        val clockBeforeUnpark = q.clockBeforeUnpark
        val clockAfterUnpark = q.clockAfterUnpark
        val paused = VanguardRealtimePlaybackTransportStateMachine.State.PAUSED
        val playing = VanguardRealtimePlaybackTransportStateMachine.State.PLAYING

        out.metrics["stateAtCompletion"] = stateAtCompletion.name
        out.metrics["postSeekExpectedFrames"] = postSeekExpected
        out.metrics["expectedTotalFrames"] = expectedTotal
        out.metrics["afterSeekState"] = afterSeek.state.name
        out.metrics["afterSeekTransportState"] = afterSeek.transportState?.name ?: "none"
        out.metrics["afterSeekSinkPhase"] = asSink?.phase?.name ?: "none"
        out.metrics["afterSeekFramesWritten"] = asSink?.framesWrittenToSink ?: -1L
        out.metrics["afterSeekClockEpochId"] = asClock?.epochId ?: -1
        out.metrics["afterSeekClockEpochOpen"] = asClock?.epochOpen ?: false
        out.metrics["afterSeekClockEpochBase"] = asClock?.epochBaseOffsetFrames ?: -1L
        out.metrics["afterSeekClockPosition"] = asClock?.positionFrames ?: -1L
        out.metrics["afterSeekClockBaseClampCount"] = asClock?.baseClampCount ?: -1L
        out.metrics["afterSeekClockBaseAdvanceCount"] = asClock?.baseAdvanceCount ?: -1L
        out.metrics["afterSeekClockLastBaseAdvanceFrames"] = asClock?.lastBaseAdvanceFrames ?: -1L
        out.metrics["afterSeekTransportGeneration"] = afterSeek.transportGeneration
        out.metrics["finalTransportGeneration"] = final.transportGeneration
        out.metrics["afterSeekQueryFrames"] = afterSeekQueryFrames
        out.metrics["afterSeekQueryUs"] = afterSeekQueryUs
        if (poller != null) {
            out.metrics["pollerRegressionCount"] = poller.regressionCount
            out.metrics["pollerValidCount"] = poller.validCount
        }

        // Decoder landing assertions (paired with checksum identity): the
        // previous-sync seat landed at or before the target, the first
        // post-seek chunk is PTS-anchored, every pre-target frame was
        // discarded and a padded gap (Y5b policy) ends exactly at the first
        // decoded post-seek frame.
        val gapPolicyOk = d != null && d.gapPaddedFrames == d.gapObservedFrames &&
            d.gapPaddedFrames <= d.maxSeekGapFrames &&
            (d.gapPaddedFrames == 0L || d.firstPostSeekFrame == target + d.gapPaddedFrames)
        val landingOk = d != null && d.seekTargetUs > 0L && d.seekLandedUs in 0L..d.seekTargetUs &&
            d.firstPostSeekPtsUs >= 0L && d.firstPostSeekFrame >= 0L &&
            (if (d.firstPostSeekFrame <= target) d.discardedPreTargetFrames == target - d.firstPostSeekFrame else d.discardedPreTargetFrames == 0L) &&
            gapPolicyOk
        out.metrics["decoderLandingOk"] = landingOk
        out.metrics["decoderGapPolicyOk"] = gapPolicyOk

        out.lanes[LANE_PLAYTHROUGH_ACCOUNTING] = q.armed && hold > 0L && target > hold && playthroughAccountingOk(final, stateAtCompletion, expectedTotal)
        out.lanes[LANE_CHECKSUM_IDENTITY] = checksumIdentityOk(final) && landingOk
        out.lanes[LANE_SEEK_QUIESCE_ACCOUNTING] = d != null && pre != null &&
            q.armed && q.admissionOk && q.holdPinned && hold % window == 0L &&
            final.preRollFrames < hold && hold < target && target < declared - 2L * window &&
            q.quiesceFeedHeld && q.quiesceSinkReadFrames == hold && q.quiesceSinkWrittenFrames == hold && q.quiesceAccountingOk &&
            pre.state == VanguardRealtimePlaybackNativeSession.NativeState.PLAYING && pre.positionFrame == hold &&
            pre.pushedFrames == hold && pre.drainedFrames == hold && pre.discardedFrames == 0L && pre.outputAvailableReadFrames == 0L &&
            !pre.eosPushed && !pre.eosDrained && q.preSeekTransportState == playing &&
            d.holdFrame == hold && d.preSeekAcceptedFrames == hold &&
            sink.framesWrittenAtFlush == hold && sink.framesReadAtFlush == hold &&
            q.initialWriteWaitMs >= 0L && q.quiesceWaitMs >= 0L && q.preSeekSettleMs >= 0L
        out.lanes[LANE_SEEK_COMMAND] = postPause != null && post != null && postPreRoll != null &&
            q.seekCount == 1 && q.seekAccepted && q.staleGeneration == final.startGeneration &&
            q.seekGeneration == q.staleGeneration + 1L && q.pauseAccepted && q.pauseGeneration == final.startGeneration &&
            q.resumeAccepted && q.resumeGeneration == q.seekGeneration &&
            // The seek command is judged on the immediate after-seek snapshot:
            // `final` is taken after stop(), which bumps the transport
            // generation once more by design (exported as a metric only).
            afterSeek.transportGeneration == q.seekGeneration &&
            postPause.state == VanguardRealtimePlaybackNativeSession.NativeState.PAUSED && postPause.pushedFrames == hold &&
            postPause.drainedFrames == hold && postPause.discardedFrames == 0L &&
            post.state == VanguardRealtimePlaybackNativeSession.NativeState.PAUSED && post.positionFrame == target &&
            post.pushedFrames == hold && post.drainedFrames == hold && post.discardedFrames == 0L && !post.eosPushed && !post.eosDrained &&
            q.postSeekTransportState == paused && q.sinkPhaseAtSeek == VanguardRealtimeAudioPlaybackSinkBridge.Phase.PARKED.name &&
            q.flushRequestedWhilePaused && q.flushAckedBeforeSeek &&
            postPreRoll.state == VanguardRealtimePlaybackNativeSession.NativeState.PAUSED && postPreRoll.pushedFrames == hold &&
            postPreRoll.positionFrame == target && postPreRoll.discardedFrames == 0L &&
            q.postSeekPreRollTransportState == paused && q.transportStateAtUnpark == paused &&
            afterSeek.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING && afterSeek.transportState == playing &&
            afterSeek.failureReason.isBlank() && q.seekWallMs >= 0L &&
            q.parkAckedAtMs >= q.parkRequestedAtMs && q.unparkedAtMs >= q.parkAckedAtMs && q.resumedAtMs >= q.unparkedAtMs
        out.lanes[LANE_SINK_FLUSH_AT_SEEK] = sink.seekParkCount == 1 && sink.parkCount == 1 && sink.unparkCount == 1 &&
            sink.flushRequestCount == 1 && sink.flushCount == 1 && sink.flushExecutedOnSinkThread &&
            sink.parkExecutedOnSinkThread && sink.unparkExecutedOnSinkThread &&
            sink.playStateAtPark == AudioTrack.PLAYSTATE_PAUSED && sink.playStateBeforeFlush == AudioTrack.PLAYSTATE_PAUSED &&
            sink.playStateAfterFlush == AudioTrack.PLAYSTATE_PAUSED && sink.playStateAfterUnpark == AudioTrack.PLAYSTATE_PLAYING &&
            sink.parkedPlayStateViolations == 0L && sink.timestampPollsWhileParked == 0L && sink.timestampPollsDuringFlush == 0L &&
            sink.framesWrittenAtFlush == hold && sink.framesReadAtFlush == hold && sink.drainCallsAtFlush > 0L &&
            sink.postSeekExpectedFrames == postSeekExpected && sink.readBudgetFrames == expectedTotal && sink.seekTargetFrame == target &&
            sink.flushAckLatencyMs >= 0L && q.flushAckWaitMs >= 0L &&
            sink.maxSeekHoldMs == config.maxSeekHoldMs && sink.parkHoldCapMs == config.maxSeekHoldMs &&
            sink.parkedHoldMs >= 0L && sink.parkedHoldMs <= config.maxSeekHoldMs &&
            q.holdObservedMs >= 0L && q.holdObservedMs <= config.maxSeekHoldMs &&
            sink.audioTracksCreated == 1 && sink.releaseCount == 1 && sink.deadObjectRecoveryCount == 0 &&
            sink.audioTrackCallsOffSinkThread == 0L
        out.lanes[LANE_DECODER_SEEK_REANCHOR] = d != null &&
            d.seekReanchorCount == 1 && d.reanchorOk && d.reanchorExecutedOnDecodeThread && d.reanchorTransportStatePaused &&
            d.seekTargetFrame == target && d.holdFrame == hold && d.preSeekAcceptedFrames == hold && d.codecChunks > d.codecChunksAtSeek &&
            d.postSeekAcceptedFrames == postSeekExpected && d.postSeekDecodedAcceptedFrames > 0L &&
            d.anchorFrame == declared && d.acceptedFrames == expectedTotal && !d.heldAtHoldFrame &&
            d.postSeekPreRollFrames >= window && d.postSeekPreRollStatePaused && landingOk && d.mediaReopens <= 1 &&
            d.paddedFrames <= (VanguardRealtimePlaybackDecoderFeed.MAX_EOS_DRIFT_SEC * fmt.sampleRate).toLong() &&
            d.seekReanchorWallMs >= 0L && q.reanchorWaitMs >= 0L && q.postSeekPreRollWaitMs >= 0L &&
            final.decoderExitReason == VanguardRealtimePlaybackDecoderFeed.EXIT_EOS && final.decoderAcceptedFrames == expectedTotal &&
            final.decoderMediaReleaseCount == 1L && final.decoderMediaReleaseClean
        out.lanes[LANE_STALE_GENERATION_REJECTED] = d != null &&
            d.staleProbeCalls == 1 && d.staleProbeRejected && d.staleProbeReplyNull && d.staleProbeAnchorUntouched &&
            d.staleProbeReason == VanguardRealtimePlaybackTransportStateMachine.REASON_STALE_GENERATION &&
            final.decoderIngestCallbacksOffOwner == 0L && q.seekGeneration == q.staleGeneration + 1L
        out.lanes[LANE_SEEK_CLOCK_EPOCH] = clockAtPark != null && clockBeforeUnpark != null && clockAfterUnpark != null && asClock != null &&
            !clockAtPark.epochOpen && clockAtPark.epochId == 0 && clockAtPark.positionFrames == sink.positionAtPark &&
            clockAtPark.provenance == VanguardRealtimePlaybackPresentationClock.Provenance.RESET &&
            clockBeforeUnpark.positionFrames == clockAtPark.positionFrames && clockBeforeUnpark.updateCount == clockAtPark.updateCount &&
            !clockBeforeUnpark.epochOpen &&
            sink.positionAtPark >= 0L && sink.positionAtPark <= hold && sink.epochClosedAtPark == 0 && sink.epochOpenedAtUnpark == 1 &&
            sink.seekEpochOpenedAtUnpark == 1 && sink.seekEpochBaseFrame == target &&
            sink.seekDiscontinuityFrames == target - sink.positionAtPark && sink.seekDiscontinuityFrames > 0L &&
            sink.seekEpochOpenAccepted && sink.seekUnwrapResetAtFlush && sink.epochRawOriginAtUnpark == 0L &&
            sink.rebasedClampCount == 0L && sink.clockSnapshotsAtPark == 1L && sink.clockSnapshotsAtDeadObjectRecovery == 0L &&
            clockAfterUnpark.epochOpen && clockAfterUnpark.epochId == 1 && clockAfterUnpark.epochBaseOffsetFrames == target &&
            clockAfterUnpark.positionFrames >= target && clockAfterUnpark.baseClampCount == 0L && !clockAfterUnpark.faulted &&
            clockAfterUnpark.baseAdvanceCount == 1L && clockAfterUnpark.lastBaseAdvanceFrames == sink.seekDiscontinuityFrames &&
            asClock.epochId == 1 && asClock.epochBaseOffsetFrames == target && asClock.positionFrames >= target &&
            asClock.baseClampCount == 0L && !asClock.faulted &&
            clock.epochOpenCount == 2 && clock.epochCloseCount == 2 && clock.baseClampCount == 0L && !clock.faulted &&
            clock.regressionCount == 0L && clock.positionFrames >= target && clock.positionFrames <= declared &&
            !clock.epochOpen && clock.epochId == 1 &&
            clock.timestampSuccessCount > clockAfterUnpark.timestampSuccessCount && clock.anchoredCount > clockAfterUnpark.anchoredCount
        out.lanes[LANE_POST_SEEK_DRAIN] = asSink != null && reply != null &&
            sink.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS && sink.eosDrainedObserved &&
            sink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.EXITED && q.resumeAccepted &&
            asSink.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_RUNNING &&
            asSink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.RUNNING && asSink.unparkCount == 1 && asSink.flushCount == 1 &&
            asSink.framesWrittenToSink >= hold && asSink.framesWrittenToSink <= expectedTotal &&
            sink.framesReadFromTransport == expectedTotal && sink.framesWrittenToSink == expectedTotal &&
            sink.postSeekFramesWritten == postSeekExpected && sink.drainCalls > sink.drainCallsAtFlush && sink.productiveDrainPasses > 0L &&
            reply.pushedFrames == expectedTotal && reply.drainedFrames == expectedTotal && reply.discardedFrames == 0L &&
            reply.positionFrame == declared && reply.eosDrained &&
            final.transportCompletedCallbacks == 1 && final.transportFailedCallbacks == 0 && final.failureReason.isBlank() &&
            stateAtCompletion == VanguardRealtimeAudioPlaybackSession.State.COMPLETED
        out.lanes[LANE_POSITION_QUERY_SEEK_BASE_ADVANCE] = afterSeekQueryFrames >= 0L &&
            afterSeekQueryUs >= 0L &&
            target > 0L &&
            afterSeekQueryFrames >= target &&
            (poller == null || poller.regressionCount == 0L)
    }

    // Y10b lanes: two ordered forward seeks (T1 then T2) followed by a third
    // seek rejected with reason "seek_repeated" without teardown or mutation;
    // cumulative accounting equals H1 + (H2 - T1) + (declared - T2), sink
    // park/flush/unpark counts == 2, decoder reanchor count == 2, stale probe
    // count == 2, seek clock epoch rebased at T2, and playback drains to EOS.
    fun evaluateRepeatedForwardSeek(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        armed: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterFirstSeek: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterSecondSeek: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterThirdSeek: VanguardRealtimeAudioPlaybackSession.Snapshot,
        stateAtCompletion: VanguardRealtimeAudioPlaybackSession.State,
        config: SmokeConfig,
        out: ScenarioOutcome,
        afterSeek1QueryFrames: Long = -1L,
        afterSeek1QueryUs: Long = -1L,
        afterSeek2QueryFrames: Long = -1L,
        afterSeek2QueryUs: Long = -1L,
        afterSeek3QueryFrames: Long = -1L,
        afterSeek3QueryUs: Long = -1L,
        poller: PresentationClockPollerMetrics? = null,
    ) {
        val fmt = final.format ?: return
        val sink = final.sink ?: return
        val clock = final.clock ?: return
        val q = final.seek
        val d = q.decoder
        val declared = fmt.declaredFrameCount
        val sampleRate = fmt.sampleRate
        val window = config.maxFramesPerMix.toLong()
        val t1 = (config.seekTargetSec * sampleRate).toLong()
        val t2 = (config.secondSeekTargetSec * sampleRate).toLong()
        val h1 = q.holdFrame
        val h2 = t1 + config.preSeekHoldWindows.toLong() * window
        val sinkHold2 = h1 + (h2 - t1)
        val postSeekExpected = declared - t2
        val expectedTotal = sinkHold2 + postSeekExpected
        val reply = final.terminalReply
        val asSink = afterSecondSeek.sink
        val atSink = afterThirdSeek.sink
        val playing = VanguardRealtimePlaybackTransportStateMachine.State.PLAYING

        out.metrics["stateAtCompletion"] = stateAtCompletion.name
        out.metrics["target1Frame"] = t1
        out.metrics["target2Frame"] = t2
        out.metrics["hold1Frame"] = h1
        out.metrics["hold2Frame"] = h2
        out.metrics["sinkHold2Frame"] = sinkHold2
        out.metrics["postSeekExpectedFrames"] = postSeekExpected
        out.metrics["expectedTotalFrames"] = expectedTotal
        out.metrics["afterFirstSeekState"] = afterFirstSeek.state.name
        out.metrics["afterSecondSeekState"] = afterSecondSeek.state.name
        out.metrics["afterThirdSeekState"] = afterThirdSeek.state.name
        out.metrics["afterThirdSeekTransportState"] = afterThirdSeek.transportState?.name ?: "none"
        out.metrics["thirdSeekCount"] = afterThirdSeek.seek.seekCount
        out.metrics["finalSeekCount"] = final.seek.seekCount
        out.metrics["afterSeek1QueryFrames"] = afterSeek1QueryFrames
        out.metrics["afterSeek1QueryUs"] = afterSeek1QueryUs
        out.metrics["afterSeek2QueryFrames"] = afterSeek2QueryFrames
        out.metrics["afterSeek2QueryUs"] = afterSeek2QueryUs
        out.metrics["afterSeek3QueryFrames"] = afterSeek3QueryFrames
        out.metrics["afterSeek3QueryUs"] = afterSeek3QueryUs
        if (poller != null) {
            out.metrics["pollerRegressionCount"] = poller.regressionCount
            out.metrics["pollerValidCount"] = poller.validCount
        }

        val gapPolicyOk = d != null && d.gapPaddedFrames == d.gapObservedFrames &&
            d.gapPaddedFrames <= d.maxSeekGapFrames &&
            (d.gapPaddedFrames == 0L || d.firstPostSeekFrame == t2 + d.gapPaddedFrames)
        val landingOk = d != null && d.seekTargetUs > 0L && d.seekLandedUs in 0L..d.seekTargetUs &&
            d.firstPostSeekPtsUs >= 0L && d.firstPostSeekFrame >= 0L &&
            (if (d.firstPostSeekFrame <= t2) d.discardedPreTargetFrames == t2 - d.firstPostSeekFrame else d.discardedPreTargetFrames == 0L) &&
            gapPolicyOk
        out.metrics["decoderLandingOk"] = landingOk
        out.metrics["decoderGapPolicyOk"] = gapPolicyOk

        out.lanes[LANE_PLAYTHROUGH_ACCOUNTING] = q.armed && h1 > 0L && t1 > h1 && h2 > t1 && t2 > h2 &&
            playthroughAccountingOk(final, stateAtCompletion, expectedTotal)
        out.lanes[LANE_CHECKSUM_IDENTITY] = checksumIdentityOk(final) && landingOk
        out.lanes[LANE_REPEATED_SEEK_COMMAND] = armed.seek.armed && armed.seek.admissionOk && armed.seek.holdPinned &&
            afterFirstSeek.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING &&
            afterFirstSeek.transportState == playing &&
            afterFirstSeek.seek.seekCount == 1 &&
            afterSecondSeek.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING &&
            afterSecondSeek.transportState == playing &&
            afterSecondSeek.seek.seekCount == 2 &&
            final.seek.seekCount == 2 &&
            final.seek.seekAccepted && final.seek.pauseAccepted && final.seek.resumeAccepted &&
            sink.seekParkCount == 2 && sink.parkCount == 2 && sink.unparkCount == 2 &&
            sink.flushRequestCount == 2 && sink.flushCount == 2 && sink.flushExecutedOnSinkThread &&
            sink.seekEpochOpenedAtUnpark == 2 && sink.seekEpochBaseFrame == t2 && sink.seekTargetFrame == t2 &&
            d != null && d.seekReanchorCount == 2 && d.reanchorOk && d.reanchorExecutedOnDecodeThread &&
            d.staleProbeCalls == 2 && d.staleProbeRejected &&
            d.staleProbeReason == VanguardRealtimePlaybackTransportStateMachine.REASON_STALE_GENERATION &&
            d.seekTargetFrame == t2
        out.lanes[LANE_REPEATED_SEEK_CUMULATIVE_ACCOUNTING] = h1 % window == 0L && (h2 - t1) % window == 0L &&
            final.preRollFrames < h1 && h1 < t1 && t1 < h2 && h2 < t2 && t2 < declared - 2L * window &&
            sinkHold2 == h1 + (h2 - t1) &&
            expectedTotal == sinkHold2 + (declared - t2) &&
            sink.postSeekExpectedFrames == postSeekExpected &&
            sink.readBudgetFrames == expectedTotal &&
            sink.framesReadFromTransport == expectedTotal &&
            sink.framesWrittenToSink == expectedTotal &&
            final.decoderAcceptedFrames == expectedTotal &&
            reply != null && reply.pushedFrames == expectedTotal && reply.drainedFrames == expectedTotal &&
            reply.discardedFrames == 0L && reply.positionFrame == declared && reply.eosDrained &&
            sink.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS && sink.eosDrainedObserved &&
            stateAtCompletion == VanguardRealtimeAudioPlaybackSession.State.COMPLETED &&
            playthroughAccountingOk(final, stateAtCompletion, expectedTotal) &&
            checksumIdentityOk(final) && landingOk
        out.lanes[LANE_REPEATED_SEEK_THIRD_REJECT] = afterThirdSeek.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING &&
            afterThirdSeek.transportState == playing &&
            afterThirdSeek.failureReason.isBlank() &&
            afterThirdSeek.seek.seekCount == 2 &&
            afterThirdSeek.transportGeneration == afterSecondSeek.transportGeneration &&
            atSink != null && atSink.audioTracksCreated == 1 && atSink.releaseCount == 0 &&
            atSink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.RUNNING &&
            atSink.seekParkCount == 2 && atSink.flushCount == 2 && atSink.unparkCount == 2 &&
            !afterThirdSeek.cancelled
        out.lanes[LANE_POSITION_QUERY_REPEATED_SEEK_BASE_ADVANCE] = afterSeek1QueryFrames >= 0L &&
            afterSeek1QueryUs >= 0L &&
            afterSeek2QueryFrames >= 0L &&
            afterSeek2QueryUs >= 0L &&
            afterSeek3QueryFrames >= 0L &&
            afterSeek3QueryUs >= 0L &&
            t1 > 0L && t2 > t1 &&
            afterSeek1QueryFrames >= t1 &&
            afterSeek2QueryFrames >= t2 &&
            afterSeek3QueryFrames >= afterSeek2QueryFrames &&
            afterSeek3QueryUs >= afterSeek2QueryUs &&
            (poller == null || poller.regressionCount == 0L)
    }

    // Y17 lanes: ONE backward seek to T (0 <= T <= H - 2 windows) declared
    // backward end to end (session/sequencer/sink/clock/decoder), a second
    // seek(T) rejected "seek_repeated" without teardown or mutation, and
    // accounting of H + (declared - T) across the one declared discontinuity.
    // The sink's seek discontinuity and the clock's declared-backward base
    // step are the sanctioned decrease (never a clamp or monotonic
    // violation); every other invariant mirrors the forward-seek lanes.
    fun evaluateBackwardSeek(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        armed: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterSeek: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterRepeated: VanguardRealtimeAudioPlaybackSession.Snapshot,
        stateAtCompletion: VanguardRealtimeAudioPlaybackSession.State,
        config: SmokeConfig,
        out: ScenarioOutcome,
        afterSeekQueryFrames: Long = -1L,
        afterSeekQueryUs: Long = -1L,
        poller: PresentationClockPollerMetrics? = null,
    ) {
        val fmt = final.format ?: return
        val sink = final.sink ?: return
        val clock = final.clock ?: return
        val q = final.seek
        val d = q.decoder
        val declared = fmt.declaredFrameCount
        val window = config.maxFramesPerMix.toLong()
        val hold = q.holdFrame
        val target = q.targetFrame
        val postSeekExpected = declared - target
        val expectedTotal = hold + postSeekExpected
        val reply = final.terminalReply
        val pre = q.preSeekReply
        val postPause = q.postPauseReply
        val post = q.postSeekReply
        val postPreRoll = q.postSeekPreRollReply
        val asSink = afterSeek.sink
        val asClock = afterSeek.clock
        val arSink = afterRepeated.sink
        val clockAtPark = q.clockAtPark
        val clockBeforeUnpark = q.clockBeforeUnpark
        val clockAfterUnpark = q.clockAfterUnpark
        val paused = VanguardRealtimePlaybackTransportStateMachine.State.PAUSED
        val playing = VanguardRealtimePlaybackTransportStateMachine.State.PLAYING

        out.metrics["stateAtCompletion"] = stateAtCompletion.name
        out.metrics["postSeekExpectedFrames"] = postSeekExpected
        out.metrics["expectedTotalFrames"] = expectedTotal
        out.metrics["afterSeekState"] = afterSeek.state.name
        out.metrics["afterSeekTransportState"] = afterSeek.transportState?.name ?: "none"
        out.metrics["afterSeekSinkPhase"] = asSink?.phase?.name ?: "none"
        out.metrics["afterSeekFramesWritten"] = asSink?.framesWrittenToSink ?: -1L
        out.metrics["afterSeekClockEpochId"] = asClock?.epochId ?: -1
        out.metrics["afterSeekClockEpochOpen"] = asClock?.epochOpen ?: false
        out.metrics["afterSeekClockEpochBase"] = asClock?.epochBaseOffsetFrames ?: -1L
        out.metrics["afterSeekClockPosition"] = asClock?.positionFrames ?: -1L
        out.metrics["afterSeekClockBaseClampCount"] = asClock?.baseClampCount ?: -1L
        out.metrics["afterSeekClockDeclaredBackwardBaseCount"] = asClock?.declaredBackwardBaseCount ?: -1L
        out.metrics["afterSeekClockLastDeclaredBackwardFrames"] = asClock?.lastDeclaredBackwardFrames ?: -1L
        out.metrics["afterSeekTransportGeneration"] = afterSeek.transportGeneration
        out.metrics["afterRepeatedState"] = afterRepeated.state.name
        out.metrics["afterRepeatedTransportState"] = afterRepeated.transportState?.name ?: "none"
        out.metrics["afterRepeatedSeekCount"] = afterRepeated.seek.seekCount
        out.metrics["finalTransportGeneration"] = final.transportGeneration
        out.metrics["finalSeekCount"] = final.seek.seekCount
        out.metrics["afterSeekQueryFrames"] = afterSeekQueryFrames
        out.metrics["afterSeekQueryUs"] = afterSeekQueryUs
        if (poller != null) {
            out.metrics["pollerRegressionCount"] = poller.regressionCount
            out.metrics["pollerValidCount"] = poller.validCount
        }

        val gapPolicyOk = d != null && d.gapPaddedFrames == d.gapObservedFrames &&
            d.gapPaddedFrames <= d.maxSeekGapFrames &&
            (d.gapPaddedFrames == 0L || d.firstPostSeekFrame == target + d.gapPaddedFrames)
        // A frame-zero backward seek (T = 0) lands on the first audio sample
        // at or after 0; seekLandedUs may exceed seekTargetUs (0) in that
        // case, so the landed<=target bound only applies once the target is
        // itself past frame zero.
        val landingOk = d != null && d.seekBackward && d.seekTargetUs >= 0L && d.seekLandedUs >= 0L &&
            (d.seekTargetUs == 0L || d.seekLandedUs <= d.seekTargetUs) &&
            d.firstPostSeekPtsUs >= 0L && d.firstPostSeekFrame >= target &&
            d.discardedPreTargetFrames <= d.maxPreTargetDiscardFrames &&
            gapPolicyOk
        out.metrics["decoderLandingOk"] = landingOk
        out.metrics["decoderGapPolicyOk"] = gapPolicyOk

        out.lanes[LANE_BACKWARD_SEEK_ADMISSION] = q.armed && q.admissionOk && q.holdPinned && q.backward &&
            armed.seek.armed && armed.seek.admissionOk && armed.seek.holdPinned && armed.seek.backward &&
            hold % window == 0L && final.preRollFrames < hold && hold < declared - 2L * window &&
            target >= 0L && target <= hold - 2L * window
        out.lanes[LANE_BACKWARD_SEEK_QUIESCE_ACCOUNTING] = d != null && pre != null &&
            q.armed && q.admissionOk && q.holdPinned && q.backward && hold % window == 0L &&
            final.preRollFrames < hold && target >= 0L && target < hold &&
            q.quiesceFeedHeld && q.quiesceSinkReadFrames == hold && q.quiesceSinkWrittenFrames == hold && q.quiesceAccountingOk &&
            pre.state == VanguardRealtimePlaybackNativeSession.NativeState.PLAYING && pre.positionFrame == hold &&
            pre.pushedFrames == hold && pre.drainedFrames == hold && pre.discardedFrames == 0L && pre.outputAvailableReadFrames == 0L &&
            !pre.eosPushed && !pre.eosDrained && q.preSeekTransportState == playing &&
            d.holdFrame == hold && d.preSeekAcceptedFrames == hold &&
            sink.framesWrittenAtFlush == hold && sink.framesReadAtFlush == hold &&
            q.initialWriteWaitMs >= 0L && q.quiesceWaitMs >= 0L && q.preSeekSettleMs >= 0L
        out.lanes[LANE_BACKWARD_SINK_FLUSH_AT_SEEK] = sink.seekParkCount == 1 && sink.parkCount == 1 && sink.unparkCount == 1 &&
            sink.flushRequestCount == 1 && sink.flushCount == 1 && sink.flushExecutedOnSinkThread &&
            sink.parkExecutedOnSinkThread && sink.unparkExecutedOnSinkThread &&
            sink.playStateAtPark == AudioTrack.PLAYSTATE_PAUSED && sink.playStateBeforeFlush == AudioTrack.PLAYSTATE_PAUSED &&
            sink.playStateAfterFlush == AudioTrack.PLAYSTATE_PAUSED && sink.playStateAfterUnpark == AudioTrack.PLAYSTATE_PLAYING &&
            sink.parkedPlayStateViolations == 0L && sink.timestampPollsWhileParked == 0L && sink.timestampPollsDuringFlush == 0L &&
            sink.framesWrittenAtFlush == hold && sink.framesReadAtFlush == hold && sink.drainCallsAtFlush > 0L &&
            sink.postSeekExpectedFrames == postSeekExpected && sink.readBudgetFrames == expectedTotal && sink.seekTargetFrame == target &&
            sink.seekDeclaredBackward && sink.flushAckLatencyMs >= 0L && q.flushAckWaitMs >= 0L &&
            sink.maxSeekHoldMs == config.maxSeekHoldMs && sink.parkHoldCapMs == config.maxSeekHoldMs &&
            sink.parkedHoldMs >= 0L && sink.parkedHoldMs <= config.maxSeekHoldMs &&
            q.holdObservedMs >= 0L && q.holdObservedMs <= config.maxSeekHoldMs &&
            sink.audioTracksCreated == 1 && sink.releaseCount == 1 && sink.deadObjectRecoveryCount == 0 &&
            sink.audioTrackCallsOffSinkThread == 0L
        out.lanes[LANE_BACKWARD_SEEK_COMMAND] = postPause != null && post != null && postPreRoll != null &&
            q.seekCount == 1 && q.seekAccepted && q.backward && q.declaredBackward &&
            q.staleGeneration == final.startGeneration && q.seekGeneration == q.staleGeneration + 1L &&
            q.pauseAccepted && q.pauseGeneration == final.startGeneration &&
            q.resumeAccepted && q.resumeGeneration == q.seekGeneration &&
            afterSeek.transportGeneration == q.seekGeneration &&
            postPause.state == VanguardRealtimePlaybackNativeSession.NativeState.PAUSED && postPause.pushedFrames == hold &&
            postPause.drainedFrames == hold && postPause.discardedFrames == 0L &&
            post.state == VanguardRealtimePlaybackNativeSession.NativeState.PAUSED && post.positionFrame == target &&
            post.pushedFrames == hold && post.drainedFrames == hold && post.discardedFrames == 0L && !post.eosPushed && !post.eosDrained &&
            q.postSeekTransportState == paused && q.sinkPhaseAtSeek == VanguardRealtimeAudioPlaybackSinkBridge.Phase.PARKED.name &&
            q.flushRequestedWhilePaused && q.flushAckedBeforeSeek &&
            postPreRoll.state == VanguardRealtimePlaybackNativeSession.NativeState.PAUSED && postPreRoll.pushedFrames == hold &&
            postPreRoll.positionFrame == target && postPreRoll.discardedFrames == 0L &&
            q.postSeekPreRollTransportState == paused && q.transportStateAtUnpark == paused &&
            afterSeek.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING && afterSeek.transportState == playing &&
            afterSeek.failureReason.isBlank() && q.seekWallMs >= 0L &&
            q.parkAckedAtMs >= q.parkRequestedAtMs && q.unparkedAtMs >= q.parkAckedAtMs && q.resumedAtMs >= q.unparkedAtMs
        out.lanes[LANE_BACKWARD_DECODER_REANCHOR] = d != null && d.seekBackward &&
            d.seekReanchorCount == 1 && d.reanchorOk && d.reanchorExecutedOnDecodeThread && d.reanchorTransportStatePaused &&
            d.seekTargetFrame == target && d.holdFrame == hold && d.preSeekAcceptedFrames == hold && d.codecChunks > d.codecChunksAtSeek &&
            d.postSeekAcceptedFrames == postSeekExpected && d.postSeekDecodedAcceptedFrames > 0L &&
            d.anchorFrame == declared && d.acceptedFrames == expectedTotal && !d.heldAtHoldFrame &&
            d.postSeekPreRollFrames >= window && d.postSeekPreRollStatePaused && landingOk && d.mediaReopens <= 1 &&
            d.paddedFrames <= (VanguardRealtimePlaybackDecoderFeed.MAX_EOS_DRIFT_SEC * fmt.sampleRate).toLong() &&
            d.discardedPreTargetFrames <= d.maxPreTargetDiscardFrames &&
            d.seekReanchorWallMs >= 0L && q.reanchorWaitMs >= 0L && q.postSeekPreRollWaitMs >= 0L &&
            final.decoderExitReason == VanguardRealtimePlaybackDecoderFeed.EXIT_EOS && final.decoderAcceptedFrames == expectedTotal &&
            final.decoderMediaReleaseCount == 1L && final.decoderMediaReleaseClean
        out.lanes[LANE_BACKWARD_STALE_GENERATION_REJECTED] = d != null &&
            d.staleProbeCalls == 1 && d.staleProbeRejected && d.staleProbeReplyNull && d.staleProbeAnchorUntouched &&
            d.staleProbeReason == VanguardRealtimePlaybackTransportStateMachine.REASON_STALE_GENERATION &&
            final.decoderIngestCallbacksOffOwner == 0L && q.seekGeneration == q.staleGeneration + 1L
        out.lanes[LANE_BACKWARD_SEEK_CLOCK_EPOCH_REBASE] = clockAtPark != null && clockBeforeUnpark != null && clockAfterUnpark != null && asClock != null &&
            !clockAtPark.epochOpen && clockAtPark.epochId == 0 && clockAtPark.positionFrames == sink.positionAtPark &&
            clockAtPark.provenance == VanguardRealtimePlaybackPresentationClock.Provenance.RESET &&
            clockBeforeUnpark.positionFrames == clockAtPark.positionFrames && clockBeforeUnpark.updateCount == clockAtPark.updateCount &&
            !clockBeforeUnpark.epochOpen &&
            sink.positionAtPark >= 0L && sink.positionAtPark <= hold && sink.epochClosedAtPark == 0 && sink.epochOpenedAtUnpark == 1 &&
            sink.seekEpochOpenedAtUnpark == 1 && sink.seekEpochBaseFrame == target &&
            sink.seekDiscontinuityFrames == target - sink.positionAtPark && sink.seekDiscontinuityFrames < 0L &&
            sink.seekEpochOpenAccepted && sink.seekUnwrapResetAtFlush && sink.epochRawOriginAtUnpark == 0L &&
            sink.rebasedClampCount == 0L && sink.clockSnapshotsAtPark == 1L && sink.clockSnapshotsAtDeadObjectRecovery == 0L &&
            sink.clockDeclaredBackwardOpenCalls == 1 && sink.seekDeclaredBackward &&
            clockAfterUnpark.epochOpen && clockAfterUnpark.epochId == 1 && clockAfterUnpark.epochBaseOffsetFrames == target &&
            clockAfterUnpark.positionFrames >= target && clockAfterUnpark.baseClampCount == 0L && !clockAfterUnpark.faulted &&
            clockAfterUnpark.baseAdvanceCount == 0L && clockAfterUnpark.declaredBackwardBaseCount == 1L &&
            clockAfterUnpark.lastDeclaredBackwardFrames == sink.positionAtPark - target &&
            asClock.epochId == 1 && asClock.epochBaseOffsetFrames == target && asClock.positionFrames >= target &&
            asClock.baseClampCount == 0L && !asClock.faulted &&
            clock.epochOpenCount == 2 && clock.epochCloseCount == 2 && clock.baseClampCount == 0L && !clock.faulted &&
            clock.monotonicViolationCount == 0L && clock.regressionCount == 0L &&
            clock.positionFrames >= target && clock.positionFrames <= declared &&
            !clock.epochOpen && clock.epochId == 1 && clock.declaredBackwardBaseCount == 1L &&
            clock.timestampSuccessCount > clockAfterUnpark.timestampSuccessCount && clock.anchoredCount > clockAfterUnpark.anchoredCount
        // Rebase to the backward target is proven by the clock epoch base
        // (declaredBackwardBaseCount=1, baseClampCount=0) rather than by
        // requiring the query to stay under the pre-seek hold after resume,
        // since forward playback resumes immediately and may legitimately
        // advance the query at or past hold before it is read.
        out.lanes[LANE_BACKWARD_POSITION_QUERY_REBASE] = afterSeekQueryFrames >= target &&
            afterSeekQueryFrames <= declared &&
            afterSeekQueryUs >= 0L &&
            clockAfterUnpark != null && clockAfterUnpark.epochBaseOffsetFrames == target &&
            clockAfterUnpark.declaredBackwardBaseCount == 1L && clockAfterUnpark.baseClampCount == 0L &&
            asClock != null && asClock.epochBaseOffsetFrames == target && asClock.baseClampCount == 0L
        out.lanes[LANE_BACKWARD_DRIFT_SAMPLE_BOUNDED] = sink.driftSamplesPosted >= 0L && sink.driftSamplesDropped >= 0L &&
            sink.driftNativeSamplesRejected >= 0L && sink.driftNativeSamplesRejected <= sink.driftSamplesPosted &&
            sink.driftSamplesStaleRejected >= 0L && sink.driftSamplesOtherRejected >= 0L &&
            sink.driftSamplesStaleRejected + sink.driftSamplesOtherRejected <= sink.driftSamplesPosted
        out.lanes[LANE_BACKWARD_CLOCK_CORRELATION] = clock.consistent && !clock.faulted &&
            clock.writerThreadId == sink.threadId && clock.timestampSuccessCount > 0L && clock.anchoredCount > 0L &&
            sink.timestampPollSuccesses == clock.timestampSuccessCount
        out.lanes[LANE_BACKWARD_POST_SEEK_FRAME_ACCOUNTING] = q.armed && hold > 0L && target >= 0L && target < hold &&
            playthroughAccountingOk(final, stateAtCompletion, expectedTotal) && checksumIdentityOk(final) && landingOk &&
            asSink != null && reply != null &&
            sink.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS && sink.eosDrainedObserved &&
            sink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.EXITED && q.resumeAccepted &&
            asSink.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_RUNNING &&
            asSink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.RUNNING && asSink.unparkCount == 1 && asSink.flushCount == 1 &&
            sink.framesReadFromTransport == expectedTotal && sink.framesWrittenToSink == expectedTotal &&
            sink.postSeekFramesWritten == postSeekExpected && sink.drainCalls > sink.drainCallsAtFlush && sink.productiveDrainPasses > 0L &&
            reply.pushedFrames == expectedTotal && reply.drainedFrames == expectedTotal && reply.discardedFrames == 0L &&
            reply.positionFrame == declared && reply.eosDrained &&
            final.transportCompletedCallbacks == 1 && final.transportFailedCallbacks == 0 && final.failureReason.isBlank() &&
            stateAtCompletion == VanguardRealtimeAudioPlaybackSession.State.COMPLETED
        out.lanes[LANE_BACKWARD_SEEK_REPEATED_REJECT] = afterRepeated.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING &&
            afterRepeated.transportState == playing &&
            afterRepeated.failureReason.isBlank() &&
            afterRepeated.seek.seekCount == 1 &&
            afterRepeated.transportGeneration == afterSeek.transportGeneration &&
            arSink != null && arSink.audioTracksCreated == 1 && arSink.releaseCount == 0 &&
            arSink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.RUNNING &&
            arSink.seekParkCount == 1 && arSink.flushCount == 1 && arSink.unparkCount == 1 &&
            !afterRepeated.cancelled
        out.lanes[LANE_BACKWARD_NO_FEEDBACK] = final.failureReason.isBlank() &&
            stateAtCompletion == VanguardRealtimeAudioPlaybackSession.State.COMPLETED &&
            playthroughAccountingOk(final, stateAtCompletion, expectedTotal) &&
            checksumIdentityOk(final) &&
            sink.drainRequestSizeChanges == 0L && sink.timestampMaxPollsInOnePass <= 1L &&
            sink.timestampPollsWhileParked == 0L && sink.timestampPollsDuringFlush == 0L &&
            final.transportCompletedCallbacks == 1 && final.transportFailedCallbacks == 0
    }

    // Y11b lanes: focus duck -> gain restore -> transient pause ->
    // auto-resume -> noisy terminal pause -> ignored gain.
    fun evaluateFocusDuckTransientNoisy(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterStart: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterDuck: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterRestore: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterTransientPause: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterAutoResume: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterNoisy: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterIgnoredGain: VanguardRealtimeAudioPlaybackSession.Snapshot,
        config: SmokeConfig,
        out: ScenarioOutcome,
        coordinatorThreadId: Long,
    ) {
        val sink = final.sink ?: return
        val duckSink = afterDuck.sink ?: return
        val restoreSink = afterRestore.sink ?: return
        val playing = VanguardRealtimePlaybackTransportStateMachine.State.PLAYING
        val paused = VanguardRealtimePlaybackTransportStateMachine.State.PAUSED

        out.metrics["afterDuckGain"] = duckSink.effectiveGain.toDouble()
        out.metrics["afterRestoreGain"] = restoreSink.effectiveGain.toDouble()
        out.metrics["duckAppliedCount"] = afterDuck.focus.duckAppliedCount
        out.metrics["gainRestoreAppliedCount"] = afterRestore.focus.gainRestoreAppliedCount
        out.metrics["pauseTransientAppliedCount"] = afterTransientPause.focus.pauseTransientAppliedCount
        out.metrics["autoResumeAppliedCount"] = afterAutoResume.focus.autoResumeAppliedCount
        out.metrics["pauseNoisyAppliedCount"] = afterNoisy.focus.pauseNoisyAppliedCount
        out.metrics["ignoredGainEventsDrained"] = afterIgnoredGain.focus.eventsDrained
        out.metrics["ignoredGainRestoreAppliedCount"] = afterIgnoredGain.focus.gainRestoreAppliedCount
        out.metrics["ignoredGainAutoResumeCount"] = afterIgnoredGain.focus.autoResumeAppliedCount

        val monitorThreadOk = final.focus.monitorThreadId > 0L &&
            final.focus.monitorThreadId != coordinatorThreadId &&
            final.focus.monitorThreadId != sink.threadId &&
            final.focus.monitorThreadId != final.decoderThreadId

        out.lanes[LANE_THREAD_OWNERSHIP] = final.decoderThreadId > 0L && sink.threadId > 0L &&
            final.decoderThreadId != sink.threadId &&
            final.decoderThreadId != coordinatorThreadId && sink.threadId != coordinatorThreadId &&
            !final.decoderThreadIsTransportOwner && !sink.threadIsTransportOwner &&
            final.decoderIngestCallbacksOnOwner > 0L && final.decoderIngestCallbacksOffOwner == 0L &&
            final.listenerCallbacksOnOwner > 0L && final.listenerCallbacksOffOwner == 0L &&
            sink.audioTrackCallsOffSinkThread == 0L &&
            monitorThreadOk

        out.lanes[LANE_PROOF_BOUNDARY] = PROOF_BOUNDARY_TOKENS.all { PROOF_BOUNDARY.contains(it) }

        out.lanes[LANE_FOCUS_SETUP] = afterStart.focus.enabled &&
            afterStart.focus.controllerRequested &&
            afterStart.focus.controllerGranted &&
            afterStart.focus.controllerNoisyRegistered &&
            afterStart.focus.monitorStarted &&
            afterStart.focus.monitorThreadId > 0L

        out.lanes[LANE_FOCUS_DUCK_RESTORE] = afterDuck.focus.duckAppliedCount == 1L &&
            afterDuck.focus.focusState == "ducked" &&
            kotlin.math.abs(duckSink.effectiveGain - config.duckGain) <= 0.001f &&
            afterRestore.focus.gainRestoreAppliedCount == 1L &&
            afterRestore.focus.focusState == "held" &&
            kotlin.math.abs(restoreSink.effectiveGain - config.gain) <= 0.001f &&
            duckSink.gainAppliedOnSinkThread &&
            restoreSink.gainAppliedOnSinkThread

        out.lanes[LANE_FOCUS_TRANSIENT_PAUSE_RESUME] = afterTransientPause.focus.pauseTransientAppliedCount == 1L &&
            afterTransientPause.focus.focusPausedByPolicy &&
            afterTransientPause.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
            afterTransientPause.transportState == paused &&
            afterAutoResume.focus.autoResumeAppliedCount == 1L &&
            !afterAutoResume.focus.focusPausedByPolicy &&
            afterAutoResume.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING &&
            afterAutoResume.transportState == playing

        out.lanes[LANE_FOCUS_NOISY_TERMINAL_PAUSE] = afterNoisy.focus.pauseNoisyAppliedCount == 1L &&
            afterNoisy.focus.terminalNoisyLoss &&
            afterNoisy.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
            afterNoisy.transportState == paused &&
            afterIgnoredGain.focus.eventsDrained >= afterNoisy.focus.eventsDrained + 1L &&
            afterIgnoredGain.focus.gainRestoreAppliedCount >= afterRestore.focus.gainRestoreAppliedCount + 1L &&
            afterIgnoredGain.focus.autoResumeAppliedCount == 1L &&
            afterIgnoredGain.focus.terminalNoisyLoss &&
            afterIgnoredGain.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
            afterIgnoredGain.transportState == paused

        out.lanes[LANE_FOCUS_MONITOR_TEARDOWN] = final.focus.controllerReleased &&
            final.focus.monitorExited &&
            final.focus.monitorJoined &&
            sink.releaseCount == 1 &&
            sink.releaseExecutedOnSinkThread &&
            final.sinkJoined &&
            sink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.EXITED &&
            final.transportDisposeCalls == 1 &&
            final.transportStateAfterDispose == VanguardRealtimePlaybackTransportStateMachine.State.DISPOSED &&
            final.state == VanguardRealtimeAudioPlaybackSession.State.DISPOSED &&
            final.failureReason.isBlank()
    }

    // Y11b lanes: permanent focus loss -> no auto-resume on gain.
    fun evaluateFocusPermanentLoss(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterStart: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterPermanent: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterIgnoredGain: VanguardRealtimeAudioPlaybackSession.Snapshot,
        config: SmokeConfig,
        out: ScenarioOutcome,
        coordinatorThreadId: Long,
    ) {
        val sink = final.sink ?: return
        val paused = VanguardRealtimePlaybackTransportStateMachine.State.PAUSED

        out.metrics["pausePermanentAppliedCount"] = afterPermanent.focus.pausePermanentAppliedCount
        out.metrics["ignoredGainEventsDrained"] = afterIgnoredGain.focus.eventsDrained
        out.metrics["ignoredGainRestoreAppliedCount"] = afterIgnoredGain.focus.gainRestoreAppliedCount
        out.metrics["ignoredGainAutoResumeCount"] = afterIgnoredGain.focus.autoResumeAppliedCount
        out.metrics["ignoredGainAutoResumeCountPermanent"] = afterIgnoredGain.focus.autoResumeAppliedCount

        val monitorThreadOk = final.focus.monitorThreadId > 0L &&
            final.focus.monitorThreadId != coordinatorThreadId &&
            final.focus.monitorThreadId != sink.threadId &&
            final.focus.monitorThreadId != final.decoderThreadId

        out.lanes[LANE_THREAD_OWNERSHIP] = final.decoderThreadId > 0L && sink.threadId > 0L &&
            final.decoderThreadId != sink.threadId &&
            final.decoderThreadId != coordinatorThreadId && sink.threadId != coordinatorThreadId &&
            !final.decoderThreadIsTransportOwner && !sink.threadIsTransportOwner &&
            final.decoderIngestCallbacksOnOwner > 0L && final.decoderIngestCallbacksOffOwner == 0L &&
            final.listenerCallbacksOnOwner > 0L && final.listenerCallbacksOffOwner == 0L &&
            sink.audioTrackCallsOffSinkThread == 0L &&
            monitorThreadOk

        out.lanes[LANE_PROOF_BOUNDARY] = PROOF_BOUNDARY_TOKENS.all { PROOF_BOUNDARY.contains(it) }

        out.lanes[LANE_FOCUS_SETUP] = afterStart.focus.enabled &&
            afterStart.focus.controllerRequested &&
            afterStart.focus.controllerGranted &&
            afterStart.focus.controllerNoisyRegistered &&
            afterStart.focus.monitorStarted &&
            afterStart.focus.monitorThreadId > 0L

        out.lanes[LANE_FOCUS_PERMANENT_LOSS_PAUSE] = afterPermanent.focus.pausePermanentAppliedCount == 1L &&
            afterPermanent.focus.terminalPermanentLoss &&
            afterPermanent.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
            afterPermanent.transportState == paused &&
            afterIgnoredGain.focus.eventsDrained >= afterPermanent.focus.eventsDrained + 1L &&
            afterIgnoredGain.focus.gainRestoreAppliedCount >= 1L &&
            afterIgnoredGain.focus.autoResumeAppliedCount == 0L &&
            afterIgnoredGain.focus.terminalPermanentLoss &&
            afterIgnoredGain.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
            afterIgnoredGain.transportState == paused

        out.lanes[LANE_FOCUS_MONITOR_TEARDOWN] = final.focus.controllerReleased &&
            final.focus.monitorExited &&
            final.focus.monitorJoined &&
            sink.releaseCount == 1 &&
            sink.releaseExecutedOnSinkThread &&
            final.sinkJoined &&
            sink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.EXITED &&
            final.transportDisposeCalls == 1 &&
            final.transportStateAfterDispose == VanguardRealtimePlaybackTransportStateMachine.State.DISPOSED &&
            final.state == VanguardRealtimeAudioPlaybackSession.State.DISPOSED &&
            final.failureReason.isBlank()
    }

    // Y12 lane: route change observation only (independently bounded scenario, no
    // disconnect ever posted). Uses a monotonic baseline increase on
    // routeChangedAppliedCount rather than an exact-equality check so a real OS
    // ROUTE_CHANGED callback racing the synthetic one cannot skip the check past the
    // polling loop and starve the whole scenario on the session's own deadline.
    fun evaluateRouteChangeObservation(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterStart: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterRouteChange: VanguardRealtimeAudioPlaybackSession.Snapshot,
        config: SmokeConfig,
        out: ScenarioOutcome,
        coordinatorThreadId: Long,
    ) {
        val sink = final.sink ?: return
        val playing = VanguardRealtimePlaybackTransportStateMachine.State.PLAYING

        out.metrics["routeChangedAppliedBaseline"] = afterStart.routing.routeChangedAppliedCount
        out.metrics["routeChangedAppliedCount"] = afterRouteChange.routing.routeChangedAppliedCount
        out.metrics["routeDisconnectAppliedCount"] = afterRouteChange.routing.routeDisconnectAppliedCount
        out.metrics["routingTerminalDisconnect"] = afterRouteChange.routing.routingTerminalDisconnect
        out.metrics["routingMonitorThreadId"] = afterStart.routing.monitorThreadId
        out.metrics["routingAttachCount"] = afterStart.routing.attachCount
        out.metrics["routingDetachCount"] = final.routing.detachCount

        val focusMonitorThreadOk = if (final.focus.monitorThreadId > 0L) {
            final.focus.monitorThreadId != coordinatorThreadId &&
                final.focus.monitorThreadId != sink.threadId &&
                final.focus.monitorThreadId != final.decoderThreadId
        } else {
            true
        }
        val routingMonitorThreadOk = final.routing.monitorThreadId > 0L &&
            final.routing.monitorThreadId != coordinatorThreadId &&
            final.routing.monitorThreadId != sink.threadId &&
            final.routing.monitorThreadId != final.decoderThreadId &&
            (final.focus.monitorThreadId == 0L || final.routing.monitorThreadId != final.focus.monitorThreadId)

        out.lanes[LANE_THREAD_OWNERSHIP] = final.decoderThreadId > 0L && sink.threadId > 0L &&
            final.decoderThreadId != sink.threadId &&
            final.decoderThreadId != coordinatorThreadId && sink.threadId != coordinatorThreadId &&
            !final.decoderThreadIsTransportOwner && !sink.threadIsTransportOwner &&
            final.decoderIngestCallbacksOnOwner > 0L && final.decoderIngestCallbacksOffOwner == 0L &&
            final.listenerCallbacksOnOwner > 0L && final.listenerCallbacksOffOwner == 0L &&
            sink.audioTrackCallsOffSinkThread == 0L &&
            focusMonitorThreadOk && routingMonitorThreadOk

        out.lanes[LANE_PROOF_BOUNDARY] = PROOF_BOUNDARY_TOKENS.all { PROOF_BOUNDARY.contains(it) }

        out.lanes[LANE_ROUTING_SETUP] = afterStart.routing.enabled &&
            afterStart.routing.controllerAttached &&
            afterStart.routing.attachCount == 1 &&
            afterStart.routing.monitorStarted &&
            routingMonitorThreadOk &&
            afterStart.routing.eventsDropped == 0L &&
            final.routing.eventsDropped == 0L

        out.lanes[LANE_ROUTE_CHANGE_OBSERVATION] = afterRouteChange.routing.routeChangedAppliedCount >=
            afterStart.routing.routeChangedAppliedCount + 1L &&
            afterRouteChange.routing.lastEventTag == "ROUTE_CHANGED" &&
            afterRouteChange.routing.lastAction == "observed" &&
            (afterRouteChange.routing.lastEventSource == "SYNTHETIC" || afterRouteChange.routing.lastEventSource == "OS_ROUTING_CALLBACK") &&
            afterRouteChange.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING &&
            afterRouteChange.transportState == playing &&
            !afterRouteChange.routing.routingTerminalDisconnect &&
            afterRouteChange.routing.routeDisconnectAppliedCount == afterStart.routing.routeDisconnectAppliedCount

        out.lanes[LANE_ROUTING_MONITOR_TEARDOWN] = final.routing.controllerReleased &&
            !final.routing.controllerAttached &&
            final.routing.detachCount >= 1 &&
            final.routing.monitorExited &&
            final.routing.monitorJoined &&
            final.routing.eventsPending == 0 &&
            final.routing.eventsDropped == 0L &&
            sink.releaseCount == 1 &&
            sink.releaseExecutedOnSinkThread &&
            final.sinkJoined &&
            sink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.EXITED &&
            final.transportDisposeCalls == 1 &&
            final.transportStateAfterDispose == VanguardRealtimePlaybackTransportStateMachine.State.DISPOSED &&
            final.state == VanguardRealtimeAudioPlaybackSession.State.DISPOSED &&
            final.failureReason.isBlank()
    }

    // Y12 lane: route disconnect terminal pause -> public resume rejected -> routing
    // teardown (independently bounded scenario, fresh PLAYING session so the native
    // bounded-pause path runs and routeDisconnectAppliedCount is a valid monotonic
    // proof signal here).
    fun evaluateRouteDisconnectTerminalPause(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterStart: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterDisconnect: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterRejectedResume: VanguardRealtimeAudioPlaybackSession.Snapshot,
        resumeRes: VanguardRealtimeAudioPlaybackSession.CommandResult,
        config: SmokeConfig,
        out: ScenarioOutcome,
        coordinatorThreadId: Long,
    ) {
        val sink = final.sink ?: return
        val paused = VanguardRealtimePlaybackTransportStateMachine.State.PAUSED

        out.metrics["routeDisconnectAppliedBaseline"] = afterStart.routing.routeDisconnectAppliedCount
        out.metrics["routeDisconnectAppliedCount"] = afterDisconnect.routing.routeDisconnectAppliedCount
        out.metrics["routingTerminalDisconnect"] = afterDisconnect.routing.routingTerminalDisconnect
        out.metrics["routingPausedByPolicy"] = afterDisconnect.routing.routingPausedByPolicy
        out.metrics["publicResumeAccepted"] = resumeRes.accepted
        out.metrics["publicResumeReason"] = resumeRes.reason
        out.metrics["afterRejectedResumeState"] = afterRejectedResume.state.name
        out.metrics["routingMonitorThreadId"] = afterStart.routing.monitorThreadId
        out.metrics["routingAttachCount"] = afterStart.routing.attachCount
        out.metrics["routingDetachCount"] = final.routing.detachCount

        val focusMonitorThreadOk = if (final.focus.monitorThreadId > 0L) {
            final.focus.monitorThreadId != coordinatorThreadId &&
                final.focus.monitorThreadId != sink.threadId &&
                final.focus.monitorThreadId != final.decoderThreadId
        } else {
            true
        }
        val routingMonitorThreadOk = final.routing.monitorThreadId > 0L &&
            final.routing.monitorThreadId != coordinatorThreadId &&
            final.routing.monitorThreadId != sink.threadId &&
            final.routing.monitorThreadId != final.decoderThreadId &&
            (final.focus.monitorThreadId == 0L || final.routing.monitorThreadId != final.focus.monitorThreadId)

        out.lanes[LANE_THREAD_OWNERSHIP] = final.decoderThreadId > 0L && sink.threadId > 0L &&
            final.decoderThreadId != sink.threadId &&
            final.decoderThreadId != coordinatorThreadId && sink.threadId != coordinatorThreadId &&
            !final.decoderThreadIsTransportOwner && !sink.threadIsTransportOwner &&
            final.decoderIngestCallbacksOnOwner > 0L && final.decoderIngestCallbacksOffOwner == 0L &&
            final.listenerCallbacksOnOwner > 0L && final.listenerCallbacksOffOwner == 0L &&
            sink.audioTrackCallsOffSinkThread == 0L &&
            focusMonitorThreadOk && routingMonitorThreadOk

        out.lanes[LANE_PROOF_BOUNDARY] = PROOF_BOUNDARY_TOKENS.all { PROOF_BOUNDARY.contains(it) }

        out.lanes[LANE_ROUTING_SETUP] = afterStart.routing.enabled &&
            afterStart.routing.controllerAttached &&
            afterStart.routing.attachCount == 1 &&
            afterStart.routing.monitorStarted &&
            routingMonitorThreadOk &&
            afterStart.routing.eventsDropped == 0L &&
            final.routing.eventsDropped == 0L

        val disconnectSink = afterDisconnect.sink
        out.lanes[LANE_ROUTE_DISCONNECT_TERMINAL_PAUSE] = afterDisconnect.routing.routingTerminalDisconnect &&
            afterDisconnect.routing.routingPausedByPolicy &&
            afterDisconnect.routing.routeDisconnectAppliedCount >= afterStart.routing.routeDisconnectAppliedCount + 1L &&
            afterDisconnect.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
            afterDisconnect.transportState == paused &&
            disconnectSink != null &&
            disconnectSink.playStateAtPark == AudioTrack.PLAYSTATE_PAUSED &&
            disconnectSink.parkCount >= 1 &&
            !resumeRes.accepted &&
            resumeRes.reason == "routing_terminal_disconnect" &&
            resumeRes.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
            afterRejectedResume.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
            afterRejectedResume.transportState == paused &&
            afterRejectedResume.routing.routingTerminalDisconnect

        out.lanes[LANE_ROUTING_MONITOR_TEARDOWN] = final.routing.controllerReleased &&
            !final.routing.controllerAttached &&
            final.routing.detachCount >= 1 &&
            final.routing.monitorExited &&
            final.routing.monitorJoined &&
            final.routing.eventsPending == 0 &&
            final.routing.eventsDropped == 0L &&
            sink.releaseCount == 1 &&
            sink.releaseExecutedOnSinkThread &&
            final.sinkJoined &&
            sink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.EXITED &&
            final.transportDisposeCalls == 1 &&
            final.transportStateAfterDispose == VanguardRealtimePlaybackTransportStateMachine.State.DISPOSED &&
            final.state == VanguardRealtimeAudioPlaybackSession.State.DISPOSED &&
            final.failureReason.isBlank()
    }

    // Y12 lanes (Scenario 10): route disconnect while paused by focus policy ->
    // focus auto-resume blocked -> public resume rejected.
    fun evaluateRouteDisconnectFocusGainBlocked(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterStart: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterTransientPause: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterDisconnect: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterIgnoredGain: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterRejectedResume: VanguardRealtimeAudioPlaybackSession.Snapshot,
        resumeRes: VanguardRealtimeAudioPlaybackSession.CommandResult,
        config: SmokeConfig,
        out: ScenarioOutcome,
        coordinatorThreadId: Long,
    ) {
        val sink = final.sink ?: return
        val paused = VanguardRealtimePlaybackTransportStateMachine.State.PAUSED

        out.metrics["pauseTransientAppliedCount"] = afterTransientPause.focus.pauseTransientAppliedCount
        out.metrics["focusPausedByPolicy"] = afterTransientPause.focus.focusPausedByPolicy
        out.metrics["routingTerminalDisconnect"] = afterDisconnect.routing.routingTerminalDisconnect
        out.metrics["routingLastEventTag"] = afterDisconnect.routing.lastEventTag
        out.metrics["routingLastAction"] = afterDisconnect.routing.lastAction
        out.metrics["ignoredGainEventsDrained"] = afterIgnoredGain.focus.eventsDrained
        out.metrics["ignoredGainRestoreAppliedCount"] = afterIgnoredGain.focus.gainRestoreAppliedCount
        out.metrics["ignoredGainAutoResumeCount"] = afterIgnoredGain.focus.autoResumeAppliedCount
        out.metrics["focusPausedByPolicyAfterGain"] = afterIgnoredGain.focus.focusPausedByPolicy
        out.metrics["routingTerminalDisconnectAfterGain"] = afterIgnoredGain.routing.routingTerminalDisconnect
        out.metrics["publicResumeAccepted"] = resumeRes.accepted
        out.metrics["publicResumeReason"] = resumeRes.reason
        out.metrics["afterRejectedResumeState"] = afterRejectedResume.state.name
        out.metrics["routingMonitorThreadId"] = afterStart.routing.monitorThreadId
        out.metrics["routingAttachCount"] = afterStart.routing.attachCount
        out.metrics["routingDetachCount"] = final.routing.detachCount

        val focusMonitorThreadOk = if (final.focus.monitorThreadId > 0L) {
            final.focus.monitorThreadId != coordinatorThreadId &&
                final.focus.monitorThreadId != sink.threadId &&
                final.focus.monitorThreadId != final.decoderThreadId
        } else {
            true
        }
        val routingMonitorThreadOk = final.routing.monitorThreadId > 0L &&
            final.routing.monitorThreadId != coordinatorThreadId &&
            final.routing.monitorThreadId != sink.threadId &&
            final.routing.monitorThreadId != final.decoderThreadId &&
            (final.focus.monitorThreadId == 0L || final.routing.monitorThreadId != final.focus.monitorThreadId)

        out.lanes[LANE_THREAD_OWNERSHIP] = final.decoderThreadId > 0L && sink.threadId > 0L &&
            final.decoderThreadId != sink.threadId &&
            final.decoderThreadId != coordinatorThreadId && sink.threadId != coordinatorThreadId &&
            !final.decoderThreadIsTransportOwner && !sink.threadIsTransportOwner &&
            final.decoderIngestCallbacksOnOwner > 0L && final.decoderIngestCallbacksOffOwner == 0L &&
            final.listenerCallbacksOnOwner > 0L && final.listenerCallbacksOffOwner == 0L &&
            sink.audioTrackCallsOffSinkThread == 0L &&
            focusMonitorThreadOk && routingMonitorThreadOk

        out.lanes[LANE_PROOF_BOUNDARY] = PROOF_BOUNDARY_TOKENS.all { PROOF_BOUNDARY.contains(it) }

        out.lanes[LANE_ROUTING_SETUP] = afterStart.routing.enabled &&
            afterStart.routing.controllerAttached &&
            afterStart.routing.attachCount == 1 &&
            afterStart.routing.monitorStarted &&
            routingMonitorThreadOk &&
            afterStart.routing.eventsDropped == 0L &&
            final.routing.eventsDropped == 0L

        out.lanes[LANE_ROUTE_DISCONNECT_RESUME_BLOCKED] = !resumeRes.accepted &&
            resumeRes.reason == "routing_terminal_disconnect" &&
            resumeRes.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
            afterRejectedResume.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
            afterRejectedResume.transportState == paused &&
            afterRejectedResume.routing.routingTerminalDisconnect &&
            afterTransientPause.focus.focusPausedByPolicy &&
            afterTransientPause.focus.autoResumeAppliedCount == 0L &&
            afterTransientPause.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
            afterTransientPause.transportState == paused &&
            // The session was already PAUSED (by focus policy) when the disconnect
            // landed, so the native session's bounded-pause path never ran and
            // routeDisconnectAppliedCount never bumped (session code only bumps it from
            // PLAYING); the sticky routingTerminalDisconnect transition from the
            // pre-disconnect baseline is therefore the reliable proof signal here, not a
            // count delta or a snapshot of lastEventTag/lastAction, which are
            // last-writer-wins fields a later real OS ROUTE_CHANGED callback can
            // overwrite before this snapshot is captured.
            !afterTransientPause.routing.routingTerminalDisconnect &&
            afterDisconnect.routing.routingTerminalDisconnect &&
            afterDisconnect.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
            afterDisconnect.transportState == paused &&
            afterIgnoredGain.focus.eventsDrained >= afterDisconnect.focus.eventsDrained + 1L &&
            afterIgnoredGain.focus.gainRestoreAppliedCount >= 1L &&
            afterIgnoredGain.focus.autoResumeAppliedCount == 0L &&
            afterIgnoredGain.focus.focusPausedByPolicy &&
            afterIgnoredGain.routing.routingTerminalDisconnect &&
            afterIgnoredGain.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
            afterIgnoredGain.transportState == paused

        out.lanes[LANE_ROUTING_MONITOR_TEARDOWN] = final.routing.controllerReleased &&
            !final.routing.controllerAttached &&
            final.routing.detachCount >= 1 &&
            final.routing.monitorExited &&
            final.routing.monitorJoined &&
            final.routing.eventsPending == 0 &&
            final.routing.eventsDropped == 0L &&
            sink.releaseCount == 1 &&
            sink.releaseExecutedOnSinkThread &&
            final.sinkJoined &&
            sink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.EXITED &&
            final.transportDisposeCalls == 1 &&
            final.transportStateAfterDispose == VanguardRealtimePlaybackTransportStateMachine.State.DISPOSED &&
            final.state == VanguardRealtimeAudioPlaybackSession.State.DISPOSED &&
            final.failureReason.isBlank()
    }

    // Y13 lanes: the off-thread poller repeatedly queried the public query
    // surface (currentPositionFrames / currentPositionUs) on an independent
    // thread without regressing, currentPosition read counters recorded
    // writer vs other thread reads cleanly isolated from snapshot counters,
    // epoch-relative presentation lag telemetry was captured and bounded
    // analytically, and the final EOS position exhibited no runaway.
    fun evaluatePresentationClockQuerySurface(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        poller: PresentationClockPollerMetrics,
        stateAtCompletion: VanguardRealtimeAudioPlaybackSession.State,
        config: SmokeConfig,
        out: ScenarioOutcome,
        postTeardownFrames: Long = -1L,
        postTeardownUs: Long = -1L,
        correlation: VanguardRealtimeAudioPlaybackClockCorrelation? = null,
        commandsBefore: Int = -1,
        commandsAfter: Int = -1,
    ) {
        val fmt = final.format ?: return
        val sink = final.sink ?: return
        val clock = final.clock ?: return
        val declared = fmt.declaredFrameCount

        out.metrics["stateAtCompletion"] = stateAtCompletion.name
        out.metrics["pollerPollCount"] = poller.pollCount
        out.metrics["pollerValidCount"] = poller.validCount
        out.metrics["pollerRegressionCount"] = poller.regressionCount
        out.metrics["pollerFrameReadCount"] = poller.frameReadCount
        out.metrics["pollerUsReadCount"] = poller.usReadCount
        out.metrics["pollerLastFrame"] = poller.lastFrame
        out.metrics["pollerLastUs"] = poller.lastUs
        out.metrics["pollerMinFrame"] = poller.minFrame
        out.metrics["pollerMaxFrame"] = poller.maxFrame
        out.metrics["pollerMinUs"] = poller.minUs
        out.metrics["pollerMaxUs"] = poller.maxUs
        out.metrics["pollerThreadId"] = poller.threadId
        out.metrics["pollerJoined"] = poller.joined
        out.metrics["pollerError"] = poller.error
        out.metrics["postTeardownCurrentPositionFrames"] = postTeardownFrames
        out.metrics["postTeardownCurrentPositionUs"] = postTeardownUs
        out.metrics["presentationLagSampleCount"] = sink.presentationLagSampleCount
        out.metrics["presentationLagBoundedSampleCount"] = sink.presentationLagBoundedSampleCount
        out.metrics["presentationLagExcludedSampleCount"] = sink.presentationLagExcludedSampleCount
        out.metrics["lastPresentationLagFrames"] = sink.lastPresentationLagFrames
        out.metrics["minPresentationLagFrames"] = sink.minPresentationLagFrames
        out.metrics["maxPresentationLagFrames"] = sink.maxPresentationLagFrames
        out.metrics["presentationLagLowerBoundFrames"] = sink.presentationLagLowerBoundFrames
        out.metrics["presentationLagUpperBoundFrames"] = sink.presentationLagUpperBoundFrames
        out.metrics["lastPositionFramesAtPoll"] = sink.lastPositionFramesAtPoll
        out.metrics["lastPositionUsAtPoll"] = sink.lastPositionUsAtPoll
        out.metrics["positionAtEosFrames"] = sink.positionAtEosFrames
        out.metrics["positionAtEosUs"] = sink.positionAtEosUs
        out.metrics["currentPositionReadsFromWriterThread"] = sink.currentPositionReadsFromWriterThread
        out.metrics["currentPositionReadsFromOtherThreads"] = sink.currentPositionReadsFromOtherThreads
        out.metrics["nativeClockState"] = correlation?.nativeClockState ?: ""
        out.metrics["nativeClockPositionUs"] = correlation?.nativePositionUs ?: -1L
        out.metrics["nativeClockPositionFrame"] = correlation?.nativePositionFrame ?: -1L
        out.metrics["nativeClockDriftSampleCount"] = correlation?.nativeDriftSampleCount ?: -1L
        out.metrics["presentationClockPositionUsAtCorrelation"] = correlation?.presentationPositionUs ?: -1L
        out.metrics["presentationClockPositionFramesAtCorrelation"] = correlation?.presentationPositionFrames ?: -1L
        out.metrics["clockCorrelationOffsetUs"] = correlation?.offsetUs ?: -1L
        out.metrics["clockCorrelationOffsetFrames"] = correlation?.offsetFrames ?: -1L
        out.metrics["clockCorrelationCommandsBefore"] = commandsBefore
        out.metrics["clockCorrelationCommandsAfter"] = commandsAfter
        out.metrics["driftSamplesPosted"] = sink.driftSamplesPosted
        out.metrics["driftSamplesSkipped"] = sink.driftSamplesSkipped
        out.metrics["driftSamplesDropped"] = sink.driftSamplesDropped
        out.metrics["driftCallbackCount"] = sink.driftCallbackCount
        out.metrics["driftSamplesRecorded"] = sink.driftSamplesRecorded
        out.metrics["driftSamplesStaleRejected"] = sink.driftSamplesStaleRejected
        out.metrics["driftSamplesOtherRejected"] = sink.driftSamplesOtherRejected
        out.metrics["driftLastRejectReason"] = sink.driftLastRejectReason
        out.metrics["driftMaxQueueLatencyNs"] = sink.driftMaxQueueLatencyNs
        out.metrics["driftLastPostedGeneration"] = sink.driftLastPostedGeneration
        out.metrics["driftLastExpectedPtsUs"] = sink.driftLastExpectedPtsUs
        out.metrics["driftLastReportedPtsUs"] = sink.driftLastReportedPtsUs
        out.metrics["driftLastDeltaUs"] = sink.driftLastDeltaUs
        out.metrics["driftLastReportedFrame"] = sink.driftLastReportedFrame
        out.metrics["driftNativeSampleCount"] = sink.driftNativeSampleCount
        out.metrics["driftNativeSamplesRecorded"] = sink.driftNativeSamplesRecorded
        out.metrics["driftNativeSamplesRejected"] = sink.driftNativeSamplesRejected

        out.lanes[LANE_PLAYTHROUGH_ACCOUNTING] = playthroughAccountingOk(final, stateAtCompletion)
        out.lanes[LANE_CHECKSUM_IDENTITY] = checksumIdentityOk(final)

        out.lanes[LANE_CURRENT_POSITION_QUERY_SURFACE] = poller.joined &&
            poller.error.isBlank() &&
            poller.validCount > 0L &&
            poller.pollCount > 0L &&
            sink.currentPositionReadsFromOtherThreads >= poller.frameReadCount + poller.usReadCount &&
            sink.currentPositionReadsFromOtherThreads > 0L &&
            final.failureReason.isBlank()

        val threadDistinct = poller.threadId > 0L &&
            poller.threadId != poller.coordinatorThreadId &&
            poller.threadId != sink.threadId &&
            (final.decoderThreadId <= 0L || poller.threadId != final.decoderThreadId)
        out.lanes[LANE_CURRENT_POSITION_POLLER_MONOTONIC] = poller.regressionCount == 0L &&
            poller.validCount >= 3L &&
            poller.frameReadCount >= 3L &&
            poller.usReadCount >= 3L &&
            threadDistinct

        out.lanes[LANE_CURRENT_POSITION_READ_COUNTER_ISOLATION] = sink.currentPositionReadsFromOtherThreads >= poller.frameReadCount + poller.usReadCount &&
            sink.currentPositionReadsFromOtherThreads > 0L &&
            sink.currentPositionReadsFromWriterThread >= 1L &&
            clock.offWriterThreadCalls == 0L

        out.lanes[LANE_PRESENTATION_LAG_TELEMETRY] = sink.presentationLagSampleCount > 0L &&
            sink.lastPositionFramesAtPoll >= 0L &&
            sink.presentationLagLowerBoundFrames <= sink.presentationLagUpperBoundFrames &&
            sink.presentationLagExcludedSampleCount >= 0L

        out.lanes[LANE_PRESENTATION_LAG_BOUNDED] = sink.presentationLagBoundedSampleCount == sink.presentationLagSampleCount &&
            sink.presentationLagSampleCount > 0L &&
            sink.lastPresentationLagFrames in sink.presentationLagLowerBoundFrames..sink.presentationLagUpperBoundFrames &&
            sink.minPresentationLagFrames in sink.presentationLagLowerBoundFrames..sink.presentationLagUpperBoundFrames &&
            sink.maxPresentationLagFrames in sink.presentationLagLowerBoundFrames..sink.presentationLagUpperBoundFrames

        val maxAllowedEosFrames = declared + sink.audioTrackBufferFrames.toLong() + config.maxFramesPerMix.toLong()
        out.lanes[LANE_POSITION_AT_EOS_NO_RUNAWAY] = sink.positionAtEosFrames >= 0L &&
            sink.positionAtEosUs >= 0L &&
            sink.positionAtEosFrames <= maxAllowedEosFrames

        out.lanes[LANE_POSITION_QUERY_POST_TEARDOWN_LATCHED] = postTeardownFrames >= 0L &&
            postTeardownUs >= 0L &&
            clock.positionFrames >= 0L &&
            clock.positionUs >= 0L &&
            postTeardownFrames >= clock.positionFrames &&
            postTeardownUs >= clock.positionUs

        val nativeClockStateValid = correlation != null &&
            correlation.nativeClockState.isNotBlank() &&
            !correlation.nativeClockState.equals("none", ignoreCase = true) &&
            !correlation.nativeClockState.equals("unknown", ignoreCase = true)
        out.lanes[LANE_NATIVE_AUDIO_CLOCK_SNAPSHOT_PUBLISHED] = correlation != null &&
            nativeClockStateValid &&
            correlation.nativePositionUs >= 0L &&
            correlation.nativePositionFrame >= 0L

        out.lanes[LANE_CLOCK_CORRELATION_TELEMETRY] = correlation != null &&
            correlation.presentationConsistent &&
            correlation.presentationPositionUs >= 0L &&
            correlation.presentationPositionFrames >= 0L

        out.lanes[LANE_CLOCK_OBSERVATION_NO_FEEDBACK] = correlation != null &&
            commandsBefore >= 0 &&
            commandsBefore == commandsAfter

        out.lanes[LANE_DRIFT_SAMPLE_WORKER_OWNED] = sink.driftSamplesPosted > 0L &&
            sink.driftCallbackCount > 0L &&
            sink.driftSamplesRecorded > 0L &&
            sink.driftNativeSamplesRecorded > 0L &&
            sink.driftNativeSampleCount > 0L &&
            sink.driftLastExpectedPtsUs >= 0L &&
            sink.driftLastReportedPtsUs >= 0L &&
            sink.driftLastReportedFrame >= 0L &&
            sink.driftNativeSamplesRejected >= 0L &&
            sink.driftNativeSamplesRejected <= sink.driftSamplesPosted

        val staleAttempted = out.metrics["staleProbeAttempted"] as? Boolean ?: false
        val stalePostReturn = out.metrics["staleProbePostReturn"] as? Boolean ?: false
        val staleCallbackCount = (out.metrics["staleProbeCallbackCount"] as? Number)?.toLong() ?: -1L
        val staleRejectedCount = (out.metrics["staleProbeStaleRejectedCount"] as? Number)?.toLong() ?: -1L
        val staleReason = out.metrics["staleProbeReason"] as? String ?: ""
        val staleAccepted = out.metrics["staleProbeAccepted"] as? Boolean ?: true
        val nativeRecBefore = (out.metrics["staleProbeNativeRecordedBefore"] as? Number)?.toLong() ?: -1L
        val nativeRecAfter = (out.metrics["staleProbeNativeRecordedAfter"] as? Number)?.toLong() ?: -2L
        val nativeCntBefore = (out.metrics["staleProbeNativeCountBefore"] as? Number)?.toLong() ?: -1L
        val nativeCntAfter = (out.metrics["staleProbeNativeCountAfter"] as? Number)?.toLong() ?: -2L
        val cmdBefore = (out.metrics["staleProbeCommandsBefore"] as? Number)?.toInt() ?: -1
        val cmdAfter = (out.metrics["staleProbeCommandsAfter"] as? Number)?.toInt() ?: -2
        val stateBefore = out.metrics["staleProbeStateBefore"] as? String ?: ""
        val stateAfter = out.metrics["staleProbeStateAfter"] as? String ?: ""

        out.lanes[LANE_DRIFT_SAMPLE_GENERATION_PINNED] = staleAttempted &&
            stalePostReturn &&
            staleCallbackCount == 1L &&
            staleRejectedCount == 1L &&
            staleReason == VanguardRealtimePlaybackTransportStateMachine.REASON_STALE_GENERATION &&
            !staleAccepted &&
            nativeRecBefore >= 0L &&
            nativeRecBefore == nativeRecAfter &&
            nativeCntBefore >= 0L &&
            nativeCntBefore == nativeCntAfter &&
            cmdBefore >= 0 &&
            cmdBefore == cmdAfter &&
            stateBefore.isNotBlank() &&
            stateBefore == stateAfter

        out.lanes[LANE_DRIFT_SAMPLE_NO_FEEDBACK] = final.failureReason.isBlank() &&
            stateAtCompletion == VanguardRealtimeAudioPlaybackSession.State.COMPLETED &&
            playthroughAccountingOk(final, stateAtCompletion) &&
            checksumIdentityOk(final) &&
            out.lanes[LANE_NO_FEEDBACK] == true &&
            final.transportCompletedCallbacks >= 1 &&
            final.transportFailedCallbacks == 0

        out.lanes[LANE_CLOCK_AUTHORITY_UNCHANGED] = out.lanes[LANE_CURRENT_POSITION_QUERY_SURFACE] == true &&
            out.lanes[LANE_CURRENT_POSITION_POLLER_MONOTONIC] == true &&
            out.lanes[LANE_CURRENT_POSITION_READ_COUNTER_ISOLATION] == true &&
            out.lanes[LANE_POSITION_QUERY_POST_TEARDOWN_LATCHED] == true &&
            postTeardownFrames >= clock.positionFrames &&
            postTeardownUs >= clock.positionUs &&
            clock.offWriterThreadCalls == 0L
    }

    // Y18b (P4-AUDIO-REALTIME-PLAYBACK-RING-FRAME-SOURCE-PROOF): the ONE
    // ring-transport lane. The production sink was fed through the Y18a
    // frameSource seam from the async-runtime multi-source native output
    // ring (no state machine, no session, no MediaCodec), drained to the
    // NATIVE eosDrained verdict, then released/joined; the ring took its
    // final native snapshot and destroyed/joined the native worker. Every
    // fact below is read from the captured sink / ring / folded-native
    // telemetry; a missing snapshot fails the lane closed. Non-claims stay
    // explicit: no seek, no pause/resume, no drift feedback (every posted
    // sample rejected inline as unsupported/stale), no pacing or resampling
    // claim, and the frozen proof boundary text is unchanged.
    fun evaluateRingFrameSource(
        sink: VanguardRealtimeAudioPlaybackSinkTelemetry?,
        ring: AndroidRealtimeAudioPlaybackRingTransportFrameSource.Telemetry?,
        sinkClock: VanguardRealtimePlaybackPresentationClock.Snapshot?,
        expectedFrames: Long,
        ringFrameSourceUsed: Boolean,
        stateMachineSourceUsed: Boolean,
        sinkReadyBeforeTransportStart: Boolean,
        drainAllowedAfterTransportStart: Boolean,
        sinkJoined: Boolean,
        ringClosed: Boolean,
        coordinatorThreadId: Long,
        config: SmokeConfig,
        out: ScenarioOutcome,
    ) {
        val native = ring?.native
        val m = out.metrics
        m["ringSinkTelemetryPresent"] = sink != null
        m["ringTelemetryPresent"] = ring != null
        m["ringNativeTelemetryPresent"] = native != null
        m["ringMaxFramesPerMixConfig"] = config.maxFramesPerMix

        // ── Sink-side facts (production VanguardRealtimeAudioPlaybackSinkBridge) ─
        m["sinkPhase"] = sink?.phase?.name ?: "none"
        m["sinkExitReason"] = sink?.exitReason ?: "none"
        m["sinkThreadId"] = sink?.threadId ?: -1L
        m["sinkThreadIsFrameSourceOwner"] = sink?.threadIsTransportOwner ?: true
        m["sinkFramesReadFromTransport"] = sink?.framesReadFromTransport ?: -1L
        m["sinkFramesWrittenToSink"] = sink?.framesWrittenToSink ?: -1L
        m["sinkDrainCalls"] = sink?.drainCalls ?: -1L
        m["sinkDrainCallsBeforeAllow"] = sink?.drainCallsBeforeAllow ?: -1L
        m["sinkDrainRequestSizeChanges"] = sink?.drainRequestSizeChanges ?: -1L
        m["sinkEmptyDrainCount"] = sink?.emptyDrainCount ?: -1L
        m["sinkProductiveDrainPasses"] = sink?.productiveDrainPasses ?: -1L
        m["sinkEosDrainedObserved"] = sink?.eosDrainedObserved ?: false
        m["sinkPartialWriteCount"] = sink?.partialWriteCount ?: -1L
        m["sinkZeroWriteCount"] = sink?.zeroWriteCount ?: -1L
        m["sinkAudioTrackInitOk"] = sink?.audioTrackInitOk ?: false
        m["sinkGainSetOk"] = sink?.gainSetOk ?: false
        m["sinkGainValue"] = sink?.gainValue ?: 0f
        m["sinkPlayed"] = sink?.played ?: false
        m["sinkAudioTracksCreated"] = sink?.audioTracksCreated ?: -1
        m["sinkReleaseCount"] = sink?.releaseCount ?: -1
        m["sinkReleaseExecutedOnSinkThread"] = sink?.releaseExecutedOnSinkThread ?: false
        m["sinkAudioTrackCallsOffSinkThread"] = sink?.audioTrackCallsOffSinkThread ?: -1L
        m["sinkParkCount"] = sink?.parkCount ?: -1
        m["sinkUnparkCount"] = sink?.unparkCount ?: -1
        m["sinkSeekParkCount"] = sink?.seekParkCount ?: -1
        m["sinkFlushCount"] = sink?.flushCount ?: -1
        m["sinkDeadObjectInjectedCount"] = sink?.deadObjectInjectedCount ?: -1L
        m["sinkDeadObjectObservedCount"] = sink?.deadObjectObservedCount ?: -1L
        m["sinkTimestampPollAttempts"] = sink?.timestampPollAttempts ?: -1L
        m["sinkTimestampMaxPollsInOnePass"] = sink?.timestampMaxPollsInOnePass ?: -1L
        m["sinkTimestampPollsWhileParked"] = sink?.timestampPollsWhileParked ?: -1L
        m["sinkDriftSamplesPosted"] = sink?.driftSamplesPosted ?: -1L
        m["sinkDriftCallbackCount"] = sink?.driftCallbackCount ?: -1L
        m["sinkDriftSamplesRecorded"] = sink?.driftSamplesRecorded ?: -1L
        m["sinkDriftSamplesStaleRejected"] = sink?.driftSamplesStaleRejected ?: -1L
        m["sinkDriftSamplesOtherRejected"] = sink?.driftSamplesOtherRejected ?: -1L
        m["sinkDriftLastRejectReason"] = sink?.driftLastRejectReason ?: ""
        m["sinkDriftNativeSamplesRecorded"] = sink?.driftNativeSamplesRecorded ?: -1L
        m["sinkChecksumHex"] = sink?.checksumHex ?: ""
        m["sinkThreadWallMs"] = sink?.sinkThreadWallMs ?: -1L
        m["sinkLastReplyEosDrained"] = sink?.lastReply?.eosDrained ?: false
        m["sinkJoined"] = sinkJoined

        // ── Sink presentation clock (observation only; never a lane gate here) ─
        m["sinkClockConsistent"] = sinkClock?.consistent ?: false
        m["sinkClockFaulted"] = sinkClock?.faulted ?: true
        m["sinkClockPositionFrames"] = sinkClock?.positionFrames ?: -1L
        m["sinkClockPositionUs"] = sinkClock?.positionUs ?: -1L
        m["sinkClockAnchoredCount"] = sinkClock?.anchoredCount ?: -1L
        m["sinkClockRegressionCount"] = sinkClock?.regressionCount ?: -1L
        m["sinkClockEpochOpen"] = sinkClock?.epochOpen ?: true
        m["sinkClockEpochOpenCount"] = sinkClock?.epochOpenCount ?: -1
        m["sinkClockEpochCloseCount"] = sinkClock?.epochCloseCount ?: -1

        // ── Ring adapter facts (AndroidRealtimeAudioPlaybackRingTransportFrameSource) ─
        m["ringStage"] = ring?.stage?.name ?: "none"
        m["ringFailureReason"] = ring?.failureReason ?: "none"
        m["ringOwnerThreadId"] = ring?.ownerThreadId ?: -1L
        m["ringSinkThreadIdObserved"] = ring?.sinkThreadIdObserved ?: -1L
        m["ringDrainCallsFromSink"] = ring?.drainCallsFromSink ?: -1L
        m["ringDrainCallsOnOwnerThread"] = ring?.drainCallsOnOwnerThread ?: -1L
        m["ringDrainCallsOnOtherThreads"] = ring?.drainCallsOnOtherThreads ?: -1L
        m["ringDrainOverlapRejects"] = ring?.drainOverlapRejects ?: -1L
        m["ringDrainsBeforeStartRejected"] = ring?.drainsBeforeStartRejected ?: -1L
        m["ringDrainsServiced"] = ring?.drainsServiced ?: -1L
        m["ringDrainsAfterCloseRejected"] = ring?.drainsAfterCloseRejected ?: -1L
        m["ringDrainOwnerTimeouts"] = ring?.drainOwnerTimeouts ?: -1L
        m["ringFramesReadBySink"] = ring?.framesReadBySink ?: -1L
        m["ringEmptyReadsServiced"] = ring?.emptyReadsServiced ?: -1L
        m["ringOutputSinkAccountedFrames"] = ring?.outputSinkAccountedFrames ?: -1L
        m["ringOutputSinkCallbacks"] = ring?.outputSinkCallbacks ?: -1L
        m["ringOutputSinkCallbacksOffOwner"] = ring?.outputSinkCallbacksOffOwner ?: -1L
        m["ringTotalOutputFramesRead"] = ring?.totalOutputFramesRead ?: -1L
        m["ringNativeOutputReadChecksumHex"] = ring?.nativeOutputReadChecksumHex ?: ""
        m["ringKotlinReferenceMixChecksumHex"] = ring?.kotlinReferenceMixChecksumHex ?: ""
        m["ringKotlinTrack0ChecksumHex"] = ring?.kotlinTrack0ChecksumHex ?: ""
        m["ringKotlinTrack1ChecksumHex"] = ring?.kotlinTrack1ChecksumHex ?: ""
        m["ringNativeAcceptedChecksumHexTrack0"] = ring?.nativeAcceptedChecksumHexTrack0 ?: ""
        m["ringNativeAcceptedChecksumHexTrack1"] = ring?.nativeAcceptedChecksumHexTrack1 ?: ""
        m["ringFramesIngestedTrack0"] = ring?.framesIngestedTrack0 ?: -1L
        m["ringFramesIngestedTrack1"] = ring?.framesIngestedTrack1 ?: -1L
        m["ringIngestCallsTrack0"] = ring?.ingestCallsTrack0 ?: -1L
        m["ringIngestCallsTrack1"] = ring?.ingestCallsTrack1 ?: -1L
        m["ringIngestRingFullEventsTrack0"] = ring?.ingestRingFullEventsTrack0 ?: -1L
        m["ringIngestRingFullEventsTrack1"] = ring?.ingestRingFullEventsTrack1 ?: -1L
        m["ringPreStartFillFrames"] = ring?.preStartFillFrames ?: -1L
        m["ringTransportCommandsIssued"] = ring?.transportCommandsIssued ?: -1L
        m["ringTransportCommandsFromDrain"] = ring?.transportCommandsFromDrain ?: -1L
        m["ringEosSetWithoutDrain"] = ring?.eosSetWithoutDrain ?: false
        m["ringTotalFramesPushedAtEos"] = ring?.totalFramesPushedAtEos ?: -1L
        m["ringEosDrainedObservedByRing"] = ring?.eosDrainedObservedByRing ?: false
        m["ringEosPollSnapshots"] = ring?.eosPollSnapshots ?: -1L
        m["ringDriftSamplesPosted"] = ring?.driftSamplesPosted ?: -1L
        m["ringDriftSamplesRejectedUnsupported"] = ring?.driftSamplesRejectedUnsupported ?: -1L
        m["ringDriftSamplesRejectedStale"] = ring?.driftSamplesRejectedStale ?: -1L
        m["ringDestroyJoinOk"] = ring?.destroyJoinOk ?: false
        m["ringDestroyIdempotentOk"] = ring?.destroyIdempotentOk ?: false
        m["ringOpenWallMs"] = ring?.openWallMs ?: -1L
        m["ringStartWallMs"] = ring?.startWallMs ?: -1L
        m["ringOwnerLoopWallMs"] = ring?.ownerLoopWallMs ?: -1L
        m["ringOwnerLoopIterations"] = ring?.ownerLoopIterations ?: -1L

        // ── Folded FINAL native snapshot (multi-source realtime-clock worker) ─
        m["nativeCommandsEnqueued"] = native?.commandsEnqueued ?: -1L
        m["nativeCommandsProcessed"] = native?.commandsProcessed ?: -1L
        m["nativeCommandErrors"] = native?.commandErrors ?: -1L
        m["nativeQueueDepth"] = native?.queueDepth ?: -1L
        m["nativeDispatchCount"] = native?.dispatchCount ?: -1L
        m["nativeOkCount"] = native?.okCount ?: -1L
        m["nativeSilenceCount"] = native?.silenceCount ?: -1L
        m["nativeBackpressureCount"] = native?.backpressureCount ?: -1L
        m["nativeSchedulerErrorCount"] = native?.schedulerErrorCount ?: -1L
        m["nativeWorkerDispatchAnomalies"] = native?.workerDispatchAnomalies ?: -1L
        m["nativeNonMonotonicTimeAnomalies"] = native?.nonMonotonicTimeAnomalies ?: -1L
        m["nativeWorkerStarvedWaits"] = native?.workerStarvedWaits ?: -1L
        m["nativeTotalFramesRendered"] = native?.totalFramesRendered ?: -1L
        m["nativeTotalFramesPushed"] = native?.totalFramesPushed ?: -1L
        m["nativeOwnerDispatchCalls"] = native?.ownerDispatchCalls ?: -1L
        m["nativeWorkerThreadDistinct"] = native?.workerThreadDistinct ?: false
        m["nativeNoCallerSuppliedNativeTime"] = native?.noCallerSuppliedNativeTime ?: false
        m["nativeWorkerOwnsMonotonicClock"] = native?.workerOwnsMonotonicClock ?: false
        m["nativeTerminal"] = native?.terminal ?: false
        m["nativeTimelineComplete"] = native?.timelineComplete ?: false
        m["nativeEosTrack0"] = native?.eosTrack0 ?: false
        m["nativeEosTrack1"] = native?.eosTrack1 ?: false
        m["nativeProviderFramesZeroFilledTrack0"] = native?.providerFramesZeroFilledTrack0 ?: -1L
        m["nativeProviderFramesZeroFilledTrack1"] = native?.providerFramesZeroFilledTrack1 ?: -1L
        m["nativeProviderUnderrunEventsTrack0"] = native?.providerUnderrunEventsTrack0 ?: -1L
        m["nativeProviderUnderrunEventsTrack1"] = native?.providerUnderrunEventsTrack1 ?: -1L
        m["nativeWriterSeekRequestsTrack0"] = native?.writerSeekRequestsTrack0 ?: -1L
        m["nativeWriterSeekRequestsTrack1"] = native?.writerSeekRequestsTrack1 ?: -1L
        m["nativeTotalFramesAcceptedTrack0"] = native?.totalFramesAcceptedTrack0 ?: -1L
        m["nativeTotalFramesAcceptedTrack1"] = native?.totalFramesAcceptedTrack1 ?: -1L
        m["nativeOutputAvailableReadFrames"] = native?.outputAvailableReadFrames ?: -1L
        m["nativeTotalOutputFramesRead"] = native?.totalOutputFramesRead ?: -1L
        m["nativePaused"] = native?.paused ?: true
        m["nativePauseCommandsProcessed"] = native?.pauseCommandsProcessed ?: -1L
        m["nativeResumeCommandsProcessed"] = native?.resumeCommandsProcessed ?: -1L
        m["nativeRealtimeElapsedOk"] = native?.realtimeElapsedOk ?: false
        m["nativeRealtimeElapsedMs"] = native?.nativeRealtimeElapsedMs ?: -1L
        m["nativeRealtimeBacklogBoundOk"] = native?.realtimeBacklogBoundOk ?: false
        m["nativeClockDriftSampleCount"] = native?.clockDriftSampleCount ?: -1L
        m["nativeProofBoundaryOk"] = native?.proofBoundaryOk ?: false

        // ── Lane decomposition (each sub-verdict is also reported) ──────────
        val routeOk = ringFrameSourceUsed && !stateMachineSourceUsed &&
            sinkReadyBeforeTransportStart && drainAllowedAfterTransportStart
        val sinkLifecycleOk = sink != null &&
            sink.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS &&
            sink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.EXITED &&
            sink.releaseCount == 1 && sink.releaseExecutedOnSinkThread && sinkJoined &&
            sink.audioTrackInitOk && sink.gainSetOk && sink.gainValue > 0f && sink.played &&
            sink.audioTracksCreated == 1 && sink.audioTrackCallsOffSinkThread == 0L &&
            sink.deadObjectInjectedCount == 0L && sink.deadObjectObservedCount == 0L &&
            sink.drainCallsBeforeAllow == 0L && sink.drainCalls > 0L && sink.eosDrainedObserved
        val threadOk = sink != null && ring != null &&
            sink.threadId > 0L && ring.ownerThreadId > 0L && coordinatorThreadId > 0L &&
            sink.threadId != coordinatorThreadId && sink.threadId != ring.ownerThreadId &&
            ring.ownerThreadId != coordinatorThreadId && !sink.threadIsTransportOwner &&
            ring.sinkThreadIdObserved == sink.threadId
        val ringDrainOk = ring != null &&
            ring.drainCallsFromSink > 0L && ring.drainsServiced > 0L &&
            ring.drainCallsOnOwnerThread == 0L && ring.drainCallsOnOtherThreads == 0L &&
            ring.drainOverlapRejects == 0L && ring.drainsBeforeStartRejected == 0L &&
            ring.drainsAfterCloseRejected == 0L && ring.drainOwnerTimeouts == 0L &&
            ring.transportCommandsIssued == 1L && ring.transportCommandsFromDrain == 0L
        val frameAccountingOk = sink != null && ring != null && expectedFrames > 0L &&
            ring.framesReadBySink == expectedFrames &&
            sink.framesReadFromTransport == expectedFrames &&
            sink.framesWrittenToSink == expectedFrames &&
            ring.totalOutputFramesRead == expectedFrames &&
            ring.outputSinkAccountedFrames == expectedFrames &&
            ring.framesIngestedTrack0 == expectedFrames && ring.framesIngestedTrack1 == expectedFrames
        val eosOk = ring != null &&
            ring.eosSetWithoutDrain && ring.eosDrainedObservedByRing &&
            ring.totalFramesPushedAtEos == expectedFrames
        val checksumOk = sink != null && ring != null &&
            ring.nativeOutputReadChecksumHex.isNotBlank() &&
            ring.nativeOutputReadChecksumHex == ring.kotlinReferenceMixChecksumHex &&
            ring.nativeOutputReadChecksumHex == sink.checksumHex &&
            ring.nativeAcceptedChecksumHexTrack0 == ring.kotlinTrack0ChecksumHex &&
            ring.nativeAcceptedChecksumHexTrack1 == ring.kotlinTrack1ChecksumHex
        val ringCloseOk = ring != null && ringClosed &&
            ring.stage == AndroidRealtimeAudioPlaybackRingTransportFrameSource.Stage.CLOSED &&
            ring.failureReason.isBlank() && ring.destroyJoinOk && ring.destroyIdempotentOk
        // `terminal` is reported, not gated: the worker reaches it only via
        // Stop/error, and this route ends at EOS + destroy (X4..X15 parity).
        val nativeOk = native != null &&
            native.timelineComplete &&
            native.totalFramesPushed == expectedFrames &&
            native.outputAvailableReadFrames == 0L &&
            native.totalOutputFramesRead == expectedFrames &&
            native.totalFramesAcceptedTrack0 == expectedFrames &&
            native.totalFramesAcceptedTrack1 == expectedFrames &&
            native.eosTrack0 && native.eosTrack1 &&
            native.workerThreadDistinct && native.ownerDispatchCalls == 0L &&
            native.commandErrors == 0L && native.schedulerErrorCount == 0L &&
            native.workerDispatchAnomalies == 0L && native.nonMonotonicTimeAnomalies == 0L &&
            native.commandsEnqueued == 1L && native.commandsProcessed == 1L && native.queueDepth == 0L &&
            native.noCallerSuppliedNativeTime && native.workerOwnsMonotonicClock &&
            native.providerFramesZeroFilledTrack0 == 0L && native.providerFramesZeroFilledTrack1 == 0L &&
            native.providerUnderrunEventsTrack0 == 0L && native.providerUnderrunEventsTrack1 == 0L &&
            native.proofBoundaryOk
        // No seek / pause / resume anywhere on the route (sink park/flush
        // surface untouched, native writer seek and pause/resume counters 0).
        val noSeekPauseResumeOk = sink != null && native != null &&
            sink.parkCount == 0 && sink.unparkCount == 0 && sink.seekParkCount == 0 &&
            sink.flushCount == 0 &&
            native.writerSeekRequestsTrack0 == 0L && native.writerSeekRequestsTrack1 == 0L &&
            native.pauseCommandsProcessed == 0L && native.resumeCommandsProcessed == 0L && !native.paused
        // No drift feedback: every sample the sink posted was rejected inline
        // by the ring (unsupported or stale), nothing was recorded on either
        // side, and the sink's drain shape / clock polling never adapted.
        val noFeedbackOk = sink != null && ring != null &&
            ring.driftSamplesPosted == ring.driftSamplesRejectedUnsupported + ring.driftSamplesRejectedStale &&
            sink.driftSamplesPosted == ring.driftSamplesPosted &&
            sink.driftSamplesRecorded == 0L && sink.driftNativeSamplesRecorded == 0L &&
            sink.drainRequestSizeChanges == 0L && sink.timestampMaxPollsInOnePass <= 1L &&
            sink.timestampPollsWhileParked == 0L
        val proofBoundaryOk = PROOF_BOUNDARY_TOKENS.all { PROOF_BOUNDARY.contains(it) }

        m["ringLaneRouteOk"] = routeOk
        m["ringLaneSinkLifecycleOk"] = sinkLifecycleOk
        m["ringLaneThreadOk"] = threadOk
        m["ringLaneRingDrainOk"] = ringDrainOk
        m["ringLaneFrameAccountingOk"] = frameAccountingOk
        m["ringLaneEosOk"] = eosOk
        m["ringLaneChecksumOk"] = checksumOk
        m["ringLaneRingCloseOk"] = ringCloseOk
        m["ringLaneNativeOk"] = nativeOk
        m["ringLaneNoSeekPauseResumeOk"] = noSeekPauseResumeOk
        m["ringLaneNoFeedbackOk"] = noFeedbackOk
        m["ringLaneProofBoundaryOk"] = proofBoundaryOk
        m["ringNonClaims"] = "no_seek_no_pause_resume_no_drift_feedback_no_pacing_claim_no_resampling_claim_" +
            "synthetic_pcm_no_mediacodec_no_session_no_position_authority_change"

        out.lanes[LANE_RING_FRAME_SOURCE] = out.failureReason.isBlank() &&
            routeOk && sinkLifecycleOk && threadOk && ringDrainOk && frameAccountingOk &&
            eosOk && checksumOk && ringCloseOk && nativeOk && noSeekPauseResumeOk &&
            noFeedbackOk && proofBoundaryOk
    }

    // A lane holds only when every scenario that evaluated it passed and at
    // least one scenario evaluated it.
    fun aggregateLanes(outcomes: List<ScenarioOutcome>): LinkedHashMap<String, Boolean> {
        val lanes = linkedMapOf<String, Boolean>()
        for (name in REQUIRED_LANES) {
            val evaluated = outcomes.filter { it.lanes.containsKey(name) }
            lanes[name] = evaluated.isNotEmpty() && evaluated.all { it.lanes[name] == true }
        }
        return lanes
    }
}
