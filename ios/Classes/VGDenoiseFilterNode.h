// VGDenoiseFilterNode.h
// vanguard_media_engine — Phase 10-D
//
// Still-image CINoiseReduction denoise filter node.
//
// Applies Apple CINoiseReduction to a single CVPixelBuffer (in-place on
// a new allocation). The node runs at the source/full resolution, before
// any downscale transform, so noise is processed while fine detail is
// maximally preserved.
//
// Processing order in optimizeImage pipeline:
//   1. VGDenoiseFilterNode    ← this node (source-res, pre-resize)
//   2. VGTransformFilterNode  (resize to target canvas)
//   3. VGSharpenFilterNode    (post-resize, target-res)
//
// CINoiseReduction parameters:
//   inputNoiseLevel   – how aggressively noise is reduced. Range: [0.0, 0.06].
//                       Values above 0.06 smear fine detail.
//                       Conservative default: 0.02.
//   inputSharpness    – compensatory sharpness applied during noise reduction.
//                       Range: [0.0, 1.0]. Conservative default: 0.40.
//
// Failure-safe contract:
//   - If CINoiseReduction returns nil, the node passes the input buffer
//     through unchanged (+1 retain). Export continues on the baseline path.
//   - CIContext is file-static, created once via dispatch_once.
//     The context is NOT the VGTransformFilterNode shared context —
//     each node class owns its own static context per the Opus correction.
//
// Design rules (mirrors VGTransformFilterNode conventions):
//   • Conforms to <VanguardFilterNode> and <VGMetalFilterNode>.
//   • nil pool is valid — one-shot export allocates standalone CVPixelBuffer.
//   • processBuffer:atTime:device: returns a +1 CVPixelBuffer owned by caller.
//   • processEnvelope:device: takes/returns VGFrameEnvelope by value (struct).
//   • Passthrough (enabled=NO) returns input envelope/buffer unchanged.
//   • prepareWithCompletion: succeeds immediately (no async work).
//   • Buffer ownership: caller releases the returned buffer (DEC-44/RR-28).
//
// Phase 10-D — derivative-only enhancement. Master export is never modified.

#pragma once

#import "VanguardFilterNode.h"
#import <UMF/VGMetalFilterNode.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// CINoiseReduction denoise filter node for still-image derivative export.
///
/// Applies CINoiseReduction at source/full resolution, before any downscale
/// transform, to reduce noise while preserving maximum fine detail.
///
/// Failure-safe: if the CIFilter produces no output the input buffer is
/// returned unchanged (+1 retain) so export continues on the baseline path.
///
/// Designated initialiser is
/// `-initWithPool:device:noiseLevel:sharpness:`.
@interface VGDenoiseFilterNode : NSObject <VanguardFilterNode, VGMetalFilterNode>

// ─── VGMediaNode / VGMetalFilterNode required properties ──────────────────────

/// Stable node identifier (UUID string, set at init time).
@property (nonatomic, readonly, copy) NSString *nodeId;

/// Node type tag for logging. Value: @"VGDenoiseFilterNode".
@property (nonatomic, readonly, copy) NSString *nodeType;

/// Human-readable name. Value: @"Denoise".
@property (nonatomic, readonly, copy) NSString *filterName;

/// When NO, returns the input envelope unchanged (zero cost). Default: YES.
@property (nonatomic, assign) BOOL enabled;

/// Whether this filter is expensive enough to be disabled under thermal pressure.
/// CINoiseReduction at source resolution is computationally moderate. Returns YES.
@property (nonatomic, readonly) BOOL isExpensive;

/// Estimated GPU cost in ms at 1080p BGRA on A14 at nominal thermal state.
/// CINoiseReduction at source resolution: ~10–30ms. Conservative: 15.0ms.
@property (nonatomic, readonly) float estimatedGPUCostMs;

// ─── Designated initialiser ───────────────────────────────────────────────────

/// Designated initialiser.
///
/// @param pool        The renderer's CVPixelBufferPool (nullable for one-shot export).
/// @param device      The shared MTLDevice.
/// @param noiseLevel  CINoiseReduction inputNoiseLevel. Clamped to [0.0, 0.06].
///                    Pass 0.02 for the conservative default.
/// @param sharpness   CINoiseReduction inputSharpness. Clamped to [0.0, 1.0].
///                    Pass 0.40 for the conservative default.
- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
                  noiseLevel:(double)noiseLevel
                   sharpness:(double)sharpness NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
