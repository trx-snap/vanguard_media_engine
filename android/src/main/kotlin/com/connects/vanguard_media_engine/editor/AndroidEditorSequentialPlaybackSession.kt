package com.connects.vanguard_media_engine.editor

import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.connects.vanguard_media_engine.codec.AndroidDagSourceInspector
import com.connects.vanguard_media_engine.codec.AndroidDagTexturePlaybackControlSession
import io.flutter.view.TextureRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Trim/timeline timing for one clip in an editor preview sequence.
 *
 * Built by [AndroidEditorPlaybackCoordinator] from a validated VGClipDescriptor map (see
 * vg_clip_descriptor.dart) and owned/consumed by [AndroidEditorSequentialPlaybackSession].
 * All fields are microseconds. [sourceTrimStartUs] / [sourceTrimEndUs] are measured from the
 * start of the source file at [sourcePath] (decoder/source-local PTS space); [timelineStartUs]
 * is this clip's position on the global editor timeline. [timelineDurationUs] is this clip's
 * contribution to the global timeline — for the 1.0x-speed-only clips this slice supports, it
 * equals `sourceTrimEndUs - sourceTrimStartUs`.
 */
data class AndroidEditorClipPlaybackSpec(
    val sourcePath: String,
    val timelineStartUs: Long,
    val sourceTrimStartUs: Long,
    val sourceTrimEndUs: Long,
    val timelineDurationUs: Long,
)

/**
 * Phase 7.8G-Android: sequential multi-clip editor playback session.
 *
 * Wraps exactly one active [AndroidDagTexturePlaybackControlSession] at a time — one per plain
 * local video clip in [clipSpecs] — reusing the same [surfaceProducer] across clip switches, and
 * maps clip-local (source-file) decoder PTS onto a single global timeline PTS using each clip's
 * [AndroidEditorClipPlaybackSpec] trim window, so trimmed drafts preserve clip trim/timeline
 * timing instead of playing each clip's untrimmed full source.
 *
 * Cross-clip transitions/overlays/audio-sidecar/transform/speed features are rejected by
 * [AndroidEditorPlaybackCoordinator] before this session is constructed.
 *
 * Ownership: [AndroidEditorPlaybackCoordinator] owns this session and the [surfaceProducer].
 * This session never releases the [surfaceProducer] — only the
 * [AndroidDagTexturePlaybackControlSession] it wraps is disposed and recreated on clip
 * switches / disposal.
 *
 * Concurrency: all orchestration (prepare / play / pause / seek / clip-switch on EOS / dispose)
 * is serialized on a single dedicated [HandlerThread] owned by this session (`orchHandler`).
 * Clip activation ([activateClipBlocking]) blocks that thread until the wrapped session's
 * asynchronous prepare/seek callback fires (via [CountDownLatch]), so no two activations — and
 * no command racing an in-flight activation — can ever observe or mutate [activeSession] /
 * [activeClipIndex] concurrently. This mirrors [AndroidDagTexturePlaybackControlSession]'s own
 * single-HandlerThread confinement, bridged across the extra thread hop that wrapping
 * introduces.
 */
class AndroidEditorSequentialPlaybackSession(
    private val clipSpecs: List<AndroidEditorClipPlaybackSpec>,
    private val surfaceProducer: TextureRegistry.SurfaceProducer,
    private val onTimelineFrame: (textureId: Long, ptsSeconds: Double, generationId: Long) -> Unit,
    private val onTimelineEOS: (textureId: Long) -> Unit,
) {
    companion object {
        private const val TAG = "EditorSeqPlaybackSession"

        /** Tolerance for validating a clip's requested trimEnd against its inspected source duration. */
        private const val TRIM_DURATION_TOLERANCE_US = 2_000L
    }

    private val disposed = AtomicBoolean(false)

    /**
     * Bumped on every clip activation and on dispose; invalidates stale in-flight
     * frame/EOS callbacks from a superseded [AndroidDagTexturePlaybackControlSession].
     * This is a session-identity token, NOT the public timeline generation surfaced
     * to [onTimelineFrame] callers — those are two distinct concerns (see
     * [publicGeneration]).
     */
    private val sessionToken = AtomicLong(0L)

    /**
     * Monotonically increasing public timeline generation surfaced via
     * [onTimelineFrame]. Bumped once per clip activation (first frame of the newly
     * active clip) and once per intra-clip seek (detected by the wrapped session's
     * own inner `generationId` changing), so callers observe a strictly newer
     * generation for every seek and every clip transition — matching the readiness
     * packet's "every seek and clip transition must increment the monotonic
     * generationId" requirement — without being tied to per-clip-session identity.
     */
    private val publicGeneration = AtomicLong(0L)

    private var orchThread: HandlerThread? = null
    private var orchHandler: Handler? = null

    private var totalDurationUs: Long = 0L
    private var activeClipIndex: Int = -1
    private var activeSession: AndroidDagTexturePlaybackControlSession? = null
    private var isPlaying: Boolean = false

    // ── prepare ────────────────────────────────────────────────────────────

    /**
     * Inspects every clip (metadata only, verifying readability and that each clip's
     * requested trim window fits within its actual source duration), computes the
     * global timeline duration from [clipSpecs], then activates clip 0 (prerolling to
     * its trim start when non-zero). [onResult] receives `{pass, textureId, width,
     * height, durationUs, raw}` on success, matching the shape
     * [AndroidEditorPlaybackCoordinator] already expects from a single-clip
     * [AndroidDagTexturePlaybackControlSession.prepare].
     */
    fun prepare(onResult: (Map<String, Any?>) -> Unit) {
        if (clipSpecs.isEmpty()) {
            onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=empty_clip_list"))
            return
        }

        val ht = HandlerThread("EditorSeqPlaybackOrch_${surfaceProducer.id()}").also {
            orchThread = it
            it.start()
        }
        val h = Handler(ht.looper).also { orchHandler = it }

        h.post {
            if (disposed.get()) {
                onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=disposed"))
                return@post
            }

            for (spec in clipSpecs) {
                val inspection = AndroidDagSourceInspector().inspect(spec.sourcePath)
                try {
                    if (!inspection.pass) {
                        dispose(null)
                        onResult(mapOf(
                            "pass" to false,
                            "raw" to "status=FAIL;reason=clip_inspect_failed;path=${spec.sourcePath};detail=${inspection.failureReason}",
                        ))
                        return@post
                    }
                    if (spec.sourceTrimEndUs > inspection.durationUs + TRIM_DURATION_TOLERANCE_US) {
                        dispose(null)
                        onResult(mapOf(
                            "pass" to false,
                            "raw" to "status=FAIL;reason=trim_exceeds_source_duration;path=${spec.sourcePath};" +
                                "trimEndUs=${spec.sourceTrimEndUs};sourceDurationUs=${inspection.durationUs}",
                        ))
                        return@post
                    }
                } finally {
                    // Metadata-only probe: release immediately. The active clip's own
                    // AndroidDagTexturePlaybackControlSession performs its own independent
                    // inspect + decode configure when it becomes active.
                    try { inspection.extractor?.release() } catch (_: Throwable) {}
                }
            }

            totalDurationUs = clipSpecs.maxOf { it.timelineStartUs + it.timelineDurationUs }

            val activateResult = activateClipBlocking(0, explicitSourceSeekUs = null, resumeAfterSeek = false)
            val pass = activateResult["pass"] as? Boolean ?: false
            if (!pass) {
                dispose(null)
                onResult(activateResult)
                return@post
            }

            val width = activateResult["width"] as? Int ?: 0
            val height = activateResult["height"] as? Int ?: 0
            onResult(mapOf(
                "pass" to true,
                "textureId" to surfaceProducer.id(),
                "width" to width,
                "height" to height,
                "durationUs" to totalDurationUs,
                "raw" to "status=OK;clipCount=${clipSpecs.size};totalDurationUs=$totalDurationUs",
            ))
        }
    }

    // ── play / pause ───────────────────────────────────────────────────────

    fun play(frameCount: Int?, onResult: (Map<String, Any?>) -> Unit) {
        val h = orchHandler
        if (h == null || disposed.get()) {
            onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=session_disposed_or_uninitialized"))
            return
        }
        h.post {
            val session = activeSession
            if (disposed.get() || session == null) {
                onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=session_disposed_or_uninitialized"))
                return@post
            }
            isPlaying = true
            session.play(frameCount, onResult)
        }
    }

    fun pause(onResult: (Map<String, Any?>) -> Unit) {
        val h = orchHandler
        if (h == null || disposed.get()) {
            onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=session_disposed_or_uninitialized"))
            return
        }
        h.post {
            val session = activeSession
            if (disposed.get() || session == null) {
                onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=session_disposed_or_uninitialized"))
                return@post
            }
            isPlaying = false
            session.pause(onResult)
        }
    }

    // ── seek ───────────────────────────────────────────────────────────────

    /**
     * Maps [targetGlobalPtsUs] (global timeline microseconds) to a target clip + source-local
     * PTS via [mapGlobalToSourcePts]. An intra-clip seek delegates directly to the active
     * [AndroidDagTexturePlaybackControlSession]; a cross-clip seek switches the active session
     * first (via [activateClipBlocking]) and then seeks the freshly-activated session to the
     * mapped source-local target.
     */
    fun seek(targetGlobalPtsUs: Long, resumeAfterSeek: Boolean, onResult: (Map<String, Any?>) -> Unit) {
        val h = orchHandler
        if (h == null || disposed.get()) {
            onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=session_disposed_or_uninitialized"))
            return
        }
        h.post {
            if (disposed.get() || clipSpecs.isEmpty()) {
                onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=session_disposed_or_uninitialized"))
                return@post
            }

            val clampedUs = targetGlobalPtsUs.coerceIn(0L, (totalDurationUs - 1L).coerceAtLeast(0L))
            val targetIndex = resolveClipIndex(clampedUs)
            val targetSpec = clipSpecs[targetIndex]
            val sourceTargetUs = mapGlobalToSourcePts(clampedUs, targetSpec)
            isPlaying = resumeAfterSeek

            val activeNow = activeSession
            if (targetIndex == activeClipIndex && activeNow != null) {
                activeNow.seek(sourceTargetUs, resumeAfterSeek) { seekResult ->
                    onResult(translateSeekResult(seekResult, targetSpec))
                }
            } else {
                val activateResult = activateClipBlocking(
                    targetIndex,
                    explicitSourceSeekUs = sourceTargetUs,
                    resumeAfterSeek = resumeAfterSeek,
                )
                onResult(translateSeekResult(activateResult, targetSpec))
            }
        }
    }

    /** Resolves [globalPtsUs] to the clip whose `[timelineStartUs, timelineStartUs + timelineDurationUs)` range contains it. */
    private fun resolveClipIndex(globalPtsUs: Long): Int {
        var idx = 0
        for (i in clipSpecs.indices) {
            if (clipSpecs[i].timelineStartUs <= globalPtsUs) idx = i else break
        }
        return idx
    }

    /**
     * Maps a global timeline PTS to the corresponding source-local PTS for [spec], clamped to
     * its trim window `[sourceTrimStartUs, sourceTrimEndUs)` so an out-of-range global target
     * (e.g. the final-clip-inclusive end of the timeline) never produces a seek target at or
     * past this clip's trim end.
     */
    private fun mapGlobalToSourcePts(globalPtsUs: Long, spec: AndroidEditorClipPlaybackSpec): Long {
        val sourcePtsUs = spec.sourceTrimStartUs + (globalPtsUs - spec.timelineStartUs)
        val maxSourceUs = (spec.sourceTrimEndUs - 1L).coerceAtLeast(spec.sourceTrimStartUs)
        return sourcePtsUs.coerceIn(spec.sourceTrimStartUs, maxSourceUs)
    }

    /**
     * Maps a source-local PTS back to the global timeline PTS for [spec], unclamped — used only
     * for translating diagnostic seek-result fields, not for gating what is ever rendered.
     */
    private fun sourceToGlobalPtsRaw(sourcePtsUs: Long, spec: AndroidEditorClipPlaybackSpec): Long =
        spec.timelineStartUs + (sourcePtsUs - spec.sourceTrimStartUs)

    /**
     * Maps a source-local PTS back to the global timeline PTS for [spec], clamped into this
     * clip's timeline window so a decoder callback never surfaces a PTS outside the trimmed
     * window to [onTimelineFrame].
     */
    private fun sourceToGlobalPtsClamped(sourcePtsUs: Long, spec: AndroidEditorClipPlaybackSpec): Long {
        val globalPtsUs = sourceToGlobalPtsRaw(sourcePtsUs, spec)
        val maxGlobalUs = (spec.timelineStartUs + spec.timelineDurationUs - 1L).coerceAtLeast(spec.timelineStartUs)
        return globalPtsUs.coerceIn(spec.timelineStartUs, maxGlobalUs)
    }

    private fun translateSeekResult(result: Map<String, Any?>, spec: AndroidEditorClipPlaybackSpec): Map<String, Any?> {
        val out = result.toMutableMap()
        (result["seekTargetUs"] as? Number)?.let { out["seekTargetUs"] = sourceToGlobalPtsRaw(it.toLong(), spec) }
        (result["seekRenderedPtsUs"] as? Number)?.let { out["seekRenderedPtsUs"] = sourceToGlobalPtsRaw(it.toLong(), spec) }
        return out
    }

    // ── clip activation (dispose old + create/prepare/seek new) ────────────

    /**
     * Must be called from [orchHandler]. Disposes any current [activeSession]
     * (waiting for its teardown to fully complete — in particular, releasing
     * its [TextureRegistry.SurfaceProducer.SurfaceCallback] registration —
     * before the replacement session touches the shared [surfaceProducer]),
     * then creates, prepares, and preroll-seeks the session for
     * `clipSpecs[index]`. When [explicitSourceSeekUs] is null, activation
     * preroll-seeks to the clip's own `sourceTrimStartUs` if non-zero (so a
     * default clip activation always lands on the trimmed-in frame); when
     * non-null (an explicit cross-clip seek target), that value is used
     * directly. Blocks the calling thread on each async step via
     * [CountDownLatch] so the whole activation is atomic from the perspective
     * of every other orchHandler-serialized command (no interleaved seek/play/
     * EOS-switch can observe a partially-activated state).
     */
    private fun activateClipBlocking(
        index: Int,
        explicitSourceSeekUs: Long?,
        resumeAfterSeek: Boolean,
    ): Map<String, Any?> {
        val old = activeSession
        activeSession = null
        if (old != null) {
            val disposeLatch = CountDownLatch(1)
            old.dispose { disposeLatch.countDown() }
            disposeLatch.await()
        }

        if (disposed.get()) {
            return mapOf("pass" to false, "raw" to "status=FAIL;reason=disposed")
        }
        if (index !in clipSpecs.indices) {
            return mapOf("pass" to false, "raw" to "status=FAIL;reason=clip_index_out_of_range;index=$index")
        }

        val mySessionToken = sessionToken.incrementAndGet()
        val spec = clipSpecs[index]

        // Tracks the wrapped session's own inner `generationId` (bumped by it on
        // every internal seek) so a change can be detected and translated into a
        // fresh public generation. Both vars are only ever touched from inside
        // onTimelineFrame, which — per AndroidDagTexturePlaybackControlSession's own
        // single-HandlerThread confinement — fires serialized on that one wrapped
        // session's dedicated thread, so plain (non-atomic) captured vars are safe.
        var lastInnerGeneration: Long? = null
        var sessionPublicGeneration = 0L

        val newSession = AndroidDagTexturePlaybackControlSession(
            videoPath = spec.sourcePath,
            surfaceProducer = surfaceProducer,
            onTimelineFrame = { textureId, localPtsSeconds, innerGenerationId ->
                if (sessionToken.get() == mySessionToken) {
                    if (lastInnerGeneration != innerGenerationId) {
                        lastInnerGeneration = innerGenerationId
                        sessionPublicGeneration = publicGeneration.incrementAndGet()
                    }
                    val sourcePtsUs = Math.round(localPtsSeconds * 1_000_000.0)
                    val globalPtsUs = sourceToGlobalPtsClamped(sourcePtsUs, spec)
                    onTimelineFrame(textureId, globalPtsUs / 1_000_000.0, sessionPublicGeneration)
                }
            },
            onTimelineEOS = { _ ->
                orchHandler?.post {
                    if (sessionToken.get() == mySessionToken && !disposed.get()) {
                        handleClipEOS(index)
                    }
                }
            },
            playbackEndPtsUs = spec.sourceTrimEndUs,
        )

        activeSession = newSession
        activeClipIndex = index

        val prepareLatch = CountDownLatch(1)
        var prepareResult: Map<String, Any?> = emptyMap()
        newSession.prepare { r ->
            prepareResult = r
            prepareLatch.countDown()
        }
        prepareLatch.await()

        val preparePass = prepareResult["pass"] as? Boolean ?: false
        if (!preparePass) {
            return prepareResult
        }

        val seekTargetUs = explicitSourceSeekUs ?: if (spec.sourceTrimStartUs > 0L) spec.sourceTrimStartUs else null
        if (seekTargetUs == null) {
            // Already at (and this clip's trim start is) source PTS 0 — no explicit seek
            // needed, since a freshly prepared session starts decoding from the beginning
            // of the file. Still honor a requested resume-after-activation.
            if (resumeAfterSeek) {
                newSession.play(null) { /* continuous playback; callbacks drive state */ }
            }
            return prepareResult
        }

        val seekLatch = CountDownLatch(1)
        var seekResult: Map<String, Any?> = emptyMap()
        newSession.seek(seekTargetUs, resumeAfterSeek) { r ->
            seekResult = r
            seekLatch.countDown()
        }
        seekLatch.await()
        // seekResult lacks the prepared textureId/width/height/durationUs (seek's map only
        // carries seek-specific fields); merge so callers still see prepared metadata alongside
        // the post-seek state/raw/generationId, which take priority via the right-hand overlay.
        return prepareResult + seekResult
    }

    /** Must be called from [orchHandler]. Handles non-final vs. final clip EOS. */
    private fun handleClipEOS(finishedIndex: Int) {
        if (disposed.get()) return

        if (finishedIndex >= clipSpecs.size - 1) {
            // Final clip EOS: preserve the completed session (holds last frame),
            // matching the single-clip route's Completed-state behavior.
            isPlaying = false
            onTimelineEOS(surfaceProducer.id())
            return
        }

        val wasPlaying = isPlaying
        val activateResult = activateClipBlocking(finishedIndex + 1, explicitSourceSeekUs = null, resumeAfterSeek = false)
        val pass = activateResult["pass"] as? Boolean ?: false
        if (!pass) {
            isPlaying = false
            Log.w(TAG, "handleClipEOS: activation of clip ${finishedIndex + 1} failed: $activateResult")
            return
        }
        if (wasPlaying) {
            activeSession?.play(null) { /* continuous playback; onTimelineFrame/onTimelineEOS drive state */ }
        }
    }

    // ── dispose ────────────────────────────────────────────────────────────

    /**
     * Disposes the active wrapped session (if any) and this session's own
     * orchestration [HandlerThread]. Idempotent. Never releases
     * [surfaceProducer] — the coordinator owns that.
     */
    fun dispose(onResult: ((Map<String, Any?>) -> Unit)? = null) {
        if (!disposed.compareAndSet(false, true)) {
            onResult?.invoke(mapOf("pass" to true, "raw" to "status=OK;already_disposed"))
            return
        }
        sessionToken.incrementAndGet()

        val h = orchHandler
        if (h == null) {
            onResult?.invoke(mapOf("pass" to true, "raw" to "status=OK;disposed=true"))
            return
        }

        h.post {
            val session = activeSession
            activeSession = null
            val finish: () -> Unit = {
                onResult?.invoke(mapOf("pass" to true, "raw" to "status=OK;disposed=true"))
                try { orchThread?.quitSafely() } catch (_: Throwable) {}
                orchThread = null
                orchHandler = null
            }
            if (session != null) {
                session.dispose { finish() }
            } else {
                finish()
            }
        }
    }
}
