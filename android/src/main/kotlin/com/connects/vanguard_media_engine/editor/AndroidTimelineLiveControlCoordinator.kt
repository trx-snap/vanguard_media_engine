package com.connects.vanguard_media_engine.editor

import io.flutter.plugin.common.MethodChannel

/**
 * Phase 10-C-3N Android: owns the public Dart VGTimelineLiveControls route
 * (timeline_setFilterChain) as an honest guard route only.
 *
 * Non-claims (read before touching this file):
 *  - This slice does NOT implement live visual filter evaluation on Android.
 *    No filters are applied to pixels, and no GL/filter-node/shader code is
 *    added by this route.
 *  - An empty or all-disabled filter chain replying success(null) proves only
 *    route reachability, guard ordering, and a satisfiable no-filter
 *    postcondition ("no filters are applied" holds trivially when there are
 *    none to apply). It is not evidence of filter application.
 *  - Any recognized, enabled filter chain fails closed with
 *    UNSUPPORTED_TIMELINE_FEATURE. No visual parity with iOS is claimed or
 *    implied by this route.
 *
 * The known filter type set `{ "lut", "beauty", "segmentation" }` mirrors the
 * native runtime authority in ios/Classes/VanguardGraphRuntime.m:1305 (not
 * Dart's wider debug-only validator set), so UNKNOWN_FILTER is consistent
 * across platforms even though Android cannot apply any of them.
 *
 * Stateless: holds no native resources, runs no async work, and does no I/O.
 * Calls arrive on the platform main thread and this route replies
 * synchronously exactly once per call.
 */
class AndroidTimelineLiveControlCoordinator(
    private val activeTextureIdProvider: () -> Long?,
) {
    companion object {
        private val KNOWN_FILTER_TYPES = setOf("lut", "beauty", "segmentation")

        private val OWNED_METHODS = setOf(
            "timeline_setFilterChain",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "timeline_setFilterChain" -> timelineSetFilterChain(args, result)
            else -> return false
        }
        return true
    }

    // ── timeline_setFilterChain ─────────────────────────────────────────────────

    private fun timelineSetFilterChain(args: Map<*, *>?, result: MethodChannel.Result) {
        // 1-2: textureId must be a non-negative Int or Long. Reject Boolean,
        // Double, Float, String, and any other type explicitly -- do not use
        // (raw as? Number)?.toLong(), which would silently truncate floats.
        val rawTextureId = args?.get("textureId")
        val textureId: Long = when (rawTextureId) {
            is Int -> rawTextureId.toLong()
            is Long -> rawTextureId
            else -> {
                result.error("INVALID_ARG", "timeline_setFilterChain: textureId must be a non-negative integer", null)
                return
            }
        }
        if (textureId < 0L) {
            result.error("INVALID_ARG", "timeline_setFilterChain: textureId must be non-negative, got $textureId", null)
            return
        }

        // 3: filters must be a List whose elements are all Maps.
        val rawFilters = args?.get("filters")
        if (rawFilters !is List<*> || rawFilters.any { it !is Map<*, *> }) {
            result.error("INVALID_ARG", "timeline_setFilterChain: filters must be a list of filter maps", null)
            return
        }
        @Suppress("UNCHECKED_CAST")
        val filters = rawFilters as List<Map<*, *>>

        // 4: no active timeline.
        val activeTextureId = activeTextureIdProvider()
        if (activeTextureId == null) {
            result.error("NO_TIMELINE", "timeline_setFilterChain: no active timeline session", null)
            return
        }

        // 5: requested textureId does not match the active timeline.
        if (activeTextureId != textureId) {
            result.error(
                "STALE_TIMELINE",
                "timeline_setFilterChain: textureId=$textureId does not match active timeline textureId=$activeTextureId",
                null,
            )
            return
        }

        // 6: any filter entry with a missing/non-String/unrecognized type.
        for (filter in filters) {
            val type = filter["type"]
            if (type !is String || type !in KNOWN_FILTER_TYPES) {
                result.error("UNKNOWN_FILTER", "timeline_setFilterChain: unrecognized filter type: $type", null)
                return
            }
        }

        // 7: empty filter list -- "no filters are applied" is trivially satisfied.
        if (filters.isEmpty()) {
            result.success(null)
            return
        }

        // 8-9: all types are known at this point. Missing/non-Boolean 'enabled'
        // defaults to true, matching the Dart default. Success only when every
        // entry is disabled; otherwise this route honestly fails closed because
        // Android live playback has no visual filter evaluation to apply the
        // enabled filter(s) with.
        val anyEnabled = filters.any { (it["enabled"] as? Boolean) ?: true }
        if (!anyEnabled) {
            result.success(null)
            return
        }

        result.error(
            "UNSUPPORTED_TIMELINE_FEATURE",
            "timeline_setFilterChain: Android live playback cannot apply enabled filters in this slice",
            null,
        )
    }
}
