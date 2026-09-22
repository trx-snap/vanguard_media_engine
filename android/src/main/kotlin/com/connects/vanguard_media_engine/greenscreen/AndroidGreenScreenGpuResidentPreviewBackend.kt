package com.connects.vanguard_media_engine.greenscreen

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.SurfaceTexture
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.CompatibilityList
import org.tensorflow.lite.gpu.GpuDelegate
import org.tensorflow.lite.gpu.GpuDelegateFactory
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.math.max

// -----------------------------------------------------------------------------
// ANDROID-GREENSCREEN-GPU-RESIDENT: self-contained GPU-resident live
// GreenScreen preview backend.
// -----------------------------------------------------------------------------
//
// Port of the proven RND gpuzero loop (MainActivity.kt TFLite GPU-delegate
// interpreter + gl_renderer.cpp GPU downscale / guided filter / composite)
// into a [AndroidGreenScreenPreviewBackend] that AndroidGreenScreenPreviewRenderLoop
// can drive exactly like AndroidGreenScreenPreviewCompositor. The RND native
// camera owner (native_bridge.cpp / camera_stream_reader.*) is NOT ported:
// the camera stays owned by AndroidGreenScreenCamera2Source, which renders
// into this backend's [cameraInputSurface] (SurfaceTexture over a native-owned
// GL_TEXTURE_EXTERNAL_OES texture), and the coordinator keeps admission,
// output SurfaceProducer, start/stop/dispose ordering and the public routes.
//
// Segmentation is self-contained: there is no CPU analysis stream, no mask
// callback and no stale mask queue. One drawFrame is one frame transaction on
// the render thread with the native EGL context current:
//   updateTexImage + getTransformMatrix (latch camera frame N)
//   -> native GPU downscale of frame N into the direct float input buffer
//   -> Interpreter.run (GpuDelegate; CPU XNNPACK only if the GPU delegate fails)
//   -> native upload of the mask into the coarse R8 texture
//   -> native guided filter / composite of frame N with mask N -> swap.
//
// Camera UV policy: every camera sample in every native pass (model input,
// guided-filter luminance, final composite) maps quad space through the
// latched SurfaceTexture transform matrix, i.e. the same proven
// `uSTMatrix * aTextureCoord` policy as AndroidGreenScreenPreviewCompositor.
// [setCameraFrameTransform] is therefore the no-op interface default, exactly
// like that compositor. The upright camera aspect for the aspect-fill
// viewport is derived from the transform matrix (axis swap => rotated), with
// the same 1920x1080 preview buffer default the CPU compositor uses.
//
// Ownership / lifecycle:
//   - Owns: native renderer handle (EGL display/context/pbuffer/window
//     surface, GL objects), the camera SurfaceTexture + [cameraInputSurface],
//     the TFLite Interpreter + GpuDelegate and their direct tensor buffers.
//   - Borrows: the output Surface (never released here; only the EGL window
//     surface wrapping it is destroyed on [detachOutputSurface]).
//   - Output loss destroys only the window surface; camera input survives.
//   - [release] is terminal and idempotent: interpreter/delegate, camera
//     Surface/SurfaceTexture, then the native renderer.
//   - Every heavy step (native init, interpreter creation, tensor validation)
//     runs inside the first [attachOutputSurface] on the render thread. If any
//     step fails, attach returns false with everything partial torn down, so
//     the render loop can fall back to the CPU compositor before the camera
//     is ever started.
//
// Backgrounds: SOLID_COLOR renders the requested ARGB; IMAGE decodes on the
// render thread (bounded to 2048px) and uploads through native, honoring
// aspectFill / aspectFit; VIDEO degrades to black exactly like the CPU
// compositor. [updateGreenScreenMask] is ignored (segmentation is internal).
//
// Threading: render-thread-only, except the SurfaceTexture frame-available
// callback (any looper; only sets [cameraFramePending]) and the volatile
// [cameraInputSurface] read.

class AndroidGreenScreenGpuResidentPreviewBackend(
    private val context: Context,
    private val modelAssetPath: String = DEFAULT_MODEL_ASSET,
) : AndroidGreenScreenPreviewBackend {

    companion object {
        private const val TAG = "GreenScreenGpuResident"

        /** RND-proven single-channel selfie segmenter (float32 NHWC [1,256,256,3] -> [1,256,256,1]). */
        const val DEFAULT_MODEL_ASSET = "selfie_segmenter_gpu.tflite"

        // Same deterministic landscape preview buffer default as
        // AndroidGreenScreenPreviewCompositor (Camera2 negotiates against it).
        private const val CAMERA_ST_DEFAULT_WIDTH = 1920
        private const val CAMERA_ST_DEFAULT_HEIGHT = 1080

        /** Upright aspect before the first transform matrix is latched (rotated landscape buffer). */
        private const val CAMERA_DEFAULT_UPRIGHT_ASPECT =
            CAMERA_ST_DEFAULT_HEIGHT.toFloat() / CAMERA_ST_DEFAULT_WIDTH.toFloat()

        /** Background images are downsampled on decode so the long side never exceeds this. */
        private const val MAX_BACKGROUND_IMAGE_DIMENSION = 2048

        /** After this many consecutive interpreter failures inference stops; the background stays visible. */
        private const val MAX_CONSECUTIVE_INFERENCE_FAILURES = 3

        private const val CPU_FALLBACK_THREADS = 4

        // Native camera-layer modes (GlesGreenScreenGpuResidentRenderer::CameraMode).
        private const val CAMERA_MODE_NONE = 0
        private const val CAMERA_MODE_PLACEHOLDER = 1
        private const val CAMERA_MODE_PASSTHROUGH = 2
        private const val CAMERA_MODE_MASKED = 3

        // RND defaults (gl_renderer.h): guided filter on, temporal off, despill on.
        private const val GUIDED_FILTER_ENABLED = true
        private const val TEMPORAL_STABILIZER_ENABLED = false
        private const val DESPILL_ENABLED = true

        /** Matches nativeStatsSummary dimension tokens like "720x1280". */
        private val DIMENSION_PATTERN = Regex("^(\\d+)x(\\d+)$")
    }

    /** Interpreter + delegate + direct tensor buffers, created on the render thread. */
    private class ModelSession(
        val interpreter: Interpreter,
        val gpuDelegate: GpuDelegate?,
        val inputBuffer: ByteBuffer,
        val outputBuffer: ByteBuffer,
        val inputWidth: Int,
        val inputHeight: Int,
        val maskWidth: Int,
        val maskHeight: Int,
        val delegateLabel: String,
        val inputShape: String,
        val outputShape: String,
    ) {
        fun closeQuietly() {
            try { interpreter.close() } catch (_: Throwable) {}
            try { gpuDelegate?.close() } catch (_: Throwable) {}
        }
    }

    private val bridge = AndroidGreenScreenGpuResidentNativeBridge

    // -- Native renderer + model (render-thread only; created in first attach) --

    private var nativeHandle = 0L
    private var model: ModelSession? = null
    private var coreReady = false

    // -- Camera ingest (survives output loss, released only in release) -------

    private var cameraSurfaceTexture: SurfaceTexture? = null

    @Volatile
    private var _cameraInputSurface: Surface? = null

    override val cameraInputSurface: Surface? get() = _cameraInputSurface

    private val cameraFramePending = AtomicBoolean(false)
    override val hasPendingCameraFrame: Boolean get() = cameraFramePending.get()

    private var hasCameraTexImage = false
    private val cameraStMatrix = FloatArray(16).also { android.opengl.Matrix.setIdentityM(it, 0) }
    private var cameraUprightAspect = CAMERA_DEFAULT_UPRIGHT_ASPECT

    // -- Output / layout state -------------------------------------------------

    private var outputAttached = false
    private var outputWidthPx = 0
    private var outputHeightPx = 0
    private var sourceRect: AndroidGreenScreenPixelRect? = null
    private var cameraRect: AndroidGreenScreenPixelRect? = null

    private val isReleased = AtomicBoolean(false)

    // -- Green-screen state ----------------------------------------------------

    private var greenScreenEnabled = false
    private var hasMask = false
    private var inferenceDisabled = false
    private var consecutiveInferenceFailures = 0

    private var background: AndroidGreenScreenBackground = AndroidGreenScreenBackground.VIDEO
    private var backgroundDirty = true
    private var backgroundImageLoadedPath: String? = null
    private var backgroundImageDecodeFailed = false

    // -- Telemetry (render-thread only) ----------------------------------------

    private var frameCount = 0L
    private var swappedFrameCount = 0L
    private var inferenceCount = 0L
    private var inferenceFailureCount = 0L
    private var totalInferenceNs = 0L
    private var maxInferenceNs = 0L
    private var firstFrameLogged = false
    private var firstInferenceLogged = false
    private var loggedIgnoredCpuMask = false
    private var sessionStartMs = 0L

    // -- Attach / detach -------------------------------------------------------

    override fun attachOutputSurface(surface: Surface, widthPx: Int, heightPx: Int): Boolean {
        if (isReleased.get()) return false
        if (!surface.isValid || widthPx <= 0 || heightPx <= 0) {
            Log.w(TAG, "attachOutputSurface rejected: valid=${surface.isValid} ${widthPx}x$heightPx")
            return false
        }
        if (!ensureCore()) return false

        return try {
            if (!bridge.nativeAttachOutputSurface(nativeHandle, surface, widthPx, heightPx)) {
                Log.w(TAG, "ANDROID_GREENSCREEN_GPU_RESIDENT_ATTACH_FAILED ${bridge.nativeLastError(nativeHandle)}")
                outputAttached = false
                return false
            }
            outputAttached = true
            outputWidthPx = widthPx
            outputHeightPx = heightPx
            true
        } catch (t: Throwable) {
            Log.w(TAG, "attachOutputSurface threw: ${t.message}")
            outputAttached = false
            false
        }
    }

    override fun detachOutputSurface() {
        outputAttached = false
        outputWidthPx = 0
        outputHeightPx = 0
        if (nativeHandle != 0L) {
            try { bridge.nativeDetachOutputSurface(nativeHandle) } catch (_: Throwable) {}
        }
    }

    // -- Layout ------------------------------------------------------------

    override fun setLayout(sourceRect: AndroidGreenScreenPixelRect, cameraRect: AndroidGreenScreenPixelRect) {
        this.sourceRect = sourceRect
        this.cameraRect = cameraRect
        pushLayoutToNative()
    }

    private fun pushLayoutToNative() {
        val src = sourceRect ?: return
        val cam = cameraRect ?: return
        if (nativeHandle == 0L) return
        bridge.nativeSetLayout(
            nativeHandle,
            src.left.toFloat(), src.top.toFloat(), src.width.toFloat(), src.height.toFloat(),
            cam.left.toFloat(), cam.top.toFloat(), cam.width.toFloat(), cam.height.toFloat(),
        )
    }

    // -- Green-screen controls ---------------------------------------------------

    override fun setGreenScreenEnabled(enabled: Boolean) {
        greenScreenEnabled = enabled
        if (!enabled) {
            hasMask = false
        }
    }

    /** CPU masks are ignored: segmentation is self-contained in this backend. */
    override fun updateGreenScreenMask(frame: AndroidGreenScreenSegmentationFrame) {
        if (!loggedIgnoredCpuMask) {
            loggedIgnoredCpuMask = true
            Log.d(TAG, "ANDROID_GREENSCREEN_GPU_RESIDENT_CPU_MASK_IGNORED backend=${frame.backend}")
        }
    }

    override fun setGreenScreenBackground(background: AndroidGreenScreenBackground) {
        if (this.background == background && !backgroundDirty) return
        this.background = background
        backgroundDirty = true
    }

    // -- Frame transaction -----------------------------------------------------

    override fun drawFrame(): Boolean {
        if (isReleased.get() || !coreReady || !outputAttached) return false
        val handle = nativeHandle
        if (handle == 0L) return false

        try {
            if (!bridge.nativeMakeCurrent(handle)) return false

            // 1. Latch the newest camera frame (frame N) on this thread.
            var latchedNewFrame = false
            val camSt = cameraSurfaceTexture
            if (camSt != null && cameraFramePending.compareAndSet(true, false)) {
                camSt.updateTexImage()
                camSt.getTransformMatrix(cameraStMatrix)
                cameraUprightAspect = deriveCameraUprightAspect(cameraStMatrix)
                bridge.nativeSetCameraTransform(handle, cameraStMatrix, cameraUprightAspect)
                hasCameraTexImage = true
                latchedNewFrame = true
                if (!firstFrameLogged) {
                    firstFrameLogged = true
                    Log.i(
                        TAG,
                        "ANDROID_GREENSCREEN_GPU_RESIDENT_FIRST_FRAME output=${outputWidthPx}x$outputHeightPx " +
                            "uprightAspect=$cameraUprightAspect stMatrix=[" +
                            cameraStMatrix.joinToString(",") { "%.3f".format(it) } + "]",
                    )
                }
            }

            // 2. Background upload (lazy; needs the context current).
            ensureBackgroundUploaded()

            // 3. Segmentation of exactly the latched frame N (no mask queue).
            var refineMask = false
            if (greenScreenEnabled && latchedNewFrame && !inferenceDisabled) {
                refineMask = runSegmentationOnLatchedFrame(handle)
            }

            // 4. Composite frame N with mask N and swap.
            val cameraMode = when {
                !hasCameraTexImage -> if (greenScreenEnabled) CAMERA_MODE_NONE else CAMERA_MODE_PLACEHOLDER
                greenScreenEnabled -> if (hasMask) CAMERA_MODE_MASKED else CAMERA_MODE_NONE
                else -> CAMERA_MODE_PASSTHROUGH
            }
            val swapped = bridge.nativeRenderFrame(handle, cameraMode, refineMask)
            frameCount++
            if (swapped) swappedFrameCount++
            return swapped
        } catch (t: Throwable) {
            Log.w(TAG, "drawFrame failed: ${t.javaClass.simpleName}: ${t.message}")
            return false
        }
    }

    /**
     * Downscale -> Interpreter.run -> mask upload for the frame latched by the
     * caller. Returns true when a new coarse mask was uploaded. Interpreter
     * failures are counted; after [MAX_CONSECUTIVE_INFERENCE_FAILURES] in a
     * row inference is disabled for the rest of the session (the background
     * stays visible, the camera layer is not drawn), mirroring the CPU
     * compositor's "no mask => background only" invariant.
     */
    private fun runSegmentationOnLatchedFrame(handle: Long): Boolean {
        val session = model ?: return false
        val tDownscale = SystemClock.elapsedRealtimeNanos()
        session.inputBuffer.rewind()
        if (!bridge.nativeDownscaleCameraToModelInput(handle, session.inputBuffer)) {
            Log.w(TAG, "ANDROID_GREENSCREEN_GPU_RESIDENT_DOWNSCALE_FAILED ${bridge.nativeLastError(handle)}")
            return false
        }
        val downscaleNs = SystemClock.elapsedRealtimeNanos() - tDownscale

        val tInference = SystemClock.elapsedRealtimeNanos()
        try {
            session.inputBuffer.rewind()
            session.outputBuffer.rewind()
            session.interpreter.run(session.inputBuffer, session.outputBuffer)
        } catch (t: Throwable) {
            inferenceFailureCount++
            consecutiveInferenceFailures++
            Log.w(
                TAG,
                "ANDROID_GREENSCREEN_GPU_RESIDENT_INFERENCE_FAILED consecutive=$consecutiveInferenceFailures " +
                    "${t.javaClass.simpleName}: ${t.message}",
            )
            if (consecutiveInferenceFailures >= MAX_CONSECUTIVE_INFERENCE_FAILURES) {
                inferenceDisabled = true
                hasMask = false
                Log.w(TAG, "ANDROID_GREENSCREEN_GPU_RESIDENT_INFERENCE_DISABLED after $consecutiveInferenceFailures failures")
            }
            return false
        }
        val inferenceNs = SystemClock.elapsedRealtimeNanos() - tInference
        consecutiveInferenceFailures = 0
        inferenceCount++
        totalInferenceNs += inferenceNs
        if (inferenceNs > maxInferenceNs) maxInferenceNs = inferenceNs

        session.outputBuffer.rewind()
        if (!bridge.nativeUploadCoarseMask(handle, session.outputBuffer, session.maskWidth, session.maskHeight)) {
            Log.w(TAG, "ANDROID_GREENSCREEN_GPU_RESIDENT_MASK_UPLOAD_FAILED ${bridge.nativeLastError(handle)}")
            return false
        }
        hasMask = true

        if (!firstInferenceLogged) {
            firstInferenceLogged = true
            Log.i(
                TAG,
                "ANDROID_GREENSCREEN_GPU_RESIDENT_FIRST_INFERENCE delegate=${session.delegateLabel} " +
                    "input=${session.inputShape} output=${session.outputShape} " +
                    "downscaleMs=${"%.2f".format(downscaleNs / 1_000_000.0)} " +
                    "inferenceMs=${"%.2f".format(inferenceNs / 1_000_000.0)} " +
                    "sinceStartMs=${SystemClock.elapsedRealtime() - sessionStartMs}",
            )
        }
        return true
    }

    // -- Release (terminal, idempotent, never throws) --------------------------

    override fun release() {
        if (!isReleased.compareAndSet(false, true)) return

        try { cameraSurfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}

        val handle = nativeHandle
        val avgInferenceMs = if (inferenceCount > 0) totalInferenceNs / inferenceCount / 1_000_000.0 else 0.0
        val nativeSummary = if (handle != 0L) {
            try { bridge.nativeStatsSummary(handle) } catch (_: Throwable) { "unavailable" }
        } else "not_created"
        Log.i(
            TAG,
            "ANDROID_GREENSCREEN_GPU_RESIDENT_RELEASE_SUMMARY frames=$frameCount swapped=$swappedFrameCount " +
                "inferences=$inferenceCount inferenceFailures=$inferenceFailureCount " +
                "avgInferenceMs=${"%.2f".format(avgInferenceMs)} maxInferenceMs=${"%.2f".format(maxInferenceNs / 1_000_000.0)} " +
                "delegate=${model?.delegateLabel ?: "none"} inferenceDisabled=$inferenceDisabled " +
                "uptimeMs=${if (sessionStartMs > 0) SystemClock.elapsedRealtime() - sessionStartMs else 0} " +
                "native=[$nativeSummary]",
        )

        teardownCoreQuietly()
    }

    // -- Diagnostics (render-thread-only; read-only, never mutates state) ------

    override fun diagnosticsSnapshot(): Map<String, Any?> {
        val snapshot = LinkedHashMap<String, Any?>()
        snapshot["backend"] = "gpu_resident"
        snapshot["coreReady"] = coreReady
        snapshot["outputAttached"] = outputAttached
        snapshot["outputWidthPx"] = outputWidthPx
        snapshot["outputHeightPx"] = outputHeightPx
        snapshot["greenScreenEnabled"] = greenScreenEnabled
        snapshot["hasMask"] = hasMask
        snapshot["inferenceDisabled"] = inferenceDisabled
        snapshot["frames"] = frameCount
        snapshot["swappedFrames"] = swappedFrameCount
        snapshot["inferences"] = inferenceCount
        snapshot["inferenceFailures"] = inferenceFailureCount
        snapshot["avgInferenceMs"] =
            if (inferenceCount > 0) totalInferenceNs / inferenceCount / 1_000_000.0 else 0.0
        snapshot["maxInferenceMs"] = maxInferenceNs / 1_000_000.0
        val session = model
        snapshot["delegate"] = session?.delegateLabel ?: "none"
        snapshot["modelInputWidth"] = session?.inputWidth
        snapshot["modelInputHeight"] = session?.inputHeight
        snapshot["maskWidth"] = session?.maskWidth
        snapshot["maskHeight"] = session?.maskHeight
        snapshot["cameraUprightAspect"] = cameraUprightAspect
        val handle = nativeHandle
        val nativeStatsRaw = if (handle != 0L) {
            try { bridge.nativeStatsSummary(handle) } catch (_: Throwable) { null }
        } else {
            null
        }
        snapshot["nativeStatsRaw"] = nativeStatsRaw
        snapshot["nativeStats"] = nativeStatsRaw?.let { parseNativeStats(it) }
        return snapshot
    }

    /**
     * Parses a [nativeStatsSummary]-style "key=value key=value ..." string
     * into a primitive map for diagnostics consumers. Never throws: any
     * unparsable token is dropped rather than aborting the whole snapshot.
     * Integral values become [Long], other numeric values become [Double],
     * dimension values like "720x1280" become a nested map with
     * width/height ints plus the original raw string, and anything else is
     * kept as its original string.
     */
    private fun parseNativeStats(raw: String): Map<String, Any?> {
        val result = LinkedHashMap<String, Any?>()
        try {
            for (token in raw.trim().split(Regex("\\s+"))) {
                if (token.isEmpty()) continue
                val eq = token.indexOf('=')
                if (eq <= 0) continue
                val key = token.substring(0, eq)
                val value = token.substring(eq + 1)
                result[key] = parseNativeStatValue(value)
            }
        } catch (_: Throwable) {
            // Best-effort: return whatever was parsed before the failure.
        }
        return result
    }

    private fun parseNativeStatValue(value: String): Any {
        val dimension = DIMENSION_PATTERN.matchEntire(value)
        if (dimension != null) {
            val width = dimension.groupValues[1].toIntOrNull()
            val height = dimension.groupValues[2].toIntOrNull()
            if (width != null && height != null) {
                val dims = LinkedHashMap<String, Any?>()
                dims["width"] = width
                dims["height"] = height
                dims["raw"] = value
                return dims
            }
        }
        value.toLongOrNull()?.let { return it }
        value.toDoubleOrNull()?.let { return it }
        return value
    }

    // -- Core bootstrap ------------------------------------------------------

    /**
     * One-time bootstrap on the render thread: native EGL/GL core (context
     * current afterwards), TFLite interpreter + tensor validation, model input
     * configuration, camera SurfaceTexture / [cameraInputSurface], then a
     * replay of the state received before attach. Everything partial is torn
     * down on failure so the render loop can fall back before camera start.
     */
    private fun ensureCore(): Boolean {
        if (coreReady) return true
        val t0 = SystemClock.elapsedRealtime()
        try {
            val handle = bridge.nativeCreate()
            if (handle == 0L) {
                Log.w(TAG, "ANDROID_GREENSCREEN_GPU_RESIDENT_BACKEND_INIT_FAILED reason=native_create_failed")
                return false
            }
            nativeHandle = handle

            // Interpreter on this very thread with the native context current:
            // the GPU delegate's GL backend binds to the current context.
            val session = openModelSession()
            model = session

            if (!bridge.nativeConfigureModelInput(handle, session.inputWidth, session.inputHeight)) {
                Log.w(
                    TAG,
                    "ANDROID_GREENSCREEN_GPU_RESIDENT_BACKEND_INIT_FAILED reason=model_input_configure_failed " +
                        bridge.nativeLastError(handle),
                )
                teardownCoreQuietly()
                return false
            }

            val textureId = bridge.nativeGetCameraTextureId(handle)
            if (textureId == 0) {
                Log.w(TAG, "ANDROID_GREENSCREEN_GPU_RESIDENT_BACKEND_INIT_FAILED reason=camera_texture_missing")
                teardownCoreQuietly()
                return false
            }
            val camTexture = SurfaceTexture(textureId)
            camTexture.setDefaultBufferSize(CAMERA_ST_DEFAULT_WIDTH, CAMERA_ST_DEFAULT_HEIGHT)
            // Any looper; only sets the flag. updateTexImage runs in drawFrame.
            camTexture.setOnFrameAvailableListener { cameraFramePending.set(true) }
            cameraSurfaceTexture = camTexture
            _cameraInputSurface = Surface(camTexture)

            bridge.nativeSetFilterToggles(handle, GUIDED_FILTER_ENABLED, TEMPORAL_STABILIZER_ENABLED, DESPILL_ENABLED)
            bridge.nativeSetCameraTransform(handle, cameraStMatrix, cameraUprightAspect)
            pushLayoutToNative()
            backgroundDirty = true

            coreReady = true
            sessionStartMs = SystemClock.elapsedRealtime()
            Log.i(
                TAG,
                "ANDROID_GREENSCREEN_GPU_RESIDENT_BACKEND_READY delegate=${session.delegateLabel} " +
                    "model=$modelAssetPath input=${session.inputShape} output=${session.outputShape} " +
                    "cameraTexture=$textureId cameraBuffer=${CAMERA_ST_DEFAULT_WIDTH}x$CAMERA_ST_DEFAULT_HEIGHT " +
                    "initMs=${SystemClock.elapsedRealtime() - t0}",
            )
            return true
        } catch (t: Throwable) {
            Log.w(
                TAG,
                "ANDROID_GREENSCREEN_GPU_RESIDENT_BACKEND_INIT_FAILED reason=exception " +
                    "${t.javaClass.simpleName}: ${t.message}",
            )
            teardownCoreQuietly()
            return false
        }
    }

    /**
     * Loads the model asset and creates the Interpreter with the RND delegate
     * policy: CompatibilityList best options when supported (else default
     * options), INFERENCE_PREFERENCE_SUSTAINED_SPEED, precision loss allowed;
     * CPU (XNNPACK, 4 threads) only if GPU delegate/interpreter creation
     * fails. Validates FLOAT32 NHWC [1,h,w,3] input and [1,h,w,1] / [1,h,w]
     * output; allocates direct native-order buffers from the real tensor
     * byte sizes. Throws on any unsupported model.
     */
    private fun openModelSession(): ModelSession {
        val modelBytes = loadModelBytes()
        verifyFlatBufferIdentifier(modelBytes)

        var delegate: GpuDelegate? = null
        var delegateLabel: String
        var options = Interpreter.Options()
        try {
            var gpuOptions: GpuDelegateFactory.Options? = null
            var source = "default_options"
            try {
                val compatibilityList = CompatibilityList()
                try {
                    if (compatibilityList.isDelegateSupportedOnThisDevice) {
                        gpuOptions = compatibilityList.bestOptionsForThisDevice
                        source = "compat_best_options"
                    }
                } finally {
                    try { compatibilityList.close() } catch (_: Throwable) {}
                }
            } catch (t: Throwable) {
                Log.w(TAG, "CompatibilityList unavailable: ${t.javaClass.simpleName}: ${t.message}")
            }
            val resolved = gpuOptions ?: GpuDelegateFactory.Options()
            resolved.setInferencePreference(GpuDelegateFactory.Options.INFERENCE_PREFERENCE_SUSTAINED_SPEED)
            resolved.setPrecisionLossAllowed(true)
            val gpuDelegate = GpuDelegate(resolved)
            delegate = gpuDelegate
            options.addDelegate(gpuDelegate)
            delegateLabel = "gpu:$source"
        } catch (t: Throwable) {
            Log.w(
                TAG,
                "ANDROID_GREENSCREEN_GPU_RESIDENT_DELEGATE_FALLBACK reason=gpu_delegate_create_failed " +
                    "${t.javaClass.simpleName}: ${t.message}",
            )
            try { delegate?.close() } catch (_: Throwable) {}
            delegate = null
            options = cpuInterpreterOptions()
            delegateLabel = "cpu_xnnpack"
        }

        var interpreter: Interpreter
        try {
            interpreter = Interpreter(modelBytes, options)
        } catch (t: Throwable) {
            val gpuDelegate = delegate ?: throw t
            Log.w(
                TAG,
                "ANDROID_GREENSCREEN_GPU_RESIDENT_DELEGATE_FALLBACK reason=gpu_interpreter_create_failed " +
                    "${t.javaClass.simpleName}: ${t.message}",
            )
            try { gpuDelegate.close() } catch (_: Throwable) {}
            delegate = null
            delegateLabel = "cpu_xnnpack"
            interpreter = Interpreter(modelBytes, cpuInterpreterOptions())
        }

        try {
            interpreter.allocateTensors()

            if (interpreter.inputTensorCount != 1) {
                throw IllegalStateException("expected 1 input tensor, got ${interpreter.inputTensorCount}")
            }
            if (interpreter.outputTensorCount != 1) {
                throw IllegalStateException("expected 1 output tensor, got ${interpreter.outputTensorCount}")
            }
            val inputTensor = interpreter.getInputTensor(0)
            val outputTensor = interpreter.getOutputTensor(0)
            if (inputTensor.dataType() != DataType.FLOAT32) {
                throw IllegalStateException("input dtype must be FLOAT32, got ${inputTensor.dataType()}")
            }
            if (outputTensor.dataType() != DataType.FLOAT32) {
                throw IllegalStateException("output dtype must be FLOAT32, got ${outputTensor.dataType()}")
            }
            val inputShape = inputTensor.shape()
            if (inputShape.size != 4 || inputShape[0] != 1 || inputShape[3] != 3 ||
                inputShape[1] <= 0 || inputShape[2] <= 0
            ) {
                throw IllegalStateException("input must be NHWC [1,h,w,3], got ${inputShape.toList()}")
            }
            val inputHeight = inputShape[1]
            val inputWidth = inputShape[2]

            val outputShape = outputTensor.shape()
            val maskHeight: Int
            val maskWidth: Int
            when {
                outputShape.size == 4 && outputShape[0] == 1 && outputShape[3] == 1 -> {
                    maskHeight = outputShape[1]
                    maskWidth = outputShape[2]
                }
                outputShape.size == 3 && outputShape[0] == 1 -> {
                    maskHeight = outputShape[1]
                    maskWidth = outputShape[2]
                }
                else -> throw IllegalStateException(
                    "output must be single-channel [1,h,w,1] or [1,h,w], got ${outputShape.toList()}",
                )
            }
            if (maskHeight <= 0 || maskWidth <= 0) {
                throw IllegalStateException("output has non-positive spatial dims ${outputShape.toList()}")
            }

            val inputBytes = inputTensor.numBytes()
            val outputBytes = outputTensor.numBytes()
            if (inputBytes != inputWidth * inputHeight * 3 * 4) {
                throw IllegalStateException("input numBytes=$inputBytes does not match [1,$inputHeight,$inputWidth,3] float32")
            }
            if (outputBytes != maskWidth * maskHeight * 4) {
                throw IllegalStateException("output numBytes=$outputBytes does not match [1,$maskHeight,$maskWidth,1] float32")
            }
            val inputBuffer = ByteBuffer.allocateDirect(inputBytes).order(ByteOrder.nativeOrder())
            val outputBuffer = ByteBuffer.allocateDirect(outputBytes).order(ByteOrder.nativeOrder())

            return ModelSession(
                interpreter = interpreter,
                gpuDelegate = delegate,
                inputBuffer = inputBuffer,
                outputBuffer = outputBuffer,
                inputWidth = inputWidth,
                inputHeight = inputHeight,
                maskWidth = maskWidth,
                maskHeight = maskHeight,
                delegateLabel = delegateLabel,
                inputShape = inputShape.toList().toString(),
                outputShape = outputShape.toList().toString(),
            )
        } catch (t: Throwable) {
            try { interpreter.close() } catch (_: Throwable) {}
            try { delegate?.close() } catch (_: Throwable) {}
            throw t
        }
    }

    private fun cpuInterpreterOptions(): Interpreter.Options =
        Interpreter.Options().apply {
            setNumThreads(CPU_FALLBACK_THREADS)
            setUseXNNPACK(true)
        }

    private fun loadModelBytes(): ByteBuffer {
        val assetManager = context.applicationContext?.assets ?: context.assets
        val raw = assetManager.open(modelAssetPath).use { it.readBytes() }
        return ByteBuffer.allocateDirect(raw.size).order(ByteOrder.nativeOrder()).apply {
            put(raw)
            rewind()
        }
    }

    /** A valid .tflite FlatBuffer carries the identifier "TFL3" at bytes [4..7]. */
    private fun verifyFlatBufferIdentifier(model: ByteBuffer) {
        if (model.capacity() < 8) {
            throw IllegalStateException("model too small (${model.capacity()} bytes)")
        }
        val ok = model.get(4) == 'T'.code.toByte() && model.get(5) == 'F'.code.toByte() &&
            model.get(6) == 'L'.code.toByte() && model.get(7) == '3'.code.toByte()
        if (!ok) throw IllegalStateException("model flatbuffer identifier is not TFL3")
    }

    /**
     * Upright camera aspect (width / height) after the SurfaceTexture transform.
     * The matrix is column-major: u' = m[0]*u + m[4]*v + m[12]. A 90/270-degree
     * rotation makes u' depend on v, swapping the buffer's width/height.
     */
    private fun deriveCameraUprightAspect(m: FloatArray): Float {
        val rotated = abs(m[0]) < abs(m[4])
        return if (rotated) {
            CAMERA_ST_DEFAULT_HEIGHT.toFloat() / CAMERA_ST_DEFAULT_WIDTH.toFloat()
        } else {
            CAMERA_ST_DEFAULT_WIDTH.toFloat() / CAMERA_ST_DEFAULT_HEIGHT.toFloat()
        }
    }

    // -- Background --------------------------------------------------------------

    /**
     * Applies [background] to native once per change, with the context current
     * (called from drawFrame). IMAGE decodes on this thread, bounded to
     * [MAX_BACKGROUND_IMAGE_DIMENSION]; a missing path or decode/upload
     * failure degrades to opaque black and is not retried for that path.
     */
    private fun ensureBackgroundUploaded() {
        if (!backgroundDirty) return
        val handle = nativeHandle
        if (handle == 0L) return
        backgroundDirty = false
        val bg = background
        when (bg.type) {
            AndroidGreenScreenBackgroundType.VIDEO -> {
                releaseBackgroundImageState(handle)
                bridge.nativeSetBackgroundBlack(handle)
            }
            AndroidGreenScreenBackgroundType.SOLID_COLOR -> {
                releaseBackgroundImageState(handle)
                bridge.nativeSetBackgroundSolidColor(handle, bg.argbColor)
            }
            AndroidGreenScreenBackgroundType.IMAGE -> {
                val aspectFill = bg.scaleMode != AndroidGreenScreenBackgroundScaleMode.ASPECT_FIT
                if (backgroundImageLoadedPath != null && backgroundImageLoadedPath == bg.filePath &&
                    !backgroundImageDecodeFailed
                ) {
                    bridge.nativeSetBackgroundImageScaleMode(handle, aspectFill)
                    return
                }
                if (backgroundImageLoadedPath != bg.filePath) {
                    releaseBackgroundImageState(handle)
                }
                backgroundImageLoadedPath = bg.filePath
                if (backgroundImageDecodeFailed) {
                    bridge.nativeSetBackgroundSolidColor(handle, AndroidGreenScreenBackground.VIDEO.argbColor)
                    return
                }
                if (!uploadBackgroundImage(handle, bg.filePath, aspectFill)) {
                    backgroundImageDecodeFailed = true
                    bridge.nativeSetBackgroundSolidColor(handle, AndroidGreenScreenBackground.VIDEO.argbColor)
                }
            }
        }
    }

    private fun releaseBackgroundImageState(handle: Long) {
        if (backgroundImageLoadedPath != null) {
            try { bridge.nativeClearBackgroundImage(handle) } catch (_: Throwable) {}
        }
        backgroundImageLoadedPath = null
        backgroundImageDecodeFailed = false
    }

    private fun uploadBackgroundImage(handle: Long, path: String?, aspectFill: Boolean): Boolean {
        if (path == null) {
            Log.w(TAG, "ANDROID_GREENSCREEN_GPU_RESIDENT_BACKGROUND_IMAGE_FALLBACK reason=missing_path path=")
            return false
        }
        val bitmap = try {
            decodeBoundedBitmap(path)
        } catch (t: Throwable) {
            null
        }
        if (bitmap == null) {
            Log.w(TAG, "ANDROID_GREENSCREEN_GPU_RESIDENT_BACKGROUND_IMAGE_FALLBACK reason=decode_failed path=$path")
            return false
        }
        try {
            val width = bitmap.width
            val height = bitmap.height
            val pixels = ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.nativeOrder())
            bitmap.copyPixelsToBuffer(pixels)
            pixels.rewind()
            val ok = bridge.nativeSetBackgroundImage(handle, pixels, width, height, aspectFill)
            if (!ok) {
                Log.w(
                    TAG,
                    "ANDROID_GREENSCREEN_GPU_RESIDENT_BACKGROUND_IMAGE_FALLBACK reason=upload_failed path=$path " +
                        bridge.nativeLastError(handle),
                )
            } else {
                Log.i(TAG, "ANDROID_GREENSCREEN_GPU_RESIDENT_BACKGROUND_IMAGE ${width}x$height aspectFill=$aspectFill")
            }
            return ok
        } finally {
            bitmap.recycle()
        }
    }

    /** Decodes [path] as ARGB_8888 with the long side bounded to [MAX_BACKGROUND_IMAGE_DIMENSION]. */
    private fun decodeBoundedBitmap(path: String): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sampleSize = 1
        while (max(bounds.outWidth, bounds.outHeight) / sampleSize > MAX_BACKGROUND_IMAGE_DIMENSION) {
            sampleSize *= 2
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = BitmapFactory.decodeFile(path, options) ?: return null
        if (decoded.config == Bitmap.Config.ARGB_8888) return decoded
        val converted = decoded.copy(Bitmap.Config.ARGB_8888, false)
        decoded.recycle()
        return converted
    }

    // -- Teardown ----------------------------------------------------------------

    /**
     * Releases everything this backend owns, in order: interpreter + delegate
     * (with the native context current), camera Surface + SurfaceTexture, then
     * the native renderer (window surface, GL objects, context, display).
     * Never touches the borrowed output Surface. Idempotent.
     */
    private fun teardownCoreQuietly() {
        val handle = nativeHandle
        if (handle != 0L) {
            try { bridge.nativeMakeCurrent(handle) } catch (_: Throwable) {}
        }
        model?.closeQuietly()
        model = null

        try { cameraSurfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
        try { _cameraInputSurface?.release() } catch (_: Throwable) {}
        _cameraInputSurface = null
        try { cameraSurfaceTexture?.release() } catch (_: Throwable) {}
        cameraSurfaceTexture = null

        if (handle != 0L) {
            try { bridge.nativeDestroy(handle) } catch (_: Throwable) {}
        }
        nativeHandle = 0L
        coreReady = false
        outputAttached = false
        hasCameraTexImage = false
        hasMask = false
        backgroundImageLoadedPath = null
        backgroundImageDecodeFailed = false
        backgroundDirty = true
    }
}
