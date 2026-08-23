// Copyright (c) Connects - Phase 4C1C: HttpAdaptivePlaybackAdapter with headless ImageReader bridge.
// Phase 4C5B: Streaming network profile policy (AdaptiveStreamingNetworkPolicy) applied in prepare().
// Scaffold with headless decode surface bridge enabled.  No live network streaming is claimed or
// verified here.  Physical network streaming proof is deferred to Phase 4C device validation.

package com.connects.vanguard_media_engine.streaming

import android.content.Context
import android.os.Build
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
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Android Media3 / ExoPlayer adaptive HTTP streaming adapter.
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
 * - `setVideoSurface(null)` is enforced **before** player stop/release and on surface loss.
 * - [setSurface] and [enableHeadlessFrameBridge] are mutually exclusive outputs: activating one
 *   disables and releases the other.
 *
 * ## Headless Frame Bridge (Phase 4C1C)
 * - [enableHeadlessFrameBridge] creates an [HttpAdaptiveImageReaderBridge] that routes decoded
 *   frames through an [android.media.ImageReader] -> [android.hardware.HardwareBuffer] pipeline.
 * - This is the decode surface -> HardwareBuffer slice.  Native DAG render wiring is deferred
 *   to Phase 4C1D.
 * - ABR / rendition resolution changes detected via [Player.Listener.onVideoSizeChanged] trigger
 *   automatic bridge recreation to match the new dimensions.
 * - Requires API 29+ (Android 10 / Q).
 *
 * ## Release Contract
 * - [release] is idempotent and terminal.  Once released, all subsequent public calls are no-ops.
 * - Release order:  detach surface -> stop player -> release player -> release headless bridge ->
 *   quit HandlerThread.
 *
 * ## Non-Goals (current boundary)
 * - No ConnectsApp wiring, no WebRTC/LiveKit transport, no DRM licensing.
 * - No native DAG render wiring (deferred to Phase 4C1D).
 * - No working end-to-end streaming claim.
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

    /** Pending external surface to bind once the player exists (set before prepare is called).
     *  Mutually exclusive with [headlessBridge]: activating the bridge clears this field. */
    private var pendingSurface: Surface? = null

    /** Pending seek to apply once [Player.STATE_READY] is first reached. */
    private var pendingSeekMs: Long? = null

    /** Current stream configuration.  Set during [prepare]. */
    private var activeConfig: HttpAdaptiveStreamConfig? = null

    /**
     * Network policy resolved for the currently prepared player (Phase 4C5B).
     * Set in [prepare] from [AdaptiveStreamingNetworkPolicy.forProfile].
     * Cleared to null in [tearDownPlayerOnHandlerThread] so it is absent after teardown/release.
     */
    private var activeNetworkPolicy: AdaptiveStreamingNetworkPolicy? = null

    // --- Headless bridge state (Phase 4C1C) --------------------------------------------------

    /**
     * Active headless ImageReader bridge.  Non-null when [enableHeadlessFrameBridge] has been
     * called and [disableHeadlessFrameBridge] / [clearSurface] / [release] has not yet run.
     * Only accessed on the HandlerThread.
     */
    private var headlessBridge: HttpAdaptiveImageReaderBridge? = null

    /**
     * Frame listener stored so that bridge recreation (on ABR resize) can reuse it without
     * requiring the caller to call [enableHeadlessFrameBridge] again.
     * Only accessed on the HandlerThread.
     */
    private var headlessFrameListener: HttpAdaptiveFrameListener? = null

    // --- Player.Listener ---------------------------------------------------------------------

    /**
     * Bridges Media3 [Player.Listener] events into typed [HttpAdaptivePlaybackState] transitions.
     * All callbacks execute on the HandlerThread (guaranteed by `setLooper` during player build).
     *
     * Every callback starts with an early [released] guard (invariant 6): any callback that
     * arrives after terminal release has begun is silently ignored.
     */
    private val playerListener = object : Player.Listener {

        override fun onPlaybackStateChanged(playbackState: Int) {
            // Invariant 6: ignore late callbacks after terminal release has been requested.
            if (released.get()) return
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
            // Invariant 6: ignore late callbacks after terminal release has been requested.
            if (released.get()) return
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
            // Invariant 6: ignore late callbacks after terminal release has been requested.
            if (released.get()) return
            val newWidth = videoSize.width
            val newHeight = videoSize.height

            // Always forward the size change to the listener (external callers may need it).
            listener.onVideoSizeChanged(newWidth, newHeight)

            // --- ABR / rendition resize seam (Phase 4C1C) -----------------------------------
            // If the headless bridge is active and the new size is positive and differs from the
            // current bridge dimensions, recreate the bridge to match the new resolution.
            // This handles mid-stream ABR quality switches that change the decoded frame size.
            val bridge = headlessBridge
            val frameListener = headlessFrameListener
            if (bridge != null && frameListener != null &&
                newWidth > 0 && newHeight > 0 &&
                (newWidth != bridge.width || newHeight != bridge.height)
            ) {
                // 1. Detach the player from the old bridge surface.
                player?.setVideoSurface(null)
                // 2. Release the old bridge (closes its ImageReader and surface).
                bridge.release()
                // 3. Create a new bridge sized to the updated resolution.
                val newBridge = createBridgeOnHandlerThread(newWidth, newHeight, frameListener)
                headlessBridge = newBridge
                // 4. Bind the new bridge surface to the player.
                player?.setVideoSurface(newBridge.surface)
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            // Invariant 6: ignore late error callbacks after terminal release has been requested.
            if (released.get()) return
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
     * If [enableHeadlessFrameBridge] has been called, the bridge's surface is bound to the new
     * player.  Otherwise [pendingSurface] is bound as before.
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

            // --- Phase 4C5B: Resolve streaming network policy ----------------------------
            // Compute the policy for this config's profile.  For AUTO the policy has
            // customPolicyEnabled=false and no LoadControl / TrackSelector is installed,
            // which preserves all Media3 ExoPlayer defaults unchanged.
            val policy = AdaptiveStreamingNetworkPolicy.forProfile(config.networkProfile)
            activeNetworkPolicy = policy

            val exoBuilder = ExoPlayer.Builder(context)
                .setLooper(handlerThread.looper)

            if (policy.customPolicyEnabled) {
                exoBuilder.setLoadControl(policy.buildLoadControl())
                exoBuilder.setTrackSelector(policy.buildTrackSelector(context))
            }
            // AUTO: setLoadControl and setTrackSelector are not called; Media3 defaults apply.

            val exo = exoBuilder.build()

            exo.addListener(playerListener)
            exo.playWhenReady = config.autoPlay

            // Bind the appropriate video output surface:
            //   - headless bridge takes priority (Phase 4C1C).
            //   - external pending surface is the fallback (pre-4C1C behaviour).
            val bridge = headlessBridge
            if (bridge != null) {
                exo.setVideoSurface(bridge.surface)
            } else {
                val surface = pendingSurface
                if (surface != null) {
                    exo.setVideoSurface(surface)
                }
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
     * Binds [surface] as the video output target, disabling and releasing any active headless
     * bridge to maintain mutual exclusion between the two output paths.
     *
     * If the player is already active, the surface is attached immediately via
     * `ExoPlayer.setVideoSurface(surface)`.  If [prepare] has not been called yet, the surface
     * is stored and applied when [prepare] creates the player.
     * Safe to call from any thread.
     *
     * @param surface Target [Surface] for video frame output.  Must not be null.
     */
    fun setSurface(surface: Surface) {
        if (released.get()) return
        handler.post {
            if (released.get()) return@post
            // Mutual exclusion: detach player from the bridge surface before releasing it, then
            // bind the new external surface.
            if (headlessBridge != null) {
                player?.setVideoSurface(null)
            }
            releaseHeadlessBridgeOnHandlerThread()
            pendingSurface = surface
            player?.setVideoSurface(surface)
        }
    }

    /**
     * Detaches the current video surface and releases any active headless bridge.
     *
     * On surface loss the player is intentionally paused (`playWhenReady = false`) before the
     * surface is detached so that the emitted [HttpAdaptivePlaybackState.Paused] state is honest:
     * the player is not actively rendering and will not attempt to write frames to a destroyed or
     * closed surface handle.
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
            // 3. Clear stored external surface reference.
            pendingSurface = null
            // 4. Release any active headless bridge (its surface is also now invalid).
            releaseHeadlessBridgeOnHandlerThread()
            // 5. Emit Paused if the player exists and we were in an active state.
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

    // --- Headless bridge API (Phase 4C1C) ---------------------------------------------------

    /**
     * Enables the headless ImageReader -> HardwareBuffer frame bridge.
     *
     * The bridge is created with the caller-supplied [width] x [height] dimensions.  The
     * Phase 4C1C design intentionally does **not** rely on Media3 discovering an initial video
     * size before a decode surface exists; the caller supplies the initial dimensions explicitly.
     * Later ABR / rendition changes are detected via [Player.Listener.onVideoSizeChanged] and
     * handled transparently by recreating the bridge to match the new resolution.
     *
     * Calling this method:
     * - Disables any pending external surface ([pendingSurface] is cleared).
     * - Releases and replaces any existing headless bridge.
     * - If the player is already active, immediately binds the new bridge's surface.
     *
     * Requires **API 29 (Android 10 / Q)** or higher; the call is silently ignored on older
     * devices.
     *
     * Safe to call from any thread.
     *
     * @param width         Initial bridge width in pixels.  Must be positive.
     * @param height        Initial bridge height in pixels.  Must be positive.
     * @param frameListener Receiver for decoded [HttpAdaptiveDecodedFrame] instances.
     */
    fun enableHeadlessFrameBridge(
        width: Int,
        height: Int,
        frameListener: HttpAdaptiveFrameListener,
    ) {
        if (released.get()) return
        require(width > 0) { "enableHeadlessFrameBridge: width must be positive, got $width" }
        require(height > 0) { "enableHeadlessFrameBridge: height must be positive, got $height" }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return  // silently no-op on < API 29
        handler.post {
            if (released.get()) return@post
            // Mutual exclusion: clear external surface before activating the bridge.
            pendingSurface = null
            // Release any prior bridge: detach player first so it never writes to a closed surface.
            if (headlessBridge != null) {
                player?.setVideoSurface(null)
                headlessBridge?.release()
                headlessBridge = null
            }

            headlessFrameListener = frameListener
            val bridge = createBridgeOnHandlerThread(width, height, frameListener)
            headlessBridge = bridge
            player?.setVideoSurface(bridge.surface)
        }
    }

    /**
     * Disables the headless frame bridge and detaches the player from its surface.
     *
     * This method:
     * - Detaches the player from the bridge surface (`setVideoSurface(null)`).
     * - Releases the [HttpAdaptiveImageReaderBridge].
     * - Clears the stored [HttpAdaptiveFrameListener].
     *
     * After this call [player] has no video output surface.  Call [setSurface] or
     * [enableHeadlessFrameBridge] to re-attach an output.
     *
     * Safe to call from any thread.
     */
    fun disableHeadlessFrameBridge() {
        if (released.get()) return
        handler.post {
            if (released.get()) return@post
            // Only detach the player if the active output is the bridge surface.
            if (headlessBridge != null) {
                player?.setVideoSurface(null)
            }
            releaseHeadlessBridgeOnHandlerThread()
        }
    }

    /**
     * Releases all resources.  Terminal and idempotent.
     *
     * Release order (executed on the HandlerThread):
     * 1. `player.setVideoSurface(null)` — detach surface before decoder teardown.
     * 2. `player.removeListener(playerListener)` — unregister before stop/release (invariant 5).
     * 3. `player.stop()` — cancel active network loaders and buffer allocations.
     * 4. `player.release()` — destroy MediaCodec decoders and audio sinks.
     * 5. Release headless bridge (closes ImageReader and its internal surface).
     * 6. `handler.removeCallbacksAndMessages(null)` — drain any queued adapter work that was
     *    posted before release() but has not yet executed (invariant 8).  The release runnable
     *    itself is already executing at this point, so removal only affects later posts.
     * 7. Emit [HttpAdaptivePlaybackState.Released] exactly once (invariant 7).
     * 8. Schedule [handlerThread.quitSafely()] behind a [RELEASE_LOOPER_SHUTDOWN_GRACE_MS] grace
     *    delay so that Media3's own ListenerSet release callbacks (dispatched via
     *    `sendAtFrontOfQueue` onto the ExoPlayer application looper) can finish draining before
     *    the Looper is torn down.  The grace period is cleanup-only: `released=true` already
     *    makes all public methods permanent no-ops, so no new adapter work will be posted.
     *
     * Safe to call from any thread.  Subsequent calls are no-ops.
     */
    fun release() {
        if (!released.compareAndSet(false, true)) return // idempotent guard
        handler.post {
            tearDownPlayerOnHandlerThread()
            // Full release: clear all pending references that could be rebound by queued work.
            // Invariant 8: drain surface, seek, config, and output references.
            pendingSurface = null
            pendingSeekMs = null
            activeConfig = null
            // Release the headless bridge after player teardown (player is already detached in
            // tearDownPlayerOnHandlerThread).
            releaseHeadlessBridgeOnHandlerThread()
            // Drain any queued adapter work (play/pause/seek/setSurface posts) that was enqueued
            // before release() ran but has not yet executed.  The current runnable (this block)
            // is executing now, so removeCallbacksAndMessages only drops later queued entries.
            // This prevents them from posting to a dead HandlerThread after quitSafely().
            handler.removeCallbacksAndMessages(null)
            emitState(HttpAdaptivePlaybackState.Released)
            // Defer looper shutdown by a brief grace period so that Media3 ListenerSet events
            // queued via sendAtFrontOfQueue onto this looper (during player.release() codec
            // teardown) can drain without triggering "Handler on a dead thread" warnings.
            // The adapter is already fully terminal at this point (released=true); this delay
            // only affects the looper lifetime, not any observable adapter behaviour.
            handler.postDelayed(
                { handlerThread.quitSafely() },
                RELEASE_LOOPER_SHUTDOWN_GRACE_MS,
            )
        }
    }

    // --- Internal helpers (HandlerThread only) -----------------------------------------------

    /**
     * Performs ordered player teardown.  Must only be called from the HandlerThread.
     * Safe to call when [player] is null (no-op).
     *
     * Detaches the video surface (whether external or the headless bridge surface) before
     * stopping and releasing the player.
     *
     * **Intentionally does NOT clear [pendingSurface] or release [headlessBridge].**
     * - On re-prepare the caller's previously set surface / bridge remains valid and is rebound.
     * - Only [release] (full teardown) and [clearSurface] (explicit surface loss) are permitted
     *   to clear those references.
     */
    private fun tearDownPlayerOnHandlerThread() {
        val p = player ?: return
        player = null
        pendingSeekMs = null
        // Phase 4C5B: clear policy reference so it is absent after teardown/release.
        activeNetworkPolicy = null

        // 1. Detach surface before any decoder teardown (covers both external and bridge surfaces).
        p.setVideoSurface(null)
        // 2. Unregister listener BEFORE stop/release so that STATE_IDLE, STATE_ERROR, and any
        //    other terminal ExoPlayer callbacks cannot fire back into adapter state.
        //    Invariant 5: listener must be removed before stop() can emit stop/idle/error events.
        p.removeListener(playerListener)
        // 3. Cancel active network loaders / buffer allocations.
        p.stop()
        // 4. Destroy MediaCodec decoders and audio sinks.
        p.release()
        // HandlerThread quitSafely() is called separately in release() after emitting Released.
    }

    /**
     * Releases the headless bridge and clears the stored listener.
     * Must only be called from the HandlerThread.
     */
    private fun releaseHeadlessBridgeOnHandlerThread() {
        headlessBridge?.release()
        headlessBridge = null
        headlessFrameListener = null
    }

    /**
     * Creates a new [HttpAdaptiveImageReaderBridge] instance.
     * Must only be called from the HandlerThread.
     * Caller must have already verified API >= Q before this point.
     */
    @androidx.annotation.RequiresApi(Build.VERSION_CODES.Q)
    private fun createBridgeOnHandlerThread(
        width: Int,
        height: Int,
        frameListener: HttpAdaptiveFrameListener,
    ): HttpAdaptiveImageReaderBridge {
        return HttpAdaptiveImageReaderBridge(
            width = width,
            height = height,
            handler = handler,
            frameListener = frameListener,
        )
    }

    /**
     * Emits [newState] to the listener and updates [currentState].
     * Must only be called from the HandlerThread.
     *
     * Once [released] is true, only [HttpAdaptivePlaybackState.Released] may be forwarded to the
     * listener.  Any other state is silently dropped (invariant 7).
     */
    private fun emitState(newState: HttpAdaptivePlaybackState) {
        if (released.get() && newState !is HttpAdaptivePlaybackState.Released) return
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

        /**
         * Grace period (ms) between emitting [HttpAdaptivePlaybackState.Released] and calling
         * [HandlerThread.quitSafely].  Media3's [androidx.media3.common.util.ListenerSet] posts
         * release callbacks via `sendAtFrontOfQueue` onto the ExoPlayer application looper after
         * [ExoPlayer.release] returns.  Quitting the looper immediately causes those posts to hit
         * a dead thread, producing logcat warnings.  A 500 ms window is ample for codec teardown
         * callbacks to drain; the adapter itself is fully terminal (released=true) well before
         * this fires.
         */
        private const val RELEASE_LOOPER_SHUTDOWN_GRACE_MS = 500L
    }
}
