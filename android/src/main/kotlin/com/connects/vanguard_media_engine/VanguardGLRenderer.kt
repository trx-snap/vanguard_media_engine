package com.connects.vanguard_media_engine

import android.content.Context
import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.opengl.*
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * VanguardGLRenderer — Phase 3 Android GPU Render Pass
 *
 * Pipeline:
 *   MediaExtractor → MediaCodec (HW decoder) → SurfaceTexture (OES)
 *   → OpenGL ES 3 compositor shader → Flutter Texture
 *
 * The SurfaceTexture acts as the bridge between MediaCodec's output and
 * the OpenGL OES sampler in our fragment shader, eliminating any CPU memcpy.
 */
class VanguardGLRenderer(
    private val context: Context,
    private val videoPath: String,
    private val textureRegistry: TextureRegistry,
    private val methodChannel: MethodChannel
) {

    // Flutter texture entry — exposes the textureId to the Dart VanguardTextureView
    private val textureEntry: TextureRegistry.SurfaceTextureEntry = textureRegistry.createSurfaceTexture()
    val textureId: Long get() = textureEntry.id()

    // OpenGL
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var glProgram: Int = 0

    // OES texture for MediaCodec → OpenGL
    private var oesTextureId: Int = 0
    private lateinit var decoderSurface: SurfaceTexture
    private lateinit var decoderSurfaceReal: Surface

    // MediaCodec
    private lateinit var extractor: MediaExtractor
    private lateinit var codec: MediaCodec
    private var videoDuration: Long = 0L // microseconds

    // Decode thread
    private val decodeThread = HandlerThread("VanguardDecode").also { it.start() }
    private val decodeHandler = Handler(decodeThread.looper)

    init {
        decodeHandler.post {
            setupEGL()
            setupShaders()
            setupDecoder()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // EGL Setup
    // ─────────────────────────────────────────────────────────────────────────

    private fun setupEGL() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        EGL14.eglInitialize(eglDisplay, null, 0, null, 0)

        val attribs = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, 1, numConfigs, 0)

        val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, contextAttribs, 0)

        // Off-screen pbuffer surface for rendering into the Flutter SurfaceTexture
        val surfaceAttribs = intArrayOf(EGL14.EGL_WIDTH, 1080, EGL14.EGL_HEIGHT, 1920, EGL14.EGL_NONE)
        eglSurface = EGL14.eglCreatePbufferSurface(eglDisplay, configs[0], surfaceAttribs, 0)
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

        // Create OES texture that MediaCodec will render into
        val textures = IntArray(1)
        GLES30.glGenTextures(1, textures, 0)
        oesTextureId = textures[0]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)

        // Bridge OES texture → SurfaceTexture → Surface → MediaCodec output
        decoderSurface = SurfaceTexture(oesTextureId)
        decoderSurfaceReal = Surface(decoderSurface)

        // Notify Flutter when a new frame is available
        decoderSurface.setOnFrameAvailableListener {
            renderFrame()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GLSL Shader Compilation
    // ─────────────────────────────────────────────────────────────────────────

    private fun setupShaders() {
        val vertSrc = context.resources.openRawResource(R.raw.vanguard_compositor_vert)
            .bufferedReader().readText()
        val fragSrc = context.resources.openRawResource(R.raw.vanguard_compositor_frag)
            .bufferedReader().readText()

        val vertShader = compileShader(GLES30.GL_VERTEX_SHADER, vertSrc)
        val fragShader = compileShader(GLES30.GL_FRAGMENT_SHADER, fragSrc)

        glProgram = GLES30.glCreateProgram()
        GLES30.glAttachShader(glProgram, vertShader)
        GLES30.glAttachShader(glProgram, fragShader)
        GLES30.glLinkProgram(glProgram)
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, src)
        GLES30.glCompileShader(shader)
        val status = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            android.util.Log.e("Vanguard", "Shader compile error: ${GLES30.glGetShaderInfoLog(shader)}")
        }
        return shader
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MediaCodec + MediaExtractor Setup
    // ─────────────────────────────────────────────────────────────────────────

    private fun setupDecoder() {
        extractor = MediaExtractor()
        extractor.setDataSource(videoPath)

        var videoTrackIndex = -1
        for (i in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(i)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("video/")) {
                videoTrackIndex = i
                videoDuration = format.getLong(MediaFormat.KEY_DURATION)
                break
            }
        }

        if (videoTrackIndex < 0) {
            android.util.Log.e("Vanguard", "No video track in: $videoPath")
            return
        }

        extractor.selectTrack(videoTrackIndex)
        val format = extractor.getTrackFormat(videoTrackIndex)
        val mime   = format.getString(MediaFormat.KEY_MIME)!!

        // Hardware decoder — output goes directly into our SurfaceTexture (zero-copy)
        codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, decoderSurfaceReal, null, 0)
        codec.start()

        // Notify Dart of the probed duration in seconds
        val durationSeconds = videoDuration / 1_000_000.0
        methodChannel.invokeMethod("onNodeDurationProbed",
            mapOf("path" to videoPath, "duration" to durationSeconds))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GPU Render Pass
    // ─────────────────────────────────────────────────────────────────────────

    private fun renderFrame() {
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

        // Update OES texture with the latest frame from SurfaceTexture
        decoderSurface.updateTexImage()

        GLES30.glUseProgram(glProgram)
        GLES30.glViewport(0, 0, 1080, 1920)
        GLES30.glClearColor(0f, 0f, 0f, 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)

        // Bind OES texture to uBackground slot
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(glProgram, "uBackground"), 0)

        // Default effects (neutral — no change)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(glProgram, "uContrast"),    1.0f)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(glProgram, "uBrightness"),  0.0f)
        GLES30.glUniform1f(GLES30.glGetUniformLocation(glProgram, "uSaturation"),  1.0f)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(glProgram, "uHasForeground"), 0)

        // Draw full-screen quad
        val quadVerts = floatArrayOf(
            0f, 0f,  0f, 0f,
            1f, 0f,  1f, 0f,
            0f, 1f,  0f, 1f,
            1f, 1f,  1f, 1f
        )
        val vertBuf = ByteBuffer.allocateDirect(quadVerts.size * 4)
            .order(ByteOrder.nativeOrder()).asFloatBuffer()
        vertBuf.put(quadVerts).position(0)

        GLES30.glEnableVertexAttribArray(0)
        GLES30.glVertexAttribPointer(0, 2, GLES30.GL_FLOAT, false, 16, vertBuf)
        val uvBuf = vertBuf.duplicate().also { it.position(2) }
        GLES30.glEnableVertexAttribArray(1)
        GLES30.glVertexAttribPointer(1, 2, GLES30.GL_FLOAT, false, 16, uvBuf)

        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)

        // Signal Flutter Texture to redraw
        textureEntry.surfaceTexture().updateTexImage()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Playback Controls
    // ─────────────────────────────────────────────────────────────────────────

    fun play() {
        decodeHandler.post { drainDecoder() }
    }

    fun pause() {
        decodeHandler.removeCallbacksAndMessages(null)
    }

    private fun drainDecoder() {
        val info = MediaCodec.BufferInfo()
        var inputDone = false

        while (true) {
            if (!inputDone) {
                val inIdx = codec.dequeueInputBuffer(10_000L)
                if (inIdx >= 0) {
                    val buf = codec.getInputBuffer(inIdx)!!
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

            val outIdx = codec.dequeueOutputBuffer(info, 10_000L)
            if (outIdx >= 0) {
                // true = render to Surface → triggers SurfaceTexture.onFrameAvailable
                codec.releaseOutputBuffer(outIdx, true)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                    methodChannel.invokeMethod("onPlaybackComplete", mapOf("textureId" to textureId))
                    break
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Dispose
    // ─────────────────────────────────────────────────────────────────────────

    fun dispose() {
        pause()
        codec.stop()
        codec.release()
        extractor.release()
        decoderSurfaceReal.release()
        decoderSurface.release()
        EGL14.eglDestroySurface(eglDisplay, eglSurface)
        EGL14.eglDestroyContext(eglDisplay, eglContext)
        EGL14.eglTerminate(eglDisplay)
        textureEntry.release()
        decodeThread.quitSafely()
    }
}
