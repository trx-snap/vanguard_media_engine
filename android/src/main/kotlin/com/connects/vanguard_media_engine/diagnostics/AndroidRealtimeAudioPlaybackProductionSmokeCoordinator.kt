package com.connects.vanguard_media_engine.diagnostics

import android.content.Context
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.SystemClock
import android.util.Log
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackClockCorrelation
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSinkBridge
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackDecoderFeed
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SINK-CLOCK (Y8a) +
 * P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-DEAD-OBJECT (Y8b) +
 * P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SEEK (Y9) +
 * P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-REPEATED-SEEK (Y10b) +
 * P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-FOCUS-RESPONSE (Y11b) +
 * P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-ROUTE-CHANGE (Y12):
 * production-component diagnostic smoke coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route only. It drives the PRODUCTION
 * [VanguardRealtimeAudioPlaybackSession] (real MediaExtractor/MediaCodec ->
 * Y5a external ingest -> Y1 transport -> sink-thread-owned non-zero-gain
 * AudioTrack + presentation clock) through ten scenarios on a worker
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
 *
 * Scenario 4 (Y9) arms the session's ONE forward mid-stream seek to
 * [SmokeConfig.seekTargetSec] (dead-object seam off): the session executes
 * the whole seek order on its own (feed held at the window-aligned hold
 * frame H, quiescence, sink seek park, transport pause, AudioTrack.flush
 * once on the sink thread, transport seek, decoder re-anchor with the
 * deliberate stale-generation probe, post-seek pre-roll while PAUSED, sink
 * unpark opening the seek clock epoch at T, transport resume) and plays to
 * EOS; the lanes assert H + (declared - T) accounting, checksum identity
 * over the accepted sequence, and the seek clock epoch discontinuity.
 *
 * Scenario 5 (Y10b) arms the session's repeated forward seek to T1 then T2:
 * starts, snapshots armed state, calls session.seek(T1), requires accepted/PLAYING,
 * snapshots after first, calls session.seek(T2), requires accepted/PLAYING,
 * snapshots after second, then calls session.seek(T2) again and requires rejected
 * reason seek_repeated with state still PLAYING/no failure. Then awaits EOS,
 * stop/dispose, and evaluates lanes.
 * Seek metric flattening lives in [AndroidRealtimeAudioPlaybackProductionSeekMetrics].
 *
 * Scenario 6 (Y11b) starts a focus-enabled session (duckGain default 0.1f):
 * proves transient duck gain change, full gain restore, transient loss pause,
 * user-intent-gated auto-resume on gain, becoming-noisy terminal pause, and
 * verified rejection of auto-resume after noisy loss.
 *
 * Scenario 7 (Y11b) starts a focus-enabled session: proves permanent loss pause
 * and verified rejection of auto-resume on subsequent gain.
 *
 * Scenario 8 (Y12) starts a fresh routing- and focus-enabled session: proves
 * observation of route change without transport mutation using a monotonic
 * baseline increase on routeChangedAppliedCount (robust to real OS
 * ROUTE_CHANGED callbacks racing the synthetic one), then stops/disposes.
 * This scenario never posts a disconnect, so it carries its own independent
 * [SmokeConfig.deadlineMs] budget separate from Scenario 9's.
 *
 * Scenario 9 (Y12) starts a second fresh routing- and focus-enabled session:
 * proves terminal fail-closed pause on route disconnect (from PLAYING) with
 * AudioTrack paused at park and routeDisconnectAppliedCount increased by a
 * monotonic baseline, rejection of public resume, and routing teardown. It
 * carries its own independent [SmokeConfig.deadlineMs] budget separate from
 * Scenario 8's, so a slow/racy route-change observation can never starve the
 * disconnect proof (or vice versa).
 *
 * Scenario 10 (Y12) starts a routing- and focus-enabled session: proves route
 * disconnect while paused by focus policy blocks focus auto-resume on
 * subsequent focus gain and continues to reject public resume. Because the
 * session is already PAUSED when the disconnect lands, the native session
 * never attempts the bounded-pause path that bumps routeDisconnectAppliedCount
 * (session code only bumps it from PLAYING), so this scenario proves the
 * disconnect landed via the sticky routingTerminalDisconnect flag transition
 * rather than a count delta or a snapshot of lastEventTag/lastAction, which
 * are last-writer-wins fields a later real OS ROUTE_CHANGED callback can
 * overwrite before the polling loop observes them.
 */
class AndroidRealtimeAudioPlaybackProductionSmokeCoordinator(
    private val context: Context,
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
                "one_forward_mid_stream_seek_while_paused_feed_held_at_window_aligned_anchor_quiescent_" +
                "audiotrack_flush_once_on_sink_thread_before_transport_seek_" +
                "seek_clock_epoch_based_at_target_deliberate_discontinuity_" +
                "stale_generation_rejected_before_jni_two_ordered_forward_seeks_and_third_rejected_without_teardown_" +
                "production_focus_response_focus_monitor_single_consumer_audiomanager_focus_request_becoming_noisy_receiver_" +
                "sink_thread_gain_duck_restore_request_ack_transient_pause_auto_resume_user_intent_gated_" +
                "noisy_terminal_pause_no_auto_resume_permanent_loss_pause_no_auto_resume_" +
                "production_route_change_response_routing_monitor_single_consumer_audiotrack_routing_listener_attach_detach_" +
                "route_change_observed_no_transport_mutation_route_disconnect_terminal_pause_no_resume_" +
                "focus_gain_after_route_disconnect_no_auto_resume_" +
                "presentation_clock_query_surface_off_thread_current_position_poller_monotonic_" +
                "current_position_read_counter_isolation_epoch_relative_presentation_lag_bounded_position_at_eos_no_runaway_" +
                "position_query_lifecycle_pause_seek_dead_object_teardown_" +
                "native_clock_correlation_observation_no_feedback_" +
                "stop_dispose_release_once_" +
                "no_product_no_editor_no_app_no_connectsapp_no_ios_no_streaming_no_cache_" +
                "no_audio_clock_mutator_changes_no_clock_feedback_no_pacing_feedback"

        const val SCENARIO_PLAYTHROUGH = "PLAYTHROUGH_BOUNDED_PAUSE_RESUME_TO_EOS"
        const val SCENARIO_STOP_DISPOSE = "STOP_DISPOSE_MID_PLAYBACK"
        const val SCENARIO_DEAD_OBJECT_RECOVERY = "SYNTHETIC_DEAD_OBJECT_RECOVERY_TO_EOS"
        const val SCENARIO_FORWARD_SEEK = "SCENARIO_FORWARD_SEEK_TO_EOS"
        const val SCENARIO_REPEATED_FORWARD_SEEK = "SCENARIO_REPEATED_FORWARD_SEEK_TO_EOS"
        const val SCENARIO_FOCUS_DUCK_TRANSIENT_NOISY = "SCENARIO_FOCUS_DUCK_TRANSIENT_NOISY"
        const val SCENARIO_FOCUS_PERMANENT_LOSS = "SCENARIO_FOCUS_PERMANENT_LOSS"
        const val SCENARIO_ROUTE_CHANGE_OBSERVATION = "SCENARIO_ROUTE_CHANGE_OBSERVATION"
        const val SCENARIO_ROUTE_DISCONNECT_TERMINAL_PAUSE = "SCENARIO_ROUTE_DISCONNECT_TERMINAL_PAUSE"
        const val SCENARIO_ROUTE_DISCONNECT_FOCUS_GAIN_BLOCKED = "SCENARIO_ROUTE_DISCONNECT_FOCUS_GAIN_BLOCKED"
        const val SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE = "SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE"

        const val DEFAULT_PAUSE_HOLD_MS = 400L
        const val DEFAULT_STOP_AFTER_MS = 300L
        // Y9/Y10b seek defaults: target inside the 3 s default clip window; the
        // hold frame is preSeekHoldWindows windows past the pre-roll.
        const val DEFAULT_SEEK_TARGET_SEC = 1.0
        const val DEFAULT_SECOND_SEEK_TARGET_SEC = 2.0
        const val DEFAULT_PRE_SEEK_HOLD_WINDOWS = VanguardRealtimeAudioPlaybackSession.DEFAULT_PRE_SEEK_HOLD_WINDOWS
        // Frames written before the ONE synthetic dead object is armed
        // (~186 ms at 44.1 kHz); must stay below the clip's declared frames.
        const val DEFAULT_DEAD_OBJECT_INJECT_AFTER_FRAMES = 8_192L
        // Device observability budget for the dead-object publication lag
        // (head consumed by the dead instance minus the last published clock
        // position) when the clock was ANCHORED or EXTRAPOLATED at recovery.
        // It bounds how far the clock's view may trail the hardware on the
        // proof device; it is NOT a playback latency target or an SLA.
        const val DEAD_OBJECT_PUBLICATION_LAG_BUDGET_MS = 300L
        const val DEFAULT_DUCK_GAIN = 0.1f
        const val DEFAULT_FOCUS_SETTLE_MS = 100L

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
        // Y9 lanes, evaluated by the forward-seek scenario only.
        const val LANE_SEEK_QUIESCE_ACCOUNTING = "seekQuiesceAccountingOk"
        const val LANE_SEEK_COMMAND = "seekCommandOk"
        const val LANE_SINK_FLUSH_AT_SEEK = "sinkFlushAtSeekOk"
        const val LANE_DECODER_SEEK_REANCHOR = "decoderSeekReanchorOk"
        const val LANE_STALE_GENERATION_REJECTED = "staleGenerationRejectedOk"
        const val LANE_SEEK_CLOCK_EPOCH = "seekClockEpochOk"
        const val LANE_POST_SEEK_DRAIN = "postSeekDrainOk"
        // Y10b lanes, evaluated by the repeated forward-seek scenario only.
        const val LANE_REPEATED_SEEK_COMMAND = "repeatedSeekCommandOk"
        const val LANE_REPEATED_SEEK_CUMULATIVE_ACCOUNTING = "repeatedSeekCumulativeAccountingOk"
        const val LANE_REPEATED_SEEK_THIRD_REJECT = "repeatedSeekThirdRejectOk"
        // Y11b lanes, evaluated by the focus-response scenarios.
        const val LANE_FOCUS_SETUP = "focusSetupOk"
        const val LANE_FOCUS_DUCK_RESTORE = "focusDuckRestoreOk"
        const val LANE_FOCUS_TRANSIENT_PAUSE_RESUME = "focusTransientPauseResumeOk"
        const val LANE_FOCUS_NOISY_TERMINAL_PAUSE = "focusNoisyTerminalPauseOk"
        const val LANE_FOCUS_PERMANENT_LOSS_PAUSE = "focusPermanentLossPauseOk"
        const val LANE_FOCUS_MONITOR_TEARDOWN = "focusMonitorTeardownOk"
        // Y12 lanes, evaluated by the route-change/disconnect scenario.
        const val LANE_ROUTING_SETUP = "routingSetupOk"
        const val LANE_ROUTE_CHANGE_OBSERVATION = "routeChangeObservationOk"
        const val LANE_ROUTE_DISCONNECT_TERMINAL_PAUSE = "routeDisconnectTerminalPauseOk"
        const val LANE_ROUTE_DISCONNECT_RESUME_BLOCKED = "routeDisconnectResumeBlockedOk"
        const val LANE_ROUTING_MONITOR_TEARDOWN = "routingMonitorTeardownOk"
        // Y13 lanes, evaluated by the presentation-clock query surface scenario.
        const val LANE_CURRENT_POSITION_QUERY_SURFACE = "currentPositionQuerySurfaceOk"
        const val LANE_CURRENT_POSITION_POLLER_MONOTONIC = "currentPositionPollerMonotonicOk"
        const val LANE_CURRENT_POSITION_READ_COUNTER_ISOLATION = "currentPositionReadCounterIsolationOk"
        const val LANE_PRESENTATION_LAG_TELEMETRY = "presentationLagTelemetryOk"
        const val LANE_PRESENTATION_LAG_BOUNDED = "presentationLagBoundedOk"
        const val LANE_POSITION_AT_EOS_NO_RUNAWAY = "positionAtEosNoRunawayOk"
        // Y14 lanes, evaluated across lifecycle discontinuities.
        const val LANE_POSITION_QUERY_PAUSE_HOLD_FROZEN = "positionQueryPauseHoldFrozenOk"
        const val LANE_POSITION_QUERY_DEAD_OBJECT_REBASE = "positionQueryDeadObjectRebaseOk"
        const val LANE_POSITION_QUERY_SEEK_BASE_ADVANCE = "positionQuerySeekBaseAdvanceOk"
        const val LANE_POSITION_QUERY_REPEATED_SEEK_BASE_ADVANCE = "positionQueryRepeatedSeekBaseAdvanceOk"
        const val LANE_POSITION_QUERY_POST_TEARDOWN_LATCHED = "positionQueryPostTeardownLatchedOk"
        // Y15 lanes, evaluated by the clock correlation observation.
        const val LANE_NATIVE_AUDIO_CLOCK_SNAPSHOT_PUBLISHED = "nativeAudioClockSnapshotPublishedOk"
        const val LANE_CLOCK_CORRELATION_TELEMETRY = "clockCorrelationTelemetryOk"
        const val LANE_CLOCK_OBSERVATION_NO_FEEDBACK = "clockObservationNoFeedbackOk"
        const val LANE_CANONICAL = "canonical"

        val REQUIRED_LANES: List<String> = listOf(
            LANE_FORMAT_PROBE, LANE_PRE_ROLL, LANE_START, LANE_NONZERO_GAIN,
            LANE_PLAYTHROUGH_ACCOUNTING, LANE_CHECKSUM_IDENTITY,
            LANE_CLOCK_ANCHORED, LANE_CLOCK_MONOTONIC, LANE_CLOCK_EPOCH_BALANCED, LANE_CLOCK_PAUSE_FROZEN,
            LANE_BOUNDED_PAUSE_RESUME, LANE_STOP_DISPOSE, LANE_DECODER_CANCELLED_ON_STOP,
            LANE_TRANSPORT_DISPOSED, LANE_AUDIO_TRACK_RELEASED_ONCE, LANE_THREAD_OWNERSHIP,
            LANE_NO_FEEDBACK, LANE_PROOF_BOUNDARY,
            LANE_DEAD_OBJECT_RECOVERY, LANE_DEAD_OBJECT_CLOCK_EPOCH, LANE_DEAD_OBJECT_REMAINDER,
            LANE_SEEK_QUIESCE_ACCOUNTING, LANE_SEEK_COMMAND, LANE_SINK_FLUSH_AT_SEEK,
            LANE_DECODER_SEEK_REANCHOR, LANE_STALE_GENERATION_REJECTED, LANE_SEEK_CLOCK_EPOCH,
            LANE_POST_SEEK_DRAIN,
            LANE_REPEATED_SEEK_COMMAND, LANE_REPEATED_SEEK_CUMULATIVE_ACCOUNTING, LANE_REPEATED_SEEK_THIRD_REJECT,
            LANE_FOCUS_SETUP, LANE_FOCUS_DUCK_RESTORE, LANE_FOCUS_TRANSIENT_PAUSE_RESUME,
            LANE_FOCUS_NOISY_TERMINAL_PAUSE, LANE_FOCUS_PERMANENT_LOSS_PAUSE, LANE_FOCUS_MONITOR_TEARDOWN,
            LANE_ROUTING_SETUP, LANE_ROUTE_CHANGE_OBSERVATION, LANE_ROUTE_DISCONNECT_TERMINAL_PAUSE,
            LANE_ROUTE_DISCONNECT_RESUME_BLOCKED, LANE_ROUTING_MONITOR_TEARDOWN,
            LANE_CURRENT_POSITION_QUERY_SURFACE, LANE_CURRENT_POSITION_POLLER_MONOTONIC,
            LANE_CURRENT_POSITION_READ_COUNTER_ISOLATION, LANE_PRESENTATION_LAG_TELEMETRY,
            LANE_PRESENTATION_LAG_BOUNDED, LANE_POSITION_AT_EOS_NO_RUNAWAY,
            LANE_POSITION_QUERY_PAUSE_HOLD_FROZEN, LANE_POSITION_QUERY_DEAD_OBJECT_REBASE,
            LANE_POSITION_QUERY_SEEK_BASE_ADVANCE, LANE_POSITION_QUERY_REPEATED_SEEK_BASE_ADVANCE,
            LANE_POSITION_QUERY_POST_TEARDOWN_LATCHED,
            LANE_NATIVE_AUDIO_CLOCK_SNAPSHOT_PUBLISHED,
            LANE_CLOCK_CORRELATION_TELEMETRY,
            LANE_CLOCK_OBSERVATION_NO_FEEDBACK,
        )

        val PROOF_BOUNDARY_TOKENS = listOf(
            "production_engine_component_diagnostic_route", "real_mediaextractor_mediacodec", "y5a_external_ingest",
            "y1_transport", "nonzero_gain_audiotrack", "sink_thread_owned_audiotrack_and_presentation_clock",
            "bounded_pause_resume_closes_reopens_clock_epoch_at_last_published_position",
            "synthetic_armed_dead_object_recovered_once_on_sink_thread", "same_parameter_audiotrack", "epoch_rebase",
            "real_or_repeated_dead_object_fails_closed",
            "one_forward_mid_stream_seek_while_paused", "feed_held_at_window_aligned_anchor_quiescent",
            "audiotrack_flush_once_on_sink_thread_before_transport_seek",
            "seek_clock_epoch_based_at_target_deliberate_discontinuity",
            "stale_generation_rejected_before_jni", "two_ordered_forward_seeks_and_third_rejected_without_teardown",
            "production_focus_response", "focus_monitor_single_consumer", "audiomanager_focus_request",
            "becoming_noisy_receiver", "sink_thread_gain_duck_restore_request_ack",
            "transient_pause_auto_resume_user_intent_gated", "noisy_terminal_pause_no_auto_resume",
            "permanent_loss_pause_no_auto_resume",
            "production_route_change_response", "routing_monitor_single_consumer",
            "audiotrack_routing_listener_attach_detach",
            "route_change_observed_no_transport_mutation",
            "route_disconnect_terminal_pause_no_resume",
            "focus_gain_after_route_disconnect_no_auto_resume",
            "presentation_clock_query_surface", "off_thread_current_position_poller_monotonic",
            "current_position_read_counter_isolation", "epoch_relative_presentation_lag_bounded",
            "position_at_eos_no_runaway",
            "position_query_lifecycle_pause_seek_dead_object_teardown",
            "native_clock_correlation_observation_no_feedback",
            "stop_dispose_release_once",
            "no_product", "no_editor", "no_app", "no_connectsapp", "no_ios",
            "no_streaming", "no_cache", "no_audio_clock_mutator_changes",
            "no_clock_feedback_no_pacing_feedback",
        )

        private const val FAILURE_SOURCE_PATH_REQUIRED = "source_path_required"
        private const val FIRST_AUDIO_TIMEOUT_MS = 3_000L
        private const val WAIT_SLICE_MS = 5L

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    class FailClosed(val reason: String) : Exception(reason)

    private val baselineExpectation = SinkExpectation(audioTracksCreated = 1, oldTrackReleases = 0, deadObjectsInjected = 0L, deadObjectsObserved = 0L)
    private val deadObjectExpectation = SinkExpectation(audioTracksCreated = 2, oldTrackReleases = 1, deadObjectsInjected = 1L, deadObjectsObserved = 1L)

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
            seekTargetSec = (args["seekTargetSec"] as? Number)?.toDouble() ?: DEFAULT_SEEK_TARGET_SEC,
            secondSeekTargetSec = (args["secondSeekTargetSec"] as? Number)?.toDouble() ?: DEFAULT_SECOND_SEEK_TARGET_SEC,
            preSeekHoldWindows = (args["preSeekHoldWindows"] as? Number)?.toInt() ?: DEFAULT_PRE_SEEK_HOLD_WINDOWS,
            maxSeekHoldMs = (args["maxSeekHoldMs"] as? Number)?.toLong()
                ?: VanguardRealtimeAudioPlaybackSession.DEFAULT_MAX_SEEK_HOLD_MS,
            duckGain = (args["duckGain"] as? Number)?.toFloat() ?: DEFAULT_DUCK_GAIN,
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
            "duckGain" to config.duckGain.toDouble(),
            "deadlineMs" to config.deadlineMs,
            "pauseHoldMs" to config.pauseHoldMs,
            "maxPauseHoldMs" to config.maxPauseHoldMs,
            "stopAfterMs" to config.stopAfterMs,
            "deadObjectInjectAfterFrames" to config.deadObjectInjectAfterFrames,
            "seekTargetSec" to config.seekTargetSec,
            "secondSeekTargetSec" to config.secondSeekTargetSec,
            "preSeekHoldWindows" to config.preSeekHoldWindows,
            "maxSeekHoldMs" to config.maxSeekHoldMs,
            "coordinatorThreadId" to Thread.currentThread().id,
        )
        val outcomes = ArrayList<ScenarioOutcome>(11)
        if (config.pauseHoldMs <= 0L || config.pauseHoldMs >= config.maxPauseHoldMs) {
            return buildPayload(false, "invalid_pause_hold:${config.pauseHoldMs}:${config.maxPauseHoldMs}", emptyList(), metrics)
        }
        if (config.deadObjectInjectAfterFrames <= 0L) {
            return buildPayload(false, "invalid_dead_object_inject_after_frames:${config.deadObjectInjectAfterFrames}", emptyList(), metrics)
        }
        if (!(config.seekTargetSec > 0.0) || config.seekTargetSec >= config.maxDurationSec) {
            return buildPayload(false, "invalid_seek_target:${config.seekTargetSec}:${config.maxDurationSec}", emptyList(), metrics)
        }
        if (config.secondSeekTargetSec <= config.seekTargetSec || config.secondSeekTargetSec >= config.maxDurationSec) {
            return buildPayload(
                false,
                "invalid_second_seek_target:${config.secondSeekTargetSec}:${config.seekTargetSec}:${config.maxDurationSec}",
                emptyList(),
                metrics,
            )
        }
        if (config.preSeekHoldWindows <= 0 || config.preSeekHoldWindows > VanguardRealtimeAudioPlaybackSession.MAX_PRE_SEEK_HOLD_WINDOWS) {
            return buildPayload(false, "invalid_pre_seek_hold_windows:${config.preSeekHoldWindows}", emptyList(), metrics)
        }
        if (config.maxSeekHoldMs <= 0L || config.maxSeekHoldMs >= config.deadlineMs) {
            return buildPayload(false, "invalid_max_seek_hold:${config.maxSeekHoldMs}:${config.deadlineMs}", emptyList(), metrics)
        }
        if (!config.duckGain.isFinite() || config.duckGain < 0f || config.duckGain > config.gain) {
            return buildPayload(false, "invalid_duck_gain:${config.duckGain}:${config.gain}", emptyList(), metrics)
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
        if (disposed.get()) return buildPayload(false, "coordinator_disposed", outcomes, metrics)
        // Y9: the ONE forward seek is armed for this scenario only (seam off).
        outcomes += runScenario(SCENARIO_FORWARD_SEEK, config, injectAfterFrames = 0L, seekTargetSec = config.seekTargetSec) { session, outcome ->
            forwardSeekScenario(session, config, outcome)
        }
        if (disposed.get()) return buildPayload(false, "coordinator_disposed", outcomes, metrics)
        // Y10b: repeated forward seek to T1 then T2 (seam off).
        outcomes += runScenario(
            SCENARIO_REPEATED_FORWARD_SEEK,
            config,
            injectAfterFrames = 0L,
            seekTargetSec = config.seekTargetSec,
            secondSeekTargetSec = config.secondSeekTargetSec,
        ) { session, outcome ->
            repeatedForwardSeekScenario(session, config, outcome)
        }
        if (disposed.get()) return buildPayload(false, "coordinator_disposed", outcomes, metrics)
        // Y11b: focus duck / transient pause / auto-resume / noisy terminal pause (seams off).
        outcomes += runScenario(
            SCENARIO_FOCUS_DUCK_TRANSIENT_NOISY,
            config,
            injectAfterFrames = 0L,
            enableAudioFocusResponse = true,
            duckGain = config.duckGain,
        ) { session, outcome ->
            focusDuckTransientNoisyScenario(session, config, outcome)
        }
        if (disposed.get()) return buildPayload(false, "coordinator_disposed", outcomes, metrics)
        // Y11b: focus permanent loss terminal pause (seams off).
        outcomes += runScenario(
            SCENARIO_FOCUS_PERMANENT_LOSS,
            config,
            injectAfterFrames = 0L,
            enableAudioFocusResponse = true,
            duckGain = config.duckGain,
        ) { session, outcome ->
            focusPermanentLossScenario(session, config, outcome)
        }
        if (disposed.get()) return buildPayload(false, "coordinator_disposed", outcomes, metrics)
        // Y12: route change observation only, independently bounded by its own deadline budget.
        outcomes += runScenario(
            SCENARIO_ROUTE_CHANGE_OBSERVATION,
            config,
            injectAfterFrames = 0L,
            enableAudioFocusResponse = true,
            duckGain = config.duckGain,
            enableAudioRoutingResponse = true,
        ) { session, outcome ->
            routeChangeObservationScenario(session, config, outcome)
        }
        if (disposed.get()) return buildPayload(false, "coordinator_disposed", outcomes, metrics)
        // Y12: route disconnect terminal pause / public resume blocked / routing teardown,
        // independently bounded by its own deadline budget (fresh session, never shares
        // the observation scenario's wait window).
        outcomes += runScenario(
            SCENARIO_ROUTE_DISCONNECT_TERMINAL_PAUSE,
            config,
            injectAfterFrames = 0L,
            enableAudioFocusResponse = true,
            duckGain = config.duckGain,
            enableAudioRoutingResponse = true,
        ) { session, outcome ->
            routeDisconnectTerminalPauseScenario(session, config, outcome)
        }
        if (disposed.get()) return buildPayload(false, "coordinator_disposed", outcomes, metrics)
        // Y12: route disconnect while paused by focus policy: focus auto-resume blocked and public resume rejected.
        outcomes += runScenario(
            SCENARIO_ROUTE_DISCONNECT_FOCUS_GAIN_BLOCKED,
            config,
            injectAfterFrames = 0L,
            enableAudioFocusResponse = true,
            duckGain = config.duckGain,
            enableAudioRoutingResponse = true,
        ) { session, outcome ->
            routeDisconnectFocusGainBlockedScenario(session, config, outcome)
        }
        if (disposed.get()) return buildPayload(false, "coordinator_disposed", outcomes, metrics)
        // Y13: presentation clock query surface during active playback -> EOS.
        outcomes += runScenario(SCENARIO_PRESENTATION_CLOCK_QUERY_SURFACE, config, injectAfterFrames = 0L) { session, outcome ->
            presentationClockQuerySurfaceScenario(session, config, outcome)
        }

        val lanes = AndroidRealtimeAudioPlaybackProductionLaneEvaluator.aggregateLanes(outcomes)
        val firstFailure = outcomes.firstOrNull { it.failureReason.isNotBlank() }?.let { "${it.name}:${it.failureReason}" } ?: ""
        val pass = firstFailure.isBlank() && REQUIRED_LANES.all { lanes[it] == true }
        val reason = if (pass) "" else firstFailure.ifBlank { "lane_failed:${REQUIRED_LANES.firstOrNull { lanes[it] != true } ?: "none"}" }
        return buildPayload(pass, reason, outcomes, metrics)
    }

    private fun runScenario(
        name: String,
        config: SmokeConfig,
        injectAfterFrames: Long,
        seekTargetSec: Double = 0.0,
        secondSeekTargetSec: Double = 0.0,
        enableAudioFocusResponse: Boolean = false,
        duckGain: Float = DEFAULT_DUCK_GAIN,
        enableAudioRoutingResponse: Boolean = false,
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
                seekTargetSec = seekTargetSec,
                secondSeekTargetSec = secondSeekTargetSec,
                preSeekHoldWindows = config.preSeekHoldWindows,
                maxSeekHoldMs = config.maxSeekHoldMs,
                context = if (enableAudioFocusResponse) context else null,
                mainHandler = if (enableAudioFocusResponse || enableAudioRoutingResponse) mainHandler else null,
                enableAudioFocusResponse = enableAudioFocusResponse,
                duckGain = duckGain,
                enableAudioRoutingResponse = enableAudioRoutingResponse,
            ),
        )
        outcome.metrics["deadObjectInjectAfterFrames"] = injectAfterFrames
        outcome.metrics["seekTargetSecArmed"] = seekTargetSec
        outcome.metrics["secondSeekTargetSecArmed"] = secondSeekTargetSec
        outcome.metrics["enableAudioFocusResponse"] = enableAudioFocusResponse
        outcome.metrics["duckGainArmed"] = duckGain.toDouble()
        outcome.metrics["enableAudioRoutingResponse"] = enableAudioRoutingResponse
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

    // ── Off-thread position poller helper (Y13/Y14) ────────────────────────
    private fun runWithPositionPoller(
        session: VanguardRealtimeAudioPlaybackSession,
        threadName: String,
        block: () -> Unit,
    ): PresentationClockPollerMetrics {
        val coordinatorThreadId = Thread.currentThread().id
        val running = AtomicBoolean(true)
        var pollerThreadId = -1L
        var pollCount = 0L
        var validCount = 0L
        var regressionCount = 0L
        var frameReadCount = 0L
        var usReadCount = 0L
        var lastFrame = -1L
        var lastUs = -1L
        var minFrame = Long.MAX_VALUE
        var maxFrame = -1L
        var minUs = Long.MAX_VALUE
        var maxUs = -1L
        var pollerError = ""

        val poller = Thread({
            pollerThreadId = Thread.currentThread().id
            while (running.get()) {
                try {
                    val f = session.currentPositionFrames()
                    frameReadCount++
                    val u = session.currentPositionUs()
                    usReadCount++
                    pollCount++
                    if (f >= 0L) {
                        validCount++
                        if (lastFrame >= 0L && f < lastFrame) {
                            regressionCount++
                        }
                        if (f < minFrame) minFrame = f
                        if (f > maxFrame) maxFrame = f
                        lastFrame = f
                    }
                    if (u >= 0L) {
                        if (lastUs >= 0L && u < lastUs) {
                            regressionCount++
                        }
                        if (u < minUs) minUs = u
                        if (u > maxUs) maxUs = u
                        lastUs = u
                    }
                    Thread.sleep(WAIT_SLICE_MS)
                } catch (_: InterruptedException) {
                    break
                } catch (t: Throwable) {
                    pollerError = "exception:${t.javaClass.simpleName}:${t.message}"
                    break
                }
            }
        }, threadName)

        try {
            poller.start()
            block()
        } finally {
            running.set(false)
            poller.interrupt()
            try {
                poller.join(3_000L)
            } catch (_: InterruptedException) {}
        }
        val joined = !poller.isAlive
        require(joined, "poller_not_joined")
        return PresentationClockPollerMetrics(
            pollCount = pollCount,
            validCount = validCount,
            regressionCount = regressionCount,
            frameReadCount = frameReadCount,
            usReadCount = usReadCount,
            lastFrame = lastFrame,
            lastUs = lastUs,
            minFrame = if (minFrame == Long.MAX_VALUE) -1L else minFrame,
            maxFrame = maxFrame,
            minUs = if (minUs == Long.MAX_VALUE) -1L else minUs,
            maxUs = maxUs,
            threadId = pollerThreadId,
            joined = joined,
            error = pollerError,
            coordinatorThreadId = coordinatorThreadId,
        )
    }

    // ── Scenario 1: load/start -> bounded pause -> resume -> EOS ───────────

    private fun playthroughScenario(session: VanguardRealtimeAudioPlaybackSession, config: SmokeConfig, out: ScenarioOutcome) {
        startAndAwaitAudio(session)
        var pauseStartFrames = -1L
        var pauseStartUs = -1L
        var pauseEndFrames = -1L
        var pauseEndUs = -1L
        var holdStartSnap: VanguardRealtimeAudioPlaybackSession.Snapshot? = null
        var holdEndSnap: VanguardRealtimeAudioPlaybackSession.Snapshot? = null
        var completionReached = false

        val pollerMetrics = runWithPositionPoller(session, "Y14PlaythroughPositionPoller") {
            val pauseRes = session.pauseBounded()
            require(pauseRes.accepted && pauseRes.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED, "pause_rejected:${pauseRes.reason}")
            pauseStartFrames = session.currentPositionFrames()
            pauseStartUs = session.currentPositionUs()
            holdStartSnap = session.snapshot()
            val holdStartedAt = SystemClock.elapsedRealtime()
            while (SystemClock.elapsedRealtime() - holdStartedAt < config.pauseHoldMs) {
                require(session.failureReason.isBlank(), "failure_during_hold:${session.failureReason}")
                SystemClock.sleep(WAIT_SLICE_MS)
            }
            pauseEndFrames = session.currentPositionFrames()
            pauseEndUs = session.currentPositionUs()
            holdEndSnap = session.snapshot()
            val resumeRes = session.resume()
            require(resumeRes.accepted && resumeRes.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING, "resume_rejected:${resumeRes.reason}")
            completionReached = session.awaitCompletion(config.deadlineMs)
        }
        require(completionReached, "completion_not_reached:${session.failureReason}")
        val holdStart = holdStartSnap ?: throw FailClosed("hold_start_missing")
        val holdEnd = holdEndSnap ?: throw FailClosed("hold_end_missing")
        val stateAtCompletion = session.currentState
        val stopRes = session.stop()
        require(stopRes.accepted, "stop_rejected:${stopRes.reason}")
        session.dispose()
        session.dispose()
        val final = session.snapshot()
        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluateCommon(final, baselineExpectation, out, Thread.currentThread().id)
        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluatePlaythrough(
            final, holdStart, holdEnd, stateAtCompletion, config, out,
            pauseStartFrames, pauseStartUs, pauseEndFrames, pauseEndUs, pollerMetrics,
        )
    }

    // ── Scenario 3 (Y8b): load/start -> armed synthetic dead object ->
    //    sink-thread recovery -> EOS ───────────────────────────────────────

    private fun deadObjectRecoveryScenario(session: VanguardRealtimeAudioPlaybackSession, config: SmokeConfig, out: ScenarioOutcome) {
        startAndAwaitAudio(session)
        val waitStart = SystemClock.elapsedRealtime()
        var afterRecoverySnap: VanguardRealtimeAudioPlaybackSession.Snapshot? = null
        var afterRecoveryFrames = -1L
        var afterRecoveryUs = -1L
        var completionReached = false

        val pollerMetrics = runWithPositionPoller(session, "Y14DeadObjectPositionPoller") {
            while (true) {
                val snap = session.snapshot()
                require(snap.failureReason.isBlank(), "failure_before_recovery:${snap.failureReason}")
                val k = snap.sink ?: throw FailClosed("sink_missing_before_recovery")
                if (k.deadObjectRecoveryCount == 1) {
                    afterRecoverySnap = snap
                    afterRecoveryFrames = session.currentPositionFrames()
                    afterRecoveryUs = session.currentPositionUs()
                    break
                }
                require(k.exitReason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_RUNNING, "sink_exited_before_recovery:${k.exitReason}")
                require(SystemClock.elapsedRealtime() - waitStart < config.deadlineMs, "recovery_not_observed:${k.framesWrittenToSink}")
                SystemClock.sleep(WAIT_SLICE_MS)
            }
            completionReached = session.awaitCompletion(config.deadlineMs)
        }
        require(completionReached, "completion_not_reached:${session.failureReason}")
        val afterRecovery = afterRecoverySnap ?: throw FailClosed("after_recovery_missing")
        val stateAtCompletion = session.currentState
        val stopRes = session.stop()
        require(stopRes.accepted, "stop_rejected:${stopRes.reason}")
        session.dispose()
        session.dispose()
        val final = session.snapshot()
        val postTeardownFrames = session.currentPositionFrames()
        val postTeardownUs = session.currentPositionUs()
        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluateCommon(final, deadObjectExpectation, out, Thread.currentThread().id)
        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluateDeadObjectRecovery(
            final, afterRecovery, stateAtCompletion, config, out,
            afterRecoveryFrames, afterRecoveryUs, postTeardownFrames, postTeardownUs, pollerMetrics,
        )
    }

    // ── Scenario 4 (Y9): load/start (seek armed) -> ONE forward seek to T
    //    executed by the session -> EOS ───────────────────────────────────

    private fun forwardSeekScenario(session: VanguardRealtimeAudioPlaybackSession, config: SmokeConfig, out: ScenarioOutcome) {
        startAndAwaitAudio(session)
        var afterSeekSnap: VanguardRealtimeAudioPlaybackSession.Snapshot? = null
        var afterSeekFrames = -1L
        var afterSeekUs = -1L
        var completionReached = false

        val pollerMetrics = runWithPositionPoller(session, "Y14ForwardSeekPositionPoller") {
            val armed = session.snapshot()
            val arm = armed.seek
            require(arm.armed && arm.admissionOk && arm.holdPinned && arm.targetFrame > 0L && arm.holdFrame > 0L,
                "seek_not_armed:${arm.armed}:${arm.admissionOk}:${arm.holdPinned}:${arm.targetFrame}:${arm.holdFrame}")
            val seekRes = session.seek(arm.targetFrame)
            require(seekRes.accepted && seekRes.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING, "seek_rejected:${seekRes.reason}")
            afterSeekFrames = session.currentPositionFrames()
            afterSeekUs = session.currentPositionUs()
            afterSeekSnap = session.snapshot()
            require(afterSeekSnap!!.failureReason.isBlank(), "failure_after_seek:${afterSeekSnap!!.failureReason}")
            // ONE forward seek is the proof lane; the session's repeated-seek
            // rejection guard is a non-claim here and is deliberately not exercised.
            completionReached = session.awaitCompletion(config.deadlineMs)
        }
        require(completionReached, "completion_not_reached:${session.failureReason}")
        val afterSeek = afterSeekSnap ?: throw FailClosed("after_seek_missing")
        val stateAtCompletion = session.currentState
        val stopRes = session.stop()
        require(stopRes.accepted, "stop_rejected:${stopRes.reason}")
        session.dispose()
        session.dispose()
        val final = session.snapshot()
        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluateCommon(final, baselineExpectation, out, Thread.currentThread().id)
        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluateForwardSeek(
            final, afterSeek, stateAtCompletion, config, out,
            afterSeekFrames, afterSeekUs, pollerMetrics,
        )
    }

    // ── Scenario 5 (Y10b): load/start (repeated seek armed) -> seek(T1) ->
    //    seek(T2) -> seek(T2) rejected (seek_repeated) -> EOS ─────────────

    private fun repeatedForwardSeekScenario(
        session: VanguardRealtimeAudioPlaybackSession,
        config: SmokeConfig,
        out: ScenarioOutcome,
    ) {
        startAndAwaitAudio(session)
        var armedSnap: VanguardRealtimeAudioPlaybackSession.Snapshot? = null
        var afterFirstSeekSnap: VanguardRealtimeAudioPlaybackSession.Snapshot? = null
        var afterSecondSeekSnap: VanguardRealtimeAudioPlaybackSession.Snapshot? = null
        var afterThirdSeekSnap: VanguardRealtimeAudioPlaybackSession.Snapshot? = null
        var afterSeek1Frames = -1L
        var afterSeek1Us = -1L
        var afterSeek2Frames = -1L
        var afterSeek2Us = -1L
        var afterSeek3Frames = -1L
        var afterSeek3Us = -1L
        var completionReached = false

        val pollerMetrics = runWithPositionPoller(session, "Y14RepeatedSeekPositionPoller") {
            val armed = session.snapshot()
            armedSnap = armed
            val arm = armed.seek
            val fmt = armed.format ?: throw FailClosed("format_missing")
            require(
                arm.armed && arm.admissionOk && arm.holdPinned && arm.targetFrame > 0L && arm.holdFrame > 0L,
                "repeated_seek_not_armed:${arm.armed}:${arm.admissionOk}:${arm.holdPinned}:${arm.targetFrame}:${arm.holdFrame}",
            )
            val target1 = arm.targetFrame
            val target2 = (config.secondSeekTargetSec * fmt.sampleRate).toLong()

            val seekRes1 = session.seek(target1)
            require(seekRes1.accepted && seekRes1.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING, "first_seek_rejected:${seekRes1.reason}")
            afterSeek1Frames = session.currentPositionFrames()
            afterSeek1Us = session.currentPositionUs()
            val afterFirstSeek = session.snapshot()
            afterFirstSeekSnap = afterFirstSeek
            require(afterFirstSeek.failureReason.isBlank(), "failure_after_first_seek:${afterFirstSeek.failureReason}")

            val seekRes2 = session.seek(target2)
            require(seekRes2.accepted && seekRes2.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING, "second_seek_rejected:${seekRes2.reason}")
            afterSeek2Frames = session.currentPositionFrames()
            afterSeek2Us = session.currentPositionUs()
            val afterSecondSeek = session.snapshot()
            afterSecondSeekSnap = afterSecondSeek
            require(afterSecondSeek.failureReason.isBlank(), "failure_after_second_seek:${afterSecondSeek.failureReason}")

            val seekRes3 = session.seek(target2)
            require(
                !seekRes3.accepted && seekRes3.reason == "seek_repeated" && seekRes3.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING,
                "third_seek_not_rejected:${seekRes3.accepted}:${seekRes3.reason}:${seekRes3.state}",
            )
            afterSeek3Frames = session.currentPositionFrames()
            afterSeek3Us = session.currentPositionUs()
            val afterThirdSeek = session.snapshot()
            afterThirdSeekSnap = afterThirdSeek
            require(afterThirdSeek.failureReason.isBlank(), "failure_after_third_seek:${afterThirdSeek.failureReason}")
            require(afterThirdSeek.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING, "state_mutated_after_third_seek:${afterThirdSeek.state}")

            completionReached = session.awaitCompletion(config.deadlineMs)
        }
        require(completionReached, "completion_not_reached:${session.failureReason}")
        val armed = armedSnap ?: throw FailClosed("armed_missing")
        val afterFirstSeek = afterFirstSeekSnap ?: throw FailClosed("after_first_seek_missing")
        val afterSecondSeek = afterSecondSeekSnap ?: throw FailClosed("after_second_seek_missing")
        val afterThirdSeek = afterThirdSeekSnap ?: throw FailClosed("after_third_seek_missing")
        val stateAtCompletion = session.currentState
        val stopRes = session.stop()
        require(stopRes.accepted, "stop_rejected:${stopRes.reason}")
        session.dispose()
        session.dispose()
        val final = session.snapshot()
        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluateCommon(final, baselineExpectation, out, Thread.currentThread().id)
        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluateRepeatedForwardSeek(
            final, armed, afterFirstSeek, afterSecondSeek, afterThirdSeek, stateAtCompletion, config, out,
            afterSeek1Frames, afterSeek1Us, afterSeek2Frames, afterSeek2Us, afterSeek3Frames, afterSeek3Us, pollerMetrics,
        )
    }

    // ── Scenario 6 (Y11b): focus duck -> gain restore -> transient pause ->
    //    auto-resume -> noisy terminal pause -> ignored gain ─────────────

    private fun focusDuckTransientNoisyScenario(
        session: VanguardRealtimeAudioPlaybackSession,
        config: SmokeConfig,
        out: ScenarioOutcome,
    ) {
        startAndAwaitAudio(session)
        val afterStart = session.snapshot()

        // a. post AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK, wait until snapshot.focus.duckAppliedCount == 1,
        //    snapshot.sink.effectiveGain ~= duckGain, focusState ducked, no failure.
        require(session.postSyntheticFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK), "post_focus_duck_failed")
        val afterDuck = awaitFocusSnapshot(session, config.deadlineMs, "focus_duck_not_applied") { snap ->
            val sink = snap.sink ?: return@awaitFocusSnapshot false
            snap.focus.duckAppliedCount == 1L &&
                kotlin.math.abs(sink.effectiveGain - config.duckGain) <= 0.001f &&
                snap.focus.focusState == "ducked"
        }

        // b. post AUDIOFOCUS_GAIN, wait until focus.gainRestoreAppliedCount == 1, sink.effectiveGain ~= gain.
        require(session.postSyntheticFocusChange(AudioManager.AUDIOFOCUS_GAIN), "post_focus_gain_restore_failed")
        val afterRestore = awaitFocusSnapshot(session, config.deadlineMs, "focus_restore_not_applied") { snap ->
            val sink = snap.sink ?: return@awaitFocusSnapshot false
            snap.focus.gainRestoreAppliedCount == 1L &&
                kotlin.math.abs(sink.effectiveGain - config.gain) <= 0.001f
        }

        // c. post AUDIOFOCUS_LOSS_TRANSIENT, wait until focus.pauseTransientAppliedCount == 1,
        //    focusPausedByPolicy true, state PAUSED, transportState PAUSED.
        require(session.postSyntheticFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT), "post_focus_transient_failed")
        val afterTransientPause = awaitFocusSnapshot(session, config.deadlineMs, "focus_transient_pause_not_applied") { snap ->
            snap.focus.pauseTransientAppliedCount == 1L &&
                snap.focus.focusPausedByPolicy &&
                snap.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
                snap.transportState == VanguardRealtimePlaybackTransportStateMachine.State.PAUSED
        }

        // d. post AUDIOFOCUS_GAIN, wait until focus.autoResumeAppliedCount == 1, state PLAYING, transportState PLAYING.
        require(session.postSyntheticFocusChange(AudioManager.AUDIOFOCUS_GAIN), "post_focus_gain_auto_resume_failed")
        val afterAutoResume = awaitFocusSnapshot(session, config.deadlineMs, "focus_transient_resume_not_applied") { snap ->
            snap.focus.autoResumeAppliedCount == 1L &&
                snap.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING &&
                snap.transportState == VanguardRealtimePlaybackTransportStateMachine.State.PLAYING
        }

        // e. postSyntheticBecomingNoisy, wait until focus.pauseNoisyAppliedCount == 1,
        //    terminalNoisyLoss true, state PAUSED, transportState PAUSED.
        require(session.postSyntheticBecomingNoisy(), "post_becoming_noisy_failed")
        val afterNoisy = awaitFocusSnapshot(session, config.deadlineMs, "focus_noisy_pause_not_applied") { snap ->
            snap.focus.pauseNoisyAppliedCount == 1L &&
                snap.focus.terminalNoisyLoss &&
                snap.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
                snap.transportState == VanguardRealtimePlaybackTransportStateMachine.State.PAUSED
        }

        // f. post AUDIOFOCUS_GAIN again; wait until the gain event is actually consumed without auto-resuming.
        require(session.postSyntheticFocusChange(AudioManager.AUDIOFOCUS_GAIN), "post_focus_gain_after_noisy_failed")
        val afterIgnoredGain = awaitFocusSnapshot(
            session,
            config.deadlineMs,
            "focus_noisy_gain_not_consumed_or_auto_resumed",
        ) { snap ->
            snap.focus.eventsDrained >= afterNoisy.focus.eventsDrained + 1L &&
                snap.focus.gainRestoreAppliedCount >= afterRestore.focus.gainRestoreAppliedCount + 1L &&
                snap.focus.autoResumeAppliedCount == 1L &&
                snap.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
                snap.transportState == VanguardRealtimePlaybackTransportStateMachine.State.PAUSED &&
                snap.focus.terminalNoisyLoss
        }

        // Then stop/dispose cleanly.
        val stopRes = session.stop()
        require(stopRes.accepted, "stop_rejected:${stopRes.reason}")
        session.dispose()
        session.dispose()
        val final = session.snapshot()

        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluateFocusDuckTransientNoisy(
            final = final,
            afterStart = afterStart,
            afterDuck = afterDuck,
            afterRestore = afterRestore,
            afterTransientPause = afterTransientPause,
            afterAutoResume = afterAutoResume,
            afterNoisy = afterNoisy,
            afterIgnoredGain = afterIgnoredGain,
            config = config,
            out = out,
            coordinatorThreadId = Thread.currentThread().id,
        )
    }

    // ── Scenario 7 (Y11b): permanent focus loss -> no auto-resume on gain ───

    private fun focusPermanentLossScenario(
        session: VanguardRealtimeAudioPlaybackSession,
        config: SmokeConfig,
        out: ScenarioOutcome,
    ) {
        startAndAwaitAudio(session)
        val afterStart = session.snapshot()

        // post AUDIOFOCUS_LOSS, wait until pausePermanentAppliedCount == 1, terminalPermanentLoss true, state PAUSED, transportState PAUSED;
        require(session.postSyntheticFocusChange(AudioManager.AUDIOFOCUS_LOSS), "post_focus_permanent_loss_failed")
        val afterPermanent = awaitFocusSnapshot(session, config.deadlineMs, "focus_permanent_pause_not_applied") { snap ->
            snap.focus.pausePermanentAppliedCount == 1L &&
                snap.focus.terminalPermanentLoss &&
                snap.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
                snap.transportState == VanguardRealtimePlaybackTransportStateMachine.State.PAUSED
        }

        // post AUDIOFOCUS_GAIN; wait until the gain event is actually consumed without auto-resuming.
        require(session.postSyntheticFocusChange(AudioManager.AUDIOFOCUS_GAIN), "post_focus_gain_after_loss_failed")
        val afterIgnoredGain = awaitFocusSnapshot(
            session,
            config.deadlineMs,
            "focus_permanent_gain_not_consumed_or_auto_resumed",
        ) { snap ->
            snap.focus.eventsDrained >= afterPermanent.focus.eventsDrained + 1L &&
                snap.focus.gainRestoreAppliedCount >= 1L &&
                snap.focus.autoResumeAppliedCount == 0L &&
                snap.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
                snap.transportState == VanguardRealtimePlaybackTransportStateMachine.State.PAUSED &&
                snap.focus.terminalPermanentLoss
        }

        // Then stop/dispose cleanly.
        val stopRes = session.stop()
        require(stopRes.accepted, "stop_rejected:${stopRes.reason}")
        session.dispose()
        session.dispose()
        val final = session.snapshot()

        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluateFocusPermanentLoss(
            final = final,
            afterStart = afterStart,
            afterPermanent = afterPermanent,
            afterIgnoredGain = afterIgnoredGain,
            config = config,
            out = out,
            coordinatorThreadId = Thread.currentThread().id,
        )
    }

    private fun awaitFocusSnapshot(
        session: VanguardRealtimeAudioPlaybackSession,
        timeoutMs: Long,
        timeoutReason: String,
        condition: (VanguardRealtimeAudioPlaybackSession.Snapshot) -> Boolean,
    ): VanguardRealtimeAudioPlaybackSession.Snapshot {
        val start = SystemClock.elapsedRealtime()
        while (SystemClock.elapsedRealtime() - start < timeoutMs) {
            val snap = session.snapshot()
            require(snap.failureReason.isBlank(), "failure_before_focus_event:${snap.failureReason}")
            if (condition(snap)) {
                return snap
            }
            SystemClock.sleep(WAIT_SLICE_MS)
        }
        throw FailClosed(timeoutReason)
    }

    // ── Scenario 8 (Y12): route change observation only, independently bounded ─────────
    //    Never posts a disconnect, so it cannot starve (or be starved by) the terminal
    //    pause proof's own deadline budget in Scenario 9.

    private fun routeChangeObservationScenario(
        session: VanguardRealtimeAudioPlaybackSession,
        config: SmokeConfig,
        out: ScenarioOutcome,
    ) {
        startAndAwaitAudio(session)
        val afterStart = session.snapshot()

        // postSyntheticRouteChanged and await routeChangedAppliedCount increasing by at
        // least 1 from baseline (monotonic, robust to a real OS ROUTE_CHANGED racing the
        // synthetic one and skipping past an exact-equality check) while state/transport
        // remain PLAYING, routingTerminalDisconnect stays false and
        // routeDisconnectAppliedCount stays unchanged (no disconnect ever posted here).
        val routeChangedBaseline = afterStart.routing.routeChangedAppliedCount
        val routeDisconnectBaseline = afterStart.routing.routeDisconnectAppliedCount
        require(session.postSyntheticRouteChanged(), "post_route_changed_failed")
        val afterRouteChange = awaitRoutingSnapshot(
            session,
            config.deadlineMs,
            "route_change_not_applied",
        ) { snap ->
            snap.routing.routeChangedAppliedCount >= routeChangedBaseline + 1L &&
                snap.state == VanguardRealtimeAudioPlaybackSession.State.PLAYING &&
                snap.transportState == VanguardRealtimePlaybackTransportStateMachine.State.PLAYING &&
                !snap.routing.routingTerminalDisconnect &&
                snap.routing.routeDisconnectAppliedCount == routeDisconnectBaseline
        }

        // Stop/dispose cleanly.
        val stopRes = session.stop()
        require(stopRes.accepted, "stop_rejected:${stopRes.reason}")
        session.dispose()
        session.dispose()
        val final = session.snapshot()

        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluateRouteChangeObservation(
            final = final,
            afterStart = afterStart,
            afterRouteChange = afterRouteChange,
            config = config,
            out = out,
            coordinatorThreadId = Thread.currentThread().id,
        )
    }

    // ── Scenario 9 (Y12): route disconnect terminal pause -> public resume rejected ->
    //    routing teardown, independently bounded ─────────────────────────────────────

    private fun routeDisconnectTerminalPauseScenario(
        session: VanguardRealtimeAudioPlaybackSession,
        config: SmokeConfig,
        out: ScenarioOutcome,
    ) {
        startAndAwaitAudio(session)
        val afterStart = session.snapshot()

        // postSyntheticRouteDisconnect (session is PLAYING, so the native session takes
        // the bounded-pause path and bumps routeDisconnectAppliedCount) and await
        // routingTerminalDisconnect=true, routingPausedByPolicy=true,
        // routeDisconnectAppliedCount increasing by at least 1 from baseline (monotonic,
        // same robustness rationale as the observation scenario above), state/transport
        // PAUSED, sink playStateAtPark PAUSED, no failure.
        val routeDisconnectBaseline = afterStart.routing.routeDisconnectAppliedCount
        require(session.postSyntheticRouteDisconnect(), "post_route_disconnect_failed")
        val afterDisconnect = awaitRoutingSnapshot(
            session,
            config.deadlineMs,
            "route_disconnect_not_applied",
        ) { snap ->
            val s = snap.sink
            snap.routing.routingTerminalDisconnect &&
                snap.routing.routingPausedByPolicy &&
                snap.routing.routeDisconnectAppliedCount >= routeDisconnectBaseline + 1L &&
                snap.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
                snap.transportState == VanguardRealtimePlaybackTransportStateMachine.State.PAUSED &&
                s != null &&
                s.playStateAtPark == AudioTrack.PLAYSTATE_PAUSED &&
                snap.failureReason.isBlank()
        }

        // call session.resume() and require accepted=false, reason routing_terminal_disconnect, state PAUSED.
        val resumeRes = session.resume()
        require(
            !resumeRes.accepted &&
                resumeRes.reason == "routing_terminal_disconnect" &&
                resumeRes.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED,
            "resume_after_disconnect_not_rejected:${resumeRes.accepted}:${resumeRes.reason}:${resumeRes.state}",
        )
        val afterRejectedResume = session.snapshot()
        require(afterRejectedResume.failureReason.isBlank(), "failure_after_rejected_resume:${afterRejectedResume.failureReason}")
        require(afterRejectedResume.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED, "state_mutated_after_rejected_resume:${afterRejectedResume.state}")
        require(afterRejectedResume.routing.routingTerminalDisconnect, "routing_terminal_disconnect_cleared_after_rejected_resume")

        // stop/dispose cleanly.
        val stopRes = session.stop()
        require(stopRes.accepted, "stop_rejected:${stopRes.reason}")
        session.dispose()
        session.dispose()
        val final = session.snapshot()

        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluateRouteDisconnectTerminalPause(
            final = final,
            afterStart = afterStart,
            afterDisconnect = afterDisconnect,
            afterRejectedResume = afterRejectedResume,
            resumeRes = resumeRes,
            config = config,
            out = out,
            coordinatorThreadId = Thread.currentThread().id,
        )
    }

    // ── Scenario 10 (Y12): route disconnect while paused by focus policy ->
    //    focus auto-resume blocked -> public resume rejected ────────────────────────────

    private fun routeDisconnectFocusGainBlockedScenario(
        session: VanguardRealtimeAudioPlaybackSession,
        config: SmokeConfig,
        out: ScenarioOutcome,
    ) {
        startAndAwaitAudio(session)
        val afterStart = session.snapshot()

        // 1. post AUDIOFOCUS_LOSS_TRANSIENT and await focusPausedByPolicy=true,
        //    state/transport PAUSED, autoResumeAppliedCount==0.
        require(session.postSyntheticFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT), "post_focus_transient_loss_failed")
        val afterTransientPause = awaitFocusSnapshot(
            session,
            config.deadlineMs,
            "focus_transient_pause_not_applied",
        ) { snap ->
            snap.focus.pauseTransientAppliedCount == 1L &&
                snap.focus.focusPausedByPolicy &&
                snap.focus.autoResumeAppliedCount == 0L &&
                snap.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
                snap.transportState == VanguardRealtimePlaybackTransportStateMachine.State.PAUSED
        }

        // 2. postSyntheticRouteDisconnect while still PAUSED and await
        //    routingTerminalDisconnect=true, state/transport still PAUSED. The session
        //    was already PAUSED (by focus policy) before the disconnect, so the native
        //    session's bounded-pause path never runs and routeDisconnectAppliedCount
        //    never bumps (session code only bumps it from PLAYING); the sticky
        //    routingTerminalDisconnect flag is therefore the only reliable proof signal
        //    here. lastEventTag/lastAction are last-writer-wins fields a later real OS
        //    ROUTE_CHANGED callback can overwrite before this poll observes them, so they
        //    are deliberately not part of this wait condition.
        require(session.postSyntheticRouteDisconnect(), "post_route_disconnect_failed")
        val afterDisconnect = awaitRoutingSnapshot(
            session,
            config.deadlineMs,
            "route_disconnect_while_paused_not_applied",
        ) { snap ->
            snap.routing.routingTerminalDisconnect &&
                snap.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
                snap.transportState == VanguardRealtimePlaybackTransportStateMachine.State.PAUSED &&
                snap.failureReason.isBlank()
        }

        // 3. post AUDIOFOCUS_GAIN and await focus event drained/gain restored but
        //    focusAutoResumeAppliedCount remains 0, focusPausedByPolicy remains true,
        //    routingTerminalDisconnect remains true, state/transport remain PAUSED.
        require(session.postSyntheticFocusChange(AudioManager.AUDIOFOCUS_GAIN), "post_focus_gain_after_disconnect_failed")
        val afterIgnoredGain = awaitRoutingSnapshot(
            session,
            config.deadlineMs,
            "focus_gain_after_disconnect_not_consumed_or_auto_resumed",
        ) { snap ->
            snap.focus.eventsDrained >= afterDisconnect.focus.eventsDrained + 1L &&
                snap.focus.gainRestoreAppliedCount >= 1L &&
                snap.focus.autoResumeAppliedCount == 0L &&
                snap.focus.focusPausedByPolicy &&
                snap.routing.routingTerminalDisconnect &&
                snap.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED &&
                snap.transportState == VanguardRealtimePlaybackTransportStateMachine.State.PAUSED
        }

        // 4. public resume still rejects routing_terminal_disconnect.
        val resumeRes = session.resume()
        require(
            !resumeRes.accepted &&
                resumeRes.reason == "routing_terminal_disconnect" &&
                resumeRes.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED,
            "resume_after_disconnect_not_rejected:${resumeRes.accepted}:${resumeRes.reason}:${resumeRes.state}",
        )
        val afterRejectedResume = session.snapshot()
        require(afterRejectedResume.failureReason.isBlank(), "failure_after_rejected_resume:${afterRejectedResume.failureReason}")
        require(afterRejectedResume.state == VanguardRealtimeAudioPlaybackSession.State.PAUSED, "state_mutated_after_rejected_resume:${afterRejectedResume.state}")
        require(afterRejectedResume.routing.routingTerminalDisconnect, "routing_terminal_disconnect_cleared_after_rejected_resume")

        // 5. stop/dispose cleanly.
        val stopRes = session.stop()
        require(stopRes.accepted, "stop_rejected:${stopRes.reason}")
        session.dispose()
        session.dispose()
        val final = session.snapshot()

        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluateRouteDisconnectFocusGainBlocked(
            final = final,
            afterStart = afterStart,
            afterTransientPause = afterTransientPause,
            afterDisconnect = afterDisconnect,
            afterIgnoredGain = afterIgnoredGain,
            afterRejectedResume = afterRejectedResume,
            resumeRes = resumeRes,
            config = config,
            out = out,
            coordinatorThreadId = Thread.currentThread().id,
        )
    }

    private fun awaitRoutingSnapshot(
        session: VanguardRealtimeAudioPlaybackSession,
        timeoutMs: Long,
        timeoutReason: String,
        condition: (VanguardRealtimeAudioPlaybackSession.Snapshot) -> Boolean,
    ): VanguardRealtimeAudioPlaybackSession.Snapshot {
        val start = SystemClock.elapsedRealtime()
        while (SystemClock.elapsedRealtime() - start < timeoutMs) {
            val snap = session.snapshot()
            require(snap.failureReason.isBlank(), "failure_before_routing_event:${snap.failureReason}")
            if (condition(snap)) {
                return snap
            }
            SystemClock.sleep(WAIT_SLICE_MS)
        }
        throw FailClosed(timeoutReason)
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
        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluateCommon(final, baselineExpectation, out, Thread.currentThread().id)
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

    // ── Scenario 11 (Y13/Y14): load/start -> active playback with off-thread
    //    presentation clock poller -> EOS -> post-teardown latched read ────

    private fun presentationClockQuerySurfaceScenario(
        session: VanguardRealtimeAudioPlaybackSession,
        config: SmokeConfig,
        out: ScenarioOutcome,
    ) {
        startAndAwaitAudio(session)
        var completionReached = false
        val pollerMetrics = runWithPositionPoller(session, "Y13PositionPoller") {
            completionReached = session.awaitCompletion(config.deadlineMs)
        }
        require(completionReached, "completion_not_reached:${session.failureReason}")

        val commandsBefore = session.snapshot().commandsIssued
        val correlation = session.observeClockCorrelation()
        val commandsAfter = session.snapshot().commandsIssued

        val stateAtCompletion = session.currentState
        val stopRes = session.stop()
        require(stopRes.accepted, "stop_rejected:${stopRes.reason}")
        session.dispose()
        session.dispose()
        val final = session.snapshot()
        val postTeardownFrames = session.currentPositionFrames()
        val postTeardownUs = session.currentPositionUs()

        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluateCommon(final, baselineExpectation, out, pollerMetrics.coordinatorThreadId)
        AndroidRealtimeAudioPlaybackProductionLaneEvaluator.evaluatePresentationClockQuerySurface(
            final, pollerMetrics, stateAtCompletion, config, out,
            postTeardownFrames, postTeardownUs,
            correlation, commandsBefore, commandsAfter,
        )
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
            AndroidRealtimeAudioPlaybackProductionSeekMetrics.putSinkSeekMetrics(m, k)
            m["sinkGainRequestCount"] = k.gainRequestCount
            m["sinkGainAppliedCount"] = k.gainAppliedCount
            m["sinkGainRejectedCount"] = k.gainRejectedCount
            m["sinkGainQueueFullCount"] = k.gainQueueFullCount
            m["sinkLastGainRequestSeq"] = k.lastGainRequestSeq
            m["sinkLastGainAppliedSeq"] = k.lastGainAppliedSeq
            m["sinkGainAppliedOnSinkThread"] = k.gainAppliedOnSinkThread
            m["sinkEffectiveGain"] = k.effectiveGain.toDouble()
            m["epochBaseFrame"] = k.epochBaseFrame
            m["framesWrittenAtEpochOpen"] = k.framesWrittenAtEpochOpen
            m["framesReadAtEpochOpen"] = k.framesReadAtEpochOpen
            m["presentationLagSampleCount"] = k.presentationLagSampleCount
            m["presentationLagBoundedSampleCount"] = k.presentationLagBoundedSampleCount
            m["presentationLagExcludedSampleCount"] = k.presentationLagExcludedSampleCount
            m["lastPresentationLagFrames"] = k.lastPresentationLagFrames
            m["minPresentationLagFrames"] = k.minPresentationLagFrames
            m["maxPresentationLagFrames"] = k.maxPresentationLagFrames
            m["presentationLagLowerBoundFrames"] = k.presentationLagLowerBoundFrames
            m["presentationLagUpperBoundFrames"] = k.presentationLagUpperBoundFrames
            m["lastPositionFramesAtPoll"] = k.lastPositionFramesAtPoll
            m["lastPositionUsAtPoll"] = k.lastPositionUsAtPoll
            m["positionAtEosFrames"] = k.positionAtEosFrames
            m["positionAtEosUs"] = k.positionAtEosUs
            m["currentPositionReadsFromWriterThread"] = k.currentPositionReadsFromWriterThread
            m["currentPositionReadsFromOtherThreads"] = k.currentPositionReadsFromOtherThreads
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
        AndroidRealtimeAudioPlaybackProductionSeekMetrics.putSessionSeekMetrics(m, s.seek)
        val f = s.focus
        m["focusEnabled"] = f.enabled
        m["focusControllerRequested"] = f.controllerRequested
        m["focusControllerGranted"] = f.controllerGranted
        m["focusControllerNoisyRegistered"] = f.controllerNoisyRegistered
        m["focusControllerReleased"] = f.controllerReleased
        m["focusMonitorStarted"] = f.monitorStarted
        m["focusMonitorExited"] = f.monitorExited
        m["focusMonitorJoined"] = f.monitorJoined
        m["focusMonitorThreadId"] = f.monitorThreadId
        m["focusEventsEnqueued"] = f.eventsEnqueued
        m["focusEventsDrained"] = f.eventsDrained
        m["focusEventsDropped"] = f.eventsDropped
        m["focusEventsPending"] = f.eventsPending
        m["focusDuckAppliedCount"] = f.duckAppliedCount
        m["focusGainRestoreAppliedCount"] = f.gainRestoreAppliedCount
        m["focusPauseTransientAppliedCount"] = f.pauseTransientAppliedCount
        m["focusPausePermanentAppliedCount"] = f.pausePermanentAppliedCount
        m["focusPauseNoisyAppliedCount"] = f.pauseNoisyAppliedCount
        m["focusPauseDroppedParkAppliedCount"] = f.pauseDroppedParkAppliedCount
        m["focusAutoResumeAppliedCount"] = f.autoResumeAppliedCount
        m["focusUnknownEventCount"] = f.unknownEventCount
        m["focusGainRequestCount"] = f.gainRequestCount
        m["focusGainAppliedCount"] = f.gainAppliedCount
        m["focusGainFailCount"] = f.gainFailCount
        m["focusState"] = f.focusState
        m["focusUserIntentPlaying"] = f.userIntentPlaying
        m["focusPausedByPolicy"] = f.focusPausedByPolicy
        m["focusTerminalPermanentLoss"] = f.terminalPermanentLoss
        m["focusTerminalNoisyLoss"] = f.terminalNoisyLoss
        m["focusLastEventTag"] = f.lastEventTag
        m["focusLastEventSeq"] = f.lastEventSeq
        m["focusLastEventSource"] = f.lastEventSource
        m["focusLastAction"] = f.lastAction
        m["focusLastReason"] = f.lastReason
        val rt = s.routing
        m["routingEnabled"] = rt.enabled
        m["routingControllerAttached"] = rt.controllerAttached
        m["routingControllerReleased"] = rt.controllerReleased
        m["routingAttachCount"] = rt.attachCount
        m["routingDetachCount"] = rt.detachCount
        m["routingLastAttachError"] = rt.lastAttachError
        m["routingLastDetachError"] = rt.lastDetachError
        m["routingMonitorStarted"] = rt.monitorStarted
        m["routingMonitorExited"] = rt.monitorExited
        m["routingMonitorJoined"] = rt.monitorJoined
        m["routingMonitorThreadId"] = rt.monitorThreadId
        m["routingEventsEnqueued"] = rt.eventsEnqueued
        m["routingEventsDrained"] = rt.eventsDrained
        m["routingEventsDropped"] = rt.eventsDropped
        m["routingEventsPending"] = rt.eventsPending
        m["routeChangedAppliedCount"] = rt.routeChangedAppliedCount
        m["routeDisconnectAppliedCount"] = rt.routeDisconnectAppliedCount
        m["routingTerminalDisconnect"] = rt.routingTerminalDisconnect
        m["routingPausedByPolicy"] = rt.routingPausedByPolicy
        m["routingLastEventTag"] = rt.lastEventTag
        m["routingLastEventSeq"] = rt.lastEventSeq
        m["routingLastEventSource"] = rt.lastEventSource
        m["routingLastAction"] = rt.lastAction
        m["routingLastReason"] = rt.lastReason
        return m
    }

    // ── Reporting ──────────────────────────────────────────────────────────

    private fun buildPayload(
        pass: Boolean,
        failureReason: String,
        outcomes: List<ScenarioOutcome>,
        metrics: LinkedHashMap<String, Any?>,
    ): Map<String, Any?> {
        val lanes = if (outcomes.isEmpty()) emptyLanes() else AndroidRealtimeAudioPlaybackProductionLaneEvaluator.aggregateLanes(outcomes)
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
            "details" to "Y8a/Y8b/Y9/Y10b/Y11b/Y12/Y13/Y14/Y15 realtime audio playback production sink/clock/dead-object/seek/repeated-seek/focus/routing/presentation-clock/position-query-lifecycle/native-clock-correlation smoke pass=$pass scenarios=${outcomes.joinToString(",") { it.name }}",
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
