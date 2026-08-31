package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidMultiSourceNodeOwnedPipelineDriver (P4-AUDIO-MULTI-SOURCE-NODE-OWNED-PIPELINE) ─
//
// Kotlin-owned two-source NODE-OWNED closed-loop proof: one real
// MediaExtractor/MediaCodec streaming decode of the first audio track (MIME
// audio/*) as track 0, plus one deterministically Kotlin-synthesized PCM
// track (same sampleRate/channelCount, generated on demand) as track 1,
// driven in lockstep through the two-source node-owned native audio graph
// pipeline session via [AndroidMultiSourceNodeOwnedPipelineNativeSession].
// Unlike the external-provider-map multi-source proof, each native
// DecodedAudioPcmSourceNode owns its source ring/writer/provider triple by
// composition and the GraphAudioScheduler auto-discovers BOTH providers
// from graph topology alone (tag-dispatched constructor; no external
// provider map, no hybrid routing). This driver owns the single real
// decoder/extractor lifecycle (there is no second OS decoder anywhere), the
// codec output buffer copy/release policy, the decoder output format policy
// (including benign repeat format changes), the synthetic track generation
// on the shared accepted-frame axis, the Kotlin-side reference mix
// checksum, the common frame budget L (which is also each node's
// expectedFrameCount timeline-window bound, resolved format-first before
// native create), the watchdog deadline, the dispose-cancellation poll, and
// the overall step loop; the native session component owns every JNI
// interaction.
//
// Proof shape, all on the single caller thread of [run] (except the
// deliberate foreign-thread probe inside the session that native must
// reject):
//   - Resolve the decoder output format first (PCM16, 1-2 channels only);
//     create + start the native session only once the format is known, with
//     expectedFrameCount = commonBudgetFrames so both nodes' isActiveAt
//     timeline windows cover every dispatched frame. The synthetic track
//     inherits the exact format: no resampling, no downmix.
//   - Every codec output chunk is copied into direct ByteBuffers and the
//     codec output buffer is released BEFORE any JNI ingest/step/drain
//     runs. Each slice is then split into sub-chunks of at most
//     maxFramesPerMix frames; for every accepted real frame chunk exactly
//     the same frame count is synthesized for track 1 and ingested in
//     lockstep (shared accepted-frame axis; divergence fails closed).
//   - The Kotlin reference mixed-output checksum streams over the accepted
//     lockstep frames as clamp16(sample0 + syntheticSample) with
//     c = c * 31 + (sample & 0xFFFF), mirroring the native unit-gain
//     int32-accumulate-then-clamp mix bus exactly; per-track Kotlin
//     accepted checksums and frames are recorded alongside.
//   - Common budget L = round(window seconds * sampleRate): the proof is
//     lossless within [0, L) only; real decoder output beyond L is
//     truncated and that truncation is an explicit non-claim.
//   - The one native seek is JOINT and on the shared ACCEPTED-FRAME axis:
//     after a fully drained pre-seek joint EOS tail flush at
//     A = totalFramesAccepted, the native seek re-anchors BOTH tracks at
//     exactly A with zero discards and clears both writer-local EOS flags;
//     the synthetic generator resumes on accepted frame axis A. The
//     extractor seek is media-local (PREVIOUS_SYNC may land early);
//     post-seek media content overlap with pre-seek content is an explicit
//     non-claim.
//   - Both tracks set EOS together through the single joint EOS entry point
//     (no independent EOS, no ragged tail, no post-EOS intentional
//     silence); the final joint tail flush drains both rings to exactly
//     zero.
//
// Honest non-claims: no AudioTrack/AAudio/OpenSL/Oboe, no sink-clocked
// transport, no audible or realtime playback, no export or pass-2 graph
// reroute, no streaming/cache, no iOS, no product/editor UI. Native never
// owns MediaCodec/MediaExtractor, never does file IO, and never reads a
// wall clock; every tick is caller-derived on the shared accepted-frame
// axis.
class AndroidMultiSourceNodeOwnedPipelineDriver(
    private val cancelled: () -> Boolean = { false },
) {

    companion object {
        const val PASS_MARKER = "ANDROID_DAG_PHASE4_MULTI_SOURCE_NODE_OWNED_PIPELINE_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_MULTI_SOURCE_NODE_OWNED_PIPELINE_SMOKE_FAIL"
        const val PROOF_BOUNDARY =
            "kotlin_owned_real_decoder_plus_synthetic_second_track_step_driven_multi_source_node_owned_closed_loop_native_audio_graph_pipeline_session_proof_only_source_nodes_own_ring_writer_provider_by_composition_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_no_hybrid_routing_no_second_os_decoder_no_cpp_os_decoder_no_mediacodec_no_mediaextractor_ownership_in_cpp_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_seek_reanchors_both_tracks_at_single_accepted_frame_cursor_extractor_seek_is_media_local_post_seek_media_content_overlap_permitted_lossless_within_common_budget_l_truncation_beyond_budget_non_claim_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_destroy_idempotent_any_thread_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_sink_clocked_transport_no_audible_or_realtime_playback_no_audio_focus_no_route_no_dead_object_no_speaker_no_latency_no_glitch_claims_diagnostic_graph_topology_only_two_routed_tracks_unit_gain_no_independent_eos_no_ragged_tail_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_joint_tail_flush_diagnostic_only_no_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_streaming_no_cache_no_ios_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim"

        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val HARD_MAX_DURATION_SEC = 2.0

        // Codec-chunk copy scratch, matching the native per-call ingest
        // clamp (AudioDecoderRingWriter kMaxWriteFrames).
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
        val topologyRoutedSourcesOk: Boolean,
        val nodeOwnedRouteDiscoveryOk: Boolean,
        val nodeOwnsRingTrack0Ok: Boolean,
        val nodeOwnsRingTrack1Ok: Boolean,
        val track0IngestOk: Boolean,
        val track1SyntheticIngestOk: Boolean,
        val trackFrameAxisLockstepOk: Boolean,
        val jointDispatchGateOk: Boolean,
        val referenceMixChecksumOk: Boolean,
        val mixedOutputFrameAccountingOk: Boolean,
        val twoTrackContributionOk: Boolean,
        val seekOk: Boolean,
        val jointTailFlushOk: Boolean,
        val noProviderUnderrunOk: Boolean,
        val noZeroFillOk: Boolean,
        val noForwardSkipOk: Boolean,
        val noRewindRejectOk: Boolean,
        val noSilenceOk: Boolean,
        val noRingPushShortfallOk: Boolean,
        val zeroNativeSteadyStateAllocationOk: Boolean,
        val ownerThreadOk: Boolean,
        val lifecycleOk: Boolean,
        val canonical: Boolean,
        // Metrics.
        val sampleRate: Int,
        val channelCount: Int,
        val pcmEncoding: Int,
        val commonBudgetFrames: Long,
        val expectedFrameCount: Long,
        val routedSourceId0: String,
        val routedSourceId1: String,
        val framesTruncatedBeyondBudget: Long,
        val totalFramesExtracted: Long,
        val totalFramesAcceptedTrack0: Long,
        val totalFramesAcceptedTrack1: Long,
        val totalOutputFramesDrained: Long,
        val postSeekFramesAccepted: Long,
        val postSeekFramesDrained: Long,
        val seekAcceptedFrame: Long,
        val track1NonZeroSampleCount: Long,
        val mixedChecksumDiffersFromTrack0: Boolean,
        val mixedChecksumDiffersFromTrack1: Boolean,
        val decoderBenignFormatChangeCount: Long,
        val providerUnderrunEventsTrack0: Long,
        val providerUnderrunEventsTrack1: Long,
        val providerFramesZeroFilledTrack0: Long,
        val providerFramesZeroFilledTrack1: Long,
        val providerForwardSkipFramesTrack0: Long,
        val providerForwardSkipFramesTrack1: Long,
        val providerRewindRejectsTrack0: Long,
        val providerRewindRejectsTrack1: Long,
        val coordinatorSilenceCount: Long,
        val nativeAcceptedChecksumHexTrack0: String,
        val nativeAcceptedChecksumHexTrack1: String,
        val nativeOutputDrainChecksumHex: String,
        val kotlinAcceptedChecksumHexTrack0: String,
        val kotlinAcceptedChecksumHexTrack1: String,
        val kotlinReferenceMixChecksumHex: String,
        val maxFramesPerMix: Long,
        val sourceAvailableReadFramesTrack0: Long,
        val sourceAvailableReadFramesTrack1: Long,
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
        var topologyRoutedSourcesOk = false
        var nodeOwnedRouteDiscoveryOk = false
        var nodeOwnsRingTrack0Ok = false
        var nodeOwnsRingTrack1Ok = false
        var track0IngestOk = false
        var track1SyntheticIngestOk = false
        var trackFrameAxisLockstepOk = false
        var jointDispatchGateOk = false
        var referenceMixChecksumOk = false
        var mixedOutputFrameAccountingOk = false
        var twoTrackContributionOk = false
        var seekOk = false
        var jointTailFlushOk = false
        var noProviderUnderrunOk = false
        var noZeroFillOk = false
        var noForwardSkipOk = false
        var noRewindRejectOk = false
        var noSilenceOk = false
        var noRingPushShortfallOk = false
        var zeroNativeSteadyStateAllocationOk = false
        var ownerThreadOk = false
        var lifecycleOk = false

        var sampleRate = 0
        var channelCount = 0
        var pcmEncoding = 0
        var commonBudgetFrames = 0L
        var framesTruncatedBeyondBudget = 0L
        var totalFramesExtracted = 0L
        var postSeekFramesAccepted = 0L
        var postSeekFramesDrained = 0L
        var seekAcceptedFrame = -1L
        var track1NonZeroSampleCount = 0L
        var mixedChecksumDiffersFromTrack0 = false
        var mixedChecksumDiffersFromTrack1 = false
        var decoderBenignFormatChangeCount = 0L

        // Kotlin-side streaming checksums over the shared accepted-frame
        // axis, updated before each lockstep chunk crosses into native.
        var kotlinTrack0Checksum = 0L
        var kotlinTrack1Checksum = 0L
        var kotlinMixedChecksum = 0L
        var kotlinFramesAccepted = 0L

        val detailParts = mutableListOf<String>()
    }

    // Deterministic, non-silent, low-amplitude (|v| <= 504) synthetic
    // sample on the shared accepted-frame axis; low enough that clipping
    // against the real track is unlikely, while the reference mix still
    // clamps exactly like the native mix bus.
    private fun syntheticSample(frameIndex: Long, channel: Int): Int =
        ((frameIndex * 7L + channel * 3L) % 1009L).toInt() - 504

    fun run(config: RunConfig): RunResult {
        val t = RunTelemetry()
        val deadline = SystemClock.elapsedRealtime() + config.deadlineMs
        val session = AndroidMultiSourceNodeOwnedPipelineNativeSession(deadline)
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
            if (config.maxFramesPerMix <= 0) throw FailClosed("invalid_max_frames_per_mix")
            val windowUs = (windowSec * 1_000_000.0).toLong()
            val seekTargetUs = (config.seekTargetSec * 1_000_000.0).toLong()
            val mfpm = config.maxFramesPerMix

            fun checkDeadline() {
                if (SystemClock.elapsedRealtime() > deadline) throw FailClosed("deadline_exceeded")
            }

            fun pollCancelled() {
                if (cancelled()) throw FailClosed("cancelled_by_dispose")
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
            var chunk0: ByteBuffer? = null
            var chunk1: ByteBuffer? = null

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
            // fixes the common budget L on the now-known sampleRate, creates
            // + starts the native session (format-first, with
            // expectedFrameCount = L so both nodes' timeline windows cover
            // every dispatched frame), verifies the node-owned
            // auto-discovery lanes, and hoists the direct buffers
            // (codec-copy scratch plus one lockstep chunk buffer per
            // track). The synthetic track inherits this exact format.
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
                t.commonBudgetFrames = (windowSec * sr).toLong()
                if (t.commonBudgetFrames <= 0L) throw FailClosed("invalid_common_budget")
                if (t.commonBudgetFrames > Int.MAX_VALUE.toLong()) {
                    throw FailClosed("common_budget_exceeds_int")
                }
                bytesPerFrame = 2 * ch
                session.create(
                    sr, ch,
                    t.commonBudgetFrames.toInt(),
                    config.sourceRingCapacityFrames,
                    config.outputRingCapacityFrames,
                    config.maxFramesPerMix,
                )
                session.startAndConsumeAck()
                t.topologyRoutedSourcesOk = session.routedSourceCount == 2L
                if (!t.topologyRoutedSourcesOk) throw FailClosed("topology_route_mismatch")
                t.nodeOwnedRouteDiscoveryOk =
                    session.routedSourceId0 ==
                        AndroidMultiSourceNodeOwnedPipelineNativeSession.SOURCE0_NODE_ID &&
                    session.routedSourceId1 ==
                        AndroidMultiSourceNodeOwnedPipelineNativeSession.SOURCE1_NODE_ID
                if (!t.nodeOwnedRouteDiscoveryOk) throw FailClosed("node_owned_route_mismatch")
                t.nodeOwnsRingTrack0Ok = session.nodeOwnsRingTrack0
                if (!t.nodeOwnsRingTrack0Ok) throw FailClosed("node_owns_ring_track0_false")
                t.nodeOwnsRingTrack1Ok = session.nodeOwnsRingTrack1
                if (!t.nodeOwnsRingTrack1Ok) throw FailClosed("node_owns_ring_track1_false")
                scratch = ByteBuffer.allocateDirect(SCRATCH_FRAMES * bytesPerFrame)
                    .order(ByteOrder.LITTLE_ENDIAN)
                chunk0 = ByteBuffer.allocateDirect(mfpm * bytesPerFrame)
                    .order(ByteOrder.LITTLE_ENDIAN)
                chunk1 = ByteBuffer.allocateDirect(mfpm * bytesPerFrame)
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

            // Lockstep ingest of [frames] real frames read from
            // [slice] starting at frame offset [sliceFrameOffset]: copies
            // the real sub-chunk to chunk0, synthesizes the identical frame
            // count into chunk1 on the shared accepted-frame axis, streams
            // the Kotlin reference checksums (track0/track1/mixed) BEFORE
            // the buffers cross into native (lossless lockstep ingest may
            // compact them), then hands both to the session.
            fun ingestLockstepSubChunk(slice: ByteBuffer, sliceFrameOffset: Int, frames: Int) {
                val c0 = chunk0!!
                val c1 = chunk1!!
                slice.limit((sliceFrameOffset + frames) * bytesPerFrame)
                slice.position(sliceFrameOffset * bytesPerFrame)
                c0.clear()
                c0.put(slice)
                val base = t.kotlinFramesAccepted
                val ch = t.channelCount
                val sampleCount = frames * ch
                for (i in 0 until sampleCount) {
                    val s0 = c0.getShort(i * 2).toInt()
                    val s1 = syntheticSample(base + (i / ch), i % ch)
                    c1.putShort(i * 2, s1.toShort())
                    if (s1 != 0) t.track1NonZeroSampleCount += 1
                    t.kotlinTrack0Checksum =
                        t.kotlinTrack0Checksum * 31L + (s0.toLong() and 0xFFFFL)
                    t.kotlinTrack1Checksum =
                        t.kotlinTrack1Checksum * 31L + (s1.toLong() and 0xFFFFL)
                    var acc = s0 + s1
                    if (acc > 32767) acc = 32767 else if (acc < -32768) acc = -32768
                    t.kotlinMixedChecksum =
                        t.kotlinMixedChecksum * 31L + (acc.toLong() and 0xFFFFL)
                }
                session.ingestLockstepChunk(c0, c1, frames)
                t.kotlinFramesAccepted += frames
            }

            // Streams decoder output through the lockstep rig until the
            // codec reports output EOS; input EOS is queued once the
            // extractor passes [endUs] (or runs out of samples). Real
            // frames beyond the common budget L are truncated (explicit
            // non-claim; the decode still runs to codec EOS).
            fun decodePhase(endUs: Long) {
                val info = MediaCodec.BufferInfo()
                var inputDone = false
                var outputDone = false
                while (!outputDone) {
                    checkDeadline()
                    pollCancelled()
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
                                    var offsetFrames = 0
                                    while (offsetFrames < sliceFrames) {
                                        checkDeadline()
                                        pollCancelled()
                                        val budgetLeft =
                                            t.commonBudgetFrames - t.kotlinFramesAccepted
                                        if (budgetLeft <= 0L) {
                                            t.framesTruncatedBeyondBudget +=
                                                (sliceFrames - offsetFrames).toLong()
                                            break
                                        }
                                        val take = minOf(
                                            (sliceFrames - offsetFrames).toLong(),
                                            mfpm.toLong(),
                                            budgetLeft,
                                        ).toInt()
                                        ingestLockstepSubChunk(sliceBuf, offsetFrames, take)
                                        offsetFrames += take
                                    }
                                }
                                session.pumpWhileJointWindows()
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
            session.pumpWhileJointWindows()

            // ── Joint dispatch gate probe at the sub-window residual ────────
            session.probeJointDeferral()
            t.jointDispatchGateOk = session.jointDeferralObserved

            // ── Pre-seek boundary: joint EOS tail flush (both tracks set
            // EOS together), then the one joint accepted-frame-axis seek ────
            session.flushTailAtEos()
            val preSeekAccepted = session.totalFramesAcceptedTrack0
            val preSeekDrained = session.totalOutputFramesDrained
            val seekFrame = session.seekToAcceptedFrameBoundary()
            t.seekOk = true
            t.seekAcceptedFrame = seekFrame
            t.detailParts.add("seekAcceptedFrame=$seekFrame")
            t.detailParts.add("post_seek_media_content_overlap_permitted")
            t.detailParts.add("truncation_beyond_budget_l_non_claim")

            // Extractor seek stays media-local; PREVIOUS_SYNC may land early
            // and re-decode content already ingested pre-seek (non-claim
            // recorded above). The synthetic generator resumes on accepted
            // frame axis A automatically (it is a pure function of the
            // accepted frame index).
            extractor.seekTo(seekTargetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val postSeekStartUs =
                extractor.sampleTime.let { if (it >= 0L) it else seekTargetUs }
            dec.flush()
            t.detailParts.add("postSeekStartUs=$postSeekStartUs")

            // ── Post-seek decode: the remaining window budget only ──────────
            decodePhase(postSeekStartUs + (windowUs - seekTargetUs))
            session.pumpWhileJointWindows()
            session.flushTailAtEos()
            t.jointTailFlushOk = true
            t.postSeekFramesAccepted = session.totalFramesAcceptedTrack0 - preSeekAccepted
            t.postSeekFramesDrained = session.totalOutputFramesDrained - preSeekDrained

            // ── Owner-thread probe at a quiescent point (no in-flight codec
            // buffer: both decode phases are complete) ──────────────────────
            t.ownerThreadOk = session.probeForeignThreadRejected()
            if (!t.ownerThreadOk) throw FailClosed("foreign_thread_not_rejected")

            // ── Final snapshot + verdict lanes ──────────────────────────────
            val snapEnd = session.snapshotMetrics()
            t.detailParts.add("preSeekFramesAccepted=$preSeekAccepted")
            t.detailParts.add("benignFormatChanges=${t.decoderBenignFormatChangeCount}")
            t.detailParts.add("commonBudgetFrames=${t.commonBudgetFrames}")
            t.detailParts.add("framesTruncatedBeyondBudget=${t.framesTruncatedBeyondBudget}")

            t.noProviderUnderrunOk = session.providerUnderrunEventsTrack0 == 0L &&
                session.providerUnderrunEventsTrack1 == 0L
            if (!t.noProviderUnderrunOk) throw FailClosed("provider_underrun_observed")
            t.noZeroFillOk = session.providerFramesZeroFilledTrack0 == 0L &&
                session.providerFramesZeroFilledTrack1 == 0L
            if (!t.noZeroFillOk) throw FailClosed("provider_zero_fill_observed")
            t.noForwardSkipOk = session.providerForwardSkipFramesTrack0 == 0L &&
                session.providerForwardSkipFramesTrack1 == 0L
            if (!t.noForwardSkipOk) throw FailClosed("provider_forward_skip_observed")
            t.noRewindRejectOk = session.providerRewindRejectsTrack0 == 0L &&
                session.providerRewindRejectsTrack1 == 0L
            if (!t.noRewindRejectOk) throw FailClosed("provider_rewind_reject_observed")
            t.noSilenceOk = session.coordinatorSilenceCount == 0L
            if (!t.noSilenceOk) throw FailClosed("silence_window_observed")
            t.noRingPushShortfallOk = !session.ringPushShortfallSeen
            if (!t.noRingPushShortfallOk) throw FailClosed("ring_push_shortfall_observed")
            if (session.snapshotTerminal) throw FailClosed("terminal_state_observed")
            if (session.snapshotAwaitingSeekAck) throw FailClosed("seek_ack_still_pending")
            t.zeroNativeSteadyStateAllocationOk =
                session.verifyZeroSteadyStateAllocation(snapEnd)
            if (!t.zeroNativeSteadyStateAllocationOk) {
                throw FailClosed("native_steady_state_allocation_detected")
            }

            if (session.totalFramesAcceptedTrack0 <= 0L) throw FailClosed("no_frames_accepted")
            if (t.postSeekFramesAccepted <= 0L) throw FailClosed("no_post_seek_frames_accepted")
            if (t.postSeekFramesDrained <= 0L) throw FailClosed("no_post_seek_frames_drained")

            t.trackFrameAxisLockstepOk =
                session.totalFramesAcceptedTrack0 == session.totalFramesAcceptedTrack1 &&
                    session.totalFramesAcceptedTrack0 == t.kotlinFramesAccepted
            if (!t.trackFrameAxisLockstepOk) throw FailClosed("track_frame_axis_divergence")

            val kotlin0Hex = String.format("%016x", t.kotlinTrack0Checksum)
            val kotlin1Hex = String.format("%016x", t.kotlinTrack1Checksum)
            val kotlinMixHex = String.format("%016x", t.kotlinMixedChecksum)
            t.track0IngestOk = kotlin0Hex == session.nativeAcceptedChecksumHexTrack0
            if (!t.track0IngestOk) throw FailClosed("track0_checksum_identity_mismatch")
            t.track1SyntheticIngestOk =
                kotlin1Hex == session.nativeAcceptedChecksumHexTrack1 &&
                    t.track1NonZeroSampleCount > 0L
            if (!t.track1SyntheticIngestOk) throw FailClosed("track1_checksum_identity_mismatch")
            t.referenceMixChecksumOk = kotlinMixHex == session.nativeOutputDrainChecksumHex
            if (!t.referenceMixChecksumOk) throw FailClosed("reference_mix_checksum_mismatch")
            t.mixedOutputFrameAccountingOk =
                session.totalOutputFramesDrained == session.totalFramesAcceptedTrack0
            if (!t.mixedOutputFrameAccountingOk) throw FailClosed("mixed_frame_accounting_mismatch")
            t.mixedChecksumDiffersFromTrack0 =
                kotlinMixHex != session.nativeAcceptedChecksumHexTrack0
            t.mixedChecksumDiffersFromTrack1 =
                kotlinMixHex != session.nativeAcceptedChecksumHexTrack1
            t.twoTrackContributionOk =
                t.mixedChecksumDiffersFromTrack0 && t.mixedChecksumDiffersFromTrack1
            if (!t.twoTrackContributionOk) throw FailClosed("two_track_contribution_not_observed")

            // ── Lifecycle lane: idempotent any-thread destroy ───────────────
            t.lifecycleOk = session.destroyAndVerifyLifecycle()
            if (!t.lifecycleOk) throw FailClosed("lifecycle_destroy_not_idempotent")

            return makeResult(t, session, config, pass = true, failureReason = "")
        } catch (f: FailClosed) {
            return makeResult(t, session, config, pass = false, failureReason = f.reason)
        } catch (f: AndroidMultiSourceNodeOwnedPipelineNativeSession.Failure) {
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
        session: AndroidMultiSourceNodeOwnedPipelineNativeSession,
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
        topologyRoutedSourcesOk = t.topologyRoutedSourcesOk,
        nodeOwnedRouteDiscoveryOk = t.nodeOwnedRouteDiscoveryOk,
        nodeOwnsRingTrack0Ok = t.nodeOwnsRingTrack0Ok,
        nodeOwnsRingTrack1Ok = t.nodeOwnsRingTrack1Ok,
        track0IngestOk = t.track0IngestOk,
        track1SyntheticIngestOk = t.track1SyntheticIngestOk,
        trackFrameAxisLockstepOk = t.trackFrameAxisLockstepOk,
        jointDispatchGateOk = t.jointDispatchGateOk,
        referenceMixChecksumOk = t.referenceMixChecksumOk,
        mixedOutputFrameAccountingOk = t.mixedOutputFrameAccountingOk,
        twoTrackContributionOk = t.twoTrackContributionOk,
        seekOk = t.seekOk,
        jointTailFlushOk = t.jointTailFlushOk,
        noProviderUnderrunOk = t.noProviderUnderrunOk,
        noZeroFillOk = t.noZeroFillOk,
        noForwardSkipOk = t.noForwardSkipOk,
        noRewindRejectOk = t.noRewindRejectOk,
        noSilenceOk = t.noSilenceOk,
        noRingPushShortfallOk = t.noRingPushShortfallOk,
        zeroNativeSteadyStateAllocationOk = t.zeroNativeSteadyStateAllocationOk,
        ownerThreadOk = t.ownerThreadOk,
        lifecycleOk = t.lifecycleOk,
        canonical = pass,
        sampleRate = t.sampleRate,
        channelCount = t.channelCount,
        pcmEncoding = t.pcmEncoding,
        commonBudgetFrames = t.commonBudgetFrames,
        expectedFrameCount = t.commonBudgetFrames,
        routedSourceId0 = session.routedSourceId0,
        routedSourceId1 = session.routedSourceId1,
        framesTruncatedBeyondBudget = t.framesTruncatedBeyondBudget,
        totalFramesExtracted = t.totalFramesExtracted,
        totalFramesAcceptedTrack0 = session.totalFramesAcceptedTrack0,
        totalFramesAcceptedTrack1 = session.totalFramesAcceptedTrack1,
        totalOutputFramesDrained = session.totalOutputFramesDrained,
        postSeekFramesAccepted = t.postSeekFramesAccepted,
        postSeekFramesDrained = t.postSeekFramesDrained,
        seekAcceptedFrame = t.seekAcceptedFrame,
        track1NonZeroSampleCount = t.track1NonZeroSampleCount,
        mixedChecksumDiffersFromTrack0 = t.mixedChecksumDiffersFromTrack0,
        mixedChecksumDiffersFromTrack1 = t.mixedChecksumDiffersFromTrack1,
        decoderBenignFormatChangeCount = t.decoderBenignFormatChangeCount,
        providerUnderrunEventsTrack0 = session.providerUnderrunEventsTrack0,
        providerUnderrunEventsTrack1 = session.providerUnderrunEventsTrack1,
        providerFramesZeroFilledTrack0 = session.providerFramesZeroFilledTrack0,
        providerFramesZeroFilledTrack1 = session.providerFramesZeroFilledTrack1,
        providerForwardSkipFramesTrack0 = session.providerForwardSkipFramesTrack0,
        providerForwardSkipFramesTrack1 = session.providerForwardSkipFramesTrack1,
        providerRewindRejectsTrack0 = session.providerRewindRejectsTrack0,
        providerRewindRejectsTrack1 = session.providerRewindRejectsTrack1,
        coordinatorSilenceCount = session.coordinatorSilenceCount,
        nativeAcceptedChecksumHexTrack0 = session.nativeAcceptedChecksumHexTrack0,
        nativeAcceptedChecksumHexTrack1 = session.nativeAcceptedChecksumHexTrack1,
        nativeOutputDrainChecksumHex = session.nativeOutputDrainChecksumHex,
        kotlinAcceptedChecksumHexTrack0 = String.format("%016x", t.kotlinTrack0Checksum),
        kotlinAcceptedChecksumHexTrack1 = String.format("%016x", t.kotlinTrack1Checksum),
        kotlinReferenceMixChecksumHex = String.format("%016x", t.kotlinMixedChecksum),
        maxFramesPerMix = config.maxFramesPerMix.toLong(),
        sourceAvailableReadFramesTrack0 = session.sourceAvailableReadFramesTrack0,
        sourceAvailableReadFramesTrack1 = session.sourceAvailableReadFramesTrack1,
        outputAvailableReadFrames = session.outputAvailableReadFrames,
        dispatchCount = session.dispatchCount,
        nextDispatchFrame = session.nativeNextDispatchFrame,
        nativeLastStatus = session.lastStatus,
    )
}
