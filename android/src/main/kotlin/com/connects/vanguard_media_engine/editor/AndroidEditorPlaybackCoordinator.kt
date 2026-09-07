package com.connects.vanguard_media_engine.editor

import android.content.Context
import android.os.Handler
import android.util.Log
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
 * for the original/music/sfx/voiceover lanes (Phase 7.8O-Android). Validates
 * each draft against the current unsupported-feature guardrails (transitions,
 * overlays, per-clip transform, non-default fit/crop, freeze frame, reverse
 * playback, dual camera, time remap, transform track, color matrix) and
 * delegates execution to [AndroidEditorSequentialPlaybackSession]. Does not
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
) {
    companion object {
        private const val TAG = "EditorPlaybackCoord"

        /** Tolerance (seconds) for a clip's trimEndSeconds vs. its declared durationSeconds. */
        private const val TRIM_DURATION_TOLERANCE_SECONDS = 0.002

        /** Tolerance (us) for advisory wire startTimeSeconds vs. the computed sequential cursor. */
        private const val STARTTIME_TOLERANCE_US = 1_000L

        /**
         * Phase 7.8O-Android: native eager-MediaPlayer preview safety cap — each lane
         * (added music+sfx, or voiceover) may hold at most this many non-overlapping
         * tracks. Not a product UX rule; purely a guard against unbounded MediaPlayer
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
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS

        /** Added lane = `music` and `sfx` (Phase 7.8O-Android); `voiceover` is its own lane. */
        private fun isAddedLaneRole(role: String?) = role == "music" || role == "sfx"
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
        val session: AndroidEditorSequentialPlaybackSession,
        val surfaceProducer: TextureRegistry.SurfaceProducer,
        /**
         * Added-audio preview runtimes: zero or more, one per validated audioSidecar track
         * (Phase 7.8O-Android: multiple non-overlapping `music`/`sfx` tracks share the added
         * lane, multiple non-overlapping `voiceover` tracks share the voiceover lane; see
         * [validateAndAddLaneWindow]). Attached after [AndroidEditorSequentialPlaybackSession
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
        // 'audioSidecar' is present only when a plan is set.
        val transitions = draft["transitions"] as? List<*>
        if (transitions != null && transitions.isNotEmpty()) {
            result.error("UNSUPPORTED_TIMELINE_FEATURE", "transitions are not supported in this slice", null)
            return
        }
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
        for (rawClip in clips) {
            val clip = rawClip as? Map<*, *>
            if (clip == null) {
                result.error("INVALID_CLIP", "each clip must be a map", null)
                return
            }

            val mediaKind = clip["mediaKind"] as? String
            if (mediaKind != null && mediaKind != "video") {
                result.error("UNSUPPORTED_MEDIA_KIND", "mediaKind=$mediaKind is not supported", null)
                return
            }

            // Per-clip unsupported-feature guardrails. Each of these wire keys is
            // present in VGClipDescriptor.toMap() only when the field differs from
            // its supported default (see vg_clip_descriptor.dart), so presence
            // alone identifies an unsupported clip.
            if (clip["transform"] != null ||
                clip["fitMode"] != null ||
                clip["cropRect"] != null ||
                clip["freezePTS"] != null ||
                clip["isReversed"] != null ||
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

            val sourcePath = clip["sourcePath"] as? String
            if (sourcePath.isNullOrBlank()) {
                result.error("FILE_UNREADABLE", "sourcePath is missing or blank", null)
                return
            }
            // POSIX paths keep the File.exists()/canRead() check; `content://` URIs are probed
            // via ContentResolver and fail closed (false) when the context is null or the
            // provider refuses. No texture/session has been allocated yet, so the caller can
            // retry with a valid path/URI after a FILE_UNREADABLE error.
            if (!AndroidUriDataSourceHelper.isReadable(sourcePath, context)) {
                result.error("FILE_UNREADABLE", "sourcePath is not readable: $sourcePath", null)
                return
            }

            // Timing/trim fields are unconditionally present in VGClipDescriptor.toMap()
            // (see vg_clip_descriptor.dart:604-614). speed != 1.0 is rejected here because
            // speed audio/video parity is not part of this slice.
            val speed = (clip["speed"] as? Number)?.toDouble()
            if (speed == null || !speed.isFinite()) {
                result.error("INVALID_CLIP", "clip \"${clip["id"]}\" has a missing or non-finite speed", null)
                return
            }
            if (speed != 1.0) {
                result.error(
                    "UNSUPPORTED_TIMELINE_FEATURE",
                    "clip \"${clip["id"]}\" uses speed=$speed, which is not supported in this slice",
                    null,
                )
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

            val sourceTrimStartUs = (trimStartSeconds * 1_000_000.0).toLong()
            val sourceTrimEndUs = (trimEndSeconds * 1_000_000.0).toLong()
            val timelineDurationUs = sourceTrimEndUs - sourceTrimStartUs
            if (timelineDurationUs <= 0L) {
                result.error("INVALID_CLIP", "clip \"${clip["id"]}\" has a non-positive trim duration", null)
                return
            }

            // Wire startTimeSeconds is advisory only: reject a non-zero value that
            // disagrees with the computed sequential cursor by more than 1ms, but never
            // treat it as authoritative layout (multiple clips may all report 0.0).
            val wireStartTimeUs = (startTimeSeconds * 1_000_000.0).toLong()
            if (startTimeSeconds != 0.0 && Math.abs(wireStartTimeUs - cursorUs) > STARTTIME_TOLERANCE_US) {
                result.error(
                    "INVALID_CLIP",
                    "clip \"${clip["id"]}\" startTimeSeconds=$startTimeSeconds disagrees with " +
                        "computed sequential position ${cursorUs / 1_000_000.0}",
                    null,
                )
                return
            }

            clipSpecs.add(
                AndroidEditorClipPlaybackSpec(
                    sourcePath = sourcePath,
                    timelineStartUs = cursorUs,
                    sourceTrimStartUs = sourceTrimStartUs,
                    sourceTrimEndUs = sourceTrimEndUs,
                    timelineDurationUs = timelineDurationUs,
                ),
            )
            cursorUs += timelineDurationUs
        }

        // 'audioSidecar' is present in VGEditorDraft.toMap() only when a plan is
        // set. This route accepts two sidecar track shapes: (1) the controller's
        // own derived original-clip-audio tracks (VGEditorDraft
        // .flattenOriginalClipAudio()) — one synthetic track per clip's own
        // already-validated sourcePath, tagged role="original" with a trackId of
        // "original-<clipId>" — passed through unchanged; and (2) any number of
        // user-added role="music"/"sfx" tracks (the shared added lane, matching
        // the shared placement policy) and role="voiceover" tracks (its own lane,
        // Phase 7.8O-Android: sfx parity + multi-track added lanes), supported on
        // hard-cut single- or multi-clip timelines (Phase 7.8N-Android: multi-clip
        // added-audio preview), each with a finite non-negative startTime (Phase
        // 7.8K-Android: delayed start/end) and finite non-negative
        // fadeInSeconds/fadeOutSeconds and/or volumeKeyframes (Phase 7.8M-Android:
        // volume automation; see
        // AndroidEditorAddedAudioPreviewRuntime/AndroidEditorAudioAutomation).
        // Tracks sharing a lane must not overlap ([startUs, startUs+durationUs) is
        // half-open; touching endpoints are allowed) and each lane is capped at
        // [MAX_TRACKS_PER_LANE] tracks (a native eager-MediaPlayer preview safety
        // guard, not a product rule — see [validateAndAddLaneWindow]). Any other
        // role (unknown, null), a same-lane overlap, a lane over its cap, or
        // unsupported video features on the timeline remain unsupported in this
        // slice; iOS-style dynamic same-lane priority selection is intentionally
        // not implemented here.
        val audioSidecar = draft["audioSidecar"]
        val pendingAddedAudioConfigs = mutableListOf<AndroidEditorAddedAudioTrackConfig>()
        if (audioSidecar != null) {
            val sidecarMap = audioSidecar as? Map<*, *>
            val tracks = sidecarMap?.get("tracks") as? List<*>
            if (tracks == null || tracks.isEmpty()) {
                result.error("INVALID_AUDIO_SIDECAR", "audioSidecar.tracks must be a non-empty list", null)
                return
            }

            val addedLaneWindows = mutableListOf<AddedAudioLaneWindow>()
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
                    if (trackId.isNullOrBlank() || !trackId.startsWith("original-") ||
                        url.isNullOrBlank() || clipSpecs.none { it.sourcePath == url }
                    ) {
                        result.error(
                            "INVALID_AUDIO_SIDECAR",
                            "track \"$trackId\" is not a valid derived original-audio track",
                            null,
                        )
                        return
                    }
                    continue
                }

                if (!isAddedLaneRole(role) && role != "voiceover") {
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

                val laneWindows = if (isAddedLaneRole(role)) addedLaneWindows else voiceoverLaneWindows
                val laneName = if (isAddedLaneRole(role)) "added (music/sfx)" else "voiceover"
                val laneError = validateAndAddLaneWindow(
                    laneWindows,
                    laneName,
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

                val addedAudioFile = java.io.File(url)
                if (!addedAudioFile.exists() || !addedAudioFile.canRead()) {
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

        // Exactly one active editor timeline at a time — dispose and fully
        // release any existing active session before creating the replacement.
        disposeActiveSession {
            val surfaceProducer = textureRegistry.createSurfaceProducer(TextureRegistry.SurfaceLifecycle.resetInBackground)
            val textureId = surfaceProducer.id()

            val session = AndroidEditorSequentialPlaybackSession(
                clipSpecs = clipSpecs,
                surfaceProducer = surfaceProducer,
                context = context,
                onTimelineFrame = { id, ptsSeconds, generationId ->
                    mainHandler.post {
                        channel.invokeMethod(
                            "onTimelineFrame",
                            mapOf("textureId" to id, "pts" to ptsSeconds, "generation" to generationId),
                        )
                    }
                },
                onTimelineEOS = { id ->
                    pauseAddedAudioRuntimesIfActive(id)
                    mainHandler.post {
                        channel.invokeMethod("onTimelineEOS", mapOf("textureId" to id))
                    }
                },
            )

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
    private fun isActiveEntry(textureId: Long, session: AndroidEditorSequentialPlaybackSession): Boolean {
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
    private fun removeActiveIfSame(textureId: Long, session: AndroidEditorSequentialPlaybackSession): Boolean {
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
        session: AndroidEditorSequentialPlaybackSession,
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

    // ── Phase 10-C-3N: read-only accessor for AndroidTimelineLiveControlCoordinator ──

    /** The textureId of the active timeline, or null if none is active. */
    fun activeTimelineTextureId(): Long? = synchronized(lock) { active?.textureId }
}
