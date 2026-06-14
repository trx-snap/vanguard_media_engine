// VGCameraGraphFactory.m
// vanguard_media_engine — Phase 6A-1 / Phase 9B-3
//
// Implementation of VGCameraGraphFactory.
//
// Phase 9B-3: Adds +makeSegmentationNodeWithPool:device: gated behind
// VG_ML_SEGMENTATION_ENABLED (defaults OFF).
// When OFF: identical behaviour to the pre-9B-3 VGSegmentationNode
// designated initializer — no behavioural change whatsoever.
// When ON: VGLiteRTMaskProvider with VGHeuristicMaskProvider fallback.

#import "VGCameraGraphFactory.h"

// ─── Phase 9B-3 ML segmentation gate ─────────────────────────────────────────
// Default OFF. Never enable in production until Phase 9B-4 device validation.
// Callers (e.g. VanguardGraphRuntime) should call
//   +makeSegmentationNodeWithPool:device:
// and receive the gated node — replacing the direct alloc/init site.
// In this slice NO callers are migrated; the method is ready for Phase 9B-4.
#ifndef VG_ML_SEGMENTATION_ENABLED
#define VG_ML_SEGMENTATION_ENABLED 0
#endif

#if VG_ML_SEGMENTATION_ENABLED
#import "VGLiteRTMaskProvider.h"
#import "VGHeuristicMaskProvider.h"
#import "VGMLModelBundle.h"
#endif

// ─── Native source / adapters / sinks ─────────────────────────────────────────
#import "VGCameraSourceAdapter.h"
#import "VGRendererSinkAdapter.h"
#import "VGFanOutSink.h"
#import "VGLegacyFilterAdapter.h"
#import "VGMetadataNodeAdapter.h"
#import "VGPlatformViewSinkAdapter.h"
#import "VGRecordingSinkNode.h"
#import "VGPhotoSinkNode.h"

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
#import <UMF/VGMetalFilterNode.h>

// ─── Wrapped V1 classes ───────────────────────────────────────────────────────
#import "VGSegmentationNode.h"
#import "VanguardCameraMediaSource.h"
#import "VanguardMetalRenderer.h"

@implementation VGCameraGraphFactory

// ─── Phase 9B-3: Gated segmentation node factory ──────────────────────────────
//
// Creates a VGSegmentationNode wired with the correct mask provider.
//
// VG_ML_SEGMENTATION_ENABLED == 0 (DEFAULT — ALL PRODUCTION BUILDS):
//   Delegates directly to the existing designated initializer.
//   No new code paths executed. Behaviour is byte-for-byte identical to
//   calling [[VGSegmentationNode alloc] initWithPool:pool device:device]
//   directly.
//
// VG_ML_SEGMENTATION_ENABLED == 1 (DEV/TEST OVERRIDE ONLY):
//   1. Resolves selfie_multiclass_256x256.tflite from VGMLModelBundle.
//   2. Creates VGHeuristicMaskProvider as fallback.
//   3. Creates VGLiteRTMaskProvider with model URL + fallback.
//   4. If provider init fails or -isReady is NO, uses fallback alone.
//   5. Injects the chosen provider via the DI initializer.
//
// Migration note:
//   VanguardGraphRuntime currently creates VGSegmentationNode directly at
//   line 1415 with [[VGSegmentationNode alloc] initWithPool:pool device:device].
//   That call site is NOT modified in Phase 9B-3. A future Phase 9B-4 task
//   should replace it with [VGCameraGraphFactory makeSegmentationNodeWithPool:device:].

+ (VGSegmentationNode *)makeSegmentationNodeWithPool:(CVPixelBufferPoolRef)pool
                                              device:(id<MTLDevice>)device {
#if VG_ML_SEGMENTATION_ENABLED
    // ── 1. Resolve model URL ────────────────────────────────────────────────
    NSURL *modelURL = [VGMLModelBundle URLForModelNamed:@"selfie_multiclass_256x256"];
    if (!modelURL) {
        NSLog(@"[VGCameraGraphFactory] 9B-3: model URL not found — using heuristic provider");
        return [[VGSegmentationNode alloc] initWithPool:pool device:device];
    }

    // ── 2. Build heuristic fallback ──────────────────────────────────────────
    VGHeuristicMaskProvider *fallback = [[VGHeuristicMaskProvider alloc] init];

    // ── 3. Build LiteRT provider ─────────────────────────────────────────────
    VGLiteRTMaskProvider *mlProvider =
        [[VGLiteRTMaskProvider alloc] initWithModelURL:modelURL
                                              fallback:fallback];

    // ── 4. Validate readiness — fall back to heuristic on any failure ─────────
    id<VGMaskProvider> chosenProvider;
    if (!mlProvider || !mlProvider.isReady) {
        NSLog(@"[VGCameraGraphFactory] 9B-3: VGLiteRTMaskProvider not ready — "
              @"using VGHeuristicMaskProvider");
        chosenProvider = fallback;
    } else {
        NSLog(@"[VGCameraGraphFactory] 9B-3: VGLiteRTMaskProvider ready — "
              @"injecting ML provider");
        chosenProvider = mlProvider;
    }

    // ── 5. Inject provider via DI initializer ────────────────────────────────
    return [[VGSegmentationNode alloc] initWithPool:pool
                                             device:device
                                           provider:chosenProvider];
#else
    // Gate OFF: identical to the existing production call site.
    return [[VGSegmentationNode alloc] initWithPool:pool device:device];
#endif
}

+ (nullable NSDictionary<NSString *, id> *)
    buildCameraGraphWithSource:(VanguardCameraMediaSource *)source
                   filterChain:(nullable NSArray *)filterChain
                      renderer:(VanguardMetalRenderer *)renderer
                         error:(NSError * _Nullable * _Nullable)outError
{
    // Convenience overload — preserves original single-renderer fan-out behaviour.
    return [self buildCameraGraphWithSource:source
                                filterChain:filterChain
                                   renderer:renderer
                           platformViewSink:nil
                                      error:outError];
}

+ (nullable NSDictionary<NSString *, id> *)
    buildCameraGraphWithSource:(VanguardCameraMediaSource *)source
                   filterChain:(nullable NSArray *)filterChain
                      renderer:(VanguardMetalRenderer *)renderer
             platformViewSink:(nullable id<VGFrameSink>)platformViewSink
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
        } else if ([filter conformsToProtocol:@protocol(VGMetalFilterNode)] ||
                   [filter respondsToSelector:@selector(processEnvelope:device:)]) {
            VGLegacyFilterAdapter *lAdapter =
                [[VGLegacyFilterAdapter alloc] initWithFilter:filter];
            [filterAdapters addObject:lAdapter];
        } else {
            NSLog(@"[VGCameraGraphFactory] buildCameraGraph: skipping unrecognised "
                  @"filter (class=%@) — does not conform to VGMetalFilterNode or "
                  @"VGSegmentationNode", [filter class]);
        }
    }

    // ── (d) Wrap renderer and construct composite VGFanOutSink ─────────────────
    VGRendererSinkAdapter *rendererSinkAdapter = [[VGRendererSinkAdapter alloc] initWithRenderer:renderer];

    // Phase 6E.1B: Instantiate the recording sink. Disabled by default — presentEnvelope:
    // is an immediate no-op in this step. Held as last child of VGFanOutSink so the
    // topology is ready for Phase 6E.1C wiring without a graph rebuild.
    VGRecordingSinkNode *recordingSink =
        [[VGRecordingSinkNode alloc] initWithNodeId:@"camera_recording_sink"
                                             source:source];
    // recordingSink.enabled remains NO (the default). No frames are forwarded.

    // Phase 6E.2A: Instantiate the photo sink skeleton. presentEnvelope: is an
    // unconditional no-op in this phase — no arming, encoding, or file I/O.
    // Held as the final child of VGFanOutSink to reserve the topology slot
    // for Phase 6E.2B one-shot capture wiring.
    VGPhotoSinkNode *photoSink =
        [[VGPhotoSinkNode alloc] initWithNodeId:@"camera_photo_sink"];

    // POC2: when platformViewSink is provided, include it as a second child of
    // VGFanOutSink so graph output (post-Beauty-V2) reaches the MTKView PlatformView.
    // When nil: original single-child behaviour is preserved exactly.
    // Recording sink and photo sink are always appended last.
    NSArray<id<VGFrameSink>> *sinkChildren;
    if (platformViewSink) {
        sinkChildren = @[ rendererSinkAdapter, platformViewSink, recordingSink, photoSink ];
        NSLog(@"[VGCameraGraphFactory] Phase 6E.2A: building four-child VGFanOutSink "
               "(renderer + platformView + recordingSink + photoSink[skeleton])");
    } else {
        sinkChildren = @[ rendererSinkAdapter, recordingSink, photoSink ];
        NSLog(@"[VGCameraGraphFactory] Phase 6E.2A: building three-child VGFanOutSink "
               "(renderer + recordingSink + photoSink[skeleton])");
    }

    VGFanOutSink *fanOutSink = [[VGFanOutSink alloc] initWithNodeId:@"fan_out_sink"
                                                               sinks:sinkChildren];
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
    // Phase 6E.1D.1: expose the recording sink by its own nodeId so that
    // VGCameraGraphSession can resolve it via _nodes[@"camera_recording_sink"]
    // in setRecordingEnabled: and graph-rebuild propagation. The sink is already
    // a child of fanOutSink — this entry does not affect graph topology.
    nodeMap[recordingSink.nodeId] = recordingSink;
    // Phase 6E.2A: expose the photo sink by its own nodeId so that
    // VGCameraGraphSession can resolve it via _nodes[@"camera_photo_sink"]
    // in future Phase 6E.2B arming. The sink is already a child of fanOutSink
    // — this entry does not affect graph topology.
    nodeMap[photoSink.nodeId] = photoSink;

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
