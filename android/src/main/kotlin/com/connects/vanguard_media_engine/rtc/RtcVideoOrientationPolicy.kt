package com.connects.vanguard_media_engine.rtc

/**
 * Pure policy helper for RTC video frame rotation normalization, cardinal validation,
 * display dimension calculation, and spatial transform description.
 *
 * ## Video-Only Domain Invariant
 * This policy operates strictly within the video frame transform domain:
 * - Vanguard True-DAG RTC contracts carry zero room orchestration, signaling session,
 *   participant roster, network token, or audio stream semantics.
 * - Audio capture, routing, mixing, and WebRTC audio tracks are exclusively managed outside Vanguard.
 * - [mirrored] is display/publish metadata and does not imply camera device ownership or hardware control.
 * - This policy is stateless, pure metadata and transform calculation only.
 */
object RtcVideoOrientationPolicy {

    private val CARDINAL_ROTATIONS = setOf(0, 90, 180, 270)

    /**
     * Normalizes an arbitrary rotation angle in degrees to one of the four cardinal display
     * orientations (0, 90, 180, 270).
     *
     * Accepts any integer angle, applies modulo 360 arithmetic, normalizes negative values,
     * and snaps non-cardinal values to the nearest cardinal rotation degree.
     *
     * @param rotationDegrees Rotation in degrees (may be negative, zero, or >= 360).
     * @return Normalized cardinal rotation in degrees (one of 0, 90, 180, 270).
     */
    fun normalizeRotationDegrees(rotationDegrees: Int): Int {
        val mod = ((rotationDegrees % 360) + 360) % 360
        return when (mod) {
            0 -> 0
            90 -> 90
            180 -> 180
            270 -> 270
            else -> ((Math.round(mod.toDouble() / 90.0).toInt() * 90) % 360)
        }
    }

    /**
     * Checks whether the given rotation angle is already an exact cardinal rotation (0, 90, 180, or 270).
     *
     * @param rotationDegrees Rotation angle in degrees to check.
     * @return `true` if [rotationDegrees] is exactly one of 0, 90, 180, 270; `false` otherwise.
     */
    fun isCardinalRotation(rotationDegrees: Int): Boolean = rotationDegrees in CARDINAL_ROTATIONS

    /**
     * Computes the effective presentation / display width of an encoded frame after applying
     * cardinal display orientation rotation.
     *
     * For 90-degree and 270-degree rotations, display width is the encoded height.
     * For 0-degree and 180-degree rotations, display width is the encoded width.
     *
     * @param encodedWidth Encoded / storage width in pixels (must be > 0).
     * @param encodedHeight Encoded / storage height in pixels (must be > 0).
     * @param rotationDegrees Rotation angle in degrees.
     * @return Display width in pixels (> 0).
     * @throws IllegalArgumentException If [encodedWidth] or [encodedHeight] is <= 0.
     */
    fun displayWidth(encodedWidth: Int, encodedHeight: Int, rotationDegrees: Int): Int {
        require(encodedWidth > 0) {
            "RtcVideoOrientationPolicy: encodedWidth must be positive, got $encodedWidth"
        }
        require(encodedHeight > 0) {
            "RtcVideoOrientationPolicy: encodedHeight must be positive, got $encodedHeight"
        }
        val normalized = normalizeRotationDegrees(rotationDegrees)
        return if (normalized == 90 || normalized == 270) encodedHeight else encodedWidth
    }

    /**
     * Computes the effective presentation / display height of an encoded frame after applying
     * cardinal display orientation rotation.
     *
     * For 90-degree and 270-degree rotations, display height is the encoded width.
     * For 0-degree and 180-degree rotations, display height is the encoded height.
     *
     * @param encodedWidth Encoded / storage width in pixels (must be > 0).
     * @param encodedHeight Encoded / storage height in pixels (must be > 0).
     * @param rotationDegrees Rotation angle in degrees.
     * @return Display height in pixels (> 0).
     * @throws IllegalArgumentException If [encodedWidth] or [encodedHeight] is <= 0.
     */
    fun displayHeight(encodedWidth: Int, encodedHeight: Int, rotationDegrees: Int): Int {
        require(encodedWidth > 0) {
            "RtcVideoOrientationPolicy: encodedWidth must be positive, got $encodedWidth"
        }
        require(encodedHeight > 0) {
            "RtcVideoOrientationPolicy: encodedHeight must be positive, got $encodedHeight"
        }
        val normalized = normalizeRotationDegrees(rotationDegrees)
        return if (normalized == 90 || normalized == 270) encodedWidth else encodedHeight
    }

    /**
     * Produces a structured descriptive metadata map for the given rotation and mirroring settings.
     *
     * @param rotationDegrees Input rotation in degrees.
     * @param mirrored Whether horizontal mirroring is requested.
     * @return Map containing rotation metadata, normalized angle, cardinal status, and dimension swap flag.
     */
    fun describe(rotationDegrees: Int, mirrored: Boolean): Map<String, Any?> {
        val normalized = normalizeRotationDegrees(rotationDegrees)
        val cardinal = isCardinalRotation(rotationDegrees)
        val swapsDimensions = normalized == 90 || normalized == 270
        return mapOf(
            "rotationDegrees" to rotationDegrees,
            "normalizedRotationDegrees" to normalized,
            "isCardinal" to cardinal,
            "mirrored" to mirrored,
            "swapsDimensions" to swapsDimensions,
        )
    }
}
