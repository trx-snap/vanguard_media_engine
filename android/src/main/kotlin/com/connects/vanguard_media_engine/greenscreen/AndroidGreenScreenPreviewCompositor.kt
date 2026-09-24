package com.connects.vanguard_media_engine.greenscreen

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt

// -----------------------------------------------------------------------------
// Independent single-camera GLES compositor for the GreenScreen preview.
// -----------------------------------------------------------------------------
//
// Ported the subset of duet/AndroidDuetPreviewCompositor.kt that GreenScreen
// actually exercises in production. GreenScreen always ran
// AndroidDuetPreviewRenderLoop with `decoderProvider = { null }`, so the
// decoder/source-video OES ingest, its aspect-fill draw, and the RND-only
// mask-debug-view / GPU-resident-mask seams were provably dead code for this
// capability (the decoder was never bound, so `hasTexImage` was always
// false and the video draw call never ran; the debug-view and GPU-mask
// methods were never called by either GreenScreen consumer). None of that is
// ported here. `setCameraFrameTransform` is a no-op here, exactly like
// duet/AndroidDuetPreviewCompositor.kt: the camera SurfaceTexture's own
// transform matrix (cameraStMatrix, from getTransformMatrix) already
// delivers a display-correct camera feed, so no additional rotation/mirror
// of the camera texture sample is applied. Everything else (camera ingest,
// green-screen mask compositing math, static background compositing, EGL
// lifecycle) is preserved exactly.
//
// Owns the EGL display/context and the camera-facing SurfaceTexture ingest:
//   - A camera OES texture + SurfaceTexture + [cameraInputSurface] the
//     GreenScreen Camera2 source renders into.
//   - A borrowed output Surface (Flutter SurfaceProducer surface acquired via
//     AndroidPreviewSurfaceProducer.acquireSurface()) wrapped in an EGL
//     window surface. The output Surface is NEVER released here; only the EGL
//     window surface wrapping it is destroyed on [detachOutputSurface].
//
// Lifetime split:
//   - Output loss (Flutter onSurfaceCleanup) destroys ONLY the EGL window
//     surface. The EGL context, camera OES texture, SurfaceTexture and
//     [cameraInputSurface] all survive, so the camera stays bound and a later
//     re-attach resumes without rebuilding it.
//   - [release] is terminal: it tears down the SurfaceTexture ingest, the GL
//     objects and the whole EGL stack. Idempotent, never throws.
//
// A 1x1 pbuffer surface keeps the context current on the render thread while
// no output is attached, so texture setup/teardown never depends on the
// (transient) window surface.
//
// Threading: render-thread-only. Every method (and property read) must run on
// the single render thread owned by AndroidGreenScreenPreviewRenderLoop. The
// only cross-thread touch point is the camera SurfaceTexture frame-available
// callback (which may fire on any looper and therefore only sets
// [cameraFramePending]) and [updateGreenScreenMask] (AtomicReference).
//
// Recording (VG-LIVE-GREENSCREEN-RECORDING): [setSegmentRecorderTarget]
// wraps a recorder's MediaCodec input Surface in a second EGL window surface
// on this same context; after every preview swap that latched a new camera
// frame, [encodeRecorderFrame] draws the identical composite
// ([drawCompositeScene]: background + masked camera, current layout) into
// it with the recorder's presentation time. The recorded file is therefore
// exactly what the preview shows -- never the raw camera alone.

class AndroidGreenScreenPreviewCompositor : AndroidGreenScreenPreviewBackend {

    companion object {
        private const val TAG = "GreenScreenPreviewComp"

        // Deterministic placeholder fill for the camera rect when green-screen
        // is disabled and no camera frame has arrived yet: a fixed dark slate,
        // identical every frame.
        private const val CAMERA_PLACEHOLDER_R = 0.13f
        private const val CAMERA_PLACEHOLDER_G = 0.14f
        private const val CAMERA_PLACEHOLDER_B = 0.17f

        // Deterministic landscape preview buffer size for the camera SurfaceTexture,
        // matching the 16:9 SurfaceRequest resolution CameraX's Preview use-case
        // actually negotiates on-device (observed 1920x1080). The SurfaceTexture
        // needs a non-zero default buffer size up front so it can export a valid
        // EGLImage from the first onFrameAvailable call; without this the first
        // updateTexImage may silently produce a zero-size image. This is a
        // preview-ingress default only; no recording/export claim.
        private const val CAMERA_ST_DEFAULT_WIDTH  = 1920
        private const val CAMERA_ST_DEFAULT_HEIGHT = 1080

        // Aspect ratio (width/height) of the camera image once [cameraStMatrix]
        // has rotated the landscape sensor buffer upright for a portrait front
        // camera: the width/height dimensions swap, so the upright aspect is
        // height-over-width of the raw buffer above (1080/1920 == 9:16). Used by
        // [cameraAspectFillViewport] since the camera has no analogous decoder
        // video size of its own.
        private const val CAMERA_UPRIGHT_ASPECT =
            CAMERA_ST_DEFAULT_HEIGHT.toDouble() / CAMERA_ST_DEFAULT_WIDTH.toDouble()
    }

    // -- EGL core (created lazily on first attach, destroyed only in release) --

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglConfig: EGLConfig? = null

    /** Keeps [eglContext] current while no output window surface exists. */
    private var eglPbufferSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    /** Wraps the borrowed output Surface; destroyed on every output loss. */
    private var eglWindowSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    private var coreReady = false

    // -- Camera ingest (survives output loss, released only in release) -------

    private var cameraOesTextureId = 0
    private var cameraSurfaceTexture: SurfaceTexture? = null

    @Volatile
    private var _cameraInputSurface: Surface? = null

    /**
     * Surface the camera (AndroidGreenScreenCamera2Source) renders into. Owned
     * by this compositor: allocated on first [attachOutputSurface], released
     * once in [release]. Null until the first successful [attachOutputSurface].
     */
    override val cameraInputSurface: Surface? get() = _cameraInputSurface

    /** Set by the camera frame-available callback (any thread), consumed in [drawFrame]. */
    private val cameraFramePending = AtomicBoolean(false)

    /** True when [drawFrame] has latched at least one real camera frame. */
    private var hasCameraTexImage = false

    /** True when a new camera frame is waiting to be consumed. */
    override val hasPendingCameraFrame: Boolean get() = cameraFramePending.get()

    // -- Live recording encoder target (VG-LIVE-GREENSCREEN-RECORDING; render-thread only) --

    /**
     * Attached encoder target ([setSegmentRecorderTarget]) and the EGL window
     * surface wrapping its MediaCodec input Surface. The window surface is
     * created against this compositor's own [eglConfig]/[eglContext] so the
     * already-latched camera OES texture, mask texture and background can be
     * drawn into it directly (zero copy). Independent of the preview output
     * surface: it survives output loss and is destroyed by
     * [setSegmentRecorderTarget] (null) or [release].
     */
    private var recorderTarget: AndroidGreenScreenSegmentRecorderSurfaceTarget? = null
    private var eglRecorderSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var recorderFramesSubmitted = 0L
    private var recorderFramesSkipped = 0L
    private var recorderFailureLogged = false

    /**
     * Armed one-shot still-photo read-back (VG-LIVE-GREENSCREEN-PHOTO),
     * consumed by the next [drawFrame] that reaches [drawCompositeScene].
     * Render-thread only; failed (never left dangling) by
     * [detachOutputSurface] and [release].
     */
    private var compositeCaptureRequest: AndroidGreenScreenCompositeCaptureRequest? = null

    private val cameraStMatrix = FloatArray(16).also { Matrix.setIdentityM(it, 0) }

    // -- Output / layout state -------------------------------------------------

    private var outputSurface: Surface? = null
    private var outputWidthPx = 0
    private var outputHeightPx = 0

    private var sourceRect: AndroidGreenScreenPixelRect? = null
    private var cameraRect: AndroidGreenScreenPixelRect? = null

    private val isReleased = AtomicBoolean(false)

    // -- Plain camera-passthrough GL program (used when green-screen is disabled) --

    private var oesProgram = 0
    private var aPositionLoc = -1
    private var aTexCoordLoc = -1
    private var uSTMatrixLoc = -1
    private var sTextureLoc = -1

    // -- Green-screen GL state -------------------------------------------------

    /** True when the session is compositing camera-over-background. Render-thread only. */
    private var greenScreenEnabled = false

    /**
     * Pending mask data to upload on the next drawFrame. Delivered from the
     * segmentation callback (off render thread) via [updateGreenScreenMask];
     * consumed on the render thread inside drawFrame. Wrapped in
     * AtomicReference so the setter (any thread) and getter (render thread)
     * don't race.
     */
    private val pendingMaskRef = AtomicReference<AndroidGreenScreenSegmentationFrame?>(null)

    /** GL texture ID for the single-channel mask (LUMINANCE). 0 = not yet allocated. */
    private var maskTextureId = 0

    /** GLES program: OES camera + 2D mask → alpha-blended draw. 0 = not yet compiled. */
    private var greenScreenProgram = 0
    private var gsAPositionLoc = -1
    private var gsATexCoordLoc = -1
    private var gsUSTMatrixLoc = -1
    private var gsSCameraLoc = -1
    private var gsUMaskLoc = -1
    private var gsUMaskTexelSizeLoc = -1

    /** Whether [maskTextureId] has been uploaded with at least one real mask. */
    private var hasMaskTexture = false

    /** Whether the first mask texture upload diagnostic log has fired. Render-thread only. */
    private var hasLoggedFirstMaskUpload = false

    /** Backend id of the most recently uploaded mask (diagnostic only). Render-thread only. */
    private var lastUploadedMaskBackend: String? = null

    /**
     * Dimensions of the most recently uploaded mask texture, used to derive the
     * `uMaskTexelSize` uniform for GPU-side matte erosion. 0 = unknown (draw
     * falls back to a (1,1) texel size so neighbour taps clamp to the edge and
     * refinement degrades to a plain sample rather than crashing). Render-thread only.
     */
    private var latestMaskWidth = 0
    private var latestMaskHeight = 0

    // -- Green-screen static background GL state -------------------------------

    /** Current background spec. Render-thread only; default preserves prior behavior. */
    private var greenScreenBackground: AndroidGreenScreenBackground = AndroidGreenScreenBackground.VIDEO

    /** GL texture id for a decoded [AndroidGreenScreenBackgroundType.IMAGE] background. 0 = none loaded. */
    private var backgroundImageTextureId = 0
    private var backgroundImageWidthPx = 0
    private var backgroundImageHeightPx = 0

    /** File path the currently-loaded [backgroundImageTextureId] was decoded from, if any. */
    private var backgroundImageLoadedPath: String? = null

    /** True once decode/texture upload has failed for [backgroundImageLoadedPath]; stops retrying every frame. */
    private var backgroundImageDecodeFailed = false

    /** GLES program: plain 2D texture sampler used to draw a static image background. 0 = not yet compiled. */
    private var backgroundImageProgram = 0
    private var bgImageAPositionLoc = -1
    private var bgImageATexCoordLoc = -1
    private var bgImageSTextureLoc = -1

    // -- Green-screen static background: VIDEO GL state (Slice 2) --------------
    //
    // Mirrors the camera ingest shape (OES texture + SurfaceTexture +
    // frame-pending flag, latched in drawFrame) rather than the IMAGE state
    // above, because a video background is itself a continuous producer, not
    // a one-shot decode. Draws reuse the existing plain [oesProgram] (camera
    // passthrough shader) since both are "OES texture + ST matrix" draws.

    private var backgroundVideoOesTextureId = 0
    private var backgroundVideoSurfaceTexture: SurfaceTexture? = null
    private var backgroundVideoSurface: Surface? = null
    private val backgroundVideoStMatrix = FloatArray(16).also { Matrix.setIdentityM(it, 0) }
    private val backgroundVideoFramePending = AtomicBoolean(false)

    /** True once [backgroundVideoSurfaceTexture] has latched at least one real decoded frame. */
    private var hasBackgroundVideoTexImage = false

    /** The decoder exclusively owning [backgroundVideoSurface]/[backgroundVideoSurfaceTexture]; null when no video background is active. */
    private var backgroundVideoDecoder: AndroidGreenScreenVideoBackgroundDecoder? = null

    /** File path the currently-loaded [backgroundVideoDecoder] was started for, if any. */
    private var backgroundVideoLoadedPath: String? = null

    /** True once video ingest setup has failed for [backgroundVideoLoadedPath]; stops retrying every frame. */
    private var backgroundVideoDecodeFailed = false

    /**
     * Reported by [backgroundVideoDecoder] once its format is known. Written
     * only from the decoder's own thread, read only from the render thread
     * inside [backgroundVideoAspectViewport]; volatile for cross-thread
     * visibility (single writer, single reader — no read-modify-write race).
     */
    @Volatile private var backgroundVideoWidthPx = 0
    @Volatile private var backgroundVideoHeightPx = 0
    @Volatile private var backgroundVideoRotationDegrees = 0

    private val quadPositions: FloatBuffer = floatBufferOf(
        -1f, -1f,
         1f, -1f,
        -1f,  1f,
         1f,  1f,
    )
    private val quadTexCoords: FloatBuffer = floatBufferOf(
        0f, 0f,
        1f, 0f,
        0f, 1f,
        1f, 1f,
    )

    // -- Attach / detach -------------------------------------------------------

    /**
     * Wraps the borrowed [surface] in an EGL window surface and makes it
     * current. First call also bootstraps the EGL core and the camera ingest
     * (OES texture / SurfaceTexture / [cameraInputSurface]).
     *
     * [surface] is borrowed (SurfaceProducer-owned): it is never released
     * here, under any path. Re-attaching while already attached destroys the
     * previous window surface first. Returns false (leaving no window surface
     * bound) when released, [surface] is invalid, or any EGL step fails.
     */
    override fun attachOutputSurface(surface: Surface, widthPx: Int, heightPx: Int): Boolean {
        if (isReleased.get()) return false
        if (!surface.isValid || widthPx <= 0 || heightPx <= 0) {
            Log.w(TAG, "attachOutputSurface rejected: valid=${surface.isValid} ${widthPx}x$heightPx")
            return false
        }
        if (!ensureCore()) return false

        // Re-attach: drop the previous window surface only.
        destroyWindowSurfaceQuietly()

        try {
            val window = EGL14.eglCreateWindowSurface(
                eglDisplay, eglConfig, surface, intArrayOf(EGL14.EGL_NONE), 0,
            )
            if (window == null || window == EGL14.EGL_NO_SURFACE) {
                Log.w(TAG, "eglCreateWindowSurface failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
                makeCurrentQuietly(eglPbufferSurface)
                return false
            }
            if (!EGL14.eglMakeCurrent(eglDisplay, window, window, eglContext)) {
                Log.w(TAG, "eglMakeCurrent(window) failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
                try { EGL14.eglDestroySurface(eglDisplay, window) } catch (_: Throwable) {}
                makeCurrentQuietly(eglPbufferSurface)
                return false
            }
            eglWindowSurface = window
            outputSurface = surface
            outputWidthPx = widthPx
            outputHeightPx = heightPx
            return true
        } catch (t: Throwable) {
            Log.w(TAG, "attachOutputSurface threw: ${t.message}")
            makeCurrentQuietly(eglPbufferSurface)
            return false
        }
    }

    /**
     * Output loss: destroys ONLY the EGL window surface and drops the borrowed
     * output Surface reference (never releasing it). The EGL context, camera
     * OES texture, SurfaceTexture and [cameraInputSurface] all stay alive so
     * the camera remains bound for a later re-attach. Tolerates every EGL
     * teardown error; never throws. Idempotent.
     */
    override fun detachOutputSurface() {
        // A still-photo read-back armed against this output must not resolve
        // against a later re-attached one.
        failCompositeCaptureQuietly("output_detached")
        destroyWindowSurfaceQuietly()
        outputSurface = null
        outputWidthPx = 0
        outputHeightPx = 0
    }

    // -- Layout ------------------------------------------------------------

    /** Canvas-pixel rects (top-left origin) for the background and camera layer. */
    override fun setLayout(sourceRect: AndroidGreenScreenPixelRect, cameraRect: AndroidGreenScreenPixelRect) {
        this.sourceRect = sourceRect
        this.cameraRect = cameraRect
    }

    // -- Green-screen controls (render-thread only for enabled; AtomicRef for mask) --

    /**
     * Enable or disable green-screen compositing. Must be called on the render thread.
     * When disabled, the camera rect reverts to plain camera passthrough (or a
     * placeholder before the first camera frame arrives).
     */
    override fun setGreenScreenEnabled(enabled: Boolean) {
        greenScreenEnabled = enabled
        if (!enabled) {
            // Clear pending mask so stale data is not shown if re-enabled later.
            pendingMaskRef.set(null)
            hasMaskTexture = false
            hasLoggedFirstMaskUpload = false
            lastUploadedMaskBackend = null
            latestMaskWidth = 0
            latestMaskHeight = 0
        }
    }

    /**
     * Delivers a new segmentation mask to be uploaded on the next [drawFrame].
     * Safe to call from any thread (backed by AtomicReference — latest wins,
     * stale frames are dropped). Segmentation callback thread → render thread.
     */
    override fun updateGreenScreenMask(frame: AndroidGreenScreenSegmentationFrame) {
        pendingMaskRef.set(frame)
    }

    /**
     * Stores the new background spec; render-thread only (posted here by the
     * render loop). The actual image decode/texture (re)load is deferred to
     * [ensureBackgroundImageTexture] inside [drawFrame], mirroring how
     * [updateGreenScreenMask] defers its GL upload to [uploadMaskTexture] —
     * both need the EGL context current, which is only guaranteed there.
     */
    override fun setGreenScreenBackground(background: AndroidGreenScreenBackground) {
        greenScreenBackground = background
    }

    /**
     * Composites one frame into the attached output surface:
     *   1. full clear to black,
     *   2. green-screen background (solid color / image) when enabled,
     *   3. masked camera over the background (green-screen) or plain camera
     *      passthrough / placeholder (green-screen disabled),
     *   4. eglSwapBuffers.
     *
     * Returns true when a frame was actually presented (swap succeeded).
     * Returns false (without throwing) when released, no output is attached,
     * or EGL rejects the frame (e.g. surface torn down mid-draw).
     */
    override fun drawFrame(): Boolean {
        if (isReleased.get() || !coreReady) return false
        val display = eglDisplay
        val window = eglWindowSurface
        if (display == EGL14.EGL_NO_DISPLAY || window == EGL14.EGL_NO_SURFACE) return false
        if (outputWidthPx <= 0 || outputHeightPx <= 0) return false

        try {
            if (!EGL14.eglMakeCurrent(display, window, window, eglContext)) return false

            // Latch camera frame if one arrived since last draw.
            var latchedNewCameraFrame = false
            val camSt = cameraSurfaceTexture
            if (camSt != null && cameraFramePending.compareAndSet(true, false)) {
                camSt.updateTexImage()
                camSt.getTransformMatrix(cameraStMatrix)
                hasCameraTexImage = true
                latchedNewCameraFrame = true
            }

            // Latch a new background video frame if one arrived since last
            // draw. Unconditional (like the camera latch above) so the
            // decoder's bounded SurfaceTexture BufferQueue never backs up
            // while green-screen compositing happens to be disabled.
            val bgVideoSt = backgroundVideoSurfaceTexture
            if (bgVideoSt != null && backgroundVideoFramePending.compareAndSet(true, false)) {
                try {
                    bgVideoSt.updateTexImage()
                    bgVideoSt.getTransformMatrix(backgroundVideoStMatrix)
                    hasBackgroundVideoTexImage = true
                } catch (t: Throwable) {
                    Log.w(TAG, "background video updateTexImage failed: ${t.message}")
                }
            }

            // Upload latest mask texture when green-screen is active.
            if (greenScreenEnabled) {
                val maskFrame = pendingMaskRef.getAndSet(null)
                if (maskFrame != null) {
                    uploadMaskTexture(maskFrame)
                }
            }

            drawCompositeScene()

            // VG-LIVE-GREENSCREEN-PHOTO: one-shot read-back of exactly the
            // composite just drawn, BEFORE the swap (the back buffer's
            // contents are undefined after eglSwapBuffers). Pixel read only:
            // row-flipping and JPEG encoding happen off this thread.
            val capture = compositeCaptureRequest
            if (capture != null) {
                compositeCaptureRequest = null
                readBackComposite(capture)
            }

            GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
            val presented = EGL14.eglSwapBuffers(display, window)

            // VG-LIVE-GREENSCREEN-RECORDING: after the preview swap, draw the
            // SAME composite (same latched camera frame, mask, background and
            // layout) into the attached recorder surface -- once per new camera
            // frame, so the encoder never sees duplicates. The preview output
            // above is unchanged; encodeRecorderFrame restores the preview
            // surface as current before returning.
            if (latchedNewCameraFrame && recorderTarget != null) {
                encodeRecorderFrame()
            }
            return presented
        } catch (t: Throwable) {
            Log.w(TAG, "drawFrame failed: ${t.message}")
            return false
        }
    }

    /**
     * Draws the full green-screen composite for the current output dimensions
     * ([outputWidthPx] x [outputHeightPx]) into whatever EGL surface is
     * current: full clear to black, the green-screen background (solid color /
     * image / video) when enabled, then the masked camera over it -- or, with
     * green-screen disabled, the plain camera passthrough / placeholder.
     * Shared verbatim by the preview pass ([drawFrame]) and the recording
     * pass ([encodeRecorderFrame]) so the recorded file is exactly what the
     * preview shows. Assumes the camera/mask/background textures for this
     * frame were already latched/uploaded by [drawFrame].
     */
    private fun drawCompositeScene() {
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
        GLES20.glViewport(0, 0, outputWidthPx, outputHeightPx)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        if (greenScreenEnabled) {
            drawGreenScreenBackground(sourceRect ?: fullSurfaceRect())
        }

        // Camera rect drawing:
        // - Green-screen mode: draw camera masked by the segmentation mask.
        //   If no camera frame has arrived yet or no mask texture is ready,
        //   leave the background visible underneath (do NOT draw an opaque placeholder).
        // - Disabled: draw live OES frame when available, else placeholder.
        val cr = cameraRect
        if (cr != null) {
            if (greenScreenEnabled) {
                if (hasCameraTexImage && hasMaskTexture) {
                    drawCameraGreenScreen(cr)
                }
                // else: background remains visible, invariant satisfied.
            } else {
                if (hasCameraTexImage) {
                    drawCameraRect(cr)
                } else {
                    drawCameraPlaceholder(cr)
                }
            }
        }
    }

    // -- Still photo read-back (VG-LIVE-GREENSCREEN-PHOTO) ---------------------

    /**
     * Arms/disarms the one-shot composite read-back (see
     * [AndroidGreenScreenPreviewBackend.setCompositeCaptureRequest]). Rejects
     * (false, nothing armed) once released. Render-thread only.
     */
    override fun setCompositeCaptureRequest(request: AndroidGreenScreenCompositeCaptureRequest?): Boolean {
        if (request == null) {
            compositeCaptureRequest = null
            return true
        }
        if (isReleased.get()) return false
        compositeCaptureRequest = request
        return true
    }

    /**
     * Reads the composite [drawCompositeScene] just drew into the current
     * (preview window) surface back to a direct RGBA8 buffer with
     * glReadPixels (GL bottom-left origin; the receiver flips rows) and
     * resolves [request] exactly once. Requires at least one latched camera
     * frame: a composite without the camera layer is not a photo of the
     * user, so it fails with `no_camera_frame` instead. Render-thread only,
     * called by [drawFrame] with the preview surface current, before the swap.
     */
    private fun readBackComposite(request: AndroidGreenScreenCompositeCaptureRequest) {
        val widthPx = outputWidthPx
        val heightPx = outputHeightPx
        if (!hasCameraTexImage) {
            request.onFailed("no_camera_frame")
            return
        }
        if (widthPx <= 0 || heightPx <= 0) {
            request.onFailed("invalid_output_size")
            return
        }
        val rgba: ByteBuffer
        val readMs: Double
        try {
            val startNs = System.nanoTime()
            rgba = ByteBuffer.allocateDirect(widthPx * heightPx * 4).order(ByteOrder.nativeOrder())
            // Drain stale GL errors (bounded) so the read-back verdict below is exact.
            var drained = 0
            while (drained < 8 && GLES20.glGetError() != GLES20.GL_NO_ERROR) drained++
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            GLES20.glPixelStorei(GLES20.GL_PACK_ALIGNMENT, 4)
            GLES20.glReadPixels(0, 0, widthPx, heightPx, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, rgba)
            val glErr = GLES20.glGetError()
            if (glErr != GLES20.GL_NO_ERROR) {
                request.onFailed("glReadPixels_error_0x${Integer.toHexString(glErr)}")
                return
            }
            rgba.rewind()
            readMs = (System.nanoTime() - startNs) / 1_000_000.0
        } catch (t: Throwable) {
            Log.w(TAG, "ANDROID_LIVE_GREENSCREEN_PHOTO_READBACK_FAILED backend=gles_compositor ${t.javaClass.simpleName}: ${t.message}")
            request.onFailed("readback_exception:${t.javaClass.simpleName}")
            return
        }
        Log.i(
            TAG,
            "ANDROID_LIVE_GREENSCREEN_PHOTO_CAPTURED backend=gles_compositor size=${widthPx}x$heightPx " +
                "readMs=${"%.2f".format(readMs)} greenScreen=$greenScreenEnabled maskReady=$hasMaskTexture",
        )
        try {
            request.onCaptured(rgba, widthPx, heightPx)
        } catch (t: Throwable) {
            Log.w(TAG, "composite capture onCaptured threw: ${t.message}")
        }
    }

    /** Fails and forgets an armed read-back so it never resolves on a later, unrelated frame. */
    private fun failCompositeCaptureQuietly(reason: String) {
        val request = compositeCaptureRequest ?: return
        compositeCaptureRequest = null
        try {
            request.onFailed(reason)
        } catch (t: Throwable) {
            Log.w(TAG, "composite capture onFailed threw: ${t.message}")
        }
    }

    // -- Live recording encoder surface (VG-LIVE-GREENSCREEN-RECORDING) --------

    /**
     * Attaches or detaches the live recording's encoder surface (see
     * [AndroidGreenScreenPreviewBackend.setSegmentRecorderTarget]). Any
     * previously attached encoder surface is destroyed first, so this is
     * idempotent and a replace is a detach + attach. Attaching bootstraps the
     * EGL core if the preview has not attached yet, wraps the target's Surface
     * in an EGL window surface on this compositor's config/context, verifies
     * it can be made current, then restores the preview (window or pbuffer)
     * as the current surface. Returns false, with nothing attached, on any
     * failure so the coordinator can fail the recording start cleanly. Must
     * run on the render thread.
     */
    override fun setSegmentRecorderTarget(target: AndroidGreenScreenSegmentRecorderSurfaceTarget?): Boolean {
        destroyRecorderSurfaceQuietly()
        if (target == null) return true
        if (isReleased.get()) return false
        if (!ensureCore()) return false
        val surface = target.inputSurface
        if (surface == null || !surface.isValid || target.widthPx <= 0 || target.heightPx <= 0) {
            Log.w(TAG, "ANDROID_LIVE_GREENSCREEN_RECORDER_SURFACE_REJECTED valid=${surface?.isValid} " +
                "size=${target.widthPx}x${target.heightPx}")
            return false
        }
        try {
            val eglSurf = EGL14.eglCreateWindowSurface(
                eglDisplay, eglConfig, surface, intArrayOf(EGL14.EGL_NONE), 0,
            )
            if (eglSurf == null || eglSurf == EGL14.EGL_NO_SURFACE) {
                Log.w(TAG, "ANDROID_LIVE_GREENSCREEN_RECORDER_SURFACE_FAILED stage=eglCreateWindowSurface " +
                    "error=0x${Integer.toHexString(EGL14.eglGetError())}")
                restorePreviewCurrentQuietly()
                return false
            }
            if (!EGL14.eglMakeCurrent(eglDisplay, eglSurf, eglSurf, eglContext)) {
                Log.w(TAG, "ANDROID_LIVE_GREENSCREEN_RECORDER_SURFACE_FAILED stage=eglMakeCurrent " +
                    "error=0x${Integer.toHexString(EGL14.eglGetError())}")
                restorePreviewCurrentQuietly()
                try { EGL14.eglDestroySurface(eglDisplay, eglSurf) } catch (_: Throwable) {}
                return false
            }
            restorePreviewCurrentQuietly()
            eglRecorderSurface = eglSurf
            recorderTarget = target
            recorderFramesSubmitted = 0L
            recorderFramesSkipped = 0L
            recorderFailureLogged = false
            Log.i(
                TAG,
                "ANDROID_LIVE_GREENSCREEN_RECORDER_SURFACE_ATTACHED size=${target.widthPx}x${target.heightPx} " +
                    "cameraLatched=$hasCameraTexImage maskReady=$hasMaskTexture greenScreen=$greenScreenEnabled",
            )
            return true
        } catch (t: Throwable) {
            Log.w(TAG, "ANDROID_LIVE_GREENSCREEN_RECORDER_SURFACE_FAILED stage=exception ${t.javaClass.simpleName}: ${t.message}")
            restorePreviewCurrentQuietly()
            return false
        }
    }

    /**
     * Draws the full composite latched by the enclosing [drawFrame] into the
     * attached encoder surface ([drawCompositeScene] against the encoder
     * frame's dimensions -- the recorder is always sized to the session canvas,
     * so the same layout rects apply), stamped with the target's presentation
     * time, then swapped. Runs after the preview swap so preview latency is
     * untouched, and restores the preview dimensions and surface before
     * returning. Every EGL/GL failure is logged once and never thrown. Frames
     * the target declines (negative PTS: recorder finishing/canceled) are
     * skipped without touching the encoder surface.
     */
    private fun encodeRecorderFrame() {
        val target = recorderTarget ?: return
        val eglSurf = eglRecorderSurface
        if (eglSurf == EGL14.EGL_NO_SURFACE) return
        val ptsNs = target.nextFramePresentationTimeNs()
        if (ptsNs < 0L) {
            recorderFramesSkipped++
            return
        }
        val savedWidthPx = outputWidthPx
        val savedHeightPx = outputHeightPx
        try {
            if (!EGL14.eglMakeCurrent(eglDisplay, eglSurf, eglSurf, eglContext)) {
                failRecorderSurface("eglMakeCurrent", "error=0x${Integer.toHexString(EGL14.eglGetError())}")
                return
            }
            // toGlRect / fullSurfaceRect derive viewport, scissor and aspect
            // math from the output dimensions; point them at the encoder frame
            // for this pass only.
            outputWidthPx = target.widthPx
            outputHeightPx = target.heightPx
            drawCompositeScene()
            GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
            EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurf, ptsNs)
            if (EGL14.eglSwapBuffers(eglDisplay, eglSurf)) {
                recorderFramesSubmitted++
                target.onFrameSubmitted(ptsNs)
                if (recorderFramesSubmitted == 1L) {
                    Log.i(TAG, "ANDROID_LIVE_GREENSCREEN_RECORDER_FIRST_FRAME ptsNs=$ptsNs " +
                        "frame=${target.widthPx}x${target.heightPx} greenScreen=$greenScreenEnabled " +
                        "maskReady=$hasMaskTexture")
                }
            } else {
                failRecorderSurface("eglSwapBuffers", "error=0x${Integer.toHexString(EGL14.eglGetError())}")
            }
        } catch (t: Throwable) {
            failRecorderSurface("exception", "${t.javaClass.simpleName}: ${t.message}")
        } finally {
            outputWidthPx = savedWidthPx
            outputHeightPx = savedHeightPx
            restorePreviewCurrentQuietly()
        }
    }

    /**
     * The encoder surface can no longer be drawn into (EGL/GL failure, or the
     * recorder released it underneath us). Logs once, tells the target so the
     * recorder aborts instead of committing a file truncated at the failure,
     * then detaches the surface so no further frame touches it. Structurally
     * once per attach: the target is cleared here and [encodeRecorderFrame]
     * is never entered without one.
     */
    private fun failRecorderSurface(stage: String, detail: String) {
        val target = recorderTarget ?: return
        if (!recorderFailureLogged) {
            recorderFailureLogged = true
            Log.w(TAG, "ANDROID_LIVE_GREENSCREEN_RECORDER_FRAME_FAILED backend=gles_compositor stage=$stage $detail")
        }
        try {
            target.onSurfaceFailed("gles_compositor_recorder_frame_failed:$stage")
        } catch (t: Throwable) {
            Log.w(TAG, "onSurfaceFailed threw: ${t.message}")
        }
        destroyRecorderSurfaceQuietly()
    }

    /** Makes the preview window surface current again when attached, else the bootstrap pbuffer. */
    private fun restorePreviewCurrentQuietly() {
        val window = eglWindowSurface
        makeCurrentQuietly(if (window != EGL14.EGL_NO_SURFACE) window else eglPbufferSurface)
    }

    /**
     * Destroys only the encoder EGL window surface (never the recorder-owned
     * Surface behind it) after switching the preview/pbuffer back to current,
     * and forgets the target. Idempotent; tolerates a recorder Surface that is
     * already dead (recorder canceled first).
     */
    private fun destroyRecorderSurfaceQuietly() {
        val surf = eglRecorderSurface
        val target = recorderTarget
        eglRecorderSurface = EGL14.EGL_NO_SURFACE
        recorderTarget = null
        if (surf == EGL14.EGL_NO_SURFACE || eglDisplay == EGL14.EGL_NO_DISPLAY) return
        restorePreviewCurrentQuietly()
        try { EGL14.eglDestroySurface(eglDisplay, surf) } catch (_: Throwable) {}
        if (target != null) {
            Log.i(TAG, "ANDROID_LIVE_GREENSCREEN_RECORDER_SURFACE_DETACHED " +
                "framesSubmitted=$recorderFramesSubmitted framesSkipped=$recorderFramesSkipped")
        }
    }

    // -- Release (terminal, idempotent, never throws) --------------------------

    /**
     * Terminal teardown: window surface, GL program/texture, SurfaceTexture,
     * [cameraInputSurface] (the one place it is ever released), then the EGL
     * context/display. Tolerates every EGL/GL error.
     */
    override fun release() {
        if (!isReleased.compareAndSet(false, true)) return

        try { cameraSurfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}

        // Still-photo read-back armed for a frame that will never be drawn.
        failCompositeCaptureQuietly("released")
        destroyWindowSurfaceQuietly()
        outputSurface = null
        // Recording encoder EGL wrapper (never the recorder-owned Surface).
        destroyRecorderSurfaceQuietly()

        // GL object teardown needs the context current; pbuffer provides that.
        if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglContext != EGL14.EGL_NO_CONTEXT) {
            makeCurrentQuietly(eglPbufferSurface)
            try {
                if (oesProgram != 0) GLES20.glDeleteProgram(oesProgram)
            } catch (_: Throwable) {}
            try {
                if (cameraOesTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(cameraOesTextureId), 0)
            } catch (_: Throwable) {}
            // Green-screen GL teardown.
            try {
                if (greenScreenProgram != 0) GLES20.glDeleteProgram(greenScreenProgram)
            } catch (_: Throwable) {}
            try {
                if (maskTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(maskTextureId), 0)
            } catch (_: Throwable) {}
            try {
                if (backgroundImageProgram != 0) GLES20.glDeleteProgram(backgroundImageProgram)
            } catch (_: Throwable) {}
            try {
                if (backgroundImageTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(backgroundImageTextureId), 0)
            } catch (_: Throwable) {}
            // Background video teardown needs the EGL context current (GL
            // texture delete); the decoder's own Surface/SurfaceTexture
            // release happens asynchronously on its own thread regardless.
            releaseBackgroundVideoQuietly()
        }
        oesProgram = 0
        cameraOesTextureId = 0
        greenScreenProgram = 0
        maskTextureId = 0
        hasMaskTexture = false
        hasLoggedFirstMaskUpload = false
        latestMaskWidth = 0
        latestMaskHeight = 0
        backgroundImageProgram = 0
        backgroundImageTextureId = 0
        backgroundImageWidthPx = 0
        backgroundImageHeightPx = 0
        backgroundImageLoadedPath = null
        backgroundImageDecodeFailed = false

        // Camera ingest teardown — compositor releases the cameraInputSurface here.
        try { _cameraInputSurface?.release() } catch (_: Throwable) {}
        _cameraInputSurface = null
        try { cameraSurfaceTexture?.release() } catch (_: Throwable) {}
        cameraSurfaceTexture = null

        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            try {
                EGL14.eglMakeCurrent(
                    eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
                )
            } catch (_: Throwable) {}
            if (eglPbufferSurface != EGL14.EGL_NO_SURFACE) {
                try { EGL14.eglDestroySurface(eglDisplay, eglPbufferSurface) } catch (_: Throwable) {}
            }
            if (eglContext != EGL14.EGL_NO_CONTEXT) {
                try { EGL14.eglDestroyContext(eglDisplay, eglContext) } catch (_: Throwable) {}
            }
            try { EGL14.eglTerminate(eglDisplay) } catch (_: Throwable) {}
        }
        eglPbufferSurface = EGL14.EGL_NO_SURFACE
        eglContext = EGL14.EGL_NO_CONTEXT
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglConfig = null
        coreReady = false
        hasCameraTexImage = false
    }

    // -- EGL core bootstrap ----------------------------------------------------

    /**
     * One-time EGL + ingest bootstrap: display, ES2 context, 1x1 pbuffer,
     * plain camera-passthrough OES program, and the camera SurfaceTexture /
     * [cameraInputSurface]. On failure everything partial is torn down and a
     * later attach may retry.
     */
    private fun ensureCore(): Boolean {
        if (coreReady) return true
        try {
            val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (display == EGL14.EGL_NO_DISPLAY) {
                Log.w(TAG, "eglGetDisplay failed")
                return false
            }
            val version = IntArray(2)
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) {
                Log.w(TAG, "eglInitialize failed")
                return false
            }
            eglDisplay = display

            // PBUFFER bit alongside WINDOW so the same config backs both the
            // bootstrap pbuffer and the output window surface.
            val attribs = intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfigs = IntArray(1)
            if (!EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, numConfigs, 0) ||
                numConfigs[0] < 1 || configs[0] == null
            ) {
                Log.w(TAG, "eglChooseConfig failed")
                teardownCoreQuietly()
                return false
            }
            val config = configs[0]!!
            eglConfig = config

            val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
            val context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
            if (context == null || context == EGL14.EGL_NO_CONTEXT) {
                Log.w(TAG, "eglCreateContext failed")
                teardownCoreQuietly()
                return false
            }
            eglContext = context

            val pbufferAttribs = intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE)
            val pbuffer = EGL14.eglCreatePbufferSurface(display, config, pbufferAttribs, 0)
            if (pbuffer == null || pbuffer == EGL14.EGL_NO_SURFACE) {
                Log.w(TAG, "eglCreatePbufferSurface failed")
                teardownCoreQuietly()
                return false
            }
            eglPbufferSurface = pbuffer

            if (!EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)) {
                Log.w(TAG, "eglMakeCurrent(pbuffer) failed")
                teardownCoreQuietly()
                return false
            }

            setupOesProgram()
            setupCameraIngest()

            coreReady = true
            return true
        } catch (t: Throwable) {
            Log.w(TAG, "EGL core bootstrap threw: ${t.message}")
            teardownCoreQuietly()
            return false
        }
    }

    /**
     * Allocates the camera OES texture, SurfaceTexture and [cameraInputSurface].
     * Must be called from [ensureCore] after the GL context is current.
     *
     * Sets a deterministic landscape preview default buffer size (1920×1080,
     * matching CameraX's negotiated Preview SurfaceRequest) on the SurfaceTexture
     * before wrapping it in a Surface. The size must be non-zero before the first
     * camera frame arrives so that updateTexImage produces a valid image and the
     * OES sampler has a defined texel size. Preview-ingress default only — no
     * recording/export claim.
     */
    private fun setupCameraIngest() {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        cameraOesTextureId = textures[0]
        if (cameraOesTextureId == 0) throw IllegalStateException("glGenTextures failed for camera OES texture")
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraOesTextureId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        val camTexture = SurfaceTexture(cameraOesTextureId)
        // Set a deterministic non-zero default buffer size before creating the
        // Surface. A zero default causes the first updateTexImage to return a
        // zero-size image, breaking the OES sampler. Preview-ingress default only.
        camTexture.setDefaultBufferSize(CAMERA_ST_DEFAULT_WIDTH, CAMERA_ST_DEFAULT_HEIGHT)
        // Callback may fire on any looper; only sets the flag — updateTexImage
        // happens exclusively on the render thread inside drawFrame.
        camTexture.setOnFrameAvailableListener { cameraFramePending.set(true) }
        cameraSurfaceTexture = camTexture
        _cameraInputSurface = Surface(camTexture)
    }

    /** Compiles the plain OES texture-passthrough program used for camera passthrough/placeholder draws. */
    private fun setupOesProgram() {
        val vertexSrc = """
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            uniform mat4 uSTMatrix;
            varying vec2 vTextureCoord;
            void main() {
                gl_Position = aPosition;
                vTextureCoord = (uSTMatrix * aTextureCoord).xy;
            }
        """.trimIndent()
        val fragmentSrc = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTextureCoord;
            uniform samplerExternalOES sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, vTextureCoord);
            }
        """.trimIndent()

        val vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, vertexSrc)
        val fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vertexShader)
        GLES20.glAttachShader(program, fragmentShader)
        GLES20.glLinkProgram(program)
        GLES20.glDeleteShader(vertexShader)
        GLES20.glDeleteShader(fragmentShader)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(program)
            GLES20.glDeleteProgram(program)
            throw IllegalStateException("GL program link failed: $log")
        }
        oesProgram = program
        aPositionLoc = GLES20.glGetAttribLocation(program, "aPosition")
        aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTextureCoord")
        uSTMatrixLoc = GLES20.glGetUniformLocation(program, "uSTMatrix")
        sTextureLoc = GLES20.glGetUniformLocation(program, "sTexture")
    }

    /**
     * Lazily compiles the green-screen shader program on demand (first time
     * green-screen draw is requested). Uses OES camera texture + 2D LUMINANCE
     * mask texture; alpha-blends the camera over the background based on mask.r.
     */
    private fun ensureGreenScreenProgram() {
        if (greenScreenProgram != 0) return
        val vertexSrc = """
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            uniform mat4 uSTMatrix;
            varying vec2 vTextureCoord;
            varying vec2 vMaskCoord;
            varying vec2 vRawTexCoord;
            void main() {
                gl_Position = aPosition;
                vec2 cameraCoord = (uSTMatrix * aTextureCoord).xy;
                vTextureCoord = cameraCoord;
                // Mask is sampled in the same ST-matrix-transformed camera UV
                // space as the camera texture, so no additional remapping is needed.
                vMaskCoord = clamp(cameraCoord, 0.0, 1.0);
                // Raw (untransformed) quad texture coordinate, used by the
                // normal-mode mask sampling below.
                vRawTexCoord = aTextureCoord.xy;
            }
        """.trimIndent()
        val fragmentSrc = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTextureCoord;
            varying vec2 vMaskCoord;
            varying vec2 vRawTexCoord;
            uniform samplerExternalOES sCamera;
            uniform sampler2D uMask;
            // (1/maskWidth, 1/maskHeight) in mask UV space; drives the
            // one-mask-pixel erosion taps.
            uniform vec2 uMaskTexelSize;
            void main() {
                vec4 cameraColor = texture2D(sCamera, vTextureCoord);
                // Physical RND on SM-A566B showed the CPU MediaPipe mask
                // arrives in raw analysis UV with vertical orientation
                // inverted relative to the GLES rect, so the mask is sampled
                // here with Y flipped.
                //
                // X is intentionally NOT flipped here. AndroidDuetMediaPipeSegmentationBackend
                // (the segmentation backend feeding this compositor) mirrors its CPU input
                // horizontally before segmentation (matching the front-camera preview mirror
                // applied by cameraStMatrix), so the mask buffer itself already carries the
                // same X orientation this raw-quad sampling expects. Adding an X flip here on
                // top of that would cancel the upstream mirror fix and reintroduce the
                // wrong-side registration bug.
                vec2 maskUv = vec2(vRawTexCoord.x, 1.0 - vRawTexCoord.y);
                float centerAlpha = texture2D(uMask, maskUv).r;
                // Conservative GPU-side matte refinement: take the minimum of
                // the centre tap and its four direct neighbours (one mask
                // pixel away, clamped inside [0,1]). This erodes the matte by
                // one mask pixel so false-positive room background clinging
                // to the head/shoulder silhouette shrinks, while the true
                // person core (uniformly high confidence) is unaffected.
                float leftAlpha  = texture2D(uMask, clamp(maskUv - vec2(uMaskTexelSize.x, 0.0), 0.0, 1.0)).r;
                float rightAlpha = texture2D(uMask, clamp(maskUv + vec2(uMaskTexelSize.x, 0.0), 0.0, 1.0)).r;
                float upAlpha    = texture2D(uMask, clamp(maskUv - vec2(0.0, uMaskTexelSize.y), 0.0, 1.0)).r;
                float downAlpha  = texture2D(uMask, clamp(maskUv + vec2(0.0, uMaskTexelSize.y), 0.0, 1.0)).r;
                float erodedAlpha = min(centerAlpha, min(min(leftAlpha, rightAlpha), min(upAlpha, downAlpha)));
                // Shape the eroded MediaPipe selfie-segmentation confidence
                // with a slightly stricter feather than a raw sample, so
                // low-confidence background is rejected while true edge
                // pixels still feather smoothly.
                float maskAlpha = smoothstep(0.52, 0.78, erodedAlpha);
                gl_FragColor = vec4(cameraColor.rgb, cameraColor.a * maskAlpha);
            }
        """.trimIndent()
        val vs = compileShader(GLES20.GL_VERTEX_SHADER, vertexSrc)
        val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        val prog = GLES20.glCreateProgram()
        GLES20.glAttachShader(prog, vs)
        GLES20.glAttachShader(prog, fs)
        GLES20.glLinkProgram(prog)
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(prog)
            GLES20.glDeleteProgram(prog)
            throw IllegalStateException("GS program link failed: $log")
        }
        greenScreenProgram = prog
        gsAPositionLoc = GLES20.glGetAttribLocation(prog, "aPosition")
        gsATexCoordLoc = GLES20.glGetAttribLocation(prog, "aTextureCoord")
        gsUSTMatrixLoc = GLES20.glGetUniformLocation(prog, "uSTMatrix")
        gsSCameraLoc   = GLES20.glGetUniformLocation(prog, "sCamera")
        gsUMaskLoc     = GLES20.glGetUniformLocation(prog, "uMask")
        gsUMaskTexelSizeLoc = GLES20.glGetUniformLocation(prog, "uMaskTexelSize")
    }

    /**
     * Uploads [frame]'s mask buffer into [maskTextureId] as a LUMINANCE texture,
     * dispatching on [AndroidGreenScreenSegmentationFrame.format]:
     *   - FLOAT32_CONFIDENCE (ML Kit): float32 stride-4 -> byte pack (unchanged path).
     *   - UINT8_ALPHA (MediaPipe): stride-1 bytes uploaded as-is, never read as float.
     * Allocates the GL texture on first call. Must run on render thread.
     */
    private fun uploadMaskTexture(frame: AndroidGreenScreenSegmentationFrame) {
        val w = frame.width
        val h = frame.height
        if (w <= 0 || h <= 0) {
            Log.w(TAG, "uploadMaskTexture: invalid dimensions ${w}x$h, skipping")
            return
        }
        if (maskTextureId == 0) {
            val texIds = IntArray(1)
            GLES20.glGenTextures(1, texIds, 0)
            maskTextureId = texIds[0]
            if (maskTextureId == 0) {
                Log.w(TAG, "uploadMaskTexture: glGenTextures failed")
                return
            }
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTextureId)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        } else {
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTextureId)
        }
        // Dispatch on the frame's declared byte layout. The two layouts differ in
        // stride (4 vs 1) and must never be interpreted through each other's path.
        val byteBuffer: ByteBuffer = when (frame.format) {
            GreenScreenSegmentationMaskFormat.FLOAT32_CONFIDENCE -> {
                // ML Kit produces float32 confidence values in [0,1]. Upload as LUMINANCE.
                // ES 2.0 does not support GL_R32F natively; pack float → byte (0–255).
                // Use a read-only duplicate so we never mutate the frame buffer's position.
                val buf = frame.maskBytes.asReadOnlyBuffer()
                    .order(ByteOrder.nativeOrder())
                buf.rewind()
                val capacity = w * h
                val packed = ByteBuffer.allocateDirect(capacity)
                for (i in 0 until capacity) {
                    val byteOffset = i * 4
                    val f = if (buf.limit() >= byteOffset + 4) buf.getFloat(byteOffset) else 0f
                    packed.put((f.coerceIn(0f, 1f) * 255f).toInt().toByte())
                }
                packed.rewind()
                packed
            }
            GreenScreenSegmentationMaskFormat.UINT8_ALPHA -> {
                // MediaPipe rung: one byte per pixel already scaled to 0–255 on the
                // analysis thread. Upload through a read-only view bounded to exactly
                // w*h bytes — no float reinterpretation, no repack.
                val required = w * h
                val view = frame.maskBytes.asReadOnlyBuffer()
                view.rewind()
                if (view.capacity() < required) {
                    Log.w(TAG, "uploadMaskTexture: uint8 mask too small (${view.capacity()} < $required), skipping")
                    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
                    return
                }
                view.limit(required)
                view
            }
        }
        // GL_UNPACK_ALIGNMENT defaults to 4, which causes row misalignment for
        // single-channel (1 byte/pixel) mask rows whose width is not divisible by
        // 4.  Save the current alignment, force 1, upload, then restore — so we
        // don't leave a side-effect on the GL state machine.
        val prevAlignment = IntArray(1)
        GLES20.glGetIntegerv(GLES20.GL_UNPACK_ALIGNMENT, prevAlignment, 0)
        try {
            GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
            GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE,
                w, h, 0,
                GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, byteBuffer,
            )
        } finally {
            GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, prevAlignment[0])
        }
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        hasMaskTexture = true
        // Remember the uploaded dimensions so drawCameraGreenScreen can pass
        // the matching texel size to the erosion taps.
        latestMaskWidth = w
        latestMaskHeight = h
        if (!hasLoggedFirstMaskUpload) {
            hasLoggedFirstMaskUpload = true
            Log.i(
                TAG,
                "ANDROID_GREENSCREEN_PREVIEW_MASK_UPLOAD_FIRST width=$w height=$h " +
                    "format=${frame.format.key} backend=${frame.backend}",
            )
        } else if (lastUploadedMaskBackend != null && lastUploadedMaskBackend != frame.backend) {
            Log.i(
                TAG,
                "ANDROID_GREENSCREEN_PREVIEW_MASK_BACKEND_CHANGED from=$lastUploadedMaskBackend " +
                    "to=${frame.backend} format=${frame.format.key} width=$w height=$h",
            )
        }
        lastUploadedMaskBackend = frame.backend
    }

    /**
     * Draws the camera OES frame alpha-blended into [rect] using the current
     * mask texture. GL_BLEND is enabled around this draw only; the background
     * underneath shows through where mask alpha is low.
     *
     * Like [drawCameraRect], the viewport is aspect-filled (via
     * [cameraAspectFillViewport]) and the scissor crops the overflow back to
     * [rect]; camera passthrough and green-screen share the same aspect-fill
     * geometry so the two draws stay visually consistent.
     */
    private fun drawCameraGreenScreen(rect: AndroidGreenScreenPixelRect) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return
        val viewport = cameraAspectFillViewport(rect)

        ensureGreenScreenProgram()
        if (greenScreenProgram == 0) return  // compilation failed; skip silently

        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glViewport(viewport.x, viewport.y, viewport.width, viewport.height)

        // Enable blending so camera pixels with low mask alpha reveal the background below.
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)

        GLES20.glUseProgram(greenScreenProgram)

        // Mask texel size for the erosion taps. Falls back to (1,1) when
        // dimensions are not yet known (e.g. a draw racing ahead of the first
        // upload): neighbour taps then clamp to the texture edge, so the
        // shader degrades gracefully instead of reading garbage.
        val maskTexelW = if (latestMaskWidth > 0) 1f / latestMaskWidth else 1f
        val maskTexelH = if (latestMaskHeight > 0) 1f / latestMaskHeight else 1f
        GLES20.glUniform2f(gsUMaskTexelSizeLoc, maskTexelW, maskTexelH)

        // Texture unit 0: camera OES
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraOesTextureId)
        GLES20.glUniform1i(gsSCameraLoc, 0)
        GLES20.glUniformMatrix4fv(gsUSTMatrixLoc, 1, false, cameraStMatrix, 0)

        // Texture unit 1: mask (2D LUMINANCE)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTextureId)
        GLES20.glUniform1i(gsUMaskLoc, 1)

        quadPositions.position(0)
        GLES20.glEnableVertexAttribArray(gsAPositionLoc)
        GLES20.glVertexAttribPointer(gsAPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadPositions)
        quadTexCoords.position(0)
        GLES20.glEnableVertexAttribArray(gsATexCoordLoc)
        GLES20.glVertexAttribPointer(gsATexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(gsAPositionLoc)
        GLES20.glDisableVertexAttribArray(gsATexCoordLoc)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)

        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    // -- Green-screen static background draws -----------------------------------

    /**
     * Draws the background layer beneath the masked camera in green-screen
     * mode, dispatching on [greenScreenBackground]'s type. [VIDEO] plays a
     * looping local video file via [AndroidGreenScreenVideoBackgroundDecoder]
     * (Slice 2); [SOLID_COLOR] and [IMAGE] are unchanged from before.
     * Switching away from a type always releases that type's resources so
     * nothing leaks or keeps decoding in the background unobserved.
     */
    private fun drawGreenScreenBackground(rect: AndroidGreenScreenPixelRect) {
        when (greenScreenBackground.type) {
            AndroidGreenScreenBackgroundType.VIDEO -> {
                releaseBackgroundImageTextureQuietly()
                ensureBackgroundVideoProvider(greenScreenBackground)
                if (hasBackgroundVideoTexImage) {
                    drawVideoBackground(rect)
                } else {
                    // No frame decoded yet (startup latency) or setup/decode
                    // failed: opaque black fallback, matching the IMAGE
                    // precedent. A previously-showing background is only ever
                    // torn down once a NEW background spec is accepted (see
                    // ensureBackgroundVideoProvider / releaseBackgroundVideoQuietly),
                    // so this path is never reached while a prior background
                    // was already on screen for the *same* spec.
                    drawSolidColorBackground(rect, AndroidGreenScreenBackground.VIDEO.argbColor)
                }
            }
            AndroidGreenScreenBackgroundType.SOLID_COLOR -> {
                releaseBackgroundImageTextureQuietly()
                releaseBackgroundVideoQuietly()
                drawSolidColorBackground(rect, greenScreenBackground.argbColor)
            }
            AndroidGreenScreenBackgroundType.IMAGE -> {
                releaseBackgroundVideoQuietly()
                ensureBackgroundImageTexture(greenScreenBackground)
                if (backgroundImageTextureId != 0) {
                    drawImageBackground(rect)
                } else {
                    // Missing path or decode failure: opaque black fallback.
                    drawSolidColorBackground(rect, AndroidGreenScreenBackground.VIDEO.argbColor)
                }
            }
        }
    }

    /** Solid ARGB scissor-clear of [rect]. Used for [SOLID_COLOR] and as the IMAGE fallback. */
    private fun drawSolidColorBackground(rect: AndroidGreenScreenPixelRect, argbColor: Int) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return
        val a = ((argbColor ushr 24) and 0xFF) / 255f
        val r = ((argbColor ushr 16) and 0xFF) / 255f
        val g = ((argbColor ushr 8) and 0xFF) / 255f
        val b = (argbColor and 0xFF) / 255f
        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glClearColor(r, g, b, a)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    /**
     * Lazily (re)loads [bg]'s image file into [backgroundImageTextureId].
     * No-ops once a texture matching [bg]'s filePath is already loaded, or
     * once decode/upload has already failed for that path (never retries
     * every frame). Releases a stale texture from a previous path first.
     * Must run on the render thread with the EGL context current (called
     * from inside [drawFrame]).
     */
    private fun ensureBackgroundImageTexture(bg: AndroidGreenScreenBackground) {
        if (backgroundImageTextureId != 0 && backgroundImageLoadedPath == bg.filePath) return
        if (backgroundImageLoadedPath != bg.filePath) {
            releaseBackgroundImageTextureQuietly()
            // A prior failure was scoped to the old path; a new path deserves
            // its own decode attempt rather than inheriting that failure.
            backgroundImageDecodeFailed = false
        }
        backgroundImageLoadedPath = bg.filePath
        if (backgroundImageDecodeFailed) return

        val path = bg.filePath
        if (path == null) {
            backgroundImageDecodeFailed = true
            Log.w(TAG, "ANDROID_GREENSCREEN_PREVIEW_BACKGROUND_IMAGE_FALLBACK reason=missing_path path=")
            return
        }
        val bitmap = try {
            android.graphics.BitmapFactory.decodeFile(path)
        } catch (t: Throwable) {
            null
        }
        if (bitmap == null) {
            backgroundImageDecodeFailed = true
            Log.w(TAG, "ANDROID_GREENSCREEN_PREVIEW_BACKGROUND_IMAGE_FALLBACK reason=decode_failed path=$path")
            return
        }
        try {
            val texIds = IntArray(1)
            GLES20.glGenTextures(1, texIds, 0)
            val texId = texIds[0]
            if (texId == 0) {
                backgroundImageDecodeFailed = true
                Log.w(TAG, "ANDROID_GREENSCREEN_PREVIEW_BACKGROUND_IMAGE_FALLBACK reason=texture_alloc_failed path=$path")
                return
            }
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texId)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            android.opengl.GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
            backgroundImageTextureId = texId
            backgroundImageWidthPx = bitmap.width
            backgroundImageHeightPx = bitmap.height
            backgroundImageDecodeFailed = false
        } finally {
            bitmap.recycle()
        }
    }

    /**
     * Releases the current background image texture and its cached path/failure
     * state (idempotent). Clearing [backgroundImageLoadedPath] and
     * [backgroundImageDecodeFailed] here ensures switching away to VIDEO/SOLID_COLOR
     * never leaves stale state that would block a later reload of the same path.
     * Render-thread only.
     */
    private fun releaseBackgroundImageTextureQuietly() {
        if (backgroundImageTextureId != 0) {
            try { GLES20.glDeleteTextures(1, intArrayOf(backgroundImageTextureId), 0) } catch (_: Throwable) {}
        }
        backgroundImageTextureId = 0
        backgroundImageWidthPx = 0
        backgroundImageHeightPx = 0
        backgroundImageLoadedPath = null
        backgroundImageDecodeFailed = false
    }

    /**
     * Draws [backgroundImageTextureId] into [rect] using [greenScreenBackground]'s
     * scale mode. Letterbox/pillarbox area (aspectFit) is cleared to black first.
     */
    private fun drawImageBackground(rect: AndroidGreenScreenPixelRect) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return
        ensureBackgroundImageProgram()
        if (backgroundImageProgram == 0) {
            drawSolidColorBackground(rect, AndroidGreenScreenBackground.VIDEO.argbColor)
            return
        }

        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        val viewport = backgroundImageAspectViewport(rect)
        GLES20.glViewport(viewport.x, viewport.y, viewport.width, viewport.height)

        GLES20.glUseProgram(backgroundImageProgram)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, backgroundImageTextureId)
        GLES20.glUniform1i(bgImageSTextureLoc, 0)

        quadPositions.position(0)
        GLES20.glEnableVertexAttribArray(bgImageAPositionLoc)
        GLES20.glVertexAttribPointer(bgImageAPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadPositions)
        quadTexCoords.position(0)
        GLES20.glEnableVertexAttribArray(bgImageATexCoordLoc)
        GLES20.glVertexAttribPointer(bgImageATexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(bgImageAPositionLoc)
        GLES20.glDisableVertexAttribArray(bgImageATexCoordLoc)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    /**
     * Viewport for the background image inside [rect], per [greenScreenBackground]'s
     * scale mode: aspectFill (cover, overflow cropped by the scissor already set)
     * or aspectFit (contain, remaining area stays the black clear from [drawImageBackground]).
     * Unknown image size degrades to the rect itself (stretch).
     */
    private fun backgroundImageAspectViewport(rect: AndroidGreenScreenPixelRect): GlRect {
        val rectW = rect.width
        val rectH = rect.height
        if (backgroundImageWidthPx <= 0 || backgroundImageHeightPx <= 0 || rectW <= 0.0 || rectH <= 0.0) {
            return toGlRect(rect.left, rect.top, rectW, rectH)
        }
        val imageAspect = backgroundImageWidthPx.toDouble() / backgroundImageHeightPx.toDouble()
        val rectAspect = rectW / rectH
        val cover = greenScreenBackground.scaleMode != AndroidGreenScreenBackgroundScaleMode.ASPECT_FIT
        val matchHeightBasis = if (cover) imageAspect > rectAspect else imageAspect <= rectAspect
        val drawnW: Double
        val drawnH: Double
        if (matchHeightBasis) {
            drawnH = rectH
            drawnW = rectH * imageAspect
        } else {
            drawnW = rectW
            drawnH = rectW / imageAspect
        }
        return toGlRect(
            rect.left - (drawnW - rectW) / 2.0,
            rect.top - (drawnH - rectH) / 2.0,
            drawnW,
            drawnH,
        )
    }

    // -- Green-screen static background: VIDEO draws (Slice 2) -----------------

    /**
     * Lazily (re)starts a looping [AndroidGreenScreenVideoBackgroundDecoder]
     * for [bg]'s file path. No-ops once a decoder matching [bg]'s filePath is
     * already active, or once setup has already failed for that path (never
     * retries every frame). Releases the previous video provider first when
     * the path actually changes. Must run on the render thread with the EGL
     * context current (GL texture allocation). Non-blocking: decoding itself
     * always happens on the decoder's own thread.
     */
    private fun ensureBackgroundVideoProvider(bg: AndroidGreenScreenBackground) {
        if (backgroundVideoLoadedPath == bg.filePath &&
            (backgroundVideoDecoder != null || backgroundVideoDecodeFailed)
        ) {
            return
        }
        releaseBackgroundVideoQuietly()
        backgroundVideoLoadedPath = bg.filePath

        val path = bg.filePath
        if (path == null) {
            backgroundVideoDecodeFailed = true
            Log.w(TAG, "ANDROID_GREENSCREEN_PREVIEW_BACKGROUND_VIDEO_FALLBACK reason=missing_path path=")
            return
        }

        try {
            setupBackgroundVideoIngest()
        } catch (t: Throwable) {
            backgroundVideoDecodeFailed = true
            Log.w(TAG, "ANDROID_GREENSCREEN_PREVIEW_BACKGROUND_VIDEO_FALLBACK reason=texture_setup_failed path=$path error=${t.message}")
            return
        }
        val surface = backgroundVideoSurface
        val texture = backgroundVideoSurfaceTexture
        if (surface == null || texture == null) {
            backgroundVideoDecodeFailed = true
            return
        }

        backgroundVideoDecoder = AndroidGreenScreenVideoBackgroundDecoder(
            filePath = path,
            outputSurface = surface,
            outputSurfaceTexture = texture,
            onFormatKnown = { w, h, rotation ->
                backgroundVideoWidthPx = w
                backgroundVideoHeightPx = h
                backgroundVideoRotationDegrees = rotation
            },
            onFatalError = { message ->
                Log.w(TAG, "ANDROID_GREENSCREEN_PREVIEW_BACKGROUND_VIDEO_DECODE_FAILED path=$path error=$message")
            },
        ).also { it.start() }
    }

    /**
     * Allocates a fresh OES texture + SurfaceTexture + Surface for the
     * background video decoder's exclusive use. Unlike [setupCameraIngest],
     * no default buffer size is set: MediaCodec negotiates the ANativeWindow
     * buffer geometry itself from the decoder's own output format once
     * configured. Must run on the render thread with the EGL context current.
     *
     * Exception-safe: builds the GL texture / SurfaceTexture / Surface as
     * locals and only publishes them to the
     * [backgroundVideoOesTextureId]/[backgroundVideoSurfaceTexture]/[backgroundVideoSurface]
     * fields once all three succeed together. If any step throws (most
     * notably [Surface]'s constructor, after the GL texture and
     * SurfaceTexture already exist), every local created so far is released
     * immediately before rethrowing — no decoder has been constructed yet at
     * that point, so nothing else will ever own/release them, unlike the
     * normal [releaseBackgroundVideoQuietly] teardown model this must not
     * disturb. Cleanup here is synchronous GL/SurfaceTexture/Surface teardown
     * only — no thread posts, no blocking waits.
     */
    private fun setupBackgroundVideoIngest() {
        var texId = 0
        var texture: SurfaceTexture? = null
        var surface: Surface? = null
        try {
            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            texId = textures[0]
            if (texId == 0) throw IllegalStateException("glGenTextures failed for background video OES texture")
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

            texture = SurfaceTexture(texId)
            texture.setOnFrameAvailableListener { backgroundVideoFramePending.set(true) }
            surface = Surface(texture)

            backgroundVideoOesTextureId = texId
            backgroundVideoSurfaceTexture = texture
            backgroundVideoSurface = surface
        } catch (t: Throwable) {
            try { surface?.release() } catch (_: Throwable) {}
            try { texture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
            try { texture?.release() } catch (_: Throwable) {}
            if (texId != 0) {
                try { GLES20.glDeleteTextures(1, intArrayOf(texId), 0) } catch (_: Throwable) {}
            }
            throw t
        }
    }

    /**
     * Releases the current background video decoder/texture (idempotent,
     * non-blocking). Deletes the GL texture id immediately (render-thread,
     * EGL context must be current) and drops the Surface/SurfaceTexture
     * references, but does not release those two objects itself — the
     * decoder ([AndroidGreenScreenVideoBackgroundDecoder.release]) owns and
     * releases them asynchronously, on its own thread, once its codec has
     * guaranteed no further writes. This is what keeps a mid-session
     * background switch from ever blocking render loop pacing.
     */
    private fun releaseBackgroundVideoQuietly() {
        hasBackgroundVideoTexImage = false
        backgroundVideoFramePending.set(false)
        try { backgroundVideoDecoder?.release() } catch (_: Throwable) {}
        backgroundVideoDecoder = null
        try { backgroundVideoSurfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
        if (backgroundVideoOesTextureId != 0) {
            try { GLES20.glDeleteTextures(1, intArrayOf(backgroundVideoOesTextureId), 0) } catch (_: Throwable) {}
        }
        backgroundVideoOesTextureId = 0
        backgroundVideoSurface = null
        backgroundVideoSurfaceTexture = null
        backgroundVideoLoadedPath = null
        backgroundVideoDecodeFailed = false
        backgroundVideoWidthPx = 0
        backgroundVideoHeightPx = 0
        backgroundVideoRotationDegrees = 0
    }

    /**
     * Draws the latched background video OES frame into [rect] using
     * [backgroundVideoAspectViewport] for placement and the plain OES
     * program/[backgroundVideoStMatrix] for sampling — the same shader
     * [drawCameraRect] uses for the camera layer, just a different texture/ST
     * matrix. Letterbox/pillarbox area (aspectFit) is cleared to black first,
     * matching [drawImageBackground].
     */
    private fun drawVideoBackground(rect: AndroidGreenScreenPixelRect) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return

        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        val viewport = backgroundVideoAspectViewport(rect)
        GLES20.glViewport(viewport.x, viewport.y, viewport.width, viewport.height)

        GLES20.glUseProgram(oesProgram)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, backgroundVideoOesTextureId)
        GLES20.glUniform1i(sTextureLoc, 0)
        GLES20.glUniformMatrix4fv(uSTMatrixLoc, 1, false, backgroundVideoStMatrix, 0)

        quadPositions.position(0)
        GLES20.glEnableVertexAttribArray(aPositionLoc)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadPositions)
        quadTexCoords.position(0)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPositionLoc)
        GLES20.glDisableVertexAttribArray(aTexCoordLoc)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    /**
     * Viewport for the background video inside [rect], per
     * [greenScreenBackground]'s scale mode: aspectFill (cover) or aspectFit
     * (contain) — identical policy to [backgroundImageAspectViewport]. For a
     * 90/270-degree [backgroundVideoRotationDegrees] the raw decoded
     * width/height are swapped first so the aspect used here matches the
     * upright display orientation rather than the sideways decode buffer,
     * mirroring duet/AndroidDuetPreviewCompositor's aspectFillViewport.
     * Unknown video size degrades to the rect itself (stretch).
     */
    private fun backgroundVideoAspectViewport(rect: AndroidGreenScreenPixelRect): GlRect {
        val rectW = rect.width
        val rectH = rect.height
        if (backgroundVideoWidthPx <= 0 || backgroundVideoHeightPx <= 0 || rectW <= 0.0 || rectH <= 0.0) {
            return toGlRect(rect.left, rect.top, rectW, rectH)
        }
        val displayWidthPx: Int
        val displayHeightPx: Int
        if (backgroundVideoRotationDegrees == 90 || backgroundVideoRotationDegrees == 270) {
            displayWidthPx = backgroundVideoHeightPx
            displayHeightPx = backgroundVideoWidthPx
        } else {
            displayWidthPx = backgroundVideoWidthPx
            displayHeightPx = backgroundVideoHeightPx
        }
        val videoAspect = displayWidthPx.toDouble() / displayHeightPx.toDouble()
        val rectAspect = rectW / rectH
        val cover = greenScreenBackground.scaleMode != AndroidGreenScreenBackgroundScaleMode.ASPECT_FIT
        val matchHeightBasis = if (cover) videoAspect > rectAspect else videoAspect <= rectAspect
        val drawnW: Double
        val drawnH: Double
        if (matchHeightBasis) {
            drawnH = rectH
            drawnW = rectH * videoAspect
        } else {
            drawnW = rectW
            drawnH = rectW / videoAspect
        }
        return toGlRect(
            rect.left - (drawnW - rectW) / 2.0,
            rect.top - (drawnH - rectH) / 2.0,
            drawnW,
            drawnH,
        )
    }

    /** Lazily compiles the plain 2D-texture shader used to draw a static image background. */
    private fun ensureBackgroundImageProgram() {
        if (backgroundImageProgram != 0) return
        val vertexSrc = """
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            varying vec2 vTextureCoord;
            void main() {
                gl_Position = aPosition;
                // Flip V: glTexImage2D uploads Bitmap row 0 (the image's top
                // row) first, which OpenGL treats as v=0. Without this flip
                // the image would be drawn upside down.
                vTextureCoord = vec2(aTextureCoord.x, 1.0 - aTextureCoord.y);
            }
        """.trimIndent()
        val fragmentSrc = """
            precision mediump float;
            varying vec2 vTextureCoord;
            uniform sampler2D sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, vTextureCoord);
            }
        """.trimIndent()
        val vs = compileShader(GLES20.GL_VERTEX_SHADER, vertexSrc)
        val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        val prog = GLES20.glCreateProgram()
        GLES20.glAttachShader(prog, vs)
        GLES20.glAttachShader(prog, fs)
        GLES20.glLinkProgram(prog)
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(prog)
            GLES20.glDeleteProgram(prog)
            Log.w(TAG, "background image GL program link failed: $log")
            return
        }
        backgroundImageProgram = prog
        bgImageAPositionLoc = GLES20.glGetAttribLocation(prog, "aPosition")
        bgImageATexCoordLoc = GLES20.glGetAttribLocation(prog, "aTextureCoord")
        bgImageSTextureLoc = GLES20.glGetUniformLocation(prog, "sTexture")
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, src)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            throw IllegalStateException("GL shader compile failed: $log")
        }
        return shader
    }

    // -- Rect draws ------------------------------------------------------------

    /** Solid fill fallback over the camera rect when no live camera frame has arrived yet. */
    private fun drawCameraPlaceholder(rect: AndroidGreenScreenPixelRect) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return
        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glClearColor(CAMERA_PLACEHOLDER_R, CAMERA_PLACEHOLDER_G, CAMERA_PLACEHOLDER_B, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    /**
     * Draws the latched camera OES frame into [rect] (green-screen disabled
     * passthrough). Reuses the plain OES shader program bound to
     * [cameraOesTextureId] / [cameraStMatrix].
     *
     * Like [drawCameraGreenScreen], the viewport is aspect-filled (via
     * [cameraAspectFillViewport]) and the scissor crops the overflow back to
     * [rect]; camera passthrough and green-screen share this same geometry.
     * [cameraStMatrix] separately supplies the texture-coordinate transform
     * for reading the OES buffer (rotation/crop/mirror baked in by CameraX);
     * it does not perform aspect-fill itself.
     */
    private fun drawCameraRect(rect: AndroidGreenScreenPixelRect) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return
        val viewport = cameraAspectFillViewport(rect)

        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glViewport(viewport.x, viewport.y, viewport.width, viewport.height)

        GLES20.glUseProgram(oesProgram)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraOesTextureId)
        GLES20.glUniform1i(sTextureLoc, 0)
        GLES20.glUniformMatrix4fv(uSTMatrixLoc, 1, false, cameraStMatrix, 0)

        quadPositions.position(0)
        GLES20.glEnableVertexAttribArray(aPositionLoc)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadPositions)
        quadTexCoords.position(0)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPositionLoc)
        GLES20.glDisableVertexAttribArray(aTexCoordLoc)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    // -- Geometry --------------------------------------------------------------

    private data class GlRect(val x: Int, val y: Int, val width: Int, val height: Int)

    /**
     * Canvas rect (top-left origin, like AndroidGreenScreenPixelRect) to GLES
     * viewport/scissor rect (bottom-left origin): glY = surfaceH - (top + h).
     */
    private fun toGlRect(left: Double, top: Double, width: Double, height: Double): GlRect {
        val w = width.roundToInt()
        val h = height.roundToInt()
        return GlRect(
            x = left.roundToInt(),
            y = outputHeightPx - (top.roundToInt() + h),
            width = w,
            height = h,
        )
    }

    /**
     * Viewport for an aspect-fill of the upright camera image into [rect]: same
     * centre, inflated along one axis to [CAMERA_UPRIGHT_ASPECT]. Uses the
     * fixed camera buffer aspect since there is no per-frame decoder video
     * size in this single-camera compositor.
     */
    private fun cameraAspectFillViewport(rect: AndroidGreenScreenPixelRect): GlRect {
        val rectW = rect.width
        val rectH = rect.height
        if (rectW <= 0.0 || rectH <= 0.0) {
            return toGlRect(rect.left, rect.top, rectW, rectH)
        }
        val cameraAspect = CAMERA_UPRIGHT_ASPECT
        val rectAspect = rectW / rectH
        val drawnW: Double
        val drawnH: Double
        if (cameraAspect > rectAspect) {
            drawnH = rectH
            drawnW = rectH * cameraAspect
        } else {
            drawnW = rectW
            drawnH = rectW / cameraAspect
        }
        return toGlRect(
            rect.left - (drawnW - rectW) / 2.0,
            rect.top - (drawnH - rectH) / 2.0,
            drawnW,
            drawnH,
        )
    }

    private fun fullSurfaceRect() =
        AndroidGreenScreenPixelRect(0.0, 0.0, outputWidthPx.toDouble(), outputHeightPx.toDouble())

    // -- Quiet EGL helpers -----------------------------------------------------

    /** Rebinds [surface] (or nothing) as current, swallowing every EGL error. */
    private fun makeCurrentQuietly(surface: EGLSurface) {
        if (eglDisplay == EGL14.EGL_NO_DISPLAY || eglContext == EGL14.EGL_NO_CONTEXT) return
        try {
            if (surface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglMakeCurrent(eglDisplay, surface, surface, eglContext)
            } else {
                EGL14.eglMakeCurrent(
                    eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
                )
            }
        } catch (_: Throwable) {}
    }

    /**
     * Destroys only the EGL window surface (never the borrowed Surface behind
     * it), falling back to the pbuffer so the context stays current. Tolerates
     * every teardown error; the Android surface may already be dead.
     */
    private fun destroyWindowSurfaceQuietly() {
        val window = eglWindowSurface
        eglWindowSurface = EGL14.EGL_NO_SURFACE
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return
        makeCurrentQuietly(eglPbufferSurface)
        if (window != EGL14.EGL_NO_SURFACE) {
            try { EGL14.eglDestroySurface(eglDisplay, window) } catch (_: Throwable) {}
        }
    }

    /** Partial-bootstrap cleanup for a failed [ensureCore]; a later attach may retry. */
    private fun teardownCoreQuietly() {
        // Camera ingest cleanup.
        try { cameraSurfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
        try { _cameraInputSurface?.release() } catch (_: Throwable) {}
        _cameraInputSurface = null
        try { cameraSurfaceTexture?.release() } catch (_: Throwable) {}
        cameraSurfaceTexture = null
        cameraOesTextureId = 0
        oesProgram = 0
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            try {
                EGL14.eglMakeCurrent(
                    eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
                )
            } catch (_: Throwable) {}
            if (eglPbufferSurface != EGL14.EGL_NO_SURFACE) {
                try { EGL14.eglDestroySurface(eglDisplay, eglPbufferSurface) } catch (_: Throwable) {}
            }
            if (eglContext != EGL14.EGL_NO_CONTEXT) {
                try { EGL14.eglDestroyContext(eglDisplay, eglContext) } catch (_: Throwable) {}
            }
            try { EGL14.eglTerminate(eglDisplay) } catch (_: Throwable) {}
        }
        eglPbufferSurface = EGL14.EGL_NO_SURFACE
        eglContext = EGL14.EGL_NO_CONTEXT
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglConfig = null
        coreReady = false
    }

    private fun floatBufferOf(vararg values: Float): FloatBuffer =
        ByteBuffer.allocateDirect(values.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply {
                put(values)
                position(0)
            }
}
