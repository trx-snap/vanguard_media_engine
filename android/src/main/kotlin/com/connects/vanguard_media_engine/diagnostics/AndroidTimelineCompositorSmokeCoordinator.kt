package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P5-COMPOSITOR-TRANS (sub-slice NODE-TOPOLOGY-MATH):
 * verification smoke coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for validating the native C++
 * `VGTimelineCompositorNode` topology and timeline clip overlap / transition
 * progress math. Runs the diagnostic on a single background executor and
 * posts a parsed result map back through [mainHandler]. Expected failures
 * (busy, native exception, malformed JSON) return a fail-shaped map with
 * `pass=false`, never a thrown MethodChannel error.
 *
 * Diagnostic only: no render, no decode, no export session, no product UI.
 */
class AndroidTimelineCompositorSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP5TimelineCompositor"
        private const val METHOD_NAME = "runAndroidDagPhase5TimelineCompositorSmoke"
        private const val PROOF_BOUNDARY =
            "native_vg_timeline_compositor_node_topology_and_transition_math_only_no_render_no_decode"
        private const val FAIL_MARKER =
            "ANDROID_DAG_PHASE5_TIMELINE_COMPOSITOR_NODE_TOPOLOGY_MATH_PHYSICAL_SMOKE_FAIL"

        private val GATE_KEYS = listOf(
            "kindOk",
            "typeOk",
            "inputPortCountOk",
            "outputPortCountOk",
            "portIdsOk",
            "hardCutOk",
            "crossfadeStartOk",
            "crossfadeMidOk",
            "crossfadeEndOk",
            "slideLeftMidOk",
            "wipeLeftMidOk",
            "speedMappingOk",
            "outsideTimelineOk",
            "invalidTransitionIgnoredOk",
            "zeroDurationSafeOk",
            "overflowSafeOk",
        )

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vanguard-p5-timeline-compositor-smoke").apply { isDaemon = true }
    }
    private val active = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)

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

    /** Releases the background executor. Safe to call more than once. */
    fun disposeAll() {
        if (disposed.compareAndSet(false, true)) {
            executor.shutdown()
        }
    }

    private fun runSmoke(result: MethodChannel.Result) {
        if (disposed.get()) {
            result.success(makeFailedMap("coordinator_disposed"))
            return
        }
        if (!active.compareAndSet(false, true)) {
            result.success(makeFailedMap("smoke_already_active"))
            return
        }
        try {
            executor.execute {
                try {
                    val diagnostics = VanguardDiagnostics()
                    val nativeBridge = VanguardNativeBridge(
                        lifecycleObserver = VanguardLifecycleObserver(diagnostics),
                        diagnostics = diagnostics,
                        codecAdapter = null,
                    )
                    val raw = nativeBridge.runAndroidDagPhase5TimelineCompositorSmoke()
                    val payload = parseResult(raw)
                    mainHandler.post { result.success(payload) }
                } catch (t: Throwable) {
                    Log.e(TAG, "$METHOD_NAME failed", t)
                    mainHandler.post {
                        result.success(
                            makeFailedMap("exception:${t.javaClass.simpleName}:${t.message}")
                        )
                    }
                } finally {
                    active.set(false)
                }
            }
        } catch (t: Throwable) {
            // Executor rejected the task (e.g. disposed concurrently).
            active.set(false)
            Log.e(TAG, "$METHOD_NAME could not be scheduled", t)
            result.success(makeFailedMap("executor_rejected:${t.javaClass.simpleName}"))
        }
    }

    private fun parseResult(raw: String): Map<String, Any?> {
        val json = try {
            JSONObject(raw)
        } catch (t: Throwable) {
            Log.e(TAG, "native result is not a JSON object", t)
            return makeFailedMap("native_result_not_json", raw)
        }
        val map = jsonObjectToMap(json).toMutableMap()
        map["raw"] = raw
        // Defensive defaults so the Dart side always sees the contract keys.
        if (map["pass"] !is Boolean) map["pass"] = false
        if (map["status"] !is String) map["status"] = if (map["pass"] == true) "PASS" else "FAIL"
        if (map["proofBoundary"] !is String) map["proofBoundary"] = PROOF_BOUNDARY
        if (map["marker"] !is String) map["marker"] = FAIL_MARKER
        if (map["failureReason"] !is String) map["failureReason"] = ""
        for (key in GATE_KEYS) {
            if (map[key] !is Boolean) map[key] = false
        }
        if (map["allNativeLanesPass"] !is Boolean) {
            map["allNativeLanesPass"] = GATE_KEYS.all { map[it] == true }
        }
        if (map["details"] !is Map<*, *>) map["details"] = emptyMap<String, Any?>()
        return map
    }

    private fun jsonObjectToMap(obj: JSONObject): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            out[key] = convertJsonValue(obj.opt(key))
        }
        return out
    }

    private fun jsonArrayToList(arr: JSONArray): List<Any?> {
        val out = ArrayList<Any?>(arr.length())
        for (i in 0 until arr.length()) {
            out.add(convertJsonValue(arr.opt(i)))
        }
        return out
    }

    private fun convertJsonValue(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> jsonObjectToMap(value)
        is JSONArray -> jsonArrayToList(value)
        is Boolean, is Int, is Long, is Double, is String -> value
        is Number -> value.toDouble()
        else -> value.toString()
    }

    private fun makeFailedMap(reason: String, raw: String? = null): Map<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        map["pass"] = false
        map["status"] = "FAIL"
        map["marker"] = FAIL_MARKER
        map["proofBoundary"] = PROOF_BOUNDARY
        map["failureReason"] = reason
        for (key in GATE_KEYS) {
            map[key] = false
        }
        map["allNativeLanesPass"] = false
        map["details"] = mapOf("reason" to reason)
        map["raw"] = raw ?: "{\"pass\":false,\"status\":\"FAIL\",\"failureReason\":\"$reason\"}"
        return map
    }
}
