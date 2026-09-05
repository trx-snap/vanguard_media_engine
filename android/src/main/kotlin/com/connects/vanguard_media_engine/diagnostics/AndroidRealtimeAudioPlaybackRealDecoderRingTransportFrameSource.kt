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
// Honest non-claims: diagnostic real-decoder ring frame-source proof only.
// No feedback control loop, no pacing correction, no resampling, no
// currentPosition authority switch, no A/V sync closure, no seek, no
// pause/resume, no product/editor/app/ConnectsApp/iOS/streaming/cache, no
// fleet claim, no change to the sink, the seam, the production feed, the
// session, the native session wrapper, or any X4..X15 entry point.
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
        TRANSPORT_START, ACTIVE_DRAIN, DECODER_EOS, EOS_SET, CLOSING, CLOSED, FAILED,
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

    // Adapter-side facts (owner thread + sink thread counters). The folded
    // final native snapshot reuses the Y18b [AndroidRealtimeAudioPlaybackRingTransportFrameSource.NativeTelemetry]
    // shape so the evaluator reads one native fact type for both ring routes.
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

    private enum class Feed { PROGRESSED, RETRY, STALLED, IDLE }

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
    private var acceptingRequests = true
    @Volatile private var ownerThread: Thread? = null
    @Volatile private var ownerThreadId = -1L
    @Volatile private var stage = Stage.CREATED
    @Volatile private var stageTrace = "created"
    @Volatile private var failureReason = ""
    @Volatile private var started = false

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
        )
    }

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
                Feed.STALLED, Feed.IDLE -> break
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
        if (pendingSliceFrames == 0 && p.hasPendingChunk) {
            if (!allowDrain) return Feed.STALLED
            p.completePendingLockstep()
            if (p.framesCommitted >= expectedFrames) markIngestComplete()
            return Feed.PROGRESSED
        }
        if (pendingSliceFrames > 0) {
            val room = expectedFrames - p.framesCommitted
            if (room <= 0L) {
                noteTruncated(pendingSliceFrames)
                pendingSliceFrames = 0
                markIngestComplete()
                return Feed.PROGRESSED
            }
            val take = minOf(pendingSliceFrames.toLong(), room).toInt()
            val surplus = pendingSliceFrames - take
            if (surplus > 0) noteTruncated(surplus)
            val remaining = p.ingestDecodedSlice(slice, take, allowDrain)
            val ingested = (take - remaining).toLong()
            if (!sliceIsPad) framesIngestedReal += ingested
            pendingSliceFrames = remaining
            if (remaining > 0) return Feed.STALLED
            if (p.framesCommitted >= expectedFrames && !p.hasPendingChunk) markIngestComplete()
            return Feed.PROGRESSED
        }
        if (ingestComplete) {
            if (outputEos) return Feed.IDLE
            // Decoder run-out to EOS: every further chunk is truncated above.
            return if (decodeStep()) Feed.PROGRESSED else Feed.RETRY
        }
        if (outputEos) {
            val shortfall = expectedFrames - p.framesCommitted
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
                        val outBuf = dec.getOutputBuffer(outIdx)
                        if (outBuf == null) {
                            dec.releaseOutputBuffer(outIdx, false)
                            throw FailClosed(REASON_PREFIX_DECODER + "null_output_buffer")
                        }
                        ensureSliceCapacity(size)
                        outBuf.position(bufferInfo.offset)
                        outBuf.limit(bufferInfo.offset + size)
                        slice.clear()
                        slice.put(outBuf)
                        dec.releaseOutputBuffer(outIdx, false)
                        val frames = size / bytesPerFrame
                        pendingSliceFrames = frames
                        sliceIsPad = false
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

    // Services Start / drain requests with priority, runs one bounded feed
    // step (draining before and after it), then polls (snapshot-only, no
    // ring read) for timeline completion to set the joint EOS once; idles on
    // the request condition otherwise.
    private fun ownerLoop() {
        val s = requireSession()
        while (!stopRequested.get()) {
            ownerLoopIterations += 1L
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
            if (started) {
                if (!ingestComplete || !outputEos) {
                    when (feedStep(allowDrain = true)) {
                        Feed.PROGRESSED, Feed.RETRY -> progressed = true
                        Feed.STALLED -> throw FailClosed(REASON_PREFIX_LOCKSTEP + "stall_with_drain_allowed")
                        Feed.IDLE -> {}
                    }
                } else if (!s.eosSetWithoutDrain) {
                    val now = SystemClock.elapsedRealtime()
                    if (now >= nextEosPollAtMs) {
                        eosPollSnapshots += 1L
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
                    if (pendingDrain == null && !stopRequested.get() && !(startRequested.get() && !started)) {
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
        val p = pump
        finalChecksumChainSelfOk = p != null && !p.hasPendingChunk &&
            p.kotlinFramesAccepted == expectedFrames &&
            s.totalFramesAcceptedTrack0 == expectedFrames && s.totalFramesAcceptedTrack1 == expectedFrames &&
            s.totalOutputFramesRead == expectedFrames &&
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
