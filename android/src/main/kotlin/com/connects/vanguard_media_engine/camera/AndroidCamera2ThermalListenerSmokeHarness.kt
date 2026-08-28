package com.connects.vanguard_media_engine.camera

import com.connects.vanguard_media_engine.thermal.AndroidThermalStateBridge

/**
 * Phase 3-Unit T: diagnostic-only Android Camera2 dynamic thermal listener &
 * fallback telemetry smoke harness.
 *
 * Reads [AndroidThermalStateBridge.diagnosticState] — API support, the current
 * PowerManager snapshot, and the OS listener's registration state — and reports
 * it alongside explicit non-claims. Never opens a camera, never creates a
 * capture session, never renders, never touches product UI, never mutates a
 * dependency, and never forces overheating.
 */
class AndroidCamera2ThermalListenerSmokeHarness(
    private val thermalBridge: AndroidThermalStateBridge,
) {
    companion object {
        const val PROOF_BOUNDARY = "dynamic_thermal_listener_no_camera_open_no_forced_heat"
    }

    fun run(): Map<String, Any?> {
        val diagnostics = thermalBridge.diagnosticState()
        return mapOf(
            "success" to true,
            "diagnostics" to diagnostics,
            "nonClaims" to mapOf(
                "cameraOpened" to false,
                "captureSessionCreated" to false,
                "rendererCreated" to false,
                "productUiTouched" to false,
                "dependenciesModified" to false,
                "overheatingForced" to false,
            ),
            "proofBoundary" to PROOF_BOUNDARY,
        )
    }
}
