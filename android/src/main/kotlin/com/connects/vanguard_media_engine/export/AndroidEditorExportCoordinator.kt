package com.connects.vanguard_media_engine.export

import android.content.Context
import android.os.Handler
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

// -- AndroidEditorExportCoordinator (Export Unit C, extended by Phase 2-Unit AD,
// Phase 5-Unit T) -
//
// Thin owner of the production `exportTimeline` and `exportPassthroughRemux`
// MethodChannel routes. Does NOT own `cancelExport` -- the plugin tries this
// coordinator's [cancelActiveExport] first and falls back to the legacy
// `activeEncoder` cancel path when there is no active coordinator-owned
// export (see VanguardMediaEnginePlugin.onMethodCall "cancelExport").
//
// One export at a time across ALL THREE routes: a second concurrent
// `exportTimeline`, `exportPassthroughRemux`, or `normalizeVideo` call while
// any of [AndroidTimelineExportSession], [AndroidPassthroughRemuxSession], or
// [AndroidNormalizeVideoSession] is active is rejected with EXPORT_IN_PROGRESS
// rather than silently queued or run in parallel.
//
// Every [MethodChannel.Result] reply happens exactly once, posted to
// [mainHandler], guarded by a per-call [AtomicBoolean] -- the underlying
// sessions run on a background thread and their onSuccess/onError callbacks
// may race with coordinator-driven cancellation.
//
// Progress telemetry (Phase 5-Unit T): this coordinator is the sole owner of
// `onExportProgress` MethodChannel emission, terminal 1.0, throttling, and
// lifecycle gating for the `exportTimeline` route. [AndroidTimelineExportSession]
// only ever reports [0.0, 0.98] progress; this class clamps, throttles, and
// appends the terminal 1.0 immediately before the success result, but only
// when the success callback wins the progress gate (i.e. cancel/dispose has
// not already closed it) -- otherwise the success result is still delivered,
// just without a terminal 1.0. A per-export
// [AtomicBoolean] progress gate is closed on cancel/error/success/dispose so
// that no stale progress can be posted once the export's outcome is settled,
// and every posted runnable re-checks both the gate (for progress) and
// [detached] (for any callback) as its first statement, so a race with
// [disposeAll] can never emit a channel callback after detach.
class AndroidEditorExportCoordinator(
    private val context: Context,
    private val channel: MethodChannel,
    private val mainHandler: Handler,
) {
    @Volatile private var activeTimelineSession: AndroidTimelineExportSession? = null
    @Volatile private var activePassthroughSession: AndroidPassthroughRemuxSession? = null
    @Volatile private var activeNormalizeSession: AndroidNormalizeVideoSession? = null
    @Volatile private var activeTimelineProgressGate: AtomicBoolean? = null
    @Volatile private var detached = false

    private fun isAnyExportActive(): Boolean =
        activeTimelineSession != null || activePassthroughSession != null || activeNormalizeSession != null

    /// Handles the `exportTimeline` MethodChannel call. Also owns
    /// `onExportProgress` emission for the lifetime of the export -- see the
    /// class doc comment for the gating/throttling contract.
    fun exportTimeline(args: Map<*, *>?, result: MethodChannel.Result) {
        val repliedOnce = AtomicBoolean(false)

        fun replySuccess(map: Map<String, Any?>, emitTerminalProgress: Boolean = false) {
            if (repliedOnce.compareAndSet(false, true)) {
                mainHandler.post {
                    if (detached) return@post
                    if (emitTerminalProgress) channel.invokeMethod("onExportProgress", 1.0)
                    result.success(map)
                }
            }
        }

        fun replyError(code: String, message: String?) {
            if (repliedOnce.compareAndSet(false, true)) {
                mainHandler.post {
                    if (detached) return@post
                    result.error(code, message, null)
                }
            }
        }

        // Per-export progress gate + throttle state. The throttle vars are
        // touched only from the session's single background thread (the
        // session runs one clip/pass at a time, sequentially), so they need
        // no synchronization of their own; the gate is an AtomicBoolean
        // because cancelActiveExport()/disposeAll() close it from the main
        // thread while the session thread is concurrently posting progress.
        val progressOpen = AtomicBoolean(true)
        var lastPostedProgress = -1.0
        var lastPostTimeMs = 0L

        fun postProgress(rawPct: Double) {
            if (!progressOpen.get()) return
            val isCheckpoint = rawPct == PASS1_CHECKPOINT || rawPct == PASS2_CHECKPOINT
            val clamped = rawPct.coerceIn(0.0, 0.99)
            if (clamped <= lastPostedProgress) return
            val now = SystemClock.elapsedRealtime()
            if (!isCheckpoint && now - lastPostTimeMs < PROGRESS_THROTTLE_MS) return
            lastPostedProgress = clamped
            lastPostTimeMs = now
            if (!progressOpen.get()) return
            mainHandler.post {
                if (!progressOpen.get()) return@post
                if (detached) return@post
                channel.invokeMethod("onExportProgress", clamped)
            }
        }

        synchronized(this) {
            if (isAnyExportActive()) {
                replyError("EXPORT_IN_PROGRESS", "exportTimeline: an export is already in progress")
                return
            }
            val session = AndroidTimelineExportSession(context)
            activeTimelineSession = session
            activeTimelineProgressGate = progressOpen
            session.start(
                args = args,
                onProgress = { pct -> postProgress(pct) },
                onSuccess = { map ->
                    val emitTerminalProgress = progressOpen.compareAndSet(true, false)
                    synchronized(this) {
                        if (activeTimelineSession === session) {
                            activeTimelineSession = null
                            activeTimelineProgressGate = null
                        }
                    }
                    replySuccess(map, emitTerminalProgress)
                },
                onError = { code, message ->
                    progressOpen.set(false)
                    synchronized(this) {
                        if (activeTimelineSession === session) {
                            activeTimelineSession = null
                            activeTimelineProgressGate = null
                        }
                    }
                    replyError(code, message)
                },
            )
        }
    }

    /// Handles the `exportPassthroughRemux` MethodChannel call (Phase 2-Unit AD).
    /// Shares this coordinator's single-export lock with [exportTimeline].
    /// No progress events -- this route remains no-progress by design.
    fun exportPassthroughRemux(args: Map<*, *>?, result: MethodChannel.Result) {
        val repliedOnce = AtomicBoolean(false)

        fun replySuccess(map: Map<String, Any?>) {
            if (repliedOnce.compareAndSet(false, true)) {
                mainHandler.post {
                    if (detached) return@post
                    result.success(map)
                }
            }
        }

        fun replyError(code: String, message: String?) {
            if (repliedOnce.compareAndSet(false, true)) {
                mainHandler.post {
                    if (detached) return@post
                    result.error(code, message, null)
                }
            }
        }

        synchronized(this) {
            if (isAnyExportActive()) {
                replyError("EXPORT_IN_PROGRESS", "exportPassthroughRemux: an export is already in progress")
                return
            }
            val session = AndroidPassthroughRemuxSession(context)
            activePassthroughSession = session
            session.start(
                args = args,
                onSuccess = { map ->
                    synchronized(this) {
                        if (activePassthroughSession === session) activePassthroughSession = null
                    }
                    replySuccess(map)
                },
                onError = { code, message ->
                    synchronized(this) {
                        if (activePassthroughSession === session) activePassthroughSession = null
                    }
                    replyError(code, message)
                },
            )
        }
    }

    /// Handles the `normalizeVideo` MethodChannel call (Phase 5-Unit AA /
    /// Phase 2-Unit AI). Shares this coordinator's single-export lock with
    /// [exportTimeline] and [exportPassthroughRemux]. No progress events.
    fun normalizeVideo(args: Map<*, *>?, result: MethodChannel.Result) {
        val repliedOnce = AtomicBoolean(false)

        fun replySuccess(map: Map<String, Any?>) {
            if (repliedOnce.compareAndSet(false, true)) {
                mainHandler.post {
                    if (detached) return@post
                    result.success(map)
                }
            }
        }

        fun replyError(code: String, message: String?) {
            if (repliedOnce.compareAndSet(false, true)) {
                mainHandler.post {
                    if (detached) return@post
                    result.error(code, message, null)
                }
            }
        }

        synchronized(this) {
            if (isAnyExportActive()) {
                replyError("EXPORT_IN_PROGRESS", "normalizeVideo: an export is already in progress")
                return
            }
            val session = AndroidNormalizeVideoSession(context)
            activeNormalizeSession = session
            session.start(
                args = args,
                onSuccess = { map ->
                    synchronized(this) {
                        if (activeNormalizeSession === session) activeNormalizeSession = null
                    }
                    replySuccess(map)
                },
                onError = { code, message ->
                    synchronized(this) {
                        if (activeNormalizeSession === session) activeNormalizeSession = null
                    }
                    replyError(code, message)
                },
            )
        }
    }

    /// Requests cancellation of the active export (either route), if any.
    /// Non-blocking -- the underlying session resolves its own pending result
    /// as EXPORT_CANCELLED. Returns true only if there was an active session
    /// to cancel. Closes the timeline progress gate immediately so no further
    /// progress is posted, but deliberately does NOT clear
    /// [activeTimelineSession] -- the export lock is held until the session's
    /// terminal onError/onSuccess callback clears it.
    fun cancelActiveExport(): Boolean {
        synchronized(this) {
            val timeline = activeTimelineSession
            val passthrough = activePassthroughSession
            val normalize = activeNormalizeSession
            if (timeline == null && passthrough == null && normalize == null) return false
            activeTimelineProgressGate?.set(false)
            timeline?.requestCancel()
            passthrough?.requestCancel()
            normalize?.requestCancel()
            return true
        }
    }

    /// Cancels any active export and drops all references. Called from
    /// onDetachedFromEngine -- never touches [channel] after this point.
    /// Closes the progress gate and marks [detached] before nulling refs and
    /// requesting cancel, so every already-posted or in-flight runnable's
    /// gate/detach check suppresses its channel call.
    fun disposeAll() {
        synchronized(this) {
            detached = true
            activeTimelineProgressGate?.set(false)
            val timeline = activeTimelineSession
            val passthrough = activePassthroughSession
            val normalize = activeNormalizeSession
            activeTimelineSession = null
            activePassthroughSession = null
            activeNormalizeSession = null
            activeTimelineProgressGate = null
            timeline?.requestCancel()
            passthrough?.requestCancel()
            normalize?.requestCancel()
        }
    }

    companion object {
        private const val PROGRESS_THROTTLE_MS = 100L
        private const val PASS1_CHECKPOINT = 0.85
        private const val PASS2_CHECKPOINT = 0.98
    }
}
