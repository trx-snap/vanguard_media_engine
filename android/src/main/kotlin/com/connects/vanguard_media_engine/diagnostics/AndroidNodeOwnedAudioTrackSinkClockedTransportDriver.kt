package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.SystemClock
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidNodeOwnedAudioTrackSinkClockedTransportDriver ────────────────────
// (P4-AUDIO-NODE-OWNED-SINK-CLOCKED-TRANSPORT, sub-slice O of
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS)
//
// Combines the proven sub-slice N real MediaExtractor/MediaCodec decode ->
// NODE-OWNED DecodedAudioPcmSourceNode graph pipeline ingestion with a
// MUTED android.media.AudioTrack MODE_STREAM sink egress through the new
// readNodeOwnedAudioSourceGraphPipelineOutputPcm16 JNI read path, with the
// AudioTrack as the KOTLIN TIMEBASE MASTER after pre-roll:
//   - Bootstrap dispatches only enough frame-derived virtual ticks to
//     pre-roll the AudioTrack (frozen positive frame count, head still at
//     the epoch baseline), then play() and capture the steady-state
//     underrun baseline.
//   - After the play() gate every dispatch target derives from
//     [AndroidNodeOwnedSinkClockedTimebase] (playback head / conditional
//     AudioTimestamp position + targetLeadFrames), clamped to one mix
//     window so the proven single-window underrun-gate step semantics hold,
//     then converted to a caller-derived sysTimeNs tick. C++ AudioClock and
//     ClockedAudioTransportCoordinator are unchanged and caller-clocked;
//     native never reads a wall clock (System.nanoTime() lives in the
//     Kotlin timebase only).
//   - The read path is the single output consumption path: this driver
//     never calls the checksum-only
//     drainNodeOwnedAudioSourceGraphPipelineOutput.
//
// Ownership split: Kotlin owns MediaExtractor, MediaCodec, AudioTrack, the
// source/temp media path, the single worker loop, deadlines, cancellation
// polling, and every OS error; native owns graph topology, the node-owned
// source ring/writer/provider triple, scheduler/mix/transport, and the
// output ring only.
//
// Honest non-claims: see [PROOF_BOUNDARY]. volume is always 0.0
// (mutedOutputOk); no audible-output claim, no speaker-route verification,
// no audio quality/glitch-freedom/latency claim, no realtime A/V sync, no
// audio focus/becoming-noisy/route-change handling, no dead-object
// recovery. Device AudioTrack.underrunCount is captured per epoch
// (baseline/final/delta) as TELEMETRY ONLY and never gates the verdict:
// HAL/device underrun freedom on this muted diagnostic sink is a
// non-claim, and steadyStateUnderrunFreeOk covers the NATIVE
// provider/coordinator steady state only.
class AndroidNodeOwnedAudioTrackSinkClockedTransportDriver(
    private val cancelled: () -> Boolean = { false },
) {

    companion object {
        const val PASS_MARKER =
            "ANDROID_DAG_PHASE4_NODE_OWNED_SINK_CLOCKED_TRANSPORT_SMOKE_PASS"
        const val FAIL_MARKER =
            "ANDROID_DAG_PHASE4_NODE_OWNED_SINK_CLOCKED_TRANSPORT_SMOKE_FAIL"
        const val PROOF_BOUNDARY =
            "kotlin_owned_android_audiotrack_node_owned_source_sink_clocked_transport_diagnostic_proof_only_real_decoder_to_node_owned_decoded_audio_source_graph_pipeline_output_ring_to_audiotrack_write_accounting_sink_clocked_timebase_audio_timestamp_conditional_playback_head_fallback_system_nanotime_anchor_kotlin_only_no_cpp_wall_clock_read_no_native_audio_sink_no_aaudio_no_opensl_no_oboe_no_audible_output_claim_no_speaker_route_verification_no_audio_quality_claim_no_glitch_freedom_no_latency_budget_no_realtime_av_sync_no_audio_focus_no_becoming_noisy_no_route_change_handling_no_dead_object_recovery_no_offload_no_low_latency_mode_no_production_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_streaming_no_cache_no_ios_single_routed_track_unit_gain_only_no_resample_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_single_kotlin_worker_thread_all_jni_and_audiotrack_calls_no_jni_reverse_callbacks_no_native_worker_threads_jni_session_registry_mutex_lifecycle_only_no_locks_in_vanguard_audio_primitives_direct_bytebuffer_reused_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim"

        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val HARD_MAX_DURATION_SEC = 2.0

        // The internal fail-closed deadline keeps this reply margin under the
        // caller-supplied deadlineMs so every polled loop fails closed and the
        // structured fail payload reaches the MethodChannel before any outer
        // (Dart) wrapper timeout that was set to the same deadlineMs value.
        private const val DEADLINE_REPLY_MARGIN_MS = 5_000L
        private const val MIN_EFFECTIVE_DEADLINE_MS = 1_000L
        private const val ANCHOR_SYS_TIME_NS = 1_000_000_000L
        private const val EXPECTED_SOURCE_NODE_ID = "node_owned_pipeline_src"

        // expectedFrameCount = this * sampleRate: the node's own 10-second
        // timeline-window ceiling, covering the whole pre+post-seek
        // accepted-frame axis of a <= 2 s proof window (see sub-slice N).
        private const val EXPECTED_FRAME_SECONDS = 10

        // Matches the native per-call ingest clamp (AudioDecoderRingWriter
        // kMaxWriteFrames).
        private const val SCRATCH_FRAMES = 8192

        // Frozen pre-roll: at least this many full mix windows are dispatched
        // with virtual frame-derived ticks and written (head still at the
        // epoch baseline) before play(); everything after the play() gate is
        // sink-clocked. PREROLL_WINDOWS * maxFramesPerMix is only the quota
        // FLOOR: the effective per-run prerollFrames is aligned with the
        // track's start threshold (see alignPrerollWithStartThreshold),
        // because a MODE_STREAM head never starts consuming below that
        // threshold and the sink-clock write gate would then never open.
        // TARGET_LEAD_WINDOWS is the sink-clock lead; the AudioTrack buffer
        // floor exceeds bootstrap preroll + lead so no gated write ever
        // blocks and the fed sink stays ~lead frames ahead of the head.
        private const val PREROLL_WINDOWS = 6L
        private const val TARGET_LEAD_WINDOWS = 8L
        private const val TRACK_BUFFER_MIN_WINDOWS = 12L

        private const val MAX_CONSECUTIVE_ZERO_WRITES = 500
        private const val ZERO_WRITE_SLEEP_MS = 2L
        private const val SINK_GATE_SLEEP_MS = 2L
        private const val HEAD_POLL_SLEEP_MS = 5L
        private const val HEAD_CATCHUP_MARGIN_MS = 3_000L

        // Strict bound on tail-flush step iterations (largest legal ring is
        // 65536 frames at >= 1 rendered frame per rendering step).
        private const val MAX_TAIL_FLUSH_STEPS = 65_600

        // Stable failure-shaped result (same lane/metric key shape) for a
        // caller that never got a run.
        fun failedResult(reason: String): RunResult =
            AndroidNodeOwnedAudioTrackSinkClockedTransportDriver()
                .makeResult(pass = false, failureReason = reason)
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
    private var runDeadlineMs = 0L
    private var mfpm = 0L
    private var handle = 0L
    private var timebase: AndroidNodeOwnedSinkClockedTimebase? = null

    // ── Format / session facts ──────────────────────────────────────────────
    private var sampleRate = 0
    private var channelCount = 0
    private var pcmEncoding = 0
    private var bytesPerFrame = 0
    private var expectedFrameCount = 0L
    private var prerollFrames = 0L
    private var targetLeadFrames = 0L

    // ── Caller-derived tick math on the accepted-frame axis, re-based at
    // start() and seek() (native never reads a wall clock) ──────────────────
    private var anchorPtsUs = 0L
    private var anchorSysNs = ANCHOR_SYS_TIME_NS
    private var lastTickNs = Long.MIN_VALUE

    // ── Native pipeline mirrors ─────────────────────────────────────────────
    private var nextFrame = 0L
    private var sourceAvail = 0L
    private var outputAvail = 0L
    private var totalFramesAccepted = 0L
    private var totalOutputFramesDrained = 0L
    private var nativeAcceptedChecksumHex = ""
    private var nativeOutputDrainChecksumHex = ""
    private var dispatchCount = 0L
    private var providerUnderrunEvents = -1L
    private var providerFramesZeroFilled = -1L
    private var providerForwardSkipFrames = -1L
    private var providerRewindRejects = -1L
    private var coordinatorSilenceCount = -1L
    private var snapNextDispatchFrame = -1L
    private var schedCapBefore = -1L
    private var schedTracksBefore = -1L
    private var srcCapBefore = -1L
    private var outCapBefore = -1L

    // ── AudioTrack sink state ───────────────────────────────────────────────
    private var audioTrack: AudioTrack? = null
    private var audioTrackReleaseCount = 0
    private var nativeDestroyCallCount = 0L
    private var sinkBuffer: ByteBuffer? = null
    private var bufferSizeInFrames = 0L
    private var bufferCapacityInFrames = 0L
    private var startThresholdFrames = -1L

    // ── Epoch state: one epoch per AudioTrack write span ([start..seek] and
    // [seek..eos]); flush() opens a new epoch with a re-read head baseline ──
    private var epochBaseFrame = 0L
    private var epochFramesReadFromRing = 0L
    private var epochFramesWritten = 0L
    private var epochPlayed = false
    private var epochUnderrunBaseline = -1L
    private var epochSinkClockedDispatchCount = 0L
    private var epochsClosed = 0
    private var prerollEpochsSatisfied = 0
    private var boundariesDrained = 0
    private var tailFlushCompletions = 0
    private var sinkClockedDispatchCountEpoch0 = 0L
    private var sinkClockedDispatchCountEpoch1 = 0L

    // ── Totals & sink telemetry ─────────────────────────────────────────────
    private var totalFramesExtracted = 0L
    private var framesReadFromRingTotal = 0L
    private var framesWrittenTotal = 0L
    private var partialWriteCount = 0L
    private var zeroWriteCount = 0L
    private var kotlinSinkChecksum = 0L
    private var bootstrapDispatchCount = 0L
    private var playbackHeadFinal = 0L
    private var underrunBaselineFirst = -1L
    private var underrunFinalLast = -1L
    private var underrunDeltaTotal = 0L
    private var underrunEpochsCaptured = 0
    private var postSeekFramesAccepted = 0L
    private var postSeekFramesDrained = 0L
    private var seekAcceptedFrame = -1L
    private var cancellationPollCount = 0L

    // ── Lanes (fail-closed paths still report everything observed) ──────────
    private var formatProbeOk = false
    private var audioTrackInitOk = false
    private var mutedOutputOk = false
    private var nodeOwnedRouteDiscoveryOk = false
    private var nodeOwnsRingOk = false
    private var startAckOk = false
    private var sinkClockedDispatchOk = false
    private var playbackHeadAdvancedOk = false
    private var sinkWriteAccountingOk = false
    private var checksumIdentityOk = false
    private var frameAccountingOk = false
    private var seekOk = false
    private var tailFlushOk = false
    private var steadyStateUnderrunFreeOk = false
    private var noProviderUnderrunOk = false
    private var noSilenceOk = false
    private var noForwardSkipOk = false
    private var noRewindRejectOk = false
    private var finalNotTerminalOk = false
    private var finalSeekAckClearOk = false
    private var zeroNativeSteadyStateAllocationOk = false
    private var lifecycleOk = false
    private val detailParts = mutableListOf<String>()

    fun run(runConfig: RunConfig): RunResult {
        config = runConfig
        // Reserve the reply margin under the caller's deadline so a
        // fail-closed run always replies before an equal outer timeout.
        runDeadlineMs = SystemClock.elapsedRealtime() +
            (config.deadlineMs - DEADLINE_REPLY_MARGIN_MS)
                .coerceAtLeast(MIN_EFFECTIVE_DEADLINE_MS)
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
                return Triple(
                    f.getInteger(MediaFormat.KEY_SAMPLE_RATE),
                    f.getInteger(MediaFormat.KEY_CHANNEL_COUNT),
                    enc,
                )
            }

            // Mandatory ordering: probe format -> create muted AudioTrack
            // (STATE_INITIALIZED) -> create + start the native node-owned
            // session -> ack-only read through the new read path -> open
            // epoch 0. Pre-roll/play happen later as frames flow.
            fun establishSinkAndSession() {
                val (sr, ch, enc) = readOutputFormat()
                if (enc != AudioFormat.ENCODING_PCM_16BIT) {
                    throw FailClosed("unsupported_pcm_encoding:$enc")
                }
                if (ch != 1 && ch != 2) throw FailClosed("unsupported_channel_count:$ch")
                if (sr <= 0) throw FailClosed("invalid_sample_rate:$sr")
                sampleRate = sr
                channelCount = ch
                pcmEncoding = enc
                bytesPerFrame = 2 * ch
                prerollFrames = PREROLL_WINDOWS * mfpm
                targetLeadFrames = TARGET_LEAD_WINDOWS * mfpm
                createMutedAudioTrack(sr, ch)
                timebase = AndroidNodeOwnedSinkClockedTimebase(sr, targetLeadFrames)
                // One reused direct sink buffer for the whole run: exactly
                // maxFramesPerMix frames for every read -> AudioTrack.write.
                sinkBuffer = ByteBuffer.allocateDirect(config.maxFramesPerMix * bytesPerFrame)
                    .order(ByteOrder.LITTLE_ENDIAN)
                scratch = ByteBuffer.allocateDirect(SCRATCH_FRAMES * bytesPerFrame)
                    .order(ByteOrder.LITTLE_ENDIAN)
                expectedFrameCount = (EXPECTED_FRAME_SECONDS.toLong()) * sr
                handle = VanguardNativeBridge.createNodeOwnedAudioSourceGraphPipelineSmokeSession(
                    sr, ch, (EXPECTED_FRAME_SECONDS * sr),
                    config.sourceRingCapacityFrames,
                    config.outputRingCapacityFrames,
                    config.maxFramesPerMix,
                )
                if (handle == 0L) throw FailClosed("native_session_create_failed")

                val snapStart = snapshot()
                nodeOwnedRouteDiscoveryOk =
                    longField(snapStart, "routedSourceCount") == 1L &&
                        snapStart["routedSourceId0"] == EXPECTED_SOURCE_NODE_ID
                if (!nodeOwnedRouteDiscoveryOk) throw FailClosed("route_discovery_mismatch")
                nodeOwnsRingOk = snapStart["nodeOwnsRing"] == "true"
                if (!nodeOwnsRingOk) throw FailClosed("node_does_not_own_ring")
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
                consumeOutputRingAck(0L, "start")
                startAckOk = true
                openEpoch()
                formatProbeOk = true
            }

            // Identical repeat format change is benign; any drift is
            // malignant (the AudioTrack format is frozen).
            fun onOutputFormatChanged() {
                if (handle == 0L) {
                    establishSinkAndSession()
                    return
                }
                val (sr, ch, enc) = readOutputFormat()
                if (sr != sampleRate || ch != channelCount || enc != pcmEncoding) {
                    throw FailClosed("malignant_format_change")
                }
            }

            // Streams decoder output into the node-owned session until codec
            // output EOS; input EOS is queued once the extractor passes
            // [endUs]. Same copy/release policy as N/I: every slice is
            // copied to a direct buffer and the codec output buffer is
            // released before any JNI call runs.
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
                                if (handle == 0L) establishSinkAndSession()
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
                                    totalFramesExtracted += sliceFrames
                                    ingestLossless(sliceBuf, sliceFrames)
                                }
                                pumpAfterIngest()
                            } else {
                                dec.releaseOutputBuffer(outIdx, false)
                            }
                            if (isEos) outputDone = true
                        }
                        // INFO_TRY_AGAIN_LATER — the deadline bounds the wait.
                    }
                    if (epochPlayed) {
                        timebase!!.samplePositionFrames(
                            audioTrack!!, epochFramesWritten, true,
                        )
                    }
                }
            }

            // ── Pre-seek: decode media [0, seekTarget] through the sink ─────
            decodePhase(seekTargetUs)
            if (handle == 0L) throw FailClosed("no_decoder_output")
            flushTailAtEos()
            captureEpochUnderrunDelta("epoch0")
            waitForHeadCatchUp("pre_seek")
            closeEpochAccounting("epoch0")
            val preSeekAccepted = totalFramesAccepted
            val preSeekDrained = totalOutputFramesDrained
            if (preSeekAccepted <= 0L) throw FailClosed("no_pre_seek_frames_accepted")
            if (preSeekAccepted != nextFrame) throw FailClosed("pre_seek_cursor_mismatch")

            // ── AudioTrack seek lifecycle: pause -> flush -> new epoch ->
            // native accepted-frame-axis seek -> ack-only read through the
            // new read path (slice N forward-only seek semantics) ───────────
            val track = audioTrack!!
            track.pause()
            track.flush()
            openEpoch()
            if (epochFramesWritten != 0L || epochFramesReadFromRing != 0L) {
                throw FailClosed("seek_epoch_counters_not_reset")
            }
            val seekTargetFrame = nextFrame
            val seekPtsUs = ceilDiv(seekTargetFrame * 1_000_000L, sampleRate.toLong())
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
            consumeOutputRingAck(seekTargetFrame, "seek")
            seekOk = true
            seekAcceptedFrame = seekTargetFrame
            detailParts.add("seekAcceptedFrame=$seekTargetFrame")
            detailParts.add("post_seek_media_content_overlap_permitted")

            // Extractor seek stays media-local; PREVIOUS_SYNC may land early
            // and re-decode content already ingested pre-seek (non-claim
            // recorded above).
            extractor.seekTo(seekTargetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val postSeekStartUs =
                extractor.sampleTime.let { if (it >= 0L) it else seekTargetUs }
            dec.flush()
            detailParts.add("postSeekStartUs=$postSeekStartUs")

            // ── Post-seek: remaining window budget through the sink, then
            // the final EOS/tail boundary and stop() ────────────────────────
            decodePhase(postSeekStartUs + (windowUs - seekTargetUs))
            flushTailAtEos()
            captureEpochUnderrunDelta("epoch1")
            waitForHeadCatchUp("final")
            playbackHeadFinal = timebase!!.lastRawHeadEpochFrames
            playbackHeadAdvancedOk = playbackHeadFinal > 0L
            if (!playbackHeadAdvancedOk) throw FailClosed("playback_head_not_advanced")
            closeEpochAccounting("epoch1")
            track.stop()

            tailFlushOk = tailFlushCompletions == 2 && boundariesDrained == 2
            if (!tailFlushOk) throw FailClosed("tail_flush_boundary_missing")
            if (prerollEpochsSatisfied != 2) throw FailClosed("preroll_not_satisfied")
            postSeekFramesAccepted = totalFramesAccepted - preSeekAccepted
            postSeekFramesDrained = totalOutputFramesDrained - preSeekDrained
            if (postSeekFramesAccepted <= 0L) throw FailClosed("no_post_seek_frames_accepted")
            if (postSeekFramesDrained <= 0L) throw FailClosed("no_post_seek_frames_drained")

            // ── Final snapshot + verdict lanes ──────────────────────────────
            val snapEnd = snapshot()
            if (longField(snapEnd, "routedSourceCount") != 1L ||
                snapEnd["routedSourceId0"] != EXPECTED_SOURCE_NODE_ID ||
                snapEnd["nodeOwnsRing"] != "true"
            ) {
                throw FailClosed("route_discovery_drifted")
            }
            noProviderUnderrunOk = providerUnderrunEvents == 0L &&
                providerFramesZeroFilled == 0L
            if (!noProviderUnderrunOk) throw FailClosed("provider_underrun_observed")
            noSilenceOk = coordinatorSilenceCount == 0L
            if (!noSilenceOk) throw FailClosed("silence_window_observed")
            noForwardSkipOk = providerForwardSkipFrames == 0L
            if (!noForwardSkipOk) throw FailClosed("provider_forward_skip_observed")
            noRewindRejectOk = providerRewindRejects == 0L
            if (!noRewindRejectOk) throw FailClosed("provider_rewind_reject_observed")
            finalNotTerminalOk = snapEnd["terminal"] != "true"
            if (!finalNotTerminalOk) throw FailClosed("terminal_state_observed")
            finalSeekAckClearOk = snapEnd["awaitingSeekAck"] != "true"
            if (!finalSeekAckClearOk) throw FailClosed("seek_ack_still_pending")

            zeroNativeSteadyStateAllocationOk = dispatchCount > 0L &&
                schedCapBefore == longField(snapEnd, "schedulerTrackScratchCapacitySamples") &&
                schedTracksBefore == longField(snapEnd, "schedulerTrackScratchCapacityTracks") &&
                srcCapBefore == longField(snapEnd, "sourceRingStorageCapacitySamples") &&
                outCapBefore == longField(snapEnd, "outputRingStorageCapacitySamples")
            if (!zeroNativeSteadyStateAllocationOk) {
                throw FailClosed("native_steady_state_allocation_detected")
            }

            if (framesWrittenTotal <= 0L) throw FailClosed("no_frames_written_to_sink")
            sinkWriteAccountingOk = epochsClosed == 2 &&
                framesReadFromRingTotal == framesWrittenTotal &&
                framesReadFromRingTotal == totalOutputFramesDrained
            if (!sinkWriteAccountingOk) throw FailClosed("sink_write_accounting_mismatch")

            frameAccountingOk = totalFramesAccepted == totalOutputFramesDrained &&
                totalFramesAccepted == framesWrittenTotal &&
                totalFramesAccepted == nextFrame
            if (!frameAccountingOk) throw FailClosed("frame_accounting_mismatch")

            val kotlinSinkHex = String.format("%016x", kotlinSinkChecksum)
            checksumIdentityOk = kotlinSinkHex == nativeOutputDrainChecksumHex &&
                kotlinSinkHex == nativeAcceptedChecksumHex
            if (!checksumIdentityOk) throw FailClosed("checksum_identity_mismatch")

            val tb = timebase!!
            sinkClockedDispatchOk = sinkClockedDispatchCountEpoch0 > 0L &&
                sinkClockedDispatchCountEpoch1 > 0L &&
                tb.maxDispatchLeadFrames in 1L..targetLeadFrames &&
                tb.minDispatchLeadFrames >= 1L
            if (!sinkClockedDispatchOk) throw FailClosed("sink_clocked_dispatch_not_proven")

            // Native steady state only: the provider/coordinator lanes above
            // already hard-gate no-underrun/no-silence, so this lane adds
            // only that both epochs actually captured their device underrun
            // telemetry. The HAL AudioTrack.underrunCount delta itself
            // (underrunDelta) is telemetry, never a gate, and is reported
            // with its real observed value.
            steadyStateUnderrunFreeOk = underrunEpochsCaptured == 2 &&
                noProviderUnderrunOk && noSilenceOk
            if (!steadyStateUnderrunFreeOk) {
                throw FailClosed("steady_state_underrun_capture_incomplete")
            }
            detailParts.add("audioTrackUnderrunDeltaTelemetryOnly")

            // ── Lifecycle lane: idempotent any-thread native destroy plus
            // exactly-once AudioTrack release ───────────────────────────────
            val destroyKv = parseStatus(
                VanguardNativeBridge.destroyNodeOwnedAudioSourceGraphPipelineSmokeSession(handle)
            )
            nativeDestroyCallCount++
            val destroyAgainKv = parseStatus(
                VanguardNativeBridge.destroyNodeOwnedAudioSourceGraphPipelineSmokeSession(handle)
            )
            nativeDestroyCallCount++
            val postDestroySnapshotKv = parseStatus(
                VanguardNativeBridge.snapshotNodeOwnedAudioSourceGraphPipeline(handle)
            )
            handle = 0L
            releaseAudioTrackOnce(guardedStop = false)
            lifecycleOk = destroyKv["status"] == "ok" &&
                destroyAgainKv["status"] == "not_found" &&
                postDestroySnapshotKv["status"] == "not_found" &&
                audioTrackReleaseCount == 1
            if (!lifecycleOk) throw FailClosed("lifecycle_not_clean")

            return makeResult(pass = true, failureReason = "")
        } catch (e: Throwable) {
            val reason = when (e) {
                is FailClosed -> e.reason
                is AndroidNodeOwnedSinkClockedTimebase.Invalid -> e.reason
                else -> "exception:${e.javaClass.simpleName}:${e.message}"
            }
            return makeResult(pass = false, failureReason = reason)
        } finally {
            // Every path (including dispose cancellation): guarded
            // pause/flush/release exactly once, then codec/extractor
            // release, then idempotent native destroy.
            releaseAudioTrackOnce(guardedStop = true)
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
            if (handle != 0L) {
                try {
                    VanguardNativeBridge.destroyNodeOwnedAudioSourceGraphPipelineSmokeSession(handle)
                    nativeDestroyCallCount++
                } catch (_: Throwable) {}
                handle = 0L
            }
        }
    }

    // ── Ingest (lossless, sink-clocked backpressure) ────────────────────────

    // Losslessly ingests [frames] PCM16 frames held at byte offset 0 of the
    // direct buffer [buf]: partially accepted chunks are compacted to byte
    // offset 0 and retried; ring backpressure is relieved only by the sink
    // clock making windows due (after play), so a full ring parks briefly
    // on the real AudioTrack consumption. No decoded frame is ever dropped.
    private fun ingestLossless(buf: ByteBuffer, frames: Int) {
        var remaining = frames
        while (remaining > 0) {
            pollCancellation()
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
            sourceAvail = longField(kv, "sourceAvailableReadFrames")
            if (accepted > 0) {
                totalFramesAccepted = longField(kv, "totalFramesAccepted")
                nativeAcceptedChecksumHex = kv["nativeAcceptedChecksumHex"] ?: ""
                if (accepted < remaining) compactRemainder(buf, accepted, remaining)
                remaining -= accepted
            }
            if (remaining > 0) {
                val dispatched = pumpAfterIngest()
                if (accepted == 0 && dispatched == 0L) {
                    // Ring full and no window due yet: only real sink
                    // consumption can free space now.
                    if (!epochPlayed) throw FailClosed("ingest_stalled_before_play")
                    SystemClock.sleep(SINK_GATE_SLEEP_MS)
                }
            }
        }
    }

    // Unwritten frames move to byte offset 0 so ingest retries always read
    // from the buffer start.
    private fun compactRemainder(buf: ByteBuffer, acceptedFrames: Int, totalFrames: Int) {
        buf.position(acceptedFrames * bytesPerFrame)
        buf.limit(totalFrames * bytesPerFrame)
        buf.compact()
    }

    // ── Dispatch: bootstrap (virtual ticks) then sink-clocked ───────────────

    // Bootstrap dispatches only enough frame-derived virtual ticks to
    // pre-roll the AudioTrack; once play() gates open, every further window
    // is dispatched only when the sink-clock target makes it due. Returns
    // the number of windows dispatched.
    private fun pumpAfterIngest(): Long {
        var dispatched = 0L
        while (!epochPlayed && epochFramesWritten < prerollFrames && sourceAvail >= mfpm) {
            bootstrapDispatchWindow()
            dispatched++
            playIfPrerolled(force = false)
        }
        if (epochPlayed) {
            while (sinkClockedDispatchWindowIfDue()) {
                dispatched++
            }
        }
        return dispatched
    }

    private fun bootstrapDispatchWindow() {
        val kv = stepWindow(nextFrame + mfpm, flushTail = false)
        if (kv["status"] != "dispatch_ok" || longField(kv, "framesRendered") != mfpm) {
            throw FailClosed("bootstrap_step_${kv["status"]}")
        }
        nextFrame += mfpm
        bootstrapDispatchCount++
        readWindowAndWrite(mfpm)
    }

    // One sink-gated full-window dispatch: the dispatch target derives from
    // the sink-clock target frame (position + targetLeadFrames), clamped to
    // one mix window so the proven single-window underrun-gate step
    // semantics hold. Returns false when the sink clock has not made a full
    // window due (or the source ring cannot cover one).
    private fun sinkClockedDispatchWindowIfDue(): Boolean {
        if (sourceAvail < mfpm) return false
        val tb = timebase!!
        val targetRel = tb.targetFrame(audioTrack!!, epochFramesWritten, epochPlayed)
        val cursorRel = nextFrame - epochBaseFrame
        if (cursorRel + mfpm > targetRel) return false
        val tickFrameAbs = epochBaseFrame + minOf(targetRel, cursorRel + mfpm)
        val kv = stepWindow(tickFrameAbs, flushTail = false)
        if (kv["status"] != "dispatch_ok" || longField(kv, "framesRendered") != mfpm) {
            throw FailClosed("sink_clocked_step_${kv["status"]}")
        }
        nextFrame += mfpm
        epochSinkClockedDispatchCount++
        tb.recordDispatchCursor(nextFrame - epochBaseFrame)
        readWindowAndWrite(mfpm)
        return true
    }

    // Parks until the sink-clock target covers the next [windowFrames]
    // window; the returned absolute dispatch tick frame derives from the
    // sink target (clamped to that window).
    private fun waitForSinkGate(windowFrames: Long): Long {
        val tb = timebase!!
        val cursorRel = nextFrame - epochBaseFrame
        while (true) {
            pollCancellation()
            val targetRel = tb.targetFrame(audioTrack!!, epochFramesWritten, epochPlayed)
            if (targetRel >= cursorRel + windowFrames) {
                return epochBaseFrame + minOf(targetRel, cursorRel + windowFrames)
            }
            SystemClock.sleep(SINK_GATE_SLEEP_MS)
        }
    }

    private fun stepWindow(tickFrameAbs: Long, flushTail: Boolean): Map<String, String> {
        pollCancellation()
        val kv = parseStatus(
            VanguardNativeBridge.stepNodeOwnedAudioSourceGraphPipeline(
                handle, tickForFrame(tickFrameAbs), flushTail,
            )
        )
        if (kv["status"] == "dispatch_silence") throw FailClosed("unexpected_silence_window")
        if (kv.containsKey("sourceAvailableReadFrames")) {
            sourceAvail = longField(kv, "sourceAvailableReadFrames")
        }
        if (kv.containsKey("outputAvailableReadFrames")) {
            outputAvail = longField(kv, "outputAvailableReadFrames")
        }
        return kv
    }

    // Writer-local EOS then a lossless sink-clocked tail flush: rendering
    // steps (full or partial windows) each read through the sink buffer and
    // written to the AudioTrack immediately, gated on the sink-clock target
    // once playing, until the node-owned source ring reports
    // tail_flush_complete. Preserves slice N tail semantics (native clamps
    // the tick to the anchored tail window).
    private fun flushTailAtEos() {
        val eosKv = parseStatus(
            VanguardNativeBridge.setNodeOwnedAudioSourceGraphPipelineEos(handle)
        )
        if (eosKv["status"] != "ok" || eosKv["eos"] != "true") {
            throw FailClosed("eos_set_failed_${eosKv["status"]}")
        }
        var guard = 0
        while (true) {
            pollCancellation()
            if (++guard > MAX_TAIL_FLUSH_STEPS) throw FailClosed("tail_flush_unbounded")
            val windowTarget = minOf(sourceAvail, mfpm)
            val tickFrameAbs = if (windowTarget > 0L && epochPlayed) {
                waitForSinkGate(windowTarget)
            } else {
                nextFrame + windowTarget
            }
            val kv = stepWindow(tickFrameAbs, flushTail = true)
            when (kv["status"]) {
                "tail_flush_complete" -> {
                    readResidualOutput()
                    tailFlushCompletions++
                    return
                }
                "dispatch_ok", "tail_flush_partial_window" -> {
                    val rendered = longField(kv, "framesRendered")
                    if (rendered <= 0L) throw FailClosed("tail_flush_zero_render")
                    nextFrame += rendered
                    if (epochPlayed) {
                        epochSinkClockedDispatchCount++
                        timebase!!.recordDispatchCursor(nextFrame - epochBaseFrame)
                    } else {
                        bootstrapDispatchCount++
                    }
                    readWindowAndWrite(rendered)
                    // A segment shorter than the pre-roll quota hits the
                    // forced-play policy here and fails closed below the
                    // threshold instead of claiming pre-roll.
                    if (!epochPlayed) playIfPrerolled(force = sourceAvail <= 0L)
                }
                else -> throw FailClosed("tail_flush_${kv["status"]}")
            }
        }
    }

    // ── Sink read -> AudioTrack write (the only output consumption path) ────

    private fun readPcm(maxFrames: Int): Map<String, String> {
        val kv = parseStatus(
            VanguardNativeBridge.readNodeOwnedAudioSourceGraphPipelineOutputPcm16(
                handle, sinkBuffer!!, maxFrames,
            )
        )
        if (kv["status"] != "ok") throw FailClosed("sink_read_status_${kv["status"]}")
        totalOutputFramesDrained = longField(kv, "totalOutputFramesDrained")
        nativeOutputDrainChecksumHex = kv["nativeOutputDrainChecksumHex"] ?: ""
        outputAvail = longField(kv, "outputAvailableReadFrames")
        return kv
    }

    // Ack-only read (maxFrames = 0) through the new read path; asserts the
    // start/seek output-ring ack is consumed cleanly with zero discards.
    private fun consumeOutputRingAck(expectedStartFrame: Long, label: String) {
        val kv = readPcm(0)
        if (kv["seekAckConsumed"] != "true" ||
            longField(kv, "newStartFrame") != expectedStartFrame ||
            longField(kv, "discardedFramesOnSeek") != 0L ||
            longField(kv, "framesRead") != 0L
        ) {
            throw FailClosed("${label}_ack_not_consumed_cleanly")
        }
    }

    // Reads exactly [frames] frames from the output ring through the reused
    // direct sink buffer (at most one mix window per read) and writes each
    // read's bytes to the AudioTrack before reading the ring again.
    private fun readWindowAndWrite(frames: Long) {
        var remaining = frames
        while (remaining > 0) {
            pollCancellation()
            val toRead = minOf(remaining, mfpm)
            val kv = readPcm(toRead.toInt())
            if (kv["seekAckConsumed"] == "true") throw FailClosed("unexpected_seek_ack_in_read")
            val framesRead = longField(kv, "framesRead")
            if (framesRead <= 0L) throw FailClosed("sink_read_short")
            accountFramesRead(framesRead)
            writeAllToAudioTrack((framesRead * bytesPerFrame).toInt())
            remaining -= framesRead
        }
    }

    // Safety drain after tail_flush_complete: every step is read
    // immediately, so this expects an already-empty output ring.
    private fun readResidualOutput() {
        var guard = 0
        while (outputAvail > 0L) {
            pollCancellation()
            if (++guard > MAX_TAIL_FLUSH_STEPS) throw FailClosed("residual_drain_unbounded")
            readWindowAndWrite(minOf(outputAvail, mfpm))
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
    // WRITE_NON_BLOCKING, fail-closed on every error code (including
    // DEAD_OBJECT — no recovery claim). Partial writes compact/retain the
    // unwritten remainder in the same buffer and retry; zero writes park
    // briefly under a bounded budget.
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
                }
                wrote == 0 -> {
                    zeroWriteCount++
                    if (++consecutiveZero > MAX_CONSECUTIVE_ZERO_WRITES) {
                        throw FailClosed("audio_track_write_stalled")
                    }
                    SystemClock.sleep(ZERO_WRITE_SLEEP_MS)
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

    // ── AudioTrack lifecycle / pre-roll / underrun accounting ───────────────

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
        val floorBytes = (TRACK_BUFFER_MIN_WINDOWS * mfpm * bytesPerFrame).toInt()
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
        bufferCapacityInFrames = track.bufferCapacityInFrames.toLong()
        alignPrerollWithStartThreshold(track)
        audioTrackInitOk = true
    }

    // A MODE_STREAM AudioTrack does not start consuming until its buffer
    // holds the start threshold of frames, which DEFAULTS TO THE FULL BUFFER
    // CAPACITY. This driver caps pre-play writes at prerollFrames and
    // post-play writes at sink position + targetLeadFrames, so a threshold
    // above both leaves the playback head parked at 0 and the sink-clock
    // gate closed forever (the observed physical stall). On API 31+ the
    // threshold is lowered to the pre-roll quota; where that API is
    // unavailable or the device refuses, the per-run pre-roll quota is
    // raised to the effective threshold instead, fail-closed if it cannot
    // fit the track buffer. No latency/low-latency-mode claim is added: this
    // only makes the muted diagnostic sink start at all under gated writes.
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
        // Bootstrap dispatch advances in whole mix windows, so the effective
        // quota is rounded up to a window multiple; it must fit the buffer
        // or the final pre-play (non-consuming) write could never complete.
        val neededPreroll = maxOf(prerollFrames, effectiveThreshold)
        prerollFrames = ceilDiv(neededPreroll, mfpm) * mfpm
        if (prerollFrames > bufferSizeInFrames) {
            throw FailClosed(
                "preroll_exceeds_track_buffer:$prerollFrames:$bufferSizeInFrames"
            )
        }
    }

    // Pre-roll gate: play() only after the frozen positive pre-roll frame
    // count is written this epoch, asserting the sink position is still 0.
    // A forced terminal boundary below the threshold fails closed instead
    // of playing early and claiming pre-roll. The steady-state underrun
    // baseline for the epoch is captured immediately after play().
    private fun playIfPrerolled(force: Boolean) {
        if (epochPlayed) return
        if (epochFramesWritten < prerollFrames) {
            if (!force) return
            if (epochFramesWritten <= 0L) throw FailClosed("preroll_no_frames_written")
            throw FailClosed("preroll_forced_below_threshold:$epochFramesWritten")
        }
        val positionBeforePlay = timebase!!.samplePositionFrames(
            audioTrack!!, epochFramesWritten, false,
        )
        if (positionBeforePlay != 0L) {
            throw FailClosed("preroll_position_not_zero:$positionBeforePlay")
        }
        audioTrack!!.play()
        epochPlayed = true
        prerollEpochsSatisfied++
        epochUnderrunBaseline = readUnderrunCount()
        if (underrunBaselineFirst < 0L) underrunBaselineFirst = epochUnderrunBaseline
    }

    private fun readUnderrunCount(): Long =
        try {
            audioTrack!!.underrunCount.toLong()
        } catch (_: Throwable) {
            throw FailClosed("underrun_count_unavailable")
        }

    // Device underrun TELEMETRY per epoch: the delta from the post-play
    // baseline to the epoch's final sink write is recorded (still captured
    // BEFORE the tail head catch-up so the natural end-of-data drain stays
    // out of the number) but never gates the verdict — a nonzero HAL delta
    // on this muted diagnostic sink sits inside the slice's non-claims (no
    // glitch freedom, no latency budget, no audio quality). The observed
    // value is reported as-is, never forced to zero.
    private fun captureEpochUnderrunDelta(label: String) {
        if (!epochPlayed) throw FailClosed("underrun_capture_without_play")
        if (epochUnderrunBaseline < 0L) throw FailClosed("underrun_baseline_missing")
        val finalCount = readUnderrunCount()
        val delta = finalCount - epochUnderrunBaseline
        underrunFinalLast = finalCount
        underrunDeltaTotal += delta
        underrunEpochsCaptured++
        detailParts.add("${label}UnderrunDelta=$delta")
    }

    // Bounded wait for the raw playback head to consume every frame written
    // this epoch (terminal boundary drain proof); the budget derives from
    // the remaining playout time plus a fixed margin.
    private fun waitForHeadCatchUp(label: String) {
        if (epochFramesWritten == 0L) {
            boundariesDrained++
            return
        }
        if (!epochPlayed) throw FailClosed("head_catchup_without_play")
        val tb = timebase!!
        tb.samplePositionFrames(audioTrack!!, epochFramesWritten, true)
        val remaining = epochFramesWritten - tb.lastRawHeadEpochFrames
        val budgetMs = remaining * 1_000L / sampleRate + HEAD_CATCHUP_MARGIN_MS
        val waitDeadline = SystemClock.elapsedRealtime() + budgetMs
        while (true) {
            pollCancellation()
            tb.samplePositionFrames(audioTrack!!, epochFramesWritten, true)
            if (tb.lastRawHeadEpochFrames >= epochFramesWritten) break
            if (SystemClock.elapsedRealtime() > waitDeadline) {
                throw FailClosed("tail_drain_head_timeout_$label")
            }
            SystemClock.sleep(HEAD_POLL_SLEEP_MS)
        }
        boundariesDrained++
    }

    private fun openEpoch() {
        epochBaseFrame = nextFrame
        epochFramesReadFromRing = 0L
        epochFramesWritten = 0L
        epochPlayed = false
        epochUnderrunBaseline = -1L
        epochSinkClockedDispatchCount = 0L
        timebase!!.openEpoch(audioTrack!!)
    }

    private fun closeEpochAccounting(label: String) {
        if (epochFramesReadFromRing != epochFramesWritten) {
            throw FailClosed("sink_write_accounting_mismatch_$label")
        }
        if (epochsClosed == 0) {
            sinkClockedDispatchCountEpoch0 = epochSinkClockedDispatchCount
        } else {
            sinkClockedDispatchCountEpoch1 = epochSinkClockedDispatchCount
        }
        epochsClosed++
        detailParts.add("${label}FramesWritten=$epochFramesWritten")
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

    // ── Tick math / snapshot / cancellation / result ────────────────────────

    private fun ceilDiv(a: Long, b: Long): Long = (a + b - 1) / b

    // Caller-derived sysTimeNs for an absolute accepted-axis frame; native
    // never reads a wall clock. Monotonic across the whole run (start/seek
    // re-base the anchor pair).
    private fun tickForFrame(frame: Long): Long {
        val ptsUs = ceilDiv(frame * 1_000_000L, sampleRate.toLong())
        val tick = anchorSysNs + (ptsUs - anchorPtsUs) * 1_000L
        if (tick < lastTickNs) throw FailClosed("non_monotonic_driver_tick")
        lastTickNs = tick
        return tick
    }

    private fun snapshot(): Map<String, String> {
        val kv = parseStatus(
            VanguardNativeBridge.snapshotNodeOwnedAudioSourceGraphPipeline(handle)
        )
        if (kv["status"] != "ok") throw FailClosed("snapshot_status_${kv["status"]}")
        providerUnderrunEvents = longField(kv, "providerUnderrunEvents")
        providerFramesZeroFilled = longField(kv, "providerFramesZeroFilled")
        providerForwardSkipFrames = longField(kv, "providerForwardSkipFrames")
        providerRewindRejects = longField(kv, "providerRewindRejects")
        coordinatorSilenceCount = longField(kv, "silenceCount")
        totalFramesAccepted = longField(kv, "totalFramesAccepted")
        totalOutputFramesDrained = longField(kv, "totalOutputFramesDrained")
        nativeAcceptedChecksumHex = kv["nativeAcceptedChecksumHex"] ?: ""
        nativeOutputDrainChecksumHex = kv["nativeOutputDrainChecksumHex"] ?: ""
        dispatchCount = longField(kv, "dispatchCount")
        snapNextDispatchFrame = longField(kv, "nextDispatchFrame")
        sourceAvail = longField(kv, "sourceAvailableReadFrames")
        outputAvail = longField(kv, "outputAvailableReadFrames")
        return kv
    }

    // One combined poll for the dispose-cancellation flag and the run
    // deadline, hit in every decode/dispatch/read/write/wait loop.
    private fun pollCancellation() {
        cancellationPollCount++
        if (cancelled()) throw FailClosed("cancelled_by_dispose")
        if (SystemClock.elapsedRealtime() > runDeadlineMs) {
            throw FailClosed("deadline_exceeded")
        }
    }

    private fun makeResult(pass: Boolean, failureReason: String): RunResult {
        val tb = timebase
        val lanes = mapOf<String, Any?>(
            "formatProbeOk" to formatProbeOk,
            "audioTrackInitOk" to audioTrackInitOk,
            "mutedOutputOk" to mutedOutputOk,
            "nodeOwnedRouteDiscoveryOk" to nodeOwnedRouteDiscoveryOk,
            "nodeOwnsRingOk" to nodeOwnsRingOk,
            "startAckOk" to startAckOk,
            "sinkClockedDispatchOk" to sinkClockedDispatchOk,
            // Conditional lane: valid when unavailable; false only when a
            // returned timestamp violated the validity rules.
            "timestampTelemetryOk" to
                (tb == null || !tb.timestampAvailable || tb.timestampValid),
            "playbackHeadMonotonicOk" to
                (tb != null && tb.headSampleCount > 0L && !tb.headMonotonicViolated),
            "playbackHeadAdvancedOk" to playbackHeadAdvancedOk,
            "sinkWriteAccountingOk" to sinkWriteAccountingOk,
            "checksumIdentityOk" to checksumIdentityOk,
            "frameAccountingOk" to frameAccountingOk,
            "seekOk" to seekOk,
            "tailFlushOk" to tailFlushOk,
            "steadyStateUnderrunFreeOk" to steadyStateUnderrunFreeOk,
            "noProviderUnderrunOk" to noProviderUnderrunOk,
            "noSilenceOk" to noSilenceOk,
            "noForwardSkipOk" to noForwardSkipOk,
            "noRewindRejectOk" to noRewindRejectOk,
            "finalNotTerminalOk" to finalNotTerminalOk,
            "finalSeekAckClearOk" to finalSeekAckClearOk,
            "zeroNativeSteadyStateAllocationOk" to zeroNativeSteadyStateAllocationOk,
            "cancellationPollingOk" to (cancellationPollCount > 0L),
            "lifecycleOk" to lifecycleOk,
            "canonical" to pass,
        )
        val metrics = mapOf<String, Any?>(
            "sampleRate" to sampleRate,
            "channelCount" to channelCount,
            "pcmEncoding" to pcmEncoding,
            "expectedFrameCount" to expectedFrameCount,
            "totalFramesExtracted" to totalFramesExtracted,
            "totalFramesAccepted" to totalFramesAccepted,
            "totalOutputFramesDrained" to totalOutputFramesDrained,
            "framesReadFromRingTotal" to framesReadFromRingTotal,
            "framesWrittenTotal" to framesWrittenTotal,
            "postSeekFramesAccepted" to postSeekFramesAccepted,
            "postSeekFramesDrained" to postSeekFramesDrained,
            "nativeAcceptedChecksumHex" to nativeAcceptedChecksumHex,
            "nativeOutputDrainChecksumHex" to nativeOutputDrainChecksumHex,
            "kotlinSinkChecksumHex" to String.format("%016x", kotlinSinkChecksum),
            "dispatchCount" to dispatchCount,
            "maxFramesPerMix" to mfpm,
            "sourceAvailableReadFrames" to sourceAvail,
            "outputAvailableReadFrames" to outputAvail,
            "nextDispatchFrame" to snapNextDispatchFrame,
            "bootstrapDispatchCount" to bootstrapDispatchCount,
            "sinkClockedDispatchCountEpoch0" to sinkClockedDispatchCountEpoch0,
            "sinkClockedDispatchCountEpoch1" to sinkClockedDispatchCountEpoch1,
            "prerollFrames" to prerollFrames,
            "targetLeadFrames" to targetLeadFrames,
            "bufferSizeInFrames" to bufferSizeInFrames,
            "bufferCapacityInFrames" to bufferCapacityInFrames,
            "startThresholdFrames" to startThresholdFrames,
            "audioTimestampAttemptCount" to (tb?.timestampAttemptCount ?: 0L),
            "audioTimestampSuccessCount" to (tb?.timestampSuccessCount ?: 0L),
            "headSampleCount" to (tb?.headSampleCount ?: 0L),
            "playbackHeadFinal" to playbackHeadFinal,
            "maxSinkLagFrames" to (tb?.maxSinkLagFrames ?: -1L),
            "maxDispatchLeadFrames" to
                (tb?.maxDispatchLeadFrames?.takeIf { it != Long.MIN_VALUE } ?: -1L),
            "minDispatchLeadFrames" to
                (tb?.minDispatchLeadFrames?.takeIf { it != Long.MAX_VALUE } ?: -1L),
            "underrunBaseline" to underrunBaselineFirst,
            "underrunFinal" to underrunFinalLast,
            "underrunDelta" to underrunDeltaTotal,
            "zeroWriteCount" to zeroWriteCount,
            "partialWriteCount" to partialWriteCount,
            "audioTrackReleaseCount" to audioTrackReleaseCount.toLong(),
            "nativeDestroyCallCount" to nativeDestroyCallCount,
            "seekAcceptedFrame" to seekAcceptedFrame,
            "providerUnderrunEvents" to providerUnderrunEvents,
            "providerFramesZeroFilled" to providerFramesZeroFilled,
            "providerForwardSkipFrames" to providerForwardSkipFrames,
            "providerRewindRejects" to providerRewindRejects,
            "coordinatorSilenceCount" to coordinatorSilenceCount,
            "cancellationPollCount" to cancellationPollCount,
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

    private fun parseStatus(raw: String): Map<String, String> =
        raw.split(';').mapNotNull { part ->
            val idx = part.indexOf('=')
            if (idx <= 0) null else part.substring(0, idx) to part.substring(idx + 1)
        }.toMap()

    private fun longField(kv: Map<String, String>, key: String): Long =
        kv[key]?.toLongOrNull() ?: throw FailClosed("missing_status_field_$key")
}
