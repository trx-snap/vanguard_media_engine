// VGCameraGraphFactory.m
// vanguard_media_engine — Phase 6A-1
//
// Implementation of VGCameraGraphFactory.

#import "VGCameraGraphFactory.h"

// ─── Native source / adapters / sinks ─────────────────────────────────────────
#import "VGCameraSourceAdapter.h"
#import "VGRendererSinkAdapter.h"
#import "VGFanOutSink.h"
#import "VGLegacyFilterAdapter.h"
#import "VGMetadataNodeAdapter.h"

// ─── UMF types ────────────────────────────────────────────────────────────────
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
#import <UMF/VGValidationError.h>

// ─── Wrapped V1 classes ───────────────────────────────────────────────────────
#import "VGSegmentationNode.h"
#import "VanguardCameraMediaSource.h"
#import "VanguardMetalRenderer.h"

@implementation VGCameraGraphFactory

+ (nullable NSDictionary<NSString *, id> *)
    buildCameraGraphWithSource:(VanguardCameraMediaSource *)source
                   filterChain:(nullable NSArray *)filterChain
                      renderer:(VanguardMetalRenderer *)renderer
                         error:(NSError * _Nullable * _Nullable)outError
{
    // ── (a) Guard inputs ──────────────────────────────────────────────────────
    if (!source) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGCameraGraphFactory"
                                            code:3
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"VGCameraGraphFactory: source must not be nil."
            }];
        }
        return nil;
    }
    if (!renderer) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGCameraGraphFactory"
                                            code:4
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"VGCameraGraphFactory: renderer must not be nil."
            }];
        }
        return nil;
    }

    // ── (b) Wrap camera source ────────────────────────────────────────────────
    VGCameraSourceAdapter *sourceAdapter = [[VGCameraSourceAdapter alloc] initWithSource:source];

    // ── (c) Process filter chain ──────────────────────────────────────────────
    NSArray *safeFilterChain = filterChain ?: @[];
    NSMutableArray<id<VGNode>> *filterAdapters = [NSMutableArray arrayWithCapacity:safeFilterChain.count];
    for (id filter in safeFilterChain) {
        if ([filter isKindOfClass:[VGSegmentationNode class]]) {
            VGMetadataNodeAdapter *mAdapter =
                [[VGMetadataNodeAdapter alloc] initWithSegmentationNode:(VGSegmentationNode *)filter];
            [filterAdapters addObject:mAdapter];
        } else {
            VGLegacyFilterAdapter *lAdapter =
                [[VGLegacyFilterAdapter alloc] initWithFilter:filter];
            [filterAdapters addObject:lAdapter];
        }
    }

    // ── (d) Wrap renderer and construct composite VGFanOutSink ─────────────────
    VGRendererSinkAdapter *rendererSinkAdapter = [[VGRendererSinkAdapter alloc] initWithRenderer:renderer];
    VGFanOutSink *fanOutSink = [[VGFanOutSink alloc] initWithNodeId:@"fan_out_sink" sinks:@[ rendererSinkAdapter ]];
    if (!fanOutSink) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGCameraGraphFactory"
                                            code:5
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"VGCameraGraphFactory: failed to initialize VGFanOutSink composite sink."
            }];
        }
        return nil;
    }

    // ── (e) Build node map: nodeId → adapter ──────────────────────────────────
    NSMutableDictionary<NSString *, id<VGNode>> *nodeMap = [NSMutableDictionary dictionary];
    nodeMap[sourceAdapter.nodeId] = sourceAdapter;
    for (id<VGNode> fa in filterAdapters) {
        nodeMap[fa.nodeId] = fa;
    }
    nodeMap[fanOutSink.nodeId] = fanOutSink;

    // ── (f) Build VGGraphNodeDescriptors ─────────────────────────────────────
    NSMutableArray<VGGraphNodeDescriptor *> *nodeDescriptors = [NSMutableArray arrayWithCapacity:nodeMap.count];

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
        [[VGGraphNodeDescriptor alloc] initWithNodeId:fanOutSink.nodeId
                                            nodeClass:fanOutSink.nodeClass
                                             nodeRole:fanOutSink.nodeRole
                                           parameters:@{}
                                                ports:[fanOutSink declaredPorts]];
    [nodeDescriptors addObject:sinkDescriptor];

    // ── (g) Build VGGraphConnections — linear chain ───────────────────────────
    NSMutableArray<id<VGNode>> *orderedNodes = [NSMutableArray array];
    [orderedNodes addObject:sourceAdapter];
    [orderedNodes addObjectsFromArray:filterAdapters];

    NSMutableArray<VGGraphConnection *> *connections = [NSMutableArray array];

    if (orderedNodes.count == 1) {
        // Empty filter chain → direct connection from source adapter to VGFanOutSink.
        // Edge uses dropLatest admission policy (push-mode sink edge).
        VGGraphConnection *directEdge =
            [VGGraphConnection synchronousEdgeFrom:sourceAdapter.nodeId
                                              port:@"video_out"
                                                to:fanOutSink.nodeId
                                              port:@"video_in"
                                   admissionPolicy:[VGSinkAdmissionPolicy dropLatest]];
        [connections addObject:directEdge];
    } else {
        // Intermediate synchronous edges (no admission policy).
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

        // Final edge to fanOutSink (dropLatest policy).
        id<VGNode> lastUpstream = orderedNodes.lastObject;
        VGGraphConnection *sinkEdge =
            [VGGraphConnection synchronousEdgeFrom:lastUpstream.nodeId
                                              port:@"video_out"
                                                to:fanOutSink.nodeId
                                              port:@"video_in"
                                   admissionPolicy:[VGSinkAdmissionPolicy dropLatest]];
        [connections addObject:sinkEdge];
    }

    // ── (h) Build VGGraphDescriptor ───────────────────────────────────────────
    // graphId: "cameraGraph"
    // clockPolicy: VGClockPolicyPush — push-mode camera schedule
    // audioSidecar: nil
    VGGraphDescriptor *descriptor =
        [[VGGraphDescriptor alloc] initWithGraphId:@"cameraGraph"
                                             nodes:nodeDescriptors
                                       connections:connections
                                       clockPolicy:VGClockPolicyPush
                                      audioSidecar:nil];

    // ── (i) Validate via VGGraphValidator ─────────────────────────────────────
    NSArray<VGValidationError *> *validationErrors = nil;
    BOOL valid = [VGGraphValidator validateDescriptor:descriptor
                                               errors:&validationErrors];
    if (!valid) {
        if (outError) {
            NSString *desc = [NSString stringWithFormat:
                @"VGCameraGraphFactory: VGGraphValidator rejected descriptor. "
                 "Errors: %@", validationErrors];
            *outError = [NSError errorWithDomain:@"VGCameraGraphFactory"
                                            code:1
                                        userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return nil;
    }

    // ── (j) Plan via VGGraphPlanner ───────────────────────────────────────────
    NSError *plannerError = nil;
    VGExecutionPlan *plan = [VGGraphPlanner planFromDescriptor:descriptor
                                                         error:&plannerError];
    if (!plan) {
        if (outError) {
            NSString *desc = [NSString stringWithFormat:
                @"VGCameraGraphFactory: VGGraphPlanner failed. "
                 "Error: %@", plannerError.localizedDescription];
            *outError = [NSError errorWithDomain:@"VGCameraGraphFactory"
                                            code:2
                                        userInfo:@{NSLocalizedDescriptionKey: desc,
                                                   NSUnderlyingErrorKey: plannerError}];
        }
        return nil;
    }

    // ── (k) Return planned dictionary ─────────────────────────────────────────
    return @{
        @"descriptor": descriptor,
        @"nodes":      nodeMap,
        @"plan":       plan,
    };
}

@end
