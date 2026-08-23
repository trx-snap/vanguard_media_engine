// Copyright (c) Connects — Vanguard Android True-DAG Phase 4C6F3.
// Streaming cache low-storage prewarm admission guard.
//
// Evaluates app-cache filesystem headroom using StatFs on the cache directory path.
// This file does NOT create, delete, or mutate any cache files or SimpleCache state.

package com.connects.vanguard_media_engine.streaming

import android.os.StatFs
import android.util.Log
import java.io.File

/**
 * Vanguard Android True-DAG Phase 4C6F3: Streaming cache low-storage prewarm admission guard.
 *
 * Evaluates available filesystem headroom on the app-cache partition using [StatFs.getAvailableBytes].
 * [StatFs.getAvailableBytes] reports bytes free and available to normal applications (excludes
 * reserved blocks unavailable to normal apps — preferred over [StatFs.getFreeBytes] per Android docs).
 *
 * ## Safety invariants
 * - This class does **NOT** create, delete, or mutate any cache files or [SimpleCache] state.
 * - It may ensure the **parent** of the cache directory path exists only if needed for [StatFs]
 *   safety (StatFs requires a valid mounted path), but prefers using an existing parent when available.
 * - All [StatFs] calls are wrapped defensively; failures return [StorageGuardResult.error].
 *
 * ## Thread-safety
 * - [evaluate] is safe to call from any background thread. Does not block the UI thread.
 */
object AndroidDagPlaybackStorageGuard {

    private const val TAG = "DagStorageGuard"

    /** Default minimum free-bytes reserve: 64 MiB. */
    const val DEFAULT_MIN_FREE_BYTES: Long = 64L * 1024L * 1024L

    /**
     * Result of a storage guard evaluation.
     */
    sealed class StorageGuardResult {

        /** Guard passed — sufficient storage headroom is projected after prewarm. */
        data class Pass(
            val availableBytes: Long,
            val requestedBytes: Long,
            val minimumFreeBytesAfterPrewarm: Long,
            val projectedAvailableBytes: Long,
        ) : StorageGuardResult()

        /** Guard blocked — insufficient storage headroom projected after prewarm. */
        data class Blocked(
            val availableBytes: Long,
            val requestedBytes: Long,
            val minimumFreeBytesAfterPrewarm: Long,
            val projectedAvailableBytes: Long,
        ) : StorageGuardResult()

        /** Guard could not evaluate (StatFs error or path resolution failure). */
        data class Error(val reason: String) : StorageGuardResult()
    }

    /**
     * Evaluates filesystem headroom for the given [cacheDirPath] against [requestedBytes] and
     * [minimumFreeBytesAfterPrewarm].
     *
     * Decision logic:
     * ```
     * projectedAvailableBytes = availableBytes - requestedBytes
     * pass when minimumFreeBytesAfterPrewarm <= 0
     *          OR projectedAvailableBytes >= minimumFreeBytesAfterPrewarm
     * ```
     *
     * When [minimumFreeBytesAfterPrewarm] is 0 or negative, the guard is explicitly disabled
     * and always returns [StorageGuardResult.Pass].
     *
     * @param cacheDirPath              Absolute path to the cache directory (or its intended location).
     *                                   Used to resolve the mounted filesystem for [StatFs].
     * @param requestedBytes            Maximum bytes the prewarm job intends to write.
     * @param minimumFreeBytesAfterPrewarm Minimum bytes that must remain free after prewarm.
     *                                   0 or negative disables the guard.
     */
    fun evaluate(
        cacheDirPath: String,
        requestedBytes: Long,
        minimumFreeBytesAfterPrewarm: Long,
    ): StorageGuardResult {
        // Guard explicitly disabled when minimumFreeBytesAfterPrewarm <= 0.
        if (minimumFreeBytesAfterPrewarm <= 0L) {
            Log.d(TAG, "Phase4C6F3 storageGuard: disabled (minimumFreeBytesAfterPrewarm=$minimumFreeBytesAfterPrewarm); pass.")
            // We still want to report real storage metrics, so we attempt StatFs but treat
            // failure as a pass (guard is disabled, it should not block).
            val available = queryAvailableBytes(cacheDirPath) ?: 0L
            val projected = available - requestedBytes
            return StorageGuardResult.Pass(
                availableBytes = available,
                requestedBytes = requestedBytes,
                minimumFreeBytesAfterPrewarm = minimumFreeBytesAfterPrewarm,
                projectedAvailableBytes = projected,
            )
        }

        val availableBytes = queryAvailableBytes(cacheDirPath)
            ?: return StorageGuardResult.Error("StatFs failed for path: $cacheDirPath")

        val projectedAvailableBytes = availableBytes - requestedBytes

        return if (projectedAvailableBytes >= minimumFreeBytesAfterPrewarm) {
            Log.d(
                TAG,
                "Phase4C6F3 storageGuard: PASS available=${availableBytes}B " +
                    "requested=${requestedBytes}B projected=${projectedAvailableBytes}B " +
                    "reserve=${minimumFreeBytesAfterPrewarm}B",
            )
            StorageGuardResult.Pass(
                availableBytes = availableBytes,
                requestedBytes = requestedBytes,
                minimumFreeBytesAfterPrewarm = minimumFreeBytesAfterPrewarm,
                projectedAvailableBytes = projectedAvailableBytes,
            )
        } else {
            Log.w(
                TAG,
                "Phase4C6F3 storageGuard: BLOCKED available=${availableBytes}B " +
                    "requested=${requestedBytes}B projected=${projectedAvailableBytes}B " +
                    "reserve=${minimumFreeBytesAfterPrewarm}B",
            )
            StorageGuardResult.Blocked(
                availableBytes = availableBytes,
                requestedBytes = requestedBytes,
                minimumFreeBytesAfterPrewarm = minimumFreeBytesAfterPrewarm,
                projectedAvailableBytes = projectedAvailableBytes,
            )
        }
    }

    /**
     * Resolves a suitable existing filesystem path from [cacheDirPath] and queries
     * [StatFs.getAvailableBytes].
     *
     * Strategy (preserves the invariant that we do not create cache files):
     * 1. If [cacheDirPath] itself exists (it should once [AndroidDagPlaybackCacheManager] has
     *    initialised), use it directly.
     * 2. Otherwise, walk up the parent chain to find the first existing ancestor to feed to
     *    [StatFs]. The parent of the cache subdirectory is the Android app cacheDir which is
     *    always guaranteed to exist.
     * 3. If no existing ancestor is found (pathological environment), return null.
     *
     * Returns `null` on any [StatFs] or [SecurityException] failure.
     */
    private fun queryAvailableBytes(cacheDirPath: String): Long? {
        return try {
            val statFsPath = resolveExistingPath(cacheDirPath)
                ?: return run {
                    Log.w(TAG, "Phase4C6F3 storageGuard: no existing ancestor found for $cacheDirPath")
                    null
                }
            val statFs = StatFs(statFsPath)
            statFs.availableBytes
        } catch (t: Throwable) {
            Log.w(TAG, "Phase4C6F3 storageGuard: StatFs threw for $cacheDirPath: ${t.message}", t)
            null
        }
    }

    /**
     * Finds the first existing path at or above [path]. Does not create any directory.
     *
     * Returns the canonical path string if found, or `null` if no existing ancestor exists
     * within a reasonable traversal depth.
     */
    private fun resolveExistingPath(path: String): String? {
        var file: File? = File(path)
        var depth = 0
        while (file != null && depth < 10) {
            if (file.exists()) return file.absolutePath
            file = file.parentFile
            depth++
        }
        return null
    }
}
