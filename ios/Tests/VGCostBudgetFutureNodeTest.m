// VGCostBudgetFutureNodeTest.m
// vanguard_media_engine — Phase 4, P4-9
//
// Gate test: VGCostBudgetFutureNodeTest (plan:366 — P4-9 regression gate).
//
// Purpose:
//   Validates VanguardGraphScheduler.applyThermalState: with arbitrary
//   future-node cost profiles. Proves RR-33 is fixed for nodes that supply
//   any scalar estimatedGPUCostMs — not just the current 3-node set.
//
//   This test is designed to be resilient to any realistic future node cost:
//   the greedy algorithm is node-count and cost-value agnostic.
//
// Tests:
//   TC-F1 — Greedy order: [1,2,4,6ms], Serious(5ms) → 6 off, 4 off; 1+2 on
//   TC-F2 — Exact budget match: total exactly 5ms under Serious → all on
//   TC-F3 — Critical disables all future nodes (any cost profile)
//   TC-F4 — Single expensive node (10ms) disabled at Serious (5ms budget)
//
// Contract anchors:
//   plan:366 (VGCostBudgetFutureNodeTest definition)
//   plan:209 (greedy-disable algorithm)
//   RR-33   (known_risks.md:755 — CLOSED: cost model not dependent on flag)
//   DEC-55  (decision_log.md:804 — estimatedGPUCostMs replaces isExpensive)
//
// Simulator-safe: no GPU work, no Metal device.

#import <XCTest/XCTest.h>
#include <stdatomic.h>

// SUT
#import "VanguardGraphScheduler.h"

// UMF protocols
#import <UMF/VGMetalFilterNode.h>
#import <UMF/VGMediaNode.h>
#import <UMF/VGFrameEnvelope.h>

// ─── VGFutureMockNode ─────────────────────────────────────────────────────────
//
// Generic VGMetalFilterNode conformer for future-node scenarios.
// Identical structure to VGThermalMockNode but in its own translation unit
// to avoid duplicate-symbol errors when both test files run in the same binary.

@interface VGFutureMockNode : NSObject <VGMetalFilterNode>
@property(nonatomic, readonly, copy) NSString *label;
@property(nonatomic, readonly) BOOL isEnabled;
- (instancetype)initWithLabel:(NSString *)label costMs:(float)costMs;
@end

@implementation VGFutureMockNode {
  NSString     *_label;
  float         _costMs;
  _Atomic(BOOL) _enabled;
}

- (instancetype)initWithLabel:(NSString *)label costMs:(float)costMs {
  self = [super init];
  if (!self) return nil;
  _label  = [label copy];
  _costMs = costMs;
  atomic_store(&_enabled, YES);
  return self;
}

// VGMediaNode
- (NSString *)nodeId   { return _label; }
- (NSString *)nodeType { return @"VGFutureMockNode"; }
- (VGNodeRole)nodeRole { return VGNodeRoleFilter; }
- (void)prepareWithCompletion:(void (^)(NSError *_Nullable))c { if (c) c(nil); }
- (void)invalidate     {}

// VGMetalFilterNode
- (NSString *)filterName      { return _label; }
- (BOOL)enabled               { return atomic_load(&_enabled); }
- (void)setEnabled:(BOOL)e    { atomic_store(&_enabled, e); }
- (BOOL)isExpensive           { return NO; } // deprecated; must NOT influence P4-9
- (float)estimatedGPUCostMs   { return _costMs; }

- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)env
                            device:(id<MTLDevice>)__unused dev {
  return env;
}

- (BOOL)isEnabled { return atomic_load(&_enabled); }

@end

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Constructs and installs a chain from costs array and returns the node array.
static NSArray<VGFutureMockNode *> *buildChain(VanguardGraphScheduler *sched,
                                                NSArray<NSNumber *> *costs) {
  NSMutableArray *nodes = [NSMutableArray arrayWithCapacity:costs.count];
  for (NSUInteger i = 0; i < costs.count; i++) {
    float cost = costs[i].floatValue;
    NSString *label = [NSString stringWithFormat:@"FutureNode-%lu(%.0fms)",
                       (unsigned long)i, cost];
    VGFutureMockNode *node = [[VGFutureMockNode alloc] initWithLabel:label
                                                              costMs:cost];
    [nodes addObject:node];
  }
  [sched setFilterChain:nodes];
  return [nodes copy];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGCostBudgetFutureNodeTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCostBudgetFutureNodeTest : XCTestCase
@property(nonatomic) VanguardGraphScheduler *scheduler;
@end

@implementation VGCostBudgetFutureNodeTest

- (void)setUp {
  [super setUp];
  self.scheduler = [[VanguardGraphScheduler alloc] init];
}

- (void)tearDown {
  [self.scheduler invalidate];
  self.scheduler = nil;
  [super tearDown];
}

// ─── TC-F1: Greedy disable — most expensive first ────────────────────────────
//
// 4 nodes with costs: 1ms, 2ms, 4ms, 6ms (total = 13ms).
// Serious budget = 5ms.
//
// Greedy disable sequence (most expensive first):
//   1. Disable 6ms → total = 7ms > 5ms → continue
//   2. Disable 4ms → total = 3ms ≤ 5ms → stop
//
// Expected final state:
//   1ms node: ENABLED  (total after disables = 3ms ≤ 5ms)
//   2ms node: ENABLED
//   4ms node: DISABLED
//   6ms node: DISABLED
//
// Proves the greedy algorithm disables in descending cost order and stops
// as soon as totalCost ≤ budget (plan:209, step 5 algorithm).

- (void)testGreedyDisablesMostExpensiveFirst {
  NSArray<VGFutureMockNode *> *nodes = buildChain(
      self.scheduler, @[ @1.0f, @2.0f, @4.0f, @6.0f ]);

  VGFutureMockNode *node1ms = nodes[0];
  VGFutureMockNode *node2ms = nodes[1];
  VGFutureMockNode *node4ms = nodes[2];
  VGFutureMockNode *node6ms = nodes[3];

  [self.scheduler applyThermalState:NSProcessInfoThermalStateSerious];

  XCTAssertTrue(node1ms.isEnabled,
      @"[P4-9 TC-F1] 1ms node must remain enabled "
      @"(total after greedy disable = 3ms ≤ 5ms budget).");
  XCTAssertTrue(node2ms.isEnabled,
      @"[P4-9 TC-F1] 2ms node must remain enabled "
      @"(total after greedy disable = 3ms ≤ 5ms budget).");
  XCTAssertFalse(node4ms.isEnabled,
      @"[P4-9 TC-F1] 4ms node must be disabled "
      @"(greedy step 2: total drops from 7ms to 3ms after disabling 4ms).");
  XCTAssertFalse(node6ms.isEnabled,
      @"[P4-9 TC-F1] 6ms node must be disabled "
      @"(greedy step 1: most expensive, disabled first).");
}

// ─── TC-F2: Exact budget match disables nothing ───────────────────────────────
//
// 2 nodes with costs: 2ms, 3ms (total = 5ms = budget exactly).
// Serious budget = 5ms.
//
// Condition: totalCost (5ms) ≤ budget (5ms) → greedy loop never entered.
// All nodes must remain enabled.
//
// Edge-case boundary: total == budget must NOT trigger any disable.

- (void)testExactBudgetMatchDisablesNothing {
  NSArray<VGFutureMockNode *> *nodes = buildChain(
      self.scheduler, @[ @2.0f, @3.0f ]);

  VGFutureMockNode *node2ms = nodes[0];
  VGFutureMockNode *node3ms = nodes[1];

  [self.scheduler applyThermalState:NSProcessInfoThermalStateSerious];

  XCTAssertTrue(node2ms.isEnabled,
      @"[P4-9 TC-F2] 2ms node must be enabled when total (5ms) == budget (5ms).");
  XCTAssertTrue(node3ms.isEnabled,
      @"[P4-9 TC-F2] 3ms node must be enabled when total (5ms) == budget (5ms). "
      @"Exact budget match must NOT trigger greedy disable (plan:209: if total > budget).");
}

// ─── TC-F3: Critical disables all future nodes ────────────────────────────────
//
// 4 nodes with costs: 1ms, 2ms, 4ms, 6ms.
// Critical budget = 0ms. All must be disabled regardless of individual cost.
//
// Proves algorithm terminates correctly at budget=0 for any number of nodes.

- (void)testCriticalDisablesAllFutureNodes {
  NSArray<VGFutureMockNode *> *nodes = buildChain(
      self.scheduler, @[ @1.0f, @2.0f, @4.0f, @6.0f ]);

  [self.scheduler applyThermalState:NSProcessInfoThermalStateCritical];

  for (NSUInteger i = 0; i < nodes.count; i++) {
    XCTAssertFalse(nodes[i].isEnabled,
        @"[P4-9 TC-F3] Node %lu (%.0fms) must be disabled at Critical "
        @"(budget=0ms — all nodes off regardless of cost).",
        (unsigned long)i, nodes[i].estimatedGPUCostMs);
  }
}

// ─── TC-F4: Single expensive node (10ms) disabled at Serious ─────────────────
//
// 1 node with cost 10ms. Serious budget = 5ms.
// Greedy: total (10ms) > budget (5ms) → disable 10ms node → total = 0ms ≤ 5ms.
//
// Proves the algorithm handles the case where a single future node's cost
// exceeds the Serious budget and it is correctly disabled.
// This is the primary RR-33 future-safety proof.

- (void)testSingleExpensiveNodeDisabledAtSerious {
  NSArray<VGFutureMockNode *> *nodes = buildChain(
      self.scheduler, @[ @10.0f ]);

  VGFutureMockNode *node10ms = nodes[0];

  [self.scheduler applyThermalState:NSProcessInfoThermalStateSerious];

  XCTAssertFalse(node10ms.isEnabled,
      @"[P4-9 TC-F4] Single 10ms node must be disabled at Serious (5ms budget). "
      @"A future expensive node cannot escape thermal throttling by omitting "
      @"isExpensive — estimatedGPUCostMs is authoritative (RR-33 closure).");
}

@end
