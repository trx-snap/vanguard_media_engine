// Copyright (c) Connects - Phase 4C6D: Android Media3 playback cache-hit proof harness.
// Diagnostic-only smoke harness. No ExoPlayer, Surface, MediaCodec, Vulkan, WebRTC, or ConnectsApp state.

package com.connects.vanguard_media_engine.streaming

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Vanguard Android True-DAG Phase 4C6D: Playback Cache Hit Smoke Harness.
 *
 * Diagnostic harness only. Proves AndroidX Media3 SimpleCache read-through cache hit proof:
 * 1. Executes a bounded prewarm of a public HLS manifest via [AndroidDagPlaybackPrewarmEngine] and [androidx.media3.datasource.cache.CacheWriter].
 * 2. Confirms prewarm completed with `state=succeeded`, `cacheAvailable=true`, and `bytesCached > 0`.
 * 3. Builds a [androidx.media3.datasource.cache.CacheDataSource] backed by the same [androidx.media3.datasource.cache.SimpleCache] with a local [FailingNetworkDataSource] upstream.
 * 4. Reads the cached resource via [androidx.media3.datasource.cache.CacheDataSource].
 * 5. Asserts that the read succeeded with > 0 bytes and [FailingNetworkDataSource.openCount] is exactly 0.
 *
 * Non-claims:
 * - This proves Media3 cache reuse for a bounded single resource/manifest only.
 * - Does NOT claim adaptive HLS/DASH segment graph prefetch ([adaptiveSegmentGraphPrefetch] = false).
 * - Does NOT claim a full ExoPlayer playback hit ([fullPlaybackHitProof] = false).
 * - Does NOT mutate ExoPlayer, Surface, MediaCodec, Vulkan, WebRTC, or ConnectsApp production state.
 *
 * The [run] method is safe to call from any background thread.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
object AndroidDagPlaybackCacheHitSmokeHarness {

    private const val TAG = "DagCacheHitHarness"

    /** Default public HLS manifest URL used when no override is supplied via args. */
    private const val DEFAULT_PREWARM_URI =
        "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"

    /** Maximum bytes fetched during the prewarm leg — kept bounded for smoke. */
    private const val DEFAULT_MAX_BYTES = 65536L // 64 KiB

    /** Maximum wall-clock seconds to wait for the prewarm job to complete. */
    private const val JOB_TIMEOUT_SECONDS = 20L

    /** Unique cache directory name dedicated to Phase 4C6D cache hit proof. */
    private const val CACHE_DIR_NAME = "vanguard_playback_cache_hit_smoke4c6d"

    /**
     * Diagnostic-only [DataSource] implementation that records opening attempts and immediately throws.
     *
     * Used as the upstream [DataSource] for [androidx.media3.datasource.cache.CacheDataSource] during
     * cache-hit verification. If the requested byte range is completely satisfied from [SimpleCache],
     * this data source is never opened (`openCount == 0`). If any byte range requires network access,
     * this data source records the attempt and throws [IOException].
     */
    class FailingNetworkDataSource : DataSource {
        private val _openCount = AtomicInteger(0)

        val openCount: Int
            get() = _openCount.get()

        override fun addTransferListener(transferListener: TransferListener) {
            // No-op for diagnostic harness
        }

        override fun open(dataSpec: DataSpec): Long {
            _openCount.incrementAndGet()
            throw IOException(
                "FailingNetworkDataSource: network access forbidden during cache hit verification for URI ${dataSpec.uri}",
            )
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            throw IOException("FailingNetworkDataSource: read called unexpectedly")
        }

        override fun getUri(): Uri? = null

        override fun close() {
            // No-op for diagnostic harness
        }
    }

    /**
     * Executes the Phase 4C6D playback cache hit proof smoke test.
     *
     * @param applicationContext Application-scoped context. Must not be an Activity context.
     * @param overrideUri Optional URI override. Falls back to [DEFAULT_PREWARM_URI].
     * @param overrideMaxBytes Optional maxBytes override. Falls back to [DEFAULT_MAX_BYTES].
     *                         Clamped to [DEFAULT_MAX_BYTES] if larger.
     * @return A [Map] matching the Phase 4C6D smoke result schema.
     */
    fun run(
        applicationContext: Context,
        overrideUri: String? = null,
        overrideMaxBytes: Long? = null,
    ): Map<String, Any?> {
        Log.d(TAG, "Phase4C6D smoke: starting cache hit proof harness")

        val targetUri = if (!overrideUri.isNullOrBlank()
            && (overrideUri.startsWith("http://") || overrideUri.startsWith("https://"))) {
            overrideUri
        } else {
            DEFAULT_PREWARM_URI
        }

        val maxBytes = overrideMaxBytes?.coerceIn(1L, DEFAULT_MAX_BYTES) ?: DEFAULT_MAX_BYTES

        val cacheConfig = AndroidDagPlaybackCacheConfig(
            enabled = true,
            maxCacheBytes = 4L * 1024L * 1024L, // 4 MiB smoke budget
            cacheDirectoryName = CACHE_DIR_NAME,
        )

        // --- Step 1: Execute bounded prewarm ---------------------------------------------------
        val engine = AndroidDagPlaybackPrewarmEngine(applicationContext)
        val requestId = "smoke-4c6d-hit-${System.currentTimeMillis()}"
        val request = try {
            AndroidDagPlaybackPrewarmRequest(
                requestId = requestId,
                uri = targetUri,
                maxBytes = maxBytes,
                cacheConfig = cacheConfig,
            )
        } catch (t: Throwable) {
            Log.e(TAG, "Phase4C6D smoke: request construction threw", t)
            engine.shutdown()
            return buildResult(
                pass = false,
                completedPrewarm = false,
                cacheReadSucceeded = false,
                cacheReadBytes = 0L,
                networkOpenCount = 0,
                cacheHitProof = false,
                raw = "status=FAIL;leg=request_construction;error=${t.javaClass.simpleName}:${t.message}",
            )
        }

        val latch = CountDownLatch(1)
        var prewarmResult: Map<String, Any?> = emptyMap()

        val started = engine.start(request) { res ->
            prewarmResult = res
            latch.countDown()
        }

        if (!started) {
            Log.e(TAG, "Phase4C6D smoke: engine.start returned false")
            engine.shutdown()
            return buildResult(
                pass = false,
                completedPrewarm = false,
                cacheReadSucceeded = false,
                cacheReadBytes = 0L,
                networkOpenCount = 0,
                cacheHitProof = false,
                raw = "status=FAIL;leg=engine_start_rejected;requestId=$requestId",
            )
        }

        val completed = latch.await(JOB_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        if (!completed) {
            engine.cancel(requestId)
            engine.shutdown()
            Log.e(TAG, "Phase4C6D smoke: prewarm job timed out after ${JOB_TIMEOUT_SECONDS}s")
            return buildResult(
                pass = false,
                completedPrewarm = false,
                cacheReadSucceeded = false,
                cacheReadBytes = 0L,
                networkOpenCount = 0,
                cacheHitProof = false,
                raw = "status=FAIL;leg=prewarm_timeout;requestId=$requestId",
            )
        }

        engine.shutdown()

        val prewarmState = prewarmResult["state"] as? String ?: "unknown"
        val cacheAvailable = (prewarmResult["cacheAvailable"] as? Boolean) ?: false
        val bytesCached = (prewarmResult["bytesCached"] as? Long) ?: 0L
        val requestLength = (prewarmResult["requestLength"] as? Long) ?: 0L

        val completedPrewarm = (prewarmState == "succeeded") && cacheAvailable && (bytesCached > 0L)

        if (!completedPrewarm) {
            Log.w(
                TAG,
                "Phase4C6D smoke: prewarm failed invariant: state=$prewarmState " +
                    "cacheAvailable=$cacheAvailable bytesCached=$bytesCached",
            )
            return buildResult(
                pass = false,
                completedPrewarm = false,
                cacheReadSucceeded = false,
                cacheReadBytes = 0L,
                networkOpenCount = 0,
                cacheHitProof = false,
                raw = "status=FAIL;leg=prewarm_check;state=$prewarmState;" +
                    "cacheAvailable=$cacheAvailable;bytesCached=$bytesCached",
            )
        }

        // --- Step 2: Build verification CacheDataSource with FailingNetworkDataSource upstream ---
        val manager = try {
            AndroidDagPlaybackCacheManager.getOrCreate(applicationContext, cacheConfig)
        } catch (t: Throwable) {
            Log.e(TAG, "Phase4C6D smoke: cache manager getOrCreate threw", t)
            return buildResult(
                pass = false,
                completedPrewarm = completedPrewarm,
                cacheReadSucceeded = false,
                cacheReadBytes = 0L,
                networkOpenCount = 0,
                cacheHitProof = false,
                raw = "status=FAIL;leg=cache_manager_get_or_create;error=${t.javaClass.simpleName}:${t.message}",
            )
        }

        val failingUpstream = FailingNetworkDataSource()
        val cacheDataSource = manager.buildVerificationCacheDataSource(failingUpstream, flags = 0)
        if (cacheDataSource == null) {
            Log.e(TAG, "Phase4C6D smoke: buildVerificationCacheDataSource returned null")
            return buildResult(
                pass = false,
                completedPrewarm = completedPrewarm,
                cacheReadSucceeded = false,
                cacheReadBytes = 0L,
                networkOpenCount = failingUpstream.openCount,
                cacheHitProof = false,
                raw = "status=FAIL;leg=build_verification_data_source_null",
            )
        }

        // --- Step 3: Open and read from cache ---------------------------------------------------
        val verifyLength = if (requestLength > 0L) requestLength else bytesCached
        val verifyDataSpec = DataSpec(Uri.parse(targetUri), 0L, verifyLength)

        var cacheReadSucceeded = false
        var cacheReadBytes = 0L
        var readError: String? = null

        try {
            cacheDataSource.open(verifyDataSpec)
            val buffer = ByteArray(4096)
            var totalRead = 0L
            while (true) {
                val bytesToRead = if (verifyLength > 0L) {
                    val remaining = verifyLength - totalRead
                    if (remaining <= 0L) break
                    minOf(buffer.size.toLong(), remaining).toInt()
                } else {
                    buffer.size
                }
                val bytesRead = cacheDataSource.read(buffer, 0, bytesToRead)
                if (bytesRead == C.RESULT_END_OF_INPUT || bytesRead < 0) {
                    break
                }
                if (bytesRead == 0) {
                    break
                }
                totalRead += bytesRead
            }
            cacheReadBytes = totalRead
            if (cacheReadBytes > 0L && failingUpstream.openCount == 0) {
                cacheReadSucceeded = true
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Phase4C6D smoke: cache verification read threw", t)
            readError = "${t.javaClass.simpleName}:${t.message}"
        } finally {
            try {
                cacheDataSource.close()
            } catch (_: Throwable) {}
        }

        val networkOpenCount = failingUpstream.openCount
        val cacheHitProof = cacheReadSucceeded && (cacheReadBytes > 0L) && (networkOpenCount == 0)
        val pass = completedPrewarm && cacheHitProof

        val rawStatus = buildString {
            append("status=${if (pass) "PASS" else "FAIL"}")
            append(";completedPrewarm=$completedPrewarm")
            append(";prewarmState=$prewarmState")
            append(";bytesCached=$bytesCached")
            append(";requestLength=$requestLength")
            append(";cacheReadSucceeded=$cacheReadSucceeded")
            append(";cacheReadBytes=$cacheReadBytes")
            append(";networkOpenCount=$networkOpenCount")
            append(";cacheHitProof=$cacheHitProof")
            if (readError != null) append(";readError=$readError")
        }

        Log.d(TAG, "Phase4C6D smoke: DONE pass=$pass $rawStatus")

        return buildResult(
            pass = pass,
            completedPrewarm = completedPrewarm,
            cacheReadSucceeded = cacheReadSucceeded,
            cacheReadBytes = cacheReadBytes,
            networkOpenCount = networkOpenCount,
            cacheHitProof = cacheHitProof,
            raw = rawStatus,
        )
    }

    // --- Private helpers ------------------------------------------------------------------------

    private fun buildResult(
        pass: Boolean,
        completedPrewarm: Boolean,
        cacheReadSucceeded: Boolean,
        cacheReadBytes: Long,
        networkOpenCount: Int,
        cacheHitProof: Boolean,
        raw: String,
    ): Map<String, Any?> = mapOf(
        "phase"                        to "Phase4C6D",
        "pass"                         to pass,
        "completedPrewarm"             to completedPrewarm,
        "cacheReadSucceeded"           to cacheReadSucceeded,
        "cacheReadBytes"               to cacheReadBytes,
        "networkOpenCount"             to networkOpenCount,
        "cacheHitProof"                to cacheHitProof,
        "fullPlaybackHitProof"         to false,
        "adaptiveSegmentGraphPrefetch" to false,
        "playbackMutation"             to false,
        "webRtcCache"                  to false,
        "raw"                          to raw,
    )
}
