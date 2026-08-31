package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.plugin.common.MethodChannel

/**
 * Android True-DAG P4-AUDIO-GRAPH-TRANSPORT-CLOCK: verification smoke coordinator.
 *
 * Owns [METHOD_NAME] MethodChannel route for validating the native synchronous
 * graph-edge-routed audio window scheduler proof.
 *
 * Honest non-claims:
 * - Pure in-memory C++ graph edge routing, exact frame window math, PTS derivation,
 *   microsecond drift prevention, timeline gating, mixed PCM checksum verification,
 *   silence windows, stale generation rejection, sample rate mismatch rejection,
 *   and capacity guard micro-proof only.
 * - Does not claim audible or realtime audio playback.
 * - Does not use AudioTrack, AAudio, OpenSL, or Oboe.
 * - Does not use threads, locks, ring buffers, queues, or backpressure.
 * - Does not perform file IO.
 * - Does not use MediaCodec or MediaExtractor.
 * - Does not add C++ -> Kotlin callbacks.
 * - Does not reroute export.
 * - Does not touch app/editor/product UI.
 * - Does not stream.
 * - Does not touch iOS.
 * - Does not close P4-AUDIO-GRAPH-TRANSPORT-CLOCK or P4-AUDIO-MIXBUS.
 */
class AndroidAudioGraphTransportClockSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4AudioTransportClock"
        private const val METHOD_NAME = "runAndroidDagPhase4AudioGraphTransportClockSmoke"
        private const val PROOF_BOUNDARY =
            "native_graph_edge_routed_audio_window_scheduler_proof_only_no_realtime_no_audio_track_no_playback_no_queue_no_backpressure_no_threads_no_export_reroute_no_product"

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
                val raw = nativeBridge.runAndroidDagPhase4AudioGraphTransportClockSmoke()
                val payload = parseResult(raw)
                mainHandler.post { result.success(payload) }
            } catch (t: Throwable) {
                Log.e(TAG, "runAndroidDagPhase4AudioGraphTransportClockSmoke failed", t)
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
