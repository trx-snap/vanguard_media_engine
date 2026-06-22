// VGROIEntropySuppressionFilterNode.h
// vanguard_media_engine — Phase 10-D.4A
//
// ROI-aware background entropy suppression filter node.
//
// Integrates into the VGImageExportSession filter chain (between
// VGTransformFilterNode and VGSharpenFilterNode) to apply perceptual
// compression preprocessing:
//
//   Foreground (ROI / face region):   passed through unchanged.
//   Background (outside ROI):         blurred by CIGaussianBlur to reduce
//                                      high-frequency entropy before JPEG encoding.
//
// If sharpenROIOnly is YES, a CIUnsharpMask pass is applied to the
// foreground only (masked by the ROI), replacing the downstream
// VGSharpenFilterNode for that pass.
//
// When this node is inserted into the filter chain, VGSharpenFilterNode
// is still placed downstream; the Swift integration sets its intensity
// to 0.0 for passes where sharpenROIOnly applies, leaving the sharpening
// entirely to this node.
//
// Chain position (when ROI is active):
//   [VGDenoiseFilterNode] → [VGTransformFilterNode] →
//   [VGROIEntropySuppressionFilterNode] → [VGSharpenFilterNode(intensity=0)]
//
// Mask:
//   The `maskImage` is a grayscale CIImage produced by VGStillImageROIProcessor.
//   White (1.0) = foreground / face. Black (0.0) = background.
//   The mask has already been upscaled and feathered to canvas resolution.
//
// Core Image blending:
//   1. Apply CIGaussianBlur to the entire input at `backgroundBlurRadius`.
//   2. Use CIBlendWithMask to composite: result = mask*sharp + (1-mask)*blurred.
//      Where `sharp` = input (foreground passthrough or optionally sharpened).
//
// Failure-safe contract (matches all other filter nodes):
//   - If any CIFilter operation fails, the input buffer is returned unchanged (+1).
//   - A missing or nil maskImage causes the node to behave as a pure passthrough.
//   - Export always continues, never aborts on ROI failure.
//
// Design rules (mirrors VGSharpenFilterNode):
//   • Conforms to <VanguardFilterNode> and <VGMetalFilterNode>.
//   • nil pool is valid for one-shot export.
//   • processBuffer:atTime:device: returns +1 CVPixelBuffer owned by caller.
//   • processEnvelope:device: takes/returns VGFrameEnvelope by value (struct).
//   • Passthrough (enabled=NO or maskImage=nil) returns input unchanged.
//   • prepareWithCompletion: succeeds immediately.
//   • Buffer ownership: caller releases the returned buffer (DEC-44/RR-28).
//
// Phase 10-D.4A — derivative-only. Master export is never modified.

#pragma once

#import "VanguardFilterNode.h"
#import <UMF/VGMetalFilterNode.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

/// ROI-aware background entropy suppression filter node.
///
/// Blurs the background (non-face) region to reduce JPEG entropy while
/// preserving full sharpness in the foreground (face/head/hair) region.
///
/// Designated initialiser is `-initWithPool:device:maskImage:backgroundBlurRadius:sharpenROIOnly:sharpenIntensity:sharpenRadius:`.
@interface VGROIEntropySuppressionFilterNode : NSObject <VanguardFilterNode, VGMetalFilterNode>

// ─── VGMediaNode / VGMetalFilterNode required properties ──────────────────────

/// Stable node identifier (UUID string, set at init time).
@property (nonatomic, readonly, copy) NSString *nodeId;

/// Node type tag for logging. Value: @"VGROIEntropySuppressionFilterNode".
@property (nonatomic, readonly, copy) NSString *nodeType;

/// Human-readable name. Value: @"ROIEntropySuppression".
@property (nonatomic, readonly, copy) NSString *filterName;

/// When NO, returns the input envelope unchanged (zero cost). Default: YES.
@property (nonatomic, assign) BOOL enabled;

/// Whether this filter is expensive enough to be disabled under thermal pressure.
/// CIGaussianBlur at canvas resolution is moderate. Returns NO.
@property (nonatomic, readonly) BOOL isExpensive;

/// Estimated GPU cost in ms at 1080p BGRA on A14 at nominal thermal state.
/// Blur + blend: ~5ms. Conservative: 6.0ms.
@property (nonatomic, readonly) float estimatedGPUCostMs;

// ─── Designated initialiser ───────────────────────────────────────────────────

/// Designated initialiser.
///
/// @param pool                  CVPixelBufferPool (nullable for one-shot export).
/// @param device                The shared MTLDevice.
/// @param maskImage             Grayscale CIImage mask at canvas resolution.
///                              White=foreground, black=background.
///                              Pass nil to disable ROI (pure passthrough).
/// @param backgroundBlurRadius  CIGaussianBlur radius applied to the background.
///                              Pass 0.0 for no blurring (mild-suppression pass).
/// @param sharpenROIOnly        When YES, applies CIUnsharpMask to the foreground
///                              before blending. Replaces downstream sharpening.
/// @param sharpenIntensity      CIUnsharpMask intensity (ignored when sharpenROIOnly=NO).
///                              Clamped to [0.0, 0.50].
/// @param sharpenRadius         CIUnsharpMask radius (ignored when sharpenROIOnly=NO).
///                              Clamped to [0.0, 1.5].
- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
                   maskImage:(nullable CIImage *)maskImage
       backgroundBlurRadius:(double)backgroundBlurRadius
              sharpenROIOnly:(BOOL)sharpenROIOnly
             sharpenIntensity:(double)sharpenIntensity
               sharpenRadius:(double)sharpenRadius NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
