package com.connects.vanguard_media_engine.greenscreen

/**
 * Parses the `filters` list sent to `setCameraFilterChain` for the
 * independent Green Screen camera graph.
 *
 * Contract (Android UFM green-screen parity slice):
 *   - An empty list, or a list whose filters are all disabled, means
 *     "disable green screen" ([ParseResult.Parsed.greenScreenEnabled] = false).
 *   - Exactly one enabled `greenScreen` filter is the only supported active
 *     state. More than one enabled `greenScreen` filter fails with
 *     `BAD_ARGS` rather than silently using the first.
 *   - `parameters.backgroundType == "solidColor"` with an int `parameters.argb`
 *     resolves to [OutputMode.SOLID_COLOR]; [ParseResult.Parsed.background] is
 *     the parsed solid-color background.
 *   - `parameters.backgroundType == "alpha"` resolves to [OutputMode.ALPHA];
 *     [ParseResult.Parsed.background] is `null` — alpha output does not
 *     composite over any background and no `argb` is required or read. This
 *     is a diagnostics/API-acceptance route only: no Flutter preview
 *     transparency or native renderer alpha-output proof is implied.
 *   - Any enabled filter whose `type` is not `"greenScreen"` fails with
 *     `UNKNOWN_FILTER`.
 *   - Any enabled `greenScreen` filter whose `backgroundType` is not
 *     `"solidColor"` or `"alpha"` fails with `UNSUPPORTED_FILTER_TYPE`.
 *   - Structurally malformed entries fail with `BAD_ARGS`.
 *
 * Never throws for caller mistakes — every failure path is a [ParseResult.Failure].
 */
object AndroidGreenScreenCameraFilterChain {

    /**
     * Output routing for a parsed `greenScreen` filter, tracked independently
     * of [ParseResult.Parsed.greenScreenEnabled] and
     * [ParseResult.Parsed.background].
     */
    enum class OutputMode { SOLID_COLOR, ALPHA }

    sealed class ParseResult {
        data class Parsed(
            val greenScreenEnabled: Boolean,
            val background: AndroidGreenScreenBackground?,
            val activeFilterTypes: List<String>,
            val outputMode: OutputMode,
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

        var resolvedBackground: AndroidGreenScreenBackground? = null
        var resolvedOutputMode: OutputMode? = null
        for (filter in enabledFilters) {
            if (filter.type != "greenScreen") {
                return ParseResult.Failure(
                    "UNKNOWN_FILTER",
                    "Unknown filter type: ${filter.type}",
                )
            }
            if (resolvedOutputMode != null) {
                return ParseResult.Failure(
                    "BAD_ARGS",
                    "setCameraFilterChain: only one enabled greenScreen filter is supported.",
                )
            }
            val backgroundType = filter.parameters?.get("backgroundType") as? String
            when (backgroundType) {
                "solidColor" -> {
                    val argb = (filter.parameters["argb"] as? Number)?.toInt()
                        ?: return ParseResult.Failure(
                            "BAD_ARGS",
                            "setCameraFilterChain: greenScreen solidColor requires an int 'argb'.",
                        )
                    resolvedBackground = AndroidGreenScreenBackground(
                        type = AndroidGreenScreenBackgroundType.SOLID_COLOR,
                        argbColor = argb,
                        filePath = null,
                        scaleMode = AndroidGreenScreenBackgroundScaleMode.ASPECT_FILL,
                    )
                    resolvedOutputMode = OutputMode.SOLID_COLOR
                }
                "alpha" -> {
                    resolvedBackground = null
                    resolvedOutputMode = OutputMode.ALPHA
                }
                else -> return ParseResult.Failure(
                    "UNSUPPORTED_FILTER_TYPE",
                    "Unsupported greenScreen backgroundType: ${backgroundType ?: "<missing>"}",
                )
            }
        }

        return ParseResult.Parsed(
            greenScreenEnabled = true,
            background = resolvedBackground,
            activeFilterTypes = listOf("greenScreen"),
            outputMode = resolvedOutputMode ?: OutputMode.SOLID_COLOR,
        )
    }

    private fun clearedResult(): ParseResult.Parsed = ParseResult.Parsed(
        greenScreenEnabled = false,
        background = null,
        activeFilterTypes = emptyList(),
        outputMode = OutputMode.SOLID_COLOR,
    )
}
