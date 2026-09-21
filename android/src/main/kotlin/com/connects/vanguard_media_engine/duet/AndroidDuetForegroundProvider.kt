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
// (AndroidDuetCameraSource) + ImageAnalysis green-screen keying, consuming the
// neutral, GreenScreen-owned filter node/selector/backend types directly
// (AndroidGreenScreenFilterNode, AndroidGreenScreenImageProxyBackendSelector,
// AndroidGreenScreenSegmentationBackend) behind [AndroidDuetForegroundProvider]
// so AndroidDuetSessionCoordinator no longer owns camera/segmentation lifecycle
// directly. This is NOT the final straight-alpha/keyed-stream ingest contract.

/**
 * Narrow sink interface covering exactly the methods the foreground provider
 * calls on the render loop. Decouples [AndroidDuetCameraForegroundProvider]
 * from the concrete [AndroidDuetPreviewRenderLoop]. Phase 7 provider-boundary
 * slice — does not introduce new straight-alpha ingest.
 */
interface AndroidDuetForegroundSink {
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
 * Owns the Duet foreground (live camera + green-screen keying) source behind
 * a caller-owned compositor Surface and render sink.
 */
interface AndroidDuetForegroundProvider {
    /** True once the current keying pass has delivered its first real mask. */
    val firstMaskReady: Boolean

    /**
     * Starts the foreground source against [surface]. Idempotent — a second
     * call while already started is a no-op. [layoutConfigMap] selects the
     * initial mode ("greenScreen" binds the keying analyzer alongside camera
     * preview from the first CameraX bind). Mask events are forwarded to
     * [sink].
     */
    fun start(
        surface: Surface,
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
 * Duet's camera-backed foreground provider: one [AndroidDuetCameraSource] plus
 * one [AndroidGreenScreenFilterNode] at a time, matching the behavior
 * previously inlined in AndroidDuetSessionCoordinator. Owns the segmentation
 * backend ladder debug policy (raw GPU delegate/model overrides, MediaPipe CPU
 * model override, backend latch) and forwards masks directly into the
 * [AndroidDuetForegroundSink] supplied to [start].
 *
 * Main-thread only for start/setGreenScreenEnabled/stopKeying/stop, matching
 * AndroidDuetCameraSource and AndroidGreenScreenFilterNode's own threading
 * contracts. Mask/degrade/fallback callbacks from the filter node may arrive
 * off the analysis thread; this class hops them onto [mainHandler] before
 * touching any state or invoking [AndroidDuetForegroundProviderCallbacks].
 */
class AndroidDuetCameraForegroundProvider(
    private val context: Context?,
    private val mainHandler: Handler,
) : AndroidDuetForegroundProvider {

    companion object {
        private const val TAG = "DuetForegroundProvider"

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
    }

    private var cameraSource: AndroidDuetCameraSource? = null
    private var greenScreenFilterNode: AndroidGreenScreenFilterNode? = null

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
        surface: Surface,
        sink: AndroidDuetForegroundSink,
        layoutConfigMap: Map<String, Any?>,
        callbacks: AndroidDuetForegroundProviderCallbacks,
    ) {
        // Idempotent: camera source survives output-surface loss/re-attach, so a
        // repeat call while already started correctly does nothing.
        if (cameraSource != null) return
        val ctx = context ?: return

        this.sink = sink
        this.callbacks = callbacks

        val mode = layoutConfigMap["mode"] as? String ?: "pip"
        val camSource = AndroidDuetCameraSource(ctx)
        cameraSource = camSource

        // When the initial/effective layout mode is greenScreen, create and start
        // the adapter NOW — before the camera bind — so ImageAnalysis is part of
        // the first use-case set.
        val analyzerForBind: ImageAnalysis.Analyzer? = if (mode == "greenScreen") {
            buildGreenScreenFilterNode(layoutConfigMap)
        } else null

        camSource.start(
            targetSurface = surface,
            analyzer = analyzerForBind,
            onCameraFrameTransform = { rotationDegrees, mirrorHorizontal ->
                this.sink?.setCameraFrameTransform(rotationDegrees, mirrorHorizontal)
            },
            onStarted = {
                if (mode == "greenScreen" && greenScreenFilterNode != null) {
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
                    // to avoid leaking the ML Kit Segmenter.
                    stopGreenScreenFilterNodeInternal()
                }
                callbacks.onError(e)
            },
        )
    }

    override fun setGreenScreenEnabled(enabled: Boolean, layoutConfigMap: Map<String, Any?>): Boolean {
        val currentSink = sink
        if (enabled) {
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
        // Switching away from greenScreen: remove analysis use-case, stop
        // the filter node, disable compositor. Camera Preview continues.
        cameraSource?.setAnalysisAnalyzer(null)
        stopGreenScreenFilterNodeInternal()
        currentSink?.setGreenScreenEnabled(false)
        return true
    }

    override fun lastEnableFailureReason(): String = _lastEnableFailureReason

    override fun stopKeying() {
        stopGreenScreenFilterNodeInternal()
    }

    override fun stop() {
        val camSource = cameraSource ?: return
        camSource.stop()
        cameraSource = null
    }

    override fun reportedBackendId(): String =
        greenScreenFilterNode?.currentBackendId
            ?: greenScreenLatchedBackendId
            ?: AndroidGreenScreenImageProxyBackendSelector(context).primaryBackendId()

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
