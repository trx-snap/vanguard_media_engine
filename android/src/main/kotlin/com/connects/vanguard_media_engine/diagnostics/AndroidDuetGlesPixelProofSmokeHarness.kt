package com.connects.vanguard_media_engine.diagnostics

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Android Duet deterministic GLES matte-upload + composited-pixel proof harness (Stage 1).
 *
 * Verifies:
 * 1. Offscreen EGL pbuffer/context setup and teardown.
 * 2. Texture-backed GL_RGBA framebuffer object setup.
 * 3. GLES 2.0 shader pair compilation and linking.
 * 4. Synthetic camera texture (sampler2D) and mask texture (GL_LUMINANCE / GL_UNSIGNED_BYTE).
 * 5. Non-multiple-of-4 mask width (63x63) proving row packing requiring GL_UNPACK_ALIGNMENT=1.
 * 6. Direct UINT8_ALPHA confidence upload and FLOAT32_CONFIDENCE [0.0..1.0] -> 0..255 byte conversion.
 * 7. Green-screen blend math: cameraColor * (cameraAlpha * maskAlpha) over opaque background
 *    using GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA with GL_DITHER disabled.
 * 8. Boundary keying: alpha=0 produces background, alpha=255 produces camera (tolerance <= 1).
 * 9. Viewport and scissor exterior preservation on a 257x257 surface (tolerance <= 1).
 *
 * Proof Boundary:
 *   "android_duet_gles_pixel_proof_synthetic_mask_upload_and_blend_only"
 * Diagnostic only: no ML human matte quality claim, no CameraX/OES external texture claim,
 * no live preview lifecycle, no export MP4/A/V sync, no GPU delegate promotion.
 */
class AndroidDuetGlesPixelProofSmokeHarness {

    companion object {
        private const val TAG = "DuetGlesPixelProof"
        private const val PROOF_BOUNDARY =
            "android_duet_gles_pixel_proof_synthetic_mask_upload_and_blend_only"
        private const val PASS_MARKER = "ANDROID_DUET_GLES_PIXEL_PROOF_PHYSICAL_PASS"
        private const val FAIL_MARKER = "ANDROID_DUET_GLES_PIXEL_PROOF_PHYSICAL_FAIL"
        private const val MASK_UPLOAD_PASS_MARKER = "ANDROID_DUET_GLES_PIXEL_PROOF_MASK_UPLOAD_PASS"
        private const val BLEND_PASS_MARKER = "ANDROID_DUET_GLES_PIXEL_PROOF_BLEND_PASS"
        private const val START_MARKER = "ANDROID_DUET_GLES_PIXEL_PROOF_START"

        private const val TOLERANCE = 1

        // Framebuffer surface dimensions: non-multiple-of-4 and != mask size
        private const val SURFACE_WIDTH = 257
        private const val SURFACE_HEIGHT = 257

        // Mask dimensions: non-multiple-of-4 to verify GL_UNPACK_ALIGNMENT=1
        private const val MASK_WIDTH = 63
        private const val MASK_HEIGHT = 63

        // Draw rect inside framebuffer: offset from origin; 189 = 63 * 3
        private const val DRAW_RECT_X = 31; private const val DRAW_RECT_Y = 37
        private const val DRAW_RECT_W = 189; private const val DRAW_RECT_H = 189

        // Colors (RGBA8)
        private const val SENTINEL_R = 12; private const val SENTINEL_G = 34
        private const val SENTINEL_B = 56; private const val SENTINEL_A = 255

        private const val BACKGROUND_R = 40; private const val BACKGROUND_G = 160
        private const val BACKGROUND_B = 80; private const val BACKGROUND_A = 255

        private const val CAMERA_R = 220; private const val CAMERA_G = 60
        private const val CAMERA_B = 140; private const val CAMERA_A = 255

        private val GATE_KEYS = listOf(
            "eglSetupOk",
            "framebufferSetupOk",
            "shaderProgramOk",
            "uint8MaskUploadOk",
            "floatMaskUploadOk",
            "blendMathOk",
            "boundaryKeyingOk",
            "viewportScissorOk",
            "cleanupOk",
        )

        private val NON_CLAIMS = listOf(
            "No ML human matte quality claim (synthetic mask patterns only)",
            "No CameraX or OES external texture claim (sampler2D synthetic camera used)",
            "No live preview lifecycle or SurfaceTexture concurrency claim",
            "No export MP4, MediaCodec, or A/V sync claim",
            "No GPU delegate promotion or TFLite/MediaPipe runtime claim",
        )

        private val QUAD_POSITIONS = floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
        private val QUAD_TEX_COORDS = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)
        private val IDENTITY_MATRIX = floatArrayOf(
            1f, 0f, 0f, 0f,
            0f, 1f, 0f, 0f,
            0f, 0f, 1f, 0f,
            0f, 0f, 0f, 1f,
        )

        // Exterior sample coordinates outside [DRAW_RECT_X, DRAW_RECT_X + DRAW_RECT_W - 1] x [DRAW_RECT_Y, DRAW_RECT_Y + DRAW_RECT_H - 1]
        private val EXTERIOR_PROBE_POINTS = listOf(5 to 5, 15 to 100, 240 to 240, 100 to 245, 100 to 10)
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
     * Executes the deterministic GLES pixel proof. Never throws.
     */
    fun run(): Map<String, Any?> {
        Log.i(TAG, START_MARKER)
        println(START_MARKER)

        val gates = linkedMapOf<String, Boolean>()
        for (key in GATE_KEYS) gates[key] = false
        val details = linkedMapOf<String, Any?>()
        var failureReason = ""
        var maxDeltaOverall = 0
        var sampleCountOverall = 0

        fun fail(reason: String) {
            if (failureReason.isEmpty()) {
                failureReason = reason
            }
        }

        var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
        var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
        var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
        var fboId = 0
        var colorTextureId = 0
        var ditherWasEnabled = false
        var program = 0
        var cameraTextureId = 0
        var maskTextureId = 0
        val mismatches = mutableListOf<String>()

        fun executeHarness() {
            // 1. EGL Initialization
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
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfigs = IntArray(1)
            if (!EGL14.eglChooseConfig(eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0) ||
                numConfigs[0] < 1
            ) {
                fail("egl_choose_config_failed"); return
            }
            val config = configs[0] ?: run {
                fail("egl_null_config"); return
            }

            val contextAttribs = intArrayOf(
                EGL14.EGL_CONTEXT_CLIENT_VERSION, 2,
                EGL14.EGL_NONE,
            )
            eglContext = EGL14.eglCreateContext(eglDisplay, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
            if (eglContext == EGL14.EGL_NO_CONTEXT) {
                fail("egl_create_context_failed"); return
            }

            val pbufferAttribs = intArrayOf(
                EGL14.EGL_WIDTH, SURFACE_WIDTH,
                EGL14.EGL_HEIGHT, SURFACE_HEIGHT,
                EGL14.EGL_NONE,
            )
            eglSurface = EGL14.eglCreatePbufferSurface(eglDisplay, config, pbufferAttribs, 0)
            if (eglSurface == EGL14.EGL_NO_SURFACE) {
                fail("egl_create_pbuffer_surface_failed"); return
            }

            if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
                fail("egl_make_current_failed"); return
            }
            gates["eglSetupOk"] = true

            // Disable dithering during proof pass for deterministic pixel arithmetic
            ditherWasEnabled = GLES20.glIsEnabled(GLES20.GL_DITHER)
            GLES20.glDisable(GLES20.GL_DITHER)
            details["ditherDisabled"] = true

            // Framebuffer Object (FBO) setup: 257x257 GL_TEXTURE_2D color target with GL_RGBA/GL_UNSIGNED_BYTE
            val colorTex = IntArray(1)
            GLES20.glGenTextures(1, colorTex, 0)
            colorTextureId = colorTex[0]
            if (colorTextureId == 0) {
                fail("color_texture_creation_failed"); return
            }
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, colorTextureId)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA,
                SURFACE_WIDTH, SURFACE_HEIGHT, 0,
                GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null,
            )
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)

            val fbos = IntArray(1)
            GLES20.glGenFramebuffers(1, fbos, 0)
            fboId = fbos[0]
            if (fboId == 0) {
                fail("fbo_creation_failed"); return
            }
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fboId)
            GLES20.glFramebufferTexture2D(
                GLES20.GL_FRAMEBUFFER,
                GLES20.GL_COLOR_ATTACHMENT0,
                GLES20.GL_TEXTURE_2D,
                colorTextureId,
                0,
            )
            val fboStatus = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
            if (fboStatus != GLES20.GL_FRAMEBUFFER_COMPLETE) {
                fail("fbo_incomplete_$fboStatus"); return
            }
            gates["framebufferSetupOk"] = true
            details["framebufferSetupOk"] = true
            details["framebufferStatus"] = fboStatus

            // 2. Shader Compilation and Linking
            val vertexSrc = """
                attribute vec4 aPosition;
                attribute vec4 aTextureCoord;
                uniform mat4 uSTMatrix;
                varying vec2 vTextureCoord;
                varying vec2 vMaskCoord;
                void main() {
                    gl_Position = aPosition;
                    vTextureCoord = (uSTMatrix * aTextureCoord).xy;
                    vMaskCoord = aTextureCoord.xy;
                }
            """.trimIndent()

            val fragmentSrc = """
                precision mediump float;
                varying vec2 vTextureCoord;
                varying vec2 vMaskCoord;
                uniform sampler2D sCamera;
                uniform sampler2D uMask;
                void main() {
                    vec4 cameraColor = texture2D(sCamera, vTextureCoord);
                    float maskAlpha = texture2D(uMask, vMaskCoord).r;
                    gl_FragColor = vec4(cameraColor.rgb, cameraColor.a * maskAlpha);
                }
            """.trimIndent()

            program = buildProgram(vertexSrc, fragmentSrc)
            if (program == 0) {
                fail("shader_program_link_failed"); return
            }

            val aPositionLoc = GLES20.glGetAttribLocation(program, "aPosition")
            val aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTextureCoord")
            val uSTMatrixLoc = GLES20.glGetUniformLocation(program, "uSTMatrix")
            val sCameraLoc   = GLES20.glGetUniformLocation(program, "sCamera")
            val uMaskLoc     = GLES20.glGetUniformLocation(program, "uMask")

            if (aPositionLoc < 0 || aTexCoordLoc < 0 || uSTMatrixLoc < 0 || sCameraLoc < 0 || uMaskLoc < 0) {
                fail("shader_locations_unresolved"); return
            }
            gates["shaderProgramOk"] = true

            // 3. Textures
            cameraTextureId = createCameraTexture()
            if (cameraTextureId == 0) {
                fail("camera_texture_creation_failed"); return
            }
            maskTextureId = createMaskTexture()
            if (maskTextureId == 0) {
                fail("mask_texture_creation_failed"); return
            }

            // Test grid: 3x3 cells (each 21x21 texels in 63x63 mask)
            // c in 0..2, r in 0..2
            val uint8CellAlpha = arrayOf(
                intArrayOf(0, 255, 128),  // r = 0: bottom row
                intArrayOf(64, 192, 0),   // r = 1: middle row
                intArrayOf(255, 128, 255),// r = 2: top row (rows 42..62, tests non-multiple-of-4 row alignment)
            )

            val floatCellValues = arrayOf(
                floatArrayOf(-0.5f, 1.5f, 0.5f),  // r = 0: tests clamping to 0.0 and 1.0
                floatArrayOf(0.25f, 0.75f, 0.0f), // r = 1
                floatArrayOf(1.0f, 0.5f, 1.0f),   // r = 2: top row
            )

            var boundaryKeyingAllOk = true
            var blendMathAllOk = true
            var viewportScissorAllOk = true

            fun runCompositePass(
                passName: String,
                maskBuffer: ByteBuffer,
                expectedCellAlpha: (c: Int, r: Int) -> Int,
            ): Pair<Boolean, List<String>> {
                val sampleLogs = mutableListOf<String>()
                var passOk = true

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
                    fail("unpack_alignment_not_restored")
                    passOk = false
                }

                if (GLES20.glGetError() != GLES20.GL_NO_ERROR) {
                    fail("mask_upload_gl_error")
                    return false to sampleLogs
                }

                // Ensure FBO is bound for all clear, scissor, draw, glFinish, and read operations
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fboId)

                // 1. Full surface clear to sentinel color
                GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
                GLES20.glViewport(0, 0, SURFACE_WIDTH, SURFACE_HEIGHT)
                GLES20.glClearColor(
                    SENTINEL_R / 255f,
                    SENTINEL_G / 255f,
                    SENTINEL_B / 255f,
                    SENTINEL_A / 255f,
                )
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

                // 2. Scissored clear of draw rect to background color
                GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
                GLES20.glScissor(DRAW_RECT_X, DRAW_RECT_Y, DRAW_RECT_W, DRAW_RECT_H)
                GLES20.glViewport(DRAW_RECT_X, DRAW_RECT_Y, DRAW_RECT_W, DRAW_RECT_H)
                GLES20.glClearColor(
                    BACKGROUND_R / 255f,
                    BACKGROUND_G / 255f,
                    BACKGROUND_B / 255f,
                    BACKGROUND_A / 255f,
                )
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

                // 3. Draw camera green-screen with blending
                GLES20.glEnable(GLES20.GL_BLEND)
                GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)

                GLES20.glUseProgram(program)

                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, cameraTextureId)
                GLES20.glUniform1i(sCameraLoc, 0)
                GLES20.glUniformMatrix4fv(uSTMatrixLoc, 1, false, IDENTITY_MATRIX, 0)

                GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTextureId)
                GLES20.glUniform1i(uMaskLoc, 1)

                quadPositionBuffer.position(0)
                GLES20.glEnableVertexAttribArray(aPositionLoc)
                GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadPositionBuffer)

                quadTexCoordBuffer.position(0)
                GLES20.glEnableVertexAttribArray(aTexCoordLoc)
                GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoordBuffer)

                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

                GLES20.glDisableVertexAttribArray(aPositionLoc)
                GLES20.glDisableVertexAttribArray(aTexCoordLoc)

                GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)

                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)

                GLES20.glDisable(GLES20.GL_BLEND)
                GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
                GLES20.glFinish()

                if (GLES20.glGetError() != GLES20.GL_NO_ERROR) {
                    fail("draw_gl_error")
                    return false to sampleLogs
                }

                // 4. Sample and assert exterior pixels
                for ((exX, exY) in EXTERIOR_PROBE_POINTS) {
                    val actual = readPixel(exX, exY)
                    val expected = intArrayOf(SENTINEL_R, SENTINEL_G, SENTINEL_B, SENTINEL_A)
                    val dR = abs(actual[0] - expected[0])
                    val dG = abs(actual[1] - expected[1])
                    val dB = abs(actual[2] - expected[2])
                    val dA = abs(actual[3] - expected[3])
                    val maxD = max(max(dR, dG), max(dB, dA))
                    maxDeltaOverall = max(maxDeltaOverall, maxD)
                    sampleCountOverall++

                    if (maxD > TOLERANCE) {
                        viewportScissorAllOk = false
                        passOk = false
                        if (mismatches.size < 12) {
                            mismatches.add(
                                "pass=$passName type=exterior cell=none loc=($exX,$exY) mask=sentinel actual=${actual.contentToString()} exp=${expected.contentToString()} maxD=$maxD"
                            )
                        }
                    }
                    sampleLogs.add("EXTERIOR loc=($exX,$exY) actual=${actual.contentToString()} exp=${expected.contentToString()} maxD=$maxD")
                }

                // 5. Sample and assert interior cell centers
                // Draw rect has width 189 = 63 * 3, height 189 = 63 * 3
                // For cell (c, r), center is mx = c * 21 + 10, my = r * 21 + 10
                // Window coords: fbX = DRAW_RECT_X + c * 63 + 31, fbY = DRAW_RECT_Y + r * 63 + 31
                for (r in 0..2) {
                    for (c in 0..2) {
                        val fbX = DRAW_RECT_X + c * 63 + 31
                        val fbY = DRAW_RECT_Y + r * 63 + 31
                        val maskAlphaVal = expectedCellAlpha(c, r)
                        val expected = computeExpectedColor(
                            cameraR = CAMERA_R, cameraG = CAMERA_G, cameraB = CAMERA_B,
                            bgR = BACKGROUND_R, bgG = BACKGROUND_G, bgB = BACKGROUND_B,
                            maskByte = maskAlphaVal,
                        )
                        val actual = readPixel(fbX, fbY)
                        val dR = abs(actual[0] - expected[0])
                        val dG = abs(actual[1] - expected[1])
                        val dB = abs(actual[2] - expected[2])
                        val dA = abs(actual[3] - expected[3])
                        val maxD = max(max(dR, dG), max(dB, dA))
                        maxDeltaOverall = max(maxDeltaOverall, maxD)
                        sampleCountOverall++

                        val isMismatch = maxD > TOLERANCE
                        if (maskAlphaVal == 0 || maskAlphaVal == 255) {
                            if (isMismatch) {
                                boundaryKeyingAllOk = false
                                passOk = false
                            }
                        } else {
                            if (isMismatch) {
                                blendMathAllOk = false
                                passOk = false
                            }
                        }

                        if (isMismatch && mismatches.size < 12) {
                            mismatches.add(
                                "pass=$passName type=interior cell=($c,$r) loc=($fbX,$fbY) mask=$maskAlphaVal actual=${actual.contentToString()} exp=${expected.contentToString()} maxD=$maxD"
                            )
                        }

                        sampleLogs.add("INTERIOR pass=$passName cell=($c,$r) mask=$maskAlphaVal loc=($fbX,$fbY) actual=${actual.contentToString()} exp=${expected.contentToString()} maxD=$maxD")
                    }
                }

                return passOk to sampleLogs
            }

            // Pass 1: UINT8_ALPHA direct upload
            val uint8Buffer = ByteBuffer.allocateDirect(MASK_WIDTH * MASK_HEIGHT)
                .order(ByteOrder.nativeOrder())
            for (y in 0 until MASK_HEIGHT) {
                val r = y / 21
                for (x in 0 until MASK_WIDTH) {
                    val c = x / 21
                    val alphaVal = uint8CellAlpha[r][c]
                    uint8Buffer.put(alphaVal.toByte())
                }
            }
            uint8Buffer.rewind()

            val (uint8Pass, uint8Logs) = runCompositePass("UINT8_ALPHA", uint8Buffer) { c, r ->
                uint8CellAlpha[r][c]
            }
            gates["uint8MaskUploadOk"] = uint8Pass
            details["uint8Samples"] = uint8Logs
            if (!uint8Pass) {
                fail("uint8_mask_upload_samples_failed")
            }

            // Pass 2: FLOAT32_CONFIDENCE conversion and upload
            // Stride-4 float -> 0..255 byte conversion matching AndroidDuetPreviewCompositor.kt semantics
            val floatBuffer = ByteBuffer.allocateDirect(MASK_WIDTH * MASK_HEIGHT * 4)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()
            for (y in 0 until MASK_HEIGHT) {
                val r = y / 21
                for (x in 0 until MASK_WIDTH) {
                    val c = x / 21
                    floatBuffer.put(floatCellValues[r][c])
                }
            }
            floatBuffer.rewind()

            // Pack floats into bytes: coerceIn(0f, 1f) * 255f
            val packedFloatToByteBuffer = ByteBuffer.allocateDirect(MASK_WIDTH * MASK_HEIGHT)
                .order(ByteOrder.nativeOrder())
            floatBuffer.rewind()
            for (i in 0 until MASK_WIDTH * MASK_HEIGHT) {
                val f = floatBuffer.get(i)
                val packedByte = (f.coerceIn(0f, 1f) * 255f).toInt().toByte()
                packedFloatToByteBuffer.put(packedByte)
            }
            packedFloatToByteBuffer.rewind()

            val (floatPass, floatLogs) = runCompositePass("FLOAT32_CONFIDENCE", packedFloatToByteBuffer) { c, r ->
                val f = floatCellValues[r][c]
                (f.coerceIn(0f, 1f) * 255f).toInt()
            }
            gates["floatMaskUploadOk"] = floatPass
            details["floatSamples"] = floatLogs
            if (!floatPass) {
                fail("float_mask_upload_samples_failed")
            }

            if (gates["uint8MaskUploadOk"] == true && gates["floatMaskUploadOk"] == true) {
                Log.i(TAG, MASK_UPLOAD_PASS_MARKER)
                println(MASK_UPLOAD_PASS_MARKER)
            }

            gates["boundaryKeyingOk"] = boundaryKeyingAllOk
            gates["blendMathOk"] = blendMathAllOk
            gates["viewportScissorOk"] = viewportScissorAllOk

            if (boundaryKeyingAllOk && blendMathAllOk && viewportScissorAllOk) {
                Log.i(TAG, BLEND_PASS_MARKER)
                println(BLEND_PASS_MARKER)
            } else {
                if (!boundaryKeyingAllOk) fail("boundary_keying_failed")
                if (!blendMathAllOk) fail("blend_math_failed")
                if (!viewportScissorAllOk) fail("viewport_scissor_failed")
            }

            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        }

        try {
            executeHarness()
        } catch (t: Throwable) {
            Log.e(TAG, "executeHarness uncaught exception", t)
            fail("harness_exception:${t.javaClass.simpleName}:${t.message}")
        } finally {
            var cleanupClean = true
            try { if (ditherWasEnabled) GLES20.glEnable(GLES20.GL_DITHER) } catch (_: Throwable) {}
            try { GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0) } catch (_: Throwable) {}
            try {
                if (fboId != 0) GLES20.glDeleteFramebuffers(1, intArrayOf(fboId), 0)
            } catch (_: Throwable) { cleanupClean = false }
            try {
                if (colorTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(colorTextureId), 0)
            } catch (_: Throwable) { cleanupClean = false }
            try {
                if (cameraTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(cameraTextureId), 0)
            } catch (_: Throwable) { cleanupClean = false }
            try {
                if (maskTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(maskTextureId), 0)
            } catch (_: Throwable) { cleanupClean = false }
            try {
                if (program != 0) GLES20.glDeleteProgram(program)
            } catch (_: Throwable) { cleanupClean = false }
            if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                try {
                    EGL14.eglMakeCurrent(
                        eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT
                    )
                } catch (_: Throwable) { cleanupClean = false }
                try {
                    if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
                } catch (_: Throwable) { cleanupClean = false }
                try {
                    if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
                } catch (_: Throwable) { cleanupClean = false }
                try {
                    EGL14.eglTerminate(eglDisplay)
                } catch (_: Throwable) { cleanupClean = false }
            }
            gates["cleanupOk"] = cleanupClean
            if (!cleanupClean) {
                fail("cleanup_failed")
            }
        }

        val allGatesPass = gates.values.all { it }
        val overallPass = allGatesPass && (maxDeltaOverall <= TOLERANCE) && failureReason.isEmpty()
        val marker = if (overallPass) PASS_MARKER else FAIL_MARKER

        if (overallPass) {
            Log.i(TAG, PASS_MARKER)
            println(PASS_MARKER)
        } else {
            val failLog = "$FAIL_MARKER failureReason=$failureReason maxDelta=$maxDeltaOverall gates=$gates mismatchCount=${mismatches.size}"
            Log.e(TAG, failLog)
            println(failLog)
            for (mismatch in mismatches) {
                val mismatchLog = "DUET_GLES_MISMATCH $mismatch"
                Log.e(TAG, mismatchLog)
                println(mismatchLog)
            }
        }

        details["surfaceSize"] = mapOf("width" to SURFACE_WIDTH, "height" to SURFACE_HEIGHT)
        details["maskSize"] = mapOf("width" to MASK_WIDTH, "height" to MASK_HEIGHT)
        details["drawRect"] = mapOf(
            "x" to DRAW_RECT_X,
            "y" to DRAW_RECT_Y,
            "width" to DRAW_RECT_W,
            "height" to DRAW_RECT_H,
        )
        details["framebuffer"] = mapOf(
            "width" to SURFACE_WIDTH,
            "height" to SURFACE_HEIGHT,
            "format" to "GL_RGBA",
            "type" to "GL_UNSIGNED_BYTE",
            "complete" to (gates["framebufferSetupOk"] == true),
        )
        details["ditherDisabled"] = true
        details["mismatches"] = mismatches

        val result = linkedMapOf<String, Any?>()
        result["pass"] = overallPass
        result["marker"] = marker
        result["proofBoundary"] = PROOF_BOUNDARY
        result["gates"] = gates
        result["tolerance"] = TOLERANCE
        result["maxDelta"] = maxDeltaOverall
        result["sampleCount"] = sampleCountOverall
        result["mismatches"] = mismatches
        result["details"] = details
        result["failureReason"] = failureReason
        result["nonClaims"] = NON_CLAIMS
        return result
    }

    private fun computeExpectedColor(
        cameraR: Int, cameraG: Int, cameraB: Int,
        bgR: Int, bgG: Int, bgB: Int,
        maskByte: Int,
    ): IntArray {
        val m = maskByte.coerceIn(0, 255)
        val r = ((cameraR * m + bgR * (255 - m)) / 255.0).roundToInt()
        val g = ((cameraG * m + bgG * (255 - m)) / 255.0).roundToInt()
        val b = ((cameraB * m + bgB * (255 - m)) / 255.0).roundToInt()
        // GLES blending (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA):
        // Src: cameraColor.rgb, cameraA * (m / 255f) -> As = m / 255f
        // Dst: bg.rgb, bgA = 1.0 (255)
        // Blended alpha: As * As + Ad * (1 - As) = (m * m + 255 * (255 - m)) / 255f
        val a = ((m * m + 255 * (255 - m)) / 255.0).roundToInt().coerceIn(0, 255)
        return intArrayOf(r, g, b, a)
    }

    private fun readPixel(x: Int, y: Int): IntArray {
        val buffer = ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder())
        GLES20.glReadPixels(x, y, 1, 1, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buffer)
        buffer.position(0)
        val r = buffer.get().toInt() and 0xFF
        val g = buffer.get().toInt() and 0xFF
        val b = buffer.get().toInt() and 0xFF
        val a = buffer.get().toInt() and 0xFF
        return intArrayOf(r, g, b, a)
    }

    private fun createCameraTexture(): Int {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        val id = textures[0]
        if (id == 0) return 0
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, id)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        val width = 4
        val height = 4
        val buf = ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.nativeOrder())
        for (i in 0 until width * height) {
            buf.put(CAMERA_R.toByte())
            buf.put(CAMERA_G.toByte())
            buf.put(CAMERA_B.toByte())
            buf.put(CAMERA_A.toByte())
        }
        buf.rewind()
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA,
            width, height, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf,
        )
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        return id
    }

    private fun createMaskTexture(): Int {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        val id = textures[0]
        if (id == 0) return 0
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, id)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        return id
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
}
