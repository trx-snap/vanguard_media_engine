package com.connects.vanguard_media_engine.diagnostics

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
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
 * P5-GLES-EXPORT-OVERLAY-SEAM-A: diagnostic-only harness proving a REAL
 * MediaCodec decode -> SurfaceTexture -> GL_TEXTURE_EXTERNAL_OES frame,
 * drawn on its own ES2 EGL pbuffer context exactly like
 * AndroidTimelineVideoEncoder.kt's decode/OES/EGL lifecycle, still routes
 * into the caller-current native `GlesOverlayCompositor::drawOverlays` seam
 * through [VanguardNativeBridge.drawAndroidDagPhase5GlesExportOverlaySeam].
 *
 * Every EGL/GL/MediaCodec/SurfaceTexture object is created and destroyed by
 * this harness on the single background thread that calls [run]; the native
 * seam creates/destroys none of them and only draws into the already-current
 * context. Diagnostic only: no production export/session/backend-selector/
 * encoder change, and `GlesOverlayCompositor` itself is untouched.
 */
class AndroidGlesExportOverlaySeamSmokeHarness {

    companion object {
        private const val PROOF_BOUNDARY =
            "native_gles_export_overlay_seam_caller_current_context_diagnostic_only_no_production_export"
        private const val PASS_MARKER =
            "ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_SEAM_PHYSICAL_SMOKE_PASS"
        private const val FAIL_MARKER =
            "ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_SEAM_PHYSICAL_SMOKE_FAIL"

        private const val SURFACE_SIZE = 128
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val DECODE_TIMEOUT_MS = 5_000L
        private const val FRAME_AVAILABLE_TIMEOUT_MS = 3_000L

        // Overlay layer geometry: a 64x64 quarter of the 128x128 canvas,
        // top-left origin / Y-down, matching GlesOverlayLayerDescriptor's
        // documented convention.
        private const val OVERLAY_X = 32.0
        private const val OVERLAY_Y = 32.0
        private const val OVERLAY_SIZE = 64.0
        private const val OVERLAY_OPACITY = 0.5

        private val OUTSIDE_PROBE = 4 to 4
        private val INSIDE_PROBE =
            (OVERLAY_X + OVERLAY_SIZE / 2).toInt() to (OVERLAY_Y + OVERLAY_SIZE / 2).toInt()

        private val GATE_KEYS = listOf(
            "eglSetupOk",
            "invalidArgumentsRejectedOk",
            "decodeOk",
            "updateTexImageOk",
            "baseDrawOk",
            "seamCallOk",
            "compositeAssertionOk",
            "stateRestoredOk",
            "cleanupOk",
            "canonical",
        )

        private val QUAD_POSITIONS = floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
        private val QUAD_TEX_COORDS = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)
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
        var overlayTextureId = 0
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
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfigs = IntArray(1)
            if (!EGL14.eglChooseConfig(eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0) ||
                numConfigs[0] < 1
            ) {
                fail("egl_choose_config_failed"); return
            }
            val config = configs[0]
            if (config == null) {
                fail("egl_choose_config_failed"); return
            }

            val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
            eglContext = EGL14.eglCreateContext(eglDisplay, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
            if (eglContext == EGL14.EGL_NO_CONTEXT) {
                fail("egl_create_context_failed"); return
            }
            val pbufferAttribs = intArrayOf(
                EGL14.EGL_WIDTH, SURFACE_SIZE,
                EGL14.EGL_HEIGHT, SURFACE_SIZE,
                EGL14.EGL_NONE,
            )
            eglSurface = EGL14.eglCreatePbufferSurface(eglDisplay, config, pbufferAttribs, 0)
            if (eglSurface == EGL14.EGL_NO_SURFACE) {
                fail("egl_create_pbuffer_surface_failed"); return
            }
            if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
                fail("egl_make_current_failed"); return
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

            overlayTextureId = createSolidOverlayTexture()
            if (overlayTextureId == 0) {
                fail("overlay_texture_creation_failed"); return
            }

            gates["eglSetupOk"] = true

            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(VanguardDiagnostics()),
                VanguardDiagnostics(),
                null,
            )

            // -- Invalid-argument probes: prove the seam fails closed before
            //    touching any of the real decode/draw state. -----------------
            run {
                val badNullArrays = nativeBridge.drawAndroidDagPhase5GlesExportOverlaySeam(
                    null, null, null, null, 1, SURFACE_SIZE, SURFACE_SIZE,
                )
                val badGeometryLength = nativeBridge.drawAndroidDagPhase5GlesExportOverlaySeam(
                    intArrayOf(overlayTextureId),
                    intArrayOf(GLES20.GL_TEXTURE_2D),
                    doubleArrayOf(0.0, 0.0, 10.0, 10.0),
                    intArrayOf(0),
                    1,
                    SURFACE_SIZE,
                    SURFACE_SIZE,
                )
                val badSurfaceDimensions = nativeBridge.drawAndroidDagPhase5GlesExportOverlaySeam(
                    null, null, null, null, 0, 0, SURFACE_SIZE,
                )
                val allRejected = isRejected(badNullArrays) && isRejected(badGeometryLength) &&
                    isRejected(badSurfaceDimensions)
                gates["invalidArgumentsRejectedOk"] = allRejected
                details["invalidArgumentsProbe"] = listOf(badNullArrays, badGeometryLength, badSurfaceDimensions)
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

            val thread = HandlerThread("vanguard-p5-gles-export-overlay-seam-frame-listener").also { it.start() }
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

            // -- Base draw: decoded OES texture -> pbuffer, via the minimal
            //    external-OES passthrough shader using the SurfaceTexture
            //    transform matrix. ----------------------------------------
            val stMatrix = FloatArray(16)
            texture.getTransformMatrix(stMatrix)

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
                fail("base_draw_gl_error"); return
            }
            gates["baseDrawOk"] = true

            // -- Composite proof: read pixels before/after the seam call at
            //    an inside-overlay and an outside-overlay probe point. ------
            val beforeOutside = readPixelCanvas(OUTSIDE_PROBE.first, OUTSIDE_PROBE.second)
            val beforeInside = readPixelCanvas(INSIDE_PROBE.first, INSIDE_PROBE.second)

            val vpBefore = IntArray(4).also { GLES20.glGetIntegerv(GLES20.GL_VIEWPORT, it, 0) }
            val programBefore = IntArray(1).also { GLES20.glGetIntegerv(GLES20.GL_CURRENT_PROGRAM, it, 0) }
            val blendBefore = GLES20.glIsEnabled(GLES20.GL_BLEND)
            val activeTexBefore = IntArray(1).also { GLES20.glGetIntegerv(GLES20.GL_ACTIVE_TEXTURE, it, 0) }
            val tex2dBefore = IntArray(1).also { GLES20.glGetIntegerv(GLES20.GL_TEXTURE_BINDING_2D, it, 0) }
            val texOesBefore =
                IntArray(1).also { GLES20.glGetIntegerv(GLES11Ext.GL_TEXTURE_BINDING_EXTERNAL_OES, it, 0) }

            val geometry = doubleArrayOf(
                OVERLAY_X, OVERLAY_Y, OVERLAY_SIZE, OVERLAY_SIZE, 0.0, 1.0, OVERLAY_OPACITY,
            )
            val seamRaw = nativeBridge.drawAndroidDagPhase5GlesExportOverlaySeam(
                intArrayOf(overlayTextureId),
                intArrayOf(GLES20.GL_TEXTURE_2D),
                geometry,
                intArrayOf(0),
                1,
                SURFACE_SIZE,
                SURFACE_SIZE,
            )
            details["seamRaw"] = seamRaw
            val seamJson = try {
                JSONObject(seamRaw)
            } catch (t: Throwable) {
                null
            }
            val seamPass = seamJson?.optBoolean("pass", false) == true
            gates["seamCallOk"] = seamPass
            if (!seamPass) {
                fail("seam_call_failed:${seamJson?.optString("failureReason") ?: "unparseable_json"}")
                return
            }

            val afterOutside = readPixelCanvas(OUTSIDE_PROBE.first, OUTSIDE_PROBE.second)
            val afterInside = readPixelCanvas(INSIDE_PROBE.first, INSIDE_PROBE.second)
            details["beforeOutsideRgba"] = beforeOutside.joinToString(",")
            details["afterOutsideRgba"] = afterOutside.joinToString(",")
            details["beforeInsideRgba"] = beforeInside.joinToString(",")
            details["afterInsideRgba"] = afterInside.joinToString(",")

            val outsideUnchanged = beforeOutside.contentEquals(afterOutside)
            val insideChanged = !beforeInside.contentEquals(afterInside)
            gates["compositeAssertionOk"] = outsideUnchanged && insideChanged
            if (!(outsideUnchanged && insideChanged)) fail("composite_assertion_failed")

            val vpAfter = IntArray(4).also { GLES20.glGetIntegerv(GLES20.GL_VIEWPORT, it, 0) }
            val programAfter = IntArray(1).also { GLES20.glGetIntegerv(GLES20.GL_CURRENT_PROGRAM, it, 0) }
            val blendAfter = GLES20.glIsEnabled(GLES20.GL_BLEND)
            val activeTexAfter = IntArray(1).also { GLES20.glGetIntegerv(GLES20.GL_ACTIVE_TEXTURE, it, 0) }
            val tex2dAfter = IntArray(1).also { GLES20.glGetIntegerv(GLES20.GL_TEXTURE_BINDING_2D, it, 0) }
            val texOesAfter =
                IntArray(1).also { GLES20.glGetIntegerv(GLES11Ext.GL_TEXTURE_BINDING_EXTERNAL_OES, it, 0) }

            val stateRestored = vpBefore.contentEquals(vpAfter) &&
                programBefore[0] == programAfter[0] &&
                blendBefore == blendAfter &&
                activeTexBefore[0] == activeTexAfter[0] &&
                tex2dBefore[0] == tex2dAfter[0] &&
                texOesBefore[0] == texOesAfter[0]
            gates["stateRestoredOk"] = stateRestored
            if (!stateRestored) fail("gl_state_not_restored")
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
                    if (overlayTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(overlayTextureId), 0)
                    if (oesTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(oesTextureId), 0)
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

    private fun readPixelCanvas(canvasX: Int, canvasY: Int): ByteArray {
        // GlesOverlayLayerDescriptor's x/y are top-left-origin, Y-down canvas
        // pixels; glReadPixels row 0 is the bottom of the framebuffer.
        val glY = SURFACE_SIZE - 1 - canvasY
        val buffer = ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder())
        GLES20.glReadPixels(canvasX, glY, 1, 1, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buffer)
        buffer.position(0)
        val out = ByteArray(4)
        buffer.get(out)
        return out
    }

    private fun createSolidOverlayTexture(): Int {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        val id = textures[0]
        if (id == 0) return 0
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, id)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        // Semi-transparent solid red (straight alpha ~0.5).
        val pixel = ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder())
        pixel.put(byteArrayOf(255.toByte(), 0, 0, 128.toByte()))
        pixel.position(0)
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, 1, 1, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pixel,
        )
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        return if (GLES20.glGetError() == GLES20.GL_NO_ERROR) id else 0
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
