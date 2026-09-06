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
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/**
 * P5-GLES-EXPORT-DUAL-OES-TRANSITION-READINESS: diagnostic-only harness
 * proving that TWO real MediaCodec decodes, each feeding its own
 * SurfaceTexture-backed GL_TEXTURE_EXTERNAL_OES texture on ONE caller-owned,
 * current-verified ES3 EGL pbuffer context, still route into the private
 * `GlesTimelineTransitionCompositor::drawTransition` seam (fixed crossfade
 * midpoint: progress 0.5, blendWeightFrom == blendWeightTo == 0.5, identity
 * crops/viewports) through
 * [VanguardNativeBridge.drawAndroidDagPhase5GlesDualOesTransition].
 *
 * Every EGL/GL/MediaCodec/SurfaceTexture object is created and destroyed by
 * this harness on the single background thread that calls [run]; the native
 * seam creates/destroys none of them and only draws into the already-current
 * context using the two already-populated OES textures. Diagnostic only: no
 * production GLES export route, no AndroidTimelineExportSession/
 * AndroidTimelineVideoEncoder/AndroidExportRenderBackendSelector change, and
 * `GlesTimelineTransitionCompositor` itself is untouched.
 */
class AndroidGlesDualOesTransitionSmokeHarness {

    companion object {
        private const val PROOF_BOUNDARY =
            "diagnostic_dual_mediacodec_surfacetexture_oes_to_gles_transition_compositor_no_export"
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

        val GATE_KEYS = listOf(
            "argumentValidationOk",
            "eglSetupOk",
            "es3ContextVerifiedOk",
            "dualDecoderSetupOk",
            "bothFramesAvailableOk",
            "bothUpdateTexImageOk",
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

            // -- Native dual-OES transition draw + pixel/state proof -----------
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(VanguardDiagnostics()),
                VanguardDiagnostics(),
                null,
            )
            val raw = nativeBridge.drawAndroidDagPhase5GlesDualOesTransition(
                fromTextureId,
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                toTextureId,
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
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
                    for (id in intArrayOf(fromTextureId, toTextureId)) {
                        if (id != 0) GLES20.glDeleteTextures(1, intArrayOf(id), 0)
                    }
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
