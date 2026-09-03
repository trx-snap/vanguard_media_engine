package com.connects.vanguard_media_engine.audio_playback_graph

import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply

// ── VanguardRealtimeAudioPlaybackClockCorrelation (P4-AUDIO-REALTIME-PLAYBACK-CLOCK-CORRELATION-OBSERVATION, Y15a) ─
//
// Read-only telemetry pairing the native worker-owned AudioClock's own
// position (Y15a native publication, [Reply.nativeClock*]) against the
// downstream [VanguardRealtimePlaybackPresentationClock] snapshot the sink
// publishes. This is an OBSERVATION seam only: it computes no correction
// and applies no feedback to either clock -- it is never on
// [VanguardRealtimeAudioPlaybackSession.currentPositionFrames]/
// [currentPositionUs]'s path, which remain the sole downstream
// presentation-clock authority. A large offset is reported as telemetry,
// never thrown.
data class VanguardRealtimeAudioPlaybackClockCorrelation(
    val nativeClockState: String,
    val nativePositionUs: Long,
    val nativePositionFrame: Long,
    val nativeDriftSampleCount: Long,
    val presentationProvenance: VanguardRealtimePlaybackPresentationClock.Provenance,
    val presentationPositionUs: Long,
    val presentationPositionFrames: Long,
    val presentationConsistent: Boolean,
    val offsetUs: Long,
    val offsetFrames: Long,
    // Reserved for later lanes (class comment): true whenever this factory
    // successfully paired a native reply with a presentation snapshot, i.e.
    // whenever an instance of this class exists at all.
    val nativeSnapshotPublishedOk: Boolean = true,
    val clockCorrelationTelemetryOk: Boolean = true,
    val clockObservationNoFeedbackOk: Boolean = true,
) {
    companion object {
        fun from(
            reply: Reply,
            presentation: VanguardRealtimePlaybackPresentationClock.Snapshot,
        ): VanguardRealtimeAudioPlaybackClockCorrelation = VanguardRealtimeAudioPlaybackClockCorrelation(
            nativeClockState = reply.nativeClockState,
            nativePositionUs = reply.nativeClockPositionUs,
            nativePositionFrame = reply.nativeClockPositionFrame,
            nativeDriftSampleCount = reply.nativeClockDriftSampleCount,
            presentationProvenance = presentation.provenance,
            presentationPositionUs = presentation.positionUs,
            presentationPositionFrames = presentation.positionFrames,
            presentationConsistent = presentation.consistent,
            offsetUs = presentation.positionUs - reply.nativeClockPositionUs,
            offsetFrames = presentation.positionFrames - reply.nativeClockPositionFrame,
        )
    }
}
