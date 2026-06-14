// VGLiteRTMaskProviderTest.m
// Phase 9B-2 — VGLiteRTMaskProvider unit tests.
//
// Tests cover: protocol conformance, bad model URL fallback, bundled model
// load and tensor validation, frame submission non-blocking contract,
// idempotent invalidation, fallback delegation, generation reset safety,
// and unsupported pixel format safety.
//
// The real bundled .tflite model is used for load/tensor-validation tests.
// Frame submission tests use synthetic CVPixelBufferRef inputs.
// No TFLite API is called directly from test code.

#import <XCTest/XCTest.h>
#import "VGLiteRTMaskProvider.h"
#import "VGMaskProvider.h"
#import "VGMLModelBundle.h"
#import "VGSkinMaskGenerator.h"   // VGSkinMask definition
#import <CoreVideo/CoreVideo.h>

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Creates a synthetic CVPixelBuffer of given format, filled with a grey value.
static CVPixelBufferRef _makeSyntheticBuffer(size_t w, size_t h, OSType fmt) {
    CVPixelBufferRef buf = NULL;
    NSDictionary *attrs = @{ (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVReturn rc = CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt,
                                      (__bridge CFDictionaryRef)attrs, &buf);
    if (rc != kCVReturnSuccess || !buf) return NULL;

    CVPixelBufferLockBaseAddress(buf, 0);

    if (fmt == kCVPixelFormatType_32BGRA || fmt == kCVPixelFormatType_32RGBA) {
        size_t bpr = CVPixelBufferGetBytesPerRow(buf);
        uint8_t *p = (uint8_t *)CVPixelBufferGetBaseAddress(buf);
        if (p) {
            for (size_t y = 0; y < h; y++) {
                for (size_t x = 0; x < w; x++) {
                    p[y * bpr + x * 4 + 0] = 128;
                    p[y * bpr + x * 4 + 1] = 128;
                    p[y * bpr + x * 4 + 2] = 128;
                    p[y * bpr + x * 4 + 3] = 255;
                }
            }
        }
    } else if (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
               fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        // NV12: Y plane (0) + UV plane (1).
        size_t planeCount = CVPixelBufferGetPlaneCount(buf);
        if (planeCount >= 1) {
            uint8_t *yPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 0);
            size_t yStride  = CVPixelBufferGetBytesPerRowOfPlane(buf, 0);
            if (yPlane) {
                for (size_t y = 0; y < h; y++) memset(yPlane + y * yStride, 128, w);
            }
        }
        if (planeCount >= 2) {
            uint8_t *uvPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 1);
            size_t uvStride  = CVPixelBufferGetBytesPerRowOfPlane(buf, 1);
            if (uvPlane) {
                for (size_t y = 0; y < h / 2; y++) memset(uvPlane + y * uvStride, 128, w);
            }
        }
    } else {
        // Other formats (e.g. OneComponent8): fill base address if accessible.
        void *base = CVPixelBufferGetBaseAddress(buf);
        if (base) {
            size_t bpr = CVPixelBufferGetBytesPerRow(buf);
            memset(base, 128, bpr * h);
        }
    }

    CVPixelBufferUnlockBaseAddress(buf, 0);
    return buf;
}

// ─── Stub fallback provider ──────────────────────────────────────────────────

@interface _VGStubFallbackProvider : NSObject <VGMaskProvider>
@property (atomic, readonly, nullable) VGSkinMask *latestMask;
@property (atomic) BOOL didReceiveFrame;
@property (atomic) BOOL didInvalidate;
@end

@implementation _VGStubFallbackProvider
@synthesize latestMask = _latestMask;

- (void)submitFrame:(CVPixelBufferRef)pb pts:(CMTime)pts generation:(uint64_t)gen {
    self.didReceiveFrame = YES;
}
- (void)invalidate {
    self.didInvalidate = YES;
}
@end

// ─── Test class ──────────────────────────────────────────────────────────────

@interface VGLiteRTMaskProviderTest : XCTestCase
@end

@implementation VGLiteRTMaskProviderTest

/// Returns the bundled model URL, or nil if not found.
- (NSURL *)_bundledModelURL {
    return [VGMLModelBundle URLForModelNamed:@"selfie_multiclass_256x256"];
}

// ── P9B-2-1: Invalid model URL triggers fallback ──────────────────────────────
- (void)testInvalidModelURLFallsBack {
    NSURL *badURL = [NSURL fileURLWithPath:@"/nonexistent/path/model.tflite"];
    VGLiteRTMaskProvider *provider = [[VGLiteRTMaskProvider alloc]
                                      initWithModelURL:badURL fallback:nil];
    XCTAssertNotNil(provider, @"Provider should always init (may be in fallback)");
    XCTAssertTrue(provider.isUsingFallback, @"Provider should be in fallback after bad URL");
    XCTAssertFalse(provider.isReady, @"Provider should not be ready after bad URL");
}

// ── P9B-2-2: Provider conforms to VGMaskProvider ─────────────────────────────
- (void)testProviderConformsToVGMaskProvider {
    XCTAssertTrue([VGLiteRTMaskProvider conformsToProtocol:@protocol(VGMaskProvider)],
                  @"VGLiteRTMaskProvider must conform to VGMaskProvider");

    // Verify required selectors.
    XCTAssertTrue([VGLiteRTMaskProvider instancesRespondToSelector:@selector(latestMask)]);
    XCTAssertTrue([VGLiteRTMaskProvider instancesRespondToSelector:
                   @selector(submitFrame:pts:generation:)]);
    XCTAssertTrue([VGLiteRTMaskProvider instancesRespondToSelector:@selector(invalidate)]);
}

// ── P9B-2-3: Bundled model URL initializes provider ─────────────────────────
- (void)testModelBundleURLInitializesProvider {
    NSURL *url = [self _bundledModelURL];
    if (!url) {
        XCTSkip(@"Bundled model not found — skipping (asset bundle not installed in test host)");
        return;
    }

    VGLiteRTMaskProvider *provider = [[VGLiteRTMaskProvider alloc]
                                      initWithModelURL:url fallback:nil];
    XCTAssertNotNil(provider, @"Provider must not be nil for valid model URL");
    // Provider may be in fallback if Metal delegate fails on simulator, but
    // must not crash. We only assert it initialized.
}

// ── P9B-2-4: Tensor shape validation succeeds for bundled model ───────────────
- (void)testTensorShapeValidationSucceedsForBundledModel {
    NSURL *url = [self _bundledModelURL];
    if (!url) {
        XCTSkip(@"Bundled model not found — skipping");
        return;
    }

    VGLiteRTMaskProvider *provider = [[VGLiteRTMaskProvider alloc]
                                      initWithModelURL:url fallback:nil];
    XCTAssertNotNil(provider);

    // On simulator, Metal delegate is unavailable but CPU fallback should succeed.
    // On device, Metal delegate should succeed.
    // Either way: -ready must be YES and -isUsingFallback must be NO.
    XCTAssertTrue(provider.isReady,
                  @"Provider must be ready after loading bundled model (CPU fallback on sim)");
    XCTAssertFalse(provider.isUsingFallback,
                   @"Provider must not be in fallback after loading bundled model");
    [provider invalidate];
}

// ── P9B-2-5: submitFrame returns quickly (non-blocking contract) ───────────────
- (void)testSubmitFrameReturnsQuickly {
    NSURL *url = [self _bundledModelURL];
    if (!url) {
        XCTSkip(@"Bundled model not found — skipping");
        return;
    }

    VGLiteRTMaskProvider *provider = [[VGLiteRTMaskProvider alloc]
                                      initWithModelURL:url fallback:nil];
    XCTAssertNotNil(provider);

    CVPixelBufferRef buf = _makeSyntheticBuffer(1920, 1080, kCVPixelFormatType_32BGRA);
    XCTAssertNotNil((__bridge id)buf, @"Failed to create synthetic buffer");

    // submitFrame must return within 1 ms (non-blocking).
    NSDate *start = [NSDate date];
    for (int i = 0; i < 3; i++) {
        [provider submitFrame:buf pts:kCMTimeZero generation:0];
    }
    NSTimeInterval elapsed = -[start timeIntervalSinceNow];
    CVPixelBufferRelease(buf);

    XCTAssertLessThan(elapsed, 0.005,  // 5 ms ceiling for 3 non-blocking dispatches
        @"submitFrame must not block caller: took %.3fs for 3 calls", elapsed);

    // Give inference a chance to complete before teardown.
    [NSThread sleepForTimeInterval:0.5];
    [provider invalidate];
}

// ── P9B-2-6: invalidate is idempotent ─────────────────────────────────────────
- (void)testInvalidateIsIdempotent {
    NSURL *url = [self _bundledModelURL];
    VGLiteRTMaskProvider *provider;
    if (url) {
        provider = [[VGLiteRTMaskProvider alloc] initWithModelURL:url fallback:nil];
    } else {
        NSURL *badURL = [NSURL fileURLWithPath:@"/nonexistent/model.tflite"];
        provider = [[VGLiteRTMaskProvider alloc] initWithModelURL:badURL fallback:nil];
    }
    XCTAssertNotNil(provider);

    // Calling invalidate multiple times must not crash.
    XCTAssertNoThrow([provider invalidate]);
    XCTAssertNoThrow([provider invalidate]);
    XCTAssertNoThrow([provider invalidate]);
}

// ── P9B-2-7: latestMask delegates to fallback when faulted ────────────────────
- (void)testLatestMaskDelegatesToFallbackWhenFaulted {
    _VGStubFallbackProvider *fallback = [[_VGStubFallbackProvider alloc] init];

    // Force fallback mode with an invalid model URL.
    NSURL *badURL = [NSURL fileURLWithPath:@"/nonexistent/model.tflite"];
    VGLiteRTMaskProvider *provider = [[VGLiteRTMaskProvider alloc]
                                      initWithModelURL:badURL fallback:fallback];
    XCTAssertNotNil(provider);
    XCTAssertTrue(provider.isUsingFallback, @"Should be in fallback after bad URL");

    // Submit a frame — should forward to fallback.
    CVPixelBufferRef buf = _makeSyntheticBuffer(640, 480, kCVPixelFormatType_32BGRA);
    [provider submitFrame:buf pts:kCMTimeZero generation:1];
    CVPixelBufferRelease(buf);

    // Wait briefly for async dispatch.
    [NSThread sleepForTimeInterval:0.1];
    XCTAssertTrue(fallback.didReceiveFrame,
        @"Faulted provider must forward frames to fallback provider");
}

// ── P9B-2-8: Generation reset does not crash ──────────────────────────────────
- (void)testGenerationResetDoesNotCrash {
    NSURL *url = [self _bundledModelURL];
    VGLiteRTMaskProvider *provider;
    if (url) {
        provider = [[VGLiteRTMaskProvider alloc] initWithModelURL:url fallback:nil];
    } else {
        XCTSkip(@"Bundled model not found — skipping");
        return;
    }
    XCTAssertNotNil(provider);

    CVPixelBufferRef buf = _makeSyntheticBuffer(1280, 720, kCVPixelFormatType_32BGRA);

    // Submit frames across multiple generation changes.
    XCTAssertNoThrow({
        [provider submitFrame:buf pts:kCMTimeZero generation:0];
        [provider submitFrame:buf pts:kCMTimeZero generation:1]; // generation reset
        [provider submitFrame:buf pts:kCMTimeZero generation:1];
        [provider submitFrame:buf pts:kCMTimeZero generation:2]; // another reset
    });

    CVPixelBufferRelease(buf);
    [NSThread sleepForTimeInterval:0.5];
    [provider invalidate];
}

// ── P9B-2-9: Unsupported pixel format falls back or no-ops safely ─────────────
- (void)testUnsupportedPixelBufferFallsBackOrNoOpsSafely {
    NSURL *url = [self _bundledModelURL];
    VGLiteRTMaskProvider *provider;
    if (url) {
        provider = [[VGLiteRTMaskProvider alloc] initWithModelURL:url fallback:nil];
    } else {
        XCTSkip(@"Bundled model not found — skipping");
        return;
    }
    XCTAssertNotNil(provider);

    // kCVPixelFormatType_OneComponent8 (luma only) — unsupported format.
    CVPixelBufferRef buf = _makeSyntheticBuffer(640, 480, kCVPixelFormatType_OneComponent8);
    if (!buf) {
        // Some formats can't be allocated without IOSurface on simulator — that's OK.
        [provider invalidate];
        return;
    }

    // Must not crash, must not block.
    XCTAssertNoThrow([provider submitFrame:buf pts:kCMTimeZero generation:0]);
    CVPixelBufferRelease(buf);

    [NSThread sleepForTimeInterval:0.2];
    [provider invalidate];
}

@end
