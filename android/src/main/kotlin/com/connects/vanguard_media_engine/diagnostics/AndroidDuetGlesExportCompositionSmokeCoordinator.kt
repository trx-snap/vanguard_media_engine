package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Diagnostic-only coordinator owning the [METHOD_NAME] MethodChannel route for
 * [AndroidDuetGlesExportCompositionSmokeHarness]'s proof that the production
 * [com.connects.vanguard_media_engine.export.AndroidTimelineVideoEncoder] GLES/MediaCodec
 * export route can carry a pre-matted, alpha-varying RGBA overlay through to a produced
 * MP4. The harness runs entirely on one dedicated background executor thread.
 *
 * Expected failures (busy, disposed, invalid videoPath/outputDir, native exception,
 * malformed JSON) return a fail-shaped map with `pass=false`, never a thrown
 * MethodChannel error.
 */
class AndroidDuetGlesExportCompositionSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VGDuetGlesExportComp"
        private const val METHOD_NAME = "runAndroidDuetGlesExportCompositionSmoke"
        private const val PROOF_BOUNDARY =
            "android_duet_gles_export_composition_rgba_matte_overlay_mediacodec_mp4_only"
        private const val FAIL_MARKER = "ANDROID_DUET_GLES_EXPORT_COMPOSITION_PHYSICAL_FAIL"
        private const val PASS_MARKER = "ANDROID_DUET_GLES_EXPORT_COMPOSITION_PHYSICAL_PASS"
        private const val DEFAULT_LOSSY_RGB_TOLERANCE = 36

        private val GATE_KEYS = listOf(
            "inputValidationOk",
            "sourceMetadataOk",
            "baselineEncodeOk",
            "compositionEncodeOk",
            "compositionFrameCountOk",
            "frameExtractOk",
            "outputMp4Ok",
            "alphaZeroPreservesBackgroundOk",
            "alphaFullForegroundOk",
            "alphaFractionalBlendOk",
            "cleanupOk",
            "canonical",
        )

        private val NON_CLAIMS = listOf(
            "No real ML human matte quality.",
            "No per-frame GL_LUMINANCE mask upload inside export (DEC-V2-105 covers synthetic mask upload/blend separately).",
            "No live CameraX/OES preview lifecycle.",
            "No multi-track audio pass-2 mux or A/V sync.",
            "No ConnectsApp, Universal Editor UI, upload, share, caption, or backend admission wiring.",
            "No GPU delegate/TFLite/MediaPipe production promotion.",
            "No low-end/budget Android proof.",
        )

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vanguard-duet-gles-export-composition-smoke").apply { isDaemon = true }
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
        val videoPath = args?.get("videoPath") as? String
        val outputDir = args?.get("outputDir") as? String
        try {
            executor.execute {
                try {
                    val diagnostics = VanguardDiagnostics()
                    val lifecycleObserver = VanguardLifecycleObserver(diagnostics)
                    val nativeBridge = VanguardNativeBridge(
                        lifecycleObserver = lifecycleObserver,
                        diagnostics = diagnostics,
                        codecAdapter = null,
                    )
                    val harness = AndroidDuetGlesExportCompositionSmokeHarness()
                    val raw = harness.run(videoPath, outputDir, nativeBridge)
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
