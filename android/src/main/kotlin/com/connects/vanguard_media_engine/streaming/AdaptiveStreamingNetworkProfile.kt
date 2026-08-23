// Copyright (c) Connects - Phase 4C5B: Streaming network profile policy.

package com.connects.vanguard_media_engine.streaming

/**
 * Streaming network profile for adaptive HTTP playback.
 *
 * Controls which [AdaptiveStreamingNetworkPolicy] is applied when building an ExoPlayer
 * instance in [HttpAdaptivePlaybackAdapter.prepare].
 *
 * [AUTO]        Preserve all Media3 / ExoPlayer defaults.  No custom [LoadControl] or
 *               [DefaultTrackSelector] parameters are installed.  This is the default and
 *               matches the playback behaviour that existed before Phase 4C5B.
 *
 * [STABLE]      A conservative policy tuned for reliable, stable network conditions.
 *               Uses longer buffer windows to smooth over transient bandwidth dips without
 *               applying a hard bitrate cap, allowing the ABR algorithm to choose the best
 *               quality the link can sustain.
 *
 * [CONSTRAINED] A poor-network policy that combines long pre-roll / rebuffer windows with
 *               explicit bitrate caps ([AdaptiveStreamingNetworkPolicy.maxVideoBitrate] /
 *               [AdaptiveStreamingNetworkPolicy.maxAudioBitrate]) to prevent the player from
 *               attempting high-quality renditions that a constrained link cannot deliver.
 *
 * [LOW_LATENCY] A short-buffer, low-delay policy suitable for near-live or LL-HLS streams
 *               where keeping the viewer close to the live edge is more important than
 *               rebuffer immunity.  No bitrate cap is applied.
 */
enum class AdaptiveStreamingNetworkProfile {
    AUTO,
    STABLE,
    CONSTRAINED,
    LOW_LATENCY,
}
