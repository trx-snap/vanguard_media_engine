// VGHeuristicMaskProvider.m
// Phase 9A — Heuristic conformer of VGMaskProvider.
//
// Migrated state from VGSegmentationNode (exact behavior preserved):
//   _faceDetectionProvider       — VGFaceDetectionProvider instance (cadence=3)
//   _skinMaskGenerator           — VGSkinMaskGenerator instance
//   _lastMaskDetectionTime       — guards re-submission on stale detections
//   _lastGeneration / _lastGenerationValid — generation reset tracking (DEC-117)
//   _chromaDownBuffer / _chromaDownBufferSize — reusable CbCr downsample buffer (DEC-119)
//
// Threading:
//   submitFrame:pts:generation: is called on the render thread.
//   All Vision and mask generation work is dispatched asynchronously
//   by the owned sub-objects — this method never blocks.
//   latestMask is sourced from VGSkinMaskGenerator.latestMask (atomic).
//
// Frozen parameters (DEC-122):
//   cadenceFrames = 3
//   All VGSkinMaskGenerator parameters remain at their current defaults.
//
// PROHIBITED in this file:
//   No CoreML, no VNRequest changes, no model loading.
//   No VanguardMLSegmenter/Gate/Store wiring.
//   No downstream beauty filter changes.

#import "VGHeuristicMaskProvider.h"
#import "VGFaceDetectionProvider.h"
#import "VGSkinMaskGenerator.h"
#import <CoreVideo/CoreVideo.h>
#import <os/log.h>

@implementation VGHeuristicMaskProvider {
    // ── Heuristic sub-objects (previously owned by VGSegmentationNode) ────────
    VGFaceDetectionProvider *_faceDetectionProvider;
    VGSkinMaskGenerator     *_skinMaskGenerator;

    // ── Mask-detection timing guard (DEC-61) ─────────────────────────────────
    // Only submit to the mask generator when a newer detection result arrives.
    CFAbsoluteTime _lastMaskDetectionTime;

    // ── Phase B: generation reset tracking (DEC-117) ──────────────────────────
    // Reset temporal state in _skinMaskGenerator when envelope.generation changes.
    uint64_t _lastGeneration;
    BOOL     _lastGenerationValid;

    // ── Phase C.1: reusable quarter-res CbCr downsample buffer (DEC-119) ─────
    // Allocated lazily, reused each frame, freed on invalidate/dealloc.
    uint8_t *_chromaDownBuffer;
    size_t   _chromaDownBufferSize;
}

@synthesize latestMask = _latestMask; // forwarded from _skinMaskGenerator below

// ─── Init ────────────────────────────────────────────────────────────────────

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    // Phase 4C (DEC-61): async face detection provider. cadenceFrames frozen at 3 (DEC-122).
    _faceDetectionProvider = [[VGFaceDetectionProvider alloc] initWithCadenceFrames:3];
    _faceDetectionProvider.enabled = YES;

    // Phase 4C (DEC-62/64): CPU skin mask generator.
    _skinMaskGenerator     = [[VGSkinMaskGenerator alloc] init];
    _lastMaskDetectionTime = 0;

    // Phase B (DEC-117): initialise generation tracking as invalid so the first
    // frame always triggers a reset check.
    _lastGeneration      = 0;
    _lastGenerationValid = NO;

    // Phase C.1 (DEC-119): chroma buffer — allocated on first use.
    _chromaDownBuffer     = NULL;
    _chromaDownBufferSize = 0;

    return self;
}

// ─── VGMaskProvider: latestMask ──────────────────────────────────────────────

- (VGSkinMask *)latestMask {
    // Delegate directly to the generator's atomic property.
    return _skinMaskGenerator.latestMask;
}

// ─── VGMaskProvider: submitFrame:pts:generation: ─────────────────────────────

- (void)submitFrame:(CVPixelBufferRef)pixelBuffer
                pts:(CMTime)pts
         generation:(uint64_t)generation {
    if (!pixelBuffer) return;

    size_t w = CVPixelBufferGetWidth(pixelBuffer);
    size_t h = CVPixelBufferGetHeight(pixelBuffer);

    // ── Phase B: Generation reset (DEC-117) ───────────────────────────────────
    // On generation change (seek / session restart), clear all temporal state
    // so the first post-seek mask does not blend with pre-seek data.
    if (!_lastGenerationValid || generation != _lastGeneration) {
        [_skinMaskGenerator resetTemporalState];
        _lastMaskDetectionTime = 0;
        _lastGeneration        = generation;
        _lastGenerationValid   = YES;
    }

    // ── 1. Submit for async face detection (never blocks) ────────────────────
    [_faceDetectionProvider detectInPixelBuffer:pixelBuffer pts:pts];

    // ── 2. Feed latest detection result to mask generator ────────────────────
    //
    // Phase A.1 (DEC-113) luma-guided feathering is DISABLED on all paths.
    // lumaBuffer=NULL forces the Gaussian fallback in VGSkinMaskGenerator
    // (exact Step 1 behaviour). See RR-98 for full rationale.
    //
    // Phase C.1 (DEC-119): CbCr chroma is extracted each frame for skin
    // verification. A 1-frame lag between chroma and detection geometry is
    // safe — skin colour is stable between frames.
    VGFaceDetectionResult *detectionResult = _faceDetectionProvider.latestResult;
    if (detectionResult && detectionResult.completionTime > _lastMaskDetectionTime) {

        // ── Phase C.1: Extract quarter-res CbCr from the current CVPixelBuffer ──
        // Source format: 420YpCbCr8BiPlanarVideoRange (420v) or FullRange (420f).
        // Plane 1 is interleaved CbCr at half-resolution (w/2 × h/2).
        // Target: quarter-res (qw × qh = w/4 × h/4) — nearest-neighbor 2:1 subsample.
        //
        // Memory: _chromaDownBuffer is a reusable malloc buffer (qw*qh*2 bytes).
        // Re-filled each frame; copied synchronously into NSData by
        // VGSkinMaskGenerator before this method returns.
        const uint8_t *chromaBuffer = NULL;
        size_t qw = w / 4;
        size_t qh = h / 4;
        size_t chromaBufSize = qw * qh * 2; // 2 bytes per pixel: Cb + Cr

        OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
        BOOL isBiplanarYCbCr =
            (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
             pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);

        if (isBiplanarYCbCr && qw >= 2 && qh >= 2) {
            // Ensure reuse buffer is allocated.
            if (!_chromaDownBuffer || _chromaDownBufferSize < chromaBufSize) {
                free(_chromaDownBuffer);
                _chromaDownBuffer = (uint8_t *)malloc(chromaBufSize);
                _chromaDownBufferSize = _chromaDownBuffer ? chromaBufSize : 0;
            }

            if (_chromaDownBuffer) {
                CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
                // Plane 1: interleaved CbCr at w/2 × h/2.
                const uint8_t *cbcrPlane =
                    (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
                size_t cbcrBPR = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
                size_t cbcrH   = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1); // == h/2

                // Nearest-neighbor 2:1 subsample: take row (2r), col (2c) from CbCr plane.
                for (size_t qy = 0; qy < qh && (qy * 2) < cbcrH; qy++) {
                    const uint8_t *srcRow = cbcrPlane + (qy * 2) * cbcrBPR;
                    uint8_t       *dstRow = _chromaDownBuffer + qy * qw * 2;
                    for (size_t qx = 0; qx < qw; qx++) {
                        size_t srcOff = (qx * 2) * 2; // = qx*4
                        dstRow[qx * 2]     = srcRow[srcOff];     // Cb
                        dstRow[qx * 2 + 1] = srcRow[srcOff + 1]; // Cr
                    }
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
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
    }
}

// ─── VGMaskProvider: invalidate ──────────────────────────────────────────────

- (void)invalidate {
    [_faceDetectionProvider invalidate];
    [_skinMaskGenerator invalidate];
    free(_chromaDownBuffer);
    _chromaDownBuffer     = NULL;
    _chromaDownBufferSize = 0;
}

// ─── dealloc ─────────────────────────────────────────────────────────────────

- (void)dealloc {
    [_faceDetectionProvider invalidate];
    [_skinMaskGenerator invalidate];
    free(_chromaDownBuffer);
    _chromaDownBuffer = NULL;
}

@end
