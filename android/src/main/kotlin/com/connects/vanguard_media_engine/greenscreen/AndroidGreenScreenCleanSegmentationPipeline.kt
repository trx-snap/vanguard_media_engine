package com.connects.vanguard_media_engine.greenscreen

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.Image
import android.os.SystemClock
import android.util.Log
import com.connects.vanguard_media_engine.duet.AndroidDuetMaskTemporalSmoother
import com.connects.vanguard_media_engine.duet.AndroidDuetSegmentationBackendSelector
import com.connects.vanguard_media_engine.duet.AndroidDuetSegmentationFrame
import com.connects.vanguard_media_engine.duet.DuetSegmentationBackend
import com.connects.vanguard_media_engine.duet.DuetSegmentationFailureReason
import com.connects.vanguard_media_engine.duet.DuetSegmentationMaskFormat
import com.connects.vanguard_media_engine.duet.DuetSegmentationOutcome
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.ByteBufferExtractor
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenter
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenterResult
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.SegmentationMask
import com.google.mlkit.vision.segmentation.Segmenter
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.LinkedHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt

/**
 * Independent, tracked-assets-only segmentation pipeline for the Green Screen Camera2 path
 * ([AndroidGreenScreenCamera2Source]).
 *
 * Implements the same production ladder policy as the Duet green-screen adapter (mediapipe_cpu ->
 * mlkit -> none), reusing [AndroidDuetSegmentationBackendSelector] for the ladder/model-asset
 * decision only. It deliberately does NOT reuse the Duet backend classes
 * ([com.connects.vanguard_media_engine.duet.AndroidDuetSegmentationBackend] and its
 * implementations), because those take an [androidx.camera.core.ImageProxy]. Physical proof on
 * SM-A566B showed wrapping a Camera2 [Image] as an [androidx.camera.core.ImageProxy] (via the
 * former `AndroidGreenScreenImageProxyAdapter`) makes CameraX/ML Kit's ImageProxy handling recurse
 * into a native StackOverflowError. This pipeline instead runs small, backend-specific copies of
 * the MediaPipe CPU and ML Kit segmentation logic directly against the Camera2 `Image`, never
 * constructing or touching an ImageProxy. It never opens
 * [AndroidGreenScreenMediaPipeGpuGraphSession], `mediapipe_jni`, or `assets/mediapipe/...binarypb`.
 *
 * Single in-flight frame gate: at most one frame is being segmented at a time, matching
 * [com.connects.vanguard_media_engine.duet.AndroidDuetGreenScreenAdapter]'s drop-stale policy.
 * Frames submitted while busy are rejected outright (never queued), favoring live latency over
 * backlog.
 */
class AndroidGreenScreenCleanSegmentationPipeline(
    private val context: Context,
    /** Called with each owned CPU mask frame. May fire off the calling thread. */
    private val onMask: (AndroidDuetSegmentationFrame) -> Unit,
) {
    companion object {
        private const val TAG = "GreenScreenCleanSegPipe"

        /** First N masks are warmup (cold model / cache) and excluded from the "steady" latency stats. */
        private const val WARMUP_MASK_EXCLUSION_COUNT = 4L
    }

    private val selector = AndroidDuetSegmentationBackendSelector(context)

    /**
     * Single owned temporal smoother between backend output and [onMask] delivery.
     * Restored to the engineering/Duet default current weight (166, approximating
     * current=0.65 / previous=0.35) and DEFAULT_MAX_GAP_MS (250ms).
     */
    private val temporalSmoother = AndroidDuetMaskTemporalSmoother(
        currentWeightQ8 = AndroidDuetMaskTemporalSmoother.DEFAULT_CURRENT_WEIGHT_Q8,
        maxGapMs = AndroidDuetMaskTemporalSmoother.DEFAULT_MAX_GAP_MS,
    )

    private val lock = Any()

    /** Guarded by [lock] for writes; volatile so reads (diagnostics, frame submission) never block. */
    @Volatile private var activeBackend: CleanCameraImageSegmentationBackend? = null
    @Volatile private var currentBackendId: String = DuetSegmentationBackend.NONE

    private val isOpen = AtomicBoolean(false)
    private val isClosed = AtomicBoolean(false)
    private val inFlight = AtomicBoolean(false)

    @Volatile
    var lastRejectReason: String = "none"
        private set

    @Volatile private var submittedFrameCount: Long = 0
    @Volatile private var maskFrameCount: Long = 0
    @Volatile private var totalMaskLatencyMs: Long = 0
    @Volatile private var maxMaskLatencyMs: Long = 0
    @Volatile private var steadyMaskFrameCount: Long = 0
    @Volatile private var totalSteadyMaskLatencyMs: Long = 0
    @Volatile private var maxSteadyMaskLatencyMs: Long = 0
    @Volatile private var degradeCount: Long = 0
    @Volatile private var lastDegradeReason: String? = null

    /**
     * Opens the primary backend (mediapipe_cpu, or mlkit if the model asset is unavailable),
     * walking the ladder downward on open() failure. Returns false only if every rung fails to
     * open (mediapipe_gpu / raw_tflite_gpu are never tried — see the class doc). Blocks the
     * calling thread until the primary backend is ready or the ladder is exhausted, matching
     * [CleanCameraImageSegmentationBackend.open]'s contract.
     */
    fun open(): Boolean {
        if (isClosed.get()) {
            Log.w(TAG, "open() rejected: pipeline already closed")
            return false
        }
        if (!isOpen.compareAndSet(false, true)) {
            Log.w(TAG, "open() ignored: already open")
            return false
        }
        val opened = synchronized(lock) {
            var rung: String? = selector.primaryBackendId()
            var result: CleanCameraImageSegmentationBackend? = null
            while (rung != null) {
                val candidate = openRungLocked(rung)
                if (candidate != null) {
                    result = candidate
                    break
                }
                val failedRung = rung
                degradeCount += 1
                lastDegradeReason = DuetSegmentationFailureReason.initFailed(failedRung)
                rung = selector.nextBackendId(failedRung)
            }
            if (result != null) {
                activeBackend = result
                currentBackendId = result.backendId
            }
            result
        }
        if (opened == null) {
            isOpen.set(false)
            lastRejectReason = "no_backend_available"
            Log.w(TAG, "open() failed: no segmentation backend could be opened")
            return false
        }
        Log.i(TAG, "ANDROID_GREENSCREEN_CLEAN_SEGMENTATION_PIPELINE_OPENED backend=${opened.backendId}")
        return true
    }

    /** True when a frame submitted right now would be accepted (open, not closed, not busy). */
    fun canAcceptCameraInput(): Boolean =
        !isClosed.get() && isOpen.get() && !inFlight.get()

    /**
     * Submits [image] (a Camera2 `Image`, owned by the caller) to the active backend for
     * segmentation at [timestampMs], rotated by [rotationDegrees]. Returns false without taking
     * ownership when closed/busy/unopened/backend-exhausted; the caller must close its own image
     * immediately in that case. When accepted (true), [onConsumed] fires exactly once after the
     * backend's completion (success, skip, failure, or a synchronous throw from
     * [CleanCameraImageSegmentationBackend.segment]), so the caller can safely close [image] at
     * that point and not before.
     */
    fun processImageAsync(
        image: Image,
        rotationDegrees: Int,
        timestampMs: Long,
        onConsumed: () -> Unit,
    ): Boolean {
        if (isClosed.get() || !isOpen.get()) {
            lastRejectReason = "pipeline_not_open"
            return false
        }
        if (!inFlight.compareAndSet(false, true)) {
            lastRejectReason = "input_in_flight"
            return false
        }
        val backend = synchronized(lock) { activeBackend }
        if (backend == null) {
            inFlight.set(false)
            lastRejectReason = "no_active_backend"
            return false
        }
        lastRejectReason = "none"
        submittedFrameCount += 1

        val consumedOnce = AtomicBoolean(false)
        fun consume() {
            if (consumedOnce.compareAndSet(false, true)) {
                inFlight.set(false)
                try {
                    onConsumed()
                } catch (t: Throwable) {
                    Log.w(TAG, "onConsumed threw: ${t.message}")
                }
            }
        }

        val startElapsedMs = SystemClock.elapsedRealtime()
        try {
            backend.segment(image, rotationDegrees, timestampMs) { outcome ->
                val durationMs = SystemClock.elapsedRealtime() - startElapsedMs
                try {
                    handleOutcome(backend, outcome, durationMs)
                } finally {
                    consume()
                }
            }
        } catch (t: Throwable) {
            val durationMs = SystemClock.elapsedRealtime() - startElapsedMs
            try {
                handleOutcome(
                    backend,
                    DuetSegmentationOutcome.Failure(
                        DuetSegmentationFailureReason.segmentThrew(backend.backendId),
                        "${backend.backendId}.segment() threw: ${t.javaClass.simpleName}: ${t.message}",
                        t,
                    ),
                    durationMs,
                )
            } finally {
                consume()
            }
        }
        return true
    }

    /** Idempotent, never throws. Closes the active backend (if any). */
    fun close() {
        if (!isClosed.compareAndSet(false, true)) return
        isOpen.set(false)
        val backend = synchronized(lock) {
            val b = activeBackend
            activeBackend = null
            b
        }
        try {
            backend?.close()
        } catch (t: Throwable) {
            Log.w(TAG, "close(): ${backend?.backendId}.close() threw: ${t.message}")
        }
        temporalSmoother.reset()
        val meanMs = if (maskFrameCount > 0) totalMaskLatencyMs / maskFrameCount else 0L
        val steadyMeanMs = if (steadyMaskFrameCount > 0) totalSteadyMaskLatencyMs / steadyMaskFrameCount else 0L
        Log.i(
            TAG,
            "ANDROID_GREENSCREEN_CLEAN_SEGMENTATION_PIPELINE_SUMMARY " +
                "finalBackend=$currentBackendId submitted=$submittedFrameCount masks=$maskFrameCount " +
                "meanMaskLatencyMs=$meanMs maxMaskLatencyMs=$maxMaskLatencyMs " +
                "steadyMasks=$steadyMaskFrameCount meanSteadyMaskLatencyMs=$steadyMeanMs " +
                "maxSteadyMaskLatencyMs=$maxSteadyMaskLatencyMs degradeCount=$degradeCount " +
                "lastDegradeReason=$lastDegradeReason",
        )
    }

    /**
     * Returns a point-in-time snapshot of runtime diagnostics. Safe to call while running or after
     * [close]; never mutates state or blocks on media work.
     */
    fun diagnosticsSnapshot(): Map<String, Any?> {
        val meanMs = if (maskFrameCount > 0) totalMaskLatencyMs / maskFrameCount else 0L
        val steadyMeanMs = if (steadyMaskFrameCount > 0) totalSteadyMaskLatencyMs / steadyMaskFrameCount else 0L
        val snapshot = LinkedHashMap<String, Any?>()
        snapshot["proofLevel"] = "android_green_screen_clean_segmentation_pipeline_v1"
        snapshot["backend"] = currentBackendId
        snapshot["currentBackend"] = currentBackendId
        snapshot["isOpen"] = isOpen.get()
        snapshot["isClosed"] = isClosed.get()
        snapshot["lastRejectReason"] = lastRejectReason
        snapshot["submitted"] = submittedFrameCount
        snapshot["submittedFrameCount"] = submittedFrameCount
        snapshot["masks"] = maskFrameCount
        snapshot["maskFrameCount"] = maskFrameCount
        snapshot["steadyMaskFrameCount"] = steadyMaskFrameCount
        snapshot["meanMaskLatencyMs"] = meanMs
        snapshot["meanSteadyMaskLatencyMs"] = steadyMeanMs
        snapshot["maxMaskLatencyMs"] = maxMaskLatencyMs
        snapshot["maxSteadyMaskLatencyMs"] = maxSteadyMaskLatencyMs
        snapshot["degradeCount"] = degradeCount
        snapshot["lastDegradeReason"] = lastDegradeReason
        snapshot["warmupExcluded"] = WARMUP_MASK_EXCLUSION_COUNT
        return snapshot
    }

    private fun handleOutcome(
        backend: CleanCameraImageSegmentationBackend,
        outcome: DuetSegmentationOutcome,
        durationMs: Long,
    ) {
        when (outcome) {
            is DuetSegmentationOutcome.Mask -> {
                recordMaskTelemetry(durationMs)
                try {
                    val rawFrame = outcome.frame
                    val smoothedFrame = temporalSmoother.smooth(rawFrame)
                    onMask(smoothedFrame)
                } catch (t: Throwable) {
                    Log.w(TAG, "onMask threw: ${t.message}")
                }
            }
            is DuetSegmentationOutcome.GpuMask -> {
                // This pipeline never opens a GPU rung (see the class doc), so this is
                // unreachable in practice; fail closed by releasing the buffer instead of ever
                // handing a HardwareBuffer to a caller that only expects CPU masks.
                Log.w(TAG, "unexpected GpuMask outcome from ${backend.backendId}; releasing")
                try {
                    outcome.hardwareBuffer.close()
                } catch (_: Throwable) {}
            }
            is DuetSegmentationOutcome.Skipped -> {
                Log.v(TAG, "frame skipped by ${backend.backendId}: ${outcome.reason}")
            }
            is DuetSegmentationOutcome.Failure -> {
                handleBackendFailure(backend, outcome)
            }
        }
    }

    /**
     * Runtime failure on [backend]: closes it and walks the ladder downward until a rung opens or
     * the ladder is exhausted (activeBackend becomes null; subsequent frames are then rejected
     * with "no_active_backend" rather than crashing the process). Stale backends (already replaced
     * by an earlier failure) are ignored.
     */
    private fun handleBackendFailure(
        backend: CleanCameraImageSegmentationBackend,
        failure: DuetSegmentationOutcome.Failure,
    ) {
        synchronized(lock) {
            if (backend !== activeBackend) {
                Log.d(TAG, "ignoring failure from stale backend ${backend.backendId}: ${failure.reason}")
                return@synchronized
            }
            activeBackend = null
            try {
                backend.close()
            } catch (t: Throwable) {
                Log.w(TAG, "${backend.backendId}.close() threw: ${t.message}")
            }

            var rung: String? = selector.nextBackendId(backend.backendId)
            var replacement: CleanCameraImageSegmentationBackend? = null
            while (rung != null) {
                val candidate = openRungLocked(rung)
                if (candidate != null) {
                    replacement = candidate
                    break
                }
                rung = selector.nextBackendId(rung)
            }

            degradeCount += 1
            lastDegradeReason = failure.reason
            if (replacement != null) {
                activeBackend = replacement
                currentBackendId = replacement.backendId
                Log.w(
                    TAG,
                    "[GreenScreen clean pipeline degraded] ${backend.backendId} -> " +
                        "${replacement.backendId} (${failure.reason}): ${failure.message}",
                )
            } else {
                currentBackendId = DuetSegmentationBackend.NONE
                temporalSmoother.reset()
                Log.w(
                    TAG,
                    "[GreenScreen clean pipeline fallback] ${backend.backendId} -> none " +
                        "(${failure.reason}): ${failure.message}",
                )
            }
        }
    }

    private fun recordMaskTelemetry(durationMs: Long) {
        maskFrameCount += 1
        totalMaskLatencyMs += durationMs
        if (durationMs > maxMaskLatencyMs) maxMaskLatencyMs = durationMs
        if (maskFrameCount > WARMUP_MASK_EXCLUSION_COUNT) {
            steadyMaskFrameCount += 1
            totalSteadyMaskLatencyMs += durationMs
            if (durationMs > maxSteadyMaskLatencyMs) maxSteadyMaskLatencyMs = durationMs
        }
    }

    /**
     * Creates and opens the backend for [rung]; returns null (after closing any partial instance)
     * when unsupported, or construction/open() throws. Must be called with [lock] held. Only
     * `mediapipe_cpu` and `mlkit` are ever constructed — [AndroidDuetSegmentationBackendSelector]
     * never returns `mediapipe_gpu` or `raw_tflite_gpu` from [AndroidDuetSegmentationBackendSelector.primaryBackendId]
     * or the default ladder walked here, so this class is CPU-only by construction.
     */
    private fun openRungLocked(rung: String): CleanCameraImageSegmentationBackend? {
        val instance = when (rung) {
            DuetSegmentationBackend.MEDIAPIPE_CPU ->
                CleanMediaPipeCpuImageSegmentationBackend(context, AndroidDuetSegmentationBackendSelector.MODEL_ASSET_PATH)
            DuetSegmentationBackend.MLKIT -> CleanMlKitImageSegmentationBackend()
            else -> {
                Log.w(TAG, "rung $rung unsupported by this pipeline — skipping")
                null
            }
        } ?: return null
        return try {
            instance.open()
            Log.i(TAG, "backend $rung opened")
            instance
        } catch (t: Throwable) {
            Log.w(TAG, "backend $rung failed to open: ${t.javaClass.simpleName}: ${t.message}", t)
            try {
                instance.close()
            } catch (_: Throwable) {}
            null
        }
    }
}

/**
 * Local seam mirroring [com.connects.vanguard_media_engine.duet.AndroidDuetSegmentationBackend]'s
 * contract, but operating on a raw Camera2 [Image] instead of an [androidx.camera.core.ImageProxy].
 * Wrapping a Camera2 Image as an ImageProxy (the former `AndroidGreenScreenImageProxyAdapter`) was
 * proven on physical SM-A566B hardware to make CameraX/ML Kit's ImageProxy handling recurse into a
 * native StackOverflowError; this seam and its implementations avoid ImageProxy entirely.
 *
 * Contract (identical in spirit to the Duet backend contract):
 *   - [open] is called once, before the first [segment]; blocks the calling thread until ready or
 *     definitively failed. May throw — a throw means "this backend is unavailable".
 *   - [segment] must invoke [completion] exactly once and must never close [image]. [image] stays
 *     valid until [completion] is invoked.
 *   - [close] is idempotent, never throws, and may be called from any thread.
 */
private interface CleanCameraImageSegmentationBackend {
    /** One of [DuetSegmentationBackend] (`mediapipe_cpu`, `mlkit`). */
    val backendId: String

    /** Loads the segmenter. Called once; may throw. */
    fun open()

    /**
     * Segments [image] (captured at [timestampMs], camera clock, monotonic), rotated upright by
     * [rotationDegrees]. Invokes [completion] exactly once; never closes [image].
     */
    fun segment(
        image: Image,
        rotationDegrees: Int,
        timestampMs: Long,
        completion: (DuetSegmentationOutcome) -> Unit,
    )

    /** Releases the segmenter. Idempotent; never throws. */
    fun close()
}

/**
 * MediaPipe Tasks Vision ImageSegmenter backend (`mediapipe_cpu` rung), operating directly on a
 * Camera2 [Image]. Ports [com.connects.vanguard_media_engine.duet.AndroidDuetMediaPipeSegmentationBackend]'s
 * CPU-delegate logic (model asset, RunningMode.VIDEO, confidence mask -> UINT8_ALPHA conversion,
 * one owned single-thread executor for all MediaPipe lifecycle work), but replaces the
 * `ImageProxy.toBitmap()` frame conversion with a direct Camera2 YUV_420_888 -> ARGB_8888 Bitmap
 * conversion, since this pipeline never constructs an ImageProxy.
 */
private class CleanMediaPipeCpuImageSegmentationBackend(
    private val context: Context,
    private val modelAssetPath: String,
) : CleanCameraImageSegmentationBackend {

    companion object {
        private const val TAG = "GreenScreenCleanMPCpu"
        private const val CLOSE_TIMEOUT_MS = 1_500L

        /**
         * Long edge (px) the bitmap sent to MediaPipe is capped to before inference.
         * Restored to the engineering/Tasks live RND parameter (256px long edge) to preserve matte fidelity.
         */
        private const val SEGMENT_INPUT_LONG_EDGE_PX = 256
    }

    override val backendId: String = DuetSegmentationBackend.MEDIAPIPE_CPU

    private val closed = AtomicBoolean(false)

    @Volatile private var executor: ExecutorService? = null
    @Volatile private var ownedThread: Thread? = null
    private var segmenter: ImageSegmenter? = null
    private var lastTimestampMs = Long.MIN_VALUE
    private var loggedMaskLayout = false

    override fun open() {
        check(!closed.get()) { "MediaPipe backend ($backendId) already closed" }
        check(executor == null) { "MediaPipe backend ($backendId) already opened" }

        val executorService = Executors.newSingleThreadExecutor { r ->
            Thread(r, "GreenScreenCleanMediaPipe-$backendId").also { ownedThread = it }.apply { isDaemon = true }
        }
        executor = executorService

        val latch = CountDownLatch(1)
        var creationError: Throwable? = null
        executorService.execute {
            try {
                val baseOptions = BaseOptions.builder()
                    .setModelAssetPath(modelAssetPath)
                    .setDelegate(Delegate.CPU)
                    .build()
                val options = ImageSegmenter.ImageSegmenterOptions.builder()
                    .setBaseOptions(baseOptions)
                    .setRunningMode(RunningMode.VIDEO)
                    .setOutputConfidenceMasks(true)
                    .setOutputCategoryMask(false)
                    .build()
                val created = ImageSegmenter.createFromOptions(context, options)
                if (closed.get()) {
                    try { created.close() } catch (_: Throwable) {}
                } else {
                    segmenter = created
                }
            } catch (t: Throwable) {
                creationError = t
            } finally {
                latch.countDown()
            }
        }
        latch.await()

        val error = creationError
        if (error != null) {
            shutdownExecutorQuietly(executorService)
            throw IllegalStateException(
                "MediaPipe backend ($backendId) failed to open: ${error.message}", error,
            )
        }
        if (closed.get() || segmenter == null) {
            shutdownExecutorQuietly(executorService)
            throw IllegalStateException("MediaPipe backend ($backendId) closed during open()")
        }
        Log.i(
            TAG,
            "open() — ImageSegmenter ready (id=$backendId, asset=$modelAssetPath, delegate=CPU, mode=VIDEO)",
        )
    }

    override fun segment(
        image: Image,
        rotationDegrees: Int,
        timestampMs: Long,
        completion: (DuetSegmentationOutcome) -> Unit,
    ) {
        if (closed.get()) {
            completion(DuetSegmentationOutcome.Skipped("mediapipe_closed"))
            return
        }
        val executorService = executor
        if (executorService == null) {
            completion(DuetSegmentationOutcome.Skipped("mediapipe_closed"))
            return
        }
        try {
            executorService.execute { segmentOnOwnedThread(image, rotationDegrees, timestampMs, completion) }
        } catch (t: RejectedExecutionException) {
            if (closed.get()) {
                completion(DuetSegmentationOutcome.Skipped("mediapipe_closed"))
            } else {
                completion(
                    DuetSegmentationOutcome.Failure(
                        DuetSegmentationFailureReason.inferenceFailed(backendId),
                        "segment() executor rejected task: ${t.message}",
                        t,
                    )
                )
            }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val executorService = executor
        if (executorService == null) return

        if (Thread.currentThread() === ownedThread) {
            closeSegmenterQuietly()
            executorService.shutdown()
            return
        }

        val latch = CountDownLatch(1)
        try {
            executorService.execute {
                closeSegmenterQuietly()
                latch.countDown()
            }
        } catch (t: RejectedExecutionException) {
            latch.countDown()
        }

        val closedInTime = try {
            latch.await(CLOSE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!closedInTime) {
            Log.w(TAG, "close() ($backendId) timed out after ${CLOSE_TIMEOUT_MS}ms waiting for owned thread; forcing executor shutdown")
            executorService.shutdownNow()
        } else {
            executorService.shutdown()
        }
    }

    private fun segmentOnOwnedThread(
        image: Image,
        rotationDegrees: Int,
        timestampMs: Long,
        completion: (DuetSegmentationOutcome) -> Unit,
    ) {
        val seg = segmenter
        if (seg == null || closed.get()) {
            completion(DuetSegmentationOutcome.Skipped("mediapipe_closed"))
            return
        }

        // 1. Camera2 YUV_420_888 Image -> upright, mirrored, downscaled ARGB bitmap. Never
        //    constructs an ImageProxy (see class doc).
        val bitmap: Bitmap = try {
            imageToUprightMirroredBitmap(image, rotationDegrees)
        } catch (t: Throwable) {
            completion(
                DuetSegmentationOutcome.Failure(
                    DuetSegmentationFailureReason.frameConvertFailed(backendId),
                    "Image -> Bitmap conversion failed: ${t.message}",
                    t,
                )
            )
            return
        }

        // 2. Strictly increasing timestamp (VIDEO mode contract).
        val ts = if (timestampMs <= lastTimestampMs) lastTimestampMs + 1 else timestampMs
        lastTimestampMs = ts

        // 3. Inference + mask conversion, both on this owned thread.
        var mpImage: MPImage? = null
        var result: ImageSegmenterResult? = null
        val outcome: DuetSegmentationOutcome = try {
            mpImage = BitmapImageBuilder(bitmap).build()
            result = seg.segmentForVideo(mpImage, ts)
            extractPersonMask(result, ts)
        } catch (t: Throwable) {
            DuetSegmentationOutcome.Failure(
                DuetSegmentationFailureReason.inferenceFailed(backendId),
                "ImageSegmenter.segmentForVideo failed: ${t.javaClass.simpleName}: ${t.message}",
                t,
            )
        } finally {
            closeResultQuietly(result)
            val mp = mpImage
            if (mp != null) {
                try { mp.close() } catch (_: Throwable) {}
            } else {
                try { bitmap.recycle() } catch (_: Throwable) {}
            }
        }
        completion(outcome)
    }

    /**
     * Converts a Camera2 YUV_420_888 [image] to an upright, downscaled, horizontally mirrored
     * ARGB_8888 [Bitmap], without ever wrapping [image] as an [androidx.camera.core.ImageProxy].
     *
     * Route: direct YUV_420_888 -> ARGB_8888 Bitmap conversion honoring row/pixel strides
     * (avoiding intermediate lossy NV21 -> JPEG compression/decompression to preserve edge/matte
     * fidelity), then downscale to [SEGMENT_INPUT_LONG_EDGE_PX] before rotating by [rotationDegrees]
     * and mirroring horizontally — mirroring matches the front-camera live preview's mirrored
     * SurfaceTexture transform (this pipeline is only ever fed by the front camera; see
     * [AndroidGreenScreenCamera2Source]).
     */
    private fun imageToUprightMirroredBitmap(image: Image, rotationDegrees: Int): Bitmap {
        val raw = yuv420888ToArgb8888Bitmap(image)
        val downscaled = downscaleForSegmenter(raw)
        val matrix = Matrix().apply {
            if (rotationDegrees % 360 != 0) postRotate(rotationDegrees.toFloat())
            postScale(-1f, 1f)
        }
        val transformed = Bitmap.createBitmap(downscaled, 0, 0, downscaled.width, downscaled.height, matrix, true)
        if (transformed !== downscaled) {
            try { downscaled.recycle() } catch (_: Throwable) {}
        }
        return transformed
    }

    /** Downscales [source] so its long edge is at most [SEGMENT_INPUT_LONG_EDGE_PX], recycling [source] if scaled. */
    private fun downscaleForSegmenter(source: Bitmap): Bitmap {
        val maxEdge = maxOf(source.width, source.height)
        if (maxEdge <= SEGMENT_INPUT_LONG_EDGE_PX) return source
        val scale = SEGMENT_INPUT_LONG_EDGE_PX.toFloat() / maxEdge.toFloat()
        val targetWidth = (source.width * scale).roundToInt().coerceAtLeast(1)
        val targetHeight = (source.height * scale).roundToInt().coerceAtLeast(1)
        val scaled = Bitmap.createScaledBitmap(source, targetWidth, targetHeight, true)
        if (scaled !== source) {
            try { source.recycle() } catch (_: Throwable) {}
        }
        return scaled
    }

    /**
     * Picks the person confidence mask out of [result] and converts it to a UINT8_ALPHA frame.
     * Identical logic to the proven Duet MediaPipe CPU backend's extraction.
     */
    private fun extractPersonMask(result: ImageSegmenterResult, timestampMs: Long): DuetSegmentationOutcome {
        val masks = result.confidenceMasks().orElse(null)
        if (masks == null || masks.isEmpty()) {
            return DuetSegmentationOutcome.Failure(
                DuetSegmentationFailureReason.emptyResult(backendId),
                "ImageSegmenter returned no confidence masks (outputConfidenceMasks=true)",
            )
        }
        val mask = masks[masks.size - 1]
        val width = mask.width
        val height = mask.height
        if (width <= 0 || height <= 0) {
            return DuetSegmentationOutcome.Failure(
                DuetSegmentationFailureReason.maskSizeMismatch(backendId),
                "Confidence mask has invalid dimensions ${width}x$height",
            )
        }
        val pixelCount = width * height

        val floatBytes: ByteBuffer = ByteBufferExtractor.extract(mask, MPImage.IMAGE_FORMAT_VEC32F1)
        val floats = floatBytes.duplicate().order(ByteOrder.nativeOrder()).asFloatBuffer()
        floats.rewind()
        if (floats.remaining() < pixelCount) {
            return DuetSegmentationOutcome.Failure(
                DuetSegmentationFailureReason.maskSizeMismatch(backendId),
                "Confidence mask buffer holds ${floats.remaining()} floats, need $pixelCount for ${width}x$height",
            )
        }
        val alpha = ByteBuffer.allocateDirect(pixelCount)
        for (i in 0 until pixelCount) {
            val f = floats.get(i)
            val v = when {
                f.isNaN() || f <= 0f -> 0
                f >= 1f -> 255
                else -> (f * 255f).toInt()
            }
            alpha.put(i, v.toByte())
        }
        alpha.rewind()

        if (!loggedMaskLayout) {
            loggedMaskLayout = true
            Log.i(
                TAG,
                "ANDROID_GREENSCREEN_CLEAN_MEDIAPIPE_MASK_FIRST id=$backendId width=$width " +
                    "height=$height masks=${masks.size} personIndex=${masks.size - 1} format=vec32f1->uint8_alpha",
            )
        }

        return DuetSegmentationOutcome.Mask(
            AndroidDuetSegmentationFrame.adoptOwned(
                ownedBytes = alpha,
                width = width,
                height = height,
                timestampMs = timestampMs,
                backend = backendId,
                format = DuetSegmentationMaskFormat.UINT8_ALPHA,
            )
        )
    }

    private fun closeSegmenterQuietly() {
        val seg = segmenter
        segmenter = null
        if (seg != null) {
            try { seg.close() } catch (t: Throwable) {
                Log.w(TAG, "ImageSegmenter.close() threw ($backendId): ${t.message}")
            }
        }
        Log.d(TAG, "close() — ImageSegmenter released ($backendId)")
    }

    private fun shutdownExecutorQuietly(executorService: ExecutorService) {
        executor = null
        try { executorService.shutdown() } catch (_: Throwable) {}
    }

    private fun closeResultQuietly(result: ImageSegmenterResult?) {
        if (result == null) return
        try {
            result.confidenceMasks().orElse(null)?.forEach { m ->
                try { m.close() } catch (_: Throwable) {}
            }
        } catch (_: Throwable) {}
        try {
            result.categoryMask().orElse(null)?.let { m ->
                try { m.close() } catch (_: Throwable) {}
            }
        } catch (_: Throwable) {}
    }
}

/**
 * Converts a Camera2 YUV_420_888 [image] directly into an ARGB_8888 [Bitmap], honoring each
 * plane's row and pixel strides. Avoids intermediate NV21 and lossy JPEG compression/decompression
 * to preserve matte and edge fidelity. Standalone SDK-only conversion — never touches CameraX
 * or [androidx.camera.core.ImageProxy].
 */
private fun yuv420888ToArgb8888Bitmap(image: Image): Bitmap {
    val width = image.width
    val height = image.height
    val yPlane = image.planes[0]
    val uPlane = image.planes[1]
    val vPlane = image.planes[2]

    val yBuffer = yPlane.buffer
    val uBuffer = uPlane.buffer
    val vBuffer = vPlane.buffer

    val yRowStride = yPlane.rowStride
    val yPixelStride = yPlane.pixelStride
    val uRowStride = uPlane.rowStride
    val uPixelStride = uPlane.pixelStride
    val vRowStride = vPlane.rowStride
    val vPixelStride = vPlane.pixelStride

    val pixels = IntArray(width * height)
    var outIndex = 0

    for (row in 0 until height) {
        val yRowStart = row * yRowStride
        val chromaRow = row shr 1
        val uRowStart = chromaRow * uRowStride
        val vRowStart = chromaRow * vRowStride

        var col = 0
        while (col < width) {
            val chromaCol = col shr 1
            val uIndex = uRowStart + chromaCol * uPixelStride
            val vIndex = vRowStart + chromaCol * vPixelStride

            val uVal = (uBuffer.get(uIndex).toInt() and 0xFF) - 128
            val vVal = (vBuffer.get(vIndex).toInt() and 0xFF) - 128

            // BT.601 integer fixed-point coefficients (scaled by 1024):
            // R = Y + 1.402 * V
            // G = Y - 0.344136 * U - 0.714136 * V
            // B = Y + 1.772 * U
            val rOffset = (1436 * vVal) shr 10
            val gOffset = (352 * uVal + 731 * vVal) shr 10
            val bOffset = (1815 * uVal) shr 10

            val y0 = yBuffer.get(yRowStart + col * yPixelStride).toInt() and 0xFF
            val r0 = (y0 + rOffset).coerceIn(0, 255)
            val g0 = (y0 - gOffset).coerceIn(0, 255)
            val b0 = (y0 + bOffset).coerceIn(0, 255)
            pixels[outIndex++] = 0xFF000000.toInt() or (r0 shl 16) or (g0 shl 8) or b0
            col++

            if (col < width) {
                val y1 = yBuffer.get(yRowStart + col * yPixelStride).toInt() and 0xFF
                val r1 = (y1 + rOffset).coerceIn(0, 255)
                val g1 = (y1 - gOffset).coerceIn(0, 255)
                val b1 = (y1 + bOffset).coerceIn(0, 255)
                pixels[outIndex++] = 0xFF000000.toInt() or (r1 shl 16) or (g1 shl 8) or b1
                col++
            }
        }
    }

    return Bitmap.createBitmap(pixels, 0, width, width, height, Bitmap.Config.ARGB_8888)
}

/**
 * ML Kit Selfie Segmentation backend (`mlkit` rung), operating directly on a Camera2 [Image].
 * Ports [com.connects.vanguard_media_engine.duet.AndroidDuetMlKitSegmentationBackend]'s logic
 * verbatim, except [InputImage.fromMediaImage] is called directly on the Camera2 `Image` instead
 * of through an ImageProxy, since this pipeline never constructs one.
 */
private class CleanMlKitImageSegmentationBackend : CleanCameraImageSegmentationBackend {

    companion object {
        private const val TAG = "GreenScreenCleanMlKit"
    }

    override val backendId: String = DuetSegmentationBackend.MLKIT

    private val closed = AtomicBoolean(false)
    private val segmenterRef = AtomicReference<Segmenter?>(null)

    override fun open() {
        check(!closed.get()) { "ML Kit backend already closed" }
        if (segmenterRef.get() != null) return
        val options = SelfieSegmenterOptions.Builder()
            .setDetectorMode(SelfieSegmenterOptions.STREAM_MODE)
            .enableRawSizeMask()
            .build()
        val segmenter = Segmentation.getClient(options)
        if (!segmenterRef.compareAndSet(null, segmenter) || closed.get()) {
            try { segmenter.close() } catch (_: Throwable) {}
            if (closed.get()) throw IllegalStateException("ML Kit backend closed during open()")
        }
        Log.i(TAG, "open() — ML Kit Selfie Segmenter (STREAM_MODE, raw mask) created")
    }

    @SuppressLint("UnsafeOptInUsageError")
    override fun segment(
        image: Image,
        rotationDegrees: Int,
        timestampMs: Long,
        completion: (DuetSegmentationOutcome) -> Unit,
    ) {
        val segmenter = segmenterRef.get()
        if (segmenter == null || closed.get()) {
            completion(DuetSegmentationOutcome.Skipped("mlkit_closed"))
            return
        }

        val inputImage = InputImage.fromMediaImage(image, rotationDegrees)
        segmenter.process(inputImage)
            .addOnSuccessListener { mask: SegmentationMask ->
                val outcome = try {
                    DuetSegmentationOutcome.Mask(
                        AndroidDuetSegmentationFrame.copyFrom(
                            source = mask.buffer,
                            width = mask.width,
                            height = mask.height,
                            timestampMs = timestampMs,
                            backend = backendId,
                            format = DuetSegmentationMaskFormat.FLOAT32_CONFIDENCE,
                        )
                    )
                } catch (t: Throwable) {
                    Log.w(TAG, "Mask copy threw: ${t.message}")
                    DuetSegmentationOutcome.Skipped("mlkit_mask_copy_failed")
                }
                completion(outcome)
            }
            .addOnFailureListener { e: Exception ->
                Log.w(TAG, "Segmentation failed: ${e.message}")
                completion(
                    DuetSegmentationOutcome.Failure(
                        DuetSegmentationFailureReason.MLKIT_FAILURE,
                        "ML Kit segmentation failed: ${e.message}",
                        e,
                    )
                )
            }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val segmenter = segmenterRef.getAndSet(null)
        try { segmenter?.close() } catch (t: Throwable) {
            Log.w(TAG, "Segmenter.close() threw: ${t.message}")
        }
        Log.d(TAG, "close() — segmenter closed")
    }
}
