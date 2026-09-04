package com.connects.vanguard_media_engine.diagnostics

import android.util.Log

class VanguardDiagnostics {
    fun logCapabilities(report: BackendCapabilityReport) {
        Log.i(TAG, "capability: vulkan=${report.vulkanSupported}" +
            " gles=${report.glesSupported}" +
            " backend=${report.selectedBackend}" +
            " fallback=${report.fallbackReason}" +
            " vendor=${report.gpuVendor}" +
            " renderer=${report.gpuRenderer}" +
            " vendorId=0x${report.vendorId.toString(16)}" +
            " deviceId=0x${report.deviceId.toString(16)}" +
            " api=${report.apiVersion}" +
            " driver=${report.vulkanDriverVersion}" +
            " profile=${report.profileGateStatus}" +
            " blacklist=${report.blacklistStatus}" +
            " decodedFramePreferredPath=${report.decodedFramePreferredPath}" +
            " glesDecodedSurfaceTextureOesSupported=${report.glesDecodedSurfaceTextureOesSupported}" +
            " glesPrivateAhbImportSupported=${report.glesPrivateAhbImportSupported}" +
            " glesPrivateAhbImportStatus=${report.glesPrivateAhbImportStatus}" +
            " glesDecodedFallbackPolicy=${report.glesDecodedFallbackPolicy}")
    }

    fun logEvent(message: String) {
        Log.i(TAG, message)
    }

    companion object {
        private const val TAG = "VanguardDiagnostics"
    }
}
