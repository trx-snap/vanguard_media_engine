// VGSkinMaskGenerator.h
// Phase 4C — Step 2: CPU skin mask generation from face landmarks (DEC-62/64).
//
// Produces a quarter-resolution R8 (uint8) soft mask from face detection
// results. The mask is rasterized on CPU — no GPU compute pass needed.
//
// Mask values:
//   255 = full skin (beauty effect applies at full strength)
//   0   = non-skin (beauty effect disabled — original pixel preserved)
//   1–254 = feathered transition zone
//
// Threading contract:
//   - submitResult:sourceWidth:sourceHeight: is the primary entry point.
//     It dispatches mask generation to a private serial queue and returns
//     immediately — it NEVER blocks the caller (render thread safe).
//   - If generation is already in-flight, the request is coalesced (skipped).
//   - latestMask is atomic — safe to read from the render thread.
//   - All vImage / rasterization work runs on the private mask queue.
//
// Architecture alignment:
//   DEC-62 — quarter-res R8Unorm soft mask
//   DEC-63 — final-blend mask (Step 3 will consume this mask)
//   DEC-64 — CPU-side mask rasterization (no GPU mask pass)
//   DEC-65 — 4-pass pipeline preserved (no new pass)
//   RR-55  — mask edge leakage (mitigated by Gaussian feathering)
//   RR-57  — temporal mask flicker (mitigated by reuse of cached mask)
//   RR-59  — R8 precision banding (mitigated by bilinear sampling in Step 3)

#pragma once
#import <Foundation/Foundation.h>
#import <CoreMedia/CMTime.h>

@class VGFaceDetectionResult;

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// VGSkinMask — immutable snapshot of a generated mask
// ---------------------------------------------------------------------------

@interface VGSkinMask : NSObject

/// Mask pixel data (R8 uint8). Length = width × height.
/// The data is owned by this object — safe to read after the generator
/// has moved on to the next frame.
@property (nonatomic, readonly) const uint8_t *data;

/// Mask dimensions (quarter of source frame).
@property (nonatomic, readonly) size_t width;
@property (nonatomic, readonly) size_t height;

/// Bytes per row (== width for R8 format, no padding).
@property (nonatomic, readonly) size_t bytesPerRow;

/// Presentation timestamp of the source frame that produced this mask.
@property (nonatomic, readonly) CMTime sourcePTS;

/// Number of faces that contributed to this mask.
@property (nonatomic, readonly) NSInteger faceCount;

- (instancetype)init NS_UNAVAILABLE;

@end

// ---------------------------------------------------------------------------
// VGSkinMaskGenerator — CPU mask rasterizer
// ---------------------------------------------------------------------------

@interface VGSkinMaskGenerator : NSObject

/// Latest generated mask. Atomic — safe to read from any thread.
/// nil until the first generation completes.
@property (atomic, readonly, nullable) VGSkinMask *latestMask;

/// Feather sigma in quarter-res pixels. Default: 8.
/// Controls the softness of mask edges. Higher = softer.
@property (nonatomic, assign) float featherSigma;

/// Face oval inset factor [0, 1]. Default: 0.05 (5% inset).
/// Shrinks the face oval slightly to avoid mask leakage at edges.
@property (nonatomic, assign) float faceOvalInset;

/// Feature exclusion padding factor [0, 1]. Default: 0.15 (15% expansion).
/// Expands exclusion zones around eyes/lips/brows.
@property (nonatomic, assign) float featureExclusionPadding;

/// EMA smoothing alpha [0, 1]. Default: 0.3.
/// Controls how fast the mask converges to new detections.
/// Lower = smoother/slower, higher = more responsive.
/// (Phase 4C Step 4 — RR-57 temporal flicker mitigation)
@property (nonatomic, assign) float smoothingAlpha;

/// Submit a face detection result for async mask generation.
///
/// This method dispatches mask rasterization to a private serial queue
/// and returns immediately — it NEVER blocks the render thread.
/// If a previous generation is still in-flight, the request is coalesced
/// (skipped). The latest mask is published atomically when complete.
///
/// @param result       Face detection result (faces + landmarks). Retained
///                     for the duration of async generation.
/// @param sourceWidth  Full-resolution source frame width.
/// @param sourceHeight Full-resolution source frame height.
- (void)submitResult:(VGFaceDetectionResult *)result
         sourceWidth:(size_t)sourceWidth
        sourceHeight:(size_t)sourceHeight;

/// Release internal buffers. Safe to call multiple times.
- (void)invalidate;

- (instancetype)init NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
