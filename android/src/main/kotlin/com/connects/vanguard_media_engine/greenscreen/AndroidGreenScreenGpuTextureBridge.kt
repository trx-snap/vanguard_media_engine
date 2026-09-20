package com.connects.vanguard_media_engine.greenscreen

import android.hardware.HardwareBuffer
import android.os.Build
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge

/**
 * P5-ANDROID-GREENSCREEN-GPU-TEXTURE-BRIDGE: owns a native EGL context sized to the
 * requested width/height. [resolveCameraHardwareBufferToRgbaTexture] and
 * [copyTexture2dToHardwareBuffer] call through to the corresponding native
 * AHardwareBuffer import/shader implementations. Every public method catches
 * Throwable and returns a closed-state value (0/false/null) rather than
 * propagating.
 *
 * RND texture-slot pool: native owns a fixed pool of 3 RGBA output textures.
 * Every non-zero texture name returned by
 * [resolveCameraHardwareBufferToRgbaTexture] is an in-use pool slot that must
 * be handed back through [releaseResolvedTexture] once its consumer is done
 * (MediaPipe's TextureReleaseCallback); native never overwrites an in-use
 * slot and returns 0 instead when the pool is exhausted. [releaseResolvedTexture]
 * and [close] may race from different threads: [nativeHandle]/[isClosed] are
 * volatile and native ignores releases against a destroyed handle.
 */
// Note: Calls shared legacy Duet native symbol names in VanguardNativeBridge for this slice.
class AndroidGreenScreenGpuTextureBridge private constructor(@Volatile private var nativeHandle: Long) {
    companion object {
        private const val TAG = "GreenScreenGpuTexBridge"
        const val COPY_FAILED_FENCE_FD = -2

        fun open(width: Int, height: Int): AndroidGreenScreenGpuTextureBridge? {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                Log.w(TAG, "open rejected: API ${Build.VERSION.SDK_INT} < Q")
                return null
            }
            if (width <= 0 || height <= 0) return null
            val handle = try {
                VanguardNativeBridge.createAndroidDuetGpuTextureBridge(width, height)
            } catch (t: Throwable) {
                Log.e(TAG, "Exception creating native GPU texture bridge", t)
                0L
            }
            if (handle == 0L) return null
            return AndroidGreenScreenGpuTextureBridge(handle)
        }
    }

    @Volatile private var isClosed = false

    val isValid: Boolean
        get() = !isClosed && nativeHandle != 0L

    fun parentGlContext(): Long {
        if (isClosed || nativeHandle == 0L) return 0L
        return try {
            VanguardNativeBridge.getAndroidDuetGpuTextureBridgeParentGlContext(nativeHandle)
        } catch (t: Throwable) {
            Log.w(TAG, "Exception reading parent GL context", t)
            0L
        }
    }

    fun resolveCameraHardwareBufferToRgbaTexture(
        cameraHardwareBuffer: HardwareBuffer,
        width: Int,
        height: Int,
        timestampUs: Long,
    ): Int {
        if (isClosed || nativeHandle == 0L) return 0
        return try {
            VanguardNativeBridge.resolveAndroidDuetCameraHardwareBufferToRgbaTexture(
                nativeHandle, cameraHardwareBuffer, width, height, timestampUs,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "Exception resolving camera HardwareBuffer to RGBA texture", t)
            0
        }
    }

    /**
     * Returns the pool slot behind [textureName] (a non-zero result of
     * [resolveCameraHardwareBufferToRgbaTexture]) to the free state so a
     * later resolve may redraw it. Call exactly once per resolved texture,
     * from any thread, once its consumer has finished reading it. Safe after
     * [close] and for unknown names (returns false, no-op).
     */
    fun releaseResolvedTexture(textureName: Int): Boolean {
        if (textureName <= 0) return false
        val handle = nativeHandle
        if (isClosed || handle == 0L) return false
        return try {
            VanguardNativeBridge.releaseAndroidDuetGpuTextureBridgeResolvedTexture(handle, textureName)
        } catch (t: Throwable) {
            Log.w(TAG, "Exception releasing resolved texture slot", t)
            false
        }
    }

    fun createMaskHardwareBuffer(width: Int, height: Int): HardwareBuffer? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        if (width <= 0 || height <= 0) return null
        return try {
            HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_GPU_COLOR_OUTPUT,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "Exception creating mask HardwareBuffer", t)
            null
        }
    }

    fun copyTexture2dToHardwareBuffer(
        textureName: Int,
        width: Int,
        height: Int,
        targetHardwareBuffer: HardwareBuffer,
    ): Boolean {
        if (isClosed || nativeHandle == 0L) return false
        return try {
            VanguardNativeBridge.copyAndroidDuetTextureToHardwareBuffer(
                nativeHandle, textureName, width, height, targetHardwareBuffer,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "Exception copying texture to HardwareBuffer", t)
            false
        }
    }

    fun copyTexture2dToHardwareBufferAcquireFenceFd(
        textureName: Int,
        width: Int,
        height: Int,
        targetHardwareBuffer: HardwareBuffer,
    ): Int {
        if (isClosed || nativeHandle == 0L) return COPY_FAILED_FENCE_FD
        return try {
            VanguardNativeBridge.copyAndroidDuetTextureToHardwareBufferAcquireFenceFd(
                nativeHandle, textureName, width, height, targetHardwareBuffer,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "Exception copying texture to HardwareBuffer acquire fence", t)
            COPY_FAILED_FENCE_FD
        }
    }

    fun close() {
        if (isClosed) return
        isClosed = true
        val handle = nativeHandle
        nativeHandle = 0L
        if (handle != 0L) {
            try {
                VanguardNativeBridge.destroyAndroidDuetGpuTextureBridge(handle)
            } catch (t: Throwable) {
                Log.w(TAG, "Exception destroying native GPU texture bridge", t)
            }
        }
    }
}
