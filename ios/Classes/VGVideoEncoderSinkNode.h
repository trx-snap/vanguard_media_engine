// VGVideoEncoderSinkNode.h
// vanguard_media_engine — Phase 5C-4
//
// VGVideoEncoderSinkNode is the concrete VGFrameSink for offline video export.
// It encodes CVPixelBuffer frames via VanguardVideoToolboxEncoder (Phase 5B)
// and writes compressed CMSampleBuffers to AVAssetWriter.
//
// Architecture:
//   - Conforms to VGFrameSink (extends VGNode). Role: VGNodeRoleSink.
//   - Input port: "video_in" / VGMediaTypeVideo / required.
//   - Initialized with output URL + VGExportProfile.
//   - Uses VGEncoderUsageOffline (B-frames, no realtime hint).
//   - packetHandler is nil — no Annex-B NAL camera path needed for export.
//
// presentEnvelope: contract:
//   - Called synchronously on VGExportScheduler's serial export queue.
//   - Wraps CVPixelBuffer in VGRetainedBuffer before encode (DEC-V2-010).
//   - Blocks on dispatch_semaphore until frameCompletionHandler signals (error/drop)
//     OR encodedSampleHandler signals (success, AFTER appendSampleBuffer).
//   - Does NOT return until the compressed sample has been written (on success).
//
// Semaphore signal ordering (corrected, critical):
//   vtOutputCallback order (Phase 5B):
//     1. frameCompletionHandler — UNCONDITIONAL
//     2. encodedSampleHandler  — SUCCESS ONLY
//   Signal rule:
//     - error/drop: signal in frameCompletionHandler (no sample handler will follow)
//     - success: signal in encodedSampleHandler AFTER appendSampleBuffer
//   This guarantees presentEnvelope returns only after write completes.
//
// AVAssetWriter / AVAssetWriterInput creation:
//   - Writer created eagerly in prepareWithContext: (no startWriting yet).
//   - AVAssetWriterInput created LAZILY on first encoded sample using
//     assetWriterInputWithMediaType:outputSettings:sourceFormatHint: with
//     CMSampleBufferGetFormatDescription from the first VT-encoded CMSampleBuffer.
//   - addInput + startWriting + startSessionAtSourceTime all happen in lazy block.
//   - Apple constraint: addInput must precede startWriting.
//
// Forbidden:
//   - No VGGraphSchedulerV2
//   - No VanguardFileMediaSource
//   - No VanguardGraphRuntime
//   - No VanguardMetalRenderer
//   - No VGFrameDelegate / didReceiveRawFrame
//
// Phase 5C-4: Encoder + writer sink only. No audio. No time remapping.
// PORTABLE: VGFrameSink contract is platform-agnostic.
// PLATFORM: AVFoundation, VideoToolbox, CoreMedia, CoreVideo.

#pragma once

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGExportProfile.h>
#import <UMF/VGExportManifest.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGVideoEncoderSinkNode ───────────────────────────────────────────────────
/// Concrete VGFrameSink that encodes and writes frames for offline export.
///
/// Uses VanguardVideoToolboxEncoder (Phase 5B) for hardware H.264/HEVC encoding
/// and AVAssetWriter for MP4 muxing. Designed exclusively for use with
/// VGExportScheduler (pull-mode) via VGExportGraphFactory (Phase 5C-3).
///
/// Do NOT use with VGGraphSchedulerV2 (push-mode) or any realtime scheduler.
@interface VGVideoEncoderSinkNode : NSObject <VGFrameSink>

// ─── Designated initializer ───────────────────────────────────────────────────

/// Initialize the encoder sink node.
///
/// Does NOT create the encoder or writer session — call prepareWithContext:completion:
/// before presenting any frames.
///
/// @param outputURL  File URL for the output .mp4. Parent directory must exist.
///                   If a file already exists at this URL, it will be deleted
///                   during prepareWithContext: (Apple: AVAssetWriter cannot overwrite).
/// @param profile    Encoder configuration. Must be an offline profile
///                   (usage == VGEncoderUsageOffline).
- (instancetype)initWithOutputURL:(NSURL *)outputURL
                          profile:(VGExportProfile *)profile NS_DESIGNATED_INITIALIZER;

/// Unavailable. Use initWithOutputURL:profile:.
- (instancetype)init NS_UNAVAILABLE;

// ─── State ────────────────────────────────────────────────────────────────────

/// YES after prepareWithContext:completion: succeeds, NO after invalidate.
@property (nonatomic, readonly, getter=isReady) BOOL ready;

/// Number of frames successfully submitted to the encoder (incremented per
/// presentEnvelope: call after semaphore wake, including drops).
@property (nonatomic, readonly) NSInteger framesSubmitted;

// ─── Export finalization ──────────────────────────────────────────────────────

/// Finalize the export: flush encoder, finish writing, produce manifest.
///
/// MUST be called after VGExportScheduler signals EOS and BEFORE invalidate.
/// Blocks until AVAssetWriter.finishWriting completes (30s timeout).
///
/// Steps:
///   1. [encoder completeFrames]       — flush all pending VT callbacks
///   2. [writerInput markAsFinished]   — no more samples
///   3. [writer finishWriting...]      — mux and finalize MP4
///   4. Build VGExportManifest
///
/// @param outError Set to a descriptive NSError on failure.
/// @return VGExportManifest on success, nil on failure.
- (nullable VGExportManifest *)finalizeExportWithError:(NSError *_Nullable *_Nullable)outError;

@end

NS_ASSUME_NONNULL_END
