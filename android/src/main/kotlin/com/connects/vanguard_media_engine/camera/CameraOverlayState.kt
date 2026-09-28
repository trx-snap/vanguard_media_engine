package com.connects.vanguard_media_engine.camera

// ── CameraOverlayState ───────────────────────────────────────────────────────
//
// G1-B (Android livestream text/sticker overlay): immutable, validated copy of
// the canonical `overlay` VGFilterSpec produced by the Dart
// `VGFilterSpecs.overlay(...)` factory (G1-A contract, commit 62f8cb1):
//
//   type        "overlay"
//   enabled     Boolean (false, or an empty items list, clears every overlay)
//   parameters.canvas  {width: 720, height: 1280}   — pinned, exactly
//   parameters.items[] (max 8) each:
//     id        non-empty String
//     kind      "text" | "sticker"
//     x, y      normalized top-left in [0, 1] of the pinned portrait canvas
//     w, h      normalized size in (0, 1]
//     opacity   [0, 1] (absent → 1.0)
//     z         integer paint order in [0, 1024] (absent → 0)
//     text      text kind only: non-empty, ≤ 120 chars; sticker must omit it
//     assetPath sticker kind only: absolute local `.png`/`.jpg`/`.jpeg` path
//               (case-insensitive extension, no URI scheme); text must omit it
//
// Every constructor path validates vocabulary, bounds and required fields and
// throws IllegalArgumentException BEFORE any state exists, so the holder of the
// active state only replaces it once parsing succeeded (same policy as
// CameraGreenScreenState). Items are stored sorted by ascending `z`, stable in
// original list order for equal `z`, which is the paint order the compositor
// uses.
//
// Pure Kotlin: no GL, no Android framework types, no I/O.

import kotlin.math.floor

data class CameraOverlayState(
    /** Paint order: ascending `z`, stable by original list order for equal `z`. */
    val items: List<Item>,
    val enabled: Boolean,
) {
    enum class Kind(val wire: String) {
        TEXT("text"),
        STICKER("sticker"),
    }

    data class Item(
        val id: String,
        val kind: Kind,
        val x: Float,
        val y: Float,
        val w: Float,
        val h: Float,
        val opacity: Float,
        val z: Int,
        val text: String?,
        val assetPath: String?,
    )

    /** True when the compositor must run: enabled with at least one item. */
    val isActive: Boolean get() = enabled && items.isNotEmpty()

    companion object {
        const val FILTER_TYPE = "overlay"

        const val CANVAS_WIDTH = 720
        const val CANVAS_HEIGHT = 1280
        const val MAX_ITEMS = 8
        const val MAX_TEXT_LENGTH = 120
        const val MIN_Z = 0
        const val MAX_Z = 1024

        const val KEY_CANVAS = "canvas"
        const val KEY_ITEMS = "items"
        const val KEY_WIDTH = "width"
        const val KEY_HEIGHT = "height"
        const val KEY_ID = "id"
        const val KEY_KIND = "kind"
        const val KEY_X = "x"
        const val KEY_Y = "y"
        const val KEY_W = "w"
        const val KEY_H = "h"
        const val KEY_OPACITY = "opacity"
        const val KEY_Z = "z"
        const val KEY_TEXT = "text"
        const val KEY_ASSET_PATH = "assetPath"

        private val PARAMETER_KEYS = setOf(KEY_CANVAS, KEY_ITEMS)
        private val ITEM_KEYS = setOf(
            KEY_ID, KEY_KIND, KEY_X, KEY_Y, KEY_W, KEY_H, KEY_OPACITY, KEY_Z, KEY_TEXT, KEY_ASSET_PATH,
        )
        private val STICKER_EXTENSIONS = listOf(".png", ".jpg", ".jpeg")

        fun isOverlayType(type: String?): Boolean = type != null && type.equals(FILTER_TYPE, ignoreCase = true)

        /**
         * Parses one `filterStack` entry (`{type, enabled, parameters}`, the
         * VGFilterSpec.toMap shape) into a validated state.
         *
         * @throws IllegalArgumentException when the entry is malformed.
         */
        fun fromFilterMap(filter: Map<*, *>): CameraOverlayState {
            val type = filter["type"] as? String
            require(isOverlayType(type)) { "overlay: filter type must be overlay, got $type" }
            val rawEnabled = filter["enabled"]
            val enabled = when (rawEnabled) {
                null -> true
                is Boolean -> rawEnabled
                else -> throw IllegalArgumentException("overlay: \"enabled\" must be a boolean, got $rawEnabled")
            }
            val params = filter["parameters"] as? Map<*, *>
                ?: throw IllegalArgumentException("overlay: \"parameters\" map is required")
            return fromParameters(params, enabled)
        }

        /**
         * Validates a canonical parameter map (`{canvas, items}`).
         *
         * @throws IllegalArgumentException for unknown keys, a canvas other than
         *   exactly 720x1280, more than [MAX_ITEMS] items, or any malformed item.
         */
        fun fromParameters(params: Map<*, *>, enabled: Boolean): CameraOverlayState {
            for (rawKey in params.keys) {
                val key = rawKey as? String
                    ?: throw IllegalArgumentException("overlay parameter keys must be strings, got $rawKey")
                require(key in PARAMETER_KEYS) { "overlay: unknown parameter \"$key\"" }
            }

            val canvas = params[KEY_CANVAS] as? Map<*, *>
                ?: throw IllegalArgumentException("overlay: \"canvas\" map is required")
            val canvasWidth = readInt(canvas, KEY_WIDTH, "canvas")
            val canvasHeight = readInt(canvas, KEY_HEIGHT, "canvas")
            require(canvasWidth == CANVAS_WIDTH && canvasHeight == CANVAS_HEIGHT) {
                "overlay: canvas must be exactly ${CANVAS_WIDTH}x$CANVAS_HEIGHT, got ${canvasWidth}x$canvasHeight"
            }

            val rawItems = params[KEY_ITEMS] as? List<*>
                ?: throw IllegalArgumentException("overlay: \"items\" list is required")
            require(rawItems.size <= MAX_ITEMS) {
                "overlay: at most $MAX_ITEMS items are allowed, got ${rawItems.size}"
            }

            val parsed = ArrayList<Item>(rawItems.size)
            for ((index, rawItem) in rawItems.withIndex()) {
                val itemMap = rawItem as? Map<*, *>
                    ?: throw IllegalArgumentException("overlay: items[$index] must be a map, got $rawItem")
                parsed.add(parseItem(itemMap, index))
            }
            // sortedBy is stable: equal z keeps original list order.
            val ordered = parsed.sortedBy { it.z }
            return CameraOverlayState(items = ordered, enabled = enabled)
        }

        private fun parseItem(map: Map<*, *>, index: Int): Item {
            val where = "overlay: items[$index]"
            for (rawKey in map.keys) {
                val key = rawKey as? String
                    ?: throw IllegalArgumentException("$where keys must be strings, got $rawKey")
                require(key in ITEM_KEYS) { "$where: unknown field \"$key\"" }
            }

            val id = map[KEY_ID] as? String
                ?: throw IllegalArgumentException("$where: \"id\" must be a String")
            require(id.isNotEmpty()) { "$where: \"id\" must be non-empty" }

            val rawKind = map[KEY_KIND] as? String
                ?: throw IllegalArgumentException("$where: \"kind\" must be a String")
            val kind = when (rawKind) {
                Kind.TEXT.wire -> Kind.TEXT
                Kind.STICKER.wire -> Kind.STICKER
                else -> throw IllegalArgumentException("$where: kind must be \"text\" or \"sticker\", got $rawKind")
            }

            val x = readRequiredFloat(map, KEY_X, where)
            val y = readRequiredFloat(map, KEY_Y, where)
            val w = readRequiredFloat(map, KEY_W, where)
            val h = readRequiredFloat(map, KEY_H, where)
            require(x in 0f..1f) { "$where: x must be in [0, 1], got $x" }
            require(y in 0f..1f) { "$where: y must be in [0, 1], got $y" }
            require(w > 0f && w <= 1f) { "$where: w must be in (0, 1], got $w" }
            require(h > 0f && h <= 1f) { "$where: h must be in (0, 1], got $h" }

            val opacity = readOptionalFloat(map, KEY_OPACITY, where, default = 1f)
            require(opacity in 0f..1f) { "$where: opacity must be in [0, 1], got $opacity" }

            val z: Int = if (!map.containsKey(KEY_Z) || map[KEY_Z] == null) {
                0
            } else {
                val rawZ = map[KEY_Z] as? Number
                    ?: throw IllegalArgumentException("$where: \"z\" must be a number, got ${map[KEY_Z]}")
                val asDouble = rawZ.toDouble()
                require(asDouble.isFinite()) { "$where: \"z\" must be finite" }
                asDouble.toInt()
            }
            require(z in MIN_Z..MAX_Z) { "$where: z must be in [$MIN_Z, $MAX_Z], got $z" }

            val rawText = map[KEY_TEXT]
            if (rawText != null && rawText !is String) {
                throw IllegalArgumentException("$where: \"text\" must be a String or absent")
            }
            val rawAssetPath = map[KEY_ASSET_PATH]
            if (rawAssetPath != null && rawAssetPath !is String) {
                throw IllegalArgumentException("$where: \"assetPath\" must be a String or absent")
            }
            val text = rawText as String?
            val assetPath = rawAssetPath as String?

            when (kind) {
                Kind.TEXT -> {
                    require(!text.isNullOrEmpty()) { "$where: text overlay requires a non-empty \"text\"" }
                    require(text.length <= MAX_TEXT_LENGTH) {
                        "$where: text must be at most $MAX_TEXT_LENGTH characters, got ${text.length}"
                    }
                    require(assetPath == null) { "$where: text overlay must not carry \"assetPath\"" }
                }
                Kind.STICKER -> {
                    require(text == null) { "$where: sticker overlay must not carry \"text\"" }
                    requireStickerAssetPath(assetPath, where)
                }
            }

            return Item(
                id = id,
                kind = kind,
                x = x,
                y = y,
                w = w,
                h = h,
                opacity = opacity,
                z = z,
                text = text,
                assetPath = assetPath,
            )
        }

        private fun requireStickerAssetPath(path: String?, where: String) {
            require(!path.isNullOrBlank()) { "$where: sticker overlay requires a non-empty absolute local \"assetPath\"" }
            require(!path.contains("://")) { "$where: assetPath must be a local filesystem path, not a remote/URI path: $path" }
            require(path.startsWith("/")) { "$where: assetPath must be an absolute path starting with \"/\": $path" }
            val lower = path.lowercase()
            require(STICKER_EXTENSIONS.any { lower.endsWith(it) }) {
                "$where: assetPath must end in .png, .jpg or .jpeg (case-insensitive): $path"
            }
        }

        private fun readInt(map: Map<*, *>, key: String, where: String): Int {
            val raw = map[key] as? Number
                ?: throw IllegalArgumentException("overlay: $where.\"$key\" must be a number, got ${map[key]}")
            val asDouble = raw.toDouble()
            require(asDouble.isFinite() && asDouble == floor(asDouble)) {
                "overlay: $where.\"$key\" must be an integer, got $raw"
            }
            return asDouble.toInt()
        }

        private fun readRequiredFloat(map: Map<*, *>, key: String, where: String): Float {
            val raw = map[key] as? Number
                ?: throw IllegalArgumentException("$where: \"$key\" must be a number, got ${map[key]}")
            val value = raw.toFloat()
            require(value.isFinite()) { "$where: \"$key\" must be finite" }
            return value
        }

        private fun readOptionalFloat(map: Map<*, *>, key: String, where: String, default: Float): Float {
            if (!map.containsKey(key)) return default
            val raw = map[key] ?: return default
            val value = (raw as? Number)?.toFloat()
                ?: throw IllegalArgumentException("$where: \"$key\" must be a number, got $raw")
            require(value.isFinite()) { "$where: \"$key\" must be finite" }
            return value
        }
    }
}
