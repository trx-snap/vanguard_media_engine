package com.connects.vanguard_media_engine.camera

// ── AndroidCameraBeautySurfaceProcessor ──────────────────────────────────────
//
// LIVE-CAMERA-BEAUTY-PARITY: CameraX SurfaceProcessor that intercepts live
// camera frames with a hardware-accelerated OpenGL ES 3.0 filter pipeline.
//
// Pipeline per frame:
//   1. CameraX delivers OES texture via SurfaceTexture on the GPU thread.
//   2. OES is blitted to an intermediate GL_TEXTURE_2D (applying the CameraX
//      transform matrix for orientation/mirroring).
//   3. If intensity > 0: VanguardNativeBridge.drawLiveCameraBeauty() applies
//      the 3-pass bilateral beauty filter (GlesBeautyV2Compositor) to the
//      intermediate texture, rendering into the output surface FBO.
//      If intensity == 0: direct 1:1 passthrough blit from intermediate
//      to output (zero GPU overhead, battery preservation).
//   4. EGL buffer swap to the CameraX output surface(s).
//   5. Optional processed-frame egress, only while attachEgressSurface() has a
//      surface pending or bound (never on the normal path above): the filter
//      stage renders into finalTexture instead of the output FBO, that texture
//      is blitted 1:1 to the output surface (pixel-identical) and swapped, then
//      drawn upright, center-cropped to the egress aspect (720x1280 portrait by
//      default, never stretched) into the egress surface and swapped; the output
//      surface is made current again. Egress failures fail closed: the egress is
//      dropped and the next frame takes the normal path.
//   6. F2 / G1-B: while a green screen and/or overlay state is active the same
//      finalTexture path is taken and the processed frame flows
//      post-beauty/color → green screen → overlay → preview blit + egress, so
//      preview and egress always present the identical composited frame.
//
// Threading: all GL work runs on a dedicated HandlerThread ("VGCameraGpuThread").
// setIntensity() is thread-safe via @Volatile.
//
// Lifecycle: created by VanguardCameraSource on start(), released on stop().
// CameraX owns the SurfaceProcessor lifecycle callbacks (onInputSurface /
// onOutputSurface).

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import androidx.camera.core.SurfaceOutput
import androidx.camera.core.SurfaceProcessor
import androidx.camera.core.SurfaceRequest
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean

class AndroidCameraBeautySurfaceProcessor(
    private val nativeBridge: VanguardNativeBridge,
    // F2: context for AndroidCameraGreenScreenProcessor TFLite asset loading.
    // Null-safe: GS processor will fail-closed with bypass if context is missing.
    private val context: android.content.Context? = null,
) : SurfaceProcessor {

    companion object {
        private const val TAG = "VGCameraBeautyProc"

        // OES→2D blit vertex shader (applies SurfaceTexture transform matrix).
        private const val OES_VERTEX_SHADER =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "layout(location = 0) in vec4 aPosition;\n" +
            "layout(location = 1) in vec4 aTexCoord;\n" +
            "uniform mat4 uTexMatrix;\n" +
            "out vec2 vTexCoord;\n" +
            "void main() {\n" +
            "    gl_Position = aPosition;\n" +
            "    vTexCoord = (uTexMatrix * aTexCoord).xy;\n" +
            "}\n"

        private const val OES_FRAGMENT_SHADER =
            "#version 300 es\n" +
            "#extension GL_OES_EGL_image_external_essl3 : require\n" +
            "precision highp float;\n" +
            "uniform samplerExternalOES uOesTex;\n" +
            "in vec2 vTexCoord;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "    fragColor = texture(uOesTex, vTexCoord);\n" +
            "}\n"

        // Simple 2D→2D passthrough blit (for intensity == 0).
        private const val PASSTHROUGH_VERTEX_SHADER =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "layout(location = 0) in vec4 aPosition;\n" +
            "layout(location = 1) in vec4 aTexCoord;\n" +
            "out vec2 vTexCoord;\n" +
            "void main() {\n" +
            "    gl_Position = aPosition;\n" +
            "    vTexCoord = aTexCoord.xy;\n" +
            "}\n"

        private const val PASSTHROUGH_FRAGMENT_SHADER =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "uniform sampler2D uTex;\n" +
            "in vec2 vTexCoord;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "    fragColor = texture(uTex, vTexCoord);\n" +
            "}\n"

        // CAM-01: 2D ColorMatrix + 2D LUT fragment shader with smooth intensity blending.
        private const val COLOR_FILTER_FRAGMENT_SHADER =
            "#version 300 es\n" +
            "precision highp float;\n" +
            "uniform sampler2D uTex;\n" +
            "uniform int uFilterMode;\n" + // 0 = passthrough, 1 = colorMatrix, 2 = 2D LUT
            "uniform float uIntensity;\n" + // in [0, 1]
            "uniform vec4 uColorMatrixRow0;\n" +
            "uniform vec4 uColorMatrixRow1;\n" +
            "uniform vec4 uColorMatrixRow2;\n" +
            "uniform vec4 uColorMatrixRow3;\n" +
            "uniform vec4 uColorMatrixOffset;\n" +
            "uniform sampler2D uLut2D;\n" +
            "in vec2 vTexCoord;\n" +
            "out vec4 fragColor;\n" +
            "\n" +
            "vec3 sampleLut2D(sampler2D lut, vec3 rgb) {\n" +
            "    float blueColor = rgb.b * 63.0;\n" +
            "    vec2 quad1;\n" +
            "    quad1.y = floor(floor(blueColor) / 8.0);\n" +
            "    quad1.x = floor(blueColor) - (quad1.y * 8.0);\n" +
            "    vec2 quad2;\n" +
            "    quad2.y = floor(ceil(blueColor) / 8.0);\n" +
            "    quad2.x = ceil(blueColor) - (quad2.y * 8.0);\n" +
            "    vec2 texPos1;\n" +
            "    texPos1.x = (quad1.x * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * rgb.r);\n" +
            "    texPos1.y = (quad1.y * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * rgb.g);\n" +
            "    vec2 texPos2;\n" +
            "    texPos2.x = (quad2.x * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * rgb.r);\n" +
            "    texPos2.y = (quad2.y * 0.125) + 0.5/512.0 + ((0.125 - 1.0/512.0) * rgb.g);\n" +
            "    vec3 newColor1 = texture(lut, texPos1).rgb;\n" +
            "    vec3 newColor2 = texture(lut, texPos2).rgb;\n" +
            "    return mix(newColor1, newColor2, fract(blueColor));\n" +
            "}\n" +
            "\n" +
            "void main() {\n" +
            "    vec4 src = texture(uTex, vTexCoord);\n" +
            "    if (uFilterMode == 0 || uIntensity <= 0.0) {\n" +
            "        fragColor = src;\n" +
            "        return;\n" +
            "    }\n" +
            "    vec3 graded = src.rgb;\n" +
            "    if (uFilterMode == 1) {\n" +
            "        vec4 cm = vec4(\n" +
            "            dot(uColorMatrixRow0, src) + uColorMatrixOffset.r,\n" +
            "            dot(uColorMatrixRow1, src) + uColorMatrixOffset.g,\n" +
            "            dot(uColorMatrixRow2, src) + uColorMatrixOffset.b,\n" +
            "            dot(uColorMatrixRow3, src) + uColorMatrixOffset.a\n" +
            "        );\n" +
            "        graded = clamp(cm.rgb, 0.0, 1.0);\n" +
            "    } else if (uFilterMode == 2) {\n" +
            "        graded = sampleLut2D(uLut2D, clamp(src.rgb, 0.0, 1.0));\n" +
            "    }\n" +
            "    fragColor = vec4(mix(src.rgb, graded, uIntensity), src.a);\n" +
            "}\n"

        // Full-screen quad (triangle strip) with texcoords.
        private val FULLSCREEN_QUAD = floatArrayOf(
            // x, y, u, v
            -1f, -1f, 0f, 0f,
             1f, -1f, 1f, 0f,
            -1f,  1f, 0f, 1f,
             1f,  1f, 1f, 1f,
        )
    }

    // ── Thread-safe filter controls ───────────────────────────────────────────
    @Volatile var intensity: Float = 0f
    @Volatile var colorFilterState: CameraColorFilterState? = null
    // F2: green-screen state. Volatile so the main-thread coordinator write is
    // visible to the GPU thread on the next frame.
    @Volatile var greenScreenState: CameraGreenScreenState? = null
    // G1-B: livestream overlay state (text/sticker items). Same visibility policy.
    @Volatile var overlayState: CameraOverlayState? = null

    fun setColorFilter(state: CameraColorFilterState?) {
        colorFilterState = state
        Log.d(TAG, "setColorFilter: mode=${state?.mode}, intensity=${state?.intensity}")
    }

    // F2: called from VanguardCameraSource on the main thread.
    fun setGreenScreen(state: CameraGreenScreenState?) {
        greenScreenState = state
        Log.d(TAG, "setGreenScreen: enabled=${state?.enabled} type=${state?.backgroundType}")
    }

    // G1-B: called from VanguardCameraSource on the main thread. The full item
    // list is replaced wholesale; null or an inactive state clears every overlay.
    fun setOverlay(state: CameraOverlayState?) {
        overlayState = state
        Log.d(TAG, "setOverlay: active=${state?.isActive == true} items=${state?.items?.size ?: 0}")
    }

    // ── GPU thread ───────────────────────────────────────────────────────────
    private val gpuThread = HandlerThread("VGCameraGpuThread").also { it.start() }
    private val gpuHandler = Handler(gpuThread.looper)
    private val released = AtomicBoolean(false)
    // F2: green-screen processor (GPU thread only; created lazily, released in release()).
    private var greenScreenProcessor: AndroidCameraGreenScreenProcessor? = null
    // G1-B: overlay compositor (GPU thread only; created lazily, released when
    // the overlay state clears and in release()).
    private var overlayProcessor: AndroidCameraOverlayProcessor? = null

    // ── EGL state (GPU thread only) ──────────────────────────────────────────
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglConfig: EGLConfig? = null
    private var pbufferSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    // ── GL resources (GPU thread only) ───────────────────────────────────────
    private var oesTexture: Int = 0
    private var surfaceTexture: SurfaceTexture? = null
    private var inputSurface: Surface? = null

    private var intermediateTexture: Int = 0
    private var intermediateFbo: Int = 0

    // Two-pass FBO for combining Beauty + ColorFilter
    private var beautyIntermediateTexture: Int = 0
    private var beautyIntermediateFbo: Int = 0

    private var oesProgram: Int = 0
    private var passthroughProgram: Int = 0
    private var colorFilterProgram: Int = 0

    // Uniform locations for colorFilterProgram
    private var uColorTexLoc: Int = 0
    private var uColorFilterModeLoc: Int = 0
    private var uColorIntensityLoc: Int = 0
    private var uColorMatrixRow0Loc: Int = 0
    private var uColorMatrixRow1Loc: Int = 0
    private var uColorMatrixRow2Loc: Int = 0
    private var uColorMatrixRow3Loc: Int = 0
    private var uColorMatrixOffsetLoc: Int = 0
    private var uColorLut2DLoc: Int = 0
    private var lutTextureId: Int = 0

    private var quadVao: Int = 0
    private var quadVbo: Int = 0

    private var frameWidth: Int = 0
    private var frameHeight: Int = 0

    // ── Output surface state (GPU thread only) ───────────────────────────────
    private var outputSurface: Surface? = null
    private var outputEglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var outputSurfaceOutput: SurfaceOutput? = null

    // ── Optional processed-frame egress (GPU thread only) ────────────────────
    // A second window surface that receives the processed frame, independent
    // of the CameraX output surface above. Attach/detach requests are posted
    // to the GPU thread; pendingEgress survives until EGL is ready or detach.
    private data class EgressRequest(
        val surface: Surface,
        val width: Int,
        val height: Int,
        val mirror: Boolean,
    )

    private var pendingEgress: EgressRequest? = null
    private var egressRenderer: AndroidCameraEgressRenderer? = null
    private var egressProgram: Int = 0
    private var egressWaitLogged: Boolean = false

    // Final processed frame (post beauty/color) so preview and egress read the
    // same pixels. Rendered into only while an egress surface is pending or
    // bound; the normal preview path never touches these.
    private var finalTexture: Int = 0
    private var finalFbo: Int = 0

    // Rotation that makes the camera input upright, as reported by CameraX for
    // the current input request. Egress only; preview orientation stays
    // CameraX's job downstream of this processor.
    private var inputRotationDegrees: Int = 0
    private var inputMirroring: Boolean = false
    private var transformationInfoReceived: Boolean = false

    // Transform matrices: raw from SurfaceTexture, final after CameraX output transform.
    // Kept distinct because Matrix.multiplyMM inside updateTransformMatrix forbids buffer overlap.
    private val rawTexMatrix = FloatArray(16)
    private val finalTexMatrix = FloatArray(16)

    // ── SurfaceProcessor callbacks ───────────────────────────────────────────

    override fun onInputSurface(request: SurfaceRequest) {
        if (released.get()) return

        gpuHandler.post {
            try {
                val size = request.resolution
                frameWidth = size.width
                frameHeight = size.height
                Log.d(TAG, "onInputSurface: ${frameWidth}×${frameHeight}")

                // Egress orientation: CameraX reports the rotation that makes
                // this input upright. Only the optional egress path uses it.
                transformationInfoReceived = false
                inputRotationDegrees = 0
                request.setTransformationInfoListener({ cmd -> gpuHandler.post(cmd) }) { info ->
                    inputRotationDegrees = info.rotationDegrees
                    inputMirroring = info.isMirroring
                    transformationInfoReceived = true
                    egressWaitLogged = false
                    Log.d(
                        TAG,
                        "TransformationInfo: rotation=${info.rotationDegrees} crop=${info.cropRect} " +
                            "mirroring=${info.isMirroring} hasCameraTransform=${info.hasCameraTransform()}",
                    )
                }

                // Initialize EGL + GL resources on first input.
                if (eglDisplay == EGL14.EGL_NO_DISPLAY) {
                    initEgl()
                    initGlResources()
                }

                // Recreate intermediate FBO for new resolution.
                recreateIntermediateFbo(frameWidth, frameHeight)

                // EGL is ready now: bind an egress surface attached before this point.
                bindPendingEgressIfNeeded()

                // Create OES texture + SurfaceTexture for camera input.
                if (oesTexture == 0) {
                    oesTexture = createOesTexture()
                }
                surfaceTexture?.release()
                surfaceTexture = SurfaceTexture(oesTexture).apply {
                    setDefaultBufferSize(frameWidth, frameHeight)
                    setOnFrameAvailableListener({ onFrameAvailable() }, gpuHandler)
                }

                inputSurface?.release()
                inputSurface = Surface(surfaceTexture)

                // Provide the surface to CameraX.
                request.provideSurface(inputSurface!!, { cmd -> gpuHandler.post(cmd) }) { result ->
                    Log.d(TAG, "Input surface released by CameraX (code=${result.resultCode})")
                }
            } catch (e: Exception) {
                Log.e(TAG, "onInputSurface failed: ${e.message}", e)
            }
        }
    }

    override fun onOutputSurface(output: SurfaceOutput) {
        if (released.get()) return

        gpuHandler.post {
            try {
                // Release previous output surface.
                releaseOutputSurface()

                outputSurfaceOutput = output
                outputSurface = output.getSurface({ cmd -> gpuHandler.post(cmd) }) {
                    Log.d(TAG, "Output surface event received")
                }

                // Create EGL window surface for the output.
                if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglConfig != null) {
                    outputEglSurface = EGL14.eglCreateWindowSurface(
                        eglDisplay, eglConfig, outputSurface, intArrayOf(EGL14.EGL_NONE), 0
                    )
                    if (outputEglSurface == EGL14.EGL_NO_SURFACE) {
                        Log.e(TAG, "Failed to create output EGL surface")
                    }
                }

                Log.d(TAG, "onOutputSurface: output surface bound")
            } catch (e: Exception) {
                Log.e(TAG, "onOutputSurface failed: ${e.message}", e)
            }
        }
    }

    // ── Optional processed-frame egress surface ──────────────────────────────

    /**
     * Attaches a second [surface] that receives the already-processed frame,
     * drawn upright and center-cropped/scaled to [width]x[height] (720x1280
     * portrait by default, never stretched). [mirror] flips horizontally in
     * viewer space (front camera).
     *
     * Only argument validation runs on the caller thread; all EGL/GL work is
     * posted to the GPU thread. If EGL is not initialized yet the request is
     * kept pending and bound once the first camera input arrives. Returns false
     * only when the request is rejected up-front (processor released or invalid
     * arguments); true means it was queued. A later EGL failure drops the egress
     * and leaves the preview unaffected.
     *
     * The caller keeps ownership of [surface]; it is never released here.
     */
    fun attachEgressSurface(
        surface: Surface,
        width: Int = AndroidCameraEgressTransform.DEFAULT_OUTPUT_WIDTH,
        height: Int = AndroidCameraEgressTransform.DEFAULT_OUTPUT_HEIGHT,
        mirror: Boolean = false,
    ): Boolean {
        if (released.get()) {
            Log.w(TAG, "attachEgressSurface ignored: processor released")
            return false
        }
        if (width <= 0 || height <= 0) {
            Log.w(TAG, "attachEgressSurface rejected: invalid size ${width}×${height}")
            return false
        }
        if (!surface.isValid) {
            Log.w(TAG, "attachEgressSurface rejected: surface is not valid")
            return false
        }
        gpuHandler.post {
            if (released.get()) return@post
            releaseEgressRenderer()
            pendingEgress = EgressRequest(surface, width, height, mirror)
            egressWaitLogged = false
            if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                bindPendingEgressIfNeeded()
            } else {
                Log.d(TAG, "attachEgressSurface: EGL not initialized yet, binding deferred")
            }
        }
        return true
    }

    /** Detaches the egress surface, if any. Safe to call at any time; idempotent. */
    fun detachEgressSurface() {
        gpuHandler.post {
            pendingEgress = null
            releaseEgressRenderer()
        }
    }

    // GPU thread only.
    private fun bindPendingEgressIfNeeded() {
        val request = pendingEgress ?: return
        val existing = egressRenderer
        if (existing != null && existing.isBound) return
        val config = eglConfig
        if (eglDisplay == EGL14.EGL_NO_DISPLAY || config == null || eglContext == EGL14.EGL_NO_CONTEXT) return
        val renderer = existing
            ?: AndroidCameraEgressRenderer(eglDisplay, config, eglContext).also { egressRenderer = it }
        if (!renderer.bind(request.surface, request.width, request.height, request.mirror)) {
            Log.e(TAG, "Egress surface creation failed; egress dropped, preview unaffected")
            pendingEgress = null
            egressRenderer = null
        }
    }

    // GPU thread only. Never destroys a surface while it is current.
    private fun releaseEgressRenderer() {
        val renderer = egressRenderer ?: return
        if (renderer.isBound && eglDisplay != EGL14.EGL_NO_DISPLAY && eglContext != EGL14.EGL_NO_CONTEXT) {
            val fallback = if (outputEglSurface != EGL14.EGL_NO_SURFACE) outputEglSurface else pbufferSurface
            if (fallback != EGL14.EGL_NO_SURFACE) {
                EGL14.eglMakeCurrent(eglDisplay, fallback, fallback, eglContext)
            }
        }
        renderer.release()
        egressRenderer = null
    }

    // GPU thread only. Fail-closed guard for the egress-active frame path: if
    // the shared final FBO cannot be created, the egress is dropped and this
    // frame (and later ones) take the normal preview path.
    private fun ensureFinalTextureFboOrDropEgress(): Boolean {
        if (ensureFinalTextureFbo()) return true
        Log.e(TAG, "Egress dropped: final FBO unavailable, preview unaffected")
        pendingEgress = null
        releaseEgressRenderer()
        return false
    }

    // GPU thread only. Runs after the preview swap; always leaves
    // outputEglSurface current on return.
    private fun renderEgressIfAttached(processedTexture: Int) {
        if (pendingEgress == null) {
            if (egressRenderer != null) releaseEgressRenderer()
            return
        }
        if (egressRenderer?.isBound != true) bindPendingEgressIfNeeded()
        val renderer = egressRenderer ?: return
        if (!renderer.isBound) return
        if (!transformationInfoReceived) {
            if (!egressWaitLogged) {
                Log.d(TAG, "egress: waiting for CameraX transformation info")
                egressWaitLogged = true
            }
            return
        }
        val rotation =
            if (AndroidCameraEgressTransform.isSupportedRotation(inputRotationDegrees)) inputRotationDegrees else 0
        val ok = try {
            renderer.draw(
                egressProgram, quadVao, processedTexture, frameWidth, frameHeight, rotation,
                surfaceTexture?.timestamp ?: 0L,
            )
        } catch (e: Exception) {
            Log.e(TAG, "Egress draw threw: ${e.message}", e)
            false
        }
        EGL14.eglMakeCurrent(eglDisplay, outputEglSurface, outputEglSurface, eglContext)
        if (!ok) {
            Log.e(TAG, "Egress render failed; egress dropped, preview unaffected")
            pendingEgress = null
            releaseEgressRenderer()
        }
    }

    // ── Per-frame processing ─────────────────────────────────────────────────

    private fun onFrameAvailable() {
        if (released.get()) return
        if (outputEglSurface == EGL14.EGL_NO_SURFACE) return

        try {
            // Make our context current on the output surface.
            EGL14.eglMakeCurrent(eglDisplay, outputEglSurface, outputEglSurface, eglContext)

            // Update OES texture with the latest camera frame.
            surfaceTexture?.updateTexImage()
            surfaceTexture?.getTransformMatrix(rawTexMatrix)

            // Update output transform matrix from CameraX using non-overlapping buffers.
            val outputOut = outputSurfaceOutput
            if (outputOut != null) {
                outputOut.updateTransformMatrix(finalTexMatrix, rawTexMatrix)
            } else {
                System.arraycopy(rawTexMatrix, 0, finalTexMatrix, 0, 16)
            }

            // Step 1: Blit OES → intermediate GL_TEXTURE_2D (applying transform).
            blitOesToIntermediate()

            // Step 2: Apply beauty filter and/or color filter (CAM-01 4-state pipeline).
            val currentIntensity = intensity
            val activeColorFilter = colorFilterState
            val hasBeauty = currentIntensity > 0f
            val hasColorFilter = activeColorFilter != null &&
                activeColorFilter.mode != CameraColorFilterState.FilterMode.PASSTHROUGH &&
                activeColorFilter.intensity > 0f

            // F2: green-screen state snapshot (volatile read, once per frame).
            val activeGreenScreen = greenScreenState?.takeIf { it.enabled }
            val hasGreenScreen = activeGreenScreen != null

            // G1-B: overlay state snapshot (volatile read, once per frame).
            val activeOverlay = overlayState?.takeIf { it.isActive }
            val hasOverlay = activeOverlay != null

            // The egress path (and the green-screen / overlay paths) require finalFbo
            // so that the preview blit and the egress / GS / overlay passes share one
            // processed frame.
            val needsFinalFbo = pendingEgress != null || hasGreenScreen || hasOverlay
            val egressActive = needsFinalFbo && ensureFinalTextureFboOrDropEgress()

            if (!egressActive) {
                // Normal (no egress, no green screen, no overlay) path — direct to FBO 0.
                // Overlay processor cannot be active here; release it if state was cleared.
                if (!hasOverlay && overlayProcessor != null) {
                    overlayProcessor?.release()
                    overlayProcessor = null
                }
                when {
                    hasBeauty && hasColorFilter -> {
                        // Two-pass pipeline: Beauty into beautyIntermediateFbo, then Color filter to output.
                        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, beautyIntermediateFbo)
                        GLES30.glViewport(0, 0, frameWidth, frameHeight)
                        val ok = nativeBridge.drawLiveCameraBeauty(
                            intermediateTexture, beautyIntermediateFbo, frameWidth, frameHeight, currentIntensity
                        )
                        val colorInputTex = if (ok) beautyIntermediateTexture else intermediateTexture
                        blitColorFilter(colorInputTex, 0)
                    }
                    hasBeauty && !hasColorFilter -> {
                        // Single-pass: Beauty directly to default framebuffer (FBO 0).
                        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
                        GLES30.glViewport(0, 0, frameWidth, frameHeight)
                        val ok = nativeBridge.drawLiveCameraBeauty(
                            intermediateTexture, 0, frameWidth, frameHeight, currentIntensity
                        )
                        if (!ok) {
                            blitIntermediateToOutput()
                        }
                    }
                    !hasBeauty && hasColorFilter -> {
                        // Single-pass: Color filter directly to default framebuffer (FBO 0).
                        blitColorFilter(intermediateTexture, 0)
                    }
                    else -> {
                        // Passthrough: No filters active (zero filter GPU overhead).
                        blitIntermediateToOutput()
                    }
                }

                // Swap buffers to present the frame.
                EGL14.eglSwapBuffers(eglDisplay, outputEglSurface)
            } else {
                // Egress, green-screen or overlay active: render the filter stage into
                // finalTexture so the preview blit and the egress / GS / overlay passes
                // share one processed frame.
                // processedTexture is whichever texture holds the post-beauty/color frame.
                val postBeautyColorTexture: Int = when {
                    hasBeauty && hasColorFilter -> {
                        // Two-pass pipeline: Beauty into beautyIntermediateFbo, then Color filter into finalFbo.
                        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, beautyIntermediateFbo)
                        GLES30.glViewport(0, 0, frameWidth, frameHeight)
                        val ok = nativeBridge.drawLiveCameraBeauty(
                            intermediateTexture, beautyIntermediateFbo, frameWidth, frameHeight, currentIntensity
                        )
                        val colorInputTex = if (ok) beautyIntermediateTexture else intermediateTexture
                        blitColorFilter(colorInputTex, finalFbo)
                        finalTexture
                    }
                    hasBeauty && !hasColorFilter -> {
                        // Single-pass: Beauty into finalFbo (unprocessed frame on failure, as before).
                        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, finalFbo)
                        GLES30.glViewport(0, 0, frameWidth, frameHeight)
                        val ok = nativeBridge.drawLiveCameraBeauty(
                            intermediateTexture, finalFbo, frameWidth, frameHeight, currentIntensity
                        )
                        if (ok) finalTexture else intermediateTexture
                    }
                    !hasBeauty && hasColorFilter -> {
                        // Single-pass: Color filter into finalFbo.
                        blitColorFilter(intermediateTexture, finalFbo)
                        finalTexture
                    }
                    else -> {
                        // Passthrough: No filters active.
                        intermediateTexture
                    }
                }

                // Step 3 (F2): Green-screen compositing, if active.
                // Processing order: camera 720p → beauty → green screen → overlay → preview/egress.
                // The GS processor runs segmentation + composite in its own internal output FBO.
                // Returns: output texture id (same dims as input, quad space) or 0 to bypass.
                val postGreenScreenTexture: Int = if (hasGreenScreen && activeGreenScreen != null) {
                    // Lazy-create processor; pass context for TFLite asset loading.
                    val gsp = greenScreenProcessor ?: AndroidCameraGreenScreenProcessor(context).also {
                        greenScreenProcessor = it
                    }
                    // Deliver current state (setState clears sticky failure on state change).
                    gsp.setState(activeGreenScreen)
                    // rotation/mirror derived from CameraX TransformationInfo (never
                    // hardcoded); the egress path keeps its own mirror policy.
                    val rotation = if (transformationInfoReceived) inputRotationDegrees else 0
                    val mirror = inputMirroring
                    // composite() returns output texture id or 0 (bypass fail-closed).
                    val gsOut = gsp.composite(
                        processedTexture = postBeautyColorTexture,
                        cameraOesTexture = oesTexture,
                        cameraStMatrix = finalTexMatrix,
                        width = frameWidth,
                        height = frameHeight,
                        rotationDegrees = rotation,
                        rotationKnown = transformationInfoReceived,
                        mirror = mirror,
                        quadVao = quadVao,
                    )
                    // 0 = bypass: the green-screen processor already logged the
                    // (sticky) reason once; keep presenting the beauty/color frame.
                    if (gsOut != 0) gsOut else postBeautyColorTexture
                } else {
                    // Green screen not active this frame.
                    if (!hasGreenScreen) {
                        // Release processor if state was cleared.
                        greenScreenProcessor?.release()
                        greenScreenProcessor = null
                    }
                    postBeautyColorTexture
                }

                // Step 4 (G1-B): Overlay compositing, if active — after green screen,
                // before the preview/egress fan-out so both see the same overlaid frame.
                // The overlay processor blends into its own output FBO (same dims,
                // quad space). Returns output texture id or 0 to bypass.
                val postOverlayTexture: Int = if (activeOverlay != null) {
                    val op = overlayProcessor ?: AndroidCameraOverlayProcessor().also {
                        overlayProcessor = it
                    }
                    // A new state instance triggers the one-time item rebuild and
                    // clears any sticky failure for the previous state.
                    op.setState(activeOverlay)
                    val rotation = if (transformationInfoReceived) inputRotationDegrees else 0
                    val overlayOut = op.composite(
                        processedTexture = postGreenScreenTexture,
                        width = frameWidth,
                        height = frameHeight,
                        rotationDegrees = rotation,
                        rotationKnown = transformationInfoReceived,
                        mirror = inputMirroring,
                        quadVao = quadVao,
                    )
                    // 0 = bypass: the overlay processor already logged the reason;
                    // keep presenting the current processed frame.
                    if (overlayOut != 0) overlayOut else postGreenScreenTexture
                } else {
                    // Overlay not active this frame: release the compositor if the
                    // state was cleared (item textures, programs, output FBO).
                    if (!hasOverlay && overlayProcessor != null) {
                        overlayProcessor?.release()
                        overlayProcessor = null
                    }
                    postGreenScreenTexture
                }

                // Present the processed frame on the CameraX output surface
                // (1:1 nearest blit) and swap.
                blitTextureToOutput(postOverlayTexture)
                EGL14.eglSwapBuffers(eglDisplay, outputEglSurface)

                // Egress pass; always restores outputEglSurface as current.
                renderEgressIfAttached(postOverlayTexture)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Frame processing failed: ${e.message}", e)
        }
    }


    // ── OES → Intermediate 2D blit ──────────────────────────────────────────

    private fun blitOesToIntermediate() {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, intermediateFbo)
        GLES30.glViewport(0, 0, frameWidth, frameHeight)

        GLES30.glUseProgram(oesProgram)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexture)

        val texMatrixLoc = GLES30.glGetUniformLocation(oesProgram, "uTexMatrix")
        GLES30.glUniformMatrix4fv(texMatrixLoc, 1, false, finalTexMatrix, 0)

        val texLoc = GLES30.glGetUniformLocation(oesProgram, "uOesTex")
        GLES30.glUniform1i(texLoc, 0)

        GLES30.glBindVertexArray(quadVao)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        GLES30.glBindVertexArray(0)

        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
    }

    // ── CAM-01: Color filter blit (ColorMatrix or 2D LUT) ────────────────────

    private fun blitColorFilter(inputTex: Int, targetFbo: Int = 0) {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, targetFbo)
        GLES30.glViewport(0, 0, frameWidth, frameHeight)

        GLES30.glUseProgram(colorFilterProgram)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, inputTex)
        GLES30.glUniform1i(uColorTexLoc, 0)

        val filter = colorFilterState
        if (filter == null || filter.mode == CameraColorFilterState.FilterMode.PASSTHROUGH || filter.intensity <= 0f) {
            GLES30.glUniform1i(uColorFilterModeLoc, 0)
            GLES30.glUniform1f(uColorIntensityLoc, 0f)
        } else when (filter.mode) {
            CameraColorFilterState.FilterMode.COLOR_MATRIX -> {
                GLES30.glUniform1i(uColorFilterModeLoc, 1)
                GLES30.glUniform1f(uColorIntensityLoc, filter.intensity)
                val matrix = filter.matrix ?: CameraColorFilterState.IDENTITY_MATRIX
                GLES30.glUniform4f(uColorMatrixRow0Loc, matrix[0], matrix[1], matrix[2], matrix[3])
                GLES30.glUniform4f(uColorMatrixRow1Loc, matrix[5], matrix[6], matrix[7], matrix[8])
                GLES30.glUniform4f(uColorMatrixRow2Loc, matrix[10], matrix[11], matrix[12], matrix[13])
                GLES30.glUniform4f(uColorMatrixRow3Loc, matrix[15], matrix[16], matrix[17], matrix[18])
                GLES30.glUniform4f(
                    uColorMatrixOffsetLoc,
                    matrix[4] / 255.0f,
                    matrix[9] / 255.0f,
                    matrix[14] / 255.0f,
                    matrix[19] / 255.0f,
                )
            }
            CameraColorFilterState.FilterMode.LUT_2D -> {
                GLES30.glUniform1i(uColorFilterModeLoc, 2)
                GLES30.glUniform1f(uColorIntensityLoc, filter.intensity)
                if (lutTextureId != 0) {
                    GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
                    GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, lutTextureId)
                    GLES30.glUniform1i(uColorLut2DLoc, 1)
                }
            }
            else -> {
                GLES30.glUniform1i(uColorFilterModeLoc, 0)
                GLES30.glUniform1f(uColorIntensityLoc, 0f)
            }
        }

        GLES30.glBindVertexArray(quadVao)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        GLES30.glBindVertexArray(0)

        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
    }

    // ── Intermediate 2D → Output passthrough blit ────────────────────────────

    private fun blitIntermediateToOutput() {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        GLES30.glViewport(0, 0, frameWidth, frameHeight)

        GLES30.glUseProgram(passthroughProgram)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, intermediateTexture)

        val texLoc = GLES30.glGetUniformLocation(passthroughProgram, "uTex")
        GLES30.glUniform1i(texLoc, 0)

        GLES30.glBindVertexArray(quadVao)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        GLES30.glBindVertexArray(0)

        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
    }

    // ── Processed 2D texture → Output blit (egress-active path only) ─────────

    private fun blitTextureToOutput(srcTexture: Int) {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        GLES30.glViewport(0, 0, frameWidth, frameHeight)

        GLES30.glUseProgram(passthroughProgram)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, srcTexture)
        // 1:1 nearest sampling keeps this blit pixel-identical to rendering
        // straight into the output surface (the egress pass switches the same
        // texture to linear for its downscale, so reset it every frame).
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST)

        val texLoc = GLES30.glGetUniformLocation(passthroughProgram, "uTex")
        GLES30.glUniform1i(texLoc, 0)

        GLES30.glBindVertexArray(quadVao)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        GLES30.glBindVertexArray(0)

        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
    }

    // ── EGL initialization ───────────────────────────────────────────────────

    private fun initEgl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) throw RuntimeException("eglGetDisplay failed")

        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            throw RuntimeException("eglInitialize failed")
        }

        val configAttribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0)
        if (numConfigs[0] == 0) throw RuntimeException("eglChooseConfig found no ES3 config")
        eglConfig = configs[0]!!

        val contextAttribs = intArrayOf(
            EGL14.EGL_CONTEXT_CLIENT_VERSION, 3,
            EGL14.EGL_NONE,
        )
        eglContext = EGL14.eglCreateContext(eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) throw RuntimeException("eglCreateContext failed")

        // Create a small pbuffer surface for context activation during initial setup.
        val pbufferAttribs = intArrayOf(
            EGL14.EGL_WIDTH, 1,
            EGL14.EGL_HEIGHT, 1,
            EGL14.EGL_NONE,
        )
        pbufferSurface = EGL14.eglCreatePbufferSurface(eglDisplay, eglConfig, pbufferAttribs, 0)
        EGL14.eglMakeCurrent(eglDisplay, pbufferSurface, pbufferSurface, eglContext)

        Log.d(TAG, "EGL initialized (ES 3.0)")
    }

    // ── GL resource setup ────────────────────────────────────────────────────

    private fun initGlResources() {
        // Compile shaders.
        oesProgram = buildProgram(OES_VERTEX_SHADER, OES_FRAGMENT_SHADER)
        passthroughProgram = buildProgram(PASSTHROUGH_VERTEX_SHADER, PASSTHROUGH_FRAGMENT_SHADER)
        colorFilterProgram = buildProgram(PASSTHROUGH_VERTEX_SHADER, COLOR_FILTER_FRAGMENT_SHADER)
        // Egress blit: uTexMatrix vertex (rotate/crop/mirror) over a 2D sampler.
        egressProgram = buildProgram(OES_VERTEX_SHADER, PASSTHROUGH_FRAGMENT_SHADER)

        uColorTexLoc = GLES30.glGetUniformLocation(colorFilterProgram, "uTex")
        uColorFilterModeLoc = GLES30.glGetUniformLocation(colorFilterProgram, "uFilterMode")
        uColorIntensityLoc = GLES30.glGetUniformLocation(colorFilterProgram, "uIntensity")
        uColorMatrixRow0Loc = GLES30.glGetUniformLocation(colorFilterProgram, "uColorMatrixRow0")
        uColorMatrixRow1Loc = GLES30.glGetUniformLocation(colorFilterProgram, "uColorMatrixRow1")
        uColorMatrixRow2Loc = GLES30.glGetUniformLocation(colorFilterProgram, "uColorMatrixRow2")
        uColorMatrixRow3Loc = GLES30.glGetUniformLocation(colorFilterProgram, "uColorMatrixRow3")
        uColorMatrixOffsetLoc = GLES30.glGetUniformLocation(colorFilterProgram, "uColorMatrixOffset")
        uColorLut2DLoc = GLES30.glGetUniformLocation(colorFilterProgram, "uLut2D")

        // Create VAO + VBO for fullscreen quad.
        val vaos = IntArray(1)
        GLES30.glGenVertexArrays(1, vaos, 0)
        quadVao = vaos[0]

        val vbos = IntArray(1)
        GLES30.glGenBuffers(1, vbos, 0)
        quadVbo = vbos[0]

        val quadBuffer = ByteBuffer.allocateDirect(FULLSCREEN_QUAD.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .put(FULLSCREEN_QUAD)
            .also { it.position(0) }

        GLES30.glBindVertexArray(quadVao)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, quadVbo)
        GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, FULLSCREEN_QUAD.size * 4, quadBuffer, GLES30.GL_STATIC_DRAW)
        GLES30.glEnableVertexAttribArray(0)
        GLES30.glVertexAttribPointer(0, 2, GLES30.GL_FLOAT, false, 16, 0)
        GLES30.glEnableVertexAttribArray(1)
        GLES30.glVertexAttribPointer(1, 2, GLES30.GL_FLOAT, false, 16, 8)
        GLES30.glBindVertexArray(0)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, 0)

        Log.d(TAG, "GL resources initialized (including CAM-01 color filter)")
    }

    private fun createOesTexture(): Int {
        val textures = IntArray(1)
        GLES30.glGenTextures(1, textures, 0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textures[0])
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        return textures[0]
    }

    private fun recreateIntermediateFbo(width: Int, height: Int) {
        // Delete previous intermediate.
        if (intermediateFbo != 0) {
            GLES30.glDeleteFramebuffers(1, intArrayOf(intermediateFbo), 0)
            intermediateFbo = 0
        }
        if (intermediateTexture != 0) {
            GLES30.glDeleteTextures(1, intArrayOf(intermediateTexture), 0)
            intermediateTexture = 0
        }

        // Delete previous beauty intermediate.
        if (beautyIntermediateFbo != 0) {
            GLES30.glDeleteFramebuffers(1, intArrayOf(beautyIntermediateFbo), 0)
            beautyIntermediateFbo = 0
        }
        if (beautyIntermediateTexture != 0) {
            GLES30.glDeleteTextures(1, intArrayOf(beautyIntermediateTexture), 0)
            beautyIntermediateTexture = 0
        }

        // Create 2D texture for intermediate.
        val textures = IntArray(1)
        GLES30.glGenTextures(1, textures, 0)
        intermediateTexture = textures[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, intermediateTexture)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, width, height, 0,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)

        // Create FBO for intermediate.
        val fbos = IntArray(1)
        GLES30.glGenFramebuffers(1, fbos, 0)
        intermediateFbo = fbos[0]
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, intermediateFbo)
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
            GLES30.GL_TEXTURE_2D, intermediateTexture, 0)

        val status = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER)
        if (status != GLES30.GL_FRAMEBUFFER_COMPLETE) {
            Log.e(TAG, "Intermediate FBO incomplete: $status")
        }
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

        // Create 2D texture for beauty intermediate (two-pass composition).
        val beautyTextures = IntArray(1)
        GLES30.glGenTextures(1, beautyTextures, 0)
        beautyIntermediateTexture = beautyTextures[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, beautyIntermediateTexture)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, width, height, 0,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)

        // Create FBO for beauty intermediate.
        val beautyFbos = IntArray(1)
        GLES30.glGenFramebuffers(1, beautyFbos, 0)
        beautyIntermediateFbo = beautyFbos[0]
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, beautyIntermediateFbo)
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
            GLES30.GL_TEXTURE_2D, beautyIntermediateTexture, 0)

        val beautyStatus = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER)
        if (beautyStatus != GLES30.GL_FRAMEBUFFER_COMPLETE) {
            Log.e(TAG, "Beauty intermediate FBO incomplete: $beautyStatus")
        }
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

        // The final (egress-only) texture is sized to the input, so a resolution
        // change invalidates it; it is re-created lazily on the next egress frame.
        deleteFinalTextureFbo()

        Log.d(TAG, "Intermediate & Beauty FBOs created: ${width}×${height}")
    }

    // GPU thread only. Creates the final processed-frame texture + FBO at the
    // current input size on first use. Only the egress-active path calls this,
    // so the normal preview path allocates nothing extra. Returns false (with
    // nothing allocated) if the FBO is incomplete.
    private fun ensureFinalTextureFbo(): Boolean {
        if (finalFbo != 0) return true
        if (frameWidth <= 0 || frameHeight <= 0) return false

        val finalTextures = IntArray(1)
        GLES30.glGenTextures(1, finalTextures, 0)
        finalTexture = finalTextures[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, finalTexture)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, frameWidth, frameHeight, 0,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)

        val finalFbos = IntArray(1)
        GLES30.glGenFramebuffers(1, finalFbos, 0)
        finalFbo = finalFbos[0]
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, finalFbo)
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
            GLES30.GL_TEXTURE_2D, finalTexture, 0)

        val finalStatus = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        if (finalStatus != GLES30.GL_FRAMEBUFFER_COMPLETE) {
            Log.e(TAG, "Final FBO incomplete: $finalStatus")
            deleteFinalTextureFbo()
            return false
        }

        Log.d(TAG, "Final FBO created for egress: ${frameWidth}×${frameHeight}")
        return true
    }

    private fun deleteFinalTextureFbo() {
        if (finalFbo != 0) {
            GLES30.glDeleteFramebuffers(1, intArrayOf(finalFbo), 0)
            finalFbo = 0
        }
        if (finalTexture != 0) {
            GLES30.glDeleteTextures(1, intArrayOf(finalTexture), 0)
            finalTexture = 0
        }
    }

    // ── Shader compilation ───────────────────────────────────────────────────

    private fun buildProgram(vertexSrc: String, fragmentSrc: String): Int {
        val vs = compileShader(GLES30.GL_VERTEX_SHADER, vertexSrc)
        val fs = compileShader(GLES30.GL_FRAGMENT_SHADER, fragmentSrc)
        val program = GLES30.glCreateProgram()
        GLES30.glAttachShader(program, vs)
        GLES30.glAttachShader(program, fs)
        GLES30.glLinkProgram(program)

        val linkStatus = IntArray(1)
        GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] != GLES30.GL_TRUE) {
            val log = GLES30.glGetProgramInfoLog(program)
            GLES30.glDeleteProgram(program)
            throw RuntimeException("Program link failed: $log")
        }
        GLES30.glDeleteShader(vs)
        GLES30.glDeleteShader(fs)
        return program
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, source)
        GLES30.glCompileShader(shader)

        val compileStatus = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, compileStatus, 0)
        if (compileStatus[0] != GLES30.GL_TRUE) {
            val log = GLES30.glGetShaderInfoLog(shader)
            GLES30.glDeleteShader(shader)
            throw RuntimeException("Shader compile failed: $log")
        }
        return shader
    }

    // ── Cleanup ──────────────────────────────────────────────────────────────

    private fun releaseOutputSurface() {
        if (outputEglSurface != EGL14.EGL_NO_SURFACE && eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglDestroySurface(eglDisplay, outputEglSurface)
            outputEglSurface = EGL14.EGL_NO_SURFACE
        }
        outputSurfaceOutput?.close()
        outputSurfaceOutput = null
        outputSurface = null
    }

    fun release() {
        if (!released.compareAndSet(false, true)) return

        gpuHandler.post {
            try {
                // Egress first: it needs the display/context alive to make
                // another surface current before its own surface is destroyed.
                pendingEgress = null
                releaseEgressRenderer()

                releaseOutputSurface()

                // Release cached native GL resources (shader programs, FBOs,
                // textures, VAO/VBO) while the EGL context is still current.
                // G1-B / F2: release the overlay and green-screen processors first
                // (they own shader programs, textures and FBOs in this context).
                overlayProcessor?.release()
                overlayProcessor = null
                greenScreenProcessor?.release()
                greenScreenProcessor = null
                nativeBridge.releaseLiveCameraBeauty()

                surfaceTexture?.setOnFrameAvailableListener(null)
                surfaceTexture?.release()
                surfaceTexture = null
                inputSurface?.release()
                inputSurface = null

                if (oesTexture != 0) {
                    GLES30.glDeleteTextures(1, intArrayOf(oesTexture), 0)
                    oesTexture = 0
                }
                if (intermediateTexture != 0) {
                    GLES30.glDeleteTextures(1, intArrayOf(intermediateTexture), 0)
                    intermediateTexture = 0
                }
                if (intermediateFbo != 0) {
                    GLES30.glDeleteFramebuffers(1, intArrayOf(intermediateFbo), 0)
                    intermediateFbo = 0
                }
                if (beautyIntermediateTexture != 0) {
                    GLES30.glDeleteTextures(1, intArrayOf(beautyIntermediateTexture), 0)
                    beautyIntermediateTexture = 0
                }
                if (beautyIntermediateFbo != 0) {
                    GLES30.glDeleteFramebuffers(1, intArrayOf(beautyIntermediateFbo), 0)
                    beautyIntermediateFbo = 0
                }
                deleteFinalTextureFbo()
                if (egressProgram != 0) {
                    GLES30.glDeleteProgram(egressProgram)
                    egressProgram = 0
                }
                if (lutTextureId != 0) {
                    GLES30.glDeleteTextures(1, intArrayOf(lutTextureId), 0)
                    lutTextureId = 0
                }
                if (oesProgram != 0) {
                    GLES30.glDeleteProgram(oesProgram)
                    oesProgram = 0
                }
                if (passthroughProgram != 0) {
                    GLES30.glDeleteProgram(passthroughProgram)
                    passthroughProgram = 0
                }
                if (colorFilterProgram != 0) {
                    GLES30.glDeleteProgram(colorFilterProgram)
                    colorFilterProgram = 0
                }
                if (quadVbo != 0) {
                    GLES30.glDeleteBuffers(1, intArrayOf(quadVbo), 0)
                    quadVbo = 0
                }
                if (quadVao != 0) {
                    GLES30.glDeleteVertexArrays(1, intArrayOf(quadVao), 0)
                    quadVao = 0
                }

                if (pbufferSurface != EGL14.EGL_NO_SURFACE && eglDisplay != EGL14.EGL_NO_DISPLAY) {
                    EGL14.eglDestroySurface(eglDisplay, pbufferSurface)
                    pbufferSurface = EGL14.EGL_NO_SURFACE
                }

                if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                    EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                    if (eglContext != EGL14.EGL_NO_CONTEXT) {
                        EGL14.eglDestroyContext(eglDisplay, eglContext)
                        eglContext = EGL14.EGL_NO_CONTEXT
                    }
                    EGL14.eglTerminate(eglDisplay)
                    eglDisplay = EGL14.EGL_NO_DISPLAY
                }

                Log.d(TAG, "Released all GPU resources")
            } catch (e: Exception) {
                Log.e(TAG, "Release failed: ${e.message}", e)
            }

            gpuThread.quitSafely()
        }
    }
}
