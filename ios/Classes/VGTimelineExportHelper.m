// VGTimelineExportHelper.m
// vanguard_media_engine — Phase 7 Stage 7.5E
//
// Dev-only offline timeline export helper implementation.
//
// Implements the full pull-mode export graph for a VGTimelineCompositorNode:
//   VGTimelineCompositorNode → VGVideoEncoderSinkNode
//
// Key architectural invariants:
//   - This file never touches VanguardGraphRuntime or the playback compositor.
//   - VGExportProfile is constructed here in ObjC (MOD-1, MOD-2).
//   - VGTimelineCompositorNode is freshly initialized (independent — MOD-3).
//   - Entire implementation is guarded by #if DEBUG (MOD-4).
//   - VGClockPolicyPull + clock=nil (MOD-5).
//   - Sink invalidate on failure, scheduler invalidate on cleanup (MOD-6).
//   - VGGraphPlanner is called after VGGraphValidator (MOD-7).
//
// NOT imported:
//   VanguardGraphRuntime, VanguardMetalRenderer, VGGraphSchedulerV2,
//   VGFrameDelegate, VGExportGraphFactory, VGVideoExportSession,
//   VGExportFileSourceNode, VGTimelineCompositorSmokeTest.

#import "VGTimelineExportHelper.h"

#if DEBUG

// ─── Stage 7.5A compositor ───────────────────────────────────────────────────
#import "VGTimelineCompositorNode.h"

// ─── Phase 5C encoder sink ───────────────────────────────────────────────────
#import "VGVideoEncoderSinkNode.h"

// ─── Phase 5C-1 export scheduler ─────────────────────────────────────────────
#import "VGExportScheduler.h"

// ─── UMF graph construction types ────────────────────────────────────────────
#import <UMF/VGExportProfile.h>
#import <UMF/VGGraphDescriptor.h>
#import <UMF/VGGraphNodeDescriptor.h>
#import <UMF/VGGraphConnection.h>
#import <UMF/VGGraphValidator.h>
#import <UMF/VGGraphPlanner.h>
#import <UMF/VGExecutionPlan.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGResourceAllocator.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGNode.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGSourceNode.h>
#import <UMF/VGClockPolicy.h>
#import <UMF/VGSinkAdmissionPolicy.h>
#import <UMF/VGValidationError.h>
#import <VideoToolbox/VideoToolbox.h>
#import <os/log.h>

static os_log_t sExportHelperLog;

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - @implementation (DEBUG)
// ─────────────────────────────────────────────────────────────────────────────

@implementation VGTimelineExportHelper

+ (void)initialize {
    if (self == [VGTimelineExportHelper class]) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            sExportHelperLog = os_log_create("com.vanguard.engine",
                                             "VGTimelineExportHelper");
        });
    }
}

// ─── Public export entry point ────────────────────────────────────────────────

+ (void)exportTimelineWithClips:(NSArray<NSDictionary *> *)clips
                     outputPath:(NSString *)outputPath
                          width:(NSInteger)width
                         height:(NSInteger)height
                            fps:(NSInteger)fps
                     bitrateBps:(NSInteger)bitrateBps
                     completion:(void (^)(BOOL success,
                                         NSString * _Nullable outputPath,
                                         NSTimeInterval durationSeconds,
                                         NSError * _Nullable error))completion
{
    NSParameterAssert(completion != nil);

    // ── 1. Input validation ───────────────────────────────────────────────────

    if (clips.count == 0) {
        completion(NO, nil, 0.0,
            [NSError errorWithDomain:@"VGTimelineExportHelper"
                               code:1
                           userInfo:@{
            NSLocalizedDescriptionKey: @"clips must not be empty"
        }]);
        return;
    }
    if (outputPath.length == 0) {
        completion(NO, nil, 0.0,
            [NSError errorWithDomain:@"VGTimelineExportHelper"
                               code:2
                           userInfo:@{
            NSLocalizedDescriptionKey: @"outputPath must not be empty"
        }]);
        return;
    }
    if (width <= 0 || height <= 0 || fps <= 0 || bitrateBps <= 0) {
        completion(NO, nil, 0.0,
            [NSError errorWithDomain:@"VGTimelineExportHelper"
                               code:3
                           userInfo:@{
            NSLocalizedDescriptionKey: @"width, height, fps, and bitrateBps must all be > 0"
        }]);
        return;
    }

    os_log(sExportHelperLog,
           "[7.5E] exportTimeline: clips=%lu width=%ld height=%ld fps=%ld bitrate=%ld",
           (unsigned long)clips.count, (long)width, (long)height,
           (long)fps, (long)bitrateBps);

    // ── 2. Build output URL ───────────────────────────────────────────────────

    NSURL *outputURL = [NSURL fileURLWithPath:outputPath];

    // ── 3. Construct VGExportProfile (MOD-1, MOD-2) ──────────────────────────
    //
    // VGExportProfile is constructed entirely in ObjC. Swift callers pass only
    // primitive parameters. All 12 fields are specified per Opus MOD-2.
    //
    // allowFrameReordering:NO — simpler proof; avoids B-frame ordering complexity.
    // maxKeyFrameInterval:0   — VT default (automatic keyframe cadence).
    // quality:0.0             — bitrate-driven, quality field is unused.
    VGExportProfile *profile =
        [[VGExportProfile alloc]
            initWithCodecType:kCMVideoCodecType_H264
                 profileLevel:(__bridge NSString *)kVTProfileLevel_H264_High_AutoLevel
                        width:(int32_t)width
                       height:(int32_t)height
                   bitrateBps:(int32_t)bitrateBps
                          fps:(int32_t)fps
          maxKeyFrameInterval:0
  maxKeyFrameIntervalDuration:0.0
                      quality:0.0
          allowFrameReordering:NO
                     realtime:NO
                 allowOpenGOP:NO
                        usage:VGEncoderUsageOffline];

    // ── 4. Create a new independent VGTimelineCompositorNode (MOD-3) ──────────
    //
    // This compositor is completely independent from the playback runtime.
    // It does NOT reference _timelineRuntime, the playback texture, or any
    // VanguardGraphRuntime instance. The same clip paths can be used by both
    // playback and export concurrently since AVAssetReader is read-only.
    //
    // Parameters follow the same wire contract as the Swift plugin's
    // _prepareTimelineCompositorWithSize: helper:
    //   - descriptorStage: "7.5_executable" (required by VGTimelineCompositorNode)
    //   - clips: the caller-supplied clip descriptor dictionaries
    //   - transitions: [] (hard-cut only, Stage 7.5 limitation)
    NSDictionary<NSString *, id> *compositorParams = @{
        @"descriptorStage": @"7.5_executable",
        @"clips":           clips,
        @"transitions":     @[],
    };

    VGMediaPort *videoOutPort =
        [VGMediaPort outputPort:@"video_out" mediaType:VGMediaTypeVideo];
    NSArray<VGMediaPort *> *compositorPorts = @[videoOutPort];

    NSError *compositorError = nil;
    VGTimelineCompositorNode *compositor =
        [[VGTimelineCompositorNode alloc] initWithNodeId:@"export_timeline_compositor"
                                              parameters:compositorParams
                                                   ports:compositorPorts
                                                   error:&compositorError];
    if (!compositor) {
        NSString *msg = compositorError.localizedDescription
                        ?: @"VGTimelineCompositorNode returned nil (unknown error)";
        os_log_error(sExportHelperLog, "[7.5E] compositor init failed: %{public}@", msg);
        completion(NO, nil, 0.0,
            [NSError errorWithDomain:@"VGTimelineExportHelper"
                               code:10
                           userInfo:@{
            NSLocalizedDescriptionKey: msg,
            NSUnderlyingErrorKey: compositorError ?: [NSNull null],
        }]);
        return;
    }

    os_log(sExportHelperLog,
           "[7.5E] compositor: nodeId=%{public}@ nodeRole=%ld",
           compositor.nodeId, (long)compositor.nodeRole);

    // ── 5. Create VGVideoEncoderSinkNode ──────────────────────────────────────
    //
    // Note: VGVideoEncoderSinkNode.prepareWithContext: deletes any existing file
    // at outputURL before creating the AVAssetWriter. No redundant deletion here.
    VGVideoEncoderSinkNode *sinkNode =
        [[VGVideoEncoderSinkNode alloc] initWithOutputURL:outputURL
                                                  profile:profile];

    // ── 6. Build the export graph ─────────────────────────────────────────────
    //
    // Two-node graph: compositor (VGNodeRoleCompositor) → sink (VGNodeRoleSink).
    // The VGExportScheduler discovers the compositor via its Phase 7 fallback
    // (VGNodeRoleCompositor + <VGSourceNode> conformance — see VGExportScheduler.m
    // lines 137–152, MOD-1 from Opus Stage 7.5 validation).
    //
    // Clock policy: VGClockPolicyPull (offline, sink-driven). MOD-5.
    // Sink edge: VGSinkAdmissionPolicyNeverDrop — valid on pull-mode graphs.
    //   VGGraphValidator CHECK 5 only rejects neverDrop on push-mode edges.

    id<VGNode> sinkAsNode = (id<VGNode>)sinkNode;

    // Node descriptors.
    VGGraphNodeDescriptor *compositorDesc =
        [[VGGraphNodeDescriptor alloc] initWithNodeId:compositor.nodeId
                                            nodeClass:compositor.nodeClass
                                             nodeRole:compositor.nodeRole
                                           parameters:@{}
                                                ports:[compositor declaredPorts]];

    VGGraphNodeDescriptor *sinkDesc =
        [[VGGraphNodeDescriptor alloc] initWithNodeId:sinkAsNode.nodeId
                                            nodeClass:sinkAsNode.nodeClass
                                             nodeRole:sinkAsNode.nodeRole
                                           parameters:@{}
                                                ports:[sinkAsNode declaredPorts]];

    NSArray<VGGraphNodeDescriptor *> *nodeDescriptors = @[compositorDesc, sinkDesc];

    // Node instance map: nodeId → live node.
    NSMutableDictionary<NSString *, id<VGNode>> *nodeMap =
        [NSMutableDictionary dictionaryWithCapacity:2];
    nodeMap[compositor.nodeId] = compositor;
    nodeMap[sinkAsNode.nodeId] = sinkAsNode;

    // Single direct edge: compositor:video_out → sink:video_in (neverDrop).
    VGGraphConnection *directEdge =
        [VGGraphConnection synchronousEdgeFrom:compositor.nodeId
                                          port:@"video_out"
                                            to:sinkAsNode.nodeId
                                          port:@"video_in"
                               admissionPolicy:[VGSinkAdmissionPolicy neverDrop]];

    // Graph descriptor: VGClockPolicyPull for offline export (MOD-5).
    VGGraphDescriptor *descriptor =
        [[VGGraphDescriptor alloc] initWithGraphId:@"timelineExportGraph"
                                             nodes:nodeDescriptors
                                       connections:@[directEdge]
                                       clockPolicy:VGClockPolicyPull
                                      audioSidecar:nil];

    // ── 7. Validate via VGGraphValidator ──────────────────────────────────────
    //
    // Checks: NoSource (compositor accepted via self-sourcing patch), NoSink,
    // DanglingConnection, CycleDetected, NeverDropOnPushEdge (not applicable here).
    NSArray<VGValidationError *> *validationErrors = nil;
    BOOL valid = [VGGraphValidator validateDescriptor:descriptor
                                              errors:&validationErrors];
    if (!valid) {
        NSString *errMsg = [NSString stringWithFormat:
            @"VGGraphValidator rejected export graph: %@", validationErrors];
        os_log_error(sExportHelperLog, "[7.5E] validation failed: %{public}@", errMsg);
        [sinkNode invalidate];
        [compositor invalidate];
        completion(NO, nil, 0.0,
            [NSError errorWithDomain:@"VGTimelineExportHelper"
                               code:20
                           userInfo:@{NSLocalizedDescriptionKey: errMsg}]);
        return;
    }

    os_log(sExportHelperLog, "[7.5E] VGGraphValidator: PASSED");

    // ── 8. Plan via VGGraphPlanner (MOD-7) ───────────────────────────────────
    //
    // VGExportScheduler.initWithPlan:nodes:context:fps: requires a VGExecutionPlan.
    // For a two-node graph (compositor → sink), the topological order will have no
    // filter/metadata nodes — the scheduler extracts source and sink by role, not
    // from the plan's order. The plan object itself is still required.
    NSError *plannerError = nil;
    VGExecutionPlan *plan = [VGGraphPlanner planFromDescriptor:descriptor
                                                         error:&plannerError];
    if (!plan) {
        NSString *errMsg = [NSString stringWithFormat:
            @"VGGraphPlanner failed: %@", plannerError.localizedDescription];
        os_log_error(sExportHelperLog, "[7.5E] planner failed: %{public}@", errMsg);
        [sinkNode invalidate];
        [compositor invalidate];
        completion(NO, nil, 0.0,
            [NSError errorWithDomain:@"VGTimelineExportHelper"
                               code:21
                           userInfo:@{
            NSLocalizedDescriptionKey: errMsg,
            NSUnderlyingErrorKey: plannerError ?: [NSNull null],
        }]);
        return;
    }

    os_log(sExportHelperLog, "[7.5E] VGGraphPlanner: plan ready, order=%lu",
           (unsigned long)plan.topologicalOrder.count);

    // ── 9. Create VGGraphExecutionContext ─────────────────────────────────────
    //
    // clock=nil: pull-mode offline export — no real-time clock needed. (MOD-5)
    // Follows the VGVideoExportSession pattern (VGVideoExportSession.m L194-L199).
    VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];
    VGGraphExecutionContext *context =
        [[VGGraphExecutionContext alloc] initWithDescriptor:descriptor
                                                       plan:plan
                                                      nodes:nodeMap
                                                      clock:nil
                                          resourceAllocator:allocator];

    if (!context) {
        os_log_error(sExportHelperLog, "[7.5E] VGGraphExecutionContext creation failed");
        [sinkNode invalidate];
        [compositor invalidate];
        completion(NO, nil, 0.0,
            [NSError errorWithDomain:@"VGTimelineExportHelper"
                               code:22
                           userInfo:@{
            NSLocalizedDescriptionKey: @"VGGraphExecutionContext creation failed"
        }]);
        return;
    }

    // ── 10. Prepare all nodes (dispatch_group async barrier) ─────────────────
    //
    // Both compositor and sink prepare asynchronously. The group barrier ensures
    // we do not start the scheduler until both are ready. Follows the
    // VGVideoExportSession._prepareAllNodesWithCompletion: pattern.
    dispatch_group_t prepGroup = dispatch_group_create();
    dispatch_queue_t prepQueue =
        dispatch_queue_create("com.vanguard.export.prepare.timeline", DISPATCH_QUEUE_SERIAL);

    __block NSError *firstPrepareError = nil;

    // Prepare compositor.
    dispatch_group_enter(prepGroup);
    [compositor prepareWithContext:context completion:^(NSError * _Nullable err) {
        dispatch_async(prepQueue, ^{
            if (err && !firstPrepareError) firstPrepareError = err;
            dispatch_group_leave(prepGroup);
        });
    }];

    // Prepare sink.
    dispatch_group_enter(prepGroup);
    [sinkNode prepareWithContext:context completion:^(NSError * _Nullable err) {
        dispatch_async(prepQueue, ^{
            if (err && !firstPrepareError) firstPrepareError = err;
            dispatch_group_leave(prepGroup);
        });
    }];

    // Hold strong references so nodes survive across the async barrier.
    VGTimelineCompositorNode *strongCompositor = compositor;
    VGVideoEncoderSinkNode   *strongSink       = sinkNode;
    VGGraphExecutionContext  *strongContext     = context;
    VGExecutionPlan          *strongPlan        = plan;
    NSDictionary<NSString *, id<VGNode>> *strongNodeMap = [nodeMap copy];

    dispatch_group_notify(prepGroup, prepQueue, ^{
        NSError *prepError = firstPrepareError;

        if (prepError) {
            os_log_error(sExportHelperLog,
                         "[7.5E] node prepare failed: %{public}@",
                         prepError.localizedDescription);
            // MOD-6: Invalidate both nodes on failure.
            [strongSink invalidate];
            [strongCompositor invalidate];
            completion(NO, nil, 0.0, prepError);
            return;
        }

        os_log(sExportHelperLog, "[7.5E] all nodes prepared — starting export scheduler");

        // ── 11. Create and start VGExportScheduler ────────────────────────────
        //
        // Pass fps as int32_t to match initWithPlan:nodes:context:fps: signature.
        VGExportScheduler *scheduler =
            [[VGExportScheduler alloc] initWithPlan:strongPlan
                                              nodes:strongNodeMap
                                            context:strongContext
                                                fps:(int32_t)fps];

        // Wire the sink (weak reference in scheduler; strong in this scope). (MOD-6)
        scheduler.sink = strongSink;

        // ── 12. Wire completionHandler ────────────────────────────────────────
        //
        // Follows VGVideoExportSession.m completion wiring (lines 244-265).
        // success → finalize sink (flush encoder + mux MP4).
        // failure → invalidate sink (cancel AVAssetWriter) then propagate error.
        // MOD-6: sink invalidation on all failure paths.
        scheduler.completionHandler = ^(BOOL success, NSError * _Nullable schedError) {
            if (success) {
                // Pull loop reached EOS — finalize: flush VT encoder + finish AVAssetWriter.
                os_log(sExportHelperLog, "[7.5E] pull loop EOS — finalizing export");
                NSError *finalizeErr = nil;
                VGExportManifest *manifest =
                    [strongSink finalizeExportWithError:&finalizeErr];

                if (manifest && !finalizeErr) {
                    NSTimeInterval duration = manifest.durationSeconds;
                    os_log(sExportHelperLog,
                           "[7.5E] export finalized: %.2fs %lld bytes",
                           duration, (long long)manifest.fileSizeBytes);
                    completion(YES, outputPath, duration, nil);
                } else {
                    // Finalization failed — sink is implicitly invalidated by
                    // cancelWriting inside VGVideoEncoderSinkNode.invalidate.
                    [strongSink invalidate];
                    NSError *err = finalizeErr ?: [NSError
                        errorWithDomain:@"VGTimelineExportHelper"
                                   code:30
                               userInfo:@{
                        NSLocalizedDescriptionKey: @"finalizeExportWithError: returned nil manifest"
                    }];
                    os_log_error(sExportHelperLog,
                                 "[7.5E] finalize failed: %{public}@",
                                 err.localizedDescription);
                    completion(NO, nil, 0.0, err);
                }

            } else {
                // MOD-6: Pull loop cancelled or errored — invalidate sink to
                // cancel AVAssetWriter, then invalidate scheduler for full teardown.
                os_log_error(sExportHelperLog,
                             "[7.5E] pull loop failed/cancelled: %{public}@",
                             schedError.localizedDescription);
                [strongSink invalidate];
                // Scheduler invalidation: the scheduler already set running=NO and
                // transitioned context to stopped at loop exit (VGExportScheduler.m L367-372).
                // An explicit invalidate call here triggers node invalidation for
                // any remaining nodes. Safe to call even after loop exits.
                [scheduler invalidate];
                NSError *err = schedError ?: [NSError
                    errorWithDomain:@"VGTimelineExportHelper"
                               code:31
                           userInfo:@{
                    NSLocalizedDescriptionKey: @"Export scheduler failed or was cancelled"
                }];
                completion(NO, nil, 0.0, err);
            }
        };

        // Start the pull loop asynchronously on the scheduler's internal queue.
        [scheduler startExport];
        os_log(sExportHelperLog, "[7.5E] VGExportScheduler started");
    });
}

@end

#else // !DEBUG

// ─────────────────────────────────────────────────────────────────────────────
// Release-mode stub
// ─────────────────────────────────────────────────────────────────────────────
// The @interface is unconditional (header always visible). In release builds,
// this stub returns a static error. The actual export logic is DEBUG-only.
// Follows the same pattern as VGTimelineCompositorSmokeTest.m.

@implementation VGTimelineExportHelper

+ (void)exportTimelineWithClips:(NSArray<NSDictionary *> *)clips
                     outputPath:(NSString *)outputPath
                          width:(NSInteger)width
                         height:(NSInteger)height
                            fps:(NSInteger)fps
                     bitrateBps:(NSInteger)bitrateBps
                     completion:(void (^)(BOOL success,
                                         NSString * _Nullable outputPath,
                                         NSTimeInterval durationSeconds,
                                         NSError * _Nullable error))completion
{
    NSError *error = [NSError errorWithDomain:@"VGTimelineExportHelper"
                                         code:-1
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"VGTimelineExportHelper is DEBUG-only. "
                                   @"Timeline export is not available in release builds."
    }];
    if (completion) {
        completion(NO, nil, 0.0, error);
    }
}

@end

#endif // DEBUG
