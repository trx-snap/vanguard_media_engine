package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.IngestRequest
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.Result as TransportResult
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

// ── VanguardRealtimePlaybackDecoderFeed (P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-INTEGRATION-A, Y6a) ─
//
// Kotlin-owned MediaExtractor/MediaCodec (synchronous mode) producer that
// runs on ITS OWN decode thread and feeds exactly one external-ingest track
// of a caller-owned [VanguardRealtimePlaybackTransportStateMachine] through
// `postIngest(IngestRequest(...), expectedGeneration = ...)` only. It never
// drains, never issues a transport command (load/prepare/start/pause/
// resume/seek/stop/dispose) and never touches JNI: every PCM handoff is a
// generation-pinned post that executes on the transport's owner
// HandlerThread. The coordinator that owns the transport attaches it here
// AFTER prepare and updates the pinned generation after start.
//
// Lifecycle (decode thread only, except cancel/join/telemetry):
// 1. open media + probe the decoder output format -> publishes [Format]
//    (sampleRate / channelCount / declaredFrameCount / source metadata) and
//    releases [awaitFormat].
// 2. waits (cancel/deadline bounded) until [attachTransport] is called.
// 3. pre-rolls while the transport is PREPARED until the source ring
//    answers ring_full (or the declared end is reached) -> releases
//    [awaitPreRoll]; keeps retrying backpressure until the coordinator
//    starts the transport and raises the pinned generation.
// 4. steady state: decoded chunks are staged in a feed-owned direct buffer
//    (codec output buffers are released before any ingest), ingested in
//    slices of at most MAX_INGEST_FRAMES, partial_write / ring_full
//    remainders are compacted to offset 0 and retried in place, and a
//    stale_generation rejection (the coordinator's start raced the post)
//    is a transient retry with the re-read generation, never a failure.
// 5. EOS: a decoder ending at most 1 s short of the declared end is padded
//    with silence through the same ingest path; output past the declared
//    end is truncated (never ingested); a larger shortfall fails closed.
// 6. exit: MediaCodec stop/release and MediaExtractor release happen
//    exactly once on the decode thread on every path (eos, cancel,
//    deadline, failure), then every latch is released so a waiting
//    coordinator can never block on a dead producer.
//
// Uses the Y5b decoder policies (format support, PTS/EOS accounting,
// staging discipline) without the Y5b proof adapter, which owns its own
// state machines and drains. The Kotlin decoder checksum accumulates over
// exactly the interleaved samples native reported as accepted
// (checksum = checksum * 31 + uint16(sample)).
//
// Y9 (P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SEEK), default OFF: one optional
// coordinator-driven forward mid-stream seek, additive to the above (a feed
// without [setPreSeekHoldFrame] is byte-identical to Y6a).
// - Pre-seek hold: a window-aligned hold frame H is pinned before transport
//   start ([setPreSeekHoldFrame]); the feed ingests exactly up to H, then
//   idles (heldAtHoldFrame) until the re-anchor. The held interval refreshes
//   the progress clock and resets the no-progress counter (no mid-seek stall, C3).
// - Re-anchor ([requestSeekReanchor], after transport.seek(T) was accepted
//   while PAUSED) runs on the decode thread while held: pinned generation ->
//   post-seek generation, anchor -> T, then the Y5b seek discipline
//   (extractor SEEK_TO_PREVIOUS_SYNC, codec flush, EOS flags reset,
//   decoded-timeline origin = first post-seek PTS, ONE extractor/codec
//   reopen when the seat lands at -1). Pre-target PCM is discarded; a
//   decoded-start gap <= MAX_SEEK_GAP_SEC is silence-padded through the same
//   ingest path, a larger gap fails closed.
// - Stale probe: right after the re-anchor one postIngest pinned to the
//   PRE-seek generation must be rejected before JNI (stale_generation, reply
//   == null) or the feed fails closed.
// - Post-seek pre-roll: [awaitPostSeekPreRoll] releases once >= maxFramesPerMix
//   post-seek frames were accepted (or the declared end was reached) while
//   the transport is still PAUSED; that PAUSED wait is never a stall (C3).
// The checksum covers exactly the accepted samples, pre-seek then post-seek,
// so it matches the native and sink checksums across the seek; whole-run
// frame accounting is H + (declared - T). Seek value types live in
// VanguardRealtimePlaybackDecoderSeekTypes.kt.
class VanguardRealtimePlaybackDecoderFeed(private val config: Config) {

    data class Config(
        val sourcePath: String,
        val maxDurationSec: Double,
        val maxFramesPerMix: Int,
        // Absolute SystemClock.elapsedRealtime() deadline shared by the whole pipeline.
        val deadlineAtMs: Long,
        val threadName: String = "VanguardY6aDecoderFeed",
        // Pipeline-level cancel flag observed together with [cancel].
        val externallyCancelled: () -> Boolean = { false },
    )

    data class Format(
        val sourceMime: String,
        val sourceTrackIndex: Int,
        val sourceDurationUs: Long,
        val declaredWindowUs: Long,
        val sampleRate: Int,
        val channelCount: Int,
        val pcmEncoding: Int,
        val declaredFrameCount: Long,
    )

    companion object {
        const val TRACK_COUNT = 1
        const val EXTERNAL_TRACK_INDEX = 0
        const val EXTERNAL_INGEST_TRACK_MASK = 1

        const val EXIT_RUNNING = ""
        const val EXIT_EOS = "eos"
        const val EXIT_CANCELLED = "cancelled"
        const val EXIT_DEADLINE = "deadline_exceeded"
        const val EXIT_NOT_STARTED = "not_started"

        const val HARD_MAX_DURATION_SEC = 20.0
        // Y9: max post-seek decoded-start gap that is silence-padded, not failed (Y5b).
        const val MAX_SEEK_GAP_SEC = 0.25
        const val MAX_EOS_DRIFT_SEC = 1.0
        private const val MAX_INGEST_FRAMES = VanguardRealtimePlaybackNativeSession.MAX_INGEST_FRAMES
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val END_INPUT_MARGIN_US = 250_000L
        private const val POLL_SLEEP_MS = 2L
        private const val ATTACH_POLL_MS = 5L
        private const val OWNER_REPLY_TIMEOUT_MS = 10_000L
        private const val OWNER_REPLY_SLICE_MS = 50L
        private const val INGEST_STALL_TIMEOUT_MS = 3_000L
        private const val MAX_CONSECUTIVE_NO_PROGRESS = 5_000

        private const val STEP_STAGED = 1
        private const val STEP_TRY_AGAIN = 0
        private const val STEP_EOS = -1

        fun hex16(value: Long): String = String.format("%016x", value)
    }

    private class FailClosed(val reason: String) : Exception(reason)

    // ── Cross-thread control ───────────────────────────────────────────────

    private val started = AtomicBoolean(false)
    private val cancelled = AtomicBoolean(false)
    private val mediaReleased = AtomicBoolean(false)
    private val formatLatch = CountDownLatch(1)
    private val attachLatch = CountDownLatch(1)
    private val preRollLatch = CountDownLatch(1)
    private val exitLatch = CountDownLatch(1)
    // Y9 seek control (unused unless a hold frame is pinned).
    private val reanchorLatch = CountDownLatch(1)
    private val postSeekPreRollLatch = CountDownLatch(1)
    private val seekRequest = AtomicReference<VanguardRealtimePlaybackDecoderSeekRequest?>(null)

    @Volatile
    private var thread: Thread? = null

    @Volatile
    private var transport: VanguardRealtimePlaybackTransportStateMachine? = null

    @Volatile
    private var pinnedGeneration = 0L

    @Volatile
    private var transportStarted = false

    // Y9: exclusive upper bound of pre-seek ingest; Long.MAX_VALUE = no hold.
    @Volatile
    private var holdLimitFrame = Long.MAX_VALUE

    // ── Published telemetry (volatile: written by the decode thread) ───────

    @Volatile
    var format: Format? = null
        private set

    @Volatile
    var exitReason: String = EXIT_NOT_STARTED
        private set

    @Volatile
    var threadId: Long = -1L
        private set

    @Volatile
    var threadIsTransportOwner: Boolean = false
        private set

    @Volatile
    var preRollFrames: Long = 0L
        private set

    @Volatile
    var preRollRingFullObserved: Boolean = false
        private set

    @Volatile
    var preRollPartialWriteObserved: Boolean = false
        private set

    @Volatile
    var acceptedFrames: Long = 0L
        private set

    @Volatile
    var paddedFrames: Long = 0L
        private set

    @Volatile
    var truncatedFrames: Long = 0L
        private set

    // Pre-seek (stream-start origin) drops, Y6a semantics.
    @Volatile
    var discardedFrames: Long = 0L
        private set

    @Volatile
    var codecChunks: Long = 0L
        private set

    @Volatile
    var decodedFramesTotal: Long = 0L
        private set

    @Volatile
    var ingestCalls: Long = 0L
        private set

    @Volatile
    var ingestRingFullCount: Long = 0L
        private set

    @Volatile
    var ingestPartialWriteCount: Long = 0L
        private set

    @Volatile
    var staleGenerationRetries: Long = 0L
        private set

    @Volatile
    var transientRejects: Long = 0L
        private set

    @Volatile
    var decodeThreadWallMs: Long = 0L
        private set

    @Volatile
    var mediaReleaseClean: Boolean = false
        private set

    @Volatile
    var lastIngestStatus: String = ""
        private set

    // ── Y9 seek telemetry (decode thread writes; defaults = no seek) ───────

    // Mirror of the decode-thread anchor for any-thread readers.
    @Volatile var anchorFrame: Long = 0L
        private set
    @Volatile var heldAtHoldFrame: Boolean = false
        private set
    @Volatile var holdFrame: Long = -1L
        private set
    @Volatile var seekReanchorCount: Int = 0
        private set
    @Volatile var reanchorOk: Boolean = false
        private set
    @Volatile var reanchorExecutedOnDecodeThread: Boolean = false
        private set
    @Volatile var reanchorTransportStatePaused: Boolean = false
        private set
    @Volatile var preSeekAcceptedFrames: Long = -1L
        private set
    @Volatile var stagedFramesClearedAtSeek: Long = -1L
        private set
    @Volatile var codecChunksAtSeek: Long = -1L
        private set
    @Volatile var seekTargetFrame: Long = -1L
        private set
    @Volatile var seekTargetUs: Long = -1L
        private set
    @Volatile var seekLandedUs: Long = -1L
        private set
    @Volatile var seekReanchorWallMs: Long = -1L
        private set
    @Volatile var mediaReopens: Int = 0
        private set
    @Volatile var staleProbeCalls: Int = 0
        private set
    @Volatile var staleProbeReason: String = ""
        private set
    @Volatile var staleProbeReplyNull: Boolean = false
        private set
    @Volatile var staleProbeRejected: Boolean = false
        private set
    @Volatile var staleProbeAnchorUntouched: Boolean = false
        private set
    // Post-seek (PTS origin) accounting, Y5b semantics.
    @Volatile var firstPostSeekPtsUs: Long = -1L
        private set
    @Volatile var firstPostSeekFrame: Long = -1L
        private set
    @Volatile var postSeekAcceptedFrames: Long = 0L
        private set
    @Volatile var postSeekPreRollFrames: Long = 0L
        private set
    @Volatile var postSeekPreRollStatePaused: Boolean = false
        private set
    @Volatile var postSeekPaddedFrames: Long = 0L
        private set
    @Volatile var gapObservedFrames: Long = 0L
        private set
    @Volatile var gapPaddedFrames: Long = 0L
        private set
    @Volatile var discardedPreTargetFrames: Long = 0L
        private set

    val maxSeekGapFrames: Long get() = (MAX_SEEK_GAP_SEC * (format?.sampleRate ?: 0)).toLong()

    // Real (non-padded) post-seek decoded frames accepted by native.
    val postSeekDecodedAcceptedFrames: Long
        get() = postSeekAcceptedFrames - gapPaddedFrames - postSeekPaddedFrames

    val mediaReleaseCount = AtomicLong(0L)
    val ingestCallbacksOnOwner = AtomicLong(0L)
    val ingestCallbacksOffOwner = AtomicLong(0L)

    val isAlive: Boolean get() = thread?.isAlive == true
    val checksumHex: String get() = hex16(checksum)

    // ── Decode-thread-confined state ───────────────────────────────────────

    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private val bufferInfo = MediaCodec.BufferInfo()
    private var formatResolved = false
    private var sampleRate = 0
    private var channelCount = 0
    private var bytesPerFrame = 0
    private var pcmEncoding = 0
    private var declaredFrameCount = 0L
    private var inputEndUs = Long.MAX_VALUE
    private var inputEos = false
    private var outputEos = false
    private var decodeCursorFrame = -1L
    private var staging: ByteBuffer? = null
    private var silence: ByteBuffer? = null
    private var stagedFrames = 0
    private var stagedStartFrame = -1L
    private var anchor = 0L
    private var checksum = 0L
    private var consecutiveNoProgress = 0
    private var lastProgressMs = 0L
    private var preRollSignalled = false
    // Y9 decode-thread seek state.
    private var originIsStreamStart = true
    private var reanchored = false
    private var postSeekPreRollSignalled = false
    private var verifyOutputFormatOnNextChunk = false
    private var intermediateReleasesClean = true
    private var trackFormat: MediaFormat? = null

    // ── Public API ─────────────────────────────────────────────────────────

    // Starts the decode thread. Single use; false when already started.
    fun start(): Boolean {
        if (!started.compareAndSet(false, true)) return false
        exitReason = EXIT_RUNNING
        val t = Thread({ runOnDecodeThread() }, config.threadName)
        thread = t
        t.start()
        return true
    }

    // Blocks until the output format is published or the decode thread
    // exited (failure/cancel). Null when no format is available.
    fun awaitFormat(timeoutMs: Long): Format? {
        if (!formatLatch.await(timeoutMs, TimeUnit.MILLISECONDS)) return null
        return format
    }

    // Coordinator-only: hands over the prepared transport plus the
    // generation every ingest post is pinned to. Called once, after prepare.
    fun attachTransport(sm: VanguardRealtimePlaybackTransportStateMachine, generation: Long) {
        transport = sm
        pinnedGeneration = generation
        attachLatch.countDown()
    }

    // Coordinator-only: the transport advanced its epoch (start); later
    // posts pin the new generation. A post already in flight with the old
    // one is rejected as stale and retried here with this value.
    fun updateGeneration(generation: Long) {
        pinnedGeneration = generation
    }

    // Coordinator-only: after this the stall timeout applies (before it a
    // ring_full pre-roll may legitimately wait for the coordinator).
    fun markTransportStarted() {
        transportStarted = true
    }

    // Blocks until the pre-roll condition (ring_full observed, hold frame
    // reached or declared end reached) is signalled or the decode thread exited.
    fun awaitPreRoll(timeoutMs: Long): Boolean =
        preRollLatch.await(timeoutMs, TimeUnit.MILLISECONDS) && preRollFrames > 0L

    // Y9 coordinator-only, before transport start: ingest exactly up to `frame`
    // (window-aligned, > 0) then idle until the re-anchor. False when misaligned,
    // not positive, transport already started or a seek already happened.
    fun setPreSeekHoldFrame(frame: Long): Boolean {
        if (frame <= 0L || frame % config.maxFramesPerMix != 0L) return false
        if (transportStarted || seekRequest.get() != null || seekReanchorCount > 0) return false
        holdFrame = frame
        holdLimitFrame = frame
        return true
    }

    // Y9 coordinator-only, after transport.seek(T) was accepted while PAUSED.
    // Single use, executed by the decode thread while held at H; false when a
    // request already exists or no hold frame was pinned.
    fun requestSeekReanchor(request: VanguardRealtimePlaybackDecoderSeekRequest): Boolean {
        if (holdFrame <= 0L) return false
        return seekRequest.compareAndSet(null, request)
    }

    // Y9: blocks until the re-anchor finished (or the thread exited); true only when clean.
    fun awaitReanchor(timeoutMs: Long): Boolean =
        reanchorLatch.await(timeoutMs, TimeUnit.MILLISECONDS) && reanchorOk

    // Y9: blocks until >= maxFramesPerMix post-seek frames were accepted, the declared end was reached or the thread exited.
    fun awaitPostSeekPreRoll(timeoutMs: Long): Boolean =
        postSeekPreRollLatch.await(timeoutMs, TimeUnit.MILLISECONDS) && postSeekPreRollFrames > 0L

    // Any thread. The decode thread observes the flag at its next bounded
    // wait and tears down on its own thread.
    fun cancel() {
        cancelled.set(true)
    }

    // Bounded join; true when the decode thread has exited (or never ran).
    fun join(timeoutMs: Long): Boolean {
        val t = thread ?: return true
        if (Thread.currentThread() === t) return false
        try {
            t.join(timeoutMs)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        return !t.isAlive
    }

    // True once the decode thread finished (any exit reason).
    fun awaitExit(timeoutMs: Long): Boolean = exitLatch.await(timeoutMs, TimeUnit.MILLISECONDS)

    fun seekTelemetry(): VanguardRealtimePlaybackDecoderSeekTelemetry = VanguardRealtimePlaybackDecoderSeekTelemetry(
        holdFrame = holdFrame,
        heldAtHoldFrame = heldAtHoldFrame,
        anchorFrame = anchorFrame,
        seekReanchorCount = seekReanchorCount,
        reanchorOk = reanchorOk,
        reanchorExecutedOnDecodeThread = reanchorExecutedOnDecodeThread,
        reanchorTransportStatePaused = reanchorTransportStatePaused,
        preSeekAcceptedFrames = preSeekAcceptedFrames,
        stagedFramesClearedAtSeek = stagedFramesClearedAtSeek,
        codecChunksAtSeek = codecChunksAtSeek,
        codecChunks = codecChunks,
        seekTargetFrame = seekTargetFrame,
        seekTargetUs = seekTargetUs,
        seekLandedUs = seekLandedUs,
        seekReanchorWallMs = seekReanchorWallMs,
        mediaReopens = mediaReopens,
        staleProbeCalls = staleProbeCalls,
        staleProbeReason = staleProbeReason,
        staleProbeReplyNull = staleProbeReplyNull,
        staleProbeRejected = staleProbeRejected,
        staleProbeAnchorUntouched = staleProbeAnchorUntouched,
        firstPostSeekPtsUs = firstPostSeekPtsUs,
        firstPostSeekFrame = firstPostSeekFrame,
        postSeekAcceptedFrames = postSeekAcceptedFrames,
        postSeekDecodedAcceptedFrames = postSeekDecodedAcceptedFrames,
        postSeekPreRollFrames = postSeekPreRollFrames,
        postSeekPreRollStatePaused = postSeekPreRollStatePaused,
        postSeekPaddedFrames = postSeekPaddedFrames,
        gapObservedFrames = gapObservedFrames,
        gapPaddedFrames = gapPaddedFrames,
        maxSeekGapFrames = maxSeekGapFrames,
        discardedPreTargetFrames = discardedPreTargetFrames,
        discardedFrames = discardedFrames,
        truncatedFrames = truncatedFrames,
        acceptedFrames = acceptedFrames,
        paddedFrames = paddedFrames,
        staleGenerationRetries = staleGenerationRetries,
        transientRejects = transientRejects,
    )

    // ── Decode thread body ─────────────────────────────────────────────────

    private fun runOnDecodeThread() {
        val wallStart = SystemClock.elapsedRealtime()
        threadId = Thread.currentThread().id
        try {
            checkDeadlineAndCancel()
            validateConfig()
            openMedia()
            probeFormat()
            formatLatch.countDown()
            awaitAttach()
            feedLoop()
            truncatedFrames = stagedFrames.toLong()
            clearStaged()
            exitReason = EXIT_EOS
        } catch (f: FailClosed) {
            exitReason = f.reason
        } catch (t: Throwable) {
            exitReason = "exception:${t.javaClass.simpleName}:${t.message}"
        } finally {
            releaseMedia()
            decodeThreadWallMs = SystemClock.elapsedRealtime() - wallStart
            formatLatch.countDown()
            preRollLatch.countDown()
            reanchorLatch.countDown()
            postSeekPreRollLatch.countDown()
            exitLatch.countDown()
        }
    }

    private fun validateConfig() {
        if (config.sourcePath.isBlank()) throw FailClosed("source_path_required")
        if (config.maxDurationSec <= 0.0 || config.maxDurationSec > HARD_MAX_DURATION_SEC) {
            throw FailClosed("invalid_max_duration")
        }
        if (config.maxFramesPerMix <= 0 ||
            config.maxFramesPerMix > VanguardRealtimePlaybackNativeSession.MAX_FRAMES_PER_MIX_CAP
        ) {
            throw FailClosed("invalid_max_frames_per_mix")
        }
    }

    private fun isCancelled(): Boolean = cancelled.get() || config.externallyCancelled()

    private fun checkDeadlineAndCancel() {
        if (isCancelled()) throw FailClosed(EXIT_CANCELLED)
        if (SystemClock.elapsedRealtime() > config.deadlineAtMs) throw FailClosed(EXIT_DEADLINE)
    }

    private fun sleepPoll(ms: Long = POLL_SLEEP_MS) {
        try {
            Thread.sleep(ms)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            throw FailClosed("interrupted")
        }
    }

    private fun awaitAttach() {
        while (transport == null) {
            checkDeadlineAndCancel()
            attachLatch.await(ATTACH_POLL_MS, TimeUnit.MILLISECONDS)
        }
        val sm = transport ?: throw FailClosed("transport_missing")
        threadIsTransportOwner = sm.isOwnerThread
        if (threadIsTransportOwner) throw FailClosed("decode_thread_is_transport_owner")
        lastProgressMs = SystemClock.elapsedRealtime()
    }

    // ── Media open / format probe (Y5b policies) ───────────────────────────

    private var sourceMime = ""
    private var sourceTrackIndex = -1
    private var sourceDurationUs = 0L
    private var declaredWindowUs = 0L

    private fun openMedia() {
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
        if (trackIndex < 0 || tf == null) throw FailClosed("no_audio_track")
        ex.selectTrack(trackIndex)
        val mime = tf.getString(MediaFormat.KEY_MIME) ?: throw FailClosed("audio_track_mime_missing")
        if (!tf.containsKey(MediaFormat.KEY_DURATION)) throw FailClosed("format_duration_missing")
        val durationUs = tf.getLong(MediaFormat.KEY_DURATION)
        if (durationUs <= 0L) throw FailClosed("format_duration_invalid:$durationUs")
        sourceMime = mime
        sourceTrackIndex = trackIndex
        sourceDurationUs = durationUs
        trackFormat = tf
        declaredWindowUs = minOf(durationUs, (config.maxDurationSec * 1_000_000.0).toLong())
        inputEndUs = declaredWindowUs + END_INPUT_MARGIN_US
        startCodec(tf, mime)
    }

    private fun startCodec(tf: MediaFormat, mime: String) {
        val dec = MediaCodec.createDecoderByType(mime)
        codec = dec
        dec.configure(tf, null, null, 0)
        dec.start()
        inputEos = false
        outputEos = false
        decodeCursorFrame = -1L
    }

    // Y9, decode thread only: release the current extractor/codec pair, open a
    // fresh one on the same source/track (Y5b reopen-on-EOS landing). The
    // intermediate release folds into mediaReleaseClean, not mediaReleaseCount.
    private fun reopenMedia() {
        checkDeadlineAndCancel()
        if (mediaReleased.get()) throw FailClosed("media_reopen_after_release")
        if (mediaReopens > 0) throw FailClosed("media_reopen_repeated")
        val tf = trackFormat ?: throw FailClosed("media_reopen_format_missing")
        if (sourceTrackIndex < 0) throw FailClosed("media_reopen_source_missing")
        if (!releaseMediaObjects()) intermediateReleasesClean = false
        clearStaged()
        val ex = MediaExtractor()
        extractor = ex
        ex.setDataSource(config.sourcePath)
        if (sourceTrackIndex >= ex.trackCount) throw FailClosed("media_reopen_track_missing:$sourceTrackIndex")
        val reopenedMime = ex.getTrackFormat(sourceTrackIndex).getString(MediaFormat.KEY_MIME)
        if (reopenedMime != sourceMime) throw FailClosed("media_reopen_mime_changed:$reopenedMime")
        ex.selectTrack(sourceTrackIndex)
        startCodec(tf, sourceMime)
        verifyOutputFormatOnNextChunk = true
        mediaReopens++
    }

    // Pulls decoder output until the PCM output format is known; the first
    // staged chunk is kept for the feed loop.
    private fun probeFormat() {
        while (!formatResolved) {
            checkDeadlineAndCancel()
            if (decodeStep() == STEP_EOS && !formatResolved) throw FailClosed("no_decoder_output")
        }
        declaredFrameCount = declaredWindowUs * sampleRate / 1_000_000L
        if (declaredFrameCount <= 0L) throw FailClosed("declared_frame_count_invalid:$declaredFrameCount")
        if (declaredFrameCount < 4L * config.maxFramesPerMix) {
            throw FailClosed("declared_frame_count_too_small:$declaredFrameCount")
        }
        val declaredEndUs = (declaredFrameCount * 1_000_000L + sampleRate - 1) / sampleRate
        inputEndUs = declaredEndUs + END_INPUT_MARGIN_US
        format = Format(
            sourceMime = sourceMime,
            sourceTrackIndex = sourceTrackIndex,
            sourceDurationUs = sourceDurationUs,
            declaredWindowUs = declaredWindowUs,
            sampleRate = sampleRate,
            channelCount = channelCount,
            pcmEncoding = pcmEncoding,
            declaredFrameCount = declaredFrameCount,
        )
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
                throw FailClosed("mid_stream_format_change:$sr:$ch:$enc")
            }
            return
        }
        if (enc != AudioFormat.ENCODING_PCM_16BIT) throw FailClosed("unsupported_pcm_encoding:$enc")
        if (ch != 1 && ch != 2) throw FailClosed("unsupported_channel_count:$ch")
        if (sr < VanguardRealtimePlaybackNativeSession.MIN_SAMPLE_RATE ||
            sr > VanguardRealtimePlaybackNativeSession.MAX_SAMPLE_RATE
        ) {
            throw FailClosed("unsupported_sample_rate:$sr")
        }
        sampleRate = sr
        channelCount = ch
        pcmEncoding = enc
        bytesPerFrame = 2 * ch
        formatResolved = true
    }

    // ── Codec pump (synchronous mode, decode thread only) ──────────────────

    // Y9 floor mapping: a PREVIOUS_SYNC landing at or before the target never
    // resolves past the target, so alignment discards instead of gapping.
    private fun framesOfUs(us: Long): Long =
        if (us <= 0L) 0L else us * sampleRate / 1_000_000L

    // Feeds at most one input buffer and pulls at most one output chunk into
    // the staging buffer. The codec output buffer is released before this
    // returns, so no codec-owned memory is ever visible to the transport.
    private fun decodeStep(): Int {
        val dec = codec ?: throw FailClosed("codec_missing")
        val ex = extractor ?: throw FailClosed("extractor_missing")
        if (stagedFrames > 0) return STEP_STAGED
        if (!inputEos) {
            val inIdx = dec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
            if (inIdx >= 0) {
                val inBuf = dec.getInputBuffer(inIdx) ?: throw FailClosed("null_input_buffer")
                val size = ex.readSampleData(inBuf, 0)
                val pts = ex.sampleTime
                if (size < 0 || pts > inputEndUs) {
                    dec.queueInputBuffer(inIdx, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    inputEos = true
                } else {
                    dec.queueInputBuffer(inIdx, 0, size, pts, 0)
                    ex.advance()
                }
            }
        }
        if (outputEos) return STEP_EOS
        val outIdx = dec.dequeueOutputBuffer(bufferInfo, DEQUEUE_TIMEOUT_US)
        when {
            outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                resolveOutputFormat(dec.outputFormat)
                return STEP_TRY_AGAIN
            }
            outIdx >= 0 -> {
                val isEos = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                try {
                    if (bufferInfo.size > 0) {
                        if (!formatResolved || verifyOutputFormatOnNextChunk) {
                            // Fresh codec after a Y9 reopen must match the resolved format.
                            resolveOutputFormat(dec.outputFormat)
                            verifyOutputFormatOnNextChunk = false
                        }
                        if (bufferInfo.size % bytesPerFrame != 0) {
                            throw FailClosed("codec_chunk_shape_invalid:${bufferInfo.size}")
                        }
                        val frames = bufferInfo.size / bytesPerFrame
                        val dst = ensureStagingCapacity(bufferInfo.size)
                        val outBuf = dec.getOutputBuffer(outIdx) ?: throw FailClosed("null_output_buffer")
                        outBuf.position(bufferInfo.offset)
                        outBuf.limit(bufferInfo.offset + bufferInfo.size)
                        dst.clear()
                        dst.put(outBuf)
                        if (decodeCursorFrame < 0L) {
                            if (originIsStreamStart) {
                                // Stream-start origin: contiguous from frame 0.
                                decodeCursorFrame = 0L
                            } else {
                                // Y9: the first post-seek chunk's PTS anchors the
                                // decoded timeline (recorded, never clock-verified).
                                firstPostSeekPtsUs = bufferInfo.presentationTimeUs
                                firstPostSeekFrame = framesOfUs(bufferInfo.presentationTimeUs)
                                decodeCursorFrame = firstPostSeekFrame
                            }
                        }
                        stagedStartFrame = decodeCursorFrame
                        stagedFrames = frames
                        decodeCursorFrame += frames
                        codecChunks++
                        decodedFramesTotal += frames
                    }
                } finally {
                    dec.releaseOutputBuffer(outIdx, false)
                }
                if (isEos) outputEos = true
                return when {
                    stagedFrames > 0 -> STEP_STAGED
                    outputEos -> STEP_EOS
                    else -> STEP_TRY_AGAIN
                }
            }
            else -> return STEP_TRY_AGAIN // INFO_TRY_AGAIN_LATER; the deadline bounds the wait.
        }
    }

    private fun ensureStagingCapacity(bytes: Int): ByteBuffer {
        val minBytes = maxOf(bytes, MAX_INGEST_FRAMES * bytesPerFrame)
        val current = staging
        if (current != null && current.capacity() >= minBytes) return current
        val fresh = ByteBuffer.allocateDirect(minBytes).order(ByteOrder.nativeOrder())
        staging = fresh
        return fresh
    }

    private fun silenceBuffer(): ByteBuffer {
        val current = silence
        if (current != null) return current
        val fresh = ByteBuffer.allocateDirect(MAX_INGEST_FRAMES * bytesPerFrame).order(ByteOrder.nativeOrder())
        silence = fresh // allocateDirect zero-fills
        return fresh
    }

    // Drops `frames` from the head of the staging buffer, compacting the
    // remainder back to byte offset 0.
    private fun consumeStaged(frames: Int) {
        if (frames <= 0) return
        val s = staging ?: return
        if (frames >= stagedFrames) {
            stagedFrames = 0
            stagedStartFrame = -1L
            return
        }
        s.position(frames * bytesPerFrame)
        s.limit(stagedFrames * bytesPerFrame)
        s.compact()
        stagedFrames -= frames
        stagedStartFrame += frames
    }

    private fun clearStaged() {
        stagedFrames = 0
        stagedStartFrame = -1L
    }

    // ── Y9 decoder seek (Y5b discipline, decode thread only) ───────────────

    // Re-seats the extractor at `targetUs` (PREVIOUS_SYNC); landed sample time or -1.
    private fun seatExtractor(targetUs: Long): Long {
        val ex = extractor ?: throw FailClosed("extractor_missing")
        ex.seekTo(targetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        return ex.sampleTime
    }

    // Clears staging, re-seats the extractor, flushes the codec, resets the EOS
    // flags; the first post-seek PTS anchors the timeline. A -1 landing is
    // retried once on a reopened pair; a second -1 fails closed.
    private fun reseekDecoder(targetUs: Long): Long {
        if (codec == null) throw FailClosed("codec_missing")
        clearStaged()
        var landedUs = seatExtractor(targetUs)
        if (landedUs >= 0L) {
            (codec ?: throw FailClosed("codec_missing")).flush()
        } else {
            reopenMedia()
            landedUs = seatExtractor(targetUs)
            if (landedUs < 0L) throw FailClosed("seek_landed_eos_after_reopen:$targetUs")
        }
        inputEos = false
        outputEos = false
        originIsStreamStart = false
        decodeCursorFrame = -1L
        firstPostSeekPtsUs = -1L
        firstPostSeekFrame = -1L
        return landedUs
    }

    // Executes the seek request while held at H: anchor and pinned generation
    // move to the post-seek values, the decoder re-seeks, then one deliberately
    // stale post is proven rejected before JNI. Never touches JNI itself.
    private fun performReanchor(req: VanguardRealtimePlaybackDecoderSeekRequest, sm: VanguardRealtimePlaybackTransportStateMachine) {
        val startMs = SystemClock.elapsedRealtime()
        reanchorExecutedOnDecodeThread = Thread.currentThread().id == threadId
        reanchorTransportStatePaused = sm.currentState == State.PAUSED
        if (!reanchorTransportStatePaused) throw FailClosed("reanchor_transport_not_paused:${sm.currentState.name.lowercase()}")
        if (anchor != req.preSeekAnchorFrame) throw FailClosed("reanchor_anchor_mismatch:$anchor:${req.preSeekAnchorFrame}")
        if (req.targetFrame <= anchor || req.targetFrame >= declaredFrameCount) {
            throw FailClosed("reanchor_target_invalid:${req.targetFrame}:$anchor:$declaredFrameCount")
        }
        if (req.newGeneration == req.staleGeneration) throw FailClosed("reanchor_generation_not_advanced")

        preSeekAcceptedFrames = acceptedFrames
        stagedFramesClearedAtSeek = stagedFrames.toLong()
        codecChunksAtSeek = codecChunks
        clearStaged()
        holdLimitFrame = Long.MAX_VALUE
        heldAtHoldFrame = false
        seekTargetFrame = req.targetFrame
        seekTargetUs = (req.targetFrame * 1_000_000L + sampleRate - 1) / sampleRate
        seekLandedUs = reseekDecoder(seekTargetUs)

        anchor = req.targetFrame
        anchorFrame = anchor
        pinnedGeneration = req.newGeneration
        lastIngestStatus = ""
        consecutiveNoProgress = 0
        lastProgressMs = SystemClock.elapsedRealtime()
        reanchored = true

        // Stale probe pinned to the PRE-seek generation: the owner thread must
        // reject it before any native call (reply == null), anchor untouched.
        val stale = pinnedIngest(sm, silenceBuffer(), config.maxFramesPerMix, req.staleGeneration)
        staleProbeCalls++
        staleProbeReason = stale.reason
        staleProbeReplyNull = stale.reply == null
        staleProbeRejected = !stale.accepted &&
            stale.reason == VanguardRealtimePlaybackTransportStateMachine.REASON_STALE_GENERATION &&
            stale.reply == null
        staleProbeAnchorUntouched = anchor == req.targetFrame
        if (!staleProbeRejected) throw FailClosed("stale_probe_not_rejected:${stale.reason}")

        seekReanchorCount++
        seekReanchorWallMs = SystemClock.elapsedRealtime() - startMs
        reanchorOk = true
        reanchorLatch.countDown()
    }

    // ── Transport handoff (owner-thread post only) ─────────────────────────

    // Generation-pinned postIngest; waits (bounded, cancel-aware) for the
    // owner-thread callback. The decode thread never reaches JNI.
    private fun pinnedIngest(sm: VanguardRealtimePlaybackTransportStateMachine, src: ByteBuffer, frames: Int, generation: Long): TransportResult {
        val latch = CountDownLatch(1)
        val holder = arrayOfNulls<TransportResult>(1)
        sm.postIngest(
            IngestRequest(EXTERNAL_TRACK_INDEX, src, frames, anchor),
            expectedGeneration = generation,
        ) { r ->
            if (sm.isOwnerThread) ingestCallbacksOnOwner.incrementAndGet() else ingestCallbacksOffOwner.incrementAndGet()
            holder[0] = r
            latch.countDown()
        }
        val waitUntil = SystemClock.elapsedRealtime() + OWNER_REPLY_TIMEOUT_MS
        while (!latch.await(OWNER_REPLY_SLICE_MS, TimeUnit.MILLISECONDS)) {
            // A cancel must still be able to exit even if the owner is wedged.
            if (isCancelled()) throw FailClosed(EXIT_CANCELLED)
            if (SystemClock.elapsedRealtime() > waitUntil) throw FailClosed("owner_reply_timeout")
        }
        return holder[0] ?: throw FailClosed("owner_reply_missing")
    }

    // One ingest attempt of `frames` frames at byte offset 0 of `src`.
    // Advances the anchor/checksum only from native acceptedFrames.
    // Returns the native status or a transient rejection reason; terminal
    // rejections fail closed.
    private fun ingestOnce(src: ByteBuffer, frames: Int): String {
        checkDeadlineAndCancel()
        val sm = transport ?: throw FailClosed("transport_missing")
        val generation = pinnedGeneration
        val res = pinnedIngest(sm, src, frames, generation)
        ingestCalls++
        if (!res.accepted) {
            return when (res.reason) {
                VanguardRealtimePlaybackTransportStateMachine.REASON_STALE_GENERATION -> {
                    // The coordinator's start advanced the epoch between our
                    // read of pinnedGeneration and the owner-thread execution;
                    // the post never reached JNI. Retry with the fresh value.
                    staleGenerationRetries++
                    lastIngestStatus = res.reason
                    res.reason
                }
                "${VanguardRealtimePlaybackTransportStateMachine.REASON_INGEST_PREFIX}${VanguardRealtimePlaybackNativeSession.STATUS_COMMAND_IN_FLIGHT}",
                "${VanguardRealtimePlaybackTransportStateMachine.REASON_INGEST_PREFIX}${VanguardRealtimePlaybackNativeSession.STATUS_AWAITING_SEEK_ACK}",
                -> {
                    transientRejects++
                    lastIngestStatus = res.reason
                    res.reason
                }
                else -> throw FailClosed("ingest_rejected:${res.reason}")
            }
        }
        val reply = res.reply ?: throw FailClosed("ingest_null_reply")
        lastIngestStatus = reply.status
        val n = reply.acceptedFrames
        if (n < 0L || n > frames) throw FailClosed("accepted_out_of_range:$n")
        if (n > 0L) {
            if (reply.nextWriteFrame != anchor + n) {
                throw FailClosed("anchor_divergence:${reply.nextWriteFrame}:${anchor + n}")
            }
            val samples = (n * channelCount).toInt()
            var c = checksum
            for (i in 0 until samples) c = c * 31L + (src.getShort(i * 2).toLong() and 0xFFFFL)
            checksum = c
            anchor += n
            anchorFrame = anchor
            acceptedFrames += n
            if (reanchored) postSeekAcceptedFrames += n
            lastProgressMs = SystemClock.elapsedRealtime()
            consecutiveNoProgress = 0
        }
        when (reply.status) {
            VanguardRealtimePlaybackNativeSession.STATUS_PARTIAL_WRITE -> {
                ingestPartialWriteCount++
                if (!transportStarted) preRollPartialWriteObserved = true
            }
            VanguardRealtimePlaybackNativeSession.STATUS_RING_FULL -> {
                ingestRingFullCount++
                if (!transportStarted) preRollRingFullObserved = true
            }
        }
        return reply.status
    }

    // Aligns the staged chunk with the anchor. Stream-start origin: a gap fails
    // closed, an early start is dropped. Y9 PTS origin: a gap <= MAX_SEEK_GAP_SEC
    // stays staged for [feedStep] to pad, a larger one fails closed; pre-target
    // PCM is discarded.
    private fun alignStagedToAnchor() {
        if (stagedFrames <= 0) return
        val start = stagedStartFrame
        if (start < 0L) throw FailClosed("staged_timeline_unknown")
        if (start > anchor) {
            val gap = start - anchor
            if (originIsStreamStart) throw FailClosed("decoded_timeline_gap:$start:$anchor")
            val maxGap = (MAX_SEEK_GAP_SEC * sampleRate).toLong()
            if (gap > maxGap) throw FailClosed("decoded_timeline_gap_exceeded:$start:$anchor:$maxGap")
            gapObservedFrames += gap
            return
        }
        if (start < anchor) {
            val drop = minOf(anchor - start, stagedFrames.toLong()).toInt()
            if (originIsStreamStart) discardedFrames += drop else discardedPreTargetFrames += drop
            consumeStaged(drop)
        }
    }

    // One feed attempt toward `limitFrame` (declared end, or the pinned Y9 hold
    // frame): stage decoder output, pad a bounded post-seek decoded-start gap,
    // ingest at most one slice, or pad EOS silence. True when native accepted.
    private fun feedStep(limitFrame: Long): Boolean {
        if (anchor >= limitFrame) return false
        while (stagedFrames == 0 && !outputEos) {
            checkDeadlineAndCancel()
            if (decodeStep() == STEP_STAGED) alignStagedToAnchor() else break
        }
        val before = acceptedFrames
        val room = limitFrame - anchor
        if (stagedFrames > 0 && stagedStartFrame > anchor) {
            // Y9 bounded decoded-start gap (validated by alignStagedToAnchor):
            // silence-fill anchor..stagedStartFrame through the same ingest path.
            val gap = stagedStartFrame - anchor
            val frames = minOf(gap, MAX_INGEST_FRAMES.toLong(), room).toInt()
            ingestOnce(silenceBuffer(), frames)
            gapPaddedFrames += acceptedFrames - before
        } else if (stagedFrames > 0) {
            val frames = minOf(stagedFrames.toLong(), MAX_INGEST_FRAMES.toLong(), room).toInt()
            val s = staging ?: throw FailClosed("staging_missing")
            ingestOnce(s, frames)
            val accepted = (acceptedFrames - before).toInt()
            if (accepted > 0) consumeStaged(accepted)
        } else if (outputEos) {
            // EOS padding applies toward the declared end only, never toward H.
            if (limitFrame < declaredFrameCount) throw FailClosed("decoder_eos_before_hold:$anchor:$limitFrame")
            val shortfall = room
            if (shortfall > (MAX_EOS_DRIFT_SEC * sampleRate).toLong()) {
                throw FailClosed("eos_drift_exceeded:$shortfall")
            }
            val frames = minOf(shortfall, MAX_INGEST_FRAMES.toLong()).toInt()
            ingestOnce(silenceBuffer(), frames)
            val padded = acceptedFrames - before
            paddedFrames += padded
            if (reanchored) postSeekPaddedFrames += padded
        }
        return acceptedFrames > before
    }

    private fun currentLimit(): Long = minOf(declaredFrameCount, holdLimitFrame)

    private fun signalPreRollIfDue() {
        if (preRollSignalled) return
        if (preRollRingFullObserved || anchor >= currentLimit()) {
            preRollSignalled = true
            preRollFrames = anchor
            preRollLatch.countDown()
        }
    }

    private fun signalPostSeekPreRollIfDue() {
        if (postSeekPreRollSignalled || !reanchored) return
        if (postSeekAcceptedFrames >= config.maxFramesPerMix || anchor >= declaredFrameCount) {
            postSeekPreRollSignalled = true
            postSeekPreRollFrames = postSeekAcceptedFrames
            postSeekPreRollStatePaused = transport?.currentState == State.PAUSED
            postSeekPreRollLatch.countDown()
        }
    }

    // Feeds until the anchor reaches the declared end, holding at the pinned
    // Y9 hold frame until the re-anchor. Backpressure, transient command gates
    // and a stale generation retry in place, bounded by the deadline, cancel,
    // a no-progress cap and (transport started) a stall timeout. The held
    // interval and a PAUSED transport after the re-anchor refresh the progress
    // clock and reset the no-progress counter (C3); without a seek = Y6a loop.
    private fun feedLoop() {
        while (true) {
            checkDeadlineAndCancel()
            val sm = transport ?: throw FailClosed("transport_missing")
            val state = sm.currentState
            if (state == State.FAILED || state == State.DISPOSED) {
                throw FailClosed("transport_${state.name.lowercase()}")
            }
            val limit = currentLimit()
            if (anchor > limit) throw FailClosed("hold_limit_overrun:$anchor:$limit")
            if (anchor >= declaredFrameCount) break
            if (anchor == limit) {
                // Held at H: no ingest until the re-anchor; never a stall.
                signalPreRollIfDue()
                val req = seekRequest.get()
                if (req != null && !reanchored) {
                    performReanchor(req, sm)
                    continue
                }
                heldAtHoldFrame = true
                lastProgressMs = SystemClock.elapsedRealtime()
                consecutiveNoProgress = 0
                sleepPoll()
                continue
            }
            heldAtHoldFrame = false
            val progressed = feedStep(limit)
            signalPreRollIfDue()
            signalPostSeekPreRollIfDue()
            if (!progressed) {
                val pausedAfterSeek = reanchored && sm.currentState == State.PAUSED
                if (stagedFrames > 0 || outputEos) {
                    if (pausedAfterSeek) {
                        consecutiveNoProgress = 0
                    } else {
                        consecutiveNoProgress++
                    }
                    if (consecutiveNoProgress > MAX_CONSECUTIVE_NO_PROGRESS) {
                        throw FailClosed("retry_budget_exhausted:$lastIngestStatus")
                    }
                    if (transportStarted && !pausedAfterSeek &&
                        SystemClock.elapsedRealtime() - lastProgressMs > INGEST_STALL_TIMEOUT_MS
                    ) {
                        throw FailClosed("ingest_stall:$lastIngestStatus:${sm.currentState.name.lowercase()}")
                    }
                    // Pre-roll ring_full and PAUSED-after-seek legitimately wait.
                    if (!transportStarted || pausedAfterSeek) lastProgressMs = SystemClock.elapsedRealtime()
                    sleepPoll()
                } else if (transportStarted && SystemClock.elapsedRealtime() - lastProgressMs > INGEST_STALL_TIMEOUT_MS) {
                    throw FailClosed("decoder_output_stall")
                }
            }
        }
        signalPreRollIfDue()
        signalPostSeekPreRollIfDue()
    }

    // ── Teardown (decode thread; exactly once) ─────────────────────────────

    // Releases whatever codec/extractor pair currently exists; true when
    // every release call succeeded.
    private fun releaseMediaObjects(): Boolean {
        var clean = true
        val dec = codec
        val ex = extractor
        codec = null
        extractor = null
        if (dec != null) {
            try {
                dec.stop()
            } catch (_: Throwable) {
                clean = false
            }
            try {
                dec.release()
            } catch (_: Throwable) {
                clean = false
            }
        }
        if (ex != null) {
            try {
                ex.release()
            } catch (_: Throwable) {
                clean = false
            }
        }
        return clean
    }

    private fun releaseMedia() {
        if (!mediaReleased.compareAndSet(false, true)) return
        val clean = releaseMediaObjects()
        clearStaged()
        mediaReleaseCount.incrementAndGet()
        mediaReleaseClean = clean && intermediateReleasesClean
    }
}
