// VGHLSRateController.swift
// Per-session driver of the Debug-only LOW_LATENCY playback-rate experiment.
//
// Owns the AVPlayer measurements, the conditional rate writes, the 250 ms main
// run-loop timer, the rate-change / time-jump / status / app-inactivity observers
// and the bounded transition log. The decision itself is VGHLSRatePolicy, a pure
// value type this controller drives on the main thread.
//
// Rate ownership: VGStreamingPlaybackCoordinator owns starting (play) and pausing
// (pause / stop / teardown). This controller only adjusts an already positive rate
// between 1.00 and 1.08, and only while the player's rate is the one it expects:
// the coordinator's 1.00 before an entry, its own 1.08 before an exit. It never
// writes defaultRate and never issues a seek. Immediately before each write it
// checks that the rate is positive and the time-control status is not paused;
// those checks are conditional observations on the main thread, not an atomic
// AVPlayer read-and-write, so they bound rather than eliminate the window in which
// AVPlayer could zero the rate between the read and the write. Any rate change it
// did not request (coordinator pause, interruption, backgrounding, the native
// live-edge clamp, a failed setRate) disables the experiment for the session
// without a write; the new owner's rate is left alone.
//
// Threading: every lifecycle method and all mutable state are main-thread only.
// Observer callbacks may arrive elsewhere; they hop to the main queue and re-check
// invalidation before touching anything. After invalidate() nothing is written or
// logged, and queued callbacks do nothing.
//
// The coordinator constructs this controller in Debug builds only, for
// LOW_LATENCY sessions without a caller start position, with its own live-position
// seeks disabled, on iOS 26.4 or later. Release builds and other profiles never
// create one. Retrieval: Console.app, subsystem "com.vanguard.engine", category
// "hls-latency", records hls_rate_*.

import AVFoundation
import Foundation
import UIKit
import os

final class VGHLSRateController {

    // Same destination as VGHLSLatencyRecorder, so one Console filter shows both.
    private static let logger = Logger(subsystem: "com.vanguard.engine", category: "hls-latency")
    private static let tickIntervalSeconds: TimeInterval = 0.25
    /// Rates within this distance are the same rate.
    private static let rateTolerance: Float = 0.005
    /// Transition records per session; the cap itself is the last record written.
    private static let maxLogRecords = 256
    /// Diagnostic snapshots per session (three records each) and bytes per record.
    private static let maxDiagnosticSnapshots   = 16
    private static let maxDiagnosticRecordBytes = 700

    private let sessionId:  String
    private let player:     AVPlayer
    private let item:       AVPlayerItem
    private let stallCount: () -> Int

    private var policy = VGHLSRatePolicy(config: .experiment)

    private var timer:              Timer?
    private var started            = false
    private var invalidated        = false
    private var rateObserver:       NSObjectProtocol?
    private var timeJumpObserver:   NSObjectProtocol?
    private var inactivityObserver: NSObjectProtocol?
    private var itemStatusObservation:   NSKeyValueObservation?
    private var playerStatusObservation: NSKeyValueObservation?

    /// The rate this controller last wrote; nil before its first write. Set before
    /// the setter is invoked, so the resulting rate-change notification is
    /// recognised as its own.
    private var expectedRate: Float? = nil
    private var logRecordsEmitted = 0
    /// Exactly one hls_rate_disabled record per session, whichever path ends it.
    private var disabledRecordEmitted = false
    /// Diagnostic snapshots taken so far; bounded by maxDiagnosticSnapshots.
    private var diagnosticSnapshotsEmitted = 0

    private enum WriteGate {
        case applied
        case invalidated
        case disabled
        case itemMismatch
        case notReady
        case failed
        case rateZero
        case paused
        case ownershipMismatch
        case notPlaying
    }

    /// `stallCount` reads the session's cumulative AVPlayerItemPlaybackStalled
    /// count; it must capture the session weakly and return 0 once it is gone.
    init(sessionId: String, player: AVPlayer, item: AVPlayerItem, stallCount: @escaping () -> Int) {
        self.sessionId  = sessionId
        self.player     = player
        self.item       = item
        self.stallCount = stallCount
    }

    deinit {
        timer?.invalidate()
        removeObservers()
    }

    // MARK: - Lifecycle (main thread)

    /// Begins sampling and observing. A second call, or a call after invalidate(),
    /// is a no-op.
    func start() {
        guard !started, !invalidated else { return }
        started = true
        installObservers()

        let timer = Timer(timeInterval: Self.tickIntervalSeconds, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            self.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let config = policy.config
        emit("hls_rate_started",
             reason: "target=\(config.targetAgeMs)ms,entry=\(config.entryAgeMs)ms,rates=\(Self.fixed(config.normalRate))..\(Self.fixed(config.acceleratedRate)),tickMs=\(Int(Self.tickIntervalSeconds * 1000))",
             requestedRate: nil)
    }

    /// Called by the coordinator before a public user seek: an owned accelerated
    /// rate is set back to 1.00 (while the rate is still positive), then the
    /// experiment ends for the session so the user's chosen position is kept.
    func prepareForUserSeek() {
        guard !invalidated, !policy.isDisabled else { return }
        neutralizeOwnedAcceleration(reason: "user_seek")
        disable(reason: "user_seek")
    }

    /// Called by the coordinator before a public pause or stop. No rate write: the
    /// coordinator's own pause performs the transition to zero, and a later play()
    /// resumes at AVPlayer's default rate.
    func prepareForPauseOrStop() {
        guard !invalidated, !policy.isDisabled else { return }
        disable(reason: "pause_or_stop")
    }

    /// Cancels the timer, removes every observer and discards rate ownership.
    /// Never writes a rate. Idempotent.
    func invalidate() {
        guard !invalidated else { return }
        emit("hls_rate_invalidated", reason: policy.disabledReason ?? "teardown", requestedRate: nil)
        invalidated = true
        timer?.invalidate()
        timer = nil
        removeObservers()
        expectedRate = nil
    }

    // MARK: - Tick

    private func tick() {
        guard !invalidated, !policy.isDisabled else { return }
        let sample = measure()
        apply(policy.tick(sample), sample: sample)
    }

    private func apply(_ decision: VGHLSRateDecision, sample: VGHLSRateSample) {
        switch decision {
        case .none:
            return

        case .disable(let reason):
            disable(reason: reason, sample: sample)

        case .enterAccelerated:
            let observed = player.rate
            let gate = write(rate: policy.config.acceleratedRate,
                             overOwnedRate: policy.config.normalRate,
                             requirePlaying: true)
            switch gate {
            case .applied:
                policy.didEnterAccelerated(atMonotonicSeconds: sample.monotonicSeconds)
                emit("hls_rate_enter", reason: "age_above_entry", requestedRate: policy.config.acceleratedRate,
                     observedRate: observed, sample: sample)
            case .notPlaying, .paused:
                policy.didDeclineEntry(atMonotonicSeconds: sample.monotonicSeconds)
            case .invalidated:
                return
            default:
                disable(reason: "entry_gate_\(Self.label(gate))", sample: sample)
            }

        case .exitAccelerated(let reason, let safety):
            let observed = player.rate
            let gate = write(rate: policy.config.normalRate,
                             overOwnedRate: policy.config.acceleratedRate,
                             requirePlaying: false)
            switch gate {
            case .applied:
                policy.didExitAccelerated(atMonotonicSeconds: sample.monotonicSeconds, safety: safety)
                emit(safety ? "hls_rate_safety_exit" : "hls_rate_exit", reason: reason,
                     requestedRate: policy.config.normalRate, observedRate: observed, sample: sample)
            case .invalidated:
                return
            default:
                // The accelerated rate this controller wrote is no longer in place:
                // another owner changed it, so nothing is written over theirs.
                disable(reason: "exit_gate_\(Self.label(gate))_\(reason)", sample: sample)
            }
        }
    }

    // MARK: - Rate writes

    /// Writes `rate` only when, at this moment, the controller is live, the player
    /// still plays this ready item, the rate is positive, the time-control status
    /// is not paused, the rate equals `overOwnedRate` (so the controller is
    /// adjusting the rate it expects, not another owner's), and, when required,
    /// the player is .playing. The expected rate is recorded before the setter runs.
    /// These are sequential reads followed by a write, not an atomic operation.
    private func write(rate: Float, overOwnedRate: Float, requirePlaying: Bool) -> WriteGate {
        // Diagnostic only; reads state and logs. No decision below depends on it.
        if rate > 1.0 { captureRateDiagnostic(phase: "before_guards", requestedRate: rate) }
        guard !invalidated else { return .invalidated }
        guard !policy.isDisabled else { return .disabled }
        guard player.currentItem === item else { return .itemMismatch }
        guard item.status != .failed, player.status != .failed else { return .failed }
        guard item.status == .readyToPlay else { return .notReady }
        let observed = player.rate
        guard observed > 0 else { return .rateZero }
        let timeControl = player.timeControlStatus
        guard timeControl != .paused else { return .paused }
        guard Self.sameRate(observed, overOwnedRate) else { return .ownershipMismatch }
        if let expected = expectedRate, !Self.sameRate(expected, observed) { return .ownershipMismatch }
        if requirePlaying, timeControl != .playing { return .notPlaying }
        expectedRate = rate
        player.rate = rate
        if rate > 1.0 { captureRateDiagnostic(phase: "after_setter", requestedRate: rate) }
        return .applied
    }

    /// Sets an owned accelerated rate back to normal, if one is in place, in the
    /// playing or waiting state. Used before a user seek and on impending app
    /// inactivity; the caller disables afterwards.
    private func neutralizeOwnedAcceleration(reason: String) {
        guard policy.mode == .accelerating else { return }
        let sample = measure()
        let observed = player.rate
        let gate = write(rate: policy.config.normalRate,
                         overOwnedRate: policy.config.acceleratedRate,
                         requirePlaying: false)
        if case .applied = gate {
            policy.didExitAccelerated(atMonotonicSeconds: sample.monotonicSeconds, safety: true)
            emit("hls_rate_safety_exit", reason: reason, requestedRate: policy.config.normalRate,
                 observedRate: observed, sample: sample)
        }
    }

    /// Ends the experiment and writes its one disabled record. The policy may have
    /// disabled itself already (a failure seen in tick); the record is still written
    /// once, with the policy's own reason when it has one.
    private func disable(reason: String, sample: VGHLSRateSample? = nil) {
        guard !invalidated, !disabledRecordEmitted else { return }
        policy.disable(reason: reason)
        disabledRecordEmitted = true
        emit("hls_rate_disabled", reason: policy.disabledReason ?? reason, requestedRate: nil,
             observedRate: player.rate, sample: sample ?? measure())
    }

    // MARK: - Observers

    private func installObservers() {
        let center = NotificationCenter.default

        if #available(iOS 15.0, *) {
            rateObserver = center.addObserver(
                forName: AVPlayer.rateDidChangeNotification, object: player, queue: nil
            ) { [weak self] notification in
                let reasonRaw = notification.userInfo?[AVPlayer.rateDidChangeReasonKey] as? String
                DispatchQueue.main.async { self?.handleRateChange(reasonRaw: reasonRaw) }
            }
        } else {
            // The rate-change reason is unavailable; an external owner cannot be
            // told from the controller's own writes, so the experiment never runs.
            disable(reason: "rate_change_notification_unavailable")
        }

        timeJumpObserver = center.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: item, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.handleTimeJump() }
        }

        // Handled at once when already on the main thread, so the neutralising write
        // precedes the app's inactivity; hops to main only from elsewhere.
        inactivityObserver = center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                self?.handleWillResignActive()
            } else {
                DispatchQueue.main.async { self?.handleWillResignActive() }
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleStatusChange() }
        }
        playerStatusObservation = player.observe(\.status, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleStatusChange() }
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        if let observer = rateObserver       { center.removeObserver(observer) }
        if let observer = timeJumpObserver   { center.removeObserver(observer) }
        if let observer = inactivityObserver { center.removeObserver(observer) }
        rateObserver       = nil
        timeJumpObserver   = nil
        inactivityObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        playerStatusObservation?.invalidate()
        playerStatusObservation = nil
    }

    /// A rate change the controller requested matches expectedRate and is ignored.
    /// Before the first write every setRate is the coordinator's (play at the
    /// default rate) and is ignored too. Everything else is another owner taking
    /// the rate: the experiment ends without a write.
    @available(iOS 15.0, *)
    private func handleRateChange(reasonRaw: String?) {
        guard !invalidated, !policy.isDisabled else { return }
        let observed = player.rate
        guard let raw = reasonRaw else {
            disable(reason: "rate_change_reason_missing")
            return
        }
        let reason = AVPlayer.RateDidChangeReason(rawValue: raw)

        if #available(iOS 26.4, *), reason == .playheadReachedLiveEdge {
            disable(reason: "native_live_edge_clamp")
            return
        }
        switch reason {
        case .setRateCalled:
            if let expected = expectedRate {
                if Self.sameRate(observed, expected) { return }
                disable(reason: "external_set_rate")
            }
            // No expectation yet: the coordinator's own play/pause.
        case .setRateFailed:
            // The notification does not carry the rejected rate; the last rate this
            // controller requested stands in for it.
            captureRateDiagnostic(phase: "set_rate_failed", requestedRate: expectedRate)
            disable(reason: "set_rate_failed")
        case .audioSessionInterrupted:
            disable(reason: "audio_session_interrupted")
        case .appBackgrounded:
            disable(reason: "app_backgrounded")
        default:
            disable(reason: "rate_change_\(Self.sanitized(raw))")
        }
    }

    private func handleTimeJump() {
        guard !invalidated, !policy.isDisabled else { return }
        let sample = measure()
        apply(policy.noteTimeJump(atMonotonicSeconds: sample.monotonicSeconds), sample: sample)
    }

    /// Impending inactivity: an owned accelerated rate is set back to 1.00 while the
    /// rate is still positive, in the playing or waiting state (a stall must not
    /// leave 1.08 unsupervised); then the experiment ends for the session.
    private func handleWillResignActive() {
        guard !invalidated, !policy.isDisabled else { return }
        neutralizeOwnedAcceleration(reason: "app_will_resign_active")
        disable(reason: "app_will_resign_active")
    }

    private func handleStatusChange() {
        guard !invalidated, !policy.isDisabled else { return }
        if item.status == .failed || player.status == .failed {
            disable(reason: "playback_failed")
        }
    }

    // MARK: - Measurement (main thread)

    private func measure() -> VGHLSRateSample {
        let monotonicSeconds = CACurrentMediaTime()
        let wallDate         = Date()
        let ageMs: Int? = item.currentDate().flatMap { Self.milliseconds(wallDate.timeIntervalSince($0)) }
        let playheadSeconds  = Self.seconds(player.currentTime())
        let timeControl      = player.timeControlStatus
        let itemStatus       = item.status
        let playerStatus     = player.status
        return VGHLSRateSample(
            monotonicSeconds:          monotonicSeconds,
            wallSeconds:               wallDate.timeIntervalSince1970,
            ageMs:                     ageMs,
            contiguousForwardBufferMs: contiguousForwardBufferMs(playheadSeconds: playheadSeconds),
            isReady:                   player.currentItem === item && itemStatus == .readyToPlay && playerStatus != .failed,
            isFailed:                  itemStatus == .failed || playerStatus == .failed,
            isPlaying:                 timeControl == .playing,
            isWaiting:                 timeControl == .waitingToPlayAtSpecifiedRate,
            stallCount:                stallCount()
        )
    }

    /// Buffered media ahead of the playhead in the one valid loaded range that
    /// contains it. A disconnected later range does not count; no such range is
    /// zero; an invalid playhead is nil.
    private func contiguousForwardBufferMs(playheadSeconds: Double?) -> Int? {
        guard let playhead = playheadSeconds else { return nil }
        var bufferedEnd: Double? = nil
        for rangeValue in item.loadedTimeRanges {
            let range = rangeValue.timeRangeValue
            guard let start = Self.seconds(range.start),
                  let duration = Self.seconds(range.duration), duration > 0 else { continue }
            let end = start + duration
            guard end.isFinite, start <= playhead, playhead < end else { continue }
            bufferedEnd = max(bufferedEnd ?? end, end)
        }
        guard let end = bufferedEnd else { return 0 }
        return Self.milliseconds(end - playhead)
    }

    // MARK: - Logging (transitions only)

    private func emit(_ event: String, reason: String, requestedRate: Float?,
                      observedRate: Float? = nil, sample: VGHLSRateSample? = nil) {
        guard logRecordsEmitted < Self.maxLogRecords else { return }
        logRecordsEmitted += 1
        let capped = logRecordsEmitted == Self.maxLogRecords
        let name = capped ? "hls_rate_log_capped" : event
        let monotonicMs = Self.milliseconds(sample?.monotonicSeconds ?? CACurrentMediaTime())
        let line = "\(name) sessionId=\(sessionId) reason=\(Self.sanitized(reason))"
            + " monotonicMs=\(Self.value(monotonicMs))"
            + " ageMs=\(Self.value(sample?.ageMs))"
            + " bufferMs=\(Self.value(sample?.contiguousForwardBufferMs))"
            + " observedRate=\(observedRate.map { Self.fixed($0) } ?? "unavailable")"
            + " requestedRate=\(requestedRate.map { Self.fixed($0) } ?? "none")"
            + " expectedRate=\(expectedRate.map { Self.fixed($0) } ?? "none")"
            + " mode=\(policy.mode.rawValue)"
            + " disabled=\(policy.isDisabled)"
        Self.logger.notice("\(line, privacy: .public)")
    }

    // MARK: - Diagnostic snapshots (rejected rate requests)

    /// Diagnostic only. Writes one snapshot of what AVPlayer and the item report
    /// around a rate request above 1.0, as three hls_rate_diagnostic records (state,
    /// capabilities_rates, errors) that share a snapshotId and phase. Synchronous
    /// and read-only: it never writes a rate, seeks, or adds a timer or observer,
    /// and no decision reads it. At most maxDiagnosticSnapshots per session, nothing
    /// after invalidate(). Strings are sanitized and bounded; no URLs, headers,
    /// userInfo or localized descriptions are logged. canPlayFastForward is context,
    /// not proof that a rate is unsupported.
    private func captureRateDiagnostic(phase: String, requestedRate: Float?) {
        guard !invalidated, diagnosticSnapshotsEmitted < Self.maxDiagnosticSnapshots else { return }
        diagnosticSnapshotsEmitted += 1
        let snapshotId = diagnosticSnapshotsEmitted

        let sample        = measure()
        let observedRate  = player.rate
        let waitingReason = player.reasonForWaitingToPlay.map { Self.sanitized($0.rawValue) } ?? "none"

        let state: [String] = [
            "wallMs=\(Self.value(Self.milliseconds(sample.wallSeconds)))",
            "monotonicMs=\(Self.value(Self.milliseconds(sample.monotonicSeconds)))",
            "mode=\(policy.mode.rawValue)",
            "playerStatus=\(Self.playerStatusLabel(player.status))",
            "itemStatus=\(Self.itemStatusLabel(item.status))",
            "currentItemMatch=\(player.currentItem === item)",
            "timeControl=\(Self.timeControlLabel(player.timeControlStatus))",
            "waitingReason=\(waitingReason)",
            "ageMs=\(Self.value(sample.ageMs))",
            "bufferMs=\(Self.value(sample.contiguousForwardBufferMs))",
            "playbackBufferEmpty=\(item.isPlaybackBufferEmpty)",
            "playbackLikelyToKeepUp=\(item.isPlaybackLikelyToKeepUp)",
        ]

        var rates: [String] = [
            "requestedRate=\(requestedRate.map { Self.fixed(Double($0), 3) } ?? "none")",
            "observedRate=\(Self.fixed(Double(observedRate), 3))",
            "expectedRate=\(expectedRate.map { Self.fixed(Double($0), 3) } ?? "none")",
            "audioTimePitch=\(Self.sanitized(item.audioTimePitchAlgorithm.rawValue))",
            "canPlayFastForward=\(item.canPlayFastForward)",
            "canPlaySlowForward=\(item.canPlaySlowForward)",
            "duration=\(Self.durationState(item.duration))",
        ]
        if let timebase = item.timebase {
            rates.append("timebase=present")
            rates.append("timebaseRate=\(Self.fixed(CMTimebaseGetRate(timebase), 3))")
            rates.append("timebaseEffectiveRate=\(Self.fixed(CMTimebaseGetEffectiveRate(timebase), 3))")
        } else {
            rates.append("timebase=absent")
            rates.append("timebaseRate=unavailable")
            rates.append("timebaseEffectiveRate=unavailable")
        }
        rates.append("configuredLiveOffsetMs=\(Self.value(Self.milliseconds(Self.seconds(item.configuredTimeOffsetFromLive))))")
        rates.append("recommendedLiveOffsetMs=\(Self.value(Self.milliseconds(Self.seconds(item.recommendedTimeOffsetFromLive))))")

        let errors = Self.errorTokens("player", player.error) + Self.errorTokens("item", item.error)

        emitDiagnosticRecord(snapshotId: snapshotId, phase: phase, kind: "state", tokens: state)
        emitDiagnosticRecord(snapshotId: snapshotId, phase: phase, kind: "capabilities_rates", tokens: rates)
        emitDiagnosticRecord(snapshotId: snapshotId, phase: phase, kind: "errors", tokens: errors)
    }

    /// One diagnostic record of at most maxDiagnosticRecordBytes. Tokens that would
    /// not fit are dropped and counted, so a record is never cut mid-token.
    private func emitDiagnosticRecord(snapshotId: Int, phase: String, kind: String, tokens: [String]) {
        var line = "hls_rate_diagnostic sessionId=\(Self.sanitized(sessionId)) snapshotId=\(snapshotId) phase=\(phase) record=\(kind)"
        // Room kept for " truncatedTokens=NN".
        let budget = Self.maxDiagnosticRecordBytes - 24
        var dropped = 0
        for token in tokens {
            if line.utf8.count + 1 + token.utf8.count > budget {
                dropped += 1
            } else {
                line += " " + token
            }
        }
        if dropped > 0 { line += " truncatedTokens=\(dropped)" }
        Self.logger.notice("\(line, privacy: .public)")
    }

    // MARK: - Helpers

    private static func sameRate(_ a: Float, _ b: Float) -> Bool {
        return abs(a - b) <= rateTolerance
    }

    private static func playerStatusLabel(_ status: AVPlayer.Status) -> String {
        switch status {
        case .unknown:      return "unknown"
        case .readyToPlay:  return "readyToPlay"
        case .failed:       return "failed"
        @unknown default:   return "unrecognized"
        }
    }

    private static func itemStatusLabel(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown:      return "unknown"
        case .readyToPlay:  return "readyToPlay"
        case .failed:       return "failed"
        @unknown default:   return "unrecognized"
        }
    }

    private static func timeControlLabel(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .playing:                      return "playing"
        case .waitingToPlayAtSpecifiedRate: return "waitingToPlayAtSpecifiedRate"
        case .paused:                       return "paused"
        @unknown default:                   return "unrecognized"
        }
    }

    /// Whether a CMTime is numeric, indefinite or otherwise not a finite time.
    private static func durationState(_ time: CMTime) -> String {
        if !time.isValid            { return "invalid" }
        if time.isIndefinite        { return "indefinite" }
        if time.isPositiveInfinity  { return "positiveInfinity" }
        if time.isNegativeInfinity  { return "negativeInfinity" }
        return "numeric"
    }

    /// Domain and code of an error and of one underlying NSError, nothing else. A
    /// missing error is written as nil rather than left out.
    private static func errorTokens(_ label: String, _ error: Error?) -> [String] {
        guard let error = error else { return ["\(label)Error=nil"] }
        let nsError = error as NSError
        var tokens = [
            "\(label)ErrorDomain=\(sanitized(nsError.domain))",
            "\(label)ErrorCode=\(nsError.code)",
        ]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            tokens.append("\(label)UnderlyingDomain=\(sanitized(underlying.domain))")
            tokens.append("\(label)UnderlyingCode=\(underlying.code)")
        } else {
            tokens.append("\(label)Underlying=nil")
        }
        return tokens
    }

    private static func fixed(_ number: Double, _ precision: Int) -> String {
        guard number.isFinite else { return "unavailable" }
        return String(format: "%.\(precision)f", number)
    }

    private static func label(_ gate: WriteGate) -> String {
        switch gate {
        case .applied:           return "applied"
        case .invalidated:       return "invalidated"
        case .disabled:          return "disabled"
        case .itemMismatch:      return "item_mismatch"
        case .notReady:          return "not_ready"
        case .failed:            return "failed"
        case .rateZero:          return "rate_zero"
        case .paused:            return "paused"
        case .ownershipMismatch: return "ownership_mismatch"
        case .notPlaying:        return "not_playing"
        }
    }

    /// Seconds of a valid, finite, non-indefinite CMTime; otherwise nil.
    private static func seconds(_ time: CMTime) -> Double? {
        guard time.isNumeric else { return nil }
        let value = time.seconds
        return value.isFinite ? value : nil
    }

    /// Whole milliseconds, signed; nil for a nonfinite or implausibly large value.
    private static func milliseconds(_ seconds: Double?) -> Int? {
        guard let seconds = seconds, seconds.isFinite else { return nil }
        let ms = (seconds * 1000).rounded()
        guard abs(ms) < 1.0e15 else { return nil }
        return Int(ms)
    }

    private static func value(_ number: Int?) -> String {
        guard let number = number else { return "unavailable" }
        return String(number)
    }

    private static func fixed(_ rate: Float) -> String {
        guard rate.isFinite else { return "unavailable" }
        return String(format: "%.2f", rate)
    }

    /// Printable ASCII only, no spaces or semicolons, at most 60 characters.
    private static func sanitized(_ text: String) -> String {
        let kept = text.unicodeScalars.compactMap { scalar -> Character? in
            let v = scalar.value
            guard v > 0x20, v <= 0x7E, v != 0x3B else { return nil }
            return Character(scalar)
        }
        let result = String(kept.prefix(60))
        return result.isEmpty ? "unknown" : result
    }
}
