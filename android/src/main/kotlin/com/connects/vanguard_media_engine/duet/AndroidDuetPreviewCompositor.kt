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

class AndroidDuetPreviewCompositor {

    companion object {
        private const val TAG = "DuetPreviewComp"

        // Deterministic placeholder fill for the camera rect (no camera wired
        // in this slice): a fixed dark slate, identical every frame.
        private const val CAMERA_PLACEHOLDER_R = 0.13f
        private const val CAMERA_PLACEHOLDER_G = 0.14f
        private const val CAMERA_PLACEHOLDER_B = 0.17f

        // Deterministic portrait preview buffer size for the camera SurfaceTexture.
        // CameraX negotiates a real resolution for its Preview use-case, but the
        // SurfaceTexture needs a non-zero default buffer size up front so it can
        // export a valid EGLImage from the first onFrameAvailable call. Without this
        // the first updateTexImage may silently produce a zero-size image.
        // This is a preview-ingress default only; no recording/export claim.
        private const val CAMERA_ST_DEFAULT_WIDTH  = 1080
        private const val CAMERA_ST_DEFAULT_HEIGHT = 1920
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
    val decoderInputSurface: Surface? get() = _decoderInputSurface

    /** Set by the frame-available callback (any thread), consumed in [drawFrame]. */
    private val framePending = AtomicBoolean(false)

    /**
     * True when the decoder has queued at least one frame that [drawFrame] has
     * not yet consumed via updateTexImage. Lets the render loop wait (without
     * blocking) for an expected frame before presenting.
     */
    val hasPendingSourceFrame: Boolean get() = framePending.get()

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
    val cameraInputSurface: Surface? get() = _cameraInputSurface

    /** Set by the camera frame-available callback (any thread), consumed in [drawFrame]. */
    private val cameraFramePending = AtomicBoolean(false)

    /** True when [drawFrame] has latched at least one real camera frame. */
    private var hasCameraTexImage = false

    /** True when a new camera frame is waiting to be consumed. */
    val hasPendingCameraFrame: Boolean get() = cameraFramePending.get()

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
    fun attachOutputSurface(surface: Surface, widthPx: Int, heightPx: Int): Boolean {
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
    fun detachOutputSurface() {
        destroyWindowSurfaceQuietly()
        outputSurface = null
        outputWidthPx = 0
        outputHeightPx = 0
    }

    // -- Layout / video size ---------------------------------------------------

    /** Canvas-pixel rects (top-left origin) for the source video and camera placeholder. */
    fun setLayout(sourceRect: VGDuetPixelRect, cameraRect: VGDuetPixelRect) {
        this.sourceRect = sourceRect
        this.cameraRect = cameraRect
    }

    /**
     * Source video dimensions used for aspect-fill inside the source rect.
     * Read off the decoder (on the decoder thread) by the render loop and
     * forwarded here. Unknown (<= 0) falls back to a plain stretch fill.
     */
    fun setSourceVideoSize(widthPx: Int, heightPx: Int) {
        sourceVideoWidthPx = widthPx
        sourceVideoHeightPx = heightPx
    }

    // -- Draw ------------------------------------------------------------------

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
    fun drawFrame(): Boolean {
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

            GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
            GLES20.glViewport(0, 0, outputWidthPx, outputHeightPx)
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

            if (hasTexImage) {
                drawSourceRect(sourceRect ?: fullSurfaceRect())
            }

            // Camera rect: draw live OES frame when available, else placeholder.
            val cr = cameraRect
            if (cr != null) {
                if (hasCameraTexImage) {
                    drawCameraRect(cr)
                } else {
                    drawCameraPlaceholder(cr)
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
    fun release() {
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
        }
        oesProgram = 0
        oesTextureId = 0
        cameraOesTextureId = 0

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
     * Sets a deterministic portrait preview default buffer size (1080×1920) on the
     * SurfaceTexture before wrapping it in a Surface. The size must be non-zero
     * before the first camera frame arrives so that updateTexImage produces a valid
     * image and the OES sampler has a defined texel size. Preview-ingress default
     * only — no recording/export claim.
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
     * Draws the latched camera OES frame aspect-filled into [rect], mirroring
     * the structure of [drawSourceRect] but binding [cameraOesTextureId] and
     * [cameraStMatrix]. Reuses the same OES shader program; camera and decoder
     * are independent GL textures and transform matrices.
     *
     * Aspect-fill uses the 9:16 camera stream aspect (front camera negotiated
     * resolution). The scissor constrains output to the camera rect bounds.
     * Camera frames are not aspect-distorted.
     */
    private fun drawCameraRect(rect: VGDuetPixelRect) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return

        // For the camera we don't know the resolved resolution from here, so use
        // the rect itself as the viewport (aspect-fill via scissor alone is
        // sufficient for typical 9:16 portrait camera into portrait camera rect).
        // The SurfaceTexture transform matrix (cameraStMatrix) handles any flip/crop.
        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glViewport(scissor.x, scissor.y, scissor.width, scissor.height)

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
