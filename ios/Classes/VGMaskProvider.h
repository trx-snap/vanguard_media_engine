// VGMaskProvider.h
// Phase 9A — Provider-backed segmentation architecture.
//
// Defines the narrow protocol that any mask provider must conform to.
// Phase 9A ships exactly one conformer: VGHeuristicMaskProvider.
// Phase 9B will add VGCoreMLMaskProvider (deferred — Opus approval required).
//
// Threading contract:
//   submitFrame:pts:generation: may be called from any thread.
//   latestMask is atomic — safe to read from any thread.
//   invalidate must be called on teardown.
//
// Ownership:
//   Providers own all internal detection/generation state.
//   Providers expose only VGSkinMask* — a lightweight, ARC-managed,
//   immutable snapshot. The caller (VGSegmentationNode) is responsible
//   for any CVPixelBuffer wrapping and metadata dictionary creation.
//
// Non-goals (Phase 9A):
//   No VGSegmentationResult — not introduced in this slice.
//   No CoreML, no model loading, no Vision changes.
//   No graph factory wiring.

#pragma once
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CMTime.h>

@class VGSkinMask;

NS_ASSUME_NONNULL_BEGIN

// ─── VGMaskProvider ──────────────────────────────────────────────────────────
//
// Narrow protocol for swappable mask providers.
// The first conformer is VGHeuristicMaskProvider (Phase 9A).
//
// Implementors must:
//   - Return an ARC-managed, immutable VGSkinMask snapshot from latestMask.
//   - Never block the caller of submitFrame:pts:generation:.
//   - Release all internal resources synchronously or lazily on invalidate.

@protocol VGMaskProvider <NSObject>

/// Latest generated mask. Thread-safe — may be nil until the first
/// generation completes or if no faces are detected.
@property (atomic, readonly, nullable) VGSkinMask *latestMask;

/// Submit a frame for processing (async — never blocks the caller).
///
/// @param pixelBuffer  The input video frame. The provider retains it
///                     for the duration of async processing.
/// @param pts          Presentation timestamp of the frame.
/// @param generation   Seek-generation stamp from the envelope. Changes
///                     signal seek/session restart; providers should reset
///                     temporal state accordingly.
- (void)submitFrame:(CVPixelBufferRef)pixelBuffer
                pts:(CMTime)pts
         generation:(uint64_t)generation;

/// Release internal resources. Safe to call multiple times.
/// After invalidate, submitFrame:pts:generation: must be a no-op.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
