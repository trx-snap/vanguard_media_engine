package com.connects.vanguard_media_engine.audio_extraction

import android.content.Context
import android.os.Handler
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

// ── AndroidAudioExtractionCoordinator (Phase 5-Unit V / Phase 4-Unit D) ───────
//
// Owns the production `beginAudioExtraction` / `cancelAudioExtraction`
// MethodChannel routes, mirroring VanguardAudioExtractionHandler.swift:
//
//   - A private lock guards all registry mutations.
//   - A registry of active AndroidAudioExtractionSession instances keyed by
//     operationId. Concurrency: any number of distinct operationIds may run
//     at once; a duplicate active operationId is rejected with
//     operationAlreadyExists rather than queued or run twice.
//   - A bounded recent-terminal FIFO (cap 256) distinguishes alreadyTerminal
//     from notFound on cancel.
//   - cancellationCompleted is returned ONLY from the session's terminal
//     completion callback, after native quiescence -- requestCancel() itself
//     never resolves a cancel reply.
//
// Every MethodChannel.Result is wrapped by [GuardedReply]: an AtomicBoolean
// compareAndSet ensures at most one reply per call, posted through
// [mainHandler], and every posted runnable checks [detached] first so no
// channel call happens after onDetachedFromEngine.
class AndroidAudioExtractionCoordinator(
    @Suppress("UNUSED_PARAMETER") context: Context,
    private val mainHandler: Handler,
    private val sessionFactory: (
        operationId: String,
        sourcePath: String,
        outputPath: String,
        trimStartSeconds: Double?,
        trimEndSeconds: Double?,
    ) -> AndroidAudioExtractionSession = { operationId, sourcePath, outputPath, trimStartSeconds, trimEndSeconds ->
        AndroidAudioExtractionSession(operationId, sourcePath, outputPath, trimStartSeconds, trimEndSeconds)
    },
) {
    companion object {
        private val OWNED_METHODS = setOf("beginAudioExtraction", "cancelAudioExtraction")

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    /** AtomicBoolean-guarded, detach-aware [MethodChannel.Result] wrapper. */
    private inner class GuardedReply(private val result: MethodChannel.Result) {
        private val fired = AtomicBoolean(false)

        fun success(map: Map<String, Any?>) {
            if (fired.compareAndSet(false, true)) {
                mainHandler.post {
                    if (detached) return@post
                    result.success(map)
                }
            }
        }

        fun error(code: String, message: String?) {
            if (fired.compareAndSet(false, true)) {
                mainHandler.post {
                    if (detached) return@post
                    result.error(code, message, null)
                }
            }
        }
    }

    private class Entry(
        val session: AndroidAudioExtractionSession,
        val beginReply: GuardedReply,
    ) {
        val pendingCancels = mutableListOf<GuardedReply>()
        var terminalFired = false
    }

    private val lock = Any()
    private val registry = mutableMapOf<String, Entry>()
    private val recentTerminals = ArrayDeque<String>()
    private val terminalCap = 256

    @Volatile private var detached = false

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        when (method) {
            "beginAudioExtraction" -> handleBegin(args, result)
            "cancelAudioExtraction" -> handleCancel(args, result)
        }
    }

    // ── beginAudioExtraction ────────────────────────────────────────────────

    private fun handleBegin(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)

        val operationId = (args?.get("operationId") as? String)?.takeIf { it.isNotBlank() }
        if (operationId == null) {
            reply.error("invalidArgument", "operationId is required and must be non-empty")
            return
        }
        val sourcePath = (args.get("sourcePath") as? String)?.takeIf { it.isNotBlank() }
        if (sourcePath == null) {
            reply.error("invalidArgument", "sourcePath is required and must be non-empty")
            return
        }
        val outputPath = (args.get("outputPath") as? String)?.takeIf { it.isNotBlank() }
        if (outputPath == null) {
            reply.error("invalidArgument", "outputPath is required and must be non-empty")
            return
        }

        val trimStart = (args.get("trimStartSeconds") as? Number)?.toDouble()
        val trimEnd = (args.get("trimEndSeconds") as? Number)?.toDouble()

        if (trimStart != null) {
            if (!trimStart.isFinite()) {
                reply.error("invalidArgument", "trimStartSeconds must be a finite number")
                return
            }
            if (trimStart < 0.0) {
                reply.error("invalidArgument", "trimStartSeconds must be >= 0")
                return
            }
        }
        if (trimEnd != null) {
            if (!trimEnd.isFinite()) {
                reply.error("invalidArgument", "trimEndSeconds must be a finite number")
                return
            }
            if (trimEnd <= 0.0) {
                reply.error("invalidArgument", "trimEndSeconds must be > 0")
                return
            }
            val effectiveStart = trimStart ?: 0.0
            if (trimEnd <= effectiveStart) {
                reply.error("invalidArgument", "trimEndSeconds must be > trimStartSeconds")
                return
            }
        }

        var session: AndroidAudioExtractionSession? = null
        synchronized(lock) {
            if (registry.containsKey(operationId)) {
                reply.error(
                    "operationAlreadyExists",
                    "An active operation with id '$operationId' already exists")
                return
            }
            val created = try {
                sessionFactory(operationId, sourcePath, outputPath, trimStart, trimEnd)
            } catch (t: Throwable) {
                reply.error("internalFailure", t.message ?: t.javaClass.simpleName)
                return
            }
            registry[operationId] = Entry(session = created, beginReply = reply)
            session = created
        }

        try {
            session?.start { sessionResult -> handleTerminal(operationId, sessionResult) }
        } catch (t: Throwable) {
            // The entry was already inserted -- route through the normal terminal path so
            // the registry entry is removed and any racing pendingCancels are flushed.
            handleTerminal(
                operationId,
                AndroidAudioExtractionResult.Failure(
                    "internalFailure", t.message ?: t.javaClass.simpleName))
        }
    }

    // ── cancelAudioExtraction ───────────────────────────────────────────────

    private fun handleCancel(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)

        val operationId = (args?.get("operationId") as? String)?.takeIf { it.isNotBlank() }
        if (operationId == null) {
            reply.error("invalidArgument", "operationId is required and must be non-empty")
            return
        }

        var sessionToCancel: AndroidAudioExtractionSession? = null
        var immediateDisposition: String? = null

        synchronized(lock) {
            val entry = registry[operationId]
            when {
                entry != null && entry.session.isFinished -> {
                    // Terminal completion hasn't run its own handling yet (it's still
                    // racing for this lock) -- treat as alreadyTerminal so we don't
                    // queue a waiter that will never be flushed.
                    immediateDisposition = "alreadyTerminal"
                }
                entry != null -> {
                    entry.pendingCancels.add(reply)
                    sessionToCancel = entry.session
                }
                recentTerminals.contains(operationId) -> immediateDisposition = "alreadyTerminal"
                else -> immediateDisposition = "notFound"
            }
        }

        val disposition = immediateDisposition
        if (disposition != null) {
            reply.success(mapOf("disposition" to disposition))
            return
        }

        // Outside the lock: requestCancel() only sets a flag and returns quickly.
        sessionToCancel?.requestCancel()
    }

    // ── Terminal completion (called from a session's background thread) ────

    private fun handleTerminal(operationId: String, sessionResult: AndroidAudioExtractionResult) {
        var beginReply: GuardedReply? = null
        var pendingCancels: List<GuardedReply> = emptyList()

        synchronized(lock) {
            val entry = registry[operationId] ?: return
            if (entry.terminalFired) return
            entry.terminalFired = true
            beginReply = entry.beginReply
            pendingCancels = entry.pendingCancels.toList()
            registry.remove(operationId)
            recordTerminal(operationId)
        }

        val resolvedBeginReply = beginReply ?: return

        for (cancelReply in pendingCancels) {
            cancelReply.success(mapOf("disposition" to "cancellationCompleted"))
        }

        when (sessionResult) {
            is AndroidAudioExtractionResult.Success ->
                resolvedBeginReply.success(mapOf("outputPath" to sessionResult.outputPath))
            is AndroidAudioExtractionResult.Failure ->
                resolvedBeginReply.error(sessionResult.code, sessionResult.message)
        }
    }

    private fun recordTerminal(operationId: String) {
        if (recentTerminals.size >= terminalCap) {
            recentTerminals.removeFirst()
        }
        recentTerminals.addLast(operationId)
    }

    // ── Disposal ─────────────────────────────────────────────────────────────

    /// Idempotently detaches, cancels every active session, and clears all
    /// state. Non-blocking -- never awaits session termination and never
    /// posts a reply after [detached] is set.
    fun disposeAll() {
        val sessions: List<AndroidAudioExtractionSession>
        synchronized(lock) {
            detached = true
            sessions = registry.values.map { it.session }
            registry.clear()
            recentTerminals.clear()
        }
        sessions.forEach { session ->
            try { session.requestCancel() } catch (_: Throwable) {}
        }
    }
}
