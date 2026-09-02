package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.NativeState
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.IngestRequest
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.Result as TransportResult
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

// ── VanguardRealtimePlaybackRealDecoderAdapter (P4-AUDIO-REALTIME-PLAYBACK-REAL-DECODER, Y5b) ─
//
// Kotlin-owned MediaExtractor/MediaCodec (synchronous mode) decoder adapter
// that feeds ONE external-ingest track of the Y5a realtime playback graph
// through [VanguardRealtimePlaybackTransportStateMachine.postIngest] only.
// This class never touches JNI: every PCM handoff is a generation-pinned
// post onto the transport's owner HandlerThread, and every drain/snapshot/
// command goes through the same state machine.
//
// Ownership and lifecycle (Android MediaCodec/MediaExtractor contract):
// - The extractor owns setDataSource/selectTrack/readSampleData/advance/
//   seekTo/release; the codec runs synchronously (dequeueInputBuffer /
//   queueInputBuffer / dequeueOutputBuffer / releaseOutputBuffer) on the
//   single thread that calls [run]. No input is queued after EOS until a
//   flush; a seek always flushes the codec after the extractor re-seats.
// - Every codec output slice is copied into an adapter-owned direct
//   staging buffer (PCM16 at byte offset 0) and the codec output buffer is
//   released BEFORE any transport ingest. Codec-owned buffers are never
//   retained across ingest or callbacks. Ingest slices are at most
//   [VanguardRealtimePlaybackNativeSession.MAX_INGEST_FRAMES] frames; an
//   unwritten remainder (partial_write / ring_full) is compacted back to
//   byte offset 0 and retried later at the reply's nextWriteFrame, so no
//   frame is dropped or duplicated. Native acceptedFrames is the source of
//   truth; the Kotlin checksum is accumulated over exactly the accepted
//   interleaved samples (checksum = checksum * 31 + uint16(sample)).
// - Re-seating after EOS: Android may answer seekTo() on an extractor that
//   already reported EOS with sampleTime == -1. The adapter never depends
//   on that path: a re-seat that lands at -1 releases the extractor/codec
//   pair and reopens the same source/track (fresh MediaExtractor +
//   MediaCodec, output format re-verified against the resolved session
//   format), then re-seats once more. Reopen count is reported
//   (seekMediaReopens); the final teardown remains idempotent and releases
//   whichever pair is current, so no codec or extractor leaks across a
//   reopen.
// - Post-seek decoded timeline: after a non-zero seek the first decoded
//   PCM PTS may land AFTER the requested target (packet boundary, codec
//   priming/delay, or an approximate extractor seek table). That gap is
//   not an error: it is filled with silence through the same ingest path,
//   bounded by MAX_SEEK_GAP_SEC, and reported (seekGapPaddedFrames,
//   seekFirstDecodedFrame/PtsUs). A larger gap fails closed. This keeps
//   the transport's re-anchored accounting contiguous; it is NOT a claim
//   of sample-accurate seeking, audio quality, or A/V sync.
// - Session format comes from the decoder output format (PCM16, 1-2
//   channels, 8000..192000 Hz); no resampling or downmixing exists here.
//   declaredFrameCount = floor(min(track duration, maxDurationSec) * rate).
// - EOS accounting: a decoder that ends at most 1 s short of the declared
//   end is padded with silence through the same ingest path; decoder
//   output beyond the declared end is truncated (never ingested); a larger
//   shortfall fails closed.
// - Teardown is idempotent and runs on every path (pass, fail, timeout,
//   cancel): decode stops, codec stop/release, extractor release, state
//   machine dispose.
//
// Proof structure (one extractor/codec, two sequential transport sessions):
// - Playthrough session: PREPARED pre-roll until the source ring reports
//   partial_write then ring_full, start, generation-pinned steady-state
//   feeding with remainder retries, one deliberate external starvation
//   (nonterminal underrun while PLAYING, then recovery), EOS padding /
//   truncation, completion with positionFrame == declared, eosDrained,
//   pushed == drained == declared and the three-way checksum identity.
// - Seek session: exactly PRE_SEEK_WINDOWS windows are fed and rendered
//   (the source ring is empty), the output ring is drained under PAUSED,
//   transport seek(target) re-anchors the writer, the decoder re-seeks
//   (extractor PREVIOUS_SYNC + codec flush + EOS flag reset, or a media
//   reopen when the re-seat lands at -1), PCM before the target is
//   discarded, a bounded decoded-start gap after the target is silence-
//   padded with metrics, a postIngest pinned to the pre-seek generation is
//   rejected before JNI, >= maxFramesPerMix frames are pre-rolled at the
//   new anchor, resume, and completion is verified with discardedFrames ==
//   0, pushed == drained == preSeek + (declared - target), at least one
//   real (non-padded) decoded post-seek frame accepted, and the same
//   three-way checksum identity across the seek.
//
// Honest non-claims: no presentation clock, no A/V sync, no AudioTrack or
// audible output, no audio-quality or latency claim, no product/editor
// wiring, no iOS, no streaming/cache route, no native changes.
class VanguardRealtimePlaybackRealDecoderAdapter {

    data class Config(
        val sourcePath: String,
        val maxDurationSec: Double = 1.0,
        val seekTargetSec: Double = 0.35,
        val maxFramesPerMix: Int = 256,
        val deadlineMs: Long = 30_000L,
    )

    data class Result(
        val pass: Boolean,
        val status: String,
        val failureReason: String,
        val proofBoundary: String,
        val lanes: Map<String, Boolean>,
        val metrics: Map<String, Any?>,
        val raw: String,
    )

    companion object {
        const val PROOF_BOUNDARY =
            "realtime_playback_real_decoder_diagnostic_only_mediacodec_mediaextractor_streaming_pcm16_" +
                "to_y5a_external_ingest_seam_generation_pinned_owner_thread_handoff_no_presentation_clock_" +
                "no_av_sync_no_resample_no_downmix_no_product_editor_app_wiring_no_ios_no_streaming_cache_" +
                "no_native_cpp_changes"

        const val LANE_FORMAT_PROBE = "formatProbeOk"
        const val LANE_REAL_DECODER_INGEST = "realDecoderIngestOk"
        const val LANE_SEEK_REANCHOR = "seekReanchorOk"
        const val LANE_BACKPRESSURE_RECOVERY = "backpressureRecoveryOk"
        const val LANE_UNDERRUN_TOLERANCE = "underrunToleranceOk"
        const val LANE_EOS_ACCOUNTING = "eosAccountingOk"
        const val LANE_STALE_GENERATION_REJECTED = "staleGenerationRejectedOk"
        const val LANE_LIFECYCLE_DISPOSE = "lifecycleDisposeOk"
        const val LANE_PROOF_BOUNDARY = "proofBoundaryOk"
        const val LANE_CANONICAL = "canonical"

        val REQUIRED_LANES: List<String> = listOf(
            LANE_FORMAT_PROBE,
            LANE_REAL_DECODER_INGEST,
            LANE_SEEK_REANCHOR,
            LANE_BACKPRESSURE_RECOVERY,
            LANE_UNDERRUN_TOLERANCE,
            LANE_EOS_ACCOUNTING,
            LANE_STALE_GENERATION_REJECTED,
            LANE_LIFECYCLE_DISPOSE,
        )

        const val TRACK_COUNT = 1
        const val EXTERNAL_TRACK_INDEX = 0
        const val EXTERNAL_INGEST_TRACK_MASK = 1

        private const val MAX_INGEST_FRAMES = VanguardRealtimePlaybackNativeSession.MAX_INGEST_FRAMES
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val HARD_MAX_DURATION_SEC = 60.0
        private const val MAX_EOS_DRIFT_SEC = 1.0
        // Upper bound on the post-seek decoded-start gap that is silence-
        // padded instead of failing closed (packet boundary + codec delay +
        // approximate seek tables stay well inside this).
        private const val MAX_SEEK_GAP_SEC = 0.25
        private const val END_INPUT_MARGIN_US = 250_000L
        private const val PRE_SEEK_WINDOWS = 4
        private const val POST_SEEK_PREROLL_WINDOWS = 4
        private const val POLL_SLEEP_MS = 2L
        private const val OWNER_REPLY_TIMEOUT_MS = 10_000L
        private const val INGEST_STALL_TIMEOUT_MS = 3_000L
        private const val MAX_CONSECUTIVE_TRANSIENT_REJECTS = 5_000
        private const val STARVATION_WAIT_MS = 3_000L
        private const val RENDER_WAIT_MS = 3_000L
        private const val MAX_EMPTY_DRAIN_ITERATIONS = 256
        private const val DRAIN_WINDOWS_PER_POLL = 8

        private const val STEP_STAGED = 1
        private const val STEP_TRY_AGAIN = 0
        private const val STEP_EOS = -1

        private fun hex16(value: Long): String = String.format("%016x", value)
    }

    private class FailClosed(val reason: String) : Exception(reason)

    // Per-transport-session producer bookkeeping. `anchor` mirrors the
    // native writer cursor (nextWriteFrame) and is only advanced from
    // native acceptedFrames.
    private inner class Lane(val name: String, val sm: VanguardRealtimePlaybackTransportStateMachine) {
        var generation: Long = sm.currentGeneration
        var anchor = 0L
        var acceptedFrames = 0L
        var checksum = 0L
        var ingestCalls = 0
        var drainCalls = 0
        var transientRejects = 0
        var consecutiveNoProgress = 0
        var lastStatus = ""
        var observedPartialWrite = false
        var observedRingFull = false
        var remainderPendingAfterBackpressure = false
        var remainderRetryAccepted = false
        var paddedFrames = 0L
        var gapPaddedFrames = 0L
        var truncatedFrames = 0L
        var lastProgressMs = SystemClock.elapsedRealtime()
        var lastReply: Reply? = null
        val drainDst: ByteBuffer = directBuffer(maxFramesPerMix)

        fun checksumHex(): String = hex16(checksum)
    }

    private val started = AtomicBoolean(false)
    private val cancelled = AtomicBoolean(false)
    private val mediaReleased = AtomicBoolean(false)

    @Volatile
    private var running = false

    @Volatile
    private var activeMachine: VanguardRealtimePlaybackTransportStateMachine? = null

    // Decoder state (confined to the [run] thread).
    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private var sourcePath = ""
    private var sourceMime = ""
    private var audioTrackIndex = -1
    private var trackFormat: MediaFormat? = null
    private var mediaReopens = 0
    private var intermediateReleasesClean = true
    private var verifyOutputFormatOnNextChunk = false
    private val bufferInfo = MediaCodec.BufferInfo()
    private var formatResolved = false
    private var sampleRate = 0
    private var channelCount = 0
    private var bytesPerFrame = 0
    private var pcmEncoding = 0
    private var maxFramesPerMix = 0
    private var declaredFrameCount = 0L
    private var inputEndUs = Long.MAX_VALUE
    private var inputEos = false
    private var outputEos = false
    private var originIsStreamStart = true
    private var decodeCursorFrame = -1L
    private var staging: ByteBuffer? = null
    private var stagedFrames = 0
    private var stagedStartFrame = -1L
    private var codecChunks = 0L
    private var decodedFramesTotal = 0L
    private var discardedPreTargetFrames = 0L
    private var firstPostSeekPtsUs = -1L
    private var firstPostSeekFrame = -1L
    private var seekGapObservedFrames = 0L
    private var deadlineAt = 0L
    private var mediaReleaseClean = false

    private val lanes = linkedMapOf<String, Boolean>()
    private val metrics = linkedMapOf<String, Any?>()

    // ── Public API ─────────────────────────────────────────────────────────

    // Requests cancellation from any thread. The run thread observes the
    // flag at its next bounded wait and tears down on its own thread.
    fun cancel() {
        cancelled.set(true)
    }

    // Any-thread, idempotent. Cancels a running adapter (the run thread
    // performs the teardown) or tears down immediately when idle.
    fun dispose() {
        cancel()
        if (!running) teardown()
    }

    // Executes the full proof on the calling thread. Single use.
    fun run(config: Config): Result {
        if (!started.compareAndSet(false, true)) {
            return buildResult(false, "adapter_already_used")
        }
        running = true
        for (lane in REQUIRED_LANES) lanes[lane] = false
        maxFramesPerMix = config.maxFramesPerMix
        deadlineAt = SystemClock.elapsedRealtime() + config.deadlineMs
        return try {
            execute(config)
            val pass = REQUIRED_LANES.all { lanes[it] == true }
            buildResult(pass, if (pass) "" else "lane_failed:${firstFailedLane()}")
        } catch (f: FailClosed) {
            buildResult(false, f.reason)
        } catch (t: Throwable) {
            buildResult(false, "exception:${t.javaClass.simpleName}:${t.message}")
        } finally {
            teardown()
            running = false
        }
    }

    // ── Orchestration ──────────────────────────────────────────────────────

    private fun execute(config: Config) {
        validateConfig(config)
        openMedia(config)
        probeFormat(config)
        lanes[LANE_FORMAT_PROBE] = true

        val sessionConfig = VanguardRealtimePlaybackNativeSession.Config(
            sampleRate = sampleRate,
            channelCount = channelCount,
            maxFramesPerMix = maxFramesPerMix,
            trackCount = TRACK_COUNT,
            declaredFrameCount = declaredFrameCount,
            externalIngestTrackMask = EXTERNAL_INGEST_TRACK_MASK,
        )
        VanguardRealtimePlaybackNativeSession.validate(sessionConfig)?.let {
            throw FailClosed("session_config_invalid:${it.name.lowercase()}")
        }
        val seekTargetFrame = (config.seekTargetSec * sampleRate).toLong()
        val preSeekFrames = PRE_SEEK_WINDOWS.toLong() * maxFramesPerMix
        if (config.seekTargetSec < 0.0 || seekTargetFrame < preSeekFrames + maxFramesPerMix ||
            seekTargetFrame + 2L * maxFramesPerMix > declaredFrameCount
        ) {
            throw FailClosed("invalid_seek_target:$seekTargetFrame:$declaredFrameCount")
        }
        metrics["seekTargetFrame"] = seekTargetFrame
        metrics["preSeekFrames"] = preSeekFrames

        runPlaythroughSession(sessionConfig)
        runSeekSession(sessionConfig, seekTargetFrame, preSeekFrames)
    }

    private fun validateConfig(config: Config) {
        if (config.sourcePath.isBlank()) throw FailClosed("source_path_required")
        if (config.maxDurationSec <= 0.0 || config.maxDurationSec > HARD_MAX_DURATION_SEC) {
            throw FailClosed("invalid_max_duration")
        }
        if (config.maxFramesPerMix <= 0 ||
            config.maxFramesPerMix > VanguardRealtimePlaybackNativeSession.MAX_FRAMES_PER_MIX_CAP
        ) {
            throw FailClosed("invalid_max_frames_per_mix")
        }
        if (config.deadlineMs <= 0L) throw FailClosed("invalid_deadline")
    }

    // ── Media open / format probe ──────────────────────────────────────────

    private fun openMedia(config: Config) {
        val ex = MediaExtractor()
        extractor = ex
        ex.setDataSource(config.sourcePath)
        var trackIndex = -1
        var format: MediaFormat? = null
        for (i in 0 until ex.trackCount) {
            val f = ex.getTrackFormat(i)
            if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                trackIndex = i
                format = f
                break
            }
        }
        if (trackIndex < 0 || format == null) throw FailClosed("no_audio_track")
        ex.selectTrack(trackIndex)
        val mime = format.getString(MediaFormat.KEY_MIME) ?: throw FailClosed("audio_track_mime_missing")
        if (!format.containsKey(MediaFormat.KEY_DURATION)) throw FailClosed("format_duration_missing")
        val durationUs = format.getLong(MediaFormat.KEY_DURATION)
        if (durationUs <= 0L) throw FailClosed("format_duration_invalid:$durationUs")
        sourcePath = config.sourcePath
        sourceMime = mime
        audioTrackIndex = trackIndex
        trackFormat = format
        metrics["sourceMime"] = mime
        metrics["sourceDurationUs"] = durationUs
        metrics["sourceTrackIndex"] = trackIndex
        val windowUs = minOf(durationUs, (config.maxDurationSec * 1_000_000.0).toLong())
        metrics["declaredWindowUs"] = windowUs

        startCodec(format, mime)
        // The declared window is only known after the output format
        // resolves; until then the input side is bounded by the window.
        inputEndUs = windowUs + END_INPUT_MARGIN_US
    }

    // Creates, configures and starts a synchronous decoder for `format`,
    // resetting the decode-side flags. The codec field is assigned before
    // configure/start so a failure mid-way is still released by teardown.
    private fun startCodec(format: MediaFormat, mime: String) {
        val dec = MediaCodec.createDecoderByType(mime)
        codec = dec
        dec.configure(format, null, null, 0)
        dec.start()
        inputEos = false
        outputEos = false
        originIsStreamStart = true
        decodeCursorFrame = -1L
    }

    // Run-thread only. Releases the current extractor/codec pair and opens
    // a fresh pair on the same source/track. Used when Android answers a
    // re-seat with sampleTime == -1 (typically an EOS-positioned extractor)
    // so a seek session never depends on reusing an exhausted pair. The
    // fields are re-assigned as each object is created, so teardown always
    // releases whatever exists; the intermediate release outcome folds into
    // mediaReleaseClean.
    private fun reopenMedia() {
        checkDeadlineAndCancel()
        if (mediaReleased.get()) throw FailClosed("media_reopen_after_release")
        val format = trackFormat ?: throw FailClosed("media_reopen_format_missing")
        if (sourcePath.isBlank() || audioTrackIndex < 0) throw FailClosed("media_reopen_source_missing")
        if (!releaseMediaObjects()) intermediateReleasesClean = false
        clearStaged()
        val ex = MediaExtractor()
        extractor = ex
        ex.setDataSource(sourcePath)
        if (audioTrackIndex >= ex.trackCount) throw FailClosed("media_reopen_track_missing:$audioTrackIndex")
        val reopenedMime = ex.getTrackFormat(audioTrackIndex).getString(MediaFormat.KEY_MIME)
        if (reopenedMime != sourceMime) throw FailClosed("media_reopen_mime_changed:$reopenedMime")
        ex.selectTrack(audioTrackIndex)
        // The resolved session format stays authoritative: the fresh codec's
        // output format is re-verified by resolveOutputFormat (a mismatch
        // fails closed as mid_stream_format_change).
        startCodec(format, sourceMime)
        verifyOutputFormatOnNextChunk = true
        mediaReopens++
        metrics["seekMediaReopens"] = mediaReopens
    }

    // Pulls decoder output until the PCM output format is known, keeping
    // the first staged chunk for the playthrough session.
    private fun probeFormat(config: Config) {
        while (!formatResolved) {
            checkDeadlineAndCancel()
            when (decodeStep()) {
                STEP_EOS -> if (!formatResolved) throw FailClosed("no_decoder_output")
                else -> Unit
            }
        }
        val windowUs = metrics["declaredWindowUs"] as Long
        declaredFrameCount = windowUs * sampleRate / 1_000_000L
        if (declaredFrameCount <= 0L) throw FailClosed("declared_frame_count_invalid:$declaredFrameCount")
        if (declaredFrameCount < 4L * maxFramesPerMix) throw FailClosed("declared_frame_count_too_small:$declaredFrameCount")
        val declaredEndUs = (declaredFrameCount * 1_000_000L + sampleRate - 1) / sampleRate
        inputEndUs = declaredEndUs + END_INPUT_MARGIN_US
        metrics["sampleRate"] = sampleRate
        metrics["channelCount"] = channelCount
        metrics["pcmEncoding"] = pcmEncoding
        metrics["declaredFrameCount"] = declaredFrameCount
        metrics["maxFramesPerMix"] = maxFramesPerMix
        metrics["maxDurationSec"] = config.maxDurationSec
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

    // ── Codec pump (synchronous mode, run thread only) ─────────────────────

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
                            // equal the resolved session format (fails closed as
                            // mid_stream_format_change otherwise).
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
                                decodeCursorFrame = 0L
                            } else {
                                // First decoded chunk after a non-zero seek: the
                                // decoder-reported PTS anchors the decoded timeline
                                // (recorded for the seek metrics, not verified
                                // against any presentation clock).
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

    // Floor mapping: a PREVIOUS_SYNC landing at or before the target can
    // never resolve to a frame after the target, so alignment discards
    // instead of reporting a gap.
    private fun framesOfUs(us: Long): Long =
        if (us <= 0L) 0L else us * sampleRate / 1_000_000L

    // Re-seats the extractor at `targetUs` (PREVIOUS_SYNC) and returns the
    // landed sample time, or -1 when Android reports no sample there.
    private fun seatExtractor(targetUs: Long): Long {
        val ex = extractor ?: throw FailClosed("extractor_missing")
        ex.seekTo(targetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        return ex.sampleTime
    }

    // Quiesces decode (staging cleared), re-seats the extractor, flushes the
    // codec and resets both EOS flags. `streamStart` pins the decoded
    // timeline origin to frame 0; otherwise the first output PTS anchors it.
    // A re-seat that lands at -1 (EOS-positioned extractor) is retried once
    // on a reopened extractor/codec pair; a second -1 fails closed.
    private fun reseekDecoder(targetUs: Long, streamStart: Boolean): Long {
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
        originIsStreamStart = streamStart
        decodeCursorFrame = -1L
        firstPostSeekPtsUs = -1L
        firstPostSeekFrame = -1L
        return landedUs
    }

    // ── Transport helpers (owner-thread handoff only) ──────────────────────

    private fun directBuffer(frames: Int): ByteBuffer =
        ByteBuffer.allocateDirect(frames * bytesPerFrame).order(ByteOrder.nativeOrder())

    private fun checkDeadlineAndCancel() {
        if (cancelled.get()) throw FailClosed("cancelled")
        if (SystemClock.elapsedRealtime() > deadlineAt) throw FailClosed("deadline_exceeded")
    }

    private fun sleepPoll() {
        try {
            Thread.sleep(POLL_SLEEP_MS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            throw FailClosed("interrupted")
        }
    }

    // Generation-pinned postIngest; waits (bounded) for the owner-thread
    // callback. The producer thread never reaches JNI.
    private fun pinnedIngest(lane: Lane, src: ByteBuffer, frames: Int, generation: Long = lane.generation): TransportResult {
        val latch = CountDownLatch(1)
        val holder = arrayOfNulls<TransportResult>(1)
        lane.sm.postIngest(
            IngestRequest(EXTERNAL_TRACK_INDEX, src, frames, lane.anchor),
            expectedGeneration = generation,
        ) { r ->
            holder[0] = r
            latch.countDown()
        }
        if (!latch.await(OWNER_REPLY_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            throw FailClosed("${lane.name}_owner_reply_timeout")
        }
        return holder[0] ?: throw FailClosed("${lane.name}_owner_reply_missing")
    }

    // One ingest attempt of `frames` frames at byte offset 0 of `src`.
    // Advances the anchor/checksum only from native acceptedFrames. Returns
    // the native status (or the transient rejection reason). Terminal
    // rejections fail closed.
    private fun ingestOnce(lane: Lane, src: ByteBuffer, frames: Int): String {
        checkDeadlineAndCancel()
        val res = pinnedIngest(lane, src, frames)
        lane.ingestCalls++
        if (!res.accepted) {
            return when (res.reason) {
                VanguardRealtimePlaybackTransportStateMachine.REASON_STALE_GENERATION ->
                    throw FailClosed("${lane.name}_unexpected_stale_generation")
                "${VanguardRealtimePlaybackTransportStateMachine.REASON_INGEST_PREFIX}${VanguardRealtimePlaybackNativeSession.STATUS_COMMAND_IN_FLIGHT}",
                "${VanguardRealtimePlaybackTransportStateMachine.REASON_INGEST_PREFIX}${VanguardRealtimePlaybackNativeSession.STATUS_AWAITING_SEEK_ACK}",
                -> {
                    lane.transientRejects++
                    lane.lastStatus = res.reason
                    res.reason
                }
                else -> throw FailClosed("${lane.name}_ingest_rejected:${res.reason}")
            }
        }
        val reply = res.reply ?: throw FailClosed("${lane.name}_ingest_null_reply")
        lane.lastStatus = reply.status
        val n = reply.acceptedFrames
        if (n < 0L || n > frames) throw FailClosed("${lane.name}_accepted_out_of_range:$n")
        if (n > 0L) {
            if (reply.nextWriteFrame != lane.anchor + n) {
                throw FailClosed("${lane.name}_anchor_divergence:${reply.nextWriteFrame}:${lane.anchor + n}")
            }
            val samples = (n * channelCount).toInt()
            var c = lane.checksum
            for (i in 0 until samples) c = c * 31L + (src.getShort(i * 2).toLong() and 0xFFFFL)
            lane.checksum = c
            if (lane.remainderPendingAfterBackpressure) {
                lane.remainderRetryAccepted = true
                lane.remainderPendingAfterBackpressure = false
            }
            lane.anchor += n
            lane.acceptedFrames += n
            lane.lastProgressMs = SystemClock.elapsedRealtime()
            lane.consecutiveNoProgress = 0
        }
        when (reply.status) {
            VanguardRealtimePlaybackNativeSession.STATUS_PARTIAL_WRITE -> {
                lane.observedPartialWrite = true
                lane.remainderPendingAfterBackpressure = true
            }
            VanguardRealtimePlaybackNativeSession.STATUS_RING_FULL -> {
                lane.observedRingFull = true
                lane.remainderPendingAfterBackpressure = true
            }
        }
        return reply.status
    }

    private fun maxSeekGapFrames(): Long = (MAX_SEEK_GAP_SEC * sampleRate).toLong()

    // Aligns the staged chunk with the lane anchor: PCM before the anchor is
    // discarded (post-seek pre-target audio). A chunk starting after the
    // anchor is a decoded-timeline gap: on a stream-start origin (decoded
    // frames are contiguous from 0 by construction) that fails closed; on a
    // PTS-anchored post-seek origin a gap up to MAX_SEEK_GAP_SEC is left
    // staged and silence-padded by [feedStep], a larger one fails closed.
    private fun alignStagedToAnchor(lane: Lane, discardCounter: Boolean) {
        if (stagedFrames <= 0) return
        val start = stagedStartFrame
        if (start < 0L) throw FailClosed("${lane.name}_staged_timeline_unknown")
        if (start > lane.anchor) {
            val gap = start - lane.anchor
            if (originIsStreamStart) throw FailClosed("${lane.name}_decoded_timeline_gap:$start:${lane.anchor}")
            if (gap > maxSeekGapFrames()) {
                throw FailClosed("${lane.name}_decoded_timeline_gap_exceeded:$start:${lane.anchor}:${maxSeekGapFrames()}")
            }
            seekGapObservedFrames += gap
            return
        }
        if (start < lane.anchor) {
            val drop = minOf((lane.anchor - start), stagedFrames.toLong()).toInt()
            if (discardCounter) discardedPreTargetFrames += drop
            consumeStaged(drop)
        }
    }

    // One feed attempt toward `limitFrame`: stage decoder output (aligned to
    // the anchor), silence-pad a bounded post-seek decoded-start gap, ingest
    // at most one bounded slice, or pad silence once the decoder is
    // exhausted. Returns true when native accepted frames.
    private fun feedStep(lane: Lane, limitFrame: Long, discardCounter: Boolean): Boolean {
        if (lane.anchor >= limitFrame) return false
        if (stagedFrames == 0 && !outputEos) {
            // Pull until a chunk lands at or after the anchor, or the codec
            // has nothing right now.
            while (stagedFrames == 0 && !outputEos) {
                checkDeadlineAndCancel()
                val step = decodeStep()
                if (step == STEP_STAGED) {
                    alignStagedToAnchor(lane, discardCounter)
                } else {
                    break
                }
            }
        }
        val before = lane.acceptedFrames
        val room = limitFrame - lane.anchor
        if (stagedFrames > 0 && stagedStartFrame > lane.anchor) {
            // Bounded decoded-start gap (already validated by
            // alignStagedToAnchor): fill anchor..stagedStartFrame with
            // silence through the same generation-pinned ingest path so the
            // transport accounting stays contiguous. Counted separately from
            // EOS padding; this is not decoded audio.
            val gap = stagedStartFrame - lane.anchor
            val frames = minOf(gap, MAX_INGEST_FRAMES.toLong(), room).toInt()
            ingestOnce(lane, silenceBuffer(), frames)
            lane.gapPaddedFrames += lane.acceptedFrames - before
        } else if (stagedFrames > 0) {
            val frames = minOf(stagedFrames.toLong(), MAX_INGEST_FRAMES.toLong(), room).toInt()
            val s = staging ?: throw FailClosed("${lane.name}_staging_missing")
            ingestOnce(lane, s, frames)
            val accepted = (lane.acceptedFrames - before).toInt()
            if (accepted > 0) consumeStaged(accepted)
        } else if (outputEos) {
            val shortfall = limitFrame - lane.anchor
            if (shortfall > (MAX_EOS_DRIFT_SEC * sampleRate).toLong()) {
                throw FailClosed("${lane.name}_eos_drift_exceeded:$shortfall")
            }
            val frames = minOf(shortfall, MAX_INGEST_FRAMES.toLong()).toInt()
            val silence = silenceBuffer()
            ingestOnce(lane, silence, frames)
            lane.paddedFrames += lane.acceptedFrames - before
        }
        return lane.acceptedFrames > before
    }

    private var silence: ByteBuffer? = null

    private fun silenceBuffer(): ByteBuffer {
        val current = silence
        if (current != null) return current
        val fresh = directBuffer(MAX_INGEST_FRAMES) // allocateDirect zero-fills
        silence = fresh
        return fresh
    }

    private fun drainOutput(lane: Lane, maxWindows: Int) {
        for (i in 0 until maxWindows) {
            val res = lane.sm.drain(lane.drainDst, maxFramesPerMix)
            lane.drainCalls++
            if (!res.accepted) throw FailClosed("${lane.name}_drain_rejected:${res.reason}")
            val reply = res.reply ?: throw FailClosed("${lane.name}_drain_null_reply")
            lane.lastReply = reply
            if (reply.framesRead < maxFramesPerMix) return
        }
    }

    private fun snapshot(lane: Lane): Reply {
        val res = lane.sm.snapshot()
        val reply = res.reply ?: throw FailClosed("${lane.name}_snapshot_rejected:${res.reason}")
        if (!res.accepted) throw FailClosed("${lane.name}_snapshot_rejected:${res.reason}")
        lane.lastReply = reply
        return reply
    }

    private fun requireAccepted(lane: Lane, what: String, res: TransportResult): TransportResult {
        if (!res.accepted) throw FailClosed("${lane.name}_${what}_rejected:${res.reason}")
        return res
    }

    // Feeds until the anchor reaches `limitFrame`, draining the output ring
    // between attempts; bounded by the deadline, a progress stall timeout
    // and a consecutive transient-rejection cap. `beforeAttempt` may pause
    // feeding (return false) for starvation control.
    private fun feedUntil(
        lane: Lane,
        limitFrame: Long,
        discardCounter: Boolean = false,
        stopOnRingFull: Boolean = false,
        beforeAttempt: (() -> Boolean)? = null,
    ) {
        while (lane.anchor < limitFrame) {
            checkDeadlineAndCancel()
            val allowed = beforeAttempt?.invoke() ?: true
            var progressed = false
            if (allowed) {
                progressed = feedStep(lane, limitFrame, discardCounter)
                if (stopOnRingFull && lane.lastStatus == VanguardRealtimePlaybackNativeSession.STATUS_RING_FULL) return
            }
            drainOutput(lane, DRAIN_WINDOWS_PER_POLL)
            if (!allowed) {
                // Deliberate starvation window: not a stall.
                lane.lastProgressMs = SystemClock.elapsedRealtime()
                sleepPoll()
            } else if (!progressed) {
                if (stagedFrames > 0 || outputEos) {
                    lane.consecutiveNoProgress++
                    if (lane.consecutiveNoProgress > MAX_CONSECUTIVE_TRANSIENT_REJECTS) {
                        throw FailClosed("${lane.name}_retry_budget_exhausted:${lane.lastStatus}")
                    }
                    if (SystemClock.elapsedRealtime() - lane.lastProgressMs > INGEST_STALL_TIMEOUT_MS) {
                        throw FailClosed("${lane.name}_ingest_stall:${lane.lastStatus}:${lane.sm.currentState.name.lowercase()}")
                    }
                    sleepPoll()
                }
            }
            if (lane.sm.currentState == State.FAILED) throw FailClosed("${lane.name}_transport_failed")
        }
    }

    private fun awaitCompletion(lane: Lane): Reply {
        while (true) {
            checkDeadlineAndCancel()
            when (lane.sm.currentState) {
                State.COMPLETED -> return snapshot(lane)
                State.FAILED, State.DISPOSED -> throw FailClosed("${lane.name}_transport_${lane.sm.currentState.name.lowercase()}")
                else -> Unit
            }
            drainOutput(lane, DRAIN_WINDOWS_PER_POLL)
            sleepPoll()
        }
    }

    private fun drainUntilEmpty(lane: Lane) {
        for (i in 0 until MAX_EMPTY_DRAIN_ITERATIONS) {
            checkDeadlineAndCancel()
            val res = lane.sm.drain(lane.drainDst, maxFramesPerMix)
            lane.drainCalls++
            if (!res.accepted) throw FailClosed("${lane.name}_drain_rejected:${res.reason}")
            val reply = res.reply ?: throw FailClosed("${lane.name}_drain_null_reply")
            lane.lastReply = reply
            if (reply.framesRead == 0L && reply.outputAvailableReadFrames == 0L) return
        }
        throw FailClosed("${lane.name}_drain_empty_budget_exhausted")
    }

    // ── Playthrough session ────────────────────────────────────────────────

    private fun runPlaythroughSession(sessionConfig: VanguardRealtimePlaybackNativeSession.Config) {
        val sm = VanguardRealtimePlaybackTransportStateMachine(sessionConfig, threadName = "Y5bPlaythrough")
        activeMachine = sm
        val lane = Lane("playthrough", sm)
        try {
            requireAccepted(lane, "load", sm.load())
            requireAccepted(lane, "prepare", sm.prepare())
            lane.generation = sm.currentGeneration

            // PREPARED pre-roll: feed until the source ring reports ring_full
            // (a partial_write normally precedes it) or the declared end.
            feedUntil(lane, declaredFrameCount, stopOnRingFull = true)
            metrics["playPrerollFrames"] = lane.anchor
            metrics["playPrerollPartialWrite"] = lane.observedPartialWrite
            metrics["playPrerollRingFull"] = lane.observedRingFull

            val startRes = requireAccepted(lane, "start", sm.start())
            if (startRes.state != State.PLAYING) throw FailClosed("playthrough_start_state:${startRes.state}")
            lane.generation = sm.currentGeneration

            // Steady state with one deliberate starvation window once the
            // producer is well ahead of the start.
            val starveAtFrame = declaredFrameCount / 3L
            var starving = false
            var starvationDone = false
            var starvationObserved = false
            var starvedPositionFrame = -1L
            var starvedUnderrunCount = -1L
            var starvationStartedMs = 0L
            val underrunBaseline = snapshot(lane).underrunCount
            feedUntil(lane, declaredFrameCount) {
                if (starvationDone) return@feedUntil true
                if (!starving) {
                    if (lane.anchor < starveAtFrame) return@feedUntil true
                    starving = true
                    starvationStartedMs = SystemClock.elapsedRealtime()
                }
                val snap = snapshot(lane)
                if (snap.underrunCount > underrunBaseline && sm.currentState == State.PLAYING &&
                    snap.state == NativeState.PLAYING
                ) {
                    starvationObserved = true
                    starvedPositionFrame = snap.positionFrame
                    starvedUnderrunCount = snap.underrunCount
                    starvationDone = true
                    return@feedUntil true
                }
                if (SystemClock.elapsedRealtime() - starvationStartedMs > STARVATION_WAIT_MS) {
                    starvationDone = true
                    return@feedUntil true
                }
                false
            }
            // Anything still staged past the declared end is truncated.
            lane.truncatedFrames = stagedFrames.toLong()
            clearStaged()

            val final = awaitCompletion(lane)
            val kotlinHex = lane.checksumHex()
            val completed = sm.currentState == State.COMPLETED &&
                final.state == NativeState.COMPLETED &&
                final.positionFrame == declaredFrameCount && final.eosDrained && final.eosPushed &&
                final.pushedFrames == declaredFrameCount && final.drainedFrames == declaredFrameCount &&
                final.discardedFrames == 0L && final.lastError == "none"
            val checksumsOk = kotlinHex == final.pushedChecksumHex && kotlinHex == final.drainedChecksumHex
            val accountingOk = lane.acceptedFrames == declaredFrameCount && lane.anchor == declaredFrameCount &&
                lane.paddedFrames <= (MAX_EOS_DRIFT_SEC * sampleRate).toLong() &&
                lane.paddedFrames + (lane.acceptedFrames - lane.paddedFrames) == declaredFrameCount

            lanes[LANE_REAL_DECODER_INGEST] = completed && checksumsOk && accountingOk &&
                codecChunks > 0L && lane.acceptedFrames - lane.paddedFrames > 0L
            lanes[LANE_BACKPRESSURE_RECOVERY] = completed && checksumsOk && accountingOk &&
                lane.observedPartialWrite && lane.observedRingFull && lane.remainderRetryAccepted
            lanes[LANE_UNDERRUN_TOLERANCE] = completed && starvationObserved &&
                starvedPositionFrame in 0L until declaredFrameCount &&
                final.underrunCount >= starvedUnderrunCount
            lanes[LANE_EOS_ACCOUNTING] = completed && checksumsOk && accountingOk

            metrics["playFinalState"] = sm.currentState.name
            metrics["playNativeState"] = final.stateToken
            metrics["playPositionFrame"] = final.positionFrame
            metrics["playPushedFrames"] = final.pushedFrames
            metrics["playDrainedFrames"] = final.drainedFrames
            metrics["playDiscardedFrames"] = final.discardedFrames
            metrics["playEosPushed"] = final.eosPushed
            metrics["playEosDrained"] = final.eosDrained
            metrics["playAcceptedFrames"] = lane.acceptedFrames
            metrics["playDecodedFramesAccepted"] = lane.acceptedFrames - lane.paddedFrames
            metrics["playPaddedFrames"] = lane.paddedFrames
            metrics["playTruncatedFrames"] = lane.truncatedFrames
            metrics["playIngestCalls"] = lane.ingestCalls
            metrics["playDrainCalls"] = lane.drainCalls
            metrics["playTransientRejects"] = lane.transientRejects
            metrics["playObservedPartialWrite"] = lane.observedPartialWrite
            metrics["playObservedRingFull"] = lane.observedRingFull
            metrics["playRemainderRetryAccepted"] = lane.remainderRetryAccepted
            metrics["playStarvationObserved"] = starvationObserved
            metrics["playStarvedPositionFrame"] = starvedPositionFrame
            metrics["playStarvedUnderrunCount"] = starvedUnderrunCount
            metrics["playFinalUnderrunCount"] = final.underrunCount
            metrics["playBackpressureCount"] = final.backpressureCount
            metrics["playKotlinChecksumHex"] = kotlinHex
            metrics["playPushedChecksumHex"] = final.pushedChecksumHex
            metrics["playDrainedChecksumHex"] = final.drainedChecksumHex
            metrics["playCodecChunks"] = codecChunks
            metrics["playDecodedFramesTotal"] = decodedFramesTotal
            metrics["playLastError"] = final.lastError
        } finally {
            sm.dispose()
            activeMachine = null
        }
    }

    // ── Seek session ───────────────────────────────────────────────────────

    private fun runSeekSession(
        sessionConfig: VanguardRealtimePlaybackNativeSession.Config,
        seekTargetFrame: Long,
        preSeekFrames: Long,
    ) {
        // Decoder back to the stream start (same seek discipline, origin 0).
        // The playthrough left the extractor at or near EOS; if Android
        // answers the re-seat with sampleTime == -1 the pair is reopened.
        val restartLandedUs = reseekDecoder(0L, streamStart = true)
        metrics["seekRestartLandedUs"] = restartLandedUs
        metrics["seekMediaReopens"] = mediaReopens
        val chunksBefore = codecChunks
        discardedPreTargetFrames = 0L
        seekGapObservedFrames = 0L

        val sm = VanguardRealtimePlaybackTransportStateMachine(sessionConfig, threadName = "Y5bSeek")
        activeMachine = sm
        val lane = Lane("seek", sm)
        var disposeOk = false
        try {
            requireAccepted(lane, "load", sm.load())
            requireAccepted(lane, "prepare", sm.prepare())
            lane.generation = sm.currentGeneration
            // Exactly preSeekFrames (whole windows) so the worker can render
            // everything and the source ring is provably empty at the seek.
            feedUntil(lane, preSeekFrames, stopOnRingFull = true)
            val startRes = requireAccepted(lane, "start", sm.start())
            if (startRes.state != State.PLAYING) throw FailClosed("seek_start_state:${startRes.state}")
            lane.generation = sm.currentGeneration
            feedUntil(lane, preSeekFrames)
            if (lane.anchor != preSeekFrames) throw FailClosed("seek_preseek_anchor:${lane.anchor}")

            // Wait until every pre-seek frame was rendered (cursor parked at
            // preSeekFrames, then a nonterminal underrun follows).
            val renderDeadline = SystemClock.elapsedRealtime() + RENDER_WAIT_MS
            var parked: Reply? = null
            while (SystemClock.elapsedRealtime() < renderDeadline) {
                checkDeadlineAndCancel()
                drainOutput(lane, DRAIN_WINDOWS_PER_POLL)
                val snap = snapshot(lane)
                if (snap.positionFrame == preSeekFrames && snap.pushedFrames == preSeekFrames) {
                    parked = snap
                    break
                }
                if (sm.currentState != State.PLAYING) throw FailClosed("seek_preseek_state:${sm.currentState}")
                sleepPoll()
            }
            val parkedSnap = parked ?: throw FailClosed("seek_preseek_render_timeout:${lane.lastReply?.positionFrame}")

            val pauseRes = requireAccepted(lane, "pause", sm.pause())
            if (pauseRes.state != State.PAUSED) throw FailClosed("seek_pause_state:${pauseRes.state}")
            drainUntilEmpty(lane)
            val quiesced = snapshot(lane)
            if (quiesced.drainedFrames != preSeekFrames || quiesced.pushedFrames != preSeekFrames ||
                quiesced.positionFrame != preSeekFrames || quiesced.discardedFrames != 0L
            ) {
                throw FailClosed("seek_quiesce_accounting:${quiesced.pushedFrames}:${quiesced.drainedFrames}:${quiesced.discardedFrames}")
            }

            // Transport seek first (writer re-anchors to the target under the
            // command gate), then the decoder follows.
            val staleGeneration = sm.currentGeneration
            val seekRes = requireAccepted(lane, "seek", sm.seek(seekTargetFrame))
            val newGeneration = sm.currentGeneration
            val seekAccepted = seekRes.state == State.PAUSED && newGeneration != staleGeneration
            if (!seekAccepted) throw FailClosed("seek_transport_state:${seekRes.state}:$staleGeneration:$newGeneration")
            lane.anchor = seekTargetFrame
            lane.generation = newGeneration
            lane.lastStatus = ""
            lane.remainderPendingAfterBackpressure = false
            val seekTargetUs = (seekTargetFrame * 1_000_000L + sampleRate - 1) / sampleRate
            val landedUs = reseekDecoder(seekTargetUs, streamStart = false)
            metrics["seekLandedUs"] = landedUs
            metrics["seekTargetUs"] = seekTargetUs
            metrics["seekMediaReopens"] = mediaReopens

            // Stale pre-seek generation: rejected before JNI (reply == null),
            // and the anchor is untouched (the pinned pre-roll below lands
            // with a full accept at the target).
            val probe = directBuffer(maxFramesPerMix)
            val stale = pinnedIngest(lane, probe, maxFramesPerMix, generation = staleGeneration)
            val staleRejected = !stale.accepted &&
                stale.reason == VanguardRealtimePlaybackTransportStateMachine.REASON_STALE_GENERATION &&
                stale.reply == null
            metrics["seekStaleReason"] = stale.reason
            metrics["seekStaleReplyNull"] = stale.reply == null

            // Post-seek pre-roll: >= maxFramesPerMix frames at the new anchor
            // while still PAUSED.
            val prerollLimit = minOf(seekTargetFrame + POST_SEEK_PREROLL_WINDOWS.toLong() * maxFramesPerMix, declaredFrameCount)
            val acceptedBeforePreroll = lane.acceptedFrames
            val callsBeforePreroll = lane.ingestCalls
            feedUntil(lane, prerollLimit, discardCounter = true)
            val prerollFrames = lane.acceptedFrames - acceptedBeforePreroll
            val firstPostSeekFullAccept = lane.ingestCalls > callsBeforePreroll && prerollFrames > 0L
            if (prerollFrames < maxFramesPerMix) throw FailClosed("seek_preroll_short:$prerollFrames")
            metrics["seekPostSeekPrerollFrames"] = prerollFrames
            metrics["seekPostSeekPrerollGapPaddedFrames"] = lane.gapPaddedFrames
            metrics["seekDiscardedPreTargetFrames"] = discardedPreTargetFrames
            metrics["seekFirstDecodedPtsUs"] = firstPostSeekPtsUs
            metrics["seekFirstDecodedFrame"] = firstPostSeekFrame

            val resumeRes = requireAccepted(lane, "resume", sm.resume())
            if (resumeRes.state != State.PLAYING) throw FailClosed("seek_resume_state:${resumeRes.state}")
            if (sm.currentGeneration != newGeneration) throw FailClosed("seek_resume_generation_moved")

            feedUntil(lane, declaredFrameCount, discardCounter = true)
            lane.truncatedFrames = stagedFrames.toLong()
            clearStaged()
            val final = awaitCompletion(lane)

            val expectedPushed = preSeekFrames + (declaredFrameCount - seekTargetFrame)
            val postSeekAccepted = lane.acceptedFrames - preSeekFrames
            // Real decoded post-seek audio = accepted minus gap padding and
            // EOS padding; the seek proof requires at least one such frame.
            val postSeekDecodedAccepted = postSeekAccepted - lane.gapPaddedFrames - lane.paddedFrames
            val kotlinHex = lane.checksumHex()
            val completed = sm.currentState == State.COMPLETED && final.state == NativeState.COMPLETED &&
                final.positionFrame == declaredFrameCount && final.eosDrained && final.eosPushed &&
                final.pushedFrames == expectedPushed && final.drainedFrames == expectedPushed &&
                final.discardedFrames == 0L && final.lastError == "none"
            val checksumsOk = kotlinHex == final.pushedChecksumHex && kotlinHex == final.drainedChecksumHex
            // Gap policy accounting: every observed gap frame was padded, the
            // total stays inside the bound, and a padded gap ends exactly at
            // the decoder-reported first post-seek frame.
            val gapPolicyOk = lane.gapPaddedFrames == seekGapObservedFrames &&
                lane.gapPaddedFrames <= maxSeekGapFrames() &&
                (lane.gapPaddedFrames == 0L || firstPostSeekFrame == seekTargetFrame + lane.gapPaddedFrames)
            val accountingOk = lane.anchor == declaredFrameCount &&
                postSeekAccepted == declaredFrameCount - seekTargetFrame &&
                postSeekDecodedAccepted > 0L && gapPolicyOk &&
                lane.paddedFrames <= (MAX_EOS_DRIFT_SEC * sampleRate).toLong()

            lanes[LANE_SEEK_REANCHOR] = seekAccepted && completed && checksumsOk && accountingOk &&
                parkedSnap.positionFrame == preSeekFrames && codecChunks > chunksBefore
            lanes[LANE_STALE_GENERATION_REJECTED] = staleRejected && firstPostSeekFullAccept && completed

            metrics["seekFinalState"] = sm.currentState.name
            metrics["seekNativeState"] = final.stateToken
            metrics["seekStaleGeneration"] = staleGeneration
            metrics["seekNewGeneration"] = newGeneration
            metrics["seekParkedUnderrunCount"] = parkedSnap.underrunCount
            metrics["seekPositionFrame"] = final.positionFrame
            metrics["seekExpectedPushedFrames"] = expectedPushed
            metrics["seekPushedFrames"] = final.pushedFrames
            metrics["seekDrainedFrames"] = final.drainedFrames
            metrics["seekDiscardedFrames"] = final.discardedFrames
            metrics["seekPostSeekAcceptedFrames"] = postSeekAccepted
            metrics["seekPostSeekDecodedAcceptedFrames"] = postSeekDecodedAccepted
            metrics["seekGapObservedFrames"] = seekGapObservedFrames
            metrics["seekGapPaddedFrames"] = lane.gapPaddedFrames
            metrics["seekGapPolicyOk"] = gapPolicyOk
            metrics["seekMaxGapFrames"] = maxSeekGapFrames()
            metrics["seekPaddedFrames"] = lane.paddedFrames
            metrics["seekTruncatedFrames"] = lane.truncatedFrames
            metrics["seekIngestCalls"] = lane.ingestCalls
            metrics["seekDrainCalls"] = lane.drainCalls
            metrics["seekTransientRejects"] = lane.transientRejects
            metrics["seekFinalUnderrunCount"] = final.underrunCount
            metrics["seekKotlinChecksumHex"] = kotlinHex
            metrics["seekPushedChecksumHex"] = final.pushedChecksumHex
            metrics["seekDrainedChecksumHex"] = final.drainedChecksumHex
            metrics["seekLastError"] = final.lastError

            // Lifecycle: explicit dispose, later ingest rejected as disposed,
            // second dispose is a no-op, media resources release cleanly.
            sm.dispose()
            val afterDispose = sm.ingest(IngestRequest(EXTERNAL_TRACK_INDEX, probe, maxFramesPerMix, lane.anchor))
            val postAfterDispose = sm.postIngest(IngestRequest(EXTERNAL_TRACK_INDEX, probe, maxFramesPerMix, lane.anchor))
            sm.dispose()
            releaseMedia()
            disposeOk = sm.currentState == State.DISPOSED && !afterDispose.accepted &&
                afterDispose.reason == VanguardRealtimePlaybackTransportStateMachine.REASON_DISPOSED &&
                !postAfterDispose && mediaReleaseClean
            metrics["disposeState"] = sm.currentState.name
            metrics["disposeIngestReason"] = afterDispose.reason
            metrics["disposePostIngestPosted"] = postAfterDispose
            metrics["disposeMediaReleaseClean"] = mediaReleaseClean
            lanes[LANE_LIFECYCLE_DISPOSE] = disposeOk
        } finally {
            sm.dispose()
            activeMachine = null
        }
    }

    // ── Teardown ───────────────────────────────────────────────────────────

    // Idempotent final codec/extractor release; records whether every
    // release step (including any intermediate reopen release) completed
    // without throwing.
    private fun releaseMedia() {
        if (!mediaReleased.compareAndSet(false, true)) return
        val clean = releaseMediaObjects()
        clearStaged()
        mediaReleaseClean = clean && intermediateReleasesClean
    }

    // Releases whatever extractor/codec pair currently exists (fields are
    // nulled first so a throwing release is never retried on a dead
    // object). Returns false if any step threw.
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

    private fun teardown() {
        try {
            activeMachine?.dispose()
        } catch (_: Throwable) {
        }
        activeMachine = null
        releaseMedia()
    }

    // ── Result assembly ────────────────────────────────────────────────────

    private fun firstFailedLane(): String = REQUIRED_LANES.firstOrNull { lanes[it] != true } ?: "none"

    private fun buildResult(pass: Boolean, failureReason: String): Result {
        val laneMap = linkedMapOf<String, Boolean>()
        for (lane in REQUIRED_LANES) laneMap[lane] = pass || (lanes[lane] == true)
        laneMap[LANE_PROOF_BOUNDARY] = true
        laneMap[LANE_CANONICAL] = pass
        val status = if (pass) "pass" else "fail"
        val metricMap = LinkedHashMap<String, Any?>(metrics)
        metricMap["failureReason"] = failureReason
        metricMap["cancelled"] = cancelled.get()
        return Result(
            pass = pass,
            status = status,
            failureReason = failureReason,
            proofBoundary = PROOF_BOUNDARY,
            lanes = laneMap,
            metrics = metricMap,
            raw = "pass=$pass;status=$status;failureReason=$failureReason",
        )
    }
}
