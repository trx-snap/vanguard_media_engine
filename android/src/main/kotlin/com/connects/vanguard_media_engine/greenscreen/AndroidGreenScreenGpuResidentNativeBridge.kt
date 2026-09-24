package com.connects.vanguard_media_engine.greenscreen

import android.view.Surface
import java.nio.ByteBuffer

/**
 * JNI surface for the GPU-resident GreenScreen preview renderer
 * (src/platform/android/src/android_greenscreen_gpu_resident_jni.cpp ->
 * GlesGreenScreenGpuResidentRenderer). Owned and driven exclusively by
 * [AndroidGreenScreenGpuResidentPreviewBackend] on its render thread.
 *
 * Every function takes the handle returned by [nativeCreate]; native fails
 * closed (0 / false / no-op) for unknown or destroyed handles. Buffers passed
 * to [nativeDownscaleCameraToModelInput], [nativeUploadCoarseMask] and
 * [nativeSetBackgroundImage] must be direct: native reads/writes them in place.
 *
 * Kept separate from VanguardNativeBridge so this slice adds no symbol to the
 * shared bridge class; the JNI export names are derived from this object's
 * fully qualified class name.
 */
object AndroidGreenScreenGpuResidentNativeBridge {

    init {
        System.loadLibrary("vanguard_media_engine")
    }

    /** Creates the EGL display / ES 3.1 context / pbuffer + GL objects. Leaves the context current. 0 on failure. */
    external fun nativeCreate(): Long

    /** Terminal teardown (idempotent). Must run on the thread the context is current on. */
    external fun nativeDestroy(handle: Long)

    /** Makes the native context current on the calling thread (window surface if attached, else pbuffer). */
    external fun nativeMakeCurrent(handle: Long): Boolean

    /** GL_TEXTURE_EXTERNAL_OES texture name to construct the camera SurfaceTexture with. */
    external fun nativeGetCameraTextureId(handle: Long): Int

    /** Allocates the model-input texture/FBO for the interpreter's NHWC input size. */
    external fun nativeConfigureModelInput(handle: Long, width: Int, height: Int): Boolean

    /** Wraps the borrowed output [surface] in an EGL window surface (never releases the Surface). */
    external fun nativeAttachOutputSurface(handle: Long, surface: Surface, widthPx: Int, heightPx: Int): Boolean

    /** Destroys only the EGL window surface; camera texture and context survive. */
    external fun nativeDetachOutputSurface(handle: Long)

    // VG-LIVE-GREENSCREEN-RECORDING: secondary encoder window surface.

    /**
     * Wraps a live recording's encoder [surface] in a second EGL window surface
     * on the renderer's own display/config/context (never releases the
     * Surface). Requires an attached output of exactly [widthPx] x [heightPx]
     * and eglPresentationTimeANDROID; fails closed otherwise (see
     * [nativeLastError]). Re-attaching replaces the previous recorder surface.
     */
    external fun nativeAttachRecorderSurface(handle: Long, surface: Surface, widthPx: Int, heightPx: Int): Boolean

    /** Destroys only the recorder EGL window surface; the output, camera texture and context survive. */
    external fun nativeDetachRecorderSurface(handle: Long)

    /**
     * Re-draws the composite [nativeRenderFrame] just presented into the
     * recorder surface (composite pass only), stamps [presentationTimeNs] and
     * swaps. Returns 0 submitted, 1 skipped (no recorder / no fresh composite /
     * output lost or resized), 2 failed (EGL/GL error: the owner must detach
     * the recorder). Leaves the preview surface current again.
     */
    external fun nativeRenderRecorderFrame(handle: Long, presentationTimeNs: Long): Int

    /** Canvas-pixel rects (top-left origin) for the background (source) and the camera layer. */
    external fun nativeSetLayout(
        handle: Long,
        sourceLeft: Float, sourceTop: Float, sourceWidth: Float, sourceHeight: Float,
        cameraLeft: Float, cameraTop: Float, cameraWidth: Float, cameraHeight: Float,
    )

    /** Latches the SurfaceTexture transform matrix (column-major, 16 floats) and the upright camera aspect (w/h). */
    external fun nativeSetCameraTransform(handle: Long, stMatrix: FloatArray, cameraUprightAspect: Float)

    external fun nativeSetBackgroundBlack(handle: Long)
    external fun nativeSetBackgroundSolidColor(handle: Long, argb: Int)

    /** Uploads tightly packed RGBA8 pixels (row 0 = top) as the image background. */
    external fun nativeSetBackgroundImage(handle: Long, rgba: ByteBuffer, width: Int, height: Int, aspectFill: Boolean): Boolean
    external fun nativeSetBackgroundImageScaleMode(handle: Long, aspectFill: Boolean)
    external fun nativeClearBackgroundImage(handle: Long)

    /** Allocates (if needed) the GL_TEXTURE_EXTERNAL_OES texture for a Kotlin-owned background-video SurfaceTexture. 0 on failure. */
    external fun nativeGetBackgroundVideoTextureId(handle: Long): Int

    /** Latches the background video's SurfaceTexture transform matrix (16 floats), decoded size, source rotation and scale mode; switches the background to video. */
    external fun nativeSetBackgroundVideoFrame(
        handle: Long,
        stMatrix: FloatArray,
        videoWidth: Int,
        videoHeight: Int,
        rotationDegrees: Int,
        aspectFill: Boolean,
    )

    /** Releases the background-video OES texture (if any) and reverts the background to black if it was showing video. */
    external fun nativeClearBackgroundVideo(handle: Long)

    external fun nativeSetFilterToggles(handle: Long, guidedFilter: Boolean, temporalStabilizer: Boolean, despill: Boolean)

    /** GPU-downscales the latched camera frame and packs normalized float RGB (NHWC) into [modelInput]. */
    external fun nativeDownscaleCameraToModelInput(handle: Long, modelInput: ByteBuffer): Boolean

    /** Uploads a float32 single-channel mask (row 0 = top) as the coarse alpha texture. */
    external fun nativeUploadCoarseMask(handle: Long, mask: ByteBuffer, width: Int, height: Int): Boolean

    /**
     * Guided filter (+ optional temporal) when [refineMask] or no refined alpha
     * exists, composite, swap. [cameraMode]: 0 none, 1 placeholder,
     * 2 passthrough, 3 masked. Returns the swap result.
     */
    external fun nativeRenderFrame(handle: Long, cameraMode: Int, refineMask: Boolean): Boolean

    external fun nativeStatsSummary(handle: Long): String
    external fun nativeLastError(handle: Long): String

    // -------------------------------------------------------------------------
    // Embeddable segmenter (GlesGreenScreenGpuSegmenter): the same downscale ->
    // [Interpreter.run] -> coarse mask upload -> guided/temporal refinement
    // core, but with NO EGL/window/swap/background ownership, for a host
    // compositor that runs it inside its OWN current ES 3.1 context on its own
    // render thread and then samples the refined alpha texture from its own
    // draw (AndroidDuetPreviewCompositor greenScreen mode). Every call must be
    // made on that thread with that context current; the camera OES texture is
    // passed per call and stays owned by the host. Native fails closed
    // (0 / false / no-op) for unknown or destroyed handles.
    // -------------------------------------------------------------------------

    /** Verifies the CURRENT context is ES 3.1 + external_essl3 and compiles the compute programs. 0 on failure. */
    external fun nativeSegmenterCreate(): Long

    /** Deletes every GL object the segmenter owns; the host's context must still be current. Idempotent. */
    external fun nativeSegmenterDestroy(handle: Long)

    /** Allocates the model-input texture/FBO for the interpreter's NHWC input size. */
    external fun nativeSegmenterConfigureModelInput(handle: Long, width: Int, height: Int): Boolean

    /** Latches the camera SurfaceTexture transform (column-major, 16 floats) and upright aspect (w/h). */
    external fun nativeSegmenterSetCameraTransform(handle: Long, stMatrix: FloatArray, cameraUprightAspect: Float)

    /** Host output size the refined alpha resolution is derived from (long side clamped to [64,1280]). */
    external fun nativeSegmenterSetAlphaTargetSize(handle: Long, outputWidthPx: Int, outputHeightPx: Int)

    external fun nativeSegmenterSetFilterToggles(handle: Long, guidedFilter: Boolean, temporalStabilizer: Boolean)

    /** GPU-downscales the latched frame of [cameraOesTexture] and packs normalized float RGB (NHWC) into [modelInput]. */
    external fun nativeSegmenterDownscaleCameraToModelInput(handle: Long, cameraOesTexture: Int, modelInput: ByteBuffer): Boolean

    /** Uploads a float32 single-channel mask (row 0 = top) as the coarse alpha texture. */
    external fun nativeSegmenterUploadCoarseMask(handle: Long, mask: ByteBuffer, width: Int, height: Int): Boolean

    /** Guided filter (+ optional temporal) of the coarse mask against [cameraOesTexture] luminance. */
    external fun nativeSegmenterRefineAlpha(handle: Long, cameraOesTexture: Int): Boolean

    /** R32F GL_NEAREST texture (quad space) holding the latest refined alpha; 0 until the first refine. */
    external fun nativeSegmenterRefinedAlphaTextureId(handle: Long): Int
    external fun nativeSegmenterAlphaWidth(handle: Long): Int
    external fun nativeSegmenterAlphaHeight(handle: Long): Int

    /** Forgets the current coarse mask / refined alpha / temporal history (textures are kept). */
    external fun nativeSegmenterResetMaskState(handle: Long)

    external fun nativeSegmenterStatsSummary(handle: Long): String
    external fun nativeSegmenterLastError(handle: Long): String
}
