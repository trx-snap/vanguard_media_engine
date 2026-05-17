// VGAdapterParityTest.m
// vanguard_media_engine — Phase 4 Pre-4A
//
// Gate test: VGAdapterParityTest
//
// Purpose:
//   Verifies VGLegacyFilterAdapter.processEnvelope:device: produces identical
//   output to direct VGMetalFilterNode.processEnvelope:device:.
//
//   If the adapter introduces any pixel mutation, V2 parity with V1 is broken
//   by construction. This test isolates the adapter delegation path.
//
// Architecture:
//   VGAdapterP_MockFilter — same XOR-0xAA deterministic transform as
//     VGSchedulerParityTest.m's VGParityP_MockFilter (local copy).
//   No scheduler instantiation needed — tests the adapter's delegation only.
//
// Buffer ownership:
//   _testBuffer       — test-owned (+1). Released in tearDown.
//   _directOutput     — returned by mock filter's processEnvelope: (scheduler-owned).
//                       Test must release its +1 if it retained.
//   _adapterOutput    — same ownership as _directOutput.
//   Cleanup: CVPixelBufferRelease both in tearDown if retained.

#import <XCTest/XCTest.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

#import "VGLegacyFilterAdapter.h"

#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGMetalFilterNode.h>
#import <UMF/VGMediaNode.h>
#import <UMF/VGTransformNode.h>
#import <UMF/VGNode.h>
#import <UMF/VGMediaPort.h>

static const uint8_t kAdapterXorByte = 0xAA;

#pragma mark - VGAdapterP_MockFilter

@interface VGAdapterP_MockFilter : NSObject <VGMetalFilterNode, VGTransformNode>
@property (nonatomic, assign) BOOL enabled;
@end

@implementation VGAdapterP_MockFilter

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _enabled = YES;
    return self;
}

// VGMediaNode
- (NSString *)nodeId   { return @"adapter_test_filter"; }
- (NSString *)nodeType { return @"VGAdapterP_MockFilter"; }
- (VGNodeRole)nodeRole { return VGNodeRoleFilter; }
- (void)prepareWithCompletion:(void (^)(NSError * _Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ completion(nil); });
}
- (void)invalidate {}

// VGMetalFilterNode
- (BOOL)isExpensive         { return NO; }
- (float)estimatedGPUCostMs { return 1.0f; }

// VGNode
- (NSString *)nodeClass { return @"VGAdapterP_MockFilter"; }
- (NSArray<VGMediaPort *> *)declaredPorts {
    return @[
        [VGMediaPort inputPort:@"video_in"   mediaType:VGMediaTypeVideo required:YES],
        [VGMediaPort outputPort:@"video_out"  mediaType:VGMediaTypeVideo],
    ];
}
- (void)prepareWithContext:(VGGraphExecutionContext *)context
                completion:(void (^)(NSError * _Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ completion(nil); });
}
- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats { return nil; }

// processEnvelope:device: — shared by VGMetalFilterNode and VGTransformNode
- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                             device:(id<MTLDevice>)device {
    if (!self.enabled) return envelope;

    CVPixelBufferRef srcBuf = (CVPixelBufferRef)envelope.payload.videoBuffer;
    if (!srcBuf) return envelope;

    size_t width  = CVPixelBufferGetWidth(srcBuf);
    size_t height = CVPixelBufferGetHeight(srcBuf);
    OSType format = CVPixelBufferGetPixelFormatType(srcBuf);

    NSDictionary *attrs = @{ (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    CVPixelBufferRef dstBuf = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          width, height, format,
                                          (__bridge CFDictionaryRef)attrs,
                                          &dstBuf);
    if (status != kCVReturnSuccess || !dstBuf) return envelope;

    CVPixelBufferLockBaseAddress(srcBuf, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dstBuf, 0);
    size_t dataSize = CVPixelBufferGetDataSize(srcBuf);
    uint8_t *src = (uint8_t *)CVPixelBufferGetBaseAddress(srcBuf);
    uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(dstBuf);
    for (size_t i = 0; i < dataSize; i++) {
        dst[i] = src[i] ^ kAdapterXorByte;
    }
    CVPixelBufferUnlockBaseAddress(dstBuf, 0);
    CVPixelBufferUnlockBaseAddress(srcBuf, kCVPixelBufferLock_ReadOnly);

    VGFrameEnvelope result = envelope;
    result.payload.videoBuffer = dstBuf;
    return result;
}

@end

#pragma mark - VGAdapterParityTest

@interface VGAdapterParityTest : XCTestCase
@end

@implementation VGAdapterParityTest {
    id<MTLDevice>          _device;
    CVPixelBufferRef       _testBuffer;
    VGAdapterP_MockFilter  *_mockFilter;
    VGLegacyFilterAdapter  *_adapter;
}

- (CVPixelBufferRef)_makeTestBufferFilledWith:(uint8_t)value CF_RETURNS_RETAINED {
    NSDictionary *attrs = @{ (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    CVPixelBufferRef buf = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)attrs, &buf);
    if (status != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(buf, 0);
    memset(CVPixelBufferGetBaseAddress(buf), value, CVPixelBufferGetDataSize(buf));
    CVPixelBufferUnlockBaseAddress(buf, 0);
    return buf;
}

- (int)_maxDeltaBetween:(CVPixelBufferRef)a and:(CVPixelBufferRef)b {
    if (!a || !b) return -1;
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    size_t sizeA = CVPixelBufferGetDataSize(a);
    size_t sizeB = CVPixelBufferGetDataSize(b);
    int maxDelta = 0;
    if (sizeA == sizeB) {
        const uint8_t *pa = (const uint8_t *)CVPixelBufferGetBaseAddress(a);
        const uint8_t *pb = (const uint8_t *)CVPixelBufferGetBaseAddress(b);
        for (size_t i = 0; i < sizeA; i++) {
            int d = abs((int)pa[i] - (int)pb[i]);
            if (d > maxDelta) maxDelta = d;
        }
    } else {
        maxDelta = -2;
    }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    return maxDelta;
}

- (void)setUp {
    [super setUp];
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        NSLog(@"[VGAdapterParityTest] Skipping — no Metal device (simulator)");
        return;
    }
    _testBuffer = [self _makeTestBufferFilledWith:0x55];
    XCTAssertTrue(_testBuffer != NULL, @"Test buffer must be created");
    _mockFilter = [[VGAdapterP_MockFilter alloc] init];
    _adapter    = [[VGLegacyFilterAdapter alloc] initWithFilter:_mockFilter];
}

- (void)tearDown {
    if (_testBuffer) { CVPixelBufferRelease(_testBuffer); _testBuffer = NULL; }
    _adapter    = nil;
    _mockFilter = nil;
    [super tearDown];
}

- (VGFrameEnvelope)_buildEnvelope {
    VGFrameEnvelope env;
    memset(&env, 0, sizeof(VGFrameEnvelope));
    env.payload.videoBuffer = _testBuffer;
    env.pts                 = CMTimeMakeWithSeconds(1.0, 600);
    env.generation          = 1;
    env.mediaType           = VGMediaTypeVideo;
    env.metadata            = NULL;
    return env;
}

// ─── Test 1: Adapter delegates processEnvelope:device: ───────────────────────
// Direct call and adapter call must produce identical pixel output.

- (void)testAdapterDelegatesProcessEnvelope {
    if (!_device) return;

    VGFrameEnvelope env = [self _buildEnvelope];

    // Direct call through VGMetalFilterNode
    VGFrameEnvelope directResult = [_mockFilter processEnvelope:env device:_device];
    CVPixelBufferRef directBuf = (CVPixelBufferRef)directResult.payload.videoBuffer;
    XCTAssertTrue(directBuf != NULL, @"Direct call must return a non-null buffer");

    // Call through VGLegacyFilterAdapter (VGTransformNode path)
    VGFrameEnvelope adapterResult = [_adapter processEnvelope:env device:_device];
    CVPixelBufferRef adapterBuf = (CVPixelBufferRef)adapterResult.payload.videoBuffer;
    XCTAssertTrue(adapterBuf != NULL, @"Adapter call must return a non-null buffer");

    // Both must produce identical pixel output
    int delta = [self _maxDeltaBetween:directBuf and:adapterBuf];
    XCTAssertEqual(delta, 0,
                   @"Direct and adapter outputs must be identical (delta=%d)", delta);

    // Caller owns +1 on filter-produced buffers — release both
    if (directBuf)  CVPixelBufferRelease(directBuf);
    if (adapterBuf) CVPixelBufferRelease(adapterBuf);
}

// ─── Test 2: adapter.enabled mirrors filter.enabled ──────────────────────────

- (void)testAdapterDelegatesEnabled {
    if (!_device) return;

    _mockFilter.enabled = YES;
    XCTAssertTrue(_adapter.enabled, @"Adapter must reflect filter.enabled=YES");

    _mockFilter.enabled = NO;
    XCTAssertFalse(_adapter.enabled, @"Adapter must reflect filter.enabled=NO");

    // Restore
    _mockFilter.enabled = YES;
}

// ─── Test 3: adapter.estimatedGPUCostMs mirrors filter.estimatedGPUCostMs ────

- (void)testAdapterDelegatesEstimatedGPUCostMs {
    if (!_device) return;

    float direct  = _mockFilter.estimatedGPUCostMs;
    float adapted = _adapter.estimatedGPUCostMs;
    XCTAssertEqualWithAccuracy(adapted, direct, 0.001f,
        @"Adapter must forward estimatedGPUCostMs exactly (direct=%.3f adapted=%.3f)",
        direct, adapted);
}

// ─── Test 4: Adapter passthrough when enabled=NO ─────────────────────────────

- (void)testAdapterPassthroughWhenDisabled {
    if (!_device) return;

    _mockFilter.enabled = NO;

    VGFrameEnvelope env = [self _buildEnvelope];
    VGFrameEnvelope result = [_adapter processEnvelope:env device:_device];
    CVPixelBufferRef resultBuf = (CVPixelBufferRef)result.payload.videoBuffer;

    // Disabled adapter must return input envelope unchanged (same buffer pointer)
    XCTAssertEqual(resultBuf, (CVPixelBufferRef)env.payload.videoBuffer,
                   @"Disabled adapter must return input buffer unchanged");

    // Restore
    _mockFilter.enabled = YES;
    // No release: result is passthrough (source-owned, not scheduler-owned)
}

@end
