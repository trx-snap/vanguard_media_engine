// VGExportSchedulerPullLoopTest.m
// vanguard_media_engine — Phase 5C-1
//
// Gate test: VGExportScheduler pull loop skeleton.
//
// Tests the pull-mode export scheduler against mock source, transform,
// metadata, and sink nodes. No AVAssetReader, no AVAssetWriter, no VideoToolbox.
//
// Mock class prefix: VGES_ (VG Export Scheduler).
//
// Threading: startExport dispatches to _exportQueue (async).
// Tests use XCTestExpectation to wait for completionHandler.
//
// Buffer ownership (RR-36):
//   _testBuffer — test-owned (+1). Released in tearDown.
//   VGES_SinkSpy.capturedBuffer — spy retains +1, releases in dealloc.

#import <XCTest/XCTest.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CMTime.h>
#import <Metal/Metal.h>

#import "VGExportScheduler.h"

#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGNode.h>
#import <UMF/VGSourceNode.h>
#import <UMF/VGTransformNode.h>
#import <UMF/VGMetadataNode.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGExecutionPlan.h>
#import <UMF/VGGraphDescriptor.h>
#import <UMF/VGGraphNodeDescriptor.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGResourceAllocator.h>
#import <UMF/VGFrameRequest.h>
#import <UMF/VGFrameResult.h>
#import <UMF/VGFrameDelegate.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Helpers
// ─────────────────────────────────────────────────────────────────────────────

static CVPixelBufferRef VGES_MakeBuffer(uint8_t fill) {
    const size_t W = 16, H = 16;
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferRef buf = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, W, H,
                        kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)attrs, &buf);
    if (buf) {
        CVPixelBufferLockBaseAddress(buf, 0);
        memset(CVPixelBufferGetBaseAddress(buf), fill, CVPixelBufferGetDataSize(buf));
        CVPixelBufferUnlockBaseAddress(buf, 0);
    }
    return buf;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGES_SlowInfinitePullSource
// ─────────────────────────────────────────────────────────────────────────────

/// A pull source that sleeps 0.5ms per frame and never terminates naturally.
/// Used in cancel/invalidate tests to guarantee the cancel dispatch (50ms) fires
/// while the loop is still running, even on fast hardware.
@interface VGES_SlowInfinitePullSource : NSObject <VGSourceNode>
// Buffer is test-owned (+1), not retained by this source.
@end

@implementation VGES_SlowInfinitePullSource {
    NSString        *_nodeId;
    CVPixelBufferRef _buffer; // +1 owned by test; this class does not retain/release
}
- (instancetype)initWithBuffer:(CVPixelBufferRef)buf {
    self = [super init];
    _nodeId = @"vges_slow_source";
    _buffer = buf;
    return self;
}
- (NSString *)nodeId    { return _nodeId; }
- (NSString *)nodeClass { return @"VGES_SlowInfinitePullSource"; }
- (VGNodeRole)nodeRole  { return VGNodeRoleSource; }
- (NSArray<VGMediaPort *> *)declaredPorts {
    return @[ [VGMediaPort outputPort:@"video_out" mediaType:VGMediaTypeVideo] ];
}
- (void)prepareWithContext:(VGGraphExecutionContext *)ctx
                completion:(void (^)(NSError *_Nullable))c {
    if (c) c(nil);
}
- (void)invalidate {}
- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)p
                                       inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)f { return nil; }
- (void)startProducing {}
- (void)stopProducing  {}
- (void)seekTo:(CMTime)t generation:(uint64_t)g {}
- (VGFrameResult *)pullFrame:(VGFrameRequest *)request {
    if (request.isCancelled) return [VGFrameResult skippedWithGeneration:request.generation];
    usleep(500); // 0.5ms — guarantees 50ms cancel fires before ~100 frames
    VGFrameEnvelope env;
    memset(&env, 0, sizeof(env));
    env.payload.videoBuffer = _buffer;
    env.mediaType           = VGMediaTypeVideo;
    env.pts                 = kCMTimeZero;
    env.generation          = request.generation;
    return [VGFrameResult deliveredWithEnvelope:env generation:request.generation];
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGES_MockPullSource
// ─────────────────────────────────────────────────────────────────────────────

@interface VGES_MockPullSource : NSObject <VGSourceNode>
@property (nonatomic, strong) NSArray<VGFrameResult *> *results;
@property (nonatomic) NSInteger pullCount;
+ (VGFrameResult *)deliveredResultWithBuffer:(CVPixelBufferRef)buf generation:(uint64_t)gen;
@end

@implementation VGES_MockPullSource {
    NSString *_nodeId;
}
- (instancetype)init {
    self = [super init];
    _nodeId = @"vges_source";
    _results = @[];
    return self;
}
+ (VGFrameResult *)deliveredResultWithBuffer:(CVPixelBufferRef)buf generation:(uint64_t)gen {
    VGFrameEnvelope env;
    memset(&env, 0, sizeof(env));
    env.payload.videoBuffer = buf;
    env.mediaType           = VGMediaTypeVideo;
    env.pts                 = kCMTimeZero;
    env.generation          = gen;
    env.metadata            = NULL;
    return [VGFrameResult deliveredWithEnvelope:env generation:gen];
}
- (NSString *)nodeId    { return _nodeId; }
- (NSString *)nodeClass { return @"VGES_MockPullSource"; }
- (VGNodeRole)nodeRole  { return VGNodeRoleSource; }
- (NSArray<VGMediaPort *> *)declaredPorts {
    return @[ [VGMediaPort outputPort:@"video_out" mediaType:VGMediaTypeVideo] ];
}
- (void)prepareWithContext:(VGGraphExecutionContext *)ctx
                completion:(void (^)(NSError *_Nullable))c {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ if (c) c(nil); });
}
- (void)invalidate {}
- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)p
                                       inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)f {
    return nil;
}
- (void)startProducing {}
- (void)stopProducing  {}
- (void)seekTo:(CMTime)t generation:(uint64_t)g {}
- (VGFrameResult *)pullFrame:(VGFrameRequest *)request {
    NSInteger idx = _pullCount++;
    if (idx < (NSInteger)_results.count) {
        return _results[idx];
    }
    return [VGFrameResult endOfStreamWithGeneration:request.generation];
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGES_MockTransform
// ─────────────────────────────────────────────────────────────────────────────

@interface VGES_MockTransform : NSObject <VGTransformNode>
@property (nonatomic) NSInteger processCount;
@property (nonatomic, assign) BOOL enabled;
- (instancetype)initWithNodeId:(NSString *)nodeId;
@end

@implementation VGES_MockTransform {
    NSString *_nodeId;
}
- (instancetype)initWithNodeId:(NSString *)nodeId {
    self = [super init];
    _nodeId  = [nodeId copy];
    _enabled = YES;
    return self;
}
- (NSString *)nodeId    { return _nodeId; }
- (NSString *)nodeClass { return @"VGES_MockTransform"; }
- (VGNodeRole)nodeRole  { return VGNodeRoleFilter; }
- (NSArray<VGMediaPort *> *)declaredPorts { return @[]; }
- (void)prepareWithContext:(VGGraphExecutionContext *)ctx
                completion:(void (^)(NSError *_Nullable))c { if (c) c(nil); }
- (void)invalidate {}
- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)p
                                       inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)f {
    return nil;
}
- (float)estimatedGPUCostMs { return 1.0f; }
- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope device:(id<MTLDevice>)device {
    _processCount++;
    return envelope; // identity passthrough
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGES_MockMetadataNode
// ─────────────────────────────────────────────────────────────────────────────

@interface VGES_MockMetadataNode : NSObject <VGMetadataNode>
@property (nonatomic) NSInteger enrichCount;
- (instancetype)initWithNodeId:(NSString *)nodeId;
@end

@implementation VGES_MockMetadataNode {
    NSString *_nodeId;
}
- (instancetype)initWithNodeId:(NSString *)nodeId {
    self = [super init];
    _nodeId = [nodeId copy];
    return self;
}
- (NSString *)nodeId    { return _nodeId; }
- (NSString *)nodeClass { return @"VGES_MockMetadataNode"; }
- (VGNodeRole)nodeRole  { return (VGNodeRole)4; }
- (NSArray<VGMediaPort *> *)declaredPorts { return @[]; }
- (void)prepareWithContext:(VGGraphExecutionContext *)ctx
                completion:(void (^)(NSError *_Nullable))c { if (c) c(nil); }
- (void)invalidate {}
- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)p
                                       inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)f {
    return nil;
}
- (VGFrameEnvelope)enrichEnvelope:(VGFrameEnvelope)envelope device:(id<MTLDevice>)device {
    _enrichCount++;
    return envelope; // identity passthrough
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGES_SinkSpy
// ─────────────────────────────────────────────────────────────────────────────

@interface VGES_SinkSpy : NSObject <VGFrameSink>
@property (nonatomic) NSInteger presentCount;
@property (nonatomic) CVPixelBufferRef capturedBuffer; // +1; released in dealloc
@property (nonatomic) VGFrameEnvelope lastEnvelope;
@end

@implementation VGES_SinkSpy {
    NSString *_nodeId;
}
- (instancetype)init {
    self = [super init];
    _nodeId = @"vges_sink";
    return self;
}
- (void)dealloc {
    if (_capturedBuffer) { CVPixelBufferRelease(_capturedBuffer); _capturedBuffer = NULL; }
}
- (NSString *)nodeId    { return _nodeId; }
- (NSString *)nodeClass { return @"VGES_SinkSpy"; }
- (VGNodeRole)nodeRole  { return VGNodeRoleSink; }
- (NSArray<VGMediaPort *> *)declaredPorts { return @[]; }
- (void)prepareWithContext:(VGGraphExecutionContext *)ctx
                completion:(void (^)(NSError *_Nullable))c { if (c) c(nil); }
- (void)invalidate {}
- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)p
                                       inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)f {
    return nil;
}
- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    _presentCount++;
    _lastEnvelope = envelope;
    CVPixelBufferRef buf = (CVPixelBufferRef)envelope.payload.videoBuffer;
    if (buf) {
        CVPixelBufferRetain(buf);
        if (_capturedBuffer) CVPixelBufferRelease(_capturedBuffer);
        _capturedBuffer = buf;
    }
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Build helper
// ─────────────────────────────────────────────────────────────────────────────

/// Build a VGExportScheduler with the given mock components.
/// topoOrder: source nodeId → transform nodeIds → metadata nodeIds → sink nodeId
static VGExportScheduler *VGES_BuildScheduler(id<VGSourceNode> source,
                                               NSArray<VGES_MockTransform *> *transforms,
                                               NSArray<VGES_MockMetadataNode *> *metaNodes,
                                               VGES_SinkSpy *sink,
                                               int32_t fps) {
    NSMutableDictionary<NSString *, id<VGNode>> *nodes = [NSMutableDictionary new];
    nodes[source.nodeId] = source;
    for (VGES_MockTransform *t in transforms)   nodes[t.nodeId] = t;
    for (VGES_MockMetadataNode *m in metaNodes) nodes[m.nodeId] = m;
    nodes[sink.nodeId] = sink;

    NSMutableArray<NSString *> *topo = [NSMutableArray new];
    [topo addObject:source.nodeId];
    for (VGES_MockTransform *t in transforms)   [topo addObject:t.nodeId];
    for (VGES_MockMetadataNode *m in metaNodes) [topo addObject:m.nodeId];
    [topo addObject:sink.nodeId];

    VGExecutionPlan *plan = [[VGExecutionPlan alloc] initWithTopologicalOrder:topo
                                                               parallelGroups:@[]];
    VGGraphDescriptor *desc = [[VGGraphDescriptor alloc]
        initWithGraphId:@"vges_testGraph"
                  nodes:@[]
            connections:@[]
            clockPolicy:VGClockPolicyPull
           audioSidecar:nil];
    VGGraphExecutionContext *ctx =
        [[VGGraphExecutionContext alloc] initWithDescriptor:desc
                                                       plan:plan
                                                      nodes:nodes
                                                      clock:nil
                                          resourceAllocator:[VGResourceAllocator sharedInstance]];
    VGExportScheduler *sched =
        [[VGExportScheduler alloc] initWithPlan:plan nodes:nodes context:ctx fps:fps];
    sched.sink = sink;
    return sched;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGExportSchedulerPullLoopTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGExportSchedulerPullLoopTest : XCTestCase
@end

@implementation VGExportSchedulerPullLoopTest {
    CVPixelBufferRef _testBuffer; // test-owned (+1), released in tearDown
}

- (void)setUp {
    [super setUp];
    _testBuffer = VGES_MakeBuffer(0x42);
}

- (void)tearDown {
    if (_testBuffer) { CVPixelBufferRelease(_testBuffer); _testBuffer = NULL; }
    [super tearDown];
}

// ─── TC-5C1-1: Pull loop delivers one frame to sink ──────────────────────────

- (void)testTC5C1_1_pullLoopDeliversOneFrameToSink {
    VGES_MockPullSource *source = [VGES_MockPullSource new];
    source.results = @[
        [VGES_MockPullSource deliveredResultWithBuffer:_testBuffer generation:1],
        [VGFrameResult endOfStreamWithGeneration:1]
    ];
    VGES_SinkSpy *sink = [VGES_SinkSpy new];
    VGExportScheduler *sched = VGES_BuildScheduler(source, @[], @[], sink, 30);

    XCTestExpectation *done = [self expectationWithDescription:@"TC-5C1-1 completion"];
    __block BOOL completionSuccess = NO;
    sched.completionHandler = ^(BOOL s, NSError *e) {
        completionSuccess = s;
        [done fulfill];
    };
    [sched startExport];
    [self waitForExpectations:@[done] timeout:2.0];

    XCTAssertEqual(sink.presentCount, 1, @"TC-5C1-1: sink must receive exactly one frame");
    XCTAssertTrue(completionSuccess, @"TC-5C1-1: completion must be success");
}

// ─── TC-5C1-2: EOS triggers successful completion ────────────────────────────

- (void)testTC5C1_2_endOfStreamTriggersSuccessCompletion {
    VGES_MockPullSource *source = [VGES_MockPullSource new];
    source.results = @[
        [VGES_MockPullSource deliveredResultWithBuffer:_testBuffer generation:1],
        [VGES_MockPullSource deliveredResultWithBuffer:_testBuffer generation:1],
        [VGES_MockPullSource deliveredResultWithBuffer:_testBuffer generation:1],
        [VGFrameResult endOfStreamWithGeneration:1]
    ];
    VGES_SinkSpy *sink = [VGES_SinkSpy new];
    VGExportScheduler *sched = VGES_BuildScheduler(source, @[], @[], sink, 30);

    __block BOOL completionSuccess = NO;
    __block NSError *completionError = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"TC-5C1-2"];
    sched.completionHandler = ^(BOOL s, NSError *e) {
        completionSuccess = s;
        completionError   = e;
        [done fulfill];
    };
    [sched startExport];
    [self waitForExpectations:@[done] timeout:2.0];

    XCTAssertEqual(sink.presentCount, 3, @"TC-5C1-2: 3 frames delivered");
    XCTAssertTrue(completionSuccess, @"TC-5C1-2: success");
    XCTAssertNil(completionError, @"TC-5C1-2: no error");
}

// ─── TC-5C1-3: Source error triggers failed completion ───────────────────────

- (void)testTC5C1_3_sourceErrorTriggersFailedCompletion {
    VGES_MockPullSource *source = [VGES_MockPullSource new];
    NSError *srcErr = [NSError errorWithDomain:@"TestDomain" code:99 userInfo:nil];
    source.results = @[
        [VGES_MockPullSource deliveredResultWithBuffer:_testBuffer generation:1],
        [VGFrameResult errorResult:srcErr generation:1]
    ];
    VGES_SinkSpy *sink = [VGES_SinkSpy new];
    VGExportScheduler *sched = VGES_BuildScheduler(source, @[], @[], sink, 30);

    __block BOOL completionSuccess = YES;
    __block NSError *completionError = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"TC-5C1-3"];
    sched.completionHandler = ^(BOOL s, NSError *e) {
        completionSuccess = s;
        completionError   = e;
        [done fulfill];
    };
    [sched startExport];
    [self waitForExpectations:@[done] timeout:2.0];

    XCTAssertFalse(completionSuccess, @"TC-5C1-3: must fail");
    XCTAssertNotNil(completionError, @"TC-5C1-3: error must be non-nil");
    XCTAssertEqual(sink.presentCount, 1, @"TC-5C1-3: one frame before error");
}

// ─── TC-5C1-4: Skipped frame continues to next request ───────────────────────

- (void)testTC5C1_4_skippedFrameContinuesToNextRequest {
    VGES_MockPullSource *source = [VGES_MockPullSource new];
    source.results = @[
        [VGES_MockPullSource deliveredResultWithBuffer:_testBuffer generation:1],
        [VGFrameResult skippedWithGeneration:1],
        [VGES_MockPullSource deliveredResultWithBuffer:_testBuffer generation:1],
        [VGFrameResult endOfStreamWithGeneration:1]
    ];
    VGES_SinkSpy *sink = [VGES_SinkSpy new];
    VGExportScheduler *sched = VGES_BuildScheduler(source, @[], @[], sink, 30);

    __block BOOL completionSuccess = NO;
    XCTestExpectation *done = [self expectationWithDescription:@"TC-5C1-4"];
    sched.completionHandler = ^(BOOL s, NSError *e) {
        completionSuccess = s;
        [done fulfill];
    };
    [sched startExport];
    [self waitForExpectations:@[done] timeout:2.0];

    XCTAssertEqual(sink.presentCount, 2, @"TC-5C1-4: 2 delivered (1 skipped)");
    XCTAssertEqual(source.pullCount, 4, @"TC-5C1-4: source pulled 4 times");
    XCTAssertTrue(completionSuccess, @"TC-5C1-4: success");
}

// ─── TC-5C1-5: cancelExport stops loop and completion fires ──────────────────

- (void)testTC5C1_5_cancelExportStopsLoopAndCompletionFires {
    // VGES_SlowInfinitePullSource sleeps 0.5ms per pull — guarantees the 50ms
    // cancel dispatch fires while the loop is running on any hardware.
    VGES_SlowInfinitePullSource *source = [[VGES_SlowInfinitePullSource alloc]
                                           initWithBuffer:_testBuffer];
    VGES_SinkSpy *sink = [VGES_SinkSpy new];
    VGExportScheduler *sched = VGES_BuildScheduler(source, @[], @[], sink, 30);

    __block BOOL completionSuccess = YES;
    __block NSUInteger completionCount = 0;
    XCTestExpectation *done = [self expectationWithDescription:@"TC-5C1-5"];
    done.expectedFulfillmentCount = 1;
    sched.completionHandler = ^(BOOL s, NSError *e) {
        completionSuccess = s;
        completionCount++;
        [done fulfill];
    };
    [sched startExport];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [sched cancelExport];
    });
    [self waitForExpectations:@[done] timeout:3.0];

    XCTAssertFalse(completionSuccess, @"TC-5C1-5: cancel => success==NO");
    XCTAssertEqual(completionCount, (NSUInteger)1, @"TC-5C1-5: completion fires exactly once");
}

// ─── TC-5C1-6: invalidate is idempotent and prevents double completion ────────

- (void)testTC5C1_6_invalidateIsIdempotentAndPreventsDoubleCompletion {
    // VGES_SlowInfinitePullSource sleeps 0.5ms per pull — guarantees the 50ms
    // invalidate dispatch fires while the loop is still running.
    VGES_SlowInfinitePullSource *source = [[VGES_SlowInfinitePullSource alloc]
                                           initWithBuffer:_testBuffer];

    VGES_SinkSpy *sink = [VGES_SinkSpy new];
    VGExportScheduler *sched = VGES_BuildScheduler(source, @[], @[], sink, 30);

    __block NSUInteger completionCount = 0;
    XCTestExpectation *done = [self expectationWithDescription:@"TC-5C1-6"];
    done.expectedFulfillmentCount = 1;
    sched.completionHandler = ^(BOOL s, NSError *e) {
        completionCount++;
        if (completionCount == 1) [done fulfill];
    };
    [sched startExport];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [sched invalidate];
        [sched invalidate]; // second call must be no-op
    });
    [self waitForExpectations:@[done] timeout:3.0];

    // Drain any residual async callbacks.
    [NSThread sleepForTimeInterval:0.1];
    XCTAssertEqual(completionCount, (NSUInteger)1,
                   @"TC-5C1-6: completionHandler must fire at most once");
}

// ─── TC-5C1-7: transform processEnvelope invoked in order ────────────────────

- (void)testTC5C1_7_transformNodeProcessEnvelopeInvokedInOrder {
    VGES_MockPullSource *source = [VGES_MockPullSource new];
    source.results = @[
        [VGES_MockPullSource deliveredResultWithBuffer:_testBuffer generation:1],
        [VGFrameResult endOfStreamWithGeneration:1]
    ];
    VGES_MockTransform *tA = [[VGES_MockTransform alloc] initWithNodeId:@"vges_transform_A"];
    VGES_MockTransform *tB = [[VGES_MockTransform alloc] initWithNodeId:@"vges_transform_B"];
    VGES_SinkSpy *sink = [VGES_SinkSpy new];
    VGExportScheduler *sched = VGES_BuildScheduler(source, @[tA, tB], @[], sink, 30);

    XCTestExpectation *done = [self expectationWithDescription:@"TC-5C1-7"];
    sched.completionHandler = ^(BOOL s, NSError *e) { [done fulfill]; };
    [sched startExport];
    [self waitForExpectations:@[done] timeout:2.0];

    XCTAssertEqual(tA.processCount, 1, @"TC-5C1-7: transform A must process 1 frame");
    XCTAssertEqual(tB.processCount, 1, @"TC-5C1-7: transform B must process 1 frame");
}

// ─── TC-5C1-8: metadata enrichEnvelope invoked ───────────────────────────────

- (void)testTC5C1_8_metadataNodeEnrichEnvelopeInvoked {
    VGES_MockPullSource *source = [VGES_MockPullSource new];
    source.results = @[
        [VGES_MockPullSource deliveredResultWithBuffer:_testBuffer generation:1],
        [VGFrameResult endOfStreamWithGeneration:1]
    ];
    VGES_MockMetadataNode *meta = [[VGES_MockMetadataNode alloc] initWithNodeId:@"vges_meta"];
    VGES_SinkSpy *sink = [VGES_SinkSpy new];
    VGExportScheduler *sched = VGES_BuildScheduler(source, @[], @[meta], sink, 30);

    XCTestExpectation *done = [self expectationWithDescription:@"TC-5C1-8"];
    sched.completionHandler = ^(BOOL s, NSError *e) { [done fulfill]; };
    [sched startExport];
    [self waitForExpectations:@[done] timeout:2.0];

    XCTAssertEqual(meta.enrichCount, 1, @"TC-5C1-8: metadata enrichCount must be 1");
}

// ─── TC-5C1-9: sink presentEnvelope called after transforms ──────────────────

- (void)testTC5C1_9_sinkPresentEnvelopeCalledAfterTransforms {
    VGES_MockPullSource *source = [VGES_MockPullSource new];
    source.results = @[
        [VGES_MockPullSource deliveredResultWithBuffer:_testBuffer generation:1],
        [VGFrameResult endOfStreamWithGeneration:1]
    ];
    VGES_MockTransform *transform = [[VGES_MockTransform alloc] initWithNodeId:@"vges_xform"];
    VGES_SinkSpy *sink = [VGES_SinkSpy new];
    VGExportScheduler *sched = VGES_BuildScheduler(source, @[transform], @[], sink, 30);

    XCTestExpectation *done = [self expectationWithDescription:@"TC-5C1-9"];
    sched.completionHandler = ^(BOOL s, NSError *e) { [done fulfill]; };
    [sched startExport];
    [self waitForExpectations:@[done] timeout:2.0];

    XCTAssertEqual(transform.processCount, 1,
                   @"TC-5C1-9: transform must execute before sink");
    XCTAssertEqual(sink.presentCount, 1,
                   @"TC-5C1-9: sink must receive exactly one frame");
}

// ─── TC-5C1-10: scheduler does not use VGFrameDelegate ───────────────────────

- (void)testTC5C1_10_schedulerDoesNotConformToVGFrameDelegate {
    VGES_MockPullSource *source = [VGES_MockPullSource new];
    source.results = @[ [VGFrameResult endOfStreamWithGeneration:0] ];
    VGES_SinkSpy *sink = [VGES_SinkSpy new];
    VGExportScheduler *sched = VGES_BuildScheduler(source, @[], @[], sink, 30);

    XCTAssertFalse([sched conformsToProtocol:@protocol(VGFrameDelegate)],
                   @"TC-5C1-10: VGExportScheduler must NOT conform to VGFrameDelegate");
    XCTAssertFalse([sched respondsToSelector:@selector(didReceiveRawFrame:)],
                   @"TC-5C1-10: VGExportScheduler must NOT respond to didReceiveRawFrame:");
}

@end
