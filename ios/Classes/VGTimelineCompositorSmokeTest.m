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
                                        isReversed:NO];

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
                                        isReversed:NO];

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
                isReversed:NO];
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

@end

#endif // DEBUG


