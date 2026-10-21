import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import ImageIO
import QuartzCore

// MARK: - Monotonic Clock & Standard IEEE 802.3 CRC32

func getMonotonicMs() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1000 + UInt64(ts.tv_nsec) / 1_000_000
}

struct CRC32 {
    static let table: [UInt32] = (0...255).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in bytes { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Marker Payload and Decoding

struct DecodedMarker {
    let frameId: UInt32
    let sourceMonoMs: UInt64
    let ageMs: Int64
}

enum MarkerDecodeError: Error, CustomStringConvertible, Equatable {
    case notPortrait9x16, ambiguousCell(Int, Int, Double), invalidMagic, nonceMismatch, crcMismatch, negativeAge, invalidBuffer
    var description: String {
        switch self {
        case .notPortrait9x16: return "Buffer not portrait 9:16"
        case .ambiguousCell(let r, let c, let lum): return "Ambiguous cell (\(r),\(c)) lum=\(String(format: "%.1f", lum))"
        case .invalidMagic: return "Invalid magic header"
        case .nonceMismatch: return "Nonce mismatch"
        case .crcMismatch: return "CRC mismatch"
        case .negativeAge: return "Negative age"
        case .invalidBuffer: return "Invalid pixel buffer"
        }
    }
}

func decodeMarkerFromBGRAPointer(
    baseAddress: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int,
    observationMonoMs: UInt64, expectedNonce: UInt32
) throws -> DecodedMarker {
    guard width < height, abs(Double(width) / Double(height) - (9.0 / 16.0)) < 0.05 else {
        throw MarkerDecodeError.notPortrait9x16
    }
    let sx = Double(width) / 720.0, sy = Double(height) / 1280.0
    let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
    var payload = [UInt8](repeating: 0, count: 24)
    let sampleRadius = max(2, Int(4.0 * sx))

    for row in 0..<12 {
        for col in 0..<16 {
            let cx = Int(round((104.0 + Double(col) * 32.0 + 16.0) * sx))
            let cy = Int(round((448.0 + Double(row) * 32.0 + 16.0) * sy))
            var lumSum = 0.0, pixelCount = 0

            for dy in -sampleRadius...sampleRadius {
                let py = cy + dy
                guard py >= 0 && py < height else { continue }
                let rowOffset = py * bytesPerRow
                for dx in -sampleRadius...sampleRadius {
                    let px = cx + dx
                    guard px >= 0 && px < width else { continue }
                    let off = rowOffset + px * 4
                    lumSum += 0.299 * Double(ptr[off + 2]) + 0.587 * Double(ptr[off + 1]) + 0.114 * Double(ptr[off])
                    pixelCount += 1
                }
            }
            guard pixelCount > 0 else { throw MarkerDecodeError.invalidBuffer }
            let avgLum = lumSum / Double(pixelCount)
            let bit: UInt8
            if avgLum > 170.0 { bit = 1 }
            else if avgLum < 85.0 { bit = 0 }
            else { throw MarkerDecodeError.ambiguousCell(row, col, avgLum) }

            let bitIdx = row * 16 + col
            if bit == 1 { payload[bitIdx / 8] |= (1 << (7 - (bitIdx % 8))) }
        }
    }

    guard payload[0] == 0x56 && payload[1] == 0x47 && payload[2] == 0x4C && payload[3] == 0x4C else {
        throw MarkerDecodeError.invalidMagic
    }
    let nonce = (UInt32(payload[4]) << 24) | (UInt32(payload[5]) << 16) | (UInt32(payload[6]) << 8) | UInt32(payload[7])
    guard nonce == expectedNonce else { throw MarkerDecodeError.nonceMismatch }

    let frame = (UInt32(payload[8]) << 24) | (UInt32(payload[9]) << 16) | (UInt32(payload[10]) << 8) | UInt32(payload[11])
    var sourceMono: UInt64 = 0
    for i in 0..<8 { sourceMono = (sourceMono << 8) | UInt64(payload[12 + i]) }

    let decodedCrc = (UInt32(payload[20]) << 24) | (UInt32(payload[21]) << 16) | (UInt32(payload[22]) << 8) | UInt32(payload[23])
    let calculatedCrc = CRC32.checksum(Array(payload[0..<20]))
    guard decodedCrc == calculatedCrc else { throw MarkerDecodeError.crcMismatch }

    let ageMs = Int64(observationMonoMs) - Int64(sourceMono)
    guard ageMs >= 0 else { throw MarkerDecodeError.negativeAge }
    return DecodedMarker(frameId: frame, sourceMonoMs: sourceMono, ageMs: ageMs)
}

// MARK: - Flushed JSONL Writer with Throwing Writes

class FlushedJSONLWriter {
    let fileHandle: FileHandle
    init(path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw NSError(domain: "Probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed creating \(path)"])
            }
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw NSError(domain: "Probe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot open \(path)"])
        }
        self.fileHandle = handle
        try self.fileHandle.seekToEnd()
    }
    func writeEntry(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        var lineData = data
        lineData.append(contentsOf: [0x0A]) // \n
        try fileHandle.write(contentsOf: lineData)
        try fileHandle.synchronize()
    }
    func close() throws {
        try fileHandle.synchronize()
        try fileHandle.close()
    }
}

func sanitizeNumber(_ val: Double) -> Any {
    if val.isNaN || val.isInfinite { return NSNull() }
    return val
}

// MARK: - Calibration Mode Execution

func runCalibration(pngPath: String, nonce: UInt32, outputPath: String) -> Int32 {
    guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: pngPath) as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        fputs("[Probe:calib] Failed to load image from \(pngPath)\n", stderr); return 1
    }
    let width = cgImage.width, height = cgImage.height
    guard width == 720 && height == 1280 else {
        fputs("[Probe:calib] Dimensions \(width)x\(height) != 720x1280\n", stderr); return 1
    }

    var pixelBuffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
          let buffer = pixelBuffer else { fputs("[Probe:calib] Failed creating buffer\n", stderr); return 1 }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let baseAddr = CVPixelBufferGetBaseAddress(buffer) else { return 1 }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

    guard let ctx = CGContext(data: baseAddr, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
        fputs("[Probe:calib] Failed CGContext\n", stderr); return 1
    }
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    let obs1Mono = getMonotonicMs()
    let m1: DecodedMarker
    do {
        m1 = try decodeMarkerFromBGRAPointer(baseAddress: baseAddr, width: width, height: height, bytesPerRow: bytesPerRow,
                                             observationMonoMs: obs1Mono, expectedNonce: nonce)
    } catch {
        fputs("[Probe:calib] First decode failed: \(error)\n", stderr); return 1
    }
    guard m1.frameId == 1 else {
        fputs("[Probe:calib] Expected frame 1, got \(m1.frameId)\n", stderr); return 1
    }

    usleep(500_000)
    let obs2Mono = getMonotonicMs()
    let m2: DecodedMarker
    do {
        m2 = try decodeMarkerFromBGRAPointer(baseAddress: baseAddr, width: width, height: height, bytesPerRow: bytesPerRow,
                                             observationMonoMs: obs2Mono, expectedNonce: nonce)
    } catch {
        fputs("[Probe:calib] Second decode failed: \(error)\n", stderr); return 1
    }

    let ageIncrease = m2.ageMs - m1.ageMs
    guard ageIncrease >= 450 && ageIncrease <= 750 else {
        fputs("[Probe:calib] Age increase \(ageIncrease)ms not in 450..750ms\n", stderr); return 1
    }

    // Corrupt ALL BGRA RGB pixels of CRC cell (row 10, col 0), bounds x104..135, y768..799
    let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)
    for py in 768...799 {
        guard py < height else { continue }
        let rowOff = py * bytesPerRow
        for px in 104...135 {
            guard px < width else { continue }
            let off = rowOff + px * 4
            ptr[off] = ~ptr[off]         // B
            ptr[off + 1] = ~ptr[off + 1] // G
            ptr[off + 2] = ~ptr[off + 2] // R
        }
    }

    var gotSpecificCrcMismatch = false
    do {
        _ = try decodeMarkerFromBGRAPointer(baseAddress: baseAddr, width: width, height: height, bytesPerRow: bytesPerRow,
                                             observationMonoMs: getMonotonicMs(), expectedNonce: nonce)
    } catch MarkerDecodeError.crcMismatch {
        gotSpecificCrcMismatch = true
    } catch {
        fputs("[Probe:calib] Expected crcMismatch, got: \(error)\n", stderr)
    }

    // Restore inverted pixels
    for py in 768...799 {
        guard py < height else { continue }
        let rowOff = py * bytesPerRow
        for px in 104...135 {
            guard px < width else { continue }
            let off = rowOff + px * 4
            ptr[off] = ~ptr[off]
            ptr[off + 1] = ~ptr[off + 1]
            ptr[off + 2] = ~ptr[off + 2]
        }
    }

    guard gotSpecificCrcMismatch else {
        fputs("[Probe:calib] Failed to verify specific crcMismatch rejection\n", stderr); return 1
    }

    let record: [String: Any] = [
        "calibration": "PASS", "nonce": nonce, "frame": m1.frameId, "source_mono_ms": m1.sourceMonoMs,
        "obs1_mono_ms": obs1Mono, "obs2_mono_ms": obs2Mono, "age1_ms": m1.ageMs, "age2_ms": m2.ageMs,
        "age_increase_ms": ageIncrease, "corrupt_rejection": true
    ]
    do {
        let w = try FlushedJSONLWriter(path: outputPath)
        try w.writeEntry(record)
        try w.close()
    } catch {
        fputs("[Probe:calib] Failed writing output: \(error)\n", stderr); return 1
    }
    fputs("[Probe:calib] SUCCESS: age_increase=\(ageIncrease)ms, crcMismatch verified\n", stderr)
    return 0
}

// MARK: - Startup Mode

enum StartupMode: String {
    case native
    case precision
}

// MARK: - Native Playback Runner

class ProbeRunner {
    let url: URL, nonce: UInt32, outputPath: String, testDurationSeconds: Double, waits: Bool, offsetMs: Int, forwardBufferSeconds: Double
    let startupMode: StartupMode
    var precisionHelper: PrecisionStartup?
    var player: AVPlayer?, playerItem: AVPlayerItem?, videoOutput: AVPlayerItemVideoOutput?, writer: FlushedJSONLWriter?
    var timer: Timer?
    var probeStartMonoMs: UInt64 = 0, firstValidFrameDecoded = false, firstValidFrameMonoMs: UInt64 = 0
    var firstFrameStartupElapsedMs: UInt64 = 0, lastSampleMonoMs: UInt64 = 0, failureCount = 0, isTerminal = false, exitCode: Int32 = 1

    // State change & tracking fields
    var lastStateLogMonoMs: UInt64 = 0
    var lastTimeControlStatus: AVPlayer.TimeControlStatus? = nil
    var lastPlayerItemStatus: AVPlayerItem.Status? = nil
    var lastWaitingReason: AVPlayer.WaitingReason? = nil
    var lastRequestedRate: Float? = nil
    var lastEffectiveRate: Double? = nil
    var lastBufferEmpty: Bool? = nil
    var lastLikelyToKeepUp: Bool? = nil

    var firstEffectivePlayingMonoMs: UInt64 = 0
    var hasReachedFirstEffectivePlaying = false
    var isCurrentlyPlaying = false
    var nonplayingTransitionCount = 0

    init(
        url: URL, nonce: UInt32, outputPath: String, testDurationSeconds: Double,
        waits: Bool, offsetMs: Int, forwardBufferSeconds: Double, startupMode: StartupMode
    ) {
        self.url = url; self.nonce = nonce; self.outputPath = outputPath
        self.testDurationSeconds = testDurationSeconds; self.waits = waits; self.offsetMs = offsetMs
        self.forwardBufferSeconds = forwardBufferSeconds
        self.startupMode = startupMode
    }

    func setup() throws {
        self.writer = try FlushedJSONLWriter(path: outputPath)
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = forwardBufferSeconds
        item.configuredTimeOffsetFromLive = CMTime(value: Int64(offsetMs), timescale: 1000)
        item.automaticallyPreservesTimeOffsetFromLive = true

        if startupMode == .precision {
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        }

        let attrs = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)

        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = waits
        self.playerItem = item; self.videoOutput = output; self.player = p

        if startupMode == .precision {
            self.precisionHelper = PrecisionStartup(
                player: p,
                item: item,
                emit: { [weak self] record in
                    guard let self = self, !self.isTerminal else { return }
                    do {
                        try self.writer?.writeEntry(record)
                    } catch {
                        fputs("[Probe] Write error during precision emit: \(error)\n", stderr)
                        self.exitCode = 1
                        self.teardown()
                        throw error
                    }
                },
                fail: { [weak self] reason in
                    guard let self = self, !self.isTerminal else { return }
                    fputs("[Probe] Precision startup failure: \(reason)\n", stderr)
                    self.exitCode = 1
                    self.teardown()
                }
            )
        }

        // Readback log config event
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let configRecord: [String: Any] = [
            "event": "config",
            "utc": iso.string(from: Date()),
            "observation_mono_ms": getMonotonicMs(),
            "startup_mode": startupMode.rawValue,
            "waits": p.automaticallyWaitsToMinimizeStalling,
            "can_use_network_resources_for_live_streaming_while_paused": item.canUseNetworkResourcesForLiveStreamingWhilePaused,
            "preferred_forward_buffer_duration": item.preferredForwardBufferDuration,
            "configured_time_offset_seconds": sanitizeNumber(item.configuredTimeOffsetFromLive.seconds),
            "requested_offset_ms": offsetMs,
            "automatically_preserves_time_offset": item.automaticallyPreservesTimeOffsetFromLive
        ]
        try writer?.writeEntry(configRecord)
    }

    func teardown() {
        guard !isTerminal else { return }
        isTerminal = true

        precisionHelper?.cancel()
        precisionHelper = nil

        timer?.invalidate()
        timer = nil

        player?.pause()
        if let output = videoOutput, let item = playerItem { item.remove(output) }

        // Preserve COMPLETE errorLog events even without valid frames
        let events = playerItem?.errorLog()?.events ?? []
        let rawErrors = events.map { ev in
            return [
                "domain": ev.errorDomain,
                "comment": ev.errorComment ?? "",
                "status": ev.errorStatusCode,
                "date": ev.date != nil ? ISO8601DateFormatter().string(from: ev.date!) : ""
            ]
        }
        let nowMono = getMonotonicMs()
        let teardownRecord: [String: Any] = [
            "teardown": true,
            "utc": ISO8601DateFormatter().string(from: Date()),
            "startup_mode": startupMode.rawValue,
            "probe_start_mono_ms": probeStartMonoMs,
            "teardown_mono_ms": nowMono,
            "first_valid_frame": firstValidFrameDecoded,
            "startup_elapsed_ms": firstValidFrameDecoded ? firstFrameStartupElapsedMs : NSNull(),
            "first_effective_playing_mono_ms": firstEffectivePlayingMonoMs > 0 ? firstEffectivePlayingMonoMs : NSNull(),
            "nonplaying_transition_count": nonplayingTransitionCount,
            "failure_count": failureCount,
            "waits": player?.automaticallyWaitsToMinimizeStalling ?? waits,
            "requested_offset_ms": offsetMs,
            "native_error_log_events": rawErrors
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

    func processTick() {
        guard !isTerminal, let item = playerItem, let output = videoOutput, let p = player else { return }

        if startupMode == .precision {
            precisionHelper?.tick()
            guard !isTerminal else { return }
        }

        let nowMono = getMonotonicMs()

        // Overall timeout check (48s for 15s trials, 315s for 300s trials)
        let durationMilliseconds = UInt64(testDurationSeconds * 1000.0)
        let timeoutCeilingMs = max(UInt64(48_000), durationMilliseconds + 15_000)
        if (nowMono - probeStartMonoMs) > timeoutCeilingMs {
            fputs("[Probe] Overall timeout \(timeoutCeilingMs / 1000)s reached\n", stderr)
            exitCode = 1; teardown(); return
        }
        // Completion after first valid frame
        if firstValidFrameDecoded && (nowMono - firstValidFrameMonoMs) >= UInt64(testDurationSeconds * 1000.0) {
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

        // Track first effective playing and subsequent nonplaying transitions without auto resume
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
            lastTimeControlStatus = currentTimeControl
            lastPlayerItemStatus = currentItemStatus
            lastWaitingReason = currentReason
            lastRequestedRate = currentReqRate
            lastEffectiveRate = currentEffRate
            lastBufferEmpty = currentBufEmpty
            lastLikelyToKeepUp = currentLikely
            lastStateLogMonoMs = nowMono

            let timeControlStr = currentTimeControl == .playing ? "playing" : (currentTimeControl == .paused ? "paused" : "waiting")
            let statusStr = currentItemStatus == .readyToPlay ? "readyToPlay" : (currentItemStatus == .failed ? "failed" : "unknown")
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let utcStr = iso.string(from: Date())

            var stateRecord: [String: Any] = [
                "event": "state",
                "utc": utcStr,
                "observation_mono_ms": nowMono,
                "startup_mode": startupMode.rawValue,
                "time_control_status": timeControlStr,
                "player_status": statusStr,
                "reason_for_waiting_to_play": currentReason?.rawValue ?? "",
                "requested_rate": sanitizeNumber(Double(currentReqRate)),
                "effective_rate": sanitizeNumber(currentEffRate),
                "waits": currentWaits,
                "buffer_empty": currentBufEmpty,
                "likely_to_keep_up": currentLikely,
                "has_reached_playing": hasReachedFirstEffectivePlaying,
                "nonplaying_transition_count": nonplayingTransitionCount
            ]

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
                exitCode = 1
                teardown()
                return
            }
        }

        // Invalid mapping: no acquisition, still log state
        guard isQueryValid else { return }

        // No B pixel acquisition before didIssueStart
        if startupMode == .precision {
            guard precisionHelper?.didIssueStart == true else { return }
        }

        if firstValidFrameDecoded && (nowMono - lastSampleMonoMs) < 200 { return }

        guard output.hasNewPixelBuffer(forItemTime: queryItemTime) else { return }
        var displayTime = CMTime.invalid
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: queryItemTime, itemTimeForDisplay: &displayTime) else { return }

        let isDisplayValid = displayTime.isValid && !displayTime.isIndefinite && displayTime.isNumeric && displayTime.seconds.isFinite
        let displayAheadSec: Double? = isDisplayValid ? (displayTime.seconds - queryItemTime.seconds) : nil
        let isFutureSample: Bool = (displayAheadSec != nil) ? (displayAheadSec! > 0.050) : false
        let isEligiblePresentation: Bool = isDisplayValid && !isFutureSample

        if isFutureSample, let da = displayAheadSec {
            fputs("[Probe] Future sample detected: displayAhead=\(String(format: "%.1f", da * 1000.0))ms > 50ms; cannot count as presentation proof\n", stderr)
        }

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
            }
            lastSampleMonoMs = observationMonoMs
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let utcStr = iso.string(from: Date())
        let itemDateAge: Double? = item.currentDate().map { Date().timeIntervalSince($0) * 1000.0 }
        let timebaseRate: Double = (item.timebase != nil) ? CMTimebaseGetEffectiveRate(item.timebase!) : 0.0

        let timeControlStr = (p.timeControlStatus == .playing) ? "playing" : ((p.timeControlStatus == .paused) ? "paused" : "waiting")
        let statusStr = (item.status == .readyToPlay) ? "readyToPlay" : ((item.status == .failed) ? "failed" : "unknown")

        var record: [String: Any] = [
            "utc": utcStr, "observation_mono_ms": observationMonoMs,
            "startup_mode": startupMode.rawValue,
            "effective_timebase_rate": sanitizeNumber(timebaseRate),
            "requested_rate": sanitizeNumber(Double(currentReqRate)),
            "effective_rate": sanitizeNumber(currentEffRate),
            "waits": currentWaits,
            "time_control_status": timeControlStr, "player_status": statusStr,
            "configured_offset_seconds": sanitizeNumber(item.configuredTimeOffsetFromLive.seconds),
            "recommended_offset_seconds": sanitizeNumber(item.recommendedTimeOffsetFromLive.seconds),
            "valid": decoded != nil, "failure_count": failureCount,
            "presentation_eligible": isEligiblePresentation,
            "is_future_sample": isFutureSample
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
        if let m = decoded { record["frame_id"] = m.frameId; record["source_mono_ms"] = m.sourceMonoMs; record["age_ms"] = m.ageMs }
        if let err = errorString { record["error"] = err }
        if firstValidFrameDecoded { record["startup_elapsed_ms"] = firstFrameStartupElapsedMs }

        do {
            try writer?.writeEntry(record)
        } catch {
            fputs("[Probe] Write error during tick: \(error)\n", stderr)
            exitCode = 1
            teardown()
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

        if startupMode == .native {
            fputs("[Probe] Native mode: playing url=\(url), nonce=\(nonce), waits=\(waits), offsetMs=\(offsetMs)\n", stderr)
            player?.play()
        } else {
            fputs("[Probe] Precision mode: arm B primed, url=\(url), nonce=\(nonce), waits=\(waits), offsetMs=\(offsetMs)\n", stderr)
        }

        let t = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.processTick() }
        self.timer = t
        RunLoop.main.add(t, forMode: .common)
        while !isTerminal { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
        teardown()
        return exitCode
    }
}

// MARK: - Main CLI Parsing and DispatchSourceSignal Handling

var gRetainedSignalSources: [DispatchSourceSignal] = []

func setupRetainedSignalSources(runner: ProbeRunner) {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    for sig in [SIGINT, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            fputs("[Probe] Main dispatch signal \(sig) caught\n", stderr)
            runner.exitCode = 1
            runner.teardown()
            exit(1)
        }
        source.resume()
        gRetainedSignalSources.append(source)
    }
}

func main() {
    var urlString: String?, nonce: UInt32?, outputPath: String?, duration: Double = 15.0, calibratePath: String?, waitsBool: Bool?, offsetMsVal: Int?, forwardBufferVal: Double = 1.2
    var startupModeStr: String?
    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        switch args[i] {
        case "--url": if i + 1 < args.count { urlString = args[i + 1]; i += 1 }
        case "--nonce": if i + 1 < args.count { nonce = UInt32(args[i + 1]); i += 1 }
        case "--output": if i + 1 < args.count { outputPath = args[i + 1]; i += 1 }
        case "--duration":
            if i + 1 < args.count {
                duration = Double(args[i + 1]) ?? -1.0
                i += 1
            } else {
                duration = -1.0
            }
        case "--calibrate": if i + 1 < args.count { calibratePath = args[i + 1]; i += 1 }
        case "--waits":
            if i + 1 < args.count {
                let v = args[i + 1].lowercased()
                if v == "true" { waitsBool = true }
                else if v == "false" { waitsBool = false }
                i += 1
            }
        case "--offset-ms":
            if i + 1 < args.count {
                offsetMsVal = Int(args[i + 1])
                i += 1
            }
        case "--forward-buffer":
            if i + 1 < args.count {
                forwardBufferVal = Double(args[i + 1]) ?? -1.0
                i += 1
            } else {
                forwardBufferVal = -1.0
            }
        case "--startup-mode":
            if i + 1 < args.count {
                startupModeStr = args[i + 1]
                i += 1
            }
        default: break
        }
        i += 1
    }

    if let calib = calibratePath {
        guard let n = nonce, let out = outputPath else {
            fputs("Usage: Probe --calibrate <PNG> --nonce <UINT32> --output <JSONL>\n", stderr); exit(1)
        }
        exit(runCalibration(pngPath: calib, nonce: n, outputPath: out))
    }
    guard let uStr = urlString, let url = URL(string: uStr), let n = nonce, let out = outputPath, let waits = waitsBool, let offset = offsetMsVal else {
        fputs("Usage: Probe --url <HLS_URL> --nonce <UINT32> --output <JSONL> --waits <true> --offset-ms <1002|1200> [--duration 15|300] [--forward-buffer 1.2|0.334] [--startup-mode native|precision]\n", stderr); exit(1)
    }
    guard waits == true else {
        fputs("--waits must be true for initial playback configuration\n", stderr); exit(1)
    }
    guard offset == 1002 || offset == 1200 else {
        fputs("--offset-ms must be 1002 or 1200\n", stderr); exit(1)
    }
    guard duration.isFinite && (duration == 15.0 || duration == 300.0) else {
        fputs("--duration must be exactly 15 or 300\n", stderr); exit(1)
    }
    guard forwardBufferVal.isFinite && (forwardBufferVal == 1.2 || forwardBufferVal == 0.334 || abs(forwardBufferVal - 1.2) < 1e-6 || abs(forwardBufferVal - 0.334) < 1e-6) else {
        fputs("--forward-buffer must be 1.2 or 0.334\n", stderr); exit(1)
    }
    let forwardBuffer = (abs(forwardBufferVal - 0.334) < 1e-6) ? 0.334 : 1.2

    let mode: StartupMode
    if let mStr = startupModeStr {
        guard let m = StartupMode(rawValue: mStr) else {
            fputs("--startup-mode must be native or precision\n", stderr)
            exit(1)
        }
        mode = m
    } else {
        mode = .native
    }

    let runner = ProbeRunner(url: url, nonce: n, outputPath: out, testDurationSeconds: duration, waits: waits, offsetMs: offset, forwardBufferSeconds: forwardBuffer, startupMode: mode)
    setupRetainedSignalSources(runner: runner)
    exit(runner.run())
}

main()
