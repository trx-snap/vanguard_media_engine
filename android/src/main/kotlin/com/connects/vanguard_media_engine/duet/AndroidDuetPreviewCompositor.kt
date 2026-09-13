package com.connects.vanguard_media_engine.duet

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
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
import kotlin.math.roundToInt

// -----------------------------------------------------------------------------
// VG-DUET-SLICE-4B-B: GLES compositor for the Duet preview texture (Android
// sibling of VGDuetPreviewCompositor.swift).
// -----------------------------------------------------------------------------
//
// Owns the EGL display/context and the decoder-facing SurfaceTexture ingest:
//   - An OES texture + SurfaceTexture + [decoderInputSurface] the source video
//     decoder renders into (handed to AndroidDuetSourceVideoDecoder via
//     rebindOutputSurface by the render loop, never created by the decoder).
//   - A borrowed output Surface (Flutter SurfaceProducer surface acquired via
//     AndroidDuetPreviewSurfaceProducer.acquireSurface()) wrapped in an EGL
//     window surface. The output Surface is NEVER released here; only the EGL
//     window surface wrapping it is destroyed on [detachOutputSurface].
//
// Lifetime split (the core reason this class exists as its own seam):
//   - Output loss (Flutter onSurfaceCleanup) destroys ONLY the EGL window
//     surface. The EGL context, OES texture, SurfaceTexture and
//     [decoderInputSurface] all survive, so the decoder stays bound and a
//     later re-attach resumes without rebuilding the codec.
//   - [release] is terminal: it tears down the SurfaceTexture ingest, the GL
//     objects and the whole EGL stack. Idempotent, never throws.
//
// A 1x1 pbuffer surface keeps the context current on the render thread while
// no output is attached, so texture setup/teardown and updateTexImage never
// depend on the (transient) window surface.
//
// Threading: render-thread-only. Every method (and property read) must run on
// the single render thread owned by AndroidDuetPreviewRenderLoop. The only
// cross-thread touch points are the SurfaceTexture frame-available callback
// (which may fire on any looper and therefore only sets [framePending]) and
// the decoder writing into [decoderInputSurface] on the decoder thread.

class AndroidDuetPreviewCompositor : AndroidDuetPreviewBackend {

    companion object {
        private const val TAG = "DuetPreviewComp"

        // Deterministic placeholder fill for the camera rect (no camera wired
        // in this slice): a fixed dark slate, identical every frame.
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
        // [cameraAspectFillViewport] instead of [aspectFillViewport]'s
        // decoder-video aspect, since the camera has no analogous
        // sourceVideoWidthPx/HeightPx of its own.
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

    // -- Decoder ingest (survives output loss, dies only in release) ----------

    private var oesTextureId = 0
    private var surfaceTexture: SurfaceTexture? = null

    @Volatile
    private var _decoderInputSurface: Surface? = null

    /**
     * Surface the source video decoder renders into (backed by this
     * compositor's SurfaceTexture). Owned by this compositor: stays alive
     * across output loss and is released exactly once in [release]. Null until
     * the first successful [attachOutputSurface].
     */
    override val decoderInputSurface: Surface? get() = _decoderInputSurface

    /** Set by the frame-available callback (any thread), consumed in [drawFrame]. */
    private val framePending = AtomicBoolean(false)

    /**
     * True when the decoder has queued at least one frame that [drawFrame] has
     * not yet consumed via updateTexImage. Lets the render loop wait (without
     * blocking) for an expected frame before presenting.
     */
    override val hasPendingSourceFrame: Boolean get() = framePending.get()

    /** True once updateTexImage has latched at least one real source frame. */
    private var hasTexImage = false

    private val stMatrix = FloatArray(16).also { Matrix.setIdentityM(it, 0) }

    // -- Camera ingest (independent of decoder; survives output loss, released only in release) --

    private var cameraOesTextureId = 0
    private var cameraSurfaceTexture: SurfaceTexture? = null

    @Volatile
    private var _cameraInputSurface: Surface? = null

    /**
     * Surface the camera (AndroidDuetCameraSource) renders into. Owned by
     * this compositor: allocated on first [attachOutputSurface], released once
     * in [release]. Null until the first successful [attachOutputSurface].
     */
    override val cameraInputSurface: Surface? get() = _cameraInputSurface

    /** Set by the camera frame-available callback (any thread), consumed in [drawFrame]. */
    private val cameraFramePending = AtomicBoolean(false)

    /** True when [drawFrame] has latched at least one real camera frame. */
    private var hasCameraTexImage = false

    /** True when a new camera frame is waiting to be consumed. */
    override val hasPendingCameraFrame: Boolean get() = cameraFramePending.get()

    private val cameraStMatrix = FloatArray(16).also { Matrix.setIdentityM(it, 0) }


    // -- Output / layout state -------------------------------------------------

    private var outputSurface: Surface? = null
    private var outputWidthPx = 0
    private var outputHeightPx = 0

    private var sourceRect: VGDuetPixelRect? = null
    private var cameraRect: VGDuetPixelRect? = null

    /** Source video dimensions used for aspect-fill; 0 means unknown (stretch). */
    private var sourceVideoWidthPx = 0
    private var sourceVideoHeightPx = 0

    private val isReleased = AtomicBoolean(false)

    // -- GL program state ------------------------------------------------------

    private var oesProgram = 0
    private var aPositionLoc = -1
    private var aTexCoordLoc = -1
    private var uSTMatrixLoc = -1
    private var sTextureLoc = -1

    // -- Green-screen GL state -------------------------------------------------

    /** True when the session is in green-screen layout mode. Render-thread only. */
    private var greenScreenEnabled = false

    /**
     * Pending mask data to upload on the next drawFrame. Delivered from the ML
     * Kit callback (off render thread) via [updateGreenScreenMask]; consumed on
     * the render thread inside drawFrame. Wrapped in AtomicReference so the
     * setter (any thread) and getter (render thread) don't race.
     */
    private val pendingMaskRef = java.util.concurrent.atomic.AtomicReference<AndroidDuetSegmentationFrame?>(null)

    /** GL texture ID for the single-channel mask (LUMINANCE). 0 = not yet allocated. */
    private var maskTextureId = 0

    /** GLES program: OES camera + 2D mask → alpha-blended draw. 0 = not yet compiled. */
    private var greenScreenProgram = 0
    private var gsAPositionLoc = -1
    private var gsATexCoordLoc = -1
    private var gsUSTMatrixLoc = -1
    private var gsSCameraLoc = -1
    private var gsUMaskLoc = -1
    private var gsUDebugViewLoc = -1
    private var gsUMaskTexelSizeLoc = -1

    /**
     * Debug-only (RND diagnostic): raw mask visualization mode. Render-thread
     * only, mutated exclusively via [setGreenScreenDebugView]. Null (the
     * default) means normal production compositing; any value other than
     * "mask_direct"/"mask_mapped"/"mask_direct_mirror_x"/"mask_direct_flip_y"/
     * "camera_passthrough" is treated as null by the setter.
     */
    private var greenScreenDebugView: String? = null

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
    private var greenScreenBackground: AndroidDuetGreenScreenBackground = AndroidDuetGreenScreenBackground.VIDEO

    /** GL texture id for a decoded [AndroidDuetGreenScreenBackgroundType.IMAGE] background. 0 = none loaded. */
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
     * current. First call also bootstraps the EGL core and the decoder ingest
     * (OES texture / SurfaceTexture / [decoderInputSurface]).
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
     * output Surface reference (never releasing it). The EGL context, OES
     * texture, SurfaceTexture and [decoderInputSurface] all stay alive so the
     * decoder remains bound for a later re-attach. Tolerates every EGL
     * teardown error; never throws. Idempotent.
     */
    override fun detachOutputSurface() {
        destroyWindowSurfaceQuietly()
        outputSurface = null
        outputWidthPx = 0
        outputHeightPx = 0
    }

    // -- Layout / video size ---------------------------------------------------

    /** Canvas-pixel rects (top-left origin) for the source video and camera placeholder. */
    override fun setLayout(sourceRect: VGDuetPixelRect, cameraRect: VGDuetPixelRect) {
        this.sourceRect = sourceRect
        this.cameraRect = cameraRect
    }

    /**
     * Source video dimensions used for aspect-fill inside the source rect.
     * Read off the decoder (on the decoder thread) by the render loop and
     * forwarded here. Unknown (<= 0) falls back to a plain stretch fill.
     */
    override fun setSourceVideoSize(widthPx: Int, heightPx: Int) {
        sourceVideoWidthPx = widthPx
        sourceVideoHeightPx = heightPx
    }

    // -- Green-screen controls (render-thread only for enabled; AtomicRef for mask) --

    /**
     * Enable or disable green-screen compositing. Must be called on the render thread.
     * When disabled, the camera rect reverts to normal PiP/split drawing behaviour.
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
     * stale frames are dropped). ML Kit callback thread → render thread.
     */
    override fun updateGreenScreenMask(frame: AndroidDuetSegmentationFrame) {
        pendingMaskRef.set(frame)
    }

    /**
     * Debug-only (RND diagnostic): allowlists [view] to exactly "mask_direct",
     * "mask_mapped", "mask_direct_mirror_x", "mask_direct_flip_y" or
     * "camera_passthrough"; any other value (including null) disables the
     * visualization and restores normal production compositing.
     * "mask_direct_mirror_x" and "mask_direct_flip_y" let physical RND
     * identify front-camera mirror/flip mismatches by sampling the raw mask
     * with the X or Y raw texture coordinate inverted, respectively.
     * "camera_passthrough" shows the raw live camera feed (no mask, no
     * smoothstep) inside the green-screen camera rect, so physical RND can
     * confirm the OES camera path itself independent of segmentation. Must be
     * called on the render thread.
     */
    override fun setGreenScreenDebugView(view: String?) {
        greenScreenDebugView = when (view) {
            "mask_direct", "mask_mapped", "mask_direct_mirror_x", "mask_direct_flip_y",
            "camera_passthrough" -> view
            else -> null
        }
    }

    /**
     * Stores the new background spec; render-thread only (posted here by the
     * render loop). The actual image decode/texture (re)load is deferred to
     * [ensureBackgroundImageTexture] inside [drawFrame], mirroring how
     * [updateGreenScreenMask] defers its GL upload to [uploadMaskTexture] —
     * both need the EGL context current, which is only guaranteed there.
     */
    override fun setGreenScreenBackground(background: AndroidDuetGreenScreenBackground) {
        greenScreenBackground = background
    }


    /**
     * Composites one frame into the attached output surface:
     *   1. updateTexImage (only when the decoder queued a new frame),
     *   2. full clear to black,
     *   3. source OES texture aspect-filled into the source rect,
     *   4. deterministic placeholder fill over the camera rect,
     *   5. eglSwapBuffers.
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
        val texture = surfaceTexture ?: return false

        try {
            if (!EGL14.eglMakeCurrent(display, window, window, eglContext)) return false

            // Latch source decoder frame if one arrived since last draw.
            if (framePending.compareAndSet(true, false)) {
                texture.updateTexImage()
                texture.getTransformMatrix(stMatrix)
                hasTexImage = true
            }

            // Latch camera frame if one arrived since last draw.
            val camSt = cameraSurfaceTexture
            if (camSt != null && cameraFramePending.compareAndSet(true, false)) {
                camSt.updateTexImage()
                camSt.getTransformMatrix(cameraStMatrix)
                hasCameraTexImage = true
            }

            // Upload latest mask texture when green-screen is active.
            if (greenScreenEnabled) {
                val maskFrame = pendingMaskRef.getAndSet(null)
                if (maskFrame != null) {
                    uploadMaskTexture(maskFrame)
                }
            }

            GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
            GLES20.glViewport(0, 0, outputWidthPx, outputHeightPx)
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

            // Background: in green-screen mode, the background may be the
            // source video (default, unchanged behavior), a solid color, or a
            // static image — drawn before the masked camera. Every other
            // layout mode keeps the unconditional source-video draw.
            if (greenScreenEnabled) {
                drawGreenScreenBackground(sourceRect ?: fullSurfaceRect())
            } else if (hasTexImage) {
                drawSourceRect(sourceRect ?: fullSurfaceRect())
            }

            // Camera rect drawing:
            // - Green-screen mode: draw camera masked by the segmentation mask.
            //   If no camera frame has arrived yet or no mask texture is ready,
            //   leave the source video visible (do NOT draw an opaque placeholder).
            // - Normal mode: draw live OES frame when available, else placeholder.
            val cr = cameraRect
            if (cr != null) {
                if (greenScreenEnabled) {
                    // Green-screen: only draw when both camera OES and mask are ready.
                    // Source remains visible underneath (drawn above); no opaque fill.
                    if (hasCameraTexImage && hasMaskTexture) {
                        drawCameraGreenScreen(cr)
                    }
                    // else: source remains visible, invariant satisfied.
                } else {
                    if (hasCameraTexImage) {
                        drawCameraRect(cr)
                    } else {
                        drawCameraPlaceholder(cr)
                    }
                }
            }

            GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
            return EGL14.eglSwapBuffers(display, window)
        } catch (t: Throwable) {
            Log.w(TAG, "drawFrame failed: ${t.message}")
            return false
        }
    }


    // -- Release (terminal, idempotent, never throws) --------------------------

    /**
     * Terminal teardown: window surface, GL program/texture, SurfaceTexture,
     * [decoderInputSurface] (the one place it is ever released; the caller
     * must have unbound the decoder first via rebindOutputSurface(null, ..)),
     * then the EGL context/display. Tolerates every EGL/GL error.
     */
    override fun release() {
        if (!isReleased.compareAndSet(false, true)) return

        try { surfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
        try { cameraSurfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}

        destroyWindowSurfaceQuietly()
        outputSurface = null

        // GL object teardown needs the context current; pbuffer provides that.
        if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglContext != EGL14.EGL_NO_CONTEXT) {
            makeCurrentQuietly(eglPbufferSurface)
            try {
                if (oesProgram != 0) GLES20.glDeleteProgram(oesProgram)
            } catch (_: Throwable) {}
            try {
                if (oesTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(oesTextureId), 0)
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
        }
        oesProgram = 0
        oesTextureId = 0
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

        try { _decoderInputSurface?.release() } catch (_: Throwable) {}
        _decoderInputSurface = null
        try { surfaceTexture?.release() } catch (_: Throwable) {}
        surfaceTexture = null

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
        hasTexImage = false
        hasCameraTexImage = false
    }

    // -- EGL core bootstrap ----------------------------------------------------

    /**
     * One-time EGL + ingest bootstrap: display, ES2 context, 1x1 pbuffer, OES
     * program/texture, SurfaceTexture and [decoderInputSurface]. On failure
     * everything partial is torn down and a later attach may retry.
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
            setupDecoderIngest()
            setupCameraIngest()

            coreReady = true
            return true
        } catch (t: Throwable) {
            Log.w(TAG, "EGL core bootstrap threw: ${t.message}")
            teardownCoreQuietly()
            return false
        }
    }

    private fun setupDecoderIngest() {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        oesTextureId = textures[0]
        if (oesTextureId == 0) throw IllegalStateException("glGenTextures failed for OES texture")
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        val texture = SurfaceTexture(oesTextureId)
        // Callback may fire on any looper; it only flips the flag, and
        // updateTexImage happens exclusively on the render thread in drawFrame.
        texture.setOnFrameAvailableListener { framePending.set(true) }
        surfaceTexture = texture
        _decoderInputSurface = Surface(texture)
    }




    /**
     * Allocates the camera OES texture, SurfaceTexture and [cameraInputSurface]
     * independently of the decoder ingest. Must be called from [ensureCore] after
     * the GL context is current.
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
     * mask texture; alpha-blends the camera over the source based on mask.r.
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
                // Raw (untransformed) quad texture coordinate — debug-only,
                // used solely by the mask_direct diagnostic visualization.
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
            // one-mask-pixel erosion taps in normal (non-debug) mode only.
            uniform vec2 uMaskTexelSize;
            // Debug-only (RND diagnostic): 0 = normal, 1 = mask_direct,
            // 2 = mask_mapped, 3 = mask_direct_mirror_x, 4 = mask_direct_flip_y,
            // 5 = camera_passthrough.
            uniform int uDebugView;
            void main() {
                if (uDebugView == 5) {
                    // camera_passthrough: raw live camera feed, no mask, no
                    // smoothstep — drawCameraGreenScreen already scissors and
                    // viewports to the green-screen camera rect, so this only
                    // ever paints inside that rect.
                    vec4 cameraColorRaw = texture2D(sCamera, vTextureCoord);
                    gl_FragColor = vec4(cameraColorRaw.rgb, 1.0);
                    return;
                }
                if (uDebugView == 1) {
                    float rawMaskAlpha = texture2D(uMask, vRawTexCoord).r;
                    gl_FragColor = vec4(rawMaskAlpha, rawMaskAlpha, rawMaskAlpha, 1.0);
                    return;
                }
                if (uDebugView == 2) {
                    float rawMaskAlpha = texture2D(uMask, vMaskCoord).r;
                    gl_FragColor = vec4(rawMaskAlpha, rawMaskAlpha, rawMaskAlpha, 1.0);
                    return;
                }
                if (uDebugView == 3) {
                    // mask_direct_mirror_x: raw mask sampled with X inverted, to
                    // help RND spot a front-camera horizontal mirror mismatch.
                    float rawMaskAlpha = texture2D(uMask, vec2(1.0 - vRawTexCoord.x, vRawTexCoord.y)).r;
                    gl_FragColor = vec4(rawMaskAlpha, rawMaskAlpha, rawMaskAlpha, 1.0);
                    return;
                }
                if (uDebugView == 4) {
                    // mask_direct_flip_y: raw mask sampled with Y inverted, to
                    // help RND spot a front-camera vertical flip mismatch.
                    float rawMaskAlpha = texture2D(uMask, vec2(vRawTexCoord.x, 1.0 - vRawTexCoord.y)).r;
                    gl_FragColor = vec4(rawMaskAlpha, rawMaskAlpha, rawMaskAlpha, 1.0);
                    return;
                }
                vec4 cameraColor = texture2D(sCamera, vTextureCoord);
                // Physical RND on SM-A566B showed the CPU MediaPipe mask
                // arrives in raw analysis UV with vertical orientation
                // inverted relative to the GLES rect: mask_direct_flip_y was
                // the only debug candidate that placed the matte into the
                // foreground rect (mask_mapped produced a side-stripe
                // failure, mask_direct produced a top-heavy rectangle).
                // Normal mode therefore samples the raw mask with Y flipped;
                // vMaskCoord/mask_mapped remains diagnostic only.
                //
                // X is intentionally NOT flipped here. AndroidDuetMediaPipeSegmentationBackend
                // now mirrors its CPU input horizontally before segmentation (matching the
                // front-camera preview mirror applied by cameraStMatrix), so the mask buffer
                // itself already carries the same X orientation this raw-quad sampling
                // expects. Adding an X flip here on top of that would cancel the upstream
                // mirror fix and reintroduce the wrong-side registration bug.
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
                // with a slightly stricter feather than the raw sample used
                // previously (0.45..0.75), so low-confidence background is
                // rejected while true edge pixels still feather smoothly.
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
        gsUDebugViewLoc = GLES20.glGetUniformLocation(prog, "uDebugView")
        gsUMaskTexelSizeLoc = GLES20.glGetUniformLocation(prog, "uMaskTexelSize")
    }

    /**
     * Uploads [frame]'s mask buffer into [maskTextureId] as a LUMINANCE texture,
     * dispatching on [AndroidDuetSegmentationFrame.format]:
     *   - FLOAT32_CONFIDENCE (ML Kit): float32 stride-4 -> byte pack (unchanged path).
     *   - UINT8_ALPHA (MediaPipe): stride-1 bytes uploaded as-is, never read as float.
     * Allocates the GL texture on first call. Must run on render thread.
     */
    private fun uploadMaskTexture(frame: AndroidDuetSegmentationFrame) {
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
        val byteBuffer: java.nio.ByteBuffer = when (frame.format) {
            DuetSegmentationMaskFormat.FLOAT32_CONFIDENCE -> {
                // ML Kit produces float32 confidence values in [0,1]. Upload as LUMINANCE.
                // ES 2.0 does not support GL_R32F natively; pack float → byte (0–255).
                // Use a read-only duplicate so we never mutate the frame buffer's position.
                val buf = frame.maskBytes.asReadOnlyBuffer()
                    .order(java.nio.ByteOrder.nativeOrder())
                buf.rewind()
                val capacity = w * h
                val packed = java.nio.ByteBuffer.allocateDirect(capacity)
                for (i in 0 until capacity) {
                    val byteOffset = i * 4
                    val f = if (buf.limit() >= byteOffset + 4) buf.getFloat(byteOffset) else 0f
                    packed.put((f.coerceIn(0f, 1f) * 255f).toInt().toByte())
                }
                packed.rewind()
                packed
            }
            DuetSegmentationMaskFormat.UINT8_ALPHA -> {
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
                "ANDROID_DUET_GREENSCREEN_MASK_UPLOAD_FIRST width=$w height=$h " +
                    "format=${frame.format.key} backend=${frame.backend}",
            )
        } else if (lastUploadedMaskBackend != null && lastUploadedMaskBackend != frame.backend) {
            Log.i(
                TAG,
                "ANDROID_DUET_GREENSCREEN_MASK_BACKEND_CHANGED from=$lastUploadedMaskBackend " +
                    "to=${frame.backend} format=${frame.format.key} width=$w height=$h",
            )
        }
        lastUploadedMaskBackend = frame.backend
    }

    /**
     * Draws the camera OES frame alpha-blended into [rect] using the current
     * mask texture. GL_BLEND is enabled around this draw only; source video
     * underneath shows through where mask alpha is low (background).
     *
     * Like [drawCameraRect], the viewport is aspect-filled (via
     * [cameraAspectFillViewport]) and the scissor crops the overflow back to
     * [rect]; camera passthrough and green-screen share the same aspect-fill
     * geometry so the two draws stay visually consistent.
     */
    private fun drawCameraGreenScreen(rect: VGDuetPixelRect) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return
        val viewport = cameraAspectFillViewport(rect)

        ensureGreenScreenProgram()
        if (greenScreenProgram == 0) return  // compilation failed; skip silently

        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glViewport(viewport.x, viewport.y, viewport.width, viewport.height)

        // Enable blending so camera pixels with low mask alpha reveal the source below.
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)

        GLES20.glUseProgram(greenScreenProgram)

        // Debug-only (RND diagnostic): 0 = normal, 1 = mask_direct,
        // 2 = mask_mapped, 3 = mask_direct_mirror_x, 4 = mask_direct_flip_y,
        // 5 = camera_passthrough.
        val debugViewCode = when (greenScreenDebugView) {
            "mask_direct" -> 1
            "mask_mapped" -> 2
            "mask_direct_mirror_x" -> 3
            "mask_direct_flip_y" -> 4
            "camera_passthrough" -> 5
            else -> 0
        }
        GLES20.glUniform1i(gsUDebugViewLoc, debugViewCode)

        // Mask texel size for the normal-mode erosion taps. Falls back to
        // (1,1) when dimensions are not yet known (e.g. a draw racing ahead of
        // the first upload): neighbour taps then clamp to the texture edge, so
        // the shader degrades gracefully instead of reading garbage.
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
     * mode, dispatching on [greenScreenBackground]'s type. [VIDEO] preserves
     * the exact prior behavior (source drawn only once a real frame has
     * latched); [SOLID_COLOR] and [IMAGE] never touch the decoder.
     */
    private fun drawGreenScreenBackground(rect: VGDuetPixelRect) {
        when (greenScreenBackground.type) {
            AndroidDuetGreenScreenBackgroundType.VIDEO -> {
                releaseBackgroundImageTextureQuietly()
                if (hasTexImage) drawSourceRect(rect)
            }
            AndroidDuetGreenScreenBackgroundType.SOLID_COLOR -> {
                releaseBackgroundImageTextureQuietly()
                drawSolidColorBackground(rect, greenScreenBackground.argbColor)
            }
            AndroidDuetGreenScreenBackgroundType.IMAGE -> {
                ensureBackgroundImageTexture(greenScreenBackground)
                if (backgroundImageTextureId != 0) {
                    drawImageBackground(rect)
                } else {
                    // Missing path or decode failure: opaque black fallback.
                    drawSolidColorBackground(rect, AndroidDuetGreenScreenBackground.VIDEO.argbColor)
                }
            }
        }
    }

    /** Solid ARGB scissor-clear of [rect]. Used for [SOLID_COLOR] and as the IMAGE fallback. */
    private fun drawSolidColorBackground(rect: VGDuetPixelRect, argbColor: Int) {
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
    private fun ensureBackgroundImageTexture(bg: AndroidDuetGreenScreenBackground) {
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
            Log.w(TAG, "ANDROID_DUET_GREENSCREEN_BACKGROUND_IMAGE_FALLBACK reason=missing_path path=")
            return
        }
        val bitmap = try {
            android.graphics.BitmapFactory.decodeFile(path)
        } catch (t: Throwable) {
            null
        }
        if (bitmap == null) {
            backgroundImageDecodeFailed = true
            Log.w(TAG, "ANDROID_DUET_GREENSCREEN_BACKGROUND_IMAGE_FALLBACK reason=decode_failed path=$path")
            return
        }
        try {
            val texIds = IntArray(1)
            GLES20.glGenTextures(1, texIds, 0)
            val texId = texIds[0]
            if (texId == 0) {
                backgroundImageDecodeFailed = true
                Log.w(TAG, "ANDROID_DUET_GREENSCREEN_BACKGROUND_IMAGE_FALLBACK reason=texture_alloc_failed path=$path")
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
    private fun drawImageBackground(rect: VGDuetPixelRect) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return
        ensureBackgroundImageProgram()
        if (backgroundImageProgram == 0) {
            drawSolidColorBackground(rect, AndroidDuetGreenScreenBackground.VIDEO.argbColor)
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
    private fun backgroundImageAspectViewport(rect: VGDuetPixelRect): GlRect {
        val rectW = rect.width
        val rectH = rect.height
        if (backgroundImageWidthPx <= 0 || backgroundImageHeightPx <= 0 || rectW <= 0.0 || rectH <= 0.0) {
            return toGlRect(rect.left, rect.top, rectW, rectH)
        }
        val imageAspect = backgroundImageWidthPx.toDouble() / backgroundImageHeightPx.toDouble()
        val rectAspect = rectW / rectH
        val cover = greenScreenBackground.scaleMode != AndroidDuetBackgroundScaleMode.ASPECT_FIT
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

    /**
     * Draws the latched OES frame aspect-filled into [rect]: the viewport is
     * inflated to the video's aspect ratio (centred over the rect) and the
     * scissor crops the overflow back to the rect.
     */
    private fun drawSourceRect(rect: VGDuetPixelRect) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return
        val viewport = aspectFillViewport(rect)

        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glViewport(viewport.x, viewport.y, viewport.width, viewport.height)

        GLES20.glUseProgram(oesProgram)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES20.glUniform1i(sTextureLoc, 0)
        GLES20.glUniformMatrix4fv(uSTMatrixLoc, 1, false, stMatrix, 0)

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

    /** Solid fill fallback over the camera rect when no live camera frame has arrived yet. */
    private fun drawCameraPlaceholder(rect: VGDuetPixelRect) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return
        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glClearColor(CAMERA_PLACEHOLDER_R, CAMERA_PLACEHOLDER_G, CAMERA_PLACEHOLDER_B, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    /**
     * Draws the latched camera OES frame into [rect], mirroring the structure
     * of [drawSourceRect] but binding [cameraOesTextureId] and [cameraStMatrix].
     * Reuses the same OES shader program; camera and decoder are independent
     * GL textures and transform matrices.
     *
     * Like [drawSourceRect], the viewport is aspect-filled (via
     * [cameraAspectFillViewport]) and the scissor crops the overflow back to
     * [rect]; camera passthrough and [drawCameraGreenScreen] share this same
     * geometry. [cameraStMatrix] separately supplies the texture-coordinate
     * transform for reading the OES buffer (rotation/crop/mirror baked in by
     * CameraX); it does not perform aspect-fill itself.
     */
    private fun drawCameraRect(rect: VGDuetPixelRect) {
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
     * Canvas rect (top-left origin, like VGDuetPixelRect) to GLES
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
     * Viewport for an aspect-fill of the source video into [rect]: same centre,
     * inflated along one axis to the video's aspect ratio. Unknown video size
     * degrades to the rect itself (stretch).
     */
    private fun aspectFillViewport(rect: VGDuetPixelRect): GlRect {
        val rectW = rect.width
        val rectH = rect.height
        if (sourceVideoWidthPx <= 0 || sourceVideoHeightPx <= 0 || rectW <= 0.0 || rectH <= 0.0) {
            return toGlRect(rect.left, rect.top, rectW, rectH)
        }
        val videoAspect = sourceVideoWidthPx.toDouble() / sourceVideoHeightPx.toDouble()
        val rectAspect = rectW / rectH
        val drawnW: Double
        val drawnH: Double
        if (videoAspect > rectAspect) {
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

    /**
     * Viewport for an aspect-fill of the upright camera image into [rect]: same
     * centre, inflated along one axis to [CAMERA_UPRIGHT_ASPECT]. Mirrors
     * [aspectFillViewport]'s centred-inflate logic but uses the fixed camera
     * buffer aspect instead of a per-frame decoder video size, since the camera
     * SurfaceTexture's negotiated size is not tracked per-frame the way
     * [sourceVideoWidthPx]/[sourceVideoHeightPx] are for the decoder.
     */
    private fun cameraAspectFillViewport(rect: VGDuetPixelRect): GlRect {
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
        VGDuetPixelRect(0.0, 0.0, outputWidthPx.toDouble(), outputHeightPx.toDouble())

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
        try { surfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
        try { _decoderInputSurface?.release() } catch (_: Throwable) {}
        _decoderInputSurface = null
        try { surfaceTexture?.release() } catch (_: Throwable) {}
        surfaceTexture = null
        oesTextureId = 0
        oesProgram = 0
        // Camera ingest cleanup.
        try { cameraSurfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
        try { _cameraInputSurface?.release() } catch (_: Throwable) {}
        _cameraInputSurface = null
        try { cameraSurfaceTexture?.release() } catch (_: Throwable) {}
        cameraSurfaceTexture = null
        cameraOesTextureId = 0
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
