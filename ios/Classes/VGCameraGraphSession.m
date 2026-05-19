// VGCameraGraphSession.m
// vanguard_media_engine — Phase 6A-2
//
// Implementation of VGCameraGraphSession.
//

#import "VGCameraGraphSession.h"
#import "VGUseCameraGraph.h"
#import "VGCameraGraphFactory.h"
#import "VGGraphSchedulerV2.h"
#import "VGFanOutSink.h"
#import "VanguardCameraMediaSource.h"
#import "VanguardMetalRenderer.h"

#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGResourceAllocator.h>
#import <UMF/VGNode.h>
#import <UMF/VGFrameSink.h>
#import <stdatomic.h>

@implementation VGCameraGraphSession {
    VanguardCameraMediaSource *_source;
    __weak VanguardMetalRenderer *_renderer;
    VGGraphSchedulerV2 *_scheduler;
    VGGraphExecutionContext *_context;
    NSDictionary<NSString *, id<VGNode>> *_nodes;
    _Atomic(BOOL) _invalidated;
    dispatch_queue_t _sessionQueue;
}

- (nullable instancetype)initWithSource:(VanguardCameraMediaSource *)source
                               renderer:(VanguardMetalRenderer *)renderer
                                  error:(NSError * _Nullable * _Nullable)outError
{
    // ── (a) Guard inputs ──────────────────────────────────────────────────────
    if (!source || !renderer) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGCameraGraphSession"
                                            code:100
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"VGCameraGraphSession: source and renderer must not be nil."
            }];
        }
        return nil;
    }

    self = [super init];
    if (!self) {
        return nil;
    }

    _source = source;
    _renderer = renderer;
    atomic_init(&_invalidated, NO);
    _sessionQueue = dispatch_queue_create("com.vanguard.cameraGraphSession",
                                          DISPATCH_QUEUE_SERIAL);

    // ── (b) Build the camera graph via factory ────────────────────────────────
    NSError *graphError = nil;
    NSDictionary<NSString *, id> *graphData = [VGCameraGraphFactory
        buildCameraGraphWithSource:source
                       filterChain:nil
                          renderer:renderer
                             error:&graphError];
    if (!graphData) {
        if (outError) {
            *outError = graphError;
        }
        return nil;
    }

    VGGraphDescriptor *descriptor = graphData[@"descriptor"];
    NSDictionary<NSString *, id<VGNode>> *nodes = graphData[@"nodes"];
    VGExecutionPlan *plan = graphData[@"plan"];

    // ── (c) Extract the composite VGFanOutSink ────────────────────────────────
    id<VGFrameSink> fanOutSink = (id<VGFrameSink>)nodes[@"fan_out_sink"];
    if (!fanOutSink) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"VGCameraGraphSession"
                                            code:101
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"VGCameraGraphSession: fan_out_sink node is missing from constructed graph."
            }];
        }
        return nil;
    }

    // ── (d) Initialize Execution Context and Scheduler ────────────────────────
    _context = [[VGGraphExecutionContext alloc] initWithDescriptor:descriptor
                                                              plan:plan
                                                             nodes:nodes
                                                             clock:nil
                                                 resourceAllocator:[VGResourceAllocator sharedInstance]];

    _scheduler = [[VGGraphSchedulerV2 alloc] initWithPlan:plan
                                                    nodes:nodes
                                                  context:_context];

    // Wire the composite VGFanOutSink to the scheduler as the delivery target.
    _scheduler.sink = fanOutSink;
    _nodes = nodes;

    // ── (e) Wire and start ────────────────────────────────────────────────────
    // Wire the scheduler as the frameDelegate of the renderer. When non-nil,
    // the renderer will forward raw camera frames to the scheduler's
    // didReceiveRawFrame: delegate method instead of executing the legacy filter path.
    renderer.frameDelegate = _scheduler;

    // Start frame dispatch
    [_scheduler startWithClock:nil];

    return self;
}

- (void)setCameraFilterChain:(nullable NSArray *)filterChain {
    dispatch_sync(_sessionQueue, ^{
        if (atomic_load(&self->_invalidated)) {
            return;
        }

        VanguardMetalRenderer *renderer = self->_renderer;
        if (!self->_source || !renderer) {
            NSLog(@"[VGCameraGraphSession] setCameraFilterChain skipped — source=%@ renderer=%@",
                  self->_source, renderer);
            return;
        }

        NSError *rebuildError = nil;
        NSDictionary<NSString *, id> *newGraph =
            [VGCameraGraphFactory buildCameraGraphWithSource:self->_source
                                                 filterChain:filterChain
                                                    renderer:renderer
                                                       error:&rebuildError];
        if (!newGraph) {
            NSLog(@"[VGCameraGraphSession] setCameraFilterChain rebuild failed: %@ — keeping current scheduler",
                  rebuildError);
            return;
        }

        VGGraphDescriptor *newDesc = newGraph[@"descriptor"];
        NSDictionary<NSString *, id<VGNode>> *newNodes = newGraph[@"nodes"];
        VGExecutionPlan *newPlan = newGraph[@"plan"];

        id<VGFrameSink> newSink = (id<VGFrameSink>)newNodes[@"fan_out_sink"];
        if (!newSink) {
            NSLog(@"[VGCameraGraphSession] setCameraFilterChain fan_out_sink missing — keeping current scheduler");
            return;
        }

        VGGraphExecutionContext *newCtx =
            [[VGGraphExecutionContext alloc] initWithDescriptor:newDesc
                                                           plan:newPlan
                                                          nodes:newNodes
                                                          clock:nil
                                              resourceAllocator:[VGResourceAllocator sharedInstance]];

        VGGraphSchedulerV2 *newScheduler =
            [[VGGraphSchedulerV2 alloc] initWithPlan:newPlan
                                               nodes:newNodes
                                             context:newCtx];
        newScheduler.sink = newSink;

        // Structural proof only. startWithClock:nil starts the new scheduler.
        // Do NOT invalidate the old scheduler here because it would stop the
        // shared camera source.
        [newScheduler startWithClock:nil];

        renderer.frameDelegate = newScheduler;

        self->_scheduler = newScheduler;
        self->_context = newCtx;
        self->_nodes = newNodes;

        NSLog(@"[VGCameraGraphSession] setCameraFilterChain hot-swap complete (filterCount=%lu execOrder=%lu)",
              (unsigned long)(filterChain.count ?: 0),
              (unsigned long)newPlan.topologicalOrder.count);
    });
}

- (void)invalidate {
    dispatch_sync(_sessionQueue, ^{
        if (atomic_exchange(&self->_invalidated, YES)) {
            return;
        }

        VanguardMetalRenderer *renderer = self->_renderer;
        if (renderer) {
            if (renderer.frameDelegate == self->_scheduler) {
                renderer.frameDelegate = nil;
            }
        }

        [self->_scheduler invalidate];

        self->_scheduler = nil;
        self->_context = nil;
        self->_nodes = nil;
        self->_source = nil;
    });
}

+ (BOOL)isGraphModeEnabled {
#if defined(VG_USE_CAMERA_GRAPH) && (VG_USE_CAMERA_GRAPH != 0)
    return YES;
#else
    return NO;
#endif
}

@end
