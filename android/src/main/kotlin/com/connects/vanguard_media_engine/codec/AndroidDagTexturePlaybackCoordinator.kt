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
        val textureEntry: TextureRegistry.SurfaceTextureEntry,
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

        val textureEntry = textureRegistry.createSurfaceTexture()
        val textureId = textureEntry.id()

        val session = AndroidDagTexturePlaybackControlSession(
            videoPath = path,
            textureEntry = textureEntry,
        )

        val entry = ActiveControlEntry(session, textureEntry)
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
                    try { textureEntry.release() } catch (_: Throwable) {}
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
                    try { entry.textureEntry.release() } catch (_: Throwable) {}
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
                        try { entry.textureEntry.release() } catch (_: Throwable) {}
                    }
                }
            } catch (_: Throwable) {}
        }
    }
}
