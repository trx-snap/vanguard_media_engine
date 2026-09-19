// VGARKitPersonSegmentationMatteStillProbe.swift
// RND diagnostic: ARKit ARMatteGenerator still-image matte proof.
//
// Defines VGARKitPersonSegmentationMatteStillProbe (entry point `run`), its
// error enum, and the file-private ARMatteStillFrameCapture ARSession driver.
// Sole caller: VGLiveGreenScreenMethodHandler's
// runLiveGreenScreenARKitPersonSegmentationMatteStillProbe route. Not a public
// Dart API; never touches VGLiveGreenScreenSessionCoordinator or any live path.
//
// Packaging: ios/vanguard_media_engine.podspec globs Classes/**/*.swift, so any
// regenerated Pods project picks this file up automatically. The checked-in
// example/ios Pods project was given this file's membership by hand
// (2026-09-18, no pod install); backout steps are recorded in the Phase 10E
// Green Screen RND Ledger.

import ARKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Metal
import QuartzCore
import UIKit

// MARK: - ARKit person-segmentation matte still probe (diagnostic-only)
//
// Generic ARKit diagnostics: RND still-image visual proof that ARMatteGenerator
// (not the raw 256x192 ARFrame.segmentationBuffer) can produce a high-quality
// full-resolution alpha matte from a physical-device ARFrame, composited over a
// solid teal background into a single PNG for visual inspection.
//
// Proof boundary: ios_arkit_person_segmentation_matte_still_physical_smoke.
// Not part of any live green-screen session and not a public Dart API. Owned
// exclusively by VGLiveGreenScreenMethodHandler's
// `runLiveGreenScreenARKitPersonSegmentationMatteStillProbe` route, which is the
// only caller of `VGARKitPersonSegmentationMatteStillProbe.run`. Never touches
// VGLiveGreenScreenSessionCoordinator, Vision, LiteRT, or any live compositing
// path.
//
// Flow: start a throwaway ARSession (own instance, never the coordinator's)
// with either ARFaceTrackingConfiguration (`trackingConfiguration == "face"`,
// default, front camera) or ARWorldTrackingConfiguration
// (`trackingConfiguration == "world"`, rear camera), both with
// `.personSegmentation`; collect until the first ARFrame with a non-nil
// `segmentationBuffer`, `maxFrameCount`, or `timeoutSeconds`, whichever comes
// first, pausing the session on every completion, failure, or timeout path.
// On a captured frame, generate a full-resolution alpha matte with
// ARMatteGenerator(device:matteResolution: .full), composite the frame's
// `capturedImage` over solid teal using that matte via CIBlendWithMask, and
// write the result as a PNG to a unique path under NSTemporaryDirectory
// (`outputPath`: raw ARFrame sensor-space orientation, unchanged). Then, from
// the exact same camera image and the exact same matte, write one extra
// display-orientation candidate PNG per `CandidateMode` (left, right,
// leftMirrored, rightMirrored), applying the identical
// CGImagePropertyOrientation to camera and matte before blending so the two
// can never drift apart. Candidates exist so the correct portrait/mirror
// display transform can be chosen by eye on device; they never change matte
// content and none is a live green-screen production choice. For
// `trackingConfiguration == "face"` the RND still-proof display selection is
// locked to `leftMirrored` (chosen on device 2026-09-18: upright portrait,
// natural front-camera/selfie preview; `right` stays the upright
// non-mirrored/export-style alternative). The selection is reported through
// `selectedDisplayOrientationMode` / `selectedDisplayOrientationCandidate` /
// `selectedDisplayOrientationCandidateFailure` on top of the unchanged
// candidate matrix, and applies to this diagnostic still proof only.
//
// Fail-closed: an unsupported tracking configuration / person segmentation, a
// capture timeout/frame-limit without ever observing a mask, an unexpected
// matte texture pixel format, or a matte/capturedImage dimension mismatch all
// report `pass: false` with a `failureReason` string — never a crash and never
// a silent fallback to the raw segmentation buffer for the composite. Only the
// raw composite is fail-closed: a display candidate that cannot be written is
// reported through `displayOrientationCandidateFailure` and never flips
// `pass`, because `outputPath` already succeeded by then.
//
// All heavy work (ARMatteGenerator, CoreImage compositing, PNG encode/write)
// runs off the main thread; `completion` still fires exactly once, on the main
// queue, matching VGLiveGreenScreenMethodHandler's other diagnostic routes.

enum VGARKitPersonSegmentationMatteStillProbeError: LocalizedError {
    case compositionFailed(String)
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .compositionFailed(let msg): return "composition_failed: \(msg)"
        case .ioError(let msg):           return "io_error: \(msg)"
        }
    }
}

final class VGARKitPersonSegmentationMatteStillProbe {

    static let proofBoundary = "ios_arkit_person_segmentation_matte_still_physical_smoke"

    /// Solid teal (#008080) background used for the composite, matching the
    /// task's fixed-color proof requirement (not configurable — a diagnostic
    /// constant, not a production background option).
    private static let tealColor = CIColor(red: 0.0, green: 0.5019607843137255, blue: 0.5019607843137255, alpha: 1.0)

    private static let compositeCIContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .cacheIntermediates: false,
    ])

    // MARK: - Entry point

    static func run(trackingConfiguration: String,
                     timeoutSeconds: Double,
                     maxFrameCount: Int,
                     completion: @escaping ([String: Any]) -> Void) {
        NSLog("IOS_ARKIT_MATTE_STILL_PROBE_START trackingConfiguration=\(trackingConfiguration) timeoutSeconds=\(timeoutSeconds) maxFrameCount=\(maxFrameCount)")

        let activeTrackingUsesFrontCamera = trackingConfiguration == "face"
        let activeSupported: Bool
        let failureReasonIfUnsupported: String
        let configuration: ARConfiguration

        if activeTrackingUsesFrontCamera {
            let faceTrackingSupported = ARFaceTrackingConfiguration.isSupported
            let facePersonSegmentationSupported = ARFaceTrackingConfiguration.supportsFrameSemantics(.personSegmentation)
            activeSupported = faceTrackingSupported && facePersonSegmentationSupported
            failureReasonIfUnsupported = !faceTrackingSupported
                ? "face_tracking_unsupported"
                : "face_person_segmentation_unsupported"
            let faceConfiguration = ARFaceTrackingConfiguration()
            faceConfiguration.frameSemantics.insert(.personSegmentation)
            configuration = faceConfiguration
        } else {
            let worldTrackingSupported = ARWorldTrackingConfiguration.isSupported
            let personSegmentationSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation)
            activeSupported = worldTrackingSupported && personSegmentationSupported
            failureReasonIfUnsupported = !worldTrackingSupported
                ? "world_tracking_unsupported"
                : "person_segmentation_unsupported"
            let worldConfiguration = ARWorldTrackingConfiguration()
            worldConfiguration.frameSemantics.insert(.personSegmentation)
            configuration = worldConfiguration
        }

        guard activeSupported else {
            NSLog("IOS_ARKIT_MATTE_STILL_PROBE_FAIL trackingConfiguration=\(trackingConfiguration) reason=\(failureReasonIfUnsupported)")
            completion(makeResult(
                pass: false,
                trackingConfiguration: trackingConfiguration,
                activeTrackingUsesFrontCamera: activeTrackingUsesFrontCamera,
                outputPath: nil, outputBytes: 0,
                frameCount: 0, maskCount: 0,
                rawSegmentationBufferWidth: 0, rawSegmentationBufferHeight: 0,
                capturedImageWidth: 0, capturedImageHeight: 0,
                matteWidth: 0, matteHeight: 0,
                firstMaskLatencyMs: nil, averageFrameIntervalMs: nil,
                matteGenerationMs: nil, compositeWriteMs: nil,
                failureReason: failureReasonIfUnsupported))
            return
        }

        // Retained for its own lifetime by the strong `self` capture in its
        // pending timeout closure (ARSession.delegate is a weak reference).
        let capture = ARMatteStillFrameCapture(
            configuration: configuration,
            trackingConfiguration: trackingConfiguration,
            maxFrameCount: max(1, maxFrameCount),
            timeoutSeconds: max(0.1, timeoutSeconds)
        ) { outcome in
            handleCaptureOutcome(outcome,
                                 trackingConfiguration: trackingConfiguration,
                                 activeTrackingUsesFrontCamera: activeTrackingUsesFrontCamera,
                                 completion: completion)
        }
        capture.start()
    }

    // MARK: - Post-capture: matte generation + composite + write

    private static func handleCaptureOutcome(_ outcome: ARMatteStillFrameCapture.Outcome,
                                             trackingConfiguration: String,
                                             activeTrackingUsesFrontCamera: Bool,
                                             completion: @escaping ([String: Any]) -> Void) {
        guard let frame = outcome.frame, outcome.maskCount > 0 else {
            let reason = outcome.failureReason ?? "no_frame_captured"
            NSLog("IOS_ARKIT_MATTE_STILL_PROBE_FAIL trackingConfiguration=\(trackingConfiguration) reason=\(reason)")
            completion(makeResult(
                pass: false,
                trackingConfiguration: trackingConfiguration,
                activeTrackingUsesFrontCamera: activeTrackingUsesFrontCamera,
                outputPath: nil, outputBytes: 0,
                frameCount: outcome.frameCount, maskCount: outcome.maskCount,
                rawSegmentationBufferWidth: outcome.rawSegmentationBufferWidth,
                rawSegmentationBufferHeight: outcome.rawSegmentationBufferHeight,
                capturedImageWidth: outcome.capturedImageWidth, capturedImageHeight: outcome.capturedImageHeight,
                matteWidth: 0, matteHeight: 0,
                firstMaskLatencyMs: outcome.firstMaskLatencyMs, averageFrameIntervalMs: outcome.averageFrameIntervalMs,
                matteGenerationMs: nil, compositeWriteMs: nil,
                failureReason: reason))
            return
        }

        // Metal, CoreImage, and file I/O run off the main thread; only the
        // final `completion` call is dispatched back to main.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let composite = try generateMatteAndComposite(frame: frame, trackingConfiguration: trackingConfiguration)
                NSLog("IOS_ARKIT_MATTE_STILL_PROBE_PASS trackingConfiguration=\(trackingConfiguration)")
                let result = makeResult(
                    pass: true,
                    trackingConfiguration: trackingConfiguration,
                    activeTrackingUsesFrontCamera: activeTrackingUsesFrontCamera,
                    outputPath: composite.outputPath, outputBytes: composite.outputBytes,
                    frameCount: outcome.frameCount, maskCount: outcome.maskCount,
                    rawSegmentationBufferWidth: outcome.rawSegmentationBufferWidth,
                    rawSegmentationBufferHeight: outcome.rawSegmentationBufferHeight,
                    capturedImageWidth: composite.capturedImageWidth, capturedImageHeight: composite.capturedImageHeight,
                    matteWidth: composite.matteWidth, matteHeight: composite.matteHeight,
                    firstMaskLatencyMs: outcome.firstMaskLatencyMs, averageFrameIntervalMs: outcome.averageFrameIntervalMs,
                    matteGenerationMs: composite.matteGenerationMs, compositeWriteMs: composite.compositeWriteMs,
                    failureReason: nil,
                    displayOrientationCandidates: composite.displayOrientationCandidates,
                    displayOrientationCandidateFailure: composite.displayOrientationCandidateFailure,
                    displayOrientationCandidatesWriteMs: composite.displayOrientationCandidatesWriteMs)
                DispatchQueue.main.async { completion(result) }
            } catch {
                let reason = (error as? VGARKitPersonSegmentationMatteStillProbeError)?.errorDescription
                    ?? error.localizedDescription
                NSLog("IOS_ARKIT_MATTE_STILL_PROBE_FAIL trackingConfiguration=\(trackingConfiguration) reason=\(reason)")
                let result = makeResult(
                    pass: false,
                    trackingConfiguration: trackingConfiguration,
                    activeTrackingUsesFrontCamera: activeTrackingUsesFrontCamera,
                    outputPath: nil, outputBytes: 0,
                    frameCount: outcome.frameCount, maskCount: outcome.maskCount,
                    rawSegmentationBufferWidth: outcome.rawSegmentationBufferWidth,
                    rawSegmentationBufferHeight: outcome.rawSegmentationBufferHeight,
                    capturedImageWidth: outcome.capturedImageWidth, capturedImageHeight: outcome.capturedImageHeight,
                    matteWidth: 0, matteHeight: 0,
                    firstMaskLatencyMs: outcome.firstMaskLatencyMs, averageFrameIntervalMs: outcome.averageFrameIntervalMs,
                    matteGenerationMs: nil, compositeWriteMs: nil,
                    failureReason: reason)
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private struct CompositeOutcome {
        let outputPath: String
        let outputBytes: Int
        let capturedImageWidth: Int
        let capturedImageHeight: Int
        let matteWidth: Int
        let matteHeight: Int
        let matteGenerationMs: Double
        let compositeWriteMs: Double
        /// Always contains the raw composite first; extra modes follow in
        /// `CandidateMode.allCases` order, minus any that failed to write.
        let displayOrientationCandidates: [CandidateOutput]
        /// "<mode>: <reason>" entries joined by "; " for every candidate that
        /// could not be written; nil when all candidates were written.
        let displayOrientationCandidateFailure: String?
        let displayOrientationCandidatesWriteMs: Double
    }

    /// Display-orientation candidate modes. `raw` is the untouched ARFrame
    /// sensor-space composite (`outputPath`); every other case applies one
    /// CGImagePropertyOrientation to camera image and matte alike. Which case is
    /// the correct on-screen transform is decided by eye on device, never here.
    private enum CandidateMode: String, CaseIterable {
        case raw
        case left
        case right
        case leftMirrored
        case rightMirrored

        var orientation: CGImagePropertyOrientation? {
            switch self {
            case .raw:           return nil
            case .left:          return .left
            case .right:         return .right
            case .leftMirrored:  return .leftMirrored
            case .rightMirrored: return .rightMirrored
            }
        }
    }

    /// One written composite PNG (raw or display-oriented) plus its pixel size.
    private struct CandidateOutput {
        let mode: CandidateMode
        let path: String
        let bytes: Int
        let width: Int
        let height: Int

        var resultMap: [String: Any] {
            [
                "mode":   mode.rawValue,
                "path":   path,
                "bytes":  bytes,
                "width":  width,
                "height": height,
            ]
        }
    }

    /// Locked RND still-proof display selection per tracking configuration.
    /// `face` (front camera) → `.leftMirrored`, chosen by eye on device
    /// (2026-09-18): upright portrait with the natural selfie/front-camera
    /// mirror. `.right` remains the upright non-mirrored/export-style
    /// alternative and is deliberately not selected here. No selection exists
    /// for any other configuration (`world`, rear camera, stays unselected).
    /// Still-frame diagnostic display lock only; never a live green-screen
    /// production transform.
    private static func selectedDisplayMode(forTrackingConfiguration trackingConfiguration: String) -> CandidateMode? {
        switch trackingConfiguration {
        case "face": return .leftMirrored
        default:     return nil
        }
    }

    /// Resolved selected display candidate for one result map.
    private struct SelectedDisplayCandidate {
        let mode: CandidateMode?
        let candidate: CandidateOutput?
        /// nil exactly when `candidate` is non-nil; otherwise a clear reason.
        let failure: String?
    }

    /// Picks the locked display candidate for `trackingConfiguration` out of
    /// the already-written `candidates` without touching them. Never throws
    /// and never changes `pass`: a missing selection is reported through
    /// `failure`, matching the best-effort semantics of the candidate matrix.
    private static func resolveSelectedDisplayCandidate(pass: Bool,
                                                        trackingConfiguration: String,
                                                        candidates: [CandidateOutput],
                                                        candidateFailure: String?,
                                                        failureReason: String?) -> SelectedDisplayCandidate {
        let policyMode = selectedDisplayMode(forTrackingConfiguration: trackingConfiguration)
        guard pass else {
            return SelectedDisplayCandidate(mode: policyMode, candidate: nil,
                                            failure: "probe_failed: \(failureReason ?? "unknown")")
        }
        guard let mode = policyMode else {
            return SelectedDisplayCandidate(mode: nil, candidate: nil,
                                            failure: "no_selected_display_mode_for_tracking_configuration_\(trackingConfiguration)")
        }
        guard let candidate = candidates.first(where: { $0.mode == mode }) else {
            let detail = candidateFailure.map { "; candidateFailure=\($0)" } ?? ""
            return SelectedDisplayCandidate(mode: mode, candidate: nil,
                                            failure: "selected_display_candidate_not_written_\(mode.rawValue)\(detail)")
        }
        return SelectedDisplayCandidate(mode: mode, candidate: candidate, failure: nil)
    }

    /// Emits exactly one `IOS_ARKIT_MATTE_STILL_PROBE_SELECTED_DISPLAY_CANDIDATE`
    /// marker per result map: path/size when the selection exists, otherwise
    /// the failure reason.
    private static func logSelectedDisplayCandidate(_ selection: SelectedDisplayCandidate,
                                                    trackingConfiguration: String) {
        let modeText = selection.mode?.rawValue ?? "none"
        if let candidate = selection.candidate {
            NSLog("IOS_ARKIT_MATTE_STILL_PROBE_SELECTED_DISPLAY_CANDIDATE trackingConfiguration=\(trackingConfiguration) mode=\(modeText) path=\(candidate.path) bytes=\(candidate.bytes) width=\(candidate.width) height=\(candidate.height)")
        } else {
            NSLog("IOS_ARKIT_MATTE_STILL_PROBE_SELECTED_DISPLAY_CANDIDATE trackingConfiguration=\(trackingConfiguration) mode=\(modeText) reason=\(selection.failure ?? "unknown")")
        }
    }

    /// Generates a full-resolution ARMatteGenerator matte from `frame`, composites
    /// `frame.capturedImage` over solid teal using that matte, and writes the
    /// result as a PNG under NSTemporaryDirectory. Throws (never crashes, never
    /// silently substitutes the raw segmentation buffer) on any Metal, CoreImage,
    /// or I/O failure, or when the matte texture is not the single-channel
    /// `.r8Unorm` format this probe knows how to read, or when the matte's
    /// dimensions do not match `capturedImage` (the header promises `.full`
    /// resolution equals camera image resolution; a mismatch is treated as a
    /// diagnostic failure rather than risking a stretched/squashed composite).
    ///
    /// After the raw composite succeeds it additionally writes one PNG per
    /// non-raw `CandidateMode` from the same camera image and matte. Those are
    /// best-effort: a failed candidate is folded into
    /// `displayOrientationCandidateFailure` instead of being thrown.
    private static func generateMatteAndComposite(frame: ARFrame,
                                                   trackingConfiguration: String) throws -> CompositeOutcome {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw VGARKitPersonSegmentationMatteStillProbeError.compositionFailed("no_metal_device")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw VGARKitPersonSegmentationMatteStillProbeError.compositionFailed("no_metal_command_queue")
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw VGARKitPersonSegmentationMatteStillProbeError.compositionFailed("no_metal_command_buffer")
        }

        let matteGenerator = ARMatteGenerator(device: device, matteResolution: .full)
        let matteStart = CACurrentMediaTime()
        let matteTexture = matteGenerator.generateMatte(from: frame, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let matteGenerationMs = (CACurrentMediaTime() - matteStart) * 1000.0

        NSLog("IOS_ARKIT_MATTE_STILL_PROBE_MATTE trackingConfiguration=\(trackingConfiguration) matteGenerationMs=\(matteGenerationMs) matteWidth=\(matteTexture.width) matteHeight=\(matteTexture.height) pixelFormat=\(matteTexture.pixelFormat.rawValue)")

        guard matteTexture.pixelFormat == .r8Unorm else {
            throw VGARKitPersonSegmentationMatteStillProbeError.compositionFailed(
                "unexpected_matte_pixel_format_\(matteTexture.pixelFormat.rawValue)")
        }

        let capturedImage = frame.capturedImage
        let capturedImageWidth = CVPixelBufferGetWidth(capturedImage)
        let capturedImageHeight = CVPixelBufferGetHeight(capturedImage)

        guard matteTexture.width == capturedImageWidth, matteTexture.height == capturedImageHeight else {
            throw VGARKitPersonSegmentationMatteStillProbeError.compositionFailed(
                "matte_dimension_mismatch_\(matteTexture.width)x\(matteTexture.height)_capturedImage_\(capturedImageWidth)x\(capturedImageHeight)")
        }

        let compositeStart = CACurrentMediaTime()
        let matteBuffer = try matteTexturePixelBuffer(matteTexture)

        let canvasRect = CGRect(x: 0, y: 0, width: capturedImageWidth, height: capturedImageHeight)
        let cameraImage = CIImage(cvPixelBuffer: capturedImage)
        let maskImage = CIImage(cvPixelBuffer: matteBuffer)

        // Raw sensor-space composite (`outputPath`): unchanged behaviour and
        // unchanged fail-closed semantics — any failure here fails the probe.
        let rawOutput = try writeCompositePNG(cameraImage: cameraImage,
                                              maskImage: maskImage,
                                              canvasRect: canvasRect,
                                              mode: .raw)
        let compositeWriteMs = (CACurrentMediaTime() - compositeStart) * 1000.0

        NSLog("IOS_ARKIT_MATTE_STILL_PROBE_WRITE trackingConfiguration=\(trackingConfiguration) path=\(rawOutput.path) bytes=\(rawOutput.bytes) compositeWriteMs=\(compositeWriteMs)")

        // Display-orientation candidates: same camera image, same matte, one
        // identical orientation applied to both before blending. Best-effort —
        // a candidate that cannot be written is recorded, never thrown, because
        // the raw composite above has already succeeded.
        let candidatesStart = CACurrentMediaTime()
        var candidates: [CandidateOutput] = [rawOutput]
        var candidateFailures: [String] = []
        for mode in CandidateMode.allCases {
            guard let orientation = mode.orientation else { continue }   // .raw already written
            do {
                let orientedCamera = orientedNormalizedCIImage(cameraImage, orientation: orientation)
                let orientedMask   = orientedNormalizedCIImage(maskImage, orientation: orientation)
                let candidate = try writeCompositePNG(cameraImage: orientedCamera,
                                                      maskImage: orientedMask,
                                                      canvasRect: orientedCamera.extent.integral,
                                                      mode: mode)
                candidates.append(candidate)
                NSLog("IOS_ARKIT_MATTE_STILL_PROBE_DISPLAY_CANDIDATE trackingConfiguration=\(trackingConfiguration) mode=\(mode.rawValue) path=\(candidate.path) bytes=\(candidate.bytes) width=\(candidate.width) height=\(candidate.height)")
            } catch {
                let reason = (error as? VGARKitPersonSegmentationMatteStillProbeError)?.errorDescription
                    ?? error.localizedDescription
                candidateFailures.append("\(mode.rawValue): \(reason)")
                NSLog("IOS_ARKIT_MATTE_STILL_PROBE_DISPLAY_CANDIDATE_FAIL trackingConfiguration=\(trackingConfiguration) mode=\(mode.rawValue) reason=\(reason)")
            }
        }
        let displayOrientationCandidatesWriteMs = (CACurrentMediaTime() - candidatesStart) * 1000.0

        return CompositeOutcome(
            outputPath: rawOutput.path,
            outputBytes: rawOutput.bytes,
            capturedImageWidth: capturedImageWidth,
            capturedImageHeight: capturedImageHeight,
            matteWidth: matteTexture.width,
            matteHeight: matteTexture.height,
            matteGenerationMs: matteGenerationMs,
            compositeWriteMs: compositeWriteMs,
            displayOrientationCandidates: candidates,
            displayOrientationCandidateFailure: candidateFailures.isEmpty ? nil : candidateFailures.joined(separator: "; "),
            displayOrientationCandidatesWriteMs: displayOrientationCandidatesWriteMs)
    }

    /// Applies `orientation` to `image` and translates the result so its extent
    /// origin is exactly (0,0). Called with the same orientation for both the
    /// camera image and the matte of one candidate, so they receive the identical
    /// transform and stay pixel-aligned; the caller crops to the returned extent.
    private static func orientedNormalizedCIImage(_ image: CIImage,
                                                  orientation: CGImagePropertyOrientation) -> CIImage {
        let oriented = image.oriented(orientation)
        let extent = oriented.extent
        guard extent.origin != .zero else { return oriented }
        return oriented.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                          y: -extent.origin.y))
    }

    /// Blends `cameraImage` over solid teal through `maskImage` (CIBlendWithMask),
    /// crops to `canvasRect`, encodes as PNG, and writes it to a unique path under
    /// NSTemporaryDirectory. Both inputs must already share `canvasRect` as their
    /// origin-(0,0) extent: the raw path passes CVPixelBuffer-derived images
    /// straight through, candidates pass `orientedNormalizedCIImage` outputs. A
    /// mask/camera extent mismatch throws rather than risking a misaligned blend.
    private static func writeCompositePNG(cameraImage: CIImage,
                                          maskImage: CIImage,
                                          canvasRect: CGRect,
                                          mode: CandidateMode) throws -> CandidateOutput {
        guard canvasRect.origin == .zero, canvasRect.width >= 1, canvasRect.height >= 1 else {
            throw VGARKitPersonSegmentationMatteStillProbeError.compositionFailed(
                "invalid_canvas_\(mode.rawValue)_\(Int(canvasRect.origin.x)),\(Int(canvasRect.origin.y))_\(Int(canvasRect.width))x\(Int(canvasRect.height))")
        }
        guard cameraImage.extent.integral == canvasRect, maskImage.extent.integral == canvasRect else {
            throw VGARKitPersonSegmentationMatteStillProbeError.compositionFailed(
                "extent_mismatch_\(mode.rawValue)_camera_\(Int(cameraImage.extent.width))x\(Int(cameraImage.extent.height))_mask_\(Int(maskImage.extent.width))x\(Int(maskImage.extent.height))_canvas_\(Int(canvasRect.width))x\(Int(canvasRect.height))")
        }

        let backgroundImage = CIImage(color: tealColor).cropped(to: canvasRect)
        let params: [String: Any] = [
            "inputImage":           cameraImage,
            "inputBackgroundImage": backgroundImage,
            "inputMaskImage":       maskImage,
        ]
        guard let blended = CIFilter(name: "CIBlendWithMask", parameters: params)?.outputImage else {
            throw VGARKitPersonSegmentationMatteStillProbeError.compositionFailed("blend_filter_unavailable_\(mode.rawValue)")
        }
        let composited = blended.cropped(to: canvasRect)

        guard let cgImage = compositeCIContext.createCGImage(composited, from: canvasRect) else {
            throw VGARKitPersonSegmentationMatteStillProbeError.compositionFailed("create_cgimage_failed_\(mode.rawValue)")
        }
        guard let pngData = UIImage(cgImage: cgImage).pngData() else {
            throw VGARKitPersonSegmentationMatteStillProbeError.compositionFailed("png_encode_failed_\(mode.rawValue)")
        }

        let outputURL = uniqueTemporaryPNGURL(mode: mode)
        do {
            try pngData.write(to: outputURL, options: .atomic)
        } catch {
            throw VGARKitPersonSegmentationMatteStillProbeError.ioError("write_failed_\(mode.rawValue): \(error.localizedDescription)")
        }

        return CandidateOutput(mode: mode,
                               path: outputURL.path,
                               bytes: pngData.count,
                               width: Int(canvasRect.width),
                               height: Int(canvasRect.height))
    }

    /// Copies an `.r8Unorm` matte MTLTexture into a `kCVPixelFormatType_OneComponent8`
    /// CVPixelBuffer so it can be handed to CIImage(cvPixelBuffer:) through the same
    /// grayscale-mask path VGDuetPreviewCompositor already uses for its own L8 masks,
    /// keeping the matte and camera image in the same CVPixelBuffer-derived CoreImage
    /// coordinate space (no Metal-texture-vs-CVPixelBuffer flip ambiguity).
    private static func matteTexturePixelBuffer(_ texture: MTLTexture) throws -> CVPixelBuffer {
        let width  = texture.width
        let height = texture.height
        var srcBytes = [UInt8](repeating: 0, count: width * height)
        srcBytes.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            texture.getBytes(base,
                             bytesPerRow: width,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:     Int(kCVPixelFormatType_OneComponent8),
            kCVPixelBufferWidthKey as String:               width,
            kCVPixelBufferHeightKey as String:              height,
            kCVPixelBufferMetalCompatibilityKey as String:  true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_OneComponent8,
                                         attributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw VGARKitPersonSegmentationMatteStillProbeError.compositionFailed(
                "matte_pixel_buffer_create_failed_\(status)")
        }

        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw VGARKitPersonSegmentationMatteStillProbeError.compositionFailed(
                "matte_pixel_buffer_lock_failed_\(lockStatus)")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(buffer) else {
            throw VGARKitPersonSegmentationMatteStillProbeError.compositionFailed(
                "matte_pixel_buffer_base_address_nil")
        }
        let dstRowStride = CVPixelBufferGetBytesPerRow(buffer)
        srcBytes.withUnsafeBytes { rawBufferPointer in
            guard let srcBase = rawBufferPointer.baseAddress else { return }
            for y in 0..<height {
                let srcRow = srcBase.advanced(by: y * width)
                let dstRow = dstBase.advanced(by: y * dstRowStride)
                memcpy(dstRow, srcRow, width)
            }
        }
        return buffer
    }

    /// Raw composite keeps the historical `vg_arkit_matte_still_probe_<ms>_<uuid>.png`
    /// name; display candidates append `_display_<mode>` so the five files of one
    /// run are trivially told apart when pulled off the device.
    private static func uniqueTemporaryPNGURL(mode: CandidateMode) -> URL {
        let stem = "vg_arkit_matte_still_probe_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString)"
        let filename = mode == .raw ? "\(stem).png" : "\(stem)_display_\(mode.rawValue).png"
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
    }

    // MARK: - Result

    private static func makeResult(pass: Bool,
                                   trackingConfiguration: String,
                                   activeTrackingUsesFrontCamera: Bool,
                                   outputPath: String?,
                                   outputBytes: Int,
                                   frameCount: Int,
                                   maskCount: Int,
                                   rawSegmentationBufferWidth: Int,
                                   rawSegmentationBufferHeight: Int,
                                   capturedImageWidth: Int,
                                   capturedImageHeight: Int,
                                   matteWidth: Int,
                                   matteHeight: Int,
                                   firstMaskLatencyMs: Double?,
                                   averageFrameIntervalMs: Double?,
                                   matteGenerationMs: Double?,
                                   compositeWriteMs: Double?,
                                   failureReason: String?,
                                   displayOrientationCandidates: [CandidateOutput] = [],
                                   displayOrientationCandidateFailure: String? = nil,
                                   displayOrientationCandidatesWriteMs: Double? = nil) -> [String: Any] {
        // Selection is derived from the already-written candidate list on every
        // result path (pass or fail) so the three selected* keys are always
        // present and the marker fires exactly once per result.
        let selection = resolveSelectedDisplayCandidate(
            pass: pass,
            trackingConfiguration: trackingConfiguration,
            candidates: displayOrientationCandidates,
            candidateFailure: displayOrientationCandidateFailure,
            failureReason: failureReason)
        logSelectedDisplayCandidate(selection, trackingConfiguration: trackingConfiguration)

        let claimsAllowed: [String] = [
            "Whether ARMatteGenerator(device:matteResolution: .full) can generate a full-resolution alpha matte MTLTexture from a real physical-device ARFrame captured via \(trackingConfiguration == "face" ? "ARFaceTrackingConfiguration (front camera)" : "ARWorldTrackingConfiguration (rear camera)") + .personSegmentation.",
            "The generated matte's pixel dimensions, checked against the captured camera image's own pixel dimensions before compositing (a mismatch fails the run rather than stretching/squashing).",
            "A single still PNG compositing the exact captured camera image over a solid teal background using that ARMatteGenerator matte — never the raw \(rawSegmentationBufferWidth)x\(rawSegmentationBufferHeight) ARFrame.segmentationBuffer — for direct visual inspection of matte quality and edge alignment.",
            "Coarse timing for matte generation and for the composite+PNG-write step on this device.",
            "Display-orientation candidate PNGs (`displayOrientationCandidates`, modes raw/left/right/leftMirrored/rightMirrored) rendered from the exact same captured camera image and the exact same ARMatteGenerator matte, applying one identical CGImagePropertyOrientation to camera and matte before blending, so the correct portrait/mirror display transform can be picked by eye on device.",
            "Which candidate is the locked RND still-proof display for this tracking configuration (`selectedDisplayOrientationMode` / `selectedDisplayOrientationCandidate`): `face` → `leftMirrored`, chosen on device 2026-09-18 as upright portrait with the natural front-camera/selfie mirror; `right` remains the upright non-mirrored/export-style alternative.",
        ]
        let nonClaims: [String] = [
            "Not a production integration proof: does not exercise VGLiveGreenScreenSessionCoordinator, Vision, LiteRT, or any live green-screen compositing path.",
            "Not a public Dart API; diagnostic-only RND still-image probe.",
            "Single still frame only: does not evaluate live/real-time matte generation performance or temporal stability across frames.",
            "`outputPath` PNG stays in raw ARFrame.capturedImage sensor orientation (not rotated to on-screen/UI orientation); the display-orientation candidates differ from it only by rotation/mirror, never by matte content.",
            "The selected display candidate is a still-frame RND display-orientation lock for this diagnostic harness only: it is not a live green-screen production preview or export transform, the full candidate matrix is still written for diagnostics, and a missing selection (`selectedDisplayOrientationCandidateFailure`) never flips `pass`.",
            "No automated pixel-quality assertion; visual inspection of the written PNG(s) is the proof.",
        ]
        return [
            "pass": pass,
            "proofBoundary": proofBoundary,
            "trackingConfiguration": trackingConfiguration,
            "activeTrackingUsesFrontCamera": activeTrackingUsesFrontCamera,
            "outputPath": outputPath.map { $0 as Any } ?? NSNull(),
            "outputBytes": outputBytes,
            "frameCount": frameCount,
            "maskCount": maskCount,
            "rawSegmentationBufferWidth": rawSegmentationBufferWidth,
            "rawSegmentationBufferHeight": rawSegmentationBufferHeight,
            "capturedImageWidth": capturedImageWidth,
            "capturedImageHeight": capturedImageHeight,
            "matteWidth": matteWidth,
            "matteHeight": matteHeight,
            "firstMaskLatencyMs": firstMaskLatencyMs.map { $0 as Any } ?? NSNull(),
            "averageFrameIntervalMs": averageFrameIntervalMs.map { $0 as Any } ?? NSNull(),
            "matteGenerationMs": matteGenerationMs.map { $0 as Any } ?? NSNull(),
            "compositeWriteMs": compositeWriteMs.map { $0 as Any } ?? NSNull(),
            "failureReason": failureReason.map { $0 as Any } ?? NSNull(),
            "displayOrientationCandidates": displayOrientationCandidates.map { $0.resultMap },
            "displayOrientationCandidateModes": displayOrientationCandidates.map { $0.mode.rawValue },
            "displayOrientationCandidateFailure": displayOrientationCandidateFailure.map { $0 as Any } ?? NSNull(),
            "displayOrientationCandidatesWriteMs": displayOrientationCandidatesWriteMs.map { $0 as Any } ?? NSNull(),
            "selectedDisplayOrientationMode": selection.mode.map { $0.rawValue as Any } ?? NSNull(),
            "selectedDisplayOrientationCandidate": selection.candidate.map { $0.resultMap as Any } ?? NSNull(),
            "selectedDisplayOrientationCandidateFailure": selection.failure.map { $0 as Any } ?? NSNull(),
            "claimsAllowed": claimsAllowed,
            "nonClaims": nonClaims,
        ]
    }
}

// MARK: - ARKit matte still probe frame capture driver (diagnostic-only)

/// Owns one throwaway ARSession for `VGARKitPersonSegmentationMatteStillProbe.run`.
/// Not part of any live green-screen session; never shared with
/// VGLiveGreenScreenSessionCoordinator. Collects frames until the first
/// non-nil `ARFrame.segmentationBuffer`, `maxFrameCount`, or `timeoutSeconds`,
/// pausing the session on every completion, failure, or timeout path, and
/// retains the winning `ARFrame` (strong reference) so matte generation can run
/// on it after capture stops. `completion` fires exactly once, on the main queue.
private final class ARMatteStillFrameCapture: NSObject, ARSessionDelegate {

    struct Outcome {
        let frame: ARFrame?
        let frameCount: Int
        let maskCount: Int
        let rawSegmentationBufferWidth: Int
        let rawSegmentationBufferHeight: Int
        let capturedImageWidth: Int
        let capturedImageHeight: Int
        let firstMaskLatencyMs: Double?
        let averageFrameIntervalMs: Double?
        let failureReason: String?
    }

    private let session = ARSession()
    private let configuration: ARConfiguration
    private let trackingConfiguration: String
    private let maxFrameCount: Int
    private let timeoutSeconds: Double
    private let completion: (Outcome) -> Void

    private let lock = NSLock()
    private var isFinished = false
    private var frameCount = 0
    private var maskCount = 0
    private var winningFrame: ARFrame?
    private var rawSegmentationBufferWidth = 0
    private var rawSegmentationBufferHeight = 0
    private var capturedImageWidth = 0
    private var capturedImageHeight = 0
    private var startTime: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval?
    private var frameIntervalSumMs: Double = 0
    private var frameIntervalCount = 0
    private var firstMaskLatencyMs: Double?

    init(configuration: ARConfiguration, trackingConfiguration: String, maxFrameCount: Int, timeoutSeconds: Double, completion: @escaping (Outcome) -> Void) {
        self.configuration = configuration
        self.trackingConfiguration = trackingConfiguration
        self.maxFrameCount = maxFrameCount
        self.timeoutSeconds = timeoutSeconds
        self.completion = completion
        super.init()
    }

    func start() {
        session.delegate = self
        startTime = CACurrentMediaTime()
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        // Strong `self` capture keeps this driver alive for its own worst-case
        // lifetime (ARSession.delegate is a weak reference); the closure runs
        // once and is then discarded, so this does not leak.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
            self.finish(failureReason: "timeout")
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        let now = CACurrentMediaTime()
        if let last = lastFrameTime {
            frameIntervalSumMs += (now - last) * 1000.0
            frameIntervalCount += 1
        }
        lastFrameTime = now

        frameCount += 1
        capturedImageWidth = CVPixelBufferGetWidth(frame.capturedImage)
        capturedImageHeight = CVPixelBufferGetHeight(frame.capturedImage)

        if let mask = frame.segmentationBuffer {
            maskCount += 1
            rawSegmentationBufferWidth = CVPixelBufferGetWidth(mask)
            rawSegmentationBufferHeight = CVPixelBufferGetHeight(mask)
            winningFrame = frame
            if firstMaskLatencyMs == nil {
                let latencyMs = (now - startTime) * 1000.0
                firstMaskLatencyMs = latencyMs
                NSLog("IOS_ARKIT_MATTE_STILL_PROBE_FIRST_MASK trackingConfiguration=\(trackingConfiguration) latencyMs=\(latencyMs) width=\(rawSegmentationBufferWidth) height=\(rawSegmentationBufferHeight)")
            }
        }

        let shouldFinish = maskCount > 0 || frameCount >= maxFrameCount
        lock.unlock()

        if shouldFinish {
            finish(failureReason: maskCount > 0 ? nil : "max_frame_count_reached_without_mask")
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        finish(failureReason: "session_failed: \(error.localizedDescription)")
    }

    private func finish(failureReason: String?) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        isFinished = true
        let outcome = Outcome(
            frame: winningFrame,
            frameCount: frameCount,
            maskCount: maskCount,
            rawSegmentationBufferWidth: rawSegmentationBufferWidth,
            rawSegmentationBufferHeight: rawSegmentationBufferHeight,
            capturedImageWidth: capturedImageWidth,
            capturedImageHeight: capturedImageHeight,
            firstMaskLatencyMs: firstMaskLatencyMs,
            averageFrameIntervalMs: frameIntervalCount > 0 ? frameIntervalSumMs / Double(frameIntervalCount) : nil,
            failureReason: failureReason)
        lock.unlock()

        NSLog("IOS_ARKIT_MATTE_STILL_PROBE_STOP trackingConfiguration=\(trackingConfiguration) frameCount=\(outcome.frameCount) maskCount=\(outcome.maskCount) failureReason=\(outcome.failureReason ?? "none")")

        DispatchQueue.main.async {
            self.session.pause()
            self.completion(outcome)
        }
    }
}
