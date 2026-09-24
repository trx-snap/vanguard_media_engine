package com.connects.vanguard_media_engine.duet

import android.graphics.Bitmap
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
import android.util.Log
import android.view.Surface
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.SegmentationMask
import com.google.mlkit.vision.segmentation.Segmenter
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.roundToInt

// ─────────────────────────────────────────────────────────────────────────────
// VG-DUET-GREENSCREEN-EXPORT: Android real-take green-screen offline compositor.
// ─────────────────────────────────────────────────────────────────────────────
//
// Sibling of AndroidDuetOfflineCompositorVideoEncoder. Handles the
// layoutMode == "greenScreen" real-take export path only. PiP/Split
// behavior in the parent class is NOT touched.
//
// Architecture (Opus-frozen):
//   - Source video is decoded and rendered full-canvas as the background.
//   - Camera segment is decoded frame-by-frame; each frame is segmented via
//     ML Kit CPU SelfieSegmenter (SINGLE_IMAGE_MODE for offline, no temporal
//     state carried across frames -- safe for random-access decode order).
//   - The 8-bit foreground mask (float32 confidence → uint8 alpha) is
//     uploaded to a GL_ALPHA texture; a two-pass GLES2 compositor draws:
//       pass 1: source frame fills the full canvas (background).
//       pass 2: camera frame is alpha-blended over the camera rect using the
//               mask (equivalent of CIBlendWithMask fg*alpha + bg*(1-alpha)).
//   - Fixed output clock: ptsUs = i * 1_000_000 / fps.
//   - Fail-closed: any frame with no segmentation mask returns composition_failed;
//     no unkeyed fallback frames are output.
//   - Cancellation is checked between frames and while waiting for the
//     ML Kit Task result.
//   - All MediaCodec / MediaExtractor / EGL / GL / ML Kit resources are
//     released in finally.
//
// Non-claims: no audio (owned by AudioPass2Muxer), no live camera, no GPU
// MediaPipe, no static/image backgrounds, no overlays (caller passes none
// for the green-screen route).

class AndroidDuetGreenScreenOfflineCompositorVideoEncoder(
    private val outputPath: String,
    private val width: Int,
    private val height: Int,
    private val fps: Int,
    private val bitrateBps: Int,
) {
    /** One decoded video layer. Mirrors AndroidDuetOfflineCompositorVideoEncoder.VideoInput. */
    data class VideoInput(
        val label: String,
        val sourcePath: String,
        /** Source-file time (seconds) that maps to output timeline t = 0. */
        val startOffsetSeconds: Double,
        /** Normalized clockwise display rotation: 0, 90, 180, or 270. */
        val rotationDegrees: Int,
        val hintWidth: Int,
        val hintHeight: Int,
    )

    data class EncodeResult(
        val success: Boolean,
        val reason: String,
        val renderedFrames: Int,
        val segmentedFrames: Int,
        val avgSegmentMs: Double,
        val maxSegmentMs: Long,
        val outputSizeBytes: Long,
    )

    @Volatile private var cancelRequested = false
    fun cancel() { cancelRequested = true }

    // ─── MediaCodec / MediaMuxer ──────────────────────────────────────────────
    private var codec: MediaCodec? = null
    private var encoderInputSurface: Surface? = null
    private var muxer: MediaMuxer? = null
    private var videoTrackIndex = -1
    private var muxerStarted = false
    private var writtenVideoSamples = 0
    private var framesSubmitted = 0

    // ─── EGL / GL ─────────────────────────────────────────────────────────────
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    // Two-texture program: background (OES external) + camera (OES external).
    // For the blend pass: mask is uploaded as GL_ALPHA texture from CPU bytes.
    private var bgProgram = 0          // full-canvas source draw
    private var blendProgram = 0       // camera-over-source blend with mask
    private var aPosBg = -1; private var aTexBg = -1; private var uSTBg = -1; private var sTexBg = -1
    private var aPosBlend = -1; private var aTexBlend = -1; private var uSTBlend = -1
    private var sTexCamera = -1; private var sMaskBlend = -1

    private val sourceSlot = DecodeSlot("source")
    private val cameraSlot = DecodeSlot("camera")
    private var maskTexId = 0

    private val quadTexCoords: FloatBuffer = floatBufferOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)

    // Pre-allocated 8-float buffer (4 vertices × 2 NDC floats) for the
    // rotated-quad foreground draw path.  Populated in drawAndSubmitFrame
    // when foregroundRotationDegrees is non-zero.
    private val rotatedCameraQuadPositions: FloatBuffer =
        ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()

    // ─── Foreground free-rotation (Defect 1 fix) ──────────────────────────────
    // Set once by encode() before the frame loop. Zero means no rotation.
    private var foregroundRotationDegrees: Double = 0.0
    private var foregroundAnchorX: Double = 0.5
    private var foregroundAnchorY: Double = 0.5

    // ─── ML Kit ───────────────────────────────────────────────────────────────
    private var segmenter: Segmenter? = null

    // ─────────────────────────────────────────────────────────────────────────
    // Public entry
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs the green-screen offline composite on the calling (background) thread.
     * Fails closed on any segmentation failure; no unkeyed frames are output.
     *
     * [foregroundRotationDegrees] is the visual-clockwise Dart/top-left rotation
     * (matching [AndroidDuetPreviewCompositor.setForegroundRotation]).  Zero or
     * non-finite values disable the rotated-quad path and preserve the existing
     * axis-aligned scissor/viewport behavior.  [foregroundAnchorX] /
     * [foregroundAnchorY] are the pivot point within the unrotated camera rect
     * (0.0–1.0 normalized, default 0.5).
     */
    fun encode(
        source: VideoInput,
        sourceRect: VGDuetPixelRect,
        camera: VideoInput,
        cameraRect: VGDuetPixelRect,
        durationSeconds: Double,
        foregroundRotationDegrees: Double = 0.0,
        foregroundAnchorX: Double = 0.5,
        foregroundAnchorY: Double = 0.5,
    ): EncodeResult {
        if (width <= 0 || height <= 0 || fps <= 0 || bitrateBps <= 0) {
            return failure("invalid_encoder_config:${width}x${height}@${fps}fps:${bitrateBps}bps")
        }
        if (!durationSeconds.isFinite() || durationSeconds <= 0.0) {
            return failure("invalid_duration:$durationSeconds")
        }

        // Sanitize and store foreground rotation so drawAndSubmitFrame can use it.
        // Mirrors AndroidDuetPreviewCompositor.setForegroundRotation: non-finite
        // rotation → 0.0 (identity); non-finite anchor → 0.5 (center), clamped.
        this.foregroundRotationDegrees =
            if (foregroundRotationDegrees.isFinite()) foregroundRotationDegrees else 0.0
        this.foregroundAnchorX =
            (if (foregroundAnchorX.isFinite()) foregroundAnchorX else 0.5).coerceIn(0.0, 1.0)
        this.foregroundAnchorY =
            (if (foregroundAnchorY.isFinite()) foregroundAnchorY else 0.5).coerceIn(0.0, 1.0)

        val totalFrames = ceil(durationSeconds * fps).toInt().coerceAtLeast(1)
        val windowDurationUs = (durationSeconds * 1_000_000.0).toLong()

        var succeeded = false
        var muxerStoppedCleanly = false
        var sourcePipeline: DecodePipeline? = null
        var cameraPipeline: DecodePipeline? = null

        var segmentedFrames = 0
        var totalSegMs = 0L
        var maxSegMs = 0L

        try {
            setupEncoderAndMuxer()
            setupEgl()
            setupShaderPrograms()
            setupMaskTexture()
            sourceSlot.setup()
            cameraSlot.setup()

            // Open ML Kit CPU SelfieSegmenter in SINGLE_IMAGE_MODE (no temporal
            // state — safe for offline random-access decode order).
            val opts = SelfieSegmenterOptions.Builder()
                .setDetectorMode(SelfieSegmenterOptions.SINGLE_IMAGE_MODE)
                .enableRawSizeMask()
                .build()
            segmenter = Segmentation.getClient(opts)

            val sp = DecodePipeline(source, sourceSlot, windowDurationUs)
            sp.open()?.let { return failure(it) }
            sourcePipeline = sp
            val cp = DecodePipeline(camera, cameraSlot, windowDurationUs)
            cp.open()?.let { return failure(it) }
            cameraPipeline = cp

            val sourceGeometry = computeLayerGeometry(
                source.label, sourceRect, source.rotationDegrees, sp.decodedWidth, sp.decodedHeight,
                scaleMode = AndroidDuetLayerScaleMode.ASPECT_FILL,
            )
            if (sourceGeometry.failure != null) return failure(sourceGeometry.failure)

            val cameraGeometry = computeLayerGeometry(
                camera.label, cameraRect, camera.rotationDegrees, cp.decodedWidth, cp.decodedHeight,
                scaleMode = AndroidDuetLayerScaleMode.ASPECT_FILL,
            )
            if (cameraGeometry.failure != null) return failure(cameraGeometry.failure)

            for (frameIndex in 0 until totalFrames) {
                if (cancelRequested) break
                val timelinePtsUs = ptsUsForFrame(frameIndex)

                when (val step = sp.stepTo(timelinePtsUs)) {
                    is StepOutcome.Failed   -> return failure(step.reason)
                    StepOutcome.Cancelled   -> break
                    StepOutcome.Ended       -> return failure("${source.label}:no_decodable_frame")
                    StepOutcome.Rendered, StepOutcome.Held -> Unit
                }
                if (cancelRequested) break
                when (val step = cp.stepTo(timelinePtsUs)) {
                    is StepOutcome.Failed   -> return failure(step.reason)
                    StepOutcome.Cancelled   -> break
                    StepOutcome.Ended       -> return failure("${camera.label}:no_decodable_frame")
                    StepOutcome.Rendered, StepOutcome.Held -> Unit
                }
                if (cancelRequested) break

                // ── Segment camera frame via ML Kit CPU ───────────────────────
                val segT0 = System.currentTimeMillis()
                val maskResult = segmentCameraFrame(cp.decodedWidth, cp.decodedHeight, frameIndex)
                    ?: return failure("segmentation_failed:frame=$frameIndex")
                val segElapsed = System.currentTimeMillis() - segT0
                totalSegMs += segElapsed
                if (segElapsed > maxSegMs) maxSegMs = segElapsed
                segmentedFrames++

                if (cancelRequested) break

                // ── Upload mask + composite ────────────────────────────────────
                val drawFailure = drawAndSubmitFrame(
                    sourceGeometry, cameraGeometry, maskResult, timelinePtsUs,
                    cameraRect,
                )
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
            val avgSegMs = if (segmentedFrames > 0) totalSegMs.toDouble() / segmentedFrames else 0.0
            Log.i(
                TAG,
                "VG_DUET_GS_OFFLINE_COMPOSITOR_ENCODE_RESULT " +
                    "status=success layout=greenScreen backend=mlkit_cpu " +
                    "rendered=$framesSubmitted written=$writtenVideoSamples " +
                    "segmented=$segmentedFrames avgSegMs=%.1f maxSegMs=$maxSegMs " +
                    "outputSize=$outSize".format(avgSegMs),
            )
            return EncodeResult(
                success = true,
                reason = "success",
                renderedFrames = framesSubmitted,
                segmentedFrames = segmentedFrames,
                avgSegmentMs = avgSegMs,
                maxSegmentMs = maxSegMs,
                outputSizeBytes = outSize,
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

    private fun failure(reason: String): EncodeResult {
        Log.e(TAG, "VG_DUET_GS_OFFLINE_COMPOSITOR_ENCODE_RESULT status=failed " +
            "layout=greenScreen backend=mlkit_cpu reason=$reason " +
            "rendered=$framesSubmitted segmented=0 outputSize=0")
        return EncodeResult(
            success = false,
            reason = reason,
            renderedFrames = framesSubmitted,
            segmentedFrames = 0,
            avgSegmentMs = 0.0,
            maxSegmentMs = 0L,
            outputSizeBytes = 0L,
        )
    }

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

        val ctxAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, config, EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) throw IllegalStateException("eglCreateContext failed")

        val surfAttribs = intArrayOf(EGL14.EGL_NONE)
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, config, encoderInputSurface, surfAttribs, 0)
        if (eglSurface == EGL14.EGL_NO_SURFACE) throw IllegalStateException("eglCreateWindowSurface failed")

        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            throw IllegalStateException("eglMakeCurrent failed")
        }
    }

    private fun setupShaderPrograms() {
        // Background pass: draw OES external texture (source) filling the given viewport.
        val vertSrc = """
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            uniform mat4 uSTMatrix;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = (uSTMatrix * aTextureCoord).xy;
            }
        """.trimIndent()
        val fragBg = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTexCoord;
            uniform samplerExternalOES sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, vTexCoord);
            }
        """.trimIndent()
        bgProgram = buildProgram(vertSrc, fragBg)
        aPosBg   = GLES20.glGetAttribLocation(bgProgram,  "aPosition")
        aTexBg   = GLES20.glGetAttribLocation(bgProgram,  "aTextureCoord")
        uSTBg    = GLES20.glGetUniformLocation(bgProgram, "uSTMatrix")
        sTexBg   = GLES20.glGetUniformLocation(bgProgram, "sTexture")

        // Blend pass: draw camera OES texture masked by the CPU-uploaded alpha mask.
        // Equivalent to CIBlendWithMask: out = fg * mask + bg * (1 - mask).
        // GL blending is enabled with (SRC_ALPHA, ONE_MINUS_SRC_ALPHA) and the
        // alpha channel of the fragment output is the mask sample.
        val fragBlend = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTexCoord;
            uniform samplerExternalOES sCamera;
            uniform sampler2D sMask;
            void main() {
                vec4 cam = texture2D(sCamera, vTexCoord);
                float alpha = texture2D(sMask, vTexCoord).r;
                gl_FragColor = vec4(cam.rgb, alpha);
            }
        """.trimIndent()
        blendProgram  = buildProgram(vertSrc, fragBlend)
        aPosBlend     = GLES20.glGetAttribLocation(blendProgram,  "aPosition")
        aTexBlend     = GLES20.glGetAttribLocation(blendProgram,  "aTextureCoord")
        uSTBlend      = GLES20.glGetUniformLocation(blendProgram, "uSTMatrix")
        sTexCamera    = GLES20.glGetUniformLocation(blendProgram, "sCamera")
        sMaskBlend    = GLES20.glGetUniformLocation(blendProgram, "sMask")
    }

    private fun buildProgram(vertSrc: String, fragSrc: String): Int {
        val vs = compileShader(GLES20.GL_VERTEX_SHADER, vertSrc)
        val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, fragSrc)
        val prog = GLES20.glCreateProgram()
        GLES20.glAttachShader(prog, vs)
        GLES20.glAttachShader(prog, fs)
        GLES20.glLinkProgram(prog)
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        val status = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(prog)
            GLES20.glDeleteProgram(prog)
            throw IllegalStateException("GL link failed: $log")
        }
        return prog
    }

    private fun compileShader(type: Int, src: String): Int {
        val s = GLES20.glCreateShader(type)
        GLES20.glShaderSource(s, src)
        GLES20.glCompileShader(s)
        val status = IntArray(1)
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(s)
            GLES20.glDeleteShader(s)
            throw IllegalStateException("GL compile failed: $log")
        }
        return s
    }

    private fun setupMaskTexture() {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        maskTexId = ids[0]
        if (maskTexId == 0) throw IllegalStateException("glGenTextures failed for mask")
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTexId)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ML Kit CPU segmentation
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Reads the current camera SurfaceTexture frame into a Bitmap (via
     * `Bitmap.createBitmap` on the GL context) and runs SelfieSegmenter.
     *
     * Returns an [MaskData] (float32 confidence array + dimensions) on success,
     * or null on any failure (segmentation error, cancellation, timeout).
     *
     * ML Kit tasks fire on the main thread; we wait with a 5-second bounded
     * latch and check cancellation after the latch.
     */
    private fun segmentCameraFrame(cameraW: Int, cameraH: Int, frameIndex: Int): MaskData? {
        val seg = segmenter ?: return null

        // Read the current camera frame from the SurfaceTexture slot into a Bitmap.
        // We draw the camera OES texture into a RGBA offscreen bitmap via glReadPixels.
        val bitmapW = max(1, cameraW)
        val bitmapH = max(1, cameraH)
        val bmpPixels = IntArray(bitmapW * bitmapH)
        // The camera slot's OES texture has already been updateTexImage'd by stepTo.
        // Draw it into a temporary framebuffer and read pixels.
        val fboIds = IntArray(1)
        val texIds = IntArray(1)
        GLES20.glGenFramebuffers(1, fboIds, 0)
        GLES20.glGenTextures(1, texIds, 0)
        val fboId = fboIds[0]
        val renderTexId = texIds[0]
        try {
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, renderTexId)
            GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, bitmapW, bitmapH,
                0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fboId)
            GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
                GLES20.GL_TEXTURE_2D, renderTexId, 0)
            val fbStatus = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
            if (fbStatus != GLES20.GL_FRAMEBUFFER_COMPLETE) {
                Log.w(TAG, "FBO incomplete status=$fbStatus frame=$frameIndex")
                return null
            }
            GLES20.glViewport(0, 0, bitmapW, bitmapH)
            GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
            GLES20.glDisable(GLES20.GL_BLEND)
            GLES20.glClearColor(0f, 0f, 0f, 0f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

            // Draw camera OES texture into FBO using the bg program (no blending).
            val fullRect = VGDuetPixelRect(0.0, 0.0, bitmapW.toDouble(), bitmapH.toDouble())
            val fullGeom = computeLayerGeometry("cam_seg", fullRect, 0, bitmapW, bitmapH)
            if (fullGeom.failure != null) return null
            drawOesSlot(cameraSlot, fullGeom, bgProgram, aPosBg, aTexBg, uSTBg, sTexBg)

            val pixelBuf = ByteBuffer.allocateDirect(bitmapW * bitmapH * 4)
                .order(ByteOrder.nativeOrder())
            GLES20.glReadPixels(0, 0, bitmapW, bitmapH, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pixelBuf)
            pixelBuf.rewind()

            // glReadPixels yields bottom-left origin; flip rows to top-left.
            val bitmapBuf = IntArray(bitmapW * bitmapH)
            for (row in 0 until bitmapH) {
                val srcRow = bitmapH - 1 - row
                for (col in 0 until bitmapW) {
                    val base = (srcRow * bitmapW + col) * 4
                    val r = pixelBuf.get(base).toInt() and 0xFF
                    val g = pixelBuf.get(base + 1).toInt() and 0xFF
                    val b = pixelBuf.get(base + 2).toInt() and 0xFF
                    val a = pixelBuf.get(base + 3).toInt() and 0xFF
                    bitmapBuf[row * bitmapW + col] = (a shl 24) or (r shl 16) or (g shl 8) or b
                }
            }
            val bitmap = Bitmap.createBitmap(bitmapBuf, bitmapW, bitmapH, Bitmap.Config.ARGB_8888)

            // Restore the encoder surface.
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

            // Run ML Kit CPU segmenter (SINGLE_IMAGE_MODE → no temporal state).
            val resultRef = AtomicReference<MaskData?>(null)
            val errorRef  = AtomicReference<String?>(null)
            val latch = CountDownLatch(1)
            val inputImage = InputImage.fromBitmap(bitmap, 0 /* rotation */)
            seg.process(inputImage)
                .addOnSuccessListener { mask: SegmentationMask ->
                    try {
                        val confidence = FloatArray(mask.width * mask.height)
                        val buf = mask.buffer
                        buf.rewind()
                        for (i in confidence.indices) {
                            confidence[i] = buf.float
                        }
                        resultRef.set(MaskData(confidence, mask.width, mask.height))
                    } catch (t: Throwable) {
                        errorRef.set("mask_read_failed:${t.javaClass.simpleName}")
                    } finally {
                        latch.countDown()
                    }
                }
                .addOnFailureListener { e ->
                    errorRef.set("mlkit_failed:${e.message}")
                    latch.countDown()
                }

            val timedOut = !latch.await(SEGMENT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            bitmap.recycle()
            if (timedOut || cancelRequested) {
                if (timedOut) Log.w(TAG, "ML Kit segmentation timed out at frame=$frameIndex")
                return null
            }
            val err = errorRef.get()
            if (err != null) {
                Log.w(TAG, "ML Kit segmentation error at frame=$frameIndex: $err")
                return null
            }
            return resultRef.get()
        } finally {
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            GLES20.glDeleteFramebuffers(1, fboIds, 0)
            GLES20.glDeleteTextures(1, texIds, 0)
        }
    }

    /** Raw ML Kit mask confidence floats + dimensions. */
    private data class MaskData(val confidence: FloatArray, val maskW: Int, val maskH: Int)

    // ─────────────────────────────────────────────────────────────────────────
    // Upload mask and composite
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Uploads the float32 confidence mask as an 8-bit GL_ALPHA texture, then:
     *   1. Clears canvas to black.
     *   2. Draws source full-canvas (background).
     *   3. Alpha-blends camera over [cameraGeometry]'s scissor rect using the mask.
     * Returns null on success, or a failure reason string.
     *
     * [cameraRect] is the original (unscaled) layout rect passed to encode().
     * It is used exclusively to compute the rotation pivot, matching the live
     * preview compositor (AndroidDuetPreviewCompositor.drawCameraGreenScreenRotated
     * lines 1708-1709: pivotX/Y from rect.left/top + anchor * rect.width/height).
     * The aspect-fill inflated corners still come from [cameraGeometry.viewport].
     */
    private fun drawAndSubmitFrame(
        sourceGeometry: LayerGeometry,
        cameraGeometry: LayerGeometry,
        mask: MaskData,
        timelinePtsUs: Long,
        cameraRect: VGDuetPixelRect,
    ): String? {
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            return "egl_make_current_failed"
        }

        // Upload mask as GL_ALPHA texture.
        val alphaBytes = ByteBuffer.allocateDirect(mask.maskW * mask.maskH)
            .order(ByteOrder.nativeOrder())
        for (v in mask.confidence) {
            val byte = (v.coerceIn(0f, 1f) * 255f + 0.5f).toInt().coerceIn(0, 255).toByte()
            alphaBytes.put(byte)
        }
        alphaBytes.rewind()
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTexId)
        GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_ALPHA,
            mask.maskW, mask.maskH, 0,
            GLES20.GL_ALPHA, GLES20.GL_UNSIGNED_BYTE, alphaBytes,
        )
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)

        // Clear canvas.
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        // Pass 1: source video full-canvas (background), no blending.
        drawOesSlot(sourceSlot, sourceGeometry, bgProgram, aPosBg, aTexBg, uSTBg, sTexBg)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)

        // Pass 2: camera over source, blended by mask.
        //
        // When foregroundRotationDegrees is non-zero the camera quad's four
        // canvas-space corners are rotated around the anchor pivot (matching
        // AndroidDuetPreviewCompositor.drawCameraGreenScreenRotated): scissor
        // is disabled so rotated corners outside the axis-aligned rect are
        // preserved, and the full-canvas viewport is used.
        //
        // When rotation is zero the existing axis-aligned scissor/viewport path
        // is used unchanged.
        val camPositions: FloatBuffer
        val useFullViewport: Boolean

        if (foregroundRotationDegrees.isFinite() && kotlin.math.abs(foregroundRotationDegrees) > 0.0001) {
            // Rotated-quad path.
            //
            // Mirrors AndroidDuetPreviewCompositor.drawCameraGreenScreenRotated:
            //   • corners  → aspectRect (aspect-fill inflated rect, from camViewport)
            //   • pivot    → rect (the ORIGINAL layout rect, from cameraRect param)
            //
            // Defect A root cause: the previous code derived both corners and pivot
            // from cameraGeometry.viewport (the aspect-filled GL rect).  This shifts
            // the pivot when aspect-fill inflates beyond the unrotated layout rect,
            // producing a different visual rotation from live preview.
            val camViewport = cameraGeometry.viewport
                ?: return "camera:degenerate_geometry"

            // --- Corners from camViewport (aspect-fill inflated, top-left canvas space) ---
            // camViewport is GL bottom-left; convert to canvas top-left.
            val vpLeft   = camViewport.x.toDouble()
            val vpBottom = camViewport.y.toDouble()
            val vpW      = camViewport.width.toDouble()
            val vpH      = camViewport.height.toDouble()
            val vpTop    = height.toDouble() - vpBottom - vpH
            val left   = vpLeft;     val right  = vpLeft + vpW
            val top    = vpTop;      val bottom = vpTop  + vpH

            // --- Pivot from cameraRect (original unscaled layout rect, top-left canvas space) ---
            // cameraRect is already in top-left canvas coords (VGDuetPixelRect).
            val pivotX = cameraRect.left + foregroundAnchorX * cameraRect.width
            val pivotY = cameraRect.top  + foregroundAnchorY * cameraRect.height

            val radians = Math.toRadians(foregroundRotationDegrees)
            val cosT = Math.cos(radians); val sinT = Math.sin(radians)

            // Four corners in canvas-pixel space (same vertex order as quadTexCoords:
            // BL, BR, TL, TR — matching NDC (-1,-1),(1,-1),(-1,1),(1,1)).
            val cornersX = doubleArrayOf(left, right, left, right)
            val cornersY = doubleArrayOf(bottom, bottom, top, top)

            val ndc = FloatArray(8)
            for (i in 0 until 4) {
                val dx = cornersX[i] - pivotX
                val dy = cornersY[i] - pivotY
                val rx = pivotX + dx * cosT - dy * sinT
                val ry = pivotY + dx * sinT + dy * cosT
                ndc[i * 2]     = ((rx / width)  * 2.0 - 1.0).toFloat()
                ndc[i * 2 + 1] = (1.0 - (ry / height) * 2.0).toFloat()
            }
            rotatedCameraQuadPositions.position(0)
            rotatedCameraQuadPositions.put(ndc)
            rotatedCameraQuadPositions.position(0)
            camPositions = rotatedCameraQuadPositions
            useFullViewport = true
        } else {
            // Axis-aligned path (zero or identity rotation).
            val p = cameraGeometry.positions ?: return "camera:degenerate_geometry"
            camPositions = p
            useFullViewport = false
        }

        val camScissor  = cameraGeometry.scissor
        val camViewport = cameraGeometry.viewport
        if (camScissor == null || camViewport == null) {
            return "camera:degenerate_geometry"
        }

        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)

        if (useFullViewport) {
            // Rotated quad: no scissor (corners extend outside axis-aligned box).
            GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
            GLES20.glViewport(0, 0, width, height)
        } else {
            GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
            GLES20.glScissor(camScissor.x, camScissor.y, camScissor.width, camScissor.height)
            GLES20.glViewport(camViewport.x, camViewport.y, camViewport.width, camViewport.height)
        }

        GLES20.glUseProgram(blendProgram)
        // Camera OES texture → unit 0
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraSlot.oesTextureId)
        GLES20.glUniform1i(sTexCamera, 0)
        GLES20.glUniformMatrix4fv(uSTBlend, 1, false, cameraSlot.transformMatrix, 0)
        // Mask alpha texture → unit 1
        GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTexId)
        GLES20.glUniform1i(sMaskBlend, 1)

        camPositions.position(0)
        GLES20.glEnableVertexAttribArray(aPosBlend)
        GLES20.glVertexAttribPointer(aPosBlend, 2, GLES20.GL_FLOAT, false, 0, camPositions)
        quadTexCoords.position(0)
        GLES20.glEnableVertexAttribArray(aTexBlend)
        GLES20.glVertexAttribPointer(aTexBlend, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(aPosBlend)
        GLES20.glDisableVertexAttribArray(aTexBlend)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
        GLES20.glViewport(0, 0, width, height)

        val glErr = GLES20.glGetError()
        if (glErr != GLES20.GL_NO_ERROR) return "gl_error:$glErr"

        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, timelinePtsUs * 1000L)
        framesSubmitted++
        if (!EGL14.eglSwapBuffers(eglDisplay, eglSurface)) return "egl_swap_buffers_failed"
        return null
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Geometry (mirrors AndroidDuetOfflineCompositorVideoEncoder)
    // ─────────────────────────────────────────────────────────────────────────

    private data class GlRect(val x: Int, val y: Int, val width: Int, val height: Int)

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

    private fun toGlRect(left: Double, top: Double, w: Double, h: Double): GlRect {
        val wi = w.roundToInt(); val hi = h.roundToInt()
        return GlRect(left.roundToInt(), height - (top.roundToInt() + hi), wi, hi)
    }

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
        ) return LayerGeometry.failure("$label:degenerate_layer_rect")
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return LayerGeometry.failure("$label:degenerate_layer_rect")
        if (decodedWidth <= 0 || decodedHeight <= 0) return LayerGeometry.failure("$label:unknown_decoded_dimensions")

        val displayWidth: Int
        val displayHeight: Int
        if (rotationDegrees == 90 || rotationDegrees == 270) {
            displayWidth = decodedHeight; displayHeight = decodedWidth
        } else {
            displayWidth = decodedWidth; displayHeight = decodedHeight
        }
        val videoAspect = displayWidth.toDouble() / displayHeight.toDouble()
        val rectAspect  = rect.width / rect.height
        val drawnW: Double; val drawnH: Double
        if (scaleMode == AndroidDuetLayerScaleMode.ASPECT_FIT) {
            if (videoAspect > rectAspect) { drawnW = rect.width; drawnH = rect.width / videoAspect }
            else { drawnH = rect.height; drawnW = rect.height * videoAspect }
        } else {
            if (videoAspect > rectAspect) { drawnH = rect.height; drawnW = rect.height * videoAspect }
            else { drawnW = rect.width; drawnH = rect.width / videoAspect }
        }
        val viewport = toGlRect(
            rect.left + (rect.width - drawnW) / 2.0,
            rect.top  + (rect.height - drawnH) / 2.0,
            drawnW, drawnH,
        )
        if (viewport.width <= 0 || viewport.height <= 0) return LayerGeometry.failure("$label:degenerate_fill_viewport")
        val positions = rotatedQuadPositions(rotationDegrees, viewport)
            ?: return LayerGeometry.failure("$label:unsupported_rotation:$rotationDegrees")
        return LayerGeometry.success(scissor, viewport, positions)
    }

    private fun rotatedQuadPositions(rotationDegrees: Int, viewport: GlRect): FloatBuffer? {
        val cosR: Float; val sinR: Float
        when (rotationDegrees) {
            0   -> { cosR = 1f; sinR = 0f }
            90  -> { cosR = 0f; sinR = -1f }
            180 -> { cosR = -1f; sinR = 0f }
            270 -> { cosR = 0f; sinR = 1f }
            else -> return null
        }
        val halfW = viewport.width / 2f; val halfH = viewport.height / 2f
        val halfX: Float; val halfY: Float
        if (rotationDegrees == 90 || rotationDegrees == 270) { halfX = halfH; halfY = halfW }
        else { halfX = halfW; halfY = halfH }
        fun corner(x: Float, y: Float): FloatArray {
            val rx = x * cosR - y * sinR; val ry = x * sinR + y * cosR
            return floatArrayOf(rx / halfW, ry / halfH)
        }
        val bl = corner(-halfX, -halfY); val br = corner(halfX, -halfY)
        val tl = corner(-halfX, halfY);  val tr = corner(halfX, halfY)
        return floatBufferOf(bl[0], bl[1], br[0], br[1], tl[0], tl[1], tr[0], tr[1])
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Draw helper
    // ─────────────────────────────────────────────────────────────────────────

    private fun drawOesSlot(
        slot: DecodeSlot, geometry: LayerGeometry,
        program: Int, aPosLoc: Int, aTexLoc: Int, uSTLoc: Int, sTexLoc: Int,
    ) {
        val scissor = geometry.scissor ?: return
        val viewport = geometry.viewport ?: return
        val positions = geometry.positions ?: return
        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glViewport(viewport.x, viewport.y, viewport.width, viewport.height)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, slot.oesTextureId)
        GLES20.glUniform1i(sTexLoc, 0)
        GLES20.glUniformMatrix4fv(uSTLoc, 1, false, slot.transformMatrix, 0)
        positions.position(0)
        GLES20.glEnableVertexAttribArray(aPosLoc)
        GLES20.glVertexAttribPointer(aPosLoc, 2, GLES20.GL_FLOAT, false, 0, positions)
        quadTexCoords.position(0)
        GLES20.glEnableVertexAttribArray(aTexLoc)
        GLES20.glVertexAttribPointer(aTexLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(aPosLoc)
        GLES20.glDisableVertexAttribArray(aTexLoc)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Encoder drain
    // ─────────────────────────────────────────────────────────────────────────

    private fun drainEncoder(endOfStream: Boolean, deadlineMs: Long): Boolean {
        val enc = codec!!; val mx = muxer!!
        val info = MediaCodec.BufferInfo()
        val deadline = System.currentTimeMillis() + deadlineMs
        var draining = true; var eosObserved = false
        while (draining) {
            if (endOfStream && System.currentTimeMillis() > deadline) break
            val outIdx = enc.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
            when {
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> { if (!endOfStream) draining = false }
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (videoTrackIndex < 0) {
                        videoTrackIndex = mx.addTrack(enc.outputFormat); mx.start(); muxerStarted = true
                    }
                }
                outIdx >= 0 -> {
                    val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    if (!isConfig && info.size > 0 && muxerStarted && videoTrackIndex >= 0) {
                        val buf = enc.getOutputBuffer(outIdx)
                        if (buf != null) {
                            buf.position(info.offset); buf.limit(info.offset + info.size)
                            info.presentationTimeUs = ptsUsForFrame(writtenVideoSamples)
                            mx.writeSampleData(videoTrackIndex, buf, info)
                            writtenVideoSamples++
                        }
                    }
                    enc.releaseOutputBuffer(outIdx, false)
                    if (isEos) { eosObserved = true; draining = false }
                }
            }
        }
        return !endOfStream || eosObserved
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Cleanup
    // ─────────────────────────────────────────────────────────────────────────

    private fun releaseAll() {
        try { segmenter?.close() } catch (_: Throwable) {}
        segmenter = null

        try { codec?.stop() } catch (_: Throwable) {}
        try { codec?.release() } catch (_: Throwable) {}
        codec = null
        try { muxer?.release() } catch (_: Throwable) {}
        muxer = null

        if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglContext != EGL14.EGL_NO_CONTEXT) {
            try {
                EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
                sourceSlot.release()
                cameraSlot.release()
                if (maskTexId != 0) {
                    GLES20.glDeleteTextures(1, intArrayOf(maskTexId), 0)
                    maskTexId = 0
                }
                if (bgProgram != 0)    { GLES20.glDeleteProgram(bgProgram);    bgProgram = 0 }
                if (blendProgram != 0) { GLES20.glDeleteProgram(blendProgram); blendProgram = 0 }
            } catch (_: Throwable) {}
        } else {
            sourceSlot.release()
            cameraSlot.release()
        }

        try { encoderInputSurface?.release() } catch (_: Throwable) {}
        encoderInputSurface = null

        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            try { EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT) } catch (_: Throwable) {}
            if (eglSurface != EGL14.EGL_NO_SURFACE) try { EGL14.eglDestroySurface(eglDisplay, eglSurface) } catch (_: Throwable) {}
            if (eglContext != EGL14.EGL_NO_CONTEXT) try { EGL14.eglDestroyContext(eglDisplay, eglContext) } catch (_: Throwable) {}
            try { EGL14.eglTerminate(eglDisplay) } catch (_: Throwable) {}
        }
        eglSurface = EGL14.EGL_NO_SURFACE
        eglContext = EGL14.EGL_NO_CONTEXT
        eglDisplay = EGL14.EGL_NO_DISPLAY
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Decode slot (mirrors AndroidDuetOfflineCompositorVideoEncoder.DecodeSlot)
    // ─────────────────────────────────────────────────────────────────────────

    private class DecodeSlot(val label: String) {
        var oesTextureId = 0
            private set
        var inputSurface: Surface? = null
            private set
        private var surfaceTexture: SurfaceTexture? = null
        private val syncLock = Object()
        private var frameAvailable = false
        val transformMatrix = FloatArray(16).also { m ->
            m[0] = 1f; m[5] = 1f; m[10] = 1f; m[15] = 1f
        }

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
                synchronized(syncLock) { frameAvailable = true; syncLock.notifyAll() }
            }
            surfaceTexture = texture
            inputSurface = Surface(texture)
        }

        fun resetFrameAvailable() { synchronized(syncLock) { frameAvailable = false } }

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

        fun release() {
            try { inputSurface?.release() } catch (_: Throwable) {}
            try { surfaceTexture?.release() } catch (_: Throwable) {}
            if (oesTextureId != 0) {
                try { GLES20.glDeleteTextures(1, intArrayOf(oesTextureId), 0) } catch (_: Throwable) {}
            }
            oesTextureId = 0; surfaceTexture = null; inputSurface = null
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Decode pipeline (mirrors AndroidDuetOfflineCompositorVideoEncoder.DecodePipeline)
    // ─────────────────────────────────────────────────────────────────────────

    private sealed class StepOutcome {
        object Rendered : StepOutcome()
        object Held : StepOutcome()
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
        private var pendingIndex = -1; private var pendingPtsUs = 0L
        private var candidateIndex = -1; private var candidatePtsUs = 0L
        private var hasRenderedFrame = false
        private val startOffsetUs = (input.startOffsetSeconds * 1_000_000.0).toLong().coerceAtLeast(0L)
        private val inputEndUs = startOffsetUs + windowDurationUs + INPUT_END_MARGIN_US
        var decodedWidth = 0; private set
        var decodedHeight = 0; private set

        fun open(): String? {
            return try {
            extractor.setDataSource(input.sourcePath)
            var trackIndex = -1; var trackFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                    trackIndex = i; trackFormat = f; break
                }
            }
            if (trackIndex < 0 || trackFormat == null) return "${input.label}:no_video_track"
            extractor.selectTrack(trackIndex)
            decodedWidth  = if (trackFormat.containsKey(MediaFormat.KEY_WIDTH))  trackFormat.getInteger(MediaFormat.KEY_WIDTH)  else input.hintWidth
            decodedHeight = if (trackFormat.containsKey(MediaFormat.KEY_HEIGHT)) trackFormat.getInteger(MediaFormat.KEY_HEIGHT) else input.hintHeight
            if (decodedWidth <= 0)  decodedWidth  = input.hintWidth
            if (decodedHeight <= 0) decodedHeight = input.hintHeight
            if (startOffsetUs > 0L) extractor.seekTo(startOffsetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val mime = trackFormat.getString(MediaFormat.KEY_MIME)!!
            val dec = MediaCodec.createDecoderByType(mime)
            dec.configure(trackFormat, slot.inputSurface, null, 0)
            dec.start(); decoder = dec; null
        } catch (t: Throwable) { "${input.label}:open_exception:${t.javaClass.simpleName}" }
        }

        fun stepTo(timelinePtsUs: Long): StepOutcome {
            val dec = decoder ?: return StepOutcome.Failed("${input.label}:decoder_not_open")
            val targetUs = startOffsetUs + timelinePtsUs
            try {
                if (pendingIndex >= 0) {
                    if (pendingPtsUs <= targetUs) {
                        candidateIndex = pendingIndex; candidatePtsUs = pendingPtsUs; pendingIndex = -1
                    } else return StepOutcome.Held
                }
                val info = MediaCodec.BufferInfo()
                while (true) {
                    if (cancelRequested) { dropCandidate(dec); return StepOutcome.Cancelled }
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
                                when {
                                    pts <= targetUs -> {
                                        if (candidateIndex >= 0) dec.releaseOutputBuffer(candidateIndex, false)
                                        candidateIndex = outIdx; candidatePtsUs = pts
                                        if (isEos) outputEos = true
                                    }
                                    candidateIndex >= 0 -> {
                                        pendingIndex = outIdx; pendingPtsUs = pts
                                        if (isEos) outputEos = true
                                        return renderCandidate(dec)
                                    }
                                    !hasRenderedFrame -> {
                                        candidateIndex = outIdx; candidatePtsUs = pts
                                        if (isEos) outputEos = true
                                        return renderCandidate(dec)
                                    }
                                    else -> {
                                        pendingIndex = outIdx; pendingPtsUs = pts
                                        if (isEos) outputEos = true
                                        return StepOutcome.Held
                                    }
                                }
                            } else {
                                dec.releaseOutputBuffer(outIdx, false)
                                if (isEos) outputEos = true
                            }
                        }
                        outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                            stallAttempts++
                            if (stallAttempts > MAX_STALL_ATTEMPTS) {
                                dropCandidate(dec); return StepOutcome.Failed("${input.label}:decoder_stalled")
                            }
                        }
                        else -> Unit
                    }
                }
            } catch (t: Throwable) {
                return StepOutcome.Failed("${input.label}:decode_exception:${t.javaClass.simpleName}")
            }
        }

        private fun feedInput(dec: MediaCodec) {
            val inIdx = dec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
            if (inIdx < 0) return
            val buf = dec.getInputBuffer(inIdx) ?: throw IllegalStateException("${input.label}: null input buffer")
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
            val idx = candidateIndex; candidateIndex = -1
            slot.resetFrameAvailable()
            dec.releaseOutputBuffer(idx, true)
            if (!slot.awaitNewImage(FRAME_WAIT_TIMEOUT_MS)) {
                return StepOutcome.Failed("${input.label}:frame_transfer_timeout")
            }
            hasRenderedFrame = true; return StepOutcome.Rendered
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
        private const val TAG = "VGDuetGSOfflineCompositor"
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val FRAME_WAIT_TIMEOUT_MS = 2_000L
        private const val ENCODE_DRAIN_DEADLINE_MS = 2_000L
        private const val ENCODE_EOS_DEADLINE_MS = 5_000L
        private const val MAX_STALL_ATTEMPTS = 500
        private const val INPUT_END_MARGIN_US = 250_000L
        /** Maximum wait for a single ML Kit SINGLE_IMAGE_MODE segmentation task. */
        private const val SEGMENT_TIMEOUT_MS = 5_000L

        private fun floatBufferOf(vararg values: Float): FloatBuffer =
            ByteBuffer.allocateDirect(values.size * 4)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()
                .apply { put(values); position(0) }
    }
}
