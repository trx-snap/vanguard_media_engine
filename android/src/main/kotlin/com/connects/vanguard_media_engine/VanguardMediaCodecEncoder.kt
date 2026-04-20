package com.connects.vanguard_media_engine

import android.media.*
import android.opengl.*
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer

/**
 * VanguardMediaCodecEncoder — Phase 4 Android Hardware H.264 Encoder
 *
 * Pipeline:
 *   EGL context (OpenGL compositor output)
 *   → MediaCodec encoder (configured with input Surface)
 *   → H.264 NAL units
 *   → MediaMuxer → .mp4
 *
 * Android MediaCodec configured with createInputSurface() accepts OpenGL
 * rendering directly without any CPU memcpy. The GL compositor draws into
 * the encoder's Surface, which MediaCodec reads and encodes on the HW chip.
 */
class VanguardMediaCodecEncoder(
    private val outputPath: String,
    private val width: Int = 1080,
    private val height: Int = 1920,
    private val bitrate: Int = 1_200_000,   // 1.2 Mbps — B4 constraint
    private val fps: Int = 30,
    private val maxSeconds: Double = 30.0,  // B4 Section 6 hard cap
    private val methodChannel: MethodChannel
) {

    // ─── MediaCodec objects ──────────────────────────────────────────────────
    private lateinit var videoEncoder: MediaCodec
    private lateinit var muxer: MediaMuxer
    private var inputSurface: Surface? = null  // GL draws into this

    // ─── EGL for encoder surface binding ────────────────────────────────────
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    // ─── Muxer track indices ─────────────────────────────────────────────────
    private var videoTrackIndex = -1
    private var audioTrackIndex = -1
    private var muxerStarted   = false

    // ─── Thread & timing ────────────────────────────────────────────────────
    private val encodeThread = HandlerThread("VanguardEncode").also { it.start() }
    private val encodeHandler = Handler(encodeThread.looper)
    private var presentationTimeUs = 0L
    private val frameDurationUs = (1_000_000L / fps)
    private val maxFrames = (maxSeconds * fps).toInt()
    private var frameCount = 0

    // ─── State ───────────────────────────────────────────────────────────────
    var isReady = false
        private set

    // B4-S5: cancellation flag — set by plugin via cancel() when cancelExport is called.
    // Checked in submitFrame() so no new frames are submitted after cancellation.
    @Volatile var cancelled = false
        private set

    /** Signal the encoder to stop accepting new frames. Thread-safe. */
    fun cancel() {
        cancelled = true
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────

    fun prepare() {
        encodeHandler.post {
            setupVideoEncoder()
            setupMuxer()
            isReady = true
        }
    }

    private fun setupVideoEncoder() {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)  // 1 key-frame/sec
            setInteger(MediaFormat.KEY_BITRATE_MODE,
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            // Request hardware acceleration — FEATURE_HardwareAccelerated requires API 29+
            // Fallback to SW encoder on older devices automatically
        }

        videoEncoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        videoEncoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)

        // The encoder provides an input Surface. OpenGL renders into this Surface.
        // MediaCodec reads from it directly — zero CPU copy.
        inputSurface = videoEncoder.createInputSurface()
        videoEncoder.start()

        // Bind our EGL context to the encoder's input surface so OpenGL can draw into it
        bindEGLToEncoderSurface()
    }

    private fun bindEGLToEncoderSurface() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        EGL14.eglInitialize(eglDisplay, null, 0, null, 0)

        val attribs = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, 1, numConfigs, 0)

        val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, contextAttribs, 0)

        // Create EGL surface backed by MediaCodec's input Surface
        val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, configs[0], inputSurface, surfaceAttribs, 0)
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
    }

    private fun setupMuxer() {
        muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Encoding
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Call after rendering the current frame into the EGL surface via OpenGL.
     * This signals to MediaCodec that a frame is ready in the input surface.
     */
    fun submitFrame() {
        if (!isReady || cancelled || frameCount >= maxFrames) return

        encodeHandler.post {
            // Signal the encoder that the current EGL surface frame is complete
            EGL14.eglSwapBuffers(eglDisplay, eglSurface)

            // Drain any encoded output buffers
            drainEncoder(endOfStream = false)

            frameCount++
            presentationTimeUs += frameDurationUs

            val progress = frameCount.toFloat() / maxFrames
            methodChannel.invokeMethod("onExportProgress", progress)
        }
    }

    /**
     * Signal end of stream. Drains remaining encoded frames and finalises the MP4.
     */
    fun finish(onComplete: ((Boolean) -> Unit)? = null) {
        encodeHandler.post {
            drainEncoder(endOfStream = true)
            stopMuxer()
            encodeThread.quitSafely()

            val success = File(outputPath).exists() && File(outputPath).length() > 0
            methodChannel.invokeMethod("onExportComplete",
                mapOf("outputPath" to outputPath, "success" to success))
            onComplete?.invoke(success)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MediaCodec Output Drain
    // ─────────────────────────────────────────────────────────────────────────

    private fun drainEncoder(endOfStream: Boolean) {
        if (endOfStream) {
            videoEncoder.signalEndOfInputStream()
        }

        val info = MediaCodec.BufferInfo()
        var draining = true

        while (draining) {
            val outIdx = videoEncoder.dequeueOutputBuffer(info, 10_000L)

            when {
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) draining = false
                }

                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    // First call after start — get the format and add the muxer track
                    val format = videoEncoder.outputFormat
                    videoTrackIndex = muxer.addTrack(format)
                    if (!muxerStarted) {
                        muxer.start()
                        muxerStarted = true
                    }
                }

                outIdx >= 0 -> {
                    val encodedData: ByteBuffer = videoEncoder.getOutputBuffer(outIdx)!!

                    // Skip codec config buffers (SPS/PPS) — they are embedded in the MP4 headers
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        encodedData.position(info.offset)
                        encodedData.limit(info.offset + info.size)
                        // Override PTS with our precise frame clock for A/V sync
                        info.presentationTimeUs = presentationTimeUs
                        if (muxerStarted && videoTrackIndex >= 0) {
                            muxer.writeSampleData(videoTrackIndex, encodedData, info)
                        }
                    }

                    videoEncoder.releaseOutputBuffer(outIdx, false)

                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        draining = false
                    }
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Muxer / Cleanup
    // ─────────────────────────────────────────────────────────────────────────

    private fun stopMuxer() {
        if (muxerStarted) {
            muxer.stop()
            muxer.release()
        }
        videoEncoder.stop()
        videoEncoder.release()
        EGL14.eglDestroySurface(eglDisplay, eglSurface)
        EGL14.eglDestroyContext(eglDisplay, eglContext)
        EGL14.eglTerminate(eglDisplay)
        inputSurface?.release()
    }
}
