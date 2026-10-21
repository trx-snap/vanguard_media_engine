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
    var urlString: String?, nonce: UInt32?, outputPath: String?, duration: Double = 65.0, calibratePath: String?, waitsBool: Bool?, offsetMsVal: Int?, forwardBufferVal: Double = 1.2
    var startupModeStr: String?
    var recoveryModeStr: String?
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
        case "--recovery-mode":
            if i + 1 < args.count {
                recoveryModeStr = args[i + 1]
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
        fputs("Usage: Probe --url <HLS_URL> --nonce <UINT32> --output <JSONL> --waits <true> --offset-ms <1002|1200> [--duration 40|65|15|300] [--forward-buffer 1.2|0.334] [--startup-mode native|precision] [--recovery-mode observe|rebuild]\n", stderr); exit(1)
    }
    guard waits == true else {
        fputs("--waits must be true for initial playback configuration\n", stderr); exit(1)
    }
    guard offset == 1002 || offset == 1200 else {
        fputs("--offset-ms must be 1002 or 1200\n", stderr); exit(1)
    }
    guard duration.isFinite && (duration == 40.0 || duration == 65.0 || duration == 15.0 || duration == 300.0) else {
        fputs("--duration must be exactly 40 or 65 (or 15|300)\n", stderr); exit(1)
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
        mode = .precision
    }

    let recoveryMode: RecoveryMode
    if let rStr = recoveryModeStr {
        guard let r = RecoveryMode(rawValue: rStr) else {
            fputs("--recovery-mode must be observe or rebuild\n", stderr)
            exit(1)
        }
        recoveryMode = r
    } else {
        recoveryMode = .rebuild
    }

    let runner = ProbeRunner(
        url: url,
        nonce: n,
        outputPath: out,
        testDurationSeconds: duration,
        waits: waits,
        offsetMs: offset,
        forwardBufferSeconds: forwardBuffer,
        startupMode: mode,
        recoveryMode: recoveryMode
    )
    setupRetainedSignalSources(runner: runner)
    exit(runner.run())
}

main()
