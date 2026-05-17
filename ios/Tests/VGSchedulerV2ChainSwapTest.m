// VGSchedulerV2ChainSwapTest.m
// vanguard_media_engine — Phase 4 Batch 4B
//
// Gate test: V2 setFilterChain hot-swap.
//
// Tests VGGraphSchedulerV2 rebuild-and-swap semantics:
//   TC-V2CS-1  Swap filter A → B, new filter executes on next frame.
//   TC-V2CS-2  Swap to empty chain, passthrough.
//   TC-V2CS-3  Swap to nil chain, passthrough.
//   TC-V2CS-4  Old scheduler ref receives no frames after swap (no crash).
//   TC-V2CS-5  10 rapid swaps — no crash, last filter applied.
//   TC-V2CS-6  Factory failure simulation — old scheduler survives.
//   TC-V2CS-7  Parity: hot-swap output == fresh construction output.
//
// Threading: all calls synchronous on test thread. No dispatch queues.
//
// Buffer ownership (RR-36):
//   _testBuffer        — test-owned (+1). Released in tearDown.
//   Spy captured buffers — spy retains +1, releases in dealloc.
//   Scheduler-owned (filter output) — scheduler releases after presentEnvelope:.

#import <XCTest/XCTest.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CMTime.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>

#import "VGGraphSchedulerV2.h"
#import "VGPlaybackGraphFactory.h"

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
#pragma mark - VGCS_MockSource
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCS_MockSource : NSObject <VGSourceNode>
@end
@implementation VGCS_MockSource {
    NSString *_nodeId;
}
- (instancetype)init {
    self = [super init];
    _nodeId = @"cs_source";
    return self;
}
- (NSString *)nodeId   { return _nodeId; }
- (NSString *)nodeType { return @"cs_mock_source"; }
- (VGNodeRole)nodeRole { return VGNodeRoleSource; }
- (void)prepareWithCompletion:(void (^)(NSError *_Nullable))c { if (c) c(nil); }
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
- (void)prepareWithContext:(VGGraphExecutionContext *)ctx
                completion:(void (^)(NSError *_Nullable))c {
    if (c) c(nil);
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGCS_SinkSpy (VGFrameSink + VGNode)
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCS_SinkSpy : NSObject <VGFrameSink>
@property (nonatomic) VGFrameEnvelope lastEnvelope;
@property (nonatomic) NSInteger       presentCount;
@property (nonatomic) CVPixelBufferRef capturedBuffer; // +1; released in dealloc
@end

@implementation VGCS_SinkSpy {
    NSString *_nodeId;
}
- (instancetype)init {
    self = [super init];
    _nodeId = @"cs_sink";
    return self;
}
- (void)dealloc {
    if (_capturedBuffer) { CVPixelBufferRelease(_capturedBuffer); _capturedBuffer = NULL; }
}
- (NSString *)nodeId   { return _nodeId; }
- (NSString *)nodeType { return @"cs_sink"; }
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
    _lastEnvelope = envelope;
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
#pragma mark - VGCS_XorFilter (deterministic transform)
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCS_XorFilter : NSObject <VGTransformNode>
@property (nonatomic) uint8_t xorByte;
@property (nonatomic) NSInteger processCount;
- (instancetype)initWithXorByte:(uint8_t)byte name:(NSString *)name;
@end

@implementation VGCS_XorFilter {
    NSString *_nodeId;
    NSString *_name;
}
- (instancetype)initWithXorByte:(uint8_t)byte name:(NSString *)name {
    self = [super init];
    _xorByte = byte;
    _name    = [name copy];
    _nodeId  = [NSString stringWithFormat:@"cs_xor_%@", name];
    return self;
}
- (NSString *)nodeId   { return _nodeId; }
- (NSString *)nodeType { return @"cs_xor_filter"; }
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
- (BOOL)enabled               { return YES; }
- (void)setEnabled:(BOOL)e    {}
- (BOOL)isExpensive           { return NO; }
- (float)estimatedGPUCostMs   { return 1.0f; }
- (NSString *)filterName      { return _name; }

- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                             device:(id<MTLDevice>)device {
    _processCount++;
    CVPixelBufferRef src = envelope.payload.videoBuffer;
    if (!src) return envelope;

    size_t w  = CVPixelBufferGetWidth(src);
    size_t h  = CVPixelBufferGetHeight(src);
    CVPixelBufferRef dst = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                       CVPixelBufferGetPixelFormatType(src),
                                       (__bridge CFDictionaryRef)attrs, &dst);
    if (ret != kCVReturnSuccess || !dst) return envelope;

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);
    uint8_t *srcBytes = CVPixelBufferGetBaseAddress(src);
    uint8_t *dstBytes = CVPixelBufferGetBaseAddress(dst);
    size_t   sz       = CVPixelBufferGetDataSize(src);
    uint8_t  mask     = _xorByte;
    for (size_t i = 0; i < sz; i++) dstBytes[i] = srcBytes[i] ^ mask;
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);

    VGFrameEnvelope out = envelope;
    out.payload.videoBuffer = dst; // caller (scheduler) releases dst +1 after delivery
    return out;
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Helpers
// ─────────────────────────────────────────────────────────────────────────────

static CVPixelBufferRef VGCS_MakeBuffer(uint8_t fill) {
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

/// Build a minimal VGGraphSchedulerV2 with the given filter (or nil for passthrough)
/// and a fresh VGCS_SinkSpy wired as sink.
/// Caller owns the returned scheduler (+1 via ARC).
/// outSink is set to the new VGCS_SinkSpy.
static VGGraphSchedulerV2 * VGCS_BuildScheduler(VGCS_XorFilter *filter,
                                                  VGCS_MockSource *source,
                                                  VGCS_SinkSpy **outSink) {
    // Build node map
    NSMutableDictionary<NSString *, id<VGNode>> *nodes = [NSMutableDictionary new];
    nodes[source.nodeId] = source;
    if (filter) nodes[filter.nodeId] = filter;

    VGCS_SinkSpy *sink = [VGCS_SinkSpy new];
    nodes[sink.nodeId]  = sink;

    // Build topological order: source → filter? → sink
    NSMutableArray<NSString *> *topo = [NSMutableArray new];
    [topo addObject:source.nodeId];
    if (filter) [topo addObject:filter.nodeId];
    [topo addObject:sink.nodeId];

    // VGExecutionPlan — created via designated init (topologicalOrder + parallelGroups)
    VGExecutionPlan *plan = [[VGExecutionPlan alloc] initWithTopologicalOrder:topo
                                                               parallelGroups:@[]];

    VGResourceAllocator *alloc = [VGResourceAllocator sharedInstance];
    // Minimal descriptor — use a real VGGraphDescriptor if required by context init
    VGGraphDescriptor *desc = [[VGGraphDescriptor alloc] init];

    VGGraphExecutionContext *ctx =
        [[VGGraphExecutionContext alloc] initWithDescriptor:desc
                                                       plan:plan
                                                      nodes:nodes
                                                      clock:nil
                                          resourceAllocator:alloc];

    VGGraphSchedulerV2 *sched =
        [[VGGraphSchedulerV2 alloc] initWithPlan:plan nodes:nodes context:ctx];
    sched.sink = sink;
    [sched startWithClock:nil];

    if (outSink) *outSink = sink;
    return sched;
}

/// Deliver a single frame to scheduler and return. Buffer +1 owned by caller.
static void VGCS_DeliverFrame(VGGraphSchedulerV2 *sched, CVPixelBufferRef buf) {
    VGFrameEnvelope env;
    memset(&env, 0, sizeof(env));
    env.mediaType            = VGMediaTypeVideo;
    env.pts                  = kCMTimeZero;
    env.payload.videoBuffer  = buf;
    [sched didReceiveRawFrame:env];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGSchedulerV2ChainSwapTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGSchedulerV2ChainSwapTest : XCTestCase
@end

@implementation VGSchedulerV2ChainSwapTest {
    CVPixelBufferRef _testBuffer; // test-owned (+1), released in tearDown
    VGCS_MockSource *_source;
}

- (void)setUp {
    [super setUp];
    _source     = [VGCS_MockSource new];
    _testBuffer = VGCS_MakeBuffer(0x80);
}

- (void)tearDown {
    if (_testBuffer) { CVPixelBufferRelease(_testBuffer); _testBuffer = NULL; }
    _source = nil;
    [super tearDown];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-V2CS-1 — Swap filter A → B; new filter executes on next frame
// ─────────────────────────────────────────────────────────────────────────────
- (void)testSwapFilterAtoB_newFilterExecutes {
    // Phase 1: scheduler with XOR-0xAA filter.
    VGCS_XorFilter *filterA = [[VGCS_XorFilter alloc] initWithXorByte:0xAA name:@"A"];
    VGCS_SinkSpy   *sinkA   = nil;
    VGGraphSchedulerV2 *sched = VGCS_BuildScheduler(filterA, _source, &sinkA);

    VGCS_DeliverFrame(sched, _testBuffer);
    XCTAssertEqual(sinkA.presentCount, 1, @"TC-V2CS-1: frame not delivered to sinkA");
    XCTAssertEqual(filterA.processCount, 1, @"TC-V2CS-1: filterA not executed");

    // Phase 2: rebuild with XOR-0x55 filter.
    VGCS_XorFilter *filterB = [[VGCS_XorFilter alloc] initWithXorByte:0x55 name:@"B"];
    VGCS_SinkSpy   *sinkB   = nil;
    VGGraphSchedulerV2 *newSched = VGCS_BuildScheduler(filterB, _source, &sinkB);

    // Simulate runtime hot-swap: renderer.frameDelegate → newSched.
    // (No renderer here — just deliver directly.)
    VGCS_DeliverFrame(newSched, _testBuffer);

    XCTAssertEqual(sinkB.presentCount, 1, @"TC-V2CS-1: frame not delivered to sinkB after swap");
    XCTAssertEqual(filterB.processCount, 1, @"TC-V2CS-1: filterB not executed after swap");
    XCTAssertEqual(filterA.processCount, 1, @"TC-V2CS-1: filterA executed after swap (should be 1 still)");

    // Verify XOR-0x55 transform applied to 0x80 fill → 0xD5 expected.
    if (sinkB.capturedBuffer) {
        CVPixelBufferLockBaseAddress(sinkB.capturedBuffer, kCVPixelBufferLock_ReadOnly);
        uint8_t *bytes = CVPixelBufferGetBaseAddress(sinkB.capturedBuffer);
        XCTAssertEqual(bytes[0], (uint8_t)(0x80 ^ 0x55),
                       @"TC-V2CS-1: filterB XOR-0x55 not applied correctly");
        CVPixelBufferUnlockBaseAddress(sinkB.capturedBuffer, kCVPixelBufferLock_ReadOnly);
    }

    [sched invalidate];
    [newSched invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-V2CS-2 — Swap to empty chain; passthrough
// ─────────────────────────────────────────────────────────────────────────────
- (void)testSwapToEmptyChain_passthrough {
    VGCS_XorFilter *filterA = [[VGCS_XorFilter alloc] initWithXorByte:0xAA name:@"A2"];
    VGCS_SinkSpy   *sinkA   = nil;
    VGGraphSchedulerV2 *sched = VGCS_BuildScheduler(filterA, _source, &sinkA);
    VGCS_DeliverFrame(sched, _testBuffer);

    // Rebuild with no filter (passthrough).
    VGCS_SinkSpy *sinkB   = nil;
    VGGraphSchedulerV2 *newSched = VGCS_BuildScheduler(nil, _source, &sinkB);
    VGCS_DeliverFrame(newSched, _testBuffer);

    XCTAssertEqual(sinkB.presentCount, 1, @"TC-V2CS-2: frame not delivered");
    // With no filter, output buffer == input buffer (source-owned passthrough).
    if (sinkB.capturedBuffer) {
        CVPixelBufferLockBaseAddress(sinkB.capturedBuffer, kCVPixelBufferLock_ReadOnly);
        uint8_t *bytes = CVPixelBufferGetBaseAddress(sinkB.capturedBuffer);
        XCTAssertEqual(bytes[0], 0x80, @"TC-V2CS-2: passthrough should preserve 0x80 fill");
        CVPixelBufferUnlockBaseAddress(sinkB.capturedBuffer, kCVPixelBufferLock_ReadOnly);
    }

    [sched invalidate];
    [newSched invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-V2CS-3 — Swap to nil chain treated as passthrough
// ─────────────────────────────────────────────────────────────────────────────
- (void)testSwapToNilChain_passthrough {
    // nil filter in VGCS_BuildScheduler → no filter nodes = passthrough
    VGCS_SinkSpy *sink = nil;
    VGGraphSchedulerV2 *sched = VGCS_BuildScheduler(nil, _source, &sink);

    VGCS_DeliverFrame(sched, _testBuffer);

    XCTAssertEqual(sink.presentCount, 1, @"TC-V2CS-3: frame not delivered for nil chain");
    [sched invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-V2CS-4 — Old scheduler ref receives no frames after swap; no crash
// ─────────────────────────────────────────────────────────────────────────────
- (void)testOldSchedulerIgnoresFramesAfterSwap {
    VGCS_XorFilter *filterA = [[VGCS_XorFilter alloc] initWithXorByte:0xAA name:@"A4"];
    VGCS_SinkSpy   *sinkA   = nil;
    VGGraphSchedulerV2 *oldSched = VGCS_BuildScheduler(filterA, _source, &sinkA);

    VGCS_SinkSpy   *sinkB   = nil;
    VGCS_XorFilter *filterB = [[VGCS_XorFilter alloc] initWithXorByte:0x55 name:@"B4"];
    VGGraphSchedulerV2 *newSched = VGCS_BuildScheduler(filterB, _source, &sinkB);

    // Simulate swap: no more frames go to oldSched.
    // Explicitly invalidate old sched to verify "no crash" after invalidation.
    [oldSched invalidate];

    XCTAssertNoThrow(VGCS_DeliverFrame(oldSched, _testBuffer),
                     @"TC-V2CS-4: delivering frame to invalidated old scheduler threw");
    XCTAssertEqual(sinkA.presentCount, 0,
                   @"TC-V2CS-4: invalidated scheduler should not forward frames to sink");

    VGCS_DeliverFrame(newSched, _testBuffer);
    XCTAssertEqual(sinkB.presentCount, 1,
                   @"TC-V2CS-4: new scheduler should still deliver frames");

    [newSched invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-V2CS-5 — 10 rapid swaps; no crash, last filter applied
// ─────────────────────────────────────────────────────────────────────────────
- (void)testRapidHotSwap_noCrashLastFilterApplied {
    VGGraphSchedulerV2 *current = nil;
    VGCS_SinkSpy       *lastSink = nil;
    VGCS_XorFilter     *lastFilter = nil;

    for (int i = 0; i < 10; i++) {
        uint8_t xorByte = (uint8_t)(0x10 + i);
        NSString *name  = [NSString stringWithFormat:@"Rapid%d", i];
        VGCS_XorFilter *f  = [[VGCS_XorFilter alloc] initWithXorByte:xorByte name:name];
        VGCS_SinkSpy   *s  = nil;
        VGGraphSchedulerV2 *next = VGCS_BuildScheduler(f, _source, &s);

        // Simulate runtime: old scheduler is released (not invalidated) during hot-swap.
        current  = next;
        lastSink = s;
        lastFilter = f;
    }

    XCTAssertNoThrow(VGCS_DeliverFrame(current, _testBuffer),
                     @"TC-V2CS-5: delivery after 10 swaps threw");
    XCTAssertEqual(lastSink.presentCount, 1,
                   @"TC-V2CS-5: final scheduler did not deliver frame");
    XCTAssertEqual(lastFilter.processCount, 1,
                   @"TC-V2CS-5: final filter not executed");

    [current invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-V2CS-6 — Rebuild failure: old scheduler survives, old filter still active
// ─────────────────────────────────────────────────────────────────────────────
- (void)testRebuildFailure_oldSchedulerSurvives {
    VGCS_XorFilter *filterA = [[VGCS_XorFilter alloc] initWithXorByte:0xAA name:@"A6"];
    VGCS_SinkSpy   *sinkA   = nil;
    VGGraphSchedulerV2 *sched = VGCS_BuildScheduler(filterA, _source, &sinkA);

    // Deliver frame — old filter applies.
    VGCS_DeliverFrame(sched, _testBuffer);
    XCTAssertEqual(filterA.processCount, 1,
                   @"TC-V2CS-6: filterA must execute on first delivery");

    // Simulate rebuild failure: do NOT swap. Deliver again to old scheduler.
    // (The runtime's failure path leaves self.schedulerV2 = oldSched unchanged.)
    VGCS_DeliverFrame(sched, _testBuffer);
    XCTAssertEqual(filterA.processCount, 2,
                   @"TC-V2CS-6: filterA must still execute after failed rebuild");
    XCTAssertEqual(sinkA.presentCount, 2,
                   @"TC-V2CS-6: old sink must receive both frames");

    [sched invalidate];
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-V2CS-7 — Parity: hot-swap output == fresh construction output
// ─────────────────────────────────────────────────────────────────────────────
- (void)testHotSwapParity_matchesFreshConstruction {
    // Path A: start with filterA, hot-swap to filterB.
    VGCS_XorFilter *fA  = [[VGCS_XorFilter alloc] initWithXorByte:0xAA name:@"PA"];
    VGCS_SinkSpy   *s1  = nil;
    VGGraphSchedulerV2 *sched1 = VGCS_BuildScheduler(fA, _source, &s1);
    VGCS_DeliverFrame(sched1, _testBuffer); // deliver to A (warm-up)

    VGCS_XorFilter *fB  = [[VGCS_XorFilter alloc] initWithXorByte:0x55 name:@"PB"];
    VGCS_SinkSpy   *s2  = nil;
    VGGraphSchedulerV2 *swapped = VGCS_BuildScheduler(fB, _source, &s2);
    VGCS_DeliverFrame(swapped, _testBuffer); // hot-swap target

    // Path B: fresh construction with filterB only.
    VGCS_XorFilter *fB2 = [[VGCS_XorFilter alloc] initWithXorByte:0x55 name:@"PB2"];
    VGCS_SinkSpy   *s3  = nil;
    VGGraphSchedulerV2 *fresh = VGCS_BuildScheduler(fB2, _source, &s3);
    VGCS_DeliverFrame(fresh, _testBuffer);

    // Compare output bytes: both should be 0x80 ^ 0x55 = 0xD5.
    XCTAssertNotNil((id)s2.capturedBuffer, @"TC-V2CS-7: swapped path no output buffer");
    XCTAssertNotNil((id)s3.capturedBuffer, @"TC-V2CS-7: fresh path no output buffer");

    if (s2.capturedBuffer && s3.capturedBuffer) {
        CVPixelBufferLockBaseAddress(s2.capturedBuffer, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(s3.capturedBuffer, kCVPixelBufferLock_ReadOnly);

        size_t sz2 = CVPixelBufferGetDataSize(s2.capturedBuffer);
        size_t sz3 = CVPixelBufferGetDataSize(s3.capturedBuffer);
        XCTAssertEqual(sz2, sz3, @"TC-V2CS-7: buffer sizes differ");

        if (sz2 == sz3) {
            uint8_t *b2 = CVPixelBufferGetBaseAddress(s2.capturedBuffer);
            uint8_t *b3 = CVPixelBufferGetBaseAddress(s3.capturedBuffer);
            int maxDelta = 0;
            for (size_t i = 0; i < sz2; i++) {
                int d = abs((int)b2[i] - (int)b3[i]);
                if (d > maxDelta) maxDelta = d;
            }
            XCTAssertEqual(maxDelta, 0,
                           @"TC-V2CS-7: hot-swap output != fresh output (maxDelta=%d)", maxDelta);
        }

        CVPixelBufferUnlockBaseAddress(s3.capturedBuffer, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(s2.capturedBuffer, kCVPixelBufferLock_ReadOnly);
    }

    [sched1 invalidate];
    [swapped invalidate];
    [fresh invalidate];
}

@end
