package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioTrack
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.NativeState
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackPipelineClockSyncSinkBridge.Activity
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.IngestRequest
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

private typealias ClockOutcome = VanguardRealtimePlaybackPresentationClock.Outcome
private typealias ClockProvenance = VanguardRealtimePlaybackPresentationClock.Provenance

// ── VanguardRealtimePlaybackPipelineClockSyncCoordinator (P4-AUDIO-REALTIME-PLAYBACK-CLOCK-SYNCHRONIZATION, Y7) ─
//
// The ONLY transport command owner of the Y7 clock-synchronization
// diagnostic over the committed Y6a/Y6b pipeline shape (Y6f timestamp
// stabilization preserved verbatim, plus the read-only downstream
// [VanguardRealtimePlaybackPresentationClock]):
//
//   MediaExtractor/MediaCodec  ->  Y5a external ingest seam  ->  Y1 native
//   ([VanguardRealtimePlaybackDecoderFeed], decode thread, unchanged)
//   transport (owner HandlerThread inside the state machine)  ->
//   non-zero-gain AudioTrack MODE_STREAM
//   ([VanguardRealtimePlaybackPipelineClockSyncSinkBridge], sink thread)
//   -> presentation clock (written by the sink thread at the post-write
//      poll point only; snapshotted by this thread, any thread legal)
//
// Thread model: the decoder feed thread only posts generation-pinned
// ingest; the sink thread only drains, owns every AudioTrack call
// (create / recreate / setVolume / play / write / getTimestamp /
// playbackHeadPosition / release), the one synthetic dead object and every
// presentation-clock WRITE; the state machine is the only JNI caller; this
// coordinator (the caller's worker thread) issues transport commands (load,
// prepare, start), takes read-only clock snapshots while it waits, joins
// and aggregates. It never calls an AudioTrack method and never writes the
// pipeline clock.
//
// Two scenarios run sequentially in one smoke, each with its own feed,
// transport, sink, AudioTrack and clock. Shared head: format probe ->
// pre-roll -> sink setup on the sink thread (track created, base volume
// 0.5, empty pre-start drain point, clock RESET/unopened) BEFORE transport
// start -> start -> first positive sink write + play() (epoch 0 opens in
// the sink AND the clock) -> >= phaseFrames.
//   FORWARD_PLAYTHROUGH_CLOCK_SYNC: single epoch to EOS. Every valid
//                            getTimestamp sample anchors the clock
//                            (ANCHORED); every unavailable poll extrapolates
//                            within the bounded horizon (EXTRAPOLATED) or
//                            holds the position past it (STALE); the
//                            published position never decreases; transport
//                            COMPLETED; 4-way checksum identity.
//   DEAD_OBJECT_CLOCK_EPOCH_RESET: the sink thread substitutes exactly one
//                            synthetic ERROR_DEAD_OBJECT for an in-flight
//                            write once >= 2 * phaseFrames were written,
//                            recovers inline (epoch 0 closed in sink + clock
//                            -> release old once -> same-parameter recreate
//                            -> setVolume -> play() -> epoch 1 opens with a
//                            fresh raw baseline and a clock base offset =
//                            frames written so far), drains to EOS. Clock
//                            continuity comes from base-offset accumulation
//                            only; no raw position is ever compared across
//                            epochs.
//
// A deterministic synthetic self-check of a standalone clock instance runs
// on this thread before the scenarios (no AudioTrack involved) so the
// extrapolation / stale-horizon / regression / epoch-reset / rejection
// branches are proven even when the device's getTimestamp never fails.
//
// Diagnostic only. No A/V sync, drift correction, HAL / output latency,
// getTimestamp availability SLA, pacing / write feedback, seek / flush,
// real OS fault forcing, seamless hot-swap, product / editor / app /
// ConnectsApp, iOS, streaming / cache or C++ / JNI change lives here.
class VanguardRealtimePlaybackPipelineClockSyncCoordinator {

    enum class Scenario { FORWARD_PLAYTHROUGH_CLOCK_SYNC, DEAD_OBJECT_CLOCK_EPOCH_RESET }

    data class Config(
        val sourcePath: String,
        val maxDurationSec: Double = 3.0,
        val maxFramesPerMix: Int = 256,
        val baseVolume: Float = VanguardRealtimePlaybackPipelineClockSyncSinkBridge.DEFAULT_BASE_VOLUME,
        val deadlineMs: Long = 60_000L,
        val phaseFrames: Long = DEFAULT_PHASE_FRAMES,
        // Presentation-clock extrapolation horizon; STALE past it.
        val extrapolationHorizonMs: Long = DEFAULT_EXTRAPOLATION_HORIZON_MS,
    )

    data class Result(
        val pass: Boolean,
        val status: String,
        val failureReason: String,
        val proofBoundary: String,
        val lanes: Map<String, Boolean>,
        val metrics: Map<String, Any?>,
        val raw: String,
    )

    companion object {
        const val PROOF_BOUNDARY =
            "realtime_playback_pipeline_clock_sync_diagnostic_only_real_mediaextractor_mediacodec_" +
                "to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_" +
                "sink_thread_owns_audiotrack_gettimestamp_and_presentation_clock_updates_coordinator_owns_transport_commands_" +
                "presentation_clock_read_only_downstream_any_thread_snapshots_monotonic_published_position_" +
                "one_poll_per_drain_pass_after_write_epoch_opens_after_playing_epoch_model_audiotrack_instance_" +
                "per_epoch_unsigned32_unwrap_one_wrap_tolerated_regression_fails_closed_continuity_by_base_offset_accumulation_" +
                "gettimestamp_false_nonterminal_bounded_extrapolation_stale_after_horizon_no_fabricated_position_" +
                "synthetic_dead_object_epoch_reset_only_no_seek_no_flush_" +
                "no_av_sync_no_drift_correction_no_hal_output_latency_no_gettimestamp_availability_sla_" +
                "no_pacing_no_write_feedback_no_drain_gating_no_checksum_feedback_no_underrun_handling_" +
                "no_real_os_fault_forcing_no_seamless_hot_swap_" +
                "no_product_no_editor_no_app_wiring_no_connectsapp_no_ios_no_streaming_no_cache_no_cpp_no_jni_changes"

        const val DEFAULT_PHASE_FRAMES = 2_048L

        const val DEFAULT_EXTRAPOLATION_HORIZON_MS = 250L
        const val MAX_EXTRAPOLATION_HORIZON_MS = 1_000L

        const val LANE_FORMAT_PROBE = "formatProbeOk"
        const val LANE_PRE_ROLL = "preRollOk"
        const val LANE_PRE_START_DRAIN_EMPTY = "preStartDrainEmptyOk"
        const val LANE_TIMESTAMP_POLL_CADENCE = "timestampPollCadenceOk"
        const val LANE_PRESENTATION_CLOCK_ANCHORED = "presentationClockAnchoredOk"
        const val LANE_PRESENTATION_CLOCK_MONOTONIC = "presentationClockMonotonicOk"
        const val LANE_PRESENTATION_CLOCK_EXTRAPOLATED = "presentationClockExtrapolatedOk"
        const val LANE_PRESENTATION_CLOCK_STALE_BOUND = "presentationClockStaleBoundOk"
        const val LANE_PRESENTATION_CLOCK_EPOCH_RESET = "presentationClockEpochResetOk"
        const val LANE_SNAPSHOT_PROVENANCE = "snapshotProvenanceOk"
        const val LANE_CLOCK_NO_FEEDBACK = "clockNoFeedbackOk"
        const val LANE_TIMESTAMP_FAILURE_NONTERMINAL = "timestampFailureNonterminalOk"
        const val LANE_DEAD_OBJECT_INJECTED_ONCE = "deadObjectInjectedOnceOk"
        const val LANE_DEAD_OBJECT_OLD_TRACK_RELEASED = "deadObjectOldTrackReleasedOk"
        const val LANE_DEAD_OBJECT_NEW_TRACK_INIT_VOLUME_PLAY = "deadObjectNewTrackInitVolumePlayOk"
        const val LANE_DEAD_OBJECT_REMAINDER_RESUMED = "deadObjectRemainderResumedOk"
        const val LANE_DEAD_OBJECT_NO_DOUBLE_COUNT = "deadObjectNoDoubleCountOk"
        const val LANE_SINK_WRITE_ACCOUNTING = "sinkWriteAccountingOk"
        const val LANE_CHECKSUM_IDENTITY = "checksumIdentityOk"
        const val LANE_TRANSPORT_COMPLETED = "transportCompletedOk"
        const val LANE_AUDIO_TRACK_LIFECYCLE = "audioTrackLifecycleOk"
        const val LANE_THREAD_OWNERSHIP = "threadOwnershipOk"
        const val LANE_PROOF_BOUNDARY = "proofBoundaryOk"
        const val LANE_CANONICAL = "canonical"

        val REQUIRED_LANES: List<String> = listOf(
            LANE_FORMAT_PROBE,
            LANE_PRE_ROLL,
            LANE_PRE_START_DRAIN_EMPTY,
            LANE_TIMESTAMP_POLL_CADENCE,
            LANE_PRESENTATION_CLOCK_ANCHORED,
            LANE_PRESENTATION_CLOCK_MONOTONIC,
            LANE_PRESENTATION_CLOCK_EXTRAPOLATED,
            LANE_PRESENTATION_CLOCK_STALE_BOUND,
            LANE_PRESENTATION_CLOCK_EPOCH_RESET,
            LANE_SNAPSHOT_PROVENANCE,
            LANE_CLOCK_NO_FEEDBACK,
            LANE_TIMESTAMP_FAILURE_NONTERMINAL,
            LANE_DEAD_OBJECT_INJECTED_ONCE,
            LANE_DEAD_OBJECT_OLD_TRACK_RELEASED,
            LANE_DEAD_OBJECT_NEW_TRACK_INIT_VOLUME_PLAY,
            LANE_DEAD_OBJECT_REMAINDER_RESUMED,
            LANE_DEAD_OBJECT_NO_DOUBLE_COUNT,
            LANE_SINK_WRITE_ACCOUNTING,
            LANE_CHECKSUM_IDENTITY,
            LANE_TRANSPORT_COMPLETED,
            LANE_AUDIO_TRACK_LIFECYCLE,
            LANE_THREAD_OWNERSHIP,
            LANE_PROOF_BOUNDARY,
        )

        // Lanes every scenario must hold (epoch expectations differ per
        // scenario but are evaluated inside each session). The
        // presentation-clock lanes additionally require the synthetic
        // self-check (coordinator level) to have passed.
        private val SHARED_LANES = listOf(
            LANE_FORMAT_PROBE, LANE_PRE_ROLL, LANE_PRE_START_DRAIN_EMPTY,
            LANE_TIMESTAMP_POLL_CADENCE,
            LANE_PRESENTATION_CLOCK_ANCHORED, LANE_PRESENTATION_CLOCK_MONOTONIC,
            LANE_PRESENTATION_CLOCK_EXTRAPOLATED, LANE_PRESENTATION_CLOCK_STALE_BOUND,
            LANE_PRESENTATION_CLOCK_EPOCH_RESET, LANE_SNAPSHOT_PROVENANCE,
            LANE_CLOCK_NO_FEEDBACK, LANE_TIMESTAMP_FAILURE_NONTERMINAL,
            LANE_SINK_WRITE_ACCOUNTING, LANE_CHECKSUM_IDENTITY, LANE_TRANSPORT_COMPLETED,
            LANE_AUDIO_TRACK_LIFECYCLE, LANE_THREAD_OWNERSHIP,
        )
        private val DEAD_OBJECT_LANES = listOf(
            LANE_DEAD_OBJECT_INJECTED_ONCE, LANE_DEAD_OBJECT_OLD_TRACK_RELEASED,
            LANE_DEAD_OBJECT_NEW_TRACK_INIT_VOLUME_PLAY, LANE_DEAD_OBJECT_REMAINDER_RESUMED,
            LANE_DEAD_OBJECT_NO_DOUBLE_COUNT,
        )
        // Self-check gates: a scenario-level clock lane only holds if the
        // matching synthetic proof held too.
        private val SELF_CHECK_GATED_LANES = listOf(
            LANE_PRESENTATION_CLOCK_ANCHORED, LANE_PRESENTATION_CLOCK_MONOTONIC,
            LANE_PRESENTATION_CLOCK_EXTRAPOLATED, LANE_PRESENTATION_CLOCK_STALE_BOUND,
            LANE_PRESENTATION_CLOCK_EPOCH_RESET, LANE_SNAPSHOT_PROVENANCE,
            LANE_TIMESTAMP_FAILURE_NONTERMINAL,
        )

        private const val SELF_CHECK_SAMPLE_RATE = 48_000
        private const val SELF_CHECK_HELPER_JOIN_MS = 2_000L

        private const val WAIT_SLICE_MS = 5L
        private const val JOIN_TIMEOUT_MS = 5_000L
        private const val SETUP_WAIT_MS = 5_000L
        private const val INITIAL_WRITE_WAIT_MS = 2_000L
        private const val PHASE_WAIT_TIMEOUT_MS = 6_000L
        // The dead object must land well before the declared end.
        private const val TERMINAL_MARGIN_WINDOWS = 8L
        private const val MIN_DECLARED_PHASES = 4L
    }

    private class FailClosed(val reason: String) : Exception(reason)

    private val started = AtomicBoolean(false)
    private val cancelled = AtomicBoolean(false)

    @Volatile
    private var running = false

    @Volatile
    private var activeSession: Session? = null

    private val lanes = linkedMapOf<String, Boolean>()
    private val metrics = linkedMapOf<String, Any?>()

    @Volatile
    private var selfCheck: ClockSelfCheck.Outcome? = null

    // ── Public API ─────────────────────────────────────────────────────────

    fun cancel() {
        cancelled.set(true)
        activeSession?.cancelThreads()
    }

    fun dispose() {
        cancel()
        if (!running) activeSession?.disposeTransportOnce()
    }

    // Executes both scenarios on the calling thread. Single use.
    fun run(config: Config): Result {
        if (!started.compareAndSet(false, true)) return buildResult(false, "coordinator_already_used")
        running = true
        for (lane in REQUIRED_LANES) lanes[lane] = false
        return try {
            execute(config)
            val pass = REQUIRED_LANES.all { lanes[it] == true }
            buildResult(pass, if (pass) "" else "lane_failed:${firstFailedLane()}")
        } catch (f: FailClosed) {
            buildResult(false, f.reason)
        } catch (t: Throwable) {
            buildResult(false, "exception:${t.javaClass.simpleName}:${t.message}")
        } finally {
            activeSession?.disposeTransportOnce()
            activeSession = null
            running = false
        }
    }

    // ── Orchestration ──────────────────────────────────────────────────────

    private fun execute(config: Config) {
        if (config.sourcePath.isBlank()) throw FailClosed("source_path_required")
        if (config.maxDurationSec <= 0.0 ||
            config.maxDurationSec > VanguardRealtimePlaybackDecoderFeed.HARD_MAX_DURATION_SEC
        ) {
            throw FailClosed("invalid_max_duration")
        }
        if (config.maxFramesPerMix <= 0 ||
            config.maxFramesPerMix > VanguardRealtimePlaybackNativeSession.MAX_FRAMES_PER_MIX_CAP
        ) {
            throw FailClosed("invalid_max_frames_per_mix")
        }
        if (!(config.baseVolume > 0f) || config.baseVolume > 1f) throw FailClosed("invalid_base_volume")
        if (config.deadlineMs <= 0L) throw FailClosed("invalid_deadline")
        if (config.phaseFrames <= 0L) throw FailClosed("invalid_phase_frames")
        if (config.extrapolationHorizonMs <= 0L || config.extrapolationHorizonMs > MAX_EXTRAPOLATION_HORIZON_MS) {
            throw FailClosed("invalid_extrapolation_horizon")
        }
        if (cancelled.get()) throw FailClosed("cancelled")
        val deadlineAtMs = SystemClock.elapsedRealtime() + config.deadlineMs
        val horizonNs = config.extrapolationHorizonMs * 1_000_000L
        metrics["maxDurationSec"] = config.maxDurationSec
        metrics["maxFramesPerMix"] = config.maxFramesPerMix
        metrics["baseVolume"] = config.baseVolume.toDouble()
        metrics["deadlineMs"] = config.deadlineMs
        metrics["phaseFrames"] = config.phaseFrames
        metrics["coordinatorThreadId"] = Thread.currentThread().id
        metrics["scenarioOrder"] = Scenario.entries.map { it.name }
        metrics["frameWrapModulus"] = VanguardRealtimePlaybackPipelineClockSyncSinkBridge.FRAME_WRAP_MODULUS
        metrics["frameWrapForwardMax"] = VanguardRealtimePlaybackPipelineClockSyncSinkBridge.FRAME_WRAP_FORWARD_MAX
        metrics["extrapolationHorizonMs"] = config.extrapolationHorizonMs
        metrics["extrapolationHorizonNs"] = horizonNs
        lanes[LANE_PROOF_BOUNDARY] = true

        // Synthetic, deterministic clock proof on this thread (no AudioTrack).
        val sc = ClockSelfCheck(horizonNs).run()
        selfCheck = sc
        metrics["clockSelfCheck"] = LinkedHashMap<String, Any?>(sc.metrics)
        if (!sc.allOk) throw FailClosed("clock_self_check_failed:${sc.firstFailure}")

        val results = LinkedHashMap<Scenario, Session>()
        val wallStart = SystemClock.elapsedRealtime()
        try {
            for (scenario in Scenario.entries) {
                if (cancelled.get()) throw FailClosed("cancelled")
                val session = Session(config, scenario, deadlineAtMs, horizonNs)
                activeSession = session
                results[scenario] = session
                try {
                    session.runScenario()
                } finally {
                    session.disposeTransportOnce()
                    session.publishMetrics()
                    metrics[scenario.name.lowercase()] = LinkedHashMap<String, Any?>(session.metrics)
                    activeSession = null
                }
                session.failure.get()?.let { throw FailClosed("${scenario.name.lowercase()}:$it") }
            }
        } finally {
            metrics["totalWallMs"] = SystemClock.elapsedRealtime() - wallStart
            aggregateLanes(results)
        }
    }

    private fun aggregateLanes(results: Map<Scenario, Session>) {
        val all = Scenario.entries.map { results[it] }
        fun laneOf(s: Session?, lane: String): Boolean = s?.lanes?.get(lane) == true
        for (lane in SHARED_LANES) lanes[lane] = all.all { laneOf(it, lane) }
        for (lane in DEAD_OBJECT_LANES) lanes[lane] = laneOf(results[Scenario.DEAD_OBJECT_CLOCK_EPOCH_RESET], lane)
        val sc = selfCheck
        for (lane in SELF_CHECK_GATED_LANES) lanes[lane] = lanes[lane] == true && sc != null && sc.laneHeld(lane)
        // Aggregate timestamp telemetry across both scenarios (informational).
        var attempts = 0L
        var successes = 0L
        var unavailable = 0L
        var regressions = 0L
        var wraps = 0L
        var violations = 0L
        var clockAnchored = 0L
        var clockExtrapolated = 0L
        var clockStale = 0L
        var clockNoAnchor = 0L
        var clockRejected = 0L
        var clockSnapshots = 0L
        for (s in all) {
            val sink = s?.sink ?: continue
            attempts += sink.timestampPollAttempts
            successes += sink.timestampPollSuccesses
            unavailable += sink.timestampPollUnavailable
            regressions += sink.timestampFrameRegressionCount
            wraps += sink.timestampWrapCount
            violations += sink.timestampPollViolations
            clockAnchored += sink.clockAnchoredCount
            clockExtrapolated += sink.clockExtrapolatedCount
            clockStale += sink.clockStaleCount
            clockNoAnchor += sink.clockNoAnchorCount
            clockRejected += sink.clockRejectedCount
            clockSnapshots += s.clockSampleCount
        }
        metrics["timestampPollAttemptsTotal"] = attempts
        metrics["timestampPollSuccessesTotal"] = successes
        metrics["timestampPollUnavailableTotal"] = unavailable
        metrics["timestampFrameRegressionTotal"] = regressions
        metrics["timestampWrapTotal"] = wraps
        metrics["timestampPollViolationsTotal"] = violations
        metrics["clockAnchoredTotal"] = clockAnchored
        metrics["clockExtrapolatedTotal"] = clockExtrapolated
        metrics["clockStaleTotal"] = clockStale
        metrics["clockNoAnchorTotal"] = clockNoAnchor
        metrics["clockRejectedTotal"] = clockRejected
        metrics["clockCoordinatorSnapshotsTotal"] = clockSnapshots
        for (scenario in Scenario.entries) {
            val s = results[scenario]
            metrics["${scenario.name.lowercase()}ScenarioPass"] = s != null && s.failure.get() == null && s.scenarioLanesHeld()
        }
    }

    private fun isCancelled(): Boolean = cancelled.get()

    // ── One scenario session (feed + transport + sink) ─────────────────────

    private inner class Session(
        val config: Config,
        val scenario: Scenario,
        val deadlineAtMs: Long,
        val horizonNs: Long,
    ) {
        val failure = AtomicReference<String?>(null)
        val lanes = linkedMapOf<String, Boolean>()
        val metrics = linkedMapOf<String, Any?>()
        val completedCount = AtomicInteger(0)
        val failedCount = AtomicInteger(0)
        val listenerOnOwner = AtomicLong(0L)
        val listenerOffOwner = AtomicLong(0L)
        private val transitions = StringBuilder()
        private val disposedOnce = AtomicBoolean(false)

        @Volatile var sm: VanguardRealtimePlaybackTransportStateMachine? = null
        @Volatile var feed: VanguardRealtimePlaybackDecoderFeed? = null
        @Volatile var sink: VanguardRealtimePlaybackPipelineClockSyncSinkBridge? = null

        var format: VanguardRealtimePlaybackDecoderFeed.Format? = null
        var commandsIssued = 0
        var prepareGeneration = -1L
        var startGeneration = -1L
        var preRollFrames = 0L
        var preRollRingFull = false
        var preRollPartialWrite = false
        var preRollStatePrepared = false
        var startAcceptedPlaying = false
        var finalReply: Reply? = null
        var stateBeforeDispose = State.IDLE
        var stateAfterDispose = State.IDLE
        var stateAfterSecondDispose = State.IDLE
        var postIngestAfterDispose = true
        var feedJoined = false
        var sinkJoined = false
        var disposeCalls = 0
        var sessionWallMs = 0L
        var stateAtCompletion = State.IDLE

        // Sink setup / head observations.
        var setupWaitMs = -1L
        var setupCompleteBeforeStart = false
        var preStartDrainEmptyBeforeStart = false
        var transportStateAtSetup = State.IDLE
        var timestampPollsAtStart = -1L
        var epochsOpenAtStart = -1
        var initialWriteWaitMs = -1L
        var framesWrittenAtPhase = 0L
        var pollAttemptsAtPhase = -1L
        var epochsAtPhase = -1
        var transportCommandsAtSinkStart = 0
        // Dead-object arming (dead-object scenario): enabled by this thread
        // after the phase observations were captured.
        var deadObjectPositionLimit = -1L
        var deadObjectArmedByCoordinator = false
        var deadObjectArmedOnCoordinatorThread = false
        var framesWrittenAtArm = -1L
        var deadObjectsAtArm = -1L

        // Presentation-clock snapshots taken on THIS thread (read-only
        // downstream view) while waiting; the sink thread never snapshots.
        val expectedEpochs: Int = if (scenario == Scenario.DEAD_OBJECT_CLOCK_EPOCH_RESET) 2 else 1
        var initialClockSnapshot: VanguardRealtimePlaybackPresentationClock.Snapshot? = null
        var finalClockSnapshot: VanguardRealtimePlaybackPresentationClock.Snapshot? = null
        var clockSampleCount = 0L
        var clockSamplesOnCoordinatorThread = 0L
        var clockSamplesInconsistent = 0L
        var clockSamplePositionRegressions = 0L
        var clockSampleEpochRegressions = 0L
        var clockSampleSequenceRegressions = 0L
        var clockSampleProvenanceInconsistencies = 0L
        var clockSampleEpochOutOfRange = 0L
        var clockSamplePositionUsMismatches = 0L
        var clockSampleMaxPosition = -1L
        var clockSampleMaxEpoch = VanguardRealtimePlaybackPresentationClock.EPOCH_NONE
        var clockSampleLastEpoch = VanguardRealtimePlaybackPresentationClock.EPOCH_NONE
        var clockSampleLastSequence = -1L
        var clockSampleSeenAnchored = 0L
        var clockSampleSeenExtrapolated = 0L
        var clockSampleSeenStale = 0L
        var clockSampleSeenReset = 0L
        var clockSampleSeenEpoch1Open = false

        // One read-only snapshot; never blocks the sink, never feeds back.
        fun sampleClock(s: VanguardRealtimePlaybackPipelineClockSyncSinkBridge): VanguardRealtimePlaybackPresentationClock.Snapshot {
            val snap = s.presentationClock.snapshot()
            clockSampleCount++
            if (Thread.currentThread().id != s.threadId) clockSamplesOnCoordinatorThread++
            if (!snap.consistent) clockSamplesInconsistent++
            if (snap.positionFrames < clockSampleMaxPosition) clockSamplePositionRegressions++
            if (snap.positionFrames > clockSampleMaxPosition) clockSampleMaxPosition = snap.positionFrames
            if (snap.epochId < clockSampleLastEpoch) clockSampleEpochRegressions++
            clockSampleLastEpoch = snap.epochId
            if (snap.epochId > clockSampleMaxEpoch) clockSampleMaxEpoch = snap.epochId
            if (snap.epochId < VanguardRealtimePlaybackPresentationClock.EPOCH_NONE || snap.epochId >= expectedEpochs) clockSampleEpochOutOfRange++
            if (snap.sequence < clockSampleLastSequence) clockSampleSequenceRegressions++
            clockSampleLastSequence = snap.sequence
            if (snap.positionUs != VanguardRealtimePlaybackPresentationClock.framesToUs(snap.positionFrames, snap.sampleRate)) {
                clockSamplePositionUsMismatches++
            }
            val anchored = snap.anchorContinuousFrames >= 0L
            when (snap.provenance) {
                VanguardRealtimePlaybackPresentationClock.Provenance.ANCHORED -> {
                    clockSampleSeenAnchored++
                    if (!anchored || !snap.epochOpen) clockSampleProvenanceInconsistencies++
                }
                VanguardRealtimePlaybackPresentationClock.Provenance.EXTRAPOLATED -> {
                    clockSampleSeenExtrapolated++
                    if (!anchored || !snap.epochOpen || snap.lastAgeNs < 0L || snap.lastAgeNs > horizonNs) clockSampleProvenanceInconsistencies++
                }
                VanguardRealtimePlaybackPresentationClock.Provenance.STALE -> {
                    clockSampleSeenStale++
                    if (!anchored || !snap.epochOpen || snap.lastAgeNs <= horizonNs) clockSampleProvenanceInconsistencies++
                }
                VanguardRealtimePlaybackPresentationClock.Provenance.RESET -> {
                    clockSampleSeenReset++
                    if (anchored) clockSampleProvenanceInconsistencies++
                }
            }
            if (snap.epochId == 1 && snap.epochOpen) clockSampleSeenEpoch1Open = true
            return snap
        }

        private val listener = object : VanguardRealtimePlaybackTransportStateMachine.Listener {
            override fun onStateChanged(previous: State, current: State, generation: Long) {
                countListener()
                synchronized(transitions) {
                    if (transitions.isEmpty()) transitions.append(previous.name)
                    transitions.append('>').append(current.name)
                }
            }

            override fun onCompleted(generation: Long) {
                countListener()
                completedCount.incrementAndGet()
            }

            override fun onFailed(reason: String, generation: Long) {
                countListener()
                failedCount.incrementAndGet()
                recordFailure("transport:$reason")
            }

            private fun countListener() {
                val machine = sm
                if (machine != null && machine.isOwnerThread) listenerOnOwner.incrementAndGet() else listenerOffOwner.incrementAndGet()
            }
        }

        fun recordFailure(reason: String) {
            failure.compareAndSet(null, reason)
        }

        fun cancelThreads() {
            feed?.cancel()
            sink?.cancel()
        }

        fun disposeTransportOnce() {
            if (!disposedOnce.compareAndSet(false, true)) return
            val machine = sm ?: return
            stateBeforeDispose = machine.currentState
            machine.dispose()
            disposeCalls++
            stateAfterDispose = machine.currentState
        }

        fun scenarioLanesHeld(): Boolean {
            val specific = when (scenario) {
                Scenario.FORWARD_PLAYTHROUGH_CLOCK_SYNC -> emptyList()
                Scenario.DEAD_OBJECT_CLOCK_EPOCH_RESET -> DEAD_OBJECT_LANES
            }
            return (SHARED_LANES + specific).all { lanes[it] == true }
        }

        private fun sessionCancelled(): Boolean = isCancelled()

        private fun checkDeadlineAndCancel() {
            if (sessionCancelled()) throw FailClosed("cancelled")
            if (SystemClock.elapsedRealtime() > deadlineAtMs) throw FailClosed("deadline_exceeded")
        }

        private fun remainingMs(): Long = maxOf(1L, deadlineAtMs - SystemClock.elapsedRealtime())

        private fun sleepSlice(ms: Long = WAIT_SLICE_MS) {
            try {
                Thread.sleep(ms)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                throw FailClosed("interrupted")
            }
        }

        private fun pollFailure(): String? {
            failure.get()?.let { return it }
            val machine = sm
            if (machine != null && machine.currentState == State.FAILED) recordFailure("transport_failed")
            val f = feed
            if (f != null && !f.isAlive) {
                val reason = f.exitReason
                if (reason != VanguardRealtimePlaybackDecoderFeed.EXIT_EOS &&
                    reason != VanguardRealtimePlaybackDecoderFeed.EXIT_RUNNING &&
                    reason != VanguardRealtimePlaybackDecoderFeed.EXIT_CANCELLED
                ) {
                    recordFailure("decoder:$reason")
                }
            }
            val s = sink
            if (s != null && !s.isAlive &&
                s.exitReason != VanguardRealtimePlaybackPipelineClockSyncSinkBridge.EXIT_RUNNING &&
                s.exitReason != VanguardRealtimePlaybackPipelineClockSyncSinkBridge.EXIT_EOS &&
                s.exitReason != VanguardRealtimePlaybackPipelineClockSyncSinkBridge.EXIT_NOT_STARTED
            ) {
                recordFailure("sink:${s.exitReason}")
            }
            if (sessionCancelled()) recordFailure("cancelled")
            if (SystemClock.elapsedRealtime() > deadlineAtMs) recordFailure("deadline_exceeded")
            return failure.get()
        }

        private fun joinBoth() {
            feedJoined = feed?.join(JOIN_TIMEOUT_MS) ?: true
            sinkJoined = sink?.join(JOIN_TIMEOUT_MS) ?: true
        }

        private fun snapshotReply(phase: String, machine: VanguardRealtimePlaybackTransportStateMachine): Reply {
            val res = machine.snapshot()
            if (!res.accepted) throw FailClosed("snapshot_rejected_$phase:${res.reason}")
            return res.reply ?: throw FailClosed("snapshot_null_reply_$phase")
        }

        // Waits (bounded) for a sink-published condition; fails closed on
        // any pipeline failure, sink exit or timeout.
        private fun awaitSink(
            s: VanguardRealtimePlaybackPipelineClockSyncSinkBridge,
            phase: String,
            timeoutMs: Long,
            condition: () -> Boolean,
        ) {
            val waitDeadline = SystemClock.elapsedRealtime() + timeoutMs
            while (!condition()) {
                pollFailure()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_during_$phase:${s.exitReason}")
                if (SystemClock.elapsedRealtime() > waitDeadline) throw FailClosed("timeout_$phase")
                sampleClock(s)
                sleepSlice()
            }
        }

        // ── Open / prepare / sink setup / start ────────────────────────────

        private fun openAndPrepare() {
            checkDeadlineAndCancel()
            val tag = scenario.name.lowercase()
            val f = VanguardRealtimePlaybackDecoderFeed(
                VanguardRealtimePlaybackDecoderFeed.Config(
                    sourcePath = config.sourcePath,
                    maxDurationSec = config.maxDurationSec,
                    maxFramesPerMix = config.maxFramesPerMix,
                    deadlineAtMs = deadlineAtMs,
                    threadName = "Y7DecoderFeed_$tag",
                    externallyCancelled = { sessionCancelled() },
                ),
            )
            feed = f
            if (!f.start()) throw FailClosed("feed_start_rejected")
            val fmt = f.awaitFormat(remainingMs()) ?: throw FailClosed("format_probe_failed:${f.exitReason}")
            format = fmt
            checkDeadlineAndCancel()
            // The head needs the dead-object arming phases plus a margin
            // before the declared end.
            if (fmt.declaredFrameCount <= config.phaseFrames * MIN_DECLARED_PHASES +
                TERMINAL_MARGIN_WINDOWS * config.maxFramesPerMix
            ) {
                throw FailClosed("declared_frame_count_too_short_for_script:${fmt.declaredFrameCount}")
            }
            deadObjectPositionLimit = fmt.declaredFrameCount - TERMINAL_MARGIN_WINDOWS * config.maxFramesPerMix

            val sessionConfig = VanguardRealtimePlaybackNativeSession.Config(
                sampleRate = fmt.sampleRate,
                channelCount = fmt.channelCount,
                maxFramesPerMix = config.maxFramesPerMix,
                trackCount = VanguardRealtimePlaybackDecoderFeed.TRACK_COUNT,
                declaredFrameCount = fmt.declaredFrameCount,
                externalIngestTrackMask = VanguardRealtimePlaybackDecoderFeed.EXTERNAL_INGEST_TRACK_MASK,
            )
            VanguardRealtimePlaybackNativeSession.validate(sessionConfig)?.let {
                throw FailClosed("session_config_invalid:${it.name.lowercase()}")
            }
            val machine = VanguardRealtimePlaybackTransportStateMachine(sessionConfig, listener, threadName = "Y7Transport_$tag")
            sm = machine
            if (sessionCancelled()) throw FailClosed("cancelled")

            val loadRes = machine.load()
            commandsIssued++
            if (!loadRes.accepted) throw FailClosed("load_rejected:${loadRes.reason}")
            val prepareRes = machine.prepare()
            commandsIssued++
            if (!prepareRes.accepted || prepareRes.state != State.PREPARED) throw FailClosed("prepare_rejected:${prepareRes.reason}")
            prepareGeneration = machine.currentGeneration
            f.attachTransport(machine, prepareGeneration)

            while (!f.awaitPreRoll(WAIT_SLICE_MS)) {
                checkDeadlineAndCancel()
                failure.get()?.let { throw FailClosed(it) }
                if (!f.isAlive) throw FailClosed("feed_exited_during_preroll:${f.exitReason}")
            }
            preRollFrames = f.preRollFrames
            preRollRingFull = f.preRollRingFullObserved
            preRollPartialWrite = f.preRollPartialWriteObserved
            preRollStatePrepared = machine.currentState == State.PREPARED
            if (preRollFrames <= 0L) throw FailClosed("preroll_empty:${f.exitReason}")
        }

        // Sink thread setup (track, base volume, empty pre-start drain
        // point, no poll, no epoch) completes BEFORE the transport starts;
        // the sink then waits on its start gate.
        private fun startSinkAndProveSetup() {
            checkDeadlineAndCancel()
            val fmt = format ?: throw FailClosed("format_missing")
            val machine = sm ?: throw FailClosed("transport_missing")
            val tag = scenario.name.lowercase()
            transportCommandsAtSinkStart = commandsIssued
            val s = VanguardRealtimePlaybackPipelineClockSyncSinkBridge(
                VanguardRealtimePlaybackPipelineClockSyncSinkBridge.Config(
                    stateMachine = machine,
                    scenario = when (scenario) {
                        Scenario.FORWARD_PLAYTHROUGH_CLOCK_SYNC ->
                            VanguardRealtimePlaybackPipelineClockSyncSinkBridge.Scenario.FORWARD_PLAYTHROUGH_CLOCK_SYNC
                        Scenario.DEAD_OBJECT_CLOCK_EPOCH_RESET ->
                            VanguardRealtimePlaybackPipelineClockSyncSinkBridge.Scenario.DEAD_OBJECT_CLOCK_EPOCH_RESET
                    },
                    sampleRate = fmt.sampleRate,
                    channelCount = fmt.channelCount,
                    maxFramesPerMix = config.maxFramesPerMix,
                    declaredFrameCount = fmt.declaredFrameCount,
                    phaseFrames = config.phaseFrames,
                    baseVolume = config.baseVolume,
                    deadlineAtMs = deadlineAtMs,
                    extrapolationHorizonNs = horizonNs,
                    threadName = "Y7SinkBridge_$tag",
                    externallyCancelled = { sessionCancelled() },
                ),
            )
            sink = s
            if (!s.start()) throw FailClosed("sink_start_rejected")
            val waitStart = SystemClock.elapsedRealtime()
            awaitSink(s, "sink_setup", SETUP_WAIT_MS) { s.setupComplete }
            setupWaitMs = SystemClock.elapsedRealtime() - waitStart
            transportStateAtSetup = machine.currentState
            setupCompleteBeforeStart = s.setupComplete && transportStateAtSetup == State.PREPARED
            timestampPollsAtStart = s.timestampPollAttempts
            epochsOpenAtStart = s.timestampEpochOpenCount
            preStartDrainEmptyBeforeStart = s.preStartDrainEmptyOk && s.drainCalls == 0L && s.framesWrittenToSink == 0L &&
                s.framesReadFromTransport == 0L && timestampPollsAtStart == 0L && epochsOpenAtStart == 0 && !s.played &&
                s.preStartPlayState == AudioTrack.PLAYSTATE_STOPPED
            // Clock before transport start: bound to the sink thread, unopened, RESET, position 0.
            initialClockSnapshot = sampleClock(s)
            val setupProven = setupCompleteBeforeStart && s.audioTrackInitOk && s.gainSetOk &&
                s.gainValue == config.baseVolume && s.setVolumeCalls == 1L && s.audioTracksCreated == 1
            lanes[LANE_PRE_START_DRAIN_EMPTY] = setupProven && preStartDrainEmptyBeforeStart
            if (!setupProven) throw FailClosed("sink_setup_not_proven")
            if (lanes[LANE_PRE_START_DRAIN_EMPTY] != true) throw FailClosed("pre_start_drain_not_empty:${s.preStartPlayState}")
        }

        private fun startTransport() {
            checkDeadlineAndCancel()
            val machine = sm ?: throw FailClosed("transport_missing")
            val f = feed ?: throw FailClosed("feed_missing")
            val s = sink ?: throw FailClosed("sink_missing")
            val startRes = machine.start()
            commandsIssued++
            startAcceptedPlaying = startRes.accepted && startRes.state == State.PLAYING
            if (!startAcceptedPlaying) throw FailClosed("start_rejected:${startRes.reason}")
            startGeneration = machine.currentGeneration
            f.updateGeneration(startGeneration)
            f.markTransportStarted()
            s.allowDrain()
        }

        // ── Shared head (coordinator thread) ───────────────────────────────

        private fun awaitInitialWrites(s: VanguardRealtimePlaybackPipelineClockSyncSinkBridge) {
            val waitStart = SystemClock.elapsedRealtime()
            awaitSink(s, "initial_write", INITIAL_WRITE_WAIT_MS) { s.framesWrittenToSink > 0L && s.played }
            initialWriteWaitMs = SystemClock.elapsedRealtime() - waitStart
        }

        private fun drainAtLeast(s: VanguardRealtimePlaybackPipelineClockSyncSinkBridge, phase: String, target: Long) {
            awaitSink(s, phase, PHASE_WAIT_TIMEOUT_MS) { s.framesWrittenToSink >= target }
            val machine = sm ?: throw FailClosed("transport_missing")
            if (machine.currentState != State.PLAYING) throw FailClosed("transport_not_playing_after_$phase:${machine.currentState.name.lowercase()}")
            framesWrittenAtPhase = s.framesWrittenToSink
            pollAttemptsAtPhase = s.timestampPollAttempts
            epochsAtPhase = s.timestampEpochOpenCount
            if (epochsAtPhase < 1) throw FailClosed("epoch_not_open_after_$phase")
            // Dead-object scenario: the injection point must be well before
            // the declared end.
            if (scenario == Scenario.DEAD_OBJECT_CLOCK_EPOCH_RESET) {
                val pre = snapshotReply("pre_dead_object", machine)
                if (pre.state == NativeState.COMPLETED || pre.positionFrame >= deadObjectPositionLimit) {
                    throw FailClosed("dead_object_precondition_late:${pre.positionFrame}:$deadObjectPositionLimit")
                }
                if (s.syntheticDeadObjectInjectedCount != 0L || s.deadObjectObservedCount != 0L) {
                    throw FailClosed("dead_object_before_arm:${s.syntheticDeadObjectInjectedCount}:${s.deadObjectObservedCount}")
                }
                deadObjectsAtArm = s.deadObjectObservedCount
                framesWrittenAtArm = s.framesWrittenToSink
                deadObjectArmedOnCoordinatorThread = Thread.currentThread().id != s.threadId && !machine.isOwnerThread
                s.enableDeadObjectInjection()
                deadObjectArmedByCoordinator = s.deadObjectInjectionArmed
                if (!deadObjectArmedByCoordinator) throw FailClosed("dead_object_arm_rejected")
            }
        }

        // ── Tail: both scenarios drain to EOS ──────────────────────────────

        // The sink thread arms, injects and recovers the one synthetic dead
        // object inline (dead-object scenario); this thread only waits for
        // EOS. It never issues a transport command here.
        private fun tailEos(s: VanguardRealtimePlaybackPipelineClockSyncSinkBridge, f: VanguardRealtimePlaybackDecoderFeed) {
            while (!s.awaitExit(WAIT_SLICE_MS)) {
                val first = pollFailure()
                if (first != null) {
                    cancelThreads()
                    break
                }
                sampleClock(s)
            }
            if (failure.get() == null && s.exitReason != VanguardRealtimePlaybackPipelineClockSyncSinkBridge.EXIT_EOS) {
                recordFailure("sink:${s.exitReason}")
            }
            if (failure.get() == null && !f.awaitExit(JOIN_TIMEOUT_MS)) recordFailure("decoder_did_not_exit")
            if (failure.get() == null && f.exitReason != VanguardRealtimePlaybackDecoderFeed.EXIT_EOS) recordFailure("decoder:${f.exitReason}")
            if (scenario == Scenario.DEAD_OBJECT_CLOCK_EPOCH_RESET && failure.get() == null &&
                (s.syntheticDeadObjectInjectedCount != 1L || s.deadObjectObservedCount != 1L)
            ) {
                recordFailure("dead_object_never_injected:${s.syntheticDeadObjectInjectedCount}:${s.deadObjectObservedCount}")
            }
            if (scenario == Scenario.FORWARD_PLAYTHROUGH_CLOCK_SYNC && failure.get() == null &&
                (s.syntheticDeadObjectInjectedCount != 0L || s.deadObjectObservedCount != 0L)
            ) {
                recordFailure("dead_object_in_forward_scenario:${s.syntheticDeadObjectInjectedCount}:${s.deadObjectObservedCount}")
            }
        }

        // ── Scenario body ──────────────────────────────────────────────────

        fun runScenario() {
            val wallStart = SystemClock.elapsedRealtime()
            try {
                openAndPrepare()
                startSinkAndProveSetup()
                startTransport()
                val f = feed ?: throw FailClosed("feed_missing")
                val s = sink ?: throw FailClosed("sink_missing")
                val machine = sm ?: throw FailClosed("transport_missing")

                awaitInitialWrites(s)
                drainAtLeast(s, "first_phase", config.phaseFrames)
                tailEos(s, f)
                if (failure.get() != null) cancelThreads()
                joinBoth()
                finalClockSnapshot = sampleClock(s)

                val snapRes = machine.snapshot()
                finalReply = snapRes.reply ?: s.lastReply
                if (failure.get() == null && (!snapRes.accepted || finalReply == null)) {
                    recordFailure("final_snapshot_rejected:${snapRes.reason}")
                }

                stateAtCompletion = machine.currentState
                disposeTransportOnce()
                val probe = ByteBuffer.allocateDirect(config.maxFramesPerMix * 2 * (format?.channelCount ?: 2))
                    .order(ByteOrder.nativeOrder())
                postIngestAfterDispose = machine.postIngest(
                    IngestRequest(VanguardRealtimePlaybackDecoderFeed.EXTERNAL_TRACK_INDEX, probe, config.maxFramesPerMix, f.acceptedFrames),
                    expectedGeneration = startGeneration,
                )
                machine.dispose()
                stateAfterSecondDispose = machine.currentState

                val final = finalReply
                if (failure.get() == null && final != null) evaluate(f, s, machine, final)
            } catch (fc: FailClosed) {
                recordFailure(fc.reason)
            } catch (t: Throwable) {
                recordFailure("exception:${t.javaClass.simpleName}:${t.message}")
            } finally {
                cancelThreads()
                joinBoth()
                sessionWallMs = SystemClock.elapsedRealtime() - wallStart
            }
        }

        private fun evaluate(
            f: VanguardRealtimePlaybackDecoderFeed,
            s: VanguardRealtimePlaybackPipelineClockSyncSinkBridge,
            machine: VanguardRealtimePlaybackTransportStateMachine,
            final: Reply,
        ) {
            val fmt = format ?: return
            val declared = fmt.declaredFrameCount
            val bytesPerFrame = 2L * fmt.channelCount
            val coordinatorThreadId = Thread.currentThread().id
            val isDeadObject = scenario == Scenario.DEAD_OBJECT_CLOCK_EPOCH_RESET
            val expectedTracks = if (isDeadObject) 2 else 1
            val expectedResets = if (isDeadObject) 1 else 0
            val expectedDeadObjects = if (isDeadObject) 1L else 0L

            lanes[LANE_FORMAT_PROBE] = fmt.sampleRate > 0 && fmt.channelCount in 1..2 && declared > 0L && fmt.sourceMime.isNotBlank()
            lanes[LANE_PRE_ROLL] = preRollFrames > 0L && (preRollRingFull || preRollFrames == declared) &&
                preRollStatePrepared && startAcceptedPlaying && preRollFrames <= declared

            // ── Y6f raw timestamp checks (preserved, folded into one lane) ─
            val epochsOk = s.timestampEpochOpenCount == expectedEpochs && s.timestampEpochCloseCount == expectedEpochs &&
                s.timestampCurrentEpoch == VanguardRealtimePlaybackPipelineClockSyncSinkBridge.EPOCH_NONE
            var epochsHaveAttempts = true
            var epochOpenedAfterPlaying = true
            var epochBaselinesReset = true
            var epochFramePositionsOk = true
            var epochHeadsOk = true
            var epochAccountingOk = true
            var epochClockOk = true
            var attemptsSum = 0L
            var successesSum = 0L
            var unavailableSum = 0L
            var baselineCount = 0L
            for (e in 0 until expectedEpochs) {
                if (s.epochPollSuccesses[e] > 0L) baselineCount++
                epochsHaveAttempts = epochsHaveAttempts && s.epochPollAttempts[e] > 0L
                epochOpenedAfterPlaying = epochOpenedAfterPlaying &&
                    s.epochOpenPlayState[e] == AudioTrack.PLAYSTATE_PLAYING && s.epochOpenedAtMs[e] > 0L &&
                    s.epochClosedAtMs[e] >= s.epochOpenedAtMs[e] &&
                    (s.epochFirstPollAtMs[e] < 0L || s.epochFirstPollAtMs[e] >= s.epochOpenedAtMs[e])
                epochBaselinesReset = epochBaselinesReset && s.epochBaselineWasResetAtOpen[e] &&
                    (s.epochPollSuccesses[e] == 0L || s.epochFirstSampleWasBaseline[e])
                epochFramePositionsOk = epochFramePositionsOk && s.epochRegressionCount[e] == 0L && s.epochWrapCount[e] <= 1L &&
                    (s.epochPollSuccesses[e] == 0L ||
                        (s.epochFirstFramePosition[e] >= 0L && s.epochLastFramePosition[e] >= 0L &&
                            s.epochFirstFramePosition[e] < VanguardRealtimePlaybackPipelineClockSyncSinkBridge.FRAME_WRAP_MODULUS &&
                            s.epochLastFramePosition[e] < VanguardRealtimePlaybackPipelineClockSyncSinkBridge.FRAME_WRAP_MODULUS &&
                            (s.epochWrapCount[e] == 1L || s.epochLastFramePosition[e] >= s.epochFirstFramePosition[e])))
                epochHeadsOk = epochHeadsOk && s.epochHeadSamples[e] == s.epochPollAttempts[e] &&
                    s.epochHeadRegressionCount[e] == 0L && s.epochHeadWrapCount[e] <= 1L &&
                    (s.epochHeadSamples[e] == 0L || (s.epochFirstHead[e] >= 0L && s.epochLastHead[e] >= 0L &&
                        (s.epochHeadWrapCount[e] == 1L || s.epochLastHead[e] >= s.epochFirstHead[e])))
                epochAccountingOk = epochAccountingOk &&
                    s.epochPollAttempts[e] == s.epochPollSuccesses[e] + s.epochPollUnavailable[e]
                // Clock per epoch: opened with base = frames written at open;
                // one anchored update per success, one unavailable update per
                // failed poll; the first anchor of the epoch is ANCHORED and
                // sits at or above the base offset.
                epochClockOk = epochClockOk &&
                    s.epochClockBaseOffsetAtOpen[e] == s.epochFramesWrittenAtOpen[e] && s.epochClockBaseOffsetAtOpen[e] >= 0L &&
                    s.epochClockProvenanceAtOpen[e] == VanguardRealtimePlaybackPresentationClock.Provenance.RESET &&
                    s.epochClockAnchoredCount[e] == s.epochPollSuccesses[e] &&
                    s.epochClockUnavailableCount[e] == s.epochPollUnavailable[e] &&
                    (s.epochPollSuccesses[e] == 0L ||
                        (s.epochClockFirstAnchorOutcomeOk[e] &&
                            s.epochClockFirstAnchorContinuousFrames[e] >= s.epochClockBaseOffsetAtOpen[e]))
                attemptsSum += s.epochPollAttempts[e]
                successesSum += s.epochPollSuccesses[e]
                unavailableSum += s.epochPollUnavailable[e]
            }
            for (e in expectedEpochs until VanguardRealtimePlaybackPipelineClockSyncSinkBridge.MAX_EPOCHS) {
                // Unused epoch slots must be untouched.
                epochAccountingOk = epochAccountingOk && s.epochPollAttempts[e] == 0L && s.epochOpenedAtMs[e] < 0L &&
                    !s.epochBaselineWasResetAtOpen[e]
                epochClockOk = epochClockOk && s.epochClockBaseOffsetAtOpen[e] < 0L && s.epochClockProvenanceAtOpen[e] == null &&
                    s.epochClockAnchoredCount[e] == 0L && s.epochClockUnavailableCount[e] == 0L
            }

            lanes[LANE_TIMESTAMP_POLL_CADENCE] = s.timestampPollAttempts > 0L && s.productiveDrainPasses > 0L &&
                s.timestampMaxPollsInOnePass == 1L && s.timestampPassesPolled == s.timestampPollAttempts &&
                s.timestampPollAttempts <= s.productiveDrainPasses &&
                s.timestampPollPointReachedCount == s.timestampPollAttempts &&
                s.timestampPollsDuplicateInPass == 0L && epochsHaveAttempts &&
                s.timestampPollsAfterWriteReturned == s.timestampPollAttempts &&
                s.timestampPollsInsideWriteLoop == 0L && s.activity == Activity.TEARDOWN &&
                s.timestampPollViolations == 0L && timestampPollsAtStart == 0L &&
                s.deadObjectPollsInsideRecoveryWindow == 0L &&
                epochsOk && epochOpenedAfterPlaying && s.timestampEpochOpenedAfterPlaying &&
                epochsOpenAtStart == 0 && s.initialPlayOnSinkThread &&
                (!isDeadObject || (s.deadObjectNewTrackPlayOk && s.epochOpenedAtMs[1] >= s.epochClosedAtMs[0])) &&
                epochAccountingOk && s.timestampPollAttempts == s.timestampPollSuccesses + s.timestampPollUnavailable &&
                attemptsSum == s.timestampPollAttempts && successesSum == s.timestampPollSuccesses &&
                unavailableSum == s.timestampPollUnavailable &&
                s.timestampPollsOnSinkThread == s.timestampPollAttempts && s.timestampPollsOffSinkThread == 0L &&
                s.timestampPollExceptions <= s.timestampPollUnavailable &&
                epochFramePositionsOk && s.timestampFrameRegressionCount == 0L &&
                s.timestampWrapCount <= expectedEpochs.toLong() &&
                s.timestampFrameAdvanceCount + s.timestampFrameEqualCount + baselineCount == s.timestampPollSuccesses &&
                epochBaselinesReset && s.timestampEpochBaselineResetCount == expectedResets &&
                s.timestampCrossEpochComparisonCount == 0L && s.headCrossEpochComparisonCount == 0L &&
                epochHeadsOk && s.headRegressionCount == 0L && s.headSampleCount == s.timestampPollAttempts &&
                s.playbackHeadFinal > 0L

            // ── Presentation-clock lanes (Y7) ──────────────────────────────
            val clk = finalClockSnapshot
            val init = initialClockSnapshot
            val horizonFrames = horizonNs * fmt.sampleRate / 1_000_000_000L
            val clockAccepted = clk != null && clk.consistent && !clk.faulted && clk.rejectedCount == 0L &&
                s.clockRejectedCount == 0L && s.clockCloseRejectedAtTeardown == 0L
            val clockCountsOk = clk != null &&
                clk.updateCount == s.clockUpdateCalls &&
                clk.timestampSuccessCount == s.timestampPollSuccesses && clk.timestampUnavailableCount == s.timestampPollUnavailable &&
                clk.anchoredCount == s.clockAnchoredCount && clk.extrapolatedCount == s.clockExtrapolatedCount &&
                clk.staleCount == s.clockStaleCount && clk.noAnchorCount == s.clockNoAnchorCount &&
                clk.anchoredCount + clk.extrapolatedCount + clk.staleCount + clk.noAnchorCount +
                    clk.epochOpenCount + clk.epochCloseCount == clk.updateCount &&
                clk.extrapolatedCount + clk.staleCount + clk.noAnchorCount == clk.timestampUnavailableCount

            lanes[LANE_PRESENTATION_CLOCK_ANCHORED] = clockAccepted && clockCountsOk && clk != null &&
                s.clockWriterBoundOnSinkThread && clk.writerThreadId == s.threadId &&
                clk.sampleRate == fmt.sampleRate && clk.extrapolationHorizonNs == horizonNs &&
                clk.anchoredCount == s.timestampPollSuccesses && clk.anchoredCount > 0L &&
                clk.regressionCount == 0L && clk.wrapCount <= expectedEpochs.toLong() &&
                clk.positionFrames > 0L && clk.positionFrames <= declared + horizonFrames + 1L &&
                clk.positionUs == VanguardRealtimePlaybackPresentationClock.framesToUs(clk.positionFrames, fmt.sampleRate) &&
                epochClockOk
            lanes[LANE_PRESENTATION_CLOCK_MONOTONIC] = clockAccepted && clk != null &&
                clk.monotonicViolationCount == 0L && s.clockPositionRegressionsObservedBySink == 0L &&
                clockSampleCount > 0L && clockSamplesOnCoordinatorThread == clockSampleCount &&
                clockSamplesInconsistent == 0L && clockSamplePositionRegressions == 0L &&
                clockSampleEpochRegressions == 0L && clockSampleSequenceRegressions == 0L &&
                clockSamplePositionUsMismatches == 0L &&
                clockSampleMaxPosition <= clk.positionFrames && clk.positionFrames >= s.clockPositionFramesLastPublished &&
                clk.snapshotCallsFromOtherThreads == clockSampleCount && clk.snapshotCallsFromWriterThread == 0L
            lanes[LANE_PRESENTATION_CLOCK_EXTRAPOLATED] = clockAccepted && clockCountsOk && clk != null &&
                (clk.extrapolatedCount == 0L ||
                    (clk.maxExtrapolatedAgeNs in 0L..horizonNs && clk.maxExtrapolatedAdvanceFrames in 0L..(horizonFrames + 1L))) &&
                clk.negativeAgeCount <= clk.timestampUnavailableCount &&
                (clockSampleSeenExtrapolated == 0L || clk.extrapolatedCount > 0L)
            lanes[LANE_PRESENTATION_CLOCK_STALE_BOUND] = clockAccepted && clockCountsOk && clk != null &&
                horizonNs > 0L && horizonNs <= MAX_EXTRAPOLATION_HORIZON_MS * 1_000_000L &&
                (clk.staleCount == 0L || clk.minStaleAgeNs > horizonNs) && clk.staleAdvanceFrames == 0L &&
                (clockSampleSeenStale == 0L || clk.staleCount > 0L)
            lanes[LANE_PRESENTATION_CLOCK_EPOCH_RESET] = clockAccepted && clk != null &&
                clk.epochOpenCount == expectedEpochs && clk.epochCloseCount == expectedEpochs && !clk.epochOpen &&
                clk.epochId == expectedEpochs - 1 && clk.provenance == VanguardRealtimePlaybackPresentationClock.Provenance.RESET &&
                clk.lastOutcome == VanguardRealtimePlaybackPresentationClock.Outcome.ACCEPTED_EPOCH_CLOSED &&
                clk.resetCount == 2L * expectedEpochs &&
                s.clockEpochOpenedCalls == expectedEpochs.toLong() && s.clockEpochClosedCalls == expectedEpochs.toLong() &&
                s.clockUpdatesOutsidePollPoint == s.clockEpochOpenedCalls + s.clockEpochClosedCalls &&
                clk.baseClampCount <= (if (isDeadObject) 1L else 0L) && epochClockOk &&
                clockSampleMaxEpoch == expectedEpochs - 1 && clockSampleEpochOutOfRange == 0L &&
                (!isDeadObject || (s.epochClockBaseOffsetAtOpen[1] == s.deadObjectSinkFramesWrittenBeforeRecovery &&
                    s.epochClockBaseOffsetAtOpen[1] >= s.epochClockBaseOffsetAtOpen[0] && clockSampleSeenEpoch1Open))
            lanes[LANE_SNAPSHOT_PROVENANCE] = clockAccepted && clk != null && init != null &&
                init.consistent && init.provenance == VanguardRealtimePlaybackPresentationClock.Provenance.RESET &&
                init.epochId == VanguardRealtimePlaybackPresentationClock.EPOCH_NONE && !init.epochOpen &&
                init.positionFrames == 0L && init.positionUs == 0L && init.updateCount == 0L &&
                init.timestampSuccessCount == 0L && init.timestampUnavailableCount == 0L && init.epochOpenCount == 0 &&
                init.writerThreadId == s.threadId &&
                clockSampleProvenanceInconsistencies == 0L &&
                clockSampleSeenAnchored + clockSampleSeenExtrapolated + clockSampleSeenStale > 0L &&
                clockSampleSeenReset > 0L &&
                clockSampleSeenAnchored + clockSampleSeenExtrapolated + clockSampleSeenStale + clockSampleSeenReset == clockSampleCount &&
                clk.epochId == expectedEpochs - 1 && clk.timestampSuccessCount + clk.timestampUnavailableCount == s.timestampPollAttempts
            lanes[LANE_CLOCK_NO_FEEDBACK] = s.timestampDerivedWriteSizeAdjustments == 0L &&
                s.timestampDerivedSleeps == 0L && s.timestampDerivedDrainSkips == 0L &&
                s.timestampDerivedTransportCommands == 0L &&
                s.clockDerivedWriteSizeAdjustments == 0L && s.clockDerivedSleeps == 0L && s.clockDerivedDrainSkips == 0L &&
                s.clockDerivedTransportCommands == 0L && s.clockDerivedPacingAdjustments == 0L &&
                s.clockSnapshotsTakenOnSinkThread == 0L && clk != null &&
                clk.snapshotCallsFromWriterThread == 0L && clk.offWriterThreadCalls == 0L &&
                s.clockUpdatesAtPostWritePollPoint == s.timestampPollAttempts &&
                // Transport commands: load, prepare, start only (none after the sink started except start).
                commandsIssued == 3 && commandsIssued - transportCommandsAtSinkStart == 1 &&
                // Every drained frame was written regardless of timestamp / clock state.
                s.framesWrittenToSink == s.framesReadFromTransport && s.framesWrittenToSink == declared &&
                s.drainCalls >= s.productiveDrainPasses && final.discardedFrames == 0L
            lanes[LANE_TIMESTAMP_FAILURE_NONTERMINAL] = clockAccepted && clockCountsOk &&
                s.exitReason == VanguardRealtimePlaybackPipelineClockSyncSinkBridge.EXIT_EOS && s.eosDrainedObserved &&
                s.clockNoAnchorCount + s.clockExtrapolatedCount + s.clockStaleCount == s.timestampPollUnavailable &&
                s.timestampPollExceptions <= s.timestampPollUnavailable &&
                s.framesWrittenToSink == declared && s.timestampPollUnavailable >= 0L

            // ── Dead-object lanes (Y6e exactness) ──────────────────────────
            if (isDeadObject) {
                val remainderFrames = if (s.deadObjectUnwrittenBytesAtRecovery > 0L) s.deadObjectUnwrittenBytesAtRecovery / bytesPerFrame else -1L
                lanes[LANE_DEAD_OBJECT_INJECTED_ONCE] = s.syntheticDeadObjectInjectedCount == 1L && s.deadObjectObservedCount == 1L &&
                    s.deadObjectSinkFramesWrittenBeforeRecovery >= s.deadObjectInjectAfterFrames &&
                    s.deadObjectSinkFramesWrittenBeforeRecovery >= framesWrittenAtPhase &&
                    s.deadObjectSinkFramesWrittenBeforeRecovery >= framesWrittenAtArm && deadObjectArmedByCoordinator &&
                    deadObjectArmedOnCoordinatorThread && deadObjectsAtArm == 0L &&
                    s.deadObjectSinkFramesWrittenBeforeRecovery < declared &&
                    s.deadObjectFramesReadAtRecovery >= s.deadObjectSinkFramesWrittenBeforeRecovery &&
                    s.deadObjectUnwrittenBytesAtRecovery > 0L && s.deadObjectUnwrittenBytesAtRecovery % bytesPerFrame == 0L &&
                    s.deadObjectSliceBytesAtRecovery >= s.deadObjectUnwrittenBytesAtRecovery &&
                    s.deadObjectBufferPositionAtRecovery >= 0L
                lanes[LANE_DEAD_OBJECT_OLD_TRACK_RELEASED] = s.deadObjectOldTrackReleaseCount == 1L &&
                    s.audioTracksCreated == 2 && s.audioTracksReleased == 2 && s.releaseCount.get() == 1
                lanes[LANE_DEAD_OBJECT_NEW_TRACK_INIT_VOLUME_PLAY] = s.deadObjectNewTrackStateInitialized &&
                    s.deadObjectNewTrackBufferSizeInFrames > 0L &&
                    s.deadObjectNewTrackBufferSizeInFrames == s.frozenBufferSizeInFrames &&
                    s.deadObjectNewTrackVolumeSet && s.gainValue == config.baseVolume && s.setVolumeCalls == 2L && s.gainSetOk &&
                    s.deadObjectNewTrackPlayOk && s.deadObjectNewTrackPlayState == AudioTrack.PLAYSTATE_PLAYING
                lanes[LANE_DEAD_OBJECT_REMAINDER_RESUMED] = s.deadObjectRemainderResumedOk && remainderFrames > 0L &&
                    s.deadObjectRemainderFramesWrittenOnNewTrack == remainderFrames
                lanes[LANE_DEAD_OBJECT_NO_DOUBLE_COUNT] = s.deadObjectRemainderResumedOk && remainderFrames > 0L &&
                    s.deadObjectSinkFramesWrittenBeforeRecovery + remainderFrames == s.deadObjectSinkFramesWrittenAfterRecoveryCall &&
                    s.framesWrittenToSink == s.framesReadFromTransport && s.framesWrittenToSink == declared &&
                    s.deadObjectObservedCount == 1L && s.syntheticDeadObjectInjectedCount == 1L
            }

            // ── Shared pipeline lanes ──────────────────────────────────────
            val decoderHex = f.checksumHex
            lanes[LANE_TRANSPORT_COMPLETED] = stateAtCompletion == State.COMPLETED && final.state == NativeState.COMPLETED &&
                completedCount.get() == 1 && failedCount.get() == 0 && final.positionFrame == declared &&
                final.eosPushed && final.eosDrained && final.lastError == "none"
            lanes[LANE_SINK_WRITE_ACCOUNTING] = s.exitReason == VanguardRealtimePlaybackPipelineClockSyncSinkBridge.EXIT_EOS &&
                s.eosDrainedObserved && f.exitReason == VanguardRealtimePlaybackDecoderFeed.EXIT_EOS &&
                f.acceptedFrames == declared && s.framesReadFromTransport == declared && s.framesWrittenToSink == declared &&
                final.pushedFrames == declared && final.drainedFrames == declared && final.discardedFrames == 0L &&
                s.playbackHeadFinal > 0L && s.syntheticDeadObjectInjectedCount == expectedDeadObjects &&
                s.deadObjectObservedCount == expectedDeadObjects
            lanes[LANE_CHECKSUM_IDENTITY] = decoderHex.isNotBlank() &&
                decoderHex.equals(final.pushedChecksumHex, ignoreCase = true) &&
                decoderHex.equals(final.drainedChecksumHex, ignoreCase = true) &&
                decoderHex.equals(s.checksumHex, ignoreCase = true)
            lanes[LANE_AUDIO_TRACK_LIFECYCLE] = s.audioTrackInitOk && s.gainSetOk && s.releaseCount.get() == 1 &&
                s.audioTracksCreated == expectedTracks && s.audioTracksReleased == s.audioTracksCreated &&
                s.audioTrackOpsOffSinkThread == 0L &&
                feedJoined && sinkJoined && f.mediaReleaseCount.get() == 1L && f.mediaReleaseClean &&
                disposeCalls == 1 && stateAfterDispose == State.DISPOSED && stateAfterSecondDispose == State.DISPOSED &&
                !postIngestAfterDispose && machine.currentState == State.DISPOSED
            val scenarioOnSinkThread = if (isDeadObject) s.deadObjectRecoveryOnSinkThread else s.deadObjectObservedCount == 0L
            lanes[LANE_THREAD_OWNERSHIP] = f.ingestCallbacksOnOwner.get() > 0L && f.ingestCallbacksOffOwner.get() == 0L &&
                !f.threadIsTransportOwner && !s.threadIsTransportOwner &&
                f.threadId > 0L && s.threadId > 0L && f.threadId != s.threadId &&
                f.threadId != coordinatorThreadId && s.threadId != coordinatorThreadId &&
                s.audioTrackOpsOffSinkThread == 0L && s.timestampPollsOffSinkThread == 0L &&
                s.timestampPollsOnSinkThread == s.timestampPollAttempts && s.initialPlayOnSinkThread && scenarioOnSinkThread &&
                listenerOnOwner.get() > 0L && listenerOffOwner.get() == 0L &&
                startGeneration == prepareGeneration + 1L && !final.wrongOwnerThread
        }

        // ── Metrics ────────────────────────────────────────────────────────

        fun publishMetrics() {
            val fmt = format
            val f = feed
            val s = sink
            val machine = sm
            val final = finalReply
            metrics["scenario"] = scenario.name
            metrics["lanes"] = LinkedHashMap<String, Any?>(lanes)
            metrics["failureReason"] = failure.get() ?: ""
            metrics["sourceMime"] = fmt?.sourceMime ?: ""
            metrics["sourceDurationUs"] = fmt?.sourceDurationUs ?: -1L
            metrics["sampleRate"] = fmt?.sampleRate ?: 0
            metrics["channelCount"] = fmt?.channelCount ?: 0
            metrics["pcmEncoding"] = fmt?.pcmEncoding ?: 0
            metrics["declaredFrameCount"] = fmt?.declaredFrameCount ?: 0L
            metrics["preRollFrames"] = preRollFrames
            metrics["preRollRingFullObserved"] = preRollRingFull
            metrics["preRollPartialWriteObserved"] = preRollPartialWrite
            metrics["preRollStatePrepared"] = preRollStatePrepared
            metrics["ingestCalls"] = f?.ingestCalls ?: 0L
            metrics["staleGenerationRetries"] = f?.staleGenerationRetries ?: 0L
            metrics["transientRejects"] = f?.transientRejects ?: 0L
            metrics["decoderAcceptedFrames"] = f?.acceptedFrames ?: 0L
            metrics["eosPaddedFrames"] = f?.paddedFrames ?: 0L
            metrics["decoderExitReason"] = f?.exitReason ?: VanguardRealtimePlaybackDecoderFeed.EXIT_NOT_STARTED
            metrics["sinkExitReason"] = s?.exitReason ?: VanguardRealtimePlaybackPipelineClockSyncSinkBridge.EXIT_NOT_STARTED
            metrics["sinkActivityFinal"] = s?.activity?.name ?: "none"
            metrics["framesReadFromTransport"] = s?.framesReadFromTransport ?: 0L
            metrics["framesWrittenToSink"] = s?.framesWrittenToSink ?: 0L
            metrics["partialWriteCount"] = s?.partialWriteCount ?: 0L
            metrics["zeroWriteCount"] = s?.zeroWriteCount ?: 0L
            metrics["drainCalls"] = s?.drainCalls ?: 0L
            metrics["productiveDrainPasses"] = s?.productiveDrainPasses ?: 0L
            metrics["emptyDrainCount"] = s?.emptyDrainCount ?: 0L
            metrics["playbackHeadFinal"] = s?.playbackHeadFinal ?: 0L
            metrics["playbackHeadCaughtUp"] = s?.playbackHeadCaughtUp ?: false
            metrics["audioTrackInitOk"] = s?.audioTrackInitOk ?: false
            metrics["audioTrackBufferBytes"] = s?.audioTrackBufferBytes ?: 0
            metrics["frozenBufferSizeInFrames"] = s?.frozenBufferSizeInFrames ?: -1L
            metrics["gainValue"] = (s?.gainValue ?: 0f).toDouble()
            metrics["setVolumeCalls"] = s?.setVolumeCalls ?: 0L
            metrics["audioTracksCreated"] = s?.audioTracksCreated ?: 0
            metrics["audioTracksReleased"] = s?.audioTracksReleased ?: 0
            metrics["audioTrackReleaseCount"] = s?.releaseCount?.get() ?: 0
            metrics["audioTrackOpsOffSinkThread"] = s?.audioTrackOpsOffSinkThread ?: 0L
            metrics["initialPlayOnSinkThread"] = s?.initialPlayOnSinkThread ?: false
            metrics["mediaReleaseCount"] = f?.mediaReleaseCount?.get() ?: 0L
            metrics["mediaReleaseClean"] = f?.mediaReleaseClean ?: false
            metrics["transportDisposeCalls"] = disposeCalls
            metrics["decoderThreadJoined"] = feedJoined
            metrics["sinkThreadJoined"] = sinkJoined
            metrics["decoderThreadId"] = f?.threadId ?: -1L
            metrics["sinkThreadId"] = s?.threadId ?: -1L
            metrics["ingestCallbacksOnOwner"] = f?.ingestCallbacksOnOwner?.get() ?: 0L
            metrics["ingestCallbacksOffOwner"] = f?.ingestCallbacksOffOwner?.get() ?: 0L
            metrics["listenerCallbacksOnOwner"] = listenerOnOwner.get()
            metrics["listenerCallbacksOffOwner"] = listenerOffOwner.get()
            metrics["transportCommandsIssued"] = commandsIssued
            metrics["transportCommandsAtSinkStart"] = transportCommandsAtSinkStart
            metrics["transportPrepareGeneration"] = prepareGeneration
            metrics["transportStartGeneration"] = startGeneration
            metrics["transportGenerationFinal"] = machine?.currentGeneration ?: -1L
            metrics["transportStateBeforeDispose"] = stateBeforeDispose.name
            metrics["transportStateFinal"] = machine?.currentState?.name ?: "none"
            metrics["transportStateTransitions"] = synchronized(transitions) { transitions.toString() }
            metrics["transportCompletedCallbacks"] = completedCount.get()
            metrics["transportFailedCallbacks"] = failedCount.get()
            metrics["postIngestAfterDisposePosted"] = postIngestAfterDispose
            metrics["nativeStateFinal"] = final?.stateToken ?: "none"
            metrics["positionFrame"] = final?.positionFrame ?: -1L
            metrics["pushedFrames"] = final?.pushedFrames ?: -1L
            metrics["drainedFrames"] = final?.drainedFrames ?: -1L
            metrics["discardedFrames"] = final?.discardedFrames ?: -1L
            metrics["eosPushed"] = final?.eosPushed ?: false
            metrics["eosDrained"] = final?.eosDrained ?: false
            metrics["lastError"] = final?.lastError ?: "none"
            metrics["kotlinDecoderChecksumHex"] = f?.checksumHex ?: ""
            metrics["kotlinSinkChecksumHex"] = s?.checksumHex ?: ""
            metrics["nativePushedChecksumHex"] = final?.pushedChecksumHex ?: ""
            metrics["nativeDrainedChecksumHex"] = final?.drainedChecksumHex ?: ""
            // Sink setup / head.
            metrics["setupWaitMs"] = setupWaitMs
            metrics["setupCompleteBeforeStart"] = setupCompleteBeforeStart
            metrics["preStartDrainEmptyBeforeStart"] = preStartDrainEmptyBeforeStart
            metrics["preStartPlayState"] = s?.preStartPlayState ?: -1
            metrics["transportStateAtSetup"] = transportStateAtSetup.name
            metrics["timestampPollsAtStart"] = timestampPollsAtStart
            metrics["epochsOpenAtStart"] = epochsOpenAtStart
            metrics["startGateWaitMs"] = s?.startGateWaitMs ?: -1L
            metrics["initialWriteWaitMs"] = initialWriteWaitMs
            metrics["framesWrittenAtPhase"] = framesWrittenAtPhase
            metrics["pollAttemptsAtPhase"] = pollAttemptsAtPhase
            metrics["epochsAtPhase"] = epochsAtPhase
            metrics["deadObjectPositionLimit"] = deadObjectPositionLimit
            metrics["deadObjectArmedByCoordinator"] = deadObjectArmedByCoordinator
            metrics["deadObjectArmedOnCoordinatorThread"] = deadObjectArmedOnCoordinatorThread
            metrics["framesWrittenAtArm"] = framesWrittenAtArm
            // Timestamp telemetry.
            metrics["timestampPollAttempts"] = s?.timestampPollAttempts ?: 0L
            metrics["timestampPollSuccesses"] = s?.timestampPollSuccesses ?: 0L
            metrics["timestampPollUnavailable"] = s?.timestampPollUnavailable ?: 0L
            metrics["timestampPollExceptions"] = s?.timestampPollExceptions ?: 0L
            metrics["timestampPollsOnSinkThread"] = s?.timestampPollsOnSinkThread ?: 0L
            metrics["timestampPollsOffSinkThread"] = s?.timestampPollsOffSinkThread ?: 0L
            metrics["timestampPollPointReachedCount"] = s?.timestampPollPointReachedCount ?: 0L
            metrics["timestampPassesPolled"] = s?.timestampPassesPolled ?: 0L
            metrics["timestampMaxPollsInOnePass"] = s?.timestampMaxPollsInOnePass ?: 0L
            metrics["timestampPollsAfterWriteReturned"] = s?.timestampPollsAfterWriteReturned ?: 0L
            metrics["timestampPollsInsideWriteLoop"] = s?.timestampPollsInsideWriteLoop ?: 0L
            metrics["timestampPollsWhileHolding"] = s?.timestampPollsWhileHolding ?: 0L
            metrics["timestampPollsBetweenReleaseAndPlay"] = s?.timestampPollsBetweenReleaseAndPlay ?: 0L
            metrics["timestampPollsBeforePlaying"] = s?.timestampPollsBeforePlaying ?: 0L
            metrics["timestampPollsWithoutOpenEpoch"] = s?.timestampPollsWithoutOpenEpoch ?: 0L
            metrics["timestampPollsDuplicateInPass"] = s?.timestampPollsDuplicateInPass ?: 0L
            metrics["timestampPollsDuringCatchupOrTeardown"] = s?.timestampPollsDuringCatchupOrTeardown ?: 0L
            metrics["timestampPollsBeforeStartGate"] = s?.timestampPollsBeforeStartGate ?: 0L
            metrics["timestampPollViolations"] = s?.timestampPollViolations ?: 0L
            metrics["timestampFrameAdvanceCount"] = s?.timestampFrameAdvanceCount ?: 0L
            metrics["timestampFrameEqualCount"] = s?.timestampFrameEqualCount ?: 0L
            metrics["timestampFrameRegressionCount"] = s?.timestampFrameRegressionCount ?: 0L
            metrics["timestampWrapCount"] = s?.timestampWrapCount ?: 0L
            metrics["timestampNanoTimeAdvanceCountTelemetryOnly"] = s?.timestampNanoTimeAdvanceCount ?: 0L
            metrics["timestampNanoTimeEqualCountTelemetryOnly"] = s?.timestampNanoTimeEqualCount ?: 0L
            metrics["timestampNanoTimeNonMonotonicCountTelemetryOnly"] = s?.timestampNanoTimeNonMonotonicCount ?: 0L
            metrics["timestampCrossEpochComparisonCount"] = s?.timestampCrossEpochComparisonCount ?: 0L
            metrics["timestampEpochOpenCount"] = s?.timestampEpochOpenCount ?: 0
            metrics["timestampEpochCloseCount"] = s?.timestampEpochCloseCount ?: 0
            metrics["timestampEpochBaselineResetCount"] = s?.timestampEpochBaselineResetCount ?: 0
            metrics["timestampCurrentEpochFinal"] = s?.timestampCurrentEpoch ?: -1
            metrics["timestampEpochOpenedAfterPlaying"] = s?.timestampEpochOpenedAfterPlaying ?: false
            metrics["headSampleCount"] = s?.headSampleCount ?: 0L
            metrics["headAdvanceCount"] = s?.headAdvanceCount ?: 0L
            metrics["headEqualCount"] = s?.headEqualCount ?: 0L
            metrics["headRegressionCount"] = s?.headRegressionCount ?: 0L
            metrics["headWrapCount"] = s?.headWrapCount ?: 0L
            metrics["headCrossEpochComparisonCount"] = s?.headCrossEpochComparisonCount ?: 0L
            metrics["timestampDerivedWriteSizeAdjustments"] = s?.timestampDerivedWriteSizeAdjustments ?: 0L
            metrics["timestampDerivedSleeps"] = s?.timestampDerivedSleeps ?: 0L
            metrics["timestampDerivedDrainSkips"] = s?.timestampDerivedDrainSkips ?: 0L
            metrics["timestampDerivedTransportCommands"] = s?.timestampDerivedTransportCommands ?: 0L
            if (s != null) {
                for (e in 0 until VanguardRealtimePlaybackPipelineClockSyncSinkBridge.MAX_EPOCHS) {
                    val p = "epoch${e}_"
                    metrics["${p}openedAtMs"] = s.epochOpenedAtMs[e]
                    metrics["${p}closedAtMs"] = s.epochClosedAtMs[e]
                    metrics["${p}openPlayState"] = s.epochOpenPlayState[e]
                    metrics["${p}framesWrittenAtOpen"] = s.epochFramesWrittenAtOpen[e]
                    metrics["${p}pollAttempts"] = s.epochPollAttempts[e]
                    metrics["${p}pollSuccesses"] = s.epochPollSuccesses[e]
                    metrics["${p}pollUnavailable"] = s.epochPollUnavailable[e]
                    metrics["${p}firstPollAtMs"] = s.epochFirstPollAtMs[e]
                    metrics["${p}firstFramePosition"] = s.epochFirstFramePosition[e]
                    metrics["${p}lastFramePosition"] = s.epochLastFramePosition[e]
                    metrics["${p}frameAdvanceCount"] = s.epochFrameAdvanceCount[e]
                    metrics["${p}frameEqualCount"] = s.epochFrameEqualCount[e]
                    metrics["${p}wrapCount"] = s.epochWrapCount[e]
                    metrics["${p}regressionCount"] = s.epochRegressionCount[e]
                    metrics["${p}headSamples"] = s.epochHeadSamples[e]
                    metrics["${p}firstHead"] = s.epochFirstHead[e]
                    metrics["${p}lastHead"] = s.epochLastHead[e]
                    metrics["${p}headRegressionCount"] = s.epochHeadRegressionCount[e]
                    metrics["${p}headWrapCount"] = s.epochHeadWrapCount[e]
                    metrics["${p}baselineWasResetAtOpen"] = s.epochBaselineWasResetAtOpen[e]
                    metrics["${p}firstSampleWasBaseline"] = s.epochFirstSampleWasBaseline[e]
                }
            }
            // Presentation clock (sink-side bookkeeping + coordinator snapshots).
            metrics["clockWriterBoundOnSinkThread"] = s?.clockWriterBoundOnSinkThread ?: false
            metrics["clockUpdateCalls"] = s?.clockUpdateCalls ?: 0L
            metrics["clockUpdatesAtPostWritePollPoint"] = s?.clockUpdatesAtPostWritePollPoint ?: 0L
            metrics["clockUpdatesOutsidePollPoint"] = s?.clockUpdatesOutsidePollPoint ?: 0L
            metrics["clockEpochOpenedCalls"] = s?.clockEpochOpenedCalls ?: 0L
            metrics["clockEpochClosedCalls"] = s?.clockEpochClosedCalls ?: 0L
            metrics["clockAnchoredCount"] = s?.clockAnchoredCount ?: 0L
            metrics["clockExtrapolatedCount"] = s?.clockExtrapolatedCount ?: 0L
            metrics["clockStaleCount"] = s?.clockStaleCount ?: 0L
            metrics["clockNoAnchorCount"] = s?.clockNoAnchorCount ?: 0L
            metrics["clockRejectedCount"] = s?.clockRejectedCount ?: 0L
            metrics["clockCloseRejectedAtTeardown"] = s?.clockCloseRejectedAtTeardown ?: 0L
            metrics["clockLastOutcome"] = s?.clockLastOutcome?.name ?: "none"
            metrics["clockPositionFramesLastPublishedBySink"] = s?.clockPositionFramesLastPublished ?: -1L
            metrics["clockPositionRegressionsObservedBySink"] = s?.clockPositionRegressionsObservedBySink ?: 0L
            metrics["clockDerivedWriteSizeAdjustments"] = s?.clockDerivedWriteSizeAdjustments ?: 0L
            metrics["clockDerivedSleeps"] = s?.clockDerivedSleeps ?: 0L
            metrics["clockDerivedDrainSkips"] = s?.clockDerivedDrainSkips ?: 0L
            metrics["clockDerivedTransportCommands"] = s?.clockDerivedTransportCommands ?: 0L
            metrics["clockDerivedPacingAdjustments"] = s?.clockDerivedPacingAdjustments ?: 0L
            metrics["clockSnapshotsTakenOnSinkThread"] = s?.clockSnapshotsTakenOnSinkThread ?: 0L
            if (s != null) {
                for (e in 0 until VanguardRealtimePlaybackPipelineClockSyncSinkBridge.MAX_EPOCHS) {
                    val p = "epoch${e}_clock"
                    metrics["${p}BaseOffsetAtOpen"] = s.epochClockBaseOffsetAtOpen[e]
                    metrics["${p}ProvenanceAtOpen"] = s.epochClockProvenanceAtOpen[e]?.name ?: "none"
                    metrics["${p}FirstAnchorContinuousFrames"] = s.epochClockFirstAnchorContinuousFrames[e]
                    metrics["${p}FirstAnchorOutcomeOk"] = s.epochClockFirstAnchorOutcomeOk[e]
                    metrics["${p}AnchoredCount"] = s.epochClockAnchoredCount[e]
                    metrics["${p}UnavailableCount"] = s.epochClockUnavailableCount[e]
                }
            }
            metrics["clockSampleCount"] = clockSampleCount
            metrics["clockSamplesOnCoordinatorThread"] = clockSamplesOnCoordinatorThread
            metrics["clockSamplesInconsistent"] = clockSamplesInconsistent
            metrics["clockSamplePositionRegressions"] = clockSamplePositionRegressions
            metrics["clockSampleEpochRegressions"] = clockSampleEpochRegressions
            metrics["clockSampleSequenceRegressions"] = clockSampleSequenceRegressions
            metrics["clockSampleProvenanceInconsistencies"] = clockSampleProvenanceInconsistencies
            metrics["clockSampleEpochOutOfRange"] = clockSampleEpochOutOfRange
            metrics["clockSamplePositionUsMismatches"] = clockSamplePositionUsMismatches
            metrics["clockSampleMaxPosition"] = clockSampleMaxPosition
            metrics["clockSampleMaxEpoch"] = clockSampleMaxEpoch
            metrics["clockSampleSeenAnchored"] = clockSampleSeenAnchored
            metrics["clockSampleSeenExtrapolated"] = clockSampleSeenExtrapolated
            metrics["clockSampleSeenStale"] = clockSampleSeenStale
            metrics["clockSampleSeenReset"] = clockSampleSeenReset
            metrics["clockSampleSeenEpoch1Open"] = clockSampleSeenEpoch1Open
            metrics["clockInitialSnapshot"] = snapshotMetrics(initialClockSnapshot)
            metrics["clockFinalSnapshot"] = snapshotMetrics(finalClockSnapshot)
            // Dead object.
            metrics["deadObjectInjectAfterFrames"] = s?.deadObjectInjectAfterFrames ?: -1L
            metrics["syntheticDeadObjectInjectedCount"] = s?.syntheticDeadObjectInjectedCount ?: 0L
            metrics["deadObjectObservedCount"] = s?.deadObjectObservedCount ?: 0L
            metrics["deadObjectOldTrackReleaseCount"] = s?.deadObjectOldTrackReleaseCount ?: 0L
            metrics["deadObjectNewTrackStateInitialized"] = s?.deadObjectNewTrackStateInitialized ?: false
            metrics["deadObjectNewTrackBufferSizeInFrames"] = s?.deadObjectNewTrackBufferSizeInFrames ?: -1L
            metrics["deadObjectNewTrackVolumeSet"] = s?.deadObjectNewTrackVolumeSet ?: false
            metrics["deadObjectNewTrackPlayState"] = s?.deadObjectNewTrackPlayState ?: -1
            metrics["deadObjectNewTrackPlayOk"] = s?.deadObjectNewTrackPlayOk ?: false
            metrics["deadObjectSliceBytesAtRecovery"] = s?.deadObjectSliceBytesAtRecovery ?: -1L
            metrics["deadObjectUnwrittenBytesAtRecovery"] = s?.deadObjectUnwrittenBytesAtRecovery ?: -1L
            metrics["deadObjectBufferPositionAtRecovery"] = s?.deadObjectBufferPositionAtRecovery ?: -1L
            metrics["deadObjectSinkFramesWrittenBeforeRecovery"] = s?.deadObjectSinkFramesWrittenBeforeRecovery ?: -1L
            metrics["deadObjectSinkFramesWrittenAfterRecoveryCall"] = s?.deadObjectSinkFramesWrittenAfterRecoveryCall ?: -1L
            metrics["deadObjectRemainderFramesWrittenOnNewTrack"] = s?.deadObjectRemainderFramesWrittenOnNewTrack ?: -1L
            metrics["deadObjectFramesReadAtRecovery"] = s?.deadObjectFramesReadAtRecovery ?: -1L
            metrics["deadObjectRemainderResumedOk"] = s?.deadObjectRemainderResumedOk ?: false
            metrics["deadObjectRecoveryOnSinkThread"] = s?.deadObjectRecoveryOnSinkThread ?: false
            metrics["deadObjectRecoveryWallMs"] = s?.deadObjectRecoveryWallMs ?: -1L
            metrics["deadObjectPollsInsideRecoveryWindow"] = s?.deadObjectPollsInsideRecoveryWindow ?: 0L
            metrics["sinkThreadWallMs"] = s?.sinkThreadWallMs ?: -1L
            metrics["sessionWallMs"] = sessionWallMs
        }
    }

    // ── Snapshot -> metrics ────────────────────────────────────────────────

    private fun snapshotMetrics(snap: VanguardRealtimePlaybackPresentationClock.Snapshot?): Map<String, Any?> {
        if (snap == null) return mapOf("present" to false)
        return linkedMapOf(
            "present" to true,
            "consistent" to snap.consistent,
            "sequence" to snap.sequence,
            "provenance" to snap.provenance.name,
            "epochId" to snap.epochId,
            "epochOpen" to snap.epochOpen,
            "epochBaseOffsetFrames" to snap.epochBaseOffsetFrames,
            "positionFrames" to snap.positionFrames,
            "positionUs" to snap.positionUs,
            "anchorContinuousFrames" to snap.anchorContinuousFrames,
            "anchorNanoTime" to snap.anchorNanoTime,
            "lastRawFrame" to snap.lastRawFrame,
            "lastUnwrappedFrame" to snap.lastUnwrappedFrame,
            "lastHead" to snap.lastHead,
            "publishedAtNs" to snap.publishedAtNs,
            "lastAgeNs" to snap.lastAgeNs,
            "sampleRate" to snap.sampleRate,
            "extrapolationHorizonNs" to snap.extrapolationHorizonNs,
            "faulted" to snap.faulted,
            "lastOutcome" to snap.lastOutcome.name,
            "updateCount" to snap.updateCount,
            "timestampSuccessCount" to snap.timestampSuccessCount,
            "timestampUnavailableCount" to snap.timestampUnavailableCount,
            "anchoredCount" to snap.anchoredCount,
            "extrapolatedCount" to snap.extrapolatedCount,
            "staleCount" to snap.staleCount,
            "noAnchorCount" to snap.noAnchorCount,
            "resetCount" to snap.resetCount,
            "epochOpenCount" to snap.epochOpenCount,
            "epochCloseCount" to snap.epochCloseCount,
            "wrapCount" to snap.wrapCount,
            "regressionCount" to snap.regressionCount,
            "rejectedCount" to snap.rejectedCount,
            "anchorClampCount" to snap.anchorClampCount,
            "baseClampCount" to snap.baseClampCount,
            "negativeAgeCount" to snap.negativeAgeCount,
            "nanoTimeNonMonotonicCount" to snap.nanoTimeNonMonotonicCount,
            "maxExtrapolatedAgeNs" to snap.maxExtrapolatedAgeNs,
            "minStaleAgeNs" to snap.minStaleAgeNs,
            "maxExtrapolatedAdvanceFrames" to snap.maxExtrapolatedAdvanceFrames,
            "staleAdvanceFrames" to snap.staleAdvanceFrames,
            "monotonicViolationCount" to snap.monotonicViolationCount,
            "offWriterThreadCalls" to snap.offWriterThreadCalls,
            "snapshotCallsFromWriterThread" to snap.snapshotCallsFromWriterThread,
            "snapshotCallsFromOtherThreads" to snap.snapshotCallsFromOtherThreads,
            "writerThreadId" to snap.writerThreadId,
        )
    }

    // ── Synthetic clock self-check (coordinator thread, no AudioTrack) ─────
    //
    // Drives standalone VanguardRealtimePlaybackPresentationClock instances
    // with scripted inputs so every branch the device may never exercise is
    // still proven deterministically: unwrap + one wrap, bounded
    // extrapolation, STALE hold past the horizon, anchor clamp (monotonic),
    // strict regression fail-closed + fault latch, epoch close/open with
    // base-offset continuity, rejection tokens, off-writer-thread rejection
    // and any-thread consistent snapshots.
    private class ClockSelfCheck(private val horizonNs: Long) {
        class Outcome(val checks: Map<String, Boolean>, val metrics: Map<String, Any?>) {
            val allOk: Boolean get() = checks.values.all { it }
            val firstFailure: String get() = checks.entries.firstOrNull { !it.value }?.key ?: "none"
            fun laneHeld(lane: String): Boolean = when (lane) {
                LANE_PRESENTATION_CLOCK_ANCHORED -> held("initial", "rejectBeforeOpen", "open", "anchor", "wrap")
                LANE_PRESENTATION_CLOCK_MONOTONIC -> held("clamp", "monotonicAll", "readerThread")
                LANE_PRESENTATION_CLOCK_EXTRAPOLATED -> held("noAnchor", "extrapolate", "atHorizon")
                LANE_PRESENTATION_CLOCK_STALE_BOUND -> held("stale", "staleHold")
                LANE_PRESENTATION_CLOCK_EPOCH_RESET -> held("epochClose", "epochReopen", "epochContinuity", "epochRejections")
                LANE_SNAPSHOT_PROVENANCE -> held("provenanceAll", "initial", "counts")
                LANE_TIMESTAMP_FAILURE_NONTERMINAL -> held("noAnchor", "extrapolate", "stale", "staleHold", "regression", "faultLatch")
                else -> true
            }
            private fun held(vararg keys: String): Boolean = keys.all { checks[it] == true }
        }

        private val checks = linkedMapOf<String, Boolean>()
        private val metrics = linkedMapOf<String, Any?>()
        private var monotonicViolations = 0L
        private var provenanceViolations = 0L
        private var snapshotsTaken = 0L
        private var lastPositionByInstance = HashMap<Int, Long>()

        private fun snap(id: Int, c: VanguardRealtimePlaybackPresentationClock): VanguardRealtimePlaybackPresentationClock.Snapshot {
            val s = c.snapshot()
            snapshotsTaken++
            val last = lastPositionByInstance[id] ?: -1L
            if (s.positionFrames < last) monotonicViolations++
            if (s.positionFrames > last) lastPositionByInstance[id] = s.positionFrames
            if (!s.consistent) monotonicViolations++
            val anchored = s.anchorContinuousFrames >= 0L
            val ok = when (s.provenance) {
                VanguardRealtimePlaybackPresentationClock.Provenance.ANCHORED -> anchored && s.epochOpen
                VanguardRealtimePlaybackPresentationClock.Provenance.EXTRAPOLATED -> anchored && s.epochOpen && s.lastAgeNs in 0L..horizonNs
                VanguardRealtimePlaybackPresentationClock.Provenance.STALE -> anchored && s.epochOpen && s.lastAgeNs > horizonNs
                VanguardRealtimePlaybackPresentationClock.Provenance.RESET -> !anchored
            }
            if (!ok) provenanceViolations++
            if (s.positionUs != VanguardRealtimePlaybackPresentationClock.framesToUs(s.positionFrames, s.sampleRate)) provenanceViolations++
            return s
        }

        fun run(): Outcome {
            try {
                script()
            } catch (t: Throwable) {
                checks["exception"] = false
                metrics["exception"] = "${t.javaClass.simpleName}:${t.message}"
            }
            checks["monotonicAll"] = monotonicViolations == 0L
            checks["provenanceAll"] = provenanceViolations == 0L
            metrics["monotonicViolations"] = monotonicViolations
            metrics["provenanceViolations"] = provenanceViolations
            metrics["snapshotsTaken"] = snapshotsTaken
            metrics["checks"] = LinkedHashMap<String, Any?>(checks)
            return Outcome(LinkedHashMap(checks), LinkedHashMap(metrics))
        }

        private fun script() {
            val sr = SELF_CHECK_SAMPLE_RATE
            val modulus = VanguardRealtimePlaybackPresentationClock.FRAME_WRAP_MODULUS
            val t0 = 1_000_000_000L
            val c = VanguardRealtimePlaybackPresentationClock(sr, horizonNs)

            val s0 = snap(0, c)
            checks["initial"] = s0.consistent && s0.provenance == ClockProvenance.RESET &&
                s0.epochId == VanguardRealtimePlaybackPresentationClock.EPOCH_NONE && !s0.epochOpen &&
                s0.positionFrames == 0L && s0.positionUs == 0L && s0.updateCount == 0L && !s0.faulted &&
                s0.sampleRate == sr && s0.extrapolationHorizonNs == horizonNs &&
                s0.writerThreadId == VanguardRealtimePlaybackPresentationClock.WRITER_UNBOUND

            checks["rejectBeforeOpen"] = c.observeTimestamp(0, 10L, t0) == ClockOutcome.REJECTED_NO_OPEN_EPOCH &&
                c.observeTimestampUnavailable(0, 0L, t0) == ClockOutcome.REJECTED_NO_OPEN_EPOCH &&
                c.epochClosed(0, t0) == ClockOutcome.REJECTED_NO_OPEN_EPOCH &&
                c.epochOpened(-1, 0L, t0) == ClockOutcome.REJECTED_INVALID_EPOCH &&
                c.epochOpened(0, -1L, t0) == ClockOutcome.REJECTED_BASE_INVALID &&
                snap(0, c).let { it.rejectedCount == 5L && it.updateCount == 5L && !it.faulted && it.provenance == ClockProvenance.RESET }

            val open = c.epochOpened(0, 0L, t0)
            val s1 = snap(0, c)
            checks["open"] = open == ClockOutcome.ACCEPTED_EPOCH_OPENED && s1.provenance == ClockProvenance.RESET && s1.epochId == 0 && s1.epochOpen &&
                s1.epochBaseOffsetFrames == 0L && s1.epochOpenCount == 1 && s1.resetCount == 1L &&
                s1.writerThreadId == Thread.currentThread().id &&
                c.epochOpened(1, 0L, t0) == ClockOutcome.REJECTED_EPOCH_ALREADY_OPEN &&
                c.observeTimestamp(1, 0L, t0) == ClockOutcome.REJECTED_EPOCH_MISMATCH &&
                c.observeTimestampUnavailable(1, 0L, t0) == ClockOutcome.REJECTED_EPOCH_MISMATCH &&
                c.epochClosed(1, t0) == ClockOutcome.REJECTED_EPOCH_MISMATCH &&
                c.observeTimestamp(0, modulus, t0) == ClockOutcome.REJECTED_RAW_OUT_OF_RANGE &&
                c.observeTimestamp(0, -1L, t0) == ClockOutcome.REJECTED_RAW_OUT_OF_RANGE

            val na = c.observeTimestampUnavailable(0, 5L, t0)
            val s2 = snap(0, c)
            checks["noAnchor"] = na == ClockOutcome.ACCEPTED_NO_ANCHOR && s2.provenance == ClockProvenance.RESET && s2.positionFrames == 0L &&
                s2.lastHead == 5L && s2.noAnchorCount == 1L && s2.timestampUnavailableCount == 1L && s2.lastAgeNs == -1L

            val rawA = 0xFFFF_FF00L
            val a = c.observeTimestamp(0, rawA, t0)
            val s3 = snap(0, c)
            checks["anchor"] = a == ClockOutcome.ACCEPTED_ANCHORED && s3.provenance == ClockProvenance.ANCHORED && s3.positionFrames == rawA &&
                s3.positionUs == rawA * 1_000_000L / sr && s3.anchorContinuousFrames == rawA && s3.anchorNanoTime == t0 &&
                s3.anchoredCount == 1L && s3.timestampSuccessCount == 1L && s3.lastAgeNs == 0L && s3.lastRawFrame == rawA

            val rawB = 0x100L
            val tB = t0 + 10_000_000L
            val w = c.observeTimestamp(0, rawB, tB)
            val s4 = snap(0, c)
            val posB = modulus + rawB
            checks["wrap"] = w == ClockOutcome.ACCEPTED_ANCHORED && s4.provenance == ClockProvenance.ANCHORED && s4.positionFrames == posB &&
                s4.wrapCount == 1L && s4.lastUnwrappedFrame == posB && s4.lastRawFrame == rawB && s4.anchorNanoTime == tB &&
                s4.regressionCount == 0L && s4.anchorClampCount == 0L

            val ageE = horizonNs / 2L
            val advE = ageE * sr / 1_000_000_000L
            val e = c.observeTimestampUnavailable(0, 7L, tB + ageE)
            val s5 = snap(0, c)
            checks["extrapolate"] = e == ClockOutcome.ACCEPTED_EXTRAPOLATED && s5.provenance == ClockProvenance.EXTRAPOLATED &&
                s5.positionFrames == posB + advE && s5.lastAgeNs == ageE && s5.maxExtrapolatedAgeNs == ageE &&
                s5.maxExtrapolatedAdvanceFrames == advE && s5.extrapolatedCount == 1L && s5.anchorContinuousFrames == posB &&
                s5.lastHead == 7L && advE > 0L

            val advH = horizonNs * sr / 1_000_000_000L
            val h = c.observeTimestampUnavailable(0, 8L, tB + horizonNs)
            val s6 = snap(0, c)
            val posE = posB + advH
            checks["atHorizon"] = h == ClockOutcome.ACCEPTED_EXTRAPOLATED && s6.provenance == ClockProvenance.EXTRAPOLATED &&
                s6.positionFrames == posE && s6.lastAgeNs == horizonNs && s6.maxExtrapolatedAgeNs == horizonNs &&
                s6.extrapolatedCount == 2L && s6.staleCount == 0L

            val st = c.observeTimestampUnavailable(0, 9L, tB + horizonNs + 1L)
            val s7 = snap(0, c)
            checks["stale"] = st == ClockOutcome.ACCEPTED_STALE && s7.provenance == ClockProvenance.STALE && s7.positionFrames == posE &&
                s7.lastAgeNs == horizonNs + 1L && s7.minStaleAgeNs == horizonNs + 1L && s7.staleCount == 1L &&
                s7.staleAdvanceFrames == 0L && s7.extrapolatedCount == 2L

            val far = tB + 10_000_000_000L
            val st2 = c.observeTimestampUnavailable(0, 10L, far)
            val s8 = snap(0, c)
            checks["staleHold"] = st2 == ClockOutcome.ACCEPTED_STALE && s8.provenance == ClockProvenance.STALE && s8.positionFrames == posE &&
                s8.staleCount == 2L && s8.minStaleAgeNs == horizonNs + 1L && s8.lastAgeNs == far - tB

            // A real anchor below the extrapolated position clamps (position held).
            val rawC = rawB + 1L
            val cl = c.observeTimestamp(0, rawC, far)
            val s9 = snap(0, c)
            checks["clamp"] = cl == ClockOutcome.ACCEPTED_ANCHORED && s9.provenance == ClockProvenance.ANCHORED && s9.positionFrames == posE &&
                s9.anchorContinuousFrames == modulus + rawC && s9.anchorClampCount == 1L && s9.monotonicViolationCount == 0L &&
                s9.anchoredCount == 3L
            // A later anchor above it advances again.
            val rawD = rawC + advH + 1_000L
            val ad = c.observeTimestamp(0, rawD, far + 1L)
            val s10 = snap(0, c)
            checks["clampAdvance"] = ad == ClockOutcome.ACCEPTED_ANCHORED && s10.positionFrames == modulus + rawD && s10.anchorClampCount == 1L

            // Strict regression: fails closed and latches.
            val rg = c.observeTimestamp(0, rawD - 1L, far + 2L)
            val s11 = snap(0, c)
            checks["regression"] = rg == ClockOutcome.REJECTED_FRAME_REGRESSION && s11.faulted && s11.regressionCount == 1L &&
                s11.positionFrames == modulus + rawD && s11.provenance == ClockProvenance.ANCHORED
            checks["faultLatch"] = c.observeTimestampUnavailable(0, 0L, far + 3L) == ClockOutcome.REJECTED_FAULTED &&
                c.observeTimestamp(0, rawD, far + 3L) == ClockOutcome.REJECTED_FAULTED &&
                c.epochOpened(1, 0L, far + 3L) == ClockOutcome.REJECTED_FAULTED &&
                snap(0, c).let { it.faulted && it.positionFrames == modulus + rawD && it.rejectedCount == 15L }

            // Epoch reset on a fresh instance: continuity by base offset only.
            val d = VanguardRealtimePlaybackPresentationClock(sr, horizonNs)
            val t1 = t0 + 500_000_000L
            val d0 = d.epochOpened(0, 0L, t0) == ClockOutcome.ACCEPTED_EPOCH_OPENED && d.observeTimestamp(0, 1_000L, t0) == ClockOutcome.ACCEPTED_ANCHORED
            val cls = d.epochClosed(0, t1)
            val ds1 = snap(1, d)
            checks["epochClose"] = d0 && cls == ClockOutcome.ACCEPTED_EPOCH_CLOSED && ds1.provenance == ClockProvenance.RESET && !ds1.epochOpen &&
                ds1.positionFrames == 1_000L && ds1.epochCloseCount == 1 && ds1.anchorContinuousFrames < 0L && ds1.epochId == 0
            checks["epochRejections"] = d.observeTimestamp(0, 2_000L, t1) == ClockOutcome.REJECTED_NO_OPEN_EPOCH &&
                d.observeTimestampUnavailable(0, 0L, t1) == ClockOutcome.REJECTED_NO_OPEN_EPOCH &&
                d.epochOpened(0, 5_000L, t1) == ClockOutcome.REJECTED_EPOCH_ORDER &&
                d.epochOpened(1, -1L, t1) == ClockOutcome.REJECTED_BASE_INVALID &&
                snap(1, d).let { !it.faulted && it.rejectedCount == 4L && it.positionFrames == 1_000L }
            // Base below the published position is clamped up; a raw 0 on
            // the new epoch then lands exactly on the held position.
            val ro = d.epochOpened(1, 500L, t1)
            val ds2 = snap(1, d)
            val rn = d.observeTimestampUnavailable(1, 0L, t1)
            val ds3 = snap(1, d)
            val ra = d.observeTimestamp(1, 0L, t1)
            val ds4 = snap(1, d)
            val rb = d.observeTimestamp(1, 250L, t1 + 5_000_000L)
            val ds5 = snap(1, d)
            checks["epochReopen"] = ro == ClockOutcome.ACCEPTED_EPOCH_OPENED && ds2.provenance == ClockProvenance.RESET && ds2.epochId == 1 && ds2.epochOpen &&
                ds2.epochBaseOffsetFrames == 1_000L && ds2.baseClampCount == 1L && ds2.positionFrames == 1_000L &&
                rn == ClockOutcome.ACCEPTED_NO_ANCHOR && ds3.provenance == ClockProvenance.RESET && ds3.positionFrames == 1_000L &&
                ra == ClockOutcome.ACCEPTED_ANCHORED && ds4.provenance == ClockProvenance.ANCHORED && ds4.positionFrames == 1_000L &&
                ds4.anchorContinuousFrames == 1_000L && ds4.lastRawFrame == 0L &&
                rb == ClockOutcome.ACCEPTED_ANCHORED && ds5.positionFrames == 1_250L && ds5.epochOpenCount == 2
            // Epoch 2 with a base above: continuity is base + raw.
            val c2 = d.epochClosed(1, t1 + 6_000_000L) == ClockOutcome.ACCEPTED_EPOCH_CLOSED
            val o2 = d.epochOpened(2, 5_000L, t1 + 6_000_000L)
            val ds6 = snap(1, d)
            val a2 = d.observeTimestamp(2, 0L, t1 + 6_000_000L)
            val ds7 = snap(1, d)
            checks["epochContinuity"] = c2 && o2 == ClockOutcome.ACCEPTED_EPOCH_OPENED && ds6.epochBaseOffsetFrames == 5_000L &&
                ds6.baseClampCount == 1L && ds6.positionFrames == 1_250L && ds6.provenance == ClockProvenance.RESET &&
                a2 == ClockOutcome.ACCEPTED_ANCHORED && ds7.positionFrames == 5_000L && ds7.epochId == 2 && ds7.epochOpenCount == 3 &&
                ds7.epochCloseCount == 2 && ds7.resetCount == 5L
            val fin = snap(1, d)
            checks["counts"] = fin.anchoredCount + fin.extrapolatedCount + fin.staleCount + fin.noAnchorCount +
                fin.epochOpenCount + fin.epochCloseCount + fin.rejectedCount == fin.updateCount &&
                fin.timestampSuccessCount == fin.anchoredCount && fin.timestampUnavailableCount == fin.noAnchorCount &&
                fin.anchoredCount == 4L && fin.noAnchorCount == 1L

            // Off-writer-thread write is rejected; any-thread snapshot is consistent and identical.
            val helperOutcome = AtomicReference<VanguardRealtimePlaybackPresentationClock.Outcome?>(null)
            val helperSnap = AtomicReference<VanguardRealtimePlaybackPresentationClock.Snapshot?>(null)
            val helper = Thread({
                helperOutcome.set(d.observeTimestamp(2, 10L, t1 + 7_000_000L))
                helperSnap.set(d.snapshot())
            }, "Y7ClockSelfCheckReader")
            helper.start()
            try {
                helper.join(SELF_CHECK_HELPER_JOIN_MS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            val after = snap(1, d)
            val hs = helperSnap.get()
            checks["readerThread"] = !helper.isAlive && helperOutcome.get() == ClockOutcome.REJECTED_OFF_WRITER_THREAD &&
                hs != null && hs.consistent && hs.positionFrames == 5_000L && hs.sequence == after.sequence &&
                hs.provenance == ClockProvenance.ANCHORED && after.offWriterThreadCalls == 1L && after.positionFrames == 5_000L &&
                after.snapshotCallsFromOtherThreads == 1L && after.snapshotCallsFromWriterThread > 0L

            metrics["horizonNs"] = horizonNs
            metrics["sampleRate"] = sr
            metrics["extrapolatedAdvanceAtHalfHorizon"] = advE
            metrics["extrapolatedAdvanceAtHorizon"] = advH
            metrics["instanceA"] = snapshotMetricsStatic(snap(0, c))
            metrics["instanceB"] = snapshotMetricsStatic(after)
        }

        private fun snapshotMetricsStatic(s: VanguardRealtimePlaybackPresentationClock.Snapshot): Map<String, Any?> = linkedMapOf(
            "provenance" to s.provenance.name,
            "epochId" to s.epochId,
            "positionFrames" to s.positionFrames,
            "positionUs" to s.positionUs,
            "updateCount" to s.updateCount,
            "rejectedCount" to s.rejectedCount,
            "faulted" to s.faulted,
            "wrapCount" to s.wrapCount,
            "regressionCount" to s.regressionCount,
            "anchorClampCount" to s.anchorClampCount,
            "baseClampCount" to s.baseClampCount,
            "maxExtrapolatedAgeNs" to s.maxExtrapolatedAgeNs,
            "minStaleAgeNs" to s.minStaleAgeNs,
            "offWriterThreadCalls" to s.offWriterThreadCalls,
        )
    }

    // ── Result assembly ────────────────────────────────────────────────────

    private fun firstFailedLane(): String = REQUIRED_LANES.firstOrNull { lanes[it] != true } ?: "none"

    private fun buildResult(pass: Boolean, failureReason: String): Result {
        val laneMap = linkedMapOf<String, Boolean>()
        for (lane in REQUIRED_LANES) laneMap[lane] = pass || (lanes[lane] == true)
        laneMap[LANE_CANONICAL] = pass
        val status = if (pass) "pass" else "fail"
        val metricMap = LinkedHashMap<String, Any?>(metrics)
        metricMap["failureReason"] = failureReason
        metricMap["cancelled"] = cancelled.get()
        return Result(
            pass = pass,
            status = status,
            failureReason = failureReason,
            proofBoundary = PROOF_BOUNDARY,
            lanes = laneMap,
            metrics = metricMap,
            raw = "pass=$pass;status=$status;failureReason=$failureReason",
        )
    }
}
