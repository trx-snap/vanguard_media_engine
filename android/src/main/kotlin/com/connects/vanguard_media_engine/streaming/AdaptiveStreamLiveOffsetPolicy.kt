package com.connects.vanguard_media_engine.streaming

import kotlin.math.abs

/**
 * Vanguard Android True-DAG Phase 4C4F: Adaptive stream live-offset speed policy.
 *
 * Models Android Media3 live streaming speed adjustment principles (target, min, max live offsets
 * and min/max playback speeds) strictly as deterministic metadata policy.
 *
 * ## Verification Invariants
 * - **Metadata Only**: No Android UI, no Media3 / ExoPlayer imports, no network I/O, no buffers.
 * - **Deterministic Evaluation**: Pure mathematical policy mapping live offset (ms) to playback speed.
 * - **Zero Frame Retention**: Operates solely on numeric offsets without touching or holding frames.
 */
enum class AdaptiveStreamSpeedDecisionStatus {
    HOLD,
    SPEED_UP,
    SLOW_DOWN,
    REBUFFER_MARGIN,
    FAILED,
}

data class AdaptiveStreamSpeedDecision(
    val status: AdaptiveStreamSpeedDecisionStatus,
    val recommendedSpeed: Double,
    val raw: String,
    val retryable: Boolean = false,
) {
    val pass: Boolean
        get() = status != AdaptiveStreamSpeedDecisionStatus.FAILED
}

class AdaptiveStreamLiveOffsetPolicy(
    val targetLiveOffsetMs: Long = 3_000L,
    val minLiveOffsetMs: Long = 1_500L,
    val maxLiveOffsetMs: Long = 6_000L,
    val minPlaybackSpeed: Double = 0.97,
    val maxPlaybackSpeed: Double = 1.03,
    val targetToleranceMs: Long = 250L,
) {
    init {
        require(minLiveOffsetMs >= 0L) {
            "minLiveOffsetMs must be >= 0, got $minLiveOffsetMs"
        }
        require(targetLiveOffsetMs >= minLiveOffsetMs) {
            "targetLiveOffsetMs ($targetLiveOffsetMs) must be >= minLiveOffsetMs ($minLiveOffsetMs)"
        }
        require(maxLiveOffsetMs >= targetLiveOffsetMs) {
            "maxLiveOffsetMs ($maxLiveOffsetMs) must be >= targetLiveOffsetMs ($targetLiveOffsetMs)"
        }
        require(minPlaybackSpeed > 0.0) {
            "minPlaybackSpeed must be > 0, got $minPlaybackSpeed"
        }
        require(maxPlaybackSpeed > 0.0) {
            "maxPlaybackSpeed must be > 0, got $maxPlaybackSpeed"
        }
        require(minPlaybackSpeed <= 1.0) {
            "minPlaybackSpeed must be <= 1.0, got $minPlaybackSpeed"
        }
        require(maxPlaybackSpeed >= 1.0) {
            "maxPlaybackSpeed must be >= 1.0, got $maxPlaybackSpeed"
        }
        require(targetToleranceMs >= 0L) {
            "targetToleranceMs must be >= 0, got $targetToleranceMs"
        }
    }

    /**
     * Evaluates the recommended playback speed adjustment given the current live offset in milliseconds.
     *
     * @param currentLiveOffsetMs Current live offset in milliseconds. Negative values are invalid and yield FAILED.
     * @param rebuffered True if playback recently rebuffered, forcing REBUFFER_MARGIN slow-down.
     * @return [AdaptiveStreamSpeedDecision] containing the decision status, recommended speed, and diagnostic raw string.
     */
    fun evaluate(currentLiveOffsetMs: Long, rebuffered: Boolean = false): AdaptiveStreamSpeedDecision {
        if (currentLiveOffsetMs < 0L) {
            return AdaptiveStreamSpeedDecision(
                status = AdaptiveStreamSpeedDecisionStatus.FAILED,
                recommendedSpeed = 1.0,
                raw = "status=FAILED;reason=negative_live_offset;currentLiveOffsetMs=$currentLiveOffsetMs",
                retryable = false,
            )
        }

        if (rebuffered) {
            return AdaptiveStreamSpeedDecision(
                status = AdaptiveStreamSpeedDecisionStatus.REBUFFER_MARGIN,
                recommendedSpeed = minPlaybackSpeed,
                raw = "status=REBUFFER_MARGIN;reason=rebuffered;currentLiveOffsetMs=$currentLiveOffsetMs;recommendedSpeed=$minPlaybackSpeed",
                retryable = false,
            )
        }

        if (currentLiveOffsetMs < minLiveOffsetMs) {
            return AdaptiveStreamSpeedDecision(
                status = AdaptiveStreamSpeedDecisionStatus.SLOW_DOWN,
                recommendedSpeed = minPlaybackSpeed,
                raw = "status=SLOW_DOWN;reason=below_min_live_offset;currentLiveOffsetMs=$currentLiveOffsetMs;recommendedSpeed=$minPlaybackSpeed",
                retryable = false,
            )
        }

        if (currentLiveOffsetMs > maxLiveOffsetMs) {
            return AdaptiveStreamSpeedDecision(
                status = AdaptiveStreamSpeedDecisionStatus.SPEED_UP,
                recommendedSpeed = maxPlaybackSpeed,
                raw = "status=SPEED_UP;reason=above_max_live_offset;currentLiveOffsetMs=$currentLiveOffsetMs;recommendedSpeed=$maxPlaybackSpeed",
                retryable = false,
            )
        }

        // Within target tolerance window -> HOLD at 1.0 speed
        if (abs(currentLiveOffsetMs - targetLiveOffsetMs) <= targetToleranceMs) {
            return AdaptiveStreamSpeedDecision(
                status = AdaptiveStreamSpeedDecisionStatus.HOLD,
                recommendedSpeed = 1.0,
                raw = "status=HOLD;reason=near_target;currentLiveOffsetMs=$currentLiveOffsetMs;recommendedSpeed=1.0",
                retryable = false,
            )
        }

        // Below target but >= minLiveOffsetMs -> SLOW_DOWN proportionally
        if (currentLiveOffsetMs < targetLiveOffsetMs) {
            val lowerBound = minLiveOffsetMs
            val upperBound = targetLiveOffsetMs - targetToleranceMs
            val range = (upperBound - lowerBound).coerceAtLeast(1L).toDouble()
            val progress = (currentLiveOffsetMs - lowerBound).toDouble() / range
            val speed = minPlaybackSpeed + progress.coerceIn(0.0, 1.0) * (1.0 - minPlaybackSpeed)
            return AdaptiveStreamSpeedDecision(
                status = AdaptiveStreamSpeedDecisionStatus.SLOW_DOWN,
                recommendedSpeed = speed,
                raw = "status=SLOW_DOWN;reason=below_target;currentLiveOffsetMs=$currentLiveOffsetMs;recommendedSpeed=$speed",
                retryable = false,
            )
        }

        // Above target but <= maxLiveOffsetMs -> SPEED_UP proportionally
        val lowerBound = targetLiveOffsetMs + targetToleranceMs
        val upperBound = maxLiveOffsetMs
        val range = (upperBound - lowerBound).coerceAtLeast(1L).toDouble()
        val progress = (currentLiveOffsetMs - lowerBound).toDouble() / range
        val speed = 1.0 + progress.coerceIn(0.0, 1.0) * (maxPlaybackSpeed - 1.0)
        return AdaptiveStreamSpeedDecision(
            status = AdaptiveStreamSpeedDecisionStatus.SPEED_UP,
            recommendedSpeed = speed,
            raw = "status=SPEED_UP;reason=above_target;currentLiveOffsetMs=$currentLiveOffsetMs;recommendedSpeed=$speed",
            retryable = false,
        )
    }
}
