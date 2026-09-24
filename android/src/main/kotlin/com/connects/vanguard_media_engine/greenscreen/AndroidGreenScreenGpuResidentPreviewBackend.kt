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
// aspectFill / aspectFit; VIDEO plays a looping local video file through a
// second native-owned GL_TEXTURE_EXTERNAL_OES lane (Slice 2), mirroring the
// camera ingest ownership split: native creates/owns the GL texture id
// (EnsureBackgroundVideoTexture), Kotlin wraps it in a SurfaceTexture/Surface
// and drives decoding via a private AndroidGreenScreenVideoBackgroundDecoder
// instance (independent of Duet, one per active video background). The
// decoder frame is latched on this render thread every drawFrame (exactly
// like the camera latch) and its ST matrix/dimensions/rotation/scale mode
// are pushed to native via nativeSetBackgroundVideoFrame, which also
// switches the native background mode to video; nativeClearBackgroundVideo
// releases the native texture and reverts to black when leaving video.
// Until the first frame decodes, whatever the background showed before the
// switch (an intentionally softer transition than IMAGE/SOLID_COLOR's
// harder cut) or black at session start stays visible. [updateGreenScreenMask]
// is ignored (segmentation is internal).
//
// Recording (VG-LIVE-GREENSCREEN-RECORDING): [setSegmentRecorderTarget]
// hands the recorder's MediaCodec input Surface to native
// (nativeAttachRecorderSurface), which wraps it in a second EGL window
// surface on the renderer's own display/config/context; it must be the same
// size as the attached output because the native composite geometry is
// derived from the output size. After every preview [drawFrame] that
// latched a new camera frame, [encodeRecorderFrame] asks native to re-draw
// the composite it just presented (composite pass only: same latched camera
// frame, refined alpha, background, layout and effective camera mode; no
// segmentation, refinement or alpha reallocation) into the encoder surface
// with the recorder's presentation time. The recorded file is therefore
// exactly what the preview shows, including background-only frames before
// the first mask. A failed encoder swap detaches the recorder here and
// reports [AndroidGreenScreenSegmentRecorderSurfaceTarget.onSurfaceFailed]
// so the recorder aborts instead of committing a truncated file.
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

        // Native recorder frame status (GlesGreenScreenGpuResidentRenderer::RecorderFrameStatus).
        private const val RECORDER_FRAME_SUBMITTED = 0
        private const val RECORDER_FRAME_SKIPPED = 1
        private const val RECORDER_FRAME_FAILED = 2

        // nativeRenderFrameCapturing result bits (VG-LIVE-GREENSCREEN-PHOTO).
        private const val RENDER_FRAME_SWAPPED_BIT = 1
        private const val RENDER_FRAME_CAPTURED_BIT = 2

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

    // -- Live recording encoder target (VG-LIVE-GREENSCREEN-RECORDING; render-thread only) --

    /**
     * Attached encoder target ([setSegmentRecorderTarget]). The EGL window
     * surface wrapping its MediaCodec input Surface lives in native
     * (nativeAttachRecorderSurface / nativeDetachRecorderSurface) on the
     * renderer's own config/context. Cleared by [setSegmentRecorderTarget]
     * (null), by a failed encoder frame ([encodeRecorderFrame]) and by
     * [release]; native additionally destroys the surface inside nativeDestroy
     * for the stop-during-recording case where the loop's detach is skipped.
     */
    private var recorderTarget: AndroidGreenScreenSegmentRecorderSurfaceTarget? = null
    private var recorderFramesSubmitted = 0L
    private var recorderFramesSkipped = 0L
    private var recorderFailureLogged = false

    /**
     * Armed one-shot still-photo read-back (VG-LIVE-GREENSCREEN-PHOTO),
     * consumed by the next [drawFrame] that reaches its native composite
     * (nativeRenderFrameCapturing). Render-thread only; failed (never left
     * dangling) by [detachOutputSurface] and [release].
     */
    private var compositeCaptureRequest: AndroidGreenScreenCompositeCaptureRequest? = null

    // -- Green-screen state ----------------------------------------------------

    private var greenScreenEnabled = false
    private var hasMask = false
    private var inferenceDisabled = false
    private var consecutiveInferenceFailures = 0

    private var background: AndroidGreenScreenBackground = AndroidGreenScreenBackground.VIDEO
    private var backgroundDirty = true
    private var backgroundImageLoadedPath: String? = null
    private var backgroundImageDecodeFailed = false

    // -- Background video (Slice 2; render-thread only except the frame-
    // available listener, which only sets backgroundVideoFramePending) -------

    private var backgroundVideoSurfaceTexture: SurfaceTexture? = null
    private var backgroundVideoSurface: Surface? = null
    private val backgroundVideoStMatrix = FloatArray(16).also { android.opengl.Matrix.setIdentityM(it, 0) }
    private val backgroundVideoFramePending = AtomicBoolean(false)
    private var backgroundVideoDecoder: AndroidGreenScreenVideoBackgroundDecoder? = null
    private var backgroundVideoLoadedPath: String? = null
    private var backgroundVideoDecodeFailed = false

    /** Written only from the decoder's own thread, read only from this render thread. */
    @Volatile private var backgroundVideoWidthPx = 0
    @Volatile private var backgroundVideoHeightPx = 0
    @Volatile private var backgroundVideoRotationDegrees = 0

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
        // A still-photo read-back armed against this output must not resolve
        // against a later re-attached one.
        failCompositeCaptureQuietly("output_detached")
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

            // 1b. Latch a new background video frame if one arrived since
            // last draw, and push it to native. Unconditional (like the
            // camera latch above) so the decoder's bounded SurfaceTexture
            // BufferQueue never backs up; a stale reference here (background
            // already switched away) is impossible because
            // releaseBackgroundVideoState always clears this field first.
            val bgVideoSt = backgroundVideoSurfaceTexture
            if (bgVideoSt != null && backgroundVideoFramePending.compareAndSet(true, false)) {
                try {
                    bgVideoSt.updateTexImage()
                    bgVideoSt.getTransformMatrix(backgroundVideoStMatrix)
                    val aspectFill = background.scaleMode != AndroidGreenScreenBackgroundScaleMode.ASPECT_FIT
                    bridge.nativeSetBackgroundVideoFrame(
                        handle, backgroundVideoStMatrix, backgroundVideoWidthPx, backgroundVideoHeightPx,
                        backgroundVideoRotationDegrees, aspectFill,
                    )
                    // The first video frame is now latched and visible in
                    // native: safe to release any image background this
                    // session was still holding onto during the transition
                    // (ensureBackgroundUploaded's VIDEO branch deliberately
                    // does not release it up front, so the old image stays
                    // visible instead of flashing black while the decoder
                    // starts up).
                    if (backgroundImageLoadedPath != null) {
                        releaseBackgroundImageState(handle)
                    }
                } catch (t: Throwable) {
                    Log.w(TAG, "background video updateTexImage failed: ${t.message}")
                }
            }

            // 2. Background upload (lazy; needs the context current).
            ensureBackgroundUploaded()

            // 3. Segmentation of exactly the latched frame N (no mask queue).
            var refineMask = false
            if (greenScreenEnabled && latchedNewFrame && !inferenceDisabled) {
                refineMask = runSegmentationOnLatchedFrame(handle)
            }

            // 4. Composite frame N with mask N and swap. With a still-photo
            // read-back armed (VG-LIVE-GREENSCREEN-PHOTO), native additionally
            // glReadPixels the composite between its composite pass and the
            // swap, so the photo is exactly this presented frame.
            val cameraMode = when {
                !hasCameraTexImage -> if (greenScreenEnabled) CAMERA_MODE_NONE else CAMERA_MODE_PLACEHOLDER
                greenScreenEnabled -> if (hasMask) CAMERA_MODE_MASKED else CAMERA_MODE_NONE
                else -> CAMERA_MODE_PASSTHROUGH
            }
            val capture = compositeCaptureRequest
            val swapped = if (capture != null) {
                compositeCaptureRequest = null
                renderFrameCapturing(handle, cameraMode, refineMask, capture)
            } else {
                bridge.nativeRenderFrame(handle, cameraMode, refineMask)
            }
            frameCount++
            if (swapped) swappedFrameCount++

            // 5. VG-LIVE-GREENSCREEN-RECORDING: after the preview swap, have
            // native re-draw the SAME composite (same latched camera frame,
            // alpha, background, layout, effective mode) into the attached
            // encoder surface -- once per new camera frame, so the encoder
            // never sees duplicates, whatever the preview swap returned. Never
            // changes this frame's preview result.
            if (latchedNewFrame && recorderTarget != null) {
                encodeRecorderFrame(handle)
            }
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

    // -- Still photo read-back (VG-LIVE-GREENSCREEN-PHOTO) ---------------------

    /**
     * Arms/disarms the one-shot composite read-back (see
     * [AndroidGreenScreenPreviewBackend.setCompositeCaptureRequest]). Rejects
     * (false, nothing armed) when released, before the native core exists, or
     * without an attached output: there is no composite to read. Render-thread only.
     */
    override fun setCompositeCaptureRequest(request: AndroidGreenScreenCompositeCaptureRequest?): Boolean {
        if (request == null) {
            compositeCaptureRequest = null
            return true
        }
        if (isReleased.get() || !coreReady || !outputAttached || nativeHandle == 0L) {
            Log.w(
                TAG,
                "ANDROID_LIVE_GREENSCREEN_PHOTO_REJECTED backend=gpu_resident reason=not_ready " +
                    "released=${isReleased.get()} coreReady=$coreReady outputAttached=$outputAttached",
            )
            return false
        }
        compositeCaptureRequest = request
        return true
    }

    /**
     * [drawFrame] step 4 with an armed read-back: renders and swaps exactly
     * like nativeRenderFrame, but native also glReadPixels the composite
     * (RGBA8, GL bottom-left row order) into a direct buffer between its
     * composite pass and the swap. Resolves [request] exactly once and
     * returns the swap result, so the preview outcome of this frame is
     * unchanged whether or not the read-back succeeded. Requires at least one
     * latched camera frame (a composite without the camera layer is not a
     * photo of the user). Never throws; render-thread only.
     */
    private fun renderFrameCapturing(
        handle: Long,
        cameraMode: Int,
        refineMask: Boolean,
        request: AndroidGreenScreenCompositeCaptureRequest,
    ): Boolean {
        val widthPx = outputWidthPx
        val heightPx = outputHeightPx
        if (!hasCameraTexImage || widthPx <= 0 || heightPx <= 0) {
            failCompositeCapture(request, if (!hasCameraTexImage) "no_camera_frame" else "invalid_output_size")
            return bridge.nativeRenderFrame(handle, cameraMode, refineMask)
        }
        val rgba: ByteBuffer
        val status: Int
        val readMs: Double
        try {
            val startNs = System.nanoTime()
            rgba = ByteBuffer.allocateDirect(widthPx * heightPx * 4).order(ByteOrder.nativeOrder())
            status = bridge.nativeRenderFrameCapturing(handle, cameraMode, refineMask, rgba)
            readMs = (System.nanoTime() - startNs) / 1_000_000.0
        } catch (t: Throwable) {
            Log.w(TAG, "nativeRenderFrameCapturing threw: ${t.javaClass.simpleName}: ${t.message}")
            failCompositeCapture(request, "readback_exception:${t.javaClass.simpleName}")
            return false
        }
        val swapped = (status and RENDER_FRAME_SWAPPED_BIT) != 0
        if ((status and RENDER_FRAME_CAPTURED_BIT) == 0) {
            val nativeError = try { bridge.nativeLastError(handle) } catch (_: Throwable) { "unavailable" }
            Log.w(
                TAG,
                "ANDROID_LIVE_GREENSCREEN_PHOTO_READBACK_FAILED backend=gpu_resident swapped=$swapped error=$nativeError",
            )
            failCompositeCapture(request, "native_readback_failed:" + sanitizeReason(nativeError))
            return swapped
        }
        rgba.rewind()
        Log.i(
            TAG,
            "ANDROID_LIVE_GREENSCREEN_PHOTO_CAPTURED backend=gpu_resident size=${widthPx}x$heightPx " +
                "renderReadMs=${"%.2f".format(readMs)} swapped=$swapped greenScreen=$greenScreenEnabled " +
                "maskReady=$hasMask cameraMode=$cameraMode",
        )
        try {
            request.onCaptured(rgba, widthPx, heightPx)
        } catch (t: Throwable) {
            Log.w(TAG, "composite capture onCaptured threw: ${t.message}")
        }
        return swapped
    }

    private fun failCompositeCapture(request: AndroidGreenScreenCompositeCaptureRequest, reason: String) {
        try {
            request.onFailed(reason)
        } catch (t: Throwable) {
            Log.w(TAG, "composite capture onFailed threw: ${t.message}")
        }
    }

    /** Fails and forgets an armed read-back so it never resolves on a later, unrelated frame. */
    private fun failCompositeCaptureQuietly(reason: String) {
        val request = compositeCaptureRequest ?: return
        compositeCaptureRequest = null
        failCompositeCapture(request, reason)
    }

    // -- Live recording (VG-LIVE-GREENSCREEN-RECORDING) ------------------------

    /**
     * Attaches (non-null) or detaches (null) a live recording's encoder
     * surface (see [AndroidGreenScreenPreviewBackend.setSegmentRecorderTarget]).
     * Any previously attached target is detached first, so this is idempotent
     * and a replace is a detach + attach. Attaching requires the core and an
     * attached output of exactly the target's size (native derives the
     * composite geometry from the output size and rejects anything else);
     * native then wraps the target's Surface in a second EGL window surface on
     * its own config/context, probes it and hands the preview window back.
     * Returns false, with nothing attached, on any failure so the coordinator
     * can fail the recording start cleanly. Must run on the render thread.
     */
    override fun setSegmentRecorderTarget(target: AndroidGreenScreenSegmentRecorderSurfaceTarget?): Boolean {
        detachRecorderQuietly()
        if (target == null) return true
        val handle = nativeHandle
        if (isReleased.get() || !coreReady || !outputAttached || handle == 0L) {
            Log.w(
                TAG,
                "ANDROID_LIVE_GREENSCREEN_RECORDER_SURFACE_REJECTED backend=gpu_resident reason=not_ready " +
                    "released=${isReleased.get()} coreReady=$coreReady outputAttached=$outputAttached",
            )
            return false
        }
        val surface = target.inputSurface
        if (surface == null || !surface.isValid || target.widthPx <= 0 || target.heightPx <= 0) {
            Log.w(
                TAG,
                "ANDROID_LIVE_GREENSCREEN_RECORDER_SURFACE_REJECTED backend=gpu_resident reason=invalid_surface " +
                    "valid=${surface?.isValid} size=${target.widthPx}x${target.heightPx}",
            )
            return false
        }
        if (target.widthPx != outputWidthPx || target.heightPx != outputHeightPx) {
            Log.w(
                TAG,
                "ANDROID_LIVE_GREENSCREEN_RECORDER_SURFACE_REJECTED backend=gpu_resident reason=size_mismatch " +
                    "recorder=${target.widthPx}x${target.heightPx} output=${outputWidthPx}x$outputHeightPx",
            )
            return false
        }
        return try {
            if (!bridge.nativeAttachRecorderSurface(handle, surface, target.widthPx, target.heightPx)) {
                Log.w(
                    TAG,
                    "ANDROID_LIVE_GREENSCREEN_RECORDER_SURFACE_FAILED backend=gpu_resident stage=nativeAttach " +
                        bridge.nativeLastError(handle),
                )
                return false
            }
            recorderTarget = target
            recorderFramesSubmitted = 0L
            recorderFramesSkipped = 0L
            recorderFailureLogged = false
            Log.i(
                TAG,
                "ANDROID_LIVE_GREENSCREEN_RECORDER_SURFACE_ATTACHED backend=gpu_resident " +
                    "size=${target.widthPx}x${target.heightPx} cameraLatched=$hasCameraTexImage " +
                    "maskReady=$hasMask greenScreen=$greenScreenEnabled inferenceDisabled=$inferenceDisabled",
            )
            true
        } catch (t: Throwable) {
            Log.w(
                TAG,
                "ANDROID_LIVE_GREENSCREEN_RECORDER_SURFACE_FAILED backend=gpu_resident stage=exception " +
                    "${t.javaClass.simpleName}: ${t.message}",
            )
            try { bridge.nativeDetachRecorderSurface(handle) } catch (_: Throwable) {}
            false
        }
    }

    /**
     * Asks native to re-draw the composite [drawFrame] just presented into the
     * attached encoder surface, stamped with the target's presentation time.
     * Frames the target declines (negative PTS: recorder finishing / canceled)
     * are skipped without a native call. A native failure (EGL/GL error on the
     * encoder surface, typically the recorder having released it after its
     * own encoder failure) is logged once, reported through
     * [AndroidGreenScreenSegmentRecorderSurfaceTarget.onSurfaceFailed] exactly
     * once so the recorder aborts instead of committing a truncated file, and
     * detaches the recorder. Never throws and never affects the preview result.
     */
    private fun encodeRecorderFrame(handle: Long) {
        val target = recorderTarget ?: return
        val ptsNs = try {
            target.nextFramePresentationTimeNs()
        } catch (t: Throwable) {
            -1L
        }
        if (ptsNs < 0L) {
            recorderFramesSkipped++
            return
        }
        val status = try {
            bridge.nativeRenderRecorderFrame(handle, ptsNs)
        } catch (t: Throwable) {
            Log.w(TAG, "nativeRenderRecorderFrame threw: ${t.javaClass.simpleName}: ${t.message}")
            RECORDER_FRAME_FAILED
        }
        when (status) {
            RECORDER_FRAME_SUBMITTED -> {
                recorderFramesSubmitted++
                try { target.onFrameSubmitted(ptsNs) } catch (_: Throwable) {}
                if (recorderFramesSubmitted == 1L) {
                    Log.i(
                        TAG,
                        "ANDROID_LIVE_GREENSCREEN_RECORDER_FIRST_FRAME backend=gpu_resident ptsNs=$ptsNs " +
                            "frame=${target.widthPx}x${target.heightPx} greenScreen=$greenScreenEnabled maskReady=$hasMask",
                    )
                }
            }
            RECORDER_FRAME_SKIPPED -> recorderFramesSkipped++
            else -> {
                val nativeError = try { bridge.nativeLastError(handle) } catch (_: Throwable) { "unavailable" }
                if (!recorderFailureLogged) {
                    recorderFailureLogged = true
                    Log.w(
                        TAG,
                        "ANDROID_LIVE_GREENSCREEN_RECORDER_FRAME_FAILED backend=gpu_resident status=$status " +
                            "error=$nativeError framesSubmitted=$recorderFramesSubmitted",
                    )
                }
                // Tell the recorder first (it stops handing out timestamps and
                // aborts on its worker), then destroy the EGL wrapper so no
                // further frame touches the dead surface.
                try {
                    target.onSurfaceFailed("gpu_resident_recorder_frame_failed:" + sanitizeReason(nativeError))
                } catch (t: Throwable) {
                    Log.w(TAG, "onSurfaceFailed threw: ${t.message}")
                }
                detachRecorderQuietly()
            }
        }
    }

    /**
     * Destroys only the native encoder EGL window surface (never the
     * recorder-owned Surface behind it) and forgets the target. Idempotent;
     * tolerates a recorder Surface that is already dead (recorder canceled
     * first) and a missing native handle.
     */
    private fun detachRecorderQuietly() {
        val target = recorderTarget
        recorderTarget = null
        val handle = nativeHandle
        if (handle != 0L) {
            try { bridge.nativeDetachRecorderSurface(handle) } catch (_: Throwable) {}
        }
        if (target != null) {
            Log.i(
                TAG,
                "ANDROID_LIVE_GREENSCREEN_RECORDER_SURFACE_DETACHED backend=gpu_resident " +
                    "framesSubmitted=$recorderFramesSubmitted framesSkipped=$recorderFramesSkipped",
            )
        }
    }

    /** Collapses a free-form native error into one whitespace-free reason token. */
    private fun sanitizeReason(raw: String): String =
        raw.trim().ifEmpty { "unknown" }.replace(Regex("\\s+"), "_")

    // -- Release (terminal, idempotent, never throws) --------------------------

    override fun release() {
        if (!isReleased.compareAndSet(false, true)) return

        try { cameraSurfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
        // Still-photo read-back armed for a frame that will never be drawn.
        failCompositeCaptureQuietly("released")

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
        snapshot["recorderAttached"] = recorderTarget != null
        snapshot["recorderFramesSubmitted"] = recorderFramesSubmitted
        snapshot["recorderFramesSkipped"] = recorderFramesSkipped
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
                // Deliberately does NOT release the image background here:
                // switching to video must keep whatever was previously
                // visible (image, solid color, or a prior video's last
                // frame) on screen until the first decoded video frame is
                // actually latched and pushed (see drawFrame's step 1b),
                // rather than clearing to black up front.
                ensureBackgroundVideoProvider(handle, bg)
            }
            AndroidGreenScreenBackgroundType.SOLID_COLOR -> {
                releaseBackgroundImageState(handle)
                releaseBackgroundVideoState(handle)
                bridge.nativeSetBackgroundSolidColor(handle, bg.argbColor)
            }
            AndroidGreenScreenBackgroundType.IMAGE -> {
                releaseBackgroundVideoState(handle)
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

    /**
     * Lazily (re)starts a looping [AndroidGreenScreenVideoBackgroundDecoder]
     * for [bg]'s file path against a native-owned OES texture. No-ops once a
     * decoder matching [bg]'s filePath is already active, or once setup has
     * already failed for that path (never retries every frame). Releases the
     * previous video provider first when the path actually changes. Must run
     * on the render thread with the native context current. Non-blocking:
     * decoding itself always happens on the decoder's own thread.
     */
    private fun ensureBackgroundVideoProvider(handle: Long, bg: AndroidGreenScreenBackground) {
        if (backgroundVideoLoadedPath == bg.filePath &&
            (backgroundVideoDecoder != null || backgroundVideoDecodeFailed)
        ) {
            return
        }
        releaseBackgroundVideoState(handle)
        backgroundVideoLoadedPath = bg.filePath

        val path = bg.filePath
        if (path == null) {
            backgroundVideoDecodeFailed = true
            Log.w(TAG, "ANDROID_GREENSCREEN_GPU_RESIDENT_BACKGROUND_VIDEO_FALLBACK reason=missing_path path=")
            return
        }

        val texId = try {
            bridge.nativeGetBackgroundVideoTextureId(handle)
        } catch (t: Throwable) {
            0
        }
        if (texId == 0) {
            backgroundVideoDecodeFailed = true
            Log.w(
                TAG,
                "ANDROID_GREENSCREEN_GPU_RESIDENT_BACKGROUND_VIDEO_FALLBACK reason=native_texture_failed " +
                    "path=$path ${bridge.nativeLastError(handle)}",
            )
            return
        }

        val texture = try {
            SurfaceTexture(texId).apply {
                setOnFrameAvailableListener { backgroundVideoFramePending.set(true) }
            }
        } catch (t: Throwable) {
            // texId was already allocated natively; a stranded native
            // texture must not survive this failed attempt.
            try { bridge.nativeClearBackgroundVideo(handle) } catch (_: Throwable) {}
            backgroundVideoDecodeFailed = true
            Log.w(
                TAG,
                "ANDROID_GREENSCREEN_GPU_RESIDENT_BACKGROUND_VIDEO_FALLBACK reason=surface_texture_failed " +
                    "path=$path error=${t.message}",
            )
            return
        }
        val surface = try {
            Surface(texture)
        } catch (t: Throwable) {
            try { texture.release() } catch (_: Throwable) {}
            // Same as above: texId was already allocated natively.
            try { bridge.nativeClearBackgroundVideo(handle) } catch (_: Throwable) {}
            backgroundVideoDecodeFailed = true
            Log.w(
                TAG,
                "ANDROID_GREENSCREEN_GPU_RESIDENT_BACKGROUND_VIDEO_FALLBACK reason=surface_failed " +
                    "path=$path error=${t.message}",
            )
            return
        }
        backgroundVideoSurfaceTexture = texture
        backgroundVideoSurface = surface

        backgroundVideoDecoder = AndroidGreenScreenVideoBackgroundDecoder(
            filePath = path,
            outputSurface = surface,
            outputSurfaceTexture = texture,
            onFormatKnown = { w, h, rotation ->
                backgroundVideoWidthPx = w
                backgroundVideoHeightPx = h
                backgroundVideoRotationDegrees = rotation
            },
            onFatalError = { message ->
                Log.w(TAG, "ANDROID_GREENSCREEN_GPU_RESIDENT_BACKGROUND_VIDEO_DECODE_FAILED path=$path error=$message")
            },
        ).also { it.start() }
    }

    /**
     * Releases the current background video decoder/native texture
     * (idempotent, non-blocking). Drops the SurfaceTexture/Surface
     * references immediately but does not release those two objects itself —
     * the decoder ([AndroidGreenScreenVideoBackgroundDecoder.release]) owns
     * and releases them asynchronously, on its own thread, once its codec
     * has guaranteed no further writes; deleting the native GL texture name
     * here does not require that to have already happened (see
     * AndroidGreenScreenVideoBackgroundDecoder's class doc). This is what
     * keeps a mid-session background switch from ever blocking render loop
     * pacing.
     */
    private fun releaseBackgroundVideoState(handle: Long) {
        backgroundVideoFramePending.set(false)
        try { backgroundVideoDecoder?.release() } catch (_: Throwable) {}
        backgroundVideoDecoder = null
        try { backgroundVideoSurfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
        backgroundVideoSurface = null
        backgroundVideoSurfaceTexture = null
        if (backgroundVideoLoadedPath != null) {
            try { bridge.nativeClearBackgroundVideo(handle) } catch (_: Throwable) {}
        }
        backgroundVideoLoadedPath = null
        backgroundVideoDecodeFailed = false
        backgroundVideoWidthPx = 0
        backgroundVideoHeightPx = 0
        backgroundVideoRotationDegrees = 0
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
     * Releases everything this backend owns, in order: the recorder EGL
     * wrapper (never the recorder-owned Surface), interpreter + delegate
     * (with the native context current), camera Surface + SurfaceTexture,
     * then the native renderer (window surface, GL objects, context,
     * display). Never touches the borrowed output Surface. Idempotent.
     */
    private fun teardownCoreQuietly() {
        val handle = nativeHandle
        if (handle != 0L) {
            try { bridge.nativeMakeCurrent(handle) } catch (_: Throwable) {}
        }
        // nativeDestroy below would destroy the recorder surface too, but the
        // target must be forgotten before the handle goes away.
        detachRecorderQuietly()
        model?.closeQuietly()
        model = null

        try { cameraSurfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
        try { _cameraInputSurface?.release() } catch (_: Throwable) {}
        _cameraInputSurface = null
        try { cameraSurfaceTexture?.release() } catch (_: Throwable) {}
        cameraSurfaceTexture = null

        // Background video: stop the decoder and drop the SurfaceTexture/
        // Surface references (the decoder releases those two asynchronously,
        // on its own thread). The native OES texture is torn down for free
        // below by nativeDestroy's own DestroyGlObjects, so no explicit
        // nativeClearBackgroundVideo call is needed here.
        try { backgroundVideoDecoder?.release() } catch (_: Throwable) {}
        backgroundVideoDecoder = null
        try { backgroundVideoSurfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
        backgroundVideoSurface = null
        backgroundVideoSurfaceTexture = null

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
        backgroundVideoLoadedPath = null
        backgroundVideoDecodeFailed = false
        backgroundVideoWidthPx = 0
        backgroundVideoHeightPx = 0
        backgroundVideoRotationDegrees = 0
        backgroundDirty = true
    }
}
