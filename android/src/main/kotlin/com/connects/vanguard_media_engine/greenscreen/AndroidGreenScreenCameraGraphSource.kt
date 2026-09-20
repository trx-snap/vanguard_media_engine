package com.connects.vanguard_media_engine.greenscreen

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.duet.AndroidDuetBackgroundScaleMode
import com.connects.vanguard_media_engine.duet.AndroidDuetGreenScreenBackground
import com.connects.vanguard_media_engine.duet.AndroidDuetGreenScreenBackgroundType
import com.connects.vanguard_media_engine.duet.AndroidDuetLayoutGeometry
import com.connects.vanguard_media_engine.duet.AndroidDuetPreviewRenderLoop
import com.connects.vanguard_media_engine.duet.AndroidDuetPreviewSurfaceProducer
import com.connects.vanguard_media_engine.duet.DuetSurfaceState
import com.connects.vanguard_media_engine.duet.NativeForegroundTransform
import com.connects.vanguard_media_engine.duet.VGDuetLayoutRects
import io.flutter.view.TextureRegistry
import java.util.LinkedHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Independent camera-graph source for the Green Screen capability.
 *
 * Green Screen is not owned by Duet: this class exposes the only public
 * green-screen camera API and lives in its own package. It reuses the
 * existing Duet preview renderer and surface producer internally (they are
 * generic frame-pump/EGL plumbing, not Duet-specific business logic), but no
 * Duet type or session ever appears in this class's public surface.
 */
class AndroidGreenScreenCameraGraphSource(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
    private val mainHandler: Handler,
    private val widthPx: Int = 1080,
    private val heightPx: Int = 1920,
) {

    companion object {
        private const val TAG = "GreenScreenCamGraphSrc"
        private const val GRAPH_MODE = "greenScreenGpu"
        private val DEFAULT_TEAL_BACKGROUND = AndroidDuetGreenScreenBackground(
            type = AndroidDuetGreenScreenBackgroundType.SOLID_COLOR,
            argbColor = 0xFF008080.toInt(),
            filePath = null,
            scaleMode = AndroidDuetBackgroundScaleMode.ASPECT_FILL,
        )
    }

    private val running = AtomicBoolean(false)
    private val stopped = AtomicBoolean(true)
    private val cameraStartGuard = AtomicBoolean(false)

    private var producer: AndroidDuetPreviewSurfaceProducer? = null
    private var renderLoop: AndroidDuetPreviewRenderLoop? = null
    private var cameraSource: AndroidGreenScreenCamera2Source? = null
    private var decoderThread: HandlerThread? = null

    @Volatile private var outputAttached = false
    @Volatile private var greenScreenEnabled = true
    @Volatile private var background: AndroidDuetGreenScreenBackground = DEFAULT_TEAL_BACKGROUND
    @Volatile private var outputMode: AndroidGreenScreenCameraFilterChain.OutputMode =
        AndroidGreenScreenCameraFilterChain.OutputMode.SOLID_COLOR
    @Volatile private var foregroundTransform: NativeForegroundTransform? = null
    @Volatile private var layoutRects: VGDuetLayoutRects =
        AndroidDuetLayoutGeometry.greenScreen(widthPx.toDouble(), heightPx.toDouble(), null)
    @Volatile private var lastError: String? = null
    @Volatile private var cameraStarted = false

    // ── Public API ───────────────────────────────────────────────────────────

    /** Must be called on the Android main thread. Idempotent: a second call while running just returns current state. */
    fun start(): Map<String, Any?> {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            Log.w(TAG, "start() called off the platform thread")
        }
        if (!running.compareAndSet(false, true)) {
            return buildResultMap()
        }
        stopped.set(false)
        lastError = null
        cameraStarted = false
        outputAttached = false
        cameraStartGuard.set(false)

        val dt = HandlerThread("vg.greenscreen.decoder").apply { start() }
        decoderThread = dt
        val decoderHandler = Handler(dt.looper)

        val prod = AndroidDuetPreviewSurfaceProducer(
            textureRegistry = textureRegistry,
            mainHandler = mainHandler,
            widthPx = widthPx,
            heightPx = heightPx,
            onSurfaceAvailable = { handleSurfaceAvailable() },
            onSurfaceLost = { handleSurfaceLost() },
        )
        producer = prod

        val loop = AndroidDuetPreviewRenderLoop(
            mainHandler = mainHandler,
            decoderHandler = decoderHandler,
            decoderProvider = { null },
            cameraInputSurfaceReady = { camSurface -> startCameraSourceIfNeeded(camSurface) },
        )
        renderLoop = loop

        background = DEFAULT_TEAL_BACKGROUND
        greenScreenEnabled = true
        recomputeLayoutRects()
        loop.setGreenScreenEnabled(true)
        loop.setGreenScreenBackground(background)

        attachOutputIfPossible()

        return buildResultMap()
    }

    fun setGreenScreenEnabled(enabled: Boolean): Map<String, Any?> {
        greenScreenEnabled = enabled
        renderLoop?.setGreenScreenEnabled(enabled)
        return diagnosticsSnapshot()
    }

    fun setGreenScreenBackground(background: AndroidDuetGreenScreenBackground): Map<String, Any?> {
        this.background = background
        renderLoop?.setGreenScreenBackground(background)
        return diagnosticsSnapshot()
    }

    /**
     * Sets the diagnostic output-routing mode reported by [diagnosticsSnapshot].
     *
     * The caller (the plugin's `setCameraFilterChain` router) has already
     * validated the mode via [AndroidGreenScreenCameraFilterChain.parse]; this
     * setter trusts that and only updates the tracked/reported value. It does
     * not change the render loop's actual visual compositing — alpha mode is a
     * diagnostics/API-acceptance route only in this slice, with no Flutter
     * preview transparency or native renderer alpha-output claim.
     */
    fun setGreenScreenOutputMode(mode: AndroidGreenScreenCameraFilterChain.OutputMode) {
        outputMode = mode
    }

    fun updateForegroundTransform(transform: NativeForegroundTransform?): Map<String, Any?> {
        foregroundTransform = transform
        recomputeLayoutRects()
        if (renderLoop != null) {
            if (outputAttached) {
                val rects = layoutRects
                renderLoop?.updateLayout(rects.source, rects.camera, 0L)
            } else {
                attachOutputIfPossible()
            }
        }
        return diagnosticsSnapshot()
    }

    /** Point-in-time snapshot; safe while running or after [stop]. Never mutates state. */
    fun diagnosticsSnapshot(): Map<String, Any?> {
        val snapshot = LinkedHashMap<String, Any?>()
        snapshot["graphMode"] = GRAPH_MODE
        snapshot["running"] = running.get()
        snapshot["stopped"] = stopped.get()
        snapshot["textureId"] = producer?.textureId
        snapshot["widthPx"] = widthPx
        snapshot["heightPx"] = heightPx
        snapshot["producerState"] = producer?.state?.name
        snapshot["greenScreenEnabled"] = greenScreenEnabled
        val isAlphaMode = outputMode == AndroidGreenScreenCameraFilterChain.OutputMode.ALPHA
        val alphaSelfTestPassed = if (isAlphaMode) AlphaByteSelfTest.passed else false
        snapshot["outputMode"] = if (isAlphaMode) "alpha" else "composited"
        snapshot["backgroundType"] = if (isAlphaMode) "alpha" else "solidColor"
        snapshot["alphaByteSelfTestPassed"] = alphaSelfTestPassed
        snapshot["alphaEncoding"] = if (isAlphaMode && alphaSelfTestPassed) "straight" else null
        snapshot["layoutRects"] = layoutRectsMap()
        snapshot["lastError"] = lastError
        snapshot["cameraStarted"] = cameraStarted
        snapshot["camera"] = cameraSource?.diagnosticsSnapshot()
        return snapshot
    }

    fun isRunning(): Boolean = running.get()

    /** Best-effort, idempotent, never throws. Safe to call even if [start] was never called. */
    fun stop() {
        stopped.set(true)
        running.set(false)
        outputAttached = false
        cameraStartGuard.set(false)
        cameraStarted = false

        val prod = producer
        val loop = renderLoop
        val cam = cameraSource
        val dt = decoderThread

        try { prod?.beginRelease() } catch (_: Throwable) {}
        try { loop?.prepareForCameraStop() } catch (_: Throwable) {}
        try { cam?.stop() } catch (_: Throwable) {}
        try { loop?.stopBlocking(0L) } catch (_: Throwable) {}
        try { prod?.finishRelease() } catch (_: Throwable) {}
        try {
            dt?.quitSafely()
            dt?.join(500)
        } catch (_: Throwable) {}

        producer = null
        renderLoop = null
        cameraSource = null
        decoderThread = null
    }

    // ── Internal wiring ──────────────────────────────────────────────────────

    private fun handleSurfaceAvailable() {
        if (stopped.get()) return
        attachOutputIfPossible()
    }

    private fun handleSurfaceLost() {
        outputAttached = false
        renderLoop?.handleOutputSurfaceLost()
    }

    private fun attachOutputIfPossible() {
        val prod = producer ?: return
        val loop = renderLoop ?: return
        if (prod.state != DuetSurfaceState.SURFACE_AVAILABLE) return
        val surface: Surface = prod.acquireSurface() ?: return
        val rects = layoutRects
        loop.attachOutputSurface(surface, widthPx, heightPx, rects.source, rects.camera, 0L)
        outputAttached = true
    }

    /** Started lazily once the render loop's compositor camera input surface is ready. Idempotent; retries after a transient camera start failure. */
    private fun startCameraSourceIfNeeded(camSurface: Surface) {
        if (stopped.get()) return
        if (!cameraStartGuard.compareAndSet(false, true)) return
        val loop = renderLoop
        val src = AndroidGreenScreenCamera2Source(context)
        cameraSource = src
        src.start(
            targetSurface = camSurface,
            onCameraFrameTransform = { rotationDegrees, mirrorHorizontal ->
                loop?.setCameraFrameTransform(rotationDegrees, mirrorHorizontal)
            },
            onGpuMask = { hardwareBuffer, maskWidthPx, maskHeightPx, timestampUs, onReleased, acquireFenceFd ->
                loop?.updateGreenScreenMaskHardwareBuffer(
                    hardwareBuffer, maskWidthPx, maskHeightPx, timestampUs, onReleased, acquireFenceFd,
                )
            },
            onStarted = {
                cameraStarted = true
            },
            onError = { e ->
                Log.w(TAG, "green-screen camera start failed: ${e.message}", e)
                lastError = "${e.javaClass.simpleName}: ${e.message}"
                cameraStarted = false
                cameraStartGuard.set(false)
            },
        )
    }

    private fun recomputeLayoutRects() {
        layoutRects = AndroidDuetLayoutGeometry.greenScreen(widthPx.toDouble(), heightPx.toDouble(), foregroundTransform)
    }

    private fun layoutRectsMap(): Map<String, Any> {
        val rects = layoutRects
        return mapOf(
            "source" to rects.source.toMap(),
            "camera" to rects.camera.toMap(),
        )
    }

    private fun buildResultMap(): Map<String, Any?> {
        val result = LinkedHashMap<String, Any?>()
        producer?.let { result.putAll(it.toResultMap(widthPx, heightPx, layoutRectsMap())) }
        result["graphMode"] = GRAPH_MODE
        result["greenScreenEnabled"] = greenScreenEnabled
        result["diagnostics"] = diagnosticsSnapshot()
        return result
    }
}

/**
 * One-time, deterministic, byte-level proof of straight-alpha pixel
 * construction semantics — never touches the GPU, camera, decoder, or
 * Flutter texture/renderer. It proves only that packing `[R, G, B, A]` bytes
 * with the mask value in the alpha slot leaves foreground RGB unchanged and
 * reports alpha equal to the mask, across a transparent, feather-edge, and
 * fully-opaque mask value. This is not proof of any real matte, preview, or
 * export alpha output.
 */
private object AlphaByteSelfTest {
    private data class Case(val r: Int, val g: Int, val b: Int, val mask: Int)

    private val cases = listOf(
        Case(r = 12, g = 200, b = 40, mask = 0), // transparent background
        Case(r = 250, g = 30, b = 90, mask = 128), // feather edge
        Case(r = 5, g = 5, b = 5, mask = 255), // opaque subject
    )

    val passed: Boolean by lazy {
        cases.all { case ->
            val packed = pack(case.r, case.g, case.b, case.mask)
            val r = packed[0].toInt() and 0xFF
            val g = packed[1].toInt() and 0xFF
            val b = packed[2].toInt() and 0xFF
            val a = packed[3].toInt() and 0xFF
            r == case.r && g == case.g && b == case.b && a == case.mask
        }
    }

    private fun pack(r: Int, g: Int, b: Int, a: Int): ByteArray =
        byteArrayOf(r.toByte(), g.toByte(), b.toByte(), a.toByte())
}
