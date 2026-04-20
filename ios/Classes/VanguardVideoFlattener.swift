// VanguardVideoFlattener.swift
// Phase 3B: iOS-native replacement for FFmpegKit flattenVideo path.
//
// Approach: AVVideoCompositionCoreAnimationTool — static CALayer PNG overlay.
// No custom AVVideoCompositing protocol required.
//
// Two audio paths:
//   PATH A (audioPath != nil): video audio @ 0.2 + music @ 1.0 (AVMutableAudioMix)
//   PATH B (audioPath == nil): video audio pass-through (no audioMix)
//
// Scale/crop: fill-mode crop to 1080×1920 via layer instruction affine transform.
//   Portrait 9:16 source → scale=1.0 (identity, no crop needed).
//   Landscape or other aspect ratio → scale-up to fill height, crop width.
//
// HDR: preset selection mirrors VanguardExportSession pattern.
//   BT.2020 primaries → HEVC preset. SDR → H.264 preset.
//
// Android: unchanged — continues to use FFmpegKit for this operation.

import Foundation
import AVFoundation
import CoreGraphics
import UIKit
import QuartzCore

class VanguardVideoFlattener {

    private static let kRenderSize   = CGSize(width: 1080, height: 1920)
    private static let kFPS: Int32   = 30

    // MARK: - Public API

    /// Exports a video with a full-frame PNG overlay + optional audio mix to MP4.
    ///
    /// - Parameters:
    ///   - videoPath:         Source video path
    ///   - overlayPNGPath:    Full-frame overlay PNG (text stickers / filters)
    ///   - audioPath:         Optional music audio. If nil, video audio passes through.
    ///   - audioStartSeconds: Seek offset into external audio (default 0)
    ///   - outputPath:        Destination MP4 path
    ///   - durationSeconds:   Target output duration (default 15.0)
    ///   - completion:        (outputURL, nil) on success; (nil, error) on failure
    static func export(
        videoPath:         String,
        overlayPNGPath:    String,
        audioPath:         String? = nil,
        audioStartSeconds: Double  = 0.0,
        outputPath:        String,
        durationSeconds:   Double  = 15.0,
        completion: @escaping (URL?, Error?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try _export(
                    videoPath:         videoPath,
                    overlayPNGPath:    overlayPNGPath,
                    audioPath:         audioPath,
                    audioStartSeconds: audioStartSeconds,
                    outputPath:        outputPath,
                    durationSeconds:   durationSeconds
                )
                completion(URL(fileURLWithPath: outputPath), nil)
            } catch {
                NSLog("[VanguardFlatten] export failed: %@", error.localizedDescription)
                completion(nil, error)
            }
        }
    }

    // MARK: - Private pipeline

    private static func _export(
        videoPath:         String,
        overlayPNGPath:    String,
        audioPath:         String?,
        audioStartSeconds: Double,
        outputPath:        String,
        durationSeconds:   Double
    ) throws {
        let outputURL = URL(fileURLWithPath: outputPath)
        let fm = FileManager.default
        if fm.fileExists(atPath: outputPath) { try fm.removeItem(at: outputURL) }

        let videoURL   = URL(fileURLWithPath: videoPath)
        let videoAsset = AVURLAsset(url: videoURL,
                                    options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

        guard let videoTrack = videoAsset.tracks(withMediaType: .video).first else {
            throw _err("No video track in source: \(videoPath)")
        }

        let srcSec  = CMTimeGetSeconds(videoAsset.duration)
        let clipSec = min(srcSec, durationSeconds)
        guard clipSec > 0.001 else { throw _err("Source video has zero duration") }

        let clipRange = CMTimeRange(
            start:    .zero,
            duration: CMTimeMakeWithSeconds(clipSec, preferredTimescale: 600)
        )

        // ── 1. Build AVMutableComposition ─────────────────────────────────────

        let composition = AVMutableComposition()

        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw _err("Failed to create composition video track") }

        try compVideoTrack.insertTimeRange(clipRange, of: videoTrack, at: .zero)

        // Video audio track (always attempt — may be nil for mute sources)
        let compAudioTrack1 = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        if let srcAudio = videoAsset.tracks(withMediaType: .audio).first,
           let at1 = compAudioTrack1 {
            try? at1.insertTimeRange(clipRange, of: srcAudio, at: .zero)
        }

        // External music track: PATH A only
        var compAudioTrack2: AVMutableCompositionTrack? = nil
        if let extPath = audioPath {
            compAudioTrack2 = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            if let at2 = compAudioTrack2 {
                try _insertMusicTrack(
                    into:              at2,
                    musicPath:         extPath,
                    audioStartSeconds: audioStartSeconds,
                    targetDuration:    durationSeconds
                )
            }
            NSLog("[VanguardFlatten] PATH A: external music inserted")
        } else {
            NSLog("[VanguardFlatten] PATH B: video audio pass-through (no music track)")
        }

        // ── 2. Build AVMutableAudioMix ────────────────────────────────────────

        var audioMix: AVMutableAudioMix? = nil
        if let at2 = compAudioTrack2 {
            // PATH A: video audio @ 0.2, music @ 1.0
            var params: [AVMutableAudioMixInputParameters] = []

            if let at1 = compAudioTrack1 {
                let p1 = AVMutableAudioMixInputParameters(track: at1)
                p1.setVolume(0.2, at: .zero)
                params.append(p1)
            }
            let p2 = AVMutableAudioMixInputParameters(track: at2)
            p2.setVolume(1.0, at: .zero)
            params.append(p2)

            let mix = AVMutableAudioMix()
            mix.inputParameters = params
            audioMix = mix
        }
        // PATH B: audioMix = nil → AVAssetExportSession uses source audio as-is

        // ── 3. Build AVMutableVideoComposition with CoreAnimationTool ─────────

        let videoComposition = try _buildVideoComposition(
            compVideoTrack: compVideoTrack,
            videoTrack:     videoTrack,
            overlayPNGPath: overlayPNGPath,
            renderSize:     kRenderSize,
            duration:       clipRange.duration
        )

        // ── 4. HDR-aware preset selection (mirrors VanguardExportSession) ──────

        let preset = _selectExportPreset(videoTrack: videoTrack)
        NSLog("[VanguardFlatten] export starting | video=%@ overlay=%@ audio=%@ preset=%@",
              videoPath, overlayPNGPath, audioPath ?? "(none)", preset)

        guard let exporter = AVAssetExportSession(
            asset: composition, presetName: preset
        ) else { throw _err("AVAssetExportSession unavailable for preset \(preset)") }

        exporter.outputURL                 = outputURL
        exporter.outputFileType            = .mp4
        exporter.videoComposition         = videoComposition
        exporter.audioMix                 = audioMix
        exporter.shouldOptimizeForNetworkUse = false
        exporter.timeRange                = CMTimeRange(
            start:    .zero,
            duration: CMTimeMakeWithSeconds(min(clipSec, durationSeconds), preferredTimescale: 600)
        )

        let sem = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { sem.signal() }
        sem.wait()

        switch exporter.status {
        case .completed:
            NSLog("[VanguardFlatten] export success → %@", outputPath)
        case .failed:
            throw exporter.error ?? _err("Export failed (status=failed, no error object)")
        case .cancelled:
            throw _err("Export cancelled")
        default:
            throw _err("Unexpected export status: \(exporter.status.rawValue)")
        }
    }

    // MARK: - CoreAnimationTool video composition

    private static func _buildVideoComposition(
        compVideoTrack: AVMutableCompositionTrack,
        videoTrack:     AVAssetTrack,
        overlayPNGPath: String,
        renderSize:     CGSize,
        duration:       CMTime
    ) throws -> AVMutableVideoComposition {

        // ── Decode PNG once, upfront ──────────────────────────────────────────
        // captureRepaintBoundary produces pixelRatio:3.0 on a 360×640 pt screen
        // → 1080×1920px PNG which fills the render rect exactly.
        guard let uiImage = UIImage(contentsOfFile: overlayPNGPath),
              let cgImage = uiImage.cgImage else {
            throw _err("Cannot decode overlay PNG at \(overlayPNGPath)")
        }
        NSLog("[VanguardFlatten] overlay PNG decoded: %d×%d pts",
              cgImage.width, cgImage.height)

        // ── Layer hierarchy ───────────────────────────────────────────────────
        // parentLayer
        //   ├─ videoLayer     ← video frames rendered here (bottom)
        //   └─ overlayLayer   ← PNG composited on top
        //
        // postProcessingAsVideoLayer: videoLayer — video is rendered into
        // videoLayer first; then Core Animation composites the full parentLayer
        // (including overlayLayer) to produce the final output frame.
        // Result: PNG floats on top of each video frame. Alpha is respected.

        let renderRect = CGRect(origin: .zero, size: renderSize)

        let videoLayer = CALayer()
        videoLayer.frame = renderRect

        let overlayLayer = CALayer()
        overlayLayer.frame = renderRect
        overlayLayer.contents = cgImage
        // .resize scales the CGImage to fill the layer rect exactly.
        // PNG from captureRepaintBoundary is already at 1080×1920 → 1:1 mapping.
        overlayLayer.contentsGravity = .resize

        let parentLayer = CALayer()
        parentLayer.frame = renderRect
        parentLayer.addSublayer(videoLayer)    // video first (bottom)
        parentLayer.addSublayer(overlayLayer)  // PNG second (top)

        // ── Fill-mode crop transform via layer instruction ────────────────────
        let transform = _fillCropTransform(videoTrack: videoTrack, renderSize: renderSize)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(
            assetTrack: compVideoTrack
        )
        layerInstruction.setTransform(transform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange         = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]

        // ── AVMutableVideoComposition assembly ────────────────────────────────
        let vc = AVMutableVideoComposition()
        vc.renderSize    = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: kFPS)
        vc.instructions  = [instruction]
        // Must be set AFTER instructions — animationTool post-processes
        // each rendered frame produced by the instruction pass.
        vc.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        return vc
    }

    // MARK: - Fill-mode crop transform

    /// Returns a CGAffineTransform for the layer instruction that implements
    /// FFmpeg's `scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920`.
    ///
    /// For portrait 9:16 source → scale = 1.0 (effectively just preferredTransform).
    /// For landscape or other aspect ratios → scale-up to fill height, excess width cropped.
    private static func _fillCropTransform(
        videoTrack: AVAssetTrack,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let t   = videoTrack.preferredTransform
        let nat = videoTrack.naturalSize

        // Display size is naturalSize after applying preferredTransform (handles rotation).
        // abs() because rotation transforms produce negative dimension components.
        let displayW = abs(nat.applying(t).width)
        let displayH = abs(nat.applying(t).height)
        guard displayW > 0, displayH > 0 else {
            NSLog("[VanguardFlatten] fillCropTransform: degenerate display size — using preferredTransform only")
            return t
        }

        // Fill: scale so the short axis fills renderSize, long axis may overflow
        let scale = max(renderSize.width / displayW, renderSize.height / displayH)

        // Center-crop: offset so the scaled frame is centered in renderSize
        let tx = (renderSize.width  - displayW * scale) / 2.0
        let ty = (renderSize.height - displayH * scale) / 2.0

        NSLog("[VanguardFlatten] fillCropTransform: display=%.0f×%.0f scale=%.4f tx=%.1f ty=%.1f",
              displayW, displayH, scale, tx, ty)

        // Compose: preferred rotation → uniform scale → center translate
        return t
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    // MARK: - Music track loop-fill (composition-level, no manual sample rebasing)

    /// Inserts music audio into a composition track with loop-fill if the source
    /// is shorter than targetDuration. Uses AVMutableCompositionTrack.insertTimeRange
    /// with successive start offsets — no CMSampleBuffer manipulation required.
    private static func _insertMusicTrack(
        into track:        AVMutableCompositionTrack,
        musicPath:         String,
        audioStartSeconds: Double,
        targetDuration:    Double
    ) throws {
        let musicURL   = URL(fileURLWithPath: musicPath)
        let musicAsset = AVURLAsset(url: musicURL)

        guard let musicTrack = musicAsset.tracks(withMediaType: .audio).first else {
            NSLog("[VanguardFlatten] no audio track in music file — PATH A skips music")
            return
        }

        let musicDur = CMTimeGetSeconds(musicAsset.duration)
        var inserted = 0.0
        var loopPass = 0

        NSLog("[VanguardFlatten] music src=%.2fs start=%.2fs target=%.2fs",
              musicDur, audioStartSeconds, targetDuration)

        while inserted < targetDuration {
            let remaining = targetDuration - inserted
            let loopStart = (loopPass == 0) ? audioStartSeconds : 0.0
            let available = max(0.0, musicDur - loopStart)
            guard available > 0.001 else { break }

            let segDur  = min(available, remaining)
            let srcRange = CMTimeRange(
                start:    CMTimeMakeWithSeconds(loopStart, preferredTimescale: 44100),
                duration: CMTimeMakeWithSeconds(segDur,    preferredTimescale: 44100)
            )
            let insertAt = CMTimeMakeWithSeconds(inserted, preferredTimescale: 44100)

            try track.insertTimeRange(srcRange, of: musicTrack, at: insertAt)
            inserted += segDur
            loopPass += 1
            if loopPass > 100 { break }   // guard against degenerate very-short clips
        }
        NSLog("[VanguardFlatten] music inserted %.2fs in %d pass(es)", inserted, loopPass)
    }

    // MARK: - HDR preset selection (mirrors VanguardExportSession._selectExportPreset)

    /// Selects an AVAssetExportPreset appropriate for the source.
    /// BT.2020 primaries → HEVC (preserves HDR headroom).
    /// Everything else → H.264 1080p.
    private static func _selectExportPreset(videoTrack: AVAssetTrack) -> String {
        for desc in videoTrack.formatDescriptions {
            let fmt = desc as! CMFormatDescription
            guard let primaries = CMFormatDescriptionGetExtension(
                fmt,
                extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
            ) as? String else { continue }
            if primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) {
                return AVAssetExportPresetHEVC1920x1080
            }
        }
        return AVAssetExportPreset1920x1080
    }

    // MARK: - Error factory

    private static func _err(_ msg: String) -> NSError {
        NSError(domain: "VanguardVideoFlattener", code: -1,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
