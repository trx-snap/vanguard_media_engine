package com.connects.vanguard_media_engine.greenscreen

import android.view.Surface
import java.nio.ByteBuffer

/**
 * One-shot CPU read-back of the composited preview frame for a still photo
 * (VG-LIVE-GREENSCREEN-PHOTO), armed on a backend through
 * [AndroidGreenScreenPreviewBackend.setCompositeCaptureRequest]. The backend
 * reads back EXACTLY the composite it presents (background + keyed camera in
 * the current layout, the same pass the preview swap and the recorder see),
 * after its composite pass and before the preview swap, and resolves the
 * request exactly once on its render thread: [onCaptured] with the raw
 * pixels, or [onFailed] with a diagnostic token. Only the pixel read happens
 * on the render thread; the receiver must move row-flipping and JPEG encoding
 * off it (see [AndroidGreenScreenPreviewRenderLoop.captureCompositePhoto]).
 */
interface AndroidGreenScreenCompositeCaptureRequest {
    /**
     * [widthPx] x [heightPx] tightly packed RGBA8 pixels of the composite in
     * GL read-back order (row 0 = BOTTOM of the image); a direct buffer with
     * position 0 that the receiver now owns. Alpha is not meaningful (the
     * composite is opaque over its background). Render thread, at most once.
     */
    fun onCaptured(rgbaBottomUp: ByteBuffer, widthPx: Int, heightPx: Int)

    /** No pixels were read ([reason] is a diagnostic token). Render thread, at most once. */
    fun onFailed(reason: String)
}

/**
 * Encoder-surface target a live green-screen recording hands to the preview
 * backend (see [AndroidGreenScreenPreviewBackend.setSegmentRecorderTarget]).
 * Implemented by [AndroidGreenScreenSegmentRecorder]: the backend draws the
 * SAME full green-screen composite it presents on the preview (background +
 * keyed camera, current layout) into [inputSurface], stamped with
 * [nextFramePresentationTimeNs], once per newly latched camera frame. The
 * target never touches GL and the backend never touches the encoder.
 *
 * Threading: [nextFramePresentationTimeNs], [onFrameSubmitted] and
 * [onSurfaceFailed] are called on the backend's render thread only; the
 * properties may be read there too.
 */
interface AndroidGreenScreenSegmentRecorderSurfaceTarget {
    /** Encoder input surface; null once the recorder has released it. */
    val inputSurface: Surface?
    val widthPx: Int
    val heightPx: Int

    /**
     * Presentation time (nanoseconds, take-relative, starting at 0) for the
     * composite frame the backend is about to draw and swap into
     * [inputSurface], or a negative value to skip the frame (recorder
     * finishing / canceled).
     */
    fun nextFramePresentationTimeNs(): Long

    /** The backend swapped one frame stamped [presentationTimeNs] into [inputSurface]. */
    fun onFrameSubmitted(presentationTimeNs: Long)

    /**
     * The backend can no longer draw into [inputSurface] (EGL/GL failure on
     * the encoder surface, typically because the recorder released it after
     * its own encoder failure) and is detaching the target itself; no further
     * frame will be submitted. Called at most once per attach. The recorder
     * must abort the take (partial deleted) instead of committing a file that
     * silently ends at the failure. [reason] is a diagnostic token.
     */
    fun onSurfaceFailed(reason: String) {}
}

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
     * Attaches (non-null) or detaches (null) a live recording's encoder
     * surface. While attached, every [drawFrame] that latches a new camera
     * frame also draws the full green-screen composite into the target and
     * swaps it with the target's presentation time. Returns true when the
     * request took effect. Both production backends
     * ([AndroidGreenScreenPreviewCompositor] and
     * [AndroidGreenScreenGpuResidentPreviewBackend]) override this. The
     * default supports detach only: a backend without an encoder draw route
     * rejects attach, and the coordinator fails the recording start closed
     * with `recording_failed` instead of recording a black or raw-camera
     * file. Render-thread only.
     */
    fun setSegmentRecorderTarget(target: AndroidGreenScreenSegmentRecorderSurfaceTarget?): Boolean = target == null

    /**
     * Arms (non-null) or disarms (null) a one-shot still-photo read-back of
     * the composited frame (VG-LIVE-GREENSCREEN-PHOTO). An armed request is
     * consumed by the next [drawFrame] that reaches its composite pass, which
     * resolves it exactly once (captured or failed) before that draw returns;
     * a [drawFrame] that returns early without compositing (no output
     * surface, released) leaves the request armed, so the caller disarms it
     * and fails its own way. Arming replaces any previously armed request
     * without resolving it. Returns true when the request is armed (or a
     * null request was cleared). Both production backends override this; the
     * default supports disarm only, so a backend without a read-back route
     * fails a photo closed instead of returning a raw or black image.
     * Render-thread only.
     */
    fun setCompositeCaptureRequest(request: AndroidGreenScreenCompositeCaptureRequest?): Boolean = request == null

    /**
     * Read-only, render-thread-only diagnostics snapshot for regression
     * tooling. Default is empty; backends that carry meaningful telemetry
     * (such as [AndroidGreenScreenGpuResidentPreviewBackend]) override this.
     * Must never mutate state.
     */
    fun diagnosticsSnapshot(): Map<String, Any?> = emptyMap()
}
