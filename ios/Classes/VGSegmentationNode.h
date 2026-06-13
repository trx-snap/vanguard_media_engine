// VGSegmentationNode.h
// Phase 4F — Step 1: VGSegmentationNode extraction (DEC-100).
// Phase 9A — Provider-backed architecture (VGMaskProvider).
//
// First-class VGMediaNode for segmentation mask production.
// CPU-only — does not create or modify the video pixel buffer;
// only reads it for luma/chroma analysis.
//
// Graph position:
//   Source → VGSegmentationNode → BeautyV2FilterGroup → Sink
//
// Responsibilities:
//   - Owns a VGMaskProvider (default: VGHeuristicMaskProvider)
//   - Submits frames to the provider each envelope
//   - Reads latestMask from the provider and packages into metadata
//   - Attaches mask data to VGFrameEnvelope.metadata via lifecycle helpers
//   - Forwards the video payload unchanged
//
// Phase 9A scope:
//   - Provider protocol is narrow: submitFrame:pts:generation: / latestMask
//   - VGSegmentationResult is NOT introduced in this slice
//   - All CVPixelBuffer wrapping and metadata NSDictionary creation remain here
//   - Exact downstream metadata contract preserved
//
// Architecture alignment:
//   DEC-100 — segmentation as first-class VGMediaNode
//   DEC-101 — VGFrameEnvelope.metadata side-channel
//   DEC-102 — mandatory lifecycle helpers
//   DEC-109 — conditional insertion (only when faceAwareEnabled=YES)
//   DEC-110 — VGSkinMask metadata payload (Step 1 bridge, see below)
//   RR-86   — metadata ownership safety
//   RR-92   — legacy processBuffer: path fallback (see below)
//   RR-93   — VanguardFilterNode conformance bridge (see below)
//
// Conformance (Step 1 bridge — DEC-111 / RR-93):
//   VGMetalFilterNode (primary — used by scheduler and image processor)
//   VanguardFilterNode (legacy — required by renderer processBuffer: path)
//
//   In the UMF target architecture, VGSegmentationNode should conform ONLY to
//   VGMediaNode/VGMetalFilterNode. VanguardFilterNode conformance is a
//   TEMPORARY Step 1 bridge required because the renderer's legacy filter chain
//   dispatch iterates `id<VanguardFilterNode>`. This conformance should be
//   removed when the legacy processBuffer: path is retired (follow-up task).
//
// Legacy processBuffer: path (RR-92):
//   VGSegmentationNode.processBuffer: runs face detection and mask generation
//   but CANNOT propagate metadata to downstream nodes (the legacy API returns
//   only a CVPixelBufferRef). Metadata is created and immediately released.
//   This path is NOT used for production face-aware BeautyV2 because:
//     (1) Production video: scheduler path (processEnvelope:) is used when
//         VanguardGraphRuntime is active (delegate is wired).
//     (2) Image path: VanguardImageProcessor uses processEnvelope: directly.
//     (3) Legacy renderer path: only fires when no scheduler delegate is
//         installed — this is a non-production/dev-only configuration.
//   Face-aware Beauty V2 requires the scheduler or image path.
//
// Metadata payload (Step 1 bridge — DEC-110):
//   The metadata NSDictionary carries a VGSkinMask ObjC object directly
//   under the key @"skinMask". This is a Step 1-only compatibility bridge.
//   The target contract (Phase A+) specifies skinMaskBuffer should be a
//   CVPixelBufferRef R8Unorm. Migration from VGSkinMask to CVPixelBufferRef
//   is a follow-up task for Phase A.1.

#pragma once
#import "VanguardFilterNode.h"
#import <UMF/VGMetalFilterNode.h>
#import <UMF/VGFrameEnvelope.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

@protocol VGMaskProvider;

NS_ASSUME_NONNULL_BEGIN

// ─── Metadata dictionary keys (Phase 4F — DEC-101) ───────────────────────────
// Keys used by VGSegmentationNode to populate envelope.metadata (NSDictionary).
// Consumers (e.g. BeautyV2FilterGroup) read these keys to extract mask data.

/// NSValue wrapping CMTime — PTS of the source frame that produced the mask.
extern NSString * const VGSegmentationMetadataKeyFaceMetaPTS;

/// NSNumber (uint64_t) — seek-generation stamp of the mask-producing frame.
extern NSString * const VGSegmentationMetadataKeyFaceMetaGeneration;

/// NSNumber (NSInteger) — number of faces detected.
extern NSString * const VGSegmentationMetadataKeyFaceCount;

/// VGSkinMask * — legacy Step 1 bridge (DEC-110, now fallback only).
/// Retained for backward compatibility. Prefer VGSegmentationMetadataKeySkinMaskBuffer.
extern NSString * const VGSegmentationMetadataKeySkinMask;

/// CVPixelBufferRef (kCVPixelFormatType_OneComponent8, quarter-res R8) — DEC-121.
/// Primary mask carrier after CVPixelBufferRef migration.
/// The buffer is retrained by the metadata NSDictionary (via CFBridgingRelease transfer).
/// Consumers must lock with kCVPixelBufferLock_ReadOnly before reading pixel data.
extern NSString * const VGSegmentationMetadataKeySkinMaskBuffer;

// ─── VGSegmentationNode ──────────────────────────────────────────────────────

@interface VGSegmentationNode : NSObject <VanguardFilterNode, VGMetalFilterNode>

// ─── VGMediaNode ─────────────────────────────────────────────────────────────

/// Stable node identifier.
@property (nonatomic, readonly, copy) NSString *nodeId;

/// Node type tag for logging. Value: @"VGSegmentationNode".
@property (nonatomic, readonly, copy) NSString *nodeType;

// ─── VGMetalFilterNode ───────────────────────────────────────────────────────

/// Human-readable name for logging. Value: @"Segmentation".
@property (nonatomic, readonly, copy) NSString *filterName;

/// When NO, processEnvelope:device: returns input envelope unchanged (no metadata).
@property (nonatomic, assign) BOOL enabled;

// ─── Initializers ────────────────────────────────────────────────────────────

/// Designated initializer.
/// Instantiates the default VGHeuristicMaskProvider internally.
/// @param pool   Runtime session pool (not used by this node — passed for protocol compat).
/// @param device Shared MTLDevice (not used by this CPU-only node).
- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device NS_DESIGNATED_INITIALIZER;

/// Dependency-injection initializer for testing.
/// Accepts a custom VGMaskProvider conformer instead of the default heuristic provider.
/// Use this initializer to inject a stub/mock in unit tests.
/// @param pool     Runtime session pool (not used by this node).
/// @param device   Shared MTLDevice (not used by this CPU-only node).
/// @param provider A VGMaskProvider conformer to delegate frame/mask work to.
- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
                    provider:(id<VGMaskProvider>)provider;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
