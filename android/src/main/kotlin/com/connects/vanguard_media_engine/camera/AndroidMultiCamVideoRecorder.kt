// AndroidMultiCamVideoRecorder.kt
// Slice 5: Composited dual-camera video recording.
//
// Encodes a stream of composited-preview Bitmaps (delivered by
// AndroidDualCameraCompositor.onFrameRendered) into an H.264/AVC MP4 at 30fps,
// with best-effort AAC microphone audio (MC-20: falls back to video-only on
// any permission/hardware/init failure).
//
// Pipeline:
//   submitFrame(Bitmap) [compositor render thread, borrowed bitmap]
//     → copy into a pooled Bitmap (backpressure: drop if pool is empty)
//     → bounded queue
//     → video thread: GLUtils.texImage2D upload → GLES quad draw into the
//       encoder's input Surface → eglPresentationTimeANDROID (wall-clock PTS)
//       → eglSwapBuffers → drain MediaCodec → MediaMuxer
//
// Invariants:
//   - submitFrame() never blocks and never allocates on the hot path.
//   - PTS is derived from System.nanoTime() relative to start(), not a frame
//     counter — info.presentationTimeUs from the video encoder is trusted
//     as-is (never overwritten) because it is authoritative once the EGL
//     producer timestamp has been set.
//   - MediaMuxer.start() is deferred until the video track exists and audio
//     is either disabled, present, or has been given up on after a bounded
//     grace window — the muxer can never deadlock waiting for a track.
//   - Output is written to "<outputPath>.tmp" and atomically renamed on
//     success; the .tmp file never survives a failed or aborted attempt.
//   - start()/submitFrame()/stop()/abort() are safe to call from any thread.
//     stop() and abort() are both idempotent.

package com.connects.vanguard_media_engine.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
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
import java.util.ArrayDeque
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class AndroidMultiCamVideoRecorder(
    private val context: Context,
    private val outputPath: String,
    private val width: Int,
    private val height: Int,
    private val bitrate: Int = 10_000_000, // 10 Mbps (iOS parity)
    private val fps: Int = 30,
) {
    companion object {
        private const val TAG = "AndroidMultiCamVideoRecorder"
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val EOS_DRAIN_DEADLINE_MS = 5_000L
        private const val AUDIO_SAMPLE_RATE = 44_100
        private const val AUDIO_BIT_RATE = 128_000
        private const val AUDIO_TRACK_GRACE_MS = 1_500L
        private const val BITMAP_POOL_SIZE = 2
        private const val STOP_JOIN_TIMEOUT_MS = 3_000L
        private const val FRAME_POLL_TIMEOUT_MS = 100L
        private const val MAX_PENDING_SAMPLES = 120
    }

    private val tmpPath = "$outputPath.tmp"

    // ── Lifecycle state ──────────────────────────────────────────────────────
    @Volatile private var running = false
    private val stopped = AtomicBoolean(false)
    private var startNanos = 0L
    private var endNanos = 0L
    private var firstVideoFrameNanos = -1L

    // Wall-clock origin for both audio and video PTS.  Set atomically in
    // submitFrame() on the first delivered composited frame so that the audio
    // thread can observe it and drop pre-origin mic samples.  Both streams
    // measure their presentation timestamps relative to this instant, ensuring
    // the MP4 container has start_time = 0.000000 for both tracks.
    @Volatile private var recordingOriginNanos = -1L

    // ── Frame counters (stats contract) ─────────────────────────────────────
    private val framesOffered = AtomicInteger(0)
    private val framesAppended = AtomicInteger(0)
    private val framesDropped = AtomicInteger(0)

    // ── Bitmap pool + transport queue (submitFrame → video thread) ─────────
    // Two pre-allocated pooled bitmaps + a same-capacity queue: submitFrame()
    // copies the borrowed frame into a pooled bitmap and enqueues it; the
    // video thread dequeues, encodes, and returns the bitmap to the pool.
    // If the pool is empty, the frame is dropped rather than blocking the
    // compositor's render loop.
    private val bitmapPool = ArrayBlockingQueue<Bitmap>(BITMAP_POOL_SIZE)
    private val frameQueue = ArrayBlockingQueue<Bitmap>(BITMAP_POOL_SIZE)

    // ── Video encoder / EGL (owned exclusively by the video thread once started) ──
    private var videoThread: Thread? = null
    private val videoStopRequested = AtomicBoolean(false)
    private var videoEncoder: MediaCodec? = null
    private var encoderInputSurface: Surface? = null
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var glProgram = 0
    private var aPositionLoc = 0
    private var aTexCoordLoc = 0
    private var frameTextureId = 0

    private val quadCoords = floatArrayOf(
        -1f, -1f,
        1f, -1f,
        -1f, 1f,
        1f, 1f,
    )

    // Vertically flipped relative to a naive [0,1] mapping so Bitmap's
    // top-down row order lands right-side-up in the encoder's bottom-up NDC
    // output space (matches AndroidTimelineVideoEncoder's texCoords2D).
    private val texCoords = floatArrayOf(
        0f, 1f,
        1f, 1f,
        0f, 0f,
        1f, 0f,
    )

    private val quadBuffer: FloatBuffer = ByteBuffer.allocateDirect(quadCoords.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(quadCoords); position(0) }
    private val texBuffer: FloatBuffer = ByteBuffer.allocateDirect(texCoords.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(texCoords); position(0) }

    // ── Audio (best-effort; MC-20 fallback) ─────────────────────────────────
    private var audioThread: Thread? = null
    private var audioRecord: AudioRecord? = null
    private var audioEncoder: MediaCodec? = null
    private var audioMinBufferSize = 0
    @Volatile private var audioConfigured = false
    @Volatile private var audioActive = false
    @Volatile private var audioFormatReady = false
    @Volatile private var audioPermanentlyDisabled = false

    // ── Muxer (shared between video and audio threads under muxerLock) ─────
    private class PendingSample(
        val data: ByteArray,
        val info: MediaCodec.BufferInfo,
    )

    private val muxerLock = Any()
    private var muxer: MediaMuxer? = null
    @Volatile private var muxerStarted = false
    private var videoTrackIndex = -1
    private var audioTrackIndex = -1
    @Volatile private var videoFormatReady = false
    @Volatile private var videoFormatArrivedAtNanos = 0L
    private val pendingVideoSamples = ArrayDeque<PendingSample>()
    private val pendingAudioSamples = ArrayDeque<PendingSample>()

    // ─────────────────────────────────────────────────────────────────────────
    // start()
    // ─────────────────────────────────────────────────────────────────────────

    /** Initializes the encoder(s), muxer, and video thread. Returns false on any init failure. */
    fun start(): Boolean {
        if (width <= 0 || height <= 0) {
            Log.e(TAG, "start: invalid dimensions ${width}x$height")
            return false
        }

        try {
            val parent = File(outputPath).parentFile
            if (parent != null && !parent.exists() && !parent.mkdirs()) {
                Log.e(TAG, "start: failed to create parent directory: ${parent.absolutePath}")
                return false
            }
            val tmp = File(tmpPath)
            if (tmp.exists()) tmp.delete()
        } catch (t: Throwable) {
            Log.e(TAG, "start: failed to prepare output path: ${t.javaClass.simpleName}: ${t.message}", t)
            return false
        }

        try {
            repeat(BITMAP_POOL_SIZE) {
                bitmapPool.put(Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888))
            }
        } catch (t: Throwable) {
            Log.e(TAG, "start: bitmap pool allocation failed: ${t.javaClass.simpleName}: ${t.message}", t)
            drainBitmapPoolQuietly()
            return false
        }

        var localEnc: MediaCodec? = null
        var localSurface: Surface? = null
        try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            }
            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            localEnc = enc
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = enc.createInputSurface()
            localSurface = surface
            enc.start()
            videoEncoder = enc
            encoderInputSurface = surface
        } catch (t: Throwable) {
            Log.e(TAG, "start: video encoder setup failed: ${t.javaClass.simpleName}: ${t.message}", t)
            try { localEnc?.stop() } catch (_: Throwable) {}
            try { localEnc?.release() } catch (_: Throwable) {}
            try { localSurface?.release() } catch (_: Throwable) {}
            drainBitmapPoolQuietly()
            return false
        }

        try {
            muxer = MediaMuxer(tmpPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        } catch (t: Throwable) {
            Log.e(TAG, "start: muxer creation failed: ${t.javaClass.simpleName}: ${t.message}", t)
            releaseVideoEncoderOnly()
            drainBitmapPoolQuietly()
            return false
        }

        setupAudioBestEffort()

        val setupLatch = CountDownLatch(1)
        val setupFailed = AtomicBoolean(false)
        val thread = Thread({
            try {
                setupEglAndShader()
            } catch (t: Throwable) {
                Log.e(TAG, "start: EGL/shader setup failed: ${t.javaClass.simpleName}: ${t.message}", t)
                setupFailed.set(true)
                setupLatch.countDown()
                return@Thread
            }
            setupLatch.countDown()
            runVideoLoop()
        }, "MultiCamVideoRecorder-Video")
        videoThread = thread
        thread.start()

        if (!setupLatch.await(3, TimeUnit.SECONDS) || setupFailed.get()) {
            Log.e(TAG, "start: video thread EGL setup timed out or failed")
            videoStopRequested.set(true)
            try { thread.join(1_000) } catch (_: InterruptedException) {}
            teardownAfterFailedStart()
            return false
        }

        startNanos = System.nanoTime()
        running = true
        Log.i(TAG, "start: recording started -> $tmpPath (${width}x$height audioConfigured=$audioConfigured)")
        return true
    }

    // ─────────────────────────────────────────────────────────────────────────
    // submitFrame() — called on the compositor render thread
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Accepts a borrowed, compositor-owned [bitmap] valid only for the
     * duration of this call. Never blocks: copies into a pooled bitmap and
     * enqueues it, or counts a drop if the pool is exhausted (backpressure).
     */
    fun submitFrame(bitmap: Bitmap) {
        if (!running || stopped.get()) return
        framesOffered.incrementAndGet()

        // Establish the shared recording origin on the very first offered frame.
        // volatile-write is safe from the compositor render thread; the audio
        // thread observes it via volatile-read before stamping any audio chunk.
        if (recordingOriginNanos < 0L) {
            recordingOriginNanos = System.nanoTime()
        }

        val pooled = bitmapPool.poll()
        if (pooled == null) {
            framesDropped.incrementAndGet()
            return
        }

        try {
            Canvas(pooled).drawBitmap(bitmap, 0f, 0f, null)
        } catch (t: Throwable) {
            Log.w(TAG, "submitFrame: copy into pooled bitmap failed: ${t.javaClass.simpleName}: ${t.message}")
            bitmapPool.offer(pooled)
            framesDropped.incrementAndGet()
            return
        }

        if (!frameQueue.offer(pooled)) {
            bitmapPool.offer(pooled)
            framesDropped.incrementAndGet()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // stop() / abort()
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Finalizes the recording: stops audio, drains and signals EOS to the
     * video encoder, stops and releases the muxer, and atomically renames
     * the temp file to [outputPath]. Returns null (never throws) on any
     * finalize failure. Idempotent — a second call is a safe no-op.
     */
    fun stop(): Map<String, Any>? {
        if (!stopped.compareAndSet(false, true)) {
            return null
        }
        running = false
        endNanos = System.nanoTime()

        audioActive = false
        audioThread?.let { t -> try { t.join(STOP_JOIN_TIMEOUT_MS) } catch (_: InterruptedException) {} }
        releaseAudioResources()

        videoStopRequested.set(true)
        videoThread?.let { t -> try { t.join(STOP_JOIN_TIMEOUT_MS) } catch (_: InterruptedException) {} }

        var finalizeOk = true
        try {
            if (muxerStarted) {
                muxer?.stop()
            } else {
                finalizeOk = false
            }
        } catch (t: Throwable) {
            Log.e(TAG, "stop: muxer.stop() failed: ${t.javaClass.simpleName}: ${t.message}", t)
            finalizeOk = false
        }
        try { muxer?.release() } catch (_: Throwable) {}

        synchronized(muxerLock) {
            pendingVideoSamples.clear()
            pendingAudioSamples.clear()
        }

        releaseVideoResources()

        if (!finalizeOk) {
            Log.e(TAG, "stop: recording never produced a usable video track — discarding")
            deleteQuietly(File(tmpPath))
            return null
        }

        val tmpFile = File(tmpPath)
        val destFile = File(outputPath)
        try {
            if (destFile.exists()) destFile.delete()
        } catch (_: Throwable) {}
        val renamed = try { tmpFile.renameTo(destFile) } catch (t: Throwable) { false }
        if (!renamed) {
            Log.e(TAG, "stop: rename $tmpPath -> $outputPath failed")
            deleteQuietly(tmpFile)
            return null
        }

        val durationSeconds = (endNanos - startNanos).coerceAtLeast(0L) / 1_000_000_000.0
        val fileSizeBytes = try { destFile.length() } catch (_: Throwable) { 0L }

        Log.i(TAG, "stop: finalized $outputPath (${durationSeconds}s, ${fileSizeBytes}b, offered=${framesOffered.get()} appended=${framesAppended.get()} dropped=${framesDropped.get()})")

        return mapOf(
            "filePath" to outputPath,
            "durationSeconds" to durationSeconds,
            "width" to width,
            "height" to height,
            "framesOffered" to framesOffered.get(),
            "framesAppended" to framesAppended.get(),
            "framesDroppedWriterNotReady" to framesDropped.get(),
            "writerStatus" to 2,
            "fileSizeBytes" to fileSizeBytes,
        )
    }

    /** Aborts an in-progress or failed-to-start recording, releasing all resources. Idempotent. */
    fun abort() {
        if (!stopped.compareAndSet(false, true)) {
            return
        }
        running = false

        audioActive = false
        audioThread?.let { t -> try { t.join(STOP_JOIN_TIMEOUT_MS) } catch (_: InterruptedException) {} }
        releaseAudioResources()

        videoStopRequested.set(true)
        videoThread?.let { t -> try { t.join(STOP_JOIN_TIMEOUT_MS) } catch (_: InterruptedException) {} }
        releaseVideoResources()

        try { if (muxerStarted) muxer?.stop() } catch (_: Throwable) {}
        try { muxer?.release() } catch (_: Throwable) {}

        synchronized(muxerLock) {
            pendingVideoSamples.clear()
            pendingAudioSamples.clear()
        }

        deleteQuietly(File(tmpPath))
        Log.i(TAG, "abort: recording aborted, resources released")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Video thread — EGL setup, draw loop, encoder drain
    // ─────────────────────────────────────────────────────────────────────────

    private fun setupEglAndShader() {
        val surface = encoderInputSurface ?: throw IllegalStateException("encoderInputSurface not set")

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
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, config, surface, surfaceAttribs, 0)
        if (eglSurface == EGL14.EGL_NO_SURFACE) throw IllegalStateException("eglCreateWindowSurface failed")

        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            throw IllegalStateException("eglMakeCurrent failed")
        }

        setupShaderProgram()

        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        frameTextureId = textures[0]
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, frameTextureId)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
    }

    private fun setupShaderProgram() {
        val vertexSrc = """
            attribute vec4 aPosition;
            attribute vec2 aTexCoord;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = aTexCoord;
            }
        """.trimIndent()

        val fragmentSrc = """
            precision mediump float;
            varying vec2 vTexCoord;
            uniform sampler2D sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, vTexCoord);
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
        aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTexCoord")
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

    private fun runVideoLoop() {
        while (true) {
            val bitmap = try {
                frameQueue.poll(FRAME_POLL_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                null
            }

            if (bitmap != null) {
                try {
                    drawFrame(bitmap)
                } catch (t: Throwable) {
                    Log.w(TAG, "runVideoLoop: drawFrame failed: ${t.javaClass.simpleName}: ${t.message}")
                }
                bitmapPool.offer(bitmap)
                drainVideoEncoder(endOfStream = false)
                checkAudioGraceTimeout()
            }

            if (videoStopRequested.get() && frameQueue.isEmpty()) {
                break
            }
        }

        try {
            videoEncoder?.signalEndOfInputStream()
        } catch (t: Throwable) {
            Log.w(TAG, "runVideoLoop: signalEndOfInputStream failed: ${t.message}")
        }
        drainVideoEncoder(endOfStream = true)
    }

    private fun drawFrame(bitmap: Bitmap) {
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(glProgram)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, frameTextureId)
        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)

        quadBuffer.position(0)
        GLES20.glEnableVertexAttribArray(aPositionLoc)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadBuffer)

        texBuffer.position(0)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, texBuffer)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPositionLoc)
        GLES20.glDisableVertexAttribArray(aTexCoordLoc)

        // PTS relative to the shared recording origin established in
        // submitFrame().  recordingOriginNanos is always set before any frame
        // reaches the video thread, so the coerceAtLeast guard is defensive.
        val ptsNs = (System.nanoTime() - recordingOriginNanos).coerceAtLeast(0L)
        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, ptsNs)
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)
    }

    private fun drainVideoEncoder(endOfStream: Boolean) {
        val enc = videoEncoder ?: return
        val mx = muxer ?: return
        val info = MediaCodec.BufferInfo()
        val deadline = if (endOfStream) System.currentTimeMillis() + EOS_DRAIN_DEADLINE_MS else 0L

        while (true) {
            if (endOfStream && System.currentTimeMillis() > deadline) {
                Log.w(TAG, "drainVideoEncoder: EOS drain deadline exceeded")
                return
            }
            val outIdx = try {
                enc.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
            } catch (t: Throwable) {
                Log.w(TAG, "drainVideoEncoder: dequeueOutputBuffer threw: ${t.message}")
                return
            }
            when {
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return
                }
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    synchronized(muxerLock) {
                        if (videoTrackIndex < 0) {
                            videoTrackIndex = mx.addTrack(enc.outputFormat)
                            videoFormatReady = true
                            videoFormatArrivedAtNanos = System.nanoTime()
                            maybeStartMuxerLocked()
                        }
                    }
                }
                outIdx >= 0 -> {
                    val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    if (!isConfig && info.size > 0) {
                        val buf = enc.getOutputBuffer(outIdx)
                        if (buf != null) {
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            var wrote = false
                            synchronized(muxerLock) {
                                if (muxerStarted && videoTrackIndex >= 0) {
                                    try {
                                        mx.writeSampleData(videoTrackIndex, buf, info)
                                        wrote = true
                                    } catch (t: Throwable) {
                                        Log.w(TAG, "drainVideoEncoder: writeSampleData failed: ${t.message}")
                                    }
                                } else {
                                    // Buffer pre-muxer video samples so Frame 0 (IDR keyframe)
                                    // is preserved while audio initializes.
                                    if (pendingVideoSamples.size < MAX_PENDING_SAMPLES) {
                                        val data = ByteArray(info.size)
                                        buf.get(data)
                                        val copyInfo = MediaCodec.BufferInfo().apply {
                                            set(0, info.size, info.presentationTimeUs, info.flags)
                                        }
                                        pendingVideoSamples.add(PendingSample(data, copyInfo))
                                    } else {
                                        framesDropped.incrementAndGet()
                                    }
                                }
                            }
                            if (wrote) framesAppended.incrementAndGet()
                        }
                    }
                    enc.releaseOutputBuffer(outIdx, false)
                    if (isEos) return
                }
            }
        }
    }

    /** Called from the video thread after every processed frame; never blocks. */
    private fun checkAudioGraceTimeout() {
        if (muxerStarted || !videoFormatReady || !audioConfigured || audioFormatReady || audioPermanentlyDisabled) {
            return
        }
        val arrivedAt = videoFormatArrivedAtNanos
        if (arrivedAt == 0L) return
        val elapsedMs = (System.nanoTime() - arrivedAt) / 1_000_000L
        if (elapsedMs < AUDIO_TRACK_GRACE_MS) return

        Log.w(TAG, "checkAudioGraceTimeout: audio track absent after ${AUDIO_TRACK_GRACE_MS}ms — falling back to video-only (MC-20)")
        audioPermanentlyDisabled = true
        audioActive = false
        synchronized(muxerLock) {
            maybeStartMuxerLocked()
        }
    }

    /** Must be called while holding [muxerLock]. */
    private fun maybeStartMuxerLocked() {
        if (muxerStarted) return
        if (!videoFormatReady) return
        val audioSatisfied = !audioConfigured || audioFormatReady || audioPermanentlyDisabled
        if (!audioSatisfied) return
        val mx = muxer ?: return
        try {
            mx.start()
            muxerStarted = true
            Log.i(TAG, "maybeStartMuxerLocked: muxer started (audioConfigured=$audioConfigured audioTrackIndex=$audioTrackIndex pendingVideo=${pendingVideoSamples.size} pendingAudio=${pendingAudioSamples.size})")

            // Flush buffered pre-muxer video frames starting with Frame 0 (IDR keyframe)
            while (pendingVideoSamples.isNotEmpty()) {
                val sample = pendingVideoSamples.removeFirst()
                try {
                    val byteBuf = ByteBuffer.allocateDirect(sample.data.size).apply {
                        put(sample.data)
                        position(0)
                        limit(sample.data.size)
                    }
                    mx.writeSampleData(videoTrackIndex, byteBuf, sample.info)
                    framesAppended.incrementAndGet()
                } catch (t: Throwable) {
                    Log.w(TAG, "maybeStartMuxerLocked: failed to flush pending video frame: ${t.message}")
                }
            }

            // Flush buffered pre-muxer audio frames
            if (audioTrackIndex >= 0) {
                while (pendingAudioSamples.isNotEmpty()) {
                    val sample = pendingAudioSamples.removeFirst()
                    try {
                        val byteBuf = ByteBuffer.allocateDirect(sample.data.size).apply {
                            put(sample.data)
                            position(0)
                            limit(sample.data.size)
                        }
                        mx.writeSampleData(audioTrackIndex, byteBuf, sample.info)
                    } catch (t: Throwable) {
                        Log.w(TAG, "maybeStartMuxerLocked: failed to flush pending audio frame: ${t.message}")
                    }
                }
            } else {
                pendingAudioSamples.clear()
            }
        } catch (t: Throwable) {
            Log.e(TAG, "maybeStartMuxerLocked: muxer.start() failed: ${t.javaClass.simpleName}: ${t.message}", t)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Audio thread — best-effort mic capture + AAC encode (MC-20)
    // ─────────────────────────────────────────────────────────────────────────

    private fun setupAudioBestEffort() {
        try {
            if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                Log.i(TAG, "setupAudioBestEffort: RECORD_AUDIO not granted — video-only recording (MC-20)")
                return
            }

            val minBufSize = AudioRecord.getMinBufferSize(
                AUDIO_SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBufSize <= 0) {
                Log.w(TAG, "setupAudioBestEffort: getMinBufferSize returned $minBufSize — video-only recording (MC-20)")
                return
            }

            val record = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                AUDIO_SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBufSize * 2,
            )
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                Log.w(TAG, "setupAudioBestEffort: AudioRecord failed to initialize — video-only recording (MC-20)")
                try { record.release() } catch (_: Throwable) {}
                return
            }

            val audioFormat = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, AUDIO_SAMPLE_RATE, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BIT_RATE)
            }
            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            enc.configure(audioFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            enc.start()

            audioRecord = record
            audioEncoder = enc
            audioMinBufferSize = minBufSize
            audioConfigured = true
            audioActive = true

            val thread = Thread({ runAudioLoop() }, "MultiCamVideoRecorder-Audio")
            audioThread = thread
            thread.start()

            Log.i(TAG, "setupAudioBestEffort: mic audio enabled (AAC 44.1kHz mono 128kbps)")
        } catch (t: Throwable) {
            Log.w(TAG, "setupAudioBestEffort: unexpected failure — video-only recording (MC-20): ${t.javaClass.simpleName}: ${t.message}")
            audioConfigured = false
            audioActive = false
            try { audioEncoder?.release() } catch (_: Throwable) {}
            try { audioRecord?.release() } catch (_: Throwable) {}
            audioEncoder = null
            audioRecord = null
        }
    }

    private fun runAudioLoop() {
        val record = audioRecord ?: return
        try {
            record.startRecording()
        } catch (t: Throwable) {
            Log.w(TAG, "runAudioLoop: startRecording failed — disabling audio: ${t.message}")
            audioActive = false
            audioPermanentlyDisabled = true
            synchronized(muxerLock) { maybeStartMuxerLocked() }
            return
        }

        val pcmBuffer = ShortArray(audioMinBufferSize / 2)

        while (audioActive) {
            val n = try {
                record.read(pcmBuffer, 0, pcmBuffer.size)
            } catch (t: Throwable) {
                Log.w(TAG, "runAudioLoop: read failed: ${t.message}")
                break
            }
            if (n > 0) {
                // Drop mic audio captured before the first video frame arrives.
                // recordingOriginNanos is set in submitFrame() on the compositor
                // render thread and is read here via volatile.
                val origin = recordingOriginNanos
                if (origin < 0L) continue  // video not started yet — discard

                feedAudioEncoder(pcmBuffer, n, origin)
                drainAudioEncoder(endOfStream = false)
            }
        }

        feedAudioEncoderEos()
        drainAudioEncoder(endOfStream = true)

        try { record.stop() } catch (_: Throwable) {}
    }

    /**
     * Feeds PCM audio into the AAC encoder with PTS relative to [originNanos].
     *
     * [originNanos] is the wall-clock nanoTime of the first composited video
     * frame — all audio PTS are computed as `(now - originNanos)` so both
     * streams share the same t=0 reference in the muxed MP4.
     */
    private fun feedAudioEncoder(pcm: ShortArray, count: Int, originNanos: Long) {
        val enc = audioEncoder ?: return
        var offset = 0
        while (offset < count && audioActive) {
            try {
                val inIdx = enc.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                if (inIdx >= 0) {
                    val buf = enc.getInputBuffer(inIdx) ?: break
                    buf.clear()
                    buf.order(ByteOrder.nativeOrder())
                    val capacityShorts = buf.remaining() / 2
                    val toWrite = minOf(capacityShorts, count - offset)
                    buf.asShortBuffer().put(pcm, offset, toWrite)
                    // PTS relative to the shared recording origin, in microseconds.
                    val ptsUs = ((System.nanoTime() - originNanos) / 1000L).coerceAtLeast(0L)
                    enc.queueInputBuffer(inIdx, 0, toWrite * 2, ptsUs, 0)
                    offset += toWrite
                    drainAudioEncoder(endOfStream = false)
                } else {
                    drainAudioEncoder(endOfStream = false)
                }
            } catch (t: Throwable) {
                Log.w(TAG, "feedAudioEncoder failed: ${t.message}")
                break
            }
        }
    }

    private fun feedAudioEncoderEos() {
        val enc = audioEncoder ?: return
        try {
            val inIdx = enc.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
            if (inIdx >= 0) {
                val origin = recordingOriginNanos
                val ptsUs = if (origin > 0L) ((System.nanoTime() - origin) / 1000L).coerceAtLeast(0L) else 0L
                enc.queueInputBuffer(inIdx, 0, 0, ptsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "feedAudioEncoderEos failed: ${t.message}")
        }
    }

    private fun drainAudioEncoder(endOfStream: Boolean) {
        val enc = audioEncoder ?: return
        val mx = muxer ?: return
        val info = MediaCodec.BufferInfo()
        val deadline = if (endOfStream) System.currentTimeMillis() + EOS_DRAIN_DEADLINE_MS else 0L

        while (true) {
            if (endOfStream && System.currentTimeMillis() > deadline) return
            val outIdx = try {
                enc.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
            } catch (t: Throwable) {
                return
            }
            when {
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return
                }
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    synchronized(muxerLock) {
                        if (audioTrackIndex < 0 && !audioPermanentlyDisabled) {
                            audioTrackIndex = mx.addTrack(enc.outputFormat)
                            audioFormatReady = true
                            maybeStartMuxerLocked()
                        }
                    }
                }
                outIdx >= 0 -> {
                    val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    if (!isConfig && info.size > 0) {
                        val buf = enc.getOutputBuffer(outIdx)
                        if (buf != null) {
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            synchronized(muxerLock) {
                                if (muxerStarted && audioTrackIndex >= 0) {
                                    try {
                                        mx.writeSampleData(audioTrackIndex, buf, info)
                                    } catch (t: Throwable) {
                                        Log.w(TAG, "drainAudioEncoder: writeSampleData failed: ${t.message}")
                                    }
                                } else if (!audioPermanentlyDisabled) {
                                    if (pendingAudioSamples.size < MAX_PENDING_SAMPLES) {
                                        val data = ByteArray(info.size)
                                        buf.get(data)
                                        val copyInfo = MediaCodec.BufferInfo().apply {
                                            set(0, info.size, info.presentationTimeUs, info.flags)
                                        }
                                        pendingAudioSamples.add(PendingSample(data, copyInfo))
                                    }
                                }
                            }
                        }
                    }
                    enc.releaseOutputBuffer(outIdx, false)
                    if (isEos) return
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Cleanup helpers
    // ─────────────────────────────────────────────────────────────────────────

    private fun releaseVideoResources() {
        try { videoEncoder?.stop() } catch (_: Throwable) {}
        try { videoEncoder?.release() } catch (_: Throwable) {}
        videoEncoder = null
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            try {
                EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
                if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
                EGL14.eglTerminate(eglDisplay)
            } catch (_: Throwable) {}
        }
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglContext = EGL14.EGL_NO_CONTEXT
        eglSurface = EGL14.EGL_NO_SURFACE
        try { encoderInputSurface?.release() } catch (_: Throwable) {}
        encoderInputSurface = null
        drainBitmapPoolQuietly()
    }

    private fun releaseVideoEncoderOnly() {
        try { videoEncoder?.stop() } catch (_: Throwable) {}
        try { videoEncoder?.release() } catch (_: Throwable) {}
        videoEncoder = null
        try { encoderInputSurface?.release() } catch (_: Throwable) {}
        encoderInputSurface = null
    }

    private fun releaseAudioResources() {
        try { audioRecord?.release() } catch (_: Throwable) {}
        try { audioEncoder?.stop() } catch (_: Throwable) {}
        try { audioEncoder?.release() } catch (_: Throwable) {}
        audioRecord = null
        audioEncoder = null
    }

    private fun drainBitmapPoolQuietly() {
        while (true) {
            val b = bitmapPool.poll() ?: break
            try { b.recycle() } catch (_: Throwable) {}
        }
        while (true) {
            val b = frameQueue.poll() ?: break
            try { b.recycle() } catch (_: Throwable) {}
        }
    }

    private fun teardownAfterFailedStart() {
        releaseAudioResources()
        releaseVideoResources()
        try { muxer?.release() } catch (_: Throwable) {}
        muxer = null
        synchronized(muxerLock) {
            pendingVideoSamples.clear()
            pendingAudioSamples.clear()
        }
        deleteQuietly(File(tmpPath))
        // Mark as already stopped so a stray stop()/abort() call from the
        // caller's error path is a safe no-op rather than double-releasing.
        stopped.set(true)
    }

    private fun deleteQuietly(f: File) {
        try { if (f.exists()) f.delete() } catch (_: Throwable) {}
    }
}
