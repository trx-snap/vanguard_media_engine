package com.connects.vanguard_media_engine.diagnostics

import android.content.Context
import android.media.AudioTrack
import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackAudioFocusController
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackFocusResponseSink
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-REALTIME-PLAYBACK-FOCUS-RESPONSE (Y4a):
 * verification smoke coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for validating the production
 * [VanguardRealtimePlaybackFocusResponseSink] adapter driven by the
 * authoritative Kotlin transport state machine
 * ([VanguardRealtimePlaybackTransportStateMachine]) and one
 * [VanguardRealtimePlaybackAudioFocusController] per run:
 * - Sample rate = 48000, channel count = 2, maxFramesPerMix = 256,
 *   track count = 2, declaredFrameCount = 12000, phaseFrames = 2048,
 *   pauseHoldMs = 150, base gain 0.5, duck gain 0.1, deadlineMs = 20000.
 * - Three sequential scenarios, each with a fresh state machine and focus
 *   controller (focus requested/abandoned and receiver registered/
 *   unregistered once per scenario). Every scenario shares the same head:
 *   duck/restore, transient pause (+duplicate no-op) / gain resume.
 *   1. EOS_COMPLETION: the normal no-fault EOS path: transport COMPLETED,
 *      full checksum identity, exact declaredFrameCount accounting.
 *   2. BECOMING_NOISY_TERMINAL: becoming-noisy while PLAYING ->
 *      transport.pause() then AudioTrack.pause(); gated on transport
 *      PAUSED at tail end, autoResumeAllowed=false, frozen hold, prefix
 *      checksum identity, single teardown stop (no permanent loss).
 *   3. PERMANENT_LOSS_TERMINAL: AUDIOFOCUS_LOSS while transport and
 *      AudioTrack are PLAYING -> AudioTrack.pause() then transport.stop();
 *      gated on transport STOPPED, autoResumeAllowed=false, prefix checksum
 *      identity, and a later AUDIOFOCUS_GAIN recorded/rejected with no
 *      resume/play/transport command (no becoming-noisy).
 * - Coordinator dispose only flips the cancel flag and disposes the active
 *   state machine; the sink's finally owns receiver/focus/AudioTrack
 *   teardown.
 *
 * Proof boundary non-claims:
 * realtime playback focus/noisy response diagnostic only, nonzero-gain
 * AudioTrack sink, Y1 transport, no MediaCodec/MediaExtractor, no
 * route-change, no dead-object recovery, no presentation clock, no A/V sync,
 * no OS focus arbitration correctness claim, no audible output claim, no
 * product/editor/app wiring, no iOS, no native C++ changes.
 */
class AndroidRealtimePlaybackFocusResponseSmokeCoordinator(
    private val context: Context,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardY4aFocusResponse"
        const val METHOD_NAME = "runRealtimePlaybackFocusResponseSmoke"

        const val PASS_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_PHYSICAL_SMOKE_PASS"
        const val FAIL_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_PHYSICAL_SMOKE_FAIL"
        const val START_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_SMOKE_START"
        const val JSON_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_JSON"

        const val PROOF_BOUNDARY =
            VanguardRealtimePlaybackFocusResponseSink.PROOF_BOUNDARY

        private const val SAMPLE_RATE = 48000
        private const val CHANNEL_COUNT = 2
        private const val MAX_FRAMES_PER_MIX = 256
        private const val TRACK_COUNT = 2
        private const val DECLARED_FRAME_COUNT = 12000L
        private const val PHASE_FRAMES = 2048L
        private const val PAUSE_HOLD_MS = 150L
        private const val EVENT_AWAIT_MS = 2000L
        private const val DEADLINE_MS = 20000L

        private val LANE_NAMES = listOf(
            "focusGrantedOk",
            "noisyReceiverRegisteredOk",
            "baseGainSetOk",
            "duckAppliedOk",
            "duckRestoreOk",
            "transientPauseResumeOk",
            "becomingNoisyPauseOk",
            "permanentStopNoAutoResumeOk",
            "transportStoppedOk",
            "transportCompletedOk",
            "checksumIdentityOk",
            "sinkWriteAccountingOk",
            "audioTrackReleasedOk",
            "focusAbandonedOk",
            "receiverUnregisteredOk",
            "eventsDroppedZeroOk",
            "lifecycleOk",
            "eosScenarioPass",
            "noisyTerminalScenarioPass",
            "permanentTerminalScenarioPass",
            "allNativeLanesPass",
        )

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val active = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)

    @Volatile
    private var activeStateMachine: VanguardRealtimePlaybackTransportStateMachine? = null

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        if (method != METHOD_NAME) return false

        if (disposed.get()) {
            Log.w(TAG, "$METHOD_NAME rejected: coordinator disposed")
            replyDirect(result, buildFailurePayload("coordinator_disposed"))
            return true
        }

        if (!active.compareAndSet(false, true)) {
            Log.w(TAG, "$METHOD_NAME rejected: diagnostic already running")
            replyDirect(result, buildFailurePayload("busy"))
            return true
        }

        runSmoke(result)
        return true
    }

    // Only flips cancel and disposes the active state machine; an in-flight
    // sink observes the cancel / disposed transport, fails closed, and tears
    // down its own AudioTrack, receiver and focus in its finally block.
    fun disposeAll() {
        disposed.set(true)
        try {
            activeStateMachine?.dispose()
        } catch (_: Throwable) {}
        activeStateMachine = null
    }

    private fun replyDirect(result: MethodChannel.Result, payload: Map<String, Any?>) {
        try {
            result.success(payload)
        } catch (t: Throwable) {
            Log.w(TAG, "$METHOD_NAME reply dropped: ${t.javaClass.simpleName}")
        }
    }

    private fun runSmoke(result: MethodChannel.Result) {
        val replied = AtomicBoolean(false)
        Thread({
            try {
                Log.i(TAG, START_MARKER)
                val payload = executeSmoke()
                logOutcome(payload)
                postReply(replied, result, payload)
            } catch (t: Throwable) {
                Log.e(TAG, "$METHOD_NAME uncaught failure", t)
                val failPayload = buildFailurePayload(
                    "uncaught_exception:${t.javaClass.simpleName}:${t.message}"
                )
                logOutcome(failPayload)
                postReply(replied, result, failPayload)
            } finally {
                active.set(false)
            }
        }, "Y4aFocusResponseSmoke").start()
    }

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

    private fun postReply(
        replied: AtomicBoolean,
        result: MethodChannel.Result,
        payload: Map<String, Any?>,
    ) {
        if (disposed.get() || !replied.compareAndSet(false, true)) return
        mainHandler.post {
            if (disposed.get()) return@post
            replyDirect(result, payload)
        }
    }

    private fun runScenario(
        scenario: VanguardRealtimePlaybackFocusResponseSink.Scenario,
    ): VanguardRealtimePlaybackFocusResponseSink.Result? {
        if (disposed.get()) return null
        var sm: VanguardRealtimePlaybackTransportStateMachine? = null
        try {
            val config = VanguardRealtimePlaybackNativeSession.Config(
                sampleRate = SAMPLE_RATE,
                channelCount = CHANNEL_COUNT,
                maxFramesPerMix = MAX_FRAMES_PER_MIX,
                trackCount = TRACK_COUNT,
                declaredFrameCount = DECLARED_FRAME_COUNT,
            )
            sm = VanguardRealtimePlaybackTransportStateMachine(
                config = config,
                threadName = "Y4aFocusResponseSmokeSM_${scenario.name.lowercase()}",
            )
            activeStateMachine = sm
            if (disposed.get()) return null

            val controller = VanguardRealtimePlaybackAudioFocusController(
                context = context,
                mainHandler = mainHandler,
            )
            val sink = VanguardRealtimePlaybackFocusResponseSink()
            val sinkConfig = VanguardRealtimePlaybackFocusResponseSink.Config(
                stateMachine = sm,
                focusController = controller,
                scenario = scenario,
                sampleRate = SAMPLE_RATE,
                channelCount = CHANNEL_COUNT,
                maxFramesPerMix = MAX_FRAMES_PER_MIX,
                declaredFrameCount = DECLARED_FRAME_COUNT,
                phaseFrames = PHASE_FRAMES,
                pauseHoldMs = PAUSE_HOLD_MS,
                baseGain = VanguardRealtimePlaybackFocusResponseSink.BASE_GAIN,
                duckGain = VanguardRealtimePlaybackFocusResponseSink.DUCK_GAIN,
                eventAwaitMs = EVENT_AWAIT_MS,
                deadlineMs = DEADLINE_MS,
                cancelled = { disposed.get() },
            )
            return sink.run(sinkConfig)
        } finally {
            try {
                sm?.dispose()
            } catch (_: Throwable) {}
            activeStateMachine = null
        }
    }

    private fun executeSmoke(): Map<String, Any?> {
        try {
            val eos = runScenario(
                VanguardRealtimePlaybackFocusResponseSink.Scenario.EOS_COMPLETION,
            ) ?: return buildFailurePayload("coordinator_disposed_before_eos_scenario")
            val noisy = runScenario(
                VanguardRealtimePlaybackFocusResponseSink.Scenario.BECOMING_NOISY_TERMINAL,
            ) ?: return buildFailurePayload("coordinator_disposed_before_noisy_terminal_scenario")
            val permanent = runScenario(
                VanguardRealtimePlaybackFocusResponseSink.Scenario.PERMANENT_LOSS_TERMINAL,
            ) ?: return buildFailurePayload("coordinator_disposed_before_permanent_terminal_scenario")

            val all = listOf(eos, noisy, permanent)
            val em = eos.metrics
            val nm = noisy.metrics
            val pm = permanent.metrics

            // Gates shared by every scenario: sink pass, proof boundary,
            // shared head lanes, checksum identity, write accounting, single
            // AudioTrack release, single focus abandon, single receiver
            // unregister, zero drops, lifecycle.
            fun commonGates(r: VanguardRealtimePlaybackFocusResponseSink.Result): Boolean =
                r.pass &&
                    r.proofBoundary == PROOF_BOUNDARY &&
                    r.focusGrantedOk &&
                    r.noisyReceiverRegisteredOk &&
                    r.baseGainSetOk &&
                    r.duckAppliedOk &&
                    r.duckRestoreOk &&
                    r.transientPauseResumeOk &&
                    r.checksumIdentityOk &&
                    r.sinkWriteAccountingOk &&
                    r.audioTrackReleasedOk &&
                    r.focusAbandonedOk &&
                    r.receiverUnregisteredOk &&
                    r.lifecycleOk &&
                    r.eventsDropped == 0L &&
                    r.releaseCount == 1 &&
                    r.focusAbandonCount == 1 &&
                    r.receiverUnregisterCount == 1 &&
                    r.kotlinSinkChecksumHex.isNotEmpty() &&
                    r.kotlinSinkChecksumHex.equals(r.nativeChecksumHex, ignoreCase = true) &&
                    r.framesReadFromTransport == r.framesWrittenToSink

            val eosScenarioPass = commonGates(eos) &&
                eos.scenario == VanguardRealtimePlaybackFocusResponseSink.Scenario.EOS_COMPLETION &&
                eos.transportCompletedOk &&
                !eos.transportStoppedOk &&
                !eos.becomingNoisyPauseOk &&
                !eos.permanentStopNoAutoResumeOk &&
                eos.autoResumeAllowed &&
                eos.framesReadFromTransport == DECLARED_FRAME_COUNT &&
                eos.framesWrittenToSink == DECLARED_FRAME_COUNT &&
                (em["noisyPauseAppliedCount"] as? Long) == 0L &&
                (em["permanentStopAppliedCount"] as? Long) == 0L &&
                (em["gainAttemptRejectedCount"] as? Long) == 0L &&
                (em["transportStateAtTailEnd"] as? String) == "COMPLETED" &&
                (em["transportState"] as? String) == "COMPLETED"

            // Becoming-noisy terminal: PAUSED at tail end (transport.pause()
            // then AudioTrack.pause()), autoResumeAllowed=false, frozen hold,
            // prefix checksum identity, no permanent loss applied, and the
            // still-PAUSED transport stopped exactly once by teardown.
            val noisyTerminalScenarioPass = commonGates(noisy) &&
                noisy.scenario == VanguardRealtimePlaybackFocusResponseSink.Scenario.BECOMING_NOISY_TERMINAL &&
                noisy.becomingNoisyPauseOk &&
                !noisy.autoResumeAllowed &&
                !noisy.transportCompletedOk &&
                !noisy.transportStoppedOk &&
                !noisy.permanentStopNoAutoResumeOk &&
                (noisy.lanes["noisyHoldFrozenOk"] as? Boolean) == true &&
                (nm["noisyPauseAppliedCount"] as? Long) == 1L &&
                (nm["noisyDuplicateNoOpCount"] as? Long) == 0L &&
                (nm["permanentStopAppliedCount"] as? Long) == 0L &&
                (nm["gainAttemptRejectedCount"] as? Long) == 0L &&
                (nm["noisyHoldDispatchDelta"] as? Long) == 0L &&
                (nm["noisyHoldPushedDelta"] as? Long) == 0L &&
                (nm["transportStateAtTailEnd"] as? String) == "PAUSED" &&
                (nm["sinkPlayStateAtTailEnd"] as? Int) == AudioTrack.PLAYSTATE_PAUSED &&
                (nm["transportStopCalled"] as? Boolean) == true &&
                (nm["transportStopAccepted"] as? Boolean) == true &&
                (nm["transportState"] as? String) == "STOPPED" &&
                noisy.framesReadFromTransport < DECLARED_FRAME_COUNT

            // Permanent-loss terminal: injected while PLAYING, AudioTrack
            // paused then transport STOPPED, autoResumeAllowed=false, prefix
            // checksum identity, later gain recorded/rejected with no
            // resume/play/command, no becoming-noisy applied.
            val permanentTerminalScenarioPass = commonGates(permanent) &&
                permanent.scenario == VanguardRealtimePlaybackFocusResponseSink.Scenario.PERMANENT_LOSS_TERMINAL &&
                permanent.permanentStopNoAutoResumeOk &&
                permanent.transportStoppedOk &&
                !permanent.autoResumeAllowed &&
                !permanent.transportCompletedOk &&
                !permanent.becomingNoisyPauseOk &&
                (permanent.lanes["permanentStopOk"] as? Boolean) == true &&
                (permanent.lanes["gainAttemptRejectedOk"] as? Boolean) == true &&
                (pm["permanentStopAppliedCount"] as? Long) == 1L &&
                (pm["gainAttemptRejectedCount"] as? Long) == 1L &&
                (pm["focusGainResumeAppliedCount"] as? Long) == 1L &&
                (pm["noisyPauseAppliedCount"] as? Long) == 0L &&
                (pm["noisyDuplicateNoOpCount"] as? Long) == 0L &&
                (pm["transportStateAtTailEnd"] as? String) == "STOPPED" &&
                (pm["sinkPlayStateAtTailEnd"] as? Int) == AudioTrack.PLAYSTATE_PAUSED &&
                (pm["transportStopCalled"] as? Boolean) == true &&
                (pm["transportStopAccepted"] as? Boolean) == true &&
                (pm["transportState"] as? String) == "STOPPED" &&
                permanent.framesReadFromTransport < DECLARED_FRAME_COUNT

            val focusGrantedOk = all.all { it.focusGrantedOk }
            val noisyReceiverRegisteredOk = all.all { it.noisyReceiverRegisteredOk }
            val baseGainSetOk = all.all { it.baseGainSetOk }
            val duckAppliedOk = all.all { it.duckAppliedOk }
            val duckRestoreOk = all.all { it.duckRestoreOk }
            val transientPauseResumeOk = all.all { it.transientPauseResumeOk }
            val becomingNoisyPauseOk = noisy.becomingNoisyPauseOk
            val permanentStopNoAutoResumeOk = permanent.permanentStopNoAutoResumeOk
            val transportStoppedOk = permanent.transportStoppedOk
            val transportCompletedOk = eos.transportCompletedOk
            val checksumIdentityOk = all.all { it.checksumIdentityOk }
            val sinkWriteAccountingOk = all.all { it.sinkWriteAccountingOk }
            val audioTrackReleasedOk = all.all { it.audioTrackReleasedOk && it.releaseCount == 1 }
            val focusAbandonedOk = all.all { it.focusAbandonedOk && it.focusAbandonCount == 1 }
            val receiverUnregisteredOk = all.all { it.receiverUnregisteredOk && it.receiverUnregisterCount == 1 }
            val eventsDroppedZeroOk = all.all { it.eventsDropped == 0L }
            val lifecycleOk = all.all { it.lifecycleOk }

            val allNativeLanesPass = eosScenarioPass &&
                noisyTerminalScenarioPass &&
                permanentTerminalScenarioPass &&
                focusGrantedOk &&
                noisyReceiverRegisteredOk &&
                baseGainSetOk &&
                duckAppliedOk &&
                duckRestoreOk &&
                transientPauseResumeOk &&
                becomingNoisyPauseOk &&
                permanentStopNoAutoResumeOk &&
                transportStoppedOk &&
                transportCompletedOk &&
                checksumIdentityOk &&
                sinkWriteAccountingOk &&
                audioTrackReleasedOk &&
                focusAbandonedOk &&
                receiverUnregisteredOk &&
                eventsDroppedZeroOk &&
                lifecycleOk
            val pass = allNativeLanesPass

            val lanes = linkedMapOf<String, Any?>(
                "focusGrantedOk" to focusGrantedOk,
                "noisyReceiverRegisteredOk" to noisyReceiverRegisteredOk,
                "baseGainSetOk" to baseGainSetOk,
                "duckAppliedOk" to duckAppliedOk,
                "duckRestoreOk" to duckRestoreOk,
                "transientPauseResumeOk" to transientPauseResumeOk,
                "becomingNoisyPauseOk" to becomingNoisyPauseOk,
                "permanentStopNoAutoResumeOk" to permanentStopNoAutoResumeOk,
                "transportStoppedOk" to transportStoppedOk,
                "transportCompletedOk" to transportCompletedOk,
                "checksumIdentityOk" to checksumIdentityOk,
                "sinkWriteAccountingOk" to sinkWriteAccountingOk,
                "audioTrackReleasedOk" to audioTrackReleasedOk,
                "focusAbandonedOk" to focusAbandonedOk,
                "receiverUnregisteredOk" to receiverUnregisteredOk,
                "eventsDroppedZeroOk" to eventsDroppedZeroOk,
                "lifecycleOk" to lifecycleOk,
                "eosScenarioPass" to eosScenarioPass,
                "noisyTerminalScenarioPass" to noisyTerminalScenarioPass,
                "permanentTerminalScenarioPass" to permanentTerminalScenarioPass,
                "allNativeLanesPass" to allNativeLanesPass,
                "canonical" to pass,
            )

            val metrics = linkedMapOf<String, Any?>(
                "sampleRate" to SAMPLE_RATE,
                "channelCount" to CHANNEL_COUNT,
                "maxFramesPerMix" to MAX_FRAMES_PER_MIX,
                "trackCount" to TRACK_COUNT,
                "declaredFrameCount" to DECLARED_FRAME_COUNT,
                "phaseFrames" to PHASE_FRAMES,
                "pauseHoldMs" to PAUSE_HOLD_MS,
                "eventAwaitMs" to EVENT_AWAIT_MS,
                "baseGain" to VanguardRealtimePlaybackFocusResponseSink.BASE_GAIN,
                "duckGain" to VanguardRealtimePlaybackFocusResponseSink.DUCK_GAIN,
                "scenarioOrder" to all.map { it.scenario.name },
                // Auto-resume flag at return, per scenario.
                "eosAutoResumeAllowed" to eos.autoResumeAllowed,
                "noisyAutoResumeAllowed" to noisy.autoResumeAllowed,
                "permanentAutoResumeAllowed" to permanent.autoResumeAllowed,
                // Becoming-noisy terminal scenario seq / order / count telemetry.
                "noisyDuckApplySeq" to nm["duckApplySeq"],
                "noisyRestoreApplySeq" to nm["restoreApplySeq"],
                "noisyTransientPauseApplySeq" to nm["transientPauseApplySeq"],
                "noisyDuplicateTransientApplySeq" to nm["duplicateTransientApplySeq"],
                "noisyFocusGainResumeApplySeq" to nm["focusGainResumeApplySeq"],
                "noisyPauseApplySeq" to nm["noisyPauseApplySeq"],
                "noisyPauseApplyOrder" to nm["noisyPauseApplyOrder"],
                "noisyPauseAppliedCount" to nm["noisyPauseAppliedCount"],
                "noisyDuplicateNoOpCount" to nm["noisyDuplicateNoOpCount"],
                "noisyHoldDispatchDelta" to nm["noisyHoldDispatchDelta"],
                "noisyHoldPushedDelta" to nm["noisyHoldPushedDelta"],
                "noisyPlaybackHeadAtNoisyPause" to nm["playbackHeadAtNoisyPause"],
                "noisyTransportStateAtTailEnd" to nm["transportStateAtTailEnd"],
                "noisyNativeStateAtTailEnd" to nm["nativeStateAtTailEnd"],
                "noisySinkPlayStateAtTailEnd" to nm["sinkPlayStateAtTailEnd"],
                "noisyTransportStopCalled" to nm["transportStopCalled"],
                "noisyTransportStopAccepted" to nm["transportStopAccepted"],
                "noisyTransportState" to nm["transportState"],
                "noisyFramesReadFromTransport" to noisy.framesReadFromTransport,
                "noisyFramesWrittenToSink" to noisy.framesWrittenToSink,
                "noisyKotlinSinkChecksumHex" to noisy.kotlinSinkChecksumHex,
                "noisyNativeChecksumHex" to noisy.nativeChecksumHex,
                "noisyEventsEnqueued" to noisy.eventsEnqueued,
                "noisyEventsDrained" to noisy.eventsDrained,
                "noisyEventsDropped" to noisy.eventsDropped,
                "noisyRealFocusCallbackCount" to nm["focus_realFocusCallbackCount"],
                "noisyRealNoisyBroadcastCount" to nm["focus_realNoisyBroadcastCount"],
                "noisyReleaseCount" to noisy.releaseCount,
                "noisyFocusAbandonCount" to noisy.focusAbandonCount,
                "noisyReceiverUnregisterCount" to noisy.receiverUnregisterCount,
                // Permanent-loss terminal scenario seq / order / count telemetry.
                "permanentDuckApplySeq" to pm["duckApplySeq"],
                "permanentRestoreApplySeq" to pm["restoreApplySeq"],
                "permanentTransientPauseApplySeq" to pm["transientPauseApplySeq"],
                "permanentDuplicateTransientApplySeq" to pm["duplicateTransientApplySeq"],
                "permanentFocusGainResumeApplySeq" to pm["focusGainResumeApplySeq"],
                "permanentStopApplySeq" to pm["permanentStopApplySeq"],
                "permanentStopApplyOrder" to pm["permanentStopApplyOrder"],
                "permanentGainAttemptApplySeq" to pm["gainAttemptApplySeq"],
                "permanentGainAttemptApplyOrder" to pm["gainAttemptApplyOrder"],
                "permanentStopAppliedCount" to pm["permanentStopAppliedCount"],
                "permanentGainAttemptRejectedCount" to pm["gainAttemptRejectedCount"],
                "permanentFocusGainResumeAppliedCount" to pm["focusGainResumeAppliedCount"],
                "permanentTransportCommandAttempts" to pm["transportCommandAttempts"],
                "permanentPlaybackHeadAtPermanentStop" to pm["playbackHeadAtPermanentStop"],
                "permanentTransportStateAtTailEnd" to pm["transportStateAtTailEnd"],
                "permanentNativeStateAtTailEnd" to pm["nativeStateAtTailEnd"],
                "permanentSinkPlayStateAtTailEnd" to pm["sinkPlayStateAtTailEnd"],
                "permanentTransportStopCalled" to pm["transportStopCalled"],
                "permanentTransportStopAccepted" to pm["transportStopAccepted"],
                "permanentTransportState" to pm["transportState"],
                "permanentFramesReadFromTransport" to permanent.framesReadFromTransport,
                "permanentFramesWrittenToSink" to permanent.framesWrittenToSink,
                "permanentKotlinSinkChecksumHex" to permanent.kotlinSinkChecksumHex,
                "permanentNativeChecksumHex" to permanent.nativeChecksumHex,
                "permanentEventsEnqueued" to permanent.eventsEnqueued,
                "permanentEventsDrained" to permanent.eventsDrained,
                "permanentEventsDropped" to permanent.eventsDropped,
                "permanentRealFocusCallbackCount" to pm["focus_realFocusCallbackCount"],
                "permanentRealNoisyBroadcastCount" to pm["focus_realNoisyBroadcastCount"],
                "permanentReleaseCount" to permanent.releaseCount,
                "permanentFocusAbandonCount" to permanent.focusAbandonCount,
                "permanentReceiverUnregisterCount" to permanent.receiverUnregisterCount,
                // EOS scenario telemetry.
                "eosTransportStateAtTailEnd" to em["transportStateAtTailEnd"],
                "eosTransportState" to em["transportState"],
                "eosFramesReadFromTransport" to eos.framesReadFromTransport,
                "eosFramesWrittenToSink" to eos.framesWrittenToSink,
                "eosKotlinSinkChecksumHex" to eos.kotlinSinkChecksumHex,
                "eosNativeChecksumHex" to eos.nativeChecksumHex,
                "eosEventsEnqueued" to eos.eventsEnqueued,
                "eosEventsDrained" to eos.eventsDrained,
                "eosEventsDropped" to eos.eventsDropped,
                "eosRealFocusCallbackCount" to em["focus_realFocusCallbackCount"],
                "eosRealNoisyBroadcastCount" to em["focus_realNoisyBroadcastCount"],
                "eosReleaseCount" to eos.releaseCount,
                "eosFocusAbandonCount" to eos.focusAbandonCount,
                "eosReceiverUnregisterCount" to eos.receiverUnregisterCount,
                // Per-scenario failure reasons, lanes and full metrics.
                "eosFailureReason" to eos.failureReason,
                "noisyFailureReason" to noisy.failureReason,
                "permanentFailureReason" to permanent.failureReason,
                "eosLanes" to eos.lanes,
                "noisyLanes" to noisy.lanes,
                "permanentLanes" to permanent.lanes,
                "eosMetrics" to em,
                "noisyMetrics" to nm,
                "permanentMetrics" to pm,
            )

            val failureReason = when {
                pass -> ""
                !eos.pass -> "eos_scenario:${eos.failureReason.ifBlank { "failed" }}"
                !noisy.pass -> "noisy_terminal_scenario:${noisy.failureReason.ifBlank { "failed" }}"
                !permanent.pass -> "permanent_terminal_scenario:${permanent.failureReason.ifBlank { "failed" }}"
                !eosScenarioPass -> "eos_scenario_gates_not_held"
                !noisyTerminalScenarioPass -> "noisy_terminal_scenario_gates_not_held"
                !permanentTerminalScenarioPass -> "permanent_terminal_scenario_gates_not_held"
                else -> "focus_response_gates_not_held"
            }
            val status = when {
                pass -> "pass"
                !eos.pass -> eos.status.ifBlank { "fail" }
                !noisy.pass -> noisy.status.ifBlank { "fail" }
                !permanent.pass -> permanent.status.ifBlank { "fail" }
                else -> "fail"
            }
            val marker = if (pass) PASS_MARKER else FAIL_MARKER
            val lastError = if (pass) null else failureReason

            return mapOf(
                "pass" to pass,
                "status" to status,
                "marker" to marker,
                "proofBoundary" to PROOF_BOUNDARY,
                "nativeProofBoundary" to PROOF_BOUNDARY,
                "failureReason" to failureReason,
                "details" to "Y4a realtime playback focus/noisy response harness pass=$pass",
                "lanes" to lanes,
                "metrics" to metrics,
                "lastError" to lastError,
                "raw" to "pass=$pass;status=$status;marker=$marker",
            )
        } catch (e: Throwable) {
            return buildFailurePayload("execute_smoke_exception:${e.javaClass.simpleName}:${e.message}")
        }
    }

    private fun buildFailurePayload(reason: String): Map<String, Any?> {
        val lanes = linkedMapOf<String, Any?>()
        for (name in LANE_NAMES) lanes[name] = false
        lanes["canonical"] = false
        return mapOf(
            "pass" to false,
            "status" to "fail",
            "marker" to FAIL_MARKER,
            "proofBoundary" to PROOF_BOUNDARY,
            "nativeProofBoundary" to PROOF_BOUNDARY,
            "failureReason" to reason,
            "details" to reason,
            "lanes" to lanes,
            "metrics" to mapOf(
                "failureReason" to reason,
                "sampleRate" to SAMPLE_RATE,
                "channelCount" to CHANNEL_COUNT,
                "maxFramesPerMix" to MAX_FRAMES_PER_MIX,
                "trackCount" to TRACK_COUNT,
                "declaredFrameCount" to DECLARED_FRAME_COUNT,
                "phaseFrames" to PHASE_FRAMES,
                "pauseHoldMs" to PAUSE_HOLD_MS,
                "baseGain" to VanguardRealtimePlaybackFocusResponseSink.BASE_GAIN,
                "duckGain" to VanguardRealtimePlaybackFocusResponseSink.DUCK_GAIN,
                "scenarioOrder" to emptyList<String>(),
                "eosAutoResumeAllowed" to false,
                "noisyAutoResumeAllowed" to false,
                "permanentAutoResumeAllowed" to false,
                "noisyPauseApplySeq" to -1L,
                "permanentStopApplySeq" to -1L,
                "permanentGainAttemptApplySeq" to -1L,
                "noisyTransportStateAtTailEnd" to "",
                "permanentTransportStateAtTailEnd" to "",
                "eosTransportStateAtTailEnd" to "",
                "noisyTransportState" to "",
                "permanentTransportState" to "",
                "eosTransportState" to "",
                "noisyEventsDropped" to 0L,
                "permanentEventsDropped" to 0L,
                "eosEventsDropped" to 0L,
                "noisyReleaseCount" to 0,
                "permanentReleaseCount" to 0,
                "eosReleaseCount" to 0,
                "noisyFocusAbandonCount" to 0,
                "permanentFocusAbandonCount" to 0,
                "eosFocusAbandonCount" to 0,
                "noisyReceiverUnregisterCount" to 0,
                "permanentReceiverUnregisterCount" to 0,
                "eosReceiverUnregisterCount" to 0,
            ),
            "lastError" to reason,
            "raw" to "pass=false;status=fail;marker=$FAIL_MARKER;reason=$reason",
        )
    }
}
