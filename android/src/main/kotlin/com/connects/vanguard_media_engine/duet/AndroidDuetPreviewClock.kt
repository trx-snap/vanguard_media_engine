package com.connects.vanguard_media_engine.duet

import kotlin.math.roundToInt

// ─────────────────────────────────────────────────────────────────────────────
// VG-DUET-SLICE-3: Android Duet preview clock, speed scaling & segment timeline
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Segment record with clock-derived source/output PTS ranges.
 */
data class VGDuetAndroidSegmentRecord(
    val index: Int,
    val durationMs: Int,
    val speedMultiplier: Double,
    val sourceStartMs: Int,
    val sourceEndMs: Int,
    val outputStartMs: Int,
    val outputEndMs: Int,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "segmentIndex"    to index,
        "durationMs"      to durationMs,
        "speedMultiplier" to speedMultiplier,
        "sourceStartMs"   to sourceStartMs,
        "sourceEndMs"     to sourceEndMs,
        "outputStartMs"   to outputStartMs,
        "outputEndMs"     to outputEndMs,
    )
}

/**
 * Owns all Duet preview clock and recording timing math:
 * - trimStart/trimEnd boundary enforcement.
 * - Speed multiplier scaling: speed-scaled progression T_out = S * T_wall with source/video PTS advancing in lockstep with output.
 * - Segment cursors (sourceStart/sourceEnd in absolute source PTS ms; outputStart/outputEnd in composition ms).
 * - Rollback on deleteLastSegment.
 * - Auto-stop threshold when source cursor reaches trimEndMs.
 */
class AndroidDuetPreviewClock(
    val trimStartMs: Int,
    val trimEndMs: Int,
    initialSpeed: Double,
) {
    var speedMultiplier: Double = initialSpeed
        private set

    var sourceCursorMs: Int = trimStartMs
        private set

    var outputCursorMs: Int = 0
        private set

    private val segmentsList = mutableListOf<VGDuetAndroidSegmentRecord>()
    val segments: List<VGDuetAndroidSegmentRecord> get() = segmentsList

    private var isRecording: Boolean = false
    private var segmentStartWallMs: Long = 0L
    private var activeSpeedMultiplier: Double = 1.0
    private var activeSourceStartMs: Int = 0
    private var activeOutputStartMs: Int = 0

    var isAutoStopped: Boolean = false
        private set

    val isRecordingActive: Boolean get() = isRecording

    fun setSpeed(speed: Double) {
        this.speedMultiplier = speed
    }

    fun startSegment() {
        if (isRecording || isAutoStopped) return
        isRecording = true
        segmentStartWallMs = System.currentTimeMillis()
        activeSpeedMultiplier = speedMultiplier
        activeSourceStartMs = sourceCursorMs
        activeOutputStartMs = outputCursorMs
    }

    fun commitSegment(wallTimestampMs: Long? = null): VGDuetAndroidSegmentRecord? {
        if (!isRecording) return null
        isRecording = false

        val nowMs = wallTimestampMs ?: System.currentTimeMillis()
        val elapsedWallMs = maxOf(1, (nowMs - segmentStartWallMs).toInt())

        // Timing math:
        // Speed-scaled progression: T_out = S * T_wall, and source/video PTS advances in lockstep with output.
        val nominalProgressionMs = maxOf(1, (elapsedWallMs * activeSpeedMultiplier).roundToInt())
        val maxAvailableSourceMs = maxOf(0, trimEndMs - activeSourceStartMs)

        val actualSourceDurationMs: Int
        val actualOutputDurationMs: Int

        if (nominalProgressionMs >= maxAvailableSourceMs) {
            actualSourceDurationMs = maxAvailableSourceMs
            actualOutputDurationMs = maxAvailableSourceMs
            isAutoStopped = true
        } else {
            actualSourceDurationMs = nominalProgressionMs
            actualOutputDurationMs = nominalProgressionMs
        }

        val segSourceEnd = activeSourceStartMs + actualSourceDurationMs
        val segOutputEnd = activeOutputStartMs + actualOutputDurationMs

        val record = VGDuetAndroidSegmentRecord(
            index           = segmentsList.size,
            durationMs      = actualOutputDurationMs,
            speedMultiplier = activeSpeedMultiplier,
            sourceStartMs   = activeSourceStartMs,
            sourceEndMs     = segSourceEnd,
            outputStartMs   = activeOutputStartMs,
            outputEndMs     = segOutputEnd,
        )
        segmentsList.add(record)

        sourceCursorMs = segSourceEnd
        outputCursorMs = segOutputEnd

        if (sourceCursorMs >= trimEndMs) {
            isAutoStopped = true
        }

        return record
    }

    fun deleteLastSegment(): Boolean {
        if (isRecording) {
            isRecording = false
        }
        if (segmentsList.isEmpty()) return false
        val removed = segmentsList.removeAt(segmentsList.size - 1)
        outputCursorMs = removed.outputStartMs
        sourceCursorMs = removed.sourceStartMs
        isAutoStopped = false
        return true
    }

    fun currentSourcePtsMs(): Int {
        if (!isRecording) return sourceCursorMs
        val nowMs = System.currentTimeMillis()
        val elapsedWallMs = maxOf(0, (nowMs - segmentStartWallMs).toInt())
        val sourceElapsedMs = (elapsedWallMs * activeSpeedMultiplier).roundToInt()
        return minOf(trimEndMs, activeSourceStartMs + sourceElapsedMs)
    }

    fun currentOutputPtsMs(): Int {
        if (!isRecording) return outputCursorMs
        val nowMs = System.currentTimeMillis()
        val elapsedWallMs = maxOf(0, (nowMs - segmentStartWallMs).toInt())
        val outputElapsedMs = (elapsedWallMs * activeSpeedMultiplier).roundToInt()
        val maxAvailableSourceMs = maxOf(0, trimEndMs - activeSourceStartMs)
        return activeOutputStartMs + minOf(outputElapsedMs, maxAvailableSourceMs)
    }

    fun totalDurationMs(): Int = outputCursorMs
    fun segmentCount(): Int = segmentsList.size
}
