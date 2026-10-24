// Copyright (c) Connects - Phase 4C1C: HttpAdaptivePlaybackAdapter with headless ImageReader bridge.
// Phase 4C5B: Streaming network profile policy (AdaptiveStreamingNetworkPolicy) applied in prepare().
// Phase 4C6B: Cache-aware DataSource.Factory routing via AndroidDagPlaybackCacheManager (opt-in).
// Android LL-HLS experimental transfer: per-epoch HttpAdaptivePlaybackGraph ownership, default-off
// AndroidLlhlsProfile construction, the single qualified READY recovery path and the bounded
// behind-live-window error recovery claim sharing its budget.
// Explicit-Play live return: an experimental resume after pause rebuilds the current live graph
// through the same replacement machinery, outside the automatic budget and revocation.
// Scaffold with headless decode surface bridge enabled.  No live network streaming is claimed or
// verified here.  Physical network streaming proof is deferred to Phase 4C device validation.

package com.connects.vanguard_media_engine.streaming

import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
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
 * - Every method that touches the player posts a lambda to [handler] (the HandlerThread's Handler).
 * - [Player.Listener] callbacks are automatically dispatched on the HandlerThread because the
 *   ExoPlayer instance was built with `setLooper(handlerThread.looper)`.
 * - [listener] callbacks are therefore also invoked on the HandlerThread.
 *
 * ## Control ownership
 * - [HttpAdaptivePlaybackControlState] solely owns released / stopped / playing intent / control
 *   version / seek reservation as one atomic snapshot.  Public controls transition it
 *   synchronously before posting; owner-thread work (construction, replacement, READY, the posted
 *   seek-hold reconciliation) re-reads it at every decision point.  This class owns every SDK and
 *   handler side effect; recovery permission and graph / bridge epochs stay separate.
 *
 * ## Graph ownership
 * - The player, its per-epoch [Player.Listener] and its headless bridge live in one
 *   [HttpAdaptivePlaybackGraph].  Exactly one graph is current ([currentGraph]); every player and
 *   bridge callback captured the epoch (and bridge token) it was created for and is discarded when
 *   that graph is no longer current.
 * - Ordinary sessions build one graph per [prepare].  The experimental LL-HLS profile may replace
 *   the graph once per claimed recovery (see [claimReadyRecoveryOnHandlerThread] and
 *   [claimBehindLiveWindowRecoveryOnHandlerThread]) and once per explicit Play that validates a
 *   live resume intent (see [resumeExperimentalPlaybackOnHandlerThread]).
 *
 * ## Surface Binding
 * - The caller supplies an optional [android.view.Surface] via [setSurface].
 * - Internally, `ExoPlayer.setVideoSurface(surface)` / `setVideoSurface(null)` is used.
 * - `setVideoSurface(null)` is enforced **before** player stop/release and on surface loss.
 * - [setSurface] and [enableHeadlessFrameBridge] are mutually exclusive outputs: activating one
 *   disables and releases the other.
 *
 * ## Headless Frame Bridge (Phase 4C1C)
 * - [enableHeadlessFrameBridge] records the bridge specification; the current graph (or the next
 *   one built) owns an [HttpAdaptiveImageReaderBridge] that routes decoded frames through an
 *   [android.media.ImageReader] -> [android.hardware.HardwareBuffer] pipeline.
 * - ABR / rendition resolution changes detected via [Player.Listener.onVideoSizeChanged] trigger
 *   automatic bridge recreation to match the new dimensions.
 * - Requires API 29+ (Android 10 / Q).
 *
 * ## Release Contract
 * - [release] is idempotent and terminal.  Once released, all subsequent public calls are no-ops.
 * - Release order:  retire current graph (detach surface -> remove listener -> stop -> release ->
 *   close reader) -> quit HandlerThread after a grace period.
 *
 * ## Non-Goals (current boundary)
 * - No ConnectsApp wiring, no WebRTC/LiveKit transport, no DRM licensing.
 * - No working end-to-end streaming claim.
 *
 * @param context   Android [Context] used to build [ExoPlayer].  Must be a valid application or
 *                  plugin context; must not be an Activity context that may be destroyed.
 * @param listener  Event listener.  Callbacks are always dispatched on the HandlerThread.
 * @param experimentalLlhls `true` only when [AndroidLlhlsProfile.isEligible] held at session
 *                  construction.  Selects the tested LL-HLS profile, parser adaptation and the
 *                  bounded READY recovery path.  Defaults to `false` (all existing behaviour).
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class HttpAdaptivePlaybackAdapter(
    private val context: Context,
    private val listener: HttpAdaptivePlaybackListener,
    private val experimentalLlhls: Boolean = false,
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

    /**
     * Sole owner of released / stopped / playing-intent / control-version / seek-reservation
     * state.  Every public control transitions it synchronously (atomic snapshot swap) before any
     * handler work is posted; owner-thread work re-reads it at each decision point.  The adapter
     * keeps every SDK / handler side effect; the owner keeps none.
     */
    private val control: HttpAdaptivePlaybackControlState =
        HttpAdaptivePlaybackControlState(experimental = experimentalLlhls)

    /** Terminal release flag, read from [control].  Once true, all public methods are no-ops. */
    private val released: Boolean
        get() = control.snapshot().released

    /** Current playback state.  Only read/written on the HandlerThread. */
    @Volatile
    private var currentState: HttpAdaptivePlaybackState = HttpAdaptivePlaybackState.Idle

    // --- Graph -------------------------------------------------------------------------------

    /**
     * The current player graph.  Created on [handler] during [prepare] (and on claimed recovery).
     * All access must be on the HandlerThread.  `null` while no graph is installed.
     */
    private var currentGraph: HttpAdaptivePlaybackGraph? = null

    /** Monotonic graph epoch source; every graph gets a fresh positive epoch. */
    private val epochSeq: AtomicLong = AtomicLong(0L)

    /** Monotonic bridge token source; every bound ImageReader gets a fresh positive token. */
    private val bridgeTokenSeq: AtomicLong = AtomicLong(HttpAdaptivePlaybackGraph.NO_BRIDGE_TOKEN)

    /** Pending external surface to bind once a graph exists.  Mutually exclusive with the bridge. */
    private var pendingSurface: Surface? = null

    /**
     * Ordinary-session pending seek, applied once [Player.STATE_READY] is first reached.
     * Experimental sessions seek only through the staged reservation owned by [control].
     */
    private var pendingSeekMs: Long? = null

    /** Current stream configuration.  Set during [prepare]; reused verbatim for graph replacement. */
    private var activeConfig: HttpAdaptiveStreamConfig? = null

    /**
     * Network policy resolved for the currently prepared player (Phase 4C5B).
     * Set in [prepare] from [AdaptiveStreamingNetworkPolicy.forProfile].
     * Cleared to null in [retireCurrentGraphOnHandlerThread] so it is absent after teardown/release.
     */
    private var activeNetworkPolicy: AdaptiveStreamingNetworkPolicy? = null

    /**
     * Whether any graph of the current preparation has actually played a live item
     * (`onIsPlayingChanged(true)` while live).  A paused poster frame alone does not set it.
     * Reset at the owner-thread [prepare] boundary before the initial graph is built; retained
     * across automatic and explicit graph replacements.  Consulted only by the explicit resume
     * gate so a first Play after `autoPlay=false` stays ordinary.  HandlerThread only.
     */
    private var hasStartedLivePlayback: Boolean = false

    // --- Headless bridge specification (Phase 4C1C) ------------------------------------------

    /**
     * Frame listener and dimensions recorded by [enableHeadlessFrameBridge].  The graph owns the
     * bridge instance itself; this specification lets a new graph (re-prepare or replacement)
     * recreate the bridge without the caller calling [enableHeadlessFrameBridge] again.
     * Only accessed on the HandlerThread.
     */
    private var headlessFrameListener: HttpAdaptiveFrameListener? = null
    private var headlessBridgeWidth: Int = 0
    private var headlessBridgeHeight: Int = 0

    // --- Recovery (experimental LL-HLS only) -------------------------------------------------

    /**
     * One-way recovery revocation.  Set synchronously by [disableRecovery] from any thread and
     * checked before every arm/claim on the HandlerThread.  Never cleared.
     */
    private val recoveryDisabled: AtomicBoolean = AtomicBoolean(false)

    @Volatile
    private var recoveryDisableReason: String? = null

    /** Pure decision policy; non-null only for experimental sessions.  HandlerThread only. */
    private var recoveryPolicy: AndroidLlhlsRecoveryPolicy? = null

    /** Race-free diagnostic mirror of the policy, refreshed on the HandlerThread. */
    @Volatile
    private var recoveryDiagnosticText: String = if (experimentalLlhls) "inactive" else "not_experimental"

    // --- Player.Listener ---------------------------------------------------------------------

    /**
     * Returns the current graph only if it is still the graph the callback was created for.
     * Every player callback starts with this check (invariant 6: late callbacks after release
     * or after graph replacement are silently ignored).
     */
    private fun graphFor(epoch: Long): HttpAdaptivePlaybackGraph? {
        if (released) return null
        val g = currentGraph ?: return null
        return if (g.epoch == epoch && !g.isRetired) g else null
    }

    /**
     * Builds the per-epoch [Player.Listener] bridging Media3 events into typed
     * [HttpAdaptivePlaybackState] transitions.  All callbacks execute on the HandlerThread
     * (guaranteed by `setLooper` during player build).
     */
    private fun createPlayerListener(epoch: Long): Player.Listener = object : Player.Listener {

        override fun onPlaybackStateChanged(playbackState: Int) {
            val g = graphFor(epoch) ?: return
            val p = g.player
            when (playbackState) {
                Player.STATE_BUFFERING -> {
                    val pct = p.bufferedPercentage
                    emitState(HttpAdaptivePlaybackState.Buffering(pct))
                    listener.onBufferingProgress(pct)
                    armRecoveryOnBufferingOnHandlerThread(g)
                }
                Player.STATE_READY -> {
                    if (experimentalLlhls) {
                        // A committed reservation is issued now; this callback publishes nothing
                        // further (the post-seek READY does).  An uncommitted reservation keeps
                        // the playback hold in force (READY guard) and publishes Ready.
                        if (applyCommittedSeekOnHandlerThread(g)) return
                        if (control.snapshot().seekPending) p.playWhenReady = false
                    } else {
                        // Apply deferred seek before emitting Ready
                        pendingSeekMs?.let { seekMs ->
                            pendingSeekMs = null
                            p.seekTo(seekMs)
                            emitState(HttpAdaptivePlaybackState.Seeking(seekMs))
                            return
                        }
                    }
                    // Experimental: a claim that retires this graph publishes nothing further for
                    // it; a claim cancelled by a concurrent control keeps publishing as usual.
                    if (claimReadyRecoveryOnHandlerThread(g)) return
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
                    disableRecovery("ended")
                    val duration = p.duration
                    emitState(HttpAdaptivePlaybackState.Ended(durationMs = duration))
                }
                Player.STATE_IDLE -> {
                    // Reached after stop(); do not re-emit Idle if already releasing.
                    if (!released) {
                        emitState(HttpAdaptivePlaybackState.Idle)
                    }
                }
            }
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            val g = graphFor(epoch) ?: return
            val p = g.player
            if (isPlaying) {
                if (p.isCurrentMediaItemLive) hasStartedLivePlayback = true
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

        override fun onRenderedFirstFrame() {
            val g = graphFor(epoch) ?: return
            // Rendered-live history is graph-owned and independent of automatic recovery state.
            if (g.player.isCurrentMediaItemLive) g.hasRenderedLiveFrame = true
            val policy = recoveryPolicy ?: return
            if (recoveryDisabled.get()) return
            policy.onFirstFrame(g.epoch)
            refreshRecoveryDiagnostic()
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            val g = graphFor(epoch) ?: return
            val newWidth = videoSize.width
            val newHeight = videoSize.height

            // AndroidX Media3: videoFormat.rotationDegrees describes clockwise rotation (0, 90, 180, 270).
            // videoSize.unappliedRotationDegrees is deprecated and always 0.
            val rawRotation = g.player.videoFormat?.rotationDegrees ?: 0
            val rotationDegrees = when (rawRotation) {
                0, 90, 180, 270 -> rawRotation
                else -> 0
            }
            val displayWidth = if (rotationDegrees == 90 || rotationDegrees == 270) newHeight else newWidth
            val displayHeight = if (rotationDegrees == 90 || rotationDegrees == 270) newWidth else newHeight

            // Always forward the size and orientation changes to the listener (external callers may need it).
            listener.onVideoSizeChanged(newWidth, newHeight, rotationDegrees, displayWidth, displayHeight)

            // --- ABR / rendition resize seam (Phase 4C1C) -----------------------------------
            // If the headless bridge is active and the new size is positive and differs from the
            // current bridge dimensions, recreate the bridge to match the new resolution.
            // This handles mid-stream ABR quality switches that change the decoded frame size.
            val bridge = g.bridge
            val frameListener = headlessFrameListener
            if (bridge != null && frameListener != null &&
                newWidth > 0 && newHeight > 0 &&
                (newWidth != bridge.width || newHeight != bridge.height)
            ) {
                headlessBridgeWidth = newWidth
                headlessBridgeHeight = newHeight
                // Detach and close the old reader, then bind a fresh one sized to the new resolution.
                g.releaseBridge()
                installBridgeOnHandlerThread(g, newWidth, newHeight, frameListener)
            }
            // A replacement graph's frames are withheld until this point (see HttpAdaptivePlaybackGraph).
            if (newWidth > 0 && newHeight > 0) {
                g.videoSizeDelivered = true
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            val g = graphFor(epoch) ?: return
            // Experimental: only a behind-live-window error may consume a bounded recovery claim.
            // A claim that retires this graph publishes nothing further for it (the fresh graph
            // publishes Buffering); a declined or pre-retirement-cancelled claim falls through to
            // the existing fatal handling below.
            if (experimentalLlhls && error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW) {
                if (claimBehindLiveWindowRecoveryOnHandlerThread(g)) return
            }
            // Every other error retains fatal handling; no error-claim reconstruction.
            disableRecovery("player_error_${error.errorCode}")
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
     * If a graph is already running from a previous prepare call, it is retired before the new
     * graph is built.  Safe to call from any thread.
     *
     * If [enableHeadlessFrameBridge] has been called, a bridge is created for the new graph.
     * Otherwise [pendingSurface] is bound as before.
     *
     * @param config Stream configuration.  Must pass its own local validation invariants.
     */
    fun prepare(config: HttpAdaptiveStreamConfig) {
        // Rejected when released, or when an experimental session was stopped (new open required).
        if (!control.prepare(autoPlay = config.autoPlay)) return
        handler.post {
            if (released) return@post
            // Retire any existing graph before re-preparing.
            retireCurrentGraphOnHandlerThread()

            activeConfig = config
            pendingSeekMs = config.startPositionMs
            hasStartedLivePlayback = false

            emitState(HttpAdaptivePlaybackState.Preparing)

            // --- Phase 4C5B: Resolve streaming network policy ----------------------------
            // Compute the policy for this config's profile.  For AUTO the policy has
            // customPolicyEnabled=false and no LoadControl / TrackSelector is installed,
            // which preserves all Media3 ExoPlayer defaults unchanged.
            activeNetworkPolicy = AdaptiveStreamingNetworkPolicy.forProfile(config.networkProfile)

            if (experimentalLlhls) {
                recoveryPolicy = AndroidLlhlsRecoveryPolicy()
                refreshRecoveryDiagnostic()
            }

            val prepared = try {
                buildGraphOnHandlerThread(config = config, isReplacement = false)
            } catch (t: Throwable) {
                publishConstructionFailureOnHandlerThread("prepare", t)
                return@post
            }
            // A stop-cancelled initial prepare publishes Idle instead of remaining Preparing.
            if (!prepared) publishCancelledConstructionOnHandlerThread()
        }
    }

    /**
     * Starts or resumes playback.  A no-op if the player is not prepared or already playing.
     * Experimental: rejected after stop (new open required); a pending seek reservation keeps
     * SDK playback held until its target is issued; a resume whose recorded position is live
     * (an experimental [pause] without a pending seek) rebuilds the current live graph toward
     * the live edge instead of catching up from the paused position
     * (see [resumeExperimentalPlaybackOnHandlerThread]).  Safe to call from any thread.
     */
    fun play() {
        if (!control.play()) return
        handler.post {
            if (experimentalLlhls) {
                resumeExperimentalPlaybackOnHandlerThread()
                return@post
            }
            if (released) return@post
            currentGraph?.player?.playWhenReady = true
        }
    }

    /**
     * Pauses playback.  Buffers are preserved; a pending seek reservation is retained.
     * Ordinary sessions revoke recovery and hold the SDK directly (existing path).  Experimental
     * sessions publish the paused intent / version (and the live resume position) atomically,
     * then post the latest-intent / seek-hold reconciliation rather than a blind `false`: a Play
     * that landed after this transition may have posted first and must not be undone.  An
     * experimental pause does not revoke automatic recovery.  Safe to call from any thread.
     */
    fun pause() {
        if (!control.pause()) return
        if (experimentalLlhls) {
            handler.post { reconcileSeekHoldOnHandlerThread() }
            return
        }
        disableRecovery("pause")
        handler.post {
            if (released) return@post
            currentGraph?.player?.playWhenReady = false
        }
    }

    /**
     * Seeks to [positionMs] milliseconds.
     *
     * Ordinary sessions: if the player has not yet reached [Player.STATE_READY], the position is
     * cached and applied automatically once ready (deferred seek).  Experimental sessions: an
     * immediately committed reservation through the staged API ([beginSeek] / [commitSeek]).
     * Safe to call from any thread.
     *
     * @param positionMs Target playhead position in milliseconds.  Must be >= 0.
     */
    fun seekTo(positionMs: Long) {
        require(positionMs >= 0L) { "seekTo: positionMs must be >= 0, got $positionMs" }
        if (released) return
        if (experimentalLlhls) {
            val ticket = beginSeek(positionMs)
            if (ticket != HttpAdaptivePlaybackControlState.NO_SEEK_TICKET) commitSeek(ticket)
            return
        }
        handler.post {
            if (released) return@post
            val p = currentGraph?.player
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

    // --- Staged seek API (experimental LL-HLS) ------------------------------------------------
    //
    // Non-blocking atomic-plus-post operations: none waits for the handler, the Player or the
    // session lock.  The session calls beginSeek before taking its render lock, performs native
    // generation work, then commits (SDK seek) or cancels (reservation released).  The posted
    // hold reconciliation reads the current graph and snapshot when it executes, so it never
    // acts on a captured retired graph or a stale target; a command racing an already-entered
    // SDK call is reconciled on the next owner turn.

    /**
     * Publishes a seek reservation (target, fresh ticket / version, uncommitted playback hold),
     * permanently revokes recovery and posts hold reconciliation.  No SDK seek is issued yet.
     *
     * @return the ticket, or [HttpAdaptivePlaybackControlState.NO_SEEK_TICKET] when stopped or
     *   released (the caller must then reject before any native work).
     */
    fun beginSeek(positionMs: Long): Long {
        require(positionMs >= 0L) { "beginSeek: positionMs must be >= 0, got $positionMs" }
        val ticket = control.beginSeek(positionMs)
        if (ticket == HttpAdaptivePlaybackControlState.NO_SEEK_TICKET) return ticket
        disableRecovery("seek")
        handler.post { reconcileSeekHoldOnHandlerThread() }
        return ticket
    }

    /**
     * Commits the current live [ticket]: its target is issued on the owner thread as soon as the
     * current player can seek (retained while idle / buffering, applied at READY), then only the
     * current playing intent is restored.  Duplicate commits are harmless.
     *
     * @return `false` when [ticket] is stale, superseded, cancelled, stopped or released.
     */
    fun commitSeek(ticket: Long): Boolean {
        if (!control.commitSeek(ticket)) return false
        handler.post { reconcileSeekHoldOnHandlerThread() }
        return true
    }

    /**
     * Cancels the reservation only when [ticket] is the current live ticket, releasing its hold
     * and reconciling the current playing intent.  A stale ticket does nothing.
     */
    fun cancelSeek(ticket: Long) {
        if (!control.cancelSeek(ticket)) return
        handler.post { reconcileSeekHoldOnHandlerThread() }
    }

    /**
     * Stops the current playback and returns the player to [Player.STATE_IDLE].  Network loaders
     * are cancelled and decoders released.  An ordinary adapter may be re-prepared via [prepare];
     * an experimental one requires a new open.  Invalidates any seek reservation and revokes
     * experimental recovery permanently.  Safe to call from any thread.
     */
    fun stop() {
        if (!control.stop()) return
        disableRecovery("stop")
        handler.post {
            if (released) return@post
            currentGraph?.player?.stop()
            // STATE_IDLE callback from the graph listener will emit Idle state.
        }
    }

    /**
     * Binds [surface] as the video output target, disabling and releasing any active headless
     * bridge to maintain mutual exclusion between the two output paths.
     *
     * If a graph is active, the surface is attached immediately via
     * `ExoPlayer.setVideoSurface(surface)`.  If [prepare] has not been called yet, the surface
     * is stored and applied when [prepare] builds the graph.
     * Safe to call from any thread.
     *
     * @param surface Target [Surface] for video frame output.  Must not be null.
     */
    fun setSurface(surface: Surface) {
        if (released) return
        handler.post {
            if (released) return@post
            // Mutual exclusion: drop the bridge specification and bind the external surface.
            clearHeadlessBridgeSpecOnHandlerThread()
            pendingSurface = surface
            currentGraph?.bindExternalSurface(surface)
        }
    }

    /**
     * Detaches the current video surface and releases any active headless bridge.
     *
     * On surface loss the player is intentionally paused (`playWhenReady = false`) before the
     * surface is detached so that the emitted [HttpAdaptivePlaybackState.Paused] state is honest:
     * the player is not actively rendering and will not attempt to write frames to a destroyed or
     * closed surface handle.  Revokes experimental recovery permanently.
     *
     * Must be called when the surface is destroyed or becomes invalid.
     * Safe to call from any thread.
     */
    fun clearSurface() {
        // Surface loss records paused intent (version advanced; any seek reservation retained).
        if (!control.pause()) return
        disableRecovery("surface_cleared")
        handler.post {
            if (released) return@post
            val g = currentGraph
            val p = g?.player
            // 1. Pause before detaching; ensures playWhenReady=false before surface is nulled.
            p?.playWhenReady = false
            // 2. Detach the surface so no decoder writes land on the invalidated handle
            //    (also closes any bound reader).
            g?.bindExternalSurface(null)
            // 3. Clear stored external surface reference and bridge specification.
            pendingSurface = null
            clearHeadlessBridgeSpecOnHandlerThread()
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
     * - Records the bridge specification for every graph built afterwards.
     * - If a graph is already active, immediately replaces its bridge and binds the new surface.
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
        if (released) return
        require(width > 0) { "enableHeadlessFrameBridge: width must be positive, got $width" }
        require(height > 0) { "enableHeadlessFrameBridge: height must be positive, got $height" }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return  // silently no-op on < API 29
        handler.post {
            if (released) return@post
            // Mutual exclusion: clear external surface before activating the bridge.
            pendingSurface = null
            headlessFrameListener = frameListener
            headlessBridgeWidth = width
            headlessBridgeHeight = height
            currentGraph?.let { g ->
                g.releaseBridge()
                installBridgeOnHandlerThread(g, width, height, frameListener)
            }
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
     * After this call the player has no video output surface.  Call [setSurface] or
     * [enableHeadlessFrameBridge] to re-attach an output.
     *
     * Safe to call from any thread.
     */
    fun disableHeadlessFrameBridge() {
        if (released) return
        handler.post {
            if (released) return@post
            currentGraph?.releaseBridge()
            clearHeadlessBridgeSpecOnHandlerThread()
        }
    }

    // --- Recovery API (experimental LL-HLS) ---------------------------------------------------

    /**
     * Permanently revokes experimental recovery.  Synchronous and callable from any thread: the
     * atomic flag takes effect immediately; the policy's own cleanup follows on the HandlerThread
     * and can never re-enable recovery.  A no-op for ordinary sessions (nothing to revoke).
     */
    fun disableRecovery(reason: String) {
        if (!recoveryDisabled.compareAndSet(false, true)) return
        recoveryDisableReason = reason
        if (released) return
        handler.post {
            recoveryPolicy?.disable(reason)
            refreshRecoveryDiagnostic()
        }
    }

    /** Diagnostic-only description of the recovery policy state. */
    fun recoveryDiagnostic(): String {
        val reason = recoveryDisableReason
        return if (reason != null) "$recoveryDiagnosticText;revoked=$reason" else recoveryDiagnosticText
    }

    /**
     * Releases all resources.  Terminal and idempotent.
     *
     * Release order (executed on the HandlerThread):
     * 1. Retire the current graph: `removeListener` -> `setVideoSurface(null)` -> `stop()` ->
     *    `release()` -> close the reader (invariant 5: the listener is removed before stop/release
     *    can emit stop/idle/error events).
     * 2. `handler.removeCallbacksAndMessages(null)` — drain any queued adapter work that was
     *    posted before release() but has not yet executed (invariant 8).  The release runnable
     *    itself is already executing at this point, so removal only affects later posts.
     * 3. Emit [HttpAdaptivePlaybackState.Released] exactly once (invariant 7).
     * 4. Schedule [handlerThread.quitSafely()] behind a [RELEASE_LOOPER_SHUTDOWN_GRACE_MS] grace
     *    delay so that Media3's own ListenerSet release callbacks (dispatched via
     *    `sendAtFrontOfQueue` onto the ExoPlayer application looper) can finish draining before
     *    the Looper is torn down.  The grace period is cleanup-only: `released=true` already
     *    makes all public methods permanent no-ops, so no new adapter work will be posted.
     *
     * Safe to call from any thread.  Subsequent calls are no-ops.
     */
    fun release() {
        if (!control.release()) return // idempotent guard: only the first transition wins
        disableRecovery("release")
        handler.post {
            retireCurrentGraphOnHandlerThread()
            // Full release: clear all pending references that could be rebound by queued work.
            // Invariant 8: drain surface, seek, config, and output references.
            pendingSurface = null
            pendingSeekMs = null
            activeConfig = null
            clearHeadlessBridgeSpecOnHandlerThread()
            recoveryPolicy = null
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
     * Whether construction must be abandoned for [s]: released always; stopped for experimental
     * sessions only (an ordinary stop racing a prepare keeps the existing build-then-stop path).
     */
    private fun constructionCancelled(s: HttpAdaptivePlaybackControlState.Snapshot): Boolean =
        s.released || (experimentalLlhls && s.stopped)

    /**
     * Builds, installs and prepares a new graph for [config].  Must only be called from the
     * HandlerThread with no current graph installed.
     *
     * The graph becomes [currentGraph] **before** its listener is attached and before `prepare()`
     * can publish callbacks, so every callback observes its owning graph.  The control snapshot
     * is re-read before installing and again immediately before preparing; a cancellation
     * ([constructionCancelled]) retires the partial graph silently and returns `false`
     * (cancellation is not a construction failure).  The initial `playWhenReady` is resolved from
     * that final snapshot (current intent, held while a seek reservation is pending), never from
     * a value saved earlier; the posted hold and the READY guard reconcile a reservation that
     * lands after this read.  If any step throws, the partially built graph is retired and the
     * exception propagates to the caller, which publishes the outcome exactly once.
     *
     * @return `true` when the graph was installed and prepared.
     */
    private fun buildGraphOnHandlerThread(
        config: HttpAdaptiveStreamConfig,
        isReplacement: Boolean,
    ): Boolean {
        val epoch = epochSeq.incrementAndGet()
        val policy = activeNetworkPolicy ?: AdaptiveStreamingNetworkPolicy.forProfile(config.networkProfile)

        val exoBuilder = ExoPlayer.Builder(context)
            .setLooper(handlerThread.looper)

        if (experimentalLlhls) {
            // Tested clockfast1350 configuration; Media3 keeps its default TrackSelector (ABR on).
            exoBuilder.setLoadControl(AndroidLlhlsProfile.buildLoadControl())
            exoBuilder.setLivePlaybackSpeedControl(AndroidLlhlsProfile.buildLivePlaybackSpeedControl())
        } else if (policy.customPolicyEnabled) {
            exoBuilder.setLoadControl(policy.buildLoadControl())
            exoBuilder.setTrackSelector(policy.buildTrackSelector(context))
        }
        // AUTO: setLoadControl and setTrackSelector are not called; Media3 defaults apply.

        val exo = exoBuilder.build()
        val graph = HttpAdaptivePlaybackGraph(
            epoch = epoch,
            player = exo,
            playerListener = createPlayerListener(epoch),
            isReplacement = isReplacement,
        )

        var prepared = false
        try {
            // Recheck before installing: a cancellation that landed during construction wins.
            if (constructionCancelled(control.snapshot())) return false
            currentGraph = graph
            recoveryPolicy?.onGraphReplaced(epoch)
            graph.attachListener()
            // Debug-only read-only observer owned by this player's AnalyticsCollector; non-throwing.
            if (experimentalLlhls) AndroidLlhlsDiagnosticListener.attach(context, exo, epoch)

            // Bind the appropriate video output surface:
            //   - headless bridge takes priority (Phase 4C1C).
            //   - external pending surface is the fallback (pre-4C1C behaviour).
            val frameListener = headlessFrameListener
            if (frameListener != null && headlessBridgeWidth > 0 && headlessBridgeHeight > 0 &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
            ) {
                installBridgeOnHandlerThread(graph, headlessBridgeWidth, headlessBridgeHeight, frameListener)
            } else {
                pendingSurface?.let { graph.bindExternalSurface(it) }
            }

            exo.setMediaSource(buildMediaSource(config, epoch))
            // Recheck immediately before preparing; intent and hold are resolved from this
            // snapshot, never from a saved value.
            val s = control.snapshot()
            if (constructionCancelled(s)) return false
            exo.playWhenReady = s.intendedPlaying && !(experimentalLlhls && s.seekPending)
            exo.prepare()
            prepared = true
        } finally {
            if (!prepared) {
                if (currentGraph === graph) currentGraph = null
                graph.retire()
            }
        }
        refreshRecoveryDiagnostic()
        return true
    }

    /**
     * Performs ordered graph retirement.  Must only be called from the HandlerThread.
     * Safe to call when no graph is installed (no-op).
     *
     * Clears [currentGraph] first so any callback still in flight sees a stale epoch, then
     * retires the graph (listener, surface, player, reader).
     *
     * **Intentionally does NOT clear [pendingSurface] or the headless bridge specification.**
     * - On re-prepare the caller's previously set surface / bridge specification remains valid
     *   and the new graph rebinds it (recreating its own reader).
     * - Only [release] (full teardown) and [clearSurface] (explicit surface loss) are permitted
     *   to clear those references.
     */
    private fun retireCurrentGraphOnHandlerThread() {
        val g = currentGraph ?: return
        currentGraph = null
        pendingSeekMs = null
        // Phase 4C5B: clear policy reference so it is absent after teardown/release.
        activeNetworkPolicy = null
        g.retire()
    }

    /** Clears the recorded headless bridge specification.  HandlerThread only. */
    private fun clearHeadlessBridgeSpecOnHandlerThread() {
        headlessFrameListener = null
        headlessBridgeWidth = 0
        headlessBridgeHeight = 0
    }

    /**
     * Creates a new [HttpAdaptiveImageReaderBridge] for [graph] and binds it as the player output.
     * The bridge's frame callback captures the graph epoch and a fresh bridge token; frames from
     * any other graph or reader are discarded on the HandlerThread before reaching [frameListener].
     * Must only be called from the HandlerThread; caller must have verified API >= Q.
     */
    @androidx.annotation.RequiresApi(Build.VERSION_CODES.Q)
    private fun installBridgeOnHandlerThread(
        graph: HttpAdaptivePlaybackGraph,
        width: Int,
        height: Int,
        frameListener: HttpAdaptiveFrameListener,
    ) {
        val epoch = graph.epoch
        val token = bridgeTokenSeq.incrementAndGet()
        val guarded = HttpAdaptiveFrameListener { frame ->
            if (released) return@HttpAdaptiveFrameListener
            val g = currentGraph ?: return@HttpAdaptiveFrameListener
            if (!g.acceptsFrames(epoch, token)) return@HttpAdaptiveFrameListener
            // Synchronous, borrowed delivery: the bridge closes the HardwareBuffer after return.
            frameListener.onFrameAvailable(frame)
        }
        val bridge = HttpAdaptiveImageReaderBridge(
            width = width,
            height = height,
            handler = handler,
            frameListener = guarded,
        )
        graph.bindBridge(bridge, token)
    }

    /**
     * Experimental: records a buffering transition with the policy.  Only a graph that already
     * rendered a live frame with playing intent can arm.  HandlerThread only.
     */
    private fun armRecoveryOnBufferingOnHandlerThread(g: HttpAdaptivePlaybackGraph) {
        val policy = recoveryPolicy ?: return
        if (recoveryDisabled.get()) return
        val p = g.player
        policy.onBuffering(
            epoch = g.epoch,
            live = p.isCurrentMediaItemLive,
            playingIntent = control.snapshot().intendedPlaying && p.playWhenReady,
        )
        refreshRecoveryDiagnostic()
        if (experimentalLlhls) {
            AndroidLlhlsDiagnosticListener.record(
                context, p, g.epoch, "recovery_arm_eval",
                mapOf(
                    "renderedEpoch" to policy.renderedEpoch, "currentEpoch" to policy.currentEpoch,
                    "armed" to policy.armed, "actionCount" to policy.actionCount,
                    "disabled" to policy.disabled, "lastDecision" to policy.lastDecision,
                ),
            )
        }
    }

    /**
     * Experimental: evaluates the qualified READY recovery claim for [g].  Returns `true` only
     * when [g] was retired; the caller must then stop publishing for it.  A claim cancelled by a
     * concurrent control returns `false` and [g] remains current.  HandlerThread only.
     */
    private fun claimReadyRecoveryOnHandlerThread(g: HttpAdaptivePlaybackGraph): Boolean {
        val policy = recoveryPolicy ?: return false
        if (recoveryDisabled.get() || !policy.armed) return false
        val claim = control.snapshot()
        if (claim.terminal || claim.seekPending) return false
        val p = g.player
        val liveOffset = p.currentLiveOffset
        val snapshot = AndroidLlhlsRecoveryPolicy.Snapshot(
            epoch = g.epoch,
            nowMs = SystemClock.elapsedRealtime(),
            liveOffsetMs = if (liveOffset == C.TIME_UNSET) null else liveOffset,
            readyLive = p.isCurrentMediaItemLive,
            playingIntent = claim.intendedPlaying && p.playWhenReady,
            outputValid = outputValidOnHandlerThread(g),
            activeNetwork = hasActiveNetwork(),
        )
        val claimed = policy.claimReady(snapshot)
        refreshRecoveryDiagnostic()
        if (experimentalLlhls) {
            AndroidLlhlsDiagnosticListener.record(
                context, p, g.epoch, "recovery_claim_eval",
                mapOf(
                    "claimed" to claimed, "lastDecision" to policy.lastDecision,
                    "armed" to policy.armed, "actionCount" to policy.actionCount,
                    "controlVersion" to claim.version, "claimNowMs" to snapshot.nowMs,
                    "claimLiveOffsetMs" to snapshot.liveOffsetMs, "claimReadyLive" to snapshot.readyLive,
                    "claimPlayingIntent" to snapshot.playingIntent, "claimOutputValid" to snapshot.outputValid,
                    "claimActiveNetwork" to snapshot.activeNetwork,
                ),
            )
        }
        if (!claimed) return false
        Log.i(TAG, "LL-HLS recovery claimed: epoch=${g.epoch} liveOffsetMs=$liveOffset actions=${policy.actionCount}")
        return replaceGraphOnHandlerThread(g, claim.version, ReplacementTrigger.READY)
    }

    /**
     * Experimental: evaluates the bounded behind-live-window recovery claim for [g] from inside
     * its fatal `onPlayerError` callback.  Shares the READY claim's budget, control recheck and
     * graph replacement; requires neither an armed buffering transition nor an offset threshold.
     * Returns `true` only when [g] was retired; the caller must then skip the fatal path.  A
     * declined claim, or one cancelled by a concurrent control before retirement, returns `false`
     * and the caller applies the existing fatal handling.  The player is read only before
     * retirement.  HandlerThread only.
     */
    private fun claimBehindLiveWindowRecoveryOnHandlerThread(g: HttpAdaptivePlaybackGraph): Boolean {
        val policy = recoveryPolicy ?: return false
        if (recoveryDisabled.get()) return false
        val claim = control.snapshot()
        if (claim.terminal || claim.seekPending) return false
        val p = g.player
        val snapshot = AndroidLlhlsRecoveryPolicy.FailureSnapshot(
            epoch = g.epoch,
            nowMs = SystemClock.elapsedRealtime(),
            live = p.isCurrentMediaItemLive,
            playingIntent = claim.intendedPlaying && p.playWhenReady,
            outputValid = outputValidOnHandlerThread(g),
            activeNetwork = hasActiveNetwork(),
        )
        val claimed = policy.claimBehindLiveWindow(snapshot)
        refreshRecoveryDiagnostic()
        AndroidLlhlsDiagnosticListener.record(
            context, p, g.epoch, "recovery_error_claim_eval",
            mapOf(
                "trigger" to "behind_live_window",
                "errorCode" to PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW,
                "claimed" to claimed, "lastDecision" to policy.lastDecision,
                "renderedEpoch" to policy.renderedEpoch, "actionCount" to policy.actionCount,
                "controlVersion" to claim.version, "claimNowMs" to snapshot.nowMs,
                "claimLive" to snapshot.live, "claimPlayingIntent" to snapshot.playingIntent,
                "claimOutputValid" to snapshot.outputValid, "claimActiveNetwork" to snapshot.activeNetwork,
            ),
        )
        if (!claimed) return false
        Log.i(TAG, "LL-HLS behind-live-window recovery claimed: epoch=${g.epoch} actions=${policy.actionCount}")
        return replaceGraphOnHandlerThread(g, claim.version, ReplacementTrigger.BEHIND_LIVE_WINDOW)
    }

    /** Why a graph is replaced.  Automatic triggers honour the one-way recovery revocation. */
    private enum class ReplacementTrigger { READY, BEHIND_LIVE_WINDOW, EXPLICIT_PLAY }

    /**
     * Experimental graph replacement, executed synchronously on the owner thread by a claiming
     * READY or behind-live-window callback (the qualified lab sequence) or by an explicit Play
     * that validated a live resume intent: invalidate the epoch, publish Buffering, retire the
     * old graph (listener, output, player, reader), then build a fresh graph from the original
     * configuration and headers.  The retired graph publishes nothing further.
     *
     * Cancellation ownership: public controls transition [control] while retirement blocks this
     * thread, so the snapshot is re-read against the version captured at claim time
     * - before retirement: a newer control version, stop or release keeps the old graph current
     *   (returns `false`; the caller keeps publishing for it or reconciles its intent).  An
     *   automatic trigger is additionally cancelled by a revoked recovery, and its consumed
     *   attempt is not restored;
     * - after retirement: release means nothing is installed; stop (or the session's fatal
     *   failure stop) means Idle with no prepare or autoplay; pause or a pending seek means a
     *   usable held graph is prepared under the *current* intent so later controls keep working.
     * An automatic cancellation leaves recovery disabled; an [ReplacementTrigger.EXPLICIT_PLAY]
     * cancellation never newly revokes it and never touches the automatic budget.  Cancellation
     * never publishes a failure, and stop / release win over a construction failure raised after
     * they landed.
     *
     * @return `true` when [old] was retired.
     */
    private fun replaceGraphOnHandlerThread(
        old: HttpAdaptivePlaybackGraph,
        claimVersion: Long,
        trigger: ReplacementTrigger,
    ): Boolean {
        val automatic = trigger != ReplacementTrigger.EXPLICIT_PLAY
        val config = activeConfig
        if (config == null) {
            if (automatic) disableRecovery("replace_without_config")
            return false
        }
        // 0. Recheck before retirement: a control that arrived since the claim owns the graph.
        val beforeRetire = control.snapshot()
        if (beforeRetire.terminal || beforeRetire.version != claimVersion ||
            (automatic && recoveryDisabled.get())
        ) {
            if (automatic) disableRecovery("replacement_cancelled_before_retire")
            return false
        }
        // 1. Invalidate the epoch before retirement: every old-graph callback is now stale.
        if (currentGraph === old) currentGraph = null
        // 2. Publish the existing Buffering state for the session.
        emitState(HttpAdaptivePlaybackState.Buffering(0))
        listener.onBufferingProgress(0)
        // 3. Retire the old graph in order (player release may block this thread).
        old.retire()
        // 4. Recheck after retirement: controls that landed meanwhile own the outcome.
        val afterRetire = control.snapshot()
        if (afterRetire.released) return true
        if (afterRetire.stopped) {
            emitState(HttpAdaptivePlaybackState.Idle)
            return true
        }
        if (automatic && afterRetire.version != claimVersion) {
            disableRecovery("replacement_cancelled")
        }
        // 5. Build the replacement under the current intent / hold; it must render and report its
        //    size before frames flow.  Install / prepare recheck stop and release once more.
        val prepared = try {
            buildGraphOnHandlerThread(config = config, isReplacement = true)
        } catch (t: Throwable) {
            publishConstructionFailureOnHandlerThread("rebuild", t)
            return true
        }
        if (!prepared) publishCancelledConstructionOnHandlerThread()
        return true
    }

    /**
     * Experimental owner-thread resume for an explicit Play.  Terminal state and a live seek
     * reservation win unchanged (the reservation's own reconciliation releases the hold).  An
     * [HttpAdaptivePlaybackControlState.ResumePosition.EXPLICIT] position keeps ordinary
     * reconciliation and is never consumed.  Otherwise the resume intent is validated and
     * consumed atomically first, even when the rebuild gate below declines (startup, VOD, a
     * graph that never rendered live), so a leftover live intent cannot make a later duplicate
     * Play rebuild.  A rebuild toward live is requested only once this preparation has actually
     * played live ([hasStartedLivePlayback]; a paused poster frame alone never qualifies) and
     * only for the current, unretired graph that already rendered a live frame, still plays a
     * live item with no error and not ENDED, has a valid output, and either carried a live
     * intent or has its SDK held.  Every declined
     * or rejected path reconciles the current intent / hold; nothing autoplays a stale value.
     * The rebuild bypasses only the automatic revocation; budget and cooldown are untouched.
     */
    private fun resumeExperimentalPlaybackOnHandlerThread() {
        val s = control.snapshot()
        if (s.terminal || s.seekPending) return
        if (s.resumePosition == HttpAdaptivePlaybackControlState.ResumePosition.EXPLICIT) {
            reconcileSeekHoldOnHandlerThread()
            return
        }
        val liveIntent = s.resumePosition == HttpAdaptivePlaybackControlState.ResumePosition.LIVE
        if (!control.consumeResumeIntent(expectedVersion = s.version)) {
            // A control landed since the snapshot, or intent is no longer playing: apply the
            // current intent / hold instead of a stale `true`.
            reconcileSeekHoldOnHandlerThread()
            return
        }
        val g = currentGraph ?: return
        if (g.isRetired) return
        val p = g.player
        val rebuild = hasStartedLivePlayback &&
            g.hasRenderedLiveFrame &&
            p.isCurrentMediaItemLive &&
            p.playbackState != Player.STATE_ENDED &&
            p.playerError == null &&
            outputValidOnHandlerThread(g) &&
            (liveIntent || !p.playWhenReady)
        if (!rebuild) {
            reconcileSeekHoldOnHandlerThread()
            return
        }
        val liveOffset = p.currentLiveOffset
        AndroidLlhlsDiagnosticListener.record(
            context, p, g.epoch, "live_resume_requested",
            mapOf(
                "oldEpoch" to g.epoch, "controlVersion" to s.version,
                "resumePosition" to s.resumePosition.name, "playWhenReady" to p.playWhenReady,
                "liveOffsetMs" to if (liveOffset == C.TIME_UNSET) null else liveOffset,
            ),
        )
        if (!replaceGraphOnHandlerThread(g, s.version, ReplacementTrigger.EXPLICIT_PLAY)) {
            // Cancelled before retirement: a newer control owns the still-current graph.
            reconcileSeekHoldOnHandlerThread()
            return
        }
        // Only a graph installed by this replacement is read here; the old one is retired.
        val fresh = currentGraph ?: return
        if (fresh.isRetired) return
        AndroidLlhlsDiagnosticListener.record(
            context, fresh.player, fresh.epoch, "live_resume_rebuilt",
            mapOf(
                "oldEpoch" to g.epoch, "newEpoch" to fresh.epoch,
                "controlVersion" to control.snapshot().version,
            ),
        )
    }

    /**
     * Experimental: owner-thread hold reconciliation, posted by [beginSeek], [commitSeek],
     * [cancelSeek] and the experimental [pause].  Reads the current graph and snapshot at execution time.  With no live
     * reservation only the current playing intent is restored; with one, SDK playback is held and
     * a committed target is issued if the player can seek now (retained otherwise).
     */
    private fun reconcileSeekHoldOnHandlerThread() {
        val s = control.snapshot()
        if (s.terminal) return
        val g = currentGraph ?: return
        val p = g.player
        if (!s.seekPending) {
            p.playWhenReady = s.intendedPlaying
            return
        }
        p.playWhenReady = false
        if (s.seekCommitted) applyCommittedSeekOnHandlerThread(g)
    }

    /**
     * Experimental: issues the current committed reservation on [g] when the player can seek
     * (READY / ENDED; retained while IDLE / BUFFERING), completes the ticket, then restores only
     * the current playing intent if no newer hold, stop or release exists.  Each committed ticket
     * is applied at most once; a ticket superseded between issue and completion restores nothing.
     *
     * @return `true` when a target was issued (the caller publishes nothing further for this
     *   callback; the post-seek READY publishes).
     */
    private fun applyCommittedSeekOnHandlerThread(g: HttpAdaptivePlaybackGraph): Boolean {
        val s = control.snapshot()
        if (s.terminal || !s.seekPending || !s.seekCommitted) return false
        val target = s.seekPositionMs ?: return false
        val p = g.player
        val playbackState = p.playbackState
        if (playbackState == Player.STATE_IDLE || playbackState == Player.STATE_BUFFERING) return false
        p.seekTo(target)
        emitState(HttpAdaptivePlaybackState.Seeking(target))
        if (control.completeSeek(s.seekTicket)) {
            val after = control.snapshot()
            if (!after.terminal && !after.seekPending) p.playWhenReady = after.intendedPlaying
        }
        return true
    }

    /**
     * Publishes the outcome of a cancelled construction: nothing after release, otherwise Idle so
     * the session never remains in Preparing / Buffering.  HandlerThread only.
     */
    private fun publishCancelledConstructionOnHandlerThread() {
        if (released) return
        emitState(HttpAdaptivePlaybackState.Idle)
    }

    /**
     * Publishes a construction/rebuild failure exactly once and revokes recovery.  Partial
     * resources were already retired by [buildGraphOnHandlerThread].  For experimental sessions
     * a stop or release that landed before publication wins over the failure.  HandlerThread only.
     */
    private fun publishConstructionFailureOnHandlerThread(stage: String, t: Throwable) {
        disableRecovery("${stage}_exception")
        Log.e(TAG, "Graph $stage failed", t)
        if (experimentalLlhls) {
            val s = control.snapshot()
            if (s.released) return
            if (s.stopped) {
                emitState(HttpAdaptivePlaybackState.Idle)
                return
            }
        }
        val errorCode = PlaybackException.ERROR_CODE_UNSPECIFIED
        val msg = "errorCode=$errorCode; ${stage}_exception:${t.javaClass.simpleName}:${t.message}"
        emitState(HttpAdaptivePlaybackState.Failed(errorCode = errorCode, message = msg))
        listener.onPlaybackError(errorCode, msg)
    }

    /** Whether [g] currently has a valid video output (bound reader or pending external surface). */
    private fun outputValidOnHandlerThread(g: HttpAdaptivePlaybackGraph): Boolean =
        g.bridge?.surface?.isValid ?: (pendingSurface?.isValid ?: false)

    /**
     * Synchronous network presence check at decision time (lab `hasActiveNetwork`).  No callback
     * is registered; a `null` network or any exception reads as absent.
     */
    private fun hasActiveNetwork(): Boolean = try {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        cm?.activeNetwork != null
    } catch (t: Throwable) {
        false
    }

    /** Refreshes the race-free diagnostic mirror.  HandlerThread only. */
    private fun refreshRecoveryDiagnostic() {
        val policy = recoveryPolicy
        recoveryDiagnosticText = policy?.toDiagnosticString() ?: if (experimentalLlhls) "inactive" else "not_experimental"
    }

    /**
     * Emits [newState] to the listener and updates [currentState].
     * Must only be called from the HandlerThread.
     *
     * Once [released] is true, only [HttpAdaptivePlaybackState.Released] may be forwarded to the
     * listener.  Any other state is silently dropped (invariant 7).
     */
    private fun emitState(newState: HttpAdaptivePlaybackState) {
        if (released && newState !is HttpAdaptivePlaybackState.Released) return
        currentState = newState
        listener.onStateChanged(newState)
    }

    /**
     * Constructs the appropriate [MediaSource] for [config].
     *
     * - [AdaptiveStreamFormat.HLS]  -> [HlsMediaSource] (forces HLS even if URI lacks .m3u8).
     *   Experimental sessions additionally attach the tested live configuration and the guarded
     *   [AndroidLlhlsPlaylistParserFactory].
     * - [AdaptiveStreamFormat.DASH] -> [DashMediaSource] (forces DASH MPD parsing).
     * - [AdaptiveStreamFormat.AUTO] -> [DefaultMediaSourceFactory] (sniffs URI extension / MIME).
     *
     * Must only be called from the HandlerThread (called during graph construction).
     */
    private fun buildMediaSource(config: HttpAdaptiveStreamConfig, epoch: Long): MediaSource {
        val uri = android.net.Uri.parse(config.uri)
        // Phase 4C6B: obtain the appropriate DataSource.Factory (cache-backed or plain network)
        // for this config.  Cache failures are fully handled inside buildDataSourceFactory and
        // never propagate as exceptions here.
        val dataSourceFactory = buildDataSourceFactory(config)

        return when (config.formatHint) {
            AdaptiveStreamFormat.HLS -> {
                val itemBuilder = MediaItem.Builder()
                    .setUri(uri)
                    .setMimeType(MimeTypes.APPLICATION_M3U8)
                val factory = HlsMediaSource.Factory(dataSourceFactory)
                if (experimentalLlhls) {
                    itemBuilder.setLiveConfiguration(AndroidLlhlsProfile.buildLiveConfiguration())
                    factory
                        .setAllowChunklessPreparation(true)
                        .setPlaylistParserFactory(
                            AndroidLlhlsPlaylistParserFactory(
                                targetOffsetMs = AndroidLlhlsProfile.TARGET_OFFSET_MS,
                                graphEpoch = epoch,
                            )
                        )
                }
                factory.createMediaSource(itemBuilder.build())
            }
            AdaptiveStreamFormat.DASH -> {
                val mediaItem = MediaItem.Builder()
                    .setUri(uri)
                    .setMimeType(MimeTypes.APPLICATION_MPD)
                    .build()
                DashMediaSource.Factory(dataSourceFactory)
                    .createMediaSource(mediaItem)
            }
            AdaptiveStreamFormat.AUTO -> {
                val mediaItem = MediaItem.fromUri(uri)
                DefaultMediaSourceFactory(dataSourceFactory)
                    .createMediaSource(mediaItem)
            }
        }
    }

    /**
     * Phase 4C6B: Builds a [DataSource.Factory] for the given [config], routing through the
     * [AndroidDagPlaybackCacheManager] when [HttpAdaptiveStreamConfig.cacheConfig.enabled] is
     * `true` and cache initialisation succeeded.
     *
     * - **Cache disabled** ([AndroidDagPlaybackCacheConfig.enabled] = `false`, the default) or
     *   **cache init failed**: returns a plain [DefaultHttpDataSource.Factory] with [httpHeaders]
     *   applied — identical to pre-Phase-4C6B behaviour.  Existing callers are unaffected.
     * - **Cache enabled and available**: returns a [androidx.media3.datasource.cache.CacheDataSource.Factory]
     *   wrapping [SimpleCache] with an upstream [DefaultHttpDataSource.Factory] and
     *   [androidx.media3.datasource.cache.CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR] so that
     *   individual cache I/O failures fall back to network without interrupting playback.
     *
     * Cache failures inside [AndroidDagPlaybackCacheManager.buildDataSourceFactory] are swallowed
     * by that class; this method never throws due to cache errors.
     *
     * Must only be called from the HandlerThread.
     *
     * @param config Full [HttpAdaptiveStreamConfig]; [httpHeaders] and [cacheConfig] are read.
     */
    private fun buildDataSourceFactory(config: HttpAdaptiveStreamConfig): DataSource.Factory {
        val cacheConfig = config.cacheConfig
        return if (cacheConfig.enabled) {
            // Cache is opt-in: delegate to the manager which handles init failure safely.
            try {
                val eventListener = object : CacheDataSource.EventListener {
                    override fun onCachedBytesRead(cacheSizeBytes: Long, cachedBytesRead: Long) {
                        listener.onPlaybackCacheTelemetry(
                            cacheSizeBytes = if (cacheSizeBytes >= 0L) cacheSizeBytes else 0L,
                            cachedBytesReadDelta = if (cachedBytesRead >= 0L) cachedBytesRead else 0L,
                            cacheIgnoredDelta = 0,
                            lastCacheIgnoredReason = null,
                        )
                    }

                    override fun onCacheIgnored(reason: Int) {
                        val reasonStr = when (reason) {
                            CacheDataSource.CACHE_IGNORED_REASON_ERROR -> "error"
                            CacheDataSource.CACHE_IGNORED_REASON_UNSET_LENGTH -> "unset_length"
                            else -> "unknown_$reason"
                        }
                        listener.onPlaybackCacheTelemetry(
                            cacheSizeBytes = -1L,
                            cachedBytesReadDelta = 0L,
                            cacheIgnoredDelta = 1,
                            lastCacheIgnoredReason = reasonStr,
                        )
                    }
                }
                val manager = AndroidDagPlaybackCacheManager.getOrCreate(context, cacheConfig)
                manager.buildDataSourceFactory(config.httpHeaders, eventListener)
            } catch (t: Throwable) {
                // Defensive: manager construction should not throw, but if it does, fall back
                // to plain DefaultHttpDataSource to preserve playback (cache failure must not
                // fail playback per Phase 4C6B invariant).
                Log.w(
                    TAG,
                    "Phase4C6B: cache manager getOrCreate threw – falling back to DefaultHttpDataSource: ${t.message}",
                    t,
                )
                buildFallbackHttpDataSourceFactory(config.httpHeaders)
            }
        } else {
            // Cache is disabled (default): use plain DefaultHttpDataSource — behaviour-preserving.
            buildFallbackHttpDataSourceFactory(config.httpHeaders)
        }
    }

    /**
     * Builds a plain [DefaultHttpDataSource.Factory] and applies [httpHeaders] (if any) via
     * [DefaultHttpDataSource.Factory.setDefaultRequestProperties].
     *
     * This is the pre-Phase-4C6B factory path.  It is retained as the explicit fallback so that
     * the cache-routing logic in [buildDataSourceFactory] has a clear, named escape hatch.
     *
     * Must only be called from the HandlerThread.
     *
     * @param httpHeaders Optional header map.  Null or empty means no custom headers.
     */
    private fun buildFallbackHttpDataSourceFactory(
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
        private const val TAG = "HttpAdaptiveAdapter"

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
