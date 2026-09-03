package com.connects.vanguard_media_engine.audio_playback_graph

// ── VanguardRealtimePlaybackDecoderSeekTypes (P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SEEK, Y9) ─
//
// Value types of [VanguardRealtimePlaybackDecoderFeed]'s single forward seek.
// Pure data: the feed's decode thread owns every state transition behind them.

// Coordinator-issued seek re-anchor request: the feed moves its anchor from
// `preSeekAnchorFrame` (the hold frame it is currently held at) to
// `targetFrame` and its pinned generation from `staleGeneration` to
// `newGeneration`. `index` is the zero-based serial position of this request
// among the up-to-two reanchors a single feed run accepts (0 = first, 1 =
// second); the feed only accepts a request whose `index` matches the count of
// reanchors already completed. `nextHoldFrame` is the next hold frame the
// feed idles at after this reanchor (Y10b-1a, default = no further hold, i.e.
// this is the final seek of the run).
data class VanguardRealtimePlaybackDecoderSeekRequest(
    val targetFrame: Long,
    val preSeekAnchorFrame: Long,
    val newGeneration: Long,
    val staleGeneration: Long,
    val index: Int = 0,
    val nextHoldFrame: Long = Long.MAX_VALUE,
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
