package com.connects.vanguard_media_engine.diagnostics

import android.hardware.HardwareBuffer
import android.os.Build
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.view.TextureRegistry

/**
 * Phase 1-Unit BB: diagnostic-only Android GLES SurfaceProducer Flutter
 * Texture DAG two-source composition & playhead evaluation smoke harness.
 *
 * Extends the Unit AX single-source texture DAG render proof to two
 * synthetic RGBA HardwareBuffer sources composited through a diagnostic
 * DAG (source A + source B -> compositor -> sink) whose per-frame blend
 * weight is driven by Graph::evaluatePlayhead() and rendered onto a real
 * `TextureRegistry.SurfaceProducer` surface via
 * GlesBackend::diagnosticPresentCompositeFrames(). Never uses MediaCodec or
 * ImageReader.PRIVATE.
 */
class AndroidGlesTextureCompositionDagSmokeHarness {

    companion object {
        private const val TAG = "VanguardDagSmoke"
        private const val RESULT_MARKER = "ANDROID_DAG_PHASE1BB_NATIVE_RESULT"
        private const val DEFAULT_WIDTH = 64
        private const val DEFAULT_HEIGHT = 64
        private const val DEFAULT_FRAME_COUNT = 30
        private const val DEFAULT_FRAME_DURATION_US = 33333L
        private const val PROOF_BOUNDARY =
            "gles_surfaceproducer_texture_dag_two_source_composition_no_decoded_input_no_product_ui"

        /** Failure result map for exceptions raised outside [run] itself (e.g. thread crash). */
        fun exceptionResult(throwable: Throwable): Map<String, Any?> {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            return parseResult(failureStatus("harness_exception:$reason", DEFAULT_WIDTH, DEFAULT_HEIGHT, DEFAULT_FRAME_COUNT))
        }

        private fun clampInt(raw: Int?, default: Int): Int = raw?.takeIf { it > 0 } ?: default

        private fun parseResult(raw: String): Map<String, Any?> {
            val parsed = mutableMapOf<String, String>()
            raw.split(';').forEach { token ->
                val eq = token.indexOf('=')
                if (eq > 0) {
                    parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
                }
            }
            val pass = raw.startsWith("status=PASS;")
            return mapOf(
                "pass" to pass,
                "raw" to raw,
                "initialize" to (parsed["initialize"] ?: "not_run"),
                "attach" to (parsed["attach"] ?: "not_run"),
                "graphBuild" to (parsed["graphBuild"] ?: "not_run"),
                "importA" to (parsed["importA"] ?: "not_run"),
                "importB" to (parsed["importB"] ?: "not_run"),
                "evaluation" to (parsed["evaluation"] ?: "not_run"),
                "renderedFrames" to (parsed["renderedFrames"]?.toIntOrNull() ?: 0),
                "frameCount" to (parsed["frameCount"]?.toIntOrNull() ?: 0),
                "lastEvaluatedPtsUs" to (parsed["lastEvaluatedPtsUs"]?.toLongOrNull() ?: 0L),
                "graphGeneration" to (parsed["graphGeneration"]?.toLongOrNull() ?: 0L),
                "activeNodeCount" to (parsed["activeNodeCount"]?.toIntOrNull() ?: 0),
                "compositorActive" to (parsed["compositorActive"]?.equals("true", ignoreCase = true) ?: false),
                "startWeightB" to (parsed["startWeightB"]?.toDoubleOrNull() ?: 0.0),
                "endWeightB" to (parsed["endWeightB"]?.toDoubleOrNull() ?: 0.0),
                "monotonicWeights" to (parsed["monotonicWeights"]?.equals("true", ignoreCase = true) ?: false),
                "renderFrame" to (parsed["renderFrame"] ?: "not_run"),
                "failingFrame" to (parsed["failingFrame"]?.toIntOrNull() ?: -1),
                "releaseA" to (parsed["releaseA"] ?: "not_run"),
                "releaseB" to (parsed["releaseB"] ?: "not_run"),
                "width" to (parsed["width"]?.toIntOrNull() ?: 0),
                "height" to (parsed["height"]?.toIntOrNull() ?: 0),
                "textureSurface" to (parsed["textureSurface"]?.equals("true", ignoreCase = true) ?: false),
                "releaseFenceAFd" to (parsed["releaseFenceAFd"]?.toIntOrNull() ?: -1),
                "releaseFenceBFd" to (parsed["releaseFenceBFd"]?.toIntOrNull() ?: -1),
                "releaseFenceExported" to (parsed["releaseFenceExported"]?.equals("true", ignoreCase = true) ?: false),
                "proofBoundary" to (parsed["proofBoundary"] ?: PROOF_BOUNDARY),
                "lastError" to (parsed["lastError"] ?: "none"),
            )
        }

        private fun failureStatus(reason: String, width: Int, height: Int, frameCount: Int): String =
            "status=FAIL;initialize=not_run;attach=not_run;graphBuild=not_run;importA=not_run;importB=not_run;" +
            "evaluation=not_run;renderedFrames=0;frameCount=$frameCount;lastEvaluatedPtsUs=0;" +
            "graphGeneration=0;activeNodeCount=0;compositorActive=false;startWeightB=0.0;endWeightB=0.0;" +
            "monotonicWeights=false;renderFrame=not_run;failingFrame=-1;releaseA=not_run;releaseB=not_run;" +
            "width=$width;height=$height;textureSurface=false;releaseFenceAFd=-1;releaseFenceBFd=-1;" +
            "releaseFenceExported=false;proofBoundary=$PROOF_BOUNDARY;lastError=$reason"
    }

    fun run(surfaceProducer: TextureRegistry.SurfaceProducer, args: Map<*, *>?): Map<String, Any?> {
        val width = clampInt((args?.get("width") as? Number)?.toInt(), DEFAULT_WIDTH)
        val height = clampInt((args?.get("height") as? Number)?.toInt(), DEFAULT_HEIGHT)
        val frameCount = clampInt((args?.get("frameCount") as? Number)?.toInt(), DEFAULT_FRAME_COUNT)
        val frameDurationUs = (args?.get("frameDurationUs") as? Number)?.toLong()?.takeIf { it > 0 }
            ?: DEFAULT_FRAME_DURATION_US

        var surface: Surface? = null
        var bufferA: HardwareBuffer? = null
        var bufferB: HardwareBuffer? = null
        var raw = failureStatus("not_run", width, height, frameCount)

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = failureStatus("api_below_26", width, height, frameCount)
                return parseResult(raw)
            }
            if (width <= 0 || height <= 0 || frameCount <= 0 || frameDurationUs <= 0) {
                raw = failureStatus("invalid_arguments", width, height, frameCount)
                return parseResult(raw)
            }

            surfaceProducer.setSize(width, height)
            surface = surfaceProducer.getSurface()

            bufferA = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
            )
            bufferB = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
            )

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1BBGlesTextureCompositionDagSmoke(
                surface,
                bufferA,
                bufferB,
                width,
                height,
                frameCount,
                frameDurationUs,
            )
            return parseResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = failureStatus("exception:$reason", width, height, frameCount)
            return parseResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER $raw")
            try {
                bufferA?.close()
            } catch (_: Throwable) {
            }
            try {
                bufferB?.close()
            } catch (_: Throwable) {
            }
            try {
                surface?.release()
            } catch (_: Throwable) {
            }
        }
    }
}
