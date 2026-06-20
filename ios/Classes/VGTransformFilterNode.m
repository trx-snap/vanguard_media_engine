// VGTransformFilterNode.m
// vanguard_media_engine — Phase 10-C-3L.1D
//
// Spatial transform filter for still-image export.
//
// Transform pipeline (documented in VGTransformFilterNode.h):
//   1. Crop      – CIImage.imageByCroppingToRect (optional)
//   2. Rotate    – CGAffineTransform rotation around image center
//   3. Flip      – CGAffineTransformMakeScale(-1, 1) around rotated-image center
//   4. Aspect-fill + Zoom scale
//   5. Pan       – normalized offset → pixel translation, Y-inverted for CIImage
//   6. Composite – source over black CIImage canvas
//   7. Crop to canvas bounds
//   8. Render    – [CIContext render:toCVPixelBuffer:bounds:colorSpace:]
//
// CIImage coordinate origin: bottom-left (Y-up).
// Flutter preview coordinate origin: top-left (Y-down).
// offsetY is negated when converting to CIImage translation (see Step 5 below).
//
// Buffer ownership (DEC-44 / RR-28):
//   processBuffer:atTime:device: returns a +1 CVPixelBuffer owned by the caller.
//   If the filter is disabled/passthrough, it CVPixelBufferRetains the input
//   and returns it unchanged. The caller releases the returned buffer.

#import "VGTransformFilterNode.h"
#import <CoreImage/CoreImage.h>
#import <os/lock.h>

// ─── Shared CIContext ─────────────────────────────────────────────────────────
//
// CIContext creation is expensive (allocates GPU resources). We use a single
// shared context for all VGTransformFilterNode instances, matching the pattern
// in VGTimelineCompositorNode (_VGTCNSharedCIContext).
// The context is created lazily on the first processBuffer: call.
// Metal-backed for hardware acceleration on all iOS devices.

static CIContext *_VGTFNSharedCIContext(void) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Use Metal rendering pipeline. kCIContextCacheIntermediates=NO reduces
        // peak memory for one-shot export (no benefit from caching for single frame).
        NSDictionary *opts = @{
            kCIContextCacheIntermediates: @NO,
            kCIContextUseSoftwareRenderer: @NO,
        };
        ctx = [CIContext contextWithOptions:opts];
    });
    return ctx;
}

@implementation VGTransformFilterNode {
    CVPixelBufferPoolRef _pool;   // nullable; nil = one-shot export allocation
    id<MTLDevice>        _device;

    // Transform parameters (immutable after init).
    NSInteger _canvasWidth;
    NSInteger _canvasHeight;
    double    _scale;
    double    _offsetX;
    double    _offsetY;
    NSInteger _quarterTurns;  // [0, 3]; clockwise
    BOOL      _flipX;
    NSArray<NSNumber *> * _Nullable _cropRect; // nil or [x, y, w, h] normalized
}

@synthesize filterName = _filterName;
@synthesize enabled    = _enabled;
@synthesize nodeId     = _nodeId;
@synthesize nodeType   = _nodeType;

// ─── VGMetalFilterNode cost model ────────────────────────────────────────────

// CIImage affine + composite is moderate GPU cost. Estimated ~3ms on A14 at
// typical export resolutions (1080×1920). More expensive than color matrix
// (1.5ms) because it involves a compositing pass, but cheaper than timeline
// compositor.
- (BOOL)isExpensive {
    return NO;
}

- (VGNodeRole)nodeRole {
    return VGNodeRoleFilter;
}

- (float)estimatedGPUCostMs {
    return 3.0f;
}

// ─── Init ─────────────────────────────────────────────────────────────────────

- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
                 canvasWidth:(NSInteger)canvasWidth
                canvasHeight:(NSInteger)canvasHeight
                       scale:(double)scale
                     offsetX:(double)offsetX
                     offsetY:(double)offsetY
                quarterTurns:(NSInteger)quarterTurns
                       flipX:(BOOL)flipX
                    cropRect:(nullable NSArray<NSNumber *> *)cropRect {
    NSParameterAssert(device != nil);
    NSParameterAssert(canvasWidth > 0);
    NSParameterAssert(canvasHeight > 0);
    NSParameterAssert(scale > 0);

    self = [super init];
    if (!self) return nil;

    _pool         = pool;
    _device       = device;
    _canvasWidth  = canvasWidth;
    _canvasHeight = canvasHeight;
    _scale        = scale;
    _offsetX      = offsetX;
    _offsetY      = offsetY;
    // Normalize quarter turns to [0, 3] defensively.
    _quarterTurns = ((quarterTurns % 4) + 4) % 4;
    _flipX        = flipX;
    _cropRect     = [cropRect copy];

    _enabled     = YES;
    _filterName  = @"Transform";
    _nodeId      = [[NSUUID UUID] UUIDString];
    _nodeType    = @"VGTransformFilterNode";

    return self;
}

- (void)dealloc {
    // No Metal PSO or command queue to release — CIContext is shared/static.
    // CVPixelBufferPool is not retained by this node (passed in from caller).
}

// ─── VanguardFilterNode — processBuffer:atTime:device: ───────────────────────

- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)t
                           device:(id<MTLDevice>)device {
    // Passthrough.
    if (!_enabled) {
        CVPixelBufferRetain(input);
        return input;
    }

    // ── Step 0: Source dimensions ──────────────────────────────────────────
    size_t srcW = CVPixelBufferGetWidth(input);
    size_t srcH = CVPixelBufferGetHeight(input);

    if (srcW == 0 || srcH == 0) {
        NSLog(@"[VGTransformFilterNode] processBuffer: input has zero dimension (%zu×%zu). Passthrough.", srcW, srcH);
        CVPixelBufferRetain(input);
        return input;
    }

    // ── Step 1: Wrap input CVPixelBuffer in CIImage ────────────────────────
    //
    // CIImage(cvPixelBuffer:) creates a CIImage backed by the CVPixelBuffer's
    // IOSurface. This does NOT copy pixels — it references the source buffer.
    // CIImage coordinate origin is bottom-left (Y-up).
    CIImage *source = [CIImage imageWithCVPixelBuffer:input];
    if (!source) {
        NSLog(@"[VGTransformFilterNode] Failed to create CIImage from input buffer. Passthrough.");
        CVPixelBufferRetain(input);
        return input;
    }

    // ── Step 2: Crop (optional) ───────────────────────────────────────────
    //
    // cropRect is normalized [x, y, w, h] in top-left UIKit/Dart convention.
    // CIImage uses bottom-left origin, so we must convert the Y coordinate:
    //   ciY = srcH - (normalizedY * srcH) - (normalizedH * srcH)
    //       = srcH * (1.0 - normalizedY - normalizedH)
    //
    // After this step, source.extent.size is the cropped dimensions.
    if (_cropRect && _cropRect.count == 4) {
        double nx = _cropRect[0].doubleValue;
        double ny = _cropRect[1].doubleValue;
        double nw = _cropRect[2].doubleValue;
        double nh = _cropRect[3].doubleValue;

        // Clamp defensively.
        nx = MAX(0.0, MIN(1.0, nx));
        ny = MAX(0.0, MIN(1.0, ny));
        nw = MAX(0.0, MIN(1.0 - nx, nw));
        nh = MAX(0.0, MIN(1.0 - ny, nh));

        if (nw > 0 && nh > 0) {
            // Convert from Dart top-left to CIImage bottom-left.
            double ciX = nx * srcW;
            double ciY = (1.0 - ny - nh) * srcH;   // Y-invert for CIImage
            double ciW = nw * srcW;
            double ciH = nh * srcH;

            CGRect cropRect = CGRectMake(ciX, ciY, ciW, ciH);
            // imageByCroppingToRect does NOT translate the image — the origin
            // of the cropped image in CI space is at (ciX, ciY), not (0,0).
            // We translate to reset the origin to (0,0) so subsequent affine
            // math can treat the cropped image as starting at the origin.
            CIImage *cropped = [source imageByCroppingToRect:cropRect];
            CGAffineTransform resetOrigin = CGAffineTransformMakeTranslation(-ciX, -ciY);
            source = [cropped imageByApplyingTransform:resetOrigin];
        }
    }

    // Effective source dimensions (after crop).
    CGRect sourceExtent = source.extent;
    double effW = sourceExtent.size.width;
    double effH = sourceExtent.size.height;

    if (effW <= 0 || effH <= 0) {
        NSLog(@"[VGTransformFilterNode] Crop produced zero-sized source (%g×%g). Passthrough.", effW, effH);
        CVPixelBufferRetain(input);
        return input;
    }

    // ── Step 3: Rotate ────────────────────────────────────────────────────
    //
    // Rotation is clockwise by quarterTurns × 90°.
    // CGAffineTransform rotation is counter-clockwise in standard coordinates.
    // CIImage uses standard (bottom-left/Y-up) coordinates — the same as Core
    // Graphics, so CGAffineTransform math maps directly.
    //
    // To rotate CW by θ we apply a CCW rotation of -θ in standard coords.
    //   angle = -quarterTurns * π/2
    //
    // We rotate around the center of the source image:
    //   1. Translate center to origin.
    //   2. Apply rotation.
    //   3. Translate back.
    //
    // After rotation:
    //   if quarterTurns is odd → effectiveW/H swap
    double rotatedW, rotatedH;
    if (_quarterTurns == 0) {
        rotatedW = effW;
        rotatedH = effH;
    } else {
        double angle = -(M_PI_2 * _quarterTurns);  // CCW in standard coords = CW visually
        double cx = effW / 2.0;
        double cy = effH / 2.0;

        // Translate image so its center is at the CIImage coordinate origin.
        CGAffineTransform toOrigin = CGAffineTransformMakeTranslation(-cx, -cy);
        // Rotate.
        CGAffineTransform rotate = CGAffineTransformMakeRotation(angle);
        // After rotation, the rotated image bounds determine the new center.
        // For 90° / 270° rotation, width and height swap.
        if (_quarterTurns % 2 == 1) {
            rotatedW = effH;
            rotatedH = effW;
        } else {
            rotatedW = effW;
            rotatedH = effH;
        }
        // Translate back to positive coordinates so image is at (0, 0).
        CGAffineTransform fromOrigin = CGAffineTransformMakeTranslation(rotatedW / 2.0, rotatedH / 2.0);

        CGAffineTransform fullRotation = CGAffineTransformConcat(
            CGAffineTransformConcat(toOrigin, rotate),
            fromOrigin
        );
        source = [source imageByApplyingTransform:fullRotation];
        // Reset origin after rotation (rotation can shift the extent origin).
        CGRect rotExtent = source.extent;
        if (rotExtent.origin.x != 0 || rotExtent.origin.y != 0) {
            CGAffineTransform normalize = CGAffineTransformMakeTranslation(
                -rotExtent.origin.x, -rotExtent.origin.y
            );
            source = [source imageByApplyingTransform:normalize];
        }
    }

    // ── Step 4: Flip (horizontal mirror) ──────────────────────────────────
    //
    // Applied after rotation. Mirror around the vertical axis of the
    // rotated image (i.e., around the center X of the rotated image).
    // This matches Flutter: Transform.scale(scaleX: -1) is the OUTER widget
    // wrapping RotatedBox (the INNER widget).
    //
    // In CIImage terms: translate -centerX, scale(-1, 1), translate +centerX.
    if (_flipX) {
        double cx = rotatedW / 2.0;
        CGAffineTransform toCenter = CGAffineTransformMakeTranslation(-cx, 0);
        CGAffineTransform mirror   = CGAffineTransformMakeScale(-1, 1);
        CGAffineTransform fromCenter = CGAffineTransformMakeTranslation(cx, 0);
        CGAffineTransform fullMirror = CGAffineTransformConcat(
            CGAffineTransformConcat(toCenter, mirror),
            fromCenter
        );
        source = [source imageByApplyingTransform:fullMirror];
        // After horizontal mirror the extent.origin.x may be negative.
        // Normalize back to (0, 0).
        CGRect flipExtent = source.extent;
        if (flipExtent.origin.x != 0 || flipExtent.origin.y != 0) {
            CGAffineTransform normalize = CGAffineTransformMakeTranslation(
                -flipExtent.origin.x, -flipExtent.origin.y
            );
            source = [source imageByApplyingTransform:normalize];
        }
    }

    // At this point source has extent at (0, 0) with size (rotatedW, rotatedH).
    // Ensure rotatedW/rotatedH match actual extent for correctness.
    {
        CGRect ext = source.extent;
        rotatedW = ext.size.width;
        rotatedH = ext.size.height;
    }

    // ── Step 5: Aspect-fill scale + zoom ──────────────────────────────────
    //
    // Compute the base aspect-fill scale to fit (rotatedW, rotatedH) into
    // the canvas, then multiply by the user zoom `_scale`.
    //
    // Matches Flutter _computeCenteredOffset/_computeMaxDelta from
    // editor_preview_area.dart:
    //   mediaAspect = rotatedW / rotatedH
    //   canvasAspect = canvasW / canvasH
    //   if mediaAspect > canvasAspect: childH=canvasH, childW=canvasH*mediaAspect
    //   else: childW=canvasW, childH=canvasW/mediaAspect
    double canvasW = (double)_canvasWidth;
    double canvasH = (double)_canvasHeight;
    double mediaAspect  = rotatedW / rotatedH;
    double canvasAspect = canvasW / canvasH;

    double childW, childH;
    if (mediaAspect > canvasAspect) {
        childH = canvasH;
        childW = canvasH * mediaAspect;
    } else {
        childW = canvasW;
        childH = canvasW / mediaAspect;
    }

    double renderedW = childW * _scale;
    double renderedH = childH * _scale;

    // Uniform scale factor from source space to rendered canvas space.
    // baseScale fits the source at 1× zoom; multiply by _scale for user zoom.
    double baseScaleX = childW / rotatedW;
    double totalScale = baseScaleX * _scale;

    // Scale the image.
    CGAffineTransform scaleTransform = CGAffineTransformMakeScale(totalScale, totalScale);
    source = [source imageByApplyingTransform:scaleTransform];

    // Normalize extent origin (scale can shift it if the pre-scale origin was non-zero,
    // though after our earlier normalization steps it should be at (0,0)).
    {
        CGRect ext = source.extent;
        if (ext.origin.x != 0 || ext.origin.y != 0) {
            source = [source imageByApplyingTransform:
                CGAffineTransformMakeTranslation(-ext.origin.x, -ext.origin.y)];
        }
    }

    // ── Step 6: Pan / translate ────────────────────────────────────────────
    //
    // offsetX/offsetY are normalized displacement factors in [-1, 1].
    // They represent the fraction of maximum pan travel in each axis:
    //   maxDeltaX = max(0, (renderedW - canvasW) / 2)
    //   maxDeltaY = max(0, (renderedH - canvasH) / 2)
    //   translationX = offsetX * maxDeltaX
    //   translationY = offsetY * maxDeltaY
    //
    // Canvas centering offset:
    //   centerX = (canvasW - renderedW) / 2
    //   centerY = (canvasH - renderedH) / 2
    //
    // Final position:
    //   finalX = centerX + translationX
    //   finalY = centerY + translationY
    //
    // Y-axis inversion:
    //   Flutter (top-left): positive offsetY moves image DOWN (pan down = content moves up).
    //   CIImage (bottom-left): positive Y is UP. So to match Flutter, we negate offsetY.
    //   Without negation: a positive offsetY in Dart would pan the export UP visually
    //   while the preview showed it panning DOWN — a vertical flip in pan direction.
    double maxDeltaX = MAX(0.0, (renderedW - canvasW) / 2.0);
    double maxDeltaY = MAX(0.0, (renderedH - canvasH) / 2.0);

    double translationX = _offsetX * maxDeltaX;
    // Negate offsetY: Dart top-left Y+ (down) → CIImage bottom-left Y- (down).
    double translationY = -(_offsetY) * maxDeltaY;

    double centerX = (canvasW - renderedW) / 2.0;
    double centerY = (canvasH - renderedH) / 2.0;

    double finalX = centerX + translationX;
    double finalY = centerY + translationY;

    source = [source imageByApplyingTransform:
        CGAffineTransformMakeTranslation(finalX, finalY)];

    // ── Step 7: Composite over black background ────────────────────────────
    //
    // Create a solid black CIImage of canvasW × canvasH.
    // Use CISourceOverCompositing to blend: source_alpha * source + (1 - source_alpha) * black.
    // For opaque images (alpha=1) this is just the source. For images with any
    // transparent regions (e.g. from rotation with anti-aliasing) the transparent
    // area becomes black.
    CGRect canvasBounds = CGRectMake(0, 0, canvasW, canvasH);
    CIImage *blackBg = [CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1.0]];
    blackBg = [blackBg imageByCroppingToRect:canvasBounds];

    // CISourceOverCompositing: foreground over background.
    CIFilter *compositeFilter = [CIFilter filterWithName:@"CISourceOverCompositing"];
    [compositeFilter setValue:source  forKey:kCIInputImageKey];       // foreground
    [compositeFilter setValue:blackBg forKey:kCIInputBackgroundImageKey]; // background
    CIImage *composited = compositeFilter.outputImage;
    if (!composited) {
        NSLog(@"[VGTransformFilterNode] Compositing failed. Passthrough.");
        CVPixelBufferRetain(input);
        return input;
    }

    // Crop to exact canvas bounds (compositing may return unbounded image).
    composited = [composited imageByCroppingToRect:canvasBounds];

    // ── Step 8: Render into output CVPixelBuffer ───────────────────────────
    //
    // Allocate output buffer at canvasWidth × canvasHeight — NOT at input dimensions.
    // Use kCVPixelFormatType_32BGRA for Metal compatibility.
    CVPixelBufferRef output = NULL;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferMetalCompatibilityKey:           @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey:          @{},
        (id)kCVPixelBufferCGImageCompatibilityKey:         @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        (size_t)_canvasWidth,
        (size_t)_canvasHeight,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &output
    );
    if (status != kCVReturnSuccess || !output) {
        NSLog(@"[VGTransformFilterNode] CVPixelBufferCreate failed: %d. Passthrough.", status);
        CVPixelBufferRetain(input);
        return input;
    }

    // Render CIImage into the output CVPixelBuffer.
    // We use Device RGB color space consistent with the project's image export pipeline.
    CIContext *ctx = _VGTFNSharedCIContext();
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [ctx render:composited
 toCVPixelBuffer:output
          bounds:canvasBounds
      colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);

    // output is +1 from CVPixelBufferCreate. Caller owns and releases it.
    return output;
}

// ─── VanguardFilterNode — invalidate ─────────────────────────────────────────

- (void)invalidate {
    // No async work, no in-flight Metal commands to cancel.
    // CIContext is shared; we do not invalidate it.
}

// ─── VGMediaNode — prepareWithCompletion: (P3-2) ─────────────────────────────

- (void)prepareWithCompletion:(void (^)(NSError *_Nullable))completion {
    // nil pool is valid for one-shot still-image export.
    // All parameters are captured at init time — no async preparation needed.
    if (completion) completion(nil);
}

// ─── VGMetalFilterNode — processEnvelope:device: (P3-1 additive) ─────────────
//
// Wraps processBuffer:atTime:device: into the VGFrameEnvelope contract.
//
// Ownership contract (DEC-44 / RR-28):
//   - Passthrough: returns input envelope unchanged (no buffer ops).
//   - Active:      allocates new output buffer (+1 retain). Runtime releases it.
//   - Input buffer is NOT released here — runtime owns that retain.
//   - Failure (allocation/CI error): returns envelope with NULL videoBuffer.

- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                             device:(id<MTLDevice>)device {
    if (!_enabled) {
        return envelope; // passthrough — no buffer ops
    }

    CVPixelBufferRef input = (CVPixelBufferRef)envelope.payload.videoBuffer;
    if (!input) return envelope; // guard: nil payload → passthrough

    CVPixelBufferRef output = [self processBuffer:input
                                           atTime:envelope.pts
                                           device:device];

    // If processBuffer: returned the input unchanged (internal fallback),
    // release the extra +1 retain it added and treat as passthrough.
    if (output == input) {
        CVPixelBufferRelease(output);
        return envelope;
    }

    if (!output) {
        VGFrameEnvelope failed = envelope;
        failed.payload.videoBuffer = NULL;
        return failed;
    }

    VGFrameEnvelope out = envelope;   // copies all metadata fields (DEC-44)
    out.payload.videoBuffer = output; // runtime releases after downstream delivery
    return out;
}

@end
