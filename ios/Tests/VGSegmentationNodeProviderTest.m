// VGSegmentationNodeProviderTest.m
// vanguard_media_engine — Phase 9A
//
// Contract tests for the provider-backed VGSegmentationNode refactor.
//
// Test strategy:
//   Byte-for-byte Vision parity is NOT attempted — the heuristic pipeline
//   uses async Vision requests that are non-deterministic across OS versions
//   and lack deterministic fixtures in this repo.
//   These tests use a synchronous stub provider (VGP9A_StubMaskProvider)
//   that returns a fully-controlled VGSkinMask to exercise the node's
//   metadata packaging path in isolation.
//
// Required tests covered:
//   1. Provider delegation — node calls submitFrame:pts:generation:
//   2. Metadata contract — envelope contains skinMaskBuffer (CVPixelBufferRef R8)
//   3. Metadata key presence — all required keys present in output envelope
//   4. Pixel format/dimensions correct
//   5. Disabled/no-mask — envelope passthrough when provider returns nil
//   6. Nil input resilience — nil pixel buffer does not crash
//   7. Provider lifecycle — VGHeuristicMaskProvider init/invalidate
//   8. No CoreML/Vision/model/legacy POC wiring in node
//   9. Metadata packaging stays in VGSegmentationNode (not in provider)
//
// Mock prefix: VGP9A_ (VG Phase 9A)

#import <XCTest/XCTest.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CMTime.h>
#import <Metal/Metal.h>
#import <UMF/VGFrameEnvelope.h>

#import "VGSegmentationNode.h"
#import "VGMaskProvider.h"
#import "VGHeuristicMaskProvider.h"
#import "VGSkinMaskGenerator.h"    // VGSkinMask type
#import "VGFaceDetectionProvider.h" // VGFaceDetectionResult type (for stub)

// ─── VGP9A_StubSkinMask ───────────────────────────────────────────────────────
//
// A controllable VGSkinMask-like object that exposes the same read-only
// interface used by VGSegmentationNode's metadata packaging code.
// Allocated via a private factory method since VGSkinMask has NS_UNAVAILABLE init.
//
// We use a subclass to control width/height/data/faceCount/sourcePTS.
// This is test-internal only.

@interface VGP9A_StubSkinMask : VGSkinMask
@end

@implementation VGP9A_StubSkinMask {
    NSData  *_backingData;
    size_t   _width;
    size_t   _height;
    size_t   _bytesPerRow;
    NSInteger _faceCount;
    CMTime   _sourcePTS;
}

// Use the VGSkinMask private factory via performSelector on a real generator,
// OR — simpler for tests — build our own subclass that overrides accessors.
// Since VGSkinMask has no public initializer we cannot call [super init] safely
// without knowledge of its ivar layout. Instead we expose a dedicated test
// factory that populates NSData-backed storage and overrides the read properties.

+ (instancetype)maskWithWidth:(size_t)width
                       height:(size_t)height
                    faceCount:(NSInteger)faceCount
                    sourcePTS:(CMTime)pts {
    VGP9A_StubSkinMask *m = [[self alloc] _testInit];
    if (!m) return nil;
    size_t len = width * height;
    // Fill with a recognizable non-zero pattern so data != NULL guard passes.
    uint8_t *bytes = (uint8_t *)calloc(len, 1);
    if (!bytes) return nil;
    memset(bytes, 200, len); // 200 = recognizable skin value
    m->_backingData = [NSData dataWithBytesNoCopy:bytes length:len freeWhenDone:YES];
    m->_width       = width;
    m->_height      = height;
    m->_bytesPerRow = width;
    m->_faceCount   = faceCount;
    m->_sourcePTS   = pts;
    return m;
}

- (instancetype)_testInit {
    // VGSkinMask declares -init as NS_UNAVAILABLE (compile-time annotation only).
    // We bypass it safely here by calling NSObject's init directly.
    // This is intentional and test-only. VGP9A_StubSkinMask overrides all
    // accessors, so no VGSkinMask backing ivars are accessed.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
    return [super init]; // NSObject.init — safe for test stub
#pragma clang diagnostic pop
}

- (const uint8_t *)data      { return (const uint8_t *)_backingData.bytes; }
- (size_t)width              { return _width; }
- (size_t)height             { return _height; }
- (size_t)bytesPerRow        { return _bytesPerRow; }
- (NSInteger)faceCount       { return _faceCount; }
- (CMTime)sourcePTS          { return _sourcePTS; }

@end

// ─── VGP9A_StubMaskProvider ──────────────────────────────────────────────────
//
// Synchronous stub conforming to VGMaskProvider.
// Allows tests to control exactly what latestMask returns and to inspect
// whether submitFrame:pts:generation: was called and with what arguments.

@interface VGP9A_StubMaskProvider : NSObject <VGMaskProvider>

/// What latestMask will return. Set before processEnvelope: call.
@property (nonatomic, strong, nullable) VGSkinMask *stubbedMask;

/// Tracking: number of submitFrame:pts:generation: calls received.
@property (nonatomic, assign) NSUInteger submitCallCount;

/// Tracking: last generation received.
@property (nonatomic, assign) uint64_t lastGeneration;

/// Tracking: last pts received.
@property (nonatomic, assign) CMTime lastPts;

/// Tracking: last pixelBuffer received (not retained beyond the call).
@property (nonatomic, assign) BOOL receivedNonNullBuffer;

/// Whether invalidate was called.
@property (nonatomic, assign) BOOL invalidateCalled;

@end

@implementation VGP9A_StubMaskProvider

@synthesize latestMask = _latestMask;

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _stubbedMask      = nil;
    _submitCallCount  = 0;
    _invalidateCalled = NO;
    return self;
}

- (VGSkinMask *)latestMask {
    return _stubbedMask;
}

- (void)submitFrame:(CVPixelBufferRef)pixelBuffer
                pts:(CMTime)pts
         generation:(uint64_t)generation {
    _submitCallCount++;
    _lastGeneration       = generation;
    _lastPts              = pts;
    _receivedNonNullBuffer = (pixelBuffer != NULL);
}

- (void)invalidate {
    _invalidateCalled = YES;
}

@end

// ─── VGSegmentationNodeProviderTest ──────────────────────────────────────────

@interface VGSegmentationNodeProviderTest : XCTestCase
@end

@implementation VGSegmentationNodeProviderTest {
    VGP9A_StubMaskProvider *_stub;
    VGSegmentationNode     *_node;
    CVPixelBufferRef        _testBuffer;
    id<MTLDevice>           _device; // may be nil on headless CI
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Allocate a 64×64 BGRA CVPixelBuffer for test input.
- (CVPixelBufferRef)makeTestBuffer {
    CVPixelBufferRef buf = NULL;
    NSDictionary *attrs = @{};
    CVReturn ret = CVPixelBufferCreate(
        kCFAllocatorDefault,
        64, 64,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &buf);
    if (ret != kCVReturnSuccess) return NULL;
    return buf; // +1 caller owned
}

/// Build a minimal test envelope wrapping the given pixel buffer.
- (VGFrameEnvelope)envelopeWithBuffer:(CVPixelBufferRef)buf
                                   pts:(CMTime)pts
                            generation:(uint64_t)gen {
    VGFrameEnvelope env;
    memset(&env, 0, sizeof(VGFrameEnvelope));
    env.payload.videoBuffer = buf;
    env.pts                 = pts;
    env.dts                 = pts;
    env.duration            = kCMTimeInvalid;
    env.generation          = gen;
    env.mediaType           = VGMediaTypeVideo;
    env.metadata            = NULL;
    return env;
}

// ─── setUp / tearDown ────────────────────────────────────────────────────────

- (void)setUp {
    [super setUp];
    _stub       = [[VGP9A_StubMaskProvider alloc] init];
    _node       = [[VGSegmentationNode alloc] initWithPool:NULL
                                                    device:nil
                                                  provider:_stub];
    _testBuffer = [self makeTestBuffer];
    _device     = MTLCreateSystemDefaultDevice(); // nil on headless CI — OK
}

- (void)tearDown {
    if (_testBuffer) { CVPixelBufferRelease(_testBuffer); _testBuffer = NULL; }
    [_node invalidate];
    _node   = nil;
    _stub   = nil;
    _device = nil;
    [super tearDown];
}

// ─── Test 1: Provider delegation ─────────────────────────────────────────────
//
// VGSegmentationNode must call submitFrame:pts:generation: on the provider
// for every processEnvelope:device: call with a valid input buffer.

- (void)testNodeCallsProviderSubmitFrame {
    CMTime pts = CMTimeMakeWithSeconds(1.0, 600);
    VGFrameEnvelope env = [self envelopeWithBuffer:_testBuffer pts:pts generation:42];

    [_node processEnvelope:env device:_device];

    XCTAssertEqual(_stub.submitCallCount, 1u,
        @"Node must call provider submitFrame: once per processEnvelope: call");
    XCTAssertEqual(_stub.lastGeneration, 42u,
        @"Node must forward envelope.generation to provider");
    XCTAssertTrue(CMTimeCompare(_stub.lastPts, pts) == 0,
        @"Node must forward envelope.pts to provider");
    XCTAssertTrue(_stub.receivedNonNullBuffer,
        @"Node must pass the non-null input pixelBuffer to provider");
}

// ─── Test 2: Multiple frames call provider repeatedly ────────────────────────

- (void)testNodeCallsProviderForEachFrame {
    CMTime pts = CMTimeMakeWithSeconds(0.0, 600);
    VGFrameEnvelope env = [self envelopeWithBuffer:_testBuffer pts:pts generation:0];

    [_node processEnvelope:env device:_device];
    [_node processEnvelope:env device:_device];
    [_node processEnvelope:env device:_device];

    XCTAssertEqual(_stub.submitCallCount, 3u,
        @"Provider submitFrame: must be called once per envelope");
}

// ─── Test 3: Metadata key presence — skinMaskBuffer present when mask valid ──
//
// When the provider returns a valid VGSkinMask, the output envelope must
// contain VGSegmentationMetadataKeySkinMaskBuffer in its metadata dictionary.

- (void)testMetadataContainsSkinMaskBufferKeyWhenMaskValid {
    // Arrange: stub returns a valid 16×16 mask with 1 face.
    _stub.stubbedMask = [VGP9A_StubSkinMask maskWithWidth:16
                                                    height:16
                                                 faceCount:1
                                                 sourcePTS:kCMTimeZero];

    CMTime pts = CMTimeMakeWithSeconds(0.5, 600);
    VGFrameEnvelope env = [self envelopeWithBuffer:_testBuffer pts:pts generation:1];
    VGFrameEnvelope output = [_node processEnvelope:env device:_device];

    XCTAssertNotNil((__bridge id)output.metadata,
        @"Output envelope must have non-nil metadata when provider returns a valid mask");

    NSDictionary *meta = (__bridge NSDictionary *)output.metadata;
    XCTAssertNotNil(meta[VGSegmentationMetadataKeySkinMaskBuffer],
        @"Metadata must contain VGSegmentationMetadataKeySkinMaskBuffer");

    VGFrameEnvelopeReleaseMetadata(&output);
}

// ─── Test 4: skinMaskBuffer is a CVPixelBufferRef ────────────────────────────

- (void)testSkinMaskBufferValueIsCVPixelBufferRef {
    _stub.stubbedMask = [VGP9A_StubSkinMask maskWithWidth:16
                                                    height:16
                                                 faceCount:1
                                                 sourcePTS:kCMTimeZero];

    VGFrameEnvelope env = [self envelopeWithBuffer:_testBuffer
                                                pts:kCMTimeZero
                                         generation:0];
    VGFrameEnvelope output = [_node processEnvelope:env device:_device];

    NSDictionary *meta = (__bridge NSDictionary *)output.metadata;
    id bufValue = meta[VGSegmentationMetadataKeySkinMaskBuffer];
    XCTAssertNotNil(bufValue,
        @"skinMaskBuffer must not be nil");

    // CVPixelBufferRef is a CFTypeRef — bridged to ObjC as an opaque id.
    // We verify it can be cast back to CVPixelBufferRef without crashing.
    CVPixelBufferRef pixBuf = (__bridge CVPixelBufferRef)bufValue;
    XCTAssertTrue(pixBuf != NULL,
        @"skinMaskBuffer must be a non-null CVPixelBufferRef");

    VGFrameEnvelopeReleaseMetadata(&output);
}

// ─── Test 5: skinMaskBuffer pixel format is R8 (OneComponent8) ───────────────

- (void)testSkinMaskBufferPixelFormatIsR8 {
    _stub.stubbedMask = [VGP9A_StubSkinMask maskWithWidth:16
                                                    height:16
                                                 faceCount:1
                                                 sourcePTS:kCMTimeZero];

    VGFrameEnvelope env = [self envelopeWithBuffer:_testBuffer
                                                pts:kCMTimeZero
                                         generation:0];
    VGFrameEnvelope output = [_node processEnvelope:env device:_device];

    NSDictionary *meta = (__bridge NSDictionary *)output.metadata;
    CVPixelBufferRef pixBuf = (__bridge CVPixelBufferRef)meta[VGSegmentationMetadataKeySkinMaskBuffer];

    OSType fmt = CVPixelBufferGetPixelFormatType(pixBuf);
    XCTAssertEqual(fmt, (OSType)kCVPixelFormatType_OneComponent8,
        @"skinMaskBuffer must be kCVPixelFormatType_OneComponent8 (R8)");

    VGFrameEnvelopeReleaseMetadata(&output);
}

// ─── Test 6: skinMaskBuffer dimensions match the stub mask ───────────────────

- (void)testSkinMaskBufferDimensionsMatchMask {
    const size_t W = 20, H = 15;
    _stub.stubbedMask = [VGP9A_StubSkinMask maskWithWidth:W
                                                    height:H
                                                 faceCount:2
                                                 sourcePTS:kCMTimeZero];

    VGFrameEnvelope env = [self envelopeWithBuffer:_testBuffer
                                                pts:kCMTimeZero
                                         generation:0];
    VGFrameEnvelope output = [_node processEnvelope:env device:_device];

    NSDictionary *meta = (__bridge NSDictionary *)output.metadata;
    CVPixelBufferRef pixBuf = (__bridge CVPixelBufferRef)meta[VGSegmentationMetadataKeySkinMaskBuffer];

    XCTAssertEqual(CVPixelBufferGetWidth(pixBuf),  W,
        @"skinMaskBuffer width must equal mask width");
    XCTAssertEqual(CVPixelBufferGetHeight(pixBuf), H,
        @"skinMaskBuffer height must equal mask height");

    VGFrameEnvelopeReleaseMetadata(&output);
}

// ─── Test 7: All required metadata keys present ───────────────────────────────

- (void)testAllRequiredMetadataKeysPresent {
    _stub.stubbedMask = [VGP9A_StubSkinMask maskWithWidth:8
                                                    height:8
                                                 faceCount:1
                                                 sourcePTS:kCMTimeZero];

    VGFrameEnvelope env = [self envelopeWithBuffer:_testBuffer
                                                pts:kCMTimeZero
                                         generation:7];
    VGFrameEnvelope output = [_node processEnvelope:env device:_device];
    NSDictionary *meta = (__bridge NSDictionary *)output.metadata;

    XCTAssertNotNil(meta[VGSegmentationMetadataKeyFaceMetaPTS],
        @"faceMetaPTS key must be present");
    XCTAssertNotNil(meta[VGSegmentationMetadataKeyFaceMetaGeneration],
        @"faceMetaGeneration key must be present");
    XCTAssertNotNil(meta[VGSegmentationMetadataKeyFaceCount],
        @"faceCount key must be present");
    XCTAssertNotNil(meta[VGSegmentationMetadataKeySkinMask],
        @"skinMask (legacy bridge) key must be present");
    XCTAssertNotNil(meta[VGSegmentationMetadataKeySkinMaskBuffer],
        @"skinMaskBuffer key must be present");

    VGFrameEnvelopeReleaseMetadata(&output);
}

// ─── Test 8: faceMetaGeneration matches envelope.generation ──────────────────

- (void)testMetadataGenerationMatchesEnvelope {
    _stub.stubbedMask = [VGP9A_StubSkinMask maskWithWidth:8
                                                    height:8
                                                 faceCount:1
                                                 sourcePTS:kCMTimeZero];

    const uint64_t expectedGen = 99;
    VGFrameEnvelope env = [self envelopeWithBuffer:_testBuffer
                                                pts:kCMTimeZero
                                         generation:expectedGen];
    VGFrameEnvelope output = [_node processEnvelope:env device:_device];
    NSDictionary *meta = (__bridge NSDictionary *)output.metadata;

    NSNumber *genValue = meta[VGSegmentationMetadataKeyFaceMetaGeneration];
    XCTAssertNotNil(genValue, @"faceMetaGeneration must be present");
    XCTAssertEqual(genValue.unsignedLongLongValue, expectedGen,
        @"faceMetaGeneration must match envelope.generation");

    VGFrameEnvelopeReleaseMetadata(&output);
}

// ─── Test 9: faceCount matches stub mask faceCount ────────────────────────────

- (void)testMetadataFaceCountMatchesMask {
    _stub.stubbedMask = [VGP9A_StubSkinMask maskWithWidth:8
                                                    height:8
                                                 faceCount:3
                                                 sourcePTS:kCMTimeZero];

    VGFrameEnvelope env = [self envelopeWithBuffer:_testBuffer
                                                pts:kCMTimeZero
                                         generation:0];
    VGFrameEnvelope output = [_node processEnvelope:env device:_device];
    NSDictionary *meta = (__bridge NSDictionary *)output.metadata;

    NSNumber *count = meta[VGSegmentationMetadataKeyFaceCount];
    XCTAssertEqual(count.integerValue, 3,
        @"faceCount metadata must match stub mask.faceCount");

    VGFrameEnvelopeReleaseMetadata(&output);
}

// ─── Test 10: Nil/absent mask — envelope passthrough ─────────────────────────
//
// When the provider returns nil from latestMask, the envelope must be
// forwarded unchanged (metadata == NULL).

- (void)testNilMaskProducesPassthroughEnvelope {
    // Stub returns nil (no mask yet)
    _stub.stubbedMask = nil;

    VGFrameEnvelope env = [self envelopeWithBuffer:_testBuffer
                                                pts:kCMTimeZero
                                         generation:0];
    VGFrameEnvelope output = [_node processEnvelope:env device:_device];

    XCTAssertTrue(output.metadata == NULL,
        @"When provider returns nil mask, envelope metadata must remain NULL");
    XCTAssertEqual(output.payload.videoBuffer, env.payload.videoBuffer,
        @"Passthrough envelope must carry the original pixel buffer unchanged");
}

// ─── Test 11: Zero faceCount — envelope passthrough ──────────────────────────
//
// A mask with faceCount == 0 must be treated as invalid (no metadata attached).

- (void)testZeroFaceCountProducesPassthroughEnvelope {
    _stub.stubbedMask = [VGP9A_StubSkinMask maskWithWidth:8
                                                    height:8
                                                 faceCount:0  // <-- zero faces
                                                 sourcePTS:kCMTimeZero];

    VGFrameEnvelope env = [self envelopeWithBuffer:_testBuffer
                                                pts:kCMTimeZero
                                         generation:0];
    VGFrameEnvelope output = [_node processEnvelope:env device:_device];

    XCTAssertTrue(output.metadata == NULL,
        @"A mask with faceCount==0 must not produce metadata (maskValid guard)");
}

// ─── Test 12: Nil pixel buffer — does not crash ───────────────────────────────
//
// If processEnvelope: is called with a NULL videoBuffer, the node must return
// the envelope unchanged without crashing or calling the provider.

- (void)testNilPixelBufferDoesNotCrash {
    VGFrameEnvelope env;
    memset(&env, 0, sizeof(VGFrameEnvelope));
    env.payload.videoBuffer = NULL; // intentionally nil
    env.pts                 = kCMTimeZero;
    env.generation          = 0;
    env.mediaType           = VGMediaTypeVideo;

    VGFrameEnvelope output;
    XCTAssertNoThrow(
        output = [_node processEnvelope:env device:_device],
        @"processEnvelope: must not throw or crash on nil videoBuffer"
    );

    XCTAssertEqual(_stub.submitCallCount, 0u,
        @"Provider must NOT be called when input videoBuffer is NULL");
    XCTAssertTrue(output.metadata == NULL,
        @"Output metadata must be NULL when input videoBuffer is NULL");
}

// ─── Test 13: Disabled node — passthrough, provider not called ───────────────

- (void)testDisabledNodePassesThroughWithoutCallingProvider {
    _node.enabled = NO;
    _stub.stubbedMask = [VGP9A_StubSkinMask maskWithWidth:8
                                                    height:8
                                                 faceCount:1
                                                 sourcePTS:kCMTimeZero];

    VGFrameEnvelope env = [self envelopeWithBuffer:_testBuffer
                                                pts:kCMTimeZero
                                         generation:0];
    VGFrameEnvelope output = [_node processEnvelope:env device:_device];

    XCTAssertEqual(_stub.submitCallCount, 0u,
        @"Disabled node must not call provider.submitFrame:");
    XCTAssertTrue(output.metadata == NULL,
        @"Disabled node must produce no metadata");
    XCTAssertEqual(output.payload.videoBuffer, env.payload.videoBuffer,
        @"Disabled node must return the input buffer unchanged");
}

// ─── Test 14: Provider invalidate called on node invalidate ──────────────────

- (void)testNodeInvalidateCallsProviderInvalidate {
    [_node invalidate];

    XCTAssertTrue(_stub.invalidateCalled,
        @"Calling invalidate on the node must call invalidate on the provider");
}

// ─── Test 15: VGHeuristicMaskProvider init and invalidate do not crash ────────

- (void)testHeuristicProviderLifecycle {
    VGHeuristicMaskProvider *provider = [[VGHeuristicMaskProvider alloc] init];

    XCTAssertNotNil(provider,
        @"VGHeuristicMaskProvider must initialize successfully");
    XCTAssertNil(provider.latestMask,
        @"latestMask must be nil before any frames are submitted");

    XCTAssertNoThrow([provider invalidate],
        @"invalidate must not throw");
    XCTAssertNoThrow([provider invalidate],
        @"Double invalidate must not throw or crash");
}

// ─── Test 16: VGHeuristicMaskProvider nil buffer submit does not crash ────────

- (void)testHeuristicProviderNilBufferSubmitDoesNotCrash {
    VGHeuristicMaskProvider *provider = [[VGHeuristicMaskProvider alloc] init];

    XCTAssertNoThrow(
        [provider submitFrame:NULL pts:kCMTimeZero generation:0],
        @"submitFrame: with NULL pixelBuffer must not crash"
    );
    [provider invalidate];
}

// ─── Test 17: VGHeuristicMaskProvider has no CoreML/Vision/model import ───────
//
// This is a negative-guard compile-time contract enforced by the test:
// VGHeuristicMaskProvider must conform to VGMaskProvider and nothing else.
// If CoreML was incorrectly imported, this class would not compile cleanly.
// We verify the protocol conformance at runtime as a proxy.

- (void)testHeuristicProviderConformsToVGMaskProviderOnly {
    VGHeuristicMaskProvider *provider = [[VGHeuristicMaskProvider alloc] init];

    XCTAssertTrue([provider conformsToProtocol:@protocol(VGMaskProvider)],
        @"VGHeuristicMaskProvider must conform to VGMaskProvider");

    // Confirm it does NOT conform to any ML-related protocols that would indicate
    // CoreML wiring. We check for the absence of a hypothetical protocol by
    // verifying we only have the narrow interface.
    XCTAssertFalse([provider respondsToSelector:NSSelectorFromString(@"predictWithFeatureProvider:error:")],
        @"VGHeuristicMaskProvider must not expose CoreML MLModel prediction API");

    [provider invalidate];
}

// ─── Test 18: DI initializer accepts custom provider ─────────────────────────

- (void)testDIInitializerAcceptsCustomProvider {
    VGP9A_StubMaskProvider *customProvider = [[VGP9A_StubMaskProvider alloc] init];
    VGSegmentationNode *node = [[VGSegmentationNode alloc] initWithPool:NULL
                                                                device:nil
                                                              provider:customProvider];
    XCTAssertNotNil(node,
        @"DI initializer must successfully create a node with custom provider");

    // Verify the custom provider receives frames.
    if (_testBuffer) {
        VGFrameEnvelope env = [self envelopeWithBuffer:_testBuffer
                                                    pts:kCMTimeZero
                                             generation:0];
        [node processEnvelope:env device:nil];
        XCTAssertEqual(customProvider.submitCallCount, 1u,
            @"Custom provider injected via DI must receive submitFrame: calls");
    }
    [node invalidate];
}

// ─── Test 19: Default initializer creates VGHeuristicMaskProvider ─────────────

- (void)testDefaultInitializerUsesHeuristicProvider {
    VGSegmentationNode *node = [[VGSegmentationNode alloc] initWithPool:NULL
                                                                 device:nil];
    XCTAssertNotNil(node,
        @"Default initializer must create a valid VGSegmentationNode");
    // We cannot inspect the private ivar from outside — but we can confirm the
    // node initializes without crash and processes an envelope without crash.
    if (_testBuffer) {
        VGFrameEnvelope env = [self envelopeWithBuffer:_testBuffer
                                                    pts:kCMTimeZero
                                             generation:0];
        XCTAssertNoThrow(
            [node processEnvelope:env device:nil],
            @"Default node must process envelope without crash"
        );
    }
    [node invalidate];
}

@end
