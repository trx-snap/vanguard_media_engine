package com.connects.vanguard_media_engine.streaming

import android.content.Context
import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.codec.AndroidDagPlaybackState
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * Vanguard Android True-DAG Phase 4C1D1B: Streaming playback coordinator.
 *
 * Exposes [AndroidDagStreamingPlaybackSession] instances behind a diagnostic MethodChannel
 * coordinator. Owns active streaming sessions keyed by SurfaceProducer textureId, mirroring
 * the AndroidDagTexturePlaybackCoordinator style.
 */
class AndroidDagStreamingPlaybackCoordinator(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "DagStreamingCoord"

        private val OWNED_METHODS = setOf(
            "createAndroidDagPhase4C1D1StreamingPlayback",
            "playAndroidDagPhase4C1D1StreamingPlayback",
            "pauseAndroidDagPhase4C1D1StreamingPlayback",
            "seekAndroidDagPhase4C1D1StreamingPlayback",
            "stopAndroidDagPhase4C1D1StreamingPlayback",
            "diagnoseAndroidDagPhase4C1D1StreamingPlayback",
            "simulateAndroidDagPhase4C1D1StreamingSurfaceCleanup",
            "simulateAndroidDagPhase4C1D1StreamingSurfaceAvailable",
            "disposeAndroidDagPhase4C1D1StreamingPlayback",
            "runAndroidDagPhase4C4GAdaptiveStreamTimelineSmoke",
            "runAndroidDagPhase4C5AStreamingCodecCapabilitySmoke",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "createAndroidDagPhase4C1D1StreamingPlayback" -> createStreamingPlayback(args, result)
            "playAndroidDagPhase4C1D1StreamingPlayback" -> playStreamingPlayback(args, result)
            "pauseAndroidDagPhase4C1D1StreamingPlayback" -> pauseStreamingPlayback(args, result)
            "seekAndroidDagPhase4C1D1StreamingPlayback" -> seekStreamingPlayback(args, result)
            "stopAndroidDagPhase4C1D1StreamingPlayback" -> stopStreamingPlayback(args, result)
            "diagnoseAndroidDagPhase4C1D1StreamingPlayback" -> diagnoseStreamingPlayback(args, result)
            "simulateAndroidDagPhase4C1D1StreamingSurfaceCleanup" -> simulateStreamingSurfaceCleanup(args, result)
            "simulateAndroidDagPhase4C1D1StreamingSurfaceAvailable" -> simulateStreamingSurfaceAvailable(args, result)
            "disposeAndroidDagPhase4C1D1StreamingPlayback" -> disposeStreamingPlayback(args, result)
            "runAndroidDagPhase4C4GAdaptiveStreamTimelineSmoke" -> runAdaptiveStreamTimelineSmoke(args, result)
            "runAndroidDagPhase4C5AStreamingCodecCapabilitySmoke" -> runAdaptiveStreamingCodecCapabilitySmoke(result)
            else -> return false
        }
        return true
    }

    private data class ActiveStreamingEntry(
        val session: AndroidDagStreamingPlaybackSession,
        val surfaceProducer: TextureRegistry.SurfaceProducer,
    )

    private val sessions = mutableMapOf<Long, ActiveStreamingEntry>()

    fun createStreamingPlayback(args: Map<*, *>?, result: MethodChannel.Result) {
        val uri = args?.get("uri") as? String
        val widthNum = args?.get("initialWidth") as? Number
        val heightNum = args?.get("initialHeight") as? Number

        if (uri.isNullOrBlank() || widthNum == null || heightNum == null) {
            result.error("INVALID_ARG", "createAndroidDagPhase4C1D1StreamingPlayback: uri, initialWidth, initialHeight required", null)
            return
        }

        val initialWidth = widthNum.toInt()
        val initialHeight = heightNum.toInt()
        if (initialWidth <= 0 || initialHeight <= 0) {
            result.error("INVALID_ARG", "createAndroidDagPhase4C1D1StreamingPlayback: initialWidth and initialHeight must be > 0", null)
            return
        }

        val formatHintStr = (args["formatHint"] as? String)?.trim()?.uppercase() ?: "AUTO"
        val formatHint = when (formatHintStr) {
            "AUTO" -> AdaptiveStreamFormat.AUTO
            "HLS" -> AdaptiveStreamFormat.HLS
            "DASH" -> AdaptiveStreamFormat.DASH
            else -> {
                result.error("INVALID_ARG", "createAndroidDagPhase4C1D1StreamingPlayback: invalid formatHint '$formatHintStr', expected AUTO, HLS, or DASH", null)
                return
            }
        }

        @Suppress("UNCHECKED_CAST")
        val httpHeaders = (args["httpHeaders"] as? Map<*, *>)?.mapNotNull { (k, v) ->
            if (k is String && v is String) k to v else null
        }?.toMap()

        val startPosNum = args["startPositionMs"] as? Number
        val startPositionMs = startPosNum?.toLong()
        if (startPositionMs != null && startPositionMs < 0L) {
            result.error("INVALID_ARG", "createAndroidDagPhase4C1D1StreamingPlayback: startPositionMs must be >= 0", null)
            return
        }

        val autoPlay = (args["autoPlay"] as? Boolean) ?: true

        val streamConfig = try {
            HttpAdaptiveStreamConfig(
                uri = uri,
                formatHint = formatHint,
                httpHeaders = httpHeaders,
                startPositionMs = startPositionMs,
                autoPlay = autoPlay,
            )
        } catch (t: Throwable) {
            result.error("INVALID_ARG", "createAndroidDagPhase4C1D1StreamingPlayback: invalid config: ${t.message}", null)
            return
        }

        val surfaceProducer = textureRegistry.createSurfaceProducer()
        val textureId = surfaceProducer.id()

        val session = AndroidDagStreamingPlaybackSession(
            context = context,
            surfaceProducer = surfaceProducer,
            streamConfig = streamConfig,
            initialWidth = initialWidth,
            initialHeight = initialHeight,
        )

        val entry = ActiveStreamingEntry(session, surfaceProducer)
        synchronized(sessions) {
            sessions[textureId] = entry
        }

        try {
            session.prepare { prepResult ->
                mainHandler.post {
                    val pass = prepResult["pass"] as? Boolean ?: false
                    if (!pass) {
                        synchronized(sessions) {
                            sessions.remove(textureId)
                        }
                        try { session.dispose() } catch (_: Throwable) {}
                        try { surfaceProducer.release() } catch (_: Throwable) {}
                    }
                    val resultMap = prepResult.toMutableMap().apply {
                        putIfAbsent("textureId", textureId)
                        putIfAbsent("phase", "Phase4C1D1")
                    }
                    result.success(resultMap)
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "Exception during session prepare", t)
            synchronized(sessions) {
                sessions.remove(textureId)
            }
            try { session.dispose() } catch (_: Throwable) {}
            try { surfaceProducer.release() } catch (_: Throwable) {}
            result.success(mapOf(
                "pass" to false,
                "state" to AndroidDagPlaybackState.Failed.name,
                "textureId" to textureId,
                "phase" to "Phase4C1D1",
                "raw" to "status=FAIL;reason=prepare_exception:${t.javaClass.simpleName}:${t.message}",
            ))
        }
    }

    fun playStreamingPlayback(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "playAndroidDagPhase4C1D1StreamingPlayback: textureId required", null)
            return
        }

        val entry = synchronized(sessions) { sessions[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to false,
                "state" to "Failed",
                "textureId" to textureId,
                "raw" to "status=FAIL;reason=session_not_found;textureId=$textureId",
            ))
            return
        }

        entry.session.play { playResult ->
            mainHandler.post {
                val resMap = playResult.toMutableMap().apply {
                    putIfAbsent("textureId", textureId)
                }
                result.success(resMap)
            }
        }
    }

    fun pauseStreamingPlayback(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "pauseAndroidDagPhase4C1D1StreamingPlayback: textureId required", null)
            return
        }

        val entry = synchronized(sessions) { sessions[textureId] }
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

    fun seekStreamingPlayback(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "seekAndroidDagPhase4C1D1StreamingPlayback: textureId required", null)
            return
        }
        val posNum = args?.get("positionMs") as? Number
        if (posNum == null) {
            result.error("INVALID_ARG", "seekAndroidDagPhase4C1D1StreamingPlayback: positionMs required", null)
            return
        }
        val positionMs = posNum.toLong()
        if (positionMs < 0L) {
            result.error("INVALID_ARG", "seekAndroidDagPhase4C1D1StreamingPlayback: positionMs must be >= 0, got $positionMs", null)
            return
        }

        val entry = synchronized(sessions) { sessions[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to false,
                "state" to "Failed",
                "textureId" to textureId,
                "raw" to "status=FAIL;reason=session_not_found;textureId=$textureId",
            ))
            return
        }

        entry.session.seekTo(positionMs) { seekResult ->
            mainHandler.post {
                val resMap = seekResult.toMutableMap().apply {
                    putIfAbsent("textureId", textureId)
                }
                result.success(resMap)
            }
        }
    }

    fun stopStreamingPlayback(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "stopAndroidDagPhase4C1D1StreamingPlayback: textureId required", null)
            return
        }

        val entry = synchronized(sessions) { sessions[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to false,
                "state" to "Failed",
                "textureId" to textureId,
                "raw" to "status=FAIL;reason=session_not_found;textureId=$textureId",
            ))
            return
        }

        entry.session.stop { stopResult ->
            mainHandler.post {
                val resMap = stopResult.toMutableMap().apply {
                    putIfAbsent("textureId", textureId)
                }
                result.success(resMap)
            }
        }
    }

    fun diagnoseStreamingPlayback(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "diagnoseAndroidDagPhase4C1D1StreamingPlayback: textureId required", null)
            return
        }

        val entry = synchronized(sessions) { sessions[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to false,
                "state" to "Failed",
                "textureId" to textureId,
                "raw" to "status=FAIL;reason=session_not_found;textureId=$textureId",
            ))
            return
        }

        val diag = entry.session.diagnosticState()
        val resMap = diag.toMutableMap().apply {
            putIfAbsent("textureId", textureId)
        }
        mainHandler.post {
            result.success(resMap)
        }
    }

    fun simulateStreamingSurfaceCleanup(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "simulateAndroidDagPhase4C1D1StreamingSurfaceCleanup: textureId required", null)
            return
        }

        val entry = synchronized(sessions) { sessions[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to false,
                "state" to "Failed",
                "textureId" to textureId,
                "raw" to "status=FAIL;reason=session_not_found;textureId=$textureId",
            ))
            return
        }

        entry.session.simulateSurfaceCleanup { diag ->
            mainHandler.post {
                val resMap = diag.toMutableMap().apply {
                    putIfAbsent("textureId", textureId)
                }
                result.success(resMap)
            }
        }
    }

    fun simulateStreamingSurfaceAvailable(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "simulateAndroidDagPhase4C1D1StreamingSurfaceAvailable: textureId required", null)
            return
        }

        val entry = synchronized(sessions) { sessions[textureId] }
        if (entry == null) {
            result.success(mapOf(
                "pass" to false,
                "state" to "Failed",
                "textureId" to textureId,
                "raw" to "status=FAIL;reason=session_not_found;textureId=$textureId",
            ))
            return
        }

        entry.session.simulateSurfaceAvailable { diag ->
            mainHandler.post {
                val resMap = diag.toMutableMap().apply {
                    putIfAbsent("textureId", textureId)
                }
                result.success(resMap)
            }
        }
    }

    fun disposeStreamingPlayback(args: Map<*, *>?, result: MethodChannel.Result) {
        val textureId = (args?.get("textureId") as? Number)?.toLong()
        if (textureId == null) {
            result.error("INVALID_ARG", "disposeAndroidDagPhase4C1D1StreamingPlayback: textureId required", null)
            return
        }

        val entry = synchronized(sessions) { sessions.remove(textureId) }
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

    fun disposeAll() {
        val entriesToDispose = synchronized(sessions) {
            val list = sessions.values.toList()
            sessions.clear()
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

    private fun runAdaptiveStreamTimelineSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val frameCount = (args?.get("frameCount") as? Number)?.toInt() ?: 5
        Thread {
            val smokeResult = AdaptiveStreamTimelineSmokeHarness.run(frameCount)
            mainHandler.post { result.success(smokeResult) }
        }.start()
    }

    private fun runAdaptiveStreamingCodecCapabilitySmoke(result: MethodChannel.Result) {
        Thread {
            val smokeResult = AdaptiveStreamingCodecCapabilitySmokeHarness.run()
            mainHandler.post { result.success(smokeResult) }
        }.start()
    }
}
