package com.connects.vanguard_media_engine.diagnostics

import android.os.SystemClock
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicReference

// ── AndroidAudioGraphPipelineSyntheticDriver (P4 True-DAG sub-slice H1) ──────
//
// Kotlin-owned synthetic PCM16 step driver for the session-scoped closed-loop
// native audio graph pipeline JNI seam (android_phase4_audio_graph_pipeline_
// session_jni.cpp): AudioDecoderRingWriter -> source AudioSpscAudioRingBuffer
// -> RingBufferAudioSampleProvider -> GraphAudioScheduler -> AudioMixBusNode
// -> ClockedAudioTransportCoordinator -> output AudioSpscAudioRingBuffer ->
// consumer drain. Exactly one routed source track at unit gain; the mixed
// output must therefore be sample-identical to the ingested synthetic PCM.
//
// Every clock tick is caller-derived, never a wall clock:
//   F_k = startFrame + k * maxFramesPerMix
//   ptsUs_k = ceil(F_k * 1_000_000 / sampleRate)
//   sysTimeNs_k = anchorSysNs + (ptsUs_k - anchorPtsUs) * 1000
// with the anchor re-based at start() and at the one forward seek.
//
// Proof lanes, all on the single owner thread of [run] (except the deliberate
// foreign-thread probe that must be rejected):
//   - Start gate: the first step after start() reports awaiting_seek_ack; the
//     output-ring ack drain lands newStartFrame == startFrame with zero
//     discards.
//   - Closed-loop identity: ingest/step/drain cycles where every dispatched
//     window renders exactly maxFramesPerMix frames (anything else is
//     window_size_drift and FAIL).
//   - Forward-only seek: drained output + empty source ring, then one native
//     seek that re-bases writer/provider/coordinator to the same frame with
//     zero discarded frames; post-seek frames accepted must be > 0 and the
//     checksum identity must hold across the boundary.
//   - Output backpressure: deliberately undrained output ring until the step
//     reports output_backpressure; kRingPushShortfall must never appear.
//   - Source pressure: writerStatus partial_write and ring_full both
//     observed on the source ring.
//   - Underrun gate: a step with less than one window of source frames
//     reports deferred_insufficient_source with no cursor mutation.
//   - EOS tail flush: after setEos, flushTail steps advance exactly the
//     remaining frames (tail_flush_partial_window) and then report
//     tail_flush_complete; final accounting is
//     totalOutputFramesDrained == totalFramesAccepted exactly, zero discards.
//   - Zero native steady-state allocation: scheduler scratch and ring
//     storage capacities compared before/after >= 50 dispatch cycles.
//   - Owner thread: a foreign-thread snapshot must fail closed with
//     wrong_owner_thread; destroy is any-thread and idempotent.
//
// Honest non-claims: no MediaCodec, no MediaExtractor (sub-slice H2 is out of
// scope here), no AudioTrack/AAudio/OpenSL/Oboe, no audible or realtime
// playback, no export or pass-2 graph reroute, no streaming/cache, no iOS,
// no product/editor UI. Native spawns no threads, takes no locks inside the
// vanguard audio primitives, does no file IO, and never reads a wall clock.
class AndroidAudioGraphPipelineSyntheticDriver {

    companion object {
        const val PASS_MARKER = "ANDROID_DAG_PHASE4_AUDIO_GRAPH_PIPELINE_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_AUDIO_GRAPH_PIPELINE_SMOKE_FAIL"
        const val PROOF_BOUNDARY =
            "kotlin_owned_synthetic_pcm_step_driven_closed_loop_native_audio_graph_pipeline_session_proof_only_no_mediacodec_no_mediaextractor_no_cpp_os_decoder_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_no_audio_track_no_aaudio_no_opensl_no_oboe_no_audible_or_realtime_playback_diagnostic_graph_topology_only_no_production_source_node_wiring_no_source_node_pcm_ingest_topology_anchor_only_single_routed_track_unit_gain_only_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim"

        private const val ANCHOR_SYS_TIME_NS = 1_000_000_000L
        private const val SCRATCH_FRAMES = 4096
        private const val MAX_DRAIN_ITERATIONS = 256
        private const val MIN_STEADY_STATE_DISPATCHES = 50L
        private const val FOREIGN_PROBE_JOIN_MS = 5_000L
    }

    data class RunConfig(
        val sampleRate: Int = 48_000,
        val channelCount: Int = 2,
        val sourceRingCapacityFrames: Int = 8_192,
        val outputRingCapacityFrames: Int = 4_096,
        val maxFramesPerMix: Int = 256,
        val windowCount: Int = 64,
        val seekTargetFrame: Long = 4_096L,
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
        val sourcePartialWriteObserved: Boolean,
        val sourceRingFullObserved: Boolean,
        val outputBackpressureObserved: Boolean,
        val checksumIdentityOk: Boolean,
        val frameAccountingOk: Boolean,
        val seekOk: Boolean,
        val tailFlushOk: Boolean,
        val noUnderrunOk: Boolean,
        val noSilenceOk: Boolean,
        val zeroNativeSteadyStateAllocationOk: Boolean,
        val noRingPushShortfallOk: Boolean,
        val ownerThreadOk: Boolean,
        val lifecycleOk: Boolean,
        val canonical: Boolean,
        // Counters.
        val totalFramesAccepted: Long,
        val totalOutputFramesDrained: Long,
        val postSeekFramesAccepted: Long,
        val providerUnderrunEvents: Long,
        val providerFramesZeroFilled: Long,
        val coordinatorSilenceCount: Long,
        val nativeAcceptedChecksumHex: String,
        val nativeOutputDrainChecksumHex: String,
        val kotlinAcceptedChecksumHex: String,
        val maxFramesPerMix: Long,
        val sourceAvailableReadFrames: Long,
        val outputAvailableReadFrames: Long,
        val dispatchCount: Long,
    )

    private class FailClosed(val reason: String) : Exception(reason)

    // Mutable telemetry threaded through the run so fail-closed paths still
    // report everything observed up to the failure point.
    private class RunTelemetry {
        var sourcePartialWriteObserved = false
        var sourceRingFullObserved = false
        var outputBackpressureObserved = false
        var checksumIdentityOk = false
        var frameAccountingOk = false
        var seekOk = false
        var tailFlushOk = false
        var noUnderrunOk = false
        var noSilenceOk = false
        var zeroNativeSteadyStateAllocationOk = false
        var noRingPushShortfallOk = false
        var ownerThreadOk = false
        var lifecycleOk = false

        var kotlinChecksum = 0L
        var kotlinFramesAccepted = 0L
        var totalFramesAccepted = 0L
        var totalOutputFramesDrained = 0L
        var postSeekFramesAccepted = 0L
        var providerUnderrunEvents = 0L
        var providerFramesZeroFilled = 0L
        var coordinatorSilenceCount = 0L
        var nativeAcceptedChecksumHex = ""
        var nativeOutputDrainChecksumHex = ""
        var sourceAvailableReadFrames = -1L
        var outputAvailableReadFrames = -1L
        var dispatchCount = 0L
        var ringPushShortfallSeen = false
        val detailParts = mutableListOf<String>()
    }

    fun run(config: RunConfig): RunResult {
        val t = RunTelemetry()
        val deadline = SystemClock.elapsedRealtime() + config.deadlineMs
        var handle = 0L
        try {
            val sr = config.sampleRate
            val ch = config.channelCount
            val mfpm = config.maxFramesPerMix.toLong()
            val srcCap = config.sourceRingCapacityFrames.toLong()
            val outCap = config.outputRingCapacityFrames.toLong()

            // Driver-side lane geometry validation (native re-validates its
            // own construction contract independently).
            if (mfpm < 4) throw FailClosed("invalid_driver_config_max_frames_per_mix")
            if (config.seekTargetFrame <= 0L || config.seekTargetFrame % mfpm != 0L) {
                throw FailClosed("invalid_driver_config_seek_target_frame")
            }
            val preSeekWindows = (config.seekTargetFrame / mfpm).toInt()
            if (config.windowCount <= preSeekWindows) {
                throw FailClosed("invalid_driver_config_window_count")
            }
            if (config.windowCount < MIN_STEADY_STATE_DISPATCHES) {
                throw FailClosed("invalid_driver_config_window_count_below_cycle_floor")
            }
            val postSeekIdentityWindows = config.windowCount - preSeekWindows
            val backpressureWindows = (outCap / mfpm).toInt()
            if (backpressureWindows < 1) throw FailClosed("invalid_driver_config_output_capacity")

            fun checkDeadline() {
                if (SystemClock.elapsedRealtime() > deadline) throw FailClosed("deadline_exceeded")
            }

            // ── Lifecycle lane part 1: fail-closed construction validation ──
            if (VanguardNativeBridge.createAudioGraphPipelineSmokeSession(
                    7_999, ch, config.sourceRingCapacityFrames,
                    config.outputRingCapacityFrames, config.maxFramesPerMix) != 0L
            ) throw FailClosed("invalid_sample_rate_session_not_rejected")
            if (VanguardNativeBridge.createAudioGraphPipelineSmokeSession(
                    sr, 3, config.sourceRingCapacityFrames,
                    config.outputRingCapacityFrames, config.maxFramesPerMix) != 0L
            ) throw FailClosed("invalid_channel_count_session_not_rejected")
            if (VanguardNativeBridge.createAudioGraphPipelineSmokeSession(
                    sr, ch, 100, config.outputRingCapacityFrames, config.maxFramesPerMix) != 0L
            ) throw FailClosed("non_power_of_two_ring_session_not_rejected")
            if (VanguardNativeBridge.createAudioGraphPipelineSmokeSession(
                    sr, ch, config.sourceRingCapacityFrames,
                    config.outputRingCapacityFrames, 0) != 0L
            ) throw FailClosed("invalid_max_frames_per_mix_session_not_rejected")

            handle = VanguardNativeBridge.createAudioGraphPipelineSmokeSession(
                sr, ch, config.sourceRingCapacityFrames,
                config.outputRingCapacityFrames, config.maxFramesPerMix,
            )
            if (handle == 0L) throw FailClosed("native_session_create_failed")

            val bytesPerFrame = 2 * ch
            val scratch = ByteBuffer.allocateDirect(SCRATCH_FRAMES * bytesPerFrame)
                .order(ByteOrder.LITTLE_ENDIAN)
            var patternCounter = 0L

            // Caller-derived tick anchor, re-based at start() and seek().
            var anchorPtsUs = 0L
            var anchorSysNs = ANCHOR_SYS_TIME_NS
            var lastTickNs = Long.MIN_VALUE

            fun ceilDiv(a: Long, b: Long): Long = (a + b - 1) / b

            fun tickForFrame(frame: Long): Long {
                val ptsUs = ceilDiv(frame * 1_000_000L, sr.toLong())
                val tick = anchorSysNs + (ptsUs - anchorPtsUs) * 1_000L
                if (tick < lastTickNs) throw FailClosed("non_monotonic_driver_tick")
                lastTickNs = tick
                return tick
            }

            fun snapshot(): Map<String, String> {
                val kv = parseStatus(VanguardNativeBridge.snapshotAudioGraphPipeline(handle))
                if (kv["status"] != "ok") throw FailClosed("snapshot_status_${kv["status"]}")
                t.providerUnderrunEvents = longField(kv, "providerUnderrunEvents")
                t.providerFramesZeroFilled = longField(kv, "providerFramesZeroFilled")
                t.coordinatorSilenceCount = longField(kv, "silenceCount")
                t.totalFramesAccepted = longField(kv, "totalFramesAccepted")
                t.totalOutputFramesDrained = longField(kv, "totalOutputFramesDrained")
                t.nativeAcceptedChecksumHex = kv["nativeAcceptedChecksumHex"] ?: ""
                t.nativeOutputDrainChecksumHex = kv["nativeOutputDrainChecksumHex"] ?: ""
                t.sourceAvailableReadFrames = longField(kv, "sourceAvailableReadFrames")
                t.outputAvailableReadFrames = longField(kv, "outputAvailableReadFrames")
                t.dispatchCount = longField(kv, "dispatchCount")
                if (kv["terminal"] == "true") t.ringPushShortfallSeen = true
                return kv
            }

            // Fills [frames] frames of deterministic synthetic PCM16 at byte
            // offset 0 of the hoisted scratch buffer.
            fun fillPattern(frames: Int) {
                for (i in 0 until frames * ch) {
                    val v = ((patternCounter * 31L + 7L) % 24_001L - 12_000L).toInt().toShort()
                    scratch.putShort(i * 2, v)
                    patternCounter += 1L
                }
            }

            // One ingest call of [frames] pattern frames; mirrors the native
            // accepted-side checksum over exactly the accepted samples and
            // returns (framesAccepted, writerStatus).
            fun ingest(frames: Int): Pair<Long, String> {
                checkDeadline()
                if (frames > SCRATCH_FRAMES) throw FailClosed("ingest_chunk_exceeds_scratch")
                fillPattern(frames)
                val kv = parseStatus(
                    VanguardNativeBridge.ingestAudioGraphPipelinePcm16(handle, scratch, frames)
                )
                if (kv["status"] != "ok") throw FailClosed("ingest_status_${kv["status"]}")
                val accepted = longField(kv, "framesAccepted")
                val writerStatus = kv["writerStatus"] ?: ""
                when (writerStatus) {
                    "ok" -> {}
                    "partial_write" -> t.sourcePartialWriteObserved = true
                    "ring_full" -> t.sourceRingFullObserved = true
                    else -> throw FailClosed("unexpected_writer_status_$writerStatus")
                }
                if (accepted > 0L) {
                    val sampleCount = (accepted * ch).toInt()
                    var c = t.kotlinChecksum
                    for (i in 0 until sampleCount) {
                        c = c * 31L + (scratch.getShort(i * 2).toLong() and 0xFFFFL)
                    }
                    t.kotlinChecksum = c
                    t.kotlinFramesAccepted += accepted
                }
                t.totalFramesAccepted = longField(kv, "totalFramesAccepted")
                t.nativeAcceptedChecksumHex = kv["nativeAcceptedChecksumHex"] ?: ""
                return accepted to writerStatus
            }

            fun step(sysTimeNs: Long, flushTail: Boolean): Map<String, String> {
                checkDeadline()
                val kv = parseStatus(
                    VanguardNativeBridge.stepAudioGraphPipeline(handle, sysTimeNs, flushTail)
                )
                val status = kv["status"] ?: ""
                if (!kv.containsKey("sourceAvailableReadFrames")) {
                    throw FailClosed("step_missing_source_available_read_frames")
                }
                if (status == "ring_push_shortfall") t.ringPushShortfallSeen = true
                // Contract: every non-deferred dispatched window renders
                // exactly one full window.
                if (status == "dispatch_ok" &&
                    longField(kv, "framesRendered") != mfpm
                ) {
                    throw FailClosed("window_size_drift")
                }
                if (status == "dispatch_silence") {
                    throw FailClosed("unexpected_silence_window")
                }
                return kv
            }

            fun drain(maxFrames: Int): Map<String, String> {
                checkDeadline()
                val kv = parseStatus(
                    VanguardNativeBridge.drainAudioGraphPipelineOutput(handle, maxFrames)
                )
                if (kv["status"] != "ok") throw FailClosed("drain_status_${kv["status"]}")
                t.totalOutputFramesDrained = longField(kv, "totalOutputFramesDrained")
                t.nativeOutputDrainChecksumHex = kv["nativeOutputDrainChecksumHex"] ?: ""
                return kv
            }

            // Ingest/step/drain closed-loop identity cycle for exactly one
            // full window ending at absolute frame [windowEndFrame].
            fun identityCycle(windowEndFrame: Long) {
                val (accepted, writerStatus) = ingest(mfpm.toInt())
                if (accepted != mfpm || writerStatus != "ok") {
                    throw FailClosed("identity_ingest_rejected_${writerStatus}_$accepted")
                }
                val kv = step(tickForFrame(windowEndFrame), false)
                if (kv["status"] != "dispatch_ok") {
                    throw FailClosed("identity_step_status_${kv["status"]}")
                }
                if (longField(kv, "nextDispatchFrame") != windowEndFrame) {
                    throw FailClosed("identity_cursor_mismatch")
                }
                val drained = longField(drain(mfpm.toInt()), "framesDrained")
                if (drained != mfpm) throw FailClosed("identity_drain_short_$drained")
            }

            // ── Capacity baseline for the zero-allocation lane ──────────────
            val snapStart = snapshot()
            val schedCapBefore = longField(snapStart, "schedulerTrackScratchCapacitySamples")
            val schedTracksBefore = longField(snapStart, "schedulerTrackScratchCapacityTracks")
            val srcCapBefore = longField(snapStart, "sourceRingStorageCapacitySamples")
            val outCapBefore = longField(snapStart, "outputRingStorageCapacitySamples")
            if (schedCapBefore <= 0L || srcCapBefore <= 0L || outCapBefore <= 0L) {
                throw FailClosed("capacity_baseline_invalid")
            }

            // ── Start + awaiting-ack gate ───────────────────────────────────
            val startKv = parseStatus(
                VanguardNativeBridge.startAudioGraphPipeline(handle, 0L, anchorSysNs)
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

            // ── Lane A: pre-seek closed-loop identity windows ───────────────
            var nextFrame = 0L
            for (k in 1..preSeekWindows) {
                identityCycle(nextFrame + mfpm)
                nextFrame += mfpm
            }
            if (nextFrame != config.seekTargetFrame) throw FailClosed("pre_seek_cursor_mismatch")
            val preSeekAccepted = t.totalFramesAccepted

            // ── Owner-thread lane: a foreign thread must be rejected ────────
            val foreignStatus = AtomicReference("")
            val probeThread = Thread {
                foreignStatus.set(
                    parseStatus(VanguardNativeBridge.snapshotAudioGraphPipeline(handle))["status"]
                        ?: ""
                )
            }
            probeThread.start()
            probeThread.join(FOREIGN_PROBE_JOIN_MS)
            t.ownerThreadOk = foreignStatus.get() == "wrong_owner_thread"
            if (!t.ownerThreadOk) throw FailClosed("foreign_thread_not_rejected")

            // ── Forward-only seek at the drained/empty boundary ─────────────
            val seekPtsUs = ceilDiv(config.seekTargetFrame * 1_000_000L, sr.toLong())
            val seekSysNs = tickForFrame(config.seekTargetFrame)
            val seekKv = parseStatus(
                VanguardNativeBridge.seekAudioGraphPipeline(handle, seekPtsUs, seekSysNs)
            )
            if (seekKv["status"] != "ok") throw FailClosed("seek_status_${seekKv["status"]}")
            if (longField(seekKv, "targetFrame") != config.seekTargetFrame ||
                longField(seekKv, "discardedFramesOnSeek") != 0L
            ) {
                throw FailClosed("seek_boundary_mismatch")
            }
            anchorPtsUs = seekPtsUs
            anchorSysNs = seekSysNs

            val postSeekStepKv = step(seekSysNs, false)
            if (postSeekStepKv["status"] != "awaiting_seek_ack") {
                throw FailClosed("post_seek_step_not_awaiting_seek_ack_${postSeekStepKv["status"]}")
            }
            val seekAckKv = drain(config.outputRingCapacityFrames)
            if (seekAckKv["seekAckConsumed"] != "true" ||
                longField(seekAckKv, "newStartFrame") != config.seekTargetFrame ||
                longField(seekAckKv, "discardedFramesOnSeek") != 0L
            ) {
                throw FailClosed("seek_ack_not_consumed_cleanly")
            }
            t.seekOk = true

            // ── Lane B: output-ring backpressure (deliberately undrained) ───
            for (k in 1..backpressureWindows) {
                val (accepted, writerStatus) = ingest(mfpm.toInt())
                if (accepted != mfpm || writerStatus != "ok") {
                    throw FailClosed("backpressure_fill_ingest_rejected")
                }
                val kv = step(tickForFrame(nextFrame + mfpm), false)
                if (kv["status"] != "dispatch_ok") {
                    throw FailClosed("backpressure_fill_step_status_${kv["status"]}")
                }
                nextFrame += mfpm
            }
            val (bpAccepted, bpWriterStatus) = ingest(mfpm.toInt())
            if (bpAccepted != mfpm || bpWriterStatus != "ok") {
                throw FailClosed("backpressure_probe_ingest_rejected")
            }
            val backpressureTick = tickForFrame(nextFrame + mfpm)
            val bpKv = step(backpressureTick, false)
            if (bpKv["status"] != "output_backpressure" ||
                longField(bpKv, "framesRendered") != 0L
            ) {
                throw FailClosed("output_backpressure_not_observed_${bpKv["status"]}")
            }
            t.outputBackpressureObserved = true

            var bpDrainIterations = 0
            while (true) {
                checkDeadline()
                if (++bpDrainIterations > MAX_DRAIN_ITERATIONS) {
                    throw FailClosed("backpressure_drain_budget_exhausted")
                }
                if (longField(
                        drain(config.outputRingCapacityFrames), "outputAvailableReadFrames"
                    ) == 0L
                ) break
            }
            val bpRetryKv = step(backpressureTick, false)
            if (bpRetryKv["status"] != "dispatch_ok") {
                throw FailClosed("backpressure_retry_step_status_${bpRetryKv["status"]}")
            }
            nextFrame += mfpm
            if (longField(drain(mfpm.toInt()), "framesDrained") != mfpm) {
                throw FailClosed("backpressure_retry_drain_short")
            }

            // ── Lane A2: post-seek closed-loop identity windows ─────────────
            for (k in 1..postSeekIdentityWindows) {
                identityCycle(nextFrame + mfpm)
                nextFrame += mfpm
            }

            // ── Lane C: source-ring pressure (partial_write + ring_full) ────
            var fillRemaining = srcCap - 64L
            while (fillRemaining > 0L) {
                checkDeadline()
                val chunk = minOf(fillRemaining, SCRATCH_FRAMES.toLong()).toInt()
                val (accepted, writerStatus) = ingest(chunk)
                if (accepted != chunk.toLong() || writerStatus != "ok") {
                    throw FailClosed("source_fill_ingest_rejected")
                }
                fillRemaining -= accepted
            }
            val (partialAccepted, partialStatus) = ingest(128)
            if (partialStatus != "partial_write" || partialAccepted != 64L) {
                throw FailClosed("partial_write_not_observed_${partialStatus}_$partialAccepted")
            }
            val (fullAccepted, fullStatus) = ingest(mfpm.toInt())
            if (fullStatus != "ring_full" || fullAccepted != 0L) {
                throw FailClosed("ring_full_not_observed_${fullStatus}_$fullAccepted")
            }

            var sourceDispatchIterations = 0
            val sourceDispatchBudget = (srcCap / mfpm).toInt() + 2
            var sourceAvail = srcCap
            while (sourceAvail >= mfpm) {
                checkDeadline()
                if (++sourceDispatchIterations > sourceDispatchBudget) {
                    throw FailClosed("source_dispatch_budget_exhausted")
                }
                val kv = step(tickForFrame(nextFrame + mfpm), false)
                if (kv["status"] != "dispatch_ok") {
                    throw FailClosed("source_dispatch_step_status_${kv["status"]}")
                }
                nextFrame += mfpm
                if (longField(drain(mfpm.toInt()), "framesDrained") != mfpm) {
                    throw FailClosed("source_dispatch_drain_short")
                }
                sourceAvail = longField(kv, "sourceAvailableReadFrames")
            }

            // ── Lane D: underrun gate + writer EOS + tail flush ─────────────
            var tailFrames = sourceAvail
            if (tailFrames == 0L) {
                val extraTail = mfpm / 2L + 1L
                val (accepted, writerStatus) = ingest(extraTail.toInt())
                if (accepted != extraTail || writerStatus != "ok") {
                    throw FailClosed("tail_seed_ingest_rejected")
                }
                tailFrames = extraTail
            }
            if (tailFrames <= 0L || tailFrames >= mfpm) throw FailClosed("tail_seed_geometry")

            val tailTick = tickForFrame(nextFrame + mfpm)
            val deferredKv = step(tailTick, false)
            if (deferredKv["status"] != "deferred_insufficient_source" ||
                longField(deferredKv, "nextDispatchFrame") != nextFrame ||
                longField(deferredKv, "sourceAvailableReadFrames") != tailFrames
            ) {
                throw FailClosed("deferred_insufficient_source_not_observed_${deferredKv["status"]}")
            }

            val eosKv = parseStatus(VanguardNativeBridge.setAudioGraphPipelineEos(handle))
            if (eosKv["status"] != "ok" || eosKv["eos"] != "true") {
                throw FailClosed("eos_set_failed_${eosKv["status"]}")
            }

            val tailStepKv = step(tailTick, true)
            if (tailStepKv["status"] != "tail_flush_partial_window" ||
                longField(tailStepKv, "framesRendered") != tailFrames ||
                longField(tailStepKv, "nextDispatchFrame") != nextFrame + tailFrames
            ) {
                throw FailClosed("tail_flush_partial_window_not_observed_${tailStepKv["status"]}")
            }
            nextFrame += tailFrames
            if (longField(drain(mfpm.toInt()), "framesDrained") != tailFrames) {
                throw FailClosed("tail_drain_short")
            }
            val tailDoneKv = step(tailTick, true)
            if (tailDoneKv["status"] != "tail_flush_complete") {
                throw FailClosed("tail_flush_complete_not_observed_${tailDoneKv["status"]}")
            }
            t.tailFlushOk = true

            // ── Final snapshot + verdict lanes ──────────────────────────────
            val snapEnd = snapshot()
            t.postSeekFramesAccepted = t.totalFramesAccepted - preSeekAccepted
            t.detailParts.add("preSeekWindows=$preSeekWindows")
            t.detailParts.add("postSeekIdentityWindows=$postSeekIdentityWindows")
            t.detailParts.add("backpressureWindows=$backpressureWindows")
            t.detailParts.add("tailFrames=$tailFrames")
            t.detailParts.add("finalNextFrame=$nextFrame")

            t.noUnderrunOk = t.providerUnderrunEvents == 0L && t.providerFramesZeroFilled == 0L
            if (!t.noUnderrunOk) throw FailClosed("provider_underrun_observed")
            t.noSilenceOk = t.coordinatorSilenceCount == 0L
            if (!t.noSilenceOk) throw FailClosed("silence_window_observed")
            t.noRingPushShortfallOk = !t.ringPushShortfallSeen && snapEnd["terminal"] != "true"
            if (!t.noRingPushShortfallOk) throw FailClosed("ring_push_shortfall_observed")

            t.zeroNativeSteadyStateAllocationOk =
                t.dispatchCount >= MIN_STEADY_STATE_DISPATCHES &&
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
            if (t.postSeekFramesAccepted <= 0L) throw FailClosed("no_post_seek_frames_accepted")
            if (!t.sourcePartialWriteObserved) throw FailClosed("partial_write_not_observed")
            if (!t.sourceRingFullObserved) throw FailClosed("ring_full_not_observed")

            // ── Lifecycle lane part 2: idempotent any-thread destroy ────────
            val destroyKv = parseStatus(
                VanguardNativeBridge.destroyAudioGraphPipelineSmokeSession(handle)
            )
            val destroyAgainKv = parseStatus(
                VanguardNativeBridge.destroyAudioGraphPipelineSmokeSession(handle)
            )
            val postDestroySnapshotKv = parseStatus(
                VanguardNativeBridge.snapshotAudioGraphPipeline(handle)
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
            if (handle != 0L) {
                try {
                    VanguardNativeBridge.destroyAudioGraphPipelineSmokeSession(handle)
                } catch (_: Throwable) {}
            }
        }
    }

    private fun makeResult(
        t: RunTelemetry,
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
        sourcePartialWriteObserved = t.sourcePartialWriteObserved,
        sourceRingFullObserved = t.sourceRingFullObserved,
        outputBackpressureObserved = t.outputBackpressureObserved,
        checksumIdentityOk = t.checksumIdentityOk,
        frameAccountingOk = t.frameAccountingOk,
        seekOk = t.seekOk,
        tailFlushOk = t.tailFlushOk,
        noUnderrunOk = t.noUnderrunOk,
        noSilenceOk = t.noSilenceOk,
        zeroNativeSteadyStateAllocationOk = t.zeroNativeSteadyStateAllocationOk,
        noRingPushShortfallOk = t.noRingPushShortfallOk,
        ownerThreadOk = t.ownerThreadOk,
        lifecycleOk = t.lifecycleOk,
        canonical = pass,
        totalFramesAccepted = t.totalFramesAccepted,
        totalOutputFramesDrained = t.totalOutputFramesDrained,
        postSeekFramesAccepted = t.postSeekFramesAccepted,
        providerUnderrunEvents = t.providerUnderrunEvents,
        providerFramesZeroFilled = t.providerFramesZeroFilled,
        coordinatorSilenceCount = t.coordinatorSilenceCount,
        nativeAcceptedChecksumHex = t.nativeAcceptedChecksumHex,
        nativeOutputDrainChecksumHex = t.nativeOutputDrainChecksumHex,
        kotlinAcceptedChecksumHex = String.format("%016x", t.kotlinChecksum),
        maxFramesPerMix = config.maxFramesPerMix.toLong(),
        sourceAvailableReadFrames = t.sourceAvailableReadFrames,
        outputAvailableReadFrames = t.outputAvailableReadFrames,
        dispatchCount = t.dispatchCount,
    )

    private fun parseStatus(raw: String): Map<String, String> =
        raw.split(';').mapNotNull { part ->
            val idx = part.indexOf('=')
            if (idx <= 0) null else part.substring(0, idx) to part.substring(idx + 1)
        }.toMap()

    private fun longField(kv: Map<String, String>, key: String): Long =
        kv[key]?.toLongOrNull() ?: throw FailClosed("missing_status_field_$key")
}
