package com.connects.vanguard_media_engine.editor

import android.content.Context
import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.export.AndroidTimelineTransitionDescriptor
import com.connects.vanguard_media_engine.util.AndroidUriDataSourceHelper
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicInteger

/**
 * Phase 7.8G-Android: owns the public Dart VGEditorController playback routes
 * (createTimelineTexture, updateTimeline, timelinePlay, timelinePause,
 * timelineSeek, disposeTimeline) for sequential plain local video clips
 * (one or more clips, hard-cut concatenation only).
 *
 * Supports plain hard-cut video plus validated added-audio sidecar preview
 * for the original/music/sfx/voiceover lanes (Phase 7.8O-Android), reversed
 * clips through their prepared reverse sidecar, and freeze-frame clips
 * (Phase 7.17-Android: `freezePTS` is parsed here and executed by the session
 * as a single held source frame over the clip's timeline hold). Validates
 * each draft against the current unsupported-feature guardrails (overlays,
 * per-clip transform, non-default fit/crop, dual camera, time remap,
 * transform track, color matrix, freeze on a reversed clip, transitions
 * touching a freeze clip) and delegates execution to an
 * [AndroidEditorPlaybackSession]: [AndroidEditorSequentialPlaybackSession] for
 * hard-cut-only timelines, [AndroidEditorTransitionPlaybackSession] when the
 * draft carries at least one non-hard-cut transition (parsed through the
 * export descriptor contract, so preview and export validate identically) OR
 * requests a "fill" canvas over more than one clip (mixed-orientation
 * cover-crop needs that session's canvas-aware quad geometry even with zero
 * real transitions). Does not
 * own streaming/cache/RTC/export/compositor policy — those remain owned by
 * their respective coordinators or are left unimplemented for this slice
 * (exportTimeline, clearTimelineCache, timeline cache stats).
 */
class AndroidEditorPlaybackCoordinator(
    private val textureRegistry: TextureRegistry,
    private val channel: MethodChannel,
    private val mainHandler: Handler,
    /**
     * Optional application [Context]. Used here for the `content://` source readability
     * preflight ([AndroidUriDataSourceHelper.isReadable]) and forwarded to
     * [AndroidEditorSequentialPlaybackSession] for `content://`-aware source inspection
     * (AndroidDagSourceInspector) and original-clip audio preview's
     * [android.media.AudioManager] focus requests (Phase 7.8I-Android). Defaults to null so
     * existing callers that do not supply it keep compiling and behaving exactly as before
     * for plain POSIX paths (audio focus management is simply skipped); a `content://`
     * source with a null context fails closed with FILE_UNREADABLE before any texture or
     * session is allocated.
     */
    private val context: Context? = null,
    private val reverseSidecarPathProvider: ((clipId: String) -> String?)? = null,
) {
    companion object {
        private const val TAG = "EditorPlaybackCoord"

        /** Tolerance (seconds) for a clip's trimEndSeconds vs. its declared durationSeconds. */
        private const val TRIM_DURATION_TOLERANCE_SECONDS = 0.002

        /** Tolerance (us) for advisory wire startTimeSeconds vs. the computed sequential cursor. */
        private const val STARTTIME_TOLERANCE_US = 1_000L

        /**
         * Phase 7.8O-Android: native eager-MediaPlayer preview safety cap — each lane
         * (`music`, `sfx`, or `voiceover`; Phase 7.8Q-Android split `music` and `sfx`
         * into independent lanes) may hold at most this many non-overlapping tracks.
         * Not a product UX rule; purely a guard against unbounded MediaPlayer
         * instantiation for this preview slice.
         */
        private const val MAX_TRACKS_PER_LANE = 8

        private val OWNED_METHODS = setOf(
            "createTimelineTexture",
            "updateTimeline",
            "timelinePlay",
            "timelinePause",
            "timelineSeek",
            "disposeTimeline",
            "timeline_setAudioMixGain",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS

        /**
         * User-added audio sidecar roles (Phase 7.8Q-Android: `music`, `sfx`, and
         * `voiceover` are each their own independent lane — same-role overlap is
         * rejected, but tracks in different lanes may freely overlap in time).
         */
        private val USER_ADDED_LANE_ROLES = setOf("music", "sfx", "voiceover")
    }

    /** One track's timeline window within a lane, used only for same-lane overlap validation. */
    private data class AddedAudioLaneWindow(
        val trackId: String,
        val role: String,
        val startUs: Long,
        val endUs: Long,
    )

    private data class ActiveEntry(
        val textureId: Long,
        val session: AndroidEditorPlaybackSession,
        val surfaceProducer: TextureRegistry.SurfaceProducer,
        /**
         * Added-audio preview runtimes: zero or more, one per validated audioSidecar track
         * (Phase 7.8O-Android: multiple non-overlapping tracks may share a lane; Phase
         * 7.8Q-Android: `music`, `sfx`, and `voiceover` are each their own independent lane —
         * see [validateAndAddLaneWindow]). Attached after [AndroidEditorPlaybackSession
         * .prepare] succeeds (see [createOrUpdateTimeline]); owned/released by this coordinator,
         * never by the session (which only owns per-clip original-audio runtimes).
         */
        val addedAudioRuntimes: List<AndroidEditorAddedAudioPreviewRuntime> = emptyList(),
    )

    private val lock = Any()
    private var active: ActiveEntry? = null

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "createTimelineTexture" -> createOrUpdateTimeline(args, result)
            "updateTimeline" -> createOrUpdateTimeline(args, result)
            "timelinePlay" -> timelinePlay(result)
            "timelinePause" -> timelinePause(result)
            "timelineSeek" -> timelineSeek(args, result)
            "disposeTimeline" -> disposeTimeline(result)
            "timeline_setAudioMixGain" -> timelineSetAudioMixGain(args, result)
            else -> return false
        }
        return true
    }

    /**
     * Validates [candidate] against the other tracks already accepted into its lane
     * ([windows]) and, if it passes, appends it to [windows]. Returns a human-readable
     * error message (never throws/errors itself) if the lane is already at
     * [MAX_TRACKS_PER_LANE] or [candidate] half-open-overlaps an existing window in the
     * same lane; returns null on success. Touching endpoints (candidate.startUs ==
     * existing.endUs or vice versa) are not a conflict.
     */
    private fun validateAndAddLaneWindow(
        windows: MutableList<AddedAudioLaneWindow>,
        laneName: String,
        candidate: AddedAudioLaneWindow,
    ): String? {
        if (windows.size >= MAX_TRACKS_PER_LANE) {
            return "$laneName lane exceeds the preview safety cap of $MAX_TRACKS_PER_LANE tracks " +
                "(rejected track \"${candidate.trackId}\")"
        }
        for (existing in windows) {
            if (candidate.startUs < existing.endUs && existing.startUs < candidate.endUs) {
                return "$laneName track \"${candidate.trackId}\" (role=${candidate.role}) overlaps " +
                    "existing $laneName track \"${existing.trackId}\" (role=${existing.role})"
            }
        }
        windows.add(candidate)
        return null
    }

    // ── createTimelineTexture / updateTimeline ────────────────────────────────

    private fun createOrUpdateTimeline(args: Map<*, *>?, result: MethodChannel.Result) {
        val draft = args?.get("draft") as? Map<*, *>
        if (draft == null) {
            result.error("MISSING_DRAFT", "draft is required", null)
            return
        }

        val clips = draft["clips"] as? List<*>
        if (clips == null || clips.isEmpty()) {
            result.error("EMPTY_CLIPS", "draft.clips must be a non-empty list", null)
            return
        }

        // Draft-level unsupported-feature guardrails. 'transitions' and 'overlays'
        // are always-present keys in VGEditorDraft.toMap() (possibly empty lists);
        // 'audioSidecar' is present only when a plan is set. Transitions are parsed
        // after the clip loop (they bind to the parsed clip order); overlays fail closed.
        val rawTransitions: List<*> = draft["transitions"] as? List<*> ?: emptyList<Any?>()

        // Root canvasWidth/canvasHeight are unconditionally present in
        // VGEditorDraft.toMap(); the nested 'canvas' map (with 'contentMode') is
        // present only when VGEditorDraft.canvas is non-null. A mixed-orientation
        // "fill" draft's canvas is defined by its first clip and must reach the
        // transition session unchanged, not re-derived from a later clip's geometry.
        val requestedCanvasWidth = (draft["canvasWidth"] as? Number)?.toInt() ?: 0
        val requestedCanvasHeight = (draft["canvasHeight"] as? Number)?.toInt() ?: 0
        val canvasMap = draft["canvas"] as? Map<*, *>
        val canvasContentMode = (canvasMap?.get("contentMode") as? String) ?: "fit"
        val overlays = draft["overlays"] as? List<*>
        if (overlays != null && overlays.isNotEmpty()) {
            result.error("UNSUPPORTED_TIMELINE_FEATURE", "overlays are not supported in this slice", null)
            return
        }

        val clipSpecs = mutableListOf<AndroidEditorClipPlaybackSpec>()
        // Native layout is a running cursor over each clip's derived timeline duration —
        // not the wire startTimeSeconds, which VGEditorDraft may leave at 0.0 for every
        // clip. See correction below where each clip is appended.
        var cursorUs = 0L
        // Wire startTimeSeconds per clip, index-aligned with clipSpecs (each clip either
        // errors out and returns, or is appended to both together). Validated after the
        // loop, once parsedTransitions below is known — see the comment at that check for
        // why this cannot be validated inline against the pure sequential cursor.
        val wireStartTimeSecondsByIndex = mutableListOf<Double>()
        for (rawClip in clips) {
            val clip = rawClip as? Map<*, *>
            if (clip == null) {
                result.error("INVALID_CLIP", "each clip must be a map", null)
                return
            }

            val mediaKind = (clip["mediaKind"] as? String) ?: "video"
            if (mediaKind != "video" && mediaKind != "image") {
                result.error("UNSUPPORTED_MEDIA_KIND", "mediaKind=$mediaKind is not supported", null)
                return
            }

            // Per-clip unsupported-feature guardrails. Each of these wire keys is
            // present in VGClipDescriptor.toMap() only when the field differs from
            // its supported default (see vg_clip_descriptor.dart), so presence
            // alone identifies an unsupported clip. 'fitMode' is validated
            // separately below (per-mediaKind: image-only, fit/fill).
            if (clip["transform"] != null ||
                clip["cropRect"] != null ||
                clip["dualCamera"] != null ||
                clip["timeRemap"] != null ||
                clip["transformTrack"] != null ||
                clip["colorMatrix"] != null
            ) {
                result.error(
                    "UNSUPPORTED_TIMELINE_FEATURE",
                    "clip \"${clip["id"]}\" uses an unsupported timeline feature",
                    null,
                )
                return
            }

            // fitMode is omitted from VGClipDescriptor.toMap() when it equals the
            // default ('fit'); present ('fill') only for a still image clip. A
            // video clip must never carry it (continue rejecting fitMode on video
            // clips); an image clip may carry null/"fit"/"fill" only.
            val fitMode = clip["fitMode"] as? String
            if (mediaKind == "video") {
                if (fitMode != null) {
                    result.error(
                        "UNSUPPORTED_TIMELINE_FEATURE",
                        "clip \"${clip["id"]}\" uses an unsupported timeline feature",
                        null,
                    )
                    return
                }
            } else if (fitMode != null && fitMode != "fit" && fitMode != "fill") {
                result.error(
                    "UNSUPPORTED_TIMELINE_FEATURE",
                    "clip \"${clip["id"]}\" has unsupported fitMode '$fitMode'",
                    null,
                )
                return
            }

            // 'id' is unconditionally present in VGClipDescriptor.toMap() (a required non-null
            // Dart field). It keys the derived role="original" sidecar policy below
            // ("original-<clipId>"), so a blank id would make that policy unattachable.
            val clipId = clip["id"] as? String
            if (clipId.isNullOrBlank()) {
                result.error("INVALID_CLIP", "clip is missing a non-blank id", null)
                return
            }

            val sourcePath = clip["sourcePath"] as? String
            if (sourcePath.isNullOrBlank()) {
                result.error("FILE_UNREADABLE", "sourcePath is missing or blank", null)
                return
            }

            val isReversed = clip["isReversed"] as? Boolean ?: false

            // Phase 7.17-Android: `freezePTS` is present in VGClipDescriptor.toMap() only for
            // a freeze-frame clip (VGEditorDraft.freezeClip): a finite, non-negative source-
            // local PTS (seconds) of the single frame to hold. The clip's trim window is its
            // timeline hold (trim [0, holdDuration]), so no trim/PTS cross-check happens here;
            // the session validates the PTS against the inspected source at prepare time. A
            // freeze clip can never also be reversed (DEC-154; the reverse sidecar's PTS space
            // is not the original source's), so that combination fails closed.
            val rawFreezePts = clip["freezePTS"]
            var freezePtsUs: Long? = null
            if (rawFreezePts != null) {
                val freezePts = (rawFreezePts as? Number)?.toDouble()
                if (freezePts == null || !freezePts.isFinite() || freezePts < 0.0) {
                    result.error(
                        "INVALID_CLIP",
                        "clip \"$clipId\" has a non-numeric, non-finite, or negative freezePTS",
                        null,
                    )
                    return
                }
                if (isReversed) {
                    result.error(
                        "UNSUPPORTED_TIMELINE_FEATURE",
                        "clip \"$clipId\" combines freezePTS with isReversed, which is not supported",
                        null,
                    )
                    return
                }
                freezePtsUs = (freezePts * 1_000_000.0).toLong()
            }

            var effectiveSourcePath = sourcePath
            if (isReversed) {
                val sidecarPath = reverseSidecarPathProvider?.invoke(clipId)
                if (sidecarPath != null) {
                    effectiveSourcePath = sidecarPath
                } else {
                    result.error(
                        "UNSUPPORTED_TIMELINE_FEATURE",
                        "clip \"$clipId\" is reversed but reverse sidecar is not ready",
                        null,
                    )
                    return
                }
            }

            // POSIX paths keep the File.exists()/canRead() check; `content://` URIs are probed
            // via ContentResolver and fail closed (false) when the context is null or the
            // provider refuses. No texture/session has been allocated yet, so the caller can
            // retry with a valid path/URI after a FILE_UNREADABLE error.
            if (!AndroidUriDataSourceHelper.isReadable(effectiveSourcePath, context)) {
                result.error("FILE_UNREADABLE", "sourcePath is not readable: $effectiveSourcePath", null)
                return
            }

            // Timing/trim fields are unconditionally present in VGClipDescriptor.toMap()
            // (see vg_clip_descriptor.dart:604-614). speed must be finite and positive.
            val speed = (clip["speed"] as? Number)?.toDouble()
            if (speed == null || !speed.isFinite() || speed <= 0.0) {
                result.error("INVALID_CLIP", "clip \"${clip["id"]}\" has a missing, non-finite, or non-positive speed", null)
                return
            }

            val startTimeSeconds = (clip["startTimeSeconds"] as? Number)?.toDouble()
            val durationSeconds = (clip["durationSeconds"] as? Number)?.toDouble()
            val trimStartSeconds = (clip["trimStartSeconds"] as? Number)?.toDouble()
            val trimEndSeconds = (clip["trimEndSeconds"] as? Number)?.toDouble()
            if (startTimeSeconds == null || !startTimeSeconds.isFinite() ||
                durationSeconds == null || !durationSeconds.isFinite() ||
                trimStartSeconds == null || !trimStartSeconds.isFinite() ||
                trimEndSeconds == null || !trimEndSeconds.isFinite()
            ) {
                result.error("INVALID_CLIP", "clip \"${clip["id"]}\" has missing or non-finite timing fields", null)
                return
            }
            if (startTimeSeconds < 0.0) {
                result.error("INVALID_CLIP", "clip \"${clip["id"]}\" startTimeSeconds must be >= 0", null)
                return
            }
            // durationSeconds is the clip's full source duration, not its timeline
            // contribution, and 0.0 is a documented sentinel for "unknown duration" —
            // AndroidDagSourceInspector validates the real source duration against the
            // trim window once this clip becomes active (see
            // AndroidEditorSequentialPlaybackSession.prepare).
            if (trimStartSeconds < 0.0) {
                result.error("INVALID_CLIP", "clip \"${clip["id"]}\" trimStartSeconds must be >= 0", null)
                return
            }
            if (trimEndSeconds <= trimStartSeconds) {
                result.error("INVALID_CLIP", "clip \"${clip["id"]}\" trimEndSeconds must be > trimStartSeconds", null)
                return
            }
            if (durationSeconds > 0.0 && trimEndSeconds > durationSeconds + TRIM_DURATION_TOLERANCE_SECONDS) {
                result.error(
                    "INVALID_CLIP",
                    "clip \"${clip["id"]}\" trimEndSeconds exceeds durationSeconds",
                    null,
                )
                return
            }

            val effectiveTrimStartSeconds = if (isReversed) 0.0 else trimStartSeconds
            val effectiveTrimEndSeconds = if (isReversed) (trimEndSeconds - trimStartSeconds) else trimEndSeconds

            val sourceTrimStartUs = (effectiveTrimStartSeconds * 1_000_000.0).toLong()
            val sourceTrimEndUs = (effectiveTrimEndSeconds * 1_000_000.0).toLong()
            val sourceTrimDurationUs = sourceTrimEndUs - sourceTrimStartUs
            if (sourceTrimDurationUs <= 0L) {
                result.error("INVALID_CLIP", "clip \"${clip["id"]}\" has a non-positive trim duration", null)
                return
            }
            val timelineDurationUs = (sourceTrimDurationUs / speed).toLong()
            if (timelineDurationUs <= 0L) {
                result.error("INVALID_CLIP", "clip \"${clip["id"]}\" has a non-positive timeline duration", null)
                return
            }

            // Wire startTimeSeconds is advisory only (multiple clips may all report 0.0)
            // and is never treated as authoritative layout. It IS validated, but not here:
            // a transition-aware draft's expected clip position depends on transitions,
            // which are only known once every clip's timelineDurationUs has been derived
            // below, so the disagreement check is deferred to just after transition parsing
            // (see "Wire startTimeSeconds validation" below the clip loop).
            wireStartTimeSecondsByIndex.add(startTimeSeconds)

            if (freezePtsUs != null) {
                Log.i(
                    TAG,
                    "VG_EDITOR_FREEZE_PREVIEW clip_parsed clipId=$clipId freezePtsUs=$freezePtsUs " +
                        "holdUs=$timelineDurationUs timelineStartUs=$cursorUs",
                )
            }
            clipSpecs.add(
                AndroidEditorClipPlaybackSpec(
                    clipId = clipId,
                    sourcePath = effectiveSourcePath,
                    timelineStartUs = cursorUs,
                    sourceTrimStartUs = sourceTrimStartUs,
                    sourceTrimEndUs = sourceTrimEndUs,
                    timelineDurationUs = timelineDurationUs,
                    speed = speed,
                    freezePtsUs = freezePtsUs,
                    mediaKind = mediaKind,
                    fitMode = if (mediaKind == "image") (fitMode ?: "fit") else "fit",
                ),
            )
            cursorUs += timelineDurationUs
        }

        // Transitions: parsed by the export descriptor parser so preview and export share
        // one validation contract (adjacency, closed type set, duration vs. adjacent clip
        // timeline durations, one overlap per frame). Hard cuts are dropped by the parser.
        // A non-empty result routes this timeline to AndroidEditorTransitionPlaybackSession.
        val parsedTransitions: List<AndroidTimelineTransitionDescriptor> = when (
            val parse = AndroidTimelineTransitionDescriptor.parseList(
                rawTransitions,
                clipSpecs.map { spec ->
                    AndroidTimelineTransitionDescriptor.ClipRef(
                        id = spec.clipId,
                        durationSeconds = spec.timelineDurationUs / 1_000_000.0,
                    )
                },
            )
        ) {
            is AndroidTimelineTransitionDescriptor.ParseResult.Success -> parse.transitions
            is AndroidTimelineTransitionDescriptor.ParseResult.Failure -> {
                result.error(parse.code, parse.message.replaceFirst("exportTimeline: ", "updateTimeline: "), null)
                return
            }
        }

        // Image slideshow transitions are not supported in this slice: fail closed
        // before any session is constructed, rather than letting a still image reach
        // AndroidEditorTransitionPlaybackSession (which never routes image clips).
        if (parsedTransitions.isNotEmpty() && clipSpecs.any { it.mediaKind == "image" }) {
            result.error(
                "UNSUPPORTED_TIMELINE_FEATURE",
                "image slideshow transitions are not supported in this slice",
                null,
            )
            return
        }

        // Wire startTimeSeconds validation (deferred from the clip loop above): reject a
        // non-zero value that disagrees with the expected clip position by more than 1ms.
        // "Expected" depends on whether this draft carries any parsed non-hard-cut
        // transition: with none, it is the pure sequential cursor clipSpecs[i].timelineStartUs
        // (byte-for-byte what the old inline check compared against, so hard-cut/sequential
        // drafts validate identically to before). With one or more, VGEditorDraft
        // .sequentialWithTransitions is the Dart-side source of truth (DEC-143) for
        // overlap-adjusted layout, and native must validate against that same formula:
        //   expected[0] = 0
        //   expected[i+1] = expected[i] + clipSpecs[i].timelineDurationUs - outgoing
        //                    transition overlap from clip[i] to clip[i+1] (0 if none)
        // parseList already guarantees toClipIndex == fromClipIndex + 1 for every entry in
        // parsedTransitions (adjacency) and has already dropped hard cuts, so a lookup keyed
        // by fromClipIndex is unambiguous.
        val expectedStartUsByIndex: LongArray = if (parsedTransitions.isEmpty()) {
            LongArray(clipSpecs.size) { clipSpecs[it].timelineStartUs }
        } else {
            val overlapUsByFromIndex = HashMap<Int, Long>()
            for (transition in parsedTransitions) {
                overlapUsByFromIndex[transition.fromClipIndex] = (transition.durationSeconds * 1_000_000.0).toLong()
            }
            val expected = LongArray(clipSpecs.size)
            for (i in 1 until clipSpecs.size) {
                val overlapUs = overlapUsByFromIndex[i - 1] ?: 0L
                expected[i] = expected[i - 1] + clipSpecs[i - 1].timelineDurationUs - overlapUs
            }
            expected
        }
        for (i in clipSpecs.indices) {
            val wireStartTimeSeconds = wireStartTimeSecondsByIndex[i]
            if (wireStartTimeSeconds == 0.0) continue
            val wireStartTimeUs = (wireStartTimeSeconds * 1_000_000.0).toLong()
            val expectedUs = expectedStartUsByIndex[i]
            if (Math.abs(wireStartTimeUs - expectedUs) > STARTTIME_TOLERANCE_US) {
                result.error(
                    "INVALID_CLIP",
                    "clip \"${clipSpecs[i].clipId}\" startTimeSeconds=$wireStartTimeSeconds disagrees with " +
                        "computed ${if (parsedTransitions.isEmpty()) "sequential" else "transition-aware"} " +
                        "position ${expectedUs / 1_000_000.0}",
                    null,
                )
                return
            }
        }

        // Fail closed before any session allocation: the transition preview route renders
        // through the export decoder chain, which has no freeze-frame seam.
        for (transition in parsedTransitions) {
            val fromFreeze = clipSpecs.getOrNull(transition.fromClipIndex)?.freezePtsUs != null
            val toFreeze = clipSpecs.getOrNull(transition.toClipIndex)?.freezePtsUs != null
            if (fromFreeze || toFreeze) {
                result.error(
                    "UNSUPPORTED_TIMELINE_FEATURE",
                    "transitions touching freeze clips are not supported in this slice",
                    null,
                )
                return
            }
        }
        if (parsedTransitions.isNotEmpty()) {
            Log.i(
                TAG,
                "VG_EDITOR_TRANSITION_PREVIEW transitions_parsed count=${parsedTransitions.size} " +
                    parsedTransitions.joinToString(" ") { t ->
                        "${t.transitionId}:${t.type.name}:${t.durationSeconds}s:${t.fromClipIndex}->${t.toClipIndex}"
                    },
            )
        }

        // 'audioSidecar' is present in VGEditorDraft.toMap() only when a plan is
        // set. This route accepts two sidecar track shapes: (1) the controller's
        // own derived original-clip-audio tracks (VGEditorDraft
        // .flattenOriginalClipAudio()) — one synthetic track per clip's own
        // already-validated sourcePath, tagged role="original" with a trackId of
        // "original-<clipId>" — whose `volume * mixGain` is the native original-audio
        // preview policy for that clip (the app's original-sound policy sends 0.0/0.0
        // when muted and a committed originalMixGain otherwise; see
        // [originalGainByClipId] below and AndroidEditorClipPlaybackSpec
        // .originalAudioGain), keyed by the draft clip id so a source reused by
        // several clips is never ambiguous; and (2) any number of user-added
        // role="music", role="sfx", and role="voiceover" tracks — each role is its
        // own independent lane (Phase 7.8Q-Android: `music` and `sfx` no longer
        // share a lane, so they may freely overlap in time; `voiceover` was already
        // its own lane), supported on hard-cut single- or multi-clip timelines
        // (Phase 7.8N-Android: multi-clip added-audio preview), each with a finite
        // non-negative startTime (Phase 7.8K-Android: delayed start/end) and finite
        // non-negative fadeInSeconds/fadeOutSeconds and/or volumeKeyframes (Phase
        // 7.8M-Android: volume automation; see
        // AndroidEditorAddedAudioPreviewRuntime/AndroidEditorAudioAutomation).
        // Tracks in the same lane (i.e. sharing a role) must not overlap
        // ([startUs, startUs+durationUs) is half-open; touching endpoints are
        // allowed) and each lane is independently capped at [MAX_TRACKS_PER_LANE]
        // tracks (a native eager-MediaPlayer preview safety guard, not a product
        // rule — see [validateAndAddLaneWindow]). Any other role (unknown, null),
        // a same-lane overlap, a lane over its cap, or unsupported video features
        // on the timeline remain unsupported in this slice; iOS-style dynamic
        // same-lane priority selection is intentionally not implemented here.
        val audioSidecar = draft["audioSidecar"]
        val pendingAddedAudioConfigs = mutableListOf<AndroidEditorAddedAudioTrackConfig>()
        // Native original-audio preview policy per draft clip id, parsed from role="original"
        // sidecar tracks: clamped `volume * mixGain` in [0.0, 1.0]. A clip absent from this map
        // keeps the unity default (original audio plays as before when the source has audio).
        val originalGainByClipId = mutableMapOf<String, Float>()
        if (audioSidecar != null) {
            val sidecarMap = audioSidecar as? Map<*, *>
            val tracks = sidecarMap?.get("tracks") as? List<*>
            if (tracks == null || tracks.isEmpty()) {
                result.error("INVALID_AUDIO_SIDECAR", "audioSidecar.tracks must be a non-empty list", null)
                return
            }

            val musicLaneWindows = mutableListOf<AddedAudioLaneWindow>()
            val sfxLaneWindows = mutableListOf<AddedAudioLaneWindow>()
            val voiceoverLaneWindows = mutableListOf<AddedAudioLaneWindow>()
            val seenAddedTrackIds = mutableSetOf<String>()
            for (rawTrack in tracks) {
                val track = rawTrack as? Map<*, *>
                if (track == null) {
                    result.error("INVALID_AUDIO_SIDECAR", "each audioSidecar track must be a map", null)
                    return
                }

                val trackId = track["trackId"] as? String
                val url = track["url"] as? String
                val role = track["role"] as? String

                if (role == "original") {
                    // Derived original track: trackId is "original-<clipId>" and url is that
                    // clip's own already-validated sourcePath. Resolve the owning clip by id
                    // (not by url alone) so the policy lands on the right clip when one source
                    // is reused; fail closed on anything malformed, exactly as before.
                    val originalClipId = trackId?.takeIf { it.startsWith("original-") }
                        ?.removePrefix("original-")
                    val ownerClip = originalClipId?.takeIf { it.isNotBlank() }
                        ?.let { id -> clipSpecs.firstOrNull { it.clipId == id } }
                    if (ownerClip == null || url.isNullOrBlank() || ownerClip.sourcePath != url) {
                        result.error(
                            "INVALID_AUDIO_SIDECAR",
                            "track \"$trackId\" is not a valid derived original-audio track",
                            null,
                        )
                        return
                    }
                    if (originalGainByClipId.containsKey(ownerClip.clipId)) {
                        result.error(
                            "INVALID_AUDIO_SIDECAR",
                            "duplicate derived original-audio track \"$trackId\"",
                            null,
                        )
                        return
                    }
                    // volume/mixGain default to 1.0 exactly like the added lanes (mixGain is
                    // emitted on the wire only when not unity). Non-finite fails closed; a
                    // non-positive product is the app's mute policy (0.0), otherwise the
                    // product is clamped to [0.0, 1.0] for MediaPlayer.setVolume.
                    val originalVolume = (track["volume"] as? Number)?.toDouble() ?: 1.0
                    val originalMixGain = (track["mixGain"] as? Number)?.toDouble() ?: 1.0
                    if (!originalVolume.isFinite() || !originalMixGain.isFinite()) {
                        result.error(
                            "INVALID_AUDIO_SIDECAR",
                            "original track \"$trackId\" has a non-finite volume or mixGain",
                            null,
                        )
                        return
                    }
                    val originalGain = (originalVolume * originalMixGain).coerceIn(0.0, 1.0).toFloat()
                    originalGainByClipId[ownerClip.clipId] = originalGain
                    Log.i(
                        TAG,
                        "VG_EDITOR_AUDIO_PREVIEW original_policy_parsed clipId=${ownerClip.clipId} " +
                            "volume=$originalVolume mixGain=$originalMixGain originalGain=$originalGain",
                    )
                    continue
                }

                if (role !in USER_ADDED_LANE_ROLES) {
                    result.error(
                        "UNSUPPORTED_TIMELINE_FEATURE",
                        "audioSidecar track role=\"$role\" is not supported in this slice",
                        null,
                    )
                    return
                }

                if (trackId.isNullOrBlank() || url.isNullOrBlank()) {
                    result.error("INVALID_AUDIO_SIDECAR", "$role track is missing trackId or url", null)
                    return
                }

                if (!seenAddedTrackIds.add(trackId!!)) {
                    result.error(
                        "INVALID_AUDIO_SIDECAR",
                        "duplicate added-audio trackId \"$trackId\"",
                        null,
                    )
                    return
                }

                val startTime = (track["startTime"] as? Number)?.toDouble()
                val duration = (track["duration"] as? Number)?.toDouble()
                val volume = (track["volume"] as? Number)?.toDouble() ?: 1.0
                val mixGain = (track["mixGain"] as? Number)?.toDouble() ?: 1.0
                val fadeInSeconds = (track["fadeInSeconds"] as? Number)?.toDouble() ?: 0.0
                val fadeOutSeconds = (track["fadeOutSeconds"] as? Number)?.toDouble() ?: 0.0
                val sourceTrimStart = (track["sourceTrimStart"] as? Number)?.toDouble() ?: 0.0
                val volumeKeyframes = track["volumeKeyframes"] as? List<*>

                if (startTime == null || !startTime.isFinite() ||
                    duration == null || !duration.isFinite() ||
                    !volume.isFinite() || !mixGain.isFinite() ||
                    !fadeInSeconds.isFinite() || !fadeOutSeconds.isFinite() ||
                    !sourceTrimStart.isFinite()
                ) {
                    result.error(
                        "INVALID_AUDIO_SIDECAR",
                        "$role track \"$trackId\" has missing or non-finite numeric fields",
                        null,
                    )
                    return
                }
                if (duration <= 0.0 || sourceTrimStart < 0.0 || startTime < 0.0) {
                    result.error(
                        "INVALID_AUDIO_SIDECAR",
                        "$role track \"$trackId\" has an invalid duration, sourceTrimStart, or startTime",
                        null,
                    )
                    return
                }

                val laneWindows = when (role) {
                    "music" -> musicLaneWindows
                    "sfx" -> sfxLaneWindows
                    else -> voiceoverLaneWindows
                }
                val laneError = validateAndAddLaneWindow(
                    laneWindows,
                    role!!,
                    AddedAudioLaneWindow(
                        trackId = trackId,
                        role = role!!,
                        startUs = (startTime * 1_000_000.0).toLong(),
                        endUs = ((startTime + duration) * 1_000_000.0).toLong(),
                    ),
                )
                if (laneError != null) {
                    result.error("UNSUPPORTED_TIMELINE_FEATURE", laneError, null)
                    return
                }

                if (fadeInSeconds < 0.0 || fadeOutSeconds < 0.0) {
                    result.error(
                        "INVALID_AUDIO_SIDECAR",
                        "$role track \"$trackId\" has a negative fadeInSeconds or fadeOutSeconds",
                        null,
                    )
                    return
                }

                // Phase 7.8M-Android: volumeKeyframes overrides volume/fades when non-empty (wire
                // contract: packages/vanguard_media_engine/lib/vg_audio_sidecar_plan.dart). Absent
                // or empty parses to emptyList(); AndroidEditorAudioAutomation sorts/deduplicates
                // by timeUs, so only per-entry validation and an ascending sort happen here.
                val parsedKeyframes = mutableListOf<AndroidEditorVolumeKeyframe>()
                if (volumeKeyframes != null && volumeKeyframes.isNotEmpty()) {
                    for (rawKeyframe in volumeKeyframes) {
                        val keyframe = rawKeyframe as? Map<*, *>
                        if (keyframe == null) {
                            result.error(
                                "INVALID_AUDIO_SIDECAR",
                                "$role track \"$trackId\" has a malformed volumeKeyframes entry",
                                null,
                            )
                            return
                        }
                        val keyframeTime = (keyframe["time"] as? Number)?.toDouble()
                        val keyframeVolume = (keyframe["volume"] as? Number)?.toDouble()
                        if (keyframeTime == null || !keyframeTime.isFinite() ||
                            keyframeVolume == null || !keyframeVolume.isFinite()
                        ) {
                            result.error(
                                "INVALID_AUDIO_SIDECAR",
                                "$role track \"$trackId\" has a volumeKeyframes entry with a missing or non-finite time or volume",
                                null,
                            )
                            return
                        }
                        if (keyframeTime < 0.0) {
                            result.error(
                                "INVALID_AUDIO_SIDECAR",
                                "$role track \"$trackId\" has a volumeKeyframes entry with a negative time",
                                null,
                            )
                            return
                        }
                        if (keyframeVolume < 0.0 || keyframeVolume > 1.0) {
                            result.error(
                                "INVALID_AUDIO_SIDECAR",
                                "$role track \"$trackId\" has a volumeKeyframes entry with volume outside [0.0, 1.0]",
                                null,
                            )
                            return
                        }
                        val keyframeCurve = keyframe["curve"] as? String
                        if (keyframeCurve != null && keyframeCurve != "linear") {
                            result.error(
                                "INVALID_AUDIO_SIDECAR",
                                "$role track \"$trackId\" has a volumeKeyframes entry with unsupported curve \"$keyframeCurve\"",
                                null,
                            )
                            return
                        }
                        parsedKeyframes.add(
                            AndroidEditorVolumeKeyframe(
                                timeUs = (keyframeTime * 1_000_000.0).toLong(),
                                volume = keyframeVolume.toFloat(),
                            ),
                        )
                    }
                    parsedKeyframes.sortBy { it.timeUs }
                }

                if (!AndroidUriDataSourceHelper.isReadable(url, context)) {
                    result.error("FILE_UNREADABLE", "$role track \"$trackId\" url is not readable: $url", null)
                    return
                }

                pendingAddedAudioConfigs.add(
                    AndroidEditorAddedAudioTrackConfig(
                        trackId = trackId,
                        sourcePath = url,
                        durationUs = (duration * 1_000_000.0).toLong(),
                        sourceTrimStartUs = (sourceTrimStart * 1_000_000.0).toLong(),
                        trackStartUs = (startTime * 1_000_000.0).toLong(),
                        volume = volume.toFloat(),
                        mixGain = mixGain.toFloat(),
                        fadeInUs = (fadeInSeconds * 1_000_000.0).toLong(),
                        fadeOutUs = (fadeOutSeconds * 1_000_000.0).toLong(),
                        volumeKeyframes = parsedKeyframes,
                        role = role,
                    ),
                )
            }
        }

        // Materialize the per-clip original-audio policy onto the immutable specs now that the
        // sidecar (parsed after the clips) is fully validated. Clips without a derived original
        // track keep the spec's unity default.
        val resolvedClipSpecs = clipSpecs.map { spec ->
            val gain = originalGainByClipId[spec.clipId] ?: return@map spec
            spec.copy(originalAudioGain = gain)
        }
        resolvedClipSpecs.forEachIndexed { index, spec ->
            Log.i(
                TAG,
                "VG_EDITOR_AUDIO_PREVIEW original_policy_resolved index=$index clipId=${spec.clipId} " +
                    "originalGain=${spec.originalAudioGain} policyPresent=${originalGainByClipId.containsKey(spec.clipId)}",
            )
        }

        // Exactly one active editor timeline at a time — dispose and fully
        // release any existing active session before creating the replacement.
        disposeActiveSession {
            val surfaceProducer = textureRegistry.createSurfaceProducer(TextureRegistry.SurfaceLifecycle.resetInBackground)
            val textureId = surfaceProducer.id()

            val onTimelineFrame: (Long, Double, Long) -> Unit = { id, ptsSeconds, generationId ->
                mainHandler.post {
                    channel.invokeMethod(
                        "onTimelineFrame",
                        mapOf("textureId" to id, "pts" to ptsSeconds, "generation" to generationId),
                    )
                }
            }
            val onTimelineEOS: (Long) -> Unit = { id ->
                pauseAddedAudioRuntimesIfActive(id)
                mainHandler.post {
                    channel.invokeMethod("onTimelineEOS", mapOf("textureId" to id))
                }
            }
            // Route selection: the transition session is instantiated when at least one
            // non-hard-cut transition survived parsing, OR when the draft requests a
            // "fill" canvas over more than one VIDEO clip (mixed-orientation cover-crop
            // needs this session's canvas-aware quad geometry even with zero real
            // transitions). Image clips never enter AndroidEditorTransitionPlaybackSession
            // in this slice: it is video-only and inspects every clip through
            // AndroidDagSourceInspector, so a slideshow always stays on
            // AndroidEditorSequentialPlaybackSession regardless of canvasContentMode --
            // the image+transitions combination is already rejected above, before this
            // point, and the canvas-fill multi-clip route is gated to video-only here.
            // Every other draft keeps the exact sequential (hard-cut) session it used
            // before this slice.
            val hasImageClip = resolvedClipSpecs.any { it.isImage }
            val isFillMultiClip = canvasContentMode == "fill" && resolvedClipSpecs.size > 1 && !hasImageClip
            // MULTI-VIDEO-BLURFILL: a "blurFill" canvas over more than one VIDEO clip
            // is likewise routed to the transition session (its blurred-background +
            // sharp-foreground draw lives there), including hard-cut-only drafts. A
            // draft carrying any freeze clip stays on the sequential session (plain
            // fit): freeze holds have no seam on the transition route, and freeze
            // clips fail closed to "fit" in this slice anyway.
            val hasFreezeClip = resolvedClipSpecs.any { it.freezePtsUs != null }
            val isBlurFillMultiClip = canvasContentMode == "blurFill" && resolvedClipSpecs.size > 1 &&
                !hasImageClip && !hasFreezeClip
            val routeToTransitionSession = parsedTransitions.isNotEmpty() || isFillMultiClip || isBlurFillMultiClip
            val session: AndroidEditorPlaybackSession = if (routeToTransitionSession) {
                AndroidEditorTransitionPlaybackSession(
                    clipSpecs = resolvedClipSpecs,
                    transitions = parsedTransitions,
                    surfaceProducer = surfaceProducer,
                    onTimelineFrame = onTimelineFrame,
                    onTimelineEOS = onTimelineEOS,
                    context = context,
                    requestedCanvasWidth = requestedCanvasWidth,
                    requestedCanvasHeight = requestedCanvasHeight,
                    canvasContentMode = canvasContentMode,
                )
            } else {
                AndroidEditorSequentialPlaybackSession(
                    clipSpecs = resolvedClipSpecs,
                    surfaceProducer = surfaceProducer,
                    context = context,
                    onTimelineFrame = onTimelineFrame,
                    onTimelineEOS = onTimelineEOS,
                    canvasWidth = requestedCanvasWidth,
                    canvasHeight = requestedCanvasHeight,
                )
            }

            synchronized(lock) {
                active = ActiveEntry(textureId, session, surfaceProducer)
            }

            session.prepare { prepResult ->
                mainHandler.post {
                    val pass = prepResult["pass"] as? Boolean ?: false
                    if (!pass) {
                        if (removeActiveIfSame(textureId, session)) {
                            try { surfaceProducer.release() } catch (t: Throwable) {
                                Log.w(TAG, "createOrUpdateTimeline: release after prepare failure failed", t)
                            }
                        }
                        val raw = prepResult["raw"] as? String ?: "status=FAIL;reason=prepare_failed"
                        result.error("TIMELINE_PREPARE_FAILED", raw, prepResult)
                        return@post
                    }

                    if (!isActiveEntry(textureId, session)) {
                        // disposeTimeline ran while prepare was in flight and already
                        // owns disposal/release of this session; do not release again.
                        result.error("TIMELINE_DISPOSED", "timeline was disposed before prepare completed", prepResult)
                        return@post
                    }

                    val width = prepResult["width"] as? Int ?: 0
                    val height = prepResult["height"] as? Int ?: 0
                    val durationUs = (prepResult["durationUs"] as? Number)?.toLong() ?: 0L
                    val durationSeconds = durationUs / 1_000_000.0

                    val addedAudioConfigs = pendingAddedAudioConfigs
                    if (addedAudioConfigs.isEmpty()) {
                        result.success(mapOf(
                            "textureId" to textureId,
                            "width" to width,
                            "height" to height,
                            "durationSeconds" to durationSeconds,
                        ))
                        return@post
                    }

                    val addedAudioRuntimes = addedAudioConfigs.map {
                        AndroidEditorAddedAudioPreviewRuntime(context, it)
                    }
                    val remainingPrepares = AtomicInteger(addedAudioRuntimes.size)
                    addedAudioRuntimes.forEach { runtime ->
                        runtime.prepare {
                            mainHandler.post {
                                if (remainingPrepares.decrementAndGet() != 0) {
                                    return@post
                                }
                                if (!attachAddedAudioRuntimes(textureId, session, addedAudioRuntimes)) {
                                    // disposeTimeline ran while added-audio prepare was in flight;
                                    // it already disposed the session/surface but never saw these
                                    // runtimes.
                                    addedAudioRuntimes.forEach { it.release() }
                                    result.error(
                                        "TIMELINE_DISPOSED",
                                        "timeline was disposed before prepare completed",
                                        prepResult,
                                    )
                                    return@post
                                }
                                result.success(mapOf(
                                    "textureId" to textureId,
                                    "width" to width,
                                    "height" to height,
                                    "durationSeconds" to durationSeconds,
                                ))
                            }
                        }
                    }
                }
            }
        }
    }

    // ── timelinePlay ───────────────────────────────────────────────────────────

    private fun timelinePlay(result: MethodChannel.Result) {
        val entry = synchronized(lock) { active }
        if (entry == null) {
            result.error("NO_TIMELINE", "no active timeline session", null)
            return
        }
        entry.session.play(frameCount = null) { playResult ->
            mainHandler.post {
                val pass = playResult["pass"] as? Boolean ?: false
                if (pass) {
                    entry.addedAudioRuntimes.forEach { it.play() }
                    result.success(null)
                } else {
                    entry.addedAudioRuntimes.forEach { it.pause() }
                    val raw = playResult["raw"] as? String ?: "status=FAIL;reason=play_failed"
                    result.error("PLAY_FAILED", raw, playResult)
                }
            }
        }
    }

    // ── timelinePause ──────────────────────────────────────────────────────────

    private fun timelinePause(result: MethodChannel.Result) {
        val entry = synchronized(lock) { active }
        if (entry == null) {
            result.error("NO_TIMELINE", "no active timeline session", null)
            return
        }
        entry.addedAudioRuntimes.forEach { it.pause() }
        entry.session.pause { pauseResult ->
            mainHandler.post {
                val pass = pauseResult["pass"] as? Boolean ?: false
                if (pass) {
                    result.success(null)
                } else {
                    val raw = pauseResult["raw"] as? String ?: "status=FAIL;reason=pause_failed"
                    result.error("PAUSE_FAILED", raw, pauseResult)
                }
            }
        }
    }

    // ── timelineSeek ───────────────────────────────────────────────────────────

    private fun timelineSeek(args: Map<*, *>?, result: MethodChannel.Result) {
        val seconds = (args?.get("seconds") as? Number)?.toDouble()
        if (seconds == null) {
            result.error("INVALID_ARG", "timelineSeek: seconds required", null)
            return
        }

        val entry = synchronized(lock) { active }
        if (entry == null) {
            result.error("NO_TIMELINE", "no active timeline session", null)
            return
        }

        val resumeAfterSeek = args?.get("resumeAfterSeek") as? Boolean ?: false

        val targetPtsUs = (seconds * 1_000_000.0).toLong()
        entry.addedAudioRuntimes.forEach { it.pause() }
        entry.session.seek(targetPtsUs, resumeAfterSeek = resumeAfterSeek) { seekResult ->
            mainHandler.post {
                val pass = seekResult["pass"] as? Boolean ?: false
                if (pass) {
                    val runtimes = entry.addedAudioRuntimes
                    if (runtimes.isEmpty()) {
                        result.success(null)
                    } else {
                        val remainingSeeks = AtomicInteger(runtimes.size)
                        runtimes.forEach { runtime ->
                            runtime.seek(targetPtsUs, resumeAfterSeek) {
                                mainHandler.post {
                                    if (remainingSeeks.decrementAndGet() == 0) {
                                        result.success(null)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // Session seek failed; leave the added-audio runtimes paused (above) and
                    // surface the existing session error.
                    val raw = seekResult["raw"] as? String ?: "status=FAIL;reason=seek_failed"
                    result.error("SEEK_FAILED", raw, seekResult)
                }
            }
        }
    }

    // ── active-entry helpers ───────────────────────────────────────────────────

    /** True if [active] still refers to the given [textureId] / [session] pair. */
    private fun isActiveEntry(textureId: Long, session: AndroidEditorPlaybackSession): Boolean {
        return synchronized(lock) {
            active?.textureId == textureId && active?.session === session
        }
    }

    /**
     * Removes [active] under lock if it still refers to the given [textureId] /
     * [session] pair. Returns true if it was removed (i.e., the caller still
     * owned the entry and must finish its own cleanup), false if it had
     * already been disposed/replaced by someone else.
     */
    private fun removeActiveIfSame(textureId: Long, session: AndroidEditorPlaybackSession): Boolean {
        return synchronized(lock) {
            if (active?.textureId == textureId && active?.session === session) {
                active = null
                true
            } else {
                false
            }
        }
    }

    /**
     * Pauses [active]'s addedAudioRuntimes under lock if it still refers to the given
     * [textureId] (i.e., this is still the active session and not one already replaced or
     * disposed). No-op if there is no active entry, the textureId no longer matches, or the
     * active entry has no added runtimes attached.
     */
    private fun pauseAddedAudioRuntimesIfActive(textureId: Long) {
        val runtimes = synchronized(lock) {
            active?.takeIf { it.textureId == textureId }?.addedAudioRuntimes ?: emptyList()
        }
        runtimes.forEach { it.pause() }
    }

    /**
     * Attaches [runtimes] to [active] under lock if it still refers to the given [textureId] /
     * [session] pair. Returns true if attached, false if the entry was already
     * disposed/replaced by someone else (in which case the caller must release [runtimes] itself).
     */
    private fun attachAddedAudioRuntimes(
        textureId: Long,
        session: AndroidEditorPlaybackSession,
        runtimes: List<AndroidEditorAddedAudioPreviewRuntime>,
    ): Boolean {
        return synchronized(lock) {
            val current = active
            if (current != null && current.textureId == textureId && current.session === session) {
                active = current.copy(addedAudioRuntimes = runtimes)
                true
            } else {
                false
            }
        }
    }

    // ── disposeTimeline ────────────────────────────────────────────────────────

    private fun disposeTimeline(result: MethodChannel.Result) {
        disposeActiveSession {
            result.success(null)
        }
    }

    /**
     * Idempotent: removes the active entry under lock exactly once, then
     * disposes its native session and releases its SurfaceProducer before
     * invoking [onDisposed]. If no active entry exists, [onDisposed] runs
     * immediately.
     */
    private fun disposeActiveSession(onDisposed: () -> Unit) {
        val entry = synchronized(lock) {
            val e = active
            active = null
            e
        }
        if (entry == null) {
            onDisposed()
            return
        }

        fun disposeSessionAndSurface() {
            entry.session.dispose {
                mainHandler.post {
                    try { entry.surfaceProducer.release() } catch (t: Throwable) {
                        Log.w(TAG, "disposeActiveSession: surfaceProducer.release() failed", t)
                    }
                    onDisposed()
                }
            }
        }

        val addedAudioRuntimes = entry.addedAudioRuntimes
        if (addedAudioRuntimes.isEmpty()) {
            disposeSessionAndSurface()
        } else {
            val remainingReleases = AtomicInteger(addedAudioRuntimes.size)
            addedAudioRuntimes.forEach { runtime ->
                runtime.release {
                    mainHandler.post {
                        if (remainingReleases.decrementAndGet() == 0) {
                            disposeSessionAndSurface()
                        }
                    }
                }
            }
        }
    }

    /** Best-effort idempotent cleanup for plugin detach. */
    fun disposeAll() {
        disposeActiveSession {}
    }

    // ── timeline_setAudioMixGain ──────────────────────────────────────────

    private fun timelineSetAudioMixGain(args: Map<*, *>?, result: MethodChannel.Result) {
        val rawTextureId = args?.get("textureId")
        if (rawTextureId == null) {
            result.error("INVALID_ARG", "timeline_setAudioMixGain: missing textureId", null)
            return
        }
        val requestedTextureId = (rawTextureId as? Number)?.toLong()
        if (requestedTextureId == null || requestedTextureId < 0L) {
            result.error("INVALID_ARG", "timeline_setAudioMixGain: textureId must be non-negative integer", null)
            return
        }

        val trackId = args["trackId"] as? String
        if (trackId.isNullOrEmpty()) {
            result.error("INVALID_ARG", "timeline_setAudioMixGain: missing or empty trackId", null)
            return
        }

        val gainNum = args["gain"] as? Number
        if (gainNum == null) {
            result.error("INVALID_ARG", "timeline_setAudioMixGain: gain must be a number", null)
            return
        }
        val gain = gainNum.toDouble().coerceIn(0.0, 1.0).toFloat()

        synchronized(lock) {
            val currentActive = active
            if (currentActive == null || currentActive.textureId != requestedTextureId) {
                result.error(
                    "STALE_TIMELINE",
                    "timeline_setAudioMixGain: textureId $requestedTextureId is not an active timeline session",
                    null,
                )
                return
            }

            if (trackId.startsWith("original-")) {
                val clipId = trackId.removePrefix("original-")
                currentActive.session.setOriginalTrackGain(clipId, gain)
            } else if (trackId == "original") {
                currentActive.session.setAllOriginalTracksGain(gain)
            } else {
                val matchingRuntime = currentActive.addedAudioRuntimes.firstOrNull { it.trackId == trackId }
                if (matchingRuntime != null) {
                    matchingRuntime.setMixGain(gain)
                } else {
                    Log.w(TAG, "timeline_setAudioMixGain: trackId $trackId not found in addedAudioRuntimes")
                }
            }
        }
        result.success(null)
    }

    // ── Phase 10-C-3N: read-only accessor for AndroidTimelineLiveControlCoordinator ──

    /** The textureId of the active timeline, or null if none is active. */
    fun activeTimelineTextureId(): Long? = synchronized(lock) { active?.textureId }
}
