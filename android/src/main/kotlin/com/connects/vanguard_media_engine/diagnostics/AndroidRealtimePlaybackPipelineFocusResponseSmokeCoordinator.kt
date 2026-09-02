package com.connects.vanguard_media_engine.diagnostics

import android.content.Context
import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackPipelineFocusResponseCoordinator
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-FOCUS-RESPONSE (Y6d):
 * verification smoke coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route. It runs one
 * [VanguardRealtimePlaybackPipelineFocusResponseCoordinator] (three
 * sequential scenarios: EOS_COMPLETION, BECOMING_NOISY_TERMINAL,
 * PERMANENT_LOSS_TERMINAL; each with its own real MediaExtractor/MediaCodec
 * decode thread -> Y5a external ingest seam -> Y1 native transport ->
 * non-zero-gain AudioTrack sink thread that applies synthetic focus /
 * becoming-noisy events) on a worker thread against the caller-supplied
 * `sourcePath`, posts the payload back on the main handler and emits the
 * START / JSON / PASS / FAIL markers. Without a source path it fails closed
 * with `source_path_required`. Diagnostic only: no product, editor, app,
 * iOS, streaming or cache wiring and no C++ changes.
 */
class AndroidRealtimePlaybackPipelineFocusResponseSmokeCoordinator(
    private val context: Context,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardY6dFocus"
        const val METHOD_NAME = "runRealtimePlaybackPipelineFocusResponseSmoke"

        const val START_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_FOCUS_RESPONSE_SMOKE_START"
        const val JSON_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_FOCUS_RESPONSE_JSON"
        const val PASS_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_FOCUS_RESPONSE_PHYSICAL_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_FOCUS_RESPONSE_PHYSICAL_SMOKE_FAIL"

        const val PROOF_BOUNDARY = VanguardRealtimePlaybackPipelineFocusResponseCoordinator.PROOF_BOUNDARY

        private const val FAILURE_SOURCE_PATH_REQUIRED = "source_path_required"

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val active = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)

    @Volatile
    private var activePipeline: VanguardRealtimePlaybackPipelineFocusResponseCoordinator? = null

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
            result.error("P4_REALTIME_PLAYBACK_PIPELINE_FOCUS_RESPONSE_SMOKE_BUSY", "$METHOD_NAME: diagnostic already running", null)
            return true
        }
        val config = VanguardRealtimePlaybackPipelineFocusResponseCoordinator.Config(
            sourcePath = sourcePath,
            maxDurationSec = (args["maxDurationSec"] as? Number)?.toDouble() ?: 3.0,
            maxFramesPerMix = (args["maxFramesPerMix"] as? Number)?.toInt() ?: 256,
            baseVolume = (args["baseVolume"] as? Number)?.toFloat() ?: 0.5f,
            duckVolume = (args["duckVolume"] as? Number)?.toFloat() ?: 0.1f,
            deadlineMs = (args["deadlineMs"] as? Number)?.toLong() ?: 60_000L,
            pauseHoldMs = (args["pauseHoldMs"] as? Number)?.toLong()
                ?: VanguardRealtimePlaybackPipelineFocusResponseCoordinator.DEFAULT_PAUSE_HOLD_MS,
            phaseFrames = (args["phaseFrames"] as? Number)?.toLong()
                ?: VanguardRealtimePlaybackPipelineFocusResponseCoordinator.DEFAULT_PHASE_FRAMES,
        )
        runSmoke(config, result)
        return true
    }

    fun disposeAll() {
        disposed.set(true)
        try {
            activePipeline?.cancel()
        } catch (_: Throwable) {}
        activePipeline = null
    }

    private fun runSmoke(config: VanguardRealtimePlaybackPipelineFocusResponseCoordinator.Config, result: MethodChannel.Result) {
        val replied = AtomicBoolean(false)
        Thread({
            val pipeline = VanguardRealtimePlaybackPipelineFocusResponseCoordinator(context, mainHandler)
            activePipeline = pipeline
            try {
                Log.i(TAG, START_MARKER)
                val outcome = pipeline.run(config)
                val payload = buildPayload(outcome)
                logOutcome(payload)
                postReply(replied, result, payload)
            } catch (t: Throwable) {
                Log.e(TAG, "$METHOD_NAME uncaught failure", t)
                val failPayload = buildFailurePayload("uncaught_exception:${t.javaClass.simpleName}:${t.message}")
                logOutcome(failPayload)
                postReply(replied, result, failPayload)
            } finally {
                try {
                    pipeline.dispose()
                } catch (_: Throwable) {}
                if (activePipeline === pipeline) activePipeline = null
                active.set(false)
            }
        }, "Y6dPipelineFocusResponseSmoke").start()
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

    private fun buildPayload(outcome: VanguardRealtimePlaybackPipelineFocusResponseCoordinator.Result): Map<String, Any?> {
        val marker = if (outcome.pass) PASS_MARKER else FAIL_MARKER
        val failureReason = if (outcome.pass) "" else outcome.failureReason.ifBlank { "smoke_failed" }
        return mapOf(
            "pass" to outcome.pass,
            "status" to outcome.status,
            "marker" to marker,
            "proofBoundary" to outcome.proofBoundary,
            "nativeProofBoundary" to outcome.proofBoundary,
            "failureReason" to failureReason,
            "details" to "Y6d realtime playback pipeline focus response harness pass=${outcome.pass}",
            "lanes" to LinkedHashMap<String, Any?>(outcome.lanes),
            "metrics" to LinkedHashMap<String, Any?>(outcome.metrics),
            "lastError" to if (outcome.pass) null else failureReason,
            "raw" to "${outcome.raw};marker=$marker",
        )
    }

    private fun buildFailurePayload(reason: String): Map<String, Any?> {
        val lanes = linkedMapOf<String, Any?>()
        for (name in VanguardRealtimePlaybackPipelineFocusResponseCoordinator.REQUIRED_LANES) lanes[name] = false
        lanes[VanguardRealtimePlaybackPipelineFocusResponseCoordinator.LANE_CANONICAL] = false
        return mapOf(
            "pass" to false,
            "status" to "fail",
            "marker" to FAIL_MARKER,
            "proofBoundary" to PROOF_BOUNDARY,
            "nativeProofBoundary" to PROOF_BOUNDARY,
            "failureReason" to reason,
            "details" to reason,
            "lanes" to lanes,
            "metrics" to mapOf("failureReason" to reason),
            "lastError" to reason,
            "raw" to "pass=false;status=fail;marker=$FAIL_MARKER;reason=$reason",
        )
    }
}
