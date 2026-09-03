package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioTrack
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSinkBridge
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSinkTelemetry
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackDecoderFeed
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackPresentationClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.DEAD_OBJECT_PUBLICATION_LAG_BUDGET_MS
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_AUDIO_TRACK_RELEASED_ONCE
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_BOUNDED_PAUSE_RESUME
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CHECKSUM_IDENTITY
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CLOCK_ANCHORED
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CLOCK_EPOCH_BALANCED
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CLOCK_MONOTONIC
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_CLOCK_PAUSE_FROZEN
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_DEAD_OBJECT_CLOCK_EPOCH
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_DEAD_OBJECT_RECOVERY
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_DEAD_OBJECT_REMAINDER
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_DECODER_SEEK_REANCHOR
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_FORMAT_PROBE
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_NONZERO_GAIN
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_NO_FEEDBACK
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_PLAYTHROUGH_ACCOUNTING
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_POST_SEEK_DRAIN
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_PRE_ROLL
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_PROOF_BOUNDARY
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

// Per-invocation Y8a/Y8b/Y9 smoke arguments, shared by scenario sequencing
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

// Pure lane evaluation, A-prime dead-object base-step decomposition, and lane
// aggregation for the Y8a/Y8b production smoke coordinator. Every function
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
        out.lanes[LANE_THREAD_OWNERSHIP] = final.decoderThreadId > 0L && sink.threadId > 0L && final.decoderThreadId != sink.threadId &&
            final.decoderThreadId != coordinatorThreadId && sink.threadId != coordinatorThreadId &&
            !final.decoderThreadIsTransportOwner && !sink.threadIsTransportOwner &&
            final.decoderIngestCallbacksOnOwner > 0L && final.decoderIngestCallbacksOffOwner == 0L &&
            final.listenerCallbacksOnOwner > 0L && final.listenerCallbacksOffOwner == 0L &&
            sink.audioTrackCallsOffSinkThread == 0L && clock.offWriterThreadCalls == 0L && clock.writerThreadId == sink.threadId
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
