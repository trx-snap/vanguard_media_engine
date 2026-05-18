// VGImageExportSession.m
// vanguard_media_engine — Phase 5D-3
//
// Pull-mode still-image export coordinator.
//
// Chain:
//   VGImageSourceAdapter
//   → (optional VGLegacyFilterAdapter chain, topological order)
//   → VGImageEncoderSinkNode
//   → VGImageExportManifest
//
// Execution model:
//   1. Build VGGraphDescriptor (inline — source, transforms, sink; pull clock).
//   2. Validate with VGGraphValidator.
//   3. Plan with VGGraphPlanner.
//   4. Create VGGraphExecutionContext (clock=nil for pull mode).
//   5. Prepare all nodes via dispatch_group async barrier.
//   6. Check cancellation.
//   7. Pull one frame from the source adapter.
//   8. Walk the topological order: for each transform node, call
//      processEnvelope:device: and transfer ownership of the buffer.
//   9. presentEnvelope: on the sink (borrowed +0 call).
//  10. CVPixelBufferRelease on the owned buffer.
//  11. finalizeExportWithError: on the sink → VGImageExportManifest.
//  12. Invalidate all nodes.
//  13. Fire completion exactly once.
//
// Cancellation:
//   _cancelledAtomic is checked between every major step.
//   Completion fires with a cancellation NSError if cancelled.
//
// Completion gate:
//   _completionFired (C11 atomic_int) ensures exactly-once delivery via CAS.

#import "VGImageExportSession.h"
#import "VGImageSourceAdapter.h"
#import "VGImageEncoderSinkNode.h"
#import "VGLegacyFilterAdapter.h"
#import "VanguardImageMediaSource.h"

#import <UMF/VGGraphDescriptor.h>
#import <UMF/VGGraphNodeDescriptor.h>
#import <UMF/VGGraphConnection.h>
#import <UMF/VGGraphValidator.h>
#import <UMF/VGGraphPlanner.h>
#import <UMF/VGExecutionPlan.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGResourceAllocator.h>
#import <UMF/VGClockPolicy.h>
#import <UMF/VGSinkAdmissionPolicy.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGFrameRequest.h>
#import <UMF/VGFrameResult.h>
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGNode.h>
#import <UMF/VGTransformNode.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGRenderMode.h>
#import <UMF/VGMediaNode.h>

#import <CoreVideo/CoreVideo.h>
#import <stdatomic.h>
#import <os/log.h>

// ─── Log handle ──────────────────────────────────────────────────────────────

static os_log_t sSessionLog;

__attribute__((constructor))
static void _VGImageExportSessionLogInit(void) {
    sSessionLog = os_log_create("com.vanguard.export.image", "VGImageExportSession");
}

// ─── Error domain ─────────────────────────────────────────────────────────────

static NSString * const kVGImageExportSessionErrorDomain = @"VGImageExportSession";

typedef NS_ENUM(NSInteger, VGImageExportSessionErrorCode) {
    VGImageExportSessionErrorCancelled       = 1,
    VGImageExportSessionErrorGraphBuild      = 2,
    VGImageExportSessionErrorNodePrepare     = 3,
    VGImageExportSessionErrorSourcePull      = 4,
    VGImageExportSessionErrorFinalize        = 5,
    VGImageExportSessionErrorAlreadyStarted  = 6,
    VGImageExportSessionErrorInvalidArgs     = 7,
};

// ─── Node ID constants ────────────────────────────────────────────────────────

static NSString * const kSourceNodeId = @"imageSource";
static NSString * const kSinkNodeId   = @"imageSink";

// ─── Implementation ──────────────────────────────────────────────────────────

@implementation VGImageExportSession {
    // ── Inputs ────────────────────────────────────────────────────────────────
    VanguardImageMediaSource *_source;
    NSArray                  *_filterChain;   // nullable; id<VGMetalFilterNode>
    VGImageExportProfile     *_profile;
    NSURL                    *_outputURL;

    // ── Live nodes ────────────────────────────────────────────────────────────
    VGImageSourceAdapter   *_sourceAdapter;
    VGImageEncoderSinkNode *_sink;
    NSArray<VGLegacyFilterAdapter *> *_filterAdapters; // ordered, transform chain

    // ── Graph infrastructure ──────────────────────────────────────────────────
    VGGraphDescriptor        *_descriptor;
    VGExecutionPlan          *_plan;
    VGGraphExecutionContext   *_context;
    NSDictionary<NSString *, id<VGNode>> *_nodes; // all live nodes by nodeId

    // ── Execution ─────────────────────────────────────────────────────────────
    dispatch_queue_t _exportQueue;

    // ── Completion ────────────────────────────────────────────────────────────
    void (^_completion)(VGImageExportManifest * _Nullable, NSError * _Nullable);
    _Atomic(int32_t) _completionFired;   // 0 → 1 via CAS
    _Atomic(BOOL)    _cancelledAtomic;
    _Atomic(BOOL)    _startedAtomic;
    _Atomic(BOOL)    _finishedAtomic;
}

// ─── Designated initializer ───────────────────────────────────────────────────

- (instancetype)initWithSource:(VanguardImageMediaSource *)source
                   filterChain:(nullable NSArray *)filterChain
                       profile:(VGImageExportProfile *)profile
                     outputURL:(NSURL *)outputURL {
    NSParameterAssert(source != nil);
    NSParameterAssert(profile != nil);
    NSParameterAssert(outputURL != nil);

    self = [super init];
    if (!self) return nil;

    _source      = source;
    _filterChain = [filterChain copy];
    _profile     = profile;
    _outputURL   = [outputURL copy];

    atomic_init(&_completionFired,  0);
    atomic_init(&_cancelledAtomic,  NO);
    atomic_init(&_startedAtomic,    NO);
    atomic_init(&_finishedAtomic,   NO);

    _exportQueue = dispatch_queue_create(
        "com.vanguard.export.image.session",
        DISPATCH_QUEUE_SERIAL
    );

    return self;
}

// ─── State accessors ──────────────────────────────────────────────────────────

- (BOOL)isExporting {
    return atomic_load(&_startedAtomic) && !atomic_load(&_finishedAtomic);
}

- (BOOL)isCancelled {
    return atomic_load(&_cancelledAtomic);
}

- (BOOL)isFinished {
    return atomic_load(&_finishedAtomic);
}

// ─── Cancel ───────────────────────────────────────────────────────────────────

- (void)cancel {
    atomic_store(&_cancelledAtomic, YES);
}

// ─── Start ────────────────────────────────────────────────────────────────────

- (void)startWithCompletion:(void (^)(VGImageExportManifest * _Nullable,
                                      NSError * _Nullable))completion {
    NSParameterAssert(completion != nil);

    // Single-use gate: CAS 0→1.
    int32_t expected = 0;
    if (!atomic_compare_exchange_strong(&_startedAtomic, (BOOL *)&expected, YES)) {
        // Already started — do not fire completion again.
        return;
    }

    // Capture cancelled-before-start.
    if (atomic_load(&_cancelledAtomic)) {
        dispatch_async(_exportQueue, ^{
            completion(nil, [self _cancelledError]);
            atomic_store(&self->_finishedAtomic, YES);
        });
        return;
    }

    _completion = [completion copy];

    dispatch_async(_exportQueue, ^{
        [self _runExport];
    });
}

// ─── Private: main export sequence ────────────────────────────────────────────

- (void)_runExport {
    // ── Step 1: Build live nodes ──────────────────────────────────────────────

    _sourceAdapter = [[VGImageSourceAdapter alloc] initWithSource:_source];
    _sink          = [[VGImageEncoderSinkNode alloc] initWithOutputURL:_outputURL
                                                               profile:_profile];

    // Build filter adapters from the raw filterChain.
    NSMutableArray<VGLegacyFilterAdapter *> *adapters = [NSMutableArray array];
    for (id filter in _filterChain) {
        VGLegacyFilterAdapter *adapter = [[VGLegacyFilterAdapter alloc] initWithFilter:filter];
        [adapters addObject:adapter];
    }
    _filterAdapters = [adapters copy];

    // ── Step 2: Build VGGraphDescriptor ──────────────────────────────────────
    //
    // Inline construction — does NOT touch VGExportGraphFactory (Phase 5C, forbidden).
    //
    // Topology:
    //   [source] --video_out→video_in--> [transform_0] --video_out→video_in--> ...
    //   [transform_N-1] --video_out→video_in--> [sink]
    //
    // clockPolicy: VGClockPolicyPull (required for pull-mode image export).
    // Sink edge admissionPolicy: VGSinkAdmissionPolicyNeverDrop
    //   (valid on pull-mode graphs; VGGraphValidator enforces this rule).

    NSError *graphBuildErr = nil;
    VGGraphDescriptor *desc = [self _buildDescriptorError:&graphBuildErr];
    if (!desc) {
        os_log_error(sSessionLog,
                     "[VGImageExportSession] descriptor build failed: %{public}@",
                     graphBuildErr);
        [self _fireCompletionWithManifest:nil error:graphBuildErr];
        return;
    }
    _descriptor = desc;

    // ── Step 3: Validate ──────────────────────────────────────────────────────

    NSArray *validationErrors = nil;
    BOOL valid = [VGGraphValidator validateDescriptor:_descriptor errors:&validationErrors];
    if (!valid) {
        NSString *details = [validationErrors componentsJoinedByString:@"; "];
        NSError *err = [NSError errorWithDomain:kVGImageExportSessionErrorDomain
                                           code:VGImageExportSessionErrorGraphBuild
                                       userInfo:@{
            NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Graph validation failed: %@", details]
        }];
        os_log_error(sSessionLog,
                     "[VGImageExportSession] validation failed: %{public}@", details);
        [self _fireCompletionWithManifest:nil error:err];
        return;
    }

    // ── Step 4: Plan ──────────────────────────────────────────────────────────

    NSError *planErr = nil;
    VGExecutionPlan *plan = [VGGraphPlanner planFromDescriptor:_descriptor error:&planErr];
    if (!plan) {
        os_log_error(sSessionLog,
                     "[VGImageExportSession] planning failed: %{public}@", planErr);
        [self _fireCompletionWithManifest:nil error:planErr];
        return;
    }
    _plan = plan;

    // ── Step 5: Build nodes dictionary (nodeId → live node) ───────────────────

    NSMutableDictionary<NSString *, id<VGNode>> *nodesDict =
        [NSMutableDictionary dictionaryWithCapacity:(2 + _filterAdapters.count)];
    nodesDict[kSourceNodeId] = _sourceAdapter;
    nodesDict[kSinkNodeId]   = _sink;
    for (NSUInteger i = 0; i < _filterAdapters.count; i++) {
        NSString *nodeId = [self _transformNodeIdForIndex:i];
        nodesDict[nodeId] = _filterAdapters[i];
    }
    _nodes = [nodesDict copy];

    // ── Step 6: Create VGGraphExecutionContext ────────────────────────────────
    //
    // clock=nil: VGGraphExecutionContext.h — "Nil for pull-mode (export) graphs
    // that do not need a real-time clock."
    VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];
    _context = [[VGGraphExecutionContext alloc] initWithDescriptor:_descriptor
                                                              plan:_plan
                                                             nodes:_nodes
                                                             clock:nil
                                                 resourceAllocator:allocator];
    if (!_context) {
        NSError *err = [NSError errorWithDomain:kVGImageExportSessionErrorDomain
                                           code:VGImageExportSessionErrorGraphBuild
                                       userInfo:@{
            NSLocalizedDescriptionKey: @"VGGraphExecutionContext creation failed"
        }];
        [self _fireCompletionWithManifest:nil error:err];
        return;
    }

    // ── Step 7: Prepare all nodes (async dispatch_group barrier) ──────────────
    //
    // VGNode.h: "completion fires on a background queue, never synchronously."
    // We MUST use dispatch_group to handle async prepare completions.
    [self _prepareAllNodesWithCompletion:^(NSError * _Nullable prepareError) {
        if (prepareError) {
            os_log_error(sSessionLog,
                         "[VGImageExportSession] node prepare failed: %{public}@",
                         prepareError);
            [self _fireCompletionWithManifest:nil error:prepareError];
            return;
        }

        // ── Steps 8–13 on the export queue (already there via group_notify) ──
        [self _executeSingleFramePull];
    }];
}

// ─── Private: single-frame pull, transform walk, sink, finalize ───────────────

- (void)_executeSingleFramePull {
    // ── Cancellation check (post-prepare) ─────────────────────────────────────
    if (atomic_load(&_cancelledAtomic)) {
        [self _invalidateAllNodes];
        [self _fireCompletionWithManifest:nil error:[self _cancelledError]];
        return;
    }

    // ── Step 8: Pull one frame from the source adapter ────────────────────────
    //
    // VGFrameRequest carries PTS=kCMTimeZero, generation=context.generation.
    // A single-frame image source always returns the same image regardless of PTS.
    VGFrameRequest *request = [[VGFrameRequest alloc]
        initWithRequestedPTS:kCMTimeZero
                    duration:kCMTimeInvalid
                  generation:_context.generation
                  renderSize:CGSizeZero
                        mode:VGRenderModeExport];

    VGFrameResult *result = [_sourceAdapter pullFrame:request];

    if (result.status != VGFrameStatusDelivered) {
        NSError *err = result.error ?:
            [NSError errorWithDomain:kVGImageExportSessionErrorDomain
                               code:VGImageExportSessionErrorSourcePull
                           userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"Source pull returned status %ld", (long)result.status]
            }];
        os_log_error(sSessionLog,
                     "[VGImageExportSession] source pull failed: %{public}@", err);
        [self _invalidateAllNodes];
        [self _fireCompletionWithManifest:nil error:err];
        return;
    }

    // The envelope contains a +1 CVPixelBufferRef (from copyRawBuffer).
    // VGImageExportSession owns this buffer from here through presentEnvelope:.
    VGFrameEnvelope currentEnvelope = result.envelope;

    // ── Step 9: Walk the transform chain ──────────────────────────────────────
    //
    // Topological order from _plan.topologicalOrder — skipping source and sink.
    // Each transform's processEnvelope:device: is called synchronously.
    //
    // Buffer ownership transfer:
    //   - If a transform returns a new buffer in its output envelope,
    //     release the prior owned buffer and take ownership of the new one.
    //   - If the transform mutates in-place (no new buffer), ownership is
    //     unchanged.

    id<MTLDevice> metalDevice = [VGResourceAllocator sharedInstance].metalDevice;

    for (NSString *nodeId in _plan.topologicalOrder) {
        // Skip source and sink.
        if ([nodeId isEqualToString:kSourceNodeId] ||
            [nodeId isEqualToString:kSinkNodeId]) {
            continue;
        }

        // Cancellation check in the transform loop.
        if (atomic_load(&_cancelledAtomic)) {
            // Release the current owned buffer before exiting.
            CVPixelBufferRef ownedBuf = (CVPixelBufferRef)currentEnvelope.payload.videoBuffer;
            if (ownedBuf) CVPixelBufferRelease(ownedBuf);
            [self _invalidateAllNodes];
            [self _fireCompletionWithManifest:nil error:[self _cancelledError]];
            return;
        }

        id<VGNode> node = _nodes[nodeId];
        if (![node conformsToProtocol:@protocol(VGTransformNode)]) {
            // Not a transform (shouldn't happen given our topology) — skip.
            continue;
        }

        id<VGTransformNode> transform = (id<VGTransformNode>)node;

        // Record the prior owned buffer so we can release it if the transform
        // produces a new one.
        CVPixelBufferRef priorBuffer = (CVPixelBufferRef)currentEnvelope.payload.videoBuffer;

        // processEnvelope:device: — synchronous; returns the processed envelope.
        // If the transform replaces the video buffer, the new buffer is returned
        // inside the envelope; we own that new buffer (+1 from the transform).
        VGFrameEnvelope transformed = [transform processEnvelope:currentEnvelope
                                                          device:metalDevice];

        // If the transform produced a new buffer, release the prior one.
        CVPixelBufferRef newBuffer = (CVPixelBufferRef)transformed.payload.videoBuffer;
        if (newBuffer && newBuffer != priorBuffer) {
            if (priorBuffer) CVPixelBufferRelease(priorBuffer);
        }

        currentEnvelope = transformed;
    }

    // ── Step 10: Cancellation check (post-transform) ──────────────────────────
    if (atomic_load(&_cancelledAtomic)) {
        CVPixelBufferRef ownedBuf = (CVPixelBufferRef)currentEnvelope.payload.videoBuffer;
        if (ownedBuf) CVPixelBufferRelease(ownedBuf);
        [self _invalidateAllNodes];
        [self _fireCompletionWithManifest:nil error:[self _cancelledError]];
        return;
    }

    // ── Step 11: presentEnvelope: on the sink (borrowed +0 call) ─────────────
    //
    // VGFrameSink contract: "The envelope is delivered at +0. If the sink needs
    // to retain the payload pointer beyond this call, it MUST call CVPixelBufferRetain."
    // VGImageEncoderSinkNode does NOT retain the buffer — it copies pixels into
    // the CGImageDestination synchronously before returning.
    [_sink presentEnvelope:currentEnvelope];

    // ── Step 12: Release the owned buffer (post-present) ─────────────────────
    CVPixelBufferRef finalBuffer = (CVPixelBufferRef)currentEnvelope.payload.videoBuffer;
    if (finalBuffer) CVPixelBufferRelease(finalBuffer);
    currentEnvelope.payload.videoBuffer = NULL;

    // ── Step 13: Finalize sink → VGImageExportManifest ───────────────────────
    NSError *finalizeErr = nil;
    VGImageExportManifest *manifest = [_sink finalizeExportWithError:&finalizeErr];

    // ── Step 14: Invalidate all nodes ────────────────────────────────────────
    [self _invalidateAllNodes];

    // ── Step 15: Fire completion ──────────────────────────────────────────────
    if (manifest) {
        os_log_debug(sSessionLog,
                     "[VGImageExportSession] export finished — %{public}@ %dx%d "
                     "%lld bytes",
                     @(manifest.format), (int)manifest.width, (int)manifest.height,
                     (long long)manifest.fileSizeBytes);
        [self _fireCompletionWithManifest:manifest error:nil];
    } else {
        NSError *err = finalizeErr ?:
            [NSError errorWithDomain:kVGImageExportSessionErrorDomain
                               code:VGImageExportSessionErrorFinalize
                           userInfo:@{
                NSLocalizedDescriptionKey: @"Sink finalization returned nil manifest"
            }];
        os_log_error(sSessionLog,
                     "[VGImageExportSession] finalize failed: %{public}@", err);
        [self _fireCompletionWithManifest:nil error:err];
    }
}

// ─── Private: graph descriptor builder ───────────────────────────────────────

/// Builds the VGGraphDescriptor for the inline pull graph.
- (nullable VGGraphDescriptor *)_buildDescriptorError:(NSError **)outError {

    NSMutableArray<VGGraphNodeDescriptor *> *nodeDescs = [NSMutableArray array];
    NSMutableArray<VGGraphConnection *> *connections   = [NSMutableArray array];

    // ── Source node descriptor ────────────────────────────────────────────────
    NSArray<VGMediaPort *> *sourcePorts = @[
        [VGMediaPort outputPort:@"video_out" mediaType:VGMediaTypeVideo],
    ];
    VGGraphNodeDescriptor *sourceDesc =
        [[VGGraphNodeDescriptor alloc] initWithNodeId:kSourceNodeId
                                            nodeClass:NSStringFromClass([VGImageSourceAdapter class])
                                             nodeRole:VGNodeRoleSource
                                           parameters:@{}
                                                ports:sourcePorts];
    [nodeDescs addObject:sourceDesc];

    // ── Transform node descriptors (one per filterChain entry) ───────────────
    NSString *previousNodeId  = kSourceNodeId;
    NSString *previousPortOut = @"video_out";

    for (NSUInteger i = 0; i < _filterAdapters.count; i++) {
        NSString *transformId = [self _transformNodeIdForIndex:i];

        NSArray<VGMediaPort *> *transformPorts = @[
            [VGMediaPort inputPort:@"video_in"  mediaType:VGMediaTypeVideo required:YES],
            [VGMediaPort outputPort:@"video_out" mediaType:VGMediaTypeVideo],
        ];
        VGGraphNodeDescriptor *transformDesc =
            [[VGGraphNodeDescriptor alloc] initWithNodeId:transformId
                                                nodeClass:NSStringFromClass([VGLegacyFilterAdapter class])
                                                 nodeRole:VGNodeRoleFilter
                                               parameters:@{}
                                                    ports:transformPorts];
        [nodeDescs addObject:transformDesc];

        // Edge from previous node's video_out → this transform's video_in.
        // Transform edges are synchronous with no admission policy.
        VGGraphConnection *edge =
            [VGGraphConnection synchronousEdgeFrom:previousNodeId
                                              port:previousPortOut
                                                to:transformId
                                              port:@"video_in"];
        [connections addObject:edge];

        previousNodeId  = transformId;
        previousPortOut = @"video_out";
    }

    // ── Sink node descriptor ──────────────────────────────────────────────────
    NSArray<VGMediaPort *> *sinkPorts = @[
        [VGMediaPort inputPort:@"video_in" mediaType:VGMediaTypeVideo required:YES],
    ];
    VGGraphNodeDescriptor *sinkDesc =
        [[VGGraphNodeDescriptor alloc] initWithNodeId:kSinkNodeId
                                            nodeClass:NSStringFromClass([VGImageEncoderSinkNode class])
                                             nodeRole:VGNodeRoleSink
                                           parameters:@{}
                                                ports:sinkPorts];
    [nodeDescs addObject:sinkDesc];

    // ── Sink edge: previousNode.video_out → sink.video_in ─────────────────────
    // admissionPolicy = VGSinkAdmissionPolicyNeverDrop (valid: pull-mode graph).
    VGGraphConnection *sinkEdge =
        [VGGraphConnection synchronousEdgeFrom:previousNodeId
                                          port:previousPortOut
                                            to:kSinkNodeId
                                          port:@"video_in"
                               admissionPolicy:[VGSinkAdmissionPolicy neverDrop]];
    [connections addObject:sinkEdge];

    // ── Assemble descriptor ───────────────────────────────────────────────────
    VGGraphDescriptor *desc =
        [[VGGraphDescriptor alloc] initWithGraphId:@"imageExportGraph"
                                             nodes:[nodeDescs copy]
                                       connections:[connections copy]
                                       clockPolicy:VGClockPolicyPull
                                      audioSidecar:nil];
    return desc;
}

// ─── Private: transform node ID ───────────────────────────────────────────────

- (NSString *)_transformNodeIdForIndex:(NSUInteger)idx {
    return [NSString stringWithFormat:@"transform_%lu", (unsigned long)idx];
}

// ─── Private: prepare barrier ─────────────────────────────────────────────────

/// Prepares all nodes via dispatch_group.
/// Fires completion exactly once on a background queue after all callbacks return.
- (void)_prepareAllNodesWithCompletion:(void (^)(NSError * _Nullable))completion {
    NSDictionary<NSString *, id<VGNode>> *nodes = _nodes;
    VGGraphExecutionContext *context = _context;

    if (nodes.count == 0) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            completion(nil);
        });
        return;
    }

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t resultQueue =
        dispatch_queue_create("com.vanguard.export.image.prepare", DISPATCH_QUEUE_SERIAL);

    __block NSError *firstError = nil;

    for (NSString *nodeId in nodes) {
        id<VGNode> node = nodes[nodeId];
        if (!node) continue;

        dispatch_group_enter(group);
        [node prepareWithContext:context completion:^(NSError * _Nullable err) {
            dispatch_async(resultQueue, ^{
                if (err && !firstError) {
                    firstError = err;
                }
                dispatch_group_leave(group);
            });
        }];
    }

    dispatch_group_notify(group, resultQueue, ^{
        NSError *captured = firstError;
        completion(captured);
    });
}

// ─── Private: invalidate all nodes ────────────────────────────────────────────

- (void)_invalidateAllNodes {
    for (id<VGNode> node in _nodes.allValues) {
        [node invalidate];
    }
}

// ─── Private: completion gate ─────────────────────────────────────────────────

/// Fire user completion exactly once via CAS gate (0→1).
- (void)_fireCompletionWithManifest:(nullable VGImageExportManifest *)manifest
                              error:(nullable NSError *)error {
    int32_t expected = 0;
    if (!atomic_compare_exchange_strong(&_completionFired, &expected, 1)) {
        return;  // Completion already fired.
    }

    atomic_store(&_finishedAtomic, YES);

    void (^cb)(VGImageExportManifest *, NSError *) = _completion;
    _completion = nil;  // Release the block.

    if (cb) {
        cb(manifest, error);
    }
}

// ─── Private: error helpers ───────────────────────────────────────────────────

- (NSError *)_cancelledError {
    return [NSError errorWithDomain:kVGImageExportSessionErrorDomain
                               code:VGImageExportSessionErrorCancelled
                           userInfo:@{
        NSLocalizedDescriptionKey: @"Image export was cancelled"
    }];
}

// ─── Dealloc ──────────────────────────────────────────────────────────────────

- (void)dealloc {
    // Safety net: invalidate all nodes if still alive at dealloc time.
    if (_nodes) {
        [self _invalidateAllNodes];
    }
}

@end
