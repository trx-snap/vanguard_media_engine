package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidAudioGraphPipelineRealDecoderDriver (P4 True-DAG sub-slice H2) ────
//
// Kotlin-owned real MediaExtractor/MediaCodec streaming decode of the first
// audio track (MIME audio/*) driving the sub-slice H1 closed-loop native
// audio graph pipeline session via
// [AndroidAudioGraphPipelineRealDecoderNativeSession]. This driver owns the
// MediaExtractor/MediaCodec lifecycle, the codec output buffer copy/release
// policy, the decoder output format policy (including benign repeat format
// changes), the watchdog deadline, and the overall step loop; the native
// session component owns every JNI interaction.
//
// Proof shape, all on the single caller thread of [run] (except the
// deliberate foreign-thread probe inside the session that native must
// reject):
//   - Resolve the decoder output format first (PCM16, 1-2 channels only);
//     create + start the native session only once the format is known.
//     A repeated INFO_OUTPUT_FORMAT_CHANGED with identical
//     sampleRate/channelCount/PCM encoding (missing KEY_PCM_ENCODING means
//     PCM16) is benign and counted; any difference is a malignant format
//     change and fails closed.
//   - Every codec output chunk is copied into direct ByteBuffers (one
//     hoisted scratch, plus bounded temporary slices only when a chunk
//     exceeds it) and the codec output buffer is released BEFORE any JNI
//     ingest/step/drain runs. Partially accepted chunks are compacted and
//     retried losslessly; no decoded frame is ever dropped.
//   - Deterministic backpressure lanes (source partial_write + ring_full,
//     output backpressure) run against the native rig with relational
//     assertions only.
//   - The one native seek is on the ACCEPTED-FRAME axis: after a lossless
//     EOS tail flush fully drains the rig at A = totalFramesAccepted, the
//     native seek re-anchors writer/provider/coordinator at exactly A with
//     zero discards and clears the writer-local EOS. The extractor seek is
//     media-local (PREVIOUS_SYNC may land early); post-seek media content
//     overlap with pre-seek content is an explicit non-claim.
//   - decoderEosReachedOk requires the final codec output EOS plus a
//     completed native tail flush; lifecycleOk requires destroy ok, second
//     destroy not_found, and post-destroy snapshot not_found.
//
// Honest non-claims: no AudioTrack/AAudio/OpenSL/Oboe, no audible or
// realtime playback, no export or pass-2 graph reroute, no streaming/cache,
// no iOS, no product/editor UI. Native never owns
// MediaCodec/MediaExtractor, never does file IO, and never reads a wall
// clock; every tick is caller-derived on the accepted-frame axis.
class AndroidAudioGraphPipelineRealDecoderDriver {

    companion object {
        const val PASS_MARKER = "ANDROID_DAG_PHASE4_REAL_DECODER_PIPELINE_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_REAL_DECODER_PIPELINE_SMOKE_FAIL"
        const val PROOF_BOUNDARY =
            "kotlin_owned_real_decoder_step_driven_closed_loop_native_audio_graph_pipeline_session_proof_only_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_native_frame_axis_is_accepted_frame_count_not_media_pts_seek_reanchors_at_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_pre_seek_writer_eos_tail_flush_then_seek_clears_eos_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_no_audio_track_no_aaudio_no_opensl_no_oboe_no_audible_or_realtime_playback_diagnostic_graph_topology_only_no_production_source_node_wiring_no_source_node_pcm_ingest_topology_anchor_only_single_routed_track_unit_gain_only_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim"

        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val HARD_MAX_DURATION_SEC = 2.0

        // Matches the native per-call ingest clamp (AudioDecoderRingWriter
        // kMaxWriteFrames), so every codec chunk that fits the scratch
        // buffer can cross in one ingest call.
        private const val SCRATCH_FRAMES = 8192
    }

    data class RunConfig(
        val sourcePath: String,
        val durationSec: Double = 1.0,
        val seekTargetSec: Double = 0.35,
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
        // Lanes.
        val formatProbeOk: Boolean,
        val decoderBenignFormatChangeObserved: Boolean,
        val decoderEosReachedOk: Boolean,
        val sourcePartialWriteObserved: Boolean,
        val sourceRingFullObserved: Boolean,
        val outputBackpressureObserved: Boolean,
        val checksumIdentityOk: Boolean,
        val frameAccountingOk: Boolean,
        val seekOk: Boolean,
        val tailFlushOk: Boolean,
        val noUnderrunOk: Boolean,
        val noSilenceOk: Boolean,
        val noRingPushShortfallOk: Boolean,
        val noForwardSkipOk: Boolean,
        val noRewindRejectOk: Boolean,
        val finalNotTerminalOk: Boolean,
        val finalSeekAckClearOk: Boolean,
        val zeroNativeSteadyStateAllocationOk: Boolean,
        val ownerThreadOk: Boolean,
        val lifecycleOk: Boolean,
        val canonical: Boolean,
        // Metrics.
        val sampleRate: Int,
        val channelCount: Int,
        val pcmEncoding: Int,
        val totalFramesExtracted: Long,
        val totalFramesAccepted: Long,
        val totalOutputFramesDrained: Long,
        val postSeekFramesAccepted: Long,
        val postSeekFramesDrained: Long,
        val decoderBenignFormatChangeCount: Long,
        val providerUnderrunEvents: Long,
        val providerFramesZeroFilled: Long,
        val providerForwardSkipFrames: Long,
        val providerRewindRejects: Long,
        val coordinatorSilenceCount: Long,
        val nativeAcceptedChecksumHex: String,
        val nativeOutputDrainChecksumHex: String,
        val kotlinAcceptedChecksumHex: String,
        val maxFramesPerMix: Long,
        val sourceAvailableReadFrames: Long,
        val outputAvailableReadFrames: Long,
        val dispatchCount: Long,
        val nextDispatchFrame: Long,
        val nativeLastStatus: String,
    )

    private class FailClosed(val reason: String) : Exception(reason)

    // Mutable telemetry threaded through the run so fail-closed paths still
    // report everything observed up to the failure point.
    private class RunTelemetry {
        var formatProbeOk = false
        var decoderBenignFormatChangeObserved = false
        var decoderEosReachedOk = false
        var checksumIdentityOk = false
        var frameAccountingOk = false
        var seekOk = false
        var tailFlushOk = false
        var noUnderrunOk = false
        var noSilenceOk = false
        var noRingPushShortfallOk = false
        var noForwardSkipOk = false
        var noRewindRejectOk = false
        var finalNotTerminalOk = false
        var finalSeekAckClearOk = false
        var zeroNativeSteadyStateAllocationOk = false
        var ownerThreadOk = false
        var lifecycleOk = false

        var sampleRate = 0
        var channelCount = 0
        var pcmEncoding = 0
        var totalFramesExtracted = 0L
        var postSeekFramesAccepted = 0L
        var postSeekFramesDrained = 0L
        var decoderBenignFormatChangeCount = 0L
        val detailParts = mutableListOf<String>()
    }

    fun run(config: RunConfig): RunResult {
        val t = RunTelemetry()
        val deadline = SystemClock.elapsedRealtime() + config.deadlineMs
        val session = AndroidAudioGraphPipelineRealDecoderNativeSession(deadline)
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null

        try {
            if (config.sourcePath.isBlank()) throw FailClosed("source_path_required")
            val windowSec = minOf(config.durationSec, HARD_MAX_DURATION_SEC)
            if (windowSec <= 0.0) throw FailClosed("invalid_decode_duration")
            // The seek target must leave post-seek budget inside the single
            // proof window: pre-seek decodes [0, seekTarget] and post-seek
            // decodes the remaining (window - seekTarget) of media.
            if (config.seekTargetSec < 0.0 || config.seekTargetSec >= windowSec) {
                throw FailClosed("invalid_seek_target")
            }
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

            var bytesPerFrame = 0
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

            // First format resolution: validates PCM16 + 1-2 channels,
            // creates + starts the native session, hoists the one direct
            // scratch buffer.
            fun establishSession() {
                val (sr, ch, enc) = readOutputFormat()
                if (enc != AudioFormat.ENCODING_PCM_16BIT) {
                    throw FailClosed("unsupported_pcm_encoding:$enc")
                }
                if (ch != 1 && ch != 2) throw FailClosed("unsupported_channel_count:$ch")
                if (sr <= 0) throw FailClosed("invalid_sample_rate:$sr")
                t.sampleRate = sr
                t.channelCount = ch
                t.pcmEncoding = enc
                bytesPerFrame = 2 * ch
                session.create(
                    sr, ch,
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
                    t.decoderBenignFormatChangeObserved = true
                } else {
                    throw FailClosed("malignant_format_change")
                }
            }

            // Streams decoder output into the native session until the codec
            // reports output EOS; input EOS is queued once the extractor
            // passes [endUs] (or runs out of samples).
            fun decodePhase(endUs: Long) {
                val info = MediaCodec.BufferInfo()
                var inputDone = false
                var outputDone = false
                while (!outputDone) {
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
                                if (!session.isCreated) establishSession()
                                val s = scratch!!
                                if (info.size % bytesPerFrame != 0) {
                                    dec.releaseOutputBuffer(outIdx, false)
                                    throw FailClosed("codec_chunk_shape_invalid:${info.size}")
                                }
                                val outBuf = dec.getOutputBuffer(outIdx)!!
                                // Split the codec chunk into slices of at
                                // most the scratch capacity, each copied to
                                // byte offset 0 of a direct buffer (scratch
                                // for the first slice, bounded temporaries
                                // only when the chunk overflows scratch).
                                // All copies finish before the codec output
                                // buffer is released, and only then does any
                                // slice cross into native ingest/step/drain.
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
                                    t.totalFramesExtracted += sliceFrames
                                    session.ingestChunkLossless(sliceBuf, sliceFrames)
                                }
                                session.pumpWhileFullWindows()
                            } else {
                                dec.releaseOutputBuffer(outIdx, false)
                            }
                            if (isEos) outputDone = true
                        }
                        // INFO_TRY_AGAIN_LATER — the deadline bounds the wait.
                    }
                }
            }

            // ── Pre-seek decode: media [0, seekTarget] through the rig ──────
            decodePhase(seekTargetUs)
            if (!session.isCreated) throw FailClosed("no_decoder_output")

            // ── Deterministic backpressure lanes (held scratch data) ────────
            session.runSourceBackpressureLane(scratch!!)
            session.runOutputBackpressureLane(scratch!!)
            session.pumpWhileFullWindows()

            // ── Pre-seek boundary: lossless EOS tail flush, then the one
            // accepted-frame-axis native seek ───────────────────────────────
            session.flushTailAtEos()
            val preSeekAccepted = session.totalFramesAccepted
            val preSeekDrained = session.totalOutputFramesDrained
            val seekFrame = session.seekToAcceptedFrameBoundary()
            t.seekOk = true
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

            // ── Post-seek decode: the remaining window budget only ──────────
            decodePhase(postSeekStartUs + (windowUs - seekTargetUs))
            session.pumpWhileFullWindows()
            session.flushTailAtEos()
            t.tailFlushOk = true
            // Codec output EOS was observed (decodePhase returned) and the
            // native tail flush completed.
            t.decoderEosReachedOk = true
            t.postSeekFramesAccepted = session.totalFramesAccepted - preSeekAccepted
            t.postSeekFramesDrained = session.totalOutputFramesDrained - preSeekDrained

            // ── Owner-thread probe at a quiescent point (no in-flight codec
            // buffer: both decode phases are complete) ──────────────────────
            t.ownerThreadOk = session.probeForeignThreadRejected()
            if (!t.ownerThreadOk) throw FailClosed("foreign_thread_not_rejected")

            // ── Final snapshot + verdict lanes ──────────────────────────────
            val snapEnd = session.snapshotMetrics()
            t.detailParts.add("preSeekFramesAccepted=$preSeekAccepted")
            t.detailParts.add("benignFormatChanges=${t.decoderBenignFormatChangeCount}")

            t.noUnderrunOk = session.providerUnderrunEvents == 0L &&
                session.providerFramesZeroFilled == 0L
            if (!t.noUnderrunOk) throw FailClosed("provider_underrun_observed")
            t.noSilenceOk = session.coordinatorSilenceCount == 0L
            if (!t.noSilenceOk) throw FailClosed("silence_window_observed")
            t.noRingPushShortfallOk = !session.ringPushShortfallSeen
            if (!t.noRingPushShortfallOk) throw FailClosed("ring_push_shortfall_observed")
            t.noForwardSkipOk = session.providerForwardSkipFrames == 0L
            if (!t.noForwardSkipOk) throw FailClosed("provider_forward_skip_observed")
            t.noRewindRejectOk = session.providerRewindRejects == 0L
            if (!t.noRewindRejectOk) throw FailClosed("provider_rewind_reject_observed")
            t.finalNotTerminalOk = !session.snapshotTerminal
            if (!t.finalNotTerminalOk) throw FailClosed("terminal_state_observed")
            t.finalSeekAckClearOk = !session.snapshotAwaitingSeekAck
            if (!t.finalSeekAckClearOk) throw FailClosed("seek_ack_still_pending")
            t.zeroNativeSteadyStateAllocationOk =
                session.verifyZeroSteadyStateAllocation(snapEnd)
            if (!t.zeroNativeSteadyStateAllocationOk) {
                throw FailClosed("native_steady_state_allocation_detected")
            }

            if (session.totalFramesAccepted <= 0L) throw FailClosed("no_frames_accepted")
            if (t.postSeekFramesAccepted <= 0L) throw FailClosed("no_post_seek_frames_accepted")
            if (t.postSeekFramesDrained <= 0L) throw FailClosed("no_post_seek_frames_drained")
            if (!session.sourcePartialWriteObserved) throw FailClosed("partial_write_not_observed")
            if (!session.sourceRingFullObserved) throw FailClosed("ring_full_not_observed")
            if (!session.outputBackpressureObserved) {
                throw FailClosed("output_backpressure_not_observed")
            }

            val kotlinChecksumHex = String.format("%016x", session.kotlinChecksum)
            t.checksumIdentityOk = kotlinChecksumHex == session.nativeAcceptedChecksumHex &&
                kotlinChecksumHex == session.nativeOutputDrainChecksumHex
            if (!t.checksumIdentityOk) throw FailClosed("checksum_identity_mismatch")

            t.frameAccountingOk =
                session.totalFramesAccepted == session.totalOutputFramesDrained &&
                    session.totalFramesAccepted == session.kotlinFramesAccepted
            if (!t.frameAccountingOk) throw FailClosed("frame_accounting_mismatch")

            // ── Lifecycle lane: idempotent any-thread destroy ───────────────
            t.lifecycleOk = session.destroyAndVerifyLifecycle()
            if (!t.lifecycleOk) throw FailClosed("lifecycle_destroy_not_idempotent")

            return makeResult(t, session, config, pass = true, failureReason = "")
        } catch (f: FailClosed) {
            return makeResult(t, session, config, pass = false, failureReason = f.reason)
        } catch (f: AndroidAudioGraphPipelineRealDecoderNativeSession.Failure) {
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
        session: AndroidAudioGraphPipelineRealDecoderNativeSession,
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
        decoderBenignFormatChangeObserved = t.decoderBenignFormatChangeObserved,
        decoderEosReachedOk = t.decoderEosReachedOk,
        sourcePartialWriteObserved = session.sourcePartialWriteObserved,
        sourceRingFullObserved = session.sourceRingFullObserved,
        outputBackpressureObserved = session.outputBackpressureObserved,
        checksumIdentityOk = t.checksumIdentityOk,
        frameAccountingOk = t.frameAccountingOk,
        seekOk = t.seekOk,
        tailFlushOk = t.tailFlushOk,
        noUnderrunOk = t.noUnderrunOk,
        noSilenceOk = t.noSilenceOk,
        noRingPushShortfallOk = t.noRingPushShortfallOk,
        noForwardSkipOk = t.noForwardSkipOk,
        noRewindRejectOk = t.noRewindRejectOk,
        finalNotTerminalOk = t.finalNotTerminalOk,
        finalSeekAckClearOk = t.finalSeekAckClearOk,
        zeroNativeSteadyStateAllocationOk = t.zeroNativeSteadyStateAllocationOk,
        ownerThreadOk = t.ownerThreadOk,
        lifecycleOk = t.lifecycleOk,
        canonical = pass,
        sampleRate = t.sampleRate,
        channelCount = t.channelCount,
        pcmEncoding = t.pcmEncoding,
        totalFramesExtracted = t.totalFramesExtracted,
        totalFramesAccepted = session.totalFramesAccepted,
        totalOutputFramesDrained = session.totalOutputFramesDrained,
        postSeekFramesAccepted = t.postSeekFramesAccepted,
        postSeekFramesDrained = t.postSeekFramesDrained,
        decoderBenignFormatChangeCount = t.decoderBenignFormatChangeCount,
        providerUnderrunEvents = session.providerUnderrunEvents,
        providerFramesZeroFilled = session.providerFramesZeroFilled,
        providerForwardSkipFrames = session.providerForwardSkipFrames,
        providerRewindRejects = session.providerRewindRejects,
        coordinatorSilenceCount = session.coordinatorSilenceCount,
        nativeAcceptedChecksumHex = session.nativeAcceptedChecksumHex,
        nativeOutputDrainChecksumHex = session.nativeOutputDrainChecksumHex,
        kotlinAcceptedChecksumHex = String.format("%016x", session.kotlinChecksum),
        maxFramesPerMix = config.maxFramesPerMix.toLong(),
        sourceAvailableReadFrames = session.sourceAvailableReadFrames,
        outputAvailableReadFrames = session.outputAvailableReadFrames,
        dispatchCount = session.dispatchCount,
        nextDispatchFrame = session.nativeNextDispatchFrame,
        nativeLastStatus = session.lastStatus,
    )
}
