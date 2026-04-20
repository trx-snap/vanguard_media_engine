// VanguardExportSession.swift
// Phase 6: Multi-clip export with trim + audio mixing
// Phase 0 (T9, T11): Background task, real cancel/suspend, os_signpost
//
// Pipeline:
//   AVMutableComposition  → stitch clips with trim in AVFoundation timeline
//   AVMutableVideoComposition → bake preferredTransform (orientation)
//   AVAssetExportSession  → H.264 encode + AAC audio + mux → .mp4
//
// This replaces the previous custom frame-pump loop which had a spin-lock
// deadlock risk when AVAssetWriter interleaved audio and video tracks.

import Foundation
import AVFoundation
import UIKit
import os.signpost

typealias ExportProgressHandler   = (Float)       -> Void
typealias ExportCompletionHandler = (URL?, Error?) -> Void

// Permanent signpost log — visible in Instruments > Points of Interest
private let _exportLog = OSLog(subsystem: "com.vanguard.engine", category: "export")

// ─── Clip Specification ───────────────────────────────────────────────────────

struct ClipSpec {
    let url:       URL
    let trimStart: Double
    let trimEnd:   Double
    /// Playback rate for this segment. 1.0 = normal, 0.5 = slow-mo, 2.0 = fast.
    /// Applied via scaleTimeRange(toDuration:) during composition build.
    let speed:     Double

    init(url: URL, trimStart: Double = 0.0, trimEnd: Double = .infinity, speed: Double = 1.0) {
        self.url       = url
        self.trimStart = trimStart
        self.trimEnd   = trimEnd
        self.speed     = speed
    }
}

// ─── Export Session ───────────────────────────────────────────────────────────

class VanguardExportSession {

    // ─── Configuration ────────────────────────────────────────────────────────
    struct Config {
        let outputURL:  URL
        let width:      Int
        let height:     Int
        let bitrate:    Int
        let fps:        Int
        let maxSeconds: Double
        let audioURL:   URL?
        let audioStart: Double
        /// Move `moov` atom to front of file for adaptive streaming / social upload.
        /// Adds ~5% to encode time. Default: false (local playback / review is faster).
        let optimizeForNetworkUse: Bool

        init(outputURL: URL, width: Int, height: Int, bitrate: Int, fps: Int,
             maxSeconds: Double, audioURL: URL? = nil, audioStart: Double = 0.0,
             optimizeForNetworkUse: Bool = false) {
            self.outputURL            = outputURL
            self.width                = width
            self.height               = height
            self.bitrate              = bitrate
            self.fps                  = fps
            self.maxSeconds           = maxSeconds
            self.audioURL             = audioURL
            self.audioStart           = audioStart
            self.optimizeForNetworkUse = optimizeForNetworkUse
        }
    }

    // ─── Private State ───────────────────────────────────────────────────────
    private let config:   Config
    private let clips:    [ClipSpec]
    private var progress: ExportProgressHandler?
    private var completion: ExportCompletionHandler?

    /// T9: Stored property — enables real cancel() and suspend().
    /// Previously a local variable in _run(), making cancel() a no-op.
    private var _exporter: AVAssetExportSession?

    private let exportQueue = DispatchQueue(label: "com.vanguard.export", qos: .userInitiated)

    init(config: Config, clips: [ClipSpec]) {
        self.config = config
        self.clips  = clips
    }

    // ─── Public API ──────────────────────────────────────────────────────────

    func start(progress: ExportProgressHandler? = nil,
               completion: @escaping ExportCompletionHandler) {
        self.progress   = progress
        self.completion = completion
        exportQueue.async { self._run() }
    }

    /// T9: Real cancel — calls through to AVAssetExportSession.cancelExport().
    /// Previously this method was a stub: `/* AVAssetExportSession cancellation handled internally */`
    func cancel() {
        _exporter?.cancelExport()
    }

    /// T9: Called by VanguardMediaEnginePlugin's interruption handler (phone call etc.)
    /// Cancels the underlying exporter and fires the completion handler with a failure,
    /// ensuring the Dart Future is resolved rather than hanging indefinitely.
    func suspend() {
        _exporter?.cancelExport()
        let err = NSError(domain: "VanguardExport", code: -2,
                          userInfo: [NSLocalizedDescriptionKey:
                              "Export interrupted (audio session interruption)"])
        completion?(nil, err)
        completion = nil  // prevent double-fire if exporter callback also fires
    }

    // ─── Static Audio Extraction ─────────────────────────────────────────────

    static func extractAudio(
        from videoURL:  URL,
        to   outputURL: URL,
        trimStart: Double = 0.0,
        trimEnd:   Double = Double.infinity,
        completion: @escaping (URL?, Error?) -> Void
    ) {
        let queue = DispatchQueue(label: "com.vanguard.audio_extract", qos: .userInitiated)
        queue.async {
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: outputURL.path) {
                    try fm.removeItem(at: outputURL)
                }

                let asset = AVAsset(url: videoURL)
                guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
                    throw NSError(domain: "Vanguard", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "No audio track found"])
                }

                let duration   = asset.duration.seconds
                let clampedEnd = min(trimEnd, duration)
                let startCM    = CMTimeMakeWithSeconds(trimStart,   preferredTimescale: 44100)
                let endCM      = CMTimeMakeWithSeconds(clampedEnd,  preferredTimescale: 44100)
                let range      = CMTimeRangeFromTimeToTime(start: startCM, end: endCM)

                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = range

                let audioOutput = AVAssetReaderTrackOutput(
                    track: audioTrack,
                    outputSettings: [
                        AVFormatIDKey:               kAudioFormatLinearPCM,
                        AVSampleRateKey:             44100.0,
                        AVNumberOfChannelsKey:       2,
                        AVLinearPCMBitDepthKey:      16,
                        AVLinearPCMIsNonInterleaved: false,
                        AVLinearPCMIsFloatKey:       false,
                        AVLinearPCMIsBigEndianKey:   false,
                    ]
                )
                audioOutput.alwaysCopiesSampleData = false
                reader.add(audioOutput)

                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
                let audioSettings: [String: Any] = [
                    AVFormatIDKey:         kAudioFormatMPEG4AAC,
                    AVSampleRateKey:       44100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey:   128_000,
                ]
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput.expectsMediaDataInRealTime = false
                writer.add(audioInput)

                reader.startReading()
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)

                while reader.status == .reading {
                    guard let sample = audioOutput.copyNextSampleBuffer() else { break }
                    if audioInput.isReadyForMoreMediaData {
                        audioInput.append(sample)
                    }
                }

                audioInput.markAsFinished()
                let sem = DispatchSemaphore(value: 0)
                writer.finishWriting { sem.signal() }
                sem.wait()

                if writer.status == .completed {
                    completion(outputURL, nil)
                } else {
                    completion(nil, writer.error)
                }
            } catch {
                completion(nil, error)
            }
        }
    }

    // ─── Pipeline ─────────────────────────────────────────────────────────────

    private func _run() {

        // T11: Begin export signpost — visible in Instruments > Points of Interest
        os_signpost(.begin, log: _exportLog, name: "export",
                    "clips=%d maxSec=%.1f", clips.count, config.maxSeconds)

        // T9: Register a background task so iOS gives us up to ~3 minutes to finish
        // after the user backgrounds the app. Without this the export is silently
        // suspended and the Dart Future never resolves.
        var bgTaskId = UIBackgroundTaskIdentifier.invalid
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "VanguardExport") {
            // Expiry handler — OS is about to kill us. Cancel cleanly.
            _export_exporter_cancel: do {
                self._exporter?.cancelExport()
            }
            UIApplication.shared.endBackgroundTask(bgTaskId)
        }

        defer {
            // T11: End export signpost
            os_signpost(.end, log: _exportLog, name: "export")
            // T9: Always end the background task, success or failure
            UIApplication.shared.endBackgroundTask(bgTaskId)
        }

        // ── Step 1: Build AVMutableComposition + audio mix params in one pass ─────
        let composition = AVMutableComposition()

        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            _finish(nil, _err("Failed to add video composition track"))
            return
        }
        let compAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid)

        var insertTime   = CMTime.zero
        var totalSeconds = 0.0
        var isFirstClip  = true

        // Build audio mix params inline — reuses the AVURLAsset already opened
        // for video insertion. No second pass, no duplicate asset opens.
        var audioParams: AVMutableAudioMixInputParameters? = nil
        if config.audioURL == nil, let compAudio = compAudioTrack {
            audioParams = AVMutableAudioMixInputParameters(track: compAudio)
        }
        let rampDur = CMTimeMake(value: 1, timescale: 30)  // 33ms

        for clip in clips {
            guard totalSeconds < config.maxSeconds else { break }

            // Open asset ONCE per clip — used for both video and audio insertion.
            let asset    = AVURLAsset(url: clip.url,
                                      options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            let duration = CMTimeGetSeconds(asset.duration)
            let trimEnd  = clip.trimEnd.isInfinite ? duration : clip.trimEnd
            let clipSec  = min(trimEnd - clip.trimStart,
                               config.maxSeconds - totalSeconds)
            guard clipSec > 0.001 else { continue }

            let range = CMTimeRange(
                start:    CMTimeMakeWithSeconds(clip.trimStart, preferredTimescale: 600),
                duration: CMTimeMakeWithSeconds(clipSec,        preferredTimescale: 600)
            )
            let clipDurCM = CMTimeMakeWithSeconds(clipSec, preferredTimescale: 600)

            // Insert video track
            if let vTrack = asset.tracks(withMediaType: .video).first {
                do {
                    try compVideoTrack.insertTimeRange(range, of: vTrack, at: insertTime)
                    if isFirstClip {
                        compVideoTrack.preferredTransform = vTrack.preferredTransform
                    }
                } catch {
                    NSLog("[Vanguard] Video insert failed for %@: %@",
                          clip.url.lastPathComponent, error.localizedDescription)
                }
            }

            // Insert clip audio + crossfade ramps (same asset, no re-open)
            if config.audioURL == nil,
               let aTrack = asset.tracks(withMediaType: .audio).first,
               let compAudio = compAudioTrack {
                do {
                    try compAudio.insertTimeRange(range, of: aTrack, at: insertTime)
                } catch {
                    NSLog("[Vanguard] Audio insert skipped for %@", clip.url.lastPathComponent)
                }

                // Crossfade params — computed here, not in a second loop
                if !isFirstClip {
                    audioParams?.setVolumeRamp(fromStartVolume: 0.0, toEndVolume: 1.0,
                        timeRange: CMTimeRange(start: insertTime, duration: rampDur))
                }
                let fadeOutStart = CMTimeSubtract(CMTimeAdd(insertTime, clipDurCM), rampDur)
                audioParams?.setVolumeRamp(fromStartVolume: 1.0, toEndVolume: 0.0,
                    timeRange: CMTimeRange(start: fadeOutStart, duration: rampDur))
            }

            insertTime    = CMTimeAdd(insertTime, clipDurCM)
            totalSeconds += clipSec
            isFirstClip   = false
        }

        var audioMix: AVMutableAudioMix? = nil
        if let params = audioParams {
            audioMix = AVMutableAudioMix()
            audioMix?.inputParameters = [params]
        }

        // ── Step 2: External audio override ───────────────────────────────────
        if let extURL = config.audioURL {
            let extAsset = AVURLAsset(url: extURL)
            if let extAudioTrack = extAsset.tracks(withMediaType: .audio).first {
                let extAvail = CMTimeGetSeconds(extAsset.duration) - config.audioStart
                let extDur   = min(totalSeconds, max(0, extAvail))
                if extDur > 0.001 {
                    let extRange = CMTimeRange(
                        start:    CMTimeMakeWithSeconds(config.audioStart, preferredTimescale: 44100),
                        duration: CMTimeMakeWithSeconds(extDur,            preferredTimescale: 44100)
                    )
                    compAudioTrack?.removeTimeRange(
                        CMTimeRange(start: .zero, duration: insertTime))
                    do {
                        try compAudioTrack?.insertTimeRange(extRange, of: extAudioTrack, at: .zero)
                    } catch {
                        NSLog("[Vanguard] External audio insert failed: %@",
                              error.localizedDescription)
                    }
                }
            }
        }

        // ── Step 3: Video composition (correct orientation) ────────────────────
        let videoComposition = _buildVideoComposition(for: composition, duration: insertTime)
        if videoComposition.renderSize == .zero {
            _finish(nil, _err("Composition has no video track (renderSize = zero)"))
            return
        }
        NSLog("[Vanguard] renderSize: %.0fx%.0f",
              videoComposition.renderSize.width, videoComposition.renderSize.height)

        // ── Step 4: HDR-aware preset selection (P1-T6) ────────────────────────
        // If ANY source clip has HDR colour primaries (BT.2020), select HEVC to
        // preserve HDR metadata (HLG / PQ). H.264 presets silently strip HDR tags.
        // This is a post-publish quality regression that cannot be recovered.
        let presetName = _selectExportPreset(forClips: clips)
        guard let exporter = AVAssetExportSession(
            asset: composition, presetName: presetName
        ) else {
            // Fallback: if selected preset unavailable, try H.264
            guard let fallbackExporter = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPreset1920x1080
            ) else {
                _finish(nil, _err("AVAssetExportSession unavailable for all presets"))
                return
            }
            NSLog("[Vanguard] Preset %@ unavailable — falling back to 1920x1080", presetName)
            _exporter = fallbackExporter
            // Configure fallback exporter inline (same settings below apply)
            let fm2 = FileManager.default
            if fm2.fileExists(atPath: config.outputURL.path) {
                try? fm2.removeItem(at: config.outputURL)
            }
            fallbackExporter.outputURL        = config.outputURL
            fallbackExporter.outputFileType   = .mp4
            fallbackExporter.videoComposition = videoComposition
            fallbackExporter.audioMix         = audioMix
            fallbackExporter.shouldOptimizeForNetworkUse = config.optimizeForNetworkUse
            fallbackExporter.timeRange = CMTimeRange(
                start:    .zero,
                duration: CMTimeMakeWithSeconds(min(totalSeconds, config.maxSeconds),
                                               preferredTimescale: 600))
            fallbackExporter.exportAsynchronously {
                switch fallbackExporter.status {
                case .completed: self._finish(self.config.outputURL, nil)
                case .failed:    self._finish(nil, fallbackExporter.error ?? self._err("export failed"))
                case .cancelled: self._finish(nil, self._err("export cancelled"))
                default: break
                }
            }
            return
        }

        // T9: Store as instance property so cancel() and suspend() can reach it
        _exporter = exporter

        let fm = FileManager.default
        if fm.fileExists(atPath: config.outputURL.path) {
            try? fm.removeItem(at: config.outputURL)
        }

        exporter.outputURL        = config.outputURL
        exporter.outputFileType   = .mp4
        exporter.videoComposition = videoComposition
        exporter.audioMix         = audioMix
        // Move moov atom to file front only when caller requests it (e.g. social upload).
        // Default: false — saves ~5% encode time for local preview / review flows.
        exporter.shouldOptimizeForNetworkUse = config.optimizeForNetworkUse
        exporter.timeRange        = CMTimeRange(
            start:    .zero,
            duration: CMTimeMakeWithSeconds(
                min(totalSeconds, config.maxSeconds),
                preferredTimescale: 600))

        // Progress polling
        let progressQ = DispatchQueue.global(qos: .utility)
        progressQ.async {
            while exporter.status == .waiting || exporter.status == .exporting {
                Thread.sleep(forTimeInterval: 0.15)
                self.progress?(exporter.progress)
            }
        }

        NSLog("[Vanguard] Export starting: %.1fs → %@",
              totalSeconds, config.outputURL.lastPathComponent)

        exporter.exportAsynchronously {
            switch exporter.status {
            case .completed:
                NSLog("[Vanguard] Export complete → %@", self.config.outputURL.path)
                self._finish(self.config.outputURL, nil)
            case .failed:
                let msg = exporter.error?.localizedDescription ?? "unknown error"
                NSLog("[Vanguard] Export failed: %@", msg)
                self._finish(nil, exporter.error ?? self._err(msg))
            case .cancelled:
                self._finish(nil, self._err("Export was cancelled"))
            default:
                self._finish(nil, self._err("Unexpected exporter state: \(exporter.status.rawValue)"))
            }
            self._exporter = nil  // release reference after completion
        }
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// Fires the completion handler exactly once. Guards against double-fire from
    /// suspend() and the exporter callback both calling completion.
    private func _finish(_ url: URL?, _ error: Error?) {
        guard let c = completion else { return }
        completion = nil
        c(url, error)
    }

    private func _buildVideoComposition(for composition: AVMutableComposition,
                                        duration: CMTime) -> AVMutableVideoComposition {
        let fallback = AVMutableVideoComposition(propertiesOf: composition)

        guard let firstClip = clips.first,
              let compTrack = composition.tracks(withMediaType: .video).first else {
            return fallback
        }

        let srcAsset = AVURLAsset(url: firstClip.url)
        guard let srcTrack = srcAsset.tracks(withMediaType: .video).first else {
            return fallback
        }

        let transform   = srcTrack.preferredTransform
        let naturalSize = srcTrack.naturalSize
        let displayed   = naturalSize.applying(transform)
        let renderSize  = CGSize(width: abs(displayed.width), height: abs(displayed.height))

        guard renderSize.width > 0 && renderSize.height > 0 else { return fallback }

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
        layerInstruction.setTransform(transform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange        = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]

        let vc           = AVMutableVideoComposition()
        vc.renderSize    = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.instructions  = [instruction]

        NSLog("[Vanguard] Video composition: %.0fx%.0f transform=(%.2f,%.2f,%.2f,%.2f,%.0f,%.0f)",
              renderSize.width, renderSize.height,
              transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty)

        return vc
    }


    // P1-T6: Select export preset by probing colour primaries.
    // BT.2020 (kCMFormatDescriptionColorPrimaries_ITU_R_2020) = HDR source.
    // H.264 presets silently strip HDR metadata — use HEVC to preserve it.
    private func _selectExportPreset(forClips clips: [ClipSpec]) -> String {
        for clip in clips {
            let asset = AVURLAsset(url: clip.url,
                                   options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            guard let videoTrack = asset.tracks(withMediaType: .video).first else { continue }
            for desc in videoTrack.formatDescriptions {
                // swiftlint:disable:next force_cast
                let fmtDesc = desc as! CMFormatDescription
                guard let primaries = CMFormatDescriptionGetExtension(
                    fmtDesc,
                    extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
                ) as? String else { continue }
                if primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) {
                    NSLog("[Vanguard] HDR source detected — selecting HEVC preset")
                    return AVAssetExportPresetHEVC1920x1080
                }
            }
        }
        NSLog("[Vanguard] SDR source — selecting H.264 1920x1080 preset")
        return AVAssetExportPreset1920x1080
    }

    private func _err(_ msg: String) -> NSError {
        NSError(domain: "VanguardExport", code: -1,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
