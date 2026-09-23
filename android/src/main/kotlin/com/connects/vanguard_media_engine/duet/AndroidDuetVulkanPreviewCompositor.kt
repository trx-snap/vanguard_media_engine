package com.connects.vanguard_media_engine.duet

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class AndroidDuetVulkanPreviewCompositor : AndroidDuetPreviewBackend {
    companion object {
        private const val TAG = "DuetVulkanComp"
        // This CameraX Duet preview path uses the raw landscape 1920x1080
        // camera input surface CameraX's Preview use-case actually negotiates
        // on-device (matching the GLES path's CAMERA_ST_DEFAULT_WIDTH/HEIGHT
        // contract in AndroidDuetPreviewCompositor). This is pre-rotation,
        // sensor-orientation content: native's
        // ResolveVulkanDuetLayoutLayerPlacement swaps width/height when
        // cameraRotationDegrees is 90/270 before aspect-fill, which is what
        // turns this landscape 1920x1080 buffer into the upright 9:16 aspect
        // expected for the front camera. Do not optimize this down to a
        // lower resolution inside this compositor: a prior attempt at that
        // regressed live camera orientation and mask quality. Future
        // performance work must introduce an explicit, tested camera-content
        // geometry contract instead of hard-coding a different resolution
        // here.
        private const val CAMERA_DEFAULT_WIDTH = 1920
        private const val CAMERA_DEFAULT_HEIGHT = 1080
        private const val DECODER_DEFAULT_WIDTH = 1080
        private const val DECODER_DEFAULT_HEIGHT = 1920

        // ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND: the
        // debugGreenScreenBackgroundMode layoutConfig value recognized by
        // [setGreenScreenBackgroundMode], and its native wire value for
        // renderAndroidDuetVulkanPreviewStaticBackgroundFrame's backgroundMode
        // (mirrors render::DuetGreenScreenStaticBackgroundMode::kSolidTeal).
        private const val GREEN_SCREEN_BACKGROUND_MODE_SOLID_TEAL = "solid_teal"
        private const val NATIVE_GREEN_SCREEN_STATIC_BACKGROUND_SOLID_TEAL = 1

        /**
         * ANDROID-DUET-VULKAN-LAYOUT: converts a canvas-pixel [rect] (Double,
         * top-left origin) into the integer rect handed to native. Fails
         * closed (null) when any component is non-finite or the size is not
         * strictly positive; otherwise rounds every edge to the nearest
         * pixel, clamps the result to the [canvasWidth] x [canvasHeight]
         * canvas from attach, and fails closed again if nothing of the rect
         * remains on-canvas after clamping.
         */
        internal fun toNativeLayoutRect(
            rect: VGDuetPixelRect,
            canvasWidth: Int,
            canvasHeight: Int,
        ): NativeLayoutRect? {
            if (canvasWidth <= 0 || canvasHeight <= 0) return null
            if (!rect.left.isFinite() || !rect.top.isFinite() ||
                !rect.width.isFinite() || !rect.height.isFinite()
            ) {
                return null
            }
            if (rect.width <= 0.0 || rect.height <= 0.0) return null
            // Round the edges (not the size) so adjacent split halves stay
            // seamless and rounding never produces a one-pixel overlap/gap.
            val left = rect.left.roundToInt()
            val top = rect.top.roundToInt()
            val right = (rect.left + rect.width).roundToInt()
            val bottom = (rect.top + rect.height).roundToInt()
            val clampedLeft = max(0, min(left, canvasWidth))
            val clampedTop = max(0, min(top, canvasHeight))
            val clampedRight = max(0, min(right, canvasWidth))
            val clampedBottom = max(0, min(bottom, canvasHeight))
            val width = clampedRight - clampedLeft
            val height = clampedBottom - clampedTop
            if (width <= 0 || height <= 0) return null
            return NativeLayoutRect(clampedLeft, clampedTop, width, height)
        }

        /**
         * ANDROID-DUET-VULKAN-GREENSCREEN-FREE-TRANSFORM: converts a
         * canvas-pixel [rect] (Double, top-left origin) into the integer rect
         * handed to native for the Duet green-screen FOREGROUND camera layer,
         * WITHOUT clamping its position to the canvas -- unlike
         * [toNativeLayoutRect], which the PiP/split layout path still uses.
         * The Dart free-transform contract (VGDuetLayoutMath.computeGreenScreenRects)
         * intentionally allows the foreground rect to extend beyond or start
         * before the canvas; native (ResolveVulkanDuetLayoutLayerPlacement)
         * is responsible for clipping the scissor to the canvas and failing
         * closed if nothing of the rect remains on-canvas. Still fails closed
         * (null) when any component is non-finite or the size is not
         * strictly positive after rounding.
         */
        internal fun toNativeForegroundRect(rect: VGDuetPixelRect): NativeLayoutRect? {
            if (!rect.left.isFinite() || !rect.top.isFinite() ||
                !rect.width.isFinite() || !rect.height.isFinite()
            ) {
                return null
            }
            if (rect.width <= 0.0 || rect.height <= 0.0) return null
            val left = rect.left.roundToInt()
            val top = rect.top.roundToInt()
            val right = (rect.left + rect.width).roundToInt()
            val bottom = (rect.top + rect.height).roundToInt()
            val width = right - left
            val height = bottom - top
            if (width <= 0 || height <= 0) return null
            return NativeLayoutRect(left, top, width, height)
        }

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

    /** Integer canvas-pixel rect (top-left origin) as passed to native. */
    internal data class NativeLayoutRect(val x: Int, val y: Int, val width: Int, val height: Int)

    private var nativeSessionHandle: Long = 0
    private var isReleased = false
    private var isAttached = false

    private var cameraReader: ImageReader? = null
    private var decoderReader: ImageReader? = null

    // Layer mapping is mandatory: decoder/source video is background,
    // camera/live subject is foreground. Latest-wins latches — the previous
    // Image is closed only after a newer one is successfully acquired, so a
    // reader with no new frame this draw keeps presenting its last one.
    private var latchedDecoderImage: Image? = null
    private var latchedCameraImage: Image? = null

    private val decoderFramePending = AtomicBoolean(false)
    private val cameraFramePending = AtomicBoolean(false)

    private var greenScreenEnabled = false

    // ANDROID-DUET-VULKAN-CAMERA-PASSTHROUGH-DEBUG /
    // ANDROID-DUET-VULKAN-GREENSCREEN-MATTE: render-thread-confined,
    // normalized diagnostic view selector. "camera_passthrough" and
    // "mask_full_white" force the layout/mask path as before; "mask_direct",
    // "mask_mapped", "mask_direct_mirror_x" and "mask_direct_flip_y" select
    // the native green-screen fragment shader's RND matte-visualization
    // debug modes (see [nativeGreenScreenDebugMode]). Any other value or
    // null disables the diagnostic.
    private var greenScreenDebugView: String? = null

    // ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND: render-thread-
    // confined, normalized RND-only static background selector
    // (layoutConfig key debugGreenScreenBackgroundMode). Null (the default)
    // keeps the production video-background green-screen path in [drawFrame]
    // exactly as before; "solid_teal" routes green-screen frames to the
    // camera-only native static-background render instead (see
    // [setGreenScreenBackgroundMode]).
    private var greenScreenBackgroundMode: String? = null

    // ANDROID-DUET-VULKAN-LAYOUT: latest layout rects from setLayout (canvas
    // pixel space, top-left origin) and the canvas dimensions from the last
    // successful native attach. Render-thread-confined like the rest of the
    // compositor state.
    private var sourceRect: VGDuetPixelRect? = null
    private var cameraRect: VGDuetPixelRect? = null
    private var outputWidthPx = 0
    private var outputHeightPx = 0

    private var fallbackDelegate: AndroidDuetPreviewCompositor? = null
    private var isBound = false

    // ANDROID-DUET-VULKAN-GPU-MASK: the HardwareBuffer currently imported as
    // the native session's GPU-resident mask. Ownership transferred to this
    // compositor by the caller of [updateGreenScreenMaskHardwareBuffer]; held
    // here (not closed) for as long as native/Vulkan's import is live, and
    // closed only once superseded by a newer successful import or on
    // [release]. Render-thread-confined like the rest of this compositor.
    private var gpuMaskBuffer: HardwareBuffer? = null
    private var gpuMaskReleaseCallback: ((HardwareBuffer) -> Unit)? = null

    private var sourceVideoWidthPx = 0
    private var sourceVideoHeightPx = 0
    // ANDROID-DUET-VULKAN-TRANSFORM: normalized (0/90/180/270) rotation the
    // source video was recorded with, and the live camera feed's normalized
    // rotation/mirror state, threaded into native render calls so a
    // portrait-recorded-but-rotated source or a front-camera feed is
    // corrected instead of being rendered sideways/mirrored incorrectly.
    private var sourceVideoRotationDegrees = 0
    private var cameraRotationDegrees = 0
    private var cameraMirrorHorizontal = false

    // ANDROID-DUET-VULKAN-GREENSCREEN-FREE-TRANSFORM: Duet-only preview
    // foreground free-rotation metadata (mirrors AndroidDuetPreviewCompositor's
    // GLES fields of the same name): [setForegroundRotation]'s visual-clockwise
    // angle (Dart/top-left space) and normalized pivot anchor within the
    // camera rect. Render-thread only. Identity default (0.0, 0.5, 0.5)
    // applies no rotation, so callers that never invoke [setForegroundRotation]
    // see unchanged behavior.
    private var foregroundRotationDegrees = 0.0
    private var foregroundAnchorX = 0.5
    private var foregroundAnchorY = 0.5

    // One-shot diagnostic logs, emitted only after the corresponding native
    // call reports success for the first time (never on a false/failed call).
    private val maskUploadLoggedOnce = AtomicBoolean(false)
    private val gpuMaskUploadLoggedOnce = AtomicBoolean(false)
    // ANDROID-DUET-VULKAN-WHITE-MASK-DEBUG: reset (not left one-shot forever)
    // whenever mask_full_white is left, so re-entering the diagnostic logs
    // the forced white-mask upload again for the next QA pass.
    private val whiteMaskDebugUploadLoggedOnce = AtomicBoolean(false)
    private val previewFrameLoggedOnce = AtomicBoolean(false)
    private val layoutFrameLoggedOnce = AtomicBoolean(false)
    // ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND: one-shot for the
    // first successful camera-only static-background frame (RND diagnostic).
    private val staticBackgroundFrameLoggedOnce = AtomicBoolean(false)
    // Rate limit for the invalid-layout-rect warning (drawFrame runs ~30 fps).
    private val invalidLayoutRectLoggedOnce = AtomicBoolean(false)
    private var gpuMaskImportCount: Long = 0
    private var totalGpuMaskImportLatencyMs: Long = 0
    private var maxGpuMaskImportLatencyMs: Long = 0

    // ANDROID-DUET-VULKAN-CPU-MASK-SCRATCH: render-thread-confined reusable
    // direct scratch buffer for [updateGreenScreenMask]'s CPU mask pack
    // step, avoiding a steady-state per-mask ByteBuffer.allocateDirect
    // allocation. Reallocated only when unset or its capacity is smaller
    // than the incoming mask's pixel count; otherwise cleared and reused.
    // Observation-only upload telemetry (pack + native-upload latency) is
    // summarized once in [release].
    private var cpuMaskScratchBuffer: ByteBuffer? = null
    private var cpuMaskScratchAllocationCount: Long = 0
    private var cpuMaskUploadCount: Long = 0
    private var totalCpuMaskUploadLatencyMs: Long = 0
    private var maxCpuMaskUploadLatencyMs: Long = 0

    override val cameraInputSurface: Surface?
        get() = fallbackDelegate?.cameraInputSurface ?: cameraReader?.surface

    override val decoderInputSurface: Surface?
        get() = fallbackDelegate?.decoderInputSurface ?: decoderReader?.surface

    override val hasPendingSourceFrame: Boolean
        get() = fallbackDelegate?.hasPendingSourceFrame ?: decoderFramePending.get()

    override val hasPendingCameraFrame: Boolean
        get() = fallbackDelegate?.hasPendingCameraFrame ?: cameraFramePending.get()

    init {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            fallbackToGles("api_level_below_q")
        } else {
            try {
                nativeSessionHandle = VanguardNativeBridge.createAndroidDuetVulkanPreviewSession()
                if (nativeSessionHandle == 0L) {
                    fallbackToGles("failed_to_create_native_session")
                }
            } catch (t: Throwable) {
                Log.e(TAG, "Exception initializing native Vulkan preview session", t)
                fallbackToGles("exception_creating_native_session")
            }
        }
    }

    private fun fallbackToGles(reason: String) {
        if (isBound) {
            Log.e(TAG, "Mid-session fallback attempted after bind: $reason")
            return
        }
        Log.w(TAG, "Falling back to GLES before bind: $reason")
        if (nativeSessionHandle != 0L) {
            try {
                VanguardNativeBridge.destroyAndroidDuetVulkanPreviewSession(nativeSessionHandle)
            } catch (t: Throwable) {
                Log.w(TAG, "Exception destroying native session during fallback", t)
            }
            nativeSessionHandle = 0L
        }
        if (fallbackDelegate == null) {
            fallbackDelegate = AndroidDuetPreviewCompositor()
        }
    }

    override fun attachOutputSurface(surface: Surface, widthPx: Int, heightPx: Int): Boolean {
        if (isReleased) return false
        fallbackDelegate?.let { return it.attachOutputSurface(surface, widthPx, heightPx) }

        if (!surface.isValid || widthPx <= 0 || heightPx <= 0) {
            Log.w(TAG, "attachOutputSurface rejected: valid=${surface.isValid} ${widthPx}x$heightPx")
            return false
        }

        if (nativeSessionHandle == 0L) {
            if (!isBound) {
                fallbackToGles("null_native_session")
                return fallbackDelegate?.attachOutputSurface(surface, widthPx, heightPx) ?: false
            }
            return false
        }

        val nativeSuccess = VanguardNativeBridge.attachAndroidDuetVulkanPreviewSurface(
            nativeSessionHandle, surface, widthPx, heightPx
        )
        if (!nativeSuccess) {
            if (!isBound) {
                fallbackToGles("failed_to_attach_surface")
                return fallbackDelegate?.attachOutputSurface(surface, widthPx, heightPx) ?: false
            } else {
                Log.e(TAG, "Failed to re-attach native Vulkan preview surface after bind")
                return false
            }
        }

        // Native attach succeeded. Ensure both ImageReaders are bootstrapped before returning true.
        if (cameraReader == null || decoderReader == null) {
            try {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    throw IllegalStateException("ImageReader HardwareBuffer usage requires API >= Q")
                }
                val usage = HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE
                if (cameraReader == null) {
                    cameraReader = ImageReader.newInstance(
                        CAMERA_DEFAULT_WIDTH,
                        CAMERA_DEFAULT_HEIGHT,
                        ImageFormat.PRIVATE,
                        3,
                        usage,
                    ).also {
                        it.setOnImageAvailableListener({ cameraFramePending.set(true) }, null)
                    }
                }
                if (decoderReader == null) {
                    decoderReader = ImageReader.newInstance(
                        DECODER_DEFAULT_WIDTH,
                        DECODER_DEFAULT_HEIGHT,
                        ImageFormat.PRIVATE,
                        3,
                        usage,
                    ).also {
                        it.setOnImageAvailableListener({ decoderFramePending.set(true) }, null)
                    }
                }
                isBound = true
                isAttached = true
                outputWidthPx = widthPx
                outputHeightPx = heightPx
            } catch (e: Throwable) {
                Log.e(TAG, "Failed to bootstrap ImageReaders after native attach", e)
                try {
                    cameraReader?.close()
                } catch (_: Throwable) {}
                cameraReader = null

                try {
                    decoderReader?.close()
                } catch (_: Throwable) {}
                decoderReader = null

                VanguardNativeBridge.detachAndroidDuetVulkanPreviewSurface(nativeSessionHandle)
                fallbackToGles("failed_to_create_imagereaders")
                return fallbackDelegate?.attachOutputSurface(surface, widthPx, heightPx) ?: false
            }
        } else {
            isAttached = true
            outputWidthPx = widthPx
            outputHeightPx = heightPx
        }

        return true
    }

    override fun detachOutputSurface() {
        if (isReleased) return
        fallbackDelegate?.let {
            it.detachOutputSurface()
            return
        }
        if (nativeSessionHandle != 0L && isAttached) {
            isAttached = false
            outputWidthPx = 0
            outputHeightPx = 0
            try {
                VanguardNativeBridge.detachAndroidDuetVulkanPreviewSurface(nativeSessionHandle)
            } catch (t: Throwable) {
                Log.w(TAG, "Exception during native detachOutputSurface", t)
            }
        }
    }

    /**
     * Canvas-pixel rects (top-left origin) for the source video and camera
     * layers. Latest wins; consumed by [drawFrame]'s non-green-screen layout
     * path (PiP / split / green-screen terminal fallback) after rounding and
     * clamping to the attached canvas. Ignored by the green-screen path,
     * which is always full-canvas.
     */
    override fun setLayout(sourceRect: VGDuetPixelRect, cameraRect: VGDuetPixelRect) {
        fallbackDelegate?.let {
            it.setLayout(sourceRect, cameraRect)
            return
        }
        this.sourceRect = sourceRect
        this.cameraRect = cameraRect
        invalidLayoutRectLoggedOnce.set(false)
    }

    override fun setLayerScaleModes(
        sourceScaleMode: AndroidDuetLayerScaleMode,
        cameraScaleMode: AndroidDuetLayerScaleMode,
    ) {
        fallbackDelegate?.setLayerScaleModes(sourceScaleMode, cameraScaleMode)
    }

    override fun setSourceVideoSize(widthPx: Int, heightPx: Int) {
        if (isReleased) return
        fallbackDelegate?.let {
            it.setSourceVideoSize(widthPx, heightPx)
            return
        }
        // Metadata-only for foundation: keep decoderReader and its surface stable across calls
        sourceVideoWidthPx = widthPx
        sourceVideoHeightPx = heightPx
    }

    override fun setSourceVideoMetadata(widthPx: Int, heightPx: Int, rotationDegrees: Int) {
        if (isReleased) return
        fallbackDelegate?.let {
            it.setSourceVideoMetadata(widthPx, heightPx, rotationDegrees)
            return
        }
        sourceVideoWidthPx = widthPx
        sourceVideoHeightPx = heightPx
        sourceVideoRotationDegrees = normalizeRotationDegrees(rotationDegrees)
    }

    override fun setCameraFrameTransform(rotationDegrees: Int, mirrorHorizontal: Boolean) {
        if (isReleased) return
        fallbackDelegate?.let {
            it.setCameraFrameTransform(rotationDegrees, mirrorHorizontal)
            return
        }
        cameraRotationDegrees = normalizeRotationDegrees(rotationDegrees)
        cameraMirrorHorizontal = mirrorHorizontal
    }

    /**
     * Duet-only preview seam: stores the green-screen foreground/camera
     * layer's free-rotation angle and pivot anchor for the next [drawFrame].
     * Sanitizes non-finite input to identity and clamps the anchor to
     * `[0.0, 1.0]`, matching [AndroidDuetPreviewCompositor]'s GLES
     * implementation of the same method exactly.
     */
    override fun setForegroundRotation(rotationDegrees: Double, anchorX: Double, anchorY: Double) {
        fallbackDelegate?.let {
            it.setForegroundRotation(rotationDegrees, anchorX, anchorY)
            return
        }
        foregroundRotationDegrees = if (rotationDegrees.isFinite()) rotationDegrees else 0.0
        foregroundAnchorX = (if (anchorX.isFinite()) anchorX else 0.5).coerceIn(0.0, 1.0)
        foregroundAnchorY = (if (anchorY.isFinite()) anchorY else 0.5).coerceIn(0.0, 1.0)
    }

    override fun setGreenScreenEnabled(enabled: Boolean) {
        fallbackDelegate?.let {
            it.setGreenScreenEnabled(enabled)
            return
        }
        greenScreenEnabled = enabled
    }

    /**
     * Diagnostic-only. "camera_passthrough" isolates camera transform/crop
     * from mask alpha by forcing [drawFrame] onto the opaque layout render
     * path (source + camera, no mask) whenever green-screen is otherwise
     * enabled. "mask_full_white" isolates the green-screen renderer/blend
     * itself from MediaPipe GPU mask content: [drawFrame] stays on the
     * normal masked green-screen path, but the mask is forced to a 1x1
     * fully-opaque CPU upload that incoming real masks (CPU or GPU) cannot
     * override, so native should report maskSource=cpu_upload with the
     * subject never masked out. "mask_direct", "mask_mapped",
     * "mask_direct_mirror_x" and "mask_direct_flip_y" select the native
     * green-screen fragment shader's own RND matte-visualization debug modes
     * (see [nativeGreenScreenDebugMode]): the shader replaces the composited
     * camera with an opaque grayscale view of the mask itself, sampled a
     * different way per mode. Any other value or null restores normal
     * production compositing.
     */
    override fun setGreenScreenDebugView(view: String?) {
        fallbackDelegate?.let {
            it.setGreenScreenDebugView(view)
            return
        }
        val normalized = when (view) {
            "camera_passthrough", "mask_full_white", "mask_direct", "mask_mapped",
            "mask_direct_mirror_x", "mask_direct_flip_y" -> view
            else -> null
        }
        if (normalized == "mask_full_white" && greenScreenDebugView != "mask_full_white") {
            // Entering (or re-entering) the diagnostic: allow the one-shot
            // upload log to fire again, and force the native mask to white
            // immediately so drawFrame's very next green-screen frame is
            // already compositing from it instead of waiting on the next
            // real mask/GPU-mask call.
            whiteMaskDebugUploadLoggedOnce.set(false)
            uploadWhiteMaskForDebug()
        }
        greenScreenDebugView = normalized
    }

    /**
     * ANDROID-DUET-VULKAN-GREENSCREEN-MATTE: maps [greenScreenDebugView] to
     * the native green-screen fragment shader's debugMode (VulkanGreenScreen
     * CameraDraw::debugMode / maskDebug.x): 0 = normal, 1 = mask_direct,
     * 2 = mask_mapped, 3 = mask_direct_mirror_x, 4 = mask_direct_flip_y.
     * "camera_passthrough" and "mask_full_white" are not shader modes -- the
     * former forces [drawFrame] onto the opaque layout path entirely (where
     * this value is ignored natively), and the latter stays on the normal
     * masked path with a forced white CPU mask -- so both resolve to 0.
     */
    private fun nativeGreenScreenDebugMode(view: String?): Int = when (view) {
        "mask_direct" -> 1
        "mask_mapped" -> 2
        "mask_direct_mirror_x" -> 3
        "mask_direct_flip_y" -> 4
        else -> 0
    }

    /**
     * ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND (RND diagnostic
     * only): applies the layoutConfig key `debugGreenScreenBackgroundMode`.
     * Only "solid_teal" is recognized: while green-screen is enabled,
     * [drawFrame] then renders the camera alone -- aspect-filled into the
     * camera rect and alpha-masked by the session's current mask, with the
     * same rotation/mirror/content-dimension/debugMode logic as the
     * production green-screen path -- over a native solid-teal clear instead
     * of the decoded source video, so person-matte quality can be evaluated
     * without video-background decoder pressure. Any other value or null
     * restores the production video-background path exactly. The decoder
     * reader keeps being drained either way, so the source producer never
     * stalls; only the render no longer requires (or touches) its latched
     * frame. Combines with the shader debug views ("mask_direct", ...) and
     * "mask_full_white"; "camera_passthrough" still wins and forces the
     * opaque layout path (which needs the decoder) as before.
     *
     * Not part of [AndroidDuetPreviewBackend]; the GLES fallback delegate has
     * no static-background seam, so this is a no-op once a fallback is
     * active. Must be called on the render thread like every other mutator
     * of this compositor's state.
     */
    override fun setGreenScreenBackgroundMode(mode: String?) {
        if (fallbackDelegate != null) return
        greenScreenBackgroundMode = when (mode) {
            GREEN_SCREEN_BACKGROUND_MODE_SOLID_TEAL -> mode
            else -> null
        }
    }

    /**
     * ANDROID-DUET-VULKAN-WHITE-MASK-DEBUG: uploads a 1x1 fully opaque (255)
     * R8 CPU mask via the normal CPU mask-upload native entry point, so
     * native selects maskSource=cpu_upload with a mask that can never mask
     * out the subject. Used only by the "mask_full_white" diagnostic to
     * isolate the Vulkan green-screen renderer/blend path from MediaPipe GPU
     * mask content. No-op before the native session exists; safe to call
     * repeatedly.
     */
    private fun uploadWhiteMaskForDebug() {
        if (nativeSessionHandle == 0L) return
        val white = ByteBuffer.allocateDirect(1)
        white.put(0xFF.toByte())
        white.rewind()
        try {
            val success = VanguardNativeBridge.updateAndroidDuetVulkanPreviewMask(nativeSessionHandle, white, 1, 1)
            if (success && whiteMaskDebugUploadLoggedOnce.compareAndSet(false, true)) {
                Log.i(TAG, "ANDROID_DUET_VULKAN_WHITE_MASK_DEBUG_UPLOAD")
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Exception uploading white mask debug", t)
        }
    }

    /**
     * ANDROID-DUET-VULKAN-CPU-MASK-SCRATCH: returns [cpuMaskScratchBuffer]
     * sized to at least [pixelCount] bytes, ready for [updateGreenScreenMask]
     * to pack into (position 0, limit [pixelCount]). Reallocates only when
     * unset or the existing capacity is insufficient; otherwise clears the
     * existing buffer for reuse instead of allocating a fresh one.
     */
    private fun acquireCpuMaskScratchBuffer(pixelCount: Int): ByteBuffer {
        var scratch = cpuMaskScratchBuffer
        if (scratch == null || scratch.capacity() < pixelCount) {
            scratch = ByteBuffer.allocateDirect(pixelCount)
            cpuMaskScratchBuffer = scratch
            cpuMaskScratchAllocationCount += 1
        }
        scratch.clear()
        scratch.limit(pixelCount)
        return scratch
    }

    /**
     * Packs [frame] into a tightly packed direct R8 ByteBuffer and uploads it
     * to the native session's mask texture. Runs synchronously on the calling
     * thread (the render thread, per [AndroidDuetPreviewRenderLoop]'s posting
     * discipline) rather than deferring to [drawFrame], since the native
     * session mutex makes the upload safe to perform immediately. Incomplete
     * or invalid frames are ignored safely.
     */
    override fun updateGreenScreenMask(frame: AndroidDuetSegmentationFrame) {
        fallbackDelegate?.let {
            it.updateGreenScreenMask(frame)
            return
        }
        // ANDROID-DUET-VULKAN-WHITE-MASK-DEBUG: while the diagnostic is
        // active, real CPU mask updates must not overwrite the forced white
        // mask, or the renderer/blend isolation the diagnostic exists for
        // would be defeated the next time a real segmentation frame lands.
        if (greenScreenDebugView == "mask_full_white") return
        if (nativeSessionHandle == 0L) return
        val width = frame.width
        val height = frame.height
        if (width <= 0 || height <= 0 || !frame.isComplete) return

        val pixelCount = width * height
        val uploadStartNs = System.nanoTime()
        val packed = acquireCpuMaskScratchBuffer(pixelCount)
        when (frame.format) {
            DuetSegmentationMaskFormat.FLOAT32_CONFIDENCE -> {
                val src = frame.maskBytes.asReadOnlyBuffer().order(ByteOrder.nativeOrder())
                src.rewind()
                for (i in 0 until pixelCount) {
                    val byteOffset = i * 4
                    val value = if (src.limit() >= byteOffset + 4) src.getFloat(byteOffset) else 0f
                    packed.put((value.coerceIn(0f, 1f) * 255f).toInt().toByte())
                }
            }
            DuetSegmentationMaskFormat.UINT8_ALPHA -> {
                val src = frame.maskBytes.asReadOnlyBuffer()
                src.rewind()
                if (src.capacity() < pixelCount) return
                src.limit(pixelCount)
                packed.put(src)
            }
        }
        packed.rewind()

        try {
            val success = VanguardNativeBridge.updateAndroidDuetVulkanPreviewMask(nativeSessionHandle, packed, width, height)
            if (success && maskUploadLoggedOnce.compareAndSet(false, true)) {
                Log.i(
                    TAG,
                    "ANDROID_DUET_VULKAN_MASK_UPLOAD_FIRST width=$width height=$height " +
                        "format=${frame.format.name.lowercase()}",
                )
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Exception updating native Vulkan preview mask", t)
        } finally {
            val uploadLatencyMs = (System.nanoTime() - uploadStartNs) / 1_000_000L
            cpuMaskUploadCount += 1
            totalCpuMaskUploadLatencyMs += uploadLatencyMs
            if (uploadLatencyMs > maxCpuMaskUploadLatencyMs) maxCpuMaskUploadLatencyMs = uploadLatencyMs
        }
    }

    /**
     * GPU-resident mask update: imports [hardwareBuffer] into the native
     * session as the current GPU mask via the existing Vulkan
     * AHardwareBuffer import path, so the green-screen compositor can render
     * from it directly without a CPU mask upload. Runs synchronously on the
     * calling thread (the render thread, per [AndroidDuetPreviewRenderLoop]'s
     * posting discipline), matching [updateGreenScreenMask].
     *
     * Ownership contract: [hardwareBuffer] is ALWAYS consumed by this call.
     * On success it replaces (and closes) the previously held GPU mask
     * buffer, since native has already released its Vulkan import of that
     * one in favor of the new one. On failure — including when the fallback
     * GLES delegate is active, since it has no GPU-mask seam — [hardwareBuffer]
     * never became native-owned, so it is closed here immediately; any
     * previously valid GPU mask (native-held) and the CPU-uploaded mask are
     * both left untouched.
     */
    override fun updateGreenScreenMaskHardwareBuffer(
        hardwareBuffer: HardwareBuffer,
        widthPx: Int,
        heightPx: Int,
        timestampUs: Long,
        onReleased: ((HardwareBuffer) -> Unit)?,
        acquireFenceFd: Int,
    ) {
        fallbackDelegate?.let {
            it.updateGreenScreenMaskHardwareBuffer(
                hardwareBuffer, widthPx, heightPx, timestampUs, onReleased, acquireFenceFd,
            )
            return
        }
        if (greenScreenDebugView == "mask_full_white") {
            // ANDROID-DUET-VULKAN-WHITE-MASK-DEBUG: ignore the incoming GPU
            // mask entirely — never import it — so it cannot override the
            // forced white CPU mask while the diagnostic is active, then
            // re-assert the white mask in case native's current mask source
            // was somehow left as something else.
            closeFenceFdQuietly(acquireFenceFd)
            releaseGpuMaskBuffer(hardwareBuffer, onReleased)
            uploadWhiteMaskForDebug()
            return
        }
        if (nativeSessionHandle == 0L || widthPx <= 0 || heightPx <= 0) {
            closeFenceFdQuietly(acquireFenceFd)
            releaseGpuMaskBuffer(hardwareBuffer, onReleased)
            return
        }

        val importStartNs = System.nanoTime()
        val success = try {
            VanguardNativeBridge.updateAndroidDuetVulkanPreviewGpuMask(
                nativeSessionHandle, hardwareBuffer, widthPx, heightPx,
                hardwareBuffer.format, timestampUs, acquireFenceFd,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "Exception updating native Vulkan preview GPU mask", t)
            closeFenceFdQuietly(acquireFenceFd)
            false
        }
        val importLatencyMs = (System.nanoTime() - importStartNs) / 1_000_000L
        gpuMaskImportCount += 1
        totalGpuMaskImportLatencyMs += importLatencyMs
        if (importLatencyMs > maxGpuMaskImportLatencyMs) maxGpuMaskImportLatencyMs = importLatencyMs

        if (success) {
            val previous = gpuMaskBuffer
            val previousRelease = gpuMaskReleaseCallback
            gpuMaskBuffer = hardwareBuffer
            gpuMaskReleaseCallback = onReleased
            if (previous != null) releaseGpuMaskBuffer(previous, previousRelease)
            if (gpuMaskUploadLoggedOnce.compareAndSet(false, true)) {
                Log.i(TAG, "ANDROID_DUET_VULKAN_GPU_MASK_UPLOAD_FIRST width=$widthPx height=$heightPx")
            }
        } else {
            releaseGpuMaskBuffer(hardwareBuffer, onReleased)
        }
    }

    /**
     * Always drains both readers first (latest-wins latch; the previous
     * Image is closed only once a newer one is acquired) to keep the
     * decoder/camera producers from stalling, regardless of attach or
     * green-screen state. Renders only when attached and both a decoder and
     * a camera frame have been latched at least once:
     *   * green-screen enabled: native mask composite (the native session
     *     always has a valid mask handle — a default 1x1 zero mask from
     *     session creation until the first real segmentation mask arrives);
     *   * green-screen enabled with [setGreenScreenBackgroundMode]
     *     "solid_teal" (ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND,
     *     RND diagnostic only): native camera-only static-background
     *     composite that requires only a latched CAMERA frame — the decoder
     *     reader is still drained above but its latched Image is neither
     *     required nor touched;
     *   * green-screen disabled (ANDROID-DUET-VULKAN-LAYOUT: PiP / split /
     *     green-screen terminal fallback): native opaque two-layer layout
     *     frame using the latest [setLayout] rects, rounded and clamped to
     *     the attached canvas; an unset or invalid rect fails this draw
     *     (false, nothing rendered, no crash) rather than reaching native.
     */
    override fun drawFrame(): Boolean {
        if (isReleased) return false
        fallbackDelegate?.let { return it.drawFrame() }

        if (nativeSessionHandle == 0L) return false

        latchDecoderImageIfAvailable()
        latchCameraImageIfAvailable()

        if (!isAttached) return false

        val canvasWidth = outputWidthPx
        val canvasHeight = outputHeightPx
        if (canvasWidth <= 0 || canvasHeight <= 0) return false

        // ANDROID-DUET-VULKAN-CAMERA-PASSTHROUGH-DEBUG: when the diagnostic
        // is active, drive native with greenScreenEnabled=false so it draws
        // source + opaque camera layout (no mask) instead of the masked
        // composite, isolating camera transform/crop from mask alpha. Does
        // not affect production behavior when the debug view is unset.
        val cameraPassthroughDebugActive =
            greenScreenEnabled && greenScreenDebugView == "camera_passthrough"
        val nativeGreenScreen = greenScreenEnabled && !cameraPassthroughDebugActive

        // Resolve the layout rects before touching any HardwareBuffer so an
        // invalid layout never costs a wrapper open/close. The green-screen
        // path is full-canvas and ignores the rects natively, so it falls
        // back to the full canvas instead of failing when they are unset.
        val nativeSourceRect: NativeLayoutRect
        val nativeCameraRect: NativeLayoutRect
        if (nativeGreenScreen) {
            val fullCanvas = NativeLayoutRect(0, 0, canvasWidth, canvasHeight)
            nativeSourceRect = sourceRect?.let { toNativeLayoutRect(it, canvasWidth, canvasHeight) } ?: fullCanvas
            // ANDROID-DUET-VULKAN-GREENSCREEN-FREE-TRANSFORM: the foreground
            // camera rect is intentionally NOT clamped to the canvas here --
            // see toNativeForegroundRect. Native clips the scissor to the
            // canvas and fails closed if nothing remains on-canvas.
            nativeCameraRect = cameraRect?.let { toNativeForegroundRect(it) } ?: fullCanvas
        } else {
            val source = sourceRect?.let { toNativeLayoutRect(it, canvasWidth, canvasHeight) }
            val camera = cameraRect?.let { toNativeLayoutRect(it, canvasWidth, canvasHeight) }
            if (source == null || camera == null) {
                if (invalidLayoutRectLoggedOnce.compareAndSet(false, true)) {
                    Log.w(
                        TAG,
                        "drawFrame skipped: invalid layout rect for ${canvasWidth}x$canvasHeight canvas " +
                            "(source=$sourceRect camera=$cameraRect)",
                    )
                }
                return false
            }
            nativeSourceRect = source
            nativeCameraRect = camera
        }

        // ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND: RND camera-only
        // path. Branches before the decoder latch requirement below so a
        // green-screen frame no longer waits on (or reads) a decoded source
        // frame; everything above -- reader draining, attach/canvas checks,
        // camera_passthrough precedence and the full-canvas rect fallback --
        // is shared with the production path unchanged.
        if (nativeGreenScreen &&
            greenScreenBackgroundMode == GREEN_SCREEN_BACKGROUND_MODE_SOLID_TEAL
        ) {
            return drawStaticBackgroundGreenScreenFrame(canvasWidth, canvasHeight, nativeCameraRect)
        }

        val decoderImage = latchedDecoderImage ?: return false
        val cameraImage = latchedCameraImage ?: return false
        val decoderBuffer = decoderImage.hardwareBuffer ?: return false
        val cameraBuffer = cameraImage.hardwareBuffer
        if (cameraBuffer == null) {
            try {
                decoderBuffer.close()
            } catch (_: Throwable) {}
            return false
        }

        // ANDROID-DUET-VULKAN-CAMERA-CONTENT-DIMENSIONS: the decoder Image's
        // own width/height reflect the ImageReader's requested logical
        // content size, so they are used directly. The camera path is on a
        // PRIVATE-format ImageReader, where Image.width/height are NOT
        // trustworthy: they can reflect the consumer/allocator's padded
        // allocation (e.g. a larger square buffer than the requested
        // content size) rather than the requested content size, which would
        // distort the aspect-fill crop if used for geometry. The camera
        // content dimensions therefore come from the compositor's own
        // requested reader size (CAMERA_DEFAULT_WIDTH/HEIGHT, landscape
        // 1920x1080) instead of cameraImage.width/height. These are raw,
        // pre-rotation logical reader dimensions: native's
        // ResolveVulkanDuetLayoutLayerPlacement is responsible for swapping
        // width/height when cameraRotationDegrees is 90/270 before the
        // aspect-fill crop, so this pair must always be passed unswapped.
        // Both pairs are threaded into native as the preferred crop
        // dimensions, with the AHB descriptor kept only as native's
        // fallback/diagnostic when a pair is non-positive.
        val decoderContentWidth = decoderImage.width
        val decoderContentHeight = decoderImage.height
        val cameraContentWidth = CAMERA_DEFAULT_WIDTH
        val cameraContentHeight = CAMERA_DEFAULT_HEIGHT

        // decoderBuffer/cameraBuffer are temporary HardwareBuffer wrappers distinct
        // from latchedDecoderImage/latchedCameraImage; they must be closed here
        // regardless of native outcome, without touching the latched Images.
        return try {
            val greenScreen = nativeGreenScreen
            val debugMode = nativeGreenScreenDebugMode(greenScreenDebugView)
            val success = VanguardNativeBridge.renderAndroidDuetVulkanPreviewFrame(
                nativeSessionHandle, decoderBuffer, cameraBuffer,
                greenScreen,
                nativeSourceRect.x, nativeSourceRect.y, nativeSourceRect.width, nativeSourceRect.height,
                nativeCameraRect.x, nativeCameraRect.y, nativeCameraRect.width, nativeCameraRect.height,
                sourceVideoRotationDegrees, cameraRotationDegrees, cameraMirrorHorizontal,
                decoderContentWidth, decoderContentHeight, cameraContentWidth, cameraContentHeight,
                debugMode,
                foregroundRotationDegrees, foregroundAnchorX, foregroundAnchorY,
            )
            if (success && greenScreen && previewFrameLoggedOnce.compareAndSet(false, true)) {
                Log.i(
                    TAG,
                    "ANDROID_DUET_VULKAN_PREVIEW_FRAME_FIRST " +
                        "sourceContent=${decoderContentWidth}x$decoderContentHeight " +
                        "cameraContent=${cameraContentWidth}x$cameraContentHeight",
                )
            }
            if (success && !greenScreen && layoutFrameLoggedOnce.compareAndSet(false, true)) {
                Log.i(
                    TAG,
                    "ANDROID_DUET_VULKAN_LAYOUT_FRAME_FIRST canvas=${canvasWidth}x$canvasHeight " +
                        "source=${nativeSourceRect.x},${nativeSourceRect.y} " +
                        "${nativeSourceRect.width}x${nativeSourceRect.height} " +
                        "camera=${nativeCameraRect.x},${nativeCameraRect.y} " +
                        "${nativeCameraRect.width}x${nativeCameraRect.height} " +
                        "sourceContent=${decoderContentWidth}x$decoderContentHeight " +
                        "cameraContent=${cameraContentWidth}x$cameraContentHeight",
                )
            }
            success
        } catch (t: Throwable) {
            Log.w(TAG, "Exception rendering native Vulkan preview frame", t)
            false
        } finally {
            try {
                decoderBuffer.close()
            } catch (_: Throwable) {}
            try {
                cameraBuffer.close()
            } catch (_: Throwable) {}
        }
    }

    /**
     * ANDROID-DUET-VULKAN-GREENSCREEN-STATIC-BACKGROUND (RND diagnostic
     * only): the camera-only branch of [drawFrame]. Requires only a latched
     * camera frame; the camera content dimensions, rotation, mirror and
     * shader debugMode are resolved exactly as the production green-screen
     * branch resolves them (see ANDROID-DUET-VULKAN-CAMERA-CONTENT-DIMENSIONS
     * there), and [nativeCameraRect] is the same rounded/clamped or
     * full-canvas rect. The temporary camera HardwareBuffer wrapper is closed
     * here regardless of native outcome, without touching the latched Image.
     */
    private fun drawStaticBackgroundGreenScreenFrame(
        canvasWidth: Int,
        canvasHeight: Int,
        nativeCameraRect: NativeLayoutRect,
    ): Boolean {
        val cameraImage = latchedCameraImage ?: return false
        val cameraBuffer = cameraImage.hardwareBuffer ?: return false
        val cameraContentWidth = CAMERA_DEFAULT_WIDTH
        val cameraContentHeight = CAMERA_DEFAULT_HEIGHT
        return try {
            val debugMode = nativeGreenScreenDebugMode(greenScreenDebugView)
            val success = VanguardNativeBridge.renderAndroidDuetVulkanPreviewStaticBackgroundFrame(
                nativeSessionHandle, cameraBuffer,
                nativeCameraRect.x, nativeCameraRect.y, nativeCameraRect.width, nativeCameraRect.height,
                cameraRotationDegrees, cameraMirrorHorizontal,
                cameraContentWidth, cameraContentHeight,
                debugMode,
                NATIVE_GREEN_SCREEN_STATIC_BACKGROUND_SOLID_TEAL,
                foregroundRotationDegrees, foregroundAnchorX, foregroundAnchorY,
            )
            if (success && staticBackgroundFrameLoggedOnce.compareAndSet(false, true)) {
                Log.i(
                    TAG,
                    "ANDROID_DUET_VULKAN_STATIC_BACKGROUND_PREVIEW_FRAME_FIRST " +
                        "canvas=${canvasWidth}x$canvasHeight " +
                        "camera=${nativeCameraRect.x},${nativeCameraRect.y} " +
                        "${nativeCameraRect.width}x${nativeCameraRect.height} " +
                        "cameraContent=${cameraContentWidth}x$cameraContentHeight " +
                        "backgroundMode=$GREEN_SCREEN_BACKGROUND_MODE_SOLID_TEAL " +
                        "debugMode=$debugMode",
                )
            }
            success
        } catch (t: Throwable) {
            Log.w(TAG, "Exception rendering native Vulkan static-background preview frame", t)
            false
        } finally {
            try {
                cameraBuffer.close()
            } catch (_: Throwable) {}
        }
    }

    private fun latchDecoderImageIfAvailable() {
        if (!decoderFramePending.compareAndSet(true, false)) return
        val next = try {
            decoderReader?.acquireLatestImage()
        } catch (t: Throwable) {
            Log.w(TAG, "acquireLatestImage(decoder) threw", t)
            null
        }
        if (next != null) {
            try {
                latchedDecoderImage?.close()
            } catch (_: Throwable) {}
            latchedDecoderImage = next
        }
    }

    private fun latchCameraImageIfAvailable() {
        if (!cameraFramePending.compareAndSet(true, false)) return
        val next = try {
            cameraReader?.acquireLatestImage()
        } catch (t: Throwable) {
            Log.w(TAG, "acquireLatestImage(camera) threw", t)
            null
        }
        if (next != null) {
            try {
                latchedCameraImage?.close()
            } catch (_: Throwable) {}
            latchedCameraImage = next
        }
    }

    override fun release() {
        if (isReleased) return
        isReleased = true

        fallbackDelegate?.release()
        fallbackDelegate = null

        try {
            latchedDecoderImage?.close()
        } catch (_: Throwable) {}
        latchedDecoderImage = null

        try {
            latchedCameraImage?.close()
        } catch (_: Throwable) {}
        latchedCameraImage = null

        gpuMaskBuffer?.let { releaseGpuMaskBuffer(it, gpuMaskReleaseCallback) }
        gpuMaskBuffer = null
        gpuMaskReleaseCallback = null

        val meanGpuMaskImportLatencyMs =
            if (gpuMaskImportCount > 0) totalGpuMaskImportLatencyMs / gpuMaskImportCount else 0
        Log.i(
            TAG,
            "ANDROID_DUET_VULKAN_GPU_MASK_IMPORT_SUMMARY " +
                "count=$gpuMaskImportCount meanLatencyMs=$meanGpuMaskImportLatencyMs " +
                "maxLatencyMs=$maxGpuMaskImportLatencyMs",
        )

        val meanCpuMaskUploadLatencyMs =
            if (cpuMaskUploadCount > 0) totalCpuMaskUploadLatencyMs / cpuMaskUploadCount else 0
        Log.i(
            TAG,
            "ANDROID_DUET_VULKAN_CPU_MASK_UPLOAD_SUMMARY " +
                "count=$cpuMaskUploadCount meanTotalMs=$meanCpuMaskUploadLatencyMs " +
                "maxTotalMs=$maxCpuMaskUploadLatencyMs allocations=$cpuMaskScratchAllocationCount " +
                "scratchCapacity=${cpuMaskScratchBuffer?.capacity() ?: 0}",
        )
        cpuMaskScratchBuffer = null

        try {
            cameraReader?.close()
        } catch (_: Throwable) {}
        cameraReader = null

        try {
            decoderReader?.close()
        } catch (_: Throwable) {}
        decoderReader = null

        if (nativeSessionHandle != 0L) {
            if (isAttached) {
                try {
                    VanguardNativeBridge.detachAndroidDuetVulkanPreviewSurface(nativeSessionHandle)
                } catch (_: Throwable) {}
                isAttached = false
                outputWidthPx = 0
                outputHeightPx = 0
            }
            try {
                VanguardNativeBridge.destroyAndroidDuetVulkanPreviewSession(nativeSessionHandle)
            } catch (_: Throwable) {}
            nativeSessionHandle = 0L
        }
    }

    private fun releaseGpuMaskBuffer(
        hardwareBuffer: HardwareBuffer,
        onReleased: ((HardwareBuffer) -> Unit)?,
    ) {
        if (onReleased != null) {
            onReleased(hardwareBuffer)
        } else {
            try { hardwareBuffer.close() } catch (_: Throwable) {}
        }
    }

    private fun closeFenceFdQuietly(fd: Int) {
        if (fd < 0) return
        try {
            ParcelFileDescriptor.adoptFd(fd).close()
        } catch (_: Throwable) {}
    }
}
