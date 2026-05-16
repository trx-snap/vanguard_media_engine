// VGSkinMaskGenerator.m
// Phase 4C — Step 2: CPU skin mask generation from face landmarks (DEC-62/64).
// Phase A  — Step 2 spatial cleanup (DEC-113/114/115).
// Phase B  — Step 3 temporal stability (DEC-117): adaptive EMA smoothing.
// Phase C  — Step 4 semantic accuracy (DEC-119): YCbCr skin verification.

#import "VGSkinMaskGenerator.h"
#import "VGFaceDetectionProvider.h"  // VGDetectedFace, VGFaceDetectionResult
#import <Accelerate/Accelerate.h>
#import <os/log.h>
#import <stdatomic.h>

// ---------------------------------------------------------------------------
// MARK: VGSkinMask
// ---------------------------------------------------------------------------

@implementation VGSkinMask {
    NSData *_backingData;  // owns the R8 buffer
}

@synthesize width     = _width;
@synthesize height    = _height;
@synthesize bytesPerRow = _bytesPerRow;
@synthesize sourcePTS = _sourcePTS;
@synthesize faceCount = _faceCount;

- (const uint8_t *)data {
    return (const uint8_t *)_backingData.bytes;
}

- (instancetype)_initWithData:(NSData *)data
                        width:(size_t)width
                       height:(size_t)height
                    sourcePTS:(CMTime)pts
                    faceCount:(NSInteger)faceCount {
    self = [super init];
    if (!self) return nil;
    _backingData = [data copy];  // immutable snapshot
    _width       = width;
    _height      = height;
    _bytesPerRow = width;  // R8, no padding
    _sourcePTS   = pts;
    _faceCount   = faceCount;
    return self;
}

@end

// ---------------------------------------------------------------------------
// MARK: Geometry helpers
// ---------------------------------------------------------------------------

/// Converts a Vision-normalised point (origin = bottom-left) to quarter-res
/// pixel coordinates (origin = top-left).
static inline CGPoint
_VGNormToQuarterPixel(CGPoint norm, size_t qw, size_t qh) {
    return CGPointMake(norm.x * qw, (1.0 - norm.y) * qh);
}

/// Fills a soft ellipse into the mask buffer. Pixels inside the ellipse are
/// set to 255; pixels outside are unchanged. The ellipse is inscribed in the
/// given rect (quarter-res pixel coords, top-left origin).
static void
_VGFillSoftEllipse(uint8_t *buf, size_t qw, size_t qh, CGRect rect) {
    CGFloat cx = CGRectGetMidX(rect);
    CGFloat cy = CGRectGetMidY(rect);
    CGFloat rx = CGRectGetWidth(rect) * 0.5;
    CGFloat ry = CGRectGetHeight(rect) * 0.5;
    if (rx < 1.0 || ry < 1.0) return;

    // Clamp scan bounds to buffer.
    int yMin = MAX(0, (int)floor(cy - ry));
    int yMax = MIN((int)qh - 1, (int)ceil(cy + ry));
    int xMin = MAX(0, (int)floor(cx - rx));
    int xMax = MIN((int)qw - 1, (int)ceil(cx + rx));

    for (int y = yMin; y <= yMax; y++) {
        for (int x = xMin; x <= xMax; x++) {
            CGFloat dx = (x - cx) / rx;
            CGFloat dy = (y - cy) / ry;
            CGFloat d2 = dx * dx + dy * dy;
            if (d2 <= 1.0) {
                buf[y * qw + x] = 255;
            }
        }
    }
}

/// Fills a convex polygon into the mask buffer using scanline fill.
/// Points are in quarter-res pixel coords (top-left origin).
/// Pixels inside the polygon are set to `value`.
static void
_VGFillConvexPolygon(uint8_t *buf, size_t qw, size_t qh,
                     const CGPoint *pts, NSUInteger count, uint8_t value) {
    if (count < 3) return;

    // Find vertical bounds.
    CGFloat minY = pts[0].y, maxY = pts[0].y;
    for (NSUInteger i = 1; i < count; i++) {
        if (pts[i].y < minY) minY = pts[i].y;
        if (pts[i].y > maxY) maxY = pts[i].y;
    }
    int yStart = MAX(0, (int)floor(minY));
    int yEnd   = MIN((int)qh - 1, (int)ceil(maxY));

    for (int y = yStart; y <= yEnd; y++) {
        // Find x-intersections with polygon edges.
        CGFloat xIntersections[64]; // enough for face contours
        int nIntersections = 0;
        for (NSUInteger i = 0; i < count && nIntersections < 62; i++) {
            NSUInteger j = (i + 1) % count;
            CGFloat y0 = pts[i].y, y1 = pts[j].y;
            if ((y0 <= y && y1 > y) || (y1 <= y && y0 > y)) {
                CGFloat t = (y - y0) / (y1 - y0);
                xIntersections[nIntersections++] = pts[i].x + t * (pts[j].x - pts[i].x);
            }
        }
        // Sort intersections (simple insertion sort — small count).
        for (int a = 1; a < nIntersections; a++) {
            CGFloat key = xIntersections[a];
            int b = a - 1;
            while (b >= 0 && xIntersections[b] > key) {
                xIntersections[b + 1] = xIntersections[b];
                b--;
            }
            xIntersections[b + 1] = key;
        }
        // Fill between pairs of intersections.
        for (int p = 0; p + 1 < nIntersections; p += 2) {
            int xStart = MAX(0, (int)ceil(xIntersections[p]));
            int xEnd   = MIN((int)qw - 1, (int)floor(xIntersections[p + 1]));
            for (int x = xStart; x <= xEnd; x++) {
                buf[y * qw + x] = value;
            }
        }
    }
}

/// Applies a 1D Gaussian blur to a single row/column of uint8 data.
/// Uses a separable 2-pass approach via Accelerate vImageConvolve.
static void
_VGGaussianBlurR8(uint8_t *buf, size_t width, size_t height, float sigma) {
    if (sigma < 0.5f) return;

    // Kernel size: odd, ≥ 3, covering ±3σ.
    int kernelSize = (int)(sigma * 6.0f) | 1;  // ensure odd
    if (kernelSize < 3) kernelSize = 3;
    if (kernelSize > 31) kernelSize = 31;  // cap for performance

    vImage_Buffer src = {
        .data   = buf,
        .width  = width,
        .height = height,
        .rowBytes = width
    };

    // Allocate temp buffer for the convolution.
    size_t tempSize = width * height;
    uint8_t *temp = (uint8_t *)calloc(tempSize, 1);
    if (!temp) return;

    vImage_Buffer dst = {
        .data   = temp,
        .width  = width,
        .height = height,
        .rowBytes = width
    };

    // Build 1D Gaussian kernel.
    float *kernel = (float *)malloc(kernelSize * sizeof(float));
    if (!kernel) { free(temp); return; }
    float sum = 0;
    int half = kernelSize / 2;
    for (int i = 0; i < kernelSize; i++) {
        float x = (float)(i - half);
        kernel[i] = expf(-x * x / (2.0f * sigma * sigma));
        sum += kernel[i];
    }
    for (int i = 0; i < kernelSize; i++) kernel[i] /= sum;

    // Convert to int16 kernel (vImage expects int16 for Planar8).
    int16_t *ikernel = (int16_t *)malloc(kernelSize * sizeof(int16_t));
    if (!ikernel) { free(kernel); free(temp); return; }
    int32_t isum = 0;
    for (int i = 0; i < kernelSize; i++) {
        ikernel[i] = (int16_t)(kernel[i] * 256.0f + 0.5f);
        isum += ikernel[i];
    }
    free(kernel);

    // Horizontal pass: src → dst.
    vImageConvolve_Planar8(&src, &dst, NULL,
                           0, 0,
                           ikernel, 1, kernelSize,
                           isum, 0,
                           kvImageEdgeExtend);

    // Vertical pass: dst → src (back into original buffer).
    vImageConvolve_Planar8(&dst, &src, NULL,
                           0, 0,
                           ikernel, kernelSize, 1,
                           isum, 0,
                           kvImageEdgeExtend);

    free(ikernel);
    free(temp);
}

// ---------------------------------------------------------------------------
// Phase A.1 — Edge-aware mask feathering (DEC-113) — DISABLED for Step 2
//
// This function approximates a bilateral filter on the mask using luma guidance.
// For each output pixel, weights are: gaussian(distance) × exp(-ΔLuma²/2σ²).
// Kernel radius is capped at 5 quarter-res pixels (DEC-113 conservative first pass).
//
// CURRENT STATE (Step 2): luma-guided feathering is DISABLED on all paths.
// VGSegmentationNode always passes lumaBuffer=NULL — see RR-98 and DEC-113.
//
// Root cause: detection geometry from VGFaceDetectionProvider is asynchronous
// (cadence=3). The geometry may be from frame N-3 while luma is from frame N.
// Pairing stale geometry with fresh luma produces incorrect bilateral edge weights.
//
// A.1 is deferred until one of:
//   a) luma is tagged with the same PTS as the detection result it pairs with, OR
//   b) the image/still path can be reliably distinguished from video, enabling
//      luma-guided feathering only for same-frame still processing.
//
// When lumaGuidance is NULL (always, currently), falls back to the existing
// Gaussian blur. phaseAEnabled=NO path never reaches this function.
// ---------------------------------------------------------------------------
static void
_VGEdgeAwareFeatherR8(uint8_t *buf, size_t width, size_t height,
                       float sigma, float rangeSigma,
                       const uint8_t * _Nullable lumaGuidance) {
    // Phase A.1 — DEFERRED
    // Do not enable without PTS-aligned luma (see DEC-116, RR-98).
    // Callers always pass lumaGuidance=NULL; the branch below is unreachable.
    if (!lumaGuidance) {
        // No guidance — fall back to plain Gaussian (exact Step 1 behaviour).
        _VGGaussianBlurR8(buf, width, height, sigma);
        return;
    }

    // Conservative radius cap: max 5px at quarter-res (DEC-113 first-dev-pass).
    // Increase only after CPU budget validation on A12/A13 devices.
    int radius = (int)(sigma * 2.0f + 0.5f);
    if (radius < 1) radius = 1;
    if (radius > 5) radius = 5;  // was 7; reduced to 5 for conservative first pass

    float twoSigSq = 2.0f * sigma * sigma;
    float twoRangeSq = 2.0f * rangeSigma * rangeSigma * 255.0f * 255.0f;

    size_t total = width * height;
    uint8_t *out = (uint8_t *)malloc(total);
    if (!out) {
        _VGGaussianBlurR8(buf, width, height, sigma);
        return;
    }

    for (int y = 0; y < (int)height; y++) {
        for (int x = 0; x < (int)width; x++) {
            float lumaC = (float)lumaGuidance[y * width + x];
            float wSum  = 0.0f;
            float vSum  = 0.0f;
            int yMin = y - radius, yMax = y + radius;
            int xMin = x - radius, xMax = x + radius;
            if (yMin < 0) yMin = 0;
            if (yMax >= (int)height) yMax = (int)height - 1;
            if (xMin < 0) xMin = 0;
            if (xMax >= (int)width)  xMax = (int)width  - 1;
            for (int ny = yMin; ny <= yMax; ny++) {
                float dy = (float)(ny - y);
                for (int nx = xMin; nx <= xMax; nx++) {
                    float dx = (float)(nx - x);
                    float dLuma = (float)lumaGuidance[ny * width + nx] - lumaC;
                    float wSpatial = expf(-(dx*dx + dy*dy) / twoSigSq);
                    float wRange   = expf(-(dLuma * dLuma) / twoRangeSq);
                    float w = wSpatial * wRange;
                    wSum += w;
                    vSum += w * (float)buf[ny * width + nx];
                }
            }
            out[y * width + x] = (wSum > 0.0f)
                ? (uint8_t)(vSum / wSum + 0.5f)
                : buf[y * width + x];
        }
    }
    memcpy(buf, out, total);
    free(out);
}

// ---------------------------------------------------------------------------
// Phase A.3 — Neck extension soft ellipse (DEC-115)
//
// Adds a conservative soft elliptical region below the face bounding box.
// Values are OR'd (max) so the neck never subtracts from the face mask.
// strength controls the ellipse height as fraction of faceHeight.
// ---------------------------------------------------------------------------
static void
_VGFillNeckEllipse(uint8_t *buf, size_t qw, size_t qh, CGRect facePixelRect,
                   float strength) {
    if (strength <= 0.0f) return;

    CGFloat faceW = CGRectGetWidth(facePixelRect);
    CGFloat faceH = CGRectGetHeight(facePixelRect);
    // Center at bottom-center of face bounding box.
    CGFloat cx = CGRectGetMidX(facePixelRect);
    CGFloat cy = CGRectGetMaxY(facePixelRect); // top-left raster, so MaxY = bottom

    CGFloat rx = faceW * 0.4;                   // 80% of faceWidth / 2
    CGFloat ry = faceH * (CGFloat)strength;     // height controlled by strength

    if (rx < 1.0 || ry < 1.0) return;

    int yMin = MAX(0, (int)floor(cy));
    int yMax = MIN((int)qh - 1, (int)ceil(cy + ry));
    int xMin = MAX(0, (int)floor(cx - rx));
    int xMax = MIN((int)qw - 1, (int)ceil(cx + rx));

    for (int y = yMin; y <= yMax; y++) {
        for (int x = xMin; x <= xMax; x++) {
            CGFloat dx = (x - cx) / rx;
            CGFloat dy = (y - cy) / ry;
            CGFloat d2 = dx * dx + dy * dy;
            if (d2 <= 1.0) {
                // Soft falloff: stronger at center, fades to 0 at edge.
                // value = 255 × (1 - d2)²  →  smooth, natural fade.
                float neckVal = 255.0f * (float)((1.0 - d2) * (1.0 - d2));
                uint8_t nv = (uint8_t)(neckVal + 0.5f);
                size_t idx = y * qw + x;
                if (nv > buf[idx]) buf[idx] = nv; // OR: keep max of face/neck
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: VGSkinMaskGenerator
// ---------------------------------------------------------------------------

@implementation VGSkinMaskGenerator {
    // Reusable working buffer — avoids malloc/free per frame.
    // Accessed ONLY on _maskQueue — no synchronisation needed for these.
    uint8_t *_workBuffer;
    size_t   _workBufferSize;
    size_t   _lastQW;
    size_t   _lastQH;

    // Phase 4C Step 4: EMA-smoothed mask buffer (RR-57).
    uint8_t *_smoothedBuffer;
    size_t   _smoothedBufferSize;
    BOOL     _hasSmoothedData;

    // Phase B.1 (DEC-117): motion tracking for adaptive EMA alpha.
    // Accessed ONLY on _maskQueue — no external synchronisation needed.
    // Stores the primary face bounding-box centre from the previous generation
    // (normalised Vision coords: origin bottom-left, range [0,1]).
    CGFloat  _prevBBoxCX;    // X centre of previous primary face bb
    CGFloat  _prevBBoxCY;    // Y centre of previous primary face bb
    BOOL     _prevBBoxValid; // NO until at least one result has been processed

    // Phase C.1 (DEC-119): skin verification enabled.
    BOOL     _skinVerificationEnabled;

    // Private serial queue — all rasterization + vImage work runs here.
    dispatch_queue_t _maskQueue;
    // Atomic in-flight guard — prevents overlapping generations.
    atomic_bool      _generationInFlight;
    // Atomic invalidation flag — prevents stale mask publishes.
    atomic_bool      _invalidated;
}

@synthesize latestMask              = _latestMask;
@synthesize featherSigma            = _featherSigma;
@synthesize faceOvalInset           = _faceOvalInset;
@synthesize featureExclusionPadding = _featureExclusionPadding;
@synthesize smoothingAlpha          = _smoothingAlpha;
@synthesize phaseAEnabled           = _phaseAEnabled;
@synthesize neckExtensionStrength   = _neckExtensionStrength;
@synthesize featherRangeSigma       = _featherRangeSigma;
@synthesize featureExclusionInnerRadius = _featureExclusionInnerRadius;
@synthesize skinVerificationEnabled = _skinVerificationEnabled;

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _featherSigma            = 8.0f;   // DEC-62: σ=8 at quarter-res
    _faceOvalInset           = 0.05f;  // 5% inset to avoid mask leakage (RR-55)
    _featureExclusionPadding = 0.15f;  // 15% expansion for feature zones
    _smoothingAlpha          = 0.3f;   // Step 4 (RR-57): EMA convergence rate
                                       // NOTE: Phase B.1 overrides this with motion-
                                       // adaptive alpha. _smoothingAlpha is now the
                                       // BASE alpha (used as alphaMax upper bound
                                       // reference) but is NOT applied directly.
                                       // See _generateMaskForResult: adaptive section.
    // Phase A defaults (DEC-113/114/115):
    _phaseAEnabled              = YES;   // master gate: set NO to revert all Phase A
    _neckExtensionStrength      = 0.20f; // 20% of faceHeight below jaw (DEC-115)
                                         // Reduced from 0.35 for conservative first dev
                                         // pass. Increase only after QA on diverse shots.
    _featherRangeSigma          = 0.12f; // luma edge gate (DEC-113)
    _featureExclusionInnerRadius = 0.6f; // smoothstep inner boundary (DEC-114)
    _workBuffer     = NULL;
    _workBufferSize = 0;
    _smoothedBuffer     = NULL;
    _smoothedBufferSize = 0;
    _hasSmoothedData    = NO;
    _lastQW = 0;
    _lastQH = 0;
    // Phase B.1: motion state — cleared on init (same as after generation reset).
    _prevBBoxCX    = 0.0;
    _prevBBoxCY    = 0.0;
    _prevBBoxValid = NO;
    // Phase C (DEC-119): skin verification — enabled by default.
    _skinVerificationEnabled = YES;
    _maskQueue = dispatch_queue_create("com.vanguard.skinMask", DISPATCH_QUEUE_SERIAL);
    atomic_store(&_generationInFlight, false);
    atomic_store(&_invalidated, false);
    return self;
}

// ---------------------------------------------------------------------------
// MARK: Public async entry point
// ---------------------------------------------------------------------------

- (void)submitResult:(VGFaceDetectionResult *)result
         sourceWidth:(size_t)sourceWidth
        sourceHeight:(size_t)sourceHeight {
    [self submitResult:result
            lumaBuffer:NULL lumaWidth:0 lumaHeight:0
           sourceWidth:sourceWidth sourceHeight:sourceHeight];
}

- (void)submitResult:(VGFaceDetectionResult *)result
          lumaBuffer:(const uint8_t * _Nullable)lumaBuffer
           lumaWidth:(size_t)lumaWidth
          lumaHeight:(size_t)lumaHeight
         sourceWidth:(size_t)sourceWidth
        sourceHeight:(size_t)sourceHeight {
    if (atomic_load(&_invalidated) || !result) return;
    if (sourceWidth < 4 || sourceHeight < 4) return;
    if (atomic_exchange(&_generationInFlight, true)) return;

    // ── Luma pairing safety (DEC-113 / RR-98) ────────────────────────────────
    // Phase A.1 luma-guided feathering is DISABLED. VGSegmentationNode passes
    // lumaBuffer=NULL on all paths (video and image/still) because detection
    // geometry (_faceDetectionProvider.latestResult) may be from frame N-3 while
    // any current-frame luma would be from frame N. Pairing stale geometry with
    // fresh luma is unsafe for edge-aware feathering.
    //
    // The code below is preserved to document the intended pairing contract:
    //   capturedLuma must be tagged with the same PTS as `result.sourcePTS`.
    // When that tagging exists, remove this comment block and re-enable luma
    // capture in VGSegmentationNode.processEnvelope:device:.
    //
    // With lumaBuffer=NULL (current state), capturedLuma stays nil here.
    // The generation block unconditionally takes the Gaussian fallback path.
    NSData * _Nullable capturedLuma = nil;
    size_t capturedLumaW = 0, capturedLumaH = 0;

    if (lumaBuffer && lumaWidth > 0 && lumaHeight > 0 && _phaseAEnabled) {
        // NSData copies the bytes — immutable, ARC-managed, thread-safe.
        capturedLuma = [NSData dataWithBytes:lumaBuffer length:lumaWidth * lumaHeight];
        capturedLumaW = lumaWidth;
        capturedLumaH = lumaHeight;
    }
    // When phaseAEnabled=NO: capturedLuma remains nil. The generation block
    // will take the Gaussian path unconditionally — exact Step 1 behaviour.

    // ── Coalescing note (DEC-113 / RR-98) ────────────────────────────────────
    // IMPORTANT: even when A.1 is re-enabled in the future, the detection
    // result may be from a PREVIOUS frame (async pipeline). capturedLuma must
    // be paired by PTS with `result.sourcePTS`, not with the current frame.
    // A dimension check alone is NOT sufficient as a safety guard for video.

    size_t capturedW = sourceWidth;
    size_t capturedH = sourceHeight;
    __weak typeof(self) weakSelf = self;
    dispatch_async(_maskQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || atomic_load(&strongSelf->_invalidated)) {
            if (strongSelf) atomic_store(&strongSelf->_generationInFlight, false);
            return;
        }
        [strongSelf _generateMaskForResult:result
                               sourceWidth:capturedW
                              sourceHeight:capturedH
                              capturedLuma:capturedLuma
                             capturedLumaW:capturedLumaW
                             capturedLumaH:capturedLumaH
                           capturedChroma:nil
                          capturedChromaW:0
                          capturedChromaH:0];
        atomic_store(&strongSelf->_generationInFlight, false);
    });
}

// ---------------------------------------------------------------------------
// MARK: Phase C.1 — Skin verification entry point (DEC-119)
// ---------------------------------------------------------------------------

- (void)submitResult:(VGFaceDetectionResult *)result
       chromaBuffer:(const uint8_t * _Nullable)chromaBuffer
        chromaWidth:(size_t)chromaWidth
       chromaHeight:(size_t)chromaHeight
        sourceWidth:(size_t)sourceWidth
       sourceHeight:(size_t)sourceHeight {
    if (atomic_load(&_invalidated) || !result) return;
    if (sourceWidth < 4 || sourceHeight < 4) return;
    if (atomic_exchange(&_generationInFlight, true)) return;

    // Capture an immutable copy of the chroma buffer (ARC-managed, thread-safe).
    // A 1-frame lag between the chroma data and the detection geometry is safe:
    // skin colour is stable frame-to-frame; the chroma is used only to verify
    // whether pixels inside the already-computed geometric mask look like skin.
    // No PTS pairing is required (contrast: A.1 luma DOES require PTS pairing).
    NSData * _Nullable capturedChroma = nil;
    size_t capturedChromaW = 0, capturedChromaH = 0;

    if (chromaBuffer && chromaWidth > 0 && chromaHeight > 0 && _skinVerificationEnabled) {
        // 2 bytes per pixel: Cb at even index, Cr at odd index.
        capturedChroma = [NSData dataWithBytes:chromaBuffer
                                        length:chromaWidth * chromaHeight * 2];
        capturedChromaW = chromaWidth;
        capturedChromaH = chromaHeight;
    }
    // skinVerificationEnabled=NO → capturedChroma stays nil → verification skipped.
    // chromaBuffer=NULL → same result → exact Step 3 behaviour.

    size_t capturedW = sourceWidth;
    size_t capturedH = sourceHeight;
    __weak typeof(self) weakSelf = self;
    dispatch_async(_maskQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || atomic_load(&strongSelf->_invalidated)) {
            if (strongSelf) atomic_store(&strongSelf->_generationInFlight, false);
            return;
        }
        [strongSelf _generateMaskForResult:result
                               sourceWidth:capturedW
                              sourceHeight:capturedH
                              capturedLuma:nil
                             capturedLumaW:0
                             capturedLumaH:0
                           capturedChroma:capturedChroma
                          capturedChromaW:capturedChromaW
                          capturedChromaH:capturedChromaH];
        atomic_store(&strongSelf->_generationInFlight, false);
    });
}


// ---------------------------------------------------------------------------
// MARK: Phase B — Temporal state reset (DEC-117)
// ---------------------------------------------------------------------------

/// Clears EMA smoothing history and motion tracking state.
///
/// Must be called by VGSegmentationNode when envelope.generation changes
/// (seek / session restart). Dispatched async to _maskQueue so it runs
/// after any currently-queued generation block — no race with in-flight work.
///
/// The first mask produced after a reset seeds the smoothed buffer directly
/// (no blending lag) exactly as at node init.
- (void)resetTemporalState {
    __weak typeof(self) weakSelf = self;
    dispatch_async(_maskQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        // Clear EMA state — next generation seeds the buffer fresh.
        if (strongSelf->_smoothedBuffer && strongSelf->_smoothedBufferSize > 0) {
            memset(strongSelf->_smoothedBuffer, 0, strongSelf->_smoothedBufferSize);
        }
        strongSelf->_hasSmoothedData = NO;
        // Clear motion history — next generation has no previous bbox to compare.
        strongSelf->_prevBBoxCX    = 0.0;
        strongSelf->_prevBBoxCY    = 0.0;
        strongSelf->_prevBBoxValid = NO;
    });
}

// ---------------------------------------------------------------------------
// MARK: Internal synchronous generation (runs on _maskQueue only)
// ---------------------------------------------------------------------------

- (void)_generateMaskForResult:(VGFaceDetectionResult *)result
                   sourceWidth:(size_t)sourceWidth
                  sourceHeight:(size_t)sourceHeight
                  capturedLuma:(NSData * _Nullable)capturedLuma
                 capturedLumaW:(size_t)capturedLumaW
                 capturedLumaH:(size_t)capturedLumaH
                capturedChroma:(NSData * _Nullable)capturedChroma
               capturedChromaW:(size_t)capturedChromaW
               capturedChromaH:(size_t)capturedChromaH {
    // Verify Step 1 fallback contract (DEC-113/114/115):
    // When phaseAEnabled=NO, capturedLuma MUST be nil (suppressed at submitResult:).
    // This assertion fires in debug builds if the suppress gate breaks.
    NSCAssert(!(_phaseAEnabled == NO && capturedLuma != nil),
              @"[VGSkinMaskGenerator] capturedLuma must be nil when phaseAEnabled=NO");
    if (!result || sourceWidth < 4 || sourceHeight < 4) return;

    // ── Quarter-res dimensions (DEC-62) ──────────────────────────────────
    size_t qw = sourceWidth / 4;
    size_t qh = sourceHeight / 4;
    if (qw < 2 || qh < 2) return;
    size_t bufSize = qw * qh;

    // ── Allocate / reuse working buffer ──────────────────────────────────
    if (!_workBuffer || _workBufferSize < bufSize) {
        free(_workBuffer);
        _workBuffer = (uint8_t *)malloc(bufSize);
        if (!_workBuffer) { _workBufferSize = 0; return; }
        _workBufferSize = bufSize;
    }

    // Allocate / reuse smoothed buffer.
    if (!_smoothedBuffer || _smoothedBufferSize < bufSize) {
        free(_smoothedBuffer);
        _smoothedBuffer = (uint8_t *)calloc(bufSize, 1);
        if (!_smoothedBuffer) { _smoothedBufferSize = 0; return; }
        _smoothedBufferSize = bufSize;
        _hasSmoothedData = NO;
    }
    
    _lastQW = qw;
    _lastQH = qh;

    // ── Clear to 0 (no effect) ───────────────────────────────────────────
    memset(_workBuffer, 0, bufSize);

    // ── Rasterize each face ──────────────────────────────────────────────
    NSArray<VGDetectedFace *> *faces = result.faces;
    for (VGDetectedFace *face in faces) {
        CGRect bb = face.boundingBox;
        if (bb.size.width <= 0 || bb.size.height <= 0) continue;

        // --- 1. Fill face region (skin = 255) ---
        NSArray<NSValue *> *contour = face.faceContourPoints;
        if (contour && contour.count >= 3) {
            // Use face contour polygon — more accurate than ellipse.
            CGPoint *pts = (CGPoint *)malloc(contour.count * sizeof(CGPoint));
            if (pts) {
                for (NSUInteger i = 0; i < contour.count; i++) {
                    CGPoint norm = [contour[i] CGPointValue];
                    pts[i] = _VGNormToQuarterPixel(norm, qw, qh);
                }
                _VGFillConvexPolygon(_workBuffer, qw, qh, pts, contour.count, 255);
                free(pts);
            }
        } else {
            // Fallback: fill ellipse from bounding box (with inset).
            CGFloat inset = _faceOvalInset;
            CGRect insetBB = CGRectInset(bb, bb.size.width * inset, bb.size.height * inset);
            CGRect pixelRect = CGRectMake(
                insetBB.origin.x * qw,
                (1.0 - insetBB.origin.y - insetBB.size.height) * qh,
                insetBB.size.width * qw,
                insetBB.size.height * qh
            );
            _VGFillSoftEllipse(_workBuffer, qw, qh, pixelRect);
        }

        // --- 2. Subtract exclusion zones (features = soft falloff or hard 0) ---
        float pad = _featureExclusionPadding;
        [self _subtractFeature:face.leftEyePoints      pad:pad bb:bb qw:qw qh:qh];
        [self _subtractFeature:face.rightEyePoints     pad:pad bb:bb qw:qw qh:qh];
        [self _subtractFeature:face.leftEyebrowPoints  pad:pad bb:bb qw:qw qh:qh];
        [self _subtractFeature:face.rightEyebrowPoints pad:pad bb:bb qw:qw qh:qh];
        [self _subtractFeature:face.outerLipsPoints    pad:pad bb:bb qw:qw qh:qh];

        // --- 3. Phase A.3: Neck extension (DEC-115) ---
        if (_phaseAEnabled && _neckExtensionStrength > 0.0f) {
            // Compute face pixel rect (top-left raster) from bounding box.
            CGRect facePixRect = CGRectMake(
                bb.origin.x * qw,
                (1.0 - bb.origin.y - bb.size.height) * qh,
                bb.size.width * qw,
                bb.size.height * qh
            );
            _VGFillNeckEllipse(_workBuffer, qw, qh, facePixRect, _neckExtensionStrength);
        }
    }

    // ── Phase C.1: Skin colour verification (DEC-119) ───────────────────────────
    //
    // Reduces non-skin pixels inside the geometric face mask by × 0.3.
    // This is monotonic — values only decrease, never increase.
    // No new edges are introduced (all reductions are uniform scale, not cut).
    //
    // YCbCr skin range (BT.601, integer 0–255 scale):
    //   Cb ∈ [77, 127]
    //   Cr ∈ [133, 173]
    //
    // Partial reduction factor applied as fixed-point:
    //   mask[i] = (mask[i] × 115 + 128) >> 8  ≈ mask[i] × 0.449
    //
    // Gate: requires skinVerificationEnabled=YES AND valid chroma buffer at
    // the correct quarter-res dimensions. Skipped gracefully if either is absent.
    //
    // NOTE:
    // Chroma is extracted from current frame while detection geometry may be cached.
    // This is acceptable because this pass is monotonic (only reduces mask values)
    // and does not introduce new edges or spatial artifacts.
    const uint8_t *chromaPtr = (const uint8_t *)capturedChroma.bytes;
    if (_skinVerificationEnabled
            && chromaPtr
            && capturedChromaW == qw
            && capturedChromaH == qh) {

        static const int kSkinCbMin = 77;
        static const int kSkinCbMax = 127;
        static const int kSkinCrMin = 133;
        static const int kSkinCrMax = 173;
        // Fixed-point × 0.45: use 115/256 ≈ 0.449
        static const int kRejectNum = 115;

        // chromaPtr layout: [Cb0, Cr0, Cb1, Cr1, ...] per pixel, row-major,
        // identical spatial layout as _workBuffer (qw columns, qh rows).
        for (size_t i = 0; i < bufSize; i++) {
            if (_workBuffer[i] == 0) continue; // skip already-zero pixels (fast path)
            int cb = chromaPtr[i * 2];
            int cr = chromaPtr[i * 2 + 1];
            BOOL isSkin = (cb >= kSkinCbMin && cb <= kSkinCbMax &&
                           cr >= kSkinCrMin && cr <= kSkinCrMax);
            if (!isSkin) {
                // Partial reduction: mask × ~0.45, integer fixed-point.
                _workBuffer[i] = (uint8_t)((_workBuffer[i] * kRejectNum + 128) >> 8);
            }
        }
    }
    // skinVerificationEnabled=NO or chromaPtr=nil → _workBuffer unchanged → exact Step 3.

    // ── Feathering pass ───────────────────────────────────────────────────
    // Phase A.1 (DEC-113): luma-guided edge-aware feathering is DISABLED.
    // VGSegmentationNode always passes lumaBuffer=NULL, so capturedLuma is nil.
    // All feathering uses the Gaussian fallback — exact Step 1 behaviour.
    //
    // This code path is kept intact so A.1 can be re-enabled by restoring luma
    // capture in VGSegmentationNode once PTS/generation-paired luma exists.
    // phaseAEnabled=YES path still guards Phase A.2 and A.3 below.
    const uint8_t *lumaPtr = (const uint8_t *)capturedLuma.bytes; // always NULL
    if (_phaseAEnabled && lumaPtr && capturedLumaW == qw && capturedLumaH == qh) {
        // This branch is never reached while A.1 is disabled (lumaPtr == NULL).
        _VGEdgeAwareFeatherR8(_workBuffer, qw, qh, _featherSigma, _featherRangeSigma, lumaPtr);
    } else {
        // Gaussian fallback — executed on ALL frames while A.1 is disabled.
        // phaseAEnabled=NO also lands here (exact Step 1 behaviour preserved).
        _VGGaussianBlurR8(_workBuffer, qw, qh, _featherSigma);
    }

    // ── Phase B.1: Adaptive EMA temporal smoothing (DEC-117) ─────────────
    //
    // Alpha is chosen based on the normalised displacement of the primary
    // face bounding-box centre between consecutive mask generations.
    //
    // Motion signal:
    //   displacement = Euclidean distance of face-bb centre (Vision coords)
    //   normalised to [0,1] by the diagonal of the unit square (√2 ≈ 1.41).
    //   In practice meaningful motion is 0.02–0.15 of the image diagonal.
    //
    // Alpha mapping (Phase B.1 constants — DEC-117):
    //   motion ≤ motionLow  → alpha = alphaMin (0.15) — strong smoothing
    //   motion ≥ motionHigh → alpha = alphaMax (0.70) — fast response
    //   intermediate        → smoothstep interpolation
    //
    // The previous bbox centre is stored as _prevBBoxCX/Y and is cleared by
    // resetTemporalState on seek/generation change.

    // ── Step 1: Compute motion ───────────────────────────────────────────
    static const float kAlphaMin    = 0.15f;
    static const float kAlphaMax    = 0.70f;
    static const float kMotionLow   = 0.02f;
    static const float kMotionHigh  = 0.15f;

    float alpha = kAlphaMin; // default: strong smoothing
    if (faces.count > 0) {
        CGRect primaryBB = [faces firstObject].boundingBox;
        CGFloat currCX = CGRectGetMidX(primaryBB);
        CGFloat currCY = CGRectGetMidY(primaryBB);

        if (_prevBBoxValid) {
            CGFloat dx = currCX - _prevBBoxCX;
            CGFloat dy = currCY - _prevBBoxCY;
            // Normalise by diagonal of unit square. Clamp to [0,1].
            float motion = (float)(sqrt(dx*dx + dy*dy) / 1.41421356f);
            motion = fminf(motion, 1.0f);

            // Smoothstep: t = (motion - low) / (high - low), clamped [0,1].
            float t = (motion - kMotionLow) / (kMotionHigh - kMotionLow);
            t = fmaxf(0.0f, fminf(1.0f, t));
            t = t * t * (3.0f - 2.0f * t); // smoothstep
            alpha = kAlphaMin + t * (kAlphaMax - kAlphaMin);
        }

        // Update previous bbox for next generation (mask-queue only — no race).
        _prevBBoxCX    = currCX;
        _prevBBoxCY    = currCY;
        _prevBBoxValid = YES;
    } else {
        // No face detected this generation: use minimum alpha (strong smoothing).
        // _prevBBoxValid remains unchanged — a subsequent detection restores tracking.
        alpha = kAlphaMin;
    }

    // ── Step 2: EMA blend ────────────────────────────────────────────────
    if (!_hasSmoothedData) {
        // First frame after init or reset: seed smoothed buffer directly.
        // No blending — first post-seek mask is authoritative.
        memcpy(_smoothedBuffer, _workBuffer, bufSize);
        _hasSmoothedData = YES;
    } else {
        // Subsequent frames: per-pixel EMA blend with adaptive alpha.
        // Integer fixed-point: a256 = alpha × 256, b256 = 256 - a256.
        int a256 = (int)(alpha * 256.0f + 0.5f);
        int b256 = 256 - a256;
        for (size_t i = 0; i < bufSize; i++) {
            _smoothedBuffer[i] = (uint8_t)((b256 * _smoothedBuffer[i] + a256 * _workBuffer[i] + 128) >> 8);
        }
    }

    // ── Publish immutable snapshot (guard against post-invalidate publish) ─
    if (atomic_load(&_invalidated)) return;

    // Publish the smoothed buffer, not the raw mask.
    NSData *snapData = [NSData dataWithBytes:_smoothedBuffer length:bufSize];
    VGSkinMask *mask = [[VGSkinMask alloc] _initWithData:snapData
                                                   width:qw
                                                  height:qh
                                               sourcePTS:result.sourcePTS
                                               faceCount:(NSInteger)faces.count];
    _latestMask = mask; // readonly property — must assign to ivar directly
}

// ---------------------------------------------------------------------------
// MARK: Feature exclusion (private)
// ---------------------------------------------------------------------------

/// Subtracts a feature region from the mask.
/// Phase A.2 (DEC-114): smooth smoothstep falloff replaces hard zero cutout.
/// Inner hull (at innerRadius fraction of pad expansion) = full exclusion (0).
/// Outer hull (at full pad expansion) = no exclusion (original value kept).
/// Transition uses smoothstep for natural fade without hard borders.
/// When phaseAEnabled=NO, falls back to hard zero (Step 1 behaviour).
- (void)_subtractFeature:(NSArray<NSValue *> * _Nullable)points
                     pad:(float)pad
                      bb:(CGRect)faceBB
                      qw:(size_t)qw
                      qh:(size_t)qh {
    if (!points || points.count < 3) return;

    NSUInteger count = points.count;

    // Build outer hull (expanded by pad — same as Step 1).
    CGPoint *outerPts = (CGPoint *)malloc(count * sizeof(CGPoint));
    if (!outerPts) return;

    CGFloat cxSum = 0, cySum = 0;
    for (NSUInteger i = 0; i < count; i++) {
        CGPoint norm = [points[i] CGPointValue];
        outerPts[i] = _VGNormToQuarterPixel(norm, qw, qh);
        cxSum += outerPts[i].x;
        cySum += outerPts[i].y;
    }
    CGFloat cx = cxSum / count;
    CGFloat cy = cySum / count;
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat dx = outerPts[i].x - cx;
        CGFloat dy = outerPts[i].y - cy;
        outerPts[i].x = cx + dx * (1.0f + pad);
        outerPts[i].y = cy + dy * (1.0f + pad);
    }

    if (!_phaseAEnabled) {
        // Step 1 behaviour: hard zero fill.
        _VGFillConvexPolygon(_workBuffer, qw, qh, outerPts, count, 0);
        free(outerPts);
        return;
    }

    // Phase A.2: smooth falloff.
    // Build inner hull (contracted from centroid by innerRadius fraction).
    float innerScale = fmaxf(0.0f, fminf(1.0f, _featureExclusionInnerRadius));
    CGPoint *innerPts = (CGPoint *)malloc(count * sizeof(CGPoint));
    if (!innerPts) {
        // Fallback to hard zero.
        _VGFillConvexPolygon(_workBuffer, qw, qh, outerPts, count, 0);
        free(outerPts);
        return;
    }
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat dx = outerPts[i].x - cx;
        CGFloat dy = outerPts[i].y - cy;
        innerPts[i].x = cx + dx * innerScale;
        innerPts[i].y = cy + dy * innerScale;
    }

    // Find bounding box of outer hull for scan.
    CGFloat minX = outerPts[0].x, maxX = outerPts[0].x;
    CGFloat minY = outerPts[0].y, maxY = outerPts[0].y;
    for (NSUInteger i = 1; i < count; i++) {
        if (outerPts[i].x < minX) minX = outerPts[i].x;
        if (outerPts[i].x > maxX) maxX = outerPts[i].x;
        if (outerPts[i].y < minY) minY = outerPts[i].y;
        if (outerPts[i].y > maxY) maxY = outerPts[i].y;
    }
    int yStart = MAX(0, (int)floor(minY));
    int yEnd   = MIN((int)qh - 1, (int)ceil(maxY));
    int xStart = MAX(0, (int)floor(minX));
    int xEnd   = MIN((int)qw - 1, (int)ceil(maxX));

    // For each pixel in the outer bounding box, compute a smooth exclusion.
    // distance_from_centroid normalised: 0 at cx,cy, 1 at outer hull edge.
    // smoothstep(innerScale, 1.0, t) → 0 inside, smooth in transition, 1 outside.
    for (int y = yStart; y <= yEnd; y++) {
        for (int x = xStart; x <= xEnd; x++) {
            // Check if inside outer hull using scanline test.
            // Simple point-in-polygon test via ray casting.
            BOOL insideOuter = NO;
            for (NSUInteger i = 0, j = count - 1; i < count; j = i++) {
                CGFloat xi = outerPts[i].x, yi = outerPts[i].y;
                CGFloat xj = outerPts[j].x, yj = outerPts[j].y;
                if (((yi > y) != (yj > y)) &&
                    (x < (xj - xi) * (y - yi) / (yj - yi) + xi)) {
                    insideOuter = !insideOuter;
                }
            }
            if (!insideOuter) continue;

            // Compute normalised distance from centroid in outer hull units.
            CGFloat dx = x - cx;
            CGFloat dy = y - cy;
            CGFloat dist = sqrtf((float)(dx*dx + dy*dy));

            // Outer hull distance at same angle (approx by scaling the max radius).
            // Simple approach: normalise by the outer hull bounding radius estimate.
            CGFloat outerR = sqrtf((float)(
                fmaxf((outerPts[0].x-cx)*(outerPts[0].x-cx),
                      (outerPts[count/2].x-cx)*(outerPts[count/2].x-cx)) +
                fmaxf((outerPts[0].y-cy)*(outerPts[0].y-cy),
                      (outerPts[count/2].y-cy)*(outerPts[count/2].y-cy))
            ));
            if (outerR < 1.0f) outerR = 1.0f;
            CGFloat t = (CGFloat)(dist / outerR); // 0 at center, ~1 at outer hull

            // smoothstep(innerScale, 1.0, t): 0 when t < innerScale, 1 when t > 1.
            CGFloat edge0 = innerScale, edge1 = 1.0;
            CGFloat s = (t - edge0) / (edge1 - edge0);
            s = fmaxf(0.0, fminf(1.0, s));
            CGFloat smooth = s * s * (3.0 - 2.0 * s); // smoothstep

            // Apply: multiply existing mask value by smooth exclusion factor.
            size_t idx = y * qw + x;
            uint8_t existing = _workBuffer[idx];
            _workBuffer[idx] = (uint8_t)(existing * smooth + 0.5);
        }
    }

    free(outerPts);
    free(innerPts);
}

// ---------------------------------------------------------------------------
// MARK: Invalidate
// ---------------------------------------------------------------------------

- (void)invalidate {
    atomic_store(&_invalidated, true);
    // Dispatch a final block to the mask queue to safely free working buffers
    // after any in-flight generation completes.
    dispatch_async(_maskQueue, ^{
        free(self->_workBuffer);
        self->_workBuffer     = NULL;
        self->_workBufferSize = 0;
        free(self->_smoothedBuffer);
        self->_smoothedBuffer     = NULL;
        self->_smoothedBufferSize = 0;
        self->_hasSmoothedData    = NO;
        // Note: capturedLuma (NSData) is owned by the dispatch block that used it.
        // ARC releases it when the block completes. No manual free needed here.
    });
    _latestMask = nil;
}

- (void)dealloc {
    // If invalidate was not called, free buffers directly.
    // Safe because dealloc only runs after all strong refs (including blocks) are gone.
    free(_workBuffer);
    free(_smoothedBuffer);
}

@end
