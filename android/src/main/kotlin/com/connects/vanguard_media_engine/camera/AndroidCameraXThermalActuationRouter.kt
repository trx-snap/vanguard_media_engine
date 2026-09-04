package com.connects.vanguard_media_engine.camera

import com.connects.vanguard_media_engine.VanguardCameraSource
import io.flutter.plugin.common.MethodChannel

/**
 * P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE: owns the public Dart
 * `applyAndroidCameraXThermalTargetFps` / `getAndroidCameraXThermalFpsDiagnostics`
 * MethodChannel routes.
 *
 * Thin dispatch shim over `VanguardCameraSource.applyThermalTargetFps` /
 * `VanguardCameraSource.thermalFpsDiagnostics` -- holds no camera state of its
 * own and performs no Dart thermal-state policy (the Dart
 * `VGCamera2ThermalLoadSheddingPlanner` is the sole policy authority; this
 * router only actuates the `targetFps` it is given).
 */
class AndroidCameraXThermalActuationRouter(
    private val cameraSourceProvider: () -> VanguardCameraSource?,
) {
    companion object {
        private val OWNED_METHODS = setOf(
            "applyAndroidCameraXThermalTargetFps",
            "getAndroidCameraXThermalFpsDiagnostics",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "applyAndroidCameraXThermalTargetFps" -> applyThermalTargetFps(args, result)
            "getAndroidCameraXThermalFpsDiagnostics" -> getDiagnostics(result)
            else -> return false
        }
        return true
    }

    private fun applyThermalTargetFps(args: Map<*, *>?, result: MethodChannel.Result) {
        val src = cameraSourceProvider()
        if (src == null) {
            result.error("NO_CAMERA", "applyAndroidCameraXThermalTargetFps: no active camera session", null)
            return
        }
        val targetFps = (args?.get("targetFps") as? Number)?.toInt()
        if (targetFps == null) {
            result.error("BAD_ARGS", "applyAndroidCameraXThermalTargetFps expects an int \"targetFps\"", null)
            return
        }
        src.applyThermalTargetFps(
            targetFps = targetFps,
            onResult = { diagnostics -> result.success(diagnostics) },
            onError = { code, message -> result.error(code, message, null) },
        )
    }

    private fun getDiagnostics(result: MethodChannel.Result) {
        val src = cameraSourceProvider()
        if (src == null) {
            result.error("NO_CAMERA", "getAndroidCameraXThermalFpsDiagnostics: no active camera session", null)
            return
        }
        result.success(src.thermalFpsDiagnostics())
    }
}
