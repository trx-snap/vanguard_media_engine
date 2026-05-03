// VGSkinMaskGenerator.m
// Phase 4C — Step 2: CPU skin mask generation from face landmarks (DEC-62/64).
//
// Algorithm:
//   1. Allocate (or reuse) a quarter-res R8 buffer.
//   RR-55  — mask edge leakage (mitigated by Gaussian feathering)
//   RR-57  — temporal mask flicker (mitigated by EMA smoothing, Step 4)
//   RR-59  — R8 precision banding (mitigated by bilinear sampling in Step 3)
//   3. For each detected face:
//      a. If faceContourPoints available: fill convex hull → 255.
//      b. Else: fill soft ellipse from boundingBox → 255.
//      c. Subtract exclusion zones (eyes, eyebrows, lips) → 0.
//   4. Apply Gaussian blur to feather edges.
//   5. EMA blend with previous frame's smoothed buffer.
//   6. Publish as atomic VGSkinMask snapshot.
//
// All coordinates are Vision-normalised [0,1] (origin = bottom-left).
// Conversion to quarter-res pixel coords: x_q = norm.x * (w/4), y_q = (1 - norm.y) * (h/4).
// The Y-flip converts Vision bottom-left origin to top-left raster origin.

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
    // Persists across frames on _maskQueue. Each new raw mask is blended
    // toward this buffer with smoothingAlpha before publishing.
    uint8_t *_smoothedBuffer;
    size_t   _smoothedBufferSize;
    BOOL     _hasSmoothedData;  // false until first mask is generated

    // Private serial queue — all rasterization + vImage work runs here.
    dispatch_queue_t _maskQueue;
    // Atomic in-flight guard — prevents overlapping generations.
    atomic_bool      _generationInFlight;
    // Atomic invalidation flag — prevents stale mask publishes.
    atomic_bool      _invalidated;
}

@synthesize latestMask             = _latestMask;
@synthesize featherSigma           = _featherSigma;
@synthesize faceOvalInset          = _faceOvalInset;
@synthesize featureExclusionPadding = _featureExclusionPadding;
@synthesize smoothingAlpha         = _smoothingAlpha;

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _featherSigma           = 8.0f;   // DEC-62: σ=8 at quarter-res
    _faceOvalInset          = 0.05f;  // 5% inset to avoid mask leakage (RR-55)
    _featureExclusionPadding = 0.15f; // 15% expansion for feature zones
    _smoothingAlpha         = 0.3f;   // Step 4 (RR-57): EMA convergence rate
    _workBuffer     = NULL;
    _workBufferSize = 0;
    _smoothedBuffer     = NULL;
    _smoothedBufferSize = 0;
    _hasSmoothedData    = NO;
    _lastQW = 0;
    _lastQH = 0;
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
    // ── Gate 1: invalidated or nil result → no-op ─────────────────────────
    if (atomic_load(&_invalidated) || !result) return;
    if (sourceWidth < 4 || sourceHeight < 4) return;

    // ── Gate 2: coalesce — skip if previous generation still in-flight ────
    if (atomic_exchange(&_generationInFlight, true)) return;

    // Capture scalar dimensions by value for the block (safe copy).
    size_t capturedW = sourceWidth;
    size_t capturedH = sourceHeight;
    // VGFaceDetectionResult is an ObjC object — block retains it automatically.

    __weak typeof(self) weakSelf = self;
    dispatch_async(_maskQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || atomic_load(&strongSelf->_invalidated)) {
            if (strongSelf) atomic_store(&strongSelf->_generationInFlight, false);
            return;
        }
        [strongSelf _generateMaskForResult:result
                               sourceWidth:capturedW
                              sourceHeight:capturedH];
        atomic_store(&strongSelf->_generationInFlight, false);
    });
}

// ---------------------------------------------------------------------------
// MARK: Internal synchronous generation (runs on _maskQueue only)
// ---------------------------------------------------------------------------

- (void)_generateMaskForResult:(VGFaceDetectionResult *)result
                   sourceWidth:(size_t)sourceWidth
                  sourceHeight:(size_t)sourceHeight {
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

        // --- 2. Subtract exclusion zones (features = 0) ---
        float pad = _featureExclusionPadding;
        [self _subtractFeature:face.leftEyePoints      pad:pad bb:bb qw:qw qh:qh];
        [self _subtractFeature:face.rightEyePoints     pad:pad bb:bb qw:qw qh:qh];
        [self _subtractFeature:face.leftEyebrowPoints  pad:pad bb:bb qw:qw qh:qh];
        [self _subtractFeature:face.rightEyebrowPoints pad:pad bb:bb qw:qw qh:qh];
        [self _subtractFeature:face.outerLipsPoints    pad:pad bb:bb qw:qw qh:qh];
    }

    // ── Gaussian feather (DEC-62 / RR-55) ────────────────────────────────
    _VGGaussianBlurR8(_workBuffer, qw, qh, _featherSigma);

    // ── Phase 4C Step 4: EMA temporal smoothing (RR-57) ──────────────────
    // Blend the new raw mask toward the persistent smoothed buffer.
    // smoothed[i] = lerp(smoothed[i], raw[i], alpha)
    // This eliminates frame-to-frame jitter from landmark noise and detection
    // cadence without adding latency beyond ~3 frames (alpha=0.3 → 90% converged
    // in ~7 frames ≈ 230ms at 30fps — well within acceptable lag).
    float alpha = fminf(fmaxf(_smoothingAlpha, 0.0f), 1.0f);
    if (!_hasSmoothedData) {
        // First frame: seed smoothed buffer with raw mask (no blending lag).
        memcpy(_smoothedBuffer, _workBuffer, bufSize);
        _hasSmoothedData = YES;
    } else {
        // Subsequent frames: per-pixel EMA blend.
        // Integer arithmetic avoids float conversion per pixel:
        //   smoothed = smoothed + alpha * (raw - smoothed)
        //            = (1 - alpha) * smoothed + alpha * raw
        // Using fixed-point: a256 = alpha * 256, b256 = 256 - a256.
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

/// Subtracts a feature region from the mask by filling its convex hull
/// (expanded by `pad`) with 0.
- (void)_subtractFeature:(NSArray<NSValue *> * _Nullable)points
                     pad:(float)pad
                      bb:(CGRect)faceBB
                      qw:(size_t)qw
                      qh:(size_t)qh {
    if (!points || points.count < 3) return;

    // Convert normalised points to quarter-res pixels.
    NSUInteger count = points.count;
    CGPoint *pixPts = (CGPoint *)malloc(count * sizeof(CGPoint));
    if (!pixPts) return;

    CGFloat cxSum = 0, cySum = 0;
    for (NSUInteger i = 0; i < count; i++) {
        CGPoint norm = [points[i] CGPointValue];
        pixPts[i] = _VGNormToQuarterPixel(norm, qw, qh);
        cxSum += pixPts[i].x;
        cySum += pixPts[i].y;
    }

    // Expand polygon outward from centroid by padding factor.
    CGFloat cx = cxSum / count;
    CGFloat cy = cySum / count;
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat dx = pixPts[i].x - cx;
        CGFloat dy = pixPts[i].y - cy;
        pixPts[i].x = cx + dx * (1.0f + pad);
        pixPts[i].y = cy + dy * (1.0f + pad);
    }

    _VGFillConvexPolygon(_workBuffer, qw, qh, pixPts, count, 0);
    free(pixPts);
}

// ---------------------------------------------------------------------------
// MARK: Invalidate
// ---------------------------------------------------------------------------

- (void)invalidate {
    atomic_store(&_invalidated, true);
    // Dispatch a final block to the mask queue to safely free the working
    // buffers after any in-flight generation completes.
    dispatch_async(_maskQueue, ^{
        free(self->_workBuffer);
        self->_workBuffer     = NULL;
        self->_workBufferSize = 0;
        free(self->_smoothedBuffer);
        self->_smoothedBuffer     = NULL;
        self->_smoothedBufferSize = 0;
        self->_hasSmoothedData    = NO;
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
