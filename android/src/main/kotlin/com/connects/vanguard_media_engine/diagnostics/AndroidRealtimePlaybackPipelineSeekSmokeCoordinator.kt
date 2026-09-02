package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackPipelineSeekCoordinator
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SEEK (Y6c):
 * verification smoke coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route. It runs one
 * [VanguardRealtimePlaybackPipelineSeekCoordinator] (real
 * MediaExtractor/MediaCodec decode thread -> Y5a external ingest seam -> Y1
 * native transport -> phase-controlled non-zero-gain AudioTrack sink
 * thread; single track, pre-seek playback held at a window-aligned anchor
 * -> sink park -> transport pause -> AudioTrack flush on the sink thread ->
 * transport seek while PAUSED -> decoder re-anchor + stale-generation probe
 * -> post-seek pre-roll -> sink unpark -> transport resume -> EOS) on a
 * worker thread against the caller-supplied `sourcePath`, posts the
 * structured payload back on the main handler, and emits the START / JSON
 * / PASS / FAIL markers for log-based physical proof. Without a source
 * path it fails closed with `source_path_required`.
 *
 * Every media/codec/transport/sink lifecycle decision lives in the
 * pipeline coordinator; this class only maps arguments, threads, payloads
 * and logs. [disposeAll] cancels a running pipeline (which tears down on
 * its own threads) and drops any later reply. Diagnostic only: no product,
 * editor, app, iOS, streaming or cache wiring and no C++ changes.
 */
class AndroidRealtimePlaybackPipelineSeekSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardY6cSeek"
        const val METHOD_NAME = "runRealtimePlaybackPipelineSeekSmoke"

        const val START_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_SMOKE_START"
        const val JSON_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_JSON"
        const val PASS_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_PHYSICAL_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_PHYSICAL_SMOKE_FAIL"

        const val PROOF_BOUNDARY = VanguardRealtimePlaybackPipelineSeekCoordinator.PROOF_BOUNDARY

        private const val FAILURE_SOURCE_PATH_REQUIRED = "source_path_required"

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val active = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)

    @Volatile
    private var activePipeline: VanguardRealtimePlaybackPipelineSeekCoordinator? = null

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
                "P4_REALTIME_PLAYBACK_PIPELINE_SEEK_SMOKE_BUSY",
                "$METHOD_NAME: diagnostic already running",
                null,
            )
            return true
        }
        val config = VanguardRealtimePlaybackPipelineSeekCoordinator.Config(
            sourcePath = sourcePath,
            maxDurationSec = (args["maxDurationSec"] as? Number)?.toDouble() ?: 3.0,
            maxFramesPerMix = (args["maxFramesPerMix"] as? Number)?.toInt() ?: 256,
            baseVolume = (args["baseVolume"] as? Number)?.toFloat() ?: 0.5f,
            deadlineMs = (args["deadlineMs"] as? Number)?.toLong() ?: 30_000L,
            seekTargetSec = (args["seekTargetSec"] as? Number)?.toDouble()
                ?: VanguardRealtimePlaybackPipelineSeekCoordinator.DEFAULT_SEEK_TARGET_SEC,
            preSeekHoldWindows = (args["preSeekHoldWindows"] as? Number)?.toInt()
                ?: VanguardRealtimePlaybackPipelineSeekCoordinator.DEFAULT_PRE_SEEK_HOLD_WINDOWS,
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

    private fun runSmoke(config: VanguardRealtimePlaybackPipelineSeekCoordinator.Config, result: MethodChannel.Result) {
        val replied = AtomicBoolean(false)
        Thread({
            val pipeline = VanguardRealtimePlaybackPipelineSeekCoordinator()
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
        }, "Y6cPipelineSeekSmoke").start()
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

    private fun buildPayload(outcome: VanguardRealtimePlaybackPipelineSeekCoordinator.Result): Map<String, Any?> {
        val marker = if (outcome.pass) PASS_MARKER else FAIL_MARKER
        val failureReason = if (outcome.pass) "" else outcome.failureReason.ifBlank { "smoke_failed" }
        return mapOf(
            "pass" to outcome.pass,
            "status" to outcome.status,
            "marker" to marker,
            "proofBoundary" to outcome.proofBoundary,
            "nativeProofBoundary" to outcome.proofBoundary,
            "failureReason" to failureReason,
            "details" to "Y6c realtime playback pipeline seek harness pass=${outcome.pass}",
            "lanes" to LinkedHashMap<String, Any?>(outcome.lanes),
            "metrics" to LinkedHashMap<String, Any?>(outcome.metrics),
            "lastError" to if (outcome.pass) null else failureReason,
            "raw" to "${outcome.raw};marker=$marker",
        )
    }

    private fun buildFailurePayload(reason: String): Map<String, Any?> {
        val lanes = linkedMapOf<String, Any?>()
        for (name in VanguardRealtimePlaybackPipelineSeekCoordinator.REQUIRED_LANES) lanes[name] = false
        lanes[VanguardRealtimePlaybackPipelineSeekCoordinator.LANE_PROOF_BOUNDARY] = false
        lanes[VanguardRealtimePlaybackPipelineSeekCoordinator.LANE_CANONICAL] = false
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
