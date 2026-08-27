package com.connects.vanguard_media_engine.diagnostics

import android.graphics.SurfaceTexture
import android.hardware.HardwareBuffer
import android.os.Build
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver

object AndroidGlesTwoTextureCompositorSmokeHarness {
    private const val TAG = "VanguardDagSmoke"

    // ── Phase 1-Unit AS: Android GLES two-texture compositor RGBA blend foundation smoke ──
    private const val RESULT_MARKER_PHASE1AS = "ANDROID_GLES_TWO_TEXTURE_COMPOSITOR_UNIT_AS_NATIVE_RESULT"

    fun runGlesTwoTextureCompositorSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var bufferA: HardwareBuffer? = null
        var bufferB: HardwareBuffer? = null
        var ycbcrBuffer: HardwareBuffer? = null
        var ycbcrAllocation = "not_run"
        var raw = glesTwoTextureCompositorFailure("not_run", "not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesTwoTextureCompositorFailure("api_below_26", "not_run")
                return parseGlesTwoTextureCompositorResult(raw, "not_run")
            }
            if (width <= 0 || height <= 0) {
                raw = glesTwoTextureCompositorFailure("invalid_dimensions", "not_run")
                return parseGlesTwoTextureCompositorResult(raw, "not_run")
            }

            surfaceTexture = SurfaceTexture(false).apply {
                setDefaultBufferSize(width, height)
            }
            surface = Surface(surfaceTexture)

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

            try {
                ycbcrBuffer = HardwareBuffer.create(
                    width,
                    height,
                    HardwareBuffer.YCBCR_420_888,
                    1,
                    HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
                )
                ycbcrAllocation = "success"
            } catch (t: Throwable) {
                val excReason = t.javaClass.simpleName.ifEmpty { "allocation_exception" }
                ycbcrAllocation = "exception:$excReason"
                raw = glesTwoTextureCompositorFailure("ycbcr_allocation_failed", ycbcrAllocation)
                return parseGlesTwoTextureCompositorResult(raw, ycbcrAllocation)
            }

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1ASGlesTwoTextureCompositorSmoke(
                surface,
                bufferA,
                bufferB,
                ycbcrBuffer,
                width,
                height,
            )
            return parseGlesTwoTextureCompositorResult(raw, ycbcrAllocation)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesTwoTextureCompositorFailure("exception:$reason", ycbcrAllocation)
            return parseGlesTwoTextureCompositorResult(raw, ycbcrAllocation)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AS $raw")
            try {
                bufferA?.close()
            } catch (_: Throwable) {
            }
            try {
                bufferB?.close()
            } catch (_: Throwable) {
            }
            try {
                ycbcrBuffer?.close()
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

    private fun parseGlesTwoTextureCompositorResult(raw: String, ycbcrAllocation: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val bufferADescribe = parsed["bufferADescribe"] ?: "not_run"
        val bufferAFormat = parsed["bufferAFormat"]?.toIntOrNull() ?: 0
        val bufferAUsage = parsed["bufferAUsage"]?.toLongOrNull() ?: 0L
        val bufferAStride = parsed["bufferAStride"]?.toIntOrNull() ?: 0
        val bufferAFill = parsed["bufferAFill"] ?: "not_run"
        val bufferBDescribe = parsed["bufferBDescribe"] ?: "not_run"
        val bufferBFormat = parsed["bufferBFormat"]?.toIntOrNull() ?: 0
        val bufferBUsage = parsed["bufferBUsage"]?.toLongOrNull() ?: 0L
        val bufferBStride = parsed["bufferBStride"]?.toIntOrNull() ?: 0
        val bufferBFill = parsed["bufferBFill"] ?: "not_run"
        val ycbcrBufferDescribe = parsed["ycbcrBufferDescribe"] ?: "not_run"
        val ycbcrBufferFormat = parsed["ycbcrBufferFormat"]?.toIntOrNull() ?: 0
        val ycbcrBufferUsage = parsed["ycbcrBufferUsage"]?.toLongOrNull() ?: 0L
        val ycbcrFormatIs420888 = parsed["ycbcrFormatIs420888"]?.equals("true", ignoreCase = true) ?: false
        val preInitDiagnosticComposite = parsed["preInitDiagnosticComposite"] ?: "not_run"
        val preInitLastError = parsed["preInitLastError"] ?: ""
        val initialize = parsed["initialize"] ?: "not_run"
        val attach = parsed["attach"] ?: "not_run"
        val hasSurfaceAfterAttach = parsed["hasSurfaceAfterAttach"]?.equals("true", ignoreCase = true) ?: false
        val surfaceKindAfterAttach = parsed["surfaceKindAfterAttach"] ?: "none"
        val widthAfterAttach = parsed["widthAfterAttach"]?.toIntOrNull() ?: 0
        val heightAfterAttach = parsed["heightAfterAttach"]?.toIntOrNull() ?: 0
        val importBufferA = parsed["importBufferA"] ?: "not_run"
        val handleA = parsed["handleA"]?.toLongOrNull() ?: 0L
        val targetA = parsed["targetA"]?.toLongOrNull() ?: 0L
        val importBufferB = parsed["importBufferB"] ?: "not_run"
        val handleB = parsed["handleB"]?.toLongOrNull() ?: 0L
        val targetB = parsed["targetB"]?.toLongOrNull() ?: 0L
        val distinctHandles = parsed["distinctHandles"]?.equals("true", ignoreCase = true) ?: false
        val importYcbcr = parsed["importYcbcr"] ?: "not_run"
        val handleYcbcr = parsed["handleYcbcr"]?.toLongOrNull() ?: 0L
        val targetYcbcr = parsed["targetYcbcr"]?.toLongOrNull() ?: 0L
        val unsupportedTargetDiagnosticComposite = parsed["unsupportedTargetDiagnosticComposite"] ?: "not_run"
        val unsupportedTargetLastError = parsed["unsupportedTargetLastError"] ?: ""
        val releaseYcbcr = parsed["releaseYcbcr"] ?: "not_run"
        val releaseYcbcrFence = parsed["releaseYcbcrFence"]?.toIntOrNull() ?: -1
        val hasYcbcrAfterRelease = parsed["hasYcbcrAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val invalidWeightDiagnosticComposite = parsed["invalidWeightDiagnosticComposite"] ?: "not_run"
        val invalidWeightLastError = parsed["invalidWeightLastError"] ?: ""
        val weight0DiagnosticComposite = parsed["weight0DiagnosticComposite"] ?: "not_run"
        val weight0CenterRead = parsed["weight0CenterRead"] ?: "not_run"
        val weight0CenterR = parsed["weight0CenterR"]?.toIntOrNull() ?: 0
        val weight0CenterG = parsed["weight0CenterG"]?.toIntOrNull() ?: 0
        val weight0CenterB = parsed["weight0CenterB"]?.toIntOrNull() ?: 0
        val weight0CenterA = parsed["weight0CenterA"]?.toIntOrNull() ?: 0
        val weight0CenterPixelMatches = parsed["weight0CenterPixelMatches"]?.equals("true", ignoreCase = true) ?: false
        val weight1DiagnosticComposite = parsed["weight1DiagnosticComposite"] ?: "not_run"
        val weight1CenterRead = parsed["weight1CenterRead"] ?: "not_run"
        val weight1CenterR = parsed["weight1CenterR"]?.toIntOrNull() ?: 0
        val weight1CenterG = parsed["weight1CenterG"]?.toIntOrNull() ?: 0
        val weight1CenterB = parsed["weight1CenterB"]?.toIntOrNull() ?: 0
        val weight1CenterA = parsed["weight1CenterA"]?.toIntOrNull() ?: 0
        val weight1CenterPixelMatches = parsed["weight1CenterPixelMatches"]?.equals("true", ignoreCase = true) ?: false
        val weight05DiagnosticComposite = parsed["weight05DiagnosticComposite"] ?: "not_run"
        val weight05CenterRead = parsed["weight05CenterRead"] ?: "not_run"
        val weight05CenterR = parsed["weight05CenterR"]?.toIntOrNull() ?: 0
        val weight05CenterG = parsed["weight05CenterG"]?.toIntOrNull() ?: 0
        val weight05CenterB = parsed["weight05CenterB"]?.toIntOrNull() ?: 0
        val weight05CenterA = parsed["weight05CenterA"]?.toIntOrNull() ?: 0
        val weight05CenterPixelMatches = parsed["weight05CenterPixelMatches"]?.equals("true", ignoreCase = true) ?: false
        val presentComposite = parsed["presentComposite"] ?: "not_run"
        val presentCompositeLastError = parsed["presentCompositeLastError"] ?: ""
        val releaseBufferA = parsed["releaseBufferA"] ?: "not_run"
        val releaseBufferAFence = parsed["releaseBufferAFence"]?.toIntOrNull() ?: -1
        val hasAAfterRelease = parsed["hasAAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val releaseBufferB = parsed["releaseBufferB"] ?: "not_run"
        val releaseBufferBFence = parsed["releaseBufferBFence"]?.toIntOrNull() ?: -1
        val hasBAfterRelease = parsed["hasBAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val postReleaseDiagnosticComposite = parsed["postReleaseDiagnosticComposite"] ?: "not_run"
        val postReleaseLastError = parsed["postReleaseLastError"] ?: ""
        val detach = parsed["detach"] ?: "not_run"
        val surfaceKindAfterDetach = parsed["surfaceKindAfterDetach"] ?: "none"
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_two_texture_compositor_rgba_blend_foundation_no_oes_mixed_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "ycbcrAllocation" to ycbcrAllocation,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "bufferADescribe" to bufferADescribe,
            "bufferAFormat" to bufferAFormat,
            "bufferAUsage" to bufferAUsage,
            "bufferAStride" to bufferAStride,
            "bufferAFill" to bufferAFill,
            "bufferBDescribe" to bufferBDescribe,
            "bufferBFormat" to bufferBFormat,
            "bufferBUsage" to bufferBUsage,
            "bufferBStride" to bufferBStride,
            "bufferBFill" to bufferBFill,
            "ycbcrBufferDescribe" to ycbcrBufferDescribe,
            "ycbcrBufferFormat" to ycbcrBufferFormat,
            "ycbcrBufferUsage" to ycbcrBufferUsage,
            "ycbcrFormatIs420888" to ycbcrFormatIs420888,
            "preInitDiagnosticComposite" to preInitDiagnosticComposite,
            "preInitLastError" to preInitLastError,
            "initialize" to initialize,
            "attach" to attach,
            "hasSurfaceAfterAttach" to hasSurfaceAfterAttach,
            "surfaceKindAfterAttach" to surfaceKindAfterAttach,
            "widthAfterAttach" to widthAfterAttach,
            "heightAfterAttach" to heightAfterAttach,
            "importBufferA" to importBufferA,
            "handleA" to handleA,
            "targetA" to targetA,
            "importBufferB" to importBufferB,
            "handleB" to handleB,
            "targetB" to targetB,
            "distinctHandles" to distinctHandles,
            "importYcbcr" to importYcbcr,
            "handleYcbcr" to handleYcbcr,
            "targetYcbcr" to targetYcbcr,
            "unsupportedTargetDiagnosticComposite" to unsupportedTargetDiagnosticComposite,
            "unsupportedTargetLastError" to unsupportedTargetLastError,
            "releaseYcbcr" to releaseYcbcr,
            "releaseYcbcrFence" to releaseYcbcrFence,
            "hasYcbcrAfterRelease" to hasYcbcrAfterRelease,
            "invalidWeightDiagnosticComposite" to invalidWeightDiagnosticComposite,
            "invalidWeightLastError" to invalidWeightLastError,
            "weight0DiagnosticComposite" to weight0DiagnosticComposite,
            "weight0CenterRead" to weight0CenterRead,
            "weight0CenterR" to weight0CenterR,
            "weight0CenterG" to weight0CenterG,
            "weight0CenterB" to weight0CenterB,
            "weight0CenterA" to weight0CenterA,
            "weight0CenterPixelMatches" to weight0CenterPixelMatches,
            "weight1DiagnosticComposite" to weight1DiagnosticComposite,
            "weight1CenterRead" to weight1CenterRead,
            "weight1CenterR" to weight1CenterR,
            "weight1CenterG" to weight1CenterG,
            "weight1CenterB" to weight1CenterB,
            "weight1CenterA" to weight1CenterA,
            "weight1CenterPixelMatches" to weight1CenterPixelMatches,
            "weight05DiagnosticComposite" to weight05DiagnosticComposite,
            "weight05CenterRead" to weight05CenterRead,
            "weight05CenterR" to weight05CenterR,
            "weight05CenterG" to weight05CenterG,
            "weight05CenterB" to weight05CenterB,
            "weight05CenterA" to weight05CenterA,
            "weight05CenterPixelMatches" to weight05CenterPixelMatches,
            "presentComposite" to presentComposite,
            "presentCompositeLastError" to presentCompositeLastError,
            "releaseBufferA" to releaseBufferA,
            "releaseBufferAFence" to releaseBufferAFence,
            "hasAAfterRelease" to hasAAfterRelease,
            "releaseBufferB" to releaseBufferB,
            "releaseBufferBFence" to releaseBufferBFence,
            "hasBAfterRelease" to hasBAfterRelease,
            "postReleaseDiagnosticComposite" to postReleaseDiagnosticComposite,
            "postReleaseLastError" to postReleaseLastError,
            "detach" to detach,
            "surfaceKindAfterDetach" to surfaceKindAfterDetach,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesTwoTextureCompositorFailure(reason: String, ycbcrAllocation: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;bufferADescribe=not_run;bufferAFormat=0;bufferAUsage=0;bufferAStride=0;bufferAFill=not_run;" +
        "bufferBDescribe=not_run;bufferBFormat=0;bufferBUsage=0;bufferBStride=0;bufferBFill=not_run;" +
        "ycbcrBufferDescribe=not_run;ycbcrBufferFormat=0;ycbcrBufferUsage=0;ycbcrFormatIs420888=false;" +
        "preInitDiagnosticComposite=not_run;preInitLastError=;initialize=not_run;attach=not_run;hasSurfaceAfterAttach=false;surfaceKindAfterAttach=none;widthAfterAttach=0;heightAfterAttach=0;" +
        "importBufferA=not_run;handleA=0;targetA=0;importBufferB=not_run;handleB=0;targetB=0;distinctHandles=false;importYcbcr=not_run;handleYcbcr=0;targetYcbcr=0;" +
        "unsupportedTargetDiagnosticComposite=not_run;unsupportedTargetLastError=;releaseYcbcr=not_run;releaseYcbcrFence=-1;hasYcbcrAfterRelease=false;" +
        "invalidWeightDiagnosticComposite=not_run;invalidWeightLastError=;weight0DiagnosticComposite=not_run;weight0CenterRead=not_run;weight0CenterR=0;weight0CenterG=0;weight0CenterB=0;weight0CenterA=0;weight0CenterPixelMatches=false;" +
        "weight1DiagnosticComposite=not_run;weight1CenterRead=not_run;weight1CenterR=0;weight1CenterG=0;weight1CenterB=0;weight1CenterA=0;weight1CenterPixelMatches=false;" +
        "weight05DiagnosticComposite=not_run;weight05CenterRead=not_run;weight05CenterR=0;weight05CenterG=0;weight05CenterB=0;weight05CenterA=0;weight05CenterPixelMatches=false;" +
        "presentComposite=not_run;presentCompositeLastError=;releaseBufferA=not_run;releaseBufferAFence=-1;hasAAfterRelease=false;releaseBufferB=not_run;releaseBufferBFence=-1;hasBAfterRelease=false;" +
        "postReleaseDiagnosticComposite=not_run;postReleaseLastError=;detach=not_run;surfaceKindAfterDetach=none;shutdown=not_run;idempotentShutdown=not_run;" +
        "proofBoundary=gles_two_texture_compositor_rgba_blend_foundation_no_oes_mixed_no_product;lastError=$reason"
}
