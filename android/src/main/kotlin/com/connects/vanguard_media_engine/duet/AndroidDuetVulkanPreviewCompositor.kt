package com.connects.vanguard_media_engine.duet

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.ImageReader
import android.os.Build
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge

class AndroidDuetVulkanPreviewCompositor : AndroidDuetPreviewBackend {
    companion object {
        private const val TAG = "DuetVulkanComp"
        private const val CAMERA_DEFAULT_WIDTH = 1080
        private const val CAMERA_DEFAULT_HEIGHT = 1920
        private const val DECODER_DEFAULT_WIDTH = 1080
        private const val DECODER_DEFAULT_HEIGHT = 1920
    }

    private var nativeSessionHandle: Long = 0
    private var isReleased = false
    private var isAttached = false

    private var cameraReader: ImageReader? = null
    private var decoderReader: ImageReader? = null

    private var fallbackDelegate: AndroidDuetPreviewCompositor? = null
    private var isBound = false

    private var sourceVideoWidthPx = 0
    private var sourceVideoHeightPx = 0

    override val cameraInputSurface: Surface?
        get() = fallbackDelegate?.cameraInputSurface ?: cameraReader?.surface

    override val decoderInputSurface: Surface?
        get() = fallbackDelegate?.decoderInputSurface ?: decoderReader?.surface

    override val hasPendingSourceFrame: Boolean
        get() = fallbackDelegate?.hasPendingSourceFrame ?: false

    override val hasPendingCameraFrame: Boolean
        get() = fallbackDelegate?.hasPendingCameraFrame ?: false

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
                val usage = HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_GPU_COLOR_OUTPUT
                if (cameraReader == null) {
                    cameraReader = ImageReader.newInstance(
                        CAMERA_DEFAULT_WIDTH,
                        CAMERA_DEFAULT_HEIGHT,
                        ImageFormat.PRIVATE,
                        3,
                        usage,
                    )
                }
                if (decoderReader == null) {
                    decoderReader = ImageReader.newInstance(
                        DECODER_DEFAULT_WIDTH,
                        DECODER_DEFAULT_HEIGHT,
                        ImageFormat.PRIVATE,
                        3,
                        usage,
                    )
                }
                isBound = true
                isAttached = true
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
            try {
                VanguardNativeBridge.detachAndroidDuetVulkanPreviewSurface(nativeSessionHandle)
            } catch (t: Throwable) {
                Log.w(TAG, "Exception during native detachOutputSurface", t)
            }
        }
    }

    override fun setLayout(sourceRect: VGDuetPixelRect, cameraRect: VGDuetPixelRect) {
        fallbackDelegate?.let {
            it.setLayout(sourceRect, cameraRect)
            return
        }
        // Retained for layout; foundation-only (not plumbed to native in this slice)
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
    }

    override fun updateGreenScreenMask(frame: AndroidDuetSegmentationFrame) {
        fallbackDelegate?.let {
            it.updateGreenScreenMask(frame)
            return
        }
    }

    /**
     * Foundation-only preview backend: does not present real frames yet.
     * Drains incoming camera and decoder images to prevent pipeline stalls,
     * but returns false to honestly indicate non-presenting foundation status.
     * No diagnostic per-frame JNI path is used.
     */
    override fun drawFrame(): Boolean {
        if (isReleased) return false
        fallbackDelegate?.let { return it.drawFrame() }

        if (nativeSessionHandle == 0L) return false

        try {
            cameraReader?.acquireLatestImage()?.close()
        } catch (_: Throwable) {}

        try {
            decoderReader?.acquireLatestImage()?.close()
        } catch (_: Throwable) {}

        Log.w(
            TAG,
            "drawFrame(): foundation-only non-presenting backend (real Vulkan compositing deferred to future slice)",
        )
        return false
    }

    override fun release() {
        if (isReleased) return
        isReleased = true

        fallbackDelegate?.release()
        fallbackDelegate = null

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
            }
            try {
                VanguardNativeBridge.destroyAndroidDuetVulkanPreviewSession(nativeSessionHandle)
            } catch (_: Throwable) {}
            nativeSessionHandle = 0L
        }
    }
}
