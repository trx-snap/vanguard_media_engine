package com.connects.vanguard_media_engine.duet

enum class AndroidDuetPreviewBackendId {
    GLES,
    VULKAN,
}

data class AndroidDuetPreviewBackendSelection(
    val requested: AndroidDuetPreviewBackendId,
    val actual: AndroidDuetPreviewBackendId,
    val fallbackReason: String? = null,
)

object AndroidDuetPreviewBackendFactory {
    /**
     * Default production preview selection remains GLES while the Vulkan preview
     * backend is foundation-only (non-presenting). Explicit VULKAN selection can
     * be requested via [AndroidDuetPreviewBackendSelector.select] for diagnostics
     * or foundation testing.
     */
    fun selectDefault(): AndroidDuetPreviewBackendSelection {
        return AndroidDuetPreviewBackendSelector.select(AndroidDuetPreviewBackendId.GLES)
    }

    fun create(
        selection: AndroidDuetPreviewBackendSelection = selectDefault(),
    ): AndroidDuetPreviewBackend {
        return when (selection.actual) {
            AndroidDuetPreviewBackendId.GLES -> AndroidDuetPreviewCompositor()
            AndroidDuetPreviewBackendId.VULKAN -> AndroidDuetVulkanPreviewCompositor()
        }
    }
}
