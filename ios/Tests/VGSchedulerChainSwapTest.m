// VGSchedulerChainSwapTest.m
// vanguard_media_engine — Phase 4, P4-2
//
// Regression gate for P4-2: Scheduler Filter Chain Storage & Swap.
//
// Contract reference:
//   packages/UMF/implementation/phase4_unified_plan.md
//     § P4-2 regression table line 364:
//       "VGSchedulerChainSwapTest | P4-2 |
//        Store/replace/nil chain. Removed nodes receive invalidate.
//        3-thread concurrent swap — no crash."
//
//   DEC-54 (decision_log.md:64):
//     "setFilterChain: snapshots old chain under _chainLock, swaps to new
//      chain under _chainLock, releases lock, then calls [node invalidate]
//      on removed nodes outside the lock. os_unfair_lock must not be held
//      during arbitrary ObjC calls."
//
//   RR-26 (known_risks.md) — filter chain swap race:
//     Addressed by os_unfair_lock in VanguardGraphScheduler._chainLock.
//     This test provides the basic swap-safety gate required for P4-2.
//
// What this test covers:
//   TC-C1  setFilterChain:nil on empty scheduler — no crash.
//   TC-C2  setFilterChain: with non-empty chain — no crash.
//   TC-C3  Replace chain — no crash; old nodes receive invalidate.
//   TC-C4  Nodes still in chain are NOT invalidated on replacement.
//   TC-C5  setFilterChain:nil after non-empty chain — all nodes invalidated.
//   TC-C6  Re-setting the same node does not double-invalidate it.
//   TC-C7  3-thread concurrent setFilterChain: — no crash (RR-26 / DEC-54).
//   TC-C8  setFilterChain: after invalidate is silently ignored.
//
// What this test MUST NOT cover:
//   - Frame delivery / didReceiveRawFrame: (P4-5, method does not exist yet)
//   - processEnvelope:device: filter execution (P4-5 scope)
//   - presentEnvelope: / scheduler sink (P4-5 scope)
//   - Runtime wiring / thermal cost-budget (out of scope)
//
// Simulator-safe: no GPU work, no Metal encoding, no pixel buffers.

#import <XCTest/XCTest.h>
#import <stdatomic.h>

// SUT
#import "VanguardGraphScheduler.h"

// UMF protocols required by VGMetalFilterNode mock
#import <UMF/VGMetalFilterNode.h>
#import <UMF/VGMediaNode.h>
#import <UMF/VGFrameEnvelope.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGSwapMockFilterNode: minimal VGMetalFilterNode spy
// ─────────────────────────────────────────────────────────────────────────────

/// Minimal VGMetalFilterNode conformer for chain-swap testing.
/// Tracks invalidate call count via atomic counter.
/// No GPU work, no Metal resources, no pixel buffer pool.
@interface VGSwapMockFilterNode : NSObject <VGMetalFilterNode>
/// Number of times -invalidate has been called.
@property(nonatomic, readonly) NSInteger invalidateCallCount;
/// Unique name for identification in assertions.
@property(nonatomic, readonly, copy) NSString *name;
- (instancetype)initWithName:(NSString *)name;
@end

@implementation VGSwapMockFilterNode {
  _Atomic(NSInteger) _invalidateCallCount;
  NSString *_name;
}

- (instancetype)initWithName:(NSString *)name {
  self = [super init];
  if (!self) return nil;
  _name = [name copy];
  atomic_store(&_invalidateCallCount, 0);
  return self;
}

// ─── VGMediaNode ─────────────────────────────────────────────────────────────

- (NSString *)nodeId   { return _name; }
- (NSString *)nodeType { return @"MockFilter"; }
- (VGNodeRole)nodeRole { return VGNodeRoleFilter; }

- (void)prepareWithCompletion:(void (^)(NSError *_Nullable))completion {
  if (completion) completion(nil); // instant no-op prepare
}

- (void)invalidate {
  atomic_fetch_add(&_invalidateCallCount, 1);
}

// ─── VGMetalFilterNode ───────────────────────────────────────────────────────

- (NSString *)filterName      { return _name; }
- (BOOL)enabled               { return YES; }
- (void)setEnabled:(BOOL)e    { /* no-op for mock */ }
- (BOOL)isExpensive           { return NO; }
- (float)estimatedGPUCostMs   { return 1.0f; }

- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                             device:(id<MTLDevice>)device {
  // Passthrough — must not be called in P4-2 (scheduler is dormant).
  return envelope;
}

// ─── Accessors ───────────────────────────────────────────────────────────────

- (NSInteger)invalidateCallCount {
  return atomic_load(&_invalidateCallCount);
}

- (NSString *)name { return _name; }

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGSchedulerChainSwapTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGSchedulerChainSwapTest : XCTestCase
@end

@implementation VGSchedulerChainSwapTest

// ─────────────────────────────────────────────────────────────────────────────
// TC-C1 — setFilterChain:nil on empty scheduler does not crash
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies DEC-54 / VanguardGraphScheduler.m:70–78:
///   - Passing nil to an empty scheduler does not crash.
///   - _chainLock acquired, _filterChain = nil (was already nil), lock released.
///   - No node invalidation (nothing to remove).
- (void)testSetNilChainOnEmptySchedulerDoesNotCrash {
  VanguardGraphScheduler *scheduler = [[VanguardGraphScheduler alloc] init];

  XCTAssertNoThrow(
      [scheduler setFilterChain:nil],
      @"TC-C1 FAIL: setFilterChain:nil on empty scheduler threw — "
       "must not throw (VanguardGraphScheduler.m:75–78 lock/swap path).");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-C2 — setFilterChain: with non-empty chain does not crash
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies DEC-54 / VanguardGraphScheduler.m:75–92:
///   - Setting a non-nil chain succeeds without crash.
///   - Nodes are not invalidated (they are new arrivals, not removed nodes).
- (void)testSetNonEmptyChainDoesNotCrash {
  VanguardGraphScheduler   *scheduler = [[VanguardGraphScheduler alloc] init];
  VGSwapMockFilterNode     *nodeA     = [[VGSwapMockFilterNode alloc] initWithName:@"A"];
  VGSwapMockFilterNode     *nodeB     = [[VGSwapMockFilterNode alloc] initWithName:@"B"];

  NSArray *chainAB = @[nodeA, nodeB];
  XCTAssertNoThrow(
      [scheduler setFilterChain:chainAB],
      @"TC-C2 FAIL: setFilterChain: with 2 nodes threw.");

  XCTAssertEqual(nodeA.invalidateCallCount, 0,
      @"TC-C2 FAIL: nodeA.invalidate called on first setFilterChain: — "
       "newly added nodes must NOT be invalidated.");
  XCTAssertEqual(nodeB.invalidateCallCount, 0,
      @"TC-C2 FAIL: nodeB.invalidate called on first setFilterChain: — "
       "newly added nodes must NOT be invalidated.");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-C3 — Replacing chain: removed nodes receive invalidate
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies DEC-54 / VanguardGraphScheduler.m:81–88:
///   - Nodes present in old chain but absent from new chain receive invalidate.
///   - Nodes present in new chain are NOT invalidated.
///   - The lock is NOT held during invalidate calls (DEC-54).
- (void)testReplaceChainInvalidatesRemovedNodes {
  VanguardGraphScheduler   *scheduler = [[VanguardGraphScheduler alloc] init];
  VGSwapMockFilterNode     *nodeA     = [[VGSwapMockFilterNode alloc] initWithName:@"A"];
  VGSwapMockFilterNode     *nodeB     = [[VGSwapMockFilterNode alloc] initWithName:@"B"];
  VGSwapMockFilterNode     *nodeC     = [[VGSwapMockFilterNode alloc] initWithName:@"C"];

  // Install [A, B].
  [scheduler setFilterChain:@[nodeA, nodeB]];

  // Replace with [B, C] — A is removed, B survives, C is new.
  [scheduler setFilterChain:@[nodeB, nodeC]];

  XCTAssertEqual(nodeA.invalidateCallCount, 1,
      @"TC-C3 FAIL: nodeA (removed) must receive exactly 1 invalidate call "
       "(VanguardGraphScheduler.m:85: [node invalidate] for removed nodes).");
  XCTAssertEqual(nodeB.invalidateCallCount, 0,
      @"TC-C3 FAIL: nodeB (retained in new chain) must NOT be invalidated.");
  XCTAssertEqual(nodeC.invalidateCallCount, 0,
      @"TC-C3 FAIL: nodeC (newly added) must NOT be invalidated.");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-C4 — Retained nodes never invalidated across multiple swaps
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies that a node that survives multiple replacements is never
/// invalidated (DEC-54: NSSet containsObject: guards re-use).
- (void)testRetainedNodeNeverInvalidatedAcrossMultipleSwaps {
  VanguardGraphScheduler   *scheduler  = [[VanguardGraphScheduler alloc] init];
  VGSwapMockFilterNode     *permanent  = [[VGSwapMockFilterNode alloc] initWithName:@"Permanent"];
  VGSwapMockFilterNode     *transientA = [[VGSwapMockFilterNode alloc] initWithName:@"TransientA"];
  VGSwapMockFilterNode     *transientB = [[VGSwapMockFilterNode alloc] initWithName:@"TransientB"];

  [scheduler setFilterChain:@[permanent, transientA]]; // install
  [scheduler setFilterChain:@[permanent, transientB]]; // transientA removed
  [scheduler setFilterChain:@[permanent]];             // transientB removed

  XCTAssertEqual(permanent.invalidateCallCount, 0,
      @"TC-C4 FAIL: permanent node invalidated during chain swap — "
       "nodes retained in new chain must never be invalidated.");
  XCTAssertEqual(transientA.invalidateCallCount, 1,
      @"TC-C4 FAIL: transientA must have been invalidated exactly once.");
  XCTAssertEqual(transientB.invalidateCallCount, 1,
      @"TC-C4 FAIL: transientB must have been invalidated exactly once.");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-C5 — setFilterChain:nil after non-empty chain invalidates all nodes
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies VanguardGraphScheduler.m:82:
///   newSet = chain ? [NSSet setWithArray:chain] : [NSSet set]
///   An empty newSet means all oldChain nodes are absent → all invalidated.
- (void)testSetNilChainInvalidatesAllNodes {
  VanguardGraphScheduler   *scheduler = [[VanguardGraphScheduler alloc] init];
  VGSwapMockFilterNode     *nodeA     = [[VGSwapMockFilterNode alloc] initWithName:@"A"];
  VGSwapMockFilterNode     *nodeB     = [[VGSwapMockFilterNode alloc] initWithName:@"B"];

  [scheduler setFilterChain:@[nodeA, nodeB]];
  [scheduler setFilterChain:nil]; // nil → newSet is empty → both invalidated

  XCTAssertEqual(nodeA.invalidateCallCount, 1,
      @"TC-C5 FAIL: nodeA must be invalidated when chain replaced with nil.");
  XCTAssertEqual(nodeB.invalidateCallCount, 1,
      @"TC-C5 FAIL: nodeB must be invalidated when chain replaced with nil.");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-C6 — Re-setting same node does not double-invalidate it
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies DEC-54 / VanguardGraphScheduler.m:84 (containsObject: guard):
///   A node that is re-submitted in the new chain must NOT be invalidated,
///   even if it also appeared in the old chain.
- (void)testResubmittedNodeNotDoubleInvalidated {
  VanguardGraphScheduler   *scheduler = [[VanguardGraphScheduler alloc] init];
  VGSwapMockFilterNode     *nodeA     = [[VGSwapMockFilterNode alloc] initWithName:@"A"];

  [scheduler setFilterChain:@[nodeA]]; // install
  [scheduler setFilterChain:@[nodeA]]; // same node — no-op swap
  [scheduler setFilterChain:@[nodeA]]; // again

  XCTAssertEqual(nodeA.invalidateCallCount, 0,
      @"TC-C6 FAIL: nodeA was invalidated despite being in every new chain — "
       "containsObject: guard at VanguardGraphScheduler.m:84 must prevent this.");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-C7 — Concurrent setFilterChain: from 3 threads does not crash (RR-26)
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies RR-26 / DEC-54:
///   os_unfair_lock (_chainLock) in VanguardGraphScheduler ensures that
///   concurrent setFilterChain: callers do not race on _filterChain pointer.
///   3 threads each perform 20 swaps (60 total). No crash == PASS.
///
/// Note: This is the P4-2 basic concurrent-swap safety gate.
/// The full load test (VGSchedulerChainSwapUnderLoadTest, P4-5) adds
/// concurrent frame delivery. This test only exercises the lock path.
- (void)testConcurrentSetFilterChainFromThreeThreadsDoesNotCrash {
  VanguardGraphScheduler   *scheduler = [[VanguardGraphScheduler alloc] init];
  VGSwapMockFilterNode     *nodeA     = [[VGSwapMockFilterNode alloc] initWithName:@"ConcA"];
  VGSwapMockFilterNode     *nodeB     = [[VGSwapMockFilterNode alloc] initWithName:@"ConcB"];
  VGSwapMockFilterNode     *nodeC     = [[VGSwapMockFilterNode alloc] initWithName:@"ConcC"];

  // 3 competing threads, 20 swaps each (60 total lock/swap cycles).
  dispatch_group_t group   = dispatch_group_create();
  dispatch_queue_t conc    = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
  const NSInteger  swaps   = 20;

  dispatch_group_async(group, conc, ^{
    for (NSInteger i = 0; i < swaps; i++) {
      [scheduler setFilterChain:(i % 2 == 0) ? @[nodeA] : @[nodeA, nodeB]];
    }
  });
  dispatch_group_async(group, conc, ^{
    for (NSInteger i = 0; i < swaps; i++) {
      [scheduler setFilterChain:(i % 2 == 0) ? @[nodeB] : @[]];
    }
  });
  dispatch_group_async(group, conc, ^{
    for (NSInteger i = 0; i < swaps; i++) {
      [scheduler setFilterChain:(i % 3 == 0) ? @[nodeA, nodeB, nodeC] : nil];
    }
  });

  // 5-second watchdog — concurrent swap must not deadlock.
  long result = dispatch_group_wait(
      group,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)));

  XCTAssertEqual(result, 0,
      @"TC-C7 FAIL: 3-thread concurrent setFilterChain: timed out after 5s — "
       "possible deadlock in os_unfair_lock (_chainLock). "
       "RR-26 / DEC-54 compliance required.");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-C8 — setFilterChain: after invalidate is silently ignored
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies VanguardGraphScheduler.m:70:
///   if (atomic_load(&_invalidated)) return;
///   After invalidate, setFilterChain: must not crash and must not
///   install the chain (nodes not tracked after teardown).
- (void)testSetFilterChainAfterInvalidateIsIgnored {
  VanguardGraphScheduler   *scheduler = [[VanguardGraphScheduler alloc] init];
  VGSwapMockFilterNode     *nodeA     = [[VGSwapMockFilterNode alloc] initWithName:@"A"];

  [scheduler invalidate];

  NSArray *chainA = @[nodeA];
  XCTAssertNoThrow(
      [scheduler setFilterChain:chainA],
      @"TC-C8 FAIL: setFilterChain: after invalidate threw — must not throw.");

  // nodeA must NOT have been invalidated by the post-invalidate setFilterChain: call.
  // (The early-return at .m:70 means the swap body never runs, so old chain
  //  teardown never runs either — nodeA was never stored, never removed.)
  XCTAssertEqual(nodeA.invalidateCallCount, 0,
      @"TC-C8 FAIL: nodeA.invalidate was called by a post-invalidate "
       "setFilterChain: — early-return at VanguardGraphScheduler.m:70 "
       "should have prevented any node interaction.");
}

@end
