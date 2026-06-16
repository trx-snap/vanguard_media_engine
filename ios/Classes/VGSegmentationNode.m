// VGSegmentationNode.m
// Phase 4F — Step 1: VGSegmentationNode extraction (DEC-100).
// Phase B  — Step 3 temporal stability (DEC-117): generation reset + adaptive EMA.
// Phase C  — Step 4 semantic accuracy (DEC-119): YCbCr chroma extraction for skin verification.
// Phase 9A — Provider-backed architecture: delegates frame submission and mask
//            retrieval to an id<VGMaskProvider> (default: VGHeuristicMaskProvider).
//
// Behavior preserved exactly:
//   - processEnvelope: output metadata is identical to the pre-9A implementation.
//   - skinMaskBuffer CVPixelBufferRef ownership/lifetime contract unchanged.
//   - Legacy VGSkinMask metadata key preserved for BeautyV2 fallback.
//   - processBuffer: (legacy VanguardFilterNode path) behavior unchanged.
//
// State migrated to VGHeuristicMaskProvider (no longer lives here):
//   _faceDetectionProvider
//   _skinMaskGenerator
//   _lastMaskDetectionTime
//   _lastGeneration / _lastGenerationValid
//   _chromaDownBuffer / _chromaDownBufferSize
//
// State remaining here (metadata packaging only):
//   _maskProvider (id<VGMaskProvider>) — the active provider
//
// Ownership rules:
//   CVPixelBufferCreateWithBytes, _VGMaskBufferReleaseCallback, and the
//   metadata NSDictionary are all created and owned here, not in the provider.
//   This preserves the existing NSData / CVPixelBuffer lifetime contract exactly.

#import "VGSegmentationNode.h"
#import "VGMaskProvider.h"
#import "VGHeuristicMaskProvider.h"
#import "VGSkinMaskGenerator.h"  // VGSkinMask type
#import "VGFaceDetectionProvider.h"  // Phase 9B-Reset POC-C: face tracking metadata
#import <CoreVideo/CoreVideo.h>
#import <os/log.h>

// ─── Metadata keys ───────────────────────────────────────────────────────────

NSString * const VGSegmentationMetadataKeyFaceMetaPTS         = @"faceMetaPTS";
NSString * const VGSegmentationMetadataKeyFaceMetaGeneration  = @"faceMetaGeneration";
NSString * const VGSegmentationMetadataKeyFaceCount           = @"faceCount";
NSString * const VGSegmentationMetadataKeySkinMask            = @"skinMask";         // legacy bridge
NSString * const VGSegmentationMetadataKeySkinMaskBuffer      = @"skinMaskBuffer";   // DEC-121: CVPixelBufferRef R8
// Phase 9B-Reset POC-C: face tracking result (VGFaceDetectionResult *)
NSString * const VGSegmentationMetadataKeyFaceTrackingResult  = @"faceTrackingResult";

// ---------------------------------------------------------------------------
// CVPixelBufferReleaseBytesCallback for the mask pixel buffer (DEC-121).
//
// CVPixelBufferReleaseBytesCallback is a plain C function pointer — it cannot
// be an Objective-C block. releaseRefCon carries the __bridge_retained NSData*
// that backs the R8 bytes; CFRelease here balances that retain.
// ---------------------------------------------------------------------------
static void _VGMaskBufferReleaseCallback(void *releaseRefCon,
                                         const void *baseAddress) {
    (void)baseAddress; // unused
    CFRelease(releaseRefCon); // releases the retained NSData*
}

// ─── Implementation ──────────────────────────────────────────────────────────

@implementation VGSegmentationNode {
    // ── Identity ─────────────────────────────────────────────────────────────
    NSString *_nodeId;
    NSString *_nodeType;
    NSString *_filterName;

    // ── Phase 9A: mask provider ───────────────────────────────────────────────
    // Default: VGHeuristicMaskProvider (wraps VGFaceDetectionProvider +
    // VGSkinMaskGenerator + generation/chroma state).
    // In tests: replaced with a stub conforming to VGMaskProvider.
    id<VGMaskProvider> _maskProvider;

    // ── Phase 9B-Reset POC-C: face tracking provider ─────────────────────────
    // Separate from the mask provider's internal VGFaceDetectionProvider.
    // Purpose: supply near-current-frame (cadence=1) face tracking metadata
    // to the envelope so BeautyV2 can measure relative staleness vs. the
    // stale ML mask. Does not affect mask generation in any way.
    // Lifecycle: created in init, invalidated in invalidate/dealloc.
    // Threading: detectInPixelBuffer: is non-blocking; result is read atomically.
    VGFaceDetectionProvider *_faceTrackingProvider;
}

@synthesize nodeId     = _nodeId;
@synthesize nodeType   = _nodeType;
@synthesize filterName = _filterName;
@synthesize enabled    = _enabled;

// ─── VGMediaNode topology ────────────────────────────────────────────────────

- (VGNodeRole)nodeRole {
    return VGNodeRoleFilter;
}

// ─── VGMetalFilterNode cost model ────────────────────────────────────────────

// CPU-only — zero GPU cost. However, face detection is CPU-intensive.
- (BOOL)isExpensive {
    return YES;
}

- (float)estimatedGPUCostMs {
    return 0.0f; // CPU-only node — no GPU dispatch
}

// ─── Init ────────────────────────────────────────────────────────────────────

- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device {
    return [self initWithPool:pool
                       device:device
                     provider:[[VGHeuristicMaskProvider alloc] init]];
}

- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
                    provider:(id<VGMaskProvider>)provider {
    self = [super init];
    if (!self) return nil;

    _nodeId     = [[NSUUID UUID] UUIDString];
    _nodeType   = @"VGSegmentationNode";
    _filterName = @"Segmentation";
    _enabled    = YES;

    // Phase 9A: delegate all heuristic work to the provider.
    _maskProvider = provider;

    // Phase 9B-Reset POC-C: independent face tracking provider.
    // cadence=1: detect every frame (self-throttled by _detectionInFlight).
    // maxFaces=1: single-face optimisation — beauty mask targets primary face.
    _faceTrackingProvider = [[VGFaceDetectionProvider alloc] initWithCadenceFrames:1];
    _faceTrackingProvider.maxFaces = 1;

    return self;
}

// ─── Lifecycle ───────────────────────────────────────────────────────────────

- (void)prepareWithCompletion:(void (^)(NSError * _Nullable))completion {
    // No preparation needed — provider is ready at init.
    if (completion) completion(nil);
}

- (void)invalidate {
    [_maskProvider invalidate];
    [_faceTrackingProvider invalidate];
}

- (void)dealloc {
    [_maskProvider invalidate];
    [_faceTrackingProvider invalidate];
}

// ─── VGMetalFilterNode: processEnvelope:device: ──────────────────────────────
//
// Core execution path. Called once per frame on the filter chain thread.
//
// This method:
//   1. Submits the input frame to the mask provider (never blocks)
//   2. Reads the latest mask from the provider
//   3. If a valid mask exists, creates metadata and attaches it to the envelope
//   4. Returns the envelope with the same video payload, optionally with metadata
//
// Memory safety:
//   The NSDictionary metadata is created as a local autoreleased object.
//   VGFrameEnvelopeCopyWithMetadata calls CFRetain on it (+1 for the envelope).
//   The consumer (scheduler/image-processor) must call VGFrameEnvelopeReleaseMetadata
//   to release the +1 when the envelope is discarded.

- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                            device:(id<MTLDevice>)device {
    // Gate: disabled → passthrough (no metadata)
    if (!_enabled) return envelope;

    CVPixelBufferRef input = (CVPixelBufferRef)envelope.payload.videoBuffer;
    if (!input) return envelope;

    // ── 1. Submit frame to the mask provider (never blocks) ──────────────────
    // The provider handles async face detection, chroma extraction, mask
    // generation, and generation-change temporal resets internally.
    [_maskProvider submitFrame:input pts:envelope.pts generation:envelope.generation];

    // ── 1b. Submit frame to face tracking provider (never blocks) ─────────────
    // Phase 9B-Reset POC-C: supplies near-current-frame face tracking metadata
    // for downstream staleness measurement. Independent of mask generation.
    // Self-throttled by _detectionInFlight — at most one Vision request in-flight.
    [_faceTrackingProvider detectInPixelBuffer:input pts:envelope.pts];

    // ── 2. Read latest mask from the provider ────────────────────────────────
    VGSkinMask *currentMask = _maskProvider.latestMask;
    BOOL maskValid = (currentMask &&
                      currentMask.width > 0 &&
                      currentMask.height > 0 &&
                      currentMask.data != NULL &&
                      currentMask.faceCount > 0);

    if (!maskValid) {
        // No valid mask — forward envelope unchanged (metadata=NULL).
        return envelope;
    }

    // ── 3. Create metadata NSDictionary ──────────────────────────────────────
    //
    // DEC-121: Primary payload is CVPixelBufferRef (kCVPixelFormatType_OneComponent8).
    // The CVPixelBuffer wraps the existing VGSkinMask R8 bytes zero-copy.
    //
    // Ownership model:
    //   - currentMask (VGSkinMask *) is ARC-retained; its backing NSData owns
    //     the R8 byte buffer. The CVPixelBuffer is created with a releaseCallback
    //     that releases the NSData retain, keeping the backing buffer alive for
    //     the full lifetime of the pixel buffer.
    //   - CVPixelBufferCreateWithBytes returns a +1 CF object. We transfer
    //     ownership to ARC via CFBridgingRelease, then store in the NSDictionary
    //     (ARC retains it). The NSDictionary is CFRetained by
    //     VGFrameEnvelopeCopyWithMetadata. Net result: the CVPixelBuffer lives
    //     at least as long as the envelope metadata.
    //   - The legacy VGSkinMask key is also included for the BeautyV2 fallback
    //     path until all consumers are fully migrated (DEC-121).
    //
    // Thread safety:
    //   currentMask is an immutable snapshot (ARC-retained). Its backing NSData
    //   is immutable. No locks needed for read-only access from this thread.

    // Retain the NSData backing so it outlives the pixel buffer creation.
    // The release callback will balance this retain.
    NSData *backingData = [NSData dataWithBytes:currentMask.data
                                         length:currentMask.width * currentMask.height];

    // Release callback: called by CoreVideo when the pixel buffer is freed.
    // Must be a plain C function pointer — ObjC blocks are NOT compatible with
    // CVPixelBufferReleaseBytesCallback. See _VGMaskBufferReleaseCallback above.
    CVPixelBufferRef maskPixelBuffer = NULL;
    CVReturn cvRet = CVPixelBufferCreateWithBytes(
        kCFAllocatorDefault,
        currentMask.width,           // width
        currentMask.height,          // height
        kCVPixelFormatType_OneComponent8,
        (void *)backingData.bytes,   // base address of R8 bytes
        currentMask.bytesPerRow,     // bytes per row (== width, no padding)
        _VGMaskBufferReleaseCallback,
        (__bridge_retained void *)backingData,  // releaseRefCon: retained NSData*
        nil,                         // pixelBufferAttributes
        &maskPixelBuffer
    );

    if (cvRet != kCVReturnSuccess || !maskPixelBuffer) {
        // CVPixelBuffer creation failed — release the retained backingData manually
        // (the release callback will NOT fire if Create failed).
        // Fall back to VGSkinMask-only metadata.
        CFRelease((__bridge CFTypeRef)backingData);
        VGFaceDetectionResult *trackingResultFallback = _faceTrackingProvider.latestResult;
        NSMutableDictionary *fallbackMeta = [NSMutableDictionary dictionaryWithDictionary:@{
            VGSegmentationMetadataKeyFaceMetaPTS:
                [NSValue valueWithCMTime:currentMask.sourcePTS],
            VGSegmentationMetadataKeyFaceMetaGeneration:
                @(envelope.generation),
            VGSegmentationMetadataKeyFaceCount:
                @(currentMask.faceCount),
            VGSegmentationMetadataKeySkinMask: currentMask,
        }];
        if (trackingResultFallback) {
            fallbackMeta[VGSegmentationMetadataKeyFaceTrackingResult] = trackingResultFallback;
        }
        NSDictionary *fallbackMetadata = [fallbackMeta copy];
        VGFrameEnvelope fallbackOutput = VGFrameEnvelopeCopyWithMetadata(
            envelope, (__bridge void *)fallbackMetadata);
        return fallbackOutput;
    }

    // maskPixelBuffer is at +1 (from CVPixelBufferCreateWithBytes).
    // Transfer ownership to ARC via CFBridgingRelease so it lives through the dict.
    id maskBufferObj = CFBridgingRelease(maskPixelBuffer);

    // Phase 9B-Reset POC-C: attach latest face tracking result if available.
    // The result is the latest-known VGFaceDetectionResult from the independent
    // tracking provider. It is NOT guaranteed to be current-frame — it is the
    // most recently completed async Vision detection (typically ~33ms stale).
    // Coordinate basis: Vision normalized [0,1], origin = bottom-left.
    // BeautyV2 must handle absence gracefully (key absent if nil).
    VGFaceDetectionResult *trackingResult = _faceTrackingProvider.latestResult;

    NSDictionary *metadata;
    if (trackingResult) {
        metadata = @{
            VGSegmentationMetadataKeyFaceMetaPTS:
                [NSValue valueWithCMTime:currentMask.sourcePTS],
            VGSegmentationMetadataKeyFaceMetaGeneration:
                @(envelope.generation),
            VGSegmentationMetadataKeyFaceCount:
                @(currentMask.faceCount),
            // DEC-121: Primary carrier — CVPixelBufferRef R8 (kCVPixelFormatType_OneComponent8).
            // ARC-retained by the dict; backed by backingData kept alive via releaseCallback.
            VGSegmentationMetadataKeySkinMaskBuffer: maskBufferObj,
            // Legacy bridge (DEC-110): retained for BeautyV2 fallback during migration.
            VGSegmentationMetadataKeySkinMask: currentMask,
            // POC-C: latest-known Apple Vision tracking result. Key absent if nil.
            VGSegmentationMetadataKeyFaceTrackingResult: trackingResult,
        };
    } else {
        metadata = @{
            VGSegmentationMetadataKeyFaceMetaPTS:
                [NSValue valueWithCMTime:currentMask.sourcePTS],
            VGSegmentationMetadataKeyFaceMetaGeneration:
                @(envelope.generation),
            VGSegmentationMetadataKeyFaceCount:
                @(currentMask.faceCount),
            VGSegmentationMetadataKeySkinMaskBuffer: maskBufferObj,
            VGSegmentationMetadataKeySkinMask: currentMask,
        };
    }

    // ── 4. Attach metadata to envelope via lifecycle helper (DEC-102) ────────
    // VGFrameEnvelopeCopyWithMetadata takes env by value, CFRetains metadata.
    VGFrameEnvelope output = VGFrameEnvelopeCopyWithMetadata(
        envelope, (__bridge void *)metadata);

    return output;
}

// ─── VanguardFilterNode (legacy protocol) ────────────────────────────────────

- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)t
                           device:(id<MTLDevice>)device {
    if (!_enabled || !input) {
        CVPixelBufferRetain(input);
        return input; // +1 passthrough
    }

    // Build a minimal envelope and delegate to processEnvelope:.
    VGFrameEnvelope env = {};
    env.pts       = t;
    env.dts       = t;
    env.duration  = kCMTimeInvalid;
    env.generation = 0;
    env.mediaType = VGMediaTypeVideo;
    env.payload.videoBuffer = input;
    env.metadata  = NULL;

    VGFrameEnvelope result = [self processEnvelope:env device:device];

    // The segmentation node does NOT modify the pixel buffer — it's always
    // a passthrough for the buffer itself. The metadata is attached to the
    // envelope, not the buffer. Since the legacy processBuffer: API cannot
    // propagate metadata, we just return the input buffer.
    //
    // Note: This path only exists for the legacy VanguardMetalRenderer video
    // path. The image path (VanguardImageProcessor) uses processEnvelope:
    // which correctly propagates metadata.

    // Release metadata if it was attached — legacy path cannot propagate it.
    VGFrameEnvelopeReleaseMetadata(&result);

    CVPixelBufferRetain(input);
    return input; // +1 passthrough — buffer is always unchanged
}

@end
