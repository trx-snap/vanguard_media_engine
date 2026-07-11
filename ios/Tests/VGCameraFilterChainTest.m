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
// Phase 6E.1C: matches the accepted atomic BOOL on VanguardCameraMediaSource.
// Without this property, VGCameraGraphSession.setRecordingEnabled: throws
// an unrecognised-selector exception when the session writes the flag.
@property (atomic, assign) BOOL graphRecordingEnabled;
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
    
    // Phase 6A-3G-C: the session is the permanent renderer.frameDelegate.
    // Hot-swap replaces the internal _scheduler, not the frameDelegate.
    id<VGFrameDelegate> initialDelegate = mockRenderer.frameDelegate;
    XCTAssertNotNil(initialDelegate, @"Initial frameDelegate must not be nil");
    XCTAssertEqual(initialDelegate, session, @"renderer.frameDelegate must be the session itself");
    id initialScheduler = [session valueForKey:@"_scheduler"];
    XCTAssertNotNil(initialScheduler, @"Initial scheduler must not be nil");
    XCTAssertTrue(mockSource.startCalled);
    XCTAssertEqual(mockSource.startCallCount, 1);
    
    // Reset flags to verify that hot-swap doesn't stop the source
    mockSource.startCalled = NO;
    mockSource.stopCalled = NO;
    mockSource.startCallCount = 0;
    mockSource.stopCallCount = 0;
    
    VGCFC_MockLUTFilter *mockLUT = [[VGCFC_MockLUTFilter alloc] init];
    [session setCameraFilterChain:@[mockLUT]];
    
    // The renderer delegate must remain the same session instance.
    XCTAssertNotNil(mockRenderer.frameDelegate, @"Renderer frameDelegate must remain non-nil after hot-swap");
    XCTAssertEqual(mockRenderer.frameDelegate, session, @"renderer.frameDelegate must remain the same session after hot-swap");
    // The internal scheduler must have been replaced.
    id updatedScheduler = [session valueForKey:@"_scheduler"];
    XCTAssertNotNil(updatedScheduler, @"Updated scheduler must not be nil after hot-swap");
    XCTAssertNotEqual(initialScheduler, updatedScheduler, @"Hot-swap must replace the internal scheduler");
    
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
    // Phase 6A-3G-C: the session is the permanent renderer.frameDelegate.
    XCTAssertNotNil(mockRenderer.frameDelegate, @"Initial frameDelegate must not be nil");
    XCTAssertEqual(mockRenderer.frameDelegate, session, @"renderer.frameDelegate must be the session itself");
    id initialScheduler = [session valueForKey:@"_scheduler"];
    XCTAssertNotNil(initialScheduler, @"Initial scheduler must not be nil");
    
    VGCFC_MockLUTFilter *mockLUT = [[VGCFC_MockLUTFilter alloc] init];
    [session setCameraFilterChain:@[mockLUT]];
    
    // Delegate remains the same session; scheduler must have been replaced.
    XCTAssertEqual(mockRenderer.frameDelegate, session, @"renderer.frameDelegate must remain the session after first hot-swap");
    id schedulerAfterLUT = [session valueForKey:@"_scheduler"];
    XCTAssertNotNil(schedulerAfterLUT, @"Scheduler must not be nil after first hot-swap");
    XCTAssertNotEqual(initialScheduler, schedulerAfterLUT, @"Scheduler must be replaced after first hot-swap");
    
    mockSource.stopCalled = NO;
    mockSource.stopCallCount = 0;
    
    [session setCameraFilterChain:@[]];
    // Delegate remains the same session; scheduler must have been replaced again.
    XCTAssertNotNil(mockRenderer.frameDelegate, @"frameDelegate must remain non-nil after empty-chain hot-swap");
    XCTAssertEqual(mockRenderer.frameDelegate, session, @"renderer.frameDelegate must remain the session after second hot-swap");
    id schedulerAfterEmpty = [session valueForKey:@"_scheduler"];
    XCTAssertNotNil(schedulerAfterEmpty, @"Scheduler must not be nil after second hot-swap");
    XCTAssertNotEqual(schedulerAfterLUT, schedulerAfterEmpty, @"Scheduler must be replaced after second hot-swap");
    XCTAssertNotEqual(initialScheduler, schedulerAfterEmpty, @"Scheduler after second hot-swap must differ from the initial scheduler");
    
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
    // Phase 6A-3G-C: the session is the permanent renderer.frameDelegate.
    XCTAssertEqual(mockRenderer.frameDelegate, session, @"renderer.frameDelegate must be the session itself");
    id initialScheduler = [session valueForKey:@"_scheduler"];
    XCTAssertNotNil(initialScheduler, @"Initial scheduler must not be nil");
    
    VGCFC_MockLUTFilter *mockLUT = [[VGCFC_MockLUTFilter alloc] init];
    [session setCameraFilterChain:@[mockLUT]];
    // Scheduler must have been replaced after first hot-swap.
    id schedulerAfterLUT = [session valueForKey:@"_scheduler"];
    XCTAssertNotEqual(initialScheduler, schedulerAfterLUT, @"Scheduler must be replaced after LUT hot-swap");
    
    mockSource.stopCalled = NO;
    mockSource.stopCallCount = 0;
    
    [session setCameraFilterChain:nil];
    // Delegate remains the same session; scheduler must have been replaced again.
    XCTAssertNotNil(mockRenderer.frameDelegate, @"frameDelegate must remain non-nil after nil-chain hot-swap");
    XCTAssertEqual(mockRenderer.frameDelegate, session, @"renderer.frameDelegate must remain the session after nil-chain hot-swap");
    id schedulerAfterNil = [session valueForKey:@"_scheduler"];
    XCTAssertNotNil(schedulerAfterNil, @"Scheduler must not be nil after nil-chain hot-swap");
    XCTAssertNotEqual(schedulerAfterLUT, schedulerAfterNil, @"Scheduler must be replaced after nil-chain hot-swap");
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
    // Phase 6A-3G-C: the session is the permanent renderer.frameDelegate.
    XCTAssertEqual(mockRenderer.frameDelegate, session, @"renderer.frameDelegate must be the session itself");
    id initialScheduler = [session valueForKey:@"_scheduler"];
    XCTAssertNotNil(initialScheduler, @"Initial scheduler must not be nil");
    
    VGCFC_MockBadFilter *badFilter = [[VGCFC_MockBadFilter alloc] init];
    
    NSArray *badFilterChain = @[badFilter];
    XCTAssertNoThrow([session setCameraFilterChain:badFilterChain], @"Skipping non-conforming object must not throw/crash");
    
    // The delegate remains the session; the scheduler must have been replaced (bad filter is skipped, passthrough rebuilt).
    XCTAssertNotNil(mockRenderer.frameDelegate, @"frameDelegate must remain non-nil after bad-filter swap");
    XCTAssertEqual(mockRenderer.frameDelegate, session, @"renderer.frameDelegate must remain the session");
    id updatedScheduler = [session valueForKey:@"_scheduler"];
    XCTAssertNotNil(updatedScheduler, @"Updated scheduler must not be nil after bad-filter hot-swap");
    XCTAssertNotEqual(initialScheduler, updatedScheduler, @"Dynamic swap to passthrough must replace the scheduler");
    
    NSDictionary *nodes = [session valueForKey:@"_nodes"];
    XCTAssertNotNil(nodes);
    XCTAssertNotNil(nodes[@"camera_source"]);
    XCTAssertNotNil(nodes[@"fan_out_sink"]);
    // Phase 6E: default graph has 4 baseline nodes
    // (camera_source, fan_out_sink, camera_recording_sink, camera_photo_sink).
    // Bad filter is skipped — no additional node is added beyond the baseline.
    XCTAssertNotNil(nodes[@"camera_recording_sink"], @"Recording sink must be present in baseline graph");
    XCTAssertNotNil(nodes[@"camera_photo_sink"], @"Photo sink must be present in baseline graph");
    XCTAssertEqual(nodes.count, 4u, @"Bad filter must have been skipped, resulting in standard passthrough graph (4 baseline nodes)");
    
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
    
    // Verify that bad filter was skipped but valid LUT filter remains in the nodes dictionary.
    NSDictionary *nodes = [session valueForKey:@"_nodes"];
    XCTAssertNotNil(nodes);
    XCTAssertNotNil(nodes[@"camera_source"]);
    XCTAssertNotNil(nodes[@"mock_lut_filter"], @"LUT filter must be preserved in the graph");
    XCTAssertNotNil(nodes[@"fan_out_sink"]);
    // Phase 6E: 4 baseline nodes + 1 accepted LUT filter = 5 total.
    // (camera_source, mock_lut_filter, fan_out_sink, camera_recording_sink, camera_photo_sink)
    XCTAssertNotNil(nodes[@"camera_recording_sink"], @"Recording sink must be present in baseline graph");
    XCTAssertNotNil(nodes[@"camera_photo_sink"], @"Photo sink must be present in baseline graph");
    XCTAssertEqual(nodes.count, 5u, @"Graph must have 5 nodes: 4 baseline + accepted LUT (bad filter was skipped)");
    
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
