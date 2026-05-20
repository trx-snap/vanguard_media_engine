// VGCameraFilterConstructionTest.m
// vanguard_media_engine — Phase 6A-3D-2
//
// Unit tests for VGCameraGraphSession.setCameraFilterChainFromSpecs:error:
// Proves: Beauty V1 construction, atomic validation, correct error codes,
//         and graph-non-mutation on any validation failure.
//
// Mock prefix: VGCFC2_ (VG Camera Filter Construction 2)
// Dimension injection: VGCFC2_TestGraphSession subclass (same pattern as
// VGCRC_TestGraphSession from VGCameraResourceContractTest.m)

#import <XCTest/XCTest.h>
#import "VGCameraGraphSession.h"
#import "VanguardCameraMediaSource.h"
#import "VanguardMetalRenderer.h"
#import "VanguardBeautyFilterNode.h"
#import "VGLegacyFilterAdapter.h"
#import <UMF/VGMetalFilterNode.h>
#import <CoreVideo/CoreVideo.h>

// ─── Dimension injection globals ─────────────────────────────────────────────
static size_t g_vgcfc2_mockWidth  = 0;
static size_t g_vgcfc2_mockHeight = 0;
static BOOL   g_vgcfc2_mockEnabled = NO;

// Declare the internal seam so the compiler sees it.
@interface VGCameraGraphSession (VGCFC2_Seam)
- (BOOL)_queryDimensionsWidth:(size_t *)outWidth height:(size_t *)outHeight;
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGCFC2_TestGraphSession
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCFC2_TestGraphSession : VGCameraGraphSession
@end

@implementation VGCFC2_TestGraphSession

+ (void)setMockWidth:(size_t)width height:(size_t)height enabled:(BOOL)enabled {
    g_vgcfc2_mockWidth   = width;
    g_vgcfc2_mockHeight  = height;
    g_vgcfc2_mockEnabled = enabled;
}

- (BOOL)_queryDimensionsWidth:(size_t *)outWidth height:(size_t *)outHeight {
    if (g_vgcfc2_mockEnabled) {
        if (outWidth)  *outWidth  = g_vgcfc2_mockWidth;
        if (outHeight) *outHeight = g_vgcfc2_mockHeight;
        return YES;
    }
    return [super _queryDimensionsWidth:outWidth height:outHeight];
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGCFC2_MockCameraSource
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCFC2_MockCameraSource : NSObject
@property (nonatomic) BOOL startCalled;
@property (nonatomic) BOOL stopCalled;
@end

@implementation VGCFC2_MockCameraSource
- (void)start { _startCalled = YES; }
- (void)stop  { _stopCalled  = YES; }
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGCFC2_MockRenderer
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCFC2_MockRenderer : NSObject
@property (nonatomic, weak, nullable) id frameDelegate;
@end

@implementation VGCFC2_MockRenderer
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGCameraFilterConstructionTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGCameraFilterConstructionTest : XCTestCase
@end

@implementation VGCameraFilterConstructionTest {
    // Strong reference to keep the mock renderer alive for the session's
    // __weak _renderer ivar. Without this, the renderer is deallocated
    // immediately after init, causing setCameraFilterChain: to skip the swap.
    VGCFC2_MockRenderer *_mockRenderer;
}

- (void)setUp {
    [super setUp];
    _mockRenderer = nil;
    [VGCFC2_TestGraphSession setMockWidth:0 height:0 enabled:NO];
}

- (void)tearDown {
    _mockRenderer = nil;
    [VGCFC2_TestGraphSession setMockWidth:0 height:0 enabled:NO];
    [super tearDown];
}

// ─── Helper ──────────────────────────────────────────────────────────────────

/// Create a session with mock 320×240 dimensions (pool will be allocated).
/// Retains the mock renderer in _mockRenderer to keep the session's weak ref alive.
- (VGCFC2_TestGraphSession *)makeSessionWithPool {
    [VGCFC2_TestGraphSession setMockWidth:320 height:240 enabled:YES];
    VGCFC2_MockCameraSource *src = [[VGCFC2_MockCameraSource alloc] init];
    _mockRenderer = [[VGCFC2_MockRenderer alloc] init];
    NSError *err = nil;
    VGCFC2_TestGraphSession *s =
        [[VGCFC2_TestGraphSession alloc]
            initWithSource:(VanguardCameraMediaSource *)src
                  renderer:(VanguardMetalRenderer *)_mockRenderer
                     error:&err];
    XCTAssertNotNil(s, @"Session should initialise: %@", err);
    return s;
}

/// Create a session without pool (no mock dimensions).
/// Retains the mock renderer in _mockRenderer to keep the session's weak ref alive.
- (VGCFC2_TestGraphSession *)makeSessionWithoutPool {
    [VGCFC2_TestGraphSession setMockWidth:0 height:0 enabled:NO];
    VGCFC2_MockCameraSource *src = [[VGCFC2_MockCameraSource alloc] init];
    _mockRenderer = [[VGCFC2_MockRenderer alloc] init];
    NSError *err = nil;
    VGCFC2_TestGraphSession *s =
        [[VGCFC2_TestGraphSession alloc]
            initWithSource:(VanguardCameraMediaSource *)src
                  renderer:(VanguardMetalRenderer *)_mockRenderer
                     error:&err];
    XCTAssertNotNil(s, @"Session without pool should still init: %@", err);
    return s;
}

// ─── 1. Beauty V1 spec constructs node and mutates graph ─────────────────────

- (void)testBeautyV1SpecConstructsNodeInGraph {
    VGCFC2_TestGraphSession *session = [self makeSessionWithPool];

    NSDictionary *spec  = @{ @"type": @"beauty" };
    NSArray       *specs = @[ spec ];

    NSError *error = nil;
    BOOL success = [session setCameraFilterChainFromSpecs:specs error:&error];

    XCTAssertTrue(success, @"Beauty V1 spec must succeed");
    XCTAssertNil(error,    @"No error expected for Beauty V1");

    NSDictionary<NSString *, id> *nodes = [session valueForKey:@"_nodes"];
    XCTAssertNotNil(nodes, @"_nodes must exist after hot-swap");
    // Passthrough graph = 2 nodes. With one filter = at least 3.
    XCTAssertGreaterThanOrEqual(nodes.count, 3u,
        @"Graph must contain source + beauty + sink");

    // _nodes contains VGLegacyFilterAdapter wrappers around the raw filter nodes.
    // Adapters expose nodeClass (not nodeType) which returns the wrapped filter's nodeType.
    BOOL foundBeauty = NO;
    for (id node in nodes.allValues) {
        if ([node respondsToSelector:@selector(nodeClass)] &&
            [[node nodeClass] isEqualToString:@"VGBeautyFilterNode"]) {
            foundBeauty = YES;
            break;
        }
    }
    XCTAssertTrue(foundBeauty,
        @"_nodes must contain an adapter with nodeClass VGBeautyFilterNode");

    [session invalidate];
}

// ─── 2. beautyVersion:2 returns UNSUPPORTED_FILTER_TYPE, no mutation ─────────

- (void)testBeautyV2ParamReturnsUnsupported {
    VGCFC2_TestGraphSession *session = [self makeSessionWithPool];

    NSDictionary *spec  = @{ @"type": @"beauty",
                              @"parameters": @{ @"beautyVersion": @2 } };
    NSArray       *specs = @[ spec ];

    NSError *error = nil;
    BOOL success = [session setCameraFilterChainFromSpecs:specs error:&error];

    XCTAssertFalse(success, @"beautyVersion:2 must be rejected");
    XCTAssertEqualObjects(error.domain, @"UNSUPPORTED_FILTER_TYPE",
        @"Error domain must be UNSUPPORTED_FILTER_TYPE for beautyVersion:2");

    // Graph must not have been mutated — passthrough = 2 nodes.
    NSDictionary<NSString *, id> *nodes = [session valueForKey:@"_nodes"];
    XCTAssertEqual(nodes.count, 2u,
        @"Graph must not be mutated on validation failure");

    [session invalidate];
}

// ─── 3. lut returns UNSUPPORTED_FILTER_TYPE, no mutation ─────────────────────

- (void)testLUTReturnsUnsupported {
    VGCFC2_TestGraphSession *session = [self makeSessionWithPool];

    NSArray *specs = @[ @{ @"type": @"lut" } ];

    NSError *error = nil;
    BOOL success = [session setCameraFilterChainFromSpecs:specs error:&error];

    XCTAssertFalse(success, @"lut spec must be rejected (deferred)");
    XCTAssertEqualObjects(error.domain, @"UNSUPPORTED_FILTER_TYPE",
        @"Error domain must be UNSUPPORTED_FILTER_TYPE for lut");

    NSDictionary<NSString *, id> *nodes = [session valueForKey:@"_nodes"];
    XCTAssertEqual(nodes.count, 2u, @"Graph must not be mutated when lut rejected");

    [session invalidate];
}

// ─── 4. segmentation returns UNSUPPORTED_FILTER_TYPE, no mutation ────────────

- (void)testSegmentationReturnsUnsupported {
    VGCFC2_TestGraphSession *session = [self makeSessionWithPool];

    NSArray *specs = @[ @{ @"type": @"segmentation" } ];

    NSError *error = nil;
    BOOL success = [session setCameraFilterChainFromSpecs:specs error:&error];

    XCTAssertFalse(success, @"segmentation spec must be rejected (deferred)");
    XCTAssertEqualObjects(error.domain, @"UNSUPPORTED_FILTER_TYPE",
        @"Error domain must be UNSUPPORTED_FILTER_TYPE for segmentation");

    NSDictionary<NSString *, id> *nodes = [session valueForKey:@"_nodes"];
    XCTAssertEqual(nodes.count, 2u,
        @"Graph must not be mutated when segmentation rejected");

    [session invalidate];
}

// ─── 5. Unknown type returns UNKNOWN_FILTER, no mutation ─────────────────────

- (void)testUnknownTypeReturnsError {
    VGCFC2_TestGraphSession *session = [self makeSessionWithPool];

    NSArray *specs = @[ @{ @"type": @"sparkle" } ];

    NSError *error = nil;
    BOOL success = [session setCameraFilterChainFromSpecs:specs error:&error];

    XCTAssertFalse(success, @"Unknown type must be rejected");
    XCTAssertEqualObjects(error.domain, @"UNKNOWN_FILTER",
        @"Error domain must be UNKNOWN_FILTER for unknown type string");

    NSDictionary<NSString *, id> *nodes = [session valueForKey:@"_nodes"];
    XCTAssertEqual(nodes.count, 2u,
        @"Graph must not be mutated when unknown type rejected");

    [session invalidate];
}

// ─── 6. Empty specs clears filters (passthrough) ─────────────────────────────

- (void)testEmptySpecsClearsFilters {
    VGCFC2_TestGraphSession *session = [self makeSessionWithPool];

    // First install a Beauty V1 filter.
    NSError *setupError = nil;
    BOOL setupOK = [session setCameraFilterChainFromSpecs:@[ @{ @"type": @"beauty" } ]
                                                    error:&setupError];
    XCTAssertTrue(setupOK, @"Setup beauty filter must succeed");

    NSDictionary<NSString *, id> *nodesBefore = [session valueForKey:@"_nodes"];
    XCTAssertGreaterThanOrEqual(nodesBefore.count, 3u,
        @"Graph must have ≥3 nodes after beauty install");

    // Now clear via empty specs.
    NSError *clearError = nil;
    BOOL clearOK = [session setCameraFilterChainFromSpecs:@[] error:&clearError];

    XCTAssertTrue(clearOK,  @"Empty specs must return YES");
    XCTAssertNil(clearError, @"No error expected for empty specs");

    NSDictionary<NSString *, id> *nodesAfter = [session valueForKey:@"_nodes"];
    XCTAssertEqual(nodesAfter.count, 2u,
        @"Graph must be passthrough (2 nodes) after empty specs");

    [session invalidate];
}

// ─── 7. No pool returns UNSUPPORTED_CAMERA_FILTER_RESOURCE_CONTRACT ──────────

- (void)testNoPoolReturnsResourceContract {
    VGCFC2_TestGraphSession *session = [self makeSessionWithoutPool];

    // Verify pool is indeed nil.
    id poolVal = [session valueForKey:@"_sessionPool"];
    XCTAssertNil(poolVal, @"Session without dimensions must have nil pool");

    NSArray *specs = @[ @{ @"type": @"beauty" } ];

    NSError *error = nil;
    BOOL success = [session setCameraFilterChainFromSpecs:specs error:&error];

    XCTAssertFalse(success, @"Must fail when pool is unavailable");
    XCTAssertEqualObjects(error.domain,
        @"UNSUPPORTED_CAMERA_FILTER_RESOURCE_CONTRACT",
        @"Error domain must be UNSUPPORTED_CAMERA_FILTER_RESOURCE_CONTRACT when pool nil");

    [session invalidate];
}

// ─── 8. intensity param is applied to constructed node ───────────────────────

- (void)testBeautyIntensityParamApplied {
    VGCFC2_TestGraphSession *session = [self makeSessionWithPool];

    float expectedIntensity = 0.8f;
    NSDictionary *spec = @{
        @"type": @"beauty",
        @"parameters": @{ @"intensity": @(expectedIntensity) }
    };

    NSError *error = nil;
    BOOL success = [session setCameraFilterChainFromSpecs:@[ spec ] error:&error];

    XCTAssertTrue(success, @"Beauty with intensity must succeed: %@", error);

    NSDictionary<NSString *, id> *nodes = [session valueForKey:@"_nodes"];
    XCTAssertGreaterThanOrEqual(nodes.count, 3u,
        @"Graph must have been mutated with the beauty node");

    // Reach through adapter to find the raw VanguardBeautyFilterNode.
    // Adapters expose nodeClass (not nodeType) — use nodeClass to match.
    id<VGMetalFilterNode> foundFilter = nil;
    for (id node in nodes.allValues) {
        if ([node respondsToSelector:@selector(nodeClass)] &&
            [[node nodeClass] isEqualToString:@"VGBeautyFilterNode"]) {
            if ([node isKindOfClass:[VGLegacyFilterAdapter class]]) {
                foundFilter = ((VGLegacyFilterAdapter *)node).filter;
            }
            break;
        }
    }
    VanguardBeautyFilterNode *beautyNode =
        [foundFilter isKindOfClass:[VanguardBeautyFilterNode class]]
            ? (VanguardBeautyFilterNode *)foundFilter
            : nil;
    XCTAssertNotNil(beautyNode, @"A VanguardBeautyFilterNode must exist in _nodes");
    XCTAssertEqualWithAccuracy(beautyNode.intensity, expectedIntensity, 0.001f,
        @"Constructed beauty node must have the specified intensity");

    [session invalidate];
}

// ─── 9. Mixed [beauty, lut] does not mutate (atomic: lut unsupported) ────────

- (void)testMixedWithUnsupportedDoesNotMutate {
    VGCFC2_TestGraphSession *session = [self makeSessionWithPool];

    NSArray *specs = @[
        @{ @"type": @"beauty" },
        @{ @"type": @"lut" }
    ];

    NSError *error = nil;
    BOOL success = [session setCameraFilterChainFromSpecs:specs error:&error];

    XCTAssertFalse(success, @"Mixed specs including lut must be rejected");
    XCTAssertEqualObjects(error.domain, @"UNSUPPORTED_FILTER_TYPE",
        @"Error domain must be UNSUPPORTED_FILTER_TYPE (lut is deferred)");

    // Atomic: graph must be unchanged despite beauty being valid.
    NSDictionary<NSString *, id> *nodes = [session valueForKey:@"_nodes"];
    XCTAssertEqual(nodes.count, 2u,
        @"Graph must not be mutated — atomic validation failed at lut");

    BOOL foundBeauty = NO;
    for (id value in nodes.allValues) {
        if ([value isKindOfClass:[VanguardBeautyFilterNode class]]) {
            foundBeauty = YES;
            break;
        }
    }
    XCTAssertFalse(foundBeauty,
        @"No beauty node must appear — atomic validation prevented construction");

    [session invalidate];
}

// ─── 10. Invalid params do not crash; if type is still valid node is built ───

- (void)testInvalidParamsDoNotCrash {
    VGCFC2_TestGraphSession *session = [self makeSessionWithPool];

    // Pass a non-NSNumber intensity value — must not crash.
    NSDictionary *spec = @{
        @"type": @"beauty",
        @"parameters": @{ @"intensity": @"not_a_number" }
    };

    NSError *error = nil;
    __block BOOL success = NO;
    XCTAssertNoThrow(
        success = [session setCameraFilterChainFromSpecs:@[ spec ] error:&error],
        @"Invalid params must not throw"
    );

    // Type is valid, so construction must still succeed (invalid intensity ignored).
    XCTAssertTrue(success,
        @"Beauty with invalid intensity param must still construct (param silently ignored)");
    XCTAssertNil(error, @"No error expected — type is valid");

    NSDictionary<NSString *, id> *nodes = [session valueForKey:@"_nodes"];
    XCTAssertGreaterThanOrEqual(nodes.count, 3u,
        @"Graph must have been mutated with the beauty node");

    // _nodes contains VGLegacyFilterAdapter wrappers — find the one wrapping
    // the beauty node by checking nodeClass (not nodeType) on the adapter.
    // Then reach through to the filter via VGLegacyFilterAdapter.filter.
    id<VGMetalFilterNode> foundFilter = nil;
    for (id node in nodes.allValues) {
        if ([node respondsToSelector:@selector(nodeClass)] &&
            [[node nodeClass] isEqualToString:@"VGBeautyFilterNode"]) {
            if ([node isKindOfClass:[VGLegacyFilterAdapter class]]) {
                foundFilter = ((VGLegacyFilterAdapter *)node).filter;
            }
            break;
        }
    }
    VanguardBeautyFilterNode *beautyNode =
        [foundFilter isKindOfClass:[VanguardBeautyFilterNode class]]
            ? (VanguardBeautyFilterNode *)foundFilter
            : nil;
    XCTAssertNotNil(beautyNode, @"Beauty node must exist");
    // Default intensity is 0.5. The invalid @"not_a_number" must have been silently skipped.
    XCTAssertEqualWithAccuracy(beautyNode.intensity, 0.5f, 0.001f,
        @"Invalid intensity must be silently ignored; node uses default 0.5f");

    [session invalidate];
}

@end
