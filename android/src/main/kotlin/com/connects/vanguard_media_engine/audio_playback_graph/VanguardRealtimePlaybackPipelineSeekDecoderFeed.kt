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

// ── VanguardRealtimePlaybackPipelineSeekDecoderFeed (P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SEEK, Y6c) ─
//
// Seek-capable variant of the Y6a [VanguardRealtimePlaybackDecoderFeed].
// Same ownership: a Kotlin-owned MediaExtractor/MediaCodec (synchronous
// mode) producer on ITS OWN decode thread feeding exactly one external-
// ingest track of a caller-owned [VanguardRealtimePlaybackTransportStateMachine]
// through `postIngest(IngestRequest(...), expectedGeneration = ...)` only.
// It never drains, never issues a transport command and never touches JNI.
//
// Y6c additions over Y6a (everything else keeps the Y6a policies):
// - Pre-seek hold: the coordinator pins a window-aligned hold frame
//   ([setPreSeekHoldFrame], before start). The feed ingests exactly up to
//   that frame and then idles (no ingest, no stall accounting) so the
//   native worker renders every ingested frame and the pipeline quiesces
//   at pushed == drained == anchor with the source ring provably empty.
// - Seek re-anchor ([requestSeekReanchor], coordinator-only, after
//   transport.seek was accepted while PAUSED): executed on the decode
//   thread while held. Staging is cleared, the pinned generation moves to
//   the post-seek generation, the anchor moves to the target, then the Y5b
//   decoder seek discipline runs: extractor SEEK_TO_PREVIOUS_SYNC, codec
//   flush, EOS flag reset, decoded-timeline origin reset to the first
//   post-seek PTS, and a re-seat landing at -1 reopens the extractor/codec
//   pair once. PCM before the target is discarded; a bounded decoded-start
//   gap after the target is silence-padded through the same ingest path.
// - Deliberate stale probe: right after the re-anchor one postIngest pinned
//   to the PRE-seek generation is posted; it must be rejected before JNI
//   (reason stale_generation, reply == null) or the feed fails closed.
// - Post-seek pre-roll: [awaitPostSeekPreRoll] releases once at least
//   maxFramesPerMix post-seek frames were accepted (or the declared end was
//   reached) while the transport is still PAUSED.
//
// The Kotlin decoder checksum accumulates over exactly the interleaved
// samples native reported as accepted, pre-seek frames first then post-
// seek frames, so it matches the native pushed/drained checksums and the
// sink checksum across the seek. No AudioTrack, no transport command, no
// presentation clock, no A/V sync lives here.
class VanguardRealtimePlaybackPipelineSeekDecoderFeed(private val config: Config) {

    data class Config(
        val sourcePath: String,
        val maxDurationSec: Double,
        val maxFramesPerMix: Int,
        // Absolute SystemClock.elapsedRealtime() deadline shared by the whole pipeline.
        val deadlineAtMs: Long,
        val threadName: String = "VanguardY6cSeekDecoderFeed",
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

    // Coordinator-issued seek re-anchor request (single use).
    data class SeekRequest(
        val targetFrame: Long,
        val preSeekAnchorFrame: Long,
        val newGeneration: Long,
        val staleGeneration: Long,
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
        // Upper bound on the post-seek decoded-start gap that is silence-
        // padded instead of failing closed (Y5b policy).
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
    private val reanchorLatch = CountDownLatch(1)
    private val postSeekPreRollLatch = CountDownLatch(1)
    private val exitLatch = CountDownLatch(1)
    private val seekRequest = AtomicReference<SeekRequest?>(null)

    @Volatile
    private var thread: Thread? = null

    @Volatile
    private var transport: VanguardRealtimePlaybackTransportStateMachine? = null

    @Volatile
    private var pinnedGeneration = 0L

    @Volatile
    private var transportStarted = false

    // Frame the pre-seek feed stops at (exclusive upper bound of ingest);
    // Long.MAX_VALUE means "declared end".
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

    // Mirror of the decode-thread anchor (native writer cursor).
    @Volatile
    var anchorFrame: Long = 0L
        private set

    @Volatile
    var heldAtHoldFrame: Boolean = false
        private set

    @Volatile
    var holdFrame: Long = -1L
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

    // Seek telemetry.

    @Volatile
    var seekReanchorCount: Int = 0
        private set

    @Volatile
    var reanchorOk: Boolean = false
        private set

    @Volatile
    var reanchorExecutedOnDecodeThread: Boolean = false
        private set

    @Volatile
    var reanchorTransportStatePaused: Boolean = false
        private set

    @Volatile
    var preSeekAcceptedFrames: Long = -1L
        private set

    @Volatile
    var stagedFramesClearedAtSeek: Long = -1L
        private set

    @Volatile
    var codecChunksAtSeek: Long = -1L
        private set

    @Volatile
    var seekTargetFrame: Long = -1L
        private set

    @Volatile
    var seekTargetUs: Long = -1L
        private set

    @Volatile
    var seekLandedUs: Long = -1L
        private set

    @Volatile
    var seekReanchorWallMs: Long = -1L
        private set

    @Volatile
    var mediaReopens: Int = 0
        private set

    @Volatile
    var staleProbeCalls: Int = 0
        private set

    @Volatile
    var staleProbeReason: String = ""
        private set

    @Volatile
    var staleProbeReplyNull: Boolean = false
        private set

    @Volatile
    var staleProbeRejected: Boolean = false
        private set

    @Volatile
    var staleProbeAnchorUntouched: Boolean = false
        private set

    // Post-seek (PTS origin) accounting, Y5b semantics.
    @Volatile
    var discardedPreTargetFrames: Long = 0L
        private set

    @Volatile
    var gapObservedFrames: Long = 0L
        private set

    @Volatile
    var gapPaddedFrames: Long = 0L
        private set

    @Volatile
    var firstPostSeekPtsUs: Long = -1L
        private set

    @Volatile
    var firstPostSeekFrame: Long = -1L
        private set

    @Volatile
    var postSeekAcceptedFrames: Long = 0L
        private set

    @Volatile
    var postSeekPreRollFrames: Long = 0L
        private set

    @Volatile
    var postSeekPreRollStatePaused: Boolean = false
        private set

    @Volatile
    var postSeekPaddedFrames: Long = 0L
        private set

    val mediaReleaseCount = AtomicLong(0L)
    val ingestCallbacksOnOwner = AtomicLong(0L)
    val ingestCallbacksOffOwner = AtomicLong(0L)

    val isAlive: Boolean get() = thread?.isAlive == true
    val checksumHex: String get() = hex16(checksum)
    val maxSeekGapFrames: Long get() = (MAX_SEEK_GAP_SEC * (format?.sampleRate ?: 0)).toLong()

    // Real (non-padded) post-seek decoded frames accepted by native.
    val postSeekDecodedAcceptedFrames: Long
        get() = postSeekAcceptedFrames - gapPaddedFrames - postSeekPaddedFrames

    // ── Decode-thread-confined state ───────────────────────────────────────

    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private val bufferInfo = MediaCodec.BufferInfo()
    private var formatResolved = false
    private var verifyOutputFormatOnNextChunk = false
    private var sampleRate = 0
    private var channelCount = 0
    private var bytesPerFrame = 0
    private var pcmEncoding = 0
    private var declaredFrameCount = 0L
    private var inputEndUs = Long.MAX_VALUE
    private var inputEos = false
    private var outputEos = false
    private var originIsStreamStart = true
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
    private var postSeekPreRollSignalled = false
    private var reanchored = false
    private var intermediateReleasesClean = true

    private var sourceMime = ""
    private var sourceTrackIndex = -1
    private var sourceDurationUs = 0L
    private var declaredWindowUs = 0L
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
    // posts pin the new generation.
    fun updateGeneration(generation: Long) {
        pinnedGeneration = generation
    }

    // Coordinator-only: after this the stall timeout applies.
    fun markTransportStarted() {
        transportStarted = true
    }

    // Coordinator-only, before transport start: the feed ingests exactly up
    // to `frame` (window-aligned, > 0) and then idles until a seek
    // re-anchor arrives. False when the value is not admissible.
    fun setPreSeekHoldFrame(frame: Long): Boolean {
        if (frame <= 0L || frame % config.maxFramesPerMix != 0L) return false
        if (reanchored || seekReanchorCount > 0) return false
        holdFrame = frame
        holdLimitFrame = frame
        return true
    }

    // Coordinator-only, after transport.seek(target) was accepted while
    // PAUSED. Single use; the decode thread executes it while held at the
    // pre-seek hold frame. False when a request already exists.
    fun requestSeekReanchor(request: SeekRequest): Boolean =
        seekRequest.compareAndSet(null, request)

    // Blocks until the pre-roll condition (ring_full observed, hold frame
    // reached or declared end reached) is signalled or the decode thread exited.
    fun awaitPreRoll(timeoutMs: Long): Boolean =
        preRollLatch.await(timeoutMs, TimeUnit.MILLISECONDS) && preRollFrames > 0L

    // Blocks until the seek re-anchor finished on the decode thread (or the
    // thread exited); true only when the re-anchor completed cleanly.
    fun awaitReanchor(timeoutMs: Long): Boolean =
        reanchorLatch.await(timeoutMs, TimeUnit.MILLISECONDS) && reanchorOk

    // Blocks until >= maxFramesPerMix post-seek frames were accepted (or the
    // declared end was reached) or the decode thread exited.
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

    // Decode-thread only. Releases the current extractor/codec pair and
    // opens a fresh pair on the same source/track (Y5b reopen-on-EOS
    // landing policy). The intermediate release outcome folds into
    // mediaReleaseClean; mediaReleaseCount only counts the final teardown.
    private fun reopenMedia() {
        checkDeadlineAndCancel()
        if (mediaReleased.get()) throw FailClosed("media_reopen_after_release")
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

    // Floor mapping: a PREVIOUS_SYNC landing at or before the target can
    // never resolve to a frame after the target, so alignment discards
    // instead of reporting a gap.
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
                            // Fresh codec after a reopen: its output format must
                            // equal the resolved session format.
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
                                // Forward playthrough from the stream start: the
                                // decoded timeline is contiguous from frame 0.
                                decodeCursorFrame = 0L
                            } else {
                                // First decoded chunk after the seek: the decoder-
                                // reported PTS anchors the decoded timeline
                                // (recorded, never verified against a clock).
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

    // ── Decoder seek (Y5b discipline, decode thread only) ──────────────────

    // Re-seats the extractor at `targetUs` (PREVIOUS_SYNC) and returns the
    // landed sample time, or -1 when Android reports no sample there.
    private fun seatExtractor(targetUs: Long): Long {
        val ex = extractor ?: throw FailClosed("extractor_missing")
        ex.seekTo(targetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        return ex.sampleTime
    }

    // Quiesces decode (staging cleared), re-seats the extractor, flushes the
    // codec and resets both EOS flags; the first post-seek output PTS
    // anchors the decoded timeline. A re-seat landing at -1 is retried once
    // on a reopened extractor/codec pair; a second -1 fails closed.
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

    // Executes the coordinator's seek request while held at the pre-seek
    // hold frame: anchor and pinned generation move to the post-seek
    // values, the decoder re-seeks, then one deliberately stale post is
    // proven rejected before JNI. Never touches JNI itself.
    private fun performReanchor(req: SeekRequest, sm: VanguardRealtimePlaybackTransportStateMachine) {
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

        // Deliberate stale probe pinned to the PRE-seek generation: the
        // owner thread must reject it before any native call (reply == null)
        // and the anchor must stay at the target.
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
            if (isCancelled()) throw FailClosed(EXIT_CANCELLED)
            if (SystemClock.elapsedRealtime() > waitUntil) throw FailClosed("owner_reply_timeout")
        }
        return holder[0] ?: throw FailClosed("owner_reply_missing")
    }

    // One ingest attempt of `frames` frames at byte offset 0 of `src`.
    // Advances the anchor/checksum only from native acceptedFrames.
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

    // Aligns the staged chunk with the anchor. Stream-start origin: a chunk
    // starting after the anchor is a timeline gap (fails closed), one
    // starting before it is dropped. PTS origin (post-seek): a gap up to
    // MAX_SEEK_GAP_SEC is left staged and silence-padded by [feedStep], a
    // larger one fails closed; pre-target PCM is discarded.
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

    // One feed attempt toward `limitFrame`: stage decoder output, pad a
    // bounded post-seek decoded-start gap, ingest at most one bounded slice,
    // or pad silence once the decoder is exhausted. True when native
    // accepted frames.
    private fun feedStep(limitFrame: Long): Boolean {
        if (anchor >= limitFrame) return false
        while (stagedFrames == 0 && !outputEos) {
            checkDeadlineAndCancel()
            if (decodeStep() == STEP_STAGED) alignStagedToAnchor() else break
        }
        val before = acceptedFrames
        val room = limitFrame - anchor
        if (stagedFrames > 0 && stagedStartFrame > anchor) {
            // Bounded decoded-start gap (validated by alignStagedToAnchor):
            // fill anchor..stagedStartFrame with silence through the same
            // generation-pinned ingest path so accounting stays contiguous.
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
            // EOS padding only applies toward the declared end, never toward
            // the pre-seek hold frame.
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

    // Feeds until the anchor reaches the declared end, holding at the
    // pre-seek hold frame until the coordinator's seek re-anchor arrives.
    // Backpressure, transient command gates and a stale generation are
    // retried in place; bounded by the deadline, the cancel flag, a
    // consecutive no-progress cap and (once the transport is started and
    // not PAUSED) a progress stall timeout.
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
                // Held at the pre-seek hold frame: no ingest until the seek
                // re-anchor. The parked interval is never a stall.
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
                val paused = sm.currentState == State.PAUSED
                if (stagedFrames > 0 || outputEos) {
                    consecutiveNoProgress++
                    if (consecutiveNoProgress > MAX_CONSECUTIVE_NO_PROGRESS) {
                        throw FailClosed("retry_budget_exhausted:$lastIngestStatus")
                    }
                    if (transportStarted && !paused &&
                        SystemClock.elapsedRealtime() - lastProgressMs > INGEST_STALL_TIMEOUT_MS
                    ) {
                        throw FailClosed("ingest_stall:$lastIngestStatus:${sm.currentState.name.lowercase()}")
                    }
                    // Pre-roll ring_full and a PAUSED transport (post-seek
                    // pre-roll waiting for resume) legitimately wait.
                    if (!transportStarted || paused) lastProgressMs = SystemClock.elapsedRealtime()
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
