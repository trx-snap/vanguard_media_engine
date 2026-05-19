// VGCameraGraphFactoryTest.m
// vanguard_media_engine — Phase 6A-1
//
// Unit tests for VGCameraGraphFactory.
//
// Mock prefix: VGMCF_ (VG Mock Camera Factory)

#import <XCTest/XCTest.h>
#import "VGCameraGraphFactory.h"
#import "VGFanOutSink.h"
#import "VGCameraSourceAdapter.h"
#import "VGRendererSinkAdapter.h"
#import "VanguardCameraMediaSource.h"
#import "VanguardMetalRenderer.h"

#import <UMF/VGGraphDescriptor.h>
#import <UMF/VGGraphConnection.h>
#import <UMF/VGExecutionPlan.h>
#import <UMF/VGNode.h>
#import <UMF/VGFrameSink.h>
#import <UMF/VGClockPolicy.h>
#import <UMF/VGSinkAdmissionPolicy.h>
#import <UMF/VGValidationError.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGMCF_MockCameraSource (NSObject cast to VanguardCameraMediaSource)
// ─────────────────────────────────────────────────────────────────────────────

@interface VGMCF_MockCameraSource : NSObject
@property (nonatomic) BOOL startCalled;
@property (nonatomic) BOOL stopCalled;
@end

@implementation VGMCF_MockCameraSource

- (void)start {
    _startCalled = YES;
}

- (void)stop {
    _stopCalled = YES;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGMCF_MockRenderer (NSObject cast to VanguardMetalRenderer)
// ─────────────────────────────────────────────────────────────────────────────

@interface VGMCF_MockRenderer : NSObject
@property (nonatomic) NSInteger presentCallCount;
@end

@implementation VGMCF_MockRenderer

- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    _presentCallCount++;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGMCF_MockFilter (Metal filter mock conforming to VGMetalFilterNode requirements)
// ─────────────────────────────────────────────────────────────────────────────

@interface VGMCF_MockFilter : NSObject
@property (nonatomic, copy) NSString *nodeId;
@property (nonatomic) BOOL enabled;
@end

@implementation VGMCF_MockFilter

- (instancetype)initWithNodeId:(NSString *)nodeId {
    self = [super init];
    if (self) {
        _nodeId = [nodeId copy];
        _enabled = YES;
    }
    return self;
}

- (NSString *)nodeType {
    return @"VGMCF_MockFilter";
}

- (float)estimatedGPUCostMs {
    return 1.0f;
}

- (void)prepareWithCompletion:(void (^)(NSError * _Nullable))completion {
    if (completion) completion(nil);
}

- (void)invalidate {}

- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope device:(id<MTLDevice>)device {
    return envelope;
}

- (NSString *)nodeClass {
    return @"VGMCF_MockFilter";
}

- (VGNodeRole)nodeRole {
    return VGNodeRoleFilter;
}

- (NSArray *)declaredPorts {
    return @[
        [VGMediaPort inputPort:@"video_in" mediaType:VGMediaTypeVideo required:YES],
        [VGMediaPort outputPort:@"video_out" mediaType:VGMediaTypeVideo]
    ];
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGCameraGraphFactoryTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCameraGraphFactoryTest : XCTestCase
@end

@implementation VGCameraGraphFactoryTest {
    VGMCF_MockCameraSource *_mockSource;
    VGMCF_MockRenderer     *_mockRenderer;
}

- (void)setUp {
    [super setUp];
    _mockSource = [[VGMCF_MockCameraSource alloc] init];
    _mockRenderer = [[VGMCF_MockRenderer alloc] init];
}

- (void)tearDown {
    _mockSource = nil;
    _mockRenderer = nil;
    [super tearDown];
}

// ─── Test cases ──────────────────────────────────────────────────────────────

- (void)testBuildSucceedsWithValidInputs {
    NSError *error = nil;
    NSDictionary *result = [VGCameraGraphFactory
        buildCameraGraphWithSource:(VanguardCameraMediaSource *)_mockSource
                       filterChain:nil
                          renderer:(VanguardMetalRenderer *)_mockRenderer
                             error:&error];

    XCTAssertNotNil(result, @"Build must succeed with valid inputs");
    XCTAssertNil(error);

    VGGraphDescriptor *desc = result[@"descriptor"];
    XCTAssertNotNil(desc);
    XCTAssertEqualObjects(desc.graphId, @"cameraGraph");
    XCTAssertEqual(desc.clockPolicy, VGClockPolicyPush);

    NSDictionary<NSString *, id<VGNode>> *nodes = result[@"nodes"];
    XCTAssertNotNil(nodes);
    XCTAssertTrue([nodes[@"camera_source"] isKindOfClass:[VGCameraSourceAdapter class]]);
    XCTAssertTrue([nodes[@"fan_out_sink"] isKindOfClass:[VGFanOutSink class]]);

    VGExecutionPlan *plan = result[@"plan"];
    XCTAssertNotNil(plan);
    XCTAssertEqual(plan.topologicalOrder.count, 2u);
    XCTAssertEqualObjects(plan.topologicalOrder.firstObject, @"camera_source");
    XCTAssertEqualObjects(plan.topologicalOrder.lastObject, @"fan_out_sink");
}

- (void)testSinkEdgeUsesDropLatest {
    NSError *error = nil;
    NSDictionary *result = [VGCameraGraphFactory
        buildCameraGraphWithSource:(VanguardCameraMediaSource *)_mockSource
                       filterChain:nil
                          renderer:(VanguardMetalRenderer *)_mockRenderer
                             error:&error];

    VGGraphDescriptor *desc = result[@"descriptor"];
    XCTAssertEqual(desc.connections.count, 1u);

    VGGraphConnection *conn = desc.connections.firstObject;
    XCTAssertEqualObjects(conn.sourceNodeId, @"camera_source");
    XCTAssertEqualObjects(conn.targetNodeId, @"fan_out_sink");
    XCTAssertEqual(conn.deliveryPolicy, VGEdgeDeliveryPolicySynchronous);

    VGSinkAdmissionPolicy *policy = conn.admissionPolicy;
    XCTAssertNotNil(policy);
    XCTAssertEqual(policy.type, VGSinkAdmissionPolicyDropLatest, @"Push camera graph must use dropLatest");
}

- (void)testWithFilterChain {
    VGMCF_MockFilter *filter = [[VGMCF_MockFilter alloc] initWithNodeId:@"beauty_filter"];
    NSError *error = nil;
    NSDictionary *result = [VGCameraGraphFactory
        buildCameraGraphWithSource:(VanguardCameraMediaSource *)_mockSource
                       filterChain:@[ filter ]
                          renderer:(VanguardMetalRenderer *)_mockRenderer
                             error:&error];

    XCTAssertNotNil(result);
    XCTAssertNil(error);

    VGGraphDescriptor *desc = result[@"descriptor"];
    XCTAssertEqual(desc.nodes.count, 3u);
    XCTAssertEqual(desc.connections.count, 2u);

    // Topological order
    VGExecutionPlan *plan = result[@"plan"];
    XCTAssertEqual(plan.topologicalOrder.count, 3u);
    XCTAssertEqualObjects(plan.topologicalOrder[0], @"camera_source");
    XCTAssertEqualObjects(plan.topologicalOrder[1], @"beauty_filter");
    XCTAssertEqualObjects(plan.topologicalOrder[2], @"fan_out_sink");

    // Connection 1: source -> filter
    VGGraphConnection *conn1 = desc.connections[0];
    XCTAssertEqualObjects(conn1.sourceNodeId, @"camera_source");
    XCTAssertEqualObjects(conn1.targetNodeId, @"beauty_filter");
    XCTAssertNil(conn1.admissionPolicy);

    // Connection 2: filter -> sink
    VGGraphConnection *conn2 = desc.connections[1];
    XCTAssertEqualObjects(conn2.sourceNodeId, @"beauty_filter");
    XCTAssertEqualObjects(conn2.targetNodeId, @"fan_out_sink");
    XCTAssertEqual(conn2.admissionPolicy.type, VGSinkAdmissionPolicyDropLatest);
}

- (void)testInvalidInputs {
    // 1. Nil source
    NSError *err1 = nil;
    NSDictionary *res1 = [VGCameraGraphFactory
        buildCameraGraphWithSource:nil
                       filterChain:nil
                          renderer:(VanguardMetalRenderer *)_mockRenderer
                             error:&err1];
    XCTAssertNil(res1);
    XCTAssertNotNil(err1);
    XCTAssertEqual(err1.code, 3);

    // 2. Nil renderer
    NSError *err2 = nil;
    NSDictionary *res2 = [VGCameraGraphFactory
        buildCameraGraphWithSource:(VanguardCameraMediaSource *)_mockSource
                       filterChain:nil
                          renderer:nil
                             error:&err2];
    XCTAssertNil(res2);
    XCTAssertNotNil(err2);
    XCTAssertEqual(err2.code, 4);
}

@end
