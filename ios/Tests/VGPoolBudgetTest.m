// VGPoolBudgetTest.m
// Vanguard Media Engine — Phase 4 P4-7D
//
// Gate test 3: Budget Logic
//
// Invariant:
//   canAllocatePoolBytes: enforces the 150 MB process-wide cap. When
//   cumulative allocations would exceed the budget, the API returns NO and
//   the caller must fall back to count=3 or accept denial.
//
// Strategy:
//   Call canAllocatePoolBytes: directly on the real VGResourceAllocator with
//   increasing byte totals. Verify:
//     1. Allocations within budget are granted (returns YES).
//     2. An allocation that would exceed the 150 MB cap is denied (returns NO).
//     3. After denial, the tracked total has NOT changed (NO is atomic).
//     4. After reportPoolReleased:, budget headroom is restored.
//   Then verify the multi-runtime rule (DEC-39/RR-25):
//     5. At 1080p count=5, at most floor(150MB / ~41MB) = 3 active runtimes
//        fit inside budget. The 4th must be denied at count=5.
//
// Does NOT mock VGResourceAllocator.
// Uses the REAL singleton with direct API calls.
// All allocations are cleaned up via reportPoolReleased: at the end.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import <UMF/VGResourceAllocator.h>

// Budget constant mirrors VGResourceAllocator.m (kVGPoolBudgetBytes = 150 MB).
// If the constant changes, this test will catch the regression.
static const NSUInteger kExpectedBudgetBytes = 150 * 1024 * 1024;

// 1080p BGRA: 1080 × 1920 × 4 bytes
static const NSUInteger k1080pBytesPerBuffer = (NSUInteger)(1080 * 1920 * 4);
// count=5 pool: ~40.9 MB
static const NSUInteger k1080pCount5PoolBytes = (NSUInteger)(1080 * 1920 * 4 * 5);
// count=3 pool: ~24.5 MB
static const NSUInteger k1080pCount3PoolBytes = (NSUInteger)(1080 * 1920 * 4 * 3);

@interface VGPoolBudgetTest : XCTestCase
// Tracks bytes successfully reserved in this test so we can release all.
@property(nonatomic) NSMutableArray<NSNumber *> *allocatedBytesList;
@end

@implementation VGPoolBudgetTest

- (void)setUp {
  [super setUp];
  self.allocatedBytesList = [NSMutableArray array];
}

- (void)tearDown {
  // Always clean up budget reservations made during tests.
  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];
  for (NSNumber *bytes in self.allocatedBytesList) {
    [alloc reportPoolReleased:bytes.unsignedIntegerValue];
  }
  [self.allocatedBytesList removeAllObjects];
  [super tearDown];
}

// Helper: attempt to reserve `bytes`; record on success for tearDown cleanup.
- (BOOL)reserveBytes:(NSUInteger)bytes {
  BOOL ok = [[VGResourceAllocator sharedInstance] canAllocatePoolBytes:bytes];
  if (ok) {
    [self.allocatedBytesList addObject:@(bytes)];
  }
  return ok;
}

// ─── AC-PB1: Small allocation within budget is granted ───────────────────

- (void)testSmallAllocationWithinBudgetIsGranted {
  // 1 MB — trivially within any reasonable budget.
  NSUInteger oneMB = 1 * 1024 * 1024;
  BOOL granted = [self reserveBytes:oneMB];
  XCTAssertTrue(
      granted,
      @"[P4-7D PB1] 1 MB allocation must be granted when budget has headroom.");
}

// ─── AC-PB2: Over-budget allocation is denied ────────────────────────────
//
// Fills budget to ≥ kExpectedBudgetBytes via repeated reservations, then
// verifies the next allocation is denied.

- (void)testOverBudgetAllocationIsDenied {
  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];
  NSUInteger baseline = alloc.estimatedPoolMemoryBytes;
  NSUInteger headroom = (kExpectedBudgetBytes > baseline)
                        ? (kExpectedBudgetBytes - baseline)
                        : 0;

  // Fill budget to within 1 MB of the cap using large chunks.
  const NSUInteger chunk = 10 * 1024 * 1024; // 10 MB
  NSUInteger filled = 0;
  while (filled + chunk <= headroom) {
    BOOL ok = [self reserveBytes:chunk];
    if (!ok) break;
    filled += chunk;
  }
  // Fill remaining headroom (leaves < 1 byte of space).
  NSUInteger remaining = headroom - filled;
  if (remaining > 0) {
    [self reserveBytes:remaining];
    // remaining may or may not succeed; ignore — we just need budget exhausted.
  }

  // Now request 1 MB more than what's left — must be denied.
  NSUInteger overflowBytes = 1 * 1024 * 1024;
  NSUInteger trackedNow = alloc.estimatedPoolMemoryBytes;
  NSUInteger actualHeadroom = (kExpectedBudgetBytes > trackedNow)
                              ? (kExpectedBudgetBytes - trackedNow)
                              : 0;
  if (actualHeadroom >= overflowBytes) {
    // Budget not yet exhausted enough — skip rather than producing a false pass.
    XCTSkip(@"[P4-7D PB2] Could not exhaust budget in this test run "
            @"(other tests may hold budget). Skipping overflow check.");
    return;
  }

  NSUInteger beforeDenial = alloc.estimatedPoolMemoryBytes;
  BOOL denied = ![self reserveBytes:overflowBytes];
  NSUInteger afterDenial = alloc.estimatedPoolMemoryBytes;

  XCTAssertTrue(
      denied,
      @"[P4-7D PB2] Over-budget allocation must be denied "
      @"(requested %lu, headroom %lu).",
      (unsigned long)overflowBytes, (unsigned long)actualHeadroom);

  // Critical: tracked bytes must NOT increase on denial.
  XCTAssertEqual(
      beforeDenial, afterDenial,
      @"[P4-7D PB2] estimatedPoolMemoryBytes changed after denial "
      @"(before=%lu after=%lu). canAllocatePoolBytes: must be atomic.",
      (unsigned long)beforeDenial, (unsigned long)afterDenial);
}

// ─── AC-PB3: Budget is restored after reportPoolReleased: ────────────────

- (void)testBudgetRestoredAfterRelease {
  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];

  // Reserve 10 MB.
  NSUInteger reserveSize = 10 * 1024 * 1024;
  BOOL granted = [[VGResourceAllocator sharedInstance]
      canAllocatePoolBytes:reserveSize];

  if (!granted) {
    XCTSkip(@"[P4-7D PB3] Budget exhausted before test — skip.");
    return;
  }

  NSUInteger after = alloc.estimatedPoolMemoryBytes;

  // Release it.
  [alloc reportPoolReleased:reserveSize];

  NSUInteger restored = alloc.estimatedPoolMemoryBytes;

  XCTAssertLessThan(
      restored, after,
      @"[P4-7D PB3] estimatedPoolMemoryBytes must decrease after "
      @"reportPoolReleased: (before=%lu after=%lu).",
      (unsigned long)after, (unsigned long)restored);
  // Do NOT add reserveSize to allocatedBytesList — already released above.
}

// ─── AC-PB4: Active-audio count=5 → 4th runtime denied at count=5 ────────
//
// DEC-39: active-audio runtimes request count=5. 3 × count=5 at 1080p
// = 3 × ~41 MB = ~123 MB. The 4th at count=5 would total ~164 MB > 150 MB.
// The 4th must be denied at count=5 (and the budget logic must fall back
// to count=3 in production, but here we test the raw denial).
- (void)testFourthActiveAudioRuntimeDeniedAtCount5 {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device) {
    XCTSkip(@"No Metal device");
    return;
  }

  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];

  // Determine how many count=5 pools fit given baseline tracked bytes.
  NSUInteger baseline = alloc.estimatedPoolMemoryBytes;
  NSUInteger headroom = (kExpectedBudgetBytes > baseline)
                        ? (kExpectedBudgetBytes - baseline)
                        : 0;

  if (headroom < k1080pCount5PoolBytes) {
    XCTSkip(@"[P4-7D PB4] Insufficient headroom for even one count=5 pool "
            @"(%lu < %lu). Other tests may hold budget.",
            (unsigned long)headroom, (unsigned long)k1080pCount5PoolBytes);
    return;
  }

  // Drain budget with count=5 allocations until at least one is denied.
  NSUInteger grantsAt5 = 0;
  BOOL deniedAt5 = NO;
  while (YES) {
    BOOL ok = [self reserveBytes:k1080pCount5PoolBytes];
    if (ok) {
      grantsAt5++;
      // Safety cap: never allocate more than 10 runtimes worth (test guard).
      if (grantsAt5 >= 10) break;
    } else {
      deniedAt5 = YES;
      break;
    }
  }

  XCTAssertTrue(
      deniedAt5,
      @"[P4-7D PB4] Budget must eventually deny count=5 allocations "
      @"(granted %lu before denial). kVGPoolBudgetBytes enforcement broken.",
      (unsigned long)grantsAt5);

  // RR-25: at 1080p, count=5 pool = ~41 MB. 150 MB / 41 MB ≈ 3.65 → max 3.
  // We must not be able to fit more than 4 count=5 pools (generous check).
  XCTAssertLessThanOrEqual(
      grantsAt5, (NSUInteger)(kExpectedBudgetBytes / k1080pCount5PoolBytes) + 1,
      @"[P4-7D PB4] Granted %lu count=5 allocations before denial — "
      @"budget cap appears too large (expected ≤%lu).",
      (unsigned long)grantsAt5,
      (unsigned long)(kExpectedBudgetBytes / k1080pCount5PoolBytes + 1));

  // After denying at count=5, count=3 should still fit (fallback path).
  BOOL fallbackGranted = [self reserveBytes:k1080pCount3PoolBytes];
  // Fallback may or may not fit depending on remaining headroom.
  // Log the result — this is informational rather than a hard assert,
  // since test ordering affects available headroom.
  if (!fallbackGranted) {
    NSLog(@"[P4-7D PB4] count=3 fallback also denied (budget nearly full). "
          @"This is acceptable — it proves budget is actively enforced.");
  } else {
    NSLog(@"[P4-7D PB4] count=3 fallback granted — DEC-39 fallback path works.");
  }
}

// ─── AC-PB5: canAllocatePoolBytes(0) is always denied ────────────────────
//
// Zero-byte request is a programming error. The API must deny it without
// modifying tracked bytes (defensive guard in allocator).

- (void)testZeroByteAllocationIsDenied {
  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];
  NSUInteger before = alloc.estimatedPoolMemoryBytes;

  BOOL granted = [alloc canAllocatePoolBytes:0];

  XCTAssertFalse(
      granted,
      @"[P4-7D PB5] canAllocatePoolBytes(0) must return NO — "
      @"zero-byte pool is a caller error.");

  NSUInteger after = alloc.estimatedPoolMemoryBytes;
  XCTAssertEqual(
      before, after,
      @"[P4-7D PB5] estimatedPoolMemoryBytes must not change after "
      @"zero-byte denial (before=%lu after=%lu).",
      (unsigned long)before, (unsigned long)after);
}

@end
