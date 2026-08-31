package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidAaudioNodeOwnedSinkDriver (P4-AUDIO-AAUDIO-NODE-OWNED-SINK-DIAGNOSTIC) ─
// (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS)
//
// Combines the proven two-source NODE-OWNED closed-loop pipeline proof
// (real MediaExtractor/MediaCodec decode as track 0 plus one
// deterministically Kotlin-synthesized PCM track 1, lockstep on the shared
// accepted-frame axis — see [AndroidMultiSourceNodeOwnedPipelineDriver])
// with a MUTED NATIVE AAudio diagnostic callback sink: native owns the
// AAudio runtime loading (dlopen, never direct-linked), stream lifecycle,
// the owner-thread zero-scale pump, and the callback sink ring; Kotlin owns
// MediaExtractor/MediaCodec/the temp media path, the synthetic second
// track, the reference checksums, the deadline, the dispose-cancellation
// poll, and the overall step loop on ONE worker thread (the native
// session's single owner thread — native destroy is owner-thread-only in
// this slice, so the finally-path cleanup runs there too). There is no
// AudioTrack anywhere in this proof.
//
// Proof shape (single worker thread except the deliberate foreign-thread
// probe native must reject):
//   - Resolve the decoder output format first (PCM16, 1-2 channels only);
//     create + start the native session only once the format is known.
//     start performs the staged AAudio bring-up and fails closed verbatim
//     (aaudio_unavailable on API < 26 or a missing libaaudio,
//     aaudio_symbol_missing:<name>, aaudio_config_mismatch, ...).
//   - Feed a 0.5s-1.0s window in lockstep chunks of at most maxFramesPerMix
//     frames; every dispatched pair window is pumped: native checksums the
//     REAL mixed PCM, zero-scales it on the owner thread, and pushes the
//     muted frames into the callback sink ring, where the AAudio data
//     callback pops-or-zero-fills only.
//   - Observe real callback consumption (invocation + served counters),
//     probe the joint dispatch gate, joint-EOS tail flush, then the one
//     joint accepted-frame-axis seek IF the deadline leaves room
//     (seekOk=false is legal only with seekSkippedDeadline=true), the
//     post-seek remainder, and the final joint tail flush.
//   - Destroy on the same worker thread; the first destroy reply carries
//     the coherent post-close callback counters for the accounting lane.
//
// Honest non-claims: see [PROOF_BOUNDARY]. Every callback-fed sample is
// zero; no audible-output claim, no speaker route, no audio focus, no
// route-change handling, no dead-object recovery, no
// low-latency/MMAP/EXCLUSIVE mode, no xrun-freedom or latency/glitch
// claim, no product playback, no editor UI, no export/pass-2 reroute, no
// streaming/cache, no iOS.
class AndroidAaudioNodeOwnedSinkDriver(
    private val cancelled: () -> Boolean = { false },
) {

    companion object {
        const val PASS_MARKER = "ANDROID_DAG_PHASE4_AAUDIO_NODE_OWNED_SINK_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_AAUDIO_NODE_OWNED_SINK_SMOKE_FAIL"
        // Must stay byte-identical to kProofBoundary in
        // android_phase4_aaudio_node_owned_sink_session_jni.cpp.
        const val PROOF_BOUNDARY =
            "native_android_aaudio_callback_sink_diagnostic_only_runtime_dlopen_no_direct_libaaudio_link_min_sdk24_safe_real_decoder_plus_synthetic_second_track_two_decoded_audio_source_nodes_own_ring_writer_provider_by_composition_scheduler_auto_discovery_from_graph_topology_muted_owner_thread_zero_scale_before_callback_ring_callback_pop_or_silence_only_no_product_no_editor_no_connects_app_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_audible_output_claim_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_low_latency_mmap_exclusive_no_xrun_freedom_no_latency_glitch_claim"

        private const val DEQUEUE_TIMEOUT_US = 10_000L
        // Mandatory proof window: at least 0.5s and at most 1.0s of mixed
        // PCM must flow through the muted sink.
        private const val MIN_WINDOW_SEC = 0.5
        private const val HARD_MAX_DURATION_SEC = 1.0
        private const val ZERO_CHECKSUM_HEX = "0000000000000000"

        // The internal fail-closed deadline keeps this reply margin under
        // the caller-supplied deadlineMs so every polled loop fails closed
        // and the structured fail payload reaches the MethodChannel before
        // any outer (Dart) wrapper timeout set to the same deadlineMs.
        private const val DEADLINE_REPLY_MARGIN_MS = 5_000L
        private const val MIN_EFFECTIVE_DEADLINE_MS = 1_000L

        // The one joint seek is attempted only when at least this much of
        // the effective deadline remains; otherwise it is skipped with the
        // explicit seekSkippedDeadline=true marker (the only legal way for
        // seekOk to be false).
        private const val SEEK_TIME_MARGIN_MS = 3_000L

        // Codec-chunk copy scratch, matching the native per-call ingest
        // clamp (AudioDecoderRingWriter kMaxWriteFrames).
        private const val SCRATCH_FRAMES = 8192

        // Stable failure-shaped result (same lane/metric key shape) for a
        // caller that never got a run.
        fun failedResult(reason: String): RunResult =
            AndroidAaudioNodeOwnedSinkDriver().makeResult(pass = false, failureReason = reason)
    }

    data class RunConfig(
        val sourcePath: String,
        val durationSec: Double = 0.6,
        val seekTargetSec: Double = 0.25,
        val sourceRingCapacityFrames: Int = 8192,
        val outputRingCapacityFrames: Int = 4096,
        // Default covers a full 1.0s window at 48 kHz so the muted pump
        // never has to park on realtime callback consumption.
        val sinkRingCapacityFrames: Int = 65536,
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

    private var session: AndroidAaudioNodeOwnedSinkNativeSession? = null

    // ── Format facts / Kotlin-side lockstep state ───────────────────────────
    private var sampleRate = 0
    private var channelCount = 0
    private var pcmEncoding = 0
    private var commonBudgetFrames = 0L
    private var framesTruncatedBeyondBudget = 0L
    private var totalFramesExtracted = 0L
    private var decoderBenignFormatChangeCount = 0L
    private var track1NonZeroSampleCount = 0L
    private var kotlinTrack0Checksum = 0L
    private var kotlinTrack1Checksum = 0L
    private var kotlinMixedChecksum = 0L
    private var kotlinFramesAccepted = 0L
    private var postSeekFramesAccepted = 0L
    private var seekAcceptedFrame = -1L
    private var seekSkippedDeadline = false
    private var cancellationPollCount = 0L

    // ── Lanes (fail-closed paths still report everything observed) ──────────
    private var formatProbeOk = false
    private var aaudioRuntimeAvailableOk = false
    private var aaudioSymbolsResolvedOk = false
    private var aaudioStreamOpenOk = false
    private var aaudioConfigOk = false
    private var aaudioStartOk = false
    private var callbackObservedOk = false
    private var mutedOutputOk = false
    private var nodeOwnedRouteDiscoveryOk = false
    private var nodeOwnsRingTrack0Ok = false
    private var nodeOwnsRingTrack1Ok = false
    private var track0IngestOk = false
    private var track1SyntheticIngestOk = false
    private var jointDispatchGateOk = false
    private var graphOutputChecksumOk = false
    private var aaudioCallbackAccountingOk = false
    private var seekOk = false
    private var jointTailFlushOk = false
    private var noProviderUnderrunOk = false
    private var noGraphSilenceOk = false
    private var noRingPushShortfallOk = false
    private var zeroNativeSteadyStateAllocationOk = false
    private var ownerThreadOk = false
    private var lifecycleOk = false
    private val detailParts = mutableListOf<String>()

    // Deterministic, non-silent, low-amplitude (|v| <= 504) synthetic
    // sample on the shared accepted-frame axis; low enough that clipping
    // against the real track is unlikely, while the reference mix still
    // clamps exactly like the native mix bus.
    private fun syntheticSample(frameIndex: Long, channel: Int): Int =
        ((frameIndex * 7L + channel * 3L) % 1009L).toInt() - 504

    fun run(config: RunConfig): RunResult {
        // Reserve the reply margin under the caller's deadline so a
        // fail-closed run always replies before an equal outer timeout.
        val runDeadlineMs = SystemClock.elapsedRealtime() +
            (config.deadlineMs - DEADLINE_REPLY_MARGIN_MS)
                .coerceAtLeast(MIN_EFFECTIVE_DEADLINE_MS)
        val s = AndroidAaudioNodeOwnedSinkNativeSession(runDeadlineMs)
        session = s
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null

        try {
            if (config.sourcePath.isBlank()) throw FailClosed("source_path_required")
            val windowSec = config.durationSec
                .coerceAtLeast(MIN_WINDOW_SEC)
                .coerceAtMost(HARD_MAX_DURATION_SEC)
            if (config.seekTargetSec < 0.0 || config.seekTargetSec >= windowSec) {
                throw FailClosed("invalid_seek_target")
            }
            if (config.maxFramesPerMix <= 0) throw FailClosed("invalid_max_frames_per_mix")
            val windowUs = (windowSec * 1_000_000.0).toLong()
            val seekTargetUs = (config.seekTargetSec * 1_000_000.0).toLong()
            val mfpm = config.maxFramesPerMix

            fun pollCancelled() {
                cancellationPollCount++
                if (cancelled()) throw FailClosed("cancelled_by_dispose")
                if (SystemClock.elapsedRealtime() > runDeadlineMs) {
                    throw FailClosed("deadline_exceeded")
                }
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

            // Missing KEY_PCM_ENCODING means ENCODING_PCM_16BIT.
            fun readOutputFormat(): Triple<Int, Int, Int> {
                val f = dec.outputFormat
                val enc = if (f.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                    f.getInteger(MediaFormat.KEY_PCM_ENCODING)
                } else {
                    AudioFormat.ENCODING_PCM_16BIT
                }
                return Triple(
                    f.getInteger(MediaFormat.KEY_SAMPLE_RATE),
                    f.getInteger(MediaFormat.KEY_CHANNEL_COUNT),
                    enc,
                )
            }

            // First format resolution: validates PCM16 + 1-2 channels,
            // fixes the common budget L, creates the native graph rig with
            // expectedFrameCount = L, verifies the node-owned auto-discovery
            // lanes, performs the staged AAudio bring-up + transport start
            // (consuming the start ack through an ack-only pump), and hoists
            // the direct buffers. The synthetic track inherits this exact
            // format: no resampling, no downmix.
            fun establishSession() {
                val (sr, ch, enc) = readOutputFormat()
                if (enc != AudioFormat.ENCODING_PCM_16BIT) {
                    throw FailClosed("unsupported_pcm_encoding:$enc")
                }
                if (ch != 1 && ch != 2) throw FailClosed("unsupported_channel_count:$ch")
                if (sr <= 0) throw FailClosed("invalid_sample_rate:$sr")
                sampleRate = sr
                channelCount = ch
                pcmEncoding = enc
                commonBudgetFrames = (windowSec * sr).toLong()
                if (commonBudgetFrames <= 0L) throw FailClosed("invalid_common_budget")
                if (commonBudgetFrames > Int.MAX_VALUE.toLong()) {
                    throw FailClosed("common_budget_exceeds_int")
                }
                bytesPerFrame = 2 * ch
                s.create(
                    sr, ch,
                    commonBudgetFrames.toInt(),
                    config.sourceRingCapacityFrames,
                    config.outputRingCapacityFrames,
                    config.sinkRingCapacityFrames,
                    config.maxFramesPerMix,
                )
                nodeOwnedRouteDiscoveryOk =
                    s.routedSourceCount == 2L &&
                        s.routedSourceId0 ==
                            AndroidAaudioNodeOwnedSinkNativeSession.SOURCE0_NODE_ID &&
                        s.routedSourceId1 ==
                            AndroidAaudioNodeOwnedSinkNativeSession.SOURCE1_NODE_ID
                if (!nodeOwnedRouteDiscoveryOk) throw FailClosed("node_owned_route_mismatch")
                nodeOwnsRingTrack0Ok = s.nodeOwnsRingTrack0
                if (!nodeOwnsRingTrack0Ok) throw FailClosed("node_owns_ring_track0_false")
                nodeOwnsRingTrack1Ok = s.nodeOwnsRingTrack1
                if (!nodeOwnsRingTrack1Ok) throw FailClosed("node_owns_ring_track1_false")
                s.startAaudioAndConsumeAck()
                aaudioRuntimeAvailableOk = s.aaudioRuntimeAvailable
                aaudioSymbolsResolvedOk = s.aaudioSymbolsResolved
                aaudioStreamOpenOk = s.aaudioStreamOpen
                aaudioConfigOk = s.aaudioConfigVerified &&
                    s.streamSampleRate == sr.toLong() &&
                    s.streamChannelCount == ch.toLong()
                aaudioStartOk = s.aaudioStreamStarted
                if (!aaudioStartOk) throw FailClosed("aaudio_start_not_confirmed")
                scratch = ByteBuffer.allocateDirect(SCRATCH_FRAMES * bytesPerFrame)
                    .order(ByteOrder.LITTLE_ENDIAN)
                chunk0 = ByteBuffer.allocateDirect(mfpm * bytesPerFrame)
                    .order(ByteOrder.LITTLE_ENDIAN)
                chunk1 = ByteBuffer.allocateDirect(mfpm * bytesPerFrame)
                    .order(ByteOrder.LITTLE_ENDIAN)
                formatProbeOk = true
            }

            // Once the session format is established, a repeated format
            // change with identical sampleRate/channelCount/PCM encoding is
            // benign and counted; any difference is malignant (the AAudio
            // stream format is frozen).
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

            // Lockstep ingest of [frames] real frames read from [slice]
            // starting at frame offset [sliceFrameOffset]: copies the real
            // sub-chunk to chunk0, synthesizes the identical frame count
            // into chunk1 on the shared accepted-frame axis, streams the
            // Kotlin reference checksums (track0/track1/mixed) BEFORE the
            // buffers cross into native (lossless lockstep ingest may
            // compact them), then hands both to the session.
            fun ingestLockstepSubChunk(slice: ByteBuffer, sliceFrameOffset: Int, frames: Int) {
                val c0 = chunk0!!
                val c1 = chunk1!!
                slice.limit((sliceFrameOffset + frames) * bytesPerFrame)
                slice.position(sliceFrameOffset * bytesPerFrame)
                c0.clear()
                c0.put(slice)
                val base = kotlinFramesAccepted
                val ch = channelCount
                val sampleCount = frames * ch
                for (i in 0 until sampleCount) {
                    val s0 = c0.getShort(i * 2).toInt()
                    val s1 = syntheticSample(base + (i / ch), i % ch)
                    c1.putShort(i * 2, s1.toShort())
                    if (s1 != 0) track1NonZeroSampleCount += 1
                    kotlinTrack0Checksum = kotlinTrack0Checksum * 31L + (s0.toLong() and 0xFFFFL)
                    kotlinTrack1Checksum = kotlinTrack1Checksum * 31L + (s1.toLong() and 0xFFFFL)
                    var acc = s0 + s1
                    if (acc > 32767) acc = 32767 else if (acc < -32768) acc = -32768
                    kotlinMixedChecksum = kotlinMixedChecksum * 31L + (acc.toLong() and 0xFFFFL)
                }
                s.ingestLockstepChunk(c0, c1, frames)
                kotlinFramesAccepted += frames
            }

            // Streams decoder output through the lockstep rig until the
            // codec reports output EOS; input EOS is queued once the
            // extractor passes [endUs]. Every codec chunk is copied into
            // direct ByteBuffers and the codec output buffer is released
            // BEFORE any JNI ingest/step/pump runs. Real frames beyond the
            // common budget L are truncated (explicit non-claim).
            fun decodePhase(endUs: Long) {
                val info = MediaCodec.BufferInfo()
                var inputDone = false
                var outputDone = false
                while (!outputDone) {
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
                                if (!s.isCreated) establishSession()
                                val scr = scratch!!
                                if (info.size % bytesPerFrame != 0) {
                                    dec.releaseOutputBuffer(outIdx, false)
                                    throw FailClosed("codec_chunk_shape_invalid:${info.size}")
                                }
                                val outBuf = dec.getOutputBuffer(outIdx)!!
                                // Split the codec chunk into slices of at
                                // most the scratch capacity, each copied to
                                // byte offset 0 of a direct buffer. All
                                // copies finish before the codec output
                                // buffer is released, and only then does any
                                // slice cross into native ingest/step/pump.
                                val sliceCapBytes = scr.capacity()
                                val slices = ArrayList<Pair<ByteBuffer, Int>>()
                                var sliceOffset = info.offset
                                var remainingBytes = info.size
                                while (remainingBytes > 0) {
                                    val sliceBytes = minOf(remainingBytes, sliceCapBytes)
                                    val dst = if (slices.isEmpty()) {
                                        scr
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
                                    totalFramesExtracted += sliceFrames
                                    var offsetFrames = 0
                                    while (offsetFrames < sliceFrames) {
                                        pollCancelled()
                                        val budgetLeft =
                                            commonBudgetFrames - kotlinFramesAccepted
                                        if (budgetLeft <= 0L) {
                                            framesTruncatedBeyondBudget +=
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
                                s.pumpWhileJointWindows()
                            } else {
                                dec.releaseOutputBuffer(outIdx, false)
                            }
                            if (isEos) outputDone = true
                        }
                        // INFO_TRY_AGAIN_LATER — the deadline bounds the wait.
                    }
                }
            }

            // ── Pre-seek decode: media [0, seekTarget] through the muted
            // sink rig ──────────────────────────────────────────────────────
            decodePhase(seekTargetUs)
            if (!s.isCreated) throw FailClosed("no_decoder_output")
            s.pumpWhileJointWindows()

            // ── Real callback consumption observed (muted frames popped by
            // the AAudio data callback) ─────────────────────────────────────
            s.waitForCallbackObserved()
            callbackObservedOk = true

            // ── Joint dispatch gate probe at the sub-window residual ────────
            s.probeJointDeferral()
            jointDispatchGateOk = s.jointDeferralObserved

            // ── Pre-seek boundary: joint EOS tail flush, then the one joint
            // accepted-frame-axis seek IF the deadline leaves room ──────────
            s.flushTailAtEos()
            val preSeekAccepted = s.totalFramesAcceptedTrack0
            if (runDeadlineMs - SystemClock.elapsedRealtime() > SEEK_TIME_MARGIN_MS) {
                val seekFrame = s.seekToAcceptedFrameBoundary()
                seekOk = true
                seekAcceptedFrame = seekFrame
                detailParts.add("seekAcceptedFrame=$seekFrame")
                detailParts.add("post_seek_media_content_overlap_permitted")

                // Extractor seek stays media-local; PREVIOUS_SYNC may land
                // early and re-decode content already ingested pre-seek
                // (non-claim recorded above). The synthetic generator
                // resumes on accepted frame axis A automatically (a pure
                // function of the accepted frame index).
                extractor.seekTo(seekTargetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                val postSeekStartUs =
                    extractor.sampleTime.let { if (it >= 0L) it else seekTargetUs }
                dec.flush()
                detailParts.add("postSeekStartUs=$postSeekStartUs")

                // ── Post-seek decode: the remaining window budget, then the
                // final joint EOS tail flush ────────────────────────────────
                decodePhase(postSeekStartUs + (windowUs - seekTargetUs))
                s.pumpWhileJointWindows()
                s.flushTailAtEos()
                postSeekFramesAccepted = s.totalFramesAcceptedTrack0 - preSeekAccepted
                if (postSeekFramesAccepted <= 0L) throw FailClosed("no_post_seek_frames_accepted")
            } else {
                // The only legal seekOk=false shape: explicitly marked
                // deadline skip. The pre-seek flush above already completed
                // the joint EOS tail boundary.
                seekSkippedDeadline = true
                detailParts.add("seekSkippedDeadline=true")
            }
            jointTailFlushOk = true
            detailParts.add("truncation_beyond_budget_l_non_claim")
            detailParts.add("preSeekFramesAccepted=$preSeekAccepted")
            detailParts.add("benignFormatChanges=$decoderBenignFormatChangeCount")
            detailParts.add("commonBudgetFrames=$commonBudgetFrames")
            detailParts.add("framesTruncatedBeyondBudget=$framesTruncatedBeyondBudget")

            // ── Owner-thread probe at a quiescent point (no in-flight codec
            // buffer: every decode phase is complete) ───────────────────────
            ownerThreadOk = s.probeForeignThreadRejected()
            if (!ownerThreadOk) throw FailClosed("foreign_thread_not_rejected")

            // ── Final snapshot + verdict lanes ──────────────────────────────
            val snapEnd = s.snapshotMetrics()

            noProviderUnderrunOk = s.providerUnderrunEventsTrack0 == 0L &&
                s.providerUnderrunEventsTrack1 == 0L &&
                s.providerFramesZeroFilledTrack0 == 0L &&
                s.providerFramesZeroFilledTrack1 == 0L
            if (!noProviderUnderrunOk) throw FailClosed("provider_underrun_observed")
            noGraphSilenceOk = s.coordinatorSilenceCount == 0L
            if (!noGraphSilenceOk) throw FailClosed("silence_window_observed")
            noRingPushShortfallOk = !s.ringPushShortfallSeen && !s.sinkPushShortfallSeen
            if (!noRingPushShortfallOk) throw FailClosed("ring_push_shortfall_observed")
            if (s.snapshotTerminal) throw FailClosed("terminal_state_observed")
            if (s.snapshotAwaitingSeekAck) throw FailClosed("seek_ack_still_pending")
            zeroNativeSteadyStateAllocationOk = s.verifyZeroSteadyStateAllocation(snapEnd)
            if (!zeroNativeSteadyStateAllocationOk) {
                throw FailClosed("native_steady_state_allocation_detected")
            }

            if (s.totalFramesAcceptedTrack0 <= 0L) throw FailClosed("no_frames_accepted")
            if (s.totalFramesAcceptedTrack0 != s.totalFramesAcceptedTrack1 ||
                s.totalFramesAcceptedTrack0 != kotlinFramesAccepted
            ) {
                throw FailClosed("track_frame_axis_divergence")
            }
            // The mandatory proof window: at least MIN_WINDOW_SEC of mixed
            // PCM flowed through the muted sink.
            if (s.totalOutputFramesPumped < (MIN_WINDOW_SEC * sampleRate).toLong()) {
                throw FailClosed("window_below_minimum")
            }
            if (s.totalOutputFramesPumped != s.totalFramesAcceptedTrack0 ||
                s.totalMutedFramesPushed != s.totalOutputFramesPumped
            ) {
                throw FailClosed("pump_frame_accounting_mismatch")
            }

            val kotlin0Hex = String.format("%016x", kotlinTrack0Checksum)
            val kotlin1Hex = String.format("%016x", kotlinTrack1Checksum)
            val kotlinMixHex = String.format("%016x", kotlinMixedChecksum)
            track0IngestOk = kotlin0Hex == s.nativeAcceptedChecksumHexTrack0
            if (!track0IngestOk) throw FailClosed("track0_checksum_identity_mismatch")
            track1SyntheticIngestOk = kotlin1Hex == s.nativeAcceptedChecksumHexTrack1 &&
                track1NonZeroSampleCount > 0L
            if (!track1SyntheticIngestOk) throw FailClosed("track1_checksum_identity_mismatch")
            // The graph output checksum is computed natively over the REAL
            // mixed PCM before the zero-scale, so it must equal the Kotlin
            // reference mix — proving the muted sink consumed a faithful
            // mix, not silence at the graph output.
            graphOutputChecksumOk = kotlinMixHex == s.nativeOutputDrainChecksumHex &&
                kotlinMixHex != ZERO_CHECKSUM_HEX
            if (!graphOutputChecksumOk) throw FailClosed("graph_output_checksum_mismatch")

            // Muted proof: native latch (every pushed sample zero) plus the
            // constant-zero muted checksum (c = c*31 + 0 stays 0).
            mutedOutputOk = s.mutedOutputOkNative && s.mutedSinkChecksumHex == ZERO_CHECKSUM_HEX
            if (!mutedOutputOk) throw FailClosed("muted_output_not_proven")

            // ── Lifecycle: owner-thread destroy (stops/closes the AAudio
            // stream) whose first reply carries the coherent post-close
            // callback counters for the accounting lane ─────────────────────
            lifecycleOk = s.destroyAndVerifyLifecycle()
            if (!lifecycleOk) throw FailClosed("lifecycle_destroy_not_idempotent")
            aaudioCallbackAccountingOk = s.finalCallbackCountersCoherent &&
                s.callbackInvocationCount > 0L &&
                s.callbackFramesServed > 0L &&
                s.callbackFramesRequested ==
                    s.callbackFramesServed + s.callbackSilenceFrames
            if (!aaudioCallbackAccountingOk) throw FailClosed("callback_accounting_mismatch")
            if (!mutedOutputOk || !s.mutedOutputOkNative) {
                throw FailClosed("muted_output_regressed_at_close")
            }

            return makeResult(pass = true, failureReason = "")
        } catch (e: Throwable) {
            val reason = when (e) {
                is FailClosed -> e.reason
                is AndroidAaudioNodeOwnedSinkNativeSession.Failure -> e.reason
                else -> "exception:${e.javaClass.simpleName}:${e.message}"
            }
            return makeResult(pass = false, failureReason = reason)
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
            // Owner-thread finally: native destroy (including the AAudio
            // stop/close) must run on this same worker thread.
            s.cleanup()
        }
    }

    private fun makeResult(pass: Boolean, failureReason: String): RunResult {
        val s = session
        val lanes = mapOf<String, Any?>(
            "formatProbeOk" to formatProbeOk,
            "aaudioRuntimeAvailableOk" to aaudioRuntimeAvailableOk,
            "aaudioSymbolsResolvedOk" to aaudioSymbolsResolvedOk,
            "aaudioStreamOpenOk" to aaudioStreamOpenOk,
            "aaudioConfigOk" to aaudioConfigOk,
            "aaudioStartOk" to aaudioStartOk,
            "callbackObservedOk" to callbackObservedOk,
            "mutedOutputOk" to mutedOutputOk,
            "nodeOwnedRouteDiscoveryOk" to nodeOwnedRouteDiscoveryOk,
            "nodeOwnsRingTrack0Ok" to nodeOwnsRingTrack0Ok,
            "nodeOwnsRingTrack1Ok" to nodeOwnsRingTrack1Ok,
            "track0IngestOk" to track0IngestOk,
            "track1SyntheticIngestOk" to track1SyntheticIngestOk,
            "jointDispatchGateOk" to jointDispatchGateOk,
            "graphOutputChecksumOk" to graphOutputChecksumOk,
            "aaudioCallbackAccountingOk" to aaudioCallbackAccountingOk,
            // May be false only with metrics.seekSkippedDeadline == true.
            "seekOk" to seekOk,
            "jointTailFlushOk" to jointTailFlushOk,
            "noProviderUnderrunOk" to noProviderUnderrunOk,
            "noGraphSilenceOk" to noGraphSilenceOk,
            "noRingPushShortfallOk" to noRingPushShortfallOk,
            "zeroNativeSteadyStateAllocationOk" to zeroNativeSteadyStateAllocationOk,
            "ownerThreadOk" to ownerThreadOk,
            "lifecycleOk" to lifecycleOk,
            "canonical" to pass,
        )
        val metrics = mapOf<String, Any?>(
            "sampleRate" to sampleRate,
            "channelCount" to channelCount,
            "pcmEncoding" to pcmEncoding,
            "commonBudgetFrames" to commonBudgetFrames,
            "expectedFrameCount" to commonBudgetFrames,
            "totalFramesExtracted" to totalFramesExtracted,
            "framesTruncatedBeyondBudget" to framesTruncatedBeyondBudget,
            "totalFramesAcceptedTrack0" to (s?.totalFramesAcceptedTrack0 ?: 0L),
            "totalFramesAcceptedTrack1" to (s?.totalFramesAcceptedTrack1 ?: 0L),
            "totalOutputFramesPumped" to (s?.totalOutputFramesPumped ?: 0L),
            "totalMutedFramesPushed" to (s?.totalMutedFramesPushed ?: 0L),
            "postSeekFramesAccepted" to postSeekFramesAccepted,
            "seekAcceptedFrame" to seekAcceptedFrame,
            "seekSkippedDeadline" to seekSkippedDeadline,
            "track1NonZeroSampleCount" to track1NonZeroSampleCount,
            "decoderBenignFormatChangeCount" to decoderBenignFormatChangeCount,
            "nativeAcceptedChecksumHexTrack0" to (s?.nativeAcceptedChecksumHexTrack0 ?: ""),
            "nativeAcceptedChecksumHexTrack1" to (s?.nativeAcceptedChecksumHexTrack1 ?: ""),
            "nativeOutputDrainChecksumHex" to (s?.nativeOutputDrainChecksumHex ?: ""),
            "mutedSinkChecksumHex" to (s?.mutedSinkChecksumHex ?: ""),
            "kotlinAcceptedChecksumHexTrack0" to String.format("%016x", kotlinTrack0Checksum),
            "kotlinAcceptedChecksumHexTrack1" to String.format("%016x", kotlinTrack1Checksum),
            "kotlinReferenceMixChecksumHex" to String.format("%016x", kotlinMixedChecksum),
            "routedSourceId0" to (s?.routedSourceId0 ?: ""),
            "routedSourceId1" to (s?.routedSourceId1 ?: ""),
            "dispatchCount" to (s?.dispatchCount ?: 0L),
            "nextDispatchFrame" to (s?.nativeNextDispatchFrame ?: 0L),
            "coordinatorSilenceCount" to (s?.coordinatorSilenceCount ?: -1L),
            "providerUnderrunEventsTrack0" to (s?.providerUnderrunEventsTrack0 ?: -1L),
            "providerUnderrunEventsTrack1" to (s?.providerUnderrunEventsTrack1 ?: -1L),
            "deviceApiLevel" to (s?.deviceApiLevel ?: 0L),
            "streamSampleRate" to (s?.streamSampleRate ?: 0L),
            "streamChannelCount" to (s?.streamChannelCount ?: 0L),
            "streamFormat" to (s?.streamFormat ?: 0L),
            "aaudioChannelCountSymbolFallback" to (s?.aaudioChannelCountSymbolFallback ?: false),
            "callbackInvocationCount" to (s?.callbackInvocationCount ?: 0L),
            "callbackFramesRequested" to (s?.callbackFramesRequested ?: 0L),
            "callbackFramesServed" to (s?.callbackFramesServed ?: 0L),
            "callbackSilenceFrames" to (s?.callbackSilenceFrames ?: 0L),
            "callbackShortReads" to (s?.callbackShortReads ?: 0L),
            "errorCallbackCount" to (s?.errorCallbackCount ?: 0L),
            "finalCallbackCountersCoherent" to (s?.finalCallbackCountersCoherent ?: false),
            "sinkFullWaitCount" to (s?.sinkFullWaitCount ?: 0L),
            "sinkAvailableReadFramesFinal" to (s?.sinkAvailableReadFrames ?: -1L),
            "cancellationPollCount" to cancellationPollCount,
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
