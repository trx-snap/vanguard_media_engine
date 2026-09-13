package com.connects.vanguard_media_engine.duet

import android.content.Context
import android.os.Build
import android.os.PowerManager

// VG-DUET-GREEN-SCREEN: Capability probe + backend/quality enums.

object DuetSegmentationBackend {
    const val MEDIAPIPE_GPU  = "mediapipe_gpu"
    const val MEDIAPIPE_GPU_GRAPH = "mediapipe_gpu_graph"
    const val MEDIAPIPE_CPU  = "mediapipe_cpu"
    const val MLKIT          = "mlkit"
    const val NONE           = "none"
    /** Standalone TensorFlow Lite GPU delegate backend — debug/smoke opt-in only; not default primary. */
    const val RAW_TFLITE_GPU = "raw_tflite_gpu"
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
         * Probe result describing the mediapipe_gpu rung as EXPERIMENTAL and
         * NOT production-proven: a physical smoke test on SM-A566B (Android 16)
         * showed MediaPipe Tasks ImageSegmenter with Delegate.GPU +
         * outputConfidenceMasks(true) can open() successfully and then native-
         * abort (SIGABRT, image_frame.cc "Format UNKNOWN") during result
         * conversion on the first frame — an abort that cannot be caught as a
         * Kotlin failure. [mediaPipeGpuSupported] is therefore always false
         * here; this factory exists only for callers investigating the GPU
         * rung directly, and no production selector/probe path calls it.
         */
        fun mediapipeGpu(quality: DuetSegmentationQuality = DuetSegmentationQuality.QUALITY) =
            DuetSegmentationProbe(
                isAvailable            = true,
                selectedBackend        = DuetSegmentationBackend.MEDIAPIPE_GPU,
                quality                = quality,
                maxResolution          = 256,
                supportsRawMask        = true,
                reason                 = "MediaPipe Tasks Vision ImageSegmenter (GPU, VIDEO mode) is experimental and not production-proven (native abort observed during result conversion); CPU and ML Kit remain the production rungs.",
                mediaPipeGpuSupported  = false,
                mediaPipeCpuSupported  = true,
                mlKitAvailable         = true,
                analysisMaxResolution  = 256,
                thermalTier            = "nominal",
            )

        /**
         * Probe result when MediaPipe Tasks Vision ImageSegmenter (CPU delegate,
         * VIDEO mode) is the primary backend, with ML Kit as the next rung.
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

        /**
         * Probe result when the raw TensorFlow Lite GPU delegate backend is the
         * active rung (debug/smoke opt-in only; not default production primary).
         * [mediaPipeGpuSupported] stays false — this backend uses a standalone
         * GpuDelegate separate from MediaPipe Tasks GPU.
         */
        fun rawTfliteGpu(quality: DuetSegmentationQuality = DuetSegmentationQuality.QUALITY) =
            DuetSegmentationProbe(
                isAvailable            = true,
                selectedBackend        = DuetSegmentationBackend.RAW_TFLITE_GPU,
                quality                = quality,
                maxResolution          = 256,
                supportsRawMask        = true,
                reason                 = "Raw TensorFlow Lite GPU delegate selected (debug/smoke opt-in; degrades to mediapipe_cpu on failure).",
                mediaPipeGpuSupported  = false,
                mediaPipeCpuSupported  = true,
                mlKitAvailable         = true,
                analysisMaxResolution  = 256,
                thermalTier            = "nominal",
            )

        /**
         * Probe result for the low-level MediaPipe Framework GPU graph backend.
         * This is distinct from [mediapipeGpu], which describes the disabled
         * MediaPipe Tasks ImageSegmenter GPU path.
         */
        fun mediapipeGpuGraph(quality: DuetSegmentationQuality = DuetSegmentationQuality.QUALITY) =
            DuetSegmentationProbe(
                isAvailable            = true,
                selectedBackend        = DuetSegmentationBackend.MEDIAPIPE_GPU_GRAPH,
                quality                = quality,
                maxResolution          = 256,
                supportsRawMask        = true,
                reason                 = "MediaPipe Framework GPU graph selected (debug/smoke opt-in; produces GPU-resident masks and degrades to mediapipe_cpu on failure).",
                mediaPipeGpuSupported  = true,
                mediaPipeCpuSupported  = true,
                mlKitAvailable         = true,
                analysisMaxResolution  = 256,
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
                DuetSegmentationBackend.MEDIAPIPE_GPU  -> mediapipeGpu(quality)
                DuetSegmentationBackend.MEDIAPIPE_GPU_GRAPH -> mediapipeGpuGraph(quality)
                DuetSegmentationBackend.MEDIAPIPE_CPU  -> mediapipeCpu(quality)
                DuetSegmentationBackend.MLKIT          -> mlkit(quality)
                DuetSegmentationBackend.RAW_TFLITE_GPU -> rawTfliteGpu(quality)
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
