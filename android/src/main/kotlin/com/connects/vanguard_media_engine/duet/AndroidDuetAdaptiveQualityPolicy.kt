package com.connects.vanguard_media_engine.duet

import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.util.Log

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Adaptive quality-tier policy for the green-screen
// analyzer (AndroidDuetGreenScreenAdapter).
// -----------------------------------------------------------------------------
//
// Owns three independent, thread-safe concerns for the fixed 256x256
// CameraX analysis stream (resolution/analyzer are never touched here):
//   - Pacing: a min-interval gate per [DuetSegmentationQuality] tier that the
//     adapter applies before it commits to processing a frame.
//   - Thermal adaptation: reads PowerManager.currentThermalStatus (API 29+)
//     and maps it onto the nominal/fair/serious/critical tiers used by the
//     rest of the Duet thermal contract.
//   - Inference-budget monitoring: persistent (not single-spike) over-budget
//     tracking per tier, used to request a tier downshift or, once SURVIVAL
//     is itself persistently over budget, a backend-ladder degrade.
//
// The quality tier only ever moves down (QUALITY -> BALANCED -> SURVIVAL),
// mirroring the one-way backend-ladder latch in the adapter; there is no
// automatic recovery back to a higher tier within one policy instance.
// [reset] clears accepted-frame pacing state and inference counters only —
// it does not raise the tier back up.

class AndroidDuetAdaptiveQualityPolicy(context: Context?) {

    companion object {
        private const val TAG = "DuetAdaptiveQuality"

        const val REASON_THERMAL_THROTTLING = "thermal_throttling"
        const val REASON_INFERENCE_TIMEOUT = "inference_timeout"

        private const val QUALITY_MIN_INTERVAL_MS = 0L
        private const val BALANCED_MIN_INTERVAL_MS = 45L
        private const val SURVIVAL_MIN_INTERVAL_MS = 66L

        private const val QUALITY_TARGET_FPS = 30
        private const val BALANCED_TARGET_FPS = 22
        private const val SURVIVAL_TARGET_FPS = 15

        private const val QUALITY_BUDGET_MS = 35L
        private const val BALANCED_BUDGET_MS = 50L
        private const val SURVIVAL_BUDGET_MS = 150L

        /** Consecutive over-budget samples required before a tier reacts; guards against one spike. */
        private const val OVER_BUDGET_STREAK_THRESHOLD = 3

        const val THERMAL_TIER_NOMINAL = "nominal"
        const val THERMAL_TIER_FAIR = "fair"
        const val THERMAL_TIER_SERIOUS = "serious"
        const val THERMAL_TIER_CRITICAL = "critical"

        fun minIntervalMs(quality: DuetSegmentationQuality): Long = when (quality) {
            DuetSegmentationQuality.QUALITY -> QUALITY_MIN_INTERVAL_MS
            DuetSegmentationQuality.BALANCED -> BALANCED_MIN_INTERVAL_MS
            DuetSegmentationQuality.SURVIVAL -> SURVIVAL_MIN_INTERVAL_MS
        }

        fun targetFps(quality: DuetSegmentationQuality): Int = when (quality) {
            DuetSegmentationQuality.QUALITY -> QUALITY_TARGET_FPS
            DuetSegmentationQuality.BALANCED -> BALANCED_TARGET_FPS
            DuetSegmentationQuality.SURVIVAL -> SURVIVAL_TARGET_FPS
        }

        private fun mapThermalTier(status: Int?): String = when (status) {
            PowerManager.THERMAL_STATUS_NONE -> THERMAL_TIER_NOMINAL
            PowerManager.THERMAL_STATUS_LIGHT -> THERMAL_TIER_FAIR
            PowerManager.THERMAL_STATUS_MODERATE,
            PowerManager.THERMAL_STATUS_SEVERE -> THERMAL_TIER_SERIOUS
            PowerManager.THERMAL_STATUS_CRITICAL,
            PowerManager.THERMAL_STATUS_EMERGENCY,
            PowerManager.THERMAL_STATUS_SHUTDOWN -> THERMAL_TIER_CRITICAL
            else -> THERMAL_TIER_NOMINAL
        }
    }

    /** A policy-triggered request to move the backend ladder down via the adapter's existing failure path. */
    data class DegradeRequest(val reason: String)

    private val powerManager: PowerManager? =
        (context?.applicationContext ?: context)?.getSystemService(Context.POWER_SERVICE) as? PowerManager

    private val lock = Any()

    private var quality: DuetSegmentationQuality = DuetSegmentationQuality.QUALITY
    private var lastAcceptedTimestampMs: Long? = null
    private var lastThermalTier: String = THERMAL_TIER_NOMINAL
    private var qualityOverBudgetStreak = 0
    private var balancedOverBudgetStreak = 0
    private var survivalOverBudgetStreak = 0
    private var loggedFirstTier = false

    /** Current quality tier; only ever moves down for the lifetime of this policy instance. */
    val currentQuality: DuetSegmentationQuality get() = synchronized(lock) { quality }

    /** Last OS thermal tier observed by [evaluateThermal] (nominal until first evaluated). */
    val currentThermalTier: String get() = synchronized(lock) { lastThermalTier }

    /**
     * Pacing gate: true when [timestampMs] (camera clock, ms) is far enough past
     * the last accepted frame for the current tier's min interval. Accepts the
     * first frame unconditionally. Non-increasing timestamps are treated as
     * zero elapsed time (never negative), so they are paced like any other
     * too-soon frame rather than causing incorrect acceptance.
     */
    fun shouldProcessFrame(timestampMs: Long): Boolean = synchronized(lock) {
        logFirstTierLocked()
        val last = lastAcceptedTimestampMs
        if (last == null) {
            lastAcceptedTimestampMs = timestampMs
            return@synchronized true
        }
        val elapsed = (timestampMs - last).coerceAtLeast(0L)
        val minInterval = minIntervalMs(quality)
        if (elapsed < minInterval) return@synchronized false
        lastAcceptedTimestampMs = timestampMs
        true
    }

    /**
     * Queries PowerManager.currentThermalStatus (API 29+; null/unknown below
     * that or when unavailable, which maps to nominal). `serious` downshifts
     * the tier to SURVIVAL directly; `critical`/`emergency`/`shutdown` request
     * a backend-ladder degrade via [REASON_THERMAL_THROTTLING].
     */
    fun evaluateThermal(): DegradeRequest? = synchronized(lock) {
        when (refreshThermalTierLocked()) {
            THERMAL_TIER_SERIOUS -> {
                downshiftLocked(DuetSegmentationQuality.SURVIVAL, "thermal_serious")
                null
            }
            THERMAL_TIER_CRITICAL -> DegradeRequest(REASON_THERMAL_THROTTLING)
            else -> null
        }
    }

    /**
     * Records one segment() duration sample for the tier active when the frame
     * was dispatched. A tier only reacts after [OVER_BUDGET_STREAK_THRESHOLD]
     * consecutive over-budget samples, so a single spike is ignored. QUALITY
     * and BALANCED downshift the tier in place; SURVIVAL requests a
     * backend-ladder degrade via [REASON_INFERENCE_TIMEOUT] since there is no
     * lower quality tier to fall back to.
     */
    fun recordInferenceDuration(durationMs: Long): DegradeRequest? = synchronized(lock) {
        when (quality) {
            DuetSegmentationQuality.QUALITY -> {
                qualityOverBudgetStreak = streakFor(durationMs, QUALITY_BUDGET_MS, qualityOverBudgetStreak)
                if (qualityOverBudgetStreak >= OVER_BUDGET_STREAK_THRESHOLD) {
                    downshiftLocked(DuetSegmentationQuality.BALANCED, "inference_budget_quality")
                }
                null
            }
            DuetSegmentationQuality.BALANCED -> {
                balancedOverBudgetStreak = streakFor(durationMs, BALANCED_BUDGET_MS, balancedOverBudgetStreak)
                if (balancedOverBudgetStreak >= OVER_BUDGET_STREAK_THRESHOLD) {
                    downshiftLocked(DuetSegmentationQuality.SURVIVAL, "inference_budget_balanced")
                }
                null
            }
            DuetSegmentationQuality.SURVIVAL -> {
                survivalOverBudgetStreak = streakFor(durationMs, SURVIVAL_BUDGET_MS, survivalOverBudgetStreak)
                if (survivalOverBudgetStreak >= OVER_BUDGET_STREAK_THRESHOLD) {
                    survivalOverBudgetStreak = 0
                    DegradeRequest(REASON_INFERENCE_TIMEOUT)
                } else {
                    null
                }
            }
        }
    }

    /** Clears accepted-frame pacing state and inference-budget counters. Does not raise the tier. */
    fun reset() = synchronized(lock) {
        lastAcceptedTimestampMs = null
        qualityOverBudgetStreak = 0
        balancedOverBudgetStreak = 0
        survivalOverBudgetStreak = 0
    }

    private fun streakFor(durationMs: Long, budgetMs: Long, current: Int): Int =
        if (durationMs > budgetMs) current + 1 else 0

    private fun downshiftLocked(target: DuetSegmentationQuality, cause: String) {
        if (target.ordinal <= quality.ordinal) return
        val previous = quality
        quality = target
        qualityOverBudgetStreak = 0
        balancedOverBudgetStreak = 0
        Log.i(
            TAG,
            "ANDROID_DUET_GREENSCREEN_ADAPTIVE_TIER_CHANGED from=${previous.key} to=${target.key} " +
                "cause=$cause targetFps=${targetFps(target)} minIntervalMs=${minIntervalMs(target)}",
        )
    }

    /**
     * Refreshes and emits the first-use marker exactly once. Queries the live
     * thermal tier before logging so the marker reflects the OS's actual state
     * rather than the nominal default: a live `serious` tier downshifts to
     * SURVIVAL first so tier/targetFps/minIntervalMs stay consistent, and a
     * live `critical` tier is reported as such (the degrade/fallback request
     * itself is still issued by [evaluateThermal] on this same frame).
     */
    private fun logFirstTierLocked() {
        if (loggedFirstTier) return
        loggedFirstTier = true
        if (refreshThermalTierLocked() == THERMAL_TIER_SERIOUS) {
            downshiftLocked(DuetSegmentationQuality.SURVIVAL, "thermal_serious")
        }
        Log.i(
            TAG,
            "ANDROID_DUET_GREENSCREEN_ADAPTIVE_TIER_FIRST tier=${quality.key} " +
                "targetFps=${targetFps(quality)} minIntervalMs=${minIntervalMs(quality)} " +
                "thermalTier=$lastThermalTier",
        )
    }

    private fun refreshThermalTierLocked(): String {
        val tier = mapThermalTier(queryThermalStatusLocked())
        if (tier != lastThermalTier) {
            Log.i(TAG, "thermal tier changed: ${lastThermalTier} -> $tier")
        }
        lastThermalTier = tier
        return tier
    }

    private fun queryThermalStatusLocked(): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val pm = powerManager ?: return null
        return try {
            pm.currentThermalStatus
        } catch (t: Throwable) {
            Log.w(TAG, "currentThermalStatus failed: ${t.javaClass.simpleName}: ${t.message}")
            null
        }
    }
}
