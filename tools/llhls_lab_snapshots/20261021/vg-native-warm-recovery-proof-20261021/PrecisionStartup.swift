import Foundation
import AVFoundation
import CoreMedia

/// PrecisionStartup manages the warm play gate, pause, decoder preroll,
/// bounded forward buffer coverage waiting, and synchronized normal-speed start transaction
/// on AVPlayer and AVPlayerItem for HTTP Live Streaming.
final class PrecisionStartup {
    enum State: String {
        case warming = "warming"
        case waitingReady = "waitingReady"
        case prerolling = "prerolling"
        case waitingCoverage = "waitingCoverage"
        case starting = "starting"
        case started = "started"
        case terminal = "terminal"
    }

    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private let emitClosure: ([String: Any]) throws -> Void
    private let failClosure: (String) -> Void

    private(set) var didIssueStart: Bool = false
    private(set) var state: State = .warming

    // Absolute ready deadline established at init (never restarted/extended at pause)
    private let readyTimeoutMs: UInt64
    private let overallDeadlineMonoMs: UInt64
    private var deadlineMonoMs: UInt64 = 0

    // Frame tracking for warming gate (requires 2 strictly advancing valid frames)
    private var consecutiveAdvancingFrames: Int = 0
    private var lastObservedFrameId: UInt32 = 0
    private var lastObservedSourceMonoMs: UInt64 = 0
    private var lastObservedDisplayTimeSec: Double = -1.0

    private var firstGatedFrameId: UInt32 = 0
    private var secondGatedFrameId: UInt32 = 0
    private var secondGatedSourceMonoMs: UInt64 = 0
    private var secondGatedDisplayTime: CMTime = .invalid
    private var secondGatedObsMonoMs: UInt64 = 0

    // Alignment target & tracking for starting -> started completion
    private var alignTargetSeconds: Double = 0.0
    private var alignTargetCMTime: CMTime = .invalid
    private var alignIssuedFrameId: UInt32 = 0
    private var completedAdvancingCount: Int = 0
    private var lastCompletedFrameId: UInt32 = 0
    private var lastCompletedSourceMonoMs: UInt64 = 0
    private var lastCompletedDisplayTimeSec: Double = -1.0

    // Coverage wait diagnostics
    private var didEmitCoverageWaitStarted: Bool = false
    private var lastCoverageWaitSampleMonoMs: UInt64 = 0
    private var coverageWaitStartMonoMs: UInt64 = 0

    // Warm buffer wait diagnostics
    private var didEmitWarmBufferWaitStarted: Bool = false
    private var lastWarmBufferWaitSampleMonoMs: UInt64 = 0

    init(
        player: AVPlayer,
        item: AVPlayerItem,
        readyTimeoutMs: UInt64 = 10_000,
        emit: @escaping ([String: Any]) throws -> Void,
        fail: @escaping (String) -> Void
    ) {
        self.player = player
        self.item = item
        self.readyTimeoutMs = readyTimeoutMs
        self.emitClosure = emit
        self.failClosure = fail
        self.state = .warming
        let nowMono = getMonotonicMs()
        self.overallDeadlineMonoMs = nowMono + readyTimeoutMs
        self.deadlineMonoMs = self.overallDeadlineMonoMs
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
        let failedState = state
        state = .terminal

        let p = player; let it = item
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date(); let nowMono = getMonotonicMs()

        let playerStatusStr = (p?.status == .readyToPlay) ? "readyToPlay" : ((p?.status == .failed) ? "failed" : "unknown")
        let itemStatusStr = (it?.status == .readyToPlay) ? "readyToPlay" : ((it?.status == .failed) ? "failed" : "unknown")
        let playerErrorObj: Any = (p?.error as NSError?).map { ["domain": $0.domain, "code": $0.code, "description": $0.localizedDescription] } ?? NSNull()
        let itemErrorObj: Any = (it?.error as NSError?).map { ["domain": $0.domain, "code": $0.code, "description": $0.localizedDescription] } ?? NSNull()
        let identityMatch = (p != nil && it != nil && p!.currentItem === it!)
        let rateObj: Any = p.map { Double($0.rate) } ?? NSNull()
        let timeControlObj: Any = (p?.timeControlStatus == .playing) ? "playing" : ((p?.timeControlStatus == .paused) ? "paused" : ((p?.timeControlStatus == .waitingToPlayAtSpecifiedRate) ? "waiting" : "unknown"))

        var currentTimeObj: Any = NSNull()
        if let itObj = it {
            let ct = itObj.currentTime()
            if ct.isValid && !ct.isIndefinite && ct.isNumeric && ct.seconds.isFinite { currentTimeObj = ct.seconds }
        }
        let currentDateObj: Any = it?.currentDate().map { iso.string(from: $0) } ?? NSNull()

        var loadedRangesData: [[String: Double]] = []
        if let itObj = it {
            for val in itObj.loadedTimeRanges {
                let range = val.timeRangeValue
                let s = range.start.seconds, dur = range.duration.seconds, e = range.end.seconds
                if s.isFinite && dur.isFinite && e.isFinite {
                    loadedRangesData.append(["start": s, "duration": dur, "end": e])
                }
            }
        }

        let failRecord: [String: Any] = [
            "event": "alignment_failed", "utc": iso.string(from: now), "observation_mono_ms": nowMono,
            "reason": reason, "helper_state": failedState.rawValue,
            "overall_deadline_mono_ms": overallDeadlineMonoMs, "deadline_mono_ms": deadlineMonoMs,
            "avplayer_status": playerStatusStr, "item_status": itemStatusStr, "player_status": playerStatusStr,
            "player_error": playerErrorObj, "item_error": itemErrorObj, "identity_match": identityMatch,
            "rate": rateObj, "time_control_status": timeControlObj, "current_time_seconds": currentTimeObj,
            "current_date": currentDateObj, "loaded_ranges": loadedRangesData
        ]

        do {
            try emitClosure(failRecord)
        } catch {
            fputs("[PrecisionStartup] Emit alignment_failed failed: \(error)\n", stderr)
        }

        p?.cancelPendingPrerolls()
        player = nil
        item = nil
        failClosure(reason)
    }

    /// Tests whether targetSeconds through targetSeconds + requiredAheadSeconds is entirely contained
    /// inside ONE finite positive nonnegative loaded time range.
    static func hasLoadedCoverage(targetSeconds: Double, ranges: [CMTimeRange], requiredAheadSeconds: Double = 0.350) -> Bool {
        guard requiredAheadSeconds.isFinite, !requiredAheadSeconds.isNaN, requiredAheadSeconds > 0.0 else { return false }
        guard targetSeconds.isFinite, !targetSeconds.isNaN, targetSeconds >= 0.0 else { return false }
        let requiredEnd = targetSeconds + requiredAheadSeconds
        guard requiredEnd.isFinite, !requiredEnd.isNaN else { return false }
        for range in ranges {
            let s = range.start.seconds, dur = range.duration.seconds, e = range.end.seconds
            guard s.isFinite, !s.isNaN, dur.isFinite, !dur.isNaN, e.isFinite, !e.isNaN, s >= 0.0, dur > 0.0 else { continue }
            if s <= targetSeconds && requiredEnd <= e { return true }
        }
        return false
    }

    func observeFrame(
        frameId: UInt32,
        sourceMonoMs: UInt64,
        displayTime: CMTime,
        observationMonoMs: UInt64,
        playingAtRate1: Bool
    ) {
        guard Thread.isMainThread else { failWithReason("observeFrame called outside main thread"); return }
        guard state != .terminal, state != .started else { return }

        if observationMonoMs > overallDeadlineMonoMs {
            failWithReason("Overall gate deadline exceeded (mono=\(observationMonoMs), limit=\(overallDeadlineMonoMs))")
            return
        }

        let isDisplayValid = displayTime.isValid && !displayTime.isIndefinite && displayTime.isNumeric && displayTime.seconds.isFinite

        switch state {
        case .warming:
            // In warming count 2 strictly increasing frame/source/display timestamps with valid eligible frames at requested/effective 1 ±.005.
            // Reset on bad/nonplaying observations. observeFrame MUST NOT mutate player.
            guard playingAtRate1 && isDisplayValid else {
                consecutiveAdvancingFrames = 0; lastObservedFrameId = 0; lastObservedSourceMonoMs = 0; lastObservedDisplayTimeSec = -1.0
                return
            }

            let dispSec = displayTime.seconds
            if consecutiveAdvancingFrames > 0 {
                let advancing = (frameId > lastObservedFrameId) && (sourceMonoMs > lastObservedSourceMonoMs) && (dispSec > lastObservedDisplayTimeSec)
                if !advancing {
                    consecutiveAdvancingFrames = 0; lastObservedFrameId = 0; lastObservedSourceMonoMs = 0; lastObservedDisplayTimeSec = -1.0
                    return
                }
            }

            consecutiveAdvancingFrames += 1
            lastObservedFrameId = frameId; lastObservedSourceMonoMs = sourceMonoMs; lastObservedDisplayTimeSec = dispSec

            if consecutiveAdvancingFrames == 1 {
                firstGatedFrameId = frameId
            } else if consecutiveAdvancingFrames >= 2 {
                secondGatedFrameId = frameId; secondGatedSourceMonoMs = sourceMonoMs
                secondGatedDisplayTime = displayTime; secondGatedObsMonoMs = observationMonoMs
            }

        case .waitingReady, .prerolling, .waitingCoverage:
            // observeFrame does not advance state during pause, preroll, or coverage wait
            break

        case .starting:
            // Completion requires 2 NEW strictly advancing eligible normal-rate frames display >= stored target - .050
            if observationMonoMs > deadlineMonoMs {
                failWithReason("Starting deadline 1500ms exceeded in state starting")
                return
            }
            guard playingAtRate1 && isDisplayValid else {
                completedAdvancingCount = 0
                return
            }

            let dispSec = displayTime.seconds
            let isNew = (frameId > alignIssuedFrameId)
            let isAdvancing = (completedAdvancingCount == 0)
                ? isNew
                : (isNew && frameId > lastCompletedFrameId && sourceMonoMs > lastCompletedSourceMonoMs && dispSec > lastCompletedDisplayTimeSec)
            let isAtOrPastTarget = (dispSec >= (alignTargetSeconds - 0.050))

            if isAdvancing && isAtOrPastTarget {
                completedAdvancingCount += 1
                lastCompletedFrameId = frameId; lastCompletedSourceMonoMs = sourceMonoMs; lastCompletedDisplayTimeSec = dispSec

                if completedAdvancingCount >= 2 {
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let compRecord: [String: Any] = [
                        "event": "alignment_completed",
                        "utc": iso.string(from: Date()),
                        "observation_mono_ms": observationMonoMs,
                        "target_seconds": alignTargetSeconds,
                        "completed_frame_id": frameId,
                        "completed_source_mono_ms": sourceMonoMs,
                        "completed_display_time_seconds": dispSec
                    ]
                    do {
                        try emitClosure(compRecord)
                    } catch {
                        failWithReason("Emit alignment_completed failed: \(error)")
                        return
                    }
                    self.state = .started
                }
            } else {
                completedAdvancingCount = 0
            }

        case .started, .terminal:
            break
        }
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
        case .warming:
            guard consecutiveAdvancingFrames >= 2 else { return }

            // NEXT tick after gate rechecks both ready statuses, currentItem identity,
            // normal playing/effective/requested1, deadline, then pauses ONCE.
            guard p.status == .readyToPlay, it.status == .readyToPlay else {
                failWithReason("Player or item not readyToPlay at warmup gate")
                return
            }
            guard p.timeControlStatus == .playing else {
                failWithReason("Player not playing at warmup gate (status=\(p.timeControlStatus.rawValue))")
                return
            }
            let reqRate = Double(p.rate)
            guard reqRate.isFinite, abs(reqRate - 1.0) <= 0.005 else {
                failWithReason("Player requested rate not 1.0 at warmup gate (got \(p.rate))")
                return
            }
            guard let tb = it.timebase else {
                failWithReason("Item timebase missing at warmup gate")
                return
            }
            let effRate = CMTimebaseGetEffectiveRate(tb)
            guard effRate.isFinite, abs(effRate - 1.0) <= 0.005 else {
                failWithReason("Effective timebase rate not 1.0 at warmup gate (got \(effRate))")
                return
            }
            guard nowMono <= overallDeadlineMonoMs else {
                failWithReason("Deadline exceeded before pause in state warming")
                return
            }

            // Capture currentTime / currentDate / currentTime within 5ms, both finite and difference <= 0.005
            let t1Mono = getMonotonicMs(), t1 = it.currentTime(), dOpt = it.currentDate(), t2 = it.currentTime(), t2Mono = getMonotonicMs()
            var mappingAvailable = false, targetSeconds: Double = -1.0, quantizedTarget: Double = -1.0
            var finiteTarget: CMTime = .invalid, pdtAge: Double = -1.0, delta: Double = 0.0
            let nowDate = Date()

            if let d = dOpt, (t2Mono - t1Mono) <= 5,
               t1.isValid && !t1.isIndefinite && t1.isNumeric && t1.seconds.isFinite,
               t2.isValid && !t2.isIndefinite && t2.isNumeric && t2.seconds.isFinite,
               abs(t2.seconds - t1.seconds) <= 0.005 {
                let age = nowDate.timeIntervalSince(d)
                if age.isFinite && !age.isNaN {
                    pdtAge = age; delta = max(0.0, pdtAge - 1.2)
                    let candTarget = t2.seconds + delta
                    if candTarget.isFinite && candTarget > 0.0 {
                        targetSeconds = candTarget
                        let timescale = t2.timescale > 0 ? t2.timescale : 1000
                        finiteTarget = CMTime(seconds: candTarget, preferredTimescale: timescale)
                        quantizedTarget = finiteTarget.seconds
                        mappingAvailable = true
                    }
                }
            }

            let loadedCMTimeRanges = it.loadedTimeRanges.map { $0.timeRangeValue }
            var loadedRangesData: [[String: Double]] = []
            for range in loadedCMTimeRanges {
                let s = range.start.seconds, dur = range.duration.seconds, e = range.end.seconds
                if s.isFinite && dur.isFinite && e.isFinite {
                    loadedRangesData.append(["start": s, "duration": dur, "end": e])
                }
            }

            let hasCoverage = mappingAvailable && PrecisionStartup.hasLoadedCoverage(
                targetSeconds: quantizedTarget,
                ranges: loadedCMTimeRanges,
                requiredAheadSeconds: 0.500
            )

            // Mapping unavailable or coverage insufficient: KEEP normal playing;
            // DO NOT pause/preroll/extend initdeadline. Emit warm_buffer_wait_started once then warm_buffer_wait_sample <=4Hz.
            if !hasCoverage {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let targetObj: Any = mappingAvailable ? quantizedTarget : NSNull()
                let currentTimeObj: Any = (t2.isValid && t2.seconds.isFinite) ? t2.seconds : NSNull()
                let currentDateObj: Any = dOpt.map { iso.string(from: $0) } ?? NSNull()
                let pdtAgeObj: Any = mappingAvailable ? pdtAge : NSNull()
                let deltaObj: Any = mappingAvailable ? delta : NSNull()

                var waitRecord: [String: Any] = [
                    "event": "warm_buffer_wait_started", "utc": iso.string(from: nowDate), "observation_mono_ms": nowMono,
                    "target_item_time_seconds": targetObj, "target_seconds": targetObj, "currentTime_seconds": currentTimeObj,
                    "current_date": currentDateObj, "mapping_available": mappingAvailable, "pdt_age_seconds": pdtAgeObj,
                    "delta_seconds": deltaObj, "loaded_ranges": loadedRangesData, "required_ahead_ms": 500, "warm_required_ahead_ms": 500
                ]
                if !didEmitWarmBufferWaitStarted {
                    didEmitWarmBufferWaitStarted = true
                    lastWarmBufferWaitSampleMonoMs = nowMono
                    do { try emitClosure(waitRecord) } catch { failWithReason("Emit warm_buffer_wait_started failed: \(error)"); return }
                } else if (nowMono - lastWarmBufferWaitSampleMonoMs) >= 250 {
                    lastWarmBufferWaitSampleMonoMs = nowMono
                    waitRecord["event"] = "warm_buffer_wait_sample"
                    do { try emitClosure(waitRecord) } catch { failWithReason("Emit warm_buffer_wait_sample failed: \(error)"); return }
                }
                return
            }

            // Once coverage present, recheck identity/both ready/normal requested+effective rate/deadline
            // and fresh loaded ranges for actual target + .500 immediately before entering waitingReady and existing single pause.
            guard let pPause = self.player, let itPause = self.item, pPause.currentItem === itPause else {
                failWithReason("Player or item mismatch/deallocated before warmup_paused"); return
            }
            guard pPause.status == .readyToPlay, itPause.status == .readyToPlay else {
                failWithReason("Player or item not readyToPlay before warmup_paused"); return
            }
            guard pPause.timeControlStatus == .playing else {
                failWithReason("Player not playing before warmup_paused (status=\(pPause.timeControlStatus.rawValue))"); return
            }
            let reqRatePause = Double(pPause.rate)
            guard reqRatePause.isFinite, abs(reqRatePause - 1.0) <= 0.005 else {
                failWithReason("Player requested rate not 1.0 before warmup_paused (got \(pPause.rate))"); return
            }
            guard let tbPause = itPause.timebase else {
                failWithReason("Item timebase missing before warmup_paused"); return
            }
            let effRatePause = CMTimebaseGetEffectiveRate(tbPause)
            guard effRatePause.isFinite, abs(effRatePause - 1.0) <= 0.005 else {
                failWithReason("Effective timebase rate not 1.0 before warmup_paused (got \(effRatePause))"); return
            }
            let pauseMono = getMonotonicMs()
            guard pauseMono <= overallDeadlineMonoMs else {
                failWithReason("Deadline exceeded before pause in state warming"); return
            }

            let freshCMTimeRanges = itPause.loadedTimeRanges.map { $0.timeRangeValue }
            var freshRangesData: [[String: Double]] = []
            for range in freshCMTimeRanges {
                let s = range.start.seconds, dur = range.duration.seconds, e = range.end.seconds
                if s.isFinite && dur.isFinite && e.isFinite {
                    freshRangesData.append(["start": s, "duration": dur, "end": e])
                }
            }
            guard PrecisionStartup.hasLoadedCoverage(
                targetSeconds: quantizedTarget,
                ranges: freshCMTimeRanges,
                requiredAheadSeconds: 0.500
            ) else {
                return
            }

            // State waitingReady set BEFORE pause.
            // Absolute ready deadline established at init (never restart/extend at pause).
            self.state = .waitingReady

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let pauseRecord: [String: Any] = [
                "event": "warmup_paused", "utc": iso.string(from: Date()), "observation_mono_ms": pauseMono,
                "avplayer_status": (pPause.status == .readyToPlay) ? "readyToPlay" : "other",
                "item_status": (itPause.status == .readyToPlay) ? "readyToPlay" : "other",
                "player_rate": reqRatePause, "requested_rate": reqRatePause, "effective_rate": effRatePause,
                "consecutive_advancing_frames": consecutiveAdvancingFrames,
                "first_frame_id": firstGatedFrameId, "second_frame_id": secondGatedFrameId,
                "second_source_mono_ms": secondGatedSourceMonoMs,
                "second_display_time_seconds": secondGatedDisplayTime.isValid ? secondGatedDisplayTime.seconds : -1.0,
                "second_observation_mono_ms": secondGatedObsMonoMs,
                "warm_target_seconds": quantizedTarget, "warm_required_ahead_ms": 500,
                "warm_loaded_ranges": freshRangesData, "warm_coverage_verified": true, "warm_sample_mono_ms": nowMono
            ]
            do {
                try self.emitClosure(pauseRecord)
            } catch {
                self.failWithReason("Emit warmup_paused failed: \(error)")
                return
            }

            // Pauses ONCE. Do NOT detach/rebuild item.
            pPause.pause()

        case .waitingReady:
            // On next tick A's existing ready+rate0 gate issues exactly ONE preroll1.0, 3s deadline, completion finished=true required.
            if p.status == .readyToPlay && it.status == .readyToPlay && p.rate == 0.0 {
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
                        guard self.state == .prerolling else { return }
                        let cbMono = getMonotonicMs()
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
                        self.state = .waitingCoverage
                        self.deadlineMonoMs = getMonotonicMs() + 2000 // 2s deadline from preroll completion, set ONCE
                        self.coverageWaitStartMonoMs = cbMono
                        self.attemptPrecisionStart()
                    }
                }
            }

        case .prerolling:
            // Waiting for preroll completion callback; deadline handled by tick header
            break

        case .waitingCoverage:
            self.attemptPrecisionStart()

        case .starting:
            // Change A starting state's tick: enforce 1500ms deadline, not success just because .playing.
            // Completion is handled in observeFrame via 2 new advancing frames display >= target - .050.
            break

        case .started, .terminal:
            break
        }
    }

    private func attemptPrecisionStart() {
        guard state == .waitingCoverage else { return }
        let nowMono = getMonotonicMs()
        if nowMono > deadlineMonoMs {
            failWithReason("Deadline exceeded in state waitingCoverage")
            return
        }

        guard let p = player, let it = item, p.currentItem === it else {
            failWithReason("Player or item mismatch/deallocated during waitingCoverage")
            return
        }
        guard p.status == .readyToPlay, it.status == .readyToPlay else {
            failWithReason("Player or item status not readyToPlay during waitingCoverage")
            return
        }
        guard p.rate == 0.0 else {
            failWithReason("Player rate is not 0.0 during waitingCoverage (got \(p.rate))")
            return
        }

        let t1Mono = getMonotonicMs()
        let t1 = it.currentTime()
        guard let d = it.currentDate() else {
            failWithReason("item.currentDate() returned nil during waitingCoverage")
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

        // Use ACTUAL quantized finite target for coverage
        let timescale = t.timescale > 0 ? t.timescale : 1000
        let finiteTarget = CMTime(seconds: targetSeconds, preferredTimescale: timescale)
        let quantizedTarget = finiteTarget.seconds

        let loadedCMTimeRanges = it.loadedTimeRanges.map { $0.timeRangeValue }
        var loadedRangesData: [[String: Double]] = []
        for range in loadedCMTimeRanges {
            let s = range.start.seconds, dur = range.duration.seconds, e = range.end.seconds
            if s.isFinite && dur.isFinite && e.isFinite {
                loadedRangesData.append(["start": s, "duration": dur, "end": e])
            }
        }

        let hasCoverage = PrecisionStartup.hasLoadedCoverage(targetSeconds: quantizedTarget, ranges: loadedCMTimeRanges)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if !hasCoverage {
            if !didEmitCoverageWaitStarted {
                didEmitCoverageWaitStarted = true
                lastCoverageWaitSampleMonoMs = nowMono
                let waitStartRecord: [String: Any] = [
                    "event": "coverage_wait_started",
                    "utc": iso.string(from: nowDate),
                    "observation_mono_ms": nowMono,
                    "target_item_time_seconds": quantizedTarget,
                    "currentTime_seconds": t.seconds,
                    "pdt_age_seconds": pdtAge,
                    "delta_seconds": delta,
                    "loaded_ranges": loadedRangesData
                ]
                do {
                    try emitClosure(waitStartRecord)
                } catch {
                    failWithReason("Emit coverage_wait_started failed: \(error)")
                    return
                }
            } else if (nowMono - lastCoverageWaitSampleMonoMs) >= 250 {
                lastCoverageWaitSampleMonoMs = nowMono
                let waitSampleRecord: [String: Any] = [
                    "event": "coverage_wait_sample",
                    "utc": iso.string(from: nowDate),
                    "observation_mono_ms": nowMono,
                    "target_item_time_seconds": quantizedTarget,
                    "currentTime_seconds": t.seconds,
                    "pdt_age_seconds": pdtAge,
                    "delta_seconds": delta,
                    "loaded_ranges": loadedRangesData
                ]
                do {
                    try emitClosure(waitSampleRecord)
                } catch {
                    failWithReason("Emit coverage_wait_sample failed: \(error)")
                    return
                }
            }
            if getMonotonicMs() > deadlineMonoMs {
                failWithReason("Deadline exceeded in state waitingCoverage")
                return
            }
            return
        }

        // Valid loaded coverage satisfied!
        if didEmitCoverageWaitStarted {
            let waitCompletedRecord: [String: Any] = [
                "event": "coverage_wait_completed",
                "utc": iso.string(from: nowDate),
                "observation_mono_ms": nowMono,
                "target_item_time_seconds": quantizedTarget,
                "currentTime_seconds": t.seconds,
                "pdt_age_seconds": pdtAge,
                "delta_seconds": delta,
                "loaded_ranges": loadedRangesData,
                "waited_ms": nowMono - coverageWaitStartMonoMs
            ]
            do {
                try emitClosure(waitCompletedRecord)
            } catch {
                failWithReason("Emit coverage_wait_completed failed: \(error)")
                return
            }
        }

        var seekableRangesData: [[String: Double]] = []
        for val in it.seekableTimeRanges {
            let range = val.timeRangeValue
            let s = range.start.seconds, dur = range.duration.seconds, e = range.end.seconds
            guard s.isFinite, dur.isFinite, e.isFinite else { continue }
            seekableRangesData.append(["start": s, "duration": dur, "end": e])
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
        self.alignTargetSeconds = quantizedTarget
        self.alignTargetCMTime = finiteTarget
        self.alignIssuedFrameId = lastObservedFrameId
        self.completedAdvancingCount = 0

        let reqRecord: [String: Any] = [
            "event": "precision_requested",
            "utc": iso.string(from: nowDate),
            "observation_mono_ms": getMonotonicMs(),
            "target_item_time_seconds": quantizedTarget,
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

        // Recheck state, identity, ready statuses, rate0, and deadline immediately before autoWaits/setRate
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

        // Set autoWaits=false ONLY upon valid coverage
        p3.automaticallyWaitsToMinimizeStalling = false
        guard p3.automaticallyWaitsToMinimizeStalling == false else {
            failWithReason("Verification of automaticallyWaitsToMinimizeStalling == false failed")
            return
        }

        // Exactly setRate(1.0, time: target, atHostTime: hostTime + 0.050s)
        self.didIssueStart = true
        let hostClock = CMClockGetHostTimeClock()
        let hostNow = CMClockGetTime(hostClock)
        let hostOffset = CMTime(seconds: 0.050, preferredTimescale: 1_000_000_000)
        let atHostTime = hostNow + hostOffset

        p3.setRate(1.0, time: finiteTarget, atHostTime: atHostTime)

        // Rename precision_returned -> alignment_issued
        let retRecord: [String: Any] = [
            "event": "alignment_issued",
            "utc": iso.string(from: Date()),
            "observation_mono_ms": getMonotonicMs(),
            "target_item_time_seconds": quantizedTarget,
            "host_clock_time_seconds": atHostTime.seconds,
            "automatically_waits_to_minimize_stalling": p3.automaticallyWaitsToMinimizeStalling
        ]
        do {
            try self.emitClosure(retRecord)
        } catch {
            failWithReason("Emit alignment_issued failed: \(error)")
            return
        }
    }
}
