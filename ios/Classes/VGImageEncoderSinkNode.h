// VGImageEncoderSinkNode.h
// vanguard_media_engine — Phase 5D-2
//
// VGImageEncoderSinkNode is the concrete VGFrameSink for still-image export.
// It encodes a single CVPixelBuffer to JPEG / HEIC / PNG via ImageIO's
// CGImageDestination API.
//
// Architecture:
//   - Conforms to VGFrameSink (extends VGNode). Role: VGNodeRoleSink.
//   - Input port: "video_in" / VGMediaTypeVideo / required.
//   - Initialized with output URL + VGImageExportProfile.
//   - Uses CGImageDestinationCreateWithURL for file output.
//   - presentEnvelope: called exactly once (single-frame still image).
//
// presentEnvelope: contract:
//   - Called synchronously on the session's export queue.
//   - Creates CGImage from CVPixelBuffer via VTCreateCGImageFromCVPixelBuffer.
//     This API manages its own internal pixel buffer access — no manual
//     CVPixelBufferLockBaseAddress / CVPixelBufferUnlockBaseAddress is required.
//   - Writes to CGImageDestination with quality / orientation properties.
//   - Does NOT retain the input buffer beyond this call.
//
// Format resolution:
//   - prepareWithContext: resolves VGImageExportProfile.resolvedFormatForPlatform.
//   - WebP requested → resolved to HEIC or JPEG (P0-FU-025).
//   - Manifest records actual encoded format, not requested format.
//
// Color profile policy:
//   - Preserve: uses source buffer's color space (default, always supported).
//   - ConvertToSRGB / PreserveDisplayP3IfSupported / FailIfUnsupported:
//     fail explicitly with a descriptive error in Phase 5D-2.
//     Full color conversion deferred to Phase 12+.
//
// Orientation policy:
//   - Preserve: embeds source EXIF orientation tag if available (default).
//   - ApplyAndRotate: fail explicitly with a descriptive error in Phase 5D-2.
//     Full pixel rotation deferred to Phase 12+.
//
// Forbidden:
//   - No AVAssetWriter
//   - No VanguardVideoToolboxEncoder
//   - No VGGraphSchedulerV2
//   - No VGExportScheduler
//   - No VanguardGraphRuntime / VanguardMetalRenderer
//   - No VGFrameDelegate / didReceiveRawFrame
//
// Phase 5D-2: Image encoder sink only. No audio. No session. No graph wiring.
// PORTABLE: VGFrameSink contract is platform-agnostic.
// PLATFORM: ImageIO (CGImageDestination), VideoToolbox (VTCreateCGImageFromCVPixelBuffer),
//           CoreVideo (CVPixelBuffer), CoreGraphics (CGImage, CGColorSpace).

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGImageExportProfile.h>
#import <UMF/VGImageExportManifest.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGImageEncoderSinkNode ───────────────────────────────────────────────────
/// Concrete VGFrameSink that encodes a single still image for offline export.
///
/// Uses CGImageDestination (ImageIO) for JPEG/HEIC/PNG encoding. Designed
/// for use with VGImageExportSession (Phase 5D-3) via pull-mode graph.
///
/// Do NOT use with VGGraphSchedulerV2 (push-mode) or any realtime scheduler.
/// For camera photo capture with live effects, see Phase 6A/6B (DEC-V2-069).
@interface VGImageEncoderSinkNode : NSObject <VGFrameSink>

// ─── Designated initializer ───────────────────────────────────────────────────

/// Initialize the image encoder sink node.
///
/// Does NOT create the CGImageDestination — call prepareWithContext:completion:
/// before presenting any frame.
///
/// @param outputURL  File URL for the output image. Parent directory must exist.
///                   If a file already exists at this URL, it will be deleted
///                   during prepareWithContext:.
/// @param profile    Image export configuration specifying format, quality,
///                   color profile policy, and orientation policy.
- (instancetype)initWithOutputURL:(NSURL *)outputURL
                          profile:(VGImageExportProfile *)profile NS_DESIGNATED_INITIALIZER;

/// Unavailable. Use initWithOutputURL:profile:.
- (instancetype)init NS_UNAVAILABLE;

// ─── State ────────────────────────────────────────────────────────────────────

/// YES after prepareWithContext:completion: succeeds, NO after invalidate.
@property (nonatomic, readonly, getter=isReady) BOOL ready;

/// Number of frames successfully encoded (should be exactly 0 or 1 for images).
@property (nonatomic, readonly) NSInteger framesSubmitted;

// ─── Export finalization ──────────────────────────────────────────────────────

/// Finalize the export: verify output file, produce manifest.
///
/// MUST be called after presentEnvelope: and BEFORE invalidate.
/// Reads the output file attributes to populate manifest dimensions and size.
///
/// @param outError Set to a descriptive NSError on failure.
/// @return VGImageExportManifest on success, nil on failure.
- (nullable VGImageExportManifest *)finalizeExportWithError:(NSError *_Nullable *_Nullable)outError;

@end

NS_ASSUME_NONNULL_END
