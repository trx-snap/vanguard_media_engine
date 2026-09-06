package com.connects.vanguard_media_engine.export

// ── AndroidTimelineVideoPassEncoder ───────────────────────────────────────────
//
// Backend-selection seam for AndroidTimelineExportSession's pass-1 video
// encode step. AndroidTimelineVideoEncoder (GLES, frozen export path) and
// AndroidTimelineVulkanVideoEncoder (Vulkan, preferred) implement it so the
// session's call site does not change per backend.
//
// P5-COMPOSITOR-TRANS: the transition-aware [encode] overload is the
// session's single call site. Its default body fails closed for any
// non-hard-cut transition -- a backend that has not implemented compositor-
// owned overlap rendering (the frozen hard-cut GLES encoder,
// AndroidTimelineVideoEncoder) must never re-encode a transition timeline as
// hard cuts. AndroidTimelineVulkanVideoEncoder overrides it with the
// Vulkan-first positive route; P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A
// adds a second, narrower override -- AndroidTimelineGlesTransitionVideoEncoder
// -- used only for the video-only, non-reversed, non-beauty transition shape
// AndroidExportRenderBackendSelector.
// ExportRenderScope.glesTransitionEligible admits. P5-GLES-EXPORT-TRANSITION-
// OVERLAYS: that shape is no longer overlay-free -- AndroidTimelineGlesTransitionVideoEncoder
// overrides the overlay-aware [encode] overload below itself (rather than
// inheriting this interface's fail-closed default) to composite timeline
// overlays on that same eligible shape.
//
// P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A: the overlay-aware [encode] overload
// extends the backend-pass seam for timeline overlays. Its default body fails
// closed for any non-empty overlay list -- backends that do not implement
// native overlay compositing (e.g. GLES) fail closed with
// [OVERLAYS_UNSUPPORTED_BY_BACKEND_REASON].
interface AndroidTimelineVideoPassEncoder {
    /** Signals the encode loop to stop feeding new frames. Thread-safe. */
    fun cancel()

    fun encode(
        clips: List<AndroidTimelineVideoEncoder.ClipInput>,
        onProgress: ((Double) -> Unit)? = null,
    ): AndroidTimelineVideoEncoder.EncodeResult

    /**
     * Encodes [clips] with the validated, index-bound [transitions]
     * (non-hard-cut only; see AndroidTimelineTransitionDescriptor.parseList).
     * Backends without a transition route inherit this fail-closed default:
     * non-empty transitions return [TRANSITIONS_UNSUPPORTED_BY_BACKEND_REASON]
     * without producing output, and an empty list delegates to the plain
     * hard-cut [encode].
     */
    fun encode(
        clips: List<AndroidTimelineVideoEncoder.ClipInput>,
        transitions: List<AndroidTimelineTransitionDescriptor>,
        onProgress: ((Double) -> Unit)? = null,
    ): AndroidTimelineVideoEncoder.EncodeResult {
        if (transitions.any { !it.isHardCut }) {
            return AndroidTimelineVideoEncoder.EncodeResult(
                false,
                TRANSITIONS_UNSUPPORTED_BY_BACKEND_REASON,
                0,
                0L,
            )
        }
        return encode(clips, onProgress)
    }

    /**
     * Encodes [clips] with validated [transitions] and [overlays]
     * (see AndroidTimelineOverlayDescriptor.parseList).
     * Backends without an overlay route inherit this fail-closed default:
     * non-empty overlays return [OVERLAYS_UNSUPPORTED_BY_BACKEND_REASON]
     * without producing output, and an empty list delegates to the
     * transition-aware [encode].
     */
    fun encode(
        clips: List<AndroidTimelineVideoEncoder.ClipInput>,
        transitions: List<AndroidTimelineTransitionDescriptor>,
        overlays: List<AndroidTimelineOverlayDescriptor>,
        onProgress: ((Double) -> Unit)? = null,
    ): AndroidTimelineVideoEncoder.EncodeResult {
        if (overlays.isNotEmpty()) {
            return AndroidTimelineVideoEncoder.EncodeResult(
                false,
                OVERLAYS_UNSUPPORTED_BY_BACKEND_REASON,
                0,
                0L,
            )
        }
        return encode(clips, transitions, onProgress)
    }

    companion object {
        /** Machine-readable reason for a backend that cannot render overlap transitions. */
        const val TRANSITIONS_UNSUPPORTED_BY_BACKEND_REASON = "transitions_unsupported_by_backend"

        /** Machine-readable reason for a backend that cannot render timeline overlays. */
        const val OVERLAYS_UNSUPPORTED_BY_BACKEND_REASON = "overlays_unsupported_by_backend"
    }
}
