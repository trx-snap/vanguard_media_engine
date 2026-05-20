// VGCameraResourceContractTest.m
// vanguard_media_engine — Phase 6A-3D-1
//
// Unit tests for VGCameraGraphSession's CVPixelBufferPool and resource contract.
//
// Mock prefix: VGCRC_ (VG Camera Resource Contract Mock)

#import <XCTest/XCTest.h>
#import "VGCameraGraphSession.h"
#import "VanguardCameraMediaSource.h"
#import "VanguardMetalRenderer.h"
#import <UMF/VGResourceAllocator.h>
#import <CoreVideo/CoreVideo.h>

static size_t g_mockWidth = 0;
static size_t g_mockHeight = 0;
static BOOL g_mockDimensionsEnabled = NO;

// Declare the internal seam on VGCameraGraphSession so the compiler sees it.
@interface VGCameraGraphSession (VGCRC_Seam)
- (BOOL)_queryDimensionsWidth:(size_t *)outWidth height:(size_t *)outHeight;
@end

// Subclass VGCameraGraphSession to inject arbitrary dimensions
@interface VGCRC_TestGraphSession : VGCameraGraphSession
@end

@implementation VGCRC_TestGraphSession

+ (void)setMockWidth:(size_t)width height:(size_t)height enabled:(BOOL)enabled {
    g_mockWidth = width;
    g_mockHeight = height;
    g_mockDimensionsEnabled = enabled;
}

- (BOOL)_queryDimensionsWidth:(size_t *)outWidth height:(size_t *)outHeight {
    if (g_mockDimensionsEnabled) {
        if (outWidth) *outWidth = g_mockWidth;
        if (outHeight) *outHeight = g_mockHeight;
        return YES;
    }
    return [super _queryDimensionsWidth:outWidth height:outHeight];
}

@end

// Mock classes for VGCRC_
@interface VGCRC_MockCameraSource : NSObject
@property (nonatomic, strong, nullable) id captureSession;
@property (nonatomic) BOOL startCalled;
@property (nonatomic) BOOL stopCalled;
@end

@implementation VGCRC_MockCameraSource
- (void)start {
    _startCalled = YES;
}
- (void)stop {
    _stopCalled = YES;
}
@end

@interface VGCRC_MockRenderer : NSObject
@property (nonatomic, weak, nullable) id frameDelegate;
@end

@implementation VGCRC_MockRenderer
@end

@interface VGCameraResourceContractTest : XCTestCase
@end

@implementation VGCameraResourceContractTest

- (void)setUp {
    [super setUp];
    [VGCRC_TestGraphSession setMockWidth:0 height:0 enabled:NO];
}

- (void)tearDown {
    [VGCRC_TestGraphSession setMockWidth:0 height:0 enabled:NO];
    [super tearDown];
}

- (void)testSessionPoolCreatedOnInit {
    [VGCRC_TestGraphSession setMockWidth:320 height:240 enabled:YES];
    VGCRC_MockCameraSource *mockSource = [[VGCRC_MockCameraSource alloc] init];
    VGCRC_MockRenderer *mockRenderer = [[VGCRC_MockRenderer alloc] init];
    
    NSError *error = nil;
    VGCRC_TestGraphSession *session = [[VGCRC_TestGraphSession alloc] initWithSource:(VanguardCameraMediaSource *)mockSource
                                                                            renderer:(VanguardMetalRenderer *)mockRenderer
                                                                               error:&error];
    XCTAssertNotNil(session, @"Session creation failed: %@", error);
    XCTAssertNil(error);
    
    id poolVal = [session valueForKey:@"_sessionPool"];
    XCTAssertNotNil(poolVal, @"sessionPool ivar should be created on init.");
    
    CVPixelBufferPoolRef pool = (__bridge CVPixelBufferPoolRef)poolVal;
    XCTAssertTrue(CFGetTypeID(pool) == CVPixelBufferPoolGetTypeID(), @"sessionPool should be a CVPixelBufferPoolRef.");
    
    [session invalidate];
}

- (void)testSessionPoolDimensionsMatchCaptureOutput {
    size_t testWidth = 640;
    size_t testHeight = 480;
    [VGCRC_TestGraphSession setMockWidth:testWidth height:testHeight enabled:YES];
    
    VGCRC_MockCameraSource *mockSource = [[VGCRC_MockCameraSource alloc] init];
    VGCRC_MockRenderer *mockRenderer = [[VGCRC_MockRenderer alloc] init];
    
    NSError *error = nil;
    VGCRC_TestGraphSession *session = [[VGCRC_TestGraphSession alloc] initWithSource:(VanguardCameraMediaSource *)mockSource
                                                                            renderer:(VanguardMetalRenderer *)mockRenderer
                                                                               error:&error];
    XCTAssertNotNil(session);
    
    id poolVal = [session valueForKey:@"_sessionPool"];
    XCTAssertNotNil(poolVal);
    CVPixelBufferPoolRef pool = (__bridge CVPixelBufferPoolRef)poolVal;
    
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pixelBuffer);
    XCTAssertEqual(status, kCVReturnSuccess, @"Failed to create pixel buffer from pool.");
    XCTAssertNotNil((__bridge id)pixelBuffer);
    
    if (pixelBuffer) {
        size_t width = CVPixelBufferGetWidth(pixelBuffer);
        size_t height = CVPixelBufferGetHeight(pixelBuffer);
        XCTAssertEqual(width, testWidth, @"Pool buffer width should match capture width.");
        XCTAssertEqual(height, testHeight, @"Pool buffer height should match capture height.");
        CVPixelBufferRelease(pixelBuffer);
    }
    
    [session invalidate];
}

- (void)testSessionPoolIsBGRA {
    [VGCRC_TestGraphSession setMockWidth:320 height:240 enabled:YES];
    VGCRC_MockCameraSource *mockSource = [[VGCRC_MockCameraSource alloc] init];
    VGCRC_MockRenderer *mockRenderer = [[VGCRC_MockRenderer alloc] init];
    
    NSError *error = nil;
    VGCRC_TestGraphSession *session = [[VGCRC_TestGraphSession alloc] initWithSource:(VanguardCameraMediaSource *)mockSource
                                                                            renderer:(VanguardMetalRenderer *)mockRenderer
                                                                               error:&error];
    XCTAssertNotNil(session);
    
    id poolVal = [session valueForKey:@"_sessionPool"];
    XCTAssertNotNil(poolVal);
    CVPixelBufferPoolRef pool = (__bridge CVPixelBufferPoolRef)poolVal;
    
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pixelBuffer);
    XCTAssertEqual(status, kCVReturnSuccess);
    
    if (pixelBuffer) {
        OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
        XCTAssertEqual(format, kCVPixelFormatType_32BGRA, @"Pixel buffer format must be BGRA.");
        CVPixelBufferRelease(pixelBuffer);
    }
    
    [session invalidate];
}

- (void)testSessionPoolBudgetReservedOnInit {
    size_t testWidth = 320;
    size_t testHeight = 240;
    NSUInteger expectedPoolBytes = testWidth * testHeight * 4 * 3;
    
    VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];
    NSUInteger memoryBefore = allocator.estimatedPoolMemoryBytes;
    
    [VGCRC_TestGraphSession setMockWidth:testWidth height:testHeight enabled:YES];
    VGCRC_MockCameraSource *mockSource = [[VGCRC_MockCameraSource alloc] init];
    VGCRC_MockRenderer *mockRenderer = [[VGCRC_MockRenderer alloc] init];
    
    NSError *error = nil;
    VGCRC_TestGraphSession *session = [[VGCRC_TestGraphSession alloc] initWithSource:(VanguardCameraMediaSource *)mockSource
                                                                            renderer:(VanguardMetalRenderer *)mockRenderer
                                                                               error:&error];
    XCTAssertNotNil(session);
    
    NSUInteger memoryAfter = allocator.estimatedPoolMemoryBytes;
    
    XCTAssertEqual(memoryAfter - memoryBefore, expectedPoolBytes, @"Budget should be reserved on init.");
    
    NSNumber *poolBytesVal = [session valueForKey:@"_sessionPoolBytes"];
    XCTAssertEqual(poolBytesVal.unsignedIntegerValue, expectedPoolBytes, @"_sessionPoolBytes must match expected size.");
    
    [session invalidate];
}

- (void)testInvalidateReleasesPool {
    [VGCRC_TestGraphSession setMockWidth:320 height:240 enabled:YES];
    VGCRC_MockCameraSource *mockSource = [[VGCRC_MockCameraSource alloc] init];
    VGCRC_MockRenderer *mockRenderer = [[VGCRC_MockRenderer alloc] init];
    
    NSError *error = nil;
    VGCRC_TestGraphSession *session = [[VGCRC_TestGraphSession alloc] initWithSource:(VanguardCameraMediaSource *)mockSource
                                                                            renderer:(VanguardMetalRenderer *)mockRenderer
                                                                               error:&error];
    XCTAssertNotNil(session);
    
    id poolBefore = [session valueForKey:@"_sessionPool"];
    XCTAssertNotNil(poolBefore);
    
    [session invalidate];
    
    id poolAfter = [session valueForKey:@"_sessionPool"];
    XCTAssertNil(poolAfter, @"invalidate must release and nil the session pool.");
}

- (void)testInvalidateReportsBudgetReleased {
    size_t testWidth = 320;
    size_t testHeight = 240;
    [VGCRC_TestGraphSession setMockWidth:testWidth height:testHeight enabled:YES];
    VGCRC_MockCameraSource *mockSource = [[VGCRC_MockCameraSource alloc] init];
    VGCRC_MockRenderer *mockRenderer = [[VGCRC_MockRenderer alloc] init];
    
    VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];
    NSUInteger memoryBefore = allocator.estimatedPoolMemoryBytes;
    
    NSError *error = nil;
    VGCRC_TestGraphSession *session = [[VGCRC_TestGraphSession alloc] initWithSource:(VanguardCameraMediaSource *)mockSource
                                                                            renderer:(VanguardMetalRenderer *)mockRenderer
                                                                               error:&error];
    XCTAssertNotNil(session);
    
    XCTAssertGreaterThan(allocator.estimatedPoolMemoryBytes, memoryBefore, @"Headroom should have decreased on allocation.");
    
    [session invalidate];
    
    NSUInteger memoryAfter = allocator.estimatedPoolMemoryBytes;
    XCTAssertEqual(memoryAfter, memoryBefore, @"invalidate must report pool released and restore budget headroom.");
}

- (void)testPoolSurvivesFilterChainSwap {
    [VGCRC_TestGraphSession setMockWidth:320 height:240 enabled:YES];
    VGCRC_MockCameraSource *mockSource = [[VGCRC_MockCameraSource alloc] init];
    VGCRC_MockRenderer *mockRenderer = [[VGCRC_MockRenderer alloc] init];
    
    NSError *error = nil;
    VGCRC_TestGraphSession *session = [[VGCRC_TestGraphSession alloc] initWithSource:(VanguardCameraMediaSource *)mockSource
                                                                            renderer:(VanguardMetalRenderer *)mockRenderer
                                                                               error:&error];
    XCTAssertNotNil(session);
    
    id poolBefore = [session valueForKey:@"_sessionPool"];
    XCTAssertNotNil(poolBefore);
    
    [session setCameraFilterChain:@[]];
    
    id poolAfter = [session valueForKey:@"_sessionPool"];
    XCTAssertEqual(poolBefore, poolAfter, @"Pool must survive filter-chain swaps without recreation.");
    
    [session invalidate];
}

- (void)testSessionPoolNilIfSourceHasNoOutput {
    [VGCRC_TestGraphSession setMockWidth:0 height:0 enabled:NO];
    
    VGCRC_MockCameraSource *mockSource = [[VGCRC_MockCameraSource alloc] init];
    VGCRC_MockRenderer *mockRenderer = [[VGCRC_MockRenderer alloc] init];
    
    NSError *error = nil;
    VGCRC_TestGraphSession *session = [[VGCRC_TestGraphSession alloc] initWithSource:(VanguardCameraMediaSource *)mockSource
                                                                            renderer:(VanguardMetalRenderer *)mockRenderer
                                                                               error:&error];
    XCTAssertNotNil(session);
    
    id pool = [session valueForKey:@"_sessionPool"];
    XCTAssertNil(pool, @"Pool must be nil if source has no output dimensions.");
    
    NSNumber *poolBytes = [session valueForKey:@"_sessionPoolBytes"];
    XCTAssertEqual(poolBytes.unsignedIntegerValue, 0, @"Budget bytes must be 0 if pool was not allocated.");
    
    [session invalidate];
}

@end
