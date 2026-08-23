// Copyright (c) Connects - Phase 4C6C: Android Media3 CacheWriter prewarm/prefetch foundation.
// Diagnostic-only smoke harness.  No ExoPlayer, Surface, MediaCodec, or ConnectsApp state.

package com.connects.vanguard_media_engine.streaming

import android.content.Context
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Vanguard Android True-DAG Phase 4C6C: Prewarm Engine Smoke Harness.
 *
 * Diagnostic harness only.  Validates the end-to-end prewarm job lifecycle — from
 * [AndroidDagPlaybackPrewarmRequest] construction through [AndroidDagPlaybackPrewarmEngine.start]
 * and cancellation — without:
 * - Instantiating [androidx.media3.exoplayer.ExoPlayer].
 * - Creating any [android.view.Surface] or [android.media.ImageReader].
 * - Creating any [android.media.MediaCodec].
 * - Mutating ConnectsApp production state.
 *
 * ## Prewarm network leg
 * Fetches up to [DEFAULT_MAX_BYTES] bytes from [DEFAULT_PREWARM_URI] (a small public HTTP HLS
 * manifest).  For HLS/DASH manifest URLs this caches the addressed resource; segment traversal
 * is explicitly not claimed ([adaptiveSegmentGraphPrefetch] = `false`).
 *
 * ## Cancel safety leg
 * Verifies that [AndroidDagPlaybackPrewarmEngine.cancel] with an unknown requestId is idempotent
 * and does not throw.
 *
 * The [run] method is safe to call from any background thread.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
object AndroidDagPlaybackPrewarmSmokeHarness {

    private const val TAG = "DagPrewarmSmokeHarness"

    /**
     * Default public HLS manifest URL used when no override is supplied via args.
     * Bounded to [DEFAULT_MAX_BYTES] so the harness terminates quickly.
     */
    private const val DEFAULT_PREWARM_URI =
        "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"

    /** Maximum bytes fetched during the network prewarm leg — kept very small for smoke. */
    private const val DEFAULT_MAX_BYTES = 65536L  // 64 KiB

    /** Maximum wall-clock seconds to wait for the prewarm job to complete. */
    private const val JOB_TIMEOUT_SECONDS = 20L

    /**
     * Executes the Phase 4C6C prewarm smoke test.
     *
     * @param applicationContext Application-scoped context.  Must not be an Activity context.
     * @param overrideUri        Optional URI override.  Falls back to [DEFAULT_PREWARM_URI].
     * @param overrideMaxBytes   Optional maxBytes override.  Falls back to [DEFAULT_MAX_BYTES].
     *                           Clamped to [DEFAULT_MAX_BYTES] if larger.
     * @return A [Map] matching the Phase 4C6C smoke result schema.
     */
    fun run(
        applicationContext: Context,
        overrideUri: String? = null,
        overrideMaxBytes: Long? = null,
    ): Map<String, Any?> {
        Log.d(TAG, "Phase4C6C smoke: starting prewarm engine smoke harness")

        val prewarmUri = if (!overrideUri.isNullOrBlank()
            && (overrideUri.startsWith("http://") || overrideUri.startsWith("https://"))) {
            overrideUri
        } else {
            DEFAULT_PREWARM_URI
        }

        // Never exceed DEFAULT_MAX_BYTES regardless of what the caller supplies.
        val maxBytes = overrideMaxBytes?.coerceIn(1L, DEFAULT_MAX_BYTES) ?: DEFAULT_MAX_BYTES

        val cacheConfig = AndroidDagPlaybackCacheConfig(
            enabled = true,
            maxCacheBytes = 4L * 1024L * 1024L,  // 4 MiB smoke budget
            cacheDirectoryName = "vanguard_playback_cache_prewarm_smoke4c6c",
        )

        val engine = AndroidDagPlaybackPrewarmEngine(applicationContext)

        // --- Leg 1: cancel("missing-id") must be safe/idempotent --------------------------------
        val cancelMissingSafe: Boolean = try {
            val result = engine.cancel("missing-id-smoke-4c6c")
            // Expected: returns false (unknown id), must not throw.
            !result  // true if it correctly returned false
        } catch (t: Throwable) {
            Log.e(TAG, "Phase4C6C smoke: cancel(missing-id) threw unexpectedly", t)
            false
        }
        Log.d(TAG, "Phase4C6C smoke: Leg 1 (cancel missing id) cancelMissingSafe=$cancelMissingSafe")

        // --- Leg 2: bounded network prewarm -----------------------------------------------------
        val requestId = "smoke-4c6c-prewarm-${System.currentTimeMillis()}"
        val request = try {
            AndroidDagPlaybackPrewarmRequest(
                requestId = requestId,
                uri = prewarmUri,
                maxBytes = maxBytes,
                cacheConfig = cacheConfig,
            )
        } catch (t: Throwable) {
            Log.e(TAG, "Phase4C6C smoke: request construction threw", t)
            engine.shutdown()
            return buildResult(
                pass = false,
                completedPrewarm = false,
                cancelMissingSafe = cancelMissingSafe,
                raw = "status=FAIL;leg=request_construction;error=${t.javaClass.simpleName}:${t.message}",
            )
        }

        val latch = CountDownLatch(1)
        var finalJobResult: Map<String, Any?> = emptyMap()

        val started = engine.start(request) { jobResult ->
            finalJobResult = jobResult
            latch.countDown()
        }

        if (!started) {
            Log.e(TAG, "Phase4C6C smoke: engine.start returned false unexpectedly")
            engine.shutdown()
            return buildResult(
                pass = false,
                completedPrewarm = false,
                cancelMissingSafe = cancelMissingSafe,
                raw = "status=FAIL;leg=engine_start_rejected;requestId=$requestId",
            )
        }

        // Duplicate requestId must be rejected (design invariant check).
        val duplicateStarted = engine.start(request) { /* ignored */ }
        if (duplicateStarted) {
            Log.w(TAG, "Phase4C6C smoke: duplicate requestId was incorrectly accepted")
        }

        // Wait for job completion with bounded timeout.
        val completed = latch.await(JOB_TIMEOUT_SECONDS, TimeUnit.SECONDS)

        if (!completed) {
            // Request cancellation of the background CacheWriter before shutting down the
            // executor so we do not leave an orphaned CacheWriter running after shutdown.
            engine.cancel(requestId)
            engine.shutdown()
            Log.e(TAG, "Phase4C6C smoke: job did not complete within ${JOB_TIMEOUT_SECONDS}s")
            return buildResult(
                pass = false,
                completedPrewarm = false,
                cancelMissingSafe = cancelMissingSafe,
                raw = "status=FAIL;leg=prewarm_timeout;requestId=$requestId;timeoutSec=$JOB_TIMEOUT_SECONDS",
            )
        }

        engine.shutdown()

        val jobState = finalJobResult["state"] as? String ?: "unknown"
        val bytesCached = (finalJobResult["bytesCached"] as? Long) ?: 0L
        val newBytesCached = (finalJobResult["newBytesCached"] as? Long) ?: 0L
        val requestLength = (finalJobResult["requestLength"] as? Long) ?: 0L

        // Physical smoke PASS requires CacheWriter to have completed successfully.
        // "failed" and "cancelled" terminal states are not acceptable physical-smoke outcomes.
        val cacheWriterMadeProgress = bytesCached > 0L || requestLength > 0L || newBytesCached > 0L
        val completedPrewarm = jobState == "succeeded" && cacheWriterMadeProgress
        val pass = completedPrewarm && cancelMissingSafe && (duplicateStarted == false)

        val rawStatus = buildString {
            append("status=${if (pass) "PASS" else "FAIL"}")
            append(";jobState=$jobState")
            append(";cancelMissingSafe=$cancelMissingSafe")
            append(";duplicateRejected=${!duplicateStarted}")
            append(";bytesCached=$bytesCached")
            append(";newBytesCached=$newBytesCached")
            append(";requestLength=$requestLength")
            append(";cacheWriterMadeProgress=$cacheWriterMadeProgress")
        }

        Log.d(TAG, "Phase4C6C smoke: DONE pass=$pass $rawStatus")

        return buildResult(
            pass = pass,
            completedPrewarm = completedPrewarm,
            cancelMissingSafe = cancelMissingSafe,
            raw = rawStatus,
        )
    }

    // --- Private helpers ------------------------------------------------------------------------

    private fun buildResult(
        pass: Boolean,
        completedPrewarm: Boolean,
        cancelMissingSafe: Boolean,
        raw: String,
    ): Map<String, Any?> = mapOf(
        "phase"                        to "Phase4C6C",
        "pass"                         to pass,
        "completedPrewarm"             to completedPrewarm,
        "cancelMissingSafe"            to cancelMissingSafe,
        "prewarmImplemented"           to true,
        "adaptiveSegmentGraphPrefetch" to false,
        "playbackMutation"             to false,
        "webRtcCache"                  to false,
        "raw"                          to raw,
    )
}
