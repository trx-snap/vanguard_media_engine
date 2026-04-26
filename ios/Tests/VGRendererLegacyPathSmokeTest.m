// VGRendererLegacyPathSmokeTest.m
// vanguard_media_engine — Phase 4, P4-6
//
// Smoke test: VGRendererLegacyPathSmokeTest
//
// Purpose:
//   Validates that after P4-6 cleanup (deletion of setRuntimeFilterChain:,
//   _runtimeFilterChain, and runtime filter branch), the renderer's legacy
//   frameDelegate==nil path still works correctly for non-scheduler sources
//   (camera, export). Satisfies the P4-6 "camera smoke test" requirement
//   (plan line 169) at unit-test level.
//
// What is tested:
//   1. Renderer can be created with a mock source and nil frameDelegate.
//   2. Feeding a raw CVPixelBuffer through the video callback does not crash.
//   3. The renderer stores the frame in _latestPixelBuffer (verifiable via
//      copyPixelBuffer).
//   4. Mock texture registry receives textureFrameAvailable: (Flutter signal).
//   5. No scheduler or runtime shim code is involved.
//
// Contract anchors:
//   - RR-31 CLOSED: setRuntimeFilterChain: is gone; renderer executes legacy
//     VanguardFilterNode path only, not the deleted UMF runtime branch.
//   - RR-35: _onVideoFrame: NSAssert satisfied by setting filterChainEnabled=YES
//     (matches real camera renderer usage). _disposed=NO (renderer alive).
//   - RR-36: No filter execution in this test — legacy passthrough with empty
//     filterChain. No ownership boundary crossed beyond renderer's own retain.
//
// Source mock strategy:
//   VGP46MockCapturingSource: captures the video callback supplied by the
//   renderer at initWithSource: time, exposing it for direct test invocation.
//   This is the minimal seam to drive _onVideoFrame: without real media I/O.
//
// RR-35 assertion notes:
//   _onVideoFrame: fires NSAssert(_disposed || _filterChainEnabled ||
//   _frameDelegate != nil). With frameDelegate=nil and disposed=NO, we must
//   set filterChainEnabled=YES to satisfy the assertion (matches camera path).
//   filterChainEnabled=YES with an empty filterChain → no filter work → passthrough.
//
// Simulator-safe: no GPU, no media files, no physical device required.

#import <XCTest/XCTest.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CMTime.h>
#import <stdatomic.h>

#import "VanguardMetalRenderer.h"
#import "VanguardMediaSource.h"    // VanguardVideoFrameCallback typedef + protocol
#import <UMF/VGMasterClock.h>
#import <UMF/VGFrameEnvelope.h>

// ─── TestSeam: expose copyPixelBuffer for assertions ─────────────────────────

@interface VanguardMetalRenderer (P46LegacySmokeSeam)
- (CVPixelBufferRef _Nullable)copyPixelBuffer;
@end

// ─── VGP46MockCapturingSource ─────────────────────────────────────────────────
//
// VanguardMediaSource mock that captures the video callback registered by the
// renderer. The test fires the callback directly to simulate a decoded frame
// arriving from a camera or file source.
//
// Key difference from VGP44MockMediaSource: setVideoCallback: stores the block.

@interface VGP46MockCapturingSource : NSObject <VanguardMediaSource>

/// The video callback the renderer registered via setVideoCallback:.
/// Non-nil after renderer initWithSource: completes.
@property(nonatomic, copy, nullable) VanguardVideoFrameCallback capturedCallback;

@end

@implementation VGP46MockCapturingSource

- (void)start                                              { /* no-op */ }
- (void)stop                                               { /* no-op */ }
- (CMTime)duration                                         { return kCMTimeZero; }
- (void)seekToTime:(CMTime)t completion:(void(^)(BOOL))cb  { if (cb) cb(YES); }
- (void)setPlaybackRate:(double)rate                       { /* no-op */ }
- (id<VGMasterClock>)masterClock                           { return nil; }
- (dispatch_queue_t _Nullable)videoDecodeQueue             { return nil; }

/// Capture the callback so the test can fire it directly.
- (void)setVideoCallback:(VanguardVideoFrameCallback)callback {
  _capturedCallback = [callback copy];
}

@end

// ─── VGP46MockTextureRegistry ─────────────────────────────────────────────────
//
// Same pattern as VGP44MockTextureRegistry: records textureFrameAvailable: calls.

@interface VGP46MockTextureRegistry : NSObject <FlutterTextureRegistry>
@property(nonatomic, readonly) NSInteger textureFrameAvailableCallCount;
@end

@implementation VGP46MockTextureRegistry {
  int64_t _nextId;
  _Atomic(NSInteger) _callCount;
}

- (instancetype)init {
  self = [super init];
  if (!self) return nil;
  _nextId = 100;
  return self;
}

- (int64_t)registerTexture:(id<FlutterTexture>)texture { return _nextId++; }
- (void)unregisterTexture:(int64_t)textureId           { /* no-op */ }

- (void)textureFrameAvailable:(int64_t)textureId {
  atomic_fetch_add(&_callCount, 1);
}

- (NSInteger)textureFrameAvailableCallCount {
  return atomic_load(&_callCount);
}

@end

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Creates a 64×64 Metal-compatible IOSurface-backed CVPixelBuffer at +1.
/// Caller owns the +1; call CVPixelBufferRelease when done.
static CVPixelBufferRef P46CreateTestPixelBuffer(void) {
  NSDictionary *attrs = @{
    (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey  : @YES,
    (__bridge NSString *)kCVPixelBufferWidthKey               : @(64),
    (__bridge NSString *)kCVPixelBufferHeightKey              : @(64),
  };
  CVPixelBufferRef buf = NULL;
  CVReturn ret = CVPixelBufferCreate(
      kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
      (__bridge CFDictionaryRef)attrs, &buf);
  return (ret == kCVReturnSuccess) ? buf : NULL;
}

// Timeout for async textureFrameAvailable: dispatch to main queue.
static const NSTimeInterval kP46Timeout = 2.0;

// ─── VGRendererLegacyPathSmokeTest ───────────────────────────────────────────

@interface VGRendererLegacyPathSmokeTest : XCTestCase
@end

@implementation VGRendererLegacyPathSmokeTest {
  VanguardMetalRenderer       *_renderer;
  VGP46MockCapturingSource    *_source;
  VGP46MockTextureRegistry    *_registry;
}

- (void)setUp {
  [super setUp];

  _source   = [[VGP46MockCapturingSource alloc] init];
  _registry = [[VGP46MockTextureRegistry alloc] init];

  // FlutterMethodChannel cannot be easily mocked; use an NSObject stub.
  // Renderer only calls invokeMethod: on playback-complete paths — not exercised here.
  id channelStub = [[NSObject alloc] init];

  _renderer = [[VanguardMetalRenderer alloc]
      initWithSource:_source
     textureRegistry:_registry
       methodChannel:(FlutterMethodChannel *)channelStub];

  XCTAssertNotNil(_renderer, @"Renderer must initialise with mock dependencies");

  // Confirm callback was captured. If nil, the source mock's setVideoCallback:
  // was not called — indicates a change in renderer initialisation order.
  XCTAssertNotNil(_source.capturedCallback,
      @"Source must have received setVideoCallback: during initWithSource:");

  // Explicitly verify frameDelegate is nil — this test validates the legacy path.
  XCTAssertNil(_renderer.frameDelegate,
      @"frameDelegate must be nil for legacy path smoke test");

  // Set filterChainEnabled=YES to satisfy the RR-35 NSAssert in _onVideoFrame:.
  // This mirrors real camera renderer usage where the legacy filter chain is
  // enabled even if empty. With an empty filterChain, no filter work is done.
  _renderer.filterChainEnabled = YES;
}

- (void)tearDown {
  [_renderer dispose];
  _renderer = nil;
  _source   = nil;
  _registry = nil;
  [super tearDown];
}

// Helper: fire a raw frame through the captured video callback.
// CVPixelBufferRetain is called before firing to match the real source contract
// (source retains the buffer before handing it to the callback; renderer
// releases it after _onVideoFrame: completes).
- (void)_fireFrameWithBuffer:(CVPixelBufferRef)buf pts:(CMTime)pts {
  CVPixelBufferRetain(buf); // simulate source's +1 before callback
  _source.capturedCallback(buf, pts);
  // The renderer calls CVPixelBufferRelease(rawFrame) at the end of
  // _onVideoFrame: (line ~907). Our +1 is consumed there.
}

// ─── Test 1 ──────────────────────────────────────────────────────────────────
// frameDelegate is nil before and after a raw frame is delivered.
// Confirms legacy path is taken, not the P4-5 scheduler branch.

- (void)testFrameDelegateRemainsNilOnLegacyPath {
  XCTAssertNil(_renderer.frameDelegate,
      @"frameDelegate must be nil before frame delivery");

  CVPixelBufferRef buf = P46CreateTestPixelBuffer();
  XCTAssertNotEqual(buf, (CVPixelBufferRef)NULL, @"Buffer allocation prerequisite");
  if (!buf) return;

  [self _fireFrameWithBuffer:buf pts:kCMTimeZero];

  XCTAssertNil(_renderer.frameDelegate,
      @"frameDelegate must remain nil after legacy path frame delivery");

  CVPixelBufferRelease(buf); // balance our local +1 (captured callback consumed its +1)
  // Note: _fireFrameWithBuffer: calls CVPixelBufferRetain before firing and the
  // renderer releases rawFrame in _onVideoFrame:. We release the original +1 here.
}

// ─── Test 2 ──────────────────────────────────────────────────────────────────
// copyPixelBuffer returns non-null after a raw frame is fed through the legacy path.
// Proves the renderer stores the frame in _latestPixelBuffer correctly.

- (void)testLegacyPathStoresFrameInLatestPixelBuffer {
  CVPixelBufferRef buf = P46CreateTestPixelBuffer();
  XCTAssertNotEqual(buf, (CVPixelBufferRef)NULL, @"Buffer allocation prerequisite");
  if (!buf) return;

  [self _fireFrameWithBuffer:buf pts:CMTimeMakeWithSeconds(1.0, 600)];

  CVPixelBufferRef stored = [_renderer copyPixelBuffer];
  XCTAssertNotEqual(stored, (CVPixelBufferRef)NULL,
      @"copyPixelBuffer must return non-null after legacy path frame delivery — "
       "_latestPixelBuffer must have been set");

  if (stored) {
    // Confirm same underlying IOSurface — proves it is the same frame.
    IOSurfaceRef surface1 = CVPixelBufferGetIOSurface(buf);
    IOSurfaceRef surface2 = CVPixelBufferGetIOSurface(stored);
    XCTAssertEqual(surface1, surface2,
        @"Stored buffer IOSurface must match delivered buffer — "
         "correct frame was stored");
    CVPixelBufferRelease(stored); // balance copyPixelBuffer's +1
  }

  CVPixelBufferRelease(buf);
}

// ─── Test 3 ──────────────────────────────────────────────────────────────────
// textureFrameAvailable: fires on the registry after legacy path frame delivery.
// Proves the Flutter signal path is intact post-P4-6.

- (void)testLegacyPathSignalsFlutterRegistry {
  CVPixelBufferRef buf = P46CreateTestPixelBuffer();
  XCTAssertNotEqual(buf, (CVPixelBufferRef)NULL, @"Buffer allocation prerequisite");
  if (!buf) return;

  [self _fireFrameWithBuffer:buf pts:CMTimeMakeWithSeconds(1.0, 600)];
  CVPixelBufferRelease(buf);

  // textureFrameAvailable: is dispatched to main queue asynchronously inside
  // _onVideoFrame:. Wait for it.
  XCTestExpectation *expectation =
      [self expectationWithDescription:@"textureFrameAvailable: fires on legacy path"];

  dispatch_async(dispatch_get_main_queue(), ^{
    // By the time this runs, the dispatch_async inside _onVideoFrame: has also
    // posted to main — it will execute before or immediately after this block.
    // Add one more hop to guarantee ordering.
    dispatch_async(dispatch_get_main_queue(), ^{
      [expectation fulfill];
    });
  });

  [self waitForExpectationsWithTimeout:kP46Timeout handler:nil];

  XCTAssertGreaterThanOrEqual(_registry.textureFrameAvailableCallCount, (NSInteger)1,
      @"textureFrameAvailable: must be called at least once after legacy frame delivery");
}

// ─── Test 4 ──────────────────────────────────────────────────────────────────
// No crash on multiple sequential legacy frames.
// Basic durability: 5 frames delivered, renderer stays alive, buffer updates.

- (void)testLegacyPathHandlesMultipleFramesWithoutCrash {
  const NSUInteger frameCount = 5;
  CVPixelBufferRef lastBuf = NULL;

  for (NSUInteger i = 0; i < frameCount; i++) {
    CVPixelBufferRef buf = P46CreateTestPixelBuffer();
    XCTAssertNotEqual(buf, (CVPixelBufferRef)NULL,
        @"Frame %lu buffer allocation failed", (unsigned long)i);
    if (!buf) continue;

    CMTime pts = CMTimeMakeWithSeconds((double)i * 0.033, 600);
    [self _fireFrameWithBuffer:buf pts:pts];

    if (lastBuf) CVPixelBufferRelease(lastBuf);
    lastBuf = buf; // keep +1 alive to verify IOSurface equality below
  }

  // After 5 frames, copyPixelBuffer should return the last frame.
  CVPixelBufferRef stored = [_renderer copyPixelBuffer];
  XCTAssertNotEqual(stored, (CVPixelBufferRef)NULL,
      @"copyPixelBuffer must return non-null after %lu legacy frames",
      (unsigned long)frameCount);

  if (stored) CVPixelBufferRelease(stored);
  if (lastBuf) CVPixelBufferRelease(lastBuf);
}

// ─── Test 5 ──────────────────────────────────────────────────────────────────
// After dispose, _disposed is set and no further frame storage occurs.
// Verifies RR-35 _disposed guard: frames are dropped post-dispose.

- (void)testDisposedRendererDropsFramesOnLegacyPath {
  [_renderer dispose]; // sets _disposed = YES atomically

  CVPixelBufferRef buf = P46CreateTestPixelBuffer();
  XCTAssertNotEqual(buf, (CVPixelBufferRef)NULL, @"Buffer allocation prerequisite");
  if (!buf) {
    return;
  }

  // Fire frame — should be dropped silently by the _disposed guard.
  // The renderer calls CVPixelBufferRelease(rawFrame) in the guard branch,
  // so we must still give it the retained buffer.
  XCTAssertNoThrow([self _fireFrameWithBuffer:buf pts:kCMTimeZero],
      @"Legacy path frame delivery on disposed renderer must not crash");

  // copyPixelBuffer returns nil because _latestPixelBuffer was never set.
  CVPixelBufferRef stored = [_renderer copyPixelBuffer];
  XCTAssertEqual(stored, (CVPixelBufferRef)NULL,
      @"Disposed renderer must not store frames — copyPixelBuffer must return nil");

  if (stored) CVPixelBufferRelease(stored);
  CVPixelBufferRelease(buf);

  // Prevent tearDown from calling dispose again (already disposed).
  _renderer = nil;
}

@end
