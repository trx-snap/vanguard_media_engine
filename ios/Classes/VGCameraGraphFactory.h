// VGCameraGraphFactory.h
// vanguard_media_engine — Phase 6A-1 / Phase 6E.1B / Phase 9B-3
//
// VGCameraGraphFactory is a pure graph-construction utility for the push-mode
// camera pipeline. It builds, validates, and plans a VGClockPolicyPush camera
// graph descriptor.
//
// All methods are class methods. This class must not be instantiated.
//
// Phase 6A-1: Structural implementation only.
// Phase 9B-3: Adds +makeSegmentationNodeWithPool:device: (ML provider gate).

#pragma once

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declarations
@class VanguardCameraMediaSource;
@class VanguardMetalRenderer;
@class VGSegmentationNode;
@protocol VGFrameSink;

/// Pure graph-construction factory for the V2 camera pipeline.
@interface VGCameraGraphFactory : NSObject

/// Construct, validate, and plan a camera graph.
///
/// Builds a linear camera graph:
///   - Source: wrapped in VGCameraSourceAdapter
///   - Filters: wrapped in VGLegacyFilterAdapter / VGMetadataNodeAdapter
///   - Sink: composite VGFanOutSink wrapping:
///       • VGRendererSinkAdapter (always, first child)
///       • platformViewSink (optional, second child when non-nil)
///       • VGRecordingSinkNode (always, last child, disabled — Phase 6E.1B)
///
/// Edge policy:
///   - Intermediate transform-to-transform edges: synchronous, no admission policy.
///   - Final edge to composite sink: synchronous with VGSinkAdmissionPolicy dropLatest.
///
/// @param source            The camera media source. Must not be nil.
/// @param filterChain       Optional ordered list of id<VanguardFilterNode> (or VGSegmentationNode).
///                          nil treated as empty.
/// @param renderer          The Metal renderer sink. Must not be nil.
/// @param platformViewSink  Optional VGFrameSink for PlatformView delivery (POC2).
///                          When nil: single-child VGFanOutSink (original behaviour).
///                          When non-nil: two-child VGFanOutSink — renderer first, then platform view.
/// @param outError          On failure, set to a descriptive NSError.
/// @return A dictionary containing keys @"descriptor", @"nodes", and @"plan" on success, or nil on failure.
+ (nullable NSDictionary<NSString *, id> *)
    buildCameraGraphWithSource:(VanguardCameraMediaSource *)source
                   filterChain:(nullable NSArray *)filterChain
                      renderer:(VanguardMetalRenderer *)renderer
              platformViewSink:(nullable id<VGFrameSink>)platformViewSink
                         error:(NSError * _Nullable * _Nullable)outError;

/// Convenience overload without platformViewSink (original single-renderer fan-out behaviour).
/// Calls buildCameraGraphWithSource:filterChain:renderer:platformViewSink:error: with nil.
+ (nullable NSDictionary<NSString *, id> *)
    buildCameraGraphWithSource:(VanguardCameraMediaSource *)source
                   filterChain:(nullable NSArray *)filterChain
                      renderer:(VanguardMetalRenderer *)renderer
                         error:(NSError * _Nullable * _Nullable)outError;

/// Phase 9B-3: Gated VGSegmentationNode factory.
///
/// When VG_ML_SEGMENTATION_ENABLED == 0 (default, all production builds):
///   Returns a VGSegmentationNode initialized with VGHeuristicMaskProvider
///   via the designated initializer. Behaviour is byte-for-byte identical to
///   calling [[VGSegmentationNode alloc] initWithPool:pool device:device].
///
/// When VG_ML_SEGMENTATION_ENABLED == 1 (dev/test override only):
///   Wires VGLiteRTMaskProvider (with VGHeuristicMaskProvider fallback) and
///   injects it via the DI initializer. Falls back to heuristic if the ML
///   provider is not ready (model missing, tensor contract failure, etc.).
///
/// Callers should replace direct [[VGSegmentationNode alloc] initWithPool:device:]
/// calls with this method to participate in the provider gate automatically.
/// VanguardGraphRuntime migration is deferred to Phase 9B-4.
///
/// @param pool    Runtime session CVPixelBufferPool (may be NULL).
/// @param device  Shared MTLDevice (may be nil on headless/test host).
/// @return A fully initialized VGSegmentationNode. Never nil.
+ (VGSegmentationNode *)makeSegmentationNodeWithPool:(CVPixelBufferPoolRef)pool
                                              device:(nullable id<MTLDevice>)device;

/// init is unavailable. Use +buildCameraGraphWithSource:filterChain:renderer:error:.
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
