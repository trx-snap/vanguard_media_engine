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

    /**
     * Diagnostic-only selection: requests VULKAN when the native layoutConfigMap
     * opts in explicitly via `mode == "greenScreen"` and
     * `debugPreviewBackend == "vulkan"`. Every other combination (including
     * PiP/split layouts and normal greenScreen without the debug key) requests
     * GLES, matching [selectDefault]. Vulkan capability failure still falls
     * back to GLES via [AndroidDuetPreviewBackendSelector.select].
     */
    fun selectForLayoutConfig(layoutConfigMap: Map<String, Any?>?): AndroidDuetPreviewBackendSelection {
        val mode = layoutConfigMap?.get("mode") as? String
        val debugPreviewBackend = layoutConfigMap?.get("debugPreviewBackend") as? String
        val requestVulkan = mode == "greenScreen" && debugPreviewBackend == "vulkan"
        if (!requestVulkan) return selectDefault()
        return AndroidDuetPreviewBackendSelector.select(AndroidDuetPreviewBackendId.VULKAN)
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
