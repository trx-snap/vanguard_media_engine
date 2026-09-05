package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioFormat
import android.media.AudioTrack
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSinkBridge
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSinkTelemetry
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackPresentationClock
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_REAL_RING_SEEK_CHECKSUM_IDENTITY
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_REAL_RING_SEEK_POST_SEEK_DRAIN
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_REAL_RING_SEEK_QUIESCE_ACK
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.LANE_REAL_RING_SEEK_REANCHOR
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.PROOF_BOUNDARY
import com.connects.vanguard_media_engine.diagnostics.AndroidRealtimeAudioPlaybackProductionSmokeCoordinator.Companion.PROOF_BOUNDARY_TOKENS

// ── AndroidRealtimeAudioPlaybackRealDecoderRingSeekLaneEvaluator (Y20) ─────
//
// Pure lane evaluation for Scenario 16
// ([AndroidRealtimeAudioPlaybackRealDecoderRingSeekScenario]): reads the
// already-captured sink / ring / native / clock snapshots plus the
// coordinator-thread ordering facts and sets EXACTLY the four Y20 lanes on
// the outcome. It owns no thread, session, AudioTrack or lifecycle decision.
//
// Every Y18c route invariant is re-asserted here with the counts a single
// TRUE forward seek legitimately changes: two native commands (Start, Seek),
// one sink seek park + one flush + one unpark, one native joint seek with
// skipped == T - H > 0 and expectedPlayable == expectedFrames - skipped, and
// EVERY frame / checksum identity asserted over the EFFECTIVE (seek-aware)
// frame count, never over the original expectedFrames. No pause, no resume,
// no dead object. Codec + extractor released once, native destroy
// idempotent, sink AudioTrack released once and the no-feedback rule are
// required as in Y18c/Y19; the Y18c and Y19 lanes are never touched here.
object AndroidRealtimeAudioPlaybackRealDecoderRingSeekLaneEvaluator {

    fun evaluate(
        sink: VanguardRealtimeAudioPlaybackSinkTelemetry?,
        ring: AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Telemetry?,
        sinkClock: VanguardRealtimePlaybackPresentationClock.Snapshot?,
        geometry: AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Geometry?,
        facts: AndroidRealtimeAudioPlaybackRealDecoderRingSeekScenario.Facts,
        config: SmokeConfig,
        out: ScenarioOutcome,
    ) {
        val f = facts
        val sk = ring?.seek
        val sr = ring?.seekReanchor
        val pr = ring?.pauseResume
        val native = ring?.native
        val decoder = ring?.decoder
        val g = geometry ?: ring?.geometry
        val expectedFrames = g?.expectedFrames ?: -1L
        val sampleRate = g?.sampleRate?.toLong() ?: -1L
        val window = g?.maxFramesPerMix?.toLong() ?: -1L
        val outputRing = AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.DEFAULT_OUTPUT_RING_CAPACITY_FRAMES.toLong()
        val hold = f.holdFrame
        val target = f.targetFrame
        val skip = f.skipFrames
        // Seek-aware effective frame count every identity is asserted against.
        val effective = if (expectedFrames > 0L && skip > 0L) expectedFrames - skip else -1L
        val postSeekExpected = if (expectedFrames > 0L && target > 0L) expectedFrames - target else -1L
        val seekTargetUs = if (target > 0L && sampleRate > 0L) (target * 1_000_000L + sampleRate - 1L) / sampleRate else -1L
        val oneFrameUs = if (sampleRate > 0L) (1_000_000L + sampleRate - 1L) / sampleRate else -1L
        val m = out.metrics
        m["y20SinkTelemetryPresent"] = sink != null
        m["y20RingTelemetryPresent"] = ring != null
        m["y20NativeTelemetryPresent"] = native != null
        m["y20GeometryPresent"] = g != null
        m["y20CoordinatorThreadId"] = f.coordinatorThreadId

        // ── Frozen geometry ────────────────────────────────────────────────
        m["realRingSourceMime"] = g?.sourceMime ?: ""
        m["realRingSourceDurationUs"] = g?.sourceDurationUs ?: -1L
        m["realRingDeclaredWindowUs"] = g?.declaredWindowUs ?: -1L
        m["realRingSampleRate"] = g?.sampleRate ?: -1
        m["realRingChannelCount"] = g?.channelCount ?: -1
        m["realRingPcmEncoding"] = g?.pcmEncoding ?: -1
        m["realRingExpectedFrames"] = expectedFrames
        m["realRingPadBudgetFrames"] = g?.padBudgetFrames ?: -1L
        m["y20EffectiveExpectedFrames"] = effective
        m["y20SeekTargetUs"] = seekTargetUs

        // ── Ordering facts (coordinator thread) ────────────────────────────
        m["y20RealDecoderSourceUsed"] = f.realDecoderSourceUsed
        m["y20StateMachineSourceUsed"] = f.stateMachineSourceUsed
        m["y20SinkReadyBeforeTransportStart"] = f.sinkReadyBeforeTransportStart
        m["y20DrainAllowedAfterTransportStart"] = f.drainAllowedAfterTransportStart
        m["y20Window"] = f.window
        m["y20SampleRate"] = f.sampleRate
        m["y20ExpectedFrames"] = f.expectedFrames
        m["y20HoldAboveNativeTimingGate"] = f.holdAboveNativeTimingGate
        m["y20HoldAckOk"] = f.holdAckOk
        m["y20HoldAckWallMs"] = f.holdAckWallMs
        m["y20FeedHeldObserved"] = f.feedHeldObserved
        m["y20FirstPlayObservedAtHold"] = f.firstPlayObservedAtHold
        m["y20IngestCompleteAtHold"] = f.ingestCompleteAtHold
        m["y20SinkFramesReadAtHoldAck"] = f.sinkFramesReadAtHoldAck
        m["y20SinkDrainedToHold"] = f.sinkDrainedToHold
        m["y20SinkDrainedToHoldWallMs"] = f.sinkDrainedToHoldWallMs
        m["y20SinkFramesReadAtHoldDrained"] = f.sinkFramesReadAtHoldDrained
        m["y20RingFramesReadBySinkAtHoldDrained"] = f.ringFramesReadBySinkAtHoldDrained
        m["y20SinkSeekParkRequested"] = f.sinkSeekParkRequested
        m["y20SinkParked"] = f.sinkParked
        m["y20SinkParkedWallMs"] = f.sinkParkedWallMs
        m["y20SinkPhaseAtFlush"] = f.sinkPhaseAtFlush
        m["y20SinkFramesReadAtPark"] = f.sinkFramesReadAtPark
        m["y20SinkFlushRequested"] = f.sinkFlushRequested
        m["y20SinkFlushed"] = f.sinkFlushed
        m["y20SinkFlushedWallMs"] = f.sinkFlushedWallMs
        m["y20SinkFlushCountAtRingSeek"] = f.sinkFlushCountAtRingSeek
        m["y20SinkPhaseAtRingSeek"] = f.sinkPhaseAtRingSeek
        m["y20RingSeekRequestedWallMs"] = f.ringSeekRequestedWallMs
        m["y20RingSeekAckOk"] = f.ringSeekAckOk
        m["y20RingSeekAckWallMs"] = f.ringSeekAckWallMs
        m["y20SinkParkedBeforeRingSeek"] = f.sinkParkedBeforeRingSeek
        m["y20SinkFlushedBeforeRingSeek"] = f.sinkFlushedBeforeRingSeek
        m["y20RingSeekExercisedObserved"] = f.ringSeekExercisedObserved
        m["y20RingSeekInProgressAfterAck"] = f.ringSeekInProgressAfterAck
        m["y20RingFeedHeldAfterSeek"] = f.ringFeedHeldAfterSeek
        m["y20RingEffectiveExpectedFramesAfterSeek"] = f.ringEffectiveExpectedFramesAfterSeek
        m["y20SinkFramesReadAtRingSeekAck"] = f.sinkFramesReadAtRingSeekAck
        m["y20SinkUnparkRequestedWallMs"] = f.sinkUnparkRequestedWallMs
        m["y20SinkUnparked"] = f.sinkUnparked
        m["y20SinkRunning"] = f.sinkRunning
        m["y20SinkRunningWallMs"] = f.sinkRunningWallMs
        m["y20SinkUnparkAfterRingSeek"] = f.sinkUnparkAfterRingSeek
        m["y20SinkFramesReadAtUnpark"] = f.sinkFramesReadAtUnpark
        m["y20SinkExited"] = f.sinkExited
        m["y20SinkExitedWallMs"] = f.sinkExitedWallMs
        m["y20SinkJoined"] = f.sinkJoined
        m["y20RingClosed"] = f.ringClosed
        m["y20RingOpenWallMs"] = f.ringOpenWallMs
        m["y20SinkReadyWallMs"] = f.sinkReadyWallMs
        m["y20TransportStartedWallMs"] = f.transportStartedWallMs
        m["y20DrainAllowedWallMs"] = f.drainAllowedWallMs

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
        m["sinkFlushRequestCount"] = sink?.flushRequestCount ?: -1
        m["sinkFlushCount"] = sink?.flushCount ?: -1
        m["sinkFlushExecutedOnSinkThread"] = sink?.flushExecutedOnSinkThread ?: false
        m["sinkFlushAckLatencyMs"] = sink?.flushAckLatencyMs ?: -1L
        m["sinkPlayStateBeforeFlush"] = sink?.playStateBeforeFlush ?: -1
        m["sinkPlayStateAfterFlush"] = sink?.playStateAfterFlush ?: -1
        m["sinkFramesWrittenAtFlush"] = sink?.framesWrittenAtFlush ?: -1L
        m["sinkFramesReadAtFlush"] = sink?.framesReadAtFlush ?: -1L
        m["sinkDrainCallsAtFlush"] = sink?.drainCallsAtFlush ?: -1L
        m["sinkTimestampPollsDuringFlush"] = sink?.timestampPollsDuringFlush ?: -1L
        m["sinkPostSeekExpectedFrames"] = sink?.postSeekExpectedFrames ?: -1L
        m["sinkReadBudgetFrames"] = sink?.readBudgetFrames ?: -1L
        m["sinkSeekTargetFrame"] = sink?.seekTargetFrame ?: -1L
        m["sinkSeekEpochOpenedAtUnpark"] = sink?.seekEpochOpenedAtUnpark ?: -1
        m["sinkSeekEpochBaseFrame"] = sink?.seekEpochBaseFrame ?: -1L
        m["sinkSeekDiscontinuityFrames"] = sink?.seekDiscontinuityFrames ?: -1L
        m["sinkSeekEpochOpenAccepted"] = sink?.seekEpochOpenAccepted ?: false
        m["sinkSeekUnwrapResetAtFlush"] = sink?.seekUnwrapResetAtFlush ?: false
        m["sinkPostSeekFramesWritten"] = sink?.postSeekFramesWritten ?: -1L
        m["sinkMaxSeekHoldMs"] = sink?.maxSeekHoldMs ?: -1L
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
        m["realRingEffectiveExpectedFrames"] = ring?.effectiveExpectedFrames ?: -1L
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

        // ── Ring control accounting (Y19 counters must stay untouched) ─────
        m["realRingQuiesceRequests"] = pr?.quiesceRequests ?: -1L
        m["realRingPauseRequests"] = pr?.pauseRequests ?: -1L
        m["realRingHoldAssertRequests"] = pr?.holdAssertRequests ?: -1L
        m["realRingResumeRequests"] = pr?.resumeRequests ?: -1L
        m["realRingControlRequestsOnOwnerThread"] = pr?.controlRequestsOnOwnerThread ?: -1L
        m["realRingControlOverlapRejects"] = pr?.controlOverlapRejects ?: -1L
        m["realRingControlWaitTimeouts"] = pr?.controlWaitTimeouts ?: -1L
        m["realRingLastControlTimeoutKind"] = pr?.lastControlTimeoutKind ?: ""
        m["realRingLastControlRejectReason"] = pr?.lastControlRejectReason ?: ""
        m["realRingFeedStepsWhilePaused"] = pr?.feedStepsWhilePaused ?: -1L
        m["realRingFeedStepsWhileQuiesced"] = pr?.feedStepsWhileQuiesced ?: -1L
        m["realRingPausedDrainRejectsSinkThread"] = pr?.pausedDrainRejectsSinkThread ?: -1L
        m["realRingPausedDrainRejectsOwnerThread"] = pr?.pausedDrainRejectsOwnerThread ?: -1L

        // ── Ring seek facts, part 1 (hold + owner-executed seek) ───────────
        m["realRingSeekQuiesceRequests"] = sk?.seekQuiesceRequests ?: -1L
        m["realRingSeekRequests"] = sk?.seekRequests ?: -1L
        m["realRingSeekDrainRejectsSinkThread"] = sk?.seekDrainRejectsSinkThread ?: -1L
        m["realRingSeekDrainRejectsOwnerThread"] = sk?.seekDrainRejectsOwnerThread ?: -1L
        m["realRingSeekHoldFrame"] = sk?.holdFrame ?: -1L
        m["realRingSeekHoldArmed"] = sk?.holdArmed ?: false
        m["realRingSeekHoldArmedOnOwnerThread"] = sk?.holdArmedOnOwnerThread ?: false
        m["realRingSeekHoldCommittedFramesAtArm"] = sk?.holdCommittedFramesAtArm ?: -1L
        m["realRingSeekHoldReached"] = sk?.holdReached ?: false
        m["realRingSeekHoldAckOk"] = sk?.holdAckOk ?: false
        m["realRingSeekHoldExecutedOnOwnerThread"] = sk?.holdExecutedOnOwnerThread ?: false
        m["realRingSeekHoldWallMs"] = sk?.holdWallMs ?: -1L
        m["realRingSeekHoldDiscardedStagedFrames"] = sk?.holdDiscardedStagedFrames ?: -1L
        m["realRingFeedStepsWhileHeld"] = sk?.feedStepsWhileHeld ?: -1L
        m["realRingFramesReadBySinkAtHold"] = sk?.framesReadBySinkAtHold ?: -1L
        m["realRingDrainsServicedAtHold"] = sk?.drainsServicedAtHold ?: -1L
        m["realRingFramesAcceptedTrack0AtHold"] = sk?.framesAcceptedTrack0AtHold ?: -1L
        m["realRingFramesAcceptedTrack1AtHold"] = sk?.framesAcceptedTrack1AtHold ?: -1L
        m["realRingFramesDecodedAtHold"] = sk?.framesDecodedAtHold ?: -1L
        m["realRingDecodeStepsAtHold"] = sk?.decodeStepsAtHold ?: -1L
        m["realRingSeekExercised"] = sk?.seekExercised ?: false
        m["realRingSeekAckOk"] = sk?.seekAckOk ?: false
        m["realRingSeekExecutedOnOwnerThread"] = sk?.seekExecutedOnOwnerThread ?: false
        m["realRingSeekWallMs"] = sk?.seekWallMs ?: -1L
        m["realRingSeekTargetFrame"] = sk?.seekTargetFrame ?: -1L
        m["realRingSeekSkipFrames"] = sk?.seekSkipFrames ?: -1L
        m["realRingSeekQuiescedFirst"] = sk?.seekQuiescedFirst ?: false
        m["realRingSeekCleanBoundaryOk"] = sk?.seekCleanBoundaryOk ?: false
        m["realRingSeekPendingSliceFramesAtRequest"] = sk?.seekPendingSliceFramesAtRequest ?: -1
        m["realRingSeekPumpPendingChunkAtRequest"] = sk?.seekPumpPendingChunkAtRequest ?: true
        m["realRingSeekCodecOutputHeldAtRequest"] = sk?.seekCodecOutputHeldAtRequest ?: true
        m["realRingSeekIngestCompleteAtRequest"] = sk?.seekIngestCompleteAtRequest ?: true
        m["realRingSeekPausedAtRequest"] = sk?.seekPausedAtRequest ?: true
        m["realRingFramesReadBySinkAtSeek"] = sk?.framesReadBySinkAtSeek ?: -1L
        m["realRingDrainsServicedAtSeek"] = sk?.drainsServicedAtSeek ?: -1L
        m["realRingDrainsServicedDuringSeek"] = sk?.drainsServicedDuringSeek ?: -1L
        m["realRingStageBeforeSeek"] = sk?.stageBeforeSeek ?: "none"
        m["realRingStageAfterSeek"] = sk?.stageAfterSeek ?: "none"
        m["realRingNativeQuiescentProofOk"] = sk?.nativeQuiescentProofOk ?: false
        m["realRingNativeQuiescentTotalFramesPushed"] = sk?.nativeQuiescentTotalFramesPushed ?: -1L
        m["realRingNativeQuiescentNextDispatchFrame"] = sk?.nativeQuiescentNextDispatchFrame ?: -1L
        m["realRingNativeQuiescentOutputAvailableReadFrames"] = sk?.nativeQuiescentOutputAvailableReadFrames ?: -1L
        m["realRingNativeQuiescentTimingT1Ns"] = sk?.nativeQuiescentTimingT1Ns ?: -1L
        m["realRingNativeSeekCommandSeq"] = sk?.nativeSeekCommandSeq ?: -1L
        m["realRingNativeSeekRequestedPtsUs"] = sk?.nativeSeekRequestedPtsUs ?: -1L
        m["realRingNativeSeekReplyTargetFrame"] = sk?.nativeSeekReplyTargetFrame ?: -1L
        m["realRingNativeSeekTransientRetries"] = sk?.nativeSeekTransientRetries ?: -1L
        m["realRingNativeSeekProcessedOk"] = sk?.nativeSeekProcessedOk ?: false
        m["realRingNativeSkippedFramesAtSeek"] = sk?.nativeSkippedFramesAtSeek ?: -1L
        m["realRingNativeExpectedPlayableAtSeek"] = sk?.nativeExpectedPlayableAtSeek ?: -1L
        m["realRingNativeSeekSkipAnomaliesAtSeek"] = sk?.nativeSeekSkipAnomaliesAtSeek ?: -1L
        m["realRingNativeNextDispatchFrameAtSeek"] = sk?.nativeNextDispatchFrameAtSeek ?: -1L
        m["realRingNativeProviderExternalReanchorCountAtSeekTrack0"] = sk?.nativeProviderExternalReanchorCountAtSeekTrack0 ?: -1L
        m["realRingNativeProviderExternalReanchorCountAtSeekTrack1"] = sk?.nativeProviderExternalReanchorCountAtSeekTrack1 ?: -1L
        m["realRingNativeProviderLastExternalReanchorFrameAtSeekTrack0"] = sk?.nativeProviderLastExternalReanchorFrameAtSeekTrack0 ?: -1L
        m["realRingNativeProviderLastExternalReanchorFrameAtSeekTrack1"] = sk?.nativeProviderLastExternalReanchorFrameAtSeekTrack1 ?: -1L
        m["realRingNativeProviderExpectedNextFrameAtSeekTrack0"] = sk?.nativeProviderExpectedNextFrameAtSeekTrack0 ?: -1L
        m["realRingNativeProviderExpectedNextFrameAtSeekTrack1"] = sk?.nativeProviderExpectedNextFrameAtSeekTrack1 ?: -1L
        m["realRingSeekEffectiveExpectedFrames"] = sk?.effectiveExpectedFrames ?: -1L
        m["realRingSeekAckConsumedByAckOnlyRead"] = sk?.seekAckConsumedByAckOnlyRead ?: false
        m["realRingSeekAckNewStartFrame"] = sk?.seekAckNewStartFrame ?: -1L
        m["realRingSeekAckDiscardedFrames"] = sk?.seekAckDiscardedFrames ?: -1L
        m["realRingSeekAckTotalDiscardedOnSeekFrames"] = sk?.seekAckTotalDiscardedOnSeekFrames ?: -1L
        m["realRingSeekAckWallMs"] = sk?.seekAckWallMs ?: -1L

        // ── Ring seek facts, part 2 (re-anchor, prefill, final native) ─────
        m["realRingExtractorSeekCalls"] = sr?.extractorSeekCalls ?: -1L
        m["realRingCodecFlushCalls"] = sr?.codecFlushCalls ?: -1L
        m["realRingExtractorReanchoredOnOwnerThread"] = sr?.extractorReanchoredOnOwnerThread ?: false
        m["realRingSeekTargetUs"] = sr?.seekTargetUs ?: -1L
        m["realRingSeekLandingPtsUs"] = sr?.seekLandingPtsUs ?: -1L
        m["realRingSeekLandingLeadUs"] = sr?.seekLandingLeadUs ?: -1L
        m["realRingSeekLandingAtOrBeforeTarget"] = sr?.seekLandingAtOrBeforeTarget ?: false
        m["realRingPreTargetDiscardedFrames"] = sr?.preTargetDiscardedFrames ?: -1L
        m["realRingPreTargetDiscardBudgetFrames"] = sr?.preTargetDiscardBudgetFrames ?: -1L
        m["realRingFirstPostSeekChunkPtsUs"] = sr?.firstPostSeekChunkPtsUs ?: -1L
        m["realRingFirstIngestedPostSeekPtsUs"] = sr?.firstIngestedPostSeekPtsUs ?: -1L
        m["realRingInputEosAtSeek"] = sr?.inputEosAtSeek ?: true
        m["realRingOutputEosAtSeek"] = sr?.outputEosAtSeek ?: true
        m["realRingGeneratorReanchorCount"] = sr?.generatorReanchorCount ?: -1L
        m["realRingGeneratorReanchorFrame"] = sr?.generatorReanchorFrame ?: -1L
        m["realRingGeneratorAxis"] = sr?.generatorAxis ?: ""
        m["realRingPostSeekPrefillQuotaFrames"] = sr?.postSeekPrefillQuotaFrames ?: -1L
        m["realRingPostSeekPrefillFeedSteps"] = sr?.postSeekPrefillFeedSteps ?: -1L
        m["realRingPostSeekPrefillCommittedFrames"] = sr?.postSeekPrefillCommittedFrames ?: -1L
        m["realRingPostSeekPrefillAcceptedFrames"] = sr?.postSeekPrefillAcceptedFrames ?: -1L
        m["realRingPostSeekPrefillStalled"] = sr?.postSeekPrefillStalled ?: false
        m["realRingPostSeekPrefillWallMs"] = sr?.postSeekPrefillWallMs ?: -1L
        m["realRingPostSeekFramesReadBySink"] = sr?.postSeekFramesReadBySink ?: -1L
        m["realRingNativeExpectedPlayableFrameCount"] = sr?.nativeExpectedPlayableFrameCount ?: -1L
        m["realRingNativeTotalForwardSeekSkippedFrames"] = sr?.nativeTotalForwardSeekSkippedFrames ?: -1L
        m["realRingNativeTotalDiscardedOnSeekFrames"] = sr?.nativeTotalDiscardedOnSeekFrames ?: -1L
        m["realRingNativeSeekSkipAnomalies"] = sr?.nativeSeekSkipAnomalies ?: -1L
        m["realRingNativeNextDispatchFrame"] = sr?.nativeNextDispatchFrame ?: -1L
        m["realRingNativeOutputSeekRequest"] = sr?.nativeOutputSeekRequest ?: -1L
        m["realRingNativeOutputSeekAck"] = sr?.nativeOutputSeekAck ?: -1L
        m["realRingNativeSourceSeekRequestTrack0"] = sr?.nativeSourceSeekRequestTrack0 ?: -1L
        m["realRingNativeSourceSeekAckTrack0"] = sr?.nativeSourceSeekAckTrack0 ?: -1L
        m["realRingNativeSourceSeekRequestTrack1"] = sr?.nativeSourceSeekRequestTrack1 ?: -1L
        m["realRingNativeSourceSeekAckTrack1"] = sr?.nativeSourceSeekAckTrack1 ?: -1L
        m["realRingNativeWriterNextWriteFrameTrack0"] = sr?.nativeWriterNextWriteFrameTrack0 ?: -1L
        m["realRingNativeWriterNextWriteFrameTrack1"] = sr?.nativeWriterNextWriteFrameTrack1 ?: -1L
        m["realRingNativeTimingT1Ns"] = sr?.nativeTimingT1Ns ?: -1L
        m["nativeProviderExternalReanchorCountTrack0"] = sr?.nativeProviderExternalReanchorCountTrack0 ?: -1L
        m["nativeProviderExternalReanchorCountTrack1"] = sr?.nativeProviderExternalReanchorCountTrack1 ?: -1L
        m["nativeProviderLastExternalReanchorFrameTrack0"] = sr?.nativeProviderLastExternalReanchorFrameTrack0 ?: -1L
        m["nativeProviderLastExternalReanchorFrameTrack1"] = sr?.nativeProviderLastExternalReanchorFrameTrack1 ?: -1L
        m["nativeProviderForwardSkipFramesTrack0"] = sr?.nativeProviderForwardSkipFramesTrack0 ?: -1L
        m["nativeProviderForwardSkipFramesTrack1"] = sr?.nativeProviderForwardSkipFramesTrack1 ?: -1L
        m["nativeProviderRewindRejectsTrack0"] = sr?.nativeProviderRewindRejectsTrack0 ?: -1L
        m["nativeProviderRewindRejectsTrack1"] = sr?.nativeProviderRewindRejectsTrack1 ?: -1L
        m["realRingExpectedPlayableFrameCountAtEos"] = sr?.expectedPlayableFrameCountAtEos ?: -1L
        m["realRingTotalForwardSeekSkippedFramesAtEos"] = sr?.totalForwardSeekSkippedFramesAtEos ?: -1L

        // ── Y18c route invariants, re-asserted with the one-seek counts ────
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
        // Seek geometry derived from the frozen geometry (never hardcoded):
        // H window-aligned above the native timing gate, T = H + skip with a
        // window-aligned skip of at least one window, one output ring of
        // post-seek content before the aligned expectedFrames.
        val seekGeometryOk = g != null && expectedFrames > 0L && window > 0L && sampleRate > 0L &&
            f.window == window && f.sampleRate == sampleRate && f.expectedFrames == expectedFrames &&
            f.nativeTimingGateFrames > 0L && f.holdAboveNativeTimingGate &&
            hold > f.nativeTimingGateFrames && hold % window == 0L &&
            skip >= window && skip % window == 0L &&
            target == hold + skip && target % window == 0L &&
            target + outputRing <= expectedFrames &&
            f.expectedPlayableFrames == effective && effective > 0L && effective < expectedFrames &&
            f.postSeekExpectedFrames == postSeekExpected && postSeekExpected >= outputRing
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
        // Two owner-thread native commands on this route: Start, Seek.
        val ringDrainOk = ring != null &&
            ring.drainCallsFromSink > 0L && ring.drainsServiced > 0L &&
            ring.drainCallsOnOwnerThread == 0L && ring.drainCallsOnOtherThreads == 0L &&
            ring.drainOverlapRejects == 0L && ring.drainsBeforeStartRejected == 0L &&
            ring.drainsAfterCloseRejected == 0L && ring.privateOutputDrains == 0L &&
            ring.outputSinkAccountedFrames == ring.framesReadBySink &&
            ring.transportCommandsIssued == 2L && ring.transportCommandsFromDrain == 0L
        val drainLatencyOk = ring != null &&
            ring.drainWaitBoundMs > 0L && ring.drainWaitBoundMs < f.deadlineBudgetMs &&
            ring.drainWaitTimeouts == 0L && ring.drainLatencyBoundViolations == 0L &&
            ring.maxDrainServiceLatencyMs in 0L..ring.drainWaitBoundMs
        // Seek-aware frame accounting: every total equals the EFFECTIVE count.
        val frameAccountingOk = sink != null && ring != null && decoder != null && effective > 0L &&
            ring.effectiveExpectedFrames == effective &&
            ring.framesReadBySink == effective &&
            sink.framesReadFromTransport == effective &&
            sink.framesWrittenToSink == effective &&
            ring.totalOutputFramesRead == effective &&
            ring.outputSinkAccountedFrames == effective &&
            ring.pumpFramesAccepted == effective &&
            ring.framesAcceptedTrack0 == effective && ring.framesAcceptedTrack1 == effective &&
            decoder.ingestComplete &&
            decoder.framesIngestedReal + decoder.eosPadFrames == effective &&
            decoder.framesDecoded == decoder.framesIngestedReal + decoder.eosTruncatedFrames +
            (sk?.holdDiscardedStagedFrames ?: -1L) + (sr?.preTargetDiscardedFrames ?: -1L) &&
            decoder.eosPadFrames in 0L..decoder.padBudgetFrames &&
            ring.preStartFillFrames >= minOf(expectedFrames, outputRing)
        val decoderEosOk = decoder != null &&
            decoder.inputEosQueued && decoder.outputEosReached && decoder.decoderChunks > 0L &&
            decoder.mediaReleaseCount == 1 && decoder.codecReleaseCount == 1 &&
            decoder.extractorReleaseCount == 1 && decoder.mediaReleaseClean && decoder.mediaReleasedAtDecoderEos
        val lockstepOk = ring != null && effective > 0L &&
            ring.framesAcceptedTrack0 == ring.framesAcceptedTrack1 &&
            ring.framesAcceptedTrack0 == ring.pumpFramesAccepted &&
            ring.track1NonZeroSampleCount > 0L
        val eosOk = sink != null && ring != null && sr != null &&
            ring.eosSetWithoutDrain && ring.eosDrainedObservedByRing && sink.eosDrainedObserved &&
            ring.totalFramesPushedAtEos == effective &&
            sr.expectedPlayableFrameCountAtEos == effective &&
            sr.totalForwardSeekSkippedFramesAtEos == skip
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
            ring.stageTrace.contains(">seek_hold_armed>") && ring.stageTrace.contains(">feed_held_for_seek>") &&
            ring.stageTrace.contains(">feed_quiesced_for_seek>") && ring.stageTrace.contains(">seeking>") &&
            ring.stageTrace.contains(">native_seek_processed>") && ring.stageTrace.contains(">extractor_reanchored>") &&
            ring.stageTrace.contains(">codec_flushed>") && ring.stageTrace.contains(">post_seek_prefill>") &&
            ring.stageTrace.contains(">seek_ack_consumed>") && ring.stageTrace.contains(">seek_reanchored>") &&
            !ring.stageTrace.contains(">paused>") && !ring.stageTrace.contains(">resumed>") &&
            ring.stageTrace.contains("eos_set_without_drain") && ring.stageTrace.contains("close_dispose")
        val nativeOk = native != null && sr != null && effective > 0L &&
            native.timelineComplete &&
            native.totalFramesPushed == effective &&
            native.outputAvailableReadFrames == 0L &&
            native.totalOutputFramesRead == effective &&
            native.totalFramesAcceptedTrack0 == effective &&
            native.totalFramesAcceptedTrack1 == effective &&
            native.eosTrack0 && native.eosTrack1 &&
            native.workerThreadDistinct && native.ownerDispatchCalls == 0L &&
            native.commandErrors == 0L && native.schedulerErrorCount == 0L &&
            native.workerDispatchAnomalies == 0L && native.nonMonotonicTimeAnomalies == 0L &&
            native.commandsEnqueued == 2L && native.commandsProcessed == 2L && native.queueDepth == 0L &&
            native.noCallerSuppliedNativeTime && native.workerOwnsMonotonicClock &&
            native.providerFramesZeroFilledTrack0 == 0L && native.providerFramesZeroFilledTrack1 == 0L &&
            native.providerUnderrunEventsTrack0 == 0L && native.providerUnderrunEventsTrack1 == 0L &&
            // Provider/coordinator re-anchor: each provider was moved H -> T
            // by the worker exactly once, at T, and never forward-skipped or
            // rewind-rejected over the whole run (with zero-fill / underrun
            // above, the first post-seek window was read from T, not
            // synthesized).
            sr.nativeProviderExternalReanchorCountTrack0 == 1L &&
            sr.nativeProviderExternalReanchorCountTrack1 == 1L &&
            sr.nativeProviderLastExternalReanchorFrameTrack0 == target &&
            sr.nativeProviderLastExternalReanchorFrameTrack1 == target &&
            sr.nativeProviderForwardSkipFramesTrack0 == 0L &&
            sr.nativeProviderForwardSkipFramesTrack1 == 0L &&
            sr.nativeProviderRewindRejectsTrack0 == 0L &&
            sr.nativeProviderRewindRejectsTrack1 == 0L &&
            native.proofBoundaryOk &&
            // Final native seek-aware accounting: the content cursor ran to the
            // aligned expectedFrames while exactly `skip` frames were never
            // dispatched; every seek handshake settled; nothing was discarded.
            sr.nativeExpectedPlayableFrameCount == effective &&
            sr.nativeTotalForwardSeekSkippedFrames == skip &&
            sr.nativeTotalDiscardedOnSeekFrames == 0L &&
            sr.nativeSeekSkipAnomalies == 0L &&
            sr.nativeNextDispatchFrame == expectedFrames &&
            sr.nativeOutputSeekRequest == sr.nativeOutputSeekAck &&
            sr.nativeSourceSeekRequestTrack0 == sr.nativeSourceSeekAckTrack0 &&
            sr.nativeSourceSeekRequestTrack1 == sr.nativeSourceSeekAckTrack1 &&
            sr.nativeWriterNextWriteFrameTrack0 == sr.nativeWriterNextWriteFrameTrack1 &&
            sr.nativeTimingT1Ns >= 0L
        // Exactly one seek park (counted as the one park) + one flush + one
        // unpark; one native joint writer seek per track; no native pause or
        // resume ever processed; not paused at the end.
        val seekCycleCountsOk = sink != null && native != null &&
            sink.parkCount == 1 && sink.unparkCount == 1 && sink.seekParkCount == 1 &&
            sink.flushRequestCount == 1 && sink.flushCount == 1 &&
            native.writerSeekRequestsTrack0 == native.writerSeekRequestsTrack1 &&
            native.writerSeekRequestsTrack0 >= 1L &&
            native.pauseCommandsProcessed == 0L && native.resumeCommandsProcessed == 0L && !native.paused
        val noFeedbackOk = sink != null && ring != null &&
            ring.driftSamplesPosted == ring.driftSamplesRejectedUnsupported + ring.driftSamplesRejectedStale &&
            sink.driftSamplesPosted == ring.driftSamplesPosted &&
            sink.driftSamplesRecorded == 0L && sink.driftNativeSamplesRecorded == 0L &&
            sink.drainRequestSizeChanges == 0L && sink.timestampMaxPollsInOnePass <= 1L &&
            sink.timestampPollsWhileParked == 0L
        val proofBoundaryOk = PROOF_BOUNDARY_TOKENS.all { PROOF_BOUNDARY.contains(it) }
        // One QUIESCE_FOR_SEEK + one SEEK request from the coordinator thread;
        // the Y19 pause/resume control surface stays untouched (zero requests).
        val controlOk = pr != null && sk != null &&
            sk.seekQuiesceRequests == 1L && sk.seekRequests == 1L &&
            pr.quiesceRequests == 0L && pr.pauseRequests == 0L && pr.holdAssertRequests == 0L && pr.resumeRequests == 0L &&
            pr.controlRequestsOnOwnerThread == 0L && pr.controlOverlapRejects == 0L && pr.controlWaitTimeouts == 0L &&
            pr.feedStepsWhilePaused == 0L && pr.feedStepsWhileQuiesced == 0L &&
            pr.pausedDrainRejectsSinkThread == 0L && pr.pausedDrainRejectsOwnerThread == 0L
        val baseOk = out.failureReason.isBlank() && sink != null && ring != null && sk != null && sr != null &&
            pr != null && native != null && decoder != null && g != null &&
            routeOk && formatOk && seekGeometryOk && threadOk && ringDrainOk && drainLatencyOk && controlOk

        // ── Lane 1: feed held at H, sink drained to H, seek-parked + flushed,
        //    native quiescence proven snapshot-only (no private drain) ───────
        val quiesceAckOk = baseOk && sink != null && sk != null &&
            f.holdAckOk && f.feedHeldObserved && f.firstPlayObservedAtHold && !f.ingestCompleteAtHold &&
            f.holdAckWallMs in 0L..AndroidRealtimeAudioPlaybackRealDecoderRingSeekScenario.HOLD_TIMEOUT_MS &&
            f.sinkFramesReadAtHoldAck in 0L..hold &&
            sk.holdArmed && sk.holdFrame == hold && sk.holdArmedOnOwnerThread &&
            sk.holdCommittedFramesAtArm in 0L..hold &&
            sk.holdReached && sk.holdAckOk && sk.holdExecutedOnOwnerThread &&
            sk.holdWallMs in 0L..AndroidRealtimeAudioPlaybackRealDecoderRingSeekScenario.HOLD_TIMEOUT_MS &&
            sk.holdDiscardedStagedFrames in 0L..skip &&
            sk.feedStepsWhileHeld == 0L &&
            sk.framesReadBySinkAtHold in 0L..hold && sk.drainsServicedAtHold > 0L &&
            sk.framesAcceptedTrack0AtHold == hold && sk.framesAcceptedTrack1AtHold == hold &&
            sk.framesDecodedAtHold >= hold && sk.decodeStepsAtHold > 0L &&
            // The production sink (sole output consumer) drained exactly H.
            f.sinkDrainedToHold && f.sinkFramesReadAtHoldDrained == hold && f.ringFramesReadBySinkAtHoldDrained == hold &&
            f.sinkDrainedToHoldWallMs >= f.holdAckWallMs &&
            // Sink seek park FIRST, then the one flush, both before the ring seek.
            f.sinkSeekParkRequested && f.sinkParked && f.sinkParkedWallMs >= f.sinkDrainedToHoldWallMs &&
            f.sinkFramesReadAtPark == hold &&
            f.sinkPhaseAtFlush == VanguardRealtimeAudioPlaybackSinkBridge.Phase.PARKED.name &&
            sink.seekParkCount == 1 && sink.parkCount == 1 && sink.parkExecutedOnSinkThread &&
            sink.playStateAtPark == AudioTrack.PLAYSTATE_PAUSED && sink.positionAtPark in 0L..hold &&
            f.sinkFlushRequested && f.sinkFlushed && f.sinkFlushedWallMs >= f.sinkParkedWallMs &&
            f.sinkFlushCountAtRingSeek == 1 &&
            f.sinkPhaseAtRingSeek == VanguardRealtimeAudioPlaybackSinkBridge.Phase.PARKED.name &&
            sink.flushRequestCount == 1 && sink.flushCount == 1 && sink.flushExecutedOnSinkThread &&
            sink.playStateBeforeFlush == AudioTrack.PLAYSTATE_PAUSED && sink.playStateAfterFlush == AudioTrack.PLAYSTATE_PAUSED &&
            sink.timestampPollsDuringFlush == 0L &&
            sink.framesWrittenAtFlush == hold && sink.framesReadAtFlush == hold && sink.drainCallsAtFlush > 0L &&
            sink.postSeekExpectedFrames == postSeekExpected && sink.readBudgetFrames == effective &&
            sink.seekTargetFrame == target && sink.flushAckLatencyMs >= 0L && sink.seekUnwrapResetAtFlush &&
            sink.maxSeekHoldMs == config.maxSeekHoldMs && sink.parkHoldCapMs == config.maxSeekHoldMs &&
            f.sinkParkedBeforeRingSeek && f.sinkFlushedBeforeRingSeek &&
            // Native quiescence at H proven from a snapshot only.
            sk.nativeQuiescentProofOk && sk.nativeQuiescentTotalFramesPushed == hold &&
            sk.nativeQuiescentNextDispatchFrame == hold && sk.nativeQuiescentOutputAvailableReadFrames == 0L &&
            sk.nativeQuiescentTimingT1Ns >= 0L &&
            // The sink stayed parked across the seek: no drain reached the ring.
            sk.seekDrainRejectsSinkThread == 0L && sk.seekDrainRejectsOwnerThread == 0L && sk.drainsServicedDuringSeek == 0L

        // ── Lane 2: one owner-executed native joint seek to T (skipped == T - H),
        //    generator / extractor / codec re-anchored, post-seek prefill, ack ─
        val reanchorOk = baseOk && sk != null && sr != null && ring != null &&
            f.ringSeekAckOk && f.ringSeekExercisedObserved && !f.ringSeekInProgressAfterAck && !f.ringFeedHeldAfterSeek &&
            f.ringEffectiveExpectedFramesAfterSeek == effective &&
            f.ringSeekAckWallMs - f.ringSeekRequestedWallMs in 0L..AndroidRealtimeAudioPlaybackRealDecoderRingSeekScenario.SEEK_TIMEOUT_MS &&
            f.sinkFramesReadAtRingSeekAck == hold &&
            sk.seekExercised && sk.seekAckOk && sk.seekExecutedOnOwnerThread &&
            sk.seekWallMs in 0L..AndroidRealtimeAudioPlaybackRealDecoderRingSeekScenario.SEEK_TIMEOUT_MS &&
            sk.seekTargetFrame == target && sk.seekSkipFrames == skip &&
            sk.seekQuiescedFirst && sk.seekCleanBoundaryOk &&
            sk.seekPendingSliceFramesAtRequest == 0 && !sk.seekPumpPendingChunkAtRequest &&
            !sk.seekCodecOutputHeldAtRequest && !sk.seekIngestCompleteAtRequest && !sk.seekPausedAtRequest &&
            sk.framesReadBySinkAtSeek == hold && sk.drainsServicedAtSeek > 0L &&
            sk.stageBeforeSeek == AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.ACTIVE_DRAIN.name &&
            sk.stageAfterSeek == AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.Stage.ACTIVE_DRAIN.name &&
            // Native joint seek: second command after Start, frame-derived pts,
            // reply target == T, processed with seek-aware accounting.
            sk.nativeSeekCommandSeq == 2L && sk.nativeSeekRequestedPtsUs == seekTargetUs &&
            sk.nativeSeekReplyTargetFrame == target && sk.nativeSeekTransientRetries >= 0L &&
            sk.nativeSeekProcessedOk && sk.nativeSkippedFramesAtSeek == skip &&
            sk.nativeExpectedPlayableAtSeek == effective && sk.nativeSeekSkipAnomaliesAtSeek == 0L &&
            sk.nativeNextDispatchFrameAtSeek == target &&
            // At the processed-Seek snapshot (before the output ack was
            // consumed, so before any post-seek dispatch) BOTH providers had
            // been re-anchored exactly once to T and expected T next.
            sk.nativeProviderExternalReanchorCountAtSeekTrack0 == 1L &&
            sk.nativeProviderExternalReanchorCountAtSeekTrack1 == 1L &&
            sk.nativeProviderLastExternalReanchorFrameAtSeekTrack0 == target &&
            sk.nativeProviderLastExternalReanchorFrameAtSeekTrack1 == target &&
            sk.nativeProviderExpectedNextFrameAtSeekTrack0 == target &&
            sk.nativeProviderExpectedNextFrameAtSeekTrack1 == target &&
            sk.effectiveExpectedFrames == effective && ring.effectiveExpectedFrames == effective &&
            // Output seek ack consumed by the ack-only read, zero discard.
            sk.seekAckConsumedByAckOnlyRead && sk.seekAckNewStartFrame == target &&
            sk.seekAckDiscardedFrames == 0L && sk.seekAckTotalDiscardedOnSeekFrames == 0L && sk.seekAckWallMs >= 0L &&
            // Synthetic generator re-anchored once on the accepted-count axis at H.
            sr.generatorReanchorCount == 1L && sr.generatorReanchorFrame == hold &&
            sr.generatorAxis == AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource.GENERATOR_AXIS_ACCEPTED_COUNT &&
            // Extractor re-anchored once (landing at or before T, reported) and
            // codec flushed once, both on the owner thread; pre-target decoded
            // frames discarded within budget; ingest restarts at T (one frame
            // of pts rounding tolerance).
            sr.extractorSeekCalls == 1L && sr.codecFlushCalls == 1L && sr.extractorReanchoredOnOwnerThread &&
            sr.seekTargetUs == seekTargetUs && sr.seekLandingPtsUs >= 0L &&
            sr.seekLandingAtOrBeforeTarget && sr.seekLandingLeadUs >= 0L &&
            sr.preTargetDiscardedFrames in 0L..sr.preTargetDiscardBudgetFrames &&
            sr.firstPostSeekChunkPtsUs >= 0L && sr.firstIngestedPostSeekPtsUs >= 0L &&
            sr.firstIngestedPostSeekPtsUs + oneFrameUs >= seekTargetUs &&
            !sr.outputEosAtSeek &&
            // Post-seek lockstep prefill (drains forbidden) before the ack.
            sr.postSeekPrefillQuotaFrames == minOf(outputRing, postSeekExpected) &&
            sr.postSeekPrefillFeedSteps > 0L && sr.postSeekPrefillCommittedFrames > 0L &&
            sr.postSeekPrefillAcceptedFrames in 1L..sr.postSeekPrefillCommittedFrames &&
            sr.postSeekPrefillWallMs in 0L..AndroidRealtimeAudioPlaybackRealDecoderRingSeekScenario.SEEK_TIMEOUT_MS

        // ── Lane 3: sink unparked AFTER the ring seek (epoch opens at T),
        //    drained to the native seek-aware EOS over exactly the effective
        //    frames ─────────────────────────────────────────────────────────
        val postSeekDrainOk = baseOk && sink != null && ring != null && sr != null && native != null &&
            f.sinkUnparked && f.sinkRunning && f.sinkUnparkAfterRingSeek &&
            f.sinkRunningWallMs >= f.sinkUnparkRequestedWallMs && f.sinkFramesReadAtUnpark >= hold &&
            f.sinkExited && f.sinkJoined && f.sinkExitedWallMs >= f.sinkRunningWallMs &&
            sink.unparkCount == 1 && sink.unparkExecutedOnSinkThread &&
            sink.playStateAfterUnpark == AudioTrack.PLAYSTATE_PLAYING &&
            sink.epochOpenedAtUnpark == sink.epochClosedAtPark + 1 &&
            sink.seekEpochOpenedAtUnpark == sink.epochOpenedAtUnpark &&
            sink.seekEpochBaseFrame == target && sink.seekEpochOpenAccepted &&
            sink.seekDiscontinuityFrames == target - sink.positionAtPark && sink.seekDiscontinuityFrames > 0L &&
            sink.epochRawOriginAtUnpark == 0L &&
            sink.parkedHoldMs in 0L..sink.parkHoldCapMs && sink.parkedPlayStateViolations == 0L &&
            sink.timestampPollsWhileParked == 0L &&
            sinkLifecycleOk &&
            sink.framesReadFromTransport == effective && sink.framesWrittenToSink == effective &&
            sink.postSeekFramesWritten == postSeekExpected &&
            sink.drainCalls > sink.drainCallsAtFlush && sink.productiveDrainPasses > 0L &&
            ring.framesReadBySink == effective && ring.totalOutputFramesRead == effective &&
            ring.outputSinkAccountedFrames == effective &&
            sr.postSeekFramesReadBySink == postSeekExpected &&
            eosOk && nativeOk && seekCycleCountsOk

        // ── Lane 4: exact frame + checksum identity over the EFFECTIVE frames
        //    (expectedFrames - skipped) across the full route ─────────────────
        val checksumIdentityOk = baseOk && ring != null && sr != null &&
            f.sinkExited && f.sinkJoined && f.ringClosed &&
            skip > 0L && effective == expectedFrames - skip &&
            sinkLifecycleOk && frameAccountingOk && decoderEosOk && lockstepOk && eosOk && checksumOk &&
            ringCloseOk && nativeOk && seekCycleCountsOk && noFeedbackOk && proofBoundaryOk

        m["y20LaneRouteOk"] = routeOk
        m["y20LaneFormatOk"] = formatOk
        m["y20LaneSeekGeometryOk"] = seekGeometryOk
        m["y20LaneSinkLifecycleOk"] = sinkLifecycleOk
        m["y20LaneThreadOk"] = threadOk
        m["y20LaneRingDrainOk"] = ringDrainOk
        m["y20LaneDrainLatencyOk"] = drainLatencyOk
        m["y20LaneFrameAccountingOk"] = frameAccountingOk
        m["y20LaneDecoderEosOk"] = decoderEosOk
        m["y20LaneLockstepOk"] = lockstepOk
        m["y20LaneEosOk"] = eosOk
        m["y20LaneChecksumOk"] = checksumOk
        m["y20LaneRingCloseOk"] = ringCloseOk
        m["y20LaneNativeOk"] = nativeOk
        m["y20LaneSeekCycleCountsOk"] = seekCycleCountsOk
        m["y20LaneNoFeedbackOk"] = noFeedbackOk
        m["y20LaneProofBoundaryOk"] = proofBoundaryOk
        m["y20LaneControlOk"] = controlOk
        m["y20LaneBaseOk"] = baseOk
        m["y20NonClaims"] = "real_decoder_ring_forward_seek_proof_only_one_owner_thread_executed_native_joint_seek_" +
            "feed_held_at_derived_window_aligned_hold_above_native_timing_gate_sink_drained_to_hold_sink_seek_parked_and_flushed_before_ring_seek_" +
            "native_quiescence_snapshot_only_no_private_drain_skipped_equals_target_minus_hold_effective_frames_equals_expected_minus_skipped_" +
            "extractor_landing_at_or_before_target_reported_not_exact_keyframe_claim_pre_target_decoded_frames_discarded_counted_" +
            "post_seek_prefill_drains_forbidden_ack_only_output_ack_zero_discard_" +
            "worker_reanchored_both_ring_providers_once_at_target_after_coordinator_seek_no_provider_forward_skip_no_zero_fill_" +
            "sink_unparked_after_ring_seek_epoch_at_target_" +
            "drained_to_native_seek_aware_eos_with_checksum_identity_over_effective_frames_" +
            "no_pause_no_resume_no_dead_object_no_drift_feedback_no_feedback_control_loop_no_pacing_correction_no_resampling_" +
            "no_current_position_authority_switch_no_av_sync_closure_no_cross_device_bit_exact_decoder_claim_" +
            "no_session_no_production_feed_no_product_no_editor_no_app_no_connectsapp_no_ios_no_streaming_no_cache_no_fleet_claim"

        out.lanes[LANE_REAL_RING_SEEK_QUIESCE_ACK] = quiesceAckOk
        out.lanes[LANE_REAL_RING_SEEK_REANCHOR] = reanchorOk
        out.lanes[LANE_REAL_RING_SEEK_POST_SEEK_DRAIN] = postSeekDrainOk
        out.lanes[LANE_REAL_RING_SEEK_CHECKSUM_IDENTITY] = checksumIdentityOk
    }
}
