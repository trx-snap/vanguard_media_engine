package com.connects.vanguard_media_engine.codec

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

class AndroidDagTexturePlaybackCoordinator(
    private val textureRegistry: TextureRegistry,
    private val channel: MethodChannel,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "DagTextureCoordinator"
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

        val surfaceProducer = textureRegistry.createSurfaceProducer()
        val textureId = surfaceProducer.id()

        val session = AndroidDagTexturePlaybackControlSession(
            videoPath = path,
            surfaceProducer = surfaceProducer,
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
