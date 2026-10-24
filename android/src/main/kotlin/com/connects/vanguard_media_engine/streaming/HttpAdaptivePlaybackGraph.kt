// Copyright (c) Connects - Android LL-HLS experimental transfer: one player graph per epoch.
// Extracted from HttpAdaptivePlaybackAdapter so that retirement of a player, its listener and its
// ImageReader bridge is a single idempotent, exception-tolerant operation.

package com.connects.vanguard_media_engine.streaming

import android.util.Log
import android.view.Surface
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One ExoPlayer graph: a monotonically increasing [epoch], the [player] built for it, the
 * per-player [Player.Listener] that captured that epoch, and the headless
 * [HttpAdaptiveImageReaderBridge] currently bound as the player's video output.
 *
 * ## Ownership
 * - [HttpAdaptivePlaybackAdapter] constructs the player, listener and bridge and keeps the public
 *   controls; this class owns their retirement.
 * - Exactly one graph is current at a time. Replacing a graph means the adapter clears its
 *   reference (invalidating the epoch) **before** calling [retire] on the old graph.
 *
 * ## Threading
 * All members are confined to the adapter's HandlerThread. [retire] is idempotent and attempts
 * every cleanup step even when an earlier step throws.
 *
 * ## Stale callbacks
 * Player callbacks compare their captured epoch against the adapter's current graph. Bridge
 * callbacks additionally carry the [bridgeToken] issued when their reader was bound, so frames
 * from a closed or replaced reader are rejected by [acceptsFrames].
 *
 * @param isReplacement `true` for a graph built by recovery. Its frames are withheld from the
 *        session until its first positive video-size callback has been forwarded, so the
 *        session's existing native recreation path re-anchors rendering before any frame.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class HttpAdaptivePlaybackGraph(
    val epoch: Long,
    val player: ExoPlayer,
    private val playerListener: Player.Listener,
    val isReplacement: Boolean,
) {

    companion object {
        private const val TAG = "HttpAdaptiveGraph"

        /** Token value meaning "no bridge bound". Issued tokens are always positive. */
        const val NO_BRIDGE_TOKEN = 0L
    }

    private val retired = AtomicBoolean(false)

    /** Bridge currently bound as the player's output, if the headless path is active. */
    var bridge: HttpAdaptiveImageReaderBridge? = null
        private set

    /** Token of [bridge]; [NO_BRIDGE_TOKEN] when no bridge is bound. */
    var bridgeToken: Long = NO_BRIDGE_TOKEN
        private set

    /** Set by the adapter once this graph's first positive video size reached the session. */
    var videoSizeDelivered: Boolean = false

    /**
     * Set by the adapter once this graph rendered its first frame while its current item was
     * live.  Consulted only by an explicit resume; never cleared for the graph's lifetime.
     */
    var hasRenderedLiveFrame: Boolean = false

    val isRetired: Boolean get() = retired.get()

    /** Registers the per-epoch listener. Called once, after the adapter has made this graph current. */
    fun attachListener() {
        player.addListener(playerListener)
    }

    /** Binds [newBridge] as the video output. Any previously bound bridge is released first. */
    fun bindBridge(newBridge: HttpAdaptiveImageReaderBridge, token: Long) {
        require(token != NO_BRIDGE_TOKEN) { "bridge token must not be NO_BRIDGE_TOKEN" }
        releaseBridge()
        bridge = newBridge
        bridgeToken = token
        player.setVideoSurface(newBridge.surface)
    }

    /** Binds an external [surface] (or detaches with `null`). Releases any bound bridge first. */
    fun bindExternalSurface(surface: Surface?) {
        releaseBridge()
        player.setVideoSurface(surface)
    }

    /** Detaches and releases the bound bridge, if any. The player keeps running. */
    fun releaseBridge() {
        val b = bridge ?: return
        bridge = null
        bridgeToken = NO_BRIDGE_TOKEN
        try {
            player.setVideoSurface(null)
        } finally {
            b.release()
        }
    }

    /**
     * Whether a frame delivered by the reader bound under [token] for [expectedEpoch] may reach
     * the session right now.
     */
    fun acceptsFrames(expectedEpoch: Long, token: Long): Boolean {
        if (retired.get()) return false
        if (expectedEpoch != epoch) return false
        if (token == NO_BRIDGE_TOKEN || token != bridgeToken) return false
        return !isReplacement || videoSizeDelivered
    }

    /**
     * Idempotent, ordered retirement: remove listener, detach output, stop, release, close reader.
     * Each step runs even if an earlier one threw; the first failure is logged.
     */
    fun retire() {
        if (!retired.compareAndSet(false, true)) return
        val b = bridge
        bridge = null
        bridgeToken = NO_BRIDGE_TOKEN
        step("removeListener") { player.removeListener(playerListener) }
        step("detachSurface") { player.setVideoSurface(null) }
        step("stop") { player.stop() }
        step("release") { player.release() }
        if (b != null) step("closeReader") { b.release() }
    }

    private inline fun step(name: String, block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            Log.w(TAG, "epoch=$epoch retire step '$name' threw", t)
        }
    }
}
