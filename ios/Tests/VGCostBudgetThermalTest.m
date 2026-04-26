// VGCostBudgetThermalTest.m
// vanguard_media_engine — Phase 4, P4-9
//
// Gate test: VGCostBudgetThermalTest (plan:365 — P4-9 regression gate).
//
// Purpose:
//   Validates VanguardGraphScheduler.applyThermalState: with 3 mock nodes
//   matching the current production cost profile:
//     LUT         estimatedGPUCostMs = 2.0  (cheap)
//     Beauty      estimatedGPUCostMs = 3.0  (medium)
//     Segmentation estimatedGPUCostMs = 5.0 (expensive)
//
//   Proves Phase 3 behavioral equivalence with the new scalar cost-budget
//   algorithm (replaces binary isExpensive policy, DEC-55 required action).
//
// Tests:
//   TC-T1 — Nominal:  all nodes enabled
//   TC-T2 — Fair:     all nodes enabled
//   TC-T3 — Serious:  greedy disables Segmentation (5ms); LUT+Beauty (5ms) ≤ 5ms budget
//   TC-T4 — Critical: all nodes disabled
//   TC-T5 — Recovery: Critical → Nominal re-enables all nodes
//
// Contract anchors:
//   plan:365 (VGCostBudgetThermalTest definition)
//   plan:209 (algorithm: enable all, compute total, greedy disable)
//   plan:213 (Safety: budget calibrated for Phase 3 behavioral equivalence)
//   DEC-55  (decision_log.md:804 — isExpensive replaced by cost-budget in P4-9)
//   RR-33   (known_risks.md:755 — classification drift; CLOSED by this test)
//
// Simulator-safe: no GPU work, no Metal device required.

#import <XCTest/XCTest.h>
#include <stdatomic.h>
#include <float.h>

// SUT
#import "VanguardGraphScheduler.h"

// UMF protocols
#import <UMF/VGMetalFilterNode.h>
#import <UMF/VGMediaNode.h>
#import <UMF/VGFrameEnvelope.h>

// ─── VGThermalMockNode ────────────────────────────────────────────────────────
//
// VGMetalFilterNode conformer for thermal policy testing.
//
// Correctly implements:
//   - BOOL enabled with _Atomic(BOOL) tracking (assertable)
//   - float estimatedGPUCostMs (set at init)
//   - BOOL isExpensive (deprecated; returns NO always — must NOT be read by P4-9)
//   - All other VGMediaNode / VGMetalFilterNode @required methods (no-ops)

@interface VGThermalMockNode : NSObject <VGMetalFilterNode>
/// Descriptive label for assertion messages.
@property(nonatomic, readonly, copy) NSString *label;
/// Current enabled state (readable from test thread).
@property(nonatomic, readonly) BOOL isEnabled;
/// Initialise with a label and a cost.
- (instancetype)initWithLabel:(NSString *)label costMs:(float)costMs;
@end

@implementation VGThermalMockNode {
  NSString *_label;
  float     _costMs;
  _Atomic(BOOL) _enabled;
}

- (instancetype)initWithLabel:(NSString *)label costMs:(float)costMs {
  self = [super init];
  if (!self) return nil;
  _label  = [label copy];
  _costMs = costMs;
  atomic_store(&_enabled, YES); // default enabled (plan:209 step 1: enable all)
  return self;
}

// ─── VGMediaNode ─────────────────────────────────────────────────────────────

- (NSString *)nodeId   { return _label; }
- (NSString *)nodeType { return @"VGThermalMockNode"; }
- (VGNodeRole)nodeRole { return VGNodeRoleFilter; }
- (void)prepareWithCompletion:(void (^)(NSError *_Nullable))c { if (c) c(nil); }
- (void)invalidate     { /* no resources */ }

// ─── VGMetalFilterNode ───────────────────────────────────────────────────────

- (NSString *)filterName              { return _label; }
- (BOOL)enabled                       { return atomic_load(&_enabled); }
- (void)setEnabled:(BOOL)e            { atomic_store(&_enabled, e); }
- (BOOL)isExpensive                   { return NO; } // deprecated; must NOT be read by P4-9
- (float)estimatedGPUCostMs           { return _costMs; }

- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)env
                            device:(id<MTLDevice>)__unused dev {
  return env; // passthrough — not called in thermal tests
}

// ─── Test accessor ────────────────────────────────────────────────────────────

- (BOOL)isEnabled { return atomic_load(&_enabled); }

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGCostBudgetThermalTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCostBudgetThermalTest : XCTestCase
/// Scheduler under test — fresh per test.
@property(nonatomic) VanguardGraphScheduler *scheduler;
/// LUT mock node  — estimatedGPUCostMs = 2.0ms
@property(nonatomic) VGThermalMockNode *lut;
/// Beauty mock node — estimatedGPUCostMs = 3.0ms
@property(nonatomic) VGThermalMockNode *beauty;
/// Segmentation mock node — estimatedGPUCostMs = 5.0ms (most expensive)
@property(nonatomic) VGThermalMockNode *segmentation;
@end

@implementation VGCostBudgetThermalTest

- (void)setUp {
  [super setUp];
  self.scheduler    = [[VanguardGraphScheduler alloc] init];
  self.lut          = [[VGThermalMockNode alloc] initWithLabel:@"LUT"           costMs:2.0f];
  self.beauty       = [[VGThermalMockNode alloc] initWithLabel:@"Beauty"        costMs:3.0f];
  self.segmentation = [[VGThermalMockNode alloc] initWithLabel:@"Segmentation"  costMs:5.0f];

  // Install the 3-node chain (order: insertion order, not cost order).
  [self.scheduler setFilterChain:@[ self.lut, self.beauty, self.segmentation ]];
}

- (void)tearDown {
  [self.scheduler invalidate];
  self.scheduler    = nil;
  self.lut          = nil;
  self.beauty       = nil;
  self.segmentation = nil;
  [super tearDown];
}

// ─── TC-T1: Nominal — all nodes enabled ──────────────────────────────────────
//
// Budget = FLT_MAX. Total cost = 10ms ≤ FLT_MAX → no greedy disable.
// All 3 nodes must be enabled after applyThermalState:Nominal.

- (void)testNominalEnablesAllNodes {
  [self.scheduler applyThermalState:NSProcessInfoThermalStateNominal];

  XCTAssertTrue(self.lut.isEnabled,
      @"[P4-9 TC-T1] LUT must be enabled at Nominal thermal state.");
  XCTAssertTrue(self.beauty.isEnabled,
      @"[P4-9 TC-T1] Beauty must be enabled at Nominal thermal state.");
  XCTAssertTrue(self.segmentation.isEnabled,
      @"[P4-9 TC-T1] Segmentation must be enabled at Nominal thermal state.");
}

// ─── TC-T2: Fair — all nodes enabled ─────────────────────────────────────────
//
// Budget = FLT_MAX (same tier as Nominal). All 3 nodes must be enabled.

- (void)testFairEnablesAllNodes {
  [self.scheduler applyThermalState:NSProcessInfoThermalStateFair];

  XCTAssertTrue(self.lut.isEnabled,
      @"[P4-9 TC-T2] LUT must be enabled at Fair thermal state.");
  XCTAssertTrue(self.beauty.isEnabled,
      @"[P4-9 TC-T2] Beauty must be enabled at Fair thermal state.");
  XCTAssertTrue(self.segmentation.isEnabled,
      @"[P4-9 TC-T2] Segmentation must be enabled at Fair thermal state.");
}

// ─── TC-T3: Serious — only Segmentation disabled ─────────────────────────────
//
// Budget = 5.0ms. Total cost = 2+3+5 = 10ms > 5ms.
// Greedy disable (most expensive first):
//   Seg(5ms) disabled → remaining total = 5ms ≤ 5ms → stop.
// LUT(2ms) and Beauty(3ms) remain enabled.
//
// This is the Phase 3 behavioral equivalence proof (plan:213):
//   P3-4 isExpensive policy: Seg disabled, LUT+Beauty enabled.
//   P4-9 cost-budget policy: same result via scalar algorithm.

- (void)testSeriousDisablesOnlySegmentation {
  [self.scheduler applyThermalState:NSProcessInfoThermalStateSerious];

  XCTAssertTrue(self.lut.isEnabled,
      @"[P4-9 TC-T3] LUT (2ms) must remain enabled at Serious "
      @"(budget=5ms, total after disable=5ms ≤ budget).");
  XCTAssertTrue(self.beauty.isEnabled,
      @"[P4-9 TC-T3] Beauty (3ms) must remain enabled at Serious "
      @"(budget=5ms, LUT+Beauty=5ms ≤ budget).");
  XCTAssertFalse(self.segmentation.isEnabled,
      @"[P4-9 TC-T3] Segmentation (5ms) must be disabled at Serious "
      @"(most expensive — greedy disable step 1). "
      @"Phase 3 behavioral equivalence required (plan:213, DEC-55).");
}

// ─── TC-T4: Critical — all nodes disabled ────────────────────────────────────
//
// Budget = 0.0ms. Total cost = 10ms > 0ms.
// Greedy disable until total ≤ 0:
//   Seg(5), Beauty(3), LUT(2) all disabled → total = 0ms ≤ 0ms.
// All 3 nodes must be disabled.

- (void)testCriticalDisablesAllNodes {
  [self.scheduler applyThermalState:NSProcessInfoThermalStateCritical];

  XCTAssertFalse(self.lut.isEnabled,
      @"[P4-9 TC-T4] LUT must be disabled at Critical (budget=0ms).");
  XCTAssertFalse(self.beauty.isEnabled,
      @"[P4-9 TC-T4] Beauty must be disabled at Critical (budget=0ms).");
  XCTAssertFalse(self.segmentation.isEnabled,
      @"[P4-9 TC-T4] Segmentation must be disabled at Critical (budget=0ms).");
}

// ─── TC-T5: Recovery — Critical → Nominal re-enables all nodes ───────────────
//
// After Critical (all disabled), applying Nominal must re-enable all nodes.
// Validates the "enable all" step (plan:209 step 1) runs unconditionally
// at the start of every applyThermalState: call.

- (void)testRecoveryFromCriticalToNominalReenablesAllNodes {
  // First: Critical → all disabled.
  [self.scheduler applyThermalState:NSProcessInfoThermalStateCritical];

  XCTAssertFalse(self.lut.isEnabled,
      @"[P4-9 TC-T5 precondition] LUT must be disabled after Critical.");
  XCTAssertFalse(self.beauty.isEnabled,
      @"[P4-9 TC-T5 precondition] Beauty must be disabled after Critical.");
  XCTAssertFalse(self.segmentation.isEnabled,
      @"[P4-9 TC-T5 precondition] Segmentation must be disabled after Critical.");

  // Recovery: Nominal → all re-enabled.
  [self.scheduler applyThermalState:NSProcessInfoThermalStateNominal];

  XCTAssertTrue(self.lut.isEnabled,
      @"[P4-9 TC-T5] LUT must be re-enabled after recovery to Nominal.");
  XCTAssertTrue(self.beauty.isEnabled,
      @"[P4-9 TC-T5] Beauty must be re-enabled after recovery to Nominal.");
  XCTAssertTrue(self.segmentation.isEnabled,
      @"[P4-9 TC-T5] Segmentation must be re-enabled after recovery to Nominal.");
}

@end
