package com.connects.vanguard_media_engine.audio_playback_graph

// ── VanguardRealtimePlaybackDecoderSeekTypes (P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SEEK, Y9) ─
//
// Value types of [VanguardRealtimePlaybackDecoderFeed]'s single forward seek.
// Pure data: the feed's decode thread owns every state transition behind them.

// Coordinator-issued seek re-anchor request (single use): the feed moves its
// anchor from `preSeekAnchorFrame` (the hold frame H) to `targetFrame` and its
// pinned generation from `staleGeneration` to `newGeneration`.
data class VanguardRealtimePlaybackDecoderSeekRequest(
    val targetFrame: Long,
    val preSeekAnchorFrame: Long,
    val newGeneration: Long,
    val staleGeneration: Long,
)

// Any-thread immutable view of the feed's seek telemetry (decode thread
// writes; defaults = no seek), returned by
// [VanguardRealtimePlaybackDecoderFeed.seekTelemetry].
data class VanguardRealtimePlaybackDecoderSeekTelemetry(
    val holdFrame: Long,
    val heldAtHoldFrame: Boolean,
    val anchorFrame: Long,
    val seekReanchorCount: Int,
    val reanchorOk: Boolean,
    val reanchorExecutedOnDecodeThread: Boolean,
    val reanchorTransportStatePaused: Boolean,
    val preSeekAcceptedFrames: Long,
    val stagedFramesClearedAtSeek: Long,
    val codecChunksAtSeek: Long,
    val codecChunks: Long,
    val seekTargetFrame: Long,
    val seekTargetUs: Long,
    val seekLandedUs: Long,
    val seekReanchorWallMs: Long,
    val mediaReopens: Int,
    val staleProbeCalls: Int,
    val staleProbeReason: String,
    val staleProbeReplyNull: Boolean,
    val staleProbeRejected: Boolean,
    val staleProbeAnchorUntouched: Boolean,
    val firstPostSeekPtsUs: Long,
    val firstPostSeekFrame: Long,
    val postSeekAcceptedFrames: Long,
    val postSeekDecodedAcceptedFrames: Long,
    val postSeekPreRollFrames: Long,
    val postSeekPreRollStatePaused: Boolean,
    val postSeekPaddedFrames: Long,
    val gapObservedFrames: Long,
    val gapPaddedFrames: Long,
    val maxSeekGapFrames: Long,
    val discardedPreTargetFrames: Long,
    val discardedFrames: Long,
    val truncatedFrames: Long,
    val acceptedFrames: Long,
    val paddedFrames: Long,
    val staleGenerationRetries: Long,
    val transientRejects: Long,
)
