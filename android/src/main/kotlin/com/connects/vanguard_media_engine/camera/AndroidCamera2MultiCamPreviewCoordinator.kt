package com.connects.vanguard_media_engine.camera

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * P3-CAM-CONCURRENT-STARTMULTICAM-FAIL-CLOSED-ANDROID-HANDLER: owns the public
 * Dart VGCameraSession routes "startMultiCamPreview" / "stopMultiCamPreview"
 * as explicit fail-closed guard routes.
 *
 * Non-claims (read before touching this file):
 *  - This slice does NOT implement real Android concurrent camera capture.
 *    No camera is opened, no TextureRegistry/SurfaceTexture is allocated, and
 *    no capture session is created by either route.
 *  - Hardware/device-id combinations that Camera2's read-only
 *    [AndroidCamera2CapabilityProbe] reports as concurrent-capable still fail
 *    closed with CONCURRENT_PREVIEW_NOT_READY, because this package has no
 *    production Android concurrent-preview lifecycle owner yet. A fake
 *    texture/session is never returned.
 *  - stopMultiCamPreview is an idempotent no-op success: there is no Android
 *    multicam preview session in this slice, so it never touches the
 *    single-camera [hasActiveSingleCamera] state.
 *
 * Capability lookups go through [AndroidCamera2CapabilityProbe.probe], which
 * only calls CameraManager.getCameraIdList / getCameraCharacteristics /
 * concurrentCameraIds -- it never opens a camera.
 */
class AndroidCamera2MultiCamPreviewCoordinator(
    private val context: Context,
    private val hasActiveSingleCamera: () -> Boolean,
) {
    companion object {
        private const val TAG = "AndroidCamera2MultiCamPreviewCoordinator"

        private val OWNED_METHODS = setOf(
            "startMultiCamPreview",
            "stopMultiCamPreview",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    fun handle(method: String, args: Map<String, Any?>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "startMultiCamPreview" -> startMultiCamPreview(args, result)
            "stopMultiCamPreview" -> stopMultiCamPreview(result)
            else -> return false
        }
        return true
    }

    // -- startMultiCamPreview -------------------------------------------------

    private fun startMultiCamPreview(args: Map<String, Any?>?, result: MethodChannel.Result) {
        val frontDeviceId = (args?.get("frontDeviceId") as? String)?.trim()
        val backDeviceId = (args?.get("backDeviceId") as? String)?.trim()
        if (frontDeviceId.isNullOrEmpty() || backDeviceId.isNullOrEmpty()) {
            result.error(
                "INVALID_ARG",
                "startMultiCamPreview requires non-blank frontDeviceId and backDeviceId",
                null,
            )
            return
        }

        if (hasActiveSingleCamera()) {
            result.error(
                "CAMERA_ACTIVE",
                "A single-camera session is active; stop it before starting a multi-cam preview",
                null,
            )
            return
        }

        val probeResult = try {
            AndroidCamera2CapabilityProbe(context).probe()
        } catch (t: Throwable) {
            Log.w(TAG, "startMultiCamPreview: probe failed: ${t.javaClass.simpleName}: ${t.message}")
            result.error(
                "CONCURRENT_NOT_SUPPORTED",
                "Unable to determine concurrent camera capability: ${t.message}",
                null,
            )
            return
        }

        val supportsConcurrentCamera = probeResult["supportsConcurrentCamera"] as? Boolean ?: false
        @Suppress("UNCHECKED_CAST")
        val concurrentCameraIdSets =
            probeResult["concurrentCameraIdSets"] as? List<List<String>> ?: emptyList()

        val matchingSet = concurrentCameraIdSets.firstOrNull { idSet ->
            idSet.contains(frontDeviceId) && idSet.contains(backDeviceId)
        }

        if (!supportsConcurrentCamera || matchingSet == null) {
            result.error(
                "CONCURRENT_NOT_SUPPORTED",
                "No concurrent camera combination supports frontDeviceId=$frontDeviceId " +
                    "and backDeviceId=$backDeviceId on this device",
                mapOf(
                    "supportsConcurrentCamera" to supportsConcurrentCamera,
                    "concurrentCameraIdSets" to concurrentCameraIdSets,
                ),
            )
            return
        }

        // A matching hardware combination exists, but this package has no
        // production Android concurrent-preview lifecycle owner in this
        // slice. Fail closed instead of opening cameras / allocating a
        // texture / creating a capture session for a session nothing drives.
        result.error(
            "CONCURRENT_PREVIEW_NOT_READY",
            "Android production concurrent preview lifecycle is not implemented",
            mapOf(
                "supportsConcurrentCamera" to supportsConcurrentCamera,
                "matchingConcurrentCameraIdSet" to matchingSet,
            ),
        )
    }

    // -- stopMultiCamPreview --------------------------------------------------

    private fun stopMultiCamPreview(result: MethodChannel.Result) {
        // Idempotent no-op: this slice has no active Android multicam preview
        // session to tear down, and this route must never touch the
        // single-camera cameraSource/cameraTexture state owned by the plugin.
        result.success(null)
    }
}
