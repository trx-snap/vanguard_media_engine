package com.connects.vanguard_media_engine.diagnostics

import android.graphics.SurfaceTexture
import android.hardware.HardwareBuffer
import android.os.Build
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver

object AndroidDagRenderSmokeHarness {
    private const val TAG = "VanguardDagSmoke"
    private const val RESULT_MARKER = "ANDROID_DAG_PHASE2O2B3_NATIVE_RESULT"
    private const val RESULT_MARKER_PHASE2O2B4 = "ANDROID_DAG_PHASE2O2B4_NATIVE_RESULT"

    fun run(width: Int, height: Int): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
        var raw = smokeFailure("not_run", width, height)

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = smokeFailure("api_below_26", width, height)
                return result(raw, width, height)
            }
            if (width <= 0 || height <= 0) {
                raw = smokeFailure("invalid_dimensions", width, height)
                return result(raw, width, height)
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
            raw = nativeBridge.runAndroidDagRenderSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
            )
            return result(raw, width, height)
        } catch (throwable: Throwable) {
            raw = smokeFailure(
                throwable.javaClass.simpleName.ifEmpty { "unknown_exception" },
                width,
                height,
            )
            return result(raw, width, height)
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
            try {
                surfaceTexture?.release()
            } catch (_: Throwable) {
            }
        }
    }

    fun runMultiFrame(width: Int, height: Int, frameCount: Int): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
        var raw = smokeLoopFailure("not_run", width, height, frameCount)

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = smokeLoopFailure("api_below_26", width, height, frameCount)
                return loopResult(raw, width, height, frameCount)
            }
            if (width <= 0 || height <= 0 || frameCount <= 0) {
                raw = smokeLoopFailure("invalid_dimensions", width, height, frameCount)
                return loopResult(raw, width, height, frameCount)
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
            raw = nativeBridge.runAndroidDagRenderLoopSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
                frameCount,
            )
            return loopResult(raw, width, height, frameCount)
        } catch (throwable: Throwable) {
            raw = smokeLoopFailure(
                throwable.javaClass.simpleName.ifEmpty { "unknown_exception" },
                width,
                height,
                frameCount,
            )
            return loopResult(raw, width, height, frameCount)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE2O2B4 $raw")
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

    private fun result(raw: String, width: Int, height: Int): Map<String, Any?> = mapOf(
        "pass" to raw.startsWith("status=PASS;"),
        "raw" to raw,
        "width" to width,
        "height" to height,
    )

    private fun loopResult(raw: String, width: Int, height: Int, frameCount: Int): Map<String, Any?> = mapOf(
        "pass" to raw.startsWith("status=PASS;"),
        "raw" to raw,
        "width" to width,
        "height" to height,
        "frameCount" to frameCount,
    )

    private fun smokeFailure(reason: String, width: Int, height: Int): String =
        "status=FAIL;initialize=$reason;attach=not_run;import=not_run;" +
            "renderFrame=not_run;release=not_run;width=$width;height=$height"

    private fun smokeLoopFailure(reason: String, width: Int, height: Int, frameCount: Int): String =
        "status=FAIL;initialize=$reason;attach=not_run;import=not_run;renderedFrames=0;" +
            "frameCount=$frameCount;renderFrame=not_run;failingFrame=-1;release=not_run;width=$width;height=$height"

    // ── Phase 3C: DAG playhead evaluation smoke ───────────────────────────────
    private const val RESULT_MARKER_PHASE3C = "ANDROID_DAG_PHASE3C_NATIVE_RESULT"

    fun runDagEvaluationSmoke(
        width: Int = 64,
        height: Int = 64,
        frameCount: Int = 30,
        frameDurationUs: Long = 33333L,
    ): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
        var raw = dagEvalFailure("not_run", width, height, frameCount)

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = dagEvalFailure("api_below_26", width, height, frameCount)
                return dagEvalResult(raw, width, height, frameCount)
            }
            if (width <= 0 || height <= 0 || frameCount <= 0 || frameDurationUs <= 0) {
                raw = dagEvalFailure("invalid_params", width, height, frameCount)
                return dagEvalResult(raw, width, height, frameCount)
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
            raw = nativeBridge.runAndroidDagPhase3CEvalRenderSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
                frameCount,
                frameDurationUs,
            )
            return dagEvalResult(raw, width, height, frameCount)
        } catch (throwable: Throwable) {
            raw = dagEvalFailure(
                throwable.javaClass.simpleName.ifEmpty { "unknown_exception" },
                width,
                height,
                frameCount,
            )
            return dagEvalResult(raw, width, height, frameCount)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE3C $raw")
            try { hardwareBuffer?.close() } catch (_: Throwable) {}
            try { surface?.release() } catch (_: Throwable) {}
            try { surfaceTexture?.release() } catch (_: Throwable) {}
        }
    }

    private fun dagEvalResult(raw: String, width: Int, height: Int, frameCount: Int): Map<String, Any?> {
        val pass = raw.startsWith("status=PASS;")
        // Parse evaluatedPtsUs from the structured status string if available.
        val evaluatedPtsUs: Long = run {
            val key = "evaluatedPtsUs="
            val idx = raw.indexOf(key)
            if (idx < 0) return@run 0L
            val start = idx + key.length
            val end = raw.indexOf(';', start).let { if (it < 0) raw.length else it }
            raw.substring(start, end).toLongOrNull() ?: 0L
        }
        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "width" to width,
            "height" to height,
            "frameCount" to frameCount,
            "evaluatedPtsUs" to evaluatedPtsUs,
        )
    }

    private fun dagEvalFailure(reason: String, width: Int, height: Int, frameCount: Int): String =
        "status=FAIL;initialize=$reason;attach=not_run;graphBuild=not_run;import=not_run;" +
            "evaluation=not_run;renderedFrames=0;frameCount=$frameCount;evaluatedPtsUs=0;" +
            "renderFrame=not_run;failingFrame=-1;release=not_run;width=$width;height=$height"

    // ── Phase 2Q: direct capability-probe smoke ──────────────────────────────
    private const val RESULT_MARKER_PHASE2Q = "ANDROID_DAG_PHASE2Q_CAPABILITY_PROBE_RESULT"

    fun runCapabilityProbe(): Map<String, Any?> {
        return try {
            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            val report = nativeBridge.probeCapabilities()
            diagnostics.logCapabilities(report)

            val pass = report.vulkanSupported &&
                report.selectedBackend == 0 &&
                report.fallbackReason == "none" &&
                report.profileGateStatus == "avp2022_partial_pass" &&
                report.blacklistStatus == "not_blacklisted" &&
                report.gpuVendor.isNotEmpty() &&
                report.gpuRenderer.isNotEmpty() &&
                report.vendorId != 0L &&
                report.deviceId != 0L &&
                report.apiVersion != 0L &&
                report.vulkanDriverVersion != 0L

            val result = mapOf<String, Any?>(
                "pass" to pass,
                "vulkanSupported" to report.vulkanSupported,
                "selectedBackend" to report.selectedBackend,
                "fallbackReason" to report.fallbackReason,
                "gpuVendor" to report.gpuVendor,
                "gpuRenderer" to report.gpuRenderer,
                "vendorId" to report.vendorId,
                "deviceId" to report.deviceId,
                "apiVersion" to report.apiVersion,
                "vulkanDriverVersion" to report.vulkanDriverVersion,
                "profileGateStatus" to report.profileGateStatus,
                "blacklistStatus" to report.blacklistStatus,
            )
            Log.i(TAG, "$RESULT_MARKER_PHASE2Q pass=$pass $report")
            result
        } catch (throwable: Throwable) {
            val simpleName = throwable.javaClass.simpleName.ifEmpty { "UnknownException" }
            val result = mapOf<String, Any?>(
                "pass" to false,
                "vulkanSupported" to false,
                "selectedBackend" to 2,
                "fallbackReason" to "exception:$simpleName",
                "gpuVendor" to "",
                "gpuRenderer" to "",
                "vendorId" to 0L,
                "deviceId" to 0L,
                "apiVersion" to 0L,
                "vulkanDriverVersion" to 0L,
                "profileGateStatus" to "probe_exception",
                "blacklistStatus" to "not_evaluated",
            )
            Log.e(TAG, "$RESULT_MARKER_PHASE2Q exception=$simpleName", throwable)
            result
        }
    }
}
