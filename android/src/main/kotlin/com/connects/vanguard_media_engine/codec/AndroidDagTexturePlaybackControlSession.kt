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
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Vanguard Android True-DAG Phase 4B1B: Diagnostic physical playback control session.
 *
 * Route: MediaExtractor/MediaCodec -> ImageReader/HardwareBuffer ->
 *        native DAG generation-aware evaluation -> Vulkan render ->
 *        Flutter TextureRegistry Surface.
 */
class AndroidDagTexturePlaybackControlSession(
    private val videoPath: String,
    private val surfaceProducer: TextureRegistry.SurfaceProducer,
) {
    companion object {
        private const val TAG = "DagTexturePlaybackCtrl"
        private const val IMAGE_READER_MAX_IMAGES = 3
    }

    private val disposed = AtomicBoolean(false)
    private val imageQueue = LinkedBlockingQueue<Image>(IMAGE_READER_MAX_IMAGES)

    @Volatile
    var state: AndroidDagPlaybackState = AndroidDagPlaybackState.Idle
        private set

    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private var imageReader: ImageReader? = null
    private var flutterSurface: Surface? = null
    private var handlerThread: HandlerThread? = null
    private var handler: Handler? = null
    private var nativeBridge: VanguardNativeBridge? = null
    private var sessionId: String? = null
    private var currentGenerationId: Long = 0L

    private var choreographer: Choreographer? = null
    private var activeFrameCallback: Choreographer.FrameCallback? = null
    private var pendingPlayCallback: ((Map<String, Any?>) -> Unit)? = null
    private var targetFrameCount: Int? = null

    private var videoWidth = 0
    private var videoHeight = 0
    private var durationUs = 0L
    private var renderedFrames = 0
    private var lastRenderedPtsUs = 0L
    private var inputDone = false
    private var outputDone = false
    private var frameRenderError: String? = null

    /**
     * Initializes resources and prepares the playback session on the dedicated HandlerThread.
     */
    fun prepare(onResult: (Map<String, Any?>) -> Unit) {
        // Belt-and-suspenders: check file existence synchronously before touching
        // MediaExtractor. setDataSource() can hang (rather than throw) on some
        // Android versions when given a non-existent or unreadable path, which would
        // prevent onResult from ever being called and hang the MethodChannel reply.
        val fileCheck = java.io.File(videoPath)
        if (!fileCheck.exists() || !fileCheck.canRead()) {
            state = AndroidDagPlaybackState.Failed
            onResult(mapOf(
                "pass" to false,
                "state" to state.name,
                "raw" to "status=FAIL;reason=file_not_found_or_not_readable",
            ))
            return
        }

        if (Build.VERSION.SDK_INT < 29) {
            state = AndroidDagPlaybackState.Failed
            onResult(mapOf(
                "pass" to false,
                "state" to state.name,
                "raw" to "status=FAIL;reason=api_below_29",
            ))
            return
        }

        try {
            // 1. Prepare MediaExtractor & find video track
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
                cleanupResources(AndroidDagPlaybackState.Failed)
                onResult(mapOf(
                    "pass" to false,
                    "state" to state.name,
                    "raw" to "status=FAIL;reason=no_video_track_found",
                ))
                return
            }

            ex.selectTrack(trackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            videoWidth = format.getInteger(MediaFormat.KEY_WIDTH)
            videoHeight = format.getInteger(MediaFormat.KEY_HEIGHT)
            durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
                format.getLong(MediaFormat.KEY_DURATION)
            } else {
                0L
            }

            // 2. Start HandlerThread for Choreographer loop & ImageReader
            val ht = HandlerThread("DagPlaybackControlLoop_${surfaceProducer.id()}").also {
                handlerThread = it
                it.start()
            }
            val h = Handler(ht.looper).also { handler = it }

            h.post {
                try {
                    // 3. Configure Flutter texture buffer size and obtain Surface
                    surfaceProducer.setSize(videoWidth, videoHeight)
                    val surface = surfaceProducer.getSurface().also { flutterSurface = it }

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

                    // 5. Configure and start MediaCodec
                    val dec = MediaCodec.createDecoderByType(mime).also { codec = it }
                    dec.configure(format, reader.surface, null, 0)
                    dec.start()

                    // 6. Create native session (VulkanBackend + DAG)
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
                        cleanupResources(AndroidDagPlaybackState.Failed)
                        onResult(mapOf(
                            "pass" to false,
                            "state" to state.name,
                            "raw" to "status=FAIL;reason=native_session_create_failed;$createResult",
                        ))
                        return@post
                    }

                    sessionId = createResult.substringAfter("sessionId=").substringBefore(";").ifEmpty { null }
                    if (sessionId == null) {
                        cleanupResources(AndroidDagPlaybackState.Failed)
                        onResult(mapOf(
                            "pass" to false,
                            "state" to state.name,
                            "raw" to "status=FAIL;reason=session_id_parse_failed",
                        ))
                        return@post
                    }

                    // Initial generation bump
                    val bumpRes = bridge.bumpAndroidDagPhase4B1TexturePlaybackGeneration(sessionId!!)
                    if (!bumpRes.startsWith("status=OK;")) {
                        cleanupResources(AndroidDagPlaybackState.Failed)
                        onResult(mapOf(
                            "pass" to false,
                            "state" to state.name,
                            "raw" to "status=FAIL;reason=initial_generation_bump_failed;$bumpRes",
                        ))
                        return@post
                    }
                    val genStr = bumpRes.substringAfter("generationId=").substringBefore(";")
                    val parsedGen = genStr.toLongOrNull()
                    if (parsedGen == null || parsedGen <= 0L) {
                        cleanupResources(AndroidDagPlaybackState.Failed)
                        onResult(mapOf(
                            "pass" to false,
                            "state" to state.name,
                            "raw" to "status=FAIL;reason=initial_generation_parse_failed;$bumpRes",
                        ))
                        return@post
                    }
                    currentGenerationId = parsedGen

                    choreographer = Choreographer.getInstance()
                    state = AndroidDagPlaybackState.Prepared

                    onResult(mapOf(
                        "pass" to true,
                        "textureId" to surfaceProducer.id(),
                        "width" to videoWidth,
                        "height" to videoHeight,
                        "durationUs" to durationUs,
                        "state" to state.name,
                        "sessionId" to sessionId,
                        "generationId" to currentGenerationId,
                        "raw" to createResult,
                    ))
                } catch (t: Throwable) {
                    Log.e(TAG, "Error in session prepare", t)
                    cleanupResources(AndroidDagPlaybackState.Failed)
                    onResult(mapOf(
                        "pass" to false,
                        "state" to state.name,
                        "raw" to "status=FAIL;reason=prepare_exception:${t.javaClass.simpleName}",
                    ))
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "Error initiating session prepare", t)
            cleanupResources(AndroidDagPlaybackState.Failed)
            onResult(mapOf(
                "pass" to false,
                "state" to state.name,
                "raw" to "status=FAIL;reason=prepare_init_exception:${t.javaClass.simpleName}",
            ))
        }
    }

    /**
     * Starts or resumes playback, rendering at most one frame per vsync callback.
     * If [frameCount] is non-null, [onResult] is invoked after [frameCount] frames render.
     * Otherwise [onResult] returns immediately with state=Playing.
     */
    fun play(frameCount: Int?, onResult: (Map<String, Any?>) -> Unit) {
        val h = handler
        if (h == null || disposed.get()) {
            onResult(mapOf(
                "pass" to false,
                "state" to state.name,
                "raw" to "status=FAIL;reason=session_disposed_or_uninitialized",
            ))
            return
        }

        h.post {
            if (disposed.get()) {
                onResult(mapOf("pass" to false, "state" to state.name, "raw" to "status=FAIL;reason=disposed"))
                return@post
            }

            state = AndroidDagPlaybackState.Playing
            if (frameCount != null && frameCount > 0) {
                targetFrameCount = renderedFrames + frameCount
                pendingPlayCallback = onResult
            } else {
                targetFrameCount = null
                onResult(mapOf(
                    "pass" to true,
                    "state" to state.name,
                    "renderedFrames" to renderedFrames,
                    "lastPtsUs" to lastRenderedPtsUs,
                    "raw" to "status=OK;state=Playing;renderedFrames=$renderedFrames",
                ))
            }

            if (activeFrameCallback == null) {
                val callback = object : Choreographer.FrameCallback {
                    override fun doFrame(frameTimeNanos: Long) {
                        if (disposed.get() || state != AndroidDagPlaybackState.Playing) {
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
                            while (!outputDone && imageQueue.size < 2) {
                                val info = MediaCodec.BufferInfo()
                                val outIdx = codec?.dequeueOutputBuffer(info, 0) ?: -1
                                if (outIdx < 0) break

                                val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                                val renderable = info.size > 0 && !isEos
                                codec?.releaseOutputBuffer(outIdx, renderable)

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
                                            val ptsUs = image.timestamp / 1000L
                                            lastRenderedPtsUs = ptsUs
                                            val renderStr = nb.renderAndroidDagPhase4B1TexturePlaybackFrameForGeneration(
                                                sid,
                                                hwBuf,
                                                videoWidth,
                                                videoHeight,
                                                ptsUs,
                                                renderedFrames,
                                                currentGenerationId,
                                            )

                                            if (renderStr.startsWith("status=PASS;")) {
                                                renderedFrames++
                                            } else {
                                                Log.w(TAG, "renderFrame FAIL at index $renderedFrames: $renderStr")
                                                frameRenderError = renderStr
                                            }
                                        }
                                    }
                                } finally {
                                    try { hwBuf?.close() } catch (_: Throwable) {}
                                    try { image.close() } catch (_: Throwable) {}
                                }
                            }

                            // Check completion/termination
                            val target = targetFrameCount
                            if (target != null && renderedFrames >= target) {
                                activeFrameCallback = null
                                val cb = pendingPlayCallback
                                pendingPlayCallback = null
                                targetFrameCount = null
                                cb?.invoke(mapOf(
                                    "pass" to true,
                                    "state" to state.name,
                                    "renderedFrames" to renderedFrames,
                                    "lastPtsUs" to lastRenderedPtsUs,
                                    "raw" to "status=OK;target_reached;renderedFrames=$renderedFrames",
                                ))
                            } else if (outputDone && imageQueue.isEmpty()) {
                                state = AndroidDagPlaybackState.Completed
                                activeFrameCallback = null
                                val cb = pendingPlayCallback
                                pendingPlayCallback = null
                                targetFrameCount = null
                                val isPass = target == null || renderedFrames >= target
                                val raw = if (isPass) {
                                    "status=OK;completed=true"
                                } else {
                                    "status=FAIL;reason=eos_before_target;renderedFrames=$renderedFrames;targetFrameCount=$target"
                                }
                                cb?.invoke(mapOf(
                                    "pass" to isPass,
                                    "state" to state.name,
                                    "renderedFrames" to renderedFrames,
                                    "lastPtsUs" to lastRenderedPtsUs,
                                    "raw" to raw,
                                ))
                            } else if (frameRenderError != null) {
                                state = AndroidDagPlaybackState.Failed
                                activeFrameCallback = null
                                val cb = pendingPlayCallback
                                pendingPlayCallback = null
                                cb?.invoke(mapOf(
                                    "pass" to false,
                                    "state" to state.name,
                                    "renderedFrames" to renderedFrames,
                                    "raw" to frameRenderError!!,
                                ))
                            } else {
                                choreographer?.postFrameCallback(this)
                            }
                        } catch (t: Throwable) {
                            Log.e(TAG, "Exception in vsync frameCallback", t)
                            state = AndroidDagPlaybackState.Failed
                            activeFrameCallback = null
                            val cb = pendingPlayCallback
                            pendingPlayCallback = null
                            cb?.invoke(mapOf(
                                "pass" to false,
                                "state" to state.name,
                                "raw" to "status=FAIL;reason=callback_exception:${t.javaClass.simpleName}",
                            ))
                        }
                    }
                }
                activeFrameCallback = callback
                choreographer?.postFrameCallback(callback)
            }
        }
    }

    /**
     * Pauses playback, removing active Choreographer callback and setting state=Paused.
     */
    fun pause(onResult: (Map<String, Any?>) -> Unit) {
        val h = handler
        if (h == null || disposed.get()) {
            onResult(mapOf(
                "pass" to false,
                "state" to state.name,
                "raw" to "status=FAIL;reason=session_disposed_or_uninitialized",
            ))
            return
        }

        h.post {
            val cb = activeFrameCallback
            if (cb != null) {
                choreographer?.removeFrameCallback(cb)
                activeFrameCallback = null
            }

            val pendingCb = pendingPlayCallback
            pendingPlayCallback = null
            targetFrameCount = null

            if (state != AndroidDagPlaybackState.Disposed && state != AndroidDagPlaybackState.Failed) {
                state = AndroidDagPlaybackState.Paused
            }

            val res = mapOf(
                "pass" to true,
                "state" to state.name,
                "renderedFrames" to renderedFrames,
                "lastPtsUs" to lastRenderedPtsUs,
                "raw" to "status=OK;state=Paused;renderedFrames=$renderedFrames",
            )

            pendingCb?.invoke(res)
            onResult(res)
        }
    }

    /**
     * Seeks to [targetPtsUs] with preroll decode from sync keyframe, evaluates DAG for the bumped generation,
     * and renders the frame at or after [targetPtsUs].
     * If [resumeAfterSeek] is false, holds Paused state with seek frame visible on texture.
     */
    fun seek(targetPtsUs: Long, resumeAfterSeek: Boolean, onResult: (Map<String, Any?>) -> Unit) {
        val h = handler
        if (h == null || disposed.get()) {
            onResult(mapOf(
                "pass" to false,
                "state" to state.name,
                "raw" to "status=FAIL;reason=session_disposed_or_uninitialized",
            ))
            return
        }

        h.post {
            try {
                // a. Stop / remove frame callback
                val activeCb = activeFrameCallback
                if (activeCb != null) {
                    choreographer?.removeFrameCallback(activeCb)
                    activeFrameCallback = null
                }
                pendingPlayCallback?.invoke(mapOf("pass" to false, "raw" to "status=CANCELLED;reason=seek_interrupted"))
                pendingPlayCallback = null
                targetFrameCount = null

                state = AndroidDagPlaybackState.Seeking

                // b. Drain/close queued app-held Images
                while (true) {
                    val img = imageQueue.poll() ?: break
                    try { img.close() } catch (_: Throwable) {}
                }

                // c. Codec flush
                codec?.flush()

                // d. Reset input/output and drain any lingering images
                inputDone = false
                outputDone = false
                frameRenderError = null
                while (true) {
                    val img = imageQueue.poll() ?: break
                    try { img.close() } catch (_: Throwable) {}
                }

                // e. Extractor seek to previous sync keyframe
                extractor?.seekTo(targetPtsUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

                // f. Native bump generation
                val sid = sessionId
                val nb = nativeBridge
                if (sid == null || nb == null) {
                    state = AndroidDagPlaybackState.Failed
                    onResult(mapOf("pass" to false, "state" to state.name, "raw" to "status=FAIL;reason=session_or_bridge_null"))
                    return@post
                }

                val bumpRes = nb.bumpAndroidDagPhase4B1TexturePlaybackGeneration(sid)
                if (!bumpRes.startsWith("status=OK;")) {
                    state = AndroidDagPlaybackState.Failed
                    onResult(mapOf("pass" to false, "state" to state.name, "raw" to "status=FAIL;reason=bump_failed;$bumpRes"))
                    return@post
                }
                val genStr = bumpRes.substringAfter("generationId=").substringBefore(";")
                currentGenerationId = genStr.toLongOrNull() ?: (currentGenerationId + 1)

                // g & h. Preroll decode and render target frame
                var seekRenderedPtsUs = -1L
                var seekSuccess = false
                var seekError: String? = null
                val seekDeadline = System.currentTimeMillis() + 8000L

                while (System.currentTimeMillis() < seekDeadline && !seekSuccess && seekError == null) {
                    // Feed input
                    if (!inputDone) {
                        val inIdx = codec?.dequeueInputBuffer(10000) ?: -1
                        if (inIdx >= 0) {
                            val buf = codec?.getInputBuffer(inIdx)
                            if (buf != null) {
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
                        }
                    }

                    // Dequeue output
                    val info = MediaCodec.BufferInfo()
                    val outIdx = codec?.dequeueOutputBuffer(info, 10000) ?: -1
                    if (outIdx >= 0) {
                        val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        val ptsUs = info.presentationTimeUs

                        if (isEos) {
                            outputDone = true
                            codec?.releaseOutputBuffer(outIdx, false)
                            if (!seekSuccess) {
                                seekError = "eos_reached_before_seek_target"
                            }
                            break
                        }

                        if (targetPtsUs > 0 && ptsUs < targetPtsUs) {
                            // Preroll frame: release without rendering to surface
                            codec?.releaseOutputBuffer(outIdx, false)
                        } else {
                            // Target frame reached: release with render=true
                            codec?.releaseOutputBuffer(outIdx, true)

                            // Wait for ImageReader
                            var image: Image? = null
                            val pollDeadline = System.currentTimeMillis() + 2000L
                            while (System.currentTimeMillis() < pollDeadline && image == null) {
                                image = try {
                                    imageReader?.acquireLatestImage()
                                        ?: imageReader?.acquireNextImage()
                                        ?: imageQueue.poll(20, TimeUnit.MILLISECONDS)
                                } catch (_: Throwable) {
                                    imageQueue.poll(20, TimeUnit.MILLISECONDS)
                                }
                                if (image == null) {
                                    try { Thread.sleep(10) } catch (_: Throwable) {}
                                }
                            }

                            if (image == null) {
                                seekError = "image_reader_timeout_on_seek_frame"
                                break
                            }

                            var hwBuf: HardwareBuffer? = null
                            try {
                                hwBuf = image.hardwareBuffer
                                if (hwBuf == null) {
                                    seekError = "hardware_buffer_null_on_seek"
                                    break
                                }

                                // Wait SyncFence API >= 33
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                    val fence = image.fence
                                    try {
                                        if (fence.isValid) {
                                            fence.await(java.time.Duration.ofMillis(1000))
                                        }
                                    } catch (e: Exception) {
                                        Log.w(TAG, "SyncFence await exception on seek: $e")
                                    } finally {
                                        try { fence.close() } catch (_: Throwable) {}
                                    }
                                }

                                val imgPtsUs = image.timestamp / 1000L
                                val framePts = if (imgPtsUs > 0) imgPtsUs else ptsUs

                                val renderStr = nb.renderAndroidDagPhase4B1TexturePlaybackFrameForGeneration(
                                    sid,
                                    hwBuf,
                                    videoWidth,
                                    videoHeight,
                                    framePts,
                                    renderedFrames,
                                    currentGenerationId,
                                )

                                if (renderStr.startsWith("status=PASS;")) {
                                    renderedFrames++
                                    lastRenderedPtsUs = framePts
                                    seekRenderedPtsUs = framePts
                                    seekSuccess = true
                                } else {
                                    seekError = "render_failed_on_seek;$renderStr"
                                }
                            } finally {
                                try { hwBuf?.close() } catch (_: Throwable) {}
                                try { image.close() } catch (_: Throwable) {}
                            }
                            break
                        }
                    }
                }

                // j. Resume or hold Paused
                if (seekSuccess) {
                    if (resumeAfterSeek) {
                        state = AndroidDagPlaybackState.Playing
                        play(null) { /* continuous */ }
                    } else {
                        state = AndroidDagPlaybackState.Paused
                    }

                    onResult(mapOf(
                        "pass" to true,
                        "state" to state.name,
                        "seekTargetUs" to targetPtsUs,
                        "seekRenderedPtsUs" to seekRenderedPtsUs,
                        "generationId" to currentGenerationId,
                        "renderedFrames" to renderedFrames,
                        "raw" to "status=OK;state=${state.name};seekTargetUs=$targetPtsUs;seekRenderedPtsUs=$seekRenderedPtsUs;generationId=$currentGenerationId",
                    ))
                } else {
                    state = AndroidDagPlaybackState.Failed
                    onResult(mapOf(
                        "pass" to false,
                        "state" to state.name,
                        "seekTargetUs" to targetPtsUs,
                        "seekRenderedPtsUs" to seekRenderedPtsUs,
                        "raw" to "status=FAIL;reason=${seekError ?: "seek_timeout"}",
                    ))
                }
            } catch (t: Throwable) {
                Log.e(TAG, "Exception during seek", t)
                state = AndroidDagPlaybackState.Failed
                onResult(mapOf(
                    "pass" to false,
                    "state" to state.name,
                    "raw" to "status=FAIL;reason=seek_exception:${t.javaClass.simpleName}",
                ))
            }
        }
    }

    /**
     * Tears down all partially- or fully-allocated resources in strict order.
     * Safe to call from any state; each step is individually guarded.
     * @param targetState the [AndroidDagPlaybackState] to assign after cleanup.
     * @param cancelPendingPlay when true, the pending play callback is invoked with CANCELLED.
     */
    private fun cleanupResources(
        targetState: AndroidDagPlaybackState,
        cancelPendingPlay: Boolean = true,
    ) {
        // 1. Remove active Choreographer callback
        val cb = activeFrameCallback
        if (cb != null) {
            try { choreographer?.removeFrameCallback(cb) } catch (_: Throwable) {}
            activeFrameCallback = null
        }
        // 2. Invoke and clear pending play callback only when requested
        if (cancelPendingPlay) {
            pendingPlayCallback?.invoke(mapOf("pass" to false, "raw" to "status=CANCELLED;reason=session_disposed"))
            pendingPlayCallback = null
        }
        // 3. Destroy native session
        val sid = sessionId
        val bridge = nativeBridge
        if (sid != null && bridge != null) {
            try { bridge.destroyAndroidDagPhase4B1TexturePlaybackSession(sid) } catch (_: Throwable) {}
        }
        // 4. Stop / release MediaCodec
        try { codec?.stop() } catch (_: Throwable) {}
        try { codec?.release() } catch (_: Throwable) {}
        // 5. Drain and close every queued Image
        while (true) {
            val img = imageQueue.poll() ?: break
            try { img.close() } catch (_: Throwable) {}
        }
        // 6. Close ImageReader
        try { imageReader?.close() } catch (_: Throwable) {}
        // 7. Clear Flutter Surface reference only; SurfaceProducer owns the surface
        flutterSurface = null
        // 8. Release MediaExtractor
        try { extractor?.release() } catch (_: Throwable) {}
        // 9. Quit HandlerThread safely
        try { handlerThread?.quitSafely() } catch (_: Throwable) {}
        // 10. Null resource references
        codec = null
        imageReader = null
        extractor = null
        handler = null
        handlerThread = null
        nativeBridge = null
        sessionId = null
        activeFrameCallback = null
        choreographer = null
        state = targetState
    }

    /**
     * Disposes session resources idempotently.
     */
    fun dispose(onResult: ((Map<String, Any?>) -> Unit)? = null) {
        if (!disposed.compareAndSet(false, true)) {
            onResult?.invoke(mapOf(
                "pass" to true,
                "state" to "Disposed",
                "raw" to "status=OK;already_disposed",
            ))
            return
        }

        val h = handler
        val doCleanup = {
            cleanupResources(AndroidDagPlaybackState.Disposed)
            onResult?.invoke(mapOf(
                "pass" to true,
                "state" to state.name,
                "renderedFrames" to renderedFrames,
                "raw" to "status=OK;disposed=true",
            ))
        }

        if (h != null) {
            h.post { doCleanup() }
        } else {
            doCleanup()
        }
    }
}
