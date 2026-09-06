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
//
// P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A: a scope carrying a
// non-hard-cut transition no longer unconditionally requires Vulkan -- when
// [ExportRenderScope.glesTransitionEligible] holds (video-only clips, no
// reversed clip, no clip-level Beauty V2, no overlays, positive decoded/
// requested dimensions, zero rotation metadata on every clip), the narrow
// production GLES transition route (AndroidTimelineGlesTransitionVideoEncoder)
// is an acceptable alternative to Vulkan. Vulkan remains the default/
// preferred backend regardless (see [select]'s Vulkan-first branch below,
// unchanged) -- this only widens what happens when Vulkan is NOT selectable
// for such a scope: instead of always failing closed with
// `transitions_require_vulkan:<reason>`, an eligible scope now resolves to
// [ExportRenderBackend.GLES]. [select]'s optional `debugForceGlesTransitionExport`
// parameter additionally allows a caller to force GLES for an eligible scope
// even when Vulkan would otherwise be selected first, purely to physically
// exercise this route on a Vulkan-capable device -- see [select]'s doc.
// A non-hard-cut transition whose scope is NOT [glesTransitionEligible]
// still fails closed exactly as before with `transitions_require_vulkan:...`
// when Vulkan cannot be selected either -- this slice does not implement a
// GLES route for reversed/beauty/overlay/still-image/rotated/colorMatrix
// transition scopes. P5-GLES-EXPORT-TRANSITION-SLIDE-WIPE widened the
// eligible transition family from crossfade-only to every closed-set
// AndroidTimelineTransitionDescriptor.Type member (crossfade, the four
// wipes, and the four slides) -- native transition math
// (vanguard::compositors::ComputeTransitionGeometry) and the GLES
// compositor already implement all nine, so there is no remaining
// per-family "unsupported_transition_type" gate on this route. The
// colorMatrix restriction is still gated by
// [glesTransitionIneligibleReason]/[glesTransitionEligible] themselves, so
// the selector never routes a colorMatrix-bearing scope into GLES pass-1 in
// the first place; AndroidTimelineGlesTransitionVideoEncoder's own
// defensive re-validation of the same restriction is a second defense
// layer, not the primary gate.
//
// P5-GLES-EXPORT-BEAUTY-PRODUCTION-ROUTE-A: a scope carrying clip-level
// Beauty V2 no longer unconditionally requires Vulkan -- when
// [ExportRenderScope.glesBeautyEligible] holds (hard-cut-only transitions,
// no overlays, video-only clips, no reversed clip, no colorMatrix, positive
// decoded/requested dimensions, zero rotation metadata on every clip), the
// narrow production GLES Beauty route (AndroidTimelineVideoEncoder +
// AndroidTimelineGlesBeautyRenderSession) is an acceptable alternative to
// Vulkan. Vulkan remains the default/preferred backend regardless (see
// [select]'s Vulkan-first branch below, unchanged) -- this only widens what
// happens when Vulkan is NOT selectable for such a scope: instead of always
// failing closed with `beauty_v2_requires_vulkan:<reason>`, an eligible
// scope now resolves to [ExportRenderBackend.GLES]. [select]'s optional
// `debugForceGlesBeautyExport` parameter additionally allows a caller to
// force GLES for an eligible hard-cut scope even when Vulkan would
// otherwise be selected first, purely to physically exercise this route on
// a Vulkan-capable device -- see [select]'s doc. A scope carrying Beauty V2
// that is NOT [glesBeautyEligible] still fails closed exactly as before
// with `beauty_v2_requires_vulkan:...` when Vulkan cannot be selected
// either -- this slice does not implement a GLES Beauty route for
// transition/overlay/still-image/reversed/rotated/colorMatrix scopes.
// [debugForceGlesTransitionExport] takes priority over
// [debugForceGlesBeautyExport] whenever both could apply to the same
// non-hard-cut-transition scope (see [select]'s doc); a hard-cut Beauty
// scope only ever sets the beauty force parameter (see
// AndroidTimelineExportSession's single top-level debug-force routing).
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

    /// P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A, widened by
    /// P5-GLES-EXPORT-TRANSITION-SLIDE-WIPE: null when this scope's
    /// non-hard-cut transition(s) are eligible for the narrow production GLES
    /// transition route (AndroidTimelineGlesTransitionVideoEncoder), or a
    /// precise machine-readable reason otherwise. Also gates the same limits
    /// the GLES transition encoder itself enforces -- a clip carrying a
    /// non-null colorMatrix (the encoder has no colorMatrix uniform path on
    /// this route) returns "color_matrix_present". Every
    /// AndroidTimelineTransitionDescriptor.Type member other than NONE
    /// (crossfade, the four wipes, the four slides) is admitted here --
    /// native transition math (vanguard::compositors::ComputeTransitionGeometry)
    /// and the GLES compositor already implement all nine, so there is no
    /// per-family rejection left on this route. Rotation is restricted
    /// to exactly zero (not the wider 0/90/180/270 Vulkan accepts) -- this
    /// route's OES-to-canvas pre-resolve step does not implement a rotated
    /// fit quad, so a non-zero rotation fails closed here rather than risk
    /// wrong output. See [glesTransitionEligible].
    val glesTransitionIneligibleReason: String?
        get() {
            if (!hasNonHardCutTransition) return "no_non_hard_cut_transition"
            if (hasBeautyClip) return "beauty_clip_present"
            if (hasOverlays) return "overlays_present"
            if (clips.any { it.isReversed }) return "reversed_clip_present"
            if (clips.any { it.mediaKind != "video" }) return "non_video_clip_present"
            if (clips.any { it.colorMatrix != null }) return "color_matrix_present"
            if (clips.any { it.decodedWidth <= 0 || it.decodedHeight <= 0 }) return "invalid_decoded_dimensions"
            if (clips.any { it.rotationDegrees != 0 }) return "non_zero_rotation"
            if (requestedWidth <= 0 || requestedHeight <= 0) return "invalid_output_dimensions"
            return null
        }

    /// True when [glesTransitionIneligibleReason] is null -- see its doc.
    val glesTransitionEligible: Boolean get() = glesTransitionIneligibleReason == null

    /// P5-GLES-EXPORT-BEAUTY-PRODUCTION-ROUTE-A: null when this scope's
    /// clip-level Beauty V2 request(s) are eligible for the narrow
    /// production GLES Beauty route (AndroidTimelineVideoEncoder +
    /// AndroidTimelineGlesBeautyRenderSession), or a precise
    /// machine-readable reason otherwise. Route A only claims hard-cut,
    /// video-only, non-reversed, colorMatrix-free, zero-rotation timelines
    /// with positive decoded/requested dimensions -- any non-hard-cut
    /// transition, overlay, still-image clip, reversed clip, colorMatrix,
    /// non-zero rotation, or invalid dimension anywhere in the scope fails
    /// this predicate, even when only one clip in an otherwise-eligible
    /// mixed hard-cut timeline carries the offending shape. Does not check
    /// native-bridge availability -- that is a runtime concern the encoder
    /// itself checks immediately before it would draw a Beauty frame (see
    /// AndroidTimelineVideoEncoder), not a request-shape property. See
    /// [glesBeautyEligible].
    val glesBeautyIneligibleReason: String?
        get() {
            if (!hasBeautyClip) return "no_beauty_clip"
            if (hasNonHardCutTransition) return "non_hard_cut_transition"
            if (hasOverlays) return "overlays_present"
            if (clips.any { it.isReversed }) return "reversed_clip_present"
            if (clips.any { it.mediaKind != "video" }) return "non_video_clip_present"
            if (clips.any { it.colorMatrix != null }) return "color_matrix_present"
            if (clips.any { it.decodedWidth <= 0 || it.decodedHeight <= 0 }) return "invalid_decoded_dimensions"
            if (clips.any { it.rotationDegrees != 0 }) return "non_zero_rotation"
            if (requestedWidth <= 0 || requestedHeight <= 0) return "invalid_output_dimensions"
            return null
        }

    /// True when [glesBeautyIneligibleReason] is null -- see its doc.
    val glesBeautyEligible: Boolean get() = glesBeautyIneligibleReason == null

    /// Overlays only force Vulkan when they fall outside
    /// [glesOverlayEligible] -- a GLES-eligible overlay scope may still be
    /// routed to Vulkan (see [AndroidExportRenderBackendSelector.select]'s
    /// Vulkan-first preference) but is no longer required to be. Likewise, a
    /// non-hard-cut transition only forces Vulkan when the scope falls
    /// outside [glesTransitionEligible], and clip-level Beauty V2 only
    /// forces Vulkan when the scope falls outside [glesBeautyEligible].
    val requiresVulkan: Boolean
        get() = (hasNonHardCutTransition && !glesTransitionEligible) ||
            (hasBeautyClip && !glesBeautyEligible) ||
            (hasOverlays && !glesOverlayEligible)
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
    ///
    /// [debugForceGlesTransitionExport] (P5-GLES-EXPORT-TRANSITION-PRODUCTION-
    /// ROUTE-A): a scoped, test-only force seam that lets a caller (wired
    /// from the `exportTimeline` request's top-level
    /// `debugForceRenderBackend == "gles"` argument) physically exercise the
    /// narrow production GLES transition route on a device that would
    /// otherwise select Vulkan first. When true, this bypasses the normal
    /// Vulkan-first branch entirely and resolves to
    /// [ExportRenderBackend.GLES] with reason [DEBUG_FORCE_GLES_TRANSITION_REASON]
    /// ONLY when [scope] is [ExportRenderScope.glesTransitionEligible] AND the
    /// capability probe reports GLES support; otherwise it resolves to
    /// [ExportRenderBackend.UNAVAILABLE] with a
    /// `$GLES_TRANSITION_NOT_ELIGIBLE_REASON:<reason>` reason -- it never
    /// silently falls through to the normal (non-forced) selection logic.
    /// Ignored (has no effect) when false, which remains the default for
    /// every production caller. Takes priority over
    /// [debugForceGlesBeautyExport] whenever both are true.
    ///
    /// [debugForceGlesBeautyExport] (P5-GLES-EXPORT-BEAUTY-PRODUCTION-
    /// ROUTE-A): the same test-only force-seam pattern as
    /// [debugForceGlesTransitionExport], for the narrow production GLES
    /// Beauty route instead. When true (and [debugForceGlesTransitionExport]
    /// is false), this bypasses the normal Vulkan-first branch entirely and
    /// resolves to [ExportRenderBackend.GLES] with reason
    /// [DEBUG_FORCE_GLES_BEAUTY_REASON] ONLY when [scope] is
    /// [ExportRenderScope.glesBeautyEligible] AND the capability probe
    /// reports GLES support; otherwise it resolves to
    /// [ExportRenderBackend.UNAVAILABLE] with a
    /// `$GLES_BEAUTY_NOT_ELIGIBLE_REASON:<reason>` reason -- it never
    /// silently falls through to the normal (non-forced) selection logic.
    /// Ignored (has no effect) when false or when
    /// [debugForceGlesTransitionExport] is true, which remains the default
    /// for every production caller.
    fun select(
        scope: ExportRenderScope? = null,
        nativeBridge: VanguardNativeBridge? = null,
        debugForceGlesTransitionExport: Boolean = false,
        debugForceGlesBeautyExport: Boolean = false,
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
            if (debugForceGlesTransitionExport) {
                val ineligibleReason = scope?.glesTransitionIneligibleReason
                when {
                    ineligibleReason != null -> {
                        actualBackend = ExportRenderBackend.UNAVAILABLE
                        reason = "$GLES_TRANSITION_NOT_ELIGIBLE_REASON:$ineligibleReason"
                    }
                    !report.glesSupported -> {
                        actualBackend = ExportRenderBackend.UNAVAILABLE
                        reason = "$GLES_TRANSITION_NOT_ELIGIBLE_REASON:gles_not_supported:${report.fallbackReason}"
                    }
                    else -> {
                        actualBackend = ExportRenderBackend.GLES
                        reason = DEBUG_FORCE_GLES_TRANSITION_REASON
                    }
                }
            } else if (debugForceGlesBeautyExport) {
                val ineligibleReason = scope?.glesBeautyIneligibleReason
                when {
                    ineligibleReason != null -> {
                        actualBackend = ExportRenderBackend.UNAVAILABLE
                        reason = "$GLES_BEAUTY_NOT_ELIGIBLE_REASON:$ineligibleReason"
                    }
                    !report.glesSupported -> {
                        actualBackend = ExportRenderBackend.UNAVAILABLE
                        reason = "$GLES_BEAUTY_NOT_ELIGIBLE_REASON:gles_not_supported:${report.fallbackReason}"
                    }
                    else -> {
                        actualBackend = ExportRenderBackend.GLES
                        reason = DEBUG_FORCE_GLES_BEAUTY_REASON
                    }
                }
            } else when (capabilityBackend) {
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
                // A probe failure means capability (including GLES support)
                // could not even be confirmed -- the force seam never
                // resolves to GLES on this path, regardless of eligibility.
                actualBackend = if (debugForceGlesTransitionExport || debugForceGlesBeautyExport || requiresVulkan) {
                    ExportRenderBackend.UNAVAILABLE
                } else {
                    ExportRenderBackend.GLES
                },
                reason = if (debugForceGlesTransitionExport) {
                    "$GLES_TRANSITION_NOT_ELIGIBLE_REASON:capability_probe_failed:${t.javaClass.simpleName}"
                } else if (debugForceGlesBeautyExport) {
                    "$GLES_BEAUTY_NOT_ELIGIBLE_REASON:capability_probe_failed:${t.javaClass.simpleName}"
                } else if (requiresVulkan) {
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

        /// P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A: reason prefix used
        /// when [select]'s `debugForceGlesTransitionExport` seam is set but
        /// the scope is not [ExportRenderScope.glesTransitionEligible] (or
        /// GLES itself is not supported) -- the underlying
        /// [ExportRenderScope.glesTransitionIneligibleReason] (or
        /// "gles_not_supported:<fallbackReason>"/"capability_probe_failed:...")
        /// follows after ':'.
        const val GLES_TRANSITION_NOT_ELIGIBLE_REASON = "gles_transition_not_eligible"

        /// P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A: the exact reason
        /// [select] reports when `debugForceGlesTransitionExport` chooses
        /// GLES for an eligible, GLES-supported scope -- kept obvious in
        /// logs/reason strings so a forced selection is never mistaken for
        /// the normal capability-driven GLES fallback.
        const val DEBUG_FORCE_GLES_TRANSITION_REASON = "debug_force_gles_transition_export"

        /// P5-GLES-EXPORT-BEAUTY-PRODUCTION-ROUTE-A: reason prefix used when
        /// [select]'s `debugForceGlesBeautyExport` seam is set but the scope
        /// is not [ExportRenderScope.glesBeautyEligible] (or GLES itself is
        /// not supported) -- the underlying
        /// [ExportRenderScope.glesBeautyIneligibleReason] (or
        /// "gles_not_supported:<fallbackReason>"/"capability_probe_failed:...")
        /// follows after ':'.
        const val GLES_BEAUTY_NOT_ELIGIBLE_REASON = "gles_beauty_not_eligible"

        /// P5-GLES-EXPORT-BEAUTY-PRODUCTION-ROUTE-A: the exact reason
        /// [select] reports when `debugForceGlesBeautyExport` chooses GLES
        /// for an eligible, GLES-supported scope -- kept obvious in
        /// logs/reason strings so a forced selection is never mistaken for
        /// the normal capability-driven GLES fallback.
        const val DEBUG_FORCE_GLES_BEAUTY_REASON = "debug_force_gles_beauty_export"
    }
}
