package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidAudioStreamingPcmDecoder (P4 True-DAG V4.3 sub-slice G2) ──────────
//
// Kotlin-owned MediaExtractor/MediaCodec streaming decode of the first audio
// track (MIME audio/*) into the native audio decoder ring-ingest diagnostic
// session (sub-slice G1 JNI seam). Decoded PCM16 codec output chunks are
// copied into one hoisted direct ByteBuffer (byte offset 0), the codec output
// buffer is released, and only then does the chunk cross JNI into
// AudioDecoderRingWriter -> AudioSpscAudioRingBuffer, with the same caller
// thread playing the ring's producer (ingest) and consumer (drain) roles
// sequentially. A codec chunk larger than the hoisted buffer is split into
// bounded slices (each at most the scratch capacity, data at byte offset 0);
// every slice is copied to a direct buffer before the codec output buffer is
// released, so no codec output buffer is ever held across a native call.
//
// Proof shape, all on the single caller thread of [run]:
//   - Resolve the decoder output format first; create the native session only
//     after sampleRate/channelCount/PCM encoding are known. PCM16 and 1-2
//     channels only; anything else fails closed.
//   - Backpressure lane: when the ring backpressures before a partial_write
//     was seen, drain strictly fewer frames than remain so the retry lands a
//     guaranteed partial_write; after a partial_write fills the ring, retry
//     once without draining so native reports writerStatus=ring_full with
//     framesAccepted=0. Both statuses must be observed before PASS.
//   - One real seek: bounded drain loop empties the ring -> native
//     requestSeek -> extractor.seekTo(PREVIOUS_SYNC) -> codec.flush() ->
//     drain consumes the reader-side seek ack (which must discard nothing,
//     since the ring was emptied first — otherwise the drained checksum
//     could not equal the accepted checksum) -> post-seek decode continues
//     into the same session.
//   - Writer-local EOS then a bounded final drain empties the ring.
//   - A separate synthetic probe session proves EOS/seek ordering:
//     ok before EOS, already_eos after EOS, awaiting_seek_ack after a seek
//     request but before the ack drain, ok again after the ack drain.
//   - Native framesAccepted is the source of truth; Kotlin mirrors the native
//     accepted-side checksum (checksum = checksum * 31 + uint16(sample) over
//     exactly the accepted interleaved samples) and the two must match.
//
// Honest non-claims: no threads, no locks, no callbacks, no
// AudioTrack/AAudio/OpenSL/Oboe, no audible or realtime playback, no export
// or cache/streaming route, no app/product/editor wiring, no iOS. Native
// never owns MediaCodec/MediaExtractor and never does file IO here. Decoded
// PCM is never collected into JVM heap arrays; it streams through the one
// hoisted direct buffer (plus bounded temporary direct slice buffers only
// when a single codec chunk exceeds the scratch capacity).
class AndroidAudioStreamingPcmDecoder {

    companion object {
        private const val PASS_MARKER =
            "ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_INGEST_SMOKE_PASS"
        private const val FAIL_MARKER =
            "ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_INGEST_SMOKE_FAIL"
        private const val PROOF_BOUNDARY =
            "kotlin_owned_mediacodec_mediaextractor_streaming_decode_to_jni_decoder_ring_ingest_proof_only_no_cpp_os_decoder_no_mediacodec_or_mediaextractor_ownership_in_cpp_no_cpp_file_io_no_wall_clock_read_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_no_audio_track_no_aaudio_no_opensl_no_oboe_no_audible_or_realtime_playback_no_graph_scheduler_no_mix_bus_no_coordinator_no_closed_loop_sink_no_source_node_wiring_no_resample_no_downmix_channels_1_or_2_only_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_writer_local_eos_only_native_zero_steady_state_allocation_only_jvm_heap_non_claim"

        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val HARD_MAX_DURATION_SEC = 2.0

        // Matches the native per-call ingest clamp (AudioDecoderRingWriter
        // kMaxWriteFrames), so every codec chunk that fits the scratch buffer
        // can cross in one ingest call.
        private const val SCRATCH_FRAMES = 8192

        // When ring_full is hit before any partial_write was observed, drain
        // strictly fewer frames than remain in the chunk so the retry lands a
        // guaranteed partial_write.
        private const val PARTIAL_FORCE_DRAIN_FRAMES = 512L
        private const val MAX_CHUNK_RETRIES = 64
        private const val MAX_FINAL_DRAIN_ITERATIONS = 256

        private const val PROBE_RING_CAPACITY_FRAMES = 64
        private const val PROBE_CHUNK_FRAMES = 32

        // Contract failures whose reason token is surfaced verbatim as the
        // DecodeResult.status (marker stays FAIL); everything else reports the
        // generic "fail" status with the reason in failureReason.
        private val STABLE_FAILURE_STATUSES = setOf(
            "unsupported_channel_count",
            "unsupported_pcm_encoding",
            "mid_stream_format_change",
            "deadline_exceeded",
            "native_session_create_failed",
            "accepted_checksum_mismatch",
            "drained_checksum_mismatch",
            "frame_accounting_mismatch",
            "partial_write_not_observed",
            "ring_full_not_observed",
            "seek_ack_not_consumed",
        )
    }

    data class DecodeConfig(
        val sourcePath: String,
        val durationSec: Double = 1.0,
        val seekTargetSec: Double = 0.35,
        val ringCapacityFrames: Int = 4096,
        val maxDurationSec: Double = 2.0,
        val deadlineMs: Long = 30000L,
    )

    data class DecodeResult(
        val pass: Boolean,
        val status: String,
        val marker: String,
        val sampleRate: Int,
        val channelCount: Int,
        val pcmEncoding: Int,
        val totalFramesAccepted: Long,
        val totalFramesDrained: Long,
        val postSeekFramesAccepted: Long,
        val postSeekFramesDrained: Long,
        val kotlinAcceptedChecksumHex: String,
        val nativeAcceptedChecksumHex: String,
        val nativeDrainedChecksumHex: String,
        val observedPartialWrite: Boolean,
        val observedRingFull: Boolean,
        val syntheticProbeChunk: Boolean,
        val eosAlreadyEosStatus: String,
        val eosAwaitingSeekAckStatus: String,
        val eosPostAckStatus: String,
        val midStreamFormatChangeRejected: Boolean,
        val seekAckObserved: Boolean,
        val discardedFramesOnSeek: Long,
        val newStartFrame: Long,
        val failureReason: String,
        val details: String,
        val proofBoundary: String,
    )

    private class FailClosed(val reason: String) : Exception(reason)

    // Mutable telemetry threaded through the run so fail-closed paths still
    // report everything observed up to the failure point.
    private class RunTelemetry {
        var sampleRate = 0
        var channelCount = 0
        var pcmEncoding = 0
        var kotlinChecksum = 0L
        var nativeAcceptedChecksumHex = ""
        var nativeDrainedChecksumHex = ""
        var totalFramesAccepted = 0L
        var totalFramesDrained = 0L
        var postSeekFramesAccepted = 0L
        var postSeekFramesDrained = 0L
        var observedPartialWrite = false
        var observedRingFull = false
        var syntheticProbeChunk = false
        var eosAlreadyEosStatus = ""
        var eosAwaitingSeekAckStatus = ""
        var eosPostAckStatus = ""
        var midStreamFormatChangeRejected = false
        var seekAckObserved = false
        var discardedFramesOnSeek = 0L
        var newStartFrame = -1L
        val detailParts = mutableListOf<String>()
    }

    fun run(config: DecodeConfig): DecodeResult {
        val t = RunTelemetry()
        val deadline = SystemClock.elapsedRealtime() + config.deadlineMs
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var sessionHandle = 0L
        var probeHandle = 0L

        try {
            if (config.sourcePath.isBlank()) throw FailClosed("source_path_required")
            val windowSec = minOf(config.durationSec, config.maxDurationSec, HARD_MAX_DURATION_SEC)
            if (windowSec <= 0.0) throw FailClosed("invalid_decode_duration")
            // The seek target must leave post-seek budget inside the single
            // proof window: pre-seek decodes [0, seekTarget] and post-seek
            // decodes the remaining (window - seekTarget) of media, so total
            // ingested media duration stays <= windowSec.
            if (config.seekTargetSec < 0.0 || config.seekTargetSec >= windowSec) {
                throw FailClosed("invalid_seek_target")
            }
            val windowUs = (windowSec * 1_000_000.0).toLong()

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

            var resolvedSampleRate = -1
            var resolvedChannelCount = -1
            var resolvedPcmEncoding = -1
            var bytesPerFrame = 0
            var scratch: ByteBuffer? = null

            // Resolves the decoder output format exactly once: it validates
            // PCM16 + 1-2 channels, creates the native session, and hoists the
            // single direct scratch buffer. Any format resolution after the
            // native session exists fails closed as a mid-stream change, even
            // if the resolved values are identical.
            fun resolveOutputFormat() {
                if (sessionHandle != 0L) {
                    t.midStreamFormatChangeRejected = true
                    throw FailClosed("mid_stream_format_change")
                }
                val f = dec.outputFormat
                val sr = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                val ch = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                val enc = if (f.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                    f.getInteger(MediaFormat.KEY_PCM_ENCODING)
                } else {
                    AudioFormat.ENCODING_PCM_16BIT
                }
                if (enc != AudioFormat.ENCODING_PCM_16BIT) {
                    throw FailClosed("unsupported_pcm_encoding:$enc")
                }
                if (ch != 1 && ch != 2) throw FailClosed("unsupported_channel_count:$ch")
                if (sr <= 0) throw FailClosed("invalid_sample_rate:$sr")
                resolvedSampleRate = sr
                resolvedChannelCount = ch
                resolvedPcmEncoding = enc
                t.sampleRate = sr
                t.channelCount = ch
                t.pcmEncoding = enc
                bytesPerFrame = 2 * ch
                sessionHandle = VanguardNativeBridge.createAudioDecoderRingIngestSmokeSession(
                    sr, ch, config.ringCapacityFrames,
                )
                if (sessionHandle == 0L) throw FailClosed("native_session_create_failed")
                scratch = ByteBuffer.allocateDirect(SCRATCH_FRAMES * bytesPerFrame)
                    .order(ByteOrder.LITTLE_ENDIAN)
            }

            // One reader-side drain on the real session; returns the parsed
            // status map and folds the native drained totals (and any seek
            // ack telemetry) into the run telemetry.
            fun drainOnce(maxFrames: Int): Map<String, String> {
                val kv = parseStatus(
                    VanguardNativeBridge.drainAudioDecoderRingIngestSession(sessionHandle, maxFrames)
                )
                if (kv["status"] != "ok") throw FailClosed("drain_status_${kv["status"]}")
                t.totalFramesDrained = longField(kv, "nativeTotalFramesDrained")
                t.nativeDrainedChecksumHex = kv["nativeDrainedChecksumHex"] ?: ""
                if (kv["seekAckConsumed"] == "true") {
                    t.seekAckObserved = true
                    t.discardedFramesOnSeek = longField(kv, "discardedFramesOnSeek")
                    t.newStartFrame = longField(kv, "newStartFrame")
                }
                return kv
            }

            // Ingests the chunk held at byte offset 0 of [s] (the hoisted
            // scratch buffer for normal chunks, or a bounded temporary direct
            // slice buffer for oversized codec chunks), retrying through ring
            // backpressure. The codec output buffer is already released by the
            // time this runs; [s] is the only Kotlin-side copy and is
            // compacted in place after each partial acceptance so unwritten
            // frames always sit at byte offset 0.
            var skippedDrainAfterPartialForRingFullProbe = false
            fun ingestDirectChunk(s: ByteBuffer, chunkFrames: Int) {
                var remaining = chunkFrames
                var retries = 0
                while (remaining > 0) {
                    checkDeadline()
                    if (++retries > MAX_CHUNK_RETRIES) {
                        throw FailClosed("chunk_retry_budget_exhausted")
                    }
                    val kv = parseStatus(
                        VanguardNativeBridge.ingestAudioDecoderRingPcm16(sessionHandle, s, remaining)
                    )
                    if (kv["status"] != "ok") throw FailClosed("ingest_status_${kv["status"]}")
                    val accepted = longField(kv, "framesAccepted")
                    val writerStatus = kv["writerStatus"] ?: ""
                    when (writerStatus) {
                        "ok" -> {}
                        "partial_write" -> t.observedPartialWrite = true
                        "ring_full" -> t.observedRingFull = true
                        else -> throw FailClosed("unexpected_writer_status_$writerStatus")
                    }
                    t.totalFramesAccepted = longField(kv, "nativeTotalFramesAccepted")
                    t.nativeAcceptedChecksumHex = kv["nativeAcceptedChecksumHex"] ?: ""
                    if (accepted > 0) {
                        // Mirror the native accepted-side checksum over exactly
                        // the accepted interleaved samples (absolute reads —
                        // scratch position is irrelevant to native and to us).
                        val sampleCount = (accepted * resolvedChannelCount).toInt()
                        var c = t.kotlinChecksum
                        for (i in 0 until sampleCount) {
                            c = c * 31 + (s.getShort(i * 2).toLong() and 0xFFFFL)
                        }
                        t.kotlinChecksum = c
                        if (accepted < remaining) {
                            s.position((accepted * bytesPerFrame).toInt())
                            s.limit(remaining * bytesPerFrame)
                            s.compact()
                        }
                        remaining -= accepted.toInt()
                    }
                    if (remaining > 0) {
                        // A partial_write left the ring full. While ring_full
                        // is still unobserved, retry once without draining so
                        // the next native ingest sees the full ring and
                        // reports writerStatus=ring_full (framesAccepted=0)
                        // for real, rather than the drain hiding that state.
                        if (writerStatus == "partial_write" &&
                            !t.observedRingFull &&
                            !skippedDrainAfterPartialForRingFullProbe
                        ) {
                            skippedDrainAfterPartialForRingFullProbe = true
                            continue
                        }
                        // Ring is out of space. Before the first partial_write
                        // is observed, free strictly fewer frames than remain
                        // so the retry is a guaranteed partial acceptance;
                        // afterwards drain generously to make progress.
                        val drainFrames = if (!t.observedPartialWrite && remaining > 1) {
                            minOf((remaining - 1).toLong(), PARTIAL_FORCE_DRAIN_FRAMES)
                        } else {
                            config.ringCapacityFrames.toLong()
                        }
                        val drained = longField(drainOnce(drainFrames.toInt()), "framesDrained")
                        if (drained == 0L && writerStatus == "ring_full") {
                            throw FailClosed("ring_full_drain_stall")
                        }
                    }
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
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> resolveOutputFormat()
                        outIdx >= 0 -> {
                            val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                            if (info.size > 0) {
                                if (sessionHandle == 0L) resolveOutputFormat()
                                val s = scratch!!
                                if (info.size % bytesPerFrame != 0) {
                                    dec.releaseOutputBuffer(outIdx, false)
                                    throw FailClosed("codec_chunk_shape_invalid:${info.size}")
                                }
                                val outBuf = dec.getOutputBuffer(outIdx)!!
                                // Split the codec chunk into slices of at most
                                // the scratch capacity, each copied to byte
                                // offset 0 of a direct buffer (scratch for the
                                // first slice, bounded temporaries only when
                                // the chunk overflows scratch). All copies
                                // finish before the codec output buffer is
                                // released, and only then does any slice cross
                                // into native ingest/retry/drain.
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
                                // before any native ingest/retry/drain runs.
                                dec.releaseOutputBuffer(outIdx, false)
                                for ((sliceBuf, sliceFrames) in slices) {
                                    ingestDirectChunk(sliceBuf, sliceFrames)
                                }
                            } else {
                                dec.releaseOutputBuffer(outIdx, false)
                            }
                            if (isEos) outputDone = true
                        }
                        // INFO_TRY_AGAIN_LATER — the deadline bounds the wait.
                    }
                }
            }

            // ── Pre-seek decode: only up to the seek target, so pre-seek
            // plus post-seek media stays within the single proof window ──────
            val seekTargetUs = (config.seekTargetSec * 1_000_000.0).toLong()
            decodePhase(seekTargetUs)
            if (sessionHandle == 0L) throw FailClosed("no_decoder_output")

            // ── One real seek ────────────────────────────────────────────────
            // Fully drain the ring before requesting the seek so the ack finds
            // no stale unread frames: any frames discarded at the ack boundary
            // would be excluded from the native drained checksum, making the
            // three-way checksum identity in the verdict impossible.
            var preSeekDrainIterations = 0
            while (true) {
                checkDeadline()
                if (++preSeekDrainIterations > MAX_FINAL_DRAIN_ITERATIONS) {
                    throw FailClosed("pre_seek_drain_budget_exhausted")
                }
                if (longField(drainOnce(config.ringCapacityFrames), "availableReadAfterDrain") == 0L) {
                    break
                }
            }
            t.detailParts.add("preSeekDrainIterations=$preSeekDrainIterations")
            val targetFrame = (config.seekTargetSec * resolvedSampleRate).toLong()
            val seekKv = parseStatus(
                VanguardNativeBridge.requestAudioDecoderRingIngestSeek(sessionHandle, targetFrame)
            )
            if (seekKv["status"] != "ok") throw FailClosed("seek_request_${seekKv["status"]}")
            extractor.seekTo(seekTargetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            // PREVIOUS_SYNC may land before the target; budgeting from the
            // actual landing time keeps post-seek media at exactly the
            // remaining (window - seekTarget) so the total stays <= windowSec.
            val postSeekStartUs =
                extractor.sampleTime.let { if (it >= 0L) it else seekTargetUs }
            dec.flush()
            drainOnce(config.ringCapacityFrames)
            if (!t.seekAckObserved) throw FailClosed("seek_ack_not_consumed")
            if (t.newStartFrame != targetFrame) throw FailClosed("seek_new_start_frame_mismatch")
            // The pre-seek full drain guaranteed an empty ring at the ack
            // boundary, so the ack must not have discarded anything.
            if (t.discardedFramesOnSeek != 0L) {
                throw FailClosed("seek_discarded_frames_nonzero")
            }
            t.detailParts.add("seekTargetFrame=$targetFrame")

            // ── Post-seek decode: the remaining window budget only ───────────
            val baseAccepted = t.totalFramesAccepted
            val baseDrained = t.totalFramesDrained
            decodePhase(postSeekStartUs + (windowUs - seekTargetUs))
            t.postSeekFramesAccepted = t.totalFramesAccepted - baseAccepted

            // ── Writer EOS + bounded final drain ─────────────────────────────
            val eosKv = parseStatus(VanguardNativeBridge.setAudioDecoderRingIngestEos(sessionHandle))
            if (eosKv["status"] != "ok" || eosKv["eos"] != "true") {
                throw FailClosed("eos_set_failed_${eosKv["status"]}")
            }
            var finalDrainIterations = 0
            while (true) {
                checkDeadline()
                if (++finalDrainIterations > MAX_FINAL_DRAIN_ITERATIONS) {
                    throw FailClosed("final_drain_budget_exhausted")
                }
                val kv = drainOnce(config.ringCapacityFrames)
                if (longField(kv, "framesDrained") == 0L &&
                    longField(kv, "availableReadAfterDrain") == 0L
                ) {
                    break
                }
            }
            t.postSeekFramesDrained = t.totalFramesDrained - baseDrained
            t.detailParts.add("finalDrainIterations=$finalDrainIterations")

            // ── Synthetic probe session: EOS/seek ordering proof ─────────────
            probeHandle = VanguardNativeBridge.createAudioDecoderRingIngestSmokeSession(
                resolvedSampleRate, resolvedChannelCount, PROBE_RING_CAPACITY_FRAMES,
            )
            if (probeHandle == 0L) throw FailClosed("probe_session_create_failed")
            val probeChunk = ByteBuffer.allocateDirect(PROBE_CHUNK_FRAMES * bytesPerFrame)
                .order(ByteOrder.LITTLE_ENDIAN)
            for (i in 0 until PROBE_CHUNK_FRAMES * resolvedChannelCount) {
                probeChunk.putShort(i * 2, (i * 257).toShort())
            }
            t.syntheticProbeChunk = true

            fun probeIngestWriterStatus(): String {
                val kv = parseStatus(
                    VanguardNativeBridge.ingestAudioDecoderRingPcm16(
                        probeHandle, probeChunk, PROBE_CHUNK_FRAMES,
                    )
                )
                if (kv["status"] != "ok") throw FailClosed("probe_ingest_status_${kv["status"]}")
                return kv["writerStatus"] ?: ""
            }

            val probePreEosStatus = probeIngestWriterStatus()
            if (probePreEosStatus != "ok") throw FailClosed("probe_pre_eos_status_$probePreEosStatus")
            t.detailParts.add("probePreEos=$probePreEosStatus")

            val probeEosKv = parseStatus(VanguardNativeBridge.setAudioDecoderRingIngestEos(probeHandle))
            if (probeEosKv["status"] != "ok") throw FailClosed("probe_eos_set_failed")
            t.eosAlreadyEosStatus = probeIngestWriterStatus()

            val probeSeekKv = parseStatus(
                VanguardNativeBridge.requestAudioDecoderRingIngestSeek(probeHandle, 0L)
            )
            if (probeSeekKv["status"] != "ok") throw FailClosed("probe_seek_request_failed")
            t.eosAwaitingSeekAckStatus = probeIngestWriterStatus()

            val probeAckKv = parseStatus(
                VanguardNativeBridge.drainAudioDecoderRingIngestSession(
                    probeHandle, PROBE_RING_CAPACITY_FRAMES,
                )
            )
            if (probeAckKv["seekAckConsumed"] != "true") throw FailClosed("probe_seek_ack_not_consumed")
            t.eosPostAckStatus = probeIngestWriterStatus()

            // ── Verdict ──────────────────────────────────────────────────────
            if (!t.observedPartialWrite) throw FailClosed("partial_write_not_observed")
            if (!t.observedRingFull) throw FailClosed("ring_full_not_observed")
            if (t.totalFramesAccepted <= 0L) throw FailClosed("no_frames_accepted")
            if (t.postSeekFramesAccepted <= 0L) throw FailClosed("no_post_seek_frames_accepted")
            // Three-way identity after the final real-session drain: the
            // Kotlin accepted mirror, the native accepted checksum, and the
            // native drained checksum must all match.
            val kotlinChecksumHex = String.format("%016x", t.kotlinChecksum)
            if (kotlinChecksumHex != t.nativeAcceptedChecksumHex) {
                throw FailClosed("accepted_checksum_mismatch")
            }
            if (kotlinChecksumHex != t.nativeDrainedChecksumHex) {
                throw FailClosed("drained_checksum_mismatch")
            }
            if (t.totalFramesDrained + t.discardedFramesOnSeek != t.totalFramesAccepted) {
                throw FailClosed("frame_accounting_mismatch")
            }
            if (t.eosAlreadyEosStatus != "already_eos") throw FailClosed("probe_already_eos_status")
            if (t.eosAwaitingSeekAckStatus != "awaiting_seek_ack") {
                throw FailClosed("probe_awaiting_seek_ack_status")
            }
            if (t.eosPostAckStatus != "ok") throw FailClosed("probe_post_ack_status")

            return makeResult(t, pass = true, failureReason = "")
        } catch (f: FailClosed) {
            return makeResult(t, pass = false, failureReason = f.reason)
        } catch (e: Throwable) {
            return makeResult(
                t, pass = false,
                failureReason = "exception:${e.javaClass.simpleName}:${e.message}",
            )
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
            if (sessionHandle != 0L) {
                try {
                    VanguardNativeBridge.destroyAudioDecoderRingIngestSmokeSession(sessionHandle)
                } catch (_: Throwable) {}
            }
            if (probeHandle != 0L) {
                try {
                    VanguardNativeBridge.destroyAudioDecoderRingIngestSmokeSession(probeHandle)
                } catch (_: Throwable) {}
            }
        }
    }

    private fun makeResult(t: RunTelemetry, pass: Boolean, failureReason: String): DecodeResult =
        DecodeResult(
            pass = pass,
            status = when {
                pass -> "pass"
                failureReason.substringBefore(':') in STABLE_FAILURE_STATUSES ->
                    failureReason.substringBefore(':')
                else -> "fail"
            },
            marker = if (pass) PASS_MARKER else FAIL_MARKER,
            sampleRate = t.sampleRate,
            channelCount = t.channelCount,
            pcmEncoding = t.pcmEncoding,
            totalFramesAccepted = t.totalFramesAccepted,
            totalFramesDrained = t.totalFramesDrained,
            postSeekFramesAccepted = t.postSeekFramesAccepted,
            postSeekFramesDrained = t.postSeekFramesDrained,
            kotlinAcceptedChecksumHex = String.format("%016x", t.kotlinChecksum),
            nativeAcceptedChecksumHex = t.nativeAcceptedChecksumHex,
            nativeDrainedChecksumHex = t.nativeDrainedChecksumHex,
            observedPartialWrite = t.observedPartialWrite,
            observedRingFull = t.observedRingFull,
            syntheticProbeChunk = t.syntheticProbeChunk,
            eosAlreadyEosStatus = t.eosAlreadyEosStatus,
            eosAwaitingSeekAckStatus = t.eosAwaitingSeekAckStatus,
            eosPostAckStatus = t.eosPostAckStatus,
            midStreamFormatChangeRejected = t.midStreamFormatChangeRejected,
            seekAckObserved = t.seekAckObserved,
            discardedFramesOnSeek = t.discardedFramesOnSeek,
            newStartFrame = t.newStartFrame,
            failureReason = failureReason,
            details = t.detailParts.joinToString("|"),
            proofBoundary = PROOF_BOUNDARY,
        )

    private fun parseStatus(raw: String): Map<String, String> =
        raw.split(';').mapNotNull { part ->
            val idx = part.indexOf('=')
            if (idx <= 0) null else part.substring(0, idx) to part.substring(idx + 1)
        }.toMap()

    private fun longField(kv: Map<String, String>, key: String): Long =
        kv[key]?.toLongOrNull() ?: throw FailClosed("missing_status_field_$key")
}
