package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.plugin.common.MethodChannel

/**
 * Android True-DAG P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice E: verification smoke coordinator.
 *
 * Owns [METHOD_NAME] MethodChannel route for validating the native
 * [AudioDecoderRingWriter] decoder-to-source-ring ingest seam proof.
 *
 * Honest non-claims (Native Proof Boundary):
 * - Pure in-memory C++ proof only; no MediaCodec, no MediaExtractor,
 *   no AudioTrack, no AAudio, no OpenSL, no Oboe, no realtime playback,
 *   no OS callbacks, no threads, no locks, no file IO, no export reroute,
 *   no streaming, no iOS, no product/editor UI, no DecodedAudioPcmSourceNode wiring,
 *   no scheduler integration, no resample, no audible output.
 *   Writer-local EOS only.
 * - Note: The "no threads" claim applies strictly to the native C++ proof boundary.
 *   The Kotlin diagnostic wrapper dispatches to a background [Thread] to keep
 *   the Flutter UI thread responsive.
 */
class AndroidAudioDecoderRingWriterSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4AudioDecoderRingWriter"
        private const val METHOD_NAME = "runAndroidDagPhase4AudioDecoderRingWriterSmoke"
        private const val PROOF_BOUNDARY =
            "native_audio_decoder_ring_writer_to_spsc_source_ring_ingest_proof_only_no_mediacodec_no_mediaextractor_no_audio_track_no_aaudio_no_opensl_no_oboe_no_realtime_playback_no_os_callback_no_threads_no_locks_no_file_io_no_export_reroute_no_streaming_no_ios_no_product_no_source_node_wiring_no_scheduler_integration_no_resample_no_audible_output_writer_local_eos_only"

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
                val raw = nativeBridge.runAndroidDagPhase4AudioDecoderRingWriterSmoke()
                val payload = parseResult(raw)
                mainHandler.post { result.success(payload) }
            } catch (t: Throwable) {
                Log.e(TAG, "runAndroidDagPhase4AudioDecoderRingWriterSmoke failed", t)
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
