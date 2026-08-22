// Copyright (c) Connects - Phase 4C1B: HttpAdaptivePlaybackAdapter scaffold.
// Scaffold only. No live network streaming is claimed or verified here.

package com.connects.vanguard_media_engine.streaming

/**
 * Deterministic, sealed state taxonomy for [HttpAdaptivePlaybackAdapter].
 *
 * States are emitted to [HttpAdaptivePlaybackListener.onStateChanged] and always reflect the
 * current adapter lifecycle position.  State transitions follow the table in
 * `Phase_4C1A_HttpAdaptivePlaybackAdapter_Readiness.md Section 7`.
 *
 * Terminal states:
 * - [Released]: the adapter has been released and must not be used again.
 *
 * States carrying metadata (position, size, error) expose it through their properties.
 */
sealed class HttpAdaptivePlaybackState {

    /** Adapter constructed or [HttpAdaptivePlaybackAdapter.stop] completed.  Player is idle. */
    object Idle : HttpAdaptivePlaybackState()

    /**
     * [HttpAdaptivePlaybackAdapter.prepare] posted and pending; ExoPlayer is being created and
     * [androidx.media3.common.Player.prepare] has been called.
     */
    object Preparing : HttpAdaptivePlaybackState()

    /**
     * ExoPlayer emitted [androidx.media3.common.Player.STATE_BUFFERING].  Network segment
     * downloads are in progress.
     *
     * @param bufferedPercent 0-100 percentage of the look-ahead buffer currently filled.
     */
    data class Buffering(val bufferedPercent: Int) : HttpAdaptivePlaybackState()

    /**
     * ExoPlayer emitted [androidx.media3.common.Player.STATE_READY] and [playWhenReady] is false.
     * First frame is decodeable; seeks are now applied immediately.
     *
     * @param durationMs Total stream duration in milliseconds, or [androidx.media3.common.C.TIME_UNSET]
     *                   for live streams.
     * @param videoWidth  Decoded video width in pixels (0 if audio-only or not yet known).
     * @param videoHeight Decoded video height in pixels (0 if audio-only or not yet known).
     */
    data class Ready(
        val durationMs: Long,
        val videoWidth: Int,
        val videoHeight: Int,
    ) : HttpAdaptivePlaybackState()

    /**
     * Player is actively rendering frames ([playWhenReady] = true, STATE_READY).
     *
     * @param positionMs  Current playhead position in milliseconds.
     * @param durationMs  Total stream duration in milliseconds (or [androidx.media3.common.C.TIME_UNSET]).
     * @param bufferedPercent 0-100 percentage of the look-ahead buffer filled.
     */
    data class Playing(
        val positionMs: Long,
        val durationMs: Long,
        val bufferedPercent: Int,
    ) : HttpAdaptivePlaybackState()

    /**
     * Playback intentionally paused by the caller ([playWhenReady] = false).
     *
     * @param positionMs Current playhead position in milliseconds.
     * @param durationMs Total stream duration in milliseconds.
     */
    data class Paused(
        val positionMs: Long,
        val durationMs: Long,
    ) : HttpAdaptivePlaybackState()

    /**
     * A seek operation has been dispatched and ExoPlayer is re-buffering from the target position.
     *
     * @param targetPositionMs The requested seek target in milliseconds.
     */
    data class Seeking(val targetPositionMs: Long) : HttpAdaptivePlaybackState()

    /**
     * ExoPlayer emitted [androidx.media3.common.Player.STATE_ENDED].  The stream reached its
     * natural end-of-stream.  Playback may restart via a seek-to-zero + play.
     *
     * @param durationMs Final known stream duration.
     */
    data class Ended(val durationMs: Long) : HttpAdaptivePlaybackState()

    /**
     * ExoPlayer emitted [androidx.media3.common.Player.Listener.onPlayerError].
     *
     * @param errorCode  [androidx.media3.common.PlaybackException.errorCode] integer.
     * @param message    Human-readable description combining error code and underlying cause.
     */
    data class Failed(
        val errorCode: Int,
        val message: String,
    ) : HttpAdaptivePlaybackState()

    /**
     * Terminal state.  [HttpAdaptivePlaybackAdapter.release] has completed.  The adapter instance
     * must be discarded; no further calls are permitted.
     */
    object Released : HttpAdaptivePlaybackState()
}
