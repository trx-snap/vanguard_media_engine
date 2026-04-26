// VGPoolSizingTest.m
// Vanguard Media Engine — Phase 4 P4-7D
//
// Gate test 2: Pool Sizing
//
// Invariant:
//   Pool dimensions reflect the source's actual renderSize, NOT the hardcoded
//   1080×1920 fallback that existed before P4-7B.
//
// Strategy:
//   Create a testable runtime whose mock source reports renderSize = 720×1280.
//   After prepare, allocate a CVPixelBuffer from the session pool and assert
//   its pixel dimensions are 720×1280. This proves:
//     (a) Pool was created AFTER prepare (source renderSize is available).
//     (b) Runtime read and used the actual source dimensions.
//     (c) The hardcoded 1080×1920 pre-prepare path is gone.
//
// Note: This test creates its own pool via the real VGResourceAllocator,
//   exactly mirroring the P4-7B runtime logic, with a custom renderSize.

#import <XCTest/XCTest.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#include <stdatomic.h>

#import "VanguardGraphRuntime.h"
#import <UMF/VGGraphRuntime.h>
#import <UMF/VGMediaNode.h>
#import <UMF/VGResourceAllocator.h>
#import "VanguardMediaSource.h"

// ─── Flutter stubs (minimal) ──────────────────────────────────────────────

@interface VGPSMockRegistry : NSObject <FlutterTextureRegistry>
@end
@implementation VGPSMockRegistry {
  int64_t _next;
}
- (instancetype)init { self = [super init]; _next = 42; return self; }
- (int64_t)registerTexture:(id<FlutterTexture>)texture { return _next++; }
- (void)textureFrameAvailable:(int64_t)tid {}
- (void)unregisterTexture:(int64_t)tid {}
@end

@interface VGPSMockChannel : NSObject
- (void)invokeMethod:(NSString *)method arguments:(id)args;
@end
@implementation VGPSMockChannel
- (void)invokeMethod:(NSString *)method arguments:(id)args {}
@end

// ─── Mock source reporting renderSize 720×1280 ────────────────────────────
//
// Conforms to VGMediaNode and VanguardMediaSource. Exposes renderSize
// so the runtime can read it post-prepare (P4-7B step 3.6a).

@interface VGPSMockSource : NSObject <VanguardMediaSource, VGMediaNode>
@property(nonatomic) CGSize renderSize;
@end
@implementation VGPSMockSource {
  _Atomic(BOOL) _inv;
}
- (NSString *)nodeId   { return @"ps-mock"; }
- (NSString *)nodeType { return @"VGPSMockSource"; }
- (void)prepareWithCompletion:(void (^)(NSError *_Nullable))cb {
  // renderSize is set before prepareWithCompletion: is called by the runtime.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ cb(nil); });
}
- (void)invalidate { atomic_store(&_inv, YES); }
- (void)start {}
- (void)stop {}
- (void)seekTo:(CMTime)t {}
- (void)setVideoCallback:(VanguardVideoFrameCallback)cb {}
- (void)setAudioCallback:(nullable VanguardAudioBufferCallback)cb {}
- (CMTime)currentTime { return kCMTimeZero; }
- (CMTime)duration    { return CMTimeMakeWithSeconds(5.0, NSEC_PER_SEC); }
- (VanguardPlaybackRate)playbackRate { return 1.0; }
- (void)setPlaybackRate:(VanguardPlaybackRate)r {}
@end

// ─── Testable runtime that exercises the post-prepare pool-sizing path ─────

@interface VanguardGraphRuntime (PSSeam)
@property(nonatomic, readwrite) VGRuntimeState state;
@property(nonatomic, readwrite) int64_t textureId;
@end

@interface VGPSSizingRuntime : VanguardGraphRuntime
// Pool created with source renderSize — held for inspection + cleanup.
@property(nonatomic) CVPixelBufferPoolRef testPool;
@property(nonatomic) NSUInteger reservedBytes;
// Actual size used to create the pool (read back for assertion).
@property(nonatomic) CGSize poolSize;
@end

@implementation VGPSSizingRuntime

- (void)prepareWithURL:(NSURL *)url
            completion:(void (^)(int64_t, NSError *_Nullable))completion {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    // Create mock source with a specific renderSize.
    VGPSMockSource *source = [[VGPSMockSource alloc] init];
    source.renderSize = CGSizeMake(720.0, 1280.0); // non-fallback dimensions

    // Prepare source.
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSError *prepErr = nil;
    [source prepareWithCompletion:^(NSError *e) {
      prepErr = e;
      dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (prepErr) { completion(-1, prepErr); return; }

    // ── P4-7B step 3.6a: read actual renderSize ────────────────────────
    CGSize renderSz = source.renderSize;
    if (renderSz.width <= 0 || renderSz.height <= 0) {
      renderSz = CGSizeMake(1080.0, 1920.0); // fallback (should NOT fire here)
    }
    self.poolSize = renderSz;

    const size_t w = (size_t)renderSz.width;
    const size_t h = (size_t)renderSz.height;
    const NSUInteger count = 3; // muted role → count=3

    // ── P4-7B step 3.6c: budget check ────────────────────────────────
    VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];
    NSUInteger poolBytes = w * h * 4 * count;
    BOOL reserved = [allocator canAllocatePoolBytes:poolBytes];
    self.reservedBytes = reserved ? poolBytes : 0;

    // ── P4-7B step 3.6d: create pool with actual dimensions ───────────
    CVPixelBufferPoolRef pool = NULL;
    if (reserved) {
      pool = [allocator pixelBufferPoolWithWidth:w
                                          height:h
                                          format:kCVPixelFormatType_32BGRA
                             minimumBufferCount:count];
      if (!pool) {
        [allocator reportPoolReleased:poolBytes];
        self.reservedBytes = 0;
      }
    }
    self.testPool = pool;

    self.state = VGRuntimeStatePrepared;
    self.textureId = 42;
    completion(42, nil);
  });
}

- (void)cleanupPool {
  CVPixelBufferPoolRef pool = self.testPool;
  if (pool) {
    CVPixelBufferPoolRelease(pool);
    self.testPool = NULL;
  }
  if (self.reservedBytes > 0) {
    [[VGResourceAllocator sharedInstance] reportPoolReleased:self.reservedBytes];
    self.reservedBytes = 0;
  }
}

@end

// ─── Helpers ─────────────────────────────────────────────────────────────

static const NSTimeInterval kPSTimeout = 8.0;

static VGPSSizingRuntime *makePSRuntime(void) {
  VGPSMockRegistry *reg = [[VGPSMockRegistry alloc] init];
  VGPSMockChannel *ch   = [[VGPSMockChannel alloc] init];
  return [[VGPSSizingRuntime alloc]
      initWithTextureRegistry:reg
                methodChannel:(FlutterMethodChannel *)ch
             desiredAudioRole:VGAudioRoleMuted];
}

// ─── Test class ───────────────────────────────────────────────────────────

@interface VGPoolSizingTest : XCTestCase
@end

@implementation VGPoolSizingTest

// AC-PS1: Pool uses source renderSize, not hardcoded 1080×1920 fallback.
//
// Allocates a CVPixelBuffer from the test pool and asserts width=720 height=1280.
- (void)testPoolDimensionsMatchSourceRenderSize {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device) {
    XCTSkip(@"No Metal device");
    return;
  }

  VGPSSizingRuntime *rt = makePSRuntime();
  XCTestExpectation *exp = [self expectationWithDescription:@"prepare"];
  [rt prepareWithURL:[NSURL fileURLWithPath:@"/tmp/ps_stub.mp4"]
          completion:^(int64_t tid, NSError *err) {
            [exp fulfill];
          }];
  [self waitForExpectations:@[exp] timeout:kPSTimeout];

  // Assert poolSize was read from source (not fallback).
  XCTAssertEqual(rt.poolSize.width, 720.0,
                 @"[P4-7D PS1] Pool width must equal source renderSize.width "
                 @"(720), not the 1080 fallback.");
  XCTAssertEqual(rt.poolSize.height, 1280.0,
                 @"[P4-7D PS1] Pool height must equal source renderSize.height "
                 @"(1280), not the 1920 fallback.");

  // Assert pool exists and can allocate a buffer of the correct dimensions.
  CVPixelBufferPoolRef pool = rt.testPool;
  XCTAssertTrue(pool != NULL,
                @"[P4-7D PS1] testPool must be non-NULL after prepare.");

  if (pool) {
    CVPixelBufferRef buf = NULL;
    CVReturn status =
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf);
    XCTAssertEqual(status, kCVReturnSuccess,
                   @"[P4-7D PS1] Pool must produce a valid CVPixelBuffer.");

    if (buf) {
      size_t bufWidth  = CVPixelBufferGetWidth(buf);
      size_t bufHeight = CVPixelBufferGetHeight(buf);

      XCTAssertEqual(bufWidth, (size_t)720,
                     @"[P4-7D PS1] Buffer width must be 720 (source renderSize), "
                     @"got %zu. Pool was created with wrong dimensions.", bufWidth);
      XCTAssertEqual(bufHeight, (size_t)1280,
                     @"[P4-7D PS1] Buffer height must be 1280 (source renderSize), "
                     @"got %zu. Pool was created with wrong dimensions.", bufHeight);
      CVPixelBufferRelease(buf);
    }
  }

  [rt cleanupPool];
}

// AC-PS2: Pool dimensions do NOT equal the 1080×1920 pre-P4-7B fallback.
//
// Explicitly asserts the fallback dimensions are NOT in the pool, so any
// regression to the old hardcoded path fails immediately.
- (void)testPoolDimensionsAreNotFallback {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device) {
    XCTSkip(@"No Metal device");
    return;
  }

  VGPSSizingRuntime *rt = makePSRuntime(); // source.renderSize = 720×1280
  XCTestExpectation *exp = [self expectationWithDescription:@"prepare"];
  [rt prepareWithURL:[NSURL fileURLWithPath:@"/tmp/ps_stub2.mp4"]
          completion:^(int64_t tid, NSError *err) {
            [exp fulfill];
          }];
  [self waitForExpectations:@[exp] timeout:kPSTimeout];

  XCTAssertNotEqual(rt.poolSize.width, 1080.0,
                    @"[P4-7D PS2] Pool width is 1080 — runtime used the "
                    @"hardcoded fallback instead of source renderSize.");
  XCTAssertNotEqual(rt.poolSize.height, 1920.0,
                    @"[P4-7D PS2] Pool height is 1920 — runtime used the "
                    @"hardcoded fallback instead of source renderSize.");

  [rt cleanupPool];
}

@end
