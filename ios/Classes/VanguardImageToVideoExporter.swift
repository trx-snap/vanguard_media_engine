// VanguardImageToVideoExporter.swift
// Phase 3A: iOS-native replacement for FFmpegKit flattenImageToVideo path.
//
// Pipeline:
//   PNG → CGImage → CVPixelBuffer (BGRA) → H.264 video frames
//   Audio source → AVAssetReader (PCM) → AAC audio (with loop-fill if < 15s)
//   AVAssetWriter muxes both tracks → .mp4
//
// Pixel format: kCVPixelFormatType_32BGRA. This is the standard software-render
// format for AVAssetWriterInputPixelBufferAdaptor. H.264 encoder accepts BGRA
// and converts to YUV internally. If a device's encoder rejects this format,
// the error is surfaced through the completion handler — caller falls back.
//
// Audio interleave: video frames are written sequentially first (markAsFinished),
// then audio samples are written in their own pass. AVAssetWriter does not require
// per-timeslice interleaving when expectsMediaDataInRealTime = false — the muxer
// handles file-level interleave on finishWriting. This is the simplest valid flow.
//
// Android: unchanged — continues to use FFmpegKit for this operation.

import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import UIKit

class VanguardImageToVideoExporter {

    // MARK: - Public API

    /// Exports a static PNG image + audio track to an MP4 of [durationSeconds].
    ///
    /// - Parameters:
    ///   - imagePath:         Local path to source PNG (any UIImage-decodable format)
    ///   - audioPath:         Local path to audio source (.m4a / .mp3 / .wav)
    ///   - audioStartSeconds: Offset into audio source (seconds, default 0)
    ///   - outputPath:        Destination MP4 path (parent directory must exist)
    ///   - durationSeconds:   Target output duration (default 15.0)
    ///   - completion:        Called on background thread — (outputURL, nil) on success,
    ///                        (nil, error) on failure
    static func export(
        imagePath:         String,
        audioPath:         String,
        audioStartSeconds: Double = 0.0,
        outputPath:        String,
        durationSeconds:   Double = 15.0,
        completion:        @escaping (URL?, Error?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try _export(
                    imagePath:         imagePath,
                    audioPath:         audioPath,
                    audioStartSeconds: audioStartSeconds,
                    outputPath:        outputPath,
                    durationSeconds:   durationSeconds
                )
                completion(URL(fileURLWithPath: outputPath), nil)
            } catch {
                NSLog("[VanguardImgVid] export failed: %@", error.localizedDescription)
                completion(nil, error)
            }
        }
    }

    // MARK: - Private pipeline

    private static func _export(
        imagePath:         String,
        audioPath:         String,
        audioStartSeconds: Double,
        outputPath:        String,
        durationSeconds:   Double
    ) throws {

        let outputURL = URL(fileURLWithPath: outputPath)
        let fm = FileManager.default
        if fm.fileExists(atPath: outputPath) {
            try fm.removeItem(at: outputURL)
        }

        // ── 1. Decode PNG → CVPixelBuffer (BGRA) ─────────────────────────────

        guard let uiImage = UIImage(contentsOfFile: imagePath),
              let cgImage = uiImage.cgImage else {
            throw _err("Cannot decode image at \(imagePath)")
        }

        let width  = cgImage.width
        let height = cgImage.height

        // kCVPixelFormatType_32BGRA: accepted by AVAssetWriterInputPixelBufferAdaptor.
        // H.264 encoder performs BGRA→YUV conversion internally on all current iOS
        // devices. Logged for device validation.
        let pixelFormat = kCVPixelFormatType_32BGRA

        var pixelBuffer: CVPixelBuffer?
        let bufAttrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String:        true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferWidthKey  as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let cvStatus = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, pixelFormat,
            bufAttrs as CFDictionary, &pixelBuffer
        )
        guard cvStatus == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw _err("CVPixelBufferCreate failed: \(cvStatus)")
        }

        // Draw CGImage into the pixel buffer
        CVPixelBufferLockBaseAddress(buffer, [])
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                       | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(
            data:             CVPixelBufferGetBaseAddress(buffer),
            width:            width,
            height:           height,
            bitsPerComponent: 8,
            bytesPerRow:      CVPixelBufferGetBytesPerRow(buffer),
            space:            CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:       bitmapInfo
        )
        ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        NSLog("[VanguardImgVid] image decoded %d×%d pixelFormat=32BGRA", width, height)

        // ── 2. Configure AVAssetWriter ────────────────────────────────────────

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoProfileLevelKey:   AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw _err("Writer rejected video input — check pixel format compatibility")
        }
        writer.add(videoInput)

        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey           as String: width,
            kCVPixelBufferHeightKey          as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput:          videoInput,
            sourcePixelBufferAttributes: adaptorAttrs
        )

        let audioSettings: [String: Any] = [
            AVFormatIDKey:         kAudioFormatMPEG4AAC,
            AVSampleRateKey:       44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey:   128_000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw _err("Writer rejected audio input")
        }
        writer.add(audioInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // ── 3. Write video frames (same buffer repeated at 30fps) ─────────────

        let fps: Int32 = 30
        let timescale: CMTimeScale = fps
        let totalFrames = Int(durationSeconds * Double(fps))  // 15s × 30 = 450

        NSLog("[VanguardImgVid] writing %d frames (%gs @ %dfps)", totalFrames, durationSeconds, fps)

        for frame in 0..<totalFrames {
            // In non-real-time mode the adaptor is always ready; spin guard
            // protects against edge-case backpressure without blocking forever.
            var waited = 0
            while !adaptor.assetWriterInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
                waited += 1
                if waited > 400 {  // 2s timeout — should never trigger
                    NSLog("[VanguardImgVid] frame %d: adaptor not ready after 2s — aborting", frame)
                    throw _err("Video input stalled at frame \(frame)")
                }
            }
            let pts = CMTime(value: CMTimeValue(frame), timescale: timescale)
            if !adaptor.append(buffer, withPresentationTime: pts) {
                let msg = writer.error?.localizedDescription ?? "unknown"
                NSLog("[VanguardImgVid] frame %d append failed: %@", frame, msg)
                throw _err("Frame append failed at \(frame): \(msg)")
            }
        }
        videoInput.markAsFinished()
        NSLog("[VanguardImgVid] frame pump complete")

        // ── 4. Write audio with loop-fill ─────────────────────────────────────

        try _writeAudio(
            audioInput:        audioInput,
            audioPath:         audioPath,
            audioStartSeconds: audioStartSeconds,
            durationSeconds:   durationSeconds
        )
        audioInput.markAsFinished()

        // ── 5. Finish ─────────────────────────────────────────────────────────

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()

        guard writer.status == .completed else {
            let msg = writer.error?.localizedDescription ?? "status \(writer.status.rawValue)"
            throw _err("AVAssetWriter finish failed: \(msg)")
        }
        NSLog("[VanguardImgVid] export success → %@", outputPath)
    }

    // MARK: - Audio write with loop-fill

    private static func _writeAudio(
        audioInput:        AVAssetWriterInput,
        audioPath:         String,
        audioStartSeconds: Double,
        durationSeconds:   Double
    ) throws {
        let audioURL   = URL(fileURLWithPath: audioPath)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let srcTrack = audioAsset.tracks(withMediaType: .audio).first else {
            // No audio track — leave audio input empty rather than throw.
            // The output will have a silent audio track, which is valid.
            NSLog("[VanguardImgVid] no audio track in source — skipping audio")
            return
        }

        let srcDuration    = audioAsset.duration.seconds
        let targetScale: CMTimeScale = 44100
        var writtenSeconds = 0.0
        var loopPass       = 0

        NSLog("[VanguardImgVid] audio src=%.2fs start=%.2fs target=%.2fs",
              srcDuration, audioStartSeconds, durationSeconds)

        while writtenSeconds < durationSeconds {
            let remaining = durationSeconds - writtenSeconds
            let loopStart = (loopPass == 0) ? audioStartSeconds : 0.0
            let loopAvail = max(0.0, srcDuration - loopStart)
            guard loopAvail > 0.001 else { break }  // degenerate / exhausted source

            let segDur = min(loopAvail, remaining)
            let readRange = CMTimeRange(
                start:    CMTimeMakeWithSeconds(loopStart, preferredTimescale: targetScale),
                duration: CMTimeMakeWithSeconds(segDur,    preferredTimescale: targetScale)
            )

            let reader = try AVAssetReader(asset: audioAsset)
            reader.timeRange = readRange

            let trackOutput = AVAssetReaderTrackOutput(track: srcTrack, outputSettings: [
                AVFormatIDKey:               kAudioFormatLinearPCM,
                AVSampleRateKey:             44100.0,
                AVNumberOfChannelsKey:       2,
                AVLinearPCMBitDepthKey:      16,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsFloatKey:       false,
                AVLinearPCMIsBigEndianKey:   false,
            ])
            trackOutput.alwaysCopiesSampleData = false
            reader.add(trackOutput)
            reader.startReading()

            // PTS base for this loop pass (in output timeline)
            let ptsBase  = CMTimeMakeWithSeconds(writtenSeconds, preferredTimescale: targetScale)
            // Source offset to subtract from each sample's source PTS
            let srcOffset = CMTimeMakeWithSeconds(loopStart, preferredTimescale: targetScale)

            while reader.status == .reading {
                guard let sample = trackOutput.copyNextSampleBuffer() else { break }

                var waited = 0
                while !audioInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.005)
                    waited += 1
                    if waited > 400 { break }
                }
                guard audioInput.isReadyForMoreMediaData else { break }

                // Rebase PTS: outputPTS = ptsBase + (sourcePTS - srcOffset)
                let srcPTS  = CMSampleBufferGetPresentationTimeStamp(sample)
                let newPTS  = CMTimeAdd(ptsBase, CMTimeSubtract(srcPTS, srcOffset))
                let newDur  = CMSampleBufferGetDuration(sample)

                var timing = CMSampleTimingInfo(
                    duration:              newDur,
                    presentationTimeStamp: newPTS,
                    decodeTimeStamp:       CMTime.invalid
                )
                var rebased: CMSampleBuffer?
                let status = CMSampleBufferCreateCopyWithNewTiming(
                    allocator:              kCFAllocatorDefault,
                    sampleBuffer:           sample,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray:      &timing,
                    sampleBufferOut:        &rebased
                )
                guard status == noErr, let r = rebased else { continue }
                audioInput.append(r)
            }
            reader.cancelReading()

            writtenSeconds += segDur
            loopPass       += 1
            NSLog("[VanguardImgVid] audio pass=%d written=%.2fs", loopPass, writtenSeconds)
        }
        NSLog("[VanguardImgVid] audio done total=%.2fs passes=%d", writtenSeconds, loopPass)
    }

    // MARK: - Factory error

    private static func _err(_ msg: String) -> NSError {
        NSError(domain: "VanguardImageToVideo", code: -1,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
