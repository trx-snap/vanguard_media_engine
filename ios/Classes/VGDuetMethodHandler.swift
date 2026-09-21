// VGDuetMethodHandler.swift
// VG-DUET-SLICE-2/4A: Thin dispatch layer from VanguardMediaEnginePlugin to VGDuetNativeSessionCoordinator.
//
// Owns the MethodChannel route names for Duet (session + texture + diagnostic routes).
// Plugin is a thin router only — all session logic lives in VGDuetNativeSessionCoordinator.

import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import Foundation

/// Thin dispatch handler for all Duet MethodChannel routes.
/// Plugin owns one instance and calls `handle` for routes `ownsMethod` returns true for.
/// All methods execute on the main thread (guaranteed by Flutter plugin architecture).
final class VGDuetMethodHandler {

    // MARK: - Owned routes

    private static let ownedMethods: Set<String> = [
        "initializeDuetSession",
        "updateDuetLayout",
        "setDuetRecordingSpeed",
        "setDuetAudioMixGains",
        "startDuetRecording",
        "pauseDuetRecording",
        "resumeDuetRecording",
        "deleteLastDuetSegment",
        "stopDuetRecording",
        "disposeDuetSession",
        // Slice 4A: preview texture lifecycle
        "attachDuetPreviewTexture",
        "detachDuetPreviewTexture",
        // Diagnostic-only: deterministic CoreImage matte-blend pixel proof.
        "runIosDuetPixelProof",
        // Slice 5B-A: descriptor-bound offline export (no sessionId required).
        "exportDuetComposition",
        // Diagnostic-only: export foreground-transform rotation decoded-pixel
        // proof (IOS-DUET-EXPORT-TRANSFORM-PIXEL-PROOF). Routed directly to
        // VGDuetExportTransformPixelProofDiagnostics, never through generic
        // green-screen export production/diagnostic code.
        "assertIosDuetExportTransformPixelProofOutput",
        // Diagnostic-only: live preview source-continuity telemetry snapshot.
        "getIosDuetPreviewContinuityDiagnostics",
    ]

    static func ownsMethod(_ method: String) -> Bool {
        return ownedMethods.contains(method)
    }

    // MARK: - Coordinator

    private let coordinator: VGDuetNativeSessionCoordinator

    // MARK: - Slice 5B-A: Export session

    /// Descriptor-bound offline export lifecycle. Router only — no session id.
    private let exportSession = VGDuetExportSession()

    /// Export foreground-transform rotation decoded-pixel proof diagnostic
    /// coordinator. Router only — no session id; diagnostic-only, no
    /// production behavior.
    private let exportTransformPixelProofDiagnostics = VGDuetExportTransformPixelProofDiagnostics()

    // MARK: - Init

    /// Designated initializer.
    /// [textureRegistry] is passed down to the coordinator for Slice 4A texture allocation.
    /// [onDuetEvent] is passed down to the coordinator for `onDuetEvent` emission.
    init(textureRegistry: FlutterTextureRegistry? = nil,
         onDuetEvent: (([String: Any]) -> Void)? = nil) {
        coordinator = VGDuetNativeSessionCoordinator(textureRegistry: textureRegistry, onDuetEvent: onDuetEvent)
    }

    // MARK: - Dispatch

    func handle(method: String, args: [String: Any]?, result: @escaping FlutterResult) {
        switch method {

        case "initializeDuetSession":
            handleInitialize(args: args, result: result)

        case "updateDuetLayout":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            let layoutMap = args?["layoutConfig"] as? [String: Any] ?? [:]
            coordinator.updateLayout(sessionId: sid, layoutConfigMap: layoutMap) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "setDuetRecordingSpeed":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            let speed = (args?["speed"] as? NSNumber)?.doubleValue ?? 1.0
            coordinator.setRecordingSpeed(sessionId: sid, speed: speed) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "setDuetAudioMixGains":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            let sourceGain = (args?["sourceGain"] as? NSNumber)?.doubleValue ?? 1.0
            let micGain    = (args?["micGain"]    as? NSNumber)?.doubleValue ?? 1.0
            coordinator.setAudioMixGains(sessionId: sid, sourceGain: sourceGain, micGain: micGain) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "startDuetRecording":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            coordinator.startRecording(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "pauseDuetRecording":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            coordinator.pauseRecording(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "resumeDuetRecording":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            coordinator.resumeRecording(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "deleteLastDuetSegment":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            coordinator.deleteLastSegment(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "stopDuetRecording":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            coordinator.stopRecording(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "disposeDuetSession":
            let sid = args?["sessionId"] as? String ?? ""
            coordinator.disposeSession(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        // ── Slice 4A: preview texture ─────────────────────────────────────────

        case "attachDuetPreviewTexture":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            let canvasSizeMap = args?["canvasSize"] as? [String: Any]
                ?? ["width": 1080.0, "height": 1920.0]
            let layoutConfigMap = args?["layoutConfig"] as? [String: Any]
            coordinator.attachPreviewTexture(
                sessionId:       sid,
                canvasSize:      canvasSizeMap,
                layoutConfigMap: layoutConfigMap
            ) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "detachDuetPreviewTexture":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            coordinator.detachPreviewTexture(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        // ── Diagnostic-only: deterministic CoreImage matte-blend pixel proof ──────
        // Simulator-safe; synthetic buffers only. Never throws — always replies with
        // a fail-shaped map on any internal failure. See
        // VGDuetPreviewCompositor.runDeterministicPixelProof().
        case "runIosDuetPixelProof":
            result(VGDuetPreviewCompositor.runDeterministicPixelProof())

        // ── Slice 5B-A: descriptor-bound offline export ───────────────────────
        // No sessionId — route directly to VGDuetExportSession.
        case "exportDuetComposition":
            exportSession.export(args: args, result: result)

        // ── Diagnostic-only: export foreground-transform rotation pixel proof ──
        // No sessionId — routes directly to VGDuetExportTransformPixelProofDiagnostics,
        // never through generic green-screen export code. Never throws across
        // Flutter; always replies with a fail-shaped map on any internal failure.
        case "assertIosDuetExportTransformPixelProofOutput":
            exportTransformPixelProofDiagnostics.assertOutput(args: args, result: result)

        // ── Diagnostic-only: live preview source-continuity telemetry snapshot ──
        // Requires sessionId. Diagnostic-only; routes directly to coordinator.
        case "getIosDuetPreviewContinuityDiagnostics":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            coordinator.previewContinuityDiagnostics(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Teardown

    func disposeAll() {
        coordinator.disposeAll()
        exportSession.disposeAll()
        exportTransformPixelProofDiagnostics.disposeAll()
    }

    // MARK: - Helpers

    private func handleInitialize(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let sourceRaw  = args?["source"] as? [String: Any],
              let trimRaw    = args?["trimWindow"] as? [String: Any] else {
            result(FlutterError(
                code:    "source_invalid",
                message: "initializeDuetSession: missing required arguments 'source' and/or 'trimWindow'.",
                details: nil))
            return
        }

        let layoutMap   = args?["layoutConfig"] as? [String: Any] ?? ["mode": "pip"]
        let speed       = (args?["speed"]       as? NSNumber)?.doubleValue ?? 1.0
        let sourceGain  = (args?["sourceGain"]  as? NSNumber)?.doubleValue ?? 1.0
        let micGain     = (args?["micGain"]     as? NSNumber)?.doubleValue ?? 1.0

        coordinator.initializeSession(
            sourceMap:       sourceRaw,
            trimWindowMap:   trimRaw,
            layoutConfigMap: layoutMap,
            speed:           speed,
            sourceGain:      sourceGain,
            micGain:         micGain
        ) { sessionId, error in
            if let err = error {
                result(err)
            } else {
                result(sessionId)
            }
        }
    }

    private func requireSessionId(args: [String: Any]?, method: String, result: @escaping FlutterResult) -> String? {
        guard let sid = args?["sessionId"] as? String, !sid.isEmpty else {
            result(FlutterError(
                code:    "source_invalid",
                message: "\(method): missing required argument 'sessionId'.",
                details: nil))
            return nil
        }
        return sid
    }

    private func reply(result: @escaping FlutterResult, value: Any?, error: FlutterError?) {
        if let err = error {
            result(err)
        } else {
            result(value)
        }
    }
}

// MARK: - Export foreground-transform rotation pixel-proof diagnostics

// IOS-DUET-EXPORT-TRANSFORM-PIXEL-PROOF: diagnostic decoded-pixel proof that
// real public MethodChannel `exportDuetComposition` carries
// `foregroundTransform.rotationDegrees` into the produced MP4.
//
// Proof boundary: ios_duet_export_public_api_foreground_transform_rotation_pixel_proof
//
// Mirrors AndroidDuetExportTransformPixelProofSmokeCoordinator.kt's sample
// geometry, expected-magenta table, and gate names exactly (same target
// canvas 360x640, same four sample points, same isMagenta formula), so the
// two platforms' JSON payloads are directly comparable. Decoding technique
// differs by necessity (AVAssetReader vs MediaMetadataRetriever) but the
// pixel format decoded to (BGRA, raw byte read, row 0 = canvas top) and the
// classification logic are equivalent.
//
// Owned route: `assertIosDuetExportTransformPixelProofOutput`, dispatched
// from VGDuetMethodHandler directly to this class -- NEVER routed through
// VGGreenScreenExportMethodHandler / VGGreenScreenExportPixelProofDiagnostics
// (generic green-screen export diagnostic code), even though this class
// reuses that sibling's proven AVAssetReader decode technique as a pattern.
//
// Diagnostic only: decodes real files from disk but never touches live
// camera, ML matte quality, Android, or ConnectsApp UI/upload. Never throws
// across the Flutter boundary -- every failure path (missing/empty file,
// reader init/start failure, no samples, null image buffer, null base
// address) returns a fail-shaped map instead.
//
// Contained within this file (rather than its own
// VGDuetExportTransformPixelProofDiagnostics.swift) so the existing
// Xcode/Pods project compiles it without requiring CocoaPods project
// regeneration -- matching VGGreenScreenExportPixelProofDiagnostics's own
// placement inside VGGreenScreenExportMethodHandler.swift for the identical
// reason. See VGDuetExportTransformPixelProofDiagnostics.swift for the
// pointer to this definition; that file intentionally declares no symbols.

/// Diagnostic coordinator for the iOS Duet export foreground-transform
/// rotation decoded-pixel proof. VGDuetExportSession.swift /
/// VGDuetMethodHandler.swift own the production route and dispatch only;
/// this class owns zero production behavior.
final class VGDuetExportTransformPixelProofDiagnostics {

    static let proofBoundary = "ios_duet_export_public_api_foreground_transform_rotation_pixel_proof"

    private static let defaultWidth = 360
    private static let defaultHeight = 640
    private static let defaultFps = 30
    private static let defaultTolerance = 80

    private let queue = DispatchQueue(label: "com.connects.vanguard.duet.export.transform.pixelproof", qos: .userInitiated)
    private let lock = NSLock()
    private var disposed = false

    init() {}

    func disposeAll() {
        lock.lock()
        disposed = true
        lock.unlock()
    }

    // MARK: - Public entry point

    /// Handles the `assertIosDuetExportTransformPixelProofOutput` MethodChannel
    /// call. Decoding runs on a background queue; `result` is always invoked
    /// on the main thread with a `[String: Any]` map (`pass`/`reason`/gate
    /// booleans + per-rotation sample detail), never a FlutterError -- this
    /// route never throws across Flutter.
    func assertOutput(args: [String: Any]?, result: @escaping FlutterResult) {
        lock.lock()
        let isDisposed = disposed
        lock.unlock()
        if isDisposed {
            result(failShapedMap(reason: "coordinator_disposed"))
            return
        }

        guard let rotation0Path = args?["rotation0Path"] as? String,
              !rotation0Path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rotation90Path = args?["rotation90Path"] as? String,
              !rotation90Path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result(failShapedMap(reason: "invalid_arguments: rotation0Path and rotation90Path required"))
            return
        }

        let width = intValue(args?["width"]) ?? Self.defaultWidth
        let height = intValue(args?["height"]) ?? Self.defaultHeight
        let fps = intValue(args?["fps"]) ?? Self.defaultFps
        let tolerance = intValue(args?["tolerance"]) ?? Self.defaultTolerance

        queue.async { [weak self] in
            guard let self = self else { return }
            let outcome = self.decodeAndAssert(
                rotation0Path: rotation0Path,
                rotation90Path: rotation90Path,
                width: width,
                height: height,
                fps: fps,
                tolerance: tolerance
            )
            DispatchQueue.main.async {
                result(outcome)
            }
        }
    }

    // MARK: - Decode + assert

    private func decodeAndAssert(
        rotation0Path: String,
        rotation90Path: String,
        width: Int,
        height: Int,
        fps: Int,
        tolerance: Int
    ) -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rotation0Path),
              let attrs0 = try? fm.attributesOfItem(atPath: rotation0Path),
              ((attrs0[.size] as? NSNumber)?.int64Value ?? 0) > 0 else {
            return failShapedMap(reason: "rotation0_file_missing_or_empty:\(rotation0Path)")
        }
        guard fm.fileExists(atPath: rotation90Path),
              let attrs90 = try? fm.attributesOfItem(atPath: rotation90Path),
              ((attrs90[.size] as? NSNumber)?.int64Value ?? 0) > 0 else {
            return failShapedMap(reason: "rotation90_file_missing_or_empty:\(rotation90Path)")
        }

        guard let buffer0 = decodeMidFrame(path: rotation0Path, fps: fps) else {
            return failShapedMap(reason: "rotation0_decode_failed_null_frame")
        }
        guard let buffer90 = decodeMidFrame(path: rotation90Path, fps: fps) else {
            return failShapedMap(reason: "rotation90_decode_failed_null_frame")
        }

        // Sample geometry mirrors AndroidDuetExportTransformPixelProofSmokeCoordinator.kt
        // exactly: scale 0.4, centred anchor, zero offset foreground rect on a
        // 360x640 canvas. "center" sits inside the rect regardless of rotation
        // (rotation pivots about the centre); "rightArm"/"lowerArm" sit outside
        // the narrow un-rotated rect but inside the rotated (now-wide) rect, or
        // vice versa, so a real rotationDegrees=90 must flip their classification
        // relative to rotationDegrees=0; "farCorner" is always background.
        let center0 = sampleAndClassify("center", x: 180, y: 320, buffer: buffer0, targetWidth: width, targetHeight: height, expectedMagenta: true, tolerance: tolerance)
        let rightArm0 = sampleAndClassify("rightArm", x: 290, y: 320, buffer: buffer0, targetWidth: width, targetHeight: height, expectedMagenta: false, tolerance: tolerance)
        let lowerArm0 = sampleAndClassify("lowerArm", x: 180, y: 430, buffer: buffer0, targetWidth: width, targetHeight: height, expectedMagenta: true, tolerance: tolerance)
        let farCorner0 = sampleAndClassify("farCorner", x: 20, y: 20, buffer: buffer0, targetWidth: width, targetHeight: height, expectedMagenta: false, tolerance: tolerance)

        let center90 = sampleAndClassify("center", x: 180, y: 320, buffer: buffer90, targetWidth: width, targetHeight: height, expectedMagenta: true, tolerance: tolerance)
        let rightArm90 = sampleAndClassify("rightArm", x: 290, y: 320, buffer: buffer90, targetWidth: width, targetHeight: height, expectedMagenta: true, tolerance: tolerance)
        let lowerArm90 = sampleAndClassify("lowerArm", x: 180, y: 430, buffer: buffer90, targetWidth: width, targetHeight: height, expectedMagenta: false, tolerance: tolerance)
        let farCorner90 = sampleAndClassify("farCorner", x: 20, y: 20, buffer: buffer90, targetWidth: width, targetHeight: height, expectedMagenta: false, tolerance: tolerance)

        let centerOverlayOk = boolPass(center0) && boolPass(center90)
        let rightArmRotationDifferentiatesOk = boolPass(rightArm0) && boolPass(rightArm90)
        let lowerArmRotationDifferentiatesOk = boolPass(lowerArm0) && boolPass(lowerArm90)
        let farCornerBackgroundOk = boolPass(farCorner0) && boolPass(farCorner90)

        let allPass = centerOverlayOk && rightArmRotationDifferentiatesOk
            && lowerArmRotationDifferentiatesOk && farCornerBackgroundOk

        var failureReasons: [String] = []
        if !centerOverlayOk {
            failureReasons.append("center_overlay_failed:rot0=\(isMagentaDescription(center0)),rot90=\(isMagentaDescription(center90))")
        }
        if !rightArmRotationDifferentiatesOk {
            failureReasons.append("right_arm_differentiation_failed:rot0=\(isMagentaDescription(rightArm0)),rot90=\(isMagentaDescription(rightArm90))")
        }
        if !lowerArmRotationDifferentiatesOk {
            failureReasons.append("lower_arm_differentiation_failed:rot0=\(isMagentaDescription(lowerArm0)),rot90=\(isMagentaDescription(lowerArm90))")
        }
        if !farCornerBackgroundOk {
            failureReasons.append("far_corner_background_failed:rot0=\(isMagentaDescription(farCorner0)),rot90=\(isMagentaDescription(farCorner90))")
        }
        let reason = allPass ? "pass" : failureReasons.joined(separator: ";")

        return [
            "pass": allPass,
            "reason": reason,
            "decodeOk": true,
            "centerOverlayOk": centerOverlayOk,
            "rightArmRotationDifferentiatesOk": rightArmRotationDifferentiatesOk,
            "lowerArmRotationDifferentiatesOk": lowerArmRotationDifferentiatesOk,
            "farCornerBackgroundOk": farCornerBackgroundOk,
            "tolerance": tolerance,
            "rotation0": [
                "center": center0,
                "rightArm": rightArm0,
                "lowerArm": lowerArm0,
                "farCorner": farCorner0,
            ],
            "rotation90": [
                "center": center90,
                "rightArm": rightArm90,
                "lowerArm": lowerArm90,
                "farCorner": farCorner90,
            ],
        ]
    }

    // MARK: - Decode

    /// Decodes the video track's frame closest to the clip's midpoint into a
    /// raw BGRA `CVPixelBuffer`, via `AVAssetReader` + `AVAssetReaderTrackOutput`
    /// (matching `VGGreenScreenExportPixelProofDiagnostics.decodeAndAssert`'s
    /// proven decode technique exactly -- no `AVAssetImageGenerator` / CoreImage
    /// roundtrip, so there is no ambiguity about an extra vertical flip: the
    /// decoded buffer's raw memory is read directly with row 0 = canvas top,
    /// the same convention `readRgb`/`readBGRAPixel` already use elsewhere in
    /// this codebase's diagnostics). This clip is a synthetic, from-scratch
    /// composited canvas render (via VGTimelineExportHelper), not a pass-through
    /// of device-camera footage, so no display-transform application is needed.
    private func decodeMidFrame(path: String, fps: Int) -> CVPixelBuffer? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path),
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            return nil
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else { return nil }
        reader.add(trackOutput)
        guard reader.startReading() else { return nil }

        var sampleBuffers: [CMSampleBuffer] = []
        while let sb = trackOutput.copyNextSampleBuffer() {
            sampleBuffers.append(sb)
        }
        guard !sampleBuffers.isEmpty else { return nil }

        let durationSeconds = CMTimeGetSeconds(asset.duration)
        if durationSeconds.isFinite, durationSeconds > 0 {
            let targetTime = durationSeconds / 2.0
            var best = sampleBuffers[0]
            var bestDiff = Double.infinity
            for sb in sampleBuffers {
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
                let diff = abs(pts - targetTime)
                if diff < bestDiff {
                    bestDiff = diff
                    best = sb
                }
            }
            return CMSampleBufferGetImageBuffer(best)
        }

        // Duration unavailable: fall back to the middle decoded sample by index
        // (mirrors the Kotlin coordinator's 3rd-frame fallback intent -- pick a
        // frame safely inside the clip rather than the first/last).
        let midIndex = sampleBuffers.count / 2
        return CMSampleBufferGetImageBuffer(sampleBuffers[midIndex])
    }

    // MARK: - Sample + classify

    private func sampleAndClassify(
        _ name: String,
        x: Int,
        y: Int,
        buffer: CVPixelBuffer,
        targetWidth: Int,
        targetHeight: Int,
        expectedMagenta: Bool,
        tolerance: Int
    ) -> [String: Any] {
        let bw = CVPixelBufferGetWidth(buffer)
        let bh = CVPixelBufferGetHeight(buffer)
        guard bw > 0, bh > 0, targetWidth > 0, targetHeight > 0 else {
            return [
                "name": name, "x": x, "y": y,
                "rgb": [0, 0, 0], "isMagenta": false,
                "expectedMagenta": expectedMagenta, "pass": false,
                "error": "invalid_buffer_or_target_dimensions",
            ]
        }
        let sx = min(max(0, x * bw / targetWidth), bw - 1)
        let sy = min(max(0, y * bh / targetHeight), bh - 1)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return [
                "name": name, "x": x, "y": y,
                "rgb": [0, 0, 0], "isMagenta": false,
                "expectedMagenta": expectedMagenta, "pass": false,
                "error": "pixel_buffer_base_address_unavailable",
            ]
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let row = base.advanced(by: sy * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        let b = Int(row[sx * 4 + 0])
        let g = Int(row[sx * 4 + 1])
        let r = Int(row[sx * 4 + 2])

        let isMag = isMagenta(r: r, g: g, b: b, tolerance: tolerance)
        let pass = (isMag == expectedMagenta)

        return [
            "name": name,
            "x": x,
            "y": y,
            "sampledX": sx,
            "sampledY": sy,
            "rgb": [r, g, b],
            "isMagenta": isMag,
            "expectedMagenta": expectedMagenta,
            "pass": pass,
        ]
    }

    /// Matches AndroidDuetExportTransformPixelProofSmokeCoordinator.kt's
    /// `isMagenta` exactly: the synthetic foreground overlay is
    /// RGB(255,20,147) (see VGDuetExportSession._generateMagentaPNG); the red
    /// fixture background is RGB(240,20,20) (see
    /// VGGreenScreenExportPixelProofDiagnostics.defaultForegroundRgb, reused
    /// here as the Duet source video fixture). High red, low green, and blue
    /// substantially above the red background's blue (~20) distinguishes them.
    private func isMagenta(r: Int, g: Int, b: Int, tolerance: Int) -> Bool {
        let minBlue = max(60, 147 - tolerance)
        return r >= 140 && g <= 100 && b >= minBlue
    }

    // MARK: - Helpers

    private func failShapedMap(reason: String) -> [String: Any] {
        return [
            "pass": false,
            "reason": reason,
            "decodeOk": false,
            "centerOverlayOk": false,
            "rightArmRotationDifferentiatesOk": false,
            "lowerArmRotationDifferentiatesOk": false,
            "farCornerBackgroundOk": false,
        ]
    }

    private func boolPass(_ sample: [String: Any]) -> Bool {
        return (sample["pass"] as? Bool) == true
    }

    private func isMagentaDescription(_ sample: [String: Any]) -> String {
        if let val = sample["isMagenta"] as? Bool { return val ? "true" : "false" }
        return "nil"
    }

    private func intValue(_ raw: Any?) -> Int? {
        guard let raw = raw, !(raw is NSNull) else { return nil }
        if let val = raw as? Int { return val }
        if let num = raw as? NSNumber { return num.intValue }
        return nil
    }
}
