package com.connects.vanguard_media_engine.codec

import android.util.Log
import java.util.Arrays

/**
 * Vanguard Android True-DAG: render-cadence telemetry for continuous texture playback.
 *
 * Aggregates one Choreographer tick at a time (see [onFrameTick]) into ~1s windows and
 * emits a single `CADENCE_1S` `Log.d` line per window so dropped/uneven frame delivery can
 * be diagnosed from logcat without per-frame logging. Designed for the playback control
 * thread: every window field is plain primitive state touched only from [onFrameTick] /
 * [resetWindow] / [resetAll], and the only allocation on the hot path is nothing at all —
 * interval samples live in a fixed [LongArray] and the log line is built once per window.
 *
 * Totals are `@Volatile` so diagnostic snapshots taken from other threads read the latest
 * committed values; they are never used for cross-thread coordination.
 */
internal class AndroidDagPlaybackCadenceTelemetry(
    private val tag: String,
    private val windowNanos: Long = DEFAULT_WINDOW_NANOS,
) {
    companion object {
        const val DEFAULT_WINDOW_NANOS = 1_000_000_000L

        /**
         * Bound on stored per-window render-interval samples used for the p95. A 1s window
         * at 60fps yields ~60 samples; anything past the bound still updates min/avg/max
         * (which need no storage) but is excluded from the p95 population.
         */
        private const val MAX_INTERVAL_SAMPLES = 128
    }

    // ── Totals (control thread writes; any thread may read) ────────────────

    @Volatile
    var totalRenderedFrames: Long = 0L
        private set

    @Volatile
    var totalCatchUpDroppedFrames: Long = 0L
        private set

    /** Last queue-overflow total observed via [onFrameTick]; the session owns the live counter. */
    @Volatile
    var totalQueueOverflowDroppedFrames: Long = 0L
        private set

    @Volatile
    var totalWindowsEmitted: Long = 0L
        private set

    // ── Window state (control thread only) ────────────────────────────────

    private var windowStartNanos = 0L
    private var lastRenderNanos = 0L
    private var windowTicks = 0
    private var windowRendered = 0
    private var windowCatchUpDrops = 0
    private var overflowAtWindowStart = 0L
    private var overflowStartCaptured = false

    private val intervalSamples = LongArray(MAX_INTERVAL_SAMPLES)
    private var intervalSampleCount = 0
    private var intervalCount = 0
    private var intervalMinNanos = Long.MAX_VALUE
    private var intervalMaxNanos = 0L
    private var intervalSumNanos = 0L

    private var queueDepthMin = Int.MAX_VALUE
    private var queueDepthMax = 0
    private var queueDepthSum = 0L
    private var deferredCloseMax = 0
    private var pumpMaxNanos = 0L
    private var pumpSumNanos = 0L

    /** Single reusable builder for the once-per-window log line. */
    private val line = StringBuilder(256)

    /** Clears both window aggregates and totals. Call when a session is (re)prepared. */
    fun resetAll() {
        resetWindow()
        totalRenderedFrames = 0L
        totalCatchUpDroppedFrames = 0L
        totalQueueOverflowDroppedFrames = 0L
        totalWindowsEmitted = 0L
    }

    /**
     * Clears window aggregates and the last-render anchor so the first interval measured
     * after a play/seek/restore boundary is not the gap across the pause. Totals persist.
     */
    fun resetWindow() {
        windowStartNanos = 0L
        lastRenderNanos = 0L
        overflowStartCaptured = false
        clearWindowAggregates()
    }

    private fun clearWindowAggregates() {
        windowTicks = 0
        windowRendered = 0
        windowCatchUpDrops = 0
        intervalSampleCount = 0
        intervalCount = 0
        intervalMinNanos = Long.MAX_VALUE
        intervalMaxNanos = 0L
        intervalSumNanos = 0L
        queueDepthMin = Int.MAX_VALUE
        queueDepthMax = 0
        queueDepthSum = 0L
        deferredCloseMax = 0
        pumpMaxNanos = 0L
        pumpSumNanos = 0L
    }

    /**
     * Records one playback-loop tick. Must be called from the playback control thread.
     *
     * @param nowNanos monotonic time (System.nanoTime) taken right after the pump returned;
     *   render intervals are measured between consecutive rendered ticks on this clock.
     * @param pumpDurationNanos wall time the pump call itself took on this tick.
     * @param renderedFrame whether this tick rendered a new frame.
     * @param catchUpDroppedFrames stale queued frames the pump dropped on this tick.
     * @param queueDepth imageQueue size observed after the pump.
     * @param deferredCloseInFlight rendered Images still awaiting their GPU release fence.
     * @param queueOverflowDropsTotal cumulative Images closed because imageQueue.offer failed.
     * @param generationId current DAG generation, echoed in the log line.
     */
    fun onFrameTick(
        nowNanos: Long,
        pumpDurationNanos: Long,
        renderedFrame: Boolean,
        catchUpDroppedFrames: Int,
        queueDepth: Int,
        deferredCloseInFlight: Int,
        queueOverflowDropsTotal: Long,
        generationId: Long,
    ) {
        if (windowStartNanos == 0L) {
            windowStartNanos = nowNanos
        }
        if (!overflowStartCaptured) {
            overflowAtWindowStart = queueOverflowDropsTotal
            overflowStartCaptured = true
        }
        totalQueueOverflowDroppedFrames = queueOverflowDropsTotal

        windowTicks++
        if (catchUpDroppedFrames > 0) {
            windowCatchUpDrops += catchUpDroppedFrames
            totalCatchUpDroppedFrames += catchUpDroppedFrames
        }
        if (queueDepth < queueDepthMin) queueDepthMin = queueDepth
        if (queueDepth > queueDepthMax) queueDepthMax = queueDepth
        queueDepthSum += queueDepth
        if (deferredCloseInFlight > deferredCloseMax) deferredCloseMax = deferredCloseInFlight
        if (pumpDurationNanos > pumpMaxNanos) pumpMaxNanos = pumpDurationNanos
        pumpSumNanos += pumpDurationNanos

        if (renderedFrame) {
            windowRendered++
            totalRenderedFrames++
            if (lastRenderNanos != 0L) {
                val interval = nowNanos - lastRenderNanos
                if (interval >= 0L) {
                    intervalCount++
                    if (interval < intervalMinNanos) intervalMinNanos = interval
                    if (interval > intervalMaxNanos) intervalMaxNanos = interval
                    intervalSumNanos += interval
                    if (intervalSampleCount < MAX_INTERVAL_SAMPLES) {
                        intervalSamples[intervalSampleCount++] = interval
                    }
                }
            }
            lastRenderNanos = nowNanos
        }

        val elapsed = nowNanos - windowStartNanos
        if (elapsed >= windowNanos) {
            emitWindow(elapsed, queueOverflowDropsTotal, generationId)
            // Roll the window over at this tick. lastRenderNanos is intentionally kept so
            // the interval across the boundary is still measured in the next window.
            windowStartNanos = nowNanos
            overflowAtWindowStart = queueOverflowDropsTotal
            clearWindowAggregates()
        }
    }

    private fun emitWindow(elapsedNanos: Long, queueOverflowDropsTotal: Long, generationId: Long) {
        totalWindowsEmitted++
        val sb = line
        sb.setLength(0)
        sb.append("CADENCE_1S gen=").append(generationId)
        sb.append(" winMs=")
        appendMs(sb, elapsedNanos)
        sb.append(" ticks=").append(windowTicks)
        sb.append(" rendered=").append(windowRendered)
        sb.append(" catchUpDrops=").append(windowCatchUpDrops)
        sb.append(" overflowDrops=").append(queueOverflowDropsTotal - overflowAtWindowStart)

        sb.append(" intervalMs[min/avg/p95/max]=")
        if (intervalCount == 0) {
            sb.append("-/-/-/-")
        } else {
            appendMs(sb, intervalMinNanos)
            sb.append('/')
            appendMs(sb, intervalSumNanos / intervalCount)
            sb.append('/')
            appendMs(sb, p95IntervalNanos())
            sb.append('/')
            appendMs(sb, intervalMaxNanos)
        }
        sb.append(" intervalN=").append(intervalCount)

        sb.append(" queueDepth[min/max/avg]=")
        if (windowTicks == 0) {
            sb.append("-/-/-")
        } else {
            sb.append(queueDepthMin).append('/').append(queueDepthMax).append('/')
            appendTenths(sb, (queueDepthSum * 10L) / windowTicks)
        }
        sb.append(" deferredCloseMax=").append(deferredCloseMax)

        sb.append(" pumpMs[avg/max]=")
        if (windowTicks == 0) {
            sb.append("-/-")
        } else {
            appendMs(sb, pumpSumNanos / windowTicks)
            sb.append('/')
            appendMs(sb, pumpMaxNanos)
        }

        sb.append(" | total rendered=").append(totalRenderedFrames)
        sb.append(" catchUpDrops=").append(totalCatchUpDroppedFrames)
        sb.append(" overflowDrops=").append(queueOverflowDropsTotal)
        sb.append(" windows=").append(totalWindowsEmitted)
        Log.d(tag, sb.toString())
    }

    /** Nearest-rank p95 over the stored samples; sorts the primitive prefix in place. */
    private fun p95IntervalNanos(): Long {
        val n = intervalSampleCount
        if (n == 0) return 0L
        Arrays.sort(intervalSamples, 0, n)
        val rank = ((n * 95 + 99) / 100) - 1
        return intervalSamples[rank.coerceIn(0, n - 1)]
    }

    /** Appends [nanos] as milliseconds with one decimal, e.g. 16.7, without String.format. */
    private fun appendMs(sb: StringBuilder, nanos: Long) {
        appendTenths(sb, (nanos + 50_000L) / 100_000L)
    }

    /** Appends a value expressed in tenths as `<whole>.<tenth>`. */
    private fun appendTenths(sb: StringBuilder, tenths: Long) {
        sb.append(tenths / 10).append('.').append(tenths % 10)
    }
}
