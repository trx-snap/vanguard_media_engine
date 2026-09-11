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
    fun selectDefault(): AndroidDuetPreviewBackendSelection {
        return AndroidDuetPreviewBackendSelection(
            requested = AndroidDuetPreviewBackendId.GLES,
            actual = AndroidDuetPreviewBackendId.GLES,
            fallbackReason = null,
        )
    }

    fun create(
        selection: AndroidDuetPreviewBackendSelection = selectDefault(),
    ): AndroidDuetPreviewBackend {
        return when (selection.actual) {
            AndroidDuetPreviewBackendId.GLES -> AndroidDuetPreviewCompositor()
            AndroidDuetPreviewBackendId.VULKAN -> {
                // Fail closed by returning GLES compositor for now and do not throw.
                AndroidDuetPreviewCompositor()
            }
        }
    }
}
