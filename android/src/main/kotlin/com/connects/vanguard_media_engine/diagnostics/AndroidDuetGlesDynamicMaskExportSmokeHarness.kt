package com.connects.vanguard_media_engine.diagnostics

import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.util.Log
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Diagnostic-only physical proof harness for DEC-V2-107: Android Duet deterministic
 * per-frame GLES mask upload export proof.
 *
 * Proof boundary: [PROOF_BOUNDARY].
 *
 * Verifies that Android can:
 * 1. Configure a MediaCodec AVC encoder with an EGL14 window input surface and MediaMuxer.
 * 2. Upload a time-varying single-channel GL_LUMINANCE mask texture per encoded frame
 *    (using non-multiple-of-4 dimensions 63x63 to force and verify GL_UNPACK_ALIGNMENT=1
 *    restoration).
 * 3. Blend deterministic foreground and background colors in GLES 2.0 via mix(background,
 *    foreground, mask.r) with dithering disabled and output opaque alpha.
 * 4. Encode 4 frames with deterministic alphas [0, 255, 128, 64] to MP4 via MediaCodec input
 *    surface, swapping buffers and tagging EGLExt.eglPresentationTimeANDROID per frame.
 * 5. Decode/sample the produced MP4 via MediaMetadataRetriever and verify center pixel RGB
 *    values within lossy tolerance (36), ensuring boundary keying (0=background, 255=foreground),
 *    fractional blending (128, 64), and inter-frame variation.
 * 6. Clean up all temporary files and GPU/codec resources cleanly.
 */
class AndroidDuetGlesDynamicMaskExportSmokeHarness {

    companion object {
        private const val TAG = "VGDuetGlesDynMask"
        const val PROOF_BOUNDARY =
            "android_duet_gles_dynamic_mask_export_per_frame_upload_mediacodec_mp4_only"
        const val START_MARKER = "ANDROID_DUET_GLES_DYNAMIC_MASK_EXPORT_START"
        const val MASK_UPLOAD_PASS_MARKER = "ANDROID_DUET_GLES_DYNAMIC_MASK_EXPORT_MASK_UPLOAD_PASS"
        const val FRAME_VARIATION_PASS_MARKER = "ANDROID_DUET_GLES_DYNAMIC_MASK_EXPORT_FRAME_VARIATION_PASS"
        const val PASS_MARKER = "ANDROID_DUET_GLES_DYNAMIC_MASK_EXPORT_PHYSICAL_PASS"
        const val FAIL_MARKER = "ANDROID_DUET_GLES_DYNAMIC_MASK_EXPORT_PHYSICAL_FAIL"

        const val LOSSY_RGB_TOLERANCE = 36
        private const val MAX_MISMATCHES = 12

        private const val ENCODE_WIDTH = 256
        private const val ENCODE_HEIGHT = 256
        private const val MASK_WIDTH = 63
        private const val MASK_HEIGHT = 63

        private const val FPS = 10
        private const val FRAME_DURATION_US = 100_000L
        private const val BITRATE_BPS = 4_000_000

        // Generated colors: deterministic proof, avoids fake ML claims
        const val BG_R = 30
        const val BG_G = 100
        const val BG_B = 210

        const val FG_R = 230
        const val FG_G = 40
        const val FG_B = 180

        val FRAME_ALPHAS = intArrayOf(0, 255, 128, 64)

        val REAL_GATES = listOf(
            "inputValidationOk",
            "codecSetupOk",
            "eglSetupOk",
            "shaderProgramOk",
            "dynamicMaskUploadOk",
            "encodedMp4Ok",
            "frameExtractOk",
            "alphaZeroBackgroundOk",
            "alphaFullForegroundOk",
            "alphaFractionalBlendOk",
            "frameVariationOk",
            "cleanupOk",
        )

        val RESULT_GATES = listOf(
            "canonical",
        )

        val REQUIRED_GATES = REAL_GATES + RESULT_GATES

        val NON_CLAIMS = listOf(
            "No live ML human matte quality.",
            "No live CameraX/OES lifecycle.",
            "No production Duet recording/export branch.",
            "No source-video decoder composition.",
            "No multi-track audio/A-V sync.",
            "No ConnectsApp/Universal Editor/upload wiring.",
            "No low-end Android proof.",
        )

        private val QUAD_POSITIONS = floatArrayOf(
            -1f, -1f,
             1f, -1f,
            -1f,  1f,
             1f,  1f,
        )

        private val QUAD_TEX_COORDS = floatArrayOf(
            0f, 0f,
            1f, 0f,
            0f, 1f,
            1f, 1f,
        )
    }

    private val quadPositionBuffer: FloatBuffer =
        ByteBuffer.allocateDirect(QUAD_POSITIONS.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply {
                put(QUAD_POSITIONS)
                position(0)
            }

    private val quadTexCoordBuffer: FloatBuffer =
        ByteBuffer.allocateDirect(QUAD_TEX_COORDS.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply {
                put(QUAD_TEX_COORDS)
                position(0)
            }

    /**
     * Executes the deterministic per-frame GLES mask upload export proof. Never throws.
     */
    fun run(outputDir: String?): Map<String, Any?> {
        Log.i(TAG, START_MARKER)
        println(START_MARKER)

        val gates = LinkedHashMap<String, Boolean>()
        for (key in REQUIRED_GATES) gates[key] = false
        val details = LinkedHashMap<String, Any?>()
        val mismatches = mutableListOf<String>()
        var firstFailureReason: String? = null
        var maxDelta = 0
        var sampleCount = 0

        fun noteFailure(reason: String) {
            if (firstFailureReason == null) {
                firstFailureReason = reason
            }
        }

        // 1. Input Validation
        val outDirFile = outputDir?.let { File(it) }
        val inputValidationOk = outDirFile != null && outDirFile.exists() && outDirFile.isDirectory
        gates["inputValidationOk"] = inputValidationOk
        details["outputDir"] = outputDir

        if (!inputValidationOk) {
            val reason = "invalid_output_dir:$outputDir"
            noteFailure(reason)
            gates["cleanupOk"] = true
            return buildResult(false, reason, gates, mismatches, -1, 0, details)
        }

        val timestamp = System.currentTimeMillis()
        val tempFile = File(outDirFile!!, "duet_gles_dyn_mask_export_${timestamp}.mp4")
        details["tempFilePath"] = tempFile.absolutePath

        var codec: MediaCodec? = null
        var encoderInputSurface: Surface? = null
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        var videoTrackIndex = -1
        var writtenVideoSamples = 0

        var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
        var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
        var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
        var ditherWasEnabled = false
        var program = 0
        var maskTextureId = 0

        try {
            // 2. MediaCodec AVC Encoder & MediaMuxer Setup
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, ENCODE_WIDTH, ENCODE_HEIGHT).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, BITRATE_BPS)
                setInteger(MediaFormat.KEY_FRAME_RATE, FPS)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }

            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = enc.createInputSurface()
            val mux = MediaMuxer(tempFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            enc.start()

            codec = enc
            encoderInputSurface = surface
            muxer = mux
            gates["codecSetupOk"] = true

            // 3. EGL Setup with encoderInputSurface
            eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (eglDisplay == EGL14.EGL_NO_DISPLAY) {
                noteFailure("egl_get_display_failed")
                return buildResult(false, firstFailureReason!!, gates, mismatches, -1, 0, details)
            }
            val version = IntArray(2)
            if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
                noteFailure("egl_initialize_failed")
                return buildResult(false, firstFailureReason!!, gates, mismatches, -1, 0, details)
            }

            val attribs = intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfigs = IntArray(1)
            if (!EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, 1, numConfigs, 0) || numConfigs[0] < 1) {
                noteFailure("egl_choose_config_failed")
                return buildResult(false, firstFailureReason!!, gates, mismatches, -1, 0, details)
            }
            val config = configs[0] ?: run {
                noteFailure("egl_null_config")
                return buildResult(false, firstFailureReason!!, gates, mismatches, -1, 0, details)
            }

            val contextAttribs = intArrayOf(
                EGL14.EGL_CONTEXT_CLIENT_VERSION, 2,
                EGL14.EGL_NONE,
            )
            eglContext = EGL14.eglCreateContext(eglDisplay, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
            if (eglContext == EGL14.EGL_NO_CONTEXT) {
                noteFailure("egl_create_context_failed")
                return buildResult(false, firstFailureReason!!, gates, mismatches, -1, 0, details)
            }

            val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)
            eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, config, surface, surfaceAttribs, 0)
            if (eglSurface == EGL14.EGL_NO_SURFACE) {
                noteFailure("egl_create_window_surface_failed")
                return buildResult(false, firstFailureReason!!, gates, mismatches, -1, 0, details)
            }

            if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
                noteFailure("egl_make_current_failed")
                return buildResult(false, firstFailureReason!!, gates, mismatches, -1, 0, details)
            }
            gates["eglSetupOk"] = true

            // Disable dithering during proof pass for deterministic pixel arithmetic
            ditherWasEnabled = GLES20.glIsEnabled(GLES20.GL_DITHER)
            GLES20.glDisable(GLES20.GL_DITHER)
            details["ditherDisabled"] = true

            // 4. GLES 2.0 Shader Program
            val vertexSrc = """
                attribute vec4 aPosition;
                attribute vec2 aTextureCoord;
                varying vec2 vTextureCoord;
                void main() {
                    gl_Position = aPosition;
                    vTextureCoord = aTextureCoord;
                }
            """.trimIndent()

            val fragmentSrc = """
                precision mediump float;
                varying vec2 vTextureCoord;
                uniform sampler2D uMask;
                uniform vec3 uBackgroundColor;
                uniform vec3 uForegroundColor;
                void main() {
                    float maskAlpha = texture2D(uMask, vTextureCoord).r;
                    vec3 blended = mix(uBackgroundColor, uForegroundColor, maskAlpha);
                    gl_FragColor = vec4(blended, 1.0);
                }
            """.trimIndent()

            program = buildProgram(vertexSrc, fragmentSrc)
            if (program == 0) {
                noteFailure("shader_program_link_failed")
                return buildResult(false, firstFailureReason!!, gates, mismatches, -1, 0, details)
            }

            val aPositionLoc = GLES20.glGetAttribLocation(program, "aPosition")
            val aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTextureCoord")
            val uMaskLoc = GLES20.glGetUniformLocation(program, "uMask")
            val uBgLoc = GLES20.glGetUniformLocation(program, "uBackgroundColor")
            val uFgLoc = GLES20.glGetUniformLocation(program, "uForegroundColor")

            if (aPositionLoc < 0 || aTexCoordLoc < 0 || uMaskLoc < 0 || uBgLoc < 0 || uFgLoc < 0) {
                noteFailure("shader_locations_unresolved")
                return buildResult(false, firstFailureReason!!, gates, mismatches, -1, 0, details)
            }
            gates["shaderProgramOk"] = true

            // 5. Create GL_LUMINANCE Mask Texture (63x63 non-multiple-of-4)
            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            maskTextureId = textures[0]
            if (maskTextureId == 0) {
                noteFailure("mask_texture_creation_failed")
                return buildResult(false, firstFailureReason!!, gates, mismatches, -1, 0, details)
            }
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTextureId)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)

            val bufferInfo = MediaCodec.BufferInfo()

            fun drainEncoder(endOfStream: Boolean, timeoutMs: Long) {
                val deadline = System.currentTimeMillis() + timeoutMs
                var draining = true
                while (draining) {
                    val outIdx = enc.dequeueOutputBuffer(bufferInfo, 10_000L)
                    when {
                        outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                            if (!endOfStream || System.currentTimeMillis() > deadline) {
                                draining = false
                            }
                        }
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            if (videoTrackIndex < 0) {
                                val outFormat = enc.outputFormat
                                videoTrackIndex = mux.addTrack(outFormat)
                                mux.start()
                                muxerStarted = true
                            }
                        }
                        outIdx >= 0 -> {
                            val isConfig = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                            val isEos = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                            if (!isConfig && bufferInfo.size > 0 && muxerStarted && videoTrackIndex >= 0) {
                                val encodedData = enc.getOutputBuffer(outIdx)
                                if (encodedData != null) {
                                    encodedData.position(bufferInfo.offset)
                                    encodedData.limit(bufferInfo.offset + bufferInfo.size)
                                    bufferInfo.presentationTimeUs = writtenVideoSamples * FRAME_DURATION_US
                                    mux.writeSampleData(videoTrackIndex, encodedData, bufferInfo)
                                    writtenVideoSamples++
                                }
                            }
                            enc.releaseOutputBuffer(outIdx, false)
                            if (isEos) {
                                draining = false
                            }
                        }
                    }
                }
            }

            // 6. Encode 4 frames with per-frame dynamic mask upload
            var allMaskUploadsOk = true
            for (frameIdx in FRAME_ALPHAS.indices) {
                val alphaVal = FRAME_ALPHAS[frameIdx]
                val maskBuffer = ByteBuffer.allocateDirect(MASK_WIDTH * MASK_HEIGHT)
                    .order(ByteOrder.nativeOrder())
                val alphaByte = alphaVal.toByte()
                for (i in 0 until MASK_WIDTH * MASK_HEIGHT) {
                    maskBuffer.put(alphaByte)
                }
                maskBuffer.rewind()

                // Mask upload with strict GL_UNPACK_ALIGNMENT=1 enforcement and restoration
                val prevAlignment = IntArray(1)
                GLES20.glGetIntegerv(GLES20.GL_UNPACK_ALIGNMENT, prevAlignment, 0)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTextureId)
                try {
                    GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
                    GLES20.glTexImage2D(
                        GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE,
                        MASK_WIDTH, MASK_HEIGHT, 0,
                        GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, maskBuffer,
                    )
                } finally {
                    GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, prevAlignment[0])
                }
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)

                val restoredAlignment = IntArray(1)
                GLES20.glGetIntegerv(GLES20.GL_UNPACK_ALIGNMENT, restoredAlignment, 0)
                if (restoredAlignment[0] != prevAlignment[0]) {
                    allMaskUploadsOk = false
                    noteFailure("unpack_alignment_not_restored_frame_$frameIdx")
                    break
                }
                if (GLES20.glGetError() != GLES20.GL_NO_ERROR) {
                    allMaskUploadsOk = false
                    noteFailure("mask_upload_gl_error_frame_$frameIdx")
                    break
                }

                // Render full-frame quad
                GLES20.glViewport(0, 0, ENCODE_WIDTH, ENCODE_HEIGHT)
                GLES20.glClearColor(0f, 0f, 0f, 1f)
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

                GLES20.glUseProgram(program)
                GLES20.glUniform3f(uBgLoc, BG_R / 255f, BG_G / 255f, BG_B / 255f)
                GLES20.glUniform3f(uFgLoc, FG_R / 255f, FG_G / 255f, FG_B / 255f)

                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTextureId)
                GLES20.glUniform1i(uMaskLoc, 0)

                quadPositionBuffer.position(0)
                GLES20.glEnableVertexAttribArray(aPositionLoc)
                GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadPositionBuffer)

                quadTexCoordBuffer.position(0)
                GLES20.glEnableVertexAttribArray(aTexCoordLoc)
                GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoordBuffer)

                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

                GLES20.glDisableVertexAttribArray(aPositionLoc)
                GLES20.glDisableVertexAttribArray(aTexCoordLoc)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
                GLES20.glFinish()

                val presentationTimeNs = frameIdx * FRAME_DURATION_US * 1000L
                EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, presentationTimeNs)
                EGL14.eglSwapBuffers(eglDisplay, eglSurface)

                drainEncoder(endOfStream = false, timeoutMs = 100L)
            }

            gates["dynamicMaskUploadOk"] = allMaskUploadsOk
            if (allMaskUploadsOk) {
                Log.i(TAG, MASK_UPLOAD_PASS_MARKER)
                println(MASK_UPLOAD_PASS_MARKER)
            }

            // 7. Drain MediaCodec to End of Stream and Finalize Muxer
            enc.signalEndOfInputStream()
            drainEncoder(endOfStream = true, timeoutMs = 5000L)

            if (muxerStarted && writtenVideoSamples > 0) {
                try {
                    mux.stop()
                } catch (t: Throwable) {
                    Log.w(TAG, "muxer.stop failed: $t")
                }
            }

            val encodedMp4Ok = tempFile.exists() && tempFile.length() > 0L && writtenVideoSamples >= 4
            gates["encodedMp4Ok"] = encodedMp4Ok
            details["writtenVideoSamples"] = writtenVideoSamples
            details["mp4SizeBytes"] = tempFile.length()

            if (!encodedMp4Ok) {
                noteFailure("encoded_mp4_failed:exists=${tempFile.exists()},size=${tempFile.length()},samples=$writtenVideoSamples")
            } else {
                // 8. Decode/sample the produced MP4 with MediaMetadataRetriever
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(tempFile.absolutePath)
                    val decodedBitmaps = mutableListOf<Bitmap>()
                    for (i in 0 until 4) {
                        val timeUs = i * FRAME_DURATION_US
                        val bm = retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
                            ?: retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                            ?: retriever.getFrameAtTime(timeUs)
                        if (bm != null) {
                            decodedBitmaps.add(bm)
                        }
                    }

                    val frameExtractOk = decodedBitmaps.size == 4
                    gates["frameExtractOk"] = frameExtractOk

                    if (!frameExtractOk) {
                        noteFailure("frame_extract_failed:extracted=${decodedBitmaps.size}/4")
                    } else {
                        val decodedRgbs = mutableListOf<IntArray>()
                        val sampleDeltas = mutableListOf<Int>()

                        for (i in 0 until 4) {
                            val bm = decodedBitmaps[i]
                            val cx = bm.width / 2
                            val cy = bm.height / 2
                            val px = bm.getPixel(cx, cy)
                            val r = Color.red(px)
                            val g = Color.green(px)
                            val b = Color.blue(px)
                            decodedRgbs.add(intArrayOf(r, g, b))

                            val alpha = FRAME_ALPHAS[i]
                            val expR = ((BG_R * (255 - alpha) + FG_R * alpha) / 255.0).roundToInt()
                            val expG = ((BG_G * (255 - alpha) + FG_G * alpha) / 255.0).roundToInt()
                            val expB = ((BG_B * (255 - alpha) + FG_B * alpha) / 255.0).roundToInt()

                            val dR = abs(r - expR)
                            val dG = abs(g - expG)
                            val dB = abs(b - expB)
                            val maxD = maxOf(dR, dG, dB)
                            sampleDeltas.add(maxD)
                            maxDelta = maxOf(maxDelta, maxD)
                            sampleCount++

                            if (maxD > LOSSY_RGB_TOLERANCE) {
                                if (mismatches.size < MAX_MISMATCHES) {
                                    mismatches.add(
                                        "frame=$i alpha=$alpha actual=($r,$g,$b) expected=($expR,$expG,$expB) maxDelta=$maxD",
                                    )
                                }
                            }
                            details["frame_${i}_actualRgb"] = "$r,$g,$b"
                            details["frame_${i}_expectedRgb"] = "$expR,$expG,$expB"
                            details["frame_${i}_maxDelta"] = maxD
                        }

                        val alphaZeroBackgroundOk = sampleDeltas[0] <= LOSSY_RGB_TOLERANCE
                        val alphaFullForegroundOk = sampleDeltas[1] <= LOSSY_RGB_TOLERANCE
                        val alphaFractionalBlendOk =
                            sampleDeltas[2] <= LOSSY_RGB_TOLERANCE && sampleDeltas[3] <= LOSSY_RGB_TOLERANCE

                        gates["alphaZeroBackgroundOk"] = alphaZeroBackgroundOk
                        gates["alphaFullForegroundOk"] = alphaFullForegroundOk
                        gates["alphaFractionalBlendOk"] = alphaFractionalBlendOk

                        if (!alphaZeroBackgroundOk) noteFailure("alpha_zero_background_mismatch:delta=${sampleDeltas[0]}")
                        if (!alphaFullForegroundOk) noteFailure("alpha_full_foreground_mismatch:delta=${sampleDeltas[1]}")
                        if (!alphaFractionalBlendOk) noteFailure("alpha_fractional_blend_mismatch:d2=${sampleDeltas[2]},d3=${sampleDeltas[3]}")

                        // Frame variation verification across decoded frames
                        val rgb0 = decodedRgbs[0]
                        val rgb1 = decodedRgbs[1]
                        val rgb2 = decodedRgbs[2]
                        val rgb3 = decodedRgbs[3]

                        val var01 = maxOf(abs(rgb0[0] - rgb1[0]), abs(rgb0[1] - rgb1[1]), abs(rgb0[2] - rgb1[2]))
                        val var12 = maxOf(abs(rgb1[0] - rgb2[0]), abs(rgb1[1] - rgb2[1]), abs(rgb1[2] - rgb2[2]))
                        val var23 = maxOf(abs(rgb2[0] - rgb3[0]), abs(rgb2[1] - rgb3[1]), abs(rgb2[2] - rgb3[2]))

                        val frameVariationOk = var01 > LOSSY_RGB_TOLERANCE && var12 > 10 && var23 > 10
                        gates["frameVariationOk"] = frameVariationOk
                        details["frameVariation_0_1"] = var01
                        details["frameVariation_1_2"] = var12
                        details["frameVariation_2_3"] = var23

                        if (frameVariationOk) {
                            Log.i(TAG, FRAME_VARIATION_PASS_MARKER)
                            println(FRAME_VARIATION_PASS_MARKER)
                        } else {
                            noteFailure("frame_variation_failed:var01=$var01,var12=$var12,var23=$var23")
                        }
                    }
                } finally {
                    try {
                        retriever.release()
                    } catch (_: Throwable) {
                    }
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "Exception during dynamic mask export harness run", t)
            noteFailure("exception:${t.javaClass.simpleName}:${t.message}")
            details["exception"] = "${t.javaClass.simpleName}:${t.message}"
        } finally {
            try {
                if (ditherWasEnabled) GLES20.glEnable(GLES20.GL_DITHER)
            } catch (_: Throwable) {
            }
            try {
                if (maskTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(maskTextureId), 0)
            } catch (_: Throwable) {
            }
            try {
                if (program != 0) GLES20.glDeleteProgram(program)
            } catch (_: Throwable) {
            }
            if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                try {
                    EGL14.eglMakeCurrent(
                        eglDisplay,
                        EGL14.EGL_NO_SURFACE,
                        EGL14.EGL_NO_SURFACE,
                        EGL14.EGL_NO_CONTEXT,
                    )
                } catch (_: Throwable) {
                }
                try {
                    if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
                } catch (_: Throwable) {
                }
                try {
                    if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
                } catch (_: Throwable) {
                }
                try {
                    EGL14.eglTerminate(eglDisplay)
                } catch (_: Throwable) {
                }
            }
            try {
                encoderInputSurface?.release()
            } catch (_: Throwable) {
            }
            try {
                codec?.stop()
            } catch (_: Throwable) {
            }
            try {
                codec?.release()
            } catch (_: Throwable) {
            }
            try {
                muxer?.release()
            } catch (_: Throwable) {
            }

            var cleanupSuccessful = true
            try {
                if (tempFile.exists()) {
                    cleanupSuccessful = tempFile.delete()
                }
            } catch (_: Throwable) {
                cleanupSuccessful = false
            }
            gates["cleanupOk"] = cleanupSuccessful && !tempFile.exists()
            if (!gates["cleanupOk"]!!) {
                noteFailure("cleanup_failed_lingering_temp_mp4")
            }
        }

        val canonical = REAL_GATES.all { gates[it] == true }
        gates["canonical"] = canonical
        val pass = canonical && (maxDelta <= LOSSY_RGB_TOLERANCE) && sampleCount >= 4 && mismatches.isEmpty() && firstFailureReason == null
        val failureReason = if (pass) "" else (firstFailureReason ?: "smoke_failed")

        return buildResult(pass, failureReason, gates, mismatches, maxDelta, sampleCount, details)
    }

    private fun buildProgram(vertexSrc: String, fragmentSrc: String): Int {
        val vs = compileShader(GLES20.GL_VERTEX_SHADER, vertexSrc)
        if (vs == 0) return 0
        val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        if (fs == 0) {
            GLES20.glDeleteShader(vs)
            return 0
        }
        val prog = GLES20.glCreateProgram()
        if (prog == 0) {
            GLES20.glDeleteShader(vs)
            GLES20.glDeleteShader(fs)
            return 0
        }
        GLES20.glAttachShader(prog, vs)
        GLES20.glAttachShader(prog, fs)
        GLES20.glLinkProgram(prog)
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(prog)
            Log.e(TAG, "Program link failed: $log")
            GLES20.glDeleteProgram(prog)
            return 0
        }
        return prog
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES20.glCreateShader(type)
        if (shader == 0) return 0
        GLES20.glShaderSource(shader, src)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(shader)
            Log.e(TAG, "Shader compile failed: $log")
            GLES20.glDeleteShader(shader)
            return 0
        }
        return shader
    }

    private fun buildResult(
        pass: Boolean,
        failureReason: String,
        gates: Map<String, Boolean>,
        mismatches: List<String>,
        maxDelta: Int,
        sampleCount: Int,
        details: Map<String, Any?>,
    ): Map<String, Any?> {
        val marker = if (pass) PASS_MARKER else FAIL_MARKER
        if (pass) {
            Log.i(TAG, PASS_MARKER)
            println(PASS_MARKER)
        } else {
            val failLog = "$FAIL_MARKER failureReason=$failureReason maxDelta=$maxDelta gates=$gates mismatchCount=${mismatches.size}"
            Log.e(TAG, failLog)
            println(failLog)
            for (mismatch in mismatches) {
                val mismatchLog = "DUET_GLES_DYN_MASK_MISMATCH $mismatch"
                Log.e(TAG, mismatchLog)
                println(mismatchLog)
            }
        }

        val map = LinkedHashMap<String, Any?>()
        map["pass"] = pass
        map["status"] = if (pass) "PASS" else "FAIL"
        map["marker"] = marker
        map["proofBoundary"] = PROOF_BOUNDARY
        map["gates"] = LinkedHashMap(gates)
        map["lossyRgbTolerance"] = LOSSY_RGB_TOLERANCE
        map["maxDelta"] = maxDelta
        map["sampleCount"] = sampleCount
        map["mismatches"] = mismatches
        map["details"] = LinkedHashMap(details)
        map["failureReason"] = failureReason
        map["nonClaims"] = NON_CLAIMS
        return map
    }
}
