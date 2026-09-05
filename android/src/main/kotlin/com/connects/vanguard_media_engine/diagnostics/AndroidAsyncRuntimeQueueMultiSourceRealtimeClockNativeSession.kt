package com.connects.vanguard_media_engine.diagnostics

import android.os.SystemClock
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession (P4
// True-DAG sub-slice X4) ────────────────────────────────────────────────────
//
// Owner-thread wrapper around the multi-source realtime-clock async runtime
// queue JNI seam
// (android_phase4_async_runtime_queue_multi_source_realtime_clock_jni.cpp),
// used by the muted-AudioTrack two-track realtime pacing driver
// [AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver] together with
// the lockstep ingest pump
// [AndroidAsyncRuntimeQueueMultiSourceRealtimeClockIngestPump]. The NATIVE
// WORKER thread inside the session is the sole reader of
// std::chrono::steady_clock for media time and the sole caller of every
// AudioClock mutator, every ClockedAudioTransportCoordinator
// control/dispatch method, and the output ring's producer role; this class
// only ingests PCM through the two NODE-OWNED source-ring writers (per
// track), enqueues start/seek commands (which carry NO time values), reads
// the output ring, and observes the worker through the mutex-published
// snapshot mirror. No step/dispatch method exists anywhere on this
// wrapper: in X4 only the native worker dispatches.
//
// X4 differences from the X3 wrapper
// (AndroidAsyncRuntimeQueueRealtimeClockNativeSession, untouched and
// behaviorally reproducible):
//   - Two node-owned source tracks on the SHARED ACCEPTED FRAME AXIS:
//     [ingestTrackOnce] takes a track index and folds per-track accepted
//     totals + native checksums; the seek boundary asserts lockstep
//     (accepted0 == accepted1 == target).
//   - The joint seek publishes BOTH writer requests natively and the
//     transient/fatal status token set is per-track suffixed.
//   - Per-track provider poisoning counters are folded from the snapshot.
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
// expected timeline before setting the joint writer-local EOS, and this
// wrapper fails closed if any per-track provider zero-fill is observed.
//
// Y18b (P4-AUDIO-REALTIME-PLAYBACK-RING-FRAME-SOURCE-PROOF) adds two
// owner-thread entry points used by the ring transport frame-source adapter
// [AndroidRealtimeAudioPlaybackRingTransportFrameSource] so a PRODUCTION
// sink can consume this output ring through the Y18a seam: [readOutputInto]
// (destructive read straight into a sink-owned direct buffer via the same
// JNI read entry point, same deadline check, same totals/checksum fold,
// same [OutputSink] accounting contract) and
// [tryCompleteTimelineAndSetEosWithoutDrain] (joint EOS after the exact
// timeline completed WITHOUT draining the output ring here, because the
// sink is the sole consumer of those frames). Every X4..X15 entry point is
// untouched.
//
// Y20-prep (P4-AUDIO-ASYNC-RUNTIME-QUEUE-SEEK-AWARE-EOS): the native read
// reply and snapshot now publish seek-aware EOS accounting
// (expectedPlayableFrameCount, totalForwardSeekSkippedFrames,
// totalDiscardedOnSeekFrames, seekSkipAnomalies); this wrapper parses them
// into [SinkReadReply] / the snap* mirror and compares timeline completion
// against expectedPlayableFrameCount instead of expectedFrames. For every
// existing no-seek and boundary-seek run those are identical (skipped ==
// discarded == 0, asserted fail-closed). No true forward-seek scenario is
// driven here.
class AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession(
    private val deadlineElapsedRealtimeMs: Long,
    private val outputSink: OutputSink,
) {
    class Failure(val reason: String) : Exception(reason)

    // Invoked after every destructive output read that produced frames: the
    // freshly read mixed PCM16 sits at byte offset 0 of the read buffer
    // supplied to [create]. The sink must fully consume (write + account)
    // the frames before returning, or throw; the session issues no further
    // native call while staged frames remain unconsumed. Y18b: for a
    // [readOutputInto] read the frames sit at byte offset 0 of the
    // caller-supplied `dst` instead (the production sink's own drain
    // buffer, which it writes itself); the callback is then accounting
    // only and must not touch the create-time read buffer.
    fun interface OutputSink {
        fun onOutputFramesRead(frames: Long)
    }

    // Y18b: one destructive read into a sink-owned buffer. Y20-prep adds
    // the native seek-aware EOS accounting the reply's eosDrained verdict
    // is computed from (all structurally expectedFrames / 0 for no-seek
    // and boundary-seek runs).
    data class SinkReadReply(
        val framesRead: Long,
        val bytesRead: Long,
        val totalOutputFramesRead: Long,
        val outputAvailableReadFrames: Long,
        val nativeOutputReadChecksumHex: String,
        val eosPublished: Boolean,
        val timelineComplete: Boolean,
        val totalFramesPushed: Long,
        val eosDrained: Boolean,
        val expectedPlayableFrameCount: Long,
        val totalForwardSeekSkippedFrames: Long,
        val totalDiscardedOnSeekFrames: Long,
        val seekSkipAnomalies: Long,
    )

    data class IngestReply(
        val framesAccepted: Long,
        val writerStatus: String,
        val writerBackpressureRejects: Long,
    )

    companion object {
        // Verbatim native TU constant; the snapshot must echo it so a
        // physical run proves the exact multi-source realtime-clock TU
        // executed. Deliberately carries NO AudioTrack/native-sink claim
        // (the Kotlin driver's separate boundary does).
        const val NATIVE_PROOF_BOUNDARY =
            "diagnostic_async_runtime_queue_multi_source_realtime_clock_native_worker_proof_only_real_decoder_plus_synthetic_track_node_owned_source_rings_to_graph_scheduler_audio_mix_bus_to_output_ring_worker_owned_std_chrono_steady_clock_render_dispatch_timebase_not_presentation_clock_no_caller_supplied_native_time_on_any_control_command_two_routed_tracks_unit_gain_lockstep_source_rings_spsc_output_ring_spsc_full_window_dispatch_only_window_aligned_expected_frame_count_no_joint_tail_flush_no_partial_window_dispatch_bounded_catch_up_max_eight_per_wake_condition_variable_wait_clamped_5ms_scheduler_auto_discovers_providers_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_native_frame_axis_is_shared_accepted_frame_count_not_media_pts_seek_reanchors_both_tracks_at_single_accepted_frame_cursor_synthetic_generator_reanchored_at_accepted_frame_axis_no_second_os_decoder_no_cpp_os_decoder_no_cpp_file_io_no_native_audio_sink_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_audible_output_no_speaker_route_no_audio_focus_no_route_change_no_dead_object_recovery_no_latency_glitch_avsync_claim_no_zero_underrun_claim_no_realtime_priority_no_sched_fifo_no_affinity_no_fleet_claim_no_product_editor_app_wiring_no_streaming_cache_no_export_route_no_ios_no_cpp_primitive_changes"

        // Matches the native per-call ingest clamp
        // (AudioDecoderRingWriter kMaxWriteFrames).
        private const val NATIVE_MAX_INGEST_FRAMES = 8_192L
        private const val POLL_SLEEP_MS = 2L
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

    // Owner-side per-track accounting folded from every ingest reply
    // (indexed, never duplicated).
    private val totalFramesAcceptedTrack = longArrayOf(0L, 0L)
    private val nativeAcceptedChecksumHexTrack = arrayOf("", "")
    var totalOutputFramesRead = 0L
        private set
    var nativeOutputReadChecksumHex = ""
        private set
    var writerBackpressureRejects = 0L
        private set

    val totalFramesAcceptedTrack0: Long get() = totalFramesAcceptedTrack[0]
    val totalFramesAcceptedTrack1: Long get() = totalFramesAcceptedTrack[1]
    val nativeAcceptedChecksumHexTrack0: String get() = nativeAcceptedChecksumHexTrack[0]
    val nativeAcceptedChecksumHexTrack1: String get() = nativeAcceptedChecksumHexTrack[1]

    // Lane observations.
    var workerOwnershipAtBootOk = false
        private set
    var nodeOwnedTopologyOk = false
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
    val snapProviderUnderrunEventsTrack = longArrayOf(-1L, -1L)
    val snapProviderFramesZeroFilledTrack = longArrayOf(-1L, -1L)
    val snapProviderForwardSkipFramesTrack = longArrayOf(-1L, -1L)
    val snapProviderRewindRejectsTrack = longArrayOf(-1L, -1L)
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
    var snapRoutedSourceCount = -1L
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
    // X5 envelope telemetry folded from the snapshot (defaults preserve the
    // X4 shape: enabled/applied false, evaluations 0, gains 0.0).
    var envelopeProofEnabled = false
        private set
    var snapEnvelopeProofEnabled = false
        private set
    var snapEnvelopeApplied = false
        private set
    var snapEnvelopeEvaluations = -1L
        private set
    var snapMinEffectiveGain = 0.0
        private set
    var snapMaxEffectiveGain = 0.0
        private set
    var snapProofBoundary = ""
        private set
    // X15 pause/resume telemetry folded from the snapshot (defaults keep the
    // X4..X14 shape: never paused, zero pause/resume commands).
    var snapPaused = false
        private set
    var snapPauseCommandsProcessed = -1L
        private set
    var snapResumeCommandsProcessed = -1L
        private set
    var snapWorkerPausedWaits = -1L
        private set
    var snapLastPausedIntervalNs = -1L
        private set
    var snapTotalPausedNs = -1L
        private set
    var snapTimingPausedExcludedNs = -1L
        private set
    var snapPausedDispatchFrozenOk = false
        private set
    // Y20-prep seek-aware EOS accounting folded from the snapshot
    // (defaults keep the seek-free shape: playable == expectedFrames,
    // skipped/discarded/anomalies 0 once a snapshot has been taken).
    var snapExpectedPlayableFrameCount = -1L
        private set
    var snapTotalForwardSeekSkippedFrames = -1L
        private set
    var snapTotalDiscardedOnSeekFrames = -1L
        private set
    var snapSeekSkipAnomalies = -1L
        private set
    // X15 owner-side pause/resume proof facts, recorded by
    // [pauseAndAwaitProof] / [assertPausedHoldFrozen] / [resumeAndAwaitProof].
    var pauseProofCommandSeq = -1L
        private set
    var resumeProofCommandSeq = -1L
        private set
    var pauseProofDispatchCountAtPause = -1L
        private set
    var pauseProofTotalFramesPushedAtPause = -1L
        private set
    var pauseProofNextDispatchFrameAtPause = -1L
        private set
    var pauseProofFramesPendingAtPause = -1L
        private set
    var pauseProofPausedWaitsAtPause = -1L
        private set
    var pauseProofDispatchCountAfterHold = -1L
        private set
    var pauseProofTotalFramesPushedAfterHold = -1L
        private set
    var pauseProofPausedWaitsAfterHold = -1L
        private set
    var pauseProofNativePauseOk = false
        private set
    var pauseProofHoldFrozenOk = false
        private set
    var pauseProofNativeResumeOk = false
        private set
    var lastStatus = ""
        private set
    // Y18b owner-side facts: sink-facing reads and the no-drain EOS set.
    var sinkReadCalls = 0L
        private set
    var sinkReadFramesTotal = 0L
        private set
    var eosSetWithoutDrain = false
        private set
    var totalFramesPushedAtEos = -1L
        private set
    // Y20-prep: the playable/skipped facts from the very snapshot that
    // authorized the no-drain EOS set (== expectedFrames / 0 for runs
    // without a true forward seek).
    var expectedPlayableFrameCountAtEos = -1L
        private set
    var totalForwardSeekSkippedFramesAtEos = -1L
        private set

    val isCreated: Boolean get() = handle != 0L
    val outputRingCapacityFrames: Long get() = outCap
    val maxFramesPerMix: Long get() = mfpm

    // ── Lifecycle ───────────────────────────────────────────────────────────

    // Creates the multi-source realtime-clock native session (which starts
    // its worker thread) and proves boot-time async ownership AND the
    // node-owned two-track topology: worker started, worker thread id
    // distinct from this owner thread, zero owner dispatch calls, the
    // structural no-caller-supplied-native-time token, exactly two routed
    // sources, and both nodes owning their rings. The driver-supplied
    // [readBuffer] must be direct, little-endian, and large enough to hold
    // one full output-ring drain.
    fun create(
        sampleRateIn: Int,
        channelCountIn: Int,
        expectedFramesIn: Long,
        sourceRingCapacityFrames: Int,
        outputRingCapacityFrames: Int,
        maxFramesPerMix: Int,
        readBuffer: ByteBuffer,
        envelopeProofEnabledIn: Boolean = false,
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
        // Frozen X3 geometry per source ring (also validated fail-closed in
        // native).
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
        envelopeProofEnabled = envelopeProofEnabledIn
        // X5 mode selects the envelope-enabled create; every other entry
        // point (start/seek/ingest/eos/read/snapshot/destroy) is shared.
        handle = if (envelopeProofEnabledIn) {
            VanguardNativeBridge.createAsyncRuntimeQueueMultiSourceRealtimeClockEnvelopeSession(
                sampleRateIn, channelCountIn, expectedFramesIn,
                sourceRingCapacityFrames, outputRingCapacityFrames, maxFramesPerMix,
            )
        } else {
            VanguardNativeBridge.createAsyncRuntimeQueueMultiSourceRealtimeClockSession(
                sampleRateIn, channelCountIn, expectedFramesIn,
                sourceRingCapacityFrames, outputRingCapacityFrames, maxFramesPerMix,
            )
        }
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
        if (longField(snapBoot, "routedSourceCount") != 2L ||
            snapBoot["routedSourceId0"] != "async_rtclock_ms_src0" ||
            snapBoot["routedSourceId1"] != "async_rtclock_ms_src1" ||
            snapBoot["nodeOwnsRingTrack0"] != "true" ||
            snapBoot["nodeOwnsRingTrack1"] != "true"
        ) {
            throw Failure("node_owned_two_track_topology_not_proven")
        }
        workerOwnershipAtBootOk = true
        nodeOwnedTopologyOk = true
    }

    // Enqueues the start command (no time value crosses JNI: the worker
    // reads steady_clock itself), waits for the worker to execute it, and
    // consumes the output-ring start ack (frame 0, zero discards). The
    // driver must have ingested the lockstep pre-start source fill quota
    // (on min(accepted0, accepted1)) first so BOTH decodes stay ahead of
    // the realtime clock.
    fun startAndConsumeAck() {
        val kv = parseNative(
            VanguardNativeBridge.startAsyncRuntimeQueueMultiSourceRealtimeClock(handle)
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

    // ── Ingest (owner is BOTH source rings' producer; lockstep pacing is
    // owned by the pump) ─────────────────────────────────────────────────────

    // One ingest of [frames] frames held at byte offset 0 of [pcm] into
    // track [track]'s node-owned writer. The pump streams the Kotlin
    // reference checksums BEFORE handing a chunk here, so this wrapper
    // folds only the native-side per-track accounting.
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
            VanguardNativeBridge.ingestAsyncRuntimeQueueMultiSourceRealtimeClockPcm16(
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
        totalFramesAcceptedTrack[0] = longField(kv, "totalFramesAcceptedTrack0")
        totalFramesAcceptedTrack[1] = longField(kv, "totalFramesAcceptedTrack1")
        nativeAcceptedChecksumHexTrack[track] = kv["nativeAcceptedChecksumHex"] ?: ""
        writerBackpressureRejects = longField(kv, "writerBackpressureRejects")
        return IngestReply(accepted, writerStatus, writerBackpressureRejects)
    }

    // ── Output reads (owner is the output-ring consumer; every destructive
    // read hands its frames to the driver sink before any further native
    // call) ─────────────────────────────────────────────────────────────────

    private fun readOnce(maxFrames: Int): Map<String, String> {
        checkDeadline()
        val buf = readBuf ?: throw Failure("read_before_create")
        val kv = parseNative(
            VanguardNativeBridge.readAsyncRuntimeQueueMultiSourceRealtimeClockOutputPcm16(
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

    // Y18b (owner thread only): one destructive output read of up to
    // [maxFrames] frames straight into the sink-owned direct buffer [dst]
    // at byte offset 0, through the SAME JNI read entry point as
    // [readOnce] with the same deadline check and the same owner-side
    // totals/checksum fold; [outputSink.onOutputFramesRead] is invoked only
    // for frames actually read (frames sit in `dst`, see [OutputSink]).
    // No start/seek ack may be pending here: the adapter consumes the start
    // ack through [startAndConsumeAck] before the sink is allowed to drain
    // and this proof issues no seek, so an ack consumed inside a sink read
    // is an ordering defect and fails closed (its frames would otherwise be
    // silently discarded at the boundary).
    fun readOutputInto(dst: ByteBuffer, maxFrames: Int): SinkReadReply {
        checkDeadline()
        if (handle == 0L) throw Failure("sink_read_before_create")
        if (maxFrames <= 0 || maxFrames.toLong() > outCap) throw Failure("sink_read_invalid_max_frames")
        if (!dst.isDirect) throw Failure("sink_read_dst_not_direct")
        if (dst.order() != ByteOrder.LITTLE_ENDIAN) throw Failure("sink_read_dst_not_little_endian")
        if (dst.capacity() < maxFrames * bytesPerFrame) throw Failure("sink_read_dst_too_small")
        val kv = parseNative(
            VanguardNativeBridge.readAsyncRuntimeQueueMultiSourceRealtimeClockOutputPcm16(
                handle, dst, maxFrames,
            )
        )
        if (kv["status"] != "ok") throw Failure("sink_read_status_${kv["status"]}")
        if (kv["seekAckConsumed"] == "true") throw Failure("sink_read_consumed_unexpected_ack")
        totalOutputFramesRead = longField(kv, "totalOutputFramesRead")
        nativeOutputReadChecksumHex = kv["nativeOutputReadChecksumHex"] ?: ""
        val framesRead = longField(kv, "framesRead")
        val bytesRead = longField(kv, "bytesRead")
        if (framesRead < 0L || framesRead > maxFrames.toLong()) throw Failure("sink_read_frames_out_of_range")
        if (bytesRead != framesRead * bytesPerFrame) throw Failure("sink_read_bytes_mismatch")
        sinkReadCalls += 1L
        if (framesRead > 0L) {
            sinkReadFramesTotal += framesRead
            outputSink.onOutputFramesRead(framesRead)
        }
        return SinkReadReply(
            framesRead = framesRead,
            bytesRead = bytesRead,
            totalOutputFramesRead = totalOutputFramesRead,
            outputAvailableReadFrames = longField(kv, "outputAvailableReadFrames"),
            nativeOutputReadChecksumHex = nativeOutputReadChecksumHex,
            eosPublished = kv["eosPublished"] == "true",
            timelineComplete = kv["timelineComplete"] == "true",
            totalFramesPushed = kv["totalFramesPushed"]?.toLongOrNull() ?: -1L,
            eosDrained = kv["eosDrained"] == "true",
            expectedPlayableFrameCount = expectedPlayableFrameCountOf(kv),
            totalForwardSeekSkippedFrames = longField(kv, "totalForwardSeekSkippedFrames"),
            totalDiscardedOnSeekFrames = longField(kv, "totalDiscardedOnSeekFrames"),
            seekSkipAnomalies = longField(kv, "seekSkipAnomalies"),
        )
    }

    // Y20-prep: the native seek-aware playable frame count from a read
    // reply or snapshot, validated against the seek-free invariant: with
    // zero forward-seek skipped frames it MUST equal expectedFrames, and
    // it can never exceed expectedFrames or go negative. Any violation is
    // a native accounting defect and fails closed.
    private fun expectedPlayableFrameCountOf(kv: Map<String, String>): Long {
        val playable = longField(kv, "expectedPlayableFrameCount")
        val skipped = longField(kv, "totalForwardSeekSkippedFrames")
        if (skipped < 0L || playable < 0L || playable > expectedFrames ||
            playable != expectedFrames - skipped
        ) {
            throw Failure("expected_playable_frame_count_inconsistent")
        }
        if (skipped == 0L && playable != expectedFrames) {
            throw Failure("expected_playable_frame_count_mismatch")
        }
        return playable
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

    // ── Forward joint seek at the aligned accepted-frame boundary
    // (pre-EOS, both tracks re-anchored at one accepted frame cursor) ───────

    // The seek target IS the current lockstep accepted frame count, which
    // must be window-aligned, equal across both tracks, fully dispatched,
    // and fully read. After quiescence and the full boundary drain,
    // [onQuiescentBeforeSeek] runs exactly once (the X4 driver
    // pauses/flushes its AudioTrack sink there, with zero staged residual
    // frames guaranteed by the sink callback contract); only then is the
    // native joint seek enqueued (no time value crosses JNI) and awaited.
    // The pending OUTPUT ack is deliberately NOT consumed here: the driver
    // prefills both post-seek source rings first and then calls
    // [consumeSeekAckAndReanchor]. Transient seek statuses are
    // waited/retried under a bounded budget; every other status (including
    // seek_track_frame_axis_divergence and both
    // seek_target_behind_writer_trackN tokens) fails closed.
    fun seekAtQuiescentBoundary(onQuiescentBeforeSeek: () -> Unit): Long {
        val target = totalFramesAcceptedTrack[0]
        if (target <= 0L || target % mfpm != 0L) throw Failure("seek_boundary_not_aligned")
        if (totalFramesAcceptedTrack[1] != target) {
            throw Failure("seek_boundary_lockstep_mismatch")
        }
        awaitSnapshotDraining("seek_quiescent") {
            longField(it, "totalFramesPushed") == target &&
                longField(it, "sourceAvailableReadFramesTrack0") == 0L &&
                longField(it, "sourceAvailableReadFramesTrack1") == 0L
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
                VanguardNativeBridge.seekAsyncRuntimeQueueMultiSourceRealtimeClock(
                    handle, seekPtsUs,
                )
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
                // Bounded wait/retry transients (per-track suffixed).
                "seek_pending_commands",
                "seek_source_ring_not_empty_track0",
                "seek_source_ring_not_empty_track1",
                "seek_source_ack_pending_track0",
                "seek_source_ack_pending_track1",
                "seek_output_ack_pending" -> Thread.sleep(POLL_SLEEP_MS)
                // Everything else (seek_track_frame_axis_divergence,
                // behind_cursor, behind_writer_track0/1,
                // writer_seek_rejected_track0/1, seek_rejected_eos,
                // timing_window_unavailable via awaitCommandProcessed, and
                // the per-track ack missing/mismatch tokens) fails closed.
                else -> throw Failure("seek_status_${kv["status"]}")
            }
        }
    }

    // ── X15 diagnostic transport pause/resume (owner thread; no time value
    // crosses JNI; the worker samples steady_clock itself) ─────────────────

    // Enqueues the native Pause command, awaits the worker's execution
    // (command seq strictly next, lastCommandResult=ok, zero command
    // errors) and records the frozen dispatch/push totals from the very
    // snapshot that reported the command processed (the worker publishes
    // that snapshot after skipping dispatch for the paused loop pass).
    fun pauseAndAwaitProof(): Map<String, String> {
        if (pauseProofCommandSeq >= 0L) throw Failure("pause_proof_already_exercised")
        val kv = parseNative(
            VanguardNativeBridge.pauseAsyncRuntimeQueueMultiSourceRealtimeClock(handle)
        )
        if (kv["status"] != "enqueued") throw Failure("pause_not_enqueued_${kv["status"]}")
        val seq = ++nextCommandSeq
        if (longField(kv, "commandSeq") != seq) throw Failure("pause_command_seq_mismatch")
        val snap = awaitCommandProcessed(seq)
        if (snap["paused"] != "true" ||
            longField(snap, "pauseCommandsProcessed") != 1L ||
            longField(snap, "resumeCommandsProcessed") != 0L
        ) {
            throw Failure("pause_state_mismatch")
        }
        pauseProofCommandSeq = seq
        pauseProofDispatchCountAtPause = longField(snap, "dispatchCount")
        pauseProofTotalFramesPushedAtPause = longField(snap, "totalFramesPushed")
        pauseProofNextDispatchFrameAtPause = longField(snap, "nextDispatchFrame")
        pauseProofFramesPendingAtPause =
            totalFramesAcceptedTrack[0] - pauseProofNextDispatchFrameAtPause
        pauseProofPausedWaitsAtPause = longField(snap, "workerPausedWaits")
        if (longField(snap, "dispatchCountAtPause") != pauseProofDispatchCountAtPause ||
            longField(snap, "totalFramesPushedAtPause") != pauseProofTotalFramesPushedAtPause
        ) {
            throw Failure("pause_worker_totals_mismatch")
        }
        pauseProofNativePauseOk = true
        return snap
    }

    // Snapshot-only (no output read, no command) proof taken after the
    // driver's bounded paused hold: still paused, dispatchCount and
    // totalFramesPushed exactly as at the pause, at least one worker paused
    // wait observed since the pause, and zero command errors.
    fun assertPausedHoldFrozen(): Map<String, String> {
        if (!pauseProofNativePauseOk) throw Failure("pause_hold_without_pause")
        val snap = snapshot()
        pauseProofDispatchCountAfterHold = snapDispatchCount
        pauseProofTotalFramesPushedAfterHold = snapTotalFramesPushed
        pauseProofPausedWaitsAfterHold = snapWorkerPausedWaits
        if (!snapPaused) throw Failure("pause_hold_not_paused")
        if (snapCommandErrors != 0L) throw Failure("pause_hold_command_errors")
        if (pauseProofDispatchCountAfterHold != pauseProofDispatchCountAtPause ||
            pauseProofTotalFramesPushedAfterHold != pauseProofTotalFramesPushedAtPause ||
            longField(snap, "nextDispatchFrame") != pauseProofNextDispatchFrameAtPause
        ) {
            throw Failure("pause_hold_dispatch_not_frozen")
        }
        if (pauseProofPausedWaitsAfterHold <= pauseProofPausedWaitsAtPause) {
            throw Failure("pause_hold_wait_not_observed")
        }
        pauseProofHoldFrozenOk = true
        return snap
    }

    // Enqueues the native Resume command and awaits its execution: the
    // worker must report not paused, exactly one resume processed, and its
    // own pause->resume frozen-dispatch verdict true with the resume-time
    // totals equal to the pause-time totals.
    fun resumeAndAwaitProof(): Map<String, String> {
        if (!pauseProofHoldFrozenOk) throw Failure("resume_before_hold_proof")
        if (resumeProofCommandSeq >= 0L) throw Failure("resume_proof_already_exercised")
        val kv = parseNative(
            VanguardNativeBridge.resumeAsyncRuntimeQueueMultiSourceRealtimeClock(handle)
        )
        if (kv["status"] != "enqueued") throw Failure("resume_not_enqueued_${kv["status"]}")
        val seq = ++nextCommandSeq
        if (longField(kv, "commandSeq") != seq) throw Failure("resume_command_seq_mismatch")
        val snap = awaitCommandProcessed(seq)
        if (snap["paused"] != "false" ||
            longField(snap, "pauseCommandsProcessed") != 1L ||
            longField(snap, "resumeCommandsProcessed") != 1L ||
            snap["pausedDispatchFrozenOk"] != "true" ||
            longField(snap, "dispatchCountAtResume") != pauseProofDispatchCountAtPause ||
            longField(snap, "totalFramesPushedAtResume") != pauseProofTotalFramesPushedAtPause ||
            longField(snap, "lastPausedIntervalNs") <= 0L
        ) {
            throw Failure("resume_state_mismatch")
        }
        resumeProofCommandSeq = seq
        pauseProofNativeResumeOk = true
        return snap
    }

    // Consumes the pending output-ring seek ack (ack-only read) after the
    // post-seek lockstep source prefill: the ack must land at exactly the
    // seek target frame with zero discarded frames.
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

    // ── Timeline completion + joint writer-local EOS (zero-fill forbidden) ──

    // Awaits the exact expected-frame timeline completion, drains the last
    // output, then sets the JOINT writer-local EOS (one entry point, both
    // writers). Because the timeline is already complete, the worker has no
    // remaining window to dispatch, so provider zero-fill cannot occur on
    // either track; any observed zero-fill fails closed to keep the
    // identity checksums pure.
    //
    // Y20-prep: the completion target is the native seek-aware
    // expectedPlayableFrameCount (== expectedFrames whenever no true
    // forward seek skipped content; the boundary seek of this driver
    // skips nothing) and the drain target excludes frames the reader
    // already discarded at seek-ack consumption (0 for this driver).
    fun completeTimelineAndSetEos() {
        val complete = awaitSnapshotDraining("timeline_complete") {
            it["timelineComplete"] == "true" &&
                longField(it, "totalFramesPushed") == expectedPlayableFrameCountOf(it)
        }
        val playable = expectedPlayableFrameCountOf(complete)
        val discarded = longField(complete, "totalDiscardedOnSeekFrames")
        if (discarded < 0L || discarded > playable) {
            throw Failure("discarded_on_seek_frames_inconsistent")
        }
        drainUntilRead(playable - discarded)
        val kv = parseNative(
            VanguardNativeBridge.setAsyncRuntimeQueueMultiSourceRealtimeClockEos(handle)
        )
        if (kv["status"] != "ok" || kv["eosTrack0"] != "true" || kv["eosTrack1"] != "true") {
            throw Failure("eos_set_failed_${kv["status"]}")
        }
        val snap = awaitSnapshot("post_eos_quiescent") {
            longField(it, "outputAvailableReadFrames") == 0L
        }
        if (longField(snap, "providerFramesZeroFilledTrack0") != 0L ||
            longField(snap, "providerFramesZeroFilledTrack1") != 0L
        ) {
            throw Failure("zero_fill_leaked_into_identity")
        }
    }

    // Y18b (owner thread only, non-blocking poll): takes ONE snapshot and,
    // if the worker has completed the exact expected timeline
    // (timelineComplete with totalFramesPushed == the native seek-aware
    // expectedPlayableFrameCount, which is expectedFrames whenever no true
    // forward seek skipped content, Y20-prep), sets the
    // JOINT writer-local EOS exactly once and returns true. Unlike
    // [completeTimelineAndSetEos] it never reads the output ring: the
    // production sink is the sole consumer of those frames (observing
    // eosDrained through [readOutputInto]). Zero-fill is impossible after
    // timeline completion (no window remains to dispatch) and is asserted
    // from the same snapshot to keep the identity checksums pure. Returns
    // false when the timeline is still running; every command must have
    // succeeded so far, otherwise fails closed.
    fun tryCompleteTimelineAndSetEosWithoutDrain(): Boolean {
        if (eosSetWithoutDrain) return true
        val snap = snapshot()
        if (longField(snap, "commandErrors") != 0L) throw Failure("eos_poll_command_errors")
        val playable = expectedPlayableFrameCountOf(snap)
        if (snap["timelineComplete"] != "true" ||
            longField(snap, "totalFramesPushed") != playable
        ) {
            return false
        }
        if (longField(snap, "providerFramesZeroFilledTrack0") != 0L ||
            longField(snap, "providerFramesZeroFilledTrack1") != 0L
        ) {
            throw Failure("zero_fill_leaked_into_identity")
        }
        val kv = parseNative(
            VanguardNativeBridge.setAsyncRuntimeQueueMultiSourceRealtimeClockEos(handle)
        )
        if (kv["status"] != "ok" || kv["eosTrack0"] != "true" || kv["eosTrack1"] != "true") {
            throw Failure("eos_set_failed_${kv["status"]}")
        }
        totalFramesPushedAtEos = longField(snap, "totalFramesPushed")
        expectedPlayableFrameCountAtEos = playable
        totalForwardSeekSkippedFramesAtEos = longField(snap, "totalForwardSeekSkippedFrames")
        eosSetWithoutDrain = true
        return true
    }

    // ── Snapshot / lifecycle verdicts ───────────────────────────────────────

    fun finalSnapshot(): Map<String, String> = snapshot()

    // Destroy joins the worker (never detaches); second destroy and
    // post-destroy snapshot must both report not_found.
    fun destroyAndVerifyLifecycle(): Pair<Boolean, Boolean> {
        if (handle == 0L) throw Failure("lifecycle_no_handle")
        val h = handle
        val destroyKv = parseStatus(
            VanguardNativeBridge.destroyAsyncRuntimeQueueMultiSourceRealtimeClockSession(h)
        )
        handle = 0L
        val joinOk = destroyKv["status"] == "ok" &&
            destroyKv["workerJoined"] == "true" &&
            destroyKv["workerExited"] == "true" &&
            longField(destroyKv, "joinCount") == 1L
        val againKv = parseStatus(
            VanguardNativeBridge.destroyAsyncRuntimeQueueMultiSourceRealtimeClockSession(h)
        )
        val snapKv = parseStatus(
            VanguardNativeBridge.snapshotAsyncRuntimeQueueMultiSourceRealtimeClock(h)
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
                VanguardNativeBridge.destroyAsyncRuntimeQueueMultiSourceRealtimeClockSession(handle)
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
            VanguardNativeBridge.snapshotAsyncRuntimeQueueMultiSourceRealtimeClock(handle)
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
        for (track in 0..1) {
            snapProviderUnderrunEventsTrack[track] =
                longField(kv, "providerUnderrunEventsTrack$track")
            snapProviderFramesZeroFilledTrack[track] =
                longField(kv, "providerFramesZeroFilledTrack$track")
            snapProviderForwardSkipFramesTrack[track] =
                longField(kv, "providerForwardSkipFramesTrack$track")
            snapProviderRewindRejectsTrack[track] =
                longField(kv, "providerRewindRejectsTrack$track")
        }
        snapTotalFramesRendered = longField(kv, "totalFramesRendered")
        snapTotalFramesPushed = longField(kv, "totalFramesPushed")
        snapOwnerDispatchCalls = longField(kv, "ownerDispatchCalls")
        snapWorkerThreadDistinct = kv["workerThreadDistinct"] == "true"
        snapTerminal = kv["terminal"] == "true"
        snapNoCallerSuppliedNativeTime = kv["noCallerSuppliedNativeTime"] == "true"
        snapWorkerOwnsMonotonicClock = kv["workerOwnsMonotonicClock"] == "true"
        snapRoutedSourceCount = longField(kv, "routedSourceCount")
        snapNativeTimingF0 = longField(kv, "nativeTimingF0")
        snapNativeTimingF1 = longField(kv, "nativeTimingF1")
        snapNativeRealtimeElapsedMs = longField(kv, "nativeRealtimeElapsedMs")
        snapRealtimeElapsedOk = kv["realtimeElapsedOk"] == "true"
        snapMaxRenderCursorBacklogUs = longField(kv, "maxRenderCursorBacklogUs")
        snapRealtimeBacklogBoundOk = kv["realtimeBacklogBoundOk"] == "true"
        snapBacklogSampleCount = longField(kv, "backlogSampleCount")
        snapClockDriftSampleCount = longField(kv, "clockDriftSampleCount")
        snapEnvelopeProofEnabled = kv["envelopeProofEnabled"] == "true"
        snapEnvelopeApplied = kv["envelopeApplied"] == "true"
        snapEnvelopeEvaluations = longField(kv, "envelopeEvaluations")
        snapMinEffectiveGain = doubleField(kv, "minEffectiveGain")
        snapMaxEffectiveGain = doubleField(kv, "maxEffectiveGain")
        snapPaused = kv["paused"] == "true"
        snapPauseCommandsProcessed = longField(kv, "pauseCommandsProcessed")
        snapResumeCommandsProcessed = longField(kv, "resumeCommandsProcessed")
        snapWorkerPausedWaits = longField(kv, "workerPausedWaits")
        snapLastPausedIntervalNs = longField(kv, "lastPausedIntervalNs")
        snapTotalPausedNs = longField(kv, "totalPausedNs")
        snapTimingPausedExcludedNs = longField(kv, "timingPausedExcludedNs")
        snapPausedDispatchFrozenOk = kv["pausedDispatchFrozenOk"] == "true"
        snapExpectedPlayableFrameCount = expectedPlayableFrameCountOf(kv)
        snapTotalForwardSeekSkippedFrames = longField(kv, "totalForwardSeekSkippedFrames")
        snapTotalDiscardedOnSeekFrames = longField(kv, "totalDiscardedOnSeekFrames")
        snapSeekSkipAnomalies = longField(kv, "seekSkipAnomalies")
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

    private fun doubleField(kv: Map<String, String>, key: String): Double =
        kv[key]?.toDoubleOrNull() ?: throw Failure("missing_status_field_$key")
}
