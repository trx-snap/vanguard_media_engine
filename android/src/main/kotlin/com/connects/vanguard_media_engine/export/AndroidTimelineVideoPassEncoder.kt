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
// owned overlap rendering (the GLES encoder) must never re-encode a
// transition timeline as hard cuts. Only AndroidTimelineVulkanVideoEncoder
// overrides it with the positive route.
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

    companion object {
        /** Machine-readable reason for a backend that cannot render overlap transitions. */
        const val TRANSITIONS_UNSUPPORTED_BY_BACKEND_REASON = "transitions_unsupported_by_backend"
    }
}
