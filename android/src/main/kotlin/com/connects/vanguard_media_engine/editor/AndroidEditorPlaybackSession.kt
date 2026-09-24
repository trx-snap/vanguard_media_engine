package com.connects.vanguard_media_engine.editor

/**
 * Editor preview playback session contract consumed by [AndroidEditorPlaybackCoordinator].
 *
 * Two production implementations exist:
 *   - [AndroidEditorSequentialPlaybackSession] -- the frozen hard-cut route (one wrapped
 *     AndroidDagTexturePlaybackControlSession at a time, freeze clips, per-clip original
 *     audio); its behaviour is unchanged by this interface.
 *   - [AndroidEditorTransitionPlaybackSession] -- the non-hard-cut transition route
 *     (export-equivalent dual-decode GLES compositing onto the Flutter SurfaceProducer).
 *
 * Every method takes/returns exactly the shapes the sequential session already had, so the
 * coordinator's MethodChannel plumbing (`createTimelineTexture`, `timelinePlay`,
 * `timelinePause`, `timelineSeek`, `disposeTimeline`, `timeline_setAudioMixGain`) is
 * route-agnostic. Result maps always carry `pass` (Boolean) and `raw` (a
 * `status=OK;...` / `status=FAIL;reason=...` string); [prepare] additionally carries
 * `textureId`, `width`, `height`, `durationUs` on success.
 *
 * Ownership: the coordinator owns the session and the Flutter SurfaceProducer; a session
 * never releases the SurfaceProducer. Added-audio (music/sfx/voiceover) runtimes are owned
 * by the coordinator, never by a session; a session owns only per-clip original-audio
 * runtimes.
 *
 * Concurrency: implementations serialize prepare/play/pause/seek/dispose on their own
 * orchestration thread; every method is safe to call from the platform (main) thread and
 * never blocks the caller. Callbacks may fire on the session's own thread; the coordinator
 * re-posts to main.
 */
interface AndroidEditorPlaybackSession {
    fun prepare(onResult: (Map<String, Any?>) -> Unit)

    /** Continuous playback when [frameCount] is null; bounded (diagnostic) play otherwise. */
    fun play(frameCount: Int?, onResult: (Map<String, Any?>) -> Unit)

    fun pause(onResult: (Map<String, Any?>) -> Unit)

    /** [targetGlobalPtsUs] is a global editor-timeline position in microseconds. */
    fun seek(targetGlobalPtsUs: Long, resumeAfterSeek: Boolean, onResult: (Map<String, Any?>) -> Unit)

    /** Idempotent terminal teardown. [onResult] (when given) fires exactly once. */
    fun dispose(onResult: ((Map<String, Any?>) -> Unit)? = null)

    /** Live original-audio gain update for one draft clip id (clamped to [0.0, 1.0]). */
    fun setOriginalTrackGain(clipId: String, gain: Float)

    /** Live original-audio gain update for every clip (clamped to [0.0, 1.0]). */
    fun setAllOriginalTracksGain(gain: Float)
}
