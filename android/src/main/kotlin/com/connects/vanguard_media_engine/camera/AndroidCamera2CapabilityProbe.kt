package com.connects.vanguard_media_engine.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.params.MandatoryStreamCombination
import android.hardware.camera2.params.StreamConfigurationMap
import android.media.MediaRecorder
import android.os.Build
import android.os.PowerManager
import android.util.Log
import android.util.Size
import androidx.annotation.RequiresApi

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
        private const val MAX_SIZES_PER_CATEGORY = 64
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

        val streamConfigurationMap = try {
            characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        } catch (t: Throwable) {
            Log.w(TAG, "SCALER_STREAM_CONFIGURATION_MAP($cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
            null
        }

        val previewSizes = outputSizes(cameraId, streamConfigurationMap, SurfaceTexture::class.java)
        val videoSizes = outputSizes(cameraId, streamConfigurationMap, MediaRecorder::class.java)
        val jpegSizes = outputSizes(cameraId, streamConfigurationMap, ImageFormat.JPEG)
        val yuv420Sizes = outputSizes(cameraId, streamConfigurationMap, ImageFormat.YUV_420_888)

        val fpsRanges = try {
            characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                ?.map { mapOf("lower" to it.lower, "upper" to it.upper) }
                ?: emptyList()
        } catch (t: Throwable) {
            Log.w(TAG, "CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES($cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
            emptyList()
        }

        val flashAvailable = try {
            characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) ?: false
        } catch (t: Throwable) {
            Log.w(TAG, "FLASH_INFO_AVAILABLE($cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
            false
        }

        val videoStabilizationModes = try {
            characteristics.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES)
                ?.map { stabilizationModeName(it) }
                ?: emptyList()
        } catch (t: Throwable) {
            Log.w(
                TAG,
                "CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES($cameraId) failed: " +
                    "${t.javaClass.simpleName}: ${t.message}",
            )
            emptyList()
        }

        val opticalStabilizationModes = try {
            characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)
                ?.map { stabilizationModeName(it) }
                ?: emptyList()
        } catch (t: Throwable) {
            Log.w(
                TAG,
                "LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION($cameraId) failed: " +
                    "${t.javaClass.simpleName}: ${t.message}",
            )
            emptyList()
        }

        val sensorActiveArraySize = try {
            characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)?.let {
                mapOf("left" to it.left, "top" to it.top, "right" to it.right, "bottom" to it.bottom)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "SENSOR_INFO_ACTIVE_ARRAY_SIZE($cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
            null
        }

        val sensorPixelArraySize = try {
            characteristics.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)?.let {
                mapOf("width" to it.width, "height" to it.height)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "SENSOR_INFO_PIXEL_ARRAY_SIZE($cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
            null
        }

        val mandatoryConcurrentStreamCombinations =
            mandatoryConcurrentStreamCombinations(characteristics, cameraId)

        Log.i(
            TAG,
            "camera=$cameraId previewSizes=${previewSizes.size} videoSizes=${videoSizes.size} " +
                "jpegSizes=${jpegSizes.size} yuv420Sizes=${yuv420Sizes.size} flashAvailable=$flashAvailable " +
                "mandatoryConcurrentStreamCombinationCount=${mandatoryConcurrentStreamCombinations.size}",
        )

        return mapOf(
            "cameraId" to cameraId,
            "lensFacing" to lensFacing,
            "sensorOrientation" to sensorOrientation,
            "hardwareLevel" to hardwareLevel,
            "isLogicalMultiCamera" to isLogicalMultiCamera,
            "physicalCameraIds" to physicalCameraIds,
            "capabilities" to capabilities,
            "previewSizes" to previewSizes,
            "videoSizes" to videoSizes,
            "jpegSizes" to jpegSizes,
            "yuv420Sizes" to yuv420Sizes,
            "fpsRanges" to fpsRanges,
            "flashAvailable" to flashAvailable,
            "videoStabilizationModes" to videoStabilizationModes,
            "opticalStabilizationModes" to opticalStabilizationModes,
            "sensorActiveArraySize" to sensorActiveArraySize,
            "sensorPixelArraySize" to sensorPixelArraySize,
            "mandatoryConcurrentStreamCombinations" to mandatoryConcurrentStreamCombinations,
        )
    }

    private fun mandatoryConcurrentStreamCombinations(
        characteristics: CameraCharacteristics,
        cameraId: String,
    ): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        return try {
            val combinations = characteristics.get(
                CameraCharacteristics.SCALER_MANDATORY_CONCURRENT_STREAM_COMBINATIONS,
            ) ?: return emptyList()
            combinations.map { mandatoryStreamCombinationMap(it) }
        } catch (t: Throwable) {
            Log.w(
                TAG,
                "SCALER_MANDATORY_CONCURRENT_STREAM_COMBINATIONS($cameraId) failed: " +
                    "${t.javaClass.simpleName}: ${t.message}",
            )
            emptyList()
        }
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun mandatoryStreamCombinationMap(
        combination: MandatoryStreamCombination,
    ): Map<String, Any?> {
        return mapOf(
            "description" to combination.getDescription().toString(),
            "isReprocessable" to combination.isReprocessable(),
            "streams" to combination.getStreamsInformation().map { mandatoryStreamInfoMap(it) },
        )
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun mandatoryStreamInfoMap(
        stream: MandatoryStreamCombination.MandatoryStreamInformation,
    ): Map<String, Any?> {
        val format = stream.getFormat()
        val tenBitFormat = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            stream.get10BitFormat()
        } else {
            -1
        }
        val is10BitCapable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            stream.is10BitCapable()
        } else {
            false
        }
        val isMaximumSize = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            stream.isMaximumSize()
        } else {
            false
        }
        val isUltraHighResolution = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            stream.isUltraHighResolution()
        } else {
            false
        }
        val streamUseCase = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            stream.getStreamUseCase()
        } else {
            0L
        }

        return mapOf(
            "isInput" to stream.isInput(),
            "format" to format,
            "formatName" to imageFormatName(format),
            "tenBitFormat" to tenBitFormat,
            "tenBitFormatName" to imageFormatName(tenBitFormat),
            "is10BitCapable" to is10BitCapable,
            "isMaximumSize" to isMaximumSize,
            "isUltraHighResolution" to isUltraHighResolution,
            "streamUseCase" to streamUseCase,
            "streamUseCaseName" to streamUseCaseName(streamUseCase),
            "availableSizes" to sortedSizes(stream.getAvailableSizes()?.toTypedArray()),
        )
    }

    private fun imageFormatName(format: Int): String {
        return when (format) {
            -1 -> "none"
            ImageFormat.PRIVATE -> "PRIVATE"
            ImageFormat.YUV_420_888 -> "YUV_420_888"
            ImageFormat.JPEG -> "JPEG"
            ImageFormat.RAW_SENSOR -> "RAW_SENSOR"
            ImageFormat.RAW_PRIVATE -> "RAW_PRIVATE"
            ImageFormat.RAW10 -> "RAW10"
            ImageFormat.RAW12 -> "RAW12"
            ImageFormat.DEPTH16 -> "DEPTH16"
            ImageFormat.DEPTH_POINT_CLOUD -> "DEPTH_POINT_CLOUD"
            ImageFormat.HEIC -> "HEIC"
            ImageFormat.DEPTH_JPEG -> "DEPTH_JPEG"
            else -> "format_$format"
        }
    }

    private fun streamUseCaseName(useCase: Long): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return if (useCase == 0L) "DEFAULT" else "unknown_$useCase"
        }
        return when (useCase) {
            CameraMetadata.SCALER_AVAILABLE_STREAM_USE_CASES_DEFAULT.toLong() -> "DEFAULT"
            CameraMetadata.SCALER_AVAILABLE_STREAM_USE_CASES_PREVIEW.toLong() -> "PREVIEW"
            CameraMetadata.SCALER_AVAILABLE_STREAM_USE_CASES_STILL_CAPTURE.toLong() -> "STILL_CAPTURE"
            CameraMetadata.SCALER_AVAILABLE_STREAM_USE_CASES_VIDEO_RECORD.toLong() -> "VIDEO_RECORD"
            CameraMetadata.SCALER_AVAILABLE_STREAM_USE_CASES_PREVIEW_VIDEO_STILL.toLong() ->
                "PREVIEW_VIDEO_STILL"
            CameraMetadata.SCALER_AVAILABLE_STREAM_USE_CASES_VIDEO_CALL.toLong() -> "VIDEO_CALL"
            CameraMetadata.SCALER_AVAILABLE_STREAM_USE_CASES_CROPPED_RAW.toLong() -> "CROPPED_RAW"
            else -> "unknown_$useCase"
        }
    }

    private fun <T> outputSizes(
        cameraId: String,
        map: StreamConfigurationMap?,
        klass: Class<T>,
    ): List<Map<String, Int>> {
        if (map == null) return emptyList()
        return try {
            sortedSizes(map.getOutputSizes(klass))
        } catch (t: Throwable) {
            Log.w(TAG, "getOutputSizes($cameraId, $klass) failed: ${t.javaClass.simpleName}: ${t.message}")
            emptyList()
        }
    }

    private fun outputSizes(
        cameraId: String,
        map: StreamConfigurationMap?,
        format: Int,
    ): List<Map<String, Int>> {
        if (map == null) return emptyList()
        return try {
            sortedSizes(map.getOutputSizes(format))
        } catch (t: Throwable) {
            Log.w(TAG, "getOutputSizes($cameraId, format=$format) failed: ${t.javaClass.simpleName}: ${t.message}")
            emptyList()
        }
    }

    private fun sortedSizes(sizes: Array<Size>?): List<Map<String, Int>> {
        if (sizes == null || sizes.isEmpty()) return emptyList()
        return sizes
            .sortedWith(
                compareByDescending<Size> { it.width.toLong() * it.height.toLong() }
                    .thenByDescending { it.width }
                    .thenByDescending { it.height },
            )
            .take(MAX_SIZES_PER_CATEGORY)
            .map { mapOf("width" to it.width, "height" to it.height) }
    }

    private fun stabilizationModeName(value: Int): String {
        return when (value) {
            0 -> "off"
            1 -> "on"
            else -> "unknown_$value"
        }
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
