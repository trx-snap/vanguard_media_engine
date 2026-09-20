// VGTimelineExportHelper.m
// vanguard_media_engine — Phase 7 Stage 7.5E / Phase 7.12 / Phase 8.6 / Phase 8.14A
//
// Offline timeline export helper implementation.
//
// Implements the full pull-mode export graph for a VGTimelineCompositorNode:
//   VGTimelineCompositorNode → VGVideoEncoderSinkNode          (no overlays)
//   VGTimelineCompositorNode → VGOverlayNode → VGVideoEncoderSinkNode  (with overlays)
//
// Phase 8.14A: post-pass audio sidecar muxing via VGAudioExportMuxer.
//   When audioSidecar is non-nil:
//     1. Video-only export graph writes to {outputPath}.video_tmp.mp4
//     2. VGAudioExportMuxer muxes temp video + sidecar audio → final outputPath.
//     3. Temp file deleted on success; both temp + partial output deleted on failure.
//
// Key architectural invariants:
//   - This file never touches VanguardGraphRuntime or the playback compositor.
//   - VGExportProfile is constructed here in ObjC (MOD-1, MOD-2).
//   - VGTimelineCompositorNode is freshly initialized (independent — MOD-3).
//   - Phase 7.12: DEBUG-only guard removed (MOD-4 retired). Compiles in all
//     configurations (debug, profile, release). Required for profile-mode device
//     validation and future production export (DEC-145).
//   - VGClockPolicyPull + clock=nil (MOD-5).
//   - Sink invalidate on failure, scheduler invalidate on cleanup (MOD-6).
//   - VGGraphPlanner is called after VGGraphValidator (MOD-7).
//
// Phase 8.6:
//   - VGOverlayNode inserted conditionally (overlays non-empty only).
//   - Original 7-parameter method forwards to new 9-parameter method.
//   - No rendering. No Metal. No CoreImage. Pass-through only.
//
// NOT imported:
//   VanguardGraphRuntime, VanguardMetalRenderer, VGGraphSchedulerV2,
//   VGFrameDelegate, VGExportGraphFactory, VGVideoExportSession,
//   VGExportFileSourceNode, VGTimelineCompositorSmokeTest.

#import "VGTimelineExportHelper.h"


// Phase 8.14A: post-pass audio sidecar muxer.
#import "VGAudioExportMuxer.h"

// ─── Stage 7.5A compositor ───────────────────────────────────────────────────
#import "VGTimelineCompositorNode.h"

// ─── Phase 5C encoder sink ───────────────────────────────────────────────────
#import "VGVideoEncoderSinkNode.h"

// ─── Phase 5C-1 export scheduler ─────────────────────────────────────────────
#import "VGExportScheduler.h"

// ─── Phase 8.5 overlay transform node ────────────────────────────────────────
#import "VGOverlayNode.h"

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
static dispatch_queue_t sTimelineExportLockQueue;
static VGExportScheduler * _Nullable sActiveExportScheduler;
static BOOL sActiveExportCancelled;
static BOOL sPreparationInProgress;
static VGVideoEncoderSinkNode * _Nullable sActiveSinkNode;
static VGTimelineCompositorNode * _Nullable sActiveCompositorNode;


// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - @implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation VGTimelineExportHelper

+ (void)initialize {
    if (self == [VGTimelineExportHelper class]) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            sExportHelperLog = os_log_create("com.vanguard.engine",
                                             "VGTimelineExportHelper");
            sTimelineExportLockQueue = dispatch_queue_create("com.vanguard.export.timeline.lock", DISPATCH_QUEUE_SERIAL);
        });
    }
}

// ─── Backward-compatible 7-parameter forwarder ────────────────────────────────
//
// Phase 8.6: This method forwards to the new 9-parameter implementation with
// canvas:nil and overlays:nil. The dev_timelineExport path and any other caller
// using this signature continues to work without modification, and will use the
// existing 2-node compositor → sink topology (no overlay inserted).

+ (void)exportTimelineWithClips:(NSArray<NSDictionary *> *)clips
                    transitions:(NSArray<NSDictionary *> *)transitions
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
    [self exportTimelineWithClips:clips
                      transitions:transitions
                       outputPath:outputPath
                            width:width
                           height:height
                              fps:fps
                       bitrateBps:bitrateBps
                           canvas:nil
                         overlays:nil
                      audioSidecar:nil
                        progress:nil
                       completion:completion];
}

// ─── Phase 8.6 9-parameter forwarder ───────────────────────────────────────────────
//
// Phase 8.14A: now forwards to the 10-parameter method with audioSidecar:nil.
// No behavioral change for existing callers.

+ (void)exportTimelineWithClips:(NSArray<NSDictionary *> *)clips
                    transitions:(NSArray<NSDictionary *> *)transitions
                     outputPath:(NSString *)outputPath
                          width:(NSInteger)width
                         height:(NSInteger)height
                            fps:(NSInteger)fps
                     bitrateBps:(NSInteger)bitrateBps
                         canvas:(nullable NSDictionary *)canvas
                       overlays:(nullable NSArray<NSDictionary *> *)overlays
                     completion:(void (^)(BOOL success,
                                         NSString * _Nullable outputPath,
                                         NSTimeInterval durationSeconds,
                                         NSError * _Nullable error))completion
{
    [self exportTimelineWithClips:clips
                      transitions:transitions
                       outputPath:outputPath
                            width:width
                           height:height
                              fps:fps
                       bitrateBps:bitrateBps
                           canvas:canvas
                         overlays:overlays
                      audioSidecar:nil
                        progress:nil
                       completion:completion];
}

// ─── Phase 8.14A 10-parameter forwarder (forwards to Phase 10 11-param method) ─────────

+ (void)exportTimelineWithClips:(NSArray<NSDictionary *> *)clips
                    transitions:(NSArray<NSDictionary *> *)transitions
                     outputPath:(NSString *)outputPath
                          width:(NSInteger)width
                         height:(NSInteger)height
                            fps:(NSInteger)fps
                     bitrateBps:(NSInteger)bitrateBps
                         canvas:(nullable NSDictionary *)canvas
                       overlays:(nullable NSArray<NSDictionary *> *)overlays
                    audioSidecar:(nullable VGAudioSidecarPlan *)audioSidecar
                     completion:(void (^)(BOOL success,
                                         NSString * _Nullable outputPath,
                                         NSTimeInterval durationSeconds,
                                         NSError * _Nullable error))completion
{
    [self exportTimelineWithClips:clips
                      transitions:transitions
                       outputPath:outputPath
                            width:width
                           height:height
                              fps:fps
                       bitrateBps:bitrateBps
                           canvas:canvas
                         overlays:overlays
                      audioSidecar:audioSidecar
                        progress:nil
                       completion:completion];
}

// ─── Phase 10 Real Export Progress: 11-parameter forwarder → 12-param designated ──
//
// Forwards to the new 12-parameter designated implementation with
// temporalDenoiseEnabled:NO. Preserves backward compatibility for all existing
// callers that do not supply the temporal denoise flag.

+ (void)exportTimelineWithClips:(NSArray<NSDictionary *> *)clips
                    transitions:(NSArray<NSDictionary *> *)transitions
                     outputPath:(NSString *)outputPath
                          width:(NSInteger)width
                         height:(NSInteger)height
                            fps:(NSInteger)fps
                     bitrateBps:(NSInteger)bitrateBps
                         canvas:(nullable NSDictionary *)canvas
                       overlays:(nullable NSArray<NSDictionary *> *)overlays
                    audioSidecar:(nullable VGAudioSidecarPlan *)audioSidecar
                       progress:(nullable void (^)(double progress))progressBlock
                     completion:(void (^)(BOOL success,
                                         NSString * _Nullable outputPath,
                                         NSTimeInterval durationSeconds,
                                         NSError * _Nullable error))completion
{
    [self exportTimelineWithClips:clips
                      transitions:transitions
                       outputPath:outputPath
                            width:width
                           height:height
                              fps:fps
                       bitrateBps:bitrateBps
                           canvas:canvas
                         overlays:overlays
                      audioSidecar:audioSidecar
            temporalDenoiseEnabled:NO
                         progress:progressBlock
                       completion:completion];
}

// ─── Phase 10 Temporal Denoise: 12-parameter designated implementation ─────────
//
// All other overloads converge here. The temporalDenoiseEnabled parameter
// is threaded into compositorParams so VGTimelineCompositorNode reads it at
// init and activates or suppresses the Metal temporal denoise pass accordingly.

+ (void)exportTimelineWithClips:(NSArray<NSDictionary *> *)clips
                    transitions:(NSArray<NSDictionary *> *)transitions
                     outputPath:(NSString *)outputPath
                          width:(NSInteger)width
                         height:(NSInteger)height
                            fps:(NSInteger)fps
                     bitrateBps:(NSInteger)bitrateBps
                         canvas:(nullable NSDictionary *)canvas
                       overlays:(nullable NSArray<NSDictionary *> *)overlays
                    audioSidecar:(nullable VGAudioSidecarPlan *)audioSidecar
           temporalDenoiseEnabled:(BOOL)temporalDenoiseEnabled
                       progress:(nullable void (^)(double progress))progressBlock
                     completion:(void (^)(BOOL success,
                                         NSString * _Nullable outputPath,
                                         NSTimeInterval durationSeconds,
                                         NSError * _Nullable error))completion
{
    NSParameterAssert(completion != nil);

    // ── 0. Phase 8.14A: determine temp vs final output path ───────────────────
    //
    // When audioSidecar is non-nil:
    //   - The video-only export graph writes to videoWritePath = {outputPath}.video_tmp.mp4
    //   - After the video graph completes, VGAudioExportMuxer muxes
    //     videoWritePath + sidecar audio → finalOutputPath.
    //
    // When audioSidecar is nil:
    //   - videoWritePath == outputPath (existing behavior, unchanged).
    BOOL hasSidecar = (audioSidecar != nil && audioSidecar.tracks.count > 0);
    NSString *videoWritePath = hasSidecar
        ? [outputPath stringByAppendingString:@".video_tmp.mp4"]
        : outputPath;

    if (hasSidecar) {
        os_log(sExportHelperLog,
               "[8.14A] audio sidecar present — video will write to temp: %{public}@",
               videoWritePath.lastPathComponent);
    }

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
    }    if (width <= 0 || height <= 0 || fps <= 0 || bitrateBps <= 0) {
        completion(NO, nil, 0.0,
            [NSError errorWithDomain:@"VGTimelineExportHelper"
                               code:3
                           userInfo:@{
            NSLocalizedDescriptionKey: @"width, height, fps, and bitrateBps must all be > 0"
        }]);
        return;
    }

    // ── Phase 8.6: Determine overlay insertion ────────────────────────────────
    //
    // VGOverlayNode is inserted only when overlays is non-nil and non-empty.
    // When no overlays are supplied, the existing 2-node topology is used
    // exactly — no behavioral change for the no-overlay case.
    BOOL shouldInsertOverlayNode = (overlays != nil && overlays.count > 0);

    os_log(sExportHelperLog,
           "[8.14A] exportTimeline: clips=%lu width=%ld height=%ld fps=%ld bitrate=%ld overlays=%lu sidecar=%@",
           (unsigned long)clips.count, (long)width, (long)height,
           (long)fps, (long)bitrateBps, (unsigned long)(overlays ? overlays.count : 0),
           hasSidecar ? @"YES" : @"NO");

    // ── 2. Build output URL (pointing to videoWritePath) ──────────────────────

    NSURL *outputURL = [NSURL fileURLWithPath:videoWritePath];

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
    //   - transitions: the caller-supplied transition descriptors (Phase 7.10).
    //     Dissolve and fade transitions are executed inside the compositor
    //     during the overlap window via the dual-reader blend path.
    // Phase 10 Temporal Denoise: opt-in flag — threaded from Dart request
    // via VGEditorExportRequest.temporalDenoiseEnabled → MethodChannel args
    // → VanguardMediaEnginePlugin.swift → this 12-parameter method.
    // Default: NO (disabled). The compositor reads this key at init and skips
    // the entire denoise block when NO, incurring zero GPU or CPU overhead.
    NSDictionary<NSString *, id> *compositorParams = @{
        @"descriptorStage":         @"7.5_executable",
        @"clips":                   clips,
        @"transitions":             transitions ?: @[],
        // Phase 7.9: pass canvas dimensions for aspect-fit normalization.
        // Ensures export output matches preview orientation and scaling.
        @"canvasWidth":             @(width),
        @"canvasHeight":            @(height),
        // Phase 10 Temporal Denoise: bind the caller-supplied flag.
        @"temporalDenoiseEnabled":  @(temporalDenoiseEnabled),
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
        os_log_error(sExportHelperLog, "[8.6] compositor init failed: %{public}@", msg);
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
           "[8.6] compositor: nodeId=%{public}@ nodeRole=%ld",
           compositor.nodeId, (long)compositor.nodeRole);

    // ── 5. Create VGVideoEncoderSinkNode ──────────────────────────────────────
    //
    // Note: VGVideoEncoderSinkNode.prepareWithContext: deletes any existing file
    // at outputURL before creating the AVAssetWriter. No redundant deletion here.
    VGVideoEncoderSinkNode *sinkNode =
        [[VGVideoEncoderSinkNode alloc] initWithOutputURL:outputURL
                                                  profile:profile];

    // ── 6. Phase 8.6: Conditionally create VGOverlayNode ─────────────────────
    //
    // VGOverlayNode is VGNodeRoleFilter and conforms to <VGTransformNode>.
    // VGExportScheduler will include it in _executionOrder (role == VGNodeRoleFilter)
    // and call processEnvelope:device: on it in the pull loop.
    //
    // In Phase 8.6, processEnvelope:device: is pass-through — returns the input
    // envelope unchanged. The same videoBuffer pointer is returned, so the scheduler's
    // buffer ownership check (newBuffer != frame) evaluates to NO. No retain/release
    // imbalance. No memory leak. No rendering.
    //
    // Parameters:
    //   "canvas"   — optional canvas descriptor dictionary (may be nil → default canvas).
    //   "overlays" — the overlay descriptor dictionaries.
    // VGOverlayNode parses both defensively; all parsing failures produce safe defaults.
    VGOverlayNode *overlayNode = nil;
    if (shouldInsertOverlayNode) {
        NSMutableDictionary<NSString *, id> *overlayParams =
            [NSMutableDictionary dictionaryWithCapacity:2];
        overlayParams[@"overlays"] = overlays;
        if (canvas != nil) {
            overlayParams[@"canvas"] = canvas;
        }
        overlayNode = [[VGOverlayNode alloc] initWithNodeId:@"export_overlay"
                                                 parameters:[overlayParams copy]
                                                      ports:nil
                                                      error:nil];
        os_log(sExportHelperLog,
               "[8.6] overlayNode created: nodeId=%{public}@ overlays=%lu",
               overlayNode.nodeId, (unsigned long)overlays.count);
    }

    // ── 7. Build the export graph ─────────────────────────────────────────────
    //
    // No overlays:  compositor (VGNodeRoleCompositor) → sink (VGNodeRoleSink).
    // With overlays: compositor → overlay (VGNodeRoleFilter) → sink.
    //
    // The VGExportScheduler discovers the compositor via its Phase 7 fallback
    // (VGNodeRoleCompositor + <VGSourceNode> conformance — see VGExportScheduler.m
    // lines 137–152, MOD-1 from Opus Stage 7.5 validation).
    //
    // Clock policy: VGClockPolicyPull (offline, sink-driven). MOD-5.
    // Sink edge: VGSinkAdmissionPolicyNeverDrop — valid on pull-mode graphs.
    //   VGGraphValidator CHECK 5 only rejects neverDrop on push-mode edges.

    id<VGNode> sinkAsNode = (id<VGNode>)sinkNode;

    // Node descriptors — conditional on whether overlay node is present.
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

    NSArray<VGGraphNodeDescriptor *> *nodeDescriptors;
    NSArray<VGGraphConnection *> *connections;

    // Node instance map: nodeId → live node.
    NSMutableDictionary<NSString *, id<VGNode>> *nodeMap =
        [NSMutableDictionary dictionaryWithCapacity:(shouldInsertOverlayNode ? 3 : 2)];
    nodeMap[compositor.nodeId] = compositor;
    nodeMap[sinkAsNode.nodeId] = sinkAsNode;

    if (shouldInsertOverlayNode) {
        // ── 3-node topology: compositor → overlay → sink ──────────────────────

        id<VGNode> overlayAsNode = (id<VGNode>)overlayNode;
        nodeMap[overlayAsNode.nodeId] = overlayAsNode;

        VGGraphNodeDescriptor *overlayDesc =
            [[VGGraphNodeDescriptor alloc] initWithNodeId:overlayAsNode.nodeId
                                               nodeClass:overlayAsNode.nodeClass
                                                nodeRole:overlayAsNode.nodeRole
                                              parameters:@{}
                                                   ports:[overlayAsNode declaredPorts]];

        nodeDescriptors = @[compositorDesc, overlayDesc, sinkDesc];

        // Edge 1: compositor:video_out → overlay:video_in
        VGGraphConnection *compToOverlay =
            [VGGraphConnection synchronousEdgeFrom:compositor.nodeId
                                              port:@"video_out"
                                                to:overlayAsNode.nodeId
                                              port:@"video_in"
                                   admissionPolicy:[VGSinkAdmissionPolicy neverDrop]];

        // Edge 2: overlay:video_out → sink:video_in (neverDrop — pull-mode graph)
        VGGraphConnection *overlayToSink =
            [VGGraphConnection synchronousEdgeFrom:overlayAsNode.nodeId
                                              port:@"video_out"
                                                to:sinkAsNode.nodeId
                                              port:@"video_in"
                                   admissionPolicy:[VGSinkAdmissionPolicy neverDrop]];

        connections = @[compToOverlay, overlayToSink];

    } else {
        // ── 2-node topology: compositor → sink (original, no overlays) ─────────

        nodeDescriptors = @[compositorDesc, sinkDesc];

        VGGraphConnection *directEdge =
            [VGGraphConnection synchronousEdgeFrom:compositor.nodeId
                                              port:@"video_out"
                                                to:sinkAsNode.nodeId
                                              port:@"video_in"
                                   admissionPolicy:[VGSinkAdmissionPolicy neverDrop]];

        connections = @[directEdge];
    }

    // Graph descriptor: VGClockPolicyPull for offline export (MOD-5).
    VGGraphDescriptor *descriptor =
        [[VGGraphDescriptor alloc] initWithGraphId:@"timelineExportGraph"
                                             nodes:nodeDescriptors
                                       connections:connections
                                       clockPolicy:VGClockPolicyPull
                                      audioSidecar:nil];

    // ── 8. Validate via VGGraphValidator ──────────────────────────────────────
    //
    // Checks: NoSource (compositor accepted via self-sourcing patch), NoSink,
    // DanglingConnection, CycleDetected, NeverDropOnPushEdge (not applicable here).
    NSArray<VGValidationError *> *validationErrors = nil;
    BOOL valid = [VGGraphValidator validateDescriptor:descriptor
                                              errors:&validationErrors];
    if (!valid) {
        NSString *errMsg = [NSString stringWithFormat:
            @"VGGraphValidator rejected export graph: %@", validationErrors];
        os_log_error(sExportHelperLog, "[8.6] validation failed: %{public}@", errMsg);
        [sinkNode invalidate];
        [compositor invalidate];
        // overlayNode has no invalidate method in Phase 8.5/8.6 (pass-through only).
        completion(NO, nil, 0.0,
            [NSError errorWithDomain:@"VGTimelineExportHelper"
                               code:20
                           userInfo:@{NSLocalizedDescriptionKey: errMsg}]);
        return;
    }

    os_log(sExportHelperLog, "[8.6] VGGraphValidator: PASSED");

    // ── 9. Plan via VGGraphPlanner (MOD-7) ───────────────────────────────────
    //
    // For a 3-node graph (compositor → overlay → sink), the topological order
    // will be [compositor, overlay, sink]. The scheduler extracts source via
    // role-based scan; the overlay's VGNodeRoleFilter role places it in
    // _executionOrder. The plan object is required by the scheduler initializer.
    NSError *plannerError = nil;
    VGExecutionPlan *plan = [VGGraphPlanner planFromDescriptor:descriptor
                                                         error:&plannerError];
    if (!plan) {
        NSString *errMsg = [NSString stringWithFormat:
            @"VGGraphPlanner failed: %@", plannerError.localizedDescription];
        os_log_error(sExportHelperLog, "[8.6] planner failed: %{public}@", errMsg);
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

    os_log(sExportHelperLog, "[8.6] VGGraphPlanner: plan ready, order=%lu",
           (unsigned long)plan.topologicalOrder.count);

    // ── 10. Create VGGraphExecutionContext ────────────────────────────────────
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
        os_log_error(sExportHelperLog, "[8.6] VGGraphExecutionContext creation failed");
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

    // ── 11. Prepare all nodes (dispatch_group async barrier) ──────────────────
    //
    // Both compositor and sink prepare asynchronously. The overlay node is a
    // synchronous pass-through stub in Phase 8.6 — it has no async resources to
    // acquire. Its prepareWithContext:completion: is still called to satisfy the
    // VGNode protocol contract.
    //
    // The group barrier ensures we do not start the scheduler until all nodes
    // are ready. Follows the VGVideoExportSession._prepareAllNodesWithCompletion:
    // pattern.
    dispatch_sync(sTimelineExportLockQueue, ^{
        sActiveExportCancelled = NO;
        sPreparationInProgress = YES;
        sActiveSinkNode = sinkNode;
        sActiveCompositorNode = compositor;
    });

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

    // Prepare overlay node if present.
    // Phase 8.6: VGOverlayNode.prepareWithContext:completion: is a no-op stub
    // (the node has no async resources to acquire). Called here for protocol
    // correctness and forward-compatibility when rendering is added in Phase 8.7+.
    if (overlayNode) {
        dispatch_group_enter(prepGroup);
        [overlayNode prepareWithContext:context completion:^(NSError * _Nullable err) {
            dispatch_async(prepQueue, ^{
                if (err && !firstPrepareError) firstPrepareError = err;
                dispatch_group_leave(prepGroup);
            });
        }];
    }

    // Hold strong references so nodes survive across the async barrier.
    VGTimelineCompositorNode *strongCompositor = compositor;
    VGVideoEncoderSinkNode   *strongSink       = sinkNode;
    VGOverlayNode            *strongOverlay    = overlayNode; // nil when not inserting
    VGGraphExecutionContext  *strongContext     = context;
    VGExecutionPlan          *strongPlan        = plan;
    NSDictionary<NSString *, id<VGNode>> *strongNodeMap = [nodeMap copy];

    // Phase 8.14A: capture sidecar state for the scheduler completion block.
    BOOL        capturedHasSidecar    = hasSidecar;
    NSString   *capturedVideoWrite    = videoWritePath;
    VGAudioSidecarPlan *capturedSidecar = audioSidecar;

    // Phase 10 Real Export Progress: compute totalExpectedFrames from clip descriptors.
    // totalDuration = max(startTime + duration) across all clips.
    // totalExpectedFrames = ceil(totalDuration * fps).
    // When progressBlock is nil, totalExpectedFrames remains 0 and no progress fires.
    int64_t totalExpectedFrames = 0;
    void (^capturedProgressBlock)(double) = progressBlock;
    if (capturedProgressBlock) {
        NSTimeInterval totalDuration = 0.0;
        for (NSDictionary *clip in clips) {
            NSTimeInterval start    = [clip[@"startTimeSeconds"] doubleValue];
            NSTimeInterval duration = [clip[@"durationSeconds"] doubleValue];
            NSTimeInterval clipEnd  = start + duration;
            if (clipEnd > totalDuration) { totalDuration = clipEnd; }
        }
        if (totalDuration > 0.0 && fps > 0) {
            totalExpectedFrames = (int64_t)ceil(totalDuration * (double)fps);
        }
        os_log(sExportHelperLog,
               "[Phase10] progress enabled: totalDuration=%.2fs fps=%ld totalExpectedFrames=%lld",
               totalDuration, (long)fps, (long long)totalExpectedFrames);
    }

    dispatch_group_notify(prepGroup, prepQueue, ^{
        __block BOOL cancelledEarly = NO;
        dispatch_sync(sTimelineExportLockQueue, ^{
            sPreparationInProgress = NO;
            sActiveSinkNode = nil;
            sActiveCompositorNode = nil;
            cancelledEarly = sActiveExportCancelled;
        });

        if (cancelledEarly) {
            os_log(sExportHelperLog, "[cancelActiveExport] cancelled before scheduler started");
            [strongSink invalidate];
            [strongCompositor invalidate];
            if (capturedHasSidecar) {
                [[NSFileManager defaultManager] removeItemAtPath:capturedVideoWrite error:nil];
            }
            completion(NO, nil, 0.0, [NSError errorWithDomain:@"VGTimelineExportHelper"
                                                         code:999
                                                     userInfo:@{
                NSLocalizedDescriptionKey: @"EXPORT_CANCELLED"
            }]);
            return;
        }

        NSError *prepError = firstPrepareError;

        if (prepError) {
            os_log_error(sExportHelperLog,
                         "[8.6] node prepare failed: %{public}@",
                         prepError.localizedDescription);
            // MOD-6: Invalidate all nodes on failure.
            [strongSink invalidate];
            [strongCompositor invalidate];
            // overlayNode has no invalidate in Phase 8.6; it holds no resources.
            (void)strongOverlay;
            completion(NO, nil, 0.0, prepError);
            return;
        }

        os_log(sExportHelperLog, "[8.6] all nodes prepared — starting export scheduler");

        // ── 12. Create and start VGExportScheduler ────────────────────────────
        //
        // Pass fps as int32_t to match initWithPlan:nodes:context:fps: signature.
        // The scheduler's _executionOrder scan will include the overlay node when
        // present (VGNodeRoleFilter) and invoke processEnvelope:device: on it.
        VGExportScheduler *scheduler =
            [[VGExportScheduler alloc] initWithPlan:strongPlan
                                              nodes:strongNodeMap
                                            context:strongContext
                                                fps:(int32_t)fps];

        // Wire the sink (weak reference in scheduler; strong in this scope). (MOD-6)
        scheduler.sink = strongSink;

        // ── Phase 10 Real Export Progress: wire scheduler progress handler ────
        //
        // Throttling at ~100ms intervals is applied here, not in the scheduler.
        // When audioSidecar is non-nil, render progress is scaled to [0.0, 0.95]
        // so that 1.0 is emitted only after VGAudioExportMuxer completes.
        // When audioSidecar is nil, render progress runs [0.0, 1.0] directly.
        if (totalExpectedFrames > 0 && capturedProgressBlock) {
            scheduler.totalExpectedFrames = totalExpectedFrames;
            __block CFAbsoluteTime lastProgressTime = 0.0;
            BOOL scaleForSidecar = capturedHasSidecar;
            scheduler.progressHandler = ^(double rawProgress) {
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                // Throttle: skip if < 100ms since last fire and not the final frame.
                if (now - lastProgressTime < 0.1 && rawProgress < 1.0) return;
                lastProgressTime = now;
                double scaledProgress = scaleForSidecar
                    ? (rawProgress * 0.95)  // reserve 0.95-1.0 for mux pass
                    : rawProgress;
                capturedProgressBlock(scaledProgress);
            };
        }

        // ── 13. Wire completionHandler ─────────────────────────────────────────
        //
        // Follows VGVideoExportSession.m completion wiring (lines 244-265).
        // success → finalize sink (flush encoder + mux MP4).
        // failure → invalidate sink (cancel AVAssetWriter) then propagate error.
        // MOD-6: sink invalidation on all failure paths.
        scheduler.completionHandler = ^(BOOL success, NSError * _Nullable schedError) {
            dispatch_sync(sTimelineExportLockQueue, ^{
                sActiveExportScheduler = nil;
            });

            if (success) {
                // Pull loop reached EOS — finalize: flush VT encoder + finish AVAssetWriter.
                os_log(sExportHelperLog, "[8.6] pull loop EOS — finalizing export");
                NSError *finalizeErr = nil;
                VGExportManifest *manifest =
                    [strongSink finalizeExportWithError:&finalizeErr];

                if (manifest && !finalizeErr) {
                    NSTimeInterval videoDuration = manifest.durationSeconds;
                    os_log(sExportHelperLog,
                           "[8.14A] video finalized: %.2fs %lld bytes",
                           videoDuration, (long long)manifest.fileSizeBytes);

                    if (capturedHasSidecar) {
                        // ── Phase 8.14A: post-pass audio mux ───────────────────
                        //
                        // The video-only MP4 is now at capturedVideoWrite.
                        // Invoke VGAudioExportMuxer to combine it with the
                        // sidecar audio track and write the final outputPath.
                        os_log(sExportHelperLog,
                               "[8.14A] starting post-pass audio mux");

                        VGAudioExportMuxer *muxer =
                            [[VGAudioExportMuxer alloc]
                                initWithVideoTempPath:capturedVideoWrite
                                        audioSidecar:capturedSidecar
                                     finalOutputPath:outputPath];

                        [muxer startMuxWithCompletion:^(BOOL muxOK,
                                                       NSTimeInterval muxDuration,
                                                       NSError * _Nullable muxErr) {


                            if (muxOK) {
                                os_log(sExportHelperLog,
                                       "[8.14A] post-pass mux complete: %.2fs",
                                       muxDuration);

                                // Phase 10: emit 1.0 after mux completes
                                // (render phase was scaled to 0.95 max).
                                if (capturedProgressBlock) { capturedProgressBlock(1.0); }

                                completion(YES, outputPath, muxDuration, nil);
                            } else {
                                os_log_error(sExportHelperLog,
                                             "[8.14A] post-pass mux failed: %{public}@",
                                             muxErr.localizedDescription);

                                completion(NO, nil, 0.0, muxErr);
                            }
                        }];

                    } else {
                        // No sidecar — deliver the video-only result directly.

                        completion(YES, outputPath, videoDuration, nil);
                    }

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
                                 "[8.6] finalize failed: %{public}@",
                                 err.localizedDescription);

                    completion(NO, nil, 0.0, err);
                }

            } else {
                // MOD-6: Pull loop cancelled or errored — invalidate sink to
                // cancel AVAssetWriter, then invalidate scheduler for full teardown.
                os_log_error(sExportHelperLog,
                             "[8.6] pull loop failed/cancelled: %{public}@",
                             schedError.localizedDescription);
                [strongSink invalidate];
                // Scheduler invalidation: the scheduler already set running=NO and
                // transitioned context to stopped at loop exit (VGExportScheduler.m L367-372).
                // An explicit invalidate call here triggers node invalidation for
                // any remaining nodes. Safe to call even after loop exits.
                [scheduler invalidate];
                if (capturedHasSidecar) {
                    [[NSFileManager defaultManager] removeItemAtPath:capturedVideoWrite error:nil];
                }

                __block BOOL wasCancelled = NO;
                dispatch_sync(sTimelineExportLockQueue, ^{
                    wasCancelled = sActiveExportCancelled;
                });
                if (!wasCancelled && schedError != nil) {
                    if ([schedError.domain isEqualToString:@"VGExportScheduler"] && schedError.code == 1) {
                        wasCancelled = YES;
                    }
                }

                NSError *err = wasCancelled
                    ? [NSError errorWithDomain:@"VGTimelineExportHelper"
                                          code:999
                                      userInfo:@{
                        NSLocalizedDescriptionKey: @"EXPORT_CANCELLED"
                    }]
                    : (schedError ?: [NSError errorWithDomain:@"VGTimelineExportHelper"
                                                         code:31
                                                     userInfo:@{
                        NSLocalizedDescriptionKey: @"Export scheduler failed or was cancelled"
                    }]);

                completion(NO, nil, 0.0, err);
            }
        };

        dispatch_sync(sTimelineExportLockQueue, ^{
            if (sActiveExportCancelled) {
                cancelledEarly = YES;
            } else {
                sActiveExportScheduler = scheduler;
            }
        });

        if (cancelledEarly) {
            os_log(sExportHelperLog, "[cancelActiveExport] cancelled immediately after scheduler creation");
            [strongSink invalidate];
            [scheduler invalidate];
            if (capturedHasSidecar) {
                [[NSFileManager defaultManager] removeItemAtPath:capturedVideoWrite error:nil];
            }
            completion(NO, nil, 0.0, [NSError errorWithDomain:@"VGTimelineExportHelper"
                                                         code:999
                                                     userInfo:@{
                NSLocalizedDescriptionKey: @"EXPORT_CANCELLED"
            }]);
            return;
        }

        // Start the pull loop asynchronously on the scheduler's internal queue.
        [scheduler startExport];
        os_log(sExportHelperLog, "[8.14A] VGExportScheduler started");
    });
}

+ (BOOL)cancelActiveExport {
    __block BOOL cancelled = NO;
    dispatch_sync(sTimelineExportLockQueue, ^{
        if (sActiveExportScheduler != nil) {
            sActiveExportCancelled = YES;
            [sActiveExportScheduler cancelExport];
            cancelled = YES;
            os_log(sExportHelperLog, "[cancelActiveExport] cancelled active scheduler");
        } else if (sPreparationInProgress) {
            sActiveExportCancelled = YES;
            [sActiveSinkNode invalidate];
            [sActiveCompositorNode invalidate];
            cancelled = YES;
            os_log(sExportHelperLog, "[cancelActiveExport] cancelled during preparation");
        }
    });
    return cancelled;
}

@end
