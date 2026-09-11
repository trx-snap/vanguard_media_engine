package com.connects.vanguard_media_engine.duet

import android.view.Surface

/**
 * Backend interface for Duet preview compositing and presentation.
 *
 * Defines the contract consumed by [AndroidDuetPreviewRenderLoop], abstracting
 * over rendering backends (e.g. OpenGL ES via [AndroidDuetPreviewCompositor] and
 * future backends such as Vulkan).
 *
 * Threading model: all methods and property reads must be invoked exclusively
 * on the render thread owned by [AndroidDuetPreviewRenderLoop], except where
 * thread-safe delivery is explicitly supported (such as [updateGreenScreenMask]).
 */
interface AndroidDuetPreviewBackend {
    val cameraInputSurface: Surface?
    val decoderInputSurface: Surface?
    val hasPendingSourceFrame: Boolean
    val hasPendingCameraFrame: Boolean

    fun attachOutputSurface(surface: Surface, widthPx: Int, heightPx: Int): Boolean
    fun detachOutputSurface()
    fun setLayout(sourceRect: VGDuetPixelRect, cameraRect: VGDuetPixelRect)
    fun setSourceVideoSize(widthPx: Int, heightPx: Int)
    fun setGreenScreenEnabled(enabled: Boolean)
    fun updateGreenScreenMask(frame: AndroidDuetSegmentationFrame)
    fun drawFrame(): Boolean
    fun release()
}
