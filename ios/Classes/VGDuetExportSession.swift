// VGDuetExportSession.swift
// VG-DUET-SLICE-5B-A: Descriptor-bound offline export for iOS.
//
// Owns the exportDuetComposition route lifecycle:
//   - Validates descriptor, source, output path, dimensions.
//   - Probes source duration via AVURLAsset.
//   - Generates a synthetic magenta PNG sticker overlay.
//   - Calls VGTimelineExportHelper.exportTimeline(withClips:...:canvas:overlays:audioSidecar:)
//     using a tmp output path, then atomically moves tmp → final on success.
//   - Real-take export (segmentAssets present): probes the recorded segment
//     duration, bounds the output to min(trim, segment), and muxes source
//     and/or mic audio through a VGAudioSidecarPlan (Slice 4A).
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

// MARK: - DuetExportAudioMix

/// Audio mix fields parsed from the Duet composition descriptor.
///
/// Consumed only by the real-take export path to decide which sidecar audio
/// tracks (source/original, mic/voiceover) are muxed and at what volume.
private struct DuetExportAudioMix {
    let sourceAudioGain:  Double
    let micAudioGain:     Double
    let sourceAudioMuted: Bool
    let micAudioMuted:    Bool
}

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
        let layoutMode = layoutConfigMap["mode"] as? String

        // Creator overlays (Slice 3): read as [[String: Any]] if present, else
        // empty. The zIndex effective-order policy is applied later in
        // _performExport, alongside the synthetic foreground overlay (or,
        // for a real-take export, the composited dual-video frame) it must
        // render above.
        let creatorOverlayDicts = descriptorMap["overlays"] as? [[String: Any]] ?? []

        // Audio mix fields (Slice 4A): consumed only by the real-take export
        // path to build the audio sidecar. Defaults match the Dart
        // VGDuetCompositionDescriptor.fromMap contract (gain 1.0, unmuted).
        // Non-finite gains degrade to 0.0 so they cannot reach the muxer.
        let rawSourceAudioGain = (descriptorMap["sourceAudioGain"] as? NSNumber)?.doubleValue ?? 1.0
        let rawMicAudioGain    = (descriptorMap["micAudioGain"]    as? NSNumber)?.doubleValue ?? 1.0
        let audioMix = DuetExportAudioMix(
            sourceAudioGain:  rawSourceAudioGain.isFinite ? rawSourceAudioGain : 0.0,
            micAudioGain:     rawMicAudioGain.isFinite    ? rawMicAudioGain    : 0.0,
            sourceAudioMuted: (descriptorMap["sourceAudioMuted"] as? NSNumber)?.boolValue ?? false,
            micAudioMuted:    (descriptorMap["micAudioMuted"]    as? NSNumber)?.boolValue ?? false
        )

        // ── Validate source file ──────────────────────────────────────────────

        let fm = FileManager.default
        guard fm.isReadableFile(atPath: sourcePath) else {
            result(FlutterError(
                code:    "source_invalid",
                message: "exportDuetComposition: source file is missing or not readable: \(sourcePath)",
                details: nil))
            return
        }

        // ── Parse and validate segmentAssets (Slice 4 Packet 1) ────────────────
        //
        // segmentAssets carries the locally recorded real-take segment for
        // opaque dual-camera export, composited via VGTimelineCompositorNode's
        // existing "dualCamera" clip path. Absent/empty segmentAssets preserves
        // the synthetic magenta-PNG export exactly as before (steps below are
        // skipped entirely in that case).
        let segmentAssetsRaw = args?["segmentAssets"] as? [String]
        var realSegmentPath: String? = nil
        if let segmentAssetsRaw = segmentAssetsRaw, !segmentAssetsRaw.isEmpty {
            guard segmentAssetsRaw.count == 1 else {
                result(FlutterError(
                    code:    "unsupported_export_feature",
                    message: "exportDuetComposition: multiple segmentAssets are not supported in this slice; exactly one real-take segment is required.",
                    details: nil))
                return
            }

            let candidatePath = segmentAssetsRaw[0]
            guard !candidatePath.isEmpty else {
                result(FlutterError(
                    code:    "source_invalid",
                    message: "exportDuetComposition: segmentAssets[0] is empty.",
                    details: nil))
                return
            }

            guard fm.isReadableFile(atPath: candidatePath) else {
                result(FlutterError(
                    code:    "source_invalid",
                    message: "exportDuetComposition: segment file is missing or not readable: \(candidatePath)",
                    details: nil))
                return
            }

            // pip, splitTopBottom, and splitLeftRight (Package A) are supported
            // by the real-take export path; greenScreen and any unrecognised
            // mode fail closed.
            guard layoutMode == "pip" || layoutMode == "splitTopBottom" || layoutMode == "splitLeftRight" else {
                result(FlutterError(
                    code:    "unsupported_export_feature",
                    message: "exportDuetComposition: real-take export only supports layoutConfig.mode 'pip', 'splitTopBottom', or 'splitLeftRight'; got \(layoutMode ?? "<nil>").",
                    details: nil))
                return
            }

            // Real-take offline export requires speed 1.0: source video speed
            // remapping and source audio time-stretching are not supported by
            // the offline export path in this slice. A non-1.0 initialSpeed
            // must fail closed rather than silently export at the wrong
            // speed/audio pitch.
            let initialSpeed = (descriptorMap["initialSpeed"] as? NSNumber)?.doubleValue ?? 1.0
            guard abs(initialSpeed - 1.0) < 0.0001 else {
                result(FlutterError(
                    code:    "unsupported_export_feature",
                    message: "exportDuetComposition: real-take export requires initialSpeed 1.0 (got \(initialSpeed)); source video speed remapping and source audio time-stretching are not supported for offline export in this slice.",
                    details: nil))
                return
            }

            // Duet does not expose a top/bottom swap for export in this slice
            // (the compositor's splitScreen path accepts a `swapped` flag,
            // but only splitLeftRight forwards one -- see the splitLayout
            // dictionaries built in _performExport); a top/bottom swap request
            // must keep failing closed rather than silently render the wrong
            // order.
            if layoutMode == "splitTopBottom" {
                let isTopBottomSwapped = (layoutConfigMap["isTopBottomSwapped"] as? NSNumber)?.boolValue ?? false
                guard !isTopBottomSwapped else {
                    result(FlutterError(
                        code:    "unsupported_export_feature",
                        message: "exportDuetComposition: isTopBottomSwapped is not supported by the export compositor in this slice.",
                        details: nil))
                    return
                }
            }

            realSegmentPath = candidatePath
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

        // ── Reject non-video green-screen backgrounds before starting export ──
        //
        // Export parity with Android: if mode is greenScreen and an explicit
        // greenScreenBackground is provided whose type is not "video", fail
        // before marking busy or allocating any resources. solidColor and image
        // backgrounds are preview/R&D-only; offline export requires the source
        // video background on both platforms (unsupported_export_feature).
        // Missing background, malformed background, or type "video" falls
        // through and preserves existing behavior.

        if layoutMode == "greenScreen" {
            if let bgMap = layoutConfigMap["greenScreenBackground"] as? [String: Any],
               let bgType = bgMap["type"] as? String,
               bgType != "video" {
                result(FlutterError(
                    code:    "unsupported_export_feature",
                    message: "exportDuetComposition: static/image green-screen backgrounds are preview-only; offline export requires source video background.",
                    details: nil))
                return
            }
        }

        // ── Mark busy and continue asynchronously ─────────────────────────────

        isBusy = true

        // Probe source duration on a background queue to avoid blocking main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self._performExport(
                sourcePath:          sourcePath,
                trimStart:           trimStart,
                trimEnd:             trimEnd,
                outputPath:          outputPath,
                outputParentPath:    outputParentPath,
                targetWidth:         targetWidth,
                targetHeight:        targetHeight,
                videoBitRate:        videoBitRate,
                layoutConfigMap:     layoutConfigMap,
                creatorOverlayDicts: creatorOverlayDicts,
                realSegmentPath:     realSegmentPath,
                audioMix:            audioMix,
                result:              result
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
        sourcePath:          String,
        trimStart:           Double,
        trimEnd:             Double,
        outputPath:          String,
        outputParentPath:    String,
        targetWidth:         Int,
        targetHeight:        Int,
        videoBitRate:        Int,
        layoutConfigMap:     [String: Any],
        creatorOverlayDicts: [[String: Any]],
        realSegmentPath:     String?,
        audioMix:            DuetExportAudioMix,
        result:              @escaping FlutterResult
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

        let fm = FileManager.default

        // ── Apply z-order policy to creator overlays ──────────────────────────
        //
        // The synthetic foreground (or, for a real-take export, the composited
        // dual-video frame) renders below the creator overlays, which must
        // render above it while preserving their relative order:
        //   effectiveZIndex = max(2, originalZIndex + 2), Int-overflow-safe.
        // Only zIndex is remapped -- rotation is left untouched, because
        // VGOverlayDescriptor.rotation is already radians and VGOverlayNode
        // expects radians (unlike the synthetic foreground's own
        // degrees-to-radians conversion below).
        let effectiveCreatorOverlayDicts = creatorOverlayDicts.map { dict -> [String: Any] in
            var copy = dict
            let rawZIndex = (dict["zIndex"] as? NSNumber)?.intValue ?? 0
            let safeSum = rawZIndex > Int.max - 2 ? Int.max : rawZIndex + 2
            copy["zIndex"] = max(2, safeSum)
            return copy
        }

        // pngPath is the synthetic foreground PNG's temp path (nil for a
        // real-take export, since no synthetic PNG is generated).
        let pngPath: String?
        let clipDicts: [[String: Any]]
        let overlayDicts: [[String: Any]]
        // Planned output duration: min(trim, recorded segment) for a real-take
        // export; trimDurationSec unchanged for the synthetic export.
        let exportDurationSec: Double
        // Audio sidecar: built only for a real-take export with at least one
        // audible track; nil otherwise (video-only helper behaviour).
        let audioSidecar: VGAudioSidecarPlan?

        if let realSegmentPath = realSegmentPath {
            // ── Real-take export (Slice 4 Packet 1) ─────────────────────────────
            //
            // No synthetic PNG or synthetic foreground overlay is generated.
            // The primary clip carries a "dualCamera" descriptor pointing at
            // the recorded segment; VGTimelineCompositorNode's existing
            // dualCamera path composites the two videos into a single frame.
            // Creator overlays render on top of that composited frame via the
            // existing zIndex remap above.
            //
            // layoutMode is guaranteed to be "pip", "splitTopBottom", or
            // "splitLeftRight" here — validated in export(args:result:) before
            // busy was marked.
            let layoutMode = layoutConfigMap["mode"] as? String

            // ── Probe recorded segment duration ─────────────────────────────────
            //
            // The recorded take is typically shorter than the source trim
            // window (the creator may stop early), so the export must be
            // bounded by min(trim, segment) rather than stretching the
            // secondary clip past its recorded content.
            let segmentAsset = AVURLAsset(
                url:     URL(fileURLWithPath: realSegmentPath),
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let segmentDurationSec = CMTimeGetSeconds(segmentAsset.duration)
            guard segmentDurationSec.isFinite, segmentDurationSec > 0 else {
                _finishWithError(
                    code:    "source_invalid",
                    message: "exportDuetComposition: recorded segment has no readable duration: \(realSegmentPath)",
                    result:  result)
                return
            }

            let effectiveExportDurationSec = min(trimDurationSec, segmentDurationSec)
            guard effectiveExportDurationSec.isFinite, effectiveExportDurationSec > 0 else {
                _finishWithError(
                    code:    "composition_failed",
                    message: "exportDuetComposition: effective real-take export duration is zero (trim \(trimDurationSec)s, segment \(segmentDurationSec)s).",
                    result:  result)
                return
            }
            let effectiveRealTrimEnd = trimStart + effectiveExportDurationSec

            var dualCameraDict: [String: Any] = [
                "secondaryClip": [
                    "id":               "duet_secondary",
                    "sourcePath":       realSegmentPath,
                    "mediaKind":        "video",
                    "startTimeSeconds": 0.0,
                    "durationSeconds":  effectiveExportDurationSec,
                    "trimStartSeconds": 0.0,
                    "trimEndSeconds":   effectiveExportDurationSec,
                    "speed":            1.0,
                ],
            ]

            if layoutMode == "splitTopBottom" {
                // Explicit direction/swapped so VGTimelineCompositorNode's split
                // path never depends on its own defaults for this route.
                dualCameraDict["layoutMode"] = "splitScreen"
                dualCameraDict["splitLayout"] = [
                    "splitRatio": 0.5,
                    "direction":  "topBottom",
                    "swapped":    false,
                ]
            } else if layoutMode == "splitLeftRight" {
                // Package A: 50/50 left/right bands. `isSideSwapped` is the Dart
                // VGDuetLayoutConfig wire key: false = source (primary) on the
                // left and the recorded take (secondary) on the right; true =
                // recorded take on the left. VGTimelineCompositorNode maps
                // `swapped` onto that primary/secondary band order.
                let isSideSwapped = (layoutConfigMap["isSideSwapped"] as? NSNumber)?.boolValue ?? false
                dualCameraDict["layoutMode"] = "splitScreen"
                dualCameraDict["splitLayout"] = [
                    "splitRatio": 0.5,
                    "direction":  "leftRight",
                    "swapped":    isSideSwapped,
                ]
            } else {
                let pipAnchor = (layoutConfigMap["pipAnchor"] as? String) ?? "bottomRight"
                dualCameraDict["layoutMode"] = "pip"
                // Conservative defaults matching VGTimelineCompositorNode's own
                // _VGTCNParsePiPLayout fallback values.
                dualCameraDict["pipLayout"] = [
                    "anchor":         pipAnchor,
                    "widthFraction":  0.35,
                    "marginFraction": 0.018,
                    "cornerRadius":   24.0,
                    "opacity":        1.0,
                ]
            }

            pngPath = nil
            clipDicts = [
                [
                    "id":               "duet_source",
                    "sourcePath":       sourcePath,
                    "mediaKind":        "video",
                    "startTimeSeconds": 0.0,
                    "durationSeconds":  effectiveExportDurationSec,
                    "trimStartSeconds": trimStart,
                    "trimEndSeconds":   effectiveRealTrimEnd,
                    "speed":            1.0,
                    "dualCamera":       dualCameraDict,
                ]
            ]
            overlayDicts = effectiveCreatorOverlayDicts
            exportDurationSec = effectiveExportDurationSec

            // ── Build audio sidecar (Slice 4A) ──────────────────────────────────
            //
            // Both tracks start at output time 0 and span the effective export
            // duration. The source track reads from trimStart in the source
            // file; the mic track is the recorded segment's own audio, which
            // already starts at the take's origin. Muted or effectively silent
            // tracks are omitted; if nothing remains, audioSidecar stays nil so
            // the helper performs its existing video-only export (intentional
            // silent output, not an error).
            var sidecarTracks: [[String: Any]] = []
            if !audioMix.sourceAudioMuted && audioMix.sourceAudioGain > 0.0001 {
                sidecarTracks.append([
                    "trackId":         "duet_source_audio",
                    "url":             sourcePath,
                    "startTime":       0.0,
                    "duration":        effectiveExportDurationSec,
                    "volume":          audioMix.sourceAudioGain,
                    "sourceTrimStart": trimStart,
                    "role":            "original",
                ])
            }
            if !audioMix.micAudioMuted && audioMix.micAudioGain > 0.0001 {
                sidecarTracks.append([
                    "trackId":         "duet_mic_audio",
                    "url":             realSegmentPath,
                    "startTime":       0.0,
                    "duration":        effectiveExportDurationSec,
                    "volume":          audioMix.micAudioGain,
                    "sourceTrimStart": 0.0,
                    "role":            "voiceover",
                ])
            }
            audioSidecar = sidecarTracks.isEmpty
                ? nil
                : VGAudioSidecarPlan(tracks:               sidecarTracks,
                                     volumeKeyframes:      nil,
                                     waveformCache:        nil,
                                     timeRemapAudioPolicy: nil)

        } else {
            // ── Synthetic export (unchanged from prior slices) ──────────────────

            // ── Parse foreground transform from layoutConfig ───────────────────
            let nativeTransform: NativeForegroundTransform? = _parseForegroundTransform(layoutConfigMap)

            // ── Compute foreground overlay rect ─────────────────────────────────
            let canvasW = CGFloat(targetWidth)
            let canvasH = CGFloat(targetHeight)
            let (_, overlayRect) = VGDuetLayoutGeometry.greenScreen(
                canvasWidth:  canvasW,
                canvasHeight: canvasH,
                transform:    nativeTransform
            )

            // ── Generate synthetic magenta foreground PNG ───────────────────────
            let pngWidth  = max(1, Int(overlayRect.width.rounded()))
            let pngHeight = max(1, Int(overlayRect.height.rounded()))

            // Determine temp PNG path under output parent.
            let pngName = "vg_duet_fg_\(UUID().uuidString).png"
            let generatedPngPath = (outputParentPath as NSString).appendingPathComponent(pngName)

            guard let pngData = _generateMagentaPNG(width: pngWidth, height: pngHeight) else {
                _finishWithError(
                    code:    "composition_failed",
                    message: "exportDuetComposition: failed to generate synthetic foreground PNG.",
                    result:  result)
                return
            }

            do {
                try pngData.write(to: URL(fileURLWithPath: generatedPngPath))
            } catch {
                _finishWithError(
                    code:    "composition_failed",
                    message: "exportDuetComposition: failed to write synthetic PNG: \(error.localizedDescription)",
                    result:  result)
                return
            }

            // ── Build clip descriptor dictionary ────────────────────────────────

            // One clip: the source video, trimmed to [trimStart, effectiveTrimEnd].
            // startTimeSeconds is the output timeline start (0); trimStart/End
            // define the source trim range; durationSeconds is the output clip duration.
            pngPath = generatedPngPath
            clipDicts = [
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

            // ── Build overlay descriptor dictionary ─────────────────────────────

            // VGOverlayDescriptor.rotation is RADIANS, clockwise-positive at the
            // descriptor level; VGOverlayNode negates it internally to correct
            // for CoreImage's counter-clockwise-positive convention, so a
            // positive value here already renders visually clockwise -- matching
            // NativeForegroundTransform.rotationDegrees' Dart/top-left
            // visual-clockwise contract with no extra sign flip needed. nil (no
            // foregroundTransform) or a non-finite/malformed rotationDegrees was
            // already sanitized to 0.0 inside _parseForegroundTransform, so this
            // conversion never needs its own nil/finite handling beyond the `?? 0.0`
            // for a nil nativeTransform.
            let overlayRotationRadians = Double(nativeTransform?.rotationDegrees ?? 0.0) * .pi / 180.0

            let overlayDict: [String: Any] = [
                "id":               "duet_synthetic_fg",
                "type":             "sticker",
                "startTimeSeconds": 0.0,
                "durationSeconds":  trimDurationSec,
                "translationX":     Double(overlayRect.origin.x),
                "translationY":     Double(overlayRect.origin.y),
                "width":            Double(overlayRect.width),
                "height":           Double(overlayRect.height),
                "rotation":         overlayRotationRadians,
                "scale":            1.0,
                "opacity":          1.0,
                "zIndex":           1,
                "assetPath":        generatedPngPath,
            ]

            overlayDicts = [overlayDict] + effectiveCreatorOverlayDicts
            exportDurationSec = trimDurationSec
            audioSidecar = nil
        }

        // ── Build tmp output path ─────────────────────────────────────────────

        let tmpOutputPath = outputPath + ".tmp"
        // Remove any stale tmp from a previous crashed export.
        if fm.fileExists(atPath: tmpOutputPath) {
            try? fm.removeItem(atPath: tmpOutputPath)
        }

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
            overlays:    overlayDicts,
            audioSidecar: audioSidecar
        ) { [weak self] success, _, duration, error in

            // Completion fires on VGExportScheduler background queue.
            // Marshal everything to main thread before calling FlutterResult.

            // Always clean up the synthetic PNG (if any) in all terminal paths.
            if let pngPath = pngPath, fm.fileExists(atPath: pngPath) {
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

                // Compute durationMs: prefer helper-reported duration; fall back
                // to the planned export duration (trim, or min(trim, segment)
                // for a real-take export).
                let resolvedDurationSec = (duration > 0) ? duration : exportDurationSec
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
