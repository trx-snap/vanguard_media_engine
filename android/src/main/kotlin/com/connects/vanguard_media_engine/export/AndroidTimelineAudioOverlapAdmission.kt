package com.connects.vanguard_media_engine.export

// ── AndroidTimelineAudioOverlapAdmission (P5-TRANSITION-AUDIO-SIDECAR-EXPORT) ──
//
// Pure, testable admission gate for audioSidecar tracks on a compositor
// transition timeline (P5-COMPOSITOR-TRANS). Dart is the single source of
// truth for track timing on the overlap-adjusted output timeline --
// VGEditorDraft.sequentialWithTransitions positions clip startTimeSeconds
// around each transition's overlap, and flattenOriginalClipAudio emits
// generated original-clip-audio tracks whose startTime/duration/fadeIn/
// fadeOut already reflect that same overlap-shortened timeline (see
// lib/vg_editor_draft.dart:188-263, 660-703). This gate never adjusts or
// clamps a track's timing; it only validates that the already-computed wire
// values are self-consistent with the overlap-adjusted output duration this
// session independently derives from the parsed clip trim windows and
// transitions (AndroidTimelineTransitionDescriptor.timelineDurationSeconds).
// A track that fails this check would desynchronize audio against an
// overlap-shortened video, so it fails closed rather than muxing wrong
// output.
//
// Success (specs empty, or every spec passes) means each track is admitted
// to route through the existing pass-2 mux/mixdown path exactly like a
// hard-cut timeline's audioSidecar tracks do (AndroidTimelineAudioPass2Muxer)
// -- transition-shortened video naturally mismatches a track's serialized
// duration by more than the pass-2 direct-copy tolerance, so admitted tracks
// fall back to PCM mixdown rather than a direct-copy remux.
object AndroidTimelineAudioOverlapAdmission {

    /** Default admission tolerance in seconds, matching pass-2's own duration tolerance. */
    const val DEFAULT_TOLERANCE_SECONDS = 0.05

    private const val CODE_INVALID_ARG = "INVALID_ARG"

    sealed class Result {
        object Admitted : Result()

        /** [code] is an exportTimeline MethodChannel error code. */
        data class Failure(val code: String, val message: String) : Result()
    }

    /**
     * Validates [specs] against [overlapAdjustedDurationSeconds] (the output
     * timeline's total duration after transition overlaps are subtracted).
     * Never throws. Validates only -- clamps/adjusts nothing.
     */
    fun validate(
        specs: List<AndroidAudioTrackSpec>,
        overlapAdjustedDurationSeconds: Double,
        toleranceSeconds: Double = DEFAULT_TOLERANCE_SECONDS,
    ): Result {
        if (specs.isEmpty()) return Result.Admitted

        if (!overlapAdjustedDurationSeconds.isFinite() || overlapAdjustedDurationSeconds < 0.0) {
            return Result.Failure(
                CODE_INVALID_ARG,
                "exportTimeline: audioSidecar track timing cannot be validated against an " +
                    "invalid overlap-adjusted output duration ($overlapAdjustedDurationSeconds)",
            )
        }

        for (spec in specs) {
            if (!spec.startTime.isFinite() || !spec.duration.isFinite() ||
                !spec.sourceTrimStart.isFinite() || !spec.fadeInSeconds.isFinite() ||
                !spec.fadeOutSeconds.isFinite() || !spec.mixGain.isFinite()
            ) {
                return Result.Failure(
                    CODE_INVALID_ARG,
                    "exportTimeline: audioSidecar track '${spec.trackId}' has a non-finite " +
                        "startTime/duration/sourceTrimStart/fadeInSeconds/fadeOutSeconds/mixGain value",
                )
            }
            if (spec.startTime < -toleranceSeconds) {
                return Result.Failure(
                    CODE_INVALID_ARG,
                    "exportTimeline: audioSidecar track '${spec.trackId}' startTime " +
                        "${spec.startTime} must not be negative",
                )
            }
            if (spec.duration <= 0.0) {
                return Result.Failure(
                    CODE_INVALID_ARG,
                    "exportTimeline: audioSidecar track '${spec.trackId}' duration " +
                        "${spec.duration} must be positive",
                )
            }
            val trackEnd = spec.startTime + spec.duration
            if (trackEnd > overlapAdjustedDurationSeconds + toleranceSeconds) {
                return Result.Failure(
                    CODE_INVALID_ARG,
                    "exportTimeline: audioSidecar track '${spec.trackId}' end time $trackEnd " +
                        "exceeds the overlap-adjusted output duration " +
                        "$overlapAdjustedDurationSeconds",
                )
            }
            if (spec.sourceTrimStart < -toleranceSeconds) {
                return Result.Failure(
                    CODE_INVALID_ARG,
                    "exportTimeline: audioSidecar track '${spec.trackId}' sourceTrimStart " +
                        "${spec.sourceTrimStart} must not be negative",
                )
            }
            if (spec.fadeInSeconds < -toleranceSeconds || spec.fadeOutSeconds < -toleranceSeconds) {
                return Result.Failure(
                    CODE_INVALID_ARG,
                    "exportTimeline: audioSidecar track '${spec.trackId}' fadeInSeconds/" +
                        "fadeOutSeconds (${spec.fadeInSeconds}/${spec.fadeOutSeconds}) must not be negative",
                )
            }
        }

        return Result.Admitted
    }
}
