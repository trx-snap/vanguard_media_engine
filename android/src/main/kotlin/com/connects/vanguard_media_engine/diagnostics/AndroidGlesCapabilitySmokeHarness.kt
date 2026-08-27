package com.connects.vanguard_media_engine.diagnostics

import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver

object AndroidGlesCapabilitySmokeHarness {
    private const val TAG = "VanguardDagSmoke"

    // ── Phase 1-Unit AI: Android GLES/EGL extension and native-fence capability inventory physical proof ──
    private const val RESULT_MARKER_PHASE1AI = "ANDROID_GLES_EXTENSION_CAPABILITY_UNIT_AI_NATIVE_RESULT"

    fun runGlesExtensionCapabilitySmoke(): Map<String, Any?> {
        var raw = glesExtensionCapabilityFailure("not_run")
        try {
            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1AIGlesExtensionCapabilitySmoke()
            return parseGlesExtensionCapabilityResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesExtensionCapabilityFailure("exception:$reason")
            return parseGlesExtensionCapabilityResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AI $raw")
        }
    }

    private fun parseGlesExtensionCapabilityResult(raw: String): Map<String, Any?> {
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
        val eglExtensionsAvailable = parsed["eglExtensionsAvailable"]?.equals("true", ignoreCase = true) ?: false
        val glExtensionsAvailable = parsed["glExtensionsAvailable"]?.equals("true", ignoreCase = true) ?: false
        val hasEglAndroidImageNativeBuffer = parsed["hasEglAndroidImageNativeBuffer"]?.equals("true", ignoreCase = true) ?: false
        val hasEglAndroidGetNativeClientBuffer = parsed["hasEglAndroidGetNativeClientBuffer"]?.equals("true", ignoreCase = true) ?: false
        val hasEglKhrImageBase = parsed["hasEglKhrImageBase"]?.equals("true", ignoreCase = true) ?: false
        val hasEglAndroidNativeFenceSync = parsed["hasEglAndroidNativeFenceSync"]?.equals("true", ignoreCase = true) ?: false
        val hasEglKhrFenceSync = parsed["hasEglKhrFenceSync"]?.equals("true", ignoreCase = true) ?: false
        val hasGlOesEglImage = parsed["hasGlOesEglImage"]?.equals("true", ignoreCase = true) ?: false
        val hasGlOesEglImageExternal = parsed["hasGlOesEglImageExternal"]?.equals("true", ignoreCase = true) ?: false
        val hasGlExtYuvTarget = parsed["hasGlExtYuvTarget"]?.equals("true", ignoreCase = true) ?: false
        val symbolEglGetNativeClientBufferAndroid = parsed["symbolEglGetNativeClientBufferAndroid"]?.equals("true", ignoreCase = true) ?: false
        val symbolEglCreateImageKhr = parsed["symbolEglCreateImageKhr"]?.equals("true", ignoreCase = true) ?: false
        val symbolEglDestroyImageKhr = parsed["symbolEglDestroyImageKhr"]?.equals("true", ignoreCase = true) ?: false
        val symbolGlEglImageTargetTexture2DOes = parsed["symbolGlEglImageTargetTexture2DOes"]?.equals("true", ignoreCase = true) ?: false
        val symbolEglCreateSyncKhr = parsed["symbolEglCreateSyncKhr"]?.equals("true", ignoreCase = true) ?: false
        val symbolEglDestroySyncKhr = parsed["symbolEglDestroySyncKhr"]?.equals("true", ignoreCase = true) ?: false
        val symbolEglDupNativeFenceFdAndroid = parsed["symbolEglDupNativeFenceFdAndroid"]?.equals("true", ignoreCase = true) ?: false
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_egl_extension_capability_inventory_no_import_no_render_no_product"
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
            "eglExtensionsAvailable" to eglExtensionsAvailable,
            "glExtensionsAvailable" to glExtensionsAvailable,
            "hasEglAndroidImageNativeBuffer" to hasEglAndroidImageNativeBuffer,
            "hasEglAndroidGetNativeClientBuffer" to hasEglAndroidGetNativeClientBuffer,
            "hasEglKhrImageBase" to hasEglKhrImageBase,
            "hasEglAndroidNativeFenceSync" to hasEglAndroidNativeFenceSync,
            "hasEglKhrFenceSync" to hasEglKhrFenceSync,
            "hasGlOesEglImage" to hasGlOesEglImage,
            "hasGlOesEglImageExternal" to hasGlOesEglImageExternal,
            "hasGlExtYuvTarget" to hasGlExtYuvTarget,
            "symbolEglGetNativeClientBufferAndroid" to symbolEglGetNativeClientBufferAndroid,
            "symbolEglCreateImageKhr" to symbolEglCreateImageKhr,
            "symbolEglDestroyImageKhr" to symbolEglDestroyImageKhr,
            "symbolGlEglImageTargetTexture2DOes" to symbolGlEglImageTargetTexture2DOes,
            "symbolEglCreateSyncKhr" to symbolEglCreateSyncKhr,
            "symbolEglDestroySyncKhr" to symbolEglDestroySyncKhr,
            "symbolEglDupNativeFenceFdAndroid" to symbolEglDupNativeFenceFdAndroid,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesExtensionCapabilityFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;initialize=not_run;" +
            "eglCurrentDisplayOk=false;eglExtensionsAvailable=false;glExtensionsAvailable=false;" +
            "hasEglAndroidImageNativeBuffer=false;hasEglAndroidGetNativeClientBuffer=false;" +
            "hasEglKhrImageBase=false;hasEglAndroidNativeFenceSync=false;hasEglKhrFenceSync=false;" +
            "hasGlOesEglImage=false;hasGlOesEglImageExternal=false;hasGlExtYuvTarget=false;" +
            "symbolEglGetNativeClientBufferAndroid=false;symbolEglCreateImageKhr=false;" +
            "symbolEglDestroyImageKhr=false;symbolGlEglImageTargetTexture2DOes=false;" +
            "symbolEglCreateSyncKhr=false;symbolEglDestroySyncKhr=false;symbolEglDupNativeFenceFdAndroid=false;" +
            "shutdown=not_run;idempotentShutdown=not_run;" +
            "proofBoundary=gles_egl_extension_capability_inventory_no_import_no_render_no_product;lastError=$reason"
}
