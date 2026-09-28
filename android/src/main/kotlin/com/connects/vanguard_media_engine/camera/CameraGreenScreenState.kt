package com.connects.vanguard_media_engine.camera

// ── CameraGreenScreenState ───────────────────────────────────────────────────
//
// F2 (Android livestream green screen): immutable, validated copy of the
// canonical `greenScreen` VGFilterSpec parameters
// (packages/UMF/Docs/Vanguard_Unified_Camera_GreenScreen_Contract.md §3):
//
//   backgroundType  "solidColor" | "imageFile"
//   argb            required for solidColor (0xAARRGGBB; alpha byte ignored)
//   imagePath       required for imageFile (non-empty absolute path to an
//                   existing regular file; checked at parse time)
//   scaleMode       "aspectFill" (default) | "aspectFit"; imageFile only
//   scale           foreground scale, clamped to [0.25, 3.0]
//   offsetX/offsetY foreground offset, each clamped to [-1.0, 1.0]
//
// Every constructor path validates vocabulary and required fields and throws
// IllegalArgumentException BEFORE any state exists, so a caller that holds
// the active state only replaces it once parsing succeeded. Hot updates merge
// into a copy through the same validation ([mergeUpdates]); the previous
// instance is untouched.
//
// Pure Kotlin: no GL, no Android framework types. The only I/O is the
// imageFile existence check (java.io.File.isFile), so a nonexistent or
// non-file path fails the transaction here (Dart rolls back) instead of
// reaching the GPU thread — the same check iOS makes in
// VGGreenScreenBackgroundProvider.imageFileProviderWithPath.

import java.io.File

data class CameraGreenScreenState(
    val backgroundType: BackgroundType,
    val argb: Int,
    val imagePath: String?,
    val scaleMode: ScaleMode,
    val scale: Float,
    val offsetX: Float,
    val offsetY: Float,
    val enabled: Boolean,
) {
    enum class BackgroundType(val wire: String) {
        SOLID_COLOR("solidColor"),
        IMAGE_FILE("imageFile"),
    }

    enum class ScaleMode(val wire: String) {
        ASPECT_FILL("aspectFill"),
        ASPECT_FIT("aspectFit"),
    }

    /** True when the compositor must run (an explicitly disabled spec is a no-op). */
    val isActive: Boolean get() = enabled

    /** Canonical parameter map (the wire shape), used as the merge base for hot updates. */
    fun toParameterMap(): Map<String, Any?> = buildMap {
        put(KEY_BACKGROUND_TYPE, backgroundType.wire)
        put(KEY_SCALE_MODE, scaleMode.wire)
        when (backgroundType) {
            BackgroundType.SOLID_COLOR -> put(KEY_ARGB, argb)
            BackgroundType.IMAGE_FILE -> put(KEY_IMAGE_PATH, imagePath)
        }
        put(KEY_SCALE, scale)
        put(KEY_OFFSET_X, offsetX)
        put(KEY_OFFSET_Y, offsetY)
    }

    /**
     * Returns a new state with [updates] (a `parameterUpdates["greenScreen"]`
     * map: a background swap or a transform update, any subset of the
     * canonical keys) merged over this one and fully re-validated.
     *
     * @throws IllegalArgumentException for an unknown key, invalid vocabulary
     *   or a missing required field of the (possibly new) background type.
     *   `this` is never modified.
     */
    fun mergeUpdates(updates: Map<*, *>): CameraGreenScreenState {
        val merged = LinkedHashMap<String, Any?>(toParameterMap())
        for ((rawKey, value) in updates) {
            val key = rawKey as? String
                ?: throw IllegalArgumentException("greenScreen parameter keys must be strings, got $rawKey")
            if (key !in ALL_KEYS) {
                throw IllegalArgumentException("greenScreen: unknown parameter \"$key\"")
            }
            merged[key] = value
        }
        // A background-type swap must come with its own required field: never
        // reuse the previous type's argb/imagePath for the new type.
        val newType = merged[KEY_BACKGROUND_TYPE] as? String
        if (updates.containsKey(KEY_BACKGROUND_TYPE) && newType != backgroundType.wire) {
            if (newType == BackgroundType.SOLID_COLOR.wire && !updates.containsKey(KEY_ARGB)) {
                throw IllegalArgumentException("greenScreen: switching to solidColor requires \"argb\"")
            }
            if (newType == BackgroundType.IMAGE_FILE.wire && !updates.containsKey(KEY_IMAGE_PATH)) {
                throw IllegalArgumentException("greenScreen: switching to imageFile requires \"imagePath\"")
            }
        }
        return fromParameters(merged, enabled = enabled)
    }

    companion object {
        const val FILTER_TYPE = "greenScreen"

        const val KEY_BACKGROUND_TYPE = "backgroundType"
        const val KEY_ARGB = "argb"
        const val KEY_IMAGE_PATH = "imagePath"
        const val KEY_SCALE_MODE = "scaleMode"
        const val KEY_SCALE = "scale"
        const val KEY_OFFSET_X = "offsetX"
        const val KEY_OFFSET_Y = "offsetY"

        private val ALL_KEYS = setOf(
            KEY_BACKGROUND_TYPE, KEY_ARGB, KEY_IMAGE_PATH, KEY_SCALE_MODE,
            KEY_SCALE, KEY_OFFSET_X, KEY_OFFSET_Y,
        )

        const val MIN_SCALE = 0.25f
        const val MAX_SCALE = 3.0f
        const val MIN_OFFSET = -1.0f
        const val MAX_OFFSET = 1.0f

        /** Both spellings the Dart side and older callers use for the filter type. */
        fun isGreenScreenType(type: String?): Boolean =
            type != null && (type == FILTER_TYPE || type.equals("greenscreen", ignoreCase = true))

        /**
         * Parses one `filterStack` entry (`{type, enabled, parameters}`, the
         * VGFilterSpec.toMap shape) into a validated state.
         *
         * @throws IllegalArgumentException when the entry is malformed.
         */
        fun fromFilterMap(filter: Map<*, *>): CameraGreenScreenState {
            val type = filter["type"] as? String
            require(isGreenScreenType(type)) { "greenScreen: filter type must be greenScreen, got $type" }
            val enabled = (filter["enabled"] as? Boolean) ?: true
            val params = filter["parameters"] as? Map<*, *>
                ?: throw IllegalArgumentException("greenScreen: \"parameters\" map is required")
            return fromParameters(params, enabled)
        }

        /**
         * Validates and clamps a canonical parameter map.
         *
         * @throws IllegalArgumentException for unknown keys, invalid
         *   vocabulary, missing required fields, an imageFile path that is not
         *   an existing regular file, or non-numeric transform values.
         */
        fun fromParameters(params: Map<*, *>, enabled: Boolean): CameraGreenScreenState {
            for (rawKey in params.keys) {
                val key = rawKey as? String
                    ?: throw IllegalArgumentException("greenScreen parameter keys must be strings, got $rawKey")
                require(key in ALL_KEYS) { "greenScreen: unknown parameter \"$key\"" }
            }

            val rawType = params[KEY_BACKGROUND_TYPE]
            val backgroundType = when (rawType) {
                BackgroundType.SOLID_COLOR.wire -> BackgroundType.SOLID_COLOR
                BackgroundType.IMAGE_FILE.wire -> BackgroundType.IMAGE_FILE
                else -> throw IllegalArgumentException(
                    "greenScreen: backgroundType must be \"solidColor\" or \"imageFile\", got $rawType",
                )
            }

            val rawScaleMode = params[KEY_SCALE_MODE]
            val scaleMode = when (rawScaleMode) {
                null, ScaleMode.ASPECT_FILL.wire -> ScaleMode.ASPECT_FILL
                ScaleMode.ASPECT_FIT.wire -> ScaleMode.ASPECT_FIT
                else -> throw IllegalArgumentException(
                    "greenScreen: scaleMode must be \"aspectFill\" or \"aspectFit\", got $rawScaleMode",
                )
            }

            var argb = OPAQUE_BLACK
            var imagePath: String? = null
            when (backgroundType) {
                BackgroundType.SOLID_COLOR -> {
                    val rawArgb = params[KEY_ARGB] as? Number
                        ?: throw IllegalArgumentException("greenScreen: solidColor requires a numeric \"argb\"")
                    // 0xAARRGGBB arrives as a Long above Int.MAX_VALUE from Dart.
                    argb = rawArgb.toLong().toInt()
                }
                BackgroundType.IMAGE_FILE -> {
                    val rawPath = (params[KEY_IMAGE_PATH] as? String)?.trim()
                    require(!rawPath.isNullOrEmpty()) { "greenScreen: imageFile requires a non-empty \"imagePath\"" }
                    require(rawPath.startsWith("/")) { "greenScreen: imagePath must be an absolute path, got $rawPath" }
                    require(File(rawPath).isFile) {
                        "greenScreen: imagePath does not exist or is not a file: $rawPath"
                    }
                    imagePath = rawPath
                }
            }

            val scale = readFloat(params, KEY_SCALE, default = 1.0f).coerceIn(MIN_SCALE, MAX_SCALE)
            val offsetX = readFloat(params, KEY_OFFSET_X, default = 0.0f).coerceIn(MIN_OFFSET, MAX_OFFSET)
            val offsetY = readFloat(params, KEY_OFFSET_Y, default = 0.0f).coerceIn(MIN_OFFSET, MAX_OFFSET)

            return CameraGreenScreenState(
                backgroundType = backgroundType,
                argb = argb,
                imagePath = imagePath,
                scaleMode = scaleMode,
                scale = scale,
                offsetX = offsetX,
                offsetY = offsetY,
                enabled = enabled,
            )
        }

        private const val OPAQUE_BLACK = -0x1000000 // 0xFF000000

        private fun readFloat(params: Map<*, *>, key: String, default: Float): Float {
            if (!params.containsKey(key)) return default
            val raw = params[key] ?: return default
            val value = (raw as? Number)?.toFloat()
                ?: throw IllegalArgumentException("greenScreen: \"$key\" must be a number, got $raw")
            require(value.isFinite()) { "greenScreen: \"$key\" must be finite" }
            return value
        }
    }
}
