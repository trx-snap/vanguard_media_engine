// VGDuetSourceVideoDecoder.swift
// VG-DUET-SLICE-3: Duet source video decoder & frame provider seam.
//
// Responsibilities:
//   - Encapsulates AVAssetReader and AVAssetReaderTrackOutput.
//   - Uses 32BGRA, Metal compatibility, IOSurface backing, alwaysCopiesSampleData = false.
//   - Prepares and primes first frame at trimStartMs.
//   - Steps / seeks on demand (no free-running decode loop).
//   - Holds last decoded frame for display / composition.
//   - Safe, idempotent resource release.

import AVFoundation
import CoreMedia
import CoreVideo

// MARK: - Frame provider seam

protocol VGDuetFrameProvider: AnyObject {
    var lastPixelBuffer: CVPixelBuffer? { get }
    var lastPresentationTimeMs: Int { get }
    func stepFrame(targetPtsMs: Int) -> CVPixelBuffer?
    func seek(to ptsMs: Int) throws
    func release()
}

// MARK: - Decoder errors

enum VGDuetDecoderError: Error, LocalizedError {
    case assetMissingVideoTrack
    case readerInitializationFailed(String)
    case readingFailed(String)
    case released

    var errorDescription: String? {
        switch self {
        case .assetMissingVideoTrack:
            return "Asset does not contain a video track."
        case .readerInitializationFailed(let msg):
            return "Failed to initialize AVAssetReader: \(msg)"
        case .readingFailed(let msg):
            return "Failed to read sample buffer: \(msg)"
        case .released:
            return "Decoder has been released."
        }
    }
}

// MARK: - Source video decoder

final class VGDuetSourceVideoDecoder: VGDuetFrameProvider {

    let url: URL
    let trimStartMs: Int
    let trimEndMs: Int

    private(set) var lastPixelBuffer: CVPixelBuffer?
    private(set) var lastPresentationTimeMs: Int = 0

    private var asset: AVURLAsset?
    private var assetReader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var videoTrack: AVAssetTrack?
    private var isReleased: Bool = false

    init(url: URL, trimStartMs: Int, trimEndMs: Int) {
        self.url = url
        self.trimStartMs = trimStartMs
        self.trimEndMs = trimEndMs
        self.lastPresentationTimeMs = trimStartMs
    }

    /// Prepares the decoder and primes the first frame at trimStartMs.
    func prepare() throws {
        guard !isReleased else { throw VGDuetDecoderError.released }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        self.asset = asset

        guard let track = asset.tracks(withMediaType: .video).first else {
            throw VGDuetDecoderError.assetMissingVideoTrack
        }
        self.videoTrack = track

        try setupReader(startPtsMs: trimStartMs)
        // Prime first frame at or after trimStartMs
        _ = try readNextFrame()
    }

    private func setupReader(startPtsMs: Int) throws {
        guard let track = videoTrack, let asset = asset else {
            throw VGDuetDecoderError.assetMissingVideoTrack
        }

        if let existing = assetReader {
            if existing.status == .reading {
                existing.cancelReading()
            }
            self.assetReader = nil
            self.trackOutput = nil
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VGDuetDecoderError.readerInitializationFailed(error.localizedDescription)
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        if reader.canAdd(output) {
            reader.add(output)
        } else {
            throw VGDuetDecoderError.readerInitializationFailed("Cannot add track output to AVAssetReader")
        }

        let startTime = CMTime(value: Int64(startPtsMs), timescale: 1000)
        reader.timeRange = CMTimeRange(start: startTime, duration: CMTime.positiveInfinity)

        guard reader.startReading() else {
            let desc = reader.error?.localizedDescription ?? "unknown error"
            throw VGDuetDecoderError.readerInitializationFailed(desc)
        }

        self.assetReader = reader
        self.trackOutput = output
    }

    private func readNextFrame() throws -> CVPixelBuffer? {
        guard !isReleased else { return nil }
        guard let output = trackOutput, let reader = assetReader else { return nil }

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ptsMs = Int(CMTimeGetSeconds(pts) * 1000)

            if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                lastPixelBuffer = imageBuffer
                lastPresentationTimeMs = ptsMs
                return imageBuffer
            }
        }

        if reader.status == .failed {
            let desc = reader.error?.localizedDescription ?? "unknown"
            throw VGDuetDecoderError.readingFailed(desc)
        }
        return lastPixelBuffer
    }

    /// Advance decoding on demand until targetPtsMs. Holds and returns the frame.
    func stepFrame(targetPtsMs: Int) -> CVPixelBuffer? {
        guard !isReleased else { return nil }
        // If target is behind last decoded PTS, seek backwards
        if targetPtsMs < lastPresentationTimeMs {
            do {
                try seek(to: targetPtsMs)
                return lastPixelBuffer
            } catch {
                return lastPixelBuffer
            }
        }

        // If we already reached or passed the target PTS
        if lastPresentationTimeMs >= targetPtsMs && lastPixelBuffer != nil {
            return lastPixelBuffer
        }

        guard let output = trackOutput, let reader = assetReader else { return lastPixelBuffer }

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ptsMs = Int(CMTimeGetSeconds(pts) * 1000)

            if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                lastPixelBuffer = imageBuffer
                lastPresentationTimeMs = ptsMs
                if ptsMs >= targetPtsMs {
                    break
                }
            }
        }

        return lastPixelBuffer
    }

    /// Seeks the decoder to the requested PTS ms and decodes the frame.
    func seek(to ptsMs: Int) throws {
        guard !isReleased else { throw VGDuetDecoderError.released }
        let clampedPts = max(trimStartMs, min(ptsMs, trimEndMs))
        try setupReader(startPtsMs: clampedPts)
        _ = try readNextFrame()
    }

    /// Releases all AVAssetReader resources cleanly.
    func release() {
        guard !isReleased else { return }
        isReleased = true
        if let reader = assetReader, reader.status == .reading {
            reader.cancelReading()
        }
        assetReader = nil
        trackOutput = nil
        videoTrack = nil
        asset = nil
        lastPixelBuffer = nil
    }
}
