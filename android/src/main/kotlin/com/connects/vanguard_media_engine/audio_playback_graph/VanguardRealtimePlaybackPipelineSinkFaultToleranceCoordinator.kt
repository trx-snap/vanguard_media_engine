package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioTrack
import android.os.Handler
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.NativeState
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.ParkReason
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.Phase
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackRoutingController.Tag
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.IngestRequest
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

// ── VanguardRealtimePlaybackPipelineSinkFaultToleranceCoordinator (P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SINK-FAULT-TOLERANCE, Y6e) ─
//
// The ONLY transport command owner of the Y6e sink fault-tolerance proof
// over the committed Y6a/Y6b pipeline shape:
//
//   MediaExtractor/MediaCodec  ->  Y5a external ingest seam  ->  Y1 native
//   ([VanguardRealtimePlaybackDecoderFeed], decode thread, unchanged)
//   transport (owner HandlerThread inside the state machine)  ->
//   non-zero-gain AudioTrack MODE_STREAM
//   ([VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge], sink thread)
//   + one Y4b [VanguardRealtimePlaybackRoutingController] per scenario
//   (OS routing callbacks / synthetic route-changed posts only enqueue on
//   the main Handler; the synthetic route disconnect is enqueued
//   synchronously on this coordinator thread).
//
// Thread model: the decoder feed thread only posts generation-pinned
// ingest; the sink thread only drains, owns every AudioTrack call
// (create / recreate / setVolume / play / pause / write / release),
// attaches and detaches the routing listener and applies every routing
// event and the one synthetic dead object; the state machine is the only
// JNI caller; this coordinator (the caller's worker thread) issues
// transport commands (load, prepare, start, pause, stop) in response to
// the sink's published state, posts synthetic events through the
// controller, waits/joins and aggregates. It never calls an AudioTrack
// method and never applies an event.
//
// Two scenarios run sequentially in one smoke, each with its own feed,
// transport, sink, routing controller and AudioTrack. Shared head: format
// probe -> pre-roll -> sink setup on the sink thread (track created, base
// volume 0.5, routing listener attached, empty pre-start drain) BEFORE
// transport start -> start -> first positive sink write -> >= phaseFrames
// -> synthetic ROUTE_CHANGED observed on the sink thread (telemetry only)
// -> >= 2 * phaseFrames.
//   EOS_WITH_DEAD_OBJECT_RECOVERY: the sink thread substitutes exactly one
//                            synthetic ERROR_DEAD_OBJECT for an in-flight
//                            write (zero bytes consumed), recovers inline
//                            (detach -> release old once -> same-parameter
//                            recreate -> STATE_INITIALIZED -> setVolume ->
//                            attach -> play() -> same remainder), drains to
//                            EOS, transport COMPLETED, full checksum
//                            identity, no dropped / double-counted frame.
//   ROUTE_DISCONNECT_TERMINAL: no dead object. Synthetic ROUTE_DISCONNECT
//                            enqueued synchronously through the controller
//                            -> sink parks first (AudioTrack.pause(),
//                            autoResumeAllowed=false, parked metrics) ->
//                            transport.pause() -> frozen hold -> prefix
//                            identity -> sink exit -> transport.stop() once
//                            (never COMPLETED, no completion claim).
//
// Teardown per scenario: feed cancel/stop, sink exit (routing controller
// released then AudioTrack released once, both on the sink thread), late
// synthetic post rejected, state machine disposed once. First failure
// wins; joins are bounded.
//
// Synthetic error injection only; synthetic route disconnect only. No real
// OS fault forcing, seamless hot-swap, presentation clock, A/V sync,
// latency / glitch / acoustic / loudness / SNR, focus / noisy, seek,
// resample / downmix, product / editor / app / ConnectsApp, iOS,
// streaming / cache or C++ change lives here.
class VanguardRealtimePlaybackPipelineSinkFaultToleranceCoordinator(
    private val mainHandler: Handler,
) {

    enum class Scenario { EOS_WITH_DEAD_OBJECT_RECOVERY, ROUTE_DISCONNECT_TERMINAL }

    data class Config(
        val sourcePath: String,
        val maxDurationSec: Double = 3.0,
        val maxFramesPerMix: Int = 256,
        val baseVolume: Float = VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.DEFAULT_BASE_VOLUME,
        val deadlineMs: Long = 60_000L,
        val pauseHoldMs: Long = DEFAULT_PAUSE_HOLD_MS,
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
            "realtime_playback_pipeline_sink_fault_tolerance_diagnostic_only_real_mediaextractor_mediacodec_" +
                "to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_" +
                "synthetic_dead_object_injection_only_synthetic_route_disconnect_only_route_change_listener_handoff_" +
                "sink_thread_owns_audiotrack_coordinator_owns_transport_commands_" +
                "no_real_os_fault_forcing_no_seamless_hot_swap_no_presentation_clock_no_av_sync_" +
                "no_latency_no_glitch_no_acoustic_no_loudness_no_snr_no_focus_no_noisy_no_seek_no_resample_no_downmix_" +
                "no_product_no_editor_no_app_wiring_no_connectsapp_no_ios_no_streaming_no_cache_no_cpp_changes"

        const val DEFAULT_PAUSE_HOLD_MS = 150L
        const val MAX_PAUSE_HOLD_MS = 2_000L
        const val DEFAULT_PHASE_FRAMES = 2_048L

        const val LANE_FORMAT_PROBE = "formatProbeOk"
        const val LANE_PRE_ROLL = "preRollOk"
        const val LANE_ROUTING_LISTENER_REGISTERED = "routingListenerRegisteredOk"
        const val LANE_PRE_START_DRAIN_EMPTY = "preStartDrainEmptyOk"
        const val LANE_ROUTE_CHANGE_OBSERVATION = "routeChangeObservationOk"
        const val LANE_DEAD_OBJECT_INJECTED_ONCE = "deadObjectInjectedOnceOk"
        const val LANE_DEAD_OBJECT_OLD_TRACK_RELEASED = "deadObjectOldTrackReleasedOk"
        const val LANE_DEAD_OBJECT_NEW_TRACK_STATE_INITIALIZED = "deadObjectNewTrackStateInitializedOk"
        const val LANE_DEAD_OBJECT_NEW_TRACK_VOLUME_SET = "deadObjectNewTrackVolumeSetOk"
        const val LANE_DEAD_OBJECT_NEW_TRACK_PLAY = "deadObjectNewTrackPlayOk"
        const val LANE_DEAD_OBJECT_REMAINDER_RESUMED = "deadObjectRemainderResumedOk"
        const val LANE_DEAD_OBJECT_NO_DOUBLE_COUNT = "deadObjectNoDoubleCountOk"
        const val LANE_ROUTE_DISCONNECT_FAIL_CLOSED_PAUSE = "routeDisconnectFailClosedPauseOk"
        const val LANE_ROUTE_DISCONNECT_HOLD_FROZEN = "routeDisconnectHoldFrozenOk"
        const val LANE_SINK_WRITE_ACCOUNTING = "sinkWriteAccountingOk"
        const val LANE_CHECKSUM_IDENTITY = "checksumIdentityOk"
        const val LANE_TRANSPORT_COMPLETED = "transportCompletedOk"
        const val LANE_TRANSPORT_STOPPED = "transportStoppedOk"
        const val LANE_ROUTING_LIFECYCLE = "routingLifecycleOk"
        const val LANE_AUDIO_TRACK_LIFECYCLE = "audioTrackLifecycleOk"
        const val LANE_THREAD_OWNERSHIP = "threadOwnershipOk"
        const val LANE_PROOF_BOUNDARY = "proofBoundaryOk"
        const val LANE_CANONICAL = "canonical"

        val REQUIRED_LANES: List<String> = listOf(
            LANE_FORMAT_PROBE,
            LANE_PRE_ROLL,
            LANE_ROUTING_LISTENER_REGISTERED,
            LANE_PRE_START_DRAIN_EMPTY,
            LANE_ROUTE_CHANGE_OBSERVATION,
            LANE_DEAD_OBJECT_INJECTED_ONCE,
            LANE_DEAD_OBJECT_OLD_TRACK_RELEASED,
            LANE_DEAD_OBJECT_NEW_TRACK_STATE_INITIALIZED,
            LANE_DEAD_OBJECT_NEW_TRACK_VOLUME_SET,
            LANE_DEAD_OBJECT_NEW_TRACK_PLAY,
            LANE_DEAD_OBJECT_REMAINDER_RESUMED,
            LANE_DEAD_OBJECT_NO_DOUBLE_COUNT,
            LANE_ROUTE_DISCONNECT_FAIL_CLOSED_PAUSE,
            LANE_ROUTE_DISCONNECT_HOLD_FROZEN,
            LANE_SINK_WRITE_ACCOUNTING,
            LANE_CHECKSUM_IDENTITY,
            LANE_TRANSPORT_COMPLETED,
            LANE_TRANSPORT_STOPPED,
            LANE_ROUTING_LIFECYCLE,
            LANE_AUDIO_TRACK_LIFECYCLE,
            LANE_THREAD_OWNERSHIP,
            LANE_PROOF_BOUNDARY,
        )

        // Lanes every scenario must hold; the rest are scenario-specific.
        private val SHARED_LANES = listOf(
            LANE_FORMAT_PROBE, LANE_PRE_ROLL, LANE_ROUTING_LISTENER_REGISTERED, LANE_PRE_START_DRAIN_EMPTY,
            LANE_ROUTE_CHANGE_OBSERVATION, LANE_SINK_WRITE_ACCOUNTING, LANE_CHECKSUM_IDENTITY,
            LANE_ROUTING_LIFECYCLE, LANE_AUDIO_TRACK_LIFECYCLE, LANE_THREAD_OWNERSHIP,
        )
        private val EOS_LANES = listOf(
            LANE_DEAD_OBJECT_INJECTED_ONCE, LANE_DEAD_OBJECT_OLD_TRACK_RELEASED,
            LANE_DEAD_OBJECT_NEW_TRACK_STATE_INITIALIZED, LANE_DEAD_OBJECT_NEW_TRACK_VOLUME_SET,
            LANE_DEAD_OBJECT_NEW_TRACK_PLAY, LANE_DEAD_OBJECT_REMAINDER_RESUMED, LANE_DEAD_OBJECT_NO_DOUBLE_COUNT,
            LANE_TRANSPORT_COMPLETED,
        )
        private val DISCONNECT_LANES = listOf(
            LANE_ROUTE_DISCONNECT_FAIL_CLOSED_PAUSE, LANE_ROUTE_DISCONNECT_HOLD_FROZEN, LANE_TRANSPORT_STOPPED,
        )

        private const val WAIT_SLICE_MS = 5L
        private const val JOIN_TIMEOUT_MS = 5_000L
        private const val SETUP_WAIT_MS = 5_000L
        private const val INITIAL_WRITE_WAIT_MS = 2_000L
        private const val EVENT_APPLY_TIMEOUT_MS = 2_000L
        private const val PHASE_WAIT_TIMEOUT_MS = 6_000L
        private const val SHARED_PHASES = 2L
        // Terminal events (and the dead object) must land well before the declared end.
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
        if (config.pauseHoldMs <= 0L || config.pauseHoldMs > MAX_PAUSE_HOLD_MS) throw FailClosed("invalid_pause_hold")
        if (config.phaseFrames <= 0L) throw FailClosed("invalid_phase_frames")
        if (cancelled.get()) throw FailClosed("cancelled")
        val deadlineAtMs = SystemClock.elapsedRealtime() + config.deadlineMs
        metrics["maxDurationSec"] = config.maxDurationSec
        metrics["maxFramesPerMix"] = config.maxFramesPerMix
        metrics["baseVolume"] = config.baseVolume.toDouble()
        metrics["deadlineMs"] = config.deadlineMs
        metrics["pauseHoldMs"] = config.pauseHoldMs
        metrics["phaseFrames"] = config.phaseFrames
        metrics["coordinatorThreadId"] = Thread.currentThread().id
        metrics["scenarioOrder"] = Scenario.entries.map { it.name }
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
        for (lane in EOS_LANES) lanes[lane] = laneOf(results[Scenario.EOS_WITH_DEAD_OBJECT_RECOVERY], lane)
        for (lane in DISCONNECT_LANES) lanes[lane] = laneOf(results[Scenario.ROUTE_DISCONNECT_TERMINAL], lane)
        for (scenario in Scenario.entries) {
            val s = results[scenario]
            metrics["${scenario.name.lowercase()}ScenarioPass"] = s != null && s.failure.get() == null && s.scenarioLanesHeld()
        }
    }

    private fun isCancelled(): Boolean = cancelled.get()

    // ── One scenario session (feed + transport + sink + routing controller) ─

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
        @Volatile var sink: VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge? = null
        @Volatile var controller: VanguardRealtimePlaybackRoutingController? = null

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
        var listenerAttachedBeforeStart = false
        var preStartDrainEmptyBeforeStart = false
        var transportStateAtSetup = State.IDLE
        var initialWriteWaitMs = -1L
        var syntheticRouteChangedPosted = false
        var routeChangedWaitMs = -1L
        var framesWrittenAtRouteChanged = 0L
        var audioTracksAtRouteChanged = -1
        // Disconnect tail observations.
        var disconnectPostedOnCoordinatorThread = false
        var disconnectPostAccepted = false
        var disconnectPendingAfterPost = -1
        var disconnectParkWaitMs = -1L
        var transportStateAtPark = State.IDLE
        var pauseAccepted = false
        var pauseReason = ""
        var pauseGeneration = -1L
        var pauseNativeState = "none"
        var holdStart: Reply? = null
        var holdEnd: Reply? = null
        var holdDispatchDelta = -1L
        var holdPushedDelta = -1L
        var holdDrainCallsDelta = -1L
        var holdWrittenDelta = -1L
        var holdActualMs = -1L
        var holdStartPlayState = VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.PLAY_STATE_UNKNOWN
        var holdEndPlayState = VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.PLAY_STATE_UNKNOWN
        var terminalPositionFrame = -1L
        var terminalPositionLimit = -1L
        var stopAccepted = false
        var stopState = State.IDLE
        var stopReason = ""
        var stopGeneration = -1L
        var stopCalls = 0
        var prefixReply: Reply? = null
        var prefixSinkHex = ""
        var lateSyntheticPostRejected = false
        var ignoredAfterRelease = 0L
        var controllerTelemetry: Map<String, Any?> = emptyMap()

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
                Scenario.EOS_WITH_DEAD_OBJECT_RECOVERY -> EOS_LANES
                Scenario.ROUTE_DISCONNECT_TERMINAL -> DISCONNECT_LANES
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
                s.exitReason != VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.EXIT_RUNNING &&
                s.exitReason != VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.EXIT_EOS &&
                s.exitReason != VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.EXIT_TERMINAL &&
                s.exitReason != VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.EXIT_NOT_STARTED
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
            s: VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge,
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
                    threadName = "Y6eDecoderFeed_$tag",
                    externallyCancelled = { sessionCancelled() },
                ),
            )
            feed = f
            if (!f.start()) throw FailClosed("feed_start_rejected")
            val fmt = f.awaitFormat(remainingMs()) ?: throw FailClosed("format_probe_failed:${f.exitReason}")
            format = fmt
            checkDeadlineAndCancel()
            // The head needs SHARED_PHASES phases plus the dead-object arming
            // margin before the declared end.
            if (fmt.declaredFrameCount <= config.phaseFrames * MIN_DECLARED_PHASES +
                TERMINAL_MARGIN_WINDOWS * config.maxFramesPerMix
            ) {
                throw FailClosed("declared_frame_count_too_short_for_script:${fmt.declaredFrameCount}")
            }

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
            val machine = VanguardRealtimePlaybackTransportStateMachine(sessionConfig, listener, threadName = "Y6eTransport_$tag")
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

        // Sink thread setup (track, base volume, listener attach, empty
        // pre-start drain) completes BEFORE the transport starts; the sink
        // then waits on its start gate.
        private fun startSinkAndProveSetup() {
            checkDeadlineAndCancel()
            val fmt = format ?: throw FailClosed("format_missing")
            val machine = sm ?: throw FailClosed("transport_missing")
            val tag = scenario.name.lowercase()
            val c = VanguardRealtimePlaybackRoutingController(mainHandler)
            controller = c
            val s = VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge(
                VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.Config(
                    stateMachine = machine,
                    routingController = c,
                    scenario = when (scenario) {
                        Scenario.EOS_WITH_DEAD_OBJECT_RECOVERY ->
                            VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.Scenario.EOS_WITH_DEAD_OBJECT_RECOVERY
                        Scenario.ROUTE_DISCONNECT_TERMINAL ->
                            VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.Scenario.ROUTE_DISCONNECT_TERMINAL
                    },
                    sampleRate = fmt.sampleRate,
                    channelCount = fmt.channelCount,
                    maxFramesPerMix = config.maxFramesPerMix,
                    declaredFrameCount = fmt.declaredFrameCount,
                    phaseFrames = config.phaseFrames,
                    baseVolume = config.baseVolume,
                    deadlineAtMs = deadlineAtMs,
                    threadName = "Y6eSinkBridge_$tag",
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
            listenerAttachedBeforeStart = s.routingListenerAttachedOk && c.isAttached && c.attachCount == 1
            preStartDrainEmptyBeforeStart = s.preStartDrainEmptyOk && s.preStartPendingCount == 0 && c.pendingCount == 0
            lanes[LANE_ROUTING_LISTENER_REGISTERED] = setupCompleteBeforeStart && listenerAttachedBeforeStart &&
                s.audioTrackInitOk && s.gainSetOk && s.gainValue == config.baseVolume && s.setVolumeCalls == 1L &&
                s.audioTracksCreated == 1 && c.lastAttachError.isEmpty()
            lanes[LANE_PRE_START_DRAIN_EMPTY] = setupCompleteBeforeStart && preStartDrainEmptyBeforeStart &&
                c.enqueuedCount == 0L && c.droppedCount == 0L && s.drainCalls == 0L && s.framesWrittenToSink == 0L
            if (lanes[LANE_ROUTING_LISTENER_REGISTERED] != true) throw FailClosed("sink_setup_not_proven:${c.lastAttachError}")
            if (lanes[LANE_PRE_START_DRAIN_EMPTY] != true) throw FailClosed("pre_start_drain_not_empty:${s.preStartPendingCount}")
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

        private fun awaitInitialWrites(s: VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge) {
            val waitStart = SystemClock.elapsedRealtime()
            awaitSink(s, "initial_write", INITIAL_WRITE_WAIT_MS) { s.framesWrittenToSink > 0L && s.played }
            initialWriteWaitMs = SystemClock.elapsedRealtime() - waitStart
        }

        private fun drainAtLeast(s: VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge, phase: String, target: Long) {
            awaitSink(s, phase, PHASE_WAIT_TIMEOUT_MS) { s.framesWrittenToSink >= target }
            val machine = sm ?: throw FailClosed("transport_missing")
            if (machine.currentState != State.PLAYING) throw FailClosed("transport_not_playing_after_$phase:${machine.currentState.name.lowercase()}")
            if (s.phase != Phase.RUNNING) throw FailClosed("sink_not_running_after_$phase")
        }

        // Synthetic ROUTE_CHANGED posted through the listener Handler (same
        // path as a real OS callback); observed on the sink thread as
        // telemetry only. Any real ROUTE_CHANGED ahead of it is observed too.
        private fun observeSyntheticRouteChanged(
            s: VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge,
            c: VanguardRealtimePlaybackRoutingController,
            machine: VanguardRealtimePlaybackTransportStateMachine,
        ) {
            checkDeadlineAndCancel()
            syntheticRouteChangedPosted = c.postSyntheticRouteChanged()
            if (!syntheticRouteChangedPosted) throw FailClosed("synthetic_post_rejected_route_changed")
            val waitStart = SystemClock.elapsedRealtime()
            awaitSink(s, "route_changed_apply", EVENT_APPLY_TIMEOUT_MS) { s.syntheticRouteChangedAppliedCount >= 1L }
            routeChangedWaitMs = SystemClock.elapsedRealtime() - waitStart
            framesWrittenAtRouteChanged = s.framesWrittenToSink
            audioTracksAtRouteChanged = s.audioTracksCreated
            lanes[LANE_ROUTE_CHANGE_OBSERVATION] = s.syntheticRouteChangedAppliedCount == 1L && s.routeChangeObserved &&
                s.routeChangedAppliedCount >= 1L && s.routedDeviceSampleOk && s.syntheticRouteChangedApplySeq >= 0L &&
                s.routeDisconnectAppliedCount == 0L && s.parkCount == 0 && s.phase == Phase.RUNNING &&
                s.audioTracksCreated == 1 && s.deadObjectObservedCount == 0L &&
                s.observedPlayState == AudioTrack.PLAYSTATE_PLAYING && machine.currentState == State.PLAYING &&
                c.syntheticRouteChangedPostedCount == 1L && c.droppedCount == 0L
            if (lanes[LANE_ROUTE_CHANGE_OBSERVATION] != true) {
                throw FailClosed("route_changed_not_observed:${s.routeChangedAppliedCount}:${s.syntheticRouteChangedAppliedCount}")
            }
        }

        // ── Tails ──────────────────────────────────────────────────────────

        private fun terminalPrecondition(
            s: VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge,
            machine: VanguardRealtimePlaybackTransportStateMachine,
            phase: String,
        ) {
            checkDeadlineAndCancel()
            val declared = format?.declaredFrameCount ?: throw FailClosed("format_missing")
            terminalPositionLimit = declared - TERMINAL_MARGIN_WINDOWS * config.maxFramesPerMix
            if (machine.currentState != State.PLAYING) throw FailClosed("transport_not_playing_before_$phase:${machine.currentState.name.lowercase()}")
            if (s.phase != Phase.RUNNING || s.observedPlayState != AudioTrack.PLAYSTATE_PLAYING) throw FailClosed("sink_not_playing_before_$phase")
            val pre = snapshotReply("pre_$phase", machine)
            terminalPositionFrame = pre.positionFrame
            if (pre.state == NativeState.COMPLETED || pre.positionFrame >= terminalPositionLimit) {
                throw FailClosed("${phase}_precondition_late:${pre.positionFrame}:$terminalPositionLimit")
            }
        }

        // Prefix identity: PCM handed to AudioTrack up to the terminal park
        // vs the native drained checksum of the last drain reply before it.
        private fun verifyPrefix(s: VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge, phase: String) {
            val reply = s.replyAtPark ?: throw FailClosed("missing_prefix_reply_$phase")
            prefixReply = reply
            prefixSinkHex = s.checksumAtParkHex
            val identity = prefixSinkHex.isNotBlank() && prefixSinkHex.equals(reply.drainedChecksumHex, ignoreCase = true)
            lanes[LANE_CHECKSUM_IDENTITY] = identity
            val declared = format?.declaredFrameCount ?: 0L
            lanes[LANE_SINK_WRITE_ACCOUNTING] = s.framesWrittenAtPark == s.framesWrittenToSink &&
                s.framesReadAtPark == s.framesReadFromTransport &&
                s.framesReadFromTransport == s.framesWrittenToSink && reply.drainedFrames == s.framesWrittenToSink &&
                s.framesWrittenToSink >= config.phaseFrames * SHARED_PHASES && s.framesWrittenToSink < declared &&
                s.deadObjectObservedCount == 0L && s.syntheticDeadObjectInjectedCount == 0L
            if (!identity) throw FailClosed("prefix_checksum_identity_mismatch_$phase")
            if (lanes[LANE_SINK_WRITE_ACCOUNTING] != true) throw FailClosed("prefix_write_accounting_mismatch_$phase")
        }

        private fun stopTransportOnce(machine: VanguardRealtimePlaybackTransportStateMachine, phase: String) {
            val res = machine.stop()
            commandsIssued++
            stopCalls++
            stopAccepted = res.accepted
            stopState = res.state
            stopReason = res.reason
            stopGeneration = machine.currentGeneration
            if (!stopAccepted || res.state != State.STOPPED) throw FailClosed("stop_rejected_$phase:${res.reason}")
        }

        private fun exitSink(s: VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge, f: VanguardRealtimePlaybackDecoderFeed) {
            f.cancel()
            s.requestExit()
            while (!s.awaitExit(WAIT_SLICE_MS)) {
                if (SystemClock.elapsedRealtime() > deadlineAtMs) throw FailClosed("deadline_exceeded")
            }
            if (s.exitReason != VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.EXIT_TERMINAL) {
                throw FailClosed("sink_terminal_exit_unexpected:${s.exitReason}")
            }
            if (!f.awaitExit(JOIN_TIMEOUT_MS)) throw FailClosed("decoder_did_not_exit")
        }

        // EOS scenario: the sink thread arms, injects and recovers the one
        // synthetic dead object inline; this thread only waits for EOS.
        private fun tailEos(s: VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge, f: VanguardRealtimePlaybackDecoderFeed) {
            while (!s.awaitExit(WAIT_SLICE_MS)) {
                val first = pollFailure()
                if (first != null) {
                    cancelThreads()
                    break
                }
            }
            if (failure.get() == null && s.exitReason != VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.EXIT_EOS) {
                recordFailure("sink:${s.exitReason}")
            }
            if (failure.get() == null && !f.awaitExit(JOIN_TIMEOUT_MS)) recordFailure("decoder_did_not_exit")
            if (failure.get() == null && f.exitReason != VanguardRealtimePlaybackDecoderFeed.EXIT_EOS) recordFailure("decoder:${f.exitReason}")
            if (failure.get() == null && (s.syntheticDeadObjectInjectedCount != 1L || s.deadObjectObservedCount != 1L)) {
                recordFailure("dead_object_never_injected:${s.syntheticDeadObjectInjectedCount}:${s.deadObjectObservedCount}")
            }
        }

        // Disconnect scenario: synthetic ROUTE_DISCONNECT enqueued
        // synchronously on this thread; the sink parks first (AudioTrack
        // paused on the sink thread, autoResumeAllowed=false), then this
        // thread pauses the transport, holds frozen, proves the prefix,
        // exits the sink and stops the still-PAUSED transport exactly once.
        private fun tailDisconnect(
            s: VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge,
            c: VanguardRealtimePlaybackRoutingController,
            machine: VanguardRealtimePlaybackTransportStateMachine,
            f: VanguardRealtimePlaybackDecoderFeed,
        ) {
            terminalPrecondition(s, machine, "disconnect")
            // Enqueued synchronously on THIS (coordinator) thread: never the
            // sink thread, never the transport owner thread.
            disconnectPostedOnCoordinatorThread = Thread.currentThread().id != s.threadId && !machine.isOwnerThread
            disconnectPostAccepted = c.postSyntheticRouteDisconnect()
            disconnectPendingAfterPost = c.pendingCount
            if (!disconnectPostAccepted) throw FailClosed("synthetic_post_rejected_route_disconnect")
            val waitStart = SystemClock.elapsedRealtime()
            awaitSink(s, "disconnect_park", EVENT_APPLY_TIMEOUT_MS) { s.parkCount >= 1 && s.phase == Phase.PARKED }
            disconnectParkWaitMs = SystemClock.elapsedRealtime() - waitStart
            transportStateAtPark = machine.currentState
            val parked = s.parkCount == 1 && s.parkReason == ParkReason.ROUTE_DISCONNECT &&
                s.routeDisconnectAppliedCount == 1L && s.routeDisconnectApplySeq > s.syntheticRouteChangedApplySeq &&
                !s.autoResumeAllowed && s.playStateAtPark == AudioTrack.PLAYSTATE_PAUSED && s.parkAppliedOnSinkThread &&
                s.deadObjectObservedCount == 0L && s.syntheticDeadObjectInjectedCount == 0L && s.audioTracksCreated == 1 &&
                transportStateAtPark == State.PLAYING && stopCalls == 0 &&
                c.drainedCountFor(Tag.ROUTE_DISCONNECT) == 1L && c.syntheticRouteDisconnectPostedCount == 1L
            if (!parked) throw FailClosed("disconnect_park_not_observed:${s.parkReason.name.lowercase()}:${transportStateAtPark.name.lowercase()}")

            // Sink parked first; now the transport pauses (fail-closed, terminal).
            val res = machine.pause()
            commandsIssued++
            pauseAccepted = res.accepted
            pauseReason = res.reason
            pauseGeneration = machine.currentGeneration
            pauseNativeState = res.reply?.stateToken ?: "none"
            if (!pauseAccepted || res.state != State.PAUSED) throw FailClosed("disconnect_pause_rejected:${res.reason}")
            if (res.reply?.state != NativeState.PAUSED) throw FailClosed("disconnect_native_not_paused:$pauseNativeState")
            lanes[LANE_ROUTE_DISCONNECT_FAIL_CLOSED_PAUSE] = parked && pauseAccepted && pauseGeneration == startGeneration &&
                machine.currentState == State.PAUSED && !s.autoResumeAllowed && s.phase == Phase.PARKED

            // Frozen hold: no dispatch / push / drain / write while paused;
            // the sink stays PLAYSTATE_PAUSED at every parked poll slice.
            val t0 = snapshotReply("disconnect_hold_start", machine)
            holdStart = t0
            holdStartPlayState = s.observedPlayState
            val drains0 = s.drainCalls
            val written0 = s.framesWrittenToSink
            val observations0 = s.parkedPlayStateObservations
            val holdStartedAt = SystemClock.elapsedRealtime()
            val holdEndAt = holdStartedAt + config.pauseHoldMs
            while (true) {
                pollFailure()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_during_disconnect_hold:${s.exitReason}")
                val remaining = holdEndAt - SystemClock.elapsedRealtime()
                if (remaining <= 0L) break
                sleepSlice(minOf(remaining, WAIT_SLICE_MS))
            }
            val t1 = snapshotReply("disconnect_hold_end", machine)
            holdEnd = t1
            holdActualMs = SystemClock.elapsedRealtime() - holdStartedAt
            holdEndPlayState = s.observedPlayState
            holdDispatchDelta = t1.dispatchCount - t0.dispatchCount
            holdPushedDelta = t1.pushedFrames - t0.pushedFrames
            holdDrainCallsDelta = s.drainCalls - drains0
            holdWrittenDelta = s.framesWrittenToSink - written0
            val frozen = t0.state == NativeState.PAUSED && t1.state == NativeState.PAUSED &&
                machine.currentState == State.PAUSED &&
                holdDispatchDelta == 0L && holdPushedDelta == 0L && holdDrainCallsDelta == 0L && holdWrittenDelta == 0L &&
                t1.positionFrame == t0.positionFrame && t1.drainedFrames == t0.drainedFrames &&
                s.drainCalls == s.drainCallsAtPark && s.framesWrittenToSink == s.framesWrittenAtPark &&
                holdStartPlayState == AudioTrack.PLAYSTATE_PAUSED && holdEndPlayState == AudioTrack.PLAYSTATE_PAUSED &&
                s.parkedPlayStateViolations == 0L && s.parkedPlayStateObservations > observations0 &&
                s.phase == Phase.PARKED && !s.autoResumeAllowed && s.parkCount == 1 &&
                holdActualMs >= config.pauseHoldMs && completedCount.get() == 0
            lanes[LANE_ROUTE_DISCONNECT_HOLD_FROZEN] = frozen
            if (!frozen) {
                throw FailClosed(
                    "disconnect_hold_not_frozen:dispatch=$holdDispatchDelta:pushed=$holdPushedDelta:" +
                        "drains=$holdDrainCallsDelta:written=$holdWrittenDelta:sink=$holdStartPlayState>$holdEndPlayState",
                )
            }
            verifyPrefix(s, "disconnect")

            // Sink exit (routing controller released then AudioTrack released
            // on the sink thread), then leave no live transport behind: one
            // stop of the still-PAUSED transport (never COMPLETED).
            exitSink(s, f)
            stopTransportOnce(machine, "disconnect_teardown")
            lanes[LANE_TRANSPORT_STOPPED] = stopAccepted && machine.currentState == State.STOPPED && stopCalls == 1 &&
                stopGeneration == startGeneration + 1L && completedCount.get() == 0 && failedCount.get() == 0 &&
                s.exitReason == VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.EXIT_TERMINAL
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
                val c = controller ?: throw FailClosed("controller_missing")
                val machine = sm ?: throw FailClosed("transport_missing")

                awaitInitialWrites(s)
                drainAtLeast(s, "pre_route_changed", config.phaseFrames)
                observeSyntheticRouteChanged(s, c, machine)
                drainAtLeast(s, "post_route_changed", config.phaseFrames * SHARED_PHASES)

                when (scenario) {
                    Scenario.EOS_WITH_DEAD_OBJECT_RECOVERY -> tailEos(s, f)
                    Scenario.ROUTE_DISCONNECT_TERMINAL -> tailDisconnect(s, c, machine, f)
                }
                if (failure.get() != null) cancelThreads()
                joinBoth()

                val snapRes = machine.snapshot()
                finalReply = snapRes.reply ?: s.lastReply
                if (failure.get() == null && (!snapRes.accepted || finalReply == null)) {
                    recordFailure("final_snapshot_rejected:${snapRes.reason}")
                }

                // Routing controller was released on the sink thread; a late
                // synthetic post must be rejected.
                releaseController(c)

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
                if (failure.get() == null && final != null) evaluate(f, s, c, machine, final)
            } catch (fc: FailClosed) {
                recordFailure(fc.reason)
            } catch (t: Throwable) {
                recordFailure("exception:${t.javaClass.simpleName}:${t.message}")
            } finally {
                cancelThreads()
                joinBoth()
                controller?.let { releaseController(it) }
                sessionWallMs = SystemClock.elapsedRealtime() - wallStart
            }
        }

        // Idempotent: the sink thread releases the controller on every exit
        // path; this only covers a sink that never started and records the
        // late-post rejection + telemetry once.
        private fun releaseController(c: VanguardRealtimePlaybackRoutingController) {
            if (controllerTelemetry.isNotEmpty()) return
            if (!c.isReleased) {
                try {
                    c.release()
                } catch (_: Throwable) {}
            }
            lateSyntheticPostRejected = !c.postSyntheticRouteChanged() && !c.postSyntheticRouteDisconnect()
            ignoredAfterRelease = c.ignoredAfterReleaseCount
            controllerTelemetry = c.telemetry()
        }

        private fun evaluate(
            f: VanguardRealtimePlaybackDecoderFeed,
            s: VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge,
            c: VanguardRealtimePlaybackRoutingController,
            machine: VanguardRealtimePlaybackTransportStateMachine,
            final: Reply,
        ) {
            val fmt = format ?: return
            val declared = fmt.declaredFrameCount
            val bytesPerFrame = 2L * fmt.channelCount
            val coordinatorThreadId = Thread.currentThread().id
            lanes[LANE_FORMAT_PROBE] = fmt.sampleRate > 0 && fmt.channelCount in 1..2 && declared > 0L && fmt.sourceMime.isNotBlank()
            lanes[LANE_PRE_ROLL] = preRollFrames > 0L && (preRollRingFull || preRollFrames == declared) &&
                preRollStatePrepared && startAcceptedPlaying && preRollFrames <= declared

            val expectedTracks: Int
            val expectedAttach: Int
            if (scenario == Scenario.EOS_WITH_DEAD_OBJECT_RECOVERY) {
                expectedTracks = 2
                expectedAttach = 2
                val decoderHex = f.checksumHex
                val remainderFrames = if (s.deadObjectUnwrittenBytesAtRecovery > 0L) s.deadObjectUnwrittenBytesAtRecovery / bytesPerFrame else -1L
                lanes[LANE_DEAD_OBJECT_INJECTED_ONCE] = s.syntheticDeadObjectInjectedCount == 1L && s.deadObjectObservedCount == 1L &&
                    s.deadObjectSinkFramesWrittenBeforeRecovery >= s.deadObjectInjectAfterFrames &&
                    s.deadObjectSinkFramesWrittenBeforeRecovery >= framesWrittenAtRouteChanged &&
                    s.deadObjectSinkFramesWrittenBeforeRecovery < declared &&
                    s.deadObjectFramesReadAtRecovery >= s.deadObjectSinkFramesWrittenBeforeRecovery &&
                    s.deadObjectUnwrittenBytesAtRecovery > 0L && s.deadObjectUnwrittenBytesAtRecovery % bytesPerFrame == 0L &&
                    s.deadObjectSliceBytesAtRecovery >= s.deadObjectUnwrittenBytesAtRecovery &&
                    s.deadObjectBufferPositionAtRecovery >= 0L && s.syntheticRouteChangedApplySeq >= 0L &&
                    s.routeDisconnectAppliedCount == 0L && s.parkCount == 0
                lanes[LANE_DEAD_OBJECT_OLD_TRACK_RELEASED] = s.deadObjectOldTrackReleaseCount == 1L &&
                    s.deadObjectOldTrackListenerDetachOk && s.audioTracksCreated == 2 && s.audioTracksReleased == 2 &&
                    s.releaseCount.get() == 1
                lanes[LANE_DEAD_OBJECT_NEW_TRACK_STATE_INITIALIZED] = s.deadObjectNewTrackStateInitialized &&
                    s.deadObjectNewTrackBufferSizeInFrames > 0L &&
                    s.deadObjectNewTrackBufferSizeInFrames == s.frozenBufferSizeInFrames
                lanes[LANE_DEAD_OBJECT_NEW_TRACK_VOLUME_SET] = s.deadObjectNewTrackVolumeSet && s.gainValue == config.baseVolume &&
                    s.setVolumeCalls == 2L && s.gainSetOk
                lanes[LANE_DEAD_OBJECT_NEW_TRACK_PLAY] = s.deadObjectNewTrackPlayOk &&
                    s.deadObjectNewTrackPlayState == AudioTrack.PLAYSTATE_PLAYING && s.deadObjectListenerHandoffOk &&
                    c.attachCount == 2 && c.detachCount == 2
                lanes[LANE_DEAD_OBJECT_REMAINDER_RESUMED] = s.deadObjectRemainderResumedOk && remainderFrames > 0L &&
                    s.deadObjectRemainderFramesWrittenOnNewTrack == remainderFrames
                lanes[LANE_DEAD_OBJECT_NO_DOUBLE_COUNT] = s.deadObjectRemainderResumedOk && remainderFrames > 0L &&
                    s.deadObjectSinkFramesWrittenBeforeRecovery + remainderFrames == s.deadObjectSinkFramesWrittenAfterRecoveryCall &&
                    s.framesWrittenToSink == s.framesReadFromTransport && s.framesWrittenToSink == declared &&
                    s.deadObjectObservedCount == 1L && s.syntheticDeadObjectInjectedCount == 1L
                lanes[LANE_TRANSPORT_COMPLETED] = stateAtCompletion == State.COMPLETED && final.state == NativeState.COMPLETED &&
                    completedCount.get() == 1 && failedCount.get() == 0 && final.positionFrame == declared &&
                    final.eosPushed && final.eosDrained && final.lastError == "none" && s.autoResumeAllowed && stopCalls == 0
                lanes[LANE_SINK_WRITE_ACCOUNTING] = s.exitReason == VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.EXIT_EOS &&
                    s.eosDrainedObserved && f.exitReason == VanguardRealtimePlaybackDecoderFeed.EXIT_EOS &&
                    f.acceptedFrames == declared && s.framesReadFromTransport == declared && s.framesWrittenToSink == declared &&
                    final.pushedFrames == declared && final.drainedFrames == declared && final.discardedFrames == 0L &&
                    s.playbackHeadFinal > 0L
                lanes[LANE_CHECKSUM_IDENTITY] = decoderHex.isNotBlank() &&
                    decoderHex.equals(final.pushedChecksumHex, ignoreCase = true) &&
                    decoderHex.equals(final.drainedChecksumHex, ignoreCase = true) &&
                    decoderHex.equals(s.checksumHex, ignoreCase = true)
            } else {
                expectedTracks = 1
                expectedAttach = 1
            }

            val telemetry = controllerTelemetry
            val expectedDisconnectPosts = if (scenario == Scenario.ROUTE_DISCONNECT_TERMINAL) 1L else 0L
            lanes[LANE_ROUTING_LIFECYCLE] = listenerAttachedBeforeStart && c.isReleased && !c.isAttached &&
                c.attachCount == expectedAttach && c.detachCount == c.attachCount &&
                c.lastAttachError.isEmpty() && c.lastDetachError.isEmpty() &&
                c.droppedCount == 0L && c.pendingCount == 0 && c.enqueuedCount == c.drainedCount &&
                c.syntheticRouteChangedPostedCount == 1L && c.syntheticRouteDisconnectPostedCount == expectedDisconnectPosts &&
                c.drainedCountFor(Tag.ROUTE_DISCONNECT) == expectedDisconnectPosts &&
                s.routeDisconnectAppliedCount == expectedDisconnectPosts &&
                lateSyntheticPostRejected && (telemetry["released"] as? Boolean) == true
            lanes[LANE_AUDIO_TRACK_LIFECYCLE] = s.audioTrackInitOk && s.gainSetOk && s.releaseCount.get() == 1 &&
                s.audioTracksCreated == expectedTracks && s.audioTracksReleased == s.audioTracksCreated &&
                s.audioTrackOpsOffSinkThread == 0L &&
                feedJoined && sinkJoined && f.mediaReleaseCount.get() == 1L && f.mediaReleaseClean &&
                disposeCalls == 1 && stateAfterDispose == State.DISPOSED && stateAfterSecondDispose == State.DISPOSED &&
                !postIngestAfterDispose && machine.currentState == State.DISPOSED &&
                (scenario == Scenario.EOS_WITH_DEAD_OBJECT_RECOVERY || s.terminalExitOnSinkThread)
            val scenarioOnSinkThread = when (scenario) {
                Scenario.EOS_WITH_DEAD_OBJECT_RECOVERY -> s.deadObjectRecoveryOnSinkThread
                Scenario.ROUTE_DISCONNECT_TERMINAL -> s.parkAppliedOnSinkThread && disconnectPostedOnCoordinatorThread
            }
            lanes[LANE_THREAD_OWNERSHIP] = f.ingestCallbacksOnOwner.get() > 0L && f.ingestCallbacksOffOwner.get() == 0L &&
                !f.threadIsTransportOwner && !s.threadIsTransportOwner &&
                f.threadId > 0L && s.threadId > 0L && f.threadId != s.threadId &&
                f.threadId != coordinatorThreadId && s.threadId != coordinatorThreadId &&
                s.eventsAppliedOnSinkThread > 0L && s.eventsAppliedOffSinkThread == 0L &&
                s.audioTrackOpsOffSinkThread == 0L && scenarioOnSinkThread &&
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
            metrics["sinkExitReason"] = s?.exitReason ?: VanguardRealtimePlaybackPipelineSinkFaultToleranceSinkBridge.EXIT_NOT_STARTED
            metrics["framesReadFromTransport"] = s?.framesReadFromTransport ?: 0L
            metrics["framesWrittenToSink"] = s?.framesWrittenToSink ?: 0L
            metrics["partialWriteCount"] = s?.partialWriteCount ?: 0L
            metrics["zeroWriteCount"] = s?.zeroWriteCount ?: 0L
            metrics["drainCalls"] = s?.drainCalls ?: 0L
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
            metrics["eventsAppliedOnSinkThread"] = s?.eventsAppliedOnSinkThread ?: 0L
            metrics["eventsAppliedOffSinkThread"] = s?.eventsAppliedOffSinkThread ?: 0L
            metrics["transportCommandsIssued"] = commandsIssued
            metrics["transportPrepareGeneration"] = prepareGeneration
            metrics["transportStartGeneration"] = startGeneration
            metrics["transportPauseGeneration"] = pauseGeneration
            metrics["transportStopGeneration"] = stopGeneration
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
            metrics["eosPushed"] = final?.eosPushed ?: false
            metrics["eosDrained"] = final?.eosDrained ?: false
            metrics["lastError"] = final?.lastError ?: "none"
            metrics["kotlinDecoderChecksumHex"] = f?.checksumHex ?: ""
            metrics["kotlinSinkChecksumHex"] = s?.checksumHex ?: ""
            metrics["kotlinSinkChecksumAtParkHex"] = s?.checksumAtParkHex ?: ""
            metrics["nativePushedChecksumHex"] = final?.pushedChecksumHex ?: ""
            metrics["nativeDrainedChecksumHex"] = final?.drainedChecksumHex ?: ""
            metrics["prefixNativeDrainedChecksumHex"] = prefixReply?.drainedChecksumHex ?: ""
            metrics["prefixNativeDrainedFrames"] = prefixReply?.drainedFrames ?: -1L
            metrics["prefixSinkChecksumHex"] = prefixSinkHex
            // Sink setup / head.
            metrics["setupWaitMs"] = setupWaitMs
            metrics["setupCompleteBeforeStart"] = setupCompleteBeforeStart
            metrics["listenerAttachedBeforeStart"] = listenerAttachedBeforeStart
            metrics["preStartDrainEmptyBeforeStart"] = preStartDrainEmptyBeforeStart
            metrics["preStartPendingEvents"] = s?.preStartPendingCount ?: -1
            metrics["transportStateAtSetup"] = transportStateAtSetup.name
            metrics["startGateWaitMs"] = s?.startGateWaitMs ?: -1L
            metrics["initialWriteWaitMs"] = initialWriteWaitMs
            metrics["syntheticRouteChangedPosted"] = syntheticRouteChangedPosted
            metrics["routeChangedWaitMs"] = routeChangedWaitMs
            metrics["framesWrittenAtRouteChanged"] = framesWrittenAtRouteChanged
            metrics["audioTracksAtRouteChanged"] = audioTracksAtRouteChanged
            metrics["routeChangedAppliedCount"] = s?.routeChangedAppliedCount ?: 0L
            metrics["syntheticRouteChangedAppliedCount"] = s?.syntheticRouteChangedAppliedCount ?: 0L
            metrics["realRouteChangedAppliedCount"] = s?.realRouteChangedAppliedCount ?: 0L
            metrics["routeChangedAfterDisconnectCount"] = s?.routeChangedAfterDisconnectCount ?: 0L
            metrics["routeChangedApplySeq"] = s?.routeChangedApplySeq ?: -1L
            metrics["syntheticRouteChangedApplySeq"] = s?.syntheticRouteChangedApplySeq ?: -1L
            metrics["routedDeviceSampleOk"] = s?.routedDeviceSampleOk ?: false
            metrics["routedDeviceTypeAtRouteChanged"] = s?.routedDeviceTypeAtRouteChanged ?: -1
            metrics["lastAppliedSeq"] = s?.lastAppliedSeq ?: -1L
            metrics["lastAppliedTag"] = s?.lastAppliedTag ?: "none"
            // Dead object.
            metrics["deadObjectInjectAfterFrames"] = s?.deadObjectInjectAfterFrames ?: -1L
            metrics["syntheticDeadObjectInjectedCount"] = s?.syntheticDeadObjectInjectedCount ?: 0L
            metrics["deadObjectObservedCount"] = s?.deadObjectObservedCount ?: 0L
            metrics["deadObjectOldTrackReleaseCount"] = s?.deadObjectOldTrackReleaseCount ?: 0L
            metrics["deadObjectOldTrackListenerDetachOk"] = s?.deadObjectOldTrackListenerDetachOk ?: false
            metrics["deadObjectNewTrackStateInitialized"] = s?.deadObjectNewTrackStateInitialized ?: false
            metrics["deadObjectNewTrackBufferSizeInFrames"] = s?.deadObjectNewTrackBufferSizeInFrames ?: -1L
            metrics["deadObjectNewTrackVolumeSet"] = s?.deadObjectNewTrackVolumeSet ?: false
            metrics["deadObjectListenerHandoffOk"] = s?.deadObjectListenerHandoffOk ?: false
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
            // Disconnect tail.
            metrics["autoResumeAllowed"] = s?.autoResumeAllowed ?: true
            metrics["sinkPhaseFinal"] = s?.phase?.name ?: "none"
            metrics["sinkParkReasonFinal"] = s?.parkReason?.name ?: "none"
            metrics["sinkParkCount"] = s?.parkCount ?: 0
            metrics["routeDisconnectAppliedCount"] = s?.routeDisconnectAppliedCount ?: 0L
            metrics["routeDisconnectApplySeq"] = s?.routeDisconnectApplySeq ?: -1L
            metrics["disconnectPostedOnCoordinatorThread"] = disconnectPostedOnCoordinatorThread
            metrics["disconnectPostAccepted"] = disconnectPostAccepted
            metrics["disconnectPendingAfterPost"] = disconnectPendingAfterPost
            metrics["disconnectParkWaitMs"] = disconnectParkWaitMs
            metrics["transportStateAtPark"] = transportStateAtPark.name
            metrics["sinkPlayStateAtPark"] = s?.playStateAtPark ?: -1
            metrics["sinkObservedPlayStateFinal"] = s?.observedPlayState ?: -1
            metrics["sinkParkedPlayStateObservations"] = s?.parkedPlayStateObservations ?: 0L
            metrics["sinkParkedPlayStateViolations"] = s?.parkedPlayStateViolations ?: 0L
            metrics["sinkFramesWrittenAtPark"] = s?.framesWrittenAtPark ?: 0L
            metrics["sinkFramesReadAtPark"] = s?.framesReadAtPark ?: 0L
            metrics["sinkDrainCallsAtPark"] = s?.drainCallsAtPark ?: 0L
            metrics["sinkPlaybackHeadAtPark"] = s?.playbackHeadAtPark ?: 0L
            metrics["sinkParkAppliedOnSinkThread"] = s?.parkAppliedOnSinkThread ?: false
            metrics["sinkParkedHoldMs"] = s?.parkedHoldMs ?: -1L
            metrics["sinkTerminalExitOnSinkThread"] = s?.terminalExitOnSinkThread ?: false
            metrics["pauseAccepted"] = pauseAccepted
            metrics["pauseReason"] = pauseReason
            metrics["pauseNativeState"] = pauseNativeState
            metrics["holdStartNativeState"] = holdStart?.stateToken ?: "none"
            metrics["holdEndNativeState"] = holdEnd?.stateToken ?: "none"
            metrics["holdStartSinkPlayState"] = holdStartPlayState
            metrics["holdEndSinkPlayState"] = holdEndPlayState
            metrics["holdDispatchDelta"] = holdDispatchDelta
            metrics["holdPushedDelta"] = holdPushedDelta
            metrics["holdDrainCallsDelta"] = holdDrainCallsDelta
            metrics["holdWrittenDelta"] = holdWrittenDelta
            metrics["holdActualMs"] = holdActualMs
            metrics["terminalPositionFrame"] = terminalPositionFrame
            metrics["terminalPositionLimit"] = terminalPositionLimit
            metrics["stopCalls"] = stopCalls
            metrics["stopAccepted"] = stopAccepted
            metrics["stopState"] = stopState.name
            metrics["stopReason"] = stopReason
            metrics["lateSyntheticPostRejected"] = lateSyntheticPostRejected
            metrics["lateRoutingEventsAtTeardown"] = s?.lateEventsAtTeardown ?: 0L
            metrics["routingEventsIgnoredAfterRelease"] = ignoredAfterRelease
            metrics["sinkThreadWallMs"] = s?.sinkThreadWallMs ?: -1L
            metrics["sessionWallMs"] = sessionWallMs
            for ((k, v) in controllerTelemetry) metrics["routing_$k"] = v
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
