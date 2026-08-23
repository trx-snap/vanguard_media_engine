// Copyright (c) Connects - Phase 4C6C: Android Media3 CacheWriter prewarm/prefetch foundation.
// Prewarm job engine: owns executor, job tracking, and CacheWriter lifecycle.

package com.connects.vanguard_media_engine.streaming

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.CacheWriter
import java.io.InterruptedIOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Vanguard Android True-DAG Phase 4C6C: CacheWriter-based prewarm job engine.
 *
 * Owns a single-threaded [java.util.concurrent.ExecutorService] dedicated to background prewarm
 * jobs.  One job corresponds to one [AndroidDagPlaybackPrewarmRequest]; duplicate [requestId]
 * values are rejected without launching a second job.
 *
 * ## Thread-safety
 * - [jobs] is a [ConcurrentHashMap]; all state transitions are done inside [synchronized] blocks
 *   on [jobs] to guarantee atomicity of check-then-act pairs.
 * - [start], [cancel], [status], and [shutdown] are safe to call from any thread.
 * - The prewarm loop runs only on the owned executor thread, never on the UI thread, the Media3
 *   playback looper, a decoder callback, or a Vulkan/Metal render loop.
 *
 * ## Failure isolation (G-CACHE-FALLBACK)
 * - [InterruptedIOException] from [CacheWriter.cache] is mapped to state `"cancelled"`.
 * - Any other [Throwable] is mapped to state `"failed"`.
 * - A failed or cancelled job never mutates ExoPlayer, Surface, or MediaCodec state.
 *
 * ## Cache key policy (G-CACHE-KEY)
 * Media3 default URI-based cache key derivation is used.  No custom [DataSpec.customCacheKey] is
 * set in this slice.
 *
 * @param applicationContext Application-scoped context.  Must not be an Activity context.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class AndroidDagPlaybackPrewarmEngine(
    private val applicationContext: Context,
) {

    // --- State enum (string-serialised for MethodChannel result maps) ---------------------------

    private enum class JobState { QUEUED, RUNNING, SUCCEEDED, CANCELLED, FAILED }

    // --- Per-job record -------------------------------------------------------------------------

    private data class JobRecord(
        val request: AndroidDagPlaybackPrewarmRequest,
        @Volatile var state: JobState = JobState.QUEUED,
        @Volatile var bytesCached: Long = 0L,
        @Volatile var newBytesCached: Long = 0L,
        @Volatile var requestLength: Long = 0L,
        // Held so cancel() can interrupt an in-progress CacheWriter.cache() call.
        @Volatile var cacheWriter: CacheWriter? = null,
        // Set to true once cancel() is called so post-InterruptedIOException cleanup is coherent.
        @Volatile var cancelRequested: Boolean = false,
        @Volatile var errorMessage: String? = null,
        // True only when the CacheManager confirmed cache availability AND a CacheDataSource was
        // successfully built.  Never inferred from request.cacheConfig.enabled alone.
        @Volatile var cacheAvailable: Boolean = false,
    )

    // --- Fields ---------------------------------------------------------------------------------

    private val TAG = "DagPrewarmEngine"

    /** Dedicated single-threaded executor for all prewarm jobs. */
    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "vanguard-prewarm-worker").also { it.isDaemon = true }
    }

    /**
     * Live job registry keyed by [AndroidDagPlaybackPrewarmRequest.requestId].
     * ConcurrentHashMap for safe iteration; synchronized blocks guard check-then-act pairs.
     */
    private val jobs = ConcurrentHashMap<String, JobRecord>()

    /** `true` once [shutdown] has been called; new [start] calls are silently rejected. */
    @Volatile
    private var isShutdown = false

    // --- Public API -----------------------------------------------------------------------------

    /**
     * Submits a prewarm job for [request].
     *
     * Returns `false` (and does not launch) if:
     * - A job with the same [AndroidDagPlaybackPrewarmRequest.requestId] is already in the registry
     *   (regardless of state).
     * - [shutdown] has already been called.
     *
     * The [callback] is invoked exactly once on the executor thread after the job completes
     * (succeeded / cancelled / failed).  Callers that need to post to the UI thread must do so
     * inside [callback].
     *
     * @param request  Validated prewarm request.
     * @param callback Invoked with the final job result map once the job finishes.
     * @return `true` if the job was accepted and queued; `false` otherwise.
     */
    fun start(
        request: AndroidDagPlaybackPrewarmRequest,
        callback: (Map<String, Any?>) -> Unit,
    ): Boolean {
        if (isShutdown) {
            Log.w(TAG, "start(${request.requestId}): engine is shut down; ignoring.")
            return false
        }
        val record = JobRecord(request)
        // Atomic check-then-put: reject duplicate requestId.
        val previous = jobs.putIfAbsent(request.requestId, record)
        if (previous != null) {
            Log.w(TAG, "start(${request.requestId}): duplicate requestId; ignoring.")
            return false
        }

        Log.d(TAG, "start(${request.requestId}): queued; uri=${request.uri} maxBytes=${request.maxBytes}")

        executor.submit {
            runJob(record, callback)
        }
        return true
    }

    /**
     * Requests cancellation of the job identified by [requestId].
     *
     * - If no job exists for [requestId], returns `false` (idempotent; does not throw).
     * - If the job is still queued, marks it cancelled so the executor skips it.
     * - If the job is running, calls [CacheWriter.cancel] to interrupt [CacheWriter.cache].
     * - If the job already finished, returns `false`.
     *
     * Safe to call from any thread, including the UI thread.
     */
    fun cancel(requestId: String): Boolean {
        val record = jobs[requestId] ?: run {
            Log.d(TAG, "cancel($requestId): unknown requestId; noop.")
            return false
        }
        synchronized(record) {
            return when (record.state) {
                JobState.QUEUED, JobState.RUNNING -> {
                    record.cancelRequested = true
                    record.cacheWriter?.cancel()
                    Log.d(TAG, "cancel($requestId): cancel requested; state=${record.state}")
                    true
                }
                else -> {
                    Log.d(TAG, "cancel($requestId): already terminal state ${record.state}; noop.")
                    false
                }
            }
        }
    }

    /**
     * Returns a diagnostic status map for the job identified by [requestId].
     * If no such job exists, returns a map with state `"not_found"`.
     */
    fun status(requestId: String): Map<String, Any?> {
        val record = jobs[requestId] ?: return buildResultMap(
            request = AndroidDagPlaybackPrewarmRequest(
                requestId = requestId,
                uri = "https://unknown",
                cacheConfig = AndroidDagPlaybackCacheConfig(enabled = true),
            ),
            state = "not_found",
            bytesCached = 0L,
            newBytesCached = 0L,
            requestLength = 0L,
            cacheAvailable = false,
            raw = "status=NOT_FOUND;requestId=$requestId",
        )
        return record.toResultMap()
    }

    /**
     * Shuts down the executor.  In-progress jobs are allowed to finish or be cancelled by the
     * caller before calling [shutdown].  After [shutdown], [start] silently returns `false`.
     */
    fun shutdown() {
        isShutdown = true
        executor.shutdown()
        Log.d(TAG, "shutdown(): executor shut down.")
    }

    // --- Job execution (runs on executor thread) ------------------------------------------------

    private fun runJob(record: JobRecord, callback: (Map<String, Any?>) -> Unit) {
        val request = record.request

        // If cancel was requested before the job even started, short-circuit.
        synchronized(record) {
            if (record.cancelRequested) {
                record.state = JobState.CANCELLED
                Log.d(TAG, "runJob(${request.requestId}): cancelled before start")
                callback(record.toResultMap())
                return
            }
            record.state = JobState.RUNNING
        }

        Log.d(TAG, "runJob(${request.requestId}): RUNNING uri=${request.uri}")

        // Obtain a CacheDataSource from the manager; abort gracefully if unavailable.
        val manager = try {
            AndroidDagPlaybackCacheManager.getOrCreate(applicationContext, request.cacheConfig)
        } catch (t: Throwable) {
            Log.w(TAG, "runJob(${request.requestId}): manager construction failed: ${t.message}", t)
            synchronized(record) {
                record.state = JobState.FAILED
                record.errorMessage = "manager_construction_failed:${t.message}"
            }
            callback(record.toResultMap())
            return
        }

        if (!manager.isCacheAvailable) {
            Log.w(TAG, "runJob(${request.requestId}): cache not available; marking failed.")
            synchronized(record) {
                record.state = JobState.FAILED
                record.errorMessage = "cache_not_available"
                // record.cacheAvailable remains false — SimpleCache init failed or was never created.
            }
            callback(record.toResultMap())
            return
        }

        // Cache is available at the manager level; mark it provisionally true before attempting
        // to build the CacheDataSource.
        synchronized(record) { record.cacheAvailable = true }

        val cacheDataSource = manager.buildPrewarmCacheDataSource(request.httpHeaders)
        if (cacheDataSource == null) {
            Log.w(TAG, "runJob(${request.requestId}): buildPrewarmCacheDataSource returned null; marking failed.")
            synchronized(record) {
                record.state = JobState.FAILED
                record.errorMessage = "prewarm_data_source_null"
                // No CacheDataSource was created; cache is not usable for this job.
                record.cacheAvailable = false
            }
            callback(record.toResultMap())
            return
        }

        // Build DataSpec: position=0, length=maxBytes (bounded fetch).
        // G-CACHE-KEY: no customCacheKey; Media3 derives key from URI.
        val dataSpec = DataSpec(Uri.parse(request.uri), 0L, request.maxBytes)

        // ProgressListener tracks Media3-reported cache progress.
        val progressListener = CacheWriter.ProgressListener { requestLength, bytesCached, newBytesCached ->
            synchronized(record) {
                record.requestLength = requestLength
                record.bytesCached = bytesCached
                record.newBytesCached += newBytesCached
            }
        }

        val writer = CacheWriter(
            cacheDataSource,
            dataSpec,
            /* temporaryBuffer= */ null,
            progressListener,
        )

        synchronized(record) {
            // If cancel arrived between the state=RUNNING set and CacheWriter construction,
            // call cancel() on the writer immediately and abort.
            record.cacheWriter = writer
            if (record.cancelRequested) {
                writer.cancel()
            }
        }

        try {
            // @WorkerThread — must not run on main thread.  We are on the executor thread.
            writer.cache()
            synchronized(record) {
                record.state = JobState.SUCCEEDED
            }
            Log.d(
                TAG,
                "runJob(${request.requestId}): SUCCEEDED " +
                    "bytesCached=${record.bytesCached} newBytesCached=${record.newBytesCached}",
            )
        } catch (e: InterruptedIOException) {
            // cancel() was called; map to CANCELLED per design.
            synchronized(record) {
                record.state = JobState.CANCELLED
                record.errorMessage = "interrupted:${e.message}"
            }
            Log.d(TAG, "runJob(${request.requestId}): CANCELLED via InterruptedIOException")
        } catch (t: Throwable) {
            synchronized(record) {
                // If the throwable arrived after a cancel request, still prefer CANCELLED.
                if (record.cancelRequested) {
                    record.state = JobState.CANCELLED
                    record.errorMessage = "cancelled_with_error:${t.javaClass.simpleName}:${t.message}"
                } else {
                    record.state = JobState.FAILED
                    record.errorMessage = "cache_error:${t.javaClass.simpleName}:${t.message}"
                }
            }
            Log.w(TAG, "runJob(${request.requestId}): error during cache()", t)
        } finally {
            synchronized(record) {
                record.cacheWriter = null
            }
        }

        callback(record.toResultMap())
    }

    // --- Result map helpers ---------------------------------------------------------------------

    private fun JobRecord.toResultMap(): Map<String, Any?> {
        val stateStr = when (state) {
            JobState.QUEUED    -> "queued"
            JobState.RUNNING   -> "running"
            JobState.SUCCEEDED -> "succeeded"
            JobState.CANCELLED -> "cancelled"
            JobState.FAILED    -> "failed"
        }
        val rawParts = buildString {
            append("state=$stateStr")
            append(";bytesCached=$bytesCached")
            append(";newBytesCached=$newBytesCached")
            append(";requestLength=$requestLength")
            if (errorMessage != null) append(";error=$errorMessage")
        }
        return buildResultMap(
            request = request,
            state = stateStr,
            bytesCached = bytesCached,
            newBytesCached = newBytesCached,
            requestLength = requestLength,
            cacheAvailable = cacheAvailable,
            raw = rawParts,
        )
    }

    private fun buildResultMap(
        request: AndroidDagPlaybackPrewarmRequest,
        state: String,
        bytesCached: Long,
        newBytesCached: Long,
        requestLength: Long,
        cacheAvailable: Boolean,
        raw: String,
    ): Map<String, Any?> = mapOf(
        "phase"                        to "Phase4C6C",
        "requestId"                    to request.requestId,
        "state"                        to state,
        "bytesCached"                  to bytesCached,
        "newBytesCached"               to newBytesCached,
        "requestLength"                to requestLength,
        "cacheAvailable"               to cacheAvailable,
        "prewarmImplemented"           to true,
        "adaptiveSegmentGraphPrefetch" to false,
        "playbackMutation"             to false,
        "webRtcCache"                  to false,
        "raw"                          to raw,
    )
}
