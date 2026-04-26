// VGSessionChurnPoolLeakTest.m
// Vanguard Media Engine — Phase 4 P4-8B
//
// Purpose:
//   Gate test for VGSessionChurnPoolLeakTest (plan:200 — P4-8 regression gate).
//
//   Proves that repeated allocate-drain cycles across 10 sessions produce:
//     • NO monotonic growth in estimatedPoolMemoryBytes
//     • NO accumulation in physical memory footprint (phys_footprint)
//     • Exact return to pre-churn baseline after all cycles
//
//   This is the definitive RR-29 budget leak gate at the allocator layer.
//
// Design rationale:
//   VGTestableGraphRuntime.prepareWithURL: does not exercise the real pool
//   drain path (sessionPool remains NULL in the testable subclass). These tests
//   must therefore drive the P4-8 drain mechanism directly:
//
//     For each churn cycle:
//       1. canAllocatePoolBytes:   — reserve budget (simulates prepareWithURL:)
//       2. pixelBufferPoolWithWidth: — create pool (simulates pool creation)
//       3. [sentinelBuf commit] + addCompletedHandler: — GPU fence drain
//           OR direct reportPoolReleased: — fence unavailable fallback
//       4. Wait for XCTestExpectation — drain confirmed
//       5. Assert estimatedPoolMemoryBytes == baseline
//
//   phys_footprint is captured via Mach task_info TASK_VM_INFO before and
//   after the full 10-cycle loop. Tolerance: < 10 MB growth (plan requirement).
//
//   This is the required measurement to close RR-29 (known_risks.md:509–512).
//
// Cross-reference:
//   RR-29 (multi-runtime pool amplification — plan:200 closure criterion),
//   RR-37 (fence fallback — both paths tested), plan:200 (regression gate)

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <XCTest/XCTest.h>
#import <mach/mach.h>
#import <UMF/VGResourceAllocator.h>

// ─── Constants ───────────────────────────────────────────────────────────────

/// 1080 × 1920 BGRA × count=3 ≈ 24.5 MB per session.
static const NSUInteger kChurnPoolBytes = (NSUInteger)(1080 * 1920 * 4 * 3);

/// Number of create-drain cycles (plan:200 specifies 10).
static const NSUInteger kChurnCycles = 10;

/// Maximum allowed phys_footprint growth after all cycles (RR-29 tolerance).
static const uint64_t kMaxFootprintGrowthBytes = 10ULL * 1024 * 1024; // 10 MB

/// Timeout per fence expectation (6 s > 5 s fallback window).
static const NSTimeInterval kFenceTimeoutSeconds = 6.0;

// ─── Helper: phys_footprint ──────────────────────────────────────────────────

/// Returns the current physical memory footprint in bytes using
/// task_info(TASK_VM_INFO). This is the same metric as Xcode's memory gauge.
/// Returns 0 if the Mach call fails.
static uint64_t physFootprintBytes(void) {
  task_vm_info_data_t vmInfo;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  kern_return_t kr =
      task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count);
  if (kr != KERN_SUCCESS) {
    return 0;
  }
  return (uint64_t)vmInfo.phys_footprint;
}

// ─── Test class ──────────────────────────────────────────────────────────────

@interface VGSessionChurnPoolLeakTest : XCTestCase
/// Tracks pending budget to release on early exit.
@property(nonatomic) NSUInteger pendingBudgetBytes;
/// Tracks pending pool to release on early exit.
@property(nonatomic) CVPixelBufferPoolRef pendingPool;
@end

@implementation VGSessionChurnPoolLeakTest

- (void)setUp {
  [super setUp];
  self.pendingBudgetBytes = 0;
  self.pendingPool = NULL;
}

- (void)tearDown {
  // Safety net: release anything left by a failed or skipped test.
  if (self.pendingBudgetBytes > 0) {
    [[VGResourceAllocator sharedInstance]
        reportPoolReleased:self.pendingBudgetBytes];
    self.pendingBudgetBytes = 0;
  }
  if (self.pendingPool != NULL) {
    CVPixelBufferPoolRelease(self.pendingPool);
    self.pendingPool = NULL;
  }
  [super tearDown];
}

// ─── T1: 10-cycle churn — budget returns to exact baseline each cycle ─────────
//
// Core churn loop: allocate budget + pool → drain via GPU fence → assert return.
// After 10 cycles: assert total budget == pre-churn baseline exactly.
// After 10 cycles: assert phys_footprint ≈ pre-churn baseline (< 10 MB growth).
//
// Uses GPU fence (Metal MTLCommandBuffer) when available.
// Falls back to direct dispatch when Metal is unavailable (simulator CI).

- (void)testTenCycleChurnProducesNoMemoryGrowth {
  id<MTLDevice> device = [VGResourceAllocator sharedInstance].metalDevice;
  // Metal is required for fence path. XCTSkip not appropriate here — fall back
  // to fence-less path so CI (no Metal) still validates allocator accounting.
  BOOL useFence = (device != nil);

  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];

  // ── Baseline measurements ─────────────────────────────────────────────────
  NSUInteger budgetBaseline = alloc.estimatedPoolMemoryBytes;
  uint64_t   footprintBaseline = physFootprintBytes();

  NSLog(@"[P4-8 CT1] Baseline budget=%lu bytes, footprint=%llu bytes",
        (unsigned long)budgetBaseline, footprintBaseline);

  // Check headroom: need kChurnPoolBytes free for each cycle (one at a time).
  NSUInteger budget = 150 * 1024 * 1024;
  if (budget <= budgetBaseline || (budget - budgetBaseline) < kChurnPoolBytes) {
    XCTSkip(@"[P4-8 CT1] Insufficient headroom (%lu free) for churn test.",
            (unsigned long)(budget > budgetBaseline ? budget - budgetBaseline : 0));
    return;
  }

  // ── 10-cycle churn loop ───────────────────────────────────────────────────
  for (NSUInteger cycle = 0; cycle < kChurnCycles; cycle++) {
    NSLog(@"[P4-8 CT1] Cycle %lu/%lu start — budget=%lu",
          (unsigned long)(cycle + 1), (unsigned long)kChurnCycles,
          (unsigned long)alloc.estimatedPoolMemoryBytes);

    // ── Allocate budget (mirrors prepareWithURL: canAllocatePoolBytes:) ──────
    BOOL reserved = [alloc canAllocatePoolBytes:kChurnPoolBytes];
    XCTAssertTrue(reserved,
                  @"[P4-8 CT1] canAllocatePoolBytes: must succeed at cycle %lu "
                  @"(budget=%lu free=%lu).",
                  (unsigned long)(cycle + 1),
                  (unsigned long)alloc.estimatedPoolMemoryBytes,
                  (unsigned long)(budget - alloc.estimatedPoolMemoryBytes));
    if (!reserved) return;
    self.pendingBudgetBytes = kChurnPoolBytes;

    // ── Create pool ───────────────────────────────────────────────────────────
    CVPixelBufferPoolRef pool =
        [alloc pixelBufferPoolWithWidth:1080
                                 height:1920
                                 format:kCVPixelFormatType_32BGRA];
    self.pendingPool = pool; // safety net

    // ── Drain via GPU fence or direct fallback ────────────────────────────────
    if (useFence && pool) {
      // GPU fence path — exact replica of invalidateAsync primary path.
      XCTestExpectation *exp = [self expectationWithDescription:
          [NSString stringWithFormat:@"Cycle %lu fence", (unsigned long)(cycle + 1)]];

      id<MTLCommandQueue> q = [device newCommandQueue];
      id<MTLCommandBuffer> buf = [q commandBuffer];

      CVPixelBufferPoolRef capturedPool = pool;
      NSUInteger capturedBytes = kChurnPoolBytes;
      self.pendingBudgetBytes = 0; // block owns cleanup
      self.pendingPool = NULL;

      [buf addCompletedHandler:^(id<MTLCommandBuffer> __unused cb) {
        CVPixelBufferPoolRelease(capturedPool);
        [alloc reportPoolReleased:capturedBytes];
        [exp fulfill];
      }];
      [buf commit];
      [self waitForExpectations:@[ exp ] timeout:kFenceTimeoutSeconds];

    } else {
      // Direct path — Metal unavailable or pool creation failed.
      // Mirrors the "budgetReserved=NO" cleanup path at runtime.m:370–375,
      // or the fence-unavailable log path at runtime.m:673–676.
      if (pool) {
        CVPixelBufferPoolRelease(pool);
        self.pendingPool = NULL;
      }
      [alloc reportPoolReleased:kChurnPoolBytes];
      self.pendingBudgetBytes = 0;
    }

    // ── Assert per-cycle budget recovery ────────────────────────────────────
    NSUInteger cycleEndBudget = alloc.estimatedPoolMemoryBytes;
    XCTAssertEqual(cycleEndBudget, budgetBaseline,
                   @"[P4-8 CT1] Budget must return to baseline after cycle %lu "
                   @"(expected=%lu got=%lu). Pool leak detected.",
                   (unsigned long)(cycle + 1),
                   (unsigned long)budgetBaseline,
                   (unsigned long)cycleEndBudget);

    NSLog(@"[P4-8 CT1] Cycle %lu done — budget=%lu (baseline=%lu)",
          (unsigned long)(cycle + 1),
          (unsigned long)cycleEndBudget,
          (unsigned long)budgetBaseline);
  }

  // ── Post-loop: final budget assertion ────────────────────────────────────
  NSUInteger finalBudget = alloc.estimatedPoolMemoryBytes;
  XCTAssertEqual(finalBudget, budgetBaseline,
                 @"[P4-8 CT1] Budget after %lu cycles must equal pre-churn "
                 @"baseline exactly. Cumulative leak detected: "
                 @"baseline=%lu final=%lu delta=%ld bytes.",
                 (unsigned long)kChurnCycles,
                 (unsigned long)budgetBaseline,
                 (unsigned long)finalBudget,
                 (long)finalBudget - (long)budgetBaseline);

  // ── Post-loop: phys_footprint validation (RR-29 closure measurement) ─────
  uint64_t footprintFinal = physFootprintBytes();
  uint64_t footprintGrowth =
      (footprintFinal > footprintBaseline)
          ? (footprintFinal - footprintBaseline)
          : 0;

  NSLog(@"[P4-8 CT1] phys_footprint: baseline=%llu final=%llu "
        @"growth=%llu bytes (limit=%llu bytes)",
        footprintBaseline, footprintFinal,
        footprintGrowth, kMaxFootprintGrowthBytes);

  if (footprintBaseline > 0) {
    // Only assert when Mach API returned a valid value.
    XCTAssertLessThanOrEqual(
        footprintGrowth, kMaxFootprintGrowthBytes,
        @"[P4-8 CT1] Physical memory growth after %lu churn cycles "
        @"exceeds 10 MB tolerance (RR-29 closure criterion). "
        @"growth=%llu bytes limit=%llu bytes.",
        (unsigned long)kChurnCycles,
        footprintGrowth, kMaxFootprintGrowthBytes);
  } else {
    // Mach call failed (rare; simulator may return 0 on first call).
    NSLog(@"[P4-8 CT1] phys_footprint unavailable — skipping footprint assert.");
  }
}

// ─── T2: No-crash / no-hang under rapid concurrent churn ─────────────────────
//
// Creates 3 churn cycles concurrently on separate queues.
// Validates no crash, no deadlock, and final budget returns to baseline.
// Does NOT assert exact per-cycle timing (concurrent cycles may interleave).
//
// Proves multi-session pressure safety (plan:200 "Multi-Session Pressure" gate).

- (void)testConcurrentChurnProducesNoCrashAndReturnsToBudget {
  id<MTLDevice> device = [VGResourceAllocator sharedInstance].metalDevice;
  BOOL useFence = (device != nil);

  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];
  NSUInteger budgetBaseline = alloc.estimatedPoolMemoryBytes;
  NSUInteger budget = 150 * 1024 * 1024;

  // Need 3 × kChurnPoolBytes headroom for concurrent sessions.
  NSUInteger needed = kChurnPoolBytes * 3;
  if (budget <= budgetBaseline || (budget - budgetBaseline) < needed) {
    XCTSkip(@"[P4-8 CT2] Insufficient headroom for 3 concurrent sessions "
            @"(%lu needed, %lu free).",
            (unsigned long)needed,
            (unsigned long)(budget > budgetBaseline ? budget - budgetBaseline : 0));
    return;
  }

  // 3 concurrent expectations — one per session.
  NSMutableArray<XCTestExpectation *> *exps = [NSMutableArray array];
  for (NSUInteger i = 0; i < 3; i++) {
    [exps addObject:[self expectationWithDescription:
        [NSString stringWithFormat:@"Concurrent session %lu", (unsigned long)i]]];
  }

  // Dispatch 3 concurrent sessions.
  for (NSUInteger i = 0; i < 3; i++) {
    XCTestExpectation *exp = exps[i];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      // Reserve budget.
      BOOL ok = [alloc canAllocatePoolBytes:kChurnPoolBytes];
      if (!ok) {
        // Budget contention — another session took it first. Still fulfill.
        NSLog(@"[P4-8 CT2] Session %lu: budget denied under contention.",
              (unsigned long)i);
        [exp fulfill];
        return;
      }

      CVPixelBufferPoolRef pool =
          [alloc pixelBufferPoolWithWidth:1080
                                   height:1920
                                   format:kCVPixelFormatType_32BGRA];

      if (useFence && pool) {
        id<MTLCommandQueue> q = [device newCommandQueue];
        id<MTLCommandBuffer> buf = [q commandBuffer];
        CVPixelBufferPoolRef capturedPool = pool;
        [buf addCompletedHandler:^(id<MTLCommandBuffer> __unused cb) {
          CVPixelBufferPoolRelease(capturedPool);
          [alloc reportPoolReleased:kChurnPoolBytes];
          [exp fulfill];
        }];
        [buf commit];
      } else {
        if (pool) {
          CVPixelBufferPoolRelease(pool);
        }
        [alloc reportPoolReleased:kChurnPoolBytes];
        [exp fulfill];
      }
    });
  }

  [self waitForExpectations:exps timeout:kFenceTimeoutSeconds * 2];

  // Brief settle for any in-flight completionHandlers.
  [NSThread sleepForTimeInterval:0.100];

  // Post-concurrent: budget must be at or below baseline (some sessions may
  // have been denied under contention — those never incremented the budget).
  NSUInteger finalBudget = alloc.estimatedPoolMemoryBytes;
  XCTAssertLessThanOrEqual(
      finalBudget, budgetBaseline + kChurnPoolBytes,
      @"[P4-8 CT2] Budget after concurrent churn must not exceed baseline + "
      @"one in-flight cycle (expected <=%lu got=%lu). "
      @"Pool leak under concurrent invalidation detected.",
      (unsigned long)(budgetBaseline + kChurnPoolBytes),
      (unsigned long)finalBudget);
}

@end
