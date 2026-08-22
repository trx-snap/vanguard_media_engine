package com.connects.vanguard_media_engine.codec

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Choreographer
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.view.TextureRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Vanguard Android True-DAG Phase 4B1A: Texture playback smoke session.
 *
 * Route: MediaExtractor/MediaCodec -> ImageReader/HardwareBuffer ->
 *        native DAG evaluation -> VulkanBackend render ->
 *        Flutter TextureRegistry Surface.
 */
class AndroidDagTexturePlaybackSmokeSession(
    private val videoPath: String,
    private val frameCount: Int,
    private val textureEntry: TextureRegistry.SurfaceTextureEntry,
) {
    companion object {
        private const val TAG = "DagTexturePlaybackSmoke"
        private const val IMAGE_READER_MAX_IMAGES = 3
        private const val TOTAL_TIMEOUT_MS = 10000L
        private const val LATCH_TIMEOUT_SECONDS = 12L
    }

    private val disposed = AtomicBoolean(false)
    private val imageQueue = LinkedBlockingQueue<Image>(IMAGE_READER_MAX_IMAGES)

    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private var imageReader: ImageReader? = null
    private var flutterSurface: Surface? = null
    private var handlerThread: HandlerThread? = null
    private var handler: Handler? = null
    private var nativeBridge: VanguardNativeBridge? = null
    private var sessionId: String? = null

    private var choreographer: Choreographer? = null
    private var activeFrameCallback: Choreographer.FrameCallback? = null

    private var videoWidth = 0
    private var videoHeight = 0
    private var renderedFrames = 0
    private var inputDone = false
    private var outputDone = false
    private var frameRenderError: String? = null
    private var setupError: String? = null

    /**
     * Executes the smoke playback session, blocking the calling thread until
     * completion, error, EOS, or timeout.
     */
    fun run(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < 29) {
            setupError = "api_below_29"
            return buildResultMap(false)
        }

        val latch = CountDownLatch(1)

        try {
            // 1. Prepare MediaExtractor & find first video track
            val ex = MediaExtractor().also { extractor = it }
            ex.setDataSource(videoPath)
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("video/")) {
                    trackIndex = i
                    format = f
                    break
                }
            }

            if (trackIndex < 0 || format == null) {
                setupError = "no_video_track_found"
                return buildResultMap(false)
            }

            ex.selectTrack(trackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            videoWidth = format.getInteger(MediaFormat.KEY_WIDTH)
            videoHeight = format.getInteger(MediaFormat.KEY_HEIGHT)

            // 2. Start HandlerThread for Choreographer loop & ImageReader
            val ht = HandlerThread("DagTexturePlaybackSmokeLoop").also {
                handlerThread = it
                it.start()
            }
            val h = Handler(ht.looper).also { handler = it }

            // 3. Configure Flutter texture surface buffer size and wrap in Surface
            textureEntry.surfaceTexture().setDefaultBufferSize(videoWidth, videoHeight)
            val surface = Surface(textureEntry.surfaceTexture()).also { flutterSurface = it }

            // 4. Create ImageReader (PRIVATE, GPU_SAMPLED_IMAGE, API 29+)
            val reader = ImageReader.newInstance(
                videoWidth,
                videoHeight,
                ImageFormat.PRIVATE,
                IMAGE_READER_MAX_IMAGES,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            ).also { imageReader = it }

            reader.setOnImageAvailableListener(
                { r ->
                    try {
                        val img = r.acquireNextImage()
                        if (img != null) {
                            if (!imageQueue.offer(img)) {
                                img.close()
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "acquireNextImage failed: $e")
                    }
                },
                h,
            )

            // 5. Configure and start MediaCodec outputting to ImageReader.surface
            val dec = MediaCodec.createDecoderByType(mime).also { codec = it }
            dec.configure(format, reader.surface, null, 0)
            dec.start()

            // 6. Create native session (VulkanBackend + diagnostic DAG)
            val diagnostics = VanguardDiagnostics()
            val bridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            ).also { nativeBridge = it }

            val createResult = bridge.createAndroidDagPhase4B1TexturePlaybackSession(
                surface,
                videoWidth,
                videoHeight,
            )

            if (!createResult.startsWith("status=OK;")) {
                setupError = "session_create_failed;nativeResult=${createResult.take(80)}"
                return buildResultMap(false)
            }

            sessionId = createResult.substringAfter("sessionId=").substringBefore(";").ifEmpty { null }
            if (sessionId == null) {
                setupError = "session_id_parse_failed"
                return buildResultMap(false)
            }

            // 7. Schedule Choreographer vsync loop on HandlerThread
            val deadline = System.currentTimeMillis() + TOTAL_TIMEOUT_MS

            h.post {
                try {
                    val ch = Choreographer.getInstance().also { choreographer = it }
                    val callback = object : Choreographer.FrameCallback {
                        override fun doFrame(frameTimeNanos: Long) {
                            if (disposed.get()) {
                                latch.countDown()
                                return
                            }

                            try {
                                // Feed MediaCodec input buffers
                                while (!inputDone) {
                                    val inIdx = codec?.dequeueInputBuffer(0) ?: -1
                                    if (inIdx < 0) break
                                    val buf = codec?.getInputBuffer(inIdx)
                                    if (buf == null) break
                                    val sampleSize = extractor?.readSampleData(buf, 0) ?: -1
                                    if (sampleSize < 0) {
                                        codec?.queueInputBuffer(
                                            inIdx,
                                            0,
                                            0,
                                            0,
                                            MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                        )
                                        inputDone = true
                                    } else {
                                        val pts = extractor?.sampleTime ?: 0L
                                        codec?.queueInputBuffer(inIdx, 0, sampleSize, pts, 0)
                                        extractor?.advance()
                                    }
                                }

                                // Drain MediaCodec output buffers to ImageReader
                                while (!outputDone && imageQueue.size < 2 && (renderedFrames + imageQueue.size < frameCount)) {
                                    val info = MediaCodec.BufferInfo()
                                    val outIdx = codec?.dequeueOutputBuffer(info, 0) ?: -1
                                    if (outIdx < 0) break

                                    val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                                    val renderable = info.size > 0 && !isEos
                                    if (renderable && (renderedFrames + imageQueue.size < frameCount)) {
                                        codec?.releaseOutputBuffer(outIdx, true)
                                    } else {
                                        codec?.releaseOutputBuffer(outIdx, false)
                                    }

                                    if (isEos) {
                                        outputDone = true
                                    }
                                }

                                // Render at most ONE frame per vsync callback
                                val image: Image? = imageQueue.poll()
                                if (image != null) {
                                    var hwBuf: HardwareBuffer? = null
                                    try {
                                        hwBuf = image.hardwareBuffer
                                        if (hwBuf != null) {
                                            // SyncFence API >= 33 wait <= 1s
                                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                                val fence = image.fence
                                                try {
                                                    if (fence.isValid) {
                                                        fence.await(java.time.Duration.ofMillis(1000))
                                                    }
                                                } catch (e: Exception) {
                                                    Log.w(TAG, "SyncFence exception: $e")
                                                } finally {
                                                    try { fence.close() } catch (_: Throwable) {}
                                                }
                                            }

                                            val sid = sessionId
                                            val nb = nativeBridge
                                            if (sid != null && nb != null) {
                                                val renderStr = nb.renderAndroidDagPhase4B1TexturePlaybackFrame(
                                                    sid,
                                                    hwBuf,
                                                    videoWidth,
                                                    videoHeight,
                                                    image.timestamp / 1000,
                                                    renderedFrames,
                                                )

                                                if (renderStr.startsWith("status=PASS;")) {
                                                    renderedFrames++
                                                } else {
                                                    Log.w(TAG, "renderFrame FAIL at index $renderedFrames: $renderStr")
                                                    frameRenderError = renderStr
                                                }
                                            } else {
                                                frameRenderError = "status=FAIL;reason=session_or_bridge_null"
                                            }
                                        } else {
                                            Log.w(TAG, "hardwareBuffer was null at frame $renderedFrames")
                                        }
                                    } finally {
                                        try { hwBuf?.close() } catch (_: Throwable) {}
                                        try { image.close() } catch (_: Throwable) {}
                                    }
                                }

                                // Check completion/termination conditions
                                val isSuccess = renderedFrames >= frameCount
                                val hasError = frameRenderError != null
                                val isEosComplete = outputDone && imageQueue.isEmpty() && renderedFrames < frameCount
                                val isTimeout = System.currentTimeMillis() > deadline

                                if (isSuccess || hasError || isEosComplete || isTimeout) {
                                    if (isTimeout && !isSuccess && !hasError) {
                                        frameRenderError = "status=FAIL;reason=vsync_loop_timeout"
                                    }
                                    latch.countDown()
                                } else {
                                    choreographer?.postFrameCallback(this)
                                }
                            } catch (t: Throwable) {
                                Log.e(TAG, "Exception in vsync frameCallback", t)
                                frameRenderError = "status=FAIL;reason=callback_exception:${t.javaClass.simpleName}"
                                latch.countDown()
                            }
                        }
                    }
                    activeFrameCallback = callback
                    ch.postFrameCallback(callback)
                } catch (t: Throwable) {
                    Log.e(TAG, "Exception initializing Choreographer callback", t)
                    setupError = "choreographer_init_failed:${t.javaClass.simpleName}"
                    latch.countDown()
                }
            }

            // Wait for completion or timeout
            val finished = latch.await(LATCH_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            if (!finished && frameRenderError == null && renderedFrames < frameCount) {
                frameRenderError = "status=FAIL;reason=latch_timeout"
            }

            val pass = renderedFrames == frameCount && frameRenderError == null && setupError == null
            return buildResultMap(pass)

        } catch (t: Throwable) {
            Log.e(TAG, "Phase 4B1A session run error", t)
            setupError = "exception:${t.javaClass.simpleName}"
            return buildResultMap(false)
        }
    }

    private fun buildResultMap(pass: Boolean): Map<String, Any?> {
        val raw = if (pass) {
            "status=PASS;renderedFrames=$renderedFrames;frameCount=$frameCount;width=$videoWidth;height=$videoHeight;textureId=${textureEntry.id()}"
        } else {
            "status=FAIL;renderedFrames=$renderedFrames;frameCount=$frameCount;width=$videoWidth;height=$videoHeight;textureId=${textureEntry.id()};error=${frameRenderError ?: setupError ?: "unknown"}"
        }

        return mapOf(
            "pass" to pass,
            "textureId" to textureEntry.id(),
            "renderedFrames" to renderedFrames,
            "frameCount" to frameCount,
            "width" to videoWidth,
            "height" to videoHeight,
            "raw" to raw,
        )
    }

    /**
     * Disposes the session resources.
     * Order: cancel callback, destroy native session, codec stop/release,
     * ImageReader close, output Surface release, extractor release,
     * handlerThread quitSafely.
     *
     * Note: Do NOT release TextureRegistry entry here; plugin releases it.
     */
    fun dispose() {
        if (!disposed.compareAndSet(false, true)) return

        // 1. Cancel callback
        try {
            val h = handler
            val ch = choreographer
            val cb = activeFrameCallback
            if (cb != null) {
                if (h != null) {
                    h.post {
                        try {
                            choreographer?.removeFrameCallback(cb)
                        } catch (_: Throwable) {}
                    }
                } else if (ch != null) {
                    try {
                        ch.removeFrameCallback(cb)
                    } catch (_: Throwable) {}
                }
            }
        } catch (_: Throwable) {}

        // 2. Destroy native session
        val bridge = nativeBridge
        val sid = sessionId
        if (bridge != null && sid != null) {
            try {
                bridge.destroyAndroidDagPhase4B1TexturePlaybackSession(sid)
            } catch (_: Throwable) {}
        }

        // 3. Codec stop / release
        try { codec?.stop() } catch (_: Throwable) {}
        try { codec?.release() } catch (_: Throwable) {}

        // 4. Drain & close queued images
        while (true) {
            val img = imageQueue.poll() ?: break
            try { img.close() } catch (_: Throwable) {}
        }

        // 5. ImageReader close
        try { imageReader?.close() } catch (_: Throwable) {}

        // 6. Output Surface release
        try { flutterSurface?.release() } catch (_: Throwable) {}

        // 7. Extractor release
        try { extractor?.release() } catch (_: Throwable) {}

        // 8. HandlerThread quitSafely
        try { handlerThread?.quitSafely() } catch (_: Throwable) {}
    }
}
