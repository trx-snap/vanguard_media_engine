// VGHLSRatePolicy.swift
// Pure decision policy for the Debug-only LOW_LATENCY playback-rate experiment.
//
// Decides, from one measurement per tick, whether an already playing live session
// should run at the accelerated rate (1.08x) or the normal rate (1.00x) so that
// the age of the player head (sample wall time minus the playlist's
// EXT-X-PROGRAM-DATE-TIME at the playhead) settles at an experimental target.
// The age is an objective only: it is not a verified distance to the true live
// edge, and its absolute value is only as good as the publisher and device
// wall-clock sync.
//
// Foundation only. No AVFoundation, timers, logging or threading: the policy is a
// value type that VGHLSRateController drives on the main thread and that a
// harness can drive with synthetic samples. The policy never performs a write: it
// returns a decision, and its mode moves only when the controller confirms that
// the corresponding rate write was applied (didEnterAccelerated /
// didExitAccelerated) or declined (didDeclineEntry).
//
// Acceleration only. There is no deceleration, no integral term, no seek, and no
// knowledge of seekable ranges, recommended live offsets or buffer caps.

import Foundation

/// Experimental constants. Every value is a tuning choice, not a measured fact.
struct VGHLSRatePolicyConfig {
    let normalRate:                  Float
    let acceleratedRate:             Float
    /// Filtered age at or under which acceleration ends (normal exit).
    let targetAgeMs:                 Int
    /// Filtered age at or over which an entry tick is counted.
    let entryAgeMs:                  Int
    /// Valid samples whose median is the filtered age.
    let medianWindow:                Int
    /// Consecutive ticks at or over entryAgeMs before acceleration may start.
    let entryConsecutiveTicks:       Int
    /// Continuous playing time, and quiet time after any safety exit, time jump or
    /// declined entry, required before acceleration may start.
    let settleSeconds:               Double
    /// Contiguous forward buffer required to enter acceleration.
    let entryBufferMs:               Int
    /// Contiguous forward buffer under which acceleration ends at once.
    let safetyBufferMs:              Int
    /// Minimum spacing between non-safety writes (entry and normal exit).
    let minimumWriteSpacingSeconds:  Double
    /// A valid age lies within [minValidAgeMs, maxValidAgeMs].
    let minValidAgeMs:               Int
    let maxValidAgeMs:               Int
    /// Wall-clock versus monotonic elapsed time disagreeing by more than this is a
    /// clock step.
    let clockStepToleranceSeconds:   Double
    /// Consecutive valid ages differing by more than this are a discontinuity.
    let discontinuityAgeDeltaMs:     Int

    static let experiment = VGHLSRatePolicyConfig(
        normalRate:                 1.00,
        acceleratedRate:            1.08,
        targetAgeMs:                1_500,
        entryAgeMs:                 1_600,
        medianWindow:               4,
        entryConsecutiveTicks:      4,
        settleSeconds:              2.0,
        entryBufferMs:              750,
        safetyBufferMs:             250,
        minimumWriteSpacingSeconds: 2.0,
        minValidAgeMs:              0,
        maxValidAgeMs:              30_000,
        clockStepToleranceSeconds:  0.25,
        discontinuityAgeDeltaMs:    1_000
    )
}

/// One measurement, taken by the controller immediately before a tick. Missing or
/// nonfinite measurements are nil; the policy treats them as invalid.
struct VGHLSRateSample {
    /// Monotonic seconds (CACurrentMediaTime) and wall seconds (Date) of the sample.
    let monotonicSeconds:          Double
    let wallSeconds:               Double
    /// Sample wall time minus AVPlayerItem.currentDate(), in ms; nil when unavailable.
    let ageMs:                     Int?
    /// Buffered media ahead of the playhead in the loaded range that contains it.
    let contiguousForwardBufferMs: Int?
    /// The player's current item is this item, the item is ready and nothing failed.
    let isReady:                   Bool
    let isFailed:                  Bool
    /// AVPlayer.timeControlStatus is .playing / .waitingToPlayAtSpecifiedRate.
    let isPlaying:                 Bool
    let isWaiting:                 Bool
    /// Cumulative AVPlayerItemPlaybackStalled count for the session.
    let stallCount:                Int
}

enum VGHLSRateMode: String {
    case normal
    case accelerating
    case disabled
}

/// What the controller should do after a tick or event. A write decision is a
/// request: the controller re-checks ownership, status and rate before writing.
enum VGHLSRateDecision: Equatable {
    case none
    /// Write the accelerated rate (requires an owned normal rate and .playing).
    case enterAccelerated
    /// Write the normal rate back over an owned accelerated rate. `safety` exits
    /// bypass filtering, dwell and write spacing.
    case exitAccelerated(reason: String, safety: Bool)
    /// Stop the experiment for the session without writing.
    case disable(reason: String)
}

struct VGHLSRatePolicy {

    let config: VGHLSRatePolicyConfig

    private(set) var mode:           VGHLSRateMode = .normal
    private(set) var disabledReason: String?       = nil

    // ── Filter and dwell state ─────────────────────────────────────────────────
    private var ageWindow:                [Int]   = []
    private var consecutiveEntryTicks:    Int     = 0
    private var playingSinceSeconds:      Double? = nil
    private var settleUntilSeconds:       Double? = nil
    private var lastNonSafetyWriteSeconds: Double? = nil

    // ── Previous-sample state for stall, clock-step and discontinuity checks ──
    private var lastStallCount:       Int?    = nil
    private var lastMonotonicSeconds: Double? = nil
    private var lastWallSeconds:      Double? = nil
    private var lastValidAgeMs:       Int?    = nil

    init(config: VGHLSRatePolicyConfig = .experiment) {
        self.config = config
    }

    var isDisabled: Bool { return mode == .disabled }

    /// Median of the valid-age window once it is full; nil before that.
    var filteredAgeMs: Int? {
        guard ageWindow.count == config.medianWindow, !ageWindow.isEmpty else { return nil }
        return Self.median(ageWindow)
    }

    // MARK: - Tick

    /// Evaluates one sample. Safety conditions are checked on the raw sample and
    /// act at once; the filtered age and dwell rules apply only after them.
    mutating func tick(_ sample: VGHLSRateSample) -> VGHLSRateDecision {
        guard mode != .disabled else { return .none }
        if sample.isFailed {
            disable(reason: "playback_failed")
            return .disable(reason: "playback_failed")
        }

        // Clock step: wall and monotonic elapsed time disagree.
        var clockStep = false
        if let lastMono = lastMonotonicSeconds, let lastWall = lastWallSeconds {
            let elapsedMono = sample.monotonicSeconds - lastMono
            let elapsedWall = sample.wallSeconds - lastWall
            if !elapsedMono.isFinite || !elapsedWall.isFinite
                || abs(elapsedWall - elapsedMono) > config.clockStepToleranceSeconds {
                clockStep = true
            }
        }
        lastMonotonicSeconds = sample.monotonicSeconds
        lastWallSeconds      = sample.wallSeconds

        // Stall-count increase since the previous tick.
        var stallIncreased = false
        if let last = lastStallCount, sample.stallCount > last { stallIncreased = true }
        lastStallCount = sample.stallCount

        // Validity.
        let validAge: Int? = sample.ageMs.flatMap {
            ($0 >= config.minValidAgeMs && $0 <= config.maxValidAgeMs) ? $0 : nil
        }
        let validBuffer: Int? = sample.contiguousForwardBufferMs.flatMap { $0 >= 0 ? $0 : nil }

        // Discontinuity between consecutive valid ages.
        var discontinuity = false
        if let age = validAge, let previous = lastValidAgeMs,
           abs(age - previous) > config.discontinuityAgeDeltaMs {
            discontinuity = true
        }
        lastValidAgeMs = validAge

        // Continuous playing time.
        if sample.isPlaying {
            if playingSinceSeconds == nil { playingSinceSeconds = sample.monotonicSeconds }
        } else {
            playingSinceSeconds = nil
        }

        // Safety conditions, raw and immediate.
        let safetyReason: String? = {
            if !sample.isReady                              { return "not_ready" }
            if sample.isWaiting                             { return "waiting" }
            if !sample.isPlaying                            { return "not_playing" }
            if stallIncreased                               { return "stall_count_increased" }
            guard validAge != nil else                      { return "invalid_age" }
            guard let buffer = validBuffer else             { return "invalid_buffer" }
            if buffer < config.safetyBufferMs               { return "buffer_low" }
            if clockStep                                    { return "clock_step" }
            if discontinuity                                { return "age_discontinuity" }
            return nil
        }()
        if let reason = safetyReason {
            resetFilter()
            requireSettle(from: sample.monotonicSeconds)
            if mode == .accelerating {
                return .exitAccelerated(reason: reason, safety: true)
            }
            return .none
        }

        // Filter update; the window holds consecutive valid samples only.
        guard let age = validAge, let buffer = validBuffer else { return .none }
        ageWindow.append(age)
        if ageWindow.count > config.medianWindow { ageWindow.removeFirst() }
        guard let filtered = filteredAgeMs else { return .none }

        switch mode {
        case .accelerating:
            guard filtered <= config.targetAgeMs else { return .none }
            guard writeSpacingElapsed(at: sample.monotonicSeconds) else { return .none }
            return .exitAccelerated(reason: "target_reached", safety: false)

        case .normal:
            if filtered >= config.entryAgeMs {
                consecutiveEntryTicks += 1
            } else {
                consecutiveEntryTicks = 0
            }
            guard consecutiveEntryTicks >= config.entryConsecutiveTicks else { return .none }
            guard let playingSince = playingSinceSeconds,
                  sample.monotonicSeconds - playingSince >= config.settleSeconds else { return .none }
            if let settleUntil = settleUntilSeconds, sample.monotonicSeconds < settleUntil { return .none }
            guard buffer >= config.entryBufferMs else { return .none }
            guard writeSpacingElapsed(at: sample.monotonicSeconds) else { return .none }
            return .enterAccelerated

        case .disabled:
            return .none
        }
    }

    // MARK: - Events

    /// The item's time changed discontinuously. The filter starts over and a fresh
    /// settling period is required; an active acceleration ends as a safety exit.
    mutating func noteTimeJump(atMonotonicSeconds now: Double) -> VGHLSRateDecision {
        guard mode != .disabled else { return .none }
        resetFilter()
        lastValidAgeMs = nil
        requireSettle(from: now)
        if mode == .accelerating {
            return .exitAccelerated(reason: "time_jump", safety: true)
        }
        return .none
    }

    /// The controller applied the accelerated rate.
    mutating func didEnterAccelerated(atMonotonicSeconds now: Double) {
        guard mode == .normal else { return }
        mode = .accelerating
        consecutiveEntryTicks = 0
        lastNonSafetyWriteSeconds = now
    }

    /// The controller applied the normal rate. A non-safety exit counts toward
    /// write spacing; a safety exit has already scheduled its settling period.
    mutating func didExitAccelerated(atMonotonicSeconds now: Double, safety: Bool) {
        guard mode == .accelerating else { return }
        mode = .normal
        consecutiveEntryTicks = 0
        if !safety { lastNonSafetyWriteSeconds = now }
    }

    /// The controller could not apply an entry write (for example the player was no
    /// longer .playing). Entry conditions start over after a fresh settling period.
    mutating func didDeclineEntry(atMonotonicSeconds now: Double) {
        guard mode == .normal else { return }
        consecutiveEntryTicks = 0
        resetFilter()
        requireSettle(from: now)
    }

    /// Ends the experiment for the session. Irreversible; the first reason is kept.
    mutating func disable(reason: String) {
        guard mode != .disabled else { return }
        mode = .disabled
        disabledReason = reason
        resetFilter()
    }

    // MARK: - Helpers

    private mutating func resetFilter() {
        ageWindow.removeAll()
        consecutiveEntryTicks = 0
    }

    private mutating func requireSettle(from now: Double) {
        let until = now + config.settleSeconds
        if let current = settleUntilSeconds, current > until { return }
        settleUntilSeconds = until
    }

    private func writeSpacingElapsed(at now: Double) -> Bool {
        guard let last = lastNonSafetyWriteSeconds else { return true }
        return now - last >= config.minimumWriteSpacingSeconds
    }

    /// Median of a non-empty list; the mean of the two middle values for an even count.
    static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 1 { return sorted[count / 2] }
        return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }
}
