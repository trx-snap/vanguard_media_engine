// VGExportGraphFactory.h
// vanguard_media_engine — Phase 5C-3
//
// VGExportGraphFactory is a pure graph-construction utility for offline export.
// It builds, validates, and plans a VGClockPolicyPull export graph descriptor.
//
// Architecture:
//   - Pure class-method factory. No instance state. init is unavailable.
//   - Mirrors VGPlaybackGraphFactory but targets pull-mode offline export.
//   - Uses VGExportFileSourceNode (5C-2) as the source — no VanguardFileMediaSource.
//   - Accepts a pre-built id<VGFrameSink> parameter — no internal encoder creation.
//   - Uses VGSinkAdmissionPolicyNeverDrop on the sink edge (allowed on pull graphs).
//   - Uses VGSinkAdmissionPolicyNeverDrop only with VGClockPolicyPull.
//   - Wraps filter chain via VGLegacyFilterAdapter / VGMetadataNodeAdapter.
//
// Contract:
//   - Does NOT call prepareWithContext:, startProducing, or invalidate on any node.
//   - Does NOT wire VGExportScheduler — that is the caller's responsibility.
//   - Does NOT import VanguardFileMediaSource, VanguardGraphRuntime, VanguardMetalRenderer.
//   - Does NOT import VGVideoEncoderSinkNode, AVAssetWriter, or VGGraphSchedulerV2.
//
// Output dictionary keys:
//   @"descriptor" — VGGraphDescriptor (validated, VGClockPolicyPull)
//   @"nodes"      — NSDictionary<NSString *, id<VGNode>> mapping nodeId → node instance
//   @"plan"       — VGExecutionPlan (topologically sorted)
//
// Phase 5C-3. Next: 5C-4 VGVideoEncoderSinkNode.

#pragma once

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UMF/VGFrameSink.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGExportGraphFactory ─────────────────────────────────────────────────────
/// Pure graph-construction factory for the V2 offline export pipeline.
///
/// Accepts an AVAsset as the source, an optional filter chain, and a pre-built
/// id<VGFrameSink> sink. Builds and validates a VGGraphDescriptor with
/// VGClockPolicyPull and VGSinkAdmissionPolicyNeverDrop on the sink edge.
///
/// All methods are class methods. This class must not be instantiated.
@interface VGExportGraphFactory : NSObject

/// Construct, validate, and plan an export graph.
///
/// Source:
///   The asset is wrapped in VGExportFileSourceNode. The first video track is
///   extracted; if none is found, a validation error is returned.
///
/// Filter chain processing (same as VGPlaybackGraphFactory):
///   - VGSegmentationNode → wrapped in VGMetadataNodeAdapter
///   - Any other id<VGMetalFilterNode> → wrapped in VGLegacyFilterAdapter
///
/// Edge policy:
///   - Intermediate transform-to-transform edges: synchronous, no admission policy.
///   - Final edge to sink: synchronous with VGSinkAdmissionPolicyNeverDrop.
///     (neverDrop is valid only on pull-mode graphs — VGGraphValidator enforces this.)
///
/// This factory does NOT call prepare/start/invalidate on any node or adapter.
///
/// @param asset       The source asset. Must be a local file asset with a video track.
/// @param filterChain Optional ordered list of id<VGMetalFilterNode> (or VGSegmentationNode)
///                    to insert between source and sink. nil treated as empty.
/// @param sink        Pre-built terminal sink conforming to VGFrameSink. In Phase 5C-3
///                    tests this is VGEGF_MockSink. In Phase 5C-4+ it is VGVideoEncoderSinkNode.
/// @param outError    On failure, set to a descriptive NSError (domain "VGExportGraphFactory").
/// @return A dictionary with three keys on success, or nil on failure:
///   @"descriptor" — VGGraphDescriptor (validated)
///   @"nodes"      — NSDictionary<NSString *, id<VGNode>> mapping nodeId → adapter/node
///   @"plan"       — VGExecutionPlan (topologically sorted)
+ (nullable NSDictionary<NSString *, id> *)
    buildExportGraphWithAsset:(AVAsset *)asset
                  filterChain:(nullable NSArray *)filterChain
                         sink:(id<VGFrameSink>)sink
                        error:(NSError * _Nullable * _Nullable)outError;

/// init is unavailable. Use +buildExportGraphWithAsset:filterChain:sink:error:.
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
