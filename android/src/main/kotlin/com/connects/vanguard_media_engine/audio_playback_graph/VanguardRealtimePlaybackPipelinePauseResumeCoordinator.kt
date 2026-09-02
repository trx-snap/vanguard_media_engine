package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioTrack
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.NativeState
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.IngestRequest
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

// ── VanguardRealtimePlaybackPipelinePauseResumeCoordinator (P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-PAUSE-RESUME, Y6b) ─
//
// The ONLY transport command owner of the Y6b pause/resume proof over the
// committed Y6a pipeline shape:
//
//   MediaExtractor/MediaCodec  ->  Y5a external ingest seam  ->  Y1 native
//   ([VanguardRealtimePlaybackDecoderFeed], decode thread, unchanged)
//   transport (owner HandlerThread inside the state machine)  ->
//   non-zero-gain AudioTrack MODE_STREAM
//   ([VanguardRealtimePlaybackPipelinePauseResumeSinkBridge], sink thread)
//
// Thread model: the decoder feed thread only posts generation-pinned
// ingest; the sink thread only drains and owns every AudioTrack call; the
// shared [VanguardRealtimePlaybackTransportStateMachine] is the only JNI
// caller; this coordinator (the caller's worker thread) issues exactly
// five transport commands (load, prepare, start, pause, resume), drives
// the sink phase protocol, waits/joins and aggregates. It never calls an
// AudioTrack method.
//
// Fixed pause/resume order (single track, one forward playthrough):
//   sink requestPark -> sink ack PARKED (AudioTrack paused on the sink
//   thread) -> transport.pause() -> snapshot t0 -> hold pauseHoldMs ->
//   snapshot t1 -> sink unpark (AudioTrack.play confirmed PLAYSTATE_PLAYING
//   on the sink thread, sink RUNNING) -> transport.resume() -> post-resume
//   drain to EOS.
// The sink is therefore never PARKED while the transport is PLAYING: the
// AudioTrack is paused before transport.pause() and playing again before
// transport.resume(). Between unpark and resume the sink may only drain
// output the native worker mixed before the pause; the post-resume drain
// gate is sampled after transport.resume() returned, so it proves progress
// caused by the resume command, not by the unpark alone.
// During the hold: zero native dispatch delta, zero pushed delta, zero sink
// drainCalls delta, zero sink written delta, native/transport PAUSED and
// sink PLAYSTATE_PAUSED at both ends.
//
// Pause precondition (fail closed, never pass late): transport PLAYING,
// positive initial sink writes, positionFrame < declaredFrameCount / 3.
//
// Terminal-state table:
// - start: feed opens/probes -> state machine (externalIngestTrackMask=1)
//   load, prepare -> feed attached, pre-rolls -> start (+ feed generation
//   update) -> sink starts -> first positive sink write.
// - pause/resume: as above; a rejected command, a missing sink ack or a
//   non-frozen hold fails closed.
// - EOS: feed pads a <= 1 s shortfall; sink exits on eosDrained; the
//   transport observes COMPLETED on the owner thread.
// - failure / deadline / cancel: first failure wins (AtomicReference);
//   both threads are cancelled (a parked sink thread wakes on cancel),
//   MediaCodec/MediaExtractor and the AudioTrack are released exactly once
//   on their own threads, the state machine is disposed exactly once,
//   joins are bounded.
// - double run / dispose: AtomicBoolean guarded; [run] is single use.
//
// No seek, feed re-anchor, AudioTrack flush, interactive controls, audio
// focus, becoming-noisy, route change, dead-object recovery, presentation
// clock, A/V sync, resample or downmix live here.
class VanguardRealtimePlaybackPipelinePauseResumeCoordinator {

    data class Config(
        val sourcePath: String,
        val maxDurationSec: Double = 3.0,
        val maxFramesPerMix: Int = 256,
        val baseVolume: Float = VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.DEFAULT_BASE_VOLUME,
        val deadlineMs: Long = 30_000L,
        val pauseHoldMs: Long = DEFAULT_PAUSE_HOLD_MS,
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
            "realtime_playback_pipeline_pause_resume_diagnostic_only_real_mediaextractor_mediacodec_" +
                "to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_" +
                "single_track_forward_playthrough_pause_resume_only_sink_park_before_transport_pause_" +
                "sink_unpark_before_transport_resume_" +
                "no_seek_no_flush_no_feed_reanchor_no_presentation_clock_no_av_sync_no_interactive_controls_" +
                "no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_product_" +
                "no_editor_no_app_wiring_no_ios_no_streaming_no_cache_no_cpp_changes"

        const val DEFAULT_PAUSE_HOLD_MS = 150L
        const val MAX_PAUSE_HOLD_MS = 2_000L

        const val LANE_FORMAT_PROBE = "formatProbeOk"
        const val LANE_PRE_ROLL = "preRollOk"
        const val LANE_INITIAL_DRAIN = "initialDrainOk"
        const val LANE_SINK_PARK_ACK = "sinkParkAckOk"
        const val LANE_PAUSE_COMMAND = "pauseCommandOk"
        const val LANE_SINK_PAUSED = "sinkPausedOk"
        const val LANE_PAUSE_HOLD_FROZEN = "pauseHoldFrozenOk"
        const val LANE_RESUME_COMMAND = "resumeCommandOk"
        const val LANE_SINK_RESUMED = "sinkResumedOk"
        const val LANE_POST_RESUME_DRAIN = "postResumeDrainOk"
        const val LANE_SINK_WRITE_ACCOUNTING = "sinkWriteAccountingOk"
        const val LANE_CHECKSUM_IDENTITY = "checksumIdentityOk"
        const val LANE_PLAYBACK_HEAD_ADVANCED = "playbackHeadAdvancedOk"
        const val LANE_TRANSPORT_COMPLETED = "transportCompletedOk"
        const val LANE_THREAD_OWNERSHIP = "threadOwnershipOk"
        const val LANE_LIFECYCLE_DISPOSE = "lifecycleDisposeOk"
        const val LANE_PROOF_BOUNDARY = "proofBoundaryOk"
        const val LANE_CANONICAL = "canonical"

        val REQUIRED_LANES: List<String> = listOf(
            LANE_FORMAT_PROBE,
            LANE_PRE_ROLL,
            LANE_INITIAL_DRAIN,
            LANE_SINK_PARK_ACK,
            LANE_PAUSE_COMMAND,
            LANE_SINK_PAUSED,
            LANE_PAUSE_HOLD_FROZEN,
            LANE_RESUME_COMMAND,
            LANE_SINK_RESUMED,
            LANE_POST_RESUME_DRAIN,
            LANE_SINK_WRITE_ACCOUNTING,
            LANE_CHECKSUM_IDENTITY,
            LANE_PLAYBACK_HEAD_ADVANCED,
            LANE_TRANSPORT_COMPLETED,
            LANE_THREAD_OWNERSHIP,
            LANE_LIFECYCLE_DISPOSE,
        )

        private const val WAIT_SLICE_MS = 5L
        private const val JOIN_TIMEOUT_MS = 5_000L
        private const val INITIAL_WRITE_WAIT_MS = 2_000L
        private const val PARK_ACK_TIMEOUT_MS = 2_000L
        private const val UNPARK_ACK_TIMEOUT_MS = 2_000L
        private const val PAUSE_POSITION_DIVISOR = 3L
        // load, prepare, start, pause, resume
        private const val COMMANDS_PER_SESSION = 5
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

    // Requests cancellation from any thread; both pipeline threads observe
    // it at their next bounded wait (a parked sink wakes immediately) and
    // the run thread tears down.
    fun cancel() {
        cancelled.set(true)
        activeSession?.cancelThreads()
    }

    // Any-thread, idempotent. A running pipeline is cancelled (its own
    // threads release their resources); an idle one has nothing to free.
    fun dispose() {
        cancel()
        if (!running) activeSession?.disposeTransportOnce()
    }

    // Executes the whole proof on the calling thread. Single use.
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
        if (cancelled.get()) throw FailClosed("cancelled")
        val deadlineAtMs = SystemClock.elapsedRealtime() + config.deadlineMs
        metrics["maxDurationSec"] = config.maxDurationSec
        metrics["maxFramesPerMix"] = config.maxFramesPerMix
        // Floats are not StandardMessageCodec values; publish as Double.
        metrics["baseVolume"] = config.baseVolume.toDouble()
        metrics["deadlineMs"] = config.deadlineMs
        metrics["pauseHoldMs"] = config.pauseHoldMs
        metrics["coordinatorThreadId"] = Thread.currentThread().id

        val session = Session(config, deadlineAtMs)
        activeSession = session
        try {
            session.runPlaythrough()
        } finally {
            session.disposeTransportOnce()
            session.publishMetrics()
            activeSession = null
        }
        session.failure.get()?.let { throw FailClosed(it) }
    }

    private fun isCancelled(): Boolean = cancelled.get()

    // ── One pipeline session (feed + transport + sink) ─────────────────────

    private inner class Session(
        val config: Config,
        val deadlineAtMs: Long,
    ) {
        val failure = AtomicReference<String?>(null)
        val completedCount = AtomicInteger(0)
        val failedCount = AtomicInteger(0)
        val listenerOnOwner = AtomicLong(0L)
        val listenerOffOwner = AtomicLong(0L)
        private val transitions = StringBuilder()
        private val disposedOnce = AtomicBoolean(false)

        @Volatile
        var sm: VanguardRealtimePlaybackTransportStateMachine? = null

        @Volatile
        var feed: VanguardRealtimePlaybackDecoderFeed? = null

        @Volatile
        var sink: VanguardRealtimePlaybackPipelinePauseResumeSinkBridge? = null

        var format: VanguardRealtimePlaybackDecoderFeed.Format? = null
        var commandsIssued = 0
        var prepareGeneration = -1L
        var startGeneration = -1L
        var pauseGeneration = -1L
        var resumeGeneration = -1L
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

        // Pause/resume observations.
        var initialWriteWaitMs = -1L
        var framesWrittenBeforePark = 0L
        var drainCallsBeforePark = 0L
        var stateBeforePark = State.IDLE
        var positionBeforePark = -1L
        var pausePositionLimit = -1L
        var parkRequested = false
        var parkAcked = false
        var parkAckWaitMs = -1L
        var pauseAccepted = false
        var pauseState = State.IDLE
        var pauseReason = ""
        var holdStart: Reply? = null
        var holdEnd: Reply? = null
        var holdStartTransportState = State.IDLE
        var holdEndTransportState = State.IDLE
        var holdStartPlayState = VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.PLAY_STATE_UNKNOWN
        var holdEndPlayState = VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.PLAY_STATE_UNKNOWN
        var holdStartDrainCalls = 0L
        var holdEndDrainCalls = 0L
        var holdStartFramesWritten = 0L
        var holdEndFramesWritten = 0L
        var holdDispatchDelta = -1L
        var holdPushedDelta = -1L
        var holdDrainCallsDelta = -1L
        var holdWrittenDelta = -1L
        var holdActualMs = -1L
        var resumeAccepted = false
        var resumeState = State.IDLE
        var resumeReason = ""
        var unparkRequested = false
        var unparkAcked = false
        var unparkAckWaitMs = -1L
        var framesWrittenAfterUnpark = 0L
        var drainCallsAfterUnpark = 0L
        var framesWrittenAtResume = 0L
        var drainCallsAtResume = 0L

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

        // Exactly one coordinator-side dispose of the state machine; the
        // state machine itself is idempotent beyond that.
        fun disposeTransportOnce() {
            if (!disposedOnce.compareAndSet(false, true)) return
            val machine = sm ?: return
            stateBeforeDispose = machine.currentState
            machine.dispose()
            disposeCalls++
            stateAfterDispose = machine.currentState
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

        // Feed open/probe -> transport load/prepare -> pre-roll -> start ->
        // sink start. Same shape as Y6a with the phase-controlled sink.
        private fun openAndStart() {
            checkDeadlineAndCancel()
            val f = VanguardRealtimePlaybackDecoderFeed(
                VanguardRealtimePlaybackDecoderFeed.Config(
                    sourcePath = config.sourcePath,
                    maxDurationSec = config.maxDurationSec,
                    maxFramesPerMix = config.maxFramesPerMix,
                    deadlineAtMs = deadlineAtMs,
                    threadName = "Y6bDecoderFeed",
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
            val machine = VanguardRealtimePlaybackTransportStateMachine(
                sessionConfig, listener, threadName = "Y6bTransport",
            )
            sm = machine
            if (sessionCancelled()) throw FailClosed("cancelled")

            val loadRes = machine.load()
            commandsIssued++
            if (!loadRes.accepted) throw FailClosed("load_rejected:${loadRes.reason}")
            val prepareRes = machine.prepare()
            commandsIssued++
            if (!prepareRes.accepted || prepareRes.state != State.PREPARED) {
                throw FailClosed("prepare_rejected:${prepareRes.reason}")
            }
            prepareGeneration = machine.currentGeneration
            f.attachTransport(machine, prepareGeneration)

            // Pre-roll while PREPARED until the source ring answers ring_full
            // (or the declared end fits entirely).
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

            val startRes = machine.start()
            commandsIssued++
            startAcceptedPlaying = startRes.accepted && startRes.state == State.PLAYING
            if (!startAcceptedPlaying) throw FailClosed("start_rejected:${startRes.reason}")
            startGeneration = machine.currentGeneration
            f.updateGeneration(startGeneration)
            f.markTransportStarted()

            val s = VanguardRealtimePlaybackPipelinePauseResumeSinkBridge(
                VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.Config(
                    stateMachine = machine,
                    sampleRate = fmt.sampleRate,
                    channelCount = fmt.channelCount,
                    maxFramesPerMix = config.maxFramesPerMix,
                    declaredFrameCount = fmt.declaredFrameCount,
                    baseVolume = config.baseVolume,
                    deadlineAtMs = deadlineAtMs,
                    threadName = "Y6bSinkBridge",
                    externallyCancelled = { sessionCancelled() },
                ),
            )
            sink = s
            if (!s.start()) throw FailClosed("sink_start_rejected")
        }

        // Polls the failure sources once; returns the first failure if any.
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
            if (s != null && !s.isAlive && s.exitReason != VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.EXIT_RUNNING &&
                s.exitReason != VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.EXIT_EOS &&
                s.exitReason != VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.EXIT_NOT_STARTED
            ) {
                recordFailure("sink:${s.exitReason}")
            }
            if (sessionCancelled()) recordFailure("cancelled")
            if (SystemClock.elapsedRealtime() > deadlineAtMs) recordFailure("deadline_exceeded")
            return failure.get()
        }

        private fun joinBoth() {
            val f = feed
            val s = sink
            feedJoined = f?.join(JOIN_TIMEOUT_MS) ?: true
            sinkJoined = s?.join(JOIN_TIMEOUT_MS) ?: true
        }

        private fun snapshotReply(phase: String, machine: VanguardRealtimePlaybackTransportStateMachine): Reply {
            val res = machine.snapshot()
            if (!res.accepted) throw FailClosed("snapshot_rejected_$phase:${res.reason}")
            return res.reply ?: throw FailClosed("snapshot_null_reply_$phase")
        }

        // ── Pause / resume proof (coordinator thread) ──────────────────────

        // Waits for the first positive AudioTrack write so the pause lands
        // on a really playing sink, then enforces the early-position
        // precondition before any park/pause is issued.
        private fun awaitInitialWrites(
            s: VanguardRealtimePlaybackPipelinePauseResumeSinkBridge,
            machine: VanguardRealtimePlaybackTransportStateMachine,
        ) {
            val waitStart = SystemClock.elapsedRealtime()
            val waitDeadline = waitStart + INITIAL_WRITE_WAIT_MS
            while (s.framesWrittenToSink <= 0L || !s.played) {
                pollFailure()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_before_first_write:${s.exitReason}")
                if (SystemClock.elapsedRealtime() > waitDeadline) throw FailClosed("no_initial_sink_write")
                sleepSlice()
            }
            initialWriteWaitMs = SystemClock.elapsedRealtime() - waitStart
            framesWrittenBeforePark = s.framesWrittenToSink
            drainCallsBeforePark = s.drainCalls
            lanes[LANE_INITIAL_DRAIN] = framesWrittenBeforePark > 0L && drainCallsBeforePark > 0L && s.played

            val declared = format?.declaredFrameCount ?: throw FailClosed("format_missing")
            pausePositionLimit = declared / PAUSE_POSITION_DIVISOR
            stateBeforePark = machine.currentState
            if (stateBeforePark != State.PLAYING) throw FailClosed("pause_precondition_state:${stateBeforePark.name.lowercase()}")
            val pre = snapshotReply("pre_park", machine)
            positionBeforePark = pre.positionFrame
            if (pre.state == NativeState.COMPLETED || machine.currentState != State.PLAYING) {
                throw FailClosed("pause_precondition_completed:${pre.positionFrame}")
            }
            if (positionBeforePark >= pausePositionLimit) {
                throw FailClosed("pause_precondition_late:$positionBeforePark:$pausePositionLimit")
            }
        }

        private fun parkSink(s: VanguardRealtimePlaybackPipelinePauseResumeSinkBridge) {
            val parkAt = SystemClock.elapsedRealtime()
            parkRequested = s.requestPark()
            if (!parkRequested) throw FailClosed("sink_park_request_rejected:${s.phase.name.lowercase()}")
            val ackDeadline = parkAt + PARK_ACK_TIMEOUT_MS
            while (!s.awaitParked(WAIT_SLICE_MS)) {
                pollFailure()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_before_park_ack:${s.exitReason}")
                if (SystemClock.elapsedRealtime() > ackDeadline) throw FailClosed("sink_park_ack_timeout:${s.phase.name.lowercase()}")
            }
            parkAckWaitMs = SystemClock.elapsedRealtime() - parkAt
            parkAcked = s.phase == VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.Phase.PARKED && s.parkCount == 1
            lanes[LANE_SINK_PARK_ACK] = parkAcked && s.parkExecutedOnSinkThread && s.parkAckLatencyMs >= 0L &&
                s.framesWrittenAtPark >= framesWrittenBeforePark && s.drainCallsAtPark >= drainCallsBeforePark
            if (!parkAcked) throw FailClosed("sink_park_not_acked:${s.phase.name.lowercase()}")
            if (s.playStateAtPark != AudioTrack.PLAYSTATE_PAUSED) throw FailClosed("sink_not_paused_at_park:${s.playStateAtPark}")
        }

        private fun pauseTransport(machine: VanguardRealtimePlaybackTransportStateMachine) {
            val res = machine.pause()
            commandsIssued++
            pauseAccepted = res.accepted
            pauseState = res.state
            pauseReason = res.reason
            pauseGeneration = machine.currentGeneration
            lanes[LANE_PAUSE_COMMAND] = pauseAccepted && pauseState == State.PAUSED &&
                machine.currentState == State.PAUSED && pauseGeneration == startGeneration
            if (!pauseAccepted || pauseState != State.PAUSED) throw FailClosed("pause_rejected:${res.reason}")
        }

        private fun holdFrozen(
            s: VanguardRealtimePlaybackPipelinePauseResumeSinkBridge,
            machine: VanguardRealtimePlaybackTransportStateMachine,
        ) {
            val t0 = snapshotReply("hold_start", machine)
            holdStart = t0
            holdStartTransportState = machine.currentState
            holdStartPlayState = s.observedPlayState
            holdStartDrainCalls = s.drainCalls
            holdStartFramesWritten = s.framesWrittenToSink
            if (t0.state == NativeState.COMPLETED || t0.positionFrame >= pausePositionLimit) {
                throw FailClosed("pause_hold_late:${t0.positionFrame}:$pausePositionLimit")
            }
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
            holdEndTransportState = machine.currentState
            holdEndPlayState = s.observedPlayState
            holdEndDrainCalls = s.drainCalls
            holdEndFramesWritten = s.framesWrittenToSink
            holdDispatchDelta = t1.dispatchCount - t0.dispatchCount
            holdPushedDelta = t1.pushedFrames - t0.pushedFrames
            holdDrainCallsDelta = holdEndDrainCalls - holdStartDrainCalls
            holdWrittenDelta = holdEndFramesWritten - holdStartFramesWritten

            val sinkPaused = holdStartPlayState == AudioTrack.PLAYSTATE_PAUSED &&
                holdEndPlayState == AudioTrack.PLAYSTATE_PAUSED &&
                s.playStateAtPark == AudioTrack.PLAYSTATE_PAUSED &&
                s.parkedPlayStateViolations == 0L && s.parkedPlayStateObservations > 0L &&
                s.phase == VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.Phase.PARKED
            lanes[LANE_SINK_PAUSED] = sinkPaused
            val frozen = t0.state == NativeState.PAUSED && t1.state == NativeState.PAUSED &&
                holdStartTransportState == State.PAUSED && holdEndTransportState == State.PAUSED &&
                holdDispatchDelta == 0L && holdPushedDelta == 0L &&
                holdDrainCallsDelta == 0L && holdWrittenDelta == 0L &&
                t1.positionFrame == t0.positionFrame && t1.drainedFrames == t0.drainedFrames &&
                holdActualMs >= config.pauseHoldMs && sinkPaused
            lanes[LANE_PAUSE_HOLD_FROZEN] = frozen
            if (!frozen) {
                throw FailClosed(
                    "pause_hold_not_frozen:dispatch=$holdDispatchDelta:pushed=$holdPushedDelta:" +
                        "drains=$holdDrainCallsDelta:written=$holdWrittenDelta:native=${t0.stateToken}>${t1.stateToken}:" +
                        "sink=$holdStartPlayState>$holdEndPlayState",
                )
            }
        }

        // Issued only after [unparkSink] confirmed the sink RUNNING with the
        // AudioTrack PLAYSTATE_PLAYING, so the transport never plays into a
        // parked sink. Samples the sink counters right after the command
        // returns; [LANE_POST_RESUME_DRAIN] is gated against that baseline.
        private fun resumeTransport(
            s: VanguardRealtimePlaybackPipelinePauseResumeSinkBridge,
            machine: VanguardRealtimePlaybackTransportStateMachine,
        ) {
            if (s.phase != VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.Phase.RUNNING || !unparkAcked) {
                throw FailClosed("resume_before_sink_unpark:${s.phase.name.lowercase()}")
            }
            val res = machine.resume()
            commandsIssued++
            resumeAccepted = res.accepted
            resumeState = res.state
            resumeReason = res.reason
            resumeGeneration = machine.currentGeneration
            framesWrittenAtResume = s.framesWrittenToSink
            drainCallsAtResume = s.drainCalls
            lanes[LANE_RESUME_COMMAND] = resumeAccepted && resumeState == State.PLAYING &&
                machine.currentState == State.PLAYING && resumeGeneration == startGeneration &&
                s.phase == VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.Phase.RUNNING
            if (!resumeAccepted || resumeState != State.PLAYING) throw FailClosed("resume_rejected:${res.reason}")
        }

        // Runs while the transport is still PAUSED: the sink thread calls
        // AudioTrack.play, confirms PLAYSTATE_PLAYING and publishes RUNNING
        // before this returns. Until [resumeTransport] the sink can only
        // drain already-mixed native output (drain is legal while PAUSED),
        // so the counters sampled here are an unpark baseline, not proof of
        // resume progress.
        private fun unparkSink(s: VanguardRealtimePlaybackPipelinePauseResumeSinkBridge) {
            val unparkAt = SystemClock.elapsedRealtime()
            unparkRequested = s.unpark()
            if (!unparkRequested) throw FailClosed("sink_unpark_request_rejected:${s.phase.name.lowercase()}")
            val ackDeadline = unparkAt + UNPARK_ACK_TIMEOUT_MS
            while (!s.awaitRunning(WAIT_SLICE_MS)) {
                pollFailure()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_before_unpark_ack:${s.exitReason}")
                if (SystemClock.elapsedRealtime() > ackDeadline) throw FailClosed("sink_unpark_ack_timeout:${s.phase.name.lowercase()}")
            }
            unparkAckWaitMs = SystemClock.elapsedRealtime() - unparkAt
            unparkAcked = s.phase == VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.Phase.RUNNING && s.unparkCount == 1
            framesWrittenAfterUnpark = s.framesWrittenToSink
            drainCallsAfterUnpark = s.drainCalls
            lanes[LANE_SINK_RESUMED] = unparkAcked && s.unparkExecutedOnSinkThread &&
                s.playStateAfterUnpark == AudioTrack.PLAYSTATE_PLAYING && s.parkedHoldMs >= config.pauseHoldMs
            if (!unparkAcked) throw FailClosed("sink_unpark_not_acked:${s.phase.name.lowercase()}")
            if (s.playStateAfterUnpark != AudioTrack.PLAYSTATE_PLAYING) {
                throw FailClosed("sink_not_playing_after_unpark:${s.playStateAfterUnpark}")
            }
        }

        // ── Playthrough ────────────────────────────────────────────────────

        fun runPlaythrough() {
            val wallStart = SystemClock.elapsedRealtime()
            try {
                openAndStart()
                val f = feed ?: throw FailClosed("feed_missing")
                val s = sink ?: throw FailClosed("sink_missing")
                val machine = sm ?: throw FailClosed("transport_missing")

                // Fixed order: initial writes -> park -> ack -> pause -> t0 ->
                // hold -> t1 -> unpark (AudioTrack PLAYSTATE_PLAYING on the
                // sink thread) -> resume -> drain to EOS. The sink is never
                // PARKED while the transport is PLAYING.
                awaitInitialWrites(s, machine)
                parkSink(s)
                pauseTransport(machine)
                holdFrozen(s, machine)
                unparkSink(s)
                resumeTransport(s, machine)

                // Wait for the sink to exit (EOS) or the first failure.
                while (!s.awaitExit(WAIT_SLICE_MS)) {
                    val first = pollFailure()
                    if (first != null) {
                        cancelThreads()
                        break
                    }
                }
                if (failure.get() == null && s.exitReason != VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.EXIT_EOS) {
                    recordFailure("sink:${s.exitReason}")
                }
                if (failure.get() == null && !f.awaitExit(JOIN_TIMEOUT_MS)) {
                    recordFailure("decoder_did_not_exit")
                }
                if (failure.get() == null && f.exitReason != VanguardRealtimePlaybackDecoderFeed.EXIT_EOS) {
                    recordFailure("decoder:${f.exitReason}")
                }
                if (failure.get() != null) cancelThreads()
                joinBoth()

                val snapRes = machine.snapshot()
                finalReply = snapRes.reply ?: s.lastReply
                val final = finalReply
                if (failure.get() == null && (!snapRes.accepted || final == null)) {
                    recordFailure("final_snapshot_rejected:${snapRes.reason}")
                }

                // Lifecycle: explicit dispose, later postIngest rejected
                // (never posted), second dispose is a no-op.
                val stateAtCompletion = machine.currentState
                disposeTransportOnce()
                val probe = ByteBuffer.allocateDirect(config.maxFramesPerMix * 2 * (format?.channelCount ?: 2))
                    .order(ByteOrder.nativeOrder())
                postIngestAfterDispose = machine.postIngest(
                    IngestRequest(VanguardRealtimePlaybackDecoderFeed.EXTERNAL_TRACK_INDEX, probe, config.maxFramesPerMix, f.acceptedFrames),
                    expectedGeneration = startGeneration,
                )
                machine.dispose()
                stateAfterSecondDispose = machine.currentState

                if (failure.get() == null && final != null) evaluatePlaythrough(f, s, machine, final, stateAtCompletion)
            } finally {
                cancelThreads()
                joinBoth()
                sessionWallMs = SystemClock.elapsedRealtime() - wallStart
            }
        }

        private fun evaluatePlaythrough(
            f: VanguardRealtimePlaybackDecoderFeed,
            s: VanguardRealtimePlaybackPipelinePauseResumeSinkBridge,
            machine: VanguardRealtimePlaybackTransportStateMachine,
            final: Reply,
            stateAtCompletion: State,
        ) {
            val fmt = format ?: return
            val declared = fmt.declaredFrameCount
            val coordinatorThreadId = Thread.currentThread().id
            val decoderHex = f.checksumHex
            val sinkHex = s.checksumHex

            val transportCompleted = stateAtCompletion == State.COMPLETED &&
                final.state == NativeState.COMPLETED && completedCount.get() == 1 && failedCount.get() == 0 &&
                final.positionFrame == declared && final.eosPushed && final.eosDrained

            lanes[LANE_FORMAT_PROBE] = fmt.sampleRate > 0 && fmt.channelCount in 1..2 && declared > 0L && fmt.sourceMime.isNotBlank()
            lanes[LANE_PRE_ROLL] = preRollFrames > 0L && (preRollRingFull || preRollFrames == declared) &&
                preRollStatePrepared && startAcceptedPlaying && preRollFrames <= declared
            // Progress must be measured from the post-resume baseline: the
            // sink was already unparked (and may have drained pre-mixed
            // output) before transport.resume() was issued.
            lanes[LANE_POST_RESUME_DRAIN] = s.exitReason == VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.EXIT_EOS &&
                s.eosDrainedObserved && resumeAccepted &&
                framesWrittenAtResume >= holdEndFramesWritten && drainCallsAtResume >= holdEndDrainCalls &&
                s.framesWrittenToSink > framesWrittenAtResume && s.drainCalls > drainCallsAtResume &&
                f.exitReason == VanguardRealtimePlaybackDecoderFeed.EXIT_EOS && f.acceptedFrames == declared &&
                s.parkCount == 1 && s.unparkCount == 1 &&
                s.phase == VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.Phase.RUNNING
            lanes[LANE_SINK_WRITE_ACCOUNTING] = s.exitReason == VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.EXIT_EOS &&
                s.framesReadFromTransport == declared && s.framesWrittenToSink == declared &&
                final.pushedFrames == declared && final.drainedFrames == declared && final.discardedFrames == 0L
            lanes[LANE_CHECKSUM_IDENTITY] = decoderHex.isNotBlank() &&
                decoderHex.equals(final.pushedChecksumHex, ignoreCase = true) &&
                decoderHex.equals(final.drainedChecksumHex, ignoreCase = true) &&
                decoderHex.equals(sinkHex, ignoreCase = true)
            lanes[LANE_PLAYBACK_HEAD_ADVANCED] = s.played && s.playbackHeadFinal > 0L &&
                s.playbackHeadFinal > s.playbackHeadAtUnpark
            lanes[LANE_TRANSPORT_COMPLETED] = transportCompleted && final.lastError == "none"
            lanes[LANE_THREAD_OWNERSHIP] = f.ingestCallbacksOnOwner.get() > 0L && f.ingestCallbacksOffOwner.get() == 0L &&
                !f.threadIsTransportOwner && !s.threadIsTransportOwner &&
                f.threadId > 0L && s.threadId > 0L && f.threadId != s.threadId &&
                f.threadId != coordinatorThreadId && s.threadId != coordinatorThreadId &&
                s.parkExecutedOnSinkThread && s.unparkExecutedOnSinkThread &&
                listenerOnOwner.get() > 0L && listenerOffOwner.get() == 0L &&
                commandsIssued == COMMANDS_PER_SESSION && startGeneration == prepareGeneration + 1L &&
                pauseGeneration == startGeneration && resumeGeneration == startGeneration &&
                machine.currentGeneration == startGeneration && final.wrongOwnerThread.not()
            lanes[LANE_LIFECYCLE_DISPOSE] = feedJoined && sinkJoined &&
                f.mediaReleaseCount.get() == 1L && f.mediaReleaseClean &&
                s.releaseCount.get() == 1 && disposeCalls == 1 &&
                stateAfterDispose == State.DISPOSED && stateAfterSecondDispose == State.DISPOSED &&
                !postIngestAfterDispose && machine.currentState == State.DISPOSED
        }

        // ── Metrics ────────────────────────────────────────────────────────

        fun publishMetrics() {
            val fmt = format
            val f = feed
            val s = sink
            val machine = sm
            val final = finalReply
            val t0 = holdStart
            val t1 = holdEnd
            metrics["sourceMime"] = fmt?.sourceMime ?: ""
            metrics["sourceTrackIndex"] = fmt?.sourceTrackIndex ?: -1
            metrics["sourceDurationUs"] = fmt?.sourceDurationUs ?: -1L
            metrics["declaredWindowUs"] = fmt?.declaredWindowUs ?: -1L
            metrics["sampleRate"] = fmt?.sampleRate ?: 0
            metrics["channelCount"] = fmt?.channelCount ?: 0
            metrics["pcmEncoding"] = fmt?.pcmEncoding ?: 0
            metrics["declaredFrameCount"] = fmt?.declaredFrameCount ?: 0L
            metrics["preRollFrames"] = preRollFrames
            metrics["preRollRingFullObserved"] = preRollRingFull
            metrics["preRollPartialWriteObserved"] = preRollPartialWrite
            metrics["preRollStatePrepared"] = preRollStatePrepared
            metrics["ingestRingFullCount"] = f?.ingestRingFullCount ?: 0L
            metrics["ingestPartialWriteCount"] = f?.ingestPartialWriteCount ?: 0L
            metrics["ingestCalls"] = f?.ingestCalls ?: 0L
            metrics["staleGenerationRetries"] = f?.staleGenerationRetries ?: 0L
            metrics["transientRejects"] = f?.transientRejects ?: 0L
            metrics["nativeBackpressureCount"] = final?.backpressureCount ?: -1L
            metrics["nativeUnderrunCount"] = final?.underrunCount ?: -1L
            metrics["nativeDispatchCount"] = final?.dispatchCount ?: -1L
            metrics["eosPaddedFrames"] = f?.paddedFrames ?: 0L
            metrics["eosTruncatedFrames"] = f?.truncatedFrames ?: 0L
            metrics["decoderDiscardedFrames"] = f?.discardedFrames ?: 0L
            metrics["decoderAcceptedFrames"] = f?.acceptedFrames ?: 0L
            metrics["decoderDecodedFramesAccepted"] = (f?.acceptedFrames ?: 0L) - (f?.paddedFrames ?: 0L)
            metrics["codecChunks"] = f?.codecChunks ?: 0L
            metrics["decodedFramesTotal"] = f?.decodedFramesTotal ?: 0L
            metrics["framesReadFromTransport"] = s?.framesReadFromTransport ?: 0L
            metrics["framesWrittenToSink"] = s?.framesWrittenToSink ?: 0L
            metrics["partialWriteCount"] = s?.partialWriteCount ?: 0L
            metrics["zeroWriteCount"] = s?.zeroWriteCount ?: 0L
            metrics["drainCalls"] = s?.drainCalls ?: 0L
            metrics["emptyDrainCount"] = s?.emptyDrainCount ?: 0L
            metrics["playbackHeadFinal"] = s?.playbackHeadFinal ?: 0L
            metrics["playbackHeadCaughtUp"] = s?.playbackHeadCaughtUp ?: false
            metrics["audioTrackInitOk"] = s?.audioTrackInitOk ?: false
            metrics["gainSetOk"] = s?.gainSetOk ?: false
            metrics["gainValue"] = (s?.gainValue ?: 0f).toDouble()
            metrics["audioTrackBufferBytes"] = s?.audioTrackBufferBytes ?: 0
            metrics["decodeThreadWallMs"] = f?.decodeThreadWallMs ?: 0L
            metrics["sinkThreadWallMs"] = s?.sinkThreadWallMs ?: 0L
            metrics["sessionWallMs"] = sessionWallMs
            metrics["kotlinDecoderChecksumHex"] = f?.checksumHex ?: ""
            metrics["kotlinSinkChecksumHex"] = s?.checksumHex ?: ""
            metrics["nativePushedChecksumHex"] = final?.pushedChecksumHex ?: ""
            metrics["nativeDrainedChecksumHex"] = final?.drainedChecksumHex ?: ""
            metrics["mediaReleaseCount"] = f?.mediaReleaseCount?.get() ?: 0L
            metrics["mediaReleaseClean"] = f?.mediaReleaseClean ?: false
            metrics["audioTrackReleaseCount"] = s?.releaseCount?.get() ?: 0
            metrics["transportDisposeCalls"] = disposeCalls
            metrics["decoderThreadJoined"] = feedJoined
            metrics["sinkThreadJoined"] = sinkJoined
            metrics["decoderExitReason"] = f?.exitReason ?: VanguardRealtimePlaybackDecoderFeed.EXIT_NOT_STARTED
            metrics["sinkExitReason"] = s?.exitReason ?: VanguardRealtimePlaybackPipelinePauseResumeSinkBridge.EXIT_NOT_STARTED
            metrics["decoderThreadId"] = f?.threadId ?: -1L
            metrics["sinkThreadId"] = s?.threadId ?: -1L
            metrics["ingestCallbacksOnOwner"] = f?.ingestCallbacksOnOwner?.get() ?: 0L
            metrics["ingestCallbacksOffOwner"] = f?.ingestCallbacksOffOwner?.get() ?: 0L
            metrics["listenerCallbacksOnOwner"] = listenerOnOwner.get()
            metrics["listenerCallbacksOffOwner"] = listenerOffOwner.get()
            metrics["transportCommandsIssued"] = commandsIssued
            metrics["transportPrepareGeneration"] = prepareGeneration
            metrics["transportStartGeneration"] = startGeneration
            metrics["transportPauseGeneration"] = pauseGeneration
            metrics["transportResumeGeneration"] = resumeGeneration
            metrics["transportGenerationFinal"] = machine?.currentGeneration ?: -1L
            metrics["transportStateBeforeDispose"] = stateBeforeDispose.name
            metrics["transportStateFinal"] = machine?.currentState?.name ?: "none"
            metrics["transportStateTransitions"] = synchronized(transitions) { transitions.toString() }
            metrics["transportCompletedCallbacks"] = completedCount.get()
            metrics["transportFailedCallbacks"] = failedCount.get()
            metrics["postIngestAfterDisposePosted"] = postIngestAfterDispose
            metrics["nativeStateFinal"] = final?.stateToken ?: "none"
            metrics["nativeWorkerExited"] = final?.workerExited ?: false
            metrics["nativeWorkerJoined"] = final?.workerJoined ?: false
            metrics["positionFrame"] = final?.positionFrame ?: -1L
            metrics["pushedFrames"] = final?.pushedFrames ?: -1L
            metrics["drainedFrames"] = final?.drainedFrames ?: -1L
            metrics["discardedFrames"] = final?.discardedFrames ?: -1L
            metrics["eosPushed"] = final?.eosPushed ?: false
            metrics["eosDrained"] = final?.eosDrained ?: false
            metrics["lastError"] = final?.lastError ?: "none"
            // Pause / resume proof.
            metrics["initialWriteWaitMs"] = initialWriteWaitMs
            metrics["framesWrittenBeforePark"] = framesWrittenBeforePark
            metrics["drainCallsBeforePark"] = drainCallsBeforePark
            metrics["transportStateBeforePark"] = stateBeforePark.name
            metrics["positionFrameBeforePark"] = positionBeforePark
            metrics["pausePositionLimit"] = pausePositionLimit
            metrics["sinkParkRequested"] = parkRequested
            metrics["sinkParkAcked"] = parkAcked
            metrics["sinkParkAckWaitMs"] = parkAckWaitMs
            metrics["sinkParkAckLatencyMs"] = s?.parkAckLatencyMs ?: -1L
            metrics["sinkParkCount"] = s?.parkCount ?: 0
            metrics["sinkUnparkCount"] = s?.unparkCount ?: 0
            metrics["sinkParkRequestCount"] = s?.parkRequestCount ?: 0
            metrics["sinkPhaseFinal"] = s?.phase?.name ?: "none"
            metrics["sinkPlayStateAtPark"] = s?.playStateAtPark ?: -1
            metrics["sinkPlayStateAfterUnpark"] = s?.playStateAfterUnpark ?: -1
            metrics["sinkParkedPlayStateObservations"] = s?.parkedPlayStateObservations ?: 0L
            metrics["sinkParkedPlayStateViolations"] = s?.parkedPlayStateViolations ?: 0L
            metrics["sinkParkExecutedOnSinkThread"] = s?.parkExecutedOnSinkThread ?: false
            metrics["sinkUnparkExecutedOnSinkThread"] = s?.unparkExecutedOnSinkThread ?: false
            metrics["sinkFramesWrittenAtPark"] = s?.framesWrittenAtPark ?: 0L
            metrics["sinkDrainCallsAtPark"] = s?.drainCallsAtPark ?: 0L
            metrics["sinkPlaybackHeadAtPark"] = s?.playbackHeadAtPark ?: 0L
            metrics["sinkPlaybackHeadAtUnpark"] = s?.playbackHeadAtUnpark ?: 0L
            metrics["sinkParkedHoldMs"] = s?.parkedHoldMs ?: -1L
            metrics["pauseAccepted"] = pauseAccepted
            metrics["pauseState"] = pauseState.name
            metrics["pauseReason"] = pauseReason
            metrics["holdStartNativeState"] = t0?.stateToken ?: "none"
            metrics["holdEndNativeState"] = t1?.stateToken ?: "none"
            metrics["holdStartTransportState"] = holdStartTransportState.name
            metrics["holdEndTransportState"] = holdEndTransportState.name
            metrics["holdStartSinkPlayState"] = holdStartPlayState
            metrics["holdEndSinkPlayState"] = holdEndPlayState
            metrics["holdStartPositionFrame"] = t0?.positionFrame ?: -1L
            metrics["holdEndPositionFrame"] = t1?.positionFrame ?: -1L
            metrics["holdStartDispatchCount"] = t0?.dispatchCount ?: -1L
            metrics["holdEndDispatchCount"] = t1?.dispatchCount ?: -1L
            metrics["holdStartPushedFrames"] = t0?.pushedFrames ?: -1L
            metrics["holdEndPushedFrames"] = t1?.pushedFrames ?: -1L
            metrics["holdStartDrainCalls"] = holdStartDrainCalls
            metrics["holdEndDrainCalls"] = holdEndDrainCalls
            metrics["holdStartFramesWritten"] = holdStartFramesWritten
            metrics["holdEndFramesWritten"] = holdEndFramesWritten
            metrics["holdDispatchDelta"] = holdDispatchDelta
            metrics["holdPushedDelta"] = holdPushedDelta
            metrics["holdDrainCallsDelta"] = holdDrainCallsDelta
            metrics["holdWrittenDelta"] = holdWrittenDelta
            metrics["holdActualMs"] = holdActualMs
            metrics["resumeAccepted"] = resumeAccepted
            metrics["resumeState"] = resumeState.name
            metrics["resumeReason"] = resumeReason
            metrics["sinkUnparkRequested"] = unparkRequested
            metrics["sinkUnparkAcked"] = unparkAcked
            metrics["sinkUnparkAckWaitMs"] = unparkAckWaitMs
            metrics["framesWrittenAfterUnpark"] = framesWrittenAfterUnpark
            metrics["drainCallsAfterUnpark"] = drainCallsAfterUnpark
            metrics["framesWrittenAtResume"] = framesWrittenAtResume
            metrics["drainCallsAtResume"] = drainCallsAtResume
            metrics["failureReason"] = failure.get() ?: ""
        }
    }

    // ── Result assembly ────────────────────────────────────────────────────

    private fun firstFailedLane(): String = REQUIRED_LANES.firstOrNull { lanes[it] != true } ?: "none"

    private fun buildResult(pass: Boolean, failureReason: String): Result {
        val laneMap = linkedMapOf<String, Boolean>()
        for (lane in REQUIRED_LANES) laneMap[lane] = pass || (lanes[lane] == true)
        laneMap[LANE_PROOF_BOUNDARY] = true
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
