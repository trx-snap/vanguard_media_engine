package com.connects.vanguard_media_engine.diagnostics

import android.hardware.HardwareBuffer
import android.os.Build
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.view.TextureRegistry

/**
 * Phase 1-Unit AX: diagnostic-only Android GLES SurfaceProducer Flutter
 * Texture DAG render smoke harness.
 *
 * Extends the Unit AV offscreen playhead-evaluation + multi-frame render
 * loop proof onto a real `TextureRegistry.SurfaceProducer` surface so the
 * result is visible via a Flutter `Texture` widget. Never uses MediaCodec
 * or ImageReader.PRIVATE — the source frame is a synthetic RGBA
 * HardwareBuffer, matching Unit AV.
 */
class AndroidGlesTextureDagRenderSmokeHarness {

    companion object {
        private const val TAG = "VanguardDagSmoke"
        private const val RESULT_MARKER = "ANDROID_DAG_PHASE1AX_NATIVE_RESULT"
        private const val DEFAULT_WIDTH = 64
        private const val DEFAULT_HEIGHT = 64
        private const val DEFAULT_FRAME_COUNT = 30
        private const val DEFAULT_FRAME_DURATION_US = 33333L
        private const val DEFAULT_FRAME_DELAY_MS = 0
        private const val DEFAULT_ROTATION_DEGREES = 0
        private const val DEFAULT_MIRROR_HORIZONTAL = false
        private const val PROOF_BOUNDARY =
            "gles_surfaceproducer_texture_dag_render_foundation_no_decoded_input_no_product_ui"

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
                "import" to (parsed["import"] ?: "not_run"),
                "evaluation" to (parsed["evaluation"] ?: "not_run"),
                "renderedFrames" to (parsed["renderedFrames"]?.toIntOrNull() ?: 0),
                "frameCount" to (parsed["frameCount"]?.toIntOrNull() ?: 0),
                "evaluatedPtsUs" to (parsed["evaluatedPtsUs"]?.toLongOrNull() ?: 0L),
                "renderFrame" to (parsed["renderFrame"] ?: "not_run"),
                "failingFrame" to (parsed["failingFrame"]?.toIntOrNull() ?: -1),
                "release" to (parsed["release"] ?: "not_run"),
                "width" to (parsed["width"]?.toIntOrNull() ?: 0),
                "height" to (parsed["height"]?.toIntOrNull() ?: 0),
                "textureSurface" to (parsed["textureSurface"]?.equals("true", ignoreCase = true) ?: false),
                "releaseFenceFd" to (parsed["releaseFenceFd"]?.toIntOrNull() ?: -1),
                "releaseFenceExported" to (parsed["releaseFenceExported"]?.equals("true", ignoreCase = true) ?: false),
                "proofBoundary" to (parsed["proofBoundary"] ?: PROOF_BOUNDARY),
                "lastError" to (parsed["lastError"] ?: "none"),
                "rotationDegrees" to (parsed["rotationDegrees"]?.toIntOrNull() ?: DEFAULT_ROTATION_DEGREES),
                "mirrorHorizontal" to (parsed["mirrorHorizontal"]?.equals("true", ignoreCase = true) ?: DEFAULT_MIRROR_HORIZONTAL),
                "normalizedRotationDegrees" to (parsed["normalizedRotationDegrees"]?.toIntOrNull() ?: DEFAULT_ROTATION_DEGREES),
            )
        }

        private fun failureStatus(reason: String, width: Int, height: Int, frameCount: Int): String =
            "status=FAIL;initialize=not_run;attach=not_run;graphBuild=not_run;import=not_run;" +
            "evaluation=not_run;renderedFrames=0;frameCount=$frameCount;evaluatedPtsUs=0;" +
            "renderFrame=not_run;failingFrame=-1;release=not_run;width=$width;height=$height;" +
            "textureSurface=false;releaseFenceFd=-1;releaseFenceExported=false;" +
            "proofBoundary=$PROOF_BOUNDARY;lastError=$reason"
    }

    fun run(surfaceProducer: TextureRegistry.SurfaceProducer, args: Map<*, *>?): Map<String, Any?> {
        val width = clampInt((args?.get("width") as? Number)?.toInt(), DEFAULT_WIDTH)
        val height = clampInt((args?.get("height") as? Number)?.toInt(), DEFAULT_HEIGHT)
        val frameCount = clampInt((args?.get("frameCount") as? Number)?.toInt(), DEFAULT_FRAME_COUNT)
        val frameDurationUs = (args?.get("frameDurationUs") as? Number)?.toLong()?.takeIf { it > 0 }
            ?: DEFAULT_FRAME_DURATION_US
        // Phase 1-Unit AY: diagnostic-only per-frame delay so a dispose()
        // call can be proven to land while the render worker is still
        // active. Absent/non-positive defaults to 0, preserving AX behavior.
        val frameDelayMs = clampInt((args?.get("frameDelayMs") as? Number)?.toInt(), DEFAULT_FRAME_DELAY_MS)
        // Phase 1-Unit AZ: rotation/mirror render-transform arguments, both
        // AX/AY-compatible (default 0 / false when absent).
        val rotationDegrees = (args?.get("rotationDegrees") as? Number)?.toInt() ?: DEFAULT_ROTATION_DEGREES
        val mirrorHorizontal = (args?.get("mirrorHorizontal") as? Boolean) ?: DEFAULT_MIRROR_HORIZONTAL

        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
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
            raw = nativeBridge.runAndroidDagPhase1AXGlesTextureRenderSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
                frameCount,
                frameDurationUs,
                frameDelayMs,
                rotationDegrees,
                mirrorHorizontal,
            )
            return parseResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = failureStatus("exception:$reason", width, height, frameCount)
            return parseResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER $raw")
            try {
                hardwareBuffer?.close()
            } catch (_: Throwable) {
            }
            try {
                surface?.release()
            } catch (_: Throwable) {
            }
        }
    }
}
