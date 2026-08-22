package com.connects.vanguard_media_engine.rtc

/**
 * Video-only presentation timestamp (PTS) to real-time transport (RTC) timestamp mapper.
 *
 * Maps source video frame presentation timestamps in microseconds ([ptsUs]) to strictly monotonic
 * RTC presentation timestamps in nanoseconds ([timestampNs]) anchored to a baseline reference clock.
 *
 * ## Video-Only Domain Invariants
 * - **Video-Only Scope**: Operates strictly within the video domain. This mapper has zero ownership,
 *   awareness, or integration with audio clocks, room/session clocks, or network transport clocks.
 * - **No Audio / Room Coupling**: RTC audio and room management remain strictly outside Vanguard.
 * - **No A/V Sync Claim**: This class does NOT provide audio-video synchronization or lip-sync guarantees.
 *   Audio-video synchronization (A/V sync) belongs outside this video-only mapper (e.g. in WebRTC RTCP SR
 *   sender reports or host application session synchronizers) unless future product requirements explicitly mandate it.
 * - **Strict Monotonicity**: Preserves WebRTC monotonic timestamp invariants by enforcing that every emitted
 *   timestamp is strictly greater than the preceding timestamp (`timestampNs > lastTimestampNs`). If source
 *   video PTS contains duplicates, jitter, or out-of-order frames, the mapper coerces the timestamp to
 *   `lastTimestampNs + 1` and increments the non-monotonic correction counter.
 * - **Thread-Safe**: All public methods are synchronized for safe concurrent access.
 *
 * @param baseTimestampNs Initial baseline reference timestamp in nanoseconds (defaults to [System.nanoTime]).
 */
class RtcVideoTimestampMapper(
    private var baseTimestampNs: Long = System.nanoTime(),
) {
    private var basePtsUs: Long? = null
    private var lastTimestampNs: Long = -1L
    private var mappedFrames: Long = 0L
    private var droppedNonMonotonicCorrections: Long = 0L

    init {
        require(baseTimestampNs >= 0L) {
            "RtcVideoTimestampMapper: baseTimestampNs must be non-negative, got $baseTimestampNs"
        }
    }

    /**
     * Maps a source video frame presentation timestamp in microseconds ([ptsUs]) to a strictly
     * monotonic RTC timestamp in nanoseconds.
     *
     * @param ptsUs Source video PTS in microseconds (must be >= 0).
     * @return Strictly monotonic RTC timestamp in nanoseconds.
     * @throws IllegalArgumentException If [ptsUs] is negative.
     */
    @Synchronized
    fun mapPtsUs(ptsUs: Long): Long {
        require(ptsUs >= 0L) {
            "RtcVideoTimestampMapper: ptsUs must be non-negative, got $ptsUs"
        }

        var computed: Long
        val currentBasePtsUs = basePtsUs
        if (currentBasePtsUs == null) {
            basePtsUs = ptsUs
            computed = baseTimestampNs
        } else {
            val deltaUs = ptsUs - currentBasePtsUs
            computed = if (deltaUs >= 0L) {
                val deltaNs = try {
                    Math.multiplyExact(deltaUs, 1000L)
                } catch (_: ArithmeticException) {
                    Long.MAX_VALUE
                }
                try {
                    Math.addExact(baseTimestampNs, deltaNs)
                } catch (_: ArithmeticException) {
                    Long.MAX_VALUE
                }
            } else {
                val deltaNs = try {
                    Math.multiplyExact(deltaUs, 1000L)
                } catch (_: ArithmeticException) {
                    Long.MIN_VALUE
                }
                try {
                    Math.addExact(baseTimestampNs, deltaNs)
                } catch (_: ArithmeticException) {
                    0L
                }
            }
        }

        if (computed <= lastTimestampNs) {
            computed = if (lastTimestampNs < Long.MAX_VALUE) {
                lastTimestampNs + 1L
            } else {
                Long.MAX_VALUE
            }
            droppedNonMonotonicCorrections++
        }

        lastTimestampNs = computed
        mappedFrames++
        return computed
    }

    /**
     * Resets the mapper baseline timestamp to [newBaseTimestampNs] and clears the initial PTS anchor.
     *
     * Preserves [lastTimestampNs] to guarantee strict monotonicity even across baseline resets.
     *
     * @param newBaseTimestampNs New baseline reference timestamp in nanoseconds (must be >= 0).
     * @return Map containing reset status and current telemetry snapshot.
     */
    @Synchronized
    fun reset(newBaseTimestampNs: Long = System.nanoTime()): Map<String, Any?> {
        require(newBaseTimestampNs >= 0L) {
            "RtcVideoTimestampMapper: newBaseTimestampNs must be non-negative, got $newBaseTimestampNs"
        }
        baseTimestampNs = newBaseTimestampNs
        basePtsUs = null
        return mapOf(
            "pass" to true,
            "baseTimestampNs" to baseTimestampNs,
            "lastTimestampNs" to lastTimestampNs,
            "mappedFrames" to mappedFrames,
            "droppedNonMonotonicCorrections" to droppedNonMonotonicCorrections,
            "raw" to "status=RESET;baseTimestampNs=$baseTimestampNs;lastTimestampNs=$lastTimestampNs",
        )
    }

    /**
     * Returns an immutable snapshot map of current mapper state and telemetry counters.
     */
    @Synchronized
    fun snapshot(): Map<String, Any?> = mapOf(
        "baseTimestampNs" to baseTimestampNs,
        "basePtsUs" to basePtsUs,
        "lastTimestampNs" to lastTimestampNs,
        "mappedFrames" to mappedFrames,
        "droppedNonMonotonicCorrections" to droppedNonMonotonicCorrections,
    )
}
