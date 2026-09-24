package com.connects.vanguard_media_engine.editor

import android.graphics.Bitmap
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.opengl.GLUtils
import android.util.Log
import com.connects.vanguard_media_engine.codec.AndroidDagSurfaceProducerLifecycleAdapter
import com.connects.vanguard_media_engine.export.AndroidStillImageDecoder
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.max
import kotlin.math.min

/**
 * ANDROID-EDITOR-STATIC-IMAGE-PREVIEW: renders one still image, centered and
 * scaled by [fitMode] ("fit" letterbox / "fill" cover-crop), onto the same
 * [TextureRegistry.SurfaceProducer] that [AndroidDagTexturePlaybackControlSession]
 * uses for video clips -- so [AndroidEditorSequentialPlaybackSession] can show
 * an image slideshow clip on the shared preview texture without a decoder.
 *
 * Owns its own EGL display/context/pbuffer/program, created lazily on first
 * use and kept alive across image-to-image clip switches within one session
 * (cheap to reuse; only the window surface and decoded texture are replaced
 * per clip). Never touches a [TextureRegistry.SurfaceProducer] it wasn't
 * given, and never calls [TextureRegistry.SurfaceProducer.release] --
 * [AndroidEditorSequentialPlaybackSession] (and, above it,
 * [AndroidEditorPlaybackCoordinator]) own that.
 *
 * Threading: every method here must be called from the owning session's
 * single orchestration [android.os.Handler] thread, exactly like every other
 * "Must be called from orchHandler" method in [AndroidEditorSequentialPlaybackSession].
 * The [TextureRegistry.SurfaceProducer.Callback] this class registers fires on
 * the Flutter platform thread; [attachOutputSurface]'s [onSurfaceLost] /
 * [onSurfaceRestored] callbacks are responsible for hopping back onto
 * orchHandler before calling [handleSurfaceLost] / [handleSurfaceRestored] --
 * mirrors [AndroidEditorTransitionPlaybackSession]'s own surface-lifecycle
 * wiring.
 *
 * Decode: [AndroidStillImageDecoder] provides EXIF orientation, a display-
 * bounds-aware bounded sample size (never decodes a full-size camera JPEG
 * unbounded), and a max-texture-size clamp -- the same helper the still-image
 * export path ([AndroidTimelineVideoEncoder.renderStillClipIntoEncoder]) uses.
 * Every intermediate [Bitmap] is recycled immediately after
 * [GLUtils.texImage2D] uploads it; only the resulting GL texture is retained.
 */
class AndroidEditorStaticImageRenderer {

    companion object {
        private const val TAG = "EditorStaticImageRenderer"
    }

    // ── EGL context (persistent across clip switches; created lazily) ──────

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglConfig: EGLConfig? = null
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglPbufferSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var contextReady = false

    private var program = 0
    private var aPositionLoc = 0
    private var aTexCoordLoc = 0

    // ── Per-activation window surface (recreated every attach) ─────────────

    private var eglWindowSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var attachedSurfaceProducer: TextureRegistry.SurfaceProducer? = null
    private var callbackAdapter: AndroidDagSurfaceProducerLifecycleAdapter? = null

    /**
     * True only between a genuine [handleSurfaceLost] and its matching
     * [handleSurfaceRestored] (or [detachOutputSurface] / [release]). Guards
     * [handleSurfaceRestored] against a spurious or duplicate
     * `onSurfaceAvailable` -- e.g. the registration-time notification
     * [attachOutputSurface]'s own fresh `setCallback` may receive even though
     * that same call just created the first window surface itself -- so a
     * restore is only ever attempted after a real loss.
     */
    private var surfaceLost = false

    // ── Last successfully rendered frame (for surface-restore redraw) ──────

    private var currentTextureId = 0
    private var currentQuad: FloatArray? = null

    /**
     * BL, BR, TL, TR position pairs (filled per render); matching texture
     * coordinates are Y-flipped relative to the position order, because
     * [GLUtils.texImage2D] uploads a [Bitmap] in top-down row order while
     * OpenGL texture V=0 is the bottom row -- exactly the same
     * `texCoords2D` convention [AndroidTimelineVideoEncoder] uses for its
     * still-image export path, so preview and export agree on orientation.
     */
    private val quadBuffer: FloatBuffer = ByteBuffer.allocateDirect(8 * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer()
    private val texCoords = floatArrayOf(0f, 1f, 1f, 1f, 0f, 0f, 1f, 0f)
    private val texBuffer: FloatBuffer = ByteBuffer.allocateDirect(texCoords.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(texCoords)
            position(0)
        }

    /** Outcome of a successful [renderImage]: the image's post-EXIF display dimensions. */
    data class RenderOutcome(val displayWidth: Int, val displayHeight: Int)

    /** Exactly one of [outcome] / [failure] is non-null. */
    class RenderResult private constructor(val outcome: RenderOutcome?, val failure: String?) {
        companion object {
            fun success(outcome: RenderOutcome) = RenderResult(outcome, null)
            fun failure(reason: String) = RenderResult(null, reason)
        }
    }

    /**
     * Outcome of [handleSurfaceRestored], distinguishing a spurious/duplicate
     * callback from a genuine restore attempt and its result -- a bare
     * `String?` cannot express "nothing happened" vs. "it worked" vs. "it
     * failed" without an ambiguous null. Public because
     * [AndroidEditorSequentialPlaybackSession] must branch on it to decide
     * whether `image_surface_restored` may ever be logged.
     */
    sealed class RestoreOutcome {
        /** [handleSurfaceLost] was never called since the last resolved restore/attach: nothing to do. */
        object NoOp : RestoreOutcome()

        /** The window surface was recreated and the cached frame redrawn successfully. */
        object Restored : RestoreOutcome()

        /** A step failed; the renderer remains marked surface-lost for a later retry. */
        data class Failed(val reason: String) : RestoreOutcome()
    }

    // ── Attach / detach ──────────────────────────────────────────────────────

    /**
     * Must be called from orchHandler. Ensures the EGL context/program exist
     * (lazy, one-time), sizes [surfaceProducer] to [canvasWidth]x[canvasHeight]
     * -- the native texture contract is the editor canvas, not the raw decoded
     * image -- then (re)creates the window surface bound to it and registers a
     * fresh [TextureRegistry.SurfaceProducer.Callback], in that order (matching
     * [AndroidEditorTransitionPlaybackSession]'s own setSize-before-window-surface
     * sequencing). Mirrors
     * [com.connects.vanguard_media_engine.codec.AndroidDagTexturePlaybackControlSession]'s
     * own per-activation `setCallback` pattern, so it is safe (and expected)
     * to call this again for every image clip activation, including two
     * consecutive image clips of different sizes. [onSurfaceLost] / [onSurfaceRestored]
     * are invoked on the Flutter platform thread and must hop back onto
     * orchHandler themselves before calling [handleSurfaceLost] /
     * [handleSurfaceRestored]. Returns a failure reason, or null on success.
     */
    fun attachOutputSurface(
        surfaceProducer: TextureRegistry.SurfaceProducer,
        canvasWidth: Int,
        canvasHeight: Int,
        onSurfaceLost: () -> Unit,
        onSurfaceRestored: () -> Unit,
    ): String? {
        val ctxFailure = ensureContext()
        if (ctxFailure != null) return ctxFailure
        if (canvasWidth <= 0 || canvasHeight <= 0) {
            return "image_invalid_canvas:${canvasWidth}x$canvasHeight"
        }

        destroyWindowSurfaceOnly()
        surfaceLost = false
        attachedSurfaceProducer = surfaceProducer
        val adapter = AndroidDagSurfaceProducerLifecycleAdapter(
            onAvailable = onSurfaceRestored,
            onCleanup = onSurfaceLost,
        )
        callbackAdapter = adapter
        try {
            @Suppress("DEPRECATION")
            surfaceProducer.setCallback(adapter)
        } catch (t: Throwable) {
            return "surface_producer_set_callback_failed:${t.javaClass.simpleName}"
        }
        // The native texture contract is the editor canvas, not the raw decoded
        // image (see [renderImage] / [computeQuad]): size the SurfaceProducer to
        // the canvas BEFORE creating the window surface, mirroring
        // AndroidEditorTransitionPlaybackSession's own setSize-before-window-surface
        // ordering, so the Flutter-side texture is never left at a stale or
        // decoded-image size.
        try {
            surfaceProducer.setSize(canvasWidth, canvasHeight)
        } catch (t: Throwable) {
            return "surface_producer_set_size_failed:${t.javaClass.simpleName}"
        }
        return createWindowSurface()
    }

    /**
     * Must be called from orchHandler. Destroys the window surface and
     * unregisters this renderer's surface callback, WITHOUT destroying the
     * EGL context/program/current texture -- call this when switching away
     * from an image clip to a video clip (before the wrapped
     * [com.connects.vanguard_media_engine.codec.AndroidDagTexturePlaybackControlSession]
     * registers its own callback and window surface on the same
     * [TextureRegistry.SurfaceProducer]) and as the first step of [release].
     * Safe to call when not currently attached.
     */
    fun detachOutputSurface() {
        val producer = attachedSurfaceProducer
        if (producer != null) {
            try {
                @Suppress("DEPRECATION")
                producer.setCallback(null)
            } catch (_: Throwable) {}
        }
        callbackAdapter = null
        attachedSurfaceProducer = null
        surfaceLost = false
        destroyWindowSurfaceOnly()
    }

    // ── Transient surface loss / restore ────────────────────────────────────

    /**
     * Must be called from orchHandler, in response to a genuine
     * [TextureRegistry.SurfaceProducer.Callback.onSurfaceCleanup]. Destroys ONLY
     * the EGL window surface -- the EGL context/program/current texture/quad
     * cache are left intact -- and marks the output surface-lost so a later
     * [handleSurfaceRestored] knows to actually recreate it. Never unregisters
     * the surface callback: that happens only in [detachOutputSurface] /
     * [release]. Idempotent.
     */
    fun handleSurfaceLost() {
        surfaceLost = true
        destroyWindowSurfaceOnly()
    }

    /**
     * Must be called from orchHandler, in response to
     * [TextureRegistry.SurfaceProducer.Callback.onSurfaceAvailable]. Returns
     * [RestoreOutcome.NoOp] unless [handleSurfaceLost] previously marked the
     * output surface-lost -- see [surfaceLost]'s doc for why a spurious/
     * duplicate `onSurfaceAvailable` must never trigger a recreate here. On a
     * genuine restore attempt: re-sizes the attached
     * [TextureRegistry.SurfaceProducer] to [canvasWidth]x[canvasHeight] (a real
     * surface loss can hand back a differently configured producer), recreates
     * the EGL window surface, then redraws the cached last frame -- never
     * re-decoding the source image -- returning [RestoreOutcome.Restored] only
     * if every step succeeds. Stays marked surface-lost and returns
     * [RestoreOutcome.Failed] on any step's failure (including cleaning up a
     * window surface created by this same call if only the redraw step
     * fails), so a caller can never mistake a failed restore for success or
     * for a no-op; a later restore attempt starts clean.
     */
    fun handleSurfaceRestored(canvasWidth: Int, canvasHeight: Int): RestoreOutcome {
        if (!surfaceLost) return RestoreOutcome.NoOp
        val producer = attachedSurfaceProducer
            ?: return RestoreOutcome.Failed("image_surface_producer_missing")
        try {
            producer.setSize(canvasWidth, canvasHeight)
        } catch (t: Throwable) {
            return RestoreOutcome.Failed("surface_producer_set_size_failed:${t.javaClass.simpleName}")
        }
        val windowFailure = createWindowSurface()
        if (windowFailure != null) return RestoreOutcome.Failed(windowFailure)
        val redrawFailure = redrawLastFrame(canvasWidth, canvasHeight)
        if (redrawFailure != null) {
            destroyWindowSurfaceOnly()
            return RestoreOutcome.Failed(redrawFailure)
        }
        surfaceLost = false
        return RestoreOutcome.Restored
    }

    /**
     * True when the output window surface exists and is not marked
     * surface-lost -- i.e. it is safe right now to start the timeline clock
     * (play) or emit a timeline frame for an intra-clip seek without
     * presenting against an unavailable texture. False between a genuine
     * [handleSurfaceLost] and its matching [RestoreOutcome.Restored], and
     * before the first successful [attachOutputSurface]/[renderImage]. Mirrors
     * the wrapped [com.connects.vanguard_media_engine.codec.AndroidDagTexturePlaybackControlSession]'s
     * own `state == SurfaceLost` refusal that video/freeze clips already get.
     */
    fun canPresentOutput(): Boolean = !surfaceLost && eglWindowSurface != EGL14.EGL_NO_SURFACE

    private fun ensureContext(): String? {
        if (contextReady) return null
        try {
            eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (eglDisplay == EGL14.EGL_NO_DISPLAY) return "egl_get_display_failed"
            val version = IntArray(2)
            if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) return "egl_initialize_failed"
            val attribs = intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfigs = IntArray(1)
            EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, 1, numConfigs, 0)
            val config = configs[0] ?: return "egl_choose_config_failed"
            eglConfig = config

            eglContext = EGL14.eglCreateContext(
                eglDisplay, config, EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
            )
            if (eglContext == EGL14.EGL_NO_CONTEXT) return "egl_create_context_failed"

            eglPbufferSurface = EGL14.eglCreatePbufferSurface(
                eglDisplay, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0,
            )
            if (eglPbufferSurface == EGL14.EGL_NO_SURFACE) return "egl_create_pbuffer_failed"
            if (!EGL14.eglMakeCurrent(eglDisplay, eglPbufferSurface, eglPbufferSurface, eglContext)) {
                return "egl_make_current_failed"
            }

            setupProgram()
            contextReady = true
            return null
        } catch (t: Throwable) {
            Log.e(TAG, "ensureContext failed", t)
            return "egl_setup_exception:${t.javaClass.simpleName}"
        }
    }

    private fun setupProgram() {
        val vertexSrc = """
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            varying vec2 vTextureCoord;
            void main() {
                gl_Position = aPosition;
                vTextureCoord = aTextureCoord.xy;
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
        val vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, vertexSrc)
        val fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        val prog = GLES20.glCreateProgram()
        GLES20.glAttachShader(prog, vertexShader)
        GLES20.glAttachShader(prog, fragmentShader)
        GLES20.glLinkProgram(prog)
        GLES20.glDeleteShader(vertexShader)
        GLES20.glDeleteShader(fragmentShader)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(prog)
            GLES20.glDeleteProgram(prog)
            throw IllegalStateException("GL static-image program link failed: $log")
        }
        program = prog
        aPositionLoc = GLES20.glGetAttribLocation(prog, "aPosition")
        aTexCoordLoc = GLES20.glGetAttribLocation(prog, "aTextureCoord")
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
            throw IllegalStateException("GL static-image shader compile failed: $log")
        }
        return shader
    }

    private fun createWindowSurface(): String? {
        val config = eglConfig ?: return "egl_config_missing"
        val producer = attachedSurfaceProducer ?: return "surface_producer_missing"
        val surface = try {
            producer.getSurface()
        } catch (t: Throwable) {
            return "surface_producer_get_surface_failed:${t.javaClass.simpleName}"
        }
        val window = EGL14.eglCreateWindowSurface(eglDisplay, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
        if (window == null || window == EGL14.EGL_NO_SURFACE) {
            return "egl_create_window_surface_failed:0x${Integer.toHexString(EGL14.eglGetError())}"
        }
        if (!EGL14.eglMakeCurrent(eglDisplay, window, window, eglContext)) {
            try { EGL14.eglDestroySurface(eglDisplay, window) } catch (_: Throwable) {}
            EGL14.eglMakeCurrent(eglDisplay, eglPbufferSurface, eglPbufferSurface, eglContext)
            return "egl_make_current_window_failed:0x${Integer.toHexString(EGL14.eglGetError())}"
        }
        eglWindowSurface = window
        return null
    }

    private fun destroyWindowSurfaceOnly() {
        val window = eglWindowSurface
        eglWindowSurface = EGL14.EGL_NO_SURFACE
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return
        try { EGL14.eglMakeCurrent(eglDisplay, eglPbufferSurface, eglPbufferSurface, eglContext) } catch (_: Throwable) {}
        if (window != EGL14.EGL_NO_SURFACE) {
            try { EGL14.eglDestroySurface(eglDisplay, window) } catch (_: Throwable) {}
        }
    }

    // ── Render ───────────────────────────────────────────────────────────────

    /**
     * Must be called from orchHandler, after a successful [attachOutputSurface].
     * Decodes [path] (EXIF orientation applied, sample size bounded against
     * [canvasWidth]x[canvasHeight] and the current GL_MAX_TEXTURE_SIZE),
     * uploads it as a plain 2D texture, computes a centered [fitMode] quad,
     * draws, and swaps buffers once. The previous texture (if any) is deleted
     * first. Returns the display dimensions on success, or a failure reason.
     */
    fun renderImage(path: String, fitMode: String, canvasWidth: Int, canvasHeight: Int): RenderResult {
        if (eglWindowSurface == EGL14.EGL_NO_SURFACE) return RenderResult.failure("image_surface_unavailable")
        if (canvasWidth <= 0 || canvasHeight <= 0) {
            return RenderResult.failure("image_invalid_canvas:${canvasWidth}x$canvasHeight")
        }
        var bitmapToRecycle: Bitmap? = null
        var newTextureId = 0
        try {
            if (!EGL14.eglMakeCurrent(eglDisplay, eglWindowSurface, eglWindowSurface, eglContext)) {
                return RenderResult.failure("image_make_current_failed:0x${Integer.toHexString(EGL14.eglGetError())}")
            }

            val exifOrientation = AndroidStillImageDecoder.readExifOrientation(path)
            val bounds = AndroidStillImageDecoder.probeBounds(path)
                ?: return RenderResult.failure("image_probe_failed:$path")

            val maxTextureSize = IntArray(1)
            GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, maxTextureSize, 0)

            val inSampleSize = AndroidStillImageDecoder.computeInSampleSize(
                bounds.width, bounds.height, canvasWidth, canvasHeight, maxTextureSize[0], exifOrientation,
            )
            val decoded = AndroidStillImageDecoder.decodeBitmap(path, inSampleSize)
                ?: return RenderResult.failure("image_decode_failed:$path")
            bitmapToRecycle = decoded
            val oriented = AndroidStillImageDecoder.applyExifOrientation(decoded, exifOrientation)
            bitmapToRecycle = oriented
            val bitmap = AndroidStillImageDecoder.clampToMaxTextureSize(oriented, maxTextureSize[0])
            bitmapToRecycle = bitmap

            val displayWidth = bitmap.width
            val displayHeight = bitmap.height
            if (displayWidth <= 0 || displayHeight <= 0) {
                return RenderResult.failure("image_invalid_geometry:$path")
            }

            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            newTextureId = textures[0]
            if (newTextureId == 0) return RenderResult.failure("image_texture_alloc_failed:$path")
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, newTextureId)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
            val texUploadError = GLES20.glGetError()
            bitmap.recycle()
            bitmapToRecycle = null
            if (texUploadError != GLES20.GL_NO_ERROR) {
                return RenderResult.failure("image_texture_upload_failed:$texUploadError:$path")
            }

            val quad = computeQuad(displayWidth, displayHeight, fitMode, canvasWidth, canvasHeight)

            val drawFailure = drawQuad(newTextureId, quad, canvasWidth, canvasHeight)
            if (drawFailure != null) return RenderResult.failure(drawFailure)
            if (!EGL14.eglSwapBuffers(eglDisplay, eglWindowSurface)) {
                return RenderResult.failure("image_swap_failed:0x${Integer.toHexString(EGL14.eglGetError())}")
            }

            // Success: replace the cached texture/quad and delete the old one.
            if (currentTextureId != 0 && currentTextureId != newTextureId) {
                try { GLES20.glDeleteTextures(1, intArrayOf(currentTextureId), 0) } catch (_: Throwable) {}
            }
            currentTextureId = newTextureId
            currentQuad = quad
            newTextureId = 0
            return RenderResult.success(RenderOutcome(displayWidth, displayHeight))
        } catch (t: Throwable) {
            Log.e(TAG, "renderImage failed for $path", t)
            return RenderResult.failure("image_render_exception:${t.javaClass.simpleName}:$path")
        } finally {
            try { bitmapToRecycle?.recycle() } catch (_: Throwable) {}
            if (newTextureId != 0) {
                try { GLES20.glDeleteTextures(1, intArrayOf(newTextureId), 0) } catch (_: Throwable) {}
            }
        }
    }

    /**
     * Must be called from orchHandler, after a surface restore
     * ([attachOutputSurface] succeeded again). Redraws the last successfully
     * rendered image's cached texture/quad without re-decoding the file.
     * Returns a failure reason, null on success, or "image_nothing_to_redraw"
     * if [renderImage] never succeeded.
     */
    fun redrawLastFrame(canvasWidth: Int, canvasHeight: Int): String? {
        val textureId = currentTextureId
        val quad = currentQuad
        if (textureId == 0 || quad == null) return "image_nothing_to_redraw"
        if (eglWindowSurface == EGL14.EGL_NO_SURFACE) return "image_surface_unavailable"
        if (!EGL14.eglMakeCurrent(eglDisplay, eglWindowSurface, eglWindowSurface, eglContext)) {
            return "image_make_current_failed:0x${Integer.toHexString(EGL14.eglGetError())}"
        }
        val drawFailure = drawQuad(textureId, quad, canvasWidth, canvasHeight)
        if (drawFailure != null) return drawFailure
        if (!EGL14.eglSwapBuffers(eglDisplay, eglWindowSurface)) {
            return "image_swap_failed:0x${Integer.toHexString(EGL14.eglGetError())}"
        }
        return null
    }

    /**
     * Centered quad (BL, BR, TL, TR NDC pairs), no rotation -- unlike video,
     * [AndroidStillImageDecoder.applyExifOrientation] already physically
     * rotates the decoded bitmap, so [displayWidth]/[displayHeight] are
     * already in display orientation. "fit" scales by
     * min(canvas/display) (letterbox); "fill" scales by max(canvas/display):
     * the quad then extends past the +/-1 NDC canvas bounds on one axis and
     * is clipped there by the GPU's standard primitive clipping, producing a
     * centered cover-crop with no extra geometry -- the same technique
     * [AndroidEditorTransitionPlaybackSession.computeFitQuadOrNull] uses for
     * canvas-level fill.
     */
    private fun computeQuad(
        displayWidth: Int,
        displayHeight: Int,
        fitMode: String,
        canvasWidth: Int,
        canvasHeight: Int,
    ): FloatArray {
        val scale = if (fitMode == "fill") {
            max(canvasWidth.toFloat() / displayWidth, canvasHeight.toFloat() / displayHeight)
        } else {
            min(canvasWidth.toFloat() / displayWidth, canvasHeight.toFloat() / displayHeight)
        }
        val ndcHalfW = (displayWidth * scale / 2f) / (canvasWidth / 2f)
        val ndcHalfH = (displayHeight * scale / 2f) / (canvasHeight / 2f)
        return floatArrayOf(
            -ndcHalfW, -ndcHalfH,
            ndcHalfW, -ndcHalfH,
            -ndcHalfW, ndcHalfH,
            ndcHalfW, ndcHalfH,
        )
    }

    private fun drawQuad(textureId: Int, quad: FloatArray, canvasWidth: Int, canvasHeight: Int): String? {
        GLES20.glViewport(0, 0, canvasWidth, canvasHeight)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(program)
        quadBuffer.position(0)
        quadBuffer.put(quad)
        quadBuffer.position(0)
        GLES20.glEnableVertexAttribArray(aPositionLoc)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadBuffer)
        texBuffer.position(0)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, texBuffer)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(aPositionLoc)
        GLES20.glDisableVertexAttribArray(aTexCoordLoc)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        GLES20.glUseProgram(0)
        val err = GLES20.glGetError()
        return if (err == GLES20.GL_NO_ERROR) null else "image_gl_error:$err"
    }

    // ── Release ──────────────────────────────────────────────────────────────

    /**
     * Must be called from orchHandler. Full teardown: detaches the output
     * surface (see [detachOutputSurface]), deletes the current texture and GL
     * program, destroys the pbuffer surface and EGL context, and terminates
     * the EGL display. Idempotent. Never releases the
     * [TextureRegistry.SurfaceProducer] itself.
     */
    fun release() {
        detachOutputSurface()
        if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglContext != EGL14.EGL_NO_CONTEXT) {
            try {
                EGL14.eglMakeCurrent(eglDisplay, eglPbufferSurface, eglPbufferSurface, eglContext)
                if (currentTextureId != 0) {
                    GLES20.glDeleteTextures(1, intArrayOf(currentTextureId), 0)
                }
                if (program != 0) GLES20.glDeleteProgram(program)
            } catch (_: Throwable) {}
        }
        currentTextureId = 0
        currentQuad = null
        program = 0
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            try { EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT) } catch (_: Throwable) {}
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
        contextReady = false
    }
}
