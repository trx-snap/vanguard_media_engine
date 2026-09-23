package com.connects.vanguard_media_engine.duet

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLES30
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.export.AndroidTimelineGlesOverlayRenderSession
import com.connects.vanguard_media_engine.export.AndroidTimelineOverlayDescriptor
import com.connects.vanguard_media_engine.export.AndroidTimelineVideoEncoder
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.ceil
import kotlin.math.roundToInt

// ─────────────────────────────────────────────────────────────────────────────
// VG-DUET-SLICE-4B: Android real-take offline Duet compositor (video pass only).
// ─────────────────────────────────────────────────────────────────────────────
//
// Self-contained GLES + MediaCodec encoder for the real-take Duet export route
// owned by [AndroidDuetExportSession]. Two independent MediaExtractor +
// MediaCodec video decoders (the trimmed source video and the recorded camera
// segment) each feed their own SurfaceTexture-backed GL_TEXTURE_EXTERNAL_OES
// slot; every output frame aspect-fills the source into its layout rect,
// then the camera into its rect, then composites any creator overlays on top
// via [AndroidTimelineGlesOverlayRenderSession], and submits the frame to an
// AVC surface-input encoder muxed into an MP4 at [outputPath].
//
// Claims:
//   - Fixed output frame clock: frame i has ptsUs = i * 1_000_000 / fps; the
//     EGL presentation time and the muxed sample time both derive from it.
//   - Per-frame decode targeting: the source is sampled at
//     trimStart + t, the camera segment at t. Each side renders the latest
//     decoded frame at or before its target; a side that reaches end-of-
//     stream after producing at least one frame holds its last frame (never
//     blacks out); a side that cannot produce any frame fails the encode.
//   - Orientation: each decoder is configured with its unmodified track
//     format and renders into a SurfaceTexture, exactly like
//     AndroidTimelineVideoEncoder's clip decoder. Texture coordinates stay
//     unrotated and the SurfaceTexture transform matrix remains the only
//     texture-space transform; the caller-supplied normalized clockwise
//     0/90/180/270 rotation is applied in output vertex space
//     (computeLayerGeometry -> drawLayer), mirroring that proven export
//     path's updateClipGeometry: the decoded width/height are swapped for
//     90/270 to size the aspect-fill viewport and the drawn quad is rotated
//     by the negated angle, so rotated inputs are neither sideways nor
//     stretched.
//   - Every MediaCodec/MediaExtractor/Surface/SurfaceTexture/EGL/GL/MediaMuxer
//     resource is released in `finally`; every wait is bounded.
//
// Non-claims: no audio (the session runs the audio pass-2 muxer over this
// pass's output), no Vulkan, no speed remap, no green-screen matte.
class AndroidDuetOfflineCompositorVideoEncoder(
    private val outputPath: String,
    private val width: Int,
    private val height: Int,
    private val fps: Int,
    private val bitrateBps: Int,
    // Required only when the encode call carries creator overlays; the
    // overlay session draws through its production native seam.
    private val nativeBridge: VanguardNativeBridge?,
) {

    /** One decoded video layer: which file, where in it t=0 lands, and its display rotation. */
    data class VideoInput(
        val label: String,
        val sourcePath: String,
        /** Source-file time (seconds) that maps to output timeline t = 0. */
        val startOffsetSeconds: Double,
        /** Normalized clockwise display rotation: 0, 90, 180, or 270. */
        val rotationDegrees: Int,
        /** Probed decoded size hint; used only when the track format carries no size. */
        val hintWidth: Int,
        val hintHeight: Int,
    )

    @Volatile private var cancelRequested = false

    /** Signals the encode loop to stop feeding new frames. Thread-safe. */
    fun cancel() { cancelRequested = true }

    // ─── MediaCodec / MediaMuxer state ───────────────────────────────────────
    private var codec: MediaCodec? = null
    private var encoderInputSurface: Surface? = null
    private var muxer: MediaMuxer? = null
    private var videoTrackIndex = -1
    private var muxerStarted = false
    private var writtenVideoSamples = 0
    private var framesSubmitted = 0
    private var overlayFramesRendered = 0

    // ─── EGL / GL state ──────────────────────────────────────────────────────
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var glMajorVersion = 2
    private var glProgram = 0
    private var aPositionLoc = -1
    private var aTexCoordLoc = -1
    private var uSTMatrixLoc = -1
    private var sTextureLoc = -1
    private var glesOverlaySession: AndroidTimelineGlesOverlayRenderSession? = null

    private val sourceSlot = DecodeSlot("source")
    private val cameraSlot = DecodeSlot("camera")

    // OES texture coordinates, BL/BR/TL/TR, shared by both layers and never
    // rotated: the SurfaceTexture matrix is the only texture-space transform
    // (the same convention as AndroidTimelineVideoEncoder's `texCoords`).
    // Vertex positions are per layer and carry the rotation, see
    // [LayerGeometry.positions].
    private val quadTexCoords: FloatBuffer = floatBufferOf(
        0f, 0f,
        1f, 0f,
        0f, 1f,
        1f, 1f,
    )

    // ─────────────────────────────────────────────────────────────────────────
    // Public entry
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Encodes `ceil(durationSeconds * fps)` frames compositing [source] into
     * [sourceRect] and [camera] into [cameraRect] (canvas pixel rects,
     * top-left origin), with [overlays] drawn above both. Returns a failed
     * result with a machine-readable reason on any failure; the partial
     * output file is deleted on failure.
     */
    fun encode(
        source: VideoInput,
        sourceRect: VGDuetPixelRect,
        camera: VideoInput,
        cameraRect: VGDuetPixelRect,
        durationSeconds: Double,
        overlays: List<AndroidTimelineOverlayDescriptor>,
        sourceScaleMode: AndroidDuetLayerScaleMode = AndroidDuetLayerScaleMode.ASPECT_FILL,
        cameraScaleMode: AndroidDuetLayerScaleMode = AndroidDuetLayerScaleMode.ASPECT_FILL,
    ): AndroidTimelineVideoEncoder.EncodeResult {
        if (width <= 0 || height <= 0 || fps <= 0 || bitrateBps <= 0) {
            return failure("invalid_encoder_config:${width}x${height}@${fps}fps:${bitrateBps}bps")
        }
        if (!durationSeconds.isFinite() || durationSeconds <= 0.0) {
            return failure("invalid_duration:$durationSeconds")
        }
        if (overlays.isNotEmpty() && nativeBridge == null) {
            return failure("overlays_require_native_bridge")
        }

        val totalFrames = ceil(durationSeconds * fps).toInt().coerceAtLeast(1)
        val windowDurationUs = (durationSeconds * 1_000_000.0).toLong()

        var succeeded = false
        var muxerStoppedCleanly = false
        var sourcePipeline: DecodePipeline? = null
        var cameraPipeline: DecodePipeline? = null
        try {
            setupEncoderAndMuxer()
            setupEgl()
            setupShaderProgram()
            sourceSlot.setup()
            cameraSlot.setup()

            if (overlays.isNotEmpty()) {
                when (
                    val prepareResult = AndroidTimelineGlesOverlayRenderSession.prepare(overlays) { cancelRequested }
                ) {
                    is AndroidTimelineGlesOverlayRenderSession.PrepareResult.Failure -> {
                        return failure("overlay_prepare_failed:${prepareResult.code}:${prepareResult.message}")
                    }
                    is AndroidTimelineGlesOverlayRenderSession.PrepareResult.Success -> {
                        glesOverlaySession = prepareResult.session
                    }
                }
            }

            val sp = DecodePipeline(source, sourceSlot, windowDurationUs)
            sp.open()?.let { return failure(it) }
            sourcePipeline = sp
            val cp = DecodePipeline(camera, cameraSlot, windowDurationUs)
            cp.open()?.let { return failure(it) }
            cameraPipeline = cp

            val sourceGeometry = computeLayerGeometry(
                source.label, sourceRect, source.rotationDegrees, sp.decodedWidth, sp.decodedHeight,
                scaleMode = sourceScaleMode,
            )
            if (sourceGeometry.failure != null) return failure(sourceGeometry.failure)
            val cameraGeometry = computeLayerGeometry(
                camera.label, cameraRect, camera.rotationDegrees, cp.decodedWidth, cp.decodedHeight,
                scaleMode = cameraScaleMode,
            )
            if (cameraGeometry.failure != null) return failure(cameraGeometry.failure)

            for (frameIndex in 0 until totalFrames) {
                if (cancelRequested) break
                val timelinePtsUs = ptsUsForFrame(frameIndex)

                when (val step = sp.stepTo(timelinePtsUs)) {
                    is StepOutcome.Failed -> return failure(step.reason)
                    StepOutcome.Cancelled -> break
                    StepOutcome.Ended -> return failure("${source.label}:no_decodable_frame")
                    StepOutcome.Rendered, StepOutcome.Held -> Unit
                }
                if (cancelRequested) break
                when (val step = cp.stepTo(timelinePtsUs)) {
                    is StepOutcome.Failed -> return failure(step.reason)
                    StepOutcome.Cancelled -> break
                    StepOutcome.Ended -> return failure("${camera.label}:no_decodable_frame")
                    StepOutcome.Rendered, StepOutcome.Held -> Unit
                }

                val drawFailure = drawAndSubmitFrame(sourceGeometry, cameraGeometry, timelinePtsUs)
                if (drawFailure != null) return failure(drawFailure)
                drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
            }

            if (cancelRequested) return failure("cancelled")

            codec!!.signalEndOfInputStream()
            val eosObserved = drainEncoder(endOfStream = true, deadlineMs = ENCODE_EOS_DEADLINE_MS)
            if (!eosObserved) return failure("encoder_eos_drain_timeout")

            if (writtenVideoSamples != framesSubmitted) {
                return failure("sample_count_mismatch:written=$writtenVideoSamples:rendered=$framesSubmitted")
            }
            if (!muxerStarted || writtenVideoSamples <= 0) return failure("no_video_samples_written")

            muxer!!.stop()
            muxerStoppedCleanly = true

            val outFile = File(outputPath)
            val outSize = if (outFile.exists()) outFile.length() else 0L
            if (outSize <= 0L) return failure("output_file_empty_or_missing")

            succeeded = true
            Log.i(
                TAG,
                "VG_DUET_OFFLINE_COMPOSITOR_ENCODE_RESULT status=success rendered=$framesSubmitted " +
                    "written=$writtenVideoSamples outputSize=$outSize overlayFrames=$overlayFramesRendered " +
                    "glMajorVersion=$glMajorVersion",
            )
            return AndroidTimelineVideoEncoder.EncodeResult(
                true, "success", writtenVideoSamples, outSize,
                overlayFrameCount = overlayFramesRendered,
                glMajorVersion = glMajorVersion,
            )
        } catch (t: Throwable) {
            Log.e(TAG, "encode failed: $t", t)
            return failure("exception:${t.javaClass.simpleName}")
        } finally {
            try { sourcePipeline?.close() } catch (_: Throwable) {}
            try { cameraPipeline?.close() } catch (_: Throwable) {}
            if (muxerStarted && !muxerStoppedCleanly) {
                try { muxer?.stop() } catch (_: Throwable) {}
            }
            releaseAll()
            if (!succeeded) {
                try {
                    val f = File(outputPath)
                    if (f.exists()) f.delete()
                } catch (_: Throwable) {}
            }
        }
    }

    private fun failure(reason: String): AndroidTimelineVideoEncoder.EncodeResult =
        AndroidTimelineVideoEncoder.EncodeResult(
            false, reason, writtenVideoSamples, 0L,
            overlayFrameCount = overlayFramesRendered,
            glMajorVersion = glMajorVersion,
        )

    private fun ptsUsForFrame(frameIndex: Int): Long = frameIndex.toLong() * 1_000_000L / fps

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────

    private fun setupEncoderAndMuxer() {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
        }
        val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = enc.createInputSurface()
        enc.start()
        codec = enc
        encoderInputSurface = surface
        muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    }

    private fun setupEgl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) throw IllegalStateException("eglGetDisplay failed")
        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            throw IllegalStateException("eglInitialize failed")
        }

        val attribs = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, 1, numConfigs, 0)
        val config = configs[0] ?: throw IllegalStateException("eglChooseConfig failed")

        val contextAttribsEs3 = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, config, EGL14.EGL_NO_CONTEXT, contextAttribsEs3, 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) {
            val contextAttribsEs2 = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
            eglContext = EGL14.eglCreateContext(eglDisplay, config, EGL14.EGL_NO_CONTEXT, contextAttribsEs2, 0)
        }
        if (eglContext == EGL14.EGL_NO_CONTEXT) throw IllegalStateException("eglCreateContext failed")

        val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, config, encoderInputSurface, surfaceAttribs, 0)
        if (eglSurface == EGL14.EGL_NO_SURFACE) throw IllegalStateException("eglCreateWindowSurface failed")

        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            throw IllegalStateException("eglMakeCurrent failed")
        }

        val majorVersionOut = IntArray(1)
        GLES20.glGetIntegerv(GLES30.GL_MAJOR_VERSION, majorVersionOut, 0)
        val majorVersionQueryError = GLES20.glGetError()
        glMajorVersion = if (majorVersionQueryError == GLES20.GL_NO_ERROR && majorVersionOut[0] >= 3) {
            majorVersionOut[0]
        } else {
            while (GLES20.glGetError() != GLES20.GL_NO_ERROR) {
                // Drain any pending GL error left by the failed ES3-only query.
            }
            2
        }
    }

    private fun setupShaderProgram() {
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
        // Shaders are owned by the linked program from here on.
        GLES20.glDeleteShader(vertexShader)
        GLES20.glDeleteShader(fragmentShader)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(program)
            GLES20.glDeleteProgram(program)
            throw IllegalStateException("GL program link failed: $log")
        }
        glProgram = program
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

    // ─────────────────────────────────────────────────────────────────────────
    // Geometry
    // ─────────────────────────────────────────────────────────────────────────

    private data class GlRect(val x: Int, val y: Int, val width: Int, val height: Int)

    /**
     * Scissor = the layout rect; viewport = the aspect-fill inflation of it;
     * positions = the BL/BR/TL/TR vertex quad (viewport NDC) already rotated
     * by the layer's display rotation, uploaded once per layer.
     */
    private class LayerGeometry private constructor(
        val scissor: GlRect?,
        val viewport: GlRect?,
        val positions: FloatBuffer?,
        val failure: String?,
    ) {
        companion object {
            fun success(scissor: GlRect, viewport: GlRect, positions: FloatBuffer) =
                LayerGeometry(scissor, viewport, positions, null)
            fun failure(reason: String) = LayerGeometry(null, null, null, reason)
        }
    }

    /** Canvas rect (top-left origin) to GL viewport/scissor rect (bottom-left origin). */
    private fun toGlRect(left: Double, top: Double, w: Double, h: Double): GlRect {
        val wi = w.roundToInt()
        val hi = h.roundToInt()
        return GlRect(
            x = left.roundToInt(),
            y = height - (top.roundToInt() + hi),
            width = wi,
            height = hi,
        )
    }

    /**
     * Aspect-fill of the upright video (decoded size swapped for 90/270) into
     * [rect]: same centre, inflated along one axis to the video's display
     * aspect; the scissor crops the overflow back to [rect]. The vertex quad
     * drawn inside that viewport is rotated by [rotationDegrees] in output
     * vertex space ([rotatedQuadPositions]) so the stored, unrotated decoded
     * frame lands upright. Fails closed on a degenerate rect, unknown decoded
     * size, or non-cardinal rotation rather than stretching or drawing
     * sideways.
     */
    private fun computeLayerGeometry(
        label: String,
        rect: VGDuetPixelRect,
        rotationDegrees: Int,
        decodedWidth: Int,
        decodedHeight: Int,
        scaleMode: AndroidDuetLayerScaleMode = AndroidDuetLayerScaleMode.ASPECT_FILL,
    ): LayerGeometry {
        if (!rect.left.isFinite() || !rect.top.isFinite() ||
            !rect.width.isFinite() || !rect.height.isFinite() ||
            rect.width <= 0.0 || rect.height <= 0.0
        ) {
            return LayerGeometry.failure("$label:degenerate_layer_rect")
        }
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) {
            return LayerGeometry.failure("$label:degenerate_layer_rect")
        }
        if (decodedWidth <= 0 || decodedHeight <= 0) {
            return LayerGeometry.failure("$label:unknown_decoded_dimensions")
        }
        val displayWidth: Int
        val displayHeight: Int
        if (rotationDegrees == 90 || rotationDegrees == 270) {
            displayWidth = decodedHeight
            displayHeight = decodedWidth
        } else {
            displayWidth = decodedWidth
            displayHeight = decodedHeight
        }
        val videoAspect = displayWidth.toDouble() / displayHeight.toDouble()
        val rectAspect = rect.width / rect.height
        val drawnW: Double
        val drawnH: Double
        if (scaleMode == AndroidDuetLayerScaleMode.ASPECT_FIT) {
            if (videoAspect > rectAspect) {
                drawnW = rect.width
                drawnH = rect.width / videoAspect
            } else {
                drawnH = rect.height
                drawnW = rect.height * videoAspect
            }
        } else {
            if (videoAspect > rectAspect) {
                drawnH = rect.height
                drawnW = rect.height * videoAspect
            } else {
                drawnW = rect.width
                drawnH = rect.width / videoAspect
            }
        }
        val viewport = toGlRect(
            rect.left + (rect.width - drawnW) / 2.0,
            rect.top + (rect.height - drawnH) / 2.0,
            drawnW,
            drawnH,
        )
        if (viewport.width <= 0 || viewport.height <= 0) {
            return LayerGeometry.failure("$label:degenerate_fill_viewport")
        }
        val positions = rotatedQuadPositions(rotationDegrees, viewport)
            ?: return LayerGeometry.failure("$label:unsupported_rotation:$rotationDegrees")
        return LayerGeometry.success(scissor, viewport, positions)
    }

    /**
     * Vertex positions (BL/BR/TL/TR, NDC of [viewport]) that draw the stored
     * decoded frame rotated clockwise by [rotationDegrees] so it exactly
     * fills the aspect-fill viewport. Mirrors
     * AndroidTimelineVideoEncoder.updateClipGeometry: the unrotated frame's
     * corners are rotated in viewport pixel space by the negated angle
     * (rotation metadata is clockwise, mathematical positive angles are
     * counter-clockwise) and only then normalized per axis, because NDC is
     * anisotropic on a non-square viewport. Cardinal cos/sin values are
     * exact so every corner lands precisely on +/-1. Returns null for a
     * non-cardinal rotation.
     */
    private fun rotatedQuadPositions(rotationDegrees: Int, viewport: GlRect): FloatBuffer? {
        val cosR: Float
        val sinR: Float
        when (rotationDegrees) {
            0 -> { cosR = 1f; sinR = 0f }
            90 -> { cosR = 0f; sinR = -1f }
            180 -> { cosR = -1f; sinR = 0f }
            270 -> { cosR = 0f; sinR = 1f }
            else -> return null
        }
        val viewportHalfW = viewport.width / 2f
        val viewportHalfH = viewport.height / 2f
        // The viewport is sized to the display (rotated) extent, so the
        // unrotated frame spans the viewport extents swapped back for 90/270.
        val halfX: Float
        val halfY: Float
        if (rotationDegrees == 90 || rotationDegrees == 270) {
            halfX = viewportHalfH
            halfY = viewportHalfW
        } else {
            halfX = viewportHalfW
            halfY = viewportHalfH
        }
        fun corner(x: Float, y: Float): FloatArray {
            val rx = x * cosR - y * sinR
            val ry = x * sinR + y * cosR
            return floatArrayOf(rx / viewportHalfW, ry / viewportHalfH)
        }
        val bl = corner(-halfX, -halfY)
        val br = corner(halfX, -halfY)
        val tl = corner(-halfX, halfY)
        val tr = corner(halfX, halfY)
        return floatBufferOf(bl[0], bl[1], br[0], br[1], tl[0], tl[1], tr[0], tr[1])
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Per-frame draw → overlays → present
    // ─────────────────────────────────────────────────────────────────────────

    private fun drawAndSubmitFrame(
        sourceGeometry: LayerGeometry,
        cameraGeometry: LayerGeometry,
        timelinePtsUs: Long,
    ): String? {
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            return "egl_make_current_failed"
        }
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        drawLayer(sourceSlot, sourceGeometry)
        drawLayer(cameraSlot, cameraGeometry)

        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
        GLES20.glViewport(0, 0, width, height)
        val glError = GLES20.glGetError()
        if (glError != GLES20.GL_NO_ERROR) return "gl_error:$glError"

        val session = glesOverlaySession
        if (session != null) {
            val bridge = nativeBridge ?: return "overlays_require_native_bridge"
            when (val result = session.drawActiveOverlays(bridge, timelinePtsUs, width, height)) {
                is AndroidTimelineGlesOverlayRenderSession.DrawResult.Success -> {
                    if (result.activeOverlayCount > 0) overlayFramesRendered++
                }
                is AndroidTimelineGlesOverlayRenderSession.DrawResult.Failure -> {
                    return "overlay_draw_failed:${result.reason}"
                }
            }
        }

        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, timelinePtsUs * 1000L)
        framesSubmitted++
        if (!EGL14.eglSwapBuffers(eglDisplay, eglSurface)) return "egl_swap_buffers_failed"
        return null
    }

    private fun drawLayer(slot: DecodeSlot, geometry: LayerGeometry) {
        val scissor = geometry.scissor ?: return
        val viewport = geometry.viewport ?: return
        val positions = geometry.positions ?: return
        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glViewport(viewport.x, viewport.y, viewport.width, viewport.height)

        GLES20.glUseProgram(glProgram)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, slot.oesTextureId)
        GLES20.glUniform1i(sTextureLoc, 0)
        GLES20.glUniformMatrix4fv(uSTMatrixLoc, 1, false, slot.transformMatrix, 0)

        positions.position(0)
        GLES20.glEnableVertexAttribArray(aPositionLoc)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, positions)
        quadTexCoords.position(0)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPositionLoc)
        GLES20.glDisableVertexAttribArray(aTexCoordLoc)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Encoder drain (fixed frame clock)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Drains encoder output into the muxer. When [endOfStream] is true,
     * returns whether the encoder's EOS buffer was observed before
     * [deadlineMs] elapsed; when false (per-frame drain) always returns true.
     */
    private fun drainEncoder(endOfStream: Boolean, deadlineMs: Long): Boolean {
        val enc = codec!!
        val mx = muxer!!
        val info = MediaCodec.BufferInfo()
        val deadline = System.currentTimeMillis() + deadlineMs
        var draining = true
        var eosObserved = false
        while (draining) {
            if (endOfStream && System.currentTimeMillis() > deadline) break
            val outIdx = enc.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
            when {
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) draining = false
                }
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (videoTrackIndex < 0) {
                        videoTrackIndex = mx.addTrack(enc.outputFormat)
                        mx.start()
                        muxerStarted = true
                    }
                }
                outIdx >= 0 -> {
                    val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    if (!isConfig && info.size > 0 && muxerStarted && videoTrackIndex >= 0) {
                        val buf = enc.getOutputBuffer(outIdx)
                        if (buf != null) {
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            info.presentationTimeUs = ptsUsForFrame(writtenVideoSamples)
                            mx.writeSampleData(videoTrackIndex, buf, info)
                            writtenVideoSamples++
                        }
                    }
                    enc.releaseOutputBuffer(outIdx, false)
                    if (isEos) {
                        eosObserved = true
                        draining = false
                    }
                }
            }
        }
        return !endOfStream || eosObserved
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Cleanup
    // ─────────────────────────────────────────────────────────────────────────

    private fun releaseAll() {
        try { codec?.stop() } catch (_: Throwable) {}
        try { codec?.release() } catch (_: Throwable) {}
        codec = null
        try { muxer?.release() } catch (_: Throwable) {}
        muxer = null

        if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglContext != EGL14.EGL_NO_CONTEXT) {
            try {
                EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
                // The overlay session and the slots delete GL textures and need
                // this context current; close them before EGL teardown.
                glesOverlaySession?.close()
                glesOverlaySession = null
                sourceSlot.release()
                cameraSlot.release()
                if (glProgram != 0) GLES20.glDeleteProgram(glProgram)
                glProgram = 0
            } catch (_: Throwable) {}
        } else {
            // No GL context ever became current: only non-GL handles can exist.
            sourceSlot.release()
            cameraSlot.release()
        }

        try { encoderInputSurface?.release() } catch (_: Throwable) {}
        encoderInputSurface = null

        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            try {
                EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            } catch (_: Throwable) {}
            if (eglSurface != EGL14.EGL_NO_SURFACE) {
                try { EGL14.eglDestroySurface(eglDisplay, eglSurface) } catch (_: Throwable) {}
            }
            if (eglContext != EGL14.EGL_NO_CONTEXT) {
                try { EGL14.eglDestroyContext(eglDisplay, eglContext) } catch (_: Throwable) {}
            }
            try { EGL14.eglTerminate(eglDisplay) } catch (_: Throwable) {}
        }
        eglSurface = EGL14.EGL_NO_SURFACE
        eglContext = EGL14.EGL_NO_CONTEXT
        eglDisplay = EGL14.EGL_NO_DISPLAY
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Decode slot: one OES texture + SurfaceTexture + frame-available wait
    // ─────────────────────────────────────────────────────────────────────────

    private class DecodeSlot(val label: String) {
        var oesTextureId = 0
            private set
        var inputSurface: Surface? = null
            private set
        private var surfaceTexture: SurfaceTexture? = null

        private val syncLock = Object()
        private var frameAvailable = false

        /** Refreshed by [awaitNewImage]; identity until the first frame lands. */
        val transformMatrix = FloatArray(16).also { m ->
            m[0] = 1f; m[5] = 1f; m[10] = 1f; m[15] = 1f
        }

        /** Requires the caller's EGL context to be current. */
        fun setup() {
            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            oesTextureId = textures[0]
            if (oesTextureId == 0) throw IllegalStateException("$label: glGenTextures failed")
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)

            val texture = SurfaceTexture(oesTextureId)
            texture.setOnFrameAvailableListener {
                synchronized(syncLock) {
                    frameAvailable = true
                    syncLock.notifyAll()
                }
            }
            surfaceTexture = texture
            inputSurface = Surface(texture)
        }

        fun resetFrameAvailable() {
            synchronized(syncLock) { frameAvailable = false }
        }

        /**
         * Blocks (bounded by [timeoutMs]) until the decoder reports a new
         * frame, then updateTexImage()s and refreshes [transformMatrix].
         * Returns false on timeout.
         */
        fun awaitNewImage(timeoutMs: Long): Boolean {
            synchronized(syncLock) {
                val deadline = System.currentTimeMillis() + timeoutMs
                while (!frameAvailable) {
                    val remaining = deadline - System.currentTimeMillis()
                    if (remaining <= 0L) return false
                    syncLock.wait(remaining)
                }
                frameAvailable = false
            }
            val texture = surfaceTexture ?: return false
            texture.updateTexImage()
            texture.getTransformMatrix(transformMatrix)
            return true
        }

        /** Idempotent. GL texture deletion needs the owning context current. */
        fun release() {
            try { inputSurface?.release() } catch (_: Throwable) {}
            try { surfaceTexture?.release() } catch (_: Throwable) {}
            if (oesTextureId != 0) {
                try { GLES20.glDeleteTextures(1, intArrayOf(oesTextureId), 0) } catch (_: Throwable) {}
            }
            oesTextureId = 0
            surfaceTexture = null
            inputSurface = null
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Decode pipeline: one MediaExtractor + MediaCodec feeding one slot
    // ─────────────────────────────────────────────────────────────────────────

    private sealed class StepOutcome {
        /** A new frame was rendered into the slot for this target. */
        object Rendered : StepOutcome()
        /** No newer frame is due; the slot keeps its last rendered frame. */
        object Held : StepOutcome()
        /** End of stream reached without ever producing a frame. */
        object Ended : StepOutcome()
        object Cancelled : StepOutcome()
        class Failed(val reason: String) : StepOutcome()
    }

    private inner class DecodePipeline(
        private val input: VideoInput,
        private val slot: DecodeSlot,
        windowDurationUs: Long,
    ) {
        private val extractor = MediaExtractor()
        private var decoder: MediaCodec? = null
        private var inputDone = false
        private var outputEos = false
        private var stallAttempts = 0

        // A decoded frame whose pts is past the last target: kept unreleased
        // (never rendered yet) until a later target reaches it.
        private var pendingIndex = -1
        private var pendingPtsUs = 0L
        // Within one stepTo: the newest frame at/before the target so far.
        private var candidateIndex = -1
        private var candidatePtsUs = 0L

        private var hasRenderedFrame = false

        private val startOffsetUs = (input.startOffsetSeconds * 1_000_000.0).toLong().coerceAtLeast(0L)
        private val inputEndUs = startOffsetUs + windowDurationUs + INPUT_END_MARGIN_US

        var decodedWidth = 0
            private set
        var decodedHeight = 0
            private set

        /** Returns null on success, or a machine-readable failure reason. */
        fun open(): String? {
            return try {
                extractor.setDataSource(input.sourcePath)
                var trackIndex = -1
                var trackFormat: MediaFormat? = null
                for (i in 0 until extractor.trackCount) {
                    val f = extractor.getTrackFormat(i)
                    if (f.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                        trackIndex = i
                        trackFormat = f
                        break
                    }
                }
                if (trackIndex < 0 || trackFormat == null) return "${input.label}:no_video_track"
                extractor.selectTrack(trackIndex)

                decodedWidth = formatInt(trackFormat, MediaFormat.KEY_WIDTH, input.hintWidth)
                decodedHeight = formatInt(trackFormat, MediaFormat.KEY_HEIGHT, input.hintHeight)

                if (startOffsetUs > 0L) {
                    extractor.seekTo(startOffsetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                }

                val mime = trackFormat.getString(MediaFormat.KEY_MIME)!!
                val dec = MediaCodec.createDecoderByType(mime)
                // The track format is passed through unmodified, exactly as
                // AndroidTimelineVideoEncoder configures its clip decoder. The
                // rotation metadata is not relied on to arrive upright through
                // the slot's SurfaceTexture matrix: computeLayerGeometry applies
                // it in output vertex space (see the file-level Orientation
                // claim).
                dec.configure(trackFormat, slot.inputSurface, null, 0)
                dec.start()
                decoder = dec
                null
            } catch (t: Throwable) {
                "${input.label}:open_exception:${t.javaClass.simpleName}"
            }
        }

        private fun formatInt(format: MediaFormat, key: String, fallback: Int): Int {
            val value = try {
                if (format.containsKey(key)) format.getInteger(key) else 0
            } catch (_: Throwable) {
                0
            }
            return if (value > 0) value else fallback
        }

        /**
         * Advances this side to output-timeline instant [timelinePtsUs]:
         * renders the newest decoded frame at or before
         * `startOffset + timelinePtsUs`, or holds the last rendered frame
         * when nothing newer is due (including after end-of-stream).
         */
        fun stepTo(timelinePtsUs: Long): StepOutcome {
            val dec = decoder ?: return StepOutcome.Failed("${input.label}:decoder_not_open")
            val targetUs = startOffsetUs + timelinePtsUs
            try {
                if (pendingIndex >= 0) {
                    if (pendingPtsUs <= targetUs) {
                        candidateIndex = pendingIndex
                        candidatePtsUs = pendingPtsUs
                        pendingIndex = -1
                    } else {
                        return StepOutcome.Held
                    }
                }

                val info = MediaCodec.BufferInfo()
                while (true) {
                    if (cancelRequested) {
                        dropCandidate(dec)
                        return StepOutcome.Cancelled
                    }
                    if (outputEos) {
                        if (candidateIndex >= 0) return renderCandidate(dec)
                        return if (hasRenderedFrame) StepOutcome.Held else StepOutcome.Ended
                    }

                    if (!inputDone) feedInput(dec)

                    val outIdx = dec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                    when {
                        outIdx >= 0 -> {
                            stallAttempts = 0
                            val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                            if (info.size > 0) {
                                val pts = info.presentationTimeUs
                                if (pts <= targetUs) {
                                    // Newer at-or-before-target frame supersedes the candidate.
                                    if (candidateIndex >= 0) dec.releaseOutputBuffer(candidateIndex, false)
                                    candidateIndex = outIdx
                                    candidatePtsUs = pts
                                    if (isEos) outputEos = true
                                } else if (candidateIndex >= 0) {
                                    // First future frame: park it, render the candidate.
                                    pendingIndex = outIdx
                                    pendingPtsUs = pts
                                    if (isEos) outputEos = true
                                    return renderCandidate(dec)
                                } else if (!hasRenderedFrame) {
                                    // The first decodable frame is already past the
                                    // target: render it so frame 0 is never black.
                                    candidateIndex = outIdx
                                    candidatePtsUs = pts
                                    if (isEos) outputEos = true
                                    return renderCandidate(dec)
                                } else {
                                    pendingIndex = outIdx
                                    pendingPtsUs = pts
                                    if (isEos) outputEos = true
                                    return StepOutcome.Held
                                }
                            } else {
                                dec.releaseOutputBuffer(outIdx, false)
                                if (isEos) outputEos = true
                            }
                        }
                        outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                            stallAttempts++
                            if (stallAttempts > MAX_STALL_ATTEMPTS) {
                                dropCandidate(dec)
                                return StepOutcome.Failed("${input.label}:decoder_stalled")
                            }
                        }
                        else -> {
                            // INFO_OUTPUT_FORMAT_CHANGED / INFO_OUTPUT_BUFFERS_CHANGED: nothing to do.
                        }
                    }
                }
            } catch (t: Throwable) {
                return StepOutcome.Failed("${input.label}:decode_exception:${t.javaClass.simpleName}")
            }
        }

        private fun feedInput(dec: MediaCodec) {
            val inIdx = dec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
            if (inIdx < 0) return
            val buf = dec.getInputBuffer(inIdx)
                ?: throw IllegalStateException("${input.label}: null input buffer")
            val size = extractor.readSampleData(buf, 0)
            if (size < 0 || extractor.sampleTime > inputEndUs) {
                dec.queueInputBuffer(inIdx, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                inputDone = true
            } else {
                dec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                extractor.advance()
            }
        }

        private fun renderCandidate(dec: MediaCodec): StepOutcome {
            val idx = candidateIndex
            candidateIndex = -1
            slot.resetFrameAvailable()
            dec.releaseOutputBuffer(idx, true)
            if (!slot.awaitNewImage(FRAME_WAIT_TIMEOUT_MS)) {
                return StepOutcome.Failed("${input.label}:frame_transfer_timeout")
            }
            hasRenderedFrame = true
            return StepOutcome.Rendered
        }

        private fun dropCandidate(dec: MediaCodec) {
            if (candidateIndex >= 0) {
                try { dec.releaseOutputBuffer(candidateIndex, false) } catch (_: Throwable) {}
                candidateIndex = -1
            }
        }

        fun close() {
            try { decoder?.stop() } catch (_: Throwable) {}
            try { decoder?.release() } catch (_: Throwable) {}
            decoder = null
            try { extractor.release() } catch (_: Throwable) {}
        }
    }

    companion object {
        private const val TAG = "VGDuetOfflineCompositor"
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val FRAME_WAIT_TIMEOUT_MS = 2_000L
        private const val ENCODE_DRAIN_DEADLINE_MS = 2_000L
        private const val ENCODE_EOS_DEADLINE_MS = 5_000L

        /**
         * Bounded no-output budget per decode step: 500 attempts at
         * [DEQUEUE_TIMEOUT_US] each is a ~5 s ceiling, so a stalled decoder
         * fails closed instead of spinning forever.
         */
        private const val MAX_STALL_ATTEMPTS = 500

        /**
         * Input samples are fed slightly past the output window so the
         * decoder can confirm the last in-window frame (and flush B-frame
         * reordering) before EOS; frames past a target are simply held.
         */
        private const val INPUT_END_MARGIN_US = 250_000L

        private fun floatBufferOf(vararg values: Float): FloatBuffer =
            ByteBuffer.allocateDirect(values.size * 4)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()
                .apply {
                    put(values)
                    position(0)
                }
    }
}
