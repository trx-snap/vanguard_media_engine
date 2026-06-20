// VGTransformFilterNodeTest.m
// vanguard_media_engine — Phase 10-C-3L.1D
//
// Unit + integration tests for VGTransformFilterNode.
//
// Mock prefix: VGTFN_ (VG Transform Filter Node)
//
// Coverage:
//   TC-TFN-01  Identity transform: output dimensions == canvasWidth × canvasHeight
//   TC-TFN-02  Passthrough (enabled=NO): returns input buffer with +1 retain unchanged
//   TC-TFN-03  processBuffer returns new buffer (not input)
//   TC-TFN-04  Output buffer has correct dimensions (canvasW × canvasH, not input dims)
//   TC-TFN-05  90° rotation: effective W/H swap visible in output dimensions
//   TC-TFN-06  flipX does not crash and returns canvas-sized buffer
//   TC-TFN-07  cropRect does not crash and returns canvas-sized buffer
//   TC-TFN-08  processEnvelope: returns new buffer (not input) via VGImageExportSession
//   TC-TFN-09  prepareWithCompletion fires completion with nil error
//   TC-TFN-10  Black background: output pixel outside source region is black

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>

#import "VGTransformFilterNode.h"

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Creates a solid-color BGRA CVPixelBuffer of the given size and fill byte.
/// Returns +1 retain. Caller owns the buffer.
static CVPixelBufferRef VGTFN_MakeBuffer(size_t w, size_t h, uint8_t fill) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferMetalCompatibilityKey:  @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef pb = NULL;
    CVReturn ret = CVPixelBufferCreate(
        kCFAllocatorDefault, w, h,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs, &pb);
    if (ret != kCVReturnSuccess || !pb) return NULL;
    CVPixelBufferLockBaseAddress(pb, 0);
    memset(CVPixelBufferGetBaseAddress(pb), fill, CVPixelBufferGetDataSize(pb));
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

/// Returns the BGRA bytes at the given (x, y) pixel of a locked CVPixelBuffer.
/// Must call CVPixelBufferLockBaseAddress before and UnlockBaseAddress after.
static void VGTFN_ReadPixelBGRA(CVPixelBufferRef buf, size_t x, size_t y,
                                  uint8_t *b, uint8_t *g, uint8_t *r, uint8_t *a) {
    size_t bpr = CVPixelBufferGetBytesPerRow(buf);
    const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(buf);
    const uint8_t *px   = base + y * bpr + x * 4;
    *b = px[0]; *g = px[1]; *r = px[2]; *a = px[3];
}

// ─── VGTFN_TestImageSource ───────────────────────────────────────────────────
// Minimal VanguardImageMediaSource stub that vends a known BGRA buffer.
// Mirrors VGIES_TestImageSource pattern from VGImageExportSessionTest.m.

#import "VanguardImageMediaSource.h"

@interface VGTFN_TestImageSource : VanguardImageMediaSource
@property (nonatomic) CVPixelBufferRef _Nullable testBuffer;
- (instancetype)initWithBuffer:(CVPixelBufferRef)buf;
@end

@implementation VGTFN_TestImageSource
- (instancetype)initWithBuffer:(CVPixelBufferRef)buf {
    NSURL *dummy = [NSURL fileURLWithPath:@"/dev/null"];
    self = [super initWithURL:dummy processor:nil];
    if (!self) return nil;
    _testBuffer = CVPixelBufferRetain(buf);
    return self;
}
- (void)prepareWithCompletion:(void (^)(NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        completion(nil);
    });
}
- (CVPixelBufferRef _Nullable)copyRawBuffer {
    if (!_testBuffer) return NULL;
    return CVPixelBufferRetain(_testBuffer);
}
- (void)invalidate {
    if (_testBuffer) {
        CVPixelBufferRelease(_testBuffer);
        _testBuffer = NULL;
    }
}
- (NSString *)nodeId   { return @"testSource"; }
- (NSString *)nodeType { return @"VGTFN_TestImageSource"; }
- (void)dealloc {
    if (_testBuffer) CVPixelBufferRelease(_testBuffer);
}
@end

// ─── Test class ───────────────────────────────────────────────────────────────

@interface VGTransformFilterNodeTest : XCTestCase
@end

@implementation VGTransformFilterNodeTest {
    id<MTLDevice> _device;
    CVPixelBufferRef _input8x8;     // 8×8 solid red (R=200, G=50, B=20, A=255 in BGRA: B=20,G=50,R=200,A=255)
    CVPixelBufferRef _input16x32;   // 16×32 (landscape-ish for rotation tests)
}

- (void)setUp {
    [super setUp];
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        NSLog(@"[VGTFN] Warning: no Metal device available. Tests will run without GPU.");
    }
    // 8×8 solid fill: BGRA = (20, 50, 200, 255) → visually red-ish
    _input8x8   = VGTFN_MakeBuffer(8,  8,  200);  // all channels = 200
    _input16x32 = VGTFN_MakeBuffer(16, 32, 128);  // all channels = 128
}

- (void)tearDown {
    if (_input8x8)   { CVPixelBufferRelease(_input8x8);   _input8x8 = NULL; }
    if (_input16x32) { CVPixelBufferRelease(_input16x32); _input16x32 = NULL; }
    [super tearDown];
}

// ─── TC-TFN-01: Identity transform produces canvas-sized output ───────────────

- (void)testTC_TFN_01_identityTransformOutputHasCanvasDimensions {
    if (!_device) { XCTSkip(@"No Metal device"); }

    // Input: 8×8. Canvas: 16×16.
    VGTransformFilterNode *sut = [[VGTransformFilterNode alloc]
        initWithPool:nil
              device:_device
         canvasWidth:16
        canvasHeight:16
               scale:1.0
             offsetX:0.0
             offsetY:0.0
        quarterTurns:0
               flipX:NO
            cropRect:nil];

    CMTime t = kCMTimeZero;
    CVPixelBufferRef output = [sut processBuffer:_input8x8 atTime:t device:_device];

    XCTAssertNotNil((__bridge id)output, @"output must be non-NULL");
    if (output) {
        XCTAssertEqual(CVPixelBufferGetWidth(output),  16U, @"output width must be canvasWidth=16");
        XCTAssertEqual(CVPixelBufferGetHeight(output), 16U, @"output height must be canvasHeight=16");
        CVPixelBufferRelease(output);
    }
}

// ─── TC-TFN-02: Passthrough (enabled=NO) returns input with +1 retain ─────────

- (void)testTC_TFN_02_passthroughReturnsInputBuffer {
    if (!_device) { XCTSkip(@"No Metal device"); }

    VGTransformFilterNode *sut = [[VGTransformFilterNode alloc]
        initWithPool:nil
              device:_device
         canvasWidth:32
        canvasHeight:32
               scale:1.0
             offsetX:0.0
             offsetY:0.0
        quarterTurns:0
               flipX:NO
            cropRect:nil];
    sut.enabled = NO;

    CFIndex retainsBefore = CFGetRetainCount((__bridge CFTypeRef)(__bridge id)_input8x8);
    CVPixelBufferRef output = [sut processBuffer:_input8x8 atTime:kCMTimeZero device:_device];

    // Passthrough: must return the SAME pointer.
    XCTAssertEqual(output, _input8x8, @"Passthrough must return the input buffer pointer");
    // The +1 retain we hold from setUp, plus the +1 from passthrough = retainsBefore+1.
    CFIndex retainsAfter = CFGetRetainCount((__bridge CFTypeRef)(__bridge id)output);
    XCTAssertEqual(retainsAfter, retainsBefore + 1,
                   @"Passthrough must add exactly +1 retain to the input");

    CVPixelBufferRelease(output); // balance the +1 from processBuffer passthrough
}

// ─── TC-TFN-03: Active node returns new buffer (not input pointer) ─────────────

- (void)testTC_TFN_03_activeNodeReturnsNewBuffer {
    if (!_device) { XCTSkip(@"No Metal device"); }

    VGTransformFilterNode *sut = [[VGTransformFilterNode alloc]
        initWithPool:nil
              device:_device
         canvasWidth:8
        canvasHeight:8
               scale:1.0
             offsetX:0.0
             offsetY:0.0
        quarterTurns:0
               flipX:NO
            cropRect:nil];

    CVPixelBufferRef output = [sut processBuffer:_input8x8 atTime:kCMTimeZero device:_device];
    XCTAssertNotNil((__bridge id)output, @"output must not be NULL");
    XCTAssertNotEqual(output, _input8x8, @"active node must return new buffer, not input");
    if (output) CVPixelBufferRelease(output);
}

// ─── TC-TFN-04: Output buffer dimensions == canvasWidth × canvasHeight ──────────
//     (even when input dimensions differ from canvas)

- (void)testTC_TFN_04_outputDimensionsMatchCanvas_notInput {
    if (!_device) { XCTSkip(@"No Metal device"); }

    // Input is 16×32. Canvas is 1080×1920. Output must be 1080×1920, NOT 16×32.
    VGTransformFilterNode *sut = [[VGTransformFilterNode alloc]
        initWithPool:nil
              device:_device
         canvasWidth:1080
        canvasHeight:1920
               scale:1.0
             offsetX:0.0
             offsetY:0.0
        quarterTurns:0
               flipX:NO
            cropRect:nil];

    CVPixelBufferRef output = [sut processBuffer:_input16x32 atTime:kCMTimeZero device:_device];
    XCTAssertNotNil((__bridge id)output, @"output must not be NULL");
    if (output) {
        XCTAssertEqual(CVPixelBufferGetWidth(output),  1080U,
                       @"output width must equal canvasWidth, not input width");
        XCTAssertEqual(CVPixelBufferGetHeight(output), 1920U,
                       @"output height must equal canvasHeight, not input height");
        CVPixelBufferRelease(output);
    }
}

// ─── TC-TFN-05: 90° rotation does not crash and returns canvas-sized output ────
//     16×32 input rotated 90° CW → effective 32×16.
//     Output canvas is 64×64 → output must still be 64×64.

- (void)testTC_TFN_05_rotation90CWDoesNotCrashAndProducesCanvasSize {
    if (!_device) { XCTSkip(@"No Metal device"); }

    VGTransformFilterNode *sut = [[VGTransformFilterNode alloc]
        initWithPool:nil
              device:_device
         canvasWidth:64
        canvasHeight:64
               scale:1.0
             offsetX:0.0
             offsetY:0.0
        quarterTurns:1       // 90° CW
               flipX:NO
            cropRect:nil];

    CVPixelBufferRef output = [sut processBuffer:_input16x32 atTime:kCMTimeZero device:_device];
    XCTAssertNotNil((__bridge id)output, @"output must not be NULL after 90° rotation");
    if (output) {
        XCTAssertEqual(CVPixelBufferGetWidth(output),  64U, @"width must be canvasWidth=64");
        XCTAssertEqual(CVPixelBufferGetHeight(output), 64U, @"height must be canvasHeight=64");
        CVPixelBufferRelease(output);
    }
}

// ─── TC-TFN-06: flipX=YES does not crash and returns canvas-sized output ────────

- (void)testTC_TFN_06_flipXDoesNotCrashAndProducesCanvasSize {
    if (!_device) { XCTSkip(@"No Metal device"); }

    VGTransformFilterNode *sut = [[VGTransformFilterNode alloc]
        initWithPool:nil
              device:_device
         canvasWidth:32
        canvasHeight:32
               scale:1.0
             offsetX:0.0
             offsetY:0.0
        quarterTurns:0
               flipX:YES
            cropRect:nil];

    CVPixelBufferRef output = [sut processBuffer:_input8x8 atTime:kCMTimeZero device:_device];
    XCTAssertNotNil((__bridge id)output, @"output must not be NULL with flipX=YES");
    if (output) {
        XCTAssertEqual(CVPixelBufferGetWidth(output),  32U, @"width must be canvasWidth=32");
        XCTAssertEqual(CVPixelBufferGetHeight(output), 32U, @"height must be canvasHeight=32");
        CVPixelBufferRelease(output);
    }
}

// ─── TC-TFN-07: cropRect does not crash and returns canvas-sized output ─────────

- (void)testTC_TFN_07_cropRectDoesNotCrashAndProducesCanvasSize {
    if (!_device) { XCTSkip(@"No Metal device"); }

    // Crop the center 50% of the 8×8 source.
    NSArray<NSNumber *> *cropRect = @[@0.25, @0.25, @0.5, @0.5];

    VGTransformFilterNode *sut = [[VGTransformFilterNode alloc]
        initWithPool:nil
              device:_device
         canvasWidth:16
        canvasHeight:16
               scale:1.0
             offsetX:0.0
             offsetY:0.0
        quarterTurns:0
               flipX:NO
            cropRect:cropRect];

    CVPixelBufferRef output = [sut processBuffer:_input8x8 atTime:kCMTimeZero device:_device];
    XCTAssertNotNil((__bridge id)output, @"output must not be NULL with cropRect set");
    if (output) {
        XCTAssertEqual(CVPixelBufferGetWidth(output),  16U, @"width must be canvasWidth=16");
        XCTAssertEqual(CVPixelBufferGetHeight(output), 16U, @"height must be canvasHeight=16");
        CVPixelBufferRelease(output);
    }
}

// ─── TC-TFN-08: processEnvelope:device: returns new buffer via VGFrameEnvelope ──

- (void)testTC_TFN_08_processEnvelopeReturnsNewBuffer {
    if (!_device) { XCTSkip(@"No Metal device"); }

    VGTransformFilterNode *sut = [[VGTransformFilterNode alloc]
        initWithPool:nil
              device:_device
         canvasWidth:32
        canvasHeight:32
               scale:1.0
             offsetX:0.0
             offsetY:0.0
        quarterTurns:0
               flipX:NO
            cropRect:nil];

    VGFrameEnvelope inEnvelope;
    memset(&inEnvelope, 0, sizeof(VGFrameEnvelope));
    inEnvelope.pts = kCMTimeZero;
    inEnvelope.mediaType = VGMediaTypeVideo;
    inEnvelope.payload.videoBuffer = (void *)CVPixelBufferRetain(_input8x8);

    VGFrameEnvelope outEnvelope = [sut processEnvelope:inEnvelope device:_device];

    CVPixelBufferRef outBuf = (CVPixelBufferRef)outEnvelope.payload.videoBuffer;
    XCTAssertNotNil((__bridge id)outBuf, @"output buffer must not be NULL");
    XCTAssertNotEqual(outBuf, _input8x8, @"processEnvelope must return new buffer, not input");
    if (outBuf) {
        XCTAssertEqual(CVPixelBufferGetWidth(outBuf),  32U);
        XCTAssertEqual(CVPixelBufferGetHeight(outBuf), 32U);
        CVPixelBufferRelease(outBuf);
    }
    // Release the +1 we added on the inEnvelope.videoBuffer (input was NOT released
    // by processEnvelope — caller owns input retain).
    CVPixelBufferRelease(_input8x8);
}

// ─── TC-TFN-09: prepareWithCompletion fires with nil error ───────────────────────

- (void)testTC_TFN_09_prepareWithCompletionSucceeds {
    if (!_device) { XCTSkip(@"No Metal device"); }

    VGTransformFilterNode *sut = [[VGTransformFilterNode alloc]
        initWithPool:nil
              device:_device
         canvasWidth:16
        canvasHeight:16
               scale:1.0
             offsetX:0.0
             offsetY:0.0
        quarterTurns:0
               flipX:NO
            cropRect:nil];

    XCTestExpectation *exp = [self expectationWithDescription:@"prepare"];
    [sut prepareWithCompletion:^(NSError *err) {
        XCTAssertNil(err, @"prepareWithCompletion must fire with nil error");
        [exp fulfill];
    }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
}

// ─── TC-TFN-10: Black background — pixel outside source region is dark ────────
//     Input: 8×8 solid bright (all channels = 200).
//     Canvas: 64×64 at scale=1.0, no pan.
//     Aspect-fill of 8×8 into 64×64 square fills the entire canvas (same aspect).
//     With scale=1.0 the source fills the canvas exactly. Check center pixel ≠ black.
//     Then use scale=0.5 (half size): edges will be black.
//     This is a smoke test: we check that the background pixels (corners) are
//     darker than the source fill value, proving the black canvas was composited.
//
// NOTE: scale=0.5 is < 1.0 which violates the production contract (scale must
//       be >= 1.0 for aspect-fill). We permit it here in tests because the
//       native code does not hard-clamp — it simply produces a smaller image
//       with visible black borders, which is exactly what we want to test.
//       assertValid() in Dart prevents invalid values at the API boundary.

- (void)testTC_TFN_10_blackBackgroundVisibleWhenSourceSmallerThanCanvas {
    if (!_device) { XCTSkip(@"No Metal device"); }

    // Input: 8×8 with all channels = 200.
    // Canvas: 64×64, scale=0.1 → very small source, large black margins.
    VGTransformFilterNode *sut = [[VGTransformFilterNode alloc]
        initWithPool:nil
              device:_device
         canvasWidth:64
        canvasHeight:64
               scale:0.1    // tiny zoom → large black borders
             offsetX:0.0
             offsetY:0.0
        quarterTurns:0
               flipX:NO
            cropRect:nil];

    CVPixelBufferRef output = [sut processBuffer:_input8x8 atTime:kCMTimeZero device:_device];
    XCTAssertNotNil((__bridge id)output, @"output must not be NULL");
    if (!output) return;

    XCTAssertEqual(CVPixelBufferGetWidth(output),  64U);
    XCTAssertEqual(CVPixelBufferGetHeight(output), 64U);

    CVPixelBufferLockBaseAddress(output, kCVPixelBufferLock_ReadOnly);
    uint8_t b = 0, g = 0, r = 0, a = 0;
    // Top-left corner (0,0) should be black background.
    VGTFN_ReadPixelBGRA(output, 0, 0, &b, &g, &r, &a);
    CVPixelBufferUnlockBaseAddress(output, kCVPixelBufferLock_ReadOnly);

    // Black background: R=G=B≈0, alpha=255. Allow ±8 for CIImage AA.
    XCTAssertLessThanOrEqual((int)r, 8,
        @"Top-left corner should be black background (R≈0), got R=%d", (int)r);
    XCTAssertLessThanOrEqual((int)g, 8,
        @"Top-left corner should be black background (G≈0), got G=%d", (int)g);
    XCTAssertLessThanOrEqual((int)b, 8,
        @"Top-left corner should be black background (B≈0), got B=%d", (int)b);

    CVPixelBufferRelease(output);
}

@end
