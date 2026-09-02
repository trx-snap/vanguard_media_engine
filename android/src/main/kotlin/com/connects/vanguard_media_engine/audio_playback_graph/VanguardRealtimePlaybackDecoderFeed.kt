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
        private const val MAX_INGEST_FRAMES = VanguardRealtimePlaybackNativeSession.MAX_INGEST_FRAMES
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val MAX_EOS_DRIFT_SEC = 1.0
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

    @Volatile
    private var thread: Thread? = null

    @Volatile
    private var transport: VanguardRealtimePlaybackTransportStateMachine? = null

    @Volatile
    private var pinnedGeneration = 0L

    @Volatile
    private var transportStarted = false

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

    // Blocks until the pre-roll condition (ring_full observed or declared
    // end reached) is signalled or the decode thread exited.
    fun awaitPreRoll(timeoutMs: Long): Boolean =
        preRollLatch.await(timeoutMs, TimeUnit.MILLISECONDS) && preRollFrames > 0L

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
        var trackFormat: MediaFormat? = null
        for (i in 0 until ex.trackCount) {
            val f = ex.getTrackFormat(i)
            if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                trackIndex = i
                trackFormat = f
                break
            }
        }
        if (trackIndex < 0 || trackFormat == null) throw FailClosed("no_audio_track")
        ex.selectTrack(trackIndex)
        val mime = trackFormat.getString(MediaFormat.KEY_MIME) ?: throw FailClosed("audio_track_mime_missing")
        if (!trackFormat.containsKey(MediaFormat.KEY_DURATION)) throw FailClosed("format_duration_missing")
        val durationUs = trackFormat.getLong(MediaFormat.KEY_DURATION)
        if (durationUs <= 0L) throw FailClosed("format_duration_invalid:$durationUs")
        sourceMime = mime
        sourceTrackIndex = trackIndex
        sourceDurationUs = durationUs
        declaredWindowUs = minOf(durationUs, (config.maxDurationSec * 1_000_000.0).toLong())
        inputEndUs = declaredWindowUs + END_INPUT_MARGIN_US

        val dec = MediaCodec.createDecoderByType(mime)
        codec = dec
        dec.configure(trackFormat, null, null, 0)
        dec.start()
        inputEos = false
        outputEos = false
        decodeCursorFrame = -1L
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
                        if (!formatResolved) resolveOutputFormat(dec.outputFormat)
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
                        // Forward playthrough from the stream start: the decoded
                        // timeline is contiguous from frame 0 by construction.
                        if (decodeCursorFrame < 0L) decodeCursorFrame = 0L
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
            acceptedFrames += n
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

    // Aligns the staged chunk with the anchor. From a stream-start origin
    // decoded frames are contiguous, so a chunk starting after the anchor
    // is a timeline gap (fails closed); one starting before it is dropped.
    private fun alignStagedToAnchor() {
        if (stagedFrames <= 0) return
        val start = stagedStartFrame
        if (start < 0L) throw FailClosed("staged_timeline_unknown")
        if (start > anchor) throw FailClosed("decoded_timeline_gap:$start:$anchor")
        if (start < anchor) {
            val drop = minOf(anchor - start, stagedFrames.toLong()).toInt()
            discardedFrames += drop
            consumeStaged(drop)
        }
    }

    // One feed attempt toward the declared end: stage decoder output, ingest
    // at most one bounded slice, or pad silence once the decoder is
    // exhausted. Returns true when native accepted frames.
    private fun feedStep(): Boolean {
        if (anchor >= declaredFrameCount) return false
        while (stagedFrames == 0 && !outputEos) {
            checkDeadlineAndCancel()
            if (decodeStep() == STEP_STAGED) alignStagedToAnchor() else break
        }
        val before = acceptedFrames
        val room = declaredFrameCount - anchor
        if (stagedFrames > 0) {
            val frames = minOf(stagedFrames.toLong(), MAX_INGEST_FRAMES.toLong(), room).toInt()
            val s = staging ?: throw FailClosed("staging_missing")
            ingestOnce(s, frames)
            val accepted = (acceptedFrames - before).toInt()
            if (accepted > 0) consumeStaged(accepted)
        } else if (outputEos) {
            val shortfall = room
            if (shortfall > (MAX_EOS_DRIFT_SEC * sampleRate).toLong()) {
                throw FailClosed("eos_drift_exceeded:$shortfall")
            }
            val frames = minOf(shortfall, MAX_INGEST_FRAMES.toLong()).toInt()
            ingestOnce(silenceBuffer(), frames)
            paddedFrames += acceptedFrames - before
        }
        return acceptedFrames > before
    }

    private fun signalPreRollIfDue() {
        if (preRollSignalled) return
        if (preRollRingFullObserved || anchor >= declaredFrameCount) {
            preRollSignalled = true
            preRollFrames = anchor
            preRollLatch.countDown()
        }
    }

    // Feeds until the anchor reaches the declared end. Backpressure
    // (ring_full / partial_write remainder), transient command gates and a
    // stale generation are retried in place; bounded by the deadline, the
    // cancel flag, a consecutive no-progress cap and (once the transport is
    // started) a progress stall timeout.
    private fun feedLoop() {
        while (anchor < declaredFrameCount) {
            checkDeadlineAndCancel()
            val progressed = feedStep()
            signalPreRollIfDue()
            val sm = transport ?: throw FailClosed("transport_missing")
            val state = sm.currentState
            if (state == State.FAILED || state == State.DISPOSED) {
                throw FailClosed("transport_${state.name.lowercase()}")
            }
            if (!progressed) {
                if (stagedFrames > 0 || outputEos) {
                    consecutiveNoProgress++
                    if (consecutiveNoProgress > MAX_CONSECUTIVE_NO_PROGRESS) {
                        throw FailClosed("retry_budget_exhausted:$lastIngestStatus")
                    }
                    if (transportStarted && SystemClock.elapsedRealtime() - lastProgressMs > INGEST_STALL_TIMEOUT_MS) {
                        throw FailClosed("ingest_stall:$lastIngestStatus:${state.name.lowercase()}")
                    }
                    if (!transportStarted) lastProgressMs = SystemClock.elapsedRealtime()
                    sleepPoll()
                } else if (transportStarted && SystemClock.elapsedRealtime() - lastProgressMs > INGEST_STALL_TIMEOUT_MS) {
                    throw FailClosed("decoder_output_stall")
                }
            }
        }
        signalPreRollIfDue()
    }

    // ── Teardown (decode thread; exactly once) ─────────────────────────────

    private fun releaseMedia() {
        if (!mediaReleased.compareAndSet(false, true)) return
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
        clearStaged()
        mediaReleaseCount.incrementAndGet()
        mediaReleaseClean = clean
    }
}
