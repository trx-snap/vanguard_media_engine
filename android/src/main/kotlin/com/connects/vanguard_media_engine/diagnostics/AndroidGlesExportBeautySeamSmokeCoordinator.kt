package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * P5-GLES-EXPORT-OES-2D-BEAUTY-RESOLVE-READINESS: diagnostic-only
 * coordinator owning the [METHOD_NAME] MethodChannel route for
 * [AndroidGlesExportBeautySeamSmokeHarness]'s proof that a real MediaCodec
 * decode -> SurfaceTexture -> GL_TEXTURE_EXTERNAL_OES frame, resolved to
 * GL_TEXTURE_2D RGBA8 on its own current-verified ES3 EGL pbuffer context,
 * still routes into the caller-current native
 * `GlesBeautyV2Compositor::DrawBeautyV2` seam.
 *
 * The harness creates and destroys its own EGL context(s), GL textures, and
 * MediaCodec/SurfaceTexture/MediaExtractor lifecycle entirely on one
 * dedicated background executor thread (never the main thread, never a
 * thread that already holds an EGL context). Expected failures (busy,
 * disposed, invalid videoPath, native exception, malformed JSON) return a
 * fail-shaped map with `pass=false`, never a thrown MethodChannel error.
 *
 * Diagnostic only: no production GLES Beauty export route/session/backend-
 * selector/encoder change.
 */
class AndroidGlesExportBeautySeamSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VGGlesExportBeautySeam"
        private const val METHOD_NAME = "runAndroidDagPhase5GlesExportBeautySeamSmoke"
        private const val PROOF_BOUNDARY =
            "native_gles_export_beauty_seam_caller_current_context_diagnostic_only_no_production_export"
        private const val FAIL_MARKER =
            "ANDROID_DAG_PHASE5_GLES_EXPORT_BEAUTY_SEAM_PHYSICAL_SMOKE_FAIL"

        private val GATE_KEYS = listOf(
            "eglSetupOk",
            "es3ContextVerifiedOk",
            "invalidArgumentsRejectedOk",
            "decodeOk",
            "updateTexImageOk",
            "oesResolveOk",
            "resolvedNonUniformOk",
            "seamCallOk",
            "beautyDeltaOk",
            "strongIntensityDeltaOk",
            "stateRestoredOk",
            "cleanupOk",
            "canonical",
        )

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vanguard-p5-gles-export-beauty-seam-smoke").apply { isDaemon = true }
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
     * in-flight run owns its EGL context(s)/textures/MediaCodec on its own
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
        val videoPath = args?.get("videoPath") as? String
        try {
            executor.execute {
                try {
                    val harness = AndroidGlesExportBeautySeamSmokeHarness()
                    val raw = harness.run(videoPath)
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
        map["details"] = mapOf("reason" to reason)
        return map
    }
}
