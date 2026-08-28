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
 *
 * Phase 1-Unit BC extends this route with a diagnostic-only frameDelayMs
 * (default 0, BB-compatible) used to hold the frame loop open long enough
 * for an active-dispose/cancellation physical proof, matching the Unit AY
 * pattern.
 *
 * Phase 1-Unit BE extends this route with independent per-source
 * sourceKindA/sourceKindB arguments ("2d" or "oes", default "2d",
 * BB/BC/BD-compatible) so the same two-source DAG/compositor loop can
 * render all four source target permutations (2D+2D, OES+2D, 2D+OES,
 * OES+OES). "oes" sources allocate a YCBCR_420_888 HardwareBuffer with
 * USAGE_GPU_SAMPLED_IMAGE only (no CPU_WRITE_OFTEN, never CPU-filled).
 */
class AndroidGlesTextureCompositionDagSmokeHarness {

    companion object {
        private const val TAG = "VanguardDagSmoke"
        private const val RESULT_MARKER = "ANDROID_DAG_PHASE1BB_NATIVE_RESULT"
        private const val DEFAULT_WIDTH = 64
        private const val DEFAULT_HEIGHT = 64
        private const val DEFAULT_FRAME_COUNT = 30
        private const val DEFAULT_FRAME_DURATION_US = 33333L
        private const val DEFAULT_FRAME_DELAY_MS = 0
        private const val DEFAULT_ROTATION_DEGREES = 0
        private const val DEFAULT_MIRROR_HORIZONTAL = false
        private const val DEFAULT_SOURCE_KIND = "2d"
        private const val PROOF_BOUNDARY =
            "gles_surfaceproducer_texture_dag_two_source_composition_no_decoded_input_no_product_ui"

        /** Failure result map for exceptions raised outside [run] itself (e.g. thread crash). */
        fun exceptionResult(throwable: Throwable): Map<String, Any?> {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            return parseResult(
                failureStatus(
                    "harness_exception:$reason",
                    DEFAULT_WIDTH,
                    DEFAULT_HEIGHT,
                    DEFAULT_FRAME_COUNT,
                    DEFAULT_FRAME_DELAY_MS,
                    DEFAULT_ROTATION_DEGREES,
                    DEFAULT_MIRROR_HORIZONTAL,
                    DEFAULT_ROTATION_DEGREES,
                    DEFAULT_MIRROR_HORIZONTAL,
                    DEFAULT_SOURCE_KIND,
                    DEFAULT_SOURCE_KIND,
                )
            )
        }

        private fun clampInt(raw: Int?, default: Int): Int = raw?.takeIf { it > 0 } ?: default

        // Phase 1-Unit BE: only "2d"/"oes" are accepted; anything else falls
        // back to the BB/BC/BD-compatible "2d" default.
        private fun normalizeSourceKind(raw: String?): String =
            when (raw) {
                "2d", "oes" -> raw
                else -> DEFAULT_SOURCE_KIND
            }

        // Phase 1-Unit BE: "2d" sources allocate an RGBA_8888 buffer with
        // GPU_SAMPLED_IMAGE|CPU_WRITE_OFTEN (CPU-filled natively); "oes"
        // sources allocate a YCBCR_420_888 buffer with GPU_SAMPLED_IMAGE only
        // and are never CPU-filled.
        private fun createSourceBuffer(sourceKind: String, width: Int, height: Int): HardwareBuffer =
            if (sourceKind == "oes") {
                HardwareBuffer.create(
                    width,
                    height,
                    HardwareBuffer.YCBCR_420_888,
                    1,
                    HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
                )
            } else {
                HardwareBuffer.create(
                    width,
                    height,
                    HardwareBuffer.RGBA_8888,
                    1,
                    HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
                )
            }

        // Phase 1-Unit BD: mirrors vanguard::render::normalizeRotation — maps
        // any integer degrees to a cardinal 0/90/180/270 value; non-cardinal
        // input normalizes to 0 (identity).
        private fun normalizeRotationDegrees(degrees: Int): Int {
            val normalized = ((degrees % 360) + 360) % 360
            return when (normalized) {
                0, 90, 180, 270 -> normalized
                else -> 0
            }
        }

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
                "frameDelayMs" to (parsed["frameDelayMs"]?.toIntOrNull() ?: DEFAULT_FRAME_DELAY_MS),
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
                "rotationDegreesA" to (parsed["rotationDegreesA"]?.toIntOrNull() ?: DEFAULT_ROTATION_DEGREES),
                "mirrorHorizontalA" to (parsed["mirrorHorizontalA"]?.equals("true", ignoreCase = true) ?: DEFAULT_MIRROR_HORIZONTAL),
                "normalizedRotationDegreesA" to (parsed["normalizedRotationDegreesA"]?.toIntOrNull() ?: DEFAULT_ROTATION_DEGREES),
                "rotationDegreesB" to (parsed["rotationDegreesB"]?.toIntOrNull() ?: DEFAULT_ROTATION_DEGREES),
                "mirrorHorizontalB" to (parsed["mirrorHorizontalB"]?.equals("true", ignoreCase = true) ?: DEFAULT_MIRROR_HORIZONTAL),
                "normalizedRotationDegreesB" to (parsed["normalizedRotationDegreesB"]?.toIntOrNull() ?: DEFAULT_ROTATION_DEGREES),
                "sourceKindA" to (parsed["sourceKindA"] ?: DEFAULT_SOURCE_KIND),
                "sourceKindB" to (parsed["sourceKindB"] ?: DEFAULT_SOURCE_KIND),
                "bufferAFormat" to (parsed["bufferAFormat"] ?: "not_run"),
                "bufferBFormat" to (parsed["bufferBFormat"] ?: "not_run"),
                "targetA" to (parsed["targetA"]?.toIntOrNull() ?: -1),
                "targetB" to (parsed["targetB"]?.toIntOrNull() ?: -1),
                "bufferFillA" to (parsed["bufferFillA"] ?: "not_run"),
                "bufferFillB" to (parsed["bufferFillB"] ?: "not_run"),
                "proofBoundary" to (parsed["proofBoundary"] ?: PROOF_BOUNDARY),
                "lastError" to (parsed["lastError"] ?: "none"),
            )
        }

        private fun failureStatus(
            reason: String,
            width: Int,
            height: Int,
            frameCount: Int,
            frameDelayMs: Int,
            rotationDegreesA: Int,
            mirrorHorizontalA: Boolean,
            rotationDegreesB: Int,
            mirrorHorizontalB: Boolean,
            sourceKindA: String = DEFAULT_SOURCE_KIND,
            sourceKindB: String = DEFAULT_SOURCE_KIND,
        ): String =
            "status=FAIL;initialize=not_run;attach=not_run;graphBuild=not_run;importA=not_run;importB=not_run;" +
            "evaluation=not_run;renderedFrames=0;frameCount=$frameCount;frameDelayMs=$frameDelayMs;lastEvaluatedPtsUs=0;" +
            "graphGeneration=0;activeNodeCount=0;compositorActive=false;startWeightB=0.0;endWeightB=0.0;" +
            "monotonicWeights=false;renderFrame=not_run;failingFrame=-1;releaseA=not_run;releaseB=not_run;" +
            "width=$width;height=$height;textureSurface=false;releaseFenceAFd=-1;releaseFenceBFd=-1;" +
            "releaseFenceExported=false;" +
            "rotationDegreesA=$rotationDegreesA;mirrorHorizontalA=$mirrorHorizontalA;" +
            "normalizedRotationDegreesA=${normalizeRotationDegrees(rotationDegreesA)};" +
            "rotationDegreesB=$rotationDegreesB;mirrorHorizontalB=$mirrorHorizontalB;" +
            "normalizedRotationDegreesB=${normalizeRotationDegrees(rotationDegreesB)};" +
            "sourceKindA=$sourceKindA;sourceKindB=$sourceKindB;" +
            "bufferAFormat=not_run;bufferBFormat=not_run;targetA=-1;targetB=-1;" +
            "bufferFillA=not_run;bufferFillB=not_run;" +
            "proofBoundary=$PROOF_BOUNDARY;lastError=$reason"
    }

    fun run(surfaceProducer: TextureRegistry.SurfaceProducer, args: Map<*, *>?): Map<String, Any?> {
        val width = clampInt((args?.get("width") as? Number)?.toInt(), DEFAULT_WIDTH)
        val height = clampInt((args?.get("height") as? Number)?.toInt(), DEFAULT_HEIGHT)
        val frameCount = clampInt((args?.get("frameCount") as? Number)?.toInt(), DEFAULT_FRAME_COUNT)
        val frameDurationUs = (args?.get("frameDurationUs") as? Number)?.toLong()?.takeIf { it > 0 }
            ?: DEFAULT_FRAME_DURATION_US
        // Phase 1-Unit BC: diagnostic-only per-frame delay so a dispose()
        // call can be proven to land while the render worker is still
        // active. Absent/non-positive defaults to 0, preserving BB behavior.
        val frameDelayMs = clampInt((args?.get("frameDelayMs") as? Number)?.toInt(), DEFAULT_FRAME_DELAY_MS)
        // Phase 1-Unit BD: independent per-source rotation/mirror
        // render-transform arguments, both BB/BC-compatible (default 0 /
        // false when absent).
        val rotationDegreesA = (args?.get("rotationDegreesA") as? Number)?.toInt() ?: DEFAULT_ROTATION_DEGREES
        val mirrorHorizontalA = (args?.get("mirrorHorizontalA") as? Boolean) ?: DEFAULT_MIRROR_HORIZONTAL
        val rotationDegreesB = (args?.get("rotationDegreesB") as? Number)?.toInt() ?: DEFAULT_ROTATION_DEGREES
        val mirrorHorizontalB = (args?.get("mirrorHorizontalB") as? Boolean) ?: DEFAULT_MIRROR_HORIZONTAL
        // Phase 1-Unit BE: independent per-source kind arguments ("2d" or
        // "oes"), both BB/BC/BD-compatible (default "2d" when absent or
        // unrecognized).
        val sourceKindA = normalizeSourceKind(args?.get("sourceKindA") as? String)
        val sourceKindB = normalizeSourceKind(args?.get("sourceKindB") as? String)

        var surface: Surface? = null
        var bufferA: HardwareBuffer? = null
        var bufferB: HardwareBuffer? = null
        var raw = failureStatus(
            "not_run", width, height, frameCount, frameDelayMs,
            rotationDegreesA, mirrorHorizontalA, rotationDegreesB, mirrorHorizontalB,
            sourceKindA, sourceKindB,
        )

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = failureStatus(
                    "api_below_26", width, height, frameCount, frameDelayMs,
                    rotationDegreesA, mirrorHorizontalA, rotationDegreesB, mirrorHorizontalB,
                    sourceKindA, sourceKindB,
                )
                return parseResult(raw)
            }
            if (width <= 0 || height <= 0 || frameCount <= 0 || frameDurationUs <= 0) {
                raw = failureStatus(
                    "invalid_arguments", width, height, frameCount, frameDelayMs,
                    rotationDegreesA, mirrorHorizontalA, rotationDegreesB, mirrorHorizontalB,
                    sourceKindA, sourceKindB,
                )
                return parseResult(raw)
            }

            surfaceProducer.setSize(width, height)
            surface = surfaceProducer.getSurface()

            bufferA = createSourceBuffer(sourceKindA, width, height)
            bufferB = createSourceBuffer(sourceKindB, width, height)

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
                frameDelayMs,
                rotationDegreesA,
                mirrorHorizontalA,
                rotationDegreesB,
                mirrorHorizontalB,
                sourceKindA,
                sourceKindB,
            )
            return parseResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = failureStatus(
                "exception:$reason", width, height, frameCount, frameDelayMs,
                rotationDegreesA, mirrorHorizontalA, rotationDegreesB, mirrorHorizontalB,
                sourceKindA, sourceKindB,
            )
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
