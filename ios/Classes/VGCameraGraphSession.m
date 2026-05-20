// VGCameraGraphSession.m
// vanguard_media_engine — Phase 6A-2 / Phase 6A-3D-2
//
// Implementation of VGCameraGraphSession.
// Phase 6A-3D-2 adds setCameraFilterChainFromSpecs:error: — Beauty V1 construction
// from Dart/plugin specs using the session-owned pool and Metal device.

#import "VGCameraGraphSession.h"
#import "VGUseCameraGraph.h"
#import "VGCameraGraphFactory.h"
#import "VGGraphSchedulerV2.h"
#import "VGFanOutSink.h"
#import "VanguardCameraMediaSource.h"
#import "VanguardMetalRenderer.h"
#import "VanguardBeautyFilterNode.h"
#import "BeautyV2FilterGroup.h"

#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGResourceAllocator.h>
#import <UMF/VGNode.h>
#import <UMF/VGFrameSink.h>
#import <stdatomic.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

@interface VGCameraGraphSession ()
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

        NSLog(@"[VGCameraGraphSession] setCameraFilterChain: filterChain.count=%lu",
              (unsigned long)(filterChain.count ?: 0));

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

        VanguardMetalRenderer *renderer = self->_renderer;
        if (renderer) {
            if (renderer.frameDelegate == self->_scheduler) {
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

@end
