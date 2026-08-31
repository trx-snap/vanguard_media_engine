package com.connects.vanguard_media_engine.diagnostics

import android.os.SystemClock
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicReference

// ── AndroidAudioGraphPipelineRealDecoderNativeSession (P4 True-DAG sub-slice H2) ─
//
// Owner-thread wrapper around the sub-slice H1 closed-loop native audio graph
// pipeline JNI seam (android_phase4_audio_graph_pipeline_session_jni.cpp),
// used by the real MediaExtractor/MediaCodec decoder driver. This class owns
// the native handle lifecycle, JNI status parsing, the accepted-frame-axis
// caller-derived tick math, the deadlock-free backpressure drive, the
// deterministic source/output backpressure lanes, the lossless EOS tail
// flush, the accepted-frame-axis seek, snapshot metric folding, the
// foreign-thread owner probe, and native cleanup. It never touches
// MediaExtractor/MediaCodec — the driver hands it already-copied direct
// ByteBuffers whose codec output buffers were released beforehand.
//
// The native frame axis here is the ACCEPTED FRAME COUNT, not media PTS:
// every tick derives from the native-reported nextDispatchFrame
//   F = nextDispatchFrame + maxFramesPerMix
//   ptsUs = ceil(F * 1_000_000 / sampleRate)
//   sysTimeNs = anchorSysNs + (ptsUs - anchorPtsUs) * 1000
// with the anchor re-based at start() and at the one accepted-frame-boundary
// seek. The local dispatch cursor is cross-checked against the native cursor
// after every step; the tick guard allows equality and fails only on a
// decrease.
//
// Honest non-claims: no threads spawned except the single short-lived
// foreign-thread probe that must be rejected by native; no
// AudioTrack/AAudio/OpenSL/Oboe, no audible or realtime playback, no export
// or pass-2 reroute, no streaming/cache, no iOS, no product/editor UI.
class AndroidAudioGraphPipelineRealDecoderNativeSession(
    private val deadlineElapsedRealtimeMs: Long,
) {
    class Failure(val reason: String) : Exception(reason)

    data class IngestReply(
        val framesAccepted: Long,
        val writerStatus: String,
        val writerAvailableToWrite: Long,
    )

    companion object {
        private const val ANCHOR_SYS_TIME_NS = 1_000_000_000L
        // Matches the native per-call ingest clamp (AudioDecoderRingWriter
        // kMaxWriteFrames); a larger request would be silently clamped and
        // break the deterministic backpressure-lane assertions.
        private const val NATIVE_MAX_INGEST_FRAMES = 8_192L
        private const val MAX_CHUNK_RETRIES = 64
        private const val MAX_STEP_RETRIES = 8
        private const val MAX_DRAIN_ITERATIONS = 256
        private const val MAX_LANE_ITERATIONS = 256
        private const val MIN_STEADY_STATE_DISPATCHES = 50L
        private const val FOREIGN_PROBE_JOIN_MS = 5_000L
    }

    // Geometry, frozen at create().
    private var handle = 0L
    private var sampleRate = 0
    private var channelCount = 0
    private var bytesPerFrame = 0
    private var srcCap = 0L
    private var outCap = 0L
    private var mfpm = 0L

    // Caller-derived tick anchor on the accepted-frame axis.
    private var anchorPtsUs = 0L
    private var anchorSysNs = ANCHOR_SYS_TIME_NS
    private var lastTickNs = Long.MIN_VALUE

    // Native-reported cursors/counters, refreshed from every reply; the
    // local cursor mirrors dispatched frames and is cross-checked after
    // every step.
    var nativeNextDispatchFrame = 0L
        private set
    private var localCursorFrame = 0L
    var sourceAvailableReadFrames = 0L
        private set
    var outputAvailableReadFrames = 0L
        private set
    private var writerAvailableToWrite = -1L

    var totalFramesAccepted = 0L
        private set
    var totalOutputFramesDrained = 0L
        private set
    var kotlinFramesAccepted = 0L
        private set
    var kotlinChecksum = 0L
        private set
    var nativeAcceptedChecksumHex = ""
        private set
    var nativeOutputDrainChecksumHex = ""
        private set
    var dispatchCount = 0L
        private set
    var lastStatus = ""
        private set

    var sourcePartialWriteObserved = false
        private set
    var sourceRingFullObserved = false
        private set
    var outputBackpressureObserved = false
        private set
    var ringPushShortfallSeen = false
        private set

    // Folded from the most recent snapshot.
    var providerUnderrunEvents = 0L
        private set
    var providerFramesZeroFilled = 0L
        private set
    var providerForwardSkipFrames = 0L
        private set
    var providerRewindRejects = 0L
        private set
    var coordinatorSilenceCount = 0L
        private set
    var snapshotTerminal = false
        private set
    var snapshotAwaitingSeekAck = false
        private set

    // Fixed-at-construction capacity baseline for the zero native
    // steady-state allocation lane.
    private var schedCapBefore = -1L
    private var schedTracksBefore = -1L
    private var srcStorageBefore = -1L
    private var outStorageBefore = -1L

    val isCreated: Boolean get() = handle != 0L

    // ── Lifecycle ───────────────────────────────────────────────────────────

    fun create(
        sampleRateIn: Int,
        channelCountIn: Int,
        sourceRingCapacityFrames: Int,
        outputRingCapacityFrames: Int,
        maxFramesPerMix: Int,
    ) {
        if (handle != 0L) throw Failure("native_session_already_created")
        if (maxFramesPerMix <= 0) throw Failure("invalid_config_max_frames_per_mix")
        sampleRate = sampleRateIn
        channelCount = channelCountIn
        bytesPerFrame = 2 * channelCountIn
        srcCap = sourceRingCapacityFrames.toLong()
        outCap = outputRingCapacityFrames.toLong()
        mfpm = maxFramesPerMix.toLong()
        // The deterministic output backpressure lane must be able to hold
        // (outCap/mfpm + 1) full windows of source frames at once.
        if ((outCap / mfpm + 1L) * mfpm > srcCap) {
            throw Failure("invalid_config_backpressure_geometry")
        }
        handle = VanguardNativeBridge.createAudioGraphPipelineSmokeSession(
            sampleRateIn, channelCountIn,
            sourceRingCapacityFrames, outputRingCapacityFrames, maxFramesPerMix,
        )
        if (handle == 0L) throw Failure("native_session_create_failed")
        val snap = snapshot()
        schedCapBefore = longField(snap, "schedulerTrackScratchCapacitySamples")
        schedTracksBefore = longField(snap, "schedulerTrackScratchCapacityTracks")
        srcStorageBefore = longField(snap, "sourceRingStorageCapacitySamples")
        outStorageBefore = longField(snap, "outputRingStorageCapacitySamples")
        if (schedCapBefore <= 0L || srcStorageBefore <= 0L || outStorageBefore <= 0L) {
            throw Failure("capacity_baseline_invalid")
        }
    }

    // Starts the transport at accepted frame 0 and consumes the output-ring
    // start ack (which must land at frame 0 with zero discards).
    fun startAndConsumeAck() {
        anchorPtsUs = 0L
        anchorSysNs = ANCHOR_SYS_TIME_NS
        lastTickNs = anchorSysNs
        localCursorFrame = 0L
        val kv = parseNative(
            VanguardNativeBridge.startAudioGraphPipeline(handle, 0L, anchorSysNs)
        )
        if (kv["status"] != "ok") throw Failure("start_status_${kv["status"]}")
        val stepKv = stepRaw(anchorSysNs, flushTail = false)
        if (stepKv["status"] != "awaiting_seek_ack") {
            throw Failure("first_step_not_awaiting_seek_ack_${stepKv["status"]}")
        }
        val ackKv = drainOutputOnce(outCap.toInt())
        if (ackKv["seekAckConsumed"] != "true" ||
            longField(ackKv, "newStartFrame") != 0L ||
            longField(ackKv, "discardedFramesOnSeek") != 0L
        ) {
            throw Failure("start_ack_not_consumed_cleanly")
        }
    }

    // Idempotent lifecycle proof: destroy ok, second destroy not_found,
    // post-destroy snapshot not_found.
    fun destroyAndVerifyLifecycle(): Boolean {
        if (handle == 0L) throw Failure("lifecycle_no_handle")
        val h = handle
        val destroyKv = parseStatus(
            VanguardNativeBridge.destroyAudioGraphPipelineSmokeSession(h)
        )
        handle = 0L
        val againKv = parseStatus(
            VanguardNativeBridge.destroyAudioGraphPipelineSmokeSession(h)
        )
        val snapKv = parseStatus(VanguardNativeBridge.snapshotAudioGraphPipeline(h))
        return destroyKv["status"] == "ok" &&
            againKv["status"] == "not_found" &&
            snapKv["status"] == "not_found"
    }

    // Finally-safe: destroys the native session if the run failed before
    // destroyAndVerifyLifecycle() zeroed the handle.
    fun cleanup() {
        if (handle != 0L) {
            try {
                VanguardNativeBridge.destroyAudioGraphPipelineSmokeSession(handle)
            } catch (_: Throwable) {}
            handle = 0L
        }
    }

    // ── Ingest + deadlock-free backpressure drive ───────────────────────────

    // One ingest call of [frames] frames held at byte offset 0 of [pcm];
    // mirrors the native accepted-side checksum over exactly the accepted
    // interleaved samples.
    fun ingestOnce(pcm: ByteBuffer, frames: Int): IngestReply {
        checkDeadline()
        if (frames <= 0) throw Failure("ingest_invalid_frame_count")
        if (frames.toLong() > NATIVE_MAX_INGEST_FRAMES) {
            throw Failure("ingest_chunk_exceeds_native_clamp")
        }
        if (frames.toLong() * bytesPerFrame > pcm.capacity()) {
            throw Failure("ingest_chunk_exceeds_buffer")
        }
        val kv = parseNative(
            VanguardNativeBridge.ingestAudioGraphPipelinePcm16(handle, pcm, frames)
        )
        if (kv["status"] != "ok") throw Failure("ingest_status_${kv["status"]}")
        val accepted = longField(kv, "framesAccepted")
        val writerStatus = kv["writerStatus"] ?: ""
        when (writerStatus) {
            "ok" -> {}
            "partial_write" -> sourcePartialWriteObserved = true
            "ring_full" -> sourceRingFullObserved = true
            else -> throw Failure("unexpected_writer_status_$writerStatus")
        }
        if (accepted > 0L) {
            val sampleCount = (accepted * channelCount).toInt()
            var c = kotlinChecksum
            for (i in 0 until sampleCount) {
                c = c * 31L + (pcm.getShort(i * 2).toLong() and 0xFFFFL)
            }
            kotlinChecksum = c
            kotlinFramesAccepted += accepted
        }
        totalFramesAccepted = longField(kv, "totalFramesAccepted")
        nativeAcceptedChecksumHex = kv["nativeAcceptedChecksumHex"] ?: ""
        writerAvailableToWrite = longField(kv, "writerAvailableToWrite")
        sourceAvailableReadFrames = longField(kv, "sourceAvailableReadFrames")
        return IngestReply(accepted, writerStatus, writerAvailableToWrite)
    }

    // Lossless ingest of [frames] frames at byte offset 0 of [pcm]: retries
    // through ring backpressure by dispatching one window (and draining it)
    // to free space, compacting the unwritten remainder to byte offset 0
    // after every partial acceptance. No decoded frame is ever dropped.
    fun ingestChunkLossless(pcm: ByteBuffer, frames: Int) {
        var remaining = frames
        var retries = 0
        while (remaining > 0) {
            checkDeadline()
            if (++retries > MAX_CHUNK_RETRIES) throw Failure("chunk_retry_budget_exhausted")
            val r = ingestOnce(pcm, remaining)
            if (r.framesAccepted > 0L) {
                if (r.framesAccepted < remaining) {
                    compactRemainder(pcm, r.framesAccepted.toInt(), remaining)
                }
                remaining -= r.framesAccepted.toInt()
            }
            if (remaining > 0) {
                // Ring out of space; the full ring guarantees at least one
                // dispatchable window (srcCap >= 2*maxFramesPerMix).
                if (sourceAvailableReadFrames < mfpm) {
                    throw Failure("ring_full_without_full_window")
                }
                if (!stepOneWindow()) throw Failure("ring_full_pump_deferred")
            }
        }
    }

    // Drives the closed loop while a full window of source frames is
    // available: step at the accepted-frame-axis tick, drain each dispatched
    // window, drain-and-retry on output backpressure. Stops at the
    // (normal) deferred_insufficient_source boundary.
    fun pumpWhileFullWindows() {
        var guard = 0
        val budget = (srcCap / mfpm) + 4
        while (sourceAvailableReadFrames >= mfpm) {
            checkDeadline()
            if (++guard > budget) throw Failure("pump_budget_exhausted")
            if (!stepOneWindow()) break
        }
    }

    // One dispatch attempt: returns true when a full window was dispatched
    // and drained, false on deferred_insufficient_source (normal while
    // awaiting more decode). Output backpressure is drained and retried
    // under a bounded budget.
    private fun stepOneWindow(): Boolean {
        var retries = 0
        while (true) {
            checkDeadline()
            if (++retries > MAX_STEP_RETRIES) throw Failure("step_retry_budget_exhausted")
            val kv = stepRaw(tickForFrame(nativeNextDispatchFrame + mfpm), flushTail = false)
            when (kv["status"]) {
                "dispatch_ok" -> {
                    if (drainFrames(mfpm) != mfpm) throw Failure("window_drain_short")
                    return true
                }
                "output_backpressure" -> drainAllOutput()
                "deferred_insufficient_source" -> return false
                else -> throw Failure("pump_step_status_${kv["status"]}")
            }
        }
    }

    fun drainAllOutput() {
        var iters = 0
        while (true) {
            checkDeadline()
            if (++iters > MAX_DRAIN_ITERATIONS) throw Failure("drain_budget_exhausted")
            val kv = drainOutputOnce(outCap.toInt())
            if (longField(kv, "outputAvailableReadFrames") == 0L) return
        }
    }

    // ── Deterministic backpressure lanes ────────────────────────────────────

    // Source lane: fills the source ring with held direct-buffer data until
    // native reports exactly P frames of writer space (small P > 0), then
    // requests strictly more than P and asserts a partial_write of exactly P
    // frames; an immediate retry with the same compacted remainder and no
    // drain must report ring_full with zero frames accepted. The probe
    // remainder is then ingested losslessly.
    fun runSourceBackpressureLane(held: ByteBuffer) {
        val heldCapFrames = (held.capacity() / bytesPerFrame).toLong()
        val targetP = maxOf(1L, mfpm / 4L)
        val overRequest = targetP + maxOf(1L, mfpm / 4L)
        if (overRequest > heldCapFrames) throw Failure("source_lane_held_buffer_too_small")

        // Initial estimate from the (always-fresh) read side; residual
        // source is < maxFramesPerMix here, so the loop always runs at least
        // once and terminates on the native-reported writerAvailableToWrite.
        var free = srcCap - sourceAvailableReadFrames
        var guard = 0
        while (free > targetP) {
            checkDeadline()
            if (++guard > MAX_LANE_ITERATIONS) throw Failure("source_lane_fill_budget_exhausted")
            val req = minOf(free - targetP, heldCapFrames, NATIVE_MAX_INGEST_FRAMES)
            val r = ingestOnce(held, req.toInt())
            if (r.writerStatus != "ok" || r.framesAccepted != req) {
                throw Failure("source_lane_fill_rejected_${r.writerStatus}_${r.framesAccepted}")
            }
            free = r.writerAvailableToWrite
        }
        if (free != targetP) throw Failure("source_lane_target_free_mismatch_$free")

        // Partial probe: request strictly more than the native-reported free
        // space; exactly P frames must be accepted.
        val r1 = ingestOnce(held, overRequest.toInt())
        if (r1.writerStatus != "partial_write" ||
            r1.framesAccepted != targetP ||
            r1.framesAccepted <= 0L ||
            r1.framesAccepted >= overRequest
        ) {
            throw Failure(
                "source_lane_partial_write_not_observed_${r1.writerStatus}_${r1.framesAccepted}"
            )
        }
        // Immediate retry with the same remaining data and no drain in
        // between: the full ring must report ring_full and accept nothing.
        compactRemainder(held, targetP.toInt(), overRequest.toInt())
        val remainder = (overRequest - targetP).toInt()
        val r2 = ingestOnce(held, remainder)
        if (r2.writerStatus != "ring_full" || r2.framesAccepted != 0L) {
            throw Failure(
                "source_lane_ring_full_not_observed_${r2.writerStatus}_${r2.framesAccepted}"
            )
        }
        // Lossless completion of the probe remainder.
        ingestChunkLossless(held, remainder)
    }

    // Output lane: with a drained output ring and (outCap/mfpm + 1) full
    // windows of source frames, withholds all drains while stepping; the
    // first outCap/mfpm steps dispatch, and the extra step must report
    // output_backpressure with zero frames rendered. A full drain then lets
    // the retried step (same tick) dispatch.
    fun runOutputBackpressureLane(held: ByteBuffer) {
        drainAllOutput()
        val bpWindows = outCap / mfpm
        val neededSource = (bpWindows + 1L) * mfpm
        val heldCapFrames = (held.capacity() / bytesPerFrame).toLong()
        var guard = 0
        while (sourceAvailableReadFrames < neededSource) {
            checkDeadline()
            if (++guard > MAX_LANE_ITERATIONS) throw Failure("output_lane_topup_budget_exhausted")
            val free = srcCap - sourceAvailableReadFrames
            val req = minOf(
                neededSource - sourceAvailableReadFrames, free,
                heldCapFrames, NATIVE_MAX_INGEST_FRAMES,
            )
            if (req <= 0L) throw Failure("output_lane_topup_stalled")
            val r = ingestOnce(held, req.toInt())
            if (r.writerStatus != "ok" || r.framesAccepted != req) {
                throw Failure("output_lane_topup_rejected_${r.writerStatus}_${r.framesAccepted}")
            }
        }
        for (k in 1..bpWindows) {
            val kv = stepRaw(tickForFrame(nativeNextDispatchFrame + mfpm), flushTail = false)
            if (kv["status"] != "dispatch_ok") {
                throw Failure("output_lane_fill_step_status_${kv["status"]}")
            }
        }
        val bpKv = stepRaw(tickForFrame(nativeNextDispatchFrame + mfpm), flushTail = false)
        if (bpKv["status"] != "output_backpressure") {
            throw Failure("output_backpressure_not_observed_${bpKv["status"]}")
        }
        // stepRaw already asserted framesRendered == 0 and latched the
        // outputBackpressureObserved lane.
        drainAllOutput()
        val retryKv = stepRaw(tickForFrame(nativeNextDispatchFrame + mfpm), flushTail = false)
        if (retryKv["status"] != "dispatch_ok") {
            throw Failure("output_lane_retry_step_status_${retryKv["status"]}")
        }
        if (drainFrames(mfpm) != mfpm) throw Failure("output_lane_retry_drain_short")
    }

    // ── EOS tail flush + accepted-frame-axis seek ───────────────────────────

    // Lossless boundary flush: writer-local EOS, then a general tail-flush
    // loop that recomputes the tick from the native-reported
    // nextDispatchFrame each iteration, accepts dispatch_ok and
    // tail_flush_partial_window (draining after each), drains through output
    // backpressure, and terminates only on tail_flush_complete. Afterwards
    // the output ring is drained and the source ring must be empty.
    fun flushTailAtEos() {
        val eosKv = parseNative(VanguardNativeBridge.setAudioGraphPipelineEos(handle))
        if (eosKv["status"] != "ok" || eosKv["eos"] != "true") {
            throw Failure("eos_set_failed_${eosKv["status"]}")
        }
        var budget = 0
        val tailBudget = (srcCap / mfpm) + 8
        while (true) {
            checkDeadline()
            if (++budget > tailBudget) throw Failure("tail_flush_budget_exhausted")
            val kv = stepRaw(tickForFrame(nativeNextDispatchFrame + mfpm), flushTail = true)
            when (kv["status"]) {
                "dispatch_ok", "tail_flush_partial_window" -> {
                    val rendered = longField(kv, "framesRendered")
                    if (rendered <= 0L) throw Failure("tail_flush_rendered_zero")
                    if (drainFrames(rendered) != rendered) throw Failure("tail_flush_drain_short")
                }
                "tail_flush_complete" -> break
                "output_backpressure" -> drainAllOutput()
                else -> throw Failure("tail_flush_step_status_${kv["status"]}")
            }
        }
        drainAllOutput()
        if (sourceAvailableReadFrames != 0L) throw Failure("tail_flush_source_not_empty")
    }

    // Native seek on the accepted-frame axis (not media PTS). With A =
    // totalFramesAccepted after a completed tail flush, the seek pts is
    // ceil(A * 1e6 / sampleRate) so native computes targetFrame == A; the
    // reply must re-anchor writer/provider at exactly A with zero discards,
    // the ack drain must land newStartFrame == A with zero discards, and the
    // seek must clear the writer-local EOS. Returns A.
    fun seekToAcceptedFrameBoundary(): Long {
        val acceptedFrame = totalFramesAccepted
        if (acceptedFrame != totalOutputFramesDrained) {
            throw Failure("seek_boundary_not_fully_drained")
        }
        if (acceptedFrame != localCursorFrame) throw Failure("seek_boundary_cursor_mismatch")
        val seekPtsUs = ceilDiv(acceptedFrame * 1_000_000L, sampleRate.toLong())
        // The tail-flush ticks overshoot the boundary tick, so anchor the
        // seek at the monotonic maximum of the two (equality allowed).
        val rawTick = anchorSysNs + (seekPtsUs - anchorPtsUs) * 1_000L
        val seekSysNs = maxOf(rawTick, lastTickNs)
        lastTickNs = seekSysNs
        val kv = parseNative(
            VanguardNativeBridge.seekAudioGraphPipeline(handle, seekPtsUs, seekSysNs)
        )
        if (kv["status"] != "ok") throw Failure("seek_status_${kv["status"]}")
        if (longField(kv, "targetFrame") != acceptedFrame ||
            longField(kv, "providerExpectedNextFrame") != acceptedFrame ||
            longField(kv, "writerNextWriteFrame") != acceptedFrame ||
            longField(kv, "discardedFramesOnSeek") != 0L
        ) {
            throw Failure("seek_accepted_frame_axis_mismatch")
        }
        anchorPtsUs = seekPtsUs
        anchorSysNs = seekSysNs
        val stepKv = stepRaw(seekSysNs, flushTail = false)
        if (stepKv["status"] != "awaiting_seek_ack") {
            throw Failure("post_seek_step_not_awaiting_seek_ack_${stepKv["status"]}")
        }
        val ackKv = drainOutputOnce(outCap.toInt())
        if (ackKv["seekAckConsumed"] != "true" ||
            longField(ackKv, "newStartFrame") != acceptedFrame ||
            longField(ackKv, "discardedFramesOnSeek") != 0L
        ) {
            throw Failure("seek_ack_not_consumed_cleanly")
        }
        val snap = snapshot()
        if (snap["writerEos"] != "false") throw Failure("seek_did_not_clear_writer_eos")
        return acceptedFrame
    }

    // ── Snapshot / probes / verdict helpers ─────────────────────────────────

    fun snapshotMetrics(): Map<String, String> = snapshot()

    fun verifyZeroSteadyStateAllocation(snap: Map<String, String>): Boolean =
        dispatchCount >= MIN_STEADY_STATE_DISPATCHES &&
            schedCapBefore == longField(snap, "schedulerTrackScratchCapacitySamples") &&
            schedTracksBefore == longField(snap, "schedulerTrackScratchCapacityTracks") &&
            srcStorageBefore == longField(snap, "sourceRingStorageCapacitySamples") &&
            outStorageBefore == longField(snap, "outputRingStorageCapacitySamples")

    // Deliberate foreign-thread snapshot that native must fail closed with
    // wrong_owner_thread; call only at a quiescent point.
    fun probeForeignThreadRejected(): Boolean {
        val status = AtomicReference("")
        val probeThread = Thread {
            status.set(
                parseStatus(VanguardNativeBridge.snapshotAudioGraphPipeline(handle))["status"]
                    ?: ""
            )
        }
        probeThread.start()
        probeThread.join(FOREIGN_PROBE_JOIN_MS)
        return status.get() == "wrong_owner_thread"
    }

    // ── Internals ───────────────────────────────────────────────────────────

    private fun checkDeadline() {
        if (SystemClock.elapsedRealtime() > deadlineElapsedRealtimeMs) {
            throw Failure("deadline_exceeded")
        }
    }

    private fun ceilDiv(a: Long, b: Long): Long = (a + b - 1) / b

    // Accepted-frame-axis tick: equal ticks are allowed (backpressure
    // retries), only a decrease fails.
    private fun tickForFrame(frame: Long): Long {
        val ptsUs = ceilDiv(frame * 1_000_000L, sampleRate.toLong())
        val tick = anchorSysNs + (ptsUs - anchorPtsUs) * 1_000L
        if (tick < lastTickNs) throw Failure("non_monotonic_driver_tick")
        lastTickNs = tick
        return tick
    }

    private fun stepRaw(sysTimeNs: Long, flushTail: Boolean): Map<String, String> {
        checkDeadline()
        val kv = parseNative(
            VanguardNativeBridge.stepAudioGraphPipeline(handle, sysTimeNs, flushTail)
        )
        val status = kv["status"] ?: ""
        if (!kv.containsKey("sourceAvailableReadFrames")) {
            throw Failure("step_missing_source_available_read_frames")
        }
        if (status == "ring_push_shortfall") {
            ringPushShortfallSeen = true
            throw Failure("ring_push_shortfall_observed")
        }
        if (status == "dispatch_silence") throw Failure("unexpected_silence_window")
        sourceAvailableReadFrames = longField(kv, "sourceAvailableReadFrames")
        outputAvailableReadFrames = longField(kv, "outputAvailableReadFrames")
        dispatchCount = longField(kv, "dispatchCount")
        val next = longField(kv, "nextDispatchFrame")
        if (next < nativeNextDispatchFrame) throw Failure("native_cursor_decreased")
        nativeNextDispatchFrame = next
        if (status == "dispatch_ok" || status == "tail_flush_partial_window") {
            localCursorFrame += longField(kv, "framesRendered")
        }
        if (localCursorFrame != nativeNextDispatchFrame) {
            throw Failure("cursor_cross_check_mismatch")
        }
        if (status == "dispatch_ok" && longField(kv, "framesRendered") != mfpm) {
            throw Failure("window_size_drift")
        }
        if (status == "output_backpressure") {
            if (longField(kv, "framesRendered") != 0L) {
                throw Failure("output_backpressure_rendered_frames")
            }
            outputBackpressureObserved = true
        }
        return kv
    }

    private fun drainOutputOnce(maxFrames: Int): Map<String, String> {
        checkDeadline()
        val kv = parseNative(
            VanguardNativeBridge.drainAudioGraphPipelineOutput(handle, maxFrames)
        )
        if (kv["status"] != "ok") throw Failure("drain_status_${kv["status"]}")
        totalOutputFramesDrained = longField(kv, "totalOutputFramesDrained")
        nativeOutputDrainChecksumHex = kv["nativeOutputDrainChecksumHex"] ?: ""
        outputAvailableReadFrames = longField(kv, "outputAvailableReadFrames")
        return kv
    }

    private fun drainFrames(maxFrames: Long): Long =
        longField(drainOutputOnce(maxFrames.toInt()), "framesDrained")

    private fun snapshot(): Map<String, String> {
        checkDeadline()
        val kv = parseNative(VanguardNativeBridge.snapshotAudioGraphPipeline(handle))
        if (kv["status"] != "ok") throw Failure("snapshot_status_${kv["status"]}")
        providerUnderrunEvents = longField(kv, "providerUnderrunEvents")
        providerFramesZeroFilled = longField(kv, "providerFramesZeroFilled")
        providerForwardSkipFrames = longField(kv, "providerForwardSkipFrames")
        providerRewindRejects = longField(kv, "providerRewindRejects")
        coordinatorSilenceCount = longField(kv, "silenceCount")
        totalFramesAccepted = longField(kv, "totalFramesAccepted")
        totalOutputFramesDrained = longField(kv, "totalOutputFramesDrained")
        nativeAcceptedChecksumHex = kv["nativeAcceptedChecksumHex"] ?: ""
        nativeOutputDrainChecksumHex = kv["nativeOutputDrainChecksumHex"] ?: ""
        sourceAvailableReadFrames = longField(kv, "sourceAvailableReadFrames")
        outputAvailableReadFrames = longField(kv, "outputAvailableReadFrames")
        dispatchCount = longField(kv, "dispatchCount")
        nativeNextDispatchFrame = longField(kv, "nextDispatchFrame")
        snapshotTerminal = kv["terminal"] == "true"
        snapshotAwaitingSeekAck = kv["awaitingSeekAck"] == "true"
        return kv
    }

    // Unwritten frames move to byte offset 0 so retries always read from the
    // buffer start, exactly like the sub-slice G decoder.
    private fun compactRemainder(buf: ByteBuffer, acceptedFrames: Int, totalFrames: Int) {
        buf.position(acceptedFrames * bytesPerFrame)
        buf.limit(totalFrames * bytesPerFrame)
        buf.compact()
    }

    private fun parseNative(raw: String): Map<String, String> {
        val kv = parseStatus(raw)
        lastStatus = kv["status"] ?: ""
        return kv
    }

    private fun parseStatus(raw: String): Map<String, String> =
        raw.split(';').mapNotNull { part ->
            val idx = part.indexOf('=')
            if (idx <= 0) null else part.substring(0, idx) to part.substring(idx + 1)
        }.toMap()

    private fun longField(kv: Map<String, String>, key: String): Long =
        kv[key]?.toLongOrNull() ?: throw Failure("missing_status_field_$key")
}
