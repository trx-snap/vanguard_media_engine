package com.connects.vanguard_media_engine.duet

import android.hardware.HardwareBuffer
import android.os.ParcelFileDescriptor
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
 * thread-safe delivery is explicitly supported (such as [updateGreenScreenMask]
 * and [updateGreenScreenMaskHardwareBuffer]).
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

    /**
     * Backwards-safe superset of [setSourceVideoSize]: also carries the
     * source video's normalized (0/90/180/270) display rotation, so a
     * backend that aspect-fills by buffer dimensions (e.g. the Vulkan
     * compositor) can correct a portrait-recorded source that decoded into
     * a sideways buffer instead of rendering it rotated. Backends that only
     * need size (the default here) ignore the rotation and delegate to
     * [setSourceVideoSize].
     */
    fun setSourceVideoMetadata(widthPx: Int, heightPx: Int, rotationDegrees: Int) {
        setSourceVideoSize(widthPx, heightPx)
    }

    /**
     * Debug/opt-in seam (Camera2 GPU green-screen source): informs the
     * backend of the live camera feed's normalized (0/90/180/270) display
     * rotation and whether it is horizontally mirrored (true for a
     * front-facing camera). Backends that already present a display-correct
     * camera feed (the default here) no-op.
     */
    fun setCameraFrameTransform(rotationDegrees: Int, mirrorHorizontal: Boolean) {}

    fun setGreenScreenEnabled(enabled: Boolean)
    fun updateGreenScreenMask(frame: AndroidDuetSegmentationFrame)

    /**
     * Duet-only preview seam: sets the green-screen foreground/camera layer's
     * free-rotation metadata — [rotationDegrees] (visual clockwise, Dart/top-left
     * space, arbitrary finite value) and the normalized pivot [anchorX]/[anchorY]
     * within the camera rect the rotation is applied around. Identity is
     * `(0.0, 0.5, 0.5)`. Only meaningful while green-screen compositing is
     * enabled; harmless to call otherwise. Backends that do not support
     * foreground rotation (the default here) no-op, so production behavior for
     * callers that never invoke this is unaffected.
     */
    fun setForegroundRotation(rotationDegrees: Double, anchorX: Double, anchorY: Double) {}

    /**
     * Debug-only (RND diagnostic): selects a raw segmentation mask
     * visualization mode so a physical smoke can capture what the mask
     * texture actually contains, independent of the production alpha-blend
     * shaping. Only "mask_direct", "mask_mapped", "mask_direct_mirror_x",
     * "mask_direct_flip_y" and "camera_passthrough" are recognized; any other
     * value (including null) disables the visualization and restores normal
     * compositing. "mask_direct_mirror_x" and "mask_direct_flip_y"
     * additionally invert the raw mask's X or Y coordinate respectively, so
     * physical RND can identify a front-camera mirror/flip mismatch.
     * "camera_passthrough" is not a mask visualization at all — it shows the
     * raw live camera feed (no mask, no alpha shaping) inside the
     * green-screen camera rect, so physical RND can confirm the OES camera
     * path itself independent of segmentation. Backends that do not support
     * this diagnostic (the default here) no-op, so production behavior is
     * unaffected.
     */
    fun setGreenScreenDebugView(view: String?) {}

    /**
     * Debug-only (RND diagnostic): selects a static solid-color background
     * mode for green-screen compositing (e.g. "solid_teal") so a physical
     * smoke can isolate the mask/composite path from the live camera feed.
     * Any other value (including null) restores normal compositing.
     * Backends that do not support this diagnostic (the default here) no-op.
     */
    fun setGreenScreenBackgroundMode(mode: String?) {}

    /**
     * Sets the static background composited beneath the masked camera layer
     * in green-screen mode (video / solid color / image). Only meaningful
     * while green-screen compositing is enabled; harmless to call otherwise.
     * Backends that do not support this (the default here) no-op, so the
     * source video remains the only background.
     */
    fun setGreenScreenBackground(background: AndroidDuetGreenScreenBackground) {}

    /**
     * GPU-resident green-screen mask update: [hardwareBuffer] already
     * contains an R8/RGBA mask produced on GPU (e.g. by a future MediaPipe
     * GPU graph), so a backend that supports it can composite directly from
     * it without a CPU mask upload. [widthPx]/[heightPx] describe the mask
     * content size; [timestampUs] is caller metadata (logging/future use
     * only). [acquireFenceFd], when >= 0, is a sync-fd that the backend/native
     * import path must either consume or close before returning.
     *
     * Ownership of [hardwareBuffer] transfers to the callee on this call
     * REGARDLESS of outcome — unless [onReleased] is supplied, the caller
     * must not read, write, or close it again afterward. When [onReleased]
     * is supplied, the callee must invoke it exactly once when the buffer is
     * no longer retained by backend/native state; this lets a producer reuse
     * a small GPU mask buffer pool without racing Vulkan's current import. A
     * backend that does not support this seam (the default here) releases it
     * immediately and no-ops, so [updateGreenScreenMask] remains the only
     * mask path for that backend.
     */
    fun updateGreenScreenMaskHardwareBuffer(
        hardwareBuffer: HardwareBuffer,
        widthPx: Int,
        heightPx: Int,
        timestampUs: Long,
        onReleased: ((HardwareBuffer) -> Unit)? = null,
        acquireFenceFd: Int = -1,
    ) {
        closeFenceFdQuietly(acquireFenceFd)
        if (onReleased != null) {
            onReleased(hardwareBuffer)
        } else {
            try {
                hardwareBuffer.close()
            } catch (_: Throwable) {}
        }
    }

    private fun closeFenceFdQuietly(fd: Int) {
        if (fd < 0) return
        try {
            ParcelFileDescriptor.adoptFd(fd).close()
        } catch (_: Throwable) {}
    }

    fun drawFrame(): Boolean
    fun release()
}
