package com.connects.vanguard_media_engine.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraManager
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.os.Build
import android.util.Log
import android.util.Size
import androidx.annotation.RequiresApi

/**
 * Phase 3-Unit F: read-only Android Camera2 guarded concurrent
 * SessionConfiguration validator.
 *
 * Consumes the Dart Unit E session-configuration plan and, only when the API
 * level and CAMERA permission guards both pass, asks
 * [CameraManager.isConcurrentSessionConfigurationSupported] whether the
 * planned per-camera [SessionConfiguration]s (built from deferred, no-Surface
 * [OutputConfiguration]s) can run concurrently. Never opens a camera, never
 * creates a capture session, never requests a runtime permission, and never
 * allocates a real Surface/SurfaceTexture. Diagnostic/capability foundation
 * only.
 */
class AndroidCamera2ConcurrentSessionValidator(private val context: Context) {

    companion object {
        private const val TAG = "AndroidCamera2ConcurrentSessionValidator"
    }

    fun validate(args: Map<*, *>?): Map<String, Any?> {
        val apiLevel = Build.VERSION.SDK_INT
        val hasCameraPermission = hasCameraPermission()
        val plan = args?.get("plan") as? Map<*, *>
        val selectedConcurrentCameraIds = stringList(plan?.get("selectedConcurrentCameraIds"))
        val surfacePlans = (plan?.get("surfacePlans") as? List<*>)?.mapNotNull { it as? Map<*, *> }
            ?: emptyList()
        val distinctSurfaceCameraIds = surfacePlans
            .mapNotNull { it["cameraId"] as? String }
            .distinct()

        fun result(
            decision: String,
            attempted: Boolean,
            supported: Boolean,
            reasons: List<String>,
            diagnostics: Map<String, Any?> = emptyMap(),
        ): Map<String, Any?> {
            Log.i(
                TAG,
                "decision=$decision attemptedRuntimeValidation=$attempted supported=$supported " +
                    "hasCameraPermission=$hasCameraPermission selectedIdCount=" +
                    "${selectedConcurrentCameraIds.size} surfaceCount=${surfacePlans.size}",
            )
            return mapOf(
                "success" to true,
                "apiLevel" to apiLevel,
                "hasCameraPermission" to hasCameraPermission,
                "attemptedRuntimeValidation" to attempted,
                "supported" to supported,
                "decision" to decision,
                "reasons" to reasons,
                "selectedConcurrentCameraIds" to selectedConcurrentCameraIds,
                "surfacePlanCount" to surfacePlans.size,
                "diagnostics" to diagnostics,
            )
        }

        // Guard 1: API < 30 — isConcurrentSessionConfigurationSupported does not exist.
        if (apiLevel < Build.VERSION_CODES.R) {
            return result(
                decision = "unsupportedApi",
                attempted = false,
                supported = false,
                reasons = listOf("api_below_30"),
            )
        }

        // Guard 2: CAMERA permission absent — never touch OutputConfiguration/openCamera.
        if (!hasCameraPermission) {
            return result(
                decision = "permissionRequired",
                attempted = false,
                supported = false,
                reasons = listOf("camera_permission_absent"),
            )
        }

        // Guard 3: plan is not a concurrent-session candidate.
        if (selectedConcurrentCameraIds.size < 2 || distinctSurfaceCameraIds.size < 2) {
            return result(
                decision = "notCandidate",
                attempted = false,
                supported = false,
                reasons = listOf("session_plan_not_concurrent_candidate"),
            )
        }

        // Guard 4: API < 35 — deferred no-Surface OutputConfiguration/SessionConfiguration
        // constructors are unavailable; no real Surface fallback in this slice.
        if (apiLevel < Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            return result(
                decision = "unsupportedApi",
                attempted = false,
                supported = false,
                reasons = listOf("deferred_session_configuration_requires_api_35"),
            )
        }

        return try {
            validateRuntime(selectedConcurrentCameraIds, surfacePlans, ::result)
        } catch (e: SecurityException) {
            result(
                decision = "permissionRequired",
                attempted = false,
                supported = false,
                reasons = listOf("camera_permission_absent"),
                diagnostics = mapOf(
                    "error" to "${e.javaClass.simpleName}: ${e.message}",
                ),
            )
        } catch (t: Throwable) {
            result(
                decision = "validationFailed",
                attempted = true,
                supported = false,
                reasons = listOf("runtime_validation_threw"),
                diagnostics = mapOf(
                    "error" to "${t.javaClass.simpleName}: ${t.message}",
                ),
            )
        }
    }

    @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    private fun validateRuntime(
        selectedConcurrentCameraIds: List<String>,
        surfacePlans: List<Map<*, *>>,
        result: (String, Boolean, Boolean, List<String>, Map<String, Any?>) -> Map<String, Any?>,
    ): Map<String, Any?> {
        val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
            ?: return result(
                "validationFailed",
                true,
                false,
                listOf("camera_manager_unavailable"),
                emptyMap(),
            )

        val surfacesByCameraId = surfacePlans.groupBy { it["cameraId"] as? String }

        val sessionConfigurationsByCameraId = mutableMapOf<String, SessionConfiguration>()
        for (cameraId in selectedConcurrentCameraIds) {
            val cameraSurfacePlans = surfacesByCameraId[cameraId] ?: emptyList()
            val outputConfigurations = cameraSurfacePlans.mapNotNull { surface ->
                val size = surface["size"] as? Map<*, *>
                val width = (size?.get("width") as? Number)?.toInt()
                val height = (size?.get("height") as? Number)?.toInt()
                if (width == null || height == null) return@mapNotNull null
                OutputConfiguration(ImageFormat.PRIVATE, Size(width, height))
            }
            if (outputConfigurations.isEmpty()) {
                return result(
                    "validationFailed",
                    true,
                    false,
                    listOf("session_plan_missing_output_configurations"),
                    emptyMap(),
                )
            }
            sessionConfigurationsByCameraId[cameraId] = SessionConfiguration(
                SessionConfiguration.SESSION_REGULAR,
                outputConfigurations,
            )
        }

        val supported = cameraManager.isConcurrentSessionConfigurationSupported(
            sessionConfigurationsByCameraId,
        )

        return result(
            if (supported) "supported" else "notSupported",
            true,
            supported,
            emptyList(),
            emptyMap(),
        )
    }

    private fun hasCameraPermission(): Boolean {
        return context.checkSelfPermission(Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun stringList(raw: Any?): List<String> {
        if (raw !is List<*>) return emptyList()
        return raw.mapNotNull { it as? String }
    }
}
