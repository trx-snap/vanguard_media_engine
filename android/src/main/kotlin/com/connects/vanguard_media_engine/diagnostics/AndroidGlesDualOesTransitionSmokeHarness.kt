package com.connects.vanguard_media_engine.diagnostics

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLES30
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/**
 * P5-GLES-EXPORT-DUAL-OES-PRERESOLVE-TRANSITION-READINESS: diagnostic-only
 * harness strengthening the prior dual-OES transition proof. TWO real
 * MediaCodec decodes, each feeding its own SurfaceTexture-backed
 * GL_TEXTURE_EXTERNAL_OES texture on ONE caller-owned, current-verified ES3
 * EGL pbuffer context, are updateTexImage()'d, then EACH OES texture is
 * pre-resolved -- with its SurfaceTexture transform matrix applied -- into
 * its own canvas-sized GL_TEXTURE_2D RGBA8 raster via an FBO blit through a
 * minimal external-OES passthrough shader. Only the two RESOLVED 2D
 * textures are then handed to the private
 * `GlesTimelineTransitionCompositor::drawTransition` seam (fixed crossfade
 * midpoint: progress 0.5, blendWeightFrom == blendWeightTo == 0.5, identity
 * crops/viewports) through
 * [VanguardNativeBridge.drawAndroidDagPhase5GlesDualOesTransition].
 *
 * The pre-resolve step exists because feeding raw OES textures straight into
 * the compositor's mix draw would both skip the SurfaceTexture transform
 * matrix and risk the crossfade mix path's identity-geometry contract;
 * resolving to identity-oriented 2D rasters first avoids both failure modes
 * before any production wiring is attempted.
 *
 * Every EGL/GL/MediaCodec/SurfaceTexture object is created and destroyed by
 * this harness on the single background thread that calls [run]; the native
 * seam creates/destroys none of them and only draws into the already-current
 * context using the two already-populated resolved 2D textures. Diagnostic
 * only: no production GLES export route, no AndroidTimelineExportSession/
 * AndroidTimelineVideoEncoder/AndroidExportRenderBackendSelector change, and
 * `GlesTimelineTransitionCompositor` itself is untouched.
 *
 * Proof chain: dual MediaCodec -> dual SurfaceTexture/OES ->
 * updateTexImage() -> OES-to-canvas-2D pre-resolve -> GLES transition
 * compositor with 2D textures -> pixel/state/cleanup proof.
 */
class AndroidGlesDualOesTransitionSmokeHarness {

    companion object {
        private const val PROOF_BOUNDARY =
            "diagnostic_dual_mediacodec_surfacetexture_oes_to_canvas2d_preresolve_to_gles_transition_compositor_no_export"
        private const val PASS_MARKER =
            "ANDROID_DAG_PHASE5_GLES_DUAL_OES_TRANSITION_PHYSICAL_SMOKE_PASS"
        private const val FAIL_MARKER =
            "ANDROID_DAG_PHASE5_GLES_DUAL_OES_TRANSITION_PHYSICAL_SMOKE_FAIL"

        private const val SURFACE_SIZE = 128
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val DECODE_TIMEOUT_MS = 5_000L
        private const val FRAME_AVAILABLE_TIMEOUT_MS = 3_000L

        /** Fixed crossfade midpoint this diagnostic exercises. */
        private const val TRANSITION_PROGRESS = 0.5

        // Pre-draw clear color for each resolve FBO. Chosen far from both
        // typical decoded video content and the native seam's own sentinel
        // (40,40,40) so a resolved sample escaping this color is unambiguous
        // proof that the OES-to-2D blit actually drew real content.
        private const val RESOLVE_CLEAR_R = 10
        private const val RESOLVE_CLEAR_G = 200
        private const val RESOLVE_CLEAR_B = 10
        private const val RESOLVE_COLOR_TOLERANCE = 8

        // Corner + center probes across each resolved raster.
        private val RESOLVE_SAMPLE_POINTS = listOf(8 to 8, 64 to 64, 120 to 120)

        private val QUAD_POSITIONS = floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
        private val QUAD_TEX_COORDS = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)

        val GATE_KEYS = listOf(
            "argumentValidationOk",
            "eglSetupOk",
            "es3ContextVerifiedOk",
            "dualDecoderSetupOk",
            "bothFramesAvailableOk",
            "bothUpdateTexImageOk",
            "bothOesResolveOk",
            "resolvedContentOk",
            "nativeTransitionDrawOk",
            "pixelProofOk",
            "stateRestoredOk",
            "cleanupOk",
        )
    }

    /** Runs the full dual-OES transition proof for the two clips. Never throws. */
    fun run(fromClipPath: String?, toClipPath: String?): Map<String, Any?> {
        val gates = linkedMapOf<String, Boolean>()
        for (key in GATE_KEYS) gates[key] = false
        val details = linkedMapOf<String, Any?>()
        var failureReason = ""
        fun fail(reason: String) {
            if (failureReason.isEmpty()) failureReason = reason
        }

        var glMajorVersion = 0
        var fromPtsUs = -1L
        var toPtsUs = -1L
        var nativeRaw = ""

        val argError = validateArgs(fromClipPath, toClipPath)
        gates["argumentValidationOk"] = argError == null
        if (argError != null) {
            fail("invalid_arguments:$argError")
            return buildResult(gates, failureReason, details, glMajorVersion, fromPtsUs, toPtsUs, nativeRaw)
        }

        var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
        var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
        var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
        var fromTextureId = 0
        var toTextureId = 0
        var resolveProgram = 0
        var fromResolveTextureId = 0
        var toResolveTextureId = 0
        var fromResolveFboId = 0
        var toResolveFboId = 0
        var fromExtractor: MediaExtractor? = null
        var toExtractor: MediaExtractor? = null
        var fromCodec: MediaCodec? = null
        var toCodec: MediaCodec? = null
        var handlerThread: HandlerThread? = null
        var fromSurfaceTexture: SurfaceTexture? = null
        var toSurfaceTexture: SurfaceTexture? = null
        var fromInputSurface: Surface? = null
        var toInputSurface: Surface? = null
        val fromFrameAvailable = Semaphore(0)
        val toFrameAvailable = Semaphore(0)

        fun executeHarness() {
            eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (eglDisplay == EGL14.EGL_NO_DISPLAY) {
                fail("egl_get_display_failed"); return
            }
            val version = IntArray(2)
            if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
                fail("egl_initialize_failed"); return
            }
            val configAttribs = intArrayOf(
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfigs = IntArray(1)
            if (!EGL14.eglChooseConfig(eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0) ||
                numConfigs[0] < 1
            ) {
                fail("egl_choose_config_failed_es3"); return
            }
            val config = configs[0]
            if (config == null) {
                fail("egl_choose_config_failed_es3"); return
            }

            val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
            eglContext = EGL14.eglCreateContext(eglDisplay, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
            if (eglContext == EGL14.EGL_NO_CONTEXT) {
                fail("egl_create_context_failed_es3"); return
            }
            val pbufferAttribs = intArrayOf(
                EGL14.EGL_WIDTH, SURFACE_SIZE,
                EGL14.EGL_HEIGHT, SURFACE_SIZE,
                EGL14.EGL_NONE,
            )
            eglSurface = EGL14.eglCreatePbufferSurface(eglDisplay, config, pbufferAttribs, 0)
            if (eglSurface == EGL14.EGL_NO_SURFACE) {
                fail("egl_create_pbuffer_surface_failed_es3"); return
            }
            if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
                fail("egl_make_current_failed_es3"); return
            }
            gates["eglSetupOk"] = true

            // -- ES3 current-context assertion: query GL_MAJOR_VERSION rather
            //    than trusting the EGL_CONTEXT_CLIENT_VERSION request alone. --
            GLES20.glGetError()
            val majorVersion = IntArray(1)
            GLES20.glGetIntegerv(GLES30.GL_MAJOR_VERSION, majorVersion, 0)
            val majorVersionQueryError = GLES20.glGetError()
            glMajorVersion = majorVersion[0]
            details["glMajorVersion"] = glMajorVersion
            val es3ContextVerified = majorVersionQueryError == GLES20.GL_NO_ERROR && majorVersion[0] >= 3
            gates["es3ContextVerifiedOk"] = es3ContextVerified
            if (!es3ContextVerified) {
                fail("context_not_es3"); return
            }

            fromTextureId = createOesTexture()
            toTextureId = createOesTexture()
            if (fromTextureId == 0 || toTextureId == 0) {
                fail("oes_texture_creation_failed"); return
            }

            val thread = HandlerThread("vanguard-p5-gles-dual-oes-transition-frame-listener").also { it.start() }
            handlerThread = thread
            val listenerHandler = Handler(thread.looper)

            val fromTexture = SurfaceTexture(fromTextureId)
            fromSurfaceTexture = fromTexture
            fromTexture.setDefaultBufferSize(SURFACE_SIZE, SURFACE_SIZE)
            fromTexture.setOnFrameAvailableListener({ fromFrameAvailable.release() }, listenerHandler)
            fromInputSurface = Surface(fromTexture)

            val toTexture = SurfaceTexture(toTextureId)
            toSurfaceTexture = toTexture
            toTexture.setDefaultBufferSize(SURFACE_SIZE, SURFACE_SIZE)
            toTexture.setOnFrameAvailableListener({ toFrameAvailable.release() }, listenerHandler)
            toInputSurface = Surface(toTexture)

            // -- Dual hardware decode pipeline setup ---------------------------
            val fromExt = MediaExtractor()
            fromExtractor = fromExt
            fromExt.setDataSource(fromClipPath!!)
            val fromFormat = findVideoTrackFormat(fromExt)
            if (fromFormat == null) {
                fail("no_video_track:from"); return
            }

            val toExt = MediaExtractor()
            toExtractor = toExt
            toExt.setDataSource(toClipPath!!)
            val toFormat = findVideoTrackFormat(toExt)
            if (toFormat == null) {
                fail("no_video_track:to"); return
            }

            val fromMime = fromFormat.getString(MediaFormat.KEY_MIME)!!
            val fromDec = MediaCodec.createDecoderByType(fromMime)
            fromDec.configure(fromFormat, fromInputSurface, null, 0)
            fromDec.start()
            fromCodec = fromDec

            val toMime = toFormat.getString(MediaFormat.KEY_MIME)!!
            val toDec = MediaCodec.createDecoderByType(toMime)
            toDec.configure(toFormat, toInputSurface, null, 0)
            toDec.start()
            toCodec = toDec

            gates["dualDecoderSetupOk"] = true

            // -- Release one in-window frame from each decoder (render=true) --
            val (fromDecodeError, fromFrameDecoded) = decodeOneRenderableFrame(fromExt, fromDec)
            if (fromDecodeError != null) {
                fail("decode_failed:from:$fromDecodeError"); return
            }
            fromPtsUs = fromFrameDecoded

            val (toDecodeError, toFrameDecoded) = decodeOneRenderableFrame(toExt, toDec)
            if (toDecodeError != null) {
                fail("decode_failed:to:$toDecodeError"); return
            }
            toPtsUs = toFrameDecoded
            details["fromPtsUs"] = fromPtsUs
            details["toPtsUs"] = toPtsUs

            // -- Wait bounded for both frame-available callbacks ---------------
            val fromAvailable = fromFrameAvailable.tryAcquire(FRAME_AVAILABLE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            val toAvailable = toFrameAvailable.tryAcquire(FRAME_AVAILABLE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            gates["bothFramesAvailableOk"] = fromAvailable && toAvailable
            if (!fromAvailable || !toAvailable) {
                fail("frame_available_timeout:from=$fromAvailable,to=$toAvailable"); return
            }

            // -- updateTexImage() for each, while the EGL context is current ---
            val updateOk = try {
                fromTexture.updateTexImage()
                toTexture.updateTexImage()
                true
            } catch (t: Throwable) {
                fail("update_tex_image_failed:${t.javaClass.simpleName}:${t.message}")
                false
            }
            gates["bothUpdateTexImageOk"] = updateOk
            if (!updateOk) return

            // -- OES -> canvas-2D pre-resolve: draw each decoded OES texture,
            //    with its own SurfaceTexture transform matrix applied, into
            //    its own canvas-sized GL_TEXTURE_2D RGBA8 FBO via a minimal
            //    external-OES passthrough shader and full-canvas quad. This
            //    is required before the native transition seam: drawing
            //    directly from a SurfaceTexture-backed OES texture would
            //    both skip its transform matrix and risk the crossfade mix
            //    path's identity-geometry contract, so only the resolved 2D
            //    rasters -- never the raw OES textures -- are handed to the
            //    compositor below. -----------------------------------------
            val program = buildOesPassthroughProgram()
            if (program <= 0) {
                fail("resolve_gl_program_link_failed"); return
            }
            resolveProgram = program
            val aPositionLoc = GLES20.glGetAttribLocation(program, "aPosition")
            val aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTextureCoord")
            val uSTMatrixLoc = GLES20.glGetUniformLocation(program, "uSTMatrix")

            fromResolveTextureId = createRgba8Texture(SURFACE_SIZE)
            toResolveTextureId = createRgba8Texture(SURFACE_SIZE)
            if (fromResolveTextureId == 0 || toResolveTextureId == 0) {
                fail("resolve_texture_creation_failed"); return
            }
            val fromFboStatus = createFramebufferForTexture(fromResolveTextureId)
            fromResolveFboId = fromFboStatus.first
            if (fromResolveFboId == 0) {
                fail("resolve_fbo_incomplete:from:${fromFboStatus.second}"); return
            }
            val toFboStatus = createFramebufferForTexture(toResolveTextureId)
            toResolveFboId = toFboStatus.first
            if (toResolveFboId == 0) {
                fail("resolve_fbo_incomplete:to:${toFboStatus.second}"); return
            }

            val fromStMatrix = FloatArray(16)
            fromTexture.getTransformMatrix(fromStMatrix)
            val toStMatrix = FloatArray(16)
            toTexture.getTransformMatrix(toStMatrix)

            GLES20.glGetError()
            val fromResolveOk = resolveOesToTexture2d(
                program, aPositionLoc, aTexCoordLoc, uSTMatrixLoc,
                fromTextureId, fromStMatrix, fromResolveFboId,
            )
            val toResolveOk = resolveOesToTexture2d(
                program, aPositionLoc, aTexCoordLoc, uSTMatrixLoc,
                toTextureId, toStMatrix, toResolveFboId,
            )
            gates["bothOesResolveOk"] = fromResolveOk && toResolveOk
            if (gates["bothOesResolveOk"] != true) {
                fail("oes_resolve_failed:from=$fromResolveOk,to=$toResolveOk"); return
            }

            val fromContentEscapedClear = resolvedContentEscapedClear(fromResolveFboId)
            val toContentEscapedClear = resolvedContentEscapedClear(toResolveFboId)
            gates["resolvedContentOk"] = fromContentEscapedClear && toContentEscapedClear
            details["fromResolveEscapedClear"] = fromContentEscapedClear
            details["toResolveEscapedClear"] = toContentEscapedClear
            if (gates["resolvedContentOk"] != true) {
                fail(
                    "resolved_content_uniform_or_sentinel:" +
                        "from=$fromContentEscapedClear,to=$toContentEscapedClear",
                )
                return
            }

            // -- Native dual-OES transition draw + pixel/state proof -----------
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(VanguardDiagnostics()),
                VanguardDiagnostics(),
                null,
            )
            val raw = nativeBridge.drawAndroidDagPhase5GlesDualOesTransition(
                fromResolveTextureId,
                GLES20.GL_TEXTURE_2D,
                toResolveTextureId,
                GLES20.GL_TEXTURE_2D,
                SURFACE_SIZE,
                SURFACE_SIZE,
                TRANSITION_PROGRESS,
                fromPtsUs,
                toPtsUs,
            )
            nativeRaw = raw
            details["nativeRaw"] = raw
            val nativeJson = try { JSONObject(raw) } catch (t: Throwable) { null }
            val nativePass = nativeJson?.optBoolean("pass", false) == true
            gates["nativeTransitionDrawOk"] = nativeJson?.optBoolean("nativeTransitionDrawOk", false) == true
            gates["pixelProofOk"] = nativeJson?.optBoolean("pixelProofOk", false) == true
            gates["stateRestoredOk"] = nativeJson?.optBoolean("stateRestoredOk", false) == true
            if (!nativePass) {
                fail("native_transition_failed:${nativeJson?.optString("failureReason") ?: "unparseable_json"}")
            }
        }

        try {
            executeHarness()
        } catch (t: Throwable) {
            fail("harness_exception:${t.javaClass.simpleName}:${t.message}")
        } finally {
            var cleanupClean = true
            try { fromCodec?.stop() } catch (t: Throwable) { cleanupClean = false }
            try { fromCodec?.release() } catch (t: Throwable) { cleanupClean = false }
            try { toCodec?.stop() } catch (t: Throwable) { cleanupClean = false }
            try { toCodec?.release() } catch (t: Throwable) { cleanupClean = false }
            try { fromInputSurface?.release() } catch (t: Throwable) { cleanupClean = false }
            try { toInputSurface?.release() } catch (t: Throwable) { cleanupClean = false }
            try { fromSurfaceTexture?.setOnFrameAvailableListener(null) } catch (t: Throwable) { cleanupClean = false }
            try { toSurfaceTexture?.setOnFrameAvailableListener(null) } catch (t: Throwable) { cleanupClean = false }
            try { fromSurfaceTexture?.release() } catch (t: Throwable) { cleanupClean = false }
            try { toSurfaceTexture?.release() } catch (t: Throwable) { cleanupClean = false }
            try { fromExtractor?.release() } catch (t: Throwable) { cleanupClean = false }
            try { toExtractor?.release() } catch (t: Throwable) { cleanupClean = false }
            try { handlerThread?.quitSafely() } catch (t: Throwable) { cleanupClean = false }
            if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                try {
                    if (eglContext != EGL14.EGL_NO_CONTEXT) {
                        // Defensive re-assert: nothing else makes another
                        // context current on this thread during the run.
                        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
                    }
                    for (id in intArrayOf(
                        fromTextureId, toTextureId, fromResolveTextureId, toResolveTextureId,
                    )) {
                        if (id != 0) GLES20.glDeleteTextures(1, intArrayOf(id), 0)
                    }
                    for (fbo in intArrayOf(fromResolveFboId, toResolveFboId)) {
                        if (fbo != 0) GLES20.glDeleteFramebuffers(1, intArrayOf(fbo), 0)
                    }
                    if (resolveProgram != 0) GLES20.glDeleteProgram(resolveProgram)
                } catch (t: Throwable) {
                    cleanupClean = false
                }
                try {
                    EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                } catch (t: Throwable) {
                    cleanupClean = false
                }
                try {
                    if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
                } catch (t: Throwable) {
                    cleanupClean = false
                }
                try {
                    if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
                } catch (t: Throwable) {
                    cleanupClean = false
                }
                try { EGL14.eglTerminate(eglDisplay) } catch (t: Throwable) { cleanupClean = false }
            }
            if (!cleanupClean) fail("cleanup_exception")
            gates["cleanupOk"] = cleanupClean
        }

        return buildResult(gates, failureReason, details, glMajorVersion, fromPtsUs, toPtsUs, nativeRaw)
    }

    private fun validateArgs(fromClipPath: String?, toClipPath: String?): String? {
        if (fromClipPath.isNullOrBlank()) return "from_clip_path_empty"
        if (toClipPath.isNullOrBlank()) return "to_clip_path_empty"
        val fromFile = File(fromClipPath)
        if (!fromFile.isFile || !fromFile.canRead()) return "from_clip_not_readable"
        val toFile = File(toClipPath)
        if (!toFile.isFile || !toFile.canRead()) return "to_clip_not_readable"
        return null
    }

    private fun findVideoTrackFormat(extractor: MediaExtractor): MediaFormat? {
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            if (f.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                extractor.selectTrack(i)
                return f
            }
        }
        return null
    }

    private fun createOesTexture(): Int {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        val id = textures[0]
        if (id == 0) return 0
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, id)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        return if (GLES20.glGetError() == GLES20.GL_NO_ERROR) id else 0
    }

    private fun createRgba8Texture(size: Int): Int {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        val id = textures[0]
        if (id == 0) return 0
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, id)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, size, size, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null,
        )
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        return if (GLES20.glGetError() == GLES20.GL_NO_ERROR) id else 0
    }

    /** Returns (fboId, statusOrEmpty); fboId is 0 on any failure. */
    private fun createFramebufferForTexture(textureId: Int): Pair<Int, String> {
        val fbos = IntArray(1)
        GLES20.glGenFramebuffers(1, fbos, 0)
        val fbo = fbos[0]
        if (fbo == 0) return 0 to "fbo_generation_failed"
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        GLES20.glFramebufferTexture2D(
            GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, textureId, 0,
        )
        val status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
        if (status != GLES20.GL_FRAMEBUFFER_COMPLETE) {
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            GLES20.glDeleteFramebuffers(1, intArrayOf(fbo), 0)
            return 0 to "status_0x${Integer.toHexString(status)}"
        }
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        return fbo to ""
    }

    private fun buildOesPassthroughProgram(): Int {
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
        if (vertexShader == 0) return 0
        val fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        if (fragmentShader == 0) return 0

        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vertexShader)
        GLES20.glAttachShader(program, fragmentShader)
        GLES20.glLinkProgram(program)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0)
        GLES20.glDeleteShader(vertexShader)
        GLES20.glDeleteShader(fragmentShader)
        if (linkStatus[0] == 0) {
            GLES20.glDeleteProgram(program)
            return 0
        }
        return program
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, src)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            GLES20.glDeleteShader(shader)
            return 0
        }
        return shader
    }

    /**
     * Draws [oesTextureId] (using [stMatrix] to correct for the
     * SurfaceTexture's sampling transform) into [fboId] as a full-canvas
     * quad. Returns true only if every GL call up to and including the draw
     * reports GL_NO_ERROR.
     */
    private fun resolveOesToTexture2d(
        program: Int,
        aPositionLoc: Int,
        aTexCoordLoc: Int,
        uSTMatrixLoc: Int,
        oesTextureId: Int,
        stMatrix: FloatArray,
        fboId: Int,
    ): Boolean {
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fboId)
        GLES20.glViewport(0, 0, SURFACE_SIZE, SURFACE_SIZE)
        GLES20.glClearColor(
            RESOLVE_CLEAR_R / 255f, RESOLVE_CLEAR_G / 255f, RESOLVE_CLEAR_B / 255f, 1f,
        )
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(program)

        quadPositionBuffer.position(0)
        GLES20.glEnableVertexAttribArray(aPositionLoc)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadPositionBuffer)

        quadTexCoordBuffer.position(0)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoordBuffer)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES20.glUniformMatrix4fv(uSTMatrixLoc, 1, false, stMatrix, 0)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPositionLoc)
        GLES20.glDisableVertexAttribArray(aTexCoordLoc)

        // Leave GL state clean so the native GlesTimelineTransitionCompositor seam that
        // runs immediately after both resolves observes zeroed bindings going in, rather
        // than correctly restoring this harness's own still-live resolve state and
        // failing stateRestoredOk.
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        GLES20.glUseProgram(0)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        GLES20.glFinish()

        return GLES20.glGetError() == GLES20.GL_NO_ERROR
    }

    /**
     * Samples [RESOLVE_SAMPLE_POINTS] from [fboId] and returns true only if
     * every read reports GL_NO_ERROR AND at least one sample escapes the
     * pre-draw clear color beyond [RESOLVE_COLOR_TOLERANCE] -- proof the
     * resolve draw actually painted real decoded content rather than leaving
     * the sentinel/blank clear (or silently failing to read it back).
     */
    private fun resolvedContentEscapedClear(fboId: Int): Boolean {
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fboId)
        GLES20.glGetError()
        var allReadsOk = true
        var escaped = false
        for ((x, y) in RESOLVE_SAMPLE_POINTS) {
            val pixel = readPixelsAt(x, y)
            val readOk = GLES20.glGetError() == GLES20.GL_NO_ERROR
            allReadsOk = allReadsOk && readOk
            if (readOk) {
                val dr = kotlin.math.abs(pixel[0] - RESOLVE_CLEAR_R)
                val dg = kotlin.math.abs(pixel[1] - RESOLVE_CLEAR_G)
                val db = kotlin.math.abs(pixel[2] - RESOLVE_CLEAR_B)
                if (dr > RESOLVE_COLOR_TOLERANCE || dg > RESOLVE_COLOR_TOLERANCE || db > RESOLVE_COLOR_TOLERANCE) {
                    escaped = true
                }
            }
        }
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        return allReadsOk && escaped
    }

    /** Reads one RGBA pixel from the currently-bound read framebuffer. */
    private fun readPixelsAt(x: Int, y: Int): List<Int> {
        val buffer = ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder())
        GLES20.glReadPixels(x, y, 1, 1, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buffer)
        buffer.position(0)
        val out = ArrayList<Int>(4)
        repeat(4) { out.add(buffer.get().toInt() and 0xFF) }
        return out
    }

    private val quadPositionBuffer: FloatBuffer =
        ByteBuffer.allocateDirect(QUAD_POSITIONS.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(QUAD_POSITIONS)
            position(0)
        }
    private val quadTexCoordBuffer: FloatBuffer =
        ByteBuffer.allocateDirect(QUAD_TEX_COORDS.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(QUAD_TEX_COORDS)
            position(0)
        }

    /** Returns (failureReasonOrNull, presentationTimeUsOrMinusOne). */
    private fun decodeOneRenderableFrame(extractor: MediaExtractor, codec: MediaCodec): Pair<String?, Long> {
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        val deadline = System.currentTimeMillis() + DECODE_TIMEOUT_MS
        while (true) {
            if (System.currentTimeMillis() > deadline) return "decode_timeout" to -1L
            if (!inputDone) {
                val inIdx = codec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                if (inIdx >= 0) {
                    val buf = codec.getInputBuffer(inIdx)
                    if (buf == null) {
                        // Fail closed: never leave a dequeued input buffer
                        // index un-queued. Best-effort empty EOS so the
                        // codec's buffer accounting stays consistent even
                        // though we're about to bail out.
                        try {
                            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        } catch (t: Throwable) {
                            // Buffer index already invalid; nothing more to do.
                        }
                        inputDone = true
                        return "input_buffer_null" to -1L
                    }
                    val size = extractor.readSampleData(buf, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }
            val outIdx = codec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
            if (outIdx >= 0) {
                val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                if (info.size > 0) {
                    val pts = info.presentationTimeUs
                    codec.releaseOutputBuffer(outIdx, true)
                    return null to pts
                }
                codec.releaseOutputBuffer(outIdx, false)
                if (isEos) return "no_renderable_frame_before_eos" to -1L
            }
        }
    }

    private fun buildResult(
        gates: Map<String, Boolean>,
        failureReason: String,
        details: Map<String, Any?>,
        glMajorVersion: Int,
        fromPtsUs: Long,
        toPtsUs: Long,
        nativeRaw: String,
    ): Map<String, Any?> {
        val pass = GATE_KEYS.all { gates[it] == true }
        val out = LinkedHashMap<String, Any?>()
        out["pass"] = pass
        out["status"] = if (pass) "PASS" else "FAIL"
        out["marker"] = if (pass) PASS_MARKER else FAIL_MARKER
        out["proofBoundary"] = PROOF_BOUNDARY
        out["failureReason"] = failureReason
        for (key in GATE_KEYS) out[key] = gates[key] == true
        out["glMajorVersion"] = glMajorVersion
        out["fromPtsUs"] = fromPtsUs
        out["toPtsUs"] = toPtsUs
        out["nativeRaw"] = nativeRaw
        out["details"] = details
        return out
    }
}
