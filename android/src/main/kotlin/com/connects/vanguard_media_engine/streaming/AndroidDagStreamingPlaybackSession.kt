// Copyright (c) Connects - Phase 4C1D1A: Android True-DAG Streaming Playback Session.
// Non-exposed streaming session class bridging Media3 ExoPlayer decode frames to native DAG Vulkan render.
// Phase 4C4J-M: Adaptive stream timeline telemetry (diagnostic-only).

package com.connects.vanguard_media_engine.streaming

import android.content.Context
import android.os.Build
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

    // Android LL-HLS experiment: eligibility is decided exactly once here and never re-evaluated.
    // Ordinary sessions (experimentalLlhls=false) keep every pre-existing code path unchanged.
    private val experimentalLlhls: Boolean =
        AndroidLlhlsProfile.isEligible(streamConfig, Build.VERSION.SDK_INT)

    /** Sticky non-surface failure latch (experimental only). Never cleared. */
    private val experimentalFailed = AtomicBoolean(false)

    /** Stop latch (experimental only): a stopped experimental session requires a new open. */
    private val experimentalStopped = AtomicBoolean(false)

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
    private var currentRotationDegrees: Int = 0
    private var currentDisplayWidth: Int = initialWidth
    private var currentDisplayHeight: Int = initialHeight
    private var renderedFrames: Int = 0
    private var lastRenderedPtsUs: Long = 0L
    private var lastError: String? = null

    // Phase 4C7W: Stream playback timing and buffer telemetry fields.
    private var currentDurationMs: Long = -1L
    private var currentPositionMs: Long = 0L
    private var currentBufferedPercent: Int = 0
    private var currentBufferedPositionMs: Long = 0L
    private var currentLiveOffsetMs: Long? = null

    // Phase 4C6P: Playback cache event telemetry fields (protected by renderLock).
    private var playbackCacheEnabled: Boolean = false
    private var playbackCacheTelemetryAttached: Boolean = false
    private var playbackCacheBytesRead: Long = 0L
    private var playbackCacheSizeBytes: Long = 0L
    private var playbackCacheIgnoredCount: Int = 0
    private var playbackCacheLastIgnoredReason: String? = null

    /**
     * Updates playback timing and buffer telemetry from adapter state transitions or buffering callbacks.
     * Diagnostic-only; does not alter native rendering or ABR behavior.
     */
    private fun recordPlaybackTelemetry(
        positionMs: Long? = null,
        durationMs: Long? = null,
        bufferedPercent: Int? = null,
    ) {
        synchronized(renderLock) {
            if (positionMs != null && positionMs >= 0L) {
                currentPositionMs = positionMs
            }
            if (durationMs != null) {
                currentDurationMs = if (durationMs < 0L) -1L else durationMs
            }
            if (bufferedPercent != null) {
                currentBufferedPercent = bufferedPercent.coerceIn(0, 100)
            }
            if (currentDurationMs > 0L) {
                val bufferedAbsolutePositionMs = (currentDurationMs * currentBufferedPercent) / 100L
                currentBufferedPositionMs = (bufferedAbsolutePositionMs - currentPositionMs)
                    .coerceAtLeast(0L)
                    .coerceAtMost(currentDurationMs)
            } else {
                currentBufferedPositionMs = 0L
            }
        }
    }

    /**
     * Updates playback cache event telemetry from CacheDataSource event listener callbacks.
     * Diagnostic-only; does not alter native rendering, ABR, or playback timing.
     */
    private fun recordPlaybackCacheTelemetry(
        cacheSizeBytes: Long,
        cachedBytesReadDelta: Long,
        cacheIgnoredDelta: Int,
        lastCacheIgnoredReason: String?,
    ) {
        synchronized(renderLock) {
            if (cacheSizeBytes >= 0L) {
                playbackCacheSizeBytes = cacheSizeBytes
            }
            if (cachedBytesReadDelta > 0L) {
                playbackCacheBytesRead += cachedBytesReadDelta
            }
            if (cacheIgnoredDelta > 0) {
                playbackCacheIgnoredCount += cacheIgnoredDelta
            }
            if (lastCacheIgnoredReason != null) {
                playbackCacheLastIgnoredReason = lastCacheIgnoredReason
            }
        }
    }

    /**
     * Single write path for [state]. Ordinary sessions assign directly (unchanged behaviour).
     * Experimental sessions apply, under renderLock, the latch priority
     * Disposed > sticky Failed > stopped Idle > ordinary transition, so late adapter callbacks
     * (Idle after Failed, Ready/Playing after Stop) can neither mask a terminal failure nor revive
     * a stopped session.
     */
    private fun setState(next: AndroidDagPlaybackState) {
        if (!experimentalLlhls) {
            state = next
            return
        }
        synchronized(renderLock) {
            state = when {
                disposed.get() -> AndroidDagPlaybackState.Disposed
                experimentalFailed.get() -> AndroidDagPlaybackState.Failed
                experimentalStopped.get() -> AndroidDagPlaybackState.Idle
                else -> next
            }
        }
    }

    /**
     * State as reported by diagnostics. Ordinary sessions report [state] as-is. Experimental
     * sessions apply the same latch priority as [setState], so a latch set on the adapter thread
     * is visible even before its matching state write lands.
     */
    private fun reportedState(): AndroidDagPlaybackState {
        val current = state
        if (!experimentalLlhls) return current
        return when {
            current == AndroidDagPlaybackState.Disposed || disposed.get() -> AndroidDagPlaybackState.Disposed
            experimentalFailed.get() -> AndroidDagPlaybackState.Failed
            experimentalStopped.get() -> AndroidDagPlaybackState.Idle
            else -> current
        }
    }

    /**
     * Android LL-HLS experiment: Play and Seek are rejected after a sticky failure or after Stop.
     * Returns the rejection result, or null when the control may proceed. Ordinary sessions never
     * reject here.
     */
    private fun experimentalControlRejection(): Map<String, Any?>? {
        if (!experimentalLlhls) return null
        if (experimentalFailed.get()) {
            return diagnosticMap(pass = false, raw = "status=FAIL;reason=failed_session;state=Failed;lastError=${lastError ?: "unknown"}")
        }
        if (experimentalStopped.get()) {
            return diagnosticMap(pass = false, raw = "status=FAIL;reason=stopped_requires_new_session")
        }
        return null
    }

    /** Experimental terminal condition; native-affecting paths evaluate it under renderLock. */
    private fun experimentalTerminal(): Boolean =
        experimentalLlhls && (experimentalFailed.get() || experimentalStopped.get())

    /**
     * Experimental sessions serialize control acceptance, state write, adapter dispatch and the
     * result snapshot under renderLock, so a failure latched on the adapter thread cannot land
     * between the terminal check and the reported result. Ordinary sessions run [block] directly.
     * Callers publish adapter intent/stop markers (synchronous atomics) before entering.
     */
    private inline fun <T> controlSection(block: () -> T): T =
        if (experimentalLlhls) synchronized(renderLock, block) else block()

    /**
     * Control result snapshot. Ordinary sessions report the requested state literally (unchanged).
     * Experimental sessions report the latched state so results always agree with diagnostics.
     */
    private fun controlResult(okState: AndroidDagPlaybackState, extra: String = ""): Map<String, Any?> {
        if (!experimentalLlhls) return diagnosticMap(pass = true, raw = "status=OK;state=${okState.name}$extra")
        return when (val reported = reportedState()) {
            AndroidDagPlaybackState.Failed ->
                diagnosticMap(pass = false, raw = "status=FAIL;reason=failed_session;state=Failed;lastError=${lastError ?: "unknown"}")
            AndroidDagPlaybackState.Disposed ->
                diagnosticMap(pass = false, raw = "status=FAIL;reason=disposed")
            else -> diagnosticMap(pass = true, raw = "status=OK;state=${reported.name}$extra")
        }
    }

    /** Prepares adaptive streaming playback and native True-DAG rendering pipeline. */
    fun prepare(onResult: (Map<String, Any?>) -> Unit) {
        if (disposed.get()) {
            setState(AndroidDagPlaybackState.Failed)
            onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=disposed"))
            return
        }

        synchronized(renderLock) {
            if (disposed.get()) {
                setState(AndroidDagPlaybackState.Failed)
                onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=disposed"))
                return
            }

            try {
                setState(AndroidDagPlaybackState.Preparing)

                val adapterShim = AndroidDagSurfaceProducerLifecycleAdapter(
                    onAvailable = { handleSurfaceAvailable() },
                    onCleanup = { handleSurfaceCleanup() },
                ).also { lifecycleAdapter = it }
                @Suppress("DEPRECATION")
                surfaceProducer.setCallback(adapterShim)

                currentWidth = initialWidth
                currentHeight = initialHeight
                currentRotationDegrees = 0
                currentDisplayWidth = initialWidth
                currentDisplayHeight = initialHeight
                playbackCacheEnabled = streamConfig.cacheConfig.enabled
                playbackCacheTelemetryAttached = streamConfig.cacheConfig.enabled
                playbackCacheBytesRead = 0L
                playbackCacheSizeBytes = 0L
                playbackCacheIgnoredCount = 0
                playbackCacheLastIgnoredReason = null
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

                streamConfig.startPositionMs?.let { startMs ->
                    if (startMs > 0L) {
                        recordPlaybackTelemetry(positionMs = startMs)
                    }
                }

                val playbackListener = object : HttpAdaptivePlaybackListener {
                    override fun onStateChanged(newState: HttpAdaptivePlaybackState) {
                        if (disposed.get() || surfaceLost.get()) return
                        when (newState) {
                            is HttpAdaptivePlaybackState.Idle -> setState(AndroidDagPlaybackState.Idle)
                            is HttpAdaptivePlaybackState.Preparing -> setState(AndroidDagPlaybackState.Preparing)
                            is HttpAdaptivePlaybackState.Ready -> {
                                recordPlaybackTelemetry(durationMs = newState.durationMs)
                                setState(AndroidDagPlaybackState.Prepared)
                            }
                            is HttpAdaptivePlaybackState.Playing -> {
                                recordPlaybackTelemetry(
                                    positionMs = newState.positionMs,
                                    durationMs = newState.durationMs,
                                    bufferedPercent = newState.bufferedPercent,
                                )
                                setState(AndroidDagPlaybackState.Playing)
                            }
                            is HttpAdaptivePlaybackState.Paused -> {
                                recordPlaybackTelemetry(
                                    positionMs = newState.positionMs,
                                    durationMs = newState.durationMs,
                                )
                                setState(AndroidDagPlaybackState.Paused)
                            }
                            is HttpAdaptivePlaybackState.Buffering -> {
                                recordPlaybackTelemetry(bufferedPercent = newState.bufferedPercent)
                                if (state == AndroidDagPlaybackState.Preparing) setState(AndroidDagPlaybackState.Preparing)
                            }
                            is HttpAdaptivePlaybackState.Seeking -> {
                                recordPlaybackTelemetry(positionMs = newState.targetPositionMs)
                                setState(AndroidDagPlaybackState.Seeking)
                            }
                            is HttpAdaptivePlaybackState.Ended -> {
                                recordPlaybackTelemetry(
                                    positionMs = if (newState.durationMs > 0L) newState.durationMs else null,
                                    durationMs = newState.durationMs,
                                    bufferedPercent = 100,
                                )
                                setState(AndroidDagPlaybackState.Completed)
                            }
                            is HttpAdaptivePlaybackState.Failed -> {
                                failAndDestroyNativeSession("adapter_error:${newState.errorCode}:${newState.message}")
                            }
                            is HttpAdaptivePlaybackState.Released -> setState(AndroidDagPlaybackState.Disposed)
                        }
                    }

                    override fun onVideoSizeChanged(
                        width: Int,
                        height: Int,
                        rotationDegrees: Int,
                        displayWidth: Int,
                        displayHeight: Int,
                    ) = handleVideoSizeChanged(width, height, rotationDegrees, displayWidth, displayHeight)
                    override fun onBufferingProgress(bufferedPercent: Int) {
                        recordPlaybackTelemetry(bufferedPercent = bufferedPercent)
                    }
                    override fun onPlaybackError(errorCode: Int, message: String) {
                        failAndDestroyNativeSession("playback_error:$errorCode:$message")
                    }
                    override fun onPlaybackCacheTelemetry(
                        cacheSizeBytes: Long,
                        cachedBytesReadDelta: Long,
                        cacheIgnoredDelta: Int,
                        lastCacheIgnoredReason: String?,
                    ) {
                        recordPlaybackCacheTelemetry(
                            cacheSizeBytes = cacheSizeBytes,
                            cachedBytesReadDelta = cachedBytesReadDelta,
                            cacheIgnoredDelta = cacheIgnoredDelta,
                            lastCacheIgnoredReason = lastCacheIgnoredReason,
                        )
                    }
                }

                val ad = HttpAdaptivePlaybackAdapter(
                    context = context,
                    listener = playbackListener,
                    experimentalLlhls = experimentalLlhls,
                ).also { adapter = it }
                ad.enableHeadlessFrameBridge(initialWidth, initialHeight) { frame -> handleDecodedFrame(frame) }
                ad.prepare(streamConfig)
                setState(AndroidDagPlaybackState.Prepared)

                onResult(diagnosticMap(pass = true, raw = createResult))
            } catch (t: Throwable) {
                Log.e(TAG, "Error during prepare", t)
                lastError = "prepare_exception:${t.javaClass.simpleName}:${t.message}"
                cleanupFailedPrepare()
                onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=$lastError"))
            }
        }
    }

    /** Starts or resumes streaming playback. Ordinary resume; experimental recovery is never re-armed. */
    fun play(onResult: (Map<String, Any?>) -> Unit) {
        onResult(controlSection { playLocked() })
    }

    private fun playLocked(): Map<String, Any?> {
        if (disposed.get()) return diagnosticMap(pass = false, raw = "status=FAIL;reason=disposed")
        experimentalControlRejection()?.let { return it }
        if (surfaceLost.get() || state == AndroidDagPlaybackState.SurfaceLost) return diagnosticMap(pass = false, raw = "status=FAIL;reason=surface_lost")
        val ad = adapter ?: return diagnosticMap(pass = false, raw = "status=FAIL;reason=adapter_null")
        setState(AndroidDagPlaybackState.Playing)
        ad.play()
        return controlResult(AndroidDagPlaybackState.Playing)
    }

    /**
     * Pauses streaming playback while preserving buffers. The adapter publishes paused intent and
     * revokes experimental recovery synchronously before any lock wait. After a sticky experimental
     * failure the pause still dispatches (resource cleanup) but reports the preserved Failed state.
     */
    fun pause(onResult: (Map<String, Any?>) -> Unit) {
        if (disposed.get()) return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=disposed"))
        val ad = adapter ?: return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=adapter_null"))
        ad.pause()
        onResult(controlSection {
            if (state != AndroidDagPlaybackState.Disposed && state != AndroidDagPlaybackState.Failed && state != AndroidDagPlaybackState.SurfaceLost) {
                setState(AndroidDagPlaybackState.Paused)
            }
            controlResult(AndroidDagPlaybackState.Paused)
        })
    }

    /**
     * Seeks to [positionMs] milliseconds. Ordinary sessions keep the existing path: DAG generation
     * bump, then the seek is dispatched to the adapter. Experimental sessions use the adapter's
     * staged reservation ([seekExperimental]).
     */
    fun seekTo(positionMs: Long, onResult: (Map<String, Any?>) -> Unit) {
        if (disposed.get()) return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=disposed"))
        if (positionMs < 0L) return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=invalid_position;positionMs=$positionMs"))
        if (experimentalLlhls) return onResult(seekExperimental(positionMs))
        onResult(seekOrdinary(positionMs))
    }

    private fun seekOrdinary(positionMs: Long): Map<String, Any?> {
        if (surfaceLost.get() || state == AndroidDagPlaybackState.SurfaceLost) return diagnosticMap(pass = false, raw = "status=FAIL;reason=surface_lost")
        val ad = adapter ?: return diagnosticMap(pass = false, raw = "status=FAIL;reason=adapter_null")
        setState(AndroidDagPlaybackState.Seeking)
        recordPlaybackTelemetry(positionMs = positionMs)
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
        return controlResult(AndroidDagPlaybackState.Seeking, ";positionMs=$positionMs;generationId=$generationId")
    }

    /**
     * Android LL-HLS experiment: staged seek. The reservation (version, target, playback hold) is
     * published and recovery revoked through [HttpAdaptivePlaybackAdapter.beginSeek] before any
     * lock wait. Under renderLock the session rechecks disposed / failed / stopped / surface state
     * and native-session availability, performs the native generation work, then commits (the
     * adapter issues the SDK seek on its owner thread). Every non-committed exit cancels only this
     * ticket; a native failure uses the existing failure handling and issues no SDK seek.
     */
    private fun seekExperimental(positionMs: Long): Map<String, Any?> {
        val ad = adapter ?: return diagnosticMap(pass = false, raw = "status=FAIL;reason=adapter_null")
        val ticket = ad.beginSeek(positionMs)
        if (ticket == HttpAdaptivePlaybackControlState.NO_SEEK_TICKET) {
            return experimentalControlRejection()
                ?: diagnosticMap(pass = false, raw = "status=FAIL;reason=seek_rejected;positionMs=$positionMs")
        }
        var committed = false
        try {
            return synchronized(renderLock) {
                if (disposed.get()) return diagnosticMap(pass = false, raw = "status=FAIL;reason=disposed")
                experimentalControlRejection()?.let { return it }
                if (surfaceLost.get() || state == AndroidDagPlaybackState.SurfaceLost) return diagnosticMap(pass = false, raw = "status=FAIL;reason=surface_lost")
                val sid = sessionId ?: return diagnosticMap(pass = false, raw = "status=FAIL;reason=native_session_unavailable")

                // Native generation work precedes commit; a native failure issues no SDK seek.
                val bumpRes = nativeBridge.bumpAndroidDagPhase4B1TexturePlaybackGeneration(sid)
                if (!bumpRes.startsWith("status=OK;")) {
                    failAndDestroyNativeSession("generation_bump_failed_on_seek;$bumpRes", surfaceRelated = bumpRes.contains("surface_lost"))
                    return diagnosticMap(pass = false, raw = "status=FAIL;reason=generation_bump_failed_on_seek;$bumpRes")
                }
                val parsedGen = bumpRes.substringAfter("generationId=").substringBefore(";").toLongOrNull()
                if (parsedGen == null || parsedGen <= 0L) {
                    failAndDestroyNativeSession("generation_parse_failed_on_seek;$bumpRes", surfaceRelated = false)
                    return diagnosticMap(pass = false, raw = "status=FAIL;reason=generation_parse_failed_on_seek;$bumpRes")
                }
                generationId = parsedGen
                // Rebase adaptive timeline on seek -- diagnostic-only, does not affect rendering.
                adaptiveTimelineController.rebase("seek", System.nanoTime(), positionMs * 1000L)
                // Next decoded frame must re-anchor to actual post-seek PTS before evaluate().
                adaptiveTimelineNeedsFrameAnchor = true

                if (!ad.commitSeek(ticket)) {
                    // Superseded by a newer reservation, or invalidated by stop / release.
                    return diagnosticMap(pass = false, raw = "status=FAIL;reason=seek_superseded;positionMs=$positionMs;ticket=$ticket")
                }
                committed = true
                setState(AndroidDagPlaybackState.Seeking)
                recordPlaybackTelemetry(positionMs = positionMs)
                controlResult(AndroidDagPlaybackState.Seeking, ";positionMs=$positionMs;generationId=$generationId;ticket=$ticket")
            }
        } finally {
            if (!committed) ad.cancelSeek(ticket)
        }
    }

    /**
     * Stops streaming playback and resets adapter to idle. An experimental session latches
     * `stopped` and publishes the adapter stop marker synchronously before any lock wait: later
     * Play/Seek are rejected and a new open is required. After a sticky experimental failure the
     * stop still dispatches but reports the preserved Failed state.
     */
    fun stop(onResult: (Map<String, Any?>) -> Unit) {
        if (disposed.get()) return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=disposed"))
        val ad = adapter ?: return onResult(diagnosticMap(pass = false, raw = "status=FAIL;reason=adapter_null"))
        if (experimentalLlhls) experimentalStopped.set(true)
        ad.stop()
        onResult(controlSection {
            if (state != AndroidDagPlaybackState.Disposed && state != AndroidDagPlaybackState.Failed) setState(AndroidDagPlaybackState.Idle)
            controlResult(AndroidDagPlaybackState.Idle)
        })
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
        val reported = reportedState()
        val isSurfaceLost = surfaceLost.get() || reported == AndroidDagPlaybackState.SurfaceLost
        val rawStatus = if (reported == AndroidDagPlaybackState.Failed) "status=FAIL;state=${reported.name};reason=${lastError ?: "unknown"}" else "status=OK;state=${reported.name}"
        // Include adaptive timeline telemetry -- diagnostic-only.
        val tlSnapshot = adaptiveTimelineController.snapshot()
        // Phase 4C5B: streaming network profile/policy diagnostics -- diagnostic-only.
        val netPolicy = AdaptiveStreamingNetworkPolicy.forProfile(streamConfig.networkProfile)
        return mapOf(
            "pass" to (reported != AndroidDagPlaybackState.Failed),
            "state" to reported.name,
            "textureId" to surfaceProducer.id(),
            "sessionId" to sessionId,
            "generationId" to generationId,
            "durationMs" to currentDurationMs,
            "positionMs" to currentPositionMs,
            "bufferedPositionMs" to currentBufferedPositionMs,
            "bufferedPercent" to currentBufferedPercent,
            "liveOffsetMs" to currentLiveOffsetMs,
            "width" to currentDisplayWidth,
            "height" to currentDisplayHeight,
            "videoWidth" to currentWidth,
            "videoHeight" to currentHeight,
            "rotationDegrees" to currentRotationDegrees,
            "displayWidth" to currentDisplayWidth,
            "displayHeight" to currentDisplayHeight,
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
            "streamingNetworkProfile" to streamConfig.networkProfile.name,
            "streamingNetworkPolicy" to netPolicy.toDiagnosticMap(),
            "playbackCacheEnabled" to playbackCacheEnabled,
            "playbackCacheTelemetryAttached" to playbackCacheTelemetryAttached,
            "playbackCacheBytesRead" to playbackCacheBytesRead,
            "playbackCacheSizeBytes" to playbackCacheSizeBytes,
            "playbackCacheIgnoredCount" to playbackCacheIgnoredCount,
            "playbackCacheLastIgnoredReason" to playbackCacheLastIgnoredReason,
        ) + experimentalDiagnostics()
    }

    /** Android LL-HLS experiment diagnostics (diagnostic-only; latches are authoritative). */
    private fun experimentalDiagnostics(): Map<String, Any?> = mapOf(
        "androidLlhlsExperimentRequested" to streamConfig.androidLlhlsExperiment,
        "androidLlhlsExperimentActive" to experimentalLlhls,
        "androidLlhlsFailedLatched" to experimentalFailed.get(),
        "androidLlhlsStoppedLatched" to experimentalStopped.get(),
        "androidLlhlsRecovery" to adapter?.recoveryDiagnostic(),
        "androidLlhlsProfile" to if (experimentalLlhls) AndroidLlhlsProfile.toDiagnosticMap() else null,
    )

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
            setState(AndroidDagPlaybackState.Disposed)
            onResult?.invoke(diagnosticMap(pass = true, raw = "status=OK;disposed=true"))
        } catch (t: Throwable) {
            Log.e(TAG, "Error during dispose", t)
            setState(AndroidDagPlaybackState.Disposed)
            onResult?.invoke(diagnosticMap(pass = true, raw = "status=OK;disposed_with_error:${t.javaClass.simpleName}"))
        }
    }

    private fun failAndDestroyNativeSession(reason: String, surfaceRelated: Boolean = false) {
        try {
            synchronized(renderLock) {
                lastError = reason
                // Android LL-HLS experiment: latch before native destruction so no late callback
                // can clear the failure. Surface loss only revokes recovery; restoration stays
                // possible through the existing handleSurfaceAvailable path. Disposal dominates.
                if (experimentalLlhls && !disposed.get()) {
                    if (surfaceRelated) {
                        adapter?.disableRecovery("surface_loss:$reason")
                    } else {
                        experimentalFailed.set(true)
                        adapter?.disableRecovery("failure:$reason")
                        // Fatal: dispatch the existing stop cleanup (synchronous stop marker plus
                        // queued player stop). The latch keeps Failed over the resulting Idle.
                        adapter?.stop()
                    }
                }
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
                        setState(AndroidDagPlaybackState.SurfaceLost)
                    } else {
                        surfaceLost.set(false)
                        setState(AndroidDagPlaybackState.Failed)
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
            if (experimentalTerminal()) return
            val sid = sessionId ?: return
            val hwBuf = frame.hardwareBuffer
            val ptsUs = frame.ptsUs
            val fIndex = frame.frameIndex.toInt()
            val gen = generationId
            val renderWidth = if (currentDisplayWidth > 0) currentDisplayWidth else if (currentWidth > 0) currentWidth else frame.width
            val renderHeight = if (currentDisplayHeight > 0) currentDisplayHeight else if (currentHeight > 0) currentHeight else frame.height
            val rot = currentRotationDegrees

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
                    width = renderWidth,
                    height = renderHeight,
                    timelinePtsUs = ptsUs,
                    frameIndex = fIndex,
                    generationId = gen,
                    rotationDegrees = rot,
                    mirrorHorizontal = false,
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

    private fun handleVideoSizeChanged(
        width: Int,
        height: Int,
        rotationDegrees: Int = 0,
        displayWidth: Int = width,
        displayHeight: Int = height,
    ) {
        if (width <= 0 || height <= 0) return

        synchronized(renderLock) {
            // Android LL-HLS experiment: a latched failure or stop is terminal; late size
            // callbacks must not recreate native rendering.
            if (experimentalTerminal()) return
            currentWidth = width
            currentHeight = height
            currentRotationDegrees = rotationDegrees
            val targetDisplayWidth = if (displayWidth > 0) displayWidth else width
            val targetDisplayHeight = if (displayHeight > 0) displayHeight else height
            currentDisplayWidth = targetDisplayWidth
            currentDisplayHeight = targetDisplayHeight
            try {
                surfaceProducer.setSize(targetDisplayWidth, targetDisplayHeight)
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
                val createResult = nativeBridge.createAndroidDagPhase4B1TexturePlaybackSession(surface, targetDisplayWidth, targetDisplayHeight)
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
            // Android LL-HLS experiment: no restoration after a latched failure or stop.
            if (experimentalTerminal()) {
                Log.d(TAG, "handleSurfaceAvailable: experimental session is terminal; not restoring")
                return
            }

            try {
                val restoreDisplayWidth = if (currentDisplayWidth > 0) currentDisplayWidth else if (currentWidth > 0) currentWidth else initialWidth
                val restoreDisplayHeight = if (currentDisplayHeight > 0) currentDisplayHeight else if (currentHeight > 0) currentHeight else initialHeight
                surfaceProducer.setSize(restoreDisplayWidth, restoreDisplayHeight)
                val surface = surfaceProducer.getSurface().also { flutterSurface = it }

                val createResult = nativeBridge.createAndroidDagPhase4B1TexturePlaybackSession(surface, restoreDisplayWidth, restoreDisplayHeight)
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
                if (!disposed.get()) setState(AndroidDagPlaybackState.Paused)
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
        val reported = reportedState()
        val isSurfaceLost = surfaceLost.get() || reported == AndroidDagPlaybackState.SurfaceLost
        // Include adaptive timeline telemetry -- diagnostic-only.
        val tlSnapshot = adaptiveTimelineController.snapshot()
        // Phase 4C5B: streaming network profile/policy diagnostics -- diagnostic-only.
        val netPolicy = AdaptiveStreamingNetworkPolicy.forProfile(streamConfig.networkProfile)
        return mapOf(
            "pass" to pass,
            "state" to reported.name,
            "textureId" to surfaceProducer.id(),
            "sessionId" to sessionId,
            "generationId" to generationId,
            "durationMs" to currentDurationMs,
            "positionMs" to currentPositionMs,
            "bufferedPositionMs" to currentBufferedPositionMs,
            "bufferedPercent" to currentBufferedPercent,
            "liveOffsetMs" to currentLiveOffsetMs,
            "width" to currentDisplayWidth,
            "height" to currentDisplayHeight,
            "videoWidth" to currentWidth,
            "videoHeight" to currentHeight,
            "rotationDegrees" to currentRotationDegrees,
            "displayWidth" to currentDisplayWidth,
            "displayHeight" to currentDisplayHeight,
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
            "streamingNetworkProfile" to streamConfig.networkProfile.name,
            "streamingNetworkPolicy" to netPolicy.toDiagnosticMap(),
            "playbackCacheEnabled" to playbackCacheEnabled,
            "playbackCacheTelemetryAttached" to playbackCacheTelemetryAttached,
            "playbackCacheBytesRead" to playbackCacheBytesRead,
            "playbackCacheSizeBytes" to playbackCacheSizeBytes,
            "playbackCacheIgnoredCount" to playbackCacheIgnoredCount,
            "playbackCacheLastIgnoredReason" to playbackCacheLastIgnoredReason,
        ) + experimentalDiagnostics()
    }
}
