package com.connects.vanguard_media_engine.duet

import android.content.Context
import android.os.Build
import android.os.PowerManager

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
        /**
         * Probe result when MediaPipe Tasks Vision ImageSegmenter (CPU delegate,
         * VIDEO mode) is the primary backend, with ML Kit as the next rung.
         * GPU is deferred: mediaPipeGpuSupported stays false in this slice.
         */
        fun mediapipeCpu(quality: DuetSegmentationQuality = DuetSegmentationQuality.QUALITY) =
            DuetSegmentationProbe(
                isAvailable            = true,
                selectedBackend        = DuetSegmentationBackend.MEDIAPIPE_CPU,
                quality                = quality,
                maxResolution          = 256,
                supportsRawMask        = true,
                reason                 = "MediaPipe Tasks Vision ImageSegmenter (CPU, VIDEO mode) selected; ML Kit fallback available.",
                mediaPipeGpuSupported  = false,
                mediaPipeCpuSupported  = true,
                mlKitAvailable         = true,
                analysisMaxResolution  = 256,
                thermalTier            = "nominal",
            )

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

        /**
         * Dynamic probe for [backendId]: same shape as [mediapipeCpu]/[mlkit],
         * with [thermalTier] read live from [context]'s PowerManager (API 29+)
         * instead of the static "nominal" default. The recommended [quality]
         * is downgraded to SURVIVAL when the live tier is serious/critical,
         * mirroring [AndroidDuetAdaptiveQualityPolicy]'s tier response. Falls
         * back to the static factories' defaults when [context] is null or the
         * OS thermal API is unavailable, so existing callers of the zero-arg
         * factories are unaffected.
         */
        fun probe(
            context: Context?,
            backendId: String,
            quality: DuetSegmentationQuality,
        ): DuetSegmentationProbe {
            val base = when (backendId) {
                DuetSegmentationBackend.MEDIAPIPE_CPU -> mediapipeCpu(quality)
                DuetSegmentationBackend.MLKIT -> mlkit(quality)
                else -> return unavailable("Unsupported segmentation backend '$backendId' for dynamic probe")
            }
            val liveTier = liveThermalTier(context) ?: return base
            val recommendedQuality = when (liveTier) {
                "serious", "critical" -> DuetSegmentationQuality.SURVIVAL
                else -> quality
            }
            return base.copy(thermalTier = liveTier, quality = recommendedQuality)
        }

        private fun liveThermalTier(context: Context?): String? {
            if (context == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
            val appContext = context.applicationContext ?: context
            val powerManager = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
                ?: return null
            return try {
                when (powerManager.currentThermalStatus) {
                    PowerManager.THERMAL_STATUS_NONE -> "nominal"
                    PowerManager.THERMAL_STATUS_LIGHT -> "fair"
                    PowerManager.THERMAL_STATUS_MODERATE,
                    PowerManager.THERMAL_STATUS_SEVERE -> "serious"
                    PowerManager.THERMAL_STATUS_CRITICAL,
                    PowerManager.THERMAL_STATUS_EMERGENCY,
                    PowerManager.THERMAL_STATUS_SHUTDOWN -> "critical"
                    else -> "nominal"
                }
            } catch (t: Throwable) {
                null
            }
        }
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
