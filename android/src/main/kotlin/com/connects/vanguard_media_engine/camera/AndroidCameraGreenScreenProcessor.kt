package com.connects.vanguard_media_engine.camera

// ── AndroidCameraGreenScreenProcessor ────────────────────────────────────────
//
// F2 (Android livestream green screen): segmentation + background compositing
// for the live camera path, hosted INSIDE AndroidCameraBeautySurfaceProcessor's
// own ES 3.x context on VGCameraGpuThread. No second camera, no second EGL
// context, no standalone green-screen session.
//
// Per frame (all on the GPU thread, context current):
//   1. The embeddable native segmenter (GlesGreenScreenGpuSegmenter through
//      AndroidGreenScreenGpuResidentNativeBridge.nativeSegmenter*) downscales
//      the camera OES frame through the SAME transform matrix the beauty blit
//      used, so its "quad space" is exactly the processed 2D texture's space;
//      TFLite (selfie_segmenter_gpu.tflite, GPU delegate on this context, CPU
//      XNNPACK fallback) produces the coarse mask; native uploads it and
//      guided-filters it against the camera luminance into an R32F alpha
//      texture in quad space.
//   2. A single composite pass keys the post-beauty/color frame over the
//      background into an output texture of the SAME width x height as the
//      input, in the SAME texture space: nothing is rotated, mirrored,
//      stretched or cropped here. CameraX's downstream Preview rotation and
//      AndroidCameraEgressRenderer/AndroidCameraEgressTransform keep owning
//      upright egress rotation/crop/mirror.
//
// Orientation policy: the only orientation-dependent decisions are WHERE the
// background image and the foreground scale/offset are anchored, and those
// are expressed in the upright frame derived from CameraX's
// TransformationInfo.rotationDegrees (passed in per frame), never hardcoded.
// The mapping helpers mirror AndroidCameraEgressTransform's inverse-rotation
// table. Mirroring is only logged (derived from TransformationInfo);
// offsets are interpreted in the unmirrored upright camera frame.
//
// Fail-closed: any init/inference/background/GL failure logs
// ANDROID_LIVESTREAM_GREENSCREEN_BYPASS and returns 0 from composite(); the
// caller then presents the previous beauty/camera output for that frame.
// Failures stick until the requested state changes (no per-frame retry storm).

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.opengl.GLES30
import android.opengl.GLUtils
import android.os.SystemClock
import android.util.Log
import com.connects.vanguard_media_engine.greenscreen.AndroidGreenScreenGpuResidentNativeBridge
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.CompatibilityList
import org.tensorflow.lite.gpu.GpuDelegate
import org.tensorflow.lite.gpu.GpuDelegateFactory
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class AndroidCameraGreenScreenProcessor(
    private val context: Context?,
) {
    companion object {
        private const val TAG = "VGCameraGreenScreen"

        private const val MODEL_ASSET = "selfie_segmenter_gpu.tflite"
        private const val CPU_FALLBACK_THREADS = 4
        private const val MAX_CONSECUTIVE_INFERENCE_FAILURES = 3
        private const val MAX_BACKGROUND_IMAGE_DIMENSION = 2048
        private const val FRAME_LOG_INTERVAL = 300L

        // Same proven toggles as the Duet host compositor's GPU segmenter.
        private const val GUIDED_FILTER_ENABLED = true
        private const val TEMPORAL_STABILIZER_ENABLED = false
        private const val DESPILL_ENABLED = true

        private const val VERTEX_SHADER =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "layout(location = 0) in vec4 aPosition;\n" +
            "layout(location = 1) in vec4 aTexCoord;\n" +
            "out vec2 vTexCoord;\n" +
            "void main() {\n" +
            "    gl_Position = aPosition;\n" +
            "    vTexCoord = aTexCoord.xy;\n" +
            "}\n"

        // Quad space: vTexCoord is the processed texture's UV (v=0 bottom). The
        // alpha texture lives in that same space. Upright mapping only decides
        // where the background and the foreground transform are anchored.
        private const val FRAGMENT_SHADER =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "in vec2 vTexCoord;\n" +
            "out vec4 fragColor;\n" +
            "uniform sampler2D uProcessed;\n" +
            "uniform sampler2D uAlpha;\n" +
            "uniform vec2 uAlphaResolution;\n" +
            "uniform int uRotation;\n" +
            "uniform vec2 uUprightSize;\n" +
            "uniform int uBackgroundMode;\n" + // 0 solid, 1 image
            "uniform vec4 uBackgroundColor;\n" +
            "uniform sampler2D uBackgroundImage;\n" +
            "uniform vec2 uBackgroundImageSize;\n" +
            "uniform int uAspectFill;\n" +
            "uniform float uFgScale;\n" +
            "uniform vec2 uFgOffset;\n" +
            "uniform int uDespill;\n" +
            "\n" +
            "vec2 toUpright(vec2 q) {\n" +
            "    if (uRotation == 90) return vec2(q.y, 1.0 - q.x);\n" +
            "    if (uRotation == 180) return vec2(1.0 - q.x, 1.0 - q.y);\n" +
            "    if (uRotation == 270) return vec2(1.0 - q.y, q.x);\n" +
            "    return q;\n" +
            "}\n" +
            "vec2 fromUpright(vec2 p) {\n" +
            "    if (uRotation == 90) return vec2(1.0 - p.y, p.x);\n" +
            "    if (uRotation == 180) return vec2(1.0 - p.x, 1.0 - p.y);\n" +
            "    if (uRotation == 270) return vec2(p.y, 1.0 - p.x);\n" +
            "    return p;\n" +
            "}\n" +
            "float getLuma(vec3 rgb) { return dot(rgb, vec3(0.299, 0.587, 0.114)); }\n" +
            "float sampleHermiteAlpha(vec2 uv) {\n" +
            "    vec2 res = uAlphaResolution;\n" +
            "    vec2 pos = uv * res - 0.5;\n" +
            "    vec2 f = fract(pos);\n" +
            "    vec2 p = (floor(pos) + 0.5) / res;\n" +
            "    vec2 d = 1.0 / res;\n" +
            "    vec2 s = f * f * (3.0 - 2.0 * f);\n" +
            "    float a00 = texture(uAlpha, p).r;\n" +
            "    float a10 = texture(uAlpha, p + vec2(d.x, 0.0)).r;\n" +
            "    float a01 = texture(uAlpha, p + vec2(0.0, d.y)).r;\n" +
            "    float a11 = texture(uAlpha, p + d).r;\n" +
            "    return mix(mix(a00, a10, s.x), mix(a01, a11, s.x), s.y);\n" +
            "}\n" +
            "vec3 sampleBackground(vec2 p) {\n" +
            "    if (uBackgroundMode == 0) return uBackgroundColor.rgb;\n" +
            "    float frameAspect = uUprightSize.x / uUprightSize.y;\n" +
            "    float imgAspect = uBackgroundImageSize.x / uBackgroundImageSize.y;\n" +
            "    vec2 b = p;\n" +
            "    if (uAspectFill == 1) {\n" +
            "        if (imgAspect > frameAspect) { b.x = 0.5 + (p.x - 0.5) * (frameAspect / imgAspect); }\n" +
            "        else { b.y = 0.5 + (p.y - 0.5) * (imgAspect / frameAspect); }\n" +
            "    } else {\n" +
            "        if (imgAspect > frameAspect) { b.y = 0.5 + (p.y - 0.5) / (frameAspect / imgAspect); }\n" +
            "        else { b.x = 0.5 + (p.x - 0.5) / (imgAspect / frameAspect); }\n" +
            "        if (b.x < 0.0 || b.x > 1.0 || b.y < 0.0 || b.y > 1.0) return vec3(0.0);\n" +
            "    }\n" +
            "    // Bitmap row 0 (top) sits at texture v=0; upright v=1 is the top.\n" +
            "    return texture(uBackgroundImage, vec2(b.x, 1.0 - b.y)).rgb;\n" +
            "}\n" +
            "void main() {\n" +
            "    vec2 up = toUpright(vTexCoord);\n" +
            "    vec3 background = sampleBackground(up);\n" +
            "    vec2 c = (up - 0.5 - uFgOffset) / uFgScale + 0.5;\n" +
            "    if (c.x < 0.0 || c.x > 1.0 || c.y < 0.0 || c.y > 1.0) {\n" +
            "        fragColor = vec4(background, 1.0);\n" +
            "        return;\n" +
            "    }\n" +
            "    vec2 uv = fromUpright(c);\n" +
            "    vec3 cameraColor = texture(uProcessed, uv).rgb;\n" +
            "    float alpha = sampleHermiteAlpha(uv);\n" +
            "    vec2 px = 1.5 / uAlphaResolution;\n" +
            "    float aN = sampleHermiteAlpha(uv + vec2(0.0, px.y));\n" +
            "    float aS = sampleHermiteAlpha(uv - vec2(0.0, px.y));\n" +
            "    float aE = sampleHermiteAlpha(uv + vec2(px.x, 0.0));\n" +
            "    float aW = sampleHermiteAlpha(uv - vec2(px.x, 0.0));\n" +
            "    vec2 dPx = px * 0.7071068;\n" +
            "    float aNE = sampleHermiteAlpha(uv + vec2( dPx.x,  dPx.y));\n" +
            "    float aNW = sampleHermiteAlpha(uv + vec2(-dPx.x,  dPx.y));\n" +
            "    float aSE = sampleHermiteAlpha(uv + vec2( dPx.x, -dPx.y));\n" +
            "    float aSW = sampleHermiteAlpha(uv + vec2(-dPx.x, -dPx.y));\n" +
            "    float isotropicMin = min(min(min(aN, aS), min(aE, aW)), min(min(aNE, aNW), min(aSE, aSW)));\n" +
            "    float boundaryT = smoothstep(0.10, 0.85, alpha);\n" +
            "    float softAlpha = mix(isotropicMin, alpha, boundaryT);\n" +
            "    float compAlpha = smoothstep(0.05, 0.95, softAlpha);\n" +
            "    if (uDespill == 1 && compAlpha > 0.02 && compAlpha < 0.90) {\n" +
            "        vec2 grad = vec2(aE - aW, aN - aS);\n" +
            "        float gradLen = length(grad);\n" +
            "        if (gradLen > 0.001) {\n" +
            "            vec2 inDir = (grad / gradLen) * 3.0 * px;\n" +
            "            float inAlpha = sampleHermiteAlpha(uv + inDir);\n" +
            "            if (inAlpha > 0.70) {\n" +
            "                vec3 inCol = texture(uProcessed, clamp(uv + inDir, 0.0, 1.0)).rgb;\n" +
            "                if (getLuma(cameraColor) > getLuma(inCol) * 1.05) {\n" +
            "                    cameraColor = mix(cameraColor, inCol, (1.0 - compAlpha) * 0.70);\n" +
            "                }\n" +
            "            }\n" +
            "        }\n" +
            "    }\n" +
            "    fragColor = vec4(mix(background, cameraColor, compAlpha), 1.0);\n" +
            "}\n"

        private val ES_VERSION_REGEX = Regex("""OpenGL ES (\d+)\.(\d+)""")
    }

    /** Interpreter + delegate + direct tensor buffers; created on the GPU thread. */
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
    ) {
        fun closeQuietly() {
            try { interpreter.close() } catch (_: Throwable) {}
            try { gpuDelegate?.close() } catch (_: Throwable) {}
        }
    }

    private val bridge = AndroidGreenScreenGpuResidentNativeBridge

    // ── Requested state (any thread) ─────────────────────────────────────────
    @Volatile private var requestedState: CameraGreenScreenState? = null

    /** True when a composite is wanted for the next frame. Any thread. */
    val isRequested: Boolean get() = requestedState?.isActive == true

    /** Any thread. A new state clears a sticky failure so the next frame retries. */
    fun setState(state: CameraGreenScreenState?) {
        requestedState = state
    }

    // ── GPU-thread state ─────────────────────────────────────────────────────
    private var released = false
    private var segmenterHandle = 0L
    private var model: ModelSession? = null
    private var coreReady = false
    private var failedForState: CameraGreenScreenState? = null
    private var glesMajor = 0
    private var glesMinor = 0

    private var program = 0
    private var uProcessedLoc = -1
    private var uAlphaLoc = -1
    private var uAlphaResolutionLoc = -1
    private var uRotationLoc = -1
    private var uUprightSizeLoc = -1
    private var uBackgroundModeLoc = -1
    private var uBackgroundColorLoc = -1
    private var uBackgroundImageLoc = -1
    private var uBackgroundImageSizeLoc = -1
    private var uAspectFillLoc = -1
    private var uFgScaleLoc = -1
    private var uFgOffsetLoc = -1
    private var uDespillLoc = -1

    private var outputTexture = 0
    private var outputFbo = 0
    private var outputWidth = 0
    private var outputHeight = 0

    private var backgroundTexture = 0
    private var backgroundImagePath: String? = null
    private var backgroundImageWidth = 0
    private var backgroundImageHeight = 0

    private var alphaTexture = 0
    private var alphaWidth = 0
    private var alphaHeight = 0
    private var consecutiveInferenceFailures = 0
    private var readyLogged = false
    private var frameCount = 0L
    private val stMatrix = FloatArray(16)

    /**
     * GPU thread, context current. Keys [processedTexture] (post beauty/color,
     * [width] x [height], quad space) over the requested background and
     * returns the output texture (same size, same space), or 0 to bypass —
     * the caller then keeps [processedTexture].
     *
     * [cameraOesTexture] + [cameraStMatrix] are the beauty blit's OES input and
     * transform, so the segmenter's quad space equals the processed texture's.
     * [rotationDegrees] / [mirror] come from CameraX TransformationInfo
     * ([rotationKnown] false before it arrived: rotation 0 is assumed and logged).
     */
    fun composite(
        processedTexture: Int,
        cameraOesTexture: Int,
        cameraStMatrix: FloatArray,
        width: Int,
        height: Int,
        rotationDegrees: Int,
        rotationKnown: Boolean,
        mirror: Boolean,
        quadVao: Int,
    ): Int {
        if (released) return 0
        val state = requestedState ?: return 0
        if (!state.isActive) return 0
        if (failedForState === state) return 0
        if (width <= 0 || height <= 0 || processedTexture == 0 || cameraOesTexture == 0) return 0

        val rotation = if (AndroidCameraEgressTransform.isSupportedRotation(rotationDegrees)) rotationDegrees else 0
        try {
            if (!ensureCore(width, height, state)) return 0
            if (!ensureBackground(state)) return 0
            if (!runSegmentation(cameraOesTexture, cameraStMatrix, width, height, state)) return 0
            if (!drawComposite(processedTexture, width, height, rotation, state, quadVao)) return 0
        } catch (t: Throwable) {
            fail(state, "exception:${t.javaClass.simpleName}:${t.message}")
            return 0
        }

        frameCount++
        if (!readyLogged) {
            readyLogged = true
            Log.i(
                TAG,
                "ANDROID_LIVESTREAM_GREENSCREEN_READY source=${width}x$height output=${outputWidth}x$outputHeight " +
                    "alpha=${alphaWidth}x$alphaHeight rotation=$rotation rotationKnown=$rotationKnown mirror=$mirror " +
                    "gles=$glesMajor.$glesMinor delegate=${model?.delegateLabel} " +
                    "background=${state.backgroundType.wire} scaleMode=${state.scaleMode.wire}",
            )
        }
        if (frameCount == 1L || frameCount % FRAME_LOG_INTERVAL == 0L) {
            Log.i(
                TAG,
                "ANDROID_LIVESTREAM_GREENSCREEN_FRAME source=${width}x$height output=${outputWidth}x$outputHeight " +
                    "active=1 alpha=${alphaWidth}x$alphaHeight rotation=$rotation mirror=$mirror frame=$frameCount",
            )
        }
        return outputTexture
    }

    /** GPU thread, context current. Idempotent; releases every native/GL/TFLite resource. */
    fun release() {
        if (released) return
        released = true
        teardownCore()
        Log.d(TAG, "released")
    }

    // ── Core (segmenter + model + program + output FBO) ──────────────────────

    private fun ensureCore(width: Int, height: Int, state: CameraGreenScreenState): Boolean {
        if (coreReady) {
            if (width != outputWidth || height != outputHeight) {
                if (!createOutputTarget(width, height)) return fail(state, "output_fbo_incomplete")
                bridge.nativeSegmenterSetAlphaTargetSize(segmenterHandle, width, height)
                bridge.nativeSegmenterResetMaskState(segmenterHandle)
                readyLogged = false
                Log.i(TAG, "input size changed → output ${width}x$height, alpha target reset")
            }
            return true
        }
        val ctx = context ?: return fail(state, "no_context")
        if (!parseGlesVersion()) return fail(state, "gl_version_unreadable")
        if (glesMajor < 3 || (glesMajor == 3 && glesMinor < 1)) {
            return fail(state, "gles31_unavailable:$glesMajor.$glesMinor")
        }
        val t0 = SystemClock.elapsedRealtime()
        val handle = bridge.nativeSegmenterCreate()
        if (handle == 0L) return fail(state, "native_segmenter_create_failed")
        segmenterHandle = handle

        val session = try {
            openModelSession(ctx)
        } catch (t: Throwable) {
            teardownCore()
            return fail(state, "model_session_failed:${t.javaClass.simpleName}:${t.message}")
        }
        model = session

        if (!bridge.nativeSegmenterConfigureModelInput(handle, session.inputWidth, session.inputHeight)) {
            val err = bridge.nativeSegmenterLastError(handle)
            teardownCore()
            return fail(state, "model_input_configure_failed:$err")
        }
        bridge.nativeSegmenterSetFilterToggles(handle, GUIDED_FILTER_ENABLED, TEMPORAL_STABILIZER_ENABLED)
        bridge.nativeSegmenterSetAlphaTargetSize(handle, width, height)

        try {
            program = buildProgram(VERTEX_SHADER, FRAGMENT_SHADER)
        } catch (t: Throwable) {
            teardownCore()
            return fail(state, "composite_program_failed:${t.message}")
        }
        uProcessedLoc = GLES30.glGetUniformLocation(program, "uProcessed")
        uAlphaLoc = GLES30.glGetUniformLocation(program, "uAlpha")
        uAlphaResolutionLoc = GLES30.glGetUniformLocation(program, "uAlphaResolution")
        uRotationLoc = GLES30.glGetUniformLocation(program, "uRotation")
        uUprightSizeLoc = GLES30.glGetUniformLocation(program, "uUprightSize")
        uBackgroundModeLoc = GLES30.glGetUniformLocation(program, "uBackgroundMode")
        uBackgroundColorLoc = GLES30.glGetUniformLocation(program, "uBackgroundColor")
        uBackgroundImageLoc = GLES30.glGetUniformLocation(program, "uBackgroundImage")
        uBackgroundImageSizeLoc = GLES30.glGetUniformLocation(program, "uBackgroundImageSize")
        uAspectFillLoc = GLES30.glGetUniformLocation(program, "uAspectFill")
        uFgScaleLoc = GLES30.glGetUniformLocation(program, "uFgScale")
        uFgOffsetLoc = GLES30.glGetUniformLocation(program, "uFgOffset")
        uDespillLoc = GLES30.glGetUniformLocation(program, "uDespill")

        if (!createOutputTarget(width, height)) {
            teardownCore()
            return fail(state, "output_fbo_incomplete")
        }

        coreReady = true
        consecutiveInferenceFailures = 0
        frameCount = 0
        readyLogged = false
        Log.i(
            TAG,
            "core ready: gles=$glesMajor.$glesMinor delegate=${session.delegateLabel} " +
                "modelInput=${session.inputWidth}x${session.inputHeight} mask=${session.maskWidth}x${session.maskHeight} " +
                "initMs=${SystemClock.elapsedRealtime() - t0}",
        )
        return true
    }

    private fun parseGlesVersion(): Boolean {
        val version = try { GLES30.glGetString(GLES30.GL_VERSION) } catch (_: Throwable) { null } ?: return false
        val match = ES_VERSION_REGEX.find(version) ?: return false
        glesMajor = match.groupValues[1].toIntOrNull() ?: 0
        glesMinor = match.groupValues[2].toIntOrNull() ?: 0
        return true
    }

    private fun teardownCore() {
        coreReady = false
        model?.closeQuietly()
        model = null
        if (segmenterHandle != 0L) {
            try { bridge.nativeSegmenterDestroy(segmenterHandle) } catch (_: Throwable) {}
            segmenterHandle = 0L
        }
        alphaTexture = 0
        alphaWidth = 0
        alphaHeight = 0
        if (program != 0) {
            GLES30.glDeleteProgram(program)
            program = 0
        }
        deleteOutputTarget()
        deleteBackgroundTexture()
    }

    private fun fail(state: CameraGreenScreenState, reason: String): Boolean {
        failedForState = state
        Log.w(TAG, "ANDROID_LIVESTREAM_GREENSCREEN_BYPASS reason=$reason")
        return false
    }

    // ── TFLite model session (mirrors the GPU-resident backend's policy) ─────

    private fun openModelSession(ctx: Context): ModelSession {
        val modelBytes = loadModelBytes(ctx)
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
            // The GPU delegate binds to the context current on this thread: ours.
            val gpuDelegate = GpuDelegate(resolved)
            delegate = gpuDelegate
            options.addDelegate(gpuDelegate)
            delegateLabel = "gpu:$source"
        } catch (t: Throwable) {
            Log.w(TAG, "gpu delegate unavailable, using CPU: ${t.javaClass.simpleName}: ${t.message}")
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
            Log.w(TAG, "gpu interpreter failed, using CPU: ${t.javaClass.simpleName}: ${t.message}")
            try { gpuDelegate.close() } catch (_: Throwable) {}
            delegate = null
            delegateLabel = "cpu_xnnpack"
            interpreter = Interpreter(modelBytes, cpuInterpreterOptions())
        }

        try {
            interpreter.allocateTensors()
            check(interpreter.inputTensorCount == 1) { "expected 1 input tensor, got ${interpreter.inputTensorCount}" }
            check(interpreter.outputTensorCount == 1) { "expected 1 output tensor, got ${interpreter.outputTensorCount}" }
            val inputTensor = interpreter.getInputTensor(0)
            val outputTensor = interpreter.getOutputTensor(0)
            check(inputTensor.dataType() == DataType.FLOAT32) { "input dtype must be FLOAT32" }
            check(outputTensor.dataType() == DataType.FLOAT32) { "output dtype must be FLOAT32" }
            val inputShape = inputTensor.shape()
            check(inputShape.size == 4 && inputShape[0] == 1 && inputShape[3] == 3 && inputShape[1] > 0 && inputShape[2] > 0) {
                "input must be NHWC [1,h,w,3], got ${inputShape.toList()}"
            }
            val inputHeight = inputShape[1]
            val inputWidth = inputShape[2]
            val outputShape = outputTensor.shape()
            val maskHeight: Int
            val maskWidth: Int
            when {
                outputShape.size == 4 && outputShape[0] == 1 && outputShape[3] == 1 -> {
                    maskHeight = outputShape[1]; maskWidth = outputShape[2]
                }
                outputShape.size == 3 && outputShape[0] == 1 -> {
                    maskHeight = outputShape[1]; maskWidth = outputShape[2]
                }
                else -> throw IllegalStateException("output must be [1,h,w,1] or [1,h,w], got ${outputShape.toList()}")
            }
            check(maskHeight > 0 && maskWidth > 0) { "output has non-positive dims ${outputShape.toList()}" }
            val inputBytes = inputTensor.numBytes()
            val outputBytes = outputTensor.numBytes()
            check(inputBytes == inputWidth * inputHeight * 3 * 4) { "input numBytes=$inputBytes mismatch" }
            check(outputBytes == maskWidth * maskHeight * 4) { "output numBytes=$outputBytes mismatch" }
            return ModelSession(
                interpreter = interpreter,
                gpuDelegate = delegate,
                inputBuffer = ByteBuffer.allocateDirect(inputBytes).order(ByteOrder.nativeOrder()),
                outputBuffer = ByteBuffer.allocateDirect(outputBytes).order(ByteOrder.nativeOrder()),
                inputWidth = inputWidth,
                inputHeight = inputHeight,
                maskWidth = maskWidth,
                maskHeight = maskHeight,
                delegateLabel = delegateLabel,
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

    private fun loadModelBytes(ctx: Context): ByteBuffer {
        val assets = ctx.applicationContext?.assets ?: ctx.assets
        val raw = assets.open(MODEL_ASSET).use { it.readBytes() }
        check(raw.size >= 8 && raw[4] == 'T'.code.toByte() && raw[5] == 'F'.code.toByte() &&
            raw[6] == 'L'.code.toByte() && raw[7] == '3'.code.toByte()) { "model is not a TFL3 flatbuffer" }
        return ByteBuffer.allocateDirect(raw.size).order(ByteOrder.nativeOrder()).apply {
            put(raw)
            rewind()
        }
    }

    // ── Per-frame segmentation ───────────────────────────────────────────────

    private fun runSegmentation(
        cameraOesTexture: Int,
        cameraStMatrix: FloatArray,
        width: Int,
        height: Int,
        state: CameraGreenScreenState,
    ): Boolean {
        val handle = segmenterHandle
        val session = model ?: return fail(state, "model_missing")
        if (handle == 0L) return fail(state, "segmenter_missing")

        // Quad space == processed texture space: the same matrix the beauty
        // blit applied to this OES frame, and the quad's own pixel aspect
        // (the native side only uses it to size the alpha texture).
        System.arraycopy(cameraStMatrix, 0, stMatrix, 0, 16)
        bridge.nativeSegmenterSetCameraTransform(handle, stMatrix, width.toFloat() / height.toFloat())

        session.inputBuffer.rewind()
        if (!bridge.nativeSegmenterDownscaleCameraToModelInput(handle, cameraOesTexture, session.inputBuffer)) {
            return segmentationFailure(state, "downscale", bridge.nativeSegmenterLastError(handle))
        }
        try {
            session.inputBuffer.rewind()
            session.outputBuffer.rewind()
            session.interpreter.run(session.inputBuffer, session.outputBuffer)
        } catch (t: Throwable) {
            return segmentationFailure(state, "inference", "${t.javaClass.simpleName}: ${t.message}")
        }
        session.outputBuffer.rewind()
        if (!bridge.nativeSegmenterUploadCoarseMask(handle, session.outputBuffer, session.maskWidth, session.maskHeight)) {
            return segmentationFailure(state, "mask_upload", bridge.nativeSegmenterLastError(handle))
        }
        if (!bridge.nativeSegmenterRefineAlpha(handle, cameraOesTexture)) {
            return segmentationFailure(state, "refine", bridge.nativeSegmenterLastError(handle))
        }
        val alpha = bridge.nativeSegmenterRefinedAlphaTextureId(handle)
        if (alpha == 0) return segmentationFailure(state, "alpha_texture_missing", bridge.nativeSegmenterLastError(handle))
        alphaTexture = alpha
        alphaWidth = bridge.nativeSegmenterAlphaWidth(handle)
        alphaHeight = bridge.nativeSegmenterAlphaHeight(handle)
        consecutiveInferenceFailures = 0
        return true
    }

    private fun segmentationFailure(state: CameraGreenScreenState, stage: String, detail: String): Boolean {
        consecutiveInferenceFailures++
        Log.w(TAG, "segmentation $stage failed (${consecutiveInferenceFailures}/$MAX_CONSECUTIVE_INFERENCE_FAILURES): $detail")
        if (consecutiveInferenceFailures >= MAX_CONSECUTIVE_INFERENCE_FAILURES) {
            return fail(state, "segmentation_disabled:$stage")
        }
        return false // this frame bypasses; next frame retries
    }

    // ── Background ───────────────────────────────────────────────────────────

    private fun ensureBackground(state: CameraGreenScreenState): Boolean {
        when (state.backgroundType) {
            CameraGreenScreenState.BackgroundType.SOLID_COLOR -> {
                deleteBackgroundTexture()
                return true
            }
            CameraGreenScreenState.BackgroundType.IMAGE_FILE -> {
                val path = state.imagePath ?: return fail(state, "background_image_path_missing")
                if (backgroundTexture != 0 && backgroundImagePath == path) return true
                deleteBackgroundTexture()
                val bitmap = decodeBoundedBitmap(path) ?: return fail(state, "background_image_unavailable")
                val textures = IntArray(1)
                GLES30.glGenTextures(1, textures, 0)
                val tex = textures[0]
                GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, tex)
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
                GLUtils.texImage2D(GLES30.GL_TEXTURE_2D, 0, bitmap, 0)
                GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
                val err = GLES30.glGetError()
                backgroundImageWidth = bitmap.width
                backgroundImageHeight = bitmap.height
                bitmap.recycle()
                if (err != GLES30.GL_NO_ERROR) {
                    GLES30.glDeleteTextures(1, intArrayOf(tex), 0)
                    return fail(state, "background_image_upload_failed:0x${Integer.toHexString(err)}")
                }
                backgroundTexture = tex
                backgroundImagePath = path
                Log.i(TAG, "background image loaded ${backgroundImageWidth}x$backgroundImageHeight path=$path")
                return true
            }
        }
    }

    private fun decodeBoundedBitmap(path: String): Bitmap? {
        val file = File(path)
        if (!file.isFile) {
            Log.w(TAG, "background image not found: $path")
            return null
        }
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (bounds.outWidth / sample > MAX_BACKGROUND_IMAGE_DIMENSION ||
                bounds.outHeight / sample > MAX_BACKGROUND_IMAGE_DIMENSION
            ) {
                sample *= 2
            }
            val opts = BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            BitmapFactory.decodeFile(path, opts)
        } catch (t: Throwable) {
            Log.w(TAG, "background image decode failed: ${t.javaClass.simpleName}: ${t.message}")
            null
        }
    }

    private fun deleteBackgroundTexture() {
        if (backgroundTexture != 0) {
            GLES30.glDeleteTextures(1, intArrayOf(backgroundTexture), 0)
            backgroundTexture = 0
        }
        backgroundImagePath = null
        backgroundImageWidth = 0
        backgroundImageHeight = 0
    }

    // ── Composite ────────────────────────────────────────────────────────────

    private fun drawComposite(
        processedTexture: Int,
        width: Int,
        height: Int,
        rotation: Int,
        state: CameraGreenScreenState,
        quadVao: Int,
    ): Boolean {
        val upright = AndroidCameraEgressTransform.uprightSize(width, height, rotation)

        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, outputFbo)
        GLES30.glViewport(0, 0, width, height)
        GLES30.glUseProgram(program)

        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, processedTexture)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glUniform1i(uProcessedLoc, 0)

        GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, alphaTexture)
        GLES30.glUniform1i(uAlphaLoc, 1)
        GLES30.glUniform2f(uAlphaResolutionLoc, maxOf(alphaWidth, 1).toFloat(), maxOf(alphaHeight, 1).toFloat())

        GLES30.glUniform1i(uRotationLoc, rotation)
        GLES30.glUniform2f(uUprightSizeLoc, upright[0].toFloat(), upright[1].toFloat())

        val isImage = state.backgroundType == CameraGreenScreenState.BackgroundType.IMAGE_FILE && backgroundTexture != 0
        GLES30.glUniform1i(uBackgroundModeLoc, if (isImage) 1 else 0)
        GLES30.glUniform4f(
            uBackgroundColorLoc,
            ((state.argb ushr 16) and 0xFF) / 255f,
            ((state.argb ushr 8) and 0xFF) / 255f,
            (state.argb and 0xFF) / 255f,
            1f,
        )
        GLES30.glActiveTexture(GLES30.GL_TEXTURE2)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, if (isImage) backgroundTexture else 0)
        GLES30.glUniform1i(uBackgroundImageLoc, 2)
        GLES30.glUniform2f(
            uBackgroundImageSizeLoc,
            maxOf(backgroundImageWidth, 1).toFloat(),
            maxOf(backgroundImageHeight, 1).toFloat(),
        )
        GLES30.glUniform1i(uAspectFillLoc, if (state.scaleMode == CameraGreenScreenState.ScaleMode.ASPECT_FILL) 1 else 0)
        GLES30.glUniform1f(uFgScaleLoc, state.scale)
        // Contract offsets are screen-oriented (+y down); the upright GL frame has +y up.
        GLES30.glUniform2f(uFgOffsetLoc, state.offsetX, -state.offsetY)
        GLES30.glUniform1i(uDespillLoc, if (DESPILL_ENABLED) 1 else 0)

        GLES30.glBindVertexArray(quadVao)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        GLES30.glBindVertexArray(0)

        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

        val err = GLES30.glGetError()
        if (err != GLES30.GL_NO_ERROR) {
            return fail(state, "composite_gl_error:0x${Integer.toHexString(err)}")
        }
        return true
    }

    // ── Output target (same size as the input; NEAREST like finalTexture) ────

    private fun createOutputTarget(width: Int, height: Int): Boolean {
        deleteOutputTarget()
        val textures = IntArray(1)
        GLES30.glGenTextures(1, textures, 0)
        outputTexture = textures[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, outputTexture)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexImage2D(
            GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, width, height, 0,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null,
        )
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)

        val fbos = IntArray(1)
        GLES30.glGenFramebuffers(1, fbos, 0)
        outputFbo = fbos[0]
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, outputFbo)
        GLES30.glFramebufferTexture2D(
            GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, outputTexture, 0,
        )
        val status = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        if (status != GLES30.GL_FRAMEBUFFER_COMPLETE) {
            Log.e(TAG, "output FBO incomplete: $status")
            deleteOutputTarget()
            return false
        }
        outputWidth = width
        outputHeight = height
        return true
    }

    private fun deleteOutputTarget() {
        if (outputFbo != 0) {
            GLES30.glDeleteFramebuffers(1, intArrayOf(outputFbo), 0)
            outputFbo = 0
        }
        if (outputTexture != 0) {
            GLES30.glDeleteTextures(1, intArrayOf(outputTexture), 0)
            outputTexture = 0
        }
        outputWidth = 0
        outputHeight = 0
    }

    // ── Shader helpers ───────────────────────────────────────────────────────

    private fun buildProgram(vertexSrc: String, fragmentSrc: String): Int {
        val vs = compileShader(GLES30.GL_VERTEX_SHADER, vertexSrc)
        val fs = compileShader(GLES30.GL_FRAGMENT_SHADER, fragmentSrc)
        val prog = GLES30.glCreateProgram()
        GLES30.glAttachShader(prog, vs)
        GLES30.glAttachShader(prog, fs)
        GLES30.glLinkProgram(prog)
        val status = IntArray(1)
        GLES30.glGetProgramiv(prog, GLES30.GL_LINK_STATUS, status, 0)
        GLES30.glDeleteShader(vs)
        GLES30.glDeleteShader(fs)
        if (status[0] != GLES30.GL_TRUE) {
            val log = GLES30.glGetProgramInfoLog(prog)
            GLES30.glDeleteProgram(prog)
            throw RuntimeException("green screen program link failed: $log")
        }
        return prog
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, source)
        GLES30.glCompileShader(shader)
        val status = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
        if (status[0] != GLES30.GL_TRUE) {
            val log = GLES30.glGetShaderInfoLog(shader)
            GLES30.glDeleteShader(shader)
            throw RuntimeException("green screen shader compile failed: $log")
        }
        return shader
    }
}
