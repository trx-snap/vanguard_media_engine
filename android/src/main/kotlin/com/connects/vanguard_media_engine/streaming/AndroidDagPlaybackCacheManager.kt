// Copyright (c) Connects - Phase 4C6B: Android Media3 read-through playback cache backend.
// Owns the SimpleCache singleton per directory and builds CacheDataSource.Factory instances.

package com.connects.vanguard_media_engine.streaming

import android.content.Context
import android.util.Log
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.database.StandaloneDatabaseProvider
import java.io.File

/**
 * Vanguard Android True-DAG Phase 4C6B: Media3 read-through playback cache manager.
 *
 * Owns **exactly one** [SimpleCache] per cache directory for the lifetime of this manager
 * instance, satisfying the Media3 invariant (G-SINGLE-OWNER in ADR-AND-10):
 * > Only a single `SimpleCache` instance may own a given cache directory at any time.
 *
 * ## Invariants
 * - [SimpleCache] creation is synchronised on the companion `lock` object, keyed by
 *   [AndroidDagPlaybackCacheConfig.cacheDirectoryName].  Concurrent callers requesting the same
 *   directory name share the same [AndroidDagPlaybackCacheManager] instance via
 *   [AndroidDagPlaybackCacheManager.getOrCreate].
 * - Cache creation failures are swallowed; the manager reports [isCacheAvailable] = `false` and
 *   [buildDataSourceFactory] returns a plain [DefaultHttpDataSource.Factory] as fallback.
 * - No cache deletion or cache-directory cleanup is performed here; lifecycle is intentionally
 *   kept additive and safe.
 *
 * ## Thread-safety
 * - The companion [getOrCreate] factory method is synchronised.
 * - [buildDataSourceFactory] is safe to call from any thread (including the ExoPlayer
 *   HandlerThread or a background smoke thread).  It does not block the UI thread.
 *
 * ## Prewarm / CacheWriter
 * Not implemented in this slice.  Phase 4C6C will add prewarm support via CacheWriter.
 *
 * @param applicationContext Application-scoped context.  Must not be an Activity context.
 * @param config             Cache configuration controlling directory, max size, and enabled flag.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class AndroidDagPlaybackCacheManager private constructor(
    applicationContext: Context,
    val config: AndroidDagPlaybackCacheConfig,
) {

    // --- Fields ---------------------------------------------------------------------------------

    private val appContext: Context = applicationContext.applicationContext

    /**
     * Absolute path to the cache subdirectory inside `cacheDir`.  Computed once at construction.
     */
    val cacheDirPath: String =
        File(appContext.cacheDir, config.cacheDirectoryName).absolutePath

    /**
     * Whether [simpleCache] was successfully initialised.  `false` if the config is disabled or
     * if [SimpleCache] init threw.
     */
    @Volatile
    var isCacheAvailable: Boolean = false
        private set

    /**
     * Live [SimpleCache] instance.  `null` when [config.enabled] is `false` or when init failed.
     */
    private var simpleCache: SimpleCache? = null

    // --- Initialisation -------------------------------------------------------------------------

    init {
        if (config.enabled) {
            initCache()
        }
        // If config.enabled == false, simpleCache stays null and isCacheAvailable stays false.
    }

    /**
     * Attempts to create the [SimpleCache].  On any exception the cache remains null and the
     * manager falls back to network-only mode (cache failure must never fail playback).
     */
    private fun initCache() {
        try {
            val cacheDir = File(appContext.cacheDir, config.cacheDirectoryName)
            // Directory creation is safe to call even if the directory already exists.
            if (!cacheDir.exists()) {
                cacheDir.mkdirs()
            }
            val evictor = LeastRecentlyUsedCacheEvictor(config.maxCacheBytes)
            val dbProvider = StandaloneDatabaseProvider(appContext)
            simpleCache = SimpleCache(cacheDir, evictor, dbProvider)
            isCacheAvailable = true
            Log.d(TAG, "SimpleCache initialised: dir=$cacheDirPath maxBytes=${config.maxCacheBytes}")
        } catch (t: Throwable) {
            // G-CACHE-FALLBACK: any init failure must not propagate to the caller.
            Log.w(TAG, "SimpleCache init failed - falling back to DefaultHttpDataSource: ${t.message}", t)
            simpleCache = null
            isCacheAvailable = false
        }
    }

    // --- Public API -----------------------------------------------------------------------------

    /**
     * Builds the appropriate [DataSource.Factory] for the given [httpHeaders]:
     *
     * - If [config.enabled] is `false` **or** cache initialisation failed:
     *   Returns a plain [DefaultHttpDataSource.Factory] with [httpHeaders] applied (identical to
     *   pre-Phase-4C6B behaviour — preserves existing playback invariants).
     * - If cache is available:
     *   Returns a [CacheDataSource.Factory] wrapping [simpleCache] with an upstream
     *   [DefaultHttpDataSource.Factory], [CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR] set so that
     *   individual cache I/O errors fall back to the network without interrupting playback.
     *
     * Must be called from any thread (HandlerThread or background); does not block the UI thread.
     *
     * @param httpHeaders Optional HTTP headers forwarded to every [DefaultHttpDataSource].
     */
    fun buildDataSourceFactory(
        httpHeaders: Map<String, String>?,
    ): DataSource.Factory {
        val upstreamFactory = buildUpstreamFactory(httpHeaders)

        val cache = simpleCache
        if (!config.enabled || cache == null || !isCacheAvailable) {
            // Fallback: plain network data source (config disabled or cache init failed).
            return upstreamFactory
        }

        return try {
            CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(upstreamFactory)
                // FLAG_IGNORE_CACHE_ON_ERROR: on any cache read/write failure, fall through to
                // network upstream.  This satisfies the Phase 4C6B requirement that cache I/O
                // failures must never fail playback.
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        } catch (t: Throwable) {
            // Defensive: CacheDataSource.Factory construction should not throw, but if it does,
            // fall back to the upstream factory to preserve playback.
            Log.w(TAG, "CacheDataSource.Factory build failed – using upstream: ${t.message}", t)
            upstreamFactory
        }
    }

    /**
     * Returns a diagnostic status map suitable for the smoke harness and MethodChannel responses.
     *
     * Keys returned:
     * - `cacheEnabled`    : Boolean — whether [config.enabled] is true.
     * - `cacheAvailable`  : Boolean — whether [simpleCache] was successfully initialised.
     * - `cacheDir`        : String  — absolute path to the cache directory.
     * - `maxCacheBytes`   : Long    — configured max disk budget.
     * - `cachedBytes`     : String  — "not_available" (reliable per-URL byte estimation via
     *                                  [SimpleCache.getCachedBytes] requires a [DataSpec] and is
     *                                  deferred to Phase 4C6B physical verification; reporting
     *                                  "not_available" is honest per the spec).
     */
    fun diagnosticStatus(): Map<String, Any?> {
        return mapOf(
            "cacheEnabled" to config.enabled,
            "cacheAvailable" to isCacheAvailable,
            "cacheDir" to cacheDirPath,
            "maxCacheBytes" to config.maxCacheBytes,
            // Per the implementation spec: if reliable per-URL estimation is not straightforward,
            // report not_available without claiming hit proof.
            "cachedBytes" to "not_available",
        )
    }

    // --- Private helpers ------------------------------------------------------------------------

    /**
     * Builds a [DefaultHttpDataSource.Factory] and applies [httpHeaders] if non-empty.
     */
    private fun buildUpstreamFactory(httpHeaders: Map<String, String>?): DefaultHttpDataSource.Factory {
        val factory = DefaultHttpDataSource.Factory()
        if (!httpHeaders.isNullOrEmpty()) {
            factory.setDefaultRequestProperties(httpHeaders)
        }
        return factory
    }

    // --- Companion (singleton per directory) ----------------------------------------------------

    companion object {
        private const val TAG = "DagPlaybackCacheMgr"

        /** Synchronisation lock for the singleton map below. */
        private val lock = Any()

        /**
         * One [AndroidDagPlaybackCacheManager] per [AndroidDagPlaybackCacheConfig.cacheDirectoryName].
         * This ensures G-SINGLE-OWNER: exactly one [SimpleCache] per cache directory.
         */
        private val instances = mutableMapOf<String, AndroidDagPlaybackCacheManager>()

        /**
         * Returns an existing [AndroidDagPlaybackCacheManager] for [config.cacheDirectoryName]
         * if one already exists, or creates and caches a new one.
         *
         * **Disabled-config policy (G-SINGLE-OWNER safety):** if [config.enabled] is `false`,
         * the returned manager is *not* stored in [instances].  This prevents a disabled manager
         * from occupying the directory slot and blocking a later enabled call from creating the
         * real [SimpleCache] singleton.  The returned disabled instance is lightweight (no
         * [SimpleCache] created) and is safe to discard.
         *
         * Thread-safe: synchronised on [lock].
         *
         * @param applicationContext Application-scoped context; must not be an Activity context.
         * @param config             Cache configuration.
         */
        fun getOrCreate(
            applicationContext: Context,
            config: AndroidDagPlaybackCacheConfig,
        ): AndroidDagPlaybackCacheManager {
            // Disabled configs must not be stored in the singleton map.  Return a fresh
            // no-cache manager so that a subsequent enabled call for the same directory
            // can still create and own the SimpleCache singleton (G-SINGLE-OWNER).
            if (!config.enabled) {
                return AndroidDagPlaybackCacheManager(applicationContext, config)
            }

            synchronized(lock) {
                return instances.getOrPut(config.cacheDirectoryName) {
                    AndroidDagPlaybackCacheManager(applicationContext, config)
                }
            }
        }
    }
}
