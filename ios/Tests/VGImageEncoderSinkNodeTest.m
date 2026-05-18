// VGImageEncoderSinkNodeTest.m
// vanguard_media_engine — Phase 5D-2
//
// Gate tests: VGImageEncoderSinkNode image encoder sink.
// Mock prefix: VIESN_ (VG Image Encoder Sink Node)

#import <XCTest/XCTest.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>

#import "VGImageEncoderSinkNode.h"
#import <UMF/VGNode.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGImageExportProfile.h>
#import <UMF/VGImageExportManifest.h>
#import <UMF/VGImageEncodeFormat.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGGraphDescriptor.h>
#import <UMF/VGExecutionPlan.h>
#import <UMF/VGResourceAllocator.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Test fixtures
// ─────────────────────────────────────────────────────────────────────────────

/// Creates a 32BGRA CVPixelBuffer filled with a solid color for encode testing.
static CVPixelBufferRef VIESN_CreateTestPixelBuffer(size_t width, size_t height) {
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

/// Returns a unique temp URL for test output with the given extension.
static NSURL *VIESN_TempOutputURL(NSString *ext) {
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"VIESN_test_%@.%@",
             [[NSUUID UUID] UUIDString], ext]];
    return [NSURL fileURLWithPath:path];
}

/// Makes a minimal VGGraphExecutionContext for testing.
static VGGraphExecutionContext *VIESN_MakeContext(void) {
    VGGraphDescriptor *desc = [[VGGraphDescriptor alloc]
        initWithGraphId:@"testGraph"
                  nodes:@[]
            connections:@[]
            clockPolicy:VGClockPolicyPull
           audioSidecar:nil];
    VGExecutionPlan *plan = [[VGExecutionPlan alloc]
        initWithTopologicalOrder:@[]
               parallelGroups:@[]];
    VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];
    return [[VGGraphExecutionContext alloc]
        initWithDescriptor:desc
                      plan:plan
                     nodes:@{}
                     clock:nil
         resourceAllocator:alloc];
}

/// Builds a VGFrameEnvelope wrapping the given CVPixelBufferRef.
static VGFrameEnvelope VIESN_MakeEnvelope(CVPixelBufferRef pb) {
    VGFrameEnvelope env;
    memset(&env, 0, sizeof(env));
    env.pts      = CMTimeMake(0, 1);
    env.duration = CMTimeMake(1, 1);
    env.mediaType = VGMediaTypeVideo;
    env.payload.videoBuffer = pb;
    return env;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGImageEncoderSinkNodeTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGImageEncoderSinkNodeTest : XCTestCase
@end

@implementation VGImageEncoderSinkNodeTest {
    NSURL                    *_outputURL;
    VGImageExportProfile     *_profile;
    VGImageEncoderSinkNode   *_sut;
}

- (void)setUp {
    [super setUp];
    _outputURL = VIESN_TempOutputURL(@"jpg");
    _profile   = [VGImageExportProfile jpegProfileWithQuality:0.85f];
    _sut       = [[VGImageEncoderSinkNode alloc] initWithOutputURL:_outputURL
                                                           profile:_profile];
}

- (void)tearDown {
    [_sut invalidate];
    _sut = nil;
    [[NSFileManager defaultManager] removeItemAtURL:_outputURL error:nil];
    [super tearDown];
}

// ─── TC-5D2-01: VGFrameSink conformance ──────────────────────────────────────

- (void)testTC_5D2_01_conformsToVGFrameSink {
    XCTAssertTrue([_sut conformsToProtocol:@protocol(VGFrameSink)],
                  @"TC-5D2-01: Must conform to VGFrameSink");
}

// ─── TC-5D2-02: nodeRole == VGNodeRoleSink ───────────────────────────────────

- (void)testTC_5D2_02_nodeRoleIsSink {
    XCTAssertEqual(_sut.nodeRole, VGNodeRoleSink,
                   @"TC-5D2-02: nodeRole must be VGNodeRoleSink");
}

// ─── TC-5D2-03: declaredPorts contains video_in ──────────────────────────────

- (void)testTC_5D2_03_declaredPortsContainsVideoIn {
    NSArray<VGMediaPort *> *ports = [_sut declaredPorts];
    XCTAssertEqual(ports.count, 1u, @"TC-5D2-03: Sink must declare exactly 1 port");
    VGMediaPort *p = ports.firstObject;
    XCTAssertEqualObjects(p.portId, @"video_in");
    XCTAssertEqual(p.mediaType, VGMediaTypeVideo);
    XCTAssertEqual(p.direction, VGPortDirectionInput);
    XCTAssertTrue(p.required);
}

// ─── TC-5D2-04: nodeClass ────────────────────────────────────────────────────

- (void)testTC_5D2_04_nodeClass {
    XCTAssertEqualObjects(_sut.nodeClass, @"VGImageEncoderSinkNode");
}

// ─── TC-5D2-05: ready == NO before prepare ───────────────────────────────────

- (void)testTC_5D2_05_notReadyBeforePrepare {
    XCTAssertFalse(_sut.ready);
}

// ─── TC-5D2-06: prepare sets ready == YES ────────────────────────────────────

- (void)testTC_5D2_06_prepareSetReadyYes {
    VGGraphExecutionContext *ctx = VIESN_MakeContext();
    XCTestExpectation *exp = [self expectationWithDescription:@"prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) {
        XCTAssertNil(err);
        XCTAssertTrue(self->_sut.ready);
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];
}

// ─── TC-5D2-07: invalidate is idempotent ─────────────────────────────────────

- (void)testTC_5D2_07_invalidateIsIdempotent {
    VGGraphExecutionContext *ctx = VIESN_MakeContext();
    XCTestExpectation *exp = [self expectationWithDescription:@"prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) { [exp fulfill]; }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];
    XCTAssertNoThrow([_sut invalidate]);
    XCTAssertNoThrow([_sut invalidate]);
    XCTAssertNoThrow([_sut invalidate]);
}

// ─── TC-5D2-08: ready == NO after invalidate ─────────────────────────────────

- (void)testTC_5D2_08_readyFalseAfterInvalidate {
    VGGraphExecutionContext *ctx = VIESN_MakeContext();
    XCTestExpectation *exp = [self expectationWithDescription:@"prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) { [exp fulfill]; }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];
    [_sut invalidate];
    XCTAssertFalse(_sut.ready);
}

// ─── TC-5D2-09: presentEnvelope on invalidated node is no-op ─────────────────

- (void)testTC_5D2_09_presentEnvelopeOnInvalidatedNodeIsNoOp {
    [_sut invalidate];
    CVPixelBufferRef pb = VIESN_CreateTestPixelBuffer(64, 64);
    VGFrameEnvelope env = VIESN_MakeEnvelope(pb);
    XCTAssertNoThrow([_sut presentEnvelope:env]);
    XCTAssertEqual(_sut.framesSubmitted, 0);
    if (pb) CVPixelBufferRelease(pb);
}

// ─── TC-5D2-10: JPEG encode creates valid non-empty file ─────────────────────

- (void)testTC_5D2_10_jpegEncodeCreatesFile {
    VGGraphExecutionContext *ctx = VIESN_MakeContext();
    XCTestExpectation *exp = [self expectationWithDescription:@"prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) {
        XCTAssertNil(err);
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    CVPixelBufferRef pb = VIESN_CreateTestPixelBuffer(64, 64);
    [_sut presentEnvelope:VIESN_MakeEnvelope(pb)];
    if (pb) CVPixelBufferRelease(pb);

    XCTAssertEqual(_sut.framesSubmitted, 1);
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:_outputURL.path];
    XCTAssertTrue(exists, @"TC-5D2-10: Output file must exist");
}

// ─── TC-5D2-11: PNG encode creates valid non-empty file ──────────────────────

- (void)testTC_5D2_11_pngEncodeCreatesFile {
    NSURL *pngURL = VIESN_TempOutputURL(@"png");
    VGImageExportProfile *pngProfile = [VGImageExportProfile pngProfile];
    VGImageEncoderSinkNode *pngSut = [[VGImageEncoderSinkNode alloc]
        initWithOutputURL:pngURL profile:pngProfile];

    VGGraphExecutionContext *ctx = VIESN_MakeContext();
    XCTestExpectation *exp = [self expectationWithDescription:@"prepare"];
    [pngSut prepareWithContext:ctx completion:^(NSError *err) {
        XCTAssertNil(err);
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    CVPixelBufferRef pb = VIESN_CreateTestPixelBuffer(64, 64);
    [pngSut presentEnvelope:VIESN_MakeEnvelope(pb)];
    if (pb) CVPixelBufferRelease(pb);

    XCTAssertEqual(pngSut.framesSubmitted, 1);
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:pngURL.path];
    XCTAssertTrue(exists, @"TC-5D2-11: PNG file must exist");

    [pngSut invalidate];
    [[NSFileManager defaultManager] removeItemAtURL:pngURL error:nil];
}

// ─── TC-5D2-12: HEIC encode succeeds or falls back ──────────────────────────

- (void)testTC_5D2_12_heicEncodeOrFallback {
    NSURL *heicURL = VIESN_TempOutputURL(@"heic");
    VGImageExportProfile *heicProfile = [VGImageExportProfile heicProfileWithQuality:0.9f];
    VGImageEncoderSinkNode *heicSut = [[VGImageEncoderSinkNode alloc]
        initWithOutputURL:heicURL profile:heicProfile];

    VGGraphExecutionContext *ctx = VIESN_MakeContext();
    XCTestExpectation *exp = [self expectationWithDescription:@"prepare"];
    [heicSut prepareWithContext:ctx completion:^(NSError *err) {
        XCTAssertNil(err, @"TC-5D2-12: prepare should succeed (HEIC or JPEG fallback)");
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    CVPixelBufferRef pb = VIESN_CreateTestPixelBuffer(64, 64);
    [heicSut presentEnvelope:VIESN_MakeEnvelope(pb)];
    if (pb) CVPixelBufferRelease(pb);

    // Should have encoded (either HEIC or fallback JPEG).
    XCTAssertEqual(heicSut.framesSubmitted, 1);

    NSError *err = nil;
    VGImageExportManifest *manifest = [heicSut finalizeExportWithError:&err];
    XCTAssertNotNil(manifest, @"TC-5D2-12: manifest must not be nil: %@", err);
    // Format must be either HEIC (if supported) or JPEG (fallback).
    XCTAssertTrue(manifest.format == VGImageEncodeFormatHEIC ||
                  manifest.format == VGImageEncodeFormatJPEG,
                  @"TC-5D2-12: format must be HEIC or JPEG");

    [heicSut invalidate];
    [[NSFileManager defaultManager] removeItemAtURL:heicURL error:nil];
}

// ─── TC-5D2-13: WebP resolves to HEIC/JPEG — no WebP encode attempt ─────────

- (void)testTC_5D2_13_webpResolvesToFallback {
    NSURL *webpURL = VIESN_TempOutputURL(@"img");
    VGImageExportProfile *webpProfile = [[VGImageExportProfile alloc]
        initWithFormat:VGImageEncodeFormatWebP
               quality:0.9f
    colorProfilePolicy:VGImageColorProfilePolicyPreserve
     orientationPolicy:VGImageOrientationPolicyPreserve];
    VGImageEncoderSinkNode *webpSut = [[VGImageEncoderSinkNode alloc]
        initWithOutputURL:webpURL profile:webpProfile];

    VGGraphExecutionContext *ctx = VIESN_MakeContext();
    XCTestExpectation *exp = [self expectationWithDescription:@"prepare"];
    [webpSut prepareWithContext:ctx completion:^(NSError *err) {
        // Should succeed — resolvedFormatForPlatform routes WebP → HEIC → JPEG.
        XCTAssertNil(err, @"TC-5D2-13: prepare should resolve WebP to supported format");
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    CVPixelBufferRef pb = VIESN_CreateTestPixelBuffer(64, 64);
    [webpSut presentEnvelope:VIESN_MakeEnvelope(pb)];
    if (pb) CVPixelBufferRelease(pb);

    NSError *err = nil;
    VGImageExportManifest *manifest = [webpSut finalizeExportWithError:&err];
    XCTAssertNotNil(manifest);
    // Must NOT be WebP.
    XCTAssertTrue(manifest.format != VGImageEncodeFormatWebP,
                  @"TC-5D2-13: format must NOT be WebP");

    [webpSut invalidate];
    [[NSFileManager defaultManager] removeItemAtURL:webpURL error:nil];
}

// ─── TC-5D2-14: Manifest fields match output ─────────────────────────────────

- (void)testTC_5D2_14_manifestFieldsMatchOutput {
    VGGraphExecutionContext *ctx = VIESN_MakeContext();
    XCTestExpectation *exp = [self expectationWithDescription:@"prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) { [exp fulfill]; }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    CVPixelBufferRef pb = VIESN_CreateTestPixelBuffer(64, 64);
    [_sut presentEnvelope:VIESN_MakeEnvelope(pb)];
    if (pb) CVPixelBufferRelease(pb);

    NSError *err = nil;
    VGImageExportManifest *manifest = [_sut finalizeExportWithError:&err];
    XCTAssertNotNil(manifest, @"TC-5D2-14: manifest: %@", err);
    XCTAssertEqual(manifest.format, VGImageEncodeFormatJPEG);
    XCTAssertEqual(manifest.width, 64);
    XCTAssertEqual(manifest.height, 64);
    XCTAssertGreaterThan(manifest.fileSizeBytes, 0);
    XCTAssertEqualWithAccuracy(manifest.quality, 0.85f, 0.001f);
    XCTAssertFalse(manifest.orientationApplied);
    XCTAssertTrue(manifest.colorSpace.length > 0,
                  @"TC-5D2-14: colorSpace should be non-empty");
}

// ─── TC-5D2-15: finalize before presentEnvelope fails ────────────────────────

- (void)testTC_5D2_15_finalizeBeforePresentFails {
    VGGraphExecutionContext *ctx = VIESN_MakeContext();
    XCTestExpectation *exp = [self expectationWithDescription:@"prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) { [exp fulfill]; }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    NSError *err = nil;
    VGImageExportManifest *manifest = [_sut finalizeExportWithError:&err];
    XCTAssertNil(manifest, @"TC-5D2-15: finalize must fail without a frame");
    XCTAssertNotNil(err);
}

// ─── TC-5D2-16: presentEnvelope before prepare is no-op ──────────────────────

- (void)testTC_5D2_16_presentBeforePrepareIsNoOp {
    CVPixelBufferRef pb = VIESN_CreateTestPixelBuffer(64, 64);
    XCTAssertNoThrow([_sut presentEnvelope:VIESN_MakeEnvelope(pb)]);
    XCTAssertEqual(_sut.framesSubmitted, 0);
    if (pb) CVPixelBufferRelease(pb);
}

// ─── TC-5D2-17: output file non-zero after finalize ─────────────────────────

- (void)testTC_5D2_17_outputFileNonZeroAfterFinalize {
    VGGraphExecutionContext *ctx = VIESN_MakeContext();
    XCTestExpectation *exp = [self expectationWithDescription:@"prepare"];
    [_sut prepareWithContext:ctx completion:^(NSError *err) { [exp fulfill]; }];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];

    CVPixelBufferRef pb = VIESN_CreateTestPixelBuffer(64, 64);
    [_sut presentEnvelope:VIESN_MakeEnvelope(pb)];
    if (pb) CVPixelBufferRelease(pb);

    VGImageExportManifest *manifest = [_sut finalizeExportWithError:nil];
    XCTAssertNotNil(manifest);
    XCTAssertGreaterThan(manifest.fileSizeBytes, 0);
}

// ─── TC-5D2-18: no scheduler coupling ────────────────────────────────────────

- (void)testTC_5D2_18_noSchedulerCoupling {
    XCTAssertFalse([_sut respondsToSelector:NSSelectorFromString(@"scheduleFrame:")]);
    XCTAssertFalse([_sut respondsToSelector:NSSelectorFromString(@"didReceiveRawFrame:")]);
    XCTAssertFalse([_sut isKindOfClass:NSClassFromString(@"VGGraphSchedulerV2")]);
}

@end
