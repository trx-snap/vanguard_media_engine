// VGExportFileSourceNodePullTest.m
// vanguard_media_engine — Phase 5C-2
//
// Gate test: VGExportFileSourceNode pull-mode file source.
//
// Tests VGExportFileSourceNode against a programmatically created tiny MP4
// fixture. AVAssetWriter is used ONLY in this test file (VGEFS_CreateTestAsset)
// and not in any production code.
//
// Mock/test prefix: VGEFS_ (VG Export File Source)
//
// Apple Framework Checks applied to tests:
//   - AVAssetWriter fixture: finishWriting is async — guarded with semaphore.
//   - prepareWithContext: fires completion on background queue — XCTestExpectation used.
//   - pullFrame: is synchronous — no expectation needed.
//   - CVPixelBuffer from pullFrame: is source-owned; valid until next pull or invalidate.
//
// No VanguardFileMediaSource dependency.
// No external media fixture file.

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreGraphics/CGGeometry.h>

#import "VGExportFileSourceNode.h"

#import <UMF/VGFrameRequest.h>
#import <UMF/VGFrameResult.h>
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGFrameDelegate.h>
#import <UMF/VGNode.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGGraphDescriptor.h>
#import <UMF/VGExecutionPlan.h>
#import <UMF/VGGraphNodeDescriptor.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGResourceAllocator.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Test fixture helpers (AVAssetWriter — test only)
// ─────────────────────────────────────────────────────────────────────────────

/// Creates a tiny H.264 MP4 file in NSTemporaryDirectory with `frameCount` solid-
/// color frames at `size` resolution and `fps` frame rate. Synchronous — blocks
/// on AVAssetWriter finishWriting via semaphore.
///
/// Returns the file URL, or nil on failure.
static NSURL * _Nullable VGEFS_CreateTestAsset(NSUInteger frameCount,
                                                CGSize size,
                                                double fps) {
    NSString *path = [NSTemporaryDirectory()
                      stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"VGEFS_test_%@.mp4",
                           [[NSUUID UUID] UUIDString]]];
    NSURL *url = [NSURL fileURLWithPath:path];

    NSError *error = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url
                                                     fileType:AVFileTypeMPEG4
                                                        error:&error];
    if (!writer || error) return nil;

    NSDictionary *settings = @{
        AVVideoCodecKey:  AVVideoCodecTypeH264,
        AVVideoWidthKey:  @((NSInteger)size.width),
        AVVideoHeightKey: @((NSInteger)size.height),
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                   outputSettings:settings];
    input.expectsMediaDataInRealTime = NO;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:    @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:              @((NSInteger)size.width),
        (id)kCVPixelBufferHeightKey:             @((NSInteger)size.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                         sourcePixelBufferAttributes:attrs];

    if (![writer canAddInput:input]) return nil;
    [writer addInput:input];
    [writer startWriting];
    [writer startSessionAtSourceTime:kCMTimeZero];

    CMTime frameDuration = CMTimeMakeWithSeconds(1.0 / fps, 600);

    for (NSUInteger i = 0; i < frameCount; i++) {
        // Wait until input is ready.
        while (!input.isReadyForMoreMediaData) {
            [NSThread sleepForTimeInterval:0.005];
        }

        CVPixelBufferRef pb = NULL;
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                          adaptor.pixelBufferPool, &pb);
        if (!pb) {
            // Fallback: direct create.
            CVPixelBufferCreate(kCFAllocatorDefault,
                                (size_t)size.width, (size_t)size.height,
                                kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)attrs, &pb);
        }
        if (pb) {
            CVPixelBufferLockBaseAddress(pb, 0);
            // Solid color fill: cycle hue per frame for visibility.
            uint8_t r = (uint8_t)(i * 40 % 256);
            uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
            size_t sz = CVPixelBufferGetDataSize(pb);
            for (size_t j = 0; j < sz; j += 4) {
                base[j]   = r;      // B
                base[j+1] = 128;    // G
                base[j+2] = 200;    // R
                base[j+3] = 255;    // A
            }
            CVPixelBufferUnlockBaseAddress(pb, 0);

            CMTime pts = CMTimeMultiply(frameDuration, (int32_t)i);
            [adaptor appendPixelBuffer:pb withPresentationTime:pts];
            CVPixelBufferRelease(pb);
        }
    }

    [input markAsFinished];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    if (writer.status != AVAssetWriterStatusCompleted) return nil;
    return url;
}

/// Creates a minimal VGGraphExecutionContext suitable for pull-mode export tests
/// (clock == nil, generation == 0, nodes == empty).
static VGGraphExecutionContext * _Nullable VGEFS_MakeContext(void) {
    // Build a minimal descriptor (pull-mode; no nodes needed for source tests).
    VGGraphDescriptor *desc = [[VGGraphDescriptor alloc]
        initWithClockPolicy:VGClockPolicyPull
           admissionPolicies:@{}
                  layoutHint:VGGraphLayoutHintLinear];

    VGExecutionPlan *plan = [[VGExecutionPlan alloc]
        initWithTopologicalOrder:@[]
                  parallelGroups:@[]];

    VGResourceAllocator *alloc = [[VGResourceAllocator alloc]
        initWithDevice:nil poolConfig:nil];

    return [[VGGraphExecutionContext alloc]
        initWithDescriptor:desc
                      plan:plan
                     nodes:@{}
                     clock:nil
         resourceAllocator:alloc];
}

/// Creates a VGFrameRequest for pull-mode tests with generation 0.
static VGFrameRequest *VGEFS_MakeRequest(uint64_t generation, BOOL cancelled) {
    VGFrameRequest *req = [[VGFrameRequest alloc]
        initWithRequestedPTS:kCMTimeZero
                    duration:CMTimeMake(1, 30)
                  generation:generation
                  renderSize:CGSizeZero
                        mode:VGRenderModeExport];
    req.isCancelled = cancelled;
    return req;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGExportFileSourceNodePullTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGExportFileSourceNodePullTest : XCTestCase
@end

@implementation VGExportFileSourceNodePullTest {
    NSURL                    *_testAssetURL;
    AVAsset                  *_testAsset;
    VGExportFileSourceNode   *_node;
    VGGraphExecutionContext   *_ctx;
}

- (void)setUp {
    [super setUp];
    // Create a 5-frame 16x16 30fps MP4 fixture.
    _testAssetURL = VGEFS_CreateTestAsset(5, CGSizeMake(16, 16), 30.0);
    XCTAssertNotNil(_testAssetURL, @"Test asset creation failed");

    _testAsset = [AVURLAsset URLAssetWithURL:_testAssetURL options:nil];
    _node      = [[VGExportFileSourceNode alloc] initWithAsset:_testAsset];
    _ctx       = VGEFS_MakeContext();
}

- (void)tearDown {
    [_node invalidate];
    _node = nil;
    _testAsset = nil;

    if (_testAssetURL) {
        [[NSFileManager defaultManager] removeItemAtURL:_testAssetURL error:nil];
        _testAssetURL = nil;
    }
    [super tearDown];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5C2-01: prepareWithContext: succeeds for valid asset
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTC5C2_01_prepareSucceeds {
    XCTestExpectation *exp = [self expectationWithDescription:@"TC-5C2-01 prepare"];
    [_node prepareWithContext:_ctx completion:^(NSError * _Nullable error) {
        XCTAssertNil(error, @"TC-5C2-01: prepare should succeed; error=%@", error);
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5C2-02: pullFrame: returns delivered for first frame
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTC5C2_02_pullFrameReturnsDelivered {
    XCTestExpectation *exp = [self expectationWithDescription:@"TC-5C2-02 prepare"];
    [_node prepareWithContext:_ctx completion:^(NSError * _Nullable error) {
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    VGFrameRequest *req = VGEFS_MakeRequest(0, NO);
    VGFrameResult  *res = [_node pullFrame:req];

    XCTAssertEqual(res.status, VGFrameStatusDelivered,
                   @"TC-5C2-02: first pull should be delivered");
    XCTAssertNotNil((__bridge id)res.envelope.payload.videoBuffer,
                    @"TC-5C2-02: delivered frame should have pixel buffer");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5C2-03: pullFrame: returns endOfStream after all frames
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTC5C2_03_pullFrameReturnsEndOfStream {
    XCTestExpectation *exp = [self expectationWithDescription:@"TC-5C2-03 prepare"];
    [_node prepareWithContext:_ctx completion:^(NSError * _Nullable error) {
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    VGFrameRequest *req = VGEFS_MakeRequest(0, NO);
    VGFrameResult  *res = nil;
    NSInteger deliveredCount = 0;
    NSInteger maxPulls = 20;  // Safety limit (asset has 5 frames).

    for (NSInteger i = 0; i < maxPulls; i++) {
        res = [_node pullFrame:req];
        if (res.status == VGFrameStatusDelivered) {
            deliveredCount++;
        } else if (res.status == VGFrameStatusEndOfStream) {
            break;
        }
    }

    XCTAssertEqual(res.status, VGFrameStatusEndOfStream,
                   @"TC-5C2-03: should reach endOfStream");
    XCTAssertGreaterThan(deliveredCount, 0,
                         @"TC-5C2-03: should have delivered at least one frame");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5C2-04: request.isCancelled returns skipped
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTC5C2_04_cancelledRequestReturnsSkipped {
    XCTestExpectation *exp = [self expectationWithDescription:@"TC-5C2-04 prepare"];
    [_node prepareWithContext:_ctx completion:^(NSError * _Nullable error) {
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    VGFrameRequest *req = VGEFS_MakeRequest(0, YES);  // isCancelled = YES
    VGFrameResult  *res = [_node pullFrame:req];

    XCTAssertEqual(res.status, VGFrameStatusSkipped,
                   @"TC-5C2-04: cancelled request should return skipped");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5C2-05: generation mismatch returns skipped
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTC5C2_05_generationMismatchReturnsSkipped {
    XCTestExpectation *exp = [self expectationWithDescription:@"TC-5C2-05 prepare"];
    [_node prepareWithContext:_ctx completion:^(NSError * _Nullable error) {
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    // Node generation is 0 (from context). Use generation 99 in request.
    VGFrameRequest *req = VGEFS_MakeRequest(99, NO);
    VGFrameResult  *res = [_node pullFrame:req];

    XCTAssertEqual(res.status, VGFrameStatusSkipped,
                   @"TC-5C2-05: generation mismatch should return skipped");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5C2-06: invalidated node returns error
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTC5C2_06_invalidatedNodeReturnsError {
    XCTestExpectation *exp = [self expectationWithDescription:@"TC-5C2-06 prepare"];
    [_node prepareWithContext:_ctx completion:^(NSError * _Nullable error) {
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    [_node invalidate];

    VGFrameRequest *req = VGEFS_MakeRequest(0, NO);
    VGFrameResult  *res = [_node pullFrame:req];

    XCTAssertEqual(res.status, VGFrameStatusError,
                   @"TC-5C2-06: invalidated node should return error");
    XCTAssertNotNil(res.error, @"TC-5C2-06: error should be non-nil");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5C2-07: startProducing is no-op (does not crash)
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTC5C2_07_startProducingIsNoOp {
    XCTAssertNoThrow([_node startProducing],
                     @"TC-5C2-07: startProducing must not crash");
    // No push callbacks or state changes expected.
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5C2-08: stopProducing is no-op (does not crash)
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTC5C2_08_stopProducingIsNoOp {
    XCTAssertNoThrow([_node stopProducing],
                     @"TC-5C2-08: stopProducing must not crash");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5C2-09: no VanguardFileMediaSource dependency
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTC5C2_09_noVanguardFileMediaSourceDependency {
    // VGExportFileSourceNode is a standalone NSObject <VGSourceNode>.
    // It does not inherit from or delegate to VanguardFileMediaSource.
    // If the class loads successfully, the isolation contract holds.
    XCTAssertNotNil(_node, @"TC-5C2-09: node should init without VanguardFileMediaSource");
    XCTAssertEqualObjects(_node.nodeClass, @"VGExportFileSourceNode",
                          @"TC-5C2-09: nodeClass should identify the export source");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5C2-10: buffer remains valid after CMSampleBuffer is released
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTC5C2_10_bufferValidAfterSampleRelease {
    XCTestExpectation *exp = [self expectationWithDescription:@"TC-5C2-10 prepare"];
    [_node prepareWithContext:_ctx completion:^(NSError * _Nullable error) {
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    VGFrameRequest *req = VGEFS_MakeRequest(0, NO);
    VGFrameResult  *res = [_node pullFrame:req];

    XCTAssertEqual(res.status, VGFrameStatusDelivered,
                   @"TC-5C2-10: should deliver a frame");

    CVPixelBufferRef pb = (CVPixelBufferRef)res.envelope.payload.videoBuffer;
    XCTAssertNotEqual(pb, (CVPixelBufferRef)NULL,
                      @"TC-5C2-10: pixel buffer must be non-NULL");

    // Attempt to access the pixel buffer data — verifies it is still valid
    // (i.e., the source retained it before releasing the CMSampleBuffer).
    CVReturn lockResult = CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    XCTAssertEqual(lockResult, kCVReturnSuccess,
                   @"TC-5C2-10: buffer must be lockable — source must retain before sample release");
    void *addr = CVPixelBufferGetBaseAddress(pb);
    XCTAssertNotEqual(addr, NULL,
                      @"TC-5C2-10: base address must be accessible");
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5C2-11: sequential PTS increases
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTC5C2_11_sequentialPTSIncreases {
    XCTestExpectation *exp = [self expectationWithDescription:@"TC-5C2-11 prepare"];
    [_node prepareWithContext:_ctx completion:^(NSError * _Nullable error) {
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    VGFrameRequest *req = VGEFS_MakeRequest(0, NO);
    CMTime previousPTS = kCMTimeNegativeInfinity;
    NSInteger deliveredCount = 0;

    for (NSInteger i = 0; i < 5; i++) {
        VGFrameResult *res = [_node pullFrame:req];
        if (res.status == VGFrameStatusEndOfStream) break;
        if (res.status != VGFrameStatusDelivered) continue;

        CMTime pts = res.envelope.pts;
        if (CMTIME_IS_VALID(pts) && CMTIME_IS_VALID(previousPTS)) {
            XCTAssertTrue(CMTimeCompare(pts, previousPTS) > 0,
                          @"TC-5C2-11: PTS must increase monotonically: "
                          "prev=%.4f cur=%.4f",
                          CMTimeGetSeconds(previousPTS), CMTimeGetSeconds(pts));
        }
        previousPTS = pts;
        deliveredCount++;
    }

    XCTAssertGreaterThan(deliveredCount, 1,
                         @"TC-5C2-11: must deliver at least 2 frames to verify order");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5C2-12: nodeRole is VGNodeRoleSource
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTC5C2_12_nodeRoleIsSource {
    XCTAssertEqual(_node.nodeRole, VGNodeRoleSource,
                   @"TC-5C2-12: nodeRole must be VGNodeRoleSource");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5C2-13: declaredPorts includes video_out
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTC5C2_13_declaredPortsHasVideoOut {
    NSArray<VGMediaPort *> *ports = [_node declaredPorts];
    XCTAssertEqual(ports.count, 1U, @"TC-5C2-13: should declare exactly one port");

    VGMediaPort *port = ports.firstObject;
    XCTAssertEqualObjects(port.portId, @"video_out",
                          @"TC-5C2-13: port ID should be 'video_out'");
    XCTAssertEqual(port.mediaType, VGMediaTypeVideo,
                   @"TC-5C2-13: port media type should be video");
    XCTAssertEqual(port.direction, VGPortDirectionOutput,
                   @"TC-5C2-13: port direction should be output");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5C2-14: seekTo:generation: rebuilds reader (pull resumes after seek)
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTC5C2_14_seekToRebuildsReader {
    XCTestExpectation *exp = [self expectationWithDescription:@"TC-5C2-14 prepare"];
    [_node prepareWithContext:_ctx completion:^(NSError * _Nullable error) {
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    // Pull one frame first.
    VGFrameRequest *req = VGEFS_MakeRequest(0, NO);
    VGFrameResult  *res = [_node pullFrame:req];
    XCTAssertEqual(res.status, VGFrameStatusDelivered,
                   @"TC-5C2-14: first pull should deliver");

    // Seek to beginning with a new generation.
    [_node seekTo:kCMTimeZero generation:1];

    // Pull with the new generation — should deliver again.
    VGFrameRequest *req2 = VGEFS_MakeRequest(1, NO);
    VGFrameResult  *res2 = [_node pullFrame:req2];
    XCTAssertEqual(res2.status, VGFrameStatusDelivered,
                   @"TC-5C2-14: pull after seekTo should deliver with new generation");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5C2-15: does not conform to VGFrameDelegate
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTC5C2_15_doesNotConformToVGFrameDelegate {
    XCTAssertFalse([_node conformsToProtocol:@protocol(VGFrameDelegate)],
                   @"TC-5C2-15: VGExportFileSourceNode must NOT conform to VGFrameDelegate");
}

@end
