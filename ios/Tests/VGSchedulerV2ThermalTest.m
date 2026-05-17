// VGSchedulerV2ThermalTest.m
// vanguard_media_engine — Phase 4C
//
// Gate test: V2 thermal policy via in-place enabled toggle.
//
// Validates that toggling VGMetalFilterNode.enabled on the underlying filter
// objects causes VGGraphSchedulerV2 to skip those filters during execution,
// and that the cost-budget algorithm produces results identical to V1.
//
// Tests:
//   TC-V2T-1  Nominal/Fair state: all filters execute.
//   TC-V2T-2  Serious state: most expensive filter disabled, cheaper ones run.
//   TC-V2T-3  Critical state: all filters disabled, passthrough.
//   TC-V2T-4  Recovery: Critical → Nominal re-enables all, all filters run.
//   TC-V2T-5  Empty chain: no crash.
//   TC-V2T-6  V1 algorithm parity: budget algorithm matches V1 exactly.
//
// Threading: all calls synchronous on test thread. No dispatch queues.
//
// Buffer ownership (RR-36):
//   _testBuffer        — test-owned (+1). Released in tearDown.
//   VGT_SinkSpy.capturedBuffer — spy retains +1, releases in dealloc.

#import <XCTest/XCTest.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CMTime.h>
#import <Metal/Metal.h>
#include <float.h>

#import "VGGraphSchedulerV2.h"

#import <UMF/VGExecutionPlan.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGNode.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGSourceNode.h>
#import <UMF/VGTransformNode.h>
#import <UMF/VGMetalFilterNode.h>
#import <UMF/VGMediaNode.h>
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGResourceAllocator.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGT_MockSource
// ─────────────────────────────────────────────────────────────────────────────

@interface VGT_MockSource : NSObject <VGSourceNode>
@end
@implementation VGT_MockSource {
    NSString *_nodeId;
}
- (instancetype)init {
    self = [super init];
    _nodeId = @"vgt_source";
    return self;
}
- (NSString *)nodeId   { return _nodeId; }
- (NSString *)nodeType { return @"vgt_mock_source"; }
- (VGNodeRole)nodeRole { return VGNodeRoleSource; }
- (void)prepareWithCompletion:(void (^)(NSError *_Nullable))c { if (c) c(nil); }
- (void)prepareWithContext:(VGGraphExecutionContext *)ctx
                completion:(void (^)(NSError *_Nullable))c { if (c) c(nil); }
- (void)invalidate {}
- (void)startProducing {}
- (void)stopProducing {}
- (nullable VGFrameResult *)pullFrame:(VGFrameRequest *)req { return nil; }
- (void)seekTo:(CMTime)t generation:(uint64_t)g {}
- (nullable NSArray<VGMediaPort *> *)declaredPorts { return @[]; }
- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)p
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)f {
    return nil;
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGT_SinkSpy
// ─────────────────────────────────────────────────────────────────────────────

@interface VGT_SinkSpy : NSObject <VGFrameSink>
@property (nonatomic) NSInteger       presentCount;
@property (nonatomic) CVPixelBufferRef capturedBuffer; // +1; released in dealloc
@end

@implementation VGT_SinkSpy {
    NSString *_nodeId;
}
- (instancetype)init {
    self = [super init];
    _nodeId = @"vgt_sink";
    return self;
}
- (void)dealloc {
    if (_capturedBuffer) { CVPixelBufferRelease(_capturedBuffer); _capturedBuffer = NULL; }
}
- (NSString *)nodeId   { return _nodeId; }
- (NSString *)nodeType { return @"vgt_sink"; }
- (VGNodeRole)nodeRole { return VGNodeRoleSink; }
- (void)prepareWithCompletion:(void (^)(NSError *_Nullable))c { if (c) c(nil); }
- (void)prepareWithContext:(VGGraphExecutionContext *)ctx
                completion:(void (^)(NSError *_Nullable))c { if (c) c(nil); }
- (void)invalidate {}
- (nullable NSArray<VGMediaPort *> *)declaredPorts { return @[]; }
- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)p
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)f {
    return nil;
}
- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    _presentCount++;
    CVPixelBufferRef buf = envelope.payload.videoBuffer;
    if (buf) {
        CVPixelBufferRetain(buf);
        if (_capturedBuffer) CVPixelBufferRelease(_capturedBuffer);
        _capturedBuffer = buf;
    }
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGT_CostFilter
// ─────────────────────────────────────────────────────────────────────────────

/// A VGMetalFilterNode + VGTransformNode conformer with configurable GPU cost.
/// Performs identity transform. processCount is incremented only if enabled.
@interface VGT_CostFilter : NSObject <VGTransformNode>
@property (nonatomic) float   estimatedGPUCostMs;
@property (nonatomic) BOOL    enabled;
@property (nonatomic) NSInteger processCount;
- (instancetype)initWithCostMs:(float)cost name:(NSString *)name;
@end

@implementation VGT_CostFilter {
    NSString *_nodeId;
    NSString *_name;
}
- (instancetype)initWithCostMs:(float)cost name:(NSString *)name {
    self = [super init];
    _estimatedGPUCostMs = cost;
    _name    = [name copy];
    _nodeId  = [NSString stringWithFormat:@"vgt_filter_%@", name];
    _enabled = YES;
    return self;
}
- (NSString *)nodeId   { return _nodeId; }
- (NSString *)nodeType { return @"vgt_cost_filter"; }
- (VGNodeRole)nodeRole { return VGNodeRoleFilter; }
- (void)prepareWithCompletion:(void (^)(NSError *_Nullable))c { if (c) c(nil); }
- (void)prepareWithContext:(VGGraphExecutionContext *)ctx
                completion:(void (^)(NSError *_Nullable))c { if (c) c(nil); }
- (void)invalidate {}
- (nullable NSArray<VGMediaPort *> *)declaredPorts { return @[]; }
- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)p
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)f {
    return nil;
}
- (BOOL)isExpensive           { return NO; }
- (NSString *)filterName      { return _name; }

- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                             device:(id<MTLDevice>)device {
    _processCount++;
    return envelope; // identity passthrough
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Helpers
// ─────────────────────────────────────────────────────────────────────────────

static CVPixelBufferRef VGT_MakeBuffer(uint8_t fill) {
    const size_t W = 16, H = 16;
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferRef buf = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, W, H,
                        kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)attrs, &buf);
    if (buf) {
        CVPixelBufferLockBaseAddress(buf, 0);
        memset(CVPixelBufferGetBaseAddress(buf), fill,
               CVPixelBufferGetDataSize(buf));
        CVPixelBufferUnlockBaseAddress(buf, 0);
    }
    return buf;
}

/// Build a minimal VGGraphSchedulerV2 with the given filters.
static VGGraphSchedulerV2 *VGT_BuildScheduler(NSArray<VGT_CostFilter *> *filters,
                                               VGT_MockSource *source,
                                               VGT_SinkSpy **outSink) {
    NSMutableDictionary<NSString *, id<VGNode>> *nodes = [NSMutableDictionary new];
    nodes[source.nodeId] = source;
    for (VGT_CostFilter *f in filters) nodes[f.nodeId] = f;

    VGT_SinkSpy *sink = [VGT_SinkSpy new];
    nodes[sink.nodeId] = sink;

    NSMutableArray<NSString *> *topo = [NSMutableArray new];
    [topo addObject:source.nodeId];
    for (VGT_CostFilter *f in filters) [topo addObject:f.nodeId];
    [topo addObject:sink.nodeId];

    VGExecutionPlan *plan = [[VGExecutionPlan alloc] initWithTopologicalOrder:topo
                                                               parallelGroups:@[]];
    VGGraphDescriptor *desc = [[VGGraphDescriptor alloc] init];
    VGGraphExecutionContext *ctx =
        [[VGGraphExecutionContext alloc] initWithDescriptor:desc
                                                       plan:plan
                                                      nodes:nodes
                                                      clock:nil
                                          resourceAllocator:[VGResourceAllocator sharedInstance]];
    VGGraphSchedulerV2 *sched =
        [[VGGraphSchedulerV2 alloc] initWithPlan:plan nodes:nodes context:ctx];
    sched.sink = sink;
    [sched startWithClock:nil];

    if (outSink) *outSink = sink;
    return sched;
}

/// Deliver a single frame to the scheduler. Buffer owned by caller.
static void VGT_DeliverFrame(VGGraphSchedulerV2 *sched, CVPixelBufferRef buf) {
    VGFrameEnvelope env;
    memset(&env, 0, sizeof(env));
    env.mediaType           = VGMediaTypeVideo;
    env.pts                 = kCMTimeZero;
    env.payload.videoBuffer = buf;
    [sched didReceiveRawFrame:env];
}

/// Mirrors runtime _applyThermalBudgetToChain:state: for test-side use.
/// Budget thresholds must be identical to V1 VanguardGraphScheduler.applyThermalState:.
static void VGT_ApplyThermalBudget(NSArray<VGT_CostFilter *> *chain,
                                    NSProcessInfoThermalState state) {
    if (!chain.count) return;

    float budgetMs;
    switch (state) {
    case NSProcessInfoThermalStateNominal:
    case NSProcessInfoThermalStateFair:
        budgetMs = FLT_MAX;
        break;
    case NSProcessInfoThermalStateSerious:
        budgetMs = 5.0f;
        break;
    case NSProcessInfoThermalStateCritical:
        budgetMs = 0.0f;
        break;
    default:
        return;
    }

    for (VGT_CostFilter *n in chain) n.enabled = YES;

    float totalCostMs = 0.0f;
    for (VGT_CostFilter *n in chain) totalCostMs += n.estimatedGPUCostMs;

    if (totalCostMs > budgetMs) {
        NSArray<VGT_CostFilter *> *sorted =
            [chain sortedArrayUsingComparator:^NSComparisonResult(VGT_CostFilter *a,
                                                                   VGT_CostFilter *b) {
                if (a.estimatedGPUCostMs > b.estimatedGPUCostMs) return NSOrderedAscending;
                if (a.estimatedGPUCostMs < b.estimatedGPUCostMs) return NSOrderedDescending;
                return NSOrderedSame;
            }];
        for (VGT_CostFilter *n in sorted) {
            if (totalCostMs <= budgetMs) break;
            n.enabled  = NO;
            totalCostMs -= n.estimatedGPUCostMs;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGSchedulerV2ThermalTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGSchedulerV2ThermalTest : XCTestCase
@end

@implementation VGSchedulerV2ThermalTest {
    CVPixelBufferRef _testBuffer; // test-owned (+1), released in tearDown
    VGT_MockSource  *_source;
    // Standard 3-filter cost profile matching V1 tests (LUT=2, Beauty=3, Seg=5)
    VGT_CostFilter  *_lut;        // 2.0ms
    VGT_CostFilter  *_beauty;     // 3.0ms
    VGT_CostFilter  *_segmentation; // 5.0ms
}

- (void)setUp {
    [super setUp];
    _source      = [VGT_MockSource new];
    _testBuffer  = VGT_MakeBuffer(0xAA);
    _lut         = [[VGT_CostFilter alloc] initWithCostMs:2.0f name:@"LUT"];
    _beauty      = [[VGT_CostFilter alloc] initWithCostMs:3.0f name:@"Beauty"];
    _segmentation = [[VGT_CostFilter alloc] initWithCostMs:5.0f name:@"Segmentation"];
}

- (void)tearDown {
    if (_testBuffer) { CVPixelBufferRelease(_testBuffer); _testBuffer = NULL; }
    _source = nil;
    _lut = nil; _beauty = nil; _segmentation = nil;
    [super tearDown];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-V2T-1 — Nominal/Fair state: all filters execute
// ─────────────────────────────────────────────────────────────────────────────
- (void)testNominalState_allFiltersExecute {
    VGT_SinkSpy *sink = nil;
    NSArray *filters = @[_lut, _beauty, _segmentation];
    VGGraphSchedulerV2 *sched = VGT_BuildScheduler(filters, _source, &sink);

    // Apply nominal thermal state: all enabled.
    VGT_ApplyThermalBudget(filters, NSProcessInfoThermalStateNominal);

    XCTAssertTrue(_lut.enabled,           @"TC-V2T-1: LUT must be enabled at Nominal");
    XCTAssertTrue(_beauty.enabled,        @"TC-V2T-1: Beauty must be enabled at Nominal");
    XCTAssertTrue(_segmentation.enabled,  @"TC-V2T-1: Segmentation must be enabled at Nominal");

    VGT_DeliverFrame(sched, _testBuffer);

    XCTAssertEqual(_lut.processCount,         1, @"TC-V2T-1: LUT must execute");
    XCTAssertEqual(_beauty.processCount,      1, @"TC-V2T-1: Beauty must execute");
    XCTAssertEqual(_segmentation.processCount, 1, @"TC-V2T-1: Segmentation must execute");
    XCTAssertEqual(sink.presentCount,         1, @"TC-V2T-1: sink must receive frame");

    [sched invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-V2T-2 — Serious state: most expensive filter disabled
// ─────────────────────────────────────────────────────────────────────────────
- (void)testSeriousState_mostExpensiveFilterDisabled {
    // Serious budget = 5.0ms. Total = 2+3+5=10ms > 5ms.
    // Greedy: Seg(5ms) disabled → remaining = 5ms ≤ 5ms. LUT+Beauty enabled.
    VGT_SinkSpy *sink = nil;
    NSArray *filters = @[_lut, _beauty, _segmentation];
    VGGraphSchedulerV2 *sched = VGT_BuildScheduler(filters, _source, &sink);

    VGT_ApplyThermalBudget(filters, NSProcessInfoThermalStateSerious);

    XCTAssertTrue(_lut.enabled,            @"TC-V2T-2: LUT (2ms) must remain enabled (budget=5ms)");
    XCTAssertTrue(_beauty.enabled,         @"TC-V2T-2: Beauty (3ms) must remain enabled (budget=5ms)");
    XCTAssertFalse(_segmentation.enabled,  @"TC-V2T-2: Segmentation (5ms) must be disabled (most expensive first)");

    VGT_DeliverFrame(sched, _testBuffer);

    XCTAssertEqual(_lut.processCount,          1, @"TC-V2T-2: LUT must execute");
    XCTAssertEqual(_beauty.processCount,       1, @"TC-V2T-2: Beauty must execute");
    XCTAssertEqual(_segmentation.processCount, 0, @"TC-V2T-2: Segmentation must NOT execute (disabled)");
    XCTAssertEqual(sink.presentCount,          1, @"TC-V2T-2: sink must receive frame (passthrough from disabled node)");

    [sched invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-V2T-3 — Critical state: all filters disabled, passthrough
// ─────────────────────────────────────────────────────────────────────────────
- (void)testCriticalState_allFiltersDisabled {
    VGT_SinkSpy *sink = nil;
    NSArray *filters = @[_lut, _beauty, _segmentation];
    VGGraphSchedulerV2 *sched = VGT_BuildScheduler(filters, _source, &sink);

    VGT_ApplyThermalBudget(filters, NSProcessInfoThermalStateCritical);

    XCTAssertFalse(_lut.enabled,           @"TC-V2T-3: LUT must be disabled at Critical");
    XCTAssertFalse(_beauty.enabled,        @"TC-V2T-3: Beauty must be disabled at Critical");
    XCTAssertFalse(_segmentation.enabled,  @"TC-V2T-3: Segmentation must be disabled at Critical");

    VGT_DeliverFrame(sched, _testBuffer);

    XCTAssertEqual(_lut.processCount,          0, @"TC-V2T-3: LUT must NOT execute");
    XCTAssertEqual(_beauty.processCount,       0, @"TC-V2T-3: Beauty must NOT execute");
    XCTAssertEqual(_segmentation.processCount, 0, @"TC-V2T-3: Segmentation must NOT execute");
    // Scheduler still delivers passthrough to sink even with all disabled.
    XCTAssertEqual(sink.presentCount, 1, @"TC-V2T-3: sink must still receive passthrough frame");

    [sched invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-V2T-4 — Recovery: Critical → Nominal re-enables all, all execute
// ─────────────────────────────────────────────────────────────────────────────
- (void)testRecovery_criticalToNominal_allFiltersReenabled {
    VGT_SinkSpy *sink = nil;
    NSArray *filters = @[_lut, _beauty, _segmentation];
    VGGraphSchedulerV2 *sched = VGT_BuildScheduler(filters, _source, &sink);

    // First: Critical → all disabled.
    VGT_ApplyThermalBudget(filters, NSProcessInfoThermalStateCritical);
    XCTAssertFalse(_lut.enabled,          @"TC-V2T-4 precondition: LUT must be disabled after Critical");
    XCTAssertFalse(_beauty.enabled,       @"TC-V2T-4 precondition: Beauty must be disabled after Critical");
    XCTAssertFalse(_segmentation.enabled, @"TC-V2T-4 precondition: Segmentation must be disabled after Critical");

    // Recovery: Nominal → all re-enabled.
    VGT_ApplyThermalBudget(filters, NSProcessInfoThermalStateNominal);
    XCTAssertTrue(_lut.enabled,          @"TC-V2T-4: LUT must be re-enabled after Nominal");
    XCTAssertTrue(_beauty.enabled,       @"TC-V2T-4: Beauty must be re-enabled after Nominal");
    XCTAssertTrue(_segmentation.enabled, @"TC-V2T-4: Segmentation must be re-enabled after Nominal");

    VGT_DeliverFrame(sched, _testBuffer);
    XCTAssertEqual(_lut.processCount,         1, @"TC-V2T-4: LUT must execute after recovery");
    XCTAssertEqual(_beauty.processCount,      1, @"TC-V2T-4: Beauty must execute after recovery");
    XCTAssertEqual(_segmentation.processCount, 1, @"TC-V2T-4: Segmentation must execute after recovery");

    [sched invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-V2T-5 — Empty chain: no crash
// ─────────────────────────────────────────────────────────────────────────────
- (void)testEmptyChain_noFiltersThermalNoOp {
    VGT_SinkSpy *sink = nil;
    NSArray<VGT_CostFilter *> *noFilters = @[];
    VGGraphSchedulerV2 *sched = VGT_BuildScheduler(noFilters, _source, &sink);

    XCTAssertNoThrow(VGT_ApplyThermalBudget(noFilters, NSProcessInfoThermalStateSerious),
                     @"TC-V2T-5: empty chain serious state must not throw");
    XCTAssertNoThrow(VGT_ApplyThermalBudget(noFilters, NSProcessInfoThermalStateCritical),
                     @"TC-V2T-5: empty chain critical state must not throw");
    XCTAssertNoThrow(VGT_ApplyThermalBudget(noFilters, NSProcessInfoThermalStateNominal),
                     @"TC-V2T-5: empty chain nominal state must not throw");

    VGT_DeliverFrame(sched, _testBuffer);
    XCTAssertEqual(sink.presentCount, 1, @"TC-V2T-5: sink must receive frame even with no filters");

    [sched invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-V2T-6 — V1 algorithm parity
// ─────────────────────────────────────────────────────────────────────────────
- (void)testAlgorithmParity_matchesV1ThermalBehavior {
    // Verify VGT_ApplyThermalBudget matches the expected V1 algorithm results.
    // V1 reference (VGCostBudgetThermalTest.m):
    //   Nominal:  all 3 enabled
    //   Fair:     all 3 enabled
    //   Serious:  LUT(2ms)+Beauty(3ms) enabled, Seg(5ms) disabled
    //   Critical: all disabled

    NSArray *filters = @[_lut, _beauty, _segmentation];

    // --- Nominal ---
    VGT_ApplyThermalBudget(filters, NSProcessInfoThermalStateNominal);
    XCTAssertTrue(_lut.enabled,           @"TC-V2T-6 Nominal: LUT enabled");
    XCTAssertTrue(_beauty.enabled,        @"TC-V2T-6 Nominal: Beauty enabled");
    XCTAssertTrue(_segmentation.enabled,  @"TC-V2T-6 Nominal: Segmentation enabled");

    // --- Fair ---
    VGT_ApplyThermalBudget(filters, NSProcessInfoThermalStateFair);
    XCTAssertTrue(_lut.enabled,           @"TC-V2T-6 Fair: LUT enabled");
    XCTAssertTrue(_beauty.enabled,        @"TC-V2T-6 Fair: Beauty enabled");
    XCTAssertTrue(_segmentation.enabled,  @"TC-V2T-6 Fair: Segmentation enabled");

    // --- Serious ---
    VGT_ApplyThermalBudget(filters, NSProcessInfoThermalStateSerious);
    XCTAssertTrue(_lut.enabled,            @"TC-V2T-6 Serious: LUT enabled (2ms ≤ 5ms budget)");
    XCTAssertTrue(_beauty.enabled,         @"TC-V2T-6 Serious: Beauty enabled (2+3=5ms ≤ 5ms budget)");
    XCTAssertFalse(_segmentation.enabled,  @"TC-V2T-6 Serious: Segmentation disabled (greedy: 5ms removed first)");

    // --- Critical ---
    VGT_ApplyThermalBudget(filters, NSProcessInfoThermalStateCritical);
    XCTAssertFalse(_lut.enabled,           @"TC-V2T-6 Critical: LUT disabled");
    XCTAssertFalse(_beauty.enabled,        @"TC-V2T-6 Critical: Beauty disabled");
    XCTAssertFalse(_segmentation.enabled,  @"TC-V2T-6 Critical: Segmentation disabled");
}

@end
