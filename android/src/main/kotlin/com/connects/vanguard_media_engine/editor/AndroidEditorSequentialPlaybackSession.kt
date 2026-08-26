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
 * Phase 7.8G-Android: sequential multi-clip editor playback session.
 *
 * Wraps exactly one active [AndroidDagTexturePlaybackControlSession] at a time
 * — one per plain local video clip in [clipSourcePaths] — reusing the same
 * [surfaceProducer] across clip switches, and maps clip-local decoder PTS onto
 * a single global timeline PTS (`globalPts = clipStartOffsetSeconds + localPts`).
 *
 * Clip layout is a plain concatenation of each clip's own full source
 * duration (no transitions, no trim window — matches the existing
 * single-clip route's parity, which likewise ignores trim). Cross-clip
 * transitions/overlays/audio-sidecar/transform features are rejected by
 * [AndroidEditorPlaybackCoordinator] before this session is constructed.
 *
 * Ownership: [AndroidEditorPlaybackCoordinator] owns this session and the
 * [surfaceProducer]. This session never releases the [surfaceProducer] —
 * only the [AndroidDagTexturePlaybackControlSession] it wraps is disposed
 * and recreated on clip switches / disposal.
 *
 * Concurrency: all orchestration (prepare / play / pause / seek / clip-switch
 * on EOS / dispose) is serialized on a single dedicated [HandlerThread] owned
 * by this session (`orchHandler`). Clip activation
 * ([activateClipBlocking]) blocks that thread until the wrapped session's
 * asynchronous prepare/seek callback fires (via [CountDownLatch]), so no two
 * activations — and no command racing an in-flight activation — can ever
 * observe or mutate [activeSession] / [activeClipIndex] concurrently. This
 * mirrors [AndroidDagTexturePlaybackControlSession]'s own single-HandlerThread
 * confinement, bridged across the extra thread hop that wrapping introduces.
 */
class AndroidEditorSequentialPlaybackSession(
    private val clipSourcePaths: List<String>,
    private val surfaceProducer: TextureRegistry.SurfaceProducer,
    private val onTimelineFrame: (textureId: Long, ptsSeconds: Double, generationId: Long) -> Unit,
    private val onTimelineEOS: (textureId: Long) -> Unit,
) {
    companion object {
        private const val TAG = "EditorSeqPlaybackSession"
    }

    private data class ClipEntry(
        val sourcePath: String,
        val startOffsetUs: Long,
        val durationUs: Long,
    )

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

    private var clipEntries: List<ClipEntry> = emptyList()
    private var totalDurationUs: Long = 0L
    private var activeClipIndex: Int = -1
    private var activeSession: AndroidDagTexturePlaybackControlSession? = null
    private var isPlaying: Boolean = false

    // ── prepare ────────────────────────────────────────────────────────────

    /**
     * Inspects every clip (metadata only) to compute the cumulative timeline
     * layout, then activates clip 0. [onResult] receives `{pass, textureId,
     * width, height, durationUs, raw}` on success, matching the shape
     * [AndroidEditorPlaybackCoordinator] already expects from a single-clip
     * [AndroidDagTexturePlaybackControlSession.prepare].
     */
    fun prepare(onResult: (Map<String, Any?>) -> Unit) {
        if (clipSourcePaths.isEmpty()) {
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

            val entries = mutableListOf<ClipEntry>()
            var cursorUs = 0L
            for (path in clipSourcePaths) {
                val inspection = AndroidDagSourceInspector().inspect(path)
                try {
                    if (!inspection.pass) {
                        dispose(null)
                        onResult(mapOf(
                            "pass" to false,
                            "raw" to "status=FAIL;reason=clip_inspect_failed;path=$path;detail=${inspection.failureReason}",
                        ))
                        return@post
                    }
                    entries.add(ClipEntry(path, cursorUs, inspection.durationUs))
                    cursorUs += inspection.durationUs
                } finally {
                    // Metadata-only probe: release immediately. The active clip's own
                    // AndroidDagTexturePlaybackControlSession performs its own independent
                    // inspect + decode configure when it becomes active.
                    try { inspection.extractor?.release() } catch (_: Throwable) {}
                }
            }

            clipEntries = entries
            totalDurationUs = cursorUs

            val activateResult = activateClipBlocking(0, seekLocalUs = null, resumeAfterSeek = false)
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
                "raw" to "status=OK;clipCount=${entries.size};totalDurationUs=$totalDurationUs",
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
     * Maps [targetGlobalPtsUs] (global timeline microseconds) to a target
     * clip + clip-local PTS. An intra-clip seek delegates directly to the
     * active [AndroidDagTexturePlaybackControlSession]; a cross-clip seek
     * switches the active session first (via [activateClipBlocking]) and then
     * seeks the freshly-activated session to the local target.
     */
    fun seek(targetGlobalPtsUs: Long, resumeAfterSeek: Boolean, onResult: (Map<String, Any?>) -> Unit) {
        val h = orchHandler
        if (h == null || disposed.get()) {
            onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=session_disposed_or_uninitialized"))
            return
        }
        h.post {
            if (disposed.get() || clipEntries.isEmpty()) {
                onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=session_disposed_or_uninitialized"))
                return@post
            }

            val clampedUs = targetGlobalPtsUs.coerceIn(0L, (totalDurationUs - 1L).coerceAtLeast(0L))
            val targetIndex = resolveClipIndex(clampedUs)
            val targetEntry = clipEntries[targetIndex]
            val localTargetUs = clampedUs - targetEntry.startOffsetUs
            isPlaying = resumeAfterSeek

            val activeNow = activeSession
            if (targetIndex == activeClipIndex && activeNow != null) {
                activeNow.seek(localTargetUs, resumeAfterSeek) { seekResult ->
                    onResult(translateSeekResult(seekResult, targetEntry))
                }
            } else {
                val activateResult = activateClipBlocking(
                    targetIndex,
                    seekLocalUs = localTargetUs,
                    resumeAfterSeek = resumeAfterSeek,
                )
                onResult(translateSeekResult(activateResult, targetEntry))
            }
        }
    }

    private fun resolveClipIndex(globalPtsUs: Long): Int {
        var idx = 0
        for (i in clipEntries.indices) {
            if (clipEntries[i].startOffsetUs <= globalPtsUs) idx = i else break
        }
        return idx
    }

    private fun translateSeekResult(result: Map<String, Any?>, entry: ClipEntry): Map<String, Any?> {
        val out = result.toMutableMap()
        (result["seekTargetUs"] as? Number)?.let { out["seekTargetUs"] = entry.startOffsetUs + it.toLong() }
        (result["seekRenderedPtsUs"] as? Number)?.let { out["seekRenderedPtsUs"] = entry.startOffsetUs + it.toLong() }
        return out
    }

    // ── clip activation (dispose old + create/prepare/seek new) ────────────

    /**
     * Must be called from [orchHandler]. Disposes any current [activeSession]
     * (waiting for its teardown to fully complete — in particular, releasing
     * its [TextureRegistry.SurfaceProducer.SurfaceCallback] registration —
     * before the replacement session touches the shared [surfaceProducer]),
     * then creates, prepares, and (optionally) seeks the session for
     * `clipEntries[index]`. Blocks the calling thread on each async step via
     * [CountDownLatch] so the whole activation is atomic from the perspective
     * of every other orchHandler-serialized command (no interleaved seek/play/
     * EOS-switch can observe a partially-activated state).
     */
    private fun activateClipBlocking(
        index: Int,
        seekLocalUs: Long?,
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
        if (index !in clipEntries.indices) {
            return mapOf("pass" to false, "raw" to "status=FAIL;reason=clip_index_out_of_range;index=$index")
        }

        val mySessionToken = sessionToken.incrementAndGet()
        val entry = clipEntries[index]
        val startOffsetSeconds = entry.startOffsetUs / 1_000_000.0

        // Tracks the wrapped session's own inner `generationId` (bumped by it on
        // every internal seek) so a change can be detected and translated into a
        // fresh public generation. Both vars are only ever touched from inside
        // onTimelineFrame, which — per AndroidDagTexturePlaybackControlSession's own
        // single-HandlerThread confinement — fires serialized on that one wrapped
        // session's dedicated thread, so plain (non-atomic) captured vars are safe.
        var lastInnerGeneration: Long? = null
        var sessionPublicGeneration = 0L

        val newSession = AndroidDagTexturePlaybackControlSession(
            videoPath = entry.sourcePath,
            surfaceProducer = surfaceProducer,
            onTimelineFrame = { textureId, localPtsSeconds, innerGenerationId ->
                if (sessionToken.get() == mySessionToken) {
                    if (lastInnerGeneration != innerGenerationId) {
                        lastInnerGeneration = innerGenerationId
                        sessionPublicGeneration = publicGeneration.incrementAndGet()
                    }
                    onTimelineFrame(textureId, startOffsetSeconds + localPtsSeconds, sessionPublicGeneration)
                }
            },
            onTimelineEOS = { _ ->
                orchHandler?.post {
                    if (sessionToken.get() == mySessionToken && !disposed.get()) {
                        handleClipEOS(index)
                    }
                }
            },
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
        if (seekLocalUs == null || seekLocalUs <= 0L) {
            // Already at (or targeting) local PTS 0 — no explicit seek needed, since
            // a freshly prepared session starts decoding from the beginning of the
            // file. Still honor a requested resume-after-activation.
            if (resumeAfterSeek) {
                newSession.play(null) { /* continuous playback; callbacks drive state */ }
            }
            return prepareResult
        }

        val seekLatch = CountDownLatch(1)
        var seekResult: Map<String, Any?> = emptyMap()
        newSession.seek(seekLocalUs, resumeAfterSeek) { r ->
            seekResult = r
            seekLatch.countDown()
        }
        seekLatch.await()
        return seekResult
    }

    /** Must be called from [orchHandler]. Handles non-final vs. final clip EOS. */
    private fun handleClipEOS(finishedIndex: Int) {
        if (disposed.get()) return

        if (finishedIndex >= clipEntries.size - 1) {
            // Final clip EOS: preserve the completed session (holds last frame),
            // matching the single-clip route's Completed-state behavior.
            isPlaying = false
            onTimelineEOS(surfaceProducer.id())
            return
        }

        val wasPlaying = isPlaying
        val activateResult = activateClipBlocking(finishedIndex + 1, seekLocalUs = null, resumeAfterSeek = false)
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
