// VGCameraGraphFactoryGateTest.m
// Phase 9B-3 — Factory gate unit test.
//
// Tests that +makeSegmentationNodeWithPool:device: (gate OFF path) produces
// a valid VGSegmentationNode that behaves identically to the pre-9B-3
// designated initializer. This is the source-level gate test for the OFF path.
//
// The ON path (VG_ML_SEGMENTATION_ENABLED == 1) is NOT tested here because
// it requires a separate build-setting override — it is covered by the
// integration path in VGLiteRTMaskProviderTest when the bundled model is
// present.
//
// Tests:
//   1. +makeSegmentationNodeWithPool:device: returns a non-nil VGSegmentationNode
//      when the gate is OFF (default).
//   2. The returned node is a VGSegmentationNode.
//   3. The returned node conforms to VGMetalFilterNode.
//   4. The returned node processes an envelope without crash (heuristic path).
//   5. The returned node processes nil device without crash.
//   6. The returned node invalidates without crash.
//   7. Multiple calls return independent instances.
//   8. The returned node's enabled property defaults to YES.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CMTime.h>
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGMetalFilterNode.h>

#import "VGCameraGraphFactory.h"
#import "VGSegmentationNode.h"

// ─── VGCameraGraphFactoryGateTest ────────────────────────────────────────────

@interface VGCameraGraphFactoryGateTest : XCTestCase
@end

@implementation VGCameraGraphFactoryGateTest {
    id<MTLDevice> _device; // may be nil on headless CI — acceptable
    CVPixelBufferRef _testBuffer;
}

- (void)setUp {
    [super setUp];
    _device = MTLCreateSystemDefaultDevice(); // nil on headless CI — acceptable
    CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                        kCVPixelFormatType_32BGRA, NULL, &_testBuffer);
}

- (void)tearDown {
    if (_testBuffer) { CVPixelBufferRelease(_testBuffer); _testBuffer = NULL; }
    _device = nil;
    [super tearDown];
}

/// Convenience: build a minimal video envelope.
- (VGFrameEnvelope)envelopeWithBuffer:(CVPixelBufferRef)buf {
    VGFrameEnvelope env;
    memset(&env, 0, sizeof(VGFrameEnvelope));
    env.payload.videoBuffer = buf;
    env.pts                 = kCMTimeZero;
    env.generation          = 0;
    env.mediaType           = VGMediaTypeVideo;
    env.metadata            = NULL;
    return env;
}

// ── P9B3-1: Factory returns non-nil VGSegmentationNode (gate OFF) ─────────────
- (void)testMakeSegmentationNodeReturnsNonNil {
    VGSegmentationNode *node = [VGCameraGraphFactory makeSegmentationNodeWithPool:NULL
                                                                           device:_device];
    XCTAssertNotNil(node,
        @"+makeSegmentationNodeWithPool:device: must return a non-nil node (gate OFF)");
}

// ── P9B3-2: Returned object is a VGSegmentationNode ──────────────────────────
- (void)testMakeSegmentationNodeReturnsCorrectClass {
    VGSegmentationNode *node = [VGCameraGraphFactory makeSegmentationNodeWithPool:NULL
                                                                           device:_device];
    XCTAssertTrue([node isKindOfClass:[VGSegmentationNode class]],
        @"Returned object must be a VGSegmentationNode");
}

// ── P9B3-3: Returned node conforms to VGMetalFilterNode ──────────────────────
- (void)testMakeSegmentationNodeConformsToVGMetalFilterNode {
    VGSegmentationNode *node = [VGCameraGraphFactory makeSegmentationNodeWithPool:NULL
                                                                           device:_device];
    XCTAssertTrue([node conformsToProtocol:@protocol(VGMetalFilterNode)],
        @"Node from factory must conform to VGMetalFilterNode");
}

// ── P9B3-4: Returned node processes envelope without crash ───────────────────
- (void)testMakeSegmentationNodeProcessesEnvelopeWithoutCrash {
    VGSegmentationNode *node = [VGCameraGraphFactory makeSegmentationNodeWithPool:NULL
                                                                           device:_device];
    XCTAssertNotNil(node);
    if (!_testBuffer) { XCTSkip(@"Could not allocate test buffer"); return; }
    VGFrameEnvelope env = [self envelopeWithBuffer:_testBuffer];
    XCTAssertNoThrow([node processEnvelope:env device:_device],
        @"Factory-produced node must process an envelope without crashing");
    [node invalidate];
}

// ── P9B3-5: Returned node tolerates nil device ───────────────────────────────
- (void)testMakeSegmentationNodeToleratesNilDevice {
    VGSegmentationNode *node = [VGCameraGraphFactory makeSegmentationNodeWithPool:NULL
                                                                           device:nil];
    XCTAssertNotNil(node, @"Factory must accept nil device");
    [node invalidate];
}

// ── P9B3-6: Returned node invalidates without crash ──────────────────────────
- (void)testMakeSegmentationNodeInvalidatesWithoutCrash {
    VGSegmentationNode *node = [VGCameraGraphFactory makeSegmentationNodeWithPool:NULL
                                                                           device:nil];
    XCTAssertNotNil(node);
    XCTAssertNoThrow([node invalidate], @"invalidate must not throw");
    XCTAssertNoThrow([node invalidate], @"Double invalidate must not throw");
}

// ── P9B3-7: Multiple calls return independent instances ──────────────────────
- (void)testMakeSegmentationNodeReturnsIndependentInstances {
    VGSegmentationNode *a = [VGCameraGraphFactory makeSegmentationNodeWithPool:NULL
                                                                        device:nil];
    VGSegmentationNode *b = [VGCameraGraphFactory makeSegmentationNodeWithPool:NULL
                                                                        device:nil];
    XCTAssertNotNil(a);
    XCTAssertNotNil(b);
    XCTAssertNotEqual(a, b, @"Each call must return a distinct instance");
    [a invalidate];
    [b invalidate];
}

// ── P9B3-8: Returned node enabled property defaults to YES ────────────────────
- (void)testMakeSegmentationNodeDefaultsEnabled {
    VGSegmentationNode *node = [VGCameraGraphFactory makeSegmentationNodeWithPool:NULL
                                                                           device:nil];
    XCTAssertNotNil(node);
    XCTAssertTrue(node.enabled,
        @"VGSegmentationNode from factory must default to enabled=YES");
    [node invalidate];
}

@end
