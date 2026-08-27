package com.connects.vanguard_media_engine.diagnostics

import android.graphics.SurfaceTexture
import android.hardware.HardwareBuffer
import android.os.Build
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver

object AndroidGlesReleaseFenceProductionSmokeHarness {
    private const val TAG = "VanguardDagSmoke"

    // ── Phase 1-Unit AK: Android GLES releaseHardwareBuffer live release-fence output physical proof ──
    private const val RESULT_MARKER_PHASE1AK = "ANDROID_GLES_RELEASE_FENCE_PRODUCTION_UNIT_AK_NATIVE_RESULT"

    fun runGlesReleaseFenceProductionSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
        var raw = glesReleaseFenceProductionFailure("not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesReleaseFenceProductionFailure("api_below_26")
                return parseGlesReleaseFenceProductionResult(raw)
            }
            if (width <= 0 || height <= 0) {
                raw = glesReleaseFenceProductionFailure("invalid_dimensions")
                return parseGlesReleaseFenceProductionResult(raw)
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
            raw = nativeBridge.runAndroidDagPhase1AKGlesReleaseFenceProductionSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
            )
            return parseGlesReleaseFenceProductionResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesReleaseFenceProductionFailure("exception:$reason")
            return parseGlesReleaseFenceProductionResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AK $raw")
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

    private fun parseGlesReleaseFenceProductionResult(raw: String): Map<String, Any?> {
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
        val bufferDescribe = parsed["bufferDescribe"] ?: "not_run"
        val initialize = parsed["initialize"] ?: "not_run"
        val attach = parsed["attach"] ?: "not_run"
        val import = parsed["import"] ?: "not_run"
        val handle = parsed["handle"]?.toLongOrNull() ?: 0L
        val diagnosticRender = parsed["diagnosticRender"] ?: "not_run"
        val releaseBuffer = parsed["releaseBuffer"] ?: "not_run"
        val releaseFenceFd = parsed["releaseFenceFd"]?.toIntOrNull() ?: -1
        val releaseFenceHighFd = parsed["releaseFenceHighFd"]?.toIntOrNull() ?: -1
        val releaseFenceHighFdOpen = parsed["releaseFenceHighFdOpen"]?.equals("true", ignoreCase = true) ?: false
        val releaseFenceWaitOutcome = parsed["releaseFenceWaitOutcome"] ?: "not_run"
        val releaseFenceWaitSignaled = parsed["releaseFenceWaitSignaled"]?.equals("true", ignoreCase = true) ?: false
        val releaseFenceOriginalClose = parsed["releaseFenceOriginalClose"] ?: "not_run"
        val releaseFenceHighClose = parsed["releaseFenceHighClose"] ?: "not_run"
        val releaseFenceHighFdClosedAfterClose = parsed["releaseFenceHighFdClosedAfterClose"]?.equals("true", ignoreCase = true) ?: false
        val hasAfterRelease = parsed["hasAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val doubleRelease = parsed["doubleRelease"] ?: "not_run"
        val doubleReleaseFence = parsed["doubleReleaseFence"]?.toIntOrNull() ?: -1
        val detach = parsed["detach"] ?: "not_run"
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_release_fence_production_fd_live_poll_close_no_yuv_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "bufferDescribe" to bufferDescribe,
            "initialize" to initialize,
            "attach" to attach,
            "import" to import,
            "handle" to handle,
            "diagnosticRender" to diagnosticRender,
            "releaseBuffer" to releaseBuffer,
            "releaseFenceFd" to releaseFenceFd,
            "releaseFenceHighFd" to releaseFenceHighFd,
            "releaseFenceHighFdOpen" to releaseFenceHighFdOpen,
            "releaseFenceWaitOutcome" to releaseFenceWaitOutcome,
            "releaseFenceWaitSignaled" to releaseFenceWaitSignaled,
            "releaseFenceOriginalClose" to releaseFenceOriginalClose,
            "releaseFenceHighClose" to releaseFenceHighClose,
            "releaseFenceHighFdClosedAfterClose" to releaseFenceHighFdClosedAfterClose,
            "hasAfterRelease" to hasAfterRelease,
            "doubleRelease" to doubleRelease,
            "doubleReleaseFence" to doubleReleaseFence,
            "detach" to detach,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesReleaseFenceProductionFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;bufferDescribe=not_run;initialize=not_run;attach=not_run;import=not_run;handle=0;diagnosticRender=not_run;releaseBuffer=not_run;releaseFenceFd=-1;releaseFenceHighFd=-1;releaseFenceHighFdOpen=false;releaseFenceWaitOutcome=not_run;releaseFenceWaitSignaled=false;releaseFenceOriginalClose=not_run;releaseFenceHighClose=not_run;releaseFenceHighFdClosedAfterClose=false;hasAfterRelease=false;doubleRelease=not_run;doubleReleaseFence=-1;detach=not_run;shutdown=not_run;idempotentShutdown=not_run;proofBoundary=gles_release_fence_production_fd_live_poll_close_no_yuv_no_product;lastError=$reason"
}
