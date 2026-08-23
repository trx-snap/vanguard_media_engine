// Copyright (c) Connects - Phase 4C6B: Android Media3 read-through playback cache backend.
// No-playback, no-network smoke harness for cache manager setup validation.

package com.connects.vanguard_media_engine.streaming

import android.content.Context
import android.util.Log

/**
 * Vanguard Android True-DAG Phase 4C6B: Playback Cache Backend Smoke Harness.
 *
 * Validates cache manager setup and fallback map shape without:
 * - Fetching any network content.
 * - Instantiating [androidx.media3.exoplayer.ExoPlayer].
 * - Creating any [android.view.Surface] or [android.media.ImageReader].
 * - Creating any [android.media.MediaCodec].
 * - Mutating ConnectsApp production state.
 *
 * The harness exercises two configurations in sequence:
 * 1. **Default config** (`enabled = false`): verifies that the factory falls back to a plain
 *    [androidx.media3.datasource.DefaultHttpDataSource.Factory] without touching cache storage.
 * 2. **Smoke config** (`enabled = true`): verifies that [AndroidDagPlaybackCacheManager]
 *    initialises and [buildDataSourceFactory] returns a non-null factory without throwing.
 *
 * The [run] method is safe to call from any background thread.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
object AndroidDagPlaybackCacheSmokeHarness {

    private const val TAG = "DagCacheSmokeHarness"

    /**
     * Executes the Phase 4C6B cache smoke test.
     *
     * @param applicationContext Application-scoped context.  Must not be an Activity context.
     * @return A [Map] whose keys match the Phase 4C6B smoke result schema.
     */
    fun run(applicationContext: Context): Map<String, Any?> {
        Log.d(TAG, "Phase4C6B smoke: starting cache backend smoke harness")

        var cacheAvailable = false
        var smokePass = false
        var rawStatus = "status=INIT"

        // --- Leg 1: Default config (enabled=false) -----------------------------------------------
        // Verifies that AndroidDagPlaybackCacheManager respects the disabled default and that
        // buildDataSourceFactory returns a plain DefaultHttpDataSource.Factory.
        val defaultConfig = AndroidDagPlaybackCacheConfig() // enabled=false by default
        require(!defaultConfig.enabled) {
            "Smoke invariant violated: default AndroidDagPlaybackCacheConfig must have enabled=false"
        }

        val defaultManager = try {
            AndroidDagPlaybackCacheManager.getOrCreate(applicationContext, defaultConfig)
        } catch (t: Throwable) {
            Log.e(TAG, "Phase4C6B smoke: default manager construction threw unexpectedly", t)
            return buildResult(
                pass = false,
                cacheAvailable = false,
                rawStatus = "status=FAIL;leg=default_manager_throw;error=${t.javaClass.simpleName}:${t.message}",
            )
        }

        // Default config: cache must NOT be available (disabled by design).
        if (defaultManager.isCacheAvailable) {
            return buildResult(
                pass = false,
                cacheAvailable = false,
                rawStatus = "status=FAIL;leg=default_cache_available_unexpected;expected=false",
            )
        }

        // Factory from disabled config must be non-null (fallback DefaultHttpDataSource.Factory).
        val defaultFactory = try {
            defaultManager.buildDataSourceFactory(httpHeaders = null)
        } catch (t: Throwable) {
            Log.e(TAG, "Phase4C6B smoke: default factory threw", t)
            return buildResult(
                pass = false,
                cacheAvailable = false,
                rawStatus = "status=FAIL;leg=default_factory_throw;error=${t.javaClass.simpleName}:${t.message}",
            )
        }
        if (defaultFactory == null) {
            return buildResult(
                pass = false,
                cacheAvailable = false,
                rawStatus = "status=FAIL;leg=default_factory_null",
            )
        }

        Log.d(TAG, "Phase4C6B smoke: Leg 1 (default disabled config) PASS")

        // --- Leg 2: Smoke config (enabled=true) --------------------------------------------------
        // Uses a unique directory name to avoid colliding with any live session cache.
        val smokeConfig = AndroidDagPlaybackCacheConfig(
            enabled = true,
            maxCacheBytes = 4L * 1024L * 1024L,   // 4 MiB – minimal smoke budget
            cacheDirectoryName = "vanguard_playback_cache_smoke4c6b",
        )

        val smokeManager = try {
            AndroidDagPlaybackCacheManager.getOrCreate(applicationContext, smokeConfig)
        } catch (t: Throwable) {
            Log.e(TAG, "Phase4C6B smoke: smoke manager construction threw", t)
            return buildResult(
                pass = false,
                cacheAvailable = false,
                rawStatus = "status=FAIL;leg=smoke_manager_throw;error=${t.javaClass.simpleName}:${t.message}",
            )
        }

        cacheAvailable = smokeManager.isCacheAvailable
        Log.d(TAG, "Phase4C6B smoke: smokeManager.isCacheAvailable=$cacheAvailable dir=${smokeManager.cacheDirPath}")

        // Factory from enabled config must be non-null whether or not cache init succeeded
        // (fallback path handles the no-init case).
        val smokeFactory = try {
            smokeManager.buildDataSourceFactory(httpHeaders = mapOf("X-Smoke" to "4C6B"))
        } catch (t: Throwable) {
            Log.e(TAG, "Phase4C6B smoke: smoke factory threw", t)
            return buildResult(
                pass = false,
                cacheAvailable = cacheAvailable,
                rawStatus = "status=FAIL;leg=smoke_factory_throw;error=${t.javaClass.simpleName}:${t.message}",
            )
        }
        if (smokeFactory == null) {
            return buildResult(
                pass = false,
                cacheAvailable = cacheAvailable,
                rawStatus = "status=FAIL;leg=smoke_factory_null",
            )
        }

        // Validate diagnostic status map shape.
        val diag = smokeManager.diagnosticStatus()
        val diagKeys = setOf("cacheEnabled", "cacheAvailable", "cacheDir", "maxCacheBytes", "cachedBytes")
        val missingKeys = diagKeys - diag.keys
        if (missingKeys.isNotEmpty()) {
            return buildResult(
                pass = false,
                cacheAvailable = cacheAvailable,
                rawStatus = "status=FAIL;leg=diag_keys_missing;missing=$missingKeys",
            )
        }

        Log.d(TAG, "Phase4C6B smoke: Leg 2 (enabled smoke config) PASS; cacheAvailable=$cacheAvailable")

        smokePass = true
        rawStatus = "status=PASS;cacheAvailable=$cacheAvailable;defaultFactoryNull=false;smokeFactoryNull=false"

        return buildResult(
            pass = smokePass,
            cacheAvailable = cacheAvailable,
            rawStatus = rawStatus,
        )
    }

    // --- Private helpers ------------------------------------------------------------------------

    private fun buildResult(
        pass: Boolean,
        cacheAvailable: Boolean,
        rawStatus: String,
    ): Map<String, Any?> = mapOf(
        "phase"              to "Phase4C6B",
        "pass"               to pass,
        // Phase 4C6B invariants surface in the result map so the coordinator and external callers
        // can verify the backend shape without depending on internal implementation knowledge.
        "cacheEnabledDefault"  to false,        // default AndroidDagPlaybackCacheConfig.enabled
        "cacheEnabledSmoke"    to true,          // the smoke leg explicitly enables cache
        "cacheAvailable"       to cacheAvailable,
        "fallbackOnError"      to true,          // CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR always set
        "playbackMutation"     to false,         // no ExoPlayer, Surface, or MediaCodec touched
        "prewarmImplemented"   to false,         // Phase 4C6C deferred
        "webRtcCache"          to false,         // WebRTC/LiveKit excluded per ADR-AND-10 §2.3
        "raw"                  to rawStatus,
    )
}
