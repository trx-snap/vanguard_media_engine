// VGStillImageROIProcessor.m
// vanguard_media_engine — Phase 10-D.4A
//
// Synchronous Vision face detection + CIImage grayscale mask generation.
//
// Algorithm:
//   1. Convert UIImage → CGImage → run VNDetectFaceRectanglesRequest
//      synchronously with kCGImagePropertyOrientationUp (UIImage has already
//      baked EXIF orientation via its decode path).
//   2. Filter observations by minFaceRatio.
//   3. For each accepted observation, map normalized [0,1] Vision coords
//      (bottom-left origin) to canvas pixel coords:
//         pixelX = vision.x * canvasWidth
//         pixelY = vision.y * canvasHeight
//         (No Y inversion: both Vision and CI use bottom-left origin.)
//   4. Apply configured expansion margins, clamp to canvas bounds.
//   5. Rasterize a feathered ellipse per face into a quarter-resolution
//      grayscale vImage_Buffer using a soft radial gradient falloff.
//   6. Create a CIImage from the quarter-res buffer.
//   7. Scale to full canvas resolution via CILanczosScaleTransform.
//   8. Apply CIGaussianBlur for edge feathering.
//   9. Clamp to [0,1] and crop to canvas bounds.
//
// Memory contract:
//   - Quarter-res buffer is freed after CIImage creation.
//   - One CIContext is shared (file-static, dispatch_once).
//   - The returned VGROIDetectionResult owns its CIImage.
//   - This class is single-use per-call (not pooled).
//
// Phase 10-D.4A — derivative-only. Master export is never modified.

#import "VGStillImageROIProcessor.h"
#import <Vision/Vision.h>
#import <Accelerate/Accelerate.h>
#import <CoreImage/CoreImage.h>

// ─── Shared CIContext ─────────────────────────────────────────────────────────
// Separate from all other node contexts (each class owns its own static context).
static CIContext *_VGROIProcessorSharedCIContext(void) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *opts = @{
            kCIContextCacheIntermediates: @NO,
            kCIContextUseSoftwareRenderer: @NO,
        };
        ctx = [CIContext contextWithOptions:opts];
    });
    return ctx;
}

// ─── VGROIFaceRegion ──────────────────────────────────────────────────────────

@implementation VGROIFaceRegion {
    CGRect _pixelRect;
    float  _confidence;
}

@synthesize pixelRect  = _pixelRect;
@synthesize confidence = _confidence;

- (instancetype)_initWithPixelRect:(CGRect)rect confidence:(float)confidence {
    self = [super init];
    if (!self) return nil;
    _pixelRect  = rect;
    _confidence = confidence;
    return self;
}

@end

// ─── VGROIDetectionResult ─────────────────────────────────────────────────────

@implementation VGROIDetectionResult {
    NSArray<VGROIFaceRegion *> *_faceRegions;
    CIImage                    *_maskImage;
    NSString                   *_detectorTag;
}

@synthesize faceRegions  = _faceRegions;
@synthesize maskImage    = _maskImage;
@synthesize detectorTag  = _detectorTag;

- (instancetype)_initWithFaceRegions:(NSArray<VGROIFaceRegion *> *)regions
                           maskImage:(CIImage * _Nullable)mask {
    self = [super init];
    if (!self) return nil;
    _faceRegions  = [regions copy];
    _maskImage    = mask;
    _detectorTag  = @"vision_face_box";
    return self;
}

@end

// ─── VGStillImageROIProcessor ────────────────────────────────────────────────

@implementation VGStillImageROIProcessor

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    // Plan defaults (§3.4).
    _faceExpandX        = 0.25;
    _faceExpandYTop     = 0.35;
    _faceExpandYBottom  = 0.15;
    _minFaceRatio       = 0.05;
    _featherRadius      = 18.0;
    return self;
}

// ─── Public entry point ───────────────────────────────────────────────────────

- (VGROIDetectionResult *)detectAndBuildMaskForImage:(UIImage *)sourceImage
                                         canvasWidth:(NSInteger)canvasWidth
                                        canvasHeight:(NSInteger)canvasHeight {
    NSParameterAssert(sourceImage != nil);
    NSParameterAssert(canvasWidth > 0);
    NSParameterAssert(canvasHeight > 0);

    // ── Step 1: Vision face detection ─────────────────────────────────────
    // Run on the source CGImage (full resolution). UIImage has already baked
    // EXIF orientation, so we specify kCGImagePropertyOrientationUp.
    CGImageRef cgImage = sourceImage.CGImage;
    if (!cgImage) {
        NSLog(@"[VGStillImageROIProcessor] UIImage has no CGImage — no ROI.");
        return [[VGROIDetectionResult alloc] _initWithFaceRegions:@[] maskImage:nil];
    }

    VNDetectFaceRectanglesRequest *faceRequest =
        [[VNDetectFaceRectanglesRequest alloc] init];
    // v1: bounding boxes only — no landmarks needed.

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc]
        initWithCGImage:cgImage
            orientation:kCGImagePropertyOrientationUp
                options:@{}];

    NSError *error = nil;
    BOOL ok = [handler performRequests:@[faceRequest] error:&error];
    if (!ok || error) {
        NSLog(@"[VGStillImageROIProcessor] Vision error: %@ — no ROI.",
              error.localizedDescription);
        return [[VGROIDetectionResult alloc] _initWithFaceRegions:@[] maskImage:nil];
    }

    NSArray<VNFaceObservation *> *observations = faceRequest.results;
    if (observations.count == 0) {
        NSLog(@"[VGStillImageROIProcessor] No faces detected.");
        return [[VGROIDetectionResult alloc] _initWithFaceRegions:@[] maskImage:nil];
    }

    // ── Step 2: Map Vision coords → canvas pixel coords + expand ──────────
    double cW = (double)canvasWidth;
    double cH = (double)canvasHeight;
    double minEdge = MIN(cW, cH);

    NSMutableArray<VGROIFaceRegion *> *accepted = [NSMutableArray array];

    for (VNFaceObservation *obs in observations) {
        CGRect vb = obs.boundingBox; // normalized, bottom-left origin

        // Map to pixel coords (no Y inversion: both Vision and CI are BL-origin).
        double px = vb.origin.x * cW;
        double py = vb.origin.y * cH;
        double pw = vb.size.width  * cW;
        double ph = vb.size.height * cH;

        // Minimum face size gate.
        double faceEdge = MAX(pw, ph);
        if (faceEdge < _minFaceRatio * minEdge) {
            NSLog(@"[VGStillImageROIProcessor] Face too small (%.1f px < %.1f threshold) — skip.",
                  faceEdge, _minFaceRatio * minEdge);
            continue;
        }

        // Apply expansion margins.
        double expandLeft   = pw * _faceExpandX;
        double expandRight  = pw * _faceExpandX;
        double expandTop    = ph * _faceExpandYTop;
        double expandBottom = ph * _faceExpandYBottom;

        double ex = px - expandLeft;
        double ey = py - expandBottom;
        double ew = pw + expandLeft + expandRight;
        double eh = ph + expandBottom + expandTop;

        // Clamp to canvas bounds.
        ex = MAX(0.0, MIN(ex, cW - 1.0));
        ey = MAX(0.0, MIN(ey, cH - 1.0));
        double ex2 = MIN(ex + ew, cW);
        double ey2 = MIN(ey + eh, cH);
        ew = ex2 - ex;
        eh = ey2 - ey;

        if (ew <= 0 || eh <= 0) continue;

        CGRect pixelRect = CGRectMake(ex, ey, ew, eh);
        VGROIFaceRegion *region = [[VGROIFaceRegion alloc]
            _initWithPixelRect:pixelRect
                    confidence:obs.confidence];
        [accepted addObject:region];
    }

    if (accepted.count == 0) {
        NSLog(@"[VGStillImageROIProcessor] No faces passed size filter — no ROI.");
        return [[VGROIDetectionResult alloc] _initWithFaceRegions:@[] maskImage:nil];
    }

    NSLog(@"[VGStillImageROIProcessor] %lu face(s) accepted for ROI mask.",
          (unsigned long)accepted.count);

    // ── Step 3: Rasterize quarter-res grayscale mask via vImage ───────────
    // Quarter-res for speed; bilinearly upscaled + Gaussian feathered later.
    NSInteger qW = MAX(1, canvasWidth  / 4);
    NSInteger qH = MAX(1, canvasHeight / 4);
    double qScaleX = (double)qW / cW;
    double qScaleY = (double)qH / cH;

    // Allocate grayscale buffer (8-bit, 1 channel).
    size_t rowBytes = (size_t)qW;
    uint8_t *pixels = (uint8_t *)calloc(rowBytes * (size_t)qH, sizeof(uint8_t));
    if (!pixels) {
        NSLog(@"[VGStillImageROIProcessor] calloc failed — no ROI.");
        return [[VGROIDetectionResult alloc] _initWithFaceRegions:accepted maskImage:nil];
    }

    // Rasterize each face as a soft ellipse.
    // A soft radial gradient: value = clamp(1 - r^2, 0, 1) where r is the
    // normalized ellipse radius ([0,1] at the ellipse boundary).
    for (VGROIFaceRegion *region in accepted) {
        CGRect r  = region.pixelRect;
        double cx = (r.origin.x + r.size.width  * 0.5) * qScaleX;
        double cy = (r.origin.y + r.size.height * 0.5) * qScaleY;
        double ax = (r.size.width  * 0.5) * qScaleX;
        double ay = (r.size.height * 0.5) * qScaleY;
        if (ax <= 0 || ay <= 0) continue;

        // Scan the bounding box of the ellipse (with 1px margin).
        NSInteger xMin = (NSInteger)MAX(0.0,       floor(cx - ax - 1.0));
        NSInteger xMax = (NSInteger)MIN((double)qW - 1.0, ceil(cx + ax + 1.0));
        NSInteger yMin = (NSInteger)MAX(0.0,       floor(cy - ay - 1.0));
        NSInteger yMax = (NSInteger)MIN((double)qH - 1.0, ceil(cy + ay + 1.0));

        for (NSInteger y = yMin; y <= yMax; y++) {
            for (NSInteger x = xMin; x <= xMax; x++) {
                double dx = ((double)x - cx) / ax;
                double dy = ((double)y - cy) / ay;
                double r2 = dx*dx + dy*dy;
                // Soft-clip: 1.0 inside, smooth falloff near boundary.
                // Using quadratic: v = clamp(1 - r2, 0, 1).
                double v = 1.0 - r2;
                if (v <= 0.0) continue;
                if (v > 1.0) v = 1.0;

                uint8_t val = (uint8_t)(v * 255.0 + 0.5);
                size_t idx  = (size_t)y * rowBytes + (size_t)x;
                // Union: take the maximum value across faces.
                if (pixels[idx] < val) pixels[idx] = val;
            }
        }
    }

    // ── Step 4: Wrap in CIImage (grayscale / kCVPixelFormatType_OneComponent8) 
    // Use NSData to back the CIImage directly from the buffer.
    NSData *bufferData = [NSData dataWithBytesNoCopy:pixels
                                              length:rowBytes * (size_t)qH
                                        freeWhenDone:YES]; // takes ownership
    CIImage *quarterMask = [CIImage imageWithBitmapData:bufferData
                                            bytesPerRow:rowBytes
                                                   size:CGSizeMake((CGFloat)qW, (CGFloat)qH)
                                                 format:kCIFormatL8
                                             colorSpace:nil]; // nil = grayscale

    if (!quarterMask) {
        NSLog(@"[VGStillImageROIProcessor] CIImage from bitmap failed — no ROI mask.");
        return [[VGROIDetectionResult alloc] _initWithFaceRegions:accepted maskImage:nil];
    }

    // ── Step 5: Upscale to canvas resolution ──────────────────────────────
    // Scale factors from quarter → canvas.
    double scaleX = cW / (double)qW;
    double scaleY = cH / (double)qH;

    CIFilter *scaleFilter = [CIFilter filterWithName:@"CILanczosScaleTransform"];
    if (!scaleFilter) {
        scaleFilter = [CIFilter filterWithName:@"CIAffineTransform"];
        if (scaleFilter) {
            CGAffineTransform t = CGAffineTransformMakeScale(scaleX, scaleY);
            [scaleFilter setValue:[NSValue valueWithCGAffineTransform:t]
                          forKey:@"inputTransform"];
            [scaleFilter setValue:quarterMask forKey:kCIInputImageKey];
        }
    } else {
        // LanczosScaleTransform uses `inputScale` (Y-axis) and `inputAspectRatio`.
        double uniformScale = cH / (double)qH;
        double aspect       = scaleX / scaleY; // compensate for non-square quarter
        [scaleFilter setValue:@(uniformScale) forKey:@"inputScale"];
        [scaleFilter setValue:@(aspect)       forKey:@"inputAspectRatio"];
        [scaleFilter setValue:quarterMask     forKey:kCIInputImageKey];
    }

    CIImage *scaledMask = scaleFilter ? scaleFilter.outputImage : nil;
    if (!scaledMask) {
        // Fallback: affine scale manually via imageByApplyingTransform.
        CGAffineTransform t = CGAffineTransformMakeScale(scaleX, scaleY);
        scaledMask = [quarterMask imageByApplyingTransform:t];
    }

    // ── Step 6: Gaussian feather ───────────────────────────────────────────
    CIFilter *blurFilter = [CIFilter filterWithName:@"CIGaussianBlur"];
    CIImage *featheredMask = scaledMask;
    if (blurFilter && scaledMask) {
        [blurFilter setValue:scaledMask  forKey:kCIInputImageKey];
        [blurFilter setValue:@(_featherRadius) forKey:@"inputRadius"];
        CIImage *blurred = blurFilter.outputImage;
        if (blurred) featheredMask = blurred;
    }

    // ── Step 7: Clamp to canvas bounds ────────────────────────────────────
    CGRect canvasBounds = CGRectMake(0, 0, cW, cH);
    CIImage *finalMask  = [featheredMask imageByCroppingToRect:canvasBounds];
    if (!finalMask) finalMask = featheredMask;

    return [[VGROIDetectionResult alloc] _initWithFaceRegions:accepted
                                                    maskImage:finalMask];
}

@end
