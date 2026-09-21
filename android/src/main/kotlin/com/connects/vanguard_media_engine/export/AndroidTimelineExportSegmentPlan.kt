package com.connects.vanguard_media_engine.export

import kotlin.math.ceil

/// One ordered unit of pass-1 work. Windows are end-exclusive source pts
/// ranges in seconds; a source frame belongs to exactly one segment.
internal sealed class AndroidTimelineExportSegment {
    data class Solo(
        val clip: AndroidTimelineVideoEncoder.ClipInput,
        val windowStartSeconds: Double,
        val windowEndSeconds: Double,
    ) : AndroidTimelineExportSegment()

    data class Overlap(
        val transition: AndroidTimelineTransitionDescriptor,
        val fromClip: AndroidTimelineVideoEncoder.ClipInput,
        val fromWindowStartSeconds: Double,
        val fromWindowEndSeconds: Double,
        val toClip: AndroidTimelineVideoEncoder.ClipInput,
        val toWindowStartSeconds: Double,
        val toWindowEndSeconds: Double,
    ) : AndroidTimelineExportSegment()
}

internal data class AndroidTimelineExportSegmentPlan(
    val segments: List<AndroidTimelineExportSegment>,
    val expectedSamples: Int,
    val failureReason: String?,
)

internal object AndroidTimelineExportSegmentPlanner {
    /** Tolerance for overlap arithmetic on the parser-validated durations. */
    const val OVERLAP_EPSILON_SECONDS = 1e-9

    /// Plans the ordered segments for [clips] and the non-hard-cut
    /// [transitions]. Without transitions every clip is one solo segment over
    /// its full trim window (the frozen hard-cut route). With transitions,
    /// each clip's solo window is shortened by the overlap it lends to its
    /// incoming and outgoing transitions (a solo window shorter than one
    /// output frame is skipped), and each transition becomes an overlap
    /// segment. Fails closed (reason set, no segments) for any shape the
    /// parser should already have rejected: a clip that is neither video
    /// (stillFrameCount == 0) nor still-image (stillFrameCount > 0,
    /// P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS), out-of-range or non-adjacent
    /// indices, or combined overlaps exceeding a clip.
    fun build(
        clips: List<AndroidTimelineVideoEncoder.ClipInput>,
        transitions: List<AndroidTimelineTransitionDescriptor>,
        fps: Int,
    ): AndroidTimelineExportSegmentPlan {
        val nonHardCutTransitions = transitions.filter { !it.isHardCut }
        if (nonHardCutTransitions.isEmpty()) {
            val segments = clips.map { clip ->
                AndroidTimelineExportSegment.Solo(clip, clip.trimStartSeconds, clip.trimEndSeconds)
            }
            val expected = clips.sumOf { clip ->
                ceil((clip.trimEndSeconds - clip.trimStartSeconds) * fps).toInt().coerceAtLeast(1)
            }
            return AndroidTimelineExportSegmentPlan(segments, expected, null)
        }

        fun fail(reason: String) = AndroidTimelineExportSegmentPlan(emptyList(), 0, reason)

        if (clips.any { clip ->
                when (clip.mediaKind) {
                    "video" -> clip.stillFrameCount != 0
                    "image" -> clip.stillFrameCount <= 0
                    else -> true
                }
            }
        ) {
            return fail("transitions_require_video_or_image_clips")
        }
        val incomingByClip = HashMap<Int, AndroidTimelineTransitionDescriptor>()
        val outgoingByClip = HashMap<Int, AndroidTimelineTransitionDescriptor>()
        for (t in nonHardCutTransitions) {
            if (t.type == AndroidTimelineTransitionDescriptor.Type.NONE) continue
            if (t.fromClipIndex < 0 || t.toClipIndex >= clips.size || t.toClipIndex != t.fromClipIndex + 1) {
                return fail("transition_index_invalid:${t.transitionId}:from=${t.fromClipIndex}:to=${t.toClipIndex}")
            }
            if (!t.durationSeconds.isFinite() || t.durationSeconds <= 0.0) {
                return fail("transition_duration_invalid:${t.transitionId}")
            }
            if (outgoingByClip.put(t.fromClipIndex, t) != null || incomingByClip.put(t.toClipIndex, t) != null) {
                return fail("transition_boundary_duplicate:${t.transitionId}")
            }
        }

        val minSoloWindowSeconds = 1.0 / fps.coerceAtLeast(1)
        val segments = ArrayList<AndroidTimelineExportSegment>()
        for ((index, clip) in clips.withIndex()) {
            val incoming = incomingByClip[index]
            val outgoing = outgoingByClip[index]
            val speed = if (clip.speed > 0.0) clip.speed else 1.0
            val incomingSourceDuration = (incoming?.durationSeconds ?: 0.0) * speed
            val outgoingSourceDuration = (outgoing?.durationSeconds ?: 0.0) * speed
            val soloStart = clip.trimStartSeconds + incomingSourceDuration
            val soloEnd = clip.trimEndSeconds - outgoingSourceDuration
            if (soloEnd < soloStart - OVERLAP_EPSILON_SECONDS) {
                return fail("transition_overlap_exceeds_clip:clip=$index")
            }
            if ((soloEnd - soloStart) / speed >= minSoloWindowSeconds) {
                segments.add(AndroidTimelineExportSegment.Solo(clip, soloStart, soloEnd))
            }
            if (outgoing != null) {
                val toClip = clips[outgoing.toClipIndex]
                val toSpeed = if (toClip.speed > 0.0) toClip.speed else 1.0
                val toTransitionSourceDuration = outgoing.durationSeconds * toSpeed
                segments.add(
                    AndroidTimelineExportSegment.Overlap(
                        transition = outgoing,
                        fromClip = clip,
                        fromWindowStartSeconds = clip.trimEndSeconds - outgoingSourceDuration,
                        fromWindowEndSeconds = clip.trimEndSeconds,
                        toClip = toClip,
                        toWindowStartSeconds = toClip.trimStartSeconds,
                        toWindowEndSeconds = toClip.trimStartSeconds + toTransitionSourceDuration,
                    ),
                )
            }
        }
        val timelineSeconds = AndroidTimelineTransitionDescriptor.timelineDurationSeconds(
            clips.map {
                val speed = if (it.speed > 0.0) it.speed else 1.0
                (it.trimEndSeconds - it.trimStartSeconds) / speed
            },
            nonHardCutTransitions,
        )
        val expected = ceil(timelineSeconds * fps).toInt().coerceAtLeast(1)
        return AndroidTimelineExportSegmentPlan(segments, expected, null)
    }
}
