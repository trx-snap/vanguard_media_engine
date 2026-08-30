package com.connects.vanguard_media_engine.editor

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * Phase 7.8G-Android: owns the public Dart VGEditorController playback routes
 * (createTimelineTexture, updateTimeline, timelinePlay, timelinePause,
 * timelineSeek, disposeTimeline) for sequential plain local video clips
 * (one or more clips, hard-cut concatenation only).
 *
 * Validates each draft against the current unsupported-feature guardrails
 * (transitions, overlays, audio sidecar, per-clip transform, non-default
 * fit/crop, freeze frame, reverse playback, dual camera, time remap,
 * transform track, color matrix) and delegates execution to
 * [AndroidEditorSequentialPlaybackSession]. Does not own streaming/cache/
 * RTC/export/compositor policy — those remain owned by their respective
 * coordinators or are left unimplemented for this slice (exportTimeline,
 * clearTimelineCache, timeline cache stats).
 */
class AndroidEditorPlaybackCoordinator(
    private val textureRegistry: TextureRegistry,
    private val channel: MethodChannel,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "EditorPlaybackCoord"

        /** Tolerance (seconds) for a clip's trimEndSeconds vs. its declared durationSeconds. */
        private const val TRIM_DURATION_TOLERANCE_SECONDS = 0.002

        /** Tolerance (us) for advisory wire startTimeSeconds vs. the computed sequential cursor. */
        private const val STARTTIME_TOLERANCE_US = 1_000L

        private val OWNED_METHODS = setOf(
            "createTimelineTexture",
            "updateTimeline",
            "timelinePlay",
            "timelinePause",
            "timelineSeek",
            "disposeTimeline",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    private data class ActiveEntry(
        val textureId: Long,
        val session: AndroidEditorSequentialPlaybackSession,
        val surfaceProducer: TextureRegistry.SurfaceProducer,
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
            val file = java.io.File(sourcePath)
            if (!file.exists() || !file.canRead()) {
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
        // set. This route ignores audio entirely, so the only sidecar shape it
        // may accept is the controller's own derived original-clip-audio plan
        // (VGEditorDraft.flattenOriginalClipAudio()) — one synthetic track per
        // clip's own already-validated sourcePath, tagged role="original" with a
        // trackId of "original-<clipId>". Anything else (real mixing/added
        // audio) must still be rejected.
        val audioSidecar = draft["audioSidecar"]
        if (audioSidecar != null) {
            val sidecarMap = audioSidecar as? Map<*, *>
            val tracks = sidecarMap?.get("tracks") as? List<*>
            val isDerivedOriginalOnly = tracks != null && tracks.isNotEmpty() && tracks.all { rawTrack ->
                val track = rawTrack as? Map<*, *> ?: return@all false
                val trackId = track["trackId"] as? String
                val url = track["url"] as? String
                track["role"] == "original" &&
                    trackId != null && trackId.startsWith("original-") &&
                    !url.isNullOrBlank() &&
                    clipSpecs.any { it.sourcePath == url }
            }
            if (!isDerivedOriginalOnly) {
                result.error(
                    "UNSUPPORTED_TIMELINE_FEATURE",
                    "non-original audio sidecars are not supported in this slice",
                    null,
                )
                return
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
                onTimelineFrame = { id, ptsSeconds, generationId ->
                    mainHandler.post {
                        channel.invokeMethod(
                            "onTimelineFrame",
                            mapOf("textureId" to id, "pts" to ptsSeconds, "generation" to generationId),
                        )
                    }
                },
                onTimelineEOS = { id ->
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
                    result.success(null)
                } else {
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

        val targetPtsUs = (seconds * 1_000_000.0).toLong()
        entry.session.seek(targetPtsUs, resumeAfterSeek = false) { seekResult ->
            mainHandler.post {
                val pass = seekResult["pass"] as? Boolean ?: false
                if (pass) {
                    result.success(null)
                } else {
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
        entry.session.dispose {
            mainHandler.post {
                try { entry.surfaceProducer.release() } catch (t: Throwable) {
                    Log.w(TAG, "disposeActiveSession: surfaceProducer.release() failed", t)
                }
                onDisposed()
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
