package com.connects.vanguard_media_engine.duet

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenGpuResidentNativeBridge
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.CompatibilityList
import org.tensorflow.lite.gpu.GpuDelegate
import org.tensorflow.lite.gpu.GpuDelegateFactory
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

// -----------------------------------------------------------------------------
// VG-DUET-SLICE-4B-B: GLES compositor for the Duet preview texture (Android
// sibling of VGDuetPreviewCompositor.swift).
// -----------------------------------------------------------------------------
//
// Owns the EGL display/context and the decoder-facing SurfaceTexture ingest:
//   - An OES texture + SurfaceTexture + [decoderInputSurface] the source video
//     decoder renders into (handed to AndroidDuetSourceVideoDecoder via
//     rebindOutputSurface by the render loop, never created by the decoder).
//   - A borrowed output Surface (Flutter SurfaceProducer surface acquired via
//     AndroidDuetPreviewSurfaceProducer.acquireSurface()) wrapped in an EGL
//     window surface. The output Surface is NEVER released here; only the EGL
//     window surface wrapping it is destroyed on [detachOutputSurface].
//
// Lifetime split (the core reason this class exists as its own seam):
//   - Output loss (Flutter onSurfaceCleanup) destroys ONLY the EGL window
//     surface. The EGL context, OES texture, SurfaceTexture and
//     [decoderInputSurface] all survive, so the decoder stays bound and a
//     later re-attach resumes without rebuilding the codec.
//   - [release] is terminal: it tears down the SurfaceTexture ingest, the GL
//     objects and the whole EGL stack. Idempotent, never throws.
//
// A 1x1 pbuffer surface keeps the context current on the render thread while
// no output is attached, so texture setup/teardown and updateTexImage never
// depend on the (transient) window surface.
//
// Threading: render-thread-only. Every method (and property read) must run on
// the single render thread owned by AndroidDuetPreviewRenderLoop. The only
// cross-thread touch points are the SurfaceTexture frame-available callback
// (which may fire on any looper and therefore only sets [framePending]) and
// the decoder writing into [decoderInputSurface] on the decoder thread.
//
// ANDROID-DUET-GPU-GREENSCREEN-SEGMENTER: greenScreen mode no longer depends
// on a CameraX ImageAnalysis mask stream by default. When the foreground
// provider installs an [AndroidDuetGpuGreenScreenSegmenterBinding.Config]
// before enabling keying, this compositor runs the committed GPU-resident
// segmentation core (GlesGreenScreenGpuSegmenter, reached through
// AndroidGreenScreenGpuResidentNativeBridge.nativeSegmenter*) INSIDE its own
// render pass, on this render thread, in this EGL context (upgraded to ES 3.1
// when the device supports it), sampling the already-latched
// [cameraOesTextureId] through [cameraStMatrix]:
//   latch camera frame N -> native downscale -> Interpreter.run (GpuDelegate)
//   -> native coarse mask upload -> native guided-filter refine
//   -> (existing) source-video / static background draw
//   -> (existing) axis-aligned / free-rotated camera quad, keyed by the
//      refined R32F alpha texture instead of a CPU-uploaded LUMINANCE mask.
// Nothing about the source-video decoder ingest, PiP/split drawing, output
// surface lifecycle or the free-transform geometry changes. Without an
// installed config (explicit debug opt-in only) the legacy CPU-mask path
// through [updateGreenScreenMask] keeps working unchanged.
//
// Fail-closed policy: if the context is not ES 3.1, the native segmenter or
// the TFLite session cannot be created, or inference fails repeatedly, the
// camera layer is simply not drawn (source video stays visible, exactly the
// pre-existing "no mask => background only" invariant) and the installed
// listener is told once so the provider can drive the existing PiP fallback.

/**
 * Process-wide hand-off between the main-thread foreground provider (which
 * owns the application Context, the model asset policy and the
 * coordinator-facing readiness / fallback callbacks) and the render-thread
 * [AndroidDuetPreviewCompositor] (which owns the GPU segmenter, the TFLite
 * session and the frame transaction). The compositor is constructed by
 * [AndroidDuetPreviewBackendFactory] without a Context and is only reachable
 * through the [AndroidDuetPreviewBackend] contract, so the provider publishes
 * its configuration here BEFORE it asks the sink to enable keying; the
 * compositor latches the current [config] on the render thread inside
 * [AndroidDuetPreviewCompositor.setGreenScreenEnabled] (`true`). Only the
 * application Context is ever stored (never an Activity). A `null` config at
 * enable time selects the legacy CPU-mask path.
 *
 * Listener calls are made on the compositor's render thread; implementations
 * must hop to their own thread and must tolerate late calls after they have
 * been uninstalled.
 */
object AndroidDuetGpuGreenScreenSegmenterBinding {

    /** RND-proven single-channel selfie segmenter (float32 NHWC [1,256,256,3] -> [1,256,256,1]). */
    const val DEFAULT_MODEL_ASSET = "selfie_segmenter_gpu.tflite"

    interface Listener {
        /** Native segmenter + TFLite session are live; [delegateLabel] is "gpu:*" or "cpu_xnnpack". */
        fun onSegmenterReady(delegateLabel: String)

        /** First refined alpha of the current enable is available to the draw. */
        fun onFirstMask()

        /** Terminal for the current enable: no alpha will be produced; [reason] is a stable token. */
        fun onSegmenterUnavailable(reason: String)
    }

    class Config(
        context: Context,
        val modelAssetPath: String,
        val listener: Listener,
    ) {
        /** Always the application Context (never an Activity), so holding it process-wide leaks nothing. */
        val applicationContext: Context = context.applicationContext ?: context
    }

    @Volatile
    var config: Config? = null
}

class AndroidDuetPreviewCompositor : AndroidDuetPreviewBackend {

    companion object {
        private const val TAG = "DuetPreviewComp"

        // Deterministic placeholder fill for the camera rect (no camera wired
        // in this slice): a fixed dark slate, identical every frame.
        private const val CAMERA_PLACEHOLDER_R = 0.13f
        private const val CAMERA_PLACEHOLDER_G = 0.14f
        private const val CAMERA_PLACEHOLDER_B = 0.17f

        // Deterministic landscape preview buffer size for the camera SurfaceTexture,
        // matching the 16:9 SurfaceRequest resolution CameraX's Preview use-case
        // actually negotiates on-device (observed 1920x1080). The SurfaceTexture
        // needs a non-zero default buffer size up front so it can export a valid
        // EGLImage from the first onFrameAvailable call; without this the first
        // updateTexImage may silently produce a zero-size image. This is a
        // preview-ingress default only; no recording/export claim.
        private const val CAMERA_ST_DEFAULT_WIDTH  = 1920
        private const val CAMERA_ST_DEFAULT_HEIGHT = 1080

        // Aspect ratio (width/height) of the camera image once [cameraStMatrix]
        // has rotated the landscape sensor buffer upright for a portrait front
        // camera: the width/height dimensions swap, so the upright aspect is
        // height-over-width of the raw buffer above (1080/1920 == 9:16). Used by
        // [cameraAspectFillViewport] instead of [aspectFillViewport]'s
        // decoder-video aspect, since the camera has no analogous
        // sourceVideoWidthPx/HeightPx of its own.
        private const val CAMERA_UPRIGHT_ASPECT =
            CAMERA_ST_DEFAULT_HEIGHT.toDouble() / CAMERA_ST_DEFAULT_WIDTH.toDouble()

        // Below this magnitude, [setForegroundRotation]'s angle is treated as
        // identity so the unrotated fast path (existing viewport/scissor crop,
        // unchanged pixel output) is used instead of the rotated-quad path.
        private const val ROTATION_EPSILON_DEGREES = 1e-4

        // -- GPU green-screen segmenter policy (same RND defaults as
        //    AndroidGreenScreenGpuResidentPreviewBackend) ------------------------

        /** RND defaults (gl_renderer.h): guided filter on, temporal off, despill on. */
        private const val GPU_GUIDED_FILTER_ENABLED = true
        private const val GPU_TEMPORAL_STABILIZER_ENABLED = false
        private const val GPU_DESPILL_ENABLED = true

        /** After this many consecutive segmentation failures the GPU path stops for this enable. */
        private const val GPU_MAX_CONSECUTIVE_INFERENCE_FAILURES = 3

        private const val GPU_CPU_FALLBACK_THREADS = 4

        /** Normalizes any integer degrees to a cardinal 0/90/180/270 value; anything else maps to 0. */
        private fun normalizeRotationDegrees(degrees: Int): Int {
            return when (((degrees % 360) + 360) % 360) {
                0 -> 0
                90 -> 90
                180 -> 180
                270 -> 270
                else -> 0
            }
        }
    }

    // -- EGL core (created lazily on first attach, destroyed only in release) --

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglConfig: EGLConfig? = null

    /** Keeps [eglContext] current while no output window surface exists. */
    private var eglPbufferSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    /** Wraps the borrowed output Surface; destroyed on every output loss. */
    private var eglWindowSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    private var coreReady = false

    /**
     * OpenGL ES version the bootstrapped context actually reports (parsed
     * from GL_VERSION). [ensureCore] asks for ES 3.1 first (needed by the GPU
     * segmenter's compute passes), then plain ES 3, then the historical ES 2
     * request; every existing ES 2 shader/draw in this file runs unchanged on
     * any of them. [computeCapable] is true only for 3.1+.
     */
    private var glesMajor = 0
    private var glesMinor = 0
    private var computeCapable = false

    // -- Decoder ingest (survives output loss, dies only in release) ----------

    private var oesTextureId = 0
    private var surfaceTexture: SurfaceTexture? = null

    @Volatile
    private var _decoderInputSurface: Surface? = null

    /**
     * Surface the source video decoder renders into (backed by this
     * compositor's SurfaceTexture). Owned by this compositor: stays alive
     * across output loss and is released exactly once in [release]. Null until
     * the first successful [attachOutputSurface].
     */
    override val decoderInputSurface: Surface? get() = _decoderInputSurface

    /** Set by the frame-available callback (any thread), consumed in [drawFrame]. */
    private val framePending = AtomicBoolean(false)

    /**
     * True when the decoder has queued at least one frame that [drawFrame] has
     * not yet consumed via updateTexImage. Lets the render loop wait (without
     * blocking) for an expected frame before presenting.
     */
    override val hasPendingSourceFrame: Boolean get() = framePending.get()

    /** True once updateTexImage has latched at least one real source frame. */
    private var hasTexImage = false

    private val stMatrix = FloatArray(16).also { Matrix.setIdentityM(it, 0) }

    // -- Camera ingest (independent of decoder; survives output loss, released only in release) --

    private var cameraOesTextureId = 0
    private var cameraSurfaceTexture: SurfaceTexture? = null

    @Volatile
    private var _cameraInputSurface: Surface? = null

    /**
     * Surface the camera (AndroidDuetCameraSource) renders into. Owned by
     * this compositor: allocated on first [attachOutputSurface], released once
     * in [release]. Null until the first successful [attachOutputSurface].
     */
    override val cameraInputSurface: Surface? get() = _cameraInputSurface

    /** Set by the camera frame-available callback (any thread), consumed in [drawFrame]. */
    private val cameraFramePending = AtomicBoolean(false)

    /** True when [drawFrame] has latched at least one real camera frame. */
    private var hasCameraTexImage = false

    /** True when a new camera frame is waiting to be consumed. */
    override val hasPendingCameraFrame: Boolean get() = cameraFramePending.get()

    private val cameraStMatrix = FloatArray(16).also { Matrix.setIdentityM(it, 0) }

    // -- Live take recorder target (ANDROID-DUET-SLICE-1A; render-thread only) --

    /**
     * Attached encoder target ([setSegmentRecorderTarget]) and the EGL window
     * surface wrapping its MediaCodec input Surface. The window surface is
     * created against this compositor's own [eglConfig]/[eglContext] so the
     * already-latched [cameraOesTextureId] (and, in green-screen mode, the
     * whole composited scene: background + keyed camera) can be drawn into it
     * directly (zero copy). Independent of the preview output surface: it
     * survives output loss and is destroyed by [setSegmentRecorderTarget]
     * (null) or [release].
     */
    private var recorderTarget: AndroidDuetSegmentRecorderSurfaceTarget? = null
    private var eglRecorderSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var recorderFramesSubmitted = 0L
    private var recorderFramesSkipped = 0L
    private var recorderSwapFailureLogged = false


    // -- Output / layout state -------------------------------------------------

    private var outputSurface: Surface? = null
    private var outputWidthPx = 0
    private var outputHeightPx = 0

    private var sourceRect: VGDuetPixelRect? = null
    private var cameraRect: VGDuetPixelRect? = null
    private var sourceScaleMode: AndroidDuetLayerScaleMode = AndroidDuetLayerScaleMode.ASPECT_FILL
    private var cameraScaleMode: AndroidDuetLayerScaleMode = AndroidDuetLayerScaleMode.ASPECT_FILL

    /** Raw decoded source video dimensions used for aspect-fill; 0 means unknown (stretch). */
    private var sourceVideoWidthPx = 0
    private var sourceVideoHeightPx = 0

    /**
     * Source video's normalized (0/90/180/270) display rotation, as reported
     * by the decoder. [aspectFillViewport] swaps [sourceVideoWidthPx]/
     * [sourceVideoHeightPx] for 90/270 so the background aspect matches the
     * upright display orientation instead of the raw decoded buffer's shape.
     */
    private var sourceVideoRotationDegrees = 0

    private val isReleased = AtomicBoolean(false)

    // -- GL program state ------------------------------------------------------

    private var oesProgram = 0
    private var aPositionLoc = -1
    private var aTexCoordLoc = -1
    private var uSTMatrixLoc = -1
    private var sTextureLoc = -1

    // -- Green-screen GL state -------------------------------------------------

    /** True when the session is in green-screen layout mode. Render-thread only. */
    private var greenScreenEnabled = false

    /**
     * Pending mask data to upload on the next drawFrame. Delivered from the ML
     * Kit callback (off render thread) via [updateGreenScreenMask]; consumed on
     * the render thread inside drawFrame. Wrapped in AtomicReference so the
     * setter (any thread) and getter (render thread) don't race.
     */
    private val pendingMaskRef = java.util.concurrent.atomic.AtomicReference<AndroidDuetSegmentationFrame?>(null)

    /** GL texture ID for the single-channel mask (LUMINANCE). 0 = not yet allocated. */
    private var maskTextureId = 0

    /**
     * Duet-only preview foreground free-rotation metadata: [setForegroundRotation]'s
     * visual-clockwise angle (Dart/top-left space) and normalized pivot anchor
     * within the camera rect. Render-thread only. Identity default (0.0, 0.5,
     * 0.5) applies no rotation, so callers that never invoke [setForegroundRotation]
     * see unchanged behavior.
     */
    private var foregroundRotationDegrees = 0.0
    private var foregroundAnchorX = 0.5
    private var foregroundAnchorY = 0.5

    /** GLES program: OES camera + 2D mask → alpha-blended draw. 0 = not yet compiled. */
    private var greenScreenProgram = 0
    private var gsAPositionLoc = -1
    private var gsATexCoordLoc = -1
    private var gsUSTMatrixLoc = -1
    private var gsSCameraLoc = -1
    private var gsUMaskLoc = -1
    private var gsUDebugViewLoc = -1
    private var gsUMaskTexelSizeLoc = -1

    /**
     * Debug-only (RND diagnostic): raw mask visualization mode. Render-thread
     * only, mutated exclusively via [setGreenScreenDebugView]. Null (the
     * default) means normal production compositing; any value other than
     * "mask_direct"/"mask_mapped"/"mask_direct_mirror_x"/"mask_direct_flip_y"/
     * "camera_passthrough" is treated as null by the setter.
     */
    private var greenScreenDebugView: String? = null

    /** Whether [maskTextureId] has been uploaded with at least one real mask. */
    private var hasMaskTexture = false

    /** Whether the first mask texture upload diagnostic log has fired. Render-thread only. */
    private var hasLoggedFirstMaskUpload = false

    /** Backend id of the most recently uploaded mask (diagnostic only). Render-thread only. */
    private var lastUploadedMaskBackend: String? = null

    /**
     * Dimensions of the most recently uploaded mask texture, used to derive the
     * `uMaskTexelSize` uniform for GPU-side matte erosion. 0 = unknown (draw
     * falls back to a (1,1) texel size so neighbour taps clamp to the edge and
     * refinement degrades to a plain sample rather than crashing). Render-thread only.
     */
    private var latestMaskWidth = 0
    private var latestMaskHeight = 0

    // -- GPU green-screen segmenter state (render-thread only) ----------------

    /** Interpreter + delegate + direct tensor buffers, created on the render thread. */
    private class GpuModelSession(
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

    private val gpuBridge = AndroidGreenScreenGpuResidentNativeBridge

    /**
     * Provider-installed configuration latched by [setGreenScreenEnabled]
     * (`true`) from [AndroidDuetGpuGreenScreenSegmenterBinding.config]. Non-null
     * means "this enable uses the GPU segmenter"; null means the legacy
     * CPU-mask path ([updateGreenScreenMask] -> [maskTextureId]).
     */
    private var gpuConfig: AndroidDuetGpuGreenScreenSegmenterBinding.Config? = null

    /** Native GlesGreenScreenGpuSegmenter handle living in THIS EGL context. 0 = not created. */
    private var gpuSegmenterHandle = 0L
    private var gpuModel: GpuModelSession? = null
    private var gpuSegmenterReady = false

    /** Latched for the compositor's lifetime once bootstrap fails (no per-frame retry storm). */
    private var gpuSegmenterFailed = false
    private var gpuSegmenterFailureReason: String? = null

    /** Per-enable one-shot latches for the listener notifications. */
    private var gpuUnavailableNotified = false
    private var gpuFirstMaskSignaled = false

    /** True once the current enable has a refined alpha texture the draw may use. */
    private var gpuHasRefinedAlpha = false
    private var gpuAlphaTextureId = 0
    private var gpuAlphaWidth = 0
    private var gpuAlphaHeight = 0

    private var gpuInferenceDisabled = false
    private var gpuConsecutiveInferenceFailures = 0

    /** GLES 3.00 program: OES camera keyed by the refined R32F alpha (port of the GPU-resident composite). */
    private var gpuMaskedProgram = 0
    private var gpuAPositionLoc = -1
    private var gpuATexCoordLoc = -1
    private var gpuUSTMatrixLoc = -1
    private var gpuSCameraLoc = -1
    private var gpuUAlphaLoc = -1
    private var gpuUAlphaResolutionLoc = -1
    private var gpuUDespillLoc = -1
    private var gpuUDebugViewLoc = -1
    private var gpuMaskedProgramFailed = false

    // GPU segmenter telemetry (render-thread only).
    private var gpuFrameCount = 0L
    private var gpuInferenceCount = 0L
    private var gpuInferenceFailureCount = 0L
    private var gpuTotalInferenceNs = 0L
    private var gpuMaxInferenceNs = 0L
    private var gpuFirstInferenceLogged = false
    private var gpuSessionStartMs = 0L
    private var loggedMaskPath = false

    // -- Green-screen static background GL state -------------------------------

    /** Current background spec. Render-thread only; default preserves prior behavior. */
    private var greenScreenBackground: AndroidDuetGreenScreenBackground = AndroidDuetGreenScreenBackground.VIDEO

    /** GL texture id for a decoded [AndroidDuetGreenScreenBackgroundType.IMAGE] background. 0 = none loaded. */
    private var backgroundImageTextureId = 0
    private var backgroundImageWidthPx = 0
    private var backgroundImageHeightPx = 0

    /** File path the currently-loaded [backgroundImageTextureId] was decoded from, if any. */
    private var backgroundImageLoadedPath: String? = null

    /** True once decode/texture upload has failed for [backgroundImageLoadedPath]; stops retrying every frame. */
    private var backgroundImageDecodeFailed = false

    /** GLES program: plain 2D texture sampler used to draw a static image background. 0 = not yet compiled. */
    private var backgroundImageProgram = 0
    private var bgImageAPositionLoc = -1
    private var bgImageATexCoordLoc = -1
    private var bgImageSTextureLoc = -1

    private val quadPositions: FloatBuffer = floatBufferOf(
        -1f, -1f,
         1f, -1f,
        -1f,  1f,
         1f,  1f,
    )
    private val quadTexCoords: FloatBuffer = floatBufferOf(
        0f, 0f,
        1f, 0f,
        0f, 1f,
        1f, 1f,
    )

    /**
     * Scratch vertex-position buffer for the non-zero-rotation green-screen
     * camera draw ([drawCameraGreenScreenRotated]), reused every frame instead
     * of allocating. Holds 4 NDC (x, y) corners in the same order as
     * [quadPositions]; texture coordinates are unaffected by rotation and
     * continue to use [quadTexCoords].
     */
    private val rotatedQuadPositions: FloatBuffer = floatBufferOf(0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f)

    // -- Attach / detach -------------------------------------------------------

    /**
     * Wraps the borrowed [surface] in an EGL window surface and makes it
     * current. First call also bootstraps the EGL core and the decoder ingest
     * (OES texture / SurfaceTexture / [decoderInputSurface]).
     *
     * [surface] is borrowed (SurfaceProducer-owned): it is never released
     * here, under any path. Re-attaching while already attached destroys the
     * previous window surface first. Returns false (leaving no window surface
     * bound) when released, [surface] is invalid, or any EGL step fails.
     */
    override fun attachOutputSurface(surface: Surface, widthPx: Int, heightPx: Int): Boolean {
        if (isReleased.get()) return false
        if (!surface.isValid || widthPx <= 0 || heightPx <= 0) {
            Log.w(TAG, "attachOutputSurface rejected: valid=${surface.isValid} ${widthPx}x$heightPx")
            return false
        }
        if (!ensureCore()) return false

        // Re-attach: drop the previous window surface only.
        destroyWindowSurfaceQuietly()

        try {
            val window = EGL14.eglCreateWindowSurface(
                eglDisplay, eglConfig, surface, intArrayOf(EGL14.EGL_NONE), 0,
            )
            if (window == null || window == EGL14.EGL_NO_SURFACE) {
                Log.w(TAG, "eglCreateWindowSurface failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
                makeCurrentQuietly(eglPbufferSurface)
                return false
            }
            if (!EGL14.eglMakeCurrent(eglDisplay, window, window, eglContext)) {
                Log.w(TAG, "eglMakeCurrent(window) failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
                try { EGL14.eglDestroySurface(eglDisplay, window) } catch (_: Throwable) {}
                makeCurrentQuietly(eglPbufferSurface)
                return false
            }
            eglWindowSurface = window
            outputSurface = surface
            outputWidthPx = widthPx
            outputHeightPx = heightPx
            // The refined alpha resolution derives from the output size; keep
            // the (possibly already created) segmenter in step on re-attach.
            if (gpuSegmenterHandle != 0L) {
                try { gpuBridge.nativeSegmenterSetAlphaTargetSize(gpuSegmenterHandle, widthPx, heightPx) } catch (_: Throwable) {}
            }
            return true
        } catch (t: Throwable) {
            Log.w(TAG, "attachOutputSurface threw: ${t.message}")
            makeCurrentQuietly(eglPbufferSurface)
            return false
        }
    }

    /**
     * Output loss: destroys ONLY the EGL window surface and drops the borrowed
     * output Surface reference (never releasing it). The EGL context, OES
     * texture, SurfaceTexture and [decoderInputSurface] all stay alive so the
     * decoder remains bound for a later re-attach. Tolerates every EGL
     * teardown error; never throws. Idempotent.
     */
    override fun detachOutputSurface() {
        destroyWindowSurfaceQuietly()
        outputSurface = null
        outputWidthPx = 0
        outputHeightPx = 0
    }

    // -- Layout / video size ---------------------------------------------------

    /** Canvas-pixel rects (top-left origin) for the source video and camera placeholder. */
    override fun setLayout(sourceRect: VGDuetPixelRect, cameraRect: VGDuetPixelRect) {
        this.sourceRect = sourceRect
        this.cameraRect = cameraRect
    }

    override fun setLayerScaleModes(
        sourceScaleMode: AndroidDuetLayerScaleMode,
        cameraScaleMode: AndroidDuetLayerScaleMode,
    ) {
        this.sourceScaleMode = sourceScaleMode
        this.cameraScaleMode = cameraScaleMode
    }

    /**
     * Source video dimensions used for aspect-fill inside the source rect.
     * Read off the decoder (on the decoder thread) by the render loop and
     * forwarded here. Unknown (<= 0) falls back to a plain stretch fill.
     * Resets the stored rotation to 0 (identity); callers that also know the
     * source's display rotation should use [setSourceVideoMetadata] instead.
     */
    override fun setSourceVideoSize(widthPx: Int, heightPx: Int) {
        applySourceVideoMetadata(widthPx, heightPx, rotationDegrees = 0)
    }

    /**
     * Backwards-safe superset of [setSourceVideoSize]: also carries the source
     * video's display rotation, normalized to 0/90/180/270 (any other value
     * degrades to 0), so [aspectFillViewport] can swap width/height for a
     * 90/270 source instead of aspect-filling with the raw decoded buffer's
     * (sideways) shape.
     */
    override fun setSourceVideoMetadata(widthPx: Int, heightPx: Int, rotationDegrees: Int) {
        applySourceVideoMetadata(widthPx, heightPx, rotationDegrees)
    }

    private fun applySourceVideoMetadata(widthPx: Int, heightPx: Int, rotationDegrees: Int) {
        sourceVideoWidthPx = widthPx
        sourceVideoHeightPx = heightPx
        sourceVideoRotationDegrees = normalizeRotationDegrees(rotationDegrees)
    }

    // -- Green-screen controls (render-thread only for enabled; AtomicRef for mask) --

    /**
     * Enable or disable green-screen compositing. Must be called on the render thread.
     * When disabled, the camera rect reverts to normal PiP/split drawing behaviour.
     *
     * Enabling latches the provider-installed
     * [AndroidDuetGpuGreenScreenSegmenterBinding.config] for this enable: a
     * non-null config selects the GPU segmenter path (bootstrapped lazily on
     * the next [drawFrame]); null keeps the legacy CPU-mask path. Disabling
     * forgets every mask (legacy texture flag and GPU refined alpha / temporal
     * history) so a later re-enable never composites a stale matte, but keeps
     * the segmenter, model session and GL objects alive for a cheap re-enable.
     */
    override fun setGreenScreenEnabled(enabled: Boolean) {
        if (greenScreenEnabled == enabled) return
        greenScreenEnabled = enabled
        if (!enabled) {
            // Clear pending mask so stale data is not shown if re-enabled later.
            pendingMaskRef.set(null)
            hasMaskTexture = false
            hasLoggedFirstMaskUpload = false
            lastUploadedMaskBackend = null
            latestMaskWidth = 0
            latestMaskHeight = 0
            // GPU path: forget the matte for this enable; resources survive.
            gpuHasRefinedAlpha = false
            gpuAlphaTextureId = 0
            if (gpuSegmenterHandle != 0L) {
                try { gpuBridge.nativeSegmenterResetMaskState(gpuSegmenterHandle) } catch (_: Throwable) {}
            }
            gpuConfig = null
            return
        }
        gpuConfig = AndroidDuetGpuGreenScreenSegmenterBinding.config
        gpuUnavailableNotified = false
        gpuFirstMaskSignaled = false
        gpuHasRefinedAlpha = false
        gpuAlphaTextureId = 0
        // A fresh enable gets a fresh failure budget; a bootstrap failure
        // ([gpuSegmenterFailed]) stays latched because it cannot recover.
        gpuInferenceDisabled = false
        gpuConsecutiveInferenceFailures = 0
        loggedMaskPath = false
    }

    /**
     * Delivers a new segmentation mask to be uploaded on the next [drawFrame].
     * Safe to call from any thread (backed by AtomicReference — latest wins,
     * stale frames are dropped). ML Kit callback thread → render thread.
     */
    override fun updateGreenScreenMask(frame: AndroidDuetSegmentationFrame) {
        pendingMaskRef.set(frame)
    }

    /**
     * Debug-only (RND diagnostic): allowlists [view] to exactly "mask_direct",
     * "mask_mapped", "mask_direct_mirror_x", "mask_direct_flip_y" or
     * "camera_passthrough"; any other value (including null) disables the
     * visualization and restores normal production compositing.
     * "mask_direct_mirror_x" and "mask_direct_flip_y" let physical RND
     * identify front-camera mirror/flip mismatches by sampling the raw mask
     * with the X or Y raw texture coordinate inverted, respectively.
     * "camera_passthrough" shows the raw live camera feed (no mask, no
     * smoothstep) inside the green-screen camera rect, so physical RND can
     * confirm the OES camera path itself independent of segmentation. Must be
     * called on the render thread.
     */
    override fun setGreenScreenDebugView(view: String?) {
        greenScreenDebugView = when (view) {
            "mask_direct", "mask_mapped", "mask_direct_mirror_x", "mask_direct_flip_y",
            "camera_passthrough" -> view
            else -> null
        }
    }

    /**
     * Stores the new background spec; render-thread only (posted here by the
     * render loop). The actual image decode/texture (re)load is deferred to
     * [ensureBackgroundImageTexture] inside [drawFrame], mirroring how
     * [updateGreenScreenMask] defers its GL upload to [uploadMaskTexture] —
     * both need the EGL context current, which is only guaranteed there.
     */
    override fun setGreenScreenBackground(background: AndroidDuetGreenScreenBackground) {
        greenScreenBackground = background
    }

    /**
     * Duet-only preview seam: stores the green-screen foreground/camera layer's
     * free-rotation angle and pivot anchor for the next [drawFrame]. Sanitizes
     * non-finite input to identity, matching the finiteness contract
     * [AndroidDuetLayoutGeometry.foregroundRotation] already enforces upstream.
     * Must be called on the render thread (mirrors [setLayout]).
     */
    override fun setForegroundRotation(rotationDegrees: Double, anchorX: Double, anchorY: Double) {
        foregroundRotationDegrees = if (rotationDegrees.isFinite()) rotationDegrees else 0.0
        foregroundAnchorX = (if (anchorX.isFinite()) anchorX else 0.5).coerceIn(0.0, 1.0)
        foregroundAnchorY = (if (anchorY.isFinite()) anchorY else 0.5).coerceIn(0.0, 1.0)
    }

    // -- Live take recorder surface (ANDROID-DUET-SLICE-1A) ---------------------

    /**
     * Attaches or detaches the live take recorder's encoder surface (see
     * [AndroidDuetPreviewBackend.setSegmentRecorderTarget]). Any previously
     * attached encoder surface is destroyed first, so this is idempotent and
     * a replace is a detach + attach. Attaching bootstraps the EGL core if the
     * preview has not attached yet (the camera ingest is allocated with it),
     * wraps the target's Surface in an EGL window surface on this compositor's
     * config/context, verifies it can be made current, then restores the
     * preview (window or pbuffer) as the current surface. Returns false, with
     * nothing attached, on any failure so the coordinator can fail the take
     * start cleanly. Must run on the render thread.
     */
    override fun setSegmentRecorderTarget(target: AndroidDuetSegmentRecorderSurfaceTarget?): Boolean {
        destroyRecorderSurfaceQuietly()
        if (target == null) return true
        if (isReleased.get()) return false
        if (!ensureCore()) return false
        val surface = target.inputSurface
        if (surface == null || !surface.isValid || target.widthPx <= 0 || target.heightPx <= 0) {
            Log.w(TAG, "ANDROID_DUET_SEGMENT_RECORDER_SURFACE_REJECTED valid=${surface?.isValid} " +
                "size=${target.widthPx}x${target.heightPx}")
            return false
        }
        try {
            val eglSurf = EGL14.eglCreateWindowSurface(
                eglDisplay, eglConfig, surface, intArrayOf(EGL14.EGL_NONE), 0,
            )
            if (eglSurf == null || eglSurf == EGL14.EGL_NO_SURFACE) {
                Log.w(TAG, "ANDROID_DUET_SEGMENT_RECORDER_SURFACE_FAILED stage=eglCreateWindowSurface " +
                    "error=0x${Integer.toHexString(EGL14.eglGetError())}")
                restorePreviewCurrentQuietly()
                return false
            }
            if (!EGL14.eglMakeCurrent(eglDisplay, eglSurf, eglSurf, eglContext)) {
                Log.w(TAG, "ANDROID_DUET_SEGMENT_RECORDER_SURFACE_FAILED stage=eglMakeCurrent " +
                    "error=0x${Integer.toHexString(EGL14.eglGetError())}")
                restorePreviewCurrentQuietly()
                try { EGL14.eglDestroySurface(eglDisplay, eglSurf) } catch (_: Throwable) {}
                return false
            }
            restorePreviewCurrentQuietly()
            eglRecorderSurface = eglSurf
            recorderTarget = target
            recorderFramesSubmitted = 0L
            recorderFramesSkipped = 0L
            recorderSwapFailureLogged = false
            Log.i(
                TAG,
                "ANDROID_DUET_SEGMENT_RECORDER_SURFACE_ATTACHED size=${target.widthPx}x${target.heightPx} " +
                    "cameraLatched=$hasCameraTexImage gles=$glesMajor.$glesMinor",
            )
            return true
        } catch (t: Throwable) {
            Log.w(TAG, "ANDROID_DUET_SEGMENT_RECORDER_SURFACE_FAILED stage=exception ${t.javaClass.simpleName}: ${t.message}")
            restorePreviewCurrentQuietly()
            return false
        }
    }

    /**
     * Draws the frame latched by the enclosing [drawFrame] into the attached
     * encoder surface, stamped with the target's presentation time, then
     * swapped. What is drawn depends on the layout mode:
     *   - PiP / Split (green screen off): the raw camera frame, full encoder
     *     frame, aspect-filled and oriented exactly as the preview draws it
     *     ([cameraStMatrix] + the shared [drawCameraOesQuad]); the offline
     *     export compositor places it into the layout later. Unchanged.
     *   - Green screen: the SAME final composited scene the preview just
     *     presented (background + keyed camera foreground, current layout)
     *     through [drawCompositedSceneIntoRecorderFrame], so the take is
     *     already the finished picture and the export only remuxes it.
     * Runs after the preview swap so preview latency is untouched, and
     * restores the preview surface as current (and every dimension/layout
     * field it borrowed) before returning. Every EGL/GL failure is logged
     * (first swap failure once) and never thrown. Frames the target declines
     * (negative PTS: recorder finishing/canceled) are skipped without touching
     * the encoder surface.
     */
    private fun encodeRecorderFrame() {
        val target = recorderTarget ?: return
        val eglSurf = eglRecorderSurface
        if (eglSurf == EGL14.EGL_NO_SURFACE || !hasCameraTexImage || cameraOesTextureId == 0) return
        val ptsNs = target.nextFramePresentationTimeNs()
        if (ptsNs < 0L) {
            recorderFramesSkipped++
            return
        }
        try {
            if (!EGL14.eglMakeCurrent(eglDisplay, eglSurf, eglSurf, eglContext)) {
                if (!recorderSwapFailureLogged) {
                    recorderSwapFailureLogged = true
                    Log.w(TAG, "ANDROID_DUET_SEGMENT_RECORDER_FRAME_FAILED stage=eglMakeCurrent " +
                        "error=0x${Integer.toHexString(EGL14.eglGetError())}")
                }
                return
            }
            val frameW = target.widthPx
            val frameH = target.heightPx
            val recorderMode: String
            val viewportLabel: String
            if (greenScreenEnabled) {
                // ANDROID-DUET-GREENSCREEN-LIVE-COMPOSITE: record the finished
                // picture (source/background + keyed camera), never the raw camera.
                recorderMode = "green_screen_composite"
                viewportLabel = "0,0,${frameW}x$frameH"
                drawCompositedSceneIntoRecorderFrame(frameW, frameH)
            } else {
                recorderMode = "raw_camera"
                GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
                GLES20.glDisable(GLES20.GL_BLEND)
                GLES20.glViewport(0, 0, frameW, frameH)
                GLES20.glClearColor(0f, 0f, 0f, 1f)
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
                val viewport = recorderCameraAspectFillViewport(frameW, frameH)
                viewportLabel = "${viewport.x},${viewport.y},${viewport.width}x${viewport.height}"
                GLES20.glViewport(viewport.x, viewport.y, viewport.width, viewport.height)
                drawCameraOesQuad()
            }
            EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurf, ptsNs)
            if (EGL14.eglSwapBuffers(eglDisplay, eglSurf)) {
                recorderFramesSubmitted++
                target.onFrameSubmitted(ptsNs)
                if (recorderFramesSubmitted == 1L) {
                    Log.i(TAG, "ANDROID_DUET_SEGMENT_RECORDER_FIRST_FRAME ptsNs=$ptsNs " +
                        "mode=$recorderMode viewport=$viewportLabel " +
                        "frame=${frameW}x$frameH preview=${outputWidthPx}x$outputHeightPx")
                }
            } else if (!recorderSwapFailureLogged) {
                recorderSwapFailureLogged = true
                Log.w(TAG, "ANDROID_DUET_SEGMENT_RECORDER_FRAME_FAILED stage=eglSwapBuffers " +
                    "error=0x${Integer.toHexString(EGL14.eglGetError())}")
            }
        } catch (t: Throwable) {
            if (!recorderSwapFailureLogged) {
                recorderSwapFailureLogged = true
                Log.w(TAG, "ANDROID_DUET_SEGMENT_RECORDER_FRAME_FAILED stage=exception ${t.javaClass.simpleName}: ${t.message}")
            }
        } finally {
            restorePreviewCurrentQuietly()
        }
    }

    /**
     * ANDROID-DUET-GREENSCREEN-LIVE-COMPOSITE: draws the identical composited
     * scene the preview just presented ([drawCompositedScene]) into the
     * encoder frame that is current. The scene geometry ([toGlRect],
     * [fullSurfaceRect], the aspect-fill viewports and the rotated keyed quad)
     * is derived from [outputWidthPx]/[outputHeightPx] and the canvas-pixel
     * layout rects, so for this pass only the output dimensions are pointed at
     * the encoder frame and [sourceRect]/[cameraRect] are scaled from the
     * preview canvas to it (identity for the default 1080x1920 canvas and take
     * size). Every borrowed field is restored before returning, whatever
     * happens; the caller restores the current EGL surface.
     */
    private fun drawCompositedSceneIntoRecorderFrame(frameW: Int, frameH: Int) {
        val savedWidthPx = outputWidthPx
        val savedHeightPx = outputHeightPx
        val savedSourceRect = sourceRect
        val savedCameraRect = cameraRect
        try {
            if (savedWidthPx > 0 && savedHeightPx > 0 && (savedWidthPx != frameW || savedHeightPx != frameH)) {
                val sx = frameW.toDouble() / savedWidthPx.toDouble()
                val sy = frameH.toDouble() / savedHeightPx.toDouble()
                sourceRect = savedSourceRect?.let { scaleRect(it, sx, sy) }
                cameraRect = savedCameraRect?.let { scaleRect(it, sx, sy) }
            }
            outputWidthPx = frameW
            outputHeightPx = frameH
            drawCompositedScene()
        } finally {
            outputWidthPx = savedWidthPx
            outputHeightPx = savedHeightPx
            sourceRect = savedSourceRect
            cameraRect = savedCameraRect
        }
    }

    private fun scaleRect(rect: VGDuetPixelRect, sx: Double, sy: Double): VGDuetPixelRect =
        VGDuetPixelRect(rect.left * sx, rect.top * sy, rect.width * sx, rect.height * sy)

    /**
     * Viewport for an aspect-fill of the upright camera image into the whole
     * encoder frame: the same centred-inflate math as
     * [cameraAspectFillCanvasRect], converted to a bottom-left-origin GL rect
     * using the encoder frame height (not [outputHeightPx], which belongs to
     * the preview surface). For the 9:16 default take size and the 9:16
     * upright camera aspect this is the identity full-frame viewport.
     */
    private fun recorderCameraAspectFillViewport(frameW: Int, frameH: Int): GlRect {
        val aspectRect = cameraAspectFillCanvasRect(
            VGDuetPixelRect(0.0, 0.0, frameW.toDouble(), frameH.toDouble()),
        )
        val w = aspectRect.width.roundToInt()
        val h = aspectRect.height.roundToInt()
        return GlRect(
            x = aspectRect.left.roundToInt(),
            y = frameH - (aspectRect.top.roundToInt() + h),
            width = w,
            height = h,
        )
    }

    /** Makes the preview window surface current again when attached, else the bootstrap pbuffer. */
    private fun restorePreviewCurrentQuietly() {
        val window = eglWindowSurface
        makeCurrentQuietly(if (window != EGL14.EGL_NO_SURFACE) window else eglPbufferSurface)
    }

    /**
     * Destroys only the encoder EGL window surface (never the recorder-owned
     * Surface behind it) after switching the preview/pbuffer back to current,
     * and forgets the target. Idempotent; tolerates a recorder Surface that is
     * already dead (recorder canceled first).
     */
    private fun destroyRecorderSurfaceQuietly() {
        val surf = eglRecorderSurface
        val target = recorderTarget
        eglRecorderSurface = EGL14.EGL_NO_SURFACE
        recorderTarget = null
        if (surf == EGL14.EGL_NO_SURFACE || eglDisplay == EGL14.EGL_NO_DISPLAY) return
        restorePreviewCurrentQuietly()
        try { EGL14.eglDestroySurface(eglDisplay, surf) } catch (_: Throwable) {}
        if (target != null) {
            Log.i(TAG, "ANDROID_DUET_SEGMENT_RECORDER_SURFACE_DETACHED " +
                "framesSubmitted=$recorderFramesSubmitted framesSkipped=$recorderFramesSkipped")
        }
    }


    /**
     * Composites one frame into the attached output surface:
     *   1. updateTexImage (only when the decoder / camera queued a new frame),
     *   2. green-screen mask production for the latched camera frame,
     *   3. [drawCompositedScene]: full clear to black, background (source
     *      video, or the green-screen background), camera layer (keyed
     *      camera, live OES frame or placeholder),
     *   4. eglSwapBuffers,
     *   5. the attached take recorder pass ([encodeRecorderFrame]).
     *
     * Returns true when a frame was actually presented (swap succeeded).
     * Returns false (without throwing) when released, no output is attached,
     * or EGL rejects the frame (e.g. surface torn down mid-draw).
     */
    override fun drawFrame(): Boolean {
        if (isReleased.get() || !coreReady) return false
        val display = eglDisplay
        val window = eglWindowSurface
        if (display == EGL14.EGL_NO_DISPLAY || window == EGL14.EGL_NO_SURFACE) return false
        if (outputWidthPx <= 0 || outputHeightPx <= 0) return false
        val texture = surfaceTexture ?: return false

        try {
            if (!EGL14.eglMakeCurrent(display, window, window, eglContext)) return false

            // Latch source decoder frame if one arrived since last draw.
            if (framePending.compareAndSet(true, false)) {
                texture.updateTexImage()
                texture.getTransformMatrix(stMatrix)
                hasTexImage = true
            }

            // Latch camera frame if one arrived since last draw.
            var latchedNewCameraFrame = false
            val camSt = cameraSurfaceTexture
            if (camSt != null && cameraFramePending.compareAndSet(true, false)) {
                camSt.updateTexImage()
                camSt.getTransformMatrix(cameraStMatrix)
                hasCameraTexImage = true
                latchedNewCameraFrame = true
            }

            // Green-screen mask production for this frame:
            //  - GPU segmenter path (provider-installed config): one same-frame
            //    transaction over exactly the camera frame latched above
            //    (downscale -> Interpreter.run -> coarse upload -> refine), all
            //    in this context on this thread, BEFORE any draw of the frame.
            //  - Legacy path (no config, explicit debug opt-in): upload the
            //    latest CPU mask delivered through updateGreenScreenMask.
            if (greenScreenEnabled) {
                if (gpuConfig != null) {
                    logMaskPathOnce("gpu_segmenter")
                    if (ensureGpuSegmenter()) {
                        gpuFrameCount++
                        if (latchedNewCameraFrame && !gpuInferenceDisabled) {
                            runGpuSegmentationOnLatchedFrame()
                        }
                    }
                } else {
                    logMaskPathOnce("image_analysis")
                    val maskFrame = pendingMaskRef.getAndSet(null)
                    if (maskFrame != null) {
                        uploadMaskTexture(maskFrame)
                    }
                }
            }

            drawCompositedScene()
            val presented = EGL14.eglSwapBuffers(display, window)

            // ANDROID-DUET-SLICE-1A: after the preview swap, feed the SAME
            // latched camera frame to the attached take recorder (once per
            // new camera frame, so the encoder never sees duplicates): raw
            // camera for PiP/Split, the identical composited scene in
            // green-screen mode. The preview output above is unchanged by
            // this; encodeRecorderFrame restores the preview surface as
            // current before returning.
            if (latchedNewCameraFrame && recorderTarget != null) {
                encodeRecorderFrame()
            }
            return presented
        } catch (t: Throwable) {
            Log.w(TAG, "drawFrame failed: ${t.message}")
            return false
        }
    }

    /**
     * Draws the full composited scene for the CURRENT EGL surface at
     * [outputWidthPx] x [outputHeightPx]: full clear to black, then the
     * background (the green-screen background in green-screen mode, else the
     * source video once a frame has latched), then the camera layer (keyed
     * camera in green-screen mode, live OES frame or placeholder otherwise).
     * Shared verbatim by the preview pass ([drawFrame]) and the green-screen
     * take recorder pass ([encodeRecorderFrame]) so the recorded take and the
     * preview can never diverge. Uses only state already latched / produced
     * by the enclosing drawFrame: never latches, never segments, never swaps.
     * Leaves the scissor test disabled.
     */
    private fun drawCompositedScene() {
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
        GLES20.glViewport(0, 0, outputWidthPx, outputHeightPx)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        // Background: in green-screen mode, the background may be the
        // source video (default, unchanged behavior), a solid color, or a
        // static image — drawn before the masked camera. Every other
        // layout mode keeps the unconditional source-video draw.
        if (greenScreenEnabled) {
            drawGreenScreenBackground(sourceRect ?: fullSurfaceRect())
        } else if (hasTexImage) {
            drawSourceRect(sourceRect ?: fullSurfaceRect())
        }

        // Camera rect drawing:
        // - Green-screen mode: draw camera masked by the segmentation mask.
        //   If no camera frame has arrived yet or no mask texture is ready,
        //   leave the source video visible (do NOT draw an opaque placeholder).
        // - Normal mode: draw live OES frame when available, else placeholder.
        val cr = cameraRect
        if (cr != null) {
            if (greenScreenEnabled) {
                // Green-screen: only draw when both camera OES and a mask
                // (GPU refined alpha, or the legacy CPU mask texture) are
                // ready. Source remains visible underneath (drawn above);
                // no opaque fill.
                val maskReady = if (gpuConfig != null) gpuHasRefinedAlpha else hasMaskTexture
                if (hasCameraTexImage && maskReady) {
                    drawCameraGreenScreen(cr)
                }
                // else: source remains visible, invariant satisfied.
            } else {
                if (hasCameraTexImage) {
                    drawCameraRect(cr)
                } else {
                    drawCameraPlaceholder(cr)
                }
            }
        }

        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }


    // -- Release (terminal, idempotent, never throws) --------------------------

    /**
     * Terminal teardown: window surface, GL program/texture, SurfaceTexture,
     * [decoderInputSurface] (the one place it is ever released; the caller
     * must have unbound the decoder first via rebindOutputSurface(null, ..)),
     * then the EGL context/display. Tolerates every EGL/GL error.
     */
    override fun release() {
        if (!isReleased.compareAndSet(false, true)) return

        try { surfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
        try { cameraSurfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}

        // Encoder surface first (it may be current), then the preview window.
        destroyRecorderSurfaceQuietly()
        destroyWindowSurfaceQuietly()
        outputSurface = null

        logGpuSegmenterReleaseSummary()

        // GL object teardown needs the context current; pbuffer provides that.
        if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglContext != EGL14.EGL_NO_CONTEXT) {
            makeCurrentQuietly(eglPbufferSurface)
            // GPU segmenter first: interpreter/delegate, then the native
            // segmenter's GL objects, then its draw program — all while this
            // context is still alive and current.
            teardownGpuSegmenterQuietly()
            try {
                if (oesProgram != 0) GLES20.glDeleteProgram(oesProgram)
            } catch (_: Throwable) {}
            try {
                if (oesTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(oesTextureId), 0)
            } catch (_: Throwable) {}
            try {
                if (cameraOesTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(cameraOesTextureId), 0)
            } catch (_: Throwable) {}
            // Green-screen GL teardown.
            try {
                if (greenScreenProgram != 0) GLES20.glDeleteProgram(greenScreenProgram)
            } catch (_: Throwable) {}
            try {
                if (maskTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(maskTextureId), 0)
            } catch (_: Throwable) {}
            try {
                if (backgroundImageProgram != 0) GLES20.glDeleteProgram(backgroundImageProgram)
            } catch (_: Throwable) {}
            try {
                if (backgroundImageTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(backgroundImageTextureId), 0)
            } catch (_: Throwable) {}
        }
        oesProgram = 0
        oesTextureId = 0
        cameraOesTextureId = 0
        greenScreenProgram = 0
        maskTextureId = 0
        hasMaskTexture = false
        hasLoggedFirstMaskUpload = false
        latestMaskWidth = 0
        latestMaskHeight = 0
        backgroundImageProgram = 0
        backgroundImageTextureId = 0
        backgroundImageWidthPx = 0
        backgroundImageHeightPx = 0
        backgroundImageLoadedPath = null
        backgroundImageDecodeFailed = false

        try { _decoderInputSurface?.release() } catch (_: Throwable) {}
        _decoderInputSurface = null
        try { surfaceTexture?.release() } catch (_: Throwable) {}
        surfaceTexture = null

        // Camera ingest teardown — compositor releases the cameraInputSurface here.
        try { _cameraInputSurface?.release() } catch (_: Throwable) {}
        _cameraInputSurface = null
        try { cameraSurfaceTexture?.release() } catch (_: Throwable) {}
        cameraSurfaceTexture = null

        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            try {
                EGL14.eglMakeCurrent(
                    eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
                )
            } catch (_: Throwable) {}
            if (eglPbufferSurface != EGL14.EGL_NO_SURFACE) {
                try { EGL14.eglDestroySurface(eglDisplay, eglPbufferSurface) } catch (_: Throwable) {}
            }
            if (eglContext != EGL14.EGL_NO_CONTEXT) {
                try { EGL14.eglDestroyContext(eglDisplay, eglContext) } catch (_: Throwable) {}
            }
            try { EGL14.eglTerminate(eglDisplay) } catch (_: Throwable) {}
        }
        eglPbufferSurface = EGL14.EGL_NO_SURFACE
        eglContext = EGL14.EGL_NO_CONTEXT
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglConfig = null
        coreReady = false
        hasTexImage = false
        hasCameraTexImage = false
    }

    // -- EGL core bootstrap ----------------------------------------------------

    /**
     * One-time EGL + ingest bootstrap: display, ES2 context, 1x1 pbuffer, OES
     * program/texture, SurfaceTexture and [decoderInputSurface]. On failure
     * everything partial is torn down and a later attach may retry.
     */
    private fun ensureCore(): Boolean {
        if (coreReady) return true
        try {
            val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (display == EGL14.EGL_NO_DISPLAY) {
                Log.w(TAG, "eglGetDisplay failed")
                return false
            }
            val version = IntArray(2)
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) {
                Log.w(TAG, "eglInitialize failed")
                return false
            }
            eglDisplay = display

            // PBUFFER bit alongside WINDOW so the same config backs both the
            // bootstrap pbuffer and the output window surface. ES 3 configs are
            // preferred so the GPU green-screen segmenter can get an ES 3.1
            // context; the historical ES 2 config/context request is the last
            // rung, so a device without ES 3 support boots exactly as before.
            var config: EGLConfig? = chooseConfig(display, EGLExt.EGL_OPENGL_ES3_BIT_KHR)
            var context: EGLContext? = null
            var requestedVersion = "none"
            if (config != null) {
                context = createContext(
                    display, config,
                    intArrayOf(
                        EGLExt.EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
                        EGLExt.EGL_CONTEXT_MINOR_VERSION_KHR, 1,
                        EGL14.EGL_NONE,
                    ),
                )
                requestedVersion = "3.1"
                if (context == null) {
                    context = createContext(
                        display, config, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE),
                    )
                    requestedVersion = "3"
                }
            }
            if (context == null) {
                config = chooseConfig(display, EGL14.EGL_OPENGL_ES2_BIT)
                if (config == null) {
                    Log.w(TAG, "eglChooseConfig failed")
                    teardownCoreQuietly()
                    return false
                }
                context = createContext(
                    display, config, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
                )
                requestedVersion = "2"
            }
            val chosenConfig = config
            if (context == null || chosenConfig == null) {
                Log.w(TAG, "eglCreateContext failed")
                teardownCoreQuietly()
                return false
            }
            eglConfig = chosenConfig
            eglContext = context

            val pbufferAttribs = intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE)
            val pbuffer = EGL14.eglCreatePbufferSurface(display, chosenConfig, pbufferAttribs, 0)
            if (pbuffer == null || pbuffer == EGL14.EGL_NO_SURFACE) {
                Log.w(TAG, "eglCreatePbufferSurface failed")
                teardownCoreQuietly()
                return false
            }
            eglPbufferSurface = pbuffer

            if (!EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)) {
                Log.w(TAG, "eglMakeCurrent(pbuffer) failed")
                teardownCoreQuietly()
                return false
            }

            recordGlesVersion()
            Log.i(
                TAG,
                "ANDROID_DUET_PREVIEW_COMPOSITOR_EGL requested=$requestedVersion " +
                    "gles=$glesMajor.$glesMinor computeCapable=$computeCapable " +
                    "renderer=${GLES20.glGetString(GLES20.GL_RENDERER)}",
            )

            setupOesProgram()
            setupDecoderIngest()
            setupCameraIngest()

            coreReady = true
            return true
        } catch (t: Throwable) {
            Log.w(TAG, "EGL core bootstrap threw: ${t.message}")
            teardownCoreQuietly()
            return false
        }
    }

    /** RGBA8 window|pbuffer config for [renderableType], or null when the display has none. */
    private fun chooseConfig(display: EGLDisplay, renderableType: Int): EGLConfig? {
        val attribs = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, renderableType,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        val ok = try {
            EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, numConfigs, 0)
        } catch (_: Throwable) {
            false
        }
        if (!ok || numConfigs[0] < 1) return null
        return configs[0]
    }

    /** Context for [config] with [contextAttribs], or null (never throws) when EGL rejects the request. */
    private fun createContext(display: EGLDisplay, config: EGLConfig, contextAttribs: IntArray): EGLContext? {
        val context = try {
            EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
        } catch (_: Throwable) {
            null
        }
        if (context == null || context == EGL14.EGL_NO_CONTEXT) {
            // Consume the error so a later, successful request starts clean.
            try { EGL14.eglGetError() } catch (_: Throwable) {}
            return null
        }
        return context
    }

    /**
     * Parses "OpenGL ES <major>.<minor> ..." from GL_VERSION on the current
     * context. GL_MAJOR_VERSION is an invalid enum on an ES 2 context, so the
     * string form is the only query that is safe on every rung.
     */
    private fun recordGlesVersion() {
        glesMajor = 0
        glesMinor = 0
        computeCapable = false
        val version = try { GLES20.glGetString(GLES20.GL_VERSION) } catch (_: Throwable) { null } ?: return
        val match = Regex("OpenGL ES (\\d+)\\.(\\d+)").find(version) ?: return
        glesMajor = match.groupValues[1].toIntOrNull() ?: 0
        glesMinor = match.groupValues[2].toIntOrNull() ?: 0
        computeCapable = glesMajor > 3 || (glesMajor == 3 && glesMinor >= 1)
    }

    private fun setupDecoderIngest() {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        oesTextureId = textures[0]
        if (oesTextureId == 0) throw IllegalStateException("glGenTextures failed for OES texture")
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        val texture = SurfaceTexture(oesTextureId)
        // Callback may fire on any looper; it only flips the flag, and
        // updateTexImage happens exclusively on the render thread in drawFrame.
        texture.setOnFrameAvailableListener { framePending.set(true) }
        surfaceTexture = texture
        _decoderInputSurface = Surface(texture)
    }




    /**
     * Allocates the camera OES texture, SurfaceTexture and [cameraInputSurface]
     * independently of the decoder ingest. Must be called from [ensureCore] after
     * the GL context is current.
     *
     * Sets a deterministic landscape preview default buffer size (1920×1080,
     * matching CameraX's negotiated Preview SurfaceRequest) on the SurfaceTexture
     * before wrapping it in a Surface. The size must be non-zero before the first
     * camera frame arrives so that updateTexImage produces a valid image and the
     * OES sampler has a defined texel size. Preview-ingress default only — no
     * recording/export claim.
     */
    private fun setupCameraIngest() {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        cameraOesTextureId = textures[0]
        if (cameraOesTextureId == 0) throw IllegalStateException("glGenTextures failed for camera OES texture")
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraOesTextureId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        val camTexture = SurfaceTexture(cameraOesTextureId)
        // Set a deterministic non-zero default buffer size before creating the
        // Surface. A zero default causes the first updateTexImage to return a
        // zero-size image, breaking the OES sampler. Preview-ingress default only.
        camTexture.setDefaultBufferSize(CAMERA_ST_DEFAULT_WIDTH, CAMERA_ST_DEFAULT_HEIGHT)
        // Callback may fire on any looper; only sets the flag — updateTexImage
        // happens exclusively on the render thread inside drawFrame.
        camTexture.setOnFrameAvailableListener { cameraFramePending.set(true) }
        cameraSurfaceTexture = camTexture
        _cameraInputSurface = Surface(camTexture)
    }

    private fun setupOesProgram() {
        val vertexSrc = """
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            uniform mat4 uSTMatrix;
            varying vec2 vTextureCoord;
            void main() {
                gl_Position = aPosition;
                vTextureCoord = (uSTMatrix * aTextureCoord).xy;
            }
        """.trimIndent()
        val fragmentSrc = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTextureCoord;
            uniform samplerExternalOES sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, vTextureCoord);
            }
        """.trimIndent()

        val vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, vertexSrc)
        val fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vertexShader)
        GLES20.glAttachShader(program, fragmentShader)
        GLES20.glLinkProgram(program)
        GLES20.glDeleteShader(vertexShader)
        GLES20.glDeleteShader(fragmentShader)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(program)
            GLES20.glDeleteProgram(program)
            throw IllegalStateException("GL program link failed: $log")
        }
        oesProgram = program
        aPositionLoc = GLES20.glGetAttribLocation(program, "aPosition")
        aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTextureCoord")
        uSTMatrixLoc = GLES20.glGetUniformLocation(program, "uSTMatrix")
        sTextureLoc = GLES20.glGetUniformLocation(program, "sTexture")
    }

    /**
     * Lazily compiles the green-screen shader program on demand (first time
     * green-screen draw is requested). Uses OES camera texture + 2D LUMINANCE
     * mask texture; alpha-blends the camera over the source based on mask.r.
     */
    private fun ensureGreenScreenProgram() {
        if (greenScreenProgram != 0) return
        val vertexSrc = """
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            uniform mat4 uSTMatrix;
            varying vec2 vTextureCoord;
            varying vec2 vMaskCoord;
            varying vec2 vRawTexCoord;
            void main() {
                gl_Position = aPosition;
                vec2 cameraCoord = (uSTMatrix * aTextureCoord).xy;
                vTextureCoord = cameraCoord;
                // Mask is sampled in the same ST-matrix-transformed camera UV
                // space as the camera texture, so no additional remapping is needed.
                vMaskCoord = clamp(cameraCoord, 0.0, 1.0);
                // Raw (untransformed) quad texture coordinate — debug-only,
                // used solely by the mask_direct diagnostic visualization.
                vRawTexCoord = aTextureCoord.xy;
            }
        """.trimIndent()
        val fragmentSrc = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTextureCoord;
            varying vec2 vMaskCoord;
            varying vec2 vRawTexCoord;
            uniform samplerExternalOES sCamera;
            uniform sampler2D uMask;
            // (1/maskWidth, 1/maskHeight) in mask UV space; drives the
            // one-mask-pixel erosion taps in normal (non-debug) mode only.
            uniform vec2 uMaskTexelSize;
            // Debug-only (RND diagnostic): 0 = normal, 1 = mask_direct,
            // 2 = mask_mapped, 3 = mask_direct_mirror_x, 4 = mask_direct_flip_y,
            // 5 = camera_passthrough.
            uniform int uDebugView;
            void main() {
                if (uDebugView == 5) {
                    // camera_passthrough: raw live camera feed, no mask, no
                    // smoothstep — drawCameraGreenScreen already scissors and
                    // viewports to the green-screen camera rect, so this only
                    // ever paints inside that rect.
                    vec4 cameraColorRaw = texture2D(sCamera, vTextureCoord);
                    gl_FragColor = vec4(cameraColorRaw.rgb, 1.0);
                    return;
                }
                if (uDebugView == 1) {
                    float rawMaskAlpha = texture2D(uMask, vRawTexCoord).r;
                    gl_FragColor = vec4(rawMaskAlpha, rawMaskAlpha, rawMaskAlpha, 1.0);
                    return;
                }
                if (uDebugView == 2) {
                    float rawMaskAlpha = texture2D(uMask, vMaskCoord).r;
                    gl_FragColor = vec4(rawMaskAlpha, rawMaskAlpha, rawMaskAlpha, 1.0);
                    return;
                }
                if (uDebugView == 3) {
                    // mask_direct_mirror_x: raw mask sampled with X inverted, to
                    // help RND spot a front-camera horizontal mirror mismatch.
                    float rawMaskAlpha = texture2D(uMask, vec2(1.0 - vRawTexCoord.x, vRawTexCoord.y)).r;
                    gl_FragColor = vec4(rawMaskAlpha, rawMaskAlpha, rawMaskAlpha, 1.0);
                    return;
                }
                if (uDebugView == 4) {
                    // mask_direct_flip_y: raw mask sampled with Y inverted, to
                    // help RND spot a front-camera vertical flip mismatch.
                    float rawMaskAlpha = texture2D(uMask, vec2(vRawTexCoord.x, 1.0 - vRawTexCoord.y)).r;
                    gl_FragColor = vec4(rawMaskAlpha, rawMaskAlpha, rawMaskAlpha, 1.0);
                    return;
                }
                vec4 cameraColor = texture2D(sCamera, vTextureCoord);
                // Physical RND on SM-A566B showed the CPU MediaPipe mask
                // arrives in raw analysis UV with vertical orientation
                // inverted relative to the GLES rect: mask_direct_flip_y was
                // the only debug candidate that placed the matte into the
                // foreground rect (mask_mapped produced a side-stripe
                // failure, mask_direct produced a top-heavy rectangle).
                // Normal mode therefore samples the raw mask with Y flipped;
                // vMaskCoord/mask_mapped remains diagnostic only.
                //
                // X is intentionally NOT flipped here. AndroidDuetMediaPipeSegmentationBackend
                // now mirrors its CPU input horizontally before segmentation (matching the
                // front-camera preview mirror applied by cameraStMatrix), so the mask buffer
                // itself already carries the same X orientation this raw-quad sampling
                // expects. Adding an X flip here on top of that would cancel the upstream
                // mirror fix and reintroduce the wrong-side registration bug.
                vec2 maskUv = vec2(vRawTexCoord.x, 1.0 - vRawTexCoord.y);
                float centerAlpha = texture2D(uMask, maskUv).r;
                // Conservative GPU-side matte refinement: take the minimum of
                // the centre tap and its four direct neighbours (one mask
                // pixel away, clamped inside [0,1]). This erodes the matte by
                // one mask pixel so false-positive room background clinging
                // to the head/shoulder silhouette shrinks, while the true
                // person core (uniformly high confidence) is unaffected.
                float leftAlpha  = texture2D(uMask, clamp(maskUv - vec2(uMaskTexelSize.x, 0.0), 0.0, 1.0)).r;
                float rightAlpha = texture2D(uMask, clamp(maskUv + vec2(uMaskTexelSize.x, 0.0), 0.0, 1.0)).r;
                float upAlpha    = texture2D(uMask, clamp(maskUv - vec2(0.0, uMaskTexelSize.y), 0.0, 1.0)).r;
                float downAlpha  = texture2D(uMask, clamp(maskUv + vec2(0.0, uMaskTexelSize.y), 0.0, 1.0)).r;
                float erodedAlpha = min(centerAlpha, min(min(leftAlpha, rightAlpha), min(upAlpha, downAlpha)));
                // Shape the eroded MediaPipe selfie-segmentation confidence
                // with a slightly stricter feather than the raw sample used
                // previously (0.45..0.75), so low-confidence background is
                // rejected while true edge pixels still feather smoothly.
                float maskAlpha = smoothstep(0.52, 0.78, erodedAlpha);
                gl_FragColor = vec4(cameraColor.rgb, cameraColor.a * maskAlpha);
            }
        """.trimIndent()
        val vs = compileShader(GLES20.GL_VERTEX_SHADER, vertexSrc)
        val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        val prog = GLES20.glCreateProgram()
        GLES20.glAttachShader(prog, vs)
        GLES20.glAttachShader(prog, fs)
        GLES20.glLinkProgram(prog)
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(prog)
            GLES20.glDeleteProgram(prog)
            throw IllegalStateException("GS program link failed: $log")
        }
        greenScreenProgram = prog
        gsAPositionLoc = GLES20.glGetAttribLocation(prog, "aPosition")
        gsATexCoordLoc = GLES20.glGetAttribLocation(prog, "aTextureCoord")
        gsUSTMatrixLoc = GLES20.glGetUniformLocation(prog, "uSTMatrix")
        gsSCameraLoc   = GLES20.glGetUniformLocation(prog, "sCamera")
        gsUMaskLoc     = GLES20.glGetUniformLocation(prog, "uMask")
        gsUDebugViewLoc = GLES20.glGetUniformLocation(prog, "uDebugView")
        gsUMaskTexelSizeLoc = GLES20.glGetUniformLocation(prog, "uMaskTexelSize")
    }

    /**
     * Uploads [frame]'s mask buffer into [maskTextureId] as a LUMINANCE texture,
     * dispatching on [AndroidDuetSegmentationFrame.format]:
     *   - FLOAT32_CONFIDENCE (ML Kit): float32 stride-4 -> byte pack (unchanged path).
     *   - UINT8_ALPHA (MediaPipe): stride-1 bytes uploaded as-is, never read as float.
     * Allocates the GL texture on first call. Must run on render thread.
     */
    private fun uploadMaskTexture(frame: AndroidDuetSegmentationFrame) {
        val w = frame.width
        val h = frame.height
        if (w <= 0 || h <= 0) {
            Log.w(TAG, "uploadMaskTexture: invalid dimensions ${w}x$h, skipping")
            return
        }
        if (maskTextureId == 0) {
            val texIds = IntArray(1)
            GLES20.glGenTextures(1, texIds, 0)
            maskTextureId = texIds[0]
            if (maskTextureId == 0) {
                Log.w(TAG, "uploadMaskTexture: glGenTextures failed")
                return
            }
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTextureId)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        } else {
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTextureId)
        }
        // Dispatch on the frame's declared byte layout. The two layouts differ in
        // stride (4 vs 1) and must never be interpreted through each other's path.
        val byteBuffer: java.nio.ByteBuffer = when (frame.format) {
            DuetSegmentationMaskFormat.FLOAT32_CONFIDENCE -> {
                // ML Kit produces float32 confidence values in [0,1]. Upload as LUMINANCE.
                // ES 2.0 does not support GL_R32F natively; pack float → byte (0–255).
                // Use a read-only duplicate so we never mutate the frame buffer's position.
                val buf = frame.maskBytes.asReadOnlyBuffer()
                    .order(java.nio.ByteOrder.nativeOrder())
                buf.rewind()
                val capacity = w * h
                val packed = java.nio.ByteBuffer.allocateDirect(capacity)
                for (i in 0 until capacity) {
                    val byteOffset = i * 4
                    val f = if (buf.limit() >= byteOffset + 4) buf.getFloat(byteOffset) else 0f
                    packed.put((f.coerceIn(0f, 1f) * 255f).toInt().toByte())
                }
                packed.rewind()
                packed
            }
            DuetSegmentationMaskFormat.UINT8_ALPHA -> {
                // MediaPipe rung: one byte per pixel already scaled to 0–255 on the
                // analysis thread. Upload through a read-only view bounded to exactly
                // w*h bytes — no float reinterpretation, no repack.
                val required = w * h
                val view = frame.maskBytes.asReadOnlyBuffer()
                view.rewind()
                if (view.capacity() < required) {
                    Log.w(TAG, "uploadMaskTexture: uint8 mask too small (${view.capacity()} < $required), skipping")
                    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
                    return
                }
                view.limit(required)
                view
            }
        }
        // GL_UNPACK_ALIGNMENT defaults to 4, which causes row misalignment for
        // single-channel (1 byte/pixel) mask rows whose width is not divisible by
        // 4.  Save the current alignment, force 1, upload, then restore — so we
        // don't leave a side-effect on the GL state machine.
        val prevAlignment = IntArray(1)
        GLES20.glGetIntegerv(GLES20.GL_UNPACK_ALIGNMENT, prevAlignment, 0)
        try {
            GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
            GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE,
                w, h, 0,
                GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, byteBuffer,
            )
        } finally {
            GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, prevAlignment[0])
        }
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        hasMaskTexture = true
        // Remember the uploaded dimensions so drawCameraGreenScreen can pass
        // the matching texel size to the erosion taps.
        latestMaskWidth = w
        latestMaskHeight = h
        if (!hasLoggedFirstMaskUpload) {
            hasLoggedFirstMaskUpload = true
            Log.i(
                TAG,
                "ANDROID_DUET_GREENSCREEN_MASK_UPLOAD_FIRST width=$w height=$h " +
                    "format=${frame.format.key} backend=${frame.backend}",
            )
        } else if (lastUploadedMaskBackend != null && lastUploadedMaskBackend != frame.backend) {
            Log.i(
                TAG,
                "ANDROID_DUET_GREENSCREEN_MASK_BACKEND_CHANGED from=$lastUploadedMaskBackend " +
                    "to=${frame.backend} format=${frame.format.key} width=$w height=$h",
            )
        }
        lastUploadedMaskBackend = frame.backend
    }

    /**
     * Draws the camera OES frame alpha-blended into [rect] using the current
     * mask texture. Dispatches on [foregroundRotationDegrees]: identity/near-zero
     * rotation keeps the exact axis-aligned fast path
     * ([drawCameraGreenScreenAxisAligned], unchanged pixel output); a non-zero
     * user rotation switches to [drawCameraGreenScreenRotated], which rotates
     * the quad geometry around the configured pivot instead of only cropping
     * to [rect].
     */
    private fun drawCameraGreenScreen(rect: VGDuetPixelRect) {
        val rotationDeg = foregroundRotationDegrees
        if (kotlin.math.abs(rotationDeg) < ROTATION_EPSILON_DEGREES) {
            drawCameraGreenScreenAxisAligned(rect)
        } else {
            drawCameraGreenScreenRotated(rect, rotationDeg)
        }
    }

    /**
     * Identity/near-zero-rotation path: unchanged from the pre-rotation
     * behavior. GL_BLEND is enabled around this draw only; source video
     * underneath shows through where mask alpha is low (background).
     *
     * Like [drawCameraRect], the viewport is aspect-filled (via
     * [cameraAspectFillViewport]) and the scissor crops the overflow back to
     * [rect]; camera passthrough and green-screen share the same aspect-fill
     * geometry so the two draws stay visually consistent.
     */
    private fun drawCameraGreenScreenAxisAligned(rect: VGDuetPixelRect) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return
        val viewport = cameraAspectFillViewport(rect)

        // Program + uniforms + textures for the active mask path (GPU refined
        // alpha or legacy CPU mask); compilation failure skips silently.
        val attribs = bindGreenScreenMaterial() ?: return

        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glViewport(viewport.x, viewport.y, viewport.width, viewport.height)

        // Enable blending so camera pixels with low mask alpha reveal the source below.
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)

        quadPositions.position(0)
        GLES20.glEnableVertexAttribArray(attribs.positionLoc)
        GLES20.glVertexAttribPointer(attribs.positionLoc, 2, GLES20.GL_FLOAT, false, 0, quadPositions)
        quadTexCoords.position(0)
        GLES20.glEnableVertexAttribArray(attribs.texCoordLoc)
        GLES20.glVertexAttribPointer(attribs.texCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(attribs.positionLoc)
        GLES20.glDisableVertexAttribArray(attribs.texCoordLoc)
        unbindGreenScreenMaterial()

        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    /**
     * Non-zero-rotation path: rotates the aspect-filled camera quad's four
     * corners around `pivot = (rect.left + foregroundAnchorX * rect.width,
     * rect.top + foregroundAnchorY * rect.height)` by [rotationDegrees]
     * (visual clockwise, Dart/top-left space) in canvas-pixel space, then maps
     * each rotated corner independently to NDC for the full output surface.
     *
     * Deliberately does not use [toGlRect]'s scissor/viewport cropping to
     * [rect]: a rotated quad's corners can land outside that axis-aligned box,
     * and clipping to it would cut off the rotated corners. Instead the
     * viewport covers the whole output surface with scissor disabled, and the
     * quad's own triangle-strip geometry — not a scissor rect — bounds what
     * gets rasterized, so nothing outside the rotated quad is drawn.
     *
     * Texture coordinates ([quadTexCoords]) and the camera's sensor transform
     * ([cameraStMatrix]) are untouched: only the on-screen vertex positions
     * rotate, so CameraX orientation/mirror correction stays exclusively in
     * [cameraStMatrix] as before.
     */
    private fun drawCameraGreenScreenRotated(rect: VGDuetPixelRect, rotationDegrees: Double) {
        if (outputWidthPx <= 0 || outputHeightPx <= 0) return
        val aspectRect = cameraAspectFillCanvasRect(rect)
        if (aspectRect.width <= 0.0 || aspectRect.height <= 0.0) return

        // Program + uniforms + textures for the active mask path (GPU refined
        // alpha or legacy CPU mask); compilation failure skips silently.
        val attribs = bindGreenScreenMaterial() ?: return

        val pivotX = rect.left + foregroundAnchorX * rect.width
        val pivotY = rect.top + foregroundAnchorY * rect.height
        val radians = Math.toRadians(rotationDegrees)
        val cosT = Math.cos(radians)
        val sinT = Math.sin(radians)

        // Canvas-space corners in the same vertex order as [quadPositions]
        // ((-1,-1),(1,-1),(-1,1),(1,1)): via toGlRect's y-flip those NDC
        // corners map to GL-viewport bottom-left/bottom-right/top-left/
        // top-right, i.e. canvas bottom-left/bottom-right/top-left/top-right.
        val left = aspectRect.left
        val top = aspectRect.top
        val right = aspectRect.left + aspectRect.width
        val bottom = aspectRect.top + aspectRect.height
        val cornersX = doubleArrayOf(left, right, left, right)
        val cornersY = doubleArrayOf(bottom, bottom, top, top)

        val ndc = FloatArray(8)
        for (i in 0 until 4) {
            val dx = cornersX[i] - pivotX
            val dy = cornersY[i] - pivotY
            val rx = pivotX + dx * cosT - dy * sinT
            val ry = pivotY + dx * sinT + dy * cosT
            ndc[i * 2] = ((rx / outputWidthPx) * 2.0 - 1.0).toFloat()
            ndc[i * 2 + 1] = (1.0 - (ry / outputHeightPx) * 2.0).toFloat()
        }
        rotatedQuadPositions.position(0)
        rotatedQuadPositions.put(ndc)
        rotatedQuadPositions.position(0)

        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
        GLES20.glViewport(0, 0, outputWidthPx, outputHeightPx)

        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)

        rotatedQuadPositions.position(0)
        GLES20.glEnableVertexAttribArray(attribs.positionLoc)
        GLES20.glVertexAttribPointer(attribs.positionLoc, 2, GLES20.GL_FLOAT, false, 0, rotatedQuadPositions)
        quadTexCoords.position(0)
        GLES20.glEnableVertexAttribArray(attribs.texCoordLoc)
        GLES20.glVertexAttribPointer(attribs.texCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(attribs.positionLoc)
        GLES20.glDisableVertexAttribArray(attribs.texCoordLoc)
        unbindGreenScreenMaterial()

        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    // -- Green-screen camera material (shared by the axis-aligned and rotated draws) --

    /** Vertex attribute locations of the bound green-screen program. */
    private data class GreenScreenMaterialAttribs(val positionLoc: Int, val texCoordLoc: Int)

    /**
     * Debug-only (RND diagnostic) view code shared by both mask paths:
     * 0 = normal, 1 = mask_direct, 2 = mask_mapped, 3 = mask_direct_mirror_x,
     * 4 = mask_direct_flip_y, 5 = camera_passthrough.
     */
    private fun greenScreenDebugViewCode(): Int = when (greenScreenDebugView) {
        "mask_direct" -> 1
        "mask_mapped" -> 2
        "mask_direct_mirror_x" -> 3
        "mask_direct_flip_y" -> 4
        "camera_passthrough" -> 5
        else -> 0
    }

    /**
     * Binds the program, uniforms and texture units for the camera draw of
     * the active mask path (GPU refined alpha when a config is latched, else
     * the legacy CPU mask) and returns its attribute locations, or null when
     * the program is unavailable (the caller skips the draw silently, leaving
     * the source video visible). Geometry, scissor/viewport and blending stay
     * with the two callers; [unbindGreenScreenMaterial] must follow the draw.
     */
    private fun bindGreenScreenMaterial(): GreenScreenMaterialAttribs? =
        if (gpuConfig != null) bindGpuGreenScreenMaterial() else bindLegacyGreenScreenMaterial()

    private fun bindLegacyGreenScreenMaterial(): GreenScreenMaterialAttribs? {
        ensureGreenScreenProgram()
        if (greenScreenProgram == 0) return null  // compilation failed; skip silently

        GLES20.glUseProgram(greenScreenProgram)
        GLES20.glUniform1i(gsUDebugViewLoc, greenScreenDebugViewCode())

        // Mask texel size for the normal-mode erosion taps. Falls back to
        // (1,1) when dimensions are not yet known (e.g. a draw racing ahead of
        // the first upload): neighbour taps then clamp to the texture edge, so
        // the shader degrades gracefully instead of reading garbage.
        val maskTexelW = if (latestMaskWidth > 0) 1f / latestMaskWidth else 1f
        val maskTexelH = if (latestMaskHeight > 0) 1f / latestMaskHeight else 1f
        GLES20.glUniform2f(gsUMaskTexelSizeLoc, maskTexelW, maskTexelH)

        // Texture unit 0: camera OES
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraOesTextureId)
        GLES20.glUniform1i(gsSCameraLoc, 0)
        GLES20.glUniformMatrix4fv(gsUSTMatrixLoc, 1, false, cameraStMatrix, 0)

        // Texture unit 1: mask (2D LUMINANCE)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTextureId)
        GLES20.glUniform1i(gsUMaskLoc, 1)
        return GreenScreenMaterialAttribs(gsAPositionLoc, gsATexCoordLoc)
    }

    private fun bindGpuGreenScreenMaterial(): GreenScreenMaterialAttribs? {
        if (gpuAlphaTextureId == 0) return null
        ensureGpuMaskedProgram()
        if (gpuMaskedProgram == 0) return null

        GLES20.glUseProgram(gpuMaskedProgram)
        GLES20.glUniform1i(gpuUDebugViewLoc, greenScreenDebugViewCode())
        GLES20.glUniform2f(
            gpuUAlphaResolutionLoc,
            maxOf(gpuAlphaWidth, 1).toFloat(),
            maxOf(gpuAlphaHeight, 1).toFloat(),
        )
        GLES20.glUniform1i(gpuUDespillLoc, if (GPU_DESPILL_ENABLED) 1 else 0)

        // Texture unit 0: camera OES, sampled through the latched transform
        // (the same matrix the segmenter used for this frame's alpha).
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraOesTextureId)
        GLES20.glUniform1i(gpuSCameraLoc, 0)
        GLES20.glUniformMatrix4fv(gpuUSTMatrixLoc, 1, false, cameraStMatrix, 0)

        // Texture unit 1: refined alpha (R32F, NEAREST, quad space)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, gpuAlphaTextureId)
        GLES20.glUniform1i(gpuUAlphaLoc, 1)
        return GreenScreenMaterialAttribs(gpuAPositionLoc, gpuATexCoordLoc)
    }

    /** Unbinds the two texture units used by [bindGreenScreenMaterial] and returns to unit 0. */
    private fun unbindGreenScreenMaterial() {
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
    }

    /**
     * Lazily compiles the GLES 3.00 program that keys the camera by the GPU
     * segmenter's refined alpha. The fragment stage is the `maskedCamera`
     * branch of the committed GPU-resident composite shader
     * (gles_green_screen_gpu_resident_shaders.h): Hermite-interpolated alpha
     * at uAlphaResolution, isotropic 8-point boundary contraction,
     * smoothstep(0.05, 0.95) threshold and inward-normal despill, emitted as
     * straight alpha so the existing SRC_ALPHA / ONE_MINUS_SRC_ALPHA blend
     * over the already-drawn background is the same `mix(background,
     * camera, compAlpha)` the standalone path computes in one pass. Camera UV
     * policy is identical to the segmenter's passes: quadUv (raw quad texture
     * coordinate, v=0 at the bottom) through the latched transform matrix;
     * the alpha texture lives in that quad space and is sampled unflipped.
     * A compile failure is terminal for the GPU path of this compositor.
     */
    private fun ensureGpuMaskedProgram() {
        if (gpuMaskedProgram != 0 || gpuMaskedProgramFailed) return
        val vertexSrc = """
            #version 300 es
            in vec4 aPosition;
            in vec4 aTextureCoord;
            out vec2 vQuadUv;
            void main() {
                gl_Position = aPosition;
                vQuadUv = aTextureCoord.xy;
            }
        """.trimIndent()
        val fragmentSrc = """
            #version 300 es
            #extension GL_OES_EGL_image_external_essl3 : require
            precision highp float;
            precision highp int;

            in vec2 vQuadUv;
            out vec4 fragColor;

            uniform samplerExternalOES sCamera;
            uniform sampler2D uAlphaTexture;
            uniform vec2 uAlphaResolution;
            uniform mat4 uSTMatrix;
            uniform bool uDespillEnabled;
            // Debug-only (RND diagnostic): 0 = normal, 1 = mask_direct,
            // 2 = mask_mapped, 3 = mask_direct_mirror_x, 4 = mask_direct_flip_y,
            // 5 = camera_passthrough.
            uniform int uDebugView;

            float getLuma(vec3 rgb) {
                return dot(rgb, vec3(0.299, 0.587, 0.114));
            }

            vec2 camUvFor(vec2 quadUv) {
                return (uSTMatrix * vec4(quadUv, 0.0, 1.0)).xy;
            }

            float sampleHermiteAlpha(vec2 uv) {
                vec2 res = uAlphaResolution;
                vec2 pos = uv * res - 0.5;
                vec2 f = fract(pos);
                vec2 p = (floor(pos) + 0.5) / res;
                vec2 d = 1.0 / res;
                // Cubic Hermite smoothstep for C1-continuous derivatives across texels.
                vec2 s = f * f * (3.0 - 2.0 * f);
                float a00 = texture(uAlphaTexture, p).r;
                float a10 = texture(uAlphaTexture, p + vec2(d.x, 0.0)).r;
                float a01 = texture(uAlphaTexture, p + vec2(0.0, d.y)).r;
                float a11 = texture(uAlphaTexture, p + d).r;
                return mix(mix(a00, a10, s.x), mix(a01, a11, s.x), s.y);
            }

            void main() {
                vec2 uv = vQuadUv;
                if (uDebugView == 5) {
                    // camera_passthrough: raw live camera feed, no mask.
                    fragColor = vec4(texture(sCamera, camUvFor(uv)).rgb, 1.0);
                    return;
                }
                if (uDebugView != 0) {
                    vec2 maskUv = uv;
                    if (uDebugView == 2) maskUv = clamp(camUvFor(uv), 0.0, 1.0);
                    else if (uDebugView == 3) maskUv = vec2(1.0 - uv.x, uv.y);
                    else if (uDebugView == 4) maskUv = vec2(uv.x, 1.0 - uv.y);
                    float rawAlpha = texture(uAlphaTexture, maskUv).r;
                    fragColor = vec4(rawAlpha, rawAlpha, rawAlpha, 1.0);
                    return;
                }

                vec3 cameraColor = texture(sCamera, camUvFor(uv)).rgb;
                float alpha = sampleHermiteAlpha(uv);

                // Isotropic 8-point anti-aliased boundary refinement (radius 1.5 alpha pixels).
                vec2 px = 1.5 / uAlphaResolution;
                float aN = sampleHermiteAlpha(uv + vec2(0.0, px.y));
                float aS = sampleHermiteAlpha(uv - vec2(0.0, px.y));
                float aE = sampleHermiteAlpha(uv + vec2(px.x, 0.0));
                float aW = sampleHermiteAlpha(uv - vec2(px.x, 0.0));

                vec2 dPx = px * 0.7071068;
                float aNE = sampleHermiteAlpha(uv + vec2( dPx.x,  dPx.y));
                float aNW = sampleHermiteAlpha(uv + vec2(-dPx.x,  dPx.y));
                float aSE = sampleHermiteAlpha(uv + vec2( dPx.x, -dPx.y));
                float aSW = sampleHermiteAlpha(uv + vec2(-dPx.x, -dPx.y));

                float minCardinal = min(min(aN, aS), min(aE, aW));
                float minDiagonal = min(min(aNE, aNW), min(aSE, aSW));
                float isotropicMin = min(minCardinal, minDiagonal);

                // Soft boundary contraction: pulls the boundary inward to remove light wall fringe.
                float boundaryT = smoothstep(0.10, 0.85, alpha);
                float softAlpha = mix(isotropicMin, alpha, boundaryT);

                // Continuous sigmoidal threshold with C1 sub-pixel antialiasing.
                float compAlpha = smoothstep(0.05, 0.95, softAlpha);

                // Ambient wall light decontamination (despill) along the inward normal.
                if (uDespillEnabled && compAlpha > 0.02 && compAlpha < 0.90) {
                    vec2 grad = vec2(aE - aW, aN - aS);
                    float gradLen = length(grad);
                    if (gradLen > 0.001) {
                        vec2 inDir = (grad / gradLen) * 3.0 * px;
                        float inAlpha = sampleHermiteAlpha(uv + inDir);
                        if (inAlpha > 0.70) {
                            vec3 inCol = texture(sCamera, camUvFor(clamp(uv + inDir, 0.0, 1.0))).rgb;
                            float inLuma = getLuma(inCol);
                            float camLuma = getLuma(cameraColor);
                            if (camLuma > inLuma * 1.05) {
                                cameraColor = mix(cameraColor, inCol, (1.0 - compAlpha) * 0.70);
                            }
                        }
                    }
                }

                fragColor = vec4(cameraColor, compAlpha);
            }
        """.trimIndent()
        try {
            val vs = compileShader(GLES20.GL_VERTEX_SHADER, vertexSrc)
            val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
            val prog = GLES20.glCreateProgram()
            GLES20.glAttachShader(prog, vs)
            GLES20.glAttachShader(prog, fs)
            GLES20.glLinkProgram(prog)
            GLES20.glDeleteShader(vs)
            GLES20.glDeleteShader(fs)
            val linkStatus = IntArray(1)
            GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, linkStatus, 0)
            if (linkStatus[0] == 0) {
                val log = GLES20.glGetProgramInfoLog(prog)
                GLES20.glDeleteProgram(prog)
                throw IllegalStateException("GPU GS program link failed: $log")
            }
            gpuMaskedProgram = prog
            gpuAPositionLoc = GLES20.glGetAttribLocation(prog, "aPosition")
            gpuATexCoordLoc = GLES20.glGetAttribLocation(prog, "aTextureCoord")
            gpuUSTMatrixLoc = GLES20.glGetUniformLocation(prog, "uSTMatrix")
            gpuSCameraLoc = GLES20.glGetUniformLocation(prog, "sCamera")
            gpuUAlphaLoc = GLES20.glGetUniformLocation(prog, "uAlphaTexture")
            gpuUAlphaResolutionLoc = GLES20.glGetUniformLocation(prog, "uAlphaResolution")
            gpuUDespillLoc = GLES20.glGetUniformLocation(prog, "uDespillEnabled")
            gpuUDebugViewLoc = GLES20.glGetUniformLocation(prog, "uDebugView")
        } catch (t: Throwable) {
            gpuMaskedProgramFailed = true
            gpuMaskedProgram = 0
            Log.w(TAG, "ANDROID_DUET_GPU_GREENSCREEN_MASKED_PROGRAM_FAILED ${t.message}")
            notifyGpuSegmenterUnavailableOnce("masked_program_compile_failed")
        }
    }

    // -- GPU green-screen segmenter (render thread, context current) -------------

    private fun logMaskPathOnce(path: String) {
        if (loggedMaskPath) return
        loggedMaskPath = true
        Log.i(TAG, "ANDROID_DUET_GREENSCREEN_MASK_PATH path=$path gles=$glesMajor.$glesMinor computeCapable=$computeCapable")
    }

    /**
     * Lazy bootstrap of the GPU segmenter for the latched [gpuConfig], on the
     * render thread with the window surface current (called from
     * [drawFrame]): ES 3.1 gate, native segmenter in THIS context, TFLite
     * interpreter (GPU delegate created right here so its GL backend binds to
     * this context; CPU XNNPACK only if the delegate fails, mirroring
     * AndroidGreenScreenGpuResidentPreviewBackend), tensor validation, model
     * input configuration. Any failure is terminal for this compositor
     * ([gpuSegmenterFailed]): everything partial is torn down, the camera
     * layer stays undrawn (source visible) and the listener is told once per
     * enable so the provider can apply the existing PiP fallback.
     */
    private fun ensureGpuSegmenter(): Boolean {
        if (gpuSegmenterReady) return true
        if (gpuSegmenterFailed) {
            notifyGpuSegmenterUnavailableOnce(gpuSegmenterFailureReason ?: "segmenter_unavailable")
            return false
        }
        val config = gpuConfig ?: return false
        if (!computeCapable) {
            failGpuSegmenterBootstrap("gles31_unavailable:$glesMajor.$glesMinor")
            return false
        }
        if (cameraOesTextureId == 0) {
            failGpuSegmenterBootstrap("camera_texture_missing")
            return false
        }
        val t0 = SystemClock.elapsedRealtime()
        try {
            val handle = gpuBridge.nativeSegmenterCreate()
            if (handle == 0L) {
                failGpuSegmenterBootstrap("native_segmenter_create_failed")
                return false
            }
            gpuSegmenterHandle = handle

            // Interpreter on this very thread with this context current: the
            // GPU delegate's GL backend binds to the current context.
            val session = openGpuModelSession(config)
            gpuModel = session

            if (!gpuBridge.nativeSegmenterConfigureModelInput(handle, session.inputWidth, session.inputHeight)) {
                failGpuSegmenterBootstrap("model_input_configure_failed:" + gpuBridge.nativeSegmenterLastError(handle))
                return false
            }
            gpuBridge.nativeSegmenterSetFilterToggles(handle, GPU_GUIDED_FILTER_ENABLED, GPU_TEMPORAL_STABILIZER_ENABLED)
            gpuBridge.nativeSegmenterSetAlphaTargetSize(handle, outputWidthPx, outputHeightPx)
            gpuBridge.nativeSegmenterSetCameraTransform(handle, cameraStMatrix, CAMERA_UPRIGHT_ASPECT.toFloat())

            gpuSegmenterReady = true
            gpuSessionStartMs = SystemClock.elapsedRealtime()
            Log.i(
                TAG,
                "ANDROID_DUET_GPU_GREENSCREEN_SEGMENTER_READY delegate=${session.delegateLabel} " +
                    "model=${config.modelAssetPath} input=${session.inputShape} output=${session.outputShape} " +
                    "gles=$glesMajor.$glesMinor cameraTexture=$cameraOesTextureId " +
                    "output=${outputWidthPx}x$outputHeightPx initMs=${SystemClock.elapsedRealtime() - t0}",
            )
            try { config.listener.onSegmenterReady(session.delegateLabel) } catch (_: Throwable) {}
            return true
        } catch (t: Throwable) {
            failGpuSegmenterBootstrap("exception:${t.javaClass.simpleName}:${t.message}")
            return false
        }
    }

    private fun failGpuSegmenterBootstrap(reason: String) {
        Log.w(TAG, "ANDROID_DUET_GPU_GREENSCREEN_SEGMENTER_INIT_FAILED reason=$reason")
        teardownGpuSegmenterQuietly()
        gpuSegmenterFailed = true
        gpuSegmenterFailureReason = reason
        notifyGpuSegmenterUnavailableOnce(reason)
    }

    /** Tells the latched config's listener once per enable that no alpha will be produced. */
    private fun notifyGpuSegmenterUnavailableOnce(reason: String) {
        if (gpuUnavailableNotified) return
        gpuUnavailableNotified = true
        val config = gpuConfig ?: return
        try { config.listener.onSegmenterUnavailable(reason) } catch (_: Throwable) {}
    }

    /**
     * One same-frame transaction for the camera frame latched by the caller:
     * transform latch -> native downscale -> Interpreter.run -> native coarse
     * mask upload -> native refine. Returns true when a new refined alpha is
     * available. Every stage failure counts toward
     * [GPU_MAX_CONSECUTIVE_INFERENCE_FAILURES]; reaching it disables the GPU
     * path for this enable (camera layer not drawn, source stays visible) and
     * notifies the listener once.
     */
    private fun runGpuSegmentationOnLatchedFrame(): Boolean {
        val handle = gpuSegmenterHandle
        val session = gpuModel ?: return false
        if (handle == 0L || cameraOesTextureId == 0) return false

        gpuBridge.nativeSegmenterSetCameraTransform(handle, cameraStMatrix, CAMERA_UPRIGHT_ASPECT.toFloat())

        val tDownscale = SystemClock.elapsedRealtimeNanos()
        session.inputBuffer.rewind()
        if (!gpuBridge.nativeSegmenterDownscaleCameraToModelInput(handle, cameraOesTextureId, session.inputBuffer)) {
            return recordGpuSegmentationFailure("downscale", gpuBridge.nativeSegmenterLastError(handle))
        }
        val downscaleNs = SystemClock.elapsedRealtimeNanos() - tDownscale

        val tInference = SystemClock.elapsedRealtimeNanos()
        try {
            session.inputBuffer.rewind()
            session.outputBuffer.rewind()
            session.interpreter.run(session.inputBuffer, session.outputBuffer)
        } catch (t: Throwable) {
            return recordGpuSegmentationFailure("inference", "${t.javaClass.simpleName}: ${t.message}")
        }
        val inferenceNs = SystemClock.elapsedRealtimeNanos() - tInference

        session.outputBuffer.rewind()
        if (!gpuBridge.nativeSegmenterUploadCoarseMask(handle, session.outputBuffer, session.maskWidth, session.maskHeight)) {
            return recordGpuSegmentationFailure("mask_upload", gpuBridge.nativeSegmenterLastError(handle))
        }
        val tRefine = SystemClock.elapsedRealtimeNanos()
        if (!gpuBridge.nativeSegmenterRefineAlpha(handle, cameraOesTextureId)) {
            return recordGpuSegmentationFailure("refine", gpuBridge.nativeSegmenterLastError(handle))
        }
        val refineNs = SystemClock.elapsedRealtimeNanos() - tRefine
        val alphaTexture = gpuBridge.nativeSegmenterRefinedAlphaTextureId(handle)
        if (alphaTexture == 0) {
            return recordGpuSegmentationFailure("alpha_texture_missing", gpuBridge.nativeSegmenterLastError(handle))
        }
        gpuAlphaTextureId = alphaTexture
        gpuAlphaWidth = gpuBridge.nativeSegmenterAlphaWidth(handle)
        gpuAlphaHeight = gpuBridge.nativeSegmenterAlphaHeight(handle)

        gpuConsecutiveInferenceFailures = 0
        gpuInferenceCount++
        gpuTotalInferenceNs += inferenceNs
        if (inferenceNs > gpuMaxInferenceNs) gpuMaxInferenceNs = inferenceNs
        gpuHasRefinedAlpha = true

        if (!gpuFirstInferenceLogged) {
            gpuFirstInferenceLogged = true
            Log.i(
                TAG,
                "ANDROID_DUET_GPU_GREENSCREEN_FIRST_INFERENCE delegate=${session.delegateLabel} " +
                    "input=${session.inputShape} output=${session.outputShape} " +
                    "alpha=${gpuAlphaWidth}x$gpuAlphaHeight " +
                    "downscaleMs=${"%.2f".format(downscaleNs / 1_000_000.0)} " +
                    "inferenceMs=${"%.2f".format(inferenceNs / 1_000_000.0)} " +
                    "refineMs=${"%.2f".format(refineNs / 1_000_000.0)} " +
                    "sinceReadyMs=${SystemClock.elapsedRealtime() - gpuSessionStartMs} " +
                    "stMatrix=[" + cameraStMatrix.joinToString(",") { "%.3f".format(it) } + "]",
            )
        }
        if (!gpuFirstMaskSignaled) {
            gpuFirstMaskSignaled = true
            val config = gpuConfig
            if (config != null) {
                try { config.listener.onFirstMask() } catch (_: Throwable) {}
            }
        }
        return true
    }

    private fun recordGpuSegmentationFailure(stage: String, detail: String): Boolean {
        gpuInferenceFailureCount++
        gpuConsecutiveInferenceFailures++
        Log.w(
            TAG,
            "ANDROID_DUET_GPU_GREENSCREEN_SEGMENTATION_FAILED stage=$stage " +
                "consecutive=$gpuConsecutiveInferenceFailures $detail",
        )
        if (gpuConsecutiveInferenceFailures >= GPU_MAX_CONSECUTIVE_INFERENCE_FAILURES) {
            gpuInferenceDisabled = true
            gpuHasRefinedAlpha = false
            gpuAlphaTextureId = 0
            Log.w(TAG, "ANDROID_DUET_GPU_GREENSCREEN_INFERENCE_DISABLED after $gpuConsecutiveInferenceFailures failures stage=$stage")
            notifyGpuSegmenterUnavailableOnce("inference_disabled:$stage")
        }
        return false
    }

    /**
     * Loads the model asset and creates the Interpreter with the RND delegate
     * policy (same as AndroidGreenScreenGpuResidentPreviewBackend):
     * CompatibilityList best options when supported (else default options),
     * INFERENCE_PREFERENCE_SUSTAINED_SPEED, precision loss allowed; CPU
     * (XNNPACK, 4 threads) only if GPU delegate/interpreter creation fails.
     * Validates FLOAT32 NHWC [1,h,w,3] input and [1,h,w,1] / [1,h,w] output;
     * allocates direct native-order buffers from the real tensor byte sizes.
     * Throws on any unsupported model.
     */
    private fun openGpuModelSession(config: AndroidDuetGpuGreenScreenSegmenterBinding.Config): GpuModelSession {
        val modelBytes = loadGpuModelBytes(config)
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
                "ANDROID_DUET_GPU_GREENSCREEN_DELEGATE_FALLBACK reason=gpu_delegate_create_failed " +
                    "${t.javaClass.simpleName}: ${t.message}",
            )
            try { delegate?.close() } catch (_: Throwable) {}
            delegate = null
            options = gpuCpuInterpreterOptions()
            delegateLabel = "cpu_xnnpack"
        }

        var interpreter: Interpreter
        try {
            interpreter = Interpreter(modelBytes, options)
        } catch (t: Throwable) {
            val gpuDelegate = delegate ?: throw t
            Log.w(
                TAG,
                "ANDROID_DUET_GPU_GREENSCREEN_DELEGATE_FALLBACK reason=gpu_interpreter_create_failed " +
                    "${t.javaClass.simpleName}: ${t.message}",
            )
            try { gpuDelegate.close() } catch (_: Throwable) {}
            delegate = null
            delegateLabel = "cpu_xnnpack"
            interpreter = Interpreter(modelBytes, gpuCpuInterpreterOptions())
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

            return GpuModelSession(
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

    private fun gpuCpuInterpreterOptions(): Interpreter.Options =
        Interpreter.Options().apply {
            setNumThreads(GPU_CPU_FALLBACK_THREADS)
            setUseXNNPACK(true)
        }

    private fun loadGpuModelBytes(config: AndroidDuetGpuGreenScreenSegmenterBinding.Config): ByteBuffer {
        val raw = config.applicationContext.assets.open(config.modelAssetPath).use { it.readBytes() }
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
     * Releases everything the GPU path owns, in order: interpreter + delegate
     * (with this context current), the native segmenter's GL objects (handle
     * destroyed), then the masked draw program. Never touches the camera OES
     * texture, the EGL objects or any other compositor state. Idempotent;
     * requires the compositor's context to be current (callers guarantee it).
     */
    private fun teardownGpuSegmenterQuietly() {
        gpuModel?.closeQuietly()
        gpuModel = null
        val handle = gpuSegmenterHandle
        gpuSegmenterHandle = 0L
        if (handle != 0L) {
            try { gpuBridge.nativeSegmenterDestroy(handle) } catch (_: Throwable) {}
        }
        if (gpuMaskedProgram != 0) {
            try { GLES20.glDeleteProgram(gpuMaskedProgram) } catch (_: Throwable) {}
        }
        gpuMaskedProgram = 0
        gpuMaskedProgramFailed = false
        gpuSegmenterReady = false
        gpuHasRefinedAlpha = false
        gpuAlphaTextureId = 0
        gpuAlphaWidth = 0
        gpuAlphaHeight = 0
    }

    /** Physical-proof summary; silent when the GPU path was never engaged (PiP/split logs unchanged). */
    private fun logGpuSegmenterReleaseSummary() {
        if (gpuSegmenterHandle == 0L && gpuModel == null && !gpuSegmenterFailed && gpuFrameCount == 0L) return
        val avgInferenceMs = if (gpuInferenceCount > 0) gpuTotalInferenceNs / gpuInferenceCount / 1_000_000.0 else 0.0
        val nativeSummary = if (gpuSegmenterHandle != 0L) {
            try { gpuBridge.nativeSegmenterStatsSummary(gpuSegmenterHandle) } catch (_: Throwable) { "unavailable" }
        } else "not_created"
        Log.i(
            TAG,
            "ANDROID_DUET_GPU_GREENSCREEN_RELEASE_SUMMARY frames=$gpuFrameCount " +
                "inferences=$gpuInferenceCount failures=$gpuInferenceFailureCount " +
                "avgInferenceMs=${"%.2f".format(avgInferenceMs)} " +
                "maxInferenceMs=${"%.2f".format(gpuMaxInferenceNs / 1_000_000.0)} " +
                "delegate=${gpuModel?.delegateLabel ?: "none"} inferenceDisabled=$gpuInferenceDisabled " +
                "bootstrapFailed=$gpuSegmenterFailed reason=${gpuSegmenterFailureReason ?: "none"} " +
                "gles=$glesMajor.$glesMinor " +
                "uptimeMs=${if (gpuSessionStartMs > 0) SystemClock.elapsedRealtime() - gpuSessionStartMs else 0} " +
                "native=[$nativeSummary]",
        )
    }

    // -- Green-screen static background draws -----------------------------------

    /**
     * Draws the background layer beneath the masked camera in green-screen
     * mode, dispatching on [greenScreenBackground]'s type. [VIDEO] preserves
     * the exact prior behavior (source drawn only once a real frame has
     * latched); [SOLID_COLOR] and [IMAGE] never touch the decoder.
     */
    private fun drawGreenScreenBackground(rect: VGDuetPixelRect) {
        when (greenScreenBackground.type) {
            AndroidDuetGreenScreenBackgroundType.VIDEO -> {
                releaseBackgroundImageTextureQuietly()
                if (hasTexImage) drawSourceRect(rect)
            }
            AndroidDuetGreenScreenBackgroundType.SOLID_COLOR -> {
                releaseBackgroundImageTextureQuietly()
                drawSolidColorBackground(rect, greenScreenBackground.argbColor)
            }
            AndroidDuetGreenScreenBackgroundType.IMAGE -> {
                ensureBackgroundImageTexture(greenScreenBackground)
                if (backgroundImageTextureId != 0) {
                    drawImageBackground(rect)
                } else {
                    // Missing path or decode failure: opaque black fallback.
                    drawSolidColorBackground(rect, AndroidDuetGreenScreenBackground.VIDEO.argbColor)
                }
            }
        }
    }

    /** Solid ARGB scissor-clear of [rect]. Used for [SOLID_COLOR] and as the IMAGE fallback. */
    private fun drawSolidColorBackground(rect: VGDuetPixelRect, argbColor: Int) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return
        val a = ((argbColor ushr 24) and 0xFF) / 255f
        val r = ((argbColor ushr 16) and 0xFF) / 255f
        val g = ((argbColor ushr 8) and 0xFF) / 255f
        val b = (argbColor and 0xFF) / 255f
        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glClearColor(r, g, b, a)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    /**
     * Lazily (re)loads [bg]'s image file into [backgroundImageTextureId].
     * No-ops once a texture matching [bg]'s filePath is already loaded, or
     * once decode/upload has already failed for that path (never retries
     * every frame). Releases a stale texture from a previous path first.
     * Must run on the render thread with the EGL context current (called
     * from inside [drawFrame]).
     */
    private fun ensureBackgroundImageTexture(bg: AndroidDuetGreenScreenBackground) {
        if (backgroundImageTextureId != 0 && backgroundImageLoadedPath == bg.filePath) return
        if (backgroundImageLoadedPath != bg.filePath) {
            releaseBackgroundImageTextureQuietly()
            // A prior failure was scoped to the old path; a new path deserves
            // its own decode attempt rather than inheriting that failure.
            backgroundImageDecodeFailed = false
        }
        backgroundImageLoadedPath = bg.filePath
        if (backgroundImageDecodeFailed) return

        val path = bg.filePath
        if (path == null) {
            backgroundImageDecodeFailed = true
            Log.w(TAG, "ANDROID_DUET_GREENSCREEN_BACKGROUND_IMAGE_FALLBACK reason=missing_path path=")
            return
        }
        val bitmap = try {
            android.graphics.BitmapFactory.decodeFile(path)
        } catch (t: Throwable) {
            null
        }
        if (bitmap == null) {
            backgroundImageDecodeFailed = true
            Log.w(TAG, "ANDROID_DUET_GREENSCREEN_BACKGROUND_IMAGE_FALLBACK reason=decode_failed path=$path")
            return
        }
        try {
            val texIds = IntArray(1)
            GLES20.glGenTextures(1, texIds, 0)
            val texId = texIds[0]
            if (texId == 0) {
                backgroundImageDecodeFailed = true
                Log.w(TAG, "ANDROID_DUET_GREENSCREEN_BACKGROUND_IMAGE_FALLBACK reason=texture_alloc_failed path=$path")
                return
            }
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texId)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            android.opengl.GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
            backgroundImageTextureId = texId
            backgroundImageWidthPx = bitmap.width
            backgroundImageHeightPx = bitmap.height
            backgroundImageDecodeFailed = false
        } finally {
            bitmap.recycle()
        }
    }

    /**
     * Releases the current background image texture and its cached path/failure
     * state (idempotent). Clearing [backgroundImageLoadedPath] and
     * [backgroundImageDecodeFailed] here ensures switching away to VIDEO/SOLID_COLOR
     * never leaves stale state that would block a later reload of the same path.
     * Render-thread only.
     */
    private fun releaseBackgroundImageTextureQuietly() {
        if (backgroundImageTextureId != 0) {
            try { GLES20.glDeleteTextures(1, intArrayOf(backgroundImageTextureId), 0) } catch (_: Throwable) {}
        }
        backgroundImageTextureId = 0
        backgroundImageWidthPx = 0
        backgroundImageHeightPx = 0
        backgroundImageLoadedPath = null
        backgroundImageDecodeFailed = false
    }

    /**
     * Draws [backgroundImageTextureId] into [rect] using [greenScreenBackground]'s
     * scale mode. Letterbox/pillarbox area (aspectFit) is cleared to black first.
     */
    private fun drawImageBackground(rect: VGDuetPixelRect) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return
        ensureBackgroundImageProgram()
        if (backgroundImageProgram == 0) {
            drawSolidColorBackground(rect, AndroidDuetGreenScreenBackground.VIDEO.argbColor)
            return
        }

        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        val viewport = backgroundImageAspectViewport(rect)
        GLES20.glViewport(viewport.x, viewport.y, viewport.width, viewport.height)

        GLES20.glUseProgram(backgroundImageProgram)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, backgroundImageTextureId)
        GLES20.glUniform1i(bgImageSTextureLoc, 0)

        quadPositions.position(0)
        GLES20.glEnableVertexAttribArray(bgImageAPositionLoc)
        GLES20.glVertexAttribPointer(bgImageAPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadPositions)
        quadTexCoords.position(0)
        GLES20.glEnableVertexAttribArray(bgImageATexCoordLoc)
        GLES20.glVertexAttribPointer(bgImageATexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(bgImageAPositionLoc)
        GLES20.glDisableVertexAttribArray(bgImageATexCoordLoc)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    /**
     * Viewport for the background image inside [rect], per [greenScreenBackground]'s
     * scale mode: aspectFill (cover, overflow cropped by the scissor already set)
     * or aspectFit (contain, remaining area stays the black clear from [drawImageBackground]).
     * Unknown image size degrades to the rect itself (stretch).
     */
    private fun backgroundImageAspectViewport(rect: VGDuetPixelRect): GlRect {
        val rectW = rect.width
        val rectH = rect.height
        if (backgroundImageWidthPx <= 0 || backgroundImageHeightPx <= 0 || rectW <= 0.0 || rectH <= 0.0) {
            return toGlRect(rect.left, rect.top, rectW, rectH)
        }
        val imageAspect = backgroundImageWidthPx.toDouble() / backgroundImageHeightPx.toDouble()
        val rectAspect = rectW / rectH
        val cover = greenScreenBackground.scaleMode != AndroidDuetBackgroundScaleMode.ASPECT_FIT
        val matchHeightBasis = if (cover) imageAspect > rectAspect else imageAspect <= rectAspect
        val drawnW: Double
        val drawnH: Double
        if (matchHeightBasis) {
            drawnH = rectH
            drawnW = rectH * imageAspect
        } else {
            drawnW = rectW
            drawnH = rectW / imageAspect
        }
        return toGlRect(
            rect.left - (drawnW - rectW) / 2.0,
            rect.top - (drawnH - rectH) / 2.0,
            drawnW,
            drawnH,
        )
    }

    /** Lazily compiles the plain 2D-texture shader used to draw a static image background. */
    private fun ensureBackgroundImageProgram() {
        if (backgroundImageProgram != 0) return
        val vertexSrc = """
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            varying vec2 vTextureCoord;
            void main() {
                gl_Position = aPosition;
                // Flip V: glTexImage2D uploads Bitmap row 0 (the image's top
                // row) first, which OpenGL treats as v=0. Without this flip
                // the image would be drawn upside down.
                vTextureCoord = vec2(aTextureCoord.x, 1.0 - aTextureCoord.y);
            }
        """.trimIndent()
        val fragmentSrc = """
            precision mediump float;
            varying vec2 vTextureCoord;
            uniform sampler2D sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, vTextureCoord);
            }
        """.trimIndent()
        val vs = compileShader(GLES20.GL_VERTEX_SHADER, vertexSrc)
        val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        val prog = GLES20.glCreateProgram()
        GLES20.glAttachShader(prog, vs)
        GLES20.glAttachShader(prog, fs)
        GLES20.glLinkProgram(prog)
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(prog)
            GLES20.glDeleteProgram(prog)
            Log.w(TAG, "background image GL program link failed: $log")
            return
        }
        backgroundImageProgram = prog
        bgImageAPositionLoc = GLES20.glGetAttribLocation(prog, "aPosition")
        bgImageATexCoordLoc = GLES20.glGetAttribLocation(prog, "aTextureCoord")
        bgImageSTextureLoc = GLES20.glGetUniformLocation(prog, "sTexture")
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, src)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            throw IllegalStateException("GL shader compile failed: $log")
        }
        return shader
    }

    // -- Rect draws ------------------------------------------------------------

    /**
     * Draws the latched OES frame aspect-filled into [rect]: the viewport is
     * inflated to the video's aspect ratio (centred over the rect) and the
     * scissor crops the overflow back to the rect.
     */
    private fun drawSourceRect(rect: VGDuetPixelRect) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return
        val viewport = if (sourceScaleMode == AndroidDuetLayerScaleMode.ASPECT_FIT) {
            aspectFitViewport(rect)
        } else {
            aspectFillViewport(rect)
        }

        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glViewport(viewport.x, viewport.y, viewport.width, viewport.height)

        GLES20.glUseProgram(oesProgram)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES20.glUniform1i(sTextureLoc, 0)
        GLES20.glUniformMatrix4fv(uSTMatrixLoc, 1, false, stMatrix, 0)

        quadPositions.position(0)
        GLES20.glEnableVertexAttribArray(aPositionLoc)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadPositions)
        quadTexCoords.position(0)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPositionLoc)
        GLES20.glDisableVertexAttribArray(aTexCoordLoc)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    /** Solid fill fallback over the camera rect when no live camera frame has arrived yet. */
    private fun drawCameraPlaceholder(rect: VGDuetPixelRect) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return
        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glClearColor(CAMERA_PLACEHOLDER_R, CAMERA_PLACEHOLDER_G, CAMERA_PLACEHOLDER_B, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    /**
     * Draws the latched camera OES frame into [rect], mirroring the structure
     * of [drawSourceRect] but binding [cameraOesTextureId] and [cameraStMatrix].
     * Reuses the same OES shader program; camera and decoder are independent
     * GL textures and transform matrices.
     *
     * Like [drawSourceRect], the viewport is aspect-filled (via
     * [cameraAspectFillViewport]) and the scissor crops the overflow back to
     * [rect]; camera passthrough and [drawCameraGreenScreen] share this same
     * geometry. [cameraStMatrix] separately supplies the texture-coordinate
     * transform for reading the OES buffer (rotation/crop/mirror baked in by
     * CameraX); it does not perform aspect-fill itself.
     */
    private fun drawCameraRect(rect: VGDuetPixelRect) {
        val scissor = toGlRect(rect.left, rect.top, rect.width, rect.height)
        if (scissor.width <= 0 || scissor.height <= 0) return
        val viewport = if (cameraScaleMode == AndroidDuetLayerScaleMode.ASPECT_FIT) {
            cameraAspectFitViewport(rect)
        } else {
            cameraAspectFillViewport(rect)
        }

        GLES20.glEnable(GLES20.GL_SCISSOR_TEST)
        GLES20.glScissor(scissor.x, scissor.y, scissor.width, scissor.height)
        GLES20.glViewport(viewport.x, viewport.y, viewport.width, viewport.height)

        drawCameraOesQuad()

        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
    }

    /**
     * The camera OES quad draw shared by [drawCameraRect] (preview) and
     * [encodeRecorderFrame] (live take): [oesProgram] sampling
     * [cameraOesTextureId] through [cameraStMatrix] over the full current
     * viewport. Callers own viewport/scissor state; this touches neither.
     */
    private fun drawCameraOesQuad() {
        GLES20.glUseProgram(oesProgram)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraOesTextureId)
        GLES20.glUniform1i(sTextureLoc, 0)
        GLES20.glUniformMatrix4fv(uSTMatrixLoc, 1, false, cameraStMatrix, 0)

        quadPositions.position(0)
        GLES20.glEnableVertexAttribArray(aPositionLoc)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadPositions)
        quadTexCoords.position(0)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPositionLoc)
        GLES20.glDisableVertexAttribArray(aTexCoordLoc)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
    }

    // -- Geometry --------------------------------------------------------------

    private data class GlRect(val x: Int, val y: Int, val width: Int, val height: Int)

    /**
     * Canvas rect (top-left origin, like VGDuetPixelRect) to GLES
     * viewport/scissor rect (bottom-left origin): glY = surfaceH - (top + h).
     */
    private fun toGlRect(left: Double, top: Double, width: Double, height: Double): GlRect {
        val w = width.roundToInt()
        val h = height.roundToInt()
        return GlRect(
            x = left.roundToInt(),
            y = outputHeightPx - (top.roundToInt() + h),
            width = w,
            height = h,
        )
    }

    /**
     * Viewport for an aspect-fill of the source video into [rect]: same centre,
     * inflated along one axis to the video's display aspect ratio. Unknown
     * video size degrades to the rect itself (stretch). For a 90/270-degree
     * [sourceVideoRotationDegrees], the raw decoded width/height are swapped
     * first so the aspect used here matches the upright display orientation
     * rather than the sideways decode buffer.
     */
    private fun aspectFillViewport(rect: VGDuetPixelRect): GlRect {
        val rectW = rect.width
        val rectH = rect.height
        if (sourceVideoWidthPx <= 0 || sourceVideoHeightPx <= 0 || rectW <= 0.0 || rectH <= 0.0) {
            return toGlRect(rect.left, rect.top, rectW, rectH)
        }
        val displayWidthPx: Int
        val displayHeightPx: Int
        if (sourceVideoRotationDegrees == 90 || sourceVideoRotationDegrees == 270) {
            displayWidthPx = sourceVideoHeightPx
            displayHeightPx = sourceVideoWidthPx
        } else {
            displayWidthPx = sourceVideoWidthPx
            displayHeightPx = sourceVideoHeightPx
        }
        val videoAspect = displayWidthPx.toDouble() / displayHeightPx.toDouble()
        val rectAspect = rectW / rectH
        val drawnW: Double
        val drawnH: Double
        if (videoAspect > rectAspect) {
            drawnH = rectH
            drawnW = rectH * videoAspect
        } else {
            drawnW = rectW
            drawnH = rectW / videoAspect
        }
        return toGlRect(
            rect.left - (drawnW - rectW) / 2.0,
            rect.top - (drawnH - rectH) / 2.0,
            drawnW,
            drawnH,
        )
    }

    /**
     * Viewport for an aspect-fill of the upright camera image into [rect]: same
     * centre, inflated along one axis to [CAMERA_UPRIGHT_ASPECT]. Mirrors
     * [aspectFillViewport]'s centred-inflate logic but uses the fixed camera
     * buffer aspect instead of a per-frame decoder video size, since the camera
     * SurfaceTexture's negotiated size is not tracked per-frame the way
     * [sourceVideoWidthPx]/[sourceVideoHeightPx] are for the decoder.
     */
    private fun cameraAspectFillViewport(rect: VGDuetPixelRect): GlRect {
        val aspectRect = cameraAspectFillCanvasRect(rect)
        return toGlRect(aspectRect.left, aspectRect.top, aspectRect.width, aspectRect.height)
    }

    /**
     * Canvas-space (top-left origin, pre-[toGlRect]) counterpart of
     * [cameraAspectFillViewport]: same centred-inflate aspect-fill math, but
     * returned before the GL-viewport y-flip conversion so
     * [drawCameraGreenScreenRotated] can rotate the quad's corners directly in
     * canvas-pixel space (matching [VGDuetForegroundRotation]'s Dart/top-left
     * convention) before converting each rotated corner to NDC individually.
     */
    private fun cameraAspectFillCanvasRect(rect: VGDuetPixelRect): VGDuetPixelRect {
        val rectW = rect.width
        val rectH = rect.height
        if (rectW <= 0.0 || rectH <= 0.0) {
            return rect
        }
        val cameraAspect = CAMERA_UPRIGHT_ASPECT
        val rectAspect = rectW / rectH
        val drawnW: Double
        val drawnH: Double
        if (cameraAspect > rectAspect) {
            drawnH = rectH
            drawnW = rectH * cameraAspect
        } else {
            drawnW = rectW
            drawnH = rectW / cameraAspect
        }
        return VGDuetPixelRect(
            left   = rect.left - (drawnW - rectW) / 2.0,
            top    = rect.top - (drawnH - rectH) / 2.0,
            width  = drawnW,
            height = drawnH,
        )
    }

    private fun aspectFitViewport(rect: VGDuetPixelRect): GlRect {
        val rectW = rect.width
        val rectH = rect.height
        if (sourceVideoWidthPx <= 0 || sourceVideoHeightPx <= 0 || rectW <= 0.0 || rectH <= 0.0) {
            return toGlRect(rect.left, rect.top, rectW, rectH)
        }
        val displayWidthPx: Int
        val displayHeightPx: Int
        if (sourceVideoRotationDegrees == 90 || sourceVideoRotationDegrees == 270) {
            displayWidthPx = sourceVideoHeightPx
            displayHeightPx = sourceVideoWidthPx
        } else {
            displayWidthPx = sourceVideoWidthPx
            displayHeightPx = sourceVideoHeightPx
        }
        val videoAspect = displayWidthPx.toDouble() / displayHeightPx.toDouble()
        val rectAspect = rectW / rectH
        val drawnW: Double
        val drawnH: Double
        if (videoAspect > rectAspect) {
            drawnW = rectW
            drawnH = rectW / videoAspect
        } else {
            drawnH = rectH
            drawnW = rectH * videoAspect
        }
        return toGlRect(
            rect.left + (rectW - drawnW) / 2.0,
            rect.top + (rectH - drawnH) / 2.0,
            drawnW,
            drawnH,
        )
    }

    private fun cameraAspectFitViewport(rect: VGDuetPixelRect): GlRect {
        val aspectRect = cameraAspectFitCanvasRect(rect)
        return toGlRect(aspectRect.left, aspectRect.top, aspectRect.width, aspectRect.height)
    }

    private fun cameraAspectFitCanvasRect(rect: VGDuetPixelRect): VGDuetPixelRect {
        val rectW = rect.width
        val rectH = rect.height
        if (rectW <= 0.0 || rectH <= 0.0) {
            return rect
        }
        val cameraAspect = CAMERA_UPRIGHT_ASPECT
        val rectAspect = rectW / rectH
        val drawnW: Double
        val drawnH: Double
        if (cameraAspect > rectAspect) {
            drawnW = rectW
            drawnH = rectW / cameraAspect
        } else {
            drawnH = rectH
            drawnW = rectH * cameraAspect
        }
        return VGDuetPixelRect(
            left   = rect.left + (rectW - drawnW) / 2.0,
            top    = rect.top + (rectH - drawnH) / 2.0,
            width  = drawnW,
            height = drawnH,
        )
    }

    private fun fullSurfaceRect() =
        VGDuetPixelRect(0.0, 0.0, outputWidthPx.toDouble(), outputHeightPx.toDouble())

    // -- Quiet EGL helpers -----------------------------------------------------

    /** Rebinds [surface] (or nothing) as current, swallowing every EGL error. */
    private fun makeCurrentQuietly(surface: EGLSurface) {
        if (eglDisplay == EGL14.EGL_NO_DISPLAY || eglContext == EGL14.EGL_NO_CONTEXT) return
        try {
            if (surface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglMakeCurrent(eglDisplay, surface, surface, eglContext)
            } else {
                EGL14.eglMakeCurrent(
                    eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
                )
            }
        } catch (_: Throwable) {}
    }

    /**
     * Destroys only the EGL window surface (never the borrowed Surface behind
     * it), falling back to the pbuffer so the context stays current. Tolerates
     * every teardown error; the Android surface may already be dead.
     */
    private fun destroyWindowSurfaceQuietly() {
        val window = eglWindowSurface
        eglWindowSurface = EGL14.EGL_NO_SURFACE
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return
        makeCurrentQuietly(eglPbufferSurface)
        if (window != EGL14.EGL_NO_SURFACE) {
            try { EGL14.eglDestroySurface(eglDisplay, window) } catch (_: Throwable) {}
        }
    }

    /** Partial-bootstrap cleanup for a failed [ensureCore]; a later attach may retry. */
    private fun teardownCoreQuietly() {
        // The segmenter and the recorder surface are only ever created after
        // coreReady, so these are no-ops here in practice; kept so no ordering
        // change can leak them.
        if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglContext != EGL14.EGL_NO_CONTEXT) {
            destroyRecorderSurfaceQuietly()
            makeCurrentQuietly(eglPbufferSurface)
            teardownGpuSegmenterQuietly()
        }
        try { surfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
        try { _decoderInputSurface?.release() } catch (_: Throwable) {}
        _decoderInputSurface = null
        try { surfaceTexture?.release() } catch (_: Throwable) {}
        surfaceTexture = null
        oesTextureId = 0
        oesProgram = 0
        // Camera ingest cleanup.
        try { cameraSurfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
        try { _cameraInputSurface?.release() } catch (_: Throwable) {}
        _cameraInputSurface = null
        try { cameraSurfaceTexture?.release() } catch (_: Throwable) {}
        cameraSurfaceTexture = null
        cameraOesTextureId = 0
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            try {
                EGL14.eglMakeCurrent(
                    eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
                )
            } catch (_: Throwable) {}
            if (eglPbufferSurface != EGL14.EGL_NO_SURFACE) {
                try { EGL14.eglDestroySurface(eglDisplay, eglPbufferSurface) } catch (_: Throwable) {}
            }
            if (eglContext != EGL14.EGL_NO_CONTEXT) {
                try { EGL14.eglDestroyContext(eglDisplay, eglContext) } catch (_: Throwable) {}
            }
            try { EGL14.eglTerminate(eglDisplay) } catch (_: Throwable) {}
        }
        eglPbufferSurface = EGL14.EGL_NO_SURFACE
        eglContext = EGL14.EGL_NO_CONTEXT
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglConfig = null
        coreReady = false
    }

    private fun floatBufferOf(vararg values: Float): FloatBuffer =
        ByteBuffer.allocateDirect(values.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply {
                put(values)
                position(0)
            }
}
