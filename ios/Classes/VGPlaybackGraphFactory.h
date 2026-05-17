// VGPlaybackGraphFactory.h
// Phase 4 Batch 1: Adapter only. No runtime wiring.
//
// VGPlaybackGraphFactory is a pure graph-construction utility. It:
//   - Accepts existing runtime components (source, renderer, filter chain)
//   - Wraps them in Phase 3 adapters (VGFileSourceAdapter / VGImageSourceAdapter,
//     VGLegacyFilterAdapter, VGMetadataNodeAdapter, VGRendererSinkAdapter)
//   - Builds a VGGraphDescriptor with clock policy VGClockPolicyPush
//   - Validates the descriptor via VGGraphValidator
//   - Plans execution order via VGGraphPlanner
//   - Returns a result dictionary (@"descriptor", @"nodes", @"plan")
//
// IMPORTANT — NO LIFECYCLE CALLS:
//   This factory does NOT call prepareWithContext:completion:, prepareWithCompletion:,
//   startProducing, stopProducing, or invalidate on any node or adapter.
//   All lifecycle management remains with VanguardGraphRuntime.
//
// VGClockPolicyPush rationale:
//   The V1 playback engine is source-driven (VanguardFileMediaSource fires
//   _videoCallback on its internal decode queue at the source's natural rate).
//   VGClockPolicyPush preserves this V1 push-mode timing to maintain pixel parity
//   with the existing renderer path. Hybrid clock scheduling (CADisplayLink / audio
//   clock) is deferred to Phase 6+ once the V2 scheduler is fully validated.
//
// Pure construction — no state is stored. All methods are class methods.
// init is unavailable; do not instantiate this class.
//
// Phase 4 Batch 1. Phase 5+ will add port-level format negotiation.

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declarations — full types imported in .m only to keep this header lean.
@class VanguardMetalRenderer;

// ─── VGPlaybackGraphFactory ───────────────────────────────────────────────────
/// Pure graph-construction factory for the V2 playback pipeline.
///
/// Accepts existing V1 runtime objects, wraps them in Phase 3 adapters, builds
/// and validates a VGGraphDescriptor, and returns the planned execution artifacts
/// without invoking any node lifecycle methods.
///
/// All methods are class methods. This class must not be instantiated.
@interface VGPlaybackGraphFactory : NSObject

/// Construct, validate, and plan a playback graph from existing V1 runtime objects.
///
/// Source type detection:
///   - VanguardImageMediaSource → wrapped in VGImageSourceAdapter (pull-mode source)
///   - Any other id<VanguardMediaSource> → wrapped in VGFileSourceAdapter (push-mode)
///
/// Filter chain processing (in order):
///   - VGSegmentationNode → wrapped in VGMetadataNodeAdapter
///   - Any other id<VanguardFilterNode> → wrapped in VGLegacyFilterAdapter
///
/// Edge policy:
///   - All intermediate (transform-to-transform) edges are synchronous with no
///     admission policy.
///   - The final edge from the last upstream node to the renderer sink uses
///     VGSinkAdmissionPolicy.dropLatest (camera preview contract).
///
/// The factory does NOT call prepare/start/invalidate on any adapter or wrapped node.
/// Lifecycle management remains with VanguardGraphRuntime (Phase 4B+).
///
/// @param source       The V1 media source providing decoded frames.
/// @param filterChain  Ordered list of id<VanguardFilterNode> to insert between
///                     source and sink. May be empty (nil treated as empty).
/// @param renderer     The Metal renderer that will act as the graph sink.
/// @param outError     On failure (validation or planning), set to a descriptive
///                     NSError. On success, set to nil.
/// @return A dictionary with three keys on success, or nil on failure:
///   @"descriptor" — VGGraphDescriptor (validated)
///   @"nodes"      — NSDictionary<NSString *, id<VGNode>> mapping nodeId → adapter
///   @"plan"       — VGExecutionPlan (topologically sorted)
+ (nullable NSDictionary<NSString *, id> *)
    buildGraphWithSource:(id)source
             filterChain:(nullable NSArray *)filterChain
                renderer:(VanguardMetalRenderer *)renderer
                   error:(NSError * _Nullable * _Nullable)outError;

/// init is unavailable. Use +buildGraphWithSource:filterChain:renderer:error:.
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
