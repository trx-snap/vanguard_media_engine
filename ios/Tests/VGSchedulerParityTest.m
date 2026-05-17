// VGSchedulerParityTest.m
// vanguard_media_engine — Phase 4 Pre-4A
//
// Gate test: VGSchedulerParityTest
//
// Purpose:
//   Verifies that V1 VanguardGraphScheduler and V2 VGGraphSchedulerV2 produce
//   pixel-identical output for the same input frame and filter chain.
//
//   This is the Batch 4A pixel-parity precondition: if V1 and V2 schedulers
//   diverge in output here, 4A cannot pass. If they match here, the delta on
//   a real pipeline is zero by construction (same transform, same path).
//
// Architecture:
//   VGParityP_SinkSpyV1  — plain NSObject with presentEnvelope: assigned to
//     VanguardGraphScheduler.sink via unsafe cast (VGP45SinkSpy pattern).
//   VGParityP_SinkSpyV2  — NSObject conforming to VGFrameSink+VGNode, wired to
//     VGGraphSchedulerV2.sink directly.
//   VGParityP_MockFilter — NSObject conforming to VGMetalFilterNode+VGTransformNode
//     with a deterministic XOR-0xAA per-byte transform.
//   VGParityP_MockSource — minimal VGSourceNode stub (no-op) to satisfy
//     VGGraphSchedulerV2.initWithPlan:nodes:context: source extraction.
//
// Threading:
//   All didReceiveRawFrame: calls are made synchronously on the test thread.
//   No dispatch queues created.
//
// Buffer ownership (RR-36):
//   _testBuffer        — test-owned (+1). Released in tearDown.
//   Spy captured buffers — spy retains +1 in presentEnvelope:, releases in dealloc.
//   Scheduler-owned (filter output) — scheduler releases after presentEnvelope:.
//   No double-release.

#import <XCTest/XCTest.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CMTime.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>

#import "VanguardGraphScheduler.h"
#import "VanguardMetalRenderer.h"   // required for sink property type
#import "VGGraphSchedulerV2.h"
#import "VGLegacyFilterAdapter.h"

#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGFrameDelegate.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGNode.h>
#import <UMF/VGSourceNode.h>
#import <UMF/VGTransformNode.h>
#import <UMF/VGMetalFilterNode.h>
#import <UMF/VGMediaNode.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGExecutionPlan.h>
#import <UMF/VGGraphDescriptor.h>
#import <UMF/VGGraphNodeDescriptor.h>
#import <UMF/VGGraphConnection.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGResourceAllocator.h>

// VGNodeRoleMetadata = 4 (VGNodeRoleExtended — matches VGGraphSchedulerV2.m)
static const VGNodeRole kVGParityNodeRoleMetadata = (VGNodeRole)4;

#pragma mark - VGParityP_SinkSpyV1 (V1 sink — unsafe cast pattern)

@interface VGParityP_SinkSpyV1 : NSObject
@property (nonatomic, assign) NSUInteger presentCallCount;
@property (nonatomic, assign) CVPixelBufferRef capturedBuffer; // spy-retained +1
@property (nonatomic, assign) VGFrameEnvelope capturedEnvelope;
- (void)presentEnvelope:(VGFrameEnvelope)envelope;
@end

@implementation VGParityP_SinkSpyV1

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _presentCallCount = 0;
    _capturedBuffer = NULL;
    return self;
}

- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    _presentCallCount++;
    _capturedEnvelope = envelope;
    // Retain the delivered buffer so the test can compare pixels after
    // didReceiveRawFrame: returns (RR-36 spy +1; released in dealloc).
    if (_capturedBuffer) {
        CVPixelBufferRelease(_capturedBuffer);
        _capturedBuffer = NULL;
    }
    if (envelope.payload.videoBuffer) {
        _capturedBuffer = (CVPixelBufferRef)envelope.payload.videoBuffer;
        CVPixelBufferRetain(_capturedBuffer);
    }
}

- (void)dealloc {
    if (_capturedBuffer) {
        CVPixelBufferRelease(_capturedBuffer);
        _capturedBuffer = NULL;
    }
}

@end

#pragma mark - VGParityP_SinkSpyV2 (V2 sink — VGFrameSink conformant)

@interface VGParityP_SinkSpyV2 : NSObject <VGFrameSink>
@property (nonatomic, assign) NSUInteger presentCallCount;
@property (nonatomic, assign) CVPixelBufferRef capturedBuffer; // spy-retained +1
@property (nonatomic, assign) VGFrameEnvelope capturedEnvelope;
@end

@implementation VGParityP_SinkSpyV2

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _presentCallCount = 0;
    _capturedBuffer = NULL;
    return self;
}

// VGNode — Identity
- (NSString *)nodeId    { return @"parity_test_sink_v2"; }
- (NSString *)nodeClass { return @"VGParityP_SinkSpyV2"; }
- (VGNodeRole)nodeRole  { return VGNodeRoleSink; }

// VGNode — Ports
- (NSArray<VGMediaPort *> *)declaredPorts {
    return @[ [VGMediaPort inputPort:@"video_in"
                          mediaType:VGMediaTypeVideo
                           required:YES] ];
}

// VGNode — Lifecycle
- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(nil);
    });
}
- (void)invalidate {}
- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    return nil;
}

// VGFrameSink
- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    _presentCallCount++;
    _capturedEnvelope = envelope;
    if (_capturedBuffer) {
        CVPixelBufferRelease(_capturedBuffer);
        _capturedBuffer = NULL;
    }
    if (envelope.payload.videoBuffer) {
        _capturedBuffer = (CVPixelBufferRef)envelope.payload.videoBuffer;
        CVPixelBufferRetain(_capturedBuffer);
    }
}

- (void)dealloc {
    if (_capturedBuffer) {
        CVPixelBufferRelease(_capturedBuffer);
        _capturedBuffer = NULL;
    }
}

@end

#pragma mark - VGParityP_MockSource (no-op VGSourceNode for V2 graph)

@interface VGParityP_MockSource : NSObject <VGSourceNode>
@end
@implementation VGParityP_MockSource
- (NSString *)nodeId    { return @"parity_test_source"; }
- (NSString *)nodeClass { return @"VGParityP_MockSource"; }
- (VGNodeRole)nodeRole  { return VGNodeRoleSource; }
- (NSArray<VGMediaPort *> *)declaredPorts {
    return @[ [VGMediaPort outputPort:@"video_out" mediaType:VGMediaTypeVideo] ];
}
- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ completion(nil); });
}
- (void)invalidate {}
- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats { return nil; }
// VGSourceNode
- (void)startProducing {}
- (void)stopProducing  {}
- (VGFrameResult *)pullFrame:(VGFrameRequest *)request { return nil; }
- (void)seekTo:(CMTime)time generation:(uint64_t)generation {}
@end

#pragma mark - VGParityP_MockFilter (deterministic XOR transform)

static const uint8_t kXorByte = 0xAA;

@interface VGParityP_MockFilter : NSObject <VGMetalFilterNode, VGTransformNode>
@property (nonatomic, assign) BOOL enabled;
@end

@implementation VGParityP_MockFilter

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _enabled = YES;
    return self;
}

// ─── VGMediaNode ─────────────────────────────────────────────────────────────
- (NSString *)nodeId   { return @"parity_test_filter"; }
- (NSString *)nodeType { return @"VGParityP_MockFilter"; }
- (VGNodeRole)nodeRole { return VGNodeRoleFilter; }
- (void)prepareWithCompletion:(void (^)(NSError * _Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ completion(nil); });
}
- (void)invalidate {}

// ─── VGMetalFilterNode ────────────────────────────────────────────────────────
- (BOOL)isExpensive         { return NO; }
- (float)estimatedGPUCostMs { return 1.0f; }

// ─── VGNode (for VGTransformNode conformance) ─────────────────────────────────
- (NSString *)nodeClass { return @"VGParityP_MockFilter"; }
- (NSArray<VGMediaPort *> *)declaredPorts {
    return @[
        [VGMediaPort inputPort:@"video_in"  mediaType:VGMediaTypeVideo required:YES],
        [VGMediaPort outputPort:@"video_out" mediaType:VGMediaTypeVideo],
    ];
}
- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ completion(nil); });
}
- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats { return nil; }

// ─── processEnvelope:device: (shared by VGMetalFilterNode and VGTransformNode) ─
// Creates a new CVPixelBuffer, XORs every byte with 0xAA.
// The scheduler owns the returned buffer (+1); it releases after presentEnvelope:.
- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                             device:(id<MTLDevice>)device {
    if (!self.enabled) return envelope;

    CVPixelBufferRef srcBuf = (CVPixelBufferRef)envelope.payload.videoBuffer;
    if (!srcBuf) return envelope;

    size_t width  = CVPixelBufferGetWidth(srcBuf);
    size_t height = CVPixelBufferGetHeight(srcBuf);
    OSType format = CVPixelBufferGetPixelFormatType(srcBuf);

    NSDictionary *attrs = @{ (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    CVPixelBufferRef dstBuf = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          width, height, format,
                                          (__bridge CFDictionaryRef)attrs,
                                          &dstBuf);
    if (status != kCVReturnSuccess || !dstBuf) return envelope;

    CVPixelBufferLockBaseAddress(srcBuf, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dstBuf, 0);

    size_t srcBytes = CVPixelBufferGetDataSize(srcBuf);
    uint8_t *src = (uint8_t *)CVPixelBufferGetBaseAddress(srcBuf);
    uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(dstBuf);
    for (size_t i = 0; i < srcBytes; i++) {
        dst[i] = src[i] ^ kXorByte;
    }

    CVPixelBufferUnlockBaseAddress(dstBuf, 0);
    CVPixelBufferUnlockBaseAddress(srcBuf, kCVPixelBufferLock_ReadOnly);

    VGFrameEnvelope result = envelope;
    result.payload.videoBuffer = dstBuf;
    // Caller (scheduler) owns +1 on dstBuf via CF ownership rules.
    // VGMetalFilterNode contract: caller releases filter-produced buffer.
    return result;
}

@end

#pragma mark - VGSchedulerParityTest

@interface VGSchedulerParityTest : XCTestCase
@end

@implementation VGSchedulerParityTest {
    id<MTLDevice>               _device;
    CVPixelBufferRef            _testBuffer;

    // V1
    VanguardGraphScheduler     *_v1;
    VGParityP_SinkSpyV1        *_v1Spy;

    // V2
    VGGraphSchedulerV2         *_v2;
    VGParityP_SinkSpyV2        *_v2Spy;
    VGGraphExecutionContext     *_context;

    // Mock nodes
    VGParityP_MockFilter       *_mockFilter;
    VGParityP_MockSource       *_mockSource;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Create an opaque 16x16 BGRA CVPixelBuffer filled with the given byte value.
- (CVPixelBufferRef)_makeTestBufferFilledWith:(uint8_t)value CF_RETURNS_RETAINED {
    NSDictionary *attrs = @{ (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    CVPixelBufferRef buf = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          16, 16,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)attrs,
                                          &buf);
    if (status != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(buf, 0);
    memset(CVPixelBufferGetBaseAddress(buf), value, CVPixelBufferGetDataSize(buf));
    CVPixelBufferUnlockBaseAddress(buf, 0);
    return buf;
}

/// Build a minimal VGGraphExecutionContext for V2 scheduler construction.
/// Nodes dictionary must include source, filter (wrapped), and sink.
- (VGGraphExecutionContext *)_buildContextWithNodes:(NSDictionary<NSString *, id<VGNode>> *)nodes
                                      filterNodeIds:(NSArray<NSString *> *)filterIds {
    // Node descriptors
    VGGraphNodeDescriptor *srcDesc =
        [[VGGraphNodeDescriptor alloc] initWithNodeId:@"parity_test_source"
                                            nodeClass:@"VGParityP_MockSource"
                                             nodeRole:VGNodeRoleSource
                                           parameters:@{}
                                                ports:@[ [VGMediaPort outputPort:@"video_out"
                                                                       mediaType:VGMediaTypeVideo] ]];
    VGGraphNodeDescriptor *sinkDesc =
        [[VGGraphNodeDescriptor alloc] initWithNodeId:@"parity_test_sink_v2"
                                            nodeClass:@"VGParityP_SinkSpyV2"
                                             nodeRole:VGNodeRoleSink
                                           parameters:@{}
                                                ports:@[ [VGMediaPort inputPort:@"video_in"
                                                                      mediaType:VGMediaTypeVideo
                                                                       required:YES] ]];

    NSMutableArray<VGGraphNodeDescriptor *> *nodeDescs =
        [NSMutableArray arrayWithObjects:srcDesc, sinkDesc, nil];
    for (NSString *fid in filterIds) {
        VGGraphNodeDescriptor *fd =
            [[VGGraphNodeDescriptor alloc] initWithNodeId:fid
                                                nodeClass:@"VGParityP_MockFilter"
                                                 nodeRole:VGNodeRoleFilter
                                               parameters:@{}
                                                    ports:@[
                                                        [VGMediaPort inputPort:@"video_in"
                                                                    mediaType:VGMediaTypeVideo
                                                                     required:YES],
                                                        [VGMediaPort outputPort:@"video_out"
                                                                     mediaType:VGMediaTypeVideo],
                                                    ]];
        [nodeDescs addObject:fd];
    }

    VGGraphDescriptor *desc =
        [[VGGraphDescriptor alloc] initWithGraphId:@"parity_test_graph"
                                             nodes:nodeDescs
                                       connections:@[]
                                       clockPolicy:VGClockPolicyPush
                                      audioSidecar:nil];

    // Topological order: source → filters → sink
    NSMutableArray<NSString *> *topoOrder = [NSMutableArray array];
    [topoOrder addObject:@"parity_test_source"];
    [topoOrder addObjectsFromArray:filterIds];
    [topoOrder addObject:@"parity_test_sink_v2"];

    VGExecutionPlan *plan =
        [[VGExecutionPlan alloc] initWithTopologicalOrder:topoOrder
                                            parallelGroups:@[]];

    VGGraphExecutionContext *ctx =
        [[VGGraphExecutionContext alloc] initWithDescriptor:desc
                                                       plan:plan
                                                      nodes:nodes
                                                      clock:nil
                                          resourceAllocator:[VGResourceAllocator sharedInstance]];
    return ctx;
}

/// Wire V1 spy to scheduler.sink via unsafe cast (VGP45SinkSpy pattern).
- (void)_wireV1Spy {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincompatible-pointer-types"
    _v1.sink = (VanguardMetalRenderer *)_v1Spy;
#pragma clang diagnostic pop
}

// ─── setUp / tearDown ─────────────────────────────────────────────────────────

- (void)setUp {
    [super setUp];

    // Simulator guard — Metal required for V2 context construction.
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        NSLog(@"[VGSchedulerParityTest] Skipping — no Metal device (simulator)");
        return;
    }

    _testBuffer = [self _makeTestBufferFilledWith:0x55];
    XCTAssertTrue(_testBuffer != NULL, @"Test buffer must be created");

    _mockFilter = [[VGParityP_MockFilter alloc] init];
    _mockSource = [[VGParityP_MockSource alloc] init];
}

- (void)tearDown {
    // V1 teardown
    _v1.sink = nil;
    [_v1 invalidate];
    _v1 = nil;
    _v1Spy = nil;  // dealloc releases captured buffer

    // V2 teardown
    [_v2 invalidate];
    _v2 = nil;
    _v2Spy = nil;  // dealloc releases captured buffer
    _context = nil;

    // Input buffer
    if (_testBuffer) { CVPixelBufferRelease(_testBuffer); _testBuffer = NULL; }

    _mockFilter = nil;
    _mockSource = nil;

    [super tearDown];
}

/// Configure V1 and V2 schedulers with the given filter chain (nil = passthrough).
- (void)_setupSchedulersWithFilter:(VGParityP_MockFilter * _Nullable)filter {
    // ── V1 ────────────────────────────────────────────────────────────────────
    _v1 = [[VanguardGraphScheduler alloc] init];
    _v1Spy = [[VGParityP_SinkSpyV1 alloc] init];
    [self _wireV1Spy];
    if (filter) {
        [_v1 setFilterChain:@[filter]];
    }
    [_v1 startWithClock:nil device:_device];

    // ── V2 ────────────────────────────────────────────────────────────────────
    _v2Spy = [[VGParityP_SinkSpyV2 alloc] init];

    NSMutableDictionary<NSString *, id<VGNode>> *nodes = [NSMutableDictionary dictionary];
    nodes[@"parity_test_source"]  = _mockSource;
    nodes[@"parity_test_sink_v2"] = _v2Spy;

    NSMutableArray<NSString *> *filterIds = [NSMutableArray array];
    if (filter) {
        VGLegacyFilterAdapter *adapter =
            [[VGLegacyFilterAdapter alloc] initWithFilter:filter];
        nodes[@"parity_test_filter"] = adapter;
        [filterIds addObject:@"parity_test_filter"];
    }

    _context = [self _buildContextWithNodes:nodes filterNodeIds:filterIds];

    VGExecutionPlan *plan = _context.plan;
    _v2 = [[VGGraphSchedulerV2 alloc] initWithPlan:plan nodes:nodes context:_context];
    _v2.sink = _v2Spy;
    [_v2 startWithClock:nil];  // required: V2 gates on _running
}

/// Build a test VGFrameEnvelope from _testBuffer.
- (VGFrameEnvelope)_buildEnvelope {
    VGFrameEnvelope env;
    memset(&env, 0, sizeof(VGFrameEnvelope));
    env.payload.videoBuffer = _testBuffer;
    env.pts                 = CMTimeMakeWithSeconds(1.0, 600);
    env.generation          = 1;
    env.mediaType           = VGMediaTypeVideo;
    env.metadata            = NULL;
    return env;
}

/// Compare two CVPixelBuffers byte-for-byte.
/// Returns the maximum absolute per-byte delta (0 = identical).
- (int)_maxDeltaBetween:(CVPixelBufferRef)a and:(CVPixelBufferRef)b {
    if (!a || !b) return -1;
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    size_t sizeA = CVPixelBufferGetDataSize(a);
    size_t sizeB = CVPixelBufferGetDataSize(b);
    int maxDelta = 0;
    if (sizeA == sizeB) {
        const uint8_t *pa = (const uint8_t *)CVPixelBufferGetBaseAddress(a);
        const uint8_t *pb = (const uint8_t *)CVPixelBufferGetBaseAddress(b);
        for (size_t i = 0; i < sizeA; i++) {
            int d = abs((int)pa[i] - (int)pb[i]);
            if (d > maxDelta) maxDelta = d;
        }
    } else {
        maxDelta = -2; // size mismatch
    }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    return maxDelta;
}

// ─── Test 1: Passthrough (no filters) ────────────────────────────────────────

- (void)testParityPassthrough {
    if (!_device) return;
    [self _setupSchedulersWithFilter:nil];

    VGFrameEnvelope env = [self _buildEnvelope];
    [_v1 didReceiveRawFrame:env];
    [_v2 didReceiveRawFrame:env];

    XCTAssertEqual(_v1Spy.presentCallCount, (NSUInteger)1,
                   @"V1 must deliver exactly one frame");
    XCTAssertEqual(_v2Spy.presentCallCount, (NSUInteger)1,
                   @"V2 must deliver exactly one frame");

    // Passthrough: both schedulers forward the source buffer unchanged.
    // Output must be identical to input and to each other.
    int delta = [self _maxDeltaBetween:_v1Spy.capturedBuffer
                                   and:_v2Spy.capturedBuffer];
    XCTAssertEqual(delta, 0,
                   @"V1 and V2 passthrough output must be identical (delta=%d)", delta);
}

// ─── Test 2: Deterministic filter (XOR 0xAA transform) ───────────────────────

- (void)testParityWithMockFilter {
    if (!_device) return;
    [self _setupSchedulersWithFilter:_mockFilter];

    VGFrameEnvelope env = [self _buildEnvelope];
    [_v1 didReceiveRawFrame:env];
    [_v2 didReceiveRawFrame:env];

    XCTAssertEqual(_v1Spy.presentCallCount, (NSUInteger)1,
                   @"V1 must deliver exactly one frame after filter");
    XCTAssertEqual(_v2Spy.presentCallCount, (NSUInteger)1,
                   @"V2 must deliver exactly one frame after filter");

    // Both schedulers execute the same mock filter.
    // Outputs must be identical (same deterministic XOR).
    int delta = [self _maxDeltaBetween:_v1Spy.capturedBuffer
                                   and:_v2Spy.capturedBuffer];
    XCTAssertEqual(delta, 0,
                   @"V1 and V2 filter output must be identical (delta=%d)", delta);
}

// ─── Test 3: Envelope fields preserved ───────────────────────────────────────

- (void)testParityPreservesEnvelopeFields {
    if (!_device) return;
    [self _setupSchedulersWithFilter:nil];

    CMTime expectedPts  = CMTimeMakeWithSeconds(2.5, 600);
    uint64_t expectedGen = 99;

    VGFrameEnvelope env;
    memset(&env, 0, sizeof(VGFrameEnvelope));
    env.payload.videoBuffer = _testBuffer;
    env.pts                 = expectedPts;
    env.generation          = expectedGen;
    env.mediaType           = VGMediaTypeVideo;
    env.metadata            = NULL;

    [_v1 didReceiveRawFrame:env];
    [_v2 didReceiveRawFrame:env];

    XCTAssertTrue(CMTimeCompare(_v1Spy.capturedEnvelope.pts, expectedPts) == 0,
                  @"V1 must preserve pts");
    XCTAssertTrue(CMTimeCompare(_v2Spy.capturedEnvelope.pts, expectedPts) == 0,
                  @"V2 must preserve pts");
    XCTAssertEqual(_v1Spy.capturedEnvelope.generation, expectedGen,
                   @"V1 must preserve generation");
    XCTAssertEqual(_v2Spy.capturedEnvelope.generation, expectedGen,
                   @"V2 must preserve generation");
    XCTAssertEqual(_v1Spy.capturedEnvelope.mediaType, VGMediaTypeVideo,
                   @"V1 must preserve mediaType");
    XCTAssertEqual(_v2Spy.capturedEnvelope.mediaType, VGMediaTypeVideo,
                   @"V2 must preserve mediaType");
}

@end
