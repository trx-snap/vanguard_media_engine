// VGDuetPreviewClock.swift
// VG-DUET-SLICE-3: Duet preview clock, speed scaling & segment timeline math.
//
// Responsibilities:
//   - Owns all timing math: trimStart/trimEnd, speed scaling, pause hold,
//     segment cursor, rollback delete-last-segment, and auto-stop threshold.
//   - Replaces wall-clock segment cursor math with clock-derived source/output ranges.
//   - Segment sourceStart/sourceEnd are absolute source PTS ms from the asset trim window.
//   - Segment outputStart/outputEnd are composition timeline ms starting at 0.
//   - Auto-stop: observes trim end; marks terminal auto-stopped state.

import Foundation

// MARK: - Segment record (clock-derived source/output PTS)

struct VGDuetSegmentRecord {
    let index: Int
    let durationMs: Int
    let speedMultiplier: Double
    let sourceStartMs: Int
    let sourceEndMs: Int
    let outputStartMs: Int
    let outputEndMs: Int

    func toMap() -> [String: Any] {
        return [
            "segmentIndex":     index,
            "durationMs":       durationMs,
            "speedMultiplier":  speedMultiplier,
            "sourceStartMs":    sourceStartMs,
            "sourceEndMs":      sourceEndMs,
            "outputStartMs":    outputStartMs,
            "outputEndMs":      outputEndMs,
        ]
    }
}

// MARK: - Preview clock

final class VGDuetPreviewClock {

    let trimStartMs: Int
    let trimEndMs: Int

    private(set) var speedMultiplier: Double
    private(set) var sourceCursorMs: Int
    private(set) var outputCursorMs: Int
    private(set) var segments: [VGDuetSegmentRecord] = []

    // Active segment tracking
    private var isRecording: Bool = false
    private var segmentStartWallMs: Int64 = 0
    private var activeSpeedMultiplier: Double = 1.0
    private var activeSourceStartMs: Int = 0
    private var activeOutputStartMs: Int = 0

    private(set) var isAutoStopped: Bool = false

    var isRecordingActive: Bool { isRecording }

    init(trimStartMs: Int, trimEndMs: Int, initialSpeed: Double) {
        self.trimStartMs = trimStartMs
        self.trimEndMs = trimEndMs
        self.speedMultiplier = initialSpeed
        self.sourceCursorMs = trimStartMs
        self.outputCursorMs = 0
    }

    func setSpeed(_ speed: Double) {
        self.speedMultiplier = speed
    }

    func startSegment() {
        guard !isRecording && !isAutoStopped else { return }
        isRecording = true
        segmentStartWallMs = Int64(Date().timeIntervalSince1970 * 1000)
        activeSpeedMultiplier = speedMultiplier
        activeSourceStartMs = sourceCursorMs
        activeOutputStartMs = outputCursorMs
    }

    @discardableResult
    func commitSegment(at wallTimestampMs: Int64? = nil) -> VGDuetSegmentRecord? {
        guard isRecording else { return nil }
        isRecording = false

        let nowMs = wallTimestampMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let elapsedWallMs = max(1, Int(nowMs - segmentStartWallMs))

        // Timing math:
        // Speed-scaled progression: T_out = S * T_wall, and source/video PTS advances in lockstep with output.
        let nominalProgressionMs = max(1, Int(round(Double(elapsedWallMs) * activeSpeedMultiplier)))
        let maxAvailableSourceMs = max(0, trimEndMs - activeSourceStartMs)

        let actualSourceDurationMs: Int
        let actualOutputDurationMs: Int

        if nominalProgressionMs >= maxAvailableSourceMs {
            actualSourceDurationMs = maxAvailableSourceMs
            actualOutputDurationMs = maxAvailableSourceMs
            isAutoStopped = true
        } else {
            actualSourceDurationMs = nominalProgressionMs
            actualOutputDurationMs = nominalProgressionMs
        }

        let segSourceEnd = activeSourceStartMs + actualSourceDurationMs
        let segOutputEnd = activeOutputStartMs + actualOutputDurationMs

        let record = VGDuetSegmentRecord(
            index:           segments.count,
            durationMs:      actualOutputDurationMs,
            speedMultiplier: activeSpeedMultiplier,
            sourceStartMs:   activeSourceStartMs,
            sourceEndMs:     segSourceEnd,
            outputStartMs:   activeOutputStartMs,
            outputEndMs:     segOutputEnd
        )
        segments.append(record)

        sourceCursorMs = segSourceEnd
        outputCursorMs = segOutputEnd

        if sourceCursorMs >= trimEndMs {
            isAutoStopped = true
        }

        return record
    }

    @discardableResult
    func deleteLastSegment() -> Bool {
        if isRecording {
            isRecording = false
        }
        guard !segments.isEmpty else { return false }
        let removed = segments.removeLast()
        outputCursorMs = removed.outputStartMs
        sourceCursorMs = removed.sourceStartMs
        isAutoStopped = false
        return true
    }

    func currentSourcePtsMs() -> Int {
        if !isRecording {
            return sourceCursorMs
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let elapsedWallMs = max(0, Int(nowMs - segmentStartWallMs))
        let progressionMs = Int(round(Double(elapsedWallMs) * activeSpeedMultiplier))
        return min(trimEndMs, activeSourceStartMs + progressionMs)
    }

    func currentOutputPtsMs() -> Int {
        if !isRecording {
            return outputCursorMs
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let elapsedWallMs = max(0, Int(nowMs - segmentStartWallMs))
        let outputElapsedMs = Int(round(Double(elapsedWallMs) * activeSpeedMultiplier))
        let maxAvailableSourceMs = max(0, trimEndMs - activeSourceStartMs)
        return activeOutputStartMs + min(outputElapsedMs, maxAvailableSourceMs)
    }

    func totalDurationMs() -> Int { outputCursorMs }
    func segmentCount() -> Int { segments.count }
}
