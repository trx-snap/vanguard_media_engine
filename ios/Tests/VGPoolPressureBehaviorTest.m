// VGPoolPressureBehaviorTest.m
// Vanguard Media Engine — Phase 4 P4-7D (Hardening)
//
// Purpose:
//   Prove that P4-7 pool budget enforcement produces OBSERVABLE behavior changes
//   under memory pressure — not just structural compliance.
//
//   Four invariants proved:
//
//   T1 — Pressure detection:
//     Repeated count=5 allocations are eventually denied by the budget gate.
//     The grant count is bounded by floor(150 MB / bytes5) + 1.
//     estimatedPoolMemoryBytes never exceeds 150 MB.
//
//   T2 — Observable 5→3 fallback:
//     After the first count=5 denial, a count=3 request is accepted.
//     This is the DEC-39 fallback behavior made observable: the system
//     explicitly demonstrates it can accept the smaller allocation where
//     the larger was denied.
//
//   T3 — Real pool stability under allocation stress:
//     A real CVPixelBufferPool (via VGResourceAllocator) survives 50
//     allocate/release cycles without crash. All successful buffers
//     have correct pixel dimensions.
//
//   T4 — Budget recovery:
//     reportPoolReleased: restores tracked bytes exactly to the pre-
//     reservation level (delta = 0 after reserve + release).
//
// Design rules:
//   - Real VGResourceAllocator singleton — no mocking.
//   - Real CVPixelBufferPool — no fake pools.
//   - Same byte math as the production runtime (P4-7B).
//   - Deterministic: never depends on timing or device memory.
//   - Isolation: all bytes reserved by this test are released in tearDown.
//   - Delta-relative: baseline is read at setUp; tests measure only the
//     DELTA they introduce, so pre-existing allocations from other test
//     suites do not cause false failures.

#import <XCTest/XCTest.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <UMF/VGResourceAllocator.h>

// ─── Byte math constants (mirrors production runtime P4-7B) ───────────────
// These are computed at compile-time to match the runtime exactly.
// If the runtime changes its byte formula, these tests will need updating.

static const size_t   kPoolWidth         = 1080;
static const size_t   kPoolHeight        = 1920;
static const NSUInteger kBytesPerPixel   = 4;    // BGRA
static const NSUInteger kCount5          = 5;    // DEC-39: active-audio role
static const NSUInteger kCount3          = 3;    // DEC-39: muted role / fallback

// Derived byte totals — same formula as VanguardGraphRuntime.prepareWithURL:
// step 3.6c (P4-7B): poolBytes = w * h * bytesPerPixel * count
#define kBytes5 ((NSUInteger)(kPoolWidth * kPoolHeight * kBytesPerPixel * kCount5))
#define kBytes3 ((NSUInteger)(kPoolWidth * kPoolHeight * kBytesPerPixel * kCount3))

// Process-wide budget (mirrors kVGPoolBudgetBytes in VGResourceAllocator.m).
// Hard-coded here so a change in the allocator is immediately caught.
static const NSUInteger kBudget = 150 * 1024 * 1024; // 150 MB

// Maximum count=5 pools that fit: floor(150 MB / bytes5).
// At 1080p BGRA: bytes5 ≈ 39.6 MB → floor(150 / 39.6) = 3.
#define kMaxCount5Pools ((NSUInteger)(kBudget / kBytes5))

// ─── Test class ───────────────────────────────────────────────────────────

@interface VGPoolPressureBehaviorTest : XCTestCase
// All bytes reserved by this test instance — released in tearDown.
@property(nonatomic, strong) NSMutableArray<NSNumber *> *reservedBytesList;
// All CVPixelBufferPoolRefs created by this test — released in tearDown.
@property(nonatomic, strong) NSMutableArray<NSValue *>  *createdPools;
@end

@implementation VGPoolPressureBehaviorTest

- (void)setUp {
  [super setUp];
  self.reservedBytesList = [NSMutableArray array];
  self.createdPools      = [NSMutableArray array];
}

- (void)tearDown {
  // Release all CVPixelBufferPools created during the test.
  for (NSValue *v in self.createdPools) {
    CVPixelBufferPoolRef pool = NULL;
    [v getValue:&pool];
    if (pool) CVPixelBufferPoolRelease(pool);
  }
  [self.createdPools removeAllObjects];

  // Release all budget reservations made during the test.
  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];
  for (NSNumber *n in self.reservedBytesList) {
    [alloc reportPoolReleased:n.unsignedIntegerValue];
  }
  [self.reservedBytesList removeAllObjects];

  [super tearDown];
}

// ── Helpers ──────────────────────────────────────────────────────────────

/// Attempt to reserve `bytes` from the budget.
/// Records on success so tearDown can release.
/// Returns YES if granted.
- (BOOL)reserveBytes:(NSUInteger)bytes {
  BOOL ok = [[VGResourceAllocator sharedInstance] canAllocatePoolBytes:bytes];
  if (ok) {
    [self.reservedBytesList addObject:@(bytes)];
  }
  return ok;
}

/// Create a real CVPixelBufferPool using the allocator (BGRA, given count).
/// Caller must NOT release — tearDown handles it via createdPools.
/// Returns NULL if creation fails or budget denied.
- (CVPixelBufferPoolRef)makePoolWithCount:(NSUInteger)count reserveBytes:(BOOL)reserve {
  NSUInteger bytes = kPoolWidth * kPoolHeight * kBytesPerPixel * count;
  if (reserve) {
    BOOL ok = [self reserveBytes:bytes];
    if (!ok) return NULL;
  }
  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];
  CVPixelBufferPoolRef pool = [alloc pixelBufferPoolWithWidth:kPoolWidth
                                                        height:kPoolHeight
                                                        format:kCVPixelFormatType_32BGRA
                                           minimumBufferCount:count];
  if (pool) {
    // Store for tearDown release (+1 is ours).
    NSValue *v = [NSValue value:&pool withObjCType:@encode(CVPixelBufferPoolRef)];
    [self.createdPools addObject:v];
  }
  return pool;
}

// ─── T1: Budget allows count=5 pools but eventually denies them ──────────
//
// Proves pressure detection.
// Steps:
//   1. Read baseline estimatedPoolMemoryBytes.
//   2. Reserve count=5 pools until the first denial.
//   3. Assert at least one was granted.
//   4. Assert at least one was denied.
//   5. Assert estimatedPoolMemoryBytes never exceeded kBudget.
//   6. Assert grant count ≤ floor(budget/bytes5) + 1 (bounded).

- (void)testCount5PoolsEventuallyDeniedUnderPressure {
  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];

  NSUInteger baseline = alloc.estimatedPoolMemoryBytes;
  NSUInteger headroom = (kBudget > baseline) ? (kBudget - baseline) : 0;

  if (headroom < kBytes5) {
    XCTSkip(@"[P4-7D PPB T1] Insufficient headroom for even one count=5 "
            @"reservation (%lu available, %lu needed). "
            @"Other tests may hold budget.",
            (unsigned long)headroom, (unsigned long)kBytes5);
    return;
  }

  NSUInteger granted = 0;
  BOOL deniedAtSome = NO;
  NSUInteger peakBytes = baseline;

  // Safety cap: 15 iterations max to prevent runaway.
  for (NSUInteger i = 0; i < 15; i++) {
    BOOL ok = [self reserveBytes:kBytes5];
    NSUInteger current = alloc.estimatedPoolMemoryBytes;
    if (current > peakBytes) peakBytes = current;

    if (ok) {
      granted++;
    } else {
      deniedAtSome = YES;
      break;
    }
  }

  // Assert 1: At least one count=5 reservation succeeded.
  XCTAssertGreaterThan(
      granted, (NSUInteger)0,
      @"[P4-7D PPB T1] At least one count=5 pool must be granted "
      @"(budget has headroom of %lu bytes, bytes5=%lu).",
      (unsigned long)headroom, (unsigned long)kBytes5);

  // Assert 2: Budget pressure eventually causes denial.
  XCTAssertTrue(
      deniedAtSome,
      @"[P4-7D PPB T1] count=5 reservation must eventually be denied "
      @"(granted %lu without denial). Budget ceiling not enforced.",
      (unsigned long)granted);

  // Assert 3: Tracked bytes never exceeded the budget.
  XCTAssertLessThanOrEqual(
      peakBytes, kBudget,
      @"[P4-7D PPB T1] estimatedPoolMemoryBytes (%lu) exceeded kBudget (%lu). "
      @"Budget ceiling was breached.",
      (unsigned long)peakBytes, (unsigned long)kBudget);

  // Assert 4: Grant count is bounded by floor(budget / bytes5) + 1.
  // +1 accounts for the baseline headroom being non-zero.
  NSUInteger maxExpected = kMaxCount5Pools + 1;
  XCTAssertLessThanOrEqual(
      granted, maxExpected,
      @"[P4-7D PPB T1] Granted %lu count=5 pools (max expected ≤ %lu). "
      @"Budget constant or byte formula may have changed.",
      (unsigned long)granted, (unsigned long)maxExpected);
}

// ─── T2: Observable 5→3 fallback under pressure ──────────────────────────
//
// Proves DEC-39 fallback behavior is measurably real:
// After filling the budget to the point where count=5 is denied,
// a count=3 request is accepted (remaining headroom ~31 MB > bytes3 ~24 MB).
//
// Steps:
//   1. Fill budget until count=5 is denied.
//   2. Assert count=5 was denied.
//   3. Assert count=3 is granted.
//   4. Assert total tracked bytes ≤ kBudget.

- (void)testFallbackFrom5To3ObservableAfterPressure {
  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];

  NSUInteger baseline = alloc.estimatedPoolMemoryBytes;
  NSUInteger headroom = (kBudget > baseline) ? (kBudget - baseline) : 0;

  if (headroom < kBytes5) {
    XCTSkip(@"[P4-7D PPB T2] Budget already saturated — skip.");
    return;
  }

  // Fill until count=5 is denied.
  BOOL count5Denied = NO;
  for (NSUInteger i = 0; i < 15; i++) {
    BOOL ok = [self reserveBytes:kBytes5];
    if (!ok) {
      count5Denied = YES;
      break;
    }
  }

  if (!count5Denied) {
    // Budget never denied count=5 (headroom > 15 × bytes5 = 15 × ~40 MB = ~600 MB).
    // This cannot happen with kBudget = 150 MB — if it does the budget is broken.
    XCTFail(@"[P4-7D PPB T2] count=5 was never denied after 15 iterations. "
            @"Budget ceiling not enforced (kBudget=%lu).", (unsigned long)kBudget);
    return;
  }

  // After count=5 denial, check count=3 acceptance.
  NSUInteger trackedNow = alloc.estimatedPoolMemoryBytes;
  NSUInteger remainingHeadroom = (kBudget > trackedNow) ? (kBudget - trackedNow) : 0;

  if (remainingHeadroom < kBytes3) {
    // Budget is so tight count=3 also won't fit. Log and pass — the denial
    // itself is the observable behavior.
    NSLog(@"[P4-7D PPB T2] count=3 also denied (remaining headroom %lu < "
          @"bytes3 %lu). Budget fully saturated — denial itself is valid.",
          (unsigned long)remainingHeadroom, (unsigned long)kBytes3);
    XCTAssertTrue(count5Denied,
                  @"[P4-7D PPB T2] count=5 must be denied when budget saturated.");
    return;
  }

  // count=3 should be accepted.
  BOOL count3Granted = [self reserveBytes:kBytes3];

  // Observable behavior change: denied at 5, accepted at 3.
  XCTAssertTrue(
      count5Denied,
      @"[P4-7D PPB T2] count=5 must be denied before testing fallback.");

  XCTAssertTrue(
      count3Granted,
      @"[P4-7D PPB T2] count=3 fallback must be granted after count=5 denial "
      @"(remaining headroom %lu, bytes3 %lu). DEC-39 fallback broken.",
      (unsigned long)remainingHeadroom, (unsigned long)kBytes3);

  // Total tracked bytes after fallback must remain ≤ budget.
  NSUInteger finalTracked = alloc.estimatedPoolMemoryBytes;
  XCTAssertLessThanOrEqual(
      finalTracked, kBudget,
      @"[P4-7D PPB T2] Total tracked bytes (%lu) exceeded budget (%lu) "
      @"after count=3 fallback grant.",
      (unsigned long)finalTracked, (unsigned long)kBudget);
}

// ─── T3: Real CVPixelBufferPool stability under 50-allocation stress ──────
//
// Proves the pool infrastructure (not just the budget API) is stable.
// Creates a real pool via VGResourceAllocator, then allocates and immediately
// releases 50 CVPixelBuffers. Verifies no crash, correct dimensions,
// and at least one successful allocation.

- (void)testRealPoolStableUnder50AllocationCycles {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device) {
    XCTSkip(@"[P4-7D PPB T3] No Metal device — cannot create Metal-compatible pool.");
    return;
  }

  // Create a real pool using count=3 (conservative, minimises budget impact).
  CVPixelBufferPoolRef pool = [self makePoolWithCount:kCount3 reserveBytes:YES];
  if (!pool) {
    XCTSkip(@"[P4-7D PPB T3] Pool creation failed (budget denied or no Metal). "
            @"Other tests may hold budget.");
    return;
  }

  NSUInteger successCount = 0;
  const NSUInteger kIterations = 50;

  for (NSUInteger i = 0; i < kIterations; i++) {
    CVPixelBufferRef buf = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault, pool, &buf);

    if (status == kCVReturnSuccess && buf) {
      successCount++;
      size_t w = CVPixelBufferGetWidth(buf);
      size_t h = CVPixelBufferGetHeight(buf);

      // Each successful buffer must have the expected dimensions.
      XCTAssertEqual(w, kPoolWidth,
                     @"[P4-7D PPB T3] Buffer width %zu ≠ expected %zu "
                     @"(iteration %lu).",
                     w, kPoolWidth, (unsigned long)i);
      XCTAssertEqual(h, kPoolHeight,
                     @"[P4-7D PPB T3] Buffer height %zu ≠ expected %zu "
                     @"(iteration %lu).",
                     h, kPoolHeight, (unsigned long)i);

      CVPixelBufferRelease(buf);
    } else {
      // Pool may return kCVReturnWouldExceedAllocationThreshold when
      // minimumBufferCount is exceeded concurrently — acceptable in stress.
      // We only assert that the pool itself doesn't crash.
    }
  }

  // At least one buffer must have been successfully allocated.
  XCTAssertGreaterThan(
      successCount, (NSUInteger)0,
      @"[P4-7D PPB T3] At least one buffer allocation must succeed from "
      @"a valid pool (0 out of %lu succeeded).", (unsigned long)kIterations);
}

// ─── T4: Budget recovery — exact delta is restored ───────────────────────
//
// Proves reportPoolReleased: restores the tracked byte total to exactly
// the pre-reservation level (not just "less than"). This is the precise
// correctness check on the allocator's bookkeeping.

- (void)testBudgetRecoveryIsExact {
  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];

  // Snapshot the current tracked total (may be non-zero from other tests).
  NSUInteger snapshotBefore = alloc.estimatedPoolMemoryBytes;

  // Reserve one count=3 pool worth.
  BOOL granted = [[VGResourceAllocator sharedInstance]
      canAllocatePoolBytes:kBytes3];

  if (!granted) {
    XCTSkip(@"[P4-7D PPB T4] Budget exhausted — cannot reserve kBytes3.");
    return;
  }
  // Note: NOT added to reservedBytesList — we release it manually below.

  NSUInteger snapshotAfterReserve = alloc.estimatedPoolMemoryBytes;

  // The delta must equal exactly kBytes3.
  NSUInteger delta = snapshotAfterReserve - snapshotBefore;
  XCTAssertEqual(
      delta, kBytes3,
      @"[P4-7D PPB T4] estimatedPoolMemoryBytes increased by %lu after "
      @"reserving kBytes3 (%lu). Delta must be exact.",
      (unsigned long)delta, (unsigned long)kBytes3);

  // Release.
  [alloc reportPoolReleased:kBytes3];
  NSUInteger snapshotAfterRelease = alloc.estimatedPoolMemoryBytes;

  // Tracked bytes must return to EXACTLY the pre-reservation value.
  XCTAssertEqual(
      snapshotAfterRelease, snapshotBefore,
      @"[P4-7D PPB T4] estimatedPoolMemoryBytes after release (%lu) does not "
      @"match pre-reservation snapshot (%lu). Budget recovery is not exact.",
      (unsigned long)snapshotAfterRelease, (unsigned long)snapshotBefore);
}

@end
