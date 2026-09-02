package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackPipelineTimestampStabilizationCoordinator
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-TIMESTAMP-STABILIZATION
 * (Y6f): verification smoke coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route. It runs one
 * [VanguardRealtimePlaybackPipelineTimestampStabilizationCoordinator] (two
 * sequential scenarios: FORWARD_PLAYTHROUGH_TIMESTAMP,
 * DEAD_OBJECT_EPOCH_RESET_TIMESTAMP; each with its own real
 * MediaExtractor/MediaCodec decode thread -> Y5a external ingest seam -> Y1
 * native transport -> non-zero-gain AudioTrack sink thread that owns every
 * AudioTrack call including getTimestamp(), polls at most once per drain
 * pass after the write returned, keeps a per-epoch unsigned-32
 * framePosition baseline and recovers the one synthetic dead object) on a
 * worker thread against the caller-supplied `sourcePath`, posts the payload
 * back on the main handler and emits the START / JSON / PASS / FAIL
 * markers. Without a source path it fails closed with
 * `source_path_required`. Diagnostic only: timestamp telemetry is inert; no
 * HAL/output latency, presentation clock, A/V sync, timestamp-derived
 * position, clock ownership, getTimestamp availability SLA or drift
 * correction claim; synthetic error injection only; no product, editor,
 * app, iOS, streaming or cache wiring and no C++/JNI changes.
 */
class AndroidRealtimePlaybackPipelineTimestampStabilizationSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardY6fTimestamp"
        const val METHOD_NAME = "runRealtimePlaybackPipelineTimestampStabilizationSmoke"

        const val START_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_TIMESTAMP_STABILIZATION_SMOKE_START"
        const val JSON_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_TIMESTAMP_STABILIZATION_JSON"
        const val PASS_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_TIMESTAMP_STABILIZATION_PHYSICAL_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_TIMESTAMP_STABILIZATION_PHYSICAL_SMOKE_FAIL"

        const val PROOF_BOUNDARY = VanguardRealtimePlaybackPipelineTimestampStabilizationCoordinator.PROOF_BOUNDARY

        private const val FAILURE_SOURCE_PATH_REQUIRED = "source_path_required"

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val active = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)

    @Volatile
    private var activePipeline: VanguardRealtimePlaybackPipelineTimestampStabilizationCoordinator? = null

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
            result.error(
                "P4_REALTIME_PLAYBACK_PIPELINE_TIMESTAMP_STABILIZATION_SMOKE_BUSY",
                "$METHOD_NAME: diagnostic already running",
                null,
            )
            return true
        }
        val config = VanguardRealtimePlaybackPipelineTimestampStabilizationCoordinator.Config(
            sourcePath = sourcePath,
            maxDurationSec = (args["maxDurationSec"] as? Number)?.toDouble() ?: 3.0,
            maxFramesPerMix = (args["maxFramesPerMix"] as? Number)?.toInt() ?: 256,
            baseVolume = (args["baseVolume"] as? Number)?.toFloat() ?: 0.5f,
            deadlineMs = (args["deadlineMs"] as? Number)?.toLong() ?: 60_000L,
            phaseFrames = (args["phaseFrames"] as? Number)?.toLong()
                ?: VanguardRealtimePlaybackPipelineTimestampStabilizationCoordinator.DEFAULT_PHASE_FRAMES,
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

    private fun runSmoke(config: VanguardRealtimePlaybackPipelineTimestampStabilizationCoordinator.Config, result: MethodChannel.Result) {
        val replied = AtomicBoolean(false)
        Thread({
            val pipeline = VanguardRealtimePlaybackPipelineTimestampStabilizationCoordinator()
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
        }, "Y6fPipelineTimestampStabilizationSmoke").start()
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

    private fun buildPayload(outcome: VanguardRealtimePlaybackPipelineTimestampStabilizationCoordinator.Result): Map<String, Any?> {
        val marker = if (outcome.pass) PASS_MARKER else FAIL_MARKER
        val failureReason = if (outcome.pass) "" else outcome.failureReason.ifBlank { "smoke_failed" }
        return mapOf(
            "pass" to outcome.pass,
            "status" to outcome.status,
            "marker" to marker,
            "proofBoundary" to outcome.proofBoundary,
            "nativeProofBoundary" to outcome.proofBoundary,
            "failureReason" to failureReason,
            "details" to "Y6f realtime playback pipeline timestamp stabilization harness pass=${outcome.pass}",
            "lanes" to LinkedHashMap<String, Any?>(outcome.lanes),
            "metrics" to LinkedHashMap<String, Any?>(outcome.metrics),
            "lastError" to if (outcome.pass) null else failureReason,
            "raw" to "${outcome.raw};marker=$marker",
        )
    }

    private fun buildFailurePayload(reason: String): Map<String, Any?> {
        val lanes = linkedMapOf<String, Any?>()
        for (name in VanguardRealtimePlaybackPipelineTimestampStabilizationCoordinator.REQUIRED_LANES) lanes[name] = false
        lanes[VanguardRealtimePlaybackPipelineTimestampStabilizationCoordinator.LANE_CANONICAL] = false
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
