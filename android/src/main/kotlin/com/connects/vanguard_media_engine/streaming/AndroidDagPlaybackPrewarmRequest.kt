// Copyright (c) Connects - Phase 4C6C: Android Media3 CacheWriter prewarm/prefetch foundation.
// Immutable prewarm request data class.  No I/O is performed here.

package com.connects.vanguard_media_engine.streaming

/**
 * Vanguard Android True-DAG Phase 4C6C: Immutable prewarm request descriptor.
 *
 * Describes a single bounded CacheWriter prewarm job targeting one URI.  Construction validates
 * every field; invalid inputs throw [IllegalArgumentException] before any I/O is attempted.
 *
 * ## Cache key policy (G-CACHE-KEY)
 * Phase 4C6C uses Media3 default cache-key derivation only (URI-based).  No custom cache key is
 * accepted or applied in this slice.
 *
 * ## Adaptive-manifest disclaimer
 * For HLS/DASH manifest URLs this request may cache the addressed manifest resource; segment
 * traversal / manifest-aware prewarm is explicitly deferred to a later slice.
 *
 * @param requestId    Non-blank string uniquely identifying this job within the engine.
 * @param uri          Absolute HTTP or HTTPS URI of the resource to prewarm.
 * @param httpHeaders  Optional request headers forwarded to [DefaultHttpDataSource].
 * @param maxBytes     Maximum bytes to cache (DataSpec length cap).  Must be > 0.
 *                     Default: 2 MiB.
 * @param cacheConfig  Cache configuration.  [AndroidDagPlaybackCacheConfig.enabled] must be
 *                     `true`; a disabled config is rejected at construction time.
 */
data class AndroidDagPlaybackPrewarmRequest(
    val requestId: String,
    val uri: String,
    val httpHeaders: Map<String, String>? = null,
    val maxBytes: Long = 2L * 1024L * 1024L,
    val cacheConfig: AndroidDagPlaybackCacheConfig = AndroidDagPlaybackCacheConfig(enabled = true),
) {
    init {
        require(requestId.isNotBlank()) {
            "AndroidDagPlaybackPrewarmRequest: requestId must not be blank."
        }
        require(uri.startsWith("http://") || uri.startsWith("https://")) {
            "AndroidDagPlaybackPrewarmRequest: uri must be an absolute HTTP or HTTPS URL, got '$uri'."
        }
        require(maxBytes > 0L) {
            "AndroidDagPlaybackPrewarmRequest: maxBytes must be > 0, got $maxBytes."
        }
        require(cacheConfig.enabled) {
            "AndroidDagPlaybackPrewarmRequest: cacheConfig.enabled must be true for a prewarm request."
        }
        // Phase 4C6C relies on Media3 default cache-key derivation (URI-based); see G-CACHE-KEY.
    }
}
