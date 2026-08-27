package com.connects.vanguard_media_engine.diagnostics

import android.graphics.SurfaceTexture
import android.hardware.HardwareBuffer
import android.os.Build
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver

object AndroidGlesDagEvalSmokeHarness {
    private const val TAG = "VanguardDagSmoke"

    // ── Phase 1-Unit AV: Android GLES DAG playhead evaluation + multi-frame render smoke ──
    private const val RESULT_MARKER_PHASE1AV = "ANDROID_DAG_PHASE1AV_NATIVE_RESULT"

    fun runGlesDagEvalRenderSmoke(
        width: Int = 64,
        height: Int = 64,
        frameCount: Int = 30,
        frameDurationUs: Long = 33333L,
    ): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
        var raw = glesDagEvalRenderSmokeFailure("not_run", width, height, frameCount)

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesDagEvalRenderSmokeFailure("api_below_26", width, height, frameCount)
                return parseGlesDagEvalRenderSmokeResult(raw)
            }
            if (width <= 0 || height <= 0 || frameCount <= 0 || frameDurationUs <= 0) {
                raw = glesDagEvalRenderSmokeFailure("invalid_arguments", width, height, frameCount)
                return parseGlesDagEvalRenderSmokeResult(raw)
            }

            surfaceTexture = SurfaceTexture(false).apply {
                setDefaultBufferSize(width, height)
            }
            surface = Surface(surfaceTexture)

            hardwareBuffer = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1AVGlesEvalRenderSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
                frameCount,
                frameDurationUs,
            )
            return parseGlesDagEvalRenderSmokeResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesDagEvalRenderSmokeFailure("exception:$reason", width, height, frameCount)
            return parseGlesDagEvalRenderSmokeResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AV $raw")
            try {
                hardwareBuffer?.close()
            } catch (_: Throwable) {
            }
            try {
                surface?.release()
            } catch (_: Throwable) {
            }
            try {
                surfaceTexture?.release()
            } catch (_: Throwable) {
            }
        }
    }

    private fun parseGlesDagEvalRenderSmokeResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val initialize = parsed["initialize"] ?: "not_run"
        val attach = parsed["attach"] ?: "not_run"
        val graphBuild = parsed["graphBuild"] ?: "not_run"
        val import = parsed["import"] ?: "not_run"
        val evaluation = parsed["evaluation"] ?: "not_run"
        val renderedFrames = parsed["renderedFrames"]?.toIntOrNull() ?: 0
        val frameCount = parsed["frameCount"]?.toIntOrNull() ?: 0
        val evaluatedPtsUs = parsed["evaluatedPtsUs"]?.toLongOrNull() ?: 0L
        val renderFrame = parsed["renderFrame"] ?: "not_run"
        val failingFrame = parsed["failingFrame"]?.toIntOrNull() ?: -1
        val release = parsed["release"] ?: "not_run"
        val width = parsed["width"]?.toIntOrNull() ?: 0
        val height = parsed["height"]?.toIntOrNull() ?: 0
        val releaseFenceFd = parsed["releaseFenceFd"]?.toIntOrNull() ?: -1
        val releaseFenceExported = parsed["releaseFenceExported"]?.equals("true", ignoreCase = true) ?: false
        val proofBoundary = parsed["proofBoundary"]
            ?: "gles_dag_playhead_eval_multiframe_render_foundation_no_product_ui"
        val lastError = parsed["lastError"] ?: "none"

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "initialize" to initialize,
            "attach" to attach,
            "graphBuild" to graphBuild,
            "import" to import,
            "evaluation" to evaluation,
            "renderedFrames" to renderedFrames,
            "frameCount" to frameCount,
            "evaluatedPtsUs" to evaluatedPtsUs,
            "renderFrame" to renderFrame,
            "failingFrame" to failingFrame,
            "release" to release,
            "width" to width,
            "height" to height,
            "releaseFenceFd" to releaseFenceFd,
            "releaseFenceExported" to releaseFenceExported,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesDagEvalRenderSmokeFailure(reason: String, width: Int, height: Int, frameCount: Int): String =
        "status=FAIL;initialize=not_run;attach=not_run;graphBuild=not_run;import=not_run;" +
        "evaluation=not_run;renderedFrames=0;frameCount=$frameCount;evaluatedPtsUs=0;" +
        "renderFrame=not_run;failingFrame=-1;release=not_run;width=$width;height=$height;" +
        "releaseFenceFd=-1;releaseFenceExported=false;" +
        "proofBoundary=gles_dag_playhead_eval_multiframe_render_foundation_no_product_ui;" +
        "lastError=$reason"
}
