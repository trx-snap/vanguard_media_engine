package com.connects.vanguard_media_engine.export

// ── AndroidTimelineVideoPassEncoder ───────────────────────────────────────────
//
// Backend-selection seam for AndroidTimelineExportSession's pass-1 video
// encode step. AndroidTimelineVideoEncoder (GLES, frozen export path) is the
// only implementation in this slice; a future Vulkan export encoder
// implements this same interface so the session's call site does not change
// when that backend lands.
interface AndroidTimelineVideoPassEncoder {
    /** Signals the encode loop to stop feeding new frames. Thread-safe. */
    fun cancel()

    fun encode(
        clips: List<AndroidTimelineVideoEncoder.ClipInput>,
        onProgress: ((Double) -> Unit)? = null,
    ): AndroidTimelineVideoEncoder.EncodeResult
}
