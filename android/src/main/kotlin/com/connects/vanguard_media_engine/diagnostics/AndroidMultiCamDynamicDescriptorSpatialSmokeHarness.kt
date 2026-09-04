package com.connects.vanguard_media_engine.diagnostics

import android.hardware.HardwareBuffer
import android.os.Build
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver

/**
 * P3-MULTICAM-NODE-DYNAMIC-DESCRIPTOR-SPATIAL-RENDER: dedicated
 * allocation/parsing/execution harness proving a caller-supplied Dart
 * layout descriptor map drives native GLES/OES spatial rendering.
 *
 * Owns HardwareBuffer allocation (two RGBA_8888 baseline buffers, two
 * YCBCR_420_888 GPU-sampled OES buffers), Dart layout descriptor map
 * shape/type parsing, the native bridge invocation, and raw-result parsing,
 * so [AndroidGlesTextureSmokeCoordinator] only needs to own SurfaceProducer
 * creation/threading/dispose bookkeeping for this route (matching the
 * harness/coordinator split already used by the sibling OES spatial route).
 * The caller-owned [Surface] is never released here.
 *
 * Kotlin is dumb transport for the descriptor: [parseDescriptor] validates
 * only map shape/type (every field present, String fields are String,
 * numeric fields are Number) and fails closed with `null` for a malformed
 * map -- before any native call, so no GL/native work ever starts for a
 * shape-malformed map. It performs no layout math, clamping, rect
 * derivation, or enum-*value* validation: an unrecognized-but-well-typed
 * enum string (e.g. `layoutMode: "invalidMode"`) is passed through
 * untouched, and native -- the sole layout authority -- rejects it with its
 * own explicit `descriptorParse`/`lastError` reason.
 *
 * YCBCR_420_888 buffers are allocated with `USAGE_GPU_SAMPLED_IMAGE` only
 * (no `USAGE_CPU_WRITE_OFTEN`) and are never CPU-locked/filled, mirroring
 * the existing `AndroidMultiCamSpatialGlesOesSmokeHarness` OES-buffer
 * allocation precedent -- no evidence that CPU-locking a GPU_SAMPLED_IMAGE-
 * only YCBCR_420_888 buffer is safe.
 */
object AndroidMultiCamDynamicDescriptorSpatialSmokeHarness {
    private const val TAG = "VanguardDagSmoke"
    private const val RESULT_MARKER =
        "ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_RENDER_NATIVE_RESULT"

    const val PROOF_BOUNDARY =
        "native_multicam_dynamic_descriptor_spatial_gles_oes_render_readback_only_no_vulkan_no_camera_no_opacity_no_corner_radius_no_ycbcr_color_claim_no_recording_no_product"

    // Runs the dynamic-descriptor spatial smoke against a caller-owned
    // Surface (e.g. a Flutter TextureRegistry.SurfaceProducer surface). The
    // provided Surface is never released here -- the caller retains sole
    // ownership of it. [descriptor] is the raw Dart layout descriptor map
    // (MethodChannel arguments are decoded as Map<*, *>).
    fun runDynamicDescriptorSpatialSmokeForSurface(
        surface: Surface,
        width: Int,
        height: Int,
        descriptor: Map<*, *>?,
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

            val parsed = parseDescriptor(descriptor)
            if (parsed == null) {
                raw = failureResult(
                    "malformed_descriptor_layout_map",
                    descriptorParseStatus = "failed",
                    descriptorParseLastError = "malformed_descriptor_layout_map",
                )
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
            raw = nativeBridge.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialRenderSmoke(
                surface,
                rgbaBufferA,
                rgbaBufferB,
                ycbcrBufferA,
                ycbcrBufferB,
                width,
                height,
                parsed.layoutMode,
                parsed.pipAnchor,
                parsed.pipCenterX,
                parsed.pipCenterY,
                parsed.pipWidthFraction,
                parsed.pipAspectRatio,
                parsed.pipMarginFraction,
                parsed.splitDirection,
                parsed.splitRatio,
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

    private data class ParsedDescriptor(
        val layoutMode: String,
        val pipAnchor: String,
        val pipCenterX: Double,
        val pipCenterY: Double,
        val pipWidthFraction: Double,
        val pipAspectRatio: Double,
        val pipMarginFraction: Double,
        val splitDirection: String,
        val splitRatio: Double,
    )

    // Shape/type parsing only -- no enum-value validation, no clamping, no
    // rect derivation (native owns all of that). Every field must be
    // present and of the exact expected type; anything else (missing key,
    // wrong type, non-numeric field) returns null so the caller fails
    // closed before any native call.
    private fun parseDescriptor(descriptor: Map<*, *>?): ParsedDescriptor? {
        if (descriptor == null) return null
        val layoutMode = descriptor["layoutMode"] as? String ?: return null
        val pipAnchor = descriptor["pipAnchor"] as? String ?: return null
        val splitDirection = descriptor["splitDirection"] as? String ?: return null
        val pipCenterX = (descriptor["pipCenterX"] as? Number)?.toDouble() ?: return null
        val pipCenterY = (descriptor["pipCenterY"] as? Number)?.toDouble() ?: return null
        val pipWidthFraction = (descriptor["pipWidthFraction"] as? Number)?.toDouble() ?: return null
        val pipAspectRatio = (descriptor["pipAspectRatio"] as? Number)?.toDouble() ?: return null
        val pipMarginFraction = (descriptor["pipMarginFraction"] as? Number)?.toDouble() ?: return null
        val splitRatio = (descriptor["splitRatio"] as? Number)?.toDouble() ?: return null
        return ParsedDescriptor(
            layoutMode = layoutMode,
            pipAnchor = pipAnchor,
            pipCenterX = pipCenterX,
            pipCenterY = pipCenterY,
            pipWidthFraction = pipWidthFraction,
            pipAspectRatio = pipAspectRatio,
            pipMarginFraction = pipMarginFraction,
            splitDirection = splitDirection,
            splitRatio = splitRatio,
        )
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
            "descriptorParse" to (parsed["descriptorParse"] ?: "not_run"),
            "descriptorParseLastError" to (parsed["descriptorParseLastError"] ?: ""),
            "layoutModeResolved" to (parsed["layoutModeResolved"] ?: ""),
            "anchorResolved" to (parsed["anchorResolved"] ?: ""),
            "directionResolved" to (parsed["directionResolved"] ?: ""),
            "layoutConvert" to (parsed["layoutConvert"] ?: "not_run"),
            "layoutConvertLastError" to (parsed["layoutConvertLastError"] ?: ""),
            "primaryRectX" to (parsed["primaryRectX"]?.toIntOrNull() ?: 0),
            "primaryRectY" to (parsed["primaryRectY"]?.toIntOrNull() ?: 0),
            "primaryRectW" to (parsed["primaryRectW"]?.toIntOrNull() ?: 0),
            "primaryRectH" to (parsed["primaryRectH"]?.toIntOrNull() ?: 0),
            "secondaryRectX" to (parsed["secondaryRectX"]?.toIntOrNull() ?: 0),
            "secondaryRectY" to (parsed["secondaryRectY"]?.toIntOrNull() ?: 0),
            "secondaryRectW" to (parsed["secondaryRectW"]?.toIntOrNull() ?: 0),
            "secondaryRectH" to (parsed["secondaryRectH"]?.toIntOrNull() ?: 0),
            "renderLaneMode" to (parsed["renderLaneMode"] ?: ""),
            "primaryTextureKind" to (parsed["primaryTextureKind"] ?: ""),
            "secondaryTextureKind" to (parsed["secondaryTextureKind"] ?: ""),
            "renderDraw" to (parsed["renderDraw"] ?: "not_run"),
            "renderDrawLastError" to (parsed["renderDrawLastError"] ?: ""),
            "primaryTargetOk" to (parsed["primaryTargetOk"]?.equals("true", ignoreCase = true) ?: false),
            "secondaryTargetOk" to (parsed["secondaryTargetOk"]?.equals("true", ignoreCase = true) ?: false),
            "primarySampleReadOk" to (parsed["primarySampleReadOk"]?.equals("true", ignoreCase = true) ?: false),
            "secondarySampleReadOk" to (parsed["secondarySampleReadOk"]?.equals("true", ignoreCase = true) ?: false),
            "deterministicColorSide" to (parsed["deterministicColorSide"] ?: ""),
            "deterministicColorOk" to (parsed["deterministicColorOk"]?.equals("true", ignoreCase = true) ?: false),
            "presentLane" to (parsed["presentLane"] ?: "not_run"),
            "presentLaneLastError" to (parsed["presentLaneLastError"] ?: ""),
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

    private fun failureResult(
        reason: String,
        descriptorParseStatus: String = "not_run",
        descriptorParseLastError: String = "",
    ): String =
        "status=FAIL;width=0;height=0;clientVersion=0;vendor=;renderer=;version=;" +
        "rgbaADescribe=not_run;rgbaAFill=not_run;rgbaBDescribe=not_run;rgbaBFill=not_run;" +
        "ycbcrADescribe=not_run;ycbcrAFormatIs420888=false;ycbcrBDescribe=not_run;ycbcrBFormatIs420888=false;" +
        "initialize=not_run;attach=not_run;" +
        "importRgbaA=not_run;handleRgbaA=0;targetRgbaA=0;importRgbaB=not_run;handleRgbaB=0;targetRgbaB=0;" +
        "importYcbcrA=not_run;handleYcbcrA=0;targetYcbcrA=0;importYcbcrB=not_run;handleYcbcrB=0;targetYcbcrB=0;" +
        "descriptorParse=$descriptorParseStatus;descriptorParseLastError=$descriptorParseLastError;" +
        "layoutModeResolved=;anchorResolved=;directionResolved=;" +
        "layoutConvert=not_run;layoutConvertLastError=;" +
        "primaryRectX=0;primaryRectY=0;primaryRectW=0;primaryRectH=0;" +
        "secondaryRectX=0;secondaryRectY=0;secondaryRectW=0;secondaryRectH=0;" +
        "renderLaneMode=;primaryTextureKind=;secondaryTextureKind=;" +
        "renderDraw=not_run;renderDrawLastError=;" +
        "primaryTargetOk=false;secondaryTargetOk=false;" +
        "primarySampleReadOk=false;secondarySampleReadOk=false;" +
        "deterministicColorSide=;deterministicColorOk=false;" +
        "presentLane=not_run;presentLaneLastError=;" +
        "releaseRgbaA=not_run;releaseRgbaAFence=-1;hasRgbaAAfterRelease=false;" +
        "releaseRgbaB=not_run;releaseRgbaBFence=-1;hasRgbaBAfterRelease=false;" +
        "releaseYcbcrA=not_run;releaseYcbcrAFence=-1;hasYcbcrAAfterRelease=false;" +
        "releaseYcbcrB=not_run;releaseYcbcrBFence=-1;hasYcbcrBAfterRelease=false;" +
        "postReleaseLane=not_run;postReleaseLastError=;detach=not_run;shutdown=not_run;idempotentShutdown=not_run;" +
        "proofBoundary=$PROOF_BOUNDARY;lastError=$reason"
}
