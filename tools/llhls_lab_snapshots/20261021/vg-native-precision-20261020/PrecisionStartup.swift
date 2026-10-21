import Foundation
import AVFoundation
import CoreMedia

/// PrecisionStartup manages the decoder preroll and synchronized normal-speed start
/// transaction on AVPlayer and AVPlayerItem for HTTP Live Streaming.
final class PrecisionStartup {
    enum State: String {
        case waitingReady
        case prerolling
        case starting
        case started
        case terminal
    }

    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private let emitClosure: ([String: Any]) throws -> Void
    private let failClosure: (String) -> Void

    private(set) var didIssueStart: Bool = false
    private(set) var state: State = .waitingReady
    private var deadlineMonoMs: UInt64 = 0

    init(
        player: AVPlayer,
        item: AVPlayerItem,
        emit: @escaping ([String: Any]) throws -> Void,
        fail: @escaping (String) -> Void
    ) {
        self.player = player
        self.item = item
        self.emitClosure = emit
        self.failClosure = fail
        self.state = .waitingReady
        self.deadlineMonoMs = getMonotonicMs() + 5000 // 5s deadline for waitingReady
    }

    func cancel() {
        guard state != .terminal else { return }
        state = .terminal
        player?.cancelPendingPrerolls()
        player = nil
        item = nil
    }

    private func failWithReason(_ reason: String) {
        guard state != .terminal else { return }
        state = .terminal
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let failRecord: [String: Any] = [
            "event": "precision_failed",
            "utc": iso.string(from: Date()),
            "observation_mono_ms": getMonotonicMs(),
            "reason": reason
        ]
        try? emitClosure(failRecord)
        player?.cancelPendingPrerolls()
        player = nil
        item = nil
        failClosure(reason)
    }

    func tick() {
        guard Thread.isMainThread else {
            failWithReason("PrecisionStartup.tick() called outside main thread")
            return
        }
        guard state != .terminal, state != .started else { return }

        guard let p = player, let it = item else {
            failWithReason("Player or item deallocated during tick in state \(state.rawValue)")
            return
        }
        guard p.currentItem === it else {
            failWithReason("currentItem mismatch during tick in state \(state.rawValue)")
            return
        }
        guard p.status != .failed && it.status != .failed else {
            failWithReason("Player or item entered failed status during tick in state \(state.rawValue)")
            return
        }

        let nowMono = getMonotonicMs()
        if nowMono > deadlineMonoMs {
            failWithReason("Deadline exceeded in state \(state.rawValue)")
            return
        }

        switch state {
        case .waitingReady:
            if p.status == .readyToPlay && it.status == .readyToPlay && p.rate == 0.0 {
                // Set state and deadline BEFORE event emission
                self.state = .prerolling
                self.deadlineMonoMs = getMonotonicMs() + 3000 // 3s deadline for preroll

                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let reqRecord: [String: Any] = [
                    "event": "preroll_requested",
                    "utc": iso.string(from: Date()),
                    "observation_mono_ms": getMonotonicMs()
                ]
                do {
                    try self.emitClosure(reqRecord)
                } catch {
                    self.failWithReason("Emit preroll_requested failed: \(error)")
                    return
                }

                // Recheck state, identity, readiness, and deadline after event and before public call
                guard self.state == .prerolling else { return }
                guard let pPreroll = self.player, let itPreroll = self.item, pPreroll.currentItem === itPreroll else {
                    self.failWithReason("Player or item mismatch/deallocated after preroll_requested emit")
                    return
                }
                guard pPreroll.status == .readyToPlay, itPreroll.status == .readyToPlay else {
                    self.failWithReason("Player or item status not readyToPlay after preroll_requested emit")
                    return
                }
                guard pPreroll.rate == 0.0 else {
                    self.failWithReason("Player rate not 0.0 after preroll_requested emit")
                    return
                }
                if getMonotonicMs() > self.deadlineMonoMs {
                    self.failWithReason("Preroll deadline exceeded before preroll call")
                    return
                }

                pPreroll.preroll(atRate: 1.0) { [weak self] finished in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        // Ignore stale, terminal, or state mismatch callbacks
                        guard self.state == .prerolling else { return }
                        let cbMono = getMonotonicMs()
                        // Enforce existing preroll deadline before acting
                        if cbMono > self.deadlineMonoMs {
                            self.failWithReason("Preroll deadline exceeded before callback action (\(cbMono) > \(self.deadlineMonoMs))")
                            return
                        }
                        if !finished {
                            self.failWithReason("Preroll finished with false (interrupted or failed)")
                            return
                        }

                        let completedRecord: [String: Any] = [
                            "event": "preroll_completed",
                            "utc": iso.string(from: Date()),
                            "observation_mono_ms": cbMono,
                            "finished": finished
                        ]
                        do {
                            try self.emitClosure(completedRecord)
                        } catch {
                            self.failWithReason("Emit preroll_completed failed: \(error)")
                            return
                        }

                        guard self.state == .prerolling else { return }
                        self.handlePrerollSuccess()
                    }
                }
            }

        case .prerolling:
            // Waiting for preroll completion callback; deadline handled above
            break

        case .starting:
            let effRate: Double = (it.timebase != nil) ? CMTimebaseGetEffectiveRate(it.timebase!) : 0.0
            let isPlaying = (p.timeControlStatus == .playing)
            if isPlaying && effRate.isFinite && abs(effRate - 1.0) <= 0.005 {
                self.state = .started
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let startedRecord: [String: Any] = [
                    "event": "precision_started",
                    "utc": iso.string(from: Date()),
                    "observation_mono_ms": getMonotonicMs(),
                    "time_control_status": "playing",
                    "effective_rate": effRate,
                    "automatically_waits_to_minimize_stalling": p.automaticallyWaitsToMinimizeStalling
                ]
                do {
                    try self.emitClosure(startedRecord)
                } catch {
                    self.failWithReason("Emit precision_started failed: \(error)")
                }
            }

        case .started, .terminal:
            break
        }
    }

    private func handlePrerollSuccess() {
        guard state == .prerolling else { return }
        let handleMono = getMonotonicMs()
        if handleMono > deadlineMonoMs {
            failWithReason("Preroll deadline exceeded entering handlePrerollSuccess")
            return
        }

        guard let p = player, let it = item, p.currentItem === it else {
            failWithReason("Player or item mismatch/deallocated upon preroll completion")
            return
        }
        guard p.status == .readyToPlay, it.status == .readyToPlay else {
            failWithReason("Player or item status not readyToPlay upon preroll completion")
            return
        }
        guard p.rate == 0.0 else {
            failWithReason("Player rate is not 0.0 upon preroll completion (got \(p.rate))")
            return
        }

        let t1Mono = getMonotonicMs()
        let t1 = it.currentTime()
        guard let d = it.currentDate() else {
            failWithReason("item.currentDate() returned nil upon preroll completion")
            return
        }
        let t2 = it.currentTime()
        let t2Mono = getMonotonicMs()
        guard (t2Mono - t1Mono) <= 5 else {
            failWithReason("currentTime reread exceeded 5ms limit (\(t2Mono - t1Mono)ms)")
            return
        }
        guard t1.isValid, !t1.isIndefinite, t1.isNumeric, t1.seconds.isFinite else {
            failWithReason("currentTime T1 is not finite numeric: \(t1.seconds)")
            return
        }
        guard t2.isValid, !t2.isIndefinite, t2.isNumeric, t2.seconds.isFinite else {
            failWithReason("currentTime T2 is not finite numeric: \(t2.seconds)")
            return
        }
        guard abs(t2.seconds - t1.seconds) <= 0.005 else {
            failWithReason("currentTime delta abs(T2 - T1) > 0.005s (T1=\(t1.seconds), T2=\(t2.seconds))")
            return
        }

        let t = t2
        let nowDate = Date()
        let pdtAge = nowDate.timeIntervalSince(d)
        guard pdtAge.isFinite, !pdtAge.isNaN else {
            failWithReason("PDT age is not finite: \(pdtAge)")
            return
        }
        let delta = max(0.0, pdtAge - 1.2)
        let targetSeconds = t.seconds + delta

        guard targetSeconds.isFinite, targetSeconds > 0 else {
            failWithReason("Target seconds is not finite positive: \(targetSeconds)")
            return
        }

        var loadedRangesData: [[String: Double]] = []
        var targetContainedInLoadedRange = false
        let requiredLoadedEnd = targetSeconds + 0.350

        for val in it.loadedTimeRanges {
            let range = val.timeRangeValue
            let s = range.start.seconds
            let dur = range.duration.seconds
            let e = range.end.seconds
            guard s.isFinite, dur.isFinite, e.isFinite, s >= 0, dur > 0 else { continue }
            loadedRangesData.append(["start": s, "duration": dur, "end": e])
            if s <= targetSeconds && requiredLoadedEnd <= e {
                targetContainedInLoadedRange = true
            }
        }

        var seekableRangesData: [[String: Double]] = []
        for val in it.seekableTimeRanges {
            let range = val.timeRangeValue
            let s = range.start.seconds
            let dur = range.duration.seconds
            let e = range.end.seconds
            guard s.isFinite, dur.isFinite, e.isFinite else { continue }
            seekableRangesData.append(["start": s, "duration": dur, "end": e])
        }

        guard targetContainedInLoadedRange else {
            failWithReason("Target range [\(targetSeconds)..\(requiredLoadedEnd)] not contained in any finite positive loaded range: \(loadedRangesData)")
            return
        }

        guard let p2 = self.player, let it2 = self.item, p2.currentItem === it2 else {
            failWithReason("Player or item ownership invalidated before precision_requested")
            return
        }
        guard p2.status == .readyToPlay, it2.status == .readyToPlay else {
            failWithReason("Player or item status not readyToPlay before precision_requested")
            return
        }
        guard p2.rate == 0.0 else {
            failWithReason("Player rate not 0.0 before precision_requested")
            return
        }

        self.state = .starting
        self.deadlineMonoMs = getMonotonicMs() + 1500 // 1.5s deadline for starting state

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let reqRecord: [String: Any] = [
            "event": "precision_requested",
            "utc": iso.string(from: nowDate),
            "observation_mono_ms": getMonotonicMs(),
            "target_item_time_seconds": targetSeconds,
            "currentTime_seconds": t.seconds,
            "pdt_age_seconds": pdtAge,
            "delta_seconds": delta,
            "loaded_ranges": loadedRangesData,
            "seekable_ranges": seekableRangesData
        ]
        do {
            try self.emitClosure(reqRecord)
        } catch {
            failWithReason("Emit precision_requested failed: \(error)")
            return
        }

        // After throwing emit recheck state, identity, ready statuses, rate0, and deadline immediately before autoWaits/setRate
        guard self.state == .starting else { return }
        guard let p3 = self.player, let it3 = self.item, p3.currentItem === it3 else {
            failWithReason("Player or item identity changed after precision_requested emit")
            return
        }
        guard p3.status == .readyToPlay, it3.status == .readyToPlay else {
            failWithReason("Player or item status not readyToPlay after precision_requested emit")
            return
        }
        guard p3.rate == 0.0 else {
            failWithReason("Player rate not 0.0 after precision_requested emit (got \(p3.rate))")
            return
        }
        if getMonotonicMs() > self.deadlineMonoMs {
            failWithReason("Starting deadline exceeded before autoWaits/setRate")
            return
        }

        // Set autoWaits=false and verify
        p3.automaticallyWaitsToMinimizeStalling = false
        guard p3.automaticallyWaitsToMinimizeStalling == false else {
            failWithReason("Verification of automaticallyWaitsToMinimizeStalling == false failed")
            return
        }

        // Exactly setRate(1.0, time: target, atHostTime: hostTime + 0.050s)
        self.didIssueStart = true
        let targetCMTime = CMTime(seconds: targetSeconds, preferredTimescale: t.timescale > 0 ? t.timescale : 1000)
        let hostClock = CMClockGetHostTimeClock()
        let hostNow = CMClockGetTime(hostClock)
        let hostOffset = CMTime(seconds: 0.050, preferredTimescale: 1_000_000_000)
        let atHostTime = hostNow + hostOffset

        p3.setRate(1.0, time: targetCMTime, atHostTime: atHostTime)

        let retRecord: [String: Any] = [
            "event": "precision_returned",
            "utc": iso.string(from: Date()),
            "observation_mono_ms": getMonotonicMs(),
            "target_item_time_seconds": targetSeconds,
            "host_clock_time_seconds": atHostTime.seconds,
            "automatically_waits_to_minimize_stalling": p3.automaticallyWaitsToMinimizeStalling
        ]
        do {
            try self.emitClosure(retRecord)
        } catch {
            failWithReason("Emit precision_returned failed: \(error)")
            return
        }
    }
}
