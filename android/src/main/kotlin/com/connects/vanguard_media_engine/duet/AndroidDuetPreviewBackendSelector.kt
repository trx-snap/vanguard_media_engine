package com.connects.vanguard_media_engine.duet

import android.os.Build
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge

object AndroidDuetPreviewBackendSelector {
    private const val TAG = "DuetBackendSelector"

    fun select(requested: AndroidDuetPreviewBackendId): AndroidDuetPreviewBackendSelection {
        if (requested == AndroidDuetPreviewBackendId.GLES) {
            return AndroidDuetPreviewBackendSelection(
                requested = requested,
                actual = AndroidDuetPreviewBackendId.GLES,
                fallbackReason = null,
            )
        }

        // Vulkan ImageReader HardwareBuffer usage requires Android Q (API 29+)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.w(TAG, "Vulkan requested but API level ${Build.VERSION.SDK_INT} < Q; falling back to GLES")
            return AndroidDuetPreviewBackendSelection(
                requested = requested,
                actual = AndroidDuetPreviewBackendId.GLES,
                fallbackReason = "api_level_below_q",
            )
        }

        // Fail-closed Vulkan capability probe
        return try {
            val probeHandle = VanguardNativeBridge.createAndroidDuetVulkanPreviewSession()
            if (probeHandle == 0L) {
                Log.w(TAG, "Vulkan preview session capability probe failed; falling back to GLES")
                AndroidDuetPreviewBackendSelection(
                    requested = requested,
                    actual = AndroidDuetPreviewBackendId.GLES,
                    fallbackReason = "probe_failed",
                )
            } else {
                VanguardNativeBridge.destroyAndroidDuetVulkanPreviewSession(probeHandle)
                AndroidDuetPreviewBackendSelection(
                    requested = requested,
                    actual = AndroidDuetPreviewBackendId.VULKAN,
                    fallbackReason = null,
                )
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Vulkan capability probe threw exception; falling back to GLES", t)
            AndroidDuetPreviewBackendSelection(
                requested = requested,
                actual = AndroidDuetPreviewBackendId.GLES,
                fallbackReason = "probe_exception:${t.message ?: "unknown"}",
            )
        }
    }
}
