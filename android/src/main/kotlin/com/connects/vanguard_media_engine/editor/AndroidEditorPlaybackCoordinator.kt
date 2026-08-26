package com.connects.vanguard_media_engine.editor

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.codec.AndroidDagTexturePlaybackControlSession
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * Phase 7.8A-Android: owns the public Dart VGEditorController playback routes
 * (createTimelineTexture, updateTimeline, timelinePlay, timelinePause,
 * timelineSeek, disposeTimeline) for exactly one local video clip.
 *
 * Delegates execution to [AndroidDagTexturePlaybackControlSession]. Does not
 * own streaming/cache/RTC/export/multi-clip compositor policy — those remain
 * owned by their respective coordinators or are left unimplemented for this
 * slice (multi-clip, transitions, overlays, transforms, audio sidecars,
 * reverse sidecars, timeline cache stats, exportTimeline, clearTimelineCache).
 */
class AndroidEditorPlaybackCoordinator(
    private val textureRegistry: TextureRegistry,
    private val channel: MethodChannel,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "EditorPlaybackCoord"

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
        val session: AndroidDagTexturePlaybackControlSession,
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

        if (clips.size != 1) {
            result.error("UNSUPPORTED_TIMELINE", "exactly one clip is supported in this slice", null)
            return
        }

        val clip = clips[0] as? Map<*, *>
        val mediaKind = clip?.get("mediaKind") as? String
        if (mediaKind != null && mediaKind != "video") {
            result.error("UNSUPPORTED_MEDIA_KIND", "mediaKind=$mediaKind is not supported", null)
            return
        }

        val sourcePath = clip?.get("sourcePath") as? String
        if (sourcePath.isNullOrBlank()) {
            result.error("FILE_UNREADABLE", "sourcePath is missing or blank", null)
            return
        }
        val file = java.io.File(sourcePath)
        if (!file.exists() || !file.canRead()) {
            result.error("FILE_UNREADABLE", "sourcePath is not readable: $sourcePath", null)
            return
        }

        // Exactly one active editor timeline at a time — dispose and fully
        // release any existing active session before creating the replacement.
        disposeActiveSession {
            val surfaceProducer = textureRegistry.createSurfaceProducer(TextureRegistry.SurfaceLifecycle.resetInBackground)
            val textureId = surfaceProducer.id()

            val session = AndroidDagTexturePlaybackControlSession(
                videoPath = sourcePath,
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
    private fun isActiveEntry(textureId: Long, session: AndroidDagTexturePlaybackControlSession): Boolean {
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
    private fun removeActiveIfSame(textureId: Long, session: AndroidDagTexturePlaybackControlSession): Boolean {
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
}
