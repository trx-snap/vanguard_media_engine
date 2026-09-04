package com.connects.vanguard_media_engine.sidecar

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
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
import android.opengl.GLUtils
import android.util.Log
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.min
import kotlin.math.roundToLong

/**
 * P5-REVERSE-SIDECAR-TRANSCODE-FOUNDATION.
 *
 * Bounded video-only MP4 sidecar transcoder for a single reversed clip
 * window. Walks the requested [Params.frameCount] output frames backward
 * across [Params.trimStartSeconds, Params.trimEndSeconds), decoding one live
 * [Bitmap] at a time via [MediaMetadataRetriever.getFrameAtTime] (never
 * buffering the whole clip), uploading it to a GLES2 2D texture via
 * [GLUtils.texImage2D], drawing an aspect-fit quad onto a black canvas sized
 * [Params.targetWidth]x[Params.targetHeight], and submitting it to a
 * MediaCodec encoder through an EGL14 window surface bound to the encoder's
 * own input Surface (no [android.view.Surface.lockCanvas]). Encoder output is
 * drained into a [MediaMuxer] writing [Params.outputPath] directly (the
 * caller is responsible for the temp-then-rename dance).
 *
 * Bounds enforcement (max duration/frame count/dimensions) is the caller's
 * responsibility -- this class trusts [Params] and only fails closed on
 * genuine decode/encode errors.
 *
 * [Params.isCancelled] is polled cooperatively (before expensive setup,
 * every frame-loop iteration, and inside the encoder drain loop) so a
 * generation-aware caller can bound how long an in-flight transcode keeps
 * running after it becomes stale, without any thread interruption.
 */
class AndroidReverseSidecarTranscoder {

    data class Params(
        val sourcePath: String,
        val outputPath: String,
        val trimStartSeconds: Double,
        val trimEndSeconds: Double,
        val frameCount: Int,
        val targetWidth: Int,
        val targetHeight: Int,
        /// Cooperative cancellation poll, checked before expensive stages,
        /// inside the per-frame loop, and while draining the encoder. Caller
        /// (coordinator) supplies a generation-aware check; defaults to
        /// never-cancelled for any other caller.
        val isCancelled: () -> Boolean = { false },
    )

    data class TranscodeResult(
        val success: Boolean,
        val failureCode: String?,
        val writtenVideoSamples: Int,
    )

    /// Runs the full probe -> decode -> encode -> mux pipeline synchronously
    /// on the calling thread (callers must not invoke this on the platform
    /// main thread). Never throws -- all failures are reported via
    /// [TranscodeResult.failureCode]. On any non-success outcome, best-effort
    /// deletes a partially written [Params.outputPath].
    fun transcode(params: Params): TranscodeResult {
        var extractor: MediaExtractor? = null
        var retriever: MediaMetadataRetriever? = null
        var codec: MediaCodec? = null
        var encoderInputSurface: Surface? = null
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        var muxerStoppedCleanly = false
        var videoTrackIndex = -1
        var writtenVideoSamples = 0

        var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
        var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
        var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
        var glProgram = 0
        var textureId = 0

        var succeeded = false

        try {
            if (params.frameCount <= 0) {
                return TranscodeResult(false, CODE_OUTPUT_EMPTY, 0)
            }
            if (params.isCancelled()) {
                return TranscodeResult(false, CODE_CANCELLED, 0)
            }

            // ── 1. Probe for a video track ──────────────────────────────────
            val probeExtractor = MediaExtractor()
            extractor = probeExtractor
            try {
                probeExtractor.setDataSource(params.sourcePath)
            } catch (_: Throwable) {
                return TranscodeResult(false, CODE_NO_VIDEO_TRACK, 0)
            }
            var hasVideoTrack = false
            for (i in 0 until probeExtractor.trackCount) {
                val mime = probeExtractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
                if (mime?.startsWith("video/") == true) {
                    hasVideoTrack = true
                    break
                }
            }
            try { probeExtractor.release() } catch (_: Throwable) {}
            extractor = null
            if (!hasVideoTrack) {
                return TranscodeResult(false, CODE_NO_VIDEO_TRACK, 0)
            }
            if (params.isCancelled()) {
                return TranscodeResult(false, CODE_CANCELLED, 0)
            }

            // ── 2. Open the frame-at-time retriever ─────────────────────────
            val mmr = MediaMetadataRetriever()
            retriever = mmr
            try {
                mmr.setDataSource(params.sourcePath)
            } catch (_: Throwable) {
                return TranscodeResult(false, CODE_ENCODE_FAILED, 0)
            }

            // ── 3. Configure the encoder + muxer ────────────────────────────
            val format = MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_AVC, params.targetWidth, params.targetHeight,
            ).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE_BPS)
                setInteger(MediaFormat.KEY_FRAME_RATE, OUTPUT_FPS)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            }
            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            codec = enc
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = enc.createInputSurface()
            encoderInputSurface = surface
            enc.start()

            val mx = MediaMuxer(params.outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = mx

            val frameDurationUs = 1_000_000L / OUTPUT_FPS

            // Local drain closure -- captures and mutates the outer
            // videoTrackIndex/muxerStarted/writtenVideoSamples vars directly
            // so the finally block always sees the latest state.
            fun drainOnce(endOfStream: Boolean, deadlineMs: Long): Boolean {
                val info = MediaCodec.BufferInfo()
                val deadline = System.currentTimeMillis() + deadlineMs
                var draining = true
                var eosObserved = false
                while (draining) {
                    if (params.isCancelled()) break
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
                                    // Fixed frame clock -- output PTS is derived
                                    // from the mux write order, not the source
                                    // timestamps (which run backward).
                                    info.presentationTimeUs = writtenVideoSamples * frameDurationUs
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

            // ── 4. EGL window surface bound to the encoder's input Surface ──
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

            val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
            eglContext = EGL14.eglCreateContext(eglDisplay, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
            if (eglContext == EGL14.EGL_NO_CONTEXT) throw IllegalStateException("eglCreateContext failed")

            val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)
            eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, config, encoderInputSurface, surfaceAttribs, 0)
            if (eglSurface == EGL14.EGL_NO_SURFACE) throw IllegalStateException("eglCreateWindowSurface failed")

            if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
                throw IllegalStateException("eglMakeCurrent failed")
            }

            // ── 5. GLES2 2D-texture program (plain Bitmap upload, no OES) ───
            glProgram = buildShaderProgram()
            val positionLoc = GLES20.glGetAttribLocation(glProgram, "aPosition")
            val texCoordLoc = GLES20.glGetAttribLocation(glProgram, "aTextureCoord")

            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            textureId = textures[0]
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

            // Vertically flipped relative to a naive [0,0]-origin mapping so
            // Bitmap's top-down row order lands right-side-up in the
            // encoder's bottom-up NDC output space (matches BL,BR,TL,TR).
            val texCoords = floatArrayOf(0f, 1f, 1f, 1f, 0f, 0f, 1f, 0f)
            val texBuffer: FloatBuffer = ByteBuffer.allocateDirect(texCoords.size * 4)
                .order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(texCoords); position(0) }
            val quadBuffer: FloatBuffer = ByteBuffer.allocateDirect(8 * 4)
                .order(ByteOrder.nativeOrder()).asFloatBuffer()

            // ── 6. Walk source timestamps backward, one live Bitmap at a time ─
            val windowSeconds = params.trimEndSeconds - params.trimStartSeconds
            val frameStepSeconds = windowSeconds / params.frameCount
            var framesRendered = 0

            for (i in 0 until params.frameCount) {
                if (params.isCancelled()) {
                    return TranscodeResult(false, CODE_CANCELLED, writtenVideoSamples)
                }
                val sourceSeconds = (params.trimEndSeconds - frameStepSeconds * (i + 0.5))
                    .coerceIn(params.trimStartSeconds, params.trimEndSeconds)
                val sourceUs = (sourceSeconds * 1_000_000.0).roundToLong().coerceAtLeast(0L)

                var bitmap: Bitmap? = null
                try {
                    bitmap = mmr.getFrameAtTime(sourceUs, MediaMetadataRetriever.OPTION_CLOSEST) ?: continue

                    writeFitQuad(quadBuffer, bitmap.width, bitmap.height, params.targetWidth, params.targetHeight)

                    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
                    GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
                    val uploadError = GLES20.glGetError()
                    bitmap.recycle()
                    bitmap = null
                    if (uploadError != GLES20.GL_NO_ERROR) {
                        return TranscodeResult(false, CODE_ENCODE_FAILED, writtenVideoSamples)
                    }

                    GLES20.glViewport(0, 0, params.targetWidth, params.targetHeight)
                    GLES20.glClearColor(0f, 0f, 0f, 1f)
                    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
                    GLES20.glUseProgram(glProgram)

                    quadBuffer.position(0)
                    GLES20.glEnableVertexAttribArray(positionLoc)
                    GLES20.glVertexAttribPointer(positionLoc, 2, GLES20.GL_FLOAT, false, 0, quadBuffer)

                    texBuffer.position(0)
                    GLES20.glEnableVertexAttribArray(texCoordLoc)
                    GLES20.glVertexAttribPointer(texCoordLoc, 2, GLES20.GL_FLOAT, false, 0, texBuffer)

                    GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
                    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
                    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

                    GLES20.glDisableVertexAttribArray(positionLoc)
                    GLES20.glDisableVertexAttribArray(texCoordLoc)

                    EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, framesRendered * frameDurationUs * 1000L)
                    EGL14.eglSwapBuffers(eglDisplay, eglSurface)
                    framesRendered++

                    drainOnce(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
                } finally {
                    bitmap?.recycle()
                }
            }

            if (framesRendered == 0) {
                return TranscodeResult(false, CODE_OUTPUT_EMPTY, 0)
            }

            enc.signalEndOfInputStream()
            val eosObserved = drainOnce(endOfStream = true, deadlineMs = ENCODE_EOS_DEADLINE_MS)
            if (params.isCancelled()) {
                return TranscodeResult(false, CODE_CANCELLED, writtenVideoSamples)
            }
            if (!eosObserved) {
                return TranscodeResult(false, CODE_ENCODE_FAILED, writtenVideoSamples)
            }

            if (!muxerStarted || writtenVideoSamples <= 0) {
                return TranscodeResult(false, CODE_OUTPUT_EMPTY, writtenVideoSamples)
            }

            mx.stop()
            muxerStoppedCleanly = true

            val outFile = File(params.outputPath)
            val outSize = if (outFile.exists()) outFile.length() else 0L
            if (outSize <= 0L) {
                return TranscodeResult(false, CODE_OUTPUT_EMPTY, writtenVideoSamples)
            }

            succeeded = true
            return TranscodeResult(true, null, writtenVideoSamples)
        } catch (t: Throwable) {
            Log.e(TAG, "transcode failed for ${params.sourcePath}: $t", t)
            return TranscodeResult(false, CODE_ENCODE_FAILED, writtenVideoSamples)
        } finally {
            if (muxerStarted && !muxerStoppedCleanly) {
                try { muxer?.stop() } catch (_: Throwable) {}
            }
            try { extractor?.release() } catch (_: Throwable) {}
            try { retriever?.release() } catch (_: Throwable) {}
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { muxer?.release() } catch (_: Throwable) {}

            if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglContext != EGL14.EGL_NO_CONTEXT) {
                try {
                    EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
                    if (glProgram != 0) GLES20.glDeleteProgram(glProgram)
                    if (textureId != 0) GLES20.glDeleteTextures(1, intArrayOf(textureId), 0)
                } catch (_: Throwable) {}
            }

            try { encoderInputSurface?.release() } catch (_: Throwable) {}

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

            if (!succeeded) {
                try {
                    val f = File(params.outputPath)
                    if (f.exists()) f.delete()
                } catch (_: Throwable) {}
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GL helpers
    // ─────────────────────────────────────────────────────────────────────────

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

    private fun buildShaderProgram(): Int {
        val vertexSrc = """
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            varying vec2 vTextureCoord;
            void main() {
                gl_Position = aPosition;
                vTextureCoord = aTextureCoord.xy;
            }
        """.trimIndent()

        val fragmentSrc = """
            precision mediump float;
            varying vec2 vTextureCoord;
            uniform sampler2D sTexture;
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
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(program)
            GLES20.glDeleteProgram(program)
            throw IllegalStateException("GL program link failed: $log")
        }
        return program
    }

    /// Aspect-fits a [bitmapWidth]x[bitmapHeight] frame centered onto a
    /// [canvasWidth]x[canvasHeight] black canvas, writing the resulting NDC
    /// quad (BL, BR, TL, TR -- matching the GL_TRIANGLE_STRIP draw order) into
    /// [out]. No rotation term: [MediaMetadataRetriever.getFrameAtTime]
    /// already returns display-oriented pixels.
    private fun writeFitQuad(out: FloatBuffer, bitmapWidth: Int, bitmapHeight: Int, canvasWidth: Int, canvasHeight: Int) {
        val scale = min(canvasWidth.toFloat() / bitmapWidth, canvasHeight.toFloat() / bitmapHeight)
        val halfW = (bitmapWidth * scale) / canvasWidth.toFloat()
        val halfH = (bitmapHeight * scale) / canvasHeight.toFloat()
        out.position(0)
        out.put(floatArrayOf(-halfW, -halfH, halfW, -halfH, -halfW, halfH, halfW, halfH))
        out.position(0)
    }

    companion object {
        private const val TAG = "ReverseSidecarXcode"

        /// Fixed output frame rate. Frame timestamps to sample from the
        /// source are derived from this, not the source's own frame rate --
        /// paired 1:1 with the coordinator's max-duration/max-frame-count
        /// bounds (5s * 30fps == 150 frames).
        const val OUTPUT_FPS = 30

        private const val BIT_RATE_BPS = 6_000_000
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val ENCODE_DRAIN_DEADLINE_MS = 2_000L
        private const val ENCODE_EOS_DEADLINE_MS = 5_000L

        const val CODE_NO_VIDEO_TRACK = "SIDECAR_NO_VIDEO_TRACK"
        const val CODE_ENCODE_FAILED = "SIDECAR_ENCODE_FAILED"
        const val CODE_OUTPUT_EMPTY = "SIDECAR_OUTPUT_EMPTY"
        const val CODE_CANCELLED = "SIDECAR_CANCELLED"
    }
}
