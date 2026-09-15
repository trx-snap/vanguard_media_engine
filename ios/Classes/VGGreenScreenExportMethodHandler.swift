// VGGreenScreenExportMethodHandler.swift
// Thin dispatch layer from VanguardMediaEnginePlugin for green-screen export routes.

import Flutter
import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import UIKit

/// Thin dispatch handler for green-screen export MethodChannel routes.
/// Plugin owns one instance and calls `handle` for routes `ownsMethod` returns true for.
final class VGGreenScreenExportMethodHandler {

    // MARK: - Owned routes

    private static let ownedMethods: Set<String> = [
        "exportGreenScreenComposition",
        "prepareIosGreenScreenExportApiPixelProofFixtures",
        "assertIosGreenScreenExportApiPixelProofOutput",
    ]

    static func ownsMethod(_ method: String) -> Bool {
        return ownedMethods.contains(method)
    }

    // MARK: - Session

    private let exportSession = VGGreenScreenExportSession()
    private let diagnostics = VGGreenScreenExportPixelProofDiagnostics()

    // MARK: - Init

    init() {
    }

    // MARK: - Dispatch

    func handle(method: String, args: [String: Any]?, result: @escaping FlutterResult) {
        switch method {

        case "exportGreenScreenComposition":
            exportSession.export(args: args, result: result)

        case "prepareIosGreenScreenExportApiPixelProofFixtures":
            diagnostics.prepareFixtures(args: args, result: result)

        case "assertIosGreenScreenExportApiPixelProofOutput":
            diagnostics.assertOutput(args: args, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Teardown

    func disposeAll() {
        exportSession.disposeAll()
        diagnostics.disposeAll()
    }
}

// MARK: - Decoded-pixel proof diagnostics coordinator

/// Diagnostic coordinator for iOS green-screen export decoded-pixel proof.
/// Contained within this file so the existing Xcode/Pods project compiles it
/// without requiring CocoaPods project regeneration.
final class VGGreenScreenExportPixelProofDiagnostics {

    static let defaultForegroundRgb = [240, 20, 20]
    static let defaultSolidBackgroundRgb = [20, 20, 240]
    static let defaultImageCenterRgb = [20, 240, 20]
    static let defaultLetterboxRgb = [0, 0, 0]

    private static let defaultWidth = 360
    private static let defaultHeight = 640
    private static let defaultFps = 30
    private static let defaultFrameCount = 6
    private static let defaultBitrate = 1_500_000
    private static let defaultTolerance = 80

    private let lock = NSLock()
    private var disposed = false
    private let queue = DispatchQueue(label: "com.connects.vanguard.greenscreen.pixelproof", qos: .userInitiated)

    init() {}

    func disposeAll() {
        lock.lock()
        disposed = true
        lock.unlock()
    }

    // MARK: - Fixture preparation

    func prepareFixtures(args: [String: Any]?, result: @escaping FlutterResult) {
        lock.lock()
        if disposed {
            lock.unlock()
            result(FlutterError(code: "DISPOSED", message: "Diagnostics coordinator disposed", details: nil))
            return
        }
        lock.unlock()

        guard let workDir = args?["workDir"] as? String,
              !workDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result(FlutterError(
                code: "INVALID_ARG",
                message: "prepareIosGreenScreenExportApiPixelProofFixtures: 'workDir' required",
                details: nil
            ))
            return
        }

        let width = intValue(args?["width"]) ?? 360
        let height = intValue(args?["height"]) ?? 640
        let fps = intValue(args?["fps"]) ?? 30
        let frameCount = intValue(args?["frameCount"]) ?? 6
        let bitrate = intValue(args?["bitrate"]) ?? 1_500_000

        queue.async { [weak self] in
            guard let self = self else { return }
            let payload = self.doPrepareFixtures(
                workDirPath: workDir,
                width: width,
                height: height,
                fps: fps,
                frameCount: frameCount,
                bitrate: bitrate
            )
            DispatchQueue.main.async {
                result(payload)
            }
        }
    }

    private func doPrepareFixtures(
        workDirPath: String,
        width: Int,
        height: Int,
        fps: Int,
        frameCount: Int,
        bitrate: Int
    ) -> [String: Any] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: workDirPath, isDirectory: &isDirectory) || !isDirectory.boolValue {
            do {
                try fileManager.createDirectory(atPath: workDirPath, withIntermediateDirectories: true, attributes: nil)
            } catch {
                return [
                    "pass": false,
                    "reason": "work_dir_creation_failed:\(error.localizedDescription)"
                ]
            }
        }

        let fgFixturePath = (workDirPath as NSString).appendingPathComponent("gs_proof_fg_fixture.mp4")
        let bgImagePath = (workDirPath as NSString).appendingPathComponent("gs_proof_bg_image.png")

        // 1. Solid red foreground MP4
        if let fgError = generateSolidRedVideo(
            outputPath: fgFixturePath,
            width: width,
            height: height,
            fps: fps,
            frameCount: frameCount,
            bitrate: bitrate
        ) {
            return ["pass": false, "reason": "foreground_fixture_failed:\(fgError)"]
        }

        // 2. Landscape PNG background (320x160, green [20, 240, 20])
        if let pngError = generateLandscapePng(outputPath: bgImagePath) {
            return ["pass": false, "reason": "background_png_failed:\(pngError)"]
        }

        // 3. R8 mask frame files (64x64, alternating 0 and 255)
        let (maskPaths, maskError) = generateR8MaskFiles(workDirPath: workDirPath, frameCount: frameCount)
        if let maskError = maskError {
            return ["pass": false, "reason": "r8_masks_failed:\(maskError)"]
        }

        return [
            "pass": true,
            "reason": "pass",
            "foregroundVideoPath": fgFixturePath,
            "backgroundImagePath": bgImagePath,
            "maskFramePaths": maskPaths,
            "maskWidth": 64,
            "maskHeight": 64,
            "expectedForegroundRgb": Self.defaultForegroundRgb,
            "expectedSolidBackgroundRgb": Self.defaultSolidBackgroundRgb,
            "expectedImageCenterRgb": Self.defaultImageCenterRgb,
            "expectedLetterboxRgb": Self.defaultLetterboxRgb,
        ]
    }

    private func generateSolidRedVideo(
        outputPath: String,
        width: Int,
        height: Int,
        fps: Int,
        frameCount: Int,
        bitrate: Int
    ) -> String? {
        let fileURL = URL(fileURLWithPath: outputPath)
        if FileManager.default.fileExists(atPath: outputPath) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        } catch {
            return "writer_init_failed:\(error.localizedDescription)"
        }

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: 1,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            return "writer_settings_rejected"
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: sourceAttributes)

        guard writer.canAdd(input) else {
            return "writer_input_rejected"
        }
        writer.add(input)

        guard writer.startWriting() else {
            return "writer_start_failed:\(writer.error?.localizedDescription ?? "unknown")"
        }
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<frameCount {
            let deadline = Date(timeIntervalSinceNow: 5.0)
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    return "writer_failed_during_write:\(writer.error?.localizedDescription ?? "unknown")"
                }
                if Date() > deadline {
                    return "writer_not_ready_timeout:frame=\(frameIndex)"
                }
                usleep(1_000)
            }

            var pixelBuffer: CVPixelBuffer?
            let pool = adaptor.pixelBufferPool
            let status = pool != nil
                ? CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool!, &pixelBuffer)
                : CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, sourceAttributes as CFDictionary, &pixelBuffer)
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                return "pixel_buffer_alloc_failed:frame=\(frameIndex):status=\(status)"
            }

            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                let byteB: UInt8 = UInt8(Self.defaultForegroundRgb[2])
                let byteG: UInt8 = UInt8(Self.defaultForegroundRgb[1])
                let byteR: UInt8 = UInt8(Self.defaultForegroundRgb[0])
                let byteA: UInt8 = 255
                for y in 0..<height {
                    let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width {
                        row[x * 4 + 0] = byteB
                        row[x * 4 + 1] = byteG
                        row[x * 4 + 2] = byteR
                        row[x * 4 + 3] = byteA
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                return "writer_append_failed:frame=\(frameIndex):\(writer.error?.localizedDescription ?? "unknown")"
            }
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(fps)))

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting {
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5.0)

        guard writer.status == .completed else {
            return "writer_finish_failed:status=\(writer.status.rawValue):\(writer.error?.localizedDescription ?? "unknown")"
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outputPath, isDirectory: &isDir), !isDir.boolValue else {
            return "output_file_missing_after_finish"
        }
        return nil
    }

    private func generateLandscapePng(outputPath: String) -> String? {
        let imgWidth = 320
        let imgHeight = 160
        let size = CGSize(width: imgWidth, height: imgHeight)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            // Center and overall fill: green [20, 240, 20]
            UIColor(
                red: CGFloat(Self.defaultImageCenterRgb[0]) / 255.0,
                green: CGFloat(Self.defaultImageCenterRgb[1]) / 255.0,
                blue: CGFloat(Self.defaultImageCenterRgb[2]) / 255.0,
                alpha: 1.0
            ).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let pngData = image.pngData() else {
            return "png_encode_failed"
        }
        do {
            try pngData.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            return "png_write_failed:\(error.localizedDescription)"
        }
        guard FileManager.default.fileExists(atPath: outputPath) else {
            return "png_file_missing"
        }
        return nil
    }

    private func generateR8MaskFiles(workDirPath: String, frameCount: Int, maskDim: Int = 64) -> ([String], String?) {
        var paths: [String] = []
        let bufferSize = maskDim * maskDim
        let zeroBytes = Data(repeating: 0, count: bufferSize)
        let fullBytes = Data(repeating: 255, count: bufferSize)

        for i in 0..<frameCount {
            let maskPath = (workDirPath as NSString).appendingPathComponent("gs_proof_mask_frame_\(i).r8")
            let data = (i % 2 == 0) ? zeroBytes : fullBytes
            do {
                try data.write(to: URL(fileURLWithPath: maskPath))
                paths.append(maskPath)
            } catch {
                return ([], "mask_write_failed:frame=\(i):\(error.localizedDescription)")
            }
        }
        return (paths, nil)
    }

    // MARK: - Decoded-pixel output assertion

    func assertOutput(args: [String: Any]?, result: @escaping FlutterResult) {
        lock.lock()
        if disposed {
            lock.unlock()
            result(["pass": false, "reason": "coordinator_disposed"])
            return
        }
        lock.unlock()

        guard let outputPath = args?["outputPath"] as? String,
              let lane = args?["lane"] as? String,
              !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !lane.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result(["pass": false, "reason": "invalid_arguments: outputPath and lane required"])
            return
        }

        let width = intValue(args?["width"]) ?? 360
        let height = intValue(args?["height"]) ?? 640
        let fps = intValue(args?["fps"]) ?? 30
        let frameCount = intValue(args?["frameCount"]) ?? 6
        let tolerance = intValue(args?["tolerance"]) ?? 80

        let expectedFg = parseRgbList(args?["expectedForegroundRgb"], defaultVal: Self.defaultForegroundRgb)
        let expectedBg = parseRgbList(args?["expectedBackgroundRgb"], defaultVal: Self.defaultSolidBackgroundRgb)
        let expectedImgCenter = parseRgbList(args?["expectedImageCenterRgb"], defaultVal: Self.defaultImageCenterRgb)
        let expectedLetterbox = parseRgbList(args?["expectedLetterboxRgb"], defaultVal: Self.defaultLetterboxRgb)

        queue.async { [weak self] in
            guard let self = self else { return }
            let outcome = self.decodeAndAssert(
                outputPath: outputPath,
                lane: lane,
                width: width,
                height: height,
                fps: fps,
                frameCount: frameCount,
                tolerance: tolerance,
                expectedForegroundRgb: expectedFg,
                expectedBackgroundRgb: expectedBg,
                expectedImageCenterRgb: expectedImgCenter,
                expectedLetterboxRgb: expectedLetterbox
            )
            DispatchQueue.main.async {
                result(outcome)
            }
        }
    }

    private func decodeAndAssert(
        outputPath: String,
        lane: String,
        width: Int,
        height: Int,
        fps: Int,
        frameCount: Int,
        tolerance: Int,
        expectedForegroundRgb: [Int],
        expectedBackgroundRgb: [Int],
        expectedImageCenterRgb: [Int],
        expectedLetterboxRgb: [Int]
    ) -> [String: Any] {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: outputPath, isDirectory: &isDir),
              !isDir.boolValue,
              let attrs = try? fileManager.attributesOfItem(atPath: outputPath),
              let fileSize = attrs[.size] as? NSNumber,
              fileSize.int64Value > 0 else {
            return [
                "pass": false,
                "reason": "output_file_missing_or_empty",
                "lane": lane,
                "outputPath": outputPath,
            ]
        }

        let asset = AVURLAsset(url: URL(fileURLWithPath: outputPath), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = asset.tracks(withMediaType: .video).first else {
            return [
                "pass": false,
                "reason": "no_video_track_in_output",
                "lane": lane,
                "outputPath": outputPath,
            ]
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            return [
                "pass": false,
                "reason": "reader_init_failed:\(error.localizedDescription)",
                "lane": lane,
                "outputPath": outputPath,
            ]
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else {
            return [
                "pass": false,
                "reason": "reader_cannot_add_output",
                "lane": lane,
                "outputPath": outputPath,
            ]
        }
        reader.add(trackOutput)
        guard reader.startReading() else {
            return [
                "pass": false,
                "reason": "reader_start_failed:\(reader.error?.localizedDescription ?? "unknown")",
                "lane": lane,
                "outputPath": outputPath,
            ]
        }

        var sampleBuffers: [CMSampleBuffer] = []
        while let sb = trackOutput.copyNextSampleBuffer() {
            sampleBuffers.append(sb)
        }

        if sampleBuffers.isEmpty {
            return [
                "pass": false,
                "reason": "no_samples_read_from_video:status=\(reader.status.rawValue):\(reader.error?.localizedDescription ?? "unknown")",
                "lane": lane,
                "outputPath": outputPath,
            ]
        }

        var perFramePixelResults: [[String: Any]] = []
        var anySampleFailed = false

        if sampleBuffers.count < frameCount {
            anySampleFailed = true
        }

        for i in 0..<frameCount {
            let sb: CMSampleBuffer
            if sampleBuffers.indices.contains(i) && sampleBuffers.count == frameCount {
                sb = sampleBuffers[i]
            } else {
                let targetTime = (Double(i) + 0.25) / Double(fps)
                var bestDiff = Double.infinity
                var bestMatch = sampleBuffers[0]
                for candidate in sampleBuffers {
                    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(candidate))
                    let diff = abs(pts - targetTime)
                    if diff < bestDiff {
                        bestDiff = diff
                        bestMatch = candidate
                    }
                }
                sb = bestMatch
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sb) else {
                perFramePixelResults.append([
                    "frameIndex": i,
                    "pass": false,
                    "reason": "null_image_buffer"
                ])
                anySampleFailed = true
                continue
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                perFramePixelResults.append([
                    "frameIndex": i,
                    "pass": false,
                    "reason": "null_base_address"
                ])
                anySampleFailed = true
                continue
            }

            let bw = CVPixelBufferGetWidth(pixelBuffer)
            let bh = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

            let cx = min(max(bw / 2, 0), bw - 1)
            let cy = min(max(bh / 2, 0), bh - 1)

            func readRgb(x: Int, y: Int) -> [Int] {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                let b = Int(row[x * 4 + 0])
                let g = Int(row[x * 4 + 1])
                let r = Int(row[x * 4 + 2])
                return [r, g, b]
            }

            switch lane {
            case "solid_r8_ladder":
                let actual = readRgb(x: cx, y: cy)
                let showsForeground = (i % 2 == 1)
                let expected = showsForeground ? expectedForegroundRgb : expectedBackgroundRgb
                let diffs = [
                    abs(actual[0] - expected[0]),
                    abs(actual[1] - expected[1]),
                    abs(actual[2] - expected[2])
                ]
                let framePass = diffs.allSatisfy { $0 <= tolerance }
                if !framePass { anySampleFailed = true }
                perFramePixelResults.append([
                    "frameIndex": i,
                    "pass": framePass,
                    "showsForeground": showsForeground,
                    "expectedRgb": expected,
                    "actualRgb": actual,
                    "diffs": diffs,
                ])

            case "image_fit_background":
                let topX = cx
                let topY = min(max(bh / 10, 0), bh - 1)
                let topActual = readRgb(x: topX, y: topY)
                let topExpected = expectedLetterboxRgb
                let topDiffs = [
                    abs(topActual[0] - topExpected[0]),
                    abs(topActual[1] - topExpected[1]),
                    abs(topActual[2] - topExpected[2])
                ]
                let topPass = topDiffs.allSatisfy { $0 <= tolerance }

                let centerActual = readRgb(x: cx, y: cy)
                let centerExpected = expectedImageCenterRgb
                let centerDiffs = [
                    abs(centerActual[0] - centerExpected[0]),
                    abs(centerActual[1] - centerExpected[1]),
                    abs(centerActual[2] - centerExpected[2])
                ]
                let centerPass = centerDiffs.allSatisfy { $0 <= tolerance }

                let framePass = topPass && centerPass
                if !framePass { anySampleFailed = true }
                perFramePixelResults.append([
                    "frameIndex": i,
                    "pass": framePass,
                    "topPass": topPass,
                    "topActualRgb": topActual,
                    "topExpectedRgb": topExpected,
                    "topDiffs": topDiffs,
                    "centerPass": centerPass,
                    "centerActualRgb": centerActual,
                    "centerExpectedRgb": centerExpected,
                    "centerDiffs": centerDiffs,
                ])

            case "image_fill_background":
                let topX = cx
                let topY = min(max(bh / 10, 0), bh - 1)
                let topActual = readRgb(x: topX, y: topY)
                let topExpected = expectedImageCenterRgb
                let topDiffs = [
                    abs(topActual[0] - topExpected[0]),
                    abs(topActual[1] - topExpected[1]),
                    abs(topActual[2] - topExpected[2])
                ]
                let topMatchesImage = topDiffs.allSatisfy { $0 <= tolerance }
                let topIsNonBlack = topActual.contains { $0 > 100 }
                let topPass = topMatchesImage && topIsNonBlack

                let centerActual = readRgb(x: cx, y: cy)
                let centerExpected = expectedImageCenterRgb
                let centerDiffs = [
                    abs(centerActual[0] - centerExpected[0]),
                    abs(centerActual[1] - centerExpected[1]),
                    abs(centerActual[2] - centerExpected[2])
                ]
                let centerPass = centerDiffs.allSatisfy { $0 <= tolerance }

                let framePass = topPass && centerPass
                if !framePass { anySampleFailed = true }
                perFramePixelResults.append([
                    "frameIndex": i,
                    "pass": framePass,
                    "topPass": topPass,
                    "topMatchesImage": topMatchesImage,
                    "topIsNonBlack": topIsNonBlack,
                    "topActualRgb": topActual,
                    "topExpectedRgb": topExpected,
                    "topDiffs": topDiffs,
                    "centerPass": centerPass,
                    "centerActualRgb": centerActual,
                    "centerExpectedRgb": centerExpected,
                    "centerDiffs": centerDiffs,
                ])

            default:
                perFramePixelResults.append([
                    "frameIndex": i,
                    "pass": false,
                    "reason": "unknown_lane:\(lane)"
                ])
                anySampleFailed = true
            }

            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        let isPass = perFramePixelResults.count == frameCount && !anySampleFailed
        let reason = isPass ? "pass" : "pixel_assertion_failed_for_lane_\(lane)"
        return [
            "pass": isPass,
            "reason": reason,
            "lane": lane,
            "outputPath": outputPath,
            "frameCount": frameCount,
            "decodedFrameCount": perFramePixelResults.count,
            "pixelTolerance": tolerance,
            "perFramePixelResults": perFramePixelResults,
            "frameResults": perFramePixelResults,
        ]
    }

    // MARK: - Value coercion

    private func intValue(_ raw: Any?) -> Int? {
        guard let raw = raw, !(raw is NSNull) else { return nil }
        if let val = raw as? Int { return val }
        if let num = raw as? NSNumber { return num.intValue }
        return nil
    }

    private func parseRgbList(_ raw: Any?, defaultVal: [Int]) -> [Int] {
        guard let list = raw as? [Any] else { return defaultVal }
        let ints = list.compactMap { ($0 as? NSNumber)?.intValue ?? ($0 as? Int) }
        return ints.count == 3 ? ints : defaultVal
    }
}
