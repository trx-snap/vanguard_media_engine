// VGExportGraphFactory.m
// vanguard_media_engine — Phase 5C-3
//
// Pure graph-construction factory for the V2 offline export pipeline.
//
// This file mirrors VGPlaybackGraphFactory.m in structure, but builds a
// VGClockPolicyPull graph for offline export rather than a VGClockPolicyPush
// graph for camera/file playback.
//
// Key differences from VGPlaybackGraphFactory:
//   - Source: VGExportFileSourceNode (standalone, no VanguardFileMediaSource wrapper)
//   - Sink: id<VGFrameSink> parameter (injected, not created internally)
//   - Clock policy: VGClockPolicyPull (sink-driven)
//   - Sink admission: VGSinkAdmissionPolicyNeverDrop (allowed on pull-mode graphs)
//   - Graph ID: @"exportGraph"
//   - audioSidecar: nil (Phase 8+)
//
// This file does NOT import:
//   VanguardFileMediaSource, VanguardGraphRuntime, VanguardMetalRenderer,
//   VGGraphSchedulerV2, VGVideoEncoderSinkNode, AVAssetWriter.
//
// This factory does NOT call prepareWithContext:, startProducing, or invalidate.
//
// Phase 5C-3: Graph construction only. VGExportScheduler wiring is Phase 5C-5+.

#import "VGExportGraphFactory.h"

// ─── Phase 5C-2/3 export nodes ───────────────────────────────────────────────
#import "VGExportFileSourceNode.h"

// ─── Phase 3 adapters (same as playback) ─────────────────────────────────────
#import "VGLegacyFilterAdapter.h"
#import "VGMetadataNodeAdapter.h"
#import "VGSegmentationNode.h"      // for isKindOfClass check only

// ─── UMF graph construction types ────────────────────────────────────────────
#import <UMF/VGGraphDescriptor.h>
#import <UMF/VGGraphNodeDescriptor.h>
#import <UMF/VGGraphConnection.h>
#import <UMF/VGGraphValidator.h>
#import <UMF/VGGraphPlanner.h>
#import <UMF/VGExecutionPlan.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGClockPolicy.h>
#import <UMF/VGSinkAdmissionPolicy.h>
#import <UMF/VGNode.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGSourceNode.h>
#import <UMF/VGValidationError.h>

@implementation VGExportGraphFactory

// ─── Public class method ──────────────────────────────────────────────────────

/// Construct, validate, and plan a pull-mode export graph.
///
/// Steps:
///   (a) Guard inputs — nil asset or sink → early error.
///   (b) Create VGExportFileSourceNode from asset.
///   (c) Process filter chain: VGSegmentationNode → VGMetadataNodeAdapter,
///       others → VGLegacyFilterAdapter.
///   (d) Build nodeId → node map (source + filters + sink).
///   (e) Build VGGraphNodeDescriptors from each node's declared identity and ports.
///   (f) Build VGGraphConnections as a linear chain:
///       — Intermediate edges: synchronous, no admission policy.
///       — Sink edge: synchronous with VGSinkAdmissionPolicyNeverDrop.
///   (g) Build VGGraphDescriptor with graphId "exportGraph", VGClockPolicyPull,
///       and no audio sidecar.
///   (h) Validate via VGGraphValidator.validateDescriptor:errors:. Return nil on fail.
///   (i) Plan via VGGraphPlanner.planFromDescriptor:error:. Return nil on fail.
///   (j) Return @{ @"descriptor": …, @"nodes": …, @"plan": … }.
///
/// This method does NOT call prepare/start/invalidate on any node or adapter.
+ (nullable NSDictionary<NSString *, id> *)
    buildExportGraphWithAsset:(AVAsset *)asset
                  filterChain:(nullable NSArray *)filterChain
                         sink:(id<VGFrameSink>)sink
                        error:(NSError * _Nullable * _Nullable)outError
{
    // ── (a) Guard inputs ──────────────────────────────────────────────────────
    if (!asset) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGExportGraphFactory"
                                           code:3
                                       userInfo:@{
                NSLocalizedDescriptionKey: @"VGExportGraphFactory: asset must not be nil."
            }];
        }
        return nil;
    }
    if (!sink) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGExportGraphFactory"
                                           code:4
                                       userInfo:@{
                NSLocalizedDescriptionKey: @"VGExportGraphFactory: sink must not be nil."
            }];
        }
        return nil;
    }

    // ── (b) Create VGExportFileSourceNode ─────────────────────────────────────
    //
    // Standalone pull-mode source — does NOT wrap VanguardFileMediaSource.
    // Extracts the first video track from the asset and computes renderSize/fps.
    VGExportFileSourceNode *sourceNode =
        [[VGExportFileSourceNode alloc] initWithAsset:asset];

    // ── (c) Process filter chain ──────────────────────────────────────────────
    //
    // Mirrors VGPlaybackGraphFactory filter-chain wrapping:
    //   VGSegmentationNode → VGMetadataNodeAdapter (produces metadata + passes video)
    //   Other id<VGMetalFilterNode> → VGLegacyFilterAdapter (pure transform)
    NSArray *safeFilterChain = filterChain ?: @[];
    NSMutableArray<id<VGNode>> *filterAdapters =
        [NSMutableArray arrayWithCapacity:safeFilterChain.count];

    for (id filter in safeFilterChain) {
        if ([filter isKindOfClass:[VGSegmentationNode class]]) {
            VGMetadataNodeAdapter *mAdapter =
                [[VGMetadataNodeAdapter alloc]
                    initWithSegmentationNode:(VGSegmentationNode *)filter];
            [filterAdapters addObject:mAdapter];
        } else {
            // Assumes id<VGMetalFilterNode> conformance (enforced at call site).
            VGLegacyFilterAdapter *lAdapter =
                [[VGLegacyFilterAdapter alloc] initWithFilter:filter];
            [filterAdapters addObject:lAdapter];
        }
    }

    // ── (d) Build nodeId → node map ───────────────────────────────────────────
    //
    // Sink is cast to id<VGNode> — VGFrameSink extends VGNode per VGFrameSink.h.
    id<VGNode> sinkNode = (id<VGNode>)sink;
    NSMutableDictionary<NSString *, id<VGNode>> *nodeMap =
        [NSMutableDictionary dictionary];
    nodeMap[sourceNode.nodeId] = sourceNode;
    for (id<VGNode> fa in filterAdapters) {
        nodeMap[fa.nodeId] = fa;
    }
    nodeMap[sinkNode.nodeId] = sinkNode;

    // ── (e) Build VGGraphNodeDescriptors ─────────────────────────────────────
    //
    // Each descriptor carries identity (nodeId, nodeClass, nodeRole),
    // initial parameters (@{}), and declared ports from the live node.
    NSMutableArray<VGGraphNodeDescriptor *> *nodeDescriptors =
        [NSMutableArray arrayWithCapacity:nodeMap.count];

    VGGraphNodeDescriptor *sourceDescriptor =
        [[VGGraphNodeDescriptor alloc] initWithNodeId:sourceNode.nodeId
                                            nodeClass:sourceNode.nodeClass
                                             nodeRole:sourceNode.nodeRole
                                           parameters:@{}
                                                ports:[sourceNode declaredPorts]];
    [nodeDescriptors addObject:sourceDescriptor];

    for (id<VGNode> fa in filterAdapters) {
        VGGraphNodeDescriptor *fd =
            [[VGGraphNodeDescriptor alloc] initWithNodeId:fa.nodeId
                                                nodeClass:fa.nodeClass
                                                 nodeRole:fa.nodeRole
                                               parameters:@{}
                                                    ports:[fa declaredPorts]];
        [nodeDescriptors addObject:fd];
    }

    VGGraphNodeDescriptor *sinkDescriptor =
        [[VGGraphNodeDescriptor alloc] initWithNodeId:sinkNode.nodeId
                                            nodeClass:sinkNode.nodeClass
                                             nodeRole:sinkNode.nodeRole
                                           parameters:@{}
                                                ports:[sinkNode declaredPorts]];
    [nodeDescriptors addObject:sinkDescriptor];

    // ── (f) Build VGGraphConnections — linear chain ───────────────────────────
    //
    // Ordered upstream list: source + filter adapters (declaration order).
    // Edge rule:
    //   Intermediate (transform-to-transform): synchronous, no admission policy.
    //   Final (last upstream → sink): synchronous with neverDrop admission.
    //     neverDrop is valid on VGClockPolicyPull; VGGraphValidator enforces this
    //     (CHECK 5 only rejects neverDrop on VGClockPolicyPush edges).
    NSMutableArray<id<VGNode>> *orderedUpstream = [NSMutableArray array];
    [orderedUpstream addObject:sourceNode];
    [orderedUpstream addObjectsFromArray:filterAdapters];

    NSMutableArray<VGGraphConnection *> *connections = [NSMutableArray array];

    if (orderedUpstream.count == 1) {
        // Empty filter chain → single direct source → sink edge with neverDrop.
        VGGraphConnection *directEdge =
            [VGGraphConnection synchronousEdgeFrom:sourceNode.nodeId
                                              port:@"video_out"
                                                to:sinkNode.nodeId
                                              port:@"video_in"
                                   admissionPolicy:[VGSinkAdmissionPolicy neverDrop]];
        [connections addObject:directEdge];
    } else {
        // N-1 intermediate synchronous edges (no admission policy).
        for (NSUInteger i = 0; i < orderedUpstream.count - 1; i++) {
            id<VGNode> upstream   = orderedUpstream[i];
            id<VGNode> downstream = orderedUpstream[i + 1];
            VGGraphConnection *edge =
                [VGGraphConnection synchronousEdgeFrom:upstream.nodeId
                                                  port:@"video_out"
                                                    to:downstream.nodeId
                                                  port:@"video_in"];
            [connections addObject:edge];
        }

        // Final edge: last upstream → sink (neverDrop policy).
        id<VGNode> lastUpstream = orderedUpstream.lastObject;
        VGGraphConnection *sinkEdge =
            [VGGraphConnection synchronousEdgeFrom:lastUpstream.nodeId
                                              port:@"video_out"
                                                to:sinkNode.nodeId
                                              port:@"video_in"
                                   admissionPolicy:[VGSinkAdmissionPolicy neverDrop]];
        [connections addObject:sinkEdge];
    }

    // ── (g) Build VGGraphDescriptor ───────────────────────────────────────────
    //
    // graphId: "exportGraph" — distinguishes from "playbackGraph".
    // clockPolicy: VGClockPolicyPull — sink-driven, offline export pacing.
    // audioSidecar: nil — audio export is Phase 8+.
    VGGraphDescriptor *descriptor =
        [[VGGraphDescriptor alloc] initWithGraphId:@"exportGraph"
                                             nodes:nodeDescriptors
                                       connections:connections
                                       clockPolicy:VGClockPolicyPull
                                      audioSidecar:nil];

    // ── (h) Validate via VGGraphValidator ─────────────────────────────────────
    //
    // Phase 2 structural checks:
    //   1. NoSource — at least one node with role == VGNodeRoleSource.
    //   2. NoSink   — at least one node with role == VGNodeRoleSink.
    //   3. DanglingConnection — all nodeId references exist.
    //   4. CycleDetected — iterative DFS.
    //   5. NeverDropOnPushEdge — only checked on VGClockPolicyPush; pull is safe.
    NSArray<VGValidationError *> *validationErrors = nil;
    BOOL valid = [VGGraphValidator validateDescriptor:descriptor
                                               errors:&validationErrors];
    if (!valid) {
        if (outError) {
            NSString *desc = [NSString stringWithFormat:
                @"VGExportGraphFactory: VGGraphValidator rejected descriptor. "
                 "Errors: %@", validationErrors];
            *outError = [NSError errorWithDomain:@"VGExportGraphFactory"
                                           code:1
                                       userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return nil;
    }

    // ── (i) Plan via VGGraphPlanner ───────────────────────────────────────────
    //
    // Kahn's BFS topological sort. Returns nil + error if cycle detected
    // (should not occur for a validated linear DAG).
    NSError *plannerError = nil;
    VGExecutionPlan *plan = [VGGraphPlanner planFromDescriptor:descriptor
                                                         error:&plannerError];
    if (!plan) {
        if (outError) {
            NSString *desc = [NSString stringWithFormat:
                @"VGExportGraphFactory: VGGraphPlanner failed. "
                 "Error: %@", plannerError.localizedDescription];
            *outError = [NSError errorWithDomain:@"VGExportGraphFactory"
                                           code:2
                                       userInfo:@{NSLocalizedDescriptionKey: desc,
                                                  NSUnderlyingErrorKey: plannerError}];
        }
        return nil;
    }

    // ── (j) Return result dictionary ──────────────────────────────────────────
    //
    // Caller uses:
    //   result[@"plan"]       → VGExportScheduler.initWithPlan:nodes:context:fps:
    //   result[@"nodes"]      → VGExportScheduler.initWithPlan:nodes:context:fps:
    //   result[@"descriptor"] → VGGraphExecutionContext construction
    return @{
        @"descriptor": descriptor,
        @"nodes":      nodeMap,
        @"plan":       plan,
    };
}

@end
