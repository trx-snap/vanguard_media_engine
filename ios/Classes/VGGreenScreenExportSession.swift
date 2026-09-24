import Foundation
import Flutter
import AVFoundation
import CoreImage
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import Metal
import UIKit

// VGGreenScreenExportSession.swift
//
// Generic, caller-agnostic iOS green-screen export renderer behind the
// `exportGreenScreenComposition` MethodChannel route. Nothing here is
// Duet-owned; Duet, live meeting/calling, going live, camera, and the
// Universal Editor are all expected callers.
//
// Slice scope (static background proof): solid-color and image-file
// backgrounds only. `videoFile` backgrounds stay rejected at parse time.
// No audio, no live camera, no cancellation, no app wiring.
//
// Coordinate systems:
//   Dart rects are integer canvas pixels with a TOP-LEFT origin. CoreImage
//   renders with a BOTTOM-LEFT origin. `ExportRun.ciRect(_:)` flips Y once;
//   every placement below works in CoreImage space after that flip.
//   Rotations are cardinal (0/90/180/270), clockwise as seen by the viewer,
//   applied explicitly after the horizontal mirror; container rotation is
//   reported as telemetry only and never auto-applied.
//
// Mask convention: 8-bit, 255 = foreground visible, 0 = background visible.
// Masks travel through a OneComponent8 CVPixelBuffer into CIBlendWithMask,
// the same combination VGDuetPreviewCompositor's pixel proof verified
// (output = round(fg * m + bg * (1 - m)) per channel, delta 0).

// MARK: - Supporting types

/// How an image background is placed on its destination rect.
/// `aspectFit` letterboxes/pillarboxes with black; `aspectFill` center-crops.
private enum ScaleMode: String {
    case aspectFit
    case aspectFill

    /// Missing (nil / NSNull) defaults to `aspectFill`. A non-nil value that
    /// is not one of the wire names fails closed.
    static func parse(_ raw: Any?) throws -> ScaleMode {
        guard let raw = ArgValue.unwrap(raw) else { return .aspectFill }
        guard let text = raw as? String, let mode = ScaleMode(rawValue: text) else {
            throw ParseError(message: "background.scaleMode must be one of aspectFill, aspectFit")
        }
        return mode
    }
}

private struct Size {
    let width: Int
    let height: Int
}

/// Integer canvas rect in Dart's top-left-origin pixel coordinates.
private struct Rect {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

private enum BackgroundSource {
    case solidColor(Int32)
    case imageFile(path: String, scaleMode: ScaleMode)

    var typeName: String {
        switch self {
        case .solidColor: return "solidColor"
        case .imageFile: return "imageFile"
        }
    }
}

private enum MaskSource {
    case constantAlpha(alpha: Int, width: Int, height: Int)
    case r8FrameFiles(framePaths: [String], width: Int, height: Int, rowStrideBytes: Int)

    var width: Int {
        switch self {
        case .constantAlpha(_, let width, _): return width
        case .r8FrameFiles(_, let width, _, _): return width
        }
    }

    var height: Int {
        switch self {
        case .constantAlpha(_, _, let height): return height
        case .r8FrameFiles(_, _, let height, _): return height
        }
    }
}

private struct Request {
    let foregroundVideoPath: String
    let outputPath: String
    let targetSize: Size
    /// Integer output frame rate; also the CMTime timescale of the output clock.
    let fps: Int
    let videoBitRate: Int
    let outputFrameCount: Int
    let background: BackgroundSource
    let mask: MaskSource
    let foregroundRect: Rect?
    let backgroundRect: Rect?
    let foregroundRotationDegrees: Int
    let backgroundRotationDegrees: Int
    let foregroundMirrorHorizontal: Bool
    let backgroundMirrorHorizontal: Bool

    var tmpPath: String { return outputPath + ".tmp" }

    var fullCanvasRect: Rect {
        return Rect(x: 0, y: 0, width: targetSize.width, height: targetSize.height)
    }

    var effectiveForegroundRect: Rect { return foregroundRect ?? fullCanvasRect }
    var effectiveBackgroundRect: Rect { return backgroundRect ?? fullCanvasRect }

    /// Nominal duration from the fixed output clock (integer math like Android).
    var nominalDurationMs: Int { return outputFrameCount * 1000 / fps }
}

private struct ParseError: Error {
    let message: String
}

/// Method-channel value coercion. Flutter's standard codec bridges Dart ints
/// as NSNumber (which Swift may surface as Int), Dart bools as CFBoolean-backed
/// NSNumber, and Dart null as NSNull. Every accessor treats NSNull as absent
/// and refuses booleans where numbers are expected.
private enum ArgValue {
    static func unwrap(_ raw: Any?) -> Any? {
        guard let raw = raw, !(raw is NSNull) else { return nil }
        return raw
    }

    static func isBoolean(_ raw: Any) -> Bool {
        guard let number = raw as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func int(_ raw: Any?) -> Int? {
        guard let raw = unwrap(raw), !isBoolean(raw) else { return nil }
        if let value = raw as? Int { return value }
        guard let number = raw as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite,
              value.rounded(.towardZero) == value,
              abs(value) <= 9_007_199_254_740_991 else {
            return nil
        }
        return Int(value)
    }

    static func bool(_ raw: Any?) -> Bool? {
        guard let raw = unwrap(raw) else { return nil }
        if isBoolean(raw), let value = raw as? Bool { return value }
        return nil
    }

    static func string(_ raw: Any?) -> String? {
        guard let raw = unwrap(raw) else { return nil }
        return raw as? String
    }
}

// MARK: - Session

final class VGGreenScreenExportSession {

    private let lock = NSLock()
    private var busy = false
    private var disposed = false
    private let queue = DispatchQueue(label: "vg.greenscreen.export", qos: .userInitiated)

    init() {}

    /// Parses on the calling (main) thread, admits at most one export at a
    /// time, runs the export on the serial background queue, and delivers
    /// exactly one FlutterResult on the main queue. `busy` is cleared exactly
    /// once per admitted export, immediately before that delivery.
    func export(args: [String: Any]?, result: @escaping FlutterResult) {
        let request: Request
        do {
            request = try VGGreenScreenExportSession.parseRequest(args)
        } catch let error as ParseError {
            VGGreenScreenExportSession.deliver(result, FlutterError(code: "INVALID_ARG", message: error.message, details: nil))
            return
        } catch {
            VGGreenScreenExportSession.deliver(result, FlutterError(code: "INVALID_ARG", message: "unknown parse error", details: nil))
            return
        }

        lock.lock()
        if disposed || busy {
            lock.unlock()
            VGGreenScreenExportSession.deliver(result, FlutterError(code: "export_busy", message: "an export is already in progress or the session is disposed", details: nil))
            return
        }
        busy = true
        lock.unlock()

        // Strong capture on purpose: the admitted export must run to a
        // terminal state and clear `busy` even if the handler lets go of us.
        queue.async {
            let outcome = ExportRun(request: request).run()

            DispatchQueue.main.async {
                self.lock.lock()
                self.busy = false
                self.lock.unlock()

                switch outcome {
                case .success(let map):
                    result(map)
                case .failure(let reason, let details):
                    result(FlutterError(
                        code: "composition_failed",
                        message: "exportGreenScreenComposition: failed:\(reason)",
                        details: details
                    ))
                }
            }
        }
    }

    func disposeAll() {
        lock.lock()
        disposed = true
        lock.unlock()
    }

    private static func deliver(_ result: @escaping FlutterResult, _ value: Any?) {
        if Thread.isMainThread {
            result(value)
        } else {
            DispatchQueue.main.async { result(value) }
        }
    }

    // MARK: - Parsing

    private static func parseRequest(_ args: [String: Any]?) throws -> Request {
        guard let args = args else {
            throw ParseError(message: "arguments must not be nil")
        }

        guard let foregroundVideoPath = ArgValue.string(args["foregroundVideoPath"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !foregroundVideoPath.isEmpty else {
            throw ParseError(message: "foregroundVideoPath must be non-blank")
        }
        guard let outputPath = ArgValue.string(args["outputPath"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !outputPath.isEmpty else {
            throw ParseError(message: "outputPath must be non-blank")
        }

        let targetSize = try parseTargetSize(args["targetSize"])

        guard let fps = ArgValue.int(args["fps"]), fps > 0 else {
            throw ParseError(message: "fps must be a positive integer")
        }
        guard fps <= Int(Int32.max) else {
            throw ParseError(message: "fps is too large for a CMTime timescale")
        }
        guard let videoBitRate = ArgValue.int(args["videoBitRate"]), videoBitRate > 0 else {
            throw ParseError(message: "videoBitRate must be positive")
        }
        guard let outputFrameCount = ArgValue.int(args["outputFrameCount"]), outputFrameCount > 0 else {
            throw ParseError(message: "outputFrameCount must be positive")
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: outputPath) == false else {
            throw ParseError(message: "outputPath must not already exist")
        }
        let outputDirectory = (outputPath as NSString).deletingLastPathComponent
        var outputDirectoryIsDirectory: ObjCBool = false
        guard !outputDirectory.isEmpty,
              fileManager.fileExists(atPath: outputDirectory, isDirectory: &outputDirectoryIsDirectory),
              outputDirectoryIsDirectory.boolValue else {
            throw ParseError(message: "outputPath parent directory does not exist")
        }
        guard fileManager.fileExists(atPath: foregroundVideoPath) else {
            throw ParseError(message: "foregroundVideoPath file does not exist")
        }

        let background = try parseBackground(args["background"])
        let mask = try parseMask(args["mask"], outputFrameCount: outputFrameCount)

        let foregroundRect = try parseOptionalRect(args["foregroundRect"], fitWithin: targetSize, key: "foregroundRect")
        let backgroundRect = try parseOptionalRect(args["backgroundRect"], fitWithin: targetSize, key: "backgroundRect")

        let foregroundRotationDegrees = try optionalInt(args["foregroundRotationDegrees"], key: "foregroundRotationDegrees", defaultValue: 0)
        guard [0, 90, 180, 270].contains(foregroundRotationDegrees) else {
            throw ParseError(message: "foregroundRotationDegrees must be one of 0, 90, 180, 270")
        }
        let backgroundRotationDegrees = try optionalInt(args["backgroundRotationDegrees"], key: "backgroundRotationDegrees", defaultValue: 0)
        guard [0, 90, 180, 270].contains(backgroundRotationDegrees) else {
            throw ParseError(message: "backgroundRotationDegrees must be one of 0, 90, 180, 270")
        }

        let foregroundMirrorHorizontal = try optionalBool(args["foregroundMirrorHorizontal"], key: "foregroundMirrorHorizontal", defaultValue: false)
        let backgroundMirrorHorizontal = try optionalBool(args["backgroundMirrorHorizontal"], key: "backgroundMirrorHorizontal", defaultValue: false)

        return Request(
            foregroundVideoPath: foregroundVideoPath,
            outputPath: outputPath,
            targetSize: targetSize,
            fps: fps,
            videoBitRate: videoBitRate,
            outputFrameCount: outputFrameCount,
            background: background,
            mask: mask,
            foregroundRect: foregroundRect,
            backgroundRect: backgroundRect,
            foregroundRotationDegrees: foregroundRotationDegrees,
            backgroundRotationDegrees: backgroundRotationDegrees,
            foregroundMirrorHorizontal: foregroundMirrorHorizontal,
            backgroundMirrorHorizontal: backgroundMirrorHorizontal
        )
    }

    private static func parseTargetSize(_ raw: Any?) throws -> Size {
        guard let dict = ArgValue.unwrap(raw) as? [String: Any] else {
            throw ParseError(message: "targetSize must be a map with width and height")
        }
        guard let width = ArgValue.int(dict["width"]), width > 0 else {
            throw ParseError(message: "targetSize.width must be positive")
        }
        guard let height = ArgValue.int(dict["height"]), height > 0 else {
            throw ParseError(message: "targetSize.height must be positive")
        }
        return Size(width: width, height: height)
    }

    private static func parseBackground(_ raw: Any?) throws -> BackgroundSource {
        guard let dict = ArgValue.unwrap(raw) as? [String: Any] else {
            throw ParseError(message: "background must be a map with a type")
        }
        guard let type = ArgValue.string(dict["type"]) else {
            throw ParseError(message: "background.type must be a string")
        }

        switch type {
        case "solidColor":
            guard let color = ArgValue.int(dict["argbColor"]) else {
                throw ParseError(message: "background.argbColor must be a number")
            }
            return .solidColor(Int32(truncatingIfNeeded: color))

        case "imageFile":
            guard let imagePath = ArgValue.string(dict["path"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !imagePath.isEmpty else {
                throw ParseError(message: "background.path must be non-blank")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: imagePath, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw ParseError(message: "background.path file does not exist")
            }
            let scaleMode = try ScaleMode.parse(dict["scaleMode"])
            return .imageFile(path: imagePath, scaleMode: scaleMode)

        case "videoFile":
            throw ParseError(message: "background.type videoFile is not supported")

        default:
            throw ParseError(message: "background.type must be one of solidColor, imageFile, videoFile")
        }
    }

    private static func parseMask(_ raw: Any?, outputFrameCount: Int) throws -> MaskSource {
        guard let dict = ArgValue.unwrap(raw) as? [String: Any] else {
            throw ParseError(message: "mask must be a map with a type")
        }
        guard let type = ArgValue.string(dict["type"]) else {
            throw ParseError(message: "mask.type must be a string")
        }

        switch type {
        case "constantAlpha":
            guard let alpha = ArgValue.int(dict["alpha"]), (0...255).contains(alpha) else {
                throw ParseError(message: "mask.alpha must be in 0...255")
            }
            let width = try optionalInt(dict["width"], key: "mask.width", defaultValue: 64)
            guard width > 0 else {
                throw ParseError(message: "mask.width must be positive")
            }
            let height = try optionalInt(dict["height"], key: "mask.height", defaultValue: 64)
            guard height > 0 else {
                throw ParseError(message: "mask.height must be positive")
            }
            return .constantAlpha(alpha: alpha, width: width, height: height)

        case "r8FrameFiles":
            guard let framePaths = ArgValue.unwrap(dict["framePaths"]) as? [String], !framePaths.isEmpty else {
                throw ParseError(message: "mask.framePaths must be a non-empty array of strings")
            }
            guard framePaths.count >= outputFrameCount else {
                throw ParseError(message: "mask.framePaths must contain at least outputFrameCount entries")
            }
            guard let width = ArgValue.int(dict["width"]), width > 0 else {
                throw ParseError(message: "mask.width must be positive")
            }
            guard let height = ArgValue.int(dict["height"]), height > 0 else {
                throw ParseError(message: "mask.height must be positive")
            }
            let rowStrideBytes = try optionalInt(dict["rowStrideBytes"], key: "mask.rowStrideBytes", defaultValue: 0)
            guard rowStrideBytes == 0 || rowStrideBytes >= width else {
                throw ParseError(message: "mask.rowStrideBytes must be 0 or >= mask.width")
            }
            let effectiveStride = rowStrideBytes == 0 ? width : rowStrideBytes
            let minimumBytes = effectiveStride * height

            // Only the frames this export will read are validated; extra
            // trailing entries are ignored (same as Android).
            let fileManager = FileManager.default
            for index in 0..<outputFrameCount {
                let path = framePaths[index]
                var isDirectory: ObjCBool = false
                guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    throw ParseError(message: "mask.framePaths[\(index)] does not exist: \(path)")
                }
                guard let fileSize = fileSize(atPath: path) else {
                    throw ParseError(message: "unable to read mask.framePaths[\(index)] size: \(path)")
                }
                guard fileSize >= minimumBytes else {
                    throw ParseError(message: "mask.framePaths[\(index)] too small: \(fileSize) < \(minimumBytes) bytes")
                }
            }
            return .r8FrameFiles(framePaths: framePaths, width: width, height: height, rowStrideBytes: rowStrideBytes)

        default:
            throw ParseError(message: "mask.type must be one of constantAlpha, r8FrameFiles")
        }
    }

    private static func parseOptionalRect(_ raw: Any?, fitWithin size: Size, key: String) throws -> Rect? {
        guard let raw = ArgValue.unwrap(raw) else { return nil }
        guard let dict = raw as? [String: Any],
              let x = ArgValue.int(dict["x"]),
              let y = ArgValue.int(dict["y"]),
              let width = ArgValue.int(dict["width"]),
              let height = ArgValue.int(dict["height"]) else {
            throw ParseError(message: "\(key) must have integer x, y, width, height")
        }
        guard width > 0, height > 0 else {
            throw ParseError(message: "\(key) width and height must be positive")
        }
        guard x >= 0, y >= 0, x + width <= size.width, y + height <= size.height else {
            throw ParseError(message: "\(key) must fit within target size")
        }
        return Rect(x: x, y: y, width: width, height: height)
    }

    /// nil / NSNull -> default; any other non-integer value fails closed.
    private static func optionalInt(_ raw: Any?, key: String, defaultValue: Int) throws -> Int {
        guard ArgValue.unwrap(raw) != nil else { return defaultValue }
        guard let value = ArgValue.int(raw) else {
            throw ParseError(message: "\(key) must be an integer")
        }
        return value
    }

    /// nil / NSNull -> default; any other non-boolean value fails closed.
    private static func optionalBool(_ raw: Any?, key: String, defaultValue: Bool) throws -> Bool {
        guard ArgValue.unwrap(raw) != nil else { return defaultValue }
        guard let value = ArgValue.bool(raw) else {
            throw ParseError(message: "\(key) must be a boolean")
        }
        return value
    }

    fileprivate static func fileSize(atPath path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return Int(truncatingIfNeeded: size.int64Value)
    }
}

// MARK: - Export run

private enum RunOutcome {
    case success([String: Any])
    case failure(reason: String, details: [String: Any])
}

private struct ExportFailure: Error {
    let reason: String
}

/// One offline export. Owns every AVFoundation/CoreImage resource for its
/// lifetime and produces exactly one terminal map. Runs synchronously on the
/// session's serial queue; nothing here is thread-safe or reentrant.
///
/// Per output frame `i` (fixed clock, pts = CMTime(i, fps)):
///   1. foreground: the newest decoded BGRA sample whose PTS is <= i/fps.
///      A decoded sample whose PTS is ahead of i/fps is held as a pending
///      sample for a later output frame, and the previously selected buffer
///      is reused for this one. After EOS the last selected sample is held
///      and counted as held/heldAfterEos. No first sample by output frame 0
///      fails closed.
///   2. mask: the constant OneComponent8 buffer, or `framePaths[i]` read as
///      tightly validated R8 rows into a fresh OneComponent8 buffer.
///   3. CoreImage: rasterized background canvas + mirrored/rotated
///      aspect-filled foreground + aspect-filled mask -> CIBlendWithMask ->
///      a BGRA buffer from the writer adaptor's pool.
///   4. `AVAssetWriterInputPixelBufferAdaptor.append` at pts i/fps.
///
/// Output goes to `outputPath.tmp`. Only a verified non-empty tmp is renamed
/// onto `outputPath` (never overwriting an existing file); every failure path
/// deletes the tmp.
private final class ExportRun {

    private static let engineBoundary = "ios_greenscreen_export_engine_offline_static_background_fixed_clock"
    private static let logTag = "[VGGreenScreenExportSession]"
    private static let writerReadyTimeoutSeconds: TimeInterval = 10
    private static let writerFinishTimeoutSeconds: TimeInterval = 120
    private static let backgroundImageDecodeMaxDimensionFactor = 2
    private static let maxSamplesWithoutImageBuffer = 64

    private static let nonClaims: [String] = [
        "no_video_file_background",
        "no_live_camera",
        "no_ml_matte",
        "no_gpu_resident_mask_path",
        "no_audio",
        "no_av_sync",
        "no_realtime_clock",
        "no_cancellation",
        "no_container_rotation_auto_apply",
        // EXIF orientation IS applied on the primary bounded-thumbnail decode
        // path (loadBackgroundImage). This narrower claim covers only the
        // rare fallback (CGImageSourceCreateImageAtIndex with no transform
        // option) used when ImageIO's thumbnail generation itself fails.
        "no_image_exif_orientation_on_thumbnail_fallback_decode",
        "no_production_duet_wiring",
        "no_connectsapp_or_universal_editor_wiring",
        "fixed_offline_frame_clock_only",
    ]

    private let request: Request
    private let tmpPath: String
    private let canvasRect: CGRect
    private let foregroundRectCI: CGRect
    private let backgroundRectCI: CGRect

    // Resources (released in releaseResources()).
    private var reader: AVAssetReader?
    private var readerOutput: AVAssetReaderTrackOutput?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var ciContext: CIContext?
    private var backgroundBuffer: CVPixelBuffer?
    private var backgroundImage: CIImage?
    private var constantMaskBuffer: CVPixelBuffer?
    private var constantMaskImage: CIImage?
    private var currentMaskBuffer: CVPixelBuffer?
    /// The foreground buffer most recently selected for an output frame; also
    /// what is reused/held when no qualifying sample is available yet.
    private var lastSelectedForegroundBuffer: CVPixelBuffer?
    /// A decoded sample already pulled from the reader whose PTS is ahead of
    /// the most recently requested output frame's target PTS; carried over
    /// until an output frame's target PTS reaches it.
    private var pendingForegroundSample: (buffer: CVPixelBuffer, pts: CMTime)?
    private var writerFinished = false

    // Telemetry.
    private var renderedFrames = 0
    private var writtenVideoSamples = 0
    private var backgroundGeneratedFrames = 0
    private var backgroundRasterized = false
    private var backgroundContentWidth = 0
    private var backgroundContentHeight = 0
    private var foregroundDecoderName: String?
    private var foregroundContentWidth = 0
    private var foregroundContentHeight = 0
    private var foregroundContainerRotationDegrees = 0
    private var foregroundDecodedFrames = 0
    private var foregroundHeldFrames = 0
    private var foregroundHeldAfterEosFrames = 0
    private var foregroundDroppedFrames = 0
    private var foregroundEosReached = false
    private var finalFileSizeBytes = 0

    init(request: Request) {
        self.request = request
        self.tmpPath = request.tmpPath
        self.canvasRect = CGRect(x: 0, y: 0, width: request.targetSize.width, height: request.targetSize.height)
        self.foregroundRectCI = ExportRun.ciRect(request.effectiveForegroundRect, canvasHeight: request.targetSize.height)
        self.backgroundRectCI = ExportRun.ciRect(request.effectiveBackgroundRect, canvasHeight: request.targetSize.height)
    }

    // MARK: Terminal-state driver

    func run() -> RunOutcome {
        var failureReason: String?
        do {
            try execute()
        } catch let failure as ExportFailure {
            failureReason = failure.reason
        } catch {
            failureReason = "exception:\(error.localizedDescription)"
        }

        releaseResources()

        if failureReason == nil {
            do {
                try finalizeOutput()
            } catch let failure as ExportFailure {
                failureReason = failure.reason
            } catch {
                failureReason = "exception:\(error.localizedDescription)"
            }
        }

        if let reason = failureReason {
            deleteTmp()
            NSLog("%@ export failed reason=%@ rendered=%d written=%d expected=%d",
                  ExportRun.logTag, reason, renderedFrames, writtenVideoSamples, request.outputFrameCount)
            return .failure(reason: reason, details: buildMap(success: false, reason: reason))
        }

        NSLog("%@ export succeeded frames=%d bytes=%d background=%@",
              ExportRun.logTag, writtenVideoSamples, finalFileSizeBytes, request.background.typeName)
        return .success(buildMap(success: true, reason: "success"))
    }

    private func execute() throws {
        try prepareTmpAndOutput()
        try prepareForegroundReader()
        try prepareWriter()
        try prepareCIContext()
        try prepareBackground()
        try prepareConstantMask()
        try renderAllFrames()
        try finishWriter()
    }

    // MARK: Filesystem

    private func prepareTmpAndOutput() throws {
        let fileManager = FileManager.default
        var tmpIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: tmpPath, isDirectory: &tmpIsDirectory) {
            if tmpIsDirectory.boolValue {
                throw ExportFailure(reason: "stale_tmp_is_directory")
            }
            do {
                try fileManager.removeItem(atPath: tmpPath)
            } catch {
                throw ExportFailure(reason: "stale_tmp_delete_failed")
            }
        }
        if fileManager.fileExists(atPath: request.outputPath) {
            throw ExportFailure(reason: "output_already_exists")
        }
    }

    private func finalizeOutput() throws {
        let fileManager = FileManager.default
        guard let tmpSize = VGGreenScreenExportSession.fileSize(atPath: tmpPath) else {
            throw ExportFailure(reason: "tmp_output_missing")
        }
        guard tmpSize > 0 else {
            throw ExportFailure(reason: "tmp_output_empty")
        }
        // Never overwrite: re-check right before the rename; moveItem also
        // refuses an existing destination.
        guard !fileManager.fileExists(atPath: request.outputPath) else {
            throw ExportFailure(reason: "output_already_exists_at_finalize")
        }
        do {
            try fileManager.moveItem(atPath: tmpPath, toPath: request.outputPath)
        } catch {
            throw ExportFailure(reason: "output_rename_failed:\(error.localizedDescription)")
        }
        guard let finalSize = VGGreenScreenExportSession.fileSize(atPath: request.outputPath) else {
            throw ExportFailure(reason: "output_missing_after_rename")
        }
        guard finalSize > 0 else {
            // Our own just-renamed product is unusable; remove it so a retry
            // does not trip the never-overwrite guard on an empty file.
            try? fileManager.removeItem(atPath: request.outputPath)
            throw ExportFailure(reason: "output_empty_after_rename")
        }
        finalFileSizeBytes = finalSize
    }

    private func deleteTmp() {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: tmpPath, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
        try? fileManager.removeItem(atPath: tmpPath)
    }

    // MARK: Foreground decode lane

    private func prepareForegroundReader() throws {
        let url = URL(fileURLWithPath: request.foregroundVideoPath)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw ExportFailure(reason: "foreground_no_video_track")
        }

        let natural = track.naturalSize
        let contentWidth = Int(natural.width.rounded())
        let contentHeight = Int(natural.height.rounded())
        guard contentWidth > 0, contentHeight > 0 else {
            throw ExportFailure(reason: "foreground_track_dimensions_invalid:\(contentWidth)x\(contentHeight)")
        }
        foregroundContentWidth = contentWidth
        foregroundContentHeight = contentHeight
        // Telemetry only. Container rotation is never auto-applied.
        foregroundContainerRotationDegrees = ExportRun.rotationDegrees(from: track.preferredTransform)
        foregroundDecoderName = ExportRun.decoderName(for: track)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ExportFailure(reason: "foreground_reader_init_failed:\(error.localizedDescription)")
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ExportFailure(reason: "foreground_reader_output_rejected")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ExportFailure(reason: "foreground_reader_start_failed:\(reader.error?.localizedDescription ?? "unknown")")
        }
        self.reader = reader
        self.readerOutput = output
    }

    /// PTS-based pairing: selects the newest decoded foreground sample whose
    /// presentation timestamp is <= this output frame's target PTS
    /// (`CMTime(frameIndex, fps)`). A decoded sample ahead of the target is
    /// carried over in `pendingForegroundSample` for a later frame, and any
    /// samples superseded by a newer qualifying sample before ever being
    /// rendered are counted as dropped. After EOS (or while waiting on a
    /// pending future sample), the last selected sample is held.
    private func nextForegroundBuffer(frameIndex: Int) throws -> CVPixelBuffer {
        guard let reader = reader, let output = readerOutput else {
            throw ExportFailure(reason: "foreground_reader_missing:frame=\(frameIndex)")
        }

        let targetPTS = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(request.fps))
        var candidate: CVPixelBuffer?

        if let pending = pendingForegroundSample {
            if pending.pts <= targetPTS {
                candidate = pending.buffer
                pendingForegroundSample = nil
            } else {
                // The next decoded sample is still ahead of this frame's
                // target PTS; nothing to decode yet, hold the last selection.
                return try holdCurrentForegroundSelection(frameIndex: frameIndex)
            }
        }

        if !foregroundEosReached {
            var samplesWithoutImage = 0
            readLoop: while true {
                if let sample = output.copyNextSampleBuffer() {
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                        // A sample without an image buffer carries no picture; skip it.
                        samplesWithoutImage += 1
                        if samplesWithoutImage > ExportRun.maxSamplesWithoutImageBuffer {
                            throw ExportFailure(reason: "foreground_decode_no_image_buffers:frame=\(frameIndex)")
                        }
                        continue readLoop
                    }
                    foregroundDecodedFrames += 1
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    if pts <= targetPTS {
                        // A newer qualifying sample supersedes any earlier
                        // candidate for this same output PTS before it is
                        // ever rendered.
                        if candidate != nil {
                            foregroundDroppedFrames += 1
                        }
                        candidate = pixelBuffer
                        continue readLoop
                    } else {
                        pendingForegroundSample = (pixelBuffer, pts)
                        break readLoop
                    }
                }
                switch reader.status {
                case .failed:
                    throw ExportFailure(reason: "foreground_decode_failed:frame=\(frameIndex):\(reader.error?.localizedDescription ?? "unknown")")
                case .cancelled:
                    throw ExportFailure(reason: "foreground_decode_cancelled:frame=\(frameIndex)")
                default:
                    // .completed, or a nil sample while still .reading: no more pictures.
                    foregroundEosReached = true
                }
                break readLoop
            }
        }

        if let candidate = candidate {
            lastSelectedForegroundBuffer = candidate
            return candidate
        }

        return try holdCurrentForegroundSelection(frameIndex: frameIndex)
    }

    /// Reuses the most recently selected foreground sample because no
    /// sample with PTS <= this frame's target PTS is available yet (either
    /// still waiting on a pending future sample, or the reader hit EOS).
    private func holdCurrentForegroundSelection(frameIndex: Int) throws -> CVPixelBuffer {
        guard let held = lastSelectedForegroundBuffer else {
            throw ExportFailure(reason: "foreground_no_first_frame:frame=\(frameIndex)")
        }
        foregroundHeldFrames += 1
        if foregroundEosReached {
            foregroundHeldAfterEosFrames += 1
        }
        return held
    }

    // MARK: Writer

    private func prepareWriter() throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: tmpPath), fileType: .mp4)
        } catch {
            throw ExportFailure(reason: "writer_init_failed:\(error.localizedDescription)")
        }

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: request.videoBitRate,
            AVVideoExpectedSourceFrameRateKey: request.fps,
            // One keyframe per second, matching the Android engine's I-frame interval.
            AVVideoMaxKeyFrameIntervalKey: request.fps,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: request.targetSize.width,
            AVVideoHeightKey: request.targetSize.height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw ExportFailure(reason: "writer_settings_rejected:\(request.targetSize.width)x\(request.targetSize.height)")
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: request.targetSize.width,
            kCVPixelBufferHeightKey as String: request.targetSize.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: sourceAttributes)

        guard writer.canAdd(input) else {
            throw ExportFailure(reason: "writer_input_rejected")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportFailure(reason: "writer_start_failed:\(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.writerInput = input
        self.adaptor = adaptor
    }

    private func waitUntilWriterReady(_ input: AVAssetWriterInput, writer: AVAssetWriter, frameIndex: Int) throws {
        let deadline = Date(timeIntervalSinceNow: ExportRun.writerReadyTimeoutSeconds)
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw ExportFailure(reason: "writer_failed:frame=\(frameIndex):\(writer.error?.localizedDescription ?? "unknown")")
            }
            guard writer.status == .writing else {
                throw ExportFailure(reason: "writer_not_writing:frame=\(frameIndex):status=\(writer.status.rawValue)")
            }
            if Date() > deadline {
                throw ExportFailure(reason: "writer_input_not_ready_timeout:frame=\(frameIndex)")
            }
            usleep(1_000)
        }
    }

    private func finishWriter() throws {
        guard let writer = writer, let input = writerInput else {
            throw ExportFailure(reason: "writer_missing_at_finish")
        }
        guard renderedFrames == request.outputFrameCount, writtenVideoSamples == renderedFrames else {
            throw ExportFailure(reason: "sample_count_mismatch;rendered=\(renderedFrames);written=\(writtenVideoSamples);expected=\(request.outputFrameCount)")
        }
        guard writer.status == .writing else {
            throw ExportFailure(reason: "writer_not_writing_at_finish:status=\(writer.status.rawValue):\(writer.error?.localizedDescription ?? "unknown")")
        }

        input.markAsFinished()
        // Ends the session exactly at outputFrameCount / fps so the last frame
        // carries a full frame duration and the container duration is nominal.
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(request.outputFrameCount), timescale: CMTimeScale(request.fps)))

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        guard semaphore.wait(timeout: .now() + ExportRun.writerFinishTimeoutSeconds) == .success else {
            throw ExportFailure(reason: "writer_finish_timeout")
        }
        guard writer.status == .completed else {
            throw ExportFailure(reason: "writer_finish_failed:status=\(writer.status.rawValue):\(writer.error?.localizedDescription ?? "unknown")")
        }
        writerFinished = true
    }

    // MARK: CoreImage

    private func prepareCIContext() throws {
        // Color management off (same as VGDuetPreviewCompositor): decoded BGRA,
        // the solid color, and the mask are blended byte-for-byte as authored.
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            NSLog("%@ MTLCreateSystemDefaultDevice nil; CPU CIContext fallback", ExportRun.logTag)
            ciContext = CIContext(options: options)
        }
    }

    /// Builds the opaque canvas-sized background once and rasterizes it into a
    /// BGRA buffer so every frame samples a fixed, already-decoded image.
    private func prepareBackground() throws {
        guard let context = ciContext else {
            throw ExportFailure(reason: "ci_context_missing")
        }
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: canvasRect)
        let composed: CIImage

        switch request.background {
        case .solidColor(let argb):
            // Alpha ignored: the background lane is opaque. The color fills the
            // background rect (the full canvas when no rect is given); any
            // canvas area outside the rect stays black, matching Android's
            // generated-clip placement.
            let fill = CIImage(color: ExportRun.ciColor(argb: argb)).cropped(to: backgroundRectCI)
            composed = fill.composited(over: black)
            backgroundContentWidth = request.effectiveBackgroundRect.width
            backgroundContentHeight = request.effectiveBackgroundRect.height

        case .imageFile(let path, let scaleMode):
            let bounds = request.effectiveBackgroundRect
            let maxPixelSize = max(bounds.width, bounds.height) * ExportRun.backgroundImageDecodeMaxDimensionFactor
            guard let cgImage = ExportRun.loadBackgroundImage(path: path, maxPixelSize: maxPixelSize) else {
                throw ExportFailure(reason: "background_image_decode_failed")
            }
            var image = CIImage(cgImage: cgImage)
            guard image.extent.width > 0, image.extent.height > 0 else {
                throw ExportFailure(reason: "background_image_empty")
            }
            if request.backgroundMirrorHorizontal {
                image = ExportRun.mirroredHorizontally(image)
            }
            image = ExportRun.rotatedClockwise(image, degrees: request.backgroundRotationDegrees)
            backgroundContentWidth = Int(image.extent.width.rounded())
            backgroundContentHeight = Int(image.extent.height.rounded())
            let placed = ExportRun.place(image, into: backgroundRectCI, mode: scaleMode)
            composed = placed.composited(over: black)
        }

        let buffer = try ExportRun.makePixelBuffer(
            width: request.targetSize.width,
            height: request.targetSize.height,
            format: kCVPixelFormatType_32BGRA,
            failureReason: "background_buffer_alloc_failed"
        )
        context.render(composed.cropped(to: canvasRect), to: buffer, bounds: canvasRect, colorSpace: nil)
        backgroundBuffer = buffer
        backgroundImage = CIImage(cvPixelBuffer: buffer)
        backgroundRasterized = true
    }

    private func prepareConstantMask() throws {
        guard case .constantAlpha(let alpha, let width, let height) = request.mask else { return }
        let buffer = try ExportRun.makePixelBuffer(
            width: width,
            height: height,
            format: kCVPixelFormatType_OneComponent8,
            failureReason: "mask_buffer_alloc_failed"
        )
        try ExportRun.fill(maskBuffer: buffer, constant: UInt8(clamping: alpha))
        constantMaskBuffer = buffer
        constantMaskImage = CIImage(cvPixelBuffer: buffer)
    }

    /// Mask for output frame `index` as a CIImage backed by a OneComponent8
    /// buffer (retained in `currentMaskBuffer` until the frame is rendered).
    private func maskImage(forFrame index: Int) throws -> CIImage {
        switch request.mask {
        case .constantAlpha:
            guard let image = constantMaskImage else {
                throw ExportFailure(reason: "constant_mask_missing:frame=\(index)")
            }
            return image

        case .r8FrameFiles(let framePaths, let width, let height, let rowStrideBytes):
            guard index < framePaths.count else {
                throw ExportFailure(reason: "mask_frame_index_out_of_range:index=\(index):count=\(framePaths.count)")
            }
            let path = framePaths[index]
            let sourceStride = rowStrideBytes == 0 ? width : rowStrideBytes
            let expectedBytes = sourceStride * height

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw ExportFailure(reason: "mask_frame_file_missing:index=\(index)")
            }
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.uncached])
            } catch {
                throw ExportFailure(reason: "mask_frame_file_unreadable:index=\(index):\(error.localizedDescription)")
            }
            guard data.count >= expectedBytes else {
                throw ExportFailure(reason: "mask_frame_file_short:index=\(index):read=\(data.count):expected=\(expectedBytes)")
            }

            let buffer = try ExportRun.makePixelBuffer(
                width: width,
                height: height,
                format: kCVPixelFormatType_OneComponent8,
                failureReason: "mask_buffer_alloc_failed:index=\(index)"
            )
            try ExportRun.fill(maskBuffer: buffer, from: data, width: width, height: height, sourceStride: sourceStride)
            currentMaskBuffer = buffer
            return CIImage(cvPixelBuffer: buffer)
        }
    }

    private func composeFrame(foreground: CVPixelBuffer, mask: CIImage, background: CIImage) throws -> CIImage {
        var image = CIImage(cvPixelBuffer: foreground)
        if request.foregroundMirrorHorizontal {
            image = ExportRun.mirroredHorizontally(image)
        }
        image = ExportRun.rotatedClockwise(image, degrees: request.foregroundRotationDegrees)
        let foregroundPlaced = ExportRun.place(image, into: foregroundRectCI, mode: .aspectFill)
        // The mask is interpreted in foreground-rect space and aspect-filled
        // exactly like the foreground content, so a mask that shares the
        // content's aspect stays aligned and a rect-shaped mask covers the rect.
        let maskPlaced = ExportRun.place(mask, into: foregroundRectCI, mode: .aspectFill)

        let parameters: [String: Any] = [
            kCIInputImageKey: foregroundPlaced,
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: maskPlaced,
        ]
        guard let blended = CIFilter(name: "CIBlendWithMask", parameters: parameters)?.outputImage else {
            throw ExportFailure(reason: "ci_blend_with_mask_unavailable")
        }
        return blended.cropped(to: canvasRect)
    }

    private func renderAllFrames() throws {
        guard let context = ciContext else {
            throw ExportFailure(reason: "ci_context_missing")
        }
        guard let writer = writer, let input = writerInput, let adaptor = adaptor else {
            throw ExportFailure(reason: "writer_missing")
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw ExportFailure(reason: "writer_pixel_buffer_pool_missing")
        }
        guard let background = backgroundImage else {
            throw ExportFailure(reason: "background_not_rasterized")
        }

        for index in 0..<request.outputFrameCount {
            let foregroundBuffer = try nextForegroundBuffer(frameIndex: index)
            let mask = try maskImage(forFrame: index)
            let composite = try composeFrame(foreground: foregroundBuffer, mask: mask, background: background)

            var pooled: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pooled)
            guard status == kCVReturnSuccess, let target = pooled else {
                throw ExportFailure(reason: "output_buffer_alloc_failed:frame=\(index):status=\(status)")
            }

            context.render(composite, to: target, bounds: canvasRect, colorSpace: nil)
            renderedFrames += 1
            backgroundGeneratedFrames += 1
            currentMaskBuffer = nil

            let presentationTime = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(request.fps))
            try waitUntilWriterReady(input, writer: writer, frameIndex: index)
            guard adaptor.append(target, withPresentationTime: presentationTime) else {
                throw ExportFailure(reason: "writer_append_failed:frame=\(index):\(writer.error?.localizedDescription ?? "unknown")")
            }
            writtenVideoSamples += 1
        }
    }

    // MARK: Release

    /// Idempotent. Order: held frames/masks -> reader -> writer (cancelled if
    /// still writing) -> CoreImage resources.
    private func releaseResources() {
        currentMaskBuffer = nil
        lastSelectedForegroundBuffer = nil
        pendingForegroundSample = nil

        if let reader = reader, reader.status == .reading {
            reader.cancelReading()
        }
        readerOutput = nil
        reader = nil

        if let writer = writer, !writerFinished, writer.status == .writing {
            writer.cancelWriting()
        }
        adaptor = nil
        writerInput = nil
        writer = nil

        backgroundImage = nil
        backgroundBuffer = nil
        constantMaskImage = nil
        constantMaskBuffer = nil
        ciContext = nil
    }

    // MARK: Result map

    private func buildMap(success: Bool, reason: String) -> [String: Any] {
        let fileManager = FileManager.default
        let tmpExists = fileManager.fileExists(atPath: tmpPath)
        let outputExists = fileManager.fileExists(atPath: request.outputPath)
        let fileSizeBytes: Int
        if success {
            fileSizeBytes = finalFileSizeBytes
        } else {
            fileSizeBytes = outputExists ? (VGGreenScreenExportSession.fileSize(atPath: request.outputPath) ?? 0) : 0
        }
        let nominalDurationMs = request.nominalDurationMs
        // A verified success always describes a playable file; clamp so a
        // sub-millisecond nominal clock never trips the Dart positivity check.
        let durationMs = success ? max(1, nominalDurationMs) : nominalDurationMs
        let complete = renderedFrames == request.outputFrameCount && writtenVideoSamples == renderedFrames
        let renderedEqualsWritten = complete && renderedFrames == writtenVideoSamples

        var claims: [String] = []
        if success {
            claims = [
                "generic_green_screen_export_engine_boundary",
                "static_background_ios_export",
                "fixed_output_clock_pts_based_foreground_pairing",
                "atomic_tmp_rename_output",
                "cpu_r8_mask_frozen_dimensions",
                "rendered_equals_written_samples",
            ]
            if !tmpExists {
                claims.append("clean_tmp_cleanup")
            }
        }

        var nonClaims = ExportRun.nonClaims
        if !success {
            if renderedFrames < request.outputFrameCount {
                nonClaims.append("frames_not_fully_rendered")
            }
            if writtenVideoSamples < request.outputFrameCount {
                nonClaims.append("video_not_fully_written")
            }
            if !outputExists {
                nonClaims.append("output_file_not_created")
            }
            if tmpExists {
                nonClaims.append("tmp_cleanup_incomplete")
            }
        }

        return [
            "pass": success,
            "terminalState": success ? "success" : "failed",
            "reason": reason,
            "engineBoundary": ExportRun.engineBoundary,
            "outputPath": request.outputPath,
            "outputSize": [
                "width": request.targetSize.width,
                "height": request.targetSize.height,
            ],
            "fileSizeBytes": fileSizeBytes,
            "durationMs": durationMs,
            "outputExists": outputExists,
            "tmpExists": tmpExists,
            "fps": request.fps,
            "outputFrameCount": request.outputFrameCount,
            "renderedFrames": renderedFrames,
            "writtenVideoSamples": writtenVideoSamples,
            "renderedEqualsWritten": renderedEqualsWritten,
            "backgroundDecoderName": backgroundRasterized ? "coreimage_static_\(request.background.typeName)" : NSNull(),
            "backgroundContentWidth": backgroundContentWidth,
            "backgroundContentHeight": backgroundContentHeight,
            "backgroundContainerRotationDegrees": 0,
            "backgroundDecodedFrames": backgroundRasterized ? 1 : 0,
            "backgroundHeldFrames": max(0, backgroundGeneratedFrames - 1),
            "backgroundHeldAfterEosFrames": 0,
            "backgroundDroppedFrames": 0,
            "backgroundEosReached": false,
            "foregroundDecoderName": foregroundDecoderName ?? NSNull(),
            "foregroundContentWidth": foregroundContentWidth,
            "foregroundContentHeight": foregroundContentHeight,
            "foregroundContainerRotationDegrees": foregroundContainerRotationDegrees,
            "foregroundDecodedFrames": foregroundDecodedFrames,
            "foregroundHeldFrames": foregroundHeldFrames,
            "foregroundHeldAfterEosFrames": foregroundHeldAfterEosFrames,
            "foregroundDroppedFrames": foregroundDroppedFrames,
            "foregroundEosReached": foregroundEosReached,
            "backgroundSourceType": request.background.typeName,
            "backgroundGeneratedFrames": backgroundGeneratedFrames,
            "backgroundGeneratedTmpExists": false,
            "maskWidth": request.mask.width,
            "maskHeight": request.mask.height,
            "claims": claims,
            "nonClaims": nonClaims,
        ]
    }

    // MARK: Geometry helpers (CoreImage bottom-left space)

    /// Dart top-left canvas rect -> CoreImage bottom-left rect. Rects are
    /// integer and already validated to lie inside the canvas.
    private static func ciRect(_ rect: Rect, canvasHeight: Int) -> CGRect {
        return CGRect(
            x: CGFloat(rect.x),
            y: CGFloat(canvasHeight - rect.y - rect.height),
            width: CGFloat(rect.width),
            height: CGFloat(rect.height)
        )
    }

    /// Scale `image` into `rect` (aspect-fill center-crops, aspect-fit centers
    /// with the underlying canvas showing through), then crop to `rect`.
    private static func place(_ image: CIImage, into rect: CGRect, mode: ScaleMode) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return CIImage.empty() }
        let scaleX = rect.width / extent.width
        let scaleY = rect.height / extent.height
        let scale = mode == .aspectFill ? max(scaleX, scaleY) : min(scaleX, scaleY)
        let scaledWidth = extent.width * scale
        let scaledHeight = extent.height * scale
        let tx = rect.minX + (rect.width - scaledWidth) / 2 - extent.minX * scale
        let ty = rect.minY + (rect.height - scaledHeight) / 2 - extent.minY * scale
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
        return image.transformed(by: transform).cropped(to: rect)
    }

    /// Flips about the extent's vertical center line; the extent is unchanged.
    private static func mirroredHorizontally(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: extent.minX + extent.maxX, ty: 0)
        return image.transformed(by: transform)
    }

    /// Cardinal clockwise rotation (as seen by the viewer) using exact integer
    /// matrices so the rotated extent stays pixel-aligned at the origin.
    private static func rotatedClockwise(_ image: CIImage, degrees: Int) -> CIImage {
        let extent = image.extent
        let width = extent.width
        let height = extent.height
        let anchored: CIImage
        if extent.minX == 0 && extent.minY == 0 {
            anchored = image
        } else {
            anchored = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        }
        switch degrees {
        case 90:
            // (x, y) -> (y, width - x); result is height x width.
            return anchored.transformed(by: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width))
        case 180:
            // (x, y) -> (width - x, height - y).
            return anchored.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height))
        case 270:
            // (x, y) -> (height - y, x); result is height x width.
            return anchored.transformed(by: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0))
        default:
            return anchored
        }
    }

    private static func ciColor(argb: Int32) -> CIColor {
        let value = UInt32(bitPattern: argb)
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        return CIColor(red: red, green: green, blue: blue, alpha: 1)
    }

    // MARK: Image / buffer helpers

    /// Decodes the background image bounded to `maxPixelSize` on its longer
    /// side (never upscaled). EXIF orientation is applied so the returned
    /// CGImage is in visual (display) orientation, matching preview.
    private static func loadBackgroundImage(path: String, maxPixelSize: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let bounded = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
            return bounded
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func makePixelBuffer(width: Int, height: Int, format: OSType, failureReason: String) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw ExportFailure(reason: "\(failureReason):status=\(status)")
        }
        return buffer
    }

    private static func fill(maskBuffer buffer: CVPixelBuffer, constant: UInt8) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw ExportFailure(reason: "mask_buffer_base_address_missing")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        memset(base, Int32(constant), bytesPerRow * height)
    }

    /// Copies `height` rows of `width` bytes from `data` (row pitch
    /// `sourceStride`) into the buffer's own row pitch. `data.count` must
    /// already be verified >= sourceStride * height.
    private static func fill(maskBuffer buffer: CVPixelBuffer, from data: Data, width: Int, height: Int, sourceStride: Int) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw ExportFailure(reason: "mask_buffer_base_address_missing")
        }
        let destinationStride = CVPixelBufferGetBytesPerRow(buffer)
        guard destinationStride >= width,
              CVPixelBufferGetWidth(buffer) >= width,
              CVPixelBufferGetHeight(buffer) >= height,
              data.count >= sourceStride * height else {
            throw ExportFailure(reason: "mask_buffer_geometry_mismatch")
        }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let source = raw.baseAddress else { return }
            for row in 0..<height {
                memcpy(base.advanced(by: row * destinationStride), source.advanced(by: row * sourceStride), width)
            }
        }
    }

    /// Track rotation from `preferredTransform`, snapped to a cardinal angle.
    /// Telemetry only; never applied.
    private static func rotationDegrees(from transform: CGAffineTransform) -> Int {
        let radians = atan2(Double(transform.b), Double(transform.a))
        var degrees = Int((radians * 180.0 / Double.pi).rounded())
        degrees = ((degrees % 360) + 360) % 360
        return ((degrees + 45) / 90 * 90) % 360
    }

    private static func decoderName(for track: AVAssetTrack) -> String {
        guard let first = track.formatDescriptions.first,
              CFGetTypeID(first as CFTypeRef) == CMFormatDescriptionGetTypeID() else {
            return "avassetreader"
        }
        let description = first as! CMFormatDescription
        return "avassetreader:" + fourCharCode(CMFormatDescriptionGetMediaSubType(description))
    }

    private static func fourCharCode(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes.map { byte -> Character in
            (byte >= 32 && byte < 127) ? Character(UnicodeScalar(byte)) : "?"
        })
    }
}
