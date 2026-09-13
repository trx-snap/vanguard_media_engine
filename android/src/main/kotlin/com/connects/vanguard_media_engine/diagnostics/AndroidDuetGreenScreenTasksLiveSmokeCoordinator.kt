package com.connects.vanguard_media_engine.diagnostics

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.connects.vanguard_media_engine.duet.AndroidDuetCameraSource
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.ByteBufferExtractor
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.ImageProcessingOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenter
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenterResult
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt

/**
 * ANDROID-DUET-GREENSCREEN-TASKS-LIVE: RND-only diagnostic proof of the
 * "right foundation" green-screen path on Android:
 *
 *   CameraX ImageAnalysis (640x360 YUV_420_888, KEEP_ONLY_LATEST, via
 *   [AndroidDuetCameraSource]) -> official MediaPipe Tasks ImageSegmenter in
 *   RunningMode.LIVE_STREAM (one owned segmenter thread) -> static background
 *   composite drawn with a Canvas -> Flutter TextureRegistry.SurfaceProducer.
 *
 * Owned MethodChannel routes: [METHOD_START] / [METHOD_STOP].
 *
 * Boundaries (honest claims only):
 *   - Static background only (solid teal or checker). No video background, no
 *     export, no production Duet session, no TikTok-quality claim.
 *   - CameraX Preview is bound (the camera source requires a Preview surface)
 *     but it is fed into an offscreen GL-consumed dummy SurfaceTexture; it is
 *     NEVER drawn into the Flutter SurfaceProducer surface. The Flutter
 *     surface only ever receives this coordinator's Canvas output.
 *   - GPU delegate is category-mask only. GPU confidence masks are refused
 *     (a physically observed native abort path).
 *   - Exactly one analysis frame is in flight at a time; a frame arriving
 *     while busy is closed immediately and counted as droppedBusy.
 *   - A mask is composited as keyed truth only when it is fresh
 *     (callback age since frame acquire <= maxFreshnessMs). Otherwise the
 *     camera frame is drawn over the background unkeyed and counted as such.
 *
 * Threads:
 *   - main (Flutter platform thread): start/stop orchestration, SurfaceProducer
 *     create/release, camera start/stop.
     *   - CameraX analysis thread: ImageProxy -> raw Bitmap, submit.
 *   - owned segmenter thread: ImageSegmenter create / segmentAsync / close.
 *   - MediaPipe result thread: mask extraction, hand-off to the render thread.
 *   - owned render thread: composite + Surface hardware Canvas draw.
 *   - owned dummy-preview GL thread: consumes CameraX Preview buffers.
 */
class AndroidDuetGreenScreenTasksLiveSmokeCoordinator(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "DuetGreenScreenTasksLive"

        const val METHOD_START = "startAndroidDuetGreenScreenTasksLiveSmoke"
        const val METHOD_STOP = "stopAndroidDuetGreenScreenTasksLiveSmoke"

        const val MARKER_START = "ANDROID_DUET_GREENSCREEN_TASKS_LIVE_START"
        const val MARKER_FIRST_FRAME = "ANDROID_DUET_GREENSCREEN_TASKS_LIVE_FIRST_FRAME"
        const val MARKER_FIRST_MASK = "ANDROID_DUET_GREENSCREEN_TASKS_LIVE_FIRST_MASK"
        const val MARKER_FIRST_COMPOSITE = "ANDROID_DUET_GREENSCREEN_TASKS_LIVE_FIRST_COMPOSITE_LAYER"
        const val MARKER_SUMMARY = "ANDROID_DUET_GREENSCREEN_TASKS_LIVE_SUMMARY"
        const val MARKER_PASS = "ANDROID_DUET_GREENSCREEN_TASKS_LIVE_PASS"
        const val MARKER_FAIL = "ANDROID_DUET_GREENSCREEN_TASKS_LIVE_FAIL"

        const val PROOF_BOUNDARY =
            "android_duet_green_screen_tasks_live_rnd_diagnostic_only_camerax_imageanalysis_640x360_" +
                "to_official_mediapipe_tasks_imagesegmenter_live_stream_to_static_background_canvas_" +
                "to_flutter_surface_producer_texture_camerax_preview_offscreen_never_drawn_" +
                "gpu_category_mask_only_no_gpu_confidence_single_in_flight_frame_" +
                "no_video_background_no_export_no_production_duet_no_tiktok_quality_claim"

        const val BACKEND_CPU_CONFIDENCE = "cpu_confidence"
        const val BACKEND_CPU_CATEGORY = "cpu_category"
        const val BACKEND_GPU_CATEGORY = "gpu_category"
        const val BACKEND_GPU_CONFIDENCE_FORBIDDEN = "gpu_confidence"

        const val BACKGROUND_SOLID_TEAL = "solid_teal"
        const val BACKGROUND_CHECKER = "checker"
        const val BACKGROUND_PICTURE_STILL_C = "picture_still_c"

        const val VIEW_MODE_COMPOSITE = "composite"
        const val VIEW_MODE_MASK = "mask"
        const val VIEW_MODE_BINARY_MASK = "binary_mask"

        const val MATTE_RAW = "raw"
        const val MATTE_SMOOTHSTEP = "smoothstep"
        const val MATTE_BINARY = "binary"

        const val MASK_ROTATION_CAMERA = "camera"
        const val MASK_ROTATION_NONE = "none"
        const val MASK_ROTATION_INVERSE = "inverse"

        const val SEGMENT_INPUT_METADATA = "metadata"
        const val SEGMENT_INPUT_UPRIGHT_BITMAP = "upright_bitmap"

        const val DEFAULT_MAX_FRESHNESS_MS = 250L
        const val MIN_MAX_FRESHNESS_MS = 16L
        const val MAX_MAX_FRESHNESS_MS = 2_000L
        const val DEFAULT_OUTPUT_WIDTH = 720
        const val DEFAULT_OUTPUT_HEIGHT = 1280
        const val MIN_OUTPUT_DIM = 64
        const val MAX_OUTPUT_DIM = 4_096
        const val DEFAULT_SEGMENT_LONG_EDGE_PX = 256

        /** Same bundled model the production MediaPipe CPU rung uses. */
        const val MODEL_ASSET_PATH = "selfie_segmentation_landscape.tflite"

        /**
         * Category value that denotes "person" for the single-channel selfie
         * model. Repository evidence (AndroidDuetMediaPipeSegmentationBackend)
         * records 0 = person / 255 = unlabeled; the first mask histogram is
         * published so a physical run can confirm or flip via `categoryPersonValue`.
         */
        const val DEFAULT_CATEGORY_PERSON_VALUE = 0

        private const val DUMMY_PREVIEW_WIDTH = 1280
        private const val DUMMY_PREVIEW_HEIGHT = 720
        private const val TEAL = 0xFF008080.toInt()
        private const val CHECKER_LIGHT = 0xFF3A3A3A.toInt()
        private const val CHECKER_DARK = 0xFF1E1E1E.toInt()
        private const val CHECKER_CELL_PX = 40
        private const val STILL_C_ASSET_PATH = "flutter_assets/assets/manual_test_clips/still_C.png"

        private const val SEGMENTER_CLOSE_TIMEOUT_MS = 1_500L
        private const val DUMMY_SINK_CREATE_TIMEOUT_MS = 2_000L
        private const val DUMMY_SINK_RELEASE_TIMEOUT_MS = 1_000L
        private const val RENDER_JOIN_TIMEOUT_MS = 1_500L
        private const val INFLIGHT_TIMEOUT_NS = 1_500_000_000L

        fun ownsMethod(method: String): Boolean = method == METHOD_START || method == METHOD_STOP
    }

    private val disposed = AtomicBoolean(false)

    /** Main-thread confined: the one live session, null when idle. */
    private var session: Session? = null

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    /** Returns true when [method] belongs to this coordinator (reply always sent). */
    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        return when (method) {
            METHOD_START -> {
                handleStart(args, result)
                true
            }
            METHOD_STOP -> {
                handleStop(result)
                true
            }
            else -> false
        }
    }

    /** Plugin detach: stops and releases everything; later calls are ignored. */
    fun disposeAll() {
        disposed.set(true)
        val s = session ?: return
        session = null
        try {
            s.stopAndRelease()
        } catch (t: Throwable) {
            Log.w(TAG, "disposeAll: stop threw ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    // ── Start / stop (main thread) ────────────────────────────────────────────

    private fun handleStart(args: Map<*, *>?, result: MethodChannel.Result) {
        if (disposed.get()) {
            replySafely(result, failureStartPayload("coordinator_disposed", null))
            return
        }
        if (session != null) {
            result.error(
                "DUET_GREENSCREEN_TASKS_LIVE_BUSY",
                "$METHOD_START: diagnostic already running; call $METHOD_STOP first",
                null,
            )
            return
        }
        val config = try {
            parseConfig(args)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "$MARKER_FAIL reason=${e.message}")
            replySafely(result, failureStartPayload(e.message ?: "invalid_args", null))
            return
        }
        val s = Session(config)
        session = s
        s.start(result)
    }

    private fun handleStop(result: MethodChannel.Result) {
        val s = session
        if (s == null) {
            replySafely(
                result,
                mapOf(
                    "pass" to false,
                    "proofBoundary" to PROOF_BOUNDARY,
                    "failureReason" to "not_running",
                ),
            )
            return
        }
        session = null
        val payload = try {
            s.stopAndRelease()
        } catch (t: Throwable) {
            Log.e(TAG, "stop threw", t)
            mapOf(
                "pass" to false,
                "proofBoundary" to PROOF_BOUNDARY,
                "failureReason" to "stop_exception:${t.javaClass.simpleName}:${t.message}",
            )
        }
        replySafely(result, payload)
    }

    private fun replySafely(result: MethodChannel.Result, payload: Map<String, Any?>) {
        try {
            result.success(payload)
        } catch (t: Throwable) {
            Log.w(TAG, "reply dropped: ${t.javaClass.simpleName}")
        }
    }

    private fun failureStartPayload(reason: String, config: Config?): Map<String, Any?> = mapOf(
        "pass" to false,
        "textureId" to -1L,
        "viewMode" to (config?.viewMode ?: ""),
        "backend" to (config?.backend ?: ""),
        "proofBoundary" to PROOF_BOUNDARY,
        "backgroundMode" to (config?.backgroundMode ?: ""),
        "matteMode" to (config?.matteMode ?: ""),
        "matteLow" to (config?.matteLow ?: 0.18f),
        "matteHigh" to (config?.matteHigh ?: 0.62f),
        "matteGamma" to (config?.matteGamma ?: 0.85f),
        "maxFreshnessMs" to (config?.maxFreshnessMs ?: DEFAULT_MAX_FRESHNESS_MS),
        "statsWarmupMs" to (config?.statsWarmupMs ?: 0L),
        "segmentLongEdgePx" to (config?.segmentLongEdgePx ?: DEFAULT_SEGMENT_LONG_EDGE_PX),
        "outputWidth" to (config?.outputWidth ?: DEFAULT_OUTPUT_WIDTH),
        "outputHeight" to (config?.outputHeight ?: DEFAULT_OUTPUT_HEIGHT),
        "failureReason" to reason,
    )

    // ── Config ────────────────────────────────────────────────────────────────

    private data class Config(
        val viewMode: String,
        val backend: String,
        val delegate: Delegate,
        val outputConfidence: Boolean,
        val outputCategory: Boolean,
        val backgroundMode: String,
        val maxFreshnessMs: Long,
        val outputWidth: Int,
        val outputHeight: Int,
        val categoryPersonValue: Int,
        val matteMode: String,
        val matteLow: Float,
        val matteHigh: Float,
        val matteGamma: Float,
        val maskRotationPolicy: String,
        val segmentInputOrientationPolicy: String,
        val statsWarmupMs: Long,
        val segmentLongEdgePx: Int,
    )

    private fun parseConfig(args: Map<*, *>?): Config {
        val viewMode = (args?.get("viewMode") as? String)?.trim()?.ifEmpty { null } ?: VIEW_MODE_COMPOSITE
        if (viewMode != VIEW_MODE_COMPOSITE && viewMode != VIEW_MODE_MASK && viewMode != VIEW_MODE_BINARY_MASK) {
            throw IllegalArgumentException("unknown_view_mode:$viewMode")
        }
        val backend = (args?.get("backend") as? String)?.trim()?.ifEmpty { null } ?: BACKEND_CPU_CONFIDENCE
        val (delegate, confidence, category) = when (backend) {
            BACKEND_CPU_CONFIDENCE -> Triple(Delegate.CPU, true, false)
            BACKEND_CPU_CATEGORY -> Triple(Delegate.CPU, false, true)
            BACKEND_GPU_CATEGORY -> Triple(Delegate.GPU, false, true)
            BACKEND_GPU_CONFIDENCE_FORBIDDEN ->
                throw IllegalArgumentException("gpu_confidence_forbidden_gpu_is_category_mask_only")
            else -> throw IllegalArgumentException("unknown_backend:$backend")
        }
        val backgroundMode = (args?.get("backgroundMode") as? String)?.trim()?.ifEmpty { null } ?: BACKGROUND_SOLID_TEAL
        if (backgroundMode != BACKGROUND_SOLID_TEAL &&
            backgroundMode != BACKGROUND_CHECKER &&
            backgroundMode != BACKGROUND_PICTURE_STILL_C
        ) {
            throw IllegalArgumentException("unknown_background_mode:$backgroundMode")
        }
        val matteMode = (args?.get("matteMode") as? String)?.trim()?.ifEmpty { null } ?: MATTE_SMOOTHSTEP
        if (matteMode != MATTE_RAW && matteMode != MATTE_SMOOTHSTEP && matteMode != MATTE_BINARY) {
            throw IllegalArgumentException("unknown_matte_mode:$matteMode")
        }
        val matteLow = ((args?.get("matteLow") as? Number)?.toFloat() ?: 0.18f).coerceIn(0f, 1f)
        val matteHigh = ((args?.get("matteHigh") as? Number)?.toFloat() ?: 0.62f).coerceIn(0f, 1f)
        if (matteHigh <= matteLow) {
            throw IllegalArgumentException("invalid_matte_thresholds:${matteLow},${matteHigh}")
        }
        val matteGamma = ((args?.get("matteGamma") as? Number)?.toFloat() ?: 0.85f).coerceIn(0.1f, 4f)
        val maskRotationPolicy = (args?.get("maskRotationPolicy") as? String)?.trim()?.ifEmpty { null }
            ?: MASK_ROTATION_CAMERA
        if (maskRotationPolicy != MASK_ROTATION_CAMERA &&
            maskRotationPolicy != MASK_ROTATION_NONE &&
            maskRotationPolicy != MASK_ROTATION_INVERSE
        ) {
            throw IllegalArgumentException("unknown_mask_rotation_policy:$maskRotationPolicy")
        }
        val segmentInputOrientationPolicy =
            (args?.get("segmentInputOrientationPolicy") as? String)?.trim()?.ifEmpty { null }
                ?: SEGMENT_INPUT_METADATA
        if (segmentInputOrientationPolicy != SEGMENT_INPUT_METADATA &&
            segmentInputOrientationPolicy != SEGMENT_INPUT_UPRIGHT_BITMAP
        ) {
            throw IllegalArgumentException("unknown_segment_input_orientation_policy:$segmentInputOrientationPolicy")
        }
        val maxFreshnessMs = (args?.get("maxFreshnessMs") as? Number)?.toLong() ?: DEFAULT_MAX_FRESHNESS_MS
        if (maxFreshnessMs < MIN_MAX_FRESHNESS_MS || maxFreshnessMs > MAX_MAX_FRESHNESS_MS) {
            throw IllegalArgumentException("invalid_max_freshness_ms:$maxFreshnessMs")
        }
        val statsWarmupMs = ((args?.get("statsWarmupMs") as? Number)?.toLong() ?: 0L).coerceIn(0L, 120_000L)
        val segmentLongEdgePx = ((args?.get("segmentLongEdgePx") as? Number)?.toInt()
            ?: DEFAULT_SEGMENT_LONG_EDGE_PX).coerceIn(0, MAX_OUTPUT_DIM)
        val outputWidth = (args?.get("outputWidth") as? Number)?.toInt() ?: DEFAULT_OUTPUT_WIDTH
        val outputHeight = (args?.get("outputHeight") as? Number)?.toInt() ?: DEFAULT_OUTPUT_HEIGHT
        if (outputWidth < MIN_OUTPUT_DIM || outputWidth > MAX_OUTPUT_DIM ||
            outputHeight < MIN_OUTPUT_DIM || outputHeight > MAX_OUTPUT_DIM
        ) {
            throw IllegalArgumentException("invalid_output_size:${outputWidth}x$outputHeight")
        }
        val categoryPersonValue = (args?.get("categoryPersonValue") as? Number)?.toInt() ?: DEFAULT_CATEGORY_PERSON_VALUE
        if (categoryPersonValue < 0 || categoryPersonValue > 255) {
            throw IllegalArgumentException("invalid_category_person_value:$categoryPersonValue")
        }
        return Config(
            viewMode = viewMode,
            backend = backend,
            delegate = delegate,
            outputConfidence = confidence,
            outputCategory = category,
            backgroundMode = backgroundMode,
            maxFreshnessMs = maxFreshnessMs,
            outputWidth = outputWidth,
            outputHeight = outputHeight,
            categoryPersonValue = categoryPersonValue,
            matteMode = matteMode,
            matteLow = matteLow,
            matteHigh = matteHigh,
            matteGamma = matteGamma,
            maskRotationPolicy = maskRotationPolicy,
            segmentInputOrientationPolicy = segmentInputOrientationPolicy,
            statsWarmupMs = statsWarmupMs,
            segmentLongEdgePx = segmentLongEdgePx,
        )
    }

    // ── Latency accumulator ───────────────────────────────────────────────────

    private class LatencyStat {
        private var count = 0L
        private var sumNs = 0L
        private var maxNs = 0L

        @Synchronized
        fun add(ns: Long) {
            val v = if (ns < 0L) 0L else ns
            count++
            sumNs += v
            if (v > maxNs) maxNs = v
        }

        @Synchronized
        fun meanMs(): Double = if (count == 0L) -1.0 else (sumNs.toDouble() / count) / 1_000_000.0

        @Synchronized
        fun maxMs(): Double = if (count == 0L) -1.0 else maxNs / 1_000_000.0

        @Synchronized
        fun samples(): Long = count
    }

    // ── One analysis frame in flight ──────────────────────────────────────────

    private class FrameInFlight(
        val seq: Long,
        val bitmap: Bitmap,
        val segmentBitmap: Bitmap,
        val rotationDegrees: Int,
        val segmentRotationDegrees: Int,
        val acquireNs: Long,
        val timestampMs: Long,
    ) {
        @Volatile
        var inputReadyNs: Long = -1L

        /** Set on the segmenter thread; MPImage.close() recycles [bitmap]. */
        @Volatile
        var mpImage: MPImage? = null

        private val released = AtomicBoolean(false)

        fun release() {
            if (!released.compareAndSet(false, true)) return
            val image = mpImage
            mpImage = null
            if (image != null) {
                try { image.close() } catch (_: Throwable) {}
            }
            if (segmentBitmap !== bitmap && !segmentBitmap.isRecycled) {
                try { segmentBitmap.recycle() } catch (_: Throwable) {}
            }
            if (!bitmap.isRecycled) {
                try { bitmap.recycle() } catch (_: Throwable) {}
            }
        }
    }

    /** Person alpha (0..255) at mask resolution, row stride = width. */
    private class AlphaMask(val width: Int, val height: Int, val alpha: ByteArray, val kind: String)

    // ── Offscreen GL consumer for the CameraX Preview surface ─────────────────

    /**
     * The camera source insists on a Preview surface. This sink owns a 1x1
     * EGL pbuffer context on its own thread and a GL_TEXTURE_EXTERNAL_OES
     * SurfaceTexture; every camera preview buffer is consumed with
     * updateTexImage so the preview stream never stalls the shared capture
     * session (a never-consumed BufferQueue would block the HAL and starve
     * ImageAnalysis). Nothing from this sink is ever presented.
     */
    private class OffscreenPreviewSink {
        private val thread = HandlerThread("vg.duet.tasks.dummyPreview").apply { start() }
        private val handler = Handler(thread.looper)
        private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
        private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
        private var pbuffer: EGLSurface = EGL14.EGL_NO_SURFACE
        private var textureId = 0
        private var surfaceTexture: SurfaceTexture? = null

        @Volatile
        var surface: Surface? = null
            private set

        val framesConsumed = AtomicLong(0L)

        @Volatile
        var createError: String? = null
            private set

        fun create(timeoutMs: Long): Surface? {
            val latch = CountDownLatch(1)
            val posted = handler.post {
                try {
                    createOnThread()
                } catch (t: Throwable) {
                    createError = "${t.javaClass.simpleName}:${t.message}"
                    try { releaseOnThread() } catch (_: Throwable) {}
                } finally {
                    latch.countDown()
                }
            }
            if (!posted) return null
            if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
                createError = "dummy_sink_create_timeout"
                return null
            }
            return surface
        }

        private fun createOnThread() {
            val d = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (d == EGL14.EGL_NO_DISPLAY) throw IllegalStateException("egl_no_display")
            val version = IntArray(2)
            if (!EGL14.eglInitialize(d, version, 0, version, 1)) throw IllegalStateException("egl_initialize_failed")
            display = d
            val configAttribs = intArrayOf(
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfigs = IntArray(1)
            if (!EGL14.eglChooseConfig(d, configAttribs, 0, configs, 0, 1, numConfigs, 0) || numConfigs[0] <= 0) {
                throw IllegalStateException("egl_choose_config_failed")
            }
            val config = configs[0] ?: throw IllegalStateException("egl_config_null")
            val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
            val ctx = EGL14.eglCreateContext(d, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
            if (ctx == EGL14.EGL_NO_CONTEXT) throw IllegalStateException("egl_create_context_failed")
            eglContext = ctx
            val pbufferAttribs = intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE)
            val pb = EGL14.eglCreatePbufferSurface(d, config, pbufferAttribs, 0)
            if (pb == EGL14.EGL_NO_SURFACE) throw IllegalStateException("egl_create_pbuffer_failed")
            pbuffer = pb
            if (!EGL14.eglMakeCurrent(d, pb, pb, ctx)) throw IllegalStateException("egl_make_current_failed")
            val ids = IntArray(1)
            GLES20.glGenTextures(1, ids, 0)
            textureId = ids[0]
            if (textureId == 0) throw IllegalStateException("gl_gen_textures_failed")
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            val st = SurfaceTexture(textureId)
            st.setDefaultBufferSize(DUMMY_PREVIEW_WIDTH, DUMMY_PREVIEW_HEIGHT)
            st.setOnFrameAvailableListener({ texture ->
                // Delivered on this sink's thread (handler variant); consume the
                // buffer so the camera producer never blocks.
                try {
                    texture.updateTexImage()
                    framesConsumed.incrementAndGet()
                } catch (t: Throwable) {
                    Log.w(TAG, "dummy preview updateTexImage failed: ${t.message}")
                }
            }, handler)
            surfaceTexture = st
            surface = Surface(st)
        }

        fun release(timeoutMs: Long) {
            val latch = CountDownLatch(1)
            val posted = handler.post {
                try {
                    releaseOnThread()
                } finally {
                    latch.countDown()
                }
            }
            if (posted) {
                try {
                    latch.await(timeoutMs, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
            thread.quitSafely()
            try {
                thread.join(timeoutMs)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }

        private fun releaseOnThread() {
            try { surface?.release() } catch (_: Throwable) {}
            surface = null
            try { surfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
            try { surfaceTexture?.release() } catch (_: Throwable) {}
            surfaceTexture = null
            if (display != EGL14.EGL_NO_DISPLAY) {
                if (textureId != 0) {
                    try { GLES20.glDeleteTextures(1, intArrayOf(textureId), 0) } catch (_: Throwable) {}
                    textureId = 0
                }
                try {
                    EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                } catch (_: Throwable) {}
                if (pbuffer != EGL14.EGL_NO_SURFACE) {
                    try { EGL14.eglDestroySurface(display, pbuffer) } catch (_: Throwable) {}
                    pbuffer = EGL14.EGL_NO_SURFACE
                }
                if (eglContext != EGL14.EGL_NO_CONTEXT) {
                    try { EGL14.eglDestroyContext(display, eglContext) } catch (_: Throwable) {}
                    eglContext = EGL14.EGL_NO_CONTEXT
                }
                // The default display is process-shared; never eglTerminate it.
                display = EGL14.EGL_NO_DISPLAY
            }
        }
    }

    // ── Session ───────────────────────────────────────────────────────────────

    private inner class Session(private val config: Config) {
        private val stopRequested = AtomicBoolean(false)
        private val replied = AtomicBoolean(false)
        private val startedAtMs = SystemClock.elapsedRealtime()

        // Flutter output.
        private var producer: TextureRegistry.SurfaceProducer? = null

        @Volatile
        private var outputSurface: Surface? = null

        @Volatile
        private var textureId: Long = -1L

        // Camera.
        private var camera: AndroidDuetCameraSource? = null
        private val dummySink = OffscreenPreviewSink()

        @Volatile
        private var cameraStarted = false

        // Segmenter (owned thread).
        private val segmenterExecutor: ExecutorService = Executors.newSingleThreadExecutor { r ->
            Thread(r, "vg.duet.tasks.segmenter").apply { isDaemon = true }
        }

        /** Touched only on the segmenter thread. */
        private var segmenter: ImageSegmenter? = null

        @Volatile
        private var segmenterReady = false

        @Volatile
        private var segmenterClosed = false

        // Render thread.
        private val renderThread = HandlerThread("vg.duet.tasks.render").apply { start() }
        private val renderHandler = Handler(renderThread.looper)

        // Render-thread confined scratch.
        private var backgroundBitmap: Bitmap? = null
        private var maskDebugBitmap: Bitmap? = null
        private var maskPixels: IntArray? = null
        private var compositeAlphaBitmap: Bitmap? = null
        private var compositeAlphaBuffer: ByteBuffer? = null
        private var confidenceFloatScratch: FloatArray? = null

        // MediaPipe result-thread confined scratch. Reusing this array across masks (rather
        // than allocating ByteArray(count) per frame) is only safe because exactly one frame
        // is ever in flight (see the `inFlight` single-slot contract): extractAlphaMask never
        // runs concurrently for two frames, and the returned AlphaMask is consumed by the
        // render thread before the next mask is extracted.
        private var alphaByteScratch: ByteArray? = null
        private val pictureBackgroundLoadFailed = AtomicBoolean(false)
        private val confidenceAlphaLut = ByteArray(256) { index ->
            buildConfidenceDisplayAlpha(index.toFloat() / 255f).toByte()
        }
        private val drawPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
        private val maskPaint = Paint(Paint.FILTER_BITMAP_FLAG).apply {
            xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_IN)
        }
        private val matrix = Matrix()
        private val maskMatrix = Matrix()

        // In-flight control.
        private val inFlight = AtomicReference<FrameInFlight?>(null)
        private val frameSeq = AtomicLong(0L)
        private var lastTimestampMs = Long.MIN_VALUE // analysis-thread confined

        // Counters.
        private val framesAnalyzed = AtomicLong(0L)
        private val submitted = AtomicLong(0L)
        private val masks = AtomicLong(0L)
        private val droppedBusy = AtomicLong(0L)
        private val staleMasks = AtomicLong(0L)
        private val drawnFrames = AtomicLong(0L)
        private val keyedDraws = AtomicLong(0L)
        private val maskDebugDraws = AtomicLong(0L)
        private val unkeyedDraws = AtomicLong(0L)
        private val containerDiffers = AtomicLong(0L)
        private val timestampMismatches = AtomicLong(0L)
        private val failures = AtomicLong(0L)
        private val skippedNotReady = AtomicLong(0L)
        private val inflightTimeouts = AtomicLong(0L)
        private val orphanResults = AtomicLong(0L)
        private val segmenterErrors = AtomicLong(0L)
        private val outputDrawErrors = AtomicLong(0L)
        private val inputReadyToCallback = LatencyStat()
        private val callbackToDraw = LatencyStat()
        private val totalAcquireToDraw = LatencyStat()
        private val frameConvert = LatencyStat()
        private val maskExtract = LatencyStat()
        private val maskBufferExtract = LatencyStat()
        private val maskAlphaBuild = LatencyStat()
        private val renderQueue = LatencyStat()
        private val maskBitmapCopy = LatencyStat()
        private val compositeRenderBody = LatencyStat()
        private val outputCanvasLock = LatencyStat()
        private val outputCanvasBlock = LatencyStat()
        private val outputCanvasUnlockPost = LatencyStat()
        private val warmInputReadyToCallback = LatencyStat()
        private val warmCallbackToDraw = LatencyStat()
        private val warmTotalAcquireToDraw = LatencyStat()
        private val warmFrameConvert = LatencyStat()
        private val warmMaskExtract = LatencyStat()
        private val warmMaskBufferExtract = LatencyStat()
        private val warmMaskAlphaBuild = LatencyStat()
        private val warmRenderQueue = LatencyStat()
        private val warmMaskBitmapCopy = LatencyStat()
        private val warmCompositeRenderBody = LatencyStat()
        private val warmOutputCanvasLock = LatencyStat()
        private val warmOutputCanvasBlock = LatencyStat()
        private val warmOutputCanvasUnlockPost = LatencyStat()

        private val firstFrameLogged = AtomicBoolean(false)
        private val firstMaskLogged = AtomicBoolean(false)
        private val firstCompositeLogged = AtomicBoolean(false)
        private val lastError = AtomicReference<String?>(null)

        @Volatile
        private var firstMaskLayout: Map<String, Any?>? = null

        @Volatile
        private var geometry: Map<String, Any?>? = null

        @Volatile
        private var cameraRotationDegrees = -1

        @Volatile
        private var firstFrameAtMs = -1L

        @Volatile
        private var firstMaskAtMs = -1L

        private fun recordFailure(reason: String) {
            failures.incrementAndGet()
            lastError.compareAndSet(null, reason)
            Log.w(TAG, "failure: $reason")
        }

        // ── Start (main thread) ─────────────────────────────────────────────

        fun start(result: MethodChannel.Result) {
            Log.i(
                TAG,
                "$MARKER_START viewMode=${config.viewMode} backend=${config.backend} delegate=${config.delegate} " +
                    "confidence=${config.outputConfidence} category=${config.outputCategory} " +
                    "background=${config.backgroundMode} maxFreshnessMs=${config.maxFreshnessMs} " +
                    "matteMode=${config.matteMode} matteLow=${config.matteLow} " +
                    "matteHigh=${config.matteHigh} matteGamma=${config.matteGamma} " +
                    "maskRotationPolicy=${config.maskRotationPolicy} " +
                    "segmentInputOrientationPolicy=${config.segmentInputOrientationPolicy} " +
                    "statsWarmupMs=${config.statsWarmupMs} segmentLongEdgePx=${config.segmentLongEdgePx} " +
                    "output=${config.outputWidth}x${config.outputHeight} model=$MODEL_ASSET_PATH",
            )
            // 1. Flutter output surface (main thread).
            try {
                val p = textureRegistry.createSurfaceProducer()
                producer = p
                p.setSize(config.outputWidth, config.outputHeight)
                outputSurface = p.getSurface()
                textureId = p.id()
            } catch (t: Throwable) {
                failStart(result, "surface_producer_create_failed:${t.javaClass.simpleName}:${t.message}")
                return
            }
            // 2. Background frame immediately so the texture is never blank.
            renderHandler.post { drawBackgroundOnly() }
            // 3. Offscreen consumer for the CameraX Preview stream.
            val dummySurface = dummySink.create(DUMMY_SINK_CREATE_TIMEOUT_MS)
            if (dummySurface == null) {
                failStart(result, "dummy_preview_sink_failed:${dummySink.createError ?: "unknown"}")
                return
            }
            // 4. Segmenter on its owned thread; camera + reply once it exists.
            val submittedCreate = try {
                segmenterExecutor.execute { createSegmenterOnOwnedThread(result, dummySurface) }
                true
            } catch (_: RejectedExecutionException) {
                false
            }
            if (!submittedCreate) failStart(result, "segmenter_executor_rejected")
        }

        private fun createSegmenterOnOwnedThread(result: MethodChannel.Result, dummySurface: Surface) {
            val createdAt = SystemClock.elapsedRealtime()
            var error: String? = null
            try {
                val baseOptions = BaseOptions.builder()
                    .setModelAssetPath(MODEL_ASSET_PATH)
                    .setDelegate(config.delegate)
                    .build()
                val options = ImageSegmenter.ImageSegmenterOptions.builder()
                    .setBaseOptions(baseOptions)
                    .setRunningMode(RunningMode.LIVE_STREAM)
                    .setOutputConfidenceMasks(config.outputConfidence)
                    .setOutputCategoryMask(config.outputCategory)
                    .setResultListener { segResult, input -> onSegmentResult(segResult, input) }
                    .setErrorListener { e -> onSegmentError(e) }
                    .build()
                val created = ImageSegmenter.createFromOptions(context, options)
                if (stopRequested.get()) {
                    try { created.close() } catch (_: Throwable) {}
                    error = "stopped_during_create"
                } else {
                    segmenter = created
                    segmenterReady = true
                }
            } catch (t: Throwable) {
                error = "segmenter_create_failed:${t.javaClass.simpleName}:${t.message}"
            }
            val createMs = SystemClock.elapsedRealtime() - createdAt
            val err = error
            mainHandler.post {
                if (err != null) {
                    failStart(result, err)
                    return@post
                }
                if (stopRequested.get() || disposed.get()) {
                    failStart(result, "stopped_before_camera_start")
                    return@post
                }
                Log.i(TAG, "segmenter ready in ${createMs}ms (backend=${config.backend}, LIVE_STREAM)")
                startCameraOnMain(result, dummySurface)
            }
        }

        private fun startCameraOnMain(result: MethodChannel.Result, dummySurface: Surface) {
            val cam = AndroidDuetCameraSource(context)
            camera = cam
            val analyzer = ImageAnalysis.Analyzer { proxy -> onAnalyze(proxy) }
            cam.start(
                targetSurface = dummySurface,
                onStarted = {
                    cameraStarted = true
                    Log.i(TAG, "camera started (front, Preview -> offscreen sink, ImageAnalysis -> segmenter)")
                },
                onError = { e ->
                    recordFailure("camera:${e.javaClass.simpleName}:${e.message}")
                },
                analyzer = analyzer,
            )
            // A missing CAMERA permission reports synchronously through onError.
            val early = lastError.get()
            if (early != null && early.startsWith("camera:")) {
                failStart(result, early)
                return
            }
            if (!replied.compareAndSet(false, true)) return
            replySafely(
                result,
                mapOf(
                    "pass" to true,
                    "textureId" to textureId,
                    "viewMode" to config.viewMode,
                    "backend" to config.backend,
                    "proofBoundary" to PROOF_BOUNDARY,
                    "backgroundMode" to config.backgroundMode,
                    "matteMode" to config.matteMode,
                    "matteLow" to config.matteLow.toDouble(),
                    "matteHigh" to config.matteHigh.toDouble(),
                    "matteGamma" to config.matteGamma.toDouble(),
                    "maskRotationPolicy" to config.maskRotationPolicy,
                    "segmentInputOrientationPolicy" to config.segmentInputOrientationPolicy,
                    "maxFreshnessMs" to config.maxFreshnessMs,
                    "statsWarmupMs" to config.statsWarmupMs,
                    "segmentLongEdgePx" to config.segmentLongEdgePx,
                    "outputWidth" to config.outputWidth,
                    "outputHeight" to config.outputHeight,
                    "model" to MODEL_ASSET_PATH,
                    "failureReason" to "",
                ),
            )
        }

        /** Main thread. Tears the session down and replies pass=false once. */
        private fun failStart(result: MethodChannel.Result, reason: String) {
            recordFailure(reason)
            Log.w(TAG, "$MARKER_FAIL phase=start reason=$reason")
            if (session === this) session = null
            try {
                stopAndRelease()
            } catch (t: Throwable) {
                Log.w(TAG, "failStart teardown threw: ${t.message}")
            }
            if (!replied.compareAndSet(false, true)) return
            replySafely(result, failureStartPayload(reason, config))
        }

        // ── Analysis thread ─────────────────────────────────────────────────

        private fun onAnalyze(proxy: ImageProxy) {
            val acquireNs = SystemClock.elapsedRealtimeNanos()
            if (stopRequested.get()) {
                proxy.close()
                return
            }
            val n = framesAnalyzed.incrementAndGet()
            if (n == 1L) {
                firstFrameAtMs = SystemClock.elapsedRealtime()
                cameraRotationDegrees = proxy.imageInfo.rotationDegrees
                if (firstFrameLogged.compareAndSet(false, true)) {
                    Log.i(
                        TAG,
                        "$MARKER_FIRST_FRAME width=${proxy.width} height=${proxy.height} " +
                            "format=${proxy.format} rotation=${proxy.imageInfo.rotationDegrees} " +
                            "sinceStartMs=${firstFrameAtMs - startedAtMs}",
                    )
                }
            }
            // Single in-flight frame; a wedged callback is released by a watchdog.
            val busy = inFlight.get()
            if (busy != null) {
                val readyNs = busy.inputReadyNs
                if (readyNs > 0L && acquireNs - readyNs > INFLIGHT_TIMEOUT_NS) {
                    if (inFlight.compareAndSet(busy, null)) {
                        inflightTimeouts.incrementAndGet()
                        recordFailure("inflight_timeout:seq=${busy.seq}")
                        busy.release()
                    }
                } else {
                    droppedBusy.incrementAndGet()
                    proxy.close()
                    return
                }
            }
            val rotation = proxy.imageInfo.rotationDegrees
            val convertStartNs = SystemClock.elapsedRealtimeNanos()
            val bitmap: Bitmap = try {
                proxy.toBitmap()
            } catch (t: Throwable) {
                recordFailure("frame_convert_failed:${t.javaClass.simpleName}:${t.message}")
                return
            } finally {
                try { proxy.close() } catch (_: Throwable) {}
            }
            val segmentBitmap: Bitmap = try {
                prepareBitmapForSegmenter(bitmap, rotation)
            } catch (t: Throwable) {
                recordFailure("segment_prepare_failed:${t.javaClass.simpleName}:${t.message}")
                if (!bitmap.isRecycled) {
                    try { bitmap.recycle() } catch (_: Throwable) {}
                }
                return
            }
            val convertDoneNs = SystemClock.elapsedRealtimeNanos()
            frameConvert.add(convertDoneNs - convertStartNs)
            if ((SystemClock.elapsedRealtime() - startedAtMs) >= config.statsWarmupMs) {
                warmFrameConvert.add(convertDoneNs - convertStartNs)
            }
            val nowMs = SystemClock.elapsedRealtime()
            val ts = if (nowMs <= lastTimestampMs) lastTimestampMs + 1 else nowMs
            lastTimestampMs = ts
            val segmentRotation = if (config.segmentInputOrientationPolicy == SEGMENT_INPUT_UPRIGHT_BITMAP) {
                0
            } else {
                rotation
            }
            val frame = FrameInFlight(
                frameSeq.incrementAndGet(),
                bitmap,
                segmentBitmap,
                rotation,
                segmentRotation,
                acquireNs,
                ts,
            )

            if (!segmenterReady || segmenterClosed) {
                // No segmenter (not yet created / closed): camera over background, unkeyed.
                skippedNotReady.incrementAndGet()
                postUnkeyedDraw(frame, callbackNs = -1L, reason = "segmenter_not_ready")
                return
            }
            if (!inFlight.compareAndSet(null, frame)) {
                droppedBusy.incrementAndGet()
                frame.release()
                return
            }
            frame.inputReadyNs = SystemClock.elapsedRealtimeNanos()
            try {
                segmenterExecutor.execute { segmentOnOwnedThread(frame) }
                submitted.incrementAndGet()
            } catch (_: RejectedExecutionException) {
                inFlight.compareAndSet(frame, null)
                skippedNotReady.incrementAndGet()
                frame.release()
            }
        }

        private fun prepareBitmapForSegmenter(source: Bitmap, rotationDegrees: Int): Bitmap {
            // Downscale before rotating (not after) so the 90/180/270 rotation transform
            // below runs on the small segmenter-sized bitmap instead of the full-resolution
            // camera frame; the long-edge scale factor is the same either way since it is
            // computed from maxOf(width, height), which 90/270 rotation only swaps.
            val downscaled = downscaleForSegmenter(source, recycleSourceIfScaled = false)
            if (config.segmentInputOrientationPolicy != SEGMENT_INPUT_UPRIGHT_BITMAP) {
                return downscaled
            }
            val normalizedRotation = ((rotationDegrees % 360) + 360) % 360
            if (normalizedRotation == 0) {
                return downscaled
            }
            // Exact 90/180/270 rotation needs no bilinear filtering.
            val rotate = Matrix().apply { postRotate(normalizedRotation.toFloat()) }
            val rotated = Bitmap.createBitmap(downscaled, 0, 0, downscaled.width, downscaled.height, rotate, false)
            if (downscaled !== source && !downscaled.isRecycled) {
                try { downscaled.recycle() } catch (_: Throwable) {}
            }
            return rotated
        }

        private fun downscaleForSegmenter(source: Bitmap, recycleSourceIfScaled: Boolean): Bitmap {
            val longEdge = config.segmentLongEdgePx
            if (longEdge <= 0) return source
            val maxEdge = maxOf(source.width, source.height)
            if (maxEdge <= longEdge) return source
            val scale = longEdge.toFloat() / maxEdge.toFloat()
            val targetWidth = (source.width * scale).roundToInt().coerceAtLeast(1)
            val targetHeight = (source.height * scale).roundToInt().coerceAtLeast(1)
            val scaled = Bitmap.createScaledBitmap(source, targetWidth, targetHeight, true)
            if (recycleSourceIfScaled && !source.isRecycled) {
                try { source.recycle() } catch (_: Throwable) {}
            }
            return scaled
        }

        // ── Segmenter thread ────────────────────────────────────────────────

        private fun segmentOnOwnedThread(frame: FrameInFlight) {
            val seg = segmenter
            if (seg == null || segmenterClosed || stopRequested.get()) {
                inFlight.compareAndSet(frame, null)
                skippedNotReady.incrementAndGet()
                frame.release()
                return
            }
            try {
                val image = BitmapImageBuilder(frame.segmentBitmap).build()
                frame.mpImage = image
                val options = ImageProcessingOptions.builder()
                    .setRotationDegrees(frame.segmentRotationDegrees)
                    .build()
                seg.segmentAsync(image, options, frame.timestampMs)
            } catch (t: Throwable) {
                recordFailure("segment_async_failed:${t.javaClass.simpleName}:${t.message}")
                if (inFlight.compareAndSet(frame, null)) {
                    postUnkeyedDraw(frame, callbackNs = -1L, reason = "segment_async_failed")
                } else {
                    frame.release()
                }
            }
        }

        // ── MediaPipe result thread ─────────────────────────────────────────

        private fun onSegmentResult(result: ImageSegmenterResult, input: MPImage) {
            val callbackNs = SystemClock.elapsedRealtimeNanos()
            masks.incrementAndGet()
            val frame = inFlight.get()
            if (frame == null) {
                orphanResults.incrementAndGet()
                closeResultQuietly(result)
                return
            }
            val resultTimestampMs = result.timestampMs()
            if (resultTimestampMs != frame.timestampMs) {
                val count = timestampMismatches.incrementAndGet()
                if (count <= 3L || count % 200L == 0L) {
                    Log.w(
                        TAG,
                        "result timestamp differs from in-flight frame seq=${frame.seq} " +
                            "resultTimestampMs=$resultTimestampMs frameTimestampMs=${frame.timestampMs} " +
                            "(count=$count)",
                    )
                }
                closeResultQuietly(result)
                inFlight.compareAndSet(frame, null)
                frame.release()
                return
            }
            if (frame.mpImage !== input) {
                // MediaPipe Tasks can return a distinct MPImage wrapper for an otherwise
                // valid in-flight result. Keep this as telemetry until a timestamp/keyed
                // result identity is available; object identity rejected every physical frame.
                val count = containerDiffers.incrementAndGet()
                if (count <= 3L || count % 200L == 0L) {
                    Log.w(TAG, "result input container differs from in-flight frame seq=${frame.seq} (count=$count)")
                }
            }
            if (stopRequested.get()) {
                closeResultQuietly(result)
                inFlight.compareAndSet(frame, null)
                frame.release()
                return
            }
            val alphaMask: AlphaMask? = try {
                extractAlphaMask(result)
            } catch (t: Throwable) {
                recordFailure("mask_extract_failed:${t.javaClass.simpleName}:${t.message}")
                null
            } finally {
                closeResultQuietly(result)
            }
            val extractDoneNs = SystemClock.elapsedRealtimeNanos()
            maskExtract.add(extractDoneNs - callbackNs)
            if (alphaMask == null) {
                postUnkeyedDraw(frame, callbackNs, reason = "mask_extract_failed")
                return
            }
            if (firstMaskAtMs < 0L) firstMaskAtMs = SystemClock.elapsedRealtime()
            inputReadyToCallback.add(callbackNs - frame.inputReadyNs)
            val warmStats = (SystemClock.elapsedRealtime() - startedAtMs) >= config.statsWarmupMs
            if (warmStats) warmMaskExtract.add(extractDoneNs - callbackNs)
            if (warmStats) warmInputReadyToCallback.add(callbackNs - frame.inputReadyNs)
            val ageMs = (callbackNs - frame.acquireNs) / 1_000_000L
            val fresh = ageMs <= config.maxFreshnessMs
            if (!fresh) staleMasks.incrementAndGet()
            val postNs = SystemClock.elapsedRealtimeNanos()
            val posted = renderHandler.post { drawMaskedFrame(frame, alphaMask, fresh, callbackNs, postNs, warmStats) }
            if (!posted) {
                inFlight.compareAndSet(frame, null)
                frame.release()
            }
        }

        private fun onSegmentError(e: RuntimeException) {
            segmenterErrors.incrementAndGet()
            recordFailure("segmenter_error:${e.javaClass.simpleName}:${e.message}")
            val frame = inFlight.get() ?: return
            postUnkeyedDraw(frame, callbackNs = SystemClock.elapsedRealtimeNanos(), reason = "segmenter_error")
        }

        private fun buildConfidenceDisplayAlpha(confidence: Float): Int {
            val c = if (confidence.isNaN()) 0f else confidence.coerceIn(0f, 1f)
            val shaped = when (config.matteMode) {
                MATTE_RAW -> c
                MATTE_BINARY -> if (c >= config.matteLow) 1f else 0f
                else -> {
                    val t = ((c - config.matteLow) / (config.matteHigh - config.matteLow)).coerceIn(0f, 1f)
                    val smooth = t * t * (3f - 2f * t)
                    Math.pow(smooth.toDouble(), config.matteGamma.toDouble()).toFloat()
                }
            }
            return (shaped * 255f).roundToInt().coerceIn(0, 255)
        }

        private fun confidenceToDisplayAlpha(confidence: Float): Int {
            val c = if (confidence.isNaN()) 0f else confidence.coerceIn(0f, 1f)
            val index = (c * 255f).roundToInt().coerceIn(0, 255)
            return confidenceAlphaLut[index].toInt() and 0xFF
        }

        private fun shouldRecordWarmStats(): Boolean =
            (SystemClock.elapsedRealtime() - startedAtMs) >= config.statsWarmupMs

        private fun confidenceScratch(count: Int): FloatArray {
            var scratch = confidenceFloatScratch
            if (scratch == null || scratch.size < count) {
                scratch = FloatArray(count)
                confidenceFloatScratch = scratch
            }
            return scratch
        }

        private fun alphaScratch(count: Int): ByteArray {
            var scratch = alphaByteScratch
            if (scratch == null || scratch.size < count) {
                scratch = ByteArray(count)
                alphaByteScratch = scratch
            }
            return scratch
        }

        private fun extractAlphaMask(result: ImageSegmenterResult): AlphaMask? {
            if (config.outputCategory) {
                val mask = result.categoryMask().orElse(null)
                if (mask == null) {
                    recordFailure("category_mask_missing")
                    return null
                }
                val w = mask.width
                val h = mask.height
                if (w <= 0 || h <= 0) {
                    recordFailure("category_mask_invalid_size:${w}x$h")
                    return null
                }
                val count = w * h
                val bufferStartNs = SystemClock.elapsedRealtimeNanos()
                val bytes = ByteBufferExtractor.extract(mask, MPImage.IMAGE_FORMAT_ALPHA).duplicate()
                val bufferDoneNs = SystemClock.elapsedRealtimeNanos()
                maskBufferExtract.add(bufferDoneNs - bufferStartNs)
                if (shouldRecordWarmStats()) warmMaskBufferExtract.add(bufferDoneNs - bufferStartNs)
                bytes.rewind()
                if (bytes.remaining() < count) {
                    recordFailure("category_mask_short_buffer:${bytes.remaining()}<$count")
                    return null
                }
                val alphaStartNs = SystemClock.elapsedRealtimeNanos()
                val alpha = alphaScratch(count)
                alpha.fill(0, 0, count)
                val personValue = config.categoryPersonValue
                var zeroCount = 0L
                var fullCount = 0L
                var otherCount = 0L
                var personCount = 0L
                val logLayout = !firstMaskLogged.get()
                for (i in 0 until count) {
                    val v = bytes.get(i).toInt() and 0xFF
                    if (logLayout) {
                        when (v) {
                            0 -> zeroCount++
                            255 -> fullCount++
                            else -> otherCount++
                        }
                    }
                    if (v == personValue) {
                        alpha[i] = 0xFF.toByte()
                        personCount++
                    }
                }
                val alphaDoneNs = SystemClock.elapsedRealtimeNanos()
                maskAlphaBuild.add(alphaDoneNs - alphaStartNs)
                if (shouldRecordWarmStats()) warmMaskAlphaBuild.add(alphaDoneNs - alphaStartNs)
                if (firstMaskLogged.compareAndSet(false, true)) {
                    val layout = linkedMapOf<String, Any?>(
                        "kind" to "category",
                        "width" to w,
                        "height" to h,
                        "maskCount" to 1,
                        "format" to "uint8_category->person_alpha",
                        "personValue" to personValue,
                        "zeroCount" to zeroCount,
                        "fullCount" to fullCount,
                        "otherCount" to otherCount,
                        "personPixels" to personCount,
                        "personFraction" to personCount.toDouble() / count,
                    )
                    firstMaskLayout = layout
                    Log.i(TAG, "$MARKER_FIRST_MASK $layout sinceStartMs=${SystemClock.elapsedRealtime() - startedAtMs}")
                }
                return AlphaMask(w, h, alpha, "category")
            }

            val list = result.confidenceMasks().orElse(null)
            if (list == null || list.isEmpty()) {
                recordFailure("confidence_masks_missing")
                return null
            }
            val mask = list[list.size - 1]
            val w = mask.width
            val h = mask.height
            if (w <= 0 || h <= 0) {
                recordFailure("confidence_mask_invalid_size:${w}x$h")
                return null
            }
            val count = w * h
            val bufferStartNs = SystemClock.elapsedRealtimeNanos()
            val floatBytes: ByteBuffer = ByteBufferExtractor.extract(mask, MPImage.IMAGE_FORMAT_VEC32F1)
            val bufferDoneNs = SystemClock.elapsedRealtimeNanos()
            maskBufferExtract.add(bufferDoneNs - bufferStartNs)
            if (shouldRecordWarmStats()) warmMaskBufferExtract.add(bufferDoneNs - bufferStartNs)
            val floats = floatBytes.duplicate().order(ByteOrder.nativeOrder()).asFloatBuffer()
            floats.rewind()
            if (floats.remaining() < count) {
                recordFailure("confidence_mask_short_buffer:${floats.remaining()}<$count")
                return null
            }
            val alphaStartNs = SystemClock.elapsedRealtimeNanos()
            val floatScratch = confidenceScratch(count)
            floats.get(floatScratch, 0, count)
            val alpha = alphaScratch(count)
            val lut = confidenceAlphaLut
            var minV = Float.MAX_VALUE
            var maxV = -Float.MAX_VALUE
            var sum = 0.0
            val logLayout = !firstMaskLogged.get()
            for (i in 0 until count) {
                val f = floatScratch[i]
                val c = when {
                    f.isNaN() -> 0f
                    f <= 0f -> 0f
                    f >= 1f -> 1f
                    else -> f
                }
                val index = (c * 255f + 0.5f).toInt()
                alpha[i] = lut[index]
                if (logLayout) {
                    if (c < minV) minV = c
                    if (c > maxV) maxV = c
                    sum += c
                }
            }
            val alphaDoneNs = SystemClock.elapsedRealtimeNanos()
            maskAlphaBuild.add(alphaDoneNs - alphaStartNs)
            if (shouldRecordWarmStats()) warmMaskAlphaBuild.add(alphaDoneNs - alphaStartNs)
            if (firstMaskLogged.compareAndSet(false, true)) {
                val layout = linkedMapOf<String, Any?>(
                    "kind" to "confidence",
                    "width" to w,
                    "height" to h,
                    "maskCount" to list.size,
                    "personIndex" to list.size - 1,
                    "format" to "vec32f1->uint8_alpha:${config.matteMode}",
                    "matteLow" to config.matteLow.toDouble(),
                    "matteHigh" to config.matteHigh.toDouble(),
                    "matteGamma" to config.matteGamma.toDouble(),
                    "min" to minV.toDouble(),
                    "max" to maxV.toDouble(),
                    "mean" to sum / count,
                )
                firstMaskLayout = layout
                Log.i(TAG, "$MARKER_FIRST_MASK $layout sinceStartMs=${SystemClock.elapsedRealtime() - startedAtMs}")
            }
            return AlphaMask(w, h, alpha, "confidence")
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

        // ── Render thread ───────────────────────────────────────────────────

        private fun postUnkeyedDraw(frame: FrameInFlight, callbackNs: Long, reason: String) {
            val posted = renderHandler.post { drawUnkeyedFrame(frame, callbackNs, reason) }
            if (!posted) {
                inFlight.compareAndSet(frame, null)
                frame.release()
            }
        }

        private fun ensureBackground(): Bitmap {
            val existing = backgroundBitmap
            if (existing != null && !existing.isRecycled) return existing
            val bmp = Bitmap.createBitmap(config.outputWidth, config.outputHeight, Bitmap.Config.ARGB_8888)
            val c = Canvas(bmp)
            if (config.backgroundMode == BACKGROUND_CHECKER) {
                val p = Paint()
                var y = 0
                var row = 0
                while (y < config.outputHeight) {
                    var x = 0
                    var col = 0
                    while (x < config.outputWidth) {
                        p.color = if ((row + col) % 2 == 0) CHECKER_LIGHT else CHECKER_DARK
                        c.drawRect(
                            x.toFloat(),
                            y.toFloat(),
                            minOf(x + CHECKER_CELL_PX, config.outputWidth).toFloat(),
                            minOf(y + CHECKER_CELL_PX, config.outputHeight).toFloat(),
                            p,
                        )
                        x += CHECKER_CELL_PX
                        col++
                    }
                    y += CHECKER_CELL_PX
                    row++
                }
            } else if (config.backgroundMode == BACKGROUND_PICTURE_STILL_C) {
                val still = try {
                    context.assets.open(STILL_C_ASSET_PATH).use { input ->
                        BitmapFactory.decodeStream(input)
                    }
                } catch (t: Throwable) {
                    if (pictureBackgroundLoadFailed.compareAndSet(false, true)) {
                        recordFailure("picture_background_decode_failed:${t.javaClass.simpleName}:${t.message}")
                    }
                    null
                }
                if (still == null || still.isRecycled || still.width <= 0 || still.height <= 0) {
                    if (pictureBackgroundLoadFailed.compareAndSet(false, true)) {
                        recordFailure("picture_background_decode_failed:null_or_empty")
                    }
                    c.drawColor(TEAL)
                } else {
                    try {
                        val scale = maxOf(
                            config.outputWidth.toFloat() / still.width.toFloat(),
                            config.outputHeight.toFloat() / still.height.toFloat(),
                        )
                        val srcWidth = (config.outputWidth / scale).roundToInt().coerceAtMost(still.width)
                        val srcHeight = (config.outputHeight / scale).roundToInt().coerceAtMost(still.height)
                        val srcLeft = ((still.width - srcWidth) / 2).coerceAtLeast(0)
                        val srcTop = ((still.height - srcHeight) / 2).coerceAtLeast(0)
                        c.drawBitmap(
                            still,
                            Rect(srcLeft, srcTop, srcLeft + srcWidth, srcTop + srcHeight),
                            Rect(0, 0, config.outputWidth, config.outputHeight),
                            drawPaint,
                        )
                    } finally {
                        try { still.recycle() } catch (_: Throwable) {}
                    }
                }
            } else {
                c.drawColor(TEAL)
            }
            backgroundBitmap = bmp
            return bmp
        }

        /** Rotation + center-crop + mirror matrix from a raw [cw]x[ch] camera frame to the output. */
        private fun cameraToOutputMatrix(cw: Int, ch: Int, rotationDegrees: Int): Matrix {
            val ow = config.outputWidth.toFloat()
            val oh = config.outputHeight.toFloat()
            val normalizedRotation = ((rotationDegrees % 360) + 360) % 360
            matrix.reset()
            matrix.postRotate(normalizedRotation.toFloat())
            val rotatedBounds = RectF(0f, 0f, cw.toFloat(), ch.toFloat())
            matrix.mapRect(rotatedBounds)
            matrix.postTranslate(-rotatedBounds.left, -rotatedBounds.top)
            val uprightWidth = rotatedBounds.width()
            val uprightHeight = rotatedBounds.height()
            val scale = maxOf(ow / uprightWidth, oh / uprightHeight)
            val dw = uprightWidth * scale
            val dh = uprightHeight * scale
            val dx = (ow - dw) / 2f
            val dy = (oh - dh) / 2f
            matrix.postScale(scale, scale)
            matrix.postTranslate(dx, dy)
            // Front camera: mirror horizontally so the user sees a mirror image.
            matrix.postScale(-1f, 1f, ow / 2f, oh / 2f)
            if (geometry == null) {
                geometry = linkedMapOf<String, Any?>(
                    "outputWidth" to config.outputWidth,
                    "outputHeight" to config.outputHeight,
                    "cameraFrameWidth" to cw,
                    "cameraFrameHeight" to ch,
                    "cameraFrameUprightWidth" to uprightWidth.toDouble(),
                    "cameraFrameUprightHeight" to uprightHeight.toDouble(),
                    "rotationDegrees" to normalizedRotation,
                    "scale" to scale.toDouble(),
                    "drawWidth" to dw.toDouble(),
                    "drawHeight" to dh.toDouble(),
                    "cropOffsetX" to dx.toDouble(),
                    "cropOffsetY" to dy.toDouble(),
                    "mirrored" to true,
                    "fit" to "rotate_center_crop_no_stretch",
                )
            }
            return matrix
        }

        private fun effectiveMaskRotationDegrees(rotationDegrees: Int): Int {
            val normalizedRotation = ((rotationDegrees % 360) + 360) % 360
            return when (config.maskRotationPolicy) {
                MASK_ROTATION_NONE -> 0
                MASK_ROTATION_INVERSE -> (360 - normalizedRotation) % 360
                else -> normalizedRotation
            }
        }

        private fun withOutputCanvas(block: (Canvas) -> Unit): Boolean {
            val surface = outputSurface ?: return false
            if (stopRequested.get()) return false
            var canvas: Canvas? = null
            var unlockStartNs = -1L
            try {
                val lockStartNs = SystemClock.elapsedRealtimeNanos()
                val locked: Canvas = surface.lockHardwareCanvas()
                val lockDoneNs = SystemClock.elapsedRealtimeNanos()
                outputCanvasLock.add(lockDoneNs - lockStartNs)
                val warmStats = (SystemClock.elapsedRealtime() - startedAtMs) >= config.statsWarmupMs
                if (warmStats) warmOutputCanvasLock.add(lockDoneNs - lockStartNs)
                canvas = locked
                val blockStartNs = SystemClock.elapsedRealtimeNanos()
                block(locked)
                val blockDoneNs = SystemClock.elapsedRealtimeNanos()
                outputCanvasBlock.add(blockDoneNs - blockStartNs)
                if (warmStats) warmOutputCanvasBlock.add(blockDoneNs - blockStartNs)
                return true
            } catch (t: Throwable) {
                outputDrawErrors.incrementAndGet()
                lastError.compareAndSet(null, "output_draw_failed:${t.javaClass.simpleName}:${t.message}")
                return false
            } finally {
                if (canvas != null) {
                    try {
                        unlockStartNs = SystemClock.elapsedRealtimeNanos()
                        surface.unlockCanvasAndPost(canvas)
                    } catch (_: Throwable) {
                    } finally {
                        if (unlockStartNs > 0L) {
                            val unlockDoneNs = SystemClock.elapsedRealtimeNanos()
                            outputCanvasUnlockPost.add(unlockDoneNs - unlockStartNs)
                            if ((SystemClock.elapsedRealtime() - startedAtMs) >= config.statsWarmupMs) {
                                warmOutputCanvasUnlockPost.add(unlockDoneNs - unlockStartNs)
                            }
                        }
                    }
                }
            }
        }

        private fun drawBackgroundOnly() {
            withOutputCanvas { canvas ->
                if (config.viewMode != VIEW_MODE_COMPOSITE) {
                    canvas.drawColor(Color.BLACK)
                } else {
                    canvas.drawBitmap(ensureBackground(), 0f, 0f, null)
                }
            }
        }

        private fun drawUnkeyedFrame(frame: FrameInFlight, callbackNs: Long, reason: String) {
            try {
                if (stopRequested.get() || frame.bitmap.isRecycled) return
                val bmp = frame.bitmap
                val ok = if (config.viewMode != VIEW_MODE_COMPOSITE) {
                    withOutputCanvas { canvas ->
                        canvas.drawColor(Color.BLACK)
                    }
                } else {
                    val m = cameraToOutputMatrix(bmp.width, bmp.height, frame.rotationDegrees)
                    withOutputCanvas { canvas ->
                        canvas.drawBitmap(ensureBackground(), 0f, 0f, null)
                        canvas.drawBitmap(bmp, m, drawPaint)
                    }
                }
                if (ok) {
                    drawnFrames.incrementAndGet()
                    if (unkeyedDraws.incrementAndGet() == 1L) Log.d(TAG, "first unkeyed draw reason=$reason")
                    val doneNs = SystemClock.elapsedRealtimeNanos()
                    if (callbackNs > 0L) callbackToDraw.add(doneNs - callbackNs)
                }
            } catch (t: Throwable) {
                recordFailure("draw_failed:${t.javaClass.simpleName}:${t.message}")
            } finally {
                inFlight.compareAndSet(frame, null)
                frame.release()
            }
        }

        private fun renderAlphaMaskToBitmap(mask: AlphaMask, isBinary: Boolean): Bitmap {
            val count = mask.width * mask.height
            var pixels = maskPixels
            if (pixels == null || pixels.size != count) {
                pixels = IntArray(count)
                maskPixels = pixels
            }
            val alphaBytes = mask.alpha
            if (isBinary) {
                for (i in 0 until count) {
                    val a = alphaBytes[i].toInt() and 0xFF
                    val gray = if (a >= 128) 0xFF else 0x00
                    pixels[i] = 0xFF000000.toInt() or (gray shl 16) or (gray shl 8) or gray
                }
            } else {
                for (i in 0 until count) {
                    val gray = alphaBytes[i].toInt() and 0xFF
                    pixels[i] = 0xFF000000.toInt() or (gray shl 16) or (gray shl 8) or gray
                }
            }
            var bmp = maskDebugBitmap
            if (bmp == null || bmp.isRecycled || bmp.width != mask.width || bmp.height != mask.height) {
                try { bmp?.recycle() } catch (_: Throwable) {}
                bmp = Bitmap.createBitmap(mask.width, mask.height, Bitmap.Config.ARGB_8888)
                maskDebugBitmap = bmp
            }
            bmp.setPixels(pixels, 0, mask.width, 0, 0, mask.width, mask.height)
            return bmp
        }

        /** Rotation + center-crop + mirror matrix from a raw [mw]x[mh] mask to the output surface. */
        private fun maskToOutputMatrix(mw: Int, mh: Int, rotationDegrees: Int): Matrix {
            val ow = config.outputWidth.toFloat()
            val oh = config.outputHeight.toFloat()
            val normalizedRotation = effectiveMaskRotationDegrees(rotationDegrees)
            maskMatrix.reset()
            maskMatrix.postRotate(normalizedRotation.toFloat())
            val rotatedBounds = RectF(0f, 0f, mw.toFloat(), mh.toFloat())
            maskMatrix.mapRect(rotatedBounds)
            maskMatrix.postTranslate(-rotatedBounds.left, -rotatedBounds.top)
            val uprightWidth = rotatedBounds.width()
            val uprightHeight = rotatedBounds.height()
            val scale = maxOf(ow / uprightWidth, oh / uprightHeight)
            val dw = uprightWidth * scale
            val dh = uprightHeight * scale
            val dx = (ow - dw) / 2f
            val dy = (oh - dh) / 2f
            maskMatrix.postScale(scale, scale)
            maskMatrix.postTranslate(dx, dy)
            // Front camera: mirror horizontally so the user sees a mirror image.
            maskMatrix.postScale(-1f, 1f, ow / 2f, oh / 2f)
            if (geometry == null) {
                geometry = linkedMapOf<String, Any?>(
                    "outputWidth" to config.outputWidth,
                    "outputHeight" to config.outputHeight,
                    "maskWidth" to mw,
                    "maskHeight" to mh,
                    "maskUprightWidth" to uprightWidth.toDouble(),
                    "maskUprightHeight" to uprightHeight.toDouble(),
                    "cameraRotationDegrees" to ((rotationDegrees % 360) + 360) % 360,
                    "maskRotationDegrees" to normalizedRotation,
                    "maskRotationPolicy" to config.maskRotationPolicy,
                    "scale" to scale.toDouble(),
                    "drawWidth" to dw.toDouble(),
                    "drawHeight" to dh.toDouble(),
                    "cropOffsetX" to dx.toDouble(),
                    "cropOffsetY" to dy.toDouble(),
                    "mirrored" to true,
                    "fit" to "rotate_center_crop_no_stretch",
                )
            }
            return maskMatrix
        }

        private fun copyMaskIntoReusableAlphaBitmap(mask: AlphaMask): Bitmap {
            var alphaBitmap = compositeAlphaBitmap
            if (alphaBitmap == null ||
                alphaBitmap.isRecycled ||
                alphaBitmap.width != mask.width ||
                alphaBitmap.height != mask.height
            ) {
                try { alphaBitmap?.recycle() } catch (_: Throwable) {}
                alphaBitmap = Bitmap.createBitmap(mask.width, mask.height, Bitmap.Config.ALPHA_8)
                compositeAlphaBitmap = alphaBitmap
                compositeAlphaBuffer = null
            }
            val rowBytes = alphaBitmap.rowBytes
            val needed = rowBytes * mask.height
            var buf = compositeAlphaBuffer
            if (buf == null || buf.capacity() < needed) {
                buf = ByteBuffer.allocate(needed)
                compositeAlphaBuffer = buf
            }
            buf.clear()
            if (rowBytes == mask.width) {
                buf.put(mask.alpha, 0, mask.width * mask.height)
            } else {
                for (y in 0 until mask.height) {
                    buf.position(y * rowBytes)
                    buf.put(mask.alpha, y * mask.width, mask.width)
                }
                buf.position(needed)
            }
            buf.flip()
            alphaBitmap.copyPixelsFromBuffer(buf)
            return alphaBitmap
        }

        private fun drawMaskedFrame(
            frame: FrameInFlight,
            mask: AlphaMask,
            fresh: Boolean,
            callbackNs: Long,
            postNs: Long,
            warmStats: Boolean,
        ) {
            val drawStartNs = SystemClock.elapsedRealtimeNanos()
            renderQueue.add(drawStartNs - postNs)
            if (warmStats) warmRenderQueue.add(drawStartNs - postNs)
            try {
                if (stopRequested.get() || frame.bitmap.isRecycled) return
                val bmp = frame.bitmap
                val ok: Boolean
                if (config.viewMode == VIEW_MODE_MASK || config.viewMode == VIEW_MODE_BINARY_MASK) {
                    val isBinary = config.viewMode == VIEW_MODE_BINARY_MASK
                    val maskBmp = renderAlphaMaskToBitmap(mask, isBinary)
                    val m = maskToOutputMatrix(mask.width, mask.height, frame.rotationDegrees)
                    ok = withOutputCanvas { canvas ->
                        canvas.drawColor(Color.BLACK)
                        canvas.drawBitmap(maskBmp, m, drawPaint)
                    }
                    if (ok) maskDebugDraws.incrementAndGet()
                } else {
                    if (fresh) {
                        val copyStartNs = SystemClock.elapsedRealtimeNanos()
                        val alphaBitmap = copyMaskIntoReusableAlphaBitmap(mask)
                        val copyDoneNs = SystemClock.elapsedRealtimeNanos()
                        maskBitmapCopy.add(copyDoneNs - copyStartNs)
                        if (warmStats) warmMaskBitmapCopy.add(copyDoneNs - copyStartNs)
                        val camMatrix = cameraToOutputMatrix(bmp.width, bmp.height, frame.rotationDegrees)
                        val mMask = maskToOutputMatrix(mask.width, mask.height, frame.rotationDegrees)
                        val renderBodyStartNs = SystemClock.elapsedRealtimeNanos()
                        ok = withOutputCanvas { canvas ->
                            canvas.drawBitmap(ensureBackground(), 0f, 0f, null)
                            val layer = canvas.saveLayer(
                                0f,
                                0f,
                                config.outputWidth.toFloat(),
                                config.outputHeight.toFloat(),
                                null,
                            )
                            try {
                                canvas.drawBitmap(bmp, camMatrix, drawPaint)
                                canvas.drawBitmap(alphaBitmap, mMask, maskPaint)
                            } finally {
                                canvas.restoreToCount(layer)
                            }
                        }
                        val renderBodyDoneNs = SystemClock.elapsedRealtimeNanos()
                        compositeRenderBody.add(renderBodyDoneNs - renderBodyStartNs)
                        if (warmStats) warmCompositeRenderBody.add(renderBodyDoneNs - renderBodyStartNs)
                        if (ok) {
                            if (firstCompositeLogged.compareAndSet(false, true)) {
                                Log.i(
                                    TAG,
                                    "$MARKER_FIRST_COMPOSITE camera=${bmp.width}x${bmp.height} " +
                                        "segment=${frame.segmentBitmap.width}x${frame.segmentBitmap.height} " +
                                        "mask=${mask.width}x${mask.height} cameraRotation=${frame.rotationDegrees} " +
                                        "maskRotationPolicy=${config.maskRotationPolicy} " +
                                        "maskRotation=${effectiveMaskRotationDegrees(frame.rotationDegrees)} " +
                                        "backgroundMode=${config.backgroundMode} output=${config.outputWidth}x${config.outputHeight}",
                                )
                            }
                            keyedDraws.incrementAndGet()
                        }
                    } else {
                        // Stale mask: camera over background, never counted as keyed truth.
                        val m = cameraToOutputMatrix(bmp.width, bmp.height, frame.rotationDegrees)
                        ok = withOutputCanvas { canvas ->
                            canvas.drawBitmap(ensureBackground(), 0f, 0f, null)
                            canvas.drawBitmap(bmp, m, drawPaint)
                        }
                        if (ok) unkeyedDraws.incrementAndGet()
                    }
                }
                if (ok) {
                    drawnFrames.incrementAndGet()
                    val doneNs = SystemClock.elapsedRealtimeNanos()
                    callbackToDraw.add(doneNs - callbackNs)
                    totalAcquireToDraw.add(doneNs - frame.acquireNs)
                    if (warmStats) {
                        warmCallbackToDraw.add(doneNs - callbackNs)
                        warmTotalAcquireToDraw.add(doneNs - frame.acquireNs)
                    }
                }
            } catch (t: Throwable) {
                recordFailure("draw_failed:${t.javaClass.simpleName}:${t.message}")
            } finally {
                inFlight.compareAndSet(frame, null)
                frame.release()
            }
        }

        private fun releaseRenderScratch() {
            try { backgroundBitmap?.recycle() } catch (_: Throwable) {}
            backgroundBitmap = null
            try { maskDebugBitmap?.recycle() } catch (_: Throwable) {}
            maskDebugBitmap = null
            try { compositeAlphaBitmap?.recycle() } catch (_: Throwable) {}
            compositeAlphaBitmap = null
            compositeAlphaBuffer = null
            maskPixels = null
        }

        // ── Stop (main thread) ──────────────────────────────────────────────

        fun stopAndRelease(): Map<String, Any?> {
            val alreadyStopped = !stopRequested.compareAndSet(false, true)
            val stopAtMs = SystemClock.elapsedRealtime()

            // 1. Camera first: no new analysis frames.
            try {
                camera?.stop()
            } catch (t: Throwable) {
                Log.w(TAG, "camera.stop threw: ${t.message}")
            }
            camera = null

            // 2. Segmenter close on its owned thread (bounded), then executor down.
            closeSegmenterBounded()

            // 3. Any frame still in flight.
            inFlight.getAndSet(null)?.release()

            // 4. Render thread: release scratch on its thread, then quit and join.
            val renderLatch = CountDownLatch(1)
            val renderPosted = renderHandler.post {
                try {
                    releaseRenderScratch()
                } finally {
                    renderLatch.countDown()
                }
            }
            if (renderPosted) {
                try {
                    renderLatch.await(RENDER_JOIN_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
            renderThread.quitSafely()
            try {
                renderThread.join(RENDER_JOIN_TIMEOUT_MS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }

            // 5. Dummy preview surface / SurfaceTexture / EGL on its thread.
            dummySink.release(DUMMY_SINK_RELEASE_TIMEOUT_MS)

            // 6. Flutter SurfaceProducer on the main thread.
            releaseProducerOnMain()

            val payload = buildSummary(stopAtMs, alreadyStopped)
            Log.i(TAG, "$MARKER_SUMMARY $payload")
            Log.i(TAG, if (payload["pass"] == true) MARKER_PASS else "$MARKER_FAIL reason=${payload["failureReason"]}")
            return payload
        }

        private fun closeSegmenterBounded() {
            segmenterClosed = true
            segmenterReady = false
            val latch = CountDownLatch(1)
            val posted = try {
                segmenterExecutor.execute {
                    try {
                        val seg = segmenter
                        segmenter = null
                        if (seg != null) {
                            try {
                                seg.close()
                            } catch (t: Throwable) {
                                Log.w(TAG, "ImageSegmenter.close threw: ${t.message}")
                            }
                        }
                    } finally {
                        latch.countDown()
                    }
                }
                true
            } catch (_: RejectedExecutionException) {
                false
            }
            var closedInTime = !posted
            if (posted) {
                closedInTime = try {
                    latch.await(SEGMENTER_CLOSE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    false
                }
            }
            if (!closedInTime) {
                Log.w(TAG, "segmenter close timed out after ${SEGMENTER_CLOSE_TIMEOUT_MS}ms; forcing executor shutdown")
                segmenterExecutor.shutdownNow()
            } else {
                segmenterExecutor.shutdown()
            }
        }

        private fun releaseProducerOnMain() {
            val p = producer
            producer = null
            outputSurface = null
            if (p == null) return
            if (Looper.myLooper() == mainHandler.looper) {
                try {
                    p.release()
                } catch (t: Throwable) {
                    Log.w(TAG, "producer.release threw: ${t.message}")
                }
                return
            }
            val latch = CountDownLatch(1)
            val posted = mainHandler.post {
                try {
                    p.release()
                } catch (t: Throwable) {
                    Log.w(TAG, "producer.release threw: ${t.message}")
                }
                latch.countDown()
            }
            if (posted) {
                try {
                    latch.await(RENDER_JOIN_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
        }

        private fun buildSummary(stopAtMs: Long, alreadyStopped: Boolean): Map<String, Any?> {
            val framesAnalyzedV = framesAnalyzed.get()
            val masksV = masks.get()
            val drawnV = drawnFrames.get()
            val keyedV = keyedDraws.get()
            val maskDebugV = maskDebugDraws.get()
            val failuresV = failures.get()
            val layout = firstMaskLayout
            val failureReason = when {
                failuresV > 0L -> lastError.get() ?: "failures_recorded"
                framesAnalyzedV == 0L -> "no_frames_analyzed"
                masksV == 0L -> "no_masks"
                config.viewMode == VIEW_MODE_COMPOSITE && keyedV == 0L -> "no_keyed_draws"
                config.viewMode != VIEW_MODE_COMPOSITE && maskDebugV == 0L -> "no_mask_debug_draws"
                layout == null -> "no_first_mask_layout"
                textureId < 0L -> "no_texture"
                else -> ""
            }
            val pass = failureReason.isEmpty()
            val runMs = stopAtMs - startedAtMs
            return linkedMapOf<String, Any?>(
                "pass" to pass,
                "proofBoundary" to PROOF_BOUNDARY,
                "viewMode" to config.viewMode,
                "backend" to config.backend,
                "backgroundMode" to config.backgroundMode,
                "matteMode" to config.matteMode,
                "matteLow" to config.matteLow.toDouble(),
                "matteHigh" to config.matteHigh.toDouble(),
                "matteGamma" to config.matteGamma.toDouble(),
                "maxFreshnessMs" to config.maxFreshnessMs,
                "statsWarmupMs" to config.statsWarmupMs,
                "segmentLongEdgePx" to config.segmentLongEdgePx,
                "textureId" to textureId,
                "model" to MODEL_ASSET_PATH,
                "runMs" to runMs,
                "cameraStarted" to cameraStarted,
                "alreadyStopped" to alreadyStopped,
                "framesAnalyzed" to framesAnalyzedV,
                "submitted" to submitted.get(),
                "masks" to masksV,
                "droppedBusy" to droppedBusy.get(),
                "staleMasks" to staleMasks.get(),
                "drawnFrames" to drawnV,
                "keyedDraws" to keyedV,
                "maskDebugDraws" to maskDebugV,
                "unkeyedDraws" to unkeyedDraws.get(),
                "containerDiffers" to containerDiffers.get(),
                "timestampMismatches" to timestampMismatches.get(),
                "failures" to failuresV,
                "skippedNotReady" to skippedNotReady.get(),
                "inflightTimeouts" to inflightTimeouts.get(),
                "orphanResults" to orphanResults.get(),
                "segmenterErrors" to segmenterErrors.get(),
                "outputDrawErrors" to outputDrawErrors.get(),
                "dummyPreviewFramesConsumed" to dummySink.framesConsumed.get(),
                "inputReadyToCallbackMeanMs" to inputReadyToCallback.meanMs(),
                "inputReadyToCallbackMaxMs" to inputReadyToCallback.maxMs(),
                "inputReadyToCallbackSamples" to inputReadyToCallback.samples(),
                "callbackToDrawMeanMs" to callbackToDraw.meanMs(),
                "callbackToDrawMaxMs" to callbackToDraw.maxMs(),
                "callbackToDrawSamples" to callbackToDraw.samples(),
                "totalAcquireToDrawMeanMs" to totalAcquireToDraw.meanMs(),
                "totalAcquireToDrawMaxMs" to totalAcquireToDraw.maxMs(),
                "totalAcquireToDrawSamples" to totalAcquireToDraw.samples(),
                "frameConvertMeanMs" to frameConvert.meanMs(),
                "frameConvertMaxMs" to frameConvert.maxMs(),
                "frameConvertSamples" to frameConvert.samples(),
                "maskExtractMeanMs" to maskExtract.meanMs(),
                "maskExtractMaxMs" to maskExtract.maxMs(),
                "maskExtractSamples" to maskExtract.samples(),
                "maskBufferExtractMeanMs" to maskBufferExtract.meanMs(),
                "maskBufferExtractMaxMs" to maskBufferExtract.maxMs(),
                "maskBufferExtractSamples" to maskBufferExtract.samples(),
                "maskAlphaBuildMeanMs" to maskAlphaBuild.meanMs(),
                "maskAlphaBuildMaxMs" to maskAlphaBuild.maxMs(),
                "maskAlphaBuildSamples" to maskAlphaBuild.samples(),
                "renderQueueMeanMs" to renderQueue.meanMs(),
                "renderQueueMaxMs" to renderQueue.maxMs(),
                "renderQueueSamples" to renderQueue.samples(),
                "maskBitmapCopyMeanMs" to maskBitmapCopy.meanMs(),
                "maskBitmapCopyMaxMs" to maskBitmapCopy.maxMs(),
                "maskBitmapCopySamples" to maskBitmapCopy.samples(),
                "compositeRenderBodyMeanMs" to compositeRenderBody.meanMs(),
                "compositeRenderBodyMaxMs" to compositeRenderBody.maxMs(),
                "compositeRenderBodySamples" to compositeRenderBody.samples(),
                "outputCanvasLockMeanMs" to outputCanvasLock.meanMs(),
                "outputCanvasLockMaxMs" to outputCanvasLock.maxMs(),
                "outputCanvasLockSamples" to outputCanvasLock.samples(),
                "outputCanvasBlockMeanMs" to outputCanvasBlock.meanMs(),
                "outputCanvasBlockMaxMs" to outputCanvasBlock.maxMs(),
                "outputCanvasBlockSamples" to outputCanvasBlock.samples(),
                "outputCanvasUnlockPostMeanMs" to outputCanvasUnlockPost.meanMs(),
                "outputCanvasUnlockPostMaxMs" to outputCanvasUnlockPost.maxMs(),
                "outputCanvasUnlockPostSamples" to outputCanvasUnlockPost.samples(),
                "warmInputReadyToCallbackMeanMs" to warmInputReadyToCallback.meanMs(),
                "warmInputReadyToCallbackMaxMs" to warmInputReadyToCallback.maxMs(),
                "warmInputReadyToCallbackSamples" to warmInputReadyToCallback.samples(),
                "warmCallbackToDrawMeanMs" to warmCallbackToDraw.meanMs(),
                "warmCallbackToDrawMaxMs" to warmCallbackToDraw.maxMs(),
                "warmCallbackToDrawSamples" to warmCallbackToDraw.samples(),
                "warmTotalAcquireToDrawMeanMs" to warmTotalAcquireToDraw.meanMs(),
                "warmTotalAcquireToDrawMaxMs" to warmTotalAcquireToDraw.maxMs(),
                "warmTotalAcquireToDrawSamples" to warmTotalAcquireToDraw.samples(),
                "warmFrameConvertMeanMs" to warmFrameConvert.meanMs(),
                "warmFrameConvertMaxMs" to warmFrameConvert.maxMs(),
                "warmFrameConvertSamples" to warmFrameConvert.samples(),
                "warmMaskExtractMeanMs" to warmMaskExtract.meanMs(),
                "warmMaskExtractMaxMs" to warmMaskExtract.maxMs(),
                "warmMaskExtractSamples" to warmMaskExtract.samples(),
                "warmMaskBufferExtractMeanMs" to warmMaskBufferExtract.meanMs(),
                "warmMaskBufferExtractMaxMs" to warmMaskBufferExtract.maxMs(),
                "warmMaskBufferExtractSamples" to warmMaskBufferExtract.samples(),
                "warmMaskAlphaBuildMeanMs" to warmMaskAlphaBuild.meanMs(),
                "warmMaskAlphaBuildMaxMs" to warmMaskAlphaBuild.maxMs(),
                "warmMaskAlphaBuildSamples" to warmMaskAlphaBuild.samples(),
                "warmRenderQueueMeanMs" to warmRenderQueue.meanMs(),
                "warmRenderQueueMaxMs" to warmRenderQueue.maxMs(),
                "warmRenderQueueSamples" to warmRenderQueue.samples(),
                "warmMaskBitmapCopyMeanMs" to warmMaskBitmapCopy.meanMs(),
                "warmMaskBitmapCopyMaxMs" to warmMaskBitmapCopy.maxMs(),
                "warmMaskBitmapCopySamples" to warmMaskBitmapCopy.samples(),
                "warmCompositeRenderBodyMeanMs" to warmCompositeRenderBody.meanMs(),
                "warmCompositeRenderBodyMaxMs" to warmCompositeRenderBody.maxMs(),
                "warmCompositeRenderBodySamples" to warmCompositeRenderBody.samples(),
                "warmOutputCanvasLockMeanMs" to warmOutputCanvasLock.meanMs(),
                "warmOutputCanvasLockMaxMs" to warmOutputCanvasLock.maxMs(),
                "warmOutputCanvasLockSamples" to warmOutputCanvasLock.samples(),
                "warmOutputCanvasBlockMeanMs" to warmOutputCanvasBlock.meanMs(),
                "warmOutputCanvasBlockMaxMs" to warmOutputCanvasBlock.maxMs(),
                "warmOutputCanvasBlockSamples" to warmOutputCanvasBlock.samples(),
                "warmOutputCanvasUnlockPostMeanMs" to warmOutputCanvasUnlockPost.meanMs(),
                "warmOutputCanvasUnlockPostMaxMs" to warmOutputCanvasUnlockPost.maxMs(),
                "warmOutputCanvasUnlockPostSamples" to warmOutputCanvasUnlockPost.samples(),
                "firstFrameSinceStartMs" to (if (firstFrameAtMs > 0L) firstFrameAtMs - startedAtMs else -1L),
                "firstMaskSinceStartMs" to (if (firstMaskAtMs > 0L) firstMaskAtMs - startedAtMs else -1L),
                "firstMaskLayout" to layout?.let { LinkedHashMap<String, Any?>(it) },
                "geometry" to geometry?.let { LinkedHashMap<String, Any?>(it) },
                "lastError" to (lastError.get() ?: ""),
                "failureReason" to failureReason,
                "claims" to listOf(
                    "rnd_diagnostic_only",
                    "camerax_imageanalysis_to_mediapipe_tasks_live_stream",
                    "static_background_canvas_to_flutter_texture",
                    "camerax_preview_offscreen_never_presented",
                ),
                "nonClaims" to listOf(
                    "no_video_background",
                    "no_export",
                    "no_production_duet",
                    "no_tiktok_quality_claim",
                    "no_gpu_confidence_masks",
                ),
            )
        }
    }
}
