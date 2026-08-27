package com.connects.vanguard_media_engine.diagnostics

import android.graphics.SurfaceTexture
import android.hardware.HardwareBuffer
import android.os.Build
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver

object AndroidGlesExternalTextureSmokeHarness {
    private const val TAG = "VanguardDagSmoke"

    // ── Phase 1-Unit AR: Android GLES external texture YCBCR_420_888 AHardwareBuffer import foundation physical smoke ──
    private const val RESULT_MARKER_PHASE1AR = "ANDROID_GLES_EXTERNAL_TEXTURE_UNIT_AR_NATIVE_RESULT"

    fun runGlesExternalTextureSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var rgbaBuffer: HardwareBuffer? = null
        var ycbcrBuffer: HardwareBuffer? = null
        var ycbcrAllocation = "not_run"
        var raw = glesExternalTextureFailure("not_run", "not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesExternalTextureFailure("api_below_26", "not_run")
                return parseGlesExternalTextureResult(raw, "not_run")
            }
            if (width <= 0 || height <= 0) {
                raw = glesExternalTextureFailure("invalid_dimensions", "not_run")
                return parseGlesExternalTextureResult(raw, "not_run")
            }

            surfaceTexture = SurfaceTexture(false).apply {
                setDefaultBufferSize(width, height)
            }
            surface = Surface(surfaceTexture)

            rgbaBuffer = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
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
                raw = glesExternalTextureFailure("ycbcr_allocation_failed", ycbcrAllocation)
                return parseGlesExternalTextureResult(raw, ycbcrAllocation)
            }

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1ARGlesExternalTextureSmoke(
                surface,
                rgbaBuffer,
                ycbcrBuffer,
                width,
                height,
            )
            return parseGlesExternalTextureResult(raw, ycbcrAllocation)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesExternalTextureFailure("exception:$reason", ycbcrAllocation)
            return parseGlesExternalTextureResult(raw, ycbcrAllocation)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AR $raw")
            try {
                rgbaBuffer?.close()
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

    private fun parseGlesExternalTextureResult(raw: String, ycbcrAllocation: String): Map<String, Any?> {
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
        val rgbaBufferDescribe = parsed["rgbaBufferDescribe"] ?: "not_run"
        val rgbaBufferFormat = parsed["rgbaBufferFormat"]?.toIntOrNull() ?: 0
        val rgbaBufferUsage = parsed["rgbaBufferUsage"]?.toLongOrNull() ?: 0L
        val ycbcrBufferDescribe = parsed["ycbcrBufferDescribe"] ?: "not_run"
        val ycbcrBufferFormat = parsed["ycbcrBufferFormat"]?.toIntOrNull() ?: 0
        val ycbcrBufferUsage = parsed["ycbcrBufferUsage"]?.toLongOrNull() ?: 0L
        val ycbcrFormatIs420888 = parsed["ycbcrFormatIs420888"]?.equals("true", ignoreCase = true) ?: false
        val initialize = parsed["initialize"] ?: "not_run"
        val attach = parsed["attach"] ?: "not_run"
        val hasSurfaceAfterAttach = parsed["hasSurfaceAfterAttach"]?.equals("true", ignoreCase = true) ?: false
        val surfaceKindAfterAttach = parsed["surfaceKindAfterAttach"] ?: "none"
        val widthAfterAttach = parsed["widthAfterAttach"]?.toIntOrNull() ?: 0
        val heightAfterAttach = parsed["heightAfterAttach"]?.toIntOrNull() ?: 0
        val ycbcrImport = parsed["ycbcrImport"] ?: "not_run"
        val ycbcrHandle = parsed["ycbcrHandle"]?.toLongOrNull() ?: 0L
        val ycbcrDescWidth = parsed["ycbcrDescWidth"]?.toIntOrNull() ?: 0
        val ycbcrDescHeight = parsed["ycbcrDescHeight"]?.toIntOrNull() ?: 0
        val ycbcrDescLayers = parsed["ycbcrDescLayers"]?.toIntOrNull() ?: 0
        val ycbcrDescFormat = parsed["ycbcrDescFormat"]?.toIntOrNull() ?: 0
        val ycbcrDescUsageSampled = parsed["ycbcrDescUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasYcbcrAfterImport = parsed["hasYcbcrAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val ycbcrTextureTarget = parsed["ycbcrTextureTarget"]?.toLongOrNull() ?: 0L
        val diagnosticRender = parsed["diagnosticRender"] ?: "not_run"
        val diagnosticRenderLastError = parsed["diagnosticRenderLastError"] ?: ""
        val centerRead = parsed["centerRead"] ?: "not_run"
        val centerReadLastError = parsed["centerReadLastError"] ?: ""
        val renderFrame = parsed["renderFrame"] ?: "not_run"
        val renderFrameLastError = parsed["renderFrameLastError"] ?: ""
        val releaseYcbcr = parsed["releaseYcbcr"] ?: "not_run"
        val releaseYcbcrFence = parsed["releaseYcbcrFence"]?.toIntOrNull() ?: -1
        val hasYcbcrAfterRelease = parsed["hasYcbcrAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val rgbaPostImport = parsed["rgbaPostImport"] ?: "not_run"
        val rgbaPostHandle = parsed["rgbaPostHandle"]?.toLongOrNull() ?: 0L
        val rgbaPostDescWidth = parsed["rgbaPostDescWidth"]?.toIntOrNull() ?: 0
        val rgbaPostDescHeight = parsed["rgbaPostDescHeight"]?.toIntOrNull() ?: 0
        val rgbaPostDescLayers = parsed["rgbaPostDescLayers"]?.toIntOrNull() ?: 0
        val rgbaPostDescFormat = parsed["rgbaPostDescFormat"]?.toIntOrNull() ?: 0
        val rgbaPostDescUsageSampled = parsed["rgbaPostDescUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasRgbaPostAfterImport = parsed["hasRgbaPostAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val rgbaPostTextureTarget = parsed["rgbaPostTextureTarget"]?.toLongOrNull() ?: 0L
        val rgbaPostRelease = parsed["rgbaPostRelease"] ?: "not_run"
        val rgbaPostReleaseFence = parsed["rgbaPostReleaseFence"]?.toIntOrNull() ?: -1
        val hasRgbaPostAfterRelease = parsed["hasRgbaPostAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val detach = parsed["detach"] ?: "not_run"
        val surfaceKindAfterDetach = parsed["surfaceKindAfterDetach"] ?: "none"
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_external_texture_ycbcr_import_foundation_no_color_conversion_no_camera_product_no_multinode"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "ycbcrAllocation" to ycbcrAllocation,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "rgbaBufferDescribe" to rgbaBufferDescribe,
            "rgbaBufferFormat" to rgbaBufferFormat,
            "rgbaBufferUsage" to rgbaBufferUsage,
            "ycbcrBufferDescribe" to ycbcrBufferDescribe,
            "ycbcrBufferFormat" to ycbcrBufferFormat,
            "ycbcrBufferUsage" to ycbcrBufferUsage,
            "ycbcrFormatIs420888" to ycbcrFormatIs420888,
            "initialize" to initialize,
            "attach" to attach,
            "hasSurfaceAfterAttach" to hasSurfaceAfterAttach,
            "surfaceKindAfterAttach" to surfaceKindAfterAttach,
            "widthAfterAttach" to widthAfterAttach,
            "heightAfterAttach" to heightAfterAttach,
            "ycbcrImport" to ycbcrImport,
            "ycbcrHandle" to ycbcrHandle,
            "ycbcrDescWidth" to ycbcrDescWidth,
            "ycbcrDescHeight" to ycbcrDescHeight,
            "ycbcrDescLayers" to ycbcrDescLayers,
            "ycbcrDescFormat" to ycbcrDescFormat,
            "ycbcrDescUsageSampled" to ycbcrDescUsageSampled,
            "hasYcbcrAfterImport" to hasYcbcrAfterImport,
            "ycbcrTextureTarget" to ycbcrTextureTarget,
            "diagnosticRender" to diagnosticRender,
            "diagnosticRenderLastError" to diagnosticRenderLastError,
            "centerRead" to centerRead,
            "centerReadLastError" to centerReadLastError,
            "renderFrame" to renderFrame,
            "renderFrameLastError" to renderFrameLastError,
            "releaseYcbcr" to releaseYcbcr,
            "releaseYcbcrFence" to releaseYcbcrFence,
            "hasYcbcrAfterRelease" to hasYcbcrAfterRelease,
            "rgbaPostImport" to rgbaPostImport,
            "rgbaPostHandle" to rgbaPostHandle,
            "rgbaPostDescWidth" to rgbaPostDescWidth,
            "rgbaPostDescHeight" to rgbaPostDescHeight,
            "rgbaPostDescLayers" to rgbaPostDescLayers,
            "rgbaPostDescFormat" to rgbaPostDescFormat,
            "rgbaPostDescUsageSampled" to rgbaPostDescUsageSampled,
            "hasRgbaPostAfterImport" to hasRgbaPostAfterImport,
            "rgbaPostTextureTarget" to rgbaPostTextureTarget,
            "rgbaPostRelease" to rgbaPostRelease,
            "rgbaPostReleaseFence" to rgbaPostReleaseFence,
            "hasRgbaPostAfterRelease" to hasRgbaPostAfterRelease,
            "detach" to detach,
            "surfaceKindAfterDetach" to surfaceKindAfterDetach,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesExternalTextureFailure(reason: String, ycbcrAllocation: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;rgbaBufferDescribe=not_run;rgbaBufferFormat=0;rgbaBufferUsage=0;" +
        "ycbcrBufferDescribe=not_run;ycbcrBufferFormat=0;ycbcrBufferUsage=0;ycbcrFormatIs420888=false;" +
        "initialize=not_run;attach=not_run;hasSurfaceAfterAttach=false;surfaceKindAfterAttach=none;widthAfterAttach=0;heightAfterAttach=0;" +
        "ycbcrImport=not_run;ycbcrHandle=0;ycbcrDescWidth=0;ycbcrDescHeight=0;ycbcrDescLayers=0;ycbcrDescFormat=0;ycbcrDescUsageSampled=false;" +
        "hasYcbcrAfterImport=false;ycbcrTextureTarget=0;diagnosticRender=not_run;diagnosticRenderLastError=;centerRead=not_run;centerReadLastError=;" +
        "renderFrame=not_run;renderFrameLastError=;releaseYcbcr=not_run;releaseYcbcrFence=-1;hasYcbcrAfterRelease=false;" +
        "rgbaPostImport=not_run;rgbaPostHandle=0;rgbaPostDescWidth=0;rgbaPostDescHeight=0;rgbaPostDescLayers=0;rgbaPostDescFormat=0;rgbaPostDescUsageSampled=false;" +
        "hasRgbaPostAfterImport=false;rgbaPostTextureTarget=0;rgbaPostRelease=not_run;rgbaPostReleaseFence=-1;hasRgbaPostAfterRelease=false;" +
        "detach=not_run;surfaceKindAfterDetach=none;shutdown=not_run;idempotentShutdown=not_run;" +
        "proofBoundary=gles_external_texture_ycbcr_import_foundation_no_color_conversion_no_camera_product_no_multinode;lastError=$reason"
}
