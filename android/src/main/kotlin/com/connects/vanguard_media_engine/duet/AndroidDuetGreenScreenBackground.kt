package com.connects.vanguard_media_engine.duet

// -----------------------------------------------------------------------------
// Static green-screen background model (engine preview and export parsing).
// -----------------------------------------------------------------------------
//
// Mirrors VGDuetGreenScreenBackground.toMap() on the Dart side
// (lib/src/duet/vg_duet_models.dart): the nested `greenScreenBackground` map
// on a layoutConfigMap carries `type` / `argbColor` / `filePath` / `scaleMode`.
// Parsing here never throws: unknown/absent `type` degrades to [VIDEO], an
// invalid solid color degrades to opaque black, and an image with a missing
// path degrades to opaque black (a decode failure at draw time degrades the
// same way, but that can only be detected once the compositor attempts the
// decode).

/** The type of background displayed beneath the green-screen camera layer. */
enum class AndroidDuetGreenScreenBackgroundType {
    VIDEO, SOLID_COLOR, IMAGE
}

/** Scaling mode for static (solid color / image) green-screen backgrounds. */
enum class AndroidDuetBackgroundScaleMode {
    ASPECT_FILL, ASPECT_FIT
}

/**
 * Immutable, parsed green-screen background specification.
 *
 * [argbColor] is only meaningful for [AndroidDuetGreenScreenBackgroundType.SOLID_COLOR];
 * [filePath] and [scaleMode] only for [AndroidDuetGreenScreenBackgroundType.IMAGE].
 */
data class AndroidDuetGreenScreenBackground(
    val type: AndroidDuetGreenScreenBackgroundType,
    val argbColor: Int,
    val filePath: String?,
    val scaleMode: AndroidDuetBackgroundScaleMode,
) {
    /**
     * True when the source video should be composited as the background (the
     * default). The render loop uses this to decide whether active playback
     * needs sustained decoder Step ticks at all.
     */
    val usesSourceVideo: Boolean get() = type == AndroidDuetGreenScreenBackgroundType.VIDEO

    companion object {
        private const val OPAQUE_BLACK = -0x1000000 // 0xFF000000.toInt()

        val VIDEO = AndroidDuetGreenScreenBackground(
            type = AndroidDuetGreenScreenBackgroundType.VIDEO,
            argbColor = OPAQUE_BLACK,
            filePath = null,
            scaleMode = AndroidDuetBackgroundScaleMode.ASPECT_FILL,
        )

        /**
         * Parses the nested `greenScreenBackground` map. A null map (key absent)
         * or an unrecognized `type` both degrade to [VIDEO].
         */
        fun parse(map: Map<*, *>?): AndroidDuetGreenScreenBackground {
            if (map == null) return VIDEO
            return when (map["type"] as? String) {
                "solidColor" -> {
                    val color = (map["argbColor"] as? Number)?.toInt() ?: OPAQUE_BLACK
                    AndroidDuetGreenScreenBackground(
                        type = AndroidDuetGreenScreenBackgroundType.SOLID_COLOR,
                        argbColor = color,
                        filePath = null,
                        scaleMode = AndroidDuetBackgroundScaleMode.ASPECT_FILL,
                    )
                }
                "image" -> {
                    val path = (map["filePath"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
                    val scaleMode = when (map["scaleMode"] as? String) {
                        "aspectFit" -> AndroidDuetBackgroundScaleMode.ASPECT_FIT
                        else -> AndroidDuetBackgroundScaleMode.ASPECT_FILL
                    }
                    AndroidDuetGreenScreenBackground(
                        type = AndroidDuetGreenScreenBackgroundType.IMAGE,
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
