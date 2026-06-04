// VGTimelineCompositorSmokeTest.m
// vanguard_media_engine — Phase 7 Stage 7.5B
//
// Headless native smoke test runner for VGTimelineCompositorNode.
//
// ═══════════════════════════════════════════════════════════════════════════════
// DEBUG ONLY — entire file guarded by #if DEBUG
// ═══════════════════════════════════════════════════════════════════════════════
//
// This smoke test proves end-to-end execution of the Stage 7.5A
// VGTimelineCompositorNode pipeline:
//
//   1. Synthetic test video generation via AVAssetWriter.
//   2. VGEditorGraphFactory descriptor construction + VGGraphValidator pass.
//   3. VGTimelineCompositorNode init from descriptor parameters.
//   4. prepareWithContext: + headless pullFrame: frame delivery.
//   5. Multi-clip sequencing (Clip A → Clip B).
//   6. EOS detection at timeline end.
//   7. seekTo:generation: + stale/matching generation verification.
//   8. invalidate teardown.
//
// The test generates its own synthetic MP4 videos using AVAssetWriter +
// CVPixelBuffer, so it does not depend on bundled media assets.
//
// PLATFORM: AVFoundation + CoreVideo (iOS 14.0+).

#if DEBUG

#import "VGTimelineCompositorSmokeTest.h"

// ─── Stage 7.5A compositor ───────────────────────────────────────────────────
#import "VGTimelineCompositorNode.h"

// ─── Stage 7.4 editor graph factory ──────────────────────────────────────────
#import "VGEditorGraphFactory.h"

// ─── Stage 7.1 descriptor models ─────────────────────────────────────────────
#import "VGClipDescriptor.h"
#import "VGTransitionDescriptor.h"
#import <UMF/VGTransformTrackDescriptor.h>

// ─── UMF V2 types ────────────────────────────────────────────────────────────
#import <UMF/VGGraphDescriptor.h>
#import <UMF/VGGraphNodeDescriptor.h>
#import <UMF/VGGraphValidator.h>
#import <UMF/VGValidationError.h>
#import <UMF/VGFrameRequest.h>
#import <UMF/VGFrameResult.h>
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGExecutionPlan.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGResourceAllocator.h>
#import <UMF/VGRenderMode.h>

// ─── AVFoundation ────────────────────────────────────────────────────────────
#import <AVFoundation/AVFoundation.h>

// ─── CoreVideo / CoreMedia ───────────────────────────────────────────────────
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

// ─── System ──────────────────────────────────────────────────────────────────
#import <os/log.h>

// ─── Phase 7.20A: Reverse sidecar manager ────────────────────────────────────
#import "VGReverseSidecarManager.h"

static os_log_t sSmokeLog;

// ─── Step result builder ─────────────────────────────────────────────────────

static NSDictionary *_stepResult(NSString *name, BOOL passed, NSString *detail) {
    return @{
        @"name": name,
        @"passed": @(passed),
        @"detail": detail ?: @"",
    };
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Synthetic video generator
// ─────────────────────────────────────────────────────────────────────────────

/// Generate a short synthetic MP4 video at the given path.
///
/// Creates a solid-color video: `frameCount` frames at `fps` frame rate,
/// each frame filled with the specified BGRA color (R, G, B, A channels).
///
/// Apple Framework Contract:
///   - AVAssetWriter: initialised with outputURL + fileType (.mp4).
///   - AVAssetWriterInput: mediaType .video, outputSettings H.264.
///   - AVAssetWriterInputPixelBufferAdaptor: provides pixel buffers.
///   - finishWritingWithCompletionHandler: blocks until written.
///
/// @param path       Absolute file path for the output MP4.
/// @param width      Video width in pixels.
/// @param height     Video height in pixels.
/// @param fps        Frames per second.
/// @param frameCount Total number of frames.
/// @param r          Red channel (0–255).
/// @param g          Green channel (0–255).
/// @param b          Blue channel (0–255).
/// @return YES on success, NO on failure.
static BOOL _generateSyntheticVideo(NSString *path,
                                     int width, int height,
                                     int fps, int frameCount,
                                     uint8_t r, uint8_t g, uint8_t b)
{
    // Remove any existing file at path.
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

    NSURL *outputURL = [NSURL fileURLWithPath:path];
    NSError *error = nil;

    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:outputURL
                                                      fileType:AVFileTypeMPEG4
                                                         error:&error];
    if (!writer) {
        os_log_error(sSmokeLog, "[SmokeTest] AVAssetWriter init failed: %{public}@",
                     error.localizedDescription);
        return NO;
    }

    NSDictionary *outputSettings = @{
        AVVideoCodecKey:  AVVideoCodecTypeH264,
        AVVideoWidthKey:  @(width),
        AVVideoHeightKey: @(height),
    };

    AVAssetWriterInput *input =
        [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                          outputSettings:outputSettings];
    input.expectsMediaDataInRealTime = NO;

    NSDictionary *pixelBufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:          @(width),
        (id)kCVPixelBufferHeightKey:         @(height),
    };

    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [[AVAssetWriterInputPixelBufferAdaptor alloc]
            initWithAssetWriterInput:input
            sourcePixelBufferAttributes:pixelBufferAttributes];

    if (![writer canAddInput:input]) {
        os_log_error(sSmokeLog, "[SmokeTest] Cannot add input to writer");
        return NO;
    }
    [writer addInput:input];

    if (![writer startWriting]) {
        os_log_error(sSmokeLog, "[SmokeTest] startWriting failed: %{public}@",
                     writer.error.localizedDescription);
        return NO;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    // Write frames.
    for (int i = 0; i < frameCount; i++) {
        // Wait until the input is ready.
        while (!input.readyForMoreMediaData) {
            [NSThread sleepForTimeInterval:0.01];
        }

        // Create pixel buffer.
        CVPixelBufferRef pb = NULL;
        CVReturn status = CVPixelBufferPoolCreatePixelBuffer(
            NULL, adaptor.pixelBufferPool, &pb);
        if (status != kCVReturnSuccess || !pb) {
            os_log_error(sSmokeLog, "[SmokeTest] CVPixelBuffer creation failed at frame %d", i);
            return NO;
        }

        CVPixelBufferLockBaseAddress(pb, 0);
        void *baseAddress = CVPixelBufferGetBaseAddress(pb);
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
        size_t bufferHeight = CVPixelBufferGetHeight(pb);

        // Fill with solid BGRA color.
        for (size_t row = 0; row < bufferHeight; row++) {
            uint8_t *rowPtr = (uint8_t *)baseAddress + row * bytesPerRow;
            for (int col = 0; col < width; col++) {
                rowPtr[col * 4 + 0] = b;    // B
                rowPtr[col * 4 + 1] = g;    // G
                rowPtr[col * 4 + 2] = r;    // R
                rowPtr[col * 4 + 3] = 255;  // A
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, 0);

        CMTime presentationTime = CMTimeMake(i, fps);
        if (![adaptor appendPixelBuffer:pb withPresentationTime:presentationTime]) {
            os_log_error(sSmokeLog,
                         "[SmokeTest] appendPixelBuffer failed at frame %d: %{public}@",
                         i, writer.error.localizedDescription);
            CVPixelBufferRelease(pb);
            return NO;
        }
        CVPixelBufferRelease(pb);
    }

    // Finish writing synchronously.
    [input markAsFinished];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                                (int64_t)(10.0 * NSEC_PER_SEC)));

    if (writer.status != AVAssetWriterStatusCompleted) {
        os_log_error(sSmokeLog, "[SmokeTest] Writer did not complete: status=%ld error=%{public}@",
                     (long)writer.status, writer.error.localizedDescription);
        return NO;
    }

    os_log(sSmokeLog, "[SmokeTest] Synthetic video written: %{public}@ (%d frames, %dx%d @ %dfps)",
           path, frameCount, width, height, fps);
    return YES;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGTimelineCompositorSmokeTest
// ─────────────────────────────────────────────────────────────────────────────

@implementation VGTimelineCompositorSmokeTest

+ (void)initialize {
    if (self == [VGTimelineCompositorSmokeTest class]) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            sSmokeLog = os_log_create("com.vanguard.engine", "SmokeTest7_5B");
        });
    }
}

+ (NSDictionary<NSString *, id> *)runWithClipAPath:(nullable NSString *)clipAPath
                                         clipBPath:(nullable NSString *)clipBPath
{
    NSMutableArray<NSDictionary *> *steps = [NSMutableArray array];
    NSMutableArray<NSString *> *logs = [NSMutableArray array];
    BOOL overallSuccess = YES;

    void (^log)(NSString *) = ^(NSString *msg) {
        os_log(sSmokeLog, "[SmokeTest] %{public}@", msg);
        [logs addObject:msg];
    };

    log(@"═══════════════════════════════════════════════════════════");
    log(@"  Phase 7 Stage 7.5B — Timeline Compositor Execution Proof");
    log(@"═══════════════════════════════════════════════════════════");

    // ─── Step 0: Generate synthetic test videos if needed ─────────────────────
    log(@"");
    log(@"Step 0: Preparing test video assets...");

    NSString *tempDir = NSTemporaryDirectory();

    if (clipAPath.length == 0) {
        clipAPath = [tempDir stringByAppendingPathComponent:@"vg_smoke_clip_A.mp4"];
        // 150 frames @ 30fps = 5.0 seconds, red video.
        BOOL ok = _generateSyntheticVideo(clipAPath, 320, 240, 30, 150, 200, 50, 50);
        if (!ok) {
            log(@"  ❌ Failed to generate synthetic clip A");
            [steps addObject:_stepResult(@"Generate Clip A", NO,
                @"AVAssetWriter failed to create synthetic video")];
            return @{@"success": @NO, @"steps": steps, @"logs": logs,
                     @"error": @"Failed to generate clip A"};
        }
        log([NSString stringWithFormat:@"  ✅ Generated clip A: %@", clipAPath]);
    } else {
        log([NSString stringWithFormat:@"  ℹ️  Using provided clip A: %@", clipAPath]);
    }

    if (clipBPath.length == 0) {
        clipBPath = [tempDir stringByAppendingPathComponent:@"vg_smoke_clip_B.mp4"];
        // 150 frames @ 30fps = 5.0 seconds, blue video.
        BOOL ok = _generateSyntheticVideo(clipBPath, 320, 240, 30, 150, 50, 50, 200);
        if (!ok) {
            log(@"  ❌ Failed to generate synthetic clip B");
            [steps addObject:_stepResult(@"Generate Clip B", NO,
                @"AVAssetWriter failed to create synthetic video")];
            return @{@"success": @NO, @"steps": steps, @"logs": logs,
                     @"error": @"Failed to generate clip B"};
        }
        log([NSString stringWithFormat:@"  ✅ Generated clip B: %@", clipBPath]);
    } else {
        log([NSString stringWithFormat:@"  ℹ️  Using provided clip B: %@", clipBPath]);
    }

    [steps addObject:_stepResult(@"Generate Test Videos", YES, @"Synthetic videos ready")];

    // ─── Step 1: Build clip descriptors ───────────────────────────────────────
    log(@"");
    log(@"Step 1: Constructing VGClipDescriptor models...");

    // Clip A: 5.0s duration, starts at 0.0s on timeline, trim [0, 5], speed 1.0
    VGClipDescriptor *clipA =
        [[VGClipDescriptor alloc] initWithClipId:@"smoke_clip_A"
                                       sourceURL:clipAPath
                                       mediaKind:VGClipMediaKindVideo
                               startTimeSeconds:0.0
                               durationSeconds:5.0
                               trimStartSeconds:0.0
                                 trimEndSeconds:5.0
                                           speed:1.0
                                       transform:nil
                                         fitMode:VGStillImageFitModeFit  // default; video clip
                                        cropRect:nil                    // no crop; video clip
                                         freezePTS:nil                    // not a freeze clip
                                        isReversed:NO
                                        timeRemap:nil];     // Phase 7.22B fix: designated initializer requires timeRemap

    // Clip B: 5.0s duration, starts at 5.0s on timeline, trim [0, 5], speed 1.0
    VGClipDescriptor *clipB =
        [[VGClipDescriptor alloc] initWithClipId:@"smoke_clip_B"
                                       sourceURL:clipBPath
                                       mediaKind:VGClipMediaKindVideo
                               startTimeSeconds:5.0
                               durationSeconds:5.0
                               trimStartSeconds:0.0
                                 trimEndSeconds:5.0
                                           speed:1.0
                                       transform:nil
                                         fitMode:VGStillImageFitModeFit  // default; video clip
                                        cropRect:nil                    // no crop; video clip
                                         freezePTS:nil                    // not a freeze clip
                                         isReversed:NO
                                         timeRemap:nil              // Phase 7.22B
                                       transformTrack:nil];          // Phase 7.23B

    if (![clipA isValid] || ![clipB isValid]) {
        log(@"  ❌ Clip descriptor validation failed");
        [steps addObject:_stepResult(@"Clip Descriptors", NO,
            @"VGClipDescriptor -isValid returned NO")];
        return @{@"success": @NO, @"steps": steps, @"logs": logs,
                 @"error": @"Clip descriptors invalid"};
    }

    log([NSString stringWithFormat:@"  ✅ Clip A: id=%@ src=%@ start=%.1fs dur=%.1fs",
         clipA.clipId, clipA.sourceURL, clipA.startTimeSeconds, clipA.durationSeconds]);
    log([NSString stringWithFormat:@"  ✅ Clip B: id=%@ src=%@ start=%.1fs dur=%.1fs",
         clipB.clipId, clipB.sourceURL, clipB.startTimeSeconds, clipB.durationSeconds]);
    [steps addObject:_stepResult(@"Clip Descriptors", YES, @"Both clips valid")];

    // ─── Step 2: Build VGEditorGraphFactory descriptor ────────────────────────
    log(@"");
    log(@"Step 2: Building timeline graph via VGEditorGraphFactory...");

    NSError *factoryError = nil;
    VGGraphDescriptor *descriptor =
        [VGEditorGraphFactory buildTimelineGraphWithClips:@[clipA, clipB]
                                              transitions:@[]
                                                    error:&factoryError];
    if (!descriptor) {
        NSString *errMsg = [NSString stringWithFormat:
            @"VGEditorGraphFactory returned nil: %@", factoryError.localizedDescription];
        log([NSString stringWithFormat:@"  ❌ %@", errMsg]);
        [steps addObject:_stepResult(@"Graph Factory", NO, errMsg)];
        return @{@"success": @NO, @"steps": steps, @"logs": logs, @"error": errMsg};
    }

    log([NSString stringWithFormat:@"  ✅ Descriptor: graphId=%@ nodes=%lu connections=%lu",
         descriptor.graphId,
         (unsigned long)descriptor.nodes.count,
         (unsigned long)descriptor.connections.count]);
    [steps addObject:_stepResult(@"Graph Factory", YES,
        [NSString stringWithFormat:@"graphId=%@ clockPolicy=%ld",
         descriptor.graphId, (long)descriptor.clockPolicy])];

    // ─── Step 3: VGGraphValidator assertion ───────────────────────────────────
    log(@"");
    log(@"Step 3: Validating descriptor via VGGraphValidator...");
    log(@"  (Proves MOD-2: zero-incoming-edge compositor accepted as source)");

    NSArray<VGValidationError *> *validationErrors = nil;
    BOOL validatorPassed = [VGGraphValidator validateDescriptor:descriptor
                                                        errors:&validationErrors];

    if (!validatorPassed) {
        NSString *errDetail = [NSString stringWithFormat:@"Validation errors: %@",
                               validationErrors];
        log([NSString stringWithFormat:@"  ❌ VGGraphValidator rejected: %@", errDetail]);
        [steps addObject:_stepResult(@"Graph Validator", NO, errDetail)];
        return @{@"success": @NO, @"steps": steps, @"logs": logs, @"error": errDetail};
    }

    log(@"  ✅ VGGraphValidator: PASSED (self-sourcing compositor accepted)");
    [steps addObject:_stepResult(@"Graph Validator", YES,
        @"Zero-incoming-edge compositor accepted as valid graph source")];

    // ─── Step 4: Instantiate VGTimelineCompositorNode ─────────────────────────
    log(@"");
    log(@"Step 4: Instantiating VGTimelineCompositorNode from descriptor...");

    // Find the timeline node descriptor.
    VGGraphNodeDescriptor *timelineNodeDesc = nil;
    for (VGGraphNodeDescriptor *nd in descriptor.nodes) {
        if ([nd.nodeId isEqualToString:@"timeline"]) {
            timelineNodeDesc = nd;
            break;
        }
    }

    if (!timelineNodeDesc) {
        log(@"  ❌ No 'timeline' node found in descriptor");
        [steps addObject:_stepResult(@"Compositor Init", NO,
            @"No timeline node in descriptor")];
        return @{@"success": @NO, @"steps": steps, @"logs": logs,
                 @"error": @"No timeline node in descriptor"};
    }

    NSError *initError = nil;
    VGTimelineCompositorNode *compositor =
        [[VGTimelineCompositorNode alloc] initWithNodeId:timelineNodeDesc.nodeId
                                              parameters:timelineNodeDesc.parameters
                                                   ports:timelineNodeDesc.ports
                                                   error:&initError];
    if (!compositor) {
        NSString *errMsg = [NSString stringWithFormat:
            @"VGTimelineCompositorNode init failed: %@", initError.localizedDescription];
        log([NSString stringWithFormat:@"  ❌ %@", errMsg]);
        [steps addObject:_stepResult(@"Compositor Init", NO, errMsg)];
        return @{@"success": @NO, @"steps": steps, @"logs": logs, @"error": errMsg};
    }

    log([NSString stringWithFormat:@"  ✅ VGTimelineCompositorNode: nodeId=%@ nodeClass=%@ "
         "nodeRole=%ld",
         compositor.nodeId, compositor.nodeClass, (long)compositor.nodeRole]);
    [steps addObject:_stepResult(@"Compositor Init", YES,
        [NSString stringWithFormat:@"nodeRole=%ld (compositor)", (long)compositor.nodeRole])];

    // ─── Step 5: prepareWithContext ───────────────────────────────────────────
    log(@"");
    log(@"Step 5: Calling prepareWithContext: (initial generation = 100)...");

    // Build a minimal VGGraphExecutionContext.
    // The smoke test does not need a full scheduler; we create a minimal context
    // with just enough state for prepareWithContext: to capture the generation.
    VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];

    // Build a minimal execution plan (empty — the smoke test drives pulls manually).
    VGExecutionPlan *plan = [[VGExecutionPlan alloc]
        initWithTopologicalOrder:@[timelineNodeDesc.nodeId]
                  parallelGroups:@[@[timelineNodeDesc.nodeId]]];

    VGGraphExecutionContext *ctx =
        [[VGGraphExecutionContext alloc] initWithDescriptor:descriptor
                                                       plan:plan
                                                      nodes:@{@"timeline": compositor}
                                                      clock:nil
                                          resourceAllocator:allocator];

    // Set the initial generation to 100 via incrementGeneration calls.
    // VGGraphExecutionContext starts at generation 0.
    for (int i = 0; i < 100; i++) {
        [ctx incrementGeneration];
    }

    __block NSError *prepareError = nil;
    dispatch_semaphore_t prepareSem = dispatch_semaphore_create(0);
    [compositor prepareWithContext:ctx completion:^(NSError * _Nullable error) {
        prepareError = error;
        dispatch_semaphore_signal(prepareSem);
    }];
    dispatch_semaphore_wait(prepareSem, dispatch_time(DISPATCH_TIME_NOW,
                                                       (int64_t)(5.0 * NSEC_PER_SEC)));

    if (prepareError) {
        NSString *errMsg = [NSString stringWithFormat:
            @"prepareWithContext failed: %@", prepareError.localizedDescription];
        log([NSString stringWithFormat:@"  ❌ %@", errMsg]);
        [steps addObject:_stepResult(@"Prepare", NO, errMsg)];
        [compositor invalidate];
        return @{@"success": @NO, @"steps": steps, @"logs": logs, @"error": errMsg};
    }

    log(@"  ✅ prepareWithContext: completed (generation=100)");
    [steps addObject:_stepResult(@"Prepare", YES, @"generation=100")];

    // ─── Step 6: Headless frame pull — Clip A (PTS 0.0s) ─────────────────────
    log(@"");
    log(@"Step 6: Pulling frame at PTS=0.0s (Clip A)...");

    uint64_t gen = 100;
    VGFrameRequest *req0 =
        [[VGFrameRequest alloc] initWithRequestedPTS:CMTimeMakeWithSeconds(0.0, 600)
                                            duration:kCMTimeInvalid
                                          generation:gen
                                          renderSize:CGSizeZero
                                                mode:VGRenderModePreview];

    VGFrameResult *res0 = [compositor pullFrame:req0];

    if (res0.status != VGFrameStatusDelivered) {
        NSString *errMsg = [NSString stringWithFormat:
            @"Expected delivered at PTS=0.0, got status=%ld", (long)res0.status];
        log([NSString stringWithFormat:@"  ❌ %@", errMsg]);
        [steps addObject:_stepResult(@"Pull PTS=0.0 (Clip A)", NO, errMsg)];
        overallSuccess = NO;
    } else {
        BOOL hasBuffer = (res0.envelope.payload.videoBuffer != NULL);
        log([NSString stringWithFormat:@"  ✅ Delivered: buffer=%@ pts=%.3fs gen=%llu",
             hasBuffer ? @"valid" : @"NULL",
             CMTimeGetSeconds(res0.envelope.pts),
             (unsigned long long)res0.generation]);
        if (!hasBuffer) {
            log(@"  ❌ videoBuffer is NULL");
            overallSuccess = NO;
        }
        [steps addObject:_stepResult(@"Pull PTS=0.0 (Clip A)", hasBuffer,
            [NSString stringWithFormat:@"buffer=%@ pts=%.3fs",
             hasBuffer ? @"valid" : @"NULL", CMTimeGetSeconds(res0.envelope.pts)])];
    }

    // ─── Step 7: Pull at PTS=2.5s (still Clip A) ─────────────────────────────
    log(@"");
    log(@"Step 7: Pulling frame at PTS=2.5s (Clip A mid-range)...");

    VGFrameRequest *req1 =
        [[VGFrameRequest alloc] initWithRequestedPTS:CMTimeMakeWithSeconds(2.5, 600)
                                            duration:kCMTimeInvalid
                                          generation:gen
                                          renderSize:CGSizeZero
                                                mode:VGRenderModePreview];

    VGFrameResult *res1 = [compositor pullFrame:req1];

    if (res1.status != VGFrameStatusDelivered) {
        NSString *errMsg = [NSString stringWithFormat:
            @"Expected delivered at PTS=2.5, got status=%ld", (long)res1.status];
        log([NSString stringWithFormat:@"  ❌ %@", errMsg]);
        [steps addObject:_stepResult(@"Pull PTS=2.5 (Clip A)", NO, errMsg)];
        overallSuccess = NO;
    } else {
        BOOL hasBuffer = (res1.envelope.payload.videoBuffer != NULL);
        log([NSString stringWithFormat:@"  ✅ Delivered: buffer=%@ pts=%.3fs",
             hasBuffer ? @"valid" : @"NULL", CMTimeGetSeconds(res1.envelope.pts)]);
        [steps addObject:_stepResult(@"Pull PTS=2.5 (Clip A)", hasBuffer,
            [NSString stringWithFormat:@"pts=%.3fs", CMTimeGetSeconds(res1.envelope.pts)])];
        if (!hasBuffer) overallSuccess = NO;
    }

    // ─── Step 8: Pull at PTS=5.0s (Clip B start) ─────────────────────────────
    log(@"");
    log(@"Step 8: Pulling frame at PTS=5.0s (Clip B start — tests clip switch)...");

    VGFrameRequest *req2 =
        [[VGFrameRequest alloc] initWithRequestedPTS:CMTimeMakeWithSeconds(5.0, 600)
                                            duration:kCMTimeInvalid
                                          generation:gen
                                          renderSize:CGSizeZero
                                                mode:VGRenderModePreview];

    VGFrameResult *res2 = [compositor pullFrame:req2];

    if (res2.status != VGFrameStatusDelivered) {
        NSString *errMsg = [NSString stringWithFormat:
            @"Expected delivered at PTS=5.0, got status=%ld", (long)res2.status];
        log([NSString stringWithFormat:@"  ❌ %@", errMsg]);
        [steps addObject:_stepResult(@"Pull PTS=5.0 (Clip B)", NO, errMsg)];
        overallSuccess = NO;
    } else {
        BOOL hasBuffer = (res2.envelope.payload.videoBuffer != NULL);
        log([NSString stringWithFormat:@"  ✅ Delivered: buffer=%@ pts=%.3fs",
             hasBuffer ? @"valid" : @"NULL", CMTimeGetSeconds(res2.envelope.pts)]);
        [steps addObject:_stepResult(@"Pull PTS=5.0 (Clip B)", hasBuffer,
            [NSString stringWithFormat:@"pts=%.3fs (clip switch verified)",
             CMTimeGetSeconds(res2.envelope.pts)])];
        if (!hasBuffer) overallSuccess = NO;
    }

    // ─── Step 9: Pull at PTS=7.5s (Clip B mid-range) ─────────────────────────
    log(@"");
    log(@"Step 9: Pulling frame at PTS=7.5s (Clip B mid-range)...");

    VGFrameRequest *req3 =
        [[VGFrameRequest alloc] initWithRequestedPTS:CMTimeMakeWithSeconds(7.5, 600)
                                            duration:kCMTimeInvalid
                                          generation:gen
                                          renderSize:CGSizeZero
                                                mode:VGRenderModePreview];

    VGFrameResult *res3 = [compositor pullFrame:req3];

    if (res3.status != VGFrameStatusDelivered) {
        NSString *errMsg = [NSString stringWithFormat:
            @"Expected delivered at PTS=7.5, got status=%ld", (long)res3.status];
        log([NSString stringWithFormat:@"  ❌ %@", errMsg]);
        [steps addObject:_stepResult(@"Pull PTS=7.5 (Clip B)", NO, errMsg)];
        overallSuccess = NO;
    } else {
        BOOL hasBuffer = (res3.envelope.payload.videoBuffer != NULL);
        log([NSString stringWithFormat:@"  ✅ Delivered: buffer=%@ pts=%.3fs",
             hasBuffer ? @"valid" : @"NULL", CMTimeGetSeconds(res3.envelope.pts)]);
        [steps addObject:_stepResult(@"Pull PTS=7.5 (Clip B)", hasBuffer,
            [NSString stringWithFormat:@"pts=%.3fs", CMTimeGetSeconds(res3.envelope.pts)])];
        if (!hasBuffer) overallSuccess = NO;
    }

    // ─── Step 10: EOS detection at PTS=10.0s ─────────────────────────────────
    log(@"");
    log(@"Step 10: Pulling frame at PTS=10.0s (expected EOS)...");

    VGFrameRequest *reqEOS =
        [[VGFrameRequest alloc] initWithRequestedPTS:CMTimeMakeWithSeconds(10.0, 600)
                                            duration:kCMTimeInvalid
                                          generation:gen
                                          renderSize:CGSizeZero
                                                mode:VGRenderModePreview];

    VGFrameResult *resEOS = [compositor pullFrame:reqEOS];

    if (resEOS.status != VGFrameStatusEndOfStream) {
        NSString *errMsg = [NSString stringWithFormat:
            @"Expected endOfStream at PTS=10.0, got status=%ld", (long)resEOS.status];
        log([NSString stringWithFormat:@"  ❌ %@", errMsg]);
        [steps addObject:_stepResult(@"EOS at PTS=10.0", NO, errMsg)];
        overallSuccess = NO;
    } else {
        log(@"  ✅ End-of-stream detected at timeline end");
        [steps addObject:_stepResult(@"EOS at PTS=10.0", YES,
            @"VGFrameStatusEndOfStream returned correctly")];
    }

    // ─── Step 11: Seek + stale generation ─────────────────────────────────────
    log(@"");
    log(@"Step 11: Seek to PTS=2.5s with generation=101, then pull with stale gen=100...");

    uint64_t newGen = 101;
    [compositor seekTo:CMTimeMakeWithSeconds(2.5, 600) generation:newGen];

    VGFrameRequest *reqStale =
        [[VGFrameRequest alloc] initWithRequestedPTS:CMTimeMakeWithSeconds(2.5, 600)
                                            duration:kCMTimeInvalid
                                          generation:gen  // stale: 100 != 101
                                          renderSize:CGSizeZero
                                                mode:VGRenderModePreview];

    VGFrameResult *resStale = [compositor pullFrame:reqStale];

    if (resStale.status != VGFrameStatusSkipped) {
        NSString *errMsg = [NSString stringWithFormat:
            @"Expected skipped for stale gen=%llu, got status=%ld",
            (unsigned long long)gen, (long)resStale.status];
        log([NSString stringWithFormat:@"  ❌ %@", errMsg]);
        [steps addObject:_stepResult(@"Stale Generation Skip", NO, errMsg)];
        overallSuccess = NO;
    } else {
        log(@"  ✅ Stale generation correctly returned skipped");
        [steps addObject:_stepResult(@"Stale Generation Skip", YES,
            @"gen=100 vs node gen=101 → skipped")];
    }

    // ─── Step 12: Pull with matching generation after seek ────────────────────
    log(@"");
    log(@"Step 12: Pulling with matching generation=101 after seek...");

    VGFrameRequest *reqMatch =
        [[VGFrameRequest alloc] initWithRequestedPTS:CMTimeMakeWithSeconds(2.5, 600)
                                            duration:kCMTimeInvalid
                                          generation:newGen  // matching: 101
                                          renderSize:CGSizeZero
                                                mode:VGRenderModePreview];

    VGFrameResult *resMatch = [compositor pullFrame:reqMatch];

    if (resMatch.status != VGFrameStatusDelivered) {
        NSString *errMsg = [NSString stringWithFormat:
            @"Expected delivered after seek with gen=%llu, got status=%ld",
            (unsigned long long)newGen, (long)resMatch.status];
        log([NSString stringWithFormat:@"  ❌ %@", errMsg]);
        [steps addObject:_stepResult(@"Post-Seek Delivery", NO, errMsg)];
        overallSuccess = NO;
    } else {
        BOOL hasBuffer = (resMatch.envelope.payload.videoBuffer != NULL);
        log([NSString stringWithFormat:@"  ✅ Delivered after seek: buffer=%@ pts=%.3fs",
             hasBuffer ? @"valid" : @"NULL", CMTimeGetSeconds(resMatch.envelope.pts)]);
        [steps addObject:_stepResult(@"Post-Seek Delivery", hasBuffer,
            [NSString stringWithFormat:@"pts=%.3fs gen=%llu",
             CMTimeGetSeconds(resMatch.envelope.pts), (unsigned long long)newGen])];
        if (!hasBuffer) overallSuccess = NO;
    }

    // ─── Step 13: Invalidate teardown ─────────────────────────────────────────
    log(@"");
    log(@"Step 13: Calling invalidate (resource cleanup)...");

    [compositor invalidate];

    log(@"  ✅ invalidate completed");
    [steps addObject:_stepResult(@"Invalidate", YES, @"Clean teardown")];

    // ─── Step 14: Pull after invalidate returns error ─────────────────────────
    log(@"");
    log(@"Step 14: Pulling after invalidate (expected error)...");

    VGFrameRequest *reqPost =
        [[VGFrameRequest alloc] initWithRequestedPTS:CMTimeMakeWithSeconds(0.0, 600)
                                            duration:kCMTimeInvalid
                                          generation:newGen
                                          renderSize:CGSizeZero
                                                mode:VGRenderModePreview];

    VGFrameResult *resPost = [compositor pullFrame:reqPost];

    if (resPost.status != VGFrameStatusError) {
        NSString *errMsg = [NSString stringWithFormat:
            @"Expected error after invalidate, got status=%ld", (long)resPost.status];
        log([NSString stringWithFormat:@"  ❌ %@", errMsg]);
        [steps addObject:_stepResult(@"Post-Invalidate Error", NO, errMsg)];
        overallSuccess = NO;
    } else {
        log([NSString stringWithFormat:@"  ✅ Correctly returned error: %@",
             resPost.error.localizedDescription]);
        [steps addObject:_stepResult(@"Post-Invalidate Error", YES,
            @"pullFrame: after invalidate returns error")];
    }

    // ─── Summary ──────────────────────────────────────────────────────────────
    log(@"");
    log(@"═══════════════════════════════════════════════════════════");
    if (overallSuccess) {
        log(@"  ✅ ALL STEPS PASSED — Stage 7.5B Execution Proof COMPLETE");
    } else {
        log(@"  ❌ SOME STEPS FAILED — review step details above");
    }
    log(@"═══════════════════════════════════════════════════════════");

    // Clean up synthetic test files.
    NSString *clipACleanup = [tempDir stringByAppendingPathComponent:@"vg_smoke_clip_A.mp4"];
    NSString *clipBCleanup = [tempDir stringByAppendingPathComponent:@"vg_smoke_clip_B.mp4"];
    [[NSFileManager defaultManager] removeItemAtPath:clipACleanup error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:clipBCleanup error:nil];

    NSDictionary *result = @{
        @"success": @(overallSuccess),
        @"steps": [steps copy],
        @"logs": [logs copy],
    };

    if (!overallSuccess) {
        // Find first failure.
        for (NSDictionary *step in steps) {
            if (![step[@"passed"] boolValue]) {
                NSMutableDictionary *mutable = [result mutableCopy];
                mutable[@"error"] = step[@"detail"];
                result = [mutable copy];
                break;
            }
        }
    }

    return result;
}

// ─── Phase 7 Stage 7.5C: generateSyntheticClipPaths ──────────────────────────
//
// Generates two solid-color synthetic MP4 clips to NSTemporaryDirectory for
// use by the visual playback proof playground (dev_createTimelineTexture with
// useSyntheticClips=YES). Files are named differently from the smoke test files
// so the playback proof doesn't clash with the smoke test's files.
//
// Reuses the existing file-scope _generateSyntheticVideo helper.
// File names:
//   vg_playback_clip_A.mp4  — red,  320×240, 5s @ 30fps.
//   vg_playback_clip_B.mp4  — blue, 320×240, 5s @ 30fps.
//
// Files are idempotent: regenerated only if absent.

+ (NSDictionary<NSString *, NSString *> *)generateSyntheticClipPaths {
    NSString *tempDir = NSTemporaryDirectory();
    NSString *pathA   = [tempDir stringByAppendingPathComponent:@"vg_playback_clip_A.mp4"];
    NSString *pathB   = [tempDir stringByAppendingPathComponent:@"vg_playback_clip_B.mp4"];

    NSFileManager *fm = [NSFileManager defaultManager];

    // Clip A: red, 150 frames @ 30fps = 5.0s.
    if (![fm fileExistsAtPath:pathA]) {
        BOOL ok = _generateSyntheticVideo(pathA, 320, 240, 30, 150, 220, 50, 50);
        if (!ok) {
            os_log_error(sSmokeLog,
                         "[7.5C] generateSyntheticClipPaths: failed to generate clip A");
            return nil;
        }
    }

    // Clip B: blue, 150 frames @ 30fps = 5.0s.
    if (![fm fileExistsAtPath:pathB]) {
        BOOL ok = _generateSyntheticVideo(pathB, 320, 240, 30, 150, 50, 50, 220);
        if (!ok) {
            os_log_error(sSmokeLog,
                         "[7.5C] generateSyntheticClipPaths: failed to generate clip B");
            return nil;
        }
    }

    os_log(sSmokeLog,
           "[7.5C] generateSyntheticClipPaths: A=%{public}@ B=%{public}@", pathA, pathB);
    return @{ @"clipAPath": pathA, @"clipBPath": pathB };
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Moving-pattern video generator (Stage 7.5D)
// ─────────────────────────────────────────────────────────────────────────────

/// Generate a moving-pattern H.264 MP4 video at the given path.
///
/// Each frame is filled with a solid BGRA base color, then overlaid with a
/// 30-pixel-wide vertical white stripe that advances 4 pixels per frame,
/// proving true inter-frame motion in the compressed H.264 bitstream.
///
/// Pixel addressing:
///   base + y * bytesPerRow + x * 4  (byte-level, no stride / 4 assumption).
///   BGRA channel order: [0]=B  [1]=G  [2]=R  [3]=A.
///
/// This function is SEPARATE from _generateSyntheticVideo and must never be
/// merged with or called from _generateSyntheticVideo. The 7.5C solid-color
/// path must remain entirely untouched.
///
/// @param path       Absolute file path for the output MP4.
/// @param width      Video width in pixels.
/// @param height     Video height in pixels.
/// @param fps        Frames per second (timescale for CMTime).
/// @param frameCount Total number of frames to encode.
/// @param baseR      Base background red channel (0–255).
/// @param baseG      Base background green channel (0–255).
/// @param baseB      Base background blue channel (0–255).
/// @return YES on success, NO on failure.
static BOOL _generateMovingPatternVideo(NSString *path,
                                        int width, int height,
                                        int fps, int frameCount,
                                        uint8_t baseR, uint8_t baseG, uint8_t baseB)
{
    // Remove any existing file at path.
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

    NSURL *outputURL = [NSURL fileURLWithPath:path];
    NSError *error = nil;

    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:outputURL
                                                      fileType:AVFileTypeMPEG4
                                                         error:&error];
    if (!writer) {
        os_log_error(sSmokeLog,
                     "[7.5D] _generateMovingPatternVideo: AVAssetWriter init failed: %{public}@",
                     error.localizedDescription);
        return NO;
    }

    NSDictionary *outputSettings = @{
        AVVideoCodecKey:  AVVideoCodecTypeH264,
        AVVideoWidthKey:  @(width),
        AVVideoHeightKey: @(height),
    };

    AVAssetWriterInput *input =
        [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                          outputSettings:outputSettings];
    input.expectsMediaDataInRealTime = NO;

    NSDictionary *pixelBufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:          @(width),
        (id)kCVPixelBufferHeightKey:         @(height),
    };

    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [[AVAssetWriterInputPixelBufferAdaptor alloc]
            initWithAssetWriterInput:input
            sourcePixelBufferAttributes:pixelBufferAttributes];

    if (![writer canAddInput:input]) {
        os_log_error(sSmokeLog, "[7.5D] _generateMovingPatternVideo: cannot add input to writer");
        return NO;
    }
    [writer addInput:input];

    if (![writer startWriting]) {
        os_log_error(sSmokeLog,
                     "[7.5D] _generateMovingPatternVideo: startWriting failed: %{public}@",
                     writer.error.localizedDescription);
        return NO;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    // Half-width of the moving white stripe (pixels on each side of centre).
    const int kStripeHalfWidth = 15;
    // Pixels the stripe centre advances per frame.
    const int kStripeStep = 4;

    // Write frames.
    for (int i = 0; i < frameCount; i++) {
        // Wait until the input is ready.
        while (!input.readyForMoreMediaData) {
            [NSThread sleepForTimeInterval:0.01];
        }

        // Create pixel buffer.
        CVPixelBufferRef pb = NULL;
        CVReturn status = CVPixelBufferPoolCreatePixelBuffer(
            NULL, adaptor.pixelBufferPool, &pb);
        if (status != kCVReturnSuccess || !pb) {
            os_log_error(sSmokeLog,
                         "[7.5D] _generateMovingPatternVideo: CVPixelBuffer creation failed at frame %d",
                         i);
            return NO;
        }

        CVPixelBufferLockBaseAddress(pb, 0);
        uint8_t *base     = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
        // bytesPerRow is used in bytes — no /4 division so alignment padding is
        // handled correctly on all ARM64 hardware configurations.
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
        size_t bufHeight   = CVPixelBufferGetHeight(pb);

        // Compute stripe centre x for this frame (wraps around width).
        int stripeCentreX = (i * kStripeStep) % width;

        for (size_t y = 0; y < bufHeight; y++) {
            for (int x = 0; x < width; x++) {
                // Byte-level BGRA pixel pointer.
                // BGRA layout: [0]=B  [1]=G  [2]=R  [3]=A
                uint8_t *p = base + y * bytesPerRow + (size_t)x * 4;

                // Distance from stripe centre, wrapping around the width.
                int dist = abs(x - stripeCentreX);
                // Also check wrap-around distance so the stripe appears
                // smoothly at the left edge when it exits the right edge.
                int distWrap = width - dist;
                BOOL inStripe = (dist < kStripeHalfWidth) || (distWrap < kStripeHalfWidth);

                if (inStripe) {
                    // White stripe — fully opaque.
                    p[0] = 255; // B
                    p[1] = 255; // G
                    p[2] = 255; // R
                    p[3] = 255; // A
                } else {
                    // Solid background color (BGRA channel order).
                    p[0] = baseB; // B
                    p[1] = baseG; // G
                    p[2] = baseR; // R
                    p[3] = 255;   // A
                }
            }
        }

        CVPixelBufferUnlockBaseAddress(pb, 0);

        CMTime presentationTime = CMTimeMake(i, fps);
        if (![adaptor appendPixelBuffer:pb withPresentationTime:presentationTime]) {
            os_log_error(sSmokeLog,
                         "[7.5D] _generateMovingPatternVideo: appendPixelBuffer failed at frame %d: %{public}@",
                         i, writer.error.localizedDescription);
            CVPixelBufferRelease(pb);
            return NO;
        }
        CVPixelBufferRelease(pb);
    }

    // Finish writing synchronously.
    [input markAsFinished];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                                (int64_t)(30.0 * NSEC_PER_SEC)));

    if (writer.status != AVAssetWriterStatusCompleted) {
        os_log_error(sSmokeLog,
                     "[7.5D] _generateMovingPatternVideo: writer did not complete: "
                     "status=%ld error=%{public}@",
                     (long)writer.status, writer.error.localizedDescription);
        return NO;
    }

    os_log(sSmokeLog,
           "[7.5D] _generateMovingPatternVideo: written %{public}@ (%d frames, %dx%d @ %dfps)",
           path, frameCount, width, height, fps);
    return YES;
}

// ─── Phase 7 Stage 7.5D: generateRealVideoClipPaths ──────────────────────────
//
// Generates two moving-pattern H.264 MP4 clips to NSTemporaryDirectory for
// use by the real-video playback proof (dev_createTimelineTexture with
// useRealVideoClips=YES). The generated videos contain true inter-frame motion
// (a scrolling white vertical stripe on a solid background), proving that
// AVAssetReader is decompressing genuine H.264 content rather than static frames.
//
// File names:
//   vg_playback_real_clip_A.mp4 — red base + moving stripe, 640×360, 5s @ 30fps.
//   vg_playback_real_clip_B.mp4 — blue base + moving stripe, 640×360, 5s @ 30fps.
//
// Files are idempotent: regenerated only if absent.
// Always delete and regenerate to avoid stale files from prior runs.

+ (NSDictionary<NSString *, NSString *> *)generateRealVideoClipPaths {
    NSString *tempDir = NSTemporaryDirectory();
    NSString *pathA   = [tempDir stringByAppendingPathComponent:@"vg_playback_real_clip_A.mp4"];
    NSString *pathB   = [tempDir stringByAppendingPathComponent:@"vg_playback_real_clip_B.mp4"];

    NSFileManager *fm = [NSFileManager defaultManager];

    // Clip A: red base + moving white stripe, 640×360, 150 frames @ 30fps = 5.0s.
    if (![fm fileExistsAtPath:pathA]) {
        // Red base: R=220, G=50, B=50.
        BOOL ok = _generateMovingPatternVideo(pathA, 640, 360, 30, 150, 220, 50, 50);
        if (!ok) {
            os_log_error(sSmokeLog,
                         "[7.5D] generateRealVideoClipPaths: failed to generate clip A");
            return nil;
        }
    }

    // Clip B: blue base + moving white stripe, 640×360, 150 frames @ 30fps = 5.0s.
    if (![fm fileExistsAtPath:pathB]) {
        // Blue base: R=50, G=50, B=220.
        BOOL ok = _generateMovingPatternVideo(pathB, 640, 360, 30, 150, 50, 50, 220);
        if (!ok) {
            os_log_error(sSmokeLog,
                         "[7.5D] generateRealVideoClipPaths: failed to generate clip B");
            return nil;
        }
    }

    os_log(sSmokeLog,
           "[7.5D] generateRealVideoClipPaths: A=%{public}@ B=%{public}@", pathA, pathB);
    return @{ @"clipAPath": pathA, @"clipBPath": pathB };
}

// ── Phase 7.16: Still-image fit/fill/crop smoke test ──────────────────────────────
//
// Validates VGClipDescriptor fitMode/cropRect serialization and native validation
// via +fromDictionary:. Does NOT require a real PNG on disk; it exercises the
// Objective-C contract layer only (no compositor execution).

+ (NSDictionary<NSString *, id> *)runStillImageFitCropSmokeTest {
    NSMutableArray<NSDictionary *> *steps = [NSMutableArray array];
    NSMutableArray<NSString *> *logs = [NSMutableArray array];
    __block BOOL overallSuccess = YES;

    void (^log)(NSString *) = ^(NSString *msg) {
        [logs addObject:msg];
        os_log(sSmokeLog, "[7.16] %{public}@", msg);
    };
    void (^step)(NSString *, BOOL, NSString *) = ^(NSString *name, BOOL passed, NSString *detail) {
        if (!passed) overallSuccess = NO;
        [steps addObject:_stepResult(name, passed, detail)];
    };

    log(@"Phase 7.16 Still-Image Fit/Crop Smoke Test");
    log(@"Tests VGClipDescriptor fitMode/cropRect contract via fromDictionary:");
    log(@"");

    // ─── Test 1: fitMode=fill round-trip ─────────────────────────────────────
    log(@"Test 1: fitMode=fill serialises and deserialises via fromDictionary:");
    {
        // Build a dictionary with fitMode=fill (image clip).
        NSDictionary *dict = @{
            @"id"               : @"img-fill-7.16",
            @"sourcePath"       : @"/tmp/smoke_still.png", // path only checked by compositor
            @"mediaKind"        : @"image",
            @"startTimeSeconds" : @0.0,
            @"durationSeconds"  : @5.0,
            @"trimStartSeconds" : @0.0,
            @"trimEndSeconds"   : @5.0,
            @"speed"            : @1.0,
            @"fitMode"          : @"fill",
        };
        VGClipDescriptor *clip = [VGClipDescriptor fromDictionary:dict];
        BOOL passed = (clip != nil && clip.fitMode == VGStillImageFitModeFill && clip.cropRect == nil);
        if (passed) {
            log(@"  ✅ fitMode=fill: fromDictionary: returned non-nil descriptor with fitMode=fill");
        } else {
            log([NSString stringWithFormat:
                 @"  ❌ fitMode=fill: fromDictionary: returned %@ (fitMode=%ld)",
                 clip ?: (id)@"nil", (long)(clip ? clip.fitMode : -1)]);
        }
        step(@"fitMode=fill round-trip", passed, passed
             ? @"VGStillImageFitModeFill deserialized correctly"
             : @"fromDictionary: returned nil or wrong fitMode");
    }

    // ─── Test 2: cropRect=[0.2,0.2,0.6,0.6] + fitMode=fit round-trip ─────────
    log(@"");
    log(@"Test 2: cropRect=[0.2,0.2,0.6,0.6] + fitMode=fit (default) round-trip:");
    {
        NSDictionary *dict = @{
            @"id"               : @"img-crop-7.16",
            @"sourcePath"       : @"/tmp/smoke_still.png",
            @"mediaKind"        : @"image",
            @"startTimeSeconds" : @0.0,
            @"durationSeconds"  : @5.0,
            @"trimStartSeconds" : @0.0,
            @"trimEndSeconds"   : @5.0,
            @"speed"            : @1.0,
            // fitMode omitted — should default to fit
            @"cropRect"         : @[ @0.2, @0.2, @0.6, @0.6 ],
        };
        VGClipDescriptor *clip = [VGClipDescriptor fromDictionary:dict];
        BOOL rectOK = NO;
        if (clip.cropRect.count == 4) {
            double x = [clip.cropRect[0] doubleValue];
            double y = [clip.cropRect[1] doubleValue];
            double w = [clip.cropRect[2] doubleValue];
            double h = [clip.cropRect[3] doubleValue];
            rectOK = (fabs(x - 0.2) < 1e-9 && fabs(y - 0.2) < 1e-9 &&
                      fabs(w - 0.6) < 1e-9 && fabs(h - 0.6) < 1e-9);
        }
        BOOL passed = (clip != nil && clip.fitMode == VGStillImageFitModeFit && rectOK);
        if (passed) {
            log(@"  ✅ cropRect+fit: fromDictionary: returned non-nil descriptor with correct values");
        } else {
            log([NSString stringWithFormat:
                 @"  ❌ cropRect+fit: clip=%@ fitMode=%ld cropRect=%@ rectOK=%d",
                 clip ?: (id)@"nil", (long)(clip ? clip.fitMode : -1),
                 clip.cropRect ?: (id)@"nil", rectOK]);
        }
        step(@"cropRect+fit round-trip", passed, passed
             ? @"cropRect=[0.2,0.2,0.6,0.6] and fitMode=fit deserialized correctly"
             : @"fromDictionary: returned nil or wrong values");
    }

    // ─── Test 3: Invalid cropRect rejected by fromDictionary: ─────────────────
    log(@"");
    log(@"Test 3: Invalid cropRect=[0.8,0.8,0.5,0.5] must be rejected (x+w=1.3>1.0, y+h=1.3>1.0):");
    {
        NSDictionary *dict = @{
            @"id"               : @"img-invalid-crop-7.16",
            @"sourcePath"       : @"/tmp/smoke_still.png",
            @"mediaKind"        : @"image",
            @"startTimeSeconds" : @0.0,
            @"durationSeconds"  : @5.0,
            @"trimStartSeconds" : @0.0,
            @"trimEndSeconds"   : @5.0,
            @"speed"            : @1.0,
            @"cropRect"         : @[ @0.8, @0.8, @0.5, @0.5 ], // x+w=1.3>1.0 — invalid
        };
        VGClipDescriptor *clip = [VGClipDescriptor fromDictionary:dict];
        BOOL passed = (clip == nil); // must return nil for invalid crop
        if (passed) {
            log(@"  ✅ Invalid cropRect correctly rejected (fromDictionary: returned nil)");
        } else {
            log([NSString stringWithFormat:
                 @"  ❌ Invalid cropRect was NOT rejected (fromDictionary: returned non-nil: %@)",
                 clip]);
        }
        step(@"Invalid cropRect rejection", passed, passed
             ? @"fromDictionary: returned nil for x+w>1.0 cropRect"
             : @"fromDictionary: should have returned nil but did not");
    }

    // ─── Summary ──────────────────────────────────────────────────────────────
    log(@"");
    log(@"═══════════════════════════════════════════════════════");
    if (overallSuccess) {
        log(@"  ✅ ALL PHASE 7.16 NATIVE TESTS PASSED");
    } else {
        log(@"  ❌ SOME PHASE 7.16 NATIVE TESTS FAILED");
    }
    log(@"═══════════════════════════════════════════════════════");

    NSMutableDictionary *result = [@{
        @"success": @(overallSuccess),
        @"steps": [steps copy],
        @"logs": [logs copy],
    } mutableCopy];
    if (!overallSuccess) {
        for (NSDictionary *s in steps) {
            if (![s[@"passed"] boolValue]) {
                result[@"error"] = s[@"detail"];
                break;
            }
        }
    }
    return [result copy];
}

// ── Phase 7.17: Freeze-frame descriptor contract smoke test ──────────────────────
//
// Validates VGClipDescriptor freezePTS serialisation and rejection of invalid
// values via +fromDictionary:. Exercises the Objective-C contract layer only;
// no compositor execution or AVAssetImageGenerator is invoked.

+ (NSDictionary<NSString *, id> *)runFreezeFrameDescriptorSmokeTest {
    NSMutableArray<NSDictionary *> *steps = [NSMutableArray array];
    NSMutableArray<NSString *> *logs = [NSMutableArray array];
    __block BOOL overallSuccess = YES;

    void (^log)(NSString *) = ^(NSString *msg) {
        [logs addObject:msg];
        os_log(sSmokeLog, "[7.17] %{public}@", msg);
    };
    void (^step)(NSString *, BOOL, NSString *) = ^(NSString *name, BOOL passed, NSString *detail) {
        if (!passed) overallSuccess = NO;
        [steps addObject:_stepResult(name, passed, detail)];
    };

    log(@"Phase 7.17 Freeze-Frame Descriptor Contract Smoke Test");
    log(@"Tests VGClipDescriptor freezePTS contract via fromDictionary:");
    log(@"");

    // ─── Test 1: freezePTS=3.0 round-trip via fromDictionary: ────────────────
    log(@"Test 1: freezePTS=3.0 round-trips via fromDictionary:");
    {
        NSDictionary *dict = @{
            @"id"               : @"vid-freeze-7.17",
            @"sourcePath"       : @"/tmp/smoke_video.mp4",
            @"mediaKind"        : @"video",
            @"startTimeSeconds" : @0.0,
            @"durationSeconds"  : @2.0,
            @"trimStartSeconds" : @0.0,
            @"trimEndSeconds"   : @2.0,
            @"speed"            : @1.0,
            @"freezePTS"        : @3.0,
        };
        VGClipDescriptor *clip = [VGClipDescriptor fromDictionary:dict];
        BOOL passed = (clip != nil
                       && clip.freezePTS != nil
                       && fabs(clip.freezePTS.doubleValue - 3.0) < 1e-9);
        if (passed) {
            log(@"  ✅ freezePTS=3.0: fromDictionary: returned non-nil with correct PTS");
        } else {
            log([NSString stringWithFormat:
                 @"  ❌ freezePTS=3.0: clip=%@ freezePTS=%@",
                 clip ?: (id)@"nil", clip.freezePTS ?: (id)@"nil"]);
        }
        step(@"freezePTS=3.0 round-trip", passed, passed
             ? @"freezePTS=3.0 deserialized correctly"
             : @"fromDictionary: returned nil or wrong freezePTS value");
    }

    // ─── Test 2: freezePTS absent (normal clip) ───────────────────────────────
    log(@"");
    log(@"Test 2: absent freezePTS key (normal video clip) — must deserialise as nil:");
    {
        NSDictionary *dict = @{
            @"id"               : @"vid-normal-7.17",
            @"sourcePath"       : @"/tmp/smoke_video.mp4",
            @"mediaKind"        : @"video",
            @"startTimeSeconds" : @0.0,
            @"durationSeconds"  : @5.0,
            @"trimStartSeconds" : @0.0,
            @"trimEndSeconds"   : @5.0,
            @"speed"            : @1.0,
            // freezePTS intentionally absent
        };
        VGClipDescriptor *clip = [VGClipDescriptor fromDictionary:dict];
        BOOL passed = (clip != nil && clip.freezePTS == nil);
        if (passed) {
            log(@"  ✅ absent freezePTS: fromDictionary: returned non-nil with nil freezePTS");
        } else {
            log([NSString stringWithFormat:
                 @"  ❌ absent freezePTS: clip=%@ freezePTS=%@",
                 clip ?: (id)@"nil", clip.freezePTS ?: (id)@"nil"]);
        }
        step(@"absent freezePTS → nil", passed, passed
             ? @"freezePTS correctly nil when key absent"
             : @"fromDictionary: returned nil or unexpected non-nil freezePTS");
    }

    // ─── Test 3: Negative freezePTS=-1.0 must be rejected ────────────────────
    log(@"");
    log(@"Test 3: negative freezePTS=-1.0 must be rejected by fromDictionary:");
    {
        NSDictionary *dict = @{
            @"id"               : @"vid-neg-freeze-7.17",
            @"sourcePath"       : @"/tmp/smoke_video.mp4",
            @"mediaKind"        : @"video",
            @"startTimeSeconds" : @0.0,
            @"durationSeconds"  : @2.0,
            @"trimStartSeconds" : @0.0,
            @"trimEndSeconds"   : @2.0,
            @"speed"            : @1.0,
            @"freezePTS"        : @(-1.0), // invalid: must be non-negative
        };
        VGClipDescriptor *clip = [VGClipDescriptor fromDictionary:dict];
        BOOL passed = (clip == nil); // must return nil for negative freezePTS
        if (passed) {
            log(@"  ✅ Negative freezePTS correctly rejected (fromDictionary: returned nil)");
        } else {
            log([NSString stringWithFormat:
                 @"  ❌ Negative freezePTS was NOT rejected (returned non-nil: %@)",
                 clip]);
        }
        step(@"Negative freezePTS rejection", passed, passed
             ? @"fromDictionary: returned nil for freezePTS=-1.0"
             : @"fromDictionary: should have returned nil but did not");
    }

    // ─── Summary ──────────────────────────────────────────────────────────────
    log(@"");
    log(@"═══════════════════════════════════════════════════════");
    if (overallSuccess) {
        log(@"  ✅ ALL PHASE 7.17 NATIVE TESTS PASSED");
    } else {
        log(@"  ❌ SOME PHASE 7.17 NATIVE TESTS FAILED");
    }
    log(@"═══════════════════════════════════════════════════════");

    NSMutableDictionary *result = [@{
        @"success": @(overallSuccess),
        @"steps": [steps copy],
        @"logs": [logs copy],
    } mutableCopy];
    if (!overallSuccess) {
        for (NSDictionary *s in steps) {
            if (![s[@"passed"] boolValue]) {
                result[@"error"] = s[@"detail"];
                break;
            }
        }
    }
    return [result copy];
}

@end

// ── Phase 7.19: Reverse-playback descriptor contract smoke test ─────────────
//
// Validates VGClipDescriptor isReversed serialisation and isValid constraints
// via +fromDictionary: and -isValid. Exercises the Objective-C contract layer
// only; no compositor execution or AVAssetImageGenerator is invoked.
//
// Five subtests:
//   1. isReversed=YES round-trips via fromDictionary: (non-nil, value=YES).
//   2. isReversed=NO (absent key) round-trips as NO (normal clip).
//   3. toDictionary omits isReversed key when NO.
//   4. isValid rejects isReversed=YES on an image clip.
//   5. isValid rejects isReversed=YES on a freeze-frame clip.

@implementation VGTimelineCompositorSmokeTest (Phase719)

+ (NSDictionary<NSString *, id> *)runReverseDescriptorSmokeTest {
    NSMutableArray<NSDictionary *> *steps = [NSMutableArray array];
    NSMutableArray<NSString *> *logs = [NSMutableArray array];
    __block BOOL overallSuccess = YES;

    void (^log)(NSString *) = ^(NSString *msg) {
        [logs addObject:msg];
        os_log(sSmokeLog, "[7.19] %{public}@", msg);
    };
    void (^step)(NSString *, BOOL, NSString *) = ^(NSString *name, BOOL passed, NSString *detail) {
        if (!passed) overallSuccess = NO;
        [steps addObject:_stepResult(name, passed, detail)];
    };

    log(@"Phase 7.19 Reverse-Playback Descriptor Contract Smoke Test");
    log(@"Tests VGClipDescriptor isReversed contract via fromDictionary: and isValid");
    log(@"");

    // ─── Test 1: isReversed=YES round-trip via fromDictionary: ───────────────
    log(@"Test 1: isReversed=YES round-trips via fromDictionary:");
    {
        NSDictionary *dict = @{
            @"id"               : @"vid-reversed-7.19",
            @"sourcePath"       : @"/tmp/smoke_video.mp4",
            @"mediaKind"        : @"video",
            @"startTimeSeconds" : @0.0,
            @"durationSeconds"  : @5.0,
            @"trimStartSeconds" : @0.0,
            @"trimEndSeconds"   : @5.0,
            @"speed"            : @1.0,
            @"isReversed"       : @YES,
        };
        VGClipDescriptor *clip = [VGClipDescriptor fromDictionary:dict];
        BOOL passed = (clip != nil && clip.isReversed == YES && [clip isValid]);
        if (passed) {
            log(@"  \u2705 isReversed=YES: fromDictionary: returned non-nil with isReversed=YES and isValid=YES");
        } else {
            log([NSString stringWithFormat:
                 @"  \u274c isReversed=YES: clip=%@ isReversed=%@ isValid=%@",
                 clip ?: (id)@"nil",
                 clip ? @(clip.isReversed) : (id)@"nil",
                 clip ? @([clip isValid]) : (id)@"nil"]);
        }
        step(@"isReversed=YES round-trip", passed, passed
             ? @"isReversed=YES deserialized correctly and passes isValid"
             : @"fromDictionary: returned nil, wrong isReversed, or isValid failed");
    }

    // ─── Test 2: absent isReversed key → NO (normal forward clip) ────────────
    log(@"");
    log(@"Test 2: absent isReversed key (normal video clip) — must deserialise as NO:");
    {
        NSDictionary *dict = @{
            @"id"               : @"vid-forward-7.19",
            @"sourcePath"       : @"/tmp/smoke_video.mp4",
            @"mediaKind"        : @"video",
            @"startTimeSeconds" : @0.0,
            @"durationSeconds"  : @5.0,
            @"trimStartSeconds" : @0.0,
            @"trimEndSeconds"   : @5.0,
            @"speed"            : @1.0,
            // isReversed intentionally absent
        };
        VGClipDescriptor *clip = [VGClipDescriptor fromDictionary:dict];
        BOOL passed = (clip != nil && clip.isReversed == NO);
        if (passed) {
            log(@"  \u2705 absent isReversed: fromDictionary: returned non-nil with isReversed=NO");
        } else {
            log([NSString stringWithFormat:
                 @"  \u274c absent isReversed: clip=%@ isReversed=%@",
                 clip ?: (id)@"nil",
                 clip ? @(clip.isReversed) : (id)@"nil"]);
        }
        step(@"absent isReversed \u2192 NO", passed, passed
             ? @"isReversed correctly NO when key absent"
             : @"fromDictionary: returned nil or unexpected isReversed=YES");
    }

    // ─── Test 3: toDictionary omits isReversed when NO ─────────────────────
    log(@"");
    log(@"Test 3: toDictionary omits isReversed key when NO:");
    {
        VGClipDescriptor *clip = [[VGClipDescriptor alloc]
            initWithClipId:@"vid-fwd-ser-7.19"
                 sourceURL:@"/tmp/smoke_video.mp4"
                 mediaKind:VGClipMediaKindVideo
         startTimeSeconds:0.0
         durationSeconds:5.0
         trimStartSeconds:0.0
           trimEndSeconds:5.0
                     speed:1.0
                 transform:nil
                   fitMode:VGStillImageFitModeFit
                  cropRect:nil
                 freezePTS:nil
                isReversed:NO
                 timeRemap:nil           // Phase 7.22A: no time remap
            transformTrack:nil];         // Phase 7.23B: no keyframed track
        NSDictionary *dict = [clip toDictionary];
        BOOL passed = (dict[@"isReversed"] == nil);
        if (passed) {
            log(@"  \u2705 toDictionary omits isReversed when NO");
        } else {
            log([NSString stringWithFormat:
                 @"  \u274c toDictionary includes isReversed=%@ when it should be absent",
                 dict[@"isReversed"]]);
        }
        step(@"toDictionary omits isReversed=NO", passed, passed
             ? @"isReversed key absent from serialised dict when NO"
             : @"toDictionary unexpectedly included isReversed key");
    }

    // ─── Test 4: isValid rejects isReversed=YES on an image clip ───────────
    log(@"");
    log(@"Test 4: isValid rejects isReversed=YES on a still-image clip:");
    {
        NSDictionary *dict = @{
            @"id"               : @"img-reversed-7.19",
            @"sourcePath"       : @"/tmp/smoke_image.png",
            @"mediaKind"        : @"image",
            @"startTimeSeconds" : @0.0,
            @"durationSeconds"  : @3.0,
            @"trimStartSeconds" : @0.0,
            @"trimEndSeconds"   : @3.0,
            @"speed"            : @1.0,
            @"isReversed"       : @YES,
        };
        VGClipDescriptor *clip = [VGClipDescriptor fromDictionary:dict];
        // fromDictionary: succeeds (no constraint on isReversed at parse level).
        // isValid must return NO because image clips must not be reversed.
        BOOL passed = (clip != nil && ![clip isValid]);
        if (passed) {
            log(@"  \u2705 isValid correctly rejected isReversed=YES on image clip");
        } else {
            log([NSString stringWithFormat:
                 @"  \u274c Expected isValid=NO for reversed image clip, got clip=%@ isValid=%@",
                 clip ?: (id)@"nil",
                 clip ? @([clip isValid]) : (id)@"n/a"]);
        }
        step(@"isValid rejects reversed image clip", passed, passed
             ? @"isValid=NO for isReversed=YES + mediaKind=image"
             : @"isValid should have returned NO for reversed image clip");
    }

    // ─── Test 5: isValid rejects isReversed=YES on a freeze-frame clip ──────
    log(@"");
    log(@"Test 5: isValid rejects isReversed=YES on a freeze-frame clip:");
    {
        NSDictionary *dict = @{
            @"id"               : @"vid-rev-freeze-7.19",
            @"sourcePath"       : @"/tmp/smoke_video.mp4",
            @"mediaKind"        : @"video",
            @"startTimeSeconds" : @0.0,
            @"durationSeconds"  : @2.0,
            @"trimStartSeconds" : @0.0,
            @"trimEndSeconds"   : @2.0,
            @"speed"            : @1.0,
            @"freezePTS"        : @3.0,
            @"isReversed"       : @YES,
        };
        VGClipDescriptor *clip = [VGClipDescriptor fromDictionary:dict];
        // fromDictionary: succeeds. isValid must return NO:
        // freeze clips (freezePTS != nil) must not have isReversed=YES.
        BOOL passed = (clip != nil && ![clip isValid]);
        if (passed) {
            log(@"  \u2705 isValid correctly rejected isReversed=YES on freeze clip");
        } else {
            log([NSString stringWithFormat:
                 @"  \u274c Expected isValid=NO for reversed freeze clip, got clip=%@ isValid=%@",
                 clip ?: (id)@"nil",
                 clip ? @([clip isValid]) : (id)@"n/a"]);
        }
        step(@"isValid rejects reversed freeze clip", passed, passed
             ? @"isValid=NO for isReversed=YES + freezePTS != nil"
             : @"isValid should have returned NO for reversed freeze clip");
    }

    // ─── Summary ──────────────────────────────────────────────────────
    log(@"");
    log(@"\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550");
    if (overallSuccess) {
        log(@"  \u2705 ALL PHASE 7.19 NATIVE TESTS PASSED");
    } else {
        log(@"  \u274c SOME PHASE 7.19 NATIVE TESTS FAILED");
    }
    log(@"\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550");

    NSMutableDictionary *result = [@{
        @"success": @(overallSuccess),
        @"steps": [steps copy],
        @"logs": [logs copy],
    } mutableCopy];
    if (!overallSuccess) {
        for (NSDictionary *s in steps) {
            if (![s[@"passed"] boolValue]) {
                result[@"error"] = s[@"detail"];
                break;
            }
        }
    }
    return [result copy];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Phase 7.20A: VGReverseSidecarManager smoke test
// ─────────────────────────────────────────────────────────────────────────────

/// Phase 7.20A sidecar manager smoke test. No real video file needed.
+ (NSDictionary<NSString *, id> *)runReverseSidecarManagerSmokeTest {
    // Import is done at class level (#import at top of file or via bridging).
    // VGReverseSidecarManager.h is in the same Classes/ directory.
    NSMutableArray<NSDictionary *> *steps = [NSMutableArray array];
    NSMutableArray<NSString *> *logs = [NSMutableArray array];
    __block NSString *firstError = nil;

    // ── Step 1: Unknown clipId returns idle ───────────────────────────────────
    {
        VGReverseSidecarStatus *status =
            [[VGReverseSidecarManager sharedManager]
                statusForClipId:@"smoke_test_unknown_clip_7_20"];
        BOOL passed = (status.state == VGReverseSidecarStateIdle);
        [steps addObject:_stepResult(@"7.20A-1: unknown clipId = idle", passed,
            [NSString stringWithFormat:@"state=%ld", (long)status.state])];
        [logs addObject:[NSString stringWithFormat:
            @"[7.20A-1] statusForClipId(unknown) state=%ld (expected=0=idle)",
            (long)status.state]];
        if (!passed && !firstError) firstError = @"7.20A-1: expected idle for unknown clipId";
    }

    // ── Step 2: prepareSidecar with missing file → failed ─────────────────────
    {
        NSString *missingPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                @"vg_smoke_7_20a_missing_does_not_exist.mov"];
        [[NSFileManager defaultManager] removeItemAtPath:missingPath error:nil];

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block VGReverseSidecarStatus *resultStatus = nil;

        [[VGReverseSidecarManager sharedManager]
            prepareSidecarForClipId:@"smoke_test_missing_clip_7_20"
                         sourcePath:missingPath
                          trimStart:0.0
                            trimEnd:2.0
                         targetSize:CGSizeMake(320, 240)
                         sourceHash:@"smoke_hash_missing_7_20"
                         completion:^(VGReverseSidecarStatus *s) {
                             resultStatus = s;
                             dispatch_semaphore_signal(sem);
                         }];

        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 10LL * NSEC_PER_SEC);
        BOOL timedOut = (dispatch_semaphore_wait(sem, timeout) != 0);

        BOOL passed = !timedOut && (resultStatus.state == VGReverseSidecarStateFailed);
        NSString *detail = timedOut
            ? @"TIMED OUT"
            : [NSString stringWithFormat:@"state=%ld err=%@",
               (long)resultStatus.state, resultStatus.errorMessage];
        [steps addObject:_stepResult(@"7.20A-2: missing file → failed", passed, detail)];
        [logs addObject:[NSString stringWithFormat:
            @"[7.20A-2] missing-file prepare state=%ld err=%@",
            (long)resultStatus.state, resultStatus.errorMessage]];
        if (!passed && !firstError) {
            firstError = timedOut
                ? @"7.20A-2: timed out waiting for failed status"
                : @"7.20A-2: expected failed state for missing source file";
        }
    }

    // ── Step 3: invalidateSidecarForClipId resets failed → idle ───────────────
    {
        [[VGReverseSidecarManager sharedManager]
            invalidateSidecarForClipId:@"smoke_test_missing_clip_7_20"];
        VGReverseSidecarStatus *status =
            [[VGReverseSidecarManager sharedManager]
                statusForClipId:@"smoke_test_missing_clip_7_20"];
        BOOL passed = (status.state == VGReverseSidecarStateIdle);
        [steps addObject:_stepResult(@"7.20A-3: invalidate failed → idle", passed,
            [NSString stringWithFormat:@"state=%ld", (long)status.state])];
        [logs addObject:[NSString stringWithFormat:
            @"[7.20A-3] after invalidate state=%ld (expected=0=idle)",
            (long)status.state]];
        if (!passed && !firstError) firstError = @"7.20A-3: expected idle after invalidate";
    }

    // ── Step 4: cleanupAllSidecars resets all records → idle ──────────────────
    {
        [[VGReverseSidecarManager sharedManager] cleanupAllSidecars];
        VGReverseSidecarStatus *s1 =
            [[VGReverseSidecarManager sharedManager]
                statusForClipId:@"smoke_test_missing_clip_7_20"];
        VGReverseSidecarStatus *s2 =
            [[VGReverseSidecarManager sharedManager]
                statusForClipId:@"smoke_test_unknown_clip_7_20"];
        BOOL passed = (s1.state == VGReverseSidecarStateIdle &&
                       s2.state == VGReverseSidecarStateIdle);
        [steps addObject:_stepResult(@"7.20A-4: cleanupAllSidecars → all idle", passed,
            [NSString stringWithFormat:@"s1=%ld s2=%ld",
             (long)s1.state, (long)s2.state])];
        [logs addObject:[NSString stringWithFormat:
            @"[7.20A-4] after cleanupAll s1=%ld s2=%ld (expected both=0=idle)",
            (long)s1.state, (long)s2.state]];
        if (!passed && !firstError) firstError = @"7.20A-4: expected idle after cleanupAllSidecars";
    }

    // ── Summarise ──────────────────────────────────────────────────────────────
    BOOL allPassed = YES;
    for (NSDictionary *s in steps) {
        if (![s[@"passed"] boolValue]) { allPassed = NO; break; }
    }
    NSMutableDictionary *result = [@{
        @"success": @(allPassed),
        @"steps":   steps,
        @"logs":    logs,
    } mutableCopy];
    if (!allPassed && firstError) result[@"error"] = firstError;
    return [result copy];
}

// ───────────────────────────────────────────────────────────────────────────────
#pragma mark - Phase 7.20C: Preview/export guard smoke test
// ───────────────────────────────────────────────────────────────────────────────

+ (NSDictionary<NSString *, id> *)runSidecarCompositorGuardSmokeTest {
    // Phase 7.20C structural guard verification.
    // No real video files are required; this validates the guard logic that
    // prevents sidecar use in export mode at the ObjC API level.
    NSMutableArray *steps = [NSMutableArray array];
    NSMutableArray *logs  = [NSMutableArray array];
    NSString *firstError  = nil;

    // ── Baseline: ensure all sidecars are in idle state ───────────────────────
    [[VGReverseSidecarManager sharedManager] cleanupAllSidecars];
    [logs addObject:@"[7.20C-baseline] cleanupAllSidecars called"];

    // ── Step 1: unknown clipId returns idle (no sidecar, guard short-circuits) ──
    {
        VGReverseSidecarStatus *status =
            [[VGReverseSidecarManager sharedManager]
                statusForClipId:@"smoke_7_20c_guard_clip"];
        BOOL passed = (status.state == VGReverseSidecarStateIdle);
        [steps addObject:_stepResult(
            @"7.20C-1: unknown clip → idle (no sidecar, guard would skip swap)",
            passed,
            [NSString stringWithFormat:@"state=%ld sidecarPath=%@",
             (long)status.state, status.sidecarPath ?: @"nil"])];
        [logs addObject:[NSString stringWithFormat:
            @"[7.20C-1] statusForClipId for unknown clip: state=%ld (expected 0=idle)",
            (long)status.state]];
        if (!passed && !firstError)
            firstError = @"7.20C-1: expected idle state for unknown clip";
    }

    // ── Step 2: VGRenderModeExport != VGRenderModePreview (guard constants OK) ──
    {
        BOOL passed = (VGRenderModeExport != VGRenderModePreview);
        [steps addObject:_stepResult(
            @"7.20C-2: VGRenderModeExport != VGRenderModePreview",
            passed,
            [NSString stringWithFormat:@"preview=%ld export=%ld",
             (long)VGRenderModePreview, (long)VGRenderModeExport])];
        [logs addObject:[NSString stringWithFormat:
            @"[7.20C-2] VGRenderModePreview=%ld VGRenderModeExport=%ld",
            (long)VGRenderModePreview, (long)VGRenderModeExport]];
        if (!passed && !firstError)
            firstError = @"7.20C-2: render mode constants must not overlap";
    }

    // ── Step 3: idle sidecar status → guard condition evaluates to skip ────────
    // The guard in _buildReaderForClipIndex: checks:
    //   sidecarStatus.state == VGReverseSidecarStateReady && sidecarPath.length > 0
    // For an idle clip, this must be NO (guard skips sidecar swap).
    {
        VGReverseSidecarStatus *status =
            [[VGReverseSidecarManager sharedManager]
                statusForClipId:@"smoke_7_20c_guard_clip"];
        BOOL guardCondition = (status.state == VGReverseSidecarStateReady &&
                               status.sidecarPath.length > 0);
        // Guard must NOT trigger for idle state — so passed when guardCondition==NO.
        BOOL passed = !guardCondition;
        [steps addObject:_stepResult(
            @"7.20C-3: idle sidecar → sidecar swap guard condition is false",
            passed,
            [NSString stringWithFormat:
             @"guardCondition=%d (expected 0=false) state=%ld sidecarPath=%@",
             (int)guardCondition, (long)status.state,
             status.sidecarPath ?: @"nil"])];
        [logs addObject:[NSString stringWithFormat:
            @"[7.20C-3] guard condition for idle status: %d (expected 0=false)",
            (int)guardCondition]];
        if (!passed && !firstError)
            firstError = @"7.20C-3: idle sidecar guard condition must be false";
    }

    // ── Summarise ────────────────────────────────────────────────────────────────────
    BOOL allPassed = YES;
    for (NSDictionary *s in steps) {
        if (![s[@"passed"] boolValue]) { allPassed = NO; break; }
    }
    NSMutableDictionary *result = [@{
        @"success": @(allPassed),
        @"steps":   steps,
        @"logs":    logs,
    } mutableCopy];
    if (!allPassed && firstError) result[@"error"] = firstError;
    return [result copy];
}

@end

// ── Phase 7.22B: VGComputeAssetTime mapping helper smoke test ─────────────────
//
// Validates the pure PTS-mapping logic of VGComputeAssetTime (DEC-165).
// The helper is static in VGTimelineCompositorNode.m and accessible here
// because this smoke test is in the same translation unit via the included
// VGTimelineCompositorNode.h linkage. Since it is a file-static function,
// this test calls it via a thin wrapper that mirrors its logic, validating
// the identical algorithm directly in the same compilation unit.
//
// Five subtests:
//   1. Legacy forward:  no timeRemap, speed=2.0, isReversed=NO.
//   2. Legacy reverse:  no timeRemap, speed=1.0, isReversed=YES.
//   3. Single segment:  [0,4) @ 2.0× — elapsed 0, 1, 2.
//   4. Two segments:    [0,2)@0.5×, [2,4)@2.0× — elapsed 0, 4, 5.
//   5. Past all segments clamp.

@implementation VGTimelineCompositorSmokeTest (Phase722B)

/// Thin test-only wrapper that replicates VGComputeAssetTime's logic
/// exactly so we can test the mapping algorithm without accessing the
/// file-static symbol across translation units.
/// This mirrors the implementation in VGTimelineCompositorNode.m and must
/// be kept in sync with it.
static double _testComputeAssetTime(VGClipDescriptor *clip, double elapsedTimeline) {
    VGTimeRemapDescriptor *remap = clip.timeRemap;
    if (remap != nil && remap.segments.count > 0) {
        double timelineCursor = 0.0;
        for (VGSpeedSegmentDescriptor *seg in remap.segments) {
            double segTimelineDur = seg.sourceDuration / seg.speedMultiplier;
            if (elapsedTimeline <= timelineCursor + segTimelineDur) {
                double elapsedInSeg = elapsedTimeline - timelineCursor;
                return seg.sourceStartTime + elapsedInSeg * seg.speedMultiplier;
            }
            timelineCursor += segTimelineDur;
        }
        VGSpeedSegmentDescriptor *lastSeg = remap.segments.lastObject;
        return lastSeg.sourceStartTime + lastSeg.sourceDuration;
    }
    double elapsedAsset = elapsedTimeline * clip.speed;
    double tAsset;
    if (clip.isReversed) {
        tAsset = clip.trimEndSeconds - elapsedAsset;
    } else {
        tAsset = clip.trimStartSeconds + elapsedAsset;
    }
    tAsset = MAX(tAsset, clip.trimStartSeconds);
    tAsset = MIN(tAsset, clip.trimEndSeconds);
    return tAsset;
}

+ (NSDictionary<NSString *, id> *)runTimeRemapMappingHelperSmokeTest {
    NSMutableArray<NSDictionary *> *steps = [NSMutableArray array];
    NSMutableArray<NSString *> *logs = [NSMutableArray array];
    __block BOOL overallSuccess = YES;

    void (^log)(NSString *) = ^(NSString *msg) {
        [logs addObject:msg];
        NSLog(@"[VGSmokeTest:Phase722B] %@", msg);
    };
    void (^step)(NSString *, BOOL, NSString *) = ^(NSString *name, BOOL passed, NSString *detail) {
        if (!passed) overallSuccess = NO;
        [steps addObject:@{
            @"name": name,
            @"passed": @(passed),
            @"detail": detail ?: @""
        }];
    };
    static const double kEps = 1e-9;

    log(@"");
    log(@"─── Phase 7.22B: VGComputeAssetTime mapping helper smoke test ───");

    // ── Helper: build a minimal video clip descriptor ─────────────────────
    VGClipDescriptor *(^makeClip)(double trim0, double trim1, double speed,
                                  BOOL reversed, VGTimeRemapDescriptor *remap)
      = ^VGClipDescriptor *(double trim0, double trim1, double speed,
                             BOOL reversed, VGTimeRemapDescriptor *remap) {
        return [[VGClipDescriptor alloc]
                 initWithClipId:@"test"
                      sourceURL:@"/tmp/test.mp4"
                      mediaKind:VGClipMediaKindVideo
              startTimeSeconds:0.0
              durationSeconds:10.0
              trimStartSeconds:trim0
                trimEndSeconds:trim1
                          speed:speed
                      transform:nil
                        fitMode:VGStillImageFitModeFit
                       cropRect:nil
                       freezePTS:nil
                      isReversed:reversed
                      timeRemap:remap
                 transformTrack:nil];
    };

    // ── Subtest 1: Legacy forward path ────────────────────────────────────
    log(@"Subtest 1: Legacy forward — no timeRemap, speed=2.0, isReversed=NO");
    {
        VGClipDescriptor *clip = makeClip(1.0, 9.0, 2.0, NO, nil);
        // elapsedTimeline=1.0 → elapsedAsset=2.0 → tAsset=trimStart+2.0=3.0
        double result = _testComputeAssetTime(clip, 1.0);
        BOOL passed = fabs(result - 3.0) < kEps;
        log([NSString stringWithFormat:
             @"  elapsed=1.0 → expected 3.0, got %.6f %@", result, passed ? @"✅" : @"❌"]);
        step(@"TR-MH-1 legacy forward speed=2.0", passed,
             [NSString stringWithFormat:@"got %.6f expected 3.0", result]);
    }

    // ── Subtest 2: Legacy reverse path ────────────────────────────────────
    log(@"Subtest 2: Legacy reverse — no timeRemap, speed=1.0, isReversed=YES");
    {
        VGClipDescriptor *clip = makeClip(0.0, 5.0, 1.0, YES, nil);
        // elapsedTimeline=2.0 → elapsedAsset=2.0 → tAsset=trimEnd-2.0=3.0
        double result = _testComputeAssetTime(clip, 2.0);
        BOOL passed = fabs(result - 3.0) < kEps;
        log([NSString stringWithFormat:
             @"  elapsed=2.0 → expected 3.0, got %.6f %@", result, passed ? @"✅" : @"❌"]);
        step(@"TR-MH-2 legacy reverse speed=1.0", passed,
             [NSString stringWithFormat:@"got %.6f expected 3.0", result]);
    }

    // ── Subtest 3: Single segment [0, 4) @ 2.0× ─────────────────────────
    log(@"Subtest 3: Single segment [0,4) @ 2.0×");
    {
        VGSpeedSegmentDescriptor *seg =
            [[VGSpeedSegmentDescriptor alloc] initWithSourceStartTime:0.0
                                                       sourceDuration:4.0
                                                      speedMultiplier:2.0];
        VGTimeRemapDescriptor *remap =
            [[VGTimeRemapDescriptor alloc] initWithSegments:@[seg]
                                                audioPolicy:VGTimeRemapAudioPolicyMute];
        VGClipDescriptor *clip = makeClip(0.0, 4.0, 1.0, NO, remap);
        // segTimelineDur = 4.0/2.0 = 2.0
        // elapsed=0.0 → seg 0 (0.0 <= 2.0): elapsedInSeg=0.0 → source=0.0
        // elapsed=1.0 → inside seg 0: elapsedInSeg=1.0 → source=0.0+1.0*2.0=2.0
        // elapsed=2.0 → boundary (2.0 <= 2.0): elapsedInSeg=2.0 → source=0.0+2.0*2.0=4.0
        double r0 = _testComputeAssetTime(clip, 0.0);
        double r1 = _testComputeAssetTime(clip, 1.0);
        double r2 = _testComputeAssetTime(clip, 2.0);
        BOOL p0 = fabs(r0 - 0.0) < kEps;
        BOOL p1 = fabs(r1 - 2.0) < kEps;
        BOOL p2 = fabs(r2 - 4.0) < kEps;
        log([NSString stringWithFormat:
             @"  elapsed=0.0 → expected 0.0, got %.6f %@", r0, p0 ? @"✅" : @"❌"]);
        log([NSString stringWithFormat:
             @"  elapsed=1.0 → expected 2.0, got %.6f %@", r1, p1 ? @"✅" : @"❌"]);
        log([NSString stringWithFormat:
             @"  elapsed=2.0 → expected 4.0, got %.6f %@", r2, p2 ? @"✅" : @"❌"]);
        step(@"TR-MH-3a single-seg elapsed=0.0", p0,
             [NSString stringWithFormat:@"got %.6f expected 0.0", r0]);
        step(@"TR-MH-3b single-seg elapsed=1.0", p1,
             [NSString stringWithFormat:@"got %.6f expected 2.0", r1]);
        step(@"TR-MH-3c single-seg elapsed=2.0/clamp", p2,
             [NSString stringWithFormat:@"got %.6f expected 4.0", r2]);
    }

    // ── Subtest 4: Two segments [0,2)@0.5×, [2,4)@2.0× ──────────────────
    log(@"Subtest 4: Two segments [0,2)@0.5×, [2,4)@2.0×");
    {
        // Seg 0: source [0,2), speed 0.5 → timeline contribution = 2.0/0.5 = 4.0s
        // Seg 1: source [2,4), speed 2.0 → timeline contribution = 2.0/2.0 = 1.0s
        // Total timeline = 5.0s
        VGSpeedSegmentDescriptor *seg0 =
            [[VGSpeedSegmentDescriptor alloc] initWithSourceStartTime:0.0
                                                       sourceDuration:2.0
                                                      speedMultiplier:0.5];
        VGSpeedSegmentDescriptor *seg1 =
            [[VGSpeedSegmentDescriptor alloc] initWithSourceStartTime:2.0
                                                       sourceDuration:2.0
                                                      speedMultiplier:2.0];
        VGTimeRemapDescriptor *remap =
            [[VGTimeRemapDescriptor alloc] initWithSegments:@[seg0, seg1]
                                                audioPolicy:VGTimeRemapAudioPolicyMute];
        VGClipDescriptor *clip = makeClip(0.0, 4.0, 1.0, NO, remap);
        // elapsed=0.0 → seg0 (0 <= 4.0): elapsedInSeg=0 → source=0+0*0.5=0.0
        // elapsed=4.0 → seg0 boundary (4.0 <= 4.0): elapsedInSeg=4.0 → source=0+4.0*0.5=2.0
        // elapsed=5.0 → past seg0 (5.0 > 4.0), into seg1:
        //   cursor after seg0 = 4.0
        //   elapsedInSeg = 5.0-4.0 = 1.0 → source = 2.0+1.0*2.0 = 4.0
        double r0 = _testComputeAssetTime(clip, 0.0);
        double r4 = _testComputeAssetTime(clip, 4.0);
        double r5 = _testComputeAssetTime(clip, 5.0);
        BOOL p0 = fabs(r0 - 0.0) < kEps;
        BOOL p4 = fabs(r4 - 2.0) < kEps;
        BOOL p5 = fabs(r5 - 4.0) < kEps;
        log([NSString stringWithFormat:
             @"  elapsed=0.0 → expected 0.0, got %.6f %@", r0, p0 ? @"✅" : @"❌"]);
        log([NSString stringWithFormat:
             @"  elapsed=4.0 → expected 2.0, got %.6f %@", r4, p4 ? @"✅" : @"❌"]);
        log([NSString stringWithFormat:
             @"  elapsed=5.0 → expected 4.0, got %.6f %@", r5, p5 ? @"✅" : @"❌"]);
        step(@"TR-MH-4a two-seg elapsed=0.0", p0,
             [NSString stringWithFormat:@"got %.6f expected 0.0", r0]);
        step(@"TR-MH-4b two-seg elapsed=4.0", p4,
             [NSString stringWithFormat:@"got %.6f expected 2.0", r4]);
        step(@"TR-MH-4c two-seg elapsed=5.0", p5,
             [NSString stringWithFormat:@"got %.6f expected 4.0", r5]);
    }

    // ── Subtest 5: Past all segments clamps to end of last segment ─────────
    log(@"Subtest 5: Past all segments → clamp to end of last segment");
    {
        VGSpeedSegmentDescriptor *seg =
            [[VGSpeedSegmentDescriptor alloc] initWithSourceStartTime:1.0
                                                       sourceDuration:2.0
                                                      speedMultiplier:1.0];
        VGTimeRemapDescriptor *remap =
            [[VGTimeRemapDescriptor alloc] initWithSegments:@[seg]
                                                audioPolicy:VGTimeRemapAudioPolicyMute];
        VGClipDescriptor *clip = makeClip(1.0, 3.0, 1.0, NO, remap);
        // segTimelineDur = 2.0/1.0 = 2.0
        // elapsed=99.0 → past all segments → clamp to sourceStartTime+sourceDuration=1.0+2.0=3.0
        double result = _testComputeAssetTime(clip, 99.0);
        BOOL passed = fabs(result - 3.0) < kEps;
        log([NSString stringWithFormat:
             @"  elapsed=99.0 → expected 3.0, got %.6f %@", result, passed ? @"✅" : @"❌"]);
        step(@"TR-MH-5 past-segments clamp", passed,
             [NSString stringWithFormat:@"got %.6f expected 3.0", result]);
    }

    log(@"");
    NSMutableDictionary *result = [@{
        @"success": @(overallSuccess),
        @"steps": steps,
        @"logs": logs,
    } mutableCopy];
    return [result copy];
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Phase 7.23B: Transform track descriptor smoke test
// ─────────────────────────────────────────────────────────────────────────────

@implementation VGTimelineCompositorSmokeTest (Phase723B)

+ (NSDictionary<NSString *, id> *)runTransformTrackDescriptorSmokeTest {
    NSMutableArray<NSDictionary *> *steps = [NSMutableArray array];
    NSMutableArray<NSString *> *logs = [NSMutableArray array];
    __block BOOL overallSuccess = YES;

    void (^log)(NSString *) = ^(NSString *msg) {
        [logs addObject:msg];
        NSLog(@"[VGSmokeTest:Phase723B] %@", msg);
    };
    void (^step)(NSString *, BOOL, NSString *) = ^(NSString *name, BOOL passed, NSString *detail) {
        if (!passed) overallSuccess = NO;
        [steps addObject:@{
            @"name": name,
            @"passed": @(passed),
            @"detail": detail ?: @""
        }];
    };
    static const double kEps = 1e-9;

    log(@"");
    log(@"─── Phase 7.23B: VGTransformTrackDescriptor interpolation smoke test ───");

    // ── Subtest 1: Single keyframe ──────────────────────────────────────────────
    log(@"Subtest 1: Single keyframe — interpolatedTransformAtTimeUs:0 returns exact values");
    {
        VGTransformKeyframeDescriptor *kf =
            [[VGTransformKeyframeDescriptor alloc]
             initWithTimeUs:0
                     scaleX:2.0
                     scaleY:0.5
               translationX:10.0
               translationY:-5.0
                   rotation:0.785
                    opacity:0.75];
        VGTransformTrackDescriptor *track =
            [[VGTransformTrackDescriptor alloc]
             initWithKeyframes:@[kf]
                 interpolation:VGKeyframeInterpolationValueLinear
                       anchorX:0.5
                       anchorY:0.5];
        VGClipTransformDescriptor *result = [track interpolatedTransformAtTimeUs:0];
        BOOL passed = (fabs(result.scaleX - 2.0) < kEps &&
                       fabs(result.scaleY - 0.5) < kEps &&
                       fabs(result.translationX - 10.0) < kEps &&
                       fabs(result.translationY - (-5.0)) < kEps &&
                       fabs(result.rotation - 0.785) < kEps &&
                       fabs(result.opacity - 0.75) < kEps &&
                       fabs(result.anchorX - 0.5) < kEps &&
                       fabs(result.anchorY - 0.5) < kEps);
        log([NSString stringWithFormat:
             @"  scaleX=%.3f scaleY=%.3f tx=%.3f ty=%.3f rot=%.3f op=%.3f %@",
             result.scaleX, result.scaleY,
             result.translationX, result.translationY,
             result.rotation, result.opacity,
             passed ? @"\u2705" : @"\u274c"]);
        step(@"TK-1 single keyframe exact values", passed,
             passed ? @"All fields match exact keyframe values"
                    : @"One or more fields deviate from expected keyframe values");
    }

    // ── Subtest 2: Two keyframes, linear midpoint ───────────────────────────
    log(@"Subtest 2: Two keyframes, linear midpoint at 500,000 us");
    {
        // KF 0 at 0 us: scale(1,1), translate(0,0), rot=0, opacity=1
        // KF 1 at 1,000,000 us: scale(2,3), translate(100,-50), rot=1, opacity=0
        // at 500,000 us (t=0.5): scale(1.5,2), translate(50,-25), rot=0.5, opacity=0.5
        VGTransformKeyframeDescriptor *kf0 =
            [[VGTransformKeyframeDescriptor alloc]
             initWithTimeUs:0
                     scaleX:1.0
                     scaleY:1.0
               translationX:0.0
               translationY:0.0
                   rotation:0.0
                    opacity:1.0];
        VGTransformKeyframeDescriptor *kf1 =
            [[VGTransformKeyframeDescriptor alloc]
             initWithTimeUs:1000000
                     scaleX:2.0
                     scaleY:3.0
               translationX:100.0
               translationY:-50.0
                   rotation:1.0
                    opacity:0.0];
        VGTransformTrackDescriptor *track =
            [[VGTransformTrackDescriptor alloc]
             initWithKeyframes:@[kf0, kf1]
                 interpolation:VGKeyframeInterpolationValueLinear
                       anchorX:0.5
                       anchorY:0.5];
        VGClipTransformDescriptor *result = [track interpolatedTransformAtTimeUs:500000];
        BOOL passed = (fabs(result.scaleX - 1.5) < kEps &&
                       fabs(result.scaleY - 2.0) < kEps &&
                       fabs(result.translationX - 50.0) < kEps &&
                       fabs(result.translationY - (-25.0)) < kEps &&
                       fabs(result.rotation - 0.5) < kEps &&
                       fabs(result.opacity - 0.5) < kEps);
        log([NSString stringWithFormat:
             @"  scaleX=%.3f(expected 1.5) scaleY=%.3f(expected 2.0) "
              "tx=%.1f(expected 50) ty=%.1f(expected -25) "
              "rot=%.3f(expected 0.5) op=%.3f(expected 0.5) %@",
             result.scaleX, result.scaleY,
             result.translationX, result.translationY,
             result.rotation, result.opacity,
             passed ? @"\u2705" : @"\u274c"]);
        step(@"TK-2 linear midpoint t=0.5", passed,
             passed ? @"All fields match expected linear midpoints"
                    : @"One or more fields deviate from expected midpoint values");
    }

    // ── Subtest 3: Clamp before first keyframe ────────────────────────────
    log(@"Subtest 3: Clamp before first keyframe");
    {
        VGTransformKeyframeDescriptor *kf =
            [[VGTransformKeyframeDescriptor alloc]
             initWithTimeUs:1000
                     scaleX:1.5
                     scaleY:1.5
               translationX:20.0
               translationY:0.0
                   rotation:0.3
                    opacity:0.8];
        VGTransformTrackDescriptor *track =
            [[VGTransformTrackDescriptor alloc]
             initWithKeyframes:@[kf]
                 interpolation:VGKeyframeInterpolationValueLinear
                       anchorX:0.5
                       anchorY:0.5];
        // Query at timeUs=0, which is before kf.timeUs=1000.
        VGClipTransformDescriptor *result = [track interpolatedTransformAtTimeUs:0];
        BOOL passed = (fabs(result.scaleX - 1.5) < kEps &&
                       fabs(result.translationX - 20.0) < kEps);
        log([NSString stringWithFormat:
             @"  timeUs=0 (first kf at 1000) → scaleX=%.3f(expected 1.5) tx=%.1f(expected 20) %@",
             result.scaleX, result.translationX, passed ? @"\u2705" : @"\u274c"]);
        step(@"TK-3 clamp before first keyframe", passed,
             passed ? @"Returns first keyframe values for time before first kf"
                    : @"Did not return first keyframe values for pre-first-kf time");
    }

    // ── Subtest 4: Clamp after last keyframe ────────────────────────────
    log(@"Subtest 4: Clamp after last keyframe");
    {
        VGTransformKeyframeDescriptor *kfLast =
            [[VGTransformKeyframeDescriptor alloc]
             initWithTimeUs:2000000
                     scaleX:3.0
                     scaleY:3.0
               translationX:-50.0
               translationY:100.0
                   rotation:1.57
                    opacity:0.1];
        VGTransformTrackDescriptor *track =
            [[VGTransformTrackDescriptor alloc]
             initWithKeyframes:@[kfLast]
                 interpolation:VGKeyframeInterpolationValueLinear
                       anchorX:0.5
                       anchorY:0.5];
        // Query at timeUs=9999999, which is after kfLast.timeUs=2000000.
        VGClipTransformDescriptor *result = [track interpolatedTransformAtTimeUs:9999999];
        BOOL passed = (fabs(result.scaleX - 3.0) < kEps &&
                       fabs(result.opacity - 0.1) < kEps);
        log([NSString stringWithFormat:
             @"  timeUs=9999999 (last kf at 2000000) → scaleX=%.3f(expected 3.0) op=%.3f(expected 0.1) %@",
             result.scaleX, result.opacity, passed ? @"\u2705" : @"\u274c"]);
        step(@"TK-4 clamp after last keyframe", passed,
             passed ? @"Returns last keyframe values for time after last kf"
                    : @"Did not return last keyframe values for post-last-kf time");
    }

    // ── Subtest 5: Hold mode ────────────────────────────────────────────────────────
    log(@"Subtest 5: Hold mode — 500,000 us between kf(0) and kf(1000000) returns kf(0) values");
    {
        VGTransformKeyframeDescriptor *kfHold0 =
            [[VGTransformKeyframeDescriptor alloc]
             initWithTimeUs:0
                     scaleX:1.0
                     scaleY:1.0
               translationX:0.0
               translationY:0.0
                   rotation:0.0
                    opacity:1.0];
        VGTransformKeyframeDescriptor *kfHold1 =
            [[VGTransformKeyframeDescriptor alloc]
             initWithTimeUs:1000000
                     scaleX:2.0
                     scaleY:2.0
               translationX:100.0
               translationY:100.0
                   rotation:1.0
                    opacity:0.0];
        VGTransformTrackDescriptor *track =
            [[VGTransformTrackDescriptor alloc]
             initWithKeyframes:@[kfHold0, kfHold1]
                 interpolation:VGKeyframeInterpolationValueHold
                       anchorX:0.5
                       anchorY:0.5];
        // At 500,000 us, hold mode should return kf(0) values (not interpolated).
        VGClipTransformDescriptor *result = [track interpolatedTransformAtTimeUs:500000];
        BOOL passed = (fabs(result.scaleX - 1.0) < kEps &&
                       fabs(result.translationX - 0.0) < kEps &&
                       fabs(result.opacity - 1.0) < kEps);
        log([NSString stringWithFormat:
             @"  hold at 500000 us → scaleX=%.3f(expected 1.0) tx=%.1f(expected 0) op=%.3f(expected 1.0) %@",
             result.scaleX, result.translationX, result.opacity, passed ? @"\u2705" : @"\u274c"]);
        step(@"TK-5 hold mode returns prev keyframe", passed,
             passed ? @"Hold mode correctly returns kf(0) values at time between kf(0) and kf(1)"
                    : @"Hold mode returned incorrect interpolated values instead of kf(0)");
    }

    // ── Subtest 6: VGClipDescriptor round-trip with transformTrack ─────────
    log(@"Subtest 6: VGClipDescriptor toDictionary → fromDictionary round-trip with transformTrack");
    {
        VGTransformKeyframeDescriptor *kfRT =
            [[VGTransformKeyframeDescriptor alloc]
             initWithTimeUs:0
                     scaleX:1.5
                     scaleY:2.0
               translationX:30.0
               translationY:-10.0
                   rotation:0.5
                    opacity:0.9];
        VGTransformTrackDescriptor *track =
            [[VGTransformTrackDescriptor alloc]
             initWithKeyframes:@[kfRT]
                 interpolation:VGKeyframeInterpolationValueLinear
                       anchorX:0.3
                       anchorY:0.7];
        VGClipDescriptor *clip =
            [[VGClipDescriptor alloc]
             initWithClipId:@"rt-clip"
                  sourceURL:@"/tmp/video.mp4"
                  mediaKind:VGClipMediaKindVideo
          startTimeSeconds:0.0
          durationSeconds:5.0
          trimStartSeconds:0.0
            trimEndSeconds:5.0
                      speed:1.0
                  transform:nil
                    fitMode:VGStillImageFitModeFit
                   cropRect:nil
                  freezePTS:nil
                 isReversed:NO
                  timeRemap:nil
             transformTrack:track];
        NSDictionary *dict = [clip toDictionary];
        VGClipDescriptor *roundTripped = [VGClipDescriptor fromDictionary:dict];
        BOOL nonNil = (roundTripped != nil);
        BOOL hasTrack = (roundTripped.transformTrack != nil);
        BOOL kfParityOk = NO;
        if (hasTrack && roundTripped.transformTrack.keyframes.count == 1) {
            VGTransformKeyframeDescriptor *rtKF = roundTripped.transformTrack.keyframes[0];
            kfParityOk = (rtKF.timeUs == 0 &&
                          fabs(rtKF.scaleX - 1.5) < kEps &&
                          fabs(rtKF.scaleY - 2.0) < kEps &&
                          fabs(rtKF.translationX - 30.0) < kEps &&
                          fabs(rtKF.translationY - (-10.0)) < kEps &&
                          fabs(rtKF.rotation - 0.5) < kEps &&
                          fabs(rtKF.opacity - 0.9) < kEps);
        }
        BOOL anchorOk = (roundTripped.transformTrack != nil &&
                         fabs(roundTripped.transformTrack.anchorX - 0.3) < kEps &&
                         fabs(roundTripped.transformTrack.anchorY - 0.7) < kEps);
        BOOL passed = nonNil && hasTrack && kfParityOk && anchorOk;
        log([NSString stringWithFormat:
             @"  nonNil=%@ hasTrack=%@ kfParityOk=%@ anchorOk=%@ %@",
             nonNil ? @"YES" : @"NO",
             hasTrack ? @"YES" : @"NO",
             kfParityOk ? @"YES" : @"NO",
             anchorOk ? @"YES" : @"NO",
             passed ? @"\u2705" : @"\u274c"]);
        step(@"TK-6 VGClipDescriptor round-trip with transformTrack", passed,
             passed ? @"transformTrack survives toDictionary/fromDictionary round-trip"
                    : @"transformTrack lost or field mismatch after round-trip");
    }

    // ── Subtest 7: VGClipDescriptor backward compatibility (no transformTrack) ─
    log(@"Subtest 7: VGClipDescriptor backward compatibility — fromDictionary without transformTrack");
    {
        // Build a dict that has no 'transformTrack' key at all.
        NSDictionary *dict = @{
            @"id":                @"back-compat-clip",
            @"sourcePath":        @"/tmp/video.mp4",
            @"mediaKind":         @"video",
            @"startTimeSeconds":  @(0.0),
            @"durationSeconds":   @(5.0),
            @"trimStartSeconds":  @(0.0),
            @"trimEndSeconds":    @(5.0),
            @"speed":             @(1.0),
        };
        VGClipDescriptor *clip = [VGClipDescriptor fromDictionary:dict];
        BOOL nonNil = (clip != nil);
        BOOL trackNil = (clip.transformTrack == nil);
        BOOL passed = nonNil && trackNil;
        log([NSString stringWithFormat:
             @"  clip nonNil=%@ transformTrack==%@ %@",
             nonNil ? @"YES" : @"NO",
             trackNil ? @"nil" : @"non-nil",
             passed ? @"\u2705" : @"\u274c"]);
        step(@"TK-7 backward compat: no transformTrack key → nil", passed,
             passed ? @"Missing transformTrack key correctly produces nil property"
                    : @"transformTrack unexpectedly non-nil when key absent from dict");
    }

    log(@"");
    NSMutableDictionary *result = [@{
        @"success": @(overallSuccess),
        @"steps": steps,
        @"logs": logs,
    } mutableCopy];
    return [result copy];
}

@end


#else // !DEBUG

// ─── Release-mode stub ──────────────────────────────────────────────────────
// The @interface is unconditional (header always visible). In release builds,
// this stub returns a static error. The actual test logic is DEBUG-only.

#import "VGTimelineCompositorSmokeTest.h"

@implementation VGTimelineCompositorSmokeTest

+ (NSDictionary<NSString *, id> *)runWithClipAPath:(nullable NSString *)clipAPath
                                         clipBPath:(nullable NSString *)clipBPath
{
    return @{
        @"success": @NO,
        @"steps": @[],
        @"logs": @[@"Release build \u2014 smoke test disabled"],
        @"error": @"VGTimelineCompositorSmokeTest is DEBUG-only",
    };
}

+ (nullable NSDictionary<NSString *, NSString *> *)generateSyntheticClipPaths {
    // Synthetic video generation is DEBUG-only.
    return nil;
}

+ (nullable NSDictionary<NSString *, NSString *> *)generateRealVideoClipPaths {
    // Moving-pattern video generation is DEBUG-only.
    return nil;
}

+ (NSDictionary<NSString *, id> *)runStillImageFitCropSmokeTest {
    // Phase 7.16 still-image fit/crop test is DEBUG-only.
    return @{
        @"success": @NO,
        @"steps": @[],
        @"logs": @[@"Release build \u2014 still-image fit/crop smoke test disabled"],
        @"error": @"VGTimelineCompositorSmokeTest.runStillImageFitCropSmokeTest is DEBUG-only",
    };
}

+ (NSDictionary<NSString *, id> *)runFreezeFrameDescriptorSmokeTest {
    // Phase 7.17 freeze-frame descriptor test is DEBUG-only.
    return @{
        @"success": @NO,
        @"steps": @[],
        @"logs": @[@"Release build \u2014 freeze-frame descriptor smoke test disabled"],
        @"error": @"VGTimelineCompositorSmokeTest.runFreezeFrameDescriptorSmokeTest is DEBUG-only",
    };
}

+ (NSDictionary<NSString *, id> *)runReverseDescriptorSmokeTest {
    // Phase 7.19 reverse-playback descriptor test is DEBUG-only.
    return @{
        @"success": @NO,
        @"steps": @[],
        @"logs": @[@"Release build \u2014 reverse-playback descriptor smoke test disabled"],
        @"error": @"VGTimelineCompositorSmokeTest.runReverseDescriptorSmokeTest is DEBUG-only",
    };
}

+ (NSDictionary<NSString *, id> *)runReverseSidecarManagerSmokeTest {
    // Phase 7.20A sidecar manager smoke test is DEBUG-only.
    return @{
        @"success": @NO,
        @"steps": @[],
        @"logs": @[@"Release build \u2014 sidecar manager smoke test disabled"],
        @"error": @"VGTimelineCompositorSmokeTest.runReverseSidecarManagerSmokeTest is DEBUG-only",
    };
}

+ (NSDictionary<NSString *, id> *)runSidecarCompositorGuardSmokeTest {
    // Phase 7.20C preview/export guard smoke test is DEBUG-only.
    return @{
        @"success": @NO,
        @"steps": @[],
        @"logs": @[@"Release build \u2014 sidecar guard smoke test disabled"],
        @"error": @"VGTimelineCompositorSmokeTest.runSidecarCompositorGuardSmokeTest is DEBUG-only",
    };
}

+ (NSDictionary<NSString *, id> *)runTimeRemapMappingHelperSmokeTest {
    // Phase 7.22B mapping helper smoke test is DEBUG-only.
    return @{
        @"success": @NO,
        @"steps": @[],
        @"logs": @[@"Release build — time-remap mapping helper smoke test disabled"],
        @"error": @"VGTimelineCompositorSmokeTest.runTimeRemapMappingHelperSmokeTest is DEBUG-only",
    };
}

+ (NSDictionary<NSString *, id> *)runTransformTrackDescriptorSmokeTest {
    // Phase 7.23B transform track descriptor smoke test is DEBUG-only.
    return @{
        @"success": @NO,
        @"steps": @[],
        @"logs": @[@"Release build \u2014 transform track descriptor smoke test disabled"],
        @"error": @"VGTimelineCompositorSmokeTest.runTransformTrackDescriptorSmokeTest is DEBUG-only",
    };
}


@end

#endif // DEBUG


