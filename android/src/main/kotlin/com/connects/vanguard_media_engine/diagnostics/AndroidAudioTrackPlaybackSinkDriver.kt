package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidAudioTrackPlaybackSinkDriver (P4-AUDIO-AUDIOTRACK-OUTPUT-SINK-WRITE) ─
//
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice I: Kotlin-owned
// android.media.AudioTrack MODE_STREAM PCM16 output sink fed from the
// existing sub-slice H1 closed-loop native audio graph pipeline output ring
// through the new readAudioGraphPipelineOutputPcm16 JNI read path
// ([AndroidAudioTrackSinkNativeSession]). Proves OS sink writes and HAL
// consumption via playback-head advancement plus conditional AudioTimestamp
// telemetry — a diagnostic proof core only.
//
// Proof shape, all on the single caller thread of [run] (except the
// deliberate foreign-thread probe inside the session that native must
// reject):
//   - Probe the decoder output format (PCM16, 1-2 channels) -> create the
//     AudioTrack (MODE_STREAM, matching mono/stereo mask, no offload, no
//     low-latency mode, no audio focus, default volume 0.0) and assert
//     STATE_INITIALIZED -> create + start the native session -> ack-only
//     readOutputPcm(maxFrames = 0) -> pre-roll a frozen positive frame
//     count with the playback head still at 0 -> play().
//   - Active loop: decode/top-up the source ring -> step/dispatch at the
//     frame-derived virtual tick -> read output PCM through the new JNI
//     read into one reused direct ByteBuffer -> write those exact bytes to
//     the AudioTrack with WRITE_NON_BLOCKING (partial writes compacted and
//     retried in the same buffer; error codes fail closed) -> sample head/
//     timestamp telemetry -> repeat.
//   - Seek lifecycle: EOS tail flush drains the rig through the sink, the
//     head catches up to the epoch's written frames under a bounded wait,
//     then pause() -> flush() -> new frame epoch (counters + head baseline
//     reset) -> native accepted-frame-axis seek -> ack-only read ->
//     pre-roll -> play(). Pause/resume as user features are out of scope.
//   - EOS/tail: final tail flush writes every remaining byte, the head
//     catches up, then stop(). Cleanup releases the AudioTrack exactly
//     once, guarded in finally.
//
// Honest non-claims: no audible-output claim, no speaker-route
// verification, no audio quality/glitch-freedom/latency claim, no realtime
// clock sync, no A/V sync, no audio focus, no becoming-noisy or route
// change handling, no dead-object recovery, no AAudio/OpenSL/Oboe, no
// production source-node wiring, no export or pass-2 reroute, no
// streaming/cache, no iOS, no product/editor UI. PASS never depends on
// audible observation. Native never reads a wall clock; wall time is
// Kotlin telemetry/deadline only.
class AndroidAudioTrackPlaybackSinkDriver(
    private val cancelled: () -> Boolean,
) {

    companion object {
        const val PASS_MARKER = "ANDROID_DAG_PHASE4_AUDIOTRACK_OUTPUT_SINK_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_AUDIOTRACK_OUTPUT_SINK_SMOKE_FAIL"
        const val PROOF_BOUNDARY =
            "kotlin_owned_android_audiotrack_output_sink_write_diagnostic_proof_only_existing_h2_closed_loop_native_output_ring_source_no_cpp_os_sink_no_native_wall_clock_read_frame_derived_virtual_ticks_only_system_nanotime_telemetry_only_audio_timestamp_conditional_telemetry_only_playback_head_consumption_assertion_only_no_audible_output_claim_no_speaker_route_verification_no_audio_quality_claim_no_glitch_freedom_no_latency_budget_no_realtime_clock_sync_no_av_sync_no_pause_resume_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_offload_no_low_latency_mode_no_aaudio_no_opensl_no_oboe_no_dead_object_recovery_no_production_source_node_wiring_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_single_kotlin_worker_thread_all_jni_and_audiotrack_calls_direct_bytebuffer_reused_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim_no_in_band_dispose_cancellation_proof_detach_cancellation_source_audited_invariant_only"

        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val HARD_MAX_DURATION_SEC = 2.0

        // Matches the native per-call ingest clamp (AudioDecoderRingWriter
        // kMaxWriteFrames).
        private const val SCRATCH_FRAMES = 8192

        // Frozen pre-roll: this many full mix windows must be written
        // (head still at the epoch baseline) before play(); the AudioTrack
        // buffer floor below guarantees they fit without a blocking write.
        private const val PREROLL_WINDOWS = 2L
        private const val TRACK_BUFFER_MIN_WINDOWS = 4L

        private const val MAX_CHUNK_RETRIES = 64
        private const val MAX_DRAIN_ITERATIONS = 256
        private const val MAX_CONSECUTIVE_ZERO_WRITES = 500
        private const val ZERO_WRITE_SLEEP_MS = 2L
        private const val HEAD_POLL_SLEEP_MS = 5L
        private const val HEAD_CATCHUP_MARGIN_MS = 3_000L
        private const val TIMESTAMP_SAMPLE_INTERVAL = 16L
    }

    data class RunConfig(
        val sourcePath: String,
        val durationSec: Double = 1.0,
        val seekTargetSec: Double = 0.35,
        val volume: Float = 0.0f,
        val sourceRingCapacityFrames: Int = 8192,
        val outputRingCapacityFrames: Int = 4096,
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
        // Physically asserted lanes.
        val formatProbeOk: Boolean,
        val audioTrackInitOk: Boolean,
        val prerollOk: Boolean,
        val sinkWriteAccountingOk: Boolean,
        val checksumIdentityOk: Boolean,
        val playbackHeadMonotonicOk: Boolean,
        val playbackHeadAdvancedOk: Boolean,
        val headNeverExceedsWrittenOk: Boolean,
        val tailDrainedOk: Boolean,
        val seekEpochAccountingOk: Boolean,
        val noUnderrunOk: Boolean,
        val noSilenceOk: Boolean,
        val noRingPushShortfallOk: Boolean,
        val zeroNativeSteadyStateAllocationOk: Boolean,
        val ownerThreadOk: Boolean,
        val lifecycleOk: Boolean,
        val canonical: Boolean,
        // Conditional / telemetry lanes. cancellationPollingLiveOk only
        // attests that the dispose-cancellation flag was polled during the
        // run; real dispose cancellation is source-audited, never exercised
        // in-band here (a real disposeAll() cancels the run and drops the
        // reply by design).
        val cancellationPollingLiveOk: Boolean,
        val audioTimestampAvailable: Boolean,
        val audioTimestampValidOk: Boolean,
        // Metrics.
        val cancellationPollCount: Long,
        val sampleRate: Int,
        val channelCount: Int,
        val audioTimestampAttemptCount: Long,
        val audioTimestampSuccessCount: Long,
        val playbackHeadFinal: Long,
        val framesWrittenTotal: Long,
        val framesReadFromRingTotal: Long,
        val partialWriteCount: Long,
        val zeroWriteCount: Long,
        val getUnderrunCount: Long,
        val bufferSizeInFrames: Long,
        val bufferCapacityInFrames: Long,
        val maxHeadLagFrames: Long,
        val finalHeadLagFrames: Long,
        val prerollFrames: Long,
        val seekAcceptedFrame: Long,
        val totalFramesAccepted: Long,
        val totalOutputFramesDrained: Long,
        val dispatchCount: Long,
        val nativeOutputDrainChecksumHex: String,
        val kotlinSinkChecksumHex: String,
        val nativeLastStatus: String,
    )

    private class FailClosed(val reason: String) : Exception(reason)

    // Mutable lane telemetry threaded through the run so fail-closed paths
    // still report everything observed up to the failure point.
    private class RunTelemetry {
        var formatProbeOk = false
        var audioTrackInitOk = false
        var prerollOk = false
        var sinkWriteAccountingOk = false
        var checksumIdentityOk = false
        var playbackHeadAdvancedOk = false
        var tailDrainedOk = false
        var seekEpochAccountingOk = false
        var noUnderrunOk = false
        var noSilenceOk = false
        var noRingPushShortfallOk = false
        var zeroNativeSteadyStateAllocationOk = false
        var ownerThreadOk = false
        var lifecycleOk = false
        var sampleRate = 0
        var channelCount = 0
        var seekAcceptedFrame = -1L
        val detailParts = mutableListOf<String>()
    }

    private lateinit var config: RunConfig
    private lateinit var session: AndroidAudioTrackSinkNativeSession
    private val t = RunTelemetry()

    private var audioTrack: AudioTrack? = null
    private var audioTrackReleaseCount = 0
    private var sinkBuffer: ByteBuffer? = null
    private var bytesPerFrame = 0
    private var mfpm = 0L
    private var srcCap = 0L
    private var prerollFrames = 0L
    private var bufferSizeInFrames = 0L
    private var bufferCapacityInFrames = 0L

    // Frame-epoch state: one epoch per AudioTrack write span
    // ([start..seek] and [seek..eos]); flush() opens a new epoch with the
    // head baseline re-read from the track.
    private var epochIndex = -1
    private var epochFramesReadFromRing = 0L
    private var epochFramesWritten = 0L
    private var epochHeadBaselineRaw = 0L
    private var epochLastRawHead = 0L
    private var epochPlayed = false
    private var epochLastTimestampFramePos = -1L
    private var epochsClosed = 0
    private var boundariesDrained = 0
    private var prerollEpochsSatisfied = 0

    // Totals & sink telemetry.
    private var framesReadFromRingTotal = 0L
    private var framesWrittenTotal = 0L
    private var partialWriteCount = 0L
    private var zeroWriteCount = 0L
    private var kotlinSinkChecksum = 0L
    private var timestampAttempts = 0L
    private var timestampSuccesses = 0L
    private var timestampAvailable = false
    private var timestampValid = true
    private var maxHeadLagFrames = 0L
    private var finalHeadLagFrames = -1L
    private var playbackHeadFinal = 0L
    private var telemetrySampleCounter = 0L
    private var headSampleCount = 0L
    private var headMonotonicViolated = false
    private var headBoundViolated = false
    private var underrunCountCaptured = -1L
    private var runDeadlineMs = 0L
    private var cancellationPollCount = 0L
    private var cancellationTripped = false
    private val timestampScratch = AudioTimestamp()

    fun run(runConfig: RunConfig): RunResult {
        config = runConfig
        val deadline = SystemClock.elapsedRealtime() + config.deadlineMs
        runDeadlineMs = deadline
        session = AndroidAudioTrackSinkNativeSession(deadline)
        mfpm = config.maxFramesPerMix.toLong()
        srcCap = config.sourceRingCapacityFrames.toLong()
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null

        try {
            if (config.sourcePath.isBlank()) throw FailClosed("source_path_required")
            val windowSec = minOf(config.durationSec, HARD_MAX_DURATION_SEC)
            if (windowSec <= 0.0) throw FailClosed("invalid_decode_duration")
            if (config.seekTargetSec < 0.0 || config.seekTargetSec >= windowSec) {
                throw FailClosed("invalid_seek_target")
            }
            if (config.volume !in 0.0f..1.0f) throw FailClosed("invalid_volume")
            if (config.maxFramesPerMix <= 0) throw FailClosed("invalid_max_frames_per_mix")
            val windowUs = (windowSec * 1_000_000.0).toLong()
            val seekTargetUs = (config.seekTargetSec * 1_000_000.0).toLong()

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

            var scratch: ByteBuffer? = null

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

            // First format resolution. Ordering is mandatory: probe format
            // -> create AudioTrack (assert STATE_INITIALIZED) -> create
            // native session -> start + ack-only read; pre-roll/play happen
            // later as decoded frames flow through the sink.
            fun establishSinkAndSession() {
                val (sr, ch, enc) = readOutputFormat()
                if (enc != AudioFormat.ENCODING_PCM_16BIT) {
                    throw FailClosed("unsupported_pcm_encoding:$enc")
                }
                if (ch != 1 && ch != 2) throw FailClosed("unsupported_channel_count:$ch")
                if (sr <= 0) throw FailClosed("invalid_sample_rate:$sr")
                t.sampleRate = sr
                t.channelCount = ch
                bytesPerFrame = 2 * ch
                prerollFrames = PREROLL_WINDOWS * mfpm
                createAudioTrack(sr, ch)
                // One reused direct sink buffer for the whole run: exactly
                // maxFramesPerMix frames.
                val sink = ByteBuffer.allocateDirect(config.maxFramesPerMix * bytesPerFrame)
                    .order(ByteOrder.LITTLE_ENDIAN)
                sinkBuffer = sink
                scratch = ByteBuffer.allocateDirect(SCRATCH_FRAMES * bytesPerFrame)
                    .order(ByteOrder.LITTLE_ENDIAN)
                session.create(
                    sr, ch,
                    config.sourceRingCapacityFrames,
                    config.outputRingCapacityFrames,
                    config.maxFramesPerMix,
                )
                session.startAndConsumeAck(sink)
                openEpoch()
                t.formatProbeOk = true
            }

            // A repeated format change with identical parameters is benign;
            // any difference is malignant (the AudioTrack format is frozen).
            fun onOutputFormatChanged() {
                if (!session.isCreated) {
                    establishSinkAndSession()
                    return
                }
                val (sr, ch, enc) = readOutputFormat()
                if (sr != t.sampleRate || ch != t.channelCount ||
                    enc != AudioFormat.ENCODING_PCM_16BIT
                ) {
                    throw FailClosed("malignant_format_change")
                }
            }

            // Streams decoder output into the native session until the codec
            // reports output EOS; input EOS is queued once the extractor
            // passes [endUs] (or runs out of samples). Same copy/release
            // policy as H2: all slices are copied to direct buffers and the
            // codec output buffer is released before any JNI call runs.
            fun decodePhase(endUs: Long) {
                val info = MediaCodec.BufferInfo()
                var inputDone = false
                var outputDone = false
                while (!outputDone) {
                    pollCancellation()
                    checkDeadline()
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
                                if (!session.isCreated) establishSinkAndSession()
                                val s = scratch!!
                                if (info.size % bytesPerFrame != 0) {
                                    dec.releaseOutputBuffer(outIdx, false)
                                    throw FailClosed("codec_chunk_shape_invalid:${info.size}")
                                }
                                val outBuf = dec.getOutputBuffer(outIdx)!!
                                val sliceCapBytes = s.capacity()
                                val slices = ArrayList<Pair<ByteBuffer, Int>>()
                                var sliceOffset = info.offset
                                var remainingBytes = info.size
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
                                // Codec output buffer goes back to the codec
                                // before any native call runs.
                                dec.releaseOutputBuffer(outIdx, false)
                                for ((sliceBuf, sliceFrames) in slices) {
                                    ingestChunkLossless(sliceBuf, sliceFrames)
                                }
                                pumpFullWindows()
                            } else {
                                dec.releaseOutputBuffer(outIdx, false)
                            }
                            if (isEos) outputDone = true
                        }
                        // INFO_TRY_AGAIN_LATER — the deadline bounds the wait.
                    }
                    sampleTelemetry()
                }
            }

            // ── Pre-seek: decode media [0, seekTarget] through the sink ─────
            decodePhase(seekTargetUs)
            if (!session.isCreated) throw FailClosed("no_decoder_output")

            // ── Pre-seek terminal boundary: lossless EOS tail flush through
            // the sink, then bounded head catch-up ──────────────────────────
            flushTailAtEos()
            playIfPrerolled(force = true)
            waitForHeadCatchUp("pre_seek")
            closeEpochAccounting("epoch0")
            t.detailParts.add("epoch0FramesWritten=$epochFramesWritten")

            // ── AudioTrack seek lifecycle: pause -> flush -> new epoch ->
            // native accepted-frame-axis seek -> ack-only read ──────────────
            val track = audioTrack!!
            track.pause()
            track.flush()
            openEpoch()
            if (epochFramesWritten != 0L || epochFramesReadFromRing != 0L) {
                throw FailClosed("seek_epoch_counters_not_reset")
            }
            val seekFrame = session.seekToAcceptedFrameBoundary(sinkBuffer!!)
            t.seekAcceptedFrame = seekFrame
            t.seekEpochAccountingOk = true
            t.detailParts.add("seekAcceptedFrame=$seekFrame")
            t.detailParts.add("post_seek_media_content_overlap_permitted")

            // Extractor seek stays media-local; PREVIOUS_SYNC may land early
            // and re-decode content already ingested pre-seek (non-claim
            // recorded above).
            extractor.seekTo(seekTargetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val postSeekStartUs =
                extractor.sampleTime.let { if (it >= 0L) it else seekTargetUs }
            dec.flush()
            t.detailParts.add("postSeekStartUs=$postSeekStartUs")

            // ── Post-seek: remaining window budget through the sink, then
            // the final EOS/tail boundary and stop() ────────────────────────
            decodePhase(postSeekStartUs + (windowUs - seekTargetUs))
            flushTailAtEos()
            playIfPrerolled(force = true)
            waitForHeadCatchUp("final")
            t.playbackHeadAdvancedOk = currentEpochHead() > 0L
            if (!t.playbackHeadAdvancedOk) throw FailClosed("playback_head_not_advanced")
            playbackHeadFinal = currentEpochHead()
            finalHeadLagFrames = epochFramesWritten - playbackHeadFinal
            closeEpochAccounting("epoch1")
            t.detailParts.add("epoch1FramesWritten=$epochFramesWritten")
            track.stop()
            underrunCountCaptured = try {
                track.underrunCount.toLong()
            } catch (_: Throwable) {
                -1L
            }

            t.tailDrainedOk = boundariesDrained == 2
            if (!t.tailDrainedOk) throw FailClosed("tail_drain_boundary_missing")
            t.prerollOk = prerollEpochsSatisfied == 2
            if (!t.prerollOk) throw FailClosed("preroll_not_satisfied")

            // ── Owner-thread probe at a quiescent point ─────────────────────
            t.ownerThreadOk = session.probeForeignThreadRejected()
            if (!t.ownerThreadOk) throw FailClosed("foreign_thread_not_rejected")

            // ── Final snapshot + verdict lanes ──────────────────────────────
            val snapEnd = session.snapshotMetrics()
            t.noUnderrunOk = session.providerUnderrunEvents == 0L &&
                session.providerFramesZeroFilled == 0L
            if (!t.noUnderrunOk) throw FailClosed("provider_underrun_observed")
            t.noSilenceOk = session.coordinatorSilenceCount == 0L
            if (!t.noSilenceOk) throw FailClosed("silence_window_observed")
            t.noRingPushShortfallOk = !session.ringPushShortfallSeen
            if (!t.noRingPushShortfallOk) throw FailClosed("ring_push_shortfall_observed")
            t.zeroNativeSteadyStateAllocationOk =
                session.verifyZeroSteadyStateAllocation(snapEnd)
            if (!t.zeroNativeSteadyStateAllocationOk) {
                throw FailClosed("native_steady_state_allocation_detected")
            }

            if (framesWrittenTotal <= 0L) throw FailClosed("no_frames_written_to_sink")
            t.sinkWriteAccountingOk = epochsClosed == 2 &&
                framesReadFromRingTotal == framesWrittenTotal &&
                framesReadFromRingTotal == session.totalOutputFramesDrained
            if (!t.sinkWriteAccountingOk) throw FailClosed("sink_write_accounting_mismatch")

            val kotlinChecksumHex = String.format("%016x", kotlinSinkChecksum)
            t.checksumIdentityOk = kotlinChecksumHex == session.nativeOutputDrainChecksumHex
            if (!t.checksumIdentityOk) throw FailClosed("checksum_identity_mismatch")

            // ── Lifecycle lane: idempotent any-thread native destroy plus
            // exactly-once AudioTrack release ───────────────────────────────
            val nativeLifecycleOk = session.destroyAndVerifyLifecycle()
            releaseAudioTrackOnce(guardedStop = false)
            t.lifecycleOk = nativeLifecycleOk && audioTrackReleaseCount == 1
            if (!t.lifecycleOk) throw FailClosed("lifecycle_not_clean")

            return makeResult(pass = true, failureReason = "")
        } catch (f: FailClosed) {
            return makeResult(pass = false, failureReason = f.reason)
        } catch (f: AndroidAudioTrackSinkNativeSession.Failure) {
            return makeResult(pass = false, failureReason = f.reason)
        } catch (e: Throwable) {
            return makeResult(
                pass = false,
                failureReason = "exception:${e.javaClass.simpleName}:${e.message}",
            )
        } finally {
            // Prompt release on every path (including dispose cancellation):
            // guarded pause/flush/release exactly once, then codec/extractor
            // release, then native destroy.
            releaseAudioTrackOnce(guardedStop = true)
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
            session.cleanup()
        }
    }

    // ── Sink pump: step/dispatch + read + AudioTrack write ──────────────────

    private fun pumpFullWindows() {
        var guard = 0
        val budget = (srcCap / mfpm) + 4
        while (session.sourceAvailableReadFrames >= mfpm) {
            pollCancellation()
            if (++guard > budget) throw FailClosed("pump_budget_exhausted")
            when (val s = session.stepWindow()) {
                "dispatch_ok" -> readWindowAndWrite(mfpm)
                "output_backpressure" -> drainAllOutputThroughSink()
                "deferred_insufficient_source" -> return
                else -> throw FailClosed("pump_step_status_$s")
            }
            sampleTelemetry()
        }
    }

    // Lossless ingest of [frames] frames at byte offset 0 of [pcm]: retries
    // through ring backpressure by dispatching one window through the sink
    // to free space, compacting the unwritten remainder to byte offset 0
    // after every partial acceptance. No decoded frame is ever dropped.
    private fun ingestChunkLossless(pcm: ByteBuffer, frames: Int) {
        var remaining = frames
        var retries = 0
        while (remaining > 0) {
            pollCancellation()
            if (++retries > MAX_CHUNK_RETRIES) throw FailClosed("chunk_retry_budget_exhausted")
            val r = session.ingestOnce(pcm, remaining)
            if (r.framesAccepted > 0L) {
                if (r.framesAccepted < remaining) {
                    compactRemainder(pcm, r.framesAccepted.toInt(), remaining)
                }
                remaining -= r.framesAccepted.toInt()
            }
            if (remaining > 0) {
                // Ring out of space; the full ring guarantees at least one
                // dispatchable window (srcCap >= 2*maxFramesPerMix).
                if (session.sourceAvailableReadFrames < mfpm) {
                    throw FailClosed("ring_full_without_full_window")
                }
                when (val s = session.stepWindow()) {
                    "dispatch_ok" -> readWindowAndWrite(mfpm)
                    "output_backpressure" -> drainAllOutputThroughSink()
                    else -> throw FailClosed("ring_full_pump_status_$s")
                }
            }
        }
    }

    // Lossless boundary flush: writer-local EOS, then a tail-flush loop
    // that reads every rendered window through the sink and terminates only
    // on tail_flush_complete; afterwards the output ring is fully read and
    // the source ring must be empty.
    private fun flushTailAtEos() {
        session.setEosVerified()
        var budget = 0
        val tailBudget = (srcCap / mfpm) + 8
        while (true) {
            pollCancellation()
            if (++budget > tailBudget) throw FailClosed("tail_flush_budget_exhausted")
            val step = session.stepTailWindow()
            when (step.status) {
                "dispatch_ok", "tail_flush_partial_window" -> {
                    if (step.framesRendered <= 0L) throw FailClosed("tail_flush_rendered_zero")
                    readWindowAndWrite(step.framesRendered)
                }
                "tail_flush_complete" -> break
                "output_backpressure" -> drainAllOutputThroughSink()
                else -> throw FailClosed("tail_flush_step_status_${step.status}")
            }
        }
        drainAllOutputThroughSink()
        if (session.sourceAvailableReadFrames != 0L) throw FailClosed("tail_flush_source_not_empty")
    }

    // Reads exactly [frames] frames from the output ring through the sink
    // buffer (at most one mix window per read) and writes each read's bytes
    // to the AudioTrack before reading the ring again.
    private fun readWindowAndWrite(frames: Long) {
        var remaining = frames
        while (remaining > 0) {
            pollCancellation()
            val toRead = minOf(remaining, mfpm)
            val rr = session.readOutputPcm(sinkBuffer!!, toRead.toInt())
            if (rr.framesRead <= 0L) throw FailClosed("sink_read_short")
            accountFramesRead(rr.framesRead)
            writeAllToAudioTrack((rr.framesRead * bytesPerFrame).toInt())
            remaining -= rr.framesRead
        }
    }

    private fun drainAllOutputThroughSink() {
        var guard = 0
        while (session.outputAvailableReadFrames > 0L) {
            pollCancellation()
            if (++guard > MAX_DRAIN_ITERATIONS) throw FailClosed("drain_budget_exhausted")
            val rr = session.readOutputPcm(sinkBuffer!!, mfpm.toInt())
            if (rr.framesRead <= 0L) break
            accountFramesRead(rr.framesRead)
            writeAllToAudioTrack((rr.framesRead * bytesPerFrame).toInt())
        }
    }

    // Unwritten frames move to byte offset 0 so ingest retries always read
    // from the buffer start, exactly like the H2 decoder driver.
    private fun compactRemainder(buf: ByteBuffer, acceptedFrames: Int, totalFrames: Int) {
        buf.position(acceptedFrames * bytesPerFrame)
        buf.limit(totalFrames * bytesPerFrame)
        buf.compact()
    }

    // Mirrors the Kotlin sink-side checksum over exactly the frames handed
    // to AudioTrack.write (identical accumulation to the native drain
    // checksum: c = c * 31 + uint16(sample)).
    private fun accountFramesRead(framesRead: Long) {
        val buf = sinkBuffer!!
        val sampleCount = (framesRead * t.channelCount).toInt()
        var c = kotlinSinkChecksum
        for (i in 0 until sampleCount) {
            c = c * 31L + (buf.getShort(i * 2).toLong() and 0xFFFFL)
        }
        kotlinSinkChecksum = c
        epochFramesReadFromRing += framesRead
        framesReadFromRingTotal += framesRead
    }

    // Writes [bytes] bytes from offset 0 of the sink buffer to the
    // AudioTrack with WRITE_NON_BLOCKING, fail-closed on every error code.
    // Partial writes compact/retain the unwritten remainder in the same
    // buffer and retry before the ring is read again; repeated zero writes
    // park briefly and fail after a bounded budget.
    private fun writeAllToAudioTrack(bytes: Int) {
        val track = audioTrack ?: throw FailClosed("audio_track_missing")
        val buf = sinkBuffer!!
        buf.position(0)
        buf.limit(bytes)
        var consecutiveZero = 0
        while (buf.hasRemaining()) {
            pollCancellation()
            checkRunDeadline()
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
                    framesWrittenTotal += framesWritten
                    if (wrote < requested) {
                        partialWriteCount++
                        buf.compact()
                        buf.flip()
                    }
                    playIfPrerolled(force = false)
                }
                wrote == 0 -> {
                    zeroWriteCount++
                    if (++consecutiveZero > MAX_CONSECUTIVE_ZERO_WRITES) {
                        throw FailClosed("audio_track_write_stalled")
                    }
                    // Zero writes only park and retry; the pre-roll gate
                    // stays closed until the frozen frame count is written.
                    // The track buffer floor (TRACK_BUFFER_MIN_WINDOWS)
                    // exceeds PREROLL_WINDOWS, so a never-started track
                    // cannot fill before the steady-state gate opens.
                    SystemClock.sleep(ZERO_WRITE_SLEEP_MS)
                    sampleTelemetry()
                }
                wrote == AudioTrack.ERROR_INVALID_OPERATION ->
                    throw FailClosed("audio_track_invalid_operation")
                wrote == AudioTrack.ERROR_BAD_VALUE ->
                    throw FailClosed("audio_track_bad_value")
                wrote == AudioTrack.ERROR_DEAD_OBJECT ->
                    throw FailClosed("audio_track_dead_object")
                else -> throw FailClosed("audio_track_generic_error")
            }
        }
        buf.clear()
    }

    // ── AudioTrack lifecycle / pre-roll / head telemetry ────────────────────

    private fun createAudioTrack(sampleRate: Int, channelCount: Int) {
        val channelMask = if (channelCount == 1) {
            AudioFormat.CHANNEL_OUT_MONO
        } else {
            AudioFormat.CHANNEL_OUT_STEREO
        }
        val minBytes = AudioTrack.getMinBufferSize(
            sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBytes <= 0) throw FailClosed("audio_track_min_buffer_invalid:$minBytes")
        val floorBytes = (TRACK_BUFFER_MIN_WINDOWS * mfpm * bytesPerFrame).toInt()
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
            .setBufferSizeInBytes(maxOf(minBytes, floorBytes))
            .build()
        audioTrack = track
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            throw FailClosed("audio_track_not_initialized")
        }
        track.setVolume(config.volume)
        bufferSizeInFrames = track.bufferSizeInFrames.toLong()
        bufferCapacityInFrames = track.bufferCapacityInFrames.toLong()
        t.audioTrackInitOk = true
    }

    // Pre-roll gate: play() only after the frozen positive pre-roll frame
    // count is written this epoch, asserting the epoch head is still 0. A
    // forced terminal boundary that reaches this gate below the threshold
    // fails closed instead of playing early and claiming pre-roll.
    private fun playIfPrerolled(force: Boolean) {
        if (epochPlayed) return
        if (epochFramesWritten < prerollFrames) {
            if (!force) return
            if (epochFramesWritten <= 0L) throw FailClosed("preroll_no_frames_written")
            throw FailClosed("preroll_forced_below_threshold:$epochFramesWritten")
        }
        val headBeforePlay = currentEpochHead()
        if (headBeforePlay != 0L) throw FailClosed("preroll_head_not_zero:$headBeforePlay")
        audioTrack!!.play()
        epochPlayed = true
        prerollEpochsSatisfied++
    }

    private fun openEpoch() {
        epochIndex++
        epochFramesReadFromRing = 0L
        epochFramesWritten = 0L
        val raw = rawHead()
        epochHeadBaselineRaw = raw
        epochLastRawHead = raw
        epochPlayed = false
        epochLastTimestampFramePos = -1L
    }

    private fun closeEpochAccounting(label: String) {
        if (epochFramesReadFromRing != epochFramesWritten) {
            throw FailClosed("sink_write_accounting_mismatch_$label")
        }
        epochsClosed++
    }

    // Bounded wait for the playback head to consume every frame written
    // this epoch (terminal boundary drain proof); the budget derives from
    // the remaining playout time plus a fixed margin.
    private fun waitForHeadCatchUp(label: String) {
        if (epochFramesWritten == 0L) {
            boundariesDrained++
            return
        }
        if (!epochPlayed) throw FailClosed("head_catchup_without_play")
        val remaining = epochFramesWritten - currentEpochHead()
        val budgetMs = remaining * 1_000L / t.sampleRate + HEAD_CATCHUP_MARGIN_MS
        val waitDeadline = SystemClock.elapsedRealtime() + budgetMs
        while (true) {
            pollCancellation()
            checkRunDeadline()
            val head = sampleTelemetry()
            if (head >= epochFramesWritten) break
            if (SystemClock.elapsedRealtime() > waitDeadline) {
                throw FailClosed("tail_drain_head_timeout_$label")
            }
            SystemClock.sleep(HEAD_POLL_SLEEP_MS)
        }
        boundariesDrained++
    }

    private fun rawHead(): Long {
        val track = audioTrack ?: return 0L
        // playbackHeadPosition wraps as an unsigned 32-bit frame counter.
        return track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
    }

    private fun currentEpochHead(): Long = rawHead() - epochHeadBaselineRaw

    // One telemetry sample: per-epoch head monotonicity, head-vs-written
    // bound, drift telemetry, and a periodic conditional AudioTimestamp
    // probe. Returns the current epoch head.
    private fun sampleTelemetry(): Long {
        if (audioTrack == null) return 0L
        headSampleCount++
        val raw = rawHead()
        if (raw < epochLastRawHead) {
            headMonotonicViolated = true
            throw FailClosed("playback_head_not_monotonic")
        }
        epochLastRawHead = raw
        val head = raw - epochHeadBaselineRaw
        if (head > epochFramesWritten) {
            headBoundViolated = true
            throw FailClosed("playback_head_exceeds_written")
        }
        val lag = epochFramesWritten - head
        if (lag > maxHeadLagFrames) maxHeadLagFrames = lag
        if (epochPlayed && telemetrySampleCounter++ % TIMESTAMP_SAMPLE_INTERVAL == 0L) {
            attemptTimestamp()
        }
        return head
    }

    // Conditional telemetry: availability is recorded, not required. A
    // succeeded timestamp must carry nanoTime > 0 and a non-decreasing
    // framePosition that never exceeds the frames written this epoch.
    private fun attemptTimestamp() {
        timestampAttempts++
        val ok = try {
            audioTrack!!.getTimestamp(timestampScratch)
        } catch (_: Throwable) {
            false
        }
        if (!ok) return
        timestampSuccesses++
        timestampAvailable = true
        if (timestampScratch.nanoTime <= 0L) {
            timestampValid = false
            throw FailClosed("audio_timestamp_nanotime_invalid")
        }
        if (timestampScratch.framePosition < epochLastTimestampFramePos) {
            timestampValid = false
            throw FailClosed("audio_timestamp_regressed")
        }
        if (timestampScratch.framePosition > epochFramesWritten) {
            timestampValid = false
            throw FailClosed("audio_timestamp_ahead_of_written")
        }
        epochLastTimestampFramePos = timestampScratch.framePosition
    }

    // ── Cancellation / deadline / cleanup ───────────────────────────────────

    private fun pollCancellation() {
        cancellationPollCount++
        if (cancelled()) {
            cancellationTripped = true
            throw FailClosed("cancelled_by_dispose")
        }
    }

    // The session enforces the same deadline on every JNI call; this covers
    // the AudioTrack-only write/wait loops.
    private fun checkRunDeadline() {
        if (SystemClock.elapsedRealtime() > runDeadlineMs) {
            throw FailClosed("deadline_exceeded")
        }
    }

    private fun releaseAudioTrackOnce(guardedStop: Boolean) {
        val track = audioTrack ?: return
        if (audioTrackReleaseCount > 0) return
        if (guardedStop) {
            try { track.pause() } catch (_: Throwable) {}
            try { track.flush() } catch (_: Throwable) {}
        }
        try { track.release() } catch (_: Throwable) {}
        audioTrackReleaseCount++
    }

    private fun makeResult(pass: Boolean, failureReason: String): RunResult {
        val underruns = if (underrunCountCaptured >= 0L) {
            underrunCountCaptured
        } else {
            try {
                audioTrack?.underrunCount?.toLong() ?: -1L
            } catch (_: Throwable) {
                -1L
            }
        }
        return RunResult(
            pass = pass,
            status = if (pass) "pass" else failureReason.substringBefore(':').ifBlank { "fail" },
            marker = if (pass) PASS_MARKER else FAIL_MARKER,
            proofBoundary = PROOF_BOUNDARY,
            failureReason = failureReason,
            details = t.detailParts.joinToString("|"),
            formatProbeOk = t.formatProbeOk,
            audioTrackInitOk = t.audioTrackInitOk,
            prerollOk = t.prerollOk,
            sinkWriteAccountingOk = t.sinkWriteAccountingOk,
            checksumIdentityOk = t.checksumIdentityOk,
            playbackHeadMonotonicOk = headSampleCount > 0L && !headMonotonicViolated,
            playbackHeadAdvancedOk = t.playbackHeadAdvancedOk,
            headNeverExceedsWrittenOk = headSampleCount > 0L && !headBoundViolated,
            tailDrainedOk = t.tailDrainedOk,
            seekEpochAccountingOk = t.seekEpochAccountingOk,
            noUnderrunOk = t.noUnderrunOk,
            noSilenceOk = t.noSilenceOk,
            noRingPushShortfallOk = t.noRingPushShortfallOk,
            zeroNativeSteadyStateAllocationOk = t.zeroNativeSteadyStateAllocationOk,
            ownerThreadOk = t.ownerThreadOk,
            lifecycleOk = t.lifecycleOk,
            canonical = pass,
            cancellationPollingLiveOk = cancellationPollCount > 0L,
            audioTimestampAvailable = timestampAvailable,
            // Conditional lane: valid when unavailable; false only when a
            // returned timestamp violated the nanoTime/frame-position rules.
            audioTimestampValidOk = !timestampAvailable || timestampValid,
            cancellationPollCount = cancellationPollCount,
            sampleRate = t.sampleRate,
            channelCount = t.channelCount,
            audioTimestampAttemptCount = timestampAttempts,
            audioTimestampSuccessCount = timestampSuccesses,
            playbackHeadFinal = playbackHeadFinal,
            framesWrittenTotal = framesWrittenTotal,
            framesReadFromRingTotal = framesReadFromRingTotal,
            partialWriteCount = partialWriteCount,
            zeroWriteCount = zeroWriteCount,
            getUnderrunCount = underruns,
            bufferSizeInFrames = bufferSizeInFrames,
            bufferCapacityInFrames = bufferCapacityInFrames,
            maxHeadLagFrames = maxHeadLagFrames,
            finalHeadLagFrames = finalHeadLagFrames,
            prerollFrames = prerollFrames,
            seekAcceptedFrame = t.seekAcceptedFrame,
            totalFramesAccepted = session.totalFramesAccepted,
            totalOutputFramesDrained = session.totalOutputFramesDrained,
            dispatchCount = session.dispatchCount,
            nativeOutputDrainChecksumHex = session.nativeOutputDrainChecksumHex,
            kotlinSinkChecksumHex = String.format("%016x", kotlinSinkChecksum),
            nativeLastStatus = session.lastStatus,
        )
    }
}
