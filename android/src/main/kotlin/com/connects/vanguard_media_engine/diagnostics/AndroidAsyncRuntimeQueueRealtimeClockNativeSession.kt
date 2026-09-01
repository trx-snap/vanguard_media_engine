package com.connects.vanguard_media_engine.diagnostics

import android.os.SystemClock
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidAsyncRuntimeQueueRealtimeClockNativeSession (P4 True-DAG
// sub-slice X3) ─────────────────────────────────────────────────────────────
//
// Owner-thread wrapper around the realtime-clock async runtime queue JNI
// seam (android_phase4_async_runtime_queue_realtime_clock_jni.cpp), used by
// the muted-AudioTrack realtime pacing driver
// [AndroidAsyncRuntimeQueueRealtimeClockDriver]. The NATIVE WORKER thread
// inside the session is the sole reader of std::chrono::steady_clock for
// media time and the sole caller of every AudioClock mutator, every
// ClockedAudioTransportCoordinator control/dispatch method, and the output
// ring's producer role; this class only ingests decoded PCM through the
// node-owned source-ring writer, enqueues start/seek commands (which carry
// NO time values — see [startAndConsumeAck]/[seekAtQuiescentBoundary]),
// reads the output ring, and observes the worker through the
// mutex-published snapshot mirror.
//
// X3 differences from the committed X2 wrapper
// (AndroidAsyncRuntimeQueueAudioTrackSinkNativeSession, which stays
// untouched and behaviorally reproducible):
//   - No caller-supplied ticks anywhere: the X3 JNI entry points have no
//     sysTimeNs/syntheticSysTimeNs parameters, so this wrapper holds no
//     tick anchor mirror at all. Kotlin never derives native media time.
//   - Only two control commands exist (start, seek); there is no
//     pause/resume lane and no deterministic backpressure verification
//     lane (backpressure is normal telemetry in X3).
//   - [ingestPrefill] supports the pre-start / post-seek source fill
//     quotas: it never drains output (so it can never consume a pending
//     output ack early) and returns the not-yet-accepted remainder on a
//     writer stall instead of retrying.
//   - [seekAtQuiescentBoundary] enqueues + awaits the seek command only;
//     [consumeSeekAckAndReanchor] consumes the output ack separately so
//     the driver can prefill the post-seek source ring while the worker is
//     provably parked on the pending output ack gate.
//
// Owner-thread affinity: every non-destroy entry point is owner-only in
// native; this object must be created AND driven on the single Kotlin
// worker thread that calls create().
//
// Honest non-claims: muted diagnostic realtime pacing proof only; the
// native steady_clock timebase is a render/dispatch timebase, not a
// presentation clock; no audible output, no product/editor/app wiring, no
// streaming/cache, no iOS, no C++ primitive changes. Zero-fill is never
// allowed into the identity checksums: the driver completes the exact
// expected timeline before setting the writer-local EOS, and this wrapper
// fails closed if any provider zero-fill is observed.
class AndroidAsyncRuntimeQueueRealtimeClockNativeSession(
    private val deadlineElapsedRealtimeMs: Long,
    private val outputSink: OutputSink,
) {
    class Failure(val reason: String) : Exception(reason)

    // Invoked after every destructive output read that produced frames: the
    // freshly read PCM16 sits at byte offset 0 of the read buffer supplied
    // to [create]. The sink must fully consume (write + account) the frames
    // before returning, or throw; the session issues no further native call
    // while staged frames remain unconsumed.
    fun interface OutputSink {
        fun onOutputFramesRead(frames: Long)
    }

    data class IngestReply(
        val framesAccepted: Long,
        val writerStatus: String,
        val writerBackpressureRejects: Long,
    )

    companion object {
        // Verbatim native TU constant; the snapshot must echo it so a
        // physical run proves the exact realtime-clock TU executed.
        const val NATIVE_PROOF_BOUNDARY =
            "diagnostic_async_runtime_queue_realtime_clock_proof_only_worker_owned_std_chrono_steady_clock_render_dispatch_timebase_no_caller_supplied_native_time_on_any_control_command_command_serialized_source_ring_spsc_output_ring_spsc_full_window_dispatch_bounded_catch_up_max_eight_per_wake_condition_variable_wait_clamped_5ms_not_a_presentation_clock_no_audible_output_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_realtime_priority_no_sched_fifo_no_affinity_no_product_editor_app_wiring_no_streaming_cache_no_ios_no_export_route_changes"

        // Matches the native per-call ingest clamp
        // (AudioDecoderRingWriter kMaxWriteFrames).
        private const val NATIVE_MAX_INGEST_FRAMES = 8_192L
        private const val POLL_SLEEP_MS = 2L
        private const val MAX_INGEST_STALL_RETRIES = 8_192
        private const val MAX_SEEK_TRANSIENT_RETRIES = 64
    }

    // Geometry, frozen at create().
    private var handle = 0L
    private var sampleRate = 0
    private var channelCount = 0
    private var bytesPerFrame = 0
    private var srcCap = 0L
    private var outCap = 0L
    private var mfpm = 0L
    var expectedFrames = 0L
        private set

    // Driver-supplied direct buffer for every destructive output read.
    private var readBuf: ByteBuffer? = null

    // Owner-side command sequence mirror (asserted against every enqueue
    // reply and the processed-command snapshot).
    private var nextCommandSeq = 0L

    // Owner-side accounting folded from every reply.
    var totalFramesAccepted = 0L
        private set
    var kotlinFramesAccepted = 0L
        private set
    var kotlinChecksum = 0L
        private set
    var nativeAcceptedChecksumHex = ""
        private set
    var totalOutputFramesRead = 0L
        private set
    var nativeOutputReadChecksumHex = ""
        private set
    var writerBackpressureRejects = 0L
        private set

    // Lane observations.
    var workerOwnershipAtBootOk = false
        private set
    var seekReanchorOk = false
        private set
    var seekTargetFrame = -1L
        private set

    // Folded from the most recent snapshot (final metrics for the driver).
    var snapCommandsEnqueued = -1L
        private set
    var snapCommandsProcessed = -1L
        private set
    var snapCommandErrors = -1L
        private set
    var snapLastCommandSeq = -1L
        private set
    var snapQueueDepth = -1L
        private set
    var snapDispatchCount = -1L
        private set
    var snapOkCount = -1L
        private set
    var snapSilenceCount = -1L
        private set
    var snapBackpressureCount = -1L
        private set
    var snapSchedulerErrorCount = -1L
        private set
    var snapWorkerDispatchAnomalies = -1L
        private set
    var snapNonMonotonicTimeAnomalies = -1L
        private set
    var snapWorkerNoFramesDueWaits = -1L
        private set
    var snapWorkerStarvedWaits = -1L
        private set
    var snapProviderUnderrunEvents = -1L
        private set
    var snapProviderFramesZeroFilled = -1L
        private set
    var snapProviderForwardSkipFrames = -1L
        private set
    var snapProviderRewindRejects = -1L
        private set
    var snapTotalFramesRendered = -1L
        private set
    var snapTotalFramesPushed = -1L
        private set
    var snapOwnerDispatchCalls = -1L
        private set
    var snapWorkerThreadDistinct = false
        private set
    var snapTerminal = false
        private set
    var snapNoCallerSuppliedNativeTime = false
        private set
    var snapWorkerOwnsMonotonicClock = false
        private set
    var snapNativeTimingF0 = -1L
        private set
    var snapNativeTimingF1 = -1L
        private set
    var snapNativeRealtimeElapsedMs = -1L
        private set
    var snapRealtimeElapsedOk = false
        private set
    var snapMaxRenderCursorBacklogUs = -1L
        private set
    var snapRealtimeBacklogBoundOk = false
        private set
    var snapBacklogSampleCount = -1L
        private set
    var snapClockDriftSampleCount = -1L
        private set
    var snapProofBoundary = ""
        private set
    var lastStatus = ""
        private set

    val isCreated: Boolean get() = handle != 0L

    // ── Lifecycle ───────────────────────────────────────────────────────────

    // Creates the realtime-clock native session (which starts its worker
    // thread) and proves boot-time async ownership: worker started, worker
    // thread id distinct from this owner thread, zero owner dispatch calls,
    // and the structural no-caller-supplied-native-time token. The
    // driver-supplied [readBuffer] must be direct, little-endian, and large
    // enough to hold one full output-ring drain.
    fun create(
        sampleRateIn: Int,
        channelCountIn: Int,
        expectedFramesIn: Long,
        sourceRingCapacityFrames: Int,
        outputRingCapacityFrames: Int,
        maxFramesPerMix: Int,
        readBuffer: ByteBuffer,
    ) {
        if (handle != 0L) throw Failure("native_session_already_created")
        if (maxFramesPerMix <= 0) throw Failure("invalid_config_max_frames_per_mix")
        sampleRate = sampleRateIn
        channelCount = channelCountIn
        bytesPerFrame = 2 * channelCountIn
        srcCap = sourceRingCapacityFrames.toLong()
        outCap = outputRingCapacityFrames.toLong()
        mfpm = maxFramesPerMix.toLong()
        expectedFrames = expectedFramesIn
        if (outCap % mfpm != 0L) throw Failure("invalid_config_output_ring_alignment")
        if (expectedFrames <= 0L || expectedFrames % mfpm != 0L) {
            throw Failure("invalid_config_expected_frames_alignment")
        }
        // Frozen X3 geometry (also validated fail-closed in native).
        if (srcCap < outCap + 2L * mfpm) {
            throw Failure("invalid_config_source_ring_geometry")
        }
        if (!readBuffer.isDirect) throw Failure("read_buffer_not_direct")
        if (readBuffer.order() != ByteOrder.LITTLE_ENDIAN) {
            throw Failure("read_buffer_not_little_endian")
        }
        if (readBuffer.capacity() < outputRingCapacityFrames * bytesPerFrame) {
            throw Failure("read_buffer_too_small")
        }
        handle = VanguardNativeBridge.createAsyncRuntimeQueueRealtimeClockSession(
            sampleRateIn, channelCountIn, expectedFramesIn,
            sourceRingCapacityFrames, outputRingCapacityFrames, maxFramesPerMix,
        )
        if (handle == 0L) throw Failure("native_session_create_failed")
        readBuf = readBuffer
        val snapBoot = awaitSnapshot("worker_started") { it["workerStarted"] == "true" }
        if (snapBoot["workerThreadDistinct"] != "true") {
            throw Failure("worker_thread_not_distinct")
        }
        if (longField(snapBoot, "ownerDispatchCalls") != 0L) {
            throw Failure("owner_dispatch_calls_nonzero_at_boot")
        }
        if (snapBoot["noCallerSuppliedNativeTime"] != "true") {
            throw Failure("caller_supplied_native_time_token_missing")
        }
        workerOwnershipAtBootOk = true
    }

    // Enqueues the start command (no time value crosses JNI: the worker
    // reads steady_clock itself), waits for the worker to execute it, and
    // consumes the output-ring start ack (frame 0, zero discards). The
    // driver must have ingested the pre-start source fill quota first so
    // decode stays ahead of the realtime clock.
    fun startAndConsumeAck() {
        val kv = parseNative(
            VanguardNativeBridge.startAsyncRuntimeQueueRealtimeClock(handle)
        )
        if (kv["status"] != "enqueued") throw Failure("start_not_enqueued_${kv["status"]}")
        val seq = ++nextCommandSeq
        if (longField(kv, "commandSeq") != seq) throw Failure("start_command_seq_mismatch")
        val snap = awaitCommandProcessed(seq)
        if (snap["started"] != "true") throw Failure("start_state_mismatch")
        val ack = ackOnlyRead()
        if (ack["seekAckConsumed"] != "true" ||
            longField(ack, "newStartFrame") != 0L ||
            longField(ack, "discardedFramesOnSeek") != 0L
        ) {
            throw Failure("start_ack_not_consumed_cleanly")
        }
    }

    // ── Ingest (owner is the source-ring producer) ──────────────────────────

    // One ingest of [frames] frames held at byte offset 0 of [pcm]; the
    // owner checksum mirrors the native accepted-side checksum over exactly
    // the accepted leading interleaved samples of this call.
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
            VanguardNativeBridge.ingestAsyncRuntimeQueueRealtimeClockPcm16(handle, pcm, frames)
        )
        if (kv["status"] != "ok") throw Failure("ingest_status_${kv["status"]}")
        val accepted = longField(kv, "framesAccepted")
        val writerStatus = kv["writerStatus"] ?: ""
        when (writerStatus) {
            "ok", "partial_write", "ring_full" -> {}
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
        writerBackpressureRejects = longField(kv, "writerBackpressureRejects")
        return IngestReply(accepted, writerStatus, writerBackpressureRejects)
    }

    // Prefill ingest for the pre-start / post-seek source fill quotas: no
    // output reads run here (so a pending output ack can never be consumed
    // early), and a zero-accepted writer stall returns the remainder
    // (compacted to byte offset 0 of [pcm]) instead of retrying — a stall
    // means the source ring is full, which by geometry already satisfies
    // every fill quota. Returns 0 when the whole chunk fit.
    fun ingestPrefill(pcm: ByteBuffer, frames: Int): Int {
        var remaining = frames
        while (remaining > 0) {
            checkDeadline()
            val request = minOf(remaining.toLong(), NATIVE_MAX_INGEST_FRAMES).toInt()
            val r = ingestOnce(pcm, request)
            if (r.framesAccepted > 0L) {
                if (r.framesAccepted < remaining) {
                    compactRemainder(pcm, r.framesAccepted.toInt(), remaining)
                }
                remaining -= r.framesAccepted.toInt()
                continue
            }
            if (r.writerStatus != "ring_full") {
                throw Failure("prefill_unexpected_writer_status_${r.writerStatus}")
            }
            return remaining
        }
        return 0
    }

    // Lossless ingest of [frames] frames at byte offset 0 of [pcm]: the
    // async worker drains the source ring on its own realtime pace, so a
    // stalled (zero-accepted) call drains available output to the sink,
    // waits briefly, and retries the SAME compacted logical window. No
    // decoded frame is ever dropped here.
    fun ingestChunkLossless(pcm: ByteBuffer, frames: Int) {
        var remaining = frames
        var stalls = 0
        while (remaining > 0) {
            checkDeadline()
            val request = minOf(remaining.toLong(), NATIVE_MAX_INGEST_FRAMES).toInt()
            val r = ingestOnce(pcm, request)
            if (r.framesAccepted > 0L) {
                if (r.framesAccepted < remaining) {
                    compactRemainder(pcm, r.framesAccepted.toInt(), remaining)
                }
                remaining -= r.framesAccepted.toInt()
                stalls = 0
                continue
            }
            if (++stalls > MAX_INGEST_STALL_RETRIES) {
                throw Failure("ingest_stall_budget_exhausted")
            }
            if (drainAvailableOutput() == 0L) {
                Thread.sleep(POLL_SLEEP_MS)
            }
        }
    }

    // ── Output reads (owner is the output-ring consumer; every destructive
    // read hands its frames to the driver sink before any further native
    // call) ─────────────────────────────────────────────────────────────────

    private fun readOnce(maxFrames: Int): Map<String, String> {
        checkDeadline()
        val buf = readBuf ?: throw Failure("read_before_create")
        val kv = parseNative(
            VanguardNativeBridge.readAsyncRuntimeQueueRealtimeClockOutputPcm16(
                handle, buf, maxFrames,
            )
        )
        if (kv["status"] != "ok") throw Failure("read_status_${kv["status"]}")
        totalOutputFramesRead = longField(kv, "totalOutputFramesRead")
        nativeOutputReadChecksumHex = kv["nativeOutputReadChecksumHex"] ?: ""
        val framesRead = longField(kv, "framesRead")
        if (framesRead > 0L) {
            outputSink.onOutputFramesRead(framesRead)
        }
        return kv
    }

    // Ack-only read (maxFrames == 0): consumes a pending start/seek output
    // ack without popping frames, so the sink is never invoked.
    fun ackOnlyRead(): Map<String, String> = readOnce(0)

    fun drainAvailableOutput(): Long =
        longField(readOnce(outCap.toInt()), "framesRead")

    fun drainUntilRead(targetTotal: Long) {
        while (true) {
            val kv = readOnce(outCap.toInt())
            if (longField(kv, "totalOutputFramesRead") >= targetTotal) return
            if (longField(kv, "framesRead") == 0L) {
                Thread.sleep(POLL_SLEEP_MS)
            }
            checkDeadline()
        }
    }

    // ── Forward seek at the aligned accepted-frame boundary (pre-EOS) ───────

    // The seek target IS the current accepted frame count, which must be
    // window-aligned, fully dispatched, and fully read. After quiescence
    // and the full boundary drain, [onQuiescentBeforeSeek] runs exactly
    // once (the X3 driver pauses/flushes its AudioTrack sink there, with
    // zero staged residual frames guaranteed by the sink callback
    // contract); only then is the native seek enqueued (no time value
    // crosses JNI) and awaited. The pending OUTPUT ack is deliberately NOT
    // consumed here: the driver prefills the post-seek source ring first
    // and then calls [consumeSeekAckAndReanchor]. Transient seek statuses
    // are waited/retried under a bounded budget; every other status fails
    // closed.
    fun seekAtQuiescentBoundary(onQuiescentBeforeSeek: () -> Unit): Long {
        val target = totalFramesAccepted
        if (target <= 0L || target % mfpm != 0L) throw Failure("seek_boundary_not_aligned")
        if (kotlinFramesAccepted != target) throw Failure("seek_boundary_accounting_mismatch")
        awaitSnapshotDraining("seek_quiescent") {
            longField(it, "totalFramesPushed") == target &&
                longField(it, "sourceAvailableReadFrames") == 0L
        }
        drainUntilRead(target)
        onQuiescentBeforeSeek()
        val seekPtsUs = ceilDiv(target * 1_000_000L, sampleRate.toLong())
        var attempts = 0
        while (true) {
            checkDeadline()
            if (++attempts > MAX_SEEK_TRANSIENT_RETRIES) {
                throw Failure("seek_transient_retry_budget_exhausted")
            }
            val kv = parseNative(
                VanguardNativeBridge.seekAsyncRuntimeQueueRealtimeClock(handle, seekPtsUs)
            )
            when (kv["status"]) {
                "enqueued" -> {
                    if (longField(kv, "targetFrame") != target) {
                        throw Failure("seek_target_frame_mismatch")
                    }
                    val seq = ++nextCommandSeq
                    if (longField(kv, "commandSeq") != seq) {
                        throw Failure("seek_command_seq_mismatch")
                    }
                    awaitCommandProcessed(seq)
                    seekTargetFrame = target
                    return target
                }
                // The boundary drain already emptied the output ring; an
                // undrained ring here means the quiescence claim was false.
                "seek_output_ring_not_drained" ->
                    throw Failure("seek_output_not_drained_after_quiescence")
                // Bounded wait/retry transients.
                "seek_pending_commands",
                "seek_source_ring_not_empty",
                "seek_source_ack_pending",
                "seek_output_ack_pending" -> Thread.sleep(POLL_SLEEP_MS)
                // Everything else (behind_cursor, behind_writer,
                // writer_seek_rejected, seek_rejected_eos,
                // timing_window_unavailable via awaitCommandProcessed, ...)
                // fails closed.
                else -> throw Failure("seek_status_${kv["status"]}")
            }
        }
    }

    // Consumes the pending output-ring seek ack (ack-only read) after the
    // post-seek source prefill: the ack must land at exactly the seek
    // target frame with zero discarded frames.
    fun consumeSeekAckAndReanchor() {
        if (seekTargetFrame < 0L) throw Failure("seek_ack_without_seek")
        val ack = ackOnlyRead()
        if (ack["seekAckConsumed"] != "true" ||
            longField(ack, "newStartFrame") != seekTargetFrame ||
            longField(ack, "discardedFramesOnSeek") != 0L
        ) {
            throw Failure("seek_ack_not_consumed_cleanly")
        }
        seekReanchorOk = true
    }

    // ── Timeline completion + writer-local EOS (zero-fill forbidden) ────────

    // Awaits the exact expected-frame timeline completion, drains the last
    // output, then sets the writer-local EOS. Because the timeline is
    // already complete, the worker has no remaining window to dispatch, so
    // provider zero-fill cannot occur; any observed zero-fill fails closed
    // to keep the identity checksums pure.
    fun completeTimelineAndSetEos() {
        awaitSnapshotDraining("timeline_complete") {
            it["timelineComplete"] == "true" &&
                longField(it, "totalFramesPushed") == expectedFrames
        }
        drainUntilRead(expectedFrames)
        val kv = parseNative(
            VanguardNativeBridge.setAsyncRuntimeQueueRealtimeClockEos(handle)
        )
        if (kv["status"] != "ok" || kv["eos"] != "true") {
            throw Failure("eos_set_failed_${kv["status"]}")
        }
        val snap = awaitSnapshot("post_eos_quiescent") {
            longField(it, "outputAvailableReadFrames") == 0L
        }
        if (longField(snap, "providerFramesZeroFilled") != 0L) {
            throw Failure("zero_fill_leaked_into_identity")
        }
    }

    // ── Snapshot / lifecycle verdicts ───────────────────────────────────────

    fun finalSnapshot(): Map<String, String> = snapshot()

    // Destroy joins the worker (never detaches); second destroy and
    // post-destroy snapshot must both report not_found.
    fun destroyAndVerifyLifecycle(): Pair<Boolean, Boolean> {
        if (handle == 0L) throw Failure("lifecycle_no_handle")
        val h = handle
        val destroyKv = parseStatus(
            VanguardNativeBridge.destroyAsyncRuntimeQueueRealtimeClockSession(h)
        )
        handle = 0L
        val joinOk = destroyKv["status"] == "ok" &&
            destroyKv["workerJoined"] == "true" &&
            destroyKv["workerExited"] == "true" &&
            longField(destroyKv, "joinCount") == 1L
        val againKv = parseStatus(
            VanguardNativeBridge.destroyAsyncRuntimeQueueRealtimeClockSession(h)
        )
        val snapKv = parseStatus(
            VanguardNativeBridge.snapshotAsyncRuntimeQueueRealtimeClock(h)
        )
        val idempotentOk = againKv["status"] == "not_found" &&
            snapKv["status"] == "not_found"
        return joinOk to idempotentOk
    }

    // Finally-safe: destroys the native session (joining its worker) if the
    // run failed before destroyAndVerifyLifecycle() zeroed the handle.
    fun cleanup() {
        if (handle != 0L) {
            try {
                VanguardNativeBridge.destroyAsyncRuntimeQueueRealtimeClockSession(handle)
            } catch (_: Throwable) {}
            handle = 0L
        }
    }

    // ── Internals ───────────────────────────────────────────────────────────

    private fun checkDeadline() {
        if (SystemClock.elapsedRealtime() > deadlineElapsedRealtimeMs) {
            throw Failure("deadline_exceeded")
        }
    }

    private fun ceilDiv(a: Long, b: Long): Long = (a + b - 1) / b

    private fun snapshot(): Map<String, String> {
        checkDeadline()
        val kv = parseNative(
            VanguardNativeBridge.snapshotAsyncRuntimeQueueRealtimeClock(handle)
        )
        if (kv["status"] != "ok") throw Failure("snapshot_status_${kv["status"]}")
        snapCommandsEnqueued = longField(kv, "commandsEnqueued")
        snapCommandsProcessed = longField(kv, "commandsProcessed")
        snapCommandErrors = longField(kv, "commandErrors")
        snapLastCommandSeq = longField(kv, "lastCommandSeq")
        snapQueueDepth = longField(kv, "queueDepth")
        snapDispatchCount = longField(kv, "dispatchCount")
        snapOkCount = longField(kv, "okCount")
        snapSilenceCount = longField(kv, "silenceCount")
        snapBackpressureCount = longField(kv, "backpressureCount")
        snapSchedulerErrorCount = longField(kv, "schedulerErrorCount")
        snapWorkerDispatchAnomalies = longField(kv, "workerDispatchAnomalies")
        snapNonMonotonicTimeAnomalies = longField(kv, "nonMonotonicTimeAnomalies")
        snapWorkerNoFramesDueWaits = longField(kv, "workerNoFramesDueWaits")
        snapWorkerStarvedWaits = longField(kv, "workerStarvedWaits")
        snapProviderUnderrunEvents = longField(kv, "providerUnderrunEvents")
        snapProviderFramesZeroFilled = longField(kv, "providerFramesZeroFilled")
        snapProviderForwardSkipFrames = longField(kv, "providerForwardSkipFrames")
        snapProviderRewindRejects = longField(kv, "providerRewindRejects")
        snapTotalFramesRendered = longField(kv, "totalFramesRendered")
        snapTotalFramesPushed = longField(kv, "totalFramesPushed")
        snapOwnerDispatchCalls = longField(kv, "ownerDispatchCalls")
        snapWorkerThreadDistinct = kv["workerThreadDistinct"] == "true"
        snapTerminal = kv["terminal"] == "true"
        snapNoCallerSuppliedNativeTime = kv["noCallerSuppliedNativeTime"] == "true"
        snapWorkerOwnsMonotonicClock = kv["workerOwnsMonotonicClock"] == "true"
        snapNativeTimingF0 = longField(kv, "nativeTimingF0")
        snapNativeTimingF1 = longField(kv, "nativeTimingF1")
        snapNativeRealtimeElapsedMs = longField(kv, "nativeRealtimeElapsedMs")
        snapRealtimeElapsedOk = kv["realtimeElapsedOk"] == "true"
        snapMaxRenderCursorBacklogUs = longField(kv, "maxRenderCursorBacklogUs")
        snapRealtimeBacklogBoundOk = kv["realtimeBacklogBoundOk"] == "true"
        snapBacklogSampleCount = longField(kv, "backlogSampleCount")
        snapClockDriftSampleCount = longField(kv, "clockDriftSampleCount")
        snapProofBoundary = kv["proofBoundary"] ?: ""
        return kv
    }

    private fun awaitSnapshot(
        what: String,
        pred: (Map<String, String>) -> Boolean,
    ): Map<String, String> {
        while (true) {
            val kv = snapshot()
            if (pred(kv)) return kv
            if (SystemClock.elapsedRealtime() > deadlineElapsedRealtimeMs) {
                throw Failure("await_timeout_$what")
            }
            Thread.sleep(POLL_SLEEP_MS)
        }
    }

    // Await variant that drains the output ring between polls so the
    // realtime worker can never wedge on a full output ring while we wait
    // for it to push a target frame count.
    private fun awaitSnapshotDraining(
        what: String,
        pred: (Map<String, String>) -> Boolean,
    ): Map<String, String> {
        while (true) {
            val kv = snapshot()
            if (pred(kv)) return kv
            if (SystemClock.elapsedRealtime() > deadlineElapsedRealtimeMs) {
                throw Failure("await_timeout_$what")
            }
            if (drainAvailableOutput() == 0L) {
                Thread.sleep(POLL_SLEEP_MS)
            }
        }
    }

    private fun awaitCommandProcessed(seq: Long): Map<String, String> {
        val kv = awaitSnapshot("command_$seq") {
            longField(it, "commandsProcessed") >= seq
        }
        if (longField(kv, "lastCommandSeq") != seq ||
            kv["lastCommandResult"] != "ok" ||
            longField(kv, "commandErrors") != 0L
        ) {
            throw Failure("command_${seq}_failed_${kv["lastCommandResult"]}")
        }
        return kv
    }

    // Unwritten frames move to byte offset 0 so retries always read from
    // the buffer start (native ingest reads offset 0 only).
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
