package com.connects.vanguard_media_engine.export

import android.os.Build
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver

// ── AndroidExportRenderBackendSelector ────────────────────────────────────────
//
// Owns Android export render-backend selection policy, isolated from
// AndroidTimelineExportSession's lifecycle/result ownership. Vulkan is the
// preferred/default render backend for new export development; GLES
// (AndroidTimelineVideoEncoder) is the fallback for unsupported capability,
// hardware/driver/init/render failure, or a request/clip shape outside the
// narrow safe scope this slice implements for the native Vulkan export path
// (AndroidTimelineVulkanVideoEncoder) -- see [vulkanScopeFailureReason]. Any
// clip carrying a non-null colorMatrix (Phase 10) also falls outside this
// scope -- the Vulkan export path does not implement colorMatrix -- and that
// check is evaluated deterministically before any other scope failure.
// AndroidTimelineExportSession additionally falls back to GLES mid-export if
// a selected Vulkan encode attempt fails before pass-2/finalization; that
// runtime fallback is session-owned and does not change this selector's
// [select] decision.
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

/// Describes the exportTimeline pass-1 request shape [AndroidExportRenderBackendSelector.select]
/// evaluates against the Vulkan safe-scope predicate. Absent (null) when a
/// caller has no clip/request context yet -- [AndroidExportRenderBackendSelector.select]
/// then never resolves to Vulkan, since the safe-scope predicate cannot be
/// evaluated without it.
data class ExportRenderScope(
    val clips: List<AndroidTimelineVideoEncoder.ClipInput>,
    val requestedWidth: Int,
    val requestedHeight: Int,
)

class AndroidExportRenderBackendSelector {

    /// Probes native backend capabilities and resolves this export run's
    /// backend decision. Never throws -- a probe exception is captured into
    /// the decision's [ExportRenderBackendDecision.reason] and still resolves
    /// to GLES. When the native capability probe itself resolves to Vulkan,
    /// [ExportRenderBackendDecision.actualBackend] only becomes Vulkan if
    /// [scope] is non-null and [vulkanScopeFailureReason] returns null;
    /// otherwise this resolves to GLES with that failure reason (e.g.
    /// "vulkan_scope_not_supported", or "vulkan_color_matrix_not_supported"
    /// when any clip carries a colorMatrix), even though the device itself is
    /// Vulkan-capable. Logs exactly one
    /// VG_EXPORT_BACKEND_SELECTED row; never logs per-frame.
    ///
    /// [nativeBridge], when non-null, is reused as-is (e.g. the same
    /// session-owned bridge later passed to AndroidTimelineVulkanVideoEncoder)
    /// instead of this selector constructing its own -- callers that have no
    /// bridge yet (existing `AndroidExportRenderBackendSelector().select()`
    /// call sites) keep working unchanged via the default.
    fun select(
        scope: ExportRenderScope? = null,
        nativeBridge: VanguardNativeBridge? = null,
    ): ExportRenderBackendDecision {
        val decision = try {
            val diagnostics = VanguardDiagnostics()
            val bridge = nativeBridge ?: run {
                val lifecycleObserver = VanguardLifecycleObserver(diagnostics)
                VanguardNativeBridge(lifecycleObserver, diagnostics, null)
            }
            val report = bridge.probeCapabilities()
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

            val actualBackend: ExportRenderBackend
            val reason: String
            when (capabilityBackend) {
                ExportRenderBackend.VULKAN -> {
                    val scopeFailureReason = vulkanScopeFailureReason(scope)
                    if (scopeFailureReason == null) {
                        actualBackend = ExportRenderBackend.VULKAN
                        reason = "vulkan_export_scope_supported"
                    } else {
                        actualBackend = ExportRenderBackend.GLES
                        reason = scopeFailureReason
                    }
                }
                ExportRenderBackend.GLES, ExportRenderBackend.UNAVAILABLE -> {
                    actualBackend = ExportRenderBackend.GLES
                    reason = report.fallbackReason
                }
            }

            ExportRenderBackendDecision(
                preferredBackend = preferredBackend,
                actualBackend = actualBackend,
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

    /// The safe scope this slice implements for
    /// AndroidTimelineVulkanVideoEncoder: API 29+ (ImageReader hardware-buffer
    /// path), at least one clip, every clip video-kind, positive requested
    /// output dimensions, positive decoded clip dimensions, cardinal
    /// 0/90/180/270 rotation, and no clip carrying a colorMatrix (Phase 10 --
    /// the Vulkan export path does not implement colorMatrix).
    /// AndroidTimelineVulkanVideoEncoder itself computes an
    /// aspect-preserving-fit destination rect per clip (see its own geometry
    /// computation) rather than requiring decoded dimensions to exactly match
    /// the (possibly rotation-swapped) output geometry, so this predicate no
    /// longer checks for that exact/swapped equality.
    ///
    /// Returns null when [scope] is safe for Vulkan, or a machine-readable
    /// failure reason otherwise. The colorMatrix check is evaluated first --
    /// deterministically, before any other scope failure -- so a clip with a
    /// colorMatrix always resolves to reason "vulkan_color_matrix_not_supported"
    /// regardless of what else about [scope] might also be unsafe. Any other
    /// unsafe shape (still images, unsupported/non-cardinal rotation,
    /// non-positive output or decoded dimensions, empty clip list, API < 29,
    /// or no scope at all) resolves to "vulkan_scope_not_supported".
    private fun vulkanScopeFailureReason(scope: ExportRenderScope?): String? {
        if (scope != null && scope.clips.any { it.colorMatrix != null }) {
            return "vulkan_color_matrix_not_supported"
        }
        if (scope == null) return "vulkan_scope_not_supported"
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return "vulkan_scope_not_supported"
        if (scope.clips.isEmpty()) return "vulkan_scope_not_supported"
        if (scope.requestedWidth <= 0 || scope.requestedHeight <= 0) return "vulkan_scope_not_supported"
        val allSafe = scope.clips.all { clip ->
            if (clip.mediaKind != "video") return@all false
            if (clip.decodedWidth <= 0 || clip.decodedHeight <= 0) return@all false
            when (clip.rotationDegrees) {
                0, 90, 180, 270 -> true
                else -> false
            }
        }
        return if (allSafe) null else "vulkan_scope_not_supported"
    }

    companion object {
        private const val TAG = "VGExportBackendSelector"
    }
}
