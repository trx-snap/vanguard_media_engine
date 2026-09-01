package com.connects.vanguard_media_engine.diagnostics

import android.os.SystemClock
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicReference

// ── AndroidAsyncRuntimeQueueRealDecoderNativeSession (P4 True-DAG sub-slice X1) ─
//
// Owner-thread wrapper around the verified async runtime queue scheduler JNI
// seam (android_phase4_async_runtime_queue_scheduler_session_jni.cpp), used
// by the real MediaExtractor/MediaCodec decoder driver. Unlike the H2
// step-driven wrapper, the NATIVE WORKER thread inside the session is the
// sole caller of every AudioClock mutator, every
// ClockedAudioTransportCoordinator control/dispatch method, and the output
// ring's producer role; this class only ingests decoded PCM through the
// node-owned source-ring writer, enqueues start/pause/resume/seek commands,
// reads the output ring, and observes the worker through the
// mutex-published snapshot mirror.
//
// Owner-thread affinity: every non-destroy async entry point is owner-only
// in native; this object must be created AND driven on the single Kotlin
// worker thread that calls create(). The one extra short-lived thread here
// is the deliberate foreign-thread probe that native must reject with
// wrong_owner_thread.
//
// Frame axis and ticks: the native frame axis is the ACCEPTED FRAME COUNT.
// The worker derives its own dispatch ticks; the owner supplies ticks only
// on pause/resume/seek commands, computed on the same accepted-frame axis
//   ptsUs = ceil(F * 1e6 / sampleRate)
//   tick  = anchorSysNs + (ptsUs - anchorPtsUs) * 1000
// mirrored against the worker's published anchors and clamped to the
// published workerLastTickNs at quiescent points, so the worker's
// max(cmd.b, lastTickNs) clamp never diverges the two mirrors.
//
// Seek policy (fail-closed statuses vs bounded transients): the async seek
// runs only at a window-aligned, fully-drained accepted-frame boundary
// with no EOS published. seek_pending_commands, seek_source_ring_not_empty,
// seek_output_ring_not_drained, seek_source_ack_pending and
// seek_output_ack_pending are bounded drain/wait/retry transients;
// seek_target_behind_cursor, seek_target_behind_writer, invalid_args,
// writer_seek_rejected and every other token fail closed.
//
// Honest non-claims: no AudioTrack/AAudio/OpenSL/Oboe, no audible output,
// no realtime claim, no product/editor/app wiring, no streaming/cache, no
// iOS. Zero-fill is never allowed into the identity checksums: the driver
// completes the exact expected timeline before setting the writer-local
// EOS, and this wrapper fails closed if any provider zero-fill is observed.
class AndroidAsyncRuntimeQueueRealDecoderNativeSession(
    private val deadlineElapsedRealtimeMs: Long,
) {
    class Failure(val reason: String) : Exception(reason)

    data class IngestReply(
        val framesAccepted: Long,
        val writerStatus: String,
        val writerBackpressureRejects: Long,
    )

    companion object {
        // Verbatim native TU constant; the snapshot must echo it so a
        // physical run proves the exact verified async session TU executed.
        const val NATIVE_PROOF_BOUNDARY =
            "diagnostic_async_runtime_queue_scheduler_integration_proof_only_worker_owned_clock_and_coordinator_command_serialized_source_ring_spsc_output_ring_spsc_caller_derived_systime_ticks_only_steady_clock_pacing_only_no_native_media_timebase_no_audible_output_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_product_editor_app_wiring_no_streaming_cache_no_ios_no_export_route_changes"

        private const val ANCHOR_SYS_TIME_NS = 1_000_000_000L
        // Matches the native per-call ingest clamp
        // (AudioDecoderRingWriter kMaxWriteFrames).
        private const val NATIVE_MAX_INGEST_FRAMES = 8_192L
        private const val POLL_SLEEP_MS = 2L
        private const val MAX_INGEST_STALL_RETRIES = 4_096
        private const val MAX_SEEK_TRANSIENT_RETRIES = 64
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
    var expectedFrames = 0L
        private set

    private var readBuf: ByteBuffer? = null

    // Owner mirror of the worker's deterministic tick anchor (re-based by
    // the worker's own start/pause/resume/seek arithmetic, mirrored here).
    private var anchorPtsUs = 0L
    private var anchorSysNs = ANCHOR_SYS_TIME_NS
    private var lastTickNs = Long.MIN_VALUE
    private var pauseTickNs = 0L

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
    var outputBackpressureVerified = false
        private set
    var sourcePartialWriteObserved = false
        private set
    var sourceRingFullObserved = false
        private set
    var pausedFillActive = false
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
    var snapWorkerZeroFillProbeWindows = -1L
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
    var snapProofBoundary = ""
        private set
    var lastStatus = ""
        private set

    val isCreated: Boolean get() = handle != 0L

    // ── Lifecycle ───────────────────────────────────────────────────────────

    // Creates the async native session (which starts its worker thread) and
    // proves boot-time async ownership: worker started, worker thread id
    // distinct from this owner thread, zero owner dispatch calls.
    fun create(
        sampleRateIn: Int,
        channelCountIn: Int,
        expectedFramesIn: Long,
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
        expectedFrames = expectedFramesIn
        if (outCap % mfpm != 0L) throw Failure("invalid_config_output_ring_alignment")
        if (expectedFrames <= 0L || expectedFrames % mfpm != 0L) {
            throw Failure("invalid_config_expected_frames_alignment")
        }
        // The no-drain output-backpressure lane must be fully absorbable by
        // the source ring while the output ring fills.
        if (srcCap < outCap + 2L * mfpm) {
            throw Failure("invalid_config_backpressure_geometry")
        }
        handle = VanguardNativeBridge.createAsyncRuntimeQueueSchedulerSession(
            sampleRateIn, channelCountIn, expectedFramesIn,
            sourceRingCapacityFrames, outputRingCapacityFrames, maxFramesPerMix,
        )
        if (handle == 0L) throw Failure("native_session_create_failed")
        readBuf = ByteBuffer.allocateDirect(outputRingCapacityFrames * bytesPerFrame)
            .order(ByteOrder.LITTLE_ENDIAN)
        val snapBoot = awaitSnapshot("worker_started") { it["workerStarted"] == "true" }
        if (snapBoot["workerThreadDistinct"] != "true") {
            throw Failure("worker_thread_not_distinct")
        }
        if (longField(snapBoot, "ownerDispatchCalls") != 0L) {
            throw Failure("owner_dispatch_calls_nonzero_at_boot")
        }
        workerOwnershipAtBootOk = true
    }

    // Enqueues the start command (frame 0), waits for the worker to execute
    // it, and consumes the output-ring start ack (frame 0, zero discards).
    fun startAndConsumeAck() {
        anchorPtsUs = 0L
        anchorSysNs = ANCHOR_SYS_TIME_NS
        lastTickNs = anchorSysNs
        val kv = parseNative(
            VanguardNativeBridge.startAsyncRuntimeQueueScheduler(
                handle, 0L, ANCHOR_SYS_TIME_NS,
            )
        )
        if (kv["status"] != "enqueued") throw Failure("start_not_enqueued_${kv["status"]}")
        val seq = ++nextCommandSeq
        if (longField(kv, "commandSeq") != seq) throw Failure("start_command_seq_mismatch")
        val snap = awaitCommandProcessed(seq)
        if (snap["started"] != "true") throw Failure("start_state_mismatch")
        val ack = readOnce(0)
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
            VanguardNativeBridge.ingestAsyncRuntimeQueueSchedulerPcm16(handle, pcm, frames)
        )
        if (kv["status"] != "ok") throw Failure("ingest_status_${kv["status"]}")
        val accepted = longField(kv, "framesAccepted")
        val writerStatus = kv["writerStatus"] ?: ""
        when (writerStatus) {
            "ok" -> {}
            "partial_write" -> sourcePartialWriteObserved = true
            "ring_full" -> {}
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
        return IngestReply(
            accepted, writerStatus, writerBackpressureRejects,
        )
    }

    // Lossless ingest of [frames] frames at byte offset 0 of [pcm]: the
    // async worker drains the source ring on its own thread, so a stalled
    // (zero-accepted) call waits and retries the SAME compacted logical
    // window. The first stall before the output-backpressure lane has been
    // verified triggers that verification (the worker is provably wedged at
    // a full output ring at that point); afterwards stalls drain output to
    // un-wedge the worker. No decoded frame is ever dropped here.
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
            if (!outputBackpressureVerified) {
                verifyOutputBackpressureAndEnableDrains()
            } else {
                drainAvailableOutput()
                Thread.sleep(POLL_SLEEP_MS)
            }
        }
    }

    // ── Output backpressure lane (no drains until verified) ─────────────────

    // With every read withheld so far, the worker must fill the output ring
    // to exactly its capacity and record coordinator backpressure without
    // ever overrunning the SPSC ring. Verifying enables normal drains.
    fun verifyOutputBackpressureAndEnableDrains() {
        if (outputBackpressureVerified) return
        val snap = awaitSnapshot("output_backpressure") {
            longField(it, "backpressureCount") >= 1L &&
                longField(it, "totalFramesPushed") >= outCap
        }
        if (longField(snap, "totalFramesPushed") != outCap) {
            throw Failure("output_backpressure_overrun")
        }
        outputBackpressureVerified = true
        drainAvailableOutput()
    }

    // ── Output reads (owner is the output-ring consumer) ────────────────────

    private fun readOnce(maxFrames: Int): Map<String, String> {
        checkDeadline()
        val buf = readBuf ?: throw Failure("read_before_create")
        val kv = parseNative(
            VanguardNativeBridge.readAsyncRuntimeQueueSchedulerOutputPcm16(
                handle, buf, maxFrames,
            )
        )
        if (kv["status"] != "ok") throw Failure("read_status_${kv["status"]}")
        totalOutputFramesRead = longField(kv, "totalOutputFramesRead")
        nativeOutputReadChecksumHex = kv["nativeOutputReadChecksumHex"] ?: ""
        return kv
    }

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

    // ── Pause / paused source-ring fill / resume ────────────────────────────

    // Awaits the worker at a dispatch-boundary quiescent point (every full
    // accepted window dispatched, sub-window residual starved), drains the
    // output ring, then enqueues pause with an accepted-frame-axis tick
    // clamped to the published workerLastTickNs so the owner anchor mirror
    // stays exact through the worker's own max(cmd.b, lastTickNs) clamp.
    fun pauseAtQuiescentBoundary() {
        if (pausedFillActive) throw Failure("pause_already_active")
        val dispatchable = (totalFramesAccepted / mfpm) * mfpm
        awaitSnapshotDraining("pause_quiescent") {
            longField(it, "totalFramesPushed") == dispatchable
        }
        drainUntilRead(dispatchable)
        val snap = snapshot()
        val tick = maxOf(
            tickForFrame(dispatchable),
            longField(snap, "workerLastTickNs"),
            lastTickNs,
        )
        val kv = parseNative(
            VanguardNativeBridge.pauseAsyncRuntimeQueueScheduler(handle, tick)
        )
        if (kv["status"] != "enqueued") throw Failure("pause_not_enqueued_${kv["status"]}")
        val seq = ++nextCommandSeq
        if (longField(kv, "commandSeq") != seq) throw Failure("pause_command_seq_mismatch")
        val snapPaused = awaitCommandProcessed(seq)
        if (snapPaused["paused"] != "true") throw Failure("pause_state_mismatch")
        // Mirror the worker's freeze re-anchor exactly.
        anchorPtsUs += (tick - anchorSysNs) / 1000L
        anchorSysNs = tick
        lastTickNs = tick
        pauseTickNs = tick
        pausedFillActive = true
    }

    // Paused-fill ingest: the worker cannot drain, so the writer must reach
    // ring_full deterministically. Returns the count of not-yet-ingested
    // frames (compacted to byte offset 0 of [pcm]) once ring_full with zero
    // accepted frames was observed; returns 0 when the whole chunk fit.
    fun ingestUntilRingFull(pcm: ByteBuffer, frames: Int): Int {
        if (!pausedFillActive) throw Failure("paused_fill_not_active")
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
                throw Failure("paused_fill_unexpected_writer_status_${r.writerStatus}")
            }
            if (r.writerBackpressureRejects < 1L) {
                throw Failure("paused_fill_reject_not_counted")
            }
            sourceRingFullObserved = true
            return remaining
        }
        return 0
    }

    // Resume with the exact pause tick: the worker's clamp makes the
    // effective tick equal, so the anchor mirrors stay in lockstep and the
    // rejected window (still held, compacted) is retried losslessly by the
    // caller through the normal ingest path.
    fun resumeAfterSourceBackpressure() {
        if (!pausedFillActive) throw Failure("resume_without_pause")
        if (!sourceRingFullObserved) throw Failure("resume_before_ring_full_observed")
        val kv = parseNative(
            VanguardNativeBridge.resumeAsyncRuntimeQueueScheduler(handle, pauseTickNs)
        )
        if (kv["status"] != "enqueued") throw Failure("resume_not_enqueued_${kv["status"]}")
        val seq = ++nextCommandSeq
        if (longField(kv, "commandSeq") != seq) throw Failure("resume_command_seq_mismatch")
        val snapResumed = awaitCommandProcessed(seq)
        if (snapResumed["paused"] != "false") throw Failure("resume_state_mismatch")
        pausedFillActive = false
    }

    // ── Forward seek at the aligned accepted-frame boundary (pre-EOS) ───────

    // The seek target IS the current accepted frame count, which must be
    // window-aligned, fully dispatched, and fully read. Transient seek
    // statuses are drained/waited/retried under a bounded budget; every
    // other status fails closed. Asserts targetFrame == acceptedFrame,
    // consumes the output ack at exactly that frame with zero discards, and
    // re-anchors the owner tick mirror.
    fun seekAtAcceptedAlignedBoundary(): Long {
        if (pausedFillActive) throw Failure("seek_during_paused_fill")
        val target = totalFramesAccepted
        if (target <= 0L || target % mfpm != 0L) throw Failure("seek_boundary_not_aligned")
        if (kotlinFramesAccepted != target) throw Failure("seek_boundary_accounting_mismatch")
        awaitSnapshotDraining("seek_quiescent") {
            longField(it, "totalFramesPushed") == target &&
                longField(it, "sourceAvailableReadFrames") == 0L
        }
        drainUntilRead(target)
        val seekPtsUs = ceilDiv(target * 1_000_000L, sampleRate.toLong())
        var attempts = 0
        while (true) {
            checkDeadline()
            if (++attempts > MAX_SEEK_TRANSIENT_RETRIES) {
                throw Failure("seek_transient_retry_budget_exhausted")
            }
            val snap = snapshot()
            val tick = maxOf(
                tickForFrame(target),
                longField(snap, "workerLastTickNs"),
                lastTickNs,
            )
            val kv = parseNative(
                VanguardNativeBridge.seekAsyncRuntimeQueueScheduler(handle, seekPtsUs, tick)
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
                    val ack = readOnce(0)
                    if (ack["seekAckConsumed"] != "true" ||
                        longField(ack, "newStartFrame") != target ||
                        longField(ack, "discardedFramesOnSeek") != 0L
                    ) {
                        throw Failure("seek_ack_not_consumed_cleanly")
                    }
                    anchorPtsUs = seekPtsUs
                    anchorSysNs = tick
                    lastTickNs = tick
                    seekTargetFrame = target
                    seekReanchorOk = true
                    return target
                }
                // Bounded drain/wait/retry transients.
                "seek_output_ring_not_drained" -> drainAvailableOutput()
                "seek_pending_commands",
                "seek_source_ring_not_empty",
                "seek_source_ack_pending",
                "seek_output_ack_pending" -> Thread.sleep(POLL_SLEEP_MS)
                // Everything else (behind_cursor, behind_writer, invalid_args,
                // writer_seek_rejected, seek_rejected_eos, ...) fails closed.
                else -> throw Failure("seek_status_${kv["status"]}")
            }
        }
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
            VanguardNativeBridge.setAsyncRuntimeQueueSchedulerEos(handle)
        )
        if (kv["status"] != "ok" || kv["eos"] != "true") {
            throw Failure("eos_set_failed_${kv["status"]}")
        }
        val snap = awaitSnapshot("post_eos_quiescent") {
            longField(it, "outputAvailableReadFrames") == 0L
        }
        if (longField(snap, "providerFramesZeroFilled") != 0L ||
            longField(snap, "workerZeroFillProbeWindows") != 0L
        ) {
            throw Failure("zero_fill_leaked_into_identity")
        }
    }

    // ── Snapshot / probes / lifecycle verdicts ──────────────────────────────

    fun finalSnapshot(): Map<String, String> = snapshot()

    // Deliberate foreign-thread snapshot that native must fail closed with
    // wrong_owner_thread; call only at a quiescent point.
    fun probeForeignThreadRejected(): Boolean {
        val status = AtomicReference("")
        val probeThread = Thread {
            status.set(
                parseStatus(
                    VanguardNativeBridge.snapshotAsyncRuntimeQueueScheduler(handle)
                )["status"] ?: ""
            )
        }
        probeThread.start()
        probeThread.join(FOREIGN_PROBE_JOIN_MS)
        return status.get() == "wrong_owner_thread"
    }

    // Destroy joins the worker (never detaches); second destroy and
    // post-destroy snapshot must both report not_found.
    fun destroyAndVerifyLifecycle(): Pair<Boolean, Boolean> {
        if (handle == 0L) throw Failure("lifecycle_no_handle")
        val h = handle
        val destroyKv = parseStatus(
            VanguardNativeBridge.destroyAsyncRuntimeQueueSchedulerSession(h)
        )
        handle = 0L
        val joinOk = destroyKv["status"] == "ok" &&
            destroyKv["workerJoined"] == "true" &&
            destroyKv["workerExited"] == "true" &&
            longField(destroyKv, "joinCount") == 1L
        val againKv = parseStatus(
            VanguardNativeBridge.destroyAsyncRuntimeQueueSchedulerSession(h)
        )
        val snapKv = parseStatus(
            VanguardNativeBridge.snapshotAsyncRuntimeQueueScheduler(h)
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
                VanguardNativeBridge.destroyAsyncRuntimeQueueSchedulerSession(handle)
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

    // Accepted-frame-axis tick with the same clamp shape as the worker.
    private fun tickForFrame(frame: Long): Long {
        val ptsUs = ceilDiv(frame * 1_000_000L, sampleRate.toLong())
        var deltaUs = ptsUs - anchorPtsUs
        if (deltaUs < 0L) deltaUs = 0L
        val tick = anchorSysNs + deltaUs * 1_000L
        return if (tick < lastTickNs) lastTickNs else tick
    }

    private fun snapshot(): Map<String, String> {
        checkDeadline()
        val kv = parseNative(
            VanguardNativeBridge.snapshotAsyncRuntimeQueueScheduler(handle)
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
        snapWorkerZeroFillProbeWindows = longField(kv, "workerZeroFillProbeWindows")
        snapProviderUnderrunEvents = longField(kv, "providerUnderrunEvents")
        snapProviderFramesZeroFilled = longField(kv, "providerFramesZeroFilled")
        snapProviderForwardSkipFrames = longField(kv, "providerForwardSkipFrames")
        snapProviderRewindRejects = longField(kv, "providerRewindRejects")
        snapTotalFramesRendered = longField(kv, "totalFramesRendered")
        snapTotalFramesPushed = longField(kv, "totalFramesPushed")
        snapOwnerDispatchCalls = longField(kv, "ownerDispatchCalls")
        snapWorkerThreadDistinct = kv["workerThreadDistinct"] == "true"
        snapTerminal = kv["terminal"] == "true"
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

    // Await variant that drains the output ring between polls so the worker
    // can never wedge on a full output ring while we wait for it to push a
    // target frame count. Requires drains to be enabled (post-verify).
    private fun awaitSnapshotDraining(
        what: String,
        pred: (Map<String, String>) -> Boolean,
    ): Map<String, String> {
        if (!outputBackpressureVerified) {
            throw Failure("draining_await_before_backpressure_verify_$what")
        }
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
