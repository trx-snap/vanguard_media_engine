package com.connects.vanguard_media_engine.export

/**
 * Snapshot of an overlay's spatial transform and opacity at an overlay-local elapsed time.
 *
 * Geometry is in absolute canvas pixels with top-left origin.
 * Immutable value type.
 */
data class AndroidTimelineOverlayKeyframe(
    val timeSeconds: Double,
    val translationX: Double = 0.0,
    val translationY: Double = 0.0,
    val width: Double = 0.0,
    val height: Double = 0.0,
    val rotation: Double = 0.0,
    val scale: Double = 1.0,
    val opacity: Double = 1.0,
    val interpolation: Interpolation = Interpolation.LINEAR,
) {
    /**
     * Interpolation curve applied between consecutive overlay keyframes.
     */
    enum class Interpolation(val wireValue: String) {
        LINEAR("linear"),
        EASE_IN_OUT("easeInOut"),
        SMOOTHSTEP("smoothstep"),
        HOLD("hold");

        companion object {
            /**
             * Resolves a wire-format or enum name string to [Interpolation].
             * Case-insensitive. Returns null if unrecognized.
             */
            fun fromWireValue(raw: String): Interpolation? {
                val trimmed = raw.trim()
                return values().firstOrNull {
                    it.wireValue.equals(trimmed, ignoreCase = true) ||
                        it.name.equals(trimmed, ignoreCase = true)
                }
            }
        }
    }
}
