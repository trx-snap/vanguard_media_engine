package com.connects.vanguard_media_engine.diagnostics

import android.graphics.SurfaceTexture
import android.hardware.HardwareBuffer
import android.os.Build
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver

object AndroidGlesFenceSmokeHarness {
    private const val TAG = "VanguardDagSmoke"

    // ── Phase 1-Unit AJ: Android GLES EGL native-fence FD lifecycle physical proof ──
    private const val RESULT_MARKER_PHASE1AJ = "ANDROID_GLES_NATIVE_FENCE_FD_UNIT_AJ_NATIVE_RESULT"

    fun runGlesNativeFenceFdSmoke(): Map<String, Any?> {
        var raw = glesNativeFenceFdFailure("not_run")
        try {
            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1AJGlesNativeFenceFdSmoke()
            return parseGlesNativeFenceFdResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesNativeFenceFdFailure("exception:$reason")
            return parseGlesNativeFenceFdResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AJ $raw")
        }
    }

    private fun parseGlesNativeFenceFdResult(raw: String): Map<String, Any?> {
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
        val initialize = parsed["initialize"] ?: "not_run"
        val eglCurrentDisplayOk = parsed["eglCurrentDisplayOk"]?.equals("true", ignoreCase = true) ?: false
        val symbolsResolved = parsed["symbolsResolved"]?.equals("true", ignoreCase = true) ?: false
        val nativeFenceSyncCreate = parsed["nativeFenceSyncCreate"] ?: "not_run"
        val glFlushOk = parsed["glFlushOk"]?.equals("true", ignoreCase = true) ?: false
        val dupNativeFenceFd = parsed["dupNativeFenceFd"]?.toIntOrNull() ?: -1
        val fdOpenBeforeClose = parsed["fdOpenBeforeClose"]?.equals("true", ignoreCase = true) ?: false
        val waitOutcome = parsed["waitOutcome"] ?: "not_run"
        val waitSignaled = parsed["waitSignaled"]?.equals("true", ignoreCase = true) ?: false
        val closeResult = parsed["closeResult"] ?: "not_run"
        val fdClosedAfterClose = parsed["fdClosedAfterClose"]?.equals("true", ignoreCase = true) ?: false
        val destroySync = parsed["destroySync"] ?: "not_run"
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_native_fence_fd_lifecycle_no_releaseHardwareBuffer_path_no_import_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "initialize" to initialize,
            "eglCurrentDisplayOk" to eglCurrentDisplayOk,
            "symbolsResolved" to symbolsResolved,
            "nativeFenceSyncCreate" to nativeFenceSyncCreate,
            "glFlushOk" to glFlushOk,
            "dupNativeFenceFd" to dupNativeFenceFd,
            "fdOpenBeforeClose" to fdOpenBeforeClose,
            "waitOutcome" to waitOutcome,
            "waitSignaled" to waitSignaled,
            "closeResult" to closeResult,
            "fdClosedAfterClose" to fdClosedAfterClose,
            "destroySync" to destroySync,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesNativeFenceFdFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;initialize=not_run;" +
            "eglCurrentDisplayOk=false;symbolsResolved=false;nativeFenceSyncCreate=not_run;glFlushOk=false;" +
            "dupNativeFenceFd=-1;fdOpenBeforeClose=false;waitOutcome=not_run;waitSignaled=false;" +
            "closeResult=not_run;fdClosedAfterClose=false;destroySync=not_run;shutdown=not_run;idempotentShutdown=not_run;" +
            "proofBoundary=gles_native_fence_fd_lifecycle_no_releaseHardwareBuffer_path_no_import_no_product;lastError=$reason"

    // ── Phase 1-Unit AL: Android GLES releaseHardwareBuffer nullptr release-fence output physical proof ──
    private const val RESULT_MARKER_PHASE1AL = "ANDROID_GLES_RELEASE_NULL_FENCE_UNIT_AL_NATIVE_RESULT"

    fun runGlesReleaseNullFenceSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var hardwareBuffer: HardwareBuffer? = null
        var raw = glesReleaseNullFenceFailure("not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesReleaseNullFenceFailure("api_below_26")
                return parseGlesReleaseNullFenceResult(raw)
            }
            if (width <= 0 || height <= 0) {
                raw = glesReleaseNullFenceFailure("invalid_dimensions")
                return parseGlesReleaseNullFenceResult(raw)
            }

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
            raw = nativeBridge.runAndroidDagPhase1ALGlesReleaseNullFenceSmoke(
                hardwareBuffer,
                width,
                height,
            )
            return parseGlesReleaseNullFenceResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesReleaseNullFenceFailure("exception:$reason")
            return parseGlesReleaseNullFenceResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AL $raw")
            try {
                hardwareBuffer?.close()
            } catch (_: Throwable) {
            }
        }
    }

    private fun parseGlesReleaseNullFenceResult(raw: String): Map<String, Any?> {
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
        val bufferWidth = parsed["bufferWidth"]?.toIntOrNull() ?: 0
        val bufferHeight = parsed["bufferHeight"]?.toIntOrNull() ?: 0
        val bufferLayers = parsed["bufferLayers"]?.toIntOrNull() ?: 0
        val bufferFormat = parsed["bufferFormat"]?.toIntOrNull() ?: 0
        val bufferUsageSampled = parsed["bufferUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val initialize = parsed["initialize"] ?: "not_run"
        val import1 = parsed["import1"] ?: "not_run"
        val handle1 = parsed["handle1"]?.toLongOrNull() ?: 0L
        val desc1Width = parsed["desc1Width"]?.toIntOrNull() ?: 0
        val desc1Height = parsed["desc1Height"]?.toIntOrNull() ?: 0
        val desc1Layers = parsed["desc1Layers"]?.toIntOrNull() ?: 0
        val desc1Format = parsed["desc1Format"]?.toIntOrNull() ?: 0
        val desc1UsageSampled = parsed["desc1UsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasAfterImport1 = parsed["hasAfterImport1"]?.equals("true", ignoreCase = true) ?: false
        val nullFenceRelease1 = parsed["nullFenceRelease1"] ?: "not_run"
        val hasAfterNullFenceRelease1 = parsed["hasAfterNullFenceRelease1"]?.equals("true", ignoreCase = true) ?: false
        val nullFenceDoubleRelease1 = parsed["nullFenceDoubleRelease1"] ?: "not_run"
        val import2 = parsed["import2"] ?: "not_run"
        val handle2 = parsed["handle2"]?.toLongOrNull() ?: 0L
        val desc2Width = parsed["desc2Width"]?.toIntOrNull() ?: 0
        val desc2Height = parsed["desc2Height"]?.toIntOrNull() ?: 0
        val desc2Layers = parsed["desc2Layers"]?.toIntOrNull() ?: 0
        val desc2Format = parsed["desc2Format"]?.toIntOrNull() ?: 0
        val desc2UsageSampled = parsed["desc2UsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasAfterImport2 = parsed["hasAfterImport2"]?.equals("true", ignoreCase = true) ?: false
        val release2 = parsed["release2"] ?: "not_run"
        val release2Fence = parsed["release2Fence"]?.toIntOrNull() ?: -1
        val hasAfterRelease2 = parsed["hasAfterRelease2"]?.equals("true", ignoreCase = true) ?: false
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_release_null_fence_output_contract_release_fence_optional_no_render_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "bufferDescribe" to bufferDescribe,
            "bufferWidth" to bufferWidth,
            "bufferHeight" to bufferHeight,
            "bufferLayers" to bufferLayers,
            "bufferFormat" to bufferFormat,
            "bufferUsageSampled" to bufferUsageSampled,
            "initialize" to initialize,
            "import1" to import1,
            "handle1" to handle1,
            "desc1Width" to desc1Width,
            "desc1Height" to desc1Height,
            "desc1Layers" to desc1Layers,
            "desc1Format" to desc1Format,
            "desc1UsageSampled" to desc1UsageSampled,
            "hasAfterImport1" to hasAfterImport1,
            "nullFenceRelease1" to nullFenceRelease1,
            "hasAfterNullFenceRelease1" to hasAfterNullFenceRelease1,
            "nullFenceDoubleRelease1" to nullFenceDoubleRelease1,
            "import2" to import2,
            "handle2" to handle2,
            "desc2Width" to desc2Width,
            "desc2Height" to desc2Height,
            "desc2Layers" to desc2Layers,
            "desc2Format" to desc2Format,
            "desc2UsageSampled" to desc2UsageSampled,
            "hasAfterImport2" to hasAfterImport2,
            "release2" to release2,
            "release2Fence" to release2Fence,
            "hasAfterRelease2" to hasAfterRelease2,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesReleaseNullFenceFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;bufferDescribe=not_run;bufferWidth=0;bufferHeight=0;bufferLayers=0;bufferFormat=0;bufferUsageSampled=false;" +
            "initialize=not_run;import1=not_run;handle1=0;desc1Width=0;desc1Height=0;desc1Layers=0;desc1Format=0;desc1UsageSampled=false;hasAfterImport1=false;" +
            "nullFenceRelease1=not_run;hasAfterNullFenceRelease1=false;nullFenceDoubleRelease1=not_run;import2=not_run;handle2=0;desc2Width=0;desc2Height=0;desc2Layers=0;desc2Format=0;desc2UsageSampled=false;hasAfterImport2=false;" +
            "release2=not_run;release2Fence=-1;hasAfterRelease2=false;shutdown=not_run;idempotentShutdown=not_run;" +
            "proofBoundary=gles_release_null_fence_output_contract_release_fence_optional_no_render_no_product;lastError=$reason"

    // ── Phase 1-Unit AM: Android GLES renderFrame -> EGL native-fence GPU chain physical proof ──
    private const val RESULT_MARKER_PHASE1AM = "ANDROID_GLES_RENDER_FENCE_CHAIN_UNIT_AM_NATIVE_RESULT"

    fun runGlesRenderFenceChainSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
        var raw = glesRenderFenceChainFailure("not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesRenderFenceChainFailure("api_below_26")
                return parseGlesRenderFenceChainResult(raw)
            }
            if (width <= 0 || height <= 0) {
                raw = glesRenderFenceChainFailure("invalid_dimensions")
                return parseGlesRenderFenceChainResult(raw)
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
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
            )

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1AMGlesRenderFenceChainSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
            )
            return parseGlesRenderFenceChainResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesRenderFenceChainFailure("exception:$reason")
            return parseGlesRenderFenceChainResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AM $raw")
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

    private fun parseGlesRenderFenceChainResult(raw: String): Map<String, Any?> {
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
        val bufferWidth = parsed["bufferWidth"]?.toIntOrNull() ?: 0
        val bufferHeight = parsed["bufferHeight"]?.toIntOrNull() ?: 0
        val bufferLayers = parsed["bufferLayers"]?.toIntOrNull() ?: 0
        val bufferFormat = parsed["bufferFormat"]?.toIntOrNull() ?: 0
        val bufferUsageSampled = parsed["bufferUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val bufferUsageCpuWrite = parsed["bufferUsageCpuWrite"]?.equals("true", ignoreCase = true) ?: false
        val bufferFill = parsed["bufferFill"] ?: "not_run"
        val writeFenceFd = parsed["writeFenceFd"]?.toIntOrNull() ?: -1
        val writeFenceWait = parsed["writeFenceWait"] ?: "none"
        val initialize = parsed["initialize"] ?: "not_run"
        val attach = parsed["attach"] ?: "not_run"
        val hasSurfaceAfterAttach = parsed["hasSurfaceAfterAttach"]?.equals("true", ignoreCase = true) ?: false
        val import = parsed["import"] ?: "not_run"
        val handle = parsed["handle"]?.toLongOrNull() ?: 0L
        val hasAfterImport = parsed["hasAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val renderFrame = parsed["renderFrame"] ?: "not_run"
        val eglCurrentDisplayOk = parsed["eglCurrentDisplayOk"]?.equals("true", ignoreCase = true) ?: false
        val symbolsResolved = parsed["symbolsResolved"]?.equals("true", ignoreCase = true) ?: false
        val nativeFenceSyncCreate = parsed["nativeFenceSyncCreate"] ?: "not_run"
        val glFlushOk = parsed["glFlushOk"]?.equals("true", ignoreCase = true) ?: false
        val dupNativeFenceFd = parsed["dupNativeFenceFd"]?.toIntOrNull() ?: -1
        val fdOpenBeforeClose = parsed["fdOpenBeforeClose"]?.equals("true", ignoreCase = true) ?: false
        val waitOutcome = parsed["waitOutcome"] ?: "not_run"
        val waitSignaled = parsed["waitSignaled"]?.equals("true", ignoreCase = true) ?: false
        val closeResult = parsed["closeResult"] ?: "not_run"
        val fdClosedAfterClose = parsed["fdClosedAfterClose"]?.equals("true", ignoreCase = true) ?: false
        val destroySync = parsed["destroySync"] ?: "not_run"
        val releaseBuffer = parsed["releaseBuffer"] ?: "not_run"
        val releaseFence = parsed["releaseFence"]?.toIntOrNull() ?: -1
        val hasAfterRelease = parsed["hasAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val detach = parsed["detach"] ?: "not_run"
        val surfaceKindAfterDetach = parsed["surfaceKindAfterDetach"] ?: "none"
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_renderFrame_native_fence_chain_release_fence_optional_no_yuv_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "bufferDescribe" to bufferDescribe,
            "bufferWidth" to bufferWidth,
            "bufferHeight" to bufferHeight,
            "bufferLayers" to bufferLayers,
            "bufferFormat" to bufferFormat,
            "bufferUsageSampled" to bufferUsageSampled,
            "bufferUsageCpuWrite" to bufferUsageCpuWrite,
            "bufferFill" to bufferFill,
            "writeFenceFd" to writeFenceFd,
            "writeFenceWait" to writeFenceWait,
            "initialize" to initialize,
            "attach" to attach,
            "hasSurfaceAfterAttach" to hasSurfaceAfterAttach,
            "import" to import,
            "handle" to handle,
            "hasAfterImport" to hasAfterImport,
            "renderFrame" to renderFrame,
            "eglCurrentDisplayOk" to eglCurrentDisplayOk,
            "symbolsResolved" to symbolsResolved,
            "nativeFenceSyncCreate" to nativeFenceSyncCreate,
            "glFlushOk" to glFlushOk,
            "dupNativeFenceFd" to dupNativeFenceFd,
            "fdOpenBeforeClose" to fdOpenBeforeClose,
            "waitOutcome" to waitOutcome,
            "waitSignaled" to waitSignaled,
            "closeResult" to closeResult,
            "fdClosedAfterClose" to fdClosedAfterClose,
            "destroySync" to destroySync,
            "releaseBuffer" to releaseBuffer,
            "releaseFence" to releaseFence,
            "hasAfterRelease" to hasAfterRelease,
            "detach" to detach,
            "surfaceKindAfterDetach" to surfaceKindAfterDetach,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesRenderFenceChainFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;bufferDescribe=not_run;bufferWidth=0;bufferHeight=0;bufferLayers=0;bufferFormat=0;bufferUsageSampled=false;bufferUsageCpuWrite=false;bufferFill=not_run;writeFenceFd=-1;writeFenceWait=none;initialize=not_run;attach=not_run;hasSurfaceAfterAttach=false;import=not_run;handle=0;hasAfterImport=false;renderFrame=not_run;eglCurrentDisplayOk=false;symbolsResolved=false;nativeFenceSyncCreate=not_run;glFlushOk=false;dupNativeFenceFd=-1;fdOpenBeforeClose=false;waitOutcome=not_run;waitSignaled=false;closeResult=not_run;fdClosedAfterClose=false;destroySync=not_run;releaseBuffer=not_run;releaseFence=-1;hasAfterRelease=false;detach=not_run;surfaceKindAfterDetach=none;shutdown=not_run;idempotentShutdown=not_run;proofBoundary=gles_renderFrame_native_fence_chain_release_fence_optional_no_yuv_no_product;lastError=$reason"

    // ── Phase 1-Unit AN: Android GLES acquire-fence import -> renderFrame content physical proof ──
    private const val RESULT_MARKER_PHASE1AN = "ANDROID_GLES_ACQUIRE_FENCE_RENDER_CONTENT_UNIT_AN_NATIVE_RESULT"

    fun runGlesAcquireFenceRenderContentSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
        var raw = glesAcquireFenceRenderContentFailure("not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesAcquireFenceRenderContentFailure("api_below_26")
                return parseGlesAcquireFenceRenderContentResult(raw)
            }
            if (width <= 0 || height <= 0) {
                raw = glesAcquireFenceRenderContentFailure("invalid_dimensions")
                return parseGlesAcquireFenceRenderContentResult(raw)
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
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
            )

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1ANGlesAcquireFenceRenderContentSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
            )
            return parseGlesAcquireFenceRenderContentResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesAcquireFenceRenderContentFailure("exception:$reason")
            return parseGlesAcquireFenceRenderContentResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AN $raw")
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

    private fun parseGlesAcquireFenceRenderContentResult(raw: String): Map<String, Any?> {
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
        val bufferWidth = parsed["bufferWidth"]?.toIntOrNull() ?: 0
        val bufferHeight = parsed["bufferHeight"]?.toIntOrNull() ?: 0
        val bufferLayers = parsed["bufferLayers"]?.toIntOrNull() ?: 0
        val bufferFormat = parsed["bufferFormat"]?.toIntOrNull() ?: 0
        val bufferUsageSampled = parsed["bufferUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val bufferUsageCpuWrite = parsed["bufferUsageCpuWrite"]?.equals("true", ignoreCase = true) ?: false
        val bufferFill = parsed["bufferFill"] ?: "not_run"
        val writeFenceFd = parsed["writeFenceFd"]?.toIntOrNull() ?: -1
        val writeFenceWait = parsed["writeFenceWait"] ?: "none"
        val initialize = parsed["initialize"] ?: "not_run"
        val eglCurrentDisplayOk = parsed["eglCurrentDisplayOk"]?.equals("true", ignoreCase = true) ?: false
        val symbolsResolved = parsed["symbolsResolved"]?.equals("true", ignoreCase = true) ?: false
        val acquireFenceCreate = parsed["acquireFenceCreate"] ?: "not_run"
        val glFlushOk = parsed["glFlushOk"]?.equals("true", ignoreCase = true) ?: false
        val acquireFenceFd = parsed["acquireFenceFd"]?.toIntOrNull() ?: -1
        val acquireFenceOpenBeforeImport = parsed["acquireFenceOpenBeforeImport"]?.equals("true", ignoreCase = true) ?: false
        val acquireFenceDestroyed = parsed["acquireFenceDestroyed"]?.equals("true", ignoreCase = true) ?: false
        val attach = parsed["attach"] ?: "not_run"
        val hasSurfaceAfterAttach = parsed["hasSurfaceAfterAttach"]?.equals("true", ignoreCase = true) ?: false
        val import = parsed["import"] ?: "not_run"
        val acquireFenceClosedAfterImport = parsed["acquireFenceClosedAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val handle = parsed["handle"]?.toLongOrNull() ?: 0L
        val descriptorWidth = parsed["descriptorWidth"]?.toIntOrNull() ?: 0
        val descriptorHeight = parsed["descriptorHeight"]?.toIntOrNull() ?: 0
        val descriptorLayers = parsed["descriptorLayers"]?.toIntOrNull() ?: 0
        val descriptorFormat = parsed["descriptorFormat"]?.toIntOrNull() ?: 0
        val descriptorUsageSampled = parsed["descriptorUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasAfterImport = parsed["hasAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val diagnosticRender = parsed["diagnosticRender"] ?: "not_run"
        val centerRead = parsed["centerRead"] ?: "not_run"
        val centerR = parsed["centerR"]?.toIntOrNull() ?: 0
        val centerG = parsed["centerG"]?.toIntOrNull() ?: 0
        val centerB = parsed["centerB"]?.toIntOrNull() ?: 0
        val centerA = parsed["centerA"]?.toIntOrNull() ?: 0
        val centerPixelMatches = parsed["centerPixelMatches"]?.equals("true", ignoreCase = true) ?: false
        val releaseBuffer = parsed["releaseBuffer"] ?: "not_run"
        val releaseFence = parsed["releaseFence"]?.toIntOrNull() ?: -1
        val hasAfterRelease = parsed["hasAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val detach = parsed["detach"] ?: "not_run"
        val surfaceKindAfterDetach = parsed["surfaceKindAfterDetach"] ?: "none"
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_acquire_fence_import_render_content_release_fence_optional_no_yuv_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "bufferDescribe" to bufferDescribe,
            "bufferWidth" to bufferWidth,
            "bufferHeight" to bufferHeight,
            "bufferLayers" to bufferLayers,
            "bufferFormat" to bufferFormat,
            "bufferUsageSampled" to bufferUsageSampled,
            "bufferUsageCpuWrite" to bufferUsageCpuWrite,
            "bufferFill" to bufferFill,
            "writeFenceFd" to writeFenceFd,
            "writeFenceWait" to writeFenceWait,
            "initialize" to initialize,
            "eglCurrentDisplayOk" to eglCurrentDisplayOk,
            "symbolsResolved" to symbolsResolved,
            "acquireFenceCreate" to acquireFenceCreate,
            "glFlushOk" to glFlushOk,
            "acquireFenceFd" to acquireFenceFd,
            "acquireFenceOpenBeforeImport" to acquireFenceOpenBeforeImport,
            "acquireFenceDestroyed" to acquireFenceDestroyed,
            "attach" to attach,
            "hasSurfaceAfterAttach" to hasSurfaceAfterAttach,
            "import" to import,
            "acquireFenceClosedAfterImport" to acquireFenceClosedAfterImport,
            "handle" to handle,
            "descriptorWidth" to descriptorWidth,
            "descriptorHeight" to descriptorHeight,
            "descriptorLayers" to descriptorLayers,
            "descriptorFormat" to descriptorFormat,
            "descriptorUsageSampled" to descriptorUsageSampled,
            "hasAfterImport" to hasAfterImport,
            "diagnosticRender" to diagnosticRender,
            "centerRead" to centerRead,
            "centerR" to centerR,
            "centerG" to centerG,
            "centerB" to centerB,
            "centerA" to centerA,
            "centerPixelMatches" to centerPixelMatches,
            "releaseBuffer" to releaseBuffer,
            "releaseFence" to releaseFence,
            "hasAfterRelease" to hasAfterRelease,
            "detach" to detach,
            "surfaceKindAfterDetach" to surfaceKindAfterDetach,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesAcquireFenceRenderContentFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;bufferDescribe=not_run;bufferWidth=0;bufferHeight=0;bufferLayers=0;bufferFormat=0;bufferUsageSampled=false;bufferUsageCpuWrite=false;bufferFill=not_run;writeFenceFd=-1;writeFenceWait=none;initialize=not_run;eglCurrentDisplayOk=false;symbolsResolved=false;acquireFenceCreate=not_run;glFlushOk=false;acquireFenceFd=-1;acquireFenceOpenBeforeImport=false;acquireFenceDestroyed=false;attach=not_run;hasSurfaceAfterAttach=false;import=not_run;acquireFenceClosedAfterImport=false;handle=0;descriptorWidth=0;descriptorHeight=0;descriptorLayers=0;descriptorFormat=0;descriptorUsageSampled=false;hasAfterImport=false;diagnosticRender=not_run;centerRead=not_run;centerR=0;centerG=0;centerB=0;centerA=0;centerPixelMatches=false;releaseBuffer=not_run;releaseFence=-1;hasAfterRelease=false;detach=not_run;surfaceKindAfterDetach=none;shutdown=not_run;idempotentShutdown=not_run;proofBoundary=gles_acquire_fence_import_render_content_release_fence_optional_no_yuv_no_product;lastError=$reason"
}
