// VGCameraFilterChainTest.m
// vanguard_media_engine — Phase 6A-3C-1
//
// Unit tests for VGCameraGraphSession and VGCameraGraphFactory filter-chain adapter integration.
//
// Mock prefix: VGCFC_ (VG Camera Filter Chain Mock)

#import <XCTest/XCTest.h>
#import "VGCameraGraphSession.h"
#import "VanguardCameraMediaSource.h"
#import "VanguardMetalRenderer.h"
#import <UMF/VGMetalFilterNode.h>
#import <UMF/VGFrameDelegate.h>
#import <UMF/VGMediaPort.h>
#import <UMF/VGMediaFormat.h>
#import <UMF/VGGraphExecutionContext.h>
#import <UMF/VGFrameEnvelope.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGCFC_MockCameraSource
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCFC_MockCameraSource : NSObject
@property (nonatomic) BOOL startCalled;
@property (nonatomic) BOOL stopCalled;
@property (nonatomic) NSInteger startCallCount;
@property (nonatomic) NSInteger stopCallCount;
@end

@implementation VGCFC_MockCameraSource

- (void)start {
    _startCalled = YES;
    _startCallCount++;
}

- (void)stop {
    _stopCalled = YES;
    _stopCallCount++;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGCFC_MockRenderer
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCFC_MockRenderer : NSObject
@property (nonatomic, weak, nullable) id<VGFrameDelegate> frameDelegate;
@end

@implementation VGCFC_MockRenderer
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGCFC_MockLUTFilter (Conforms to VGMetalFilterNode)
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCFC_MockLUTFilter : NSObject <VGMetalFilterNode>
@property (nonatomic, copy, readonly) NSString *nodeId;
@property (nonatomic, copy, readonly) NSString *nodeType;
@property (nonatomic, copy, readonly) NSString *filterName;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, readonly) float estimatedGPUCostMs;
@property (nonatomic, readonly) BOOL isExpensive;
@property (nonatomic, readonly) VGNodeRole nodeRole;
@end

@implementation VGCFC_MockLUTFilter

- (instancetype)init {
    self = [super init];
    if (self) {
        _nodeId = @"mock_lut_filter";
        _nodeType = @"VGLUTFilterNode";
        _filterName = @"MockLUT";
        _enabled = YES;
    }
    return self;
}

- (float)estimatedGPUCostMs {
    return 2.0f;
}

- (BOOL)isExpensive {
    return NO;
}

- (VGNodeRole)nodeRole {
    return VGNodeRoleFilter;
}

- (void)prepareWithCompletion:(void (^)(NSError * _Nullable))completion {
    if (completion) {
        completion(nil);
    }
}

- (void)invalidate {
    // no-op
}

- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope device:(id<MTLDevice>)device {
    return envelope;
}

- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    return nil;
}

- (NSArray *)declaredPorts {
    return @[
        [VGMediaPort inputPort:@"video_in" mediaType:VGMediaTypeVideo required:YES],
        [VGMediaPort outputPort:@"video_out" mediaType:VGMediaTypeVideo]
    ];
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGCFC_MockBadFilter
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCFC_MockBadFilter : NSObject
@end

@implementation VGCFC_MockBadFilter
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGCameraFilterChainTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCameraFilterChainTest : XCTestCase
@end

@implementation VGCameraFilterChainTest

- (void)testSingleLUTFilterHotSwap {
    VGCFC_MockCameraSource *mockSource = [[VGCFC_MockCameraSource alloc] init];
    VGCFC_MockRenderer *mockRenderer = [[VGCFC_MockRenderer alloc] init];
    
    NSError *error = nil;
    VGCameraGraphSession *session = [[VGCameraGraphSession alloc]
        initWithSource:(VanguardCameraMediaSource *)mockSource
              renderer:(VanguardMetalRenderer *)mockRenderer
                  error:&error];
    
    XCTAssertNotNil(session, @"Session creation must succeed");
    XCTAssertNil(error);
    
    id<VGFrameDelegate> initialDelegate = mockRenderer.frameDelegate;
    XCTAssertNotNil(initialDelegate, @"Initial frameDelegate must not be nil");
    XCTAssertTrue(mockSource.startCalled);
    XCTAssertEqual(mockSource.startCallCount, 1);
    
    // Reset flags to verify that hot-swap doesn't stop the source
    mockSource.startCalled = NO;
    mockSource.stopCalled = NO;
    mockSource.startCallCount = 0;
    mockSource.stopCallCount = 0;
    
    VGCFC_MockLUTFilter *mockLUT = [[VGCFC_MockLUTFilter alloc] init];
    [session setCameraFilterChain:@[mockLUT]];
    
    id<VGFrameDelegate> secondDelegate = mockRenderer.frameDelegate;
    XCTAssertNotNil(secondDelegate, @"Second frameDelegate must exist after hot-swap");
    XCTAssertNotEqual(initialDelegate, secondDelegate, @"Hot-swap must create a new scheduler/delegate");
    
    // Hot-swap must keep the source running
    XCTAssertFalse(mockSource.stopCalled, @"Source must not be stopped during hot-swap");
    XCTAssertEqual(mockSource.stopCallCount, 0);
    
    [session invalidate];
    XCTAssertNil(mockRenderer.frameDelegate, @"Delegate must be cleared after invalidation");
    XCTAssertTrue(mockSource.stopCalled, @"Source must be stopped on invalidation");
    XCTAssertEqual(mockSource.stopCallCount, 1);
}

- (void)testEmptyFilterChainAfterLUTFilter {
    VGCFC_MockCameraSource *mockSource = [[VGCFC_MockCameraSource alloc] init];
    VGCFC_MockRenderer *mockRenderer = [[VGCFC_MockRenderer alloc] init];
    
    NSError *error = nil;
    VGCameraGraphSession *session = [[VGCameraGraphSession alloc]
        initWithSource:(VanguardCameraMediaSource *)mockSource
              renderer:(VanguardMetalRenderer *)mockRenderer
                  error:&error];
    
    XCTAssertNotNil(session);
    id<VGFrameDelegate> initialDelegate = mockRenderer.frameDelegate;
    XCTAssertNotNil(initialDelegate);
    
    VGCFC_MockLUTFilter *mockLUT = [[VGCFC_MockLUTFilter alloc] init];
    [session setCameraFilterChain:@[mockLUT]];
    
    id<VGFrameDelegate> secondDelegate = mockRenderer.frameDelegate;
    XCTAssertNotNil(secondDelegate);
    XCTAssertNotEqual(initialDelegate, secondDelegate);
    
    mockSource.stopCalled = NO;
    mockSource.stopCallCount = 0;
    
    [session setCameraFilterChain:@[]];
    id<VGFrameDelegate> thirdDelegate = mockRenderer.frameDelegate;
    XCTAssertNotNil(thirdDelegate);
    XCTAssertNotEqual(secondDelegate, thirdDelegate);
    XCTAssertNotEqual(initialDelegate, thirdDelegate);
    
    XCTAssertFalse(mockSource.stopCalled, @"Source must not be stopped during empty swap");
    XCTAssertEqual(mockSource.stopCallCount, 0);
    
    [session invalidate];
}

- (void)testNilFilterChainAfterLUTFilter {
    VGCFC_MockCameraSource *mockSource = [[VGCFC_MockCameraSource alloc] init];
    VGCFC_MockRenderer *mockRenderer = [[VGCFC_MockRenderer alloc] init];
    
    NSError *error = nil;
    VGCameraGraphSession *session = [[VGCameraGraphSession alloc]
        initWithSource:(VanguardCameraMediaSource *)mockSource
              renderer:(VanguardMetalRenderer *)mockRenderer
                  error:&error];
    
    XCTAssertNotNil(session);
    id<VGFrameDelegate> initialDelegate = mockRenderer.frameDelegate;
    
    VGCFC_MockLUTFilter *mockLUT = [[VGCFC_MockLUTFilter alloc] init];
    [session setCameraFilterChain:@[mockLUT]];
    id<VGFrameDelegate> secondDelegate = mockRenderer.frameDelegate;
    XCTAssertNotEqual(initialDelegate, secondDelegate);
    
    mockSource.stopCalled = NO;
    mockSource.stopCallCount = 0;
    
    [session setCameraFilterChain:nil];
    id<VGFrameDelegate> thirdDelegate = mockRenderer.frameDelegate;
    XCTAssertNotNil(thirdDelegate);
    XCTAssertNotEqual(secondDelegate, thirdDelegate);
    XCTAssertFalse(mockSource.stopCalled, @"Source must not be stopped during nil swap");
    XCTAssertEqual(mockSource.stopCallCount, 0);
    
    [session invalidate];
}

- (void)testBadFilterObjectSkipped {
    VGCFC_MockCameraSource *mockSource = [[VGCFC_MockCameraSource alloc] init];
    VGCFC_MockRenderer *mockRenderer = [[VGCFC_MockRenderer alloc] init];
    
    NSError *error = nil;
    VGCameraGraphSession *session = [[VGCameraGraphSession alloc]
        initWithSource:(VanguardCameraMediaSource *)mockSource
              renderer:(VanguardMetalRenderer *)mockRenderer
                  error:&error];
    
    XCTAssertNotNil(session);
    id<VGFrameDelegate> initialDelegate = mockRenderer.frameDelegate;
    
    VGCFC_MockBadFilter *badFilter = [[VGCFC_MockBadFilter alloc] init];
    
    NSArray *badFilterChain = @[badFilter];
    XCTAssertNoThrow([session setCameraFilterChain:badFilterChain], @"Skipping non-conforming object must not throw/crash");
    
    id<VGFrameDelegate> secondDelegate = mockRenderer.frameDelegate;
    XCTAssertNotNil(secondDelegate);
    XCTAssertNotEqual(initialDelegate, secondDelegate, @"Dynamic swap to passthrough must succeed");
    
    NSDictionary *nodes = [session valueForKey:@"_nodes"];
    XCTAssertNotNil(nodes);
    XCTAssertNotNil(nodes[@"camera_source"]);
    XCTAssertNotNil(nodes[@"fan_out_sink"]);
    XCTAssertEqual(nodes.count, 2u, @"Bad filter must have been skipped, resulting in standard passthrough graph");
    
    [session invalidate];
}

- (void)testMixedFilterChainWithBadObjectSkipped {
    VGCFC_MockCameraSource *mockSource = [[VGCFC_MockCameraSource alloc] init];
    VGCFC_MockRenderer *mockRenderer = [[VGCFC_MockRenderer alloc] init];
    
    NSError *error = nil;
    VGCameraGraphSession *session = [[VGCameraGraphSession alloc]
        initWithSource:(VanguardCameraMediaSource *)mockSource
              renderer:(VanguardMetalRenderer *)mockRenderer
                  error:&error];
    
    XCTAssertNotNil(session);
    
    VGCFC_MockLUTFilter *mockLUT = [[VGCFC_MockLUTFilter alloc] init];
    VGCFC_MockBadFilter *badFilter = [[VGCFC_MockBadFilter alloc] init];
    
    NSArray *mixedFilterChain = @[mockLUT, badFilter];
    XCTAssertNoThrow([session setCameraFilterChain:mixedFilterChain], @"Skipping non-conforming object in list must not throw/crash");
    
    id<VGFrameDelegate> secondDelegate = mockRenderer.frameDelegate;
    XCTAssertNotNil(secondDelegate);
    
    // Verify that bad filter was skipped but valid LUT filter remains in the nodes dictionary
    NSDictionary *nodes = [session valueForKey:@"_nodes"];
    XCTAssertNotNil(nodes);
    XCTAssertNotNil(nodes[@"camera_source"]);
    XCTAssertNotNil(nodes[@"mock_lut_filter"], @"LUT filter must be preserved in the graph");
    XCTAssertNotNil(nodes[@"fan_out_sink"]);
    XCTAssertEqual(nodes.count, 3u, @"Graph must have exactly 3 nodes because the bad filter was skipped");
    
    [session invalidate];
}

- (void)testFilterChainAfterInvalidateIsNoOp {
    VGCFC_MockCameraSource *mockSource = [[VGCFC_MockCameraSource alloc] init];
    VGCFC_MockRenderer *mockRenderer = [[VGCFC_MockRenderer alloc] init];
    
    NSError *error = nil;
    VGCameraGraphSession *session = [[VGCameraGraphSession alloc]
        initWithSource:(VanguardCameraMediaSource *)mockSource
              renderer:(VanguardMetalRenderer *)mockRenderer
                  error:&error];
    
    XCTAssertNotNil(session);
    
    [session invalidate];
    XCTAssertNil(mockRenderer.frameDelegate);
    
    // Reset flags to check no-op post-invalidate
    mockSource.startCalled = NO;
    mockSource.startCallCount = 0;
    
    VGCFC_MockLUTFilter *mockLUT = [[VGCFC_MockLUTFilter alloc] init];
    NSArray *lutFilterChain = @[mockLUT];
    XCTAssertNoThrow([session setCameraFilterChain:lutFilterChain], @"Post-invalidate setCameraFilterChain must not crash");
    
    XCTAssertNil(mockRenderer.frameDelegate, @"Delegate must remain nil after setCameraFilterChain on invalidated session");
    XCTAssertFalse(mockSource.startCalled, @"Source start must not be called post-invalidate");
    XCTAssertEqual(mockSource.startCallCount, 0);
}

@end
