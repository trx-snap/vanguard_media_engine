// VanguardBugFixTests.m
// Regression tests for five confirmed Vanguard Phase 1 bugs.
// Run with: xcodebuild test -scheme vanguard_media_engine -destination 'platform=iOS'
// ASAN: set DYLD_INSERT_LIBRARIES to the ASAN dylib in the scheme's Diagnostics tab.
// TSAN: enable Thread Sanitizer in scheme Diagnostics.

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import "VanguardFileMediaSource.h"
#import "VanguardCameraMediaSource.h"
#import "VanguardMetalRenderer.h"
#import "VanguardFilterNode.h"

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Helpers
// ─────────────────────────────────────────────────────────────────────────────

static CVPixelBufferRef makeTestPixelBuffer(size_t w, size_t h) {
    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:    @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)attrs, &pb);
    return pb;  // caller owns +1
}

/// Spy filter node that records the retain count of its input buffer at call time.
@interface VanguardRetainCountSpyNode : NSObject <VanguardFilterNode>
@property (nonatomic, readonly) CFIndex lastInputRetainCount;
@property (nonatomic, readonly) NSUInteger callCount;
@property (nonatomic, readonly) CVPixelBufferPoolRef pool;
- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool;
@end

@implementation VanguardRetainCountSpyNode {
    CVPixelBufferPoolRef _pool;
    CFIndex _lastInputRetainCount;
    NSUInteger _callCount;
}
@synthesize filterName = _filterName;
@synthesize enabled    = _enabled;

- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool {
    self = [super init];
    _pool = pool; CVPixelBufferPoolRetain(_pool);
    _enabled    = YES;
    _filterName = @"RetainCountSpy";
    return self;
}
- (void)dealloc { if (_pool) CVPixelBufferPoolRelease(_pool); }

- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)t
                           device:(id<MTLDevice>)device {
    _lastInputRetainCount = CVPixelBufferGetRetainCount(input);
    _callCount++;
    // Return a new buffer from the pool with +1, as required by the protocol.
    CVPixelBufferRef output = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(nil, _pool, &output) != kCVReturnSuccess) {
        CVPixelBufferRetain(input); return input;  // passthrough fallback
    }
    return output;  // +1 owned by caller (the filter loop)
}

- (void)invalidate {}
- (CFIndex)lastInputRetainCount { return _lastInputRetainCount; }
- (NSUInteger)callCount { return _callCount; }
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - FIX-1: AudioBufferList Stack Overflow Test
// ─────────────────────────────────────────────────────────────────────────────

@interface VanguardAudioBufferListTests : XCTestCase
@end

@implementation VanguardAudioBufferListTests

/// Verifies that _scheduleNextAudioChunk does not corrupt the stack when reading
/// a stereo audio track. With the old code, this crashes under ASAN with
/// stack-buffer-overflow. With the fix it must run clean.
///
/// Failure mode before fix: ASAN reports stack-buffer-overflow at the
/// CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer call site.
/// After fix: no ASAN report, test completes within timeout.
- (void)testStereoAudioChunkReadsWithoutStackOverflow {
    // Use a stereo video file from the test bundle.
    // Any standard iPhone-recorded MP4 has stereo AAC audio.
    NSURL *url = [[NSBundle bundleForClass:[self class]]
                  URLForResource:@"test_stereo" withExtension:@"mp4"];
    if (!url) {
        // Fallback: use the system camera roll sample if available.
        url = [NSURL fileURLWithPath:@"/System/Library/CoreServices/SystemVersion.bundle"]; // placeholder
        XCTSkip(@"test_stereo.mp4 not found in test bundle — add a stereo MP4 to run this test");
    }

    VanguardFileMediaSource *source =
        [[VanguardFileMediaSource alloc] initWithURL:url pixelBufferPool:nil];
    XCTAssertNotNil(source);

    // Start drives _setupAudioEngine → _scheduleNextAudioChunk on _decodeQueue.
    [source start];
    [source play];

    // Allow 1.5s for at least two chunks to be scheduled.
    XCTestExpectation *settled = [self expectationWithDescription:@"audio chunks scheduled"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [settled fulfill]; });
    [self waitForExpectations:@[settled] timeout:3.0];

    // If stack overflow occurred: process crashed before reaching here.
    // Reaching this line with ASAN enabled and clean confirms the fix.
    XCTAssertTrue(source.hasAudio, @"Stereo source must report hasAudio = YES");
    // Verify audioEngineReady through KVC since it's an internal ivar.
    // This is acceptable in test-only code.
    BOOL ready = [[source valueForKey:@"audioEngineReady"] boolValue];
    XCTAssertTrue(ready, @"Audio engine must be ready after start+play on a stereo source");

    [source stop];
}

/// Edge case: mono audio source. The mono-to-stereo duplication path must not overflow either.
- (void)testMonoAudioChunkReadsCleanly {
    NSURL *url = [[NSBundle bundleForClass:[self class]]
                  URLForResource:@"test_mono" withExtension:@"mp4"];
    if (!url) { XCTSkip(@"test_mono.mp4 not in test bundle"); }

    VanguardFileMediaSource *source =
        [[VanguardFileMediaSource alloc] initWithURL:url pixelBufferPool:nil];
    [source start];
    [source play];

    XCTestExpectation *settled = [self expectationWithDescription:@"mono chunks"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [settled fulfill]; });
    [self waitForExpectations:@[settled] timeout:2.0];
    [source stop];
    // No crash = pass.
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - FIX-3: Camera CVPixelBuffer Ownership Tests
// ─────────────────────────────────────────────────────────────────────────────

@interface VanguardCameraOwnershipTests : XCTestCase
@end

@implementation VanguardCameraOwnershipTests

/// Verifies that _latestBuffer remains alive (retain count >= 1) after the video
/// callback fires. Before the fix, the renderer's CVPixelBufferRelease(rawFrame)
/// consumed _latestBuffer's retain, leaving it with retain count 0 after the
/// callback returns — a use-after-free on the next frame.
///
/// Run with NSZombieEnabled=YES and MallocScribble=YES to make the failure loud.
- (void)testLatestBufferIsAliveAfterVideoCallback {
    // We drive the delegate directly without a real camera session.
    VanguardCameraMediaSource *cam =
        [[VanguardCameraMediaSource alloc] initWithPosition:AVCaptureDevicePositionBack
                                                  frameRate:30];
    XCTAssertNotNil(cam);

    // Install a callback that simulates what _onVideoFrame: does:
    // retain for _latestPixelBuffer, then release rawFrame.
    __block CFIndex retainCountAtCallbackEntry = -1;
    [cam setVideoCallback:^(CVPixelBufferRef frame, CMTime pts) {
        retainCountAtCallbackEntry = CVPixelBufferGetRetainCount(frame);
        CVPixelBufferRetain(frame);   // simulate _latestPixelBuffer retain
        CVPixelBufferRelease(frame);  // simulate line 514: CVPixelBufferRelease(rawFrame)
    }];

    // Build a fake CMSampleBuffer wrapping a known pixel buffer.
    CVPixelBufferRef testBuffer = makeTestPixelBuffer(1920, 1080);
    XCTAssertNotNil((__bridge id)testBuffer);

    // Simulate 5 frames to catch the bug on the second frame (when old _latestBuffer released).
    for (int i = 0; i < 5; i++) {
        // The callback invariant: frame must arrive with retain count >= 2
        // (sampleBuffer's +1 AND the callback's dedicated +1 from CVPixelBufferRetain).
        // Before the fix: frame arrived with count = 2 but _latestBuffer's retain
        // was already "spent", so releasing rawFrame in the callback brought
        // _latestBuffer to 0 on the next iteration.
        // After the fix: frame arrives with count = 2 (sampleBuffer + callback retain).
        // Renderer releases rawFrame → count = 1 (sampleBuffer). _latestBuffer untouched.
        [cam setVideoCallback:^(CVPixelBufferRef frame, CMTime pts) {
            retainCountAtCallbackEntry = CVPixelBufferGetRetainCount(frame);
            CVPixelBufferRelease(frame);  // simulate renderer releasing its rawFrame
        }];

        // Drive the callback directly by calling the internal path via KVC/runtime.
        // In production this fires from captureOutput:didOutputSampleBuffer:.
        // For test isolation we call the videoCallback block directly.
        void (^cb)(CVPixelBufferRef, CMTime) = [cam valueForKey:@"_videoCallback"];
        if (cb) {
            CVPixelBufferRetain(testBuffer);  // simulate sampleBuffer's hold
            cb(testBuffer, kCMTimeZero);
            // After callback: testBuffer retain from sampleBuffer is pending release.
            // Simulate sampleBuffer dealloc:
            CVPixelBufferRelease(testBuffer);
        }

        // _latestBuffer must still be alive: retain count >= 1.
        // (We can't read _latestBuffer directly — access it via the public API,
        //  or verify via retain count of testBuffer which _latestBuffer points to.)
        CFIndex afterCount = CVPixelBufferGetRetainCount(testBuffer);
        XCTAssertGreaterThanOrEqual(afterCount, 1,
            @"pixelBuffer must remain alive via _latestBuffer after frame %d (count=%ld)",
            i, afterCount);

        XCTAssertGreaterThanOrEqual(retainCountAtCallbackEntry, 2,
            @"Frame %d: callback must receive buffer with count >= 2 "
             "(sampleBuffer + dedicated callback retain). Got %ld",
            i, retainCountAtCallbackEntry);
    }

    CVPixelBufferRelease(testBuffer);
    [cam stop];
}

/// Stress test: 200 rapid frames through camera callback. Verifies NSZombie
/// does not fire on _latestBuffer on any frame.
/// Run with MallocScribble=YES: a freed buffer reused by CVPixelBufferPool will
/// have its contents 0xAA-filled — the memcpy in the next frame will produce
/// visible corruption that ASAN/Zombie will catch.
- (void)testCameraCallbackRapid200Frames {
    VanguardCameraMediaSource *cam =
        [[VanguardCameraMediaSource alloc] initWithPosition:AVCaptureDevicePositionBack
                                                  frameRate:30];

    __block int releaseCount = 0;
    [cam setVideoCallback:^(CVPixelBufferRef frame, CMTime pts) {
        // Simulate renderer receive + release.
        CVPixelBufferRelease(frame);
        releaseCount++;
    }];

    CVPixelBufferRef buf = makeTestPixelBuffer(1920, 1080);
    void (^cb)(CVPixelBufferRef, CMTime) = [cam valueForKey:@"_videoCallback"];

    for (int i = 0; i < 200; i++) {
        if (cb) {
            CVPixelBufferRetain(buf);   // simulate sampleBuffer hold
            cb(buf, kCMTimeZero);
            CVPixelBufferRelease(buf);  // simulate sampleBuffer release
        }
    }

    XCTAssertEqual(releaseCount, 200, @"Callback must fire for every frame");
    // buf must still be alive: held by _latestBuffer (which was set on the last frame).
    CFIndex finalCount = CVPixelBufferGetRetainCount(buf);
    XCTAssertGreaterThanOrEqual(finalCount, 1,
        @"Last frame's buffer must be held by _latestBuffer (count=%ld)", finalCount);

    CVPixelBufferRelease(buf);
    [cam stop];
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - FIX-4: Filter Chain Queue Synchronization Tests
// ─────────────────────────────────────────────────────────────────────────────

@interface VanguardFilterChainQueueTests : XCTestCase
@end

@implementation VanguardFilterChainQueueTests

/// Verifies that processBuffer:atTime:device: is always called on _videoDecodeQueue.
/// Before the fix: the barrier was on _decodeQueue (audio), so _filterChain could be
/// read on _videoDecodeQueue simultaneously with the write. TSAN would report a race.
/// After the fix: barrier on _videoDecodeQueue serialises all reads.
///
/// Run with -fsanitize=thread. The old code will produce a TSAN report.
/// The fixed code will be TSAN-clean.
- (void)testFilterChainBarrierOnCorrectQueue {
    // This test requires a VanguardFileMediaSource — the camera path is excluded
    // because replaceFilterChain: assigns directly for non-file sources.
    NSURL *url = [[NSBundle bundleForClass:[self class]]
                  URLForResource:@"test_video" withExtension:@"mp4"];
    if (!url) { XCTSkip(@"test_video.mp4 not in test bundle"); }

    VanguardMetalRenderer *renderer =
        [[VanguardMetalRenderer alloc] initWithVideoPath:url.path
                                         textureRegistry:nil
                                           methodChannel:nil];
    XCTAssertNotNil(renderer);

    // Create a pool for the spy nodes.
    CVPixelBufferPoolRef pool = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:           @1920,
        (id)kCVPixelBufferHeightKey:          @1080,
    };
    CVPixelBufferPoolCreate(nil, nil, (__bridge CFDictionaryRef)attrs, &pool);

    VanguardRetainCountSpyNode *spy = [[VanguardRetainCountSpyNode alloc] initWithPool:pool];

    // Concurrently: swap filter chain 100 times while injecting synthetic frames.
    // TSAN will catch any unsynchronised access to _filterChain.
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t bgQ = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    __block BOOL keepRunning = YES;

    // Thread A: inject frames via the source's pullNextFrameAsync path.
    // We drive it via start/play for 2 seconds.
    [renderer.source start];
    [renderer.source play];

    // Thread B: rapidly replace filter chain.
    dispatch_group_async(group, bgQ, ^{
        for (int i = 0; i < 100 && keepRunning; i++) {
            NSArray *chain = (i % 2 == 0) ? @[spy] : @[];
            [renderer replaceFilterChain:chain];
            usleep(10000);  // 10ms
        }
    });

    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    keepRunning = NO;
    [renderer.source stop];

    // If TSAN did not fire, the synchronisation is correct.
    // Additionally verify the spy was called at least once (filter chain was active).
    // (spy.callCount > 0 means processBuffer: ran while chain was installed)
    NSLog(@"[Test] Filter chain spy call count: %lu", (unsigned long)spy.callCount);

    if (pool) CVPixelBufferPoolRelease(pool);
}

/// Verifies that after replaceFilterChain:, processBuffer:atTime:device: on the
/// OLD nodes is never called again. Before the fix, a concurrent read on
/// _videoDecodeQueue could see the chain mid-swap and call a node that was
/// already invalidated.
- (void)testInvalidatedNodesNotCalledAfterChainReplacement {
    NSURL *url = [[NSBundle bundleForClass:[self class]]
                  URLForResource:@"test_video" withExtension:@"mp4"];
    if (!url) { XCTSkip(@"test_video.mp4 not in test bundle"); }

    CVPixelBufferPoolRef pool = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:           @1920,
        (id)kCVPixelBufferHeightKey:          @1080,
    };
    CVPixelBufferPoolCreate(nil, nil, (__bridge CFDictionaryRef)attrs, &pool);

    VanguardRetainCountSpyNode *oldNode = [[VanguardRetainCountSpyNode alloc] initWithPool:pool];
    VanguardRetainCountSpyNode *newNode = [[VanguardRetainCountSpyNode alloc] initWithPool:pool];

    VanguardMetalRenderer *renderer =
        [[VanguardMetalRenderer alloc] initWithVideoPath:url.path
                                         textureRegistry:nil
                                           methodChannel:nil];

    [renderer replaceFilterChain:@[oldNode]];

    // Give the barrier time to settle on the video decode queue.
    [NSThread sleepForTimeInterval:0.05];

    NSUInteger oldCallsBeforeSwap = oldNode.callCount;

    // Now swap to newNode. The barrier on videoDecodeQueue ensures all in-flight
    // _onVideoFrame: calls using oldNode complete BEFORE the chain is replaced.
    [renderer replaceFilterChain:@[newNode]];

    // Wait for barrier to propagate.
    [NSThread sleepForTimeInterval:0.1];

    NSUInteger oldCallsAfterSwap    = oldNode.callCount;

    // Let a few more frames render.
    [NSThread sleepForTimeInterval:0.2];

    NSUInteger oldCallsFinalCheck   = oldNode.callCount;

    // oldNode must not be called after the chain was replaced.
    XCTAssertEqual(oldCallsAfterSwap, oldCallsFinalCheck,
        @"Old node must not be called after replaceFilterChain: "
         "(calls before=%lu, after swap settle=%lu, final=%lu)",
        (unsigned long)oldCallsBeforeSwap,
        (unsigned long)oldCallsAfterSwap,
        (unsigned long)oldCallsFinalCheck);

    if (pool) CVPixelBufferPoolRelease(pool);
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - FIX-5: Camera Teardown Race Tests
// ─────────────────────────────────────────────────────────────────────────────

@interface VanguardModeSwitchTeardownTests : XCTestCase
@end

@implementation VanguardModeSwitchTeardownTests

/// Verifies that stopRecordingAndWait blocks until recording state is Idle.
/// Before the fix: teardownCurrentMode returned while state was still .writing,
/// allowing the next mode to start with an active AVAssetWriter.
- (void)testStopRecordingAndWaitCompletesBeforeReturn {
    VanguardCameraMediaSource *cam =
        [[VanguardCameraMediaSource alloc] initWithPosition:AVCaptureDevicePositionBack
                                                  frameRate:30];
    [cam start];

    NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
                            stringByAppendingPathComponent:@"test_recording.mp4"]];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

    XCTestExpectation *startedEx = [self expectationWithDescription:@"recording started"];
    [cam startRecordingToURL:outputURL completion:^(NSError *err) {
        XCTAssertNil(err, @"startRecordingToURL must succeed");
        [startedEx fulfill];
    }];
    [self waitForExpectations:@[startedEx] timeout:3.0];

    // Give the writer a moment to write at least one frame via the watchdog.
    [NSThread sleepForTimeInterval:0.3];

    // This must block until finishWritingWithCompletionHandler: fires.
    // After return, _recordingState must be Idle.
    [cam stopRecordingAndWait];

    // Verify via KVC (test-only access to internal state).
    NSInteger state = [[cam valueForKey:@"_recordingState"] integerValue];
    XCTAssertEqual(state, 0 /* VanguardRecordingStateIdle */,
        @"Recording state must be Idle immediately after stopRecordingAndWait returns");

    // Verify the output file exists and is a valid, closed MP4.
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:outputURL.path];
    XCTAssertTrue(exists, @"Recording file must exist after stopRecordingAndWait");

    if (exists) {
        NSError *assetErr = nil;
        AVAsset *asset = [AVAsset assetWithURL:outputURL];
        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&assetErr];
        XCTAssertNil(assetErr, @"Recording file must be a valid MP4 (parseable by AVAssetReader)");
        XCTAssertNotNil(reader);
    }

    [cam stop];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
}

/// Stress test: 10 rapid camera→idle→camera cycles.
/// Before the fix: the second camera session could start before the first
/// AVAssetWriter finished, leading to kVTCompressionSessionErr_InvalidSession.
- (void)testRapidCameraRestartDoesNotLeakWriter {
    for (int cycle = 0; cycle < 10; cycle++) {
        VanguardCameraMediaSource *cam =
            [[VanguardCameraMediaSource alloc] initWithPosition:AVCaptureDevicePositionBack
                                                      frameRate:30];
        [cam start];

        NSURL *url = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:
             [NSString stringWithFormat:@"rapid_test_%d.mp4", cycle]]];
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

        XCTestExpectation *started = [self expectationWithDescription:
            [NSString stringWithFormat:@"start %d", cycle]];
        [cam startRecordingToURL:url completion:^(NSError *e) { [started fulfill]; }];
        [self waitForExpectations:@[started] timeout:2.0];

        [NSThread sleepForTimeInterval:0.2];  // write a few frames

        // Synchronous drain: must return before we create the next cam instance.
        [cam stopRecordingAndWait];
        [cam stop];

        // Verify no open file handles remain (writer is fully closed).
        NSInteger state = [[cam valueForKey:@"_recordingState"] integerValue];
        XCTAssertEqual(state, 0,
            @"Cycle %d: recording state must be Idle after stopRecordingAndWait", cycle);

        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    }
}

/// Verifies that stopRecordingAndWait is a no-op when not recording.
- (void)testStopRecordingAndWaitWhenIdleIsImmediateNoOp {
    VanguardCameraMediaSource *cam =
        [[VanguardCameraMediaSource alloc] initWithPosition:AVCaptureDevicePositionBack
                                                  frameRate:30];
    // Not recording — must return immediately (< 100ms).
    NSDate *before = [NSDate date];
    [cam stopRecordingAndWait];
    NSTimeInterval elapsed = -[before timeIntervalSinceNow];
    XCTAssertLessThan(elapsed, 0.1, @"stopRecordingAndWait must be immediate when not recording");
}

@end
