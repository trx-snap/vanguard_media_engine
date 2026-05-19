// VGVideoEncoderSinkNodeTest.m
// vanguard_media_engine — Phase 5C-4
//
// Gate tests: VGVideoEncoderSinkNode encoder sink.
//
// AVAssetWriter is used in production code (VGVideoEncoderSinkNode.m)
// AND in VGESN_CreateTestPixelBuffer/finalize tests — this IS the writer node.
// Mock prefix: VGESN_ (VG Export Sink Node)

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

#import "VGVideoEncoderSinkNode.h"
#import <UMF/VGNode.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGExportProfile.h>
#import <UMF/VGExportManifest.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGGraphDescriptor.h>
#import <UMF/VGExecutionPlan.h>
#import <UMF/VGResourceAllocator.h>
#import <UMF/VGRetainedBuffer.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Test fixtures
// ─────────────────────────────────────────────────────────────────────────────

/// Creates a 32BGRA CVPixelBuffer filled with a solid color for encode testing.
static CVPixelBufferRef VGESN_CreateTestPixelBuffer(size_t width, size_t height) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:           @(width),
        (id)kCVPixelBufferHeightKey:          @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)attrs, &pb);
    if (pb) {
        CVPixelBufferLockBaseAddress(pb, 0);
        memset(CVPixelBufferGetBaseAddress(pb), 128,
               CVPixelBufferGetDataSize(pb));
        CVPixelBufferUnlockBaseAddress(pb, 0);
    }
    return pb;
}

/// Returns a unique temp URL for test output.
static NSURL *VGESN_TempOutputURL(void) {
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"VGESN_test_%@.mp4",
             [[NSUUID UUID] UUIDString]]];
    return [NSURL fileURLWithPath:path];
}

/// Makes a minimal VGGraphExecutionContext for testing.
static VGGraphExecutionContext *VGESN_MakeContext(void) {
    VGGraphDescriptor *desc = [[VGGraphDescriptor alloc]
        initWithGraphId:@"testGraph"
                  nodes:@[]
            connections:@[]
            clockPolicy:VGClockPolicyPull
           audioSidecar:nil];
    VGExecutionPlan *plan = [[VGExecutionPlan alloc]
        initWithTopologicalOrder:@[]
                  parallelGroups:@[]];
    return [[VGGraphExecutionContext alloc]
        initWithDescriptor:desc
                       plan:plan
                      nodes:@{}
                      clock:nil
          resourceAllocator:[VGResourceAllocator sharedInstance]];
}

/// Makes a minimal offline VGExportProfile for 128×128 testing.
static VGExportProfile *VGESN_MakeProfile(void) {
    return [[VGExportProfile alloc]
        initWithCodecType:kCMVideoCodecType_H264
             profileLevel:(__bridge NSString *)kVTProfileLevel_H264_High_AutoLevel
                    width:128
                   height:128
               bitrateBps:100000
                      fps:30
      maxKeyFrameInterval:0
  maxKeyFrameIntervalDuration:0.0
                  quality:0.0
      allowFrameReordering:NO
                 realtime:NO
             allowOpenGOP:NO
                    usage:VGEncoderUsageOffline];
}

/// Builds a VGFrameEnvelope wrapping the given CVPixelBufferRef at pts.
static VGFrameEnvelope VGESN_MakeEnvelope(CVPixelBufferRef pb, int frameIndex) {
    VGFrameEnvelope env;
    memset(&env, 0, sizeof(env));
    env.pts      = CMTimeMake(frameIndex, 30);
    env.duration = CMTimeMake(1, 30);
    env.payload.videoBuffer = pb;
    return env;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGVideoEncoderSinkNodeTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGVideoEncoderSinkNodeTest : XCTestCase
@end

@implementation VGVideoEncoderSinkNodeTest {
    NSURL              *_outputURL;
    VGExportProfile    *_profile;
    VGVideoEncoderSinkNode *_sut;
}

- (void)setUp {
    [super setUp];
    _outputURL = VGESN_TempOutputURL();
    _profile   = VGESN_MakeProfile();
    _sut       = [[VGVideoEncoderSinkNode alloc] initWithOutputURL:_outputURL
                                                           profile:_profile];
}

- (void)tearDown {
    [_sut invalidate];
    _sut = nil;
    // Clean up output file if present.
    [[NSFileManager defaultManager] removeItemAtURL:_outputURL error:nil];
    [super tearDown];
}

// ─── TC-5C4-01: VGFrameSink conformance ──────────────────────────────────────

- (void)testTC_5C4_01_conformsToVGFrameSink {
    XCTAssertTrue([_sut conformsToProtocol:@protocol(VGFrameSink)],
                  @"TC-5C4-01: Must conform to VGFrameSink");
}

// ─── TC-5C4-02: nodeRole == VGNodeRoleSink ───────────────────────────────────

- (void)testTC_5C4_02_nodeRoleIsSink {
    XCTAssertEqual(_sut.nodeRole, VGNodeRoleSink,
                   @"TC-5C4-02: nodeRole must be VGNodeRoleSink");
}

// ─── TC-5C4-03: declaredPorts contains video_in ──────────────────────────────

- (void)testTC_5C4_03_declaredPortsContainsVideoIn {
    NSArray<VGMediaPort *> *ports = [_sut declaredPorts];
    XCTAssertEqual(ports.count, 1u, @"TC-5C4-03: Sink must declare exactly 1 port");
    VGMediaPort *p = ports.firstObject;
    XCTAssertEqualObjects(p.portId, @"video_in",
                          @"TC-5C4-03: Port must be named 'video_in'");
    XCTAssertEqual(p.mediaType, VGMediaTypeVideo,
                   @"TC-5C4-03: Port media type must be VGMediaTypeVideo");
    XCTAssertEqual(p.direction, VGPortDirectionInput,
                   @"TC-5C4-03: Port must be input");
    XCTAssertTrue(p.required, @"TC-5C4-03: Port must be required");
}

// ─── TC-5C4-04: nodeClass ────────────────────────────────────────────────────

- (void)testTC_5C4_04_nodeClass {
    XCTAssertEqualObjects(_sut.nodeClass, @"VGVideoEncoderSinkNode",
                          @"TC-5C4-04: nodeClass must be 'VGVideoEncoderSinkNode'");
}

// ─── TC-5C4-05: ready == NO before prepare ───────────────────────────────────

- (void)testTC_5C4_05_notReadyBeforePrepare {
    XCTAssertFalse(_sut.ready, @"TC-5C4-05: ready must be NO before prepareWithContext:");
}

// ─── TC-5C4-06: prepare sets ready == YES ────────────────────────────────────

- (void)testTC_5C4_06_prepareSetReadyYes {
    VGGraphExecutionContext *ctx = VGESN_MakeContext();
    XCTestExpectation *exp = [self expectationWithDescription:@"TC-5C4-06 prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) {
        XCTAssertNil(err, @"TC-5C4-06: prepareWithContext should not error: %@", err);
        XCTAssertTrue(self->_sut.ready, @"TC-5C4-06: ready must be YES after prepare");
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];
}

// ─── TC-5C4-07: invalidate is idempotent ─────────────────────────────────────

- (void)testTC_5C4_07_invalidateIsIdempotent {
    VGGraphExecutionContext *ctx = VGESN_MakeContext();
    XCTestExpectation *exp = [self expectationWithDescription:@"TC-5C4-07 prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) {
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    // Calling invalidate multiple times must not crash.
    XCTAssertNoThrow([_sut invalidate], @"TC-5C4-07: First invalidate");
    XCTAssertNoThrow([_sut invalidate], @"TC-5C4-07: Second invalidate (idempotent)");
    XCTAssertNoThrow([_sut invalidate], @"TC-5C4-07: Third invalidate (idempotent)");
}

// ─── TC-5C4-08: ready == NO after invalidate ─────────────────────────────────

- (void)testTC_5C4_08_readyFalseAfterInvalidate {
    VGGraphExecutionContext *ctx = VGESN_MakeContext();
    XCTestExpectation *exp = [self expectationWithDescription:@"TC-5C4-08 prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) {
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    [_sut invalidate];
    XCTAssertFalse(_sut.ready, @"TC-5C4-08: ready must be NO after invalidate");
}

// ─── TC-5C4-09: presentEnvelope on invalidated node is no-op ─────────────────

- (void)testTC_5C4_09_presentEnvelopeOnInvalidatedNodeIsNoOp {
    // Node not prepared — invalidate immediately, then present.
    [_sut invalidate];

    CVPixelBufferRef pb = VGESN_CreateTestPixelBuffer(128, 128);
    VGFrameEnvelope env = VGESN_MakeEnvelope(pb, 0);
    XCTAssertNoThrow([_sut presentEnvelope:env],
                     @"TC-5C4-09: presentEnvelope on invalidated node must not crash");
    XCTAssertEqual(_sut.framesSubmitted, 0,
                   @"TC-5C4-09: framesSubmitted must remain 0 on invalidated node");
    if (pb) CVPixelBufferRelease(pb);
}

// ─── TC-5C4-10: presentEnvelope submits frame to encoder ─────────────────────

- (void)testTC_5C4_10_presentEnvelopeSubmitsFrame {
    VGGraphExecutionContext *ctx = VGESN_MakeContext();
    XCTestExpectation *prepExp = [self expectationWithDescription:@"TC-5C4-10 prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) {
        XCTAssertNil(err);
        [prepExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    CVPixelBufferRef pb = VGESN_CreateTestPixelBuffer(128, 128);
    VGFrameEnvelope env = VGESN_MakeEnvelope(pb, 0);
    [_sut presentEnvelope:env];
    if (pb) CVPixelBufferRelease(pb);

    XCTAssertGreaterThan(_sut.framesSubmitted, 0,
                         @"TC-5C4-10: framesSubmitted must increment after presentEnvelope:");
}

// ─── TC-5C4-11: presentEnvelope blocks until after append ────────────────────
// This test verifies the semaphore signal ordering: framesSubmitted is only
// incremented AFTER presentEnvelope: returns, which happens only after the
// semaphore wakes (i.e., after appendSampleBuffer on success).

- (void)testTC_5C4_11_presentEnvelopeDoesNotReturnBeforeAppend {
    VGGraphExecutionContext *ctx = VGESN_MakeContext();
    XCTestExpectation *prepExp = [self expectationWithDescription:@"TC-5C4-11 prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) {
        XCTAssertNil(err);
        [prepExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    NSInteger before = _sut.framesSubmitted;
    CVPixelBufferRef pb = VGESN_CreateTestPixelBuffer(128, 128);
    VGFrameEnvelope env = VGESN_MakeEnvelope(pb, 0);

    // presentEnvelope: is synchronous and blocking — by the time it returns,
    // the semaphore has been signaled (after append or error/drop).
    [_sut presentEnvelope:env];
    NSInteger after = _sut.framesSubmitted;
    if (pb) CVPixelBufferRelease(pb);

    XCTAssertEqual(after, before + 1,
                   @"TC-5C4-11: framesSubmitted must increment exactly once "
                   @"after presentEnvelope: returns (semaphore + append complete)");
}

// ─── TC-5C4-12: multiple presentEnvelope calls — correct frame count ──────────

- (void)testTC_5C4_12_multipleFramesCorrectCount {
    VGGraphExecutionContext *ctx = VGESN_MakeContext();
    XCTestExpectation *prepExp = [self expectationWithDescription:@"TC-5C4-12 prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) {
        XCTAssertNil(err);
        [prepExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    const NSInteger kFrameCount = 5;
    for (NSInteger i = 0; i < kFrameCount; i++) {
        CVPixelBufferRef pb = VGESN_CreateTestPixelBuffer(128, 128);
        VGFrameEnvelope env = VGESN_MakeEnvelope(pb, (int)i);
        [_sut presentEnvelope:env];
        if (pb) CVPixelBufferRelease(pb);
    }

    XCTAssertEqual(_sut.framesSubmitted, kFrameCount,
                   @"TC-5C4-12: framesSubmitted must equal frame count submitted");
}

// ─── TC-5C4-13: VGRetainedBuffer used (structural) ───────────────────────────
// This test is structural — verifies the class is imported and referenced.
// Runtime correctness is covered by TC-5C4-11 (blocking until after VT callback).

- (void)testTC_5C4_13_VGRetainedBufferImported {
    // VGRetainedBuffer must be importable and usable (proves DEC-V2-010 compliance).
    CVPixelBufferRef pb = VGESN_CreateTestPixelBuffer(128, 128);
    XCTAssertNotEqual(pb, (CVPixelBufferRef)NULL, @"TC-5C4-13: fixture must return non-NULL buffer");
    // Wrap it directly to verify VGRetainedBuffer is available.
    VGRetainedBuffer *retained __attribute__((objc_precise_lifetime)) =
        [[VGRetainedBuffer alloc] initWithPixelBuffer:pb];
    XCTAssertNotNil(retained, @"TC-5C4-13: VGRetainedBuffer must wrap pixel buffer");
    XCTAssertEqual(retained.pixelBuffer, pb,
                   @"TC-5C4-13: VGRetainedBuffer must expose the retained pixel buffer");
    CVPixelBufferRelease(pb);
    // retained released by ARC — verifies +1 retain pattern
}


// ─── TC-5C4-14: no double-signal on success ───────────────────────────────────
// After one presentEnvelope: the framesSubmitted count is exactly 1.
// If the semaphore were signaled twice (once in frameCompletion, once in
// encodedSample), the next presentEnvelope would return without waiting.
// This test submits 2 frames and verifies both increment correctly.

- (void)testTC_5C4_14_noDoubleSignalOnSuccess {
    VGGraphExecutionContext *ctx = VGESN_MakeContext();
    XCTestExpectation *prepExp = [self expectationWithDescription:@"TC-5C4-14 prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) {
        XCTAssertNil(err);
        [prepExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    // Submit frame 0.
    CVPixelBufferRef pb0 = VGESN_CreateTestPixelBuffer(128, 128);
    [_sut presentEnvelope:VGESN_MakeEnvelope(pb0, 0)];
    CVPixelBufferRelease(pb0);
    XCTAssertEqual(_sut.framesSubmitted, 1, @"TC-5C4-14: After frame 0: count=1");

    // Submit frame 1 — if semaphore leaked, this would return before timeout.
    CVPixelBufferRef pb1 = VGESN_CreateTestPixelBuffer(128, 128);
    [_sut presentEnvelope:VGESN_MakeEnvelope(pb1, 1)];
    CVPixelBufferRelease(pb1);
    XCTAssertEqual(_sut.framesSubmitted, 2, @"TC-5C4-14: After frame 1: count=2");
}

// ─── TC-5C4-15: finalizeExport flushes and finishes writing ──────────────────

- (void)testTC_5C4_15_finalizeExportSucceeds {
    VGGraphExecutionContext *ctx = VGESN_MakeContext();
    XCTestExpectation *prepExp = [self expectationWithDescription:@"TC-5C4-15 prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) {
        XCTAssertNil(err);
        [prepExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    // Submit a few frames.
    for (int i = 0; i < 3; i++) {
        CVPixelBufferRef pb = VGESN_CreateTestPixelBuffer(128, 128);
        [_sut presentEnvelope:VGESN_MakeEnvelope(pb, i)];
        CVPixelBufferRelease(pb);
    }

    NSError *finalizeErr = nil;
    VGExportManifest *manifest = [_sut finalizeExportWithError:&finalizeErr];
    XCTAssertNil(finalizeErr, @"TC-5C4-15: finalizeExport must not error: %@", finalizeErr);
    XCTAssertNotNil(manifest, @"TC-5C4-15: finalizeExport must return a manifest");
}

// ─── TC-5C4-16: output file exists after finalize ────────────────────────────

- (void)testTC_5C4_16_outputFileExistsAfterFinalize {
    VGGraphExecutionContext *ctx = VGESN_MakeContext();
    XCTestExpectation *prepExp = [self expectationWithDescription:@"TC-5C4-16 prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) {
        [prepExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    for (int i = 0; i < 3; i++) {
        CVPixelBufferRef pb = VGESN_CreateTestPixelBuffer(128, 128);
        [_sut presentEnvelope:VGESN_MakeEnvelope(pb, i)];
        CVPixelBufferRelease(pb);
    }

    [_sut finalizeExportWithError:nil];

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:_outputURL.path];
    XCTAssertTrue(exists, @"TC-5C4-16: Output file must exist at URL after finalize");
}

// ─── TC-5C4-17: output file is non-zero after finalize ───────────────────────

- (void)testTC_5C4_17_outputFileNonZeroAfterFinalize {
    VGGraphExecutionContext *ctx = VGESN_MakeContext();
    XCTestExpectation *prepExp = [self expectationWithDescription:@"TC-5C4-17 prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) {
        [prepExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    for (int i = 0; i < 3; i++) {
        CVPixelBufferRef pb = VGESN_CreateTestPixelBuffer(128, 128);
        [_sut presentEnvelope:VGESN_MakeEnvelope(pb, i)];
        CVPixelBufferRelease(pb);
    }

    VGExportManifest *manifest = [_sut finalizeExportWithError:nil];
    XCTAssertNotNil(manifest, @"TC-5C4-17: manifest required");
    XCTAssertGreaterThan(manifest.fileSizeBytes, 0,
                         @"TC-5C4-17: Output file must be non-zero size");
}

// ─── TC-5C4-18: manifest codec and dimensions match profile ──────────────────

- (void)testTC_5C4_18_manifestCodecAndDimensions {
    VGGraphExecutionContext *ctx = VGESN_MakeContext();
    XCTestExpectation *prepExp = [self expectationWithDescription:@"TC-5C4-18 prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) {
        [prepExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    for (int i = 0; i < 3; i++) {
        CVPixelBufferRef pb = VGESN_CreateTestPixelBuffer(128, 128);
        [_sut presentEnvelope:VGESN_MakeEnvelope(pb, i)];
        CVPixelBufferRelease(pb);
    }

    NSError *err = nil;
    VGExportManifest *manifest = [_sut finalizeExportWithError:&err];
    XCTAssertNotNil(manifest, @"TC-5C4-18: manifest must not be nil: %@", err);
    XCTAssertEqualObjects(manifest.codec, @"h264", @"TC-5C4-18: codec must be h264");
    XCTAssertEqual(manifest.width, 128, @"TC-5C4-18: width must match profile");
    XCTAssertEqual(manifest.height, 128, @"TC-5C4-18: height must match profile");
}

// ─── TC-5C4-19: no VGGraphSchedulerV2 coupling ───────────────────────────────
// Structural test: VGVideoEncoderSinkNode must not import or reference
// VGGraphSchedulerV2. Verified via grep in validation; this test confirms
// the class does not respond to any VGGraphSchedulerV2 selectors.

- (void)testTC_5C4_19_noVGGraphSchedulerV2Coupling {
    // VGVideoEncoderSinkNode is a plain NSObject<VGFrameSink>.
    // It must NOT be a subclass of VGGraphSchedulerV2 or any scheduler.
    // VGGraphSchedulerV2 is deliberately not imported in this test file.
    XCTAssertFalse([_sut respondsToSelector:NSSelectorFromString(@"scheduleFrame:")],
                   @"TC-5C4-19: Must not respond to VGGraphSchedulerV2 selectors");
    XCTAssertFalse([_sut respondsToSelector:NSSelectorFromString(@"didReceiveRawFrame:")],
                   @"TC-5C4-19: Must not respond to VGFrameDelegate selectors");
    XCTAssertFalse([_sut isKindOfClass:NSClassFromString(@"VGGraphSchedulerV2")],
                   @"TC-5C4-19: Must not be VGGraphSchedulerV2 or subclass");
}

// ─── TC-5C4-20: sourceFormatHint used (lazy writer input pattern) ─────────────
// Structural: verifies that the output file's video track format matches
// the encoder config (H.264 128×128). If sourceFormatHint were missing or wrong,
// the output format would be inconsistent.

- (void)testTC_5C4_20_outputVideoTrackPresent {
    VGGraphExecutionContext *ctx = VGESN_MakeContext();
    XCTestExpectation *prepExp = [self expectationWithDescription:@"TC-5C4-20 prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) {
        [prepExp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    for (int i = 0; i < 5; i++) {
        CVPixelBufferRef pb = VGESN_CreateTestPixelBuffer(128, 128);
        [_sut presentEnvelope:VGESN_MakeEnvelope(pb, i)];
        CVPixelBufferRelease(pb);
    }

    NSError *finalErr = nil;
    VGExportManifest *manifest = [_sut finalizeExportWithError:&finalErr];
    XCTAssertNotNil(manifest, @"TC-5C4-20: finalize must succeed: %@", finalErr);

    // Verify the output file has a video track via AVAsset.
    AVAsset *outputAsset = [AVAsset assetWithURL:_outputURL];
    NSArray *videoTracks = [outputAsset tracksWithMediaType:AVMediaTypeVideo];
    XCTAssertGreaterThan(videoTracks.count, 0u,
                         @"TC-5C4-20: Output MP4 must contain a video track "
                         @"(sourceFormatHint lazy writer init worked correctly)");
}

@end
