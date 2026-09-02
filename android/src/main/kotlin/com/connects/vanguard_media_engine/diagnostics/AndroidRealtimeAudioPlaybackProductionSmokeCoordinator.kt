package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioTrack
import android.os.Handler
import android.os.SystemClock
import android.util.Log
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSinkBridge
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackDecoderFeed
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackPresentationClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SINK-CLOCK (Y8a) +
 * P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-DEAD-OBJECT (Y8b):
 * production-component diagnostic smoke coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route only. It drives the PRODUCTION
 * [VanguardRealtimeAudioPlaybackSession] (real MediaExtractor/MediaCodec ->
 * Y5a external ingest -> Y1 transport -> sink-thread-owned non-zero-gain
 * AudioTrack + presentation clock) through three scenarios on a worker
 * thread, evaluates proof lanes from the session's snapshots, posts the
 * payload on the main handler and logs the START / JSON / PASS / FAIL
 * markers. Every lifecycle decision lives in the session; this class only
 * maps arguments, sequences scenarios, evaluates lanes and reports.
 *
 * Scenario 3 (Y8b) arms the session's ONE synthetic ERROR_DEAD_OBJECT after
 * [SmokeConfig.deadObjectInjectAfterFrames] written frames; the two Y8a
 * baseline scenarios run with the seam off. The synthetic injection proves
 * the recovery sequence only; a real OS dead object is not forced here and
 * fails closed in the sink by construction.
 */
class AndroidRealtimeAudioPlaybackProductionSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardY8aProductionSink"
        const val METHOD_NAME = "runRealtimeAudioPlaybackProductionSmoke"

        const val START_MARKER = "ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_SMOKE_START"
        const val JSON_MARKER = "ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_JSON"
        const val PASS_MARKER = "ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_PHYSICAL_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_PHYSICAL_SMOKE_FAIL"

        const val PROOF_BOUNDARY =
            "production_engine_component_diagnostic_route_real_mediaextractor_mediacodec_to_y5a_external_ingest_" +
                "to_y1_transport_to_nonzero_gain_audiotrack_sink_thread_owned_audiotrack_and_presentation_clock_" +
                "bounded_pause_resume_closes_reopens_clock_epoch_at_last_published_position_" +
                "synthetic_armed_dead_object_recovered_once_on_sink_thread_same_parameter_audiotrack_epoch_rebase_" +
                "real_or_repeated_dead_object_fails_closed_" +
                "stop_dispose_release_once_no_seek_" +
                "no_product_no_editor_no_app_no_connectsapp_no_ios_no_streaming_no_cache_no_cpp_no_jni"

        const val SCENARIO_PLAYTHROUGH = "PLAYTHROUGH_BOUNDED_PAUSE_RESUME_TO_EOS"
        const val SCENARIO_STOP_DISPOSE = "STOP_DISPOSE_MID_PLAYBACK"
        const val SCENARIO_DEAD_OBJECT_RECOVERY = "SYNTHETIC_DEAD_OBJECT_RECOVERY_TO_EOS"

        const val DEFAULT_PAUSE_HOLD_MS = 400L
        const val DEFAULT_STOP_AFTER_MS = 300L
        // Frames written before the ONE synthetic dead object is armed
        // (~186 ms at 44.1 kHz); must stay below the clip's declared frames.
        const val DEFAULT_DEAD_OBJECT_INJECT_AFTER_FRAMES = 8_192L
        // Device observability budget for the dead-object publication lag
        // (head consumed by the dead instance minus the last published clock
        // position) when the clock was ANCHORED or EXTRAPOLATED at recovery.
        // It bounds how far the clock's view may trail the hardware on the
        // proof device; it is NOT a playback latency target or an SLA.
        const val DEAD_OBJECT_PUBLICATION_LAG_BUDGET_MS = 300L

        const val LANE_FORMAT_PROBE = "formatProbeOk"
        const val LANE_PRE_ROLL = "preRollOk"
        const val LANE_START = "startOk"
        const val LANE_NONZERO_GAIN = "nonZeroGainAudioTrackOk"
        const val LANE_PLAYTHROUGH_ACCOUNTING = "playthroughAccountingOk"
        const val LANE_CHECKSUM_IDENTITY = "checksumIdentityOk"
        const val LANE_CLOCK_ANCHORED = "clockAnchoredOk"
        const val LANE_CLOCK_MONOTONIC = "clockMonotonicOk"
        const val LANE_CLOCK_EPOCH_BALANCED = "clockEpochBalancedOk"
        const val LANE_CLOCK_PAUSE_FROZEN = "clockPauseFrozenOk"
        const val LANE_BOUNDED_PAUSE_RESUME = "boundedPauseResumeOk"
        const val LANE_STOP_DISPOSE = "stopDisposeOk"
        const val LANE_DECODER_CANCELLED_ON_STOP = "decoderCancelledOnStopOk"
        const val LANE_TRANSPORT_DISPOSED = "transportDisposedOk"
        const val LANE_AUDIO_TRACK_RELEASED_ONCE = "audioTrackReleasedOnceOk"
        const val LANE_THREAD_OWNERSHIP = "threadOwnershipOk"
        const val LANE_NO_FEEDBACK = "noFeedbackOk"
        const val LANE_PROOF_BOUNDARY = "proofBoundaryOk"
        // Y8b lanes, evaluated by the dead-object scenario only.
        const val LANE_DEAD_OBJECT_RECOVERY = "syntheticDeadObjectRecoveryOk"
        const val LANE_DEAD_OBJECT_CLOCK_EPOCH = "deadObjectClockEpochRebaseOk"
        const val LANE_DEAD_OBJECT_REMAINDER = "deadObjectRemainderAccountingOk"
        const val LANE_CANONICAL = "canonical"

        val REQUIRED_LANES: List<String> = listOf(
            LANE_FORMAT_PROBE, LANE_PRE_ROLL, LANE_START, LANE_NONZERO_GAIN,
            LANE_PLAYTHROUGH_ACCOUNTING, LANE_CHECKSUM_IDENTITY,
            LANE_CLOCK_ANCHORED, LANE_CLOCK_MONOTONIC, LANE_CLOCK_EPOCH_BALANCED, LANE_CLOCK_PAUSE_FROZEN,
            LANE_BOUNDED_PAUSE_RESUME, LANE_STOP_DISPOSE, LANE_DECODER_CANCELLED_ON_STOP,
            LANE_TRANSPORT_DISPOSED, LANE_AUDIO_TRACK_RELEASED_ONCE, LANE_THREAD_OWNERSHIP,
            LANE_NO_FEEDBACK, LANE_PROOF_BOUNDARY,
            LANE_DEAD_OBJECT_RECOVERY, LANE_DEAD_OBJECT_CLOCK_EPOCH, LANE_DEAD_OBJECT_REMAINDER,
        )

        private val PROOF_BOUNDARY_TOKENS = listOf(
            "production_engine_component_diagnostic_route", "real_mediaextractor_mediacodec", "y5a_external_ingest",
            "y1_transport", "nonzero_gain_audiotrack", "sink_thread_owned_audiotrack_and_presentation_clock",
            "bounded_pause_resume_closes_reopens_clock_epoch_at_last_published_position",
            "synthetic_armed_dead_object_recovered_once_on_sink_thread", "same_parameter_audiotrack", "epoch_rebase",
            "real_or_repeated_dead_object_fails_closed", "stop_dispose_release_once",
            "no_seek", "no_product", "no_editor", "no_app", "no_connectsapp", "no_ios",
            "no_streaming", "no_cache", "no_cpp", "no_jni",
        )

        private const val FAILURE_SOURCE_PATH_REQUIRED = "source_path_required"
        private const val FIRST_AUDIO_TIMEOUT_MS = 3_000L
        private const val WAIT_SLICE_MS = 5L

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private class FailClosed(val reason: String) : Exception(reason)

    private data class SmokeConfig(
        val sourcePath: String,
        val maxDurationSec: Double,
        val maxFramesPerMix: Int,
        val gain: Float,
        val deadlineMs: Long,
        val pauseHoldMs: Long,
        val maxPauseHoldMs: Long,
        val stopAfterMs: Long,
        val deadObjectInjectAfterFrames: Long,
    )

    // Per-scenario expected AudioTrack instance/dead-object accounting.
    private data class SinkExpectation(
        val audioTracksCreated: Int,
        val oldTrackReleases: Int,
        val deadObjectsInjected: Long,
        val deadObjectsObserved: Long,
    )

    private val baselineExpectation = SinkExpectation(audioTracksCreated = 1, oldTrackReleases = 0, deadObjectsInjected = 0L, deadObjectsObserved = 0L)
    private val deadObjectExpectation = SinkExpectation(audioTracksCreated = 2, oldTrackReleases = 1, deadObjectsInjected = 1L, deadObjectsObserved = 1L)

    private class ScenarioOutcome(val name: String) {
        val lanes = linkedMapOf<String, Boolean>()
        val metrics = linkedMapOf<String, Any?>()
        var failureReason = ""
    }

    private val active = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)

    @Volatile
    private var activeSession: VanguardRealtimeAudioPlaybackSession? = null

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        if (method != METHOD_NAME) return false
        if (disposed.get()) {
            Log.w(TAG, "$METHOD_NAME ignored: coordinator disposed")
            return true
        }
        val sourcePath = args?.get("sourcePath") as? String
        if (sourcePath.isNullOrBlank()) {
            Log.i(TAG, START_MARKER)
            val payload = buildFailurePayload(FAILURE_SOURCE_PATH_REQUIRED)
            logOutcome(payload)
            try {
                result.success(payload)
            } catch (t: Throwable) {
                Log.w(TAG, "$METHOD_NAME reply dropped: ${t.javaClass.simpleName}")
            }
            return true
        }
        if (!active.compareAndSet(false, true)) {
            result.error("P4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_SMOKE_BUSY", "$METHOD_NAME: diagnostic already running", null)
            return true
        }
        val config = SmokeConfig(
            sourcePath = sourcePath,
            maxDurationSec = (args["maxDurationSec"] as? Number)?.toDouble() ?: 3.0,
            maxFramesPerMix = (args["maxFramesPerMix"] as? Number)?.toInt() ?: 256,
            gain = (args["gain"] as? Number)?.toFloat() ?: 0.5f,
            deadlineMs = (args["deadlineMs"] as? Number)?.toLong() ?: 30_000L,
            pauseHoldMs = (args["pauseHoldMs"] as? Number)?.toLong() ?: DEFAULT_PAUSE_HOLD_MS,
            maxPauseHoldMs = (args["maxPauseHoldMs"] as? Number)?.toLong()
                ?: VanguardRealtimeAudioPlaybackSession.DEFAULT_MAX_PAUSE_HOLD_MS,
            stopAfterMs = (args["stopAfterMs"] as? Number)?.toLong() ?: DEFAULT_STOP_AFTER_MS,
            deadObjectInjectAfterFrames = (args["deadObjectInjectAfterFrames"] as? Number)?.toLong()
                ?: DEFAULT_DEAD_OBJECT_INJECT_AFTER_FRAMES,
        )
        runSmoke(config, result)
        return true
    }

    fun disposeAll() {
        disposed.set(true)
        try {
            activeSession?.cancel()
        } catch (_: Throwable) {}
        activeSession = null
    }

    // ── Run ────────────────────────────────────────────────────────────────

    private fun runSmoke(config: SmokeConfig, result: MethodChannel.Result) {
        val replied = AtomicBoolean(false)
        Thread({
            try {
                Log.i(TAG, START_MARKER)
                val payload = execute(config)
                logOutcome(payload)
                postReply(replied, result, payload)
            } catch (t: Throwable) {
                Log.e(TAG, "$METHOD_NAME uncaught failure", t)
                val failPayload = buildFailurePayload("uncaught_exception:${t.javaClass.simpleName}:${t.message}")
                logOutcome(failPayload)
                postReply(replied, result, failPayload)
            } finally {
                activeSession = null
                active.set(false)
            }
        }, "Y8aProductionSinkSmoke").start()
    }

    private fun execute(config: SmokeConfig): Map<String, Any?> {
        val metrics = linkedMapOf<String, Any?>(
            "maxDurationSec" to config.maxDurationSec,
            "maxFramesPerMix" to config.maxFramesPerMix,
            "gain" to config.gain.toDouble(),
            "deadlineMs" to config.deadlineMs,
            "pauseHoldMs" to config.pauseHoldMs,
            "maxPauseHoldMs" to config.maxPauseHoldMs,
            "stopAfterMs" to config.stopAfterMs,
            "deadObjectInjectAfterFrames" to config.deadObjectInjectAfterFrames,
            "coordinatorThreadId" to Thread.currentThread().id,
        )
        val outcomes = ArrayList<ScenarioOutcome>(3)
        if (config.pauseHoldMs <= 0L || config.pauseHoldMs >= config.maxPauseHoldMs) {
            return buildPayload(false, "invalid_pause_hold:${config.pauseHoldMs}:${config.maxPauseHoldMs}", emptyList(), metrics)
        }
        if (config.deadObjectInjectAfterFrames <= 0L) {
            return buildPayload(false, "invalid_dead_object_inject_after_frames:${config.deadObjectInjectAfterFrames}", emptyList(), metrics)
        }
        // Y8a baseline scenarios run with the dead-object seam OFF.
        outcomes += runScenario(SCENARIO_PLAYTHROUGH, config, injectAfterFrames = 0L) { session, outcome ->
            playthroughScenario(session, config, outcome)
        }
        if (disposed.get()) return buildPayload(false, "coordinator_disposed", outcomes, metrics)
        outcomes += runScenario(SCENARIO_STOP_DISPOSE, config, injectAfterFrames = 0L) { session, outcome ->
            stopDisposeScenario(session, config, outcome)
        }
        if (disposed.get()) return buildPayload(false, "coordinator_disposed", outcomes, metrics)
        // Y8b: the ONE synthetic dead object is armed for this scenario only.
        outcomes += runScenario(SCENARIO_DEAD_OBJECT_RECOVERY, config, injectAfterFrames = config.deadObjectInjectAfterFrames) { session, outcome ->
            deadObjectRecoveryScenario(session, config, outcome)
        }

        val lanes = aggregateLanes(outcomes)
        val firstFailure = outcomes.firstOrNull { it.failureReason.isNotBlank() }?.let { "${it.name}:${it.failureReason}" } ?: ""
        val pass = firstFailure.isBlank() && REQUIRED_LANES.all { lanes[it] == true }
        val reason = if (pass) "" else firstFailure.ifBlank { "lane_failed:${REQUIRED_LANES.firstOrNull { lanes[it] != true } ?: "none"}" }
        return buildPayload(pass, reason, outcomes, metrics)
    }

    private fun runScenario(
        name: String,
        config: SmokeConfig,
        injectAfterFrames: Long,
        body: (VanguardRealtimeAudioPlaybackSession, ScenarioOutcome) -> Unit,
    ): ScenarioOutcome {
        val outcome = ScenarioOutcome(name)
        val session = VanguardRealtimeAudioPlaybackSession(
            VanguardRealtimeAudioPlaybackSession.Config(
                sourcePath = config.sourcePath,
                maxDurationSec = config.maxDurationSec,
                maxFramesPerMix = config.maxFramesPerMix,
                gain = config.gain,
                deadlineMs = config.deadlineMs,
                maxPauseHoldMs = config.maxPauseHoldMs,
                threadNamePrefix = "Y8a$name",
                syntheticDeadObjectInjectAfterFrames = injectAfterFrames,
            ),
        )
        outcome.metrics["deadObjectInjectAfterFrames"] = injectAfterFrames
        activeSession = session
        val wallStart = SystemClock.elapsedRealtime()
        try {
            if (disposed.get()) throw FailClosed("coordinator_disposed")
            body(session, outcome)
        } catch (f: FailClosed) {
            outcome.failureReason = f.reason
        } catch (t: Throwable) {
            outcome.failureReason = "exception:${t.javaClass.simpleName}:${t.message}"
        } finally {
            try {
                session.dispose()
            } catch (_: Throwable) {}
            if (activeSession === session) activeSession = null
            val snap = session.snapshot()
            if (outcome.failureReason.isBlank() && snap.failureReason.isNotBlank()) outcome.failureReason = snap.failureReason
            outcome.metrics.putAll(snapshotMetrics(snap))
            outcome.metrics["scenarioWallMs"] = SystemClock.elapsedRealtime() - wallStart
            outcome.metrics["failureReason"] = outcome.failureReason
        }
        return outcome
    }

    private fun require(condition: Boolean, reason: String) {
        if (!condition) throw FailClosed(reason)
    }

    private fun startAndAwaitAudio(session: VanguardRealtimeAudioPlaybackSession) {
        val res = session.start()
        require(res.accepted && res.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING, "start_rejected:${res.reason}")
        require(session.awaitFirstAudio(FIRST_AUDIO_TIMEOUT_MS), "no_first_audio:${session.failureReason}")
    }

    // ── Scenario 1: load/start -> bounded pause -> resume -> EOS ───────────

    private fun playthroughScenario(session: VanguardRealtimeAudioPlaybackSession, config: SmokeConfig, out: ScenarioOutcome) {
        startAndAwaitAudio(session)
        val pauseRes = session.pauseBounded()
        require(pauseRes.accepted && pauseRes.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED, "pause_rejected:${pauseRes.reason}")
        val holdStart = session.snapshot()
        val holdStartedAt = SystemClock.elapsedRealtime()
        while (SystemClock.elapsedRealtime() - holdStartedAt < config.pauseHoldMs) {
            require(session.failureReason.isBlank(), "failure_during_hold:${session.failureReason}")
            SystemClock.sleep(WAIT_SLICE_MS)
        }
        val holdEnd = session.snapshot()
        val resumeRes = session.resume()
        require(resumeRes.accepted && resumeRes.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING, "resume_rejected:${resumeRes.reason}")
        require(session.awaitCompletion(config.deadlineMs), "completion_not_reached:${session.failureReason}")
        val stateAtCompletion = session.currentState
        val stopRes = session.stop()
        require(stopRes.accepted, "stop_rejected:${stopRes.reason}")
        session.dispose()
        session.dispose()
        val final = session.snapshot()
        evaluateCommon(final, baselineExpectation, out)
        evaluatePlaythrough(final, holdStart, holdEnd, stateAtCompletion, config, out)
    }

    // ── Scenario 3 (Y8b): load/start -> armed synthetic dead object ->
    //    sink-thread recovery -> EOS ───────────────────────────────────────

    private fun deadObjectRecoveryScenario(session: VanguardRealtimeAudioPlaybackSession, config: SmokeConfig, out: ScenarioOutcome) {
        startAndAwaitAudio(session)
        val waitStart = SystemClock.elapsedRealtime()
        var afterRecovery: VanguardRealtimeAudioPlaybackSession.Snapshot
        while (true) {
            val snap = session.snapshot()
            require(snap.failureReason.isBlank(), "failure_before_recovery:${snap.failureReason}")
            val k = snap.sink ?: throw FailClosed("sink_missing_before_recovery")
            if (k.deadObjectRecoveryCount == 1) {
                afterRecovery = snap
                break
            }
            require(k.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_RUNNING, "sink_exited_before_recovery:${k.exitReason}")
            require(SystemClock.elapsedRealtime() - waitStart < config.deadlineMs, "recovery_not_observed:${k.framesWrittenToSink}")
            SystemClock.sleep(WAIT_SLICE_MS)
        }
        require(session.awaitCompletion(config.deadlineMs), "completion_not_reached:${session.failureReason}")
        val stateAtCompletion = session.currentState
        val stopRes = session.stop()
        require(stopRes.accepted, "stop_rejected:${stopRes.reason}")
        session.dispose()
        session.dispose()
        val final = session.snapshot()
        evaluateCommon(final, deadObjectExpectation, out)
        evaluateDeadObjectRecovery(final, afterRecovery, stateAtCompletion, config, out)
    }

    // ── Scenario 2: load/start -> stop/dispose before EOS ──────────────────

    private fun stopDisposeScenario(session: VanguardRealtimeAudioPlaybackSession, config: SmokeConfig, out: ScenarioOutcome) {
        startAndAwaitAudio(session)
        val waitStart = SystemClock.elapsedRealtime()
        while (SystemClock.elapsedRealtime() - waitStart < config.stopAfterMs) {
            require(session.failureReason.isBlank(), "failure_before_stop:${session.failureReason}")
            SystemClock.sleep(WAIT_SLICE_MS)
        }
        val beforeStop = session.snapshot()
        val sinkBefore = beforeStop.sink ?: throw FailClosed("sink_missing_before_stop")
        val declared = beforeStop.format?.declaredFrameCount ?: throw FailClosed("format_missing")
        require(sinkBefore.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_RUNNING, "sink_not_running_before_stop:${sinkBefore.exitReason}")
        require(beforeStop.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING, "not_playing_before_stop:${beforeStop.state}")
        require(sinkBefore.framesWrittenToSink in 1 until declared, "stop_not_mid_playback:${sinkBefore.framesWrittenToSink}:$declared")
        val stopRes = session.stop()
        val stateAfterStop = session.currentState
        session.dispose()
        val stateAfterDispose = session.currentState
        session.dispose()
        val stateAfterSecondDispose = session.currentState
        val final = session.snapshot()
        val sink = final.sink ?: throw FailClosed("sink_missing_after_stop")
        out.metrics["stopAccepted"] = stopRes.accepted
        out.metrics["stopReason"] = stopRes.reason
        out.metrics["stateAfterStop"] = stateAfterStop.name
        out.metrics["stateAfterDispose"] = stateAfterDispose.name
        out.metrics["stateAfterSecondDispose"] = stateAfterSecondDispose.name
        out.metrics["framesWrittenBeforeStop"] = sinkBefore.framesWrittenToSink
        evaluateCommon(final, baselineExpectation, out)
        out.lanes[LANE_STOP_DISPOSE] = stopRes.accepted && stopRes.state == VanguardRealtimeAudioPlaybackSession.State.STOPPED &&
            stateAfterStop == VanguardRealtimeAudioPlaybackSession.State.STOPPED &&
            stateAfterDispose == VanguardRealtimeAudioPlaybackSession.State.DISPOSED &&
            stateAfterSecondDispose == VanguardRealtimeAudioPlaybackSession.State.DISPOSED &&
            sink.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_CANCELLED &&
            sink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.EXITED &&
            sink.framesWrittenToSink >= sinkBefore.framesWrittenToSink && sink.framesWrittenToSink < declared &&
            !sink.eosDrainedObserved && final.transportStopAccepted &&
            final.transportStateBeforeDispose == VanguardRealtimePlaybackTransportStateMachine.State.STOPPED &&
            final.failureReason.isBlank()
        out.lanes[LANE_DECODER_CANCELLED_ON_STOP] = final.decoderCancelRequested && final.decoderJoined &&
            final.decoderExitReason == VanguardRealtimePlaybackDecoderFeed.EXIT_CANCELLED &&
            final.decoderMediaReleaseCount == 1L && final.decoderMediaReleaseClean &&
            final.decoderAcceptedFrames < declared
    }

    // ── Lane evaluation ────────────────────────────────────────────────────

    private fun evaluateCommon(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        expect: SinkExpectation,
        out: ScenarioOutcome,
    ) {
        val fmt = final.format ?: throw FailClosed("format_missing")
        val sink = final.sink ?: throw FailClosed("sink_missing")
        val clock = final.clock ?: throw FailClosed("clock_missing")
        val declared = fmt.declaredFrameCount
        val coordinatorThreadId = Thread.currentThread().id

        out.lanes[LANE_FORMAT_PROBE] = fmt.sampleRate > 0 && fmt.channelCount in 1..2 && declared > 0L && fmt.sourceMime.isNotBlank()
        out.lanes[LANE_PRE_ROLL] = final.preRollFrames > 0L && (final.preRollRingFullObserved || final.preRollFrames == declared) &&
            final.preRollStatePrepared && final.preRollFrames <= declared
        out.lanes[LANE_START] = final.startAccepted && final.startGeneration == final.prepareGeneration + 1L &&
            final.sinkReadyBeforeTransportStart && final.drainAllowedAfterTransportStart &&
            sink.drainCallsBeforeAllow == 0L && sink.firstDrainAtMs >= final.drainAllowedAtMs && sink.drainCalls > 0L
        out.lanes[LANE_NONZERO_GAIN] = sink.audioTrackInitOk && sink.gainSetOk && sink.gainValue > 0f && sink.played &&
            sink.initialPlayState == AudioTrack.PLAYSTATE_PLAYING && sink.audioTracksCreated == expect.audioTracksCreated &&
            sink.framesWrittenToSink > 0L
        out.lanes[LANE_CLOCK_ANCHORED] = clock.anchoredCount > 0L && clock.timestampSuccessCount > 0L &&
            sink.timestampPollSuccesses == clock.timestampSuccessCount && sink.clockWriterBoundOnSinkThread &&
            clock.writerThreadId == sink.threadId && clock.consistent
        out.lanes[LANE_CLOCK_MONOTONIC] = !clock.faulted && clock.regressionCount == 0L && clock.monotonicViolationCount == 0L &&
            clock.rejectedCount == 0L && sink.clockRejectedCount == 0L && clock.positionFrames >= 0L
        out.lanes[LANE_CLOCK_EPOCH_BALANCED] = clock.epochOpenCount == clock.epochCloseCount && clock.epochOpenCount > 0 && !clock.epochOpen &&
            sink.clockEpochOpenCalls == clock.epochOpenCount && sink.clockEpochCloseCalls == clock.epochCloseCount &&
            sink.currentEpoch == VanguardRealtimeAudioPlaybackSinkBridge.EPOCH_NONE
        // Final release exactly once on every scenario; the dead-object
        // scenario additionally released the old instance exactly once
        // through its own counter, so created == final + old releases.
        out.lanes[LANE_AUDIO_TRACK_RELEASED_ONCE] = sink.releaseCount == 1 && sink.releaseExecutedOnSinkThread && final.sinkJoined &&
            sink.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.EXITED &&
            sink.deadObjectOldTrackReleaseCount == expect.oldTrackReleases &&
            sink.audioTracksCreated == sink.releaseCount + sink.deadObjectOldTrackReleaseCount &&
            sink.deadObjectInjectedCount == expect.deadObjectsInjected && sink.deadObjectObservedCount == expect.deadObjectsObserved &&
            (sink.syntheticDeadObjectInjectAfterFrames > 0L) == (expect.deadObjectsInjected > 0L)
        out.lanes[LANE_TRANSPORT_DISPOSED] = final.transportDisposeCalls == 1 &&
            final.transportStateAfterDispose == VanguardRealtimePlaybackTransportStateMachine.State.DISPOSED &&
            final.transportState == VanguardRealtimePlaybackTransportStateMachine.State.DISPOSED &&
            final.state == VanguardRealtimeAudioPlaybackSession.State.DISPOSED && final.transportStopAccepted &&
            final.transportFailedCallbacks == 0
        out.lanes[LANE_THREAD_OWNERSHIP] = final.decoderThreadId > 0L && sink.threadId > 0L && final.decoderThreadId != sink.threadId &&
            final.decoderThreadId != coordinatorThreadId && sink.threadId != coordinatorThreadId &&
            !final.decoderThreadIsTransportOwner && !sink.threadIsTransportOwner &&
            final.decoderIngestCallbacksOnOwner > 0L && final.decoderIngestCallbacksOffOwner == 0L &&
            final.listenerCallbacksOnOwner > 0L && final.listenerCallbacksOffOwner == 0L &&
            sink.audioTrackCallsOffSinkThread == 0L && clock.offWriterThreadCalls == 0L && clock.writerThreadId == sink.threadId
        out.lanes[LANE_NO_FEEDBACK] = sink.drainRequestSizeChanges == 0L && sink.timestampMaxPollsInOnePass <= 1L &&
            sink.timestampPollAttempts <= sink.productiveDrainPasses &&
            sink.timestampPollAttempts == clock.timestampSuccessCount + clock.timestampUnavailableCount &&
            clock.snapshotCallsFromWriterThread == sink.clockSnapshotsAtPark + sink.clockSnapshotsAtDeadObjectRecovery &&
            sink.timestampPollsWhileParked == 0L
        out.lanes[LANE_PROOF_BOUNDARY] = PROOF_BOUNDARY_TOKENS.all { PROOF_BOUNDARY.contains(it) }
    }

    private fun evaluatePlaythrough(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        holdStart: VanguardRealtimeAudioPlaybackSession.Snapshot,
        holdEnd: VanguardRealtimeAudioPlaybackSession.Snapshot,
        stateAtCompletion: VanguardRealtimeAudioPlaybackSession.State,
        config: SmokeConfig,
        out: ScenarioOutcome,
    ) {
        if (final.format == null) return
        val sink = final.sink ?: return
        val clock = final.clock ?: return
        val atPause = final.clockAtPauseAck
        val beforeResume = final.clockBeforeResume
        val afterResume = final.clockAfterResume
        val hs = holdStart.sink
        val he = holdEnd.sink
        val hsClock = holdStart.clock
        val heClock = holdEnd.clock

        out.metrics["stateAtCompletion"] = stateAtCompletion.name
        out.metrics["holdStartDrainCalls"] = hs?.drainCalls ?: -1L
        out.metrics["holdEndDrainCalls"] = he?.drainCalls ?: -1L
        out.metrics["holdStartClockPosition"] = hsClock?.positionFrames ?: -1L
        out.metrics["holdEndClockPosition"] = heClock?.positionFrames ?: -1L
        out.metrics["holdStartClockUpdateCount"] = hsClock?.updateCount ?: -1L
        out.metrics["holdEndClockUpdateCount"] = heClock?.updateCount ?: -1L

        out.lanes[LANE_PLAYTHROUGH_ACCOUNTING] = playthroughAccountingOk(final, stateAtCompletion)
        out.lanes[LANE_CHECKSUM_IDENTITY] = checksumIdentityOk(final)
        out.lanes[LANE_CLOCK_PAUSE_FROZEN] = atPause != null && beforeResume != null && afterResume != null &&
            hs != null && he != null && hsClock != null && heClock != null &&
            !atPause.epochOpen && atPause.epochId == 0 && atPause.provenance == VanguardRealtimePlaybackPresentationClock.Provenance.RESET &&
            beforeResume.positionFrames == atPause.positionFrames && beforeResume.updateCount == atPause.updateCount && !beforeResume.epochOpen &&
            heClock.positionFrames == hsClock.positionFrames && heClock.updateCount == hsClock.updateCount &&
            he.drainCalls == hs.drainCalls && he.framesWrittenToSink == hs.framesWrittenToSink &&
            he.timestampPollAttempts == hs.timestampPollAttempts &&
            sink.positionAtPark == atPause.positionFrames && sink.timestampPollsWhileParked == 0L && sink.clockSnapshotsAtPark == 1L &&
            afterResume.epochOpen && afterResume.epochId == 1 && afterResume.epochBaseOffsetFrames == atPause.positionFrames &&
            afterResume.positionFrames >= atPause.positionFrames && clock.positionFrames >= atPause.positionFrames &&
            clock.epochOpenCount == 2 && clock.epochCloseCount == 2 && sink.epochClosedAtPark == 0 && sink.epochOpenedAtUnpark == 1
        out.lanes[LANE_BOUNDED_PAUSE_RESUME] = final.pauseAccepted && final.resumeAccepted &&
            final.pauseGeneration == final.startGeneration && final.resumeGeneration == final.startGeneration &&
            sink.parkCount == 1 && sink.unparkCount == 1 && sink.audioTracksCreated == 1 &&
            sink.playStateAtPark == AudioTrack.PLAYSTATE_PAUSED && sink.playStateAfterUnpark == AudioTrack.PLAYSTATE_PLAYING &&
            sink.parkedPlayStateViolations == 0L && sink.parkExecutedOnSinkThread && sink.unparkExecutedOnSinkThread &&
            sink.parkedHoldMs >= config.pauseHoldMs && sink.parkedHoldMs <= config.maxPauseHoldMs &&
            final.pauseHoldObservedMs >= config.pauseHoldMs && final.pauseHoldObservedMs <= config.maxPauseHoldMs &&
            holdStart.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED && holdEnd.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
            holdStart.transportState == VanguardRealtimePlaybackTransportStateMachine.State.PAUSED &&
            holdEnd.transportState == VanguardRealtimePlaybackTransportStateMachine.State.PAUSED
    }

    // Shared by the two EOS scenarios (Y8a playthrough, Y8b dead object).
    private fun playthroughAccountingOk(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        stateAtCompletion: VanguardRealtimeAudioPlaybackSession.State,
    ): Boolean {
        val declared = final.format?.declaredFrameCount ?: return false
        val sink = final.sink ?: return false
        val reply = final.terminalReply
        return stateAtCompletion == VanguardRealtimeAudioPlaybackSession.State.COMPLETED &&
            sink.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS && sink.eosDrainedObserved &&
            sink.framesReadFromTransport == declared && sink.framesWrittenToSink == declared &&
            final.decoderExitReason == VanguardRealtimePlaybackDecoderFeed.EXIT_EOS && final.decoderAcceptedFrames == declared &&
            reply != null && reply.pushedFrames == declared && reply.drainedFrames == declared && reply.discardedFrames == 0L &&
            final.transportCompletedCallbacks == 1 && final.transportFailedCallbacks == 0 && final.failureReason.isBlank()
    }

    private fun checksumIdentityOk(final: VanguardRealtimeAudioPlaybackSession.Snapshot): Boolean {
        val sink = final.sink ?: return false
        val reply = final.terminalReply ?: return false
        return final.decoderChecksumHex.isNotBlank() &&
            final.decoderChecksumHex.equals(reply.pushedChecksumHex, ignoreCase = true) &&
            final.decoderChecksumHex.equals(reply.drainedChecksumHex, ignoreCase = true) &&
            final.decoderChecksumHex.equals(sink.checksumHex, ignoreCase = true)
    }

    // Y8b lanes: the ONE armed synthetic dead object was recovered on the
    // sink thread with a same-parameter instance, the clock epoch was
    // closed/reopened at baseFrame = frames written with a non-negative base
    // step whose decomposition (frames lost with the dead instance + clock
    // publication lag) holds, and exactly the unwritten
    // remainder landed on the replacement; the run then reached EOS with
    // full accounting and checksum identity, and the final release still
    // happened exactly once.
    private fun evaluateDeadObjectRecovery(
        final: VanguardRealtimeAudioPlaybackSession.Snapshot,
        afterRecovery: VanguardRealtimeAudioPlaybackSession.Snapshot,
        stateAtCompletion: VanguardRealtimeAudioPlaybackSession.State,
        config: SmokeConfig,
        out: ScenarioOutcome,
    ) {
        val fmt = final.format ?: return
        val sink = final.sink ?: return
        val clock = final.clock ?: return
        val arSink = afterRecovery.sink
        val arClock = afterRecovery.clock
        val declared = fmt.declaredFrameCount

        out.metrics["stateAtCompletion"] = stateAtCompletion.name
        out.metrics["afterRecoverySinkExitReason"] = arSink?.exitReason ?: "none"
        out.metrics["afterRecoveryFramesWritten"] = arSink?.framesWrittenToSink ?: -1L
        out.metrics["afterRecoveryClockEpochId"] = arClock?.epochId ?: -1
        out.metrics["afterRecoveryClockEpochOpen"] = arClock?.epochOpen ?: false
        out.metrics["afterRecoveryClockEpochBase"] = arClock?.epochBaseOffsetFrames ?: -1L
        out.metrics["afterRecoveryClockPosition"] = arClock?.positionFrames ?: -1L
        out.metrics["afterRecoveryClockTimestampSuccessCount"] = arClock?.timestampSuccessCount ?: -1L

        out.lanes[LANE_PLAYTHROUGH_ACCOUNTING] = playthroughAccountingOk(final, stateAtCompletion)
        out.lanes[LANE_CHECKSUM_IDENTITY] = checksumIdentityOk(final)
        out.lanes[LANE_DEAD_OBJECT_RECOVERY] = sink.syntheticDeadObjectInjectAfterFrames == config.deadObjectInjectAfterFrames &&
            sink.deadObjectInjectedCount == 1L && sink.deadObjectObservedCount == 1L && sink.deadObjectRecoveryCount == 1 &&
            sink.deadObjectOldTrackReleaseCount == 1 && sink.deadObjectRecoveryExecutedOnSinkThread &&
            sink.deadObjectNewTrackInitOk && sink.deadObjectNewTrackVolumeOk && sink.deadObjectNewTrackPlayOk &&
            sink.deadObjectNewTrackPlayState == AudioTrack.PLAYSTATE_PLAYING && sink.deadObjectNewTrackSameBuffer &&
            sink.deadObjectNewTrackBufferFrames == sink.audioTrackBufferFrames && sink.audioTrackBufferFrames > 0 &&
            sink.audioTracksCreated == 2 && sink.releaseCount == 1 && sink.gainValue == config.gain &&
            sink.deadObjectRecoveryWallMs >= 0L && sink.deadObjectTimestampPollsDuringRecovery == 0L &&
            sink.parkCount == 0 && sink.unparkCount == 0 && sink.audioTrackCallsOffSinkThread == 0L &&
            arSink != null && arSink.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_RUNNING &&
            arSink.deadObjectRecoveryCount == 1 && arSink.audioTracksCreated == 2 && arSink.releaseCount == 0 &&
            sink.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS && final.failureReason.isBlank()
        out.lanes[LANE_DEAD_OBJECT_CLOCK_EPOCH] = arClock != null &&
            sink.deadObjectEpochBeforeRecovery == 0 && sink.deadObjectEpochOpenedAfterRecovery == 1 &&
            sink.deadObjectEpochCloseAccepted && sink.deadObjectEpochOpenAccepted &&
            sink.clockSnapshotsAtDeadObjectRecovery == 1L && sink.clockSnapshotsAtPark == 0L &&
            sink.deadObjectPositionBeforeRecovery >= 0L &&
            sink.deadObjectBaseFrameAfterRecovery == sink.deadObjectFramesWrittenBeforeRecovery &&
            sink.deadObjectBaseStepFrames == sink.deadObjectBaseFrameAfterRecovery - sink.deadObjectPositionBeforeRecovery &&
            sink.deadObjectBaseStepFrames >= 0L && sink.deadObjectBaseStepBounded &&
            deadObjectBaseStepDecompositionOk(sink, config, fmt.sampleRate) &&
            arClock.epochId == 1 && arClock.epochBaseOffsetFrames == sink.deadObjectBaseFrameAfterRecovery &&
            arClock.positionFrames >= sink.deadObjectPositionBeforeRecovery &&
            clock.epochOpenCount == 2 && clock.epochCloseCount == 2 && clock.baseClampCount == 0L &&
            clock.timestampSuccessCount > arClock.timestampSuccessCount && clock.anchoredCount > arClock.anchoredCount &&
            clock.positionFrames >= sink.deadObjectBaseFrameAfterRecovery && !clock.epochOpen && clock.epochId == 1 &&
            sink.rebasedClampCount == 0L
        out.lanes[LANE_DEAD_OBJECT_REMAINDER] = sink.deadObjectRemainderAccountingOk &&
            sink.deadObjectSliceBytesAtRecovery > 0L &&
            sink.deadObjectUnwrittenBytesAtRecovery in 1L..sink.deadObjectSliceBytesAtRecovery &&
            sink.deadObjectBufferPositionAtRecovery >= 0L &&
            sink.deadObjectRemainderFramesExpected > 0L &&
            sink.deadObjectRemainderFramesExpected * 2L * fmt.channelCount == sink.deadObjectUnwrittenBytesAtRecovery &&
            sink.deadObjectRemainderFramesWrittenOnNewTrack == sink.deadObjectRemainderFramesExpected &&
            sink.deadObjectFramesWrittenBeforeRecovery >= config.deadObjectInjectAfterFrames &&
            sink.deadObjectFramesWrittenBeforeRecovery < declared &&
            sink.deadObjectFramesReadAtRecovery >= sink.deadObjectFramesWrittenBeforeRecovery &&
            sink.deadObjectFramesReadAtRecovery <= declared &&
            sink.framesWrittenToSink == declared && sink.framesReadFromTransport == declared
    }

    // Base-step decomposition (A-prime). With W = frames written before
    // recovery, H = content head consumed at the dead object, P = last
    // published position, B = track buffer frames, M = one mix window:
    //   step = W - P = (W - H) + (H - P).
    //   Loss bound: when H was readable, 0 <= W - H <= B + M (frames lost
    //     with the dead instance never exceed what could sit in its buffer
    //     plus one mix window) and the sink's own decomposition flag holds.
    //   Publication lag: if the clock was ANCHORED or EXTRAPOLATED at
    //     recovery, step <= B + M + framesFor(DEAD_OBJECT_PUBLICATION_LAG_BUDGET_MS);
    //     if RESET or STALE only the sign claim (step >= 0) is asserted and
    //     the values are reported.
    private fun deadObjectBaseStepDecompositionOk(
        sink: VanguardRealtimeAudioPlaybackSinkBridge.Telemetry,
        config: SmokeConfig,
        sampleRate: Int,
    ): Boolean {
        val w = sink.deadObjectFramesWrittenBeforeRecovery
        val h = sink.deadObjectContentHeadAtDeadObject
        val p = sink.deadObjectPositionBeforeRecovery
        val step = sink.deadObjectBaseStepFrames
        val lossBound = sink.audioTrackBufferFrames.toLong() + config.maxFramesPerMix.toLong()
        if (step < 0L || w < 0L || p < 0L) return false
        if (h >= 0L) {
            val lost = w - h
            if (lost !in 0L..lossBound) return false
            if (sink.deadObjectWrittenAheadOfHeadFrames != lost) return false
            if (sink.deadObjectPublicationLagFrames != h - p) return false
            if (!sink.deadObjectBaseStepDecompositionOk) return false
        }
        return when (sink.deadObjectClockProvenanceAtRecovery) {
            VanguardRealtimePlaybackPresentationClock.Provenance.ANCHORED.name,
            VanguardRealtimePlaybackPresentationClock.Provenance.EXTRAPOLATED.name,
            -> step <= lossBound + sampleRate.toLong() * DEAD_OBJECT_PUBLICATION_LAG_BUDGET_MS / 1_000L
            VanguardRealtimePlaybackPresentationClock.Provenance.RESET.name,
            VanguardRealtimePlaybackPresentationClock.Provenance.STALE.name,
            -> true
            else -> false
        }
    }

    // A lane holds only when every scenario that evaluated it passed and at
    // least one scenario evaluated it.
    private fun aggregateLanes(outcomes: List<ScenarioOutcome>): LinkedHashMap<String, Boolean> {
        val lanes = linkedMapOf<String, Boolean>()
        for (name in REQUIRED_LANES) {
            val evaluated = outcomes.filter { it.lanes.containsKey(name) }
            lanes[name] = evaluated.isNotEmpty() && evaluated.all { it.lanes[name] == true }
        }
        return lanes
    }

    // ── Metrics ────────────────────────────────────────────────────────────

    private fun snapshotMetrics(s: VanguardRealtimeAudioPlaybackSession.Snapshot): LinkedHashMap<String, Any?> {
        val m = linkedMapOf<String, Any?>()
        val fmt = s.format
        val k = s.sink
        val c = s.clock
        val r = s.terminalReply
        m["state"] = s.state.name
        m["generation"] = s.generation
        m["cancelled"] = s.cancelled
        m["sourceMime"] = fmt?.sourceMime ?: ""
        m["sampleRate"] = fmt?.sampleRate ?: 0
        m["channelCount"] = fmt?.channelCount ?: 0
        m["declaredFrameCount"] = fmt?.declaredFrameCount ?: 0L
        m["transportState"] = s.transportState?.name ?: "none"
        m["transportGeneration"] = s.transportGeneration
        m["transportTransitions"] = s.transportTransitions
        m["transportCompletedCallbacks"] = s.transportCompletedCallbacks
        m["transportFailedCallbacks"] = s.transportFailedCallbacks
        m["listenerCallbacksOnOwner"] = s.listenerCallbacksOnOwner
        m["listenerCallbacksOffOwner"] = s.listenerCallbacksOffOwner
        m["commandsIssued"] = s.commandsIssued
        m["prepareGeneration"] = s.prepareGeneration
        m["startGeneration"] = s.startGeneration
        m["pauseGeneration"] = s.pauseGeneration
        m["resumeGeneration"] = s.resumeGeneration
        m["startAccepted"] = s.startAccepted
        m["pauseAccepted"] = s.pauseAccepted
        m["resumeAccepted"] = s.resumeAccepted
        m["transportStopAccepted"] = s.transportStopAccepted
        m["transportStateBeforeDispose"] = s.transportStateBeforeDispose?.name ?: "none"
        m["transportStateAfterDispose"] = s.transportStateAfterDispose?.name ?: "none"
        m["transportDisposeCalls"] = s.transportDisposeCalls
        m["preRollFrames"] = s.preRollFrames
        m["preRollRingFullObserved"] = s.preRollRingFullObserved
        m["preRollStatePrepared"] = s.preRollStatePrepared
        m["sinkReadyBeforeTransportStart"] = s.sinkReadyBeforeTransportStart
        m["drainAllowedAfterTransportStart"] = s.drainAllowedAfterTransportStart
        m["pauseHoldObservedMs"] = s.pauseHoldObservedMs
        m["decoderExitReason"] = s.decoderExitReason
        m["decoderThreadId"] = s.decoderThreadId
        m["decoderAcceptedFrames"] = s.decoderAcceptedFrames
        m["decoderPaddedFrames"] = s.decoderPaddedFrames
        m["decoderChecksumHex"] = s.decoderChecksumHex
        m["decoderMediaReleaseCount"] = s.decoderMediaReleaseCount
        m["decoderMediaReleaseClean"] = s.decoderMediaReleaseClean
        m["decoderIngestCallbacksOnOwner"] = s.decoderIngestCallbacksOnOwner
        m["decoderIngestCallbacksOffOwner"] = s.decoderIngestCallbacksOffOwner
        m["decoderIngestCalls"] = s.decoderIngestCalls
        m["decoderCancelRequested"] = s.decoderCancelRequested
        m["decoderJoined"] = s.decoderJoined
        m["sinkJoined"] = s.sinkJoined
        m["sessionWallMs"] = s.sessionWallMs
        m["nativeStateFinal"] = r?.stateToken ?: "none"
        m["nativeEosDrained"] = r?.eosDrained ?: false
        m["nativePushedFrames"] = r?.pushedFrames ?: -1L
        m["nativeDrainedFrames"] = r?.drainedFrames ?: -1L
        m["nativeDiscardedFrames"] = r?.discardedFrames ?: -1L
        m["nativeUnderrunCount"] = r?.underrunCount ?: -1L
        m["nativePushedChecksumHex"] = r?.pushedChecksumHex ?: ""
        m["nativeDrainedChecksumHex"] = r?.drainedChecksumHex ?: ""
        m["nativeLastError"] = r?.lastError ?: "none"
        if (k != null) {
            m["sinkPhase"] = k.phase.name
            m["sinkExitReason"] = k.exitReason
            m["sinkThreadId"] = k.threadId
            m["sinkClockWriterBoundOnSinkThread"] = k.clockWriterBoundOnSinkThread
            m["audioTrackInitOk"] = k.audioTrackInitOk
            m["gainSetOk"] = k.gainSetOk
            m["gainValue"] = k.gainValue.toDouble()
            m["audioTrackBufferBytes"] = k.audioTrackBufferBytes
            m["audioTracksCreated"] = k.audioTracksCreated
            m["audioTrackReleaseCount"] = k.releaseCount
            m["audioTrackReleaseExecutedOnSinkThread"] = k.releaseExecutedOnSinkThread
            m["audioTrackCallsOffSinkThread"] = k.audioTrackCallsOffSinkThread
            m["sinkPlayed"] = k.played
            m["sinkInitialPlayState"] = k.initialPlayState
            m["framesReadFromTransport"] = k.framesReadFromTransport
            m["framesWrittenToSink"] = k.framesWrittenToSink
            m["partialWriteCount"] = k.partialWriteCount
            m["zeroWriteCount"] = k.zeroWriteCount
            m["drainCalls"] = k.drainCalls
            m["drainCallsBeforeAllow"] = k.drainCallsBeforeAllow
            m["emptyDrainCount"] = k.emptyDrainCount
            m["productiveDrainPasses"] = k.productiveDrainPasses
            m["eosDrainedObserved"] = k.eosDrainedObserved
            m["timestampPollAttempts"] = k.timestampPollAttempts
            m["timestampPollSuccesses"] = k.timestampPollSuccesses
            m["timestampPollUnavailable"] = k.timestampPollUnavailable
            m["timestampPollsWhileParked"] = k.timestampPollsWhileParked
            m["timestampMaxPollsInOnePass"] = k.timestampMaxPollsInOnePass
            m["sinkClockEpochOpenCalls"] = k.clockEpochOpenCalls
            m["sinkClockEpochCloseCalls"] = k.clockEpochCloseCalls
            m["sinkClockRejectedCount"] = k.clockRejectedCount
            m["sinkClockSnapshotsAtPark"] = k.clockSnapshotsAtPark
            m["sinkRebasedClampCount"] = k.rebasedClampCount
            m["sinkParkCount"] = k.parkCount
            m["sinkUnparkCount"] = k.unparkCount
            m["sinkPlayStateAtPark"] = k.playStateAtPark
            m["sinkPlayStateAfterUnpark"] = k.playStateAfterUnpark
            m["sinkParkedPlayStateViolations"] = k.parkedPlayStateViolations
            m["sinkPositionAtPark"] = k.positionAtPark
            m["sinkEpochClosedAtPark"] = k.epochClosedAtPark
            m["sinkEpochOpenedAtUnpark"] = k.epochOpenedAtUnpark
            m["sinkParkAckLatencyMs"] = k.parkAckLatencyMs
            m["sinkParkedHoldMs"] = k.parkedHoldMs
            m["playbackHeadAtPark"] = k.playbackHeadAtPark
            m["playbackHeadAtUnpark"] = k.playbackHeadAtUnpark
            m["playbackHeadFinal"] = k.playbackHeadFinal
            m["sinkThreadWallMs"] = k.sinkThreadWallMs
            m["sinkChecksumHex"] = k.checksumHex
            m["audioTrackBufferFrames"] = k.audioTrackBufferFrames
            m["syntheticDeadObjectInjectAfterFrames"] = k.syntheticDeadObjectInjectAfterFrames
            m["deadObjectInjectedCount"] = k.deadObjectInjectedCount
            m["deadObjectObservedCount"] = k.deadObjectObservedCount
            m["deadObjectRecoveryCount"] = k.deadObjectRecoveryCount
            m["deadObjectOldTrackReleaseCount"] = k.deadObjectOldTrackReleaseCount
            m["deadObjectRecoveryExecutedOnSinkThread"] = k.deadObjectRecoveryExecutedOnSinkThread
            m["deadObjectNewTrackInitOk"] = k.deadObjectNewTrackInitOk
            m["deadObjectNewTrackVolumeOk"] = k.deadObjectNewTrackVolumeOk
            m["deadObjectNewTrackPlayOk"] = k.deadObjectNewTrackPlayOk
            m["deadObjectNewTrackPlayState"] = k.deadObjectNewTrackPlayState
            m["deadObjectNewTrackSameBuffer"] = k.deadObjectNewTrackSameBuffer
            m["deadObjectNewTrackBufferFrames"] = k.deadObjectNewTrackBufferFrames
            m["deadObjectRecoveryWallMs"] = k.deadObjectRecoveryWallMs
            m["deadObjectEpochBeforeRecovery"] = k.deadObjectEpochBeforeRecovery
            m["deadObjectEpochOpenedAfterRecovery"] = k.deadObjectEpochOpenedAfterRecovery
            m["deadObjectEpochCloseAccepted"] = k.deadObjectEpochCloseAccepted
            m["deadObjectEpochOpenAccepted"] = k.deadObjectEpochOpenAccepted
            m["deadObjectPositionBeforeRecovery"] = k.deadObjectPositionBeforeRecovery
            m["deadObjectBaseFrameAfterRecovery"] = k.deadObjectBaseFrameAfterRecovery
            m["deadObjectBaseStepFrames"] = k.deadObjectBaseStepFrames
            m["deadObjectBaseStepBounded"] = k.deadObjectBaseStepBounded
            m["deadObjectContentHeadAtDeadObject"] = k.deadObjectContentHeadAtDeadObject
            m["deadObjectWrittenAheadOfHeadFrames"] = k.deadObjectWrittenAheadOfHeadFrames
            m["deadObjectPublicationLagFrames"] = k.deadObjectPublicationLagFrames
            m["deadObjectBaseStepDecompositionOk"] = k.deadObjectBaseStepDecompositionOk
            m["deadObjectClockProvenanceAtRecovery"] = k.deadObjectClockProvenanceAtRecovery
            m["deadObjectClockLastAgeNsAtRecovery"] = k.deadObjectClockLastAgeNsAtRecovery
            m["deadObjectSliceBytesAtRecovery"] = k.deadObjectSliceBytesAtRecovery
            m["deadObjectUnwrittenBytesAtRecovery"] = k.deadObjectUnwrittenBytesAtRecovery
            m["deadObjectBufferPositionAtRecovery"] = k.deadObjectBufferPositionAtRecovery
            m["deadObjectFramesReadAtRecovery"] = k.deadObjectFramesReadAtRecovery
            m["deadObjectFramesWrittenBeforeRecovery"] = k.deadObjectFramesWrittenBeforeRecovery
            m["deadObjectRemainderFramesExpected"] = k.deadObjectRemainderFramesExpected
            m["deadObjectRemainderFramesWrittenOnNewTrack"] = k.deadObjectRemainderFramesWrittenOnNewTrack
            m["deadObjectRemainderAccountingOk"] = k.deadObjectRemainderAccountingOk
            m["deadObjectTimestampPollsDuringRecovery"] = k.deadObjectTimestampPollsDuringRecovery
            m["sinkClockSnapshotsAtDeadObjectRecovery"] = k.clockSnapshotsAtDeadObjectRecovery
            m["playbackHeadAtDeadObject"] = k.playbackHeadAtDeadObject
        }
        if (c != null) {
            m["clockConsistent"] = c.consistent
            m["clockProvenance"] = c.provenance.name
            m["clockEpochId"] = c.epochId
            m["clockEpochOpen"] = c.epochOpen
            m["clockEpochBaseOffsetFrames"] = c.epochBaseOffsetFrames
            m["clockPositionFrames"] = c.positionFrames
            m["clockPositionUs"] = c.positionUs
            m["clockFaulted"] = c.faulted
            m["clockLastOutcome"] = c.lastOutcome.name
            m["clockUpdateCount"] = c.updateCount
            m["clockTimestampSuccessCount"] = c.timestampSuccessCount
            m["clockTimestampUnavailableCount"] = c.timestampUnavailableCount
            m["clockAnchoredCount"] = c.anchoredCount
            m["clockExtrapolatedCount"] = c.extrapolatedCount
            m["clockStaleCount"] = c.staleCount
            m["clockNoAnchorCount"] = c.noAnchorCount
            m["clockEpochOpenCount"] = c.epochOpenCount
            m["clockEpochCloseCount"] = c.epochCloseCount
            m["clockWrapCount"] = c.wrapCount
            m["clockRegressionCount"] = c.regressionCount
            m["clockRejectedCount"] = c.rejectedCount
            m["clockAnchorClampCount"] = c.anchorClampCount
            m["clockBaseClampCount"] = c.baseClampCount
            m["clockMonotonicViolationCount"] = c.monotonicViolationCount
            m["clockOffWriterThreadCalls"] = c.offWriterThreadCalls
            m["clockSnapshotCallsFromWriterThread"] = c.snapshotCallsFromWriterThread
            m["clockWriterThreadId"] = c.writerThreadId
        }
        s.clockAtPauseAck?.let { m["clockPositionAtPauseAck"] = it.positionFrames; m["clockUpdateCountAtPauseAck"] = it.updateCount }
        s.clockBeforeResume?.let { m["clockPositionBeforeResume"] = it.positionFrames; m["clockUpdateCountBeforeResume"] = it.updateCount }
        s.clockAfterResume?.let {
            m["clockEpochIdAfterResume"] = it.epochId
            m["clockEpochBaseAfterResume"] = it.epochBaseOffsetFrames
            m["clockPositionAfterResume"] = it.positionFrames
        }
        return m
    }

    // ── Reporting ──────────────────────────────────────────────────────────

    private fun buildPayload(
        pass: Boolean,
        failureReason: String,
        outcomes: List<ScenarioOutcome>,
        metrics: LinkedHashMap<String, Any?>,
    ): Map<String, Any?> {
        val lanes = if (outcomes.isEmpty()) emptyLanes() else aggregateLanes(outcomes)
        lanes[LANE_CANONICAL] = pass
        val marker = if (pass) PASS_MARKER else FAIL_MARKER
        val reason = if (pass) "" else failureReason.ifBlank { "smoke_failed" }
        val metricMap = LinkedHashMap<String, Any?>(metrics)
        for (o in outcomes) {
            metricMap[o.name] = LinkedHashMap<String, Any?>(o.metrics)
            metricMap["${o.name}_lanes"] = LinkedHashMap<String, Any?>(o.lanes)
        }
        metricMap["failureReason"] = reason
        return mapOf(
            "pass" to pass,
            "status" to if (pass) "pass" else "fail",
            "marker" to marker,
            "proofBoundary" to PROOF_BOUNDARY,
            "nativeProofBoundary" to PROOF_BOUNDARY,
            "failureReason" to reason,
            "details" to "Y8a/Y8b realtime audio playback production sink/clock/dead-object smoke pass=$pass scenarios=${outcomes.joinToString(",") { it.name }}",
            "lanes" to lanes,
            "metrics" to metricMap,
            "lastError" to if (pass) null else reason,
            "raw" to "pass=$pass;status=${if (pass) "pass" else "fail"};failureReason=$reason;marker=$marker",
        )
    }

    private fun emptyLanes(): LinkedHashMap<String, Boolean> {
        val lanes = linkedMapOf<String, Boolean>()
        for (name in REQUIRED_LANES) lanes[name] = false
        return lanes
    }

    private fun buildFailurePayload(reason: String): Map<String, Any?> =
        buildPayload(false, reason, emptyList(), linkedMapOf("failureReason" to reason))

    private fun logOutcome(payload: Map<String, Any?>) {
        try {
            val lanes = payload["lanes"] as? Map<*, *>
            val laneText = lanes?.entries?.joinToString(",") { "\"${it.key}\":${it.value}" } ?: ""
            Log.i(
                TAG,
                "$JSON_MARKER {\"pass\":${payload["pass"]},\"status\":\"${payload["status"]}\"," +
                    "\"failureReason\":\"${payload["failureReason"]}\",\"lanes\":{$laneText}}",
            )
            Log.i(TAG, payload["marker"]?.toString() ?: FAIL_MARKER)
        } catch (_: Throwable) {}
    }

    private fun postReply(replied: AtomicBoolean, result: MethodChannel.Result, payload: Map<String, Any?>) {
        if (disposed.get() || !replied.compareAndSet(false, true)) return
        mainHandler.post {
            if (disposed.get()) return@post
            try {
                result.success(payload)
            } catch (t: Throwable) {
                Log.w(TAG, "$METHOD_NAME reply dropped: ${t.javaClass.simpleName}")
            }
        }
    }
}
