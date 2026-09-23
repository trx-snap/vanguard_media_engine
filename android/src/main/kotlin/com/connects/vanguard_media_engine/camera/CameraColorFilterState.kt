package com.connects.vanguard_media_engine.camera

import android.graphics.Bitmap
import android.util.Log

/**
 * CameraColorFilterState encapsulates the configuration for live camera color grading
 * filters (ColorMatrix and 2D LUT) on Android.
 *
 * This state carries:
 *   - [mode]: PASSTHROUGH, COLOR_MATRIX, or LUT_2D
 *   - [intensity]: Filter blend intensity in [0.0, 1.0] (0.0 = passthrough, 1.0 = full effect)
 *   - [matrix]: 20-element 4x5 row-major ColorMatrix (matching Flutter ColorFilter.matrix
 *               and AndroidTimelineVideoEncoder conventions, with columns 0-3 as multipliers
 *               and column 4 as an offset in [0, 255]).
 *   - [lutBitmap]: Optional Bitmap holding a 2D LUT texture (e.g. 512x512 for a 64^3 cube).
 *
 * Zero lifecycle ownership: purely a frame rendering descriptor.
 */
data class CameraColorFilterState(
    val mode: FilterMode = FilterMode.PASSTHROUGH,
    val intensity: Float = 1.0f,
    val matrix: FloatArray? = null,
    val lutBitmap: Bitmap? = null,
) {
    enum class FilterMode {
        PASSTHROUGH,
        COLOR_MATRIX,
        LUT_2D,
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is CameraColorFilterState) return false
        if (mode != other.mode) return false
        if (intensity != other.intensity) return false
        if (matrix != null) {
            if (other.matrix == null || !matrix.contentEquals(other.matrix)) return false
        } else if (other.matrix != null) return false
        if (lutBitmap != other.lutBitmap) return false
        return true
    }

    override fun hashCode(): Int {
        var result = mode.hashCode()
        result = 31 * result + intensity.hashCode()
        result = 31 * result + (matrix?.contentHashCode() ?: 0)
        result = 31 * result + (lutBitmap?.hashCode() ?: 0)
        return result
    }

    companion object {
        private const val TAG = "CameraColorFilterState"

        // ── 4x5 ColorMatrix standard presets (row-major: 4 rows x 5 columns) ─────
        // Column 4 is an offset in [0, 255].
        val IDENTITY_MATRIX = floatArrayOf(
            1f, 0f, 0f, 0f, 0f,
            0f, 1f, 0f, 0f, 0f,
            0f, 0f, 1f, 0f, 0f,
            0f, 0f, 0f, 1f, 0f,
        )

        // Warm / Amber: boosted red/yellow, reduced blue.
        val WARM_MATRIX = floatArrayOf(
            1.15f, 0.05f, 0.00f, 0f, 10f,
            0.00f, 1.05f, 0.00f, 0f, 5f,
            0.00f, 0.00f, 0.85f, 0f, -5f,
            0.00f, 0.00f, 0.00f, 1f, 0f,
        )

        // Cool / Cyan: boosted blue/cyan, reduced red.
        val COOL_MATRIX = floatArrayOf(
            0.85f, 0.00f, 0.00f, 0f, -5f,
            0.00f, 1.05f, 0.05f, 0f, 5f,
            0.00f, 0.05f, 1.20f, 0f, 15f,
            0.00f, 0.00f, 0.00f, 1f, 0f,
        )

        // Vintage / Nostalgia: warm highlights, slightly lifted blacks, gentle desaturation.
        val VINTAGE_MATRIX = floatArrayOf(
            0.90f, 0.15f, 0.05f, 0f, 20f,
            0.05f, 0.85f, 0.10f, 0f, 15f,
            0.05f, 0.10f, 0.70f, 0f, 25f,
            0.00f, 0.00f, 0.00f, 1f, 0f,
        )

        // Sepia: classic warm monochrome toning.
        val SEPIA_MATRIX = floatArrayOf(
            0.393f, 0.769f, 0.189f, 0f, 0f,
            0.349f, 0.686f, 0.168f, 0f, 0f,
            0.272f, 0.534f, 0.131f, 0f, 0f,
            0.000f, 0.000f, 0.000f, 1f, 0f,
        )

        // B&W / Monochrome: Rec.709 standard luminance weights (0.2126, 0.7152, 0.0722).
        val BW_MATRIX = floatArrayOf(
            0.2126f, 0.7152f, 0.0722f, 0f, 0f,
            0.2126f, 0.7152f, 0.0722f, 0f, 0f,
            0.2126f, 0.7152f, 0.0722f, 0f, 0f,
            0.0000f, 0.0000f, 0.0000f, 1f, 0f,
        )

        // Vivid / Boost: increased saturation and contrast.
        val VIVID_MATRIX = floatArrayOf(
            1.25f, -0.15f, -0.10f, 0f, 0f,
            -0.10f, 1.25f, -0.15f, 0f, 0f,
            -0.10f, -0.15f, 1.25f, 0f, 0f,
            0.00f,  0.00f,  0.00f, 1f, 0f,
        )

        // Fade / Matte: lifted black floor for cinematic washed look.
        val FADE_MATRIX = floatArrayOf(
            0.88f, 0.00f, 0.00f, 0f, 25f,
            0.00f, 0.88f, 0.00f, 0f, 25f,
            0.00f, 0.00f, 0.88f, 0f, 25f,
            0.00f, 0.00f, 0.00f, 1f, 0f,
        )

        /**
         * Resolves a named preset to a [CameraColorFilterState].
         * Supported presets: "warm", "cool", "vintage", "sepia", "bw"/"grayscale"/"mono",
         * "vivid", "fade", "none"/"off"/"identity".
         */
        fun fromPreset(presetName: String, intensity: Float = 1.0f): CameraColorFilterState? {
            val clampedIntensity = intensity.coerceIn(0f, 1f)
            val matrix = when (presetName.lowercase().trim()) {
                "warm", "amber", "golden" -> WARM_MATRIX
                "cool", "cyan", "cold" -> COOL_MATRIX
                "vintage", "retro", "nostalgia" -> VINTAGE_MATRIX
                "sepia" -> SEPIA_MATRIX
                "bw", "b&w", "grayscale", "monochrome", "mono", "noir" -> BW_MATRIX
                "vivid", "saturated", "boost" -> VIVID_MATRIX
                "fade", "matte", "cinematic" -> FADE_MATRIX
                "none", "off", "disabled", "identity", "passthrough" -> return null
                else -> {
                    Log.w(TAG, "Unknown preset name: $presetName, falling back to identity")
                    IDENTITY_MATRIX
                }
            }
            return CameraColorFilterState(
                mode = FilterMode.COLOR_MATRIX,
                intensity = clampedIntensity,
                matrix = matrix,
            )
        }

        /**
         * Constructs a [CameraColorFilterState] from a 20-element FloatArray.
         */
        fun fromMatrix(matrix: FloatArray, intensity: Float = 1.0f): CameraColorFilterState {
            require(matrix.size == 20) { "ColorMatrix must have exactly 20 elements (4x5), got ${matrix.size}" }
            return CameraColorFilterState(
                mode = FilterMode.COLOR_MATRIX,
                intensity = intensity.coerceIn(0f, 1f),
                matrix = matrix,
            )
        }

        /**
         * Parses a filter map (e.g. from filterStack or parameterUpdates) into a
         * [CameraColorFilterState], or null if disabled/identity.
         */
        fun fromFilterMap(filter: Map<*, *>, defaultType: String? = null): CameraColorFilterState? {
            val enabled = (filter["enabled"] as? Boolean) ?: true
            if (!enabled) return null

            val type = (filter["type"] as? String) ?: defaultType ?: return null
            val params = filter["parameters"] as? Map<*, *>

            // Extract intensity.
            val intensity = ((params?.get("intensity") ?: filter["intensity"]) as? Number)?.toFloat() ?: 1.0f
            if (intensity <= 0f) return null

            when (type.lowercase()) {
                "colormatrix" -> {
                    val rawMatrix = (params?.get("matrix") ?: filter["matrix"]) as? List<*>
                    if (rawMatrix != null && rawMatrix.size == 20) {
                        val floatArray = FloatArray(20) { idx ->
                            (rawMatrix[idx] as? Number)?.toFloat() ?: 0f
                        }
                        return fromMatrix(floatArray, intensity)
                    }
                    return null
                }
                "lut" -> {
                    // Check for preset name first.
                    val preset = (params?.get("preset") ?: filter["preset"]) as? String
                    if (preset != null && preset.isNotEmpty()) {
                        return fromPreset(preset, intensity)
                    }

                    // Check for raw matrix inside lut parameters.
                    val rawMatrix = (params?.get("matrix") ?: filter["matrix"]) as? List<*>
                    if (rawMatrix != null && rawMatrix.size == 20) {
                        val floatArray = FloatArray(20) { idx ->
                            (rawMatrix[idx] as? Number)?.toFloat() ?: 0f
                        }
                        return fromMatrix(floatArray, intensity)
                    }

                    // Default LUT fallback when no preset or matrix is specified:
                    // Treat default lut as warm cinematic grading.
                    return fromPreset("warm", intensity)
                }
                else -> return null
            }
        }
    }
}
