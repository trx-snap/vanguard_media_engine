package com.connects.vanguard_media_engine.codec

import android.content.Context
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
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import android.util.Log
import android.view.Choreographer
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.view.TextureRegistry
import java.io.FileDescriptor
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

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
    private val onTimelineFrame: ((textureId: Long, ptsSeconds: Double, generationId: Long) -> Unit)? = null,
    private val onTimelineEOS: ((textureId: Long) -> Unit)? = null,
    /**
     * Optional trim-end boundary (source PTS, us). When non-null, continuous playback
     * completes/EOS once the next decoded frame's PTS reaches this boundary, without ever
     * rendering a frame at or beyond it. Null preserves untrimmed (full-source) behavior.
     */
    private val playbackEndPtsUs: Long? = null,
    /**
     * Phase 7.8I-Android: optional callback invoked when video playback stops
     * unexpectedly — real/simulated surface cleanup, or a terminal Failed-state
     * transition mid-playback (as opposed to a normal pause/EOS/dispose). Used
     * by editor callers to pause a mirrored audio-preview runtime immediately.
     * [reason] is a short diagnostic tag; never null-checked by video logic.
     */
    private val onPlaybackInterrupted: ((reason: String) -> Unit)? = null,
    /**
     * Reference-import Slice 3A: optional application [Context], required only to open a
     * `content://` [videoPath] through a ContentResolver during source inspection. Plain
     * POSIX paths never touch it. A `content://` path with a null context fails closed in
     * [prepare] (source inspection reports `content_uri_requires_context`).
     */
    private val context: Context? = null,
    private val playbackSpeed: Double = 1.0,
) {
    companion object {
        private const val TAG = "DagTexturePlaybackCtrl"
        private const val IMAGE_READER_MAX_IMAGES = 6

        /**
         * Separate cap on decoded-but-unrendered Images the async ImageReader callback may
         * hold in [imageQueue], independent of [IMAGE_READER_MAX_IMAGES]. Images retained
         * off-queue by the release-fence waiter (see [deferRenderedImageClose]) also consume
         * an ImageReader acquisition slot, so a queue allowed to grow up to the full reader
         * pool could alone saturate it and trip acquireNextImage()'s maxImages exception.
         * Kept well below IMAGE_READER_MAX_IMAGES to leave that headroom.
         */
        private const val IMAGE_QUEUE_CAPACITY = 2

        /**
         * Bound on how long the release thread waits for one rendered frame's GPU release
         * fence before closing the Image anyway (fail-closed for buffer-pool safety; a
         * warning is logged). GPU work per frame completes in a few milliseconds, so this
         * only trips on a hung queue or device loss.
         */
        private const val RELEASE_FENCE_WAIT_TIMEOUT_MS = 1000

        /**
         * Frame-rate vote defaults for the Flutter playback Surface (API 30+). The vote
         * tells SurfaceFlinger the content cadence so it stops re-selecting display modes
         * (idle 60 Hz / touch 120 Hz) mid-playback on top of an otherwise-clean 30 fps
         * render cadence. Sources without a usable KEY_FRAME_RATE fall back to 30 fps.
         */
        private const val DEFAULT_SOURCE_FRAME_RATE_FPS = 30f
        private const val MIN_SOURCE_FRAME_RATE_FPS = 1f
        private const val MAX_SOURCE_FRAME_RATE_FPS = 120f
    }

    /**
     * One rendered [Image] whose close is deferred until its GPU release fence signals.
     * [fence] is this session's own dup of the native-owned release sync fd. Both closes
     * are idempotent and thread-safe: the release thread closes both after its wait, and
     * terminal cleanup may close the Image first from the control thread (after the
     * native session has been destroyed, so the GPU can no longer be reading it).
     */
    private class DeferredImageRelease(
        val image: Image,
        val fence: ParcelFileDescriptor,
        val ptsUs: Long,
    ) {
        private var imageClosed = false
        private var fenceClosed = false

        fun closeImage() {
            synchronized(this) {
                if (imageClosed) return
                imageClosed = true
            }
            try { image.close() } catch (_: Throwable) {}
        }

        /** Only the release thread (the poll owner) calls this, so no poll races a close. */
        fun closeFence() {
            synchronized(this) {
                if (fenceClosed) return
                fenceClosed = true
            }
            try { fence.close() } catch (_: Throwable) {}
        }
    }

    private val disposed = AtomicBoolean(false)

    /** Set atomically the moment onSurfaceCleanup fires; cleared on restore. */
    private val surfaceLostFlag = AtomicBoolean(false)

    // Phase 4B2B3F: diagnostic-only counters distinguishing real Flutter SurfaceProducer
    // callbacks from the simulateSurfaceCleanup/simulateSurfaceAvailable diagnostic seams.
    private val realSurfaceCleanupCallbackCount = AtomicInteger(0)
    private val realSurfaceAvailableCallbackCount = AtomicInteger(0)

    @Volatile
    private var lastSurfaceLifecycleEvent: String? = null

    private val imageQueue = LinkedBlockingQueue<Image>(IMAGE_QUEUE_CAPACITY)

    /**
     * Decoded Images closed unrendered because [imageQueue] was full when the ImageReader
     * callback tried to enqueue them. Incremented on the ImageReader thread, read on the
     * control thread for cadence telemetry and diagnostic snapshots.
     */
    private val queueOverflowDrops = AtomicInteger(0)

    /** Once-per-second render cadence aggregation; touched only on the control thread. */
    private val cadenceTelemetry = AndroidDagPlaybackCadenceTelemetry(TAG)

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

    /**
     * Dedicated HandlerThread/Handler for ImageReader.OnImageAvailableListener callbacks,
     * separate from [handlerThread]/[handler] (Choreographer + playback control). Keeping
     * image acquisition off the VSYNC/control thread lets the decoder hand off a newly
     * available frame while doFrame's synchronous feed/drain/render pump is still running,
     * instead of serializing both onto one thread and starving decode throughput.
     */
    private var imageReaderHandlerThread: HandlerThread? = null
    private var imageReaderHandler: Handler? = null

    /**
     * Dedicated HandlerThread/Handler that waits on each rendered frame's GPU release fence
     * and only then closes the decoded [Image] (returning its buffer to MediaCodec). This
     * replaces a blocking post-submit fence wait inside the native render call: the
     * Choreographer/control thread and the ImageReader acquisition thread never block on
     * GPU completion, while the decoder still cannot overwrite a buffer the GPU is sampling.
     */
    private var releaseHandlerThread: HandlerThread? = null
    private var releaseHandler: Handler? = null

    /** True only while the session may enqueue new deferred Image closes (prepare -> cleanup). */
    private val deferredCloseAccepting = AtomicBoolean(false)

    /** Number of rendered Images currently awaiting their release fence on the release thread. */
    private val deferredCloseInFlight = AtomicInteger(0)

    /** Deferred entries not yet completed by the release thread; guarded by its own monitor. */
    private val pendingDeferredReleases = ArrayList<DeferredImageRelease>()
    private var nativeBridge: VanguardNativeBridge? = null
    private var sessionId: String? = null
    private var currentGenerationId: Long = 0L

    /** Registered with [surfaceProducer] to receive availability/cleanup callbacks. */
    private var lifecycleAdapter: AndroidDagSurfaceProducerLifecycleAdapter? = null

    private var choreographer: Choreographer? = null
    private var activeFrameCallback: Choreographer.FrameCallback? = null

    /** Paces rendered frames by media PTS at [playbackSpeed] instead of one source frame per vsync. */
    private val timelineClock = AndroidDagTimelineClock(initialPlaybackSpeed = playbackSpeed)
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
     * Latest raw native render status string from a play/resume pump render call
     * (pass or fail). Surfaced to callers under the "lastNativeRenderStatus" key
     * so smoke/telemetry callers can verify the execution-planner ran on the frame.
     */
    private var lastNativeRenderStatus: String? = null
    /**
     * Latest raw native render status string from a seek-preroll render call
     * (pass or fail). Surfaced to callers under the "seekNativeRenderStatus" key.
     */
    private var seekNativeRenderStatus: String? = null
    /**
     * Video rotation from source metadata. Phase 4B2C: applied to display dimensions
     * and render transform. Normalised cardinal 0/90/180/270.
     */
    private var rotationDegrees: Int = 0

    /**
     * Display width after applying [rotationDegrees] swap (swapped for 90/270).
     * Used for surfaceProducer size, native session, and render calls.
     */
    private var displayWidth = 0

    /**
     * Display height after applying [rotationDegrees] swap (swapped for 90/270).
     */
    private var displayHeight = 0

    /**
     * Source frame rate (fps) derived from track metadata during prepare, clamped to
     * [MIN_SOURCE_FRAME_RATE_FPS]..[MAX_SOURCE_FRAME_RATE_FPS]. Used only for the
     * presentation frame-rate vote on the Flutter Surface; never affects pacing.
     */
    private var sourceFrameRateFps: Float = DEFAULT_SOURCE_FRAME_RATE_FPS

    /**
     * Freezes [timelineClock] at [ptsUs] (the actually-displayed media position), so a later
     * resume anchors from here rather than an interpolated/stale position.
     */
    private fun freezeClockAt(ptsUs: Long) {
        val now = System.nanoTime()
        timelineClock.pause(now)
        timelineClock.seek(ptsUs, now)
    }

    /**
     * Initializes resources and prepares the playback session on the dedicated HandlerThread.
     */
    fun prepare(onResult: (Map<String, Any?>) -> Unit) {
        // Phase 4B2B3A: delegate all source inspection (file preflight, API check,
        // MediaExtractor creation, track selection, metadata extraction) to helper.
        val inspection = AndroidDagSourceInspector().inspect(videoPath, context)
        if (!inspection.pass) {
            state = AndroidDagPlaybackState.Failed
            onResult(mapOf(
                "pass" to false,
                "state" to state.name,
                "raw" to "status=FAIL;reason=${inspection.failureReason}",
            ))
            return
        }

        // On success, take ownership of extractor and populate session fields.
        extractor = inspection.extractor
        videoWidth = inspection.width
        videoHeight = inspection.height
        durationUs = inspection.durationUs
        // rotationDegrees is normalised cardinal (0/90/180/270) by the inspector.
        rotationDegrees = inspection.rotationDegrees
        // Phase 4B2C: compute display dimensions - swap for 90/270 clockwise rotation.
        val swapDims = rotationDegrees == 90 || rotationDegrees == 270
        displayWidth  = if (swapDims) videoHeight else videoWidth
        displayHeight = if (swapDims) videoWidth  else videoHeight
        val mime = inspection.mime
        val format = inspection.format!!
        sourceFrameRateFps = deriveSourceFrameRateFps(format)

        try {
            cadenceTelemetry.resetAll()
            queueOverflowDrops.set(0)

            // 2. Start HandlerThread for Choreographer loop & ImageReader. Display priority
            //    keeps the vsync-driven pump from being descheduled behind default-priority
            //    app work while it feeds/drains the codec and submits the render.
            val ht = HandlerThread(
                "DagPlaybackControlLoop_${surfaceProducer.id()}",
                Process.THREAD_PRIORITY_DISPLAY,
            ).also {
                handlerThread = it
                it.start()
            }
            val h = Handler(ht.looper).also { handler = it }

            h.post {
                try {
                    // 3. Register surface lifecycle callback BEFORE first getSurface()
                    val adapter = AndroidDagSurfaceProducerLifecycleAdapter(
                        onAvailable = { handleSurfaceAvailable(countAsRealCallback = true) },
                        onCleanup   = { handleSurfaceCleanup(countAsRealCallback = true) },
                    ).also { lifecycleAdapter = it }
                    @Suppress("DEPRECATION")
                    surfaceProducer.setCallback(adapter)

                    // Configure Flutter texture buffer size with display (post-rotation) dimensions
                    // and obtain Surface. ImageReader and MediaCodec use raw decoded dimensions.
                    surfaceProducer.setSize(displayWidth, displayHeight)
                    val surface = surfaceProducer.getSurface().also { flutterSurface = it }
                    // Presentation cadence hint for SurfaceFlinger (API 30+), applied before
                    // the native session starts presenting onto this Surface.
                    applyPlaybackSurfaceFrameRateVote(surface, site = "prepare")

                    // 4. Create ImageReader (PRIVATE, GPU_SAMPLED_IMAGE, API 29+)
                    // Uses raw video dimensions: MediaCodec decodes at native resolution.
                    val reader = ImageReader.newInstance(
                        videoWidth,
                        videoHeight,
                        ImageFormat.PRIVATE,
                        IMAGE_READER_MAX_IMAGES,
                        HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
                    ).also { imageReader = it }

                    // Dedicated thread for image-available callbacks so acquisition can
                    // happen concurrently with the Choreographer/pump thread's work.
                    val irHt = HandlerThread(
                        "DagImageReaderLoop_${surfaceProducer.id()}",
                        Process.THREAD_PRIORITY_DISPLAY,
                    ).also {
                        imageReaderHandlerThread = it
                        it.start()
                    }
                    val irH = Handler(irHt.looper).also { imageReaderHandler = it }

                    // Dedicated thread for rendered-Image release-fence waits, started with
                    // the other session threads so continuous playback can defer closes
                    // from its first rendered frame.
                    val relHt = HandlerThread("DagImageReleaseLoop_${surfaceProducer.id()}").also {
                        releaseHandlerThread = it
                        it.start()
                    }
                    releaseHandler = Handler(relHt.looper)
                    deferredCloseAccepting.set(true)

                    reader.setOnImageAvailableListener(
                        { r ->
                            try {
                                val img = r.acquireNextImage()
                                if (img != null) {
                                    if (!imageQueue.offer(img)) {
                                        // Counted (not logged) per drop; surfaced by the
                                        // once-per-second CADENCE_1S line and result maps.
                                        queueOverflowDrops.incrementAndGet()
                                        img.close()
                                    }
                                }
                            } catch (e: Exception) {
                                Log.w(TAG, "acquireNextImage failed: $e")
                            }
                        },
                        irH,
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
                        displayWidth,
                        displayHeight,
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
                        "width" to displayWidth,
                        "height" to displayHeight,
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
                    "lastNativeRenderStatus" to lastNativeRenderStatus,
                    "raw" to "status=OK;state=Playing;renderedFrames=$renderedFrames",
                ))
            }

            if (activeFrameCallback == null) {
                // New playback run (initial play, resume after pause, seek, or surface
                // restore): drop the stale window so the first measured render interval is
                // not the gap across the pause. Totals are preserved.
                cadenceTelemetry.resetWindow()
                val callback = object : Choreographer.FrameCallback {
                    override fun doFrame(frameTimeNanos: Long) {
                        // Stop the loop immediately if surface has been lost or session is no longer playing.
                        if (disposed.get() || surfaceLostFlag.get() || state != AndroidDagPlaybackState.Playing) {
                            return
                        }

                        try {
                            // Resume is a no-op when already playing; on the first tick after
                            // play()/resume it anchors the clock at this vsync's frameTimeNanos.
                            val dueMediaPtsUs = timelineClock.resume(frameTimeNanos)

                            // Target-frame-count proof callers need each pump call to advance by
                            // exactly one decoded frame under a tight due-tolerance; continuous
                            // (target == null) playback instead paces to a normal frame-interval
                            // tolerance. Neither path drops frames to catch up to wall-clock -
                            // catch-up dropping produced uneven/late render intervals worse than
                            // the backlog it was meant to correct.
                            val isTargetProof = targetFrameCount != null
                            val dueToleranceUs = if (isTargetProof) {
                                AndroidDagFrameRenderPump.DEFAULT_DUE_TOLERANCE_US
                            } else {
                                AndroidDagFrameRenderPump.CONTINUOUS_DUE_TOLERANCE_US
                            }

                            // Feed, drain, and render - delegated to AndroidDagFrameRenderPump.
                            val pumpStartNanos = System.nanoTime()
                            val pumpResult = AndroidDagFrameRenderPump().pumpOnce(
                                extractor = extractor,
                                codec = codec,
                                imageQueue = imageQueue,
                                bridge = nativeBridge,
                                sessionId = sessionId,
                                videoWidth = videoWidth,
                                videoHeight = videoHeight,
                                displayWidth = displayWidth,
                                displayHeight = displayHeight,
                                rotationDegrees = rotationDegrees,
                                currentGenerationId = currentGenerationId,
                                inputDone = inputDone,
                                outputDone = outputDone,
                                renderedFrames = renderedFrames,
                                lastRenderedPtsUs = lastRenderedPtsUs,
                                dueMediaPtsUs = dueMediaPtsUs,
                                dueToleranceUs = dueToleranceUs,
                                sourceEndPtsUs = playbackEndPtsUs,
                                allowCatchUpDrop = false,
                                imageReaderMaxImages = IMAGE_READER_MAX_IMAGES,
                                imageQueueCapacity = IMAGE_QUEUE_CAPACITY,
                                // Rendered Images still awaiting their release fence hold an
                                // ImageReader acquisition slot; proof callers never defer, so
                                // this is always 0 for them regardless of isTargetProof.
                                deferredRenderedImageCloseInFlight = deferredCloseInFlight.get(),
                                // Continuous playback defers each rendered Image's close to the
                                // release thread; proof callers keep the immediate close.
                                deferRenderedImageClose = if (isTargetProof) {
                                    null
                                } else {
                                    this@AndroidDagTexturePlaybackControlSession::deferRenderedImageClose
                                },
                            )
                            val pumpEndNanos = System.nanoTime()
                            inputDone = pumpResult.inputDone
                            outputDone = pumpResult.outputDone
                            renderedFrames = pumpResult.renderedFrames
                            lastRenderedPtsUs = pumpResult.lastRenderedPtsUs
                            frameRenderError = pumpResult.frameRenderError
                            if (pumpResult.nativeRenderStatus != null) {
                                lastNativeRenderStatus = pumpResult.nativeRenderStatus
                            }

                            // Cadence telemetry: measured on System.nanoTime right after the
                            // pump so intervals reflect when frames were actually submitted,
                            // not the vsync timestamps they were scheduled against.
                            cadenceTelemetry.onFrameTick(
                                nowNanos = pumpEndNanos,
                                pumpDurationNanos = pumpEndNanos - pumpStartNanos,
                                renderedFrame = pumpResult.renderedFrame,
                                catchUpDroppedFrames = pumpResult.catchUpDroppedFrames,
                                queueDepth = imageQueue.size,
                                deferredCloseInFlight = deferredCloseInFlight.get(),
                                queueOverflowDropsTotal = queueOverflowDrops.get().toLong(),
                                generationId = currentGenerationId,
                            )

                            if (frameRenderError == null && pumpResult.renderedFrame) {
                                onTimelineFrame?.invoke(surfaceProducer.id(), lastRenderedPtsUs / 1_000_000.0, currentGenerationId)
                            }

                            // Check completion/termination
                            val target = targetFrameCount
                            if (target != null && renderedFrames >= target) {
                                freezeClockAt(lastRenderedPtsUs)
                                activeFrameCallback = null
                                val cb = pendingPlayCallback
                                pendingPlayCallback = null
                                targetFrameCount = null
                                cb?.invoke(mapOf(
                                    "pass" to true,
                                    "state" to state.name,
                                    "renderedFrames" to renderedFrames,
                                    "lastPtsUs" to lastRenderedPtsUs,
                                    "lastNativeRenderStatus" to lastNativeRenderStatus,
                                    "cadenceRenderedFrames" to cadenceTelemetry.totalRenderedFrames,
                                    "cadenceCatchUpDroppedFrames" to cadenceTelemetry.totalCatchUpDroppedFrames,
                                    "cadenceQueueOverflowDroppedFrames" to queueOverflowDrops.get().toLong(),
                                    "raw" to "status=OK;target_reached;renderedFrames=$renderedFrames",
                                ))
                            } else if (pumpResult.playbackEndReached) {
                                // Trim-end boundary reached: complete/EOS immediately regardless
                                // of remaining queue state — the pump has already closed/drained
                                // every boundary-or-later image it owned, so nothing is left
                                // queued as normal playback state to wait on.
                                if (target == null) {
                                    onTimelineEOS?.invoke(surfaceProducer.id())
                                }
                                state = AndroidDagPlaybackState.Completed
                                val freezePtsUs = playbackEndPtsUs?.let { boundary ->
                                    minOf(lastRenderedPtsUs, boundary)
                                } ?: lastRenderedPtsUs
                                freezeClockAt(freezePtsUs)
                                activeFrameCallback = null
                                val cb = pendingPlayCallback
                                pendingPlayCallback = null
                                targetFrameCount = null
                                val isPass = target == null || renderedFrames >= target
                                val raw = if (isPass) {
                                    "status=OK;completed=true;reason=playback_end_reached"
                                } else {
                                    "status=FAIL;reason=playback_end_before_target;renderedFrames=$renderedFrames;targetFrameCount=$target"
                                }
                                cb?.invoke(mapOf(
                                    "pass" to isPass,
                                    "state" to state.name,
                                    "renderedFrames" to renderedFrames,
                                    "lastPtsUs" to lastRenderedPtsUs,
                                    "lastNativeRenderStatus" to lastNativeRenderStatus,
                                    "cadenceRenderedFrames" to cadenceTelemetry.totalRenderedFrames,
                                    "cadenceCatchUpDroppedFrames" to cadenceTelemetry.totalCatchUpDroppedFrames,
                                    "cadenceQueueOverflowDroppedFrames" to queueOverflowDrops.get().toLong(),
                                    "raw" to raw,
                                ))
                            } else if (outputDone && imageQueue.isEmpty()) {
                                if (target == null) {
                                    onTimelineEOS?.invoke(surfaceProducer.id())
                                }
                                state = AndroidDagPlaybackState.Completed
                                freezeClockAt(lastRenderedPtsUs)
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
                                    "lastNativeRenderStatus" to lastNativeRenderStatus,
                                    "cadenceRenderedFrames" to cadenceTelemetry.totalRenderedFrames,
                                    "cadenceCatchUpDroppedFrames" to cadenceTelemetry.totalCatchUpDroppedFrames,
                                    "cadenceQueueOverflowDroppedFrames" to queueOverflowDrops.get().toLong(),
                                    "raw" to raw,
                                ))
                            } else if (frameRenderError != null) {
                                state = AndroidDagPlaybackState.Failed
                                activeFrameCallback = null
                                val cb = pendingPlayCallback
                                pendingPlayCallback = null
                                onPlaybackInterrupted?.invoke("frame_render_error")
                                cb?.invoke(mapOf(
                                    "pass" to false,
                                    "state" to state.name,
                                    "renderedFrames" to renderedFrames,
                                    "lastNativeRenderStatus" to lastNativeRenderStatus,
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
                            onPlaybackInterrupted?.invoke("callback_exception:${t.javaClass.simpleName}")
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
            freezeClockAt(lastRenderedPtsUs)

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
                "cadenceRenderedFrames" to cadenceTelemetry.totalRenderedFrames,
                "cadenceCatchUpDroppedFrames" to cadenceTelemetry.totalCatchUpDroppedFrames,
                "cadenceQueueOverflowDroppedFrames" to queueOverflowDrops.get().toLong(),
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

                // b. Drain/close queued app-held Images. Only never-rendered images live in
                // imageQueue; already-rendered images whose GPU release fence has not yet
                // signaled are owned by the release thread and are deliberately NOT closed
                // here (the GPU may still be sampling them). They drain on their own.
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
                    displayWidth = displayWidth,
                    displayHeight = displayHeight,
                    rotationDegrees = rotationDegrees,
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
                seekNativeRenderStatus = engineResult.nativeRenderStatus

                // j. Resume or hold Paused
                if (engineResult.pass) {
                    val renderedOrTargetPts = if (engineResult.seekRenderedPtsUs >= 0) engineResult.seekRenderedPtsUs else targetPtsUs
                    // Reset the pacing anchor to the seek-rendered PTS before any resumed playback.
                    freezeClockAt(renderedOrTargetPts)

                    if (resumeAfterSeek) {
                        state = AndroidDagPlaybackState.Playing
                        play(null) { /* continuous */ }
                    } else {
                        state = AndroidDagPlaybackState.Paused
                    }

                    onTimelineFrame?.invoke(surfaceProducer.id(), renderedOrTargetPts / 1_000_000.0, engineResult.generationId)

                    onResult(mapOf(
                        "pass" to true,
                        "state" to state.name,
                        "seekTargetUs" to targetPtsUs,
                        "seekRenderedPtsUs" to engineResult.seekRenderedPtsUs,
                        "generationId" to engineResult.generationId,
                        "renderedFrames" to renderedFrames,
                        "seekNativeRenderStatus" to seekNativeRenderStatus,
                        "raw" to "status=OK;state=${state.name};seekTargetUs=$targetPtsUs;seekRenderedPtsUs=${engineResult.seekRenderedPtsUs};generationId=${engineResult.generationId}",
                    ))
                } else {
                    state = AndroidDagPlaybackState.Failed
                    onResult(mapOf(
                        "pass" to false,
                        "state" to state.name,
                        "seekTargetUs" to targetPtsUs,
                        "seekRenderedPtsUs" to engineResult.seekRenderedPtsUs,
                        "seekNativeRenderStatus" to seekNativeRenderStatus,
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
        // 0. Stop accepting new deferred Image closes: anything rendered from here on
        //    (nothing should be) is closed immediately by the pump.
        deferredCloseAccepting.set(false)
        // 1. Remove active Choreographer callback
        val cb = activeFrameCallback
        if (cb != null) {
            try { choreographer?.removeFrameCallback(cb) } catch (_: Throwable) {}
            activeFrameCallback = null
        }
        // Freeze the pacing clock so a stale anchor can't fast-forward a later resume/restore.
        freezeClockAt(lastRenderedPtsUs)
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
        // 3b. The native session is gone (backend shutdown idles the device), so no GPU
        //     read can still target a deferred Image: close any still waiting on their
        //     release fence now. The release thread's pending runnables find the Image
        //     already closed and just close their own fence dup.
        closePendingDeferredImages("cleanup:${targetState.name}")
        // 4. Clear the frame-rate vote on the cached Flutter Surface, then drop the
        //    reference (do NOT release SurfaceProducer). Vote failures only warn.
        clearPlaybackSurfaceFrameRateVote(flutterSurface)
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
            // 9. Quit HandlerThreads safely. quitSafely still runs already-posted release
            //    runnables, so every fence dup handed to the release thread is closed.
            try { handlerThread?.quitSafely() } catch (_: Throwable) {}
            try { imageReaderHandlerThread?.quitSafely() } catch (_: Throwable) {}
            try { releaseHandlerThread?.quitSafely() } catch (_: Throwable) {}
            // 10. Null heavy resource references
            codec = null
            imageReader = null
            extractor = null
            handler = null
            handlerThread = null
            imageReaderHandler = null
            imageReaderHandlerThread = null
            releaseHandler = null
            releaseHandlerThread = null
            nativeBridge = null
            choreographer = null
            // 11. Detach lifecycle adapter — final dispose only
            try { surfaceProducer.setCallback(null) } catch (_: Throwable) {}
            lifecycleAdapter = null
        } else {
            // Surface-loss-only cleanup: preserve codec/extractor/imageReader/handler/
            // imageReaderHandler/releaseHandler/nativeBridge for restore. nativeBridge is
            // kept so handleSurfaceAvailable() can recreate the native session; the release
            // thread is kept (deferred closes stay disabled until a successful restore).
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
    private fun handleSurfaceCleanup(countAsRealCallback: Boolean = false) {
        if (countAsRealCallback) {
            realSurfaceCleanupCallbackCount.incrementAndGet()
            lastSurfaceLifecycleEvent = "real_cleanup"
        }
        // Set flag immediately on platform thread so render loop abort is synchronous.
        surfaceLostFlag.set(true)

        val h = handler ?: return
        h.post {
            if (disposed.get()) return@post

            Log.i(TAG, "handleSurfaceCleanup: posting surface-loss cleanup; state=$state")
            onPlaybackInterrupted?.invoke("surface_cleanup")
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
     *
     * Phase 4B2B3B: dense restore algorithm delegated to [AndroidDagSurfaceRecoveryHandler];
     * this method keeps the spurious-available guard, nativeBridge null check, and all
     * session field / state assignments.
     */
    private fun handleSurfaceAvailable(countAsRealCallback: Boolean = false) {
        if (countAsRealCallback) {
            realSurfaceAvailableCallbackCount.incrementAndGet()
            lastSurfaceLifecycleEvent = "real_available"
        }
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

            val nb = nativeBridge
            if (nb == null) {
                Log.e(TAG, "handleSurfaceAvailable: nativeBridge is null; cannot recreate session")
                lastRestoreFailureReason = "native_bridge_null_on_restore"
                state = AndroidDagPlaybackState.SurfaceLost
                return@post
            }

            // Reset codec bookkeeping flags before preroll so they are never stale
            // regardless of whether the helper performs a seek/preroll.
            if (lastRenderedPtsUs > 0) {
                inputDone = false
                outputDone = false
            }

            // Clear the stale flag from the loss that triggered this restore so shouldCancel
            // below only fires on a *new* cleanup/loss or disposal that happens during restore.
            surfaceLostFlag.set(false)

            val result = AndroidDagSurfaceRecoveryHandler().restoreSurface(
                surfaceProducer = surfaceProducer,
                bridge = nb,
                extractor = extractor,
                codec = codec,
                imageReader = imageReader,
                imageQueue = imageQueue,
                videoWidth = videoWidth,
                videoHeight = videoHeight,
                displayWidth = displayWidth,
                displayHeight = displayHeight,
                rotationDegrees = rotationDegrees,
                lastRenderedPtsUs = lastRenderedPtsUs,
                renderedFrames = renderedFrames,
                currentGenerationId = currentGenerationId,
                isDisposed = { disposed.get() },
                shouldCancel = { surfaceLostFlag.get() || disposed.get() },
            )

            if (result.success) {
                // Re-apply the presentation cadence vote to the freshly fetched Surface
                // (the vote does not carry over from the pre-loss Surface).
                result.surface?.let { applyPlaybackSurfaceFrameRateVote(it, site = "restore") }
                flutterSurface = result.surface
                sessionId = result.sessionId
                currentGenerationId = result.generationId
                renderedFrames = result.renderedFrames
                lastRenderedPtsUs = result.lastRenderedPtsUs
                // Re-anchor pacing to the actually-restored PTS (preroll may differ from the pre-loss PTS).
                freezeClockAt(lastRenderedPtsUs)
                surfaceLostFlag.set(false)
                lastRestoreFailureReason = null
                // Re-arm deferred closes against the fresh native session (the release
                // thread survived surface-loss cleanup).
                deferredCloseAccepting.set(releaseHandler != null)
                state = AndroidDagPlaybackState.Paused
                Log.i(TAG, "handleSurfaceAvailable: restore complete; state=$state; gen=$currentGenerationId")
            } else {
                surfaceLostFlag.set(true)
                state = AndroidDagPlaybackState.SurfaceLost
                sessionId = null
                lastRestoreFailureReason = result.failureReason
                Log.w(TAG, "handleSurfaceAvailable: restore failed: ${result.failureReason}")
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
        "realSurfaceCleanupCallbackCount" to realSurfaceCleanupCallbackCount.get(),
        "realSurfaceAvailableCallbackCount" to realSurfaceAvailableCallbackCount.get(),
        "lastSurfaceLifecycleEvent" to lastSurfaceLifecycleEvent,
        "deferredImageClosesInFlight" to deferredCloseInFlight.get(),
        "cadenceRenderedFrames" to cadenceTelemetry.totalRenderedFrames,
        "cadenceCatchUpDroppedFrames" to cadenceTelemetry.totalCatchUpDroppedFrames,
        "cadenceQueueOverflowDroppedFrames" to queueOverflowDrops.get().toLong(),
        "sourceFrameRateFps" to sourceFrameRateFps,
    )

    // ── Playback Surface frame-rate vote (presentation cadence hint) ─────────

    /**
     * Reads [MediaFormat.KEY_FRAME_RATE] from the selected video track. The key may be
     * stored as an Integer or a Float depending on the container/extractor, and may be
     * absent or malformed; every such case falls back to [DEFAULT_SOURCE_FRAME_RATE_FPS].
     * The result is clamped to a sane range and never throws.
     */
    private fun deriveSourceFrameRateFps(format: MediaFormat): Float {
        val raw: Float? = try {
            if (!format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                null
            } else {
                try {
                    format.getInteger(MediaFormat.KEY_FRAME_RATE).toFloat()
                } catch (_: ClassCastException) {
                    format.getFloat(MediaFormat.KEY_FRAME_RATE)
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "source frame-rate metadata read failed; defaulting to $DEFAULT_SOURCE_FRAME_RATE_FPS fps: $t")
            null
        }
        return if (raw != null && raw.isFinite() && raw > 0f) {
            raw.coerceIn(MIN_SOURCE_FRAME_RATE_FPS, MAX_SOURCE_FRAME_RATE_FPS)
        } else {
            DEFAULT_SOURCE_FRAME_RATE_FPS
        }
    }

    /**
     * Votes [sourceFrameRateFps] on [surface] with FIXED_SOURCE compatibility (API 30+) so
     * SurfaceFlinger keeps a display mode that is a multiple of the content cadence instead
     * of bouncing between idle/touch modes while 30 fps content is presenting. No-op below
     * API 30. Failure only warns; it never changes session state or lifecycle.
     */
    private fun applyPlaybackSurfaceFrameRateVote(surface: Surface, site: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            surface.setFrameRate(sourceFrameRateFps, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
            Log.i(TAG, "playback surface frame-rate vote fps=$sourceFrameRateFps textureId=${surfaceProducer.id()} site=$site")
        } catch (t: Throwable) {
            Log.w(TAG, "playback surface frame-rate vote failed fps=$sourceFrameRateFps textureId=${surfaceProducer.id()} site=$site: $t")
        }
    }

    /**
     * Clears any frame-rate vote on [surface] (API 30+) before the session drops its
     * reference, so a released/re-used Flutter Surface does not keep voting for the old
     * content cadence. Null surface and pre-API-30 are no-ops; failure only warns.
     */
    private fun clearPlaybackSurfaceFrameRateVote(surface: Surface?) {
        if (surface == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            surface.setFrameRate(0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
            Log.i(TAG, "playback surface frame-rate vote cleared textureId=${surfaceProducer.id()}")
        } catch (t: Throwable) {
            Log.w(TAG, "playback surface frame-rate vote clear failed textureId=${surfaceProducer.id()}: $t")
        }
    }

    // ── Rendered-Image release-fence deferral ────────────────────────────────

    /**
     * [AndroidDagFrameRenderPump.pumpOnce] `deferRenderedImageClose` seam for continuous
     * playback. Runs synchronously on the control thread right after a successful native
     * render. Dups the native-owned release sync fd (native closes its copy on the next
     * render call for this session, which can only happen after this returns because both
     * run on the control thread), enqueues the wait on the release thread, and returns true
     * so the pump leaves the Image open. Any failure to enqueue closes the dup and returns
     * false so the pump closes the Image immediately (pre-existing behavior).
     */
    private fun deferRenderedImageClose(image: Image, releaseFenceFd: Int): Boolean {
        if (releaseFenceFd < 0 || disposed.get() || !deferredCloseAccepting.get()) return false
        val rh = releaseHandler ?: return false
        val fence: ParcelFileDescriptor = try {
            ParcelFileDescriptor.fromFd(releaseFenceFd)
        } catch (t: Throwable) {
            Log.w(TAG, "release fence dup failed (fd=$releaseFenceFd); closing image immediately: $t")
            return false
        }
        val entry = DeferredImageRelease(image, fence, image.timestamp / 1000L)
        synchronized(pendingDeferredReleases) { pendingDeferredReleases.add(entry) }
        deferredCloseInFlight.incrementAndGet()
        val posted = try {
            rh.post { completeDeferredRelease(entry) }
        } catch (t: Throwable) {
            Log.w(TAG, "release-thread post threw: $t")
            false
        }
        if (!posted) {
            synchronized(pendingDeferredReleases) { pendingDeferredReleases.remove(entry) }
            deferredCloseInFlight.decrementAndGet()
            entry.closeFence()
            Log.w(TAG, "release thread unavailable; closing image immediately pts=${entry.ptsUs}")
            return false
        }
        return true
    }

    /** Release-thread body: wait for the frame's GPU reads to finish, then close Image and fence. */
    private fun completeDeferredRelease(entry: DeferredImageRelease) {
        try {
            waitForReleaseFence(entry.fence.fileDescriptor, entry.ptsUs)
        } catch (t: Throwable) {
            Log.w(TAG, "release-fence wait threw pts=${entry.ptsUs}; closing image anyway: $t")
        } finally {
            synchronized(pendingDeferredReleases) { pendingDeferredReleases.remove(entry) }
            entry.closeImage()
            entry.closeFence()
            deferredCloseInFlight.decrementAndGet()
        }
    }

    /**
     * Polls the sync fd for POLLIN (fence signaled) with a bounded total timeout, retrying
     * across EINTR. Timeout, poll error, or POLLERR/POLLNVAL/POLLHUP log a warning and
     * return normally so the caller still closes the Image (fail-closed for the buffer pool).
     */
    private fun waitForReleaseFence(syncFd: FileDescriptor, ptsUs: Long) {
        val pollfd = StructPollfd()
        pollfd.fd = syncFd
        pollfd.events = OsConstants.POLLIN.toShort()
        val fds = arrayOf(pollfd)
        val deadlineMs = SystemClock.elapsedRealtime() + RELEASE_FENCE_WAIT_TIMEOUT_MS
        while (true) {
            val remainingMs = (deadlineMs - SystemClock.elapsedRealtime()).coerceAtLeast(0L).toInt()
            val ready = try {
                Os.poll(fds, remainingMs)
            } catch (e: ErrnoException) {
                if (e.errno == OsConstants.EINTR) continue
                Log.w(TAG, "release-fence poll error pts=$ptsUs errno=${e.errno}; closing image anyway")
                return
            }
            if (ready > 0) {
                val revents = pollfd.revents.toInt()
                if (revents and (OsConstants.POLLERR or OsConstants.POLLNVAL or OsConstants.POLLHUP) != 0) {
                    Log.w(TAG, "release-fence poll reported revents=0x${Integer.toHexString(revents)} pts=$ptsUs; closing image anyway")
                    return
                }
                if (revents and OsConstants.POLLIN != 0) return // fence signaled
            }
            if (remainingMs <= 0) {
                Log.w(TAG, "release-fence wait timed out after ${RELEASE_FENCE_WAIT_TIMEOUT_MS}ms pts=$ptsUs; closing image anyway")
                return
            }
            // ready == 0 with time left cannot happen (poll waits the full remaining time),
            // and a spurious wake without POLLIN simply loops until the deadline.
        }
    }

    /**
     * Terminal close of every rendered Image still awaiting its release fence. Must only be
     * called after the native session has been destroyed (GPU idle). Fence dups are left to
     * the release thread, which owns their polls and closes them when its runnables complete.
     */
    private fun closePendingDeferredImages(reason: String) {
        val snapshot: List<DeferredImageRelease> = synchronized(pendingDeferredReleases) {
            ArrayList(pendingDeferredReleases)
        }
        if (snapshot.isEmpty()) return
        Log.i(TAG, "closing ${snapshot.size} deferred image(s) still awaiting release fence ($reason)")
        for (entry in snapshot) {
            entry.closeImage()
        }
    }

    /**
     * Diagnostic seam: programmatically triggers a surface cleanup event.
     * [onDone] is invoked on the session's HandlerThread after the posted cleanup work completes,
     * receiving a [diagnosticState] snapshot. Only for diagnostic/smoke use; not called in production.
     */
    fun simulateSurfaceCleanup(onDone: ((Map<String, Any?>) -> Unit)? = null) {
        Log.d(TAG, "simulateSurfaceCleanup: diagnostic trigger")
        // Simulated seam: does not touch the real-callback counters.
        lastSurfaceLifecycleEvent = "simulated_cleanup"
        // Set flag synchronously then post the cleanup. After cleanup, post onDone if provided.
        surfaceLostFlag.set(true)
        val h = handler ?: run { onDone?.invoke(diagnosticState()); return }
        h.post {
            if (!disposed.get()) {
                onPlaybackInterrupted?.invoke("simulated_surface_cleanup")
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
        // Simulated seam: countAsRealCallback=false keeps the real-callback counters untouched.
        handleSurfaceAvailable(countAsRealCallback = false)
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
                "cadenceRenderedFrames" to cadenceTelemetry.totalRenderedFrames,
                "cadenceCatchUpDroppedFrames" to cadenceTelemetry.totalCatchUpDroppedFrames,
                "cadenceQueueOverflowDroppedFrames" to queueOverflowDrops.get().toLong(),
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
