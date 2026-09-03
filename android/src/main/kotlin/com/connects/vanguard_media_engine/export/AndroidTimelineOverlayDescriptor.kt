package com.connects.vanguard_media_engine.export

import java.io.File

// ── AndroidTimelineOverlayDescriptor (P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A) ──
//
// Validated timeline overlay element descriptor for the UMF/Vanguard export
// pipeline. Owns parsing and preflight validation of raw `draft.overlays` maps
// against Route-A constraints.
//
// Preflight/admission only: this descriptor validates and gates overlay
// definitions before render execution; it makes no production rendering claim.
// Native rendering (Vulkan overlay compositor) is implemented in subsequent slices.
//
// Closed supported type set: sticker only. Text, emoji, or unknown types fail
// closed with UNSUPPORTED_EXPORT_FEATURE. Animated keyframes fail closed with
// UNSUPPORTED_EXPORT_FEATURE. Remote (http/https) or non-absolute asset paths fail
// with UNSUPPORTED_EXPORT_FEATURE; missing or unreadable asset files fail with
// CODE_FILE_UNREADABLE.
data class AndroidTimelineOverlayDescriptor(
    val overlayId: String,
    val type: Type,
    val startTimeSeconds: Double,
    val durationSeconds: Double,
    val translationX: Double,
    val translationY: Double,
    val width: Double,
    val height: Double,
    val rotation: Double,
    val scale: Double,
    val opacity: Double,
    val zIndex: Int,
    val assetPath: String? = null,
) {
    /** Wire id alias matching Dart/wire descriptor conventions. */
    val id: String get() = overlayId

    /**
     * Whether this overlay is active at playhead position [ptsSeconds]:
     * active interval is `[startTimeSeconds, startTimeSeconds + durationSeconds)`.
     */
    fun isActiveAtTime(ptsSeconds: Double): Boolean {
        if (!ptsSeconds.isFinite() || ptsSeconds < 0.0) return false
        if (durationSeconds <= 0.0) return false
        return ptsSeconds >= startTimeSeconds && ptsSeconds < (startTimeSeconds + durationSeconds)
    }

    /** Compatibility alias matching Dart `isActiveAtPTS`. */
    fun isActiveAtPTS(ptsSeconds: Double): Boolean = isActiveAtTime(ptsSeconds)

    /**
     * Overlay kind. Route-A accepts [STICKER] only.
     */
    enum class Type(val wireNames: List<String>) {
        STICKER(listOf("sticker")),
        TEXT(listOf("text")),
        EMOJI(listOf("emoji")),
        ;

        /** Canonical wire name (first alias). */
        val wireName: String get() = wireNames.first()

        companion object {
            /** Case-insensitive lookup over closed wire names; null when unrecognised. */
            fun fromWireName(raw: String): Type? {
                val trimmed = raw.trim()
                return values().firstOrNull { type ->
                    type.wireNames.any { it.equals(trimmed, ignoreCase = true) }
                }
            }
        }
    }

    sealed class ParseResult {
        data class Success(val overlays: List<AndroidTimelineOverlayDescriptor>) : ParseResult()
        data class Failure(val code: String, val message: String) : ParseResult()
    }

    companion object {
        const val CODE_INVALID_ARG = "INVALID_ARG"
        const val CODE_UNSUPPORTED_EXPORT_FEATURE = "UNSUPPORTED_EXPORT_FEATURE"
        const val CODE_FILE_UNREADABLE = "FILE_UNREADABLE"

        /**
         * Sorts overlays by [zIndex] ascending, breaking ties by [overlayId] ascending.
         */
        val DRAW_ORDER_COMPARATOR: Comparator<AndroidTimelineOverlayDescriptor> =
            compareBy<AndroidTimelineOverlayDescriptor> { it.zIndex }
                .thenBy { it.overlayId }

        /**
         * Parses and validates raw `draft.overlays` entries against Route-A constraints.
         * Never throws.
         */
        fun parseList(rawOverlays: List<*>): ParseResult {
            if (rawOverlays.isEmpty()) return ParseResult.Success(emptyList())

            val parsed = ArrayList<AndroidTimelineOverlayDescriptor>(rawOverlays.size)
            for ((entryIndex, raw) in rawOverlays.withIndex()) {
                val map = raw as? Map<*, *>
                    ?: return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: draft.overlays[$entryIndex] is malformed",
                    )

                val overlayId = (map["id"] as? String)?.trim()
                if (overlayId.isNullOrEmpty()) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: draft.overlays[$entryIndex].id required and must be non-blank",
                    )
                }

                val rawType = map["type"] as? String
                    ?: return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: overlay '$overlayId' type required",
                    )
                val type = Type.fromWireName(rawType)
                if (type != Type.STICKER) {
                    return ParseResult.Failure(
                        CODE_UNSUPPORTED_EXPORT_FEATURE,
                        "exportTimeline: overlay '$overlayId' type '$rawType' is not supported (only 'sticker' is supported in Route-A)",
                    )
                }

                val rawKeyframes = map["keyframes"]
                if (rawKeyframes != null) {
                    val isEmpty = when (rawKeyframes) {
                        is Collection<*> -> rawKeyframes.isEmpty()
                        is Map<*, *> -> rawKeyframes.isEmpty()
                        is Array<*> -> rawKeyframes.isEmpty()
                        is CharSequence -> rawKeyframes.isEmpty()
                        else -> false
                    }
                    if (!isEmpty) {
                        return ParseResult.Failure(
                            CODE_UNSUPPORTED_EXPORT_FEATURE,
                            "exportTimeline: overlay '$overlayId' has animated keyframes which are not supported in Route-A (keyframes must be empty)",
                        )
                    }
                }

                val assetPath = (map["assetPath"] as? String)?.trim()
                if (assetPath.isNullOrEmpty()) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: sticker overlay '$overlayId' requires non-blank assetPath",
                    )
                }
                if (assetPath.startsWith("http://") || assetPath.startsWith("https://")) {
                    return ParseResult.Failure(
                        CODE_UNSUPPORTED_EXPORT_FEATURE,
                        "exportTimeline: remote overlay sticker asset sources are not supported: '$assetPath'",
                    )
                }
                if (!assetPath.startsWith("/")) {
                    return ParseResult.Failure(
                        CODE_UNSUPPORTED_EXPORT_FEATURE,
                        "exportTimeline: non-absolute overlay sticker asset path is not supported: '$assetPath'",
                    )
                }
                val assetFile = File(assetPath)
                if (!assetFile.exists() || !assetFile.canRead()) {
                    return ParseResult.Failure(
                        CODE_FILE_UNREADABLE,
                        "exportTimeline: cannot read overlay sticker asset file: $assetPath",
                    )
                }

                val rawStart = map["startTimeSeconds"] as? Number
                val startTimeSeconds = rawStart?.toDouble()
                if (startTimeSeconds == null || !startTimeSeconds.isFinite() || startTimeSeconds < 0.0) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: overlay '$overlayId' startTimeSeconds must be a finite number >= 0.0",
                    )
                }

                val rawDuration = map["durationSeconds"] as? Number
                val durationSeconds = rawDuration?.toDouble()
                if (durationSeconds == null || !durationSeconds.isFinite() || durationSeconds <= 0.0) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: overlay '$overlayId' durationSeconds must be a finite number > 0.0",
                    )
                }

                val rawTx = map["translationX"] as? Number
                val translationX = rawTx?.toDouble()
                if (translationX == null || !translationX.isFinite()) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: overlay '$overlayId' translationX must be a finite number",
                    )
                }

                val rawTy = map["translationY"] as? Number
                val translationY = rawTy?.toDouble()
                if (translationY == null || !translationY.isFinite()) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: overlay '$overlayId' translationY must be a finite number",
                    )
                }

                val rawWidth = map["width"] as? Number
                val width = rawWidth?.toDouble()
                if (width == null || !width.isFinite() || width <= 0.0) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: overlay '$overlayId' width must be a finite number > 0.0",
                    )
                }

                val rawHeight = map["height"] as? Number
                val height = rawHeight?.toDouble()
                if (height == null || !height.isFinite() || height <= 0.0) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: overlay '$overlayId' height must be a finite number > 0.0",
                    )
                }

                val rawRotation = map["rotation"] as? Number
                val rotation = rawRotation?.toDouble()
                if (rotation == null || !rotation.isFinite()) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: overlay '$overlayId' rotation must be a finite number",
                    )
                }

                val rawScale = map["scale"] as? Number
                val scale = rawScale?.toDouble()
                if (scale == null || !scale.isFinite() || scale <= 0.0) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: overlay '$overlayId' scale must be a finite number > 0.0",
                    )
                }

                val rawOpacity = map["opacity"] as? Number
                val opacity = rawOpacity?.toDouble()
                if (opacity == null || !opacity.isFinite() || opacity < 0.0 || opacity > 1.0) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: overlay '$overlayId' opacity must be a finite number in [0.0, 1.0]",
                    )
                }

                val rawZIndex = map["zIndex"] as? Number
                val zIndexDouble = rawZIndex?.toDouble()
                if (zIndexDouble == null || !zIndexDouble.isFinite()) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: overlay '$overlayId' zIndex must be a finite number",
                    )
                }
                val zIndex = rawZIndex.toInt()

                parsed.add(
                    AndroidTimelineOverlayDescriptor(
                        overlayId = overlayId,
                        type = type,
                        startTimeSeconds = startTimeSeconds,
                        durationSeconds = durationSeconds,
                        translationX = translationX,
                        translationY = translationY,
                        width = width,
                        height = height,
                        rotation = rotation,
                        scale = scale,
                        opacity = opacity,
                        zIndex = zIndex,
                        assetPath = assetPath,
                    ),
                )
            }

            return ParseResult.Success(parsed)
        }
    }
}
