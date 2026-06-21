// VGSharpenFilterNode.h
// vanguard_media_engine — Phase 10-D
//
// Still-image CIUnsharpMask post-resize sharpening filter node.
//
// Applies Apple CIUnsharpMask to a single CVPixelBuffer after the downscale
// transform. Because sharpening runs at the target canvas resolution it
// restores micro-contrast lost during interpolation without amplifying
// the pre-resize high-frequency noise.
//
// Processing order in optimizeImage pipeline:
//   1. VGDenoiseFilterNode    (source-res, pre-resize)
//   2. VGTransformFilterNode  (resize to target canvas)
//   3. VGSharpenFilterNode    ← this node (post-resize, target-res)
//
// CIUnsharpMask parameters:
//   inputIntensity  – sharpening strength. Range: [0.0, 0.50].
//                     Values above 0.50 create visible halos.
//                     Conservative default: 0.15.
//   inputRadius     – radius of the blur used to detect edges, in pixels.
//                     Range: [0.0, 1.5].
//                     Conservative default: 0.65.
//
// Failure-safe contract:
//   - If CIUnsharpMask returns nil, the node passes the input buffer
//     through unchanged (+1 retain). Export continues on the baseline path.
//   - CIContext is file-static, created once via dispatch_once.
//     The context is NOT the VGTransformFilterNode or VGDenoiseFilterNode
//     shared contexts — each node class owns its own static context per
//     the Opus correction.
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

/// CIUnsharpMask post-resize sharpening filter node for still-image derivative export.
///
/// Applied after VGTransformFilterNode at target canvas resolution to restore
/// micro-contrast lost during interpolation.
///
/// Failure-safe: if the CIFilter produces no output the input buffer is
/// returned unchanged (+1 retain) so export continues on the baseline path.
///
/// Designated initialiser is
/// `-initWithPool:device:intensity:radius:`.
@interface VGSharpenFilterNode : NSObject <VanguardFilterNode, VGMetalFilterNode>

// ─── VGMediaNode / VGMetalFilterNode required properties ──────────────────────

/// Stable node identifier (UUID string, set at init time).
@property (nonatomic, readonly, copy) NSString *nodeId;

/// Node type tag for logging. Value: @"VGSharpenFilterNode".
@property (nonatomic, readonly, copy) NSString *nodeType;

/// Human-readable name. Value: @"Sharpen".
@property (nonatomic, readonly, copy) NSString *filterName;

/// When NO, returns the input envelope unchanged (zero cost). Default: YES.
@property (nonatomic, assign) BOOL enabled;

/// Whether this filter is expensive enough to be disabled under thermal pressure.
/// CIUnsharpMask at post-resize resolution is cheap. Returns NO.
@property (nonatomic, readonly) BOOL isExpensive;

/// Estimated GPU cost in ms at 1080p BGRA on A14 at nominal thermal state.
/// CIUnsharpMask at post-resize resolution: ~1–3ms. Conservative: 3.0ms.
@property (nonatomic, readonly) float estimatedGPUCostMs;

// ─── Designated initialiser ───────────────────────────────────────────────────

/// Designated initialiser.
///
/// @param pool       The renderer's CVPixelBufferPool (nullable for one-shot export).
/// @param device     The shared MTLDevice.
/// @param intensity  CIUnsharpMask inputIntensity. Clamped to [0.0, 0.50].
///                   Pass 0.15 for the conservative default.
/// @param radius     CIUnsharpMask inputRadius. Clamped to [0.0, 1.5].
///                   Pass 0.65 for the conservative default.
- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
                   intensity:(double)intensity
                      radius:(double)radius NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
