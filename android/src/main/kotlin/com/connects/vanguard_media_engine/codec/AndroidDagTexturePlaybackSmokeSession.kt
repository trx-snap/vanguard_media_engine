package com.connects.vanguard_media_engine.codec

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaExtractor
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
 *
 * Phase 4B2C rotation correction: source inspection is delegated to
 * AndroidDagSourceInspector, which provides rotationDegrees.  Display
 * dimensions are swapped for 90/270 clockwise rotation.  The Flutter
 * surface buffer size and native session use display dimensions; the
 * ImageReader/MediaCodec decoder path uses raw (source) dimensions.
 * Rendering uses the generation-aware JNI call which carries rotationDegrees.
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

    // Source metadata (raw)
    private var videoWidth = 0
    private var videoHeight = 0
    private var durationUs = 0L
    private var rotationDegrees = 0

    // Display (post-rotation) dimensions
    private var displayWidth = 0
    private var displayHeight = 0

    // Generation tracking (Phase 4B2C)
    private var currentGenerationId = 0L

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
        // 1. Delegate all source inspection to the shared inspector.
        //    The inspector performs file preflight, API check, extractor creation,
        //    track selection, and rotation metadata normalisation.
        val inspection = AndroidDagSourceInspector().inspect(videoPath)
        if (!inspection.pass) {
            setupError = "source_inspection_failed;reason=${inspection.failureReason}"
            return buildResultMap(false)
        }

        // On success the inspector transfers extractor ownership to this session.
        // Store it as a class field so dispose() can always release it,
        // regardless of which early-return path is taken below.
        extractor = inspection.extractor!!

        // Populate session metadata from inspection result.
        videoWidth = inspection.width
        videoHeight = inspection.height
        durationUs = inspection.durationUs
        rotationDegrees = inspection.rotationDegrees

        // Phase 4B2C: compute display dimensions — swap for 90/270 clockwise rotation.
        val swapDims = rotationDegrees == 90 || rotationDegrees == 270
        displayWidth  = if (swapDims) videoHeight else videoWidth
        displayHeight = if (swapDims) videoWidth  else videoHeight

        val mime   = inspection.mime
        val format = inspection.format!!

        val latch = CountDownLatch(1)

        try {
            // 2. Start HandlerThread for Choreographer loop & ImageReader
            val ht = HandlerThread("DagTexturePlaybackSmokeLoop").also {
                handlerThread = it
                it.start()
            }
            val h = Handler(ht.looper).also { handler = it }

            // 3. Configure Flutter texture surface buffer size using DISPLAY dimensions
            //    (post-rotation) and wrap in Surface.
            textureEntry.surfaceTexture().setDefaultBufferSize(displayWidth, displayHeight)
            val surface = Surface(textureEntry.surfaceTexture()).also { flutterSurface = it }

            // 4. Create ImageReader using RAW (source) dimensions — the decoder
            //    decodes at native resolution; the rotation is applied in the
            //    native render stage.
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
            //    using DISPLAY dimensions so the Vulkan surface is correctly sized.
            val diagnostics = VanguardDiagnostics()
            val bridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            ).also { nativeBridge = it }

            val createResult = bridge.createAndroidDagPhase4B1TexturePlaybackSession(
                surface,
                displayWidth,
                displayHeight,
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

            // 7. Bump generation (Phase 4B2C requirement): establishes the initial
            //    generation id that all render calls must carry.  Fail closed if the
            //    bump itself or its id parse fails.
            val bumpRes = bridge.bumpAndroidDagPhase4B1TexturePlaybackGeneration(sessionId!!)
            if (!bumpRes.startsWith("status=OK;")) {
                setupError = "initial_generation_bump_failed;bumpResult=${bumpRes.take(80)}"
                return buildResultMap(false)
            }
            val genStr   = bumpRes.substringAfter("generationId=").substringBefore(";")
            val parsedGen = genStr.toLongOrNull()
            if (parsedGen == null || parsedGen <= 0L) {
                setupError = "initial_generation_parse_failed;bumpResult=${bumpRes.take(80)}"
                return buildResultMap(false)
            }
            currentGenerationId = parsedGen

            // 8. Schedule Choreographer vsync loop on HandlerThread
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
                                                // Phase 4B2C: generation-aware render call carrying
                                                // display dimensions and rotation metadata so the
                                                // native Vulkan stage applies the correct transform.
                                                val renderStr = nb.renderAndroidDagPhase4B1TexturePlaybackFrameForGeneration(
                                                    sid,
                                                    hwBuf,
                                                    displayWidth,
                                                    displayHeight,
                                                    image.timestamp / 1000,
                                                    renderedFrames,
                                                    currentGenerationId,
                                                    rotationDegrees,
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
            "status=PASS;renderedFrames=$renderedFrames;frameCount=$frameCount;" +
                "sourceWidth=$videoWidth;sourceHeight=$videoHeight;" +
                "displayWidth=$displayWidth;displayHeight=$displayHeight;" +
                "rotationDegrees=$rotationDegrees;durationUs=$durationUs;" +
                "textureId=${textureEntry.id()}"
        } else {
            "status=FAIL;renderedFrames=$renderedFrames;frameCount=$frameCount;" +
                "sourceWidth=$videoWidth;sourceHeight=$videoHeight;" +
                "displayWidth=$displayWidth;displayHeight=$displayHeight;" +
                "rotationDegrees=$rotationDegrees;durationUs=$durationUs;" +
                "textureId=${textureEntry.id()};" +
                "error=${frameRenderError ?: setupError ?: "unknown"}"
        }

        return mapOf(
            "pass"            to pass,
            "textureId"       to textureEntry.id(),
            "renderedFrames"  to renderedFrames,
            "frameCount"      to frameCount,
            // width/height now reflect the display (output) dimensions.
            "width"           to displayWidth,
            "height"          to displayHeight,
            "sourceWidth"     to videoWidth,
            "sourceHeight"    to videoHeight,
            "rotationDegrees" to rotationDegrees,
            "displayWidth"    to displayWidth,
            "displayHeight"   to displayHeight,
            "durationUs"      to durationUs,
            "raw"             to raw,
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
