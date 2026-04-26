// VGSchedulerFrameDeliveryTest.m
// vanguard_media_engine — Phase 4, P4-5
//
// Gate test: VGSchedulerFrameDeliveryTest
//
// Purpose:
//   Validates that VanguardGraphScheduler.didReceiveRawFrame: (the VGFrameDelegate
//   entry point activated in P4-5) correctly receives a raw frame and delivers it
//   to its sink via presentEnvelope: without touching the renderer runtime filter
//   shim (setRuntimeFilterChain: / _runtimeFilterChain).
//
// Validates (plan §8.2, line 375):
//   - presentEnvelope: is called on the sink (≥ 1 per didReceiveRawFrame: call).
//   - Scheduler-side delivery counter > 0.
//   - Delivered envelope carries non-null videoBuffer.
//   - pts and generation are preserved through the scheduler path.
//   - No crash.
//
// Contract anchors:
//   - RR-31: Scheduler receives frame; setRuntimeFilterChain: is NOT called.
//   - RR-36: Source-owned buffer not released by scheduler (no filter nodes).
//   - DEC-50: setRuntimeFilterChain: renderer shim is not involved.
//   - DEC-54: Chain snapshot runs under _chainLock with zero nodes; released
//             before any ObjC call.
//
// Approach:
//   VanguardMetalRenderer requires initWithSource: — init is NS_UNAVAILABLE.
//   We cannot subclass it cheaply for tests without a real source/registrar.
//
//   Solution: VGP45SinkSpy is a plain NSObject that responds to
//   presentEnvelope: (declared via a local @protocol + category trick-free
//   approach: we add the method and assign via unsafe cast to the weak property).
//
//   Since scheduler.sink is typed as `VanguardMetalRenderer * _Nullable weak`,
//   we declare a VGP45SinkSpy subclass of NSObject and assign it via an
//   unsafe bridged cast. At runtime, ObjC message dispatch resolves
//   presentEnvelope: on the actual isa, not the declared type. The weak
//   reference storage is safe because VGP45SinkSpy is a proper NSObject.
//   The __unsafe_unretained assignment is used only for the typed property.
//
//   This is the minimal, production-code-free approach that validates the
//   scheduler delivery path without requiring Flutter/Metal bootstrap.

#import <XCTest/XCTest.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CMTime.h>
#import <objc/runtime.h>

#import "VanguardGraphScheduler.h"
#import "VanguardMetalRenderer.h"   // for presentEnvelope: selector + VGFrameEnvelope
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGFrameDelegate.h>

// ─── VGP45SinkSpy ────────────────────────────────────────────────────────────
//
// Plain NSObject spy that implements presentEnvelope: for test interception.
// Typed as NSObject; assigned to scheduler.sink via unsafe cast (see below).
// Does NOT subclass VanguardMetalRenderer (init is NS_UNAVAILABLE).
//
// ObjC runtime dispatches presentEnvelope: via isa — the concrete method
// on VGP45SinkSpy is found and called regardless of the static type of the
// `sink` property.

@interface VGP45SinkSpy : NSObject

@property(nonatomic, assign) NSUInteger presentEnvelopeCallCount;
@property(nonatomic, assign) VGFrameEnvelope lastDeliveredEnvelope;

- (void)presentEnvelope:(VGFrameEnvelope)envelope;

@end

@implementation VGP45SinkSpy

- (instancetype)init {
  self = [super init];
  if (!self) return nil;
  _presentEnvelopeCallCount = 0;
  return self;
}

- (void)presentEnvelope:(VGFrameEnvelope)envelope {
  _presentEnvelopeCallCount++;
  _lastDeliveredEnvelope = envelope;
}

@end

// ─── VGSchedulerFrameDeliveryTest ────────────────────────────────────────────

@interface VGSchedulerFrameDeliveryTest : XCTestCase
@end

@implementation VGSchedulerFrameDeliveryTest {
  VanguardGraphScheduler *_scheduler;
  VGP45SinkSpy           *_spy;
  CVPixelBufferRef        _testBuffer;
}

// Helper: wire spy to scheduler.sink via unsafe cast.
// The scheduler's -didReceiveRawFrame: calls [sink presentEnvelope:envelope]
// using normal ObjC message dispatch — isa resolution finds VGP45SinkSpy's imp.
- (void)_wireSpy {
  // Suppress type-mismatch: intentional duck-type test seam.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincompatible-pointer-types"
  _scheduler.sink = (VanguardMetalRenderer *)_spy;
#pragma clang diagnostic pop
}

- (void)setUp {
  [super setUp];

  _scheduler = [[VanguardGraphScheduler alloc] init];
  XCTAssertNotNil(_scheduler, @"Scheduler must initialise");

  _spy = [[VGP45SinkSpy alloc] init];
  XCTAssertNotNil(_spy, @"Spy must initialise");
  [self _wireSpy];

  // No filter chain — source-owned passthrough (RR-36, DEC-54).

  // Allocate a minimal 16×16 BGRA CVPixelBuffer.
  NSDictionary *attrs = @{ (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{} };
  CVReturn status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      16, 16,
      kCVPixelFormatType_32BGRA,
      (__bridge CFDictionaryRef)attrs,
      &_testBuffer);
  XCTAssertEqual(status, kCVReturnSuccess,
      @"CVPixelBufferCreate must succeed");
}

- (void)tearDown {
  if (_testBuffer) { CVPixelBufferRelease(_testBuffer); _testBuffer = NULL; }
  _scheduler.sink = nil;
  [_scheduler invalidate];
  _scheduler = nil;
  _spy = nil;
  [super tearDown];
}

// ─── Test 1 ──────────────────────────────────────────────────────────────────
// didReceiveRawFrame: calls presentEnvelope: exactly once per invocation.
// Primary P4-5 gate: plan line 375 "presentEnvelope: called ≥ 30 times"
// (unit-test equivalent: ≥ 1 per call, counter > 0).

- (void)testDidReceiveRawFrameCallsPresentEnvelopeOnce {
  VGFrameEnvelope envelope;
  memset(&envelope, 0, sizeof(VGFrameEnvelope));
  envelope.payload.videoBuffer = _testBuffer;
  envelope.pts                 = CMTimeMakeWithSeconds(1.0, 600);
  envelope.generation          = 7;
  envelope.mediaType           = VGMediaTypeVideo;

  [_scheduler didReceiveRawFrame:envelope];

  XCTAssertEqual(_spy.presentEnvelopeCallCount, (NSUInteger)1,
      @"presentEnvelope: must be called exactly once per didReceiveRawFrame:");
}

// ─── Test 2 ──────────────────────────────────────────────────────────────────
// Delivered envelope carries non-null videoBuffer.

- (void)testDeliveredEnvelopeHasNonNullVideoBuffer {
  VGFrameEnvelope envelope;
  memset(&envelope, 0, sizeof(VGFrameEnvelope));
  envelope.payload.videoBuffer = _testBuffer;
  envelope.pts                 = CMTimeMakeWithSeconds(2.0, 600);
  envelope.generation          = 1;
  envelope.mediaType           = VGMediaTypeVideo;

  [_scheduler didReceiveRawFrame:envelope];

  XCTAssertTrue(_spy.lastDeliveredEnvelope.payload.videoBuffer != NULL,
      @"Delivered envelope must carry non-null videoBuffer (source passthrough)");
}

// ─── Test 3 ──────────────────────────────────────────────────────────────────
// pts preserved through scheduler path (no filter nodes → passthrough).

- (void)testDeliveredEnvelopePreservesPts {
  CMTime expectedPts = CMTimeMakeWithSeconds(3.5, 600);

  VGFrameEnvelope envelope;
  memset(&envelope, 0, sizeof(VGFrameEnvelope));
  envelope.payload.videoBuffer = _testBuffer;
  envelope.pts                 = expectedPts;
  envelope.generation          = 0;
  envelope.mediaType           = VGMediaTypeVideo;

  [_scheduler didReceiveRawFrame:envelope];

  CMTime deliveredPts = _spy.lastDeliveredEnvelope.pts;
  XCTAssertTrue(CMTimeCompare(deliveredPts, expectedPts) == 0,
      @"Delivered pts must match input pts (no filter transformation)");
}

// ─── Test 4 ──────────────────────────────────────────────────────────────────
// generation preserved through scheduler path.

- (void)testDeliveredEnvelopePreservesGeneration {
  uint64_t expectedGeneration = 42;

  VGFrameEnvelope envelope;
  memset(&envelope, 0, sizeof(VGFrameEnvelope));
  envelope.payload.videoBuffer = _testBuffer;
  envelope.pts                 = CMTimeMakeWithSeconds(0.0, 600);
  envelope.generation          = expectedGeneration;
  envelope.mediaType           = VGMediaTypeVideo;

  [_scheduler didReceiveRawFrame:envelope];

  XCTAssertEqual(_spy.lastDeliveredEnvelope.generation, expectedGeneration,
      @"Delivered generation must match input");
}

// ─── Test 5 ──────────────────────────────────────────────────────────────────
// Multiple sequential frames — counter grows monotonically.
// Validates plan "counter > 0" for repeated delivery.

- (void)testMultipleFramesAccumulateDeliveryCount {
  const NSUInteger frameCount = 5;

  for (NSUInteger i = 0; i < frameCount; i++) {
    VGFrameEnvelope envelope;
    memset(&envelope, 0, sizeof(VGFrameEnvelope));
    envelope.payload.videoBuffer = _testBuffer;
    envelope.pts                 = CMTimeMakeWithSeconds((double)i * 0.033, 600);
    envelope.generation          = i;
    envelope.mediaType           = VGMediaTypeVideo;
    [_scheduler didReceiveRawFrame:envelope];
  }

  XCTAssertEqual(_spy.presentEnvelopeCallCount, frameCount,
      @"presentEnvelope: call count must equal frame count (%lu)",
      (unsigned long)frameCount);
}

// ─── Test 6 ──────────────────────────────────────────────────────────────────
// After invalidate, didReceiveRawFrame: is no-op — presentEnvelope: not called.
// Verifies _invalidated guard (scheduler-side teardown safety).

- (void)testDidReceiveRawFrameIsNoOpAfterInvalidate {
  [_scheduler invalidate];

  VGFrameEnvelope envelope;
  memset(&envelope, 0, sizeof(VGFrameEnvelope));
  envelope.payload.videoBuffer = _testBuffer;
  envelope.pts                 = CMTimeMakeWithSeconds(0.0, 600);
  envelope.generation          = 0;
  envelope.mediaType           = VGMediaTypeVideo;

  [_scheduler didReceiveRawFrame:envelope];

  XCTAssertEqual(_spy.presentEnvelopeCallCount, (NSUInteger)0,
      @"After invalidate, didReceiveRawFrame: must not call presentEnvelope:");
}

// ─── Test 7 ──────────────────────────────────────────────────────────────────
// Nil sink: frame dropped without crash.
// Validates `if (!sink) return;` guard in didReceiveRawFrame:.

- (void)testNilSinkDropsFrameWithoutCrash {
  _scheduler.sink = nil;

  VGFrameEnvelope envelope;
  memset(&envelope, 0, sizeof(VGFrameEnvelope));
  envelope.payload.videoBuffer = _testBuffer;
  envelope.pts                 = CMTimeMakeWithSeconds(0.0, 600);
  envelope.generation          = 0;
  envelope.mediaType           = VGMediaTypeVideo;

  XCTAssertNoThrow([_scheduler didReceiveRawFrame:envelope],
      @"Nil sink must not crash — frame is dropped safely");
}

@end
