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
 * Android True-DAG P3-MULTICAM-NODE-VULKAN-DYNAMIC-DESCRIPTOR-SPATIAL-RENDER:
 * verification smoke coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for the native diagnostic that
 * proves a caller-supplied Dart layout descriptor's primitive fields
 * (layoutMode, pipAnchor, pipCenterX, pipCenterY, pipWidthFraction,
 * pipAspectRatio, pipMarginFraction, splitDirection, splitRatio) drive
 * `vanguard::compositors::ComputeMultiCamLayout()` and, through it, native
 * Vulkan spatial rendering for that single call -- combining the strict
 * descriptor-string resolution policy of the GLES dynamic-descriptor route
 * with the synchronous, self-contained-resource shape of the static Vulkan
 * spatial route. This coordinator only parses the *shape* of the MethodChannel
 * arguments (every field present and of the expected Dart type); an
 * unrecognized layoutMode/pipAnchor/splitDirection *value* is still native's
 * job to reject, strictly, before any Vulkan object is created. Native
 * creates and destroys its own temporary VkInstance/VkDevice/VkQueue/
 * VkCommandPool and synthetic sampled images on the calling thread, so this
 * coordinator runs on a single dedicated background executor (never the main
 * thread) and posts a parsed result map back through [mainHandler]. Expected
 * failures (busy, malformed/missing arguments, native exception, malformed
 * JSON) return a fail-shaped map with `pass=false`, never a thrown
 * MethodChannel error. A device without a usable Vulkan driver is reported by
 * native as `status=UNSUPPORTED` and passed through unchanged.
 *
 * Diagnostic only: no camera, no GLES, no OES import, no opacity, no corner
 * radius, no recording, no export, no production VulkanBackend mutation,
 * and no product/editor UI.
 */
class AndroidMulticamDynamicDescriptorSpatialVulkanRenderSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP3MultiCamDynDescVulkan"
        private const val METHOD_NAME =
            "runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke"
        private const val PROOF_BOUNDARY =
            "native_multicam_dynamic_descriptor_spatial_vulkan_render_readback_only_no_gles_no_camera_no_oes_no_ahb_no_opacity_no_corner_radius_no_recording_no_product"
        private const val FAIL_MARKER =
            "ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_VULKAN_RENDER_FAIL"

        private val GATE_KEYS = listOf(
            "descriptorParseOk",
            "descriptorRejectedBeforeVulkanOk",
            "vulkanSetupOk",
            "syntheticImportOk",
            "layoutConvertOk",
            "renderReadbackOk",
            "helperResourcesReleasedOk",
            "diagnosticTeardownOk",
        )

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vanguard-p3-multicam-dyndesc-vulkan-smoke").apply { isDaemon = true }
    }
    private val active = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    private data class ParsedVulkanDescriptorArgs(
        val layoutMode: String,
        val pipAnchor: String,
        val pipCenterX: Double,
        val pipCenterY: Double,
        val pipWidthFraction: Double,
        val pipAspectRatio: Double,
        val pipMarginFraction: Double,
        val splitDirection: String,
        val splitRatio: Double,
    )

    // Shape/type parsing only -- no enum-value validation, no clamping. Every
    // field must be present and of the exact expected type; anything else
    // (missing key, wrong type, non-numeric field) returns null so the
    // caller fails closed before any native call. Native itself performs the
    // strict layoutMode/pipAnchor/splitDirection enum-value resolution.
    private fun parseDescriptorArgs(args: Map<*, *>?): ParsedVulkanDescriptorArgs? {
        if (args == null) return null
        val layoutMode = args["layoutMode"] as? String ?: return null
        val pipAnchor = args["pipAnchor"] as? String ?: return null
        val splitDirection = args["splitDirection"] as? String ?: return null
        val pipCenterX = (args["pipCenterX"] as? Number)?.toDouble() ?: return null
        val pipCenterY = (args["pipCenterY"] as? Number)?.toDouble() ?: return null
        val pipWidthFraction = (args["pipWidthFraction"] as? Number)?.toDouble() ?: return null
        val pipAspectRatio = (args["pipAspectRatio"] as? Number)?.toDouble() ?: return null
        val pipMarginFraction = (args["pipMarginFraction"] as? Number)?.toDouble() ?: return null
        val splitRatio = (args["splitRatio"] as? Number)?.toDouble() ?: return null
        return ParsedVulkanDescriptorArgs(
            layoutMode = layoutMode,
            pipAnchor = pipAnchor,
            pipCenterX = pipCenterX,
            pipCenterY = pipCenterY,
            pipWidthFraction = pipWidthFraction,
            pipAspectRatio = pipAspectRatio,
            pipMarginFraction = pipMarginFraction,
            splitDirection = splitDirection,
            splitRatio = splitRatio,
        )
    }

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        if (method != METHOD_NAME) {
            return false
        }
        val parsed = parseDescriptorArgs(args)
        if (parsed == null) {
            result.success(makeFailedMap("malformed_or_missing_descriptor_args"))
            return true
        }
        runSmoke(parsed, result)
        return true
    }

    /**
     * Releases the background executor. Safe to call more than once. An
     * in-flight native run finishes on its own thread and destroys its own
     * Vulkan device/images before returning.
     */
    fun disposeAll() {
        if (disposed.compareAndSet(false, true)) {
            executor.shutdown()
        }
    }

    private fun runSmoke(parsed: ParsedVulkanDescriptorArgs, result: MethodChannel.Result) {
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
                    val raw =
                        nativeBridge.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
                            parsed.layoutMode,
                            parsed.pipAnchor,
                            parsed.pipCenterX,
                            parsed.pipCenterY,
                            parsed.pipWidthFraction,
                            parsed.pipAspectRatio,
                            parsed.pipMarginFraction,
                            parsed.splitDirection,
                            parsed.splitRatio,
                        )
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
        if (map["nativeAllLanesPass"] !is Boolean) {
            map["nativeAllLanesPass"] = map["allNativeLanesPass"]
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
        map["nativeAllLanesPass"] = false
        map["details"] = mapOf("reason" to reason)
        map["raw"] = raw ?: "{\"pass\":false,\"status\":\"FAIL\",\"failureReason\":\"$reason\"}"
        return map
    }
}
