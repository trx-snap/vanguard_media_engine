package com.connects.vanguard_media_engine.diagnostics

import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSeekObservation
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSinkTelemetry
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession

// Y9 (P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SEEK) + Y10b repeated-seek metric mapping
// of the production smoke: flattens the session's seek observation (with the decoder
// seek telemetry it carries) and the sink's seek park / flush / seek-epoch
// telemetry into a scenario metric map. Pure key mapping: lane logic lives in
// [AndroidRealtimeAudioPlaybackProductionLaneEvaluator], sequencing in
// [AndroidRealtimeAudioPlaybackProductionSmokeCoordinator].
object AndroidRealtimeAudioPlaybackProductionSeekMetrics {

    fun putSinkSeekMetrics(m: LinkedHashMap<String, Any?>, k: VanguardRealtimeAudioPlaybackSinkTelemetry) {
        m["sinkMaxSeekHoldMs"] = k.maxSeekHoldMs
        m["sinkSeekParkCount"] = k.seekParkCount
        m["sinkParkHoldCapMs"] = k.parkHoldCapMs
        m["sinkFlushRequestCount"] = k.flushRequestCount
        m["sinkFlushCount"] = k.flushCount
        m["sinkFlushExecutedOnSinkThread"] = k.flushExecutedOnSinkThread
        m["sinkFlushAckLatencyMs"] = k.flushAckLatencyMs
        m["sinkPlayStateBeforeFlush"] = k.playStateBeforeFlush
        m["sinkPlayStateAfterFlush"] = k.playStateAfterFlush
        m["playbackHeadBeforeFlush"] = k.playbackHeadBeforeFlush
        m["playbackHeadAfterFlush"] = k.playbackHeadAfterFlush
        m["sinkFramesWrittenAtFlush"] = k.framesWrittenAtFlush
        m["sinkFramesReadAtFlush"] = k.framesReadAtFlush
        m["sinkDrainCallsAtFlush"] = k.drainCallsAtFlush
        m["sinkTimestampPollsDuringFlush"] = k.timestampPollsDuringFlush
        m["sinkPostSeekExpectedFrames"] = k.postSeekExpectedFrames
        m["sinkReadBudgetFrames"] = k.readBudgetFrames
        m["sinkSeekTargetFrame"] = k.seekTargetFrame
        m["sinkSeekEpochOpenedAtUnpark"] = k.seekEpochOpenedAtUnpark
        m["sinkSeekEpochBaseFrame"] = k.seekEpochBaseFrame
        m["sinkSeekDiscontinuityFrames"] = k.seekDiscontinuityFrames
        m["sinkSeekEpochOpenAccepted"] = k.seekEpochOpenAccepted
        m["sinkSeekUnwrapResetAtFlush"] = k.seekUnwrapResetAtFlush
        m["sinkEpochRawOriginAtUnpark"] = k.epochRawOriginAtUnpark
        m["playbackHeadAtSeekUnpark"] = k.playbackHeadAtSeekUnpark
        m["sinkPostSeekFramesWritten"] = k.postSeekFramesWritten
    }

    fun putSessionSeekMetrics(m: LinkedHashMap<String, Any?>, q: VanguardRealtimeAudioPlaybackSeekObservation) {
        m["seekArmed"] = q.armed
        m["seekTargetFrame"] = q.targetFrame
        m["preSeekHoldFrame"] = q.holdFrame
        m["seekAdmissionOk"] = q.admissionOk
        m["seekHoldPinned"] = q.holdPinned
        m["seekCount"] = q.seekCount
        m["seekAccepted"] = q.seekAccepted
        m["seekStaleGeneration"] = q.staleGeneration
        m["seekGeneration"] = q.seekGeneration
        m["seekPauseAccepted"] = q.pauseAccepted
        m["seekPauseGeneration"] = q.pauseGeneration
        m["seekResumeAccepted"] = q.resumeAccepted
        m["seekResumeGeneration"] = q.resumeGeneration
        m["seekInitialWriteWaitMs"] = q.initialWriteWaitMs
        m["seekQuiesceWaitMs"] = q.quiesceWaitMs
        m["seekQuiesceFeedHeld"] = q.quiesceFeedHeld
        m["seekQuiesceSinkReadFrames"] = q.quiesceSinkReadFrames
        m["seekQuiesceSinkWrittenFrames"] = q.quiesceSinkWrittenFrames
        m["seekQuiesceAccountingOk"] = q.quiesceAccountingOk
        m["seekPreSeekSettleMs"] = q.preSeekSettleMs
        m["seekPreSeekTransportState"] = q.preSeekTransportState?.name ?: "none"
        m["seekFlushRequestedWhilePaused"] = q.flushRequestedWhilePaused
        m["seekFlushAckWaitMs"] = q.flushAckWaitMs
        m["seekFlushAckedBeforeSeek"] = q.flushAckedBeforeSeek
        m["seekSinkPhaseAtSeek"] = q.sinkPhaseAtSeek
        m["seekPostSeekTransportState"] = q.postSeekTransportState?.name ?: "none"
        m["seekReanchorWaitMs"] = q.reanchorWaitMs
        m["seekPostSeekPreRollWaitMs"] = q.postSeekPreRollWaitMs
        m["seekPostSeekPreRollTransportState"] = q.postSeekPreRollTransportState?.name ?: "none"
        m["seekTransportStateAtUnpark"] = q.transportStateAtUnpark?.name ?: "none"
        m["seekHoldObservedMs"] = q.holdObservedMs
        m["seekWallMs"] = q.seekWallMs
        m["seekParkRequestedAtMs"] = q.parkRequestedAtMs
        m["seekParkAckedAtMs"] = q.parkAckedAtMs
        m["seekUnparkedAtMs"] = q.unparkedAtMs
        m["seekResumedAtMs"] = q.resumedAtMs
        putReplyMetrics(m, "seekPreSeek", q.preSeekReply)
        putReplyMetrics(m, "seekPostPause", q.postPauseReply)
        putReplyMetrics(m, "seekPostSeek", q.postSeekReply)
        putReplyMetrics(m, "seekPostSeekPreRoll", q.postSeekPreRollReply)
        q.clockAtPark?.let {
            m["seekClockPositionAtPark"] = it.positionFrames
            m["seekClockEpochIdAtPark"] = it.epochId
            m["seekClockUpdateCountAtPark"] = it.updateCount
        }
        q.clockBeforeUnpark?.let {
            m["seekClockPositionBeforeUnpark"] = it.positionFrames
            m["seekClockUpdateCountBeforeUnpark"] = it.updateCount
        }
        q.clockAfterUnpark?.let {
            m["seekClockEpochIdAfterUnpark"] = it.epochId
            m["seekClockEpochBaseAfterUnpark"] = it.epochBaseOffsetFrames
            m["seekClockPositionAfterUnpark"] = it.positionFrames
            m["seekClockBaseClampCountAfterUnpark"] = it.baseClampCount
            m["seekClockBaseAdvanceCountAfterUnpark"] = it.baseAdvanceCount
            m["seekClockLastBaseAdvanceFramesAfterUnpark"] = it.lastBaseAdvanceFrames
            m["seekClockProvenanceAfterUnpark"] = it.provenance.name
        }
        val d = q.decoder ?: return
        m["decoderHoldFrame"] = d.holdFrame
        m["decoderHeldAtHoldFrame"] = d.heldAtHoldFrame
        m["decoderAnchorFrame"] = d.anchorFrame
        m["decoderSeekReanchorCount"] = d.seekReanchorCount
        m["decoderReanchorOk"] = d.reanchorOk
        m["decoderReanchorExecutedOnDecodeThread"] = d.reanchorExecutedOnDecodeThread
        m["decoderReanchorTransportStatePaused"] = d.reanchorTransportStatePaused
        m["decoderPreSeekAcceptedFrames"] = d.preSeekAcceptedFrames
        m["decoderStagedFramesClearedAtSeek"] = d.stagedFramesClearedAtSeek
        m["decoderCodecChunksAtSeek"] = d.codecChunksAtSeek
        m["decoderCodecChunks"] = d.codecChunks
        m["decoderSeekTargetFrame"] = d.seekTargetFrame
        m["decoderSeekTargetUs"] = d.seekTargetUs
        m["decoderSeekLandedUs"] = d.seekLandedUs
        m["decoderSeekReanchorWallMs"] = d.seekReanchorWallMs
        m["decoderMediaReopens"] = d.mediaReopens
        m["decoderStaleProbeCalls"] = d.staleProbeCalls
        m["decoderStaleProbeReason"] = d.staleProbeReason
        m["decoderStaleProbeReplyNull"] = d.staleProbeReplyNull
        m["decoderStaleProbeRejected"] = d.staleProbeRejected
        m["decoderStaleProbeAnchorUntouched"] = d.staleProbeAnchorUntouched
        m["decoderFirstPostSeekPtsUs"] = d.firstPostSeekPtsUs
        m["decoderFirstPostSeekFrame"] = d.firstPostSeekFrame
        m["decoderPostSeekAcceptedFrames"] = d.postSeekAcceptedFrames
        m["decoderPostSeekDecodedAcceptedFrames"] = d.postSeekDecodedAcceptedFrames
        m["decoderPostSeekPreRollFrames"] = d.postSeekPreRollFrames
        m["decoderPostSeekPreRollStatePaused"] = d.postSeekPreRollStatePaused
        m["decoderPostSeekPaddedFrames"] = d.postSeekPaddedFrames
        m["decoderGapObservedFrames"] = d.gapObservedFrames
        m["decoderGapPaddedFrames"] = d.gapPaddedFrames
        m["decoderMaxSeekGapFrames"] = d.maxSeekGapFrames
        m["decoderDiscardedPreTargetFrames"] = d.discardedPreTargetFrames
        m["decoderDiscardedFrames"] = d.discardedFrames
        m["decoderTruncatedFrames"] = d.truncatedFrames
        m["decoderStaleGenerationRetries"] = d.staleGenerationRetries
        m["decoderTransientRejects"] = d.transientRejects
    }

    private fun putReplyMetrics(m: LinkedHashMap<String, Any?>, prefix: String, r: VanguardRealtimePlaybackNativeSession.Reply?) {
        m["${prefix}NativeState"] = r?.stateToken ?: "none"
        m["${prefix}PositionFrame"] = r?.positionFrame ?: -1L
        m["${prefix}PushedFrames"] = r?.pushedFrames ?: -1L
        m["${prefix}DrainedFrames"] = r?.drainedFrames ?: -1L
        m["${prefix}DiscardedFrames"] = r?.discardedFrames ?: -1L
        m["${prefix}OutputAvailableReadFrames"] = r?.outputAvailableReadFrames ?: -1L
        m["${prefix}EosPushed"] = r?.eosPushed ?: false
        m["${prefix}EosDrained"] = r?.eosDrained ?: false
    }
}
