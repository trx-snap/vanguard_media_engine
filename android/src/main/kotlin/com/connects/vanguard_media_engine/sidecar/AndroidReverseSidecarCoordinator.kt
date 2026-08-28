package com.connects.vanguard_media_engine.sidecar

import android.content.Context
import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Phase 5-Unit Q / Phase 7.20 first honest Android reverse sidecar API slice.
 *
 * Owns the public Dart VGEditorController reverse-sidecar routes
 * (prepareReverseSidecars, getSidecarStatus, cleanupReverseSidecars) so
 * Android no longer returns MissingPluginException for them. This slice does
 * NOT transcode reversed clips — no MediaCodec/MediaExtractor/MediaMuxer,
 * no byte copy, no sidecar file is ever produced. Every prepare of a
 * structurally valid, readable clip terminates in `state=failed` with
 * errorMessage=SIDECAR_UNSUPPORTED_ANDROID. `state=ready` is unreachable on
 * Android until the real transcoder slice lands (RISK-04 / spec V4.3 §154-159).
 */
class AndroidReverseSidecarCoordinator(
    private val context: Context,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "ReverseSidecarCoord"
        private const val CACHE_DIR_NAME = "VGReverseSidecars"

        private val OWNED_METHODS = setOf(
            "prepareReverseSidecars",
            "getSidecarStatus",
            "cleanupReverseSidecars",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    private data class SidecarRecord(
        val clipId: String,
        val sourceHash: String?,
        val errorMessage: String,
        val progress: Double,
    )

    private val lock = Any()
    private val records = mutableMapOf<String, SidecarRecord>()
    private var generation = 0

    private var cleanupExecutor: ExecutorService? = Executors.newSingleThreadExecutor()

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "prepareReverseSidecars" -> prepareReverseSidecars(args, result)
            "getSidecarStatus" -> getSidecarStatus(args, result)
            "cleanupReverseSidecars" -> cleanupReverseSidecars(result)
            else -> return false
        }
        return true
    }

    // ── prepareReverseSidecars ─────────────────────────────────────────────────

    private fun prepareReverseSidecars(args: Map<*, *>?, result: MethodChannel.Result) {
        val clips = args?.get("clips") as? List<*>
        if (clips == null) {
            result.error("INVALID_REVERSE_SIDECAR_ARGS", "prepareReverseSidecars: clips list required", null)
            return
        }
        if (clips.isEmpty()) {
            result.success(mapOf("clips" to emptyList<Map<String, Any?>>()))
            return
        }

        val statuses = clips.map { rawClip -> prepareSingleClip(rawClip as? Map<*, *>) }
        mainHandler.post {
            result.success(mapOf("clips" to statuses))
        }
    }

    private fun prepareSingleClip(clip: Map<*, *>?): Map<String, Any?> {
        val clipId = (clip?.get("clipId") as? String)?.trim()
        val sourcePath = (clip?.get("sourcePath") as? String)?.trim()
        val trimStart = (clip?.get("trimStart") as? Number)?.toDouble()
        val trimEnd = (clip?.get("trimEnd") as? Number)?.toDouble()
        val sourceHash = clip?.get("sourceHash") as? String

        if (clipId.isNullOrBlank() || sourcePath.isNullOrBlank()) {
            return failedStatusMap(clipId ?: "", "SIDECAR_INVALID_ARG")
        }
        if (trimStart == null || trimEnd == null || trimEnd <= trimStart) {
            return failedStatusMap(clipId, "SIDECAR_INVALID_TRIM_RANGE")
        }

        val sourceFile = File(sourcePath)
        if (!sourceFile.exists() || !sourceFile.canRead()) {
            storeRecord(clipId, sourceHash, "SIDECAR_MISSING_SOURCE_FILE")
            return failedStatusMap(clipId, "SIDECAR_MISSING_SOURCE_FILE")
        }

        storeRecord(clipId, sourceHash, "SIDECAR_UNSUPPORTED_ANDROID")
        return failedStatusMap(clipId, "SIDECAR_UNSUPPORTED_ANDROID")
    }

    private fun storeRecord(clipId: String, sourceHash: String?, errorMessage: String) {
        synchronized(lock) {
            records[clipId] = SidecarRecord(
                clipId = clipId,
                sourceHash = sourceHash,
                errorMessage = errorMessage,
                progress = 0.0,
            )
        }
    }

    private fun failedStatusMap(clipId: String, errorMessage: String): Map<String, Any?> {
        return mapOf(
            "clipId" to clipId,
            "state" to "failed",
            "sidecarPath" to null,
            "errorMessage" to errorMessage,
            "progress" to 0.0,
        )
    }

    // ── getSidecarStatus ────────────────────────────────────────────────────────

    private fun getSidecarStatus(args: Map<*, *>?, result: MethodChannel.Result) {
        val clipId = (args?.get("clipId") as? String)?.trim()
        if (clipId.isNullOrBlank()) {
            result.error("INVALID_REVERSE_SIDECAR_ARGS", "getSidecarStatus: clipId required", null)
            return
        }

        val record = synchronized(lock) { records[clipId] }
        if (record == null) {
            result.success(mapOf(
                "clipId" to clipId,
                "state" to "idle",
                "progress" to 0.0,
            ))
            return
        }

        result.success(failedStatusMap(record.clipId, record.errorMessage))
    }

    // ── cleanupReverseSidecars ──────────────────────────────────────────────────

    private fun cleanupReverseSidecars(result: MethodChannel.Result) {
        synchronized(lock) {
            records.clear()
            generation += 1
        }

        val executor = synchronized(lock) { cleanupExecutor }
        if (executor == null) {
            mainHandler.post { result.success(mapOf("ok" to true)) }
            return
        }

        executor.execute {
            deleteSidecarCacheContents()
            mainHandler.post { result.success(mapOf("ok" to true)) }
        }
    }

    // ── cache cleanup helper ────────────────────────────────────────────────────

    private fun deleteSidecarCacheContents() {
        try {
            val dir = File(context.cacheDir, CACHE_DIR_NAME)
            if (dir.exists()) {
                dir.listFiles()?.forEach { child ->
                    child.deleteRecursively()
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "deleteSidecarCacheContents: cleanup failed", t)
        }
    }

    // ── disposeAll ─────────────────────────────────────────────────────────────

    /** Best-effort idempotent cleanup for plugin detach. */
    fun disposeAll() {
        val executor: ExecutorService?
        synchronized(lock) {
            records.clear()
            generation += 1
            executor = cleanupExecutor
            cleanupExecutor = null
        }

        if (executor == null) {
            runDisposeCleanupOnBoundedThread()
            return
        }

        try {
            executor.execute { deleteSidecarCacheContents() }
        } catch (t: Throwable) {
            Log.w(TAG, "disposeAll: executor rejected cleanup task, falling back to thread", t)
            runDisposeCleanupOnBoundedThread()
        } finally {
            executor.shutdown()
        }
    }

    private fun runDisposeCleanupOnBoundedThread() {
        try {
            Thread({ deleteSidecarCacheContents() }, "VGReverseSidecarDisposeCleanup").apply {
                isDaemon = true
                start()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "disposeAll: failed to start fallback cleanup thread", t)
        }
    }
}
