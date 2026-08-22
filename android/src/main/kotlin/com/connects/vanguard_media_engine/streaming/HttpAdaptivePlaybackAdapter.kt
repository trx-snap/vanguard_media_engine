// Copyright (c) Connects - Phase 4C1B: HttpAdaptivePlaybackAdapter scaffold.
// Scaffold only. No live network streaming is claimed or verified here.
// Physical network streaming proof is deferred to Phase 4C device validation.

package com.connects.vanguard_media_engine.streaming

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Android Media3 / ExoPlayer adaptive HTTP streaming adapter scaffold.
 *
 * Supports HLS (including LL-HLS delta segments), DASH (MPD multi-period), and automatic format
 * detection for a single adaptive HTTP stream.  All ExoPlayer lifecycle operations execute on a
 * private [HandlerThread] named `HttpAdaptivePlaybackLoop_<id>`, keeping HTTP I/O, manifest
 * polling, codec initialisation, and ABR decisions off the Flutter UI thread.
 *
 * ## Threading Model
 * - Public API methods may be called from any thread.
 * - Every method that touches [player] posts a lambda to [handler] (the HandlerThread's Handler).
 * - [Player.Listener] callbacks are automatically dispatched on the HandlerThread because the
 *   ExoPlayer instance was built with `setLooper(handlerThread.looper)`.
 * - [listener] callbacks are therefore also invoked on the HandlerThread.
 *
 * ## Surface Binding
 * - The caller supplies an optional [android.view.Surface] via [setSurface].
 * - Internally, `ExoPlayer.setVideoSurface(surface)` / `setVideoSurface(null)` is used.
 * - [setVideoSurface] null is enforced **before** player stop/release and on surface loss.
 * - No [android.media.ImageReader] is allocated in this scaffold phase; wiring to the Vanguard
 *   True-DAG ImageReader pipeline is deferred to Phase 4C4.
 *
 * ## Release Contract
 * - [release] is idempotent and terminal.  Once released, all subsequent public calls are no-ops.
 * - Release order:  detach surface -> stop player -> release player -> quit HandlerThread.
 *
 * ## Non-Goals (scaffold boundary)
 * - No ConnectsApp wiring, no WebRTC/LiveKit transport, no DRM licensing.
 * - No working end-to-end streaming claim.  Compile-only scaffold for Phase 4C1B.
 *
 * @param context   Android [Context] used to build [ExoPlayer].  Must be a valid application or
 *                  plugin context; must not be an Activity context that may be destroyed.
 * @param listener  Event listener.  Callbacks are always dispatched on the HandlerThread.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class HttpAdaptivePlaybackAdapter(
    private val context: Context,
    private val listener: HttpAdaptivePlaybackListener,
) {

    // --- Identity ----------------------------------------------------------------------------

    private val id: Long = nextId.getAndIncrement()

    // --- HandlerThread / Handler -------------------------------------------------------------

    /**
     * Dedicated background thread owning all ExoPlayer access.  Named for easy identification in
     * profilers and thread dumps.
     */
    private val handlerThread: HandlerThread =
        HandlerThread("HttpAdaptivePlaybackLoop_$id").also { it.start() }

    /**
     * Handler backed by [handlerThread].  All player API calls are posted here.
     */
    private val handler: Handler = Handler(handlerThread.looper)

    // --- State -------------------------------------------------------------------------------

    /** Guards against double-release.  Once true, all public methods are no-ops. */
    private val released: AtomicBoolean = AtomicBoolean(false)

    /** Current playback state.  Only read/written on the HandlerThread. */
    @Volatile
    private var currentState: HttpAdaptivePlaybackState = HttpAdaptivePlaybackState.Idle

    // --- Player ------------------------------------------------------------------------------

    /**
     * ExoPlayer instance.  Created lazily on [handler] during [prepare].  All access must be on
     * the HandlerThread.
     */
    private var player: ExoPlayer? = null

    /** Pending surface to bind once the player exists (set before prepare is called). */
    private var pendingSurface: Surface? = null

    /** Pending seek to apply once [Player.STATE_READY] is first reached. */
    private var pendingSeekMs: Long? = null

    /** Current stream configuration.  Set during [prepare]. */
    private var activeConfig: HttpAdaptiveStreamConfig? = null

    // --- Player.Listener ---------------------------------------------------------------------

    /**
     * Bridges Media3 [Player.Listener] events into typed [HttpAdaptivePlaybackState] transitions.
     * All callbacks execute on the HandlerThread (guaranteed by `setLooper` during player build).
     */
    private val playerListener = object : Player.Listener {

        override fun onPlaybackStateChanged(playbackState: Int) {
            val p = player ?: return
            when (playbackState) {
                Player.STATE_BUFFERING -> {
                    val pct = p.bufferedPercentage
                    emitState(HttpAdaptivePlaybackState.Buffering(pct))
                    listener.onBufferingProgress(pct)
                }
                Player.STATE_READY -> {
                    // Apply deferred seek before emitting Ready
                    pendingSeekMs?.let { seekMs ->
                        pendingSeekMs = null
                        p.seekTo(seekMs)
                        emitState(HttpAdaptivePlaybackState.Seeking(seekMs))
                        return
                    }
                    val duration = p.duration
                    val size = p.videoSize
                    if (p.playWhenReady) {
                        emitState(
                            HttpAdaptivePlaybackState.Playing(
                                positionMs = p.currentPosition,
                                durationMs = duration,
                                bufferedPercent = p.bufferedPercentage,
                            )
                        )
                    } else {
                        emitState(
                            HttpAdaptivePlaybackState.Ready(
                                durationMs = duration,
                                videoWidth = size.width,
                                videoHeight = size.height,
                            )
                        )
                    }
                }
                Player.STATE_ENDED -> {
                    val duration = p.duration
                    emitState(HttpAdaptivePlaybackState.Ended(durationMs = duration))
                }
                Player.STATE_IDLE -> {
                    // Reached after stop(); do not re-emit Idle if already releasing.
                    if (!released.get()) {
                        emitState(HttpAdaptivePlaybackState.Idle)
                    }
                }
            }
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            val p = player ?: return
            if (isPlaying) {
                emitState(
                    HttpAdaptivePlaybackState.Playing(
                        positionMs = p.currentPosition,
                        durationMs = p.duration,
                        bufferedPercent = p.bufferedPercentage,
                    )
                )
            } else {
                // Only emit Paused if we're not in a terminal or transitional state.
                val s = currentState
                if (s is HttpAdaptivePlaybackState.Playing) {
                    emitState(
                        HttpAdaptivePlaybackState.Paused(
                            positionMs = p.currentPosition,
                            durationMs = p.duration,
                        )
                    )
                }
            }
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            listener.onVideoSizeChanged(videoSize.width, videoSize.height)
        }

        override fun onPlayerError(error: PlaybackException) {
            val msg = "errorCode=${error.errorCode}; ${error.message ?: "unknown"}"
            val failedState = HttpAdaptivePlaybackState.Failed(
                errorCode = error.errorCode,
                message = msg,
            )
            emitState(failedState)
            listener.onPlaybackError(error.errorCode, msg)
        }
    }

    // --- Public API --------------------------------------------------------------------------

    /**
     * Prepares a new adaptive streaming session using [config].
     *
     * If a player is already running from a previous prepare call, it is stopped and released
     * before the new session is initialised.  Safe to call from any thread.
     *
     * @param config Stream configuration.  Must pass its own local validation invariants.
     */
    fun prepare(config: HttpAdaptiveStreamConfig) {
        if (released.get()) return
        handler.post {
            if (released.get()) return@post
            // Tear down any existing player before re-preparing.
            tearDownPlayerOnHandlerThread()

            activeConfig = config
            pendingSeekMs = config.startPositionMs

            emitState(HttpAdaptivePlaybackState.Preparing)

            val exo = ExoPlayer.Builder(context)
                .setLooper(handlerThread.looper)
                .build()

            exo.addListener(playerListener)
            exo.playWhenReady = config.autoPlay

            // Bind pending surface if the caller set it before prepare().
            val surface = pendingSurface
            if (surface != null) {
                exo.setVideoSurface(surface)
            }

            val mediaSource = buildMediaSource(config)
            exo.setMediaSource(mediaSource)
            exo.prepare()

            player = exo
        }
    }

    /**
     * Starts or resumes playback.  A no-op if the player is not prepared or already playing.
     * Safe to call from any thread.
     */
    fun play() {
        if (released.get()) return
        handler.post {
            if (released.get()) return@post
            player?.playWhenReady = true
        }
    }

    /**
     * Pauses playback.  Buffers are preserved.  Safe to call from any thread.
     */
    fun pause() {
        if (released.get()) return
        handler.post {
            if (released.get()) return@post
            player?.playWhenReady = false
        }
    }

    /**
     * Seeks to [positionMs] milliseconds.
     *
     * If the player has not yet reached [Player.STATE_READY], the position is cached and applied
     * automatically once ready (deferred seek).  Safe to call from any thread.
     *
     * @param positionMs Target playhead position in milliseconds.  Must be >= 0.
     */
    fun seekTo(positionMs: Long) {
        require(positionMs >= 0L) { "seekTo: positionMs must be >= 0, got $positionMs" }
        if (released.get()) return
        handler.post {
            if (released.get()) return@post
            val p = player
            if (p == null) {
                // Not yet prepared; store as pending seek.
                pendingSeekMs = positionMs
                return@post
            }
            val state = p.playbackState
            if (state == Player.STATE_IDLE || state == Player.STATE_BUFFERING) {
                // Defer: player not ready to accept a seek yet.
                pendingSeekMs = positionMs
                emitState(HttpAdaptivePlaybackState.Seeking(positionMs))
            } else {
                pendingSeekMs = null
                p.seekTo(positionMs)
                emitState(HttpAdaptivePlaybackState.Seeking(positionMs))
            }
        }
    }

    /**
     * Stops the current playback and returns the player to [Player.STATE_IDLE].  Network loaders
     * are cancelled and decoders released.  The adapter may be re-prepared via [prepare].
     * Safe to call from any thread.
     */
    fun stop() {
        if (released.get()) return
        handler.post {
            if (released.get()) return@post
            player?.stop()
            // STATE_IDLE callback from playerListener will emit Idle state.
        }
    }

    /**
     * Binds [surface] as the video output target.  If the player is already active, the surface
     * is attached immediately via `ExoPlayer.setVideoSurface(surface)`.  If [prepare] has not
     * been called yet, the surface is stored and applied when [prepare] creates the player.
     * Safe to call from any thread.
     *
     * @param surface Target [Surface] for video frame output.  Must not be null.
     */
    fun setSurface(surface: Surface) {
        if (released.get()) return
        handler.post {
            if (released.get()) return@post
            pendingSurface = surface
            player?.setVideoSurface(surface)
        }
    }

    /**
     * Detaches the current video surface.  On surface loss the player is intentionally paused
     * (`playWhenReady = false`) before the surface is detached so that the emitted
     * [HttpAdaptivePlaybackState.Paused] state is honest: the player is not actively rendering
     * and will not attempt to write frames to a destroyed surface handle.
     *
     * Must be called when the surface is destroyed or becomes invalid.
     * Safe to call from any thread.
     */
    fun clearSurface() {
        if (released.get()) return
        handler.post {
            if (released.get()) return@post
            val p = player
            // 1. Pause before detaching; ensures playWhenReady=false before surface is nulled.
            p?.playWhenReady = false
            // 2. Detach the surface so no decoder writes land on the invalidated handle.
            p?.setVideoSurface(null)
            // 3. Clear stored surface reference so a future prepare() does not rebind it.
            pendingSurface = null
            // 4. Emit Paused if the player exists and we were in an active state.
            //    onIsPlayingChanged will also fire; the guard on currentState prevents double-emit.
            if (p != null) {
                val s = currentState
                if (s is HttpAdaptivePlaybackState.Playing ||
                    s is HttpAdaptivePlaybackState.Ready ||
                    s is HttpAdaptivePlaybackState.Buffering
                ) {
                    emitState(
                        HttpAdaptivePlaybackState.Paused(
                            positionMs = p.currentPosition,
                            durationMs = p.duration,
                        )
                    )
                }
            }
        }
    }


    /**
     * Releases all resources.  Terminal and idempotent.
     *
     * Release order (executed on the HandlerThread):
     * 1. `player.setVideoSurface(null)` - detach surface before decoder teardown.
     * 2. `player.stop()` - cancel active network loaders and buffer allocations.
     * 3. `player.release()` - destroy MediaCodec decoders and audio sinks.
     * 4. `handlerThread.quitSafely()` - shut down the dedicated Looper.
     *
     * Safe to call from any thread.  Subsequent calls are no-ops.
     */
    fun release() {
        if (!released.compareAndSet(false, true)) return // idempotent guard
        handler.post {
            tearDownPlayerOnHandlerThread()
            // Full release: clear surface reference so it cannot be rebound by any lingering post.
            pendingSurface = null
            emitState(HttpAdaptivePlaybackState.Released)
            handlerThread.quitSafely()
        }
    }

    // --- Internal helpers (HandlerThread only) -----------------------------------------------

    /**
     * Performs ordered player teardown.  Must only be called from the HandlerThread.
     * Safe to call when [player] is null (no-op).
     *
     * **Intentionally does NOT clear [pendingSurface].**  If this teardown is triggered by
     * [prepare] (re-prepare), the caller's previously set surface remains valid and is rebound
     * to the new ExoPlayer instance.  Only [release] (full teardown) and [clearSurface]
     * (explicit surface loss) are permitted to clear [pendingSurface].
     */
    private fun tearDownPlayerOnHandlerThread() {
        val p = player ?: return
        player = null
        pendingSeekMs = null

        // 1. Detach surface before any decoder teardown.
        p.setVideoSurface(null)
        // 2. Cancel active network loaders / buffer allocations.
        p.stop()
        // 3. Destroy MediaCodec decoders and audio sinks.
        p.removeListener(playerListener)
        p.release()
        // HandlerThread quitSafely() is called separately in release() after emitting Released.
    }

    /**
     * Emits [newState] to the listener and updates [currentState].
     * Must only be called from the HandlerThread.
     */
    private fun emitState(newState: HttpAdaptivePlaybackState) {
        currentState = newState
        listener.onStateChanged(newState)
    }

    /**
     * Constructs the appropriate [MediaSource] for [config].
     *
     * - [AdaptiveStreamFormat.HLS]  -> [HlsMediaSource] (forces HLS even if URI lacks .m3u8).
     * - [AdaptiveStreamFormat.DASH] -> [DashMediaSource] (forces DASH MPD parsing).
     * - [AdaptiveStreamFormat.AUTO] -> [DefaultMediaSourceFactory] (sniffs URI extension / MIME).
     *
     * Must only be called from the HandlerThread (called during [prepare]).
     */
    private fun buildMediaSource(config: HttpAdaptiveStreamConfig): MediaSource {
        val uri = android.net.Uri.parse(config.uri)

        return when (config.formatHint) {
            AdaptiveStreamFormat.HLS -> {
                val mediaItem = MediaItem.Builder()
                    .setUri(uri)
                    .setMimeType(MimeTypes.APPLICATION_M3U8)
                    .build()
                HlsMediaSource.Factory(buildHttpDataSourceFactory(config.httpHeaders))
                    .createMediaSource(mediaItem)
            }
            AdaptiveStreamFormat.DASH -> {
                val mediaItem = MediaItem.Builder()
                    .setUri(uri)
                    .setMimeType(MimeTypes.APPLICATION_MPD)
                    .build()
                DashMediaSource.Factory(buildHttpDataSourceFactory(config.httpHeaders))
                    .createMediaSource(mediaItem)
            }
            AdaptiveStreamFormat.AUTO -> {
                val mediaItem = MediaItem.fromUri(uri)
                DefaultMediaSourceFactory(buildHttpDataSourceFactory(config.httpHeaders))
                    .createMediaSource(mediaItem)
            }
        }
    }

    /**
     * Builds a [DefaultHttpDataSource.Factory] and applies [httpHeaders] (if any) via
     * [DefaultHttpDataSource.Factory.setDefaultRequestProperties].
     *
     * This is the correct API for forwarding custom headers to every HTTP request (manifest
     * fetch, segment download, encryption key request) issued by Media3's network loaders.
     * The headers are set once on the factory and applied to all [DefaultHttpDataSource]
     * instances it creates.
     *
     * Must only be called from the HandlerThread.
     *
     * @param httpHeaders Optional header map from [HttpAdaptiveStreamConfig.httpHeaders].
     *                    Null or empty means no custom headers.
     */
    private fun buildHttpDataSourceFactory(
        httpHeaders: Map<String, String>?,
    ): DefaultHttpDataSource.Factory {
        val factory = DefaultHttpDataSource.Factory()
        if (!httpHeaders.isNullOrEmpty()) {
            factory.setDefaultRequestProperties(httpHeaders)
        }
        return factory
    }

    // --- Companion ---------------------------------------------------------------------------

    companion object {
        /** Monotonically increasing counter used to produce unique HandlerThread names. */
        private val nextId: AtomicLong = AtomicLong(0L)
    }
}
