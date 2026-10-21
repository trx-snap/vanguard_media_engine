// VGHLSStartupAlignment.swift
// LOW_LATENCY startup alignment experiment (Debug or explicit Release opt-in)
//
// iOS port of the controller-free Mac lab gate (PrecisionStartup): one attempt per
// LOW_LATENCY session, started by VGStreamingPlaybackCoordinator right after the
// ordinary play().
//
//   warming          ready live item, two advancing copied frames at 1×, then ONE
//                    loaded range covering the forward-only PDT target + 500 ms
//   waitingReady     paused once (the pause is owned); ready and rate 0 on a later tick
//   prerolling       preroll(atRate: 1), finished == true required
//   waitingCoverage  target recomputed; ONE loaded range covering target + 350 ms
//   starting         autoWaits=false, then exactly one
//                    setRate(1, time: target, atHostTime: now + 50 ms)
//   aligned          two advancing copied frames at or past target − 50 ms
//
// Anything else — a deadline, a missing PDT, coverage never arriving, a preroll
// that fails, an unowned pause, inactivity, an audio interruption, a stall or a
// native failure — ends the attempt with one Event. The helper never writes the
// public session state and never seeks, accelerates, replaces the item or
// recovers; the coordinator owns intent, the public state and every route.
//
// Layout:
//   Pure policy (Foundation/CoreMedia only; compiles on macOS for tests):
//     VGHLSStartupAlignmentPolicy, VGHLSStartupDeadlineBudget,
//     VGHLSStartupTargetMapping, VGHLSStartupCoverage, VGHLSStartupFrameGate,
//     VGHLSStartupEndReason.
//   Effects (iOS only): VGHLSStartupAlignment — the AVPlayer / AVPlayerItem
//     writes, the 50 ms main-run-loop timer, the rate KVO and the lifecycle
//     observers.
//
// Threading: every entry point and every effect runs on the main thread. KVO,
// notification and preroll callbacks hop to main, check the helper epoch and read
// the CURRENT player values before acting.
//
// Owned overrides: automaticallyWaitsToMinimizeStalling and
// canUseNetworkResourcesForLiveStreamingWhilePaused are captured at start(); the
// paused-network flag is enabled at once and autoWaits is set to false only
// immediately before the start. Both are retained after a successful alignment,
// as in the lab, and restored by cancel(), by every end and by disposal.
//
// Copied-frame alignment is not proof of visible latency; the iPhone clock offset
// from the origin shifts the target one for one.

import CoreMedia
import Foundation

// MARK: - Policy constants

enum VGHLSStartupAlignmentPolicy {
    /// Main-run-loop timer period that drives every phase transition.
    static let tickIntervalSeconds: TimeInterval = 0.050
    /// Hard cap from start() over the whole attempt; deliberately tighter than the
    /// lab, whose phase deadlines were not capped by an overall one.
    static let overallDeadlineSeconds:       Double = 10.0
    static let prerollDeadlineSeconds:       Double = 3.0
    static let finalCoverageDeadlineSeconds: Double = 2.0
    static let confirmDeadlineSeconds:       Double = 1.5
    /// The live offset the target is measured against (configuredTimeOffsetFromLive).
    static let liveOffsetSeconds:            Double = 1.2
    static let warmCoverageAheadSeconds:     Double = 0.500
    static let finalCoverageAheadSeconds:    Double = 0.350
    /// A copied frame displayed more than this ahead of the query time is a future
    /// sample and never counts.
    static let maxDisplayAheadOfQuerySeconds: Double = 0.050
    static let unitRateTolerance:            Double = 0.005
    /// Qualifying copies count at least this far apart, as the lab sampled.
    static let minQualifyingSpacingSeconds:  Double = 0.200
    static let requiredWarmFrames:           Int = 2
    static let requiredConfirmFrames:        Int = 2
    /// A confirming copy may display this much before the target.
    static let confirmToleranceSeconds:      Double = 0.050
    /// Host lead given to setRate(_:time:atHostTime:).
    static let startHostLeadSeconds:         Double = 0.050
    /// currentTime / currentDate / currentTime sampling limits.
    static let timelineSampleMaxSpanSeconds:  Double = 0.005
    static let timelineSampleMaxDeltaSeconds: Double = 0.005
    /// A wait is logged once, then at most this often.
    static let waitLogIntervalSeconds:       Double = 1.0
    /// Copied-frame observations kept between two ticks.
    static let maxPendingObservations:       Int = 64
}

// MARK: - Deadline budget

/// The overall deadline from start() and the current phase deadline, which is
/// always capped by the overall one. Times are host seconds (CACurrentMediaTime).
struct VGHLSStartupDeadlineBudget {
    let startSeconds:           Double
    let overallDeadlineSeconds: Double
    private(set) var phaseDeadlineSeconds: Double

    init(startSeconds: Double,
         overallSeconds: Double = VGHLSStartupAlignmentPolicy.overallDeadlineSeconds) {
        self.startSeconds           = startSeconds
        self.overallDeadlineSeconds = startSeconds + overallSeconds
        self.phaseDeadlineSeconds   = self.overallDeadlineSeconds
    }

    /// Starts a phase deadline `seconds` from `now`, capped by the overall deadline.
    mutating func beginPhase(seconds: Double, now: Double) {
        phaseDeadlineSeconds = min(now + seconds, overallDeadlineSeconds)
    }

    func isOverallExpired(now: Double) -> Bool { return now > overallDeadlineSeconds }
    func isPhaseExpired(now: Double)   -> Bool { return now > phaseDeadlineSeconds }
}

// MARK: - Target mapping

/// The three reads taken back to back on main: currentTime, currentDate, currentTime.
struct VGHLSStartupTimelineSample {
    let firstTime:   CMTime
    let date:        Date?
    let secondTime:  CMTime
    /// Host seconds between the first and the last read.
    let spanSeconds: Double
    /// Wall clock read right after the sample; the PDT age is measured against it.
    let wallClock:   Date
}

struct VGHLSStartupTarget {
    let currentSeconds: Double
    let pdtAgeSeconds:  Double
    let deltaSeconds:   Double
    /// The quantized, forward-only item time to start at; never before the
    /// sampled current time.
    let finiteTarget:   CMTime
    var quantizedSeconds: Double { return finiteTarget.seconds }
}

/// target = currentTime + max(0, pdtAge − liveOffset), quantized to the current
/// time's timescale. The lab formula (PrecisionStartup.attemptPrecisionStart).
enum VGHLSStartupTargetMapping {

    enum Failure: String, Error {
        case sampleSpanExceeded
        case currentTimeInvalid
        case currentTimeUnstable
        case pdtUnavailable
        case pdtAgeInvalid
        case targetInvalid

        /// Whether a fresh sample on a later tick can reasonably succeed.
        var isTransient: Bool { return self == .sampleSpanExceeded || self == .currentTimeUnstable }
    }

    static func isFiniteNumeric(_ time: CMTime) -> Bool {
        return time.isValid && !time.isIndefinite && time.isNumeric && time.seconds.isFinite
    }

    static func map(_ sample: VGHLSStartupTimelineSample,
                    liveOffsetSeconds: Double = VGHLSStartupAlignmentPolicy.liveOffsetSeconds)
        -> Result<VGHLSStartupTarget, Failure> {
        guard sample.spanSeconds.isFinite,
              sample.spanSeconds <= VGHLSStartupAlignmentPolicy.timelineSampleMaxSpanSeconds else {
            return .failure(.sampleSpanExceeded)
        }
        guard isFiniteNumeric(sample.firstTime), isFiniteNumeric(sample.secondTime) else {
            return .failure(.currentTimeInvalid)
        }
        guard abs(sample.secondTime.seconds - sample.firstTime.seconds)
                <= VGHLSStartupAlignmentPolicy.timelineSampleMaxDeltaSeconds else {
            return .failure(.currentTimeUnstable)
        }
        guard let date = sample.date else { return .failure(.pdtUnavailable) }
        let age = sample.wallClock.timeIntervalSince(date)
        guard age.isFinite else { return .failure(.pdtAgeInvalid) }
        let delta   = max(0.0, age - liveOffsetSeconds)
        let current = sample.secondTime
        let targetSeconds = current.seconds + delta
        guard targetSeconds.isFinite, targetSeconds > 0 else { return .failure(.targetInvalid) }
        let timescale: CMTimeScale = current.timescale > 0 ? current.timescale : 1000
        var finite = CMTime(seconds: targetSeconds, preferredTimescale: timescale)
        // Forward-only: quantization must never land before the sampled current time.
        if finite < current { finite = current }
        guard isFiniteNumeric(finite), finite.seconds > 0 else { return .failure(.targetInvalid) }
        return .success(VGHLSStartupTarget(
            currentSeconds: current.seconds,
            pdtAgeSeconds:  age,
            deltaSeconds:   delta,
            finiteTarget:   finite))
    }
}

// MARK: - Loaded coverage

enum VGHLSStartupCoverage {
    /// Whether target through target + requiredAhead lies inside ONE loaded range
    /// with a finite non-negative start and a positive finite duration.
    static func hasLoadedCoverage(targetSeconds: Double, ranges: [CMTimeRange],
                                  requiredAheadSeconds: Double) -> Bool {
        guard requiredAheadSeconds.isFinite, requiredAheadSeconds > 0 else { return false }
        guard targetSeconds.isFinite, targetSeconds >= 0 else { return false }
        let requiredEnd = targetSeconds + requiredAheadSeconds
        guard requiredEnd.isFinite else { return false }
        for range in ranges {
            let start = range.start.seconds, duration = range.duration.seconds, end = range.end.seconds
            guard start.isFinite, duration.isFinite, end.isFinite, start >= 0, duration > 0 else { continue }
            if start <= targetSeconds && requiredEnd <= end { return true }
        }
        return false
    }
}

// MARK: - Copied-frame gate

/// One copied frame as the display link saw it. Times are seconds; a time that
/// was not numeric is NaN.
struct VGHLSStartupFrameObservation {
    let displaySeconds:      Double
    let querySeconds:        Double
    let queryHostSeconds:    Double
    /// CACurrentMediaTime when the copy was recorded.
    let observedHostSeconds: Double
    /// timeControlStatus playing with requested and effective rate 1 ± tolerance.
    let isPlayingAtUnitRate: Bool

    var hasFiniteTimes: Bool {
        return displaySeconds.isFinite && querySeconds.isFinite
            && queryHostSeconds.isFinite && observedHostSeconds.isFinite
    }
    var displayAheadOfQuerySeconds: Double { return displaySeconds - querySeconds }
    var isEligible: Bool {
        return hasFiniteTimes && isPlayingAtUnitRate
            && displayAheadOfQuerySeconds <= VGHLSStartupAlignmentPolicy.maxDisplayAheadOfQuerySeconds
    }
}

/// The warm gate (two advancing eligible copies before the pause) and the
/// confirmation gate (two advancing eligible copies after issuance, beyond every
/// display time seen before it and at or past target − tolerance). Qualifying
/// copies count at least minQualifyingSpacing apart; a copy inside that spacing is
/// neither counted nor a reset. An ineligible or non-advancing copy resets.
struct VGHLSStartupFrameGate {

    enum ConfirmResult { case notIssued, ignored, reset, counted, satisfied }

    private(set) var warmCount: Int = 0
    private var lastWarmDisplaySeconds: Double = -.infinity
    private var lastWarmHostSeconds:    Double = -.infinity
    /// Highest finite display time observed before issuance, eligible or not.
    private(set) var maxDisplayBeforeIssuanceSeconds: Double = -.infinity

    private(set) var isIssued: Bool = false
    private(set) var issuanceHostSeconds: Double = 0
    private(set) var targetSeconds: Double = 0
    private(set) var confirmCount: Int = 0
    private var lastConfirmDisplaySeconds: Double = -.infinity
    private var lastConfirmHostSeconds:    Double = -.infinity
    /// The first eligible copy beyond the pre-issuance maximum and at or past the target.
    private(set) var firstPostTargetObservation: VGHLSStartupFrameObservation?
    /// The last copy the confirmation gate counted; nil after a reset.
    private(set) var lastConfirmingObservation: VGHLSStartupFrameObservation?

    var isWarm: Bool { return warmCount >= VGHLSStartupAlignmentPolicy.requiredWarmFrames }
    /// Whether the confirmation gate stands satisfied after the copies fed so far.
    var isConfirmed: Bool { return isIssued && confirmCount >= VGHLSStartupAlignmentPolicy.requiredConfirmFrames }

    /// Records a display time seen before issuance without touching the counts.
    mutating func trackDisplay(_ observation: VGHLSStartupFrameObservation) {
        guard !isIssued, observation.displaySeconds.isFinite else { return }
        maxDisplayBeforeIssuanceSeconds = max(maxDisplayBeforeIssuanceSeconds, observation.displaySeconds)
    }

    /// Feeds the warm gate; returns whether it is satisfied after this copy.
    @discardableResult
    mutating func observeWarm(_ observation: VGHLSStartupFrameObservation) -> Bool {
        trackDisplay(observation)
        guard observation.isEligible else { resetWarm(); return false }
        if warmCount > 0 {
            if observation.observedHostSeconds - lastWarmHostSeconds
                < VGHLSStartupAlignmentPolicy.minQualifyingSpacingSeconds {
                return isWarm
            }
            guard observation.displaySeconds > lastWarmDisplaySeconds else { resetWarm(); return false }
        }
        warmCount += 1
        lastWarmDisplaySeconds = observation.displaySeconds
        lastWarmHostSeconds    = observation.observedHostSeconds
        return isWarm
    }

    private mutating func resetWarm() {
        warmCount = 0
        lastWarmDisplaySeconds = -.infinity
        lastWarmHostSeconds    = -.infinity
    }

    mutating func markIssued(targetSeconds: Double, hostSeconds: Double) {
        isIssued = true
        self.targetSeconds   = targetSeconds
        issuanceHostSeconds  = hostSeconds
        resetConfirmation()
        firstPostTargetObservation = nil
    }

    /// Clears the confirmation count; the first post-target record is kept.
    mutating func resetConfirmation() {
        confirmCount = 0
        lastConfirmDisplaySeconds = -.infinity
        lastConfirmHostSeconds    = -.infinity
        lastConfirmingObservation = nil
    }

    /// Feeds the confirmation gate with a copy recorded after markIssued.
    @discardableResult
    mutating func observeConfirming(_ observation: VGHLSStartupFrameObservation) -> ConfirmResult {
        guard isIssued else { return .notIssued }
        // Copied in a later main-thread turn than the issuing tick.
        guard observation.observedHostSeconds > issuanceHostSeconds else { return .ignored }
        guard observation.isEligible else { resetConfirmation(); return .reset }
        let isNew = observation.displaySeconds > maxDisplayBeforeIssuanceSeconds
        let atOrPastTarget = observation.displaySeconds
            >= targetSeconds - VGHLSStartupAlignmentPolicy.confirmToleranceSeconds
        guard isNew, atOrPastTarget else { resetConfirmation(); return .reset }
        if firstPostTargetObservation == nil { firstPostTargetObservation = observation }
        if confirmCount > 0 {
            if observation.observedHostSeconds - lastConfirmHostSeconds
                < VGHLSStartupAlignmentPolicy.minQualifyingSpacingSeconds {
                return .ignored
            }
            guard observation.displaySeconds > lastConfirmDisplaySeconds else { resetConfirmation(); return .reset }
        }
        confirmCount += 1
        lastConfirmDisplaySeconds = observation.displaySeconds
        lastConfirmHostSeconds    = observation.observedHostSeconds
        lastConfirmingObservation = observation
        return isConfirmed ? .satisfied : .counted
    }
}

// MARK: - End reasons

/// Why an attempt ended without, or after, an alignment. The disposition is what
/// the coordinator does with the player; the reason itself is diagnostic.
enum VGHLSStartupEndReason: String {
    // Ordinary fallback: the coordinator resumes only a pause the attempt owned.
    case notLive
    case warmTimeout
    case notPlayingAtWarmGate
    case notReadyAtGate
    case unexpectedRate
    case pdtUnavailable
    case prerollTimeout
    case prerollInterrupted
    case coverageTimeout
    case confirmTimeout
    case autoWaitsWriteFailed
    case identityMismatch
    case intentLost
    // External interruption: the coordinator clears intent and pauses.
    case externalPause
    case applicationInactive
    case audioInterruption
    case playbackStalled
    // Native failure: the status callbacks own the state.
    case nativeFailed

    enum Disposition { case fallback, externalInterruption, nativeFailure }

    var disposition: Disposition {
        switch self {
        case .externalPause, .applicationInactive, .audioInterruption, .playbackStalled:
            return .externalInterruption
        case .nativeFailed:
            return .nativeFailure
        default:
            return .fallback
        }
    }
}

#if os(iOS)

import AVFoundation
import UIKit
import os

// MARK: - Effects (iOS)

/// Owns one alignment attempt's timing, native effects and captured overrides for
/// a LOW_LATENCY session. Constructed and driven by VGStreamingPlaybackCoordinator
/// on the main thread; see the file header for the protocol.
final class VGHLSStartupAlignment {

    enum Event {
        /// Two advancing copied frames at or past the target were confirmed.
        case aligned
        /// The attempt ended without an alignment, or the retained observation
        /// after one found an external pause, inactivity, interruption or stall.
        /// ownedPause is whether the attempt had paused the player itself.
        case ended(reason: VGHLSStartupEndReason, ownedPause: Bool)
    }

    enum Phase: String {
        case created, warming, waitingReady, prerolling, waitingCoverage, starting, aligned, ended
    }

    // .notice is the lowest level the unified log writes to disk by default.
    private static let logger = Logger(subsystem: "com.vanguard.engine", category: "hls-startup")

    private let player:    AVPlayer
    private let item:      AVPlayerItem
    private let sessionId: String
    /// The coordinator's view: the session is current, still intends to play and
    /// still holds this attempt.
    private let isCurrentAndIntended: () -> Bool
    /// Meaningful once the item is ready: no definite duration.
    private let isLive:  () -> Bool
    private let onEvent: (Event) -> Void

    private(set) var phase: Phase = .created
    /// True from immediately before the attempt's own pause() until immediately
    /// before its setRate; the coordinator reports that pause as buffering.
    private(set) var ownsPause: Bool = false

    /// True between start() and the aligned or ended outcome.
    var isAligning: Bool {
        switch phase {
        case .warming, .waitingReady, .prerolling, .waitingCoverage, .starting: return true
        case .created, .aligned, .ended:                                       return false
        }
    }
    var phaseName: String { return phase.rawValue }
    /// Aligning, or aligned with the lifecycle observation retained.
    private var isObserving: Bool { return isAligning || phase == .aligned }

    // ── Lifetime ─────────────────────────────────────────────────────────────
    /// Bumped by cleanup; a callback carrying an older epoch is ignored.
    private var epoch: UInt64 = 0
    private var cleanedUp = false
    private var timer: Timer?
    private var rateObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var capturedAutoWaits:     Bool?
    private var capturedPausedNetwork: Bool?

    // ── Attempt state ────────────────────────────────────────────────────────
    private var budget = VGHLSStartupDeadlineBudget(startSeconds: 0)
    private var gate   = VGHLSStartupFrameGate()
    private var pending: [VGHLSStartupFrameObservation] = []
    private var target: VGHLSStartupTarget?
    private var lastMappingFailure: VGHLSStartupTargetMapping.Failure?
    private var startHostSeconds:  Double = 0
    private var issuedHostSeconds: Double = 0
    private var lastRateChangeReason: String?

    // ── Bounded diagnostics ──────────────────────────────────────────────────
    private var waitLogKind: String?
    private var lastWaitLogAt: Double = -.infinity
    private var didLogWarmGate = false
    private var didLogFirstPostTarget = false

    init(player: AVPlayer,
         item: AVPlayerItem,
         sessionId: String,
         isCurrentAndIntended: @escaping () -> Bool,
         isLive: @escaping () -> Bool,
         onEvent: @escaping (Event) -> Void) {
        self.player    = player
        self.item      = item
        self.sessionId = sessionId
        self.isCurrentAndIntended = isCurrentAndIntended
        self.isLive  = isLive
        self.onEvent = onEvent
    }

    deinit {
        cleanup()
    }

    // MARK: - Entry points (main thread)

    /// Begins the attempt right after the ordinary play(). A second call is a no-op.
    func start() {
        guard phase == .created, !cleanedUp else { return }
        // Context before the first override write: nothing is written for a session
        // that is already replaced, not current, failed or in the background.
        guard player.currentItem === item else { end(.identityMismatch); return }
        guard isCurrentAndIntended() else { end(.intentLost); return }
        guard player.status != .failed, item.status != .failed else { end(.nativeFailed); return }
        guard UIApplication.shared.applicationState == .active else { end(.applicationInactive); return }
        let now = CACurrentMediaTime()
        startHostSeconds = now
        budget = VGHLSStartupDeadlineBudget(startSeconds: now)
        capturedAutoWaits     = player.automaticallyWaitsToMinimizeStalling
        capturedPausedNetwork = item.canUseNetworkResourcesForLiveStreamingWhilePaused
        // Loaded ranges keep moving while the attempt holds its own pause.
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        installObservers()
        phase = .warming
        let timer = Timer(timeInterval: VGHLSStartupAlignmentPolicy.tickIntervalSeconds, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            self.tick()
        }
        // .common keeps ticking while the UI is tracking a touch or scroll.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log("start", ["capturedAutoWaits=\(capturedAutoWaits ?? false)",
                      "capturedPausedNetwork=\(capturedPausedNetwork ?? false)"])
    }

    /// Records one copied frame from the display link; nothing is decided here.
    /// The next tick feeds it to the gate.
    func observeCopiedFrame(displayTime: CMTime, queryTime: CMTime, hostSeconds: Double) {
        guard isAligning else { return }
        let requested = Double(player.rate)
        let effective = item.timebase.map { CMTimebaseGetEffectiveRate($0) } ?? Double.nan
        let tolerance = VGHLSStartupAlignmentPolicy.unitRateTolerance
        let playingAtUnitRate = player.timeControlStatus == .playing
            && requested.isFinite && abs(requested - 1.0) <= tolerance
            && effective.isFinite && abs(effective - 1.0) <= tolerance
        let observation = VGHLSStartupFrameObservation(
            displaySeconds:      displayTime.isNumeric ? displayTime.seconds : Double.nan,
            querySeconds:        queryTime.isNumeric   ? queryTime.seconds   : Double.nan,
            queryHostSeconds:    hostSeconds,
            observedHostSeconds: CACurrentMediaTime(),
            isPlayingAtUnitRate: playingAtUnitRate)
        // Value-only bookkeeping now: the pre-issuance barrier is current at once, so
        // an issue from the preroll callback never uses an outdated maximum.
        gate.trackDisplay(observation)
        if pending.count >= VGHLSStartupAlignmentPolicy.maxPendingObservations {
            pending.removeFirst()
        }
        pending.append(observation)
    }

    /// Synchronous check of the player and application state, for a route that
    /// would otherwise answer a repeated Play with a snapshot.
    func refreshExternalState() {
        guard !cleanedUp, isObserving else { return }
        if player.rate == 0, !ownsPause {
            end(.externalPause)
            return
        }
        if UIApplication.shared.applicationState != .active {
            end(.applicationInactive)
        }
    }

    /// AVPlayerItemPlaybackStalled for this item, forwarded by the coordinator.
    func playbackStalled() {
        guard !cleanedUp, isObserving else { return }
        end(.playbackStalled)
    }

    /// Ends the attempt without an outcome and restores the captured overrides.
    /// Returns whether the attempt owned the player's pause at that moment.
    @discardableResult
    func cancel(reason: String) -> Bool {
        guard !cleanedUp else { return false }
        let owned = ownsPause
        log("cancel", ["reason=\(reason)", "ownedPause=\(owned)",
                       "elapsedMs=\(Self.ms(CACurrentMediaTime() - startHostSeconds))"])
        cleanup()
        return owned
    }

    // MARK: - Timer

    private func tick() {
        guard isAligning else { return }
        let now = CACurrentMediaTime()
        // Context first: a queued copy is never accepted for a session that is no
        // longer current, intended, foreground, healthy or inside its deadlines.
        guard player.currentItem === item else { end(.identityMismatch); return }
        guard isCurrentAndIntended() else { end(.intentLost); return }
        guard player.status != .failed, item.status != .failed else { end(.nativeFailed); return }
        if player.rate == 0, !ownsPause { end(.externalPause); return }
        guard UIApplication.shared.applicationState == .active else { end(.applicationInactive); return }
        guard !budget.isOverallExpired(now: now), !budget.isPhaseExpired(now: now) else {
            end(timeoutReason(for: phase))
            return
        }
        drainObservations(now: now)
        guard isAligning else { return }
        switch phase {
        case .warming:         tickWarming(now: now)
        case .waitingReady:    tickWaitingReady(now: now)
        case .prerolling:      break   // the completion callback moves on; the deadline is above
        case .waitingCoverage: attemptStart(now: now)
        case .starting:        break   // drainObservations confirms; the deadline is above
        case .created, .aligned, .ended: break
        }
    }

    /// Ready live item, warm gate, then ONE loaded range covering target + 500 ms
    /// while playback continues at 1×; then the one pause.
    private func tickWarming(now: Double) {
        guard item.status == .readyToPlay, player.status == .readyToPlay else { return }
        guard isLive() else { end(.notLive); return }
        guard gate.isWarm else { return }
        if !didLogWarmGate {
            didLogWarmGate = true
            log("warmGate", ["elapsedMs=\(Self.ms(now - startHostSeconds))"])
        }
        // The gate holds only while playback is still at 1×, as in the lab.
        guard isPlayingAtUnitRate() else { end(.notPlayingAtWarmGate); return }
        let mapped: VGHLSStartupTarget
        switch VGHLSStartupTargetMapping.map(sampleTimeline()) {
        case .failure(let failure):
            lastMappingFailure = failure
            logWait("warmMapping", now: now, ["failure=\(failure.rawValue)"])
            return
        case .success(let value):
            mapped = value
        }
        lastMappingFailure = nil
        let ahead = VGHLSStartupAlignmentPolicy.warmCoverageAheadSeconds
        guard VGHLSStartupCoverage.hasLoadedCoverage(
                targetSeconds: mapped.quantizedSeconds, ranges: loadedRanges(), requiredAheadSeconds: ahead) else {
            logWait("warmCoverage", now: now, ["target=\(Self.fmt(mapped.quantizedSeconds))",
                                               "delta=\(Self.fmt(mapped.deltaSeconds))"])
            return
        }
        // Fresh rechecks immediately before the one pause.
        guard player.currentItem === item else { end(.identityMismatch); return }
        guard isCurrentAndIntended() else { end(.intentLost); return }
        guard UIApplication.shared.applicationState == .active else { end(.applicationInactive); return }
        guard item.status == .readyToPlay, player.status == .readyToPlay else { end(.notReadyAtGate); return }
        guard isPlayingAtUnitRate() else { end(.notPlayingAtWarmGate); return }
        guard !budget.isOverallExpired(now: CACurrentMediaTime()) else { end(.warmTimeout); return }
        guard VGHLSStartupCoverage.hasLoadedCoverage(
                targetSeconds: mapped.quantizedSeconds, ranges: loadedRanges(), requiredAheadSeconds: ahead) else {
            return
        }
        target = mapped
        waitLogKind = nil
        ownsPause = true
        phase = .waitingReady
        log("pause", ["target=\(Self.fmt(mapped.quantizedSeconds))",
                      "current=\(Self.fmt(mapped.currentSeconds))",
                      "pdtAge=\(Self.fmt(mapped.pdtAgeSeconds))",
                      "elapsedMs=\(Self.ms(now - startHostSeconds))"])
        player.pause()
    }

    /// On a tick after the pause: ready player and item at rate 0, then exactly
    /// one preroll at 1×.
    private func tickWaitingReady(now: Double) {
        guard item.status == .readyToPlay, player.status == .readyToPlay, player.rate == 0 else { return }
        guard UIApplication.shared.applicationState == .active else { end(.applicationInactive); return }
        budget.beginPhase(seconds: VGHLSStartupAlignmentPolicy.prerollDeadlineSeconds, now: now)
        phase = .prerolling
        let issueEpoch = epoch
        log("prerollRequested")
        player.preroll(atRate: 1.0) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self, self.epoch == issueEpoch, self.phase == .prerolling else { return }
                self.handlePrerollCompletion(finished: finished)
            }
        }
    }

    private func handlePrerollCompletion(finished: Bool) {
        let now = CACurrentMediaTime()
        guard !budget.isPhaseExpired(now: now), !budget.isOverallExpired(now: now) else {
            end(.prerollTimeout)
            return
        }
        guard finished else { end(.prerollInterrupted); return }
        log("prerollCompleted", ["elapsedMs=\(Self.ms(now - startHostSeconds))"])
        phase = .waitingCoverage
        waitLogKind = nil
        budget.beginPhase(seconds: VGHLSStartupAlignmentPolicy.finalCoverageDeadlineSeconds, now: now)
        attemptStart(now: now)
    }

    /// Recomputes the target from the paused timeline, requires ONE loaded range
    /// covering target + 350 ms, then issues the one start.
    private func attemptStart(now: Double) {
        guard phase == .waitingCoverage else { return }
        guard item.status == .readyToPlay, player.status == .readyToPlay else { end(.notReadyAtGate); return }
        guard player.rate == 0 else { end(.unexpectedRate); return }
        let mapped: VGHLSStartupTarget
        switch VGHLSStartupTargetMapping.map(sampleTimeline()) {
        case .failure(let failure):
            lastMappingFailure = failure
            // A sample the main thread stretched is retaken on the next tick, inside
            // the phase deadline; a missing or invalid mapping ends the attempt.
            if failure.isTransient {
                logWait("finalMapping", now: now, ["failure=\(failure.rawValue)"])
            } else {
                end(.pdtUnavailable)
            }
            return
        case .success(let value):
            mapped = value
        }
        lastMappingFailure = nil
        target = mapped
        let ahead = VGHLSStartupAlignmentPolicy.finalCoverageAheadSeconds
        guard VGHLSStartupCoverage.hasLoadedCoverage(
                targetSeconds: mapped.quantizedSeconds, ranges: loadedRanges(), requiredAheadSeconds: ahead) else {
            logWait("finalCoverage", now: now, ["target=\(Self.fmt(mapped.quantizedSeconds))",
                                                "delta=\(Self.fmt(mapped.deltaSeconds))"])
            return
        }
        // Rechecks immediately before the effects, in this same main-thread turn.
        guard player.currentItem === item else { end(.identityMismatch); return }
        guard isCurrentAndIntended() else { end(.intentLost); return }
        guard UIApplication.shared.applicationState == .active else { end(.applicationInactive); return }
        guard item.status == .readyToPlay, player.status == .readyToPlay else { end(.notReadyAtGate); return }
        guard player.rate == 0 else { end(.unexpectedRate); return }
        let issueNow = CACurrentMediaTime()
        guard !budget.isPhaseExpired(now: issueNow), !budget.isOverallExpired(now: issueNow) else {
            end(.coverageTimeout)
            return
        }
        // setRate(_:time:atHostTime:) raises while autoWaits is true; verified by read-back.
        player.automaticallyWaitsToMinimizeStalling = false
        guard player.automaticallyWaitsToMinimizeStalling == false else { end(.autoWaitsWriteFailed); return }
        ownsPause = false
        let hostNow    = CMClockGetTime(CMClockGetHostTimeClock())
        let atHostTime = hostNow + CMTime(seconds: VGHLSStartupAlignmentPolicy.startHostLeadSeconds,
                                          preferredTimescale: 1_000_000_000)
        player.setRate(1.0, time: mapped.finiteTarget, atHostTime: atHostTime)
        issuedHostSeconds = CACurrentMediaTime()
        gate.markIssued(targetSeconds: mapped.quantizedSeconds, hostSeconds: issuedHostSeconds)
        phase = .starting
        waitLogKind = nil
        budget.beginPhase(seconds: VGHLSStartupAlignmentPolicy.confirmDeadlineSeconds, now: issuedHostSeconds)
        log("issued", ["target=\(Self.fmt(mapped.quantizedSeconds))",
                       "current=\(Self.fmt(mapped.currentSeconds))",
                       "pdtAge=\(Self.fmt(mapped.pdtAgeSeconds))",
                       "delta=\(Self.fmt(mapped.deltaSeconds))",
                       "atHost=\(Self.fmt(atHostTime.seconds))",
                       "elapsedMs=\(Self.ms(issuedHostSeconds - startHostSeconds))"])
    }

    /// Feeds every copy recorded since the last tick to the gate for the current
    /// phase. The whole batch is processed, so a reset later in it undoes an earlier
    /// satisfaction; an alignment is then accepted only against the player's CURRENT
    /// playback at 1×. The context checks ran in this tick before the drain.
    private func drainObservations(now: Double) {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        for observation in batch {
            switch phase {
            case .warming:
                gate.observeWarm(observation)
            case .waitingReady, .prerolling, .waitingCoverage:
                gate.trackDisplay(observation)
            case .starting:
                gate.observeConfirming(observation)
                if !didLogFirstPostTarget, let first = gate.firstPostTargetObservation {
                    didLogFirstPostTarget = true
                    log("firstPostTargetCopy", ["display=\(Self.fmt(first.displaySeconds))",
                                                "query=\(Self.fmt(first.querySeconds))",
                                                "target=\(Self.fmt(gate.targetSeconds))",
                                                "sinceIssueMs=\(Self.ms(first.observedHostSeconds - issuedHostSeconds))"])
                }
            case .created, .aligned, .ended:
                return
            }
        }
        guard phase == .starting, gate.isConfirmed, let last = gate.lastConfirmingObservation else { return }
        guard isPlayingAtUnitRate() else {
            gate.resetConfirmation()
            logWait("confirmNotPlayingNow", now: now, [])
            return
        }
        completeAligned(last)
    }

    private func completeAligned(_ observation: VGHLSStartupFrameObservation) {
        phase = .aligned
        timer?.invalidate()
        timer = nil
        pending.removeAll()
        log("aligned", ["display=\(Self.fmt(observation.displaySeconds))",
                        "target=\(Self.fmt(gate.targetSeconds))",
                        "sinceIssueMs=\(Self.ms(observation.observedHostSeconds - issuedHostSeconds))",
                        "elapsedMs=\(Self.ms(observation.observedHostSeconds - startHostSeconds))"])
        onEvent(.aligned)
    }

    // MARK: - Ending

    private func end(_ reason: VGHLSStartupEndReason) {
        guard !cleanedUp else { return }
        let owned = ownsPause
        log("ended", ["reason=\(reason.rawValue)", "ownedPause=\(owned)",
                      "mapping=\(lastMappingFailure?.rawValue ?? "none")",
                      "rateChangeReason=\(lastRateChangeReason ?? "none")",
                      "elapsedMs=\(Self.ms(CACurrentMediaTime() - startHostSeconds))"])
        cleanup()
        onEvent(.ended(reason: reason, ownedPause: owned))
    }

    /// Idempotent: invalidates late callbacks, then restores what was captured. The
    /// player is written only while it still holds the captured item: a replaced
    /// graph is never cancelled or reconfigured from here, and only the captured
    /// item's own setting is put back. Finally removes the timer and observers.
    private func cleanup() {
        guard !cleanedUp else { return }
        cleanedUp = true
        epoch &+= 1
        phase = .ended
        ownsPause = false
        pending.removeAll()
        if player.currentItem === item {
            player.cancelPendingPrerolls()
            if let autoWaits = capturedAutoWaits {
                player.automaticallyWaitsToMinimizeStalling = autoWaits
            }
        }
        if let pausedNetwork = capturedPausedNetwork {
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = pausedNetwork
        }
        timer?.invalidate()
        timer = nil
        rateObservation?.invalidate()
        rateObservation = nil
        let center = NotificationCenter.default
        for token in notificationTokens {
            center.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    // MARK: - Observers

    private func installObservers() {
        // iOS 14 KVO; the handler reads the CURRENT rate on main, not the change.
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleRateChange() }
        }
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.cleanedUp, self.isObserving else { return }
            self.end(.applicationInactive)
        })
        // Observation only; the audio session's category and activation are never touched.
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self, !self.cleanedUp, self.isObserving else { return }
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
                  AVAudioSession.InterruptionType(rawValue: rawType.uintValue) == .began else { return }
            self.end(.audioInterruption)
        })
        if #available(iOS 15.0, *) {
            // Diagnostic only: names the last rate change in the ended record.
            notificationTokens.append(center.addObserver(
                forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main
            ) { [weak self] notification in
                self?.lastRateChangeReason = notification.userInfo?[AVPlayer.rateDidChangeReasonKey] as? String
            })
        }
    }

    private func handleRateChange() {
        guard !cleanedUp, isObserving else { return }
        if player.rate == 0, !ownsPause {
            end(.externalPause)
        }
    }

    // MARK: - Reads

    private func sampleTimeline() -> VGHLSStartupTimelineSample {
        let hostFirst  = CACurrentMediaTime()
        let first      = item.currentTime()
        let date       = item.currentDate()
        let second     = item.currentTime()
        let hostSecond = CACurrentMediaTime()
        return VGHLSStartupTimelineSample(
            firstTime: first, date: date, secondTime: second,
            spanSeconds: hostSecond - hostFirst, wallClock: Date())
    }

    private func loadedRanges() -> [CMTimeRange] {
        return item.loadedTimeRanges.map { $0.timeRangeValue }
    }

    private func isPlayingAtUnitRate() -> Bool {
        guard player.timeControlStatus == .playing else { return false }
        let tolerance = VGHLSStartupAlignmentPolicy.unitRateTolerance
        let requested = Double(player.rate)
        guard requested.isFinite, abs(requested - 1.0) <= tolerance else { return false }
        guard let timebase = item.timebase else { return false }
        let effective = CMTimebaseGetEffectiveRate(timebase)
        return effective.isFinite && abs(effective - 1.0) <= tolerance
    }

    private func timeoutReason(for phase: Phase) -> VGHLSStartupEndReason {
        switch phase {
        case .warming:
            return (gate.isWarm && lastMappingFailure == .pdtUnavailable) ? .pdtUnavailable : .warmTimeout
        case .waitingReady, .prerolling: return .prerollTimeout
        case .waitingCoverage:           return .coverageTimeout
        case .starting:                  return .confirmTimeout
        case .created, .aligned, .ended: return .warmTimeout
        }
    }

    // MARK: - Logging

    private func log(_ event: String, _ fields: [String] = []) {
        let line = (["hls-startup", "event=\(event)", "sessionId=\(sessionId)", "phase=\(phase.rawValue)"] + fields)
            .joined(separator: " ")
        Self.logger.notice("\(line, privacy: .public)")
    }

    /// One record when a wait of `kind` begins, then one sample per interval.
    private func logWait(_ kind: String, now: Double, _ fields: [String]) {
        if waitLogKind != kind {
            waitLogKind = kind
            lastWaitLogAt = now
            log("wait", ["kind=\(kind)"] + fields)
        } else if now - lastWaitLogAt >= VGHLSStartupAlignmentPolicy.waitLogIntervalSeconds {
            lastWaitLogAt = now
            log("waitSample", ["kind=\(kind)"] + fields)
        }
    }

    private static func ms(_ seconds: Double) -> Int {
        return seconds.isFinite ? Int((seconds * 1000.0).rounded()) : -1
    }

    private static func fmt(_ seconds: Double) -> String {
        return seconds.isFinite ? String(format: "%.3f", seconds) : "nan"
    }
}

#endif
