package com.connects.vanguard_media_engine.export

import kotlin.math.abs
import kotlin.math.roundToInt

// ── AndroidTimelineTransitionDescriptor (P5-COMPOSITOR-TRANS production route) ─
//
// Validated, index-bound description of one compositor-owned clip overlap
// transition in an `exportTimeline` draft. Owns parsing/validation of the raw
// `draft.transitions` maps (wire keys: `id`, `type`, `durationSeconds`,
// `fromClipId`, `toClipId`; see Dart VGTransitionDescriptor.toMap) against the
// parsed clip order, and the pure overlap-adjusted timeline arithmetic shared
// by the export session and the Vulkan encoder. It knows nothing about
// decoders, MethodChannels, or rendering.
//
// Closed supported type set (Type): none (hard cut), dissolve/crossfade,
// fade (two-phase fade through black: the outgoing clip dips to black over
// the first half of the overlap, the incoming clip rises from black over the
// second half -- never aliased to a dissolve), slideLeft/Right/Up/Down,
// wipeLeft/Right/Up/Down -- exactly the families the native compositor math
// (vanguard::compositors::TransitionType) and the production Vulkan / GLES
// transition seams implement. Any other type fails closed with
// UNSUPPORTED_EXPORT_FEATURE; it is never silently mapped to a dissolve or a
// hard cut.
//
// Validation rules for a non-hard-cut transition (all fail closed):
//   - fromClipId / toClipId present, non-blank, and resolving to parsed clips
//     that carry an `id` (INVALID_ARG otherwise; duplicate clip ids are also
//     INVALID_ARG since binding would be ambiguous);
//   - the bound clips are adjacent in timeline order (to == from + 1);
//   - at most one non-hard-cut transition per clip boundary;
//   - durationSeconds finite and > 0 (INVALID_ARG);
//   - durationSeconds <= both adjacent clip durations, and the two transitions
//     touching any one clip may not together exceed that clip's duration
//     (a frame may belong to at most one overlap) -- UNSUPPORTED_EXPORT_FEATURE.
// Hard-cut (`none`) entries are accepted and dropped: they change nothing.
data class AndroidTimelineTransitionDescriptor(
    val transitionId: String,
    val type: Type,
    val durationSeconds: Double,
    val fromClipId: String,
    val toClipId: String,
    /** Index of the outgoing clip in the parsed clip order. */
    val fromClipIndex: Int,
    /** Index of the incoming clip in the parsed clip order (always fromClipIndex + 1). */
    val toClipIndex: Int,
) {
    val isHardCut: Boolean get() = type == Type.NONE

    /**
     * Number of output frames the overlap window occupies at [fps]: the
     * rounded duration, never below one frame. The transition progress for
     * overlap frame j (0-based) is (j + 1) / (count + 1), strictly inside
     * (0, 1) so the frames before/after remain pure from/to.
     */
    fun overlapFrameCount(fps: Int): Int = overlapFrameCount(durationSeconds, fps)

    /** Transition progress for 0-based overlap frame [index] of [count] frames. */
    fun progressForOverlapFrame(index: Int, count: Int): Double {
        val denominator = (count.coerceAtLeast(1) + 1).toDouble()
        return ((index + 1).toDouble() / denominator).coerceIn(0.0, 1.0)
    }

    /**
     * Supported transition families. [nativeCode] is the wire code consumed by
     * VanguardNativeBridge.renderAndroidTimelineVulkanExportTransitionFrame and
     * VanguardNativeBridge.drawAndroidTimelineGlesTransitionExportFrame
     * (0 = hard cut, never sent to those routes). Codes map 1:1 onto
     * vanguard::compositors::TransitionType in the Android JNI translation
     * units; FADE (10) is the two-phase fade-through-black family
     * (TransitionType::kFade), distinct from CROSSFADE (1).
     */
    enum class Type(val wireNames: List<String>, val nativeCode: Int) {
        NONE(listOf("none"), 0),
        CROSSFADE(listOf("dissolve", "crossfade"), 1),
        WIPE_LEFT(listOf("wipeLeft"), 2),
        WIPE_RIGHT(listOf("wipeRight"), 3),
        WIPE_UP(listOf("wipeUp"), 4),
        WIPE_DOWN(listOf("wipeDown"), 5),
        SLIDE_LEFT(listOf("slideLeft"), 6),
        SLIDE_RIGHT(listOf("slideRight"), 7),
        SLIDE_UP(listOf("slideUp"), 8),
        SLIDE_DOWN(listOf("slideDown"), 9),
        FADE(listOf("fade"), 10),
        ;

        /** Canonical wire name (first alias). */
        val wireName: String get() = wireNames.first()

        companion object {
            /** Case-insensitive lookup over the closed alias set; null when unsupported. */
            fun fromWireName(raw: String): Type? {
                val trimmed = raw.trim()
                return values().firstOrNull { type ->
                    type.wireNames.any { it.equals(trimmed, ignoreCase = true) }
                }
            }
        }
    }

    /** Minimal clip view needed to bind and validate a transition. */
    data class ClipRef(
        val id: String?,
        val durationSeconds: Double,
    )

    sealed class ParseResult {
        /** Only non-hard-cut transitions, ordered by [fromClipIndex]. */
        data class Success(val transitions: List<AndroidTimelineTransitionDescriptor>) : ParseResult()

        /** [code] is an exportTimeline MethodChannel error code. */
        data class Failure(val code: String, val message: String) : ParseResult()
    }

    companion object {
        const val CODE_INVALID_ARG = "INVALID_ARG"
        const val CODE_UNSUPPORTED_EXPORT_FEATURE = "UNSUPPORTED_EXPORT_FEATURE"

        private const val DURATION_EPSILON = 1e-9

        /** See [AndroidTimelineTransitionDescriptor.overlapFrameCount]. */
        fun overlapFrameCount(durationSeconds: Double, fps: Int): Int {
            if (!durationSeconds.isFinite() || durationSeconds <= 0.0 || fps <= 0) return 0
            return (durationSeconds * fps).roundToInt().coerceAtLeast(1)
        }

        /**
         * Overlap-adjusted timeline duration: sum of clip durations minus the
         * sum of non-hard-cut transition durations.
         */
        fun timelineDurationSeconds(
            clipDurationsSeconds: List<Double>,
            transitions: List<AndroidTimelineTransitionDescriptor>,
        ): Double {
            val clips = clipDurationsSeconds.sum()
            val overlaps = transitions.filter { !it.isHardCut }.sumOf { it.durationSeconds }
            return (clips - overlaps).coerceAtLeast(0.0)
        }

        /**
         * Parses and validates raw `draft.transitions` entries against the
         * parsed clip order. Never throws.
         */
        fun parseList(rawTransitions: List<*>, clips: List<ClipRef>): ParseResult {
            if (rawTransitions.isEmpty()) return ParseResult.Success(emptyList())

            // Clip id -> index binding. Duplicate ids make binding ambiguous.
            val indexById = HashMap<String, Int>()
            for ((index, clip) in clips.withIndex()) {
                val id = clip.id?.trim()
                if (id.isNullOrEmpty()) continue
                if (indexById.containsKey(id)) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: duplicate clip id '$id' cannot bind transitions",
                    )
                }
                indexById[id] = index
            }

            val parsed = ArrayList<AndroidTimelineTransitionDescriptor>()
            val boundaries = HashSet<Int>()
            for ((entryIndex, raw) in rawTransitions.withIndex()) {
                val map = raw as? Map<*, *>
                    ?: return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: draft.transitions[$entryIndex] is malformed",
                    )
                val rawType = map["type"] as? String
                    ?: return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: draft.transitions[$entryIndex].type required",
                    )
                val type = Type.fromWireName(rawType)
                    ?: return ParseResult.Failure(
                        CODE_UNSUPPORTED_EXPORT_FEATURE,
                        "exportTimeline: transition type '$rawType' is not supported " +
                            "(supported: ${Type.values().flatMap { it.wireNames }.joinToString(", ")})",
                    )
                if (type == Type.NONE) continue

                val transitionId = (map["id"] as? String)?.trim().orEmpty().ifEmpty { "transition_$entryIndex" }
                val fromClipId = (map["fromClipId"] as? String)?.trim()
                val toClipId = (map["toClipId"] as? String)?.trim()
                if (fromClipId.isNullOrEmpty() || toClipId.isNullOrEmpty()) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: transition '$transitionId' requires fromClipId and toClipId",
                    )
                }
                val fromIndex = indexById[fromClipId]
                    ?: return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: transition '$transitionId' fromClipId '$fromClipId' " +
                            "does not match a clip id",
                    )
                val toIndex = indexById[toClipId]
                    ?: return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: transition '$transitionId' toClipId '$toClipId' " +
                            "does not match a clip id",
                    )
                if (toIndex != fromIndex + 1) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: transition '$transitionId' must bind adjacent clips " +
                            "(from index $fromIndex, to index $toIndex)",
                    )
                }
                if (!boundaries.add(fromIndex)) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: more than one transition binds clips $fromIndex and $toIndex",
                    )
                }
                val duration = (map["durationSeconds"] as? Number)?.toDouble()
                if (duration == null || !duration.isFinite() || duration <= 0.0) {
                    return ParseResult.Failure(
                        CODE_INVALID_ARG,
                        "exportTimeline: transition '$transitionId' durationSeconds must be a " +
                            "positive finite number",
                    )
                }
                val fromDuration = clips[fromIndex].durationSeconds
                val toDuration = clips[toIndex].durationSeconds
                if (duration > fromDuration + DURATION_EPSILON || duration > toDuration + DURATION_EPSILON) {
                    return ParseResult.Failure(
                        CODE_UNSUPPORTED_EXPORT_FEATURE,
                        "exportTimeline: transition '$transitionId' duration $duration exceeds an " +
                            "adjacent clip duration (from=$fromDuration, to=$toDuration)",
                    )
                }
                parsed.add(
                    AndroidTimelineTransitionDescriptor(
                        transitionId = transitionId,
                        type = type,
                        durationSeconds = duration,
                        fromClipId = fromClipId,
                        toClipId = toClipId,
                        fromClipIndex = fromIndex,
                        toClipIndex = toIndex,
                    ),
                )
            }

            parsed.sortBy { it.fromClipIndex }

            // A clip touched by two overlaps must be long enough for both:
            // otherwise one decoded frame would belong to two windows.
            for (i in 1 until parsed.size) {
                val previous = parsed[i - 1]
                val next = parsed[i]
                if (previous.toClipIndex != next.fromClipIndex) continue
                val sharedDuration = clips[next.fromClipIndex].durationSeconds
                val combined = previous.durationSeconds + next.durationSeconds
                if (combined > sharedDuration + DURATION_EPSILON) {
                    return ParseResult.Failure(
                        CODE_UNSUPPORTED_EXPORT_FEATURE,
                        "exportTimeline: transitions '${previous.transitionId}' and " +
                            "'${next.transitionId}' overlap inside clip ${next.fromClipIndex} " +
                            "(combined $combined > clip duration $sharedDuration)",
                    )
                }
            }

            return ParseResult.Success(parsed)
        }

        /** Whether two durations agree within [DURATION_EPSILON]. */
        fun durationsMatch(a: Double, b: Double): Boolean = abs(a - b) <= DURATION_EPSILON
    }
}
