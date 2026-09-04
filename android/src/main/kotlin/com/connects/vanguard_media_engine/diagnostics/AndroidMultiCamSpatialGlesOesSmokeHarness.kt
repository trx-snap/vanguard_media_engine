package com.connects.vanguard_media_engine.diagnostics

import android.hardware.HardwareBuffer
import android.os.Build
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver

/**
 * P3-MULTICAM-NODE-GLES-OES-SPATIAL-RENDER: dedicated allocation/execution
 * harness for the OES extension of the P3 spatial GLES render smoke route.
 *
 * Owns HardwareBuffer allocation (two RGBA_8888 baseline buffers, two
 * YCBCR_420_888 GPU-sampled OES buffers), the native bridge invocation, and
 * raw-result parsing, so [AndroidGlesTextureSmokeCoordinator] only needs to
 * own SurfaceProducer creation/threading/dispose bookkeeping for this route
 * (matching the harness/coordinator split already used by the AX/BB/AW-OES
 * routes). The caller-owned [Surface] is never released here.
 *
 * YCBCR_420_888 buffers are allocated with `USAGE_GPU_SAMPLED_IMAGE` only
 * (no `USAGE_CPU_WRITE_OFTEN`) and are never CPU-locked/filled, mirroring
 * the existing `AndroidGlesTwoTextureCompositorSmokeHarness` OES-buffer
 * allocation precedent -- no evidence that CPU-locking a GPU_SAMPLED_IMAGE-
 * only YCBCR_420_888 buffer is safe.
 */
object AndroidMultiCamSpatialGlesOesSmokeHarness {
    private const val TAG = "VanguardDagSmoke"
    private const val RESULT_MARKER = "ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_GLES_OES_RENDER_NATIVE_RESULT"

    const val PROOF_BOUNDARY =
        "native_multicam_spatial_gles_oes_texture_layout_render_readback_only_no_vulkan_no_camera_no_opacity_no_corner_radius_no_recording_no_product"

    // Runs the OES spatial smoke against a caller-owned Surface (e.g. a
    // Flutter TextureRegistry.SurfaceProducer surface). The provided Surface
    // is never released here -- the caller retains sole ownership of it.
    fun runGlesOesSpatialSmokeForSurface(
        surface: Surface,
        width: Int,
        height: Int,
    ): Map<String, Any?> {
        var rgbaBufferA: HardwareBuffer? = null
        var rgbaBufferB: HardwareBuffer? = null
        var ycbcrBufferA: HardwareBuffer? = null
        var ycbcrBufferB: HardwareBuffer? = null
        var ycbcrAllocation = "not_run"
        var raw = failureResult("not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = failureResult("api_below_26")
                return parseResult(raw, ycbcrAllocation)
            }
            if (width <= 0 || height <= 0) {
                raw = failureResult("invalid_dimensions")
                return parseResult(raw, ycbcrAllocation)
            }

            rgbaBufferA = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
            )
            rgbaBufferB = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
            )

            try {
                ycbcrBufferA = HardwareBuffer.create(
                    width,
                    height,
                    HardwareBuffer.YCBCR_420_888,
                    1,
                    HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
                )
                ycbcrBufferB = HardwareBuffer.create(
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
                raw = failureResult("ycbcr_allocation_failed")
                return parseResult(raw, ycbcrAllocation)
            }

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase3MultiCamSpatialGlesOesRenderSmoke(
                surface,
                rgbaBufferA,
                rgbaBufferB,
                ycbcrBufferA,
                ycbcrBufferB,
                width,
                height,
            )
            return parseResult(raw, ycbcrAllocation)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = failureResult("exception:$reason")
            return parseResult(raw, ycbcrAllocation)
        } finally {
            Log.i(TAG, "$RESULT_MARKER $raw")
            try {
                rgbaBufferA?.close()
            } catch (_: Throwable) {
            }
            try {
                rgbaBufferB?.close()
            } catch (_: Throwable) {
            }
            try {
                ycbcrBufferA?.close()
            } catch (_: Throwable) {
            }
            try {
                ycbcrBufferB?.close()
            } catch (_: Throwable) {
            }
        }
    }

    private fun parseResult(raw: String, ycbcrAllocation: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val proofBoundary = parsed["proofBoundary"] ?: PROOF_BOUNDARY
        val lastError = parsed["lastError"] ?: ""

        val metrics = mapOf(
            "clientVersion" to (parsed["clientVersion"]?.toIntOrNull() ?: 0),
            "vendor" to (parsed["vendor"] ?: ""),
            "renderer" to (parsed["renderer"] ?: ""),
            "version" to (parsed["version"] ?: ""),
            "ycbcrAllocation" to ycbcrAllocation,
            "rgbaADescribe" to (parsed["rgbaADescribe"] ?: "not_run"),
            "rgbaAFill" to (parsed["rgbaAFill"] ?: "not_run"),
            "rgbaBDescribe" to (parsed["rgbaBDescribe"] ?: "not_run"),
            "rgbaBFill" to (parsed["rgbaBFill"] ?: "not_run"),
            "ycbcrADescribe" to (parsed["ycbcrADescribe"] ?: "not_run"),
            "ycbcrAFormatIs420888" to (parsed["ycbcrAFormatIs420888"]?.equals("true", ignoreCase = true) ?: false),
            "ycbcrBDescribe" to (parsed["ycbcrBDescribe"] ?: "not_run"),
            "ycbcrBFormatIs420888" to (parsed["ycbcrBFormatIs420888"]?.equals("true", ignoreCase = true) ?: false),
            "preInitLane" to (parsed["preInitLane"] ?: "not_run"),
            "preInitLastError" to (parsed["preInitLastError"] ?: ""),
            "initialize" to (parsed["initialize"] ?: "not_run"),
            "attach" to (parsed["attach"] ?: "not_run"),
            "importRgbaA" to (parsed["importRgbaA"] ?: "not_run"),
            "handleRgbaA" to (parsed["handleRgbaA"]?.toLongOrNull() ?: 0L),
            "targetRgbaA" to (parsed["targetRgbaA"]?.toLongOrNull() ?: 0L),
            "importRgbaB" to (parsed["importRgbaB"] ?: "not_run"),
            "handleRgbaB" to (parsed["handleRgbaB"]?.toLongOrNull() ?: 0L),
            "targetRgbaB" to (parsed["targetRgbaB"]?.toLongOrNull() ?: 0L),
            "importYcbcrA" to (parsed["importYcbcrA"] ?: "not_run"),
            "handleYcbcrA" to (parsed["handleYcbcrA"]?.toLongOrNull() ?: 0L),
            "targetYcbcrA" to (parsed["targetYcbcrA"]?.toLongOrNull() ?: 0L),
            "importYcbcrB" to (parsed["importYcbcrB"] ?: "not_run"),
            "handleYcbcrB" to (parsed["handleYcbcrB"]?.toLongOrNull() ?: 0L),
            "targetYcbcrB" to (parsed["targetYcbcrB"]?.toLongOrNull() ?: 0L),
            "invalidHandleLane" to (parsed["invalidHandleLane"] ?: "not_run"),
            "invalidHandleLastError" to (parsed["invalidHandleLastError"] ?: ""),
            "invalidRectLane" to (parsed["invalidRectLane"] ?: "not_run"),
            "invalidRectLastError" to (parsed["invalidRectLastError"] ?: ""),
            "twoDOesOk" to (parsed["twoDOesOk"]?.equals("true", ignoreCase = true) ?: false),
            "twoDOesTargetOk" to (parsed["twoDOesTargetOk"]?.equals("true", ignoreCase = true) ?: false),
            "twoDOesLastError" to (parsed["twoDOesLastError"] ?: ""),
            "oesTwoDOk" to (parsed["oesTwoDOk"]?.equals("true", ignoreCase = true) ?: false),
            "oesTwoDTargetOk" to (parsed["oesTwoDTargetOk"]?.equals("true", ignoreCase = true) ?: false),
            "oesTwoDLastError" to (parsed["oesTwoDLastError"] ?: ""),
            "oesOesOk" to (parsed["oesOesOk"]?.equals("true", ignoreCase = true) ?: false),
            "oesOesTargetOk" to (parsed["oesOesTargetOk"]?.equals("true", ignoreCase = true) ?: false),
            "oesOesLastError" to (parsed["oesOesLastError"] ?: ""),
            "presentOesOes" to (parsed["presentOesOes"] ?: "not_run"),
            "presentOesOesLastError" to (parsed["presentOesOesLastError"] ?: ""),
            "releaseRgbaA" to (parsed["releaseRgbaA"] ?: "not_run"),
            "releaseRgbaAFence" to (parsed["releaseRgbaAFence"]?.toIntOrNull() ?: -1),
            "hasRgbaAAfterRelease" to (parsed["hasRgbaAAfterRelease"]?.equals("true", ignoreCase = true) ?: false),
            "releaseRgbaB" to (parsed["releaseRgbaB"] ?: "not_run"),
            "releaseRgbaBFence" to (parsed["releaseRgbaBFence"]?.toIntOrNull() ?: -1),
            "hasRgbaBAfterRelease" to (parsed["hasRgbaBAfterRelease"]?.equals("true", ignoreCase = true) ?: false),
            "releaseYcbcrA" to (parsed["releaseYcbcrA"] ?: "not_run"),
            "releaseYcbcrAFence" to (parsed["releaseYcbcrAFence"]?.toIntOrNull() ?: -1),
            "hasYcbcrAAfterRelease" to (parsed["hasYcbcrAAfterRelease"]?.equals("true", ignoreCase = true) ?: false),
            "releaseYcbcrB" to (parsed["releaseYcbcrB"] ?: "not_run"),
            "releaseYcbcrBFence" to (parsed["releaseYcbcrBFence"]?.toIntOrNull() ?: -1),
            "hasYcbcrBAfterRelease" to (parsed["hasYcbcrBAfterRelease"]?.equals("true", ignoreCase = true) ?: false),
            "postReleaseLane" to (parsed["postReleaseLane"] ?: "not_run"),
            "postReleaseLastError" to (parsed["postReleaseLastError"] ?: ""),
            "detach" to (parsed["detach"] ?: "not_run"),
            "shutdown" to (parsed["shutdown"] ?: "not_run"),
            "idempotentShutdown" to (parsed["idempotentShutdown"] ?: "not_run"),
        )

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "proofBoundary" to proofBoundary,
            "metrics" to metrics,
            "lastError" to lastError,
        )
    }

    private fun failureResult(reason: String): String =
        "status=FAIL;width=0;height=0;clientVersion=0;vendor=;renderer=;version=;" +
        "rgbaADescribe=not_run;rgbaAFill=not_run;rgbaBDescribe=not_run;rgbaBFill=not_run;" +
        "ycbcrADescribe=not_run;ycbcrAFormatIs420888=false;ycbcrBDescribe=not_run;ycbcrBFormatIs420888=false;" +
        "preInitLane=not_run;preInitLastError=;initialize=not_run;attach=not_run;" +
        "importRgbaA=not_run;handleRgbaA=0;targetRgbaA=0;importRgbaB=not_run;handleRgbaB=0;targetRgbaB=0;" +
        "importYcbcrA=not_run;handleYcbcrA=0;targetYcbcrA=0;importYcbcrB=not_run;handleYcbcrB=0;targetYcbcrB=0;" +
        "invalidHandleLane=not_run;invalidHandleLastError=;invalidRectLane=not_run;invalidRectLastError=;" +
        "twoDOesOk=false;twoDOesTargetOk=false;twoDOesLastError=;" +
        "oesTwoDOk=false;oesTwoDTargetOk=false;oesTwoDLastError=;" +
        "oesOesOk=false;oesOesTargetOk=false;oesOesLastError=;" +
        "presentOesOes=not_run;presentOesOesLastError=;" +
        "releaseRgbaA=not_run;releaseRgbaAFence=-1;hasRgbaAAfterRelease=false;" +
        "releaseRgbaB=not_run;releaseRgbaBFence=-1;hasRgbaBAfterRelease=false;" +
        "releaseYcbcrA=not_run;releaseYcbcrAFence=-1;hasYcbcrAAfterRelease=false;" +
        "releaseYcbcrB=not_run;releaseYcbcrBFence=-1;hasYcbcrBAfterRelease=false;" +
        "postReleaseLane=not_run;postReleaseLastError=;detach=not_run;shutdown=not_run;idempotentShutdown=not_run;" +
        "proofBoundary=$PROOF_BOUNDARY;lastError=$reason"
}
