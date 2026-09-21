package com.connects.vanguard_media_engine.greenscreen

import android.os.SystemClock
import android.util.Log

// -----------------------------------------------------------------------------
// VG-GREEN-SCREEN: Backend-neutral segmentation completion telemetry.
// -----------------------------------------------------------------------------
//
// Byte-for-byte port of
// `com.connects.vanguard_media_engine.duet.AndroidDuetSegmentationTelemetry`
// (only the package, class name, and referenced backend/outcome types
// changed) — GreenScreen segmentation telemetry is an independent, reusable
// capability and must not be owned by the Duet compositor package. The Duet
// class is kept as a source-compatible type alias onto this one. The
// `ANDROID_DUET_*` log marker text is preserved byte-for-byte since existing
// log parsers/tests may depend on it.
//
// Scoped to one [AndroidGreenScreenFilterNode] lifetime. Records every
// completed segmentation callback regardless of backend (production ladder:
// mediapipe_cpu -> mlkit; debug/smoke ladder additionally includes
// raw_tflite_gpu). This is a pure observation seam — it never influences
// frame closing, in-flight release, backend fallback, quality-policy
// decisions, or mask delivery, and every public method catches and logs its
// own failures rather than throwing back into the filter node's
// frame-completion path.
//
// [durationMs] passed to [recordCompletion] is the filter node's dispatch-to-
// completion wall time measured around backend.segment() in
// AndroidGreenScreenFilterNode, not pure model inference time; it may
// include backend-internal queuing/dispatch overhead.

internal class AndroidGreenScreenSegmentationTelemetry {

    companion object {
        private const val TAG = "GreenScreenSegTelemetry"

        /**
         * Quality-tier dispatch-to-completion budget (ms); mirrors
         * AndroidGreenScreenAdaptiveQualityPolicy's QUALITY_BUDGET_MS. Used as
         * a comparable over-budget threshold across all backends.
         */
        private const val QUALITY_BUDGET_MS = 35L

        private const val STATS_LOG_INTERVAL = 30

        /** Backend-neutral periodic stats marker; covers every backend. */
        const val STATS_MARKER = "ANDROID_DUET_GREENSCREEN_SEGMENTATION_STATS"

        /** Backend-neutral end-of-session summary marker; covers every backend. */
        const val SUMMARY_MARKER = "ANDROID_DUET_GREENSCREEN_SEGMENTATION_SUMMARY"

        /**
         * Raw raw_tflite_gpu-only markers, kept for backward compatibility with
         * existing raw GPU proof/log parsers. Logged in addition to the neutral
         * markers whenever the observed sample/backend path includes
         * raw_tflite_gpu.
         */
        const val RAW_GPU_STATS_MARKER = "ANDROID_DUET_RAW_TFLITE_GPU_INFERENCE_STATS"
        const val RAW_GPU_SUMMARY_MARKER = "ANDROID_DUET_RAW_TFLITE_GPU_INFERENCE_SUMMARY"
    }

    private val lock = Any()
    private var count = 0
    private var masks = 0
    private var gpuMasks = 0
    private var skipped = 0
    private var failures = 0
    private var totalDurationMs = 0L
    private var maxDurationMs = 0L
    private var overBudget = 0
    private var startedAtElapsedMs: Long? = null
    private var latestBackendId: String? = null
    private val observedBackendIds = linkedSetOf<String>()

    /** True once at least one completed callback was recorded for raw_tflite_gpu. */
    private var sawRawGpu = false

    private data class Snapshot(
        val count: Int,
        val masks: Int,
        val gpuMasks: Int,
        val skipped: Int,
        val failures: Int,
        val avgMs: Long,
        val maxMs: Long,
        val overBudget: Int,
        val elapsedMs: Long,
        val latestBackendId: String,
        val backendIds: List<String>,
        val sawRawGpu: Boolean,
    )

    /**
     * Records one completed segmentation callback for [backendId], whichever
     * backend produced it (production or debug/smoke ladder alike). Logs a
     * periodic [STATS_MARKER] line every [STATS_LOG_INTERVAL] completed
     * callbacks (plus a legacy [RAW_GPU_STATS_MARKER] line when [backendId] is
     * raw_tflite_gpu). Never throws.
     */
    fun recordCompletion(
        backendId: String,
        outcome: GreenScreenSegmentationOutcome,
        durationMs: Long,
        quality: String,
        thermal: String,
    ) {
        try {
            var dueForStats = false
            synchronized(lock) {
                if (startedAtElapsedMs == null) startedAtElapsedMs = SystemClock.elapsedRealtime()
                count += 1
                totalDurationMs += durationMs
                if (durationMs > maxDurationMs) maxDurationMs = durationMs
                if (durationMs > QUALITY_BUDGET_MS) overBudget += 1
                when (outcome) {
                    is GreenScreenSegmentationOutcome.Mask -> masks += 1
                    is GreenScreenSegmentationOutcome.GpuMask -> gpuMasks += 1
                    is GreenScreenSegmentationOutcome.Skipped -> skipped += 1
                    is GreenScreenSegmentationOutcome.Failure -> failures += 1
                }
                latestBackendId = backendId
                observedBackendIds.add(backendId)
                if (backendId == AndroidGreenScreenSegmentationBackend.RAW_TFLITE_GPU) sawRawGpu = true
                dueForStats = count % STATS_LOG_INTERVAL == 0
            }
            if (dueForStats) logStats(quality, thermal)
        } catch (t: Throwable) {
            Log.w(TAG, "recordCompletion failed: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    /**
     * Logs [SUMMARY_MARKER] (plus a legacy [RAW_GPU_SUMMARY_MARKER] line if any
     * recorded callback was raw_tflite_gpu) if at least one callback was
     * recorded; otherwise a no-op. Never throws.
     */
    fun logSummary(
        finalBackend: String,
        degraded: Boolean,
        terminal: Boolean,
        quality: String,
        thermal: String,
    ) {
        try {
            val snapshot = snapshot()
            if (snapshot.count == 0) return
            val backends = snapshot.backendIds.joinToString(",")
            Log.i(
                TAG,
                "$SUMMARY_MARKER backends=$backends count=${snapshot.count} masks=${snapshot.masks} " +
                    "gpu_masks=${snapshot.gpuMasks} skipped=${snapshot.skipped} failures=${snapshot.failures} avgMs=${snapshot.avgMs} " +
                    "maxMs=${snapshot.maxMs} overBudget=${snapshot.overBudget} qualityBudgetMs=$QUALITY_BUDGET_MS " +
                    "elapsedMs=${snapshot.elapsedMs} quality=$quality thermal=$thermal finalBackend=$finalBackend " +
                    "degraded=$degraded terminal=$terminal",
            )
            if (snapshot.sawRawGpu) {
                Log.i(
                    TAG,
                    "$RAW_GPU_SUMMARY_MARKER count=${snapshot.count} masks=${snapshot.masks} " +
                        "skipped=${snapshot.skipped} failures=${snapshot.failures} avgMs=${snapshot.avgMs} " +
                        "maxMs=${snapshot.maxMs} overBudget=${snapshot.overBudget} elapsedMs=${snapshot.elapsedMs} " +
                        "finalBackend=$finalBackend degraded=$degraded terminal=$terminal quality=$quality " +
                        "thermal=$thermal",
                )
            }
        } catch (t: Throwable) {
            Log.w(TAG, "logSummary failed: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    private fun logStats(quality: String, thermal: String) {
        val snapshot = snapshot()
        val backends = snapshot.backendIds.joinToString(",")
        Log.i(
            TAG,
            "$STATS_MARKER backends=$backends count=${snapshot.count} masks=${snapshot.masks} " +
                "gpu_masks=${snapshot.gpuMasks} skipped=${snapshot.skipped} failures=${snapshot.failures} avgMs=${snapshot.avgMs} " +
                "maxMs=${snapshot.maxMs} overBudget=${snapshot.overBudget} qualityBudgetMs=$QUALITY_BUDGET_MS " +
                "elapsedMs=${snapshot.elapsedMs} quality=$quality thermal=$thermal",
        )
        if (snapshot.sawRawGpu) {
            Log.i(
                TAG,
                "$RAW_GPU_STATS_MARKER count=${snapshot.count} masks=${snapshot.masks} " +
                    "skipped=${snapshot.skipped} failures=${snapshot.failures} avgMs=${snapshot.avgMs} " +
                    "maxMs=${snapshot.maxMs} overBudget=${snapshot.overBudget} elapsedMs=${snapshot.elapsedMs} " +
                    "quality=$quality thermal=$thermal",
            )
        }
    }

    private fun snapshot(): Snapshot = synchronized(lock) {
        val avg = if (count > 0) totalDurationMs / count else 0L
        val elapsed = startedAtElapsedMs?.let { SystemClock.elapsedRealtime() - it } ?: 0L
        Snapshot(
            count = count,
            masks = masks,
            gpuMasks = gpuMasks,
            skipped = skipped,
            failures = failures,
            avgMs = avg,
            maxMs = maxDurationMs,
            overBudget = overBudget,
            elapsedMs = elapsed,
            latestBackendId = latestBackendId ?: "",
            backendIds = observedBackendIds.toList(),
            sawRawGpu = sawRawGpu,
        )
    }
}
