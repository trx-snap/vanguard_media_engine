// VGLiveGreenScreenReplayDiagnostics.swift
// Generic live green-screen: replay diagnostics helper and errors.
//
// Three offline, deterministic, diagnostic-only entry points (none is public Dart API):
//   - writeReplayInputBundle: captures the exact background/camera/mask CVPixelBuffers
//     and layout rects into a replay bundle directory.
//   - replay(inputDir:outputPath:label:): re-runs VGDuetPreviewCompositor.composite on a
//     bundle (a compositor constructed explicitly with the production live green-screen
//     default mode, VGMatteRefinementPipeline.defaultLiveMatteRefinementMode; the generic
//     compositor's own init default is the neutral .s1) and encodes the result to one PNG.
//   - runMatteStageLab(inputDir:outputDir:label:refinementMode:): re-runs the same bundle
//     through the compositor's matte refinement stage tap and dumps one PNG per stage (raw
//     mask, aspect-filled mask, post morphology, post feather, post trimap, post guided edge,
//     final composite) so edge artifacts can be attributed to the stage that introduces them.
//     refinementMode defaults to .s1 (the S1 base stages, the explicit live s1 fallback;
//     seven PNGs, 07 is composite()'s pool output from a lab compositor pinned to .s1).
//     .s4GuidedAlphaR1 (plus S4-family parameter variants: .s4SoftAlphaR2,
//     the production live default as well as an offline lab mode; and
//     .s4TightAlphaR2, which remains lab-only) and .s5GuidedFilterR1 are lab
//     modes: stages 01-05 are unchanged, 06/07 reflect the mode-selected final
//     mask/composite (07 is built here with composite()'s CIBlendWithMask recipe because
//     the lab compositor is pinned to .s1), and an eighth PNG shows where the candidate
//     acted (08_s4_guided_alpha_band.png for every S4-family mode,
//     08_s5_guided_filter_band.png for S5). s4TightAlphaR2 has no live counterpart.
//     .tightAlphaR1 is the offline lab evaluation of the live opt-in tight-alpha post-pass
//     (the same applyLiveTightAlphaR1 recipe over the S1 final mask): the seven standard
//     PNG names only, 06/07 reflect the tight-alpha-selected final mask/composite, no band
//     file. Selecting it here never changes the live default
//     (VGMatteRefinementPipeline.defaultLiveMatteRefinementMode, .s4SoftAlphaR2).
// All writes refuse to overwrite existing files. No camera or ML segmentation runs here.

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import UIKit

// MARK: - Replay Error

enum VGLiveGreenScreenReplayError: LocalizedError {
    case invalidArgument(String)
    case unsupportedFormat(String)
    case emptyDimensions(String)
    case missingBaseAddress(String)
    case fileCollision(String)
    case compositionFailed(String)
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let msg):    return "invalid_arg: \(msg)"
        case .unsupportedFormat(let msg):  return "unsupported_format: \(msg)"
        case .emptyDimensions(let msg):    return "empty_dimensions: \(msg)"
        case .missingBaseAddress(let msg): return "missing_base_address: \(msg)"
        case .fileCollision(let msg):      return "file_collision: \(msg)"
        case .compositionFailed(let msg):  return "composition_failed: \(msg)"
        case .ioError(let msg):            return "io_error: \(msg)"
        }
    }

    var isInvalidArgument: Bool {
        switch self {
        case .invalidArgument, .fileCollision:
            return true
        default:
            return false
        }
    }
}

// MARK: - Replay Diagnostics Helper

final class VGLiveGreenScreenReplayDiagnostics {

    // Bundle filenames
    static let metadataFileName   = "metadata.json"
    static let backgroundFileName = "background.bgra"
    static let cameraFileName     = "camera.bgra"
    static let maskFileName       = "mask.r8"

    private static let replayCIContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .cacheIntermediates: false,
    ])

    // MARK: - Buffer Extraction (Write)

    private struct BufferRawData {
        let data: Data
        let width: Int
        let height: Int
        let rowStride: Int
        let formatString: String
    }

    private static func extractRawBytes(from buffer: CVPixelBuffer,
                                        expectedFormat: OSType,
                                        formatName: String) throws -> BufferRawData {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == expectedFormat else {
            throw VGLiveGreenScreenReplayError.unsupportedFormat(
                "Expected pixel format '\(formatName)' (\(expectedFormat)), got \(format)."
            )
        }

        guard !CVPixelBufferIsPlanar(buffer) else {
            throw VGLiveGreenScreenReplayError.unsupportedFormat("Planar pixel buffers are not supported.")
        }

        let width  = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else {
            throw VGLiveGreenScreenReplayError.emptyDimensions(
                "Buffer dimensions \(width)x\(height) must be positive."
            )
        }

        let lockStatus = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            throw VGLiveGreenScreenReplayError.missingBaseAddress(
                "CVPixelBufferLockBaseAddress failed with code \(lockStatus)."
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw VGLiveGreenScreenReplayError.missingBaseAddress("CVPixelBufferGetBaseAddress returned nil.")
        }

        let rowStride = CVPixelBufferGetBytesPerRow(buffer)
        guard rowStride > 0 else {
            throw VGLiveGreenScreenReplayError.emptyDimensions("CVPixelBufferGetBytesPerRow returned \(rowStride) <= 0.")
        }

        var data = Data(capacity: height * rowStride)
        for y in 0..<height {
            let rowPtr = base.advanced(by: y * rowStride).assumingMemoryBound(to: UInt8.self)
            data.append(rowPtr, count: rowStride)
        }

        return BufferRawData(data: data,
                             width: width,
                             height: height,
                             rowStride: rowStride,
                             formatString: formatName)
    }

    // MARK: - Write Replay Input Bundle

    /// Writes raw inputs (background, camera, mask) row-by-row into [outputDir],
    /// along with metadata.json containing canvas size and layout rects.
    /// Fails closed if any target file already exists (refuses overwrite).
    static func writeReplayInputBundle(outputDir: String,
                                       label: String,
                                       canvasWidth: Int,
                                       canvasHeight: Int,
                                       sourceFrame: CVPixelBuffer,
                                       sourceRect: CGRect,
                                       cameraRect: CGRect,
                                       cameraFrame: CVPixelBuffer,
                                       maskFrame: CVPixelBuffer) throws -> [String: Any] {
        guard canvasWidth > 0, canvasHeight > 0 else {
            throw VGLiveGreenScreenReplayError.emptyDimensions("Canvas dimensions \(canvasWidth)x\(canvasHeight) must be positive.")
        }

        let trimmedOutputDir = outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutputDir.isEmpty else {
            throw VGLiveGreenScreenReplayError.invalidArgument("outputDir must not be empty.")
        }

        let dirURL = URL(fileURLWithPath: trimmedOutputDir)
        let metadataURL   = dirURL.appendingPathComponent(metadataFileName)
        let backgroundURL = dirURL.appendingPathComponent(backgroundFileName)
        let cameraURL     = dirURL.appendingPathComponent(cameraFileName)
        let maskURL       = dirURL.appendingPathComponent(maskFileName)

        // Refuse overwrite: fail closed if any bundle file already exists.
        for fileURL in [metadataURL, backgroundURL, cameraURL, maskURL] {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                throw VGLiveGreenScreenReplayError.fileCollision(
                    "Replay bundle file already exists at '\(fileURL.path)'. Overwrite is refused."
                )
            }
        }

        // Create output directory if needed.
        try ensureOutputDirectory(dirURL)

        // Extract raw bytes row-by-row.
        let bgData = try extractRawBytes(from: sourceFrame,
                                         expectedFormat: kCVPixelFormatType_32BGRA,
                                         formatName: "kCVPixelFormatType_32BGRA")
        let camData = try extractRawBytes(from: cameraFrame,
                                          expectedFormat: kCVPixelFormatType_32BGRA,
                                          formatName: "kCVPixelFormatType_32BGRA")
        let maskData = try extractRawBytes(from: maskFrame,
                                           expectedFormat: kCVPixelFormatType_OneComponent8,
                                           formatName: "kCVPixelFormatType_OneComponent8")

        // Build metadata.json dictionary.
        let metadata: [String: Any] = [
            "version": 1,
            "label": label,
            "canvasWidth": canvasWidth,
            "canvasHeight": canvasHeight,
            "sourceRect": [
                "x": Double(sourceRect.origin.x),
                "y": Double(sourceRect.origin.y),
                "width": Double(sourceRect.size.width),
                "height": Double(sourceRect.size.height),
            ],
            "cameraRect": [
                "x": Double(cameraRect.origin.x),
                "y": Double(cameraRect.origin.y),
                "width": Double(cameraRect.size.width),
                "height": Double(cameraRect.size.height),
            ],
            "background": [
                "file": backgroundFileName,
                "width": bgData.width,
                "height": bgData.height,
                "rowStride": bgData.rowStride,
                "pixelFormat": bgData.formatString,
            ],
            "camera": [
                "file": cameraFileName,
                "width": camData.width,
                "height": camData.height,
                "rowStride": camData.rowStride,
                "pixelFormat": camData.formatString,
            ],
            "mask": [
                "file": maskFileName,
                "width": maskData.width,
                "height": maskData.height,
                "rowStride": maskData.rowStride,
                "pixelFormat": maskData.formatString,
            ],
            "buffers": [
                "background": [
                    "file": backgroundFileName,
                    "width": bgData.width,
                    "height": bgData.height,
                    "rowStride": bgData.rowStride,
                    "pixelFormat": bgData.formatString,
                ],
                "camera": [
                    "file": cameraFileName,
                    "width": camData.width,
                    "height": camData.height,
                    "rowStride": camData.rowStride,
                    "pixelFormat": camData.formatString,
                ],
                "mask": [
                    "file": maskFileName,
                    "width": maskData.width,
                    "height": maskData.height,
                    "rowStride": maskData.rowStride,
                    "pixelFormat": maskData.formatString,
                ],
            ],
        ]

        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw VGLiveGreenScreenReplayError.compositionFailed("Failed to serialize metadata.json: \(error.localizedDescription)")
        }

        // Write all files atomically.
        do {
            try bgData.data.write(to: backgroundURL, options: .atomic)
            try camData.data.write(to: cameraURL, options: .atomic)
            try maskData.data.write(to: maskURL, options: .atomic)
            try jsonData.write(to: metadataURL, options: .atomic)
        } catch {
            throw VGLiveGreenScreenReplayError.ioError("Failed writing bundle file: \(error.localizedDescription)")
        }

        NSLog("[VGLiveGreenScreenReplayDiagnostics] IOS_LIVE_GREENSCREEN_REPLAY_INPUT_BUNDLE_CAPTURED dir=\(trimmedOutputDir) label=\(label) canvas=\(canvasWidth)x\(canvasHeight)")

        return [
            "path": trimmedOutputDir,
            "outputDir": trimmedOutputDir,
            "label": label,
            "canvasWidth": canvasWidth,
            "canvasHeight": canvasHeight,
            "sourceRect": [
                "x": Double(sourceRect.origin.x),
                "y": Double(sourceRect.origin.y),
                "width": Double(sourceRect.size.width),
                "height": Double(sourceRect.size.height),
            ],
            "cameraRect": [
                "x": Double(cameraRect.origin.x),
                "y": Double(cameraRect.origin.y),
                "width": Double(cameraRect.size.width),
                "height": Double(cameraRect.size.height),
            ],
            "files": [
                "metadata": metadataFileName,
                "background": backgroundFileName,
                "camera": cameraFileName,
                "mask": maskFileName,
            ],
            "proofBoundary": "ios_live_green_screen_replay_input_bundle_capture",
            "claims": [
                "captured exact sourceFrame, cameraBuffer, and maskBuffer CVPixelBuffers immediately before compositing",
                "saved raw byte rows and layout rects into replay bundle directory for deterministic replay",
            ],
            "nonClaims": [
                "diagnostic only: input bundle capture is non-claim for production keying quality",
            ],
        ]
    }

    // MARK: - Output helpers (shared by bundle capture, replay, and the stage lab)

    /// Creates `dirURL` (with intermediates) when it does not exist. Fails closed when
    /// the path exists but is not a directory.
    private static func ensureOutputDirectory(_ dirURL: URL) throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir) {
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                throw VGLiveGreenScreenReplayError.ioError(
                    "Failed to create output directory '\(dirURL.path)': \(error.localizedDescription)"
                )
            }
        } else if !isDir.boolValue {
            throw VGLiveGreenScreenReplayError.invalidArgument(
                "outputDir path '\(dirURL.path)' exists and is not a directory."
            )
        }
    }

    private struct EncodedPNG {
        let data: Data
        let width: Int
        let height: Int
    }

    /// Renders `image` over `rect` through `context` and encodes it as PNG in memory.
    /// `what` names the image in error messages (e.g. "composited pixel buffer",
    /// "stage 'postFeather'"). Fails closed on empty/unbounded rects.
    private static func encodePNG(_ image: CIImage,
                                  from rect: CGRect,
                                  using context: CIContext,
                                  what: String) throws -> EncodedPNG {
        guard !rect.isNull, !rect.isInfinite, rect.width >= 1, rect.height >= 1 else {
            throw VGLiveGreenScreenReplayError.compositionFailed(
                "Cannot render \(what): extent \(rect) is empty or unbounded."
            )
        }
        guard let cgImage = context.createCGImage(image, from: rect) else {
            throw VGLiveGreenScreenReplayError.compositionFailed("Failed to create CGImage from \(what).")
        }
        let uiImage = UIImage(cgImage: cgImage)
        guard let pngData = uiImage.pngData() else {
            throw VGLiveGreenScreenReplayError.compositionFailed("Failed to encode \(what) CGImage to PNG data.")
        }
        return EncodedPNG(data: pngData, width: cgImage.width, height: cgImage.height)
    }

    /// Writes already-encoded PNG bytes to `url`, re-checking for a collision
    /// immediately before the write (overwrite is always refused).
    private static func writePNG(_ png: EncodedPNG, to url: URL, what: String) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw VGLiveGreenScreenReplayError.fileCollision(
                "File already exists at '\(url.path)'. Overwriting is refused."
            )
        }
        do {
            try png.data.write(to: url, options: .atomic)
        } catch {
            throw VGLiveGreenScreenReplayError.ioError(
                "Failed to write \(what) PNG to '\(url.path)': \(error.localizedDescription)"
            )
        }
    }

    private static func rectMap(_ rect: CGRect) -> [String: Double] {
        return [
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "width": Double(rect.size.width),
            "height": Double(rect.size.height),
        ]
    }

    // MARK: - Buffer Reconstruction (Read)

    private static func createBufferFromRawBytes(fileURL: URL,
                                                 expectedFormat: OSType,
                                                 expectedWidth: Int,
                                                 expectedHeight: Int,
                                                 expectedRowStride: Int) throws -> CVPixelBuffer {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw VGLiveGreenScreenReplayError.invalidArgument("Bundle buffer file not found: '\(fileURL.path)'.")
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw VGLiveGreenScreenReplayError.ioError("Failed to read '\(fileURL.path)': \(error.localizedDescription)")
        }

        let bytesPerPixel = (expectedFormat == kCVPixelFormatType_32BGRA ? 4 : 1)
        let minRowBytes = expectedWidth * bytesPerPixel

        var fileRowStride = expectedRowStride
        if data.count == expectedHeight * expectedRowStride {
            fileRowStride = expectedRowStride
        } else if data.count == expectedHeight * minRowBytes {
            fileRowStride = minRowBytes
        } else {
            throw VGLiveGreenScreenReplayError.invalidArgument(
                "File size \(data.count) bytes for '\(fileURL.lastPathComponent)' does not match expected \(expectedHeight * expectedRowStride) or packed \(expectedHeight * minRowBytes)."
            )
        }

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:     Int(expectedFormat),
            kCVPixelBufferWidthKey as String:               expectedWidth,
            kCVPixelBufferHeightKey as String:              expectedHeight,
            kCVPixelBufferMetalCompatibilityKey as String:  true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        var pixelBuffer: CVPixelBuffer?
        let cvStatus = CVPixelBufferCreate(kCFAllocatorDefault,
                                           expectedWidth,
                                           expectedHeight,
                                           expectedFormat,
                                           pixelBufferAttributes as CFDictionary,
                                           &pixelBuffer)
        guard cvStatus == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw VGLiveGreenScreenReplayError.compositionFailed("CVPixelBufferCreate failed with code \(cvStatus).")
        }

        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw VGLiveGreenScreenReplayError.missingBaseAddress("CVPixelBufferLockBaseAddress failed: \(lockStatus).")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(buffer) else {
            throw VGLiveGreenScreenReplayError.missingBaseAddress("Newly created CVPixelBuffer base address is nil.")
        }
        let dstRowStride = CVPixelBufferGetBytesPerRow(buffer)

        data.withUnsafeBytes { rawBufferPointer in
            guard let srcBase = rawBufferPointer.baseAddress else { return }
            for y in 0..<expectedHeight {
                let srcRow = srcBase.advanced(by: y * fileRowStride)
                let dstRow = dstBase.advanced(by: y * dstRowStride)
                memcpy(dstRow, srcRow, minRowBytes)
            }
        }

        return buffer
    }

    // MARK: - Replay Bundle Loading

    private struct LoadedBundle {
        let canvasWidth: Int
        let canvasHeight: Int
        let sourceRect: CGRect
        let cameraRect: CGRect
        let background: CVPixelBuffer
        let camera: CVPixelBuffer
        let mask: CVPixelBuffer
    }

    private static func loadBundle(from inputDir: String) throws -> LoadedBundle {
        let trimmedDir = inputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        let dirURL = URL(fileURLWithPath: trimmedDir)
        let metadataURL = dirURL.appendingPathComponent(metadataFileName)

        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw VGLiveGreenScreenReplayError.invalidArgument("metadata.json not found in inputDir '\(inputDir)'.")
        }

        let metaData: Data
        do {
            metaData = try Data(contentsOf: metadataURL)
        } catch {
            throw VGLiveGreenScreenReplayError.ioError("Failed to read metadata.json: \(error.localizedDescription)")
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: metaData, options: []),
              let dict = jsonObject as? [String: Any] else {
            throw VGLiveGreenScreenReplayError.invalidArgument("Failed to parse metadata.json as JSON map.")
        }

        guard let canvasWidth = dict["canvasWidth"] as? Int,
              let canvasHeight = dict["canvasHeight"] as? Int,
              canvasWidth > 0, canvasHeight > 0 else {
            throw VGLiveGreenScreenReplayError.invalidArgument("Invalid or missing canvasWidth/canvasHeight in metadata.json.")
        }

        func parseRect(_ raw: Any?, name: String) throws -> CGRect {
            guard let map = raw as? [String: Any],
                  let x = (map["x"] as? NSNumber)?.doubleValue,
                  let y = (map["y"] as? NSNumber)?.doubleValue,
                  let w = (map["width"] as? NSNumber)?.doubleValue,
                  let h = (map["height"] as? NSNumber)?.doubleValue,
                  w > 0, h > 0 else {
                throw VGLiveGreenScreenReplayError.invalidArgument("Invalid or missing rect '\(name)' in metadata.json.")
            }
            return CGRect(x: x, y: y, width: w, height: h)
        }

        let sourceRect = try parseRect(dict["sourceRect"], name: "sourceRect")
        let cameraRect = try parseRect(dict["cameraRect"], name: "cameraRect")

        func getBufferMeta(_ key: String) throws -> [String: Any] {
            if let topLevel = dict[key] as? [String: Any] {
                return topLevel
            }
            if let buffersMap = dict["buffers"] as? [String: Any],
               let inner = buffersMap[key] as? [String: Any] {
                return inner
            }
            throw VGLiveGreenScreenReplayError.invalidArgument("Missing buffer metadata for '\(key)' in metadata.json.")
        }

        let bgMeta   = try getBufferMeta("background")
        let camMeta  = try getBufferMeta("camera")
        let maskMeta = try getBufferMeta("mask")

        func parseBufferMeta(_ meta: [String: Any], defaultFile: String) throws -> (file: String, width: Int, height: Int, rowStride: Int) {
            let file = (meta["file"] as? String) ?? defaultFile
            guard let w = meta["width"] as? Int, let h = meta["height"] as? Int, let s = meta["rowStride"] as? Int,
                  w > 0, h > 0, s > 0 else {
                throw VGLiveGreenScreenReplayError.invalidArgument("Invalid width/height/rowStride in buffer metadata: \(meta).")
            }
            return (file, w, h, s)
        }

        let bgParsed   = try parseBufferMeta(bgMeta, defaultFile: backgroundFileName)
        let camParsed  = try parseBufferMeta(camMeta, defaultFile: cameraFileName)
        let maskParsed = try parseBufferMeta(maskMeta, defaultFile: maskFileName)

        let bgBuffer = try createBufferFromRawBytes(
            fileURL: dirURL.appendingPathComponent(bgParsed.file),
            expectedFormat: kCVPixelFormatType_32BGRA,
            expectedWidth: bgParsed.width,
            expectedHeight: bgParsed.height,
            expectedRowStride: bgParsed.rowStride
        )

        let camBuffer = try createBufferFromRawBytes(
            fileURL: dirURL.appendingPathComponent(camParsed.file),
            expectedFormat: kCVPixelFormatType_32BGRA,
            expectedWidth: camParsed.width,
            expectedHeight: camParsed.height,
            expectedRowStride: camParsed.rowStride
        )

        let maskBuffer = try createBufferFromRawBytes(
            fileURL: dirURL.appendingPathComponent(maskParsed.file),
            expectedFormat: kCVPixelFormatType_OneComponent8,
            expectedWidth: maskParsed.width,
            expectedHeight: maskParsed.height,
            expectedRowStride: maskParsed.rowStride
        )

        return LoadedBundle(canvasWidth: canvasWidth,
                            canvasHeight: canvasHeight,
                            sourceRect: sourceRect,
                            cameraRect: cameraRect,
                            background: bgBuffer,
                            camera: camBuffer,
                            mask: maskBuffer)
    }

    // MARK: - Replay Execution

    /// Offline deterministic replay of a captured input bundle through VGDuetPreviewCompositor.
    /// Encodes the composited output CVPixelBuffer as PNG at [outputPath].
    /// Refuses overwrite if [outputPath] already exists.
    static func replay(inputDir: String,
                       outputPath: String,
                       label: String) throws -> [String: Any] {
        let trimmedOutputPath = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutputPath.isEmpty else {
            throw VGLiveGreenScreenReplayError.invalidArgument("outputPath must not be empty.")
        }

        let outputURL = URL(fileURLWithPath: trimmedOutputPath)
        let parentURL = outputURL.deletingLastPathComponent()

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw VGLiveGreenScreenReplayError.invalidArgument("Parent directory of outputPath does not exist: '\(parentURL.path)'.")
        }

        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw VGLiveGreenScreenReplayError.fileCollision("File already exists at '\(trimmedOutputPath)'. Overwriting is refused.")
        }

        let bundle = try loadBundle(from: inputDir)

        // Explicitly the production live green-screen default mode
        // (VGMatteRefinementPipeline.defaultLiveMatteRefinementMode), exactly what a
        // live green-screen session runs when no option is sent. Passed explicitly because
        // the generic compositor's own init default is the neutral .s1 (Duet must not
        // inherit green-screen tuning by construction).
        let compositor = VGDuetPreviewCompositor(
            canvasWidth: Double(bundle.canvasWidth),
            canvasHeight: Double(bundle.canvasHeight),
            liveMatteRefinementMode: VGMatteRefinementPipeline.defaultLiveMatteRefinementMode)

        guard let composited = compositor.composite(
            sourceFrame: bundle.background,
            sourceRect: bundle.sourceRect,
            cameraRect: bundle.cameraRect,
            cameraFrame: bundle.camera,
            isGreenScreen: true,
            greenScreenMask: bundle.mask
        ) else {
            throw VGLiveGreenScreenReplayError.compositionFailed("VGDuetPreviewCompositor.composite returned nil during replay.")
        }

        let width  = CVPixelBufferGetWidth(composited)
        let height = CVPixelBufferGetHeight(composited)
        guard width > 0, height > 0 else {
            throw VGLiveGreenScreenReplayError.compositionFailed("Composited buffer has invalid dimensions \(width)x\(height).")
        }

        let png = try encodePNG(CIImage(cvPixelBuffer: composited),
                                from: CGRect(x: 0, y: 0, width: width, height: height),
                                using: replayCIContext,
                                what: "composited pixel buffer")

        // Final race check + write (overwrite refused).
        try writePNG(png, to: outputURL, what: "replay")

        let bytes = png.data.count
        NSLog("[VGLiveGreenScreenReplayDiagnostics] IOS_LIVE_GREENSCREEN_REPLAY_COMPLETED inputDir=\(inputDir) output=\(trimmedOutputPath) label=\(label) dimensions=\(width)x\(height) bytes=\(bytes)")

        return [
            "path": trimmedOutputPath,
            "label": label,
            "width": width,
            "height": height,
            "bytes": bytes,
            "inputDir": inputDir,
            "proofBoundary": "ios_live_green_screen_deterministic_replay",
            "claims": [
                "offline deterministic replay of exact captured camera, mask, and background CVPixelBuffers",
                "exact sourceRect and cameraRect layout passed to VGDuetPreviewCompositor.composite",
                "output encoded as PNG at specified output path without overwriting",
            ],
            "nonClaims": [
                "diagnostic only: offline visual/metric comparison between compositor constants",
                "does not execute live camera or live ML segmentation during replay",
            ],
        ]
    }

    // MARK: - Matte Stage Lab

    /// Stable stage PNG file names in pipeline order. The `key` is the entry name used in
    /// the `paths` / `stages` maps returned by `runMatteStageLab`.
    static let matteStageFiles: [(key: String, file: String)] = [
        ("rawMask",          "01_raw_mask.png"),
        ("aspectFilledMask", "02_aspect_filled_mask.png"),
        ("postMorphology",   "03_post_morphology.png"),
        ("postFeather",      "04_post_feather.png"),
        ("postTrimap",       "05_post_trimap.png"),
        ("postGuidedEdge",   "06_post_guided_edge.png"),
        ("finalComposite",   "07_final_composite.png"),
    ]

    /// Extra stage PNG written only for the S4-family modes (`.s4GuidedAlphaR1` and the
    /// R2 parameter variants `.s4SoftAlphaR2` and
    /// lab-only `.s4TightAlphaR2`): the S4 refinement band weight
    /// (white = pixel refined by S4, black = S1 mask kept). Never written for `.s1`, so the
    /// seven-file contract above is unchanged for the default mode.
    static let matteStageS4BandFile: (key: String, file: String) = ("s4RefinementBand", "08_s4_guided_alpha_band.png")

    /// Extra stage PNG written only for `.s5GuidedFilterR1`: the S5 refinement band weight
    /// (white = pixel refined by S5, black = S1 mask kept). Never written for `.s1` or
    /// any S4-family mode, so neither existing contract is affected by adding S5.
    static let matteStageS5BandFile: (key: String, file: String) = ("s5RefinementBand", "08_s5_guided_filter_band.png")

    /// Stage files for a mode: the seven S1 files, plus the mode's own extra RND band file
    /// (S4/S5 only). `.tightAlphaR1` is a global remap with no band tap, so it writes
    /// exactly the seven standard files.
    static func matteStageFiles(for mode: VGDuetPreviewCompositor.GreenScreenRefinementMode) -> [(key: String, file: String)] {
        switch mode {
        case .s1:               return matteStageFiles
        case .s4GuidedAlphaR1,
             .s4SoftAlphaR2,
             .s4TightAlphaR2:   return matteStageFiles + [matteStageS4BandFile]
        case .s5GuidedFilterR1: return matteStageFiles + [matteStageS5BandFile]
        case .tightAlphaR1:     return matteStageFiles
        }
    }

    /// True for every S4-family mode: `.s4GuidedAlphaR1` plus the R2 parameter
    /// variants `.s4SoftAlphaR2` (lab mode and the production live default) and
    /// lab-only `.s4TightAlphaR2`. All three run the same S4 guided-alpha
    /// recipe, populate the same S4 result fields, and write the same S4 band file.
    private static func isS4FamilyMode(_ mode: VGDuetPreviewCompositor.GreenScreenRefinementMode) -> Bool {
        switch mode {
        case .s4GuidedAlphaR1, .s4SoftAlphaR2, .s4TightAlphaR2: return true
        case .s1, .s5GuidedFilterR1, .tightAlphaR1:            return false
        }
    }

    /// Short parameter-set label for an S4-family mode, embedded in stage descriptions and
    /// claims so lab output names the exact variant. Nil for non-S4 modes.
    private static func s4VariantLabel(for mode: VGDuetPreviewCompositor.GreenScreenRefinementMode) -> String? {
        switch mode {
        case .s4GuidedAlphaR1: return "R1 parameter set (the unchanged live-S4 constants)"
        case .s4SoftAlphaR2:   return "soft-alpha R2 parameter set (wider, softer band; softer in-band alpha; offline lab mode and the production live default)"
        case .s4TightAlphaR2:  return "lab-only tight-alpha R2 parameter set (narrower band; steeper in-band alpha)"
        case .s1, .s5GuidedFilterR1, .tightAlphaR1: return nil
        }
    }

    static let matteStageLabProofBoundary = "ios_live_green_screen_matte_stage_lab"

    /// Offline deterministic matte stage lab: loads the same bundle as `replay`, aspect-fills
    /// camera and mask into the exact CI-space camera rect `composite()` uses, runs the
    /// compositor's `greenScreenMatteStages` tap, and writes one PNG per stage plus the
    /// final composite under `outputDir` using `matteStageFiles` names.
    ///
    /// Fail-closed contract:
    ///   - `outputDir` must be non-blank; it is created if missing.
    ///   - Any pre-existing stage file is a `fileCollision` (INVALID_ARG at the channel).
    ///   - All seven PNGs are encoded in memory before the first write; if a write then
    ///     fails, files written by this call are removed (best effort) and the error is
    ///     rethrown, so a failed run never leaves a partial stage set behind.
    ///
    /// Stage images are rendered through the compositor's own CIContext. For `.s1` the
    /// final composite is the pool buffer produced by `composite()` (same as `replay`).
    /// For the S4-family modes (`.s4GuidedAlphaR1`, `.s4SoftAlphaR2`, and
    /// lab-only `.s4TightAlphaR2`) and `.s5GuidedFilterR1` (RND, diagnostic only) 06 is the
    /// mode-selected final mask (S1 on fail-open), 07 is composed here from that mask with
    /// composite()'s exact CIBlendWithMask recipe rendered into a BGRA canvas buffer, and
    /// 08 is that mode's refinement band. For `.tightAlphaR1` (offline lab evaluation of
    /// the live opt-in post-pass) 06 is the tight-alpha-selected final mask (S1 on
    /// fail-open), 07 is composed here from that mask the same way, and there is no 08.
    /// The live compositor default is never changed by this routine.
    static func runMatteStageLab(inputDir: String,
                                 outputDir: String,
                                 label: String,
                                 refinementMode: VGDuetPreviewCompositor.GreenScreenRefinementMode = .s1) throws -> [String: Any] {
        let trimmedOutputDir = outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutputDir.isEmpty else {
            throw VGLiveGreenScreenReplayError.invalidArgument("outputDir must not be empty.")
        }

        let dirURL = URL(fileURLWithPath: trimmedOutputDir)
        let stageFiles = matteStageFiles(for: refinementMode)
        let targetURLs: [(key: String, file: String, url: URL)] = stageFiles.map {
            ($0.key, $0.file, dirURL.appendingPathComponent($0.file))
        }

        // Refuse overwrite: fail closed if any stage file already exists.
        for target in targetURLs where FileManager.default.fileExists(atPath: target.url.path) {
            throw VGLiveGreenScreenReplayError.fileCollision(
                "Stage file already exists at '\(target.url.path)'. Overwrite is refused."
            )
        }

        try ensureOutputDirectory(dirURL)

        let bundle = try loadBundle(from: inputDir)

        // Pinned to .s1 so composite() below (the .s1 lab mode's 07 output) stays the
        // S1-only path regardless of the production live default; every other lab mode
        // builds 07 from stages.finalMask, independent of the compositor's live mode
        // (greenScreenMatteStages takes refinementMode explicitly).
        let compositor = VGDuetPreviewCompositor(canvasWidth: Double(bundle.canvasWidth),
                                                canvasHeight: Double(bundle.canvasHeight),
                                                liveMatteRefinementMode: .s1)

        // Same geometry as composite(): top-left cameraRect -> snapped, clipped CI rect.
        let ciCamera = compositor.ciRect(fromTopLeft: bundle.cameraRect)
        guard !ciCamera.isEmpty else {
            throw VGLiveGreenScreenReplayError.invalidArgument(
                "cameraRect \(bundle.cameraRect) maps to an empty canvas rect; nothing to refine."
            )
        }

        let rawMaskImage = CIImage(cvPixelBuffer: bundle.mask)
        let camFilled    = compositor.aspectFill(CIImage(cvPixelBuffer: bundle.camera), into: ciCamera)
        let maskFilled   = compositor.aspectFill(rawMaskImage, into: ciCamera)
        let stages       = compositor.greenScreenMatteStages(aspectFilledMask: maskFilled,
                                                             in: ciCamera,
                                                             guidedBy: camFilled,
                                                             refinementMode: refinementMode)

        // Final composite for the selected mode.
        //   .s1: composite()'s own pool output (the compositor is pinned to .s1 above, so
        //   this is the S1-only live fallback path, unchanged).
        //   .s4GuidedAlphaR1 / .s4SoftAlphaR2 / .s4TightAlphaR2 / .s5GuidedFilterR1 /
        //   .tightAlphaR1: the pinned compositor only runs S1, so the mode composite is
        //   built here from stages.finalMask with composite()'s exact CIBlendWithMask recipe.
        let composited: CVPixelBuffer
        switch refinementMode {
        case .s1:
            guard let pooled = compositor.composite(
                sourceFrame: bundle.background,
                sourceRect: bundle.sourceRect,
                cameraRect: bundle.cameraRect,
                cameraFrame: bundle.camera,
                isGreenScreen: true,
                greenScreenMask: bundle.mask
            ) else {
                throw VGLiveGreenScreenReplayError.compositionFailed(
                    "VGDuetPreviewCompositor.composite returned nil during matte stage lab."
                )
            }
            composited = pooled
        case .s4GuidedAlphaR1, .s4SoftAlphaR2, .s4TightAlphaR2, .s5GuidedFilterR1, .tightAlphaR1:
            composited = try composeWithSelectedMask(compositor: compositor,
                                                     bundle: bundle,
                                                     cameraFilled: camFilled,
                                                     finalMask: stages.finalMask,
                                                     modeName: refinementMode.rawValue)
        }
        let compositeWidth  = CVPixelBufferGetWidth(composited)
        let compositeHeight = CVPixelBufferGetHeight(composited)
        guard compositeWidth > 0, compositeHeight > 0 else {
            throw VGLiveGreenScreenReplayError.compositionFailed(
                "Composited buffer has invalid dimensions \(compositeWidth)x\(compositeHeight)."
            )
        }
        let compositeRect = CGRect(x: 0, y: 0, width: compositeWidth, height: compositeHeight)

        // Encode every stage in memory first so a render failure writes nothing.
        // 06/07 always reflect the mode-selected final mask/composite; for .s1 that is
        // exactly the previous seven-file contract.
        let finalMaskDescription: String
        let finalCompositeDescription: String
        switch refinementMode {
        case .s1:
            finalMaskDescription = "after stage 4 guided edge preserve; the final mask fed to CIBlendWithMask (identical to 05 when not applied)"
            finalCompositeDescription = "full canvas output of composite() for this bundle"
        case .s4GuidedAlphaR1, .s4SoftAlphaR2, .s4TightAlphaR2:
            let variant = s4VariantLabel(for: refinementMode) ?? refinementMode.rawValue
            finalMaskDescription = stages.s4GuidedAlphaApplied
                ? "S4 guided-alpha final mask (\(refinementMode.rawValue): \(variant)): S1 stage-4 mask refined only inside the camera-guided band (\(refinementMode == .s4SoftAlphaR2 ? "the production live default, rendered offline by the lab" : "RND, not the live default"))"
                : "S4 (\(refinementMode.rawValue)) requested but failed open (\(stages.s4GuidedAlphaFailOpenReason ?? "unknown")); identical to the S1 stage-4 mask"
            finalCompositeDescription = "full canvas composite built by the lab from the \(refinementMode.rawValue)-selected final mask with composite()'s CIBlendWithMask recipe (not composite() pool output)"
        case .s5GuidedFilterR1:
            finalMaskDescription = stages.s5GuidedFilterApplied
                ? "S5 guided-filter R1 final mask: S1 stage-4 mask refined only inside the guided-filter band (RND, not live)"
                : "S5 requested but failed open (\(stages.s5GuidedFilterFailOpenReason ?? "unknown")); identical to the S1 stage-4 mask"
            finalCompositeDescription = "full canvas composite built by the lab from the S5-selected final mask with composite()'s CIBlendWithMask recipe (not composite() pool output)"
        case .tightAlphaR1:
            finalMaskDescription = stages.tightAlphaR1Applied
                ? "tight-alpha R1 final mask: the live opt-in applyLiveTightAlphaR1 post-pass (smoothstep remap + small final blur) run offline on the S1 stage-4 mask (lab evaluation, not the live default)"
                : "tightAlphaR1 requested but failed open (\(stages.tightAlphaR1FailOpenReason ?? "unknown")); identical to the S1 stage-4 mask"
            finalCompositeDescription = "full canvas composite built by the lab from the tight-alpha-R1-selected final mask with composite()'s CIBlendWithMask recipe (not composite() pool output)"
        }
        var stageImages: [(key: String, image: CIImage, rect: CGRect, context: CIContext, description: String)] = [
            ("rawMask", rawMaskImage, rawMaskImage.extent, compositor.ciContext,
             "mask.r8 at native buffer resolution; no aspect fill, no refinement"),
            ("aspectFilledMask", stages.aspectFilledInput, ciCamera, compositor.ciContext,
             "mask aspect-filled into the CI-space camera rect exactly as composite() does; input to morphology close"),
            ("postMorphology", stages.postMorphologyClose, ciCamera, compositor.ciContext,
             "after stage 1 morphology close (identical to 02 when not applied)"),
            ("postFeather", stages.postFeather, ciCamera, compositor.ciContext,
             "after stage 2 feather (identical to 03 when not applied)"),
            ("postTrimap", stages.postTrimap, ciCamera, compositor.ciContext,
             "after stage 3 trimap (identical to 04 when not applied)"),
            ("postGuidedEdge", stages.finalMask, ciCamera, compositor.ciContext,
             finalMaskDescription),
            ("finalComposite", CIImage(cvPixelBuffer: composited), compositeRect, replayCIContext,
             finalCompositeDescription),
        ]
        if isS4FamilyMode(refinementMode) {
            // Band weight where S4 acted (same band tap for R1 and both R2 variants);
            // an all-black band when S4 failed open (nothing refined).
            let bandImage = stages.s4RefinementBand
                ?? CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: ciCamera)
            stageImages.append((matteStageS4BandFile.key, bandImage, ciCamera, compositor.ciContext,
                                stages.s4GuidedAlphaApplied
                                    ? "S4 refinement band weight (\(refinementMode.rawValue)): white = pixel refined by S4, black = S1 mask kept"
                                    : "S4 (\(refinementMode.rawValue)) failed open; all-black band (no pixel refined)"))
        }
        if refinementMode == .s5GuidedFilterR1 {
            // Band weight where S5 acted; an all-black band when S5 failed open (nothing refined).
            let bandImage = stages.s5RefinementBand
                ?? CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: ciCamera)
            stageImages.append((matteStageS5BandFile.key, bandImage, ciCamera, compositor.ciContext,
                                stages.s5GuidedFilterApplied
                                    ? "S5 refinement band weight: white = pixel refined by S5, black = S1 mask kept"
                                    : "S5 failed open; all-black band (no pixel refined)"))
        }

        var encoded: [String: EncodedPNG] = [:]
        for stage in stageImages {
            encoded[stage.key] = try encodePNG(stage.image,
                                               from: stage.rect,
                                               using: stage.context,
                                               what: "stage '\(stage.key)'")
        }

        // Write in pipeline order; roll back this call's own files on failure.
        var written: [URL] = []
        var stageEntries: [String: Any] = [:]
        var paths: [String: String] = [:]
        do {
            for target in targetURLs {
                guard let png = encoded[target.key],
                      let stage = stageImages.first(where: { $0.key == target.key }) else {
                    throw VGLiveGreenScreenReplayError.compositionFailed(
                        "Internal error: no encoded image for stage '\(target.key)'."
                    )
                }
                try writePNG(png, to: target.url, what: "stage '\(target.key)'")
                written.append(target.url)
                paths[target.key] = target.url.path
                stageEntries[target.key] = [
                    "file": target.file,
                    "path": target.url.path,
                    "width": png.width,
                    "height": png.height,
                    "bytes": png.data.count,
                    "description": stage.description,
                ]
            }
        } catch {
            for url in written {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }

        let appliedFlags: [String: Bool] = [
            "morphologyCloseApplied": stages.morphologyCloseApplied,
            "featherApplied":         stages.featherApplied,
            "trimapApplied":          stages.trimapApplied,
            "guidedEdgeApplied":      stages.guidedEdgeApplied,
            "s4GuidedAlphaApplied":   stages.s4GuidedAlphaApplied,
            "s5GuidedFilterApplied":  stages.s5GuidedFilterApplied,
            "tightAlphaR1Applied":    stages.tightAlphaR1Applied,
        ]
        let s4Status: String
        let s5Status: String
        let tightAlphaR1Status: String
        switch refinementMode {
        case .s1:
            s4Status = "not_requested"
            s5Status = "not_requested"
            tightAlphaR1Status = "not_requested"
        case .s4GuidedAlphaR1, .s4SoftAlphaR2, .s4TightAlphaR2:
            s4Status = stages.s4GuidedAlphaApplied
                ? "applied"
                : "fail_open:\(stages.s4GuidedAlphaFailOpenReason ?? "unknown")"
            s5Status = "not_requested"
            tightAlphaR1Status = "not_requested"
        case .s5GuidedFilterR1:
            s4Status = "not_requested"
            s5Status = stages.s5GuidedFilterApplied
                ? "applied"
                : "fail_open:\(stages.s5GuidedFilterFailOpenReason ?? "unknown")"
            tightAlphaR1Status = "not_requested"
        case .tightAlphaR1:
            s4Status = "not_requested"
            s5Status = "not_requested"
            tightAlphaR1Status = stages.tightAlphaR1Applied
                ? "applied"
                : "fail_open:\(stages.tightAlphaR1FailOpenReason ?? "unknown")"
        }

        NSLog("[VGLiveGreenScreenReplayDiagnostics] IOS_LIVE_GREENSCREEN_MATTE_STAGE_LAB_COMPLETED inputDir=\(inputDir) outputDir=\(trimmedOutputDir) label=\(label) refinementMode=\(refinementMode.rawValue) s4Status=\(s4Status) s5Status=\(s5Status) tightAlphaR1Status=\(tightAlphaR1Status) canvas=\(bundle.canvasWidth)x\(bundle.canvasHeight) cameraRectCI=\(Int(ciCamera.minX)),\(Int(ciCamera.minY)) \(Int(ciCamera.width))x\(Int(ciCamera.height)) rawMask=\(CVPixelBufferGetWidth(bundle.mask))x\(CVPixelBufferGetHeight(bundle.mask)) flags=\(appliedFlags)")

        let claims: [String]
        let nonClaims: [String]
        switch refinementMode {
        case .s1:
            claims = [
                "offline deterministic replay of the exact captured camera, mask, and background CVPixelBuffers",
                "camera and mask aspect-filled into the same snapped CI camera rect composite() uses",
                "stage PNGs 02-06 are the compositor's own greenScreenMatteStages outputs (shared production filter pipeline, S1 constants unchanged)",
                "01_raw_mask.png is the mask buffer at native resolution before aspect fill; 07_final_composite.png is composite()'s pool output",
                "all seven PNGs written without overwriting; a failed write removes this call's partial files",
            ]
            nonClaims = [
                "diagnostic only: no production visual-quality tuning, no constant changes",
                "does not execute live camera capture or live ML segmentation",
                "no automated pixel quality assertion; visual inspection of stage PNGs only",
                "stage PNGs are 8-bit renders through the compositor CIContext; bit-exactness with the live texture path is not asserted",
            ]
        case .s4GuidedAlphaR1, .s4SoftAlphaR2, .s4TightAlphaR2:
            let modeName = refinementMode.rawValue
            let variant = s4VariantLabel(for: refinementMode) ?? modeName
            claims = [
                "offline deterministic replay of the exact captured camera, mask, and background CVPixelBuffers",
                "camera and mask aspect-filled into the same snapped CI camera rect composite() uses",
                "stage PNGs 02-05 are the compositor's unchanged S1 greenScreenMatteStages outputs (S1 constants unchanged)",
                "06_post_guided_edge.png is the \(modeName) selected final mask: the S4 guided-alpha recipe with the \(variant), a band-limited camera-guided refinement of the S1 stage-4 mask; identical to S1 on fail-open, see s4Status",
                "07_final_composite.png is composed by the lab from that mask with composite()'s CIBlendWithMask recipe (canvas colour, aspect-filled source, aspect-filled camera foreground) rendered through the compositor CIContext",
                "08_s4_guided_alpha_band.png is the \(modeName) S4 refinement band weight (white = refined, black = S1 kept)",
                "all eight PNGs written without overwriting; a failed write removes this call's partial files",
            ]
            var s4NonClaims = [
                refinementMode == .s4SoftAlphaR2
                    ? "offline lab rendering of the production live default: this routine composes \(modeName) itself from stages.finalMask (the lab compositor is pinned to .s1); no live behaviour changed by this routine"
                    : "RND candidate only: \(modeName) is not the live production default and this routine's pinned-.s1 compositor never runs it; no live behaviour changed by this routine",
                "diagnostic only: no production visual-quality tuning, no S1 constant changes, no S4 R1 constant changes",
                "does not execute live camera capture or live ML segmentation",
                "no automated pixel quality assertion; visual inspection of stage PNGs only",
                "07 is not composite() pool output; bit-exactness with the live texture path or with the S1 lab composite is not asserted",
                "S4 is a fast guided-alpha approximation (edge-confidence-selected soft/steep alpha inside a matte band), not a full guided-filter or alpha-matting solve",
            ]
            if refinementMode == .s4SoftAlphaR2 {
                s4NonClaims.append("S4-family variant: s4SoftAlphaR2 is the production live default (VGMatteRefinementPipeline.defaultLiveMatteRefinementMode) as well as an offline lab mode; the live opt-in .s4GuidedAlphaR1 route and its parameters are unchanged; no ranking against R1 or any other mode is asserted by this routine")
            } else if refinementMode == .s4TightAlphaR2 {
                s4NonClaims.append("lab-only S4-family variant: s4TightAlphaR2 remains lab-only and has no live counterpart; the live opt-in .s4GuidedAlphaR1 route and its parameters are unchanged; no ranking against R1 or any other mode is asserted")
            }
            nonClaims = s4NonClaims
        case .s5GuidedFilterR1:
            claims = [
                "offline deterministic replay of the exact captured camera, mask, and background CVPixelBuffers",
                "camera and mask aspect-filled into the same snapped CI camera rect composite() uses",
                "stage PNGs 02-05 are the compositor's unchanged S1 greenScreenMatteStages outputs (S1 constants unchanged)",
                "06_post_guided_edge.png is the S5 guided-filter R1 selected final mask (band-limited local-linear guided-filter refinement of the S1 stage-4 mask; identical to S1 on fail-open, see s5Status)",
                "07_final_composite.png is composed by the lab from that mask with composite()'s CIBlendWithMask recipe (canvas colour, aspect-filled source, aspect-filled camera foreground) rendered through the compositor CIContext",
                "08_s5_guided_filter_band.png is the S5 refinement band weight (white = refined, black = S1 kept)",
                "all eight PNGs written without overwriting; a failed write removes this call's partial files",
            ]
            nonClaims = [
                "RND candidate only: S5 is not the live production default and composite() never runs it; no live behaviour changed",
                "diagnostic only: no production visual-quality tuning, no S1 constant changes",
                "does not execute live camera capture or live ML segmentation",
                "no automated pixel quality assertion; visual inspection of stage PNGs only",
                "07 is not composite() pool output; bit-exactness with the live texture path or with the S1 lab composite is not asserted",
                "S5 is a box-filter approximation of a true local-linear guided filter (He et al.), not an exact solve, and is not compared against S4 for quality",
            ]
        case .tightAlphaR1:
            claims = [
                "offline deterministic replay of the exact captured camera, mask, and background CVPixelBuffers",
                "camera and mask aspect-filled into the same snapped CI camera rect composite() uses",
                "stage PNGs 02-05 are the compositor's unchanged S1 greenScreenMatteStages outputs (S1 constants unchanged)",
                "06_post_guided_edge.png is the tight-alpha R1 selected final mask: the same applyLiveTightAlphaR1 post-pass (smoothstep remap + small final blur over the S1 stage-4 mask, live constants unchanged) that the live opt-in LiveMatteRefinementMode.tightAlphaR1 runs; identical to S1 on fail-open, see tightAlphaR1Status",
                "07_final_composite.png is composed by the lab from that mask with composite()'s CIBlendWithMask recipe (canvas colour, aspect-filled source, aspect-filled camera foreground) rendered through the compositor CIContext",
                "exactly the seven standard stage PNG names are written for this mode; there is no 08 band file",
                "all seven PNGs written without overwriting; a failed write removes this call's partial files",
            ]
            nonClaims = [
                "offline lab evaluation only: tightAlphaR1 is not the live production default (LiveMatteRefinementMode stays at the production default, .s4SoftAlphaR2, unless a session opts in through its diagnostic-only route) and composite() never runs it; no live behaviour changed by this routine",
                "diagnostic only: no production visual-quality tuning, no S1 or tight-alpha constant changes",
                "does not execute live camera capture or live ML segmentation",
                "no automated pixel quality assertion in this routine; any objective mask-edge metrics are computed by the calling harness from the written stage PNGs",
                "07 is not composite() pool output; bit-exactness with the live texture path (S1 or the live tightAlphaR1 opt-in) or with the S1 lab composite is not asserted",
                "tight alpha is a global remap of the whole S1 mask, not a band-limited refinement, so no band tap exists and no comparison against S4/S5 quality is asserted",
            ]
        }

        return [
            "outputDir": trimmedOutputDir,
            "inputDir": inputDir,
            "label": label,
            "refinementMode": refinementMode.rawValue,
            "s4Status": s4Status,
            "s4FailOpenReason": stages.s4GuidedAlphaFailOpenReason ?? "",
            "s5Status": s5Status,
            "s5FailOpenReason": stages.s5GuidedFilterFailOpenReason ?? "",
            "tightAlphaR1Status": tightAlphaR1Status,
            "tightAlphaR1FailOpenReason": stages.tightAlphaR1FailOpenReason ?? "",
            "files": stageFiles.map { $0.file },
            "paths": paths,
            "stages": stageEntries,
            "dimensions": [
                "canvasWidth": bundle.canvasWidth,
                "canvasHeight": bundle.canvasHeight,
                "sourceRect": rectMap(bundle.sourceRect),
                "cameraRect": rectMap(bundle.cameraRect),
                "cameraRectCI": rectMap(ciCamera),
                "rawMaskWidth": CVPixelBufferGetWidth(bundle.mask),
                "rawMaskHeight": CVPixelBufferGetHeight(bundle.mask),
                "stageWidth": Int(ciCamera.width),
                "stageHeight": Int(ciCamera.height),
                "compositeWidth": compositeWidth,
                "compositeHeight": compositeHeight,
            ],
            "appliedFlags": appliedFlags,
            "proofBoundary": matteStageLabProofBoundary,
            "claims": claims,
            "nonClaims": nonClaims,
        ]
    }

    // MARK: - Diagnostic composite for non-S1 final masks

    /// Composes the bundle with an already-refined `finalMask` using composite()'s exact
    /// recipe — canvas colour, aspect-filled source in sourceRect, then CIBlendWithMask with
    /// the aspect-filled camera as foreground, the composed canvas as background and
    /// `finalMask` as mask, cropped to the canvas — and renders it through the compositor's
    /// CIContext into a fresh BGRA canvas buffer (same render call composite() uses on its
    /// pool buffer). Used only for diagnostic refinement modes composite() cannot run.
    private static func composeWithSelectedMask(compositor: VGDuetPreviewCompositor,
                                                bundle: LoadedBundle,
                                                cameraFilled: CIImage,
                                                finalMask: CIImage,
                                                modeName: String) throws -> CVPixelBuffer {
        let bounds = CGRect(origin: .zero, size: compositor.canvasSize)
        var image = CIImage(color: VGDuetPreviewCompositor.canvasColor).cropped(to: bounds)

        let ciSource = compositor.ciRect(fromTopLeft: bundle.sourceRect)
        if !ciSource.isEmpty {
            let sourceImage = CIImage(cvPixelBuffer: bundle.background)
            image = compositor.aspectFill(sourceImage, into: ciSource).composited(over: image)
        }

        let params: [String: Any] = [
            "inputBackgroundImage": image,
            "inputImage":           cameraFilled,
            "inputMaskImage":       finalMask,
        ]
        guard let blended = CIFilter(name: "CIBlendWithMask", parameters: params)?.outputImage else {
            throw VGLiveGreenScreenReplayError.compositionFailed(
                "CIBlendWithMask unavailable while composing the \(modeName) final composite."
            )
        }
        image = blended.cropped(to: bounds)

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:     Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String:               compositor.canvasWidth,
            kCVPixelBufferHeightKey as String:              compositor.canvasHeight,
            kCVPixelBufferMetalCompatibilityKey as String:  true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var pixelBuffer: CVPixelBuffer?
        let cvStatus = CVPixelBufferCreate(kCFAllocatorDefault,
                                           compositor.canvasWidth,
                                           compositor.canvasHeight,
                                           kCVPixelFormatType_32BGRA,
                                           pixelBufferAttributes as CFDictionary,
                                           &pixelBuffer)
        guard cvStatus == kCVReturnSuccess, let output = pixelBuffer else {
            throw VGLiveGreenScreenReplayError.compositionFailed(
                "CVPixelBufferCreate failed with code \(cvStatus) while composing the \(modeName) final composite."
            )
        }
        compositor.ciContext.render(image, to: output, bounds: bounds, colorSpace: nil)
        return output
    }
}
