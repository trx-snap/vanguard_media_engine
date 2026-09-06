package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * P5-GLES-EXPORT-DUAL-OES-TRANSITION-READINESS: diagnostic-only coordinator
 * owning the [METHOD_NAME] MethodChannel route for
 * [AndroidGlesDualOesTransitionSmokeHarness]'s proof that two real
 * MediaCodec decodes, each feeding its own SurfaceTexture-backed
 * GL_TEXTURE_EXTERNAL_OES texture on one caller-owned, current-verified ES3
 * EGL pbuffer context, still route into the caller-current native
 * `GlesTimelineTransitionCompositor::drawTransition` seam.
 *
 * The harness creates and destroys its own EGL context, GL textures, and
 * dual MediaCodec/SurfaceTexture/MediaExtractor lifecycle entirely on one
 * dedicated background executor thread (never the main thread, never a
 * thread that already holds an EGL context). Expected failures (busy,
 * disposed, invalid clip paths, native exception, malformed JSON) return a
 * fail-shaped map with `pass=false`, never a thrown MethodChannel error.
 *
 * Diagnostic only: no production export route/session/backend-selector/
 * encoder change.
 */
class AndroidGlesDualOesTransitionSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VGGlesDualOesTransition"
        private const val METHOD_NAME = "runAndroidDagPhase5GlesDualOesTransitionSmoke"
        private const val PROOF_BOUNDARY =
            "diagnostic_dual_mediacodec_surfacetexture_oes_to_gles_transition_compositor_no_export"
        private const val FAIL_MARKER =
            "ANDROID_DAG_PHASE5_GLES_DUAL_OES_TRANSITION_PHYSICAL_SMOKE_FAIL"

        private val GATE_KEYS = AndroidGlesDualOesTransitionSmokeHarness.GATE_KEYS

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vanguard-p5-gles-dual-oes-transition-smoke").apply { isDaemon = true }
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
        runSmoke(args, result)
        return true
    }

    /**
     * Releases the background executor. Safe to call more than once. An
     * in-flight run owns its EGL context/textures/dual MediaCodec on its own
     * thread and tears them down in the harness before returning.
     */
    fun disposeAll() {
        if (disposed.compareAndSet(false, true)) {
            executor.shutdown()
        }
    }

    private fun runSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        if (disposed.get()) {
            result.success(makeFailedMap("coordinator_disposed"))
            return
        }
        if (!active.compareAndSet(false, true)) {
            result.success(makeFailedMap("smoke_already_active"))
            return
        }
        val fromClipPath = args?.get("fromClipPath") as? String
        val toClipPath = args?.get("toClipPath") as? String
        try {
            executor.execute {
                try {
                    val harness = AndroidGlesDualOesTransitionSmokeHarness()
                    val raw = harness.run(fromClipPath, toClipPath)
                    val payload = parseResult(raw)
                    mainHandler.post { result.success(payload) }
                } catch (t: Throwable) {
                    Log.e(TAG, "$METHOD_NAME failed", t)
                    mainHandler.post {
                        result.success(
                            makeFailedMap("exception:${t.javaClass.simpleName}:${t.message}"),
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

    private fun parseResult(raw: Map<String, Any?>): Map<String, Any?> {
        val map = raw.toMutableMap()
        if (map["pass"] !is Boolean) map["pass"] = false
        if (map["status"] !is String) map["status"] = if (map["pass"] == true) "PASS" else "FAIL"
        if (map["proofBoundary"] !is String) map["proofBoundary"] = PROOF_BOUNDARY
        if (map["marker"] !is String) map["marker"] = FAIL_MARKER
        if (map["failureReason"] !is String) map["failureReason"] = ""
        for (key in GATE_KEYS) {
            if (map[key] !is Boolean) map[key] = false
        }
        if (map["glMajorVersion"] !is Int) map["glMajorVersion"] = 0
        if (map["fromPtsUs"] !is Long) map["fromPtsUs"] = -1L
        if (map["toPtsUs"] !is Long) map["toPtsUs"] = -1L
        if (map["nativeRaw"] !is String) map["nativeRaw"] = ""
        if (map["details"] !is Map<*, *>) map["details"] = emptyMap<String, Any?>()
        return map
    }

    private fun makeFailedMap(reason: String): Map<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        map["pass"] = false
        map["status"] = "FAIL"
        map["marker"] = FAIL_MARKER
        map["proofBoundary"] = PROOF_BOUNDARY
        map["failureReason"] = reason
        for (key in GATE_KEYS) {
            map[key] = false
        }
        map["glMajorVersion"] = 0
        map["fromPtsUs"] = -1L
        map["toPtsUs"] = -1L
        map["nativeRaw"] = ""
        map["details"] = mapOf("reason" to reason)
        return map
    }
}
