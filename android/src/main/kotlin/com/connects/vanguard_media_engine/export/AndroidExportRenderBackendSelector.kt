package com.connects.vanguard_media_engine.export

import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver

// ── AndroidExportRenderBackendSelector ────────────────────────────────────────
//
// Owns Android export render-backend selection policy, isolated from
// AndroidTimelineExportSession's lifecycle/result ownership. New export
// development treats Vulkan as the preferred/default render backend; GLES is
// the fallback for unsupported capability, hardware/driver/init/render
// failure, or -- until a native Vulkan export baseline exists -- the current
// frozen GLES export path itself (AndroidTimelineVideoEncoder). No native
// Vulkan export is implemented by this slice, so [select] always resolves
// [ExportRenderBackendDecision.actualBackend] to GLES; it exists so backend
// selection is explicit and logged today, and so a later slice can flip
// [actualBackend] without changing AndroidTimelineExportSession's call site.
enum class ExportRenderBackend {
    VULKAN,
    GLES,
    UNAVAILABLE,
    ;

    fun wireName(): String = when (this) {
        VULKAN -> "vulkan"
        GLES -> "gles"
        UNAVAILABLE -> "unavailable"
    }
}

data class ExportRenderBackendDecision(
    val preferredBackend: ExportRenderBackend,
    val actualBackend: ExportRenderBackend,
    val reason: String,
    val vulkanSupported: Boolean,
    val glesSupported: Boolean,
    val selectedCapabilityBackend: ExportRenderBackend,
)

class AndroidExportRenderBackendSelector {

    /// Probes native backend capabilities and resolves this export run's
    /// backend decision. Never throws -- a probe exception is captured into
    /// the decision's [ExportRenderBackendDecision.reason] and still resolves
    /// to GLES, since AndroidTimelineVideoEncoder (GLES) is the only
    /// implemented export render path in this slice. Logs exactly one
    /// VG_EXPORT_BACKEND_SELECTED row; never logs per-frame.
    fun select(): ExportRenderBackendDecision {
        val decision = try {
            val diagnostics = VanguardDiagnostics()
            val lifecycleObserver = VanguardLifecycleObserver(diagnostics)
            val nativeBridge = VanguardNativeBridge(lifecycleObserver, diagnostics, null)
            val report = nativeBridge.probeCapabilities()
            diagnostics.logCapabilities(report)

            // The native library's own selection, factoring in blacklist/driver
            // gating beyond the raw vulkanSupported/glesSupported flags.
            val capabilityBackend = when (report.selectedBackend) {
                0 -> ExportRenderBackend.VULKAN
                1 -> ExportRenderBackend.GLES
                else -> ExportRenderBackend.UNAVAILABLE
            }

            // This selector's own architectural preference, computed from the
            // raw capability flags -- may diverge from [capabilityBackend] when
            // the native library gates a raw-capable Vulkan device to GLES.
            val preferredBackend = when {
                report.vulkanSupported -> ExportRenderBackend.VULKAN
                report.glesSupported -> ExportRenderBackend.GLES
                else -> ExportRenderBackend.UNAVAILABLE
            }

            val reason = when (capabilityBackend) {
                ExportRenderBackend.VULKAN -> "vulkan_export_backend_not_yet_implemented"
                ExportRenderBackend.GLES, ExportRenderBackend.UNAVAILABLE -> report.fallbackReason
            }

            ExportRenderBackendDecision(
                preferredBackend = preferredBackend,
                actualBackend = ExportRenderBackend.GLES,
                reason = reason,
                vulkanSupported = report.vulkanSupported,
                glesSupported = report.glesSupported,
                selectedCapabilityBackend = capabilityBackend,
            )
        } catch (t: Throwable) {
            Log.e(TAG, "capability probe failed: $t", t)
            ExportRenderBackendDecision(
                preferredBackend = ExportRenderBackend.UNAVAILABLE,
                actualBackend = ExportRenderBackend.GLES,
                reason = "capability_probe_failed:${t.javaClass.simpleName}",
                vulkanSupported = false,
                glesSupported = false,
                selectedCapabilityBackend = ExportRenderBackend.UNAVAILABLE,
            )
        }

        Log.i(
            TAG,
            "VG_EXPORT_BACKEND_SELECTED preferred=${decision.preferredBackend.wireName()} " +
                "actual=${decision.actualBackend.wireName()} reason=${decision.reason} " +
                "capability=${decision.selectedCapabilityBackend.wireName()}",
        )
        return decision
    }

    companion object {
        private const val TAG = "VGExportBackendSelector"
    }
}
