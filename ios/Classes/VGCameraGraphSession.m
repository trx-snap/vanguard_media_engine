// VGCameraGraphSession.m
// vanguard_media_engine — Phase 6A-2 / Phase 6A-3D-2 / Phase 6A-3G-C
//
// Implementation of VGCameraGraphSession.
// Phase 6A-3D-2 adds setCameraFilterChainFromSpecs:error: — Beauty V1 construction
// from Dart/plugin specs using the session-owned pool and Metal device.
//
// Phase 6A-3G-C: Async camera graph handoff.
// VGCameraGraphSession now acts as the renderer.frameDelegate (not _scheduler).
// Its didReceiveRawFrame: retains the incoming buffer, checks an atomic in-flight
// flag (drop-latest backpressure), and dispatches the real graph traversal
// asynchronously onto com.vanguard.cameraGraphExecution, returning immediately
// to the capture delegate queue.
//
// Ownership contract for the async path:
//   capture queue retains buffer (line ~461 in VanguardCameraMediaSource.m).
//   _onVideoFrame: passes frameToDeliver (+0 or +1 rotated) to us.
//   We call CVPixelBufferRetain to add our own +1 for the async block.
//   After we return, _onVideoFrame: releases its references (rawFrame + rotated).
//   Inside the async block: we call [scheduler didReceiveRawFrame:] which treats
//   the buffer as source-owned (does not release it). After the scheduler returns
//   we CVPixelBufferRelease our +1.
//
// Scheduler hot-swap safety:
//   The async block captures the *current* scheduler at enqueue time as a local
//   strong reference. Even if setCameraFilterChain: swaps _scheduler on the
//   session queue while a block is queued, the block executes against the
//   scheduler it was enqueued for — no stale-pointer risk.
//
// Thread safety of _graphInFlight:
//   _graphInFlight is _Atomic(BOOL). The in-flight check uses atomic_compare_
//   exchange_strong so concurrent calls from the serial capture queue are safe.

#import "VGCameraGraphSession.h"
#import "VGUseCameraGraph.h"
#import "VGCameraGraphFactory.h"
#import "VGGraphSchedulerV2.h"
#import "VGFanOutSink.h"
#import "VGPlatformViewSinkAdapter.h"
#import "VanguardCameraMediaSource.h"
#import "VanguardMetalRenderer.h"
#import "VanguardBeautyFilterNode.h"
#import "BeautyV2FilterGroup.h"

#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGFrameDelegate.h>
#import <UMF/VGResourceAllocator.h>
#import <UMF/VGNode.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGFrameEnvelope.h>
#import <stdatomic.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

// 3G-C: VGCameraGraphSession adopts VGFrameDelegate so it can act as the
// renderer.frameDelegate instead of _scheduler. This gives the session full
// control over the async handoff boundary.
@interface VGCameraGraphSession () <VGFrameDelegate>
- (BOOL)_queryDimensionsWidth:(size_t *)outWidth height:(size_t *)outHeight;
- (id)_sessionPool;
- (NSUInteger)_sessionPoolBytes;
@end

@implementation VGCameraGraphSession {
    VanguardCameraMediaSource *_source;
    __weak VanguardMetalRenderer *_renderer;
    VGGraphSchedulerV2 *_scheduler;
    VGGraphExecutionContext *_context;
    NSDictionary<NSString *, id<VGNode>> *_nodes;
    _Atomic(BOOL) _invalidated;
    dispatch_queue_t _sessionQueue;
    CVPixelBufferPoolRef _sessionPool;
    NSUInteger _sessionPoolBytes;

    // 3G-C: dedicated serial queue for graph execution (off capture delegate queue).
    dispatch_queue_t _graphExecutionQueue;
    // 3G-C: drop-latest backpressure flag. Set when a graph block is in-flight;
    // cleared when that block finishes. Subsequent raw frames are dropped until
    // the in-flight block completes.
    _Atomic(BOOL) _graphInFlight;

    // POC2: optional platform view sink. Set by connectPlatformViewReceiver:.
    // Retained strongly — the VGPlatformViewSinkAdapter itself holds _receiver weakly.
    VGPlatformViewSinkAdapter *_platformViewSink;

    // POC2: cache the most recent filter chain so connectPlatformViewReceiver:
    // can trigger a rebuild that preserves the current filter state.
    NSArray *_currentFilterChain;
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
    atomic_init(&_graphInFlight, NO);
    _sessionQueue = dispatch_queue_create("com.vanguard.cameraGraphSession",
                                          DISPATCH_QUEUE_SERIAL);
    // 3G-C: serial execution queue for graph traversal.
    // QoS userInteractive to match the AVCaptureVideoDataOutput priority; the
    // graph must keep up with camera frame delivery or the in-flight flag will
    // drop frames (expected and intentional backpressure).
    _graphExecutionQueue =
        dispatch_queue_create("com.vanguard.cameraGraphExecution",
                              dispatch_queue_attr_make_with_qos_class(
                                  DISPATCH_QUEUE_SERIAL,
                                  QOS_CLASS_USER_INTERACTIVE, 0));
    _sessionPool = NULL;
    _sessionPoolBytes = 0;

    size_t width = 0;
    size_t height = 0;
    if ([self _queryDimensionsWidth:&width height:&height]) {
        VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];
        NSUInteger poolBytes = width * height * 4 * 3;
        BOOL budgetReserved = [allocator canAllocatePoolBytes:poolBytes];
        if (budgetReserved) {
            _sessionPoolBytes = poolBytes;
        } else {
            NSLog(@"[VGCameraGraphSession] WARNING: Budget reservation of %lu bytes failed. Creating pool anyway.", (unsigned long)poolBytes);
            _sessionPoolBytes = 0;
        }
        _sessionPool = [allocator pixelBufferPoolWithWidth:width
                                                    height:height
                                                    format:kCVPixelFormatType_32BGRA
                                        minimumBufferCount:3];
    } else {
        NSLog(@"[VGCameraGraphSession] No camera dimensions available from source.");
        _sessionPool = NULL;
        _sessionPoolBytes = 0;
    }

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
    // 3G-C: Wire the SESSION as the frameDelegate of the renderer (not _scheduler
    // directly). The session's didReceiveRawFrame: provides the async boundary that
    // moves graph traversal off the capture delegate queue.
    renderer.frameDelegate = self;

    // Start frame dispatch.
    [_scheduler startWithClock:nil];

    return self;
}

- (void)setCameraFilterChain:(nullable NSArray *)filterChain {
    dispatch_sync(_sessionQueue, ^{
        if (atomic_load(&self->_invalidated)) {
            return;
        }

        NSLog(@"[VGCameraGraphSession] setCameraFilterChain: filterChain.count=%lu",
              (unsigned long)(filterChain.count ?: 0));

        VanguardMetalRenderer *renderer = self->_renderer;
        if (!self->_source || !renderer) {
            NSLog(@"[VGCameraGraphSession] setCameraFilterChain skipped — source=%@ renderer=%@",
                  self->_source, renderer);
            return;
        }

        // POC2: persist current filter chain so connectPlatformViewReceiver: can
        // trigger a rebuild that preserves filter state.
        // Defensive copy: caller may pass NSMutableArray; copy ensures the cached
        // value cannot be mutated behind our back.
        self->_currentFilterChain = [filterChain copy];

        NSError *rebuildError = nil;
        NSDictionary<NSString *, id> *newGraph =
            [VGCameraGraphFactory buildCameraGraphWithSource:self->_source
                                                 filterChain:filterChain
                                                    renderer:renderer
                                            platformViewSink:self->_platformViewSink
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

        // 3G-C: The session remains the permanent renderer.frameDelegate.
        // Only _scheduler is swapped. Async blocks enqueued after this point
        // will capture newScheduler because they read _scheduler at enqueue time
        // inside the session queue, which is serialized with this swap.
        // renderer.frameDelegate is NOT changed here — the session stays wired.
        self->_scheduler = newScheduler;
        self->_context = newCtx;
        self->_nodes = newNodes;

        NSLog(@"[VGCameraGraphSession] setCameraFilterChain hot-swap complete (filterCount=%lu execOrder=%lu)",
              (unsigned long)(filterChain.count ?: 0),
              (unsigned long)newPlan.topologicalOrder.count);
    });
}

// ─── POC2: connectPlatformViewReceiver: ───────────────────────────────────────
//
// Wires a VanguardCameraFrameReceiver into the graph as a second VGFanOutSink child.
//
// Strategy: store a VGPlatformViewSinkAdapter as _platformViewSink ivar, then
// trigger a full graph rebuild via setCameraFilterChain: (reusing _currentFilterChain)
// so the factory builds a two-child VGFanOutSink.
//
// Also disables POC1 raw direct forwarding on the camera source to prevent
// double delivery: raw (POC1 path) + graph-processed (POC2 path).
//
// REMOVE before Phase 7 / production.
- (BOOL)connectPlatformViewReceiver:(id<VanguardCameraFrameReceiver>)receiver {
    __block BOOL success = NO;
    dispatch_sync(_sessionQueue, ^{
        if (atomic_load(&self->_invalidated)) {
            NSLog(@"[Vanguard] POC2: connectPlatformViewReceiver — session is invalidated");
            return;
        }
        if (!receiver) {
            NSLog(@"[Vanguard] POC2: connectPlatformViewReceiver — receiver is nil");
            return;
        }

        // Create (or replace) the platform view sink adapter.
        self->_platformViewSink = [[VGPlatformViewSinkAdapter alloc] initWithReceiver:receiver];
        NSLog(@"[Vanguard] POC2: VGPlatformViewSinkAdapter created — will rebuild graph");

        // ── Disable POC1 raw direct forwarding ────────────────────────────────
        // POC1 raw delivery must not run while POC2 graph fan-out is active.
        // Setting platformViewRawForwardingEnabled=NO prevents captureOutput: from
        // calling [_frameReceiver onFrame:pixelBuffer pts:pts] directly, so the
        // MTKView receives only graph-processed frames from VGFanOutSink.
        if (self->_source) {
            self->_source.platformViewRawForwardingEnabled = NO;
            NSLog(@"[Vanguard] POC2: POC1 raw forwarding DISABLED on camera source ✓");
        }

        // ── Trigger graph rebuild with two-child VGFanOutSink ─────────────────
        // setCameraFilterChain: is called on _sessionQueue (we are already on it),
        // so we cannot dispatch_sync again — call the inner implementation directly.
        VanguardMetalRenderer *renderer = self->_renderer;
        if (!self->_source || !renderer) {
            NSLog(@"[Vanguard] POC2: connectPlatformViewReceiver — source or renderer nil");
            return;
        }

        NSError *rebuildError = nil;
        NSDictionary<NSString *, id> *newGraph =
            [VGCameraGraphFactory buildCameraGraphWithSource:self->_source
                                                 filterChain:self->_currentFilterChain
                                                    renderer:renderer
                                            platformViewSink:self->_platformViewSink
                                                       error:&rebuildError];
        if (!newGraph) {
            NSLog(@"[Vanguard] POC2: connectPlatformViewReceiver graph rebuild failed: %@",
                  rebuildError);
            return;
        }

        VGGraphDescriptor *newDesc = newGraph[@"descriptor"];
        NSDictionary<NSString *, id<VGNode>> *newNodes = newGraph[@"nodes"];
        VGExecutionPlan *newPlan = newGraph[@"plan"];

        id<VGFrameSink> newSink = (id<VGFrameSink>)newNodes[@"fan_out_sink"];
        if (!newSink) {
            NSLog(@"[Vanguard] POC2: connectPlatformViewReceiver — fan_out_sink missing after rebuild");
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
        [newScheduler startWithClock:nil];

        self->_scheduler = newScheduler;
        self->_context = newCtx;
        self->_nodes = newNodes;

        NSLog(@"[Vanguard] POC2: graph rebuilt with two-child VGFanOutSink — PlatformView wired ✓");
        success = YES;
    });
    return success;
}

// ─── Phase 6A-3D-2: Spec-driven filter construction ──────────────────────────
//
// Three-pass atomic validation:
//   Pass 1 — resource contract: pool and Metal device must exist.
//   Pass 2 — known-type check: every spec type must be in {beauty, lut, segmentation}.
//   Pass 3 — constructable check: type must be camera-constructable in this phase.
// Only after all three passes succeed are nodes constructed and the graph mutated.
//
// Known-but-unsupported types (lut, segmentation, beautyVersion:2) return
// UNSUPPORTED_FILTER_TYPE without mutating the graph.
// Unknown types return UNKNOWN_FILTER.
// Missing pool/device returns UNSUPPORTED_CAMERA_FILTER_RESOURCE_CONTRACT.

- (BOOL)setCameraFilterChainFromSpecs:(NSArray<NSDictionary *> *)specs
                                error:(NSError * _Nullable * _Nullable)outError
{
    if (outError) *outError = nil;

    // ── Empty specs: clear to passthrough ────────────────────────────────────
    if (!specs || specs.count == 0) {
        [self setCameraFilterChain:nil];
        return YES;
    }

    // ── Pass 1: resource contract ─────────────────────────────────────────────
    id<MTLDevice> metalDevice = [VGResourceAllocator sharedInstance].metalDevice;
    if (_sessionPool == NULL || !metalDevice) {
        if (outError) {
            *outError = [NSError
                errorWithDomain:@"UNSUPPORTED_CAMERA_FILTER_RESOURCE_CONTRACT"
                           code:1
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    @"Camera filter construction requires a session pool and Metal device. "
                     "Pool or device is unavailable."
            }];
        }
        NSLog(@"[VGCameraGraphSession] setCameraFilterChainFromSpecs: resource contract "
               "not satisfied (pool=%p device=%@)", _sessionPool, metalDevice);
        return NO;
    }

    // ── Pass 2: known-type check ──────────────────────────────────────────────
    static NSSet<NSString *> *knownTypes;
    static dispatch_once_t knownTypesToken;
    dispatch_once(&knownTypesToken, ^{
        knownTypes = [NSSet setWithObjects:@"beauty", @"lut", @"segmentation", nil];
    });

    for (NSDictionary *spec in specs) {
        NSString *type = spec[@"type"];
        if (![type isKindOfClass:[NSString class]] || ![knownTypes containsObject:type]) {
            NSString *badType = [type isKindOfClass:[NSString class]] ? type : @"(nil)";
            if (outError) {
                *outError = [NSError
                    errorWithDomain:@"UNKNOWN_FILTER"
                               code:2
                           userInfo:@{
                    NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"Unknown filter type: %@", badType]
                }];
            }
            NSLog(@"[VGCameraGraphSession] setCameraFilterChainFromSpecs: unknown type '%@'",
                  badType);
            return NO;
        }
    }

    // ── Pass 3: constructable check ───────────────────────────────────────────
    //
    // Phase 6A-3D-2: only beauty V1 is constructable.
    // lut and segmentation are known but deferred.
    // beauty with beautyVersion:2 is known but deferred.
    for (NSDictionary *spec in specs) {
        NSString *type = spec[@"type"];
        NSDictionary *params = spec[@"parameters"];

        if ([type isEqualToString:@"lut"]) {
            if (outError) {
                *outError = [NSError
                    errorWithDomain:@"UNSUPPORTED_FILTER_TYPE"
                               code:3
                           userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"Filter type 'lut' is not yet supported for the camera graph."
                }];
            }
            NSLog(@"[VGCameraGraphSession] setCameraFilterChainFromSpecs: lut deferred");
            return NO;
        }

        if ([type isEqualToString:@"segmentation"]) {
            if (outError) {
                *outError = [NSError
                    errorWithDomain:@"UNSUPPORTED_FILTER_TYPE"
                               code:3
                           userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"Filter type 'segmentation' is not yet supported for the camera graph."
                }];
            }
            NSLog(@"[VGCameraGraphSession] setCameraFilterChainFromSpecs: segmentation deferred");
            return NO;
        }

        if ([type isEqualToString:@"beauty"]) {
            // beautyVersion:2 is now constructable in Phase 6A-3E-V2.
            // beauty V1 (default/no key) remains the production path.
        }
    }

    // ── All specs valid: construct nodes ──────────────────────────────────────
    //
    // Only reached after all three validation passes succeed.
    NSMutableArray<id<VGMetalFilterNode>> *nodes =
        [NSMutableArray arrayWithCapacity:specs.count];

    for (NSDictionary *spec in specs) {
        NSString *type   = spec[@"type"];
        NSDictionary *params = spec[@"parameters"];

        // Default enabled=YES when key is absent (Dart default).
        BOOL enabled = (spec[@"enabled"] != nil) ? [spec[@"enabled"] boolValue] : YES;

        if ([type isEqualToString:@"beauty"]) {
            BOOL wantV2 = [params[@"beautyVersion"] isKindOfClass:[NSNumber class]] &&
                          [params[@"beautyVersion"] integerValue] == 2;

            if (wantV2) {
                // ── Beauty V2 path (Phase 6A-3E-V2) ──────────────────────────
                // BeautyV2FilterGroup owns its own intermediate pools;
                // borrows _sessionPool for final output only (matches runtime pattern).
                BeautyV2FilterGroup *v2 =
                    [[BeautyV2FilterGroup alloc] initWithPool:_sessionPool
                                                       device:metalDevice];
                if (v2) {
                    if ([params[@"intensity"] isKindOfClass:[NSNumber class]]) {
                        v2.intensity = [params[@"intensity"] floatValue];
                    }
                    v2.enabled = enabled;
                    [nodes addObject:(id<VGMetalFilterNode>)v2];
                }
            } else {
                // ── Beauty V1 path (default) ──────────────────────────────────
                VanguardBeautyFilterNode *beauty =
                    [[VanguardBeautyFilterNode alloc] initWithPool:_sessionPool
                                                            device:metalDevice];
                if ([params[@"intensity"] isKindOfClass:[NSNumber class]]) {
                    beauty.intensity = [params[@"intensity"] floatValue];
                }
                beauty.enabled = enabled;
                [nodes addObject:(id<VGMetalFilterNode>)beauty];
            }
        }
        // Additional constructable types will be added in future phases.
    }

    NSLog(@"[VGCameraGraphSession] setCameraFilterChainFromSpecs: constructed %lu node(s)",
          (unsigned long)nodes.count);

    // Delegate to the existing hot-swap method — it handles graph rebuild,
    // scheduler swap, and renderer delegate rewiring.
    [self setCameraFilterChain:nodes];
    return YES;
}

- (void)invalidate {
    dispatch_sync(_sessionQueue, ^{
        if (atomic_exchange(&self->_invalidated, YES)) {
            return;
        }

        // 3G-C: Clear renderer.frameDelegate while still on the session queue.
        // The session is the frameDelegate; clearing it prevents _onVideoFrame:
        // from calling our didReceiveRawFrame: after teardown begins.
        VanguardMetalRenderer *renderer = self->_renderer;
        if (renderer) {
            if (renderer.frameDelegate == self) {
                renderer.frameDelegate = nil;
            }
        }

        [self->_scheduler invalidate];

        if (self->_sessionPool) {
            CVPixelBufferPoolRelease(self->_sessionPool);
            self->_sessionPool = NULL;
        }
        if (self->_sessionPoolBytes > 0) {
            [[VGResourceAllocator sharedInstance] reportPoolReleased:self->_sessionPoolBytes];
            self->_sessionPoolBytes = 0;
        }

        self->_scheduler = nil;
        self->_context = nil;
        self->_nodes = nil;
        self->_source = nil;
    });

    // 3G-C: After the session queue has cleared frameDelegate (preventing new
    // enqueues), drain the graph execution queue synchronously. This ensures any
    // in-flight async block that captured a scheduler reference has finished and
    // released its retained buffer before invalidate returns.
    //
    // We must NOT hold _sessionQueue while doing this (deadlock risk if the
    // async block tries to dispatch_sync back). The dispatch_sync here is on a
    // *different* queue (_graphExecutionQueue), which is safe.
    dispatch_sync(_graphExecutionQueue, ^{
        // Intentionally empty — just draining any queued or in-flight block.
    });
}

- (void)dealloc {
    if (_sessionPool) {
        CVPixelBufferPoolRelease(_sessionPool);
        _sessionPool = NULL;
    }
    if (_sessionPoolBytes > 0) {
        [[VGResourceAllocator sharedInstance] reportPoolReleased:_sessionPoolBytes];
        _sessionPoolBytes = 0;
    }
}

- (BOOL)_queryDimensionsWidth:(size_t *)outWidth height:(size_t *)outHeight {
    if (![_source respondsToSelector:@selector(captureSession)]) {
        return NO;
    }
    AVCaptureSession *session = _source.captureSession;
    if (!session) {
        return NO;
    }
    
    AVCaptureDevice *device = nil;
    for (AVCaptureInput *input in session.inputs) {
        if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
            AVCaptureDeviceInput *deviceInput = (AVCaptureDeviceInput *)input;
            if ([deviceInput.device hasMediaType:AVMediaTypeVideo]) {
                device = deviceInput.device;
                break;
            }
        }
    }
    if (!device) {
        return NO;
    }
    
    AVCaptureVideoDataOutput *videoOutput = nil;
    for (AVCaptureOutput *output in session.outputs) {
        if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
            videoOutput = (AVCaptureVideoDataOutput *)output;
            break;
        }
    }
    if (!videoOutput) {
        return NO;
    }
    
    CMVideoFormatDescriptionRef formatDesc = device.activeFormat.formatDescription;
    if (!formatDesc) {
        return NO;
    }
    
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(formatDesc);
    size_t width = dims.width;
    size_t height = dims.height;
    
    AVCaptureConnection *connection = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (connection) {
        if (connection.videoOrientation == AVCaptureVideoOrientationPortrait ||
            connection.videoOrientation == AVCaptureVideoOrientationPortraitUpsideDown) {
            size_t temp = width;
            width = height;
            height = temp;
        }
    }
    
    if (width == 0 || height == 0) {
        return NO;
    }
    
    if (outWidth) *outWidth = width;
    if (outHeight) *outHeight = height;
    return YES;
}

- (id)_sessionPool {
    return (__bridge id)_sessionPool;
}

- (NSUInteger)_sessionPoolBytes {
    return _sessionPoolBytes;
}

+ (BOOL)isGraphModeEnabled {
#if defined(VG_USE_CAMERA_GRAPH) && (VG_USE_CAMERA_GRAPH != 0)
    return YES;
#else
    return NO;
#endif
}

// ─── VGFrameDelegate (Phase 6A-3G-C) ─────────────────────────────────────────
//
// This is the async boundary between the AVCapture delegate queue
// (com.vanguard.capture) and the graph execution queue
// (com.vanguard.cameraGraphExecution).
//
// Called by VanguardMetalRenderer._onVideoFrame: on com.vanguard.capture
// (a serial queue). Must return quickly — no GPU work, no filter execution.
//
// Ownership:
//   envelope.payload.videoBuffer: source-owned (+1). We add our own +1 via
//   CVPixelBufferRetain before the async dispatch so the buffer stays alive
//   after _onVideoFrame: releases its references. The async block releases
//   our +1 after [scheduler didReceiveRawFrame:] returns.
//
// Backpressure:
//   If _graphInFlight is already YES (previous frame still processing),
//   we drop the incoming frame and return immediately. This prevents frame
//   backlog on the execution queue and matches the AVFoundation drop-latest
//   model (alwaysDiscardsLateVideoFrames companion on the CPU side).
- (void)didReceiveRawFrame:(VGFrameEnvelope)envelope {
    // ── Guard: invalidated ────────────────────────────────────────────────────
    if (atomic_load(&_invalidated)) return;

    // ── Guard: no buffer ──────────────────────────────────────────────────────
    CVPixelBufferRef rawBuffer = envelope.payload.videoBuffer;
    if (!rawBuffer) return;

    // ── Backpressure: drop-latest ─────────────────────────────────────────────
    // Atomically set in-flight from NO→YES. If it was already YES, a block is
    // already executing — drop this frame.
    BOOL expected = NO;
    if (!atomic_compare_exchange_strong(&_graphInFlight, &expected, YES)) {
        // Frame dropped — graph execution is busy.
        return;
    }

    // ── Retain buffer for async lifetime ─────────────────────────────────────
    // _onVideoFrame: will release its references to rawFrame / frameToDeliver
    // after we return. We must hold our own +1 until the async block finishes.
    CVPixelBufferRetain(rawBuffer);

    // ── Capture scheduler at enqueue time ────────────────────────────────────
    // Read _scheduler under no explicit lock — assignment is done on
    // _sessionQueue which is separate from the capture queue. On ARM64, object
    // pointer reads are atomic. The strong local reference prevents dealloc
    // before the block executes.
    VGGraphSchedulerV2 *scheduler = _scheduler;

    // Build a retained envelope for the async block. The buffer pointer is the
    // same rawBuffer we just retained; everything else copies by value.
    VGFrameEnvelope asyncEnvelope = envelope;
    asyncEnvelope.payload.videoBuffer = rawBuffer; // already +1 from our retain

    __weak __typeof(self) weakSelf = self;
    dispatch_async(_graphExecutionQueue, ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;

        // ── Execute graph if session is still live ─────────────────────────
        // scheduler may be nil if invalidate was called between enqueue and here.
        if (strongSelf && !atomic_load(&strongSelf->_invalidated) && scheduler) {
            [scheduler didReceiveRawFrame:asyncEnvelope];
        }

        // ── Release our +1 retain ─────────────────────────────────────────
        // The scheduler has already called presentEnvelope: (synchronously),
        // which retained the buffer for the renderer. We now release our +1.
        CVPixelBufferRelease(rawBuffer);

        // ── Clear in-flight flag ──────────────────────────────────────────
        if (strongSelf) {
            atomic_store(&strongSelf->_graphInFlight, NO);
        }
    });
}

@end
