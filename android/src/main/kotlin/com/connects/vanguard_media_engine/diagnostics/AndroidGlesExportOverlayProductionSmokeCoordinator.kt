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
 * P5-GLES-EXPORT-OVERLAY-PRODUCTION-ROUTE-A: diagnostic-only coordinator owning the
 * [METHOD_NAME] MethodChannel route for
 * [AndroidGlesExportOverlayProductionSmokeHarness]'s verification that the production
 * [com.connects.vanguard_media_engine.export.AndroidTimelineVideoEncoder] directly routes
 * overlay rendering through GLES via [VanguardNativeBridge] on caller-current context.
 *
 * The harness runs entirely on one dedicated background executor thread.
 * Expected failures (busy, disposed, invalid videoPath/stickerPath/outputDir,
 * native exception, malformed JSON) return a fail-shaped map with `pass=false`,
 * never a thrown MethodChannel error.
 */
class AndroidGlesExportOverlayProductionSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VGGlesExportOverlayProd"
        private const val METHOD_NAME = "runAndroidDagPhase5GlesExportOverlayProductionSmoke"
        private const val PROOF_BOUNDARY =
            "production_android_timeline_gles_overlay_export_forced_encoder_route_a"
        private const val FAIL_MARKER =
            "ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_PRODUCTION_PHYSICAL_SMOKE_FAIL"
        private const val PASS_MARKER =
            "ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_PRODUCTION_PHYSICAL_SMOKE_PASS"

        private val GATE_KEYS = listOf(
            "inputValidationOk",
            "sourceMetadataOk",
            "baselineEncodeOk",
            "overlayEncodeOk",
            "overlayFrameCountOk",
            "frameExtractOk",
            "pixelDeltaOk",
            "missingBridgeRejectedOk",
            "stillImageOverlayEncodeOk",
            "reversedVideoOverlayEncodeOk",
            "glMajorVersionOk",
            "cleanupOk",
            "canonical",
        )

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vanguard-p5-gles-export-overlay-prod-smoke").apply { isDaemon = true }
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
        val stickerPath = args?.get("stickerPath") as? String
        val outputDir = args?.get("outputDir") as? String
        val reversedVideoPath = args?.get("reversedVideoPath") as? String
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
                    val harness = AndroidGlesExportOverlayProductionSmokeHarness()
                    val raw = harness.run(videoPath, stickerPath, outputDir, nativeBridge, reversedVideoPath)
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
