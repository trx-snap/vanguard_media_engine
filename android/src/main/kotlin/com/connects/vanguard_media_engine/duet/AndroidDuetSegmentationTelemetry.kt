package com.connects.vanguard_media_engine.duet

import android.os.SystemClock
import android.util.Log

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Lightweight raw_tflite_gpu inference telemetry.
// -----------------------------------------------------------------------------
//
// Scoped to one [AndroidDuetGreenScreenAdapter] lifetime. Only records while
// the completed callback's backend is [DuetSegmentationBackend.RAW_TFLITE_GPU]
// (the debug/smoke opt-in rung); every other backend is a no-op. This is a
// pure observation seam — it never influences frame closing, in-flight
// release, backend fallback, or mask delivery, and every public method
// catches and logs its own failures rather than throwing back into the
// adapter's frame-completion path.

internal class AndroidDuetSegmentationTelemetry {

    companion object {
        private const val TAG = "DuetRawGpuTelemetry"

        /** raw_tflite_gpu quality-tier inference budget (ms); mirrors AndroidDuetAdaptiveQualityPolicy's QUALITY_BUDGET_MS. */
        private const val RAW_GPU_BUDGET_MS = 35L

        private const val STATS_LOG_INTERVAL = 30

        const val STATS_MARKER = "ANDROID_DUET_RAW_TFLITE_GPU_INFERENCE_STATS"
        const val SUMMARY_MARKER = "ANDROID_DUET_RAW_TFLITE_GPU_INFERENCE_SUMMARY"
    }

    private val lock = Any()
    private var count = 0
    private var masks = 0
    private var skipped = 0
    private var failures = 0
    private var totalDurationMs = 0L
    private var maxDurationMs = 0L
    private var overBudget = 0
    private var startedAtElapsedMs: Long? = null

    private data class Snapshot(
        val count: Int,
        val masks: Int,
        val skipped: Int,
        val failures: Int,
        val avgMs: Long,
        val maxMs: Long,
        val overBudget: Int,
        val elapsedMs: Long,
    )

    /**
     * Records one completed segmentation callback for [backendId]. No-op for
     * any backend other than [DuetSegmentationBackend.RAW_TFLITE_GPU]. Logs a
     * periodic [STATS_MARKER] line every [STATS_LOG_INTERVAL] completed raw
     * GPU callbacks. Never throws.
     */
    fun recordCompletion(
        backendId: String,
        outcome: DuetSegmentationOutcome,
        durationMs: Long,
        quality: String,
        thermal: String,
    ) {
        if (backendId != DuetSegmentationBackend.RAW_TFLITE_GPU) return
        try {
            var dueForStats = false
            synchronized(lock) {
                if (startedAtElapsedMs == null) startedAtElapsedMs = SystemClock.elapsedRealtime()
                count += 1
                totalDurationMs += durationMs
                if (durationMs > maxDurationMs) maxDurationMs = durationMs
                if (durationMs > RAW_GPU_BUDGET_MS) overBudget += 1
                when (outcome) {
                    is DuetSegmentationOutcome.Mask -> masks += 1
                    is DuetSegmentationOutcome.Skipped -> skipped += 1
                    is DuetSegmentationOutcome.Failure -> failures += 1
                }
                dueForStats = count % STATS_LOG_INTERVAL == 0
            }
            if (dueForStats) logStats(quality, thermal)
        } catch (t: Throwable) {
            Log.w(TAG, "recordCompletion failed: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    /**
     * Logs [SUMMARY_MARKER] if at least one raw GPU callback was recorded;
     * otherwise a no-op. Never throws.
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
            Log.i(
                TAG,
                "$SUMMARY_MARKER count=${snapshot.count} masks=${snapshot.masks} skipped=${snapshot.skipped} " +
                    "failures=${snapshot.failures} avgMs=${snapshot.avgMs} maxMs=${snapshot.maxMs} " +
                    "overBudget=${snapshot.overBudget} elapsedMs=${snapshot.elapsedMs} finalBackend=$finalBackend " +
                    "degraded=$degraded terminal=$terminal quality=$quality thermal=$thermal",
            )
        } catch (t: Throwable) {
            Log.w(TAG, "logSummary failed: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    private fun logStats(quality: String, thermal: String) {
        val snapshot = snapshot()
        Log.i(
            TAG,
            "$STATS_MARKER count=${snapshot.count} masks=${snapshot.masks} skipped=${snapshot.skipped} " +
                "failures=${snapshot.failures} avgMs=${snapshot.avgMs} maxMs=${snapshot.maxMs} " +
                "overBudget=${snapshot.overBudget} elapsedMs=${snapshot.elapsedMs} quality=$quality thermal=$thermal",
        )
    }

    private fun snapshot(): Snapshot = synchronized(lock) {
        val avg = if (count > 0) totalDurationMs / count else 0L
        val elapsed = startedAtElapsedMs?.let { SystemClock.elapsedRealtime() - it } ?: 0L
        Snapshot(count, masks, skipped, failures, avg, maxDurationMs, overBudget, elapsed)
    }
}
