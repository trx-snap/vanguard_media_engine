package com.connects.vanguard_media_engine.export

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
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidTimelineVideoEncoder (Export Unit C) ───────────────────────────────
//
// Export-owned H.264 surface-input encoder for the production `exportTimeline`
// route. Fully independent of the legacy `VanguardMediaCodecEncoder` (dev/proof
// path) -- no shared state, no MethodChannel calls, no onExportComplete
// callback. This class is never reused by legacy `startExport`.
//
// Real video frame transfer (Opus correction): each decoder output frame is
// released onto a SurfaceTexture-backed OES texture, then drawn by a GL
// passthrough shader into the encoder's own input EGL surface before
// eglSwapBuffers submits it to MediaCodec. This is a genuine GPU pixel
// transfer -- never a null-surface decode paired with a swapped-but-undrawn
// encoder surface, which was the legacy false-proof pattern this Unit
// replaces.
//
// PTS mechanism (frozen — do not change without re-verifying multi-clip
// continuity): fixed frame clock on encoder output. Each muxed sample's
// presentationTimeUs = writtenVideoSamples * frameDurationUs, mirroring
// AndroidDagRenderSmokeHarness's Phase-5 encoder drain. Because clips are
// concatenated hard-cut (no overlap), this produces a strictly increasing,
// gap-free PTS sequence across clip boundaries without any per-clip timestamp
// bookkeeping.
//
// Guardrails enforced upstream by AndroidTimelineExportSession (not here):
// video-only clips, speed == 1.0, zero rotation, identical decoded
// width/height across clips and matching the requested output width/height.
// This encoder therefore never scales, rotates, or crops -- it is a 1:1
// pixel passthrough from decoder OES texture to encoder surface.
class AndroidTimelineVideoEncoder(
    private val outputPath: String,
    private val width: Int,
    private val height: Int,
    private val fps: Int,
    private val bitrateBps: Int,
) {
    data class ClipInput(
        val sourcePath: String,
        val trimStartSeconds: Double,
        val trimEndSeconds: Double,
    )

    data class EncodeResult(
        val success: Boolean,
        val reason: String,
        val writtenVideoSamples: Int,
        val outputSizeBytes: Long,
    )

    @Volatile private var cancelRequested = false

    /** Signals the encode loop to stop feeding new frames. Thread-safe. */
    fun cancel() {
        cancelRequested = true
    }

    private val frameDurationUs = 1_000_000L / fps.coerceAtLeast(1)

    // ─── MediaCodec / MediaMuxer state ───────────────────────────────────────
    private var codec: MediaCodec? = null
    private var encoderInputSurface: Surface? = null
    private var muxer: MediaMuxer? = null
    private var muxerStarted = false
    private var videoTrackIndex = -1
    private var writtenVideoSamples = 0

    // ─── EGL / GL state (bound to the encoder's input surface) ──────────────
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var glProgram = 0
    private var oesTextureId = 0
    private var aPositionLoc = 0
    private var aTexCoordLoc = 0
    private var uSTMatrixLoc = 0
    private var framesSubmitted = 0

    // ─── Decode-side transfer surface (OES texture target for the decoder) ──
    private var decodeSurfaceTexture: SurfaceTexture? = null
    private var decodeInputSurface: Surface? = null
    private val frameSyncLock = Object()
    private var frameAvailable = false
    private val stMatrix = FloatArray(16)

    /// Encodes [clips] sequentially (hard-cut concatenation) into [outputPath]
    /// as a video-only MP4. Returns a structured result; never throws.
    fun encode(clips: List<ClipInput>): EncodeResult {
        var succeeded = false
        var muxerStoppedCleanly = false
        var reason = "not_run"
        try {
            setupEncoderAndMuxer()
            setupGlAndDecodeSurface()

            for (clip in clips) {
                if (cancelRequested) break
                val failureReason = decodeClipIntoEncoder(clip)
                if (failureReason != null) {
                    if (cancelRequested) break
                    reason = failureReason
                    return EncodeResult(false, reason, writtenVideoSamples, 0L)
                }
            }

            if (cancelRequested) {
                reason = "cancelled"
                return EncodeResult(false, reason, writtenVideoSamples, 0L)
            }

            codec!!.signalEndOfInputStream()
            val eosObserved = drainEncoder(endOfStream = true, deadlineMs = ENCODE_EOS_DEADLINE_MS)
            if (!eosObserved) {
                reason = "encoder_eos_drain_timeout"
                return EncodeResult(false, reason, writtenVideoSamples, 0L)
            }

            if (!muxerStarted || writtenVideoSamples <= 0) {
                reason = "no_video_samples_written"
                return EncodeResult(false, reason, writtenVideoSamples, 0L)
            }

            muxer!!.stop()
            muxerStoppedCleanly = true

            val outFile = File(outputPath)
            val outSize = if (outFile.exists()) outFile.length() else 0L
            if (outSize <= 0L) {
                reason = "output_file_empty_or_missing"
                return EncodeResult(false, reason, writtenVideoSamples, 0L)
            }

            succeeded = true
            reason = "success"
            return EncodeResult(true, reason, writtenVideoSamples, outSize)
        } catch (t: Throwable) {
            reason = "exception:${t.javaClass.simpleName}"
            Log.e(TAG, "encode failed: $t", t)
            return EncodeResult(false, reason, writtenVideoSamples, 0L)
        } finally {
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

    private fun setupGlAndDecodeSurface() {
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
            EGL14.EGL_NONE
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

        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        oesTextureId = textures[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        val texture = SurfaceTexture(oesTextureId)
        texture.setOnFrameAvailableListener {
            synchronized(frameSyncLock) {
                frameAvailable = true
                frameSyncLock.notifyAll()
            }
        }
        decodeSurfaceTexture = texture
        decodeInputSurface = Surface(texture)

        setupShaderProgram()
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
    // Per-clip decode → GL transfer → encode
    // ─────────────────────────────────────────────────────────────────────────

    /// Returns null on success, or a machine-readable failure reason string
    /// for any non-cancel decode/transfer failure.
    private fun decodeClipIntoEncoder(clip: ClipInput): String? {
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        try {
            extractor.setDataSource(clip.sourcePath)
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
            if (trackIndex < 0 || trackFormat == null) return "clip_no_video_track:${clip.sourcePath}"
            extractor.selectTrack(trackIndex)

            val trimStartUs = (clip.trimStartSeconds * 1_000_000L).toLong()
            if (trimStartUs > 0L) {
                extractor.seekTo(trimStartUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            }
            val trimEndUs = (clip.trimEndSeconds * 1_000_000L).toLong()

            val mime = trackFormat.getString(MediaFormat.KEY_MIME)!!
            val dec = MediaCodec.createDecoderByType(mime)
            dec.configure(trackFormat, decodeInputSurface, null, 0)
            dec.start()
            decoder = dec

            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var renderedFramesInClip = 0

            while (true) {
                if (cancelRequested && !inputDone) {
                    val inIdx = dec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                    if (inIdx >= 0) {
                        dec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    }
                } else if (!inputDone) {
                    val inIdx = dec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                    if (inIdx >= 0) {
                        val buf = dec.getInputBuffer(inIdx)!!
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0 || extractor.sampleTime > trimEndUs) {
                            dec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            dec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                val outIdx = dec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                if (outIdx >= 0) {
                    val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    if (info.size > 0) {
                        // Trim window is [trimStartUs, trimEndUs) — decoded pre-roll
                        // needed for the sync seek, and any frame at/after trimEnd,
                        // must be dropped rather than rendered.
                        val inWindow = info.presentationTimeUs >= trimStartUs &&
                            info.presentationTimeUs < trimEndUs
                        if (inWindow) {
                            dec.releaseOutputBuffer(outIdx, true)
                            if (!awaitNewImage(FRAME_WAIT_TIMEOUT_MS)) {
                                // Real transfer failed to arrive — report honestly, never fake success.
                                return "frame_transfer_timeout:${clip.sourcePath}"
                            }
                            drawAndSubmitFrame()
                            drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
                            renderedFramesInClip++
                        } else {
                            dec.releaseOutputBuffer(outIdx, false)
                        }
                    } else {
                        dec.releaseOutputBuffer(outIdx, false)
                    }
                    if (isEos) break
                }
                if (cancelRequested && inputDone && outIdx == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    // Cancellation requested and no more input pending — stop waiting for
                    // a decoder drain that may never come from a codec we've EOS'd.
                    break
                }
            }

            if (renderedFramesInClip == 0 && !cancelRequested) {
                return "no_frames_in_trim_window:${clip.sourcePath}"
            }
            return null
        } catch (t: Throwable) {
            Log.e(TAG, "decodeClipIntoEncoder failed for ${clip.sourcePath}: $t", t)
            return "clip_decode_exception:${t.javaClass.simpleName}:${clip.sourcePath}"
        } finally {
            try { decoder?.stop() } catch (_: Throwable) {}
            try { decoder?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
        }
    }

    /// Blocks until the decoder's SurfaceTexture reports a new frame, then
    /// calls updateTexImage(). Returns false on timeout (real failure, not faked).
    private fun awaitNewImage(timeoutMs: Long): Boolean {
        synchronized(frameSyncLock) {
            val deadline = System.currentTimeMillis() + timeoutMs
            while (!frameAvailable) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0L) return false
                frameSyncLock.wait(remaining)
            }
            frameAvailable = false
        }
        decodeSurfaceTexture!!.updateTexImage()
        return true
    }

    private val quadCoords = floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
    private val texCoords = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)

    /// Draws the current OES texture (decoded frame) into the encoder's EGL
    /// surface and submits it via eglSwapBuffers. Real GPU frame transfer —
    /// the decoded pixels are drawn, not assumed.
    private fun drawAndSubmitFrame() {
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        decodeSurfaceTexture!!.getTransformMatrix(stMatrix)

        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(glProgram)

        val quadBuf = ByteBuffer.allocateDirect(quadCoords.size * 4)
            .order(ByteOrder.nativeOrder()).asFloatBuffer()
        quadBuf.put(quadCoords).position(0)
        GLES20.glEnableVertexAttribArray(aPositionLoc)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadBuf)

        val texBuf = ByteBuffer.allocateDirect(texCoords.size * 4)
            .order(ByteOrder.nativeOrder()).asFloatBuffer()
        texBuf.put(texCoords).position(0)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, texBuf)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES20.glUniformMatrix4fv(uSTMatrixLoc, 1, false, stMatrix, 0)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPositionLoc)
        GLES20.glDisableVertexAttribArray(aTexCoordLoc)

        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, framesSubmitted * frameDurationUs * 1000L)
        framesSubmitted++
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Encoder output drain (fixed frame clock — frozen PTS mechanism)
    // ─────────────────────────────────────────────────────────────────────────

    /// Drains encoder output into the muxer. When [endOfStream] is true,
    /// returns whether the encoder's own EOS buffer was actually observed
    /// before [deadlineMs] elapsed (false means the drain timed out without
    /// seeing EOS — a real failure, not a fake completion). When
    /// [endOfStream] is false (per-frame drain), always returns true.
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
                            // Frozen mechanism: fixed frame clock, matching
                            // AndroidDagRenderSmokeHarness's Phase-5 drain.
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

    // ─────────────────────────────────────────────────────────────────────────
    // Cleanup
    // ─────────────────────────────────────────────────────────────────────────

    private fun releaseAll() {
        try { codec?.stop() } catch (_: Throwable) {}
        try { codec?.release() } catch (_: Throwable) {}
        try { muxer?.release() } catch (_: Throwable) {}

        if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglContext != EGL14.EGL_NO_CONTEXT) {
            try {
                EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
                if (glProgram != 0) GLES20.glDeleteProgram(glProgram)
                if (oesTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(oesTextureId), 0)
            } catch (_: Throwable) {}
        }

        try { encoderInputSurface?.release() } catch (_: Throwable) {}
        try { decodeInputSurface?.release() } catch (_: Throwable) {}
        try { decodeSurfaceTexture?.release() } catch (_: Throwable) {}

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
    }

    companion object {
        private const val TAG = "VGTimelineVideoEnc"
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val FRAME_WAIT_TIMEOUT_MS = 2_000L
        private const val ENCODE_DRAIN_DEADLINE_MS = 2_000L
        private const val ENCODE_EOS_DEADLINE_MS = 5_000L
    }
}
