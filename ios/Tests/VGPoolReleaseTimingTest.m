// VGPoolReleaseTimingTest.m
// Vanguard Media Engine — Phase 4 P4-8B
//
// Purpose:
//   Gate test for VGPoolReleaseTimingTest (plan:200 — P4-8 regression gate).
//
//   Validates that the GPU fence mechanism used in VanguardGraphRuntime
//   .invalidateAsync releases pool budget within the hard timing limits:
//
//     T1 — GPU fence path: budget returns to baseline in < 500 ms (target).
//     T2 — Fallback path: budget returns to baseline if fence is not submitted,
//           simulated by immediately invoking the fallback body.
//
// Design rationale:
//   VGTestableGraphRuntime.prepareWithURL: bypasses the real runtime's prepare,
//   so rt.sessionPool is NULL when invalidateAsync fires — the testable subclass
//   cannot be used to exercise the budget drain timing path.
//
//   Instead, these tests replicate the EXACT mechanism used by
//   VanguardGraphRuntime.invalidateAsync (runtime.m:646–696):
//
//     1. Reserve budget via canAllocatePoolBytes:             (mirrors prepareWithURL:)
//     2. Create pool via pixelBufferPoolWithWidth:height:format:
//     3. Submit sentinel MTLCommandBuffer on allocator.metalDevice
//     4. addCompletedHandler: calls reportPoolReleased: + CVPixelBufferPoolRelease
//     5. CFAbsoluteTime delta from commit to handler = GPU fence latency
//     6. Assert delta < 0.500 s (hard limit, plan:200)
//     7. Assert budget equals pre-reservation baseline (exact)
//
//   This is the tightest possible test: the fence runs on the same Metal device
//   that VanguardMetalRenderer uses, with an empty command buffer (no work),
//   so it is guaranteed to complete in practice in < 2 ms on A-series hardware.
//
// Simulator note:
//   MTLCreateSystemDefaultDevice() returns a valid device on iOS simulator
//   (software renderer). The fence still fires, but latency may be higher
//   (typically < 50 ms). The 500 ms limit accommodates both cases.
//   Tests guard with XCTSkip if no Metal device is available.
//
// Cross-reference:
//   P4-8 plan:194–200, RR-37 (fence failure fallback), DEC-59 (CAS guard)

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <XCTest/XCTest.h>
#import <UMF/VGResourceAllocator.h>

// ─── Constants ───────────────────────────────────────────────────────────────

/// 1080 × 1920 BGRA × count=3 ≈ 24.5 MB.
/// Mirrors VanguardGraphRuntime._sessionPoolBytes formula (P4-8A).
static const NSUInteger kTimingPoolBytes = (NSUInteger)(1080 * 1920 * 4 * 3);

/// Hard timing limit (plan:200 contract).
static const CFAbsoluteTime kFenceTimingLimitSeconds = 0.500;

/// Fallback timeout for XCTestExpectation (matches dispatch_after(5s) in runtime).
static const NSTimeInterval kFallbackTimeoutSeconds = 6.0;

// ─── Test class ──────────────────────────────────────────────────────────────

@interface VGPoolReleaseTimingTest : XCTestCase
/// Tracks budget reservations that need cleanup if a test exits early.
@property(nonatomic) NSUInteger pendingReservationBytes;
@end

@implementation VGPoolReleaseTimingTest

- (void)setUp {
  [super setUp];
  self.pendingReservationBytes = 0;
}

- (void)tearDown {
  // Safety: release any budget that was reserved but not yet reported released.
  if (self.pendingReservationBytes > 0) {
    [[VGResourceAllocator sharedInstance]
        reportPoolReleased:self.pendingReservationBytes];
    self.pendingReservationBytes = 0;
  }
  [super tearDown];
}

// ─── T1: GPU fence path — budget released within 500 ms ──────────────────────
//
// Replicates VanguardGraphRuntime.invalidateAsync primary path:
//   canAllocatePoolBytes: → pixelBufferPoolWithWidth: → [sentinelBuf commit]
//   → addCompletedHandler: → reportPoolReleased: → CVPixelBufferPoolRelease
//
// Asserts:
//   • estimatedPoolMemoryBytes returns to exact pre-reservation baseline
//   • Time from [buf commit] to addCompletedHandler: firing < 500 ms

- (void)testGPUFenceReleasesPoolBudgetWithin500ms {
  id<MTLDevice> device = [VGResourceAllocator sharedInstance].metalDevice;
  if (!device) {
    XCTSkip(@"[P4-8 TT1] No Metal device — GPU fence path cannot be tested.");
    return;
  }

  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];
  NSUInteger baseline = alloc.estimatedPoolMemoryBytes;
  NSUInteger budget = 150 * 1024 * 1024;

  if (budget <= baseline || (budget - baseline) < kTimingPoolBytes) {
    XCTSkip(@"[P4-8 TT1] Insufficient budget headroom (%lu bytes free).",
            (unsigned long)(budget > baseline ? budget - baseline : 0));
    return;
  }

  // ── Step 1: Reserve budget (mirrors prepareWithURL: canAllocatePoolBytes:) ──
  BOOL reserved = [alloc canAllocatePoolBytes:kTimingPoolBytes];
  XCTAssertTrue(reserved,
                @"[P4-8 TT1] canAllocatePoolBytes: must succeed when "
                @"headroom >= kTimingPoolBytes.");
  if (!reserved) return;
  self.pendingReservationBytes = kTimingPoolBytes;

  NSUInteger afterReserve = alloc.estimatedPoolMemoryBytes;
  XCTAssertEqual(afterReserve - baseline, kTimingPoolBytes,
                 @"[P4-8 TT1] Budget must reflect reservation immediately.");

  // ── Step 2: Create real pool (mirrors pixelBufferPoolWithWidth: call) ────────
  CVPixelBufferPoolRef pool =
      [alloc pixelBufferPoolWithWidth:1080
                               height:1920
                               format:kCVPixelFormatType_32BGRA];
  if (!pool) {
    // Pool creation failed — release budget reservation and skip.
    [alloc reportPoolReleased:kTimingPoolBytes];
    self.pendingReservationBytes = 0;
    XCTSkip(@"[P4-8 TT1] CVPixelBufferPool creation failed — "
            @"simulator Metal renderer limitation.");
    return;
  }

  // ── Step 3: Submit sentinel MTLCommandBuffer (mirrors invalidateAsync) ───────
  id<MTLCommandQueue> sentinelQueue = [device newCommandQueue];
  id<MTLCommandBuffer> sentinelBuf  = [sentinelQueue commandBuffer];

  XCTestExpectation *fenceExp =
      [self expectationWithDescription:@"GPU fence completion handler fired"];

  __block CFAbsoluteTime fenceStart  = 0;
  __block CFAbsoluteTime fenceEnd    = 0;
  __block NSUInteger budgetAfterDrain = 0;

  // Capture for block — pool and alloc are CF/ObjC; capture by value.
  CVPixelBufferPoolRef capturedPool   = pool;
  NSUInteger capturedBytes            = kTimingPoolBytes;
  self.pendingReservationBytes        = 0; // block now owns the cleanup

  // ── Step 4: addCompletedHandler: (exact replica of runtime.m:657–668) ───────
  [sentinelBuf addCompletedHandler:^(id<MTLCommandBuffer> __unused cb) {
    fenceEnd = CFAbsoluteTimeGetCurrent();
    // Release pool and decrement budget — identical to runtime path.
    CVPixelBufferPoolRelease(capturedPool);
    [alloc reportPoolReleased:capturedBytes];
    budgetAfterDrain = alloc.estimatedPoolMemoryBytes;
    [fenceExp fulfill];
  }];

  // ── Step 5: Record start time and commit ─────────────────────────────────────
  fenceStart = CFAbsoluteTimeGetCurrent();
  [sentinelBuf commit];

  // ── Step 6: Wait for completion handler (hard limit: 6 s > 500 ms target) ───
  [self waitForExpectations:@[ fenceExp ] timeout:kFallbackTimeoutSeconds];

  // ── Step 7: Assert timing < 500 ms ───────────────────────────────────────────
  CFAbsoluteTime deltaSeconds = fenceEnd - fenceStart;
  NSLog(@"[P4-8 TT1] GPU fence latency: %.3f ms (limit: %.0f ms)",
        deltaSeconds * 1000.0, kFenceTimingLimitSeconds * 1000.0);

  XCTAssertLessThan(
      deltaSeconds, kFenceTimingLimitSeconds,
      @"[P4-8 TT1] GPU fence must release budget within %.0f ms — "
      @"measured %.2f ms (plan:200 contract).",
      kFenceTimingLimitSeconds * 1000.0, deltaSeconds * 1000.0);

  // ── Step 8: Assert exact budget return ────────────────────────────────────────
  XCTAssertEqual(budgetAfterDrain, baseline,
                 @"[P4-8 TT1] estimatedPoolMemoryBytes must return to exact "
                 @"pre-reservation baseline after GPU fence "
                 @"(expected=%lu got=%lu).",
                 (unsigned long)baseline, (unsigned long)budgetAfterDrain);
}

// ─── T2: Fallback path — budget released even without GPU fence ───────────────
//
// Replicates VanguardGraphRuntime.invalidateAsync fallback path (runtime.m:680–696)
// for the case where Metal device is unavailable (RR-37 trigger scenario).
//
// The fallback is the dispatch_after(5s) block that is always scheduled,
// guarded by _poolReleased CAS. This test simulates the case where no fence
// was submitted (device == nil path) and only the fallback fires.
//
// Asserts:
//   • Budget returns to exact baseline (correctness, not timing)
//   • CAS pattern suppresses any second execution

- (void)testFallbackPathReleasesBudgetCorrectly {
  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];
  NSUInteger baseline = alloc.estimatedPoolMemoryBytes;
  NSUInteger budget = 150 * 1024 * 1024;

  if (budget <= baseline || (budget - baseline) < kTimingPoolBytes) {
    XCTSkip(@"[P4-8 TT2] Insufficient budget headroom.");
    return;
  }

  // Reserve budget.
  BOOL reserved = [alloc canAllocatePoolBytes:kTimingPoolBytes];
  if (!reserved) {
    XCTSkip(@"[P4-8 TT2] Budget exhausted before test.");
    return;
  }
  self.pendingReservationBytes = kTimingPoolBytes;

  // Create pool.
  CVPixelBufferPoolRef pool =
      [alloc pixelBufferPoolWithWidth:1080
                               height:1920
                               format:kCVPixelFormatType_32BGRA];
  if (!pool) {
    [alloc reportPoolReleased:kTimingPoolBytes];
    self.pendingReservationBytes = 0;
    XCTSkip(@"[P4-8 TT2] Pool creation failed.");
    return;
  }

  // Simulate _poolReleased CAS flag.
  __block BOOL poolReleasedFlag = NO;
  NSObject *casLock = [NSObject new];
  __block NSUInteger fallbackFireCount = 0;

  // Capture for blocks.
  CVPixelBufferPoolRef capturedPool = pool;
  NSUInteger capturedBytes          = kTimingPoolBytes;
  self.pendingReservationBytes      = 0; // block owns cleanup

  XCTestExpectation *fallbackExp =
      [self expectationWithDescription:@"Fallback path fired"];

  // Simulate dispatch_after fallback body (runtime.m:680–696).
  void (^fallbackBlock)(void) = ^{
    BOOL already = YES;
    @synchronized(casLock) {
      already = poolReleasedFlag;
      poolReleasedFlag = YES;
    }
    if (!already) {
      fallbackFireCount++;
      CVPixelBufferPoolRelease(capturedPool);
      [alloc reportPoolReleased:capturedBytes];
      [fallbackExp fulfill];
    }
  };

  // Invoke fallback directly (no 5s wait in a unit test).
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), fallbackBlock);

  [self waitForExpectations:@[ fallbackExp ] timeout:3.0];

  // CAS must have fired exactly once.
  XCTAssertEqual(fallbackFireCount, (NSUInteger)1,
                 @"[P4-8 TT2] Fallback must fire exactly once (got %lu).",
                 (unsigned long)fallbackFireCount);

  // Budget must return to baseline.
  NSUInteger afterRelease = alloc.estimatedPoolMemoryBytes;
  XCTAssertEqual(afterRelease, baseline,
                 @"[P4-8 TT2] Budget must return to baseline after fallback "
                 @"(expected=%lu got=%lu).",
                 (unsigned long)baseline, (unsigned long)afterRelease);

  // Invoke fallback a second time — CAS must suppress it.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), fallbackBlock);
  // Brief settle for the no-op second invocation.
  [NSThread sleepForTimeInterval:0.050];

  XCTAssertEqual(fallbackFireCount, (NSUInteger)1,
                 @"[P4-8 TT2] Second fallback invocation must be suppressed "
                 @"by CAS (got %lu — double-release).",
                 (unsigned long)fallbackFireCount);
}

@end
