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
     * Informs the backend of the live camera feed's normalized (0/90/180/270)
     * display rotation and whether it is horizontally mirrored. The GLES
     * backend already presents a display-correct camera feed via the
     * SurfaceTexture transform matrix (matching production behavior on the
     * Duet render loop GreenScreen previously ran on, where this was also a
     * no-op), so the default here no-ops.
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
}
