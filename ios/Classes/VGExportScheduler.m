// VGExportScheduler.m
// vanguard_media_engine — Phase 5C-1
//
// Pull-mode export scheduler skeleton.
//
// This scheduler does NOT conform to VGFrameDelegate (no push-mode entry).
// This scheduler does NOT import VanguardMetalRenderer or VanguardGraphRuntime.
// This scheduler does NOT call didReceiveRawFrame:.
//
// Execution model:
//   startExport dispatches the pull loop on _exportQueue (private serial queue).
//   The loop calls [sourceNode pullFrame:request] for each frame, walks the
//   execution order forward for transforms/metadata, and delivers the final
//   envelope to id<VGFrameSink> via presentEnvelope:.
//
// Buffer ownership (RR-36):
//   Source-owned envelopes: the scheduler does NOT release the source buffer.
//   Filter-produced buffers: the scheduler releases them after presentEnvelope:
//   (or after the node chain if no sink is wired).
//   Metadata: VGFrameEnvelopeReleaseMetadata called post-delivery (DEC-102).
//
// Completion guarantee:
//   _completionSignaled is a CAS gate (0→1). Exactly one of the terminal paths
//   (EOS, error, cancel, invalidate) will win the CAS and fire completionHandler.
//
// Phase 5C-1. No real encoder. No AVAssetWriter. No runtime integration.

#import "VGExportScheduler.h"

#import <UMF/VGSourceNode.h>
#import <UMF/VGTransformNode.h>
#import <UMF/VGMetadataNode.h>
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGFrameRequest.h>
#import <UMF/VGFrameResult.h>
#import <UMF/VGResourceAllocator.h>
#import <UMF/VGRenderMode.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <os/log.h>
#include <stdatomic.h>

// VGNodeRoleMetadata = 4 — same cast pattern as VGGraphSchedulerV2.m line 66.
static const VGNodeRole kVGExportNodeRoleMetadata = (VGNodeRole)4;

static os_log_t sExportSchedulerLog;

// ─────────────────────────────────────────────────────────────────────────────

@implementation VGExportScheduler {
    VGExecutionPlan                      *_plan;
    NSDictionary<NSString *, id<VGNode>> *_nodes;
    VGGraphExecutionContext              *_context;
    int32_t                               _fps;

    // Pre-computed at init from plan.topologicalOrder — filter + metadata only.
    // Immutable after init. Same pattern as VGGraphSchedulerV2._executionOrder.
    NSArray<NSString *>                  *_executionOrder;

    // Extracted at init from nodes — the pull-mode source node.
    id<VGSourceNode>                      _sourceNode;

    // Metal device from context.resourceAllocator.metalDevice.
    id<MTLDevice>                         _device;

    // Private serial queue for the pull loop.
    dispatch_queue_t                      _exportQueue;

    // Frame counter — monotonically increasing. Drives PTS generation.
    int64_t                               _frameIndex;

    // Atomic state flags.
    _Atomic(BOOL)                         _invalidated;
    _Atomic(BOOL)                         _cancelled;
    _Atomic(BOOL)                         _running;

    // CAS gate: 0 → 1 exactly once. Guards completionHandler from firing twice.
    _Atomic(int32_t)                      _completionSignaled;
}

// ─── Initialization ───────────────────────────────────────────────────────────

+ (void)initialize {
    if (self == [VGExportScheduler class]) {
        sExportSchedulerLog = os_log_create("com.vanguard.engine", "exportScheduler");
    }
}

- (instancetype)initWithPlan:(VGExecutionPlan *)plan
                       nodes:(NSDictionary<NSString *, id<VGNode>> *)nodes
                     context:(VGGraphExecutionContext *)context
                         fps:(int32_t)fps {
    NSParameterAssert(plan != nil);
    NSParameterAssert(nodes != nil);
    NSParameterAssert(context != nil);

    self = [super init];
    if (!self) return nil;

    _plan    = plan;
    _nodes   = nodes;
    _context = context;
    _fps     = (fps > 0) ? fps : 30;

    // ── (a) Extract Metal device from resource allocator ──────────────────────
    _device = context.resourceAllocator.metalDevice;

    // ── (b) Pre-compute execution order — filter + metadata nodes only ────────
    // Walk the full topological order; include only nodes whose role indicates
    // they transform or enrich the frame. Source (role=0) and sink (role=2)
    // are excluded — they are not dispatched in the execution loop.
    // Metadata role is 4 (kVGExportNodeRoleMetadata — VGNodeRole cast).
    NSMutableArray<NSString *> *execOrder =
        [NSMutableArray arrayWithCapacity:plan.topologicalOrder.count];
    for (NSString *nodeId in plan.topologicalOrder) {
        id<VGNode> node = nodes[nodeId];
        if (!node) continue;
        VGNodeRole role = node.nodeRole;
        if (role == VGNodeRoleFilter || role == kVGExportNodeRoleMetadata) {
            [execOrder addObject:nodeId];
        }
    }
    _executionOrder = [execOrder copy]; // immutable after this point

    // ── (c) Extract source node ───────────────────────────────────────────────
    // Primary scan: standard VGNodeRoleSource node conforming to VGSourceNode.
    // All Phase 3–6 export graphs (VGExportFileSourceNode) have such a node.
    for (NSString *nodeId in nodes) {
        id<VGNode> node = nodes[nodeId];
        if (node.nodeRole == VGNodeRoleSource &&
            [node conformsToProtocol:@protocol(VGSourceNode)]) {
            _sourceNode = (id<VGSourceNode>)node;
            break;
        }
    }

    // Fallback scan: Phase 7 self-sourcing compositor.
    // VGTimelineCompositorNode returns VGNodeRoleCompositor (descriptor role)
    // but also conforms to <VGSourceNode> for pull-mode execution.
    // This fallback is only reached when no standard source is found,
    // so it is safe and backward-compatible with all existing export graphs.
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

    // ── (d) Private export queue ──────────────────────────────────────────────
    _exportQueue = dispatch_queue_create("com.vanguard.export.pull",
                                         DISPATCH_QUEUE_SERIAL);

    // ── (e) Initialize atomics ────────────────────────────────────────────────
    atomic_store(&_invalidated, NO);
    atomic_store(&_cancelled, NO);
    atomic_store(&_running, NO);
    atomic_store(&_completionSignaled, 0);
    _frameIndex = 0;

    os_log_debug(sExportSchedulerLog,
                 "[VGExportScheduler] init: execOrder=%lu fps=%d sourceNode=%@",
                 (unsigned long)_executionOrder.count,
                 _fps,
                 _sourceNode ? _sourceNode.nodeId : @"<none>");
    return self;
}

// ─── State accessors ──────────────────────────────────────────────────────────

- (BOOL)isRunning    { return (BOOL)atomic_load(&_running); }
- (BOOL)isCancelled  { return (BOOL)atomic_load(&_cancelled); }

// ─── Control ──────────────────────────────────────────────────────────────────

- (void)startExport {
    if (atomic_load(&_invalidated) || atomic_load(&_cancelled)) return;
    if (atomic_load(&_running)) return;

    atomic_store(&_running, YES);

    __weak typeof(self) weakSelf = self;
    dispatch_async(_exportQueue, ^{
        [weakSelf _runPullLoop];
    });
}

- (void)cancelExport {
    atomic_store(&_cancelled, YES);
    // The pull loop checks _cancelled on each iteration and will exit,
    // then fire completionHandler via _signalCompletionOnce:error:.
    os_log_debug(sExportSchedulerLog, "[VGExportScheduler] cancelExport requested");
}

- (void)invalidate {
    // Idempotent via CAS: only the first caller proceeds.
    BOOL expected = NO;
    if (!atomic_compare_exchange_strong(&_invalidated, &expected, YES)) {
        return; // already invalidated
    }

    atomic_store(&_cancelled, YES);
    atomic_store(&_running, NO);

    // Invalidate all nodes.
    for (NSString *nodeId in _nodes) {
        [_nodes[nodeId] invalidate];
    }

    // Transition context to stopped.
    [_context transitionToState:VGGraphStateStopped];

    // Fire completion with cancellation error if not already signaled.
    NSError *cancelError = [NSError errorWithDomain:@"VGExportScheduler"
                                               code:1
                                           userInfo:@{
        NSLocalizedDescriptionKey: @"Export invalidated"
    }];
    [self _signalCompletionOnce:NO error:cancelError];

    os_log_debug(sExportSchedulerLog, "[VGExportScheduler] invalidated");
}

// ─── Pull loop ────────────────────────────────────────────────────────────────

- (void)_runPullLoop {
    [_context transitionToState:VGGraphStateRunning];

    BOOL success = NO;
    NSError *loopError = nil;

    while (!atomic_load(&_cancelled) && !atomic_load(&_invalidated)) {

        // Phase 10-C C1C (RR-memory): Wrap the entire per-frame work unit in a
        // local @autoreleasepool so that CIImage / CIFilter / NSValue / CIContext
        // render-graph intermediates are drained after each frame rather than
        // accumulating in the dispatch block's implicit pool until loop exit.
        // Without this, a zoom/pan export of a 5 s / 150-frame 1080p clip can
        // build 3–4 GB of transient Core Image objects and trigger Jetsam.
        //
        // Safety notes:
        //   goto loop_exit  — exits the @autoreleasepool scope; Clang drains the
        //                     pool on any control-flow exit from the braces.
        //   continue        — re-enters the while condition; the pool is drained
        //                     before the next iteration's @autoreleasepool opens.
        //   CVPixelBufferRef / CMSampleBufferRef — retained (+1) before entering
        //                     the pool; CF retain counts are unaffected by pool
        //                     drain. Buffer ownership contracts are unchanged.
        @autoreleasepool {

        // ── 1. Create VGFrameRequest ──────────────────────────────────────────
        CMTime pts      = CMTimeMake(_frameIndex, _fps);
        CMTime duration = CMTimeMake(1, _fps);
        VGFrameRequest *request =
            [[VGFrameRequest alloc] initWithRequestedPTS:pts
                                                duration:duration
                                              generation:_context.generation
                                              renderSize:CGSizeZero
                                                    mode:VGRenderModeExport];

        // ── 2. Pull from source ───────────────────────────────────────────────
        VGFrameResult *result = nil;
        if (_sourceNode) {
            result = [_sourceNode pullFrame:request];
        }

        if (!result) {
            // Defensive: nil result treated as error.
            loopError = [NSError errorWithDomain:@"VGExportScheduler"
                                           code:2
                                       userInfo:@{
                NSLocalizedDescriptionKey: @"Source returned nil VGFrameResult"
            }];
            break;
        }

        // ── 3. Handle result status ───────────────────────────────────────────
        switch (result.status) {
            case VGFrameStatusEndOfStream:
                success = YES;
                goto loop_exit;

            case VGFrameStatusError:
                loopError = result.error;
                goto loop_exit;

            case VGFrameStatusSkipped:
                // Do not increment frameIndex for skipped frames.
                continue;

            case VGFrameStatusDelivered:
                break; // proceed to transform chain
        }

        // ── 4. Build working envelope from source result ──────────────────────
        VGFrameEnvelope sourceEnvelope  = result.envelope;
        CVPixelBufferRef rawBuffer       = (CVPixelBufferRef)sourceEnvelope.payload.videoBuffer;
        CVPixelBufferRef frame           = rawBuffer;
        BOOL schedulerOwnedBuffer        = NO;
        VGFrameEnvelope currentEnvelope  = sourceEnvelope;

        // ── 5. Walk execution order — transform + metadata nodes ──────────────
        // RR-36: when a node returns a NEW buffer (different pointer), the
        // scheduler takes ownership of that buffer (+1 via CF ownership rules
        // from the node's CVPixelBufferCreate). The previous scheduler-owned
        // buffer is released before adopting the new one. Source buffers are
        // never released by the scheduler.

        for (NSString *nodeId in _executionOrder) {
            id<VGNode> node = _nodes[nodeId];
            if (!node) continue;

            VGFrameEnvelope nodeResult;

            if ([node conformsToProtocol:@protocol(VGTransformNode)]) {
                id<VGTransformNode> transform = (id<VGTransformNode>)node;
                if (!transform.enabled) continue;
                nodeResult = [transform processEnvelope:currentEnvelope
                                                 device:_device];

            } else if ([node conformsToProtocol:@protocol(VGMetadataNode)]) {
                id<VGMetadataNode> metaNode = (id<VGMetadataNode>)node;
                nodeResult = [metaNode enrichEnvelope:currentEnvelope
                                               device:_device];
            } else {
                continue;
            }

            // If the node returned a NULL video buffer, revert to source envelope.
            CVPixelBufferRef newBuffer = (CVPixelBufferRef)nodeResult.payload.videoBuffer;
            if (!newBuffer) {
                if (schedulerOwnedBuffer) {
                    CVPixelBufferRelease(frame);
                    schedulerOwnedBuffer = NO;
                }
                VGFrameEnvelopeReleaseMetadata(&currentEnvelope);
                frame           = rawBuffer;
                currentEnvelope = sourceEnvelope;
                continue;
            }

            // Release previous scheduler-owned intermediate.
            if (schedulerOwnedBuffer) {
                CVPixelBufferRelease(frame);
            }

            // Scheduler owns the new buffer if the pointer changed.
            schedulerOwnedBuffer = (newBuffer != frame);
            frame           = newBuffer;
            currentEnvelope = nodeResult;
        }


        // ── 6. Deliver to sink ────────────────────────────────────────────────
        id<VGFrameSink> sink = self.sink;
        if (sink) {
            VGFrameEnvelope deliveredEnvelope     = currentEnvelope;
            deliveredEnvelope.payload.videoBuffer = frame;
            [sink presentEnvelope:deliveredEnvelope];
        }



        // ── 7. Post-delivery cleanup (RR-36 + DEC-102) ───────────────────────
        if (schedulerOwnedBuffer) {
            CVPixelBufferRelease(frame);
        }
        VGFrameEnvelopeReleaseMetadata(&currentEnvelope);

        // ── 8. Advance frame index on delivered frames ────────────────────────
        _frameIndex++;

        } // @autoreleasepool — Phase 10-C C1C: drain per-frame Core Image intermediates
    }

loop_exit:
    // If exited due to cancel flag (not EOS / error), wrap as cancellation error.
    if (atomic_load(&_cancelled) && !success && !loopError) {
        loopError = [NSError errorWithDomain:@"VGExportScheduler"
                                       code:1
                                   userInfo:@{
            NSLocalizedDescriptionKey: @"Export cancelled"
        }];
    }

    atomic_store(&_running, NO);

    // Transition context to stopped only if not already done by invalidate.
    if (!atomic_load(&_invalidated)) {
        [_context transitionToState:VGGraphStateStopped];
    }

    os_log_debug(sExportSchedulerLog,
                 "[VGExportScheduler] pull loop exit: success=%d frameIndex=%lld",
                 (int)success, (long long)_frameIndex);

    // Signal completion exactly once via CAS gate.
    [self _signalCompletionOnce:success error:loopError];
}

// ─── Completion gate ──────────────────────────────────────────────────────────

/// Fire completionHandler exactly once. Uses atomic CAS (0→1) as the gate.
/// Any terminal path that loses the CAS is silently suppressed.
- (void)_signalCompletionOnce:(BOOL)success error:(nullable NSError *)error {
    int32_t expected = 0;
    if (!atomic_compare_exchange_strong(&_completionSignaled, &expected, 1)) {
        return; // another terminal path already fired
    }
    void (^handler)(BOOL, NSError *) = self.completionHandler;
    if (handler) {
        handler(success, error);
    }
}

// ─── Dealloc ──────────────────────────────────────────────────────────────────

- (void)dealloc {
    [self invalidate];
}

@end
