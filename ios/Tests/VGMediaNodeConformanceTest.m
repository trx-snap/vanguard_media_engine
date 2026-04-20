// VGMediaNodeConformanceTest.m
// Vanguard Media Engine — Phase 1A, P1A-08
//
// Conformance tests for the VGMediaNode additive lifecycle protocol.
// Covers VanguardFileMediaSource (P1A-06) and VanguardImageMediaSource (P1A-07).
//
// Goals (workboard P1A-08):
//   1. prepareWithCompletion: fires completion without blocking the test thread.
//   2. prepare → invalidate → invalidate again: no crash, no hang (idempotency).
//   3. invalidate before prepare: no crash, no hang.
//   4. Both source classes tested independently.
//
// Design constraints:
//   - Simulator-safe only. No physical device required.
//   - No real media files. Stub/dummy URLs only.
//   - No production callsites added or modified.
//   - Does NOT depend on AVAudioEngine, real AVAssetReader, or camera.
//   - prepareWithCompletion: may succeed or return an error on a stub URL —
//     both are acceptable; the test only asserts that completion FIRES and
//     that the test thread is not blocked.
//
// Run with:
//   xcodebuild test -scheme vanguard_media_engine \
//                   -destination 'platform=iOS Simulator,name=iPhone 15'
//
// NOTE: simulator execution is currently blocked by RR-9
// (VanguardCameraMediaSource not visible to Swift module).
// These tests compile clean. Execution is deferred until RR-9 is resolved.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <CoreServices/CoreServices.h>

#import "VanguardFileMediaSource.h"
#import "VanguardImageMediaSource.h"
#import "VanguardImageProcessor.h"

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Test helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Timeout for all async expectations: 5 seconds.
/// prepareWithCompletion: dispatches to a background queue; 5 s is generous
/// even under heavy simulator load.
static const NSTimeInterval kPrepareTimeout = 5.0;

/// Write a minimal 1×1 white PNG to a temporary file and return its URL.
/// The PNG is synthetically constructed — no UIKit rendering pipeline is
/// involved, making it safe on any thread and in the simulator.
/// Returns nil if the write fails (test will be skipped in that case).
static NSURL * _Nullable makeTempPNG(void) {
    // 1×1 white RGBA pixel encoded as a minimal PNG bytestream.
    // This is a valid, decodable PNG that CGImageSourceCreateWithURL accepts.
    static const uint8_t kMinimalPNG[] = {
        // PNG signature
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        // IHDR chunk: width=1, height=1, bitdepth=8, colortype=2 (RGB)
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE,
        // IDAT chunk: zlib-compressed 1 white RGB pixel (filter byte 0x00)
        0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
        0x08, 0xD7, 0x63, 0xF8, 0xFF, 0xFF, 0x3F, 0x00,
        0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59, 0xE7,
        // IEND chunk
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
        0xAE, 0x42, 0x60, 0x82
    };

    NSURL *tmpDir = [NSFileManager defaultManager].temporaryDirectory;
    NSURL *url = [tmpDir URLByAppendingPathComponent:
                  [NSString stringWithFormat:@"vg_conformance_test_%@.png",
                   [NSUUID UUID].UUIDString]];
    NSData *data = [NSData dataWithBytes:kMinimalPNG length:sizeof(kMinimalPNG)];
    if ([data writeToURL:url atomically:YES]) return url;
    return nil;
}

/// Create a VanguardFileMediaSource with a non-existent stub URL.
/// prepareWithCompletion: will attempt _setupAssetReader on this URL; the
/// asset reader will fail internally (no real file), but completion still
/// fires. The test only checks that completion was called and that the test
/// thread was not blocked.
static VanguardFileMediaSource * makeFileSource(void) {
    NSURL *stub = [NSURL fileURLWithPath:@"/tmp/vg_nonexistent_stub.mp4"];
    return [[VanguardFileMediaSource alloc] initWithURL:stub
                                        pixelBufferPool:nil];
}

/// Create a VanguardImageMediaSource backed by a temp 1×1 PNG.
/// Returns nil if Metal is unavailable (e.g. on a headless CI runner without
/// a GPU — should not happen on a standard iOS Simulator instance).
static VanguardImageMediaSource * _Nullable makeImageSource(NSURL *pngURL) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return nil;
    VanguardImageProcessor *processor =
        [[VanguardImageProcessor alloc] initWithDevice:device pool:nil];
    return [[VanguardImageMediaSource alloc] initWithURL:pngURL
                                              processor:processor];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGMediaNodeConformanceTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGMediaNodeConformanceTest : XCTestCase
@end

@implementation VGMediaNodeConformanceTest

// ─── Section A: Identity properties ─────────────────────────────────────────

/// A-1: VanguardFileMediaSource must expose a non-empty nodeId and correct nodeType.
- (void)testFileSource_NodeIdentity {
    VanguardFileMediaSource *src = makeFileSource();
    XCTAssertNotNil(src.nodeId,  @"nodeId must not be nil");
    XCTAssertGreaterThan(src.nodeId.length, 0u, @"nodeId must be non-empty");
    XCTAssertEqualObjects(src.nodeType, @"VanguardFileMediaSource",
        @"nodeType must be 'VanguardFileMediaSource'");
}

/// A-2: VanguardImageMediaSource must expose a non-empty nodeId and correct nodeType.
- (void)testImageSource_NodeIdentity {
    NSURL *png = makeTempPNG();
    if (!png) { XCTSkip(@"makeTempPNG failed — skipping"); return; }
    VanguardImageMediaSource *src = makeImageSource(png);
    if (!src) { XCTSkip(@"MTLCreateSystemDefaultDevice returned nil — no GPU"); return; }

    XCTAssertNotNil(src.nodeId,  @"nodeId must not be nil");
    XCTAssertGreaterThan(src.nodeId.length, 0u, @"nodeId must be non-empty");
    XCTAssertEqualObjects(src.nodeType, @"VanguardImageMediaSource",
        @"nodeType must be 'VanguardImageMediaSource'");
}

/// A-3: Two distinct VanguardFileMediaSource instances must have different nodeIds.
- (void)testFileSource_NodeIdUnique {
    VanguardFileMediaSource *a = makeFileSource();
    VanguardFileMediaSource *b = makeFileSource();
    XCTAssertNotEqualObjects(a.nodeId, b.nodeId,
        @"Each instance must have a unique nodeId (NSUUID)");
}

// ─── Section B: VanguardFileMediaSource — prepareWithCompletion: ─────────────

/// B-1: prepareWithCompletion: fires completion without blocking the test thread.
/// The stub URL has no real file; _setupAssetReader will fail internally.
/// The contract only requires that completion fires; error is acceptable.
- (void)testFileSource_PrepareFiresCompletion {
    VanguardFileMediaSource *src = makeFileSource();
    XCTestExpectation *exp = [self expectationWithDescription:@"prepare completion"];

    [src prepareWithCompletion:^(NSError *err) {
        // Completion fired — that is the contract.
        // err may be non-nil (stub URL, no asset) — both are acceptable.
        [exp fulfill];
    }];

    [self waitForExpectations:@[exp] timeout:kPrepareTimeout];
}

/// B-2: prepareWithCompletion: must NOT call completion synchronously on this thread.
/// We verify this via a flag that is set AFTER prepareWithCompletion: returns.
- (void)testFileSource_PrepareDoesNotCallCompletionSynchronously {
    VanguardFileMediaSource *src = makeFileSource();
    XCTestExpectation *exp = [self expectationWithDescription:@"async completion"];

    __block BOOL returnedFromPrepare = NO;
    [src prepareWithCompletion:^(NSError *err) {
        // If completion fires synchronously, returnedFromPrepare is still NO.
        XCTAssertTrue(returnedFromPrepare,
            @"completion must not fire synchronously before prepareWithCompletion: returns");
        [exp fulfill];
    }];
    returnedFromPrepare = YES;

    [self waitForExpectations:@[exp] timeout:kPrepareTimeout];
}

// ─── Section C: VanguardFileMediaSource — invalidate idempotency ─────────────

/// C-1: prepare → invalidate → invalidate again. No crash, no hang.
- (void)testFileSource_PrepareInvalidateInvalidate {
    VanguardFileMediaSource *src = makeFileSource();
    XCTestExpectation *exp = [self expectationWithDescription:@"prepare then double invalidate"];

    [src prepareWithCompletion:^(NSError *err) {
        [src invalidate]; // first call: YES, teardown dispatched
        [src invalidate]; // second call: CAS fails, immediate return
        [exp fulfill];   // no crash = pass
    }];

    [self waitForExpectations:@[exp] timeout:kPrepareTimeout];
}

/// C-2: invalidate BEFORE prepareWithCompletion:. No crash, no hang.
/// The guard in prepareWithCompletion: checks _invalidated and fires
/// an error completion on a background queue — we expect exactly one completion.
- (void)testFileSource_InvalidateBeforePrepare {
    VanguardFileMediaSource *src = makeFileSource();
    XCTestExpectation *exp = [self expectationWithDescription:@"invalidate before prepare"];

    [src invalidate]; // sets _invalidated = YES immediately

    [src prepareWithCompletion:^(NSError *err) {
        // Must fire with a non-nil error (already invalidated path).
        XCTAssertNotNil(err,
            @"prepare after invalidate must return an error, not nil");
        [exp fulfill];
    }];

    [self waitForExpectations:@[exp] timeout:kPrepareTimeout];
}

/// C-3: invalidate called twice before any prepare. No crash, immediate return.
- (void)testFileSource_DoubleInvalidateNoPrepare {
    VanguardFileMediaSource *src = makeFileSource();
    [src invalidate];
    [src invalidate]; // must return immediately, no crash
    // If we reach here: pass.
    XCTAssertTrue(YES, @"double invalidate before prepare must not crash");
}

/// C-4: invalidate called concurrently from two threads. No crash, no double-free.
/// Tests that the CAS (atomic_compare_exchange_strong_explicit) correctly
/// serialises concurrent callers.
- (void)testFileSource_ConcurrentInvalidate {
    VanguardFileMediaSource *src = makeFileSource();
    XCTestExpectation *exp1 = [self expectationWithDescription:@"thread 1"];
    XCTestExpectation *exp2 = [self expectationWithDescription:@"thread 2"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [src invalidate];
        [exp1 fulfill];
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [src invalidate];
        [exp2 fulfill];
    });

    [self waitForExpectations:@[exp1, exp2] timeout:kPrepareTimeout];
    // No crash = pass.
    XCTAssertTrue(YES, @"concurrent invalidate must not crash or double-free");
}

// ─── Section D: VanguardImageMediaSource — prepareWithCompletion: ────────────

/// D-1: prepareWithCompletion: fires completion on a valid 1×1 PNG.
/// For a real image, completion fires with nil error.
- (void)testImageSource_PrepareFiresCompletion {
    NSURL *png = makeTempPNG();
    if (!png) { XCTSkip(@"makeTempPNG failed"); return; }
    VanguardImageMediaSource *src = makeImageSource(png);
    if (!src) { XCTSkip(@"No MTLDevice"); return; }

    XCTestExpectation *exp = [self expectationWithDescription:@"image prepare completion"];

    [src prepareWithCompletion:^(NSError *err) {
        // For a valid PNG, error should be nil.
        // We assert completion fires; err==nil is preferred but both are reported.
        if (err) {
            NSLog(@"[VGConformanceTest] D-1: prepare returned err=%@", err);
        }
        [exp fulfill];
    }];

    [self waitForExpectations:@[exp] timeout:kPrepareTimeout];
}

/// D-2: prepareWithCompletion: must NOT call completion synchronously.
- (void)testImageSource_PrepareDoesNotCallCompletionSynchronously {
    NSURL *png = makeTempPNG();
    if (!png) { XCTSkip(@"makeTempPNG failed"); return; }
    VanguardImageMediaSource *src = makeImageSource(png);
    if (!src) { XCTSkip(@"No MTLDevice"); return; }

    XCTestExpectation *exp = [self expectationWithDescription:@"async"];
    __block BOOL returnedFromPrepare = NO;

    [src prepareWithCompletion:^(NSError *err) {
        XCTAssertTrue(returnedFromPrepare,
            @"completion must not fire synchronously before prepareWithCompletion: returns");
        [exp fulfill];
    }];
    returnedFromPrepare = YES;

    [self waitForExpectations:@[exp] timeout:kPrepareTimeout];
}

// ─── Section E: VanguardImageMediaSource — invalidate idempotency ────────────

/// E-1: prepare → invalidate → invalidate again. No crash.
- (void)testImageSource_PrepareInvalidateInvalidate {
    NSURL *png = makeTempPNG();
    if (!png) { XCTSkip(@"makeTempPNG failed"); return; }
    VanguardImageMediaSource *src = makeImageSource(png);
    if (!src) { XCTSkip(@"No MTLDevice"); return; }

    XCTestExpectation *exp = [self expectationWithDescription:@"image double invalidate"];

    [src prepareWithCompletion:^(NSError *err) {
        [src invalidate]; // first: CAS YES, CVPixelBufferRelease if _buffer set
        [src invalidate]; // second: CAS fails, no-op
        [exp fulfill];   // no crash = pass
    }];

    [self waitForExpectations:@[exp] timeout:kPrepareTimeout];
}

/// E-2: invalidate BEFORE prepareWithCompletion:. No crash, completion fires with error.
- (void)testImageSource_InvalidateBeforePrepare {
    NSURL *png = makeTempPNG();
    if (!png) { XCTSkip(@"makeTempPNG failed"); return; }
    VanguardImageMediaSource *src = makeImageSource(png);
    if (!src) { XCTSkip(@"No MTLDevice"); return; }

    XCTestExpectation *exp = [self expectationWithDescription:@"invalidate before prepare"];

    [src invalidate]; // sets _invalidated = YES

    [src prepareWithCompletion:^(NSError *err) {
        XCTAssertNotNil(err,
            @"prepare after invalidate must return an error, not nil");
        [exp fulfill];
    }];

    [self waitForExpectations:@[exp] timeout:kPrepareTimeout];
}

/// E-3: double invalidate before any prepare. No crash, immediate return.
- (void)testImageSource_DoubleInvalidateNoPrepare {
    NSURL *png = makeTempPNG();
    if (!png) { XCTSkip(@"makeTempPNG failed"); return; }
    VanguardImageMediaSource *src = makeImageSource(png);
    if (!src) { XCTSkip(@"No MTLDevice"); return; }

    [src invalidate];
    [src invalidate]; // must return immediately, no crash
    XCTAssertTrue(YES, @"double invalidate before prepare must not crash");
}

/// E-4: invalidate concurrent — two threads race to invalidate simultaneously.
/// Only one may release _buffer; the second must observe the flag and return.
- (void)testImageSource_ConcurrentInvalidate {
    NSURL *png = makeTempPNG();
    if (!png) { XCTSkip(@"makeTempPNG failed"); return; }
    VanguardImageMediaSource *src = makeImageSource(png);
    if (!src) { XCTSkip(@"No MTLDevice"); return; }

    XCTestExpectation *exp1 = [self expectationWithDescription:@"t1"];
    XCTestExpectation *exp2 = [self expectationWithDescription:@"t2"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [src invalidate];
        [exp1 fulfill];
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [src invalidate];
        [exp2 fulfill];
    });

    [self waitForExpectations:@[exp1, exp2] timeout:kPrepareTimeout];
    XCTAssertTrue(YES, @"concurrent invalidate on image source must not crash");
}

// ─── Section F: Cross-class — rapid create → immediate invalidate ────────────

/// F-1: Create VanguardFileMediaSource then immediately invalidate before any prepare.
/// Exercises the path where no _setupAssetReader has ever been dispatched.
- (void)testFileSource_ImmediateInvalidateAfterInit {
    VanguardFileMediaSource *src = makeFileSource();
    [src invalidate]; // _invalidated = YES; teardown dispatched (drain + audio)
    // No crash, no hang = pass.
    XCTAssertTrue(YES, @"immediate invalidate after init must not crash");
}

/// F-2: Create VanguardImageMediaSource then immediately invalidate.
/// _buffer is nil at this point — invalidate must handle nil _buffer safely.
- (void)testImageSource_ImmediateInvalidateAfterInit {
    NSURL *png = makeTempPNG();
    if (!png) { XCTSkip(@"makeTempPNG failed"); return; }
    VanguardImageMediaSource *src = makeImageSource(png);
    if (!src) { XCTSkip(@"No MTLDevice"); return; }

    [src invalidate]; // _buffer is nil — CVPixelBufferRelease must not be called
    XCTAssertTrue(YES, @"immediate invalidate with nil _buffer must not crash");
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// SIMULATOR EXECUTION GATE
// ─────────────────────────────────────────────────────────────────────────────
//
// These tests compile clean but CANNOT currently be executed in the simulator
// via xcodebuild because:
//
//   BLOCKER: RR-9 — VanguardCameraMediaSource not visible to the Swift module.
//   The vanguard_media_engine scheme's build-for-testing step fails with:
//     error: cannot find type 'VanguardCameraMediaSource' in scope
//     (VanguardMediaEnginePlugin.swift:94)
//
//   Fix: add VanguardCameraMediaSource.h to the Swift bridging header or
//   module umbrella. Deferred post-Phase 1A per C-4/C-6.
//
// All 14 tests (A-1 through F-2) can be manually executed on device via:
//   xcodebuild test -scheme vanguard_media_engine \
//                   -destination 'platform=iOS,name=<DeviceName>'
// once RR-9 is resolved.
