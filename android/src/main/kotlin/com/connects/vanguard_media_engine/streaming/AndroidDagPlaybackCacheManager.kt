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
 * Phase 4C6C adds prewarm support via CacheWriter; see [buildPrewarmCacheDataSource].
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

    // --- Phase 4C6C: Prewarm / CacheWriter API --------------------------------------------------

    /**
     * Builds a concrete [CacheDataSource] suitable for passing to [CacheWriter] during prewarm.
     *
     * Unlike [buildDataSourceFactory] (which returns a factory for ExoPlayer), this method
     * creates a ready-to-use [CacheDataSource] instance.  [CacheWriter] requires an already-open
     * [CacheDataSource], not a factory.
     *
     * Returns `null` if [config.enabled] is `false` or if the cache was not successfully
     * initialised ([isCacheAvailable] is `false`).  The prewarm engine must treat a `null` return
     * as a graceful abort and must not surface it as a playback error.
     *
     * Reuses the same [DefaultHttpDataSource] header behaviour as [buildDataSourceFactory]; no
     * additional headers or custom cache key are applied (G-CACHE-KEY: URI-based key only).
     *
     * Must be called from a background thread; does not block the UI thread.
     *
     * @param httpHeaders Optional HTTP headers forwarded to [DefaultHttpDataSource].
     * @return A configured [CacheDataSource], or `null` if cache is unavailable.
     */
    fun buildPrewarmCacheDataSource(
        httpHeaders: Map<String, String>?,
    ): CacheDataSource? {
        val cache = simpleCache
        if (!config.enabled || cache == null || !isCacheAvailable) {
            Log.d(TAG, "buildPrewarmCacheDataSource: cache not available; returning null.")
            return null
        }

        val upstreamFactory = buildUpstreamFactory(httpHeaders)
        return try {
            // Build a CacheDataSource (not a factory) for direct use by CacheWriter.
            // FLAG_IGNORE_CACHE_ON_ERROR: cache I/O errors fall through to upstream network;
            // this matches the same flag set in buildDataSourceFactory for playback consistency.
            CacheDataSource(
                cache,
                upstreamFactory.createDataSource(),
                CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "buildPrewarmCacheDataSource: CacheDataSource construction failed: ${t.message}", t)
            null
        }
    }

    // --- Phase 4C6D: Verification CacheDataSource API -------------------------------------------

    /**
     * Builds a concrete [CacheDataSource] backed by the owned [simpleCache] with a caller-provided
     * upstream [upstreamDataSource] for diagnostic verification (such as Phase 4C6D cache-hit proof).
     *
     * Returns `null` if [config.enabled] is `false` or if the cache was not successfully
     * initialised ([isCacheAvailable] is `false`). Does not expose [SimpleCache] itself.
     *
     * @param upstreamDataSource Custom upstream data source (e.g. failing network data source).
     * @param flags Optional CacheDataSource flags. Defaults to 0.
     * @return A configured [CacheDataSource], or `null` if cache is unavailable.
     */
    fun buildVerificationCacheDataSource(
        upstreamDataSource: DataSource,
        flags: Int = 0,
    ): CacheDataSource? {
        val cache = simpleCache
        if (!config.enabled || cache == null || !isCacheAvailable) {
            Log.d(TAG, "buildVerificationCacheDataSource: cache not available; returning null.")
            return null
        }

        return try {
            CacheDataSource(
                cache,
                upstreamDataSource,
                flags,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "buildVerificationCacheDataSource: CacheDataSource construction failed: ${t.message}", t)
            null
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

    // --- Phase 4C6F: Cache lifecycle controls ---------------------------------------------------

    /**
     * Returns the current total cache space (used disk bytes) via [Cache.getCacheSpace].
     *
     * Safe to call from any thread (does not block the UI thread for significant time).
     * Returns 0 if the cache is not available.
     *
     * Must be called from a worker thread; [getCacheSpace] may involve I/O on first call.
     */
    fun cacheSpaceBytes(): Long {
        val cache = simpleCache
        if (!isCacheAvailable || cache == null) return 0L
        return try {
            cache.getCacheSpace()
        } catch (t: Throwable) {
            Log.w(TAG, "Phase4C6F cacheSpaceBytes: getCacheSpace threw: ${t.message}", t)
            0L
        }
    }

    /**
     * Returns a snapshot copy of the set of cached resource keys via [Cache.getKeys].
     *
     * The returned set is a defensive copy so the caller is not affected by any subsequent
     * eviction or write to the cache index.
     *
     * Returns an empty set if the cache is not available.
     *
     * Must be called from a worker thread.
     */
    fun cachedResourceKeys(): Set<String> {
        val cache = simpleCache
        if (!isCacheAvailable || cache == null) return emptySet()
        return try {
            HashSet(cache.keys)
        } catch (t: Throwable) {
            Log.w(TAG, "Phase4C6F cachedResourceKeys: getKeys threw: ${t.message}", t)
            emptySet()
        }
    }

    /**
     * Phase 4C6F: Removes all cached resources by iterating [Cache.getKeys] and calling
     * [Cache.removeResource] for each key.
     *
     * Failures on individual keys are caught and counted; they do not abort the loop.
     * Never manually deletes cache directory contents — uses only the [Cache] API so the
     * internal index remains coherent.
     *
     * Must be called from a background/worker thread — [removeResource] may be slow.
     *
     * @return Structured result map with keys:
     *   - `beforeBytes`           : Long — cache space before clearing.
     *   - `afterBytes`            : Long — cache space after clearing.
     *   - `resourceCountBefore`   : Int  — number of keys before clearing.
     *   - `removedResourceCount`  : Int  — keys for which [removeResource] succeeded.
     *   - `failedResourceCount`   : Int  — keys for which [removeResource] threw.
     */
    fun clearAllCachedResources(): Map<String, Any?> {
        val cache = simpleCache
        if (!isCacheAvailable || cache == null) {
            Log.d(TAG, "Phase4C6F clearAllCachedResources: cache not available; returning zero counts.")
            return mapOf(
                "beforeBytes"          to 0L,
                "afterBytes"           to 0L,
                "resourceCountBefore"  to 0,
                "removedResourceCount" to 0,
                "failedResourceCount"  to 0,
            )
        }

        val beforeBytes = try { cache.getCacheSpace() } catch (_: Throwable) { 0L }
        val keys = try { ArrayList(cache.keys) } catch (_: Throwable) { arrayListOf() }
        val resourceCountBefore = keys.size
        var removedCount = 0
        var failedCount = 0

        for (key in keys) {
            try {
                cache.removeResource(key)
                removedCount++
            } catch (t: Throwable) {
                Log.w(TAG, "Phase4C6F clearAllCachedResources: removeResource($key) threw: ${t.message}", t)
                failedCount++
            }
        }

        val afterBytes = try { cache.getCacheSpace() } catch (_: Throwable) { 0L }

        Log.d(
            TAG,
            "Phase4C6F clearAllCachedResources: before=${beforeBytes}B after=${afterBytes}B " +
                "keys=$resourceCountBefore removed=$removedCount failed=$failedCount",
        )
        return mapOf(
            "beforeBytes"          to beforeBytes,
            "afterBytes"           to afterBytes,
            "resourceCountBefore"  to resourceCountBefore,
            "removedResourceCount" to removedCount,
            "failedResourceCount"  to failedCount,
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
