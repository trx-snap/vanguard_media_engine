package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidAsyncRuntimeQueueRealDecoderDriver (P4 True-DAG sub-slice X1) ─────
//
// Kotlin-owned real MediaExtractor/MediaCodec SYNCHRONOUS streaming decode of
// the first audio track (MIME audio/*) feeding the verified async runtime
// queue scheduler native session via
// [AndroidAsyncRuntimeQueueRealDecoderNativeSession]. The driver owns the
// MediaExtractor/MediaCodec lifecycle (synchronous dequeue only — never
// MediaCodec.setCallback async mode, preserving single-owner-thread
// affinity), the codec output copy/release policy, decoder format policy
// (benign repeat format changes counted, malignant changes fail closed), the
// watchdog deadline, and the phase orchestration; the session component owns
// every JNI interaction. The NATIVE WORKER thread inside the session is the
// sole caller of the AudioClock mutators, the coordinator control/dispatch,
// and the output-ring producer role.
//
// Proof shape, all on the single caller thread of [run] (except the
// deliberate foreign-thread probe that native must reject):
//   - Resolve the decoder output format first (PCM16, 1-2 channels only);
//     create + start the async native session lazily once the real sample
//     rate is known, freezing the exact expected timeline as window-aligned
//     pre/post-seek frame budgets derived from that sample rate.
//   - Every codec output chunk is copied to byte offset 0 of direct
//     ByteBuffers (hoisted scratch plus bounded temporaries for oversized
//     chunks) and the codec output buffer is released BEFORE any JNI
//     ingest/read/snapshot runs. Chunk frames beyond the frozen budgets are
//     NEVER ingested: they are counted honestly as truncated (pre-seek
//     boundary) or discarded (post-budget EOS run-out) and excluded from
//     every identity/accounting claim, exactly like the media-local
//     extractor-seek content discontinuity. Everything committed to the
//     proof stream is ingested losslessly (compacted partial retries).
//   - Output backpressure: reads are withheld until the worker wedges at
//     exactly the output ring capacity with a recorded backpressure probe.
//   - Source backpressure: a worker pause freezes dispatch so the source
//     ring fills to a deterministic ring_full writer reject; the rejected
//     window is retried losslessly after resume.
//   - The one native seek runs BEFORE any EOS, at the window-aligned
//     pre-seek budget boundary with quiescent rings, zero held decoded PCM,
//     targetFrame == acceptedFrame, and a cleanly consumed output ack. The
//     extractor seek stays media-local (PREVIOUS_SYNC may land early);
//     post-seek media content overlap is an explicit non-claim.
//   - The writer-local EOS is set only after the post-seek decode completed
//     the exact expected timeline, so provider zero-fill can never enter
//     the identity checksums.
//
// Honest non-claims: no AudioTrack/AAudio/OpenSL/Oboe, no audible output,
// no speaker route, no audio focus, no route change, no dead-object
// recovery, no latency/glitch/AV-sync claim, no product/editor/app wiring,
// no export route changes, no streaming/cache, no iOS. Native never owns
// MediaCodec/MediaExtractor, never does file IO, and never reads a wall
// clock as a media timebase.
class AndroidAsyncRuntimeQueueRealDecoderDriver {

    companion object {
        const val PASS_MARKER =
            "ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REAL_DECODER_SMOKE_PASS"
        const val FAIL_MARKER =
            "ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_REAL_DECODER_SMOKE_FAIL"
        const val PROOF_BOUNDARY =
            "kotlin_owned_real_decoder_to_async_runtime_queue_scheduler_proof_only_mediaextractor_mediacodec_sync_decode_owner_thread_to_native_async_worker_queue_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_media_time_worker_owned_clock_coordinator_output_ring_source_ring_spsc_caller_derived_accepted_frame_axis_ticks_only_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_audible_output_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_product_editor_app_wiring_no_export_route_changes_no_streaming_cache_no_ios_writer_local_eos_only_zero_fill_not_in_identity"

        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val HARD_MAX_DURATION_SEC = 2.0
        // Media-supply safety margins between the decode window bounds and
        // the frozen frame budgets (decoder priming/trim tolerance).
        private const val PRE_SEEK_SUPPLY_MARGIN_SEC = 0.05
        private const val POST_SEEK_SUPPLY_MARGIN_SEC = 0.10

        // Matches the native per-call ingest clamp (AudioDecoderRingWriter
        // kMaxWriteFrames).
        private const val SCRATCH_FRAMES = 8192
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

    data class RunResult(
        val pass: Boolean,
        val status: String,
        val marker: String,
        val proofBoundary: String,
        val failureReason: String,
        val details: String,
        // Lanes.
        val formatProbeOk: Boolean,
        val decoderEosReachedOk: Boolean,
        val asyncWorkerOwnershipOk: Boolean,
        val controlCommandSerializationOk: Boolean,
        val realDecoderIngestOk: Boolean,
        val sourceBackpressureRetryOk: Boolean,
        val outputBackpressureOk: Boolean,
        val checksumIdentityOk: Boolean,
        val frameAccountingOk: Boolean,
        val seekEpochReanchorOk: Boolean,
        val noOwnerThreadDispatchOk: Boolean,
        val foreignThreadRejectedOk: Boolean,
        val workerJoinOnDestroyOk: Boolean,
        val idempotentDestroyOk: Boolean,
        val canonicalProofBoundaryOk: Boolean,
        // Metrics.
        val sampleRate: Int,
        val channelCount: Int,
        val pcmEncoding: Int,
        val expectedFrames: Long,
        val preSeekFrames: Long,
        val postSeekFrames: Long,
        val seekTargetFrame: Long,
        val totalFramesExtracted: Long,
        val totalFramesAccepted: Long,
        val totalFramesRendered: Long,
        val totalFramesPushed: Long,
        val totalOutputFramesRead: Long,
        val framesTruncatedAtSeekBoundary: Long,
        val framesDiscardedAfterBudget: Long,
        val decoderBenignFormatChangeCount: Long,
        val commandsEnqueued: Long,
        val commandsProcessed: Long,
        val commandErrors: Long,
        val dispatchCount: Long,
        val silenceCount: Long,
        val backpressureCount: Long,
        val writerBackpressureRejects: Long,
        val providerUnderrunEvents: Long,
        val providerFramesZeroFilled: Long,
        val providerForwardSkipFrames: Long,
        val providerRewindRejects: Long,
        val workerThreadDistinct: Boolean,
        val ownerDispatchCalls: Long,
        val kotlinAcceptedChecksumHex: String,
        val nativeAcceptedChecksumHex: String,
        val nativeOutputReadChecksumHex: String,
        val maxFramesPerMix: Long,
        val nativeLastStatus: String,
    )

    private class FailClosed(val reason: String) : Exception(reason)

    // Mutable telemetry threaded through the run so fail-closed paths still
    // report everything observed up to the failure point.
    private class RunTelemetry {
        var formatProbeOk = false
        var decoderEosReachedOk = false
        var asyncWorkerOwnershipOk = false
        var controlCommandSerializationOk = false
        var realDecoderIngestOk = false
        var sourceBackpressureRetryOk = false
        var outputBackpressureOk = false
        var checksumIdentityOk = false
        var frameAccountingOk = false
        var seekEpochReanchorOk = false
        var noOwnerThreadDispatchOk = false
        var foreignThreadRejectedOk = false
        var workerJoinOnDestroyOk = false
        var idempotentDestroyOk = false
        var canonicalProofBoundaryOk = false

        var sampleRate = 0
        var channelCount = 0
        var pcmEncoding = 0
        var preSeekFrames = 0L
        var postSeekFrames = 0L
        var seekTargetFrame = -1L
        var totalFramesExtracted = 0L
        var framesTruncatedAtSeekBoundary = 0L
        var framesDiscardedAfterBudget = 0L
        var decoderBenignFormatChangeCount = 0L
        val detailParts = mutableListOf<String>()
    }

    fun run(config: RunConfig): RunResult {
        val t = RunTelemetry()
        val deadline = SystemClock.elapsedRealtime() + config.deadlineMs
        val session = AndroidAsyncRuntimeQueueRealDecoderNativeSession(deadline)
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
            val mfpm = config.maxFramesPerMix.toLong()

            fun checkDeadline() {
                if (SystemClock.elapsedRealtime() > deadline) throw FailClosed("deadline_exceeded")
            }

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

            var bytesPerFrame = 0
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
            // rate, creates + starts the async native session (worker boots
            // here), and hoists the one direct scratch buffer.
            fun establishSession() {
                val (sr, ch, enc) = readOutputFormat()
                if (enc != AudioFormat.ENCODING_PCM_16BIT) {
                    throw FailClosed("unsupported_pcm_encoding:$enc")
                }
                if (ch != 1 && ch != 2) throw FailClosed("unsupported_channel_count:$ch")
                if (sr < 8000 || sr > 192000) throw FailClosed("invalid_sample_rate:$sr")
                t.sampleRate = sr
                t.channelCount = ch
                t.pcmEncoding = enc
                bytesPerFrame = 2 * ch
                t.preSeekFrames =
                    (config.preSeekBudgetSec * sr).toLong() / mfpm * mfpm
                t.postSeekFrames =
                    (config.postSeekBudgetSec * sr).toLong() / mfpm * mfpm
                // The pre-seek budget must fit both deterministic
                // backpressure lanes before the seek boundary.
                if (t.preSeekFrames <
                    config.sourceRingCapacityFrames.toLong() +
                    config.outputRingCapacityFrames.toLong() + 4L * mfpm
                ) {
                    throw FailClosed("pre_seek_budget_too_small_for_lanes")
                }
                if (t.postSeekFrames < 2L * mfpm) {
                    throw FailClosed("post_seek_budget_too_small")
                }
                expectedFrames = t.preSeekFrames + t.postSeekFrames
                phaseATargetFrames =
                    config.outputRingCapacityFrames.toLong() + 2L * mfpm
                session.create(
                    sr, ch, expectedFrames,
                    config.sourceRingCapacityFrames,
                    config.outputRingCapacityFrames,
                    config.maxFramesPerMix,
                )
                session.startAndConsumeAck()
                scratch = ByteBuffer.allocateDirect(SCRATCH_FRAMES * bytesPerFrame)
                    .order(ByteOrder.LITTLE_ENDIAN)
                t.formatProbeOk = true
            }

            // Once the session format is established, a repeated format
            // change with identical sampleRate/channelCount/PCM encoding is
            // benign and counted; any difference is malignant.
            fun onOutputFormatChanged() {
                if (!session.isCreated) {
                    establishSession()
                    return
                }
                val (sr, ch, enc) = readOutputFormat()
                if (sr == t.sampleRate && ch == t.channelCount && enc == t.pcmEncoding) {
                    t.decoderBenignFormatChangeCount += 1
                } else {
                    throw FailClosed("malignant_format_change")
                }
            }

            // Phase-1 deterministic lane triggers, run only BETWEEN chunks
            // (never with decoded PCM held): first the no-drain output
            // backpressure verification, then the paused source-ring fill.
            fun preChunkLaneTriggers() {
                if (!session.outputBackpressureVerified &&
                    session.kotlinFramesAccepted >= phaseATargetFrames
                ) {
                    session.verifyOutputBackpressureAndEnableDrains()
                }
                if (session.outputBackpressureVerified && !sourceLaneStarted) {
                    // The paused fill must reach ring_full before the frozen
                    // pre-seek budget runs out; fail closed instead of
                    // wedging when an oversized codec chunk ate the margin.
                    if (t.preSeekFrames - session.kotlinFramesAccepted <
                        config.sourceRingCapacityFrames.toLong() + 2L * mfpm
                    ) {
                        throw FailClosed("insufficient_budget_for_source_lane")
                    }
                    sourceLaneStarted = true
                    session.pauseAtQuiescentBoundary()
                }
            }

            // One already-copied direct slice at byte offset 0. During the
            // paused fill the writer must reach ring_full; the rejected
            // remainder (compacted to offset 0) is then retried losslessly
            // after resume, so no committed decoded frame is ever dropped.
            fun ingestSlice(sliceBuf: ByteBuffer, sliceFrames: Int) {
                if (session.pausedFillActive) {
                    val remaining = session.ingestUntilRingFull(sliceBuf, sliceFrames)
                    if (session.sourceRingFullObserved) {
                        session.resumeAfterSourceBackpressure()
                        sourceLaneDone = true
                        if (remaining > 0) {
                            session.ingestChunkLossless(sliceBuf, remaining)
                        }
                    }
                } else {
                    session.ingestChunkLossless(sliceBuf, sliceFrames)
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
                    val budgetEnd = if (phase1) t.preSeekFrames else expectedFrames
                    if (phase1 && session.isCreated &&
                        session.kotlinFramesAccepted >= budgetEnd
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
                                if (!session.isCreated) establishSession()
                                if (info.size % bytesPerFrame != 0) {
                                    dec.releaseOutputBuffer(outIdx, false)
                                    throw FailClosed("codec_chunk_shape_invalid:${info.size}")
                                }
                                val chunkFrames = info.size / bytesPerFrame
                                t.totalFramesExtracted += chunkFrames
                                // Re-read the phase budget here: the first
                                // chunk's establishSession() call above is
                                // what froze the budgets.
                                val budget =
                                    if (phase1) t.preSeekFrames else expectedFrames
                                val room = budget - session.kotlinFramesAccepted
                                val ingestFrames =
                                    minOf(chunkFrames.toLong(), maxOf(0L, room)).toInt()
                                val excess = chunkFrames - ingestFrames
                                if (excess > 0) {
                                    // Never-ingested decoded frames: honest
                                    // media-discontinuity accounting, kept
                                    // out of every identity claim.
                                    if (phase1) {
                                        t.framesTruncatedAtSeekBoundary += excess
                                    } else {
                                        t.framesDiscardedAfterBudget += excess
                                    }
                                }
                                if (ingestFrames > 0) {
                                    val s = scratch!!
                                    val outBuf = dec.getOutputBuffer(outIdx)!!
                                    // Copy the committed leading frames into
                                    // direct slices (scratch first, bounded
                                    // temporaries only on overflow), all at
                                    // byte offset 0, BEFORE releasing the
                                    // codec output buffer; only then may any
                                    // JNI call run.
                                    val sliceCapBytes = s.capacity()
                                    val slices = ArrayList<Pair<ByteBuffer, Int>>()
                                    var sliceOffset = info.offset
                                    var remainingBytes = ingestFrames * bytesPerFrame
                                    while (remainingBytes > 0) {
                                        val sliceBytes = minOf(remainingBytes, sliceCapBytes)
                                        val dst = if (slices.isEmpty()) {
                                            s
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
                                    if (session.isCreated &&
                                        session.kotlinFramesAccepted >= t.preSeekFrames
                                    ) {
                                        return
                                    }
                                    throw FailClosed("decoder_eos_before_pre_seek_budget")
                                }
                                if (session.kotlinFramesAccepted < expectedFrames) {
                                    throw FailClosed("decoder_eos_before_post_seek_budget")
                                }
                                t.decoderEosReachedOk = true
                                return
                            }
                        }
                        // INFO_TRY_AGAIN_LATER — the deadline bounds the wait.
                    }
                }
            }

            // ── Phase 1: pre-seek decode with both backpressure lanes ───────
            decodePhase(seekTargetUs, phase1 = true)
            if (!session.isCreated) throw FailClosed("no_decoder_output")
            if (!session.outputBackpressureVerified) {
                throw FailClosed("output_backpressure_lane_not_run")
            }
            if (session.pausedFillActive) {
                throw FailClosed("budget_reached_during_paused_fill")
            }
            if (!sourceLaneDone) throw FailClosed("source_backpressure_lane_not_run")
            t.outputBackpressureOk = true
            t.sourceBackpressureRetryOk = session.sourceRingFullObserved &&
                session.writerBackpressureRejects >= 1L

            // ── The one pre-EOS native seek at the aligned budget boundary ──
            val seekFrame = session.seekAtAcceptedAlignedBoundary()
            if (seekFrame != t.preSeekFrames) throw FailClosed("seek_frame_budget_mismatch")
            t.seekTargetFrame = seekFrame
            t.seekEpochReanchorOk = session.seekReanchorOk
            t.detailParts.add("seekAcceptedFrame=$seekFrame")
            t.detailParts.add("post_seek_media_content_overlap_permitted")

            // Extractor seek stays media-local; PREVIOUS_SYNC may land early
            // and re-decode content already ingested pre-seek (non-claim
            // recorded above). flush() discards in-flight codec state.
            extractor.seekTo(seekTargetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val postSeekStartUs =
                extractor.sampleTime.let { if (it >= 0L) it else seekTargetUs }
            dec.flush()
            t.detailParts.add("postSeekStartUs=$postSeekStartUs")

            // ── Phase 2: post-seek decode to the total budget, then codec
            // EOS run-out ───────────────────────────────────────────────────
            decodePhase(postSeekStartUs + (windowUs - seekTargetUs), phase1 = false)

            // ── Exact timeline completion, then writer-local EOS ────────────
            session.completeTimelineAndSetEos()

            // ── Final snapshot + verdict lanes ──────────────────────────────
            session.finalSnapshot()
            t.detailParts.add("preSeekFrames=${t.preSeekFrames}")
            t.detailParts.add("postSeekFrames=${t.postSeekFrames}")
            t.detailParts.add("expectedFrames=$expectedFrames")
            t.detailParts.add(
                "framesTruncatedAtSeekBoundary=${t.framesTruncatedAtSeekBoundary}"
            )
            t.detailParts.add(
                "framesDiscardedAfterBudget=${t.framesDiscardedAfterBudget}"
            )

            t.asyncWorkerOwnershipOk = session.workerOwnershipAtBootOk &&
                session.snapWorkerThreadDistinct &&
                session.snapOwnerDispatchCalls == 0L &&
                session.snapWorkerDispatchAnomalies == 0L &&
                session.snapSchedulerErrorCount == 0L &&
                !session.snapTerminal
            if (!t.asyncWorkerOwnershipOk) throw FailClosed("async_worker_ownership_violated")

            t.controlCommandSerializationOk = session.snapCommandsEnqueued == 4L &&
                session.snapCommandsProcessed == 4L &&
                session.snapCommandErrors == 0L &&
                session.snapLastCommandSeq == 4L &&
                session.snapQueueDepth == 0L
            if (!t.controlCommandSerializationOk) {
                throw FailClosed("command_serialization_mismatch")
            }

            val kotlinChecksumHex = String.format("%016x", session.kotlinChecksum)
            t.checksumIdentityOk =
                kotlinChecksumHex == session.nativeAcceptedChecksumHex &&
                kotlinChecksumHex == session.nativeOutputReadChecksumHex &&
                session.snapProviderFramesZeroFilled == 0L &&
                session.snapProviderUnderrunEvents == 0L &&
                session.snapSilenceCount == 0L
            if (!t.checksumIdentityOk) throw FailClosed("checksum_identity_mismatch")

            t.frameAccountingOk =
                session.totalFramesAccepted == expectedFrames &&
                    session.snapTotalFramesRendered == expectedFrames &&
                    session.snapTotalFramesPushed == expectedFrames &&
                    session.totalOutputFramesRead == expectedFrames &&
                    session.kotlinFramesAccepted == expectedFrames &&
                    session.snapProviderForwardSkipFrames == 0L &&
                    session.snapProviderRewindRejects == 0L
            if (!t.frameAccountingOk) throw FailClosed("frame_accounting_mismatch")

            t.realDecoderIngestOk = session.totalFramesAccepted == expectedFrames &&
                t.totalFramesExtracted >= expectedFrames
            if (!t.realDecoderIngestOk) throw FailClosed("real_decoder_ingest_shortfall")

            t.noOwnerThreadDispatchOk = session.snapOwnerDispatchCalls == 0L &&
                session.snapWorkerThreadDistinct
            if (!t.noOwnerThreadDispatchOk) throw FailClosed("owner_thread_dispatch_observed")

            t.canonicalProofBoundaryOk = session.snapProofBoundary ==
                AndroidAsyncRuntimeQueueRealDecoderNativeSession.NATIVE_PROOF_BOUNDARY
            if (!t.canonicalProofBoundaryOk) throw FailClosed("native_proof_boundary_mismatch")

            // ── Foreign-thread rejection probe at a quiescent point ─────────
            t.foreignThreadRejectedOk = session.probeForeignThreadRejected()
            if (!t.foreignThreadRejectedOk) throw FailClosed("foreign_thread_not_rejected")

            // ── Destroy: join-on-destroy + idempotence ──────────────────────
            val (joinOk, idempotentOk) = session.destroyAndVerifyLifecycle()
            t.workerJoinOnDestroyOk = joinOk
            if (!joinOk) throw FailClosed("worker_join_on_destroy_failed")
            t.idempotentDestroyOk = idempotentOk
            if (!idempotentOk) throw FailClosed("destroy_not_idempotent")

            return makeResult(t, session, config, pass = true, failureReason = "")
        } catch (f: FailClosed) {
            return makeResult(t, session, config, pass = false, failureReason = f.reason)
        } catch (f: AndroidAsyncRuntimeQueueRealDecoderNativeSession.Failure) {
            return makeResult(t, session, config, pass = false, failureReason = f.reason)
        } catch (e: Throwable) {
            return makeResult(
                t, session, config, pass = false,
                failureReason = "exception:${e.javaClass.simpleName}:${e.message}",
            )
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
            session.cleanup()
        }
    }

    private fun makeResult(
        t: RunTelemetry,
        session: AndroidAsyncRuntimeQueueRealDecoderNativeSession,
        config: RunConfig,
        pass: Boolean,
        failureReason: String,
    ): RunResult = RunResult(
        pass = pass,
        status = if (pass) "pass" else failureReason.substringBefore(':').ifBlank { "fail" },
        marker = if (pass) PASS_MARKER else FAIL_MARKER,
        proofBoundary = PROOF_BOUNDARY,
        failureReason = failureReason,
        details = t.detailParts.joinToString("|"),
        formatProbeOk = t.formatProbeOk,
        decoderEosReachedOk = t.decoderEosReachedOk,
        asyncWorkerOwnershipOk = t.asyncWorkerOwnershipOk,
        controlCommandSerializationOk = t.controlCommandSerializationOk,
        realDecoderIngestOk = t.realDecoderIngestOk,
        sourceBackpressureRetryOk = t.sourceBackpressureRetryOk,
        outputBackpressureOk = t.outputBackpressureOk,
        checksumIdentityOk = t.checksumIdentityOk,
        frameAccountingOk = t.frameAccountingOk,
        seekEpochReanchorOk = t.seekEpochReanchorOk,
        noOwnerThreadDispatchOk = t.noOwnerThreadDispatchOk,
        foreignThreadRejectedOk = t.foreignThreadRejectedOk,
        workerJoinOnDestroyOk = t.workerJoinOnDestroyOk,
        idempotentDestroyOk = t.idempotentDestroyOk,
        canonicalProofBoundaryOk = t.canonicalProofBoundaryOk,
        sampleRate = t.sampleRate,
        channelCount = t.channelCount,
        pcmEncoding = t.pcmEncoding,
        expectedFrames = session.expectedFrames,
        preSeekFrames = t.preSeekFrames,
        postSeekFrames = t.postSeekFrames,
        seekTargetFrame = t.seekTargetFrame,
        totalFramesExtracted = t.totalFramesExtracted,
        totalFramesAccepted = session.totalFramesAccepted,
        totalFramesRendered = session.snapTotalFramesRendered,
        totalFramesPushed = session.snapTotalFramesPushed,
        totalOutputFramesRead = session.totalOutputFramesRead,
        framesTruncatedAtSeekBoundary = t.framesTruncatedAtSeekBoundary,
        framesDiscardedAfterBudget = t.framesDiscardedAfterBudget,
        decoderBenignFormatChangeCount = t.decoderBenignFormatChangeCount,
        commandsEnqueued = session.snapCommandsEnqueued,
        commandsProcessed = session.snapCommandsProcessed,
        commandErrors = session.snapCommandErrors,
        dispatchCount = session.snapDispatchCount,
        silenceCount = session.snapSilenceCount,
        backpressureCount = session.snapBackpressureCount,
        writerBackpressureRejects = session.writerBackpressureRejects,
        providerUnderrunEvents = session.snapProviderUnderrunEvents,
        providerFramesZeroFilled = session.snapProviderFramesZeroFilled,
        providerForwardSkipFrames = session.snapProviderForwardSkipFrames,
        providerRewindRejects = session.snapProviderRewindRejects,
        workerThreadDistinct = session.snapWorkerThreadDistinct,
        ownerDispatchCalls = session.snapOwnerDispatchCalls,
        kotlinAcceptedChecksumHex = String.format("%016x", session.kotlinChecksum),
        nativeAcceptedChecksumHex = session.nativeAcceptedChecksumHex,
        nativeOutputReadChecksumHex = session.nativeOutputReadChecksumHex,
        maxFramesPerMix = config.maxFramesPerMix.toLong(),
        nativeLastStatus = session.lastStatus,
    )
}
