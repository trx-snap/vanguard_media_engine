import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore

// MARK: - Recovery Session Enums

enum RecoveryMode: String {
    case observe
    case rebuild
}

enum RecoveryPhase: String {
    case initial
    case monitoring
    case recovering
    case recovered
    case terminal
}

enum StartupMode: String {
    case native
    case precision
}

// MARK: - Recovery Session & Probe Runner

final class ProbeRunner {
    let url: URL, nonce: UInt32, outputPath: String, testDurationSeconds: Double
    let waits: Bool, offsetMs: Int, forwardBufferSeconds: Double
    let startupMode: StartupMode, recoveryMode: RecoveryMode

    // Lifecycle objects
    var player: AVPlayer?, playerItem: AVPlayerItem?, videoOutput: AVPlayerItemVideoOutput?
    var precisionHelper: PrecisionStartup?, writer: FlushedJSONLWriter?, timer: Timer?

    // Session State & Monotonic clocks
    private(set) var generation: UInt32 = 1
    private(set) var phase: RecoveryPhase = .initial
    private(set) var isTerminal: Bool = false
    var exitCode: Int32 = 1

    var probeStartMonoMs: UInt64 = 0, firstValidFrameDecoded: Bool = false
    var firstValidFrameMonoMs: UInt64 = 0, firstFrameStartupElapsedMs: UInt64 = 0
    var lastSampleMonoMs: UInt64 = 0, failureCount: Int = 0

    // State change & tracking fields
    var lastStateLogMonoMs: UInt64 = 0
    var lastTimeControlStatus: AVPlayer.TimeControlStatus?
    var lastPlayerItemStatus: AVPlayerItem.Status?
    var lastWaitingReason: AVPlayer.WaitingReason?
    var lastRequestedRate: Float?
    var lastEffectiveRate: Double?
    var lastBufferEmpty: Bool?
    var lastLikelyToKeepUp: Bool?

    var firstEffectivePlayingMonoMs: UInt64 = 0
    var hasReachedFirstEffectivePlaying: Bool = false
    var isCurrentlyPlaying: Bool = false
    var nonplayingTransitionCount: Int = 0

    // Advancing frame tracking & recovery triggers
    var lastAdvancingFrameId: UInt32 = 0
    var lastAdvancingSourceMonoMs: UInt64 = 0
    var lastAdvancingObservationMonoMs: UInt64 = 0
    var advancingEligibleMarkerCount: Int = 0
    var recoveryRequestedMonoMs: UInt64 = 0
    var lastAdvancingFrameIdBeforeRecovery: UInt32 = 0

    // Retained error events across all generations
    var allNativeErrorEvents: [[String: Any]] = []

    init(
        url: URL, nonce: UInt32, outputPath: String, testDurationSeconds: Double,
        waits: Bool, offsetMs: Int, forwardBufferSeconds: Double,
        startupMode: StartupMode, recoveryMode: RecoveryMode
    ) {
        self.url = url; self.nonce = nonce; self.outputPath = outputPath
        self.testDurationSeconds = testDurationSeconds; self.waits = waits; self.offsetMs = offsetMs
        self.forwardBufferSeconds = forwardBufferSeconds; self.startupMode = startupMode
        self.recoveryMode = recoveryMode
    }

    func setup() throws {
        self.writer = try FlushedJSONLWriter(path: outputPath)
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = forwardBufferSeconds
        item.configuredTimeOffsetFromLive = CMTime(value: Int64(offsetMs), timescale: 1000)
        item.automaticallyPreservesTimeOffsetFromLive = true
        // Keep paused-network setting identical in control/treatment
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true

        let attrs = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)

        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = waits
        self.playerItem = item; self.videoOutput = output; self.player = p

        if startupMode == .precision {
            let curGen = self.generation
            self.precisionHelper = PrecisionStartup(
                player: p, item: item, readyTimeoutMs: 10_000,
                emit: { [weak self] record in
                    guard let self = self, !self.isTerminal, self.generation == curGen else { return }
                    var taggedRecord = record
                    taggedRecord["generation"] = curGen
                    do {
                        try self.writer?.writeEntry(taggedRecord)
                    } catch {
                        fputs("[Probe] Write error during precision emit (gen \(curGen)): \(error)\n", stderr)
                        self.exitCode = 1; self.teardown(); throw error
                    }
                },
                fail: { [weak self] reason in
                    guard let self = self, !self.isTerminal, self.generation == curGen else { return }
                    fputs("[Probe] Precision startup failure (gen \(curGen)): \(reason)\n", stderr)
                    self.exitCode = 1; self.teardown()
                }
            )
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var configRecord: [String: Any] = [
            "event": "config", "utc": iso.string(from: Date()), "observation_mono_ms": getMonotonicMs(),
            "generation": self.generation, "startup_mode": startupMode.rawValue, "recovery_mode": recoveryMode.rawValue,
            "waits": p.automaticallyWaitsToMinimizeStalling,
            "can_use_network_resources_for_live_streaming_while_paused": item.canUseNetworkResourcesForLiveStreamingWhilePaused,
            "preferred_forward_buffer_duration": item.preferredForwardBufferDuration,
            "configured_time_offset_seconds": sanitizeNumber(item.configuredTimeOffsetFromLive.seconds),
            "requested_offset_ms": offsetMs,
            "automatically_preserves_time_offset": item.automaticallyPreservesTimeOffsetFromLive
        ]
        if startupMode == .precision {
            configRecord["startup_protocol"] = "warm_play_pause_preroll_align"
        }
        try writer?.writeEntry(configRecord)
    }

    func teardown() {
        guard !isTerminal else { return }
        let finalPhase = phase.rawValue
        let finalGen = generation

        isTerminal = true
        phase = .terminal

        generation += 1
        precisionHelper?.cancel()
        precisionHelper = nil

        timer?.invalidate()
        timer = nil

        player?.pause()
        if let output = videoOutput, let item = playerItem { item.remove(output) }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let events = playerItem?.errorLog()?.events ?? []
        let rawErrors = events.map { ev in
            return [
                "domain": ev.errorDomain, "comment": ev.errorComment ?? "",
                "status": ev.errorStatusCode, "date": ev.date != nil ? iso.string(from: ev.date!) : ""
            ]
        }
        allNativeErrorEvents.append(contentsOf: rawErrors)

        let nowMono = getMonotonicMs()
        let teardownRecord: [String: Any] = [
            "teardown": true, "utc": iso.string(from: Date()),
            "startup_mode": startupMode.rawValue, "recovery_mode": recoveryMode.rawValue,
            "final_phase": finalPhase, "final_generation": finalGen,
            "probe_start_mono_ms": probeStartMonoMs, "teardown_mono_ms": nowMono,
            "first_valid_frame": firstValidFrameDecoded,
            "startup_elapsed_ms": firstValidFrameDecoded ? firstFrameStartupElapsedMs : NSNull(),
            "first_effective_playing_mono_ms": firstEffectivePlayingMonoMs > 0 ? firstEffectivePlayingMonoMs : NSNull(),
            "nonplaying_transition_count": nonplayingTransitionCount,
            "failure_count": failureCount, "waits": player?.automaticallyWaitsToMinimizeStalling ?? waits,
            "requested_offset_ms": offsetMs, "native_error_log_events": allNativeErrorEvents
        ]

        if let w = writer {
            do {
                try w.writeEntry(teardownRecord)
                try w.close()
            } catch {
                fputs("[Probe] Write error on teardown: \(error)\n", stderr)
                exitCode = 1
            }
        }
        writer = nil

        player?.replaceCurrentItem(with: nil)
        playerItem = nil; videoOutput = nil; player = nil
    }

    private func checkProgressGap(nowMono: UInt64) {
        guard !isTerminal else { return }

        // Enforce 22s recovery deadline if actively recovering with guarded subtraction
        if phase == .recovering {
            if nowMono >= recoveryRequestedMonoMs && (nowMono - recoveryRequestedMonoMs) > 22_000 {
                fputs("[Probe] Recovery generation timeout: no advancing marker within 22s of request\n", stderr)
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let failRecord: [String: Any] = [
                    "event": "recovery_failed", "utc": iso.string(from: Date()),
                    "observation_mono_ms": nowMono, "generation": generation, "reason": "recovery_timeout_22s"
                ]
                try? writer?.writeEntry(failRecord)
                exitCode = 1; teardown(); return
            }

            if let p = player, let it = playerItem {
                if p.status == .failed || it.status == .failed {
                    fputs("[Probe] Recovery generation player or item failed\n", stderr)
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let failRecord: [String: Any] = [
                        "event": "recovery_failed", "utc": iso.string(from: Date()),
                        "observation_mono_ms": nowMono, "generation": generation, "reason": "player_or_item_failed"
                    ]
                    try? writer?.writeEntry(failRecord)
                    exitCode = 1; teardown(); return
                }
            }
        }

        guard phase == .monitoring else { return }
        guard recoveryMode == .rebuild else { return }

        // Guard subtraction ordering: nowMono >= lastAdvancingObservationMonoMs
        if lastAdvancingObservationMonoMs > 0 && nowMono >= lastAdvancingObservationMonoMs {
            let gap = nowMono - lastAdvancingObservationMonoMs
            if gap >= 750 {
                requestRecovery(gapMs: gap, nowMono: nowMono)
            }
        }
    }

    private func requestRecovery(gapMs: UInt64, nowMono: UInt64) {
        guard phase == .monitoring, recoveryMode == .rebuild else { return }
        phase = .recovering
        recoveryRequestedMonoMs = nowMono
        lastAdvancingFrameIdBeforeRecovery = lastAdvancingFrameId

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let utcStr = iso.string(from: Date())

        let oldTc = player?.timeControlStatus
        let oldTcStr = (oldTc == .playing) ? "playing" : ((oldTc == .paused) ? "paused" : "waiting")
        let oldItemStatus = playerItem?.status
        let oldStatusStr = (oldItemStatus == .readyToPlay) ? "readyToPlay" : ((oldItemStatus == .failed) ? "failed" : "unknown")

        // Before replacement emit recovery_requested with oldstate/frame/clock; terminal on IO failure
        let reqRecord: [String: Any] = [
            "event": "recovery_requested", "utc": utcStr, "observation_mono_ms": nowMono, "generation": generation,
            "old_time_control_status": oldTcStr, "old_player_item_status": oldStatusStr,
            "last_advancing_frame_id": lastAdvancingFrameId, "last_advancing_source_mono_ms": lastAdvancingSourceMonoMs,
            "last_advancing_observation_mono_ms": lastAdvancingObservationMonoMs, "progress_gap_ms": gapMs
        ]
        do {
            try writer?.writeEntry(reqRecord)
        } catch {
            fputs("[Probe] Write error during recovery_requested emit: \(error)\n", stderr)
            exitCode = 1; teardown(); return
        }

        // Increment generation before cancel old callbacks
        let endedGen = generation
        generation += 1

        let oldHelper = precisionHelper
        precisionHelper = nil
        oldHelper?.cancel()

        let oldP = player
        oldP?.pause()

        let oldItem = playerItem
        let events = oldItem?.errorLog()?.events ?? []
        let rawErrors = events.map { ev in
            return [
                "domain": ev.errorDomain, "comment": ev.errorComment ?? "",
                "status": ev.errorStatusCode, "date": ev.date != nil ? iso.string(from: ev.date!) : ""
            ]
        }
        allNativeErrorEvents.append(contentsOf: rawErrors)

        let genEndedRecord: [String: Any] = [
            "event": "generation_ended", "utc": iso.string(from: Date()),
            "observation_mono_ms": getMonotonicMs(), "ended_generation": endedGen,
            "native_error_log_events": rawErrors
        ]
        do {
            try writer?.writeEntry(genEndedRecord)
        } catch {
            fputs("[Probe] Write error during generation_ended emit: \(error)\n", stderr)
            exitCode = 1; teardown(); return
        }

        if let out = videoOutput, let it = oldItem { it.remove(out) }
        oldP?.replaceCurrentItem(with: nil)
        self.videoOutput = nil; self.playerItem = nil; self.player = nil

        // Reset sample throttle / state cached fields for new generation
        lastSampleMonoMs = 0; lastStateLogMonoMs = 0
        lastTimeControlStatus = nil; lastPlayerItemStatus = nil
        lastWaitingReason = nil; lastRequestedRate = nil
        lastEffectiveRate = nil; lastBufferEmpty = nil; lastLikelyToKeepUp = nil

        let freshAsset = AVURLAsset(url: url)
        let newItem = AVPlayerItem(asset: freshAsset)
        newItem.preferredForwardBufferDuration = forwardBufferSeconds
        newItem.configuredTimeOffsetFromLive = CMTime(value: Int64(offsetMs), timescale: 1000)
        newItem.automaticallyPreservesTimeOffsetFromLive = true
        newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true

        let attrs = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        let newOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        newItem.add(newOutput)

        let newPlayer = AVPlayer(playerItem: newItem)
        newPlayer.automaticallyWaitsToMinimizeStalling = waits

        self.playerItem = newItem; self.videoOutput = newOutput; self.player = newPlayer

        let curGen = self.generation
        if startupMode == .precision {
            self.precisionHelper = PrecisionStartup(
                player: newPlayer, item: newItem, readyTimeoutMs: 15_000,
                emit: { [weak self] record in
                    guard let self = self, !self.isTerminal, self.generation == curGen else { return }
                    var taggedRecord = record
                    taggedRecord["generation"] = curGen
                    do {
                        try self.writer?.writeEntry(taggedRecord)
                    } catch {
                        fputs("[Probe] Write error during precision emit (gen \(curGen)): \(error)\n", stderr)
                        self.exitCode = 1; self.teardown(); throw error
                    }
                },
                fail: { [weak self] reason in
                    guard let self = self, !self.isTerminal, self.generation == curGen else { return }
                    fputs("[Probe] Precision startup failure (gen \(curGen)): \(reason)\n", stderr)
                    let failRecord: [String: Any] = [
                        "event": "recovery_failed", "utc": ISO8601DateFormatter().string(from: Date()),
                        "observation_mono_ms": getMonotonicMs(), "generation": curGen, "reason": reason
                    ]
                    try? self.writer?.writeEntry(failRecord)
                    self.exitCode = 1; self.teardown()
                }
            )
        }

        // Fresh recovery generation plays immediately
        newPlayer.play()

        var configRecord: [String: Any] = [
            "event": "config", "utc": iso.string(from: Date()), "observation_mono_ms": getMonotonicMs(),
            "generation": self.generation, "startup_mode": startupMode.rawValue, "recovery_mode": recoveryMode.rawValue,
            "waits": newPlayer.automaticallyWaitsToMinimizeStalling,
            "can_use_network_resources_for_live_streaming_while_paused": newItem.canUseNetworkResourcesForLiveStreamingWhilePaused,
            "preferred_forward_buffer_duration": newItem.preferredForwardBufferDuration,
            "configured_time_offset_seconds": sanitizeNumber(newItem.configuredTimeOffsetFromLive.seconds),
            "requested_offset_ms": offsetMs,
            "automatically_preserves_time_offset": newItem.automaticallyPreservesTimeOffsetFromLive
        ]
        if startupMode == .precision {
            configRecord["startup_protocol"] = "warm_play_pause_preroll_align"
        }
        do {
            try writer?.writeEntry(configRecord)
        } catch {
            fputs("[Probe] Write error during gen \(curGen) config emit: \(error)\n", stderr)
            exitCode = 1; teardown(); return
        }
    }

    func processTick() {
        guard !isTerminal, let item = playerItem, let output = videoOutput, let p = player else { return }

        // Defer reads fresh monotonic timestamp and checks progress gap
        defer {
            let freshMono = getMonotonicMs()
            checkProgressGap(nowMono: freshMono)
        }

        if startupMode == .precision {
            precisionHelper?.tick()
            guard !isTerminal else { return }
        }

        let nowMono = getMonotonicMs()
        let durationMilliseconds = UInt64(testDurationSeconds * 1000.0)
        let timeoutCeilingMs = max(UInt64(48_000), durationMilliseconds + 25_000)
        if (nowMono - probeStartMonoMs) > timeoutCeilingMs {
            fputs("[Probe] Overall timeout \(timeoutCeilingMs / 1000)s reached\n", stderr)
            exitCode = 1; teardown(); return
        }

        if firstValidFrameDecoded && (nowMono - firstValidFrameMonoMs) >= durationMilliseconds {
            fputs("[Probe] Normal completion: \(testDurationSeconds)s reached\n", stderr)
            exitCode = 0; teardown(); return
        }

        let highlevelItemTime = item.currentTime()
        let hostNow = CACurrentMediaTime()
        let queryItemTime = output.itemTime(forHostTime: hostNow)
        let isQueryValid = queryItemTime.isValid && !queryItemTime.isIndefinite && queryItemTime.isNumeric && queryItemTime.seconds.isFinite

        let currentTimeControl = p.timeControlStatus
        let currentItemStatus = item.status
        let currentReason = p.reasonForWaitingToPlay
        let currentReqRate = p.rate
        let currentEffRate: Double = (item.timebase != nil) ? CMTimebaseGetEffectiveRate(item.timebase!) : 0.0
        let currentBufEmpty = item.isPlaybackBufferEmpty
        let currentLikely = item.isPlaybackLikelyToKeepUp
        let currentWaits = p.automaticallyWaitsToMinimizeStalling

        let tbTime: CMTime? = (item.timebase != nil) ? CMTimebaseGetTime(item.timebase!) : nil

        let playingNow = (currentTimeControl == .playing && abs(currentEffRate - 1.0) < 0.15)
        if playingNow {
            if firstEffectivePlayingMonoMs == 0 {
                firstEffectivePlayingMonoMs = nowMono
                hasReachedFirstEffectivePlaying = true
            }
            isCurrentlyPlaying = true
        } else if hasReachedFirstEffectivePlaying && isCurrentlyPlaying {
            isCurrentlyPlaying = false
            nonplayingTransitionCount += 1
        }

        let rateChanged = (lastEffectiveRate == nil) || (abs(lastEffectiveRate! - currentEffRate) > 0.01)
        let stateChanged = (lastTimeControlStatus != currentTimeControl)
            || (lastPlayerItemStatus != currentItemStatus)
            || (lastWaitingReason != currentReason)
            || (lastRequestedRate != currentReqRate)
            || rateChanged
            || (lastBufferEmpty != currentBufEmpty)
            || (lastLikelyToKeepUp != currentLikely)

        if stateChanged || (nowMono - lastStateLogMonoMs) >= 250 {
            lastTimeControlStatus = currentTimeControl; lastPlayerItemStatus = currentItemStatus
            lastWaitingReason = currentReason; lastRequestedRate = currentReqRate
            lastEffectiveRate = currentEffRate; lastBufferEmpty = currentBufEmpty
            lastLikelyToKeepUp = currentLikely; lastStateLogMonoMs = nowMono

            let timeControlStr = currentTimeControl == .playing ? "playing" : (currentTimeControl == .paused ? "paused" : "waiting")
            let itemStatusStr = currentItemStatus == .readyToPlay ? "readyToPlay" : (currentItemStatus == .failed ? "failed" : "unknown")
            let avPlayerStatusStr = (p.status == .readyToPlay) ? "readyToPlay" : ((p.status == .failed) ? "failed" : "unknown")
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var stateRecord: [String: Any] = [
                "event": "state", "utc": iso.string(from: Date()), "observation_mono_ms": nowMono,
                "generation": generation, "recovery_phase": phase.rawValue,
                "startup_mode": startupMode.rawValue, "recovery_mode": recoveryMode.rawValue,
                "time_control_status": timeControlStr,
                "avplayer_status": avPlayerStatusStr,
                "item_status": itemStatusStr,
                "player_status": itemStatusStr,
                "reason_for_waiting_to_play": currentReason?.rawValue ?? "",
                "requested_rate": sanitizeNumber(Double(currentReqRate)),
                "effective_rate": sanitizeNumber(currentEffRate),
                "waits": currentWaits, "buffer_empty": currentBufEmpty, "likely_to_keep_up": currentLikely,
                "has_reached_playing": hasReachedFirstEffectivePlaying,
                "nonplaying_transition_count": nonplayingTransitionCount
            ]

            if let pErr = p.error as NSError? {
                stateRecord["player_error"] = [
                    "domain": pErr.domain,
                    "code": pErr.code,
                    "description": pErr.localizedDescription
                ]
            } else {
                stateRecord["player_error"] = NSNull()
            }

            if let itErr = item.error as NSError? {
                stateRecord["item_error"] = [
                    "domain": itErr.domain,
                    "code": itErr.code,
                    "description": itErr.localizedDescription
                ]
            } else {
                stateRecord["item_error"] = NSNull()
            }

            if highlevelItemTime.isValid && !highlevelItemTime.isIndefinite && highlevelItemTime.isNumeric && highlevelItemTime.seconds.isFinite {
                stateRecord["highlevel_item_time_seconds"] = highlevelItemTime.seconds
                stateRecord["item_time_seconds"] = highlevelItemTime.seconds
            } else {
                stateRecord["highlevel_item_time_seconds"] = NSNull()
                stateRecord["highlevel_item_time_unavailable_reason"] = "invalid_item_time"
                stateRecord["item_time_seconds"] = NSNull()
            }

            if isQueryValid {
                stateRecord["query_item_time_seconds"] = queryItemTime.seconds
            } else {
                stateRecord["query_item_time_seconds"] = NSNull()
                stateRecord["query_item_time_unavailable_reason"] = "invalid_host_time_mapping"
            }

            if let tb = tbTime, tb.isValid && !tb.isIndefinite && tb.isNumeric && tb.seconds.isFinite {
                stateRecord["timebase_time_seconds"] = tb.seconds
            } else {
                stateRecord["timebase_time_seconds"] = NSNull()
                stateRecord["timebase_time_unavailable_reason"] = (item.timebase == nil) ? "no_timebase" : "invalid_timebase_time"
            }

            do {
                try writer?.writeEntry(stateRecord)
            } catch {
                fputs("[Probe] Write error during state log: \(error)\n", stderr)
                exitCode = 1; teardown(); return
            }
        }

        guard isQueryValid else { return }

        if firstValidFrameDecoded && (nowMono - lastSampleMonoMs) < 200 { return }

        guard output.hasNewPixelBuffer(forItemTime: queryItemTime) else { return }
        var displayTime = CMTime.invalid
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: queryItemTime, itemTimeForDisplay: &displayTime) else { return }

        let isDisplayValid = displayTime.isValid && !displayTime.isIndefinite && displayTime.isNumeric && displayTime.seconds.isFinite
        let displayAheadSec: Double? = isDisplayValid ? (displayTime.seconds - queryItemTime.seconds) : nil
        let isFutureSample: Bool = (displayAheadSec != nil) ? (displayAheadSec! > 0.050) : false
        let isEligiblePresentation: Bool = isDisplayValid && !isFutureSample

        let observationMonoMs = getMonotonicMs()
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        var decoded: DecodedMarker? = nil
        var errorString: String? = nil
        do {
            decoded = try decodeMarkerFromBGRAPointer(
                baseAddress: baseAddr, width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer), bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                observationMonoMs: observationMonoMs, expectedNonce: nonce
            )
        } catch {
            failureCount += 1
            errorString = "\(error)"
        }

        if let validMarker = decoded {
            if isEligiblePresentation {
                if !firstValidFrameDecoded {
                    firstValidFrameDecoded = true
                    firstValidFrameMonoMs = observationMonoMs
                    firstFrameStartupElapsedMs = observationMonoMs - probeStartMonoMs
                    fputs("[Probe] First frame decoded (eligible presentation): f=\(validMarker.frameId) startup=\(firstFrameStartupElapsedMs)ms age=\(validMarker.ageMs)ms\n", stderr)
                }

                let isPlayingAndRate1 = (currentTimeControl == .playing) && currentEffRate.isFinite && (abs(currentEffRate - 1.0) <= 0.005)
                let isAdvancing = (validMarker.frameId > lastAdvancingFrameId)

                    if isPlayingAndRate1 && isAdvancing {
                    lastAdvancingFrameId = validMarker.frameId
                    lastAdvancingSourceMonoMs = validMarker.sourceMonoMs
                    lastAdvancingObservationMonoMs = observationMonoMs
                    advancingEligibleMarkerCount += 1

                    let helperStarted = (startupMode == .native) || (precisionHelper?.state == .started)
                    if phase == .initial && advancingEligibleMarkerCount >= 2 && helperStarted {
                        phase = .monitoring
                        let iso = ISO8601DateFormatter()
                        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        let armRecord: [String: Any] = [
                            "event": "monitoring_armed", "utc": iso.string(from: Date()),
                            "observation_mono_ms": observationMonoMs, "generation": generation,
                            "frame_id": validMarker.frameId, "advancing_count": advancingEligibleMarkerCount
                        ]
                        do {
                            try writer?.writeEntry(armRecord)
                        } catch {
                            fputs("[Probe] Write error during monitoring_armed emit: \(error)\n", stderr)
                            exitCode = 1; teardown(); return
                        }
                    }

                    let recHelperStarted = (startupMode == .native) || (precisionHelper?.state == .started)
                    if phase == .recovering && generation == 2 && validMarker.frameId > lastAdvancingFrameIdBeforeRecovery && recHelperStarted {
                        phase = .recovered
                        let recDur = observationMonoMs - recoveryRequestedMonoMs
                        let iso = ISO8601DateFormatter()
                        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        let recRecord: [String: Any] = [
                            "event": "recovery_completed", "utc": iso.string(from: Date()),
                            "observation_mono_ms": observationMonoMs, "generation": generation,
                            "frame_id": validMarker.frameId, "age_ms": validMarker.ageMs,
                            "source_mono_ms": validMarker.sourceMonoMs, "recovery_duration_ms": recDur
                        ]
                        do {
                            try writer?.writeEntry(recRecord)
                        } catch {
                            fputs("[Probe] Write error during recovery_completed emit: \(error)\n", stderr)
                            exitCode = 1; teardown(); return
                        }
                    }
                }
            }
            lastSampleMonoMs = observationMonoMs
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let utcStr = iso.string(from: Date())
        let itemDateAge: Double? = item.currentDate().map { Date().timeIntervalSince($0) * 1000.0 }
        let timebaseRate: Double = (item.timebase != nil) ? CMTimebaseGetEffectiveRate(item.timebase!) : 0.0

        let timeControlStr = (p.timeControlStatus == .playing) ? "playing" : ((p.timeControlStatus == .paused) ? "paused" : "waiting")
        let itemStatusStr = (item.status == .readyToPlay) ? "readyToPlay" : ((item.status == .failed) ? "failed" : "unknown")
        let avPlayerStatusStr = (p.status == .readyToPlay) ? "readyToPlay" : ((p.status == .failed) ? "failed" : "unknown")

        var record: [String: Any] = [
            "utc": utcStr, "observation_mono_ms": observationMonoMs,
            "generation": generation, "recovery_phase": phase.rawValue,
            "startup_mode": startupMode.rawValue, "recovery_mode": recoveryMode.rawValue,
            "effective_timebase_rate": sanitizeNumber(timebaseRate),
            "requested_rate": sanitizeNumber(Double(currentReqRate)),
            "effective_rate": sanitizeNumber(currentEffRate),
            "waits": currentWaits, "time_control_status": timeControlStr,
            "avplayer_status": avPlayerStatusStr,
            "item_status": itemStatusStr,
            "player_status": itemStatusStr,
            "configured_offset_seconds": sanitizeNumber(item.configuredTimeOffsetFromLive.seconds),
            "recommended_offset_seconds": sanitizeNumber(item.recommendedTimeOffsetFromLive.seconds),
            "valid": decoded != nil, "failure_count": failureCount,
            "presentation_eligible": isEligiblePresentation, "is_future_sample": isFutureSample
        ]

        if let da = displayAheadSec {
            record["display_ahead_seconds"] = sanitizeNumber(da)
        } else {
            record["display_ahead_seconds"] = NSNull()
            record["display_ahead_unavailable_reason"] = "invalid_display_time"
        }

        if highlevelItemTime.isValid && !highlevelItemTime.isIndefinite && highlevelItemTime.isNumeric && highlevelItemTime.seconds.isFinite {
            record["highlevel_item_time_seconds"] = highlevelItemTime.seconds
            record["item_time_seconds"] = highlevelItemTime.seconds
        } else {
            record["highlevel_item_time_seconds"] = NSNull()
            record["highlevel_item_time_unavailable_reason"] = "invalid_item_time"
            record["item_time_seconds"] = NSNull()
        }

        if isQueryValid {
            record["query_item_time_seconds"] = queryItemTime.seconds
        } else {
            record["query_item_time_seconds"] = NSNull()
            record["query_item_time_unavailable_reason"] = "invalid_host_time_mapping"
        }

        if let tb = tbTime, tb.isValid && !tb.isIndefinite && tb.isNumeric && tb.seconds.isFinite {
            record["timebase_time_seconds"] = tb.seconds
        } else {
            record["timebase_time_seconds"] = NSNull()
            record["timebase_time_unavailable_reason"] = (item.timebase == nil) ? "no_timebase" : "invalid_timebase_time"
        }

        if isDisplayValid {
            record["display_item_time_seconds"] = displayTime.seconds
        } else {
            record["display_item_time_seconds"] = NSNull()
            record["display_item_time_unavailable_reason"] = "invalid_display_time"
        }

        if let ida = itemDateAge { record["item_date_age_ms"] = sanitizeNumber(ida) }
        if let m = decoded {
            record["frame_id"] = m.frameId; record["source_mono_ms"] = m.sourceMonoMs; record["age_ms"] = m.ageMs
        }
        if let err = errorString { record["error"] = err }
        if firstValidFrameDecoded { record["startup_elapsed_ms"] = firstFrameStartupElapsedMs }

        do {
            try writer?.writeEntry(record)
        } catch {
            fputs("[Probe] Write error during tick: \(error)\n", stderr)
            exitCode = 1; teardown(); return
        }

        // Feed helper AFTER writing eligible marker record; observeFrame only records/gates, next tick performs mutation
        if startupMode == .precision {
            let isPlayingAndRate1 = (currentTimeControl == .playing) &&
                currentEffRate.isFinite && (abs(currentEffRate - 1.0) <= 0.005) &&
                Double(currentReqRate).isFinite && (abs(Double(currentReqRate) - 1.0) <= 0.005)
            if let m = decoded, isEligiblePresentation {
                precisionHelper?.observeFrame(
                    frameId: m.frameId,
                    sourceMonoMs: m.sourceMonoMs,
                    displayTime: displayTime,
                    observationMonoMs: observationMonoMs,
                    playingAtRate1: isPlayingAndRate1
                )
            } else {
                precisionHelper?.observeFrame(
                    frameId: decoded?.frameId ?? 0,
                    sourceMonoMs: decoded?.sourceMonoMs ?? 0,
                    displayTime: displayTime,
                    observationMonoMs: observationMonoMs,
                    playingAtRate1: false
                )
            }
        }
    }

    func run() -> Int32 {
        probeStartMonoMs = getMonotonicMs()
        do {
            try setup()
        } catch {
            fputs("[Probe] Setup failed: \(error)\n", stderr)
            teardown()
            return 1
        }

        // BOTH modes play immediately after setup
        fputs("[Probe] Mode \(startupMode.rawValue): playing immediately url=\(url), nonce=\(nonce), waits=\(waits), offsetMs=\(offsetMs)\n", stderr)
        player?.play()

        let t = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.processTick() }
        self.timer = t
        RunLoop.main.add(t, forMode: .common)
        while !isTerminal {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        teardown()
        return exitCode
    }
}
