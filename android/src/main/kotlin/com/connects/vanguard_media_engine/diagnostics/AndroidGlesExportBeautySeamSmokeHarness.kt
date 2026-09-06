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
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/**
 * P5-GLES-EXPORT-OES-2D-BEAUTY-RESOLVE-READINESS: diagnostic-only harness
 * proving a REAL MediaCodec decode -> SurfaceTexture ->
 * GL_TEXTURE_EXTERNAL_OES frame, resolved on its own current-verified ES3
 * EGL pbuffer context to a GL_TEXTURE_2D RGBA8 raster via an FBO blit, still
 * routes into the caller-current native `GlesBeautyV2Compositor::
 * DrawBeautyV2` seam through
 * [VanguardNativeBridge.drawAndroidDagPhase5GlesExportBeautySeam].
 *
 * Every EGL/GL/MediaCodec/SurfaceTexture object is created and destroyed by
 * this harness on the single background thread that calls [run]; the native
 * seam creates/destroys none of them and only draws into the already-current
 * context. The context's ES3-ness is asserted directly (GL_MAJOR_VERSION
 * query, no GL error) right after it becomes current, rather than via a
 * separate ES2-context negative lane. Diagnostic only: no production GLES
 * Beauty export route, and `GlesBeautyV2Compositor` itself is untouched.
 */
class AndroidGlesExportBeautySeamSmokeHarness {

    companion object {
        private const val PROOF_BOUNDARY =
            "native_gles_export_beauty_seam_caller_current_context_diagnostic_only_no_production_export"
        private const val PASS_MARKER =
            "ANDROID_DAG_PHASE5_GLES_EXPORT_BEAUTY_SEAM_PHYSICAL_SMOKE_PASS"
        private const val FAIL_MARKER =
            "ANDROID_DAG_PHASE5_GLES_EXPORT_BEAUTY_SEAM_PHYSICAL_SMOKE_FAIL"

        private const val SURFACE_SIZE = 128
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val DECODE_TIMEOUT_MS = 5_000L
        private const val FRAME_AVAILABLE_TIMEOUT_MS = 3_000L

        private const val DEFAULT_INTENSITY = 0.5f
        private const val STRONG_INTENSITY = 1.0f

        // Corner + center probes across the resolved raster, chosen to catch
        // real decoded-frame variation rather than a synthetically drawn
        // shape's inside/outside boundary.
        private val SAMPLE_POINTS = listOf(8 to 8, 64 to 64, 120 to 120)

        private val GATE_KEYS = listOf(
            "eglSetupOk",
            "es3ContextVerifiedOk",
            "invalidArgumentsRejectedOk",
            "decodeOk",
            "updateTexImageOk",
            "oesResolveOk",
            "resolvedNonUniformOk",
            "seamCallOk",
            "beautyDeltaOk",
            "strongIntensityDeltaOk",
            "stateRestoredOk",
            "cleanupOk",
            "canonical",
        )

        private val QUAD_POSITIONS = floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
        private val QUAD_TEX_COORDS = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)
    }

    private data class GlCallState(
        val viewport: IntArray,
        val program: Int,
        val framebuffer: Int,
        val activeTexture: Int,
        val tex2d: Int,
        val texOes: Int,
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is GlCallState) return false
            return viewport.contentEquals(other.viewport) &&
                program == other.program &&
                framebuffer == other.framebuffer &&
                activeTexture == other.activeTexture &&
                tex2d == other.tex2d &&
                texOes == other.texOes
        }

        override fun hashCode(): Int {
            var result = viewport.contentHashCode()
            result = 31 * result + program
            result = 31 * result + framebuffer
            result = 31 * result + activeTexture
            result = 31 * result + tex2d
            result = 31 * result + texOes
            return result
        }
    }

    /** Runs the full seam proof for [videoPath]. Never throws. */
    fun run(videoPath: String?): Map<String, Any?> {
        val gates = linkedMapOf<String, Boolean>()
        for (key in GATE_KEYS) gates[key] = false
        val details = linkedMapOf<String, Any?>()
        var failureReason = ""
        fun fail(reason: String) {
            if (failureReason.isEmpty()) failureReason = reason
        }

        if (videoPath.isNullOrEmpty()) {
            fail("invalid_arguments_video_path_required")
            return buildResult(gates, failureReason, details)
        }

        var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
        var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
        var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
        var oesTextureId = 0
        var resolveTextureId = 0
        var resolveFboId = 0
        var beautyDefaultTextureId = 0
        var beautyDefaultFboId = 0
        var beautyStrongTextureId = 0
        var beautyStrongFboId = 0
        var glProgram = 0
        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
        var handlerThread: HandlerThread? = null
        var surfaceTexture: SurfaceTexture? = null
        var codecInputSurface: Surface? = null
        val frameAvailable = Semaphore(0)

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

            // -- ES3 current-context assertion: the EGL_CONTEXT_CLIENT_VERSION
            //    request is advisory on some devices/drivers, so prove the
            //    context now current on this thread is truly ES3-capable by
            //    querying GL_MAJOR_VERSION and confirming no GL error and
            //    major >= 3, rather than trusting the request alone. --------
            GLES20.glGetError()
            val majorVersion = IntArray(1)
            GLES20.glGetIntegerv(GLES30.GL_MAJOR_VERSION, majorVersion, 0)
            val majorVersionQueryError = GLES20.glGetError()
            val es3ContextVerified =
                majorVersionQueryError == GLES20.GL_NO_ERROR && majorVersion[0] >= 3
            details["glMajorVersion"] = majorVersion[0]
            details["es3ContextDetails"] =
                "glMajorVersion=${majorVersion[0]}," +
                    "majorVersionQueryError=0x${Integer.toHexString(majorVersionQueryError)}"
            gates["es3ContextVerifiedOk"] = es3ContextVerified
            if (!es3ContextVerified) {
                fail("context_not_es3"); return
            }

            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            oesTextureId = textures[0]
            if (oesTextureId == 0) {
                fail("oes_texture_creation_failed"); return
            }
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

            val program = buildOesPassthroughProgram()
            if (program <= 0) {
                fail("gl_program_link_failed"); return
            }
            glProgram = program
            val aPositionLoc = GLES20.glGetAttribLocation(program, "aPosition")
            val aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTextureCoord")
            val uSTMatrixLoc = GLES20.glGetUniformLocation(program, "uSTMatrix")

            resolveTextureId = createRgba8Texture(SURFACE_SIZE)
            if (resolveTextureId == 0) {
                fail("resolve_texture_creation_failed"); return
            }
            val resolveFboStatus = createFramebufferForTexture(resolveTextureId)
            resolveFboId = resolveFboStatus.first
            if (resolveFboId == 0) {
                fail("resolve_fbo_incomplete:${resolveFboStatus.second}"); return
            }

            beautyDefaultTextureId = createRgba8Texture(SURFACE_SIZE)
            beautyStrongTextureId = createRgba8Texture(SURFACE_SIZE)
            if (beautyDefaultTextureId == 0 || beautyStrongTextureId == 0) {
                fail("beauty_target_texture_creation_failed"); return
            }
            val beautyDefaultFboStatus = createFramebufferForTexture(beautyDefaultTextureId)
            beautyDefaultFboId = beautyDefaultFboStatus.first
            if (beautyDefaultFboId == 0) {
                fail("beauty_default_fbo_incomplete:${beautyDefaultFboStatus.second}"); return
            }
            val beautyStrongFboStatus = createFramebufferForTexture(beautyStrongTextureId)
            beautyStrongFboId = beautyStrongFboStatus.first
            if (beautyStrongFboId == 0) {
                fail("beauty_strong_fbo_incomplete:${beautyStrongFboStatus.second}"); return
            }

            gates["eglSetupOk"] = true

            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(VanguardDiagnostics()),
                VanguardDiagnostics(),
                null,
            )

            // -- Invalid-argument probes: prove the seam fails closed before
            //    touching any of the real decode/draw state. ------------------
            run {
                val badDims = nativeBridge.drawAndroidDagPhase5GlesExportBeautySeam(
                    resolveTextureId, resolveFboId, 0, SURFACE_SIZE, DEFAULT_INTENSITY,
                )
                val badTexture = nativeBridge.drawAndroidDagPhase5GlesExportBeautySeam(
                    0, resolveFboId, SURFACE_SIZE, SURFACE_SIZE, DEFAULT_INTENSITY,
                )
                val badFbo = nativeBridge.drawAndroidDagPhase5GlesExportBeautySeam(
                    resolveTextureId, -1, SURFACE_SIZE, SURFACE_SIZE, DEFAULT_INTENSITY,
                )
                val badIntensity = nativeBridge.drawAndroidDagPhase5GlesExportBeautySeam(
                    resolveTextureId, resolveFboId, SURFACE_SIZE, SURFACE_SIZE, 1.5f,
                )
                val badIntensityNaN = nativeBridge.drawAndroidDagPhase5GlesExportBeautySeam(
                    resolveTextureId, resolveFboId, SURFACE_SIZE, SURFACE_SIZE, Float.NaN,
                )
                val allRejected = isRejected(badDims) && isRejected(badTexture) &&
                    isRejected(badFbo) && isRejected(badIntensity) && isRejected(badIntensityNaN)
                gates["invalidArgumentsRejectedOk"] = allRejected
                details["invalidArgumentsProbe"] =
                    listOf(badDims, badTexture, badFbo, badIntensity, badIntensityNaN)
                if (!allRejected) fail("invalid_arguments_not_rejected")
            }

            // -- Real decode: MediaCodec -> SurfaceTexture(oesTextureId). ----
            val ext = MediaExtractor()
            extractor = ext
            ext.setDataSource(videoPath)
            var trackIndex = -1
            var trackFormat: MediaFormat? = null
            for (i in 0 until ext.trackCount) {
                val f = ext.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                    trackIndex = i
                    trackFormat = f
                    break
                }
            }
            if (trackIndex < 0 || trackFormat == null) {
                fail("no_video_track"); return
            }
            ext.selectTrack(trackIndex)

            val thread = HandlerThread("vanguard-p5-gles-export-beauty-seam-frame-listener").also { it.start() }
            handlerThread = thread
            val listenerHandler = Handler(thread.looper)
            val texture = SurfaceTexture(oesTextureId)
            surfaceTexture = texture
            texture.setDefaultBufferSize(SURFACE_SIZE, SURFACE_SIZE)
            texture.setOnFrameAvailableListener({ frameAvailable.release() }, listenerHandler)
            val inputSurface = Surface(texture)
            codecInputSurface = inputSurface

            val mime = trackFormat.getString(MediaFormat.KEY_MIME)!!
            val dec = MediaCodec.createDecoderByType(mime)
            dec.configure(trackFormat, inputSurface, null, 0)
            dec.start()
            codec = dec

            val decodeError = decodeOneRenderableFrame(ext, dec)
            if (decodeError != null) {
                fail(decodeError); return
            }
            gates["decodeOk"] = true

            if (!frameAvailable.tryAcquire(FRAME_AVAILABLE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                fail("frame_available_timeout"); return
            }
            texture.updateTexImage()
            gates["updateTexImageOk"] = true

            // -- OES -> 2D resolve: draw the decoded OES texture into the
            //    RGBA8 resolve FBO via the minimal external-OES passthrough
            //    shader using the SurfaceTexture transform matrix. ----------
            val stMatrix = FloatArray(16)
            texture.getTransformMatrix(stMatrix)

            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, resolveFboId)
            GLES20.glViewport(0, 0, SURFACE_SIZE, SURFACE_SIZE)
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            GLES20.glUseProgram(glProgram)

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
            GLES20.glFinish()

            if (GLES20.glGetError() != GLES20.GL_NO_ERROR) {
                fail("oes_resolve_gl_error"); return
            }
            gates["oesResolveOk"] = true

            // -- Prove the resolved 2D texture is non-uniform (real decoded
            //    content, not a flat clear color) before running Beauty. -----
            val beforeBeautySamples = SAMPLE_POINTS.map { (x, y) -> readPixelsAt(x, y) }
            val nonUniform = beforeBeautySamples.toSet().size > 1
            gates["resolvedNonUniformOk"] = nonUniform
            details["beforeBeautyRgba"] = beforeBeautySamples.map { it.joinToString(",") }
            if (!nonUniform) fail("resolved_texture_uniform")

            // -- Default-intensity Beauty draw + native seam call. ------------
            val stateBeforeDefault = captureGlCallState()
            val seamDefaultRaw = nativeBridge.drawAndroidDagPhase5GlesExportBeautySeam(
                resolveTextureId, beautyDefaultFboId, SURFACE_SIZE, SURFACE_SIZE, DEFAULT_INTENSITY,
            )
            val stateAfterDefault = captureGlCallState()
            val glErrorAfterDefault = GLES20.glGetError()
            details["seamDefaultRaw"] = seamDefaultRaw
            val seamDefaultJson = try { JSONObject(seamDefaultRaw) } catch (t: Throwable) { null }
            val seamDefaultPass = seamDefaultJson?.optBoolean("pass", false) == true
            if (!seamDefaultPass) {
                fail("seam_call_failed:${seamDefaultJson?.optString("failureReason") ?: "unparseable_json"}")
                return
            }

            // -- Strong-intensity Beauty draw + native seam call. -------------
            val stateBeforeStrong = captureGlCallState()
            val seamStrongRaw = nativeBridge.drawAndroidDagPhase5GlesExportBeautySeam(
                resolveTextureId, beautyStrongFboId, SURFACE_SIZE, SURFACE_SIZE, STRONG_INTENSITY,
            )
            val stateAfterStrong = captureGlCallState()
            val glErrorAfterStrong = GLES20.glGetError()
            details["seamStrongRaw"] = seamStrongRaw
            val seamStrongJson = try { JSONObject(seamStrongRaw) } catch (t: Throwable) { null }
            val seamStrongPass = seamStrongJson?.optBoolean("pass", false) == true
            if (!seamStrongPass) {
                fail("seam_call_failed:${seamStrongJson?.optString("failureReason") ?: "unparseable_json"}")
                return
            }

            gates["seamCallOk"] = seamDefaultPass && seamStrongPass

            gates["stateRestoredOk"] = stateBeforeDefault == stateAfterDefault &&
                stateBeforeStrong == stateAfterStrong &&
                glErrorAfterDefault == GLES20.GL_NO_ERROR &&
                glErrorAfterStrong == GLES20.GL_NO_ERROR
            if (!gates["stateRestoredOk"]!!) fail("gl_state_not_restored")

            // -- Composite proof: Beauty output must differ from the
            //    un-beautified resolved frame at every sample point, and the
            //    strong-intensity variant must differ MORE than default. -----
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, beautyDefaultFboId)
            val afterDefaultSamples = SAMPLE_POINTS.map { (x, y) -> readPixelsAt(x, y) }
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, beautyStrongFboId)
            val afterStrongSamples = SAMPLE_POINTS.map { (x, y) -> readPixelsAt(x, y) }
            details["afterDefaultBeautyRgba"] = afterDefaultSamples.map { it.joinToString(",") }
            details["afterStrongBeautyRgba"] = afterStrongSamples.map { it.joinToString(",") }

            val defaultDiffersAtEveryPoint = beforeBeautySamples.indices.all { i ->
                beforeBeautySamples[i] != afterDefaultSamples[i]
            }
            gates["beautyDeltaOk"] = defaultDiffersAtEveryPoint
            if (!defaultDiffersAtEveryPoint) fail("beauty_output_did_not_differ_from_unbeautified_frame")

            val defaultTotalDelta = totalL1Delta(beforeBeautySamples, afterDefaultSamples)
            val strongTotalDelta = totalL1Delta(beforeBeautySamples, afterStrongSamples)
            details["defaultTotalDelta"] = defaultTotalDelta
            details["strongTotalDelta"] = strongTotalDelta
            val strongDeltaLarger = strongTotalDelta > defaultTotalDelta
            gates["strongIntensityDeltaOk"] = strongDeltaLarger
            if (!strongDeltaLarger) fail("strong_intensity_delta_not_larger_than_default")
        }

        try {
            executeHarness()
        } catch (t: Throwable) {
            fail("harness_exception:${t.javaClass.simpleName}:${t.message}")
        } finally {
            var cleanupClean = true
            try { codec?.stop() } catch (t: Throwable) { cleanupClean = false }
            try { codec?.release() } catch (t: Throwable) { cleanupClean = false }
            try { codecInputSurface?.release() } catch (t: Throwable) { cleanupClean = false }
            try { surfaceTexture?.setOnFrameAvailableListener(null) } catch (t: Throwable) { cleanupClean = false }
            try { surfaceTexture?.release() } catch (t: Throwable) { cleanupClean = false }
            try { extractor?.release() } catch (t: Throwable) { cleanupClean = false }
            try { handlerThread?.quitSafely() } catch (t: Throwable) { cleanupClean = false }
            if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                try {
                    if (eglContext != EGL14.EGL_NO_CONTEXT) {
                        // Ensure the ES3 context is current before deleting
                        // its GL objects (defensive re-assert; nothing else
                        // makes another context current during the run).
                        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
                    }
                    for (id in intArrayOf(
                        oesTextureId, resolveTextureId, beautyDefaultTextureId, beautyStrongTextureId,
                    )) {
                        if (id != 0) GLES20.glDeleteTextures(1, intArrayOf(id), 0)
                    }
                    for (fbo in intArrayOf(resolveFboId, beautyDefaultFboId, beautyStrongFboId)) {
                        if (fbo != 0) GLES20.glDeleteFramebuffers(1, intArrayOf(fbo), 0)
                    }
                    if (glProgram != 0) GLES20.glDeleteProgram(glProgram)
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

        gates["canonical"] = gates.filterKeys { it != "canonical" }.values.all { it } && failureReason.isEmpty()
        return buildResult(gates, failureReason, details)
    }

    private fun decodeOneRenderableFrame(extractor: MediaExtractor, codec: MediaCodec): String? {
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        val deadline = System.currentTimeMillis() + DECODE_TIMEOUT_MS
        while (true) {
            if (System.currentTimeMillis() > deadline) return "decode_timeout"
            if (!inputDone) {
                val inIdx = codec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                if (inIdx >= 0) {
                    val buf = codec.getInputBuffer(inIdx)
                    if (buf != null) {
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
            }
            val outIdx = codec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
            if (outIdx >= 0) {
                val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                if (info.size > 0) {
                    codec.releaseOutputBuffer(outIdx, true)
                    return null
                }
                codec.releaseOutputBuffer(outIdx, false)
                if (isEos) return "no_renderable_frame_before_eos"
            }
        }
    }

    private fun isRejected(raw: String): Boolean = try {
        val json = JSONObject(raw)
        json.optBoolean("pass", true) == false && json.optString("failureReason", "").isNotEmpty()
    } catch (t: Throwable) {
        false
    }

    private fun captureGlCallState(): GlCallState {
        val viewport = IntArray(4).also { GLES20.glGetIntegerv(GLES20.GL_VIEWPORT, it, 0) }
        val program = IntArray(1).also { GLES20.glGetIntegerv(GLES20.GL_CURRENT_PROGRAM, it, 0) }
        val framebuffer = IntArray(1).also { GLES20.glGetIntegerv(GLES20.GL_FRAMEBUFFER_BINDING, it, 0) }
        val activeTexture = IntArray(1).also { GLES20.glGetIntegerv(GLES20.GL_ACTIVE_TEXTURE, it, 0) }
        val tex2d = IntArray(1).also { GLES20.glGetIntegerv(GLES20.GL_TEXTURE_BINDING_2D, it, 0) }
        val texOes = IntArray(1).also { GLES20.glGetIntegerv(GLES11Ext.GL_TEXTURE_BINDING_EXTERNAL_OES, it, 0) }
        return GlCallState(viewport, program[0], framebuffer[0], activeTexture[0], tex2d[0], texOes[0])
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

    private fun totalL1Delta(before: List<List<Int>>, after: List<List<Int>>): Int {
        var total = 0
        for (i in before.indices) {
            for (c in before[i].indices) {
                total += kotlin.math.abs(before[i][c] - after[i][c])
            }
        }
        return total
    }

    private fun createRgba8Texture(size: Int): Int {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        val id = textures[0]
        if (id == 0) return 0
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, id)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
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

    private fun buildResult(
        gates: Map<String, Boolean>,
        failureReason: String,
        details: Map<String, Any?>,
    ): Map<String, Any?> {
        val pass = gates["canonical"] == true
        val out = LinkedHashMap<String, Any?>()
        out["pass"] = pass
        out["status"] = if (pass) "PASS" else "FAIL"
        out["marker"] = if (pass) PASS_MARKER else FAIL_MARKER
        out["proofBoundary"] = PROOF_BOUNDARY
        out["failureReason"] = failureReason
        for ((key, value) in gates) out[key] = value
        out["details"] = details
        return out
    }
}
