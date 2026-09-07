package com.connects.vanguard_media_engine.codec

import android.content.Context
import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.util.AndroidUriDataSourceHelper
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

class AndroidDagTexturePlaybackCoordinator(
    private val textureRegistry: TextureRegistry,
    private val channel: MethodChannel,
    private val mainHandler: Handler,
    /**
     * Reference-import Slice 3A: optional application [Context] threaded into each
     * [AndroidDagTexturePlaybackControlSession] so a `content://` source path can be
     * opened through a ContentResolver. Null keeps POSIX-path behaviour unchanged and
     * makes any `content://` request fail closed at preflight.
     */
    private val context: Context? = null,
) {
    companion object {
        private const val TAG = "DagTextureCoordinator"

        private val OWNED_METHODS = setOf(
            "runAndroidDagPhase4B1TexturePlaybackSmoke",
            "disposeAndroidDagPhase4B1TexturePlaybackSmoke",
            "createAndroidDagPhase4B1BPlaybackControlSmoke",
            "playAndroidDagPhase4B1BPlaybackControlSmoke",
            "pauseAndroidDagPhase4B1BPlaybackControlSmoke",
            "seekAndroidDagPhase4B1BPlaybackControlSmoke",
            "disposeAndroidDagPhase4B1BPlaybackControlSmoke",
            "runAndroidDagPhase4B2AClockStateSmoke",
            "simulateAndroidDagPhase4B2B2SurfaceCleanup",
            "simulateAndroidDagPhase4B2B2SurfaceAvailable",
            "getAndroidDagPhase4B2B3SurfaceLifecycleStatus",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "runAndroidDagPhase4B1TexturePlaybackSmoke" -> runPhase4B1TexturePlaybackSmoke(args, result)
            "disposeAndroidDagPhase4B1TexturePlaybackSmoke" -> disposePhase4B1TexturePlaybackSmoke(args, result)
            "createAndroidDagPhase4B1BPlaybackControlSmoke" -> createPhase4B1BPlaybackControlSmoke(args, result)
            "playAndroidDagPhase4B1BPlaybackControlSmoke" -> playPhase4B1BPlaybackControlSmoke(args, result)
            "pauseAndroidDagPhase4B1BPlaybackControlSmoke" -> pausePhase4B1BPlaybackControlSmoke(args, result)
            "seekAndroidDagPhase4B1BPlaybackControlSmoke" -> seekPhase4B1BPlaybackControlSmoke(args, result)
            "disposeAndroidDagPhase4B1BPlaybackControlSmoke" -> disposePhase4B1BPlaybackControlSmoke(args, result)
            "runAndroidDagPhase4B2AClockStateSmoke" -> runPhase4B2AClockStateSmoke(args, result)
            "simulateAndroidDagPhase4B2B2SurfaceCleanup" -> simulatePhase4B2B2SurfaceCleanup(args, result)
            "simulateAndroidDagPhase4B2B2SurfaceAvailable" -> simulatePhase4B2B2SurfaceAvailable(args, result)
            "getAndroidDagPhase4B2B3SurfaceLifecycleStatus" -> getPhase4B2B3SurfaceLifecycleStatus(args, result)
            else -> return false
        }
        return true
    }

    private data class ActiveSmokeEntry(
        val session: AndroidDagTexturePlaybackSmokeSession,
        val textureEntry: TextureRegistry.SurfaceTextureEntry,
    )

    private data class ActiveControlEntry(
        val session: AndroidDagTexturePlaybackControlSession,
        val surfaceProducer: TextureRegistry.SurfaceProducer,
    )

    private val smokeSessions = mutableMapOf<Long, ActiveSmokeEntry>()
    private val controlSessions = mutableMapOf<Long, ActiveControlEntry>()

    // ── Phase 4B1A: Texture playback smoke ──────────────────────────────────

    fun runPhase4B1TexturePlaybackSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val path = args?.get("path") as? String
        val frameCount = (args?.get("frameCount") as? Number)?.toInt() ?: 12
        if (path == null) {
            result.error("INVALID_ARG", "runAndroidDagPhase4B1TexturePlaybackSmoke: path required", null)
            return
        }

        val textureEntry = textureRegistry.createSurfaceTexture()
        val textureId = textureEntry.id()

        val session = AndroidDagTexturePlaybackSmokeSession(
            videoPath = path,
            frameCount = frameCount,
            textureEntry = textureEntry,
        )

        val entry = ActiveSmokeEntry(session, textureEntry)
        synchronized(smokeSessions) {
            smokeSessions[textureId] = entry
        }

        Thread {
            var smokeResult: Map<String, Any?>
            try {
                smokeResult = session.run()
            } catch (t: Throwable) {
                Log.e(TAG, "Phase 4B1A session execution error", t)
                smokeResult = mapOf(
                    "pass" to false,
                    "textureId" to textureId,
                    "renderedFrames" to 0,
                    "frameCount" to frameCount,
                    "raw" to "status=FAIL;reason=exception:${t.javaClass.simpleName}",
                )
            }
            mainHandler.post {
                channel.invokeMethod("onAndroidDagPhase4B1TexturePlaybackSmokeComplete", smokeResult)
            }
        }.start()

        result.success(mapOf(
            "started" to true,
            "textureId" to textureId,
            "frameCount" to frameCount,
        ))
    }

    fun disposePhase4B1TexturePlaybackSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        val entry = synchronized(smokeSessions) {
            if (textureId != null) smokeSessions.remove(textureId) else null
        }
        if (entry != null) {
            try { entry.session.dispose() } catch (_: Throwable) {}
            try { entry.textureEntry.release() } catch (_: Throwable) {}
            result.success(mapOf(
                "pass" to true,
                "textureId" to textureId,
                "raw" to "status=OK;disposed=true",
            ))
        } else {
            result.success(mapOf(
                "pass" to false,
                "textureId" to textureId,
                "raw" to "status=FAIL;reason=session_not_found",
            ))
        }
    }

    // ── Phase 4B1B: Diagnostic playback control session ──────────────────────

    fun createPhase4B1BPlaybackControlSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val path = args?.get("path") as? String
        if (path == null) {
            result.error("INVALID_ARG", "createAndroidDagPhase4B1BPlaybackControlSmoke: path required", null)
            return
        }

        // Preflight: verify the source exists and can be read before allocating any
        // texture resources. MediaExtractor.setDataSource() can hang or throw
        // unpredictably on non-existent paths; this guard guarantees a prompt,
        // well-formed MethodChannel result for the missing-file case. POSIX paths
        // keep the File.exists()/canRead() check; content:// URIs are probed via
        // ContentResolver and fail closed (false, no hang) when context is null.
        if (!AndroidUriDataSourceHelper.isReadable(path, context)) {
            Log.w(TAG, "createPhase4B1BPlaybackControlSmoke: file not found or not readable: $path")
            result.success(mapOf(
                "pass" to false,
                "state" to AndroidDagPlaybackState.Failed.name,
                "raw" to "status=FAIL;reason=file_not_found_or_not_readable;path=$path",
            ))
            return
        }

        // Opt into real background surface reset callbacks (rather than the default
        // manual lifecycle) so this DAG control session can prove Home/Resume
        // recovery via genuine onSurfaceCleanup/onSurfaceAvailable callbacks.
        val surfaceProducer = textureRegistry.createSurfaceProducer(TextureRegistry.SurfaceLifecycle.resetInBackground)
        val textureId = surfaceProducer.id()

        val session = AndroidDagTexturePlaybackControlSession(
            videoPath = path,
            surfaceProducer = surfaceProducer,
            context = context,
        )

        val entry = ActiveControlEntry(session, surfaceProducer)
        synchronized(controlSessions) {
            controlSessions[textureId] = entry
        }

        session.prepare { prepResult ->
            mainHandler.post {
                val pass = prepResult["pass"] as? Boolean ?: false
                if (!pass) {
                    synchronized(controlSessions) {
                        controlSessions.remove(textureId)
                    }
                    try { surfaceProducer.release() } catch (_: Throwable) {}
                }
                val resultMap = prepResult.toMutableMap().apply {
                    putIfAbsent("textureId", textureId)
                }
                result.success(resultMap)
            }
        }
    }

    fun playPhase4B1BPlaybackControlSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "playAndroidDagPhase4B1BPlaybackControlSmoke: textureId required", null)
            return
        }
        val frameBudget = (args?.get("frameBudget") as? Number)?.toInt()
            ?: (args?.get("frameCount") as? Number)?.toInt()
            ?: 6

        val entry = synchronized(controlSessions) { controlSessions[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to false,
                "state" to "Failed",
                "textureId" to textureId,
                "raw" to "status=FAIL;reason=session_not_found;textureId=$textureId",
            ))
            return
        }

        entry.session.play(frameBudget) { playResult ->
            mainHandler.post {
                val resMap = playResult.toMutableMap().apply {
                    putIfAbsent("textureId", textureId)
                }
                result.success(resMap)
            }
        }
    }

    fun pausePhase4B1BPlaybackControlSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "pauseAndroidDagPhase4B1BPlaybackControlSmoke: textureId required", null)
            return
        }

        val entry = synchronized(controlSessions) { controlSessions[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to false,
                "state" to "Failed",
                "textureId" to textureId,
                "raw" to "status=FAIL;reason=session_not_found;textureId=$textureId",
            ))
            return
        }

        entry.session.pause { pauseResult ->
            mainHandler.post {
                val resMap = pauseResult.toMutableMap().apply {
                    putIfAbsent("textureId", textureId)
                }
                result.success(resMap)
            }
        }
    }

    fun seekPhase4B1BPlaybackControlSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "seekAndroidDagPhase4B1BPlaybackControlSmoke: textureId required", null)
            return
        }
        val targetPtsUs = (args?.get("targetPtsUs") as? Number)?.toLong()
            ?: (args?.get("targetUs") as? Number)?.toLong()
            ?: 0L
        val resumeAfterSeek = (args?.get("resumeAfterSeek") as? Boolean) ?: false

        val entry = synchronized(controlSessions) { controlSessions[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to false,
                "state" to "Failed",
                "textureId" to textureId,
                "raw" to "status=FAIL;reason=session_not_found;textureId=$textureId",
            ))
            return
        }

        entry.session.seek(targetPtsUs, resumeAfterSeek) { seekResult ->
            mainHandler.post {
                val resMap = seekResult.toMutableMap().apply {
                    putIfAbsent("textureId", textureId)
                }
                result.success(resMap)
            }
        }
    }

    fun disposePhase4B1BPlaybackControlSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "disposeAndroidDagPhase4B1BPlaybackControlSmoke: textureId required", null)
            return
        }

        val entry = synchronized(controlSessions) { controlSessions.remove(textureId) }
        if (entry != null) {
            entry.session.dispose { dispResult ->
                val resMap = dispResult.toMutableMap().apply {
                    putIfAbsent("textureId", textureId)
                }
                mainHandler.post {
                    try { entry.surfaceProducer.release() } catch (_: Throwable) {}
                    result.success(resMap)
                }
            }
        } else {
            result.success(mapOf(
                "pass" to true,
                "state" to "Disposed",
                "textureId" to textureId,
                "raw" to "status=OK;already_disposed_or_not_found;textureId=$textureId",
            ))
        }
    }

    // ── Phase 4B2A: State Machine & Timeline Clock diagnostic smoke ─────────

    fun runPhase4B2AClockStateSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        try {
            val stateSequence = mutableListOf<String>()
            val sm = AndroidDagPlaybackStateMachine()
            stateSequence.add(sm.state.name) // Idle

            var smPass = true
            fun step(res: AndroidDagPlaybackTransitionResult, expected: AndroidDagPlaybackState) {
                if (!res.pass || sm.state != expected || res.toState != expected) {
                    smPass = false
                }
                stateSequence.add(sm.state.name)
            }

            step(sm.prepareStarted(), AndroidDagPlaybackState.Preparing)
            step(sm.prepareSucceeded(), AndroidDagPlaybackState.Prepared)
            step(sm.playRequested(), AndroidDagPlaybackState.Playing)
            step(sm.pauseRequested(), AndroidDagPlaybackState.Paused)
            step(sm.seekStarted(), AndroidDagPlaybackState.Seeking)
            step(sm.seekCompletedPaused(), AndroidDagPlaybackState.Paused)
            step(sm.playRequested(), AndroidDagPlaybackState.Playing)
            step(sm.surfaceLost(), AndroidDagPlaybackState.SurfaceLost)
            step(sm.surfaceRestored(), AndroidDagPlaybackState.Paused)
            step(sm.backgrounded(), AndroidDagPlaybackState.Backgrounded)
            step(sm.foregrounded(), AndroidDagPlaybackState.Paused)
            step(sm.playRequested(), AndroidDagPlaybackState.Playing)
            step(sm.completed(), AndroidDagPlaybackState.Completed)
            step(sm.dispose(), AndroidDagPlaybackState.Disposed)

            // Test idempotent dispose
            val disp2 = sm.dispose()
            if (!disp2.pass || sm.state != AndroidDagPlaybackState.Disposed) {
                smPass = false
            }

            // Test invalid transitions
            val invalidFromDisposed = sm.playRequested()
            val invalidSm = AndroidDagPlaybackStateMachine()
            val invalidFromIdle = invalidSm.seekCompletedPaused()
            val invalidTransitionPass = !invalidFromDisposed.pass &&
                    sm.state == AndroidDagPlaybackState.Disposed &&
                    invalidFromDisposed.reason != null &&
                    !invalidFromIdle.pass &&
                    invalidSm.state == AndroidDagPlaybackState.Idle &&
                    invalidFromIdle.reason != null

            // Exercise Timeline Clock
            val clock = AndroidDagTimelineClock()
            val baseNanos = 1_000_000_000L // 1.0s
            clock.start(frameTimeNanos = baseNanos, initialMediaPtsUs = 0L)

            // Advance 0.5s (500_000 us)
            val t1Nanos = baseNanos + 500_000_000L
            val pos1 = clock.currentPositionUs(t1Nanos)

            // Pause at t1
            val pausedPositionUs = clock.pause(t1Nanos)
            val t2Nanos = baseNanos + 1_000_000_000L
            val posWhilePaused = clock.currentPositionUs(t2Nanos)

            // Resume at t2 and advance 0.25s (250_000 us)
            clock.resume(t2Nanos)
            val t3Nanos = t2Nanos + 250_000_000L
            val resumedPositionUs = clock.currentPositionUs(t3Nanos)

            // Seek to 2_000_000 us at t4
            val t4Nanos = t3Nanos + 100_000_000L
            val seekPositionUs = clock.seek(2_000_000L, t4Nanos)
            val t5Nanos = t4Nanos + 100_000_000L
            val posAfterSeek = clock.currentPositionUs(t5Nanos)

            // Test negative clamp
            clock.seek(-100_000L, t5Nanos)
            val clampedNeg = clock.currentPositionUs(t5Nanos)

            clock.dispose()

            val clockPass = pos1 == 500_000L &&
                    pausedPositionUs == 500_000L &&
                    posWhilePaused == 500_000L &&
                    resumedPositionUs == 750_000L &&
                    seekPositionUs == 2_000_000L &&
                    posAfterSeek == 2_100_000L &&
                    clampedNeg == 0L

            val pass = smPass && invalidTransitionPass && clockPass
            val raw = if (pass) {
                "status=OK;smPass=$smPass;clockPass=$clockPass;invalidTransitionPass=$invalidTransitionPass"
            } else {
                "status=FAIL;smPass=$smPass;clockPass=$clockPass;invalidTransitionPass=$invalidTransitionPass;pos1=$pos1;pausedPos=$pausedPositionUs;pausedCheck=$posWhilePaused;resumedPos=$resumedPositionUs;seekPos=$seekPositionUs;posAfterSeek=$posAfterSeek;clampedNeg=$clampedNeg"
            }

            result.success(mapOf(
                "pass" to pass,
                "stateSequence" to stateSequence,
                "invalidTransitionPass" to invalidTransitionPass,
                "pausedPositionUs" to pausedPositionUs,
                "resumedPositionUs" to resumedPositionUs,
                "seekPositionUs" to seekPositionUs,
                "raw" to raw,
            ))
        } catch (t: Throwable) {
            Log.e(TAG, "Phase 4B2A clock/state smoke error", t)
            result.success(mapOf(
                "pass" to false,
                "stateSequence" to emptyList<String>(),
                "invalidTransitionPass" to false,
                "pausedPositionUs" to -1L,
                "resumedPositionUs" to -1L,
                "seekPositionUs" to -1L,
                "raw" to "status=FAIL;reason=exception:${t.javaClass.simpleName}:${t.message}",
            ))
        }
    }

    // ── Phase 4B2B2B: Surface lifecycle diagnostic seams ─────────────────────

    /**
     * Diagnostic seam: simulates a surface cleanup callback for the given textureId.
     * Intended for future physical smoke tests; does not affect production lifecycle.
     */
    fun simulatePhase4B2B2SurfaceCleanup(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "simulateAndroidDagPhase4B2B2SurfaceCleanup: textureId required", null)
            return
        }
        val entry = synchronized(controlSessions) { controlSessions[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to false,
                "textureId" to textureId,
                "raw" to "status=FAIL;reason=session_not_found;textureId=$textureId",
            ))
            return
        }
        // Delegate to the session; onDone fires after handler work completes so the snapshot is accurate.
        entry.session.simulateSurfaceCleanup { diag ->
            mainHandler.post {
                result.success(diag.toMutableMap().apply {
                    put("pass", true)
                    put("textureId", textureId)
                    put("raw", "status=OK;simulated=surface_cleanup;state=${diag["state"]}")
                })
            }
        }
    }

    /**
     * Diagnostic seam: simulates a surface available callback for the given textureId.
     * Intended for future physical smoke tests; does not affect production lifecycle.
     */
    fun simulatePhase4B2B2SurfaceAvailable(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "simulateAndroidDagPhase4B2B2SurfaceAvailable: textureId required", null)
            return
        }
        val entry = synchronized(controlSessions) { controlSessions[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to false,
                "textureId" to textureId,
                "raw" to "status=FAIL;reason=session_not_found;textureId=$textureId",
            ))
            return
        }
        // Delegate; onDone fires after restore handler work completes so the snapshot is accurate.
        entry.session.simulateSurfaceAvailable { diag ->
            mainHandler.post {
                result.success(diag.toMutableMap().apply {
                    put("pass", true)
                    put("textureId", textureId)
                    put("raw", "status=OK;simulated=surface_available;state=${diag["state"]}")
                })
            }
        }
    }

    // ── Phase 4B2B3F: real vs. simulated surface lifecycle diagnostics ──────

    /**
     * Diagnostic seam: returns [AndroidDagTexturePlaybackControlSession.diagnosticState] for
     * the given textureId, including the real-callback counters that distinguish genuine
     * Flutter SurfaceProducer callbacks from the simulate* diagnostic seams above.
     */
    fun getPhase4B2B3SurfaceLifecycleStatus(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "getAndroidDagPhase4B2B3SurfaceLifecycleStatus: textureId required", null)
            return
        }
        val entry = synchronized(controlSessions) { controlSessions[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to false,
                "textureId" to textureId,
                "raw" to "status=FAIL;reason=session_not_found;textureId=$textureId",
            ))
            return
        }
        val diag = entry.session.diagnosticState()
        result.success(diag.toMutableMap().apply {
            put("pass", true)
            put("textureId", textureId)
            put("raw", "status=OK;surface_lifecycle_status;state=${diag["state"]}")
        })
    }

    fun disposeAll() {
        synchronized(smokeSessions) {
            smokeSessions.values.forEach { entry ->
                try { entry.session.dispose() } catch (_: Throwable) {}
                try { entry.textureEntry.release() } catch (_: Throwable) {}
            }
            smokeSessions.clear()
        }
        val entriesToDispose = synchronized(controlSessions) {
            val list = controlSessions.values.toList()
            controlSessions.clear()
            list
        }
        entriesToDispose.forEach { entry ->
            try {
                entry.session.dispose {
                    mainHandler.post {
                        try { entry.surfaceProducer.release() } catch (_: Throwable) {}
                    }
                }
            } catch (_: Throwable) {}
        }
    }
}
