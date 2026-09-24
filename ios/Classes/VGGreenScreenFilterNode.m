// VGGreenScreenFilterNode.m
// vanguard_media_engine — UMF camera graph green screen (iOS-first MVP)
//
// Implementation of VGGreenScreenFilterNode. Constructed by
// VGCameraGraphSession.setCameraFilterChainFromSpecs: (spec type "greenScreen");
// the node never learns what produces its input or consumes its output.

#import "VGGreenScreenFilterNode.h"

#import <UMF/VGMediaNode.h>       // VGNodeRole / VGNodeRoleFilter
#import <UMF/VGFrameEnvelope.h>   // VGFrameEnvelope (processEnvelope:device:)
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>   // CMTime / CMTimeGetSeconds (frame log)
#import <CoreImage/CoreImage.h>   // S1 matte refinement + CIBlendWithMask composite
#import <Metal/Metal.h>
#import <Vision/Vision.h>         // person matte (iOS 15+)
#import <ImageIO/ImageIO.h>       // still-image background decode (VGGreenScreenBackgroundProvider)
#import <CoreGraphics/CoreGraphics.h>
#import <os/lock.h>               // telemetry lock (os_unfair_lock)
#import <math.h>                  // isfinite (transform clamping)
#import <stdatomic.h>

// Swift bridge: VGMatteRefinementPipeline + VGMatteRefinementLiveResult
// (VGMatteRefinementPipeline.swift) own live matte refinement. The
// framework build exports them through the generated Swift header; the quoted
// fallback covers a static-library integration, where the generated header is
// not copied into a framework Headers directory.
#if __has_include(<vanguard_media_engine/vanguard_media_engine-Swift.h>)
#import <vanguard_media_engine/vanguard_media_engine-Swift.h>
#else
#import "vanguard_media_engine-Swift.h"
#endif

// ─── VGGreenScreenFilterNode (UMF camera graph green screen, iOS-first MVP) ──
//
// Contract, scope and explicit non-claims are documented in
// VGGreenScreenFilterNode.h.
//
// Processing contract (processBuffer:atTime:device:):
//   1. enabled=NO or invalidated → CVPixelBufferRetain(input); return input.
//   2. Matte source unavailable (iOS < 15), NULL pool, or zero-dimension input
//      → passthrough (fail open), logged.
//   3. Synchronous Vision person segmentation (FAST) on the input exactly as
//      received (no orientation passed: the camera source already oriented and
//      mirrored the frame). Error / no observation / wrong format → passthrough.
//   4. CIImage wrap of the input (foreground) and the OneComponent8 matte; the
//      matte is scaled (non-uniform) to the frame extent.
//   5. Live matte refinement over the scaled matte through the node-owned
//      VGMatteRefinementPipeline (Swift; the single production implementation
//      shared with every other live green-screen caller). The node owns one
//      VGMatteRefinementPipeline created with Objective-C init, tracking
//      VGMatteRefinementPipeline.defaultLiveMatteRefinementMode (current
//      production default is .s4SoftAlphaR2). Explicit S1 fallback still exists
//      elsewhere, but this Objective-C node does not select modes directly.
//      Each stage fails open to its input mask inside the pipeline and reports
//      an applied flag; a nil bridge result (never expected) fails the frame
//      open with reason matte_refinement_failed.
//   5b. Subject transform (canonical flat scale/offsetX/offsetY): when not the
//      identity, the SAME affine transform is applied to the foreground and
//      to the refined matte (refinement always runs at source scale first, so
//      matte quality is unchanged by the transform). Read per frame under the
//      node's state lock together with the current background provider.
//   6. Output stage, selected by the current outputMode:
//        solidColor — CIBlendWithMask: inputImage = foreground,
//                     inputBackgroundImage = solid colour, inputMaskImage =
//                     refined matte (255 = subject → foreground). Unchanged
//                     from the MVP; pixel output is identical.
//        imageFile  — identical blend with inputBackgroundImage = the
//                     provider's canvas-sized still image (rendered once per
//                     canvas size; see VGGreenScreenBackgroundProvider).
//        alpha      — straight-alpha construction
//                     (_VGGSFNStraightAlphaKeyedImage): CIColorMatrix zeroes
//                     the foreground's alpha, then CIBlendWithMask mixes the
//                     opaque foreground over that copy with the refined matte
//                     → (fg.rgb, m). No background is composited. Rendered
//                     through the dedicated un-premultiplied context
//                     (_VGGSFNRenderStraightAlpha); the alpha encoding note
//                     on the helper explains why.
//   7. Pool buffer allocation; its dimensions must equal the frame's, else
//      passthrough (logged once).
//   8. Render with a NULL colour space into the pool buffer; return it (+1).
//      solidColor renders through the shared context; alpha renders through
//      _VGGSFNRenderStraightAlpha (kCIContextOutputPremultiplied = NO) and
//      fails open if that context is unavailable.
//
// Logging markers (grep in device logs):
//   IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_NODE_CREATED
//   IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_HOT_UPDATE           (every accepted in-place update)
//   IOS_CAMERA_GRAPH_GREENSCREEN_BACKGROUND_DECODED          (imageFile provider, once per decode)
//   IOS_CAMERA_GRAPH_GREENSCREEN_BACKGROUND_CANVAS_RENDERED  (once per canvas size per provider)
//   IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_ALPHA_BYTE_SELF_TEST (alpha mode only, once at init)
//   IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_PROOF_UNAVAILABLE   (iOS < 15 only, once)
//   IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_FRAME               (frames 1-3, then every 60th)
//   IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_FAIL_OPEN           (events 1-3, then every 60th)
//
// Native telemetry (no log dependency): -diagnosticsSnapshot (contract in the
// header). Per-frame counters are plain scalars written under _telemetryLock
// at the end of a successful keyed render (step 7 below) and on fail-open;
// nothing is allocated for telemetry on the frame path. The alpha byte
// self-test fields (alphaByteSelfTest*) are written once in init and are
// immutable afterwards, so the snapshot reads them without the lock.

NSString * const VGGreenScreenFilterNodeBackgroundTypeSolidColor = @"solidColor";
NSString * const VGGreenScreenFilterNodeBackgroundTypeAlpha      = @"alpha";
NSString * const VGGreenScreenFilterNodeBackgroundTypeImageFile  = @"imageFile";

// VGGreenScreenBackgroundProvider.h constants (implementation inlined below).
NSString * const VGGreenScreenBackgroundTypeImageFile            = @"imageFile";
NSString * const VGGreenScreenBackgroundScaleModeAspectFillName  = @"aspectFill";
NSString * const VGGreenScreenBackgroundScaleModeAspectFitName   = @"aspectFit";
const NSUInteger VGGreenScreenBackgroundImageMaxPixelSize        = 2160;

// Canonical flat foreground transform contract.
const float VGGreenScreenForegroundScaleMin  = 0.25f;
const float VGGreenScreenForegroundScaleMax  = 3.0f;
const float VGGreenScreenForegroundOffsetMin = -1.0f;
const float VGGreenScreenForegroundOffsetMax = 1.0f;
const VGGreenScreenForegroundTransform VGGreenScreenForegroundTransformIdentity = {1.0f, 0.0f, 0.0f};

static float _VGGSFNClampComponent(double value, float identity, float lo, float hi) {
    if (!isfinite(value)) return identity;
    if (value < lo) return lo;
    if (value > hi) return hi;
    return (float)value;
}

VGGreenScreenForegroundTransform
VGGreenScreenForegroundTransformMakeClamped(double scale, double offsetX, double offsetY) {
    VGGreenScreenForegroundTransform t;
    t.scale   = _VGGSFNClampComponent(scale,   1.0f, VGGreenScreenForegroundScaleMin,  VGGreenScreenForegroundScaleMax);
    t.offsetX = _VGGSFNClampComponent(offsetX, 0.0f, VGGreenScreenForegroundOffsetMin, VGGreenScreenForegroundOffsetMax);
    t.offsetY = _VGGSFNClampComponent(offsetY, 0.0f, VGGreenScreenForegroundOffsetMin, VGGreenScreenForegroundOffsetMax);
    return t;
}

BOOL VGGreenScreenForegroundTransformIsIdentity(VGGreenScreenForegroundTransform t) {
    return t.scale == 1.0f && t.offsetX == 0.0f && t.offsetY == 0.0f;
}

BOOL VGGreenScreenBackgroundScaleModeFromSpecValue(id _Nullable value,
                                                   VGGreenScreenBackgroundScaleMode * _Nonnull outMode) {
    if (value == nil || value == [NSNull null]) {
        *outMode = VGGreenScreenBackgroundScaleModeAspectFill;   // contract default
        return YES;
    }
    if (![value isKindOfClass:[NSString class]]) return NO;
    if ([value isEqualToString:VGGreenScreenBackgroundScaleModeAspectFillName]) {
        *outMode = VGGreenScreenBackgroundScaleModeAspectFill;
        return YES;
    }
    if ([value isEqualToString:VGGreenScreenBackgroundScaleModeAspectFitName]) {
        *outMode = VGGreenScreenBackgroundScaleModeAspectFit;
        return YES;
    }
    return NO;
}

NSString *VGGreenScreenBackgroundScaleModeName(VGGreenScreenBackgroundScaleMode mode) {
    return (mode == VGGreenScreenBackgroundScaleModeAspectFit)
        ? VGGreenScreenBackgroundScaleModeAspectFitName
        : VGGreenScreenBackgroundScaleModeAspectFillName;
}

static const uint64_t kVGGreenScreenFilterLogInterval = 60;

// Output mode → the spec backgroundType string it was built from. Used for
// logs and -diagnosticsSnapshot (outputMode / backgroundType share the value).
static NSString *_VGGSFNOutputModeName(VGGreenScreenFilterNodeOutputMode mode) {
    switch (mode) {
        case VGGreenScreenFilterNodeOutputModeAlpha:     return VGGreenScreenFilterNodeBackgroundTypeAlpha;
        case VGGreenScreenFilterNodeOutputModeImageFile: return VGGreenScreenFilterNodeBackgroundTypeImageFile;
        default:                                         return VGGreenScreenFilterNodeBackgroundTypeSolidColor;
    }
}

// Subject transform (see the header): the full frame scaled by `scale` about
// the canvas centre, its centre moved to (cx + offsetX·cx, cy + offsetY·cy) in
// top-left canvas space. Expressed in Core Image's bottom-left space, so
// offsetY > 0 (down) becomes a NEGATIVE y translation.
static CGAffineTransform _VGGSFNSubjectTransform(VGGreenScreenForegroundTransform t, CGRect canvas) {
    const CGFloat W  = canvas.size.width;
    const CGFloat H  = canvas.size.height;
    const CGFloat s  = (CGFloat)t.scale;
    const CGFloat tx = (W - s * W) * 0.5 + (CGFloat)t.offsetX * W * 0.5;
    const CGFloat ty = (H - s * H) * 0.5 - (CGFloat)t.offsetY * H * 0.5;
    return CGAffineTransformMake(s, 0.0, 0.0, s, tx, ty);
}

// Alpha encoding reported by logs and -diagnosticsSnapshot. "straight" is
// claimed ONLY when the one-time byte self-test passed through the alpha
// render path (_VGGSFNRenderStraightAlpha); any alpha-mode self-test failure
// reports "unverified" so no consumer can mistake the bytes for straight.
static NSString *_VGGSFNAlphaEncodingName(VGGreenScreenFilterNodeOutputMode mode, BOOL selfTestPassed) {
    if (mode != VGGreenScreenFilterNodeOutputModeAlpha) return @"opaque";
    return selfTestPassed ? @"straight" : @"unverified";
}

// Shared CIContext with NO working colour space (raw bytes in, raw bytes out):
// the same options as the proven live green-screen renderers in this package
// (VGDuetPreviewCompositor, VGARKitLiveGreenScreenPreviewCoordinator). The
// device passed on first use backs the context for the process lifetime.
static CIContext *_VGGSFNSharedCIContext(id<MTLDevice> device) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *opts = @{
            kCIContextWorkingColorSpace:  [NSNull null],
            kCIContextCacheIntermediates: @NO,
        };
        ctx = device ? [CIContext contextWithMTLDevice:device options:opts]
                     : [CIContext contextWithOptions:opts];
    });
    return ctx;
}

// Alpha-mode CIContext: the shared context's options PLUS
// kCIContextOutputPremultiplied = NO, so the final render un-premultiplies the
// (premultiplied) working values and writes STRAIGHT alpha bytes into the
// 32BGRA buffer. Used ONLY by the alpha output mode; solidColor keeps the
// shared context. Created once for the process lifetime; nil if Core Image
// refuses the options (then alpha mode fails open — see below).
static CIContext * _Nullable _VGGSFNStraightAlphaCIContext(id<MTLDevice> device) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *opts = @{
            kCIContextWorkingColorSpace:   [NSNull null],
            kCIContextCacheIntermediates:  @NO,
            kCIContextOutputPremultiplied: @NO,
        };
        ctx = device ? [CIContext contextWithMTLDevice:device options:opts]
                     : [CIContext contextWithOptions:opts];
    });
    return ctx;
}

// THE render call for alpha-mode output. Shared by the live alpha frame path
// and the alpha byte self-test so the self-test measures exactly what live
// frames write. Synchronous; NULL output colour space (raw bytes, like the
// shared context). Returns NO — nothing rendered, `output` untouched — when
// the straight-alpha context is unavailable; callers must then fail open
// rather than fall back to the premultiplied shared context.
static BOOL _VGGSFNRenderStraightAlpha(id<MTLDevice> device, CIImage *keyed,
                                       CVPixelBufferRef output, CGRect bounds) {
    CIContext *ctx = _VGGSFNStraightAlphaCIContext(device);
    if (!ctx || !keyed || !output) return NO;
    [ctx render:keyed toCVPixelBuffer:output bounds:bounds colorSpace:NULL];
    return YES;
}

// ─── VGGreenScreenBackgroundProvider (inlined; see VGGreenScreenBackgroundProvider.h) ──
//
// Static background source of the composite modes. Immutable after
// construction (kind / colour / path / scale mode / decoded CGImage); the
// only mutable state is the single-entry canvas cache below, guarded by
// _cacheLock. The one-time canvas render goes through the node's shared
// no-colour-space CIContext into an IOSurface-backed 32BGRA buffer, so the
// per-frame composite samples one texture and never re-decodes or re-places
// the image. Beauty runs on the subject upstream and never touches this
// background, which therefore stays crisp.

static CVPixelBufferRef _Nullable _VGGSFNCreateCanvasBuffer(size_t width, size_t height) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey:  @YES,
    };
    CVPixelBufferRef buffer = NULL;
    const CVReturn rv = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                            (__bridge CFDictionaryRef)attrs, &buffer);
    if (rv != kCVReturnSuccess || !buffer) return NULL;
    return buffer;
}

static NSError *_VGGSFNInvalidBackgroundError(NSString *message) {
    return [NSError errorWithDomain:@"INVALID_GREEN_SCREEN_FILTER_SPEC"
                               code:4
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation VGGreenScreenBackgroundProvider {
    VGGreenScreenBackgroundKind      _kind;
    uint32_t                         _argb;
    NSString                        *_imagePath;
    VGGreenScreenBackgroundScaleMode _scaleMode;
    CGImageRef                       _image;          // +1 owned (imageFile); NULL for solidColor
    size_t                           _imageWidth;
    size_t                           _imageHeight;

    os_unfair_lock                   _cacheLock;
    CVPixelBufferRef                 _cachedCanvas;   // +1 owned; imageFile only
    CIImage                         *_cachedCanvasImage;
    size_t                           _cachedWidth;
    size_t                           _cachedHeight;
}

@synthesize kind        = _kind;
@synthesize argb        = _argb;
@synthesize imagePath   = _imagePath;
@synthesize scaleMode   = _scaleMode;
@synthesize imageWidth  = _imageWidth;
@synthesize imageHeight = _imageHeight;

- (instancetype)_initWithKind:(VGGreenScreenBackgroundKind)kind
                         argb:(uint32_t)argb
                    imagePath:(nullable NSString *)imagePath
                    scaleMode:(VGGreenScreenBackgroundScaleMode)scaleMode
                        image:(nullable CGImageRef)image {
    self = [super init];
    if (!self) return nil;
    _kind       = kind;
    _argb       = argb;
    _imagePath  = [imagePath copy];
    _scaleMode  = scaleMode;
    _image      = image ? CGImageRetain(image) : NULL;
    _imageWidth  = image ? CGImageGetWidth(image)  : 0;
    _imageHeight = image ? CGImageGetHeight(image) : 0;
    _cacheLock  = OS_UNFAIR_LOCK_INIT;
    return self;
}

- (void)dealloc {
    if (_image) {
        CGImageRelease(_image);
        _image = NULL;
    }
    if (_cachedCanvas) {
        CVPixelBufferRelease(_cachedCanvas);
        _cachedCanvas = NULL;
    }
}

+ (instancetype)solidColorProviderWithARGB:(uint32_t)argb {
    return [[self alloc] _initWithKind:VGGreenScreenBackgroundKindSolidColor
                                  argb:argb
                             imagePath:nil
                             scaleMode:VGGreenScreenBackgroundScaleModeAspectFill
                                 image:NULL];
}

+ (nullable instancetype)imageFileProviderWithPath:(NSString *)imagePath
                                         scaleMode:(VGGreenScreenBackgroundScaleMode)scaleMode
                                             error:(NSError * _Nullable * _Nullable)outError {
    if (![imagePath isKindOfClass:[NSString class]] || imagePath.length == 0) {
        if (outError) *outError = _VGGSFNInvalidBackgroundError(
            @"greenScreen imageFile requires parameters.imagePath (non-empty absolute path).");
        return nil;
    }
    if (![imagePath hasPrefix:@"/"]) {
        if (outError) *outError = _VGGSFNInvalidBackgroundError(
            [NSString stringWithFormat:@"greenScreen imagePath must be an absolute local path (got '%@').", imagePath]);
        return nil;
    }
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:imagePath isDirectory:&isDirectory] || isDirectory) {
        if (outError) *outError = _VGGSFNInvalidBackgroundError(
            [NSString stringWithFormat:@"greenScreen imagePath does not exist or is not a file: '%@'.", imagePath]);
        return nil;
    }

    // Bounded decode through ImageIO. EXIF orientation IS applied (parity
    // with VGLiveGreenScreenStaticBackgroundRenderer / the export renderer,
    // so one path renders identically, in visual orientation, on every surface).
    NSURL *url = [NSURL fileURLWithPath:imagePath isDirectory:NO];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url,
                                                         (__bridge CFDictionaryRef)@{
        (id)kCGImageSourceShouldCache: @NO,
    });
    if (!source) {
        if (outError) *outError = _VGGSFNInvalidBackgroundError(
            [NSString stringWithFormat:@"greenScreen imagePath could not be opened as an image: '%@'.", imagePath]);
        return nil;
    }
    CGImageRef image = NULL;
    if (CGImageSourceGetCount(source) > 0) {
        NSDictionary *options = @{
            (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (id)kCGImageSourceCreateThumbnailWithTransform:   @YES,
            (id)kCGImageSourceThumbnailMaxPixelSize:          @(VGGreenScreenBackgroundImageMaxPixelSize),
            (id)kCGImageSourceShouldCache:                    @NO,
        };
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        if (!image) {
            // Some encoders reject thumbnail generation; fall back to a full decode.
            image = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)@{
                (id)kCGImageSourceShouldCache: @NO,
            });
        }
    }
    CFRelease(source);
    if (!image || CGImageGetWidth(image) == 0 || CGImageGetHeight(image) == 0) {
        if (image) CGImageRelease(image);
        if (outError) *outError = _VGGSFNInvalidBackgroundError(
            [NSString stringWithFormat:@"greenScreen imagePath could not be decoded as an image: '%@'.", imagePath]);
        return nil;
    }

    VGGreenScreenBackgroundProvider *provider =
        [[self alloc] _initWithKind:VGGreenScreenBackgroundKindImageFile
                               argb:0
                          imagePath:imagePath
                          scaleMode:scaleMode
                              image:image];
    CGImageRelease(image);   // the provider retained its own +1
    NSLog(@"[VGGreenScreenBackgroundProvider] IOS_CAMERA_GRAPH_GREENSCREEN_BACKGROUND_DECODED "
           "path=%@ size=%zux%zu scaleMode=%@ maxPixelSize=%lu exifApplied=1",
          imagePath, provider->_imageWidth, provider->_imageHeight,
          VGGreenScreenBackgroundScaleModeName(scaleMode),
          (unsigned long)VGGreenScreenBackgroundImageMaxPixelSize);
    return provider;
}

- (NSString *)backgroundTypeName {
    return (_kind == VGGreenScreenBackgroundKindImageFile)
        ? VGGreenScreenBackgroundTypeImageFile
        : VGGreenScreenFilterNodeBackgroundTypeSolidColor;
}

// Places the decoded image into the canvas (Core Image bottom-left space):
// aspectFill covers and centre-crops, aspectFit contains and centres over
// opaque black. Returns a lazy recipe cropped exactly to the canvas.
- (nullable CIImage *)_placedImageForCanvas:(CGRect)canvas {
    if (!_image || _imageWidth == 0 || _imageHeight == 0) return nil;
    CIImage *image = [CIImage imageWithCGImage:_image];
    if (!image) return nil;
    const CGFloat W  = canvas.size.width;
    const CGFloat H  = canvas.size.height;
    const CGFloat sx = W / (CGFloat)_imageWidth;
    const CGFloat sy = H / (CGFloat)_imageHeight;
    const CGFloat s  = (_scaleMode == VGGreenScreenBackgroundScaleModeAspectFit) ? MIN(sx, sy) : MAX(sx, sy);
    const CGFloat tx = (W - (CGFloat)_imageWidth  * s) * 0.5;
    const CGFloat ty = (H - (CGFloat)_imageHeight * s) * 0.5;
    CIImage *placed = [image imageByApplyingTransform:CGAffineTransformMake(s, 0.0, 0.0, s, tx, ty)];
    if (_scaleMode == VGGreenScreenBackgroundScaleModeAspectFit) {
        CIImage *black = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1.0]]
                          imageByCroppingToRect:canvas];
        placed = [placed imageByCompositingOverImage:black];
    }
    return [placed imageByCroppingToRect:canvas];
}

- (nullable CIImage *)canvasImageForWidth:(size_t)width
                                   height:(size_t)height
                                   device:(id<MTLDevice>)device {
    if (width == 0 || height == 0) return nil;
    const CGRect canvas = CGRectMake(0, 0, (CGFloat)width, (CGFloat)height);

    // Solid colour: an infinite colour image cropped to the canvas is already
    // the cheapest possible background (no buffer, no render); cache the crop.
    os_unfair_lock_lock(&_cacheLock);
    CIImage *cached = (_cachedWidth == width && _cachedHeight == height) ? _cachedCanvasImage : nil;
    os_unfair_lock_unlock(&_cacheLock);
    if (cached) return cached;

    CIImage *canvasImage = nil;
    CVPixelBufferRef canvasBuffer = NULL;
    if (_kind == VGGreenScreenBackgroundKindSolidColor) {
        // Raw sRGB components, alpha forced opaque. With the unmanaged CIContext
        // these component values reach the output bytes as-is (MVP behaviour).
        const CGFloat r = ((_argb >> 16) & 0xFF) / 255.0;
        const CGFloat g = ((_argb >>  8) & 0xFF) / 255.0;
        const CGFloat b = ( _argb        & 0xFF) / 255.0;
        canvasImage = [[CIImage imageWithColor:[CIColor colorWithRed:r green:g blue:b alpha:1.0]]
                       imageByCroppingToRect:canvas];
    } else {
        CIImage *placed = [self _placedImageForCanvas:canvas];
        if (!placed) return nil;
        canvasBuffer = _VGGSFNCreateCanvasBuffer(width, height);
        if (!canvasBuffer) return nil;
        // One-time render of the placed still into the canvas buffer through
        // the shared no-colour-space context (raw bytes, like every frame).
        [_VGGSFNSharedCIContext(device) render:placed
                                toCVPixelBuffer:canvasBuffer
                                         bounds:canvas
                                     colorSpace:NULL];
        canvasImage = [CIImage imageWithCVPixelBuffer:canvasBuffer];
        if (!canvasImage) {
            CVPixelBufferRelease(canvasBuffer);
            return nil;
        }
        NSLog(@"[VGGreenScreenBackgroundProvider] IOS_CAMERA_GRAPH_GREENSCREEN_BACKGROUND_CANVAS_RENDERED "
               "canvas=%zux%zu image=%zux%zu scaleMode=%@ path=%@",
              width, height, _imageWidth, _imageHeight,
              VGGreenScreenBackgroundScaleModeName(_scaleMode), _imagePath);
    }

    // Publish the new cache entry; release the previous buffer outside the lock.
    CVPixelBufferRef previousBuffer = NULL;
    CIImage *previousImage = nil;
    os_unfair_lock_lock(&_cacheLock);
    previousBuffer      = _cachedCanvas;
    previousImage       = _cachedCanvasImage;
    _cachedCanvas       = canvasBuffer;   // ownership moves to the cache (+1)
    _cachedCanvasImage  = canvasImage;
    _cachedWidth        = width;
    _cachedHeight       = height;
    os_unfair_lock_unlock(&_cacheLock);
    if (previousBuffer) CVPixelBufferRelease(previousBuffer);
    (void)previousImage;   // released here, after the unlock
    return canvasImage;
}

@end

// ─── Live matte refinement (VGMatteRefinementPipeline, Swift; production) ───
//
// The node owns one VGMatteRefinementPipeline created with Objective-C init
// ([[VGMatteRefinementPipeline alloc] init]), which tracks
// VGMatteRefinementPipeline.defaultLiveMatteRefinementMode (current production
// default is .s4SoftAlphaR2). Explicit S1 fallback still exists elsewhere, but
// this Objective-C node does not select modes directly. The node shares the
// same live refinement implementation as other green-screen callers in this
// package, refining every frame's matte through its Objective-C bridge,
// refineLiveGreenScreenMaskWithAspectFilledMask:inRect:guidedBy:.
// The bridge returns a VGMatteRefinementLiveResult: the refined mask (a lazy
// CIImage recipe; the GPU work still lands in the single render at the end of
// processBuffer:) plus the four S1 applied flags that feed telemetry and logs.
// The pipeline is stateless per frame and thread-confined to the graph
// execution queue like the rest of processBuffer:. Nothing here allocates
// buffers, touches the pool or the device, or retains anything beyond the call.

// ─── Alpha output stage (outputMode = alpha) ─────────────────────────────────
//
// Builds the keyed image whose RGB is the camera foreground and whose alpha is
// the refined matte, WITHOUT premultiplying RGB by the matte and without
// compositing over any background:
//   transparentForeground = CIColorMatrix(foreground, A := 0)     → (fg.rgb, 0)
//   keyed = CIBlendWithMask(inputImage           = foreground     → (fg.rgb, 1)
//                           inputBackgroundImage = transparentForeground,
//                           inputMaskImage       = refined matte m)
//         = (fg.rgb·m + fg.rgb·(1−m), 1·m + 0·(1−m)) = (fg.rgb, m)
// CIBlendWithMask is a per-component mix, so RGB comes out as the foreground
// (byte-identical where m ∈ {0, 1}; the two half-float products may round by
// ≤ 1 LSB inside the feather band) and alpha is exactly the refined matte.
// Pure CIImage recipe: no CPU pixel loop, no allocation, nothing retained.
//
// ALPHA ENCODING (read before consuming the buffer):
//   Core Image's working representation is PREMULTIPLIED: CIColorMatrix
//   re-premultiplies after zeroing alpha and CIBlendWithMask mixes
//   premultiplied samples, so the working value of this recipe is
//   (fg.rgb·m, m), not (fg.rgb, m). Measured on device (iPhone 16, iOS 26.6):
//   rendered through the shared context (default kCIContextOutputPremultiplied
//   = YES) the bytes came out premultiplied — edge (100,64,24,128) for a
//   (200,128,48) foreground at m = 128, background (0,0,0,0). The alpha path
//   therefore renders through _VGGSFNRenderStraightAlpha, whose context sets
//   kCIContextOutputPremultiplied = NO so the final render un-premultiplies
//   (RGB / A) and writes STRAIGHT alpha: (fg.rgb, m) wherever m > 0. Fully
//   transparent pixels (m = 0) carry RGB = 0, because un-premultiplying a
//   transparent working pixel yields zero; a straight-alpha source-over
//   (C = C_fg·A + C_bg·(1−A)) never reads RGB where A = 0, so consumers are
//   unaffected. A premultiplied compositor (including the Flutter Texture
//   preview) still misreads this buffer, which is why preview appearance in
//   alpha mode proves nothing. The one-time alpha byte self-test
//   (_VGGSFNRunAlphaByteSelfTest, below; run at init in alpha mode) renders
//   this recipe on a synthetic input through the SAME
//   _VGGSFNRenderStraightAlpha call and reads the bytes back; the diagnostics
//   report alphaEncoding = "straight" ONLY when it passed, otherwise
//   "unverified". Live camera frames are still not byte-measured.
//
// Returns nil with *failReason set when a required filter is unavailable or
// produces nil, so the caller fails open to the input exactly like the
// solid-colour path.
static CIImage * _Nullable _VGGSFNStraightAlphaKeyedImage(CIImage *foreground, CIImage *matte,
                                                          CGRect rect,
                                                          NSString * _Nullable * _Nonnull failReason) {
    *failReason = nil;
    if (!foreground || !matte || CGRectIsEmpty(rect)) {
        *failReason = @"alpha_degenerate_input";
        return nil;
    }

    CIFilter *clearAlpha = [CIFilter filterWithName:@"CIColorMatrix"];
    if (!clearAlpha) {
        *failReason = @"alpha_colormatrix_unavailable";
        return nil;
    }
    [clearAlpha setValue:foreground forKey:kCIInputImageKey];
    [clearAlpha setValue:[CIVector vectorWithX:1 Y:0 Z:0 W:0] forKey:@"inputRVector"];
    [clearAlpha setValue:[CIVector vectorWithX:0 Y:1 Z:0 W:0] forKey:@"inputGVector"];
    [clearAlpha setValue:[CIVector vectorWithX:0 Y:0 Z:1 W:0] forKey:@"inputBVector"];
    [clearAlpha setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0] forKey:@"inputAVector"];
    [clearAlpha setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0] forKey:@"inputBiasVector"];
    CIImage *transparentForeground = clearAlpha.outputImage;
    if (!transparentForeground) {
        *failReason = @"alpha_colormatrix_nil_output";
        return nil;
    }

    CIFilter *blend = [CIFilter filterWithName:@"CIBlendWithMask"];
    if (!blend) {
        *failReason = @"blend_filter_unavailable";
        return nil;
    }
    [blend setValue:foreground            forKey:kCIInputImageKey];
    [blend setValue:transparentForeground forKey:kCIInputBackgroundImageKey];
    [blend setValue:matte                 forKey:kCIInputMaskImageKey];
    CIImage *keyed = blend.outputImage;
    if (!keyed) {
        *failReason = @"blend_nil_output";
        return nil;
    }
    return [keyed imageByCroppingToRect:rect];
}

// ─── Alpha byte self-test (alpha mode, once at init) ─────────────────────────
//
// Deterministic byte-level proof that _VGGSFNStraightAlphaKeyedImage, rendered
// through the SAME _VGGSFNRenderStraightAlpha call (un-premultiplied context,
// NULL colour space) as the alpha frame path, writes STRAIGHT alpha into a
// 32BGRA CVPixelBuffer:
//   foreground : W×H 32BGRA, every pixel = (B 48, G 128, R 200, A 255)
//   matte      : W×H OneComponent8 in three vertical bands (like Vision's mask)
//                columns [0, W/3)    = 0    → background band
//                columns [W/3, 2W/3) = 128  → edge / feather band
//                columns [2W/3, W)   = 255  → foreground band
//   output     : the helper's image rendered into a fresh, ZERO-FILLED W×H
//                32BGRA buffer (zero-filled so an un-rendered pixel can never
//                pass the RGB check); the centre pixel of each band is read
//                back on the CPU.
// Pass requires A ≤ kAlphaTol in the background band, A ≥ 255 − kAlphaTol with
// RGB == (200,128,48) ± kRGBTol in the foreground band, and
// kEdgeAlphaMin ≤ A ≤ kEdgeAlphaMax with RGB == (200,128,48) ± kRGBTol in the
// edge band. A premultiplied output halves the edge RGB (measured on device:
// (100,64,24,128)), so the edge RGB check is the decisive
// straight-vs-premultiplied evidence. Background RGB is reported but not
// evaluated: un-premultiplying a fully transparent working pixel yields 0, and
// a straight-alpha source-over never reads RGB where A = 0. Bands are vertical
// (constant over y) so the result is independent of the buffer's row
// orientation.
//
// Runs once inside the designated initialiser (alpha mode only), on the
// caller's thread, before any frame. It allocates three tiny buffers that are
// released before returning and touches no pool, no camera state and no
// telemetry lock. Never throws; every failure returns NO with a reason. The
// caller stores the result in immutable fields. A byte mismatch never changes
// frame behaviour (the alpha path still runs; diagnostics report alphaEncoding
// "unverified"); an unavailable straight-alpha context makes every alpha frame
// fail open through the same _VGGSFNRenderStraightAlpha call.

static const size_t  kVGGSFNSelfTestWidth        = 48;   // three 16-px bands
static const size_t  kVGGSFNSelfTestHeight       = 16;
static const uint8_t kVGGSFNSelfTestFgB          = 48;   // synthetic foreground, BGRA byte order
static const uint8_t kVGGSFNSelfTestFgG          = 128;
static const uint8_t kVGGSFNSelfTestFgR          = 200;
static const uint8_t kVGGSFNSelfTestEdgeMatte    = 128;  // edge band matte value
static const int     kVGGSFNSelfTestRGBTol       = 2;    // half-float rounding allowance
static const int     kVGGSFNSelfTestAlphaTol     = 2;    // A ≈ 0 / A ≈ 255 allowance
static const int     kVGGSFNSelfTestEdgeAlphaMin = 16;   // 0 < A < 255 with margin
static const int     kVGGSFNSelfTestEdgeAlphaMax = 239;

// Creates a W×H buffer of `format` with the session pool's IOSurface / Metal
// attributes, runs `fill` over its locked base address, and returns it +1
// (NULL on any CoreVideo failure).
static CVPixelBufferRef _Nullable _VGGSFNSelfTestCreateBuffer(size_t width, size_t height, OSType format,
                                                              void (NS_NOESCAPE ^fill)(uint8_t *base, size_t bytesPerRow)) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey:  @YES,
    };
    CVPixelBufferRef buffer = NULL;
    CVReturn rv = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                      (__bridge CFDictionaryRef)attrs, &buffer);
    if (rv != kCVReturnSuccess || !buffer) {
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(buffer);
        return NULL;
    }
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    if (!base) {
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        CVPixelBufferRelease(buffer);
        return NULL;
    }
    fill(base, CVPixelBufferGetBytesPerRow(buffer));
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

// RGB of a read-back BGRA pixel equals the synthetic foreground within tolerance.
static BOOL _VGGSFNSelfTestRGBPreserved(const uint8_t px[4]) {
    return abs((int)px[0] - (int)kVGGSFNSelfTestFgB) <= kVGGSFNSelfTestRGBTol &&
           abs((int)px[1] - (int)kVGGSFNSelfTestFgG) <= kVGGSFNSelfTestRGBTol &&
           abs((int)px[2] - (int)kVGGSFNSelfTestFgR) <= kVGGSFNSelfTestRGBTol;
}

// Runs the self-test. Returns YES on pass; *outReason is always set
// ("pass <samples>" or "fail:<codes> <samples>" or an allocation/render
// failure code) and *outWidth/*outHeight always describe the synthetic image.
static BOOL _VGGSFNRunAlphaByteSelfTest(id<MTLDevice> device,
                                        size_t * _Nonnull outWidth,
                                        size_t * _Nonnull outHeight,
                                        NSString * _Nonnull * _Nonnull outReason) {
    const size_t W    = kVGGSFNSelfTestWidth;
    const size_t H    = kVGGSFNSelfTestHeight;
    const size_t band = W / 3;
    *outWidth  = W;
    *outHeight = H;
    *outReason = @"self_test_not_run";

    // Synthetic opaque foreground: every pixel (B, G, R, 255).
    CVPixelBufferRef foregroundBuffer =
        _VGGSFNSelfTestCreateBuffer(W, H, kCVPixelFormatType_32BGRA, ^(uint8_t *base, size_t bpr) {
            for (size_t y = 0; y < H; y++) {
                uint8_t *row = base + y * bpr;
                for (size_t x = 0; x < W; x++) {
                    row[x * 4 + 0] = kVGGSFNSelfTestFgB;
                    row[x * 4 + 1] = kVGGSFNSelfTestFgG;
                    row[x * 4 + 2] = kVGGSFNSelfTestFgR;
                    row[x * 4 + 3] = 255;
                }
            }
        });
    if (!foregroundBuffer) {
        *outReason = @"self_test_foreground_alloc_failed";
        return NO;
    }

    // Synthetic matte: three vertical bands 0 | 128 | 255 (OneComponent8, the
    // same pixel format Vision's person mask arrives in on the frame path).
    CVPixelBufferRef matteBuffer =
        _VGGSFNSelfTestCreateBuffer(W, H, kCVPixelFormatType_OneComponent8, ^(uint8_t *base, size_t bpr) {
            for (size_t y = 0; y < H; y++) {
                uint8_t *row = base + y * bpr;
                for (size_t x = 0; x < W; x++) {
                    row[x] = (x < band) ? 0 : (x < 2 * band) ? kVGGSFNSelfTestEdgeMatte : 255;
                }
            }
        });
    if (!matteBuffer) {
        CVPixelBufferRelease(foregroundBuffer);
        *outReason = @"self_test_matte_alloc_failed";
        return NO;
    }

    // Output: zero-filled so a pixel the render did not write fails the RGB check.
    CVPixelBufferRef outputBuffer =
        _VGGSFNSelfTestCreateBuffer(W, H, kCVPixelFormatType_32BGRA, ^(uint8_t *base, size_t bpr) {
            for (size_t y = 0; y < H; y++) {
                memset(base + y * bpr, 0, W * 4);
            }
        });
    if (!outputBuffer) {
        CVPixelBufferRelease(matteBuffer);
        CVPixelBufferRelease(foregroundBuffer);
        *outReason = @"self_test_output_alloc_failed";
        return NO;
    }

    BOOL     passed  = NO;
    NSString *reason = nil;
    uint8_t bgPx[4]   = {0, 0, 0, 0};
    uint8_t edgePx[4] = {0, 0, 0, 0};
    uint8_t fgPx[4]   = {0, 0, 0, 0};
    BOOL samplesRead  = NO;

    @autoreleasepool {
        CIImage *foreground = [CIImage imageWithCVPixelBuffer:foregroundBuffer];
        CIImage *matte      = [CIImage imageWithCVPixelBuffer:matteBuffer];
        const CGRect rect   = CGRectMake(0, 0, (CGFloat)W, (CGFloat)H);
        if (!foreground || !matte) {
            reason = @"self_test_ciimage_wrap_failed";
        } else {
            NSString *helperFailReason = nil;
            CIImage *keyed = _VGGSFNStraightAlphaKeyedImage(foreground, matte, rect, &helperFailReason);
            if (!keyed) {
                reason = [NSString stringWithFormat:@"self_test_helper_failed(%@)",
                          helperFailReason ?: @"unknown"];
            } else if (!_VGGSFNRenderStraightAlpha(device, keyed, outputBuffer, rect)) {
                // Same condition that makes live alpha frames fail open.
                reason = @"self_test_straight_alpha_context_unavailable";
            } else {
                // Rendered above through the SAME call as the alpha frame path
                // (synchronous; un-premultiplied output; NULL colour space).
                if (CVPixelBufferLockBaseAddress(outputBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
                    reason = @"self_test_output_lock_failed";
                } else {
                    const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(outputBuffer);
                    const size_t   bpr  = CVPixelBufferGetBytesPerRow(outputBuffer);
                    if (!base) {
                        reason = @"self_test_output_base_null";
                    } else {
                        const uint8_t *row = base + (H / 2) * bpr;
                        memcpy(bgPx,   row + (band / 2) * 4,            4);
                        memcpy(edgePx, row + (band + band / 2) * 4,     4);
                        memcpy(fgPx,   row + (2 * band + band / 2) * 4, 4);
                        samplesRead = YES;
                    }
                    CVPixelBufferUnlockBaseAddress(outputBuffer, kCVPixelBufferLock_ReadOnly);
                }
            }
        }
    }
    CVPixelBufferRelease(outputBuffer);
    CVPixelBufferRelease(matteBuffer);
    CVPixelBufferRelease(foregroundBuffer);

    if (!samplesRead) {
        *outReason = reason ?: @"self_test_samples_not_read";
        return NO;
    }

    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    // Background band: alpha only. RGB at A = 0 is unrecoverable after
    // un-premultiplication and irrelevant to a straight-alpha compositor.
    if ((int)bgPx[3] > kVGGSFNSelfTestAlphaTol)                [failures addObject:@"bg_alpha_not_transparent"];
    if ((int)fgPx[3] < 255 - kVGGSFNSelfTestAlphaTol)          [failures addObject:@"fg_alpha_not_opaque"];
    if (!_VGGSFNSelfTestRGBPreserved(fgPx))                    [failures addObject:@"fg_rgb_not_preserved"];
    if ((int)edgePx[3] < kVGGSFNSelfTestEdgeAlphaMin ||
        (int)edgePx[3] > kVGGSFNSelfTestEdgeAlphaMax)          [failures addObject:@"edge_alpha_not_partial"];
    if (!_VGGSFNSelfTestRGBPreserved(edgePx))                  [failures addObject:@"edge_rgb_not_preserved"];
    passed = (failures.count == 0);

    NSString *samples = [NSString stringWithFormat:
        @"expectedRGB=(%u,%u,%u) bgRGBA=(%u,%u,%u,%u) edgeRGBA=(%u,%u,%u,%u) fgRGBA=(%u,%u,%u,%u) "
         "edgeMatte=%u tolRGB=%d tolAlpha=%d edgeAlphaRange=[%d,%d]",
        (unsigned)kVGGSFNSelfTestFgR, (unsigned)kVGGSFNSelfTestFgG, (unsigned)kVGGSFNSelfTestFgB,
        (unsigned)bgPx[2],   (unsigned)bgPx[1],   (unsigned)bgPx[0],   (unsigned)bgPx[3],
        (unsigned)edgePx[2], (unsigned)edgePx[1], (unsigned)edgePx[0], (unsigned)edgePx[3],
        (unsigned)fgPx[2],   (unsigned)fgPx[1],   (unsigned)fgPx[0],   (unsigned)fgPx[3],
        (unsigned)kVGGSFNSelfTestEdgeMatte, kVGGSFNSelfTestRGBTol, kVGGSFNSelfTestAlphaTol,
        kVGGSFNSelfTestEdgeAlphaMin, kVGGSFNSelfTestEdgeAlphaMax];
    *outReason = passed
        ? [NSString stringWithFormat:@"pass %@", samples]
        : [NSString stringWithFormat:@"fail:%@ %@", [failures componentsJoinedByString:@","], samples];
    return passed;
}

@interface VGGreenScreenFilterNode ()
- (nullable VNPixelBufferObservation *)_personMatteObservationForBuffer:(CVPixelBufferRef)input
                                                                  error:(NSError * _Nullable * _Nullable)outError
    API_AVAILABLE(ios(15.0));
- (CVPixelBufferRef)_failOpenWithInput:(CVPixelBufferRef)input reason:(NSString *)reason;
@end

@implementation VGGreenScreenFilterNode {
    CVPixelBufferPoolRef _pool;               // +1 owned; released in dealloc
    id<MTLDevice>        _device;
    // ── Composite state (guarded by _stateLock; read once per frame, written
    //    only by init and the hot-update API). Alpha is fixed for the node's
    //    lifetime; SolidColor ⇄ ImageFile swap in place with their provider.
    os_unfair_lock       _stateLock;
    VGGreenScreenFilterNodeOutputMode _outputMode;
    uint32_t             _backgroundARGB;             // solidColor colour; 0 otherwise
    VGGreenScreenBackgroundProvider *_backgroundProvider;   // composite modes; nil in alpha mode
    VGGreenScreenForegroundTransform _foregroundTransform;  // clamped; identity unless set
    uint64_t             _backgroundHotUpdateCount;
    uint64_t             _transformHotUpdateCount;
    VGMatteRefinementPipeline *_mattePipeline; // Swift live matte refiner (tracks defaultLiveMatteRefinementMode, .s4SoftAlphaR2; stateless per frame)
    // Alpha byte self-test result (alpha mode only). Written once in init and
    // immutable afterwards, so -diagnosticsSnapshot reads it without the lock.
    // solidColor: NO / @"not_applicable" / 0×0.
    BOOL                 _alphaByteSelfTestPassed;
    NSString            *_alphaByteSelfTestReason;
    NSUInteger           _alphaByteSelfTestWidth;
    NSUInteger           _alphaByteSelfTestHeight;
    _Atomic(BOOL)        _invalidated;
    _Atomic(uint64_t)    _frameCounter;       // frames that entered processing (diagnostics)
    _Atomic(uint64_t)    _failOpenCounter;    // fail-open events (diagnostics, throttled log)
    _Atomic(BOOL)        _loggedUnavailable;
    _Atomic(BOOL)        _loggedPoolMismatch;

    // ── Telemetry (read by -diagnosticsSnapshot from any thread, written on
    //    the graph execution queue). Every field below is guarded by
    //    _telemetryLock; hold time is a handful of scalar stores/loads. The
    //    counts here cover successfully keyed/rendered frames only — frames
    //    entering processing and fail-opens use the atomics above.
    os_unfair_lock       _telemetryLock;
    uint64_t             _tmProcessedFrameCount;          // keyed + rendered frames
    uint64_t             _tmAllS1StagesAppliedFrameCount; // keyed frames with all 4 S1 stages
    size_t               _tmLastSourceWidth;
    size_t               _tmLastSourceHeight;
    size_t               _tmLastMatteWidth;
    size_t               _tmLastMatteHeight;
    BOOL                 _tmLastMorphologyCloseApplied;
    BOOL                 _tmLastFeatherApplied;
    BOOL                 _tmLastTrimapApplied;
    BOOL                 _tmLastGuidedEdgeApplied;
    // Live refinement mode/S4-family metadata from the last successful refinement
    // (VGMatteRefinementLiveResult). liveMatteRefinementMode is @"unknown" until the
    // first keyed frame; the node's pipeline instance always tracks
    // VGMatteRefinementPipeline.defaultLiveMatteRefinementMode (.s4SoftAlphaR2) via its
    // Objective-C init, so every keyed frame after that reports "s4SoftAlphaR2".
    NSString            *_tmLastLiveMatteRefinementMode;
    BOOL                 _tmLastS4GuidedAlphaApplied;
    uint64_t             _tmS4GuidedAlphaAppliedFrameCount;
    BOOL                 _tmLastS4GuidedAlphaR1Applied;
    BOOL                 _tmLastTightAlphaR1Applied;
    double               _tmLastVisionMs;
    double               _tmSumVisionMs;
    double               _tmMaxVisionMs;
    double               _tmLastBlendRenderMs;
    double               _tmSumBlendRenderMs;
    double               _tmMaxBlendRenderMs;
    double               _tmLastTotalMs;
    double               _tmSumTotalMs;
    double               _tmMaxTotalMs;
    NSString            *_tmLastFailOpenReason;           // @"none" until the first fail-open
}

@synthesize filterName     = _filterName;
@synthesize enabled        = _enabled;
@synthesize nodeId         = _nodeId;
@synthesize nodeType       = _nodeType;
@synthesize matteSource    = _matteSource;

// ─── Composite state accessors (lock-read; see the ivar comment) ──────────────

- (VGGreenScreenFilterNodeOutputMode)outputMode {
    os_unfair_lock_lock(&_stateLock);
    const VGGreenScreenFilterNodeOutputMode mode = _outputMode;
    os_unfair_lock_unlock(&_stateLock);
    return mode;
}

- (uint32_t)backgroundARGB {
    os_unfair_lock_lock(&_stateLock);
    const uint32_t argb = _backgroundARGB;
    os_unfair_lock_unlock(&_stateLock);
    return argb;
}

- (nullable VGGreenScreenBackgroundProvider *)backgroundProvider {
    os_unfair_lock_lock(&_stateLock);
    VGGreenScreenBackgroundProvider *provider = _backgroundProvider;
    os_unfair_lock_unlock(&_stateLock);
    return provider;
}

- (VGGreenScreenForegroundTransform)foregroundTransform {
    os_unfair_lock_lock(&_stateLock);
    const VGGreenScreenForegroundTransform t = _foregroundTransform;
    os_unfair_lock_unlock(&_stateLock);
    return t;
}
@synthesize alphaByteSelfTestPassed = _alphaByteSelfTestPassed;
@synthesize alphaByteSelfTestReason = _alphaByteSelfTestReason;
@synthesize alphaByteSelfTestWidth  = _alphaByteSelfTestWidth;
@synthesize alphaByteSelfTestHeight = _alphaByteSelfTestHeight;

// ─── VGMediaNode / VGMetalFilterNode cost model ───────────────────────────────

- (BOOL)isExpensive { return YES; }
- (float)estimatedGPUCostMs { return 12.0f; }
- (VGNodeRole)nodeRole { return VGNodeRoleFilter; }

// ─── Lifecycle ────────────────────────────────────────────────────────────────

- (void)prepareWithCompletion:(void (^)(NSError * _Nullable))completion {
    if (completion) completion(nil);
}

- (void)invalidate {
    // Terminal, idempotent, lock-free, allocation-free. Nothing asynchronous is
    // ever in flight (Vision runs synchronously inside processBuffer:), so there
    // is nothing to cancel; every subsequent frame passes through.
    atomic_store(&_invalidated, YES);
}

- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
              backgroundARGB:(uint32_t)backgroundARGB {
    return [self initWithPool:pool
                       device:device
                   outputMode:VGGreenScreenFilterNodeOutputModeSolidColor
               backgroundARGB:backgroundARGB];
}

- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
                  outputMode:(VGGreenScreenFilterNodeOutputMode)outputMode
              backgroundARGB:(uint32_t)backgroundARGB {
    const BOOL alpha = (outputMode == VGGreenScreenFilterNodeOutputModeAlpha);
    VGGreenScreenBackgroundProvider *provider =
        alpha ? nil : [VGGreenScreenBackgroundProvider solidColorProviderWithARGB:backgroundARGB];
    return [self initWithPool:pool
                       device:device
                   outputMode:(alpha ? VGGreenScreenFilterNodeOutputModeAlpha
                                     : VGGreenScreenFilterNodeOutputModeSolidColor)
           backgroundProvider:provider
          foregroundTransform:VGGreenScreenForegroundTransformIdentity];
}

- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
                  outputMode:(VGGreenScreenFilterNodeOutputMode)outputMode
          backgroundProvider:(nullable VGGreenScreenBackgroundProvider *)backgroundProvider
         foregroundTransform:(VGGreenScreenForegroundTransform)foregroundTransform {
    NSParameterAssert(device != nil);
    self = [super init];
    if (!self) return nil;

    _stateLock = OS_UNFAIR_LOCK_INIT;

    // Deterministic resolution (never trap, so filter-chain validation stays
    // atomic): Alpha has no background; a composite mode takes its mode from
    // the provider's kind, and a missing provider degrades to opaque black.
    if (outputMode == VGGreenScreenFilterNodeOutputModeAlpha) {
        _outputMode         = VGGreenScreenFilterNodeOutputModeAlpha;
        _backgroundProvider = nil;
        _backgroundARGB     = 0;
    } else {
        VGGreenScreenBackgroundProvider *resolved =
            backgroundProvider ?: [VGGreenScreenBackgroundProvider solidColorProviderWithARGB:0xFF000000];
        _backgroundProvider = resolved;
        _outputMode         = (resolved.kind == VGGreenScreenBackgroundKindImageFile)
                                ? VGGreenScreenFilterNodeOutputModeImageFile
                                : VGGreenScreenFilterNodeOutputModeSolidColor;
        _backgroundARGB     = (resolved.kind == VGGreenScreenBackgroundKindSolidColor) ? resolved.argb : 0;
    }
    _foregroundTransform = VGGreenScreenForegroundTransformMakeClamped(
        foregroundTransform.scale, foregroundTransform.offsetX, foregroundTransform.offsetY);
    _backgroundHotUpdateCount = 0;
    _transformHotUpdateCount  = 0;

    _pool           = pool ? (CVPixelBufferPoolRef)CFRetain(pool) : NULL;
    _device         = device;
    _enabled        = YES;
    atomic_init(&_invalidated, NO);
    atomic_init(&_frameCounter, 0);
    atomic_init(&_failOpenCounter, 0);
    atomic_init(&_loggedUnavailable, NO);
    atomic_init(&_loggedPoolMismatch, NO);

    // Telemetry: the numeric fields start at zero from alloc; only the lock
    // and the initial fail-open reason need explicit values.
    _telemetryLock        = OS_UNFAIR_LOCK_INIT;
    _tmLastFailOpenReason = @"none";
    // Live mode is unknown until the first successful refinement reports it (the
    // pipeline instance's mode is not queryable before then); see the ivar comment.
    _tmLastLiveMatteRefinementMode = @"unknown";

    _nodeId     = [[NSUUID UUID] UUIDString];
    _nodeType   = @"VGGreenScreenFilterNode";
    _filterName = @"GreenScreen";

    // Live matte refiner: the node owns one VGMatteRefinementPipeline created
    // with Objective-C init, tracking VGMatteRefinementPipeline.defaultLiveMatteRefinementMode
    // (current production default is .s4SoftAlphaR2). Explicit S1 fallback still
    // exists elsewhere, but this Objective-C node does not select modes directly;
    // it shares the same live refinement implementation as other green-screen callers.
    _mattePipeline = [[VGMatteRefinementPipeline alloc] init];

    // The background itself (solid colour or still image) lives in
    // _backgroundProvider; alpha mode composites nothing.

    if (@available(iOS 15.0, *)) {
        _matteSource = VGGreenScreenFilterNodeMatteSourceVisionPersonFast;
    } else {
        _matteSource = VGGreenScreenFilterNodeMatteSourceUnavailable;
    }

    // ── Alpha byte self-test (alpha mode only; once, before any frame) ──────
    //   Byte-level proof of the straight-alpha construction on a synthetic
    //   input (see _VGGSFNRunAlphaByteSelfTest). Independent of the matte
    //   source (it exercises the CoreImage output stage, not Vision). The
    //   result is immutable from here on; a failure never alters the frame
    //   path — it is reported through diagnostics and the marker below.
    _alphaByteSelfTestPassed = NO;
    _alphaByteSelfTestReason = @"not_applicable";
    _alphaByteSelfTestWidth  = 0;
    _alphaByteSelfTestHeight = 0;
    if (_outputMode == VGGreenScreenFilterNodeOutputModeAlpha) {
        size_t selfTestW = 0, selfTestH = 0;
        NSString *selfTestReason = @"self_test_not_run";
        const BOOL selfTestPassed =
            _VGGSFNRunAlphaByteSelfTest(_device, &selfTestW, &selfTestH, &selfTestReason);
        _alphaByteSelfTestPassed = selfTestPassed;
        _alphaByteSelfTestReason = [selfTestReason copy] ?: @"unknown";
        _alphaByteSelfTestWidth  = (NSUInteger)selfTestW;
        _alphaByteSelfTestHeight = (NSUInteger)selfTestH;
        NSLog(@"[VGGreenScreenFilterNode] IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_ALPHA_BYTE_SELF_TEST "
               "passed=%d width=%lu height=%lu reason=%@",
              (int)_alphaByteSelfTestPassed,
              (unsigned long)_alphaByteSelfTestWidth, (unsigned long)_alphaByteSelfTestHeight,
              _alphaByteSelfTestReason);
    }

    NSLog(@"[VGGreenScreenFilterNode] IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_NODE_CREATED "
           "proofLevel=liveMatteRefinement matteSource=%@ outputMode=%@ backgroundType=%@ alphaEncoding=%@ "
           "backgroundARGB=0x%08X alphaByteIgnored=1 backgroundImagePath=%@ backgroundScaleMode=%@ "
           "backgroundImageSize=%zux%zu foregroundScale=%.3f foregroundOffsetX=%.3f foregroundOffsetY=%.3f "
           "pool=%p edgeRefinement=liveMatteRefinement "
           "liveMatteRefinementModeExpected=s4SoftAlphaR2(confirmedPerFrame) "
           "morphologyCloseRadius=%.1f featherRadius=%.1f trimapLow=%.2f trimapHigh=%.2f "
           "guidedEdgeIntensity=%.1f guidedEdgeBlurRadius=%.1f guidedEdgeLow=%.2f "
           "guidedEdgeHigh=%.2f temporalSmoothing=none tikTokParityClaim=none",
          (_matteSource == VGGreenScreenFilterNodeMatteSourceVisionPersonFast)
              ? @"visionPersonFast" : @"unavailable",
          _VGGSFNOutputModeName(_outputMode), _VGGSFNOutputModeName(_outputMode),
          _VGGSFNAlphaEncodingName(_outputMode, _alphaByteSelfTestPassed),
          _backgroundARGB,
          _backgroundProvider.imagePath ?: @"",
          (_outputMode == VGGreenScreenFilterNodeOutputModeImageFile)
              ? VGGreenScreenBackgroundScaleModeName(_backgroundProvider.scaleMode) : @"",
          _backgroundProvider.imageWidth, _backgroundProvider.imageHeight,
          (double)_foregroundTransform.scale, (double)_foregroundTransform.offsetX,
          (double)_foregroundTransform.offsetY,
          _pool,
          (double)VGMatteRefinementPipeline.greenScreenMaskMorphologyCloseRadius,
          (double)VGMatteRefinementPipeline.greenScreenMaskFeatherRadius,
          (double)VGMatteRefinementPipeline.greenScreenTrimapLow,
          (double)VGMatteRefinementPipeline.greenScreenTrimapHigh,
          (double)VGMatteRefinementPipeline.greenScreenGuidedEdgeIntensity,
          (double)VGMatteRefinementPipeline.greenScreenGuidedEdgeBlurRadius,
          (double)VGMatteRefinementPipeline.greenScreenGuidedEdgeLow,
          (double)VGMatteRefinementPipeline.greenScreenGuidedEdgeHigh);
    return self;
}

- (void)dealloc {
    if (_pool) {
        CVPixelBufferPoolRelease(_pool);
        _pool = NULL;
    }
}

// ─── Hot updates (no graph rebuild) ──────────────────────────────────────────
//
// Validates first, writes second: nothing is stored until every check passed,
// so a rejected call leaves the live background and transform untouched. The
// write is a few pointer/scalar stores under _stateLock; the previous provider
// (and its cached canvas buffer) is released only after the unlock.

- (BOOL)applyHotUpdateWithBackgroundProvider:(nullable VGGreenScreenBackgroundProvider *)backgroundProvider
                         foregroundTransform:(nullable const VGGreenScreenForegroundTransform *)foregroundTransform
                                       error:(NSError * _Nullable * _Nullable)outError {
    if (outError) *outError = nil;
    if (!backgroundProvider && !foregroundTransform) {
        if (outError) *outError = [NSError errorWithDomain:@"HOT_UPDATE_FAIL" code:400 userInfo:@{
            NSLocalizedDescriptionKey: @"greenScreen hot update carries neither a background nor a transform."}];
        return NO;
    }
    if (atomic_load(&_invalidated)) {
        if (outError) *outError = [NSError errorWithDomain:@"HOT_UPDATE_FAIL" code:410 userInfo:@{
            NSLocalizedDescriptionKey: @"greenScreen hot update rejected: the node is invalidated."}];
        return NO;
    }
    os_unfair_lock_lock(&_stateLock);
    const BOOL alphaMode = (_outputMode == VGGreenScreenFilterNodeOutputModeAlpha);
    os_unfair_lock_unlock(&_stateLock);
    if (alphaMode && backgroundProvider) {
        if (outError) *outError = [NSError errorWithDomain:@"HOT_UPDATE_FAIL" code:409 userInfo:@{
            NSLocalizedDescriptionKey: @"greenScreen alpha output has no background; switching to a "
                                        "solidColor/imageFile background requires a filter-chain rebuild."}];
        return NO;
    }

    VGGreenScreenForegroundTransform clamped = VGGreenScreenForegroundTransformIdentity;
    if (foregroundTransform) {
        clamped = VGGreenScreenForegroundTransformMakeClamped(
            foregroundTransform->scale, foregroundTransform->offsetX, foregroundTransform->offsetY);
    }

    VGGreenScreenBackgroundProvider *previousProvider = nil;
    VGGreenScreenFilterNodeOutputMode modeNow;
    uint32_t argbNow;
    VGGreenScreenForegroundTransform transformNow;
    uint64_t backgroundUpdates, transformUpdates;
    os_unfair_lock_lock(&_stateLock);
    if (backgroundProvider) {
        previousProvider    = _backgroundProvider;
        _backgroundProvider = backgroundProvider;
        _outputMode         = (backgroundProvider.kind == VGGreenScreenBackgroundKindImageFile)
                                ? VGGreenScreenFilterNodeOutputModeImageFile
                                : VGGreenScreenFilterNodeOutputModeSolidColor;
        _backgroundARGB     = (backgroundProvider.kind == VGGreenScreenBackgroundKindSolidColor)
                                ? backgroundProvider.argb : 0;
        _backgroundHotUpdateCount += 1;
    }
    if (foregroundTransform) {
        _foregroundTransform = clamped;
        _transformHotUpdateCount += 1;
    }
    modeNow           = _outputMode;
    argbNow           = _backgroundARGB;
    transformNow      = _foregroundTransform;
    backgroundUpdates = _backgroundHotUpdateCount;
    transformUpdates  = _transformHotUpdateCount;
    os_unfair_lock_unlock(&_stateLock);
    (void)previousProvider;   // released here, after the unlock

    NSLog(@"[VGGreenScreenFilterNode] IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_HOT_UPDATE "
           "background=%d transform=%d outputMode=%@ backgroundARGB=0x%08X backgroundImagePath=%@ "
           "foregroundScale=%.3f foregroundOffsetX=%.3f foregroundOffsetY=%.3f "
           "backgroundHotUpdateCount=%llu transformHotUpdateCount=%llu graphRebuilt=0",
          (int)(backgroundProvider != nil), (int)(foregroundTransform != NULL),
          _VGGSFNOutputModeName(modeNow), argbNow,
          backgroundProvider.imagePath ?: @"",
          (double)transformNow.scale, (double)transformNow.offsetX, (double)transformNow.offsetY,
          (unsigned long long)backgroundUpdates, (unsigned long long)transformUpdates);
    return YES;
}

// ─── Fail-open helper ─────────────────────────────────────────────────────────
//
// Every failure path returns the input (+1) so the preview shows the unkeyed
// camera rather than a dropped or corrupt frame. Logged for the first 3 events
// and then every 60th so a physical run can count fail-opens without log spam.
- (CVPixelBufferRef)_failOpenWithInput:(CVPixelBufferRef)input reason:(NSString *)reason {
    uint64_t n = atomic_fetch_add(&_failOpenCounter, 1) + 1;

    // Telemetry: remember the reason for -diagnosticsSnapshot. The immutable
    // copy is taken outside the lock (a no-op retain for the immutable strings
    // callers pass), and the previous string is released outside the lock so
    // the hold is a single pointer swap.
    NSString *reasonCopy = [reason copy] ?: @"unknown";
    {
        NSString *previousReason;
        os_unfair_lock_lock(&_telemetryLock);
        previousReason = _tmLastFailOpenReason;
        _tmLastFailOpenReason = reasonCopy;
        os_unfair_lock_unlock(&_telemetryLock);
        (void)previousReason;   // released here, after the unlock
    }

    if (n <= 3 || (n % kVGGreenScreenFilterLogInterval) == 0) {
        NSLog(@"[VGGreenScreenFilterNode] IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_FAIL_OPEN "
               "reason=%@ failOpenCount=%llu frame=%llu — returning input unchanged",
              reason, (unsigned long long)n,
              (unsigned long long)atomic_load(&_frameCounter));
    }
    CVPixelBufferRetain(input);
    return input;
}

// ─── Matte: synchronous Vision person segmentation (FAST) ─────────────────────
//
// Stateless per frame: a fresh request and a fresh handler, both locals of this
// call, so nothing Vision-side survives between frames and nothing outlives the
// call (the handler's reference to the input ends when this method returns).
// No orientation is passed — the camera source already oriented/mirrored the
// frame, so the matte keeps the buffer's own orientation and lines up 1:1.
// Returns the observation (ARC-owned; keeps its pixelBuffer alive) or nil.
- (nullable VNPixelBufferObservation *)_personMatteObservationForBuffer:(CVPixelBufferRef)input
                                                                  error:(NSError * _Nullable * _Nullable)outError {
    VNGeneratePersonSegmentationRequest *request =
        [[VNGeneratePersonSegmentationRequest alloc] init];
    request.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelFast;
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8;   // 255 = person
    request.preferBackgroundProcessing = NO;

    VNImageRequestHandler *handler =
        [[VNImageRequestHandler alloc] initWithCVPixelBuffer:input options:@{}];
    NSError *error = nil;
    if (![handler performRequests:@[request] error:&error]) {
        if (outError) *outError = error;
        return nil;
    }
    VNPixelBufferObservation *observation = request.results.firstObject;
    if (![observation isKindOfClass:[VNPixelBufferObservation class]] || !observation.pixelBuffer) {
        return nil;
    }
    return observation;
}

// ─── VanguardFilterNode: processBuffer:atTime:device: ────────────────────────

- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)time
                           device:(id<MTLDevice>)dev {
    // Passthrough: disabled or invalidated (no buffer ops beyond the +1).
    if (!_enabled || atomic_load(&_invalidated)) {
        CVPixelBufferRetain(input);
        return input;
    }

    const uint64_t frameIndex = atomic_fetch_add(&_frameCounter, 1) + 1;
    const BOOL shouldLog = (frameIndex <= 3) || (frameIndex % kVGGreenScreenFilterLogInterval) == 0;

    if (_matteSource != VGGreenScreenFilterNodeMatteSourceVisionPersonFast) {
        BOOL expected = NO;
        if (atomic_compare_exchange_strong(&_loggedUnavailable, &expected, YES)) {
            NSLog(@"[VGGreenScreenFilterNode] IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_PROOF_UNAVAILABLE "
                   "reason=vision_person_segmentation_requires_ios15 — passthrough for the node's "
                   "lifetime; no keying is performed and nothing is proven on this system");
        }
        CVPixelBufferRetain(input);
        return input;
    }
    if (!_pool) {
        return [self _failOpenWithInput:input reason:@"pool_null"];
    }

    const size_t srcW = CVPixelBufferGetWidth(input);
    const size_t srcH = CVPixelBufferGetHeight(input);
    if (srcW == 0 || srcH == 0) {
        return [self _failOpenWithInput:input reason:@"zero_dimension_input"];
    }

    const CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();

    // ── 1. Person matte (synchronous Vision FAST) ─────────────────────────
    VNPixelBufferObservation *observation = nil;   // kept alive until render completes
    CVPixelBufferRef matteBuffer = NULL;
    size_t matteW = 0, matteH = 0;
    if (@available(iOS 15.0, *)) {
        NSError *visionError = nil;
        observation = [self _personMatteObservationForBuffer:input error:&visionError];
        if (!observation) {
            return [self _failOpenWithInput:input
                                     reason:[NSString stringWithFormat:@"vision_no_matte(%@)",
                                             visionError.localizedDescription ?: @"no_observation"]];
        }
        matteBuffer = observation.pixelBuffer;
        matteW = CVPixelBufferGetWidth(matteBuffer);
        matteH = CVPixelBufferGetHeight(matteBuffer);
        if (CVPixelBufferGetPixelFormatType(matteBuffer) != kCVPixelFormatType_OneComponent8 ||
            matteW == 0 || matteH == 0) {
            return [self _failOpenWithInput:input reason:@"vision_matte_format_unsupported"];
        }
    } else {
        // Unreachable: _matteSource is Unavailable below iOS 15 (guarded above).
        return [self _failOpenWithInput:input reason:@"vision_unavailable"];
    }
    const CFAbsoluteTime t1 = CFAbsoluteTimeGetCurrent();

    // ── 2. CIImages: foreground (input) + matte scaled to the frame extent ─
    CIImage *foreground = [CIImage imageWithCVPixelBuffer:input];
    CIImage *matte      = [CIImage imageWithCVPixelBuffer:matteBuffer];
    if (!foreground || !matte) {
        return [self _failOpenWithInput:input reason:@"ciimage_wrap_failed"];
    }
    const CGRect srcBounds = CGRectMake(0, 0, (CGFloat)srcW, (CGFloat)srcH);
    if (matteW != srcW || matteH != srcH) {
        matte = [matte imageByApplyingTransform:
                 CGAffineTransformMakeScale((CGFloat)srcW / (CGFloat)matteW,
                                            (CGFloat)srcH / (CGFloat)matteH)];
    }

    // ── 3. Live matte refinement (VGMatteRefinementPipeline live path) ─────
    //   Refines the scaled matte through the node-owned pipeline (tracking
    //   production default .s4SoftAlphaR2; explicit S1 fallback exists elsewhere).
    //   Each stage fails open inside the pipeline. A nil result or mask
    //   (never expected from the bridge) fails the frame open.
    BOOL morphologyCloseApplied = NO, featherApplied = NO;
    BOOL trimapApplied = NO, guidedEdgeApplied = NO;
    VGMatteRefinementLiveResult *refinement =
        [_mattePipeline refineLiveGreenScreenMaskWithAspectFilledMask:matte
                                                               inRect:srcBounds
                                                             guidedBy:foreground];
    CIImage *refined = refinement.mask;
    if (!refinement || !refined) {
        return [self _failOpenWithInput:input reason:@"matte_refinement_failed"];
    }
    morphologyCloseApplied = refinement.morphologyCloseApplied;
    featherApplied         = refinement.featherApplied;
    trimapApplied          = refinement.trimapApplied;
    guidedEdgeApplied      = refinement.guidedEdgeApplied;
    NSString *liveMatteRefinementMode = refinement.liveMatteRefinementMode;
    BOOL s4GuidedAlphaApplied         = refinement.s4GuidedAlphaApplied;
    BOOL s4GuidedAlphaR1Applied       = refinement.s4GuidedAlphaR1Applied;
    BOOL tightAlphaR1Applied          = refinement.tightAlphaR1Applied;

    // ── 3b. Composite state snapshot + subject transform ──────────────────
    //   One lock-read per frame (pointer + scalar copies; nothing allocated
    //   while locked). The refined matte and the foreground get the SAME
    //   affine transform so the key can never slip against the subject;
    //   refinement already ran at source scale, so matte quality is unchanged.
    os_unfair_lock_lock(&_stateLock);
    const VGGreenScreenFilterNodeOutputMode mode = _outputMode;
    VGGreenScreenBackgroundProvider *provider = _backgroundProvider;
    const VGGreenScreenForegroundTransform subjectTransform = _foregroundTransform;
    os_unfair_lock_unlock(&_stateLock);
    if (!VGGreenScreenForegroundTransformIsIdentity(subjectTransform)) {
        const CGAffineTransform subject = _VGGSFNSubjectTransform(subjectTransform, srcBounds);
        foreground = [foreground imageByApplyingTransform:subject];
        refined    = [refined imageByApplyingTransform:subject];
    }

    // ── 4. Output stage by outputMode ─────────────────────────────────────
    CIImage *keyed = nil;
    if (mode == VGGreenScreenFilterNodeOutputModeAlpha) {
        //   alpha: (fg.rgb, refined matte) — straight alpha, no background.
        //   Fails open to the input on any filter failure (see helper).
        NSString *alphaFailReason = nil;
        keyed = _VGGSFNStraightAlphaKeyedImage(foreground, refined, srcBounds, &alphaFailReason);
        if (!keyed) {
            return [self _failOpenWithInput:input reason:alphaFailReason ?: @"alpha_output_failed"];
        }
    } else {
        //   solidColor / imageFile: CIBlendWithMask (the MVP blend, unchanged)
        //   inputImage           = foreground (camera)
        //   inputBackgroundImage = the provider's canvas-sized background
        //                          (solid colour, or the still image rendered
        //                          once per canvas size)
        //   inputMaskImage       = refined matte (255/white = subject → foreground)
        CIImage *background = provider
            ? [provider canvasImageForWidth:srcW height:srcH device:_device]
            : nil;
        if (!background) {
            return [self _failOpenWithInput:input reason:@"background_unavailable"];
        }
        CIFilter *blend = [CIFilter filterWithName:@"CIBlendWithMask"];
        if (!blend) {
            return [self _failOpenWithInput:input reason:@"blend_filter_unavailable"];
        }
        [blend setValue:foreground forKey:kCIInputImageKey];
        [blend setValue:background forKey:kCIInputBackgroundImageKey];
        [blend setValue:refined    forKey:kCIInputMaskImageKey];
        keyed = blend.outputImage;
        if (!keyed) {
            return [self _failOpenWithInput:input reason:@"blend_nil_output"];
        }
        keyed = [keyed imageByCroppingToRect:srcBounds];
    }

    // ── 5. Output buffer from the session pool ────────────────────────────
    CVPixelBufferRef output = NULL;
    CVReturn rv = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &output);
    if (rv != kCVReturnSuccess || !output) {
        return [self _failOpenWithInput:input
                                 reason:[NSString stringWithFormat:@"pool_alloc_failed(%d)", (int)rv]];
    }
    if (CVPixelBufferGetWidth(output) != srcW || CVPixelBufferGetHeight(output) != srcH) {
        BOOL expected = NO;
        if (atomic_compare_exchange_strong(&_loggedPoolMismatch, &expected, YES)) {
            NSLog(@"[VGGreenScreenFilterNode] pool buffer %zux%zu does not match frame %zux%zu "
                   "— fail open (logged once)",
                  CVPixelBufferGetWidth(output), CVPixelBufferGetHeight(output), srcW, srcH);
        }
        CVPixelBufferRelease(output);
        return [self _failOpenWithInput:input reason:@"pool_dimension_mismatch"];
    }

    // ── 6. Render (NULL colour space: raw bytes, no colour matching) ──────
    //   alpha: the un-premultiplied context (straight bytes); fails open if
    //   that context is unavailable rather than emitting premultiplied bytes.
    //   solidColor / imageFile: the shared context, unchanged.
    if (mode == VGGreenScreenFilterNodeOutputModeAlpha) {
        if (!_VGGSFNRenderStraightAlpha(_device, keyed, output, srcBounds)) {
            CVPixelBufferRelease(output);
            return [self _failOpenWithInput:input reason:@"alpha_straight_context_unavailable"];
        }
    } else {
        [_VGGSFNSharedCIContext(_device) render:keyed
                                toCVPixelBuffer:output
                                         bounds:srcBounds
                                     colorSpace:NULL];
    }
    const CFAbsoluteTime t2 = CFAbsoluteTimeGetCurrent();
    const double visionMs      = (t1 - t0) * 1000.0;
    const double blendRenderMs = (t2 - t1) * 1000.0;
    const double totalMs       = (t2 - t0) * 1000.0;
    const BOOL allS1StagesApplied =
        morphologyCloseApplied && featherApplied && trimapApplied && guidedEdgeApplied;

    // ── 7. Telemetry (keyed frames only; scalar stores under a tiny lock) ─
    //   Reached only after a successful render, so fail-open frames never
    //   count as processed and never enter the latency averages.
    NSString *liveMatteRefinementModeCopy = [liveMatteRefinementMode copy] ?: @"unknown";
    NSString *previousLiveMatteRefinementMode;
    os_unfair_lock_lock(&_telemetryLock);
    _tmProcessedFrameCount += 1;
    if (allS1StagesApplied) _tmAllS1StagesAppliedFrameCount += 1;
    _tmLastSourceWidth  = srcW;
    _tmLastSourceHeight = srcH;
    _tmLastMatteWidth   = matteW;
    _tmLastMatteHeight  = matteH;
    _tmLastMorphologyCloseApplied = morphologyCloseApplied;
    _tmLastFeatherApplied         = featherApplied;
    _tmLastTrimapApplied          = trimapApplied;
    _tmLastGuidedEdgeApplied      = guidedEdgeApplied;
    previousLiveMatteRefinementMode = _tmLastLiveMatteRefinementMode;
    _tmLastLiveMatteRefinementMode  = liveMatteRefinementModeCopy;
    _tmLastS4GuidedAlphaApplied     = s4GuidedAlphaApplied;
    if (s4GuidedAlphaApplied) _tmS4GuidedAlphaAppliedFrameCount += 1;
    _tmLastS4GuidedAlphaR1Applied   = s4GuidedAlphaR1Applied;
    _tmLastTightAlphaR1Applied      = tightAlphaR1Applied;
    _tmLastVisionMs = visionMs;
    _tmSumVisionMs += visionMs;
    if (visionMs > _tmMaxVisionMs) _tmMaxVisionMs = visionMs;
    _tmLastBlendRenderMs = blendRenderMs;
    _tmSumBlendRenderMs += blendRenderMs;
    if (blendRenderMs > _tmMaxBlendRenderMs) _tmMaxBlendRenderMs = blendRenderMs;
    _tmLastTotalMs = totalMs;
    _tmSumTotalMs += totalMs;
    if (totalMs > _tmMaxTotalMs) _tmMaxTotalMs = totalMs;
    os_unfair_lock_unlock(&_telemetryLock);
    (void)previousLiveMatteRefinementMode;   // released here, after the unlock

    if (shouldLog) {
        NSLog(@"[VGGreenScreenFilterNode] IOS_CAMERA_GRAPH_GREENSCREEN_FILTER_FRAME frame=%llu "
               "src=%zux%zu matte=%zux%zu matteSource=visionPersonFast "
               "edgeRefinement=%@ liveMatteRefinementMode=%@ "
               "outputMode=%@ "
               "morphologyCloseApplied=%d featherApplied=%d trimapApplied=%d "
               "guidedEdgeApplied=%d liveS4GuidedAlphaApplied=%d "
               "liveS4GuidedAlphaR1Applied=%d liveTightAlphaR1Applied=%d "
               "visionMs=%.1f blendRenderMs=%.1f totalMs=%.1f "
               "pts=%.3f failOpenCount=%llu",
              (unsigned long long)frameIndex, srcW, srcH, matteW, matteH,
              liveMatteRefinementMode, liveMatteRefinementMode,
              _VGGSFNOutputModeName(mode),
              (int)morphologyCloseApplied, (int)featherApplied, (int)trimapApplied,
              (int)guidedEdgeApplied, (int)s4GuidedAlphaApplied,
              (int)s4GuidedAlphaR1Applied, (int)tightAlphaR1Applied,
              visionMs, blendRenderMs, totalMs,
              CMTimeGetSeconds(time),
              (unsigned long long)atomic_load(&_failOpenCounter));
    }
    (void)observation;   // lifetime: must outlive the render above
    return output;
}

// ─── VGMetalFilterNode: processEnvelope:device: ──────────────────────────────
//
// Contract (DEC-44): VGFrameEnvelope is a struct — taken and returned BY VALUE.
// Do NOT release envelope.payload.videoBuffer — the runtime owns it.

- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                             device:(id<MTLDevice>)device {
    if (!_enabled || atomic_load(&_invalidated)) {
        return envelope; // passthrough — no buffer ops
    }

    CVPixelBufferRef input = (CVPixelBufferRef)envelope.payload.videoBuffer;
    if (!input) return envelope;

    CVPixelBufferRef output = [self processBuffer:input
                                           atTime:envelope.pts
                                           device:device];

    if (output == input) {
        CVPixelBufferRelease(output); // release the extra +1 from the passthrough path
        return envelope;
    }

    if (!output) {
        VGFrameEnvelope failed = envelope;
        failed.payload.videoBuffer = NULL;
        return failed;
    }

    VGFrameEnvelope out = envelope;
    out.payload.videoBuffer = output;
    return out;
}

// ─── Diagnostics: read-only telemetry snapshot ────────────────────────────────
//
// Copies every guarded field out under _telemetryLock (scalar loads plus one
// retain of the reason string — no allocation while locked), then builds the
// dictionary outside the lock. Configuration fields are immutable after init
// and the frame / fail-open counters are atomics, so they need no lock.
// Callable from any thread; changes nothing.

- (NSDictionary<NSString *, id> *)diagnosticsSnapshot {
    // Composite state (background / transform) under its own lock first.
    os_unfair_lock_lock(&_stateLock);
    const VGGreenScreenFilterNodeOutputMode mode = _outputMode;
    const uint32_t backgroundARGB = _backgroundARGB;
    VGGreenScreenBackgroundProvider *provider = _backgroundProvider;
    const VGGreenScreenForegroundTransform transform = _foregroundTransform;
    const uint64_t backgroundUpdates = _backgroundHotUpdateCount;
    const uint64_t transformUpdates  = _transformHotUpdateCount;
    os_unfair_lock_unlock(&_stateLock);
    const BOOL imageMode = (mode == VGGreenScreenFilterNodeOutputModeImageFile);

    os_unfair_lock_lock(&_telemetryLock);
    const uint64_t processed      = _tmProcessedFrameCount;
    const uint64_t allS1Frames    = _tmAllS1StagesAppliedFrameCount;
    const size_t   sourceWidth    = _tmLastSourceWidth;
    const size_t   sourceHeight   = _tmLastSourceHeight;
    const size_t   matteWidth     = _tmLastMatteWidth;
    const size_t   matteHeight    = _tmLastMatteHeight;
    const BOOL     closeApplied   = _tmLastMorphologyCloseApplied;
    const BOOL     featherApplied = _tmLastFeatherApplied;
    const BOOL     trimapApplied  = _tmLastTrimapApplied;
    const BOOL     guidedApplied  = _tmLastGuidedEdgeApplied;
    NSString *liveMatteRefinementMode  = _tmLastLiveMatteRefinementMode;
    const BOOL     s4GuidedAlphaApplied         = _tmLastS4GuidedAlphaApplied;
    const uint64_t s4GuidedAlphaAppliedFrames   = _tmS4GuidedAlphaAppliedFrameCount;
    const BOOL     s4GuidedAlphaR1Applied       = _tmLastS4GuidedAlphaR1Applied;
    const BOOL     tightAlphaR1Applied          = _tmLastTightAlphaR1Applied;
    const double   lastVision     = _tmLastVisionMs;
    const double   sumVision      = _tmSumVisionMs;
    const double   maxVision      = _tmMaxVisionMs;
    const double   lastBlend      = _tmLastBlendRenderMs;
    const double   sumBlend       = _tmSumBlendRenderMs;
    const double   maxBlend       = _tmMaxBlendRenderMs;
    const double   lastTotal      = _tmLastTotalMs;
    const double   sumTotal       = _tmSumTotalMs;
    const double   maxTotal       = _tmMaxTotalMs;
    NSString *lastFailOpenReason  = _tmLastFailOpenReason;
    os_unfair_lock_unlock(&_telemetryLock);

    const BOOL allS1Last = closeApplied && featherApplied && trimapApplied && guidedApplied;
    const double meanVision = processed > 0 ? sumVision / (double)processed : 0.0;
    const double meanBlend  = processed > 0 ? sumBlend  / (double)processed : 0.0;
    const double meanTotal  = processed > 0 ? sumTotal  / (double)processed : 0.0;

    return @{
        @"nodeId":                       _nodeId,
        @"filterName":                   _filterName,
        @"enabled":                      _enabled ? @YES : @NO,
        @"matteSource":                  (_matteSource == VGGreenScreenFilterNodeMatteSourceVisionPersonFast)
                                             ? @"visionPersonFast" : @"unavailable",
        // The actual live mode/proof (production default "s4SoftAlphaR2", built on the S1
        // base stages below), not a stale "S1" claim. "unknown" until the first keyed frame.
        @"proofLevel":                   liveMatteRefinementMode ?: @"unknown",
        @"edgeRefinement":               liveMatteRefinementMode ?: @"unknown",
        @"liveMatteRefinementMode":      liveMatteRefinementMode ?: @"unknown",
        @"outputMode":                   _VGGSFNOutputModeName(mode),
        @"backgroundType":               _VGGSFNOutputModeName(mode),
        @"backgroundImagePath":          (imageMode ? (provider.imagePath ?: @"") : @""),
        @"backgroundScaleMode":          (imageMode ? VGGreenScreenBackgroundScaleModeName(provider.scaleMode) : @""),
        @"backgroundImageWidth":         @(imageMode ? provider.imageWidth  : 0),
        @"backgroundImageHeight":        @(imageMode ? provider.imageHeight : 0),
        @"foregroundScale":              @((double)transform.scale),
        @"foregroundOffsetX":            @((double)transform.offsetX),
        @"foregroundOffsetY":            @((double)transform.offsetY),
        @"foregroundTransformIdentity":  VGGreenScreenForegroundTransformIsIdentity(transform) ? @YES : @NO,
        @"backgroundHotUpdateCount":     @(backgroundUpdates),
        @"transformHotUpdateCount":      @(transformUpdates),
        // "opaque" = A is 255 (solidColor). Alpha mode: "straight" (RGB not
        // premultiplied by A) ONLY when the one-time byte self-test below
        // passed through the alpha render path, else "unverified". The
        // alphaByteSelfTest* fields are that MEASUREMENT (immutable after
        // init, no lock needed).
        @"alphaEncoding":                _VGGSFNAlphaEncodingName(mode, _alphaByteSelfTestPassed),
        @"alphaByteSelfTestPassed":      _alphaByteSelfTestPassed ? @YES : @NO,
        @"alphaByteSelfTestReason":      _alphaByteSelfTestReason ?: @"unknown",
        @"alphaByteSelfTestWidth":       @(_alphaByteSelfTestWidth),
        @"alphaByteSelfTestHeight":      @(_alphaByteSelfTestHeight),
        @"backgroundARGB":               @(backgroundARGB),
        @"frameCount":                   @(atomic_load(&_frameCounter)),
        @"processedFrameCount":          @(processed),
        @"failOpenCount":                @(atomic_load(&_failOpenCounter)),
        @"lastFailOpenReason":           lastFailOpenReason ?: @"none",
        @"sourceWidth":                  @(sourceWidth),
        @"sourceHeight":                 @(sourceHeight),
        @"matteWidth":                   @(matteWidth),
        @"matteHeight":                  @(matteHeight),
        @"morphologyCloseApplied":       closeApplied   ? @YES : @NO,
        @"featherApplied":               featherApplied ? @YES : @NO,
        @"trimapApplied":                trimapApplied  ? @YES : @NO,
        @"guidedEdgeApplied":            guidedApplied  ? @YES : @NO,
        @"allS1StagesApplied":           allS1Last      ? @YES : @NO,
        @"allS1StagesAppliedFrameCount": @(allS1Frames),
        @"liveS4GuidedAlphaApplied":            s4GuidedAlphaApplied   ? @YES : @NO,
        @"liveS4GuidedAlphaAppliedFrameCount":  @(s4GuidedAlphaAppliedFrames),
        @"liveS4GuidedAlphaR1Applied":          s4GuidedAlphaR1Applied ? @YES : @NO,
        @"liveTightAlphaR1Applied":             tightAlphaR1Applied    ? @YES : @NO,
        @"lastVisionMs":                 @(lastVision),
        @"meanVisionMs":                 @(meanVision),
        @"maxVisionMs":                  @(maxVision),
        @"lastBlendRenderMs":            @(lastBlend),
        @"meanBlendRenderMs":            @(meanBlend),
        @"maxBlendRenderMs":             @(maxBlend),
        @"lastTotalMs":                  @(lastTotal),
        @"meanTotalMs":                  @(meanTotal),
        @"maxTotalMs":                   @(maxTotal),
    };
}

@end
