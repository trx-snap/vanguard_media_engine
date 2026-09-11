package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Diagnostic-only coordinator owning the [METHOD_NAME] MethodChannel route for
 * [AndroidDuetGlesDynamicMaskExportSmokeHarness]'s proof that Android can upload a
 * time-varying single-channel GL_LUMINANCE mask per encoded frame, blend foreground/background
 * in GLES, encode to MP4 via MediaCodec input surface, and verify decoded pixels.
 *
 * Runs entirely on one dedicated background executor thread. Expected failures (busy, disposed,
 * invalid outputDir, native exception) return a fail-shaped map with `pass=false`, never a thrown
 * MethodChannel error.
 */
class AndroidDuetGlesDynamicMaskExportSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VGDuetGlesDynMask"
        private const val METHOD_NAME = "runAndroidDuetGlesDynamicMaskExportSmoke"
        private const val PROOF_BOUNDARY =
            "android_duet_gles_dynamic_mask_export_per_frame_upload_mediacodec_mp4_only"
        private const val FAIL_MARKER = "ANDROID_DUET_GLES_DYNAMIC_MASK_EXPORT_PHYSICAL_FAIL"
        private const val PASS_MARKER = "ANDROID_DUET_GLES_DYNAMIC_MASK_EXPORT_PHYSICAL_PASS"
        private const val DEFAULT_LOSSY_RGB_TOLERANCE = 36

        private val GATE_KEYS = listOf(
            "inputValidationOk",
            "codecSetupOk",
            "eglSetupOk",
            "shaderProgramOk",
            "dynamicMaskUploadOk",
            "encodedMp4Ok",
            "frameExtractOk",
            "alphaZeroBackgroundOk",
            "alphaFullForegroundOk",
            "alphaFractionalBlendOk",
            "frameVariationOk",
            "cleanupOk",
            "canonical",
        )

        private val NON_CLAIMS = listOf(
            "No live ML human matte quality.",
            "No live CameraX/OES lifecycle.",
            "No production Duet recording/export branch.",
            "No source-video decoder composition.",
            "No multi-track audio/A-V sync.",
            "No ConnectsApp/Universal Editor/upload wiring.",
            "No low-end Android proof.",
        )

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vanguard-duet-gles-dynamic-mask-export-smoke").apply { isDaemon = true }
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
     * Releases the background executor. Safe to call more than once.
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
        val outputDir = args?.get("outputDir") as? String
        try {
            executor.execute {
                try {
                    val harness = AndroidDuetGlesDynamicMaskExportSmokeHarness()
                    val raw = harness.run(outputDir)
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
            active.set(false)
            Log.e(TAG, "$METHOD_NAME could not be scheduled", t)
            result.success(makeFailedMap("executor_rejected:${t.javaClass.simpleName}"))
        }
    }

    private fun parseResult(raw: Map<String, Any?>): Map<String, Any?> {
        val map = raw.toMutableMap()
        val pass = map["pass"] as? Boolean ?: false
        map["pass"] = pass
        if (map["status"] !is String) map["status"] = if (pass) "PASS" else "FAIL"
        if (map["proofBoundary"] !is String) map["proofBoundary"] = PROOF_BOUNDARY
        if (map["marker"] !is String) map["marker"] = if (pass) PASS_MARKER else FAIL_MARKER
        if (map["failureReason"] !is String) map["failureReason"] = ""

        val rawGates = map["gates"] as? Map<*, *>
        val filledGates = LinkedHashMap<String, Boolean>()
        for (key in GATE_KEYS) {
            filledGates[key] = (rawGates?.get(key) as? Boolean) ?: false
        }
        map["gates"] = filledGates

        map["lossyRgbTolerance"] = (map["lossyRgbTolerance"] as? Int) ?: DEFAULT_LOSSY_RGB_TOLERANCE
        map["maxDelta"] = (map["maxDelta"] as? Int) ?: -1
        map["sampleCount"] = (map["sampleCount"] as? Int) ?: 0
        map["mismatches"] = (map["mismatches"] as? List<*>) ?: emptyList<String>()
        if (map["details"] !is Map<*, *>) map["details"] = emptyMap<String, Any?>()
        if (map["nonClaims"] !is List<*>) map["nonClaims"] = NON_CLAIMS
        return map
    }

    private fun makeFailedMap(reason: String): Map<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        map["pass"] = false
        map["status"] = "FAIL"
        map["marker"] = FAIL_MARKER
        map["proofBoundary"] = PROOF_BOUNDARY
        map["failureReason"] = reason
        val gates = LinkedHashMap<String, Boolean>()
        for (key in GATE_KEYS) gates[key] = false
        map["gates"] = gates
        map["lossyRgbTolerance"] = DEFAULT_LOSSY_RGB_TOLERANCE
        map["maxDelta"] = -1
        map["sampleCount"] = 0
        map["mismatches"] = emptyList<String>()
        map["details"] = mapOf("reason" to reason)
        map["nonClaims"] = NON_CLAIMS
        return map
    }
}
