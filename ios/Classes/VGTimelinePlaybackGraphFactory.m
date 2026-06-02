// VGTimelinePlaybackGraphFactory.m
// Vanguard Media Engine — Phase 7 Stage 7.5C
//
// ═══════════════════════════════════════════════════════════════════════════════
// STAGE 7.5C — VISUAL TIMELINE PLAYBACK PROOF FACTORY
// ═══════════════════════════════════════════════════════════════════════════════
//
// This factory builds a minimal two-node V2 graph:
//
//   [VGTimelineCompositorNode] ──video_out──> [VGRendererSinkAdapter]
//
// VGTimelineCompositorNode is a V2-native <VGSourceNode>. It does NOT require
// a V1 adapter wrapper (VGFileSourceAdapter or VGImageSourceAdapter). Wrapping
// it would break pull-mode semantics because those adapters expect a
// VanguardFileMediaSource / VanguardImageMediaSource, not a compositor.
//
// VGGraphPlanner is NOT called (Opus MOD requirement and consistent with
// Stage 7.5A/B pattern). The scheduler discovers the compositor via the Phase 7
// self-sourcing-compositor fallback (VGNodeRoleCompositor + <VGSourceNode>).
//
// VGClockPolicyHybrid is used per Opus MOD-3:
//   "Use for: file playback, timeline scrub" (VGClockPolicy.h §Hybrid)
//   and UMF_V2_01_Core_DAG_Architecture.md §6.5 (clockPolicy: hybrid).
//   This is NOT VGClockPolicyPush (the V1 push-mode camera/file policy).
//
// VGGraphValidator IS called — the NoSource check was patched in Stage 7.5A
// to accept self-sourcing compositor nodes (VGNodeRoleCompositor with zero
// incoming edges and <VGSourceNode> conformance).

#import "VGTimelinePlaybackGraphFactory.h"

// ─── Stage 7.5A compositor (still imported for nodeId/nodeClass/nodeRole/declaredPorts
// access via the VGNode protocol) ——————————————————————————————————————
// Retained so VGGraphNodeDescriptor can be constructed from the VGNode protocol
// accessors (nodeId, nodeClass, nodeRole, declaredPorts). The factory no longer
// requires the concrete VGTimelineCompositorNode type — it works with any
// id<VGSourceNode> that also conforms to id<VGNode>.
#import "VGTimelineCompositorNode.h"

// ─── Renderer sink adapter (Phase 3) ─────────────────────────────────────────
#import "VGRendererSinkAdapter.h"
#import "VanguardMetalRenderer.h"

// ─── UMF V2 types ────────────────────────────────────────────────────────────
#import <UMF/VGGraphDescriptor.h>
#import <UMF/VGGraphNodeDescriptor.h>
#import <UMF/VGGraphConnection.h>
#import <UMF/VGGraphValidator.h>
#import <UMF/VGValidationError.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGClockPolicy.h>
#import <UMF/VGSinkAdmissionPolicy.h>
#import <UMF/VGNode.h>
#import <UMF/VGSourceNode.h>
#import <UMF/VGFrameSink.h>

// ─── System ──────────────────────────────────────────────────────────────────
#import <os/log.h>

static os_log_t sFactoryLog;

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGTimelinePlaybackGraphFactory
// ─────────────────────────────────────────────────────────────────────────────

@implementation VGTimelinePlaybackGraphFactory

+ (void)initialize {
    if (self == [VGTimelinePlaybackGraphFactory class]) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            sFactoryLog = os_log_create("com.vanguard.engine",
                                        "VGTimelinePlaybackGraphFactory");
        });
    }
}

// ─── Public factory method ────────────────────────────────────────────────────

+ (nullable NSDictionary<NSString *, id> *)
    buildTimelineGraphWithCompositorNode:(id<VGSourceNode>)compositorNode
                                renderer:(VanguardMetalRenderer *)renderer
                                   error:(NSError * _Nullable * _Nullable)outError
{
    NSParameterAssert(compositorNode != nil);
    NSParameterAssert(renderer != nil);

    // ── (a) Wrap the renderer in the V2 sink adapter ──────────────────────────
    //
    // VGRendererSinkAdapter stores the renderer as a WEAK reference (see
    // VGRendererSinkAdapter.h header). VanguardGraphRuntime owns the renderer;
    // the adapter must not extend its lifetime.
    //
    // Phase 7 Stage 7.5C: this is the SAME adapter used in Phase 4 (V1→V2
    // playback). No modification to the adapter is required because the
    // compositor's pullFrame: delivers the same VGFrameEnvelope contract.
    VGRendererSinkAdapter *sinkAdapter =
        [[VGRendererSinkAdapter alloc] initWithRenderer:renderer];

    // ── (b) Build the node map: nodeId → node ─────────────────────────────────
    //
    // VGTimelineCompositorNode does NOT require an adapter wrapper:
    //   - It is a V2-native <VGSourceNode> (pull-mode, pullFrame:).
    //   - Its nodeId is the original descriptor nodeId (set during init).
    //   - Its nodeClass and nodeRole are already correct for V2.
    //
    // Contrast with VGPlaybackGraphFactory which MUST wrap V1 sources in
    // VGFileSourceAdapter — this factory intentionally does NOT do that.
    NSMutableDictionary<NSString *, id<VGNode>> *nodeMap =
        [NSMutableDictionary dictionaryWithCapacity:2];
    nodeMap[compositorNode.nodeId] = compositorNode;
    nodeMap[sinkAdapter.nodeId]    = sinkAdapter;

    // ── (c) Build VGGraphNodeDescriptors ─────────────────────────────────────
    //
    // The compositor descriptor must match its runtime identity exactly so
    // VGGraphValidator can verify the self-sourcing topology.
    // parameters is @{} — the compositor was already initialized from
    // the full parameters dictionary before this factory was called.
    // The descriptor here is topology-only; it is not re-initialized from it.

    VGGraphNodeDescriptor *compositorDescriptor =
        [[VGGraphNodeDescriptor alloc] initWithNodeId:compositorNode.nodeId
                                            nodeClass:compositorNode.nodeClass
                                             nodeRole:compositorNode.nodeRole
                                           parameters:@{}
                                                ports:[compositorNode declaredPorts]];

    VGGraphNodeDescriptor *sinkDescriptor =
        [[VGGraphNodeDescriptor alloc] initWithNodeId:sinkAdapter.nodeId
                                            nodeClass:sinkAdapter.nodeClass
                                             nodeRole:sinkAdapter.nodeRole
                                           parameters:@{}
                                                ports:[sinkAdapter declaredPorts]];

    NSArray<VGGraphNodeDescriptor *> *nodeDescriptors =
        @[compositorDescriptor, sinkDescriptor];

    // ── (d) Build VGGraphConnection: compositor:video_out → sink:video_in ─────
    //
    // Single direct edge. dropLatest admission policy: the pull loop drives
    // timing; if the renderer is busy the oldest frame is dropped rather
    // than blocking the pull loop.
    //
    // Port names match declaredPorts:
    //   VGTimelineCompositorNode: video_out (VGMediaTypeVideo, required, output)
    //   VGRendererSinkAdapter:    video_in  (VGMediaTypeVideo, required, input)
    VGGraphConnection *directEdge =
        [VGGraphConnection synchronousEdgeFrom:compositorNode.nodeId
                                          port:@"video_out"
                                            to:sinkAdapter.nodeId
                                          port:@"video_in"
                             admissionPolicy:[VGSinkAdmissionPolicy dropLatest]];

    NSArray<VGGraphConnection *> *connections = @[directEdge];

    // ── (e) Build VGGraphDescriptor with VGClockPolicyHybrid ─────────────────
    //
    // graphId: "timelinePlaybackGraph" — distinct from "playbackGraph" (V1 push)
    //          and "exportGraph" (pull). Identifies this as the 7.5C proof graph.
    // clockPolicy: VGClockPolicyHybrid (MOD-3):
    //   "Use for: file playback, timeline scrub, paused-preview display."
    //   (VGClockPolicy.h §Hybrid, value = 2)
    //   This signals the pull-mode timeline cadence driven by VanguardGraphRuntime's
    //   CADisplayLink in Stage 7.5C rather than the push-mode V1 decode queue.
    // audioSidecar: nil — audio is not decoded in Stage 7.5 (Phase 8+).
    VGGraphDescriptor *descriptor =
        [[VGGraphDescriptor alloc] initWithGraphId:@"timelinePlaybackGraph"
                                             nodes:nodeDescriptors
                                       connections:connections
                                       clockPolicy:VGClockPolicyHybrid
                                      audioSidecar:nil];

    // ── (f) Validate via VGGraphValidator ─────────────────────────────────────
    //
    // VGGraphValidator.validateDescriptor:errors: runs structural checks:
    //   - At least one source or self-sourcing compositor.
    //     IMPORTANT: The Stage 7.5A validator patch accepts VGNodeRoleCompositor
    //     nodes with zero incoming edges + <VGSourceNode> conformance as a valid
    //     source. Without this patch, the "NoSource" check would reject this graph.
    //   - At least one sink.
    //   - No dangling connections or port references.
    //   - No cycles.
    //   - No NeverDrop policy on push-mode edges (not applicable here).
    NSArray<VGValidationError *> *validationErrors = nil;
    BOOL valid = [VGGraphValidator validateDescriptor:descriptor
                                              errors:&validationErrors];
    if (!valid) {
        if (outError) {
            NSString *desc = [NSString stringWithFormat:
                @"VGTimelinePlaybackGraphFactory: VGGraphValidator rejected "
                 "the timeline graph descriptor. Errors: %@",
                validationErrors];
            *outError = [NSError
                errorWithDomain:@"VGTimelinePlaybackGraphFactory"
                           code:1
                       userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        os_log_error(sFactoryLog,
                     "[VGTimelinePlaybackGraphFactory] validation failed: %{public}@",
                     validationErrors);
        return nil;
    }

    os_log_debug(sFactoryLog,
                 "[VGTimelinePlaybackGraphFactory] graph built and validated "
                 "compositorId=%{public}@ sinkId=%{public}@",
                 compositorNode.nodeId,
                 sinkAdapter.nodeId);

    // ── (g) Return result dictionary ──────────────────────────────────────────
    //
    // No VGExecutionPlan is returned — it is not needed because:
    //   1. VGGraphSchedulerV2 discovers the compositor via the Phase 7 fallback.
    //   2. The Stage 7.5C pull loop in VanguardGraphRuntime drives timing
    //      directly without an execution-plan topological walk.
    return @{
        @"compositorNode": compositorNode,
        @"sinkAdapter":    sinkAdapter,
        @"descriptor":     descriptor,
        @"nodes":          [nodeMap copy],
    };
}

@end
