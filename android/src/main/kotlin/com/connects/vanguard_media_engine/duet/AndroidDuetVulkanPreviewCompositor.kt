package com.connects.vanguard_media_engine.duet

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.os.Build
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
        private const val CAMERA_DEFAULT_WIDTH = 1080
        private const val CAMERA_DEFAULT_HEIGHT = 1920
        private const val DECODER_DEFAULT_WIDTH = 1080
        private const val DECODER_DEFAULT_HEIGHT = 1920

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

    private var sourceVideoWidthPx = 0
    private var sourceVideoHeightPx = 0

    // One-shot diagnostic logs, emitted only after the corresponding native
    // call reports success for the first time (never on a false/failed call).
    private val maskUploadLoggedOnce = AtomicBoolean(false)
    private val previewFrameLoggedOnce = AtomicBoolean(false)
    private val layoutFrameLoggedOnce = AtomicBoolean(false)
    // Rate limit for the invalid-layout-rect warning (drawFrame runs ~30 fps).
    private val invalidLayoutRectLoggedOnce = AtomicBoolean(false)

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

    override fun setGreenScreenEnabled(enabled: Boolean) {
        fallbackDelegate?.let {
            it.setGreenScreenEnabled(enabled)
            return
        }
        greenScreenEnabled = enabled
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
        if (nativeSessionHandle == 0L) return
        val width = frame.width
        val height = frame.height
        if (width <= 0 || height <= 0 || !frame.isComplete) return

        val pixelCount = width * height
        val packed = ByteBuffer.allocateDirect(pixelCount)
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

        // Resolve the layout rects before touching any HardwareBuffer so an
        // invalid layout never costs a wrapper open/close. The green-screen
        // path is full-canvas and ignores the rects natively, so it falls
        // back to the full canvas instead of failing when they are unset.
        val nativeSourceRect: NativeLayoutRect
        val nativeCameraRect: NativeLayoutRect
        if (greenScreenEnabled) {
            val fullCanvas = NativeLayoutRect(0, 0, canvasWidth, canvasHeight)
            nativeSourceRect = sourceRect?.let { toNativeLayoutRect(it, canvasWidth, canvasHeight) } ?: fullCanvas
            nativeCameraRect = cameraRect?.let { toNativeLayoutRect(it, canvasWidth, canvasHeight) } ?: fullCanvas
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

        // decoderBuffer/cameraBuffer are temporary HardwareBuffer wrappers distinct
        // from latchedDecoderImage/latchedCameraImage; they must be closed here
        // regardless of native outcome, without touching the latched Images.
        return try {
            val greenScreen = greenScreenEnabled
            val success = VanguardNativeBridge.renderAndroidDuetVulkanPreviewFrame(
                nativeSessionHandle, decoderBuffer, cameraBuffer,
                greenScreen,
                nativeSourceRect.x, nativeSourceRect.y, nativeSourceRect.width, nativeSourceRect.height,
                nativeCameraRect.x, nativeCameraRect.y, nativeCameraRect.width, nativeCameraRect.height,
                0, 0, false,
            )
            if (success && greenScreen && previewFrameLoggedOnce.compareAndSet(false, true)) {
                Log.i(TAG, "ANDROID_DUET_VULKAN_PREVIEW_FRAME_FIRST")
            }
            if (success && !greenScreen && layoutFrameLoggedOnce.compareAndSet(false, true)) {
                Log.i(
                    TAG,
                    "ANDROID_DUET_VULKAN_LAYOUT_FRAME_FIRST canvas=${canvasWidth}x$canvasHeight " +
                        "source=${nativeSourceRect.x},${nativeSourceRect.y} " +
                        "${nativeSourceRect.width}x${nativeSourceRect.height} " +
                        "camera=${nativeCameraRect.x},${nativeCameraRect.y} " +
                        "${nativeCameraRect.width}x${nativeCameraRect.height}",
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
}
