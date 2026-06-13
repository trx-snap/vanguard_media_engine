// VGHeuristicMaskProvider.h
// Phase 9A — Heuristic conformer of VGMaskProvider.
//
// Wraps the existing CPU-based heuristic segmentation pipeline:
//   VGFaceDetectionProvider (async Vision landmark detection)
//   VGSkinMaskGenerator     (6-pass CPU mask rasterization)
//
// This class owns the generation-tracking, chroma-downsample buffer,
// and mask-detection timing that previously lived inside VGSegmentationNode.
// Moving this state here is necessary so a future Phase 9B CoreML provider
// can replace the entire heuristic path without touching VGSegmentationNode.
//
// Threading contract:
//   submitFrame:pts:generation: is designed to be called from the render
//   thread. It dispatches all Vision and mask work asynchronously and
//   returns immediately — it NEVER blocks the caller.
//   latestMask is atomic — safe to read from the render thread.
//
// Heuristic parameters:
//   cadenceFrames=3. Face detection fires every 3rd frame (~10 Hz at 30fps).
//   All tuning constants are frozen as per DEC-122.
//
// Phase 9B note:
//   VGFaceDetectionProvider and VGSkinMaskGenerator must NOT be modified
//   in Phase 9A. This class is the only new code touching those objects.

#pragma once
#import "VGMaskProvider.h"

NS_ASSUME_NONNULL_BEGIN

/// Phase 9A heuristic provider.
/// Owns VGFaceDetectionProvider, VGSkinMaskGenerator, and all associated
/// timing/generation/chroma state that previously resided in VGSegmentationNode.
@interface VGHeuristicMaskProvider : NSObject <VGMaskProvider>

/// Latest generated mask. Atomic — safe to read from any thread.
/// nil until the first mask generation completes.
@property (atomic, readonly, nullable) VGSkinMask *latestMask;

/// Designated initializer.
- (instancetype)init NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
