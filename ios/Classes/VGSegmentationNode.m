// VGSegmentationNode.m
// Phase 4F — Step 1: VGSegmentationNode extraction (DEC-100).
// Phase B  — Step 3 temporal stability (DEC-117): generation reset + adaptive EMA.
// Phase C  — Step 4 semantic accuracy (DEC-119): YCbCr chroma extraction for skin verification.
//
// Exact behavioral clone of the face detection + mask generation path
// previously embedded in BeautyV2FilterGroup. No algorithm changes.
//
// Execution model:
//   processEnvelope:device: is called synchronously on the filter chain thread
//   (videoDecodeQueue for video, main thread for image). Face detection is
//   dispatched asynchronously inside VGFaceDetectionProvider (never blocks).
//   Mask generation is dispatched asynchronously inside VGSkinMaskGenerator.
//   This node reads the latest cached results — NEVER blocks waiting for them.
//
// Metadata output:
//   When a valid mask exists, this node creates an NSDictionary with mask data
//   and attaches it to the envelope via VGFrameEnvelopeCopyWithMetadata.
//   When no mask is available, the envelope is forwarded unchanged (metadata=NULL).
//
// Memory safety (DEC-102, RR-86):
//   All metadata ownership goes through VGFrameEnvelope lifecycle helpers.
//   The NSDictionary is created inside processEnvelope:, CFRetained by
//   VGFrameEnvelopeCopyWithMetadata, and released by the final consumer
//   (scheduler or image processor) via VGFrameEnvelopeReleaseMetadata.

#import "VGSegmentationNode.h"
#import "VGFaceDetectionProvider.h"
#import "VGSkinMaskGenerator.h"
#import <CoreVideo/CoreVideo.h>  // kCVPixelFormatType_420YpCbCr8BiPlanar*
#import <os/log.h>

// ─── Metadata keys ───────────────────────────────────────────────────────────

NSString * const VGSegmentationMetadataKeyFaceMetaPTS         = @"faceMetaPTS";
NSString * const VGSegmentationMetadataKeyFaceMetaGeneration  = @"faceMetaGeneration";
NSString * const VGSegmentationMetadataKeyFaceCount           = @"faceCount";
NSString * const VGSegmentationMetadataKeySkinMask            = @"skinMask";         // legacy bridge
NSString * const VGSegmentationMetadataKeySkinMaskBuffer      = @"skinMaskBuffer";   // DEC-121: CVPixelBufferRef R8

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

    // ── Face detection (moved from BeautyV2FilterGroup) ──────────────────────
    VGFaceDetectionProvider *_faceDetectionProvider;

    // ── Skin mask (moved from BeautyV2FilterGroup) ───────────────────────────
    VGSkinMaskGenerator *_skinMaskGenerator;
    CFAbsoluteTime _lastMaskDetectionTime;

    // ── Phase A.1 luma buffer — DISABLED (DEC-113 / RR-98) ───────────────────
    // Edge-aware luma-guided feathering is disabled on all paths until luma and
    // detection geometry can be paired by PTS or generation tag.
    //
    // Root cause: _faceDetectionProvider.latestResult is asynchronous with
    // cadence=3. At the point submitResult: is called, the detection geometry
    // may be from frame N-3 while the current-frame luma is from frame N.
    // Pairing stale geometry with fresh luma produces incorrect bilateral weights
    // at face/background edges and is unsafe for video.
    //
    // The image/still path uses the same processEnvelope:device: entrypoint and
    // provides no reliable same-frame pairing signal. Disabling globally is the
    // only conservative option until PTS/generation-paired luma delivery exists.
    //
    // Feathering falls back to the original Gaussian blur (exact Step 1 behaviour).
    // _lumaDownBuffer intentionally removed — no luma extraction occurs.
    // A.1 is deferred to a future step (see RR-98, DEC-113 updated status).

    // ── Phase B (DEC-117): generation tracking ─────────────────────────────────────────
    // _lastGeneration: the generation stamp seen on the previous envelope.
    // When it changes, temporal state in _skinMaskGenerator is reset and
    // _lastMaskDetectionTime is cleared so a fresh detection is not skipped.
    uint64_t _lastGeneration;
    BOOL     _lastGenerationValid; // NO until first envelope is processed
    // NOTE: Cadence adaptation (B.2) is DEFERRED — see DEC-118.
    // cadenceFrames stays fixed at 3 (set at init, never modified at runtime).

    // ── Phase C.1 (DEC-119): reusable quarter-res CbCr downsample buffer ───────────
    // Allocated once, rewritten each frame when the source is biplanar YCbCr.
    // Freed in invalidate/dealloc.
    uint8_t *_chromaDownBuffer;
    size_t   _chromaDownBufferSize;
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
    self = [super init];
    if (!self) return nil;

    _nodeId     = [[NSUUID UUID] UUIDString];
    _nodeType   = @"VGSegmentationNode";
    _filterName = @"Segmentation";
    _enabled    = YES;

    // Phase 4C (DEC-61): async face detection provider.
    // Same init as BeautyV2FilterGroup — cadenceFrames:3, enabled=YES.
    _faceDetectionProvider = [[VGFaceDetectionProvider alloc] initWithCadenceFrames:3];
    _faceDetectionProvider.enabled = YES;

    // Phase 4C (DEC-62/64): CPU skin mask generator.
    _skinMaskGenerator = [[VGSkinMaskGenerator alloc] init];
    _lastMaskDetectionTime = 0;

    // Phase B (DEC-117): generation tracking — initialise as invalid so the
    // first envelope always triggers a reset check.
    _lastGeneration      = 0;
    _lastGenerationValid = NO;
    // Cadence adaptation (B.2) DEFERRED (DEC-118) — cadenceFrames fixed at 3.

    // Phase C.1 (DEC-119): chroma downsample buffer — allocated on first use.
    _chromaDownBuffer     = NULL;
    _chromaDownBufferSize = 0;

    return self;
}

// ─── Lifecycle ───────────────────────────────────────────────────────────────

- (void)prepareWithCompletion:(void (^)(NSError * _Nullable))completion {
    // No preparation needed — detection and mask gen are created at init.
    if (completion) completion(nil);
}

- (void)invalidate {
    [_faceDetectionProvider invalidate];
    [_skinMaskGenerator invalidate];
    // No luma buffer to free — luma extraction disabled (DEC-113 / RR-98).
    free(_chromaDownBuffer); _chromaDownBuffer = NULL; _chromaDownBufferSize = 0;
}

- (void)dealloc {
    [_faceDetectionProvider invalidate];
    [_skinMaskGenerator invalidate];
    // No luma buffer to free — luma extraction disabled (DEC-113 / RR-98).
    free(_chromaDownBuffer); _chromaDownBuffer = NULL;
}

// ─── VGMetalFilterNode: processEnvelope:device: ──────────────────────────────
//
// Core execution path. Called once per frame on the filter chain thread.
//
// This method:
//   1. Submits the input frame for async face detection (never blocks)
//   2. Feeds detection results to the mask generator (never blocks)
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

    size_t w = CVPixelBufferGetWidth(input);
    size_t h = CVPixelBufferGetHeight(input);

    // ── Phase B: Generation reset (DEC-117) ───────────────────────────────────
    // On generation change (seek / session restart), clear all temporal state
    // so the first post-seek mask does not blend with pre-seek data.
    //
    // Constraints satisfied:
    //   - Does NOT use wall-clock time (uses envelope.generation).
    //   - EMA buffer and motion history cleared via resetTemporalState.
    //   - _lastMaskDetectionTime is reset so the updated detection result is
    //     not filtered out by the completionTime guard below.
    if (!_lastGenerationValid || envelope.generation != _lastGeneration) {
        // Reset mask generator temporal state (dispatched to mask queue).
        [_skinMaskGenerator resetTemporalState];
        // Reset detection time so new detection results are not skipped.
        _lastMaskDetectionTime = 0;
        // Record new generation.
        _lastGeneration      = envelope.generation;
        _lastGenerationValid = YES;
    }

    // ── 1. Submit for async face detection (never blocks) ────────────────────
    [_faceDetectionProvider detectInPixelBuffer:input pts:envelope.pts];

    // ── 2. Feed latest detection result to mask generator ────────────────────
    //
    // Phase A.1 (DEC-113) luma-guided feathering is DISABLED on all paths.
    //
    // Safety reason (RR-98): `_faceDetectionProvider.latestResult` is produced
    // asynchronously with cadence=3. At this call site the detection geometry
    // may be from frame N-3 while a current-frame luma would be from frame N.
    // Pairing stale detection geometry with fresh luma is unsafe for edge-aware
    // feathering — the bilateral weights reference face/background edges that no
    // longer correspond to the current frame.
    //
    // The image/still path shares this entrypoint and provides no reliable
    // same-frame PTS or generation signal to distinguish it from video.
    //
    // Mitigation: pass NULL luma, forcing the Gaussian fallback in
    // VGSkinMaskGenerator (exact Step 1 behaviour). No luma extraction occurs.
    // A.1 is deferred until PTS/generation-paired luma delivery is available.
    //
    // Phase A.2 (soft feature exclusion) and Phase A.3 (neck extension) are
    // NOT affected by this change — they depend only on face geometry, which
    // is already async-accepted by the detection cadence model.
    //
    // Phase C.1 (DEC-119): CbCr chroma is extracted each frame for skin verification.
    // A 1-frame lag between chroma and detection geometry is safe (skin colour
    // is stable between frames). No PTS pairing required (contrast: A.1 luma).
    VGFaceDetectionResult *detectionResult = _faceDetectionProvider.latestResult;
    if (detectionResult && detectionResult.completionTime > _lastMaskDetectionTime) {

        // ── Phase C.1: Extract quarter-res CbCr from current CVPixelBuffer ──────────
        // Source format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange (420v)
        //             or kCVPixelFormatType_420YpCbCr8BiPlanarFullRange  (420f).
        // Plane 1 is interleaved CbCr at half-resolution (w/2 × h/2).
        // Target: quarter-res (qw × qh = w/4 × h/4) — nearest-neighbor 2:1 subsample.
        //
        // Memory: _chromaDownBuffer is a reusable malloc buffer (qw*qh*2 bytes).
        // It is re-filled each frame and copied synchronously into NSData before
        // submitResult:chromaBuffer: returns. No long-lived pointer is kept.
        //
        // If the pixel format is not biplanar YCbCr, chromaBuffer is NULL and
        // skin verification is skipped gracefully this frame.
        const uint8_t *chromaBuffer = NULL;
        size_t qw = w / 4;
        size_t qh = h / 4;
        size_t chromaBufSize = qw * qh * 2; // 2 bytes per pixel: Cb + Cr

        OSType pixelFormat = CVPixelBufferGetPixelFormatType(input);
        BOOL isBiplanarYCbCr = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                                 pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);

        if (isBiplanarYCbCr && qw >= 2 && qh >= 2) {
            // Ensure reuse buffer is allocated.
            if (!_chromaDownBuffer || _chromaDownBufferSize < chromaBufSize) {
                free(_chromaDownBuffer);
                _chromaDownBuffer = (uint8_t *)malloc(chromaBufSize);
                _chromaDownBufferSize = _chromaDownBuffer ? chromaBufSize : 0;
            }

            if (_chromaDownBuffer) {
                CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
                // Plane 1: interleaved CbCr at w/2 × h/2.
                const uint8_t *cbcrPlane = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(input, 1);
                size_t cbcrBPR = CVPixelBufferGetBytesPerRowOfPlane(input, 1); // bytes-per-row (may have padding)
                size_t cbcrH   = CVPixelBufferGetHeightOfPlane(input, 1); // == h/2

                // Nearest-neighbor 2:1 subsample: take row (2r), col (2c) from the CbCr plane.
                // This maps CbCr half-res coords to quarter-res of source (= target qw×qh).
                // cbcr[row][col] covers source pixel (row*2, col*2) = quarter-res pixel.
                for (size_t qy = 0; qy < qh && (qy * 2) < cbcrH; qy++) {
                    const uint8_t *srcRow = cbcrPlane + (qy * 2) * cbcrBPR;
                    uint8_t       *dstRow = _chromaDownBuffer + qy * qw * 2;
                    for (size_t qx = 0; qx < qw; qx++) {
                        // srcRow offset: column qx*2 in the CbCr plane → 2*(qx*2) bytes
                        // (each CbCr pixel = 2 bytes interleaved).
                        size_t srcOff = (qx * 2) * 2; // = qx*4
                        dstRow[qx * 2]     = srcRow[srcOff];     // Cb
                        dstRow[qx * 2 + 1] = srcRow[srcOff + 1]; // Cr
                    }
                }
                CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
                chromaBuffer = _chromaDownBuffer;
            }
        }

        // Submit to mask generator with chroma (or NULL for non-YCbCr formats).
        [_skinMaskGenerator submitResult:detectionResult
                            chromaBuffer:chromaBuffer
                             chromaWidth:(chromaBuffer ? qw : 0)
                            chromaHeight:(chromaBuffer ? qh : 0)
                             sourceWidth:w
                            sourceHeight:h];
        _lastMaskDetectionTime = detectionResult.completionTime;
        // Cadence adaptation (B.2) DEFERRED — cadenceFrames stays fixed at 3 (DEC-118).
    }

    // ── 3. Read latest mask and attach as metadata ───────────────────────────
    VGSkinMask *currentMask = _skinMaskGenerator.latestMask;
    BOOL maskValid = (currentMask &&
                      currentMask.width > 0 &&
                      currentMask.height > 0 &&
                      currentMask.data != NULL &&
                      currentMask.faceCount > 0);

    if (!maskValid) {
        // No valid mask — forward envelope unchanged (metadata=NULL).
        return envelope;
    }

    // ── 4. Create metadata NSDictionary ──────────────────────────────────────
    //
    // DEC-121: Primary payload is now CVPixelBufferRef (kCVPixelFormatType_OneComponent8).
    // The CVPixelBuffer wraps the existing VGSkinMask R8 bytes zero-copy.
    //
    // Ownership model:
    //   - currentMask (VGSkinMask *) is ARC-retained; its _backingData (NSData)
    //     owns the R8 byte buffer. The CVPixelBuffer is created with a
    //     releaseCallback that releases the NSData retain, keeping the backing
    //     buffer alive for the full lifetime of the pixel buffer.
    //   - CVPixelBufferCreateWithBytes returns a +1 CF object. We transfer
    //     ownership to ARC via CFBridgingRelease, then store the resulting id
    //     in the NSDictionary (ARC retains it). The NSDictionary is CFRetained
    //     by VGFrameEnvelopeCopyWithMetadata. Net result: the CVPixelBuffer
    //     lives at least as long as the envelope metadata.
    //   - The legacy VGSkinMask key is also included for the BeautyV2 fallback
    //     path until all consumers are fully migrated (DEC-121).
    //
    // Thread safety:
    //   currentMask is an immutable snapshot (ARC-retained). _backingData is
    //   immutable NSData. No locks needed for read-only access from this thread.

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
        NSDictionary *fallbackMetadata = @{
            VGSegmentationMetadataKeyFaceMetaPTS:
                [NSValue valueWithCMTime:currentMask.sourcePTS],
            VGSegmentationMetadataKeyFaceMetaGeneration:
                @(envelope.generation),
            VGSegmentationMetadataKeyFaceCount:
                @(currentMask.faceCount),
            VGSegmentationMetadataKeySkinMask: currentMask,
        };
        VGFrameEnvelope fallbackOutput = VGFrameEnvelopeCopyWithMetadata(
            envelope, (__bridge void *)fallbackMetadata);
        return fallbackOutput;
    }

    // maskPixelBuffer is at +1 (from CVPixelBufferCreateWithBytes).
    // Transfer ownership to ARC via CFBridgingRelease so it lives through the dict.
    id maskBufferObj = CFBridgingRelease(maskPixelBuffer);

    NSDictionary *metadata = @{
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
    };

    // ── 5. Attach metadata to envelope via lifecycle helper (DEC-102) ────────
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
