package com.connects.vanguard_media_engine.diagnostics

import android.media.AudioTrack
import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackRoutingController
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackSinkFaultToleranceSink
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-REALTIME-PLAYBACK-SINK-FAULT-TOLERANCE (Y4b):
 * verification smoke coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for validating the production
 * [VanguardRealtimePlaybackSinkFaultToleranceSink] adapter driven by the
 * authoritative Kotlin transport state machine
 * ([VanguardRealtimePlaybackTransportStateMachine]) and one
 * [VanguardRealtimePlaybackRoutingController] per run:
 * - Sample rate = 48000, channel count = 2, maxFramesPerMix = 256,
 *   track count = 2, declaredFrameCount = 12000, phaseFrames = 2048,
 *   pauseHoldMs = 150, base gain 0.5, deadlineMs = 20000.
 * - Two sequential scenarios, each with a fresh state machine and routing
 *   controller (listener attached/detached once per AudioTrack instance).
 *   Every scenario shares the same head: synthetic route-changed observed on
 *   the run thread (telemetry only).
 *   1. EOS_WITH_DEAD_OBJECT_RECOVERY: exactly one synthetic ERROR_DEAD_OBJECT
 *      substituted for an in-flight write (no bytes consumed); the old
 *      AudioTrack is released once, a same-parameter instance is created,
 *      STATE_INITIALIZED, base gain reapplied, listener handed over, play()
 *      -> PLAYSTATE_PLAYING, and the same ByteBuffer remainder is resumed;
 *      transport COMPLETED, full checksum identity, exact declaredFrameCount
 *      accounting, no double-count/drop, every AudioTrack instance released.
 *   2. ROUTE_DISCONNECT_TERMINAL: synthetic route-disconnect while PLAYING ->
 *      transport.pause() then AudioTrack.pause(); gated on transport PAUSED
 *      at tail end, autoResumeAllowed=false, frozen hold, prefix checksum
 *      identity, partial write accounting, single teardown stop.
 * - Coordinator dispose only flips the cancel flag and disposes the active
 *   state machine; the sink's finally owns listener/AudioTrack teardown.
 *
 * Proof boundary non-claims:
 * realtime playback sink fault tolerance diagnostic only, nonzero-gain
 * AudioTrack sink, Y1 transport, synthetic dead-object recovery only,
 * route-change listener handoff and fail-closed pause only, no
 * MediaCodec/MediaExtractor, no presentation clock, no A/V sync, no OS route
 * arbitration claim, no real OS dead-object forcing claim, no seamless
 * hot-swap claim, no audible output claim, no product/editor/app wiring, no
 * iOS, no native C++ changes.
 */
class AndroidRealtimePlaybackSinkFaultToleranceSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardY4bSinkFaultTolerance"
        const val METHOD_NAME = "runRealtimePlaybackSinkFaultToleranceSmoke"

        const val PASS_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_PHYSICAL_SMOKE_PASS"
        const val FAIL_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_PHYSICAL_SMOKE_FAIL"
        const val START_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_SMOKE_START"
        const val JSON_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_JSON"

        const val PROOF_BOUNDARY =
            VanguardRealtimePlaybackSinkFaultToleranceSink.PROOF_BOUNDARY

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
            "audioTrackInitOk",
            "baseGainSetOk",
            "routingListenerRegisteredOk",
            "routingListenerUnregisteredOk",
            "routeChangeObservationOk",
            "routeDisconnectFailClosedPauseOk",
            "deadObjectInjectedOnceOk",
            "deadObjectOldTrackReleasedOk",
            "deadObjectNewTrackStateInitializedOk",
            "deadObjectNewTrackVolumeSetOk",
            "deadObjectNewTrackPlayOk",
            "deadObjectRemainderResumedOk",
            "deadObjectNoDoubleCountOk",
            "transportCompletedOk",
            "transportStoppedOk",
            "checksumIdentityOk",
            "sinkWriteAccountingOk",
            "audioTrackReleasedOk",
            "eventsDroppedZeroOk",
            "lifecycleOk",
            "eosScenarioPass",
            "routeDisconnectTerminalScenarioPass",
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
    // down its own routing listener and every AudioTrack instance in its
    // finally block.
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
        }, "Y4bSinkFaultToleranceSmoke").start()
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
        scenario: VanguardRealtimePlaybackSinkFaultToleranceSink.Scenario,
    ): VanguardRealtimePlaybackSinkFaultToleranceSink.Result? {
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
                threadName = "Y4bSinkFaultToleranceSmokeSM_${scenario.name.lowercase()}",
            )
            activeStateMachine = sm
            if (disposed.get()) return null

            val controller = VanguardRealtimePlaybackRoutingController(
                listenerHandler = mainHandler,
            )
            val sink = VanguardRealtimePlaybackSinkFaultToleranceSink()
            val sinkConfig = VanguardRealtimePlaybackSinkFaultToleranceSink.Config(
                stateMachine = sm,
                routingController = controller,
                scenario = scenario,
                sampleRate = SAMPLE_RATE,
                channelCount = CHANNEL_COUNT,
                maxFramesPerMix = MAX_FRAMES_PER_MIX,
                declaredFrameCount = DECLARED_FRAME_COUNT,
                phaseFrames = PHASE_FRAMES,
                pauseHoldMs = PAUSE_HOLD_MS,
                baseGain = VanguardRealtimePlaybackSinkFaultToleranceSink.BASE_GAIN,
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
                VanguardRealtimePlaybackSinkFaultToleranceSink.Scenario.EOS_WITH_DEAD_OBJECT_RECOVERY,
            ) ?: return buildFailurePayload("coordinator_disposed_before_eos_scenario")
            val disconnect = runScenario(
                VanguardRealtimePlaybackSinkFaultToleranceSink.Scenario.ROUTE_DISCONNECT_TERMINAL,
            ) ?: return buildFailurePayload("coordinator_disposed_before_route_disconnect_scenario")

            val all = listOf(eos, disconnect)
            val em = eos.metrics
            val dm = disconnect.metrics

            // Gates shared by every scenario: sink pass, proof boundary,
            // shared head lanes, checksum identity, write accounting, every
            // AudioTrack instance released with one final release, listener
            // attached/detached once per instance, zero drops, lifecycle.
            fun commonGates(r: VanguardRealtimePlaybackSinkFaultToleranceSink.Result): Boolean =
                r.pass &&
                    r.proofBoundary == PROOF_BOUNDARY &&
                    r.audioTrackInitOk &&
                    r.baseGainSetOk &&
                    r.routingListenerRegisteredOk &&
                    r.routingListenerUnregisteredOk &&
                    r.routeChangeObservationOk &&
                    r.checksumIdentityOk &&
                    r.sinkWriteAccountingOk &&
                    r.audioTrackReleasedOk &&
                    r.lifecycleOk &&
                    r.eventsDropped == 0L &&
                    r.finalReleaseCount == 1 &&
                    r.audioTracksReleased == r.audioTracksCreated &&
                    r.listenerAttachCount == r.audioTracksCreated &&
                    r.listenerDetachCount == r.listenerAttachCount &&
                    (r.lanes["preStartDrainEmptyOk"] as? Boolean) == true &&
                    (r.lanes["syntheticRouteChangedObservedOk"] as? Boolean) == true &&
                    r.kotlinSinkChecksumHex.isNotEmpty() &&
                    r.kotlinSinkChecksumHex.equals(r.nativeChecksumHex, ignoreCase = true) &&
                    r.framesReadFromTransport == r.framesWrittenToSink

            // EOS with dead-object recovery: exactly one synthetic dead
            // object, two AudioTrack instances created and released, the
            // listener handed over, the remainder resumed on the new
            // instance, COMPLETED with full-length accounting, no route
            // disconnect applied.
            val eosScenarioPass = commonGates(eos) &&
                eos.scenario == VanguardRealtimePlaybackSinkFaultToleranceSink.Scenario.EOS_WITH_DEAD_OBJECT_RECOVERY &&
                eos.transportCompletedOk &&
                !eos.transportStoppedOk &&
                !eos.routeDisconnectFailClosedPauseOk &&
                eos.autoResumeAllowed &&
                eos.deadObjectInjectedOnceOk &&
                eos.deadObjectOldTrackReleasedOk &&
                eos.deadObjectNewTrackStateInitializedOk &&
                eos.deadObjectNewTrackVolumeSetOk &&
                eos.deadObjectNewTrackPlayOk &&
                eos.deadObjectRemainderResumedOk &&
                eos.deadObjectNoDoubleCountOk &&
                (eos.lanes["deadObjectListenerHandoffOk"] as? Boolean) == true &&
                eos.audioTracksCreated == 2 &&
                eos.audioTracksReleased == 2 &&
                eos.listenerAttachCount == 2 &&
                eos.listenerDetachCount == 2 &&
                eos.framesReadFromTransport == DECLARED_FRAME_COUNT &&
                eos.framesWrittenToSink == DECLARED_FRAME_COUNT &&
                (em["syntheticDeadObjectInjectedCount"] as? Long) == 1L &&
                (em["deadObjectObservedCount"] as? Long) == 1L &&
                (em["deadObjectOldTrackReleaseCount"] as? Long) == 1L &&
                (em["routeDisconnectAppliedCount"] as? Long) == 0L &&
                (em["playStateAfterRecreatePlay"] as? Int) == AudioTrack.PLAYSTATE_PLAYING &&
                (em["transportStopCalled"] as? Boolean) == false &&
                (em["transportStateAtTailEnd"] as? String) == "COMPLETED" &&
                (em["transportState"] as? String) == "COMPLETED"

            // Route-disconnect terminal: PAUSED at tail end (transport.pause()
            // then AudioTrack.pause()), autoResumeAllowed=false, frozen hold,
            // prefix checksum identity, one AudioTrack instance only, no dead
            // object, and the still-PAUSED transport stopped exactly once by
            // teardown.
            val routeDisconnectTerminalScenarioPass = commonGates(disconnect) &&
                disconnect.scenario == VanguardRealtimePlaybackSinkFaultToleranceSink.Scenario.ROUTE_DISCONNECT_TERMINAL &&
                disconnect.routeDisconnectFailClosedPauseOk &&
                disconnect.transportStoppedOk &&
                !disconnect.autoResumeAllowed &&
                !disconnect.transportCompletedOk &&
                !disconnect.deadObjectInjectedOnceOk &&
                !disconnect.deadObjectOldTrackReleasedOk &&
                !disconnect.deadObjectNewTrackPlayOk &&
                (disconnect.lanes["routeDisconnectHoldFrozenOk"] as? Boolean) == true &&
                disconnect.audioTracksCreated == 1 &&
                disconnect.audioTracksReleased == 1 &&
                disconnect.listenerAttachCount == 1 &&
                disconnect.listenerDetachCount == 1 &&
                (dm["routeDisconnectAppliedCount"] as? Long) == 1L &&
                (dm["syntheticDeadObjectInjectedCount"] as? Long) == 0L &&
                (dm["deadObjectObservedCount"] as? Long) == 0L &&
                (dm["disconnectHoldDispatchDelta"] as? Long) == 0L &&
                (dm["disconnectHoldPushedDelta"] as? Long) == 0L &&
                (dm["transportStateAtTailEnd"] as? String) == "PAUSED" &&
                (dm["sinkPlayStateAtTailEnd"] as? Int) == AudioTrack.PLAYSTATE_PAUSED &&
                (dm["transportStopCalled"] as? Boolean) == true &&
                (dm["transportStopAccepted"] as? Boolean) == true &&
                (dm["transportState"] as? String) == "STOPPED" &&
                disconnect.framesReadFromTransport < DECLARED_FRAME_COUNT

            val audioTrackInitOk = all.all { it.audioTrackInitOk }
            val baseGainSetOk = all.all { it.baseGainSetOk }
            val routingListenerRegisteredOk = all.all { it.routingListenerRegisteredOk }
            val routingListenerUnregisteredOk = all.all { it.routingListenerUnregisteredOk }
            val routeChangeObservationOk = all.all { it.routeChangeObservationOk }
            val routeDisconnectFailClosedPauseOk = disconnect.routeDisconnectFailClosedPauseOk
            val deadObjectInjectedOnceOk = eos.deadObjectInjectedOnceOk
            val deadObjectOldTrackReleasedOk = eos.deadObjectOldTrackReleasedOk
            val deadObjectNewTrackStateInitializedOk = eos.deadObjectNewTrackStateInitializedOk
            val deadObjectNewTrackVolumeSetOk = eos.deadObjectNewTrackVolumeSetOk
            val deadObjectNewTrackPlayOk = eos.deadObjectNewTrackPlayOk
            val deadObjectRemainderResumedOk = eos.deadObjectRemainderResumedOk
            val deadObjectNoDoubleCountOk = eos.deadObjectNoDoubleCountOk
            val transportCompletedOk = eos.transportCompletedOk
            val transportStoppedOk = disconnect.transportStoppedOk
            val checksumIdentityOk = all.all { it.checksumIdentityOk }
            val sinkWriteAccountingOk = all.all { it.sinkWriteAccountingOk }
            val audioTrackReleasedOk = all.all {
                it.audioTrackReleasedOk && it.finalReleaseCount == 1 && it.audioTracksReleased == it.audioTracksCreated
            }
            val eventsDroppedZeroOk = all.all { it.eventsDropped == 0L }
            val lifecycleOk = all.all { it.lifecycleOk }

            val allNativeLanesPass = eosScenarioPass &&
                routeDisconnectTerminalScenarioPass &&
                audioTrackInitOk &&
                baseGainSetOk &&
                routingListenerRegisteredOk &&
                routingListenerUnregisteredOk &&
                routeChangeObservationOk &&
                routeDisconnectFailClosedPauseOk &&
                deadObjectInjectedOnceOk &&
                deadObjectOldTrackReleasedOk &&
                deadObjectNewTrackStateInitializedOk &&
                deadObjectNewTrackVolumeSetOk &&
                deadObjectNewTrackPlayOk &&
                deadObjectRemainderResumedOk &&
                deadObjectNoDoubleCountOk &&
                transportCompletedOk &&
                transportStoppedOk &&
                checksumIdentityOk &&
                sinkWriteAccountingOk &&
                audioTrackReleasedOk &&
                eventsDroppedZeroOk &&
                lifecycleOk
            val pass = allNativeLanesPass

            val lanes = linkedMapOf<String, Any?>(
                "audioTrackInitOk" to audioTrackInitOk,
                "baseGainSetOk" to baseGainSetOk,
                "routingListenerRegisteredOk" to routingListenerRegisteredOk,
                "routingListenerUnregisteredOk" to routingListenerUnregisteredOk,
                "routeChangeObservationOk" to routeChangeObservationOk,
                "routeDisconnectFailClosedPauseOk" to routeDisconnectFailClosedPauseOk,
                "deadObjectInjectedOnceOk" to deadObjectInjectedOnceOk,
                "deadObjectOldTrackReleasedOk" to deadObjectOldTrackReleasedOk,
                "deadObjectNewTrackStateInitializedOk" to deadObjectNewTrackStateInitializedOk,
                "deadObjectNewTrackVolumeSetOk" to deadObjectNewTrackVolumeSetOk,
                "deadObjectNewTrackPlayOk" to deadObjectNewTrackPlayOk,
                "deadObjectRemainderResumedOk" to deadObjectRemainderResumedOk,
                "deadObjectNoDoubleCountOk" to deadObjectNoDoubleCountOk,
                "transportCompletedOk" to transportCompletedOk,
                "transportStoppedOk" to transportStoppedOk,
                "checksumIdentityOk" to checksumIdentityOk,
                "sinkWriteAccountingOk" to sinkWriteAccountingOk,
                "audioTrackReleasedOk" to audioTrackReleasedOk,
                "eventsDroppedZeroOk" to eventsDroppedZeroOk,
                "lifecycleOk" to lifecycleOk,
                "eosScenarioPass" to eosScenarioPass,
                "routeDisconnectTerminalScenarioPass" to routeDisconnectTerminalScenarioPass,
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
                "baseGain" to VanguardRealtimePlaybackSinkFaultToleranceSink.BASE_GAIN,
                "scenarioOrder" to all.map { it.scenario.name },
                // Auto-resume flag at return, per scenario.
                "eosAutoResumeAllowed" to eos.autoResumeAllowed,
                "disconnectAutoResumeAllowed" to disconnect.autoResumeAllowed,
                // EOS / dead-object recovery telemetry.
                "eosRouteChangedApplySeq" to em["routeChangedApplySeq"],
                "eosRouteChangedAppliedCount" to em["routeChangedAppliedCount"],
                "eosRoutedDeviceTypeAtRouteChanged" to em["routedDeviceTypeAtRouteChanged"],
                "eosSyntheticDeadObjectInjectedCount" to em["syntheticDeadObjectInjectedCount"],
                "eosDeadObjectObservedCount" to em["deadObjectObservedCount"],
                "eosDeadObjectInjectAfterFrames" to em["deadObjectInjectAfterFrames"],
                "eosDeadObjectOldTrackReleaseCount" to em["deadObjectOldTrackReleaseCount"],
                "eosDeadObjectOldTrackListenerDetachOk" to em["deadObjectOldTrackListenerDetachOk"],
                "eosDeadObjectSliceBytesAtRecovery" to em["deadObjectSliceBytesAtRecovery"],
                "eosDeadObjectUnwrittenBytesAtRecovery" to em["deadObjectUnwrittenBytesAtRecovery"],
                "eosDeadObjectBufferPositionAtRecovery" to em["deadObjectBufferPositionAtRecovery"],
                "eosDeadObjectSinkFramesWrittenBeforeRecovery" to em["deadObjectSinkFramesWrittenBeforeRecovery"],
                "eosDeadObjectSinkFramesWrittenAfterRecoveryCall" to em["deadObjectSinkFramesWrittenAfterRecoveryCall"],
                "eosDeadObjectRemainderFramesWrittenOnNewTrack" to em["deadObjectRemainderFramesWrittenOnNewTrack"],
                "eosDeadObjectFramesReadAtRecovery" to em["deadObjectFramesReadAtRecovery"],
                "eosPlayStateAfterRecreatePlay" to em["playStateAfterRecreatePlay"],
                "eosFrozenBufferSizeInFrames" to em["frozenBufferSizeInFrames"],
                "eosNewTrackBufferSizeInFrames" to em["newTrackBufferSizeInFrames"],
                "eosAudioTracksCreated" to eos.audioTracksCreated,
                "eosAudioTracksReleased" to eos.audioTracksReleased,
                "eosFinalReleaseCount" to eos.finalReleaseCount,
                "eosListenerAttachCount" to eos.listenerAttachCount,
                "eosListenerDetachCount" to eos.listenerDetachCount,
                "eosPlaybackHeadFinal" to em["playbackHeadFinal"],
                "eosTransportStateAtTailEnd" to em["transportStateAtTailEnd"],
                "eosNativeStateAtTailEnd" to em["nativeStateAtTailEnd"],
                "eosSinkPlayStateAtTailEnd" to em["sinkPlayStateAtTailEnd"],
                "eosTransportState" to em["transportState"],
                "eosFramesReadFromTransport" to eos.framesReadFromTransport,
                "eosFramesWrittenToSink" to eos.framesWrittenToSink,
                "eosPartialWriteCount" to em["partialWriteCount"],
                "eosKotlinSinkChecksumHex" to eos.kotlinSinkChecksumHex,
                "eosNativeChecksumHex" to eos.nativeChecksumHex,
                "eosEventsEnqueued" to eos.eventsEnqueued,
                "eosEventsDrained" to eos.eventsDrained,
                "eosEventsDropped" to eos.eventsDropped,
                "eosRealRoutingCallbackCount" to em["routing_realRoutingCallbackCount"],
                // Route-disconnect terminal telemetry.
                "disconnectRouteChangedApplySeq" to dm["routeChangedApplySeq"],
                "disconnectRouteChangedAppliedCount" to dm["routeChangedAppliedCount"],
                "disconnectRoutedDeviceTypeAtRouteChanged" to dm["routedDeviceTypeAtRouteChanged"],
                "disconnectRouteDisconnectApplySeq" to dm["routeDisconnectApplySeq"],
                "disconnectRouteDisconnectApplyOrder" to dm["routeDisconnectApplyOrder"],
                "disconnectRouteDisconnectAppliedCount" to dm["routeDisconnectAppliedCount"],
                "disconnectRouteChangedAfterDisconnectCount" to dm["routeChangedAfterDisconnectCount"],
                "disconnectTransportCommandAttempts" to dm["transportCommandAttempts"],
                "disconnectHoldDispatchDelta" to dm["disconnectHoldDispatchDelta"],
                "disconnectHoldPushedDelta" to dm["disconnectHoldPushedDelta"],
                "disconnectPlaybackHeadAtRouteDisconnect" to dm["playbackHeadAtRouteDisconnect"],
                "disconnectTransportStateAtTailEnd" to dm["transportStateAtTailEnd"],
                "disconnectNativeStateAtTailEnd" to dm["nativeStateAtTailEnd"],
                "disconnectSinkPlayStateAtTailEnd" to dm["sinkPlayStateAtTailEnd"],
                "disconnectTransportStopCalled" to dm["transportStopCalled"],
                "disconnectTransportStopAccepted" to dm["transportStopAccepted"],
                "disconnectTransportState" to dm["transportState"],
                "disconnectAudioTracksCreated" to disconnect.audioTracksCreated,
                "disconnectAudioTracksReleased" to disconnect.audioTracksReleased,
                "disconnectFinalReleaseCount" to disconnect.finalReleaseCount,
                "disconnectListenerAttachCount" to disconnect.listenerAttachCount,
                "disconnectListenerDetachCount" to disconnect.listenerDetachCount,
                "disconnectFramesReadFromTransport" to disconnect.framesReadFromTransport,
                "disconnectFramesWrittenToSink" to disconnect.framesWrittenToSink,
                "disconnectPartialWriteCount" to dm["partialWriteCount"],
                "disconnectKotlinSinkChecksumHex" to disconnect.kotlinSinkChecksumHex,
                "disconnectNativeChecksumHex" to disconnect.nativeChecksumHex,
                "disconnectEventsEnqueued" to disconnect.eventsEnqueued,
                "disconnectEventsDrained" to disconnect.eventsDrained,
                "disconnectEventsDropped" to disconnect.eventsDropped,
                "disconnectRealRoutingCallbackCount" to dm["routing_realRoutingCallbackCount"],
                // Per-scenario failure reasons, lanes and full metrics.
                "eosFailureReason" to eos.failureReason,
                "disconnectFailureReason" to disconnect.failureReason,
                "eosLanes" to eos.lanes,
                "disconnectLanes" to disconnect.lanes,
                "eosMetrics" to em,
                "disconnectMetrics" to dm,
            )

            val failureReason = when {
                pass -> ""
                !eos.pass -> "eos_scenario:${eos.failureReason.ifBlank { "failed" }}"
                !disconnect.pass -> "route_disconnect_terminal_scenario:${disconnect.failureReason.ifBlank { "failed" }}"
                !eosScenarioPass -> "eos_scenario_gates_not_held"
                !routeDisconnectTerminalScenarioPass -> "route_disconnect_terminal_scenario_gates_not_held"
                else -> "sink_fault_tolerance_gates_not_held"
            }
            val status = when {
                pass -> "pass"
                !eos.pass -> eos.status.ifBlank { "fail" }
                !disconnect.pass -> disconnect.status.ifBlank { "fail" }
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
                "details" to "Y4b realtime playback sink fault tolerance harness pass=$pass",
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
                "baseGain" to VanguardRealtimePlaybackSinkFaultToleranceSink.BASE_GAIN,
                "scenarioOrder" to emptyList<String>(),
                "eosAutoResumeAllowed" to false,
                "disconnectAutoResumeAllowed" to false,
                "eosSyntheticDeadObjectInjectedCount" to 0L,
                "eosDeadObjectObservedCount" to 0L,
                "eosAudioTracksCreated" to 0,
                "eosAudioTracksReleased" to 0,
                "eosFinalReleaseCount" to 0,
                "eosListenerAttachCount" to 0,
                "eosListenerDetachCount" to 0,
                "eosTransportStateAtTailEnd" to "",
                "eosTransportState" to "",
                "eosEventsDropped" to 0L,
                "disconnectRouteDisconnectApplySeq" to -1L,
                "disconnectRouteDisconnectAppliedCount" to 0L,
                "disconnectAudioTracksCreated" to 0,
                "disconnectAudioTracksReleased" to 0,
                "disconnectFinalReleaseCount" to 0,
                "disconnectListenerAttachCount" to 0,
                "disconnectListenerDetachCount" to 0,
                "disconnectTransportStateAtTailEnd" to "",
                "disconnectTransportState" to "",
                "disconnectEventsDropped" to 0L,
            ),
            "lastError" to reason,
            "raw" to "pass=false;status=fail;marker=$FAIL_MARKER;reason=$reason",
        )
    }
}
