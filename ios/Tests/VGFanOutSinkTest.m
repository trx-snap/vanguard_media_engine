// VGFanOutSinkTest.m
// vanguard_media_engine — Phase 6A-1
//
// Unit tests for VGFanOutSink.
//
// Mock prefix: VGFOS_ (VGFanOutSink Test)

#import <XCTest/XCTest.h>
#import "VGFanOutSink.h"
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGMediaFormat.h>
#import <UMF/VGGraphExecutionContext.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGFOS_MockSink
// ─────────────────────────────────────────────────────────────────────────────

@interface VGFOS_MockSink : NSObject <VGFrameSink>
@property (nonatomic, copy) NSString *nodeId;
@property (nonatomic) NSInteger presentCallCount;
@property (nonatomic) VGFrameEnvelope lastEnvelope;
@property (nonatomic) BOOL prepareCalled;
@property (nonatomic) BOOL invalidateCalled;
@property (nonatomic, nullable) NSError *prepareErrorToReturn;
@end

@implementation VGFOS_MockSink

- (instancetype)initWithNodeId:(NSString *)nodeId {
    self = [super init];
    if (self) {
        _nodeId = [nodeId copy];
        _presentCallCount = 0;
        _prepareCalled = NO;
        _invalidateCalled = NO;
    }
    return self;
}

- (NSString *)nodeClass {
    return @"VGFOS_MockSink";
}

- (VGNodeRole)nodeRole {
    return VGNodeRoleSink;
}

- (NSArray<VGMediaPort *> *)declaredPorts {
    return @[ [VGMediaPort inputPort:@"video_in" mediaType:VGMediaTypeVideo required:YES] ];
}

- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    _prepareCalled = YES;
    completion(_prepareErrorToReturn);
}

- (void)invalidate {
    _invalidateCalled = YES;
}

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary *)inputFormats {
    return nil;
}

- (void)presentEnvelope:(VGFrameEnvelope)envelope {
    _presentCallCount++;
    _lastEnvelope = envelope;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGFanOutSinkTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGFanOutSinkTest : XCTestCase
@end

@implementation VGFanOutSinkTest

// ─── Test cases ──────────────────────────────────────────────────────────────

- (void)testInitializationValidation {
    // 1. Nil sinks array should return nil.
    VGFanOutSink *sink1 = [[VGFanOutSink alloc] initWithNodeId:@"fan" sinks:(NSArray * _Nonnull)nil];
    XCTAssertNil(sink1, @"Nil sinks array must fail initialization");

    // 2. Empty sinks array should return nil.
    VGFanOutSink *sink2 = [[VGFanOutSink alloc] initWithNodeId:@"fan" sinks:@[]];
    XCTAssertNil(sink2, @"Empty sinks array must fail initialization");

    // 3. Sinks array with nil or invalid elements should return nil.
    VGFanOutSink *sink3 = [[VGFanOutSink alloc] initWithNodeId:@"fan" sinks:@[ (id)[NSNull null] ]];
    XCTAssertNil(sink3, @"Invalid sink conformer must fail initialization");

    // 4. Custom nodeId validation.
    VGFanOutSink *sink4 = [[VGFanOutSink alloc] initWithNodeId:@"" sinks:@[ [[VGFOS_MockSink alloc] initWithNodeId:@"s1"] ]];
    XCTAssertNil(sink4, @"Empty nodeId must fail initialization");
}

- (void)testNodeIdentityAndPorts {
    VGFOS_MockSink *child = [[VGFOS_MockSink alloc] initWithNodeId:@"s1"];
    VGFanOutSink *fanOut = [[VGFanOutSink alloc] initWithSinks:@[ child ]];

    XCTAssertNotNil(fanOut);
    XCTAssertEqualObjects(fanOut.nodeId, @"fan_out_sink", @"Default nodeId should be fan_out_sink");
    XCTAssertEqualObjects(fanOut.nodeClass, @"VGFanOutSink");
    XCTAssertEqual(fanOut.nodeRole, VGNodeRoleSink);

    NSArray<VGMediaPort *> *ports = [fanOut declaredPorts];
    XCTAssertEqual(ports.count, 1u);
    XCTAssertEqualObjects(ports.firstObject.portId, @"video_in");
    XCTAssertEqual(ports.firstObject.mediaType, VGMediaTypeVideo);
    XCTAssertTrue(ports.firstObject.required);
}

- (void)testForwardToOneChild {
    VGFOS_MockSink *child = [[VGFOS_MockSink alloc] initWithNodeId:@"s1"];
    VGFanOutSink *fanOut = [[VGFanOutSink alloc] initWithNodeId:@"my_fan_out" sinks:@[ child ]];

    XCTAssertEqualObjects(fanOut.nodeId, @"my_fan_out");

    // Construct mock frame envelope
    CVPixelBufferRef mockBuffer = (CVPixelBufferRef)0xDEADBEEF;
    VGFrameEnvelope env;
    env.pts = CMTimeMake(100, 30);
    env.dts = CMTimeMake(90, 30);
    env.duration = CMTimeMake(1, 30);
    env.generation = 42;
    env.mediaType = VGMediaTypeVideo;
    env.payload.videoBuffer = mockBuffer;
    env.metadata = NULL;

    [fanOut presentEnvelope:env];

    XCTAssertEqual(child.presentCallCount, 1);
    XCTAssertEqual(child.lastEnvelope.pts.value, 100);
    XCTAssertEqual(child.lastEnvelope.generation, 42);
    XCTAssertEqual(child.lastEnvelope.payload.videoBuffer, mockBuffer);
}

- (void)testForwardToMultipleChildrenInOrder {
    VGFOS_MockSink *child1 = [[VGFOS_MockSink alloc] initWithNodeId:@"s1"];
    VGFOS_MockSink *child2 = [[VGFOS_MockSink alloc] initWithNodeId:@"s2"];
    VGFOS_MockSink *child3 = [[VGFOS_MockSink alloc] initWithNodeId:@"s3"];

    VGFanOutSink *fanOut = [[VGFanOutSink alloc] initWithSinks:@[ child1, child2, child3 ]];

    VGFrameEnvelope env;
    env.pts = CMTimeMake(200, 30);
    env.dts = CMTimeMake(200, 30);
    env.duration = CMTimeMake(1, 30);
    env.generation = 99;
    env.mediaType = VGMediaTypeVideo;
    env.payload.videoBuffer = (CVPixelBufferRef)0xBEEF;
    env.metadata = NULL;

    [fanOut presentEnvelope:env];

    XCTAssertEqual(child1.presentCallCount, 1);
    XCTAssertEqual(child2.presentCallCount, 1);
    XCTAssertEqual(child3.presentCallCount, 1);

    XCTAssertEqual(child1.lastEnvelope.pts.value, 200);
    XCTAssertEqual(child2.lastEnvelope.pts.value, 200);
    XCTAssertEqual(child3.lastEnvelope.pts.value, 200);
}

- (void)testLifecyclePropagation {
    VGFOS_MockSink *child1 = [[VGFOS_MockSink alloc] initWithNodeId:@"s1"];
    VGFOS_MockSink *child2 = [[VGFOS_MockSink alloc] initWithNodeId:@"s2"];
    VGFanOutSink *fanOut = [[VGFanOutSink alloc] initWithSinks:@[ child1, child2 ]];

    // Invalidate
    [fanOut invalidate];
    XCTAssertTrue(child1.invalidateCalled);
    XCTAssertTrue(child2.invalidateCalled);

    // Prepare
    XCTestExpectation *expectation = [self expectationWithDescription:@"prepareComplete"];
    [fanOut prepareWithContext:(VGGraphExecutionContext * _Nonnull)[NSNull null] completion:^(NSError * _Nullable error) {
        XCTAssertNil(error);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:1.0 handler:nil];
    XCTAssertTrue(child1.prepareCalled);
    XCTAssertTrue(child2.prepareCalled);
}

- (void)testLifecyclePropagationWithError {
    VGFOS_MockSink *child1 = [[VGFOS_MockSink alloc] initWithNodeId:@"s1"];
    VGFOS_MockSink *child2 = [[VGFOS_MockSink alloc] initWithNodeId:@"s2"];
    child2.prepareErrorToReturn = [NSError errorWithDomain:@"Test" code:42 userInfo:nil];

    VGFanOutSink *fanOut = [[VGFanOutSink alloc] initWithSinks:@[ child1, child2 ]];

    XCTestExpectation *expectation = [self expectationWithDescription:@"prepareCompleteWithError"];
    [fanOut prepareWithContext:(VGGraphExecutionContext * _Nonnull)[NSNull null] completion:^(NSError * _Nullable error) {
        XCTAssertNotNil(error, @"Should propagate child preparation error");
        XCTAssertEqual(error.code, 42);
        [expectation fulfill];
    }];

    [self waitForExpectationsWithTimeout:1.0 handler:nil];
}

@end
