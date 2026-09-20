package com.connects.vanguard_media_engine.greenscreen

import com.connects.vanguard_media_engine.duet.AndroidDuetBackgroundScaleMode
import com.connects.vanguard_media_engine.duet.AndroidDuetGreenScreenBackground
import com.connects.vanguard_media_engine.duet.AndroidDuetGreenScreenBackgroundType

/**
 * Parses the `filters` list sent to `setCameraFilterChain` for the
 * independent Green Screen camera graph.
 *
 * Contract (Android UFM green-screen parity slice):
 *   - An empty list, or a list whose filters are all disabled, means
 *     "disable green screen" ([ParseResult.Parsed.greenScreenEnabled] = false).
 *   - Exactly one enabled `greenScreen` filter with
 *     `parameters.backgroundType == "solidColor"` and an int `parameters.argb`
 *     is the only supported active state. More than one enabled `greenScreen`
 *     filter fails with `BAD_ARGS` rather than silently using the first.
 *   - Any enabled filter whose `type` is not `"greenScreen"` fails with
 *     `UNKNOWN_FILTER`.
 *   - Any enabled `greenScreen` filter whose `backgroundType` is not
 *     `"solidColor"` (including `"alpha"`) fails with `UNSUPPORTED_FILTER_TYPE`
 *     — Android live alpha output is not implemented in this slice.
 *   - Structurally malformed entries fail with `BAD_ARGS`.
 *
 * Never throws for caller mistakes — every failure path is a [ParseResult.Failure].
 */
object AndroidGreenScreenCameraFilterChain {

    sealed class ParseResult {
        data class Parsed(
            val greenScreenEnabled: Boolean,
            val background: AndroidDuetGreenScreenBackground?,
            val activeFilterTypes: List<String>,
        ) : ParseResult()

        data class Failure(val code: String, val message: String) : ParseResult()
    }

    private data class EnabledFilter(val type: String, val parameters: Map<*, *>?)

    fun parse(filters: List<*>): ParseResult {
        if (filters.isEmpty()) {
            return clearedResult()
        }

        val enabledFilters = mutableListOf<EnabledFilter>()
        for (item in filters) {
            val entry = item as? Map<*, *>
                ?: return ParseResult.Failure(
                    "BAD_ARGS",
                    "setCameraFilterChain: each filter must be a map.",
                )
            val type = entry["type"] as? String
                ?: return ParseResult.Failure(
                    "BAD_ARGS",
                    "setCameraFilterChain: filter 'type' must be a non-null string.",
                )
            val enabled = when (val rawEnabled = entry["enabled"]) {
                null -> true
                is Boolean -> rawEnabled
                else -> return ParseResult.Failure(
                    "BAD_ARGS",
                    "setCameraFilterChain: filter 'enabled' must be a bool.",
                )
            }
            if (!enabled) continue

            val rawParameters = entry["parameters"]
            val parameters = when (rawParameters) {
                null -> null
                is Map<*, *> -> rawParameters
                else -> return ParseResult.Failure(
                    "BAD_ARGS",
                    "setCameraFilterChain: filter 'parameters' must be a map.",
                )
            }
            enabledFilters += EnabledFilter(type, parameters)
        }

        if (enabledFilters.isEmpty()) {
            return clearedResult()
        }

        var resolvedBackground: AndroidDuetGreenScreenBackground? = null
        for (filter in enabledFilters) {
            if (filter.type != "greenScreen") {
                return ParseResult.Failure(
                    "UNKNOWN_FILTER",
                    "Unknown filter type: ${filter.type}",
                )
            }
            val backgroundType = filter.parameters?.get("backgroundType") as? String
            if (backgroundType != "solidColor") {
                return ParseResult.Failure(
                    "UNSUPPORTED_FILTER_TYPE",
                    "Unsupported greenScreen backgroundType: ${backgroundType ?: "<missing>"}",
                )
            }
            val argb = (filter.parameters["argb"] as? Number)?.toInt()
                ?: return ParseResult.Failure(
                    "BAD_ARGS",
                    "setCameraFilterChain: greenScreen solidColor requires an int 'argb'.",
                )
            if (resolvedBackground != null) {
                return ParseResult.Failure(
                    "BAD_ARGS",
                    "setCameraFilterChain: only one enabled greenScreen filter is supported.",
                )
            }
            resolvedBackground = AndroidDuetGreenScreenBackground(
                type = AndroidDuetGreenScreenBackgroundType.SOLID_COLOR,
                argbColor = argb,
                filePath = null,
                scaleMode = AndroidDuetBackgroundScaleMode.ASPECT_FILL,
            )
        }

        return ParseResult.Parsed(
            greenScreenEnabled = true,
            background = resolvedBackground,
            activeFilterTypes = listOf("greenScreen"),
        )
    }

    private fun clearedResult(): ParseResult.Parsed = ParseResult.Parsed(
        greenScreenEnabled = false,
        background = null,
        activeFilterTypes = emptyList(),
    )
}
