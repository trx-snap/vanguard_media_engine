// Copyright (c) Connects - Phase 4C6B: Android Media3 read-through playback cache backend.
// Immutable configuration data-class. No storage or network I/O is performed here.

package com.connects.vanguard_media_engine.streaming

/**
 * Immutable configuration for the Android Media3 read-through playback cache substrate.
 *
 * Cache is **opt-in per stream**.  The safe default ([enabled] = `false`) preserves all
 * existing playback behaviour without any change; callers that do not pass this config continue
 * to use [DefaultHttpDataSource] exactly as before (Phase 4C1B/4C5B behaviour).
 *
 * ## Validation
 * - [maxCacheBytes] must be positive (> 0).
 * - [cacheDirectoryName] must be non-blank and must not contain the OS path-separator characters
 *   `/` or `\`.  The directory is resolved relative to `applicationContext.cacheDir`; a
 *   directory-traversal component in the name is therefore rejected.
 *
 * ## Cache key policy (G-CACHE-KEY)
 * Phase 4C6B uses Media3 default cache-key derivation only (URI-based).  No custom cache key is
 * accepted or applied in this slice.  Signed URL tokens, auth-bearing query parameters, and
 * expiry/version parameters are therefore preserved as-is and not stripped or normalised here.
 * Safe custom key normalisation belongs in a later public API/key-normalisation slice.
 *
 * @param enabled            Whether the Media3 cache substrate is active for this stream.
 *                           Defaults to `false`; all existing callers compile unchanged.
 * @param maxCacheBytes      Maximum disk budget for the shared [SimpleCache] directory, in bytes.
 *                           Must be > 0.  Default: 512 MiB.
 * @param cacheDirectoryName Subdirectory name under `applicationContext.cacheDir` where the
 *                           [SimpleCache] stores its data.  Must be non-blank and must not
 *                           contain path separators.  Default: `"vanguard_playback_cache"`.
 */
data class AndroidDagPlaybackCacheConfig(
    val enabled: Boolean = false,
    val maxCacheBytes: Long = 512L * 1024L * 1024L,  // 512 MiB
    val cacheDirectoryName: String = "vanguard_playback_cache",
) {
    init {
        require(maxCacheBytes > 0L) {
            "AndroidDagPlaybackCacheConfig: maxCacheBytes must be > 0, got $maxCacheBytes."
        }
        require(cacheDirectoryName.isNotBlank()) {
            "AndroidDagPlaybackCacheConfig: cacheDirectoryName must not be blank."
        }
        require(!cacheDirectoryName.contains('/') && !cacheDirectoryName.contains('\\')) {
            "AndroidDagPlaybackCacheConfig: cacheDirectoryName must not contain path separators," +
                " got '$cacheDirectoryName'."
        }
        // Phase 4C6B relies on Media3 default cache-key derivation (URI-based).
        // No custom cache key is applied here; see G-CACHE-KEY policy above.
    }
}
