// VGPlaybackGraphFactory.m
// Phase 4 Batch 1: Adapter only. No runtime wiring.
//
// Implementation of VGPlaybackGraphFactory.
//
// This factory does NOT call prepare/start/invalidate on any node or adapter.
// All lifecycle management remains with VanguardGraphRuntime.
//
// VGClockPolicyPush rationale:
//   The V1 playback engine is source-driven: VanguardFileMediaSource fires
//   _videoCallback on its internal decode queue at its own natural decode rate.
//   VGClockPolicyPush preserves this V1 push-mode timing contract to maintain
//   pixel parity with the existing renderer path (Phase 4 gate RR-V2-003).
//   Hybrid scheduling (CADisplayLink / audio clock mastered) is deferred to
//   Phase 6+ once the V2 scheduler is fully validated.
//
// VGMetadataNodeAdapter corrective patch context:
//   Prior to commit 7967061, VGMetadataNodeAdapter only declared video_in and
//   metadata_out. This made the graph topology invalid: the VGGraphValidator
//   would see an edge referencing "video_out" on an adapter that had no such
//   port. Commit 7967061 added video_out (VGMediaTypeVideo, non-required) as a
//   passthrough port, enabling valid linear-chain wiring through metadata nodes.
//   All edges in this factory reference only ports that actually exist in the
//   adapter's declaredPorts after the patch.

#import "VGPlaybackGraphFactory.h"

// ─── Phase 3 adapters ────────────────────────────────────────────────────────
#import "VGFileSourceAdapter.h"
#import "VGImageSourceAdapter.h"
#import "VGLegacyFilterAdapter.h"
#import "VGMetadataNodeAdapter.h"
#import "VGRendererSinkAdapter.h"

// ─── Wrapped V1 classes ───────────────────────────────────────────────────────
#import "VGSegmentationNode.h"
#import "VanguardMetalRenderer.h"
#import "VanguardImageMediaSource.h"
#import "VanguardFileMediaSource.h"

// ─── UMF V2 types ────────────────────────────────────────────────────────────
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
#import <UMF/VGTransformNode.h>
#import <UMF/VGMetadataNode.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGSourceNode.h>
#import <UMF/VGMediaNode.h>

@implementation VGPlaybackGraphFactory

// ─── Public class method ──────────────────────────────────────────────────────

/// Construct, validate, and plan a playback graph from existing V1 runtime objects.
///
/// Steps:
///   (a) Detect source type and wrap in the appropriate VGSourceNode adapter.
///   (b) Process filter chain: VGSegmentationNode → VGMetadataNodeAdapter,
///       others → VGLegacyFilterAdapter.
///   (c) Wrap renderer → VGRendererSinkAdapter.
///   (d) Build nodeId → adapter map.
///   (e) Build VGGraphNodeDescriptors from each adapter's declared identity and ports.
///   (f) Build VGGraphConnections as a linear chain (source → filters → sink),
///       using synchronous edges for intermediate hops and a dropLatest-policy
///       synchronous edge for the final hop to the sink.
///   (g) Build VGGraphDescriptor with graphId "playbackGraph", VGClockPolicyPush,
///       and no audio sidecar.
///   (h) Validate via VGGraphValidator.validateDescriptor:errors:. Return nil on fail.
///   (i) Plan via VGGraphPlanner.planFromDescriptor:error:. Return nil on fail.
///   (j) Return @{ @"descriptor": ..., @"nodes": ..., @"plan": ... }.
///
/// This method does NOT call prepare/start/invalidate on any node or adapter.
+ (nullable NSDictionary<NSString *, id> *)
    buildGraphWithSource:(id)source
             filterChain:(nullable NSArray *)filterChain
                renderer:(VanguardMetalRenderer *)renderer
                   error:(NSError * _Nullable * _Nullable)outError
{
    NSParameterAssert(source != nil);
    NSParameterAssert(renderer != nil);

    // ── (a) Detect source type and wrap ──────────────────────────────────────
    //
    // VanguardImageMediaSource → pull-mode VGImageSourceAdapter.
    // Any other conformer      → push-mode VGFileSourceAdapter.
    id<VGSourceNode> sourceAdapter;
    if ([source isKindOfClass:[VanguardImageMediaSource class]]) {
        sourceAdapter = [[VGImageSourceAdapter alloc]
                            initWithSource:(VanguardImageMediaSource *)source];
    } else {
        sourceAdapter = [[VGFileSourceAdapter alloc]
                            initWithSource:(VanguardFileMediaSource *)source];
    }

    // ── (b) Process filter chain ──────────────────────────────────────────────
    //
    // Iterates filterChain in declaration order (source-to-sink).
    // VGSegmentationNode instances are wrapped in VGMetadataNodeAdapter (they
    // produce metadata via enrichEnvelope:device: and pass video through via
    // the video_out port added in commit 7967061).
    // All other filters (id<VanguardFilterNode>) are wrapped in VGLegacyFilterAdapter.
    NSArray *safeFilterChain = filterChain ?: @[];
    NSMutableArray<id<VGNode>> *filterAdapters = [NSMutableArray arrayWithCapacity:safeFilterChain.count];
    for (id filter in safeFilterChain) {
        if ([filter isKindOfClass:[VGSegmentationNode class]]) {
            VGMetadataNodeAdapter *mAdapter =
                [[VGMetadataNodeAdapter alloc] initWithSegmentationNode:(VGSegmentationNode *)filter];
            [filterAdapters addObject:mAdapter];
        } else {
            // Assumes id<VGMetalFilterNode> conformance (enforced at call site).
            VGLegacyFilterAdapter *lAdapter =
                [[VGLegacyFilterAdapter alloc] initWithFilter:filter];
            [filterAdapters addObject:lAdapter];
        }
    }

    // ── (c) Wrap renderer ─────────────────────────────────────────────────────
    VGRendererSinkAdapter *sinkAdapter =
        [[VGRendererSinkAdapter alloc] initWithRenderer:renderer];

    // ── (d) Build node map: nodeId → adapter ──────────────────────────────────
    //
    // The node map is keyed by nodeId (from each adapter's nodeId property).
    // This is returned as @"nodes" in the result dictionary.
    NSMutableDictionary<NSString *, id<VGNode>> *nodeMap = [NSMutableDictionary dictionary];
    nodeMap[sourceAdapter.nodeId] = sourceAdapter;
    for (id<VGNode> fa in filterAdapters) {
        nodeMap[fa.nodeId] = fa;
    }
    nodeMap[sinkAdapter.nodeId] = sinkAdapter;

    // ── (e) Build VGGraphNodeDescriptors ─────────────────────────────────────
    //
    // Each descriptor is constructed from the adapter's identity and declared ports.
    // parameters is always @{} (Phase 4B+ may inject initial parameters).
    NSMutableArray<VGGraphNodeDescriptor *> *nodeDescriptors =
        [NSMutableArray arrayWithCapacity:nodeMap.count];

    VGGraphNodeDescriptor *sourceDescriptor =
        [[VGGraphNodeDescriptor alloc] initWithNodeId:sourceAdapter.nodeId
                                            nodeClass:sourceAdapter.nodeClass
                                             nodeRole:sourceAdapter.nodeRole
                                           parameters:@{}
                                                ports:[sourceAdapter declaredPorts]];
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
        [[VGGraphNodeDescriptor alloc] initWithNodeId:sinkAdapter.nodeId
                                            nodeClass:sinkAdapter.nodeClass
                                             nodeRole:sinkAdapter.nodeRole
                                           parameters:@{}
                                                ports:[sinkAdapter declaredPorts]];
    [nodeDescriptors addObject:sinkDescriptor];

    // ── (f) Build VGGraphConnections — linear chain ───────────────────────────
    //
    // All adapters (source, filters, sink) declare video_in / video_out ports.
    // VGMetadataNodeAdapter declares video_out after commit 7967061 corrective
    // patch — no workaround needed.
    //
    // Edge rule:
    //   Intermediate edges (transform-to-transform):
    //     synchronousEdgeFrom:port:to:port: (no admission policy)
    //   Final edge (last upstream → sink):
    //     synchronousEdgeFrom:port:to:port:admissionPolicy:dropLatest
    //     (dropLatest is the correct policy for a push-mode preview renderer)
    NSMutableArray<VGGraphConnection *> *connections = [NSMutableArray array];

    // Build ordered list: source, then filter adapters (in order).
    // These are all the "upstream" nodes relative to the next node in the chain.
    NSMutableArray<id<VGNode>> *orderedNodes = [NSMutableArray array];
    [orderedNodes addObject:sourceAdapter];
    [orderedNodes addObjectsFromArray:filterAdapters];
    // sinkAdapter is the final target.

    if (orderedNodes.count == 1) {
        // Edge case: empty filter chain → single direct source → sink edge.
        // Uses dropLatest admission policy.
        VGGraphConnection *directEdge =
            [VGGraphConnection synchronousEdgeFrom:sourceAdapter.nodeId
                                              port:@"video_out"
                                                to:sinkAdapter.nodeId
                                              port:@"video_in"
                                   admissionPolicy:[VGSinkAdmissionPolicy dropLatest]];
        [connections addObject:directEdge];
    } else {
        // Build N-1 intermediate synchronous edges (no admission policy).
        for (NSUInteger i = 0; i < orderedNodes.count - 1; i++) {
            id<VGNode> upstream   = orderedNodes[i];
            id<VGNode> downstream = orderedNodes[i + 1];
            VGGraphConnection *edge =
                [VGGraphConnection synchronousEdgeFrom:upstream.nodeId
                                                  port:@"video_out"
                                                    to:downstream.nodeId
                                                  port:@"video_in"];
            [connections addObject:edge];
        }

        // Final edge: last filter/node → sink (dropLatest policy).
        id<VGNode> lastUpstream = orderedNodes.lastObject;
        VGGraphConnection *sinkEdge =
            [VGGraphConnection synchronousEdgeFrom:lastUpstream.nodeId
                                              port:@"video_out"
                                                to:sinkAdapter.nodeId
                                              port:@"video_in"
                                   admissionPolicy:[VGSinkAdmissionPolicy dropLatest]];
        [connections addObject:sinkEdge];
    }

    // ── (g) Build VGGraphDescriptor ───────────────────────────────────────────
    //
    // graphId: "playbackGraph" — stable identifier matching V1 semantics.
    // clockPolicy: VGClockPolicyPush — source-driven, matching V1 push-mode timing.
    // audioSidecar: nil — audio handled externally by VanguardGraphRuntime (Phase 8+).
    VGGraphDescriptor *descriptor =
        [[VGGraphDescriptor alloc] initWithGraphId:@"playbackGraph"
                                             nodes:nodeDescriptors
                                       connections:connections
                                       clockPolicy:VGClockPolicyPush
                                      audioSidecar:nil];

    // ── (h) Validate via VGGraphValidator ─────────────────────────────────────
    //
    // Phase 2 structural checks: at least one source, one sink, no dangling
    // connections, no cycles, and no NeverDrop policy on push-mode edges.
    // Port-level checks (VGValidationErrorDisconnectedPort, type mismatch) are
    // deferred to Phase 3+; they are not enforced here.
    NSArray<VGValidationError *> *validationErrors = nil;
    BOOL valid = [VGGraphValidator validateDescriptor:descriptor
                                               errors:&validationErrors];
    if (!valid) {
        if (outError) {
            NSString *desc = [NSString stringWithFormat:
                @"VGPlaybackGraphFactory: VGGraphValidator rejected descriptor. "
                 "Errors: %@", validationErrors];
            *outError = [NSError errorWithDomain:@"VGPlaybackGraphFactory"
                                            code:1
                                        userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return nil;
    }

    // ── (i) Plan via VGGraphPlanner ───────────────────────────────────────────
    //
    // Computes a dependency-safe topological execution order using Kahn's BFS.
    // Returns nil + error if a cycle is detected (should not occur for a
    // validated linear DAG).
    NSError *plannerError = nil;
    VGExecutionPlan *plan = [VGGraphPlanner planFromDescriptor:descriptor
                                                         error:&plannerError];
    if (!plan) {
        if (outError) {
            NSString *desc = [NSString stringWithFormat:
                @"VGPlaybackGraphFactory: VGGraphPlanner failed. "
                 "Error: %@", plannerError.localizedDescription];
            *outError = [NSError errorWithDomain:@"VGPlaybackGraphFactory"
                                            code:2
                                        userInfo:@{NSLocalizedDescriptionKey: desc,
                                                   NSUnderlyingErrorKey: plannerError}];
        }
        return nil;
    }

    // ── (j) Return result dictionary ──────────────────────────────────────────
    return @{
        @"descriptor": descriptor,
        @"nodes":      nodeMap,
        @"plan":       plan,
    };
}

@end
