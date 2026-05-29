// VGGraphSchedulerV2.m
// Phase 4 Batch 2: V2 graph scheduler. No runtime wiring.
//
// Implementation of VGGraphSchedulerV2.
//
// This scheduler does NOT call pullFrame: (push mode only, Phase 4).
// This scheduler does NOT import VanguardMetalRenderer.
// This scheduler does NOT import or reference VanguardGraphRuntime.
// All lifecycle management of VanguardGraphRuntime remains in VanguardGraphRuntime.
//
// Execution model:
//   didReceiveRawFrame: runs on _videoDecodeQueue (the source's serial decode
//   queue), matching V1 VanguardGraphScheduler threading. No dispatch needed.
//
// Buffer ownership (RR-36):
//   Mirrored exactly from V1 VanguardGraphScheduler.m:
//   - rawBuffer:          source-owned (+1); NOT released by scheduler.
//   - frame:              tracks the current pixel buffer through the chain.
//   - schedulerOwnedDelivered: YES when frame is a NEW buffer from a filter
//     (scheduler holds +1). NO when frame is the source buffer or a passthrough.
//   - On filter producing a NEW buffer: release previous scheduler-owned
//     intermediate, adopt the new buffer.
//   - On filter failure (NULL output): release scheduler-owned intermediate,
//     release metadata on currentEnvelope, revert to source envelope, break.
//   - Passthrough node (returns same pointer as input): schedulerOwnedDelivered
//     is NOT updated to YES — avoids prematurely releasing a source-owned buffer
//     (documented RR-36 gotcha from V1).
//   - After presentEnvelope:: release scheduler's +1 if schedulerOwnedDelivered.
//
// Metadata cleanup (DEC-102):
//   VGFrameEnvelopeReleaseMetadata is called on currentEnvelope after
//   presentEnvelope: returns. The metadata pointer was CFRetained by
//   VGFrameEnvelopeCopyWithMetadata inside enrichEnvelope:device:.
//
// Execution order (DEC-54):
//   _executionOrder is pre-computed at init from plan.topologicalOrder,
//   filtered to include only VGNodeRoleFilter and VGNodeRoleMetadata nodes.
//   Source and sink nodes are excluded — no lock needed because the array
//   is immutable after init.
//
// Phase 4 Batch 2. Phase 4B+ wires this scheduler into VanguardGraphRuntime.

#import "VGGraphSchedulerV2.h"

// ─── Phase 3 adapter protocols (local imports) ────────────────────────────────
// These are referenced only via VGNode protocol — no concrete adapter types
// are imported directly. VGTransformNode and VGMetadataNode dispatch is done
// via conformsToProtocol: at runtime. No VanguardMetalRenderer import.

// ─── UMF V2 types ────────────────────────────────────────────────────────────
#import <UMF/VGSourceNode.h>
#import <UMF/VGTransformNode.h>
#import <UMF/VGMetadataNode.h>
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGResourceAllocator.h>

// ─── System ──────────────────────────────────────────────────────────────────
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <os/log.h>
#include <stdatomic.h>

// VGNodeRoleMetadata = 4 (declared as static const NSInteger in
// VGGraphNodeDescriptor.h; not in the base VGNodeRole NS_ENUM).
// Cast required — same pattern as VGMetadataNodeAdapter.m.
static const VGNodeRole kVGNodeRoleMetadata = (VGNodeRole)4;

static os_log_t sSchedulerV2Log;

// ─────────────────────────────────────────────────────────────────────────────

@implementation VGGraphSchedulerV2 {
    VGExecutionPlan                      *_plan;
    NSDictionary<NSString *, id<VGNode>> *_nodes;
    VGGraphExecutionContext              *_context;

    // Pre-computed from plan.topologicalOrder at init.
    // Contains only nodeIds with nodeRole == VGNodeRoleFilter or
    // nodeRole == kVGNodeRoleMetadata. Source and sink excluded.
    // Immutable after init — no lock needed (DEC-54).
    NSArray<NSString *>                  *_executionOrder;

    // Extracted from nodes at init — the push-mode source adapter.
    id<VGSourceNode>                      _sourceNode;

    // Metal device from context.resourceAllocator.metalDevice.
    // Stored at init; immutable thereafter.
    id<MTLDevice>                         _device;

    _Atomic(BOOL)                         _invalidated;
    BOOL                                  _running;
}

// ─── Initialization ───────────────────────────────────────────────────────────

+ (void)initialize {
    if (self == [VGGraphSchedulerV2 class]) {
        sSchedulerV2Log = os_log_create("com.vanguard.engine", "schedulerV2");
    }
}

- (instancetype)initWithPlan:(VGExecutionPlan *)plan
                       nodes:(NSDictionary<NSString *, id<VGNode>> *)nodes
                     context:(VGGraphExecutionContext *)context {
    NSParameterAssert(plan != nil);
    NSParameterAssert(nodes != nil);
    NSParameterAssert(context != nil);

    self = [super init];
    if (!self) return nil;

    _plan    = plan;
    _nodes   = nodes;
    _context = context;

    // ── (a) Extract Metal device from resource allocator ──────────────────────
    // STOP-B2-5 verified: VGResourceAllocator.metalDevice exists.
    _device = context.resourceAllocator.metalDevice;

    // ── (b) Pre-compute execution order — filter + metadata nodes only ─────────
    // STOP-B2-6 verified: VGExecutionPlan.topologicalOrder exists.
    // Walk the full topological order; include only nodes whose role
    // indicates they transform or enrich the frame. Source (role=0) and
    // sink (role=2) are excluded — they are not dispatched in the execution
    // loop. Metadata role is 4 (kVGNodeRoleMetadata — VGNodeRole cast).
    NSMutableArray<NSString *> *execOrder =
        [NSMutableArray arrayWithCapacity:plan.topologicalOrder.count];
    for (NSString *nodeId in plan.topologicalOrder) {
        id<VGNode> node = nodes[nodeId];
        if (!node) continue;
        VGNodeRole role = node.nodeRole;
        if (role == VGNodeRoleFilter || role == kVGNodeRoleMetadata) {
            [execOrder addObject:nodeId];
        }
    }
    _executionOrder = [execOrder copy]; // immutable after this point

    // ── (c) Extract source node ───────────────────────────────────────────────
    // Primary scan: standard VGNodeRoleSource node conforming to VGSourceNode.
    // All Phase 3–6 graphs (camera, file playback, export) have such a node.
    for (NSString *nodeId in nodes) {
        id<VGNode> node = nodes[nodeId];
        if (node.nodeRole == VGNodeRoleSource &&
            [node conformsToProtocol:@protocol(VGSourceNode)]) {
            _sourceNode = (id<VGSourceNode>)node;
            break;
        }
    }

    // Fallback scan: Phase 7 self-sourcing compositor.
    // VGTimelineCompositorNode returns VGNodeRoleCompositor (to match the
    // topology descriptor) but also conforms to <VGSourceNode> for pull-mode
    // execution. This fallback is only reached when no standard source is found,
    // so it is safe and backward-compatible with all existing graphs.
    // MOD-1 (Opus Phase 7 Stage 7.5 validation).
    if (!_sourceNode) {
        for (NSString *nodeId in nodes) {
            id<VGNode> node = nodes[nodeId];
            if (node.nodeRole == VGNodeRoleCompositor &&
                [node conformsToProtocol:@protocol(VGSourceNode)]) {
                _sourceNode = (id<VGSourceNode>)node;
                break;
            }
        }
    }

    atomic_store(&_invalidated, NO);
    _running = NO;

    os_log_debug(sSchedulerV2Log,
                 "[VGSchedulerV2] init: execOrder=%lu sourceNode=%@",
                 (unsigned long)_executionOrder.count,
                 _sourceNode ? _sourceNode.nodeId : @"<none>");
    return self;
}

// ─── Lifecycle ────────────────────────────────────────────────────────────────

- (void)startWithClock:(nullable id<VGMasterClock>)clock {
    // clock is accepted for API symmetry and future Phase 6+ hybrid-clock use.
    // Not used in Phase 4 push mode — source drives its own decode rate.
    (void)clock;

    if (atomic_load(&_invalidated)) return;

    _running = YES;
    if (_sourceNode) {
        [_sourceNode startProducing];
    }
    [_context transitionToState:VGGraphStateRunning];
    os_log_debug(sSchedulerV2Log, "[VGSchedulerV2] startWithClock:");
}

- (void)pause {
    if (atomic_load(&_invalidated)) return;

    _running = NO;
    if (_sourceNode) {
        [_sourceNode stopProducing];
    }
    [_context transitionToState:VGGraphStatePaused];
    os_log_debug(sSchedulerV2Log, "[VGSchedulerV2] pause");
}

- (void)resume {
    if (atomic_load(&_invalidated)) return;

    _running = YES;
    if (_sourceNode) {
        [_sourceNode startProducing];
    }
    [_context transitionToState:VGGraphStateRunning];
    os_log_debug(sSchedulerV2Log, "[VGSchedulerV2] resume");
}

- (void)seekTo:(CMTime)time generation:(uint64_t)generation {
    // generation parameter accepted for API symmetry with V1 protocol.
    // V2 uses the context's atomic generation counter as the authoritative value.
    (void)generation;

    if (atomic_load(&_invalidated)) return;

    // Atomically increment context generation so in-flight frames from
    // the previous position are detected as stale by source and sink adapters.
    [_context incrementGeneration];

    if (_sourceNode) {
        [_sourceNode seekTo:time generation:_context.generation];
    }
    os_log_debug(sSchedulerV2Log,
                 "[VGSchedulerV2] seekTo: generation=%llu",
                 (unsigned long long)_context.generation);
}

- (void)invalidate {
    // Idempotent: only the first call executes teardown (atomic CAS).
    BOOL expected = NO;
    if (!atomic_compare_exchange_strong(&_invalidated, &expected, YES))
        return;

    // Stop source production before invalidating nodes so the source
    // does not deliver frames to nodes that are being torn down.
    if (_sourceNode) {
        [_sourceNode stopProducing];
    }

    // Invalidate all nodes. _nodes is immutable NSDictionary — safe to
    // enumerate without a lock; _invalidated gate prevents re-entry.
    for (NSString *nodeId in _nodes) {
        id<VGNode> node = _nodes[nodeId];
        [node invalidate];
    }

    [_context transitionToState:VGGraphStateStopped];
    _running = NO;

    os_log_debug(sSchedulerV2Log, "[VGSchedulerV2] invalidate");
}

// ─── VGFrameDelegate ─────────────────────────────────────────────────────────

/// Receives a raw decoded frame from VanguardMetalRenderer._onVideoFrame:
/// via the VGFrameDelegate protocol and drives the V2 execution plan.
///
/// Execution model:
///   Called on _videoDecodeQueue (the source's serial decode queue).
///   Queue identity preserved — no dispatch. G-02 A/V sync ordering holds.
///
/// Buffer ownership (RR-36) — mirrors V1 VanguardGraphScheduler.m exactly:
///   rawBuffer:                 source-owned; NOT released by scheduler.
///   frame:                     current CVPixelBufferRef through the chain.
///   schedulerOwnedDelivered:   YES when frame is a NEW filter-produced buffer.
///
///   Filter produces NEW buffer:
///     Release previous scheduler-owned intermediate.
///     Adopt new buffer; set schedulerOwnedDelivered = YES.
///   Filter returns SAME pointer (passthrough):
///     Do NOT update schedulerOwnedDelivered to YES — avoids double-free of
///     source buffer (documented RR-36 gotcha: passthrough without retain).
///   Filter returns NULL:
///     Release scheduler-owned intermediate.
///     Release metadata on currentEnvelope (DEC-102 leak prevention).
///     Revert to source envelope; break chain.
///   After presentEnvelope::
///     Release scheduler's +1 if schedulerOwnedDelivered.
///
/// Metadata cleanup (DEC-102):
///   VGFrameEnvelopeReleaseMetadata called on currentEnvelope after delivery.
///   This releases the CFRetained metadata pointer from enrichEnvelope:device:.
///
/// No pullFrame: call is made — push mode only in Phase 4.
- (void)didReceiveRawFrame:(VGFrameEnvelope)envelope {
    // ── Guard ─────────────────────────────────────────────────────────────────
    if (atomic_load(&_invalidated)) return;
    if (!_running)                  return;

    id<VGFrameSink> sink = self.sink;
    if (!sink) return; // no sink wired yet — drop frame safely

    // ── RR-36: buffer ownership tracking ─────────────────────────────────────
    // rawBuffer: source-owned (+1 held by source decode cycle). NOT released here.
    CVPixelBufferRef rawBuffer            = envelope.payload.videoBuffer;
    CVPixelBufferRef frame                = rawBuffer; // start: source-owned
    BOOL             schedulerOwnedDelivered = NO;    // RR-36 ownership flag
    VGFrameEnvelope  currentEnvelope      = envelope;

    // ── Execute plan order: filter and metadata nodes only ───────────────────
    // _executionOrder is pre-computed at init (DEC-54: no lock needed).
    // Source and sink nodes are excluded from this array.
    for (NSString *nodeId in _executionOrder) {
        id<VGNode> node = _nodes[nodeId];
        if (!node) continue;

        VGFrameEnvelope result;

        if ([node conformsToProtocol:@protocol(VGTransformNode)]) {
            // ── Transform node (VGLegacyFilterAdapter) ────────────────────────
            id<VGTransformNode> transform = (id<VGTransformNode>)node;
            if (!transform.enabled) {
                // DEC-55: pass disabled nodes through unchanged.
                continue;
            }
            // STOP-B2-2 verified: processEnvelope:device: signature matches.
            result = [transform processEnvelope:currentEnvelope device:_device];

        } else if ([node conformsToProtocol:@protocol(VGMetadataNode)]) {
            // ── Metadata node (VGMetadataNodeAdapter) ────────────────────────
            // enrichEnvelope:device: enriches the envelope with side-channel
            // metadata and returns the same video buffer (passthrough).
            // The returned envelope may differ in the metadata field but the
            // video buffer pointer is the same — do NOT treat as scheduler-owned.
            // STOP-B2-3 verified: enrichEnvelope:device: signature matches.
            id<VGMetadataNode> metadata = (id<VGMetadataNode>)node;
            result = [metadata enrichEnvelope:currentEnvelope device:_device];

        } else {
            // Unknown role in execution order — skip defensively.
            os_log_debug(sSchedulerV2Log,
                         "[VGSchedulerV2] unknown node role for nodeId=%@, skipping",
                         nodeId);
            continue;
        }

        // ── NULL output: revert to source envelope ───────────────────────────
        if (!result.payload.videoBuffer) {
            // Release any scheduler-owned intermediate before reverting.
            if (schedulerOwnedDelivered) {
                CVPixelBufferRelease(frame);
                schedulerOwnedDelivered = NO;
            }
            // DEC-102: release metadata attached to currentEnvelope before
            // reverting — prevents a CFRetained metadata leak on failure.
            VGFrameEnvelopeReleaseMetadata(&currentEnvelope);
            frame           = rawBuffer;  // revert to source-owned buffer
            currentEnvelope = envelope;   // revert envelope (metadata=NULL)
            break;                        // skip remaining nodes
        }

        // ── Release previous intermediate if scheduler-owned ─────────────────
        if (schedulerOwnedDelivered) {
            CVPixelBufferRelease(frame);
        }

        // ── Adopt new buffer — track ownership per RR-36 ─────────────────────
        // Only mark scheduler-owned if the node produced a NEW buffer pointer.
        // Passthrough nodes (VGMetadataNodeAdapter) return the same pointer
        // without adding a retain. Marking that as scheduler-owned would cause
        // the next CVPixelBufferRelease(frame) to free the source-owned buffer
        // prematurely (RR-36 documented gotcha from V1).
        CVPixelBufferRef newBuffer = result.payload.videoBuffer;
        if (newBuffer != currentEnvelope.payload.videoBuffer) {
            schedulerOwnedDelivered = YES; // new buffer: scheduler owns +1
        }
        // else: same buffer returned (passthrough) — schedulerOwnedDelivered
        // retains its previous value; do not flip to YES here.
        frame           = newBuffer;
        currentEnvelope = result;
    }

    // ── Deliver final envelope to sink (RR-36: synchronous, same call stack) ─
    // STOP-B2-4 verified: presentEnvelope: signature matches VGFrameSink.
    VGFrameEnvelope deliveredEnvelope         = currentEnvelope;
    deliveredEnvelope.payload.videoBuffer     = frame;
    // presentEnvelope: retains the buffer before storing (RR-36 renderer side).
    [sink presentEnvelope:deliveredEnvelope];

    // ── Post-delivery cleanup (RR-36) ─────────────────────────────────────────
    // Release scheduler's +1 on filter-produced buffer now that the sink has
    // taken its own +1. Source-owned buffers must NOT be released here.
    if (schedulerOwnedDelivered) {
        CVPixelBufferRelease(frame);
    }

    // DEC-102: release metadata attached by VGMetadataNode.enrichEnvelope:device:.
    // The metadata pointer was CFRetained by VGFrameEnvelopeCopyWithMetadata;
    // release it here after the final consumer has had the opportunity to read it.
    // The sink (VGRendererSinkAdapter → VanguardMetalRenderer.presentEnvelope:)
    // does not use metadata — only the pixel buffer is stored.
    VGFrameEnvelopeReleaseMetadata(&currentEnvelope);

    // Note: rawBuffer (source-owned) is NOT released here. VanguardMetalRenderer
    // releases its copy when it forwarded the frame to this delegate. The source's
    // own +1 persists until the next decode cycle. No double-release.

    os_log_debug(sSchedulerV2Log,
                 "[VGSchedulerV2] didReceiveRawFrame: execOrder=%lu schedulerOwned=%d",
                 (unsigned long)_executionOrder.count,
                 (int)schedulerOwnedDelivered);
}

// ─── Property accessor ────────────────────────────────────────────────────────

- (BOOL)isRunning {
    return _running;
}

@end
