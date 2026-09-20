package com.connects.vanguard_media_engine.greenscreen

import android.content.Context
import android.graphics.PixelFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.google.mediapipe.framework.GraphTextureFrame
import java.util.LinkedHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Coordination seam between [AndroidGreenScreenGpuTextureBridge] and
 * [AndroidGreenScreenMediaPipeGpuGraphSession]: pushes a resolved camera RGBA texture into the
 * MediaPipe graph and republishes the resulting segmentation mask as a caller-owned
 * [HardwareBuffer].
 */
class AndroidGreenScreenGpuPipeline(
    context: Context,
    private val widthPx: Int,
    private val heightPx: Int,
    private val modelSelection: Int = 1,
    private val enableMaskBufferPool: Boolean = false,
    // Camera-pressure fix: fires after InFlightInput.release() returns a permit (i.e. capacity
    // may now be available), so a caller starved by MAX_INPUT_IN_FLIGHT can re-drain its source
    // instead of polling. May be invoked from any thread (MediaPipe's callback thread or the GL
    // worker); callback exceptions are caught and logged, never propagated. Declared before
    // onGpuMask (both defaulted) so onGpuMask stays the constructor's trailing-lambda parameter
    // for existing positional call sites.
    private val onInputCapacityAvailable: (() -> Unit)? = null,
    private val onGpuMask: (HardwareBuffer, Int, Int, Long, ((HardwareBuffer) -> Unit)?, Int) -> Unit,
) {
    companion object {
        private const val TAG = "GreenScreenGpuPipeline"
        private const val WARMUP_MASK_EXCLUSION_COUNT = 4L
        private const val MASK_BUFFER_POOL_SIZE = 3
        // Diagnostic mask surface ImageReader capacity. Kept well above
        // MAX_MASK_OUTPUT_IMAGES_IN_FLIGHT so acquireLatestImage() has headroom
        // while a previously delivered mask Image is still open downstream
        // (render/compositor release callback), instead of throwing
        // IllegalStateException("maxImages has already been acquired").
        private const val MASK_SURFACE_READER_MAX_IMAGES = 8
        // RND: re-enabled to replace the blocking native glFinish() copy
        // (onMaskTextureFrameOnGlWorker's non-fence branch) with the async
        // acquire-fence import path, to test whether it removes mask-copy latency
        // seen with texture_callback output.
        private const val ENABLE_OUTPUT_COPY_ACQUIRE_FENCE = true
        private const val ENABLE_MASK_OUTPUT_COPY = true
        // Disabled so this pipeline instead exercises MediaPipe's texture callback
        // output path (session.setMaskTextureCallback) for an honest latency comparison.
        // The SurfaceOutput/ImageReader code below stays intact and can be re-enabled
        // by flipping this back to true.
        private const val ENABLE_MEDIAPIPE_SURFACE_OUTPUT_MASK = false
        private const val SURFACE_MASK_STATS_MAX_LOGS = 3
        private const val SURFACE_MASK_STATS_MAX_SAMPLES = 4096

        // RND texture-slot pool: maximum camera inputs that may be owned by
        // MediaPipe at once. Each in-flight input pins one pool slot until
        // MediaPipe's TextureReleaseCallback returns it, and native fails a
        // resolve closed (0) rather than overwrite an in-use slot. This live
        // policy cap does not need to match the native bridge's pool size
        // (currently 3) and may be less than or equal to it: live preview
        // favors low end-to-end latency over throughput, so newest-frame
        // camera input is preferred and older/queued frames are dropped
        // rather than let MediaPipe fall behind a deep backlog.
        private const val MAX_INPUT_IN_FLIGHT = 1
        // Per-frame "input in flight" drops are expected under backpressure
        // (~30 fps camera vs. MediaPipe cadence); log the first few and then
        // one in every INPUT_DROP_LOG_EVERY_N, keeping the aggregate in the
        // close() summary.
        private const val INPUT_DROP_LOG_FIRST_N = 3L
        private const val INPUT_DROP_LOG_EVERY_N = 200L

        // Mask-output ownership gate: bounds how many surface-output mask
        // Images may be handed to onGpuMask (and thus owned by the
        // render/compositor path) at once, independent of the diagnostic
        // reader's larger MASK_SURFACE_READER_MAX_IMAGES capacity.
        private const val MAX_MASK_OUTPUT_IMAGES_IN_FLIGHT = 3
        private const val MASK_OUTPUT_CAPACITY_LOG_FIRST_N = 3L
        private const val MASK_OUTPUT_CAPACITY_LOG_EVERY_N = 200L
    }

    private val appContext = context.applicationContext

    @Volatile private var textureBridge: AndroidGreenScreenGpuTextureBridge? = null
    @Volatile private var graphSession: AndroidGreenScreenMediaPipeGpuGraphSession? = null
    @Volatile private var maskSurfaceReader: ImageReader? = null
    @Volatile private var glThread: HandlerThread? = null
    @Volatile private var glHandler: Handler? = null

    private val isOpen = AtomicBoolean(false)
    private val isClosed = AtomicBoolean(false)

    // Bounded in-flight accounting (RND texture-slot pool): the number of
    // camera inputs currently owning a native pool texture, from the moment
    // a permit is taken in processCameraHardwareBuffer[Async] until that
    // input's InFlightInput.release() runs (MediaPipe's
    // TextureReleaseCallback on the happy path). Never exceeds
    // MAX_INPUT_IN_FLIGHT; decrements floor at 0 so a late callback after
    // close() cannot drive it negative.
    private val inputInFlightCount = AtomicInteger(0)
    // Camera-thread drops because MAX_INPUT_IN_FLIGHT inputs were already
    // in flight (any thread; see logInputDropThrottled).
    private val inputDropInFlightCount = AtomicLong(0)

    // Mask-output ownership gate (GL-worker-confined increment in
    // drainSurfaceOutputMask, any-thread decrement in
    // SurfaceMaskOwnership.close() once its release callback fires): the
    // number of surface-output mask Images currently handed to onGpuMask and
    // not yet closed by the render/compositor path. Never exceeds
    // MAX_MASK_OUTPUT_IMAGES_IN_FLIGHT; decrement floors at 0 so a late
    // close() after close() of the pipeline cannot drive it negative.
    private val maskOutputInFlightCount = AtomicInteger(0)
    // Drain-thread skips because MAX_MASK_OUTPUT_IMAGES_IN_FLIGHT mask
    // Images were already in flight (see logMaskOutputCapacityFullThrottled).
    private val maskOutputCapacityFullCount = AtomicLong(0)
    // Coalescing guard: at most one pending GL-handler retry of
    // drainSurfaceOutputMask() per capacity release, instead of one per
    // SurfaceMaskOwnership.close() call.
    private val maskOutputRetryScheduled = AtomicBoolean(false)

    @Volatile
    var lastRejectReason: String = "none"
        private set

    private var submittedFrameCount: Long = 0
    // GL-worker-confined failure counters: native resolve returned 0 (GL
    // failure OR no free pool slot; native does not distinguish) and
    // MediaPipe rejected the hand-off.
    private var resolveFailedCount: Long = 0
    private var sendFailedCount: Long = 0
    private var maskFrameCount: Long = 0
    private var totalMaskLatencyMs: Long = 0
    private var minMaskLatencyMs: Long = Long.MAX_VALUE
    private var maxMaskLatencyMs: Long = 0
    private var steadyMaskFrameCount: Long = 0
    private var totalSteadyMaskLatencyMs: Long = 0
    private var minSteadyMaskLatencyMs: Long = Long.MAX_VALUE
    private var maxSteadyMaskLatencyMs: Long = 0
    private var slowMaskOver50Ms: Long = 0
    private var slowMaskOver100Ms: Long = 0
    private var slowMaskOver250Ms: Long = 0
    private var slowMaskOver1000Ms: Long = 0
    private val inputReleaseTelemetryLock = Any()
    private var inputReleaseFrameCount: Long = 0
    private var totalInputReleaseLatencyMs: Long = 0
    private var maxInputReleaseLatencyMs: Long = 0
    private var slowInputReleaseOver50Ms: Long = 0
    private var slowInputReleaseOver100Ms: Long = 0
    private var slowInputReleaseOver250Ms: Long = 0
    private var slowInputReleaseOver1000Ms: Long = 0
    private var maskCopyFrameCount: Long = 0
    private var totalMaskCopyLatencyMs: Long = 0
    private var maxMaskCopyLatencyMs: Long = 0
    private var pooledMaskCreateCount: Long = 0
    private var pooledMaskReuseCount: Long = 0
    private var pooledMaskUnavailableCount: Long = 0
    private val submitStartNsByTimestampUs = LinkedHashMap<Long, Long>()
    private val maskBufferPoolLock = Any()
    private val maskBufferPool = ArrayList<MaskBufferSlot>(MASK_BUFFER_POOL_SIZE)
    private var maskBufferPoolClosing = false
    private var surfaceMaskStatsLoggedCount = 0

    /** Opens the bridge + graph pair. Idempotent: false if already open or previously closed. */
    @Synchronized
    fun open(): Boolean {
        if (isClosed.get()) {
            Log.w(TAG, "open() rejected: pipeline already closed")
            return false
        }
        if (!isOpen.compareAndSet(false, true)) {
            Log.w(TAG, "open() ignored: already open")
            return false
        }
        val thread = HandlerThread("vg.greenscreen.gl")
        thread.start()
        val handler = Handler(thread.looper)
        glThread = thread
        glHandler = handler
        val opened = runOnGlWorkerBlocking("open", timeoutMs = 2500L) {
            openOnGlWorker()
        }
        if (!opened) {
            isOpen.set(false)
            glHandler = null
            glThread = null
            try {
                thread.quitSafely()
                thread.join(500)
            } catch (_: Throwable) {
            }
        }
        return opened
    }

    private fun openOnGlWorker(): Boolean {
        var bridge: AndroidGreenScreenGpuTextureBridge? = null
        var session: AndroidGreenScreenMediaPipeGpuGraphSession? = null
        var surfaceReader: ImageReader? = null
        return try {
            bridge = AndroidGreenScreenGpuTextureBridge.open(widthPx, heightPx)
            if (bridge == null) {
                lastRejectReason = "texture_bridge_unavailable"
                Log.w(TAG, "open() failed: texture bridge unavailable")
                isOpen.set(false)
                return false
            }
            val parentGlContext = bridge.parentGlContext()
            if (parentGlContext == 0L) {
                lastRejectReason = "parent_gl_context_zero"
                Log.w(TAG, "open() failed: parent GL context is zero")
                bridge.close()
                isOpen.set(false)
                return false
            }
            session = AndroidGreenScreenMediaPipeGpuGraphSession()
            if (ENABLE_MEDIAPIPE_SURFACE_OUTPUT_MASK) {
                surfaceReader = createMaskSurfaceReader(widthPx, heightPx)
            }
            if (!session.open(
                    appContext,
                    modelSelection,
                    parentGlContext,
                    maskOutputSurface = surfaceReader?.surface,
                )
            ) {
                lastRejectReason = "mediapipe_graph_session_open_failed"
                Log.w(TAG, "open() failed: MediaPipe graph session did not start")
                try { surfaceReader?.close() } catch (_: Throwable) {}
                bridge.close()
                isOpen.set(false)
                return false
            }
            if (surfaceReader == null) {
                session.setMaskTextureCallback(::onMaskTextureFrame)
                Log.i(
                    TAG,
                    "ANDROID_GREENSCREEN_GPU_PIPELINE_MASK_OUTPUT_MODE " +
                        "mode=texture_callback",
                )
            } else {
                maskSurfaceReader = surfaceReader
            }
            textureBridge = bridge
            graphSession = session
            Log.i(TAG, "ANDROID_GREENSCREEN_GPU_PIPELINE_GL_WORKER_READY")
            true
        } catch (t: Throwable) {
            lastRejectReason = "open_threw_${t.javaClass.simpleName}"
            Log.e(TAG, "open() threw", t)
            try { surfaceReader?.close() } catch (_: Throwable) {}
            session?.close()
            bridge?.close()
            maskSurfaceReader = null
            textureBridge = null
            graphSession = null
            isOpen.set(false)
            false
        }
    }

    private fun createMaskSurfaceReader(width: Int, height: Int): ImageReader? {
        return try {
            val reader = ImageReader.newInstance(
                width,
                height,
                PixelFormat.RGBA_8888,
                MASK_SURFACE_READER_MAX_IMAGES,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_GPU_COLOR_OUTPUT,
            )
            reader.setOnImageAvailableListener({ availableReader ->
                drainSurfaceOutputMask(availableReader)
            }, glHandler)
            reader
        } catch (t: Throwable) {
            Log.w(
                TAG,
                "createMaskSurfaceReader() failed; falling back to callback copy: " +
                    "${t.javaClass.simpleName}: ${t.message}",
                t,
            )
            null
        }
    }

    /**
     * Resolves [cameraHardwareBuffer] into a free slot of the bridge's fixed pool of output
     * textures and hands it to the MediaPipe graph. Returns false without side effects if not
     * open or [MAX_INPUT_IN_FLIGHT] inputs are already owned by MediaPipe. Never closes
     * [cameraHardwareBuffer]; the caller owns it and may close it as soon as this returns,
     * because the native resolve copies it into the pool texture and glFinish()es before
     * returning. The pool slot itself stays owned until MediaPipe's TextureReleaseCallback
     * returns it (see [InFlightInput]).
     */
    fun processCameraHardwareBuffer(
        cameraHardwareBuffer: HardwareBuffer,
        widthPx: Int,
        heightPx: Int,
        timestampUs: Long,
    ): Boolean {
        if (isClosed.get() || !isOpen.get()) {
            lastRejectReason = "pipeline_not_open"
            return false
        }
        val inFlight = tryAcquireInFlightInput()
        if (inFlight == null) {
            lastRejectReason = "input_in_flight"
            logInputDropThrottled("processCameraHardwareBuffer()")
            return false
        }
        // The caller owns and closes cameraHardwareBuffer immediately after this method returns.
        // Do not use a short timeout here: a timed-out queued GL task could later sample a closed
        // Camera2 buffer. Back-pressure on the camera callback is safer than use-after-close.
        var submitted = false
        try {
            submitted = runOnGlWorkerBlocking("processCameraHardwareBuffer", timeoutMs = 0L) {
                processCameraHardwareBufferOnGlWorker(
                    cameraHardwareBuffer = cameraHardwareBuffer,
                    widthPx = widthPx,
                    heightPx = heightPx,
                    timestampUs = timestampUs,
                    inFlight = inFlight,
                )
            }
        } finally {
            // Once submitted, MediaPipe's TextureReleaseCallback owns the release.
            // release() is once-guarded, so a failure path that already released
            // (sendRgbaTexture2d fires its callback synchronously on failure) is a no-op.
            if (!submitted) inFlight.release(fromMediaPipe = false)
        }
        return submitted
    }

    /**
     * Async variant for live Camera2 ImageReader callbacks. The caller-owned
     * [cameraHardwareBuffer] remains valid until [onConsumed] fires, which happens as soon as
     * the GL-worker resolve work completes (the native resolve has copied the camera buffer
     * into a pool texture and glFinish()ed by then) -- NOT when MediaPipe later releases the
     * pool texture -- so the Camera2 ImageReader is never starved by MediaPipe latency.
     */
    fun processCameraHardwareBufferAsync(
        cameraHardwareBuffer: HardwareBuffer,
        widthPx: Int,
        heightPx: Int,
        timestampUs: Long,
        onConsumed: () -> Unit,
    ): Boolean {
        if (isClosed.get() || !isOpen.get()) {
            lastRejectReason = "pipeline_not_open"
            notifyCameraBufferConsumedQuietly(onConsumed)
            return false
        }
        val inFlight = tryAcquireInFlightInput()
        if (inFlight == null) {
            lastRejectReason = "input_in_flight"
            notifyCameraBufferConsumedQuietly(onConsumed)
            logInputDropThrottled("processCameraHardwareBufferAsync()")
            return false
        }
        val posted = postToGlWorker("processCameraHardwareBufferAsync") {
            var submitted = false
            try {
                submitted = processCameraHardwareBufferOnGlWorker(
                    cameraHardwareBuffer = cameraHardwareBuffer,
                    widthPx = widthPx,
                    heightPx = heightPx,
                    timestampUs = timestampUs,
                    inFlight = inFlight,
                )
            } finally {
                // Resolve work is complete (copied + glFinish()ed, or failed): the
                // caller-owned camera buffer is free regardless of how long MediaPipe
                // keeps the resolved pool texture.
                notifyCameraBufferConsumedQuietly(onConsumed)
                if (!submitted) inFlight.release(fromMediaPipe = false)
            }
        }
        if (!posted) {
            inFlight.release(fromMediaPipe = false)
            notifyCameraBufferConsumedQuietly(onConsumed)
        }
        return posted
    }

    /**
     * GL-worker body shared by both entry points. [inFlight] is the permit the caller already
     * took; once a pool texture is resolved it is attached to [inFlight] so exactly one
     * once-guarded release returns BOTH the pool slot and the permit -- from MediaPipe's
     * TextureReleaseCallback on success (which sendRgbaTexture2d also fires synchronously when
     * the hand-off fails), or from the caller's `!submitted` path. Returns true only when
     * MediaPipe accepted the texture.
     */
    private fun processCameraHardwareBufferOnGlWorker(
        cameraHardwareBuffer: HardwareBuffer,
        widthPx: Int,
        heightPx: Int,
        timestampUs: Long,
        inFlight: InFlightInput,
    ): Boolean {
        val bridge = textureBridge ?: run {
            lastRejectReason = "texture_bridge_null"
            return false
        }
        val session = graphSession ?: run {
            lastRejectReason = "graph_session_null"
            return false
        }
        return try {
            val submitStartNs = System.nanoTime()
            val textureName = bridge.resolveCameraHardwareBufferToRgbaTexture(
                cameraHardwareBuffer, widthPx, heightPx, timestampUs,
            )
            if (textureName == 0) {
                // Native returns 0 for a GL/import failure AND when every pool slot is
                // still owned by MediaPipe (it never overwrites an in-use slot). The live
                // policy cap (MAX_INPUT_IN_FLIGHT) stays at or below the native pool size,
                // so slot exhaustion here still signals a late/missing release callback
                // rather than ordinary backpressure, keeping this counter a pool-health signal.
                lastRejectReason = "camera_hardware_buffer_resolve_failed_or_no_free_slot"
                resolveFailedCount += 1
                return false
            }
            inFlight.attachResolvedTexture(bridge, textureName, submitStartNs)
            val sent = session.sendRgbaTexture2d(textureName, widthPx, heightPx, timestampUs) {
                inFlight.release(fromMediaPipe = true)
            }
            if (!sent) {
                lastRejectReason = "mediapipe_send_rgba_texture_failed"
                sendFailedCount += 1
                // Release immediately; no-op if the session already fired the callback.
                inFlight.release(fromMediaPipe = false)
                return false
            }
            submittedFrameCount += 1
            submitStartNsByTimestampUs[timestampUs] = submitStartNs
            while (submitStartNsByTimestampUs.size > 32) {
                val oldestKey = submitStartNsByTimestampUs.keys.firstOrNull() ?: break
                submitStartNsByTimestampUs.remove(oldestKey)
            }
            lastRejectReason = "none"
            true
        } catch (t: Throwable) {
            lastRejectReason = "process_threw_${t.javaClass.simpleName}"
            Log.e(TAG, "processCameraHardwareBuffer() threw", t)
            false
        }
    }

    private fun onMaskTextureFrame(frame: GraphTextureFrame, timestampUs: Long) {
        val posted = postToGlWorker("onMaskTextureFrame") {
            onMaskTextureFrameOnGlWorker(frame, timestampUs)
        }
        if (!posted) {
            try { frame.release() } catch (t: Throwable) { Log.w(TAG, "frame.release() threw", t) }
        }
    }

    private fun onMaskTextureFrameOnGlWorker(frame: GraphTextureFrame, timestampUs: Long) {
        val bridge = textureBridge
        if (isClosed.get() || !isOpen.get() || bridge == null) {
            try { frame.release() } catch (t: Throwable) { Log.w(TAG, "frame.release() threw", t) }
            return
        }
        var target: HardwareBuffer? = null
        try {
            val width = frame.width
            val height = frame.height
            recordMaskLatencyOnGlWorker(timestampUs)
            if (!ENABLE_MASK_OUTPUT_COPY) {
                return
            }
            val copyStartNs = System.nanoTime()
            val created = acquireMaskHardwareBuffer(bridge, width, height)
            if (created == null) {
                Log.w(TAG, "onMaskTextureFrame() failed: could not allocate mask HardwareBuffer")
                return
            }
            target = created
            val acquireFenceFd =
                if (enableMaskBufferPool && ENABLE_OUTPUT_COPY_ACQUIRE_FENCE) {
                    bridge.copyTexture2dToHardwareBufferAcquireFenceFd(
                        frame.textureName, width, height, created,
                    )
                } else {
                    if (bridge.copyTexture2dToHardwareBuffer(frame.textureName, width, height, created)) {
                        -1
                    } else {
                        AndroidGreenScreenGpuTextureBridge.COPY_FAILED_FENCE_FD
                    }
                }
            if (acquireFenceFd == AndroidGreenScreenGpuTextureBridge.COPY_FAILED_FENCE_FD) {
                Log.w(TAG, "onMaskTextureFrame() failed: copyTexture2dToHardwareBuffer() returned false")
                created.close()
                target = null
                return
            }
            recordMaskCopyLatencyOnGlWorker(copyStartNs)
            target = null
            try {
                onGpuMask(
                    created, width, height, timestampUs,
                    if (enableMaskBufferPool) ::releaseMaskHardwareBuffer else null,
                    acquireFenceFd,
                )
            } catch (t: Throwable) {
                Log.e(TAG, "onGpuMask() threw", t)
                releaseOrCloseMaskHardwareBuffer(created)
            }
        } catch (t: Throwable) {
            Log.e(TAG, "onMaskTextureFrame() threw", t)
            target?.let { releaseOrCloseMaskHardwareBuffer(it) }
        } finally {
            try { frame.release() } catch (t: Throwable) { Log.w(TAG, "frame.release() threw", t) }
        }
    }

    private fun drainSurfaceOutputMask(reader: ImageReader) {
        // Check mask-output ownership capacity BEFORE acquiring: acquiring while prior mask
        // Images are still open downstream is what drives the reader past maxImages and throws
        // IllegalStateException("maxImages has already been acquired").
        if (maskOutputInFlightCount.get() >= MAX_MASK_OUTPUT_IMAGES_IN_FLIGHT) {
            logMaskOutputCapacityFullThrottled()
            return
        }
        var image: Image? = null
        var ownership: SurfaceMaskOwnership? = null
        var delivered = false
        try {
            image = reader.acquireLatestImage() ?: return
            val buffer = image.hardwareBuffer
            if (buffer == null) {
                return
            }
            val timestampUs = image.timestamp / 1_000L
            recordMaskLatencyOnGlWorker(timestampUs)
            ownership = SurfaceMaskOwnership(image, buffer)
            logSurfaceOutputMaskStatsIfNeeded(image, timestampUs)
            maskOutputInFlightCount.incrementAndGet()
            onGpuMask(buffer, image.width, image.height, timestampUs, { ownership?.close() }, -1)
            delivered = true
            image = null
        } catch (t: Throwable) {
            Log.e(TAG, "drainSurfaceOutputMask() threw", t)
        } finally {
            if (!delivered) {
                ownership?.close()
            }
            try { image?.close() } catch (_: Throwable) {}
        }
    }

    /**
     * Counts every mask-output capacity skip and logs only the first
     * [MASK_OUTPUT_CAPACITY_LOG_FIRST_N] plus one in every
     * [MASK_OUTPUT_CAPACITY_LOG_EVERY_N]; the aggregate is reported by the close() summary.
     */
    private fun logMaskOutputCapacityFullThrottled() {
        val count = maskOutputCapacityFullCount.incrementAndGet()
        if (count <= MASK_OUTPUT_CAPACITY_LOG_FIRST_N || count % MASK_OUTPUT_CAPACITY_LOG_EVERY_N == 0L) {
            Log.w(
                TAG,
                "drainSurfaceOutputMask() skipped: mask output capacity full " +
                    "(inFlight=${maskOutputInFlightCount.get()}/$MAX_MASK_OUTPUT_IMAGES_IN_FLIGHT " +
                    "count=$count)",
            )
        }
    }

    /** Returns one mask-output permit; floors at 0 so a late close() after [close] never goes
     *  negative. Then schedules a coalesced retry so an already-buffered reader image (which
     *  will not re-trigger onImageAvailableListener) still gets drained.
     */
    private fun releaseMaskOutputSlotAndMaybeRetryDrain() {
        while (true) {
            val current = maskOutputInFlightCount.get()
            if (current <= 0) break
            if (maskOutputInFlightCount.compareAndSet(current, current - 1)) break
        }
        scheduleMaskOutputDrainRetry()
    }

    /**
     * Posts a single coalesced retry of [drainSurfaceOutputMask] to the GL handler: this mirrors
     * the camera capacity retry ([onInputCapacityAvailable]) but is local to the pipeline, since
     * releasing a mask-output slot does not by itself make the reader's
     * onImageAvailableListener fire again for an image it already delivered.
     */
    private fun scheduleMaskOutputDrainRetry() {
        if (isClosed.get() || !isOpen.get()) return
        if (maskSurfaceReader == null) return
        if (!maskOutputRetryScheduled.compareAndSet(false, true)) return
        val handler = glHandler
        if (handler == null) {
            maskOutputRetryScheduled.set(false)
            return
        }
        val posted = try {
            handler.post {
                maskOutputRetryScheduled.set(false)
                val currentReader = maskSurfaceReader
                if (!isClosed.get() && isOpen.get() && currentReader != null) {
                    drainSurfaceOutputMask(currentReader)
                }
            }
        } catch (t: Throwable) {
            false
        }
        if (!posted) {
            maskOutputRetryScheduled.set(false)
        }
    }

    /**
     * Logs raw stats for the first [SURFACE_MASK_STATS_MAX_LOGS] acquired surface-output mask
     * Images, sampling plane[0] cheaply when it is CPU-readable. Bounded and diagnostic-only:
     * never throws and never influences mask delivery.
     */
    private fun logSurfaceOutputMaskStatsIfNeeded(image: Image, timestampUs: Long) {
        if (surfaceMaskStatsLoggedCount >= SURFACE_MASK_STATS_MAX_LOGS) return
        surfaceMaskStatsLoggedCount += 1
        try {
            val planes = image.planes
            val planeCount = planes.size
            if (planeCount == 0) {
                Log.i(
                    TAG,
                    "ANDROID_GREENSCREEN_GPU_PIPELINE_SURFACE_MASK_STATS " +
                        "width=${image.width} height=${image.height} format=${image.format} " +
                        "planes=0 timestampUs=$timestampUs note=no_planes",
                )
                return
            }
            val plane = planes[0]
            val buffer = plane.buffer
            val rowStride = plane.rowStride
            val pixelStride = plane.pixelStride
            val bufferLimit = buffer.limit()
            val width = image.width
            val height = image.height
            var sampleCount = 0
            var min = Int.MAX_VALUE
            var max = Int.MIN_VALUE
            var sum = 0L
            rowLoop@ for (row in 0 until height) {
                val rowOffset = row * rowStride
                for (col in 0 until width) {
                    if (sampleCount >= SURFACE_MASK_STATS_MAX_SAMPLES) break@rowLoop
                    val offset = rowOffset + col * pixelStride
                    if (offset < 0 || offset >= bufferLimit) break@rowLoop
                    val value = buffer.get(offset).toInt() and 0xFF
                    if (value < min) min = value
                    if (value > max) max = value
                    sum += value
                    sampleCount += 1
                }
            }
            val mean = if (sampleCount > 0) sum.toDouble() / sampleCount else 0.0
            val minLogged = if (sampleCount > 0) min else 0
            val maxLogged = if (sampleCount > 0) max else 0
            Log.i(
                TAG,
                "ANDROID_GREENSCREEN_GPU_PIPELINE_SURFACE_MASK_STATS " +
                    "width=$width height=$height format=${image.format} planes=$planeCount " +
                    "timestampUs=$timestampUs sampleCount=$sampleCount min=$minLogged " +
                    "max=$maxLogged mean=$mean rowStride=$rowStride pixelStride=$pixelStride " +
                    "bufferLimit=$bufferLimit",
            )
        } catch (t: Throwable) {
            Log.w(
                TAG,
                "ANDROID_GREENSCREEN_GPU_PIPELINE_SURFACE_MASK_STATS read_failed " +
                    "timestampUs=$timestampUs error=${t.javaClass.simpleName}:${t.message}",
            )
        }
    }

    /** Tears down the graph then the bridge. Idempotent and never throws. */
    @Synchronized
    fun close() {
        if (!isClosed.compareAndSet(false, true)) return
        isOpen.set(false)
        // Late MediaPipe release callbacks after this point still run
        // InFlightInput.release(): the bridge ignores releases once closed and
        // the permit decrement floors at 0, so resetting here is safe.
        inputInFlightCount.set(0)
        closeMaskBufferPool()
        runOnGlWorkerBlocking("close", timeoutMs = 1500L) {
            logSummaryOnGlWorker()
            val session = graphSession
            graphSession = null
            val reader = maskSurfaceReader
            maskSurfaceReader = null
            val bridge = textureBridge
            textureBridge = null
            try {
                session?.setMaskTextureCallback(null)
                session?.close()
            } catch (t: Throwable) {
                Log.w(TAG, "close() graph session teardown threw", t)
            }
            try {
                reader?.setOnImageAvailableListener(null, null)
                reader?.close()
            } catch (t: Throwable) {
                Log.w(TAG, "close() mask surface reader teardown threw", t)
            }
            try {
                bridge?.close()
            } catch (t: Throwable) {
                Log.w(TAG, "close() texture bridge teardown threw", t)
            }
            true
        }
        val thread = glThread
        glHandler = null
        glThread = null
        try {
            thread?.quitSafely()
            thread?.join(500)
        } catch (_: Throwable) {
        }
    }

    private fun recordMaskLatencyOnGlWorker(timestampUs: Long) {
        maskFrameCount += 1
        val startNs = submitStartNsByTimestampUs.remove(timestampUs)
        if (startNs == null) {
            return
        }
        val latencyMs = (System.nanoTime() - startNs) / 1_000_000L
        totalMaskLatencyMs += latencyMs
        if (latencyMs < minMaskLatencyMs) minMaskLatencyMs = latencyMs
        if (latencyMs > maxMaskLatencyMs) maxMaskLatencyMs = latencyMs
        if (latencyMs > 50L) slowMaskOver50Ms += 1
        if (latencyMs > 100L) slowMaskOver100Ms += 1
        if (latencyMs > 250L) slowMaskOver250Ms += 1
        if (latencyMs > 1000L) slowMaskOver1000Ms += 1
        if (maskFrameCount > WARMUP_MASK_EXCLUSION_COUNT) {
            steadyMaskFrameCount += 1
            totalSteadyMaskLatencyMs += latencyMs
            if (latencyMs < minSteadyMaskLatencyMs) minSteadyMaskLatencyMs = latencyMs
            if (latencyMs > maxSteadyMaskLatencyMs) maxSteadyMaskLatencyMs = latencyMs
        }
    }

    private fun recordMaskCopyLatencyOnGlWorker(copyStartNs: Long) {
        val latencyMs = (System.nanoTime() - copyStartNs) / 1_000_000L
        maskCopyFrameCount += 1
        totalMaskCopyLatencyMs += latencyMs
        if (latencyMs > maxMaskCopyLatencyMs) maxMaskCopyLatencyMs = latencyMs
    }

    private fun recordInputReleaseLatency(submitStartNs: Long) {
        val latencyMs = (System.nanoTime() - submitStartNs) / 1_000_000L
        synchronized(inputReleaseTelemetryLock) {
            inputReleaseFrameCount += 1
            totalInputReleaseLatencyMs += latencyMs
            if (latencyMs > maxInputReleaseLatencyMs) maxInputReleaseLatencyMs = latencyMs
            if (latencyMs > 50L) slowInputReleaseOver50Ms += 1
            if (latencyMs > 100L) slowInputReleaseOver100Ms += 1
            if (latencyMs > 250L) slowInputReleaseOver250Ms += 1
            if (latencyMs > 1000L) slowInputReleaseOver1000Ms += 1
        }
    }

    private fun logSummaryOnGlWorker() {
        val meanMs = if (maskFrameCount > 0) totalMaskLatencyMs / maskFrameCount else 0
        val minMs = if (minMaskLatencyMs == Long.MAX_VALUE) 0 else minMaskLatencyMs
        val steadyMeanMs =
            if (steadyMaskFrameCount > 0) totalSteadyMaskLatencyMs / steadyMaskFrameCount else 0
        val steadyMinMs = if (minSteadyMaskLatencyMs == Long.MAX_VALUE) 0 else minSteadyMaskLatencyMs
        val meanCopyMs = if (maskCopyFrameCount > 0) totalMaskCopyLatencyMs / maskCopyFrameCount else 0
        // Read before close() nulls maskSurfaceReader: logSummaryOnGlWorker() runs first in the
        // close() GL-worker block. Reflects the branch actually selected in openOnGlWorker().
        val maskOutputMode = if (maskSurfaceReader != null) "surface_output_image_reader" else "texture_callback"
        val inputReleaseSnapshot = synchronized(inputReleaseTelemetryLock) {
            InputReleaseTelemetrySnapshot(
                count = inputReleaseFrameCount,
                meanMs = if (inputReleaseFrameCount > 0) {
                    totalInputReleaseLatencyMs / inputReleaseFrameCount
                } else {
                    0
                },
                maxMs = maxInputReleaseLatencyMs,
                slowOver50Ms = slowInputReleaseOver50Ms,
                slowOver100Ms = slowInputReleaseOver100Ms,
                slowOver250Ms = slowInputReleaseOver250Ms,
                slowOver1000Ms = slowInputReleaseOver1000Ms,
            )
        }
        Log.i(
            TAG,
            "ANDROID_GREENSCREEN_GPU_PIPELINE_SUMMARY " +
                "maskOutputMode=$maskOutputMode " +
                "submitted=$submittedFrameCount masks=$maskFrameCount " +
                "meanMaskLatencyMs=$meanMs minMaskLatencyMs=$minMs " +
                "maxMaskLatencyMs=$maxMaskLatencyMs pending=${submitStartNsByTimestampUs.size} " +
                "inputInFlight=${inputInFlightCount.get()} maxInputInFlight=$MAX_INPUT_IN_FLIGHT " +
                "inputDropInFlight=${inputDropInFlightCount.get()} " +
                "maskOutputInFlight=${maskOutputInFlightCount.get()} " +
                "maxMaskOutputInFlight=$MAX_MASK_OUTPUT_IMAGES_IN_FLIGHT " +
                "maskOutputCapacityFull=${maskOutputCapacityFullCount.get()} " +
                "resolveFailedOrNoFreeSlot=$resolveFailedCount sendFailed=$sendFailedCount " +
                "warmupExcluded=$WARMUP_MASK_EXCLUSION_COUNT steadyMasks=$steadyMaskFrameCount " +
                "meanSteadyMaskLatencyMs=$steadyMeanMs minSteadyMaskLatencyMs=$steadyMinMs " +
                "maxSteadyMaskLatencyMs=$maxSteadyMaskLatencyMs " +
                "slowMaskOver50Ms=$slowMaskOver50Ms slowMaskOver100Ms=$slowMaskOver100Ms " +
                "slowMaskOver250Ms=$slowMaskOver250Ms slowMaskOver1000Ms=$slowMaskOver1000Ms " +
                "inputReleaseCount=${inputReleaseSnapshot.count} " +
                "meanInputReleaseLatencyMs=${inputReleaseSnapshot.meanMs} " +
                "maxInputReleaseLatencyMs=${inputReleaseSnapshot.maxMs} " +
                "slowInputReleaseOver50Ms=${inputReleaseSnapshot.slowOver50Ms} " +
                "slowInputReleaseOver100Ms=${inputReleaseSnapshot.slowOver100Ms} " +
                "slowInputReleaseOver250Ms=${inputReleaseSnapshot.slowOver250Ms} " +
                "slowInputReleaseOver1000Ms=${inputReleaseSnapshot.slowOver1000Ms} " +
                "maskCopyCount=$maskCopyFrameCount meanMaskCopyLatencyMs=$meanCopyMs " +
                "maxMaskCopyLatencyMs=$maxMaskCopyLatencyMs " +
                "maskCopyAcquireFenceEnabled=${enableMaskBufferPool && ENABLE_OUTPUT_COPY_ACQUIRE_FENCE} " +
                "maskPoolEnabled=$enableMaskBufferPool maskPoolSize=${maskBufferPoolSize()} " +
                "maskPoolCreated=$pooledMaskCreateCount maskPoolReused=$pooledMaskReuseCount " +
                "maskPoolUnavailable=$pooledMaskUnavailableCount",
        )
    }

    private data class MaskBufferSlot(
        val buffer: HardwareBuffer,
        val width: Int,
        val height: Int,
        var inUse: Boolean,
    )

    private data class InputReleaseTelemetrySnapshot(
        val count: Long,
        val meanMs: Long,
        val maxMs: Long,
        val slowOver50Ms: Long,
        val slowOver100Ms: Long,
        val slowOver250Ms: Long,
        val slowOver1000Ms: Long,
    )

    private inner class SurfaceMaskOwnership(
        private val image: Image,
        private val hardwareBuffer: HardwareBuffer,
    ) {
        private val closed = AtomicBoolean(false)

        /**
         * Runs once, from the render/compositor release callback (any thread). Decrements
         * [maskOutputInFlightCount] exactly once and, since that release does not itself
         * re-trigger the reader's onImageAvailableListener, schedules a retry so a mask Image
         * already buffered in the reader still gets drained.
         */
        fun close() {
            if (!closed.compareAndSet(false, true)) return
            try { hardwareBuffer.close() } catch (_: Throwable) {}
            try { image.close() } catch (_: Throwable) {}
            releaseMaskOutputSlotAndMaybeRetryDrain()
        }
    }

    private fun acquireMaskHardwareBuffer(
        bridge: AndroidGreenScreenGpuTextureBridge,
        width: Int,
        height: Int,
    ): HardwareBuffer? {
        if (!enableMaskBufferPool) {
            return bridge.createMaskHardwareBuffer(width, height)
        }
        synchronized(maskBufferPoolLock) {
            if (maskBufferPoolClosing) return null
            val reusable = maskBufferPool.firstOrNull {
                !it.inUse && it.width == width && it.height == height
            }
            if (reusable != null) {
                reusable.inUse = true
                pooledMaskReuseCount += 1
                return reusable.buffer
            }
            if (maskBufferPool.size >= MASK_BUFFER_POOL_SIZE) {
                pooledMaskUnavailableCount += 1
                return null
            }
        }
        val created = bridge.createMaskHardwareBuffer(width, height) ?: return null
        synchronized(maskBufferPoolLock) {
            if (maskBufferPoolClosing) {
                try { created.close() } catch (_: Throwable) {}
                return null
            }
            maskBufferPool.add(MaskBufferSlot(created, width, height, inUse = true))
            pooledMaskCreateCount += 1
        }
        return created
    }

    private fun releaseMaskHardwareBuffer(hardwareBuffer: HardwareBuffer) {
        var closeNow = false
        synchronized(maskBufferPoolLock) {
            val slot = maskBufferPool.firstOrNull { it.buffer === hardwareBuffer }
            if (slot == null || maskBufferPoolClosing) {
                closeNow = true
                if (slot != null) {
                    maskBufferPool.remove(slot)
                }
            } else {
                slot.inUse = false
            }
        }
        if (closeNow) {
            try { hardwareBuffer.close() } catch (_: Throwable) {}
        }
    }

    private fun releaseOrCloseMaskHardwareBuffer(hardwareBuffer: HardwareBuffer) {
        if (enableMaskBufferPool) {
            releaseMaskHardwareBuffer(hardwareBuffer)
        } else {
            try { hardwareBuffer.close() } catch (_: Throwable) {}
        }
    }

    private fun notifyCameraBufferConsumedQuietly(onConsumed: () -> Unit) {
        try {
            onConsumed()
        } catch (t: Throwable) {
            Log.w(TAG, "camera buffer onConsumed callback threw", t)
        }
    }

    /**
     * One acquired in-flight input: the bounded permit taken by
     * [tryAcquireInFlightInput] plus, once [attachResolvedTexture] ran on the
     * GL worker, the native pool texture MediaPipe owns until its
     * TextureReleaseCallback fires. [release] returns both exactly once and
     * is safe from any thread (MediaPipe's GL thread, the GL worker, the
     * camera thread) and after [close]: the bridge ignores a release once
     * closed and the permit decrement floors at 0.
     */
    private inner class InFlightInput {
        @Volatile private var bridge: AndroidGreenScreenGpuTextureBridge? = null
        @Volatile private var textureName: Int = 0
        @Volatile private var submitStartNs: Long = 0L
        private val released = AtomicBoolean(false)

        fun attachResolvedTexture(
            bridge: AndroidGreenScreenGpuTextureBridge,
            textureName: Int,
            submitStartNs: Long,
        ) {
            this.bridge = bridge
            this.textureName = textureName
            this.submitStartNs = submitStartNs
        }

        fun release(fromMediaPipe: Boolean) {
            if (!released.compareAndSet(false, true)) return
            if (fromMediaPipe && submitStartNs != 0L) {
                recordInputReleaseLatency(submitStartNs)
            }
            val name = textureName
            if (name != 0) {
                bridge?.releaseResolvedTexture(name)
            }
            releaseInFlightPermit()
        }
    }

    /**
     * True only when the pipeline is open, not closed, has a free [MAX_INPUT_IN_FLIGHT] permit,
     * and has room under [MAX_MASK_OUTPUT_IMAGES_IN_FLIGHT]. Lets a camera source check capacity
     * before it acquires a frame, instead of acquiring speculatively and discovering rejection
     * only after it already owns the buffer. The mask-output check prevents feeding more camera
     * frames into MediaPipe while the render/compositor path is still holding too many output
     * mask Images, which is what starves the diagnostic mask surface ImageReader.
     */
    fun canAcceptCameraInput(): Boolean {
        return !isClosed.get() && isOpen.get() &&
            inputInFlightCount.get() < MAX_INPUT_IN_FLIGHT &&
            maskOutputInFlightCount.get() < MAX_MASK_OUTPUT_IMAGES_IN_FLIGHT
    }

    /**
     * Returns a point-in-time snapshot of runtime diagnostics for this pipeline.
     * Safe to call while running or after stop. Does not mutate state or block on media work.
     */
    fun diagnosticsSnapshot(): Map<String, Any?> {
        val meanMs = if (maskFrameCount > 0) totalMaskLatencyMs / maskFrameCount else 0L
        val minMs = if (minMaskLatencyMs == Long.MAX_VALUE) 0L else minMaskLatencyMs
        val steadyMeanMs =
            if (steadyMaskFrameCount > 0) totalSteadyMaskLatencyMs / steadyMaskFrameCount else 0L
        val steadyMinMs =
            if (minSteadyMaskLatencyMs == Long.MAX_VALUE) 0L else minSteadyMaskLatencyMs
        val meanCopyMs =
            if (maskCopyFrameCount > 0) totalMaskCopyLatencyMs / maskCopyFrameCount else 0L
        val maskOutputMode =
            if (maskSurfaceReader != null) "surface_output_image_reader" else "texture_callback"
        val inputReleaseSnapshot = synchronized(inputReleaseTelemetryLock) {
            InputReleaseTelemetrySnapshot(
                count = inputReleaseFrameCount,
                meanMs = if (inputReleaseFrameCount > 0) {
                    totalInputReleaseLatencyMs / inputReleaseFrameCount
                } else {
                    0L
                },
                maxMs = maxInputReleaseLatencyMs,
                slowOver50Ms = slowInputReleaseOver50Ms,
                slowOver100Ms = slowInputReleaseOver100Ms,
                slowOver250Ms = slowInputReleaseOver250Ms,
                slowOver1000Ms = slowInputReleaseOver1000Ms,
            )
        }

        val snapshot = LinkedHashMap<String, Any?>()
        snapshot["proofLevel"] = "android_mediapipe_gpu_texture_callback_v1"
        snapshot["matteSource"] = "mediapipe_gpu_selfie_segmentation"
        snapshot["backend"] = "mediapipe_gpu_graph"
        snapshot["maskOutputMode"] = maskOutputMode
        snapshot["widthPx"] = widthPx
        snapshot["heightPx"] = heightPx
        snapshot["modelSelection"] = modelSelection
        snapshot["isOpen"] = isOpen.get()
        snapshot["isClosed"] = isClosed.get()
        snapshot["lastRejectReason"] = lastRejectReason
        snapshot["submittedFrameCount"] = submittedFrameCount
        snapshot["maskFrameCount"] = maskFrameCount
        snapshot["steadyMaskFrameCount"] = steadyMaskFrameCount
        snapshot["meanMaskLatencyMs"] = meanMs
        snapshot["minMaskLatencyMs"] = minMs
        snapshot["maxMaskLatencyMs"] = maxMaskLatencyMs
        snapshot["meanSteadyMaskLatencyMs"] = steadyMeanMs
        snapshot["minSteadyMaskLatencyMs"] = steadyMinMs
        snapshot["maxSteadyMaskLatencyMs"] = maxSteadyMaskLatencyMs
        snapshot["slowMaskOver50Ms"] = slowMaskOver50Ms
        snapshot["slowMaskOver100Ms"] = slowMaskOver100Ms
        snapshot["slowMaskOver250Ms"] = slowMaskOver250Ms
        snapshot["slowMaskOver1000Ms"] = slowMaskOver1000Ms
        snapshot["inputInFlight"] = inputInFlightCount.get()
        snapshot["maxInputInFlight"] = MAX_INPUT_IN_FLIGHT
        snapshot["inputDropInFlight"] = inputDropInFlightCount.get()
        snapshot["maskOutputInFlight"] = maskOutputInFlightCount.get()
        snapshot["maxMaskOutputInFlight"] = MAX_MASK_OUTPUT_IMAGES_IN_FLIGHT
        snapshot["maskOutputCapacityFull"] = maskOutputCapacityFullCount.get()
        snapshot["resolveFailedOrNoFreeSlot"] = resolveFailedCount
        snapshot["sendFailed"] = sendFailedCount
        snapshot["inputReleaseCount"] = inputReleaseSnapshot.count
        snapshot["meanInputReleaseLatencyMs"] = inputReleaseSnapshot.meanMs
        snapshot["maxInputReleaseLatencyMs"] = inputReleaseSnapshot.maxMs
        snapshot["slowInputReleaseOver50Ms"] = inputReleaseSnapshot.slowOver50Ms
        snapshot["slowInputReleaseOver100Ms"] = inputReleaseSnapshot.slowOver100Ms
        snapshot["slowInputReleaseOver250Ms"] = inputReleaseSnapshot.slowOver250Ms
        snapshot["slowInputReleaseOver1000Ms"] = inputReleaseSnapshot.slowOver1000Ms
        snapshot["maskCopyCount"] = maskCopyFrameCount
        snapshot["meanMaskCopyLatencyMs"] = meanCopyMs
        snapshot["maxMaskCopyLatencyMs"] = maxMaskCopyLatencyMs
        snapshot["maskCopyAcquireFenceEnabled"] = enableMaskBufferPool && ENABLE_OUTPUT_COPY_ACQUIRE_FENCE
        snapshot["maskPoolEnabled"] = enableMaskBufferPool
        snapshot["maskPoolSize"] = maskBufferPoolSize()
        snapshot["maskPoolCreated"] = pooledMaskCreateCount
        snapshot["maskPoolReused"] = pooledMaskReuseCount
        snapshot["maskPoolUnavailable"] = pooledMaskUnavailableCount
        snapshot["warmupExcluded"] = WARMUP_MASK_EXCLUSION_COUNT
        snapshot["pendingMaskSubmissions"] = submitStartNsByTimestampUs.size
        return snapshot
    }

    /** Takes one of the [MAX_INPUT_IN_FLIGHT] permits, or returns null when all are in use. */
    private fun tryAcquireInFlightInput(): InFlightInput? {
        while (true) {
            val current = inputInFlightCount.get()
            if (current >= MAX_INPUT_IN_FLIGHT) return null
            if (inputInFlightCount.compareAndSet(current, current + 1)) return InFlightInput()
        }
    }

    /** Returns one permit; floors at 0 so a late release after [close] never goes negative. */
    private fun releaseInFlightPermit() {
        while (true) {
            val current = inputInFlightCount.get()
            if (current <= 0) return
            if (inputInFlightCount.compareAndSet(current, current - 1)) {
                notifyInputCapacityAvailableQuietly()
                return
            }
        }
    }

    private fun notifyInputCapacityAvailableQuietly() {
        val callback = onInputCapacityAvailable ?: return
        try {
            callback()
        } catch (t: Throwable) {
            Log.w(TAG, "onInputCapacityAvailable() callback threw", t)
        }
    }

    /**
     * Counts every "input in flight" drop and logs only the first
     * [INPUT_DROP_LOG_FIRST_N] plus one in every [INPUT_DROP_LOG_EVERY_N];
     * the aggregate is reported by the close() summary.
     */
    private fun logInputDropThrottled(label: String) {
        val drops = inputDropInFlightCount.incrementAndGet()
        if (drops <= INPUT_DROP_LOG_FIRST_N || drops % INPUT_DROP_LOG_EVERY_N == 0L) {
            Log.w(
                TAG,
                "$label dropped: input in flight " +
                    "(inFlight=${inputInFlightCount.get()}/$MAX_INPUT_IN_FLIGHT drops=$drops)",
            )
        }
    }

    private fun closeMaskBufferPool() {
        val toClose = ArrayList<HardwareBuffer>()
        synchronized(maskBufferPoolLock) {
            maskBufferPoolClosing = true
            val iterator = maskBufferPool.iterator()
            while (iterator.hasNext()) {
                val slot = iterator.next()
                if (!slot.inUse) {
                    toClose.add(slot.buffer)
                    iterator.remove()
                }
            }
        }
        toClose.forEach { buffer ->
            try { buffer.close() } catch (_: Throwable) {}
        }
    }

    private fun maskBufferPoolSize(): Int {
        synchronized(maskBufferPoolLock) {
            return maskBufferPool.size
        }
    }

    private fun postToGlWorker(label: String, block: () -> Unit): Boolean {
        val handler = glHandler ?: run {
            lastRejectReason = "gl_worker_missing_$label"
            return false
        }
        return try {
            handler.post(block)
        } catch (t: Throwable) {
            lastRejectReason = "gl_worker_post_threw_${label}_${t.javaClass.simpleName}"
            false
        }
    }

    private fun runOnGlWorkerBlocking(
        label: String,
        timeoutMs: Long,
        block: () -> Boolean,
    ): Boolean {
        val handler = glHandler ?: run {
            lastRejectReason = "gl_worker_missing_$label"
            return false
        }
        if (Thread.currentThread() === handler.looper.thread) {
            return try {
                block()
            } catch (t: Throwable) {
                lastRejectReason = "gl_worker_inline_threw_${label}_${t.javaClass.simpleName}"
                Log.e(TAG, "$label inline GL worker block threw", t)
                false
            }
        }

        val done = CountDownLatch(1)
        var result = false
        val posted = try {
            handler.post {
                try {
                    result = block()
                } catch (t: Throwable) {
                    lastRejectReason = "gl_worker_block_threw_${label}_${t.javaClass.simpleName}"
                    Log.e(TAG, "$label GL worker block threw", t)
                    result = false
                } finally {
                    done.countDown()
                }
            }
        } catch (t: Throwable) {
            lastRejectReason = "gl_worker_post_threw_${label}_${t.javaClass.simpleName}"
            false
        }
        if (!posted) return false
        return try {
            val completed = if (timeoutMs <= 0L) {
                done.await()
                true
            } else {
                done.await(timeoutMs, TimeUnit.MILLISECONDS)
            }
            if (completed) {
                result
            } else {
                lastRejectReason = "gl_worker_timeout_$label"
                Log.w(TAG, "$label timed out waiting for GL worker")
                false
            }
        } catch (t: InterruptedException) {
            Thread.currentThread().interrupt()
            lastRejectReason = "gl_worker_wait_interrupted_$label"
            false
        } catch (t: Throwable) {
            lastRejectReason = "gl_worker_wait_threw_${label}_${t.javaClass.simpleName}"
            false
        }
    }
}
