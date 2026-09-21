// VGDuetExportSession.swift
// VG-DUET-SLICE-5B-A: Descriptor-bound offline export for iOS.
//
// Owns the exportDuetComposition route lifecycle:
//   - Validates descriptor, source, output path, dimensions.
//   - Probes source duration via AVURLAsset.
//   - Generates a synthetic magenta PNG sticker overlay.
//   - Calls VGTimelineExportHelper.exportTimeline(withClips:...:canvas:overlays:)
//     using a tmp output path, then atomically moves tmp → final on success.
//   - Single-export-at-a-time guard (export_busy).
//   - disposeAll() prevents new exports; in-flight export may finish through
//     VGTimelineExportHelper but clears busy and cleans temp files in completion.
//
// Architecture contract:
//   - This file is the ONLY place that owns the export lifecycle.
//   - VGDuetMethodHandler is a thin router only (no lifecycle logic).
//   - VGTimelineExportHelper writes to the tmp path; this class moves to final.
//   - VGDuetLayoutGeometry.greenScreen(canvasWidth:canvasHeight:transform:)
//     provides the foreground overlay rect.

import AVFoundation
import Flutter
import Foundation
import UIKit

// MARK: - VGDuetExportSession

/// Manages descriptor-bound offline Duet composition export.
///
/// One instance is owned by VGDuetMethodHandler. All public methods are
/// called on the main thread (guaranteed by Flutter plugin architecture).
final class VGDuetExportSession {

    // MARK: - State

    /// True while an export is active; concurrent calls get `export_busy`.
    private var isBusy = false

    /// True after disposeAll() is called; new exports are rejected.
    private var isDisposed = false

    // MARK: - Init

    init() {}

    // MARK: - Public API

    /// Handles the `exportDuetComposition` MethodChannel call.
    ///
    /// Must be called on the main thread.
    func export(args: [String: Any]?, result: @escaping FlutterResult) {
        // Reject if disposed.
        if isDisposed {
            result(FlutterError(
                code:    "export_busy",
                message: "exportDuetComposition: session disposed.",
                details: nil))
            return
        }

        // Single-export-at-a-time guard.
        if isBusy {
            result(FlutterError(
                code:    "export_busy",
                message: "exportDuetComposition: another export is already active.",
                details: nil))
            return
        }

        // ── Parse required arguments ──────────────────────────────────────────

        guard let descriptorMap = args?["descriptor"] as? [String: Any] else {
            result(FlutterError(
                code:    "source_invalid",
                message: "exportDuetComposition: missing 'descriptor' argument.",
                details: nil))
            return
        }

        guard let outputPath = args?["outputPath"] as? String, !outputPath.isEmpty else {
            result(FlutterError(
                code:    "source_invalid",
                message: "exportDuetComposition: missing or empty 'outputPath'.",
                details: nil))
            return
        }

        let targetSizeMap = args?["targetSize"] as? [String: Any] ?? [:]
        let targetWidth   = (targetSizeMap["width"]  as? NSNumber)?.intValue  ?? 0
        let targetHeight  = (targetSizeMap["height"] as? NSNumber)?.intValue ?? 0

        guard targetWidth > 0, targetHeight > 0 else {
            result(FlutterError(
                code:    "source_invalid",
                message: "exportDuetComposition: targetSize must have positive width and height.",
                details: nil))
            return
        }

        let videoBitRate = (args?["videoBitRate"] as? NSNumber)?.intValue ?? 0
        guard videoBitRate > 0 else {
            result(FlutterError(
                code:    "source_invalid",
                message: "exportDuetComposition: videoBitRate must be > 0.",
                details: nil))
            return
        }

        // ── Parse descriptor sub-maps ─────────────────────────────────────────

        guard let sourceMap = descriptorMap["source"] as? [String: Any],
              let sourcePath = sourceMap["filePath"] as? String,
              !sourcePath.isEmpty else {
            result(FlutterError(
                code:    "source_invalid",
                message: "exportDuetComposition: descriptor.source.filePath is missing or empty.",
                details: nil))
            return
        }

        let trimWindowMap = descriptorMap["trimWindow"] as? [String: Any] ?? [:]
        let trimStart = (trimWindowMap["startSeconds"] as? NSNumber)?.doubleValue ?? 0.0
        let trimEnd   = (trimWindowMap["endSeconds"]   as? NSNumber)?.doubleValue ?? 0.0

        let layoutConfigMap = descriptorMap["layoutConfig"] as? [String: Any] ?? [:]

        // ── Validate source file ──────────────────────────────────────────────

        let fm = FileManager.default
        guard fm.isReadableFile(atPath: sourcePath) else {
            result(FlutterError(
                code:    "source_invalid",
                message: "exportDuetComposition: source file is missing or not readable: \(sourcePath)",
                details: nil))
            return
        }

        // ── Validate output parent is writable ────────────────────────────────

        let outputURL = URL(fileURLWithPath: outputPath)
        let outputParentPath = outputURL.deletingLastPathComponent().path

        // Create parent directory if it doesn't exist.
        if !fm.fileExists(atPath: outputParentPath) {
            do {
                try fm.createDirectory(atPath: outputParentPath,
                                       withIntermediateDirectories: true,
                                       attributes: nil)
            } catch {
                result(FlutterError(
                    code:    "composition_failed",
                    message: "exportDuetComposition: cannot create output directory: \(error.localizedDescription)",
                    details: nil))
                return
            }
        }

        guard fm.isWritableFile(atPath: outputParentPath) else {
            result(FlutterError(
                code:    "composition_failed",
                message: "exportDuetComposition: output directory is not writable: \(outputParentPath)",
                details: nil))
            return
        }

        // ── Validate final output does not already exist ──────────────────────

        if fm.fileExists(atPath: outputPath) {
            result(FlutterError(
                code:    "composition_failed",
                message: "exportDuetComposition: output file already exists at: \(outputPath)",
                details: nil))
            return
        }

        // ── Mark busy and continue asynchronously ─────────────────────────────

        isBusy = true

        // Probe source duration on a background queue to avoid blocking main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self._performExport(
                sourcePath:       sourcePath,
                trimStart:        trimStart,
                trimEnd:          trimEnd,
                outputPath:       outputPath,
                outputParentPath: outputParentPath,
                targetWidth:      targetWidth,
                targetHeight:     targetHeight,
                videoBitRate:     videoBitRate,
                layoutConfigMap:  layoutConfigMap,
                result:           result
            )
        }
    }

    /// Called by VGDuetMethodHandler.disposeAll().
    ///
    /// Prevents new exports. In-flight VGTimelineExportHelper work may complete
    /// but the completion handler will clear busy and clean temp files.
    func disposeAll() {
        isDisposed = true
    }

    // MARK: - Private: export pipeline

    private func _performExport(
        sourcePath:       String,
        trimStart:        Double,
        trimEnd:          Double,
        outputPath:       String,
        outputParentPath: String,
        targetWidth:      Int,
        targetHeight:     Int,
        videoBitRate:     Int,
        layoutConfigMap:  [String: Any],
        result:           @escaping FlutterResult
    ) {
        // ── Probe source asset duration ───────────────────────────────────────

        let sourceURL   = URL(fileURLWithPath: sourcePath)
        let sourceAsset = AVURLAsset(url: sourceURL,
                                     options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let sourceDurationSec = CMTimeGetSeconds(sourceAsset.duration)

        // Validate trim window.
        if trimEnd <= trimStart {
            _finishWithError(
                code:    "source_invalid",
                message: "exportDuetComposition: trimEnd (\(trimEnd)) must be > trimStart (\(trimStart)).",
                result:  result)
            return
        }

        // Clamp trim end to source duration (mirrors Android behaviour).
        let effectiveTrimEnd = (sourceDurationSec > 0)
            ? min(trimEnd, sourceDurationSec)
            : trimEnd
        if effectiveTrimEnd <= trimStart {
            _finishWithError(
                code:    "source_invalid",
                message: "exportDuetComposition: effective trim range is zero after clamping to source duration.",
                result:  result)
            return
        }
        let trimDurationSec = effectiveTrimEnd - trimStart

        // ── Parse foreground transform from layoutConfig ───────────────────────

        let nativeTransform: NativeForegroundTransform? = _parseForegroundTransform(layoutConfigMap)

        // ── Compute foreground overlay rect ───────────────────────────────────

        let canvasW = CGFloat(targetWidth)
        let canvasH = CGFloat(targetHeight)
        let (_, overlayRect) = VGDuetLayoutGeometry.greenScreen(
            canvasWidth:  canvasW,
            canvasHeight: canvasH,
            transform:    nativeTransform
        )

        // ── Generate synthetic magenta foreground PNG ─────────────────────────

        let pngWidth  = max(1, Int(overlayRect.width.rounded()))
        let pngHeight = max(1, Int(overlayRect.height.rounded()))

        // Determine temp PNG path under output parent.
        let fm = FileManager.default
        let pngName = "vg_duet_fg_\(UUID().uuidString).png"
        let pngPath = (outputParentPath as NSString).appendingPathComponent(pngName)

        guard let pngData = _generateMagentaPNG(width: pngWidth, height: pngHeight) else {
            _finishWithError(
                code:    "composition_failed",
                message: "exportDuetComposition: failed to generate synthetic foreground PNG.",
                result:  result)
            return
        }

        do {
            try pngData.write(to: URL(fileURLWithPath: pngPath))
        } catch {
            _finishWithError(
                code:    "composition_failed",
                message: "exportDuetComposition: failed to write synthetic PNG: \(error.localizedDescription)",
                result:  result)
            return
        }

        // ── Build tmp output path ─────────────────────────────────────────────

        let tmpOutputPath = outputPath + ".tmp"
        // Remove any stale tmp from a previous crashed export.
        if fm.fileExists(atPath: tmpOutputPath) {
            try? fm.removeItem(atPath: tmpOutputPath)
        }

        // ── Build clip descriptor dictionary ──────────────────────────────────

        // One clip: the source video, trimmed to [trimStart, effectiveTrimEnd].
        // startTimeSeconds is the output timeline start (0); trimStart/End
        // define the source trim range; durationSeconds is the output clip duration.
        let clipDicts: [[String: Any]] = [
            [
                "id":               "duet_source",
                "sourcePath":       sourcePath,
                "mediaKind":        "video",
                "startTimeSeconds": 0.0,
                "durationSeconds":  trimDurationSec,
                "trimStartSeconds": trimStart,
                "trimEndSeconds":   effectiveTrimEnd,
                "speed":            1.0,
            ]
        ]

        // ── Build overlay descriptor dictionary ───────────────────────────────

        let overlayDict: [String: Any] = [
            "id":               "duet_synthetic_fg",
            "type":             "sticker",
            "startTimeSeconds": 0.0,
            "durationSeconds":  trimDurationSec,
            "translationX":     Double(overlayRect.origin.x),
            "translationY":     Double(overlayRect.origin.y),
            "width":            Double(overlayRect.width),
            "height":           Double(overlayRect.height),
            "rotation":         0.0,
            "scale":            1.0,
            "opacity":          1.0,
            "zIndex":           1,
            "assetPath":        pngPath,
        ]
        let overlayDicts: [[String: Any]] = [overlayDict]

        // Canvas dictionary for VGOverlayNode.
        let canvasDict: [String: Any] = [
            "width":  targetWidth,
            "height": targetHeight,
        ]

        // ── Delegate to VGTimelineExportHelper ───────────────────────────────

        VGTimelineExportHelper.exportTimeline(
            withClips:   clipDicts,
            transitions: [],
            outputPath:  tmpOutputPath,
            width:       targetWidth,
            height:      targetHeight,
            fps:         30,
            bitrateBps:  videoBitRate,
            canvas:      canvasDict,
            overlays:    overlayDicts
        ) { [weak self] success, _, duration, error in

            // Completion fires on VGExportScheduler background queue.
            // Marshal everything to main thread before calling FlutterResult.

            // Always clean up PNG in all terminal paths.
            if fm.fileExists(atPath: pngPath) {
                try? fm.removeItem(atPath: pngPath)
            }

            if success {
                // Verify tmp file exists and is non-empty.
                guard fm.fileExists(atPath: tmpOutputPath) else {
                    DispatchQueue.main.async {
                        self?._clearBusy()
                        result(FlutterError(
                            code:    "composition_failed",
                            message: "exportDuetComposition: VGTimelineExportHelper reported success but tmp file is missing.",
                            details: nil))
                    }
                    return
                }

                let tmpAttributes = try? fm.attributesOfItem(atPath: tmpOutputPath)
                let tmpSize = (tmpAttributes?[.size] as? NSNumber)?.intValue ?? 0
                guard tmpSize > 0 else {
                    try? fm.removeItem(atPath: tmpOutputPath)
                    DispatchQueue.main.async {
                        self?._clearBusy()
                        result(FlutterError(
                            code:    "composition_failed",
                            message: "exportDuetComposition: exported tmp file is empty.",
                            details: nil))
                    }
                    return
                }

                // Atomic rename: tmp → final.
                do {
                    try fm.moveItem(atPath: tmpOutputPath, toPath: outputPath)
                } catch {
                    try? fm.removeItem(atPath: tmpOutputPath)
                    DispatchQueue.main.async {
                        self?._clearBusy()
                        result(FlutterError(
                            code:    "composition_failed",
                            message: "exportDuetComposition: failed to rename tmp to final: \(error.localizedDescription)",
                            details: nil))
                    }
                    return
                }

                // Verify final file.
                let finalAttributes = try? fm.attributesOfItem(atPath: outputPath)
                let finalSize = (finalAttributes?[.size] as? NSNumber)?.intValue ?? 0
                guard finalSize > 0 else {
                    try? fm.removeItem(atPath: outputPath)
                    DispatchQueue.main.async {
                        self?._clearBusy()
                        result(FlutterError(
                            code:    "composition_failed",
                            message: "exportDuetComposition: final file is empty after rename.",
                            details: nil))
                    }
                    return
                }

                // Compute durationMs: prefer helper-reported duration; fall back to trim.
                let resolvedDurationSec = (duration > 0) ? duration : trimDurationSec
                let durationMs = max(1, Int((resolvedDurationSec * 1000.0).rounded()))

                let successMap: [String: Any] = [
                    "outputPath":    outputPath,
                    "durationMs":    durationMs,
                    "fileSizeBytes": finalSize,
                ]

                DispatchQueue.main.async {
                    self?._clearBusy()
                    result(successMap)
                }

            } else {
                // Export failed — delete tmp if it exists.
                if fm.fileExists(atPath: tmpOutputPath) {
                    try? fm.removeItem(atPath: tmpOutputPath)
                }

                let msg = error?.localizedDescription ?? "VGTimelineExportHelper failed (unknown error)"
                DispatchQueue.main.async {
                    self?._clearBusy()
                    result(FlutterError(
                        code:    "composition_failed",
                        message: "exportDuetComposition: \(msg)",
                        details: nil))
                }
            }
        }
    }

    // MARK: - Private helpers

    /// Clears the busy flag. Called on the main thread from the completion handler.
    private func _clearBusy() {
        isBusy = false
    }

    /// Delivers a FlutterError and clears busy on the main thread.
    private func _finishWithError(code: String, message: String, result: @escaping FlutterResult) {
        DispatchQueue.main.async { [weak self] in
            self?._clearBusy()
            result(FlutterError(code: code, message: message, details: nil))
        }
    }

    /// Parses a `NativeForegroundTransform` from `layoutConfig` map.
    ///
    /// Looks for `foregroundTransform` sub-map with keys `scale`, `offset.x`,
    /// `offset.y`, `anchor.x`, `anchor.y`, `rotationDegrees` — matching the
    /// Dart serialization of `VGDuetForegroundTransform.toMap()`. Missing or
    /// wrong-type values default per-field (scale → 1.0, offset → 0.0,
    /// anchor → 0.5, rotationDegrees → 0.0, matching the Dart `fromMap`
    /// contract); non-finite or non-positive scale is left for
    /// `VGDuetLayoutGeometry.greenScreen(canvasWidth:canvasHeight:transform:)`
    /// to degrade to the full-canvas identity.
    private func _parseForegroundTransform(_ layoutConfigMap: [String: Any]) -> NativeForegroundTransform? {
        guard let fgMap = layoutConfigMap["foregroundTransform"] as? [String: Any] else {
            return nil
        }
        let scale      = (fgMap["scale"] as? NSNumber)?.doubleValue ?? 1.0
        let offsetMap  = fgMap["offset"] as? [String: Any]
        let anchorMap  = fgMap["anchor"] as? [String: Any]
        let rawOffsetX = (offsetMap?["x"] as? NSNumber)?.doubleValue ?? Double.nan
        let rawOffsetY = (offsetMap?["y"] as? NSNumber)?.doubleValue ?? Double.nan
        let rawAnchorX = (anchorMap?["x"] as? NSNumber)?.doubleValue ?? Double.nan
        let rawAnchorY = (anchorMap?["y"] as? NSNumber)?.doubleValue ?? Double.nan
        let offsetX = rawOffsetX.isFinite ? rawOffsetX : 0.0
        let offsetY = rawOffsetY.isFinite ? rawOffsetY : 0.0
        let anchorX = rawAnchorX.isFinite ? rawAnchorX : 0.5
        let anchorY = rawAnchorY.isFinite ? rawAnchorY : 0.5
        let rawRotation = (fgMap["rotationDegrees"] as? NSNumber)?.doubleValue ?? 0.0
        let rotationDegrees = rawRotation.isFinite ? rawRotation : 0.0
        return NativeForegroundTransform(
            scale:           CGFloat(scale),
            offsetX:         CGFloat(offsetX),
            offsetY:         CGFloat(offsetY),
            anchorX:         CGFloat(anchorX),
            anchorY:         CGFloat(anchorY),
            rotationDegrees: CGFloat(rotationDegrees)
        )
    }

    /// Generates a solid magenta PNG (RGB 255/20/147, alpha 255) of the given size.
    ///
    /// Uses UIGraphicsImageRenderer to avoid CoreGraphics color space pitfalls.
    /// Returns nil if rendering fails.
    private func _generateMagentaPNG(width: Int, height: Int) -> Data? {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            // Deep pink / hot magenta: R=255 G=20 B=147.
            UIColor(red: 255.0/255.0, green: 20.0/255.0, blue: 147.0/255.0, alpha: 1.0)
                .setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData()
    }
}
