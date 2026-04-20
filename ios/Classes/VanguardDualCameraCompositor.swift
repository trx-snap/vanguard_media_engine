// VanguardDualCameraCompositor.swift
// Phase 3C: iOS-native replacement for FFmpegKit compositeDualCamera path.
//
// Architecture:
//
//   CompositorConfig              — lightweight value type carrying per-export config.
//                                   lifecycle: set by flattener, read by compositor.
//
//   VanguardDualCameraCompositor  — custom AVVideoCompositing (CIImage pipeline).
//                                   Config delivered via static pendingConfig
//                                   (approved fallback from Phase 3C refinement:
//                                    DualCameraInstruction/protocol cast approach
//                                    blocked by [NSValue] requiredSourceTrackIDs
//                                    type mismatch across SDK versions).
//
//   VanguardDualCameraFlattener   — orchestrates AVMutableComposition + export.
//                                   Geometry computed from AVAssetTrack metadata.
//                                   layerInstructions used for both tracks so
//                                   AVFoundation populates requiredSourceTrackIDs
//                                   automatically (custom compositor overrides
//                                   all rendering regardless of layerInstructions).
//
// Android: unchanged — continues using FFmpegKit for this operation.

import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Metal

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CompositorConfig
//
// Immutable value type. Set on VanguardDualCameraCompositor.pendingConfig by
// the flattener before creating the export session; cleared on completion.
// Static access is safe because story export is always serial.
// ─────────────────────────────────────────────────────────────────────────────

struct CompositorConfig {
    let backTrackID:      CMPersistentTrackID
    let frontTrackID:     CMPersistentTrackID
    let backOrientation:  CGImagePropertyOrientation
    let frontOrientation: CGImagePropertyOrientation
    let renderSize:       CGSize   // 1080 × 1920
    let pipRect:          CGRect   // bottom-right in CIImage Y-up space
    let cornerRadius:     CGFloat  // px within PiP dimensions
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - VanguardDualCameraCompositor
// ─────────────────────────────────────────────────────────────────────────────

final class VanguardDualCameraCompositor: NSObject, AVVideoCompositing {

    // ── Config delivery ───────────────────────────────────────────────────────
    // Set by the flattener before AVAssetExportSession creation, cleared after.
    // nonisolated(unsafe) suppresses Swift concurrency warnings; access is
    // guaranteed sequential by the story export serialisation on the caller side.
    nonisolated(unsafe) static var pendingConfig: CompositorConfig? = nil

    // Shared Metal-backed CIContext — thread-safe for concurrent frame renders.
    private static let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device,
                             options: [.workingColorSpace: NSNull()])
        }
        NSLog("[VanguardDual] MTLCreateSystemDefaultDevice nil — CPU CIContext fallback")
        return CIContext(options: [.workingColorSpace: NSNull()])
    }()

    // ── AVVideoCompositing pixel format requirements ───────────────────────────
    // Source: accept both YpCbCr (native camera clip) and BGRA (re-encoded clip).
    // Render output: BGRA (CIContext.render works best with linear BGRA).
    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA,
        ] as [Any]
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    // ── Per-instance state (set once in renderContextChanged, read-only after) ─

    private var backTrackID:      CMPersistentTrackID = kCMPersistentTrackID_Invalid
    private var frontTrackID:     CMPersistentTrackID = kCMPersistentTrackID_Invalid
    private var backOrientation:  CGImagePropertyOrientation = .up
    private var frontOrientation: CGImagePropertyOrientation = .up
    private var renderSize:       CGSize = .zero
    private var pipRect:          CGRect = .zero
    private var pipTranslate:     CGAffineTransform = .identity

    // Pre-computed once — geometry is fixed for the lifetime of one export.
    private var maskCI:    CIImage? = nil
    private var configured = false

    // ── AVVideoCompositing ────────────────────────────────────────────────────

    // iOS 26+ SDK renamed renderContextDidChange → renderContextChanged.
    // Implementing both so the compositor works on all deployment targets.

    // iOS 26+ requirement (iPhoneOS26.2.sdk)
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        _configure(from: newRenderContext)
    }

    // Pre-iOS 26 requirement (retained for backwards compatibility)
    func renderContextDidChange(_ renderContext: AVVideoCompositionRenderContext) {
        _configure(from: renderContext)
    }

    private func _configure(from renderCtx: AVVideoCompositionRenderContext) {
        guard let cfg = VanguardDualCameraCompositor.pendingConfig else {
            NSLog("[VanguardDual] _configure: no pendingConfig set — compositor will no-op")
            return
        }

        backTrackID      = cfg.backTrackID
        frontTrackID     = cfg.frontTrackID
        backOrientation  = cfg.backOrientation
        frontOrientation = cfg.frontOrientation
        renderSize       = cfg.renderSize
        pipRect          = cfg.pipRect
        pipTranslate     = CGAffineTransform(translationX: cfg.pipRect.minX,
                                              y:            cfg.pipRect.minY)

        // Pre-compute the corner mask once — geometry is constant per export.
        let maskExtent = CGRect(origin: .zero, size: cfg.pipRect.size)
        maskCI = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent":  CIVector(cgRect: maskExtent),
            "inputRadius":  cfg.cornerRadius,
            "inputColor":   CIColor.white,
        ])?.outputImage?.cropped(to: maskExtent)

        configured = true

        NSLog("[VanguardDual] _configure | renderSize=%.0f×%.0f | pipRect=(%.0f,%.0f,%.0f,%.0f) | cr=%.1f | mask=%@",
              renderSize.width, renderSize.height,
              pipRect.minX, pipRect.minY, pipRect.width, pipRect.height,
              cfg.cornerRadius,
              maskCI != nil ? "YES" : "NO")
    }

    // No per-frame clean-up needed for AVAssetExportSession.
    func cancelAllPendingVideoCompositionRequests() { }

    // ── Per-frame CIImage pipeline ────────────────────────────────────────────

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard configured else {
            request.finishCancelledRequest()
            return
        }

        guard let backBuf  = request.sourceFrame(byTrackID: backTrackID),
              let frontBuf = request.sourceFrame(byTrackID: frontTrackID) else {
            NSLog("[VanguardDual] startRequest: missing source frame at t=%.3f",
                  CMTimeGetSeconds(request.compositionTime))
            request.finishCancelledRequest()
            return
        }

        // A. CVPixelBuffer → CIImage
        let backRaw  = CIImage(cvPixelBuffer: backBuf)
        let frontRaw = CIImage(cvPixelBuffer: frontBuf)

        // B. Correct for device rotation stored in the AVAssetTrack.preferredTransform.
        //    normalised() ensures the extent origin is at (0,0) after oriented() rotation.
        let backOriented  = normalised(backRaw.oriented(backOrientation))
        let frontOriented = normalised(frontRaw.oriented(frontOrientation))

        // C. Scale back video to renderSize (fill-mode: scale-to-fill + center crop).
        //    Back cam may be 4K; the compositor receives raw decoded frames.
        let backScaled = fillCrop(backOriented, to: renderSize)

        // D. Scale front video to PiP dimensions (AR-preserving, computed by flattener).
        let scaleX = pipRect.width  / max(frontOriented.extent.width,  1)
        let scaleY = pipRect.height / max(frontOriented.extent.height, 1)
        let frontScaled = frontOriented
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // E. Rounded-corner alpha mask.
        //    CIBlendWithAlphaMask: pixels where mask.alpha=1 are kept, corners are transparent.
        let maskedPiP: CIImage
        if let mask = maskCI {
            maskedPiP = frontScaled.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputMaskImageKey:       mask,
                kCIInputBackgroundImageKey: CIImage.empty(),
            ])
        } else {
            maskedPiP = frontScaled // degraded fallback: no corner rounding
        }

        // F. Translate PiP to bottom-right position (CIImage Y-up: pipRect.minY from bottom).
        let positioned = maskedPiP.transformed(by: pipTranslate)

        // G. Composite: PiP (source) over back video (destination) — Porter–Duff SourceOver.
        let composited = positioned.composited(over: backScaled)

        // H. Render composite into the output pixel buffer for the export session.
        guard let outputBuf = request.renderContext.newPixelBuffer() else {
            request.finish(with: _err("renderContext.newPixelBuffer() returned nil"))
            return
        }
        Self.ciContext.render(
            composited,
            to:         outputBuf,
            bounds:     CGRect(origin: .zero, size: renderSize),
            colorSpace: nil
        )
        request.finish(withComposedVideoFrame: outputBuf)
    }

    // MARK: - Private helpers (pure, stateless)

    /// Moves a CIImage extent origin to (0,0). CIImage.oriented() can produce
    /// non-zero origins, particularly for 90-degree rotations in Y-up coords.
    private func normalised(_ ci: CIImage) -> CIImage {
        let o = ci.extent.origin
        guard o.x != 0 || o.y != 0 else { return ci }
        return ci.transformed(by: CGAffineTransform(translationX: -o.x, y: -o.y))
    }

    /// Scale-and-center-crop to fill targetSize without distortion.
    /// Equivalent to FFmpeg: scale=W:H:force_original_aspect_ratio=increase, crop=W:H
    private func fillCrop(_ ci: CIImage, to target: CGSize) -> CIImage {
        let w = ci.extent.width, h = ci.extent.height
        guard w > 0, h > 0 else { return ci }
        let s  = max(target.width / w, target.height / h)
        let sw = w * s, sh = h * s
        return ci
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: (target.width  - sw) / 2,
                                                y:            (target.height - sh) / 2))
            .cropped(to: CGRect(origin: .zero, size: target))
    }

    private func _err(_ msg: String) -> NSError {
        NSError(domain: "VanguardDualCameraCompositor", code: -1,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - VanguardDualCameraFlattener
//
// Builds AVMutableComposition + AVMutableVideoComposition and drives
// AVAssetExportSession. All PiP geometry computed natively from AVAssetTrack
// (naturalSize + preferredTransform). No geometry args from Dart.
//
// Config handoff: sets VanguardDualCameraCompositor.pendingConfig before
// creating the export session, clears it in the completion handler.
// Safe because story export is always serial.
//
// layerInstructions: both tracks are included so AVFoundation populates
// AVMutableVideoCompositionInstruction.requiredSourceTrackIDs automatically.
// The custom compositor ignores the layer instruction rendering and does its
// own CIImage compositing.
//
// Product constants mirror story_export_service.dart (Android FFmpeg path).
// ─────────────────────────────────────────────────────────────────────────────

final class VanguardDualCameraFlattener {

    // ── Product constants ─────────────────────────────────────────────────────
    private static let kRenderSize:     CGSize   = CGSize(width: 1080, height: 1920)
    private static let kFPS:            Int32    = 30
    private static let kPipFraction:    CGFloat  = 0.35     // 35% of output width → PiP width
    private static let kMarginFraction: CGFloat  = 0.018   // ≈ 20px at 1080px output width
    private static let kCornerRadius:   CGFloat  = 24.0    // px within PiP pixel space
    private static let kMaxDuration:    Double   = 30.0    // seconds — matches product-wide 30s story cap

    // MARK: - Public API

    static func export(
        backPath:   String,
        frontPath:  String,
        outputPath: String,
        completion: @escaping (URL?, Error?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try _export(backPath: backPath, frontPath: frontPath, outputPath: outputPath)
                completion(URL(fileURLWithPath: outputPath), nil)
            } catch {
                NSLog("[VanguardDual] export error: %@", error.localizedDescription)
                VanguardDualCameraCompositor.pendingConfig = nil // ensure cleanup on error
                completion(nil, error)
            }
        }
    }

    // MARK: - Private pipeline

    private static func _export(
        backPath:   String,
        frontPath:  String,
        outputPath: String
    ) throws {

        let outputURL = URL(fileURLWithPath: outputPath)
        if FileManager.default.fileExists(atPath: outputPath) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let backAsset  = AVURLAsset(url: URL(fileURLWithPath: backPath),
                                    options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let frontAsset = AVURLAsset(url: URL(fileURLWithPath: frontPath),
                                    options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

        guard let backVTrack  = backAsset.tracks(withMediaType: .video).first  else {
            throw _err("No video track in back clip: \(backPath)")
        }
        guard let frontVTrack = frontAsset.tracks(withMediaType: .video).first else {
            throw _err("No video track in front clip: \(frontPath)")
        }

        // ── Orientation (correct for AVAssetTrack.preferredTransform) ─────────
        let backOri  = _orientation(from: backVTrack.preferredTransform)
        let frontOri = _orientation(from: frontVTrack.preferredTransform)

        // ── Display dimensions (post-transform, abs handles negative rotation) ─
        let backNat  = backVTrack.naturalSize,  backT  = backVTrack.preferredTransform
        let frontNat = frontVTrack.naturalSize, frontT = frontVTrack.preferredTransform

        let backDispW  = abs(backNat.applying(backT).width)
        let backDispH  = abs(backNat.applying(backT).height)
        let frontDispW = abs(frontNat.applying(frontT).width)
        let frontDispH = abs(frontNat.applying(frontT).height)

        guard backDispW > 0.1, backDispH > 0.1,
              frontDispW > 0.1, frontDispH > 0.1 else {
            throw _err("Degenerate display size back:\(backDispW)×\(backDispH) front:\(frontDispW)×\(frontDispH)")
        }

        NSLog("[VanguardDual] back disp=%.0f×%.0f ori=%d | front disp=%.0f×%.0f ori=%d",
              backDispW, backDispH, backOri.rawValue,
              frontDispW, frontDispH, frontOri.rawValue)

        // ── PiP geometry (mirrors Dart Android path constants) ────────────────
        let outW   = kRenderSize.width
        let pipW   = (outW * kPipFraction / 2).rounded(.toNearestOrEven) * 2
        let pipH   = (pipW * frontDispH / frontDispW / 2).rounded(.toNearestOrEven) * 2
        let margin = (outW * kMarginFraction).rounded()

        // CIImage Y-up: margin from bottom = margin from minY, right edge = outW-pipW-margin
        let pipRect = CGRect(x: outW - pipW - margin, y: margin, width: pipW, height: pipH)

        NSLog("[VanguardDual] pipW=%.0f pipH=%.0f margin=%.0f | pipRect=(%.0f,%.0f,%.0f,%.0f)",
              pipW, pipH, margin, pipRect.minX, pipRect.minY, pipRect.width, pipRect.height)

        // ── Duration: shortest clip, capped at kMaxDuration ───────────────────
        let clipSec = min(min(CMTimeGetSeconds(backAsset.duration),
                              CMTimeGetSeconds(frontAsset.duration)), kMaxDuration)
        guard clipSec > 0.001 else { throw _err("Zero clip duration") }
        let clipRange = CMTimeRange(start: .zero,
                                    duration: CMTimeMakeWithSeconds(clipSec, preferredTimescale: 600))

        // ── AVMutableComposition ───────────────────────────────────────────────
        let comp = AVMutableComposition()

        guard let compBack = comp.addMutableTrack(withMediaType: .video,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw _err("Failed creating back video track") }
        try compBack.insertTimeRange(clipRange, of: backVTrack, at: .zero)

        guard let compFront = comp.addMutableTrack(withMediaType: .video,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw _err("Failed creating front video track") }
        try compFront.insertTimeRange(clipRange, of: frontVTrack, at: .zero)

        // Audio: back camera only (matches FFmpeg -map 0:a?)
        if let backAudio = backAsset.tracks(withMediaType: .audio).first,
           let compAudio = comp.addMutableTrack(withMediaType: .audio,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudio.insertTimeRange(clipRange, of: backAudio, at: .zero)
        }

        // ── Config → compositor (static, cleared on completion) ───────────────
        VanguardDualCameraCompositor.pendingConfig = CompositorConfig(
            backTrackID:      compBack.trackID,
            frontTrackID:     compFront.trackID,
            backOrientation:  backOri,
            frontOrientation: frontOri,
            renderSize:       kRenderSize,
            pipRect:          pipRect,
            cornerRadius:     kCornerRadius
        )

        // ── AVMutableVideoCompositionInstruction ───────────────────────────────
        // layerInstructions with BOTH tracks so AVFoundation populates
        // requiredSourceTrackIDs correctly and decodes both tracks per frame.
        // The custom compositor overrides all rendering regardless of the
        // (identity/default) layer instructions.
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = clipRange
        instruction.layerInstructions = [
            AVMutableVideoCompositionLayerInstruction(assetTrack: compBack),
            AVMutableVideoCompositionLayerInstruction(assetTrack: compFront),
        ]

        // ── AVMutableVideoComposition (custom compositor) ─────────────────────
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = VanguardDualCameraCompositor.self
        vc.renderSize    = kRenderSize
        vc.frameDuration = CMTime(value: 1, timescale: kFPS)
        vc.instructions  = [instruction]

        // ── Preset (HDR-aware, mirrors VanguardVideoFlattener pattern) ─────────
        let preset = _selectExportPreset(videoTrack: backVTrack)
        NSLog("[VanguardDual] export starting clipSec=%.2f preset=%@", clipSec, preset)

        guard let exporter = AVAssetExportSession(asset: comp, presetName: preset)
        else { throw _err("AVAssetExportSession unavailable for preset \(preset)") }

        exporter.outputURL                   = outputURL
        exporter.outputFileType              = .mp4
        exporter.videoComposition            = vc
        exporter.shouldOptimizeForNetworkUse = false
        exporter.timeRange                   = clipRange

        let sem = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { sem.signal() }
        sem.wait()

        VanguardDualCameraCompositor.pendingConfig = nil // always clear

        switch exporter.status {
        case .completed:
            NSLog("[VanguardDual] export success → %@", outputPath)
        case .failed:
            throw exporter.error ?? _err("Export failed (no error object)")
        case .cancelled:
            throw _err("Export cancelled")
        default:
            throw _err("Unexpected export status: \(exporter.status.rawValue)")
        }
    }

    // MARK: - Helpers

    /// Maps AVAssetTrack.preferredTransform to CGImagePropertyOrientation for CIImage.oriented(_:).
    /// The (a,b,c,d) components encode the 2D rotation/mirror; tx/ty are irrelevant.
    private static func _orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case ( 1,  0,  0,  1):  return .up
        case (-1,  0,  0, -1):  return .down
        case ( 0,  1, -1,  0):  return .right          // 90° CCW — common back-cam portrait
        case ( 0, -1,  1,  0):  return .left           // 90° CW  — common front-cam portrait
        case (-1,  0,  0,  1):  return .upMirrored
        case ( 1,  0,  0, -1):  return .downMirrored
        case ( 0,  1,  1,  0):  return .leftMirrored
        case ( 0, -1, -1,  0):  return .rightMirrored
        default:
            NSLog("[VanguardDual] unrecognised preferredTransform [%.2f,%.2f,%.2f,%.2f] → .up",
                  t.a, t.b, t.c, t.d)
            return .up
        }
    }

    /// Selects HEVC preset for HDR (BT.2020 primaries) source; H.264 otherwise.
    /// Mirrors VanguardExportSession._selectExportPreset and VanguardVideoFlattener.
    private static func _selectExportPreset(videoTrack: AVAssetTrack) -> String {
        for desc in videoTrack.formatDescriptions {
            let fmt = desc as! CMFormatDescription
            guard let p = CMFormatDescriptionGetExtension(
                fmt, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
            ) as? String else { continue }
            if p == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) {
                return AVAssetExportPresetHEVC1920x1080
            }
        }
        return AVAssetExportPreset1920x1080
    }

    private static func _err(_ msg: String) -> NSError {
        NSError(domain: "VanguardDualCameraFlattener", code: -1,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
