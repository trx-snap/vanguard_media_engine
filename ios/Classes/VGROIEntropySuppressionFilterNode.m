// VGROIEntropySuppressionFilterNode.m
// vanguard_media_engine — Phase 10-D.4A
//
// ROI-aware background entropy suppression filter node implementation.
//
// Processing contract:
//   processBuffer:atTime:device:
//     1. If enabled=NO or _maskImage=nil: CVPixelBufferRetain(input); return input.
//     2. Wrap input in CIImage.
//     3. If _sharpenROIOnly: apply CIUnsharpMask to get `foregroundCI`.
//        Otherwise: use input CIImage as `foregroundCI`.
//     4. Apply CIGaussianBlur at _backgroundBlurRadius to get `backgroundCI`.
//        If radius is 0.0: skip blur, use input as `backgroundCI`.
//     5. Apply CIBlendWithMask:
//          result = foregroundCI * mask + backgroundCI * (1 - mask)
//     6. Render result into a new CVPixelBuffer matching input dimensions.
//     7. Return new +1 CVPixelBuffer (caller releases it).
//     8. On any failure: log + CVPixelBufferRetain(input); return input.
//
// CIBlendWithMask:
//   The standard Core Image filter is CIBlendWithMask:
//     inputImage        = background layer
//     inputBackgroundImage = foreground layer (misleading Apple naming)
//     inputMaskImage    = mask (white=show background, black=show foreground)
//   CAUTION: Apple's naming is counter-intuitive. In CIBlendWithMask:
//     WHITE mask → output = inputBackgroundImage (foreground)
//     BLACK mask → output = inputImage (background)
//   So: inputImage = blurred background, inputBackgroundImage = sharp foreground.
//
// CIContext: file-static, Metal-backed, created once via dispatch_once.
//   Separate from all other node contexts.
//
// Phase 10-D.4A — derivative-only. Master export is never modified.

#import "VGROIEntropySuppressionFilterNode.h"
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>

// ─── Shared CIContext ─────────────────────────────────────────────────────────

static CIContext *_VGROIFNSharedCIContext(void) {
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

// ─── VGROIEntropySuppressionFilterNode ───────────────────────────────────────

@implementation VGROIEntropySuppressionFilterNode {
    CVPixelBufferPoolRef _pool;          // nullable; nil = one-shot export
    id<MTLDevice>        _device;
    CIImage             *_maskImage;     // nil = passthrough
    double               _bgBlurRadius;  // 0.0 = no blur
    BOOL                 _sharpenROIOnly;
    double               _sharpenIntensity; // clamped to [0.0, 0.50]
    double               _sharpenRadius;    // clamped to [0.0, 1.5]
}

@synthesize filterName = _filterName;
@synthesize enabled    = _enabled;
@synthesize nodeId     = _nodeId;
@synthesize nodeType   = _nodeType;

// ─── VGMetalFilterNode cost model ────────────────────────────────────────────

- (BOOL)isExpensive { return NO; }
- (float)estimatedGPUCostMs { return 6.0f; }

// ─── VGNode lifecycle ─────────────────────────────────────────────────────────

- (void)prepareWithCompletion:(void (^)(NSError * _Nullable))completion {
    if (completion) completion(nil);
}

- (void)invalidate {
    // No retained async resources beyond static CIContext.
}

// ─── Designated initialiser ───────────────────────────────────────────────────

- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
                   maskImage:(nullable CIImage *)maskImage
       backgroundBlurRadius:(double)backgroundBlurRadius
              sharpenROIOnly:(BOOL)sharpenROIOnly
             sharpenIntensity:(double)sharpenIntensity
               sharpenRadius:(double)sharpenRadius {
    self = [super init];
    if (!self) return nil;

    _pool            = pool ? (CVPixelBufferPoolRef)CFRetain(pool) : NULL;
    _device          = device;
    _maskImage       = maskImage;
    _bgBlurRadius    = MAX(0.0, backgroundBlurRadius);
    _sharpenROIOnly  = sharpenROIOnly;
    _sharpenIntensity = MAX(0.0, MIN(0.50, sharpenIntensity));
    _sharpenRadius    = MAX(0.0, MIN(1.5,  sharpenRadius));
    _enabled         = YES;

    _nodeId     = [[NSUUID UUID] UUIDString];
    _nodeType   = @"VGROIEntropySuppressionFilterNode";
    _filterName = @"ROIEntropySuppression";

    return self;
}

- (void)dealloc {
    if (_pool) {
        CVPixelBufferPoolRelease(_pool);
        _pool = NULL;
    }
}

// ─── VanguardFilterNode: processBuffer:atTime:device: ────────────────────────

- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)inputBuffer
                           atTime:(CMTime)time
                           device:(id<MTLDevice>)dev {
    // Passthrough: disabled or no mask.
    if (!_enabled || !_maskImage) {
        CVPixelBufferRetain(inputBuffer);
        return inputBuffer;
    }

    const size_t srcW = CVPixelBufferGetWidth(inputBuffer);
    const size_t srcH = CVPixelBufferGetHeight(inputBuffer);

    // ── 1. Wrap input in CIImage ───────────────────────────────────────────
    CIImage *sourceCI = [CIImage imageWithCVPixelBuffer:inputBuffer];
    if (!sourceCI) {
        NSLog(@"[VGROIEntropySuppressionFilterNode] CIImage wrap failed — passthrough");
        CVPixelBufferRetain(inputBuffer);
        return inputBuffer;
    }

    // ── 2. Foreground: optionally sharpen the ROI region ──────────────────
    CIImage *foregroundCI = sourceCI;
    if (_sharpenROIOnly && _sharpenIntensity > 0.0) {
        CIFilter *sharpen = [CIFilter filterWithName:@"CIUnsharpMask"];
        if (sharpen) {
            [sharpen setValue:sourceCI         forKey:kCIInputImageKey];
            [sharpen setValue:@(_sharpenIntensity) forKey:@"inputIntensity"];
            [sharpen setValue:@(_sharpenRadius)    forKey:@"inputRadius"];
            CIImage *sharpened = sharpen.outputImage;
            if (sharpened) foregroundCI = sharpened;
        }
    }

    // ── 3. Background: apply Gaussian blur to suppress entropy ─────────────
    CIImage *backgroundCI = sourceCI;
    if (_bgBlurRadius > 0.0) {
        CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
        if (blur) {
            [blur setValue:sourceCI        forKey:kCIInputImageKey];
            [blur setValue:@(_bgBlurRadius) forKey:@"inputRadius"];
            CIImage *blurred = blur.outputImage;
            if (blurred) backgroundCI = blurred;
        }
    }

    // ── 4. Blend: CIBlendWithMask ──────────────────────────────────────────
    // Apple CIBlendWithMask naming:
    //   inputImage           = layer shown where mask is BLACK (our background)
    //   inputBackgroundImage = layer shown where mask is WHITE (our foreground)
    //   inputMaskImage       = our grayscale mask (white=face, black=background)
    CIFilter *blend = [CIFilter filterWithName:@"CIBlendWithMask"];
    if (!blend) {
        NSLog(@"[VGROIEntropySuppressionFilterNode] CIBlendWithMask unavailable — passthrough");
        CVPixelBufferRetain(inputBuffer);
        return inputBuffer;
    }
    [blend setValue:backgroundCI forKey:kCIInputImageKey];
    [blend setValue:foregroundCI forKey:kCIInputBackgroundImageKey];
    [blend setValue:_maskImage   forKey:kCIInputMaskImageKey];

    CIImage *blendedCI = blend.outputImage;
    if (!blendedCI) {
        NSLog(@"[VGROIEntropySuppressionFilterNode] CIBlendWithMask nil output — passthrough");
        CVPixelBufferRetain(inputBuffer);
        return inputBuffer;
    }

    // Crop to source bounds (blur can expand the image extent).
    CGRect srcBounds = CGRectMake(0, 0, (CGFloat)srcW, (CGFloat)srcH);
    blendedCI = [blendedCI imageByCroppingToRect:srcBounds];

    // ── 5. Allocate output CVPixelBuffer ──────────────────────────────────
    CVPixelBufferRef outputBuffer = NULL;

    if (_pool) {
        CVReturn rv = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                         _pool,
                                                         &outputBuffer);
        if (rv != kCVReturnSuccess || !outputBuffer) {
            NSLog(@"[VGROIEntropySuppressionFilterNode] pool alloc failed (%d) — passthrough", rv);
            CVPixelBufferRetain(inputBuffer);
            return inputBuffer;
        }
    } else {
        OSType pixelFormat = CVPixelBufferGetPixelFormatType(inputBuffer);
        NSDictionary *attrs = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey:  @YES,
        };
        CVReturn rv = CVPixelBufferCreate(kCFAllocatorDefault,
                                          srcW, srcH,
                                          pixelFormat,
                                          (__bridge CFDictionaryRef)attrs,
                                          &outputBuffer);
        if (rv != kCVReturnSuccess || !outputBuffer) {
            NSLog(@"[VGROIEntropySuppressionFilterNode] CVPixelBufferCreate failed (%d) — passthrough", rv);
            CVPixelBufferRetain(inputBuffer);
            return inputBuffer;
        }
    }

    // ── 6. Render into output buffer ──────────────────────────────────────
    CIContext *ctx = _VGROIFNSharedCIContext();
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [ctx render:blendedCI
 toCVPixelBuffer:outputBuffer
          bounds:srcBounds
      colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);

    NSLog(@"[VGROIEntropySuppressionFilterNode] applied: %zux%zu blur=%.2f sharpenROI=%@",
          srcW, srcH, _bgBlurRadius, _sharpenROIOnly ? @"YES" : @"NO");

    return outputBuffer;
}

// ─── VGMetalFilterNode: processEnvelope:device: ──────────────────────────────
//
// Contract (DEC-44): VGFrameEnvelope is a struct — taken and returned BY VALUE.
// Do NOT release envelope.payload.videoBuffer — runtime owns it.

- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                             device:(id<MTLDevice>)device {
    if (!_enabled || !_maskImage) {
        return envelope; // passthrough — no buffer ops
    }

    CVPixelBufferRef input = (CVPixelBufferRef)envelope.payload.videoBuffer;
    if (!input) return envelope;

    CVPixelBufferRef output = [self processBuffer:input
                                           atTime:envelope.pts
                                           device:device];

    if (output == input) {
        CVPixelBufferRelease(output); // release the extra +1 from passthrough path
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

@end
