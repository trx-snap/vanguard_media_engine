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

// ── AndroidMultiSourceAudioTrackPlaybackSinkDriver (P4-AUDIO-MULTI-SOURCE-AUDIOTRACK-SINK) ─
//
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice K: Kotlin-owned AudioTrack
// MODE_STREAM PCM16 output sink fed from the TWO-SOURCE (real decoder +
// synthesized second track) closed-loop native graph pipeline output ring
// through readMultiSourceAudioGraphPipelineOutputPcm16. Owns the AudioTrack
// lifecycle, frame epochs, frozen pre-roll/play gate, write accounting,
// playback-head/AudioTimestamp telemetry, direct-buffer sink read, and the
// state machine; the ingest pump owns lockstep ingest/dispatch (handing
// every dispatched window back here for the read -> AudioTrack.write
// step); the native session owns every JNI interaction. A sink run never
// calls drainMultiSourceAudioGraphPipelineOutput anywhere and the terminal
// guard proves it. Honest non-claims are carried verbatim in
// PROOF_BOUNDARY; PASS never depends on audible observation; native never
// reads a wall clock (wall time is Kotlin telemetry/deadline only).
class AndroidMultiSourceAudioTrackPlaybackSinkDriver(
    private val cancelled: () -> Boolean = { false },
) {

    companion object {
        const val PASS_MARKER = "ANDROID_DAG_PHASE4_MULTI_SOURCE_AUDIO_TRACK_SINK_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_MULTI_SOURCE_AUDIO_TRACK_SINK_SMOKE_FAIL"
        const val PROOF_BOUNDARY =
            "kotlin_owned_android_audiotrack_multi_source_output_sink_write_diagnostic_proof_only_real_decoder_plus_synthetic_second_track_step_driven_closed_loop_native_audio_graph_pipeline_session_no_second_os_decoder_no_cpp_os_sink_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_read_frame_derived_virtual_ticks_only_system_nanotime_telemetry_only_audio_timestamp_conditional_telemetry_only_playback_head_consumption_assertion_only_no_audible_output_claim_no_speaker_route_verification_no_audio_quality_claim_no_glitch_freedom_no_latency_budget_no_realtime_clock_sync_no_av_sync_audiotrack_pause_flush_for_seek_epoch_only_no_transport_pause_resume_semantics_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_offload_no_low_latency_mode_no_aaudio_no_opensl_no_oboe_no_dead_object_recovery_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_seek_reanchors_both_tracks_at_single_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_truncation_beyond_budget_non_claim_two_routed_tracks_unit_gain_only_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_joint_tail_flush_diagnostic_only_no_jni_reverse_callbacks_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_source_node_pcm_ingest_topology_anchor_only_no_production_source_node_wiring_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_single_kotlin_worker_thread_all_jni_and_audiotrack_calls_direct_bytebuffer_reused_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim_no_in_band_dispose_cancellation_proof_detach_cancellation_source_audited_invariant_only"

        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val HARD_MAX_DURATION_SEC = 2.0
        // Matches the native per-call ingest clamp (8192 frames).
        private const val SCRATCH_FRAMES = 8192
        // Frozen pre-roll windows before play(); the AudioTrack buffer
        // floor guarantees they fit without a blocking write.
        private const val PREROLL_WINDOWS = 2L
        private const val TRACK_BUFFER_MIN_WINDOWS = 4L
        private const val MAX_DRAIN_ITERATIONS = 256
        private const val MAX_CONSECUTIVE_ZERO_WRITES = 500
        private const val ZERO_WRITE_SLEEP_MS = 2L
        private const val HEAD_POLL_SLEEP_MS = 5L
        private const val HEAD_CATCHUP_MARGIN_MS = 3_000L
        private const val TIMESTAMP_SAMPLE_INTERVAL = 16L

        // Stable failure-shaped result (same lane/metric key shape) for a
        // caller that never got a run.
        fun failedResult(reason: String): RunResult =
            AndroidMultiSourceAudioTrackPlaybackSinkDriver()
                .makeResult(pass = false, failureReason = reason)
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
    // Placeholder until run() rebinds with the real deadline; only property
    // reads ever happen against it.
    private var session = AndroidMultiSourceAudioGraphPipelineNativeSession(0L)
    private var pump: AndroidMultiSourceAudioTrackSinkIngestPump? = null

    // Lane telemetry: fail-closed paths still report everything observed.
    private var formatProbeOk = false
    private var audioTrackInitOk = false
    private var prerollOkLane = false
    private var playbackHeadAdvancedOk = false
    private var sinkWriteAccountingOk = false
    private var seekEpochAccountingOk = false
    private var jointDispatchGateOk = false
    private var jointTailFlushOk = false
    private var twoTrackContributionOk = false
    private var referenceMixChecksumOk = false
    private var nativeDrainChecksumMatchesSinkOk = false
    private var trackFrameAxisLockstepOk = false
    private var mixedOutputFrameAccountingOk = false
    private var zeroNativeSteadyStateAllocationOk = false
    private var ownerThreadOk = false
    private var lifecycleOk = false
    private var sampleRate = 0
    private var channelCount = 0
    private var commonBudgetFrames = 0L
    private var totalFramesExtracted = 0L
    private var seekAcceptedFrame = -1L
    private val detailParts = mutableListOf<String>()

    private var audioTrack: AudioTrack? = null
    private var audioTrackReleaseCount = 0
    private var sinkBuffer: ByteBuffer? = null
    private var bytesPerFrame = 0
    private var mfpm = 0L
    private var prerollFrames = 0L
    private var bufferSizeInFrames = 0L
    private var bufferCapacityInFrames = 0L

    // Frame-epoch state: one epoch per AudioTrack write span ([start..seek]
    // and [seek..eos]); flush() opens a new epoch with the head baseline
    // re-read from the track.
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
    private val timestampScratch = AudioTimestamp()

    fun run(runConfig: RunConfig): RunResult {
        config = runConfig
        val deadline = SystemClock.elapsedRealtime() + config.deadlineMs
        runDeadlineMs = deadline
        session = AndroidMultiSourceAudioGraphPipelineNativeSession(deadline)
        mfpm = config.maxFramesPerMix.toLong()
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

            // Missing KEY_PCM_ENCODING means ENCODING_PCM_16BIT.
            fun readOutputFormat(): Triple<Int, Int, Int> {
                val f = dec.outputFormat
                val enc = if (f.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                    f.getInteger(MediaFormat.KEY_PCM_ENCODING)
                } else {
                    AudioFormat.ENCODING_PCM_16BIT
                }
                return Triple(f.getInteger(MediaFormat.KEY_SAMPLE_RATE),
                    f.getInteger(MediaFormat.KEY_CHANNEL_COUNT), enc)
            }

            // Mandatory ordering: probe format -> create AudioTrack
            // (STATE_INITIALIZED) -> create + start the native session with
            // a sink-mode ack-only read -> build the pump -> open epoch 0.
            fun establishSinkAndSession() {
                val (sr, ch, enc) = readOutputFormat()
                if (enc != AudioFormat.ENCODING_PCM_16BIT) {
                    throw FailClosed("unsupported_pcm_encoding:$enc")
                }
                if (ch != 1 && ch != 2) throw FailClosed("unsupported_channel_count:$ch")
                if (sr <= 0) throw FailClosed("invalid_sample_rate:$sr")
                sampleRate = sr
                channelCount = ch
                bytesPerFrame = 2 * ch
                prerollFrames = PREROLL_WINDOWS * mfpm
                commonBudgetFrames = (windowSec * sr).toLong()
                if (commonBudgetFrames <= 0L) throw FailClosed("invalid_common_budget")
                createAudioTrack(sr, ch)
                // One reused direct sink buffer: exactly maxFramesPerMix frames.
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
                pump = AndroidMultiSourceAudioTrackSinkIngestPump(
                    session = session,
                    channelCount = ch,
                    maxFramesPerMix = config.maxFramesPerMix,
                    sourceRingCapacityFrames = config.sourceRingCapacityFrames,
                    commonBudgetFrames = commonBudgetFrames,
                    pollCancellation = { pollCancellation() },
                    readWindowThroughSink = { frames -> readWindowAndWrite(frames) },
                    drainOutputThroughSink = { drainAllOutputThroughSink() },
                )
                openEpoch()
                formatProbeOk = true
            }

            // Identical repeat format change is benign; any drift is malignant.
            fun onOutputFormatChanged() {
                if (!session.isCreated) {
                    establishSinkAndSession()
                    return
                }
                val (sr, ch, enc) = readOutputFormat()
                if (sr != sampleRate || ch != channelCount ||
                    enc != AudioFormat.ENCODING_PCM_16BIT
                ) {
                    throw FailClosed("malignant_format_change")
                }
            }

            // Streams decoder output through the lockstep rig until codec
            // output EOS; input EOS is queued once the extractor passes [endUs].
            fun decodePhase(endUs: Long) {
                val info = MediaCodec.BufferInfo()
                var inputDone = false
                var outputDone = false
                while (!outputDone) {
                    pollCancellation()
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
                                if (info.size % bytesPerFrame != 0) {
                                    dec.releaseOutputBuffer(outIdx, false)
                                    throw FailClosed("codec_chunk_shape_invalid:${info.size}")
                                }
                                val outBuf = dec.getOutputBuffer(outIdx)!!
                                // Copies finish before the codec buffer is
                                // released; only then does any JNI call run.
                                val slices = pump!!.copyCodecChunk(
                                    outBuf, info.offset, info.size, scratch!!
                                )
                                dec.releaseOutputBuffer(outIdx, false)
                                for ((sliceBuf, sliceFrames) in slices) {
                                    totalFramesExtracted += sliceFrames
                                    pump!!.ingestDecodedSlice(sliceBuf, sliceFrames)
                                }
                                pump!!.pumpWhileJointWindows()
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
            pump!!.pumpWhileJointWindows()

            // Joint dispatch gate probe at the sub-window residual.
            session.probeJointDeferral()
            jointDispatchGateOk = session.jointDeferralObserved

            // ── Pre-seek terminal boundary: both tracks EOS together, joint
            // tail flush through the sink, forced play, head catch-up ───────
            pump!!.flushTailAtEosThroughSink()
            playIfPrerolled(force = true)
            waitForHeadCatchUp("pre_seek")
            closeEpochAccounting("epoch0")

            // ── Seek order: axis guard -> pause -> flush -> new epoch
            // (head baseline re-read; counters/head 0) -> native joint seek
            // (awaiting_seek_ack step + ack-only read + writer-EOS-cleared
            // snapshot inside) -> extractor seek -> generator re-anchor ─────
            session.verifySinkSeekBoundaryAlignment()
            val track = audioTrack!!
            track.pause()
            track.flush()
            openEpoch()
            if (epochFramesWritten != 0L || epochFramesReadFromRing != 0L) {
                throw FailClosed("seek_epoch_counters_not_reset")
            }
            if (currentEpochHead() != 0L) throw FailClosed("seek_epoch_head_baseline_not_zero")
            val seekFrame = session.seekToAcceptedFrameBoundary(sinkBuffer!!)
            seekAcceptedFrame = seekFrame
            seekEpochAccountingOk = true
            detailParts.add("seekAcceptedFrame=$seekFrame")
            detailParts.add("post_seek_media_content_overlap_permitted")
            detailParts.add("truncation_beyond_budget_non_claim")

            // PREVIOUS_SYNC may land early (overlap non-claim recorded above).
            extractor.seekTo(seekTargetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val postSeekStartUs =
                extractor.sampleTime.let { if (it >= 0L) it else seekTargetUs }
            dec.flush()
            pump!!.reanchorSyntheticGenerator(seekFrame)
            detailParts.add("postSeekStartUs=$postSeekStartUs")

            // ── Post-seek: remaining window budget through the sink, then
            // the final joint EOS/tail boundary and stop() ──────────────────
            decodePhase(postSeekStartUs + (windowUs - seekTargetUs))
            pump!!.pumpWhileJointWindows()
            pump!!.flushTailAtEosThroughSink()
            playIfPrerolled(force = true)
            waitForHeadCatchUp("final")
            playbackHeadAdvancedOk = currentEpochHead() > 0L
            if (!playbackHeadAdvancedOk) throw FailClosed("playback_head_not_advanced")
            playbackHeadFinal = currentEpochHead()
            finalHeadLagFrames = epochFramesWritten - playbackHeadFinal
            closeEpochAccounting("epoch1")
            track.stop()
            underrunCountCaptured =
                try { track.underrunCount.toLong() } catch (_: Throwable) { -1L }

            jointTailFlushOk = boundariesDrained == 2
            if (!jointTailFlushOk) throw FailClosed("joint_tail_flush_boundary_missing")
            prerollOkLane = prerollEpochsSatisfied == 2
            if (!prerollOkLane) throw FailClosed("preroll_not_satisfied")

            // Owner-thread probe at a quiescent point.
            ownerThreadOk = session.probeForeignThreadRejected()
            if (!ownerThreadOk) throw FailClosed("foreign_thread_not_rejected")

            // ── Final snapshot + verdict lanes ──────────────────────────────
            val snapEnd = session.snapshotMetrics()
            session.verifyNoFaultCounters()
            zeroNativeSteadyStateAllocationOk =
                session.verifyZeroSteadyStateAllocation(snapEnd)
            if (!zeroNativeSteadyStateAllocationOk) {
                throw FailClosed("native_steady_state_allocation_detected")
            }

            // Terminal guard: proves no second output consumption path ran.
            if (framesReadFromRingTotal != session.totalOutputFramesDrained) {
                throw FailClosed("second_output_consumption_path_detected")
            }
            if (framesWrittenTotal <= 0L) throw FailClosed("no_frames_written_to_sink")
            sinkWriteAccountingOk = epochsClosed == 2 &&
                framesReadFromRingTotal == framesWrittenTotal &&
                framesReadFromRingTotal == session.totalOutputFramesDrained
            if (!sinkWriteAccountingOk) throw FailClosed("sink_write_accounting_mismatch")

            // Reference-model verdict — fail-closed inside the pump.
            val verdict = pump!!.verifyReferenceModel(
                String.format("%016x", kotlinSinkChecksum)
            )
            trackFrameAxisLockstepOk = verdict.trackFrameAxisLockstepOk
            mixedOutputFrameAccountingOk = verdict.mixedOutputFrameAccountingOk
            referenceMixChecksumOk = verdict.referenceMixChecksumOk
            nativeDrainChecksumMatchesSinkOk = verdict.nativeDrainChecksumMatchesSinkOk
            twoTrackContributionOk = verdict.twoTrackContributionOk

            // Idempotent native destroy + exactly-once AudioTrack release.
            val nativeLifecycleOk = session.destroyAndVerifyLifecycle()
            releaseAudioTrackOnce(guardedStop = false)
            lifecycleOk = nativeLifecycleOk && audioTrackReleaseCount == 1
            if (!lifecycleOk) throw FailClosed("lifecycle_not_clean")

            return makeResult(pass = true, failureReason = "")
        } catch (e: Throwable) {
            val reason = when (e) {
                is FailClosed -> e.reason
                is AndroidMultiSourceAudioTrackSinkIngestPump.FailClosed -> e.reason
                is AndroidMultiSourceAudioGraphPipelineNativeSession.Failure -> e.reason
                else -> "exception:${e.javaClass.simpleName}:${e.message}"
            }
            return makeResult(pass = false, failureReason = reason)
        } finally {
            // Every path (including dispose cancellation): guarded
            // pause/flush/release exactly once, then codec/extractor
            // release, then native destroy.
            releaseAudioTrackOnce(guardedStop = true)
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
            session.cleanup()
        }
    }

    // ── Sink read -> AudioTrack write (the only output consumption path) ────

    // Reads exactly [frames] frames from the output ring (at most one mix
    // window per read) and writes each read's bytes before reading again.
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
            if (++guard > MAX_DRAIN_ITERATIONS) throw FailClosed("drain_budget_exhausted")
            readWindowAndWrite(minOf(session.outputAvailableReadFrames, mfpm))
        }
    }

    // Kotlin sink-side checksum over exactly the frames handed to
    // AudioTrack.write (same accumulation as native: c = c*31 + uint16).
    private fun accountFramesRead(framesRead: Long) {
        val buf = sinkBuffer!!
        val sampleCount = (framesRead * channelCount).toInt()
        var c = kotlinSinkChecksum
        for (i in 0 until sampleCount) {
            c = c * 31L + (buf.getShort(i * 2).toLong() and 0xFFFFL)
        }
        kotlinSinkChecksum = c
        epochFramesReadFromRing += framesRead
        framesReadFromRingTotal += framesRead
    }

    // Writes [bytes] bytes from offset 0 of the sink buffer with
    // WRITE_NON_BLOCKING, fail-closed on every error code. Partial writes
    // compact/retain the remainder and retry; zero writes park briefly
    // under a bounded budget (the track buffer floor exceeds the pre-roll
    // threshold, so a never-started track cannot fill before the gate).
    private fun writeAllToAudioTrack(bytes: Int) {
        val track = audioTrack ?: throw FailClosed("audio_track_missing")
        val buf = sinkBuffer!!
        buf.position(0)
        buf.limit(bytes)
        var consecutiveZero = 0
        while (buf.hasRemaining()) {
            pollCancellation()
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
                    SystemClock.sleep(ZERO_WRITE_SLEEP_MS)
                    sampleTelemetry()
                }
                // Every negative code fails closed; the code rides in the
                // token (ERROR_INVALID_OPERATION/BAD_VALUE/DEAD_OBJECT/...).
                else -> throw FailClosed("audio_track_write_error:$wrote")
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
        audioTrackInitOk = true
    }

    // Pre-roll gate: play() only after the frozen positive pre-roll frame
    // count is written this epoch, asserting the epoch head is still 0; a
    // forced boundary below the threshold fails closed.
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
    // this epoch; budget = remaining playout time + fixed margin.
    private fun waitForHeadCatchUp(label: String) {
        if (epochFramesWritten == 0L) {
            boundariesDrained++
            return
        }
        if (!epochPlayed) throw FailClosed("head_catchup_without_play")
        val remaining = epochFramesWritten - currentEpochHead()
        val budgetMs = remaining * 1_000L / sampleRate + HEAD_CATCHUP_MARGIN_MS
        val waitDeadline = SystemClock.elapsedRealtime() + budgetMs
        while (true) {
            pollCancellation()
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
        // playbackHeadPosition wraps as an unsigned 32-bit frame counter.
        val track = audioTrack ?: return 0L
        return track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
    }

    private fun currentEpochHead(): Long = rawHead() - epochHeadBaselineRaw

    // One telemetry sample: per-epoch head monotonicity, head-vs-written
    // bound, lag telemetry, periodic conditional AudioTimestamp probe.
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
    // returned timestamp must carry nanoTime > 0 and a non-decreasing
    // framePosition that never exceeds the frames written this epoch.
    private fun attemptTimestamp() {
        timestampAttempts++
        val ok =
            try { audioTrack!!.getTimestamp(timestampScratch) } catch (_: Throwable) { false }
        if (!ok) return
        timestampSuccesses++
        timestampAvailable = true
        val violation = when {
            timestampScratch.nanoTime <= 0L -> "audio_timestamp_nanotime_invalid"
            timestampScratch.framePosition < epochLastTimestampFramePos ->
                "audio_timestamp_regressed"
            timestampScratch.framePosition > epochFramesWritten ->
                "audio_timestamp_ahead_of_written"
            else -> null
        }
        if (violation != null) {
            timestampValid = false
            throw FailClosed(violation)
        }
        epochLastTimestampFramePos = timestampScratch.framePosition
    }

    // ── Cancellation / deadline / cleanup ───────────────────────────────────

    // One combined poll for the dispose flag and the run deadline; the
    // session enforces the same deadline on every JNI call, so this covers
    // the AudioTrack-only write/wait loops.
    private fun pollCancellation() {
        cancellationPollCount++
        if (cancelled()) throw FailClosed("cancelled_by_dispose")
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
        val underruns = underrunCountCaptured.takeIf { it >= 0L }
            ?: try { audioTrack?.underrunCount?.toLong() ?: -1L } catch (_: Throwable) { -1L }
        val p = pump
        val lanes = mapOf<String, Any?>(
            "formatProbeOk" to formatProbeOk,
            "audioTrackInitOk" to audioTrackInitOk,
            "prerollOk" to prerollOkLane,
            "playbackHeadMonotonicOk" to (headSampleCount > 0L && !headMonotonicViolated),
            "playbackHeadAdvancedOk" to playbackHeadAdvancedOk,
            "playbackHeadBoundedOk" to (headSampleCount > 0L && !headBoundViolated),
            "sinkWriteAccountingOk" to sinkWriteAccountingOk,
            "seekEpochAccountingOk" to seekEpochAccountingOk,
            "jointDispatchGateOk" to jointDispatchGateOk,
            "jointTailFlushOk" to jointTailFlushOk,
            "twoTrackContributionOk" to twoTrackContributionOk,
            "referenceMixChecksumOk" to referenceMixChecksumOk,
            "nativeDrainChecksumMatchesSinkOk" to nativeDrainChecksumMatchesSinkOk,
            "trackFrameAxisLockstepOk" to trackFrameAxisLockstepOk,
            "mixedOutputFrameAccountingOk" to mixedOutputFrameAccountingOk,
            "zeroNativeSteadyStateAllocationOk" to zeroNativeSteadyStateAllocationOk,
            "ownerThreadOk" to ownerThreadOk,
            "lifecycleOk" to lifecycleOk,
            "canonical" to pass,
            // Conditional/telemetry lanes: recorded, never required; real
            // dispose cancellation is source-audited, never in-band.
            "cancellationPollingLiveOk" to (cancellationPollCount > 0L),
            "audioTimestampAvailable" to timestampAvailable,
            "audioTimestampValidOk" to (!timestampAvailable || timestampValid),
        )
        val metrics = mapOf<String, Any?>(
            "cancellationPollCount" to cancellationPollCount,
            "sampleRate" to sampleRate,
            "channelCount" to channelCount,
            "commonBudgetFrames" to commonBudgetFrames,
            "framesTruncatedBeyondBudget" to (p?.framesTruncatedBeyondBudget ?: 0L),
            "totalFramesExtracted" to totalFramesExtracted,
            "playbackHeadFinal" to playbackHeadFinal,
            "framesWrittenTotal" to framesWrittenTotal,
            "framesReadFromRingTotal" to framesReadFromRingTotal,
            "partialWriteCount" to partialWriteCount,
            "zeroWriteCount" to zeroWriteCount,
            "getUnderrunCount" to underruns,
            "bufferSizeInFrames" to bufferSizeInFrames,
            "bufferCapacityInFrames" to bufferCapacityInFrames,
            "maxHeadLagFrames" to maxHeadLagFrames,
            "finalHeadLagFrames" to finalHeadLagFrames,
            "prerollFrames" to prerollFrames,
            "prerollEpochsSatisfied" to prerollEpochsSatisfied.toLong(),
            "seekAcceptedFrame" to seekAcceptedFrame,
            "generatorReanchorCount" to (p?.generatorReanchorCount ?: 0L),
            "track1NonZeroSampleCount" to (p?.track1NonZeroSampleCount ?: 0L),
            "totalFramesAcceptedTrack0" to session.totalFramesAcceptedTrack0,
            "totalFramesAcceptedTrack1" to session.totalFramesAcceptedTrack1,
            "totalOutputFramesDrained" to session.totalOutputFramesDrained,
            "dispatchCount" to session.dispatchCount,
            "audioTimestampAttemptCount" to timestampAttempts,
            "audioTimestampSuccessCount" to timestampSuccesses,
            // Per-track accepted checksums are verified in-run by the pump
            // verdict; the payload carries the mix/drain/sink chain only.
            "nativeOutputDrainChecksumHex" to session.nativeOutputDrainChecksumHex,
            "kotlinReferenceMixChecksumHex" to (p?.kotlinReferenceMixChecksumHex ?: ""),
            "kotlinSinkChecksumHex" to String.format("%016x", kotlinSinkChecksum),
            "nativeLastStatus" to session.lastStatus,
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
