// VGCameraGraphSessionTest.m
// vanguard_media_engine — Phase 6A-2
//
// Unit tests for VGCameraGraphSession.
//
// Mock prefix: VGMCS_ (VG Mock Camera Session)

#import <XCTest/XCTest.h>
#import "VGCameraGraphSession.h"
#import "VanguardCameraMediaSource.h"
#import "VanguardMetalRenderer.h"
#import <UMF/VGFrameDelegate.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGMCS_MockCameraSource
// ─────────────────────────────────────────────────────────────────────────────

@interface VGMCS_MockCameraSource : NSObject
@property (nonatomic) BOOL startCalled;
@property (nonatomic) BOOL stopCalled;
@property (nonatomic) NSInteger startCallCount;
@property (nonatomic) NSInteger stopCallCount;
@end

@implementation VGMCS_MockCameraSource

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
#pragma mark - VGMCS_MockRenderer
// ─────────────────────────────────────────────────────────────────────────────

@interface VGMCS_MockRenderer : NSObject
@property (nonatomic, weak, nullable) id<VGFrameDelegate> frameDelegate;
@end

@implementation VGMCS_MockRenderer
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGCameraGraphSessionTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCameraGraphSessionTest : XCTestCase
@end

@implementation VGCameraGraphSessionTest {
    VGMCS_MockCameraSource *_mockSource;
    VGMCS_MockRenderer     *_mockRenderer;
}

- (void)setUp {
    [super setUp];
    _mockSource = [[VGMCS_MockCameraSource alloc] init];
    _mockRenderer = [[VGMCS_MockRenderer alloc] init];
}

- (void)tearDown {
    _mockSource = nil;
    _mockRenderer = nil;
    [super tearDown];
}

- (void)testInitializationAndTeardown {
    NSError *error = nil;
    VGCameraGraphSession *session = [[VGCameraGraphSession alloc]
        initWithSource:(VanguardCameraMediaSource *)_mockSource
              renderer:(VanguardMetalRenderer *)_mockRenderer
                  error:&error];

    XCTAssertNotNil(session, @"Session creation must succeed with valid inputs");
    XCTAssertNil(error);

    // Verify frame delegate was wired on the renderer
    XCTAssertNotNil(_mockRenderer.frameDelegate, @"Renderer's frameDelegate must be set");

    // Verify camera source was started as part of startWithClock:
    XCTAssertTrue(_mockSource.startCalled, @"Camera source must be started on session start");
    XCTAssertEqual(_mockSource.startCallCount, 1, @"Camera source start should be called exactly once");
    XCTAssertFalse(_mockSource.stopCalled, @"Camera source must not be stopped yet");
    XCTAssertEqual(_mockSource.stopCallCount, 0, @"Camera source stop should not be called yet");

    // Invalidate the session
    [session invalidate];

    // Verify delegate was cleared
    XCTAssertNil(_mockRenderer.frameDelegate, @"Renderer's frameDelegate must be cleared on invalidate");

    // Verify camera source was stopped during scheduler invalidation
    XCTAssertTrue(_mockSource.stopCalled, @"Camera source must be stopped on session invalidate");
    XCTAssertEqual(_mockSource.stopCallCount, 1, @"Camera source stop should be called exactly once");

    // Redundant invalidate call (idempotency check)
    XCTAssertNoThrow([session invalidate], @"Redundant invalidate must be safe and idempotent");
    XCTAssertEqual(_mockSource.stopCallCount, 1, @"Redundant invalidate must not trigger stop on the camera source again");
}

- (void)testInvalidInputs {
    NSError *err1 = nil;
    VGCameraGraphSession *res1 = [[VGCameraGraphSession alloc]
        initWithSource:nil
              renderer:(VanguardMetalRenderer *)_mockRenderer
                  error:&err1];
    XCTAssertNil(res1);
    XCTAssertNotNil(err1);
    XCTAssertEqual(err1.code, 100);

    NSError *err2 = nil;
    VGCameraGraphSession *res2 = [[VGCameraGraphSession alloc]
        initWithSource:(VanguardCameraMediaSource *)_mockSource
              renderer:nil
                  error:&err2];
    XCTAssertNil(res2);
    XCTAssertNotNil(err2);
    XCTAssertEqual(err2.code, 100);
}

- (void)testCameraFilterChainHotSwap {
    NSError *error = nil;
    VGCameraGraphSession *session = [[VGCameraGraphSession alloc]
        initWithSource:(VanguardCameraMediaSource *)_mockSource
              renderer:(VanguardMetalRenderer *)_mockRenderer
                  error:&error];

    XCTAssertNotNil(session, @"Session creation must succeed");
    XCTAssertNil(error);

    // 1. session initializes, 2. initial frameDelegate exists
    id<VGFrameDelegate> initialDelegate = _mockRenderer.frameDelegate;
    XCTAssertNotNil(initialDelegate, @"Initial frameDelegate must exist");
    
    // Verify source started initially
    XCTAssertTrue(_mockSource.startCalled, @"Source must be started initially");
    XCTAssertEqual(_mockSource.startCallCount, 1, @"Source start should be called exactly once initially");
    XCTAssertFalse(_mockSource.stopCalled, @"Source must not be stopped initially");
    XCTAssertEqual(_mockSource.stopCallCount, 0, @"Source stop should be 0 initially");
    
    // Reset mock tracking flags to check that hot-swap doesn't stop the source
    _mockSource.startCalled = NO;
    _mockSource.stopCalled = NO;
    _mockSource.startCallCount = 0;
    _mockSource.stopCallCount = 0;

    // 3. setCameraFilterChain:nil hot-swaps to a new delegate/scheduler
    [session setCameraFilterChain:nil];
    id<VGFrameDelegate> secondDelegate = _mockRenderer.frameDelegate;
    XCTAssertNotNil(secondDelegate, @"Second frameDelegate must exist after hot-swap with nil");
    XCTAssertNotEqual(initialDelegate, secondDelegate, @"Hot-swap with nil must produce a new delegate");
    
    // Verify mock source was NOT stopped during hot-swap
    XCTAssertFalse(_mockSource.stopCalled, @"Mock source must not be stopped during hot-swap");
    XCTAssertEqual(_mockSource.stopCallCount, 0, @"Mock source stop count must be 0");
    
    // Verify mock source start WAS called again during dynamic hot-swap (adapter startProducing)
    XCTAssertTrue(_mockSource.startCalled, @"Mock source start should be called during hot-swap");
    XCTAssertEqual(_mockSource.startCallCount, 1, @"Mock source start count should increment to 1 during first hot-swap");

    // Reset flags for the second hot-swap check
    _mockSource.startCalled = NO;
    _mockSource.startCallCount = 0;

    // 4. setCameraFilterChain:@[] hot-swaps again
    [session setCameraFilterChain:@[]];
    id<VGFrameDelegate> thirdDelegate = _mockRenderer.frameDelegate;
    XCTAssertNotNil(thirdDelegate, @"Third frameDelegate must exist after hot-swap with empty array");
    XCTAssertNotEqual(secondDelegate, thirdDelegate, @"Hot-swap with empty array must produce a new delegate");
    
    // 5. multiple hot-swaps produce distinct delegates/schedulers
    XCTAssertNotEqual(initialDelegate, thirdDelegate, @"Multiple hot-swaps must produce distinct delegates");
    XCTAssertFalse(_mockSource.stopCalled, @"Mock source must not be stopped during second hot-swap");
    XCTAssertEqual(_mockSource.stopCallCount, 0, @"Mock source stop count must remain 0");
    
    // Verify mock source start WAS called again during the second dynamic hot-swap
    XCTAssertTrue(_mockSource.startCalled, @"Mock source start should be called during second hot-swap");
    XCTAssertEqual(_mockSource.startCallCount, 1, @"Mock source start count should increment to 1 during second hot-swap");

    // Reset stop tracking for invalidation check
    _mockSource.stopCalled = NO;
    _mockSource.stopCallCount = 0;

    // 6. after invalidate, setCameraFilterChain is a no-op and does not crash
    [session invalidate];
    XCTAssertNil(_mockRenderer.frameDelegate, @"Renderer's frameDelegate must be cleared after invalidate");
    XCTAssertTrue(_mockSource.stopCalled, @"Mock source must be stopped on invalidate");
    XCTAssertEqual(_mockSource.stopCallCount, 1, @"Mock source stop count must be 1 on invalidate");

    // Reset tracking to check no-op behavior post-invalidate
    _mockSource.startCalled = NO;
    _mockSource.stopCalled = NO;
    _mockSource.startCallCount = 0;
    _mockSource.stopCallCount = 0;
    
    // Hot-swap after invalidate
    XCTAssertNoThrow([session setCameraFilterChain:nil], @"Hot-swap after invalidate must not crash");
    XCTAssertNil(_mockRenderer.frameDelegate, @"Renderer's frameDelegate must remain nil after invalidate");
    XCTAssertFalse(_mockSource.startCalled, @"Source start must not be called post-invalidate");
    XCTAssertEqual(_mockSource.startCallCount, 0, @"Source start count must remain 0 post-invalidate");
    XCTAssertFalse(_mockSource.stopCalled, @"Source stop must not be called again");
    XCTAssertEqual(_mockSource.stopCallCount, 0, @"Source stop count must remain 0 post-invalidate");
}

@end
