package com.connects.vanguard_media_engine.greenscreen

import android.os.SystemClock
import android.util.Log

// -----------------------------------------------------------------------------
// VG-GREEN-SCREEN: raw_tflite_gpu per-phase latency telemetry.
// -----------------------------------------------------------------------------
//
// Byte-for-byte port of
// `com.connects.vanguard_media_engine.duet.AndroidDuetRawTfliteGpuPhaseTelemetry`
// (only the package and class name changed) — GreenScreen segmentation
// telemetry is an independent, reusable capability and must not be owned by
// the Duet compositor package. The Duet class is kept as a source-compatible
// type alias onto this one. The `ANDROID_DUET_*` log marker text is preserved
// byte-for-byte since existing log parsers/tests may depend on it.
//
// Scoped to one AndroidGreenScreenRawTfliteGpuSegmentationBackend lifetime.
// Records phase-level timings (convert / scale+pixels / input fill /
// inference / mask extract / total) for each successful segmentOnOwnedThread
// Mask callback, to diagnose sustained-callback latency separately from the
// existing end-to-end AndroidGreenScreenSegmentationTelemetry measurement.
// Pure observation seam — it never influences segmentation results, frame
// closing, backend close behavior, fallback/degrade behavior, or completion
// exactly-once behavior. Every public method catches and logs its own
// failures rather than throwing back into the hot path.

internal class AndroidGreenScreenRawTfliteGpuPhaseTelemetry {

    companion object {
        private const val TAG = "GreenScreenRawGpuPhaseTel"

        private const val STATS_LOG_INTERVAL = 30

        const val STATS_MARKER = "ANDROID_DUET_RAW_TFLITE_GPU_PHASE_STATS"
        const val SUMMARY_MARKER = "ANDROID_DUET_RAW_TFLITE_GPU_PHASE_SUMMARY"
    }

    private val lock = Any()
    private var count = 0
    private var totalSumMs = 0L
    private var totalMaxMs = 0L
    private var convertSumMs = 0L
    private var scalePixelsSumMs = 0L
    private var inputFillSumMs = 0L
    private var inferenceSumMs = 0L
    private var inferenceMaxMs = 0L
    private var maskExtractSumMs = 0L
    private var startedAtElapsedMs: Long? = null

    private data class Snapshot(
        val count: Int,
        val totalAvgMs: Long,
        val totalMaxMs: Long,
        val convertAvgMs: Long,
        val scalePixelsAvgMs: Long,
        val inputFillAvgMs: Long,
        val inferenceAvgMs: Long,
        val inferenceMaxMs: Long,
        val maskExtractAvgMs: Long,
        val elapsedMs: Long,
    )

    /**
     * Records one successful Mask callback's phase timings (all in ms, derived
     * from monotonic elapsedRealtimeNanos marks by the caller). Logs a
     * periodic [STATS_MARKER] line every [STATS_LOG_INTERVAL] recorded masks.
     * Never throws.
     */
    fun recordMask(
        convertMs: Long,
        scaleAndPixelsMs: Long,
        inputFillMs: Long,
        inferenceMs: Long,
        maskExtractMs: Long,
        totalMs: Long,
    ) {
        try {
            var dueForStats = false
            synchronized(lock) {
                if (startedAtElapsedMs == null) startedAtElapsedMs = SystemClock.elapsedRealtime()
                count += 1
                totalSumMs += totalMs
                if (totalMs > totalMaxMs) totalMaxMs = totalMs
                convertSumMs += convertMs
                scalePixelsSumMs += scaleAndPixelsMs
                inputFillSumMs += inputFillMs
                inferenceSumMs += inferenceMs
                if (inferenceMs > inferenceMaxMs) inferenceMaxMs = inferenceMs
                maskExtractSumMs += maskExtractMs
                dueForStats = count % STATS_LOG_INTERVAL == 0
            }
            if (dueForStats) logStats()
        } catch (t: Throwable) {
            Log.w(TAG, "recordMask failed: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    /**
     * Logs [SUMMARY_MARKER] if at least one mask was recorded; otherwise a
     * no-op. Never throws.
     */
    fun logSummary() {
        try {
            val snapshot = snapshot()
            if (snapshot.count == 0) return
            Log.i(TAG, "$SUMMARY_MARKER ${fields(snapshot)} elapsedMs=${snapshot.elapsedMs}")
        } catch (t: Throwable) {
            Log.w(TAG, "logSummary failed: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    private fun logStats() {
        try {
            val snapshot = snapshot()
            Log.i(TAG, "$STATS_MARKER ${fields(snapshot)}")
        } catch (t: Throwable) {
            Log.w(TAG, "logStats failed: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    private fun fields(s: Snapshot): String =
        "count=${s.count} totalAvgMs=${s.totalAvgMs} totalMaxMs=${s.totalMaxMs} " +
            "convertAvgMs=${s.convertAvgMs} scalePixelsAvgMs=${s.scalePixelsAvgMs} " +
            "inputFillAvgMs=${s.inputFillAvgMs} inferenceAvgMs=${s.inferenceAvgMs} " +
            "inferenceMaxMs=${s.inferenceMaxMs} maskExtractAvgMs=${s.maskExtractAvgMs}"

    private fun snapshot(): Snapshot = synchronized(lock) {
        val n = if (count > 0) count else 1
        val elapsed = startedAtElapsedMs?.let { SystemClock.elapsedRealtime() - it } ?: 0L
        Snapshot(
            count = count,
            totalAvgMs = totalSumMs / n,
            totalMaxMs = totalMaxMs,
            convertAvgMs = convertSumMs / n,
            scalePixelsAvgMs = scalePixelsSumMs / n,
            inputFillAvgMs = inputFillSumMs / n,
            inferenceAvgMs = inferenceSumMs / n,
            inferenceMaxMs = inferenceMaxMs,
            maskExtractAvgMs = maskExtractSumMs / n,
            elapsedMs = elapsed,
        )
    }
}
