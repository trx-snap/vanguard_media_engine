package com.connects.vanguard_media_engine.duet

// VG-DUET-GREEN-SCREEN: Capability probe + backend/quality enums.

object DuetSegmentationBackend {
    const val MEDIAPIPE_GPU = "mediapipe_gpu"
    const val MEDIAPIPE_CPU = "mediapipe_cpu"
    const val MLKIT        = "mlkit"
    const val NONE         = "none"
}

enum class DuetSegmentationQuality(val key: String) {
    QUALITY("quality"),
    BALANCED("balanced"),
    SURVIVAL("survival"),
}

data class DuetSegmentationProbe(
    val isAvailable: Boolean,
    val selectedBackend: String,
    val quality: DuetSegmentationQuality,
    val maxResolution: Int,
    val supportsRawMask: Boolean,
    val reason: String,
    // Contract fields required by the cross-platform capability spec:
    val mediaPipeGpuSupported: Boolean = false,
    val mediaPipeCpuSupported: Boolean = false,
    val mlKitAvailable: Boolean = false,
    val analysisMaxResolution: Int = 0,
    val thermalTier: String = "unknown",
) {
    companion object {
        /** Probe result when ML Kit Selfie Segmentation is the active backend. */
        fun mlkit(quality: DuetSegmentationQuality = DuetSegmentationQuality.BALANCED) =
            DuetSegmentationProbe(
                isAvailable            = true,
                selectedBackend        = DuetSegmentationBackend.MLKIT,
                quality                = quality,
                maxResolution          = 512,
                supportsRawMask        = true,
                reason                 = "ML Kit Selfie Segmentation STREAM_MODE selected.",
                mediaPipeGpuSupported  = false,
                mediaPipeCpuSupported  = false,
                mlKitAvailable         = true,
                analysisMaxResolution  = 512,
                thermalTier            = "nominal",
            )

        /** Probe result when no backend is available; session falls back to PiP. */
        fun unavailable(reason: String) =
            DuetSegmentationProbe(
                isAvailable            = false,
                selectedBackend        = DuetSegmentationBackend.NONE,
                quality                = DuetSegmentationQuality.SURVIVAL,
                maxResolution          = 0,
                supportsRawMask        = false,
                reason                 = reason,
                mediaPipeGpuSupported  = false,
                mediaPipeCpuSupported  = false,
                mlKitAvailable         = false,
                analysisMaxResolution  = 0,
                thermalTier            = "unknown",
            )
    }

    fun toMap(): Map<String, Any?> = mapOf(
        // Legacy / internal fields:
        "isAvailable"          to isAvailable,
        "selectedBackend"      to selectedBackend,
        "quality"              to quality.key,
        "maxResolution"        to maxResolution,
        "supportsRawMask"      to supportsRawMask,
        "reason"               to reason,
        // Cross-platform contract keys:
        "mediaPipeGpuSupported" to mediaPipeGpuSupported,
        "mediaPipeCpuSupported" to mediaPipeCpuSupported,
        "mlKitAvailable"        to mlKitAvailable,
        "analysisMaxResolution" to analysisMaxResolution,
        "thermalTier"           to thermalTier,
    )
}
