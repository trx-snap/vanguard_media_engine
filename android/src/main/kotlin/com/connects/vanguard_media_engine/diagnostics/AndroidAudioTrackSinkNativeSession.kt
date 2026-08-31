package com.connects.vanguard_media_engine.diagnostics

import android.os.SystemClock
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicReference

// ── AndroidAudioTrackSinkNativeSession (P4-AUDIO-AUDIOTRACK-OUTPUT-SINK-WRITE) ─
//
// Owner-thread wrapper around the sub-slice H1 closed-loop native audio graph
// pipeline JNI seam (android_phase4_audio_graph_pipeline_session_jni.cpp) for
// the P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice I AudioTrack output sink
// diagnostic. Mirrors the H2 wrapper
// (AndroidAudioGraphPipelineRealDecoderNativeSession) lifecycle/tick/status
// parsing patterns but reads mixed output PCM through the new
// readAudioGraphPipelineOutputPcm16 entry point directly into the caller's
// reusable direct ByteBuffer so the exact same bytes can be handed to
// android.media.AudioTrack without an extra copy.
//
// Tick model: frame-derived virtual ticks only, on the accepted-frame axis
// exactly like H2:
//   F = nativeNextDispatchFrame + maxFramesPerMix
//   ptsUs = ceil(F * 1_000_000 / sampleRate)
//   sysTimeNs = anchorSysNs + (ptsUs - anchorPtsUs) * 1000
// re-anchored at start() and at the one accepted-frame-boundary seek.
// System.nanoTime() never feeds a native sysTimeNs; wall time is telemetry
// only, in the driver.
//
// Output-ring read discipline: for the whole sink run the output ring is
// drained exclusively through readOutputPcm — including the maxFrames == 0
// ack-only reads at start/seek. drainAudioGraphPipelineOutput is never mixed
// into this read path.
//
// Honest non-claims: no threads spawned except the single short-lived
// foreign-thread probe that native must reject; no audible-output claim, no
// AAudio/OpenSL/Oboe ownership, no export or pass-2 reroute, no
// streaming/cache, no iOS, no product/editor UI.
class AndroidAudioTrackSinkNativeSession(
    private val deadlineElapsedRealtimeMs: Long,
) {
    class Failure(val reason: String) : Exception(reason)

    data class IngestReply(
        val framesAccepted: Long,
        val writerStatus: String,
        val writerAvailableToWrite: Long,
    )

    data class ReadReply(
        val framesRead: Long,
        val outputAvailableReadFrames: Long,
        val seekAckConsumed: Boolean,
        val discardedFramesOnSeek: Long,
        val newStartFrame: Long,
    )

    data class TailStep(
        val status: String,
        val framesRendered: Long,
    )

    companion object {
        private const val ANCHOR_SYS_TIME_NS = 1_000_000_000L
        // Matches the native per-call ingest clamp (AudioDecoderRingWriter
        // kMaxWriteFrames).
        private const val NATIVE_MAX_INGEST_FRAMES = 8_192L
        private const val MIN_STEADY_STATE_DISPATCHES = 50L
        private const val FOREIGN_PROBE_JOIN_MS = 5_000L
    }

    // Geometry, frozen at create().
    private var handle = 0L
    private var sampleRate = 0
    private var channelCount = 0
    private var bytesPerFrame = 0
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

    var totalFramesAccepted = 0L
        private set
    var totalOutputFramesDrained = 0L
        private set
    var nativeOutputDrainChecksumHex = ""
        private set
    var dispatchCount = 0L
        private set
    var lastStatus = ""
        private set

    var ringPushShortfallSeen = false
        private set

    // Folded from the most recent snapshot.
    var providerUnderrunEvents = 0L
        private set
    var providerFramesZeroFilled = 0L
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
        mfpm = maxFramesPerMix.toLong()
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
    // start ack through an ack-only readOutputPcm (which must land at frame
    // 0 with zero discards and zero frames read).
    fun startAndConsumeAck(ackBuffer: ByteBuffer) {
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
        readAckOnly(ackBuffer, expectedStartFrame = 0L)
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

    // ── Ingest / step / read primitives ─────────────────────────────────────

    // One ingest call of [frames] frames held at byte offset 0 of [pcm].
    // partial_write / ring_full are legal here (the driver retries
    // losslessly after freeing source space through its sink write path).
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
        val writerStatus = kv["writerStatus"] ?: ""
        when (writerStatus) {
            "ok", "partial_write", "ring_full" -> {}
            else -> throw Failure("unexpected_writer_status_$writerStatus")
        }
        totalFramesAccepted = longField(kv, "totalFramesAccepted")
        sourceAvailableReadFrames = longField(kv, "sourceAvailableReadFrames")
        return IngestReply(
            framesAccepted = longField(kv, "framesAccepted"),
            writerStatus = writerStatus,
            writerAvailableToWrite = longField(kv, "writerAvailableToWrite"),
        )
    }

    // One non-tail dispatch attempt at the frame-derived virtual tick.
    // Returns the status token; the driver handles dispatch_ok /
    // deferred_insufficient_source / output_backpressure.
    fun stepWindow(): String {
        val kv = stepRaw(tickForFrame(nativeNextDispatchFrame + mfpm), flushTail = false)
        return kv["status"] ?: ""
    }

    // One tail-flush dispatch attempt (writer EOS required by native).
    fun stepTailWindow(): TailStep {
        val kv = stepRaw(tickForFrame(nativeNextDispatchFrame + mfpm), flushTail = true)
        return TailStep(
            status = kv["status"] ?: "",
            framesRendered = longField(kv, "framesRendered"),
        )
    }

    // Writer-local EOS only (cleared by the next successful seek request).
    fun setEosVerified() {
        val kv = parseNative(VanguardNativeBridge.setAudioGraphPipelineEos(handle))
        if (kv["status"] != "ok" || kv["eos"] != "true") {
            throw Failure("eos_set_failed_${kv["status"]}")
        }
    }

    // Pops up to [maxFrames] frames into byte offset 0 of the caller's
    // reused direct [sinkBuffer] through the sub-slice I JNI read entry
    // point. A pending seek ack is consumed by native first; the caller
    // states whether one is expected — a surprise ack (which would discard
    // frames silently) or a missing expected ack fails closed.
    fun readOutputPcm(
        sinkBuffer: ByteBuffer,
        maxFrames: Int,
        expectSeekAck: Boolean = false,
    ): ReadReply {
        checkDeadline()
        if (maxFrames < 0) throw Failure("read_invalid_max_frames")
        val kv = parseNative(
            VanguardNativeBridge.readAudioGraphPipelineOutputPcm16(handle, sinkBuffer, maxFrames)
        )
        if (kv["status"] != "ok") throw Failure("read_status_${kv["status"]}")
        val framesRead = longField(kv, "framesRead")
        if (longField(kv, "bytesRead") != framesRead * bytesPerFrame) {
            throw Failure("read_bytes_mismatch")
        }
        totalOutputFramesDrained = longField(kv, "totalOutputFramesDrained")
        nativeOutputDrainChecksumHex = kv["nativeOutputDrainChecksumHex"] ?: ""
        outputAvailableReadFrames = longField(kv, "outputAvailableReadFrames")
        val ackConsumed = kv["seekAckConsumed"] == "true"
        if (ackConsumed != expectSeekAck) {
            throw Failure(
                if (ackConsumed) "read_unexpected_seek_ack" else "read_seek_ack_missing"
            )
        }
        return ReadReply(
            framesRead = framesRead,
            outputAvailableReadFrames = outputAvailableReadFrames,
            seekAckConsumed = ackConsumed,
            discardedFramesOnSeek = longField(kv, "discardedFramesOnSeek"),
            newStartFrame = longField(kv, "newStartFrame"),
        )
    }

    // Ack-only read (maxFrames = 0) after start/seek: the ack must land at
    // [expectedStartFrame] with zero discards and zero frames read.
    fun readAckOnly(sinkBuffer: ByteBuffer, expectedStartFrame: Long) {
        val rr = readOutputPcm(sinkBuffer, 0, expectSeekAck = true)
        if (rr.framesRead != 0L ||
            rr.discardedFramesOnSeek != 0L ||
            rr.newStartFrame != expectedStartFrame
        ) {
            throw Failure("ack_not_consumed_cleanly")
        }
    }

    // ── Accepted-frame-axis seek ────────────────────────────────────────────

    // Native seek on the accepted-frame axis (not media PTS), exactly like
    // H2: with A = totalFramesAccepted after a completed tail flush, the
    // seek pts is ceil(A * 1e6 / sampleRate) so native computes
    // targetFrame == A; the reply must re-anchor writer/provider at exactly
    // A with zero discards, the ack-only read must land newStartFrame == A
    // with zero discards, and the seek must clear the writer-local EOS.
    // Returns A.
    fun seekToAcceptedFrameBoundary(ackBuffer: ByteBuffer): Long {
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
        readAckOnly(ackBuffer, expectedStartFrame = acceptedFrame)
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
    // wrong_owner_thread; call only at a quiescent point. This is the only
    // extra thread besides the coordinator/driver worker.
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
        if (status == "output_backpressure" && longField(kv, "framesRendered") != 0L) {
            throw Failure("output_backpressure_rendered_frames")
        }
        return kv
    }

    private fun snapshot(): Map<String, String> {
        checkDeadline()
        val kv = parseNative(VanguardNativeBridge.snapshotAudioGraphPipeline(handle))
        if (kv["status"] != "ok") throw Failure("snapshot_status_${kv["status"]}")
        providerUnderrunEvents = longField(kv, "providerUnderrunEvents")
        providerFramesZeroFilled = longField(kv, "providerFramesZeroFilled")
        coordinatorSilenceCount = longField(kv, "silenceCount")
        totalFramesAccepted = longField(kv, "totalFramesAccepted")
        totalOutputFramesDrained = longField(kv, "totalOutputFramesDrained")
        nativeOutputDrainChecksumHex = kv["nativeOutputDrainChecksumHex"] ?: ""
        sourceAvailableReadFrames = longField(kv, "sourceAvailableReadFrames")
        outputAvailableReadFrames = longField(kv, "outputAvailableReadFrames")
        dispatchCount = longField(kv, "dispatchCount")
        nativeNextDispatchFrame = longField(kv, "nextDispatchFrame")
        snapshotTerminal = kv["terminal"] == "true"
        snapshotAwaitingSeekAck = kv["awaitingSeekAck"] == "true"
        return kv
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
