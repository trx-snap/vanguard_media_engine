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
import CoreImage
import CoreMedia
import Flutter
import Foundation
import Metal
import UIKit
import Vision

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

            // pip, splitTopBottom, splitLeftRight (Package A) and greenScreen
            // are supported by the real-take export path; any unrecognised
            // mode fails closed.
            guard layoutMode == "pip" || layoutMode == "splitTopBottom" ||
                  layoutMode == "splitLeftRight" || layoutMode == "greenScreen" else {
                result(FlutterError(
                    code:    "unsupported_export_feature",
                    message: "exportDuetComposition: real-take export only supports layoutConfig.mode 'pip', 'splitTopBottom', 'splitLeftRight', or 'greenScreen'; got \(layoutMode ?? "<nil>").",
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
            // ── Real-take export (Slice 4 Packet 1 + greenScreen extension) ──────
            //
            // layoutMode is guaranteed to be "pip", "splitTopBottom",
            // "splitLeftRight", or "greenScreen" here — validated in
            // export(args:result:) before busy was marked.
            let layoutMode = layoutConfigMap["mode"] as? String

            // ── Probe recorded segment duration ─────────────────────────────────
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

            // ── Audio sidecar (shared for ALL real-take layoutModes) ─────────────
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
            let realTakeAudioSidecar: VGAudioSidecarPlan? = sidecarTracks.isEmpty
                ? nil
                : VGAudioSidecarPlan(tracks:               sidecarTracks,
                                     volumeKeyframes:      nil,
                                     waveformCache:        nil,
                                     timeRemapAudioPolicy: nil)

            // ── Green-screen real-take route ─────────────────────────────────────
            //
            // Uses VGDuetGreenScreenExportCompositor (Vision VNGeneratePersonSegmentation
            // Request Balanced) instead of the VGTimelineExportHelper dualCamera path.
            // The compositor writes the video-only composite to tmpOutputPath directly.
            // Audio is handled by the shared sidecar plan above which is re-muxed by
            // VGTimelineExportHelper with a video-only input in the clip dict.
            //
            // Temp path contract: both temps below are siblings of outputPath whose
            // FINAL extension is ".mp4". The video composite is fed back into
            // VGTimelineExportHelper as a source clip, and AVFoundation /
            // VGTimelineCompositorNode discover no video track behind a path ending
            // in ".mp4.tmp" (physical log: "no video track found in asset for clip
            // duet_gs_composite at ....mp4.tmp"). A per-export token keeps the temps
            // collision-safe across concurrent/retried exports of the same output.
            if layoutMode == "greenScreen" {
                // isPreComposited (VG-DUET-LIVE-GS): true when the recorded
                // segment was captured from the LIVE compositor's already-
                // composited preview frames (VGDuetNativeSessionCoordinator's
                // presentHandler + buildStopResult set this on the descriptor's
                // layoutConfig for a completed greenScreen take). The recorded
                // video already IS the final composited frame, so no offline
                // Vision re-composite is needed. False or missing (older /
                // replayed descriptors) falls back to the original
                // VGDuetGreenScreenExportCompositor route, unchanged.
                let isPreComposited = (layoutConfigMap["isPreComposited"] as? NSNumber)?.boolValue ?? false

                if isPreComposited {
                    NSLog("[VGDuetExportSession] BYPASSING_OFFLINE_VISION_COMPOSITOR reason=isPreComposited segment=%@",
                          (realSegmentPath as NSString).lastPathComponent)

                    // The recorded segment is already the final composited frame;
                    // only its video-track presence needs proving here -- path
                    // existence/non-emptiness was already validated in
                    // export(args:result:) before busy was marked.
                    let precomposedAsset = AVURLAsset(
                        url:     URL(fileURLWithPath: realSegmentPath),
                        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                    guard !precomposedAsset.tracks(withMediaType: .video).isEmpty else {
                        _finishWithError(
                            code:    "source_invalid",
                            message: "exportDuetComposition: pre-composited green-screen segment has no video track: \(realSegmentPath)",
                            result:  result)
                        return
                    }

                    if effectiveCreatorOverlayDicts.isEmpty {
                        // -- Fast path: no video render pass at all. Mux source/mic
                        // audio directly onto the already-composited segment via
                        // VGAudioExportMuxer. --
                        //
                        // VGAudioExportMuxer documents that it deletes its
                        // videoTempPath argument on every terminal path (success and
                        // failure alike), so the original recorded segment must
                        // never be passed directly -- only a disposable copy/hardlink
                        // is.
                        let precomposedTempPath = (outputParentPath as NSString)
                            .appendingPathComponent("vg_duet_gs_precomposited_\(UUID().uuidString).mp4")
                        if fm.fileExists(atPath: precomposedTempPath) {
                            try? fm.removeItem(atPath: precomposedTempPath)
                        }
                        do {
                            try fm.linkItem(atPath: realSegmentPath, toPath: precomposedTempPath)
                        } catch {
                            do {
                                try fm.copyItem(atPath: realSegmentPath, toPath: precomposedTempPath)
                            } catch let copyError {
                                _finishWithError(
                                    code:    "composition_failed",
                                    message: "exportDuetComposition: failed to stage pre-composited segment for audio mux: \(copyError.localizedDescription)",
                                    result:  result)
                                return
                            }
                        }

                        guard let sidecar = realTakeAudioSidecar else {
                            // No audible tracks (both source/mic muted or zero
                            // gain): the export must be genuinely silent. The
                            // staged path is only a hardlink/copy of
                            // realSegmentPath -- VGDuetSegmentRecorder records
                            // microphone audio into every take unconditionally
                            // (sourceAudioMuted/micAudioMuted/gain=0 are
                            // export-time mix knobs, not recording-time gates),
                            // so it still carries a live mic audio track.
                            // Moving or copying it straight to outputPath would
                            // leak that mic audio into a supposedly silent
                            // export. Strip every audio track by re-muxing only
                            // the video track into a fresh output instead.
                            _stripAudioAndFinalizePreComposited(
                                stagedVideoPath: precomposedTempPath,
                                outputPath:      outputPath,
                                result:          result)
                            return
                        }

                        let muxer = VGAudioExportMuxer(
                            videoTempPath:   precomposedTempPath,
                            audioSidecar:    sidecar,
                            finalOutputPath: outputPath)
                        muxer.startMux { [weak self] success, duration, error in
                            if success {
                                let finalAttr = try? fm.attributesOfItem(atPath: outputPath)
                                let finalSize = (finalAttr?[.size] as? NSNumber)?.intValue ?? 0
                                guard finalSize > 0 else {
                                    try? fm.removeItem(atPath: outputPath)
                                    DispatchQueue.main.async {
                                        self?._clearBusy()
                                        result(FlutterError(
                                            code:    "composition_failed",
                                            message: "exportDuetComposition: pre-composited mux output is empty.",
                                            details: nil))
                                    }
                                    return
                                }
                                let resolvedDuration = (duration > 0) ? duration : effectiveExportDurationSec
                                let durationMs = max(1, Int((resolvedDuration * 1000.0).rounded()))
                                DispatchQueue.main.async {
                                    self?._clearBusy()
                                    result([
                                        "outputPath":    outputPath,
                                        "durationMs":    durationMs,
                                        "fileSizeBytes": finalSize,
                                    ])
                                }
                            } else {
                                let msg = error?.localizedDescription ?? "pre-composited green-screen audio mux failed (unknown)"
                                DispatchQueue.main.async {
                                    self?._clearBusy()
                                    result(FlutterError(
                                        code:    "composition_failed",
                                        message: "exportDuetComposition: \(msg)",
                                        details: nil))
                                }
                            }
                        }
                        return  // pre-composited fast path exits here.

                    } else {
                        // -- Overlays present: still pre-composited (no offline
                        // Vision), but overlays require a video render pass, so
                        // route through the shared VGTimelineExportHelper tail below
                        // with the pre-composited segment as the single clip source.
                        // VGTimelineExportHelper never mutates or deletes a clip's
                        // sourcePath, so realSegmentPath is used directly here -- no
                        // temp copy needed (only the VGAudioExportMuxer fast path
                        // above requires one). --
                        pngPath = nil
                        clipDicts = [[
                            "id":               "duet_gs_precomposited",
                            "sourcePath":       realSegmentPath,
                            "mediaKind":        "video",
                            "startTimeSeconds": 0.0,
                            "durationSeconds":  effectiveExportDurationSec,
                            "trimStartSeconds": 0.0,
                            "trimEndSeconds":   effectiveExportDurationSec,
                            "speed":            1.0,
                        ]]
                        overlayDicts = effectiveCreatorOverlayDicts
                        exportDurationSec = effectiveExportDurationSec
                        audioSidecar = realTakeAudioSidecar
                        // Falls through to the shared VGTimelineExportHelper tail at
                        // the end of _performExport.
                    }

                } else {
                    let fgTransform: NativeForegroundTransform? = _parseForegroundTransform(layoutConfigMap)
                    let canvasW = CGFloat(targetWidth)
                    let canvasH = CGFloat(targetHeight)

                    let gsTempToken = UUID().uuidString.lowercased()
                    let gsTempStem = (outputPath as NSString).deletingPathExtension
                    let tmpOutputPath = gsTempStem + ".gs_video_tmp." + gsTempToken + ".mp4"
                    if fm.fileExists(atPath: tmpOutputPath) {
                        try? fm.removeItem(atPath: tmpOutputPath)
                    }

                    let compositor = VGDuetGreenScreenExportCompositor()
                    let compositeResult = compositor.compose(
                        sourcePath:          sourcePath,
                        sourceTrimStart:     trimStart,
                        cameraPath:          realSegmentPath,
                        outputPath:          tmpOutputPath,
                        canvasWidth:         targetWidth,
                        canvasHeight:        targetHeight,
                        durationSeconds:     effectiveExportDurationSec,
                        fps:                 30,
                        videoBitRate:        videoBitRate,
                        foregroundTransform: fgTransform,
                        canvasSize:          CGSize(width: canvasW, height: canvasH)
                    )
                    guard compositeResult.success else {
                        if fm.fileExists(atPath: tmpOutputPath) {
                            try? fm.removeItem(atPath: tmpOutputPath)
                        }
                        _finishWithError(
                            code:    "composition_failed",
                            message: "exportDuetComposition: green-screen video pass failed: \(compositeResult.reason ?? "unknown")",
                            result:  result)
                        return
                    }

                    // ── Audio re-mux for green-screen real-take ──────────────────────
                    // VGTimelineExportHelper is reused as a pure audio muxer: a
                    // single-clip "video-only" source pointing at the composited tmp
                    // file is passed in with the shared audio sidecar. The helper will
                    // copy the video track and mix the audio tracks into a new tmp2
                    // file, then the Duet export session renames that to the final path.
                    let audioMuxTmpPath = gsTempStem + ".gs_mux_tmp." + gsTempToken + ".mp4"
                    if fm.fileExists(atPath: audioMuxTmpPath) {
                        try? fm.removeItem(atPath: audioMuxTmpPath)
                    }

                    // Verify the video composite before entering the audio pass.
                    guard fm.fileExists(atPath: tmpOutputPath) else {
                        _finishWithError(
                            code:    "composition_failed",
                            message: "exportDuetComposition: green-screen compositor reported success but video tmp is missing.",
                            result:  result)
                        return
                    }
                    let tmpAttr = try? fm.attributesOfItem(atPath: tmpOutputPath)
                    let tmpSize = (tmpAttr?[.size] as? NSNumber)?.intValue ?? 0
                    guard tmpSize > 0 else {
                        try? fm.removeItem(atPath: tmpOutputPath)
                        _finishWithError(
                            code:    "composition_failed",
                            message: "exportDuetComposition: green-screen compositor video tmp is empty.",
                            result:  result)
                        return
                    }

                    // The composite is about to be handed to VGTimelineExportHelper as a
                    // source clip; prove AVFoundation can see its video track first so a
                    // container/extension problem fails here with a precise reason
                    // instead of surfacing as an opaque helper failure.
                    let tmpBasename = (tmpOutputPath as NSString).lastPathComponent
                    let tmpAsset = AVURLAsset(url: URL(fileURLWithPath: tmpOutputPath),
                                              options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                    guard let tmpVideoTrack = tmpAsset.tracks(withMediaType: .video).first else {
                        NSLog("[VGDuetExportSession] IOS_DUET_GS_TEMP_VIDEO_TRACK_MISSING file=%@ bytes=%d durationSec=%.3f",
                              tmpBasename, tmpSize, CMTimeGetSeconds(tmpAsset.duration))
                        try? fm.removeItem(atPath: tmpOutputPath)
                        _finishWithError(
                            code:    "composition_failed",
                            message: "exportDuetComposition: green-screen composite \(tmpBasename) (\(tmpSize) bytes) has no video track; not handing it to the timeline helper.",
                            result:  result)
                        return
                    }
                    NSLog("[VGDuetExportSession] IOS_DUET_GS_TEMP_VIDEO_VALIDATED file=%@ bytes=%d durationSec=%.3f naturalSize=%.0fx%.0f",
                          tmpBasename, tmpSize, CMTimeGetSeconds(tmpAsset.duration),
                          tmpVideoTrack.naturalSize.width, tmpVideoTrack.naturalSize.height)

                    let canvasDict: [String: Any] = ["width": targetWidth, "height": targetHeight]
                    // Single-clip descriptor pointing at the video composite.
                    let gsClipDicts: [[String: Any]] = [[
                        "id":               "duet_gs_composite",
                        "sourcePath":       tmpOutputPath,
                        "mediaKind":        "video",
                        "startTimeSeconds": 0.0,
                        "durationSeconds":  effectiveExportDurationSec,
                        "trimStartSeconds": 0.0,
                        "trimEndSeconds":   effectiveExportDurationSec,
                        "speed":            1.0,
                    ]]

                    VGTimelineExportHelper.exportTimeline(
                        withClips:   gsClipDicts,
                        transitions: [],
                        outputPath:  audioMuxTmpPath,
                        width:       targetWidth,
                        height:      targetHeight,
                        fps:         30,
                        bitrateBps:  videoBitRate,
                        canvas:      canvasDict,
                        overlays:    effectiveCreatorOverlayDicts,
                        audioSidecar: realTakeAudioSidecar
                    ) { [weak self] success, _, duration, error in
                        // Clean up the video composite tmp regardless.
                        if fm.fileExists(atPath: tmpOutputPath) {
                            try? fm.removeItem(atPath: tmpOutputPath)
                        }

                        if success {
                            guard fm.fileExists(atPath: audioMuxTmpPath) else {
                                DispatchQueue.main.async {
                                    self?._clearBusy()
                                    result(FlutterError(
                                        code:    "composition_failed",
                                        message: "exportDuetComposition: audio mux tmp missing after green-screen pass.",
                                        details: nil))
                                }
                                return
                            }
                            let tmpAttr2 = try? fm.attributesOfItem(atPath: audioMuxTmpPath)
                            guard (tmpAttr2?[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
                                try? fm.removeItem(atPath: audioMuxTmpPath)
                                DispatchQueue.main.async {
                                    self?._clearBusy()
                                    result(FlutterError(
                                        code:    "composition_failed",
                                        message: "exportDuetComposition: audio mux output empty after green-screen pass.",
                                        details: nil))
                                }
                                return
                            }
                            do {
                                try fm.moveItem(atPath: audioMuxTmpPath, toPath: outputPath)
                            } catch {
                                try? fm.removeItem(atPath: audioMuxTmpPath)
                                DispatchQueue.main.async {
                                    self?._clearBusy()
                                    result(FlutterError(
                                        code:    "composition_failed",
                                        message: "exportDuetComposition: green-screen rename failed: \(error.localizedDescription)",
                                        details: nil))
                                }
                                return
                            }
                            let finalAttr = try? fm.attributesOfItem(atPath: outputPath)
                            let finalSize = (finalAttr?[.size] as? NSNumber)?.intValue ?? 0
                            guard finalSize > 0 else {
                                try? fm.removeItem(atPath: outputPath)
                                DispatchQueue.main.async {
                                    self?._clearBusy()
                                    result(FlutterError(
                                        code:    "composition_failed",
                                        message: "exportDuetComposition: green-screen final file empty after rename.",
                                        details: nil))
                                }
                                return
                            }
                            let resolvedDuration = (duration > 0) ? duration : effectiveExportDurationSec
                            let durationMs = max(1, Int((resolvedDuration * 1000.0).rounded()))
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
                            if fm.fileExists(atPath: audioMuxTmpPath) {
                                try? fm.removeItem(atPath: audioMuxTmpPath)
                            }
                            let msg = error?.localizedDescription ?? "green-screen audio pass failed (unknown)"
                            DispatchQueue.main.async {
                                self?._clearBusy()
                                result(FlutterError(
                                    code:    "composition_failed",
                                    message: "exportDuetComposition: \(msg)",
                                    details: nil))
                            }
                        }
                    }
                    return  // greenScreen real-take exits here; does NOT fall through to VGTimelineExportHelper below.
                }
            } else {
                // ── PiP / Split real-take route (unchanged) ──────────────────────────
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
                audioSidecar = realTakeAudioSidecar
            }


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

    /// Pre-composited green-screen fast path, silent case only: re-muxes
    /// [stagedVideoPath]'s video track alone -- no audio track at all -- into
    /// [outputPath], then deletes [stagedVideoPath] on every terminal path.
    ///
    /// [stagedVideoPath] is a disposable hardlink/copy of the recorded
    /// segment (never [realSegmentPath] itself, which this method never
    /// touches or deletes). It still carries VGDuetSegmentRecorder's own mic
    /// audio track even when the export's audio sidecar is nil, so it must
    /// never be moved or copied to [outputPath] as-is; only a video-only
    /// re-mux is safe for a silent export.
    ///
    /// Uses AVMutableComposition + AVAssetExportPresetPassthrough (no
    /// re-encode): a fresh composition track receives only the source video
    /// track's full time range via insertTimeRange, and the source track's
    /// preferredTransform is copied onto it explicitly (insertTimeRange does
    /// not carry it over). VGAudioExportMuxer is not used here because its
    /// designated initializer requires a non-nil VGAudioSidecarPlan;
    /// VGTimelineExportHelper is not used because a full render pass is
    /// unneeded for a video-only re-mux.
    ///
    /// On success, verifies the output file is non-empty, has a video track,
    /// and has zero audio tracks before replying.
    private func _stripAudioAndFinalizePreComposited(
        stagedVideoPath: String,
        outputPath:      String,
        result:          @escaping FlutterResult
    ) {
        let fm = FileManager.default

        let stagedAsset = AVURLAsset(url: URL(fileURLWithPath: stagedVideoPath),
                                     options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let stagedVideoTrack = stagedAsset.tracks(withMediaType: .video).first else {
            try? fm.removeItem(atPath: stagedVideoPath)
            _finishWithError(
                code:    "composition_failed",
                message: "exportDuetComposition: staged pre-composited segment has no video track to strip audio from.",
                result:  result)
            return
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            try? fm.removeItem(atPath: stagedVideoPath)
            _finishWithError(
                code:    "composition_failed",
                message: "exportDuetComposition: failed to create a video-only composition track for the silent pre-composited export.",
                result:  result)
            return
        }
        do {
            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: stagedAsset.duration),
                of: stagedVideoTrack,
                at: .zero)
        } catch {
            try? fm.removeItem(atPath: stagedVideoPath)
            _finishWithError(
                code:    "composition_failed",
                message: "exportDuetComposition: failed to build the video-only composition for the silent pre-composited export: \(error.localizedDescription)",
                result:  result)
            return
        }
        // insertTimeRange copies sample data but not preferredTransform.
        compositionVideoTrack.preferredTransform = stagedVideoTrack.preferredTransform

        guard !fm.fileExists(atPath: outputPath) else {
            // export(args:result:) already validated outputPath does not
            // exist before busy was marked; reaching this while still
            // holding that same busy claim would be a logic bug rather than
            // a normal race. Fail closed rather than silently overwrite.
            try? fm.removeItem(atPath: stagedVideoPath)
            _finishWithError(
                code:    "composition_failed",
                message: "exportDuetComposition: output file already exists before the silent pre-composited export: \(outputPath)",
                result:  result)
            return
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            try? fm.removeItem(atPath: stagedVideoPath)
            _finishWithError(
                code:    "composition_failed",
                message: "exportDuetComposition: failed to create an AVAssetExportSession for the silent pre-composited export.",
                result:  result)
            return
        }
        exportSession.outputURL = URL(fileURLWithPath: outputPath)
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        exportSession.exportAsynchronously { [weak self] in
            // Fires on an arbitrary queue (Apple docs); hop to main before
            // touching the Flutter result callback, matching every other
            // completion handler in this file. The staged copy is
            // disposable and is always cleaned up here, on every outcome.
            try? fm.removeItem(atPath: stagedVideoPath)

            guard let self = self else { return }

            switch exportSession.status {
            case .completed:
                guard fm.fileExists(atPath: outputPath) else {
                    DispatchQueue.main.async {
                        self._clearBusy()
                        result(FlutterError(
                            code:    "composition_failed",
                            message: "exportDuetComposition: silent pre-composited export reported success but the output file is missing.",
                            details: nil))
                    }
                    return
                }
                let finalAttr = try? fm.attributesOfItem(atPath: outputPath)
                let finalSize = (finalAttr?[.size] as? NSNumber)?.intValue ?? 0
                guard finalSize > 0 else {
                    try? fm.removeItem(atPath: outputPath)
                    DispatchQueue.main.async {
                        self._clearBusy()
                        result(FlutterError(
                            code:    "composition_failed",
                            message: "exportDuetComposition: silent pre-composited export output is empty.",
                            details: nil))
                    }
                    return
                }
                // Verify the exact claim this method exists to make: the
                // video track survived and every audio track was stripped.
                let finalAsset = AVURLAsset(url: URL(fileURLWithPath: outputPath),
                                            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                guard !finalAsset.tracks(withMediaType: .video).isEmpty else {
                    try? fm.removeItem(atPath: outputPath)
                    DispatchQueue.main.async {
                        self._clearBusy()
                        result(FlutterError(
                            code:    "composition_failed",
                            message: "exportDuetComposition: silent pre-composited export output has no video track.",
                            details: nil))
                    }
                    return
                }
                guard finalAsset.tracks(withMediaType: .audio).isEmpty else {
                    try? fm.removeItem(atPath: outputPath)
                    DispatchQueue.main.async {
                        self._clearBusy()
                        result(FlutterError(
                            code:    "composition_failed",
                            message: "exportDuetComposition: silent pre-composited export output unexpectedly retained an audio track.",
                            details: nil))
                    }
                    return
                }
                let finalDurationSec = CMTimeGetSeconds(finalAsset.duration)
                let resolvedDurationSec = finalDurationSec.isFinite && finalDurationSec > 0
                    ? finalDurationSec
                    : CMTimeGetSeconds(composition.duration)
                let durationMs = max(1, Int((resolvedDurationSec * 1000.0).rounded()))
                DispatchQueue.main.async {
                    self._clearBusy()
                    result([
                        "outputPath":    outputPath,
                        "durationMs":    durationMs,
                        "fileSizeBytes": finalSize,
                    ])
                }
            case .cancelled:
                if fm.fileExists(atPath: outputPath) { try? fm.removeItem(atPath: outputPath) }
                DispatchQueue.main.async {
                    self._clearBusy()
                    result(FlutterError(
                        code:    "composition_failed",
                        message: "exportDuetComposition: silent pre-composited export was cancelled.",
                        details: nil))
                }
            default:
                if fm.fileExists(atPath: outputPath) { try? fm.removeItem(atPath: outputPath) }
                let msg = exportSession.error?.localizedDescription ?? "unknown export session failure"
                DispatchQueue.main.async {
                    self._clearBusy()
                    result(FlutterError(
                        code:    "composition_failed",
                        message: "exportDuetComposition: silent pre-composited export failed: \(msg)",
                        details: nil))
                }
            }
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

// MARK: - VGDuetGreenScreenExportResult
//
// Inlined from VGDuetGreenScreenExportCompositor.swift to ensure this type is
// visible to VGDuetExportSession without requiring a separate Xcode source
// membership entry for the compositor file.  During this R&D slice the
// compositor file is untracked/new and may not be included in the stale
// CocoaPods-generated project; inlining here guarantees the symbol is compiled
// in the same translation unit as its caller.

struct VGDuetGreenScreenExportResult {
    let success: Bool
    let reason: String?
}

// MARK: - VGDuetGreenScreenExportCompositor
//
// Offline green-screen export compositor for Duet real-take.
// Architecture (Opus-frozen Option 1):
//   - Source video decoded from [sourcePath] at [sourceTrimStart] as the
//     full-canvas background.
//   - Camera segment decoded from [cameraPath] from t=0 as the foreground.
//   - VNGeneratePersonSegmentationRequest qualityLevel=Balanced runs per
//     output frame on the camera CVPixelBuffer.
//   - CIBlendWithMask composites the keyed camera foreground over the source
//     background frame in the greenScreen camera rect.
//   - Fixed output clock: pts = frame_index / fps.
//   - Fail-closed: no mask available for any rendered frame → composition_failed;
//     no unkeyed fallback frames are output.
//   - All resources released on all exit paths.
//   - NSLog terminal diagnostics with backend=vision_balanced.
//
// Non-claims: no audio (owned by VGDuetExportSession's audio sidecar path),
// no live camera, no static/image backgrounds, no GPU MediaPipe.

/// Offline green-screen export compositor for Duet real-take.
/// Caller: VGDuetExportSession._performExport, greenScreen real-take branch.
/// Runs synchronously on the calling background queue; never touches the
/// main thread. One instance per export; not reentrant.
final class VGDuetGreenScreenExportCompositor {

    private static let logTag = "[VGDuetGreenScreenExportCompositor]"

    // ─── Public entry ─────────────────────────────────────────────────────────

    /// Runs the offline green-screen composite synchronously.
    ///
    /// - Parameters:
    ///   - sourcePath: Source video (background); trimmed from sourceTrimStart.
    ///   - sourceTrimStart: Start offset (seconds) within source video.
    ///   - cameraPath: Recorded camera segment (foreground); always read from t=0.
    ///   - outputPath: Destination MP4 file path (must not already exist).
    ///   - canvasWidth / canvasHeight: Output frame size in pixels.
    ///   - durationSeconds: Export duration (already bounded by min(trim, segment)).
    ///   - fps: Output frame rate (integer).
    ///   - videoBitRate: AVC bitrate in bps.
    ///   - foregroundTransform: Optional free-transform; nil → full-canvas camera rect.
    ///   - canvasSize: Convenience CGSize matching canvasWidth × canvasHeight.
    func compose(
        sourcePath:          String,
        sourceTrimStart:     Double,
        cameraPath:          String,
        outputPath:          String,
        canvasWidth:         Int,
        canvasHeight:        Int,
        durationSeconds:     Double,
        fps:                 Int,
        videoBitRate:        Int,
        foregroundTransform: NativeForegroundTransform?,
        canvasSize:          CGSize
    ) -> VGDuetGreenScreenExportResult {
        guard canvasWidth > 0, canvasHeight > 0, fps > 0, videoBitRate > 0 else {
            return fail("invalid_config:\(canvasWidth)x\(canvasHeight)@\(fps)fps:\(videoBitRate)bps")
        }
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return fail("invalid_duration:\(durationSeconds)")
        }

        let totalFrames = max(1, Int((durationSeconds * Double(fps)).rounded(.up)))
        let fm = FileManager.default
        // Guard against pre-existing output.
        guard !fm.fileExists(atPath: outputPath) else { return fail("output_already_exists") }

        // ── Layout geometry ───────────────────────────────────────────────────
        // Source = full canvas (background). Camera = foreground transform rect.
        let layoutRects = VGDuetLayoutGeometry.greenScreen(
            canvasWidth:  canvasSize.width,
            canvasHeight: canvasSize.height,
            transform:    foregroundTransform
        )
        // Camera rect in CoreImage bottom-left-origin pixel coords:
        let cameraRectCI = ciRect(from: layoutRects.camera, canvasHeight: CGFloat(canvasHeight))
        let canvasRectCI = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)

        // ── AVFoundation readers ──────────────────────────────────────────────
        var sourceReader: AVAssetReader? = nil
        var sourceOutput: AVAssetReaderVideoCompositionOutput? = nil
        var cameraReader: AVAssetReader? = nil
        var cameraOutput: AVAssetReaderVideoCompositionOutput? = nil
        var writer: AVAssetWriter? = nil
        var writerInput: AVAssetWriterInput? = nil
        var adaptor: AVAssetWriterInputPixelBufferAdaptor? = nil
        var ciContext: CIContext? = nil

        var renderedFrames = 0
        var segmentedFrames = 0
        var totalSegMs: Double = 0.0
        var maxSegMs: Double = 0.0
        var writerFinished = false
        var outputSizeBytes = 0

        let startTime = Date()

        do {
            // ── Source reader ─────────────────────────────────────────────────
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let sourceAsset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let sourceTrack = sourceAsset.tracks(withMediaType: .video).first else {
                return fail("source_no_video_track")
            }
            let sr = try AVAssetReader(asset: sourceAsset)
            // Seek source to trimStart.
            let trimCMTime = CMTime(seconds: sourceTrimStart, preferredTimescale: 600)
            let endCMTime   = CMTime(seconds: sourceTrimStart + durationSeconds, preferredTimescale: 600)
            sr.timeRange = CMTimeRange(start: trimCMTime, end: endCMTime)
            // Defect 2 fix: use AVAssetReaderVideoCompositionOutput instead of
            // AVAssetReaderTrackOutput so preferredTransform is applied at decode
            // time.  Raw AVAssetReaderTrackOutput ignores preferredTransform and
            // returns encoded-orientation buffers, causing portrait clips to render
            // sideways (mirrors Phase 7.9 fix in VGTimelineCompositorNode.m).
            // renderSize = display dimensions (after preferredTransform rotation) so
            // existing aspect-fill placement into the full canvas is unchanged.
            let so = makeOrientationNormalized(
                asset: sourceAsset, track: sourceTrack,
                renderSize: displaySize(of: sourceTrack)
            )
            guard sr.canAdd(so) else { return fail("source_reader_output_rejected") }
            sr.add(so)
            guard sr.startReading() else {
                return fail("source_reader_start_failed:\(sr.error?.localizedDescription ?? "unknown")")
            }
            sourceReader = sr; sourceOutput = so

            // ── Camera reader ─────────────────────────────────────────────────
            let cameraURL = URL(fileURLWithPath: cameraPath)
            let cameraAsset = AVURLAsset(url: cameraURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let cameraTrack = cameraAsset.tracks(withMediaType: .video).first else {
                return fail("camera_no_video_track")
            }
            let cr = try AVAssetReader(asset: cameraAsset)
            // Defect 2 fix: same orientation normalization as source reader.
            // Camera-produced clips carry identity preferredTransform, so
            // makeOrientationNormalized applies no rotation for them and decoded
            // frames are unchanged (no double rotation).
            let co = makeOrientationNormalized(
                asset: cameraAsset, track: cameraTrack,
                renderSize: displaySize(of: cameraTrack)
            )
            guard cr.canAdd(co) else { return fail("camera_reader_output_rejected") }
            cr.add(co)
            guard cr.startReading() else {
                return fail("camera_reader_start_failed:\(cr.error?.localizedDescription ?? "unknown")")
            }
            cameraReader = cr; cameraOutput = co

            // ── Writer setup ──────────────────────────────────────────────────
            let outputURL = URL(fileURLWithPath: outputPath)
            let w = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey:  AVVideoCodecType.h264,
                AVVideoWidthKey:  canvasWidth,
                AVVideoHeightKey: canvasHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: videoBitRate,
                    AVVideoProfileLevelKey:   AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
            let wi = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            wi.expectsMediaDataInRealTime = false
            let adaptorAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey  as String: canvasWidth,
                kCVPixelBufferHeightKey as String: canvasHeight,
            ]
            let adp = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: wi, sourcePixelBufferAttributes: adaptorAttrs)
            guard w.canAdd(wi) else { return fail("writer_input_rejected") }
            w.add(wi)
            guard w.startWriting() else {
                return fail("writer_start_failed:\(w.error?.localizedDescription ?? "unknown")")
            }
            w.startSession(atSourceTime: .zero)
            writer = w; writerInput = wi; adaptor = adp

            // ── CIContext ─────────────────────────────────────────────────────
            // Metal-backed for best performance; CPU fallback on devices without Metal.
            // Memory hardening: .cacheIntermediates: false, combined with periodic
            // ctx.clearCaches() calls below, prevents CoreImage's internal
            // intermediate-image cache from growing unbounded across the full
            // export frame loop (root cause of the EXC_RESOURCE high-watermark
            // crashes observed on-device).
            let ciOptions: [CIContextOption: Any] = [
                .workingColorSpace: NSNull(),
                .outputColorSpace: NSNull(),
                .cacheIntermediates: false,
            ]
            if let metalDevice = MTLCreateSystemDefaultDevice() {
                ciContext = CIContext(mtlDevice: metalDevice, options: ciOptions)
            } else {
                ciContext = CIContext(options: ciOptions)
            }
            guard let ctx = ciContext else { return fail("ci_context_init_failed") }

            // Defect 3 fix: create the Vision segmentation request once per
            // export instead of once per frame. Boxed as Any? because
            // VNGeneratePersonSegmentationRequest requires iOS 15+ and this
            // file's deployment target is 14 -- the concrete type is only ever
            // unboxed inside an `if #available(iOS 15.0, *)` check, in
            // segmentFrame below. A per-frame allocation contributed to the
            // memory high-water mark growth that preceded the EXC_RESOURCE
            // crashes observed on-device.
            var segmentationRequestBox: Any? = nil
            if #available(iOS 15.0, *) {
                let request = VNGeneratePersonSegmentationRequest()
                request.qualityLevel = .balanced
                request.outputPixelFormat = kCVPixelFormatType_OneComponent8
                segmentationRequestBox = request
            }

            // ── State for PTS-based pairing ───────────────────────────────────
            var lastSourceBuffer: CVPixelBuffer? = nil
            var lastCameraBuffer: CVPixelBuffer? = nil
            var pendingSource: (buffer: CVPixelBuffer, pts: CMTime)? = nil
            var pendingCamera: (buffer: CVPixelBuffer, pts: CMTime)? = nil
            var sourceEOS = false
            var cameraEOS = false

            // ── Frame loop ────────────────────────────────────────────────────
            for frameIndex in 0 ..< totalFrames {
                try autoreleasepool {
                    let targetPTS = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
                    // PTS fix: source samples remain on the source asset's own
                    // timebase after a non-zero sourceTrimStart -- AVAssetReader's
                    // timeRange clips what is vended, it does not rebase PTS to
                    // zero -- so the source side must target trimCMTime + targetPTS.
                    // The camera side is always read from t=0, so it keeps the
                    // zero-based targetPTS unchanged.
                    let sourceTargetPTS = CMTimeAdd(trimCMTime, targetPTS)

                    // Select source frame.
                    let sourceBuf = try selectFrame(
                        output: so, pending: &pendingSource, last: &lastSourceBuffer,
                        eos: &sourceEOS, target: sourceTargetPTS, label: "source", frameIndex: frameIndex
                    )
                    // Select camera frame.
                    let cameraBuf = try selectFrame(
                        output: co, pending: &pendingCamera, last: &lastCameraBuffer,
                        eos: &cameraEOS, target: targetPTS, label: "camera", frameIndex: frameIndex
                    )

                    // ── Segment camera frame via Vision ───────────────────────────
                    let segT0 = Date()
                    guard let mask = segmentFrame(cameraBuf, frameIndex: frameIndex, requestBox: segmentationRequestBox) else {
                        throw VGGSCompositorError(reason: "segmentation_failed:frame=\(frameIndex)")
                    }
                    let segElapsed = Date().timeIntervalSince(segT0) * 1000.0
                    totalSegMs += segElapsed
                    if segElapsed > maxSegMs { maxSegMs = segElapsed }
                    segmentedFrames += 1

                    // ── Writer readiness wait (moved before composite) ──────────────
                    // Defect 2 fix, relocated ahead of composite(): bounded
                    // pacing/yielding instead of a single readiness check that
                    // threw immediately. Checked before composite() (not after,
                    // as previously) so a lagging or already-failed/cancelled
                    // writer is caught before paying for this frame's Vision
                    // segmentation result and CIContext render work.
                    if !wi.isReadyForMoreMediaData {
                        let readyDeadline = Date().addingTimeInterval(10.0)
                        while !wi.isReadyForMoreMediaData {
                            if w.status == .failed || w.status == .cancelled {
                                throw VGGSCompositorError(reason: "writer_input_not_ready_writer_failed:frame=\(frameIndex):status=\(w.status.rawValue):\(w.error?.localizedDescription ?? "unknown")")
                            }
                            if Date() >= readyDeadline {
                                throw VGGSCompositorError(reason: "writer_input_not_ready_timeout:frame=\(frameIndex)")
                            }
                            usleep(1_000)
                        }
                    }

                    // ── Composite ─────────────────────────────────────────────────
                    // Defect 1 fix: derive foreground rotation from the transform so the
                    // rotated-camera path in composite() matches live preview.
                    let fgRotation = VGDuetLayoutGeometry.foregroundRotation(
                        transform: foregroundTransform
                    )
                    guard let outputBuffer = composite(
                        ctx:          ctx,
                        sourceBuf:    sourceBuf,
                        cameraBuf:    cameraBuf,
                        mask:         mask,
                        canvasRect:   canvasRectCI,
                        cameraRect:   cameraRectCI,
                        fgRotation:   fgRotation,
                        adaptor:      adp,
                        canvasWidth:  canvasWidth,
                        canvasHeight: canvasHeight
                    ) else {
                        throw VGGSCompositorError(reason: "composite_failed:frame=\(frameIndex)")
                    }

                    // ── Append to writer ──────────────────────────────────────────
                    guard adp.append(outputBuffer, withPresentationTime: targetPTS) else {
                        throw VGGSCompositorError(reason: "adaptor_append_failed:frame=\(frameIndex):\(w.error?.localizedDescription ?? "unknown")")
                    }
                    renderedFrames += 1

                    // Memory hardening: release CoreImage's internal
                    // intermediate-image cache every 30 frames so it never
                    // accumulates across a long export.
                    if renderedFrames % 30 == 0 {
                        ctx.clearCaches()
                    }
                }
            }

            // Release decoders' held buffers prior to finishWriting wait.
            lastSourceBuffer = nil
            lastCameraBuffer = nil
            pendingSource = nil
            pendingCamera = nil

            // Memory hardening: release any remaining CoreImage intermediates
            // before the writer's finishWriting wait below.
            ctx.clearCaches()

            // ── Finish writer ─────────────────────────────────────────────────
            wi.markAsFinished()
            let writerGroup = DispatchGroup()
            writerGroup.enter()
            w.finishWriting {
                writerGroup.leave()
            }
            // Wait up to 120 seconds for finishWriting.
            let waitResult = writerGroup.wait(timeout: .now() + 120)
            if waitResult == .timedOut {
                return fail("writer_finish_timeout")
            }
            if w.status != .completed {
                return fail("writer_finish_failed:\(w.error?.localizedDescription ?? "unknown")")
            }
            writerFinished = true

            // Verify output.
            guard fm.fileExists(atPath: outputPath) else { return fail("output_missing_after_write") }
            let attr = try fm.attributesOfItem(atPath: outputPath)
            outputSizeBytes = (attr[.size] as? NSNumber)?.intValue ?? 0
            guard outputSizeBytes > 0 else {
                try? fm.removeItem(atPath: outputPath)
                return fail("output_empty_after_write")
            }

        } catch let compositorError as VGGSCompositorError {
            // Memory hardening: release CoreImage intermediates on the
            // failure path too, before cleaning up the partial output file.
            ciContext?.clearCaches()
            gsCleanupOnFailure(outputPath: outputPath, writerFinished: writerFinished, fm: fm)
            return fail(compositorError.reason)
        } catch {
            ciContext?.clearCaches()
            gsCleanupOnFailure(outputPath: outputPath, writerFinished: writerFinished, fm: fm)
            return fail("exception:\(error.localizedDescription)")
        }

        // ── Terminal diagnostics ──────────────────────────────────────────────
        let totalMs = Date().timeIntervalSince(startTime) * 1000.0
        let avgSegMs = segmentedFrames > 0 ? totalSegMs / Double(segmentedFrames) : 0.0
        NSLog("%@ VG_DUET_GS_EXPORT_RESULT status=success backend=vision_balanced " +
              "rendered=%d segmented=%d avgSegMs=%.1f maxSegMs=%.1f " +
              "outputSize=%d totalMs=%.0f",
              VGDuetGreenScreenExportCompositor.logTag,
              renderedFrames, segmentedFrames, avgSegMs, maxSegMs,
              outputSizeBytes, totalMs)
        return VGDuetGreenScreenExportResult(success: true, reason: nil)
    }

    // ─── Private: Vision segmentation ────────────────────────────────────────

    /// Runs VNGeneratePersonSegmentationRequest (Balanced) on [pixelBuffer]
    /// using the single [requestBox]-boxed request created once per export by
    /// [compose] (Defect 3 fix -- this method must never allocate a new
    /// VNGeneratePersonSegmentationRequest per frame). Returns a CIImage mask
    /// (OneComponent8, bottom-left origin) on success, or nil on any failure
    /// (fail-closed: caller must reject the frame).
    private func segmentFrame(_ pixelBuffer: CVPixelBuffer, frameIndex: Int, requestBox: Any?) -> CIImage? {
        if #available(iOS 15.0, *) {
            guard let request = requestBox as? VNGeneratePersonSegmentationRequest else {
                NSLog("%@ Missing segmentation request frame=%d",
                      VGDuetGreenScreenExportCompositor.logTag, frameIndex)
                return nil
            }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do {
                try handler.perform([request])
            } catch {
                NSLog("%@ Vision performRequests failed frame=%d error=%@",
                      VGDuetGreenScreenExportCompositor.logTag, frameIndex, error.localizedDescription)
                return nil
            }
            guard let observation = request.results?.first as? VNPixelBufferObservation else {
                NSLog("%@ No VNPixelBufferObservation frame=%d",
                      VGDuetGreenScreenExportCompositor.logTag, frameIndex)
                return nil
            }
            let maskBuf = observation.pixelBuffer
            guard CVPixelBufferGetPixelFormatType(maskBuf) == kCVPixelFormatType_OneComponent8,
                  CVPixelBufferGetWidth(maskBuf) > 0,
                  CVPixelBufferGetHeight(maskBuf) > 0 else {
                NSLog("%@ Unexpected Vision mask format or dimensions frame=%d",
                      VGDuetGreenScreenExportCompositor.logTag, frameIndex)
                return nil
            }
            return CIImage(cvPixelBuffer: maskBuf)
        } else {
            NSLog("%@ VNGeneratePersonSegmentationRequest requires iOS 15+ (frame=%d)",
                  VGDuetGreenScreenExportCompositor.logTag, frameIndex)
            return nil
        }
    }

    // ─── Private: CIBlendWithMask composite ──────────────────────────────────

    /// Composites camera foreground over source background using the Vision mask.
    ///
    /// Pipeline:
    ///   1. Source BGRA → CIImage (full canvas, bottom-left origin).
    ///   2. Camera BGRA → CIImage, aspect-fill scaled and positioned into cameraRect.
    ///   3. If fgRotation is non-zero: rotate camera layer and mask together around
    ///      the anchor pivot (Defect 1 fix — mirrors VGDuetPreviewCompositor.rotateCameraLayer).
    ///   4. Mask → CIImage, scaled to cameraRect dimensions, rotated by the same transform.
    ///   5. CIBlendWithMask: output = camera * mask + source * (1 - mask) within canvasRect.
    ///   6. Rendered into a fresh CVPixelBuffer from the adaptor pool.
    ///
    /// Returns nil on any CI or pool failure.
    private func composite(
        ctx:         CIContext,
        sourceBuf:   CVPixelBuffer,
        cameraBuf:   CVPixelBuffer,
        mask:        CIImage,
        canvasRect:  CGRect,
        cameraRect:  CGRect,
        fgRotation:  VGDuetForegroundRotation,
        adaptor:     AVAssetWriterInputPixelBufferAdaptor,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> CVPixelBuffer? {
        // Source fills the full canvas via aspect-fill (scale to cover canvasRect,
        // then center-crop).  A plain .cropped(to: canvasRect) does not scale, so
        // when makeOrientationNormalized produces a display-sized buffer that differs
        // from the export canvas the output is black/transparent/cropped.
        // This mirrors live preview's aspect-fill placement for the source background.
        let sourceCIImage = CIImage(cvPixelBuffer: sourceBuf)
        let srcW = sourceCIImage.extent.width
        let srcH = sourceCIImage.extent.height
        let srcScaleX = canvasRect.width  / max(1, srcW)
        let srcScaleY = canvasRect.height / max(1, srcH)
        let srcFillScale = max(srcScaleX, srcScaleY)
        let scaledSrcW = srcW * srcFillScale
        let scaledSrcH = srcH * srcFillScale
        let srcCropOffsetX = (scaledSrcW - canvasRect.width)  / 2.0
        let srcCropOffsetY = (scaledSrcH - canvasRect.height) / 2.0
        let sourceImage = sourceCIImage
            .transformed(by: CGAffineTransform(scaleX: srcFillScale, y: srcFillScale))
            .cropped(to: CGRect(
                x: srcCropOffsetX,
                y: srcCropOffsetY,
                width:  canvasRect.width,
                height: canvasRect.height
            ))
            .transformed(by: CGAffineTransform(
                translationX: canvasRect.minX - srcCropOffsetX,
                y:            canvasRect.minY - srcCropOffsetY
            ))
            .cropped(to: canvasRect)

        // Camera frame: aspect-fill into cameraRect.
        let camW = CGFloat(CVPixelBufferGetWidth(cameraBuf))
        let camH = CGFloat(CVPixelBufferGetHeight(cameraBuf))
        var cameraImage = CIImage(cvPixelBuffer: cameraBuf)

        // Scale camera frame to fill cameraRect (aspect-fill: largest scale
        // so no empty space; the frame may be cropped at the rect edges).
        let scaleX = cameraRect.width  / max(1, camW)
        let scaleY = cameraRect.height / max(1, camH)
        let fillScale = max(scaleX, scaleY)
        let scaledCamW = camW * fillScale
        let scaledCamH = camH * fillScale
        let cropOffsetX = (scaledCamW - cameraRect.width)  / 2.0
        let cropOffsetY = (scaledCamH - cameraRect.height) / 2.0

        cameraImage = cameraImage
            .transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
            .cropped(to: CGRect(
                x: cropOffsetX,
                y: cropOffsetY,
                width:  cameraRect.width,
                height: cameraRect.height
            ))
            .transformed(by: CGAffineTransform(
                translationX: cameraRect.minX - cropOffsetX,
                y:            cameraRect.minY - cropOffsetY
            ))
            .cropped(to: cameraRect)

        // Mask: scale Vision output (camera-aspect) to cameraRect dimensions.
        let maskExtent = mask.extent
        let maskScaleX = cameraRect.width  / max(1, maskExtent.width)
        let maskScaleY = cameraRect.height / max(1, maskExtent.height)
        var scaledMask = mask
            .transformed(by: CGAffineTransform(scaleX: maskScaleX, y: maskScaleY))
            .cropped(to: CGRect(x: 0, y: 0, width: cameraRect.width, height: cameraRect.height))
            .transformed(by: CGAffineTransform(translationX: cameraRect.minX, y: cameraRect.minY))
            .cropped(to: cameraRect)

        // ── Defect 1 fix: apply foreground free-rotation ──────────────────────
        //
        // Mirrors VGDuetPreviewCompositor.rotateCameraLayer exactly:
        //   • anchorX is left-to-right inside rect: rect.minX + anchorX * rect.width.
        //   • anchorY is Dart/top-left-normalized → flip for CoreImage bottom-left:
        //     rect.minY + (1 - anchorY) * rect.height.
        //   • rotationDegrees is visual-clockwise in Dart/top-left space → negate
        //     for CoreImage's bottom-left space (clockwise in top-left = counter-
        //     clockwise in bottom-left, so negating the radians gives clockwise in CI).
        //   • No crop after rotation: rotated corners extending outside cameraRect
        //     are preserved; the canvasRect crop on the blend output clips everything.
        if fgRotation.rotationDegrees.isFinite && abs(fgRotation.rotationDegrees) > 0.0001 {
            let pivotX = cameraRect.minX + fgRotation.anchorX * cameraRect.width
            let pivotY = cameraRect.minY + (1.0 - fgRotation.anchorY) * cameraRect.height
            let radians = -fgRotation.rotationDegrees * CGFloat.pi / 180.0
            let rotateTx = CGAffineTransform(translationX: -pivotX, y: -pivotY)
                .concatenating(CGAffineTransform(rotationAngle: radians))
                .concatenating(CGAffineTransform(translationX: pivotX, y: pivotY))
            cameraImage = cameraImage.transformed(by: rotateTx)
            scaledMask  = scaledMask.transformed(by: rotateTx)
        }

        // CIBlendWithMask: output = fg * mask + bg * (1 - mask).
        // Background input is the source image so pixels outside the camera
        // rect remain untouched. Cropped to canvasRect after blend so the
        // canvas boundary clips any rotation overflow that exceeds the canvas.
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return nil }
        blendFilter.setValue(cameraImage,  forKey: "inputImage")
        blendFilter.setValue(sourceImage,  forKey: "inputBackgroundImage")
        blendFilter.setValue(scaledMask,   forKey: "inputMaskImage")
        guard let composited = blendFilter.outputImage?.cropped(to: canvasRect) else { return nil }

        // Render into a pixel buffer from the adaptor pool.
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var outBuffer: CVPixelBuffer? = nil
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
        guard status == kCVReturnSuccess, let buffer = outBuffer else { return nil }
        ctx.render(composited, to: buffer)
        return buffer
    }

    // ─── Private: PTS-based frame selection ──────────────────────────────────

    /// Selects the newest decoded frame with PTS ≤ targetPTS.
    /// After EOS the last selected frame is held. No frame at frame 0 fails
    /// closed (throws VGGSCompositorError).
    private func selectFrame(
        output:    AVAssetReaderOutput,
        pending:   inout (buffer: CVPixelBuffer, pts: CMTime)?,
        last:      inout CVPixelBuffer?,
        eos:       inout Bool,
        target:    CMTime,
        label:     String,
        frameIndex: Int
    ) throws -> CVPixelBuffer {
        // Consume any pending future sample that has now become eligible.
        if let p = pending, CMTimeCompare(p.pts, target) <= 0 {
            last = p.buffer; pending = nil
        }

        if !eos {
            var samplesWithoutImage = 0
            decodeLoop: while true {
                guard let sample = output.copyNextSampleBuffer() else {
                    // EOS.
                    eos = true; break decodeLoop
                }
                guard let buf = CMSampleBufferGetImageBuffer(sample) else {
                    samplesWithoutImage += 1
                    if samplesWithoutImage > 64 {
                        throw VGGSCompositorError(reason: "\(label):decode_no_image_buffers:frame=\(frameIndex)")
                    }
                    continue decodeLoop
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if CMTimeCompare(pts, target) <= 0 {
                    last = buf
                } else if last == nil && frameIndex == 0 {
                    // First-frame anchor fallback: the very first decodable
                    // sample's PTS can land slightly after `target` -- source
                    // samples stay on the asset's own timebase after a
                    // non-zero trim start, and camera capture start jitter can
                    // push the first camera frame's PTS past 0. Rather than
                    // parking it as `pending` and failing frame 0 closed with
                    // `no_decodable_frame` (nothing has ever been selected
                    // yet), accept it as the anchor frame so export can
                    // proceed. Later frames keep the existing pending/
                    // hold-last behavior unchanged.
                    last = buf
                    break decodeLoop
                } else {
                    pending = (buf, pts)
                    break decodeLoop
                }
            }
        }

        guard let selected = last else {
            throw VGGSCompositorError(reason: "\(label):no_decodable_frame:frame=\(frameIndex)")
        }
        return selected
    }

    // ─── Private: helpers ─────────────────────────────────────────────────────

    private func fail(_ reason: String) -> VGDuetGreenScreenExportResult {
        NSLog("%@ VG_DUET_GS_EXPORT_RESULT status=failed backend=vision_balanced reason=%@",
              VGDuetGreenScreenExportCompositor.logTag, reason)
        return VGDuetGreenScreenExportResult(success: false, reason: reason)
    }

    private func gsCleanupOnFailure(outputPath: String, writerFinished: Bool, fm: FileManager) {
        if !writerFinished && fm.fileExists(atPath: outputPath) {
            try? fm.removeItem(atPath: outputPath)
        }
    }

    /// Converts a CoreGraphics-top-left VGDuetLayoutGeometry camera rect to
    /// CoreImage bottom-left canvas coordinates.
    private func ciRect(from rect: CGRect, canvasHeight: CGFloat) -> CGRect {
        return CGRect(
            x:      rect.minX,
            y:      canvasHeight - rect.maxY,
            width:  rect.width,
            height: rect.height
        )
    }

    // ─── Private: Defect 2 fix — orientation-normalized reader output ─────────

    /// Returns the display size of `track` after applying `preferredTransform`.
    ///
    /// For portrait clips (90°/270° encoded orientation) the natural size has
    /// width and height swapped relative to the display orientation; applying
    /// `preferredTransform` corrects this.  For camera-produced clips that carry
    /// an identity `preferredTransform` the natural size is returned unchanged.
    private func displaySize(of track: AVAssetTrack) -> CGSize {
        let natural = track.naturalSize
        let tx      = track.preferredTransform
        // CGRectApplyAffineTransform includes scale from the transform but also
        // maps rotation to a potentially negative rect; use fabs to get magnitudes.
        let displayRect = CGRectApplyAffineTransform(
            CGRect(origin: .zero, size: natural), tx)
        let w = abs(displayRect.width);  let h = abs(displayRect.height)
        // Guard against degenerate tracks; fall back to natural size.
        return (w > 0 && h > 0) ? CGSize(width: w, height: h) : natural
    }

    /// Builds an `AVAssetReaderVideoCompositionOutput` that applies
    /// `track.preferredTransform` at decode time, producing orientation-
    /// normalized BGRA pixel buffers at `renderSize`.
    ///
    /// This mirrors the Phase 7.9 fix in `VGTimelineCompositorNode.m`:
    /// raw `AVAssetReaderTrackOutput` ignores `preferredTransform`, causing
    /// portrait `.mov`/`.mp4` files to render sideways.
    ///
    /// The video composition is generated with the deprecated-in-iOS-18
    /// `videoCompositionWithPropertiesOfAsset:` synchronous API (same as the
    /// timeline compositor node) because this helper is called synchronously on
    /// a background queue.  The API remains fully functional through current iOS.
    ///
    /// Camera-produced clips carry identity `preferredTransform`; the video
    /// composition applies no rotation and decoded frames are unchanged.
    private func makeOrientationNormalized(
        asset:      AVURLAsset,
        track:      AVAssetTrack,
        renderSize: CGSize
    ) -> AVAssetReaderVideoCompositionOutput {
        // Build a video composition that applies preferredTransform.
        // Deprecated in iOS 18 but fully functional; mirrors the timeline
        // compositor node §Phase 7.9 (same justification: called synchronously).
        let videoComposition = AVMutableVideoComposition(propertiesOf: asset)

        // Override renderSize to the display dimensions so vended pixel buffers
        // are already upright.  When preferredTransform is identity (camera clips)
        // renderSize equals naturalSize and nothing changes.
        if renderSize.width > 0 && renderSize.height > 0 {
            videoComposition.renderSize = renderSize

            // Build a layer instruction that carries the preferredTransform so the
            // video composition applies the rotation + translation at decode time.
            // For identity preferredTransform this is a no-op.
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(
                assetTrack: track)
            layerInstruction.setTransform(track.preferredTransform, at: .zero)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
            instruction.layerInstructions = [layerInstruction]
            videoComposition.instructions = [instruction]
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: outputSettings)
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        return output
    }

    // ─── Private: error type ──────────────────────────────────────────────────

    private struct VGGSCompositorError: Error {
        let reason: String
    }
}
