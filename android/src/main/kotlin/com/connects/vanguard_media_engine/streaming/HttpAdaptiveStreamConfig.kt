// Copyright (c) Connects - Phase 4C1B: HttpAdaptivePlaybackAdapter scaffold.
// Phase 4C5B: Added networkProfile for streaming network policy selection.

package com.connects.vanguard_media_engine.streaming

/**
 * Hint for the desired adaptive streaming container format.
 *
 * [AUTO] delegates format detection to [androidx.media3.exoplayer.source.DefaultMediaSourceFactory]
 * based on URI extension / MIME type sniffing.
 * [HLS]  forces [androidx.media3.exoplayer.hls.HlsMediaSource] regardless of URI extension.
 * [DASH] forces [androidx.media3.exoplayer.dash.DashMediaSource] regardless of URI extension.
 */
enum class AdaptiveStreamFormat {
    AUTO,
    HLS,
    DASH,
}

/**
 * Immutable configuration for a single adaptive HTTP playback session.
 *
 * All validation is local and synchronous; no network I/O occurs inside this class or its
 * constructor.  The [uri] must be a syntactically well-formed absolute `http://` or `https://`
 * URI; this is enforced locally in `init` via [android.net.Uri] parsing without any network call.
 *
 * @param uri            Absolute HTTP or HTTPS URI string pointing to the stream manifest or MPD.
 *                       Must have scheme `http` or `https`; other schemes are rejected at
 *                       construction time.
 * @param formatHint     Format to force on [HttpAdaptivePlaybackAdapter].  Defaults to [AdaptiveStreamFormat.AUTO].
 * @param httpHeaders    Optional map of extra HTTP request headers forwarded to Media3's
 *                       [androidx.media3.datasource.DefaultHttpDataSource].  Keys and values must be
 *                       ASCII strings; null or empty means no extra headers.
 * @param startPositionMs Optional start position in milliseconds.  Must be >= 0.  Null means start
 *                        from the beginning (or live edge for live streams).
 * @param autoPlay       Whether playback should begin immediately once the player reaches
 *                       [HttpAdaptivePlaybackState.Ready].  Defaults to `true`.
 * @param networkProfile Streaming network profile that controls the [AdaptiveStreamingNetworkPolicy]
 *                       applied to the ExoPlayer instance built in [HttpAdaptivePlaybackAdapter].
 *                       Defaults to [AdaptiveStreamingNetworkProfile.AUTO], which preserves all
 *                       Media3 ExoPlayer defaults (no custom LoadControl or TrackSelector).
 */
data class HttpAdaptiveStreamConfig(
    val uri: String,
    val formatHint: AdaptiveStreamFormat = AdaptiveStreamFormat.AUTO,
    val httpHeaders: Map<String, String>? = null,
    val startPositionMs: Long? = null,
    val autoPlay: Boolean = true,
    val networkProfile: AdaptiveStreamingNetworkProfile = AdaptiveStreamingNetworkProfile.AUTO,
) {
    init {
        require(uri.isNotBlank()) {
            "HttpAdaptiveStreamConfig: uri must not be blank."
        }
        // Local, synchronous structural check - no network I/O.
        val parsed = android.net.Uri.parse(uri)
        val scheme = parsed.scheme?.lowercase()
        require(scheme == "http" || scheme == "https") {
            "HttpAdaptiveStreamConfig: uri must use http or https scheme, got scheme='$scheme' for uri='$uri'."
        }
        if (startPositionMs != null) {
            require(startPositionMs >= 0L) {
                "HttpAdaptiveStreamConfig: startPositionMs must be >= 0, got $startPositionMs."
            }
        }
    }
}
