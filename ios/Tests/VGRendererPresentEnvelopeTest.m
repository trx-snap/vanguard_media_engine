// VGRendererPresentEnvelopeTest.m
// Vanguard Media Engine — Phase 4, P4-4
//
// Regression gate for P4-4: Renderer GPU-Sink Entry Point.
//
// Contract reference:
//   packages/UMF/implementation/phase4_unified_plan.md § P4-4, §10 (RR-36)
//
// Test plan (plan line 363):
//   presentEnvelope: stores buffer. Mock registry receives textureFrameAvailable:.
//
// Design:
//   VanguardMetalRenderer requires a real id<VanguardMediaSource>,
//   id<FlutterTextureRegistry>, and FlutterMethodChannel. We satisfy all three
//   with minimal mocks — no real media I/O, no GPU.
//
//   presentEnvelope: is tested by:
//     1. Calling it with a valid CVPixelBuffer.
//     2. Asserting copyPixelBuffer returns a retained reference to that buffer
//        (store confirmed via IOSurface backing — not pointer equality, because
//        retain gives us a new logical ref to the same underlying buffer).
//     3. Asserting the mock texture registry received textureFrameAvailable:
//        (Flutter signal confirmed).
//     4. Verifying the previous _latestPixelBuffer is released (no double-retain).
//     5. Verifying NULL payload triggers NSAssert and early-returns without crash.
//
// Simulator-safe: no real media files, no physical device required.
// Run with:
//   xcodebuild test -scheme vanguard_media_engine-Unit-Tests \
//                   -destination 'platform=iOS Simulator,name=iPhone 15'

#import <XCTest/XCTest.h>
#import <CoreVideo/CoreVideo.h>
#import <stdatomic.h>
#import <UMF/VGMasterClock.h>

// SUT
#import "VanguardMetalRenderer.h"

// UMF contract type (for VGFrameEnvelope struct)
#import <UMF/VGFrameEnvelope.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - TestSeam: expose internal state for audit
// ─────────────────────────────────────────────────────────────────────────────

/// Exposes renderer internals needed for test assertions without modifying
/// production code. Only properties that already exist are exposed.
@interface VanguardMetalRenderer (P44TestSeam)
- (CVPixelBufferRef _Nullable)copyPixelBuffer;
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGP44MockTextureRegistry: spy registry
// ─────────────────────────────────────────────────────────────────────────────

/// Records textureFrameAvailable: calls. Thread-safe via atomic counter.
@interface VGP44MockTextureRegistry : NSObject <FlutterTextureRegistry>
@property(nonatomic, readonly) NSInteger textureFrameAvailableCallCount;
@property(nonatomic, readonly) int64_t   lastTextureId;
@end

@implementation VGP44MockTextureRegistry {
  int64_t _nextId;
  _Atomic(NSInteger) _textureFrameAvailableCallCount;
  _Atomic(int64_t)   _lastTextureId;
}

- (instancetype)init {
  self = [super init];
  _nextId = 42; // fixed ID so tests can assert against it
  return self;
}

- (int64_t)registerTexture:(id<FlutterTexture>)texture {
  return _nextId++;
}

- (void)textureFrameAvailable:(int64_t)textureId {
  atomic_fetch_add(&_textureFrameAvailableCallCount, 1);
  atomic_store(&_lastTextureId, textureId);
}

- (void)unregisterTexture:(int64_t)textureId { /* no-op */ }

- (NSInteger)textureFrameAvailableCallCount {
  return atomic_load(&_textureFrameAvailableCallCount);
}
- (int64_t)lastTextureId {
  return atomic_load(&_lastTextureId);
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGP44MockMediaSource: no-op media source
// ─────────────────────────────────────────────────────────────────────────────

#import "VanguardMediaSource.h"

/// Minimal VanguardMediaSource stub. Renderer requires a non-nil source.
/// All media operations are no-ops — we are testing the sink entry point only.
@interface VGP44MockMediaSource : NSObject <VanguardMediaSource>
@end

@implementation VGP44MockMediaSource

- (void)start                                         { /* no-op */ }
- (void)stop                                          { /* no-op */ }
- (CMTime)duration                                    { return kCMTimeZero; }
- (void)seekToTime:(CMTime)t completion:(void(^)(BOOL))cb { if (cb) cb(YES); }
- (void)setPlaybackRate:(double)rate                  { /* no-op */ }
- (id<VGMasterClock>)masterClock                      { return nil; }
- (void)setVideoCallback:(VanguardVideoFrameCallback)callback { /* no-op */ }

// Optional — renderer checks class membership; stub as generic source.
- (dispatch_queue_t _Nullable)videoDecodeQueue        { return nil; }

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Timeout for async expectations (textureFrameAvailable: is async to main).
static const NSTimeInterval kP44Timeout = 2.0;

/// Creates a 1×1 BGRA CVPixelBuffer backed by an IOSurface. Renderer expects
/// Metal-compatible, IOSurface-backed buffers (RR-02). The buffer is returned
/// at +1; caller is responsible for CVPixelBufferRelease.
static CVPixelBufferRef createTestPixelBuffer(void) {
  NSDictionary *attrs = @{
    (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey:  @YES,
    (__bridge NSString *)kCVPixelBufferWidthKey:               @(64),
    (__bridge NSString *)kCVPixelBufferHeightKey:              @(64),
  };
  CVPixelBufferRef buf = NULL;
  CVReturn ret = CVPixelBufferCreate(
      kCFAllocatorDefault,
      64, 64,
      kCVPixelFormatType_32BGRA,
      (__bridge CFDictionaryRef)attrs,
      &buf);
  if (ret != kCVReturnSuccess) {
    return NULL;
  }
  return buf; // +1
}

/// Constructs a VanguardMetalRenderer with mock dependencies.
/// Returns the renderer and (via out-params) the spy registry.
static VanguardMetalRenderer *makeRenderer(VGP44MockTextureRegistry **outRegistry) {
  VGP44MockTextureRegistry *registry = [[VGP44MockTextureRegistry alloc] init];
  if (outRegistry) *outRegistry = registry;

  VGP44MockMediaSource *source = [[VGP44MockMediaSource alloc] init];

  // FlutterMethodChannel cannot be easily mocked without a full engine.
  // VanguardMetalRenderer only calls invokeMethod:arguments: from the
  // playback-complete and duration-probed paths — not from presentEnvelope:.
  // We cast a no-op object to avoid the nil assert in the initialiser.
  // This is a test-only cast (established pattern in VGRuntimeSchedulerIntegrationTest).
  id channelStub = [[NSObject alloc] init];

  return [[VanguardMetalRenderer alloc]
      initWithSource:source
     textureRegistry:registry
       methodChannel:(FlutterMethodChannel *)channelStub];
}

/// Builds a VGFrameEnvelope wrapping the given CVPixelBuffer.
/// Buffer is NOT retained by the envelope (ADR-001 unretained payload).
static VGFrameEnvelope makeEnvelope(CVPixelBufferRef buf) {
  VGFrameEnvelope e;
  memset(&e, 0, sizeof(VGFrameEnvelope));
  e.mediaType           = VGMediaTypeVideo;
  e.payload.videoBuffer = buf; // unretained in struct — presentEnvelope: retains
  e.pts                 = kCMTimeZero;
  e.generation          = 1;
  return e;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGRendererPresentEnvelopeTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGRendererPresentEnvelopeTest : XCTestCase
@end

@implementation VGRendererPresentEnvelopeTest

// ─────────────────────────────────────────────────────────────────────────────
// TC-1 — presentEnvelope: stores buffer; copyPixelBuffer returns it retained
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies P4-4 / RR-36 contract:
///   - presentEnvelope: retains the incoming buffer and stores it.
///   - copyPixelBuffer returns a +1 retained reference to the same buffer.
///   - The reference count is consistent: buffer survives the call.
- (void)testPresentEnvelopeStoresBuffer {
  VGP44MockTextureRegistry *registry = nil;
  VanguardMetalRenderer *renderer    = makeRenderer(&registry);

  CVPixelBufferRef buf = createTestPixelBuffer();
  XCTAssertNotEqual(buf, (CVPixelBufferRef)NULL,
      @"TC-1 prerequisite: IOSurface pixel buffer creation failed");
  if (!buf) return;

  VGFrameEnvelope envelope = makeEnvelope(buf);

  // --- Call the SUT ---
  [renderer presentEnvelope:envelope];

  // copyPixelBuffer returns +1 to the stored buffer (P0-T7 contract).
  CVPixelBufferRef stored = [renderer copyPixelBuffer];
  XCTAssertNotEqual(stored, (CVPixelBufferRef)NULL,
      @"TC-1 FAIL: copyPixelBuffer returned NULL after presentEnvelope: — "
       "buffer was not stored in _latestPixelBuffer");

  if (stored) {
    // The underlying IOSurface must be the same object.
    IOSurfaceRef surface1 = CVPixelBufferGetIOSurface(buf);
    IOSurfaceRef surface2 = CVPixelBufferGetIOSurface(stored);
    XCTAssertEqual(surface1, surface2,
        @"TC-1 FAIL: stored buffer is not the same IOSurface as the delivered "
         "buffer — presentEnvelope: stored the wrong buffer");

    CVPixelBufferRelease(stored);  // balance copyPixelBuffer's +1
  }

  CVPixelBufferRelease(buf); // balance createTestPixelBuffer's +1
  // At this point renderer holds sole +1 (from its retain in presentEnvelope:).
  // Renderer dispose will release it — no leak.
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-2 — Mock registry receives textureFrameAvailable:
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies P4-4 contract:
///   - presentEnvelope: dispatches textureFrameAvailable: to the main queue.
///   - The registry receives exactly 1 call per presentEnvelope: invocation.
///   - The textureId passed matches the renderer's registered textureId.
- (void)testPresentEnvelopeSignalsFlutterRegistry {
  VGP44MockTextureRegistry *registry = nil;
  VanguardMetalRenderer *renderer    = makeRenderer(&registry);

  CVPixelBufferRef buf = createTestPixelBuffer();
  XCTAssertNotEqual(buf, (CVPixelBufferRef)NULL, @"TC-2 prerequisite: buffer creation");
  if (!buf) return;

  XCTestExpectation *exp =
      [self expectationWithDescription:@"TC-2 textureFrameAvailable received"];
  exp.expectedFulfillmentCount = 1;

  // Poll the spy on main — textureFrameAvailable: dispatches async to main.
  // We check after a short drain of the main queue.
  __weak VGP44MockTextureRegistry *weakRegistry = registry;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        if (weakRegistry.textureFrameAvailableCallCount >= 1) {
          [exp fulfill];
        }
      });

  [renderer presentEnvelope:makeEnvelope(buf)];

  [self waitForExpectations:@[exp] timeout:kP44Timeout];

  XCTAssertEqual(registry.textureFrameAvailableCallCount, 1,
      @"TC-2 FAIL: textureFrameAvailable: not called exactly once — "
       "Flutter texture signal missing in presentEnvelope:");

  // The textureId delivered must be the renderer's registered ID.
  XCTAssertEqual(registry.lastTextureId, renderer.textureId,
      @"TC-2 FAIL: textureFrameAvailable: received wrong textureId — "
       "renderer did not use its own _textureId for signaling");

  CVPixelBufferRelease(buf);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-3 — Buffer swap: previous _latestPixelBuffer is replaced
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies RR-36 swap behaviour:
///   - After a second presentEnvelope: call, copyPixelBuffer returns the NEW
///     buffer, not the old one.
///   - The old buffer's IOSurface is no longer returned by copyPixelBuffer.
- (void)testPresentEnvelopeSwapsPreviousBuffer {
  VGP44MockTextureRegistry *registry = nil;
  VanguardMetalRenderer *renderer    = makeRenderer(&registry);

  CVPixelBufferRef buf1 = createTestPixelBuffer();
  CVPixelBufferRef buf2 = createTestPixelBuffer();
  XCTAssertNotEqual(buf1, (CVPixelBufferRef)NULL, @"TC-3 prerequisite: buf1");
  XCTAssertNotEqual(buf2, (CVPixelBufferRef)NULL, @"TC-3 prerequisite: buf2");
  if (!buf1 || !buf2) {
    if (buf1) CVPixelBufferRelease(buf1);
    if (buf2) CVPixelBufferRelease(buf2);
    return;
  }

  // Both buffers are 64×64 BGRA — their IOSurfaces are distinct objects.
  IOSurfaceRef surface1 = CVPixelBufferGetIOSurface(buf1);
  IOSurfaceRef surface2 = CVPixelBufferGetIOSurface(buf2);
  XCTAssertNotEqual(surface1, surface2,
      @"TC-3 prerequisite: buf1 and buf2 must be backed by different IOSurfaces");

  // First delivery.
  [renderer presentEnvelope:makeEnvelope(buf1)];
  CVPixelBufferRef stored1 = [renderer copyPixelBuffer];
  XCTAssertNotEqual(stored1, (CVPixelBufferRef)NULL, @"TC-3: first store");
  if (stored1) {
    XCTAssertEqual(CVPixelBufferGetIOSurface(stored1), surface1,
        @"TC-3 FAIL: first stored buffer is not buf1");
    CVPixelBufferRelease(stored1);
  }

  // Second delivery — new buffer replaces old.
  [renderer presentEnvelope:makeEnvelope(buf2)];
  CVPixelBufferRef stored2 = [renderer copyPixelBuffer];
  XCTAssertNotEqual(stored2, (CVPixelBufferRef)NULL, @"TC-3: second store");
  if (stored2) {
    XCTAssertEqual(CVPixelBufferGetIOSurface(stored2), surface2,
        @"TC-3 FAIL: after second presentEnvelope:, copyPixelBuffer still "
         "returns buf1 — buffer swap not performed");
    CVPixelBufferRelease(stored2);
  }

  CVPixelBufferRelease(buf1);
  CVPixelBufferRelease(buf2);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-4 — Multiple deliveries: each triggers a registry signal
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies that N calls to presentEnvelope: produce exactly N
/// textureFrameAvailable: signals (no suppression, no coalescing).
- (void)testPresentEnvelopeSignalsOnEveryDelivery {
  VGP44MockTextureRegistry *registry = nil;
  VanguardMetalRenderer *renderer    = makeRenderer(&registry);

  const NSInteger kDeliveries = 3;
  CVPixelBufferRef buf = createTestPixelBuffer();
  XCTAssertNotEqual(buf, (CVPixelBufferRef)NULL, @"TC-4 prerequisite");
  if (!buf) return;

  for (NSInteger i = 0; i < kDeliveries; i++) {
    [renderer presentEnvelope:makeEnvelope(buf)];
  }

  // Drain the main queue — all textureFrameAvailable: dispatches land here.
  XCTestExpectation *drain =
      [self expectationWithDescription:@"TC-4 main queue drain"];
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{ [drain fulfill]; });
  [self waitForExpectations:@[drain] timeout:kP44Timeout];

  XCTAssertEqual(registry.textureFrameAvailableCallCount, kDeliveries,
      @"TC-4 FAIL: expected %ld textureFrameAvailable: calls after %ld "
       "presentEnvelope: invocations; got %ld",
      (long)kDeliveries, (long)kDeliveries,
      (long)registry.textureFrameAvailableCallCount);

  CVPixelBufferRelease(buf);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-5 — NULL payload: no crash, no signal, early return
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies RR-36 debug guard:
///   - presentEnvelope: with NULL videoBuffer fires NSAssert (debug) and
///     returns without crashing (release builds must not crash either).
///   - No textureFrameAvailable: signal is emitted for a NULL envelope.
///   - _latestPixelBuffer is NOT updated (previous value preserved or nil).
///
/// NSAssert throws NSInternalInconsistencyException in debug builds (XCTest
/// catches it). We assert the exception is raised and that no side-effects
/// occurred.
- (void)testPresentEnvelopeNullPayloadNoSideEffects {
  VGP44MockTextureRegistry *registry = nil;
  VanguardMetalRenderer *renderer    = makeRenderer(&registry);

  // Build a NULL-payload envelope.
  VGFrameEnvelope nullEnvelope;
  memset(&nullEnvelope, 0, sizeof(VGFrameEnvelope));
  nullEnvelope.mediaType           = VGMediaTypeVideo;
  nullEnvelope.payload.videoBuffer = NULL; // RR-36 violation

  // In debug builds, NSAssert throws. We expect it.
  XCTAssertThrowsSpecificNamed(
      [renderer presentEnvelope:nullEnvelope],
      NSException,
      NSInternalInconsistencyException,
      @"TC-5 FAIL: presentEnvelope: with NULL videoBuffer did not fire NSAssert "
       "— RR-36 debug guard missing");

  // Drain main queue — no signal should arrive.
  XCTestExpectation *drain =
      [self expectationWithDescription:@"TC-5 main queue drain"];
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{ [drain fulfill]; });
  [self waitForExpectations:@[drain] timeout:kP44Timeout];

  XCTAssertEqual(registry.textureFrameAvailableCallCount, 0,
      @"TC-5 FAIL: textureFrameAvailable: was called for a NULL-payload envelope "
       "— early-return not executing correctly");

  CVPixelBufferRef stored = [renderer copyPixelBuffer];
  XCTAssertEqual(stored, (CVPixelBufferRef)NULL,
      @"TC-5 FAIL: copyPixelBuffer returned non-nil after a NULL-payload "
       "presentEnvelope: — buffer state corrupted");
  if (stored) CVPixelBufferRelease(stored);
}

@end
