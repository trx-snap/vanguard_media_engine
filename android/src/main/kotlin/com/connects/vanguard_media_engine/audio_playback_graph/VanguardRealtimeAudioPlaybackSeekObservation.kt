package com.connects.vanguard_media_engine.audio_playback_graph

import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State as TransportState

// ── VanguardRealtimeAudioPlaybackSeekObservation (P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SEEK, Y9) ─
//
// Any-thread immutable view of the ONE forward seek (Y17: or the ONE
// backward seek) owned by [VanguardRealtimeAudioPlaybackSession], published
// through [VanguardRealtimeAudioPlaybackSession.Snapshot.seek]. The session's
// command-lock holder writes the underlying fields in the fixed seek order
// (see the session's class comment); defaults mean "seek not armed / not
// issued". Pure data: no lifecycle decision lives here.
data class VanguardRealtimeAudioPlaybackSeekObservation(
    val armed: Boolean,
    val targetFrame: Long,
    val holdFrame: Long,
    val admissionOk: Boolean,
    val holdPinned: Boolean,
    val seekCount: Int,
    val seekAccepted: Boolean,
    val staleGeneration: Long,
    val seekGeneration: Long,
    val pauseAccepted: Boolean,
    val pauseGeneration: Long,
    val resumeAccepted: Boolean,
    val resumeGeneration: Long,
    val initialWriteWaitMs: Long,
    val quiesceWaitMs: Long,
    val quiesceFeedHeld: Boolean,
    val quiesceSinkReadFrames: Long,
    val quiesceSinkWrittenFrames: Long,
    val quiesceAccountingOk: Boolean,
    val preSeekSettleMs: Long,
    // Native snapshot while the sink is PARKED and the transport still PLAYING.
    val preSeekReply: Reply?,
    val preSeekTransportState: TransportState?,
    val postPauseReply: Reply?,
    val flushRequestedWhilePaused: Boolean,
    val flushAckWaitMs: Long,
    val flushAckedBeforeSeek: Boolean,
    val sinkPhaseAtSeek: String,
    // Native snapshot right after transport.seek(T) (PAUSED, generation + 1).
    val postSeekReply: Reply?,
    val postSeekTransportState: TransportState?,
    val reanchorWaitMs: Long,
    val postSeekPreRollWaitMs: Long,
    // Native snapshot after the post-seek pre-roll, still PAUSED.
    val postSeekPreRollReply: Reply?,
    val postSeekPreRollTransportState: TransportState?,
    val transportStateAtUnpark: TransportState?,
    val parkRequestedAtMs: Long,
    val parkAckedAtMs: Long,
    val unparkedAtMs: Long,
    val resumedAtMs: Long,
    val holdObservedMs: Long,
    val seekWallMs: Long,
    val clockAtPark: VanguardRealtimePlaybackPresentationClock.Snapshot?,
    val clockBeforeUnpark: VanguardRealtimePlaybackPresentationClock.Snapshot?,
    val clockAfterUnpark: VanguardRealtimePlaybackPresentationClock.Snapshot?,
    val decoder: VanguardRealtimePlaybackDecoderSeekTelemetry?,
    // Y17: the armed seek is a backward seek (0 <= T <= H - 2 windows);
    // `declaredBackward` mirrors the direction the last issued seek was
    // declared with to the sink/feed (false on every forward run).
    val backward: Boolean = false,
    val declaredBackward: Boolean = false,
)
