package com.connects.vanguard_media_engine.greenscreen

import android.view.Surface

/**
 * Backend interface for the independent GreenScreen preview compositor.
 *
 * Defines the contract consumed by [AndroidGreenScreenPreviewRenderLoop]:
 * single-camera ingest, green-screen mask compositing, and a static
 * (solid-color / image) background — no source-video decoder ingest, no
 * Duet layout modes, no Duet session assumptions. This mirrors only the
 * subset of `AndroidDuetPreviewBackend` that GreenScreen ever exercises in
 * production (GreenScreen always uses `decoderProvider = { null }`, so the
 * decoder ingest / video-aspect-fill code paths on the Duet interface are
 * provably unreachable for this capability).
 *
 * Threading model: all methods and property reads must be invoked
 * exclusively on the render thread owned by [AndroidGreenScreenPreviewRenderLoop],
 * except where thread-safe delivery is explicitly supported (such as
 * [updateGreenScreenMask]).
 */
interface AndroidGreenScreenPreviewBackend {
    val cameraInputSurface: Surface?
    val hasPendingCameraFrame: Boolean

    fun attachOutputSurface(surface: Surface, widthPx: Int, heightPx: Int): Boolean
    fun detachOutputSurface()
    fun setLayout(sourceRect: AndroidGreenScreenPixelRect, cameraRect: AndroidGreenScreenPixelRect)

    /**
     * Optional seam for a backend to be informed of the live camera feed's
     * normalized (0/90/180/270) display rotation and whether it is
     * horizontally mirrored. No-op by default, matching
     * duet/AndroidDuetPreviewBackend.kt: the camera SurfaceTexture's own
     * transform matrix (latched via getTransformMatrix) already delivers a
     * display-correct camera feed, so [AndroidGreenScreenPreviewCompositor]
     * does not override this either — it stays the no-op default, exactly
     * like the proven Duet GLES compositor.
     */
    fun setCameraFrameTransform(rotationDegrees: Int, mirrorHorizontal: Boolean) {}

    fun setGreenScreenEnabled(enabled: Boolean)
    fun updateGreenScreenMask(frame: AndroidGreenScreenSegmentationFrame)

    /**
     * Sets the static background composited beneath the masked camera layer
     * (solid color or image). Only meaningful while green-screen compositing
     * is enabled; harmless to call otherwise.
     */
    fun setGreenScreenBackground(background: AndroidGreenScreenBackground)

    fun drawFrame(): Boolean
    fun release()

    /**
     * Read-only, render-thread-only diagnostics snapshot for regression
     * tooling. Default is empty; backends that carry meaningful telemetry
     * (such as [AndroidGreenScreenGpuResidentPreviewBackend]) override this.
     * Must never mutate state.
     */
    fun diagnosticsSnapshot(): Map<String, Any?> = emptyMap()
}
