// Copyright (c) Connects - Phase 4C1B: HttpAdaptivePlaybackAdapter scaffold.
// Scaffold only. No live network streaming is claimed or verified here.

package com.connects.vanguard_media_engine.streaming

/**
 * Callback interface for [HttpAdaptivePlaybackAdapter] event notifications.
 *
 * All callbacks are dispatched on the adapter's dedicated `HandlerThread`
 * (`HttpAdaptivePlaybackLoop_<id>`), not the Flutter UI thread.  Callers that need to update UI
 * must post to the main thread themselves.
 *
 * Implementations must be lightweight and non-blocking.  Do not call back into the adapter from
 * inside a callback unless documented as re-entrant-safe.
 */
interface HttpAdaptivePlaybackListener {

    /**
     * Called whenever the adapter transitions to a new [HttpAdaptivePlaybackState].
     *
     * This is the primary event entry point.  Every distinct state transition (including
     * re-emission of the same state with updated metadata, e.g. [HttpAdaptivePlaybackState.Playing]
     * with an updated position) triggers this callback.
     *
     * @param state The new state.  Guaranteed non-null.
     */
    fun onStateChanged(state: HttpAdaptivePlaybackState)

    /**
     * Called when the decoded video track dimensions are first known or change (e.g. mid-stream
     * resolution switch during ABR adaptation).
     *
     * @param width  New video width in pixels.
     * @param height New video height in pixels.
     */
    fun onVideoSizeChanged(width: Int, height: Int)

    /**
     * Periodic buffering progress notification while the player is filling its look-ahead buffer.
     *
     * Emitted at a best-effort rate (typically once per second during active buffering).  The
     * caller should treat this as informational; authoritative state is always [onStateChanged].
     *
     * @param bufferedPercent 0-100 integer percentage of the current playback window that is
     *                        pre-buffered.
     */
    fun onBufferingProgress(bufferedPercent: Int)

    /**
     * Called when a non-fatal or fatal playback error occurs.
     *
     * A fatal error also transitions the state to [HttpAdaptivePlaybackState.Failed] and triggers
     * [onStateChanged].  Non-fatal diagnostic errors may be reported here without a state change.
     *
     * @param errorCode [androidx.media3.common.PlaybackException.errorCode] integer.
     * @param message   Human-readable diagnostic string (error code + underlying cause chain).
     */
    fun onPlaybackError(errorCode: Int, message: String)
}
