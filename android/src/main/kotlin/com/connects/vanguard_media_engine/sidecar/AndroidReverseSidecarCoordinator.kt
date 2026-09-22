package com.connects.vanguard_media_engine.sidecar

import android.content.Context
import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.util.AndroidUriDataSourceHelper
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.ceil
import kotlin.math.roundToInt

/**
 * P5-REVERSE-SIDECAR-TRANSCODE-FOUNDATION.
 *
 * Owns the public Dart VGEditorController reverse-sidecar routes
 * (prepareReverseSidecars, getSidecarStatus, cleanupReverseSidecars).
 *
 * Structurally valid, bounded, readable clips are handed to
 * [AndroidReverseSidecarTranscoder] on a dedicated single-thread executor
 * (never the platform main thread) and can reach `state=ready`. Invalid
 * arguments, a missing/unreadable source file, or a trim window/frame
 * count/canvas size outside the bounds below remain synchronous
 * `state=failed` responses. Any decode/encode failure inside the transcoder
 * also fails closed.
 *
 * Bounds (enforced before any decode/encode work starts):
 *   - trim window <= [MAX_DURATION_SECONDS]
 *   - output frame count <= [MAX_FRAMES] (derived from
 *     [AndroidReverseSidecarTranscoder.OUTPUT_FPS])
 *   - target canvas major axis <= [MAX_MAJOR_AXIS], minor axis <= [MAX_MINOR_AXIS]
 *
 * Generation guard: [generation] is captured once per [prepareReverseSidecars]
 * call. [cleanupReverseSidecars]/[disposeAll] bump it. A transcode that
 * finishes after the generation has moved on deletes its own owned temp/final
 * files and never writes a record into [records] -- a stale background
 * transcode can never resurrect state a concurrent cleanup already wiped.
 * The same generation check is also handed to the transcoder as a cooperative
 * cancellation poll ([AndroidReverseSidecarTranscoder.Params.isCancelled]), so
 * an in-flight job bails out boundedly instead of running to completion after
 * it is already stale; either way it always resolves to `state=invalidated`.
 */
class AndroidReverseSidecarCoordinator(
    private val context: Context,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "ReverseSidecarCoord"
        private const val CACHE_DIR_NAME = "VGReverseSidecars"
        private const val TEMP_SUFFIX = ".vgtmp"
        private const val FINAL_SUFFIX = ".mp4"
        private const val MAX_ID_LENGTH = 128

        private const val MAX_DURATION_SECONDS = 10.05
        private const val MAX_FRAMES = 305
        private const val MAX_MAJOR_AXIS = 3840
        private const val MAX_MINOR_AXIS = 2160
        private const val PREVIEW_MAX_MAJOR_AXIS = 1920

        private const val STATE_PREPARING = "preparing"
        private const val STATE_READY = "ready"
        private const val STATE_FAILED = "failed"
        private const val STATE_INVALIDATED = "invalidated"

        private const val CODE_INVALID_ARG = "SIDECAR_INVALID_ARG"
        private const val CODE_INVALID_TRIM_RANGE = "SIDECAR_INVALID_TRIM_RANGE"
        private const val CODE_MISSING_SOURCE_FILE = "SIDECAR_MISSING_SOURCE_FILE"
        private const val CODE_TRIM_WINDOW_TOO_LONG = "SIDECAR_TRIM_WINDOW_TOO_LONG"
        private const val CODE_ENCODE_FAILED = AndroidReverseSidecarTranscoder.CODE_ENCODE_FAILED
        private const val CODE_OUTPUT_EMPTY = AndroidReverseSidecarTranscoder.CODE_OUTPUT_EMPTY
        private const val CODE_CANCELLED = AndroidReverseSidecarTranscoder.CODE_CANCELLED

        private val OWNED_METHODS = setOf(
            "prepareReverseSidecars",
            "getSidecarStatus",
            "cleanupReverseSidecars",
            "probeReverseSidecarOrdering",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    private data class SidecarRecord(
        val clipId: String,
        val sourceHash: String?,
        val state: String,
        val finalPath: String?,
        val errorMessage: String?,
        val progress: Double,
    )

    private data class TranscodeJob(
        val clipId: String,
        val sourceHash: String?,
        val sourcePath: String,
        val trimStart: Double,
        val trimEnd: Double,
        val targetWidth: Int,
        val targetHeight: Int,
        val frameCount: Int,
        val tempPath: String,
        val finalPath: String,
    )

    private data class PendingClip(val index: Int, val job: TranscodeJob)

    private sealed class AdmitOutcome {
        data class Resolved(val status: Map<String, Any?>) : AdmitOutcome()
        data class Admitted(val job: TranscodeJob) : AdmitOutcome()
    }

    private val lock = Any()
    private val records = mutableMapOf<String, SidecarRecord>()
    private var generation = 0

    private var sidecarExecutor: ExecutorService? = Executors.newSingleThreadExecutor()
    private var cleanupExecutor: ExecutorService? = Executors.newSingleThreadExecutor()

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "prepareReverseSidecars" -> prepareReverseSidecars(args, result)
            "getSidecarStatus" -> getSidecarStatus(args, result)
            "cleanupReverseSidecars" -> cleanupReverseSidecars(result)
            "probeReverseSidecarOrdering" -> probeReverseSidecarOrdering(args, result)
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

        val capturedGeneration = synchronized(lock) { generation }
        val outputs = arrayOfNulls<Map<String, Any?>>(clips.size)
        val pending = mutableListOf<PendingClip>()

        clips.forEachIndexed { index, rawClip ->
            when (val outcome = validateAndAdmitClip(rawClip as? Map<*, *>, capturedGeneration)) {
                is AdmitOutcome.Resolved -> outputs[index] = outcome.status
                is AdmitOutcome.Admitted -> pending.add(PendingClip(index, outcome.job))
            }
        }

        if (pending.isEmpty()) {
            val finalList = outputs.map { it ?: failedStatusMap("", CODE_ENCODE_FAILED) }
            mainHandler.post { result.success(mapOf("clips" to finalList)) }
            return
        }

        val executor = synchronized(lock) { sidecarExecutor }
        if (executor == null) {
            failPendingAfterExecutorUnavailable(pending, outputs, capturedGeneration)
            val finalList = outputs.map { it ?: failedStatusMap("", CODE_ENCODE_FAILED) }
            mainHandler.post { result.success(mapOf("clips" to finalList)) }
            return
        }

        try {
            executor.execute {
                for (p in pending) {
                    outputs[p.index] = runTranscodeJob(p.job, capturedGeneration)
                }
                val finalList = outputs.map { it ?: failedStatusMap("", CODE_ENCODE_FAILED) }
                mainHandler.post { result.success(mapOf("clips" to finalList)) }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "prepareReverseSidecars: executor rejected task, failing pending jobs", t)
            failPendingAfterExecutorUnavailable(pending, outputs, capturedGeneration)
            val finalList = outputs.map { it ?: failedStatusMap("", CODE_ENCODE_FAILED) }
            mainHandler.post { result.success(mapOf("clips" to finalList)) }
        }
    }

    /// Called when [sidecarExecutor] is null or rejects the transcode task
    /// (e.g. dispose raced [prepareReverseSidecars]). Deletes each pending
    /// job's owned temp/final files and resolves it as `failed` (if
    /// [generation] still matches [capturedGeneration], recording it) or
    /// `invalidated` (if a concurrent cleanup/dispose already moved on).
    private fun failPendingAfterExecutorUnavailable(
        pending: List<PendingClip>,
        outputs: Array<Map<String, Any?>?>,
        capturedGeneration: Int,
    ) {
        val cacheDir = File(context.cacheDir, CACHE_DIR_NAME)
        for (p in pending) {
            deleteIfContained(cacheDir, File(p.job.tempPath))
            deleteIfContained(cacheDir, File(p.job.finalPath))
            val stillCurrent = synchronized(lock) { generation == capturedGeneration }
            outputs[p.index] = if (stillCurrent) {
                storeFailedRecord(p.job.clipId, p.job.sourceHash, CODE_ENCODE_FAILED)
                failedStatusMap(p.job.clipId, CODE_ENCODE_FAILED)
            } else {
                invalidatedStatusMap(p.job.clipId)
            }
        }
    }

    /// Synchronous, cheap validation only (arg parsing, stat()s, bounds
    /// arithmetic) -- never decodes or encodes. Clips that pass every check
    /// are admitted with a `preparing` record and handed back as a
    /// [TranscodeJob] for the caller to dispatch onto [sidecarExecutor].
    private fun validateAndAdmitClip(clip: Map<*, *>?, capturedGeneration: Int): AdmitOutcome {
        val clipId = (clip?.get("clipId") as? String)?.trim()
        val sourcePath = (clip?.get("sourcePath") as? String)?.trim()
        val trimStart = (clip?.get("trimStart") as? Number)?.toDouble()
        val trimEnd = (clip?.get("trimEnd") as? Number)?.toDouble()
        val targetWidthRaw = (clip?.get("targetWidth") as? Number)?.toDouble()
        val targetHeightRaw = (clip?.get("targetHeight") as? Number)?.toDouble()
        val sourceHash = clip?.get("sourceHash") as? String

        if (clipId.isNullOrBlank() || sourcePath.isNullOrBlank()) {
            return AdmitOutcome.Resolved(failedStatusMap(clipId ?: "", CODE_INVALID_ARG))
        }
        if (trimStart == null || trimEnd == null || trimEnd <= trimStart) {
            return AdmitOutcome.Resolved(failedStatusMap(clipId, CODE_INVALID_TRIM_RANGE))
        }

        if (!AndroidUriDataSourceHelper.isReadable(sourcePath, context)) {
            Log.w(TAG, "validateAndAdmitClip: clipId=$clipId unreadable sourcePath=$sourcePath")
            storeFailedRecord(clipId, sourceHash, CODE_MISSING_SOURCE_FILE)
            return AdmitOutcome.Resolved(failedStatusMap(clipId, CODE_MISSING_SOURCE_FILE))
        }

        val windowSeconds = trimEnd - trimStart
        var targetWidth = (targetWidthRaw ?: 0.0).roundToInt()
        var targetHeight = (targetHeightRaw ?: 0.0).roundToInt()
        val frameCount = ceil(windowSeconds * AndroidReverseSidecarTranscoder.OUTPUT_FPS).toInt()

        val majorAxis = maxOf(targetWidth, targetHeight)
        val minorAxis = minOf(targetWidth, targetHeight)

        val outOfBounds = windowSeconds <= 0.0 ||
            windowSeconds > MAX_DURATION_SECONDS ||
            frameCount <= 0 ||
            frameCount > MAX_FRAMES ||
            targetWidth <= 0 || targetHeight <= 0 ||
            majorAxis > MAX_MAJOR_AXIS || minorAxis > MAX_MINOR_AXIS
        if (outOfBounds) {
            Log.w(TAG, "validateAndAdmitClip: clipId=$clipId outOfBounds: windowSeconds=$windowSeconds frameCount=$frameCount targetWidth=$targetWidth targetHeight=$targetHeight")
            storeFailedRecord(clipId, sourceHash, CODE_TRIM_WINDOW_TOO_LONG)
            return AdmitOutcome.Resolved(failedStatusMap(clipId, CODE_TRIM_WINDOW_TOO_LONG))
        }

        // Clamp transcode dimensions for preview so major axis does not exceed PREVIEW_MAX_MAJOR_AXIS,
        // and ensure both dimensions are even for MediaCodec AVC.
        if (majorAxis > PREVIEW_MAX_MAJOR_AXIS) {
            val scale = PREVIEW_MAX_MAJOR_AXIS.toDouble() / majorAxis
            targetWidth = (targetWidth * scale).roundToInt()
            targetHeight = (targetHeight * scale).roundToInt()
        }
        targetWidth = (maxOf(targetWidth, 2) / 2) * 2
        targetHeight = (maxOf(targetHeight, 2) / 2) * 2

        val cacheDir = File(context.cacheDir, CACHE_DIR_NAME)
        try { cacheDir.mkdirs() } catch (_: Throwable) {}

        val sanitizedId = sanitizeIdentifier(clipId)
        val sanitizedHash = sourceHash?.let { sanitizeIdentifier(it) }
        // Generation-scoped so a stale job from an older generation can never
        // share (and race to delete/overwrite) the temp/final path of a newer
        // job admitted for the same clipId/sourceHash.
        val ownerSuffix = "g$capturedGeneration"
        val baseName = if (sanitizedHash.isNullOrBlank()) {
            "${sanitizedId}_$ownerSuffix"
        } else {
            "${sanitizedId}_${sanitizedHash}_$ownerSuffix"
        }
        val tempFile = File(cacheDir, "$baseName$TEMP_SUFFIX")
        val finalFile = File(cacheDir, "$baseName$FINAL_SUFFIX")

        if (!isContained(cacheDir, tempFile) || !isContained(cacheDir, finalFile)) {
            storeFailedRecord(clipId, sourceHash, CODE_INVALID_ARG)
            return AdmitOutcome.Resolved(failedStatusMap(clipId, CODE_INVALID_ARG))
        }

        synchronized(lock) {
            records[clipId] = SidecarRecord(
                clipId = clipId,
                sourceHash = sourceHash,
                state = STATE_PREPARING,
                finalPath = null,
                errorMessage = null,
                progress = 0.0,
            )
        }

        return AdmitOutcome.Admitted(
            TranscodeJob(
                clipId = clipId,
                sourceHash = sourceHash,
                sourcePath = sourcePath,
                trimStart = trimStart,
                trimEnd = trimEnd,
                targetWidth = targetWidth,
                targetHeight = targetHeight,
                frameCount = frameCount,
                tempPath = tempFile.absolutePath,
                finalPath = finalFile.absolutePath,
            ),
        )
    }

    /// Runs on [sidecarExecutor]. Transcodes into [TranscodeJob.tempPath],
    /// then -- only if [generation] still matches [capturedGeneration] --
    /// renames to [TranscodeJob.finalPath] and publishes a `ready` record.
    /// Otherwise (or on any failure) deletes its own owned temp/final files
    /// and never touches [records] with a resurrected entry.
    private fun runTranscodeJob(job: TranscodeJob, capturedGeneration: Int): Map<String, Any?> {
        val cacheDir = File(context.cacheDir, CACHE_DIR_NAME)
        val tempFile = File(job.tempPath)
        val finalFile = File(job.finalPath)

        val result = try {
            AndroidReverseSidecarTranscoder().transcode(
                AndroidReverseSidecarTranscoder.Params(
                    sourcePath = job.sourcePath,
                    outputPath = job.tempPath,
                    trimStartSeconds = job.trimStart,
                    trimEndSeconds = job.trimEnd,
                    frameCount = job.frameCount,
                    targetWidth = job.targetWidth,
                    targetHeight = job.targetHeight,
                    context = context,
                    // Cooperative cancellation: a concurrent cleanup/dispose bumps
                    // [generation], and this poll lets the transcoder bail out of
                    // its own in-flight work boundedly instead of racing to
                    // publish/overwrite state a cleanup already wiped.
                    isCancelled = { synchronized(lock) { generation != capturedGeneration } },
                ),
            )
        } catch (t: Throwable) {
            Log.e(TAG, "runTranscodeJob: transcode threw for ${job.clipId}", t)
            null
        }

        val failureCode = when {
            result == null -> CODE_ENCODE_FAILED
            !result.success -> result.failureCode ?: CODE_ENCODE_FAILED
            result.writtenVideoSamples <= 0 -> CODE_OUTPUT_EMPTY
            !tempFile.exists() || tempFile.length() <= 0L -> CODE_OUTPUT_EMPTY
            else -> null
        }

        if (failureCode != null) {
            Log.w(TAG, "runTranscodeJob: clipId=${job.clipId} failed with code=$failureCode")
            deleteIfContained(cacheDir, tempFile)
            val stillCurrent = synchronized(lock) { generation == capturedGeneration }
            // A cancellation only ever fires once generation has moved on, so
            // it always maps to invalidated, never failed -- regardless of
            // [stillCurrent] (defensive; stillCurrent is already guaranteed
            // false whenever failureCode is CODE_CANCELLED).
            if (failureCode == CODE_CANCELLED || !stillCurrent) {
                return invalidatedStatusMap(job.clipId)
            }
            storeFailedRecord(job.clipId, job.sourceHash, failureCode)
            return failedStatusMap(job.clipId, failureCode)
        }

        deleteIfContained(cacheDir, finalFile)
        val renamed = try { tempFile.renameTo(finalFile) } catch (_: Throwable) { false }
        if (!renamed || !finalFile.exists() || finalFile.length() <= 0L) {
            deleteIfContained(cacheDir, tempFile)
            deleteIfContained(cacheDir, finalFile)
            val stillCurrent = synchronized(lock) { generation == capturedGeneration }
            if (!stillCurrent) {
                return invalidatedStatusMap(job.clipId)
            }
            storeFailedRecord(job.clipId, job.sourceHash, CODE_ENCODE_FAILED)
            return failedStatusMap(job.clipId, CODE_ENCODE_FAILED)
        }

        val published = synchronized(lock) {
            if (generation != capturedGeneration) {
                false
            } else {
                records[job.clipId] = SidecarRecord(
                    clipId = job.clipId,
                    sourceHash = job.sourceHash,
                    state = STATE_READY,
                    finalPath = finalFile.absolutePath,
                    errorMessage = null,
                    progress = 1.0,
                )
                true
            }
        }

        if (!published) {
            deleteIfContained(cacheDir, finalFile)
            return invalidatedStatusMap(job.clipId)
        }

        Log.i(TAG, "runTranscodeJob: clipId=${job.clipId} ready at ${finalFile.absolutePath}")
        return mapOf(
            "clipId" to job.clipId,
            "state" to STATE_READY,
            "sidecarPath" to finalFile.absolutePath,
            "errorMessage" to null,
            "progress" to 1.0,
        )
    }

    private fun storeFailedRecord(clipId: String, sourceHash: String?, errorMessage: String) {
        synchronized(lock) {
            records[clipId] = SidecarRecord(
                clipId = clipId,
                sourceHash = sourceHash,
                state = STATE_FAILED,
                finalPath = null,
                errorMessage = errorMessage,
                progress = 0.0,
            )
        }
    }

    private fun failedStatusMap(clipId: String, errorMessage: String): Map<String, Any?> {
        return mapOf(
            "clipId" to clipId,
            "state" to STATE_FAILED,
            "sidecarPath" to null,
            "errorMessage" to errorMessage,
            "progress" to 0.0,
        )
    }

    private fun invalidatedStatusMap(clipId: String): Map<String, Any?> {
        return mapOf(
            "clipId" to clipId,
            "state" to STATE_INVALIDATED,
            "sidecarPath" to null,
            "errorMessage" to null,
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

        if (record.state == STATE_READY) {
            val path = record.finalPath
            val stillReady = path != null && try {
                val f = File(path)
                f.exists() && f.length() > 0L
            } catch (_: Throwable) {
                false
            }
            if (!stillReady) {
                storeFailedRecord(record.clipId, record.sourceHash, CODE_OUTPUT_EMPTY)
                result.success(failedStatusMap(record.clipId, CODE_OUTPUT_EMPTY))
                return
            }
            result.success(mapOf(
                "clipId" to record.clipId,
                "state" to STATE_READY,
                "sidecarPath" to path,
                "errorMessage" to null,
                "progress" to 1.0,
            ))
            return
        }

        result.success(mapOf(
            "clipId" to record.clipId,
            "state" to record.state,
            "sidecarPath" to null,
            "errorMessage" to record.errorMessage,
            "progress" to record.progress,
        ))
    }

    /**
     * Returns the absolute path of the ready reverse sidecar MP4 for [clipId] if
     * it exists and is non-empty, or null if no sidecar is ready.
     * Thread-safe; read-only.
     */
    fun getReadySidecarPath(clipId: String): String? {
        val record = synchronized(lock) { records[clipId] } ?: return null
        if (record.state != STATE_READY) return null
        val path = record.finalPath ?: return null
        val stillReady = try {
            val f = File(path)
            f.exists() && f.length() > 0L
        } catch (_: Throwable) {
            false
        }
        return if (stillReady) path else null
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

        try {
            executor.execute {
                deleteSidecarCacheContents()
                mainHandler.post { result.success(mapOf("ok" to true)) }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "cleanupReverseSidecars: executor rejected cleanup task, falling back to thread", t)
            runCleanupOnBoundedThreadAndReply(result)
        }
    }

    /// Fallback for when [cleanupExecutor] rejects (e.g. [disposeAll] raced
    /// this call and shut it down). Runs best-effort cache cleanup on a
    /// throwaway thread and replies exactly once, mirroring the executor
    /// success path above.
    private fun runCleanupOnBoundedThreadAndReply(result: MethodChannel.Result) {
        try {
            Thread({
                deleteSidecarCacheContents()
                mainHandler.post { result.success(mapOf("ok" to true)) }
            }, "VGReverseSidecarCleanupFallback").apply {
                isDaemon = true
                start()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "cleanupReverseSidecars: failed to start fallback cleanup thread", t)
            mainHandler.post { result.success(mapOf("ok" to true)) }
        }
    }

    // ── probeReverseSidecarOrdering ─────────────────────────────────────────────

    private fun probeReverseSidecarOrdering(args: Map<*, *>?, result: MethodChannel.Result) {
        val sExecutor = synchronized(lock) { sidecarExecutor }
        if (sExecutor != null && !sExecutor.isShutdown) {
            try {
                sExecutor.execute {
                    val report = AndroidReverseSidecarOrderingProbe.probe(args)
                    mainHandler.post { result.success(report) }
                }
                return
            } catch (t: Throwable) {
                Log.w(TAG, "probeReverseSidecarOrdering: executor rejected probe task, falling back to thread", t)
            }
        }

        try {
            Thread({
                val report = AndroidReverseSidecarOrderingProbe.probe(args)
                mainHandler.post { result.success(report) }
            }, "VGReverseSidecarOrderingProbe").apply {
                isDaemon = true
                start()
            }
        } catch (t: Throwable) {
            Log.e(TAG, "probeReverseSidecarOrdering: failed to start probe thread", t)
            mainHandler.post {
                result.success(
                    mapOf(
                        "pass" to false,
                        "reason" to (t.message ?: "probe_thread_start_failed"),
                        "frameCount" to 0,
                        "fps" to 0.0,
                        "probeCount" to 0,
                        "reverseWins" to 0,
                        "avgReverseDistance" to 0.0,
                        "avgForwardDistance" to 0.0,
                        "sidecarSampleCount" to 0,
                        "sidecarPtsMonotonic" to false,
                        "proofBoundary" to "AndroidReverseSidecarOrderingProbe",
                    )
                )
            }
        }
    }

    // ── path / identifier helpers ───────────────────────────────────────────────

    private fun sanitizeIdentifier(value: String): String {
        return value.replace(Regex("[^A-Za-z0-9_-]"), "_").take(MAX_ID_LENGTH)
    }

    /// Canonical-path containment check (containment only -- not a symlink
    /// check). Defense-in-depth: [sanitizeIdentifier] already strips any
    /// path-traversal-capable characters, so this should never actually
    /// reject a real clipId/sourceHash.
    private fun isContained(parent: File, child: File): Boolean {
        return try {
            val parentCanonical = parent.canonicalPath
            val childCanonical = child.canonicalPath
            childCanonical.length > parentCanonical.length &&
                childCanonical.startsWith(parentCanonical) &&
                childCanonical[parentCanonical.length] == File.separatorChar
        } catch (_: Throwable) {
            false
        }
    }

    private fun deleteIfContained(root: File, file: File) {
        try {
            if (isContained(root, file) && file.exists()) {
                file.delete()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "deleteIfContained: failed to delete ${file.path}", t)
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
        val sExecutor: ExecutorService?
        val cExecutor: ExecutorService?
        synchronized(lock) {
            records.clear()
            generation += 1
            sExecutor = sidecarExecutor
            sidecarExecutor = null
            cExecutor = cleanupExecutor
            cleanupExecutor = null
        }

        try {
            sExecutor?.shutdown()
        } catch (t: Throwable) {
            Log.w(TAG, "disposeAll: failed to shut down sidecar executor", t)
        }

        if (cExecutor == null) {
            runDisposeCleanupOnBoundedThread()
            return
        }

        try {
            cExecutor.execute { deleteSidecarCacheContents() }
        } catch (t: Throwable) {
            Log.w(TAG, "disposeAll: executor rejected cleanup task, falling back to thread", t)
            runDisposeCleanupOnBoundedThread()
        } finally {
            cExecutor.shutdown()
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
