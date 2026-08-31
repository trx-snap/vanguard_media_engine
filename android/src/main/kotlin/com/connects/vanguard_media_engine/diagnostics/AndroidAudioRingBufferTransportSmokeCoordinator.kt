package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.plugin.common.MethodChannel

/**
 * Android True-DAG P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice B: verification smoke coordinator.
 *
 * Owns [METHOD_NAME] MethodChannel route for validating the native lock-free SPSC
 * audio ring-buffer transport primitive + diagnostic AudioSampleProvider adapter proof.
 *
 * Honest non-claims:
 * - SPSC primitive + diagnostic provider only; no realtime/audible playback,
 *   no AudioTrack/AAudio/OpenSL/Oboe, no realtime clock ownership,
 *   no production decoder writer, no MediaCodec/MediaExtractor,
 *   no C++->Kotlin callback, no export reroute, no streaming/cache,
 *   no app/editor/product UI, no iOS, does not close P4-AUDIO-GRAPH-TRANSPORT-CLOCK
 *   or P4-AUDIO-MIXBUS.
 */
class AndroidAudioRingBufferTransportSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4AudioRingBufferTransport"
        private const val METHOD_NAME = "runAndroidDagPhase4AudioRingBufferTransportSmoke"
        private const val PROOF_BOUNDARY =
            "native_spsc_audio_ring_buffer_transport_primitive_and_diagnostic_provider_adapter_only_no_realtime_no_audio_track_no_playback_no_clock_ownership_no_decoder_writer_no_export_reroute_no_streaming_no_ios_no_product"

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
                val raw = nativeBridge.runAndroidDagPhase4AudioRingBufferTransportSmoke()
                val payload = parseResult(raw)
                mainHandler.post { result.success(payload) }
            } catch (t: Throwable) {
                Log.e(TAG, "runAndroidDagPhase4AudioRingBufferTransportSmoke failed", t)
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
