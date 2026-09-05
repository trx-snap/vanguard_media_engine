package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioFormat
import android.media.AudioTrack
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSinkBridge
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSinkTelemetry
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackPresentationClock
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_REAL_RING_PAUSE_ACK
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_REAL_RING_PAUSE_HOLD_FROZEN
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_REAL_RING_POST_RESUME_CHECKSUM
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_REAL_RING_RESUME_ACK
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.PROOF_BOUNDARY
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.PROOF_BOUNDARY_TOKENS

// ── AndroidRealtimeAudioPlaybackRealDecoderRingPauseResumeLaneEvaluator (Y19) ─
//
// Pure lane evaluation for Scenario 15
// ([AndroidRealtimeAudioPlaybackRealDecoderRingPauseResumeScenario]): reads
// the already-captured sink / ring / native / clock snapshots plus the
// coordinator-thread ordering facts and sets EXACTLY the four Y19 lanes on
// the outcome. It owns no thread, session, AudioTrack or lifecycle decision.
//
// Every Y18c route invariant is re-asserted here with the counts a single
// pause/resume cycle legitimately changes: three native commands (Start,
// Pause, Resume), one sink park + one unpark, one native pause + one native
// resume processed, and the sink's park/flush surface otherwise untouched
// (no seek park, no flush, no dead object). Exact frame / checksum identity
// to EOS, codec + extractor released once, native destroy idempotent, sink
// AudioTrack released once and the no-feedback rule are required as in
// Y18c; the Y18c lane itself is never touched by this evaluator.
object AndroidRealtimeAudioPlaybackRealDecoderRingPauseResumeLaneEvaluator {

    fun evaluate(
        sink: VanguardRealtimeAudioPlaybackSinkTelemetry?,
        ring: AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Telemetry?,
        sinkClock: VanguardRealtimePlaybackPresentationClock.Snapshot?,
        geometry: AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Geometry?,
        facts: AndroidRealtimeAudioPlaybackRealDecoderRingPauseResumeScenario.Facts,
        config: SmokeConfig,
        out: ScenarioOutcome,
    ) {
        val f = facts
        val pr = ring?.pauseResume
        val native = ring?.native
        val decoder = ring?.decoder
        val g = geometry ?: ring?.geometry
        val expectedFrames = g?.expectedFrames ?: -1L
        val m = out.metrics
        val holdNs = f.pauseHoldMs * 1_000_000L
        m["y19SinkTelemetryPresent"] = sink != null
        m["y19RingTelemetryPresent"] = ring != null
        m["y19NativeTelemetryPresent"] = native != null
        m["y19GeometryPresent"] = g != null
        m["y19CoordinatorThreadId"] = f.coordinatorThreadId

        // ── Frozen geometry ────────────────────────────────────────────────
        m["realRingSourceMime"] = g?.sourceMime ?: ""
        m["realRingSourceDurationUs"] = g?.sourceDurationUs ?: -1L
        m["realRingDeclaredWindowUs"] = g?.declaredWindowUs ?: -1L
        m["realRingSampleRate"] = g?.sampleRate ?: -1
        m["realRingChannelCount"] = g?.channelCount ?: -1
        m["realRingPcmEncoding"] = g?.pcmEncoding ?: -1
        m["realRingExpectedFrames"] = expectedFrames
        m["realRingPadBudgetFrames"] = g?.padBudgetFrames ?: -1L

        // ── Ordering facts (coordinator thread) ────────────────────────────
        m["y19RealDecoderSourceUsed"] = f.realDecoderSourceUsed
        m["y19StateMachineSourceUsed"] = f.stateMachineSourceUsed
        m["y19SinkReadyBeforeTransportStart"] = f.sinkReadyBeforeTransportStart
        m["y19DrainAllowedAfterTransportStart"] = f.drainAllowedAfterTransportStart
        m["y19FirstPlayObserved"] = f.firstPlayObserved
        m["y19SinkFramesReadAtFirstPlay"] = f.sinkFramesReadAtFirstPlay
        m["y19IngestCompleteAtFirstPlay"] = f.ingestCompleteAtFirstPlay
        m["y19QuiesceAckOk"] = f.quiesceAckOk
        m["y19RingQuiescedObserved"] = f.ringQuiescedObserved
        m["y19IngestCompleteAtQuiesce"] = f.ingestCompleteAtQuiesce
        m["y19SinkFramesReadAtQuiesce"] = f.sinkFramesReadAtQuiesce
        m["y19SinkParkRequested"] = f.sinkParkRequested
        m["y19SinkParked"] = f.sinkParked
        m["y19SinkPhaseAtRingPause"] = f.sinkPhaseAtRingPause
        m["y19SinkFramesReadAtPark"] = f.sinkFramesReadAtPark
        m["y19RingPauseAckOk"] = f.ringPauseAckOk
        m["y19RingPausedObserved"] = f.ringPausedObserved
        m["y19SinkParkedBeforeRingPause"] = f.sinkParkedBeforeRingPause
        m["y19HoldSleptMs"] = f.holdSleptMs
        m["y19HoldAssertAckOk"] = f.holdAssertAckOk
        m["y19RingPausedDuringHold"] = f.ringPausedDuringHold
        m["y19SinkPhaseAfterHold"] = f.sinkPhaseAfterHold
        m["y19SinkFramesReadAfterHold"] = f.sinkFramesReadAfterHold
        m["y19RingResumeAckOk"] = f.ringResumeAckOk
        m["y19RingPausedAfterResume"] = f.ringPausedAfterResume
        m["y19SinkPhaseAtRingResume"] = f.sinkPhaseAtRingResume
        m["y19SinkUnparked"] = f.sinkUnparked
        m["y19SinkRunning"] = f.sinkRunning
        m["y19SinkUnparkAfterRingResume"] = f.sinkUnparkAfterRingResume
        m["y19SinkFramesReadAtUnpark"] = f.sinkFramesReadAtUnpark
        m["y19SinkExited"] = f.sinkExited
        m["y19SinkJoined"] = f.sinkJoined
        m["y19RingClosed"] = f.ringClosed
        m["y19RingOpenWallMs"] = f.ringOpenWallMs
        m["y19SinkReadyWallMs"] = f.sinkReadyWallMs
        m["y19TransportStartedWallMs"] = f.transportStartedWallMs
        m["y19DrainAllowedWallMs"] = f.drainAllowedWallMs
        m["y19FirstPlayWallMs"] = f.firstPlayWallMs
        m["y19QuiesceAckWallMs"] = f.quiesceAckWallMs
        m["y19SinkParkedWallMs"] = f.sinkParkedWallMs
        m["y19RingPauseRequestedWallMs"] = f.ringPauseRequestedWallMs
        m["y19RingPauseAckWallMs"] = f.ringPauseAckWallMs
        m["y19HoldAssertWallMs"] = f.holdAssertWallMs
        m["y19RingResumeAckWallMs"] = f.ringResumeAckWallMs
        m["y19SinkUnparkRequestedWallMs"] = f.sinkUnparkRequestedWallMs
        m["y19SinkRunningWallMs"] = f.sinkRunningWallMs
        m["y19SinkExitedWallMs"] = f.sinkExitedWallMs

        // ── Sink facts (production VanguardRealtimeAudioPlaybackSinkBridge) ─
        m["sinkPhase"] = sink?.phase?.name ?: "none"
        m["sinkExitReason"] = sink?.exitReason ?: "none"
        m["sinkThreadId"] = sink?.threadId ?: -1L
        m["sinkFramesReadFromTransport"] = sink?.framesReadFromTransport ?: -1L
        m["sinkFramesWrittenToSink"] = sink?.framesWrittenToSink ?: -1L
        m["sinkDrainCalls"] = sink?.drainCalls ?: -1L
        m["sinkDrainCallsBeforeAllow"] = sink?.drainCallsBeforeAllow ?: -1L
        m["sinkDrainRequestSizeChanges"] = sink?.drainRequestSizeChanges ?: -1L
        m["sinkEmptyDrainCount"] = sink?.emptyDrainCount ?: -1L
        m["sinkProductiveDrainPasses"] = sink?.productiveDrainPasses ?: -1L
        m["sinkEosDrainedObserved"] = sink?.eosDrainedObserved ?: false
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
        m["sinkParkExecutedOnSinkThread"] = sink?.parkExecutedOnSinkThread ?: false
        m["sinkUnparkExecutedOnSinkThread"] = sink?.unparkExecutedOnSinkThread ?: false
        m["sinkPlayStateAtPark"] = sink?.playStateAtPark ?: -1
        m["sinkPlayStateAfterUnpark"] = sink?.playStateAfterUnpark ?: -1
        m["sinkParkedPlayStateViolations"] = sink?.parkedPlayStateViolations ?: -1L
        m["sinkParkAckLatencyMs"] = sink?.parkAckLatencyMs ?: -1L
        m["sinkParkedHoldMs"] = sink?.parkedHoldMs ?: -1L
        m["sinkParkHoldCapMs"] = sink?.parkHoldCapMs ?: -1L
        m["sinkPositionAtPark"] = sink?.positionAtPark ?: -1L
        m["sinkEpochClosedAtPark"] = sink?.epochClosedAtPark ?: -1
        m["sinkEpochOpenedAtUnpark"] = sink?.epochOpenedAtUnpark ?: -1
        m["sinkEpochRawOriginAtUnpark"] = sink?.epochRawOriginAtUnpark ?: -1L
        m["sinkDeadObjectInjectedCount"] = sink?.deadObjectInjectedCount ?: -1L
        m["sinkDeadObjectObservedCount"] = sink?.deadObjectObservedCount ?: -1L
        m["sinkTimestampMaxPollsInOnePass"] = sink?.timestampMaxPollsInOnePass ?: -1L
        m["sinkTimestampPollsWhileParked"] = sink?.timestampPollsWhileParked ?: -1L
        m["sinkDriftSamplesPosted"] = sink?.driftSamplesPosted ?: -1L
        m["sinkDriftSamplesRecorded"] = sink?.driftSamplesRecorded ?: -1L
        m["sinkDriftNativeSamplesRecorded"] = sink?.driftNativeSamplesRecorded ?: -1L
        m["sinkChecksumHex"] = sink?.checksumHex ?: ""
        m["sinkThreadWallMs"] = sink?.sinkThreadWallMs ?: -1L

        // ── Sink presentation clock (observation only) ─────────────────────
        m["sinkClockConsistent"] = sinkClock?.consistent ?: false
        m["sinkClockFaulted"] = sinkClock?.faulted ?: true
        m["sinkClockPositionFrames"] = sinkClock?.positionFrames ?: -1L
        m["sinkClockAnchoredCount"] = sinkClock?.anchoredCount ?: -1L
        m["sinkClockRegressionCount"] = sinkClock?.regressionCount ?: -1L
        m["sinkClockEpochOpenCount"] = sinkClock?.epochOpenCount ?: -1
        m["sinkClockEpochCloseCount"] = sinkClock?.epochCloseCount ?: -1

        // ── Ring adapter facts ─────────────────────────────────────────────
        m["realRingStage"] = ring?.stage?.name ?: "none"
        m["realRingStageTrace"] = ring?.stageTrace ?: ""
        m["realRingFailureReason"] = ring?.failureReason ?: "none"
        m["realRingOwnerThreadId"] = ring?.ownerThreadId ?: -1L
        m["realRingSinkThreadIdObserved"] = ring?.sinkThreadIdObserved ?: -1L
        m["realRingDrainCallsFromSink"] = ring?.drainCallsFromSink ?: -1L
        m["realRingDrainCallsOnOwnerThread"] = ring?.drainCallsOnOwnerThread ?: -1L
        m["realRingDrainCallsOnOtherThreads"] = ring?.drainCallsOnOtherThreads ?: -1L
        m["realRingDrainOverlapRejects"] = ring?.drainOverlapRejects ?: -1L
        m["realRingDrainsBeforeStartRejected"] = ring?.drainsBeforeStartRejected ?: -1L
        m["realRingDrainsServiced"] = ring?.drainsServiced ?: -1L
        m["realRingDrainsServicedFromMakeRoom"] = ring?.drainsServicedFromMakeRoom ?: -1L
        m["realRingDrainsAfterCloseRejected"] = ring?.drainsAfterCloseRejected ?: -1L
        m["realRingDrainWaitTimeouts"] = ring?.drainWaitTimeouts ?: -1L
        m["realRingMaxDrainServiceLatencyMs"] = ring?.maxDrainServiceLatencyMs ?: -1L
        m["realRingDrainLatencyBoundViolations"] = ring?.drainLatencyBoundViolations ?: -1L
        m["realRingFramesReadBySink"] = ring?.framesReadBySink ?: -1L
        m["realRingEmptyReadsServiced"] = ring?.emptyReadsServiced ?: -1L
        m["realRingOutputSinkAccountedFrames"] = ring?.outputSinkAccountedFrames ?: -1L
        m["realRingOutputSinkCallbacksOffOwner"] = ring?.outputSinkCallbacksOffOwner ?: -1L
        m["realRingPrivateOutputDrains"] = ring?.privateOutputDrains ?: -1L
        m["realRingTotalOutputFramesRead"] = ring?.totalOutputFramesRead ?: -1L
        m["realRingNativeOutputReadChecksumHex"] = ring?.nativeOutputReadChecksumHex ?: ""
        m["realRingKotlinReferenceMixChecksumHex"] = ring?.kotlinReferenceMixChecksumHex ?: ""
        m["realRingKotlinTrack0ChecksumHex"] = ring?.kotlinTrack0ChecksumHex ?: ""
        m["realRingKotlinTrack1ChecksumHex"] = ring?.kotlinTrack1ChecksumHex ?: ""
        m["realRingNativeAcceptedChecksumHexTrack0"] = ring?.nativeAcceptedChecksumHexTrack0 ?: ""
        m["realRingNativeAcceptedChecksumHexTrack1"] = ring?.nativeAcceptedChecksumHexTrack1 ?: ""
        m["realRingPumpFramesAccepted"] = ring?.pumpFramesAccepted ?: -1L
        m["realRingFramesAcceptedTrack0"] = ring?.framesAcceptedTrack0 ?: -1L
        m["realRingFramesAcceptedTrack1"] = ring?.framesAcceptedTrack1 ?: -1L
        m["realRingTrack1NonZeroSampleCount"] = ring?.track1NonZeroSampleCount ?: -1L
        m["realRingChecksumChainSelfOk"] = ring?.checksumChainSelfOk ?: false
        m["realRingPreStartFillFrames"] = ring?.preStartFillFrames ?: -1L
        m["realRingTransportCommandsIssued"] = ring?.transportCommandsIssued ?: -1L
        m["realRingTransportCommandsFromDrain"] = ring?.transportCommandsFromDrain ?: -1L
        m["realRingEosSetWithoutDrain"] = ring?.eosSetWithoutDrain ?: false
        m["realRingTotalFramesPushedAtEos"] = ring?.totalFramesPushedAtEos ?: -1L
        m["realRingEosDrainedObservedByRing"] = ring?.eosDrainedObservedByRing ?: false
        m["realRingDriftSamplesPosted"] = ring?.driftSamplesPosted ?: -1L
        m["realRingDriftSamplesRejectedUnsupported"] = ring?.driftSamplesRejectedUnsupported ?: -1L
        m["realRingDriftSamplesRejectedStale"] = ring?.driftSamplesRejectedStale ?: -1L
        m["realRingDestroyJoinOk"] = ring?.destroyJoinOk ?: false
        m["realRingDestroyIdempotentOk"] = ring?.destroyIdempotentOk ?: false
        m["realRingMakeRoomCallbacks"] = ring?.makeRoomCallbacks ?: -1L
        m["realRingOwnerLoopIterations"] = ring?.ownerLoopIterations ?: -1L

        // ── Decoder facts ──────────────────────────────────────────────────
        m["decoderFormatResolved"] = decoder?.formatResolved ?: false
        m["decoderMidStreamFormatChanges"] = decoder?.midStreamFormatChanges ?: -1L
        m["decoderDecodeSteps"] = decoder?.decodeSteps ?: -1L
        m["decoderInputEosQueued"] = decoder?.inputEosQueued ?: false
        m["decoderOutputEosReached"] = decoder?.outputEosReached ?: false
        m["decoderChunks"] = decoder?.decoderChunks ?: -1L
        m["decoderFramesDecoded"] = decoder?.framesDecoded ?: -1L
        m["decoderFramesIngestedReal"] = decoder?.framesIngestedReal ?: -1L
        m["decoderEosPadFrames"] = decoder?.eosPadFrames ?: -1L
        m["decoderEosTruncatedFrames"] = decoder?.eosTruncatedFrames ?: -1L
        m["decoderIngestComplete"] = decoder?.ingestComplete ?: false
        m["decoderCodecCallsOffOwnerThread"] = decoder?.codecCallsOffOwnerThread ?: -1L
        m["decoderMediaReleaseCount"] = decoder?.mediaReleaseCount ?: -1
        m["decoderCodecReleaseCount"] = decoder?.codecReleaseCount ?: -1
        m["decoderExtractorReleaseCount"] = decoder?.extractorReleaseCount ?: -1
        m["decoderMediaReleaseClean"] = decoder?.mediaReleaseClean ?: false
        m["decoderMediaReleasedAtDecoderEos"] = decoder?.mediaReleasedAtDecoderEos ?: false

        // ── Folded FINAL native snapshot ───────────────────────────────────
        m["nativeCommandsEnqueued"] = native?.commandsEnqueued ?: -1L
        m["nativeCommandsProcessed"] = native?.commandsProcessed ?: -1L
        m["nativeCommandErrors"] = native?.commandErrors ?: -1L
        m["nativeQueueDepth"] = native?.queueDepth ?: -1L
        m["nativeDispatchCount"] = native?.dispatchCount ?: -1L
        m["nativeTotalFramesPushed"] = native?.totalFramesPushed ?: -1L
        m["nativeOwnerDispatchCalls"] = native?.ownerDispatchCalls ?: -1L
        m["nativeWorkerThreadDistinct"] = native?.workerThreadDistinct ?: false
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
        m["nativeSchedulerErrorCount"] = native?.schedulerErrorCount ?: -1L
        m["nativeWorkerDispatchAnomalies"] = native?.workerDispatchAnomalies ?: -1L
        m["nativeNonMonotonicTimeAnomalies"] = native?.nonMonotonicTimeAnomalies ?: -1L
        m["nativeProofBoundaryOk"] = native?.proofBoundaryOk ?: false

        // ── Ring pause/resume cycle facts (owner thread) ───────────────────
        m["realRingQuiesceRequests"] = pr?.quiesceRequests ?: -1L
        m["realRingPauseRequests"] = pr?.pauseRequests ?: -1L
        m["realRingHoldAssertRequests"] = pr?.holdAssertRequests ?: -1L
        m["realRingResumeRequests"] = pr?.resumeRequests ?: -1L
        m["realRingControlRequestsOnOwnerThread"] = pr?.controlRequestsOnOwnerThread ?: -1L
        m["realRingControlOverlapRejects"] = pr?.controlOverlapRejects ?: -1L
        m["realRingControlWaitTimeouts"] = pr?.controlWaitTimeouts ?: -1L
        m["realRingLastControlTimeoutKind"] = pr?.lastControlTimeoutKind ?: ""
        m["realRingLastControlRejectReason"] = pr?.lastControlRejectReason ?: ""
        m["realRingQuiesceAckOk"] = pr?.quiesceAckOk ?: false
        m["realRingQuiesceExecutedOnOwnerThread"] = pr?.quiesceExecutedOnOwnerThread ?: false
        m["realRingQuiesceWallMs"] = pr?.quiesceWallMs ?: -1L
        m["realRingFeedStepsWhileQuiesced"] = pr?.feedStepsWhileQuiesced ?: -1L
        m["realRingPauseAckOk"] = pr?.pauseAckOk ?: false
        m["realRingPauseExecutedOnOwnerThread"] = pr?.pauseExecutedOnOwnerThread ?: false
        m["realRingPauseQuiescedFirst"] = pr?.pauseQuiescedFirst ?: false
        m["realRingPauseCleanBoundaryOk"] = pr?.pauseCleanBoundaryOk ?: false
        m["realRingPausePendingSliceFramesAtRequest"] = pr?.pausePendingSliceFramesAtRequest ?: -1
        m["realRingPausePumpPendingChunkAtRequest"] = pr?.pausePumpPendingChunkAtRequest ?: true
        m["realRingPauseCodecOutputHeldAtRequest"] = pr?.pauseCodecOutputHeldAtRequest ?: true
        m["realRingPauseIngestCompleteAtRequest"] = pr?.pauseIngestCompleteAtRequest ?: true
        m["realRingNativePauseProofOk"] = pr?.nativePauseProofOk ?: false
        m["realRingPauseCommandSeq"] = pr?.pauseCommandSeq ?: -1L
        m["realRingPauseWallMs"] = pr?.pauseWallMs ?: -1L
        m["realRingDispatchCountAtPause"] = pr?.dispatchCountAtPause ?: -1L
        m["realRingTotalFramesPushedAtPause"] = pr?.totalFramesPushedAtPause ?: -1L
        m["realRingNextDispatchFrameAtPause"] = pr?.nextDispatchFrameAtPause ?: -1L
        m["realRingFramesPendingAtPause"] = pr?.framesPendingAtPause ?: -1L
        m["realRingPausedWaitsAtPause"] = pr?.pausedWaitsAtPause ?: -1L
        m["realRingFramesReadBySinkAtPause"] = pr?.framesReadBySinkAtPause ?: -1L
        m["realRingDrainsServicedAtPause"] = pr?.drainsServicedAtPause ?: -1L
        m["realRingPumpFramesAcceptedAtPause"] = pr?.pumpFramesAcceptedAtPause ?: -1L
        m["realRingFramesAcceptedTrack0AtPause"] = pr?.framesAcceptedTrack0AtPause ?: -1L
        m["realRingFramesAcceptedTrack1AtPause"] = pr?.framesAcceptedTrack1AtPause ?: -1L
        m["realRingFramesDecodedAtPause"] = pr?.framesDecodedAtPause ?: -1L
        m["realRingStageBeforePause"] = pr?.stageBeforePause ?: "none"
        m["realRingHoldAssertAckOk"] = pr?.holdAssertAckOk ?: false
        m["realRingHoldAssertExecutedOnOwnerThread"] = pr?.holdAssertExecutedOnOwnerThread ?: false
        m["realRingNativeHoldFrozenProofOk"] = pr?.nativeHoldFrozenProofOk ?: false
        m["realRingHoldAssertObservedNs"] = pr?.holdAssertObservedNs ?: -1L
        m["realRingDispatchCountAfterHold"] = pr?.dispatchCountAfterHold ?: -1L
        m["realRingTotalFramesPushedAfterHold"] = pr?.totalFramesPushedAfterHold ?: -1L
        m["realRingPausedWaitsAfterHold"] = pr?.pausedWaitsAfterHold ?: -1L
        m["realRingFramesReadBySinkAfterHold"] = pr?.framesReadBySinkAfterHold ?: -1L
        m["realRingDrainsServicedAfterHold"] = pr?.drainsServicedAfterHold ?: -1L
        m["realRingPumpFramesAcceptedAfterHold"] = pr?.pumpFramesAcceptedAfterHold ?: -1L
        m["realRingOwnerLoopIterationsWhilePaused"] = pr?.ownerLoopIterationsWhilePaused ?: -1L
        m["realRingFeedStepsWhilePaused"] = pr?.feedStepsWhilePaused ?: -1L
        m["realRingEosPollsWhilePaused"] = pr?.eosPollsWhilePaused ?: -1L
        m["realRingDecodeStepsWhilePaused"] = pr?.decodeStepsWhilePaused ?: -1L
        m["realRingMakeRoomCallbacksWhilePaused"] = pr?.makeRoomCallbacksWhilePaused ?: -1L
        m["realRingPausedDrainRejectsSinkThread"] = pr?.pausedDrainRejectsSinkThread ?: -1L
        m["realRingPausedDrainRejectsOwnerThread"] = pr?.pausedDrainRejectsOwnerThread ?: -1L
        m["realRingResumeAckOk"] = pr?.resumeAckOk ?: false
        m["realRingResumeExecutedOnOwnerThread"] = pr?.resumeExecutedOnOwnerThread ?: false
        m["realRingNativeResumeProofOk"] = pr?.nativeResumeProofOk ?: false
        m["realRingResumeCommandSeq"] = pr?.resumeCommandSeq ?: -1L
        m["realRingResumeWallMs"] = pr?.resumeWallMs ?: -1L
        m["realRingDispatchCountAtResume"] = pr?.dispatchCountAtResume ?: -1L
        m["realRingTotalFramesPushedAtResume"] = pr?.totalFramesPushedAtResume ?: -1L
        m["realRingNativeLastPausedIntervalNs"] = pr?.nativeLastPausedIntervalNs ?: -1L
        m["realRingNativeTotalPausedNs"] = pr?.nativeTotalPausedNs ?: -1L
        m["realRingPauseHoldObservedNs"] = pr?.pauseHoldObservedNs ?: -1L
        m["realRingPauseHoldObservedMs"] = pr?.pauseHoldObservedMs ?: -1L
        m["realRingFramesReadBySinkAtResume"] = pr?.framesReadBySinkAtResume ?: -1L
        m["realRingPumpFramesAcceptedAtResume"] = pr?.pumpFramesAcceptedAtResume ?: -1L
        m["realRingStageAfterResume"] = pr?.stageAfterResume ?: "none"
        m["realRingPostResumeFramesReadBySink"] =
            if (ring != null && pr != null && pr.framesReadBySinkAtResume >= 0L) ring.framesReadBySink - pr.framesReadBySinkAtResume else -1L

        // ── Y18c route invariants, re-asserted with the one-cycle counts ───
        val routeOk = f.realDecoderSourceUsed && !f.stateMachineSourceUsed &&
            f.sinkReadyBeforeTransportStart && f.drainAllowedAfterTransportStart
        val formatOk = g != null && expectedFrames > 0L &&
            g.pcmEncoding == AudioFormat.ENCODING_PCM_16BIT &&
            (g.channelCount == 1 || g.channelCount == 2) &&
            g.sampleRate >= VanguardRealtimePlaybackNativeSession.MIN_SAMPLE_RATE &&
            g.sampleRate <= VanguardRealtimePlaybackNativeSession.MAX_SAMPLE_RATE &&
            g.maxFramesPerMix == config.maxFramesPerMix &&
            g.sourceDurationUs > 0L &&
            g.declaredWindowUs == minOf(g.sourceDurationUs, (config.maxDurationSec * 1_000_000.0).toLong()) &&
            expectedFrames == (g.declaredWindowUs * g.sampleRate / 1_000_000L) / g.maxFramesPerMix * g.maxFramesPerMix &&
            expectedFrames % g.maxFramesPerMix == 0L &&
            g.padBudgetFrames in 1L..g.sampleRate.toLong() &&
            (decoder?.formatResolved ?: false) && decoder?.midStreamFormatChanges == 0L
        val sinkLifecycleOk = sink != null &&
            sink.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS &&
            sink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.EXITED &&
            sink.releaseCount == 1 && sink.releaseExecutedOnSinkThread && f.sinkJoined &&
            sink.audioTrackInitOk && sink.gainSetOk && sink.gainValue > 0f && sink.played &&
            sink.audioTracksCreated == 1 && sink.audioTrackCallsOffSinkThread == 0L &&
            sink.deadObjectInjectedCount == 0L && sink.deadObjectObservedCount == 0L &&
            sink.drainCallsBeforeAllow == 0L && sink.drainCalls > 0L && sink.eosDrainedObserved
        val threadOk = sink != null && ring != null && decoder != null &&
            sink.threadId > 0L && ring.ownerThreadId > 0L && f.coordinatorThreadId > 0L &&
            sink.threadId != f.coordinatorThreadId && sink.threadId != ring.ownerThreadId &&
            ring.ownerThreadId != f.coordinatorThreadId && !sink.threadIsTransportOwner &&
            ring.sinkThreadIdObserved == sink.threadId &&
            decoder.codecCallsOffOwnerThread == 0L && ring.outputSinkCallbacksOffOwner == 0L
        // Three owner-thread native commands on this route: Start, Pause, Resume.
        val ringDrainOk = ring != null &&
            ring.drainCallsFromSink > 0L && ring.drainsServiced > 0L &&
            ring.drainCallsOnOwnerThread == 0L && ring.drainCallsOnOtherThreads == 0L &&
            ring.drainOverlapRejects == 0L && ring.drainsBeforeStartRejected == 0L &&
            ring.drainsAfterCloseRejected == 0L && ring.privateOutputDrains == 0L &&
            ring.outputSinkAccountedFrames == ring.framesReadBySink &&
            ring.transportCommandsIssued == 3L && ring.transportCommandsFromDrain == 0L
        val drainLatencyOk = ring != null &&
            ring.drainWaitBoundMs > 0L && ring.drainWaitBoundMs < f.deadlineBudgetMs &&
            ring.drainWaitTimeouts == 0L && ring.drainLatencyBoundViolations == 0L &&
            ring.maxDrainServiceLatencyMs in 0L..ring.drainWaitBoundMs
        val frameAccountingOk = sink != null && ring != null && decoder != null && expectedFrames > 0L &&
            ring.framesReadBySink == expectedFrames &&
            sink.framesReadFromTransport == expectedFrames &&
            sink.framesWrittenToSink == expectedFrames &&
            ring.totalOutputFramesRead == expectedFrames &&
            ring.outputSinkAccountedFrames == expectedFrames &&
            ring.pumpFramesAccepted == expectedFrames &&
            ring.framesAcceptedTrack0 == expectedFrames && ring.framesAcceptedTrack1 == expectedFrames &&
            decoder.ingestComplete &&
            decoder.framesIngestedReal + decoder.eosPadFrames == expectedFrames &&
            decoder.framesDecoded == decoder.framesIngestedReal + decoder.eosTruncatedFrames &&
            decoder.eosPadFrames in 0L..decoder.padBudgetFrames &&
            ring.preStartFillFrames >= minOf(
                expectedFrames,
                AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.DEFAULT_OUTPUT_RING_CAPACITY_FRAMES.toLong(),
            )
        val decoderEosOk = decoder != null &&
            decoder.inputEosQueued && decoder.outputEosReached && decoder.decoderChunks > 0L &&
            decoder.mediaReleaseCount == 1 && decoder.codecReleaseCount == 1 &&
            decoder.extractorReleaseCount == 1 && decoder.mediaReleaseClean && decoder.mediaReleasedAtDecoderEos
        val lockstepOk = ring != null && expectedFrames > 0L &&
            ring.framesAcceptedTrack0 == ring.framesAcceptedTrack1 &&
            ring.framesAcceptedTrack0 == ring.pumpFramesAccepted &&
            ring.track1NonZeroSampleCount > 0L
        val eosOk = sink != null && ring != null &&
            ring.eosSetWithoutDrain && ring.eosDrainedObservedByRing && sink.eosDrainedObserved &&
            ring.totalFramesPushedAtEos == expectedFrames
        val checksumOk = sink != null && ring != null &&
            ring.nativeOutputReadChecksumHex.isNotBlank() &&
            ring.nativeAcceptedChecksumHexTrack0.isNotBlank() && ring.nativeAcceptedChecksumHexTrack1.isNotBlank() &&
            ring.nativeAcceptedChecksumHexTrack0 == ring.kotlinTrack0ChecksumHex &&
            ring.nativeAcceptedChecksumHexTrack1 == ring.kotlinTrack1ChecksumHex &&
            ring.nativeOutputReadChecksumHex == ring.kotlinReferenceMixChecksumHex &&
            ring.nativeOutputReadChecksumHex == sink.checksumHex &&
            ring.kotlinReferenceMixChecksumHex != ring.kotlinTrack0ChecksumHex &&
            ring.kotlinReferenceMixChecksumHex != ring.kotlinTrack1ChecksumHex &&
            ring.checksumChainSelfOk
        val ringCloseOk = ring != null && f.ringClosed &&
            ring.stage == AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.CLOSED &&
            ring.failureReason.isBlank() && ring.destroyJoinOk && ring.destroyIdempotentOk &&
            ring.stageTrace.contains("feed_quiesced") && ring.stageTrace.contains(">paused>") &&
            ring.stageTrace.contains("paused_hold_frozen") && ring.stageTrace.contains("resumed") &&
            ring.stageTrace.contains("eos_set_without_drain") && ring.stageTrace.contains("close_dispose")
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
            native.commandsEnqueued == 3L && native.commandsProcessed == 3L && native.queueDepth == 0L &&
            native.noCallerSuppliedNativeTime && native.workerOwnsMonotonicClock &&
            native.providerFramesZeroFilledTrack0 == 0L && native.providerFramesZeroFilledTrack1 == 0L &&
            native.providerUnderrunEventsTrack0 == 0L && native.providerUnderrunEventsTrack1 == 0L &&
            native.proofBoundaryOk
        // Exactly one pause park + one unpark; no seek park, no flush, no
        // native writer seek, one native pause + one resume, not paused at the end.
        val pauseCycleCountsOk = sink != null && native != null &&
            sink.parkCount == 1 && sink.unparkCount == 1 && sink.seekParkCount == 0 && sink.flushCount == 0 &&
            native.writerSeekRequestsTrack0 == 0L && native.writerSeekRequestsTrack1 == 0L &&
            native.pauseCommandsProcessed == 1L && native.resumeCommandsProcessed == 1L && !native.paused
        val noFeedbackOk = sink != null && ring != null &&
            ring.driftSamplesPosted == ring.driftSamplesRejectedUnsupported + ring.driftSamplesRejectedStale &&
            sink.driftSamplesPosted == ring.driftSamplesPosted &&
            sink.driftSamplesRecorded == 0L && sink.driftNativeSamplesRecorded == 0L &&
            sink.drainRequestSizeChanges == 0L && sink.timestampMaxPollsInOnePass <= 1L &&
            sink.timestampPollsWhileParked == 0L
        val proofBoundaryOk = PROOF_BOUNDARY_TOKENS.all { PROOF_BOUNDARY.contains(it) }
        val controlOk = pr != null &&
            pr.quiesceRequests == 1L && pr.pauseRequests == 1L && pr.holdAssertRequests == 1L && pr.resumeRequests == 1L &&
            pr.controlRequestsOnOwnerThread == 0L && pr.controlOverlapRejects == 0L && pr.controlWaitTimeouts == 0L
        val baseOk = out.failureReason.isBlank() && sink != null && ring != null && pr != null &&
            native != null && decoder != null && g != null &&
            routeOk && formatOk && threadOk && ringDrainOk && drainLatencyOk && controlOk

        // ── Lane 1: pause ack at a clean boundary, sink parked first ───────
        val pauseAckOk = baseOk && sink != null && pr != null &&
            f.firstPlayObserved && !f.ingestCompleteAtFirstPlay &&
            f.quiesceAckOk && pr.quiesceAckOk && pr.quiesceExecutedOnOwnerThread && f.ringQuiescedObserved &&
            !f.ingestCompleteAtQuiesce && pr.feedStepsWhileQuiesced == 0L &&
            pr.quiesceWallMs in 0L..AndroidRealtimeAudioPlaybackRealDecoderRingPauseResumeScenario.CONTROL_TIMEOUT_MS &&
            f.sinkParkRequested && f.sinkParked && f.sinkParkedBeforeRingPause &&
            f.sinkPhaseAtRingPause == VanguardRealtimeAudioPlaybackSinkBridge.Phase.PARKED.name &&
            sink.parkExecutedOnSinkThread && sink.playStateAtPark == AudioTrack.PLAYSTATE_PAUSED &&
            f.ringPauseAckOk && f.ringPausedObserved &&
            pr.pauseAckOk && pr.pauseExecutedOnOwnerThread && pr.pauseQuiescedFirst && pr.pauseCleanBoundaryOk &&
            pr.pausePendingSliceFramesAtRequest == 0 && !pr.pausePumpPendingChunkAtRequest &&
            !pr.pauseCodecOutputHeldAtRequest && !pr.pauseIngestCompleteAtRequest &&
            pr.nativePauseProofOk && pr.pauseCommandSeq > 0L &&
            pr.pauseWallMs in 0L..AndroidRealtimeAudioPlaybackRealDecoderRingPauseResumeScenario.CONTROL_TIMEOUT_MS &&
            pr.dispatchCountAtPause > 0L &&
            pr.totalFramesPushedAtPause > 0L && pr.totalFramesPushedAtPause < expectedFrames &&
            pr.framesReadBySinkAtPause > 0L && pr.framesReadBySinkAtPause < expectedFrames &&
            pr.framesReadBySinkAtPause == f.sinkFramesReadAtPark &&
            pr.framesReadBySinkAtPause <= pr.totalFramesPushedAtPause &&
            pr.pumpFramesAcceptedAtPause > 0L && pr.pumpFramesAcceptedAtPause < expectedFrames &&
            pr.framesAcceptedTrack0AtPause == pr.pumpFramesAcceptedAtPause &&
            pr.framesAcceptedTrack1AtPause == pr.pumpFramesAcceptedAtPause &&
            pr.totalFramesPushedAtPause <= pr.pumpFramesAcceptedAtPause &&
            pr.framesPendingAtPause >= 0L &&
            (pr.stageBeforePause == AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.ACTIVE_DRAIN.name ||
                pr.stageBeforePause == AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.DECODER_EOS.name)

        // ── Lane 2: frozen paused hold, no owner feed / EOS poll / drain ──
        val holdFrozenOk = baseOk && sink != null && pr != null &&
            f.holdAssertAckOk && pr.holdAssertAckOk && pr.holdAssertExecutedOnOwnerThread && pr.nativeHoldFrozenProofOk &&
            f.ringPausedDuringHold &&
            f.sinkPhaseAfterHold == VanguardRealtimeAudioPlaybackSinkBridge.Phase.PARKED.name &&
            f.sinkFramesReadAfterHold == f.sinkFramesReadAtPark &&
            pr.dispatchCountAfterHold == pr.dispatchCountAtPause &&
            pr.totalFramesPushedAfterHold == pr.totalFramesPushedAtPause &&
            pr.pausedWaitsAfterHold > pr.pausedWaitsAtPause &&
            pr.framesReadBySinkAfterHold == pr.framesReadBySinkAtPause &&
            pr.drainsServicedAfterHold == pr.drainsServicedAtPause &&
            pr.pumpFramesAcceptedAfterHold == pr.pumpFramesAcceptedAtPause &&
            pr.ownerLoopIterationsWhilePaused > 0L &&
            pr.feedStepsWhilePaused == 0L && pr.eosPollsWhilePaused == 0L && pr.decodeStepsWhilePaused == 0L &&
            pr.makeRoomCallbacksWhilePaused == 0L &&
            pr.pausedDrainRejectsSinkThread == 0L && pr.pausedDrainRejectsOwnerThread == 0L &&
            f.pauseHoldMs >= AndroidRealtimeAudioPlaybackRealDecoderRingPauseResumeScenario.MIN_PAUSE_HOLD_MS &&
            f.holdSleptMs >= f.pauseHoldMs &&
            pr.holdAssertObservedNs >= holdNs &&
            pr.pauseHoldObservedMs >= f.pauseHoldMs && pr.pauseHoldObservedMs < f.sinkMaxPauseHoldMs &&
            sink.parkHoldCapMs == f.sinkMaxPauseHoldMs &&
            sink.parkedHoldMs >= f.pauseHoldMs && sink.parkedHoldMs < sink.parkHoldCapMs &&
            sink.parkedPlayStateViolations == 0L && sink.timestampPollsWhileParked == 0L

        // Pre-unpark: ring-side frames-read-by-sink is frozen across the hold
        // while the sink is still PARKED at ring resume (checked again below).
        // Post-unpark: the sink thread may already be draining once RUNNING is
        // acknowledged, so only monotonic (not equal) frames-read holds once
        // the coordinator reads it after awaitRunning.
        val y19LanePreUnparkReadFrozenOk = pr != null &&
            f.sinkPhaseAtRingResume == VanguardRealtimeAudioPlaybackSinkBridge.Phase.PARKED.name &&
            pr.framesReadBySinkAtResume == pr.framesReadBySinkAtPause
        val y19LanePostUnparkReadMonotonicOk = f.sinkFramesReadAtUnpark >= f.sinkFramesReadAtPark
        m["y19LanePreUnparkReadFrozenOk"] = y19LanePreUnparkReadFrozenOk
        m["y19LanePostUnparkReadMonotonicOk"] = y19LanePostUnparkReadMonotonicOk

        // ── Lane 3: resume ack, totals unchanged across the hold, sink unparked after ─
        val resumeAckOk = baseOk && sink != null && native != null && pr != null &&
            f.ringResumeAckOk && pr.resumeAckOk && pr.resumeExecutedOnOwnerThread && pr.nativeResumeProofOk &&
            pr.resumeCommandSeq == pr.pauseCommandSeq + 1L &&
            pr.resumeWallMs in 0L..AndroidRealtimeAudioPlaybackRealDecoderRingPauseResumeScenario.CONTROL_TIMEOUT_MS &&
            !f.ringPausedAfterResume &&
            pr.dispatchCountAtResume == pr.dispatchCountAtPause &&
            pr.totalFramesPushedAtResume == pr.totalFramesPushedAtPause &&
            pr.nativeLastPausedIntervalNs >= holdNs &&
            pr.nativeTotalPausedNs >= pr.nativeLastPausedIntervalNs &&
            pr.framesReadBySinkAtResume == pr.framesReadBySinkAtPause &&
            pr.pumpFramesAcceptedAtResume == pr.pumpFramesAcceptedAtPause &&
            pr.stageAfterResume == pr.stageBeforePause &&
            f.sinkPhaseAtRingResume == VanguardRealtimeAudioPlaybackSinkBridge.Phase.PARKED.name &&
            f.sinkUnparked && f.sinkRunning && f.sinkUnparkAfterRingResume &&
            y19LanePostUnparkReadMonotonicOk &&
            sink.unparkCount == 1 && sink.unparkExecutedOnSinkThread &&
            sink.playStateAfterUnpark == AudioTrack.PLAYSTATE_PLAYING &&
            sink.epochOpenedAtUnpark == sink.epochClosedAtPark + 1 &&
            sink.epochRawOriginAtUnpark == sink.positionAtPark &&
            native.pauseCommandsProcessed == 1L && native.resumeCommandsProcessed == 1L && !native.paused

        // ── Lane 4: exact identity to EOS after the resume + full route ───
        val postResumeChecksumOk = baseOk && ring != null && pr != null &&
            f.sinkExited && f.sinkJoined && f.ringClosed &&
            sinkLifecycleOk && frameAccountingOk && decoderEosOk && lockstepOk && eosOk && checksumOk &&
            ringCloseOk && nativeOk && pauseCycleCountsOk && noFeedbackOk && proofBoundaryOk &&
            pr.framesReadBySinkAtResume in 1L until expectedFrames &&
            ring.framesReadBySink - pr.framesReadBySinkAtResume > 0L &&
            ring.framesReadBySink == expectedFrames

        m["y19LaneRouteOk"] = routeOk
        m["y19LaneFormatOk"] = formatOk
        m["y19LaneSinkLifecycleOk"] = sinkLifecycleOk
        m["y19LaneThreadOk"] = threadOk
        m["y19LaneRingDrainOk"] = ringDrainOk
        m["y19LaneDrainLatencyOk"] = drainLatencyOk
        m["y19LaneFrameAccountingOk"] = frameAccountingOk
        m["y19LaneDecoderEosOk"] = decoderEosOk
        m["y19LaneLockstepOk"] = lockstepOk
        m["y19LaneEosOk"] = eosOk
        m["y19LaneChecksumOk"] = checksumOk
        m["y19LaneRingCloseOk"] = ringCloseOk
        m["y19LaneNativeOk"] = nativeOk
        m["y19LanePauseCycleCountsOk"] = pauseCycleCountsOk
        m["y19LaneNoFeedbackOk"] = noFeedbackOk
        m["y19LaneProofBoundaryOk"] = proofBoundaryOk
        m["y19LaneControlOk"] = controlOk
        m["y19LaneBaseOk"] = baseOk
        m["y19NonClaims"] = "real_decoder_ring_pause_resume_proof_only_one_owner_thread_executed_native_pause_resume_cycle_" +
            "feed_quiesced_at_clean_boundary_before_sink_park_sink_parked_before_ring_pause_no_feed_no_eos_poll_no_drain_while_paused_" +
            "no_seek_no_flush_no_dead_object_no_drift_feedback_no_feedback_control_loop_no_pacing_correction_no_resampling_" +
            "no_current_position_authority_switch_no_av_sync_closure_no_cross_device_bit_exact_decoder_claim_" +
            "no_session_no_production_feed_no_product_no_editor_no_app_no_connectsapp_no_ios_no_streaming_no_cache_no_fleet_claim"

        out.lanes[LANE_REAL_RING_PAUSE_ACK] = pauseAckOk
        out.lanes[LANE_REAL_RING_PAUSE_HOLD_FROZEN] = holdFrozenOk
        out.lanes[LANE_REAL_RING_RESUME_ACK] = resumeAckOk
        out.lanes[LANE_REAL_RING_POST_RESUME_CHECKSUM] = postResumeChecksumOk
    }
}
