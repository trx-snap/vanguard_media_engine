// VGHLSRecovery.swift
// LOW_LATENCY interruption recovery experiment (Debug or explicit Release opt-in)
//
// After an external interruption ends a startup-alignment attempt, or pauses a
// session that fell back to ordinary playback, one later explicit Play may replace
// the whole AVFoundation graph and run the frozen startup protocol
// (VGHLSStartupAlignment) again on the fresh item, as a new generation. Nothing
// resumes, retries, rebuilds or seeks on its own: the permission is granted by an
// interruption on a ready live item, consumed by exactly one explicit Play in the
// foreground, and cleared by every user control, native failure, end of stream and
// disposal.
//
// Layout:
//   Pure policy (Foundation only; compiles on macOS for tests):
//     VGHLSRecoveryPolicy — the generation counter, the phase and the history.
//   Effects (iOS only):
//     VGHLSFallbackInterruptionObserver — notices an unowned pause of a session in
//     ordinary fallback playback and reports it once.
//
// VGStreamingPlaybackCoordinator owns the session, the graph, intent, the public
// state and every effect; it feeds the policy events and acts on its decisions.

import Foundation

// MARK: - Policy

struct VGHLSRecoveryPolicy {

    enum Phase: Equatable {
        /// Not eligible, or a ready item proved not live: no attempt and no recovery.
        case disabled
        /// Eligible; the generation-one attempt has not begun.
        case unused
        case aligning(generation: UInt64)
        case aligned(generation: UInt64)
        /// An interruption on a ready live item; one explicit Play may reconstruct.
        case armed(generation: UInt64, reason: VGHLSStartupEndReason)
        /// The permission is consumed; the fresh generation awaits beginAlignment.
        case reconstructing(generation: UInt64)
        /// Ordinary playback after an attempt; a later interruption may arm.
        case fallback(generation: UInt64)
        /// A Pause, Seek or Stop: no reconstruction for the session's life.
        case disqualified(reason: String)
        case failed
        case ended
        case disposed
    }

    enum Event {
        case beginAlignment(generation: UInt64)
        case explicitPlay(applicationActive: Bool)
        case interrupted(reason: VGHLSStartupEndReason, generation: UInt64, readyLive: Bool)
        case aligned(generation: UInt64)
        case fallback(reason: VGHLSStartupEndReason, generation: UInt64)
        /// Diagnostic only: a helper cancelled by a control, a terminal path or a rebuild.
        case cancelled(reason: String, generation: UInt64)
        case disqualify(reason: String)
        case failed(generation: UInt64)
        case eof(generation: UInt64)
        case dispose
    }

    enum Decision: Equatable {
        case none
        case ordinaryPlay
        case snapshotOnly
        case startAlignment(generation: UInt64)
        case reconstruct(generation: UInt64)
    }

    /// The current graph's generation; 1 is the graph the session was created with.
    private(set) var generation: UInt64 = 1
    private(set) var phase: Phase
    /// Generation-one history, kept apart from later generations.
    private(set) var initialAttempted = false
    private(set) var initialOutcome   = "none"
    /// The last helper outcome or cancellation of any generation.
    private(set) var lastHelperOutcome = "none"
    /// The interruption that last armed a reconstruction.
    private(set) var triggerReason: VGHLSStartupEndReason?
    /// Reconstructions consumed, and recovery generations that aligned.
    private(set) var attemptCount = 0
    private(set) var alignedCount = 0

    init(eligible: Bool) {
        phase = eligible ? .unused : .disabled
    }

    var isDisabled: Bool { return phase == .disabled }

    var phaseName: String {
        switch phase {
        case .disabled:       return "disabled"
        case .unused:         return "unused"
        case .aligning:       return "aligning"
        case .aligned:        return "aligned"
        case .armed:          return "armed"
        case .reconstructing: return "reconstructing"
        case .fallback:       return "fallback"
        case .disqualified:   return "disqualified"
        case .failed:         return "failed"
        case .ended:          return "ended"
        case .disposed:       return "disposed"
        }
    }

    /// Applies one event. Disposal dominates; a disabled session only answers an
    /// explicit Play, with ordinary play; a stale generation or an event that does
    /// not fit the phase changes nothing.
    mutating func handle(_ event: Event) -> Decision {
        if phase == .disposed { return .none }
        if case .dispose = event {
            phase = .disposed
            return .none
        }
        if phase == .disabled {
            if case .explicitPlay = event { return .ordinaryPlay }
            return .none
        }
        switch event {
        case .beginAlignment(let g):
            guard g == generation else { return .none }
            switch phase {
            case .unused where g == 1:
                initialAttempted = true
                initialOutcome   = "started"
            case .reconstructing(let current) where current == g:
                break
            default:
                return .none
            }
            lastHelperOutcome = "started"
            phase = .aligning(generation: g)
            return .startAlignment(generation: g)

        case .explicitPlay(let applicationActive):
            switch phase {
            case .aligning:
                return .snapshotOnly
            case .armed:
                guard applicationActive else { return .snapshotOnly }
                generation   += 1
                attemptCount += 1
                phase = .reconstructing(generation: generation)
                return .reconstruct(generation: generation)
            default:
                return .ordinaryPlay
            }

        case .interrupted(let reason, let g, let readyLive):
            guard g == generation else { return .none }
            switch phase {
            case .aligning, .aligned:
                recordHelperOutcome(reason.rawValue, generation: g)
            case .fallback:
                break
            default:
                return .none
            }
            if readyLive {
                triggerReason = reason
                phase = .armed(generation: g, reason: reason)
            } else {
                // Unproven live: paused with intent cleared, but no permission.
                phase = .fallback(generation: g)
            }
            return .none

        case .aligned(let g):
            guard g == generation, case .aligning = phase else { return .none }
            recordHelperOutcome("aligned", generation: g)
            if g > 1 { alignedCount += 1 }
            phase = .aligned(generation: g)
            return .none

        case .fallback(let reason, let g):
            guard g == generation, case .aligning = phase else { return .none }
            recordHelperOutcome(reason.rawValue, generation: g)
            phase = reason == .notLive ? .disabled : .fallback(generation: g)
            return .none

        case .cancelled(let reason, let g):
            guard g == generation else { return .none }
            recordHelperOutcome("cancelled_" + reason, generation: g)
            return .none

        case .disqualify(let reason):
            switch phase {
            case .failed, .ended:
                return .none
            default:
                phase = .disqualified(reason: reason)
                return .none
            }

        case .failed(let g):
            guard g == generation else { return .none }
            switch phase {
            case .aligning, .aligned:
                recordHelperOutcome(VGHLSStartupEndReason.nativeFailed.rawValue, generation: g)
            default:
                break
            }
            phase = .failed
            return .none

        case .eof(let g):
            guard g == generation, phase != .failed else { return .none }
            phase = .ended
            return .none

        case .dispose:
            return .none
        }
    }

    /// The generation-one outcome is written once, by whatever completed that attempt.
    private mutating func recordHelperOutcome(_ outcome: String, generation: UInt64) {
        lastHelperOutcome = outcome
        if generation == 1, initialAttempted, initialOutcome == "started" {
            initialOutcome = outcome
        }
    }
}

#if os(iOS)

import AVFoundation
import QuartzCore

// MARK: - Fallback interruption observer (iOS)

/// Watches a session in ordinary fallback playback for a pause it did not ask for
/// and reports it once. It never pauses, resumes or otherwise writes the player: a
/// still-playing session is left alone, and an audio interruption that began
/// shortly before the pause only names it. The coordinator's `canObserve` is read
/// on main, with the player's CURRENT values, right before the one report.
final class VGHLSFallbackInterruptionObserver {

    /// An audio interruption that began within this long before the pause names it.
    private static let audioInterruptionAttributionSeconds: Double = 2.0

    private let player: AVPlayer
    private let item:   AVPlayerItem
    private let canObserve:     () -> Bool
    private let onInterruption: (VGHLSStartupEndReason) -> Void

    private var invalidated = false
    private var rateObservation:        NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var interruptionToken:      NSObjectProtocol?
    private var lastAudioInterruptionBeganAt: Double = -.infinity

    init(player: AVPlayer,
         item: AVPlayerItem,
         canObserve: @escaping () -> Bool,
         onInterruption: @escaping (VGHLSStartupEndReason) -> Void) {
        self.player = player
        self.item   = item
        self.canObserve     = canObserve
        self.onInterruption = onInterruption
        // Both are re-read on main; the KVO change itself is never trusted.
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.evaluate() }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.evaluate() }
        }
        // Observation only; the audio session's category and activation are never touched.
        interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
                  AVAudioSession.InterruptionType(rawValue: rawType.uintValue) == .began else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lastAudioInterruptionBeganAt = CACurrentMediaTime()
                self.evaluate()
            }
        }
    }

    deinit {
        invalidate()
    }

    /// Synchronous check, for an explicit Play that must see a queued pause first.
    func refreshExternalState() {
        evaluate()
    }

    /// Idempotent; nothing is reported afterwards.
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        rateObservation?.invalidate()
        rateObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let token = interruptionToken {
            NotificationCenter.default.removeObserver(token)
        }
        interruptionToken = nil
    }

    /// Main thread. Reports once, for a player already paused by something other
    /// than the coordinator, while the coordinator still allows the observation.
    private func evaluate() {
        guard !invalidated else { return }
        guard player.currentItem === item, player.rate == 0, player.timeControlStatus == .paused else { return }
        guard canObserve() else { return }
        let reason: VGHLSStartupEndReason =
            CACurrentMediaTime() - lastAudioInterruptionBeganAt <= Self.audioInterruptionAttributionSeconds
            ? .audioInterruption : .externalPause
        invalidate()
        onInterruption(reason)
    }
}

#endif
