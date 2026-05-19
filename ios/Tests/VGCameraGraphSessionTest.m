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

@end
