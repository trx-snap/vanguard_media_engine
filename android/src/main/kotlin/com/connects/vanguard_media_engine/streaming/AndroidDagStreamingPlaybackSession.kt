// Copyright (c) Connects - Phase 4C1D1A: Android True-DAG Streaming Playback Session.
// Non-exposed streaming session class bridging Media3 ExoPlayer decode frames to native DAG Vulkan render.
// Phase 4C4J-M: Adaptive stream timeline telemetry (diagnostic-only).

package com.connects.vanguard_media_engine.streaming

import android.content.Context
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.codec.AndroidDagPlaybackState
import com.connects.vanguard_media_engine.codec.AndroidDagSurfaceProducerLifecycleAdapter
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Vanguard Android True-DAG Phase 4C1D1A: Streaming playback session.
 *
 * Route: HttpAdaptivePlaybackAdapter (Media3 ExoPlayer) ->
 *        HttpAdaptiveImageReaderBridge -> HttpAdaptiveDecodedFrame (HardwareBuffer) ->
 *        native DAG generation-aware evaluation -> Vulkan render ->
 *        Flutter TextureRegistry SurfaceProducer.
 *
 * Phase 4C4J: Owns an AdaptiveStreamTimelineController for diagnostic-only timeline telemetry.
 * Phase 4C4K: Streaming diagnostic state exposes timeline telemetry via diagnosticState/diagnosticMap.
 */
class AndroidDagStreamingPlaybackSession(
    private val context: Context,
    private val surfaceProducer: TextureRegistry.SurfaceProducer,
    private val streamConfig: HttpAdaptiveStreamConfig,
    private val initialWidth: Int,
    private val initialHeight: Int,
) {
    companion object {
        private const val TAG = "DagStreamingSession"
    }

    init {
        require(initialWidth > 0) { "AndroidDagStreamingPlaybackSession: initialWidth must be positive, got $initialWidth" }
        require(initialHeight > 0) { "AndroidDagStreamingPlaybackSession: initialHeight must be positive, got $initialHeight" }
    }

    private val disposed = AtomicBoolean(false)
    private val surfaceLost = AtomicBoolean(false)
    private val renderLock = Any()

    @Volatile
    var state: AndroidDagPlaybackState = AndroidDagPlaybackState.Idle
        private set

    private val diagnostics = VanguardDiagnostics()
    private val lifecycleObserver = VanguardLifecycleObserver(diagnostics)
    private val nativeBridge = VanguardNativeBridge(lifecycleObserver, diagnostics, null)

    // Phase 4C4J: Adaptive timeline controller owned by this session. Diagnostic-only.
    // Timeline evaluation must NOT gate, drop, delay, or alter native rendering behavior.
    private val adaptiveTimelineController = AdaptiveStreamTimelineController()

    // Frame-anchor flag (protected by renderLock). When true, the next decoded frame rebases
    // the timeline to the actual first-decoded PTS before evaluate(), preventing false
    // DROPPED_LATE on startup, post-seek, post-rendition-change, or post-surface-restore frames.
    private var adaptiveTimelineNeedsFrameAnchor: Boolean = true

    private var adapter: HttpAdaptivePlaybackAdapter? = null
    private var lifecycleAdapter: AndroidDagSurfaceProducerLifecycleAdapter? = null
    private var flutterSurface: Surface? = null
    private var sessionId: String? = null
    private var generationId: Long = 0L

    private var currentWidth: Int = initialWidth
    private var currentHeight: Int = initialHeight
    private var renderedFrames: Int = 0
    private var lastRenderedPtsUs: Long = 0L
    private var lastError: String? = null

    /** Prepares adaptive streaming playback and native True-DAG rendering pipeline. */
    fun prepare(onResult: (Map<String, Any?>) -> Unit) {
        if (disposed.get()) {
            state = AndroidDagPlaybackState.Failed
            onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=disposed"))
            return
        }

        synchronized(renderLock) {
            if (disposed.get()) {
                state = AndroidDagPlaybackState.Failed
                onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=disposed"))
                return
            }

            try {
                state = AndroidDagPlaybackState.Preparing

                val adapterShim = AndroidDagSurfaceProducerLifecycleAdapter(
                    onAvailable = { handleSurfaceAvailable() },
                    onCleanup = { handleSurfaceCleanup() },
                ).also { lifecycleAdapter = it }
                @Suppress("DEPRECATION")
                surfaceProducer.setCallback(adapterShim)

                currentWidth = initialWidth
                currentHeight = initialHeight
                surfaceProducer.setSize(initialWidth, initialHeight)
                val surface = surfaceProducer.getSurface().also { flutterSurface = it }

                val createResult = nativeBridge.createAndroidDagPhase4B1TexturePlaybackSession(surface, initialWidth, initialHeight)
                if (!createResult.startsWith("status=OK;")) {
                    lastError = "native_session_create_failed;$createResult"
                    cleanupFailedPrepare()
                    onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=$lastError"))
                    return
                }

                val parsedSessionId = createResult.substringAfter("sessionId=").substringBefore(";").ifEmpty { null }
                if (parsedSessionId == null) {
                    lastError = "session_id_parse_failed;$createResult"
                    cleanupFailedPrepare()
                    onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=$lastError"))
                    return
                }
                sessionId = parsedSessionId

                val bumpRes = nativeBridge.bumpAndroidDagPhase4B1TexturePlaybackGeneration(parsedSessionId)
                if (!bumpRes.startsWith("status=OK;")) {
                    lastError = "initial_generation_bump_failed;$bumpRes"
                    cleanupFailedPrepare()
                    onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=$lastError"))
                    return
                }
                val parsedGen = bumpRes.substringAfter("generationId=").substringBefore(";").toLongOrNull()
                if (parsedGen == null || parsedGen <= 0L) {
                    lastError = "initial_generation_parse_failed;$bumpRes"
                    cleanupFailedPrepare()
                    onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=$lastError"))
                    return
                }
                generationId = parsedGen

                // Start adaptive timeline for diagnostic-only telemetry.
                val initialTimelinePtsUs = (streamConfig.startPositionMs?.let { it * 1000L } ?: 0L)
                    .coerceAtLeast(0L)
                adaptiveTimelineController.start(System.nanoTime(), initialTimelinePtsUs)
                // Anchor needed: first decoded frame rebases to actual stream-start PTS.
                adaptiveTimelineNeedsFrameAnchor = true

                val playbackListener = object : HttpAdaptivePlaybackListener {
                    override fun onStateChanged(newState: HttpAdaptivePlaybackState) {
                        if (disposed.get() || surfaceLost.get()) return
                        when (newState) {
                            is HttpAdaptivePlaybackState.Idle -> state = AndroidDagPlaybackState.Idle
                            is HttpAdaptivePlaybackState.Preparing -> state = AndroidDagPlaybackState.Preparing
                            is HttpAdaptivePlaybackState.Ready -> state = AndroidDagPlaybackState.Prepared
                            is HttpAdaptivePlaybackState.Playing -> state = AndroidDagPlaybackState.Playing
                            is HttpAdaptivePlaybackState.Paused -> state = AndroidDagPlaybackState.Paused
                            is HttpAdaptivePlaybackState.Buffering -> if (state == AndroidDagPlaybackState.Preparing) state = AndroidDagPlaybackState.Preparing
                            is HttpAdaptivePlaybackState.Seeking -> state = AndroidDagPlaybackState.Seeking
                            is HttpAdaptivePlaybackState.Ended -> state = AndroidDagPlaybackState.Completed
                            is HttpAdaptivePlaybackState.Failed -> {
                                failAndDestroyNativeSession("adapter_error:${newState.errorCode}:${newState.message}")
                            }
                            is HttpAdaptivePlaybackState.Released -> state = AndroidDagPlaybackState.Disposed
                        }
                    }

                    override fun onVideoSizeChanged(width: Int, height: Int) = handleVideoSizeChanged(width, height)
                    override fun onBufferingProgress(bufferedPercent: Int) {}
                    override fun onPlaybackError(errorCode: Int, message: String) {
                        failAndDestroyNativeSession("playback_error:$errorCode:$message")
                    }
                }

                val ad = HttpAdaptivePlaybackAdapter(context, playbackListener).also { adapter = it }
                ad.enableHeadlessFrameBridge(initialWidth, initialHeight) { frame -> handleDecodedFrame(frame) }
                ad.prepare(streamConfig)
                state = AndroidDagPlaybackState.Prepared

                onResult(diagnosticMap(pass = true, raw = createResult).toMutableMap().apply {
                    put("width", initialWidth)
                    put("height", initialHeight)
                })
            } catch (t: Throwable) {
                Log.e(TAG, "Error during prepare", t)
                lastError = "prepare_exception:${t.javaClass.simpleName}:${t.message}"
                cleanupFailedPrepare()
                onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=$lastError"))
            }
        }
    }

    /** Starts or resumes streaming playback. */
    fun play(onResult: (Map<String, Any?>) -> Unit) {
        if (disposed.get()) return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=disposed"))
        if (surfaceLost.get() || state == AndroidDagPlaybackState.SurfaceLost) return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=surface_lost"))
        val ad = adapter ?: return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=adapter_null"))
        state = AndroidDagPlaybackState.Playing
        ad.play()
        onResult(diagnosticMap(pass = true, raw = "status=OK;state=Playing"))
    }

    /** Pauses streaming playback while preserving buffers. */
    fun pause(onResult: (Map<String, Any?>) -> Unit) {
        if (disposed.get()) return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=disposed"))
        val ad = adapter ?: return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=adapter_null"))
        if (state != AndroidDagPlaybackState.Disposed && state != AndroidDagPlaybackState.Failed && state != AndroidDagPlaybackState.SurfaceLost) {
            state = AndroidDagPlaybackState.Paused
        }
        ad.pause()
        onResult(diagnosticMap(pass = true, raw = "status=OK;state=Paused"))
    }

    /** Seeks to [positionMs] milliseconds. Bumps DAG generation before dispatching seek to adapter. */
    fun seekTo(positionMs: Long, onResult: (Map<String, Any?>) -> Unit) {
        if (disposed.get()) return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=disposed"))
        if (positionMs < 0L) return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=invalid_position;positionMs=$positionMs"))
        if (surfaceLost.get() || state == AndroidDagPlaybackState.SurfaceLost) return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=surface_lost"))
        val ad = adapter ?: return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=adapter_null"))
        state = AndroidDagPlaybackState.Seeking
        synchronized(renderLock) {
            val sid = sessionId
            if (sid != null) {
                val bumpRes = nativeBridge.bumpAndroidDagPhase4B1TexturePlaybackGeneration(sid)
                if (bumpRes.startsWith("status=OK;")) {
                    val parsedGen = bumpRes.substringAfter("generationId=").substringBefore(";").toLongOrNull()
                    if (parsedGen != null && parsedGen > 0L) generationId = parsedGen
                }
            }
            // Rebase adaptive timeline on seek -- diagnostic-only, does not affect rendering.
            adaptiveTimelineController.rebase("seek", System.nanoTime(), positionMs * 1000L)
            // Next decoded frame must re-anchor to actual post-seek PTS before evaluate().
            adaptiveTimelineNeedsFrameAnchor = true
        }
        ad.seekTo(positionMs)
        onResult(diagnosticMap(pass = true, raw = "status=OK;state=Seeking;positionMs=$positionMs;generationId=$generationId"))
    }

    /** Stops streaming playback and resets adapter to idle. */
    fun stop(onResult: (Map<String, Any?>) -> Unit) {
        if (disposed.get()) return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=disposed"))
        val ad = adapter ?: return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=adapter_null"))
        if (state != AndroidDagPlaybackState.Disposed && state != AndroidDagPlaybackState.Failed) state = AndroidDagPlaybackState.Idle
        ad.stop()
        onResult(diagnosticMap(pass = true, raw = "status=OK;state=Idle"))
    }

    /** Diagnostic seam: triggers surface cleanup handling. */
    fun simulateSurfaceCleanup(onResult: ((Map<String, Any?>) -> Unit)? = null) {
        Log.d(TAG, "simulateSurfaceCleanup: diagnostic trigger")
        handleSurfaceCleanup()
        onResult?.invoke(diagnosticState())
    }

    /** Diagnostic seam: triggers surface available handling. */
    fun simulateSurfaceAvailable(onResult: ((Map<String, Any?>) -> Unit)? = null) {
        Log.d(TAG, "simulateSurfaceAvailable: diagnostic trigger")
        handleSurfaceAvailable()
        onResult?.invoke(diagnosticState())
    }

    /** Returns a diagnostic snapshot of current session state. */
    fun diagnosticState(): Map<String, Any?> {
        val isSurfaceLost = surfaceLost.get() || state == AndroidDagPlaybackState.SurfaceLost
        val rawStatus = if (state == AndroidDagPlaybackState.Failed) "status=FAIL;state=${state.name};reason=${lastError ?: "unknown"}" else "status=OK;state=${state.name}"
        // Include adaptive timeline telemetry -- diagnostic-only.
        val tlSnapshot = adaptiveTimelineController.snapshot()
        return mapOf(
            "pass" to (state != AndroidDagPlaybackState.Failed),
            "state" to state.name,
            "textureId" to surfaceProducer.id(),
            "sessionId" to sessionId,
            "generationId" to generationId,
            "renderedFrames" to renderedFrames,
            "lastRenderedPtsUs" to lastRenderedPtsUs,
            "surfaceLost" to isSurfaceLost,
            "lastError" to lastError,
            "raw" to rawStatus,
            "adaptiveTimelineAttached" to true,
            "adaptiveTimeline" to tlSnapshot,
            "adaptiveTimelineAcceptedFrames" to (tlSnapshot["acceptedFrames"] as? Number)?.toLong(),
            "adaptiveTimelineGenerationId" to (tlSnapshot["generationId"] as? Number)?.toLong(),
            "adaptiveTimelineStarted" to (tlSnapshot["isStarted"] as? Boolean),
            "adaptiveTimelineLastAcceptedPtsUs" to (tlSnapshot["lastAcceptedPtsUs"] as? Number)?.toLong(),
            "adaptiveTimelineLastAcceptedFrameIndex" to (tlSnapshot["lastAcceptedFrameIndex"] as? Number)?.toLong(),
        )
    }

    /** Disposes session resources idempotently. Does NOT release SurfaceProducer. */
    fun dispose(onResult: ((Map<String, Any?>) -> Unit)? = null) {
        if (!disposed.compareAndSet(false, true)) {
            onResult?.invoke(diagnosticMap(pass = true, raw = "status=OK;already_disposed"))
            return
        }

        try {
            try { adapter?.release() } catch (t: Throwable) { Log.w(TAG, "Error releasing adapter during dispose", t) }
            adapter = null

            synchronized(renderLock) {
                val sid = sessionId
                sessionId = null
                if (sid != null) {
                    try { nativeBridge.destroyAndroidDagPhase4B1TexturePlaybackSession(sid) } catch (t: Throwable) {
                        Log.w(TAG, "Error destroying native session during dispose", t)
                    }
                }
                flutterSurface = null
            }

            try {
                @Suppress("DEPRECATION")
                surfaceProducer.setCallback(null)
            } catch (t: Throwable) {
                Log.w(TAG, "Error clearing SurfaceProducer callback during dispose", t)
            }
            lifecycleAdapter = null
            state = AndroidDagPlaybackState.Disposed
            onResult?.invoke(diagnosticMap(pass = true, raw = "status=OK;disposed=true"))
        } catch (t: Throwable) {
            Log.e(TAG, "Error during dispose", t)
            state = AndroidDagPlaybackState.Disposed
            onResult?.invoke(diagnosticMap(pass = true, raw = "status=OK;disposed_with_error:${t.javaClass.simpleName}"))
        }
    }

    private fun failAndDestroyNativeSession(reason: String, surfaceRelated: Boolean = false) {
        try {
            synchronized(renderLock) {
                lastError = reason
                val sid = sessionId
                sessionId = null
                if (sid != null) {
                    try {
                        nativeBridge.destroyAndroidDagPhase4B1TexturePlaybackSession(sid)
                    } catch (t: Throwable) {
                        Log.w(TAG, "Error destroying native session in failAndDestroyNativeSession: $reason", t)
                    }
                }
                flutterSurface = null
                if (!disposed.get()) {
                    if (surfaceRelated) {
                        surfaceLost.set(true)
                        state = AndroidDagPlaybackState.SurfaceLost
                    } else {
                        surfaceLost.set(false)
                        state = AndroidDagPlaybackState.Failed
                    }
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "Unexpected error in failAndDestroyNativeSession", t)
        }
    }

    // -- Internal Lifecycle Handlers --

    private fun handleDecodedFrame(frame: HttpAdaptiveDecodedFrame) {
        synchronized(renderLock) {
            if (disposed.get() || surfaceLost.get()) return
            val sid = sessionId ?: return
            val hwBuf = frame.hardwareBuffer
            val ptsUs = frame.ptsUs
            val fIndex = frame.frameIndex.toInt()
            val gen = generationId
            val w = if (currentWidth > 0) currentWidth else frame.width
            val h = if (currentHeight > 0) currentHeight else frame.height

            // Evaluate adaptive timeline -- diagnostic-only, result intentionally ignored.
            // If anchor is needed (first frame after prepare/seek/size-change/surface-restore),
            // rebase to the actual decoded PTS to avoid false DROPPED_LATE on startup frames.
            if (adaptiveTimelineNeedsFrameAnchor) {
                adaptiveTimelineController.rebase("decoded_frame_anchor", System.nanoTime(), ptsUs)
                adaptiveTimelineNeedsFrameAnchor = false
            }
            adaptiveTimelineController.evaluate(
                frameIndex = frame.frameIndex,
                samplePtsUs = ptsUs,
                arrivalFrameTimeNanos = System.nanoTime(),
            )

            val renderRes = try {
                nativeBridge.renderAndroidDagPhase4B1TexturePlaybackFrameForGeneration(
                    sessionId = sid,
                    hardwareBuffer = hwBuf,
                    width = w,
                    height = h,
                    timelinePtsUs = ptsUs,
                    frameIndex = fIndex,
                    generationId = gen,
                    rotationDegrees = 0,
                )
            } catch (t: Throwable) {
                Log.e(TAG, "renderFrame threw exception", t)
                failAndDestroyNativeSession("render_exception:${t.javaClass.simpleName}:${t.message}", surfaceRelated = false)
                return
            }

            if (renderRes.startsWith("status=PASS;")) {
                renderedFrames++
                lastRenderedPtsUs = ptsUs
            } else {
                val isStale = renderRes.contains("stale_generation")
                val isSurfaceLost = renderRes.contains("surface_lost")
                if (isStale) {
                    Log.d(TAG, "Dropped stale frame ($fIndex, gen $gen): $renderRes")
                } else if (isSurfaceLost) {
                    Log.w(TAG, "Frame render reported surface_lost: $renderRes")
                    failAndDestroyNativeSession(renderRes, surfaceRelated = true)
                } else {
                    Log.w(TAG, "Frame render failed ($fIndex): $renderRes")
                    failAndDestroyNativeSession(renderRes, surfaceRelated = false)
                }
            }
        }
    }

    private fun handleVideoSizeChanged(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return

        synchronized(renderLock) {
            currentWidth = width
            currentHeight = height
            try {
                surfaceProducer.setSize(width, height)
            } catch (t: Throwable) {
                Log.w(TAG, "Error updating surfaceProducer size during size change", t)
            }

            if (disposed.get() || surfaceLost.get()) return

            val oldSid = sessionId
            sessionId = null
            if (oldSid != null) {
                try {
                    nativeBridge.destroyAndroidDagPhase4B1TexturePlaybackSession(oldSid)
                } catch (t: Throwable) {
                    Log.w(TAG, "Error destroying native session during video size change", t)
                }
            }

            val surface = flutterSurface
            if (surface == null) {
                failAndDestroyNativeSession("surface_null_on_size_change", surfaceRelated = false)
                return
            }

            try {
                val createResult = nativeBridge.createAndroidDagPhase4B1TexturePlaybackSession(surface, width, height)
                if (!createResult.startsWith("status=OK;")) {
                    val isSurfaceLost = createResult.contains("surface_lost")
                    failAndDestroyNativeSession("native_session_recreate_failed_on_size_change;$createResult", surfaceRelated = isSurfaceLost)
                    return
                }

                val newSid = createResult.substringAfter("sessionId=").substringBefore(";").ifEmpty { null }
                if (newSid == null) {
                    failAndDestroyNativeSession("session_id_parse_failed_on_size_change;$createResult", surfaceRelated = false)
                    return
                }
                sessionId = newSid

                val bumpRes = nativeBridge.bumpAndroidDagPhase4B1TexturePlaybackGeneration(newSid)
                if (!bumpRes.startsWith("status=OK;")) {
                    val isSurfaceLost = bumpRes.contains("surface_lost")
                    failAndDestroyNativeSession("generation_bump_failed_on_size_change;$bumpRes", surfaceRelated = isSurfaceLost)
                    return
                }

                val parsedGen = bumpRes.substringAfter("generationId=").substringBefore(";").toLongOrNull()
                if (parsedGen == null || parsedGen <= 0L) {
                    failAndDestroyNativeSession("generation_parse_failed_on_size_change;$bumpRes", surfaceRelated = false)
                    return
                }

                generationId = parsedGen
                surfaceLost.set(false)

                // Rebase adaptive timeline on rendition/size change -- diagnostic-only.
                val rebaseMediaPtsUs = if (lastRenderedPtsUs > 0L) lastRenderedPtsUs else 0L
                adaptiveTimelineController.rebase("video_size_change", System.nanoTime(), rebaseMediaPtsUs)
                // Next decoded frame must re-anchor to actual post-rendition PTS before evaluate().
                adaptiveTimelineNeedsFrameAnchor = true
            } catch (t: Throwable) {
                Log.e(TAG, "Exception during video size change", t)
                failAndDestroyNativeSession("size_change_exception:${t.javaClass.simpleName}:${t.message}", surfaceRelated = false)
            }
        }
    }

    private fun handleSurfaceCleanup() {
        try { adapter?.pause() } catch (t: Throwable) { Log.w(TAG, "Failed pausing adapter during surface cleanup", t) }
        failAndDestroyNativeSession("surface_cleanup", surfaceRelated = true)
    }

    private fun handleSurfaceAvailable() {
        if (disposed.get()) return

        synchronized(renderLock) {
            if (disposed.get()) return
            if (!surfaceLost.get()) {
                Log.d(TAG, "handleSurfaceAvailable: not surface-lost; ignoring spurious callback")
                return
            }

            try {
                val width = if (currentWidth > 0) currentWidth else initialWidth
                val height = if (currentHeight > 0) currentHeight else initialHeight
                surfaceProducer.setSize(width, height)
                val surface = surfaceProducer.getSurface().also { flutterSurface = it }

                val createResult = nativeBridge.createAndroidDagPhase4B1TexturePlaybackSession(surface, width, height)
                if (!createResult.startsWith("status=OK;")) {
                    failAndDestroyNativeSession("native_session_recreate_failed;$createResult", surfaceRelated = true)
                    return
                }

                val newSid = createResult.substringAfter("sessionId=").substringBefore(";").ifEmpty { null }
                if (newSid == null) {
                    failAndDestroyNativeSession("session_id_parse_failed_on_restore;$createResult", surfaceRelated = true)
                    return
                }
                sessionId = newSid

                val bumpRes = nativeBridge.bumpAndroidDagPhase4B1TexturePlaybackGeneration(newSid)
                if (!bumpRes.startsWith("status=OK;")) {
                    failAndDestroyNativeSession("generation_bump_failed_on_restore;$bumpRes", surfaceRelated = true)
                    return
                }

                val parsedGen = bumpRes.substringAfter("generationId=").substringBefore(";").toLongOrNull()
                if (parsedGen == null || parsedGen <= 0L) {
                    failAndDestroyNativeSession("generation_parse_failed_on_restore;$bumpRes", surfaceRelated = true)
                    return
                }

                generationId = parsedGen
                surfaceLost.set(false)
                // Rebase adaptive timeline on surface restore -- diagnostic-only, does not affect rendering.
                val rebaseMediaPtsUs = if (lastRenderedPtsUs > 0L) lastRenderedPtsUs else 0L
                adaptiveTimelineController.rebase("surface_available", System.nanoTime(), rebaseMediaPtsUs)
                // Next decoded frame must re-anchor to actual post-restore PTS before evaluate().
                adaptiveTimelineNeedsFrameAnchor = true
                if (!disposed.get()) state = AndroidDagPlaybackState.Paused
            } catch (t: Throwable) {
                Log.e(TAG, "Exception during handleSurfaceAvailable", t)
                failAndDestroyNativeSession("surface_available_exception:${t.javaClass.simpleName}:${t.message}", surfaceRelated = true)
            }
        }
    }

    private fun cleanupFailedPrepare() {
        failAndDestroyNativeSession(lastError ?: "prepare_failed", surfaceRelated = false)
        try { adapter?.release() } catch (t: Throwable) { Log.w(TAG, "Failed releasing adapter during cleanup", t) }
        adapter = null
        try {
            @Suppress("DEPRECATION")
            surfaceProducer.setCallback(null)
        } catch (t: Throwable) {
            Log.w(TAG, "Failed clearing surface callback during cleanup", t)
        }
        lifecycleAdapter = null
    }

    private fun diagnosticMap(pass: Boolean, raw: String): Map<String, Any?> {
        val isSurfaceLost = surfaceLost.get() || state == AndroidDagPlaybackState.SurfaceLost
        // Include adaptive timeline telemetry -- diagnostic-only.
        val tlSnapshot = adaptiveTimelineController.snapshot()
        return mapOf(
            "pass" to pass,
            "state" to state.name,
            "textureId" to surfaceProducer.id(),
            "sessionId" to sessionId,
            "generationId" to generationId,
            "renderedFrames" to renderedFrames,
            "lastRenderedPtsUs" to lastRenderedPtsUs,
            "surfaceLost" to isSurfaceLost,
            "lastError" to lastError,
            "raw" to raw,
            "adaptiveTimelineAttached" to true,
            "adaptiveTimeline" to tlSnapshot,
            "adaptiveTimelineAcceptedFrames" to (tlSnapshot["acceptedFrames"] as? Number)?.toLong(),
            "adaptiveTimelineGenerationId" to (tlSnapshot["generationId"] as? Number)?.toLong(),
            "adaptiveTimelineStarted" to (tlSnapshot["isStarted"] as? Boolean),
            "adaptiveTimelineLastAcceptedPtsUs" to (tlSnapshot["lastAcceptedPtsUs"] as? Number)?.toLong(),
            "adaptiveTimelineLastAcceptedFrameIndex" to (tlSnapshot["lastAcceptedFrameIndex"] as? Number)?.toLong(),
        )
    }
}
