// VGExportFileSourceNode.h
// vanguard_media_engine — Phase 5C-2
//
// VGExportFileSourceNode is a pull-only VGSourceNode backed by AVAssetReader.
// It provides synchronous frame production for offline export graphs.
//
// Architecture:
//   - Conforms to VGSourceNode (pull-mode only).
//   - Does NOT wrap VanguardFileMediaSource (zero coupling to playback source).
//   - Does NOT use push callbacks (_videoCallback, didReceiveRawFrame:).
//   - Does NOT conform to VGFrameDelegate.
//   - Does NOT use AVAssetWriter, VGVideoEncoderSinkNode, VGExportGraphFactory.
//   - Does NOT import VanguardGraphRuntime or VanguardMetalRenderer.
//
// Pull contract (Apple Framework Checks applied):
//   pullFrame: calls [AVAssetReaderTrackOutput copyNextSampleBuffer] synchronously.
//   copyNextSampleBuffer returns +1 CMSampleBufferRef (caller must CFRelease).
//   CMSampleBufferGetImageBuffer returns +0 CVPixelBufferRef.
//   Source retains the pixel buffer (+1) before releasing the sample buffer.
//   Source owns _lastDeliveredBuffer (+1); released on next pullFrame: or invalidate.
//   VGFrameEnvelope.payload.videoBuffer carries +0 per VGFrameEnvelope.h contract.
//
// Buffer lifetime (RR-36):
//   The delivered pixel buffer is valid until the next pullFrame: or invalidate call.
//   VGExportScheduler processes one frame at a time on its serial queue,
//   so the buffer is always valid through the transform chain and sink delivery.
//
// Phase 5C-2: File source skeleton. No audio. No time remapping. Sequential only.
//
// PORTABLE: Pull protocol is platform-agnostic.
// PLATFORM: AVFoundation — AVAssetReader, AVAssetReaderTrackOutput (iOS 14.0+).

#pragma once

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CGGeometry.h>
#import <UMF/VGSourceNode.h>
#import <UMF/VGMediaPort.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGExportFileSourceNode ───────────────────────────────────────────────────
/// Pull-mode file source node for offline export graphs.
///
/// Backed by AVAssetReader + AVAssetReaderTrackOutput for synchronous video
/// frame access via copyNextSampleBuffer. Suitable for use with VGExportScheduler
/// (VGClockPolicyPull) where the scheduler drives frame requests at encoder pace.
///
/// Not suitable for real-time playback — use VGFileSourceAdapter instead.
@interface VGExportFileSourceNode : NSObject <VGSourceNode>

// ─── Designated initializer ───────────────────────────────────────────────────

/// Initialize the export file source with an AVAsset.
///
/// Extracts the first video track from the asset, computes renderSize from
/// naturalSize + preferredTransform, and stores sourceFPS from nominalFrameRate.
/// Does NOT start reading — call prepareWithContext:completion: before pullFrame:.
///
/// @param asset  The source asset. Must be a local file asset with a video track.
- (instancetype)initWithAsset:(AVAsset *)asset NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// ─── Properties ───────────────────────────────────────────────────────────────

/// Natural render size of the video track after applying preferredTransform.
/// Valid after init. Zero if no video track found.
@property (nonatomic, readonly) CGSize renderSize;

/// Nominal frame rate from the video track (nominalFrameRate).
/// Falls back to 30.0 if the track reports 0.
@property (nonatomic, readonly) double sourceFPS;

@end

NS_ASSUME_NONNULL_END
