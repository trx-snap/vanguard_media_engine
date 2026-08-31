package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.plugin.common.MethodChannel

/**
 * Android True-DAG P4-AUDIO-GRAPH-TOPOLOGY: verification smoke coordinator.
 *
 * Owns [METHOD_NAME] MethodChannel route for validating that AudioMixBusNode
 * participates in the C++ DAG topology / evaluatePlayhead gating pattern and that
 * a synthetic PCM mix is reachable only after successful graph evaluation.
 *
 * Honest non-claims:
 * - Proves DecodedAudioPcmSourceNode timeline gating, PTS mapping, and GraphAudioScheduler
 *   renderWindow() isActiveAt gating (schedulerTimelineGatingOk) only; AudioMixBusNode remains
 *   always-active and the generic parser below carries the new lane without special handling.
 * - Does not claim audible or realtime audio playback.
 * - Does not claim C++ graph buffer transport / PCM transport; evaluatePlayhead moves no PCM.
 * - Does not claim AudioTrack integration.
 * - Does not claim Pass-2 export now runs through Graph.
 * - Does not close P4-AUDIO-MIXBUS or Phase 4.
 */
class AndroidAudioGraphTopologySmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4AudioGraphTopo"
        private const val METHOD_NAME = "runAndroidDagPhase4AudioGraphTopologySmoke"
        private const val PROOF_BOUNDARY =
            "native_audio_mix_bus_graph_topology_and_graph_gated_diagnostic_mix_only_no_realtime_no_playback_no_audio_track_no_graph_buffer_transport_no_product"

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        if (method != METHOD_NAME) {
            return false
        }
        runSmoke(result)
        return true
    }

    private fun runSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val diagnostics = VanguardDiagnostics()
                val nativeBridge = VanguardNativeBridge(
                    lifecycleObserver = VanguardLifecycleObserver(diagnostics),
                    diagnostics = diagnostics,
                    codecAdapter = null,
                )
                val raw = nativeBridge.runAndroidDagPhase4AudioGraphTopologySmoke()
                val payload = parseResult(raw)
                mainHandler.post { result.success(payload) }
            } catch (t: Throwable) {
                Log.e(TAG, "runAndroidDagPhase4AudioGraphTopologySmoke failed", t)
                mainHandler.post {
                    result.success(
                        makeFailedMap("exception:${t.javaClass.simpleName}:${t.message}")
                    )
                }
            }
        }.start()
    }

    private fun parseResult(raw: String): Map<String, Any?> {
        val rawMap = mutableMapOf<String, String>()
        val metrics = mutableMapOf<String, Any?>()
        for (part in raw.split(";")) {
            val eq = part.indexOf('=')
            if (eq <= 0) continue
            val key = part.substring(0, eq)
            val value = part.substring(eq + 1)
            rawMap[key] = value

            when {
                value == "true" -> metrics[key] = true
                value == "false" -> metrics[key] = false
                value.toLongOrNull() != null -> metrics[key] = value.toLong()
                value.toDoubleOrNull() != null -> metrics[key] = value.toDouble()
                else -> metrics[key] = value
            }
        }
        val pass = rawMap["status"] == "PASS"
        val lastError = if (pass) null else rawMap["reason"] ?: "diagnostic_failed"
        return mapOf(
            "pass" to pass,
            "proofBoundary" to (rawMap["proofBoundary"] ?: PROOF_BOUNDARY),
            "raw" to rawMap,
            "metrics" to metrics,
            "lastError" to lastError,
        )
    }

    private fun makeFailedMap(reason: String): Map<String, Any?> = mapOf(
        "pass" to false,
        "proofBoundary" to PROOF_BOUNDARY,
        "raw" to mapOf("status" to "FAIL", "reason" to reason),
        "metrics" to mapOf("status" to "FAIL", "reason" to reason),
        "lastError" to reason,
    )
}
