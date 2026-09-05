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
// (AndroidTimelineVulkanVideoEncoder) -- see [vulkanScopeFailureReason]. Phase
// 10: a clip carrying a non-null colorMatrix is within the Vulkan safe scope
// -- the native Vulkan export path applies colorMatrix itself (see
// AndroidTimelineVulkanVideoEncoder / android_vulkan_export_jni.cpp), so it no
// longer forces a GLES fallback. AndroidTimelineExportSession additionally
// falls back to GLES mid-export if a selected Vulkan encode attempt fails
// before pass-2/finalization (a genuine capability/init/render failure); that
// runtime fallback is session-owned and does not change this selector's
// [select] decision.
//
// P5-COMPOSITOR-TRANS: a scope carrying non-hard-cut transitions REQUIRES
// Vulkan. When Vulkan cannot be selected for such a scope (capability probe
// gates it, probe failure, or the clip shape is outside the Vulkan safe
// scope), [select] resolves to [ExportRenderBackend.UNAVAILABLE] with a
// `transitions_require_vulkan:<underlying reason>` reason instead of GLES --
// there is no GLES transition route, and silently degrading an overlap
// timeline to hard cuts is wrong output. AndroidTimelineExportSession turns
// that into UNSUPPORTED_EXPORT_FEATURE before pass-1 and also disables its
// mid-export GLES fallback for transition timelines.
//
// P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: a scope carrying any clip with a
// non-null [AndroidTimelineVideoEncoder.ClipInput.beautyIntensity] ALSO
// REQUIRES Vulkan -- clip-level Beauty V2 is a Vulkan-only production route
// with no GLES fallback. When Vulkan cannot be selected for such a scope,
// [select] resolves to [ExportRenderBackend.UNAVAILABLE] with a
// `beauty_v2_requires_vulkan:<underlying reason>` reason (the
// `transitions_require_vulkan` prefix takes priority when the scope ALSO
// carries a non-hard-cut transition, since that failure mode is
// pre-existing/tested and independently sufficient to require Vulkan).
//
// P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A, narrowed by
// P5-GLES-EXPORT-OVERLAY-PRODUCTION-ROUTE-A and extended by
// P5-GLES-EXPORT-STILL-IMAGE-OVERLAYS: a scope carrying non-empty overlays
// requires Vulkan UNLESS it is [ExportRenderScope.glesOverlayEligible]
// (hard-cut-only transitions, no clip-level Beauty V2, no reversed clip,
// every clip either a video or still-image clip) -- AndroidTimelineVideoEncoder
// (GLES) composites overlays for that narrow eligible shape via
// AndroidTimelineGlesOverlayRenderSession, reusing its existing still-image
// GL_TEXTURE_2D base draw path for still-image clips. When Vulkan cannot be
// selected for a scope whose overlays fall outside that eligible shape,
// [select] resolves to [ExportRenderBackend.UNAVAILABLE] with an
// `overlays_require_vulkan:<underlying reason>` reason (the
// `transitions_require_vulkan` and `beauty_v2_requires_vulkan` prefixes take
// priority in that order when also present).
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
    /// Validated non-hard-cut transitions (AndroidTimelineTransitionDescriptor.parseList).
    /// Non-empty means the scope requires the Vulkan backend; see the class doc.
    val transitions: List<AndroidTimelineTransitionDescriptor> = emptyList(),
    /// Validated timeline overlays (AndroidTimelineOverlayDescriptor).
    /// Non-empty means the scope requires the Vulkan backend; see the class doc.
    val overlays: List<AndroidTimelineOverlayDescriptor> = emptyList(),
) {
    val hasNonHardCutTransition: Boolean get() = transitions.any { !it.isHardCut }

    /// P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: true when any clip carries a
    /// non-null beautyIntensity. Clip-level Beauty V2 is Vulkan-only with no
    /// GLES fallback, so this alone also forces [requiresVulkan].
    val hasBeautyClip: Boolean get() = clips.any { it.beautyIntensity != null }

    /// P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A: true when the scope carries any
    /// overlays.
    val hasOverlays: Boolean get() = overlays.isNotEmpty()

    /// P5-GLES-EXPORT-OVERLAY-PRODUCTION-ROUTE-A, extended by
    /// P5-GLES-EXPORT-STILL-IMAGE-OVERLAYS: true when the scope's overlays
    /// can be composited by the GLES export route
    /// (AndroidTimelineVideoEncoder + AndroidTimelineGlesOverlayRenderSession)
    /// instead of requiring Vulkan -- hard-cut-only transitions, no
    /// clip-level Beauty V2, no reversed clip, and every clip is either a
    /// video or still-image clip (AndroidTimelineVideoEncoder reuses its
    /// existing still-image GL_TEXTURE_2D base draw path and composites
    /// overlays on top via the same AndroidTimelineGlesOverlayRenderSession
    /// route video clips use).
    val glesOverlayEligible: Boolean
        get() = hasOverlays && !hasNonHardCutTransition && !hasBeautyClip &&
            clips.none { it.isReversed } &&
            clips.all { it.mediaKind == "video" || it.mediaKind == "image" }

    /// Overlays only force Vulkan when they fall outside
    /// [glesOverlayEligible] -- a GLES-eligible overlay scope may still be
    /// routed to Vulkan (see [AndroidExportRenderBackendSelector.select]'s
    /// Vulkan-first preference) but is no longer required to be.
    val requiresVulkan: Boolean
        get() = hasNonHardCutTransition || hasBeautyClip || (hasOverlays && !glesOverlayEligible)
}

class AndroidExportRenderBackendSelector {

    /// Probes native backend capabilities and resolves this export run's
    /// backend decision. Never throws -- a probe exception is captured into
    /// the decision's [ExportRenderBackendDecision.reason] and still resolves
    /// to GLES. When the native capability probe itself resolves to Vulkan,
    /// [ExportRenderBackendDecision.actualBackend] only becomes Vulkan if
    /// [scope] is non-null and [vulkanScopeFailureReason] returns null;
    /// otherwise this resolves to GLES with that failure reason (e.g.
    /// "vulkan_scope_not_supported"), even though the device itself is
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

            val requiresVulkan = scope?.requiresVulkan == true
            val requiresVulkanReasonPrefix = requiresVulkanReasonPrefix(scope)
            val actualBackend: ExportRenderBackend
            val reason: String
            when (capabilityBackend) {
                ExportRenderBackend.VULKAN -> {
                    val scopeFailureReason = vulkanScopeFailureReason(scope)
                    if (scopeFailureReason == null) {
                        actualBackend = ExportRenderBackend.VULKAN
                        reason = "vulkan_export_scope_supported"
                    } else if (requiresVulkan) {
                        actualBackend = ExportRenderBackend.UNAVAILABLE
                        reason = "$requiresVulkanReasonPrefix:$scopeFailureReason"
                    } else {
                        actualBackend = ExportRenderBackend.GLES
                        reason = scopeFailureReason
                    }
                }
                ExportRenderBackend.GLES, ExportRenderBackend.UNAVAILABLE -> {
                    if (requiresVulkan) {
                        actualBackend = ExportRenderBackend.UNAVAILABLE
                        reason = "$requiresVulkanReasonPrefix:${report.fallbackReason}"
                    } else {
                        actualBackend = ExportRenderBackend.GLES
                        reason = report.fallbackReason
                    }
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
            val requiresVulkan = scope?.requiresVulkan == true
            ExportRenderBackendDecision(
                preferredBackend = ExportRenderBackend.UNAVAILABLE,
                actualBackend = if (requiresVulkan) ExportRenderBackend.UNAVAILABLE else ExportRenderBackend.GLES,
                reason = if (requiresVulkan) {
                    "${requiresVulkanReasonPrefix(scope)}:capability_probe_failed:${t.javaClass.simpleName}"
                } else {
                    "capability_probe_failed:${t.javaClass.simpleName}"
                },
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
    /// output dimensions, positive decoded clip dimensions, and cardinal
    /// 0/90/180/270 rotation. Phase 10: a clip carrying a colorMatrix is
    /// within this safe scope -- AndroidTimelineVulkanVideoEncoder /
    /// android_vulkan_export_jni.cpp apply it natively via the Vulkan
    /// fragment-shader color-matrix push constants, matching the GLES
    /// backend's pixel semantics -- so it is no longer excluded here.
    /// AndroidTimelineVulkanVideoEncoder itself computes an
    /// aspect-preserving-fit destination rect per clip (see its own geometry
    /// computation) rather than requiring decoded dimensions to exactly match
    /// the (possibly rotation-swapped) output geometry, so this predicate no
    /// longer checks for that exact/swapped equality.
    ///
    /// Returns null when [scope] is safe for Vulkan, or a machine-readable
    /// failure reason otherwise. Any unsafe shape (still images,
    /// unsupported/non-cardinal rotation, non-positive output or decoded
    /// dimensions, empty clip list, API < 29, or no scope at all) resolves to
    /// "vulkan_scope_not_supported".
    private fun vulkanScopeFailureReason(scope: ExportRenderScope?): String? {
        if (scope == null) return "vulkan_scope_not_supported"
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return "vulkan_scope_not_supported"
        if (scope.clips.isEmpty()) return "vulkan_scope_not_supported"
        if (scope.requestedWidth <= 0 || scope.requestedHeight <= 0) return "vulkan_scope_not_supported"
        // P5-REVERSE-EXPORT-EXACT-GLES-ROUTE: reversed clips have no native
        // Vulkan render route in this slice -- a reversed clip always
        // resolves this specific reason rather than the generic
        // "vulkan_scope_not_supported", so both AndroidTimelineExportSession's
        // GLES-fallback decision and any UNAVAILABLE reason string (when the
        // scope also independently requires Vulkan for a transition/overlay/
        // beauty reason) report the precise cause.
        if (scope.clips.any { it.isReversed }) return "reverse_unsupported_by_vulkan"
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

    /// Picks the `requires_vulkan` reason prefix for a scope that could not be
    /// routed to Vulkan. Transition prefix priority is preserved: a scope
    /// carrying a non-hard-cut transition always reports
    /// [TRANSITIONS_REQUIRE_VULKAN_REASON], even when it also carries a
    /// beauty clip or overlays -- that failure mode is pre-existing/tested and
    /// independently sufficient to require Vulkan (see class doc). A
    /// scope with a beauty clip and no non-hard-cut transition reports
    /// [BEAUTY_REQUIRE_VULKAN_REASON]. If only overlays require Vulkan, returns
    /// [OVERLAYS_REQUIRE_VULKAN_REASON].
    private fun requiresVulkanReasonPrefix(scope: ExportRenderScope?): String =
        when {
            scope?.hasNonHardCutTransition == true -> TRANSITIONS_REQUIRE_VULKAN_REASON
            scope?.hasBeautyClip == true -> BEAUTY_REQUIRE_VULKAN_REASON
            scope?.hasOverlays == true -> OVERLAYS_REQUIRE_VULKAN_REASON
            else -> OVERLAYS_REQUIRE_VULKAN_REASON
        }

    companion object {
        private const val TAG = "VGExportBackendSelector"

        /// Reason prefix when a transition timeline cannot be routed to Vulkan
        /// (the underlying capability/scope reason follows after ':').
        const val TRANSITIONS_REQUIRE_VULKAN_REASON = "transitions_require_vulkan"

        /// Reason prefix when a scope carrying a clip-level Beauty V2 request
        /// (and no non-hard-cut transition) cannot be routed to Vulkan (the
        /// underlying capability/scope reason follows after ':').
        const val BEAUTY_REQUIRE_VULKAN_REASON = "beauty_v2_requires_vulkan"

        /// Reason prefix when a scope carrying overlays (and no non-hard-cut
        /// transition or beauty clip) cannot be routed to Vulkan (the
        /// underlying capability/scope reason follows after ':').
        const val OVERLAYS_REQUIRE_VULKAN_REASON = "overlays_require_vulkan"
    }
}
