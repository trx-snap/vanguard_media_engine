package com.connects.vanguard_media_engine.audio_playback_graph

import android.content.Context
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.NativeState
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackPipelineFocusResponseSinkBridge.ParkReason
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackPipelineFocusResponseSinkBridge.Phase
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.IngestRequest
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

// ── VanguardRealtimePlaybackPipelineFocusResponseCoordinator (P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-FOCUS-RESPONSE, Y6d) ─
//
// The ONLY transport command owner of the Y6d focus / becoming-noisy
// response proof over the committed Y6a/Y6b pipeline shape:
//
//   MediaExtractor/MediaCodec  ->  Y5a external ingest seam  ->  Y1 native
//   ([VanguardRealtimePlaybackDecoderFeed], decode thread, unchanged)
//   transport (owner HandlerThread inside the state machine)  ->
//   non-zero-gain AudioTrack MODE_STREAM
//   ([VanguardRealtimePlaybackPipelineFocusResponseSinkBridge], sink thread)
//   + one Y4a [VanguardRealtimePlaybackAudioFocusController] per scenario
//   (OS / synthetic callbacks only enqueue on the main Handler).
//
// Thread model: the decoder feed thread only posts generation-pinned
// ingest; the sink thread only drains, owns every AudioTrack call and
// applies every focus event; the state machine is the only JNI caller;
// this coordinator (the caller's worker thread) issues transport commands
// (load, prepare, start, pause, resume, stop) in response to the sink's
// published park / unpark state, posts synthetic events through the
// controller, waits/joins and aggregates. It never calls an AudioTrack
// method and never applies an event.
//
// Three scenarios run sequentially in one smoke, each with its own feed,
// transport, sink, focus controller and AudioTrack. Shared head: focus
// granted + noisy receiver registered + empty pre-start drain BEFORE
// transport start -> first positive sink write -> duck (gain only) ->
// gain restore -> transient loss (sink parks, then transport.pause(),
// frozen hold) -> gain (sink unparks, then transport.resume()).
//   EOS_COMPLETION:          drain to EOS, transport COMPLETED, full
//                            checksum identity (decoder == pushed ==
//                            drained == sink).
//   BECOMING_NOISY_TERMINAL: sink parks terminal (autoResumeAllowed=false)
//                            -> transport.pause() -> frozen hold -> prefix
//                            identity -> sink exit -> transport.stop()
//                            once (never COMPLETED, no completion claim).
//   PERMANENT_LOSS_TERMINAL: sink parks terminal -> transport.stop() ->
//                            prefix identity -> later GAIN recorded and
//                            rejected (no play, no resume) -> sink exit.
//
// Teardown per scenario: feed cancel/stop, sink exit (AudioTrack released
// once on the sink thread), controller.release() (receiver unregistered
// once, focus abandoned once; a late synthetic post is rejected), state
// machine disposed once. First failure wins; joins are bounded.
//
// No seek, route change, dead-object recovery, presentation clock, A/V
// sync, acoustic claim, product/editor/app wiring, iOS, streaming/cache
// or C++ change lives here.
class VanguardRealtimePlaybackPipelineFocusResponseCoordinator(
    private val context: Context,
    private val mainHandler: Handler,
) {

    enum class Scenario { EOS_COMPLETION, BECOMING_NOISY_TERMINAL, PERMANENT_LOSS_TERMINAL }

    data class Config(
        val sourcePath: String,
        val maxDurationSec: Double = 3.0,
        val maxFramesPerMix: Int = 256,
        val baseVolume: Float = VanguardRealtimePlaybackPipelineFocusResponseSinkBridge.DEFAULT_BASE_VOLUME,
        val duckVolume: Float = VanguardRealtimePlaybackPipelineFocusResponseSinkBridge.DEFAULT_DUCK_VOLUME,
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
            "realtime_playback_pipeline_focus_response_diagnostic_only_real_mediaextractor_mediacodec_" +
                "to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_" +
                "synthetic_focus_noisy_events_sink_thread_applies_events_coordinator_owns_transport_commands_" +
                "no_seek_no_route_change_no_dead_object_recovery_no_presentation_clock_no_av_sync_" +
                "no_acoustic_no_loudness_no_snr_no_latency_no_glitch_claim_no_product_no_editor_no_app_wiring_" +
                "no_connectsapp_no_ios_no_streaming_no_cache_no_cpp_changes"

        const val DEFAULT_PAUSE_HOLD_MS = 150L
        const val MAX_PAUSE_HOLD_MS = 2_000L
        const val DEFAULT_PHASE_FRAMES = 2_048L

        const val LANE_FORMAT_PROBE = "formatProbeOk"
        const val LANE_PRE_ROLL = "preRollOk"
        const val LANE_FOCUS_GRANTED = "focusGrantedOk"
        const val LANE_NOISY_RECEIVER_REGISTERED = "noisyReceiverRegisteredOk"
        const val LANE_PRE_START_DRAIN_EMPTY = "preStartDrainEmptyOk"
        const val LANE_DUCK_APPLIED = "duckAppliedOk"
        const val LANE_DUCK_RESTORE = "duckRestoreOk"
        const val LANE_TRANSIENT_PAUSE_RESUME = "transientPauseResumeOk"
        const val LANE_BECOMING_NOISY_PAUSE = "becomingNoisyPauseOk"
        const val LANE_PERMANENT_STOP_NO_AUTO_RESUME = "permanentStopNoAutoResumeOk"
        const val LANE_SINK_WRITE_ACCOUNTING = "sinkWriteAccountingOk"
        const val LANE_CHECKSUM_IDENTITY = "checksumIdentityOk"
        const val LANE_TRANSPORT_COMPLETED = "transportCompletedOk"
        const val LANE_TRANSPORT_STOPPED = "transportStoppedOk"
        const val LANE_FOCUS_LIFECYCLE = "focusLifecycleOk"
        const val LANE_AUDIO_TRACK_LIFECYCLE = "audioTrackLifecycleOk"
        const val LANE_THREAD_OWNERSHIP = "threadOwnershipOk"
        const val LANE_PROOF_BOUNDARY = "proofBoundaryOk"
        const val LANE_CANONICAL = "canonical"

        val REQUIRED_LANES: List<String> = listOf(
            LANE_FORMAT_PROBE,
            LANE_PRE_ROLL,
            LANE_FOCUS_GRANTED,
            LANE_NOISY_RECEIVER_REGISTERED,
            LANE_PRE_START_DRAIN_EMPTY,
            LANE_DUCK_APPLIED,
            LANE_DUCK_RESTORE,
            LANE_TRANSIENT_PAUSE_RESUME,
            LANE_BECOMING_NOISY_PAUSE,
            LANE_PERMANENT_STOP_NO_AUTO_RESUME,
            LANE_SINK_WRITE_ACCOUNTING,
            LANE_CHECKSUM_IDENTITY,
            LANE_TRANSPORT_COMPLETED,
            LANE_TRANSPORT_STOPPED,
            LANE_FOCUS_LIFECYCLE,
            LANE_AUDIO_TRACK_LIFECYCLE,
            LANE_THREAD_OWNERSHIP,
            LANE_PROOF_BOUNDARY,
        )

        // Lanes every scenario must hold; the rest are scenario-specific.
        private val SHARED_LANES = listOf(
            LANE_FORMAT_PROBE, LANE_PRE_ROLL, LANE_FOCUS_GRANTED, LANE_NOISY_RECEIVER_REGISTERED,
            LANE_PRE_START_DRAIN_EMPTY, LANE_DUCK_APPLIED, LANE_DUCK_RESTORE, LANE_TRANSIENT_PAUSE_RESUME,
            LANE_SINK_WRITE_ACCOUNTING, LANE_CHECKSUM_IDENTITY, LANE_FOCUS_LIFECYCLE,
            LANE_AUDIO_TRACK_LIFECYCLE, LANE_THREAD_OWNERSHIP,
        )

        private const val WAIT_SLICE_MS = 5L
        private const val JOIN_TIMEOUT_MS = 5_000L
        private const val INITIAL_WRITE_WAIT_MS = 2_000L
        private const val EVENT_APPLY_TIMEOUT_MS = 2_000L
        private const val PHASE_WAIT_TIMEOUT_MS = 6_000L
        private const val SHARED_PHASES = 4L
        // Terminal events must land well before the declared end.
        private const val TERMINAL_MARGIN_WINDOWS = 8L
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

    // Executes all three scenarios on the calling thread. Single use.
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
        if (!(config.duckVolume > 0f) || config.duckVolume >= config.baseVolume) throw FailClosed("invalid_duck_volume")
        if (config.deadlineMs <= 0L) throw FailClosed("invalid_deadline")
        if (config.pauseHoldMs <= 0L || config.pauseHoldMs > MAX_PAUSE_HOLD_MS) throw FailClosed("invalid_pause_hold")
        if (config.phaseFrames <= 0L) throw FailClosed("invalid_phase_frames")
        if (cancelled.get()) throw FailClosed("cancelled")
        val deadlineAtMs = SystemClock.elapsedRealtime() + config.deadlineMs
        metrics["maxDurationSec"] = config.maxDurationSec
        metrics["maxFramesPerMix"] = config.maxFramesPerMix
        metrics["baseVolume"] = config.baseVolume.toDouble()
        metrics["duckVolume"] = config.duckVolume.toDouble()
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
        lanes[LANE_TRANSPORT_COMPLETED] = laneOf(results[Scenario.EOS_COMPLETION], LANE_TRANSPORT_COMPLETED)
        lanes[LANE_BECOMING_NOISY_PAUSE] = laneOf(results[Scenario.BECOMING_NOISY_TERMINAL], LANE_BECOMING_NOISY_PAUSE)
        lanes[LANE_PERMANENT_STOP_NO_AUTO_RESUME] =
            laneOf(results[Scenario.PERMANENT_LOSS_TERMINAL], LANE_PERMANENT_STOP_NO_AUTO_RESUME)
        lanes[LANE_TRANSPORT_STOPPED] = laneOf(results[Scenario.PERMANENT_LOSS_TERMINAL], LANE_TRANSPORT_STOPPED)
        for (scenario in Scenario.entries) {
            val s = results[scenario]
            metrics["${scenario.name.lowercase()}ScenarioPass"] = s != null && s.failure.get() == null && s.scenarioLanesHeld()
        }
    }

    private fun isCancelled(): Boolean = cancelled.get()

    // ── One scenario session (feed + transport + sink + focus controller) ──

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
        @Volatile var sink: VanguardRealtimePlaybackPipelineFocusResponseSinkBridge? = null
        @Volatile var controller: VanguardRealtimePlaybackAudioFocusController? = null

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

        // Focus head observations.
        var initialWriteWaitMs = -1L
        var framesWrittenBeforeDuck = 0L
        var focusGranted = false
        var receiverRegistered = false
        var preStartPending = -1
        var pauseAccepted = false
        var pauseReason = ""
        var pauseGeneration = -1L
        var resumeAccepted = false
        var resumeReason = ""
        var resumeGeneration = -1L
        var holdStart: Reply? = null
        var holdEnd: Reply? = null
        var holdDispatchDelta = -1L
        var holdPushedDelta = -1L
        var holdDrainCallsDelta = -1L
        var holdWrittenDelta = -1L
        var holdActualMs = -1L
        var holdStartPlayState = VanguardRealtimePlaybackPipelineFocusResponseSinkBridge.PLAY_STATE_UNKNOWN
        var holdEndPlayState = VanguardRealtimePlaybackPipelineFocusResponseSinkBridge.PLAY_STATE_UNKNOWN
        var framesWrittenAtResume = 0L
        var drainCallsAtResume = 0L
        var framesWrittenAfterResume = 0L
        // Terminal tail observations.
        var terminalPositionFrame = -1L
        var terminalPositionLimit = -1L
        var terminalHoldDispatchDelta = -1L
        var terminalHoldPushedDelta = -1L
        var stopAccepted = false
        var stopState = State.IDLE
        var stopReason = ""
        var stopGeneration = -1L
        var stopCalls = 0
        var prefixReply: Reply? = null
        var prefixSinkHex = ""
        var gainRejectedObserved = false
        var setVolumeCallsBeforeGainAttempt = -1L
        var setVolumeCallsAfterGainAttempt = -1L
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
                Scenario.EOS_COMPLETION -> listOf(LANE_TRANSPORT_COMPLETED)
                Scenario.BECOMING_NOISY_TERMINAL -> listOf(LANE_BECOMING_NOISY_PAUSE)
                Scenario.PERMANENT_LOSS_TERMINAL -> listOf(LANE_PERMANENT_STOP_NO_AUTO_RESUME, LANE_TRANSPORT_STOPPED)
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
                s.exitReason != VanguardRealtimePlaybackPipelineFocusResponseSinkBridge.EXIT_RUNNING &&
                s.exitReason != VanguardRealtimePlaybackPipelineFocusResponseSinkBridge.EXIT_EOS &&
                s.exitReason != VanguardRealtimePlaybackPipelineFocusResponseSinkBridge.EXIT_TERMINAL &&
                s.exitReason != VanguardRealtimePlaybackPipelineFocusResponseSinkBridge.EXIT_NOT_STARTED
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
            s: VanguardRealtimePlaybackPipelineFocusResponseSinkBridge,
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

        private fun postFocus(c: VanguardRealtimePlaybackAudioFocusController, focusChange: Int, phase: String) {
            checkDeadlineAndCancel()
            if (!c.postSyntheticFocusChange(focusChange)) throw FailClosed("synthetic_post_rejected_$phase")
        }

        // ── Open / focus / start ───────────────────────────────────────────

        private fun openAndStart() {
            checkDeadlineAndCancel()
            val tag = scenario.name.lowercase()
            val f = VanguardRealtimePlaybackDecoderFeed(
                VanguardRealtimePlaybackDecoderFeed.Config(
                    sourcePath = config.sourcePath,
                    maxDurationSec = config.maxDurationSec,
                    maxFramesPerMix = config.maxFramesPerMix,
                    deadlineAtMs = deadlineAtMs,
                    threadName = "Y6dDecoderFeed_$tag",
                    externallyCancelled = { sessionCancelled() },
                ),
            )
            feed = f
            if (!f.start()) throw FailClosed("feed_start_rejected")
            val fmt = f.awaitFormat(remainingMs()) ?: throw FailClosed("format_probe_failed:${f.exitReason}")
            format = fmt
            checkDeadlineAndCancel()

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
            val machine = VanguardRealtimePlaybackTransportStateMachine(sessionConfig, listener, threadName = "Y6dTransport_$tag")
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

            // Focus + noisy receiver BEFORE transport start; fail closed.
            val c = VanguardRealtimePlaybackAudioFocusController(context, mainHandler)
            controller = c
            focusGranted = c.requestFocus()
            lanes[LANE_FOCUS_GRANTED] = focusGranted
            if (!focusGranted) throw FailClosed("focus_not_granted:${c.telemetry()["focusRequestError"]}")
            receiverRegistered = c.registerNoisyReceiver()
            lanes[LANE_NOISY_RECEIVER_REGISTERED] = receiverRegistered
            if (!receiverRegistered) throw FailClosed("noisy_receiver_register_failed:${c.telemetry()["receiverRegisterError"]}")
            val preStart = c.drainAll()
            preStartPending = preStart.size
            lanes[LANE_PRE_START_DRAIN_EMPTY] = preStart.isEmpty()
            if (preStart.isNotEmpty()) {
                val first = preStart.first()
                throw FailClosed("unexpected_pre_start_event:${first.tag.name.lowercase()}:${first.source.name.lowercase()}")
            }

            val startRes = machine.start()
            commandsIssued++
            startAcceptedPlaying = startRes.accepted && startRes.state == State.PLAYING
            if (!startAcceptedPlaying) throw FailClosed("start_rejected:${startRes.reason}")
            startGeneration = machine.currentGeneration
            f.updateGeneration(startGeneration)
            f.markTransportStarted()

            val s = VanguardRealtimePlaybackPipelineFocusResponseSinkBridge(
                VanguardRealtimePlaybackPipelineFocusResponseSinkBridge.Config(
                    stateMachine = machine,
                    focusController = c,
                    sampleRate = fmt.sampleRate,
                    channelCount = fmt.channelCount,
                    maxFramesPerMix = config.maxFramesPerMix,
                    declaredFrameCount = fmt.declaredFrameCount,
                    baseVolume = config.baseVolume,
                    duckVolume = config.duckVolume,
                    deadlineAtMs = deadlineAtMs,
                    threadName = "Y6dSinkBridge_$tag",
                    externallyCancelled = { sessionCancelled() },
                ),
            )
            sink = s
            if (!s.start()) throw FailClosed("sink_start_rejected")
        }

        // ── Shared head (coordinator thread) ───────────────────────────────

        private fun awaitInitialWrites(s: VanguardRealtimePlaybackPipelineFocusResponseSinkBridge) {
            val waitStart = SystemClock.elapsedRealtime()
            awaitSink(s, "initial_write", INITIAL_WRITE_WAIT_MS) { s.framesWrittenToSink > 0L && s.played }
            initialWriteWaitMs = SystemClock.elapsedRealtime() - waitStart
        }

        private fun drainAtLeast(s: VanguardRealtimePlaybackPipelineFocusResponseSinkBridge, phase: String, target: Long) {
            awaitSink(s, phase, PHASE_WAIT_TIMEOUT_MS) { s.framesWrittenToSink >= target }
            val machine = sm ?: throw FailClosed("transport_missing")
            if (machine.currentState != State.PLAYING) throw FailClosed("transport_not_playing_after_$phase:${machine.currentState.name.lowercase()}")
            if (s.phase != Phase.RUNNING) throw FailClosed("sink_not_running_after_$phase")
        }

        private fun duckAndRestore(
            s: VanguardRealtimePlaybackPipelineFocusResponseSinkBridge,
            c: VanguardRealtimePlaybackAudioFocusController,
            machine: VanguardRealtimePlaybackTransportStateMachine,
        ) {
            framesWrittenBeforeDuck = s.framesWrittenToSink
            postFocus(c, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK, "duck")
            awaitSink(s, "duck_apply", EVENT_APPLY_TIMEOUT_MS) { s.duckAppliedCount >= 1L }
            lanes[LANE_DUCK_APPLIED] = s.duckAppliedCount == 1L && s.ducked && s.gainValue == config.duckVolume &&
                s.phase == Phase.RUNNING && machine.currentState == State.PLAYING && s.parkCount == 0
            if (lanes[LANE_DUCK_APPLIED] != true) throw FailClosed("duck_not_applied:${s.gainValue}")
            drainAtLeast(s, "ducked", config.phaseFrames * 2L)

            postFocus(c, AudioManager.AUDIOFOCUS_GAIN, "restore")
            awaitSink(s, "restore_apply", EVENT_APPLY_TIMEOUT_MS) { s.restoreAppliedCount >= 1L }
            lanes[LANE_DUCK_RESTORE] = s.restoreAppliedCount == 1L && !s.ducked && s.gainValue == config.baseVolume &&
                s.phase == Phase.RUNNING && s.unparkCount == 0 && s.focusGainResumeAppliedCount == 0L &&
                s.setVolumeCalls == 3L
            if (lanes[LANE_DUCK_RESTORE] != true) throw FailClosed("restore_not_applied:${s.gainValue}")
            drainAtLeast(s, "restored", config.phaseFrames * 3L)
        }

        // Transient loss: sink parks first (AudioTrack paused on the sink
        // thread), then transport.pause(); frozen hold; GAIN unparks the
        // sink (AudioTrack playing on the sink thread), then transport.resume().
        private fun transientPauseResume(
            s: VanguardRealtimePlaybackPipelineFocusResponseSinkBridge,
            c: VanguardRealtimePlaybackAudioFocusController,
            machine: VanguardRealtimePlaybackTransportStateMachine,
        ) {
            postFocus(c, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, "transient_loss")
            awaitSink(s, "transient_park", EVENT_APPLY_TIMEOUT_MS) { s.parkCount >= 1 && s.phase == Phase.PARKED }
            val parked = s.parkCount == 1 && s.parkReason == ParkReason.FOCUS_TRANSIENT &&
                s.transientPauseAppliedCount == 1L && s.playStateAtPark == AudioTrack.PLAYSTATE_PAUSED && s.autoResumeAllowed
            if (!parked) throw FailClosed("transient_park_not_observed:${s.parkReason.name.lowercase()}")

            val res = machine.pause()
            commandsIssued++
            pauseAccepted = res.accepted
            pauseReason = res.reason
            pauseGeneration = machine.currentGeneration
            if (!pauseAccepted || res.state != State.PAUSED) throw FailClosed("pause_rejected:${res.reason}")

            val t0 = snapshotReply("hold_start", machine)
            holdStart = t0
            holdStartPlayState = s.observedPlayState
            val drains0 = s.drainCalls
            val written0 = s.framesWrittenToSink
            val holdStartedAt = SystemClock.elapsedRealtime()
            val holdEndAt = holdStartedAt + config.pauseHoldMs
            while (true) {
                pollFailure()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_during_hold:${s.exitReason}")
                val remaining = holdEndAt - SystemClock.elapsedRealtime()
                if (remaining <= 0L) break
                sleepSlice(minOf(remaining, WAIT_SLICE_MS))
            }
            val t1 = snapshotReply("hold_end", machine)
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
                holdStartPlayState == AudioTrack.PLAYSTATE_PAUSED && holdEndPlayState == AudioTrack.PLAYSTATE_PAUSED &&
                s.parkedPlayStateViolations == 0L && s.parkedPlayStateObservations > 0L &&
                s.phase == Phase.PARKED && holdActualMs >= config.pauseHoldMs
            if (!frozen) {
                throw FailClosed(
                    "transient_hold_not_frozen:dispatch=$holdDispatchDelta:pushed=$holdPushedDelta:" +
                        "drains=$holdDrainCallsDelta:written=$holdWrittenDelta:sink=$holdStartPlayState>$holdEndPlayState",
                )
            }

            postFocus(c, AudioManager.AUDIOFOCUS_GAIN, "focus_gain_resume")
            awaitSink(s, "transient_unpark", EVENT_APPLY_TIMEOUT_MS) { s.unparkCount >= 1 && s.phase == Phase.RUNNING }
            val unparked = s.unparkCount == 1 && s.focusGainResumeAppliedCount == 1L &&
                s.playStateAfterUnpark == AudioTrack.PLAYSTATE_PLAYING && s.parkedHoldMs >= config.pauseHoldMs &&
                s.gainAttemptRejectedCount == 0L
            if (!unparked) throw FailClosed("transient_unpark_not_observed:${s.playStateAfterUnpark}")

            val resumeRes = machine.resume()
            commandsIssued++
            resumeAccepted = resumeRes.accepted
            resumeReason = resumeRes.reason
            resumeGeneration = machine.currentGeneration
            framesWrittenAtResume = s.framesWrittenToSink
            drainCallsAtResume = s.drainCalls
            if (!resumeAccepted || resumeRes.state != State.PLAYING) throw FailClosed("resume_rejected:${resumeRes.reason}")

            drainAtLeast(s, "resumed", maxOf(config.phaseFrames * SHARED_PHASES, framesWrittenAtResume + 1L))
            framesWrittenAfterResume = s.framesWrittenToSink
            lanes[LANE_TRANSIENT_PAUSE_RESUME] = parked && frozen && unparked && pauseAccepted && resumeAccepted &&
                pauseGeneration == startGeneration && resumeGeneration == startGeneration &&
                framesWrittenAfterResume > framesWrittenAtResume && s.drainCalls > drainCallsAtResume
        }

        // ── Terminal tails ─────────────────────────────────────────────────

        private fun terminalPrecondition(
            s: VanguardRealtimePlaybackPipelineFocusResponseSinkBridge,
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
        private fun verifyPrefix(s: VanguardRealtimePlaybackPipelineFocusResponseSinkBridge, phase: String) {
            val reply = s.replyAtPark ?: throw FailClosed("missing_prefix_reply_$phase")
            prefixReply = reply
            prefixSinkHex = s.checksumAtParkHex
            val identity = prefixSinkHex.isNotBlank() && prefixSinkHex.equals(reply.drainedChecksumHex, ignoreCase = true)
            lanes[LANE_CHECKSUM_IDENTITY] = identity
            val declared = format?.declaredFrameCount ?: 0L
            lanes[LANE_SINK_WRITE_ACCOUNTING] = s.framesWrittenAtPark == s.framesWrittenToSink &&
                s.framesReadFromTransport == s.framesWrittenToSink && reply.drainedFrames == s.framesWrittenToSink &&
                s.framesWrittenToSink >= config.phaseFrames * SHARED_PHASES && s.framesWrittenToSink < declared
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

        private fun exitSink(s: VanguardRealtimePlaybackPipelineFocusResponseSinkBridge, f: VanguardRealtimePlaybackDecoderFeed) {
            f.cancel()
            s.requestExit()
            while (!s.awaitExit(WAIT_SLICE_MS)) {
                if (SystemClock.elapsedRealtime() > deadlineAtMs) throw FailClosed("deadline_exceeded")
            }
            if (s.exitReason != VanguardRealtimePlaybackPipelineFocusResponseSinkBridge.EXIT_TERMINAL) {
                throw FailClosed("sink_terminal_exit_unexpected:${s.exitReason}")
            }
            if (!f.awaitExit(JOIN_TIMEOUT_MS)) throw FailClosed("decoder_did_not_exit")
        }

        private fun tailEos(s: VanguardRealtimePlaybackPipelineFocusResponseSinkBridge, f: VanguardRealtimePlaybackDecoderFeed) {
            while (!s.awaitExit(WAIT_SLICE_MS)) {
                val first = pollFailure()
                if (first != null) {
                    cancelThreads()
                    break
                }
            }
            if (failure.get() == null && s.exitReason != VanguardRealtimePlaybackPipelineFocusResponseSinkBridge.EXIT_EOS) {
                recordFailure("sink:${s.exitReason}")
            }
            if (failure.get() == null && !f.awaitExit(JOIN_TIMEOUT_MS)) recordFailure("decoder_did_not_exit")
            if (failure.get() == null && f.exitReason != VanguardRealtimePlaybackDecoderFeed.EXIT_EOS) recordFailure("decoder:${f.exitReason}")
        }

        private fun tailNoisy(
            s: VanguardRealtimePlaybackPipelineFocusResponseSinkBridge,
            c: VanguardRealtimePlaybackAudioFocusController,
            machine: VanguardRealtimePlaybackTransportStateMachine,
            f: VanguardRealtimePlaybackDecoderFeed,
        ) {
            terminalPrecondition(s, machine, "noisy")
            if (!c.postSyntheticBecomingNoisy()) throw FailClosed("synthetic_post_rejected_becoming_noisy")
            awaitSink(s, "noisy_park", EVENT_APPLY_TIMEOUT_MS) { s.parkCount >= 2 && s.phase == Phase.PARKED }
            val parked = s.parkCount == 2 && s.parkReason == ParkReason.BECOMING_NOISY && s.noisyPauseAppliedCount == 1L &&
                !s.autoResumeAllowed && s.playStateAtPark == AudioTrack.PLAYSTATE_PAUSED && s.permanentStopAppliedCount == 0L
            if (!parked) throw FailClosed("noisy_park_not_observed:${s.parkReason.name.lowercase()}")
            val res = machine.pause()
            commandsIssued++
            if (!res.accepted || res.state != State.PAUSED) throw FailClosed("noisy_pause_rejected:${res.reason}")
            val t0 = snapshotReply("noisy_hold_start", machine)
            val holdStartedAt = SystemClock.elapsedRealtime()
            while (SystemClock.elapsedRealtime() - holdStartedAt < config.pauseHoldMs) {
                pollFailure()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_during_noisy_hold:${s.exitReason}")
                sleepSlice()
            }
            val t1 = snapshotReply("noisy_hold_end", machine)
            terminalHoldDispatchDelta = t1.dispatchCount - t0.dispatchCount
            terminalHoldPushedDelta = t1.pushedFrames - t0.pushedFrames
            val frozen = t0.state == NativeState.PAUSED && t1.state == NativeState.PAUSED &&
                terminalHoldDispatchDelta == 0L && terminalHoldPushedDelta == 0L &&
                s.drainCalls == s.drainCallsAtPark && s.framesWrittenToSink == s.framesWrittenAtPark &&
                s.observedPlayState == AudioTrack.PLAYSTATE_PAUSED && s.parkedPlayStateViolations == 0L &&
                machine.currentState == State.PAUSED && !s.autoResumeAllowed && s.unparkCount == 1
            if (!frozen) throw FailClosed("noisy_hold_not_frozen:dispatch=$terminalHoldDispatchDelta:pushed=$terminalHoldPushedDelta")
            verifyPrefix(s, "noisy")
            lanes[LANE_BECOMING_NOISY_PAUSE] = parked && frozen && completedCount.get() == 0
            exitSink(s, f)
            // Leave no live transport behind: one stop of the still-PAUSED
            // transport (never COMPLETED; no completion claim).
            stopTransportOnce(machine, "noisy_teardown")
        }

        private fun tailPermanent(
            s: VanguardRealtimePlaybackPipelineFocusResponseSinkBridge,
            c: VanguardRealtimePlaybackAudioFocusController,
            machine: VanguardRealtimePlaybackTransportStateMachine,
            f: VanguardRealtimePlaybackDecoderFeed,
        ) {
            terminalPrecondition(s, machine, "permanent_loss")
            postFocus(c, AudioManager.AUDIOFOCUS_LOSS, "permanent_loss")
            awaitSink(s, "permanent_park", EVENT_APPLY_TIMEOUT_MS) { s.parkCount >= 2 && s.phase == Phase.PARKED }
            val parked = s.parkCount == 2 && s.parkReason == ParkReason.PERMANENT_LOSS && s.permanentStopAppliedCount == 1L &&
                !s.autoResumeAllowed && s.playStateAtPark == AudioTrack.PLAYSTATE_PAUSED && s.noisyPauseAppliedCount == 0L
            if (!parked) throw FailClosed("permanent_park_not_observed:${s.parkReason.name.lowercase()}")
            // Sink paused first, then the transport stops; the feed is
            // cancelled right after (ingest into STOPPED is pre-roll-legal).
            stopTransportOnce(machine, "permanent_loss")
            f.cancel()
            lanes[LANE_TRANSPORT_STOPPED] = stopAccepted && machine.currentState == State.STOPPED &&
                stopGeneration == startGeneration + 1L && completedCount.get() == 0
            verifyPrefix(s, "permanent")

            // GAIN after terminal stop: recorded and rejected on the sink thread.
            setVolumeCallsBeforeGainAttempt = s.setVolumeCalls
            postFocus(c, AudioManager.AUDIOFOCUS_GAIN, "gain_attempt")
            awaitSink(s, "gain_attempt", EVENT_APPLY_TIMEOUT_MS) { s.gainAttemptRejectedCount >= 1L }
            setVolumeCallsAfterGainAttempt = s.setVolumeCalls
            gainRejectedObserved = s.gainAttemptRejectedCount == 1L && s.unparkCount == 1 &&
                s.focusGainResumeAppliedCount == 1L && s.restoreAppliedCount == 1L &&
                setVolumeCallsAfterGainAttempt == setVolumeCallsBeforeGainAttempt &&
                s.phase == Phase.PARKED && s.observedPlayState == AudioTrack.PLAYSTATE_PAUSED &&
                machine.currentState == State.STOPPED && !s.autoResumeAllowed
            if (!gainRejectedObserved) throw FailClosed("gain_attempt_not_rejected")
            lanes[LANE_PERMANENT_STOP_NO_AUTO_RESUME] = parked && lanes[LANE_TRANSPORT_STOPPED] == true && gainRejectedObserved
            exitSink(s, f)
        }

        // ── Scenario body ──────────────────────────────────────────────────

        fun runScenario() {
            val wallStart = SystemClock.elapsedRealtime()
            try {
                openAndStart()
                val f = feed ?: throw FailClosed("feed_missing")
                val s = sink ?: throw FailClosed("sink_missing")
                val c = controller ?: throw FailClosed("controller_missing")
                val machine = sm ?: throw FailClosed("transport_missing")

                awaitInitialWrites(s)
                drainAtLeast(s, "pre_duck", config.phaseFrames)
                duckAndRestore(s, c, machine)
                transientPauseResume(s, c, machine)

                when (scenario) {
                    Scenario.EOS_COMPLETION -> tailEos(s, f)
                    Scenario.BECOMING_NOISY_TERMINAL -> tailNoisy(s, c, machine, f)
                    Scenario.PERMANENT_LOSS_TERMINAL -> tailPermanent(s, c, machine, f)
                }
                if (failure.get() != null) cancelThreads()
                joinBoth()

                val snapRes = machine.snapshot()
                finalReply = snapRes.reply ?: s.lastReply
                if (failure.get() == null && (!snapRes.accepted || finalReply == null)) {
                    recordFailure("final_snapshot_rejected:${snapRes.reason}")
                }

                // Focus controller release once; late synthetic post rejected.
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

        private fun releaseController(c: VanguardRealtimePlaybackAudioFocusController) {
            if (c.isReleased) return
            try {
                c.release()
            } catch (_: Throwable) {}
            lateSyntheticPostRejected = !c.postSyntheticFocusChange(AudioManager.AUDIOFOCUS_GAIN)
            ignoredAfterRelease = c.ignoredAfterReleaseCount
            controllerTelemetry = c.telemetry()
        }

        private fun evaluate(
            f: VanguardRealtimePlaybackDecoderFeed,
            s: VanguardRealtimePlaybackPipelineFocusResponseSinkBridge,
            c: VanguardRealtimePlaybackAudioFocusController,
            machine: VanguardRealtimePlaybackTransportStateMachine,
            final: Reply,
        ) {
            val fmt = format ?: return
            val declared = fmt.declaredFrameCount
            val coordinatorThreadId = Thread.currentThread().id
            lanes[LANE_FORMAT_PROBE] = fmt.sampleRate > 0 && fmt.channelCount in 1..2 && declared > 0L && fmt.sourceMime.isNotBlank()
            lanes[LANE_PRE_ROLL] = preRollFrames > 0L && (preRollRingFull || preRollFrames == declared) &&
                preRollStatePrepared && startAcceptedPlaying && preRollFrames <= declared

            if (scenario == Scenario.EOS_COMPLETION) {
                val decoderHex = f.checksumHex
                lanes[LANE_TRANSPORT_COMPLETED] = stateAtCompletion == State.COMPLETED && final.state == NativeState.COMPLETED &&
                    completedCount.get() == 1 && failedCount.get() == 0 && final.positionFrame == declared &&
                    final.eosPushed && final.eosDrained && final.lastError == "none" && s.autoResumeAllowed && stopCalls == 0
                lanes[LANE_SINK_WRITE_ACCOUNTING] = s.exitReason == VanguardRealtimePlaybackPipelineFocusResponseSinkBridge.EXIT_EOS &&
                    s.eosDrainedObserved && f.exitReason == VanguardRealtimePlaybackDecoderFeed.EXIT_EOS &&
                    f.acceptedFrames == declared && s.framesReadFromTransport == declared && s.framesWrittenToSink == declared &&
                    final.pushedFrames == declared && final.drainedFrames == declared && final.discardedFrames == 0L &&
                    s.playbackHeadFinal > 0L
                lanes[LANE_CHECKSUM_IDENTITY] = decoderHex.isNotBlank() &&
                    decoderHex.equals(final.pushedChecksumHex, ignoreCase = true) &&
                    decoderHex.equals(final.drainedChecksumHex, ignoreCase = true) &&
                    decoderHex.equals(s.checksumHex, ignoreCase = true)
            }

            val telemetry = controllerTelemetry
            lanes[LANE_FOCUS_LIFECYCLE] = focusGranted && receiverRegistered && c.isReleased &&
                c.focusAbandonCount == 1 && c.receiverUnregisterCount == 1 &&
                (telemetry["focusAbandonError"] as? String).isNullOrEmpty() &&
                (telemetry["receiverUnregisterError"] as? String).isNullOrEmpty() &&
                c.droppedCount == 0L && c.pendingCount == 0 && lateSyntheticPostRejected &&
                c.enqueuedCount == c.drainedCount && s.unknownEventCount == 0L
            lanes[LANE_AUDIO_TRACK_LIFECYCLE] = s.audioTrackInitOk && s.gainSetOk && s.releaseCount.get() == 1 &&
                feedJoined && sinkJoined && f.mediaReleaseCount.get() == 1L && f.mediaReleaseClean &&
                disposeCalls == 1 && stateAfterDispose == State.DISPOSED && stateAfterSecondDispose == State.DISPOSED &&
                !postIngestAfterDispose && machine.currentState == State.DISPOSED &&
                (scenario == Scenario.EOS_COMPLETION || s.terminalExitOnSinkThread)
            lanes[LANE_THREAD_OWNERSHIP] = f.ingestCallbacksOnOwner.get() > 0L && f.ingestCallbacksOffOwner.get() == 0L &&
                !f.threadIsTransportOwner && !s.threadIsTransportOwner &&
                f.threadId > 0L && s.threadId > 0L && f.threadId != s.threadId &&
                f.threadId != coordinatorThreadId && s.threadId != coordinatorThreadId &&
                s.eventsAppliedOnSinkThread > 0L && s.eventsAppliedOffSinkThread == 0L &&
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
            metrics["sinkExitReason"] = s?.exitReason ?: VanguardRealtimePlaybackPipelineFocusResponseSinkBridge.EXIT_NOT_STARTED
            metrics["framesReadFromTransport"] = s?.framesReadFromTransport ?: 0L
            metrics["framesWrittenToSink"] = s?.framesWrittenToSink ?: 0L
            metrics["partialWriteCount"] = s?.partialWriteCount ?: 0L
            metrics["zeroWriteCount"] = s?.zeroWriteCount ?: 0L
            metrics["drainCalls"] = s?.drainCalls ?: 0L
            metrics["emptyDrainCount"] = s?.emptyDrainCount ?: 0L
            metrics["playbackHeadFinal"] = s?.playbackHeadFinal ?: 0L
            metrics["audioTrackInitOk"] = s?.audioTrackInitOk ?: false
            metrics["gainValue"] = (s?.gainValue ?: 0f).toDouble()
            metrics["setVolumeCalls"] = s?.setVolumeCalls ?: 0L
            metrics["audioTrackReleaseCount"] = s?.releaseCount?.get() ?: 0
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
            metrics["transportResumeGeneration"] = resumeGeneration
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
            // Focus head.
            metrics["focusGranted"] = focusGranted
            metrics["noisyReceiverRegistered"] = receiverRegistered
            metrics["preStartPendingEvents"] = preStartPending
            metrics["initialWriteWaitMs"] = initialWriteWaitMs
            metrics["framesWrittenBeforeDuck"] = framesWrittenBeforeDuck
            metrics["duckAppliedCount"] = s?.duckAppliedCount ?: 0L
            metrics["restoreAppliedCount"] = s?.restoreAppliedCount ?: 0L
            metrics["transientPauseAppliedCount"] = s?.transientPauseAppliedCount ?: 0L
            metrics["duplicateTransientNoOpCount"] = s?.duplicateTransientNoOpCount ?: 0L
            metrics["focusGainResumeAppliedCount"] = s?.focusGainResumeAppliedCount ?: 0L
            metrics["focusGainNoOpCount"] = s?.focusGainNoOpCount ?: 0L
            metrics["noisyPauseAppliedCount"] = s?.noisyPauseAppliedCount ?: 0L
            metrics["noisyDuplicateNoOpCount"] = s?.noisyDuplicateNoOpCount ?: 0L
            metrics["permanentStopAppliedCount"] = s?.permanentStopAppliedCount ?: 0L
            metrics["gainAttemptRejectedCount"] = s?.gainAttemptRejectedCount ?: 0L
            metrics["unknownEventCount"] = s?.unknownEventCount ?: 0L
            metrics["lastAppliedSeq"] = s?.lastAppliedSeq ?: -1L
            metrics["lastAppliedTag"] = s?.lastAppliedTag ?: "none"
            metrics["autoResumeAllowed"] = s?.autoResumeAllowed ?: true
            metrics["sinkPhaseFinal"] = s?.phase?.name ?: "none"
            metrics["sinkParkReasonFinal"] = s?.parkReason?.name ?: "none"
            metrics["sinkParkCount"] = s?.parkCount ?: 0
            metrics["sinkUnparkCount"] = s?.unparkCount ?: 0
            metrics["sinkPlayStateAtPark"] = s?.playStateAtPark ?: -1
            metrics["sinkPlayStateAfterUnpark"] = s?.playStateAfterUnpark ?: -1
            metrics["sinkObservedPlayStateFinal"] = s?.observedPlayState ?: -1
            metrics["sinkParkedPlayStateObservations"] = s?.parkedPlayStateObservations ?: 0L
            metrics["sinkParkedPlayStateViolations"] = s?.parkedPlayStateViolations ?: 0L
            metrics["sinkFramesWrittenAtPark"] = s?.framesWrittenAtPark ?: 0L
            metrics["sinkDrainCallsAtPark"] = s?.drainCallsAtPark ?: 0L
            metrics["sinkPlaybackHeadAtPark"] = s?.playbackHeadAtPark ?: 0L
            metrics["sinkPlaybackHeadAtUnpark"] = s?.playbackHeadAtUnpark ?: 0L
            metrics["sinkParkedHoldMs"] = s?.parkedHoldMs ?: -1L
            metrics["sinkTerminalExitOnSinkThread"] = s?.terminalExitOnSinkThread ?: false
            metrics["pauseAccepted"] = pauseAccepted
            metrics["pauseReason"] = pauseReason
            metrics["holdStartNativeState"] = holdStart?.stateToken ?: "none"
            metrics["holdEndNativeState"] = holdEnd?.stateToken ?: "none"
            metrics["holdStartSinkPlayState"] = holdStartPlayState
            metrics["holdEndSinkPlayState"] = holdEndPlayState
            metrics["holdDispatchDelta"] = holdDispatchDelta
            metrics["holdPushedDelta"] = holdPushedDelta
            metrics["holdDrainCallsDelta"] = holdDrainCallsDelta
            metrics["holdWrittenDelta"] = holdWrittenDelta
            metrics["holdActualMs"] = holdActualMs
            metrics["resumeAccepted"] = resumeAccepted
            metrics["resumeReason"] = resumeReason
            metrics["framesWrittenAtResume"] = framesWrittenAtResume
            metrics["drainCallsAtResume"] = drainCallsAtResume
            metrics["framesWrittenAfterResume"] = framesWrittenAfterResume
            // Terminal tail.
            metrics["terminalPositionFrame"] = terminalPositionFrame
            metrics["terminalPositionLimit"] = terminalPositionLimit
            metrics["terminalHoldDispatchDelta"] = terminalHoldDispatchDelta
            metrics["terminalHoldPushedDelta"] = terminalHoldPushedDelta
            metrics["stopCalls"] = stopCalls
            metrics["stopAccepted"] = stopAccepted
            metrics["stopState"] = stopState.name
            metrics["stopReason"] = stopReason
            metrics["gainAttemptRejectedObserved"] = gainRejectedObserved
            metrics["setVolumeCallsBeforeGainAttempt"] = setVolumeCallsBeforeGainAttempt
            metrics["setVolumeCallsAfterGainAttempt"] = setVolumeCallsAfterGainAttempt
            metrics["lateSyntheticPostRejected"] = lateSyntheticPostRejected
            metrics["focusEventsIgnoredAfterRelease"] = ignoredAfterRelease
            metrics["sessionWallMs"] = sessionWallMs
            for ((k, v) in controllerTelemetry) metrics["focus_$k"] = v
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
