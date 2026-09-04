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
 *
 * Also owns [BRIDGE_METHOD_NAME], the P3-MULTICAM-NODE-DART-TO-NATIVE-
 * LAYOUT-MAP-BRIDGE diagnostic: it parses a Dart layout map (the
 * `layoutMode`/`pipLayout`/`splitLayout` shape shared by
 * VGLivePreviewConfig.toMap() and VGDualCameraDescriptor.toMap()), fails
 * closed with pass=false for a malformed non-map or non-numeric required
 * nested field, and otherwise forwards primitive strings/doubles to the
 * native bridge translation diagnostic.
 */
class AndroidMultiCamCompositorSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP3MultiCamNode"
        private const val METHOD_NAME = "runAndroidDagPhase3MultiCamCompositorSmoke"
        private const val PROOF_BOUNDARY =
            "native_multicam_compositor_node_topology_and_layout_math_only_no_render_no_camera_no_recording"

        private const val BRIDGE_METHOD_NAME =
            "runAndroidDagPhase3MultiCamDescriptorBridgeSmoke"
        private const val BRIDGE_PROOF_BOUNDARY =
            "dart_layout_map_to_native_multicam_layout_diagnostic_only_no_camera_no_render_no_recording_no_product"

        fun ownsMethod(method: String): Boolean =
            method == METHOD_NAME || method == BRIDGE_METHOD_NAME
    }

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        when (method) {
            METHOD_NAME -> {
                runSmoke(result)
                return true
            }
            BRIDGE_METHOD_NAME -> {
                runDescriptorBridgeSmoke(args, result)
                return true
            }
            else -> return false
        }
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

    private fun parseResult(
        raw: String,
        defaultProofBoundary: String = PROOF_BOUNDARY,
    ): Map<String, Any?> {
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
            "proofBoundary" to (metrics["proofBoundary"] ?: defaultProofBoundary),
            "metrics" to metrics,
        )
    }

    private fun makeFailedMap(
        reason: String,
        proofBoundary: String = PROOF_BOUNDARY,
    ): Map<String, Any?> = mapOf(
        "pass" to false,
        "raw" to "status=FAIL;reason=$reason",
        "decision" to "fail",
        "proofBoundary" to proofBoundary,
        "metrics" to mapOf("status" to "FAIL", "reason" to reason),
    )

    /** Primitive fields parsed out of a Dart layout map, ready for the native bridge call. */
    private data class DescriptorBridgeRequest(
        val layoutMode: String,
        val pipAnchor: String,
        val pipCenterX: Double,
        val pipCenterY: Double,
        val pipWidthFraction: Double,
        val pipAspectRatio: Double,
        val pipMarginFraction: Double,
        val pipCornerRadius: Double,
        val pipOpacity: Double,
        val splitDirection: String,
        val splitRatio: Double,
    )

    /**
     * Parses the `layoutMode`/`pipLayout`/`splitLayout` Dart layout-map shape.
     * Returns null (fail closed) if [args], `pipLayout`, or `splitLayout` is
     * not a map, or if any required nested numeric field is missing or not a
     * [Number]. `layoutMode`/`anchor`/`direction` strings are passed through
     * as-is (falling back to an empty string when missing or non-string) so
     * the native side applies the canonical unknown-value fallback.
     */
    private fun parseDescriptorBridgeRequest(args: Map<*, *>?): DescriptorBridgeRequest? {
        if (args == null) return null
        val pipLayout = args["pipLayout"] as? Map<*, *> ?: return null
        val splitLayout = args["splitLayout"] as? Map<*, *> ?: return null

        val pipCenterX = (pipLayout["centerX"] as? Number)?.toDouble() ?: return null
        val pipCenterY = (pipLayout["centerY"] as? Number)?.toDouble() ?: return null
        val pipWidthFraction = (pipLayout["widthFraction"] as? Number)?.toDouble() ?: return null
        val pipAspectRatio = (pipLayout["aspectRatio"] as? Number)?.toDouble() ?: return null
        val pipMarginFraction = (pipLayout["marginFraction"] as? Number)?.toDouble() ?: return null
        val pipCornerRadius = (pipLayout["cornerRadius"] as? Number)?.toDouble() ?: return null
        val pipOpacity = (pipLayout["opacity"] as? Number)?.toDouble() ?: return null
        val splitRatio = (splitLayout["splitRatio"] as? Number)?.toDouble() ?: return null

        return DescriptorBridgeRequest(
            layoutMode = args["layoutMode"] as? String ?: "",
            pipAnchor = pipLayout["anchor"] as? String ?: "",
            pipCenterX = pipCenterX,
            pipCenterY = pipCenterY,
            pipWidthFraction = pipWidthFraction,
            pipAspectRatio = pipAspectRatio,
            pipMarginFraction = pipMarginFraction,
            pipCornerRadius = pipCornerRadius,
            pipOpacity = pipOpacity,
            splitDirection = splitLayout["direction"] as? String ?: "",
            splitRatio = splitRatio,
        )
    }

    private fun runDescriptorBridgeSmoke(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        val request = parseDescriptorBridgeRequest(args)
        if (request == null) {
            result.success(
                makeFailedMap("malformed_descriptor_layout_map", BRIDGE_PROOF_BOUNDARY)
            )
            return
        }
        Thread {
            try {
                val diagnostics = VanguardDiagnostics()
                val nativeBridge = VanguardNativeBridge(
                    lifecycleObserver = VanguardLifecycleObserver(diagnostics),
                    diagnostics = diagnostics,
                    codecAdapter = null,
                )
                val raw = nativeBridge.runAndroidDagPhase3MultiCamDescriptorBridgeSmoke(
                    request.layoutMode,
                    request.pipAnchor,
                    request.pipCenterX,
                    request.pipCenterY,
                    request.pipWidthFraction,
                    request.pipAspectRatio,
                    request.pipMarginFraction,
                    request.pipCornerRadius,
                    request.pipOpacity,
                    request.splitDirection,
                    request.splitRatio,
                )
                val payload = parseResult(raw, BRIDGE_PROOF_BOUNDARY)
                mainHandler.post { result.success(payload) }
            } catch (t: Throwable) {
                Log.e(TAG, "runAndroidDagPhase3MultiCamDescriptorBridgeSmoke failed", t)
                mainHandler.post {
                    result.success(
                        makeFailedMap(
                            "exception:${t.javaClass.simpleName}:${t.message}",
                            BRIDGE_PROOF_BOUNDARY,
                        )
                    )
                }
            }
        }.start()
    }
}
