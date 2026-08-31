package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.plugin.common.MethodChannel

/**
 * Android True-DAG P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice D: verification smoke coordinator.
 *
 * Owns [METHOD_NAME] MethodChannel route for validating the native
 * [ClockedAudioTransportCoordinator] caller-clocked, clock-driven audio transport coordinator proof.
 *
 * Honest non-claims (Native Proof Boundary):
 * - Pure in-memory C++ proof only; no AudioTrack/AAudio/OpenSL/Oboe, no OS callbacks,
 *   no production decoder writer, no export reroute, no streaming, no iOS,
 *   no product/editor UI, no internal wall-clock read, no threads, no locks,
 *   no float timebase, no resample, no speed change, no source provider ring seek,
 *   output ring only, unity speed only.
 * - Note: The "no threads" claim applies strictly to the native C++ proof boundary.
 *   The Kotlin diagnostic wrapper dispatches to a background [Thread] to keep
 *   the Flutter UI thread responsive.
 */
class AndroidAudioTransportCoordinatorSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4AudioTransportCoordinator"
        private const val METHOD_NAME = "runAndroidDagPhase4AudioTransportCoordinatorSmoke"
        private const val PROOF_BOUNDARY =
            "native_clock_driven_audio_transport_coordinator_proof_only_no_audio_track_no_os_callback_no_decoder_writer_no_export_reroute_no_streaming_no_ios_no_product_no_internal_wall_clock_read_no_threads_no_locks_no_float_timebase_no_resample_no_speed_change_no_source_provider_ring_seek_output_ring_only_unity_speed_only"

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
                val raw = nativeBridge.runAndroidDagPhase4AudioTransportCoordinatorSmoke()
                val payload = parseResult(raw)
                mainHandler.post { result.success(payload) }
            } catch (t: Throwable) {
                Log.e(TAG, "runAndroidDagPhase4AudioTransportCoordinatorSmoke failed", t)
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
