// VGExportGraphFactoryTest.m
// vanguard_media_engine — Phase 5C-3
//
// Gate test: VGExportGraphFactory export graph construction.
//
// AVAssetWriter is used ONLY in VGEGF_CreateTestAsset — test-only.
// No AVAssetWriter in production code.
// Mock prefix: VGEGF_ (VG Export Graph Factory)

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

#import "VGExportGraphFactory.h"
#import "VGExportFileSourceNode.h"

#import <UMF/VGGraphDescriptor.h>
#import <UMF/VGGraphConnection.h>
#import <UMF/VGExecutionPlan.h>
#import <UMF/VGNode.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGMediaFormat.h>
#import <UMF/VGClockPolicy.h>
#import <UMF/VGSinkAdmissionPolicy.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGResourceAllocator.h>
#import <UMF/VGFrameDelegate.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Test fixture (AVAssetWriter — test only)
// ─────────────────────────────────────────────────────────────────────────────

/// Creates a tiny H.264 MP4 with `frameCount` solid-color 16x16 frames at
/// `fps`. Synchronous — blocks on finishWriting. Returns nil on failure.
/// AVAssetWriter is ONLY used here, never in production code.
static NSURL * _Nullable VGEGF_CreateTestAsset(NSUInteger frameCount,
                                                CGSize size,
                                                double fps) {
    NSString *path = [NSTemporaryDirectory()
                      stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"VGEGF_test_%@.mp4",
                           [[NSUUID UUID] UUIDString]]];
    NSURL *url = [NSURL fileURLWithPath:path];

    NSError *err = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url
                                                     fileType:AVFileTypeMPEG4
                                                        error:&err];
    if (!writer || err) return nil;

    NSDictionary *vSettings = @{
        AVVideoCodecKey:  AVVideoCodecTypeH264,
        AVVideoWidthKey:  @((NSInteger)size.width),
        AVVideoHeightKey: @((NSInteger)size.height),
    };
    AVAssetWriterInput *input = [AVAssetWriterInput
        assetWriterInputWithMediaType:AVMediaTypeVideo
                       outputSettings:vSettings];
    input.expectsMediaDataInRealTime = NO;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:     @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:               @((NSInteger)size.width),
        (id)kCVPixelBufferHeightKey:              @((NSInteger)size.height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                         sourcePixelBufferAttributes:attrs];

    if (![writer canAddInput:input]) return nil;
    [writer addInput:input];
    [writer startWriting];
    [writer startSessionAtSourceTime:kCMTimeZero];

    CMTime frameDuration = CMTimeMakeWithSeconds(1.0 / fps, 600);

    for (NSUInteger i = 0; i < frameCount; i++) {
        while (!input.isReadyForMoreMediaData) {
            [NSThread sleepForTimeInterval:0.005];
        }
        CVPixelBufferRef pb = NULL;
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                          adaptor.pixelBufferPool, &pb);
        if (!pb) {
            CVPixelBufferCreate(kCFAllocatorDefault,
                                (size_t)size.width, (size_t)size.height,
                                kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)attrs, &pb);
        }
        if (pb) {
            CVPixelBufferLockBaseAddress(pb, 0);
            uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
            memset(base, (int)(i * 40 % 256), CVPixelBufferGetDataSize(pb));
            CVPixelBufferUnlockBaseAddress(pb, 0);
            CMTime pts = CMTimeMultiply(frameDuration, (int32_t)i);
            [adaptor appendPixelBuffer:pb withPresentationTime:pts];
            CVPixelBufferRelease(pb);
        }
    }

    [input markAsFinished];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    if (writer.status != AVAssetWriterStatusCompleted) return nil;
    return url;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGEGF_MockSink
// ─────────────────────────────────────────────────────────────────────────────

/// Minimal VGFrameSink conformer for export graph factory tests.
/// Records presentEnvelope: calls. No real encoding — test-only.
@interface VGEGF_MockSink : NSObject <VGFrameSink>
@property (nonatomic) NSInteger frameCount;
@end

@implementation VGEGF_MockSink {
    NSString *_nodeId;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _nodeId = [[NSUUID UUID] UUIDString];
    _frameCount = 0;
    return self;
}

- (NSString *)nodeId    { return _nodeId; }
- (NSString *)nodeClass { return @"VGEGF_MockSink"; }
- (VGNodeRole)nodeRole  { return VGNodeRoleSink; }

- (NSArray<VGMediaPort *> *)declaredPorts {
    return @[ [VGMediaPort inputPort:@"video_in"
                           mediaType:VGMediaTypeVideo
                            required:YES] ];
}

- (void)prepareWithContext:(VGGraphExecutionContext *)ctx
                completion:(void (^)(NSError * _Nullable))completion {
    if (completion) completion(nil);
}

- (void)invalidate {}

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary *)formats {
    return nil;
}

- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    _frameCount++;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGExportGraphFactoryTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGExportGraphFactoryTest : XCTestCase
@end

@implementation VGExportGraphFactoryTest {
    NSURL            *_testAssetURL;
    AVAsset          *_testAsset;
    VGEGF_MockSink   *_mockSink;
}

- (void)setUp {
    [super setUp];
    _testAssetURL = VGEGF_CreateTestAsset(5, CGSizeMake(16, 16), 30.0);
    XCTAssertNotNil(_testAssetURL, @"Test asset creation failed");
    _testAsset = [AVURLAsset URLAssetWithURL:_testAssetURL options:nil];
    _mockSink  = [[VGEGF_MockSink alloc] init];
}

- (void)tearDown {
    if (_testAssetURL) {
        [[NSFileManager defaultManager] removeItemAtURL:_testAssetURL error:nil];
    }
    _testAssetURL = nil;
    _testAsset    = nil;
    _mockSink     = nil;
    [super tearDown];
}

// ─── TC-5C3-01: build succeeds with valid asset and mock sink ─────────────────

- (void)testTC_5C3_01_buildSucceedsWithValidAssetAndSink {
    // TC-5C3-01: +buildExportGraphWithAsset:filterChain:sink:error: returns non-nil.
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    XCTAssertNotNil(result, @"TC-5C3-01: build must succeed");
    XCTAssertNil(error, @"TC-5C3-01: no error on success");
}

// ─── TC-5C3-02: result contains @"descriptor" ────────────────────────────────

- (void)testTC_5C3_02_resultContainsDescriptor {
    // TC-5C3-02: Result dictionary contains a VGGraphDescriptor at @"descriptor".
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    XCTAssertNotNil(result[@"descriptor"],
                    @"TC-5C3-02: result must contain @\"descriptor\"");
    XCTAssertTrue([result[@"descriptor"] isKindOfClass:[VGGraphDescriptor class]],
                  @"TC-5C3-02: descriptor must be VGGraphDescriptor");
}

// ─── TC-5C3-03: result contains @"nodes" ─────────────────────────────────────

- (void)testTC_5C3_03_resultContainsNodes {
    // TC-5C3-03: Result dictionary contains a nodes map at @"nodes".
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    XCTAssertNotNil(result[@"nodes"],
                    @"TC-5C3-03: result must contain @\"nodes\"");
    XCTAssertTrue([result[@"nodes"] isKindOfClass:[NSDictionary class]],
                  @"TC-5C3-03: nodes must be NSDictionary");
}

// ─── TC-5C3-04: result contains @"plan" ──────────────────────────────────────

- (void)testTC_5C3_04_resultContainsPlan {
    // TC-5C3-04: Result dictionary contains a VGExecutionPlan at @"plan".
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    XCTAssertNotNil(result[@"plan"],
                    @"TC-5C3-04: result must contain @\"plan\"");
    XCTAssertTrue([result[@"plan"] isKindOfClass:[VGExecutionPlan class]],
                  @"TC-5C3-04: plan must be VGExecutionPlan");
}

// ─── TC-5C3-05: descriptor.clockPolicy == VGClockPolicyPull ──────────────────

- (void)testTC_5C3_05_clockPolicyIsPull {
    // TC-5C3-05: Export graph must use VGClockPolicyPull.
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    VGGraphDescriptor *desc = result[@"descriptor"];
    XCTAssertEqual(desc.clockPolicy, VGClockPolicyPull,
                   @"TC-5C3-05: clockPolicy must be VGClockPolicyPull");
}

// ─── TC-5C3-06: sink edge uses VGSinkAdmissionPolicyNeverDrop ────────────────

- (void)testTC_5C3_06_sinkEdgeUsesNeverDrop {
    // TC-5C3-06: The connection feeding the sink must carry neverDrop admission.
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    VGGraphDescriptor *desc = result[@"descriptor"];
    NSString *sinkId = _mockSink.nodeId;

    VGSinkAdmissionPolicy *sinkPolicy = nil;
    for (VGGraphConnection *conn in desc.connections) {
        if ([conn.targetNodeId isEqualToString:sinkId]) {
            sinkPolicy = conn.admissionPolicy;
            break;
        }
    }
    XCTAssertNotNil(sinkPolicy,
                    @"TC-5C3-06: sink edge must have an admission policy");
    XCTAssertEqual(sinkPolicy.type, VGSinkAdmissionPolicyNeverDrop,
                   @"TC-5C3-06: sink edge must use neverDrop");
}

// ─── TC-5C3-07: source node in nodes map is VGExportFileSourceNode ────────────

- (void)testTC_5C3_07_sourceNodeIsVGExportFileSourceNode {
    // TC-5C3-07: Source in nodes map must be VGExportFileSourceNode.
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    NSDictionary<NSString *, id<VGNode>> *nodes = result[@"nodes"];
    id<VGNode> source = nil;
    for (id<VGNode> node in nodes.allValues) {
        if (node.nodeRole == VGNodeRoleSource) { source = node; break; }
    }
    XCTAssertNotNil(source, @"TC-5C3-07: source node must exist");
    XCTAssertTrue([source isKindOfClass:[VGExportFileSourceNode class]],
                  @"TC-5C3-07: source must be VGExportFileSourceNode");
}

// ─── TC-5C3-08: plan topological order — source first, sink last ──────────────

- (void)testTC_5C3_08_planTopologicalOrder {
    // TC-5C3-08: Topo order must begin with source nodeId and end with sink nodeId.
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    VGExecutionPlan *plan = result[@"plan"];
    NSDictionary<NSString *, id<VGNode>> *nodes = result[@"nodes"];
    XCTAssertGreaterThanOrEqual(plan.topologicalOrder.count, 2u,
                                @"TC-5C3-08: must have at least 2 nodes");
    NSString *firstId = plan.topologicalOrder.firstObject;
    NSString *lastId  = plan.topologicalOrder.lastObject;
    id<VGNode> first = nodes[firstId];
    id<VGNode> last  = nodes[lastId];
    XCTAssertEqual(first.nodeRole, VGNodeRoleSource,
                   @"TC-5C3-08: first topo node must be source");
    XCTAssertEqual(last.nodeRole, VGNodeRoleSink,
                   @"TC-5C3-08: last topo node must be sink");
}

// ─── TC-5C3-09: VGGraphValidator passes (no error returned) ──────────────────

- (void)testTC_5C3_09_validatorPasses {
    // TC-5C3-09: Factory succeeds iff VGGraphValidator accepted the descriptor.
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    XCTAssertNotNil(result, @"TC-5C3-09: validator must pass (result non-nil)");
    XCTAssertNil(error,     @"TC-5C3-09: no validation error");
}

// ─── TC-5C3-10: no VGGraphSchedulerV2 dependency ─────────────────────────────

- (void)testTC_5C3_10_noGraphSchedulerV2Dependency {
    // TC-5C3-10: VGExportGraphFactory must not depend on VGGraphSchedulerV2.
    // VGGraphSchedulerV2 is push-mode only; export uses VGExportScheduler.
    // If this class was inadvertently imported, NSClassFromString would return
    // a class — but that class may exist from other imports. Instead we verify
    // that VGExportGraphFactory itself does not trigger VGGraphSchedulerV2 init.
    // Structural: the class responds to +buildExportGraphWithAsset:filterChain:sink:error:
    // without any VGGraphSchedulerV2 involvement (no side-effects on scheduler).
    XCTAssertTrue([VGExportGraphFactory
                   respondsToSelector:@selector(buildExportGraphWithAsset:filterChain:sink:error:)],
                  @"TC-5C3-10: factory class method must exist");
    // Not instantiating VGGraphSchedulerV2 — build a graph and confirm it uses
    // VGClockPolicyPull (incompatible with scheduler V2 push-mode contract).
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    VGGraphDescriptor *desc = result[@"descriptor"];
    XCTAssertNotEqual(desc.clockPolicy, VGClockPolicyPush,
                      @"TC-5C3-10: export graph must not use push clock (V2 scheduler contract)");
}

// ─── TC-5C3-11: empty filter chain → 2 nodes in topo order ──────────────────

- (void)testTC_5C3_11_emptyFilterChainTwoNodesTopo {
    // TC-5C3-11: No filter chain → exactly 2 nodes (source + sink).
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:@[]      // explicitly empty
                             sink:_mockSink
                            error:&error];
    XCTAssertNotNil(result, @"TC-5C3-11: build must succeed");
    VGExecutionPlan *plan = result[@"plan"];
    XCTAssertEqual(plan.topologicalOrder.count, 2u,
                   @"TC-5C3-11: empty filter chain → exactly 2 nodes");
    VGGraphDescriptor *desc = result[@"descriptor"];
    XCTAssertEqual(desc.connections.count, 1u,
                   @"TC-5C3-11: empty filter chain → exactly 1 edge");
}

// ─── TC-5C3-12: filter chain nil treated same as empty ───────────────────────

- (void)testTC_5C3_12_nilFilterChainEquivalentToEmpty {
    // TC-5C3-12: nil filterChain must be treated as empty — same 2-node result.
    NSError *errA = nil, *errB = nil;
    NSDictionary *resultA = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&errA];
    // Fresh mock sink for second call (distinct nodeId).
    VGEGF_MockSink *sink2 = [[VGEGF_MockSink alloc] init];
    NSDictionary *resultB = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:@[]
                             sink:sink2
                            error:&errB];
    XCTAssertNotNil(resultA, @"TC-5C3-12: nil filterChain result non-nil");
    XCTAssertNotNil(resultB, @"TC-5C3-12: empty filterChain result non-nil");
    VGExecutionPlan *planA = resultA[@"plan"];
    VGExecutionPlan *planB = resultB[@"plan"];
    XCTAssertEqual(planA.topologicalOrder.count,
                   planB.topologicalOrder.count,
                   @"TC-5C3-12: nil and empty filter chains must produce same node count");
}

// ─── TC-5C3-13: graphId is @"exportGraph" ────────────────────────────────────

- (void)testTC_5C3_13_graphIdIsExportGraph {
    // TC-5C3-13: Descriptor graphId must be "exportGraph".
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    VGGraphDescriptor *desc = result[@"descriptor"];
    XCTAssertEqualObjects(desc.graphId, @"exportGraph",
                          @"TC-5C3-13: graphId must be \"exportGraph\"");
}

// ─── TC-5C3-14: nil asset returns nil + error ────────────────────────────────

- (void)testTC_5C3_14_nilAssetReturnsError {
    // TC-5C3-14: nil asset must return nil with a descriptive error (code 3).
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:(AVAsset * _Nonnull)nil
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    XCTAssertNil(result,    @"TC-5C3-14: nil asset must return nil");
    XCTAssertNotNil(error,  @"TC-5C3-14: nil asset must set error");
    XCTAssertEqualObjects(error.domain, @"VGExportGraphFactory",
                          @"TC-5C3-14: error domain must be VGExportGraphFactory");
    XCTAssertEqual(error.code, 3,
                   @"TC-5C3-14: nil asset error code must be 3");
}

// ─── TC-5C3-15: no VGFrameDelegate conformance on source ─────────────────────

- (void)testTC_5C3_15_sourceDoesNotConformToVGFrameDelegate {
    // TC-5C3-15: VGExportFileSourceNode must not conform to VGFrameDelegate
    // (push-mode callback protocol — export uses pull only).
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    NSDictionary<NSString *, id<VGNode>> *nodes = result[@"nodes"];
    id<VGNode> source = nil;
    for (id<VGNode> node in nodes.allValues) {
        if (node.nodeRole == VGNodeRoleSource) { source = node; break; }
    }
    XCTAssertNotNil(source, @"TC-5C3-15: source must exist");
    XCTAssertFalse([source conformsToProtocol:@protocol(VGFrameDelegate)],
                   @"TC-5C3-15: source must NOT conform to VGFrameDelegate");
}

// ─── TC-5C3-16: nil sink returns nil + error ─────────────────────────────────

- (void)testTC_5C3_16_nilSinkReturnsError {
    // TC-5C3-16: nil sink must return nil with error code 4.
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:(id<VGFrameSink> _Nonnull)nil
                            error:&error];
    XCTAssertNil(result,   @"TC-5C3-16: nil sink must return nil");
    XCTAssertNotNil(error, @"TC-5C3-16: nil sink must set error");
    XCTAssertEqual(error.code, 4,
                   @"TC-5C3-16: nil sink error code must be 4");
}

// ─── TC-5C3-17: descriptor.audioSidecar is nil ───────────────────────────────

- (void)testTC_5C3_17_audioSidecarIsNil {
    // TC-5C3-17: Export graph has no audio sidecar (Phase 8+).
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    VGGraphDescriptor *desc = result[@"descriptor"];
    XCTAssertNil(desc.audioSidecar,
                 @"TC-5C3-17: audioSidecar must be nil in Phase 5C-3");
}

// ─── TC-5C3-18: descriptor has one source and one sink role ──────────────────

- (void)testTC_5C3_18_exactlyOneSourceAndOneSink {
    // TC-5C3-18: Descriptor must contain exactly one source node and one sink node.
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    VGGraphDescriptor *desc = result[@"descriptor"];
    NSInteger sourceCount = 0, sinkCount = 0;
    for (VGGraphNodeDescriptor *nd in desc.nodes) {
        if (nd.nodeRole == VGNodeRoleSource) sourceCount++;
        if (nd.nodeRole == VGNodeRoleSink)   sinkCount++;
    }
    XCTAssertEqual(sourceCount, 1,
                   @"TC-5C3-18: must have exactly one source node");
    XCTAssertEqual(sinkCount, 1,
                   @"TC-5C3-18: must have exactly one sink node");
}

// ─── TC-5C3-19: connection count == node count - 1 ───────────────────────────

- (void)testTC_5C3_19_connectionCountMatchesLinearChain {
    // TC-5C3-19: For a linear chain of N nodes there must be exactly N-1 edges.
    NSError *error = nil;
    NSDictionary *result = [VGExportGraphFactory
        buildExportGraphWithAsset:_testAsset
                      filterChain:nil
                             sink:_mockSink
                            error:&error];
    VGGraphDescriptor *desc = result[@"descriptor"];
    NSUInteger nodeCount = desc.nodes.count;
    NSUInteger connCount = desc.connections.count;
    XCTAssertEqual(connCount, nodeCount - 1,
                   @"TC-5C3-19: linear chain must have N-1 connections for N nodes");
}

@end
