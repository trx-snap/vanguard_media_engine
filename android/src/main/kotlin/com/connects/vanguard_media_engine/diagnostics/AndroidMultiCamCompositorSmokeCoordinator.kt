package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.plugin.common.MethodChannel

/**
 * Android True-DAG P3-MULTICAM-NODE: verification smoke coordinator.
 *
 * Owns [METHOD_NAME] MethodChannel route for validating the native C++
 * MultiCamCompositorNode topology and PiP/split layout math. Runs the
 * diagnostic on a background thread and posts a parsed result map back to
 * [mainHandler]. Expected failures return a map with pass=false, never a
 * thrown MethodChannel error.
 */
class AndroidMultiCamCompositorSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP3MultiCamNode"
        private const val METHOD_NAME = "runAndroidDagPhase3MultiCamCompositorSmoke"
        private const val PROOF_BOUNDARY =
            "native_multicam_compositor_node_topology_and_layout_math_only_no_render_no_camera_no_recording"

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
                val raw = nativeBridge.runAndroidDagPhase3MultiCamCompositorSmoke()
                val payload = parseResult(raw)
                mainHandler.post { result.success(payload) }
            } catch (t: Throwable) {
                Log.e(TAG, "runAndroidDagPhase3MultiCamCompositorSmoke failed", t)
                mainHandler.post {
                    result.success(
                        makeFailedMap("exception:${t.javaClass.simpleName}:${t.message}")
                    )
                }
            }
        }.start()
    }

    private fun parseResult(raw: String): Map<String, Any?> {
        val metrics = mutableMapOf<String, String>()
        for (part in raw.split(";")) {
            val eq = part.indexOf('=')
            if (eq <= 0) continue
            metrics[part.substring(0, eq)] = part.substring(eq + 1)
        }
        val pass = metrics["status"] == "PASS"
        val decision = if (pass) "pass" else "fail"
        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "decision" to decision,
            "proofBoundary" to (metrics["proofBoundary"] ?: PROOF_BOUNDARY),
            "metrics" to metrics,
        )
    }

    private fun makeFailedMap(reason: String): Map<String, Any?> = mapOf(
        "pass" to false,
        "raw" to "status=FAIL;reason=$reason",
        "decision" to "fail",
        "proofBoundary" to PROOF_BOUNDARY,
        "metrics" to mapOf("reason" to reason),
    )
}
