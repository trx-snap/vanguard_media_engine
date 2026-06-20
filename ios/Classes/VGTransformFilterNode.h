// VGTransformFilterNode.h
// vanguard_media_engine — Phase 10-C-3L.1D
//
// Still-image spatial transform filter node.
//
// Applies crop, rotation, flip, zoom/pan, and canvas framing to a single
// CVPixelBuffer via CIImage/CIContext. The output is a new CVPixelBuffer
// at exactly canvasWidth × canvasHeight pixels with a black background.
//
// Transform pipeline (matches UniversalEditor preview math exactly):
//   1. Crop         – optional normalized [x, y, w, h] region of input
//   2. Rotate       – quarterTurns × 90° CW (around image center)
//   3. Flip         – horizontal mirror around rotated-image vertical axis
//   4. Aspect-fill  – scale rotated/flipped source to fill canvas
//   5. Zoom         – multiply aspect-fill scale by `scale` parameter
//   6. Pan          – translate by (offsetX × maxDeltaX, offsetY × maxDeltaY)
//                    where maxDelta = max(0, (renderedDim - canvasDim) / 2)
//   7. Composite    – paint transformed image over solid black canvas
//   8. Crop/render  – render into output CVPixelBuffer at canvasW × canvasH
//
// Coordinate origin:
//   CIImage uses bottom-left origin (Y-up). Flutter preview uses top-left
//   (Y-down). offsetY is negated when converting to CIImage translation.
//
// Design rules (mirrors VGColorMatrixFilterNode conventions):
//   • Conforms to <VanguardFilterNode> (Phase 1) and <VGMetalFilterNode> (P3).
//   • nil pool is valid – one-shot export allocates standalone CVPixelBuffer.
//   • processBuffer:atTime:device: allocates new output at canvasW × canvasH.
//   • processEnvelope:device: wraps processBuffer:atTime:device:.
//   • Passthrough (enabled=NO) returns input with +1 retain unchanged.
//   • prepareWithCompletion: succeeds immediately (no async work).
//   • Buffer ownership: caller releases the returned buffer (DEC-44/RR-28).
//   • CIContext is a shared static instance; not created per-call.
//
// Phase 10-C-3L.1D — still-image export only.

#pragma once

#import "VanguardFilterNode.h"
#import <UMF/VGMetalFilterNode.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Spatial transform filter node for still-image export.
///
/// Applies a complete transform pipeline (crop → rotate → flip → aspect-fill
/// scale → zoom → pan → composite over black) and renders the result into
/// a new CVPixelBuffer of exactly `canvasWidth × canvasHeight` pixels.
///
/// Designated initialiser is `-initWithPool:device:parameters:`.
@interface VGTransformFilterNode : NSObject <VanguardFilterNode, VGMetalFilterNode>

// ─── VGMediaNode (additive — P3-1) ────────────────────────────────────────────

/// Stable node identifier (UUID string, set at init time).
@property (nonatomic, readonly, copy) NSString *nodeId;

/// Node type tag for logging. Value: @"VGTransformFilterNode".
@property (nonatomic, readonly, copy) NSString *nodeType;

/// Human-readable name. Default: "Transform".
@property (readonly, nonatomic, copy) NSString *filterName;

/// When NO, returns the input buffer unchanged (zero cost). Default: YES.
@property (nonatomic, assign) BOOL enabled;

// ─── Designated initialiser ───────────────────────────────────────────────────

/// Designated initialiser.
///
/// @param pool          The renderer's CVPixelBufferPool (nullable for one-shot export).
/// @param device        The shared MTLDevice.
/// @param canvasWidth   Output canvas pixel width.  Must be > 0.
/// @param canvasHeight  Output canvas pixel height. Must be > 0.
/// @param scale         Zoom multiplier relative to aspect-fill base. > 0.
/// @param offsetX       Normalized pan in X, [-1, 1]. Fraction of max pan travel.
/// @param offsetY       Normalized pan in Y, [-1, 1]. Fraction of max pan travel.
/// @param quarterTurns  Clockwise rotation in 90° steps [0–3]. Applied before flip.
/// @param flipX         Horizontal mirror after rotation.
/// @param cropRect      Optional normalized crop [x, y, w, h] applied before rotation.
///                      Pass nil to use the full source image.
- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
                 canvasWidth:(NSInteger)canvasWidth
                canvasHeight:(NSInteger)canvasHeight
                       scale:(double)scale
                     offsetX:(double)offsetX
                     offsetY:(double)offsetY
                quarterTurns:(NSInteger)quarterTurns
                       flipX:(BOOL)flipX
                    cropRect:(nullable NSArray<NSNumber *> *)cropRect NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
