package com.connects.vanguard_media_engine.diagnostics

data class BackendCapabilityReport(
    val vulkanSupported: Boolean,
    val selectedBackend: Int,           // 0 = Vulkan, 1 = Gles, 2 = Unavailable
    val fallbackReason: String,
    val gpuVendor: String = "",
    val gpuRenderer: String = "",
    val vendorId: Long = 0,
    val deviceId: Long = 0,
    val apiVersion: Long = 0,
    val vulkanDriverVersion: Long = 0,
    val profileGateStatus: String = "unverified",
    val blacklistStatus: String = "not_evaluated"
)
