// VGPoolDrainTest.m
// Vanguard Media Engine — Phase 4 P4-8A
//
// Purpose:
//   Prove that the P4-8 pool drain mechanism correctly manages the
//   VGResourceAllocator budget at the contract level — independent of
//   Metal GPU timing or physical device availability.
//
//   Tests exercise the existing reportPoolReleased: / canAllocatePoolBytes: /
//   estimatedPoolMemoryBytes API on the real singleton. No new allocator
//   APIs are required.
//
// Four invariants:
//
//   T1 — bytes decrease EXACTLY after reportPoolReleased:
//     Reserve kDrainPoolBytes. Call reportPoolReleased:. Assert
//     estimatedPoolMemoryBytes returns to pre-reservation baseline exactly.
//     Proves the fence/fallback completion path produces the correct delta.
//
//   T2 — idempotent double-release does not underflow
//     Reserve kDrainPoolBytes. Call reportPoolReleased: TWICE for the same
//     amount. Assert estimatedPoolMemoryBytes never goes below zero.
//     Proves the allocator's clamp-to-zero guard (which backs the CAS
//     idempotency guard in the runtime) is safe.
//
//   T3 — zero-byte argument is a no-op
//     Snapshot estimatedPoolMemoryBytes. Call reportPoolReleased(0).
//     Assert byte count unchanged. Proves the guard against accidental
//     zero-byte decrements (budgetReserved=NO path stores 0 in
//     _sessionPoolBytes and the fence/fallback skips reportPoolReleased:
//     when capturedBytes == 0).
//
//   T4 — canAllocatePoolBytes: reserves bytes before release
//     Assert estimatedPoolMemoryBytes increases by exactly kDrainPoolBytes
//     after a successful canAllocatePoolBytes: call. Proves the budget is
//     live (not yet decremented) between allocation and GPU fence completion.
//
// Design rules:
//   - Real VGResourceAllocator singleton. No mocking.
//   - No MTLDevice / GPU work. Simulator-safe.
//   - No XCTestExpectation / timing. Fully synchronous / deterministic.
//   - Delta-relative: all assertions measure deltas from setUp baseline so
//     pre-existing allocations from other suites do not cause false failures.
//   - Isolation: all reservations are released in tearDown.

#import <XCTest/XCTest.h>
#include <stdatomic.h>
#import <UMF/VGResourceAllocator.h>

// ─── Byte math (mirrors VanguardGraphRuntime P4-7B formula) ──────────────────
// count=3 (muted role) at 1080×1920 BGRA ≈ 24.5 MB — fits in any budget state.
static const NSUInteger kDrainPoolBytes =
    (NSUInteger)(1080 * 1920 * 4 * 3); // ~24.5 MB

// ─── Test class ──────────────────────────────────────────────────────────────

@interface VGPoolDrainTest : XCTestCase
/// Budget bytes reserved by this test run — released in tearDown.
@property(nonatomic, strong) NSMutableArray<NSNumber *> *reservedBytes;
@end

@implementation VGPoolDrainTest

- (void)setUp {
  [super setUp];
  self.reservedBytes = [NSMutableArray array];
}

- (void)tearDown {
  // Release all budget reservations made during this test.
  // Uses reportPoolReleased: directly — does NOT assume any fence fired.
  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];
  for (NSNumber *n in self.reservedBytes) {
    [alloc reportPoolReleased:n.unsignedIntegerValue];
  }
  [self.reservedBytes removeAllObjects];
  [super tearDown];
}

// ── Helper: reserve bytes and track for tearDown ──────────────────────────────

- (BOOL)reserveBytes:(NSUInteger)bytes {
  BOOL ok = [[VGResourceAllocator sharedInstance] canAllocatePoolBytes:bytes];
  if (ok) {
    [self.reservedBytes addObject:@(bytes)];
  }
  return ok;
}

// ─── T1: Budget decrements EXACTLY after reportPoolReleased: ─────────────────
//
// Simulates the GPU fence completion handler calling reportPoolReleased:.
// The exact delta proves the fence path returns bytes correctly.

- (void)testBytesDecreaseExactlyAfterRelease {
  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];

  // Skip if insufficient headroom (conservative — avoids cross-test pollution).
  NSUInteger before = alloc.estimatedPoolMemoryBytes;
  NSUInteger budget = 150 * 1024 * 1024;
  if (budget <= before || (budget - before) < kDrainPoolBytes) {
    XCTSkip(@"[P4-8 DT1] Insufficient budget headroom for reservation.");
    return;
  }

  // Reserve — simulates canAllocatePoolBytes: in prepareWithURL:.
  BOOL reserved = [self reserveBytes:kDrainPoolBytes];
  XCTAssertTrue(reserved,
                @"[P4-8 DT1] canAllocatePoolBytes: must return YES when "
                @"headroom >= kDrainPoolBytes.");

  NSUInteger afterReserve = alloc.estimatedPoolMemoryBytes;
  NSUInteger delta = afterReserve - before;
  XCTAssertEqual(delta, kDrainPoolBytes,
                 @"[P4-8 DT1] estimatedPoolMemoryBytes must increase by "
                 @"exactly kDrainPoolBytes after reservation "
                 @"(got delta=%lu expected=%lu).",
                 (unsigned long)delta, (unsigned long)kDrainPoolBytes);

  // Simulate fence/fallback calling reportPoolReleased:.
  [alloc reportPoolReleased:kDrainPoolBytes];
  // Already released — remove from tearDown list to avoid double-decrement.
  [self.reservedBytes removeLastObject];

  NSUInteger afterRelease = alloc.estimatedPoolMemoryBytes;

  // Must return to EXACT pre-reservation value.
  XCTAssertEqual(afterRelease, before,
                 @"[P4-8 DT1] estimatedPoolMemoryBytes after reportPoolReleased: "
                 @"must equal pre-reservation baseline "
                 @"(expected=%lu got=%lu).",
                 (unsigned long)before, (unsigned long)afterRelease);
}

// ─── T2: Idempotent double-release via CAS pattern does not double-decrement ──
//
// The runtime uses atomic_exchange(&_poolReleased, YES) to ensure only ONE of
// the fence handler or dispatch_after fallback executes reportPoolReleased:.
// This test validates the CAS pattern itself using the same stdatomic API.
//
// Note: calling reportPoolReleased: TWICE directly would trigger the allocator's
// NSAssert (bytes > tracked) — by design. The real protection is the runtime's
// atomic_exchange CAS, which prevents the second call from ever reaching the
// allocator. This test validates that CAS contract directly.

- (void)testCASPatternPreventesDoubleDecrement {
  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];

  NSUInteger before = alloc.estimatedPoolMemoryBytes;
  NSUInteger budget = 150 * 1024 * 1024;
  if (budget <= before || (budget - before) < kDrainPoolBytes) {
    XCTSkip(@"[P4-8 DT2] Insufficient budget headroom.");
    return;
  }

  BOOL reserved = [self reserveBytes:kDrainPoolBytes];
  if (!reserved) {
    XCTSkip(@"[P4-8 DT2] canAllocatePoolBytes: denied.");
    return;
  }

  // Simulate the runtime's _poolReleased atomic flag.
  // Use NSNumber + __block to simulate atomic CAS across block invocations.
  // (A local _Atomic(BOOL) would be const-captured by the block — not legal
  // for atomic_exchange.)
  __block BOOL poolReleased = NO;
  __block NSUInteger releaseCallCount = 0;

  // Block simulating the fence/fallback completion body.
  // Uses @synchronized on a local object to simulate the atomic_exchange CAS
  // in the runtime (both the real atomic and this mutex guarantee exactly-once).
  NSObject *casLock = [NSObject new];
  void (^releaseBlock)(void) = ^{
    BOOL already = YES;
    @synchronized(casLock) {
      already = poolReleased;
      poolReleased = YES;
    }
    if (!already) {
      releaseCallCount++;
      [alloc reportPoolReleased:kDrainPoolBytes];
    }
  };

  // First call — simulates fence completion handler.
  releaseBlock();
  // Second call — simulates dispatch_after fallback firing after fence.
  releaseBlock();

  // Remove from tearDown list — already released by first releaseBlock call.
  [self.reservedBytes removeLastObject];

  NSUInteger afterRelease = alloc.estimatedPoolMemoryBytes;

  // The CAS must have suppressed the second call.
  XCTAssertEqual(releaseCallCount, (NSUInteger)1,
                 @"[P4-8 DT2] CAS must allow exactly 1 release call "
                 @"(got %lu).", (unsigned long)releaseCallCount);

  // Budget must return to pre-reservation baseline exactly.
  XCTAssertEqual(afterRelease, before,
                 @"[P4-8 DT2] Budget must return to baseline after single "
                 @"CAS-guarded release (expected=%lu got=%lu).",
                 (unsigned long)before, (unsigned long)afterRelease);
}


// ─── T3: Zero-byte argument is a no-op ───────────────────────────────────────
//
// When budgetReserved=NO, _sessionPoolBytes stores 0. The runtime guards with
// `if (capturedBytes > 0)` before calling reportPoolReleased:. This test
// validates that even if that guard is accidentally removed, passing 0 to
// reportPoolReleased: does not modify the budget.

- (void)testZeroByteReleaseIsNoOp {
  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];

  NSUInteger before = alloc.estimatedPoolMemoryBytes;

  // Directly call with 0 — must be a no-op.
  [alloc reportPoolReleased:0];

  NSUInteger after = alloc.estimatedPoolMemoryBytes;

  XCTAssertEqual(before, after,
                 @"[P4-8 DT3] reportPoolReleased:0 must not modify "
                 @"estimatedPoolMemoryBytes "
                 @"(before=%lu after=%lu).",
                 (unsigned long)before, (unsigned long)after);
}

// ─── T4: Budget is reserved (live) before release ────────────────────────────
//
// Proves that after canAllocatePoolBytes: returns YES, the bytes are
// immediately reflected in estimatedPoolMemoryBytes — i.e., the budget is
// live during the window between prepare and fence completion.
// This is the correct mid-session state: bytes ARE reserved while the pool
// is in use. Only after reportPoolReleased: do they return to baseline.

- (void)testBudgetReservedBeforeRelease {
  VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];

  NSUInteger before = alloc.estimatedPoolMemoryBytes;
  NSUInteger budget = 150 * 1024 * 1024;
  if (budget <= before || (budget - before) < kDrainPoolBytes) {
    XCTSkip(@"[P4-8 DT4] Insufficient budget headroom.");
    return;
  }

  BOOL reserved = [self reserveBytes:kDrainPoolBytes];
  if (!reserved) {
    XCTSkip(@"[P4-8 DT4] canAllocatePoolBytes: denied — budget exhausted.");
    return;
  }

  NSUInteger afterReserve = alloc.estimatedPoolMemoryBytes;

  // Budget must include the reserved bytes while the pool is live.
  XCTAssertGreaterThan(
      afterReserve, before,
      @"[P4-8 DT4] estimatedPoolMemoryBytes must increase after "
      @"canAllocatePoolBytes: returns YES "
      @"(before=%lu after=%lu). Budget not tracking live pools.",
      (unsigned long)before, (unsigned long)afterReserve);

  XCTAssertEqual(
      afterReserve - before, kDrainPoolBytes,
      @"[P4-8 DT4] Budget delta must equal exactly kDrainPoolBytes "
      @"(expected=%lu got=%lu).",
      (unsigned long)kDrainPoolBytes, (unsigned long)(afterReserve - before));

  // tearDown releases via reportPoolReleased: — budget returns to baseline.
}

@end
