package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidNodeOwnedAudioSourceRealDecoderDriver ─────────────────────────────
// (P4-AUDIO-REAL-DECODER-NODE-OWNED-PIPELINE, sub-slice of
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS)
//
// Kotlin-owned real MediaExtractor/MediaCodec streaming decode of the first
// audio track (MIME audio/*) driving the NODE-OWNED closed-loop native audio
// graph pipeline session: DecodedAudioPcmSourceNode (6-arg constructor) owns
// its source ring/writer/provider triple by composition and
// GraphAudioScheduler auto-discovers the provider from graph topology alone.
// Adapts the proven sub-slice H2 real-decoder lifecycle (format-first session
// creation, benign repeat format changes, lossless slice/compact/retry
// ingest, accepted-frame-axis seek) onto the node-owned JNI seam only:
// create/ingest/start/step/drain/seek/EOS/snapshot/destroy of the
// NodeOwnedAudioSourceGraphPipeline session family.
//
// Proof shape, all on the single caller thread of [run]:
//   - Resolve the decoder output format first (PCM16, 1-2 channels only);
//     create the node-owned session only once the format is known, with
//     expectedFrameCount = 10 * sampleRate — the node's own constructor
//     ceiling — so the node's isActiveAt timeline window deterministically
//     covers the whole pre+post-seek accepted-frame axis (<= ~2x the 2 s
//     hard window cap plus sync-point overlap, well under 10 s) and no
//     window is ever timeline-gated into silence during the proof.
//   - Every codec output chunk is copied into direct little-endian
//     ByteBuffers (one hoisted scratch, plus bounded temporary slices only
//     when a chunk exceeds it) and the codec output buffer is released
//     BEFORE any JNI ingest/step/drain runs. Partially accepted chunks are
//     compacted to byte offset 0 and retried losslessly after pumping full
//     windows; no decoded frame is ever dropped and no decoded PCM is held
//     in JVM heap collections.
//   - The one native seek is on the ACCEPTED-FRAME axis: after a lossless
//     EOS tail flush fully drains the rig at A = totalFramesAccepted, the
//     native seek re-anchors writer/provider/coordinator at exactly A with
//     zero discards and clears the writer-local EOS. The extractor seek is
//     media-local (PREVIOUS_SYNC may land early); post-seek media content
//     overlap with pre-seek content is an explicit non-claim.
//   - Verdict lanes: checksum identity across Kotlin accepted, native
//     accepted, and native output drained; accepted == drained == dispatched
//     frame accounting; seek ack consumed cleanly; zero provider
//     underruns/zero-fill/forward-skip/rewind-rejects; zero coordinator
//     silence windows; routeDiscoveryOk + nodeOwnsRingOk from the snapshot;
//     fixed-at-construction scratch/storage capacities unchanged across the
//     run (zero native steady-state allocation); idempotent any-thread
//     destroy.
//
// Honest non-claims: see [PROOF_BOUNDARY]. Native never owns
// MediaCodec/MediaExtractor, never does file IO, never reads a wall clock,
// and spawns no worker threads; Kotlin owns the decoder lifecycle and the
// temp media path only.
class AndroidNodeOwnedAudioSourceRealDecoderDriver {

    companion object {
        const val PASS_MARKER = "ANDROID_DAG_PHASE4_NODE_OWNED_REAL_DECODER_PIPELINE_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_NODE_OWNED_REAL_DECODER_PIPELINE_SMOKE_FAIL"
        const val PROOF_BOUNDARY =
            "kotlin_owned_real_decoder_to_node_owned_decoded_audio_source_graph_pipeline_proof_only_source_node_owns_ring_writer_provider_by_composition_scheduler_auto_discovers_provider_from_graph_topology_kotlin_owns_mediaextractor_mediacodec_and_temp_media_path_only_no_cpp_os_decoder_ownership_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_no_native_worker_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_destroy_idempotent_any_thread_native_frame_axis_is_accepted_frame_count_not_media_pts_seek_reanchors_at_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_no_audio_track_no_aaudio_no_opensl_no_oboe_no_audible_no_speaker_no_latency_no_glitch_no_realtime_av_sync_no_audio_focus_no_route_no_dead_object_recovery_claims_no_production_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_streaming_no_cache_no_ios_single_routed_track_unit_gain_only_no_resample_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim"

        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val HARD_MAX_DURATION_SEC = 2.0
        private const val ANCHOR_SYS_TIME_NS = 1_000_000_000L
        private const val EXPECTED_SOURCE_NODE_ID = "node_owned_pipeline_src"

        // expectedFrameCount = this * sampleRate: the DecodedAudioPcmSourceNode
        // constructor's own upper bound (10 s of frames). Deterministically
        // covers the whole pre+post-seek accepted-frame axis of a <= 2 s
        // proof window (pre-seek + post-seek + PREVIOUS_SYNC re-decode
        // overlap is bounded by ~2x the window), so isActiveAt never gates a
        // dispatched window inside the proof.
        private const val EXPECTED_FRAME_SECONDS = 10

        // Matches the native per-call ingest clamp (AudioDecoderRingWriter
        // kMaxWriteFrames), so every codec chunk that fits the scratch
        // buffer can cross in one ingest call.
        private const val SCRATCH_FRAMES = 8192

        // Strict bound on tail-flush step iterations: the source ring drains
        // by at least one frame per rendering step, and the largest legal
        // ring is 65536 frames at maxFramesPerMix >= 1.
        private const val MAX_TAIL_FLUSH_STEPS = 65_600
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
        val routeDiscoveryOk: Boolean,
        val nodeOwnsRingOk: Boolean,
        val checksumIdentityOk: Boolean,
        val frameAccountingOk: Boolean,
        val seekOk: Boolean,
        val tailFlushOk: Boolean,
        val noUnderrunOk: Boolean,
        val noSilenceOk: Boolean,
        val noForwardSkipOk: Boolean,
        val noRewindRejectOk: Boolean,
        val finalNotTerminalOk: Boolean,
        val finalSeekAckClearOk: Boolean,
        val zeroNativeSteadyStateAllocationOk: Boolean,
        val lifecycleOk: Boolean,
        val canonical: Boolean,
        // Metrics.
        val sampleRate: Int,
        val channelCount: Int,
        val pcmEncoding: Int,
        val expectedFrameCount: Long,
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
        val dispatchCount: Long,
        val nativeAcceptedChecksumHex: String,
        val nativeOutputDrainChecksumHex: String,
        val kotlinAcceptedChecksumHex: String,
        val maxFramesPerMix: Long,
        val sourceAvailableReadFrames: Long,
        val outputAvailableReadFrames: Long,
        val nextDispatchFrame: Long,
    )

    private class FailClosed(val reason: String) : Exception(reason)

    // Mutable telemetry threaded through the run so fail-closed paths still
    // report everything observed up to the failure point.
    private class Telemetry {
        var formatProbeOk = false
        var decoderBenignFormatChangeObserved = false
        var decoderEosReachedOk = false
        var routeDiscoveryOk = false
        var nodeOwnsRingOk = false
        var checksumIdentityOk = false
        var frameAccountingOk = false
        var seekOk = false
        var tailFlushOk = false
        var noUnderrunOk = false
        var noSilenceOk = false
        var noForwardSkipOk = false
        var noRewindRejectOk = false
        var finalNotTerminalOk = false
        var finalSeekAckClearOk = false
        var zeroNativeSteadyStateAllocationOk = false
        var lifecycleOk = false

        var sampleRate = 0
        var channelCount = 0
        var pcmEncoding = 0
        var expectedFrameCount = 0L
        var totalFramesExtracted = 0L
        var kotlinChecksum = 0L
        var kotlinFramesAccepted = 0L
        var totalFramesAccepted = 0L
        var totalOutputFramesDrained = 0L
        var postSeekFramesAccepted = 0L
        var postSeekFramesDrained = 0L
        var decoderBenignFormatChangeCount = 0L
        var providerUnderrunEvents = -1L
        var providerFramesZeroFilled = -1L
        var providerForwardSkipFrames = -1L
        var providerRewindRejects = -1L
        var coordinatorSilenceCount = -1L
        var dispatchCount = 0L
        var nativeAcceptedChecksumHex = ""
        var nativeOutputDrainChecksumHex = ""
        var sourceAvailableReadFrames = -1L
        var outputAvailableReadFrames = -1L
        var nextDispatchFrame = -1L
        val detailParts = mutableListOf<String>()
    }

    fun run(config: RunConfig): RunResult {
        val t = Telemetry()
        val deadline = SystemClock.elapsedRealtime() + config.deadlineMs
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var handle = 0L

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
            val mfpm = config.maxFramesPerMix.toLong()

            // ── Caller-derived tick math on the accepted-frame axis,
            // re-based at start() and seek() ────────────────────────────────
            var anchorPtsUs = 0L
            var anchorSysNs = ANCHOR_SYS_TIME_NS
            var lastTickNs = Long.MIN_VALUE

            fun ceilDiv(a: Long, b: Long): Long = (a + b - 1) / b

            fun tickForFrame(frame: Long): Long {
                val ptsUs = ceilDiv(frame * 1_000_000L, t.sampleRate.toLong())
                val tick = anchorSysNs + (ptsUs - anchorPtsUs) * 1_000L
                if (tick < lastTickNs) throw FailClosed("non_monotonic_driver_tick")
                lastTickNs = tick
                return tick
            }

            // ── Node-owned session state mirrored from statuses ─────────────
            // nextFrame is the dispatch cursor on the accepted-frame axis;
            // sourceAvail mirrors the last reported source ring occupancy.
            var nextFrame = 0L
            var sourceAvail = 0L

            // Fixed-at-construction capacity baseline, captured right after
            // create for the zero-steady-state-allocation lane.
            var schedCapBefore = -1L
            var schedTracksBefore = -1L
            var srcCapBefore = -1L
            var outCapBefore = -1L

            fun snapshot(): Map<String, String> {
                val kv = parseStatus(
                    VanguardNativeBridge.snapshotNodeOwnedAudioSourceGraphPipeline(handle)
                )
                if (kv["status"] != "ok") throw FailClosed("snapshot_status_${kv["status"]}")
                t.providerUnderrunEvents = longField(kv, "providerUnderrunEvents")
                t.providerFramesZeroFilled = longField(kv, "providerFramesZeroFilled")
                t.providerForwardSkipFrames = longField(kv, "providerForwardSkipFrames")
                t.providerRewindRejects = longField(kv, "providerRewindRejects")
                t.coordinatorSilenceCount = longField(kv, "silenceCount")
                t.totalFramesAccepted = longField(kv, "totalFramesAccepted")
                t.totalOutputFramesDrained = longField(kv, "totalOutputFramesDrained")
                t.nativeAcceptedChecksumHex = kv["nativeAcceptedChecksumHex"] ?: ""
                t.nativeOutputDrainChecksumHex = kv["nativeOutputDrainChecksumHex"] ?: ""
                t.sourceAvailableReadFrames = longField(kv, "sourceAvailableReadFrames")
                t.outputAvailableReadFrames = longField(kv, "outputAvailableReadFrames")
                t.dispatchCount = longField(kv, "dispatchCount")
                t.nextDispatchFrame = longField(kv, "nextDispatchFrame")
                return kv
            }

            fun step(sysTimeNs: Long, flushTail: Boolean): Map<String, String> {
                checkDeadline()
                val kv = parseStatus(
                    VanguardNativeBridge.stepNodeOwnedAudioSourceGraphPipeline(
                        handle, sysTimeNs, flushTail,
                    )
                )
                if (!kv.containsKey("sourceAvailableReadFrames")) {
                    throw FailClosed("step_missing_source_available_read_frames")
                }
                if (kv["status"] == "dispatch_silence") {
                    throw FailClosed("unexpected_silence_window")
                }
                return kv
            }

            fun drain(maxFrames: Int): Map<String, String> {
                checkDeadline()
                val kv = parseStatus(
                    VanguardNativeBridge.drainNodeOwnedAudioSourceGraphPipelineOutput(
                        handle, maxFrames,
                    )
                )
                if (kv["status"] != "ok") throw FailClosed("drain_status_${kv["status"]}")
                t.totalOutputFramesDrained = longField(kv, "totalOutputFramesDrained")
                t.nativeOutputDrainChecksumHex = kv["nativeOutputDrainChecksumHex"] ?: ""
                return kv
            }

            // Dispatch+drain every fully covered window the source ring
            // currently holds; one window per step, drained immediately so
            // the output ring never backs up.
            fun pumpWhileFullWindows() {
                while (sourceAvail >= mfpm) {
                    val kv = step(tickForFrame(nextFrame + mfpm), false)
                    if (kv["status"] != "dispatch_ok" ||
                        longField(kv, "framesRendered") != mfpm
                    ) {
                        throw FailClosed("pump_step_${kv["status"]}")
                    }
                    nextFrame += mfpm
                    sourceAvail = longField(kv, "sourceAvailableReadFrames")
                    if (longField(drain(config.maxFramesPerMix), "framesDrained") != mfpm) {
                        throw FailClosed("pump_drain_short")
                    }
                }
            }

            // Losslessly ingests [frames] PCM16 frames held at byte offset 0
            // of the direct buffer [buf]: partially accepted chunks are
            // compacted to offset 0, full windows are pumped to free ring
            // space, and the remainder is retried until fully accepted. The
            // Kotlin checksum mirrors the native accepted-side checksum over
            // exactly the accepted samples in acceptance order.
            fun ingestLossless(buf: ByteBuffer, frames: Int) {
                val ch = t.channelCount
                var remaining = frames
                while (remaining > 0) {
                    checkDeadline()
                    val kv = parseStatus(
                        VanguardNativeBridge.ingestNodeOwnedAudioSourceGraphPipelinePcm16(
                            handle, buf, remaining,
                        )
                    )
                    if (kv["status"] != "ok") throw FailClosed("ingest_status_${kv["status"]}")
                    val writerStatus = kv["writerStatus"]
                    if (writerStatus != "ok" && writerStatus != "partial_write" &&
                        writerStatus != "ring_full"
                    ) {
                        throw FailClosed("ingest_writer_$writerStatus")
                    }
                    val accepted = longField(kv, "framesAccepted").toInt()
                    if (accepted < 0 || accepted > remaining) {
                        throw FailClosed("ingest_accepted_out_of_range")
                    }
                    if (accepted > 0) {
                        var c = t.kotlinChecksum
                        for (i in 0 until accepted * ch) {
                            c = c * 31L + (buf.getShort(i * 2).toLong() and 0xFFFFL)
                        }
                        t.kotlinChecksum = c
                        t.kotlinFramesAccepted += accepted
                        t.totalFramesAccepted = longField(kv, "totalFramesAccepted")
                        t.nativeAcceptedChecksumHex = kv["nativeAcceptedChecksumHex"] ?: ""
                    }
                    sourceAvail = longField(kv, "sourceAvailableReadFrames")
                    remaining -= accepted
                    if (remaining > 0) {
                        // Compact the unaccepted suffix to byte offset 0.
                        // Front-to-back short copies are overlap-safe because
                        // every source index is >= its destination index.
                        val baseSamples = accepted * ch
                        for (i in 0 until remaining * ch) {
                            buf.putShort(i * 2, buf.getShort((baseSamples + i) * 2))
                        }
                        val availBeforePump = sourceAvail
                        pumpWhileFullWindows()
                        if (accepted == 0 && availBeforePump < mfpm) {
                            throw FailClosed("ingest_stalled_no_ring_progress")
                        }
                    }
                }
            }

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
            // creates + starts the node-owned native session (capturing the
            // capacity/route baseline), consumes the start ack, and hoists
            // the one direct scratch buffer.
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
                val expectedFrameCount = EXPECTED_FRAME_SECONDS * sr
                t.expectedFrameCount = expectedFrameCount.toLong()
                handle = VanguardNativeBridge.createNodeOwnedAudioSourceGraphPipelineSmokeSession(
                    sr, ch, expectedFrameCount,
                    config.sourceRingCapacityFrames,
                    config.outputRingCapacityFrames,
                    config.maxFramesPerMix,
                )
                if (handle == 0L) throw FailClosed("native_session_create_failed")

                val snapStart = snapshot()
                t.routeDiscoveryOk = longField(snapStart, "routedSourceCount") == 1L &&
                    snapStart["routedSourceId0"] == EXPECTED_SOURCE_NODE_ID
                if (!t.routeDiscoveryOk) throw FailClosed("route_discovery_mismatch")
                t.nodeOwnsRingOk = snapStart["nodeOwnsRing"] == "true"
                if (!t.nodeOwnsRingOk) throw FailClosed("node_does_not_own_ring")
                schedCapBefore = longField(snapStart, "schedulerTrackScratchCapacitySamples")
                schedTracksBefore = longField(snapStart, "schedulerTrackScratchCapacityTracks")
                srcCapBefore = longField(snapStart, "sourceRingStorageCapacitySamples")
                outCapBefore = longField(snapStart, "outputRingStorageCapacitySamples")
                if (schedCapBefore <= 0L || srcCapBefore <= 0L || outCapBefore <= 0L) {
                    throw FailClosed("capacity_baseline_invalid")
                }

                val startKv = parseStatus(
                    VanguardNativeBridge.startNodeOwnedAudioSourceGraphPipeline(
                        handle, 0L, anchorSysNs,
                    )
                )
                if (startKv["status"] != "ok") throw FailClosed("start_status_${startKv["status"]}")
                lastTickNs = anchorSysNs
                val firstStepKv = step(anchorSysNs, false)
                if (firstStepKv["status"] != "awaiting_seek_ack") {
                    throw FailClosed("first_step_not_awaiting_seek_ack_${firstStepKv["status"]}")
                }
                val startAckKv = drain(config.outputRingCapacityFrames)
                if (startAckKv["seekAckConsumed"] != "true" ||
                    longField(startAckKv, "newStartFrame") != 0L ||
                    longField(startAckKv, "discardedFramesOnSeek") != 0L
                ) {
                    throw FailClosed("start_ack_not_consumed_cleanly")
                }
                scratch = ByteBuffer.allocateDirect(SCRATCH_FRAMES * bytesPerFrame)
                    .order(ByteOrder.LITTLE_ENDIAN)
                t.formatProbeOk = true
            }

            // Once the session format is established, a repeated format
            // change with identical sampleRate/channelCount/PCM encoding is
            // benign and counted; any difference is malignant.
            fun onOutputFormatChanged() {
                if (handle == 0L) {
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

            // Streams decoder output into the node-owned session until the
            // codec reports output EOS; input EOS is queued once the
            // extractor passes [endUs] (or runs out of samples).
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
                                if (handle == 0L) establishSession()
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
                                    ingestLossless(sliceBuf, sliceFrames)
                                }
                                pumpWhileFullWindows()
                            } else {
                                dec.releaseOutputBuffer(outIdx, false)
                            }
                            if (isEos) outputDone = true
                        }
                        // INFO_TRY_AGAIN_LATER — the deadline bounds the wait.
                    }
                }
            }

            // Writer-local EOS then a lossless tail flush: rendering steps
            // (full or partial windows) each drained immediately, until the
            // node-owned source ring reports tail_flush_complete.
            fun flushTailAtEos() {
                val eosKv = parseStatus(
                    VanguardNativeBridge.setNodeOwnedAudioSourceGraphPipelineEos(handle)
                )
                if (eosKv["status"] != "ok" || eosKv["eos"] != "true") {
                    throw FailClosed("eos_set_failed_${eosKv["status"]}")
                }
                var guard = 0
                while (true) {
                    checkDeadline()
                    if (++guard > MAX_TAIL_FLUSH_STEPS) throw FailClosed("tail_flush_unbounded")
                    val target = minOf(sourceAvail, mfpm)
                    val kv = step(tickForFrame(nextFrame + target), true)
                    when (kv["status"]) {
                        "tail_flush_complete" -> return
                        "dispatch_ok", "tail_flush_partial_window" -> {
                            val rendered = longField(kv, "framesRendered")
                            if (rendered <= 0L) throw FailClosed("tail_flush_zero_render")
                            nextFrame += rendered
                            sourceAvail = longField(kv, "sourceAvailableReadFrames")
                            if (longField(drain(config.maxFramesPerMix), "framesDrained") !=
                                rendered
                            ) {
                                throw FailClosed("tail_drain_short")
                            }
                        }
                        else -> throw FailClosed("tail_flush_${kv["status"]}")
                    }
                }
            }

            // ── Pre-seek decode: media [0, seekTarget] through the rig ──────
            decodePhase(seekTargetUs)
            if (handle == 0L) throw FailClosed("no_decoder_output")
            flushTailAtEos()
            val preSeekAccepted = t.totalFramesAccepted
            val preSeekDrained = t.totalOutputFramesDrained
            if (preSeekAccepted <= 0L) throw FailClosed("no_pre_seek_frames_accepted")
            if (preSeekAccepted != nextFrame) throw FailClosed("pre_seek_cursor_mismatch")

            // ── The one forward-only native seek, on the ACCEPTED-FRAME
            // axis: re-anchor writer/provider/coordinator at exactly
            // A = totalFramesAccepted with zero discards ─────────────────────
            val seekTargetFrame = nextFrame
            val seekPtsUs = ceilDiv(seekTargetFrame * 1_000_000L, t.sampleRate.toLong())
            val seekSysNs = tickForFrame(seekTargetFrame)
            val seekKv = parseStatus(
                VanguardNativeBridge.seekNodeOwnedAudioSourceGraphPipeline(
                    handle, seekPtsUs, seekSysNs,
                )
            )
            if (seekKv["status"] != "ok" ||
                longField(seekKv, "targetFrame") != seekTargetFrame ||
                longField(seekKv, "discardedFramesOnSeek") != 0L
            ) {
                throw FailClosed("seek_failed_${seekKv["status"]}")
            }
            anchorPtsUs = seekPtsUs
            anchorSysNs = seekSysNs
            val seekAckKv = drain(config.outputRingCapacityFrames)
            if (seekAckKv["seekAckConsumed"] != "true" ||
                longField(seekAckKv, "newStartFrame") != seekTargetFrame ||
                longField(seekAckKv, "discardedFramesOnSeek") != 0L
            ) {
                throw FailClosed("seek_ack_not_consumed_cleanly")
            }
            t.seekOk = true
            t.detailParts.add("seekAcceptedFrame=$seekTargetFrame")
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
            flushTailAtEos()
            t.tailFlushOk = true
            // Codec output EOS was observed (both decodePhase calls
            // returned) and both native tail flushes completed.
            t.decoderEosReachedOk = true
            t.postSeekFramesAccepted = t.totalFramesAccepted - preSeekAccepted
            t.postSeekFramesDrained = t.totalOutputFramesDrained - preSeekDrained
            if (t.postSeekFramesAccepted <= 0L) throw FailClosed("no_post_seek_frames_accepted")
            if (t.postSeekFramesDrained <= 0L) throw FailClosed("no_post_seek_frames_drained")

            // ── Final snapshot + verdict lanes ──────────────────────────────
            val snapEnd = snapshot()
            t.detailParts.add("preSeekFramesAccepted=$preSeekAccepted")
            t.detailParts.add("benignFormatChanges=${t.decoderBenignFormatChangeCount}")
            t.detailParts.add("finalNextFrame=$nextFrame")

            if (longField(snapEnd, "routedSourceCount") != 1L ||
                snapEnd["routedSourceId0"] != EXPECTED_SOURCE_NODE_ID ||
                snapEnd["nodeOwnsRing"] != "true"
            ) {
                throw FailClosed("route_discovery_drifted")
            }
            t.noUnderrunOk = t.providerUnderrunEvents == 0L &&
                t.providerFramesZeroFilled == 0L
            if (!t.noUnderrunOk) throw FailClosed("provider_underrun_observed")
            t.noSilenceOk = t.coordinatorSilenceCount == 0L
            if (!t.noSilenceOk) throw FailClosed("silence_window_observed")
            t.noForwardSkipOk = t.providerForwardSkipFrames == 0L
            if (!t.noForwardSkipOk) throw FailClosed("provider_forward_skip_observed")
            t.noRewindRejectOk = t.providerRewindRejects == 0L
            if (!t.noRewindRejectOk) throw FailClosed("provider_rewind_reject_observed")
            t.finalNotTerminalOk = snapEnd["terminal"] != "true"
            if (!t.finalNotTerminalOk) throw FailClosed("terminal_state_observed")
            t.finalSeekAckClearOk = snapEnd["awaitingSeekAck"] != "true"
            if (!t.finalSeekAckClearOk) throw FailClosed("seek_ack_still_pending")

            t.zeroNativeSteadyStateAllocationOk = t.dispatchCount > 0L &&
                schedCapBefore == longField(snapEnd, "schedulerTrackScratchCapacitySamples") &&
                schedTracksBefore == longField(snapEnd, "schedulerTrackScratchCapacityTracks") &&
                srcCapBefore == longField(snapEnd, "sourceRingStorageCapacitySamples") &&
                outCapBefore == longField(snapEnd, "outputRingStorageCapacitySamples")
            if (!t.zeroNativeSteadyStateAllocationOk) {
                throw FailClosed("native_steady_state_allocation_detected")
            }

            val kotlinChecksumHex = String.format("%016x", t.kotlinChecksum)
            t.checksumIdentityOk = kotlinChecksumHex == t.nativeAcceptedChecksumHex &&
                kotlinChecksumHex == t.nativeOutputDrainChecksumHex
            if (!t.checksumIdentityOk) throw FailClosed("checksum_identity_mismatch")

            t.frameAccountingOk = t.totalFramesAccepted == t.totalOutputFramesDrained &&
                t.totalFramesAccepted == t.kotlinFramesAccepted &&
                t.totalFramesAccepted == nextFrame
            if (!t.frameAccountingOk) throw FailClosed("frame_accounting_mismatch")

            // ── Lifecycle lane: idempotent any-thread destroy ───────────────
            val destroyKv = parseStatus(
                VanguardNativeBridge.destroyNodeOwnedAudioSourceGraphPipelineSmokeSession(handle)
            )
            val destroyAgainKv = parseStatus(
                VanguardNativeBridge.destroyNodeOwnedAudioSourceGraphPipelineSmokeSession(handle)
            )
            val postDestroySnapshotKv = parseStatus(
                VanguardNativeBridge.snapshotNodeOwnedAudioSourceGraphPipeline(handle)
            )
            handle = 0L
            t.lifecycleOk = destroyKv["status"] == "ok" &&
                destroyAgainKv["status"] == "not_found" &&
                postDestroySnapshotKv["status"] == "not_found"
            if (!t.lifecycleOk) throw FailClosed("lifecycle_destroy_not_idempotent")

            return makeResult(t, config, pass = true, failureReason = "")
        } catch (f: FailClosed) {
            return makeResult(t, config, pass = false, failureReason = f.reason)
        } catch (e: Throwable) {
            return makeResult(
                t, config, pass = false,
                failureReason = "exception:${e.javaClass.simpleName}:${e.message}",
            )
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
            if (handle != 0L) {
                // Destroy is idempotent and callable from any thread.
                try {
                    VanguardNativeBridge.destroyNodeOwnedAudioSourceGraphPipelineSmokeSession(handle)
                } catch (_: Throwable) {}
            }
        }
    }

    private fun makeResult(
        t: Telemetry,
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
        routeDiscoveryOk = t.routeDiscoveryOk,
        nodeOwnsRingOk = t.nodeOwnsRingOk,
        checksumIdentityOk = t.checksumIdentityOk,
        frameAccountingOk = t.frameAccountingOk,
        seekOk = t.seekOk,
        tailFlushOk = t.tailFlushOk,
        noUnderrunOk = t.noUnderrunOk,
        noSilenceOk = t.noSilenceOk,
        noForwardSkipOk = t.noForwardSkipOk,
        noRewindRejectOk = t.noRewindRejectOk,
        finalNotTerminalOk = t.finalNotTerminalOk,
        finalSeekAckClearOk = t.finalSeekAckClearOk,
        zeroNativeSteadyStateAllocationOk = t.zeroNativeSteadyStateAllocationOk,
        lifecycleOk = t.lifecycleOk,
        canonical = pass,
        sampleRate = t.sampleRate,
        channelCount = t.channelCount,
        pcmEncoding = t.pcmEncoding,
        expectedFrameCount = t.expectedFrameCount,
        totalFramesExtracted = t.totalFramesExtracted,
        totalFramesAccepted = t.totalFramesAccepted,
        totalOutputFramesDrained = t.totalOutputFramesDrained,
        postSeekFramesAccepted = t.postSeekFramesAccepted,
        postSeekFramesDrained = t.postSeekFramesDrained,
        decoderBenignFormatChangeCount = t.decoderBenignFormatChangeCount,
        providerUnderrunEvents = t.providerUnderrunEvents,
        providerFramesZeroFilled = t.providerFramesZeroFilled,
        providerForwardSkipFrames = t.providerForwardSkipFrames,
        providerRewindRejects = t.providerRewindRejects,
        coordinatorSilenceCount = t.coordinatorSilenceCount,
        dispatchCount = t.dispatchCount,
        nativeAcceptedChecksumHex = t.nativeAcceptedChecksumHex,
        nativeOutputDrainChecksumHex = t.nativeOutputDrainChecksumHex,
        kotlinAcceptedChecksumHex = String.format("%016x", t.kotlinChecksum),
        maxFramesPerMix = config.maxFramesPerMix.toLong(),
        sourceAvailableReadFrames = t.sourceAvailableReadFrames,
        outputAvailableReadFrames = t.outputAvailableReadFrames,
        nextDispatchFrame = t.nextDispatchFrame,
    )

    private fun parseStatus(raw: String): Map<String, String> =
        raw.split(';').mapNotNull { part ->
            val idx = part.indexOf('=')
            if (idx <= 0) null else part.substring(0, idx) to part.substring(idx + 1)
        }.toMap()

    private fun longField(kv: Map<String, String>, key: String): Long =
        kv[key]?.toLongOrNull() ?: throw FailClosed("missing_status_field_$key")
}
