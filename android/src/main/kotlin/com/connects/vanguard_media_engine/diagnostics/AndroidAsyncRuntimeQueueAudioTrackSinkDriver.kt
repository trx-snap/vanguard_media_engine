package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.SystemClock
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidAsyncRuntimeQueueAudioTrackSinkDriver (P4 True-DAG sub-slice X2,
// P4-AUDIO-ASYNC-RUNTIME-QUEUE-AUDIOTRACK-SINK) ─────────────────────────────
//
// Kotlin-owned real MediaExtractor/MediaCodec SYNCHRONOUS streaming decode
// feeding the verified async runtime queue scheduler native session (same
// lanes and phase orchestration as the committed X1 driver,
// AndroidAsyncRuntimeQueueRealDecoderDriver, which stays untouched), with
// the output ring now drained into a MUTED android.media.AudioTrack
// MODE_STREAM sink through
// [AndroidAsyncRuntimeQueueAudioTrackSinkNativeSession]. The NATIVE WORKER
// thread inside the session remains the sole caller of the AudioClock
// mutators, the ClockedAudioTransportCoordinator control/dispatch path, and
// the output-ring producer role; Kotlin owns the MediaExtractor/MediaCodec
// lifecycle, the AudioTrack lifecycle and every write, the output-ring
// reads, playback-head/timestamp telemetry, deadlines, and cleanup.
//
// Sink contract (the X2 addition on top of the X1 proof shape):
//   - Every destructive output read lands in one driver-owned direct
//     buffer; the session invokes the sink callback BEFORE any further
//     native call, and the callback fully checksums + writes the frames to
//     the AudioTrack (AudioTrack.WRITE_NON_BLOCKING only; partial writes
//     compacted and retried; zero writes parked under a bounded budget) or
//     throws. No new destructive native output read can therefore ever run
//     while unwritten staged residual frames exist.
//   - Lossless sink accounting gate: framesWrittenToSink +
//     residualFramesAtEnd(0) == totalOutputFramesRead == expectedFrames.
//   - Seek ordering: zero staged residual asserted; epoch-0 sink facts
//     captured (framesDiscardedInSinkAtSeek = framesWrittenBeforeSeek -
//     playbackHeadAtSeek, excluded from every checksum/identity claim);
//     AudioTrack pause() + flush(); native forward seek only at quiescence;
//     output ack consumed via the ack-only (maxFrames == 0) read; playback
//     head / timestamp / underrun baselines reset; re-preroll; play();
//     writes continue.
//   - AudioTrack is muted (setVolume(0.0f)) before any play/write proof.
//     Playback head reads use unsigned 32-bit masking. underrunCount and
//     AudioTimestamp are TELEMETRY ONLY and never gate the verdict; the
//     playback head gates only the X2 head-progression lane and bounded
//     sink write pacing, never the native/product media clock (the worker
//     stays on the caller-derived accepted-frame axis).
//   - Fail closed on wrong-owner, queue_full/non-enqueued commands,
//     non-quiescent seek, every negative AudioTrack write status including
//     ERROR_DEAD_OBJECT, state/playState mismatch, and deadline exceeded.
//     No recovery loop beyond bounded diagnostic cleanup.
//
// Honest non-claims: see [PROOF_BOUNDARY]. Diagnostic foundation only — no
// product/editor/app playback, no audible output, no export route, no
// streaming/cache, no iOS, zero C++ primitive changes.
class AndroidAsyncRuntimeQueueAudioTrackSinkDriver {

    companion object {
        const val PASS_MARKER =
            "ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_SINK_SMOKE_PASS"
        const val FAIL_MARKER =
            "ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_AUDIOTRACK_SINK_SMOKE_FAIL"
        const val PROOF_BOUNDARY =
            "kotlin_owned_muted_audiotrack_sink_on_async_runtime_queue_diagnostic_proof_only_real_decoder_to_async_runtime_queue_scheduler_output_ring_to_muted_audiotrack_mode_stream_write_accounting_worker_owned_clock_and_coordinator_kotlin_owned_audiotrack_lifecycle_writes_reads_telemetry_deadlines_cleanup_write_non_blocking_only_playback_head_and_audio_timestamp_diagnostic_telemetry_and_bounded_sink_write_gating_only_never_native_or_product_media_clock_no_audible_output_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_realtime_rate_claim_no_fleet_claim_no_product_editor_app_wiring_no_export_route_no_streaming_cache_no_ios_no_cpp_primitive_changes"

        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val HARD_MAX_DURATION_SEC = 2.0
        // Media-supply safety margins between the decode window bounds and
        // the frozen frame budgets (decoder priming/trim tolerance).
        private const val PRE_SEEK_SUPPLY_MARGIN_SEC = 0.05
        private const val POST_SEEK_SUPPLY_MARGIN_SEC = 0.10

        // Matches the native per-call ingest clamp (AudioDecoderRingWriter
        // kMaxWriteFrames).
        private const val SCRATCH_FRAMES = 8192

        // Frozen per-epoch pre-roll floor in mix windows; the effective
        // quota is aligned with the track's MODE_STREAM start threshold
        // (see alignPrerollWithStartThreshold). The track buffer floor
        // keeps one full output-ring drain writable pre-play.
        private const val PREROLL_WINDOWS = 4L
        private const val TRACK_BUFFER_MARGIN_WINDOWS = 4L

        private const val MAX_CONSECUTIVE_ZERO_WRITES = 500
        private const val ZERO_WRITE_SLEEP_MS = 2L
        private const val HEAD_POLL_SLEEP_MS = 5L
        private const val HEAD_PROGRESS_WAIT_MS = 3_000L

        // Stable failure-shaped result (same lane/metric key shape) for a
        // caller that never got a run.
        fun failedResult(reason: String): RunResult =
            AndroidAsyncRuntimeQueueAudioTrackSinkDriver()
                .makeResult(pass = false, failureReason = reason)
    }

    data class RunConfig(
        val sourcePath: String,
        val durationSec: Double = 1.0,
        val seekTargetSec: Double = 0.35,
        val preSeekBudgetSec: Double = 0.25,
        val postSeekBudgetSec: Double = 0.30,
        val sourceRingCapacityFrames: Int = 2048,
        val outputRingCapacityFrames: Int = 1024,
        val maxFramesPerMix: Int = 256,
        val deadlineMs: Long = 30_000L,
    )

    // Lanes/metrics are flat maps so the coordinator payload and the
    // failure default shape stay identical by construction.
    data class RunResult(
        val pass: Boolean,
        val status: String,
        val marker: String,
        val proofBoundary: String,
        val failureReason: String,
        val details: String,
        val lanes: Map<String, Any?>,
        val metrics: Map<String, Any?>,
    )

    private class FailClosed(val reason: String) : Exception(reason)

    private var config = RunConfig(sourcePath = "")
    private var deadline = 0L
    private var mfpm = 0L
    private var runThreadId = -1L
    private var session: AndroidAsyncRuntimeQueueAudioTrackSinkNativeSession? = null

    // ── Format / budget facts ───────────────────────────────────────────────
    private var sampleRate = 0
    private var channelCount = 0
    private var pcmEncoding = 0
    private var bytesPerFrame = 0
    private var preSeekFrames = 0L
    private var postSeekFrames = 0L
    private var seekTargetFrame = -1L
    private var totalFramesExtracted = 0L
    private var framesTruncatedAtSeekBoundary = 0L
    private var framesDiscardedAfterBudget = 0L
    private var decoderBenignFormatChangeCount = 0L

    // ── AudioTrack sink state ───────────────────────────────────────────────
    private var audioTrack: AudioTrack? = null
    private var audioTrackReleaseCount = 0
    private var sinkReadBuf: ByteBuffer? = null
    private var bufferSizeInFrames = 0L
    private var startThresholdFrames = -1L
    private var prerollFrames = 0L

    // ── Sink epoch state: one epoch per AudioTrack write span ([start..seek]
    // and [seek..eos]); the seek pause/flush opens a new epoch with a
    // re-read head baseline and fresh underrun/timestamp baselines ──────────
    private var epochFramesWritten = 0L
    private var epochPlayed = false
    private var epochHeadBaseline = 0L
    private var epochUnderrunBaseline = -1L

    // ── Sink totals & telemetry ─────────────────────────────────────────────
    private var stagedResidualFrames = 0L
    private var framesReadFromRingTotal = 0L
    private var framesWrittenToSinkTotal = 0L
    private var kotlinSinkChecksum = 0L
    private var zeroWriteCount = 0L
    private var partialWriteCount = 0L
    private var framesWrittenBeforeSeek = -1L
    private var playbackHeadAtSeek = -1L
    private var framesDiscardedInSinkAtSeek = -1L
    private var playbackHeadFinal = -1L
    private var underrunBaselineFirst = -1L
    private var underrunFinalLast = -1L
    private var underrunDeltaTotal = 0L
    private var audioTimestampAttemptCount = 0L
    private var audioTimestampSuccessCount = 0L
    private val audioTimestamp = AudioTimestamp()

    // ── Lanes (fail-closed paths still report everything observed) ──────────
    private var formatProbeOk = false
    private var decoderEosReachedOk = false
    private var asyncWorkerOwnershipOk = false
    private var controlCommandSerializationOk = false
    private var realDecoderIngestOk = false
    private var sourceBackpressureRetryOk = false
    private var outputBackpressureOk = false
    private var checksumIdentityOk = false
    private var frameAccountingOk = false
    private var seekEpochReanchorOk = false
    private var noOwnerThreadDispatchOk = false
    private var foreignThreadRejectedOk = false
    private var workerJoinOnDestroyOk = false
    private var idempotentDestroyOk = false
    private var canonicalProofBoundaryOk = false
    private var audioTrackInitOk = false
    private var mutedOutputOk = false
    private var sinkWriteAccountingOk = false
    private var playbackHeadProgressionOk = false
    private var seekSinkEpochResetOk = false
    private var ownerThreadAffinityOk = false
    private val detailParts = mutableListOf<String>()

    fun run(runConfig: RunConfig): RunResult {
        config = runConfig
        deadline = SystemClock.elapsedRealtime() + config.deadlineMs
        mfpm = config.maxFramesPerMix.toLong()
        runThreadId = Thread.currentThread().id
        val s = AndroidAsyncRuntimeQueueAudioTrackSinkNativeSession(deadline) { frames ->
            onOutputFramesRead(frames)
        }
        session = s
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null

        try {
            if (config.sourcePath.isBlank()) throw FailClosed("source_path_required")
            val windowSec = minOf(config.durationSec, HARD_MAX_DURATION_SEC)
            if (windowSec <= 0.0) throw FailClosed("invalid_decode_duration")
            if (config.seekTargetSec <= 0.0 || config.seekTargetSec >= windowSec) {
                throw FailClosed("invalid_seek_target")
            }
            // The frozen budgets must sit safely inside the actual media
            // decoded per phase (priming/trim tolerance).
            if (config.preSeekBudgetSec <= 0.0 ||
                config.preSeekBudgetSec >
                config.seekTargetSec - PRE_SEEK_SUPPLY_MARGIN_SEC
            ) {
                throw FailClosed("invalid_pre_seek_budget")
            }
            if (config.postSeekBudgetSec <= 0.0 ||
                config.postSeekBudgetSec >
                windowSec - config.seekTargetSec - POST_SEEK_SUPPLY_MARGIN_SEC
            ) {
                throw FailClosed("invalid_post_seek_budget")
            }
            val windowUs = (windowSec * 1_000_000.0).toLong()
            val seekTargetUs = (config.seekTargetSec * 1_000_000.0).toLong()

            extractor.setDataSource(config.sourcePath)
            var audioTrackIndex = -1
            var trackFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                if (format.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    audioTrackIndex = i
                    trackFormat = format
                    break
                }
            }
            if (audioTrackIndex < 0 || trackFormat == null) throw FailClosed("no_audio_track")
            extractor.selectTrack(audioTrackIndex)

            val mime = trackFormat.getString(MediaFormat.KEY_MIME)
                ?: throw FailClosed("audio_track_mime_missing")
            val dec = MediaCodec.createDecoderByType(mime)
            codec = dec
            dec.configure(trackFormat, null, null, 0)
            dec.start()

            var scratch: ByteBuffer? = null
            var expectedFrames = 0L
            var phaseATargetFrames = 0L
            var sourceLaneStarted = false
            var sourceLaneDone = false

            // Reads the current decoder output format; a missing
            // KEY_PCM_ENCODING means ENCODING_PCM_16BIT.
            fun readOutputFormat(): Triple<Int, Int, Int> {
                val f = dec.outputFormat
                val sr = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                val ch = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                val enc = if (f.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                    f.getInteger(MediaFormat.KEY_PCM_ENCODING)
                } else {
                    AudioFormat.ENCODING_PCM_16BIT
                }
                return Triple(sr, ch, enc)
            }

            // First format resolution: validates PCM16 + 1-2 channels,
            // freezes the window-aligned frame budgets from the REAL sample
            // rate, creates the muted AudioTrack sink and the driver-owned
            // direct read buffer, then creates + starts the async native
            // session (worker boots here) and opens sink epoch 0.
            fun establishSession() {
                val (sr, ch, enc) = readOutputFormat()
                if (enc != AudioFormat.ENCODING_PCM_16BIT) {
                    throw FailClosed("unsupported_pcm_encoding:$enc")
                }
                if (ch != 1 && ch != 2) throw FailClosed("unsupported_channel_count:$ch")
                if (sr < 8000 || sr > 192000) throw FailClosed("invalid_sample_rate:$sr")
                sampleRate = sr
                channelCount = ch
                pcmEncoding = enc
                bytesPerFrame = 2 * ch
                preSeekFrames =
                    (config.preSeekBudgetSec * sr).toLong() / mfpm * mfpm
                postSeekFrames =
                    (config.postSeekBudgetSec * sr).toLong() / mfpm * mfpm
                // The pre-seek budget must fit both deterministic
                // backpressure lanes before the seek boundary.
                if (preSeekFrames <
                    config.sourceRingCapacityFrames.toLong() +
                    config.outputRingCapacityFrames.toLong() + 4L * mfpm
                ) {
                    throw FailClosed("pre_seek_budget_too_small_for_lanes")
                }
                if (postSeekFrames < 2L * mfpm) {
                    throw FailClosed("post_seek_budget_too_small")
                }
                expectedFrames = preSeekFrames + postSeekFrames
                phaseATargetFrames =
                    config.outputRingCapacityFrames.toLong() + 2L * mfpm
                createMutedAudioTrack(sr, ch)
                val readBuf = ByteBuffer
                    .allocateDirect(config.outputRingCapacityFrames * bytesPerFrame)
                    .order(ByteOrder.LITTLE_ENDIAN)
                sinkReadBuf = readBuf
                s.create(
                    sr, ch, expectedFrames,
                    config.sourceRingCapacityFrames,
                    config.outputRingCapacityFrames,
                    config.maxFramesPerMix,
                    readBuf,
                )
                s.startAndConsumeAck()
                openSinkEpoch()
                scratch = ByteBuffer.allocateDirect(SCRATCH_FRAMES * bytesPerFrame)
                    .order(ByteOrder.LITTLE_ENDIAN)
                formatProbeOk = true
            }

            // Once the session format is established, a repeated format
            // change with identical sampleRate/channelCount/PCM encoding is
            // benign and counted; any difference is malignant (the
            // AudioTrack format is frozen).
            fun onOutputFormatChanged() {
                if (!s.isCreated) {
                    establishSession()
                    return
                }
                val (sr, ch, enc) = readOutputFormat()
                if (sr == sampleRate && ch == channelCount && enc == pcmEncoding) {
                    decoderBenignFormatChangeCount += 1
                } else {
                    throw FailClosed("malignant_format_change")
                }
            }

            // Phase-1 deterministic lane triggers, run only BETWEEN chunks
            // (never with decoded PCM held): first the no-drain output
            // backpressure verification, then the paused source-ring fill.
            fun preChunkLaneTriggers() {
                if (!s.outputBackpressureVerified &&
                    s.kotlinFramesAccepted >= phaseATargetFrames
                ) {
                    s.verifyOutputBackpressureAndEnableDrains()
                }
                if (s.outputBackpressureVerified && !sourceLaneStarted) {
                    // The paused fill must reach ring_full before the frozen
                    // pre-seek budget runs out; fail closed instead of
                    // wedging when an oversized codec chunk ate the margin.
                    if (preSeekFrames - s.kotlinFramesAccepted <
                        config.sourceRingCapacityFrames.toLong() + 2L * mfpm
                    ) {
                        throw FailClosed("insufficient_budget_for_source_lane")
                    }
                    sourceLaneStarted = true
                    s.pauseAtQuiescentBoundary()
                }
            }

            // One already-copied direct slice at byte offset 0. During the
            // paused fill the writer must reach ring_full; the rejected
            // remainder (compacted to offset 0) is then retried losslessly
            // after resume, so no committed decoded frame is ever dropped.
            fun ingestSlice(sliceBuf: ByteBuffer, sliceFrames: Int) {
                if (s.pausedFillActive) {
                    val remaining = s.ingestUntilRingFull(sliceBuf, sliceFrames)
                    if (s.sourceRingFullObserved) {
                        s.resumeAfterSourceBackpressure()
                        sourceLaneDone = true
                        if (remaining > 0) {
                            s.ingestChunkLossless(sliceBuf, remaining)
                        }
                    }
                } else {
                    s.ingestChunkLossless(sliceBuf, sliceFrames)
                }
            }

            // Streams decoder output into the async session. Phase 1 stops
            // exactly at the pre-seek budget (in-flight codec state is
            // discarded later by the post-seek flush); phase 2 ingests to
            // the total budget and then runs the codec out to output EOS,
            // discarding surplus with honest accounting.
            fun decodePhase(endUs: Long, phase1: Boolean) {
                val info = MediaCodec.BufferInfo()
                var inputDone = false
                while (true) {
                    checkDeadline()
                    val budgetEnd = if (phase1) preSeekFrames else expectedFrames
                    if (phase1 && s.isCreated &&
                        s.kotlinFramesAccepted >= budgetEnd
                    ) {
                        return
                    }
                    if (!inputDone) {
                        val inIdx = dec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                        if (inIdx >= 0) {
                            val inBuf = dec.getInputBuffer(inIdx)!!
                            val size = extractor.readSampleData(inBuf, 0)
                            if (size < 0 || extractor.sampleTime > endUs) {
                                dec.queueInputBuffer(
                                    inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                )
                                inputDone = true
                            } else {
                                dec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }
                    val outIdx = dec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                    when {
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> onOutputFormatChanged()
                        outIdx >= 0 -> {
                            val isEos =
                                (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                            if (info.size > 0) {
                                if (!s.isCreated) establishSession()
                                if (info.size % bytesPerFrame != 0) {
                                    dec.releaseOutputBuffer(outIdx, false)
                                    throw FailClosed("codec_chunk_shape_invalid:${info.size}")
                                }
                                val chunkFrames = info.size / bytesPerFrame
                                totalFramesExtracted += chunkFrames
                                // Re-read the phase budget here: the first
                                // chunk's establishSession() call above is
                                // what froze the budgets.
                                val budget =
                                    if (phase1) preSeekFrames else expectedFrames
                                val room = budget - s.kotlinFramesAccepted
                                val ingestFrames =
                                    minOf(chunkFrames.toLong(), maxOf(0L, room)).toInt()
                                val excess = chunkFrames - ingestFrames
                                if (excess > 0) {
                                    // Never-ingested decoded frames: honest
                                    // media-discontinuity accounting, kept
                                    // out of every identity claim.
                                    if (phase1) {
                                        framesTruncatedAtSeekBoundary += excess
                                    } else {
                                        framesDiscardedAfterBudget += excess
                                    }
                                }
                                if (ingestFrames > 0) {
                                    val sc = scratch!!
                                    val outBuf = dec.getOutputBuffer(outIdx)!!
                                    // Copy the committed leading frames into
                                    // direct slices (scratch first, bounded
                                    // temporaries only on overflow), all at
                                    // byte offset 0, BEFORE releasing the
                                    // codec output buffer; only then may any
                                    // JNI call run.
                                    val sliceCapBytes = sc.capacity()
                                    val slices = ArrayList<Pair<ByteBuffer, Int>>()
                                    var sliceOffset = info.offset
                                    var remainingBytes = ingestFrames * bytesPerFrame
                                    while (remainingBytes > 0) {
                                        val sliceBytes = minOf(remainingBytes, sliceCapBytes)
                                        val dst = if (slices.isEmpty()) {
                                            sc
                                        } else {
                                            ByteBuffer.allocateDirect(sliceBytes)
                                                .order(ByteOrder.LITTLE_ENDIAN)
                                        }
                                        outBuf.position(sliceOffset)
                                        outBuf.limit(sliceOffset + sliceBytes)
                                        dst.clear()
                                        dst.put(outBuf)
                                        slices.add(dst to sliceBytes / bytesPerFrame)
                                        sliceOffset += sliceBytes
                                        remainingBytes -= sliceBytes
                                    }
                                    dec.releaseOutputBuffer(outIdx, false)
                                    if (phase1) preChunkLaneTriggers()
                                    for ((sliceBuf, sliceFrames) in slices) {
                                        ingestSlice(sliceBuf, sliceFrames)
                                    }
                                } else {
                                    dec.releaseOutputBuffer(outIdx, false)
                                }
                            } else {
                                dec.releaseOutputBuffer(outIdx, false)
                            }
                            if (isEos) {
                                if (phase1) {
                                    if (s.isCreated &&
                                        s.kotlinFramesAccepted >= preSeekFrames
                                    ) {
                                        return
                                    }
                                    throw FailClosed("decoder_eos_before_pre_seek_budget")
                                }
                                if (s.kotlinFramesAccepted < expectedFrames) {
                                    throw FailClosed("decoder_eos_before_post_seek_budget")
                                }
                                decoderEosReachedOk = true
                                return
                            }
                        }
                        // INFO_TRY_AGAIN_LATER — the deadline bounds the wait.
                    }
                }
            }

            // ── Phase 1: pre-seek decode with both backpressure lanes ───────
            decodePhase(seekTargetUs, phase1 = true)
            if (!s.isCreated) throw FailClosed("no_decoder_output")
            if (!s.outputBackpressureVerified) {
                throw FailClosed("output_backpressure_lane_not_run")
            }
            if (s.pausedFillActive) {
                throw FailClosed("budget_reached_during_paused_fill")
            }
            if (!sourceLaneDone) throw FailClosed("source_backpressure_lane_not_run")
            outputBackpressureOk = true
            sourceBackpressureRetryOk = s.sourceRingFullObserved &&
                s.writerBackpressureRejects >= 1L

            // ── The one pre-EOS native seek at the aligned budget boundary,
            // with the AudioTrack sink paused + flushed at quiescence ────────
            val seekFrame = s.seekAtAcceptedAlignedBoundary { onSinkSeekBoundary() }
            if (seekFrame != preSeekFrames) throw FailClosed("seek_frame_budget_mismatch")
            seekTargetFrame = seekFrame
            seekEpochReanchorOk = s.seekReanchorOk
            // Sink epoch reset: fresh head/underrun/timestamp baselines and
            // zeroed epoch counters; the next drains re-preroll then play().
            openSinkEpoch()
            if (epochFramesWritten != 0L || stagedResidualFrames != 0L) {
                throw FailClosed("seek_sink_epoch_counters_not_reset")
            }
            seekSinkEpochResetOk = true
            detailParts.add("seekAcceptedFrame=$seekFrame")
            detailParts.add("framesDiscardedInSinkAtSeek=$framesDiscardedInSinkAtSeek")
            detailParts.add("post_seek_media_content_overlap_permitted")

            // Extractor seek stays media-local; PREVIOUS_SYNC may land early
            // and re-decode content already ingested pre-seek (non-claim
            // recorded above). flush() discards in-flight codec state.
            extractor.seekTo(seekTargetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val postSeekStartUs =
                extractor.sampleTime.let { if (it >= 0L) it else seekTargetUs }
            dec.flush()
            detailParts.add("postSeekStartUs=$postSeekStartUs")

            // ── Phase 2: post-seek decode to the total budget, then codec
            // EOS run-out ───────────────────────────────────────────────────
            decodePhase(postSeekStartUs + (windowUs - seekTargetUs), phase1 = false)

            // ── Exact timeline completion, then writer-local EOS ────────────
            s.completeTimelineAndSetEos()

            // ── Sink finalization: zero residual, head progression proof,
            // epoch-1 underrun telemetry ─────────────────────────────────────
            finalizeSinkAtEos()

            // ── Final snapshot + verdict lanes ──────────────────────────────
            s.finalSnapshot()
            detailParts.add("preSeekFrames=$preSeekFrames")
            detailParts.add("postSeekFrames=$postSeekFrames")
            detailParts.add("expectedFrames=$expectedFrames")
            detailParts.add(
                "framesTruncatedAtSeekBoundary=$framesTruncatedAtSeekBoundary"
            )
            detailParts.add(
                "framesDiscardedAfterBudget=$framesDiscardedAfterBudget"
            )
            detailParts.add("audioTrackUnderrunDeltaTelemetryOnly")

            asyncWorkerOwnershipOk = s.workerOwnershipAtBootOk &&
                s.snapWorkerThreadDistinct &&
                s.snapOwnerDispatchCalls == 0L &&
                s.snapWorkerDispatchAnomalies == 0L &&
                s.snapSchedulerErrorCount == 0L &&
                !s.snapTerminal
            if (!asyncWorkerOwnershipOk) throw FailClosed("async_worker_ownership_violated")

            controlCommandSerializationOk = s.snapCommandsEnqueued == 4L &&
                s.snapCommandsProcessed == 4L &&
                s.snapCommandErrors == 0L &&
                s.snapLastCommandSeq == 4L &&
                s.snapQueueDepth == 0L
            if (!controlCommandSerializationOk) {
                throw FailClosed("command_serialization_mismatch")
            }

            // Identity spans four checksums: Kotlin ingest side, native
            // accepted side, native output read side, and the Kotlin sink
            // side accumulated over exactly the frames handed to
            // AudioTrack.write. Sink frames discarded by the seek flush are
            // downstream of every checksum point and excluded by
            // construction.
            val kotlinChecksumHex = String.format("%016x", s.kotlinChecksum)
            val kotlinSinkHex = String.format("%016x", kotlinSinkChecksum)
            checksumIdentityOk =
                kotlinChecksumHex == s.nativeAcceptedChecksumHex &&
                kotlinChecksumHex == s.nativeOutputReadChecksumHex &&
                kotlinChecksumHex == kotlinSinkHex &&
                s.snapProviderFramesZeroFilled == 0L &&
                s.snapProviderUnderrunEvents == 0L &&
                s.snapSilenceCount == 0L
            if (!checksumIdentityOk) throw FailClosed("checksum_identity_mismatch")

            frameAccountingOk =
                s.totalFramesAccepted == expectedFrames &&
                    s.snapTotalFramesRendered == expectedFrames &&
                    s.snapTotalFramesPushed == expectedFrames &&
                    s.totalOutputFramesRead == expectedFrames &&
                    s.kotlinFramesAccepted == expectedFrames &&
                    s.snapProviderForwardSkipFrames == 0L &&
                    s.snapProviderRewindRejects == 0L
            if (!frameAccountingOk) throw FailClosed("frame_accounting_mismatch")

            // Lossless sink accounting gate: framesWrittenToSink +
            // residualFramesAtEnd(0) == totalOutputFramesRead ==
            // expectedFrames.
            sinkWriteAccountingOk = stagedResidualFrames == 0L &&
                framesWrittenToSinkTotal == framesReadFromRingTotal &&
                framesReadFromRingTotal == s.totalOutputFramesRead &&
                s.totalOutputFramesRead == expectedFrames &&
                framesDiscardedInSinkAtSeek >= 0L
            if (!sinkWriteAccountingOk) throw FailClosed("sink_write_accounting_mismatch")

            realDecoderIngestOk = s.totalFramesAccepted == expectedFrames &&
                totalFramesExtracted >= expectedFrames
            if (!realDecoderIngestOk) throw FailClosed("real_decoder_ingest_shortfall")

            noOwnerThreadDispatchOk = s.snapOwnerDispatchCalls == 0L &&
                s.snapWorkerThreadDistinct
            if (!noOwnerThreadDispatchOk) throw FailClosed("owner_thread_dispatch_observed")

            canonicalProofBoundaryOk = s.snapProofBoundary ==
                AndroidAsyncRuntimeQueueAudioTrackSinkNativeSession.NATIVE_PROOF_BOUNDARY
            if (!canonicalProofBoundaryOk) throw FailClosed("native_proof_boundary_mismatch")

            // ── Foreign-thread rejection probe at a quiescent point ─────────
            foreignThreadRejectedOk = s.probeForeignThreadRejected()
            if (!foreignThreadRejectedOk) throw FailClosed("foreign_thread_not_rejected")

            // ── Destroy: join-on-destroy + idempotence ──────────────────────
            val (joinOk, idempotentOk) = s.destroyAndVerifyLifecycle()
            workerJoinOnDestroyOk = joinOk
            if (!joinOk) throw FailClosed("worker_join_on_destroy_failed")
            idempotentDestroyOk = idempotentOk
            if (!idempotentOk) throw FailClosed("destroy_not_idempotent")

            // Every sink write and boundary callback asserted the single
            // run thread; native enforced owner-only entry points and
            // rejected the deliberate foreign probe.
            ownerThreadAffinityOk = true

            return makeResult(pass = true, failureReason = "")
        } catch (f: FailClosed) {
            return makeResult(pass = false, failureReason = f.reason)
        } catch (f: AndroidAsyncRuntimeQueueAudioTrackSinkNativeSession.Failure) {
            return makeResult(pass = false, failureReason = f.reason)
        } catch (e: Throwable) {
            return makeResult(
                pass = false,
                failureReason = "exception:${e.javaClass.simpleName}:${e.message}",
            )
        } finally {
            releaseAudioTrackOnce()
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
            s.cleanup()
        }
    }

    // ── Session output sink: read accounting + muted AudioTrack write ───────

    // Invoked by the session after every destructive output read with
    // [frames] freshly read PCM16 frames at byte offset 0 of the driver's
    // read buffer. Checksums FIRST (before any write mutates the buffer
    // layout), then stages + writes everything to the muted AudioTrack; the
    // session issues no further native call until this returns with zero
    // staged residual.
    private fun onOutputFramesRead(frames: Long) {
        assertOwnerThread("sink_read")
        val buf = sinkReadBuf ?: throw FailClosed("sink_read_before_create")
        val sampleCount = (frames * channelCount).toInt()
        var c = kotlinSinkChecksum
        for (i in 0 until sampleCount) {
            c = c * 31L + (buf.getShort(i * 2).toLong() and 0xFFFFL)
        }
        kotlinSinkChecksum = c
        framesReadFromRingTotal += frames
        stagedResidualFrames = frames
        writeAllToAudioTrack((frames * bytesPerFrame).toInt())
        if (stagedResidualFrames != 0L) throw FailClosed("sink_residual_after_write")
    }

    // Writes [bytes] bytes from offset 0 of the read buffer with
    // WRITE_NON_BLOCKING only, fail-closed on every negative status code
    // (including ERROR_DEAD_OBJECT — no recovery claim). Partial writes
    // compact/retain the unwritten remainder in the same buffer and retry;
    // zero writes park briefly under a bounded budget. The per-epoch
    // pre-roll gate opens play() from inside this loop once the quota is
    // written.
    private fun writeAllToAudioTrack(bytes: Int) {
        val track = audioTrack ?: throw FailClosed("audio_track_missing")
        val buf = sinkReadBuf!!
        buf.position(0)
        buf.limit(bytes)
        var consecutiveZero = 0
        while (buf.hasRemaining()) {
            checkDeadline()
            val requested = buf.remaining()
            val wrote = track.write(buf, requested, AudioTrack.WRITE_NON_BLOCKING)
            when {
                wrote > 0 -> {
                    consecutiveZero = 0
                    if (wrote % bytesPerFrame != 0) {
                        throw FailClosed("audio_track_write_frame_misaligned:$wrote")
                    }
                    val framesWritten = (wrote / bytesPerFrame).toLong()
                    epochFramesWritten += framesWritten
                    framesWrittenToSinkTotal += framesWritten
                    stagedResidualFrames -= framesWritten
                    if (wrote < requested) {
                        partialWriteCount++
                        buf.compact()
                        buf.flip()
                    }
                    playIfPrerolled()
                }
                wrote == 0 -> {
                    zeroWriteCount++
                    playIfPrerolled()
                    if (++consecutiveZero > MAX_CONSECUTIVE_ZERO_WRITES) {
                        throw FailClosed("audio_track_write_stalled")
                    }
                    Thread.sleep(ZERO_WRITE_SLEEP_MS)
                }
                wrote == AudioTrack.ERROR_INVALID_OPERATION ->
                    throw FailClosed("audio_track_invalid_operation")
                wrote == AudioTrack.ERROR_BAD_VALUE ->
                    throw FailClosed("audio_track_bad_value")
                wrote == AudioTrack.ERROR_DEAD_OBJECT ->
                    throw FailClosed("audio_track_dead_object")
                else -> throw FailClosed("audio_track_write_error:$wrote")
            }
        }
        buf.clear()
    }

    // ── AudioTrack lifecycle / pre-roll / seek epoch ────────────────────────

    private fun createMutedAudioTrack(sampleRate: Int, channelCount: Int) {
        val channelMask = if (channelCount == 1) {
            AudioFormat.CHANNEL_OUT_MONO
        } else {
            AudioFormat.CHANNEL_OUT_STEREO
        }
        val minBytes = AudioTrack.getMinBufferSize(
            sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBytes <= 0) throw FailClosed("audio_track_min_buffer_invalid:$minBytes")
        // The buffer floor keeps one full output-ring drain writable before
        // play() so the pre-roll write span can never stall.
        val floorBytes = ((config.outputRingCapacityFrames.toLong() +
            TRACK_BUFFER_MARGIN_WINDOWS * mfpm) * bytesPerFrame).toInt()
        // Rounded up to a whole mix window so a start-threshold-raised
        // pre-roll quota (a window multiple) always fits the buffer.
        val windowBytes = (mfpm * bytesPerFrame).toInt()
        val requestedBytes =
            ((maxOf(minBytes, floorBytes) + windowBytes - 1) / windowBytes) * windowBytes
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(channelMask)
                    .build()
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(requestedBytes)
            .build()
        audioTrack = track
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            throw FailClosed("audio_track_not_initialized")
        }
        // Muted-only boundary: this slice never runs with an audible gain.
        if (track.setVolume(0.0f) != AudioTrack.SUCCESS) {
            throw FailClosed("muted_volume_set_failed")
        }
        mutedOutputOk = true
        bufferSizeInFrames = track.bufferSizeInFrames.toLong()
        prerollFrames = PREROLL_WINDOWS * mfpm
        alignPrerollWithStartThreshold(track)
        audioTrackInitOk = true
    }

    // A MODE_STREAM AudioTrack does not start consuming until its buffer
    // holds the start threshold of frames, which defaults to the full
    // buffer capacity. On API 31+ the threshold is lowered to the pre-roll
    // quota; where that API is unavailable or the device refuses, the
    // per-run pre-roll quota is raised to the effective threshold instead,
    // fail-closed if it cannot fit the track buffer. No latency claim: this
    // only makes the muted diagnostic sink start at all under non-blocking
    // writes.
    private fun alignPrerollWithStartThreshold(track: AudioTrack) {
        var effectiveThreshold = bufferSizeInFrames
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            effectiveThreshold = try {
                track.setStartThresholdInFrames(
                    prerollFrames.coerceAtMost(bufferSizeInFrames).toInt()
                ).toLong()
            } catch (_: Throwable) {
                bufferSizeInFrames
            }
        }
        startThresholdFrames = effectiveThreshold
        val neededPreroll = maxOf(prerollFrames, effectiveThreshold)
        prerollFrames = ceilDiv(neededPreroll, mfpm) * mfpm
        if (prerollFrames > bufferSizeInFrames) {
            throw FailClosed(
                "preroll_exceeds_track_buffer:$prerollFrames:$bufferSizeInFrames"
            )
        }
    }

    // Per-epoch pre-roll gate: play() only after the aligned quota is
    // written this epoch; asserts PLAYSTATE_PLAYING and captures the
    // underrun telemetry baseline.
    private fun playIfPrerolled() {
        if (epochPlayed || epochFramesWritten < prerollFrames) return
        val track = audioTrack ?: throw FailClosed("audio_track_missing")
        track.play()
        if (track.playState != AudioTrack.PLAYSTATE_PLAYING) {
            throw FailClosed("audio_track_not_playing_after_play")
        }
        epochPlayed = true
        epochUnderrunBaseline = readUnderrunTelemetry()
        if (underrunBaselineFirst < 0L) underrunBaselineFirst = epochUnderrunBaseline
    }

    // Runs at the seek quiescent boundary (inside the session's seek, after
    // the full boundary drain, before the native seek is enqueued): zero
    // staged residual asserted, epoch-0 sink discard accounting captured
    // and excluded from identity, then AudioTrack pause() + flush().
    private fun onSinkSeekBoundary() {
        assertOwnerThread("seek_boundary")
        if (stagedResidualFrames != 0L) throw FailClosed("seek_with_staged_residual")
        if (!epochPlayed) throw FailClosed("seek_before_epoch_play")
        val track = audioTrack ?: throw FailClosed("audio_track_missing")
        sampleTimestampTelemetry()
        framesWrittenBeforeSeek = epochFramesWritten
        playbackHeadAtSeek = epochHeadProgress()
        framesDiscardedInSinkAtSeek = framesWrittenBeforeSeek - playbackHeadAtSeek
        if (framesDiscardedInSinkAtSeek < 0L) {
            throw FailClosed("seek_sink_discard_accounting_negative")
        }
        captureEpochUnderrunDelta("epoch0")
        track.pause()
        if (track.playState != AudioTrack.PLAYSTATE_PAUSED) {
            throw FailClosed("audio_track_not_paused_at_seek")
        }
        track.flush()
    }

    // Post-EOS sink finalization: zero staged residual, epoch-1 head
    // progression under a bounded wait (the write-accounting proof for the
    // X2 head lane; the head never becomes a media clock), epoch-1 underrun
    // telemetry.
    private fun finalizeSinkAtEos() {
        assertOwnerThread("sink_finalize")
        if (stagedResidualFrames != 0L) throw FailClosed("sink_residual_at_end")
        if (!epochPlayed) throw FailClosed("post_seek_epoch_never_played")
        sampleTimestampTelemetry()
        val waitDeadline = minOf(
            deadline, SystemClock.elapsedRealtime() + HEAD_PROGRESS_WAIT_MS
        )
        var progress = epochHeadProgress()
        while (progress <= 0L && SystemClock.elapsedRealtime() <= waitDeadline) {
            Thread.sleep(HEAD_POLL_SLEEP_MS)
            progress = epochHeadProgress()
        }
        playbackHeadFinal = progress
        playbackHeadProgressionOk = progress > 0L && playbackHeadAtSeek >= 0L
        if (!playbackHeadProgressionOk) throw FailClosed("playback_head_not_progressed")
        captureEpochUnderrunDelta("epoch1")
    }

    // Opens a sink write epoch: zeroed counters, fresh unsigned-masked head
    // baseline (re-read after any flush), cleared play/underrun baselines.
    private fun openSinkEpoch() {
        epochFramesWritten = 0L
        epochPlayed = false
        epochUnderrunBaseline = -1L
        epochHeadBaseline = readPlaybackHeadUnsigned()
    }

    private fun readPlaybackHeadUnsigned(): Long =
        (audioTrack ?: throw FailClosed("audio_track_missing"))
            .playbackHeadPosition.toLong() and 0xFFFF_FFFFL

    private fun epochHeadProgress(): Long {
        val progress = readPlaybackHeadUnsigned() - epochHeadBaseline
        if (progress < 0L) throw FailClosed("playback_head_regressed")
        return progress
    }

    // Device underrun TELEMETRY only: recorded per epoch, reported as-is,
    // never a verdict gate (HAL underrun freedom on this muted diagnostic
    // sink is a non-claim).
    private fun readUnderrunTelemetry(): Long = try {
        audioTrack?.underrunCount?.toLong() ?: -1L
    } catch (_: Throwable) {
        -1L
    }

    private fun captureEpochUnderrunDelta(label: String) {
        val finalCount = readUnderrunTelemetry()
        underrunFinalLast = finalCount
        val delta = if (finalCount >= 0L && epochUnderrunBaseline >= 0L) {
            finalCount - epochUnderrunBaseline
        } else {
            -1L
        }
        if (delta >= 0L) underrunDeltaTotal += delta
        detailParts.add("${label}UnderrunDelta=$delta")
    }

    // AudioTimestamp TELEMETRY only: attempt/success counters, never a
    // verdict gate.
    private fun sampleTimestampTelemetry() {
        val track = audioTrack ?: return
        audioTimestampAttemptCount++
        try {
            if (track.getTimestamp(audioTimestamp)) audioTimestampSuccessCount++
        } catch (_: Throwable) {}
    }

    private fun releaseAudioTrackOnce() {
        val track = audioTrack ?: return
        if (audioTrackReleaseCount > 0) return
        try { track.pause() } catch (_: Throwable) {}
        try { track.flush() } catch (_: Throwable) {}
        try { track.release() } catch (_: Throwable) {}
        audioTrackReleaseCount++
    }

    // ── Internals / result ──────────────────────────────────────────────────

    private fun ceilDiv(a: Long, b: Long): Long = (a + b - 1) / b

    private fun checkDeadline() {
        if (SystemClock.elapsedRealtime() > deadline) {
            throw FailClosed("deadline_exceeded")
        }
    }

    private fun assertOwnerThread(where: String) {
        if (Thread.currentThread().id != runThreadId) {
            throw FailClosed("owner_thread_affinity_violated_$where")
        }
    }

    private fun makeResult(pass: Boolean, failureReason: String): RunResult {
        val s = session
        val lanes = mapOf<String, Any?>(
            "formatProbeOk" to formatProbeOk,
            "decoderEosReachedOk" to decoderEosReachedOk,
            "asyncWorkerOwnershipOk" to asyncWorkerOwnershipOk,
            "controlCommandSerializationOk" to controlCommandSerializationOk,
            "realDecoderIngestOk" to realDecoderIngestOk,
            "sourceBackpressureRetryOk" to sourceBackpressureRetryOk,
            "outputBackpressureOk" to outputBackpressureOk,
            "checksumIdentityOk" to checksumIdentityOk,
            "frameAccountingOk" to frameAccountingOk,
            "seekEpochReanchorOk" to seekEpochReanchorOk,
            "noOwnerThreadDispatchOk" to noOwnerThreadDispatchOk,
            "foreignThreadRejectedOk" to foreignThreadRejectedOk,
            "workerJoinOnDestroyOk" to workerJoinOnDestroyOk,
            "idempotentDestroyOk" to idempotentDestroyOk,
            "canonicalProofBoundaryOk" to canonicalProofBoundaryOk,
            "audioTrackInitOk" to audioTrackInitOk,
            "mutedOutputOk" to mutedOutputOk,
            "sinkWriteAccountingOk" to sinkWriteAccountingOk,
            "playbackHeadProgressionOk" to playbackHeadProgressionOk,
            "seekSinkEpochResetOk" to seekSinkEpochResetOk,
            "ownerThreadAffinityOk" to ownerThreadAffinityOk,
        )
        val metrics = mapOf<String, Any?>(
            "sampleRate" to sampleRate,
            "channelCount" to channelCount,
            "pcmEncoding" to pcmEncoding,
            "expectedFrames" to (s?.expectedFrames ?: 0L),
            "preSeekFrames" to preSeekFrames,
            "postSeekFrames" to postSeekFrames,
            "seekTargetFrame" to seekTargetFrame,
            "totalFramesExtracted" to totalFramesExtracted,
            "totalFramesAccepted" to (s?.totalFramesAccepted ?: 0L),
            "totalFramesRendered" to (s?.snapTotalFramesRendered ?: -1L),
            "totalFramesPushed" to (s?.snapTotalFramesPushed ?: -1L),
            "totalOutputFramesRead" to (s?.totalOutputFramesRead ?: 0L),
            "framesReadFromRing" to framesReadFromRingTotal,
            "framesWrittenToSink" to framesWrittenToSinkTotal,
            "residualFramesAtEnd" to stagedResidualFrames,
            "framesWrittenBeforeSeek" to framesWrittenBeforeSeek,
            "playbackHeadAtSeek" to playbackHeadAtSeek,
            "framesDiscardedInSinkAtSeek" to framesDiscardedInSinkAtSeek,
            "playbackHeadFinal" to playbackHeadFinal,
            "framesTruncatedAtSeekBoundary" to framesTruncatedAtSeekBoundary,
            "framesDiscardedAfterBudget" to framesDiscardedAfterBudget,
            "decoderBenignFormatChangeCount" to decoderBenignFormatChangeCount,
            "commandsEnqueued" to (s?.snapCommandsEnqueued ?: -1L),
            "commandsProcessed" to (s?.snapCommandsProcessed ?: -1L),
            "commandErrors" to (s?.snapCommandErrors ?: -1L),
            "dispatchCount" to (s?.snapDispatchCount ?: -1L),
            "silenceCount" to (s?.snapSilenceCount ?: -1L),
            "backpressureCount" to (s?.snapBackpressureCount ?: -1L),
            "writerBackpressureRejects" to (s?.writerBackpressureRejects ?: -1L),
            "providerUnderrunEvents" to (s?.snapProviderUnderrunEvents ?: -1L),
            "providerFramesZeroFilled" to (s?.snapProviderFramesZeroFilled ?: -1L),
            "providerForwardSkipFrames" to (s?.snapProviderForwardSkipFrames ?: -1L),
            "providerRewindRejects" to (s?.snapProviderRewindRejects ?: -1L),
            "workerThreadDistinct" to (s?.snapWorkerThreadDistinct ?: false),
            "ownerDispatchCalls" to (s?.snapOwnerDispatchCalls ?: -1L),
            "kotlinAcceptedChecksumHex" to
                (s?.let { String.format("%016x", it.kotlinChecksum) } ?: ""),
            "kotlinSinkChecksumHex" to String.format("%016x", kotlinSinkChecksum),
            "nativeAcceptedChecksumHex" to (s?.nativeAcceptedChecksumHex ?: ""),
            "nativeOutputReadChecksumHex" to (s?.nativeOutputReadChecksumHex ?: ""),
            "maxFramesPerMix" to mfpm,
            "bufferSizeInFrames" to bufferSizeInFrames,
            "startThresholdFrames" to startThresholdFrames,
            "prerollFrames" to prerollFrames,
            "zeroWriteCount" to zeroWriteCount,
            "partialWriteCount" to partialWriteCount,
            "underrunBaseline" to underrunBaselineFirst,
            "underrunFinal" to underrunFinalLast,
            "underrunDelta" to underrunDeltaTotal,
            "audioTimestampAttemptCount" to audioTimestampAttemptCount,
            "audioTimestampSuccessCount" to audioTimestampSuccessCount,
            "audioTrackReleaseCount" to audioTrackReleaseCount.toLong(),
            "nativeLastStatus" to (s?.lastStatus ?: ""),
        )
        return RunResult(
            pass = pass,
            status = if (pass) "pass" else failureReason.substringBefore(':').ifBlank { "fail" },
            marker = if (pass) PASS_MARKER else FAIL_MARKER,
            proofBoundary = PROOF_BOUNDARY,
            failureReason = failureReason,
            details = detailParts.joinToString("|"),
            lanes = lanes,
            metrics = metrics,
        )
    }
}
