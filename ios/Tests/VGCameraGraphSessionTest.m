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
@end

@implementation VGMCS_MockCameraSource

- (void)start {
    _startCalled = YES;
}

- (void)stop {
    _stopCalled = YES;
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
    XCTAssertFalse(_mockSource.stopCalled, @"Camera source must not be stopped yet");

    // Invalidate the session
    [session invalidate];

    // Verify delegate was cleared
    XCTAssertNil(_mockRenderer.frameDelegate, @"Renderer's frameDelegate must be cleared on invalidate");

    // Verify camera source was stopped during scheduler invalidation
    XCTAssertTrue(_mockSource.stopCalled, @"Camera source must be stopped on session invalidate");

    // Redundant invalidate call (idempotency check)
    XCTAssertNoThrow([session invalidate], @"Redundant invalidate must be safe and idempotent");
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
    XCTAssertFalse(_mockSource.stopCalled, @"Source must not be stopped initially");
    
    // Reset mock tracking flags to check that hot-swap doesn't stop the source
    _mockSource.startCalled = NO;
    _mockSource.stopCalled = NO;

    // 3. setCameraFilterChain:nil hot-swaps to a new delegate/scheduler
    [session setCameraFilterChain:nil];
    id<VGFrameDelegate> secondDelegate = _mockRenderer.frameDelegate;
    XCTAssertNotNil(secondDelegate, @"Second frameDelegate must exist after hot-swap with nil");
    XCTAssertNotEqual(initialDelegate, secondDelegate, @"Hot-swap with nil must produce a new delegate");
    
    // Verify mock source was NOT stopped during hot-swap
    XCTAssertFalse(_mockSource.stopCalled, @"Mock source must not be stopped during hot-swap");

    // 4. setCameraFilterChain:@[] hot-swaps again
    [session setCameraFilterChain:@[]];
    id<VGFrameDelegate> thirdDelegate = _mockRenderer.frameDelegate;
    XCTAssertNotNil(thirdDelegate, @"Third frameDelegate must exist after hot-swap with empty array");
    XCTAssertNotEqual(secondDelegate, thirdDelegate, @"Hot-swap with empty array must produce a new delegate");
    
    // 5. multiple hot-swaps produce distinct delegates/schedulers
    XCTAssertNotEqual(initialDelegate, thirdDelegate, @"Multiple hot-swaps must produce distinct delegates");
    XCTAssertFalse(_mockSource.stopCalled, @"Mock source must not be stopped during second hot-swap");

    // 6. after invalidate, setCameraFilterChain is a no-op and does not crash
    [session invalidate];
    XCTAssertNil(_mockRenderer.frameDelegate, @"Renderer's frameDelegate must be cleared after invalidate");
    XCTAssertTrue(_mockSource.stopCalled, @"Mock source must be stopped on invalidate");

    // Reset stopCalled to check no-op behavior
    _mockSource.stopCalled = NO;
    
    // Hot-swap after invalidate
    XCTAssertNoThrow([session setCameraFilterChain:nil], @"Hot-swap after invalidate must not crash");
    XCTAssertNil(_mockRenderer.frameDelegate, @"Renderer's frameDelegate must remain nil after invalidate");
    XCTAssertFalse(_mockSource.stopCalled, @"Source stop must not be called again");
}

@end
