package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackFrameSource
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

// ── AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource (P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER-RING-FRAME-SOURCE, Y18c) ─
//
// Diagnostics-owned implementation of the Y18a production seam
// [VanguardRealtimeAudioPlaybackFrameSource] that feeds the PRODUCTION
// [com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSinkBridge]
// from the existing async-runtime multi-source native OUTPUT RING
// ([AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession]) with a
// REAL Kotlin-owned MediaExtractor/MediaCodec synchronous PCM16 decode on
// track 0 and the deterministic synthetic PCM of
// [AndroidAsyncRuntimeQueueMultiSourceRealtimeClockIngestPump] on track 1,
// ingested in lockstep through that pump. It is the real-decoder sibling of
// the Y18b synthetic adapter [AndroidRealtimeAudioPlaybackRingTransportFrameSource]
// (which stays untouched and keeps its own scenario green). Neither the
// production [VanguardRealtimePlaybackDecoderFeed] nor
// [VanguardRealtimeAudioPlaybackSession] nor any native C++ is adapted: the
// production package sees only the seam.
//
// Ownership / threading:
//   - ONE ring-owner thread owns EVERY non-destroy native-session call, the
//     whole MediaExtractor/MediaCodec lifecycle (create, configure, start,
//     every dequeue/queue/release, stop, release) and the ingest pump. Codec
//     polling uses only the frozen very small bounded dequeue waits
//     ([DEQUEUE_TIMEOUT_US]); the owner services a pending sink drain BEFORE
//     and AFTER every decode/ingest step, and again from INSIDE the pump's
//     make-room callback while a lockstep chunk waits for source-ring room.
//   - [drain] is called on the SINK thread only: the sink's own direct
//     buffer is handed to the owner thread, which performs the destructive
//     read through [AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession.readOutputInto]
//     (the ONLY output-ring consumer path in this class: no
//     drainAvailableOutput(), no private output buffer, ever), and the sink
//     thread blocks for at most [Config.drainWaitBoundMs] (never the whole
//     run deadline); a timed-out drain is rejected with the typed reason
//     [REASON_DRAIN_WAIT_TIMEOUT] and fails the owner closed as a sink
//     failure. eosDrained is the NATIVE read-reply verdict, never
//     synthesized here. A drain never issues a transport command.
//   - The pump's make-room callback services exactly one pending sink drain
//     into the sink's buffer and returns the frames read; with no pending
//     drain it returns 0 and the pump sleeps/yields on its own.
//   - [postDriftSample] is sink-thread only and fire-and-forget; this ring
//     transport has no owner entry point that accepts a caller drift
//     sample, so every sample is rejected inline with
//     [REASON_DRIFT_UNSUPPORTED] (or stale_generation off [RING_GENERATION])
//     and never reaches native. Nothing feeds back.
//
// Geometry (frozen once at format probe, read by the coordinator through
// [frozenGeometry] BEFORE it constructs the production sink): output format
// PCM16 only, channel count 1..2, sample rate 8000..192000, and
// expectedFrames = floor(min(mediaDurationUs, maxDurationSec) * sampleRate /
// maxFramesPerMix) * maxFramesPerMix (window aligned).
//
// Checksum / frame model: streaming, lockstep, self-referential. For every
// accepted real decoded chunk the SAME frame count of synthetic track-1 PCM
// is ingested through the pump, which streams the Kotlin per-track accepted
// checksums and the clamp16(s0 + s1) reference mix BEFORE any frame crosses
// JNI. The chain asserted by the lane is: kotlin track0 == native track0,
// kotlin track1 == native track1, kotlin mix == native output-read checksum
// == production sink checksum. No cross-device bit-exact decoder claim.
//
// EOS: the decoded stream is TRUNCATED to expectedFrames (surplus counted as
// eosTruncatedFrames, never ingested) or PADDED with explicit Kotlin zero
// frames (counted as eosPadFrames, budget <= one second) when the decoder
// reaches EOS early; then the joint EOS is set through
// [AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession.tryCompleteTimelineAndSetEosWithoutDrain]
// WITHOUT draining, and the sink observes eosDrained through readOutputInto.
// Native provider zero-fill stays fail-closed inside that entry point.
//
// Terminal states publish typed telemetry ([Stage] + [Telemetry.stageTrace]
// + typed failure reasons): created, format_probe, geometry_frozen,
// session_created, pre_roll, transport_start, active_drain, eos_pad /
// eos_truncate, decoder_eos, eos_set_without_drain, decoder_failure,
// native_ring_failure, sink_failure, lockstep_failure, deadline / cancel,
// close_dispose, and retry/backpressure counters. Codec and extractor are
// released exactly once on every path (at decoder EOS, or in the owner's
// finally block).
//
// Y19 (P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER-RING-PAUSE-RESUME): exactly
// ONE bounded pause/resume cycle, requested from any non-owner thread and
// EXECUTED on the ring-owner thread through a control request/latch that
// mirrors [DrainRequest] ([quiesceFeedForPause], [pauseTransport],
// [assertPausedHoldFrozen], [resumeTransport]); the coordinator never
// touches the native X15 entry points itself. Rules:
//   - A pause is entered ONLY at a clean feed boundary: no staged slice
//     (pendingSliceFrames == 0), no latched pump lockstep chunk, no
//     dequeued codec output outstanding, and the timeline not yet fully
//     ingested; anything else fails closed with a typed reason
//     ([REASON_PAUSE_NOT_AT_CLEAN_BOUNDARY]).
//   - Physics: in steady state the owner lives INSIDE the pump's make-room
//     stall (source ring full) and only leaves it when a sink drain frees
//     output room; once the sink is parked no clean boundary can be reached
//     any more. [quiesceFeedForPause] therefore holds the feed at the NEXT
//     clean boundary while the sink is still draining (drains keep being
//     serviced, no decode/ingest, no EOS poll), so the scenario can park the
//     sink first and then pause the ring at that already-clean boundary.
//   - While ring-paused the owner loop runs NO feedStep and NO EOS poll: it
//     services control requests, deadline/cancel, and rejects any drain
//     inline ([REASON_DRAIN_WHILE_PAUSED], never a native read). The
//     scenario parks the sink first, so zero drains are expected during the
//     hold; any that arrive are counted as telemetry.
//   - Native pause / hold-frozen / resume proofs are the X15 owner-thread
//     entry points of the native session wrapper; their verdicts are folded
//     into [PauseResumeTelemetry] together with the Kotlin-side frame /
//     dispatch totals at pause, after the hold, and at resume.
//
// Y20 (P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER-RING-SEEK): exactly ONE
// true FORWARD content seek (target frame T strictly past the hold frame
// H, skipped = T - H > 0), requested from any non-owner thread and EXECUTED
// on the ring-owner thread through the same control request/latch
// ([quiesceFeedForSeek], [seekTransport]); the coordinator never touches
// the native seek entry points itself. Rules:
//   - [quiesceFeedForSeek] arms a FEED CAP at the window-aligned hold frame
//     H: the feed keeps running (drains serviced) but ingests no frame past
//     H; a staged codec slice straddling H is cut at H and its surplus is
//     discarded with honest accounting (seekHoldDiscardedStagedFrames: that
//     content lies inside the skipped span [H, T) and is never checksummed).
//     Once the pump has committed exactly H frames at a clean boundary the
//     feed is held (quiesced: drains still serviced, no decode / ingest /
//     EOS poll) and the request completes. H must be above the native
//     one-second timing gate (the worker rejects a Seek before it closes).
//   - The scenario then lets the PRODUCTION sink drain every pushed frame
//     (totalOutputFramesRead == H: the sink is the sole output consumer;
//     this class never drains privately), seek-parks and flushes the sink,
//     and only then requests [seekTransport]. On the owner thread the seek
//     proves native quiescence at H snapshot-only, posts + awaits the native
//     joint seek to T (skipped == T - H asserted from the worker's
//     seek-aware accounting), re-anchors the synthetic generator on the
//     pump's accepted-count axis, re-anchors the MediaExtractor
//     (SEEK_TO_PREVIOUS_SYNC, landing pts at or before T reported as
//     telemetry) and flushes the MediaCodec, discards decoded frames whose
//     pts lie before T (counted, budgeted), prefills the post-seek lockstep
//     source rings with drains forbidden (the pending output ack survives),
//     consumes the output seek ack with an ACK-ONLY read (zero discard
//     asserted: the ring was empty), releases the feed gate and completes.
//   - From the seek on the EFFECTIVE expected frames are expectedFrames -
//     skipped (== the native expectedPlayableFrameCount): the feed
//     truncates / pads / completes against that count, the joint EOS is
//     set at that count, and the final checksum chain is asserted over
//     exactly those frames. This class never claims the original
//     expectedFrames were pushed after a true skip.
//   - While the seek executes, sink drains are rejected inline
//     ([REASON_DRAIN_DURING_SEEK], never a native read); the scenario keeps
//     the sink parked across the seek, so zero such rejections are expected.
//
// Honest non-claims: diagnostic real-decoder ring frame-source proof only.
// No feedback control loop, no pacing correction, no resampling, no
// currentPosition authority switch, no A/V sync closure, no exact keyframe
// landing claim (extractor landing is media-local, at or before T), no
// product/editor/app/ConnectsApp/iOS/streaming/cache, no fleet claim, no
// change to the sink, the seam, the production feed, the session, or any
// X4..X15 entry point.
class AndroidRealtimeAudioPlaybackRealDecoderRingTransportFrameSource(
    private val config: Config,
) : VanguardRealtimeAudioPlaybackFrameSource {

    data class Config(
        // Local media file (MediaExtractor.setDataSource(path)); no streaming.
        val sourcePath: String,
        // Upper bound on the decoded window; the media duration may be shorter.
        val maxDurationSec: Double,
        val maxFramesPerMix: Int,
        val sourceRingCapacityFrames: Int = DEFAULT_SOURCE_RING_CAPACITY_FRAMES,
        val outputRingCapacityFrames: Int = DEFAULT_OUTPUT_RING_CAPACITY_FRAMES,
        // Absolute SystemClock.elapsedRealtime() deadline shared with the sink.
        val deadlineAtMs: Long,
        // Per-drain wait bound on the sink thread (class comment); must stay
        // below the sink's own drain-stall budget so the sink never stalls first.
        val drainWaitBoundMs: Long = DEFAULT_DRAIN_WAIT_BOUND_MS,
        val threadName: String = "VanguardY18cRealRingOwner",
    )

    enum class Stage {
        CREATED, OPENING, FORMAT_PROBE, GEOMETRY_FROZEN, SESSION_CREATED, PRE_ROLL, READY,
        TRANSPORT_START, ACTIVE_DRAIN, PAUSED, SEEKING, DECODER_EOS, EOS_SET, CLOSING, CLOSED, FAILED,
    }

    class FailClosed(val reason: String) : Exception(reason)

    // Frozen at format probe; the coordinator builds the production sink from it.
    data class Geometry(
        val sourceMime: String,
        val sourceTrackIndex: Int,
        val sourceDurationUs: Long,
        val declaredWindowUs: Long,
        val sampleRate: Int,
        val channelCount: Int,
        val pcmEncoding: Int,
        val maxFramesPerMix: Int,
        val expectedFrames: Long,
        val padBudgetFrames: Long,
        val inputEndUs: Long,
    )

    // Decoder-side facts (owner thread writes).
    data class DecoderTelemetry(
        val formatResolved: Boolean,
        val midStreamFormatChanges: Long,
        val decodeSteps: Long,
        val tryAgainSteps: Long,
        val inputSamplesQueued: Long,
        val inputEosQueued: Boolean,
        val outputEosReached: Boolean,
        val decoderChunks: Long,
        val framesDecoded: Long,
        val framesIngestedReal: Long,
        val eosPadFrames: Long,
        val eosPadChunks: Long,
        val eosTruncatedFrames: Long,
        val padBudgetFrames: Long,
        val ingestComplete: Boolean,
        val sliceGrowths: Long,
        val codecCallsOffOwnerThread: Long,
        val mediaReleaseCount: Int,
        val codecReleaseCount: Int,
        val extractorReleaseCount: Int,
        val mediaReleaseClean: Boolean,
        val mediaReleasedAtDecoderEos: Boolean,
    )

    // Y19 pause/resume cycle facts (owner thread writes, requester-side
    // counters are atomics). Every "AtPause" / "AfterHold" / "AtResume"
    // total is captured on the owner thread right after the corresponding
    // native proof returned; -1 / false means "never reached".
    data class PauseResumeTelemetry(
        // Requester-side control accounting (any thread).
        val quiesceRequests: Long,
        val pauseRequests: Long,
        val holdAssertRequests: Long,
        val resumeRequests: Long,
        val controlRequestsOnOwnerThread: Long,
        val controlOverlapRejects: Long,
        val controlWaitTimeouts: Long,
        val lastControlTimeoutKind: String,
        val lastControlRejectReason: String,
        // Pre-park feed quiesce (hold at the next clean boundary).
        val quiesceAckOk: Boolean,
        val quiesceExecutedOnOwnerThread: Boolean,
        val quiesceWallMs: Long,
        val feedStepsWhileQuiesced: Long,
        // Pause (native Pause command + processed-snapshot proof).
        val pauseAckOk: Boolean,
        val pauseExecutedOnOwnerThread: Boolean,
        val pauseQuiescedFirst: Boolean,
        val pauseCleanBoundaryOk: Boolean,
        val pausePendingSliceFramesAtRequest: Int,
        val pausePumpPendingChunkAtRequest: Boolean,
        val pauseCodecOutputHeldAtRequest: Boolean,
        val pauseIngestCompleteAtRequest: Boolean,
        val nativePauseProofOk: Boolean,
        val pauseCommandSeq: Long,
        val pauseWallMs: Long,
        val dispatchCountAtPause: Long,
        val totalFramesPushedAtPause: Long,
        val nextDispatchFrameAtPause: Long,
        val framesPendingAtPause: Long,
        val pausedWaitsAtPause: Long,
        val framesReadBySinkAtPause: Long,
        val drainsServicedAtPause: Long,
        val pumpFramesAcceptedAtPause: Long,
        val framesAcceptedTrack0AtPause: Long,
        val framesAcceptedTrack1AtPause: Long,
        val framesDecodedAtPause: Long,
        val stageBeforePause: String,
        // Paused hold (snapshot-only frozen proof).
        val holdAssertAckOk: Boolean,
        val holdAssertExecutedOnOwnerThread: Boolean,
        val nativeHoldFrozenProofOk: Boolean,
        val holdAssertObservedNs: Long,
        val dispatchCountAfterHold: Long,
        val totalFramesPushedAfterHold: Long,
        val pausedWaitsAfterHold: Long,
        val framesReadBySinkAfterHold: Long,
        val drainsServicedAfterHold: Long,
        val pumpFramesAcceptedAfterHold: Long,
        // Owner-loop activity while paused (all structurally zero).
        val ownerLoopIterationsWhilePaused: Long,
        val feedStepsWhilePaused: Long,
        val eosPollsWhilePaused: Long,
        val decodeStepsWhilePaused: Long,
        val makeRoomCallbacksWhilePaused: Long,
        val pausedDrainRejectsSinkThread: Long,
        val pausedDrainRejectsOwnerThread: Long,
        // Resume (native Resume command + processed-snapshot proof).
        val resumeAckOk: Boolean,
        val resumeExecutedOnOwnerThread: Boolean,
        val nativeResumeProofOk: Boolean,
        val resumeCommandSeq: Long,
        val resumeWallMs: Long,
        val dispatchCountAtResume: Long,
        val totalFramesPushedAtResume: Long,
        val nativeLastPausedIntervalNs: Long,
        val nativeTotalPausedNs: Long,
        val pauseHoldObservedNs: Long,
        val pauseHoldObservedMs: Long,
        val framesReadBySinkAtResume: Long,
        val pumpFramesAcceptedAtResume: Long,
        val stageAfterResume: String,
    )

    // Y20 seek facts, part 1: requester-side control accounting, the feed
    // hold at H, and the owner-executed native seek (owner thread writes;
    // requester counters are atomics). -1 / false means "never reached".
    data class SeekTelemetry(
        val seekQuiesceRequests: Long,
        val seekRequests: Long,
        val seekDrainRejectsSinkThread: Long,
        val seekDrainRejectsOwnerThread: Long,
        // Feed hold at the window-aligned hold frame H.
        val holdFrame: Long,
        val holdArmed: Boolean,
        val holdArmedOnOwnerThread: Boolean,
        val holdCommittedFramesAtArm: Long,
        val holdReached: Boolean,
        val holdAckOk: Boolean,
        val holdExecutedOnOwnerThread: Boolean,
        val holdWallMs: Long,
        val holdDiscardedStagedFrames: Long,
        val feedStepsWhileHeld: Long,
        val framesReadBySinkAtHold: Long,
        val drainsServicedAtHold: Long,
        val framesAcceptedTrack0AtHold: Long,
        val framesAcceptedTrack1AtHold: Long,
        val framesDecodedAtHold: Long,
        val decodeStepsAtHold: Long,
        // Owner-executed seek to T.
        val seekExercised: Boolean,
        val seekAckOk: Boolean,
        val seekExecutedOnOwnerThread: Boolean,
        val seekWallMs: Long,
        val seekTargetFrame: Long,
        val seekSkipFrames: Long,
        val seekQuiescedFirst: Boolean,
        val seekCleanBoundaryOk: Boolean,
        val seekPendingSliceFramesAtRequest: Int,
        val seekPumpPendingChunkAtRequest: Boolean,
        val seekCodecOutputHeldAtRequest: Boolean,
        val seekIngestCompleteAtRequest: Boolean,
        val seekPausedAtRequest: Boolean,
        val framesReadBySinkAtSeek: Long,
        val drainsServicedAtSeek: Long,
        val drainsServicedDuringSeek: Long,
        val stageBeforeSeek: String,
        val stageAfterSeek: String,
        // Native pre-seek quiescence proof (snapshot-only, no private drain).
        val nativeQuiescentProofOk: Boolean,
        val nativeQuiescentTotalFramesPushed: Long,
        val nativeQuiescentNextDispatchFrame: Long,
        val nativeQuiescentOutputAvailableReadFrames: Long,
        val nativeQuiescentTimingT1Ns: Long,
        // Native seek command + processed-snapshot facts.
        val nativeSeekCommandSeq: Long,
        val nativeSeekRequestedPtsUs: Long,
        val nativeSeekReplyTargetFrame: Long,
        val nativeSeekTransientRetries: Long,
        val nativeSeekProcessedOk: Boolean,
        val nativeSkippedFramesAtSeek: Long,
        val nativeExpectedPlayableAtSeek: Long,
        val nativeSeekSkipAnomaliesAtSeek: Long,
        val nativeNextDispatchFrameAtSeek: Long,
        // Provider external re-anchor at the processed-Seek snapshot
        // (P4-AUDIO-SEEK-PROVIDER-COORDINATOR-REANCHOR): the worker consumed
        // both source acks itself, so it must have re-anchored BOTH
        // RingBufferAudioSampleProviders to T (count exactly 1, frame == T,
        // expected next frame == T) before any post-seek dispatch.
        val nativeProviderExternalReanchorCountAtSeekTrack0: Long,
        val nativeProviderExternalReanchorCountAtSeekTrack1: Long,
        val nativeProviderLastExternalReanchorFrameAtSeekTrack0: Long,
        val nativeProviderLastExternalReanchorFrameAtSeekTrack1: Long,
        val nativeProviderExpectedNextFrameAtSeekTrack0: Long,
        val nativeProviderExpectedNextFrameAtSeekTrack1: Long,
        val effectiveExpectedFrames: Long,
        // Output seek ack (ack-only read on the owner thread).
        val seekAckConsumedByAckOnlyRead: Boolean,
        val seekAckNewStartFrame: Long,
        val seekAckDiscardedFrames: Long,
        val seekAckTotalDiscardedOnSeekFrames: Long,
        val seekAckWallMs: Long,
    )

    // Y20 seek facts, part 2: the media re-anchor, the post-seek prefill,
    // the synthetic generator re-anchor and the FINAL native seek-aware
    // accounting (folded from the final snapshot).
    data class SeekReanchorTelemetry(
        val extractorSeekCalls: Long,
        val codecFlushCalls: Long,
        val extractorReanchoredOnOwnerThread: Boolean,
        val seekTargetUs: Long,
        val seekLandingPtsUs: Long,
        val seekLandingLeadUs: Long,
        val seekLandingAtOrBeforeTarget: Boolean,
        val preTargetDiscardedFrames: Long,
        val preTargetDiscardBudgetFrames: Long,
        val firstPostSeekChunkPtsUs: Long,
        val firstIngestedPostSeekPtsUs: Long,
        val inputEosAtSeek: Boolean,
        val outputEosAtSeek: Boolean,
        val generatorReanchorCount: Long,
        val generatorReanchorFrame: Long,
        val generatorAxis: String,
        // Post-seek lockstep prefill (drains forbidden) before the ack.
        val postSeekPrefillQuotaFrames: Long,
        val postSeekPrefillFeedSteps: Long,
        val postSeekPrefillCommittedFrames: Long,
        val postSeekPrefillAcceptedFrames: Long,
        val postSeekPrefillStalled: Boolean,
        val postSeekPrefillWallMs: Long,
        val postSeekFramesReadBySink: Long,
        // Final native seek-aware accounting (final snapshot).
        val nativeExpectedPlayableFrameCount: Long,
        val nativeTotalForwardSeekSkippedFrames: Long,
        val nativeTotalDiscardedOnSeekFrames: Long,
        val nativeSeekSkipAnomalies: Long,
        val nativeNextDispatchFrame: Long,
        val nativeOutputSeekRequest: Long,
        val nativeOutputSeekAck: Long,
        val nativeSourceSeekRequestTrack0: Long,
        val nativeSourceSeekAckTrack0: Long,
        val nativeSourceSeekRequestTrack1: Long,
        val nativeSourceSeekAckTrack1: Long,
        val nativeWriterNextWriteFrameTrack0: Long,
        val nativeWriterNextWriteFrameTrack1: Long,
        val nativeTimingT1Ns: Long,
        // Final provider facts (final snapshot): the one external re-anchor
        // per track landed at T and no provider ever forward-skipped or
        // rejected a rewind over the whole run (the shared NativeTelemetry
        // already carries zero-fill / underrun).
        val nativeProviderExternalReanchorCountTrack0: Long,
        val nativeProviderExternalReanchorCountTrack1: Long,
        val nativeProviderLastExternalReanchorFrameTrack0: Long,
        val nativeProviderLastExternalReanchorFrameTrack1: Long,
        val nativeProviderForwardSkipFramesTrack0: Long,
        val nativeProviderForwardSkipFramesTrack1: Long,
        val nativeProviderRewindRejectsTrack0: Long,
        val nativeProviderRewindRejectsTrack1: Long,
        val expectedPlayableFrameCountAtEos: Long,
        val totalForwardSeekSkippedFramesAtEos: Long,
    )

    // Adapter-side facts (owner thread + sink thread counters). The folded
    // final native snapshot reuses the Y18b [AndroidRealtimeAudioPlaybackRingTransportFrameSource.NativeTelemetry]
    // shape so the evaluator reads one native fact type for both ring routes.
    // Y20: [effectiveExpectedFrames] is the seek-aware expected frame count
    // (expectedFrames - skipped; == expectedFrames without a seek) every
    // accounting identity below is asserted against.
    data class Telemetry(
        val stage: Stage,
        val stageTrace: String,
        val failureReason: String,
        val ownerThreadId: Long,
        val sinkThreadIdObserved: Long,
        val drainCallsFromSink: Long,
        val drainCallsOnOwnerThread: Long,
        val drainCallsOnOtherThreads: Long,
        val drainOverlapRejects: Long,
        val drainsBeforeStartRejected: Long,
        val drainsServiced: Long,
        val drainsServicedFromMakeRoom: Long,
        val drainsAfterCloseRejected: Long,
        val drainWaitBoundMs: Long,
        val drainWaitTimeouts: Long,
        val lastDrainTimeoutWaitMs: Long,
        val maxDrainServiceLatencyMs: Long,
        val drainLatencyBoundViolations: Long,
        val framesReadBySink: Long,
        val emptyReadsServiced: Long,
        val outputSinkAccountedFrames: Long,
        val outputSinkCallbacks: Long,
        val outputSinkCallbacksOffOwner: Long,
        val privateOutputDrains: Long,
        val totalOutputFramesRead: Long,
        val nativeOutputReadChecksumHex: String,
        val kotlinReferenceMixChecksumHex: String,
        val kotlinTrack0ChecksumHex: String,
        val kotlinTrack1ChecksumHex: String,
        val nativeAcceptedChecksumHexTrack0: String,
        val nativeAcceptedChecksumHexTrack1: String,
        val pumpFramesAccepted: Long,
        val framesAcceptedTrack0: Long,
        val framesAcceptedTrack1: Long,
        val track0NonZeroSampleCount: Long,
        val track1NonZeroSampleCount: Long,
        val checksumChainSelfOk: Boolean,
        val preStartFillFrames: Long,
        val transportCommandsIssued: Long,
        val transportCommandsFromDrain: Long,
        val eosSetWithoutDrain: Boolean,
        val totalFramesPushedAtEos: Long,
        val eosDrainedObservedByRing: Boolean,
        val eosPollSnapshots: Long,
        val driftSamplesPosted: Long,
        val driftSamplesRejectedUnsupported: Long,
        val driftSamplesRejectedStale: Long,
        val destroyJoinOk: Boolean,
        val destroyIdempotentOk: Boolean,
        val makeRoomCallbacks: Long,
        val makeRoomIdleReturns: Long,
        val writerBackpressureRejects: Long,
        val openWallMs: Long,
        val formatProbeWallMs: Long,
        val prefillWallMs: Long,
        val startWallMs: Long,
        val ownerLoopWallMs: Long,
        val ownerLoopIterations: Long,
        val geometry: Geometry?,
        val decoder: DecoderTelemetry,
        val native: AndroidRealtimeAudioPlaybackRingTransportFrameSource.NativeTelemetry?,
        val pauseResume: PauseResumeTelemetry,
        val effectiveExpectedFrames: Long,
        val seek: SeekTelemetry,
        val seekReanchor: SeekReanchorTelemetry,
    )

    companion object {
        // Fixed transport generation of this ring route (no start/seek bump).
        const val RING_GENERATION = 1L
        const val REASON_OK = VanguardRealtimePlaybackTransportStateMachine.REASON_OK
        const val REASON_DRIFT_UNSUPPORTED =
            VanguardRealtimePlaybackTransportStateMachine.REASON_DRIFT_PREFIX + "real_decoder_ring_transport_unsupported"
        const val DEFAULT_SOURCE_RING_CAPACITY_FRAMES = 8_192
        const val DEFAULT_OUTPUT_RING_CAPACITY_FRAMES = 4_096
        const val DEFAULT_DRAIN_WAIT_BOUND_MS = 1_000L
        const val TRACK_COUNT = 2
        // Explicit Kotlin zero-pad budget at decoder EOS: at most one second.
        const val EOS_PAD_BUDGET_SEC = 1.0

        // Typed terminal reasons (prefixes carry the underlying detail).
        const val REASON_DEADLINE = "deadline_exceeded"
        const val REASON_CANCELLED = "cancelled"
        const val REASON_PREFIX_DECODER = "decoder_failure:"
        const val REASON_PREFIX_NATIVE = "native_ring_failure:"
        const val REASON_PREFIX_SINK = "sink_failure:"
        const val REASON_PREFIX_LOCKSTEP = "lockstep_failure:"
        const val REASON_EOS_PAD_BUDGET = "eos_pad_budget_exceeded"
        const val REASON_DRAIN_WAIT_TIMEOUT = "real_ring_drain_wait_timeout"
        const val REASON_DRAIN_BEFORE_START = "real_ring_drain_before_start"
        // Y19 typed control / pause reasons.
        const val REASON_DRAIN_WHILE_PAUSED = "real_ring_drain_while_paused"
        const val REASON_CONTROL_BEFORE_START = "real_ring_control_before_start"
        const val REASON_QUIESCE_AFTER_INGEST_COMPLETE = "real_ring_quiesce_after_ingest_complete"
        const val REASON_PAUSE_NOT_AT_CLEAN_BOUNDARY = "real_ring_pause_not_at_clean_boundary:"
        const val REASON_PAUSE_ALREADY_EXERCISED = "real_ring_pause_already_exercised"
        const val REASON_HOLD_ASSERT_NOT_PAUSED = "real_ring_hold_assert_not_paused"
        const val REASON_HOLD_ASSERT_ALREADY_EXERCISED = "real_ring_hold_assert_already_exercised"
        const val REASON_RESUME_NOT_PAUSED = "real_ring_resume_not_paused"
        const val REASON_RESUME_BEFORE_HOLD_ASSERT = "real_ring_resume_before_hold_assert"
        const val REASON_RESUME_ALREADY_EXERCISED = "real_ring_resume_already_exercised"
        const val REASON_CONTROL_CLOSED = "real_ring_control_closed"
        // Y20 typed seek reasons.
        const val REASON_DRAIN_DURING_SEEK = "real_ring_drain_during_seek"
        const val REASON_SEEK_HOLD_INVALID = "real_ring_seek_hold_invalid:"
        const val REASON_SEEK_HOLD_ALREADY_HELD = "real_ring_seek_hold_already_held"
        const val REASON_SEEK_HOLD_ALREADY_PASSED = "real_ring_seek_hold_already_passed:"
        const val REASON_SEEK_HOLD_AFTER_INGEST_COMPLETE = "real_ring_seek_hold_after_ingest_complete"
        const val REASON_SEEK_NOT_HELD = "real_ring_seek_not_held"
        const val REASON_SEEK_NOT_AT_CLEAN_BOUNDARY = "real_ring_seek_not_at_clean_boundary:"
        const val REASON_SEEK_ALREADY_EXERCISED = "real_ring_seek_already_exercised"
        const val REASON_SEEK_WHILE_PAUSED = "real_ring_seek_while_paused"
        const val REASON_SEEK_TARGET_INVALID = "real_ring_seek_target_invalid:"
        const val REASON_SEEK_SINK_NOT_DRAINED_TO_HOLD = "real_ring_seek_sink_not_drained_to_hold:"
        const val REASON_SEEK_AFTER_DECODER_EOS = "real_ring_seek_after_decoder_eos"
        const val REASON_SEEK_LANDING_UNAVAILABLE = "real_ring_seek_landing_unavailable"
        const val REASON_SEEK_PREFILL_EMPTY = "real_ring_seek_post_seek_prefill_empty"
        const val REASON_SEEK_SKIP_BELOW_DISCARDED = "real_ring_seek_skip_below_discarded_staged:"
        const val REASON_SEEK_EFFECTIVE_FRAMES_MISMATCH = "real_ring_seek_effective_frames_mismatch:"
        // Native worker timing gate floor (kTimingWarmupFrames): the worker
        // closes its one-second gate only once the dispatch cursor passed
        // ceil(8192 / window) * window + sampleRate frames, and rejects a
        // Seek command before that. Exposed so a scenario can derive a
        // valid hold frame from the frozen geometry instead of guessing.
        const val NATIVE_TIMING_WARMUP_FRAMES = 8_192L
        const val GENERATOR_AXIS_ACCEPTED_COUNT = "pump_accepted_count_axis"

        // Frozen X3/X4 decode dequeue timeout: the owner returns to drain work quickly.
        private const val DEQUEUE_TIMEOUT_US = 2_000L
        // Input is fed slightly past the declared window so the decoder can
        // reach EOS with the whole window decoded; surplus is truncated.
        private const val END_INPUT_MARGIN_US = 50_000L
        // Matches the native per-call ingest clamp (AudioDecoderRingWriter kMaxWriteFrames).
        private const val STAGING_SLICE_FRAMES = 8_192
        private const val OWNER_IDLE_WAIT_MS = 1L
        private const val EOS_POLL_INTERVAL_MS = 4L
        private const val JOIN_SLACK_MS = 2_000L
    }

    private class DrainRequest(val dst: ByteBuffer, val maxFrames: Int, val enqueuedAtMs: Long) {
        val latch = CountDownLatch(1)
        @Volatile var result: VanguardRealtimeAudioPlaybackFrameSource.DrainResult? = null
    }

    // Y19 owner-executed control request (same request/latch shape as
    // [DrainRequest]): at most one pending at a time, executed in order
    // QUIESCE -> PAUSE -> HOLD_ASSERT -> RESUME, each at most once. Y20
    // adds QUIESCE_FOR_SEEK (feed cap at the hold frame, completes once the
    // feed is held there) and SEEK (the one owner-executed forward seek).
    private enum class Control { QUIESCE, PAUSE, HOLD_ASSERT, RESUME, QUIESCE_FOR_SEEK, SEEK }

    private class ControlRequest(val kind: Control, val enqueuedAtMs: Long, val frame: Long = -1L) {
        val latch = CountDownLatch(1)
        @Volatile var ok = false
        @Volatile var reason = ""
    }

    // HELD (Y20): the feed reached the armed seek hold frame at a clean
    // boundary and ingests nothing further until the seek executes.
    private enum class Feed { PROGRESSED, RETRY, STALLED, IDLE, HELD }

    // ── Cross-thread control ───────────────────────────────────────────────

    private val opened = AtomicBoolean(false)
    private val stopRequested = AtomicBoolean(false)
    private val startRequested = AtomicBoolean(false)
    private val readyLatch = CountDownLatch(1)
    private val startLatch = CountDownLatch(1)
    private val closedLatch = CountDownLatch(1)
    private val requestLock = ReentrantLock()
    private val requestCondition = requestLock.newCondition()
    // Guarded by requestLock. acceptingRequests flips false exactly once, by
    // the owner thread in its finally block.
    private var pendingDrain: DrainRequest? = null
    private var pendingControl: ControlRequest? = null
    private var acceptingRequests = true
    @Volatile private var ownerThread: Thread? = null
    @Volatile private var ownerThreadId = -1L
    @Volatile private var stage = Stage.CREATED
    @Volatile private var stageTrace = "created"
    @Volatile private var failureReason = ""
    @Volatile private var started = false
    // Y19 owner-thread pause gate (volatile: the sink thread rejects drains
    // inline while paused; the coordinator reads the flags for its ordering
    // metrics). Written on the owner thread only.
    @Volatile private var quiesced = false
    @Volatile private var paused = false

    // ── Y19 control-request telemetry (requester side: atomics) ───────────

    private val quiesceRequests = AtomicLong(0L)
    private val pauseRequests = AtomicLong(0L)
    private val holdAssertRequests = AtomicLong(0L)
    private val resumeRequests = AtomicLong(0L)
    private val controlRequestsOnOwnerThread = AtomicLong(0L)
    private val controlOverlapRejects = AtomicLong(0L)
    private val controlWaitTimeouts = AtomicLong(0L)
    private val pausedDrainRejectsSinkThread = AtomicLong(0L)
    @Volatile private var lastControlTimeoutKind = ""
    @Volatile private var lastControlRejectReason = ""

    // ── Y19 pause/resume facts (owner thread writes) ───────────────────────

    @Volatile private var quiesceAckOk = false
    @Volatile private var quiesceExecutedOnOwnerThread = false
    @Volatile private var quiesceWallMs = -1L
    @Volatile private var feedStepsWhileQuiesced = 0L
    @Volatile private var pauseExercised = false
    @Volatile private var pauseAckOk = false
    @Volatile private var pauseExecutedOnOwnerThread = false
    @Volatile private var pauseQuiescedFirst = false
    @Volatile private var pauseCleanBoundaryOk = false
    @Volatile private var pausePendingSliceFramesAtRequest = -1
    @Volatile private var pausePumpPendingChunkAtRequest = false
    @Volatile private var pauseCodecOutputHeldAtRequest = false
    @Volatile private var pauseIngestCompleteAtRequest = false
    @Volatile private var nativePauseProofOk = false
    @Volatile private var pauseCommandSeq = -1L
    @Volatile private var pauseWallMs = -1L
    @Volatile private var dispatchCountAtPause = -1L
    @Volatile private var totalFramesPushedAtPause = -1L
    @Volatile private var nextDispatchFrameAtPause = -1L
    @Volatile private var framesPendingAtPause = -1L
    @Volatile private var pausedWaitsAtPause = -1L
    @Volatile private var framesReadBySinkAtPause = -1L
    @Volatile private var drainsServicedAtPause = -1L
    @Volatile private var pumpFramesAcceptedAtPause = -1L
    @Volatile private var framesAcceptedTrack0AtPause = -1L
    @Volatile private var framesAcceptedTrack1AtPause = -1L
    @Volatile private var framesDecodedAtPause = -1L
    @Volatile private var decodeStepsAtPause = -1L
    @Volatile private var stageBeforePause: Stage? = null
    private var pausedAtNs = -1L
    @Volatile private var holdAssertExercised = false
    @Volatile private var holdAssertAckOk = false
    @Volatile private var holdAssertExecutedOnOwnerThread = false
    @Volatile private var nativeHoldFrozenProofOk = false
    @Volatile private var holdAssertObservedNs = -1L
    @Volatile private var dispatchCountAfterHold = -1L
    @Volatile private var totalFramesPushedAfterHold = -1L
    @Volatile private var pausedWaitsAfterHold = -1L
    @Volatile private var framesReadBySinkAfterHold = -1L
    @Volatile private var drainsServicedAfterHold = -1L
    @Volatile private var pumpFramesAcceptedAfterHold = -1L
    @Volatile private var ownerLoopIterationsWhilePaused = 0L
    @Volatile private var feedStepsWhilePaused = 0L
    @Volatile private var eosPollsWhilePaused = 0L
    @Volatile private var decodeStepsWhilePaused = -1L
    @Volatile private var makeRoomCallbacksWhilePaused = 0L
    @Volatile private var pausedDrainRejectsOwnerThread = 0L
    @Volatile private var resumeExercised = false
    @Volatile private var resumeAckOk = false
    @Volatile private var resumeExecutedOnOwnerThread = false
    @Volatile private var nativeResumeProofOk = false
    @Volatile private var resumeCommandSeq = -1L
    @Volatile private var resumeWallMs = -1L
    @Volatile private var dispatchCountAtResume = -1L
    @Volatile private var totalFramesPushedAtResume = -1L
    @Volatile private var nativeLastPausedIntervalNs = -1L
    @Volatile private var nativeTotalPausedNs = -1L
    @Volatile private var pauseHoldObservedNs = -1L
    @Volatile private var framesReadBySinkAtResume = -1L
    @Volatile private var pumpFramesAcceptedAtResume = -1L
    @Volatile private var stageAfterResume: Stage? = null
    // True only between MediaCodec.getOutputBuffer and releaseOutputBuffer
    // inside [decodeStep]; a clean boundary requires it false.
    @Volatile private var codecOutputHeld = false

    // ── Y20 seek control telemetry (requester side: atomics) ──────────────

    private val seekQuiesceRequests = AtomicLong(0L)
    private val seekRequests = AtomicLong(0L)
    private val seekDrainRejectsSinkThread = AtomicLong(0L)

    // ── Y20 seek facts (owner thread writes) ───────────────────────────────

    // Seek-aware expected frames: expectedFrames until the one forward seek
    // is processed, expectedFrames - skipped afterwards (owner writes).
    @Volatile private var effectiveExpectedFrames = 0L
    // Feed cap / hold gate (owner thread only; volatile for telemetry).
    @Volatile private var seekHoldFrame = -1L
    @Volatile private var seekHoldArmed = false
    @Volatile private var seekHoldArmedOnOwnerThread = false
    @Volatile private var seekHoldCommittedFramesAtArm = -1L
    @Volatile private var seekHoldReached = false
    @Volatile private var seekHoldAckOk = false
    @Volatile private var seekHoldExecutedOnOwnerThread = false
    @Volatile private var seekHoldWallMs = -1L
    @Volatile private var seekHoldDiscardedStagedFrames = 0L
    @Volatile private var feedStepsWhileHeld = 0L
    @Volatile private var framesReadBySinkAtHold = -1L
    @Volatile private var drainsServicedAtHold = -1L
    @Volatile private var framesAcceptedTrack0AtHold = -1L
    @Volatile private var framesAcceptedTrack1AtHold = -1L
    @Volatile private var framesDecodedAtHold = -1L
    @Volatile private var decodeStepsAtHold = -1L
    // Owner-executed seek.
    @Volatile private var seekInProgress = false
    @Volatile private var seekExercised = false
    @Volatile private var seekAckOk = false
    @Volatile private var seekExecutedOnOwnerThread = false
    @Volatile private var seekWallMs = -1L
    @Volatile private var seekTargetFrame = -1L
    @Volatile private var seekSkipFrames = -1L
    @Volatile private var seekQuiescedFirst = false
    @Volatile private var seekCleanBoundaryOk = false
    @Volatile private var seekPendingSliceFramesAtRequest = -1
    @Volatile private var seekPumpPendingChunkAtRequest = false
    @Volatile private var seekCodecOutputHeldAtRequest = false
    @Volatile private var seekIngestCompleteAtRequest = false
    @Volatile private var seekPausedAtRequest = false
    @Volatile private var framesReadBySinkAtSeek = -1L
    @Volatile private var drainsServicedAtSeek = -1L
    @Volatile private var drainsServicedDuringSeek = 0L
    @Volatile private var seekDrainRejectsOwnerThread = 0L
    @Volatile private var stageBeforeSeek: Stage? = null
    @Volatile private var stageAfterSeek: Stage? = null
    @Volatile private var seekAckWallMs = -1L
    // Media re-anchor.
    @Volatile private var extractorSeekCalls = 0L
    @Volatile private var codecFlushCalls = 0L
    @Volatile private var extractorReanchoredOnOwnerThread = false
    @Volatile private var seekTargetUs = -1L
    @Volatile private var seekLandingPtsUs = -1L
    @Volatile private var seekLandingLeadUs = -1L
    @Volatile private var seekLandingAtOrBeforeTarget = false
    @Volatile private var preTargetDiscardedFrames = 0L
    @Volatile private var firstPostSeekChunkPtsUs = -1L
    @Volatile private var firstIngestedPostSeekPtsUs = -1L
    @Volatile private var inputEosAtSeek = false
    @Volatile private var outputEosAtSeek = false
    @Volatile private var generatorReanchorFrame = -1L
    // Owner-thread-confined: true between the codec flush and the first
    // post-seek chunk whose pts reaches the target.
    private var postSeekPreTargetDiscardActive = false
    // Post-seek prefill.
    @Volatile private var postSeekPrefillActive = false
    @Volatile private var postSeekPrefillQuotaFrames = -1L
    @Volatile private var postSeekPrefillFeedSteps = 0L
    @Volatile private var postSeekPrefillCommittedFrames = -1L
    @Volatile private var postSeekPrefillAcceptedFrames = -1L
    @Volatile private var postSeekPrefillStalled = false
    @Volatile private var postSeekPrefillWallMs = -1L
    // Final native seek-aware accounting (finalizeSession).
    @Volatile private var finalNativeExpectedPlayableFrameCount = -1L
    @Volatile private var finalNativeTotalForwardSeekSkippedFrames = -1L
    @Volatile private var finalNativeTotalDiscardedOnSeekFrames = -1L
    @Volatile private var finalNativeSeekSkipAnomalies = -1L
    @Volatile private var finalNativeNextDispatchFrame = -1L
    @Volatile private var finalNativeOutputSeekRequest = -1L
    @Volatile private var finalNativeOutputSeekAck = -1L
    @Volatile private var finalNativeSourceSeekRequestTrack0 = -1L
    @Volatile private var finalNativeSourceSeekAckTrack0 = -1L
    @Volatile private var finalNativeSourceSeekRequestTrack1 = -1L
    @Volatile private var finalNativeSourceSeekAckTrack1 = -1L
    @Volatile private var finalNativeWriterNextWriteFrameTrack0 = -1L
    @Volatile private var finalNativeWriterNextWriteFrameTrack1 = -1L
    @Volatile private var finalNativeTimingT1Ns = -1L
    @Volatile private var finalNativeProviderExternalReanchorCountTrack0 = -1L
    @Volatile private var finalNativeProviderExternalReanchorCountTrack1 = -1L
    @Volatile private var finalNativeProviderLastExternalReanchorFrameTrack0 = -1L
    @Volatile private var finalNativeProviderLastExternalReanchorFrameTrack1 = -1L
    @Volatile private var finalNativeProviderForwardSkipFramesTrack0 = -1L
    @Volatile private var finalNativeProviderForwardSkipFramesTrack1 = -1L
    @Volatile private var finalNativeProviderRewindRejectsTrack0 = -1L
    @Volatile private var finalNativeProviderRewindRejectsTrack1 = -1L
    @Volatile private var finalExpectedPlayableFrameCountAtEos = -1L
    @Volatile private var finalTotalForwardSeekSkippedFramesAtEos = -1L
    @Volatile private var finalSeekAckConsumed = false
    @Volatile private var finalSeekAckNewStartFrame = -1L
    @Volatile private var finalSeekAckDiscardedFrames = -1L
    @Volatile private var finalSeekAckTotalDiscardedOnSeekFrames = -1L

    // ── Sink-thread telemetry (atomics: written on the sink thread, read anywhere) ─

    @Volatile private var sinkThreadIdObserved = -1L
    private val drainCallsFromSink = AtomicLong(0L)
    private val drainCallsOnOwnerThread = AtomicLong(0L)
    private val drainCallsOnOtherThreads = AtomicLong(0L)
    private val drainOverlapRejects = AtomicLong(0L)
    private val drainsAfterCloseRejected = AtomicLong(0L)
    private val drainWaitTimeouts = AtomicLong(0L)
    @Volatile private var lastDrainTimeoutWaitMs = -1L
    private val driftSamplesPosted = AtomicLong(0L)
    private val driftSamplesRejectedUnsupported = AtomicLong(0L)
    private val driftSamplesRejectedStale = AtomicLong(0L)

    // ── Owner-thread-confined state (published as volatile for telemetry) ──

    private var session: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession? = null
    private var pump: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockIngestPump? = null
    private var readBuf: ByteBuffer? = null
    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private val bufferInfo = MediaCodec.BufferInfo()
    private var slice: ByteBuffer = ByteBuffer.allocateDirect(0).order(ByteOrder.LITTLE_ENDIAN)
    private var pendingSliceFrames = 0
    private var sliceIsPad = false
    private var nextEosPollAtMs = 0L

    // Geometry (owner thread writes once; volatile for the coordinator read).
    @Volatile private var geometry: Geometry? = null
    private var sourceMime = ""
    private var sourceTrackIndex = -1
    private var sourceDurationUs = 0L
    private var declaredWindowUs = 0L
    private var inputEndUs = 0L
    private var sampleRate = 0
    private var channelCount = 0
    private var pcmEncoding = 0
    private var bytesPerFrame = 0
    private var expectedFrames = 0L
    private var padBudgetFrames = 0L

    // Decoder facts.
    @Volatile private var formatResolved = false
    @Volatile private var midStreamFormatChanges = 0L
    @Volatile private var decodeSteps = 0L
    @Volatile private var tryAgainSteps = 0L
    @Volatile private var inputSamplesQueued = 0L
    @Volatile private var inputEos = false
    @Volatile private var outputEos = false
    @Volatile private var decoderChunks = 0L
    @Volatile private var framesDecoded = 0L
    @Volatile private var framesIngestedReal = 0L
    @Volatile private var eosPadFrames = 0L
    @Volatile private var eosPadChunks = 0L
    @Volatile private var eosTruncatedFrames = 0L
    @Volatile private var ingestComplete = false
    @Volatile private var sliceGrowths = 0L
    @Volatile private var codecCallsOffOwnerThread = 0L
    @Volatile private var mediaReleaseCount = 0
    @Volatile private var codecReleaseCount = 0
    @Volatile private var extractorReleaseCount = 0
    @Volatile private var mediaReleaseClean = true
    @Volatile private var mediaReleasedAtDecoderEos = false

    // Ring / drain facts.
    @Volatile private var drainsBeforeStartRejected = 0L
    @Volatile private var drainsServiced = 0L
    @Volatile private var drainsServicedFromMakeRoom = 0L
    @Volatile private var maxDrainServiceLatencyMs = -1L
    @Volatile private var drainLatencyBoundViolations = 0L
    @Volatile private var framesReadBySink = 0L
    @Volatile private var emptyReadsServiced = 0L
    @Volatile private var outputSinkAccountedFrames = 0L
    @Volatile private var outputSinkCallbacks = 0L
    @Volatile private var outputSinkCallbacksOffOwner = 0L
    @Volatile private var preStartFillFrames = -1L
    @Volatile private var transportCommandsIssued = 0L
    @Volatile private var transportCommandsFromDrain = 0L
    @Volatile private var eosDrainedObservedByRing = false
    @Volatile private var eosPollSnapshots = 0L
    @Volatile private var makeRoomCallbacks = 0L
    @Volatile private var makeRoomIdleReturns = 0L
    @Volatile private var destroyJoinOk = false
    @Volatile private var destroyIdempotentOk = false
    @Volatile private var openWallMs = -1L
    @Volatile private var formatProbeWallMs = -1L
    @Volatile private var prefillWallMs = -1L
    @Volatile private var startWallMs = -1L
    @Volatile private var ownerLoopWallMs = -1L
    @Volatile private var ownerLoopIterations = 0L
    @Volatile private var finalNative: AndroidRealtimeAudioPlaybackRingTransportFrameSource.NativeTelemetry? = null
    @Volatile private var finalTotalOutputFramesRead = 0L
    @Volatile private var finalNativeOutputReadChecksumHex = ""
    @Volatile private var finalNativeAcceptedChecksumHexTrack0 = ""
    @Volatile private var finalNativeAcceptedChecksumHexTrack1 = ""
    @Volatile private var finalFramesAcceptedTrack0 = 0L
    @Volatile private var finalFramesAcceptedTrack1 = 0L
    @Volatile private var finalWriterBackpressureRejects = 0L
    @Volatile private var finalEosSetWithoutDrain = false
    @Volatile private var finalTotalFramesPushedAtEos = -1L
    @Volatile private var finalChecksumChainSelfOk = false

    val currentStage: Stage get() = stage
    val currentFailureReason: String get() = failureReason
    val ringOwnerThreadId: Long get() = ownerThreadId

    // Frozen geometry, non-null once [open] returned true (stage READY).
    val frozenGeometry: Geometry? get() = geometry

    // Y19 cheap any-thread observations for the scenario's ordering metrics
    // (no allocation, unlike [telemetry]).
    val ingestCompleteObserved: Boolean get() = ingestComplete
    val isFeedQuiesced: Boolean get() = quiesced
    val isTransportPaused: Boolean get() = paused
    val framesReadBySinkObserved: Long get() = framesReadBySink
    // Y20 cheap any-thread observations.
    val isFeedHeldForSeek: Boolean get() = seekHoldReached && quiesced
    val isSeekInProgress: Boolean get() = seekInProgress
    val seekExercisedObserved: Boolean get() = seekExercised
    val effectiveExpectedFramesObserved: Long get() = effectiveExpectedFrames

    // ── Seam (VanguardRealtimeAudioPlaybackFrameSource) ────────────────────

    override val isOwnerThread: Boolean
        get() = ownerThreadId > 0L && Thread.currentThread().id == ownerThreadId

    override val currentGeneration: Long get() = RING_GENERATION

    override val currentStateLabel: String get() = "real_ring_${stage.name.lowercase()}"

    // Sink thread only (class comment): marshals the read onto the ring-owner
    // thread and blocks for at most the per-drain bound.
    override fun drain(dst: ByteBuffer, maxFrames: Int): VanguardRealtimeAudioPlaybackFrameSource.DrainResult {
        drainCallsFromSink.incrementAndGet()
        val callerId = Thread.currentThread().id
        if (sinkThreadIdObserved < 0L) sinkThreadIdObserved = callerId
        else if (sinkThreadIdObserved != callerId) drainCallsOnOtherThreads.incrementAndGet()
        if (ownerThreadId > 0L && callerId == ownerThreadId) {
            drainCallsOnOwnerThread.incrementAndGet()
            return reject("real_ring_drain_on_owner_thread")
        }
        if (maxFrames <= 0) return reject("real_ring_drain_invalid_max_frames")
        // Y19: while ring-paused no drain may reach the owner or native
        // (the scenario parks the sink first, so this is telemetry only).
        if (paused) {
            pausedDrainRejectsSinkThread.incrementAndGet()
            return reject(REASON_DRAIN_WHILE_PAUSED)
        }
        // Y20: while the owner executes the seek no drain may reach it (the
        // scenario keeps the sink seek-parked across the seek: telemetry only).
        if (seekInProgress) {
            seekDrainRejectsSinkThread.incrementAndGet()
            return reject(REASON_DRAIN_DURING_SEEK)
        }
        when (stage) {
            Stage.CLOSING, Stage.CLOSED -> {
                drainsAfterCloseRejected.incrementAndGet()
                return reject("real_ring_closed")
            }
            Stage.FAILED -> {
                drainsAfterCloseRejected.incrementAndGet()
                return reject("real_ring_owner_failed:$failureReason")
            }
            else -> {}
        }
        val request = DrainRequest(dst, maxFrames, SystemClock.elapsedRealtime())
        requestLock.withLock {
            if (!acceptingRequests) {
                drainsAfterCloseRejected.incrementAndGet()
                return reject(if (stage == Stage.FAILED) "real_ring_owner_failed:$failureReason" else "real_ring_closed")
            }
            if (pendingDrain != null) {
                drainOverlapRejects.incrementAndGet()
                return reject("real_ring_drain_overlap")
            }
            pendingDrain = request
            requestCondition.signalAll()
        }
        // Per-drain bound: never the whole run deadline (class comment).
        val remainingMs = config.deadlineAtMs - request.enqueuedAtMs
        val waitMs = minOf(config.drainWaitBoundMs, remainingMs).coerceAtLeast(1L)
        val completed = try {
            request.latch.await(waitMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!completed) {
            requestLock.withLock { if (pendingDrain === request) pendingDrain = null }
            drainWaitTimeouts.incrementAndGet()
            lastDrainTimeoutWaitMs = waitMs
            // Typed sink-side terminal state: the owner is asked to stop and
            // the run is marked failed; the sink exits with drain_rejected.
            fail(REASON_PREFIX_SINK + REASON_DRAIN_WAIT_TIMEOUT + ":$waitMs")
            cancel()
            return reject(REASON_DRAIN_WAIT_TIMEOUT)
        }
        return request.result ?: reject("real_ring_owner_failed:${failureReason.ifBlank { "unknown" }}")
    }

    // Sink thread only, fire-and-forget (class comment): always rejected
    // inline with a typed reason; never blocks, never reaches native.
    override fun postDriftSample(
        request: VanguardRealtimePlaybackTransportStateMachine.DriftSampleRequest,
        expectedGeneration: Long?,
        callback: ((VanguardRealtimeAudioPlaybackFrameSource.DriftResult) -> Unit)?,
    ): Boolean {
        driftSamplesPosted.incrementAndGet()
        val reason = if (expectedGeneration != null && expectedGeneration != RING_GENERATION) {
            driftSamplesRejectedStale.incrementAndGet()
            VanguardRealtimePlaybackTransportStateMachine.REASON_STALE_GENERATION
        } else {
            driftSamplesRejectedUnsupported.incrementAndGet()
            REASON_DRIFT_UNSUPPORTED
        }
        callback?.invoke(VanguardRealtimeAudioPlaybackFrameSource.DriftResult(false, reason, null))
        return false
    }

    private fun reject(reason: String) =
        VanguardRealtimeAudioPlaybackFrameSource.DrainResult(false, reason, null)

    // ── Lifecycle (coordinator thread) ─────────────────────────────────────

    // Starts the ring-owner thread (media open, format probe, geometry
    // freeze, native session create, lockstep pre-roll) and waits until the
    // ring is READY (no Start enqueued yet). Single use; false on timeout or
    // any owner-thread failure. [frozenGeometry] is valid once true.
    fun open(timeoutMs: Long): Boolean {
        if (!opened.compareAndSet(false, true)) return false
        setStage(Stage.OPENING, "opening")
        val t = Thread({ runOwnerThread() }, config.threadName)
        ownerThread = t
        t.start()
        val ok = try {
            readyLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        return ok && stage == Stage.READY && geometry != null
    }

    // Enqueues the ONE native Start command on the ring-owner thread and
    // waits for its execution plus the output-ring start ack. Must precede
    // the sink's allowDrain(). False on timeout or failure.
    fun startTransport(timeoutMs: Long): Boolean {
        if (stage != Stage.READY) return false
        if (!startRequested.compareAndSet(false, true)) return false
        requestLock.withLock { requestCondition.signalAll() }
        val ok = try {
            startLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        return ok && started && stage != Stage.FAILED
    }

    // ── Y19 pause/resume cycle (any non-owner thread requests; owner executes) ─

    // Holds the feed at the NEXT clean boundary (no staged slice, no latched
    // lockstep chunk, no codec output held, timeline not fully ingested):
    // from then on the owner services sink drains only, without decode /
    // ingest / EOS poll, until the cycle resumes. Blocks up to timeoutMs
    // (the owner may need a few sink drains to finish the in-flight slice).
    // False on timeout, overlap, before Start, after close, or when called
    // on the owner thread. Fails the owner closed (typed) if the timeline
    // completes before a clean boundary is reached.
    fun quiesceFeedForPause(timeoutMs: Long): Boolean = submitControl(Control.QUIESCE, timeoutMs)

    // Enqueues the ONE native Pause command on the ring-owner thread and
    // waits for its processed-snapshot proof. Executes only at a clean
    // boundary (normally the quiesced one); otherwise the owner fails closed
    // with [REASON_PAUSE_NOT_AT_CLEAN_BOUNDARY] and this returns false.
    fun pauseTransport(timeoutMs: Long): Boolean = submitControl(Control.PAUSE, timeoutMs)

    // Owner-thread, snapshot-only proof that the native dispatch stayed
    // frozen during the caller's bounded hold (no command, no read).
    fun assertPausedHoldFrozen(timeoutMs: Long): Boolean = submitControl(Control.HOLD_ASSERT, timeoutMs)

    // Enqueues the ONE native Resume command on the ring-owner thread, waits
    // for its processed-snapshot proof and releases the feed gate.
    fun resumeTransport(timeoutMs: Long): Boolean = submitControl(Control.RESUME, timeoutMs)

    // ── Y20 forward seek (any non-owner thread requests; owner executes) ───

    // Arms the feed cap at the window-aligned hold frame [holdFrame] and
    // blocks until the owner has committed exactly that many frames at a
    // clean boundary and holds the feed there (drains still serviced, no
    // decode / ingest / EOS poll). False on timeout, overlap, before Start,
    // after close, when called on the owner thread, or when the owner fails
    // closed (hold frame invalid / already passed / timeline completed).
    fun quiesceFeedForSeek(holdFrame: Long, timeoutMs: Long): Boolean =
        submitControl(Control.QUIESCE_FOR_SEEK, timeoutMs, holdFrame)

    // Executes the ONE forward seek to [targetFrame] on the ring-owner
    // thread (class comment): native quiescence proof at the hold frame,
    // native joint seek, generator + extractor + codec re-anchor, post-seek
    // lockstep prefill, ack-only output ack consume, feed gate released.
    // The caller must already have drained the production sink to the hold
    // frame and seek-parked + flushed it. False on timeout or failure.
    fun seekTransport(targetFrame: Long, timeoutMs: Long): Boolean =
        submitControl(Control.SEEK, timeoutMs, targetFrame)

    private fun submitControl(kind: Control, timeoutMs: Long, frame: Long = -1L): Boolean {
        when (kind) {
            Control.QUIESCE -> quiesceRequests.incrementAndGet()
            Control.PAUSE -> pauseRequests.incrementAndGet()
            Control.HOLD_ASSERT -> holdAssertRequests.incrementAndGet()
            Control.RESUME -> resumeRequests.incrementAndGet()
            Control.QUIESCE_FOR_SEEK -> seekQuiesceRequests.incrementAndGet()
            Control.SEEK -> seekRequests.incrementAndGet()
        }
        if (ownerThreadId > 0L && Thread.currentThread().id == ownerThreadId) {
            controlRequestsOnOwnerThread.incrementAndGet()
            lastControlRejectReason = "real_ring_control_on_owner_thread"
            return false
        }
        if (!started) {
            lastControlRejectReason = REASON_CONTROL_BEFORE_START
            return false
        }
        when (stage) {
            Stage.CLOSING, Stage.CLOSED, Stage.FAILED -> {
                lastControlRejectReason = REASON_CONTROL_CLOSED
                return false
            }
            else -> {}
        }
        val request = ControlRequest(kind, SystemClock.elapsedRealtime(), frame)
        requestLock.withLock {
            if (!acceptingRequests) {
                lastControlRejectReason = REASON_CONTROL_CLOSED
                return false
            }
            if (pendingControl != null) {
                controlOverlapRejects.incrementAndGet()
                lastControlRejectReason = "real_ring_control_overlap"
                return false
            }
            pendingControl = request
            requestCondition.signalAll()
        }
        val remainingMs = config.deadlineAtMs - request.enqueuedAtMs
        val waitMs = minOf(timeoutMs, remainingMs).coerceAtLeast(1L)
        val completed = try {
            request.latch.await(waitMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!completed) {
            // Withdraw if still pending; an already-taken request completes
            // on the owner regardless, but the caller sees the timeout.
            requestLock.withLock { if (pendingControl === request) pendingControl = null }
            controlWaitTimeouts.incrementAndGet()
            lastControlTimeoutKind = kind.name
            return false
        }
        if (!request.ok) lastControlRejectReason = request.reason
        return request.ok
    }

    // Any thread: asks the owner loop to stop (pending drains are rejected).
    fun cancel() {
        stopRequested.set(true)
        requestLock.withLock { requestCondition.signalAll() }
    }

    // Stops the owner loop, lets it take the final snapshot, release media
    // once and destroy / join the native worker, then joins the owner
    // thread. Idempotent; true once the owner thread has exited.
    fun close(timeoutMs: Long): Boolean {
        cancel()
        val t = ownerThread ?: return true
        if (Thread.currentThread() === t) return false
        try {
            closedLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
            t.join(JOIN_SLACK_MS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        return !t.isAlive
    }

    fun telemetry(): Telemetry {
        val p = pump
        val decoder = DecoderTelemetry(
            formatResolved = formatResolved,
            midStreamFormatChanges = midStreamFormatChanges,
            decodeSteps = decodeSteps,
            tryAgainSteps = tryAgainSteps,
            inputSamplesQueued = inputSamplesQueued,
            inputEosQueued = inputEos,
            outputEosReached = outputEos,
            decoderChunks = decoderChunks,
            framesDecoded = framesDecoded,
            framesIngestedReal = framesIngestedReal,
            eosPadFrames = eosPadFrames,
            eosPadChunks = eosPadChunks,
            eosTruncatedFrames = eosTruncatedFrames,
            padBudgetFrames = padBudgetFrames,
            ingestComplete = ingestComplete,
            sliceGrowths = sliceGrowths,
            codecCallsOffOwnerThread = codecCallsOffOwnerThread,
            mediaReleaseCount = mediaReleaseCount,
            codecReleaseCount = codecReleaseCount,
            extractorReleaseCount = extractorReleaseCount,
            mediaReleaseClean = mediaReleaseClean,
            mediaReleasedAtDecoderEos = mediaReleasedAtDecoderEos,
        )
        return Telemetry(
            stage = stage,
            stageTrace = stageTrace,
            failureReason = failureReason,
            ownerThreadId = ownerThreadId,
            sinkThreadIdObserved = sinkThreadIdObserved,
            drainCallsFromSink = drainCallsFromSink.get(),
            drainCallsOnOwnerThread = drainCallsOnOwnerThread.get(),
            drainCallsOnOtherThreads = drainCallsOnOtherThreads.get(),
            drainOverlapRejects = drainOverlapRejects.get(),
            drainsBeforeStartRejected = drainsBeforeStartRejected,
            drainsServiced = drainsServiced,
            drainsServicedFromMakeRoom = drainsServicedFromMakeRoom,
            drainsAfterCloseRejected = drainsAfterCloseRejected.get(),
            drainWaitBoundMs = config.drainWaitBoundMs,
            drainWaitTimeouts = drainWaitTimeouts.get(),
            lastDrainTimeoutWaitMs = lastDrainTimeoutWaitMs,
            maxDrainServiceLatencyMs = maxDrainServiceLatencyMs,
            drainLatencyBoundViolations = drainLatencyBoundViolations,
            framesReadBySink = framesReadBySink,
            emptyReadsServiced = emptyReadsServiced,
            outputSinkAccountedFrames = outputSinkAccountedFrames,
            outputSinkCallbacks = outputSinkCallbacks,
            outputSinkCallbacksOffOwner = outputSinkCallbacksOffOwner,
            // Structural: this class has no private output-drain path at all.
            privateOutputDrains = 0L,
            totalOutputFramesRead = finalTotalOutputFramesRead,
            nativeOutputReadChecksumHex = finalNativeOutputReadChecksumHex,
            kotlinReferenceMixChecksumHex = p?.kotlinReferenceMixChecksumHex ?: "",
            kotlinTrack0ChecksumHex = p?.kotlinTrack0AcceptedChecksumHex ?: "",
            kotlinTrack1ChecksumHex = p?.kotlinTrack1AcceptedChecksumHex ?: "",
            nativeAcceptedChecksumHexTrack0 = finalNativeAcceptedChecksumHexTrack0,
            nativeAcceptedChecksumHexTrack1 = finalNativeAcceptedChecksumHexTrack1,
            pumpFramesAccepted = p?.kotlinFramesAccepted ?: 0L,
            framesAcceptedTrack0 = finalFramesAcceptedTrack0,
            framesAcceptedTrack1 = finalFramesAcceptedTrack1,
            track0NonZeroSampleCount = p?.track0NonZeroSampleCount ?: 0L,
            track1NonZeroSampleCount = p?.track1NonZeroSampleCount ?: 0L,
            checksumChainSelfOk = finalChecksumChainSelfOk,
            preStartFillFrames = preStartFillFrames,
            transportCommandsIssued = transportCommandsIssued,
            transportCommandsFromDrain = transportCommandsFromDrain,
            eosSetWithoutDrain = finalEosSetWithoutDrain,
            totalFramesPushedAtEos = finalTotalFramesPushedAtEos,
            eosDrainedObservedByRing = eosDrainedObservedByRing,
            eosPollSnapshots = eosPollSnapshots,
            driftSamplesPosted = driftSamplesPosted.get(),
            driftSamplesRejectedUnsupported = driftSamplesRejectedUnsupported.get(),
            driftSamplesRejectedStale = driftSamplesRejectedStale.get(),
            destroyJoinOk = destroyJoinOk,
            destroyIdempotentOk = destroyIdempotentOk,
            makeRoomCallbacks = makeRoomCallbacks,
            makeRoomIdleReturns = makeRoomIdleReturns,
            writerBackpressureRejects = finalWriterBackpressureRejects,
            openWallMs = openWallMs,
            formatProbeWallMs = formatProbeWallMs,
            prefillWallMs = prefillWallMs,
            startWallMs = startWallMs,
            ownerLoopWallMs = ownerLoopWallMs,
            ownerLoopIterations = ownerLoopIterations,
            geometry = geometry,
            decoder = decoder,
            native = finalNative,
            pauseResume = pauseResumeTelemetry(),
            effectiveExpectedFrames = effectiveExpectedFrames,
            seek = seekTelemetry(),
            seekReanchor = seekReanchorTelemetry(),
        )
    }

    private fun seekTelemetry(): SeekTelemetry = SeekTelemetry(
        seekQuiesceRequests = seekQuiesceRequests.get(),
        seekRequests = seekRequests.get(),
        seekDrainRejectsSinkThread = seekDrainRejectsSinkThread.get(),
        seekDrainRejectsOwnerThread = seekDrainRejectsOwnerThread,
        holdFrame = seekHoldFrame,
        holdArmed = seekHoldArmed,
        holdArmedOnOwnerThread = seekHoldArmedOnOwnerThread,
        holdCommittedFramesAtArm = seekHoldCommittedFramesAtArm,
        holdReached = seekHoldReached,
        holdAckOk = seekHoldAckOk,
        holdExecutedOnOwnerThread = seekHoldExecutedOnOwnerThread,
        holdWallMs = seekHoldWallMs,
        holdDiscardedStagedFrames = seekHoldDiscardedStagedFrames,
        feedStepsWhileHeld = feedStepsWhileHeld,
        framesReadBySinkAtHold = framesReadBySinkAtHold,
        drainsServicedAtHold = drainsServicedAtHold,
        framesAcceptedTrack0AtHold = framesAcceptedTrack0AtHold,
        framesAcceptedTrack1AtHold = framesAcceptedTrack1AtHold,
        framesDecodedAtHold = framesDecodedAtHold,
        decodeStepsAtHold = decodeStepsAtHold,
        seekExercised = seekExercised,
        seekAckOk = seekAckOk,
        seekExecutedOnOwnerThread = seekExecutedOnOwnerThread,
        seekWallMs = seekWallMs,
        seekTargetFrame = seekTargetFrame,
        seekSkipFrames = seekSkipFrames,
        seekQuiescedFirst = seekQuiescedFirst,
        seekCleanBoundaryOk = seekCleanBoundaryOk,
        seekPendingSliceFramesAtRequest = seekPendingSliceFramesAtRequest,
        seekPumpPendingChunkAtRequest = seekPumpPendingChunkAtRequest,
        seekCodecOutputHeldAtRequest = seekCodecOutputHeldAtRequest,
        seekIngestCompleteAtRequest = seekIngestCompleteAtRequest,
        seekPausedAtRequest = seekPausedAtRequest,
        framesReadBySinkAtSeek = framesReadBySinkAtSeek,
        drainsServicedAtSeek = drainsServicedAtSeek,
        drainsServicedDuringSeek = drainsServicedDuringSeek,
        stageBeforeSeek = stageBeforeSeek?.name ?: "none",
        stageAfterSeek = stageAfterSeek?.name ?: "none",
        nativeQuiescentProofOk = session?.quiescentForSeekProofOk ?: false,
        nativeQuiescentTotalFramesPushed = session?.quiescentForSeekTotalFramesPushed ?: -1L,
        nativeQuiescentNextDispatchFrame = session?.quiescentForSeekNextDispatchFrame ?: -1L,
        nativeQuiescentOutputAvailableReadFrames = session?.quiescentForSeekOutputAvailableReadFrames ?: -1L,
        nativeQuiescentTimingT1Ns = session?.quiescentForSeekTimingT1Ns ?: -1L,
        nativeSeekCommandSeq = session?.seekCommandSeq ?: -1L,
        nativeSeekRequestedPtsUs = session?.seekRequestedPtsUs ?: -1L,
        nativeSeekReplyTargetFrame = session?.seekReplyTargetFrame ?: -1L,
        nativeSeekTransientRetries = session?.seekTransientRetries ?: -1L,
        nativeSeekProcessedOk = session?.seekProcessedOk ?: false,
        nativeSkippedFramesAtSeek = session?.seekSkippedFramesAtProcessed ?: -1L,
        nativeExpectedPlayableAtSeek = session?.seekExpectedPlayableAtProcessed ?: -1L,
        nativeSeekSkipAnomaliesAtSeek = session?.seekSkipAnomaliesAtProcessed ?: -1L,
        nativeNextDispatchFrameAtSeek = session?.seekNextDispatchFrameAtProcessed ?: -1L,
        nativeProviderExternalReanchorCountAtSeekTrack0 =
            session?.seekProviderExternalReanchorCountAtProcessedTrack?.get(0) ?: -1L,
        nativeProviderExternalReanchorCountAtSeekTrack1 =
            session?.seekProviderExternalReanchorCountAtProcessedTrack?.get(1) ?: -1L,
        nativeProviderLastExternalReanchorFrameAtSeekTrack0 =
            session?.seekProviderLastExternalReanchorFrameAtProcessedTrack?.get(0) ?: -1L,
        nativeProviderLastExternalReanchorFrameAtSeekTrack1 =
            session?.seekProviderLastExternalReanchorFrameAtProcessedTrack?.get(1) ?: -1L,
        nativeProviderExpectedNextFrameAtSeekTrack0 =
            session?.seekProviderExpectedNextFrameAtProcessedTrack?.get(0) ?: -1L,
        nativeProviderExpectedNextFrameAtSeekTrack1 =
            session?.seekProviderExpectedNextFrameAtProcessedTrack?.get(1) ?: -1L,
        effectiveExpectedFrames = effectiveExpectedFrames,
        seekAckConsumedByAckOnlyRead = finalSeekAckConsumed,
        seekAckNewStartFrame = finalSeekAckNewStartFrame,
        seekAckDiscardedFrames = finalSeekAckDiscardedFrames,
        seekAckTotalDiscardedOnSeekFrames = finalSeekAckTotalDiscardedOnSeekFrames,
        seekAckWallMs = seekAckWallMs,
    )

    private fun seekReanchorTelemetry(): SeekReanchorTelemetry = SeekReanchorTelemetry(
        extractorSeekCalls = extractorSeekCalls,
        codecFlushCalls = codecFlushCalls,
        extractorReanchoredOnOwnerThread = extractorReanchoredOnOwnerThread,
        seekTargetUs = seekTargetUs,
        seekLandingPtsUs = seekLandingPtsUs,
        seekLandingLeadUs = seekLandingLeadUs,
        seekLandingAtOrBeforeTarget = seekLandingAtOrBeforeTarget,
        preTargetDiscardedFrames = preTargetDiscardedFrames,
        preTargetDiscardBudgetFrames = padBudgetFrames,
        firstPostSeekChunkPtsUs = firstPostSeekChunkPtsUs,
        firstIngestedPostSeekPtsUs = firstIngestedPostSeekPtsUs,
        inputEosAtSeek = inputEosAtSeek,
        outputEosAtSeek = outputEosAtSeek,
        generatorReanchorCount = pump?.generatorReanchorCount ?: 0L,
        generatorReanchorFrame = generatorReanchorFrame,
        generatorAxis = GENERATOR_AXIS_ACCEPTED_COUNT,
        postSeekPrefillQuotaFrames = postSeekPrefillQuotaFrames,
        postSeekPrefillFeedSteps = postSeekPrefillFeedSteps,
        postSeekPrefillCommittedFrames = postSeekPrefillCommittedFrames,
        postSeekPrefillAcceptedFrames = postSeekPrefillAcceptedFrames,
        postSeekPrefillStalled = postSeekPrefillStalled,
        postSeekPrefillWallMs = postSeekPrefillWallMs,
        postSeekFramesReadBySink = if (framesReadBySinkAtSeek >= 0L) framesReadBySink - framesReadBySinkAtSeek else -1L,
        nativeExpectedPlayableFrameCount = finalNativeExpectedPlayableFrameCount,
        nativeTotalForwardSeekSkippedFrames = finalNativeTotalForwardSeekSkippedFrames,
        nativeTotalDiscardedOnSeekFrames = finalNativeTotalDiscardedOnSeekFrames,
        nativeSeekSkipAnomalies = finalNativeSeekSkipAnomalies,
        nativeNextDispatchFrame = finalNativeNextDispatchFrame,
        nativeOutputSeekRequest = finalNativeOutputSeekRequest,
        nativeOutputSeekAck = finalNativeOutputSeekAck,
        nativeSourceSeekRequestTrack0 = finalNativeSourceSeekRequestTrack0,
        nativeSourceSeekAckTrack0 = finalNativeSourceSeekAckTrack0,
        nativeSourceSeekRequestTrack1 = finalNativeSourceSeekRequestTrack1,
        nativeSourceSeekAckTrack1 = finalNativeSourceSeekAckTrack1,
        nativeWriterNextWriteFrameTrack0 = finalNativeWriterNextWriteFrameTrack0,
        nativeWriterNextWriteFrameTrack1 = finalNativeWriterNextWriteFrameTrack1,
        nativeTimingT1Ns = finalNativeTimingT1Ns,
        nativeProviderExternalReanchorCountTrack0 = finalNativeProviderExternalReanchorCountTrack0,
        nativeProviderExternalReanchorCountTrack1 = finalNativeProviderExternalReanchorCountTrack1,
        nativeProviderLastExternalReanchorFrameTrack0 = finalNativeProviderLastExternalReanchorFrameTrack0,
        nativeProviderLastExternalReanchorFrameTrack1 = finalNativeProviderLastExternalReanchorFrameTrack1,
        nativeProviderForwardSkipFramesTrack0 = finalNativeProviderForwardSkipFramesTrack0,
        nativeProviderForwardSkipFramesTrack1 = finalNativeProviderForwardSkipFramesTrack1,
        nativeProviderRewindRejectsTrack0 = finalNativeProviderRewindRejectsTrack0,
        nativeProviderRewindRejectsTrack1 = finalNativeProviderRewindRejectsTrack1,
        expectedPlayableFrameCountAtEos = finalExpectedPlayableFrameCountAtEos,
        totalForwardSeekSkippedFramesAtEos = finalTotalForwardSeekSkippedFramesAtEos,
    )

    private fun pauseResumeTelemetry(): PauseResumeTelemetry = PauseResumeTelemetry(
        quiesceRequests = quiesceRequests.get(),
        pauseRequests = pauseRequests.get(),
        holdAssertRequests = holdAssertRequests.get(),
        resumeRequests = resumeRequests.get(),
        controlRequestsOnOwnerThread = controlRequestsOnOwnerThread.get(),
        controlOverlapRejects = controlOverlapRejects.get(),
        controlWaitTimeouts = controlWaitTimeouts.get(),
        lastControlTimeoutKind = lastControlTimeoutKind,
        lastControlRejectReason = lastControlRejectReason,
        quiesceAckOk = quiesceAckOk,
        quiesceExecutedOnOwnerThread = quiesceExecutedOnOwnerThread,
        quiesceWallMs = quiesceWallMs,
        feedStepsWhileQuiesced = feedStepsWhileQuiesced,
        pauseAckOk = pauseAckOk,
        pauseExecutedOnOwnerThread = pauseExecutedOnOwnerThread,
        pauseQuiescedFirst = pauseQuiescedFirst,
        pauseCleanBoundaryOk = pauseCleanBoundaryOk,
        pausePendingSliceFramesAtRequest = pausePendingSliceFramesAtRequest,
        pausePumpPendingChunkAtRequest = pausePumpPendingChunkAtRequest,
        pauseCodecOutputHeldAtRequest = pauseCodecOutputHeldAtRequest,
        pauseIngestCompleteAtRequest = pauseIngestCompleteAtRequest,
        nativePauseProofOk = nativePauseProofOk,
        pauseCommandSeq = pauseCommandSeq,
        pauseWallMs = pauseWallMs,
        dispatchCountAtPause = dispatchCountAtPause,
        totalFramesPushedAtPause = totalFramesPushedAtPause,
        nextDispatchFrameAtPause = nextDispatchFrameAtPause,
        framesPendingAtPause = framesPendingAtPause,
        pausedWaitsAtPause = pausedWaitsAtPause,
        framesReadBySinkAtPause = framesReadBySinkAtPause,
        drainsServicedAtPause = drainsServicedAtPause,
        pumpFramesAcceptedAtPause = pumpFramesAcceptedAtPause,
        framesAcceptedTrack0AtPause = framesAcceptedTrack0AtPause,
        framesAcceptedTrack1AtPause = framesAcceptedTrack1AtPause,
        framesDecodedAtPause = framesDecodedAtPause,
        stageBeforePause = stageBeforePause?.name ?: "none",
        holdAssertAckOk = holdAssertAckOk,
        holdAssertExecutedOnOwnerThread = holdAssertExecutedOnOwnerThread,
        nativeHoldFrozenProofOk = nativeHoldFrozenProofOk,
        holdAssertObservedNs = holdAssertObservedNs,
        dispatchCountAfterHold = dispatchCountAfterHold,
        totalFramesPushedAfterHold = totalFramesPushedAfterHold,
        pausedWaitsAfterHold = pausedWaitsAfterHold,
        framesReadBySinkAfterHold = framesReadBySinkAfterHold,
        drainsServicedAfterHold = drainsServicedAfterHold,
        pumpFramesAcceptedAfterHold = pumpFramesAcceptedAfterHold,
        ownerLoopIterationsWhilePaused = ownerLoopIterationsWhilePaused,
        feedStepsWhilePaused = feedStepsWhilePaused,
        eosPollsWhilePaused = eosPollsWhilePaused,
        decodeStepsWhilePaused = decodeStepsWhilePaused,
        makeRoomCallbacksWhilePaused = makeRoomCallbacksWhilePaused,
        pausedDrainRejectsSinkThread = pausedDrainRejectsSinkThread.get(),
        pausedDrainRejectsOwnerThread = pausedDrainRejectsOwnerThread,
        resumeAckOk = resumeAckOk,
        resumeExecutedOnOwnerThread = resumeExecutedOnOwnerThread,
        nativeResumeProofOk = nativeResumeProofOk,
        resumeCommandSeq = resumeCommandSeq,
        resumeWallMs = resumeWallMs,
        dispatchCountAtResume = dispatchCountAtResume,
        totalFramesPushedAtResume = totalFramesPushedAtResume,
        nativeLastPausedIntervalNs = nativeLastPausedIntervalNs,
        nativeTotalPausedNs = nativeTotalPausedNs,
        pauseHoldObservedNs = pauseHoldObservedNs,
        pauseHoldObservedMs = if (pauseHoldObservedNs >= 0L) pauseHoldObservedNs / 1_000_000L else -1L,
        framesReadBySinkAtResume = framesReadBySinkAtResume,
        pumpFramesAcceptedAtResume = pumpFramesAcceptedAtResume,
        stageAfterResume = stageAfterResume?.name ?: "none",
    )

    // ── Ring-owner thread ──────────────────────────────────────────────────

    private fun runOwnerThread() {
        ownerThreadId = Thread.currentThread().id
        val openStart = SystemClock.elapsedRealtime()
        var loopStart = -1L
        try {
            validateConfig()
            setStage(Stage.FORMAT_PROBE, "format_probe")
            val probeStart = SystemClock.elapsedRealtime()
            openMedia()
            probeFormat()
            formatProbeWallMs = SystemClock.elapsedRealtime() - probeStart
            setStage(Stage.GEOMETRY_FROZEN, "geometry_frozen")
            freezeGeometry()
            setStage(Stage.SESSION_CREATED, "session_created")
            establishSession()
            setStage(Stage.PRE_ROLL, "pre_roll")
            val prefillStart = SystemClock.elapsedRealtime()
            prefill()
            prefillWallMs = SystemClock.elapsedRealtime() - prefillStart
            setStage(Stage.READY, "ready")
            openWallMs = SystemClock.elapsedRealtime() - openStart
            readyLatch.countDown()
            loopStart = SystemClock.elapsedRealtime()
            ownerLoop()
        } catch (f: FailClosed) {
            fail(f.reason)
        } catch (f: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession.Failure) {
            fail(REASON_PREFIX_NATIVE + f.reason)
        } catch (f: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockIngestPump.FailClosed) {
            fail(REASON_PREFIX_LOCKSTEP + f.reason)
        } catch (t: Throwable) {
            fail("exception:${t.javaClass.simpleName}:${t.message}")
        } finally {
            if (loopStart >= 0L) ownerLoopWallMs = SystemClock.elapsedRealtime() - loopStart
            if (stage != Stage.FAILED) setStage(Stage.CLOSING, "close_dispose")
            else trace("close_dispose")
            rejectPendingDrain()
            rejectPendingControl()
            releaseMediaOnce()
            finalizeSession()
            if (stage != Stage.FAILED) setStage(Stage.CLOSED, "closed")
            // Waiters must never block on a dead owner; they re-check stage.
            readyLatch.countDown()
            startLatch.countDown()
            closedLatch.countDown()
        }
    }

    private fun fail(reason: String) {
        if (failureReason.isBlank()) failureReason = reason
        stage = Stage.FAILED
        trace("failed")
    }

    private fun setStage(next: Stage, token: String) {
        stage = next
        trace(token)
    }

    private fun trace(token: String) {
        stageTrace = "$stageTrace>$token"
    }

    private fun validateConfig() {
        val c = config
        if (c.sourcePath.isBlank()) throw FailClosed("real_ring_source_path_required")
        if (!(c.maxDurationSec > 0.0)) throw FailClosed("real_ring_invalid_max_duration")
        if (c.maxFramesPerMix <= 0 || c.maxFramesPerMix > VanguardRealtimePlaybackNativeSession.MAX_FRAMES_PER_MIX_CAP) {
            throw FailClosed("real_ring_invalid_max_frames_per_mix")
        }
        if (c.outputRingCapacityFrames < c.maxFramesPerMix ||
            c.outputRingCapacityFrames % c.maxFramesPerMix != 0
        ) {
            throw FailClosed("real_ring_output_ring_not_window_aligned")
        }
        if (c.sourceRingCapacityFrames < c.outputRingCapacityFrames + 2 * c.maxFramesPerMix) {
            throw FailClosed("real_ring_source_ring_geometry")
        }
        if (c.maxFramesPerMix > STAGING_SLICE_FRAMES) throw FailClosed("real_ring_window_exceeds_staging_slice")
        if (c.drainWaitBoundMs <= 0L) throw FailClosed("real_ring_invalid_drain_wait_bound")
        if (SystemClock.elapsedRealtime() > c.deadlineAtMs) throw FailClosed(REASON_DEADLINE)
    }

    private fun checkDeadlineAndCancel() {
        if (stopRequested.get()) throw FailClosed(REASON_CANCELLED)
        if (SystemClock.elapsedRealtime() > config.deadlineAtMs) throw FailClosed(REASON_DEADLINE)
    }

    private fun noteCodecCall() {
        if (Thread.currentThread().id != ownerThreadId) codecCallsOffOwnerThread++
    }

    // Wraps every MediaExtractor/MediaCodec touch: any non-typed throwable
    // becomes the typed decoder_failure reason; typed reasons pass through.
    private inline fun <T> decoderGuard(what: String, block: () -> T): T =
        try {
            block()
        } catch (f: FailClosed) {
            throw f
        } catch (t: Throwable) {
            throw FailClosed("$REASON_PREFIX_DECODER$what:${t.javaClass.simpleName}:${t.message}")
        }

    // ── Media open / format probe / geometry freeze ────────────────────────

    private fun openMedia() {
        decoderGuard("open") {
            val ex = MediaExtractor()
            extractor = ex
            ex.setDataSource(config.sourcePath)
            var trackIndex = -1
            var tf: MediaFormat? = null
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    trackIndex = i
                    tf = f
                    break
                }
            }
            if (trackIndex < 0 || tf == null) throw FailClosed(REASON_PREFIX_DECODER + "no_audio_track")
            ex.selectTrack(trackIndex)
            val mime = tf.getString(MediaFormat.KEY_MIME) ?: throw FailClosed(REASON_PREFIX_DECODER + "audio_track_mime_missing")
            if (!tf.containsKey(MediaFormat.KEY_DURATION)) throw FailClosed(REASON_PREFIX_DECODER + "format_duration_missing")
            val durationUs = tf.getLong(MediaFormat.KEY_DURATION)
            if (durationUs <= 0L) throw FailClosed(REASON_PREFIX_DECODER + "format_duration_invalid:$durationUs")
            sourceMime = mime
            sourceTrackIndex = trackIndex
            sourceDurationUs = durationUs
            declaredWindowUs = minOf(durationUs, (config.maxDurationSec * 1_000_000.0).toLong())
            inputEndUs = declaredWindowUs + END_INPUT_MARGIN_US
            val dec = MediaCodec.createDecoderByType(mime)
            codec = dec
            dec.configure(tf, null, null, 0)
            dec.start()
        }
    }

    // Pulls decoder output until the PCM output format is known; a first
    // staged chunk (if any) is kept for the pre-roll.
    private fun probeFormat() {
        while (!formatResolved) {
            checkDeadlineAndCancel()
            decodeStep()
            if (outputEos && !formatResolved) throw FailClosed(REASON_PREFIX_DECODER + "no_decoder_output")
        }
    }

    private fun resolveOutputFormat(f: MediaFormat) {
        val sr = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val ch = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val enc = if (f.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
            f.getInteger(MediaFormat.KEY_PCM_ENCODING)
        } else {
            AudioFormat.ENCODING_PCM_16BIT
        }
        if (formatResolved) {
            if (sr != sampleRate || ch != channelCount || enc != pcmEncoding) {
                midStreamFormatChanges++
                throw FailClosed(REASON_PREFIX_DECODER + "mid_stream_format_change:$sr:$ch:$enc")
            }
            return
        }
        if (enc != AudioFormat.ENCODING_PCM_16BIT) throw FailClosed(REASON_PREFIX_DECODER + "unsupported_pcm_encoding:$enc")
        if (ch != 1 && ch != 2) throw FailClosed(REASON_PREFIX_DECODER + "unsupported_channel_count:$ch")
        if (sr < VanguardRealtimePlaybackNativeSession.MIN_SAMPLE_RATE ||
            sr > VanguardRealtimePlaybackNativeSession.MAX_SAMPLE_RATE
        ) {
            throw FailClosed(REASON_PREFIX_DECODER + "unsupported_sample_rate:$sr")
        }
        sampleRate = sr
        channelCount = ch
        pcmEncoding = enc
        bytesPerFrame = 2 * ch
        formatResolved = true
    }

    // expectedFrames = floor(min(mediaDuration, maxDurationSec) * sampleRate
    // / maxFramesPerMix) * maxFramesPerMix; pad budget = one second.
    private fun freezeGeometry() {
        val window = config.maxFramesPerMix.toLong()
        val declaredFrames = declaredWindowUs * sampleRate / 1_000_000L
        expectedFrames = declaredFrames / window * window
        if (expectedFrames <= 0L) throw FailClosed("real_ring_expected_frames_invalid:$expectedFrames")
        // The pre-start quota fills one output ring and a post-start stream must remain.
        if (expectedFrames < 2L * config.outputRingCapacityFrames) {
            throw FailClosed("real_ring_timeline_too_short:$expectedFrames:${config.outputRingCapacityFrames}")
        }
        padBudgetFrames = (EOS_PAD_BUDGET_SEC * sampleRate).toLong()
        // Y20: seek-aware effective count starts at the declared count and
        // drops by the skipped span once the one forward seek is processed.
        effectiveExpectedFrames = expectedFrames
        geometry = Geometry(
            sourceMime = sourceMime,
            sourceTrackIndex = sourceTrackIndex,
            sourceDurationUs = sourceDurationUs,
            declaredWindowUs = declaredWindowUs,
            sampleRate = sampleRate,
            channelCount = channelCount,
            pcmEncoding = pcmEncoding,
            maxFramesPerMix = config.maxFramesPerMix,
            expectedFrames = expectedFrames,
            padBudgetFrames = padBudgetFrames,
            inputEndUs = inputEndUs,
        )
    }

    // Creates the native session (worker boots here) with the accounting-only
    // output sink and the lockstep pump whose make-room callback services
    // pending sink drains only (class comment).
    private fun establishSession() {
        val s = AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession(
            deadlineElapsedRealtimeMs = config.deadlineAtMs,
            outputSink = { frames ->
                outputSinkCallbacks += 1L
                if (Thread.currentThread().id != ownerThreadId) outputSinkCallbacksOffOwner += 1L
                outputSinkAccountedFrames += frames
            },
        )
        // Required by create() for the X4 read path; never read through here
        // (the sink's own buffer is the only destination of every read).
        val buf = ByteBuffer
            .allocateDirect(config.outputRingCapacityFrames * bytesPerFrame)
            .order(ByteOrder.LITTLE_ENDIAN)
        readBuf = buf
        s.create(
            sampleRateIn = sampleRate,
            channelCountIn = channelCount,
            expectedFramesIn = expectedFrames,
            sourceRingCapacityFrames = config.sourceRingCapacityFrames,
            outputRingCapacityFrames = config.outputRingCapacityFrames,
            maxFramesPerMix = config.maxFramesPerMix,
            readBuffer = buf,
        )
        session = s
        pump = AndroidAsyncRuntimeQueueMultiSourceRealtimeClockIngestPump(
            session = s,
            channelCount = channelCount,
            maxFramesPerMix = config.maxFramesPerMix,
            pollCancellation = { checkDeadlineAndCancel() },
            drainOutputToSink = { makeRoomByServicingSinkDrain() },
        )
    }

    // Pump make-room callback (owner thread, inside a lockstep stall): the
    // production sink is the only consumer, so "make room" means servicing
    // ITS pending drain into ITS buffer; 0 means no drain was pending and the
    // pump sleeps on its own. Never a private read.
    private fun makeRoomByServicingSinkDrain(): Long {
        makeRoomCallbacks += 1L
        if (paused) makeRoomCallbacksWhilePaused += 1L
        val read = serviceDrainRequest(fromMakeRoom = true)
        if (read < 0L) {
            makeRoomIdleReturns += 1L
            return 0L
        }
        return read
    }

    // ── Pre-roll ───────────────────────────────────────────────────────────

    // Feeds decoded lockstep chunks with drains FORBIDDEN (no sink drains
    // yet, no Start enqueued) until the source ring stalls or the whole
    // timeline is ingested; the fill quota mirrors Y18b.
    private fun prefill() {
        val s = requireSession()
        while (true) {
            checkDeadlineAndCancel()
            when (feedStep(allowDrain = false)) {
                Feed.STALLED, Feed.IDLE, Feed.HELD -> break
                Feed.PROGRESSED, Feed.RETRY -> {}
            }
        }
        preStartFillFrames = minOf(s.totalFramesAcceptedTrack0, s.totalFramesAcceptedTrack1)
        val quota = minOf(config.outputRingCapacityFrames.toLong(), expectedFrames)
        if (preStartFillFrames < quota) throw FailClosed("real_ring_prestart_fill_below_quota:$preStartFillFrames:$quota")
    }

    // ── Streaming feed (one bounded step) ──────────────────────────────────

    // One bounded feed step: completes a latched lockstep chunk, ingests the
    // staged slice (truncating to the aligned expectedFrames), pads with
    // explicit zero frames after an early decoder EOS (budgeted), or runs
    // one decode step. STALLED only with drains forbidden; IDLE once the
    // timeline is fully ingested and the decoder is at EOS.
    private fun feedStep(allowDrain: Boolean): Feed {
        val p = requirePump()
        // Y19 evidence counters: the owner-loop gate never calls this while
        // paused or quiesced, so both stay zero structurally. Y20: the
        // post-seek prefill runs feed steps while the gate is still held
        // (counted separately), and nothing runs while held for the seek.
        if (paused) feedStepsWhilePaused += 1L
        if (quiesced && postSeekPrefillActive) postSeekPrefillFeedSteps += 1L
        else if (quiesced && seekHoldReached) feedStepsWhileHeld += 1L
        else if (quiesced) feedStepsWhileQuiesced += 1L
        // Y20 feed cap: until the seek executes no frame past the armed hold
        // frame is ingested; at the hold with nothing staged / latched the
        // feed is HELD (no decode either: the codec is flushed at the seek).
        val holdCapActive = seekHoldArmed && !seekExercised
        val cap = if (holdCapActive) minOf(effectiveExpectedFrames, seekHoldFrame) else effectiveExpectedFrames
        val capIsSeekHold = holdCapActive && seekHoldFrame < effectiveExpectedFrames
        if (pendingSliceFrames == 0 && p.hasPendingChunk) {
            if (!allowDrain) return Feed.STALLED
            p.completePendingLockstep()
            if (!capIsSeekHold && p.framesCommitted >= effectiveExpectedFrames) markIngestComplete()
            return Feed.PROGRESSED
        }
        if (capIsSeekHold && pendingSliceFrames == 0 && p.framesCommitted >= seekHoldFrame) {
            if (!seekHoldReached) {
                seekHoldReached = true
                trace("feed_held_for_seek")
            }
            return Feed.HELD
        }
        if (pendingSliceFrames > 0) {
            val room = cap - p.framesCommitted
            if (room <= 0L) {
                if (capIsSeekHold) {
                    // Staged content past the hold lies inside the skipped
                    // span: honest accounting, never checksummed or ingested.
                    seekHoldDiscardedStagedFrames += pendingSliceFrames.toLong()
                    pendingSliceFrames = 0
                    return Feed.PROGRESSED
                }
                noteTruncated(pendingSliceFrames)
                pendingSliceFrames = 0
                markIngestComplete()
                return Feed.PROGRESSED
            }
            val take = minOf(pendingSliceFrames.toLong(), room).toInt()
            val surplus = pendingSliceFrames - take
            if (surplus > 0) {
                if (capIsSeekHold) seekHoldDiscardedStagedFrames += surplus.toLong() else noteTruncated(surplus)
            }
            val remaining = p.ingestDecodedSlice(slice, take, allowDrain)
            val ingested = (take - remaining).toLong()
            if (!sliceIsPad) framesIngestedReal += ingested
            pendingSliceFrames = remaining
            if (remaining > 0) return Feed.STALLED
            if (!capIsSeekHold && p.framesCommitted >= effectiveExpectedFrames && !p.hasPendingChunk) markIngestComplete()
            return Feed.PROGRESSED
        }
        if (ingestComplete) {
            if (outputEos) return Feed.IDLE
            // Decoder run-out to EOS: every further chunk is truncated above.
            return if (decodeStep()) Feed.PROGRESSED else Feed.RETRY
        }
        if (outputEos) {
            val shortfall = effectiveExpectedFrames - p.framesCommitted
            if (shortfall <= 0L) {
                markIngestComplete()
                return Feed.PROGRESSED
            }
            if (eosPadFrames == 0L && shortfall > padBudgetFrames) {
                throw FailClosed("$REASON_EOS_PAD_BUDGET:$shortfall:$padBudgetFrames")
            }
            val pad = minOf(shortfall, config.maxFramesPerMix.toLong()).toInt()
            ensureSliceCapacity(pad * bytesPerFrame)
            slice.clear()
            for (i in 0 until pad * bytesPerFrame) slice.put(i, 0.toByte())
            pendingSliceFrames = pad
            sliceIsPad = true
            eosPadFrames += pad.toLong()
            eosPadChunks += 1L
            if (eosPadChunks == 1L) trace("eos_pad")
            return Feed.PROGRESSED
        }
        return if (decodeStep()) Feed.PROGRESSED else Feed.RETRY
    }

    private fun markIngestComplete() {
        if (ingestComplete) return
        ingestComplete = true
        trace("ingest_complete")
    }

    // Never-ingested decoded frames past the aligned budget: honest
    // accounting only, traced once, kept out of every identity claim.
    private fun noteTruncated(frames: Int) {
        if (eosTruncatedFrames == 0L) trace("eos_truncate")
        eosTruncatedFrames += frames.toLong()
    }

    // Owner-owned direct staging slice: sized to the native ingest clamp on
    // first use, grown (counted) only for an oversized codec chunk. Never
    // called while a slice is pending, so replacing the buffer is safe.
    private fun ensureSliceCapacity(bytes: Int) {
        if (slice.capacity() >= bytes) return
        val defaultBytes = STAGING_SLICE_FRAMES * bytesPerFrame
        val capacityBytes = maxOf(defaultBytes, bytes)
        slice = ByteBuffer.allocateDirect(capacityBytes).order(ByteOrder.LITTLE_ENDIAN)
        if (bytes > defaultBytes) sliceGrowths++
    }

    // ── Codec pump (synchronous mode, owner thread only) ───────────────────

    // Feeds at most one input buffer and pulls at most one output chunk
    // (copied into the owner's own direct slice, codec buffer released before
    // this returns) with the frozen bounded dequeue waits. True when a chunk
    // was staged, the format resolved, or EOS was reached; false on try-again.
    private fun decodeStep(): Boolean {
        if (pendingSliceFrames > 0) throw FailClosed("real_ring_decode_over_pending_slice")
        if (outputEos) return false
        val dec = codec ?: throw FailClosed(REASON_PREFIX_DECODER + "codec_missing")
        val ex = extractor ?: throw FailClosed(REASON_PREFIX_DECODER + "extractor_missing")
        noteCodecCall()
        decodeSteps++
        return decoderGuard("step") {
            if (!inputEos) {
                val inIdx = dec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                if (inIdx >= 0) {
                    val inBuf = dec.getInputBuffer(inIdx) ?: throw FailClosed(REASON_PREFIX_DECODER + "null_input_buffer")
                    val size = ex.readSampleData(inBuf, 0)
                    val pts = ex.sampleTime
                    if (size < 0 || pts > inputEndUs) {
                        dec.queueInputBuffer(inIdx, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputEos = true
                    } else {
                        dec.queueInputBuffer(inIdx, 0, size, pts, 0)
                        inputSamplesQueued++
                        ex.advance()
                    }
                }
            }
            val outIdx = dec.dequeueOutputBuffer(bufferInfo, DEQUEUE_TIMEOUT_US)
            when {
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    resolveOutputFormat(dec.outputFormat)
                    true
                }
                outIdx >= 0 -> {
                    val isEos = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    val size = bufferInfo.size
                    if (size > 0) {
                        if (!formatResolved) resolveOutputFormat(dec.outputFormat)
                        if (size % bytesPerFrame != 0) {
                            dec.releaseOutputBuffer(outIdx, false)
                            throw FailClosed(REASON_PREFIX_DECODER + "codec_chunk_shape_invalid:$size")
                        }
                        val frames = size / bytesPerFrame
                        // Y20: after the extractor re-anchor (which may land
                        // at a sync point BEFORE the target) decoded frames
                        // whose pts lies before the target are discarded
                        // (counted), so ingested post-seek content starts at
                        // the target within one frame of pts rounding.
                        var dropFrames = 0
                        if (postSeekPreTargetDiscardActive) {
                            val pts = bufferInfo.presentationTimeUs
                            if (firstPostSeekChunkPtsUs < 0L) firstPostSeekChunkPtsUs = pts
                            if (pts < seekTargetUs) {
                                val lead = ((seekTargetUs - pts) * sampleRate.toLong() + 999_999L) / 1_000_000L
                                dropFrames = minOf(frames.toLong(), lead).toInt()
                            }
                            if (dropFrames < frames) {
                                postSeekPreTargetDiscardActive = false
                                firstIngestedPostSeekPtsUs = pts + dropFrames.toLong() * 1_000_000L / sampleRate.toLong()
                            }
                        }
                        val stagedFrames = frames - dropFrames
                        if (stagedFrames > 0) {
                            val outBuf = dec.getOutputBuffer(outIdx)
                            if (outBuf == null) {
                                dec.releaseOutputBuffer(outIdx, false)
                                throw FailClosed(REASON_PREFIX_DECODER + "null_output_buffer")
                            }
                            codecOutputHeld = true
                            try {
                                ensureSliceCapacity(stagedFrames * bytesPerFrame)
                                outBuf.position(bufferInfo.offset + dropFrames * bytesPerFrame)
                                outBuf.limit(bufferInfo.offset + size)
                                slice.clear()
                                slice.put(outBuf)
                            } finally {
                                dec.releaseOutputBuffer(outIdx, false)
                                codecOutputHeld = false
                            }
                            pendingSliceFrames = stagedFrames
                            sliceIsPad = false
                        } else {
                            dec.releaseOutputBuffer(outIdx, false)
                        }
                        preTargetDiscardedFrames += dropFrames.toLong()
                        decoderChunks++
                        framesDecoded += frames.toLong()
                    } else {
                        dec.releaseOutputBuffer(outIdx, false)
                    }
                    if (isEos) {
                        outputEos = true
                        trace("decoder_eos")
                        if (stage == Stage.ACTIVE_DRAIN || stage == Stage.TRANSPORT_START) stage = Stage.DECODER_EOS
                        // The last output is staged in owner-owned memory:
                        // codec + extractor are released exactly once, here.
                        releaseMediaOnce()
                        mediaReleasedAtDecoderEos = mediaReleaseCount == 1
                    }
                    true
                }
                else -> {
                    // INFO_TRY_AGAIN_LATER / deprecated buffers-changed: bounded by the deadline.
                    tryAgainSteps++
                    false
                }
            }
        }
    }

    // Owner thread; exactly once on every path (decoder EOS or finally).
    private fun releaseMediaOnce() {
        if (mediaReleaseCount > 0) return
        mediaReleaseCount = 1
        val dec = codec
        val ex = extractor
        codec = null
        extractor = null
        if (dec != null) {
            noteCodecCall()
            try { dec.stop() } catch (_: Throwable) { mediaReleaseClean = false }
            try { dec.release() } catch (_: Throwable) { mediaReleaseClean = false }
            codecReleaseCount++
        }
        if (ex != null) {
            try { ex.release() } catch (_: Throwable) { mediaReleaseClean = false }
            extractorReleaseCount++
        }
    }

    // ── Owner loop ─────────────────────────────────────────────────────────

    // Services Start / drain / control requests with priority, runs one
    // bounded feed step (draining before and after it), then polls
    // (snapshot-only, no ring read) for timeline completion to set the joint
    // EOS once; idles on the request condition otherwise. Y19 gate: while
    // quiesced or paused NO feed step and NO EOS poll run; a quiesced owner
    // still services drains, a paused owner rejects them.
    private fun ownerLoop() {
        val s = requireSession()
        while (!stopRequested.get()) {
            ownerLoopIterations += 1L
            if (paused) ownerLoopIterationsWhilePaused += 1L
            if (SystemClock.elapsedRealtime() > config.deadlineAtMs) throw FailClosed(REASON_DEADLINE)
            var progressed = false
            if (!started && startRequested.get()) {
                val startAt = SystemClock.elapsedRealtime()
                transportCommandsIssued += 1L
                s.startAndConsumeAck()
                started = true
                setStage(Stage.TRANSPORT_START, "transport_start")
                startWallMs = SystemClock.elapsedRealtime() - startAt
                nextEosPollAtMs = 0L
                startLatch.countDown()
                progressed = true
            }
            if (serviceDrainRequest(fromMakeRoom = false) >= 0L) progressed = true
            if (serviceControlRequest(s)) progressed = true
            if (started && !paused && !quiesced) {
                if (!ingestComplete || !outputEos) {
                    when (feedStep(allowDrain = true)) {
                        Feed.PROGRESSED, Feed.RETRY -> progressed = true
                        Feed.STALLED -> throw FailClosed(REASON_PREFIX_LOCKSTEP + "stall_with_drain_allowed")
                        Feed.IDLE, Feed.HELD -> {}
                    }
                } else if (!s.eosSetWithoutDrain) {
                    val now = SystemClock.elapsedRealtime()
                    if (now >= nextEosPollAtMs) {
                        eosPollSnapshots += 1L
                        if (paused) eosPollsWhilePaused += 1L
                        if (s.tryCompleteTimelineAndSetEosWithoutDrain()) {
                            setStage(Stage.EOS_SET, "eos_set_without_drain")
                            progressed = true
                        }
                        nextEosPollAtMs = now + EOS_POLL_INTERVAL_MS
                    }
                }
                if (serviceDrainRequest(fromMakeRoom = false) >= 0L) progressed = true
            }
            if (!progressed) {
                requestLock.withLock {
                    if (pendingDrain == null && pendingControl == null &&
                        !stopRequested.get() && !(startRequested.get() && !started)
                    ) {
                        try {
                            requestCondition.await(OWNER_IDLE_WAIT_MS, TimeUnit.MILLISECONDS)
                        } catch (_: InterruptedException) {
                            Thread.currentThread().interrupt()
                            throw FailClosed("real_ring_owner_interrupted")
                        }
                    }
                }
            }
        }
    }

    // ── Y19 owner-thread control execution ─────────────────────────────────

    private fun atCleanBoundary(): Boolean =
        pendingSliceFrames == 0 && !requirePump().hasPendingChunk && !codecOutputHeld && !ingestComplete

    // Takes the request out of the slot; false when the requester already
    // withdrew it (timeout), in which case nothing executes.
    private fun takeControl(r: ControlRequest): Boolean = requestLock.withLock {
        if (pendingControl === r) {
            pendingControl = null
            true
        } else {
            false
        }
    }

    private fun completeControl(r: ControlRequest, ok: Boolean, reason: String) {
        r.ok = ok
        r.reason = reason
        r.latch.countDown()
    }

    // Typed fail-closed on a control request: the requester is released
    // with the reason first, then the owner loop fails closed.
    private fun failControl(r: ControlRequest, reason: String): Nothing {
        takeControl(r)
        completeControl(r, false, reason)
        throw FailClosed(reason)
    }

    // Peeks the pending control; a QUIESCE stays pending (feed continues)
    // until the clean boundary is reached, every other kind is taken and
    // executed at once. True when a request completed this iteration.
    private fun serviceControlRequest(s: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession): Boolean {
        val r = requestLock.withLock { pendingControl } ?: return false
        if (!started) failControl(r, REASON_CONTROL_BEFORE_START)
        return when (r.kind) {
            Control.QUIESCE -> serviceQuiesce(r)
            Control.PAUSE -> {
                if (!takeControl(r)) return false
                executePause(s, r)
                true
            }
            Control.HOLD_ASSERT -> {
                if (!takeControl(r)) return false
                executeHoldAssert(s, r)
                true
            }
            Control.RESUME -> {
                if (!takeControl(r)) return false
                executeResume(s, r)
                true
            }
            Control.QUIESCE_FOR_SEEK -> serviceQuiesceForSeek(r)
            Control.SEEK -> {
                if (!takeControl(r)) return false
                executeSeek(s, r)
                true
            }
        }
    }

    // ── Y20 owner-thread seek execution ────────────────────────────────────

    // Arms the feed cap at the request's hold frame on first sight, then
    // stays pending (feed running under the cap, drains serviced) until the
    // feed is HELD at exactly that frame at a clean boundary; only then the
    // feed gate closes (quiesced) and the request completes.
    private fun serviceQuiesceForSeek(r: ControlRequest): Boolean {
        val p = requirePump()
        if (!seekHoldArmed) {
            if (quiesced || paused) {
                takeControl(r)
                completeControl(r, false, REASON_SEEK_HOLD_ALREADY_HELD)
                return true
            }
            if (seekExercised) failControl(r, REASON_SEEK_ALREADY_EXERCISED)
            if (ingestComplete) failControl(r, REASON_SEEK_HOLD_AFTER_INGEST_COMPLETE)
            val window = config.maxFramesPerMix.toLong()
            if (r.frame <= 0L || r.frame % window != 0L || r.frame >= effectiveExpectedFrames) {
                failControl(r, "$REASON_SEEK_HOLD_INVALID${r.frame}:$window:$effectiveExpectedFrames")
            }
            if (p.framesCommitted > r.frame) {
                failControl(r, "$REASON_SEEK_HOLD_ALREADY_PASSED${p.framesCommitted}:${r.frame}")
            }
            seekHoldFrame = r.frame
            seekHoldCommittedFramesAtArm = p.framesCommitted
            seekHoldArmedOnOwnerThread = Thread.currentThread().id == ownerThreadId
            seekHoldArmed = true
            trace("seek_hold_armed")
        }
        if (ingestComplete) failControl(r, REASON_SEEK_HOLD_AFTER_INGEST_COMPLETE)
        if (!seekHoldReached || !atCleanBoundary() || p.framesCommitted != seekHoldFrame) return false
        if (!takeControl(r)) return false
        quiesced = true
        seekHoldAckOk = true
        seekHoldExecutedOnOwnerThread = Thread.currentThread().id == ownerThreadId
        seekHoldWallMs = SystemClock.elapsedRealtime() - r.enqueuedAtMs
        framesReadBySinkAtHold = framesReadBySink
        drainsServicedAtHold = drainsServiced
        framesAcceptedTrack0AtHold = requireSession().totalFramesAcceptedTrack0
        framesAcceptedTrack1AtHold = requireSession().totalFramesAcceptedTrack1
        framesDecodedAtHold = framesDecoded
        decodeStepsAtHold = decodeSteps
        trace("feed_quiesced_for_seek")
        completeControl(r, true, REASON_OK)
        return true
    }

    // The ONE forward seek (class comment). Every step runs on this owner
    // thread; the request is completed with a typed reason on any failure
    // and the owner loop then fails closed.
    private fun executeSeek(s: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession, r: ControlRequest) {
        if (seekExercised) failControl(r, REASON_SEEK_ALREADY_EXERCISED)
        if (paused) failControl(r, REASON_SEEK_WHILE_PAUSED)
        if (!seekHoldArmed || !seekHoldReached || !quiesced) failControl(r, REASON_SEEK_NOT_HELD)
        val p = requirePump()
        seekPendingSliceFramesAtRequest = pendingSliceFrames
        seekPumpPendingChunkAtRequest = p.hasPendingChunk
        seekCodecOutputHeldAtRequest = codecOutputHeld
        seekIngestCompleteAtRequest = ingestComplete
        seekPausedAtRequest = paused
        seekCleanBoundaryOk = atCleanBoundary() && p.framesCommitted == seekHoldFrame
        if (!seekCleanBoundaryOk) {
            failControl(
                r,
                "$REASON_SEEK_NOT_AT_CLEAN_BOUNDARY$pendingSliceFrames:${p.hasPendingChunk}:$codecOutputHeld:$ingestComplete:${p.framesCommitted}:$seekHoldFrame",
            )
        }
        if (outputEos || codec == null || extractor == null) failControl(r, REASON_SEEK_AFTER_DECODER_EOS)
        val target = r.frame
        val window = config.maxFramesPerMix.toLong()
        if (target <= seekHoldFrame || target % window != 0L || target >= effectiveExpectedFrames) {
            failControl(r, "$REASON_SEEK_TARGET_INVALID$target:$seekHoldFrame:$window:$effectiveExpectedFrames")
        }
        val skip = target - seekHoldFrame
        if (skip < seekHoldDiscardedStagedFrames) {
            failControl(r, "$REASON_SEEK_SKIP_BELOW_DISCARDED$skip:$seekHoldDiscardedStagedFrames")
        }
        // The production sink is the only output consumer: it must already
        // have read every frame pushed up to the hold (no private drain).
        if (framesReadBySink != seekHoldFrame) {
            failControl(r, "$REASON_SEEK_SINK_NOT_DRAINED_TO_HOLD$framesReadBySink:$seekHoldFrame")
        }
        seekExercised = true
        seekInProgress = true
        seekQuiescedFirst = quiesced
        seekExecutedOnOwnerThread = Thread.currentThread().id == ownerThreadId
        seekTargetFrame = target
        seekSkipFrames = skip
        framesReadBySinkAtSeek = framesReadBySink
        drainsServicedAtSeek = drainsServiced
        stageBeforeSeek = stage
        inputEosAtSeek = inputEos
        outputEosAtSeek = outputEos
        setStage(Stage.SEEKING, "seeking")
        val at = SystemClock.elapsedRealtime()
        try {
            // 1. Native quiescence at H, snapshot-only (no private drain).
            s.assertQuiescentForSeek(seekHoldFrame)
            // 2. Native joint seek to T (skipped == T - H asserted inside).
            transportCommandsIssued += 1L
            s.seek(target)
            trace("native_seek_processed")
            val playable = s.seekExpectedPlayableAtProcessed
            if (s.seekSkippedFramesAtProcessed != skip || playable != expectedFrames - skip) {
                throw FailClosed("$REASON_SEEK_EFFECTIVE_FRAMES_MISMATCH${s.seekSkippedFramesAtProcessed}:$skip:$playable")
            }
            effectiveExpectedFrames = playable
            // 3. Synthetic generator re-anchor on the pump's accepted-count
            //    axis (the pump's own invariant; the Kotlin reference mix and
            //    the native mix see identical track-1 samples either way).
            generatorReanchorFrame = p.kotlinFramesAccepted
            p.reanchorSyntheticGenerator(generatorReanchorFrame)
            // 4. Extractor re-anchor + codec flush, consistently on this thread.
            reanchorMediaForSeek(target)
            // 5. Post-seek lockstep prefill with drains forbidden (the pending
            //    output ack must survive until the quota is met or a stall).
            prefillAfterSeek(p)
            // 6. Output seek ack: ack-only read, zero discard (ring was empty).
            val ackAt = SystemClock.elapsedRealtime()
            s.consumeSeekAckAndReanchor()
            seekAckWallMs = SystemClock.elapsedRealtime() - ackAt
            finalSeekAckConsumed = s.seekAckConsumedByAckOnlyRead
            finalSeekAckNewStartFrame = s.seekAckNewStartFrame
            finalSeekAckDiscardedFrames = s.seekAckDiscardedFrames
            finalSeekAckTotalDiscardedOnSeekFrames = s.seekAckTotalDiscardedOnSeekFrames
            trace("seek_ack_consumed")
        } catch (t: Throwable) {
            seekInProgress = false
            completeControl(r, false, describe(t))
            throw t
        }
        seekWallMs = SystemClock.elapsedRealtime() - at
        // Release the gates: the feed resumes past the re-anchored boundary
        // (a latched prefill chunk completes on the next owner feed step).
        seekInProgress = false
        quiesced = false
        val restored = Stage.ACTIVE_DRAIN
        setStage(restored, "seek_reanchored")
        stageAfterSeek = restored
        nextEosPollAtMs = 0L
        seekAckOk = s.seekReanchorOk && finalSeekAckConsumed
        completeControl(r, seekAckOk, if (seekAckOk) REASON_OK else "real_ring_native_seek_ack_missing")
    }

    // MediaExtractor.seekTo(SEEK_TO_PREVIOUS_SYNC) + MediaCodec.flush on the
    // owner thread. Landing at or before the target is Android extractor
    // behavior and is reported, never claimed exact; frames decoded before
    // the target are discarded by [decodeStep] (counted). The input EOS flag
    // is re-armed so the feed re-queues samples from the new position.
    private fun reanchorMediaForSeek(targetFrame: Long) {
        val dec = codec ?: throw FailClosed(REASON_PREFIX_DECODER + "codec_missing")
        val ex = extractor ?: throw FailClosed(REASON_PREFIX_DECODER + "extractor_missing")
        seekTargetUs = (targetFrame * 1_000_000L + sampleRate.toLong() - 1L) / sampleRate.toLong()
        if (pendingSliceFrames != 0) throw FailClosed("real_ring_seek_reanchor_over_pending_slice")
        noteCodecCall()
        decoderGuard("seek_reanchor") {
            ex.seekTo(seekTargetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            extractorSeekCalls += 1L
            val landing = ex.sampleTime
            if (landing < 0L) throw FailClosed(REASON_SEEK_LANDING_UNAVAILABLE)
            seekLandingPtsUs = landing
            seekLandingLeadUs = seekTargetUs - landing
            seekLandingAtOrBeforeTarget = landing <= seekTargetUs
            trace("extractor_reanchored")
            dec.flush()
            codecFlushCalls += 1L
            trace("codec_flushed")
        }
        extractorReanchoredOnOwnerThread = Thread.currentThread().id == ownerThreadId
        inputEos = false
        postSeekPreTargetDiscardActive = true
    }

    // Post-seek lockstep source prefill: feed steps with drains FORBIDDEN
    // until the quota (one output ring, or the whole remaining timeline) is
    // committed or the source rings stall (a stalled sub-chunk stays latched
    // and completes after the ack, exactly like the pre-start pre-roll).
    private fun prefillAfterSeek(p: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockIngestPump) {
        val s = requireSession()
        val start = SystemClock.elapsedRealtime()
        val remainingFrames = effectiveExpectedFrames - seekHoldFrame
        postSeekPrefillQuotaFrames = minOf(config.outputRingCapacityFrames.toLong(), remainingFrames)
        postSeekPrefillActive = true
        trace("post_seek_prefill")
        try {
            while (true) {
                checkDeadlineAndCancel()
                if (p.framesCommitted - seekHoldFrame >= postSeekPrefillQuotaFrames) break
                when (feedStep(allowDrain = false)) {
                    Feed.STALLED -> {
                        postSeekPrefillStalled = true
                        break
                    }
                    Feed.IDLE, Feed.HELD -> break
                    Feed.PROGRESSED, Feed.RETRY -> {}
                }
            }
        } finally {
            postSeekPrefillActive = false
        }
        postSeekPrefillCommittedFrames = p.framesCommitted - seekHoldFrame
        postSeekPrefillAcceptedFrames = minOf(s.totalFramesAcceptedTrack0, s.totalFramesAcceptedTrack1) - seekHoldFrame
        postSeekPrefillWallMs = SystemClock.elapsedRealtime() - start
        if (postSeekPrefillAcceptedFrames <= 0L) throw FailClosed(REASON_SEEK_PREFILL_EMPTY)
    }

    private fun serviceQuiesce(r: ControlRequest): Boolean {
        if (quiesced || paused) {
            takeControl(r)
            completeControl(r, false, "real_ring_quiesce_already_held")
            return true
        }
        if (ingestComplete) failControl(r, REASON_QUIESCE_AFTER_INGEST_COMPLETE)
        if (!atCleanBoundary()) return false
        if (!takeControl(r)) return false
        quiesced = true
        quiesceAckOk = true
        quiesceExecutedOnOwnerThread = Thread.currentThread().id == ownerThreadId
        quiesceWallMs = SystemClock.elapsedRealtime() - r.enqueuedAtMs
        trace("feed_quiesced")
        completeControl(r, true, REASON_OK)
        return true
    }

    private fun executePause(s: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession, r: ControlRequest) {
        if (pauseExercised) failControl(r, REASON_PAUSE_ALREADY_EXERCISED)
        val p = requirePump()
        pausePendingSliceFramesAtRequest = pendingSliceFrames
        pausePumpPendingChunkAtRequest = p.hasPendingChunk
        pauseCodecOutputHeldAtRequest = codecOutputHeld
        pauseIngestCompleteAtRequest = ingestComplete
        pauseCleanBoundaryOk = atCleanBoundary()
        if (!pauseCleanBoundaryOk) {
            failControl(
                r,
                "$REASON_PAUSE_NOT_AT_CLEAN_BOUNDARY$pendingSliceFrames:${p.hasPendingChunk}:$codecOutputHeld:$ingestComplete",
            )
        }
        pauseExercised = true
        pauseQuiescedFirst = quiesced
        pauseExecutedOnOwnerThread = Thread.currentThread().id == ownerThreadId
        val at = SystemClock.elapsedRealtime()
        transportCommandsIssued += 1L
        try {
            s.pauseAndAwaitProof()
        } catch (t: Throwable) {
            completeControl(r, false, describe(t))
            throw t
        }
        pauseWallMs = SystemClock.elapsedRealtime() - at
        nativePauseProofOk = s.pauseProofNativePauseOk
        pauseCommandSeq = s.pauseProofCommandSeq
        dispatchCountAtPause = s.pauseProofDispatchCountAtPause
        totalFramesPushedAtPause = s.pauseProofTotalFramesPushedAtPause
        nextDispatchFrameAtPause = s.pauseProofNextDispatchFrameAtPause
        framesPendingAtPause = s.pauseProofFramesPendingAtPause
        pausedWaitsAtPause = s.pauseProofPausedWaitsAtPause
        framesReadBySinkAtPause = framesReadBySink
        drainsServicedAtPause = drainsServiced
        pumpFramesAcceptedAtPause = p.kotlinFramesAccepted
        framesAcceptedTrack0AtPause = s.totalFramesAcceptedTrack0
        framesAcceptedTrack1AtPause = s.totalFramesAcceptedTrack1
        framesDecodedAtPause = framesDecoded
        decodeStepsAtPause = decodeSteps
        stageBeforePause = stage
        pausedAtNs = System.nanoTime()
        // Gate first (sink-thread drains reject from here on), then stage.
        paused = true
        setStage(Stage.PAUSED, "paused")
        pauseAckOk = nativePauseProofOk
        completeControl(r, pauseAckOk, if (pauseAckOk) REASON_OK else "real_ring_native_pause_proof_missing")
    }

    private fun executeHoldAssert(s: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession, r: ControlRequest) {
        if (!paused) failControl(r, REASON_HOLD_ASSERT_NOT_PAUSED)
        if (holdAssertExercised) failControl(r, REASON_HOLD_ASSERT_ALREADY_EXERCISED)
        holdAssertExercised = true
        holdAssertExecutedOnOwnerThread = Thread.currentThread().id == ownerThreadId
        try {
            s.assertPausedHoldFrozen()
        } catch (t: Throwable) {
            completeControl(r, false, describe(t))
            throw t
        }
        holdAssertObservedNs = System.nanoTime() - pausedAtNs
        nativeHoldFrozenProofOk = s.pauseProofHoldFrozenOk
        dispatchCountAfterHold = s.pauseProofDispatchCountAfterHold
        totalFramesPushedAfterHold = s.pauseProofTotalFramesPushedAfterHold
        pausedWaitsAfterHold = s.pauseProofPausedWaitsAfterHold
        framesReadBySinkAfterHold = framesReadBySink
        drainsServicedAfterHold = drainsServiced
        pumpFramesAcceptedAfterHold = requirePump().kotlinFramesAccepted
        trace("paused_hold_frozen")
        holdAssertAckOk = nativeHoldFrozenProofOk
        completeControl(r, holdAssertAckOk, if (holdAssertAckOk) REASON_OK else "real_ring_native_hold_proof_missing")
    }

    private fun executeResume(s: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession, r: ControlRequest) {
        if (!paused) failControl(r, REASON_RESUME_NOT_PAUSED)
        if (!holdAssertExercised) failControl(r, REASON_RESUME_BEFORE_HOLD_ASSERT)
        if (resumeExercised) failControl(r, REASON_RESUME_ALREADY_EXERCISED)
        resumeExercised = true
        resumeExecutedOnOwnerThread = Thread.currentThread().id == ownerThreadId
        val at = SystemClock.elapsedRealtime()
        transportCommandsIssued += 1L
        val snap = try {
            s.resumeAndAwaitProof()
        } catch (t: Throwable) {
            completeControl(r, false, describe(t))
            throw t
        }
        resumeWallMs = SystemClock.elapsedRealtime() - at
        pauseHoldObservedNs = System.nanoTime() - pausedAtNs
        nativeResumeProofOk = s.pauseProofNativeResumeOk
        resumeCommandSeq = s.resumeProofCommandSeq
        dispatchCountAtResume = snap["dispatchCountAtResume"]?.toLongOrNull() ?: -1L
        totalFramesPushedAtResume = snap["totalFramesPushedAtResume"]?.toLongOrNull() ?: -1L
        nativeLastPausedIntervalNs = snap["lastPausedIntervalNs"]?.toLongOrNull() ?: -1L
        nativeTotalPausedNs = snap["totalPausedNs"]?.toLongOrNull() ?: -1L
        framesReadBySinkAtResume = framesReadBySink
        pumpFramesAcceptedAtResume = requirePump().kotlinFramesAccepted
        decodeStepsWhilePaused = decodeSteps - decodeStepsAtPause
        // Release the gate: feed resumes at the SAME clean boundary it held.
        paused = false
        quiesced = false
        val restored = stageBeforePause ?: Stage.ACTIVE_DRAIN
        setStage(restored, "resumed")
        stageAfterResume = restored
        nextEosPollAtMs = 0L
        resumeAckOk = nativeResumeProofOk
        completeControl(r, resumeAckOk, if (resumeAckOk) REASON_OK else "real_ring_native_resume_proof_missing")
    }

    private fun describe(t: Throwable): String = when (t) {
        is AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession.Failure -> REASON_PREFIX_NATIVE + t.reason
        is FailClosed -> t.reason
        else -> "exception:${t.javaClass.simpleName}:${t.message}"
    }

    // Owner thread, finally block (after the drain gate closed): the one
    // control request that may still be pending is released with the
    // terminal reason so no requester waits for its timeout.
    private fun rejectPendingControl() {
        val r = requestLock.withLock {
            val c = pendingControl
            pendingControl = null
            c
        } ?: return
        completeControl(
            r,
            false,
            if (stage == Stage.FAILED) "real_ring_owner_failed:${failureReason.ifBlank { "unknown" }}" else REASON_CONTROL_CLOSED,
        )
    }

    // One pending sink drain: destructive read straight into the sink's
    // buffer on THIS owner thread, reply translated to the seam type.
    // Returns the frames read (>= 0) when a request was serviced, -1 when
    // none was pending. A read failure completes the request with a
    // rejection and fails the owner loop closed (typed sink failure).
    private fun serviceDrainRequest(fromMakeRoom: Boolean): Long {
        val request = requestLock.withLock {
            val r = pendingDrain
            pendingDrain = null
            r
        } ?: return -1L
        try {
            val latencyMs = SystemClock.elapsedRealtime() - request.enqueuedAtMs
            if (latencyMs > maxDrainServiceLatencyMs) maxDrainServiceLatencyMs = latencyMs
            if (latencyMs > config.drainWaitBoundMs) drainLatencyBoundViolations += 1L
            if (!started) {
                drainsBeforeStartRejected += 1L
                request.result = reject(REASON_DRAIN_BEFORE_START)
                return 0L
            }
            // Y19: a drain that raced the pause gate is rejected here without
            // any native read (the output ring is never touched while paused).
            if (paused) {
                pausedDrainRejectsOwnerThread += 1L
                request.result = reject(REASON_DRAIN_WHILE_PAUSED)
                return 0L
            }
            // Y20: no native read while the seek executes (the pending output
            // ack must be consumed by the ack-only read, never inside a sink
            // read); the sink is seek-parked, so this is telemetry only.
            if (seekInProgress) {
                seekDrainRejectsOwnerThread += 1L
                request.result = reject(REASON_DRAIN_DURING_SEEK)
                return 0L
            }
            val s = requireSession()
            val r = s.readOutputInto(request.dst, request.maxFrames)
            drainsServiced += 1L
            if (fromMakeRoom) drainsServicedFromMakeRoom += 1L
            if (r.framesRead > 0L) {
                framesReadBySink += r.framesRead
                if (stage == Stage.TRANSPORT_START) setStage(Stage.ACTIVE_DRAIN, "active_drain")
            } else {
                emptyReadsServiced += 1L
            }
            if (r.eosDrained) eosDrainedObservedByRing = true
            request.result = VanguardRealtimeAudioPlaybackFrameSource.DrainResult(true, REASON_OK, toReply(r))
            return r.framesRead
        } catch (t: Throwable) {
            val reason = when (t) {
                is AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession.Failure -> REASON_PREFIX_NATIVE + t.reason
                is FailClosed -> t.reason
                else -> "exception:${t.javaClass.simpleName}:${t.message}"
            }
            request.result = reject("real_ring_read_failed:$reason")
            throw FailClosed("${REASON_PREFIX_SINK}read_failed:$reason")
        } finally {
            request.latch.countDown()
        }
    }

    // Field-for-field translation of the native read reply into the seam's
    // production reply type through the production parser (no synthesized
    // EOS: eosDrained / eosPushed are the native verdicts).
    private fun toReply(r: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession.SinkReadReply): VanguardRealtimePlaybackNativeSession.Reply {
        val stateToken = if (r.eosDrained) {
            VanguardRealtimePlaybackNativeSession.NativeState.COMPLETED.token
        } else {
            VanguardRealtimePlaybackNativeSession.NativeState.PLAYING.token
        }
        val raw = "status=${VanguardRealtimePlaybackNativeSession.STATUS_OK};state=$stateToken;handle=0;" +
            "trackCount=$TRACK_COUNT;declaredFrameCount=$expectedFrames;" +
            "maxFramesPerMix=${config.maxFramesPerMix};sampleRate=$sampleRate;channelCount=$channelCount;" +
            "renderedFrames=${r.totalFramesPushed};pushedFrames=${r.totalFramesPushed};drainedFrames=${r.totalOutputFramesRead};" +
            "discardedFrames=0;positionFrame=${r.totalOutputFramesRead};eosPushed=${r.eosPublished};eosDrained=${r.eosDrained};" +
            "commandSeq=0;commandResult=none;lastError=none;wrongOwnerThread=false;" +
            "outputAvailableReadFrames=${r.outputAvailableReadFrames};" +
            "drainedChecksumHex=${r.nativeOutputReadChecksumHex};" +
            "framesRead=${r.framesRead};bytesRead=${r.bytesRead};nativeClockState=none"
        return VanguardRealtimePlaybackNativeSession.parseReply(raw)
    }

    // Owner thread, finally block: closes the request gate under the lock
    // (no later drain can enqueue) and rejects the one request that may
    // still be pending.
    private fun rejectPendingDrain() {
        val request = requestLock.withLock {
            acceptingRequests = false
            val r = pendingDrain
            pendingDrain = null
            r
        } ?: return
        request.result = reject(
            if (stage == Stage.FAILED) "real_ring_owner_failed:${failureReason.ifBlank { "unknown" }}" else "real_ring_closed",
        )
        request.latch.countDown()
    }

    // Final snapshot (folded facts), owner-side checksum chain verdict,
    // destroy + join verdicts, finally-safe cleanup; every step is
    // best-effort so the native worker is always joined even after a failure.
    private fun finalizeSession() {
        val s = session ?: return
        try {
            if (s.isCreated) {
                val snap = s.finalSnapshot()
                finalNative = foldNative(s, snap)
                finalNativeExpectedPlayableFrameCount = s.snapExpectedPlayableFrameCount
                finalNativeTotalForwardSeekSkippedFrames = s.snapTotalForwardSeekSkippedFrames
                finalNativeTotalDiscardedOnSeekFrames = s.snapTotalDiscardedOnSeekFrames
                finalNativeSeekSkipAnomalies = s.snapSeekSkipAnomalies
                finalNativeNextDispatchFrame = s.snapNextDispatchFrame
                finalNativeOutputSeekRequest = s.snapOutputSeekRequest
                finalNativeOutputSeekAck = s.snapOutputSeekAck
                finalNativeSourceSeekRequestTrack0 = s.snapSourceSeekRequestTrack[0]
                finalNativeSourceSeekAckTrack0 = s.snapSourceSeekAckTrack[0]
                finalNativeSourceSeekRequestTrack1 = s.snapSourceSeekRequestTrack[1]
                finalNativeSourceSeekAckTrack1 = s.snapSourceSeekAckTrack[1]
                finalNativeWriterNextWriteFrameTrack0 = s.snapWriterNextWriteFrameTrack[0]
                finalNativeWriterNextWriteFrameTrack1 = s.snapWriterNextWriteFrameTrack[1]
                finalNativeTimingT1Ns = s.snapNativeTimingT1Ns
                finalNativeProviderExternalReanchorCountTrack0 = s.snapProviderExternalReanchorCountTrack[0]
                finalNativeProviderExternalReanchorCountTrack1 = s.snapProviderExternalReanchorCountTrack[1]
                finalNativeProviderLastExternalReanchorFrameTrack0 = s.snapProviderLastExternalReanchorFrameTrack[0]
                finalNativeProviderLastExternalReanchorFrameTrack1 = s.snapProviderLastExternalReanchorFrameTrack[1]
                finalNativeProviderForwardSkipFramesTrack0 = s.snapProviderForwardSkipFramesTrack[0]
                finalNativeProviderForwardSkipFramesTrack1 = s.snapProviderForwardSkipFramesTrack[1]
                finalNativeProviderRewindRejectsTrack0 = s.snapProviderRewindRejectsTrack[0]
                finalNativeProviderRewindRejectsTrack1 = s.snapProviderRewindRejectsTrack[1]
            }
        } catch (t: Throwable) {
            if (failureReason.isBlank()) {
                fail(
                    if (t is AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession.Failure) "${REASON_PREFIX_NATIVE}final_snapshot:${t.reason}"
                    else "${REASON_PREFIX_NATIVE}final_snapshot:${t.javaClass.simpleName}",
                )
            }
        }
        finalTotalOutputFramesRead = s.totalOutputFramesRead
        finalNativeOutputReadChecksumHex = s.nativeOutputReadChecksumHex
        finalNativeAcceptedChecksumHexTrack0 = s.nativeAcceptedChecksumHexTrack0
        finalNativeAcceptedChecksumHexTrack1 = s.nativeAcceptedChecksumHexTrack1
        finalFramesAcceptedTrack0 = s.totalFramesAcceptedTrack0
        finalFramesAcceptedTrack1 = s.totalFramesAcceptedTrack1
        finalWriterBackpressureRejects = s.writerBackpressureRejects
        finalEosSetWithoutDrain = s.eosSetWithoutDrain
        finalTotalFramesPushedAtEos = s.totalFramesPushedAtEos
        finalExpectedPlayableFrameCountAtEos = s.expectedPlayableFrameCountAtEos
        finalTotalForwardSeekSkippedFramesAtEos = s.totalForwardSeekSkippedFramesAtEos
        val p = pump
        // Y20: seek-aware chain: every identity holds over the EFFECTIVE
        // expected frames (== expectedFrames without a seek), never over the
        // original count after a true skip.
        val effective = effectiveExpectedFrames
        finalChecksumChainSelfOk = p != null && !p.hasPendingChunk && effective > 0L &&
            p.kotlinFramesAccepted == effective &&
            s.totalFramesAcceptedTrack0 == effective && s.totalFramesAcceptedTrack1 == effective &&
            s.totalOutputFramesRead == effective &&
            p.kotlinTrack0AcceptedChecksumHex == s.nativeAcceptedChecksumHexTrack0 &&
            p.kotlinTrack1AcceptedChecksumHex == s.nativeAcceptedChecksumHexTrack1 &&
            p.kotlinReferenceMixChecksumHex.isNotBlank() &&
            p.kotlinReferenceMixChecksumHex == s.nativeOutputReadChecksumHex
        try {
            if (s.isCreated) {
                val (joinOk, idempotentOk) = s.destroyAndVerifyLifecycle()
                destroyJoinOk = joinOk
                destroyIdempotentOk = idempotentOk
            }
        } catch (t: Throwable) {
            if (failureReason.isBlank()) fail("${REASON_PREFIX_NATIVE}destroy:${t.javaClass.simpleName}")
        } finally {
            s.cleanup()
        }
    }

    private fun foldNative(
        s: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession,
        snap: Map<String, String>,
    ): AndroidRealtimeAudioPlaybackRingTransportFrameSource.NativeTelemetry {
        fun long(key: String): Long = snap[key]?.toLongOrNull() ?: -1L
        fun bool(key: String): Boolean = snap[key] == "true"
        return AndroidRealtimeAudioPlaybackRingTransportFrameSource.NativeTelemetry(
            commandsEnqueued = s.snapCommandsEnqueued,
            commandsProcessed = s.snapCommandsProcessed,
            commandErrors = s.snapCommandErrors,
            queueDepth = s.snapQueueDepth,
            dispatchCount = s.snapDispatchCount,
            okCount = s.snapOkCount,
            silenceCount = s.snapSilenceCount,
            backpressureCount = s.snapBackpressureCount,
            schedulerErrorCount = s.snapSchedulerErrorCount,
            workerDispatchAnomalies = s.snapWorkerDispatchAnomalies,
            nonMonotonicTimeAnomalies = s.snapNonMonotonicTimeAnomalies,
            workerStarvedWaits = s.snapWorkerStarvedWaits,
            totalFramesRendered = s.snapTotalFramesRendered,
            totalFramesPushed = s.snapTotalFramesPushed,
            ownerDispatchCalls = s.snapOwnerDispatchCalls,
            workerThreadDistinct = s.snapWorkerThreadDistinct,
            noCallerSuppliedNativeTime = s.snapNoCallerSuppliedNativeTime,
            workerOwnsMonotonicClock = s.snapWorkerOwnsMonotonicClock,
            terminal = s.snapTerminal,
            timelineComplete = bool("timelineComplete"),
            eosTrack0 = bool("writerEosTrack0"),
            eosTrack1 = bool("writerEosTrack1"),
            providerFramesZeroFilledTrack0 = s.snapProviderFramesZeroFilledTrack[0],
            providerFramesZeroFilledTrack1 = s.snapProviderFramesZeroFilledTrack[1],
            providerUnderrunEventsTrack0 = s.snapProviderUnderrunEventsTrack[0],
            providerUnderrunEventsTrack1 = s.snapProviderUnderrunEventsTrack[1],
            writerSeekRequestsTrack0 = long("writerSeekRequestsTrack0"),
            writerSeekRequestsTrack1 = long("writerSeekRequestsTrack1"),
            totalFramesAcceptedTrack0 = s.totalFramesAcceptedTrack0,
            totalFramesAcceptedTrack1 = s.totalFramesAcceptedTrack1,
            outputAvailableReadFrames = long("outputAvailableReadFrames"),
            totalOutputFramesRead = long("totalOutputFramesRead"),
            paused = s.snapPaused,
            pauseCommandsProcessed = s.snapPauseCommandsProcessed,
            resumeCommandsProcessed = s.snapResumeCommandsProcessed,
            envelopeProofEnabled = s.snapEnvelopeProofEnabled,
            realtimeElapsedOk = s.snapRealtimeElapsedOk,
            nativeRealtimeElapsedMs = s.snapNativeRealtimeElapsedMs,
            realtimeBacklogBoundOk = s.snapRealtimeBacklogBoundOk,
            clockDriftSampleCount = s.snapClockDriftSampleCount,
            proofBoundaryOk = s.snapProofBoundary ==
                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession.NATIVE_PROOF_BOUNDARY,
        )
    }

    private fun requireSession(): AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession =
        session ?: throw FailClosed("real_ring_session_missing")

    private fun requirePump(): AndroidAsyncRuntimeQueueMultiSourceRealtimeClockIngestPump =
        pump ?: throw FailClosed("real_ring_pump_missing")
}
