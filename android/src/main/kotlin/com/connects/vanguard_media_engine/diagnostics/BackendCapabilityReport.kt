package com.connects.vanguard_media_engine.diagnostics

data class BackendCapabilityReport(
    val vulkanSupported: Boolean,
    val selectedBackend: Int, // 0 = Vulkan, 1 = Gles, 2 = Unavailable
    val fallbackReason: String
)
