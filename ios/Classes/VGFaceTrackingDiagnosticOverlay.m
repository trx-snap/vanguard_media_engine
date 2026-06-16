// VGFaceTrackingDiagnosticOverlay.m
// Phase 9B-Reset — Face Tracking Diagnostic Overlay
//
// GATE (two conditions BOTH required to draw anything):
//   1. DEBUG build — enforced at the call site in VanguardMetalRenderer.m via #if DEBUG.
//      In non-DEBUG builds, this file is never called; no overhead whatsoever.
//   2. Environment variable VG_FACE_TRACKING_DIAGNOSTIC = 1 (runtime).
//      Set in Xcode: Product → Scheme → Run → Arguments → Environment Variables.
//      When the flag is absent, +enabled returns NO and every method is a guaranteed no-op.
//
// This overlay proves Vision face-detection coordinates align with the live Flutter
// Texture preview (C = flip Y transform). It is DIAGNOSTIC ONLY:
//   - Does NOT feed or replace BeautyV2 mask logic.
//   - Does NOT modify the production mask buffer.
//   - Does NOT alter segmentation or mask generation.
//   - Does NOT affect frame delivery in any non-debug configuration.
//
// Confirmed transform (Phase 9B-Reset POC-A.5 physical smoke):
//   px = norm.x * W          (Vision left=0 → CG left=0)
//   py = norm.y * H          (net result of double-flip: Vision bottom=0 → CG top=0)
// Applies identically to bbox and all landmark arrays (post-6W: all image-normalized).
//
// Production mask sourcing (visual comparison only):
//   Primary:  envelope.metadata[VGSegmentationMetadataKeySkinMaskBuffer] → CVPixelBufferRef R8
//   Fallback: envelope.metadata[VGSegmentationMetadataKeySkinMask] → VGSkinMask* raw bytes
//   The buffer/bytes are locked ReadOnly and immediately unlocked. Never retained or modified.

#import "VGFaceTrackingDiagnosticOverlay.h"
#import "VGFaceDetectionProvider.h"
#import "VGSegmentationNode.h"   // VGSegmentationMetadataKey* constants (read-only)
#import "VGSkinMaskGenerator.h"  // VGSkinMask interface (read-only)
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <os/log.h>

// ── Environment variable gate ─────────────────────────────────────────────────
// Checked once at first call to +enabled and cached. Reading NSProcessInfo is
// cheap but we cache for the common case where the flag is absent.
static NSString * const kVGDiagEnvKey = @"VG_FACE_TRACKING_DIAGNOSTIC";

// ── os_log ─────────────────────────────────────────────────────────────────────
static os_log_t VGOverlayLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.vanguard.diagnostic", "FaceOverlay");
    });
    return log;
}

// ── Transform C/flipY macros ──────────────────────────────────────────────────
// Confirmed by physical smoke (Phase 9B-Reset POC-A.5).
// Applies identically to bbox and all landmark arrays (both image-normalized post-6W).
#define CFLIP_PX(normX, W)  ((normX) * (W))
#define CFLIP_PY(normY, H)  ((normY) * (H))

// Minimum contour points required to fill a closed polygon.
static const NSUInteger kVGMinContourPointsForFill = 3;

// ── Primitives ─────────────────────────────────────────────────────────────────

static void VGOverlayDot(CGContextRef ctx, CGFloat cx, CGFloat cy,
                         CGFloat r, CGColorRef c) {
    CGContextSetFillColorWithColor(ctx, c);
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - r, cy - r, r * 2, r * 2));
}

static void VGOverlayText(CGContextRef ctx, NSString *text,
                          CGFloat x, CGFloat y, UIColor *color) {
    NSDictionary<NSAttributedStringKey, id> *attrs = @{
        NSFontAttributeName:            [UIFont monospacedSystemFontOfSize:36
                                                                    weight:UIFontWeightBold],
        NSForegroundColorAttributeName: color,
        NSBackgroundColorAttributeName: [UIColor colorWithWhite:0 alpha:0.70],
    };
    UIGraphicsPushContext(ctx);
    [text drawAtPoint:CGPointMake(x, y) withAttributes:attrs];
    UIGraphicsPopContext();
}

static void VGDrawLandmarkGroup(CGContextRef ctx,
                                NSArray<NSValue *> *points,
                                CGFloat W, CGFloat H,
                                CGFloat dotRadius,
                                CGColorRef color) {
    if (!points) return;
    for (NSValue *v in points) {
        CGPoint p = v.CGPointValue;
        VGOverlayDot(ctx,
                     (CGFloat)CFLIP_PX(p.x, W),
                     (CGFloat)CFLIP_PY(p.y, H),
                     dotRadius, color);
    }
}

// ── Implementation ────────────────────────────────────────────────────────────

@implementation VGFaceTrackingDiagnosticOverlay {
    VGFaceDetectionProvider *_detectionProvider;
    BOOL _badFormatLogged;
    BOOL _methodRunLogged;
    int  _frameCount;
}

// ── Gate ──────────────────────────────────────────────────────────────────────

+ (BOOL)enabled {
#if DEBUG
    // Cache the environment-variable lookup after the first call.
    static BOOL sCachedEnabled;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{
        NSString *val = NSProcessInfo.processInfo.environment[kVGDiagEnvKey];
        sCachedEnabled = [val isEqualToString:@"1"];
        if (sCachedEnabled) {
            NSLog(@"[VGFaceTrackingOverlay] ENABLED via %@=1 "
                  "(Phase 9B-Reset diagnostic — disable before production builds)",
                  kVGDiagEnvKey);
        }
        // No log when disabled — avoid noise on every app launch.
    });
    return sCachedEnabled;
#else
    // Non-DEBUG: guaranteed NO. The call site in VanguardMetalRenderer.m is
    // additionally wrapped in #if DEBUG so this path is never reached in Release.
    return NO;
#endif
}

+ (VGFaceTrackingDiagnosticOverlay *)shared {
    static VGFaceTrackingDiagnosticOverlay *sShared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sShared = [[VGFaceTrackingDiagnosticOverlay alloc] _init];
    });
    return sShared;
}

- (instancetype)_init {
    self = [super init];
    if (!self) return nil;
    // VGFaceDetectionProvider is allocated once; cadence 1 = every frame.
    _detectionProvider = [[VGFaceDetectionProvider alloc] initWithCadenceFrames:1];
    return self;
}

- (void)dealloc {
    [_detectionProvider invalidate];
}

// ── Main entry point ──────────────────────────────────────────────────────────

- (void)drawOverlayOn:(CVPixelBufferRef)pixelBuffer
                  pts:(CMTime)pts
             metadata:(nullable NSDictionary *)metadata {
    // Guard: callers in VanguardMetalRenderer.m already check +enabled, but this
    // is a cheap double-check in case the overlay is called from any other path.
    if (![VGFaceTrackingDiagnosticOverlay enabled]) return;

    _frameCount++;

    if (!_methodRunLogged) {
        _methodRunLogged = YES;
        NSLog(@"[VGFaceTrackingOverlay] Phase 9B-Reset diagnostic ACTIVE — "
              "fmt=%u w=%zu h=%zu bpr=%zu  "
              "(disable by removing %@=1 or switching to non-DEBUG build)",
              (unsigned)CVPixelBufferGetPixelFormatType(pixelBuffer),
              CVPixelBufferGetWidth(pixelBuffer),
              CVPixelBufferGetHeight(pixelBuffer),
              CVPixelBufferGetBytesPerRow(pixelBuffer),
              kVGDiagEnvKey);
    }

    OSType fmt = CVPixelBufferGetPixelFormatType(pixelBuffer);
    if (fmt != kCVPixelFormatType_32BGRA) {
        if (!_badFormatLogged) {
            _badFormatLogged = YES;
            NSLog(@"[VGFaceTrackingOverlay] Unsupported pixel format %u "
                  "(w=%zu h=%zu bpr=%zu) — overlay skipped for this frame",
                  (unsigned)fmt,
                  CVPixelBufferGetWidth(pixelBuffer),
                  CVPixelBufferGetHeight(pixelBuffer),
                  CVPixelBufferGetBytesPerRow(pixelBuffer));
        }
        return;
    }

    CGContextRef ctx = [self _lockAndMakeContext:pixelBuffer];
    if (!ctx) {
        NSLog(@"[VGFaceTrackingOverlay] CGBitmapContextCreate failed — "
              "fmt=%u w=%zu h=%zu bpr=%zu",
              (unsigned)fmt,
              CVPixelBufferGetWidth(pixelBuffer),
              CVPixelBufferGetHeight(pixelBuffer),
              CVPixelBufferGetBytesPerRow(pixelBuffer));
        return;
    }

    CGFloat W = (CGFloat)CVPixelBufferGetWidth(pixelBuffer);
    CGFloat H = (CGFloat)CVPixelBufferGetHeight(pixelBuffer);

    // ── Layer 1: Static red canary — confirms the overlay path is live ────────
    CGColorRef red = [UIColor colorWithRed:1 green:0 blue:0 alpha:1].CGColor;
    CGContextSetStrokeColorWithColor(ctx, red);
    CGContextSetLineWidth(ctx, 14);
    CGContextStrokeRect(ctx, CGRectMake(7, 7, W - 14, H - 14));
    CGContextSetLineWidth(ctx, 8);
    CGContextMoveToPoint(ctx, 0, H * 0.5);
    CGContextAddLineToPoint(ctx, W, H * 0.5);
    CGContextStrokePath(ctx);
    CGContextMoveToPoint(ctx, W * 0.5, 0);
    CGContextAddLineToPoint(ctx, W * 0.5, H);
    CGContextStrokePath(ctx);
    VGOverlayText(ctx, @"9B DIAG: truth+mask", 30, 50, [UIColor redColor]);

    // ── Layer 2: Run Vision face detection ────────────────────────────────────
    [_detectionProvider detectInPixelBuffer:pixelBuffer pts:pts];
    VGFaceDetectionResult *result = _detectionProvider.latestResult;
    NSArray<VGDetectedFace *> *faces = result.faces;

    // ── Layer 3: Production mask visual comparison (drawn before ground truth) ─
    // The mask is drawn underneath so ground-truth geometry remains legible on top.
    // Source: envelope.metadata passed from VanguardMetalRenderer.presentEnvelope:.
    // Read-only: never retained, never modified, never fed to BeautyV2.
    BOOL maskDrawn = NO;
    NSString *maskSource = @"none";
    size_t maskW = 0, maskH = 0;

    if (metadata) {
        // Primary: CVPixelBufferRef R8 (quarter-res, set by VGSegmentationNode post-DEC-121).
        id maskBufObj = metadata[VGSegmentationMetadataKeySkinMaskBuffer];
        CVPixelBufferRef maskBuf = maskBufObj
            ? (__bridge CVPixelBufferRef)maskBufObj  // non-owning; NSDictionary owns it
            : NULL;

        if (maskBuf) {
            CVReturn lockErr = CVPixelBufferLockBaseAddress(maskBuf,
                                                           kCVPixelBufferLock_ReadOnly);
            if (lockErr == kCVReturnSuccess) {
                const uint8_t *bytes = CVPixelBufferGetBaseAddress(maskBuf);
                maskW   = CVPixelBufferGetWidth(maskBuf);
                maskH   = CVPixelBufferGetHeight(maskBuf);
                size_t bpr = CVPixelBufferGetBytesPerRow(maskBuf);
                if (bytes && maskW > 0 && maskH > 0) {
                    maskDrawn = [self _drawMaskFromBytes:bytes
                                                  width:maskW
                                                 height:maskH
                                            bytesPerRow:bpr
                                              onContext:ctx
                                                bufferW:W
                                                bufferH:H];
                    maskSource = @"CVPixelBufferRef(R8)";
                }
                CVPixelBufferUnlockBaseAddress(maskBuf, kCVPixelBufferLock_ReadOnly);
                // No CFRelease — non-owning __bridge cast; NSDictionary owns the buffer.
            }
        } else {
            // Fallback: VGSkinMask* legacy bridge (DEC-110).
            VGSkinMask *skinMask = metadata[VGSegmentationMetadataKeySkinMask];
            if (skinMask && skinMask.data && skinMask.width > 0 && skinMask.height > 0) {
                maskDrawn = [self _drawMaskFromBytes:skinMask.data
                                              width:skinMask.width
                                             height:skinMask.height
                                        bytesPerRow:skinMask.bytesPerRow
                                          onContext:ctx
                                            bufferW:W
                                            bufferH:H];
                maskSource = @"VGSkinMask(legacy)";
                maskW = skinMask.width;
                maskH = skinMask.height;
            }
        }
    }

    // Mask status label at bottom of frame.
    if (maskDrawn) {
        VGOverlayText(ctx, @"PRODUCTION MASK: visual compare only",
                      30, H - 120,
                      [UIColor colorWithRed:0.7 green:0.4 blue:1.0 alpha:1.0]);
    } else {
        VGOverlayText(ctx, @"PRODUCTION MASK: unavailable",
                      30, H - 120, [UIColor yellowColor]);
    }

    // ── Layer 4: Ground-truth face overlay ────────────────────────────────────
    if (faces.count == 0) {
        VGOverlayText(ctx, @"NO FACE", 30, 130, [UIColor yellowColor]);
        CGContextRelease(ctx);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        return;
    }

    VGDetectedFace *face = faces.firstObject;
    CGRect bb = face.boundingBox;

    // Confirmed C/flipY bbox.
    double bboxPxX = CFLIP_PX(bb.origin.x, W);
    double bboxPxY = CFLIP_PY(bb.origin.y, H);
    double bboxPxW = bb.size.width  * (double)W;
    double bboxPxH = bb.size.height * (double)H;
    CGRect bboxRect = CGRectMake(bboxPxX, bboxPxY, bboxPxW, bboxPxH);

    CGColorRef cyan = [UIColor colorWithRed:0 green:1 blue:1 alpha:1].CGColor;
    CGContextSetStrokeColorWithColor(ctx, cyan);
    CGContextSetLineWidth(ctx, 8);
    CGContextStrokeRect(ctx, bboxRect);

    double cx = CFLIP_PX(bb.origin.x + bb.size.width  * 0.5, W);
    double cy = CFLIP_PY(bb.origin.y + bb.size.height * 0.5, H);
    VGOverlayDot(ctx, (CGFloat)cx, (CGFloat)cy, 14, cyan);

    VGOverlayText(ctx, @"GROUND TRUTH: C flipY",
                  (CGFloat)(bboxRect.origin.x + 10),
                  (CGFloat)(bboxRect.origin.y + 10),
                  [UIColor cyanColor]);

    NSString *conf = [NSString stringWithFormat:@"conf:%.2f  faces:%d",
                      face.confidence, (int)faces.count];
    VGOverlayText(ctx, conf, 30, 130, [UIColor whiteColor]);

    // Raw Vision face-contour polygon (orange fill + yellow outline).
    NSArray<NSValue *> *contourPts = face.faceContourPoints;
    NSUInteger nContour = contourPts.count;

    if (nContour >= kVGMinContourPointsForFill) {
        CGMutablePathRef facePath = CGPathCreateMutable();
        CGPoint first = contourPts.firstObject.CGPointValue;
        CGPathMoveToPoint(facePath, NULL,
                          (CGFloat)CFLIP_PX(first.x, W),
                          (CGFloat)CFLIP_PY(first.y, H));
        for (NSUInteger i = 1; i < nContour; i++) {
            CGPoint p = [contourPts[i] CGPointValue];
            CGPathAddLineToPoint(facePath, NULL,
                                 (CGFloat)CFLIP_PX(p.x, W),
                                 (CGFloat)CFLIP_PY(p.y, H));
        }
        CGPathCloseSubpath(facePath);

        CGContextAddPath(ctx, facePath);
        CGContextSetFillColorWithColor(ctx,
            [UIColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:0.25].CGColor);
        CGContextFillPath(ctx);

        CGContextAddPath(ctx, facePath);
        CGContextSetStrokeColorWithColor(ctx,
            [UIColor colorWithRed:1.0 green:0.9 blue:0.0 alpha:0.9].CGColor);
        CGContextSetLineWidth(ctx, 4);
        CGContextStrokePath(ctx);
        CGPathRelease(facePath);
    }

    // Landmark dots — drawn on top of contour fill so they remain legible.
    CGColorRef lmContour = [UIColor colorWithRed:0.2 green:1.0 blue:0.2 alpha:0.9].CGColor;
    VGDrawLandmarkGroup(ctx, face.faceContourPoints, W, H, 5, lmContour);

    CGColorRef lmEye = [UIColor colorWithRed:1.0 green:1.0 blue:0.0 alpha:1.0].CGColor;
    VGDrawLandmarkGroup(ctx, face.leftEyePoints,  W, H, 5, lmEye);
    VGDrawLandmarkGroup(ctx, face.rightEyePoints, W, H, 5, lmEye);

    CGColorRef lmBrow = [UIColor colorWithRed:1.0 green:0.5 blue:0.0 alpha:1.0].CGColor;
    VGDrawLandmarkGroup(ctx, face.leftEyebrowPoints,  W, H, 4, lmBrow);
    VGDrawLandmarkGroup(ctx, face.rightEyebrowPoints, W, H, 4, lmBrow);

    CGColorRef lmLips = [UIColor colorWithRed:1.0 green:0.0 blue:1.0 alpha:1.0].CGColor;
    VGDrawLandmarkGroup(ctx, face.outerLipsPoints, W, H, 5, lmLips);

    CGColorRef lmNose = [UIColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:0.9].CGColor;
    VGDrawLandmarkGroup(ctx, face.nosePoints, W, H, 4, lmNose);

    // ── Layer 5: Throttled os_log — active only when diagnostic is enabled ────
    if (_frameCount <= 2 || (_frameCount % 30) == 0) {
        os_log_info(VGOverlayLog(),
                    "9B-Diag | buf %d×%d | "
                    "bbox px x=%.1f y=%.1f w=%.1f h=%.1f | "
                    "contourPts=%zu | "
                    "mask found=%d src=%{public}s maskSize=%zu×%zu",
                    (int)W, (int)H,
                    bboxRect.origin.x, bboxRect.origin.y,
                    bboxRect.size.width, bboxRect.size.height,
                    nContour,
                    (int)maskDrawn, maskSource.UTF8String,
                    maskW, maskH);
    }

    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

// ── Production mask rendering (display-only) ──────────────────────────────────
// Renders a semi-transparent purple tint from raw R8 mask bytes.
// Display-only transforms applied here (not to the mask buffer):
//   • Scale from quarter-res to full buffer dimensions.
//   • Y-axis flip to match confirmed C/flipY coordinate basis.
// The mask bytes are accessed read-only; the source buffer is unmodified.

- (BOOL)_drawMaskFromBytes:(const uint8_t *)bytes
                     width:(size_t)mW
                    height:(size_t)mH
               bytesPerRow:(size_t)bpr
                 onContext:(CGContextRef)ctx
                   bufferW:(CGFloat)W
                   bufferH:(CGFloat)H {
    if (!bytes || mW == 0 || mH == 0) return NO;

    // Build a grayscale CGImage from the R8 bytes without copying.
    // CGDataProvider does not own the bytes; the caller (lock/unlock pair) keeps them valid.
    CGColorSpaceRef grayCS = CGColorSpaceCreateDeviceGray();
    CGDataProviderRef dp = CGDataProviderCreateWithData(
        NULL, bytes, bpr * mH, NULL /* no release: bytes owned by mask object/buffer */);
    if (!dp) { CGColorSpaceRelease(grayCS); return NO; }

    CGImageRef maskImg = CGImageCreate(
        mW, mH, 8, 8, bpr,
        grayCS, kCGImageAlphaNone | kCGBitmapByteOrderDefault,
        dp, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(grayCS);
    if (!maskImg) return NO;

    // Apply display-only transform: scale to full buffer + C/flipY Y-flip.
    // Context state is saved/restored so subsequent layers are unaffected.
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 0, H);
    CGContextScaleCTM(ctx, 1.0, -1.0);

    // Clip to mask luminance, then fill with purple. Non-skin pixels (value≈0) are
    // transparent; skin pixels (value≈255) are fully clipped → purple drawn.
    CGContextClipToMask(ctx, CGRectMake(0, 0, W, H), maskImg);
    CGContextSetFillColorWithColor(ctx,
        [UIColor colorWithRed:0.6 green:0.2 blue:1.0 alpha:0.50].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, W, H));

    CGContextRestoreGState(ctx);
    CGImageRelease(maskImg);
    return YES;
}

// ── Context (locks pixel buffer; caller must release ctx + unlock) ────────────

- (CGContextRef _Nullable)_lockAndMakeContext:(CVPixelBufferRef)pixelBuffer {
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    if (!base) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        return NULL;
    }
    size_t w   = CVPixelBufferGetWidth(pixelBuffer);
    size_t h   = CVPixelBufferGetHeight(pixelBuffer);
    size_t bpr = CVPixelBufferGetBytesPerRow(pixelBuffer);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bi = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs, bi);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    }
    return ctx;
}

@end
