package com.connects.vanguard_media_engine.duet

import android.content.Context
import android.os.Handler
import android.util.Log
import android.view.Surface
import androidx.camera.core.ImageAnalysis
import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenFilterNode
import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenImageProxyBackendSelector
import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenSegmentationBackend
import java.util.concurrent.atomic.AtomicBoolean

// -----------------------------------------------------------------------------
// VG-DUET-PHASE-6B / VG-DUET-PHASE-7: Foreground-provider seam.
// -----------------------------------------------------------------------------
//
// [AndroidDuetCameraForegroundProvider] wraps today's CameraX
// (AndroidDuetCameraSource) behind [AndroidDuetForegroundProvider] so
// AndroidDuetSessionCoordinator no longer owns camera/segmentation lifecycle
// directly. This is NOT the final straight-alpha/keyed-stream ingest contract.
//
// ANDROID-DUET-GPU-GREENSCREEN-SEGMENTER: the production greenScreen path is
// GPU-resident. The camera is bound PREVIEW-ONLY into the backend-owned
// camera surface (no ImageAnalysis use-case, no analyzer thread, no
// AndroidGreenScreenFilterNode), and keying happens inside the GLES
// compositor's own render pass (AndroidDuetPreviewCompositor +
// GlesGreenScreenGpuSegmenter). This provider's job for that path is to
// publish the application Context / model asset / event listener through
// [AndroidDuetGpuGreenScreenSegmenterBinding] BEFORE asking the sink to enable
// keying, and to translate the compositor's render-thread events into the
// coordinator-facing readiness ([firstMaskReady] / onFirstMaskReady) and
// terminal fallback (onFallback -> safe PiP) callbacks it already understands.
//
// The previous CameraX ImageAnalysis mask ladder (AndroidGreenScreenFilterNode
// over AndroidGreenScreenImageProxyBackendSelector: mediapipe_cpu -> mlkit,
// raw_tflite_gpu opt-in) is retained ONLY as an explicit debug lane
// ([usesLegacyImageAnalysisPath]); it is never selected without a debug key.

/**
 * Narrow sink interface covering exactly the methods the foreground provider
 * calls on the render loop. Decouples [AndroidDuetCameraForegroundProvider]
 * from the concrete [AndroidDuetPreviewRenderLoop]. Phase 7 provider-boundary
 * slice — does not introduce new straight-alpha ingest.
 */
interface AndroidDuetForegroundSink {
    /**
     * Backend-owned Android BufferQueue consumer endpoint exposed to CameraX.
     * The graphics consumer (SurfaceTexture for GLES, ImageReader/HardwareBuffer
     * for Vulkan) is allocated by the backend compositor and lives for the
     * lifetime of the render loop. The provider does NOT own this surface and
     * must NOT create, release, or transfer it. Read once in [start] to obtain
     * the CameraX preview target; if null or invalid, [start] must report an
     * error through [AndroidDuetForegroundProviderCallbacks.onError] and not
     * create any CameraX state.
     */
    val cameraInputSurface: android.view.Surface?

    fun setCameraFrameTransform(rotationDegrees: Int, mirrorHorizontal: Boolean)
    fun updateGreenScreenMask(frame: AndroidDuetSegmentationFrame)
    fun updateGreenScreenMaskHardwareBuffer(
        hardwareBuffer: android.hardware.HardwareBuffer,
        widthPx: Int,
        heightPx: Int,
        timestampUs: Long,
        onReleased: ((android.hardware.HardwareBuffer) -> Unit)? = null,
        acquireFenceFd: Int = -1,
    )
    fun setGreenScreenEnabled(enabled: Boolean)
}

/**
 * Callbacks the provider uses to report lifecycle and segmentation-ladder
 * events back to the session coordinator. Always invoked on the main thread.
 */
interface AndroidDuetForegroundProviderCallbacks {
    fun onStarted()
    fun onError(e: Exception)
    fun onFirstMaskReady()
    fun onDegraded(previousBackend: String, currentBackend: String, reason: String, userMessage: String)
    fun onFallback(previousBackend: String, reason: String, userMessage: String)
}

/**
 * Owns the Duet foreground (live camera + green-screen keying) source.
 * The provider owns the CameraX and segmentation lifecycle only; the
 * backend compositor owns the graphics consumer endpoint (SurfaceTexture /
 * ImageReader / HardwareBuffer acquisition).
 */
interface AndroidDuetForegroundProvider {
    /** True once the current keying pass has delivered its first real mask. */
    val firstMaskReady: Boolean

    /**
     * Starts the foreground source. Reads the camera input surface from
     * [sink.cameraInputSurface] — a backend-owned BufferQueue consumer
     * endpoint. Idempotent — a second call while already started is a no-op.
     * If [sink.cameraInputSurface] is null or invalid, reports an error via
     * [callbacks.onError] and creates no CameraX state. [layoutConfigMap]
     * selects the initial mode ("greenScreen" binds the keying analyzer
     * alongside camera preview from the first CameraX bind). Mask events are
     * forwarded to [sink].
     */
    fun start(
        sink: AndroidDuetForegroundSink,
        layoutConfigMap: Map<String, Any?>,
        callbacks: AndroidDuetForegroundProviderCallbacks,
    )

    /**
     * Hot-switches keying on/off without restarting the camera. Returns false
     * when [enabled] is true and keying could not be enabled (adapter
     * creation or analyzer bind failure); the caller must apply its own
     * fallback in that case, consulting [lastEnableFailureReason] for why.
     * Always returns true when [enabled] is false.
     */
    fun setGreenScreenEnabled(enabled: Boolean, layoutConfigMap: Map<String, Any?>): Boolean

    /**
     * Reason the most recent [setGreenScreenEnabled] call with `enabled = true`
     * returned false: `"adapter_creation_failed"` (adapter construction/start
     * threw or returned null) or `"bind_failed"` (adapter built but the CameraX
     * analyzer hot-rebind failed, including no camera source yet). Only
     * meaningful immediately after such a call returns false.
     */
    fun lastEnableFailureReason(): String

    /** Stops keying only (adapter/analyzer); the camera keeps running. */
    fun stopKeying()

    /** Stops the camera source. Call after [stopKeying]. */
    fun stop()

    /** Backend id to report even when no keying adapter is currently live. */
    fun reportedBackendId(): String
}

/**
 * Duet's camera-backed foreground provider: one [AndroidDuetCameraSource]
 * (preview-only by default) plus, for the production greenScreen path, one
 * installed [AndroidDuetGpuGreenScreenSegmenterBinding.Config] whose listener
 * feeds this provider's readiness/fallback state. The legacy debug lane keeps
 * one [AndroidGreenScreenFilterNode] at a time with the segmentation backend
 * ladder debug policy (raw GPU delegate/model overrides, MediaPipe CPU model
 * override, backend latch) and forwards CPU masks into the
 * [AndroidDuetForegroundSink] supplied to [start].
 *
 * Main-thread only for start/setGreenScreenEnabled/stopKeying/stop, matching
 * AndroidDuetCameraSource and AndroidGreenScreenFilterNode's own threading
 * contracts. Events from the compositor's render thread (GPU path) and
 * mask/degrade/fallback callbacks from the filter node (legacy lane) may
 * arrive off the main thread; this class hops them onto [mainHandler] before
 * touching any state or invoking [AndroidDuetForegroundProviderCallbacks].
 */
class AndroidDuetCameraForegroundProvider(
    private val context: Context?,
    private val mainHandler: Handler,
) : AndroidDuetForegroundProvider {

    companion object {
        private const val TAG = "DuetForegroundProvider"

        /** Backend id reported for the production GPU-resident segmenter path. */
        const val GPU_SEGMENTER_BACKEND_ID = "gpu_resident_tflite"

        /**
         * Explicit debug key selecting the legacy CameraX ImageAnalysis mask
         * lane: `layoutConfigMap["debugGreenScreenMaskPath"] == "image_analysis"`.
         * Any explicit `debugSegmentationBackend` (an ImageAnalysis ladder rung)
         * or `debugPreviewBackend` (the Vulkan compositor, which only consumes
         * CPU/HardwareBuffer masks) opt-in also selects that lane.
         */
        const val DEBUG_MASK_PATH_KEY = "debugGreenScreenMaskPath"
        const val DEBUG_MASK_PATH_IMAGE_ANALYSIS = "image_analysis"

        /** [AndroidDuetForegroundProvider.lastEnableFailureReason] token for a latched GPU segmenter failure. */
        const val ENABLE_FAILURE_GPU_SEGMENTER_UNAVAILABLE = "gpu_segmenter_unavailable"

        /**
         * Allowlist for `layoutConfigMap["debugRawTfliteGpuDelegateMode"]`. Kept in
         * sync with the backend's internal allowlist. Invalid values are silently
         * fallen back to `compat_best_or_default`; they must not fail session start.
         */
        internal val RAW_TFLITE_GPU_DELEGATE_MODE_ALLOWLIST = setOf(
            "compat_best_or_default",
            "forced_default",
            "sustained_speed",
            "force_opencl",
            "force_opengl",
        )

        /**
         * True when [layoutConfigMap] explicitly opts into the legacy CameraX
         * ImageAnalysis mask lane. Without any debug key the production
         * GPU-resident segmenter path is used.
         */
        internal fun usesLegacyImageAnalysisPath(layoutConfigMap: Map<String, Any?>): Boolean {
            if (layoutConfigMap[DEBUG_MASK_PATH_KEY] == DEBUG_MASK_PATH_IMAGE_ANALYSIS) return true
            if ((layoutConfigMap["debugSegmentationBackend"] as? String) != null) return true
            if ((layoutConfigMap["debugPreviewBackend"] as? String) != null) return true
            return false
        }
    }

    private var cameraSource: AndroidDuetCameraSource? = null
    private var greenScreenFilterNode: AndroidGreenScreenFilterNode? = null

    // -- GPU-resident segmenter path state (main thread) ------------------------

    /** Listener currently installed in [AndroidDuetGpuGreenScreenSegmenterBinding]; null when the GPU path is not enabled. */
    private var gpuSegmenterListener: GpuSegmenterListener? = null

    /**
     * Latched for this provider's lifetime once the compositor reported the
     * GPU segmenter unavailable (ES 3.1 missing, native/model bootstrap
     * failure, inference disabled). A later enable on the GPU path then fails
     * synchronously with [ENABLE_FAILURE_GPU_SEGMENTER_UNAVAILABLE] instead of
     * re-triggering the same async fallback.
     */
    private var gpuSegmenterUnavailableReason: String? = null

    /** Whether the most recent keying enable selected the GPU path (for [reportedBackendId]). */
    private var lastMaskPathWasGpu = false

    @Volatile private var gpuDelegateLabel: String? = null

    /**
     * One-way ladder latch. Set to the rung reached after a `green_screen_degraded`
     * so a later adapter rebuilt for this provider (e.g. layout switch back to
     * greenScreen) starts there instead of re-trying a higher rung.
     */
    private var greenScreenLatchedBackendId: String? = null

    @Volatile private var _firstMaskReady: Boolean = false
    override val firstMaskReady: Boolean get() = _firstMaskReady

    /** Set by [setGreenScreenEnabled] immediately before each `false` return. */
    private var _lastEnableFailureReason: String = "bind_failed"

    private var sink: AndroidDuetForegroundSink? = null
    private var callbacks: AndroidDuetForegroundProviderCallbacks? = null

    // ── Public API ─────────────────────────────────────────────────────────────

    override fun start(
        sink: AndroidDuetForegroundSink,
        layoutConfigMap: Map<String, Any?>,
        callbacks: AndroidDuetForegroundProviderCallbacks,
    ) {
        // Idempotent: camera source survives output-surface loss/re-attach, so a
        // repeat call while already started correctly does nothing.
        if (cameraSource != null) return
        val ctx = context ?: return

        // Read the camera input surface from the sink — the backend compositor
        // owns this BufferQueue consumer endpoint; the provider must not allocate,
        // release, or transfer it. If unavailable (backend not yet bootstrapped or
        // already torn down), report a clean error and create no CameraX state.
        val surface = sink.cameraInputSurface
        if (surface == null || !surface.isValid) {
            callbacks.onError(IllegalStateException("camera_input_surface_unavailable"))
            return
        }

        this.sink = sink
        this.callbacks = callbacks

        val mode = layoutConfigMap["mode"] as? String ?: "pip"
        val camSource = AndroidDuetCameraSource(ctx)
        cameraSource = camSource

        val legacyLane = mode == "greenScreen" && usesLegacyImageAnalysisPath(layoutConfigMap)
        val gpuLane = mode == "greenScreen" && !legacyLane
        if (mode == "greenScreen") {
            Log.i(
                TAG,
                "ANDROID_DUET_GREENSCREEN_MASK_PATH_SELECTED " +
                    "path=${if (gpuLane) "gpu_segmenter" else "image_analysis"} stage=start",
            )
        }

        // Legacy debug lane only: create and start the ImageAnalysis adapter
        // NOW — before the camera bind — so ImageAnalysis is part of the first
        // use-case set. The production GPU lane binds preview-only and installs
        // the compositor binding instead (no analyzer, no analysis thread).
        val analyzerForBind: ImageAnalysis.Analyzer? = if (legacyLane) {
            buildGreenScreenFilterNode(layoutConfigMap)
        } else null
        if (gpuLane) installGpuSegmenterBinding(ctx)

        camSource.start(
            targetSurface = surface,
            analyzer = analyzerForBind,
            onCameraFrameTransform = { rotationDegrees, mirrorHorizontal ->
                this.sink?.setCameraFrameTransform(rotationDegrees, mirrorHorizontal)
            },
            onStarted = {
                if (mode == "greenScreen" && (greenScreenFilterNode != null || gpuSegmenterListener != null)) {
                    this.sink?.setGreenScreenEnabled(true)
                }
                callbacks.onStarted()
            },
            onError = { e ->
                // Stop any partial CameraX state and null the source so a later
                // re-attach callback can retry cleanly.
                camSource.stop()
                if (cameraSource === camSource) {
                    cameraSource = null
                    // Always stop the adapter properly before clearing the ref,
                    // to avoid leaking the ML Kit Segmenter; and drop the GPU
                    // binding so the compositor cannot report into a dead start.
                    stopGreenScreenFilterNodeInternal()
                    uninstallGpuSegmenterBinding()
                }
                callbacks.onError(e)
            },
        )
    }

    override fun setGreenScreenEnabled(enabled: Boolean, layoutConfigMap: Map<String, Any?>): Boolean {
        val currentSink = sink
        if (enabled) {
            if (usesLegacyImageAnalysisPath(layoutConfigMap)) {
                Log.i(TAG, "ANDROID_DUET_GREENSCREEN_MASK_PATH_SELECTED path=image_analysis stage=enable")
                // Switching lanes: a GPU binding from a previous enable must not
                // stay installed while the CPU mask lane drives the compositor.
                uninstallGpuSegmenterBinding()
                lastMaskPathWasGpu = false
                if (greenScreenFilterNode == null) {
                    val filterNode = buildGreenScreenFilterNode(layoutConfigMap)
                    if (filterNode == null) {
                        Log.w(TAG, "buildGreenScreenFilterNode returned null — cannot enable green screen")
                        _lastEnableFailureReason = "adapter_creation_failed"
                        return false
                    }
                    // Hot-rebind: camera is already running, add ImageAnalysis.
                    val bound = cameraSource?.setAnalysisAnalyzer(filterNode) ?: false
                    if (!bound) {
                        Log.w(TAG, "setAnalysisAnalyzer failed during greenScreen switch")
                        stopGreenScreenFilterNodeInternal()
                        _lastEnableFailureReason = "bind_failed"
                        return false
                    }
                }
                currentSink?.setGreenScreenEnabled(true)
                return true
            }

            // Production GPU-resident lane.
            Log.i(TAG, "ANDROID_DUET_GREENSCREEN_MASK_PATH_SELECTED path=gpu_segmenter stage=enable")
            val unavailable = gpuSegmenterUnavailableReason
            if (unavailable != null) {
                Log.w(TAG, "GPU green-screen segmenter latched unavailable ($unavailable) — cannot enable green screen")
                _lastEnableFailureReason = ENABLE_FAILURE_GPU_SEGMENTER_UNAVAILABLE
                return false
            }
            val ctx = context
            if (ctx == null || cameraSource == null) {
                // Mirrors the legacy "no camera source yet" bind failure so the
                // coordinator applies the same safe-PiP fallback.
                Log.w(TAG, "GPU green-screen enable without context/camera source — bind_failed")
                _lastEnableFailureReason = "bind_failed"
                return false
            }
            // Switching lanes: retire a legacy adapter from a previous debug
            // enable (its ImageAnalysis use-case goes with it; the preview-only
            // camera continues).
            if (greenScreenFilterNode != null) {
                cameraSource?.setAnalysisAnalyzer(null)
                stopGreenScreenFilterNodeInternal()
            }
            installGpuSegmenterBinding(ctx)
            currentSink?.setGreenScreenEnabled(true)
            return true
        }
        // Switching away from greenScreen: remove the analysis use-case only
        // when one was bound (legacy lane), stop the filter node, drop the GPU
        // binding, disable compositor. Camera Preview continues untouched.
        if (greenScreenFilterNode != null) {
            cameraSource?.setAnalysisAnalyzer(null)
            stopGreenScreenFilterNodeInternal()
        }
        uninstallGpuSegmenterBinding()
        currentSink?.setGreenScreenEnabled(false)
        return true
    }

    override fun lastEnableFailureReason(): String = _lastEnableFailureReason

    override fun stopKeying() {
        stopGreenScreenFilterNodeInternal()
        uninstallGpuSegmenterBinding()
    }

    override fun stop() {
        uninstallGpuSegmenterBinding()
        val camSource = cameraSource ?: return
        camSource.stop()
        cameraSource = null
    }

    override fun reportedBackendId(): String =
        greenScreenFilterNode?.currentBackendId
            ?: (if (gpuSegmenterListener != null || lastMaskPathWasGpu) GPU_SEGMENTER_BACKEND_ID else null)
            ?: greenScreenLatchedBackendId
            ?: AndroidGreenScreenImageProxyBackendSelector(context).primaryBackendId()

    // ── GPU-resident segmenter binding ─────────────────────────────────────────

    /**
     * Publishes (or refreshes) this provider's configuration for the
     * compositor's GPU segmenter. Idempotent while a live listener exists;
     * otherwise installs a fresh listener so events from any previous enable
     * (already closed) are ignored. Must precede the sink enable.
     */
    private fun installGpuSegmenterBinding(ctx: Context) {
        lastMaskPathWasGpu = true
        val existing = gpuSegmenterListener
        if (existing != null && !existing.closed) {
            val current = AndroidDuetGpuGreenScreenSegmenterBinding.config
            if (current == null || current.listener !== existing) {
                AndroidDuetGpuGreenScreenSegmenterBinding.config = AndroidDuetGpuGreenScreenSegmenterBinding.Config(
                    context = ctx,
                    modelAssetPath = AndroidDuetGpuGreenScreenSegmenterBinding.DEFAULT_MODEL_ASSET,
                    listener = existing,
                )
            }
            return
        }
        val listener = GpuSegmenterListener()
        gpuSegmenterListener = listener
        _firstMaskReady = false
        AndroidDuetGpuGreenScreenSegmenterBinding.config = AndroidDuetGpuGreenScreenSegmenterBinding.Config(
            context = ctx,
            modelAssetPath = AndroidDuetGpuGreenScreenSegmenterBinding.DEFAULT_MODEL_ASSET,
            listener = listener,
        )
        Log.d(TAG, "GPU green-screen segmenter binding installed (model=${AndroidDuetGpuGreenScreenSegmenterBinding.DEFAULT_MODEL_ASSET})")
    }

    /**
     * Closes the live listener (late render-thread events become no-ops) and
     * clears the process-wide config only if it is still ours. Idempotent.
     * Resets [firstMaskReady] so a rebuilt keying pass must deliver a fresh
     * first mask, exactly like [stopGreenScreenFilterNodeInternal].
     */
    private fun uninstallGpuSegmenterBinding() {
        val listener = gpuSegmenterListener ?: return
        listener.closed = true
        gpuSegmenterListener = null
        val current = AndroidDuetGpuGreenScreenSegmenterBinding.config
        if (current != null && current.listener === listener) {
            AndroidDuetGpuGreenScreenSegmenterBinding.config = null
        }
        _firstMaskReady = false
        Log.d(TAG, "GPU green-screen segmenter binding uninstalled")
    }

    /**
     * Render-thread events from the compositor, hopped onto [mainHandler].
     * [closed] is flipped by [uninstallGpuSegmenterBinding]; every landing
     * re-checks it and that this listener is still the provider's live one.
     */
    private inner class GpuSegmenterListener : AndroidDuetGpuGreenScreenSegmenterBinding.Listener {
        @Volatile var closed = false

        override fun onSegmenterReady(delegateLabel: String) {
            if (closed) return
            gpuDelegateLabel = delegateLabel
        }

        override fun onFirstMask() {
            if (closed) return
            mainHandler.post { handleGpuFirstMask(this) }
        }

        override fun onSegmenterUnavailable(reason: String) {
            if (closed) return
            mainHandler.post { handleGpuSegmenterUnavailable(this, reason) }
        }
    }

    /** Same staleness gating as [handleFirstMask]: only the live listener may release a parked start. */
    private fun handleGpuFirstMask(listener: GpuSegmenterListener) {
        if (listener.closed || gpuSegmenterListener !== listener) return
        if (_firstMaskReady) return
        _firstMaskReady = true
        Log.i(TAG, "ANDROID_DUET_GPU_GREENSCREEN_FIRST_MASK_READY delegate=${gpuDelegateLabel ?: "unknown"}")
        callbacks?.onFirstMaskReady()
    }

    /**
     * Terminal for this provider: latches the reason (a later GPU enable fails
     * synchronously) and, when the listener is still live, reports the same
     * terminal fallback the legacy ladder reports when it is exhausted, so the
     * coordinator applies its existing safe-PiP fallback. The compositor has
     * already stopped drawing the camera layer (source stays visible).
     */
    private fun handleGpuSegmenterUnavailable(listener: GpuSegmenterListener, reason: String) {
        gpuSegmenterUnavailableReason = reason
        if (listener.closed || gpuSegmenterListener !== listener) {
            Log.d(TAG, "GPU green-screen segmenter unavailable from a stale listener latched ($reason) without event")
            return
        }
        Log.w(TAG, "[GreenScreen fallback] $GPU_SEGMENTER_BACKEND_ID->none ($reason)")
        callbacks?.onFallback(
            GPU_SEGMENTER_BACKEND_ID,
            reason,
            "Green screen unavailable. Switched to Picture-in-Picture",
        )
    }

    // ── Filter node lifecycle ─────────────────────────────────────────────────

    /**
     * Stops and nulls the filter node (idempotent). Its stop() closes its
     * active and any fallback backend.
     */
    private fun stopGreenScreenFilterNodeInternal() {
        val filterNode = greenScreenFilterNode ?: return
        try { filterNode.stop() } catch (_: Throwable) {}
        greenScreenFilterNode = null
        // A rebuilt filter node must deliver a fresh first mask before a start may proceed.
        _firstMaskReady = false
        Log.d(TAG, "Green-screen adapter stopped")
    }

    /**
     * Creates, stores, and starts a new [AndroidGreenScreenFilterNode]. Returns
     * the filter node (which also implements [ImageAnalysis.Analyzer]) so it
     * can be passed directly to [AndroidDuetCameraSource.start]. No-ops and
     * returns the existing filter node if one is already running; returns null
     * if construction or start throws.
     *
     * Backend ladder: the filter node starts on the latched rung when a prior
     * degradation happened, otherwise on the selector's primary (`mediapipe_cpu`
     * when the model asset is bundled, else `mlkit`). Backends open lazily on
     * the analysis thread, so start() here never loads a model on the main thread.
     */
    private fun buildGreenScreenFilterNode(layoutConfigMap: Map<String, Any?>): AndroidGreenScreenFilterNode? {
        if (greenScreenFilterNode != null) return greenScreenFilterNode
        val currentSink = sink ?: return null
        return try {
            // Debug-only opt-in: a physical smoke harness can start this provider
            // on a GPU rung by setting layoutConfigMap["debugSegmentationBackend"] =
            // "raw_tflite_gpu". If the selector does not support that rung (asset
            // missing, no context, API too low), the opt-in is silently ignored and
            // the selector's normal primary is used. The latch wins over the debug
            // key if already set (degradation never climbs back up).
            val debugBackend = layoutConfigMap["debugSegmentationBackend"] as? String

            // Read the raw GPU delegate mode only when the debug backend is raw_tflite_gpu.
            // Validate against the allowlist; fall back to default on invalid/missing values
            // without failing session start.
            val rawGpuDelegateMode: String? = if (debugBackend == AndroidGreenScreenSegmentationBackend.RAW_TFLITE_GPU) {
                val rawMode = layoutConfigMap["debugRawTfliteGpuDelegateMode"] as? String
                if (rawMode != null) {
                    if (rawMode in RAW_TFLITE_GPU_DELEGATE_MODE_ALLOWLIST) {
                        rawMode
                    } else {
                        Log.w(TAG,
                            "debugRawTfliteGpuDelegateMode='$rawMode' is not in allowlist " +
                                "$RAW_TFLITE_GPU_DELEGATE_MODE_ALLOWLIST; " +
                                "falling back to compat_best_or_default")
                        null
                    }
                } else {
                    null // absent → backend default (compat_best_or_default)
                }
            } else {
                null
            }

            // Read the raw GPU model asset path only when the debug backend is raw_tflite_gpu.
            // Validate against the model allowlist; warn and fall back to the selector default
            // (selfie_multiclass_256x256.tflite) on invalid/missing values without failing
            // session start.
            val rawGpuModelAssetPath: String? = if (debugBackend == AndroidGreenScreenSegmentationBackend.RAW_TFLITE_GPU) {
                val rawModel = layoutConfigMap["debugRawTfliteGpuModelAssetPath"] as? String
                if (rawModel != null) {
                    if (rawModel in AndroidGreenScreenImageProxyBackendSelector.RAW_TFLITE_GPU_MODEL_ALLOWLIST) {
                        rawModel
                    } else {
                        Log.w(TAG,
                            "debugRawTfliteGpuModelAssetPath='$rawModel' is not in allowlist " +
                                "${AndroidGreenScreenImageProxyBackendSelector.RAW_TFLITE_GPU_MODEL_ALLOWLIST}; " +
                                "falling back to default model")
                        null
                    }
                } else {
                    null // absent → selector default (selfie_multiclass_256x256.tflite)
                }
            } else {
                null
            }

            // Debug-only MediaPipe CPU model override, used by sustained R&D
            // smokes to compare bundled model assets without changing the
            // production default.
            val mediaPipeCpuModelAssetPath: String? =
                (layoutConfigMap["debugMediaPipeCpuModelAssetPath"] as? String)?.let { model ->
                    if (model in AndroidGreenScreenImageProxyBackendSelector.MEDIAPIPE_MODEL_ALLOWLIST) {
                        model
                    } else {
                        Log.w(TAG,
                            "debugMediaPipeCpuModelAssetPath='$model' is not in allowlist " +
                                "${AndroidGreenScreenImageProxyBackendSelector.MEDIAPIPE_MODEL_ALLOWLIST}; " +
                                "using production default")
                        null
                    }
                }

            val selector = AndroidGreenScreenImageProxyBackendSelector(
                context,
                rawGpuDelegateMode,
                rawGpuModelAssetPath,
                mediaPipeCpuModelAssetPath,
            )

            val initialBackendId: String = when {
                greenScreenLatchedBackendId != null ->
                    greenScreenLatchedBackendId!!
                debugBackend == AndroidGreenScreenSegmentationBackend.RAW_TFLITE_GPU &&
                    selector.supports(AndroidGreenScreenSegmentationBackend.RAW_TFLITE_GPU) -> {
                    Log.d(TAG,
                        "debugSegmentationBackend=raw_tflite_gpu: starting adapter on raw_tflite_gpu " +
                            "(delegateMode=${rawGpuDelegateMode ?: "compat_best_or_default"}, " +
                            "model=${rawGpuModelAssetPath ?: AndroidGreenScreenImageProxyBackendSelector.TFLITE_GPU_MODEL_ASSET_PATH})")
                    AndroidGreenScreenSegmentationBackend.RAW_TFLITE_GPU
                }
                else -> selector.primaryBackendId()
            }

            var adapterRef: AndroidGreenScreenFilterNode? = null
            // Start barrier: hop the FIRST mask (CPU or GPU path) onto the main
            // thread exactly once per adapter. The per-frame mask upload itself
            // stays on the analysis thread; nothing else is posted per frame.
            val firstMaskSignaled = AtomicBoolean(false)
            val signalFirstMask: () -> Unit = {
                if (firstMaskSignaled.compareAndSet(false, true)) {
                    mainHandler.post { handleFirstMask(adapterRef) }
                }
            }
            val adapter = AndroidGreenScreenFilterNode(
                selector = selector,
                initialBackendId = initialBackendId,
                onMask = { frame ->
                    currentSink.updateGreenScreenMask(frame)
                    signalFirstMask()
                },
                onGpuMask = { hardwareBuffer, widthPx, heightPx, timestampUs ->
                    currentSink.updateGreenScreenMaskHardwareBuffer(hardwareBuffer, widthPx, heightPx, timestampUs)
                    signalFirstMask()
                },
                onDegraded = { prev, next, reason, userMessage ->
                    Log.w(TAG, "[GreenScreen degraded] $prev->$next ($reason): $userMessage")
                    mainHandler.post { handleDegraded(adapterRef, prev, next, reason, userMessage) }
                },
                onFallback = { prev, next, reason, userMessage ->
                    Log.w(TAG, "[GreenScreen fallback] $prev->$next ($reason): $userMessage")
                    mainHandler.post { handleFallback(adapterRef, prev, reason, userMessage) }
                },
            )
            adapterRef = adapter
            greenScreenFilterNode = adapter
            adapter.start()
            Log.d(TAG,
                "Green-screen adapter built and started " +
                    "(initial backend=$initialBackendId, latched=$greenScreenLatchedBackendId)")
            adapter
        } catch (t: Throwable) {
            Log.w(TAG,
                "[GreenScreen fallback] ${reportedBackendId()}->none (adapter_start_failed): ${t.message}")
            // Ensure no partial adapter reference is left.
            try { greenScreenFilterNode?.stop() } catch (_: Throwable) {}
            greenScreenFilterNode = null
            null
        }
    }

    // ── Main-thread landings for adapter callbacks ────────────────────────────

    /**
     * Marks readiness and forwards to [callbacks] only when [adapter] is still
     * this provider's live adapter — a mask from a stale (stopped/replaced)
     * adapter proves nothing about what the compositor is drawing now.
     */
    private fun handleFirstMask(adapter: AndroidGreenScreenFilterNode?) {
        if (adapter == null || greenScreenFilterNode !== adapter) return
        if (_firstMaskReady) return
        _firstMaskReady = true
        callbacks?.onFirstMaskReady()
    }

    private fun handleDegraded(
        adapter: AndroidGreenScreenFilterNode?,
        previousBackend: String,
        currentBackend: String,
        reason: String,
        userMessage: String,
    ) {
        // Latch regardless of adapter staleness: the degradation really happened.
        greenScreenLatchedBackendId = currentBackend
        if (adapter == null || greenScreenFilterNode !== adapter) {
            Log.d(TAG, "Green-screen degrade from a stale adapter latched ($currentBackend) without event")
            return
        }
        callbacks?.onDegraded(previousBackend, currentBackend, reason, userMessage)
    }

    /**
     * Gated like [handleFirstMask]/[handleDegraded]: a terminal fallback from a
     * stale (already stopped/replaced) adapter must not tear down or apply PiP
     * fallback over a current, healthy adapter/session state.
     */
    private fun handleFallback(
        adapter: AndroidGreenScreenFilterNode?,
        previousBackend: String,
        reason: String,
        userMessage: String,
    ) {
        if (adapter == null || greenScreenFilterNode !== adapter) return
        callbacks?.onFallback(previousBackend, reason, userMessage)
    }
}
