package com.connects.vanguard_media_engine.export

import android.content.Context
import android.os.Handler
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

// ── AndroidEditorExportCoordinator (Export Unit C) ────────────────────────────
//
// Thin owner of the production `exportTimeline` MethodChannel route only.
// Does NOT own `cancelExport` -- the plugin tries this coordinator's
// [cancelActiveExport] first and falls back to the legacy `activeEncoder`
// cancel path when there is no active Unit C export (see
// VanguardMediaEnginePlugin.onMethodCall "cancelExport").
//
// One export at a time: a second concurrent `exportTimeline` call is rejected
// with EXPORT_IN_PROGRESS rather than silently queued or run in parallel.
//
// Every [MethodChannel.Result] reply happens exactly once, posted to
// [mainHandler], guarded by a per-call [AtomicBoolean] -- the underlying
// [AndroidTimelineExportSession] runs on a background thread and its
// onSuccess/onError callbacks may race with coordinator-driven cancellation.
class AndroidEditorExportCoordinator(
    private val context: Context,
    private val channel: MethodChannel,
    private val mainHandler: Handler,
) {
    @Volatile private var activeSession: AndroidTimelineExportSession? = null

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
            if (activeSession != null) {
                replyError("EXPORT_IN_PROGRESS", "exportTimeline: an export is already in progress")
                return
            }
            val session = AndroidTimelineExportSession(context)
            activeSession = session
            session.start(
                args = args,
                onSuccess = { map ->
                    synchronized(this) {
                        if (activeSession === session) activeSession = null
                    }
                    replySuccess(map)
                },
                onError = { code, message ->
                    synchronized(this) {
                        if (activeSession === session) activeSession = null
                    }
                    replyError(code, message)
                },
            )
        }
    }

    /// Requests cancellation of the active export, if any. Non-blocking --
    /// the underlying session stops between/inside clip decode loops and
    /// resolves its own pending [exportTimeline] result as EXPORT_CANCELLED.
    /// Returns true only if there was an active session to cancel.
    fun cancelActiveExport(): Boolean {
        val session = activeSession ?: return false
        session.requestCancel()
        return true
    }

    /// Cancels any active export and drops all references. Called from
    /// onDetachedFromEngine -- never touches [channel] after this point.
    fun disposeAll() {
        activeSession?.requestCancel()
        activeSession = null
    }
}
