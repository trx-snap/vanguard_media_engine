package com.connects.vanguard_media_engine.camera

// ── AndroidCameraBeautySurfaceProcessor ──────────────────────────────────────
//
// LIVE-CAMERA-BEAUTY-PARITY: CameraX SurfaceProcessor that intercepts live
// camera frames with a hardware-accelerated OpenGL ES 3.0 filter pipeline.
//
// Pipeline per frame:
//   1. CameraX delivers OES texture via SurfaceTexture on the GPU thread.
//   2. OES is blitted to an intermediate GL_TEXTURE_2D (applying the CameraX
//      transform matrix for orientation/mirroring).
//   3. If intensity > 0: VanguardNativeBridge.drawLiveCameraBeauty() applies
//      the 3-pass bilateral beauty filter (GlesBeautyV2Compositor) to the
//      intermediate texture, rendering into the output surface FBO.
//      If intensity == 0: direct 1:1 passthrough blit from intermediate
//      to output (zero GPU overhead, battery preservation).
//   4. EGL buffer swap to the CameraX output surface(s).
//
// Threading: all GL work runs on a dedicated HandlerThread ("VGCameraGpuThread").
// setIntensity() is thread-safe via @Volatile.
//
// Lifecycle: created by VanguardCameraSource on start(), released on stop().
// CameraX owns the SurfaceProcessor lifecycle callbacks (onInputSurface /
// onOutputSurface).

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import androidx.camera.core.SurfaceOutput
import androidx.camera.core.SurfaceProcessor
import androidx.camera.core.SurfaceRequest
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean

class AndroidCameraBeautySurfaceProcessor(
    private val nativeBridge: VanguardNativeBridge,
) : SurfaceProcessor {

    companion object {
        private const val TAG = "VGCameraBeautyProc"

        // OES→2D blit vertex shader (applies SurfaceTexture transform matrix).
        private const val OES_VERTEX_SHADER =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "layout(location = 0) in vec4 aPosition;\n" +
            "layout(location = 1) in vec4 aTexCoord;\n" +
            "uniform mat4 uTexMatrix;\n" +
            "out vec2 vTexCoord;\n" +
            "void main() {\n" +
            "    gl_Position = aPosition;\n" +
            "    vTexCoord = (uTexMatrix * aTexCoord).xy;\n" +
            "}\n"

        private const val OES_FRAGMENT_SHADER =
            "#version 300 es\n" +
            "#extension GL_OES_EGL_image_external_essl3 : require\n" +
            "precision highp float;\n" +
            "uniform samplerExternalOES uOesTex;\n" +
            "in vec2 vTexCoord;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "    fragColor = texture(uOesTex, vTexCoord);\n" +
            "}\n"

        // Simple 2D→2D passthrough blit (for intensity == 0).
        private const val PASSTHROUGH_VERTEX_SHADER =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "layout(location = 0) in vec4 aPosition;\n" +
            "layout(location = 1) in vec4 aTexCoord;\n" +
            "out vec2 vTexCoord;\n" +
            "void main() {\n" +
            "    gl_Position = aPosition;\n" +
            "    vTexCoord = aTexCoord.xy;\n" +
            "}\n"

        private const val PASSTHROUGH_FRAGMENT_SHADER =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "uniform sampler2D uTex;\n" +
            "in vec2 vTexCoord;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "    fragColor = texture(uTex, vTexCoord);\n" +
            "}\n"

        // Full-screen quad (triangle strip) with texcoords.
        private val FULLSCREEN_QUAD = floatArrayOf(
            // x, y, u, v
            -1f, -1f, 0f, 0f,
             1f, -1f, 1f, 0f,
            -1f,  1f, 0f, 1f,
             1f,  1f, 1f, 1f,
        )
    }

    // ── Thread-safe intensity control ────────────────────────────────────────
    @Volatile var intensity: Float = 0f

    // ── GPU thread ───────────────────────────────────────────────────────────
    private val gpuThread = HandlerThread("VGCameraGpuThread").also { it.start() }
    private val gpuHandler = Handler(gpuThread.looper)
    private val released = AtomicBoolean(false)

    // ── EGL state (GPU thread only) ──────────────────────────────────────────
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglConfig: EGLConfig? = null
    private var pbufferSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    // ── GL resources (GPU thread only) ───────────────────────────────────────
    private var oesTexture: Int = 0
    private var surfaceTexture: SurfaceTexture? = null
    private var inputSurface: Surface? = null

    private var intermediateTexture: Int = 0
    private var intermediateFbo: Int = 0

    private var oesProgram: Int = 0
    private var passthroughProgram: Int = 0
    private var quadVao: Int = 0
    private var quadVbo: Int = 0

    private var frameWidth: Int = 0
    private var frameHeight: Int = 0

    // ── Output surface state (GPU thread only) ───────────────────────────────
    private var outputSurface: Surface? = null
    private var outputEglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var outputSurfaceOutput: SurfaceOutput? = null

    // Transform matrices: raw from SurfaceTexture, final after CameraX output transform.
    // Kept distinct because Matrix.multiplyMM inside updateTransformMatrix forbids buffer overlap.
    private val rawTexMatrix = FloatArray(16)
    private val finalTexMatrix = FloatArray(16)

    // ── SurfaceProcessor callbacks ───────────────────────────────────────────

    override fun onInputSurface(request: SurfaceRequest) {
        if (released.get()) return

        gpuHandler.post {
            try {
                val size = request.resolution
                frameWidth = size.width
                frameHeight = size.height
                Log.d(TAG, "onInputSurface: ${frameWidth}×${frameHeight}")

                // Initialize EGL + GL resources on first input.
                if (eglDisplay == EGL14.EGL_NO_DISPLAY) {
                    initEgl()
                    initGlResources()
                }

                // Recreate intermediate FBO for new resolution.
                recreateIntermediateFbo(frameWidth, frameHeight)

                // Create OES texture + SurfaceTexture for camera input.
                if (oesTexture == 0) {
                    oesTexture = createOesTexture()
                }
                surfaceTexture?.release()
                surfaceTexture = SurfaceTexture(oesTexture).apply {
                    setDefaultBufferSize(frameWidth, frameHeight)
                    setOnFrameAvailableListener({ onFrameAvailable() }, gpuHandler)
                }

                inputSurface?.release()
                inputSurface = Surface(surfaceTexture)

                // Provide the surface to CameraX.
                request.provideSurface(inputSurface!!, { cmd -> gpuHandler.post(cmd) }) { result ->
                    Log.d(TAG, "Input surface released by CameraX (code=${result.resultCode})")
                }
            } catch (e: Exception) {
                Log.e(TAG, "onInputSurface failed: ${e.message}", e)
            }
        }
    }

    override fun onOutputSurface(output: SurfaceOutput) {
        if (released.get()) return

        gpuHandler.post {
            try {
                // Release previous output surface.
                releaseOutputSurface()

                outputSurfaceOutput = output
                outputSurface = output.getSurface({ cmd -> gpuHandler.post(cmd) }) {
                    Log.d(TAG, "Output surface event received")
                }

                // Create EGL window surface for the output.
                if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglConfig != null) {
                    outputEglSurface = EGL14.eglCreateWindowSurface(
                        eglDisplay, eglConfig, outputSurface, intArrayOf(EGL14.EGL_NONE), 0
                    )
                    if (outputEglSurface == EGL14.EGL_NO_SURFACE) {
                        Log.e(TAG, "Failed to create output EGL surface")
                    }
                }

                Log.d(TAG, "onOutputSurface: output surface bound")
            } catch (e: Exception) {
                Log.e(TAG, "onOutputSurface failed: ${e.message}", e)
            }
        }
    }

    // ── Per-frame processing ─────────────────────────────────────────────────

    private fun onFrameAvailable() {
        if (released.get()) return
        if (outputEglSurface == EGL14.EGL_NO_SURFACE) return

        try {
            // Make our context current on the output surface.
            EGL14.eglMakeCurrent(eglDisplay, outputEglSurface, outputEglSurface, eglContext)

            // Update OES texture with the latest camera frame.
            surfaceTexture?.updateTexImage()
            surfaceTexture?.getTransformMatrix(rawTexMatrix)

            // Update output transform matrix from CameraX using non-overlapping buffers.
            val outputOut = outputSurfaceOutput
            if (outputOut != null) {
                outputOut.updateTransformMatrix(finalTexMatrix, rawTexMatrix)
            } else {
                System.arraycopy(rawTexMatrix, 0, finalTexMatrix, 0, 16)
            }

            // Step 1: Blit OES → intermediate GL_TEXTURE_2D (applying transform).
            blitOesToIntermediate()

            // Step 2: Apply beauty filter or passthrough blit.
            val currentIntensity = intensity
            if (currentIntensity > 0f) {
                // Bind the output surface FBO (FBO 0 = default for EGL window surface).
                GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
                GLES30.glViewport(0, 0, frameWidth, frameHeight)

                val ok = nativeBridge.drawLiveCameraBeauty(
                    intermediateTexture, 0, frameWidth, frameHeight, currentIntensity
                )
                if (!ok) {
                    // Fallback: direct passthrough if beauty fails.
                    blitIntermediateToOutput()
                }
            } else {
                // Zero intensity: direct passthrough (no GPU filter overhead).
                blitIntermediateToOutput()
            }

            // Swap buffers to present the frame.
            EGL14.eglSwapBuffers(eglDisplay, outputEglSurface)
        } catch (e: Exception) {
            Log.e(TAG, "Frame processing failed: ${e.message}", e)
        }
    }

    // ── OES → Intermediate 2D blit ──────────────────────────────────────────

    private fun blitOesToIntermediate() {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, intermediateFbo)
        GLES30.glViewport(0, 0, frameWidth, frameHeight)

        GLES30.glUseProgram(oesProgram)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexture)

        val texMatrixLoc = GLES30.glGetUniformLocation(oesProgram, "uTexMatrix")
        GLES30.glUniformMatrix4fv(texMatrixLoc, 1, false, finalTexMatrix, 0)

        val texLoc = GLES30.glGetUniformLocation(oesProgram, "uOesTex")
        GLES30.glUniform1i(texLoc, 0)

        GLES30.glBindVertexArray(quadVao)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        GLES30.glBindVertexArray(0)

        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
    }

    // ── Intermediate 2D → Output passthrough blit ────────────────────────────

    private fun blitIntermediateToOutput() {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        GLES30.glViewport(0, 0, frameWidth, frameHeight)

        GLES30.glUseProgram(passthroughProgram)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, intermediateTexture)

        val texLoc = GLES30.glGetUniformLocation(passthroughProgram, "uTex")
        GLES30.glUniform1i(texLoc, 0)

        GLES30.glBindVertexArray(quadVao)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        GLES30.glBindVertexArray(0)

        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
    }

    // ── EGL initialization ───────────────────────────────────────────────────

    private fun initEgl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) throw RuntimeException("eglGetDisplay failed")

        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            throw RuntimeException("eglInitialize failed")
        }

        val configAttribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0)
        if (numConfigs[0] == 0) throw RuntimeException("eglChooseConfig found no ES3 config")
        eglConfig = configs[0]!!

        val contextAttribs = intArrayOf(
            EGL14.EGL_CONTEXT_CLIENT_VERSION, 3,
            EGL14.EGL_NONE,
        )
        eglContext = EGL14.eglCreateContext(eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) throw RuntimeException("eglCreateContext failed")

        // Create a small pbuffer surface for context activation during initial setup.
        val pbufferAttribs = intArrayOf(
            EGL14.EGL_WIDTH, 1,
            EGL14.EGL_HEIGHT, 1,
            EGL14.EGL_NONE,
        )
        pbufferSurface = EGL14.eglCreatePbufferSurface(eglDisplay, eglConfig, pbufferAttribs, 0)
        EGL14.eglMakeCurrent(eglDisplay, pbufferSurface, pbufferSurface, eglContext)

        Log.d(TAG, "EGL initialized (ES 3.0)")
    }

    // ── GL resource setup ────────────────────────────────────────────────────

    private fun initGlResources() {
        // Compile shaders.
        oesProgram = buildProgram(OES_VERTEX_SHADER, OES_FRAGMENT_SHADER)
        passthroughProgram = buildProgram(PASSTHROUGH_VERTEX_SHADER, PASSTHROUGH_FRAGMENT_SHADER)

        // Create VAO + VBO for fullscreen quad.
        val vaos = IntArray(1)
        GLES30.glGenVertexArrays(1, vaos, 0)
        quadVao = vaos[0]

        val vbos = IntArray(1)
        GLES30.glGenBuffers(1, vbos, 0)
        quadVbo = vbos[0]

        val quadBuffer = ByteBuffer.allocateDirect(FULLSCREEN_QUAD.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .put(FULLSCREEN_QUAD)
            .also { it.position(0) }

        GLES30.glBindVertexArray(quadVao)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, quadVbo)
        GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, FULLSCREEN_QUAD.size * 4, quadBuffer, GLES30.GL_STATIC_DRAW)
        GLES30.glEnableVertexAttribArray(0)
        GLES30.glVertexAttribPointer(0, 2, GLES30.GL_FLOAT, false, 16, 0)
        GLES30.glEnableVertexAttribArray(1)
        GLES30.glVertexAttribPointer(1, 2, GLES30.GL_FLOAT, false, 16, 8)
        GLES30.glBindVertexArray(0)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, 0)

        Log.d(TAG, "GL resources initialized")
    }

    private fun createOesTexture(): Int {
        val textures = IntArray(1)
        GLES30.glGenTextures(1, textures, 0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textures[0])
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        return textures[0]
    }

    private fun recreateIntermediateFbo(width: Int, height: Int) {
        // Delete previous.
        if (intermediateFbo != 0) {
            GLES30.glDeleteFramebuffers(1, intArrayOf(intermediateFbo), 0)
            intermediateFbo = 0
        }
        if (intermediateTexture != 0) {
            GLES30.glDeleteTextures(1, intArrayOf(intermediateTexture), 0)
            intermediateTexture = 0
        }

        // Create 2D texture for intermediate.
        val textures = IntArray(1)
        GLES30.glGenTextures(1, textures, 0)
        intermediateTexture = textures[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, intermediateTexture)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, width, height, 0,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)

        // Create FBO.
        val fbos = IntArray(1)
        GLES30.glGenFramebuffers(1, fbos, 0)
        intermediateFbo = fbos[0]
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, intermediateFbo)
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
            GLES30.GL_TEXTURE_2D, intermediateTexture, 0)

        val status = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER)
        if (status != GLES30.GL_FRAMEBUFFER_COMPLETE) {
            Log.e(TAG, "Intermediate FBO incomplete: $status")
        }
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

        Log.d(TAG, "Intermediate FBO created: ${width}×${height}")
    }

    // ── Shader compilation ───────────────────────────────────────────────────

    private fun buildProgram(vertexSrc: String, fragmentSrc: String): Int {
        val vs = compileShader(GLES30.GL_VERTEX_SHADER, vertexSrc)
        val fs = compileShader(GLES30.GL_FRAGMENT_SHADER, fragmentSrc)
        val program = GLES30.glCreateProgram()
        GLES30.glAttachShader(program, vs)
        GLES30.glAttachShader(program, fs)
        GLES30.glLinkProgram(program)

        val linkStatus = IntArray(1)
        GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] != GLES30.GL_TRUE) {
            val log = GLES30.glGetProgramInfoLog(program)
            GLES30.glDeleteProgram(program)
            throw RuntimeException("Program link failed: $log")
        }
        GLES30.glDeleteShader(vs)
        GLES30.glDeleteShader(fs)
        return program
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, source)
        GLES30.glCompileShader(shader)

        val compileStatus = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, compileStatus, 0)
        if (compileStatus[0] != GLES30.GL_TRUE) {
            val log = GLES30.glGetShaderInfoLog(shader)
            GLES30.glDeleteShader(shader)
            throw RuntimeException("Shader compile failed: $log")
        }
        return shader
    }

    // ── Cleanup ──────────────────────────────────────────────────────────────

    private fun releaseOutputSurface() {
        if (outputEglSurface != EGL14.EGL_NO_SURFACE && eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglDestroySurface(eglDisplay, outputEglSurface)
            outputEglSurface = EGL14.EGL_NO_SURFACE
        }
        outputSurfaceOutput?.close()
        outputSurfaceOutput = null
        outputSurface = null
    }

    fun release() {
        if (!released.compareAndSet(false, true)) return

        gpuHandler.post {
            try {
                releaseOutputSurface()

                // Release cached native GL resources (shader programs, FBOs,
                // textures, VAO/VBO) while the EGL context is still current.
                nativeBridge.releaseLiveCameraBeauty()

                surfaceTexture?.setOnFrameAvailableListener(null)
                surfaceTexture?.release()
                surfaceTexture = null
                inputSurface?.release()
                inputSurface = null

                if (oesTexture != 0) {
                    GLES30.glDeleteTextures(1, intArrayOf(oesTexture), 0)
                    oesTexture = 0
                }
                if (intermediateTexture != 0) {
                    GLES30.glDeleteTextures(1, intArrayOf(intermediateTexture), 0)
                    intermediateTexture = 0
                }
                if (intermediateFbo != 0) {
                    GLES30.glDeleteFramebuffers(1, intArrayOf(intermediateFbo), 0)
                    intermediateFbo = 0
                }
                if (oesProgram != 0) {
                    GLES30.glDeleteProgram(oesProgram)
                    oesProgram = 0
                }
                if (passthroughProgram != 0) {
                    GLES30.glDeleteProgram(passthroughProgram)
                    passthroughProgram = 0
                }
                if (quadVbo != 0) {
                    GLES30.glDeleteBuffers(1, intArrayOf(quadVbo), 0)
                    quadVbo = 0
                }
                if (quadVao != 0) {
                    GLES30.glDeleteVertexArrays(1, intArrayOf(quadVao), 0)
                    quadVao = 0
                }

                if (pbufferSurface != EGL14.EGL_NO_SURFACE && eglDisplay != EGL14.EGL_NO_DISPLAY) {
                    EGL14.eglDestroySurface(eglDisplay, pbufferSurface)
                    pbufferSurface = EGL14.EGL_NO_SURFACE
                }

                if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                    EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                    if (eglContext != EGL14.EGL_NO_CONTEXT) {
                        EGL14.eglDestroyContext(eglDisplay, eglContext)
                        eglContext = EGL14.EGL_NO_CONTEXT
                    }
                    EGL14.eglTerminate(eglDisplay)
                    eglDisplay = EGL14.EGL_NO_DISPLAY
                }

                Log.d(TAG, "Released all GPU resources")
            } catch (e: Exception) {
                Log.e(TAG, "Release failed: ${e.message}", e)
            }

            gpuThread.quitSafely()
        }
    }
}
