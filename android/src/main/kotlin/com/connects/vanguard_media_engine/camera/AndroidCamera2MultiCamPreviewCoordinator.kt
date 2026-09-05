package com.connects.vanguard_media_engine.camera

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * P3-CAM-CONCURRENT-STARTMULTICAM-FAIL-CLOSED-ANDROID-HANDLER /
 * P3-CAM-CONCURRENT-MULTICAM-ACTIONS-FAIL-CLOSED-ANDROID-HANDLER: owns the
 * public Dart VGCameraSession MultiCam preview/action routes as explicit
 * fail-closed guard routes.
 *
 * Non-claims (read before touching this file):
 *  - This slice does NOT implement real Android concurrent camera capture,
 *    rendering, photo capture, or recording. No camera is opened, no
 *    TextureRegistry/SurfaceTexture is allocated, no capture session is
 *    created, and no file is written by any route owned here.
 *  - Hardware/device-id combinations that Camera2's read-only
 *    [AndroidCamera2CapabilityProbe] reports as concurrent-capable still fail
 *    closed with CONCURRENT_PREVIEW_NOT_READY, because this package has no
 *    production Android concurrent-preview lifecycle owner yet. A fake
 *    texture/session is never returned.
 *  - stopMultiCamPreview and stopMultiCamRenderDiagnostic are idempotent
 *    no-op successes: there is no Android multicam preview/diagnostic
 *    session in this slice, so neither touches the single-camera
 *    [hasActiveSingleCamera] state.
 *  - updateMultiCamPreviewConfig/takeMultiCamPhoto/startMultiCamRecording/
 *    stopMultiCamRecording all reject with NOT_RUNNING (after arg
 *    validation) because there is never a running Android MultiCam preview
 *    session in this slice to update, photograph, or record.
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
            "runMultiCamRenderDiagnostic",
            "startMultiCamRenderDiagnostic",
            "stopMultiCamRenderDiagnostic",
            "updateMultiCamPreviewConfig",
            "takeMultiCamPhoto",
            "startMultiCamRecording",
            "stopMultiCamRecording",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    fun handle(method: String, args: Map<String, Any?>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "startMultiCamPreview" -> startMultiCamPreviewLikeGuard(args, result)
            "stopMultiCamPreview" -> stopIdempotent(result)
            "runMultiCamRenderDiagnostic" -> startMultiCamPreviewLikeGuard(args, result)
            "startMultiCamRenderDiagnostic" -> startMultiCamPreviewLikeGuard(args, result)
            "stopMultiCamRenderDiagnostic" -> stopIdempotent(result)
            "updateMultiCamPreviewConfig" -> updateMultiCamPreviewConfig(args, result)
            "takeMultiCamPhoto" -> takeMultiCamPhoto(args, result)
            "startMultiCamRecording" -> startMultiCamRecording(args, result)
            "stopMultiCamRecording" -> stopMultiCamRecording(result)
            else -> return false
        }
        return true
    }

    // -- startMultiCamPreview / runMultiCamRenderDiagnostic /
    // -- startMultiCamRenderDiagnostic -----------------------------------------
    //
    // All three routes share the same validation/capability-gated fail-closed
    // start path: no cameras or textures are allocated by any of them.

    private fun startMultiCamPreviewLikeGuard(args: Map<String, Any?>?, result: MethodChannel.Result) {
        val frontDeviceId = (args?.get("frontDeviceId") as? String)?.trim()
        val backDeviceId = (args?.get("backDeviceId") as? String)?.trim()
        if (frontDeviceId.isNullOrEmpty() || backDeviceId.isNullOrEmpty()) {
            result.error(
                "INVALID_ARG",
                "This route requires non-blank frontDeviceId and backDeviceId",
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
            Log.w(TAG, "startMultiCamPreviewLikeGuard: probe failed: ${t.javaClass.simpleName}: ${t.message}")
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

    // -- stopMultiCamPreview / stopMultiCamRenderDiagnostic --------------------

    private fun stopIdempotent(result: MethodChannel.Result) {
        // Idempotent no-op: this slice has no active Android multicam
        // preview/diagnostic session to tear down, and this route must never
        // touch the single-camera cameraSource/cameraTexture state owned by
        // the plugin.
        result.success(null)
    }

    // -- updateMultiCamPreviewConfig -------------------------------------------

    private fun updateMultiCamPreviewConfig(args: Map<String, Any?>?, result: MethodChannel.Result) {
        val config = args?.get("config") as? Map<*, *>
        if (config == null) {
            result.error(
                "INVALID_ARG",
                "updateMultiCamPreviewConfig requires a config map",
                null,
            )
            return
        }

        result.error(
            "NOT_RUNNING",
            "Android MultiCam preview is not running",
            null,
        )
    }

    // -- takeMultiCamPhoto ------------------------------------------------------

    private fun takeMultiCamPhoto(args: Map<String, Any?>?, result: MethodChannel.Result) {
        val path = (args?.get("path") as? String)?.trim()
        if (path.isNullOrEmpty()) {
            result.error(
                "INVALID_ARG",
                "takeMultiCamPhoto requires a non-blank path",
                null,
            )
            return
        }

        result.error(
            "NOT_RUNNING",
            "Android MultiCam preview is not running",
            null,
        )
    }

    // -- startMultiCamRecording ---------------------------------------------------

    private fun startMultiCamRecording(args: Map<String, Any?>?, result: MethodChannel.Result) {
        val path = (args?.get("path") as? String)?.trim()
        if (path.isNullOrEmpty()) {
            result.error(
                "INVALID_ARG",
                "startMultiCamRecording requires a non-blank path",
                null,
            )
            return
        }

        result.error(
            "NOT_RUNNING",
            "Android MultiCam preview is not running",
            null,
        )
    }

    // -- stopMultiCamRecording ------------------------------------------------

    private fun stopMultiCamRecording(result: MethodChannel.Result) {
        result.error(
            "NOT_RUNNING",
            "Android MultiCam preview is not running",
            null,
        )
    }
}
