// VGResourceAllocatorTest.m
// Phase 1A — P1A-03
//
// Tests for VGResourceAllocator singleton.
// Runs in the iOS simulator — no physical device required.
// All assertions must be green in simulator CI.
//
// Run with:
//   xcodebuild test -scheme vanguard_media_engine \
//                   -destination 'platform=iOS Simulator,name=iPhone 15'

#import <XCTest/XCTest.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

// VGResourceAllocator lives in the UMF package. The vanguard_media_engine
// podspec includes Classes/**; the UMF package's Classes are accessible via
// the search path set up in the host app test target. If the build system
// makes the UMF sources available as a separate pod, update the import path
// accordingly. For now we use a quoted import matching the Classes directory.
#import "VGResourceAllocator.h"

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGResourceAllocatorTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGResourceAllocatorTest : XCTestCase
@end

@implementation VGResourceAllocatorTest

// ─── P1A-03-T1: Singleton identity ────────────────────────────────────────────

/// Two calls to +sharedInstance must return the exact same pointer.
/// Verifies dispatch_once is correctly guarding the initialiser.
- (void)testSingletonIdentity {
    VGResourceAllocator *a = [VGResourceAllocator sharedInstance];
    VGResourceAllocator *b = [VGResourceAllocator sharedInstance];
    XCTAssertNotNil(a, @"sharedInstance must not be nil");
    XCTAssertTrue(a == b,
        @"Two calls to sharedInstance must return the same pointer "
        @"(dispatch_once violated — got %p vs %p)", a, b);
}

// ─── P1A-03-T2: Pixel buffer pool creation ─────────────────────────────────────

/// Pool creation must succeed for a standard 1080×1920 BGRA canvas.
- (void)testPixelBufferPoolCreationSucceeds {
    VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];

    CVPixelBufferPoolRef pool =
        [allocator pixelBufferPoolWithWidth:1080
                                     height:1920
                                     format:kCVPixelFormatType_32BGRA];

    XCTAssertTrue(pool != NULL,
        @"pixelBufferPoolWithWidth:height:format: must return a non-NULL pool "
        @"for 1080×1920 BGRA");

    if (pool) {
        CVPixelBufferPoolRelease(pool);
    }
}

// ─── P1A-03-T3: IOSurface backing ──────────────────────────────────────────────

/// Buffers created from the pool must have IOSurface backing.
/// This is required for Flutter's Metal texture-cache upload path (RR-2).
- (void)testPoolBuffersHaveIOSurfaceBacking {
    VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];

    CVPixelBufferPoolRef pool =
        [allocator pixelBufferPoolWithWidth:1080
                                     height:1920
                                     format:kCVPixelFormatType_32BGRA];
    XCTAssertTrue(pool != NULL, @"Pool must be non-NULL before buffer allocation test");
    if (!pool) return;

    CVPixelBufferRef buffer = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                         pool, &buffer);
    XCTAssertEqual(status, kCVReturnSuccess,
        @"CVPixelBufferPoolCreatePixelBuffer must succeed (got %d)", status);
    XCTAssertTrue(buffer != NULL,
        @"Allocated pixel buffer must be non-NULL");

    if (buffer) {
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(buffer);
        XCTAssertTrue(surface != NULL,
            @"Pool buffers must have IOSurface backing "
            @"(kCVPixelBufferIOSurfacePropertiesKey was not set — RR-2)");
        CVPixelBufferRelease(buffer);
    }

    CVPixelBufferPoolRelease(pool);
}

// ─── P1A-03-T4: Metal compatibility attribute ──────────────────────────────────

/// Buffers created from the pool must report Metal compatibility.
/// Required for CVMetalTextureCacheCreateTextureFromImage to succeed at render time.
- (void)testPoolBuffersHaveMetalCompatibilityAttribute {
    VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];

    CVPixelBufferPoolRef pool =
        [allocator pixelBufferPoolWithWidth:1080
                                     height:1920
                                     format:kCVPixelFormatType_32BGRA];
    XCTAssertTrue(pool != NULL, @"Pool must be non-NULL before Metal compat test");
    if (!pool) return;

    CVPixelBufferRef buffer = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                         pool, &buffer);
    XCTAssertEqual(status, kCVReturnSuccess,
        @"CVPixelBufferPoolCreatePixelBuffer must succeed (got %d)", status);

    if (buffer) {
        // Verify Metal compatibility by attempting to wrap the buffer in a Metal
        // texture via CVMetalTextureCacheCreateTextureFromImage. This is the
        // actual runtime gate: if the buffer lacks Metal compatibility or IOSurface
        // backing, this call returns an error code (not kCVReturnSuccess).
        // Note: CVBufferCopyAttachment is iOS 15+ so we use the cache path only.

        // The attribute may not be propagated as a CVBuffer attachment;
        // instead we verify via CVMetalTextureCacheCreateTextureFromImage
        // (the actual runtime check) using the shared Metal device and cache.
        CVMetalTextureCacheRef cache = [allocator textureCache];
        id<MTLDevice> device = [allocator metalDevice];

        if (cache && device) {
            CVMetalTextureRef mtlTexRef = NULL;
            CVReturn texStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                buffer,
                nil,
                MTLPixelFormatBGRA8Unorm,
                CVPixelBufferGetWidth(buffer),
                CVPixelBufferGetHeight(buffer),
                0,
                &mtlTexRef
            );
            XCTAssertEqual(texStatus, kCVReturnSuccess,
                @"CVMetalTextureCacheCreateTextureFromImage must succeed — "
                @"buffer lacks Metal compatibility (kCVPixelBufferMetalCompatibilityKey "
                @"not set or IOSurface backing missing)");
            if (mtlTexRef) CFRelease(mtlTexRef);
        } else {
            // No Metal device in this sim configuration — treat as pass with note.
            // This branch should not be reached on standard simulator configs.
            XCTFail(@"No Metal device or texture cache available in this simulator. "
                    @"Cannot verify Metal compatibility attribute.");
        }

        CVPixelBufferRelease(buffer);
    }

    CVPixelBufferPoolRelease(pool);
}

// ─── P1A-03-T5: textureCache is non-nil ───────────────────────────────────────

/// textureCache must be a non-nil CVMetalTextureCacheRef after singleton init.
- (void)testTextureCacheIsNonNil {
    VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];
    CVMetalTextureCacheRef cache = [allocator textureCache];
    XCTAssertTrue(cache != NULL,
        @"textureCache must be non-NULL after sharedInstance init");
}

// ─── P1A-03-T6: metalDevice is non-nil ─────────────────────────────────────────

/// metalDevice must return a non-nil MTLDevice after singleton init.
/// MTLCreateSystemDefaultDevice() returns nil only on hardware with no Metal
/// support — all supported iOS simulator targets have Metal.
- (void)testMetalDeviceIsNonNil {
    VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];
    id<MTLDevice> device = [allocator metalDevice];
    XCTAssertNotNil(device,
        @"metalDevice must be non-nil — MTLCreateSystemDefaultDevice() returned nil. "
        @"Verify Metal is available on this simulator target.");
}

// ─── P1A-03-T7: Singleton identity under concurrent access ─────────────────────

/// 100 concurrent calls to +sharedInstance must all return the same pointer.
/// Validates that dispatch_once is safe under contention.
- (void)testSingletonIdentityConcurrent {
    __block NSMutableSet<NSValue *> *pointers =
        [NSMutableSet setWithCapacity:100];
    NSLock *lock = [[NSLock alloc] init];

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    for (int i = 0; i < 100; i++) {
        dispatch_group_async(group, q, ^{
            VGResourceAllocator *inst = [VGResourceAllocator sharedInstance];
            NSValue *ptr = [NSValue valueWithPointer:(__bridge void *)inst];
            [lock lock];
            [pointers addObject:ptr];
            [lock unlock];
        });
    }

    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW,
                                              (int64_t)(5 * NSEC_PER_SEC)));

    XCTAssertEqual(pointers.count, (NSUInteger)1,
        @"All concurrent sharedInstance calls must return the same pointer. "
        @"Got %lu distinct pointers (dispatch_once race?)", (unsigned long)pointers.count);
}

@end
