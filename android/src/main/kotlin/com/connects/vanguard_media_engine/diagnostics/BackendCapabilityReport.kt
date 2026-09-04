package com.connects.vanguard_media_engine.diagnostics

data class BackendCapabilityReport(
    val vulkanSupported: Boolean,
    val glesSupported: Boolean = false,
    val selectedBackend: Int,           // 0 = Vulkan, 1 = Gles, 2 = Unavailable
    val fallbackReason: String,
    val gpuVendor: String = "",
    val gpuRenderer: String = "",
    val vendorId: Long = 0,
    val deviceId: Long = 0,
    val apiVersion: Long = 0,
    val vulkanDriverVersion: Long = 0,
    val profileGateStatus: String = "unverified",
    val blacklistStatus: String = "not_evaluated",
    // P1-GLES-DECODED-ROUTE-CAPABILITY-REALIGNMENT: decoded-frame GLES route
    // capability reporting only. Field order must match the JNI constructor
    // descriptor in jni_bridge.cpp exactly.
    val decodedFramePreferredPath: String = "unknown",
    val glesDecodedSurfaceTextureOesSupported: Boolean = false,
    val glesPrivateAhbImportSupported: Boolean = false,
    val glesPrivateAhbImportStatus: String = "unverified",
    val glesDecodedFallbackPolicy: String = "unverified"
)
