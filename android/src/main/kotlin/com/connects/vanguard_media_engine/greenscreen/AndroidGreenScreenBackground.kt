package com.connects.vanguard_media_engine.greenscreen

// -----------------------------------------------------------------------------
// Static green-screen background model (independent GreenScreen capability).
// -----------------------------------------------------------------------------
//
// Mirrors the `greenScreenBackground` map shape historically carried on a
// Duet layoutConfigMap (`type` / `argbColor` / `filePath` / `scaleMode`), but
// is owned by GreenScreen: it is caller-agnostic and used by any camera/effect
// surface (Duet, live meeting/calling, going live, camera, export), not just
// Duet. Parsing here never throws: unknown/absent `type` degrades to [VIDEO],
// an invalid solid color degrades to opaque black, and an image with a
// missing path degrades to opaque black (a decode failure at draw time
// degrades the same way, but that can only be detected once the compositor
// attempts the decode).

/** The type of background displayed beneath the green-screen camera layer. */
enum class AndroidGreenScreenBackgroundType {
    VIDEO, SOLID_COLOR, IMAGE
}

/** Scaling mode for static (solid color / image) green-screen backgrounds. */
enum class AndroidGreenScreenBackgroundScaleMode {
    ASPECT_FILL, ASPECT_FIT
}

/**
 * Immutable, parsed green-screen background specification.
 *
 * [argbColor] is only meaningful for [AndroidGreenScreenBackgroundType.SOLID_COLOR];
 * [filePath] and [scaleMode] only for [AndroidGreenScreenBackgroundType.IMAGE].
 */
data class AndroidGreenScreenBackground(
    val type: AndroidGreenScreenBackgroundType,
    val argbColor: Int,
    val filePath: String?,
    val scaleMode: AndroidGreenScreenBackgroundScaleMode,
) {
    /**
     * True when the source video should be composited as the background (the
     * default). The render loop uses this to decide whether active playback
     * needs sustained decoder Step ticks at all.
     */
    val usesSourceVideo: Boolean get() = type == AndroidGreenScreenBackgroundType.VIDEO

    companion object {
        private const val OPAQUE_BLACK = -0x1000000 // 0xFF000000.toInt()

        val VIDEO = AndroidGreenScreenBackground(
            type = AndroidGreenScreenBackgroundType.VIDEO,
            argbColor = OPAQUE_BLACK,
            filePath = null,
            scaleMode = AndroidGreenScreenBackgroundScaleMode.ASPECT_FILL,
        )

        /**
         * Parses the nested `greenScreenBackground` map. A null map (key absent)
         * or an unrecognized `type` both degrade to [VIDEO].
         */
        fun parse(map: Map<*, *>?): AndroidGreenScreenBackground {
            if (map == null) return VIDEO
            return when (map["type"] as? String) {
                "solidColor" -> {
                    val color = (map["argbColor"] as? Number)?.toInt() ?: OPAQUE_BLACK
                    AndroidGreenScreenBackground(
                        type = AndroidGreenScreenBackgroundType.SOLID_COLOR,
                        argbColor = color,
                        filePath = null,
                        scaleMode = AndroidGreenScreenBackgroundScaleMode.ASPECT_FILL,
                    )
                }
                "image" -> {
                    val path = (map["filePath"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
                    val scaleMode = when (map["scaleMode"] as? String) {
                        "aspectFit" -> AndroidGreenScreenBackgroundScaleMode.ASPECT_FIT
                        else -> AndroidGreenScreenBackgroundScaleMode.ASPECT_FILL
                    }
                    AndroidGreenScreenBackground(
                        type = AndroidGreenScreenBackgroundType.IMAGE,
                        argbColor = OPAQUE_BLACK,
                        filePath = path,
                        scaleMode = scaleMode,
                    )
                }
                else -> VIDEO
            }
        }
    }
}
