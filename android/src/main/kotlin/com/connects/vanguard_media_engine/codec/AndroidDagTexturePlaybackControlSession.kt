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

    /** Set atomically the moment onSurfaceCleanup fires; cleared on restore. */
    private val surfaceLostFlag = AtomicBoolean(false)

    private val imageQueue = LinkedBlockingQueue<Image>(IMAGE_READER_MAX_IMAGES)

    @Volatile
    var state: AndroidDagPlaybackState = AndroidDagPlaybackState.Idle
        private set

    /** Last diagnostic reason recorded after a failed surface restore. */
    @Volatile
    var lastRestoreFailureReason: String? = null
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

    /** Registered with [surfaceProducer] to receive availability/cleanup callbacks. */
    private var lifecycleAdapter: AndroidDagSurfaceProducerLifecycleAdapter? = null

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
                    // 3. Register surface lifecycle callback BEFORE first getSurface()
                    val adapter = AndroidDagSurfaceProducerLifecycleAdapter(
                        onAvailable = { handleSurfaceAvailable() },
                        onCleanup   = { handleSurfaceCleanup() },
                    ).also { lifecycleAdapter = it }
                    @Suppress("DEPRECATION")
                    surfaceProducer.setCallback(adapter)

                    // Configure Flutter texture buffer size and obtain Surface
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

            // Reject play while surface is lost — caller must wait for onSurfaceAvailable restore.
            if (surfaceLostFlag.get() || state == AndroidDagPlaybackState.SurfaceLost) {
                onResult(mapOf(
                    "pass" to false,
                    "state" to state.name,
                    "raw" to "status=FAIL;reason=surface_lost",
                ))
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
                        // Stop the loop immediately if surface has been lost or session is no longer playing.
                        if (disposed.get() || surfaceLostFlag.get() || state != AndroidDagPlaybackState.Playing) {
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
                // Reject seek while surface is lost.
                if (surfaceLostFlag.get() || state == AndroidDagPlaybackState.SurfaceLost) {
                    onResult(mapOf(
                        "pass" to false,
                        "state" to state.name,
                        "raw" to "status=FAIL;reason=surface_lost",
                    ))
                    return@post
                }

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

                // g & h. Preroll decode and render — delegated to AndroidDagSeekPrerollEngine
                val ex = extractor
                val dec = codec
                val reader = imageReader
                if (ex == null || dec == null || reader == null) {
                    state = AndroidDagPlaybackState.Failed
                    onResult(mapOf("pass" to false, "state" to state.name, "raw" to "status=FAIL;reason=session_or_bridge_null"))
                    return@post
                }

                val engineResult = AndroidDagSeekPrerollEngine().run(
                    extractor = ex,
                    codec = dec,
                    imageReader = reader,
                    imageQueue = imageQueue,
                    bridge = nb,
                    sessionId = sid,
                    videoWidth = videoWidth,
                    videoHeight = videoHeight,
                    seekTargetUs = targetPtsUs,
                    currentGenerationId = currentGenerationId,
                    renderedFramesBefore = renderedFrames,
                    deadlineMs = System.currentTimeMillis() + 8000L,
                    shouldCancel = { surfaceLostFlag.get() || disposed.get() },
                )

                // Apply engine result back to session state
                renderedFrames = engineResult.renderedFrames
                if (engineResult.lastRenderedPtsUs >= 0) {
                    lastRenderedPtsUs = engineResult.lastRenderedPtsUs
                }

                // j. Resume or hold Paused
                if (engineResult.pass) {
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
                        "seekRenderedPtsUs" to engineResult.seekRenderedPtsUs,
                        "generationId" to engineResult.generationId,
                        "renderedFrames" to renderedFrames,
                        "raw" to "status=OK;state=${state.name};seekTargetUs=$targetPtsUs;seekRenderedPtsUs=${engineResult.seekRenderedPtsUs};generationId=${engineResult.generationId}",
                    ))
                } else {
                    state = AndroidDagPlaybackState.Failed
                    onResult(mapOf(
                        "pass" to false,
                        "state" to state.name,
                        "seekTargetUs" to targetPtsUs,
                        "seekRenderedPtsUs" to engineResult.seekRenderedPtsUs,
                        "raw" to "status=FAIL;reason=${engineResult.failureReason}",
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
        releaseJavaResources: Boolean = true,
    ) {
        // 1. Remove active Choreographer callback
        val cb = activeFrameCallback
        if (cb != null) {
            try { choreographer?.removeFrameCallback(cb) } catch (_: Throwable) {}
            activeFrameCallback = null
        }
        // 2. Invoke and clear pending play callback only when requested
        if (cancelPendingPlay) {
            val reason = if (targetState == AndroidDagPlaybackState.SurfaceLost) "surface_lost" else "session_disposed"
            pendingPlayCallback?.invoke(mapOf("pass" to false, "raw" to "status=FAIL;reason=$reason"))
            pendingPlayCallback = null
        }
        targetFrameCount = null
        // 3. Destroy native session (always — stale native session is never reusable after surface loss)
        val sid = sessionId
        val bridge = nativeBridge
        if (sid != null && bridge != null) {
            try { bridge.destroyAndroidDagPhase4B1TexturePlaybackSession(sid) } catch (_: Throwable) {}
        }
        sessionId = null
        // 4. Clear cached Flutter Surface reference (do NOT release SurfaceProducer)
        flutterSurface = null

        if (releaseJavaResources) {
            // 5. Stop / release MediaCodec
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            // 6. Drain and close every queued Image
            while (true) {
                val img = imageQueue.poll() ?: break
                try { img.close() } catch (_: Throwable) {}
            }
            // 7. Close ImageReader
            try { imageReader?.close() } catch (_: Throwable) {}
            // 8. Release MediaExtractor
            try { extractor?.release() } catch (_: Throwable) {}
            // 9. Quit HandlerThread safely
            try { handlerThread?.quitSafely() } catch (_: Throwable) {}
            // 10. Null heavy resource references
            codec = null
            imageReader = null
            extractor = null
            handler = null
            handlerThread = null
            nativeBridge = null
            choreographer = null
            // 11. Detach lifecycle adapter — final dispose only
            try { surfaceProducer.setCallback(null) } catch (_: Throwable) {}
            lifecycleAdapter = null
        } else {
            // Surface-loss-only cleanup: preserve codec/extractor/imageReader/handler/nativeBridge for restore.
            // nativeBridge is kept so handleSurfaceAvailable() can recreate the native session.
        }
        activeFrameCallback = null
        state = targetState
    }

    /**
     * Called by [AndroidDagSurfaceProducerLifecycleAdapter.onSurfaceCleanup].
     * Sets the lost flag immediately (so in-flight render checks abort), then posts
     * to the session handler to do the rest of the cleanup.
     *
     * Contract: Do NOT call getSurface() after this until the next onSurfaceAvailable.
     * Do NOT release MediaCodec / ImageReader / MediaExtractor / HandlerThread.
     */
    private fun handleSurfaceCleanup() {
        // Set flag immediately on platform thread so render loop abort is synchronous.
        surfaceLostFlag.set(true)

        val h = handler ?: return
        h.post {
            if (disposed.get()) return@post

            Log.i(TAG, "handleSurfaceCleanup: posting surface-loss cleanup; state=$state")
            cleanupResources(
                targetState = AndroidDagPlaybackState.SurfaceLost,
                cancelPendingPlay = true,
                releaseJavaResources = false,
            )
        }
    }

    /**
     * Called by [AndroidDagSurfaceProducerLifecycleAdapter.onSurfaceAvailable].
     * Recreates the native Vulkan/DAG session against the fresh Surface, bumps
     * generation, and optionally prerolls to [lastRenderedPtsUs] if non-zero.
     * Does NOT auto-resume playback — caller must call [play].
     */
    private fun handleSurfaceAvailable() {
        val h = handler ?: return
        h.post {
            if (disposed.get() || state == AndroidDagPlaybackState.Failed) {
                Log.i(TAG, "handleSurfaceAvailable: ignored; disposed=${disposed.get()} state=$state")
                return@post
            }

            // P0 guard: only restore when we are actually in SurfaceLost.
            // Spurious or initial available callbacks (fired before any surface loss) must be no-ops
            // to prevent duplicate native sessions being created alongside an already-live session.
            if (!surfaceLostFlag.get() && state != AndroidDagPlaybackState.SurfaceLost) {
                Log.d(TAG, "handleSurfaceAvailable: not surface-lost (state=$state); ignoring spurious callback")
                return@post
            }

            Log.i(TAG, "handleSurfaceAvailable: restoring surface; state=$state")

            // Track the session id created during this restore attempt so the catch block
            // can destroy it if an unexpected exception occurs after creation.
            var restoreCreatedSessionId: String? = null
            try {
                // Re-fetch surface from producer
                val newSurface = surfaceProducer.getSurface()
                if (!newSurface.isValid) {
                    Log.w(TAG, "handleSurfaceAvailable: getSurface() returned invalid surface; staying SurfaceLost")
                    lastRestoreFailureReason = "surface_invalid_after_available"
                    state = AndroidDagPlaybackState.SurfaceLost
                    return@post
                }
                flutterSurface = newSurface

                val nb = nativeBridge
                if (nb == null) {
                    Log.e(TAG, "handleSurfaceAvailable: nativeBridge is null; cannot recreate session")
                    lastRestoreFailureReason = "native_bridge_null_on_restore"
                    state = AndroidDagPlaybackState.SurfaceLost
                    return@post
                }

                // Recreate native session with new Surface.
                // sessionId was cleared by handleSurfaceCleanup → cleanupResources, so creating fresh is safe.
                val createResult = nb.createAndroidDagPhase4B1TexturePlaybackSession(
                    newSurface,
                    videoWidth,
                    videoHeight,
                )
                if (!createResult.startsWith("status=OK;")) {
                    Log.e(TAG, "handleSurfaceAvailable: native session create failed: $createResult")
                    lastRestoreFailureReason = "native_session_create_failed_on_restore;$createResult"
                    state = AndroidDagPlaybackState.SurfaceLost
                    return@post
                }
                val newSid = createResult.substringAfter("sessionId=").substringBefore(";").ifEmpty { null }
                if (newSid == null) {
                    lastRestoreFailureReason = "session_id_parse_failed_on_restore"
                    state = AndroidDagPlaybackState.SurfaceLost
                    return@post
                }
                sessionId = newSid
                restoreCreatedSessionId = newSid  // track for guaranteed destruction on any later failure

                // Bump generation
                val bumpRes = nb.bumpAndroidDagPhase4B1TexturePlaybackGeneration(newSid)
                if (!bumpRes.startsWith("status=OK;")) {
                    lastRestoreFailureReason = "generation_bump_failed_on_restore;$bumpRes"
                    // Destroy the just-created session to avoid orphan
                    try { nb.destroyAndroidDagPhase4B1TexturePlaybackSession(newSid) } catch (_: Throwable) {}
                    sessionId = null; restoreCreatedSessionId = null
                    state = AndroidDagPlaybackState.SurfaceLost
                    return@post
                }
                val genStr = bumpRes.substringAfter("generationId=").substringBefore(";")
                currentGenerationId = genStr.toLongOrNull() ?: (currentGenerationId + 1)

                // Clear the lost flag now that native session is live
                surfaceLostFlag.set(false)
                lastRestoreFailureReason = null
                state = AndroidDagPlaybackState.Paused

                // Optional: preroll to last rendered PTS if we had played at least one frame
                val prerollTarget = lastRenderedPtsUs
                if (prerollTarget > 0) {
                    val ex = extractor
                    val dec = codec
                    val reader = imageReader
                    if (ex == null || dec == null || reader == null) {
                        // Unexpected null resources — treat as restore failure; destroy new session.
                        Log.e(TAG, "handleSurfaceAvailable: preroll resources null (ex=$ex dec=$dec reader=$reader); failing restore")
                        lastRestoreFailureReason = "restore_resources_null_on_preroll"
                        surfaceLostFlag.set(true)
                        state = AndroidDagPlaybackState.SurfaceLost
                        try { nb.destroyAndroidDagPhase4B1TexturePlaybackSession(newSid) } catch (_: Throwable) {}
                        sessionId = null; restoreCreatedSessionId = null
                    } else {
                        // Drain queued images before seeking
                        while (true) { val img = imageQueue.poll() ?: break; try { img.close() } catch (_: Throwable) {} }
                        dec.flush()
                        inputDone = false
                        outputDone = false
                        ex.seekTo(prerollTarget, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

                        val prerollBumpRes = nb.bumpAndroidDagPhase4B1TexturePlaybackGeneration(newSid)
                        if (prerollBumpRes.startsWith("status=OK;")) {
                            val prerollGenStr = prerollBumpRes.substringAfter("generationId=").substringBefore(";")
                            currentGenerationId = prerollGenStr.toLongOrNull() ?: (currentGenerationId + 1)
                        }

                        val engineResult = AndroidDagSeekPrerollEngine().run(
                            extractor = ex,
                            codec = dec,
                            imageReader = reader,
                            imageQueue = imageQueue,
                            bridge = nb,
                            sessionId = newSid,
                            videoWidth = videoWidth,
                            videoHeight = videoHeight,
                            seekTargetUs = prerollTarget,
                            currentGenerationId = currentGenerationId,
                            renderedFramesBefore = renderedFrames,
                            deadlineMs = System.currentTimeMillis() + 8000L,
                            shouldCancel = { surfaceLostFlag.get() || disposed.get() },
                        )
                        if (engineResult.pass) {
                            renderedFrames = engineResult.renderedFrames
                            lastRenderedPtsUs = engineResult.lastRenderedPtsUs
                            restoreCreatedSessionId = null  // session is live and healthy; no need to destroy
                            Log.i(TAG, "handleSurfaceAvailable: preroll OK; pts=${engineResult.seekRenderedPtsUs}")
                        } else {
                            // P1/P3: Any preroll failure → SurfaceLost + destroy new session + record reason.
                            // Frozen contract: restore/preroll failure must keep SurfaceLost, never Paused.
                            Log.w(TAG, "handleSurfaceAvailable: preroll failed: ${engineResult.failureReason}")
                            val failReason = if (surfaceLostFlag.get()) {
                                "surface_relost_during_preroll"
                            } else {
                                "preroll_failed:${engineResult.failureReason}"
                            }
                            lastRestoreFailureReason = failReason
                            surfaceLostFlag.set(true)
                            state = AndroidDagPlaybackState.SurfaceLost
                            try { nb.destroyAndroidDagPhase4B1TexturePlaybackSession(newSid) } catch (_: Throwable) {}
                            sessionId = null; restoreCreatedSessionId = null
                        }
                    }
                } else {
                    // No preroll needed — session is live and healthy.
                    restoreCreatedSessionId = null
                }
                Log.i(TAG, "handleSurfaceAvailable: restore complete; state=$state; gen=$currentGenerationId")
            } catch (t: Throwable) {
                Log.e(TAG, "handleSurfaceAvailable: exception during restore", t)
                lastRestoreFailureReason = "restore_exception:${t.javaClass.simpleName}"
                surfaceLostFlag.set(true)
                if (!disposed.get()) {
                    state = AndroidDagPlaybackState.SurfaceLost
                }
                // Guarantee destruction of any native session created before the exception.
                val leaked = restoreCreatedSessionId
                val nb = nativeBridge
                if (leaked != null && nb != null) {
                    try { nb.destroyAndroidDagPhase4B1TexturePlaybackSession(leaked) } catch (_: Throwable) {}
                    if (sessionId == leaked) sessionId = null
                }
                restoreCreatedSessionId = null
            }
        }
    }

    /**
     * Returns a diagnostic snapshot of current session state for use by coordinator/plugin seams.
     */
    fun diagnosticState(): Map<String, Any?> = mapOf(
        "state" to state.name,
        "surfaceLost" to (surfaceLostFlag.get() || state == AndroidDagPlaybackState.SurfaceLost),
        "sessionId" to sessionId,
        "generationId" to currentGenerationId,
        "renderedFrames" to renderedFrames,
        "lastRenderedPtsUs" to lastRenderedPtsUs,
        "lastRestoreFailureReason" to lastRestoreFailureReason,
        "disposed" to disposed.get(),
    )

    /**
     * Diagnostic seam: programmatically triggers a surface cleanup event.
     * [onDone] is invoked on the session's HandlerThread after the posted cleanup work completes,
     * receiving a [diagnosticState] snapshot. Only for diagnostic/smoke use; not called in production.
     */
    fun simulateSurfaceCleanup(onDone: ((Map<String, Any?>) -> Unit)? = null) {
        Log.d(TAG, "simulateSurfaceCleanup: diagnostic trigger")
        // Set flag synchronously then post the cleanup. After cleanup, post onDone if provided.
        surfaceLostFlag.set(true)
        val h = handler ?: run { onDone?.invoke(diagnosticState()); return }
        h.post {
            if (!disposed.get()) {
                cleanupResources(
                    targetState = AndroidDagPlaybackState.SurfaceLost,
                    cancelPendingPlay = true,
                    releaseJavaResources = false,
                )
            }
            onDone?.invoke(diagnosticState())
        }
    }

    /**
     * Diagnostic seam: programmatically triggers a surface available event.
     * [onDone] is invoked on the session's HandlerThread after the posted restore work completes,
     * receiving a [diagnosticState] snapshot. Only for diagnostic/smoke use; not called in production.
     */
    fun simulateSurfaceAvailable(onDone: ((Map<String, Any?>) -> Unit)? = null) {
        Log.d(TAG, "simulateSurfaceAvailable: diagnostic trigger")
        val h = handler ?: run { onDone?.invoke(diagnosticState()); return }
        // handleSurfaceAvailable posts work onto h; the onDone post queued after it
        // executes in FIFO order, so onDone always fires after the restore is complete.
        handleSurfaceAvailable()
        h.post {
            onDone?.invoke(diagnosticState())
        }
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
