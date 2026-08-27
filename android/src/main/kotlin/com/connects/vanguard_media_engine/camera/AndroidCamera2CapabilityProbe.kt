package com.connects.vanguard_media_engine.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.os.PowerManager
import android.util.Log

/**
 * Phase 3-Unit A: read-only Android Camera2 hardware/thermal capability probe.
 *
 * Uses only [CameraManager.getCameraIdList] / [CameraManager.getCameraCharacteristics].
 * Never opens a camera, never starts a capture session, never requests runtime
 * permissions, never touches CameraX. Diagnostic/capability foundation only.
 */
class AndroidCamera2CapabilityProbe(private val context: Context) {

    companion object {
        private const val TAG = "AndroidCamera2CapabilityProbe"
    }

    fun probe(): Map<String, Any?> {
        val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        val hasCameraPermission = hasCameraPermission()
        val thermalStatus = thermalStatus()
        val thermalStatusName = thermalStatusName(thermalStatus)

        val cameraIds = try {
            cameraManager?.cameraIdList?.toList() ?: emptyList()
        } catch (t: Throwable) {
            Log.w(TAG, "getCameraIdList failed: ${t.javaClass.simpleName}: ${t.message}")
            emptyList()
        }

        val cameras = cameraIds.mapNotNull { id ->
            try {
                describeCamera(cameraManager!!, id)
            } catch (t: Throwable) {
                Log.w(TAG, "getCameraCharacteristics($id) failed: ${t.javaClass.simpleName}: ${t.message}")
                null
            }
        }

        val concurrentCameraIdSets = concurrentCameraIdSets(cameraManager)
        val supportsConcurrentCamera = concurrentCameraIdSets.any { it.size >= 2 }

        val fallbackRecommendation = when {
            cameras.isEmpty() -> "no_camera"
            isThermalBlocked(thermalStatus) -> "thermal_blocked"
            supportsConcurrentCamera -> "concurrent_supported"
            else -> "single_camera_only"
        }

        Log.i(
            TAG,
            "cameraCount=${cameras.size} supportsConcurrentCamera=$supportsConcurrentCamera " +
                "thermalStatusName=$thermalStatusName hasCameraPermission=$hasCameraPermission",
        )

        return mapOf(
            "success" to true,
            "apiLevel" to Build.VERSION.SDK_INT,
            "hasCameraPermission" to hasCameraPermission,
            "thermalStatus" to thermalStatus,
            "thermalStatusName" to thermalStatusName,
            "cameraCount" to cameras.size,
            "supportsConcurrentCamera" to supportsConcurrentCamera,
            "concurrentCameraIdSets" to concurrentCameraIdSets,
            "cameras" to cameras,
            "fallbackRecommendation" to fallbackRecommendation,
        )
    }

    private fun hasCameraPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun thermalStatus(): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            powerManager?.currentThermalStatus
        } catch (t: Throwable) {
            Log.w(TAG, "currentThermalStatus failed: ${t.javaClass.simpleName}: ${t.message}")
            null
        }
    }

    private fun thermalStatusName(status: Int?): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || status == null) return "unavailable"
        return when (status) {
            PowerManager.THERMAL_STATUS_NONE -> "none"
            PowerManager.THERMAL_STATUS_LIGHT -> "light"
            PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
            PowerManager.THERMAL_STATUS_SEVERE -> "severe"
            PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
            PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
            PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
            else -> "unknown_$status"
        }
    }

    private fun isThermalBlocked(status: Int?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || status == null) return false
        return status >= PowerManager.THERMAL_STATUS_SEVERE
    }

    private fun concurrentCameraIdSets(cameraManager: CameraManager?): List<List<String>> {
        if (cameraManager == null) return emptyList()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        return try {
            cameraManager.concurrentCameraIds.map { it.toList() }
        } catch (t: Throwable) {
            Log.w(TAG, "concurrentCameraIds failed: ${t.javaClass.simpleName}: ${t.message}")
            emptyList()
        }
    }

    private fun describeCamera(cameraManager: CameraManager, cameraId: String): Map<String, Any?> {
        val characteristics = cameraManager.getCameraCharacteristics(cameraId)

        val lensFacing = when (characteristics.get(CameraCharacteristics.LENS_FACING)) {
            CameraCharacteristics.LENS_FACING_FRONT -> "front"
            CameraCharacteristics.LENS_FACING_BACK -> "back"
            CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
            else -> "unknown"
        }

        val sensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION)

        val hardwareLevel = when (characteristics.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)) {
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "legacy"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "limited"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "full"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "level3"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL -> "external"
            else -> "unknown"
        }

        val capabilitiesInts = characteristics.get(
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES,
        ) ?: intArrayOf()
        val isLogicalMultiCamera = capabilitiesInts.contains(
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA,
        )
        val capabilities = capabilitiesInts.map { capabilityName(it) }

        val physicalCameraIds = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                characteristics.physicalCameraIds.toList()
            } catch (t: Throwable) {
                Log.w(TAG, "physicalCameraIds($cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
                emptyList()
            }
        } else {
            emptyList()
        }

        return mapOf(
            "cameraId" to cameraId,
            "lensFacing" to lensFacing,
            "sensorOrientation" to sensorOrientation,
            "hardwareLevel" to hardwareLevel,
            "isLogicalMultiCamera" to isLogicalMultiCamera,
            "physicalCameraIds" to physicalCameraIds,
            "capabilities" to capabilities,
        )
    }

    private fun capabilityName(value: Int): String {
        return when (value) {
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE -> "BACKWARD_COMPATIBLE"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR -> "MANUAL_SENSOR"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING -> "MANUAL_POST_PROCESSING"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_RAW -> "RAW"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_PRIVATE_REPROCESSING -> "PRIVATE_REPROCESSING"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_READ_SENSOR_SETTINGS -> "READ_SENSOR_SETTINGS"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_BURST_CAPTURE -> "BURST_CAPTURE"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_YUV_REPROCESSING -> "YUV_REPROCESSING"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_DEPTH_OUTPUT -> "DEPTH_OUTPUT"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_CONSTRAINED_HIGH_SPEED_VIDEO ->
                "CONSTRAINED_HIGH_SPEED_VIDEO"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MOTION_TRACKING -> "MOTION_TRACKING"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA -> "LOGICAL_MULTI_CAMERA"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MONOCHROME -> "MONOCHROME"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_SECURE_IMAGE_DATA -> "SECURE_IMAGE_DATA"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_SYSTEM_CAMERA -> "SYSTEM_CAMERA"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_ULTRA_HIGH_RESOLUTION_SENSOR ->
                "ULTRA_HIGH_RESOLUTION_SENSOR"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_REMOSAIC_REPROCESSING -> "REMOSAIC_REPROCESSING"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_STREAM_USE_CASE -> "STREAM_USE_CASE"
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_COLOR_SPACE_PROFILES -> "COLOR_SPACE_PROFILES"
            else -> "capability_$value"
        }
    }
}
