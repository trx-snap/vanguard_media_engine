package com.connects.vanguard_media_engine.export

import android.content.Context
import android.os.Handler
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

// -- AndroidEditorExportCoordinator (Export Unit C, extended by Phase 2-Unit AD) -
//
// Thin owner of the production `exportTimeline` and `exportPassthroughRemux`
// MethodChannel routes. Does NOT own `cancelExport` -- the plugin tries this
// coordinator's [cancelActiveExport] first and falls back to the legacy
// `activeEncoder` cancel path when there is no active coordinator-owned
// export (see VanguardMediaEnginePlugin.onMethodCall "cancelExport").
//
// One export at a time across BOTH routes: a second concurrent `exportTimeline`
// or `exportPassthroughRemux` call while either an [AndroidTimelineExportSession]
// or an [AndroidPassthroughRemuxSession] is active is rejected with
// EXPORT_IN_PROGRESS rather than silently queued or run in parallel.
//
// Every [MethodChannel.Result] reply happens exactly once, posted to
// [mainHandler], guarded by a per-call [AtomicBoolean] -- the underlying
// sessions run on a background thread and their onSuccess/onError callbacks
// may race with coordinator-driven cancellation.
class AndroidEditorExportCoordinator(
    private val context: Context,
    private val channel: MethodChannel,
    private val mainHandler: Handler,
) {
    @Volatile private var activeTimelineSession: AndroidTimelineExportSession? = null
    @Volatile private var activePassthroughSession: AndroidPassthroughRemuxSession? = null

    private fun isAnyExportActive(): Boolean =
        activeTimelineSession != null || activePassthroughSession != null

    /// Handles the `exportTimeline` MethodChannel call. The [channel] field is
    /// retained only for parity with sibling coordinators' constructor shape --
    /// this coordinator never calls it (no progress events in Unit C).
    fun exportTimeline(args: Map<*, *>?, result: MethodChannel.Result) {
        val repliedOnce = AtomicBoolean(false)

        fun replySuccess(map: Map<String, Any?>) {
            if (repliedOnce.compareAndSet(false, true)) {
                mainHandler.post { result.success(map) }
            }
        }

        fun replyError(code: String, message: String?) {
            if (repliedOnce.compareAndSet(false, true)) {
                mainHandler.post { result.error(code, message, null) }
            }
        }

        synchronized(this) {
            if (isAnyExportActive()) {
                replyError("EXPORT_IN_PROGRESS", "exportTimeline: an export is already in progress")
                return
            }
            val session = AndroidTimelineExportSession(context)
            activeTimelineSession = session
            session.start(
                args = args,
                onSuccess = { map ->
                    synchronized(this) {
                        if (activeTimelineSession === session) activeTimelineSession = null
                    }
                    replySuccess(map)
                },
                onError = { code, message ->
                    synchronized(this) {
                        if (activeTimelineSession === session) activeTimelineSession = null
                    }
                    replyError(code, message)
                },
            )
        }
    }

    /// Handles the `exportPassthroughRemux` MethodChannel call (Phase 2-Unit AD).
    /// Shares this coordinator's single-export lock with [exportTimeline].
    fun exportPassthroughRemux(args: Map<*, *>?, result: MethodChannel.Result) {
        val repliedOnce = AtomicBoolean(false)

        fun replySuccess(map: Map<String, Any?>) {
            if (repliedOnce.compareAndSet(false, true)) {
                mainHandler.post { result.success(map) }
            }
        }

        fun replyError(code: String, message: String?) {
            if (repliedOnce.compareAndSet(false, true)) {
                mainHandler.post { result.error(code, message, null) }
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

    /// Requests cancellation of the active export (either route), if any.
    /// Non-blocking -- the underlying session resolves its own pending result
    /// as EXPORT_CANCELLED. Returns true only if there was an active session
    /// to cancel.
    fun cancelActiveExport(): Boolean {
        val timeline = activeTimelineSession
        val passthrough = activePassthroughSession
        if (timeline == null && passthrough == null) return false
        timeline?.requestCancel()
        passthrough?.requestCancel()
        return true
    }

    /// Cancels any active export and drops all references. Called from
    /// onDetachedFromEngine -- never touches [channel] after this point.
    fun disposeAll() {
        activeTimelineSession?.requestCancel()
        activePassthroughSession?.requestCancel()
        activeTimelineSession = null
        activePassthroughSession = null
    }
}
