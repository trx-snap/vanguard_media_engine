package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioTrack
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.NativeState
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.Activity
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.IngestRequest
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

// ── VanguardRealtimePlaybackPipelineTimestampStabilizationCoordinator (P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-TIMESTAMP-STABILIZATION, Y6f) ─
//
// The ONLY transport command owner of the Y6f timestamp-stabilization
// diagnostic over the committed Y6a/Y6b pipeline shape:
//
//   MediaExtractor/MediaCodec  ->  Y5a external ingest seam  ->  Y1 native
//   ([VanguardRealtimePlaybackDecoderFeed], decode thread, unchanged)
//   transport (owner HandlerThread inside the state machine)  ->
//   non-zero-gain AudioTrack MODE_STREAM
//   ([VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge], sink thread)
//
// Thread model: the decoder feed thread only posts generation-pinned
// ingest; the sink thread only drains, owns every AudioTrack call
// (create / recreate / setVolume / play / write / getTimestamp /
// playbackHeadPosition / release) and the one synthetic dead object; the
// state machine is the only JNI caller; this coordinator (the caller's
// worker thread) issues transport commands (load, prepare, start), waits/
// joins and aggregates. It never calls an AudioTrack method.
//
// Two scenarios run sequentially in one smoke, each with its own feed,
// transport, sink and AudioTrack. Shared head: format probe -> pre-roll ->
// sink setup on the sink thread (track created, base volume 0.5, empty
// pre-start drain point) BEFORE transport start -> start -> first positive
// sink write + play() (epoch 0 opens) -> >= phaseFrames.
//   FORWARD_PLAYTHROUGH_TIMESTAMP:  single epoch to EOS. One getTimestamp
//                            poll per drain pass after the write returned;
//                            per-epoch unsigned-32 framePosition non-
//                            decreasing (equal allowed, one wrap tolerated,
//                            strict regression fails closed); transport
//                            COMPLETED; 4-way checksum identity.
//   DEAD_OBJECT_EPOCH_RESET_TIMESTAMP: the sink thread substitutes exactly
//                            one synthetic ERROR_DEAD_OBJECT for an
//                            in-flight write once >= 2 * phaseFrames were
//                            written (zero bytes consumed), recovers inline
//                            (epoch 0 closed -> release old once -> same-
//                            parameter recreate -> STATE_INITIALIZED ->
//                            setVolume -> play() -> epoch 1 opens with a
//                            fresh baseline -> same remainder), drains to
//                            EOS, transport COMPLETED, full checksum
//                            identity, no dropped / double-counted frame,
//                            no cross-epoch framePosition comparison.
//
// getTimestamp() returning false never fails a lane (attempts/successes
// recorded, success floor zero). Nothing timestamp-derived feeds back into
// write size, sleeps, drain gating, transport commands, pacing, checksum or
// native state.
//
// Teardown per scenario: feed cancel/stop, sink exit (AudioTrack released
// once on the sink thread), state machine disposed once. First failure
// wins; joins are bounded.
//
// Diagnostic only. No HAL / output latency, presentation clock, A/V sync,
// timestamp-derived position or seek accuracy, clock ownership,
// getTimestamp availability SLA, drift correction, latency / glitch /
// loudness / SNR, real OS fault forcing, seamless hot-swap, seek / flush,
// product / editor / app / ConnectsApp, iOS, streaming / cache or C++ /
// JNI change lives here.
class VanguardRealtimePlaybackPipelineTimestampStabilizationCoordinator {

    enum class Scenario { FORWARD_PLAYTHROUGH_TIMESTAMP, DEAD_OBJECT_EPOCH_RESET_TIMESTAMP }

    data class Config(
        val sourcePath: String,
        val maxDurationSec: Double = 3.0,
        val maxFramesPerMix: Int = 256,
        val baseVolume: Float = VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.DEFAULT_BASE_VOLUME,
        val deadlineMs: Long = 60_000L,
        val phaseFrames: Long = DEFAULT_PHASE_FRAMES,
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
            "realtime_playback_pipeline_timestamp_stabilization_diagnostic_only_real_mediaextractor_mediacodec_" +
                "to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_" +
                "sink_thread_owns_audiotrack_and_gettimestamp_coordinator_owns_transport_commands_" +
                "one_poll_per_drain_pass_after_write_epoch_opens_after_playing_" +
                "per_epoch_unsigned32_frame_position_nondecreasing_one_wrap_tolerated_no_cross_epoch_comparison_" +
                "synthetic_dead_object_epoch_reset_only_gettimestamp_false_never_fails_timestamp_inert_telemetry_" +
                "no_hal_output_latency_no_presentation_clock_no_av_sync_no_timestamp_derived_position_no_seek_accuracy_" +
                "no_clock_ownership_no_gettimestamp_availability_sla_no_drift_correction_" +
                "no_latency_no_glitch_no_loudness_no_snr_no_real_os_fault_forcing_no_seamless_hot_swap_no_seek_no_flush_" +
                "no_product_no_editor_no_app_wiring_no_connectsapp_no_ios_no_streaming_no_cache_no_cpp_no_jni_changes"

        const val DEFAULT_PHASE_FRAMES = 2_048L

        const val LANE_FORMAT_PROBE = "formatProbeOk"
        const val LANE_PRE_ROLL = "preRollOk"
        const val LANE_PRE_START_DRAIN_EMPTY = "preStartDrainEmptyOk"
        const val LANE_TIMESTAMP_POLL_CADENCE = "timestampPollCadenceOk"
        const val LANE_TIMESTAMP_POLL_AFTER_WRITE_ONLY = "timestampPollAfterWriteOnlyOk"
        const val LANE_TIMESTAMP_NO_POLL_WHILE_PARKED = "timestampNoPollWhileParkedOk"
        const val LANE_TIMESTAMP_WARMUP_GATED_ON_PLAYING = "timestampWarmupGatedOnPlayingOk"
        const val LANE_TIMESTAMP_POLL_ACCOUNTING = "timestampPollAccountingOk"
        const val LANE_EPOCH_FRAME_POSITION_MONOTONIC = "epochFramePositionMonotonicOk"
        const val LANE_EPOCH_BASELINE_RESET = "epochBaselineResetOk"
        const val LANE_NO_CROSS_EPOCH_COMPARISON = "noCrossEpochComparisonOk"
        const val LANE_PLAYBACK_HEAD_MONOTONIC_PER_EPOCH = "playbackHeadMonotonicPerEpochOk"
        const val LANE_TIMESTAMP_INERT_NO_FEEDBACK = "timestampInertNoFeedbackOk"
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
            LANE_TIMESTAMP_POLL_AFTER_WRITE_ONLY,
            LANE_TIMESTAMP_NO_POLL_WHILE_PARKED,
            LANE_TIMESTAMP_WARMUP_GATED_ON_PLAYING,
            LANE_TIMESTAMP_POLL_ACCOUNTING,
            LANE_EPOCH_FRAME_POSITION_MONOTONIC,
            LANE_EPOCH_BASELINE_RESET,
            LANE_NO_CROSS_EPOCH_COMPARISON,
            LANE_PLAYBACK_HEAD_MONOTONIC_PER_EPOCH,
            LANE_TIMESTAMP_INERT_NO_FEEDBACK,
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
        // scenario but are evaluated inside each session).
        private val SHARED_LANES = listOf(
            LANE_FORMAT_PROBE, LANE_PRE_ROLL, LANE_PRE_START_DRAIN_EMPTY,
            LANE_TIMESTAMP_POLL_CADENCE, LANE_TIMESTAMP_POLL_AFTER_WRITE_ONLY, LANE_TIMESTAMP_NO_POLL_WHILE_PARKED,
            LANE_TIMESTAMP_WARMUP_GATED_ON_PLAYING, LANE_TIMESTAMP_POLL_ACCOUNTING,
            LANE_EPOCH_FRAME_POSITION_MONOTONIC, LANE_EPOCH_BASELINE_RESET, LANE_NO_CROSS_EPOCH_COMPARISON,
            LANE_PLAYBACK_HEAD_MONOTONIC_PER_EPOCH, LANE_TIMESTAMP_INERT_NO_FEEDBACK,
            LANE_SINK_WRITE_ACCOUNTING, LANE_CHECKSUM_IDENTITY, LANE_TRANSPORT_COMPLETED,
            LANE_AUDIO_TRACK_LIFECYCLE, LANE_THREAD_OWNERSHIP,
        )
        private val DEAD_OBJECT_LANES = listOf(
            LANE_DEAD_OBJECT_INJECTED_ONCE, LANE_DEAD_OBJECT_OLD_TRACK_RELEASED,
            LANE_DEAD_OBJECT_NEW_TRACK_INIT_VOLUME_PLAY, LANE_DEAD_OBJECT_REMAINDER_RESUMED,
            LANE_DEAD_OBJECT_NO_DOUBLE_COUNT,
        )

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
        if (cancelled.get()) throw FailClosed("cancelled")
        val deadlineAtMs = SystemClock.elapsedRealtime() + config.deadlineMs
        metrics["maxDurationSec"] = config.maxDurationSec
        metrics["maxFramesPerMix"] = config.maxFramesPerMix
        metrics["baseVolume"] = config.baseVolume.toDouble()
        metrics["deadlineMs"] = config.deadlineMs
        metrics["phaseFrames"] = config.phaseFrames
        metrics["coordinatorThreadId"] = Thread.currentThread().id
        metrics["scenarioOrder"] = Scenario.entries.map { it.name }
        metrics["frameWrapModulus"] = VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.FRAME_WRAP_MODULUS
        metrics["frameWrapForwardMax"] = VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.FRAME_WRAP_FORWARD_MAX
        lanes[LANE_PROOF_BOUNDARY] = true

        val results = LinkedHashMap<Scenario, Session>()
        val wallStart = SystemClock.elapsedRealtime()
        try {
            for (scenario in Scenario.entries) {
                if (cancelled.get()) throw FailClosed("cancelled")
                val session = Session(config, scenario, deadlineAtMs)
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
        for (lane in DEAD_OBJECT_LANES) lanes[lane] = laneOf(results[Scenario.DEAD_OBJECT_EPOCH_RESET_TIMESTAMP], lane)
        // Aggregate timestamp telemetry across both scenarios (informational).
        var attempts = 0L
        var successes = 0L
        var unavailable = 0L
        var regressions = 0L
        var wraps = 0L
        var violations = 0L
        for (s in all) {
            val sink = s?.sink ?: continue
            attempts += sink.timestampPollAttempts
            successes += sink.timestampPollSuccesses
            unavailable += sink.timestampPollUnavailable
            regressions += sink.timestampFrameRegressionCount
            wraps += sink.timestampWrapCount
            violations += sink.timestampPollViolations
        }
        metrics["timestampPollAttemptsTotal"] = attempts
        metrics["timestampPollSuccessesTotal"] = successes
        metrics["timestampPollUnavailableTotal"] = unavailable
        metrics["timestampFrameRegressionTotal"] = regressions
        metrics["timestampWrapTotal"] = wraps
        metrics["timestampPollViolationsTotal"] = violations
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
        @Volatile var sink: VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge? = null

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
                Scenario.FORWARD_PLAYTHROUGH_TIMESTAMP -> emptyList()
                Scenario.DEAD_OBJECT_EPOCH_RESET_TIMESTAMP -> DEAD_OBJECT_LANES
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
                s.exitReason != VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.EXIT_RUNNING &&
                s.exitReason != VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.EXIT_EOS &&
                s.exitReason != VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.EXIT_NOT_STARTED
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
            s: VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge,
            phase: String,
            timeoutMs: Long,
            condition: () -> Boolean,
        ) {
            val waitDeadline = SystemClock.elapsedRealtime() + timeoutMs
            while (!condition()) {
                pollFailure()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_during_$phase:${s.exitReason}")
                if (SystemClock.elapsedRealtime() > waitDeadline) throw FailClosed("timeout_$phase")
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
                    threadName = "Y6fDecoderFeed_$tag",
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
            val machine = VanguardRealtimePlaybackTransportStateMachine(sessionConfig, listener, threadName = "Y6fTransport_$tag")
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
            val s = VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge(
                VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.Config(
                    stateMachine = machine,
                    scenario = when (scenario) {
                        Scenario.FORWARD_PLAYTHROUGH_TIMESTAMP ->
                            VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.Scenario.FORWARD_PLAYTHROUGH_TIMESTAMP
                        Scenario.DEAD_OBJECT_EPOCH_RESET_TIMESTAMP ->
                            VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.Scenario.DEAD_OBJECT_EPOCH_RESET_TIMESTAMP
                    },
                    sampleRate = fmt.sampleRate,
                    channelCount = fmt.channelCount,
                    maxFramesPerMix = config.maxFramesPerMix,
                    declaredFrameCount = fmt.declaredFrameCount,
                    phaseFrames = config.phaseFrames,
                    baseVolume = config.baseVolume,
                    deadlineAtMs = deadlineAtMs,
                    threadName = "Y6fSinkBridge_$tag",
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

        private fun awaitInitialWrites(s: VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge) {
            val waitStart = SystemClock.elapsedRealtime()
            awaitSink(s, "initial_write", INITIAL_WRITE_WAIT_MS) { s.framesWrittenToSink > 0L && s.played }
            initialWriteWaitMs = SystemClock.elapsedRealtime() - waitStart
        }

        private fun drainAtLeast(s: VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge, phase: String, target: Long) {
            awaitSink(s, phase, PHASE_WAIT_TIMEOUT_MS) { s.framesWrittenToSink >= target }
            val machine = sm ?: throw FailClosed("transport_missing")
            if (machine.currentState != State.PLAYING) throw FailClosed("transport_not_playing_after_$phase:${machine.currentState.name.lowercase()}")
            framesWrittenAtPhase = s.framesWrittenToSink
            pollAttemptsAtPhase = s.timestampPollAttempts
            epochsAtPhase = s.timestampEpochOpenCount
            if (epochsAtPhase < 1) throw FailClosed("epoch_not_open_after_$phase")
            // Dead-object scenario: the injection point must be well before
            // the declared end.
            if (scenario == Scenario.DEAD_OBJECT_EPOCH_RESET_TIMESTAMP) {
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
        private fun tailEos(s: VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge, f: VanguardRealtimePlaybackDecoderFeed) {
            while (!s.awaitExit(WAIT_SLICE_MS)) {
                val first = pollFailure()
                if (first != null) {
                    cancelThreads()
                    break
                }
            }
            if (failure.get() == null && s.exitReason != VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.EXIT_EOS) {
                recordFailure("sink:${s.exitReason}")
            }
            if (failure.get() == null && !f.awaitExit(JOIN_TIMEOUT_MS)) recordFailure("decoder_did_not_exit")
            if (failure.get() == null && f.exitReason != VanguardRealtimePlaybackDecoderFeed.EXIT_EOS) recordFailure("decoder:${f.exitReason}")
            if (scenario == Scenario.DEAD_OBJECT_EPOCH_RESET_TIMESTAMP && failure.get() == null &&
                (s.syntheticDeadObjectInjectedCount != 1L || s.deadObjectObservedCount != 1L)
            ) {
                recordFailure("dead_object_never_injected:${s.syntheticDeadObjectInjectedCount}:${s.deadObjectObservedCount}")
            }
            if (scenario == Scenario.FORWARD_PLAYTHROUGH_TIMESTAMP && failure.get() == null &&
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
            s: VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge,
            machine: VanguardRealtimePlaybackTransportStateMachine,
            final: Reply,
        ) {
            val fmt = format ?: return
            val declared = fmt.declaredFrameCount
            val bytesPerFrame = 2L * fmt.channelCount
            val coordinatorThreadId = Thread.currentThread().id
            val isDeadObject = scenario == Scenario.DEAD_OBJECT_EPOCH_RESET_TIMESTAMP
            val expectedEpochs = if (isDeadObject) 2 else 1
            val expectedTracks = if (isDeadObject) 2 else 1
            val expectedResets = if (isDeadObject) 1 else 0
            val expectedDeadObjects = if (isDeadObject) 1L else 0L

            lanes[LANE_FORMAT_PROBE] = fmt.sampleRate > 0 && fmt.channelCount in 1..2 && declared > 0L && fmt.sourceMime.isNotBlank()
            lanes[LANE_PRE_ROLL] = preRollFrames > 0L && (preRollRingFull || preRollFrames == declared) &&
                preRollStatePrepared && startAcceptedPlaying && preRollFrames <= declared

            // ── Timestamp lanes ────────────────────────────────────────────
            val epochsOk = s.timestampEpochOpenCount == expectedEpochs && s.timestampEpochCloseCount == expectedEpochs &&
                s.timestampCurrentEpoch == VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.EPOCH_NONE
            var epochsHaveAttempts = true
            var epochOpenedAfterPlaying = true
            var epochBaselinesReset = true
            var epochFramePositionsOk = true
            var epochHeadsOk = true
            var epochAccountingOk = true
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
                            s.epochFirstFramePosition[e] < VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.FRAME_WRAP_MODULUS &&
                            s.epochLastFramePosition[e] < VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.FRAME_WRAP_MODULUS &&
                            (s.epochWrapCount[e] == 1L || s.epochLastFramePosition[e] >= s.epochFirstFramePosition[e])))
                epochHeadsOk = epochHeadsOk && s.epochHeadSamples[e] == s.epochPollAttempts[e] &&
                    s.epochHeadRegressionCount[e] == 0L && s.epochHeadWrapCount[e] <= 1L &&
                    (s.epochHeadSamples[e] == 0L || (s.epochFirstHead[e] >= 0L && s.epochLastHead[e] >= 0L &&
                        (s.epochHeadWrapCount[e] == 1L || s.epochLastHead[e] >= s.epochFirstHead[e])))
                epochAccountingOk = epochAccountingOk &&
                    s.epochPollAttempts[e] == s.epochPollSuccesses[e] + s.epochPollUnavailable[e]
                attemptsSum += s.epochPollAttempts[e]
                successesSum += s.epochPollSuccesses[e]
                unavailableSum += s.epochPollUnavailable[e]
            }
            for (e in expectedEpochs until VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.MAX_EPOCHS) {
                // Unused epoch slots must be untouched.
                epochAccountingOk = epochAccountingOk && s.epochPollAttempts[e] == 0L && s.epochOpenedAtMs[e] < 0L &&
                    !s.epochBaselineWasResetAtOpen[e]
            }

            lanes[LANE_TIMESTAMP_POLL_CADENCE] = s.timestampPollAttempts > 0L && s.productiveDrainPasses > 0L &&
                s.timestampMaxPollsInOnePass == 1L && s.timestampPassesPolled == s.timestampPollAttempts &&
                s.timestampPollAttempts <= s.productiveDrainPasses &&
                s.timestampPollPointReachedCount == s.timestampPollAttempts &&
                s.timestampPollsDuplicateInPass == 0L && epochsHaveAttempts
            lanes[LANE_TIMESTAMP_POLL_AFTER_WRITE_ONLY] = s.timestampPollsAfterWriteReturned == s.timestampPollAttempts &&
                s.timestampPollsInsideWriteLoop == 0L && s.timestampPollAttempts > 0L &&
                s.activity == Activity.TEARDOWN
            lanes[LANE_TIMESTAMP_NO_POLL_WHILE_PARKED] = s.timestampPollsWhileHolding == 0L &&
                s.timestampPollsBeforeStartGate == 0L && s.timestampPollsBetweenReleaseAndPlay == 0L &&
                s.deadObjectPollsInsideRecoveryWindow == 0L && s.timestampPollsDuringCatchupOrTeardown == 0L &&
                timestampPollsAtStart == 0L
            lanes[LANE_TIMESTAMP_WARMUP_GATED_ON_PLAYING] = epochsOk && epochOpenedAfterPlaying && s.timestampEpochOpenedAfterPlaying &&
                s.timestampPollsBeforePlaying == 0L && s.timestampPollsWithoutOpenEpoch == 0L &&
                epochsOpenAtStart == 0 && s.initialPlayOnSinkThread &&
                (!isDeadObject || (s.deadObjectNewTrackPlayOk && s.epochOpenedAtMs[1] >= s.epochClosedAtMs[0]))
            lanes[LANE_TIMESTAMP_POLL_ACCOUNTING] = epochAccountingOk &&
                s.timestampPollAttempts == s.timestampPollSuccesses + s.timestampPollUnavailable &&
                attemptsSum == s.timestampPollAttempts && successesSum == s.timestampPollSuccesses &&
                unavailableSum == s.timestampPollUnavailable && s.timestampPollSuccesses >= 0L &&
                s.timestampPollsOnSinkThread == s.timestampPollAttempts && s.timestampPollsOffSinkThread == 0L &&
                s.timestampPollExceptions <= s.timestampPollUnavailable
            lanes[LANE_EPOCH_FRAME_POSITION_MONOTONIC] = epochsOk && epochFramePositionsOk &&
                s.timestampFrameRegressionCount == 0L && s.timestampWrapCount <= expectedEpochs.toLong() &&
                // Every success is either an epoch baseline, an advance (a
                // tolerated wrap counts as an advance) or an equal sample.
                s.timestampFrameAdvanceCount + s.timestampFrameEqualCount + baselineCount == s.timestampPollSuccesses
            lanes[LANE_EPOCH_BASELINE_RESET] = epochsOk && epochBaselinesReset &&
                s.timestampEpochBaselineResetCount == expectedResets &&
                (!isDeadObject || (s.epochClosedAtMs[0] > 0L && s.epochOpenedAtMs[1] >= s.epochClosedAtMs[0] &&
                    s.epochFramesWrittenAtOpen[1] == s.deadObjectSinkFramesWrittenBeforeRecovery))
            lanes[LANE_NO_CROSS_EPOCH_COMPARISON] = s.timestampCrossEpochComparisonCount == 0L &&
                s.headCrossEpochComparisonCount == 0L && epochsOk &&
                (!isDeadObject || s.epochPollSuccesses[1] == 0L || s.epochFirstSampleWasBaseline[1])
            lanes[LANE_PLAYBACK_HEAD_MONOTONIC_PER_EPOCH] = epochHeadsOk && s.headRegressionCount == 0L &&
                s.headSampleCount == s.timestampPollAttempts && s.headWrapCount <= expectedEpochs.toLong() &&
                s.playbackHeadFinal > 0L
            lanes[LANE_TIMESTAMP_INERT_NO_FEEDBACK] = s.timestampDerivedWriteSizeAdjustments == 0L &&
                s.timestampDerivedSleeps == 0L && s.timestampDerivedDrainSkips == 0L &&
                s.timestampDerivedTransportCommands == 0L &&
                // Transport commands: load, prepare, start only (none after the sink started except start).
                commandsIssued == 3 && commandsIssued - transportCommandsAtSinkStart == 1 &&
                // Every drained frame was written regardless of timestamp availability.
                s.framesWrittenToSink == s.framesReadFromTransport && s.framesWrittenToSink == declared &&
                s.drainCalls >= s.productiveDrainPasses && final.discardedFrames == 0L

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
            lanes[LANE_SINK_WRITE_ACCOUNTING] = s.exitReason == VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.EXIT_EOS &&
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
            metrics["sinkExitReason"] = s?.exitReason ?: VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.EXIT_NOT_STARTED
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
                for (e in 0 until VanguardRealtimePlaybackPipelineTimestampStabilizationSinkBridge.MAX_EPOCHS) {
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
