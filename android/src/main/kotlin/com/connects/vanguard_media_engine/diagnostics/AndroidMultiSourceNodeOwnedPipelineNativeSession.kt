package com.connects.vanguard_media_engine.diagnostics

import android.os.SystemClock
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicReference

// ── AndroidMultiSourceNodeOwnedPipelineNativeSession (P4-AUDIO-MULTI-SOURCE-NODE-OWNED-PIPELINE) ─
//
// Owner-thread wrapper around the two-source NODE-OWNED closed-loop native
// audio graph pipeline JNI seam
// (android_phase4_multi_source_node_owned_pipeline_session_jni.cpp), used
// by [AndroidMultiSourceNodeOwnedPipelineDriver]. This class owns the
// native handle lifecycle, JNI status parsing, the deadline checks, the
// shared accepted-frame-axis caller-derived tick math, the start ack, the
// joint step/drain drive, the lockstep two-track ingest with its make-room
// state machine, the joint EOS tail flush (one JNI call sets BOTH writers
// EOS), the both-track accepted-frame-axis seek, snapshot metric folding
// (including the node-owned/auto-discovery evidence), the foreign-thread
// owner probe, and idempotent native cleanup. It never touches
// MediaExtractor/MediaCodec — the driver hands it already-copied direct
// ByteBuffers whose codec output buffers were released beforehand.
//
// Unlike the external-provider-map multi-source session, the native session
// owns NO source ring/writer/provider members: each
// DecodedAudioPcmSourceNode (6-arg constructor) owns its own transport
// triple and the GraphAudioScheduler auto-discovers both providers from
// graph topology alone. create() therefore passes expectedFrameCount (each
// node's isActiveAt timeline-window bound) and fails closed unless the
// snapshot proves routedSourceCount == 2 with the exact node ids and
// nodeOwnsRingTrack0/1 == true.
//
// The native frame axis here is the SHARED ACCEPTED FRAME COUNT, not media
// PTS: every tick derives from the native-reported nextDispatchFrame
//   F = nextDispatchFrame + maxFramesPerMix
//   ptsUs = ceil(F * 1_000_000 / sampleRate)
//   sysTimeNs = anchorSysNs + (ptsUs - anchorPtsUs) * 1000
// with the anchor re-based at start() and at the one joint
// accepted-frame-boundary seek. The local dispatch cursor is cross-checked
// against the native cursor after every step; the tick guard allows
// equality and fails only on a decrease.
//
// Lockstep invariant: for every real (track 0) frame chunk the driver hands
// over, exactly the same frame count of synthetic (track 1) PCM is ingested;
// abs(accepted0 - accepted1) never exceeds 0 at a stable chunk boundary.
// When neither ring can accept, the make-room machine dispatches drained
// joint pair windows and retries under a bounded budget
// (ring_full_without_dispatchable_pair /
// multi_source_makeroom_budget_exhausted on exhaustion).
//
// Honest non-claims: no threads spawned except the single short-lived
// foreign-thread probe that must be rejected by native; no
// AudioTrack/AAudio/OpenSL/Oboe, no sink-clocked transport, no audible or
// realtime playback, no export or pass-2 reroute, no streaming/cache, no
// iOS, no product/editor UI. Full overlap only: no independent EOS, no
// ragged tail, no post-EOS intentional silence. Consumer drain is the ONLY
// output read path in this slice.
class AndroidMultiSourceNodeOwnedPipelineNativeSession(
    private val deadlineElapsedRealtimeMs: Long,
) {
    class Failure(val reason: String) : Exception(reason)

    data class IngestReply(
        val framesAccepted: Long,
        val writerStatus: String,
        val writerAvailableToWrite: Long,
    )

    companion object {
        const val SOURCE0_NODE_ID = "multi_source_node_owned_src0"
        const val SOURCE1_NODE_ID = "multi_source_node_owned_src1"

        private const val ANCHOR_SYS_TIME_NS = 1_000_000_000L
        // Matches the native per-call ingest clamp (AudioDecoderRingWriter
        // kMaxWriteFrames).
        private const val NATIVE_MAX_INGEST_FRAMES = 8_192L
        private const val MAX_CHUNK_RETRIES = 128
        private const val MAX_STEP_RETRIES = 8
        private const val MAX_DRAIN_ITERATIONS = 256
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

    // Caller-derived tick anchor on the shared accepted-frame axis.
    private var anchorPtsUs = 0L
    private var anchorSysNs = ANCHOR_SYS_TIME_NS
    private var lastTickNs = Long.MIN_VALUE

    // Native-reported cursors/counters, refreshed from every reply; the
    // local cursor mirrors dispatched frames and is cross-checked after
    // every step.
    var nativeNextDispatchFrame = 0L
        private set
    private var localCursorFrame = 0L
    var sourceAvailableReadFramesTrack0 = 0L
        private set
    var sourceAvailableReadFramesTrack1 = 0L
        private set
    var outputAvailableReadFrames = 0L
        private set

    var totalFramesAcceptedTrack0 = 0L
        private set
    var totalFramesAcceptedTrack1 = 0L
        private set
    var totalOutputFramesDrained = 0L
        private set
    var nativeAcceptedChecksumHexTrack0 = ""
        private set
    var nativeAcceptedChecksumHexTrack1 = ""
        private set
    var nativeOutputDrainChecksumHex = ""
        private set
    var dispatchCount = 0L
        private set
    var lastStatus = ""
        private set

    // Joint-gate/no-fault latches.
    var jointDeferralObserved = false
        private set
    var ringPushShortfallSeen = false
        private set

    // Folded from the most recent snapshot.
    var providerUnderrunEventsTrack0 = 0L
        private set
    var providerUnderrunEventsTrack1 = 0L
        private set
    var providerFramesZeroFilledTrack0 = 0L
        private set
    var providerFramesZeroFilledTrack1 = 0L
        private set
    var providerForwardSkipFramesTrack0 = 0L
        private set
    var providerForwardSkipFramesTrack1 = 0L
        private set
    var providerRewindRejectsTrack0 = 0L
        private set
    var providerRewindRejectsTrack1 = 0L
        private set
    var coordinatorSilenceCount = 0L
        private set
    var snapshotTerminal = false
        private set
    var snapshotAwaitingSeekAck = false
        private set

    // Node-owned/auto-discovery evidence, folded from the most recent
    // snapshot.
    var routedSourceCount = 0L
        private set
    var routedSourceId0 = ""
        private set
    var routedSourceId1 = ""
        private set
    var nodeOwnsRingTrack0 = false
        private set
    var nodeOwnsRingTrack1 = false
        private set

    // Fixed-at-construction capacity baseline for the zero native
    // steady-state allocation lane (scheduler scratch + all three rings).
    private var schedCapBefore = -1L
    private var schedTracksBefore = -1L
    private var src0StorageBefore = -1L
    private var src1StorageBefore = -1L
    private var outStorageBefore = -1L

    val isCreated: Boolean get() = handle != 0L

    // ── Lifecycle ───────────────────────────────────────────────────────────

    fun create(
        sampleRateIn: Int,
        channelCountIn: Int,
        expectedFrameCount: Int,
        sourceRingCapacityFrames: Int,
        outputRingCapacityFrames: Int,
        maxFramesPerMix: Int,
    ) {
        if (handle != 0L) throw Failure("native_session_already_created")
        if (maxFramesPerMix <= 0) throw Failure("invalid_config_max_frames_per_mix")
        if (expectedFrameCount <= 0) throw Failure("invalid_config_expected_frame_count")
        sampleRate = sampleRateIn
        channelCount = channelCountIn
        bytesPerFrame = 2 * channelCountIn
        srcCap = sourceRingCapacityFrames.toLong()
        outCap = outputRingCapacityFrames.toLong()
        mfpm = maxFramesPerMix.toLong()
        handle = VanguardNativeBridge.createMultiSourceNodeOwnedAudioGraphPipelineSmokeSession(
            sampleRateIn, channelCountIn, expectedFrameCount,
            sourceRingCapacityFrames, outputRingCapacityFrames, maxFramesPerMix,
        )
        if (handle == 0L) throw Failure("native_session_create_failed")
        val snap = snapshot()
        schedCapBefore = longField(snap, "schedulerTrackScratchCapacitySamples")
        schedTracksBefore = longField(snap, "schedulerTrackScratchCapacityTracks")
        src0StorageBefore = longField(snap, "sourceRingStorageCapacitySamplesTrack0")
        src1StorageBefore = longField(snap, "sourceRingStorageCapacitySamplesTrack1")
        outStorageBefore = longField(snap, "outputRingStorageCapacitySamples")
        if (schedCapBefore <= 0L || src0StorageBefore <= 0L ||
            src1StorageBefore <= 0L || outStorageBefore <= 0L
        ) {
            throw Failure("capacity_baseline_invalid")
        }
        // Node-owned/auto-discovery fail-closed verification: exactly two
        // routed node-owned tracks in src0, src1 order, both owning rings.
        if (routedSourceCount != 2L) throw Failure("routed_source_count_not_two")
        if (routedSourceId0 != SOURCE0_NODE_ID || routedSourceId1 != SOURCE1_NODE_ID) {
            throw Failure("routed_source_id_mismatch")
        }
        if (!nodeOwnsRingTrack0 || !nodeOwnsRingTrack1) {
            throw Failure("node_does_not_own_ring")
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
            VanguardNativeBridge.startMultiSourceNodeOwnedAudioGraphPipeline(handle, 0L, anchorSysNs)
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
            VanguardNativeBridge.destroyMultiSourceNodeOwnedAudioGraphPipelineSmokeSession(h)
        )
        handle = 0L
        val againKv = parseStatus(
            VanguardNativeBridge.destroyMultiSourceNodeOwnedAudioGraphPipelineSmokeSession(h)
        )
        val snapKv = parseStatus(VanguardNativeBridge.snapshotMultiSourceNodeOwnedAudioGraphPipeline(h))
        return destroyKv["status"] == "ok" &&
            againKv["status"] == "not_found" &&
            snapKv["status"] == "not_found"
    }

    // Finally-safe: destroys the native session if the run failed before
    // destroyAndVerifyLifecycle() zeroed the handle.
    fun cleanup() {
        if (handle != 0L) {
            try {
                VanguardNativeBridge.destroyMultiSourceNodeOwnedAudioGraphPipelineSmokeSession(handle)
            } catch (_: Throwable) {}
            handle = 0L
        }
    }

    // ── Lockstep two-track ingest + make-room state machine ─────────────────

    // One ingest call of [frames] frames held at byte offset 0 of [pcm] for
    // [track] through that track's node-owned ring writer; folds the
    // native-reported per-track totals/checksums.
    fun ingestTrackOnce(track: Int, pcm: ByteBuffer, frames: Int): IngestReply {
        checkDeadline()
        if (track != 0 && track != 1) throw Failure("ingest_invalid_track_index")
        if (frames <= 0) throw Failure("ingest_invalid_frame_count")
        if (frames.toLong() > NATIVE_MAX_INGEST_FRAMES) {
            throw Failure("ingest_chunk_exceeds_native_clamp")
        }
        if (frames.toLong() * bytesPerFrame > pcm.capacity()) {
            throw Failure("ingest_chunk_exceeds_buffer")
        }
        val kv = parseNative(
            VanguardNativeBridge.ingestMultiSourceNodeOwnedAudioGraphPipelinePcm16(
                handle, track, pcm, frames,
            )
        )
        if (kv["status"] != "ok") throw Failure("ingest_status_${kv["status"]}")
        val accepted = longField(kv, "framesAccepted")
        val writerStatus = kv["writerStatus"] ?: ""
        when (writerStatus) {
            "ok", "partial_write", "ring_full" -> {}
            else -> throw Failure("unexpected_writer_status_$writerStatus")
        }
        totalFramesAcceptedTrack0 = longField(kv, "totalFramesAcceptedTrack0")
        totalFramesAcceptedTrack1 = longField(kv, "totalFramesAcceptedTrack1")
        sourceAvailableReadFramesTrack0 = longField(kv, "sourceAvailableReadFramesTrack0")
        sourceAvailableReadFramesTrack1 = longField(kv, "sourceAvailableReadFramesTrack1")
        val checksumHex = kv["nativeAcceptedChecksumHex"] ?: ""
        if (track == 0) nativeAcceptedChecksumHexTrack0 = checksumHex
        else nativeAcceptedChecksumHexTrack1 = checksumHex
        return IngestReply(
            accepted, writerStatus, longField(kv, "writerAvailableToWrite"),
        )
    }

    // Lossless lockstep ingest of one chunk: [frames] real frames at byte
    // offset 0 of [pcm0] and exactly [frames] synthetic frames at byte
    // offset 0 of [pcm1]. Track 1 always catches track 0 up first, so the
    // in-flight divergence never exceeds the current chunk and returns to
    // exactly 0 at this stable boundary. When neither track can make
    // progress (both rings full), a drained joint pair window is dispatched
    // to make room; bounded retries fail closed. Chunks must not exceed
    // maxFramesPerMix so a single dispatched pair window always frees
    // enough space for the remainder.
    fun ingestLockstepChunk(pcm0: ByteBuffer, pcm1: ByteBuffer, frames: Int) {
        if (frames <= 0 || frames.toLong() > mfpm) throw Failure("lockstep_chunk_size_invalid")
        var remaining0 = frames
        var remaining1 = frames
        var retries = 0
        while (remaining0 > 0 || remaining1 > 0) {
            checkDeadline()
            if (++retries > MAX_CHUNK_RETRIES) {
                throw Failure("multi_source_makeroom_budget_exhausted")
            }
            var progressed = false
            if (remaining1 > remaining0) {
                // Track 1 lags the shared axis by the in-flight amount:
                // service the lagging track first.
                val want = remaining1 - remaining0
                val r = ingestTrackOnce(1, pcm1, want)
                if (r.framesAccepted > 0L) {
                    compactRemainder(pcm1, r.framesAccepted.toInt(), remaining1)
                    remaining1 -= r.framesAccepted.toInt()
                    progressed = true
                }
            } else if (remaining0 > 0) {
                val r = ingestTrackOnce(0, pcm0, remaining0)
                if (r.framesAccepted > 0L) {
                    compactRemainder(pcm0, r.framesAccepted.toInt(), remaining0)
                    remaining0 -= r.framesAccepted.toInt()
                    progressed = true
                }
            }
            if (!progressed && (remaining0 > 0 || remaining1 > 0)) {
                // Neither ring accepted anything: make room by dispatching
                // (and draining) one joint pair window.
                if (minOf(sourceAvailableReadFramesTrack0, sourceAvailableReadFramesTrack1) < mfpm) {
                    throw Failure("ring_full_without_dispatchable_pair")
                }
                if (!stepPairWindow()) throw Failure("makeroom_step_deferred")
            }
        }
        if (totalFramesAcceptedTrack0 != totalFramesAcceptedTrack1) {
            throw Failure("track_frame_axis_divergence_after_chunk")
        }
    }

    // ── Joint step/drain drive ──────────────────────────────────────────────

    // Drives the closed loop while both source rings hold a full window:
    // step at the shared accepted-frame-axis tick, drain each dispatched
    // pair window, drain-and-retry on output backpressure. Stops at the
    // (normal) deferred_insufficient_joint_source boundary.
    fun pumpWhileJointWindows() {
        var guard = 0
        val budget = (srcCap / mfpm) + 4
        while (minOf(sourceAvailableReadFramesTrack0, sourceAvailableReadFramesTrack1) >= mfpm) {
            checkDeadline()
            if (++guard > budget) throw Failure("pump_budget_exhausted")
            if (!stepPairWindow()) break
        }
    }

    // One joint dispatch attempt: returns true when a full pair window was
    // dispatched and drained, false on deferred_insufficient_joint_source
    // (normal while awaiting more lockstep ingest). Output backpressure is
    // drained and retried under a bounded budget.
    fun stepPairWindow(): Boolean {
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
                "deferred_insufficient_joint_source" -> return false
                else -> throw Failure("pump_step_status_${kv["status"]}")
            }
        }
    }

    // Explicit joint-dispatch-gate probe at a point where the joint window
    // is short: the deferral must report
    // deferred_insufficient_joint_source and mutate no clock/cursor/ring
    // state (dispatch count and cursor unchanged, zero frames rendered).
    fun probeJointDeferral() {
        if (minOf(sourceAvailableReadFramesTrack0, sourceAvailableReadFramesTrack1) >= mfpm) {
            throw Failure("deferral_probe_window_available")
        }
        val cursorBefore = nativeNextDispatchFrame
        val dispatchCountBefore = dispatchCount
        val kv = stepRaw(tickForFrame(nativeNextDispatchFrame + mfpm), flushTail = false)
        if (kv["status"] != "deferred_insufficient_joint_source") {
            throw Failure("deferral_probe_status_${kv["status"]}")
        }
        if (longField(kv, "framesRendered") != 0L ||
            nativeNextDispatchFrame != cursorBefore ||
            dispatchCount != dispatchCountBefore
        ) {
            throw Failure("deferral_probe_mutated_state")
        }
        jointDeferralObserved = true
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

    // ── Joint EOS tail flush + both-track accepted-frame-axis seek ──────────

    // Both tracks reach writer-local EOS together through the single joint
    // EOS entry point (there is no per-track EOS route in this slice);
    // native reports both flags in the same reply.
    fun setEosBothTracks() {
        val kv = parseNative(
            VanguardNativeBridge.setMultiSourceNodeOwnedAudioGraphPipelineEos(handle)
        )
        if (kv["status"] != "ok") throw Failure("eos_set_failed_${kv["status"]}")
        if (kv["eosTrack0"] != "true" || kv["eosTrack1"] != "true") {
            throw Failure("eos_flags_not_both_set")
        }
    }

    // Lossless joint boundary flush: both writers EOS, then a general
    // tail-flush loop that recomputes the tick from the native-reported
    // nextDispatchFrame each iteration, accepts dispatch_ok and
    // tail_flush_partial_window (draining after each), drains through
    // output backpressure, and terminates only on tail_flush_complete.
    // Afterwards the output ring is drained and both source rings must be
    // empty (a residual mismatch would already have failed closed natively
    // with tail_flush_track_length_mismatch).
    fun flushTailAtEos() {
        setEosBothTracks()
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
        if (sourceAvailableReadFramesTrack0 != 0L || sourceAvailableReadFramesTrack1 != 0L) {
            throw Failure("tail_flush_source_not_empty")
        }
    }

    // Native joint seek on the shared accepted-frame axis (not media PTS).
    // With A = totalFramesAcceptedTrack0 after a completed joint tail
    // flush, the seek pts is ceil(A * 1e6 / sampleRate) so native computes
    // targetFrame == A; the reply must re-anchor BOTH writers/providers at
    // exactly A with zero discards, the ack drain must land newStartFrame
    // == A with zero discards, and the seek must clear both writer-local
    // EOS flags. Returns A.
    fun seekToAcceptedFrameBoundary(): Long {
        val acceptedFrame = totalFramesAcceptedTrack0
        if (acceptedFrame != totalFramesAcceptedTrack1) {
            throw Failure("seek_boundary_track_axis_divergence")
        }
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
            VanguardNativeBridge.seekMultiSourceNodeOwnedAudioGraphPipeline(handle, seekPtsUs, seekSysNs)
        )
        if (kv["status"] != "ok") throw Failure("seek_status_${kv["status"]}")
        if (longField(kv, "targetFrame") != acceptedFrame ||
            longField(kv, "providerExpectedNextFrameTrack0") != acceptedFrame ||
            longField(kv, "providerExpectedNextFrameTrack1") != acceptedFrame ||
            longField(kv, "writerNextWriteFrameTrack0") != acceptedFrame ||
            longField(kv, "writerNextWriteFrameTrack1") != acceptedFrame ||
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
        if (snap["writerEosTrack0"] != "false" || snap["writerEosTrack1"] != "false") {
            throw Failure("seek_did_not_clear_writer_eos")
        }
        return acceptedFrame
    }

    // ── Snapshot / probes / verdict helpers ─────────────────────────────────

    fun snapshotMetrics(): Map<String, String> = snapshot()

    // Fail-closed no-fault sweep over the latest snapshot fold: any
    // provider underrun/zero-fill/forward-skip/rewind-reject, coordinator
    // silence window, ring-push shortfall, terminal latch, or still-pending
    // seek ack fails with a distinct token.
    fun verifyNoFaultCounters() {
        if (providerUnderrunEventsTrack0 != 0L || providerUnderrunEventsTrack1 != 0L) {
            throw Failure("provider_underrun_observed")
        }
        if (providerFramesZeroFilledTrack0 != 0L || providerFramesZeroFilledTrack1 != 0L) {
            throw Failure("provider_zero_fill_observed")
        }
        if (providerForwardSkipFramesTrack0 != 0L || providerForwardSkipFramesTrack1 != 0L) {
            throw Failure("provider_forward_skip_observed")
        }
        if (providerRewindRejectsTrack0 != 0L || providerRewindRejectsTrack1 != 0L) {
            throw Failure("provider_rewind_reject_observed")
        }
        if (coordinatorSilenceCount != 0L) throw Failure("silence_window_observed")
        if (ringPushShortfallSeen) throw Failure("ring_push_shortfall_observed")
        if (snapshotTerminal) throw Failure("terminal_state_observed")
        if (snapshotAwaitingSeekAck) throw Failure("seek_ack_still_pending")
    }

    fun verifyZeroSteadyStateAllocation(snap: Map<String, String>): Boolean =
        dispatchCount >= MIN_STEADY_STATE_DISPATCHES &&
            schedCapBefore == longField(snap, "schedulerTrackScratchCapacitySamples") &&
            schedTracksBefore == longField(snap, "schedulerTrackScratchCapacityTracks") &&
            src0StorageBefore == longField(snap, "sourceRingStorageCapacitySamplesTrack0") &&
            src1StorageBefore == longField(snap, "sourceRingStorageCapacitySamplesTrack1") &&
            outStorageBefore == longField(snap, "outputRingStorageCapacitySamples")

    // Deliberate foreign-thread snapshot that native must fail closed with
    // wrong_owner_thread; call only at a quiescent point.
    fun probeForeignThreadRejected(): Boolean {
        val status = AtomicReference("")
        val probeThread = Thread {
            status.set(
                parseStatus(
                    VanguardNativeBridge.snapshotMultiSourceNodeOwnedAudioGraphPipeline(handle)
                )["status"] ?: ""
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

    // Shared accepted-frame-axis tick: equal ticks are allowed (backpressure
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
            VanguardNativeBridge.stepMultiSourceNodeOwnedAudioGraphPipeline(handle, sysTimeNs, flushTail)
        )
        val status = kv["status"] ?: ""
        if (!kv.containsKey("sourceAvailableReadFramesTrack0") ||
            !kv.containsKey("sourceAvailableReadFramesTrack1")
        ) {
            throw Failure("step_missing_source_available_read_frames")
        }
        if (status == "ring_push_shortfall") {
            ringPushShortfallSeen = true
            throw Failure("ring_push_shortfall_observed")
        }
        if (status == "dispatch_silence") throw Failure("unexpected_silence_window")
        sourceAvailableReadFramesTrack0 = longField(kv, "sourceAvailableReadFramesTrack0")
        sourceAvailableReadFramesTrack1 = longField(kv, "sourceAvailableReadFramesTrack1")
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

    private fun drainOutputOnce(maxFrames: Int): Map<String, String> {
        checkDeadline()
        val kv = parseNative(
            VanguardNativeBridge.drainMultiSourceNodeOwnedAudioGraphPipelineOutput(handle, maxFrames)
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
        val kv = parseNative(VanguardNativeBridge.snapshotMultiSourceNodeOwnedAudioGraphPipeline(handle))
        if (kv["status"] != "ok") throw Failure("snapshot_status_${kv["status"]}")
        providerUnderrunEventsTrack0 = longField(kv, "providerUnderrunEventsTrack0")
        providerUnderrunEventsTrack1 = longField(kv, "providerUnderrunEventsTrack1")
        providerFramesZeroFilledTrack0 = longField(kv, "providerFramesZeroFilledTrack0")
        providerFramesZeroFilledTrack1 = longField(kv, "providerFramesZeroFilledTrack1")
        providerForwardSkipFramesTrack0 = longField(kv, "providerForwardSkipFramesTrack0")
        providerForwardSkipFramesTrack1 = longField(kv, "providerForwardSkipFramesTrack1")
        providerRewindRejectsTrack0 = longField(kv, "providerRewindRejectsTrack0")
        providerRewindRejectsTrack1 = longField(kv, "providerRewindRejectsTrack1")
        coordinatorSilenceCount = longField(kv, "silenceCount")
        totalFramesAcceptedTrack0 = longField(kv, "totalFramesAcceptedTrack0")
        totalFramesAcceptedTrack1 = longField(kv, "totalFramesAcceptedTrack1")
        totalOutputFramesDrained = longField(kv, "totalOutputFramesDrained")
        nativeAcceptedChecksumHexTrack0 = kv["nativeAcceptedChecksumHexTrack0"] ?: ""
        nativeAcceptedChecksumHexTrack1 = kv["nativeAcceptedChecksumHexTrack1"] ?: ""
        nativeOutputDrainChecksumHex = kv["nativeOutputDrainChecksumHex"] ?: ""
        sourceAvailableReadFramesTrack0 = longField(kv, "sourceAvailableReadFramesTrack0")
        sourceAvailableReadFramesTrack1 = longField(kv, "sourceAvailableReadFramesTrack1")
        outputAvailableReadFrames = longField(kv, "outputAvailableReadFrames")
        dispatchCount = longField(kv, "dispatchCount")
        nativeNextDispatchFrame = longField(kv, "nextDispatchFrame")
        routedSourceCount = longField(kv, "routedSourceCount")
        routedSourceId0 = kv["routedSourceId0"] ?: ""
        routedSourceId1 = kv["routedSourceId1"] ?: ""
        nodeOwnsRingTrack0 = kv["nodeOwnsRingTrack0"] == "true"
        nodeOwnsRingTrack1 = kv["nodeOwnsRingTrack1"] == "true"
        snapshotTerminal = kv["terminal"] == "true"
        snapshotAwaitingSeekAck = kv["awaitingSeekAck"] == "true"
        return kv
    }

    // Unwritten frames move to byte offset 0 so retries always read from the
    // buffer start, exactly like the external-provider-map two-source
    // session.
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
