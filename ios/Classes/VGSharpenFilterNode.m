// VGSharpenFilterNode.m
// vanguard_media_engine — Phase 10-D
//
// CIUnsharpMask post-resize sharpening filter node for still-image derivative export.
//
// Processing contract:
//   processBuffer:atTime:device:
//     1. If enabled=NO: CVPixelBufferRetain(input); return input.
//     2. Apply CIUnsharpMask to input at current (post-resize) resolution.
//     3. Render CIImage result to a new CVPixelBuffer (same dimensions).
//     4. If CIFilter or render fails: log + CVPixelBufferRetain(input); return input.
//     5. Return new +1 CVPixelBuffer (caller releases it).
//
//   processEnvelope:device:
//     Wraps processBuffer:atTime:device: per DEC-44:
//     - Takes/returns VGFrameEnvelope by VALUE (struct, not pointer).
//     - Does NOT release envelope.payload.videoBuffer — runtime owns it.
//     - On passthrough: returns input envelope unchanged.
//     - On success: copies envelope metadata, sets out.payload.videoBuffer.
//     - On failure: returns envelope with payload.videoBuffer = NULL.
//
// CIContext: file-static, Metal-backed, created once via dispatch_once.
// kCIContextCacheIntermediates = @NO — reduces peak memory for one-shot export.
// This context is NOT the VGTransformFilterNode or VGDenoiseFilterNode context —
// each node class owns its own static context per the Opus correction.
//
// Buffer allocation: CVPixelBufferCreate for one-shot export (pool=nil path).
// The output buffer always matches the input (post-resize) dimensions.
//
// Failure-safe: any CIFilter or rendering failure → passthrough + log.
// Export continues with the resized-but-not-sharpened derivative.
//
// Phase 10-D — derivative-only. Master export path is never invoked.

#import "VGSharpenFilterNode.h"
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>

// ─── Shared CIContext ─────────────────────────────────────────────────────────
//
// Separate from VGTransformFilterNode._VGTFNSharedCIContext and
// VGDenoiseFilterNode._VGDFNSharedCIContext (all file-static).
// Per Opus correction: each node class defines its own static context.
// Metal-backed. kCIContextCacheIntermediates=NO for one-shot export.

static CIContext *_VGSFNSharedCIContext(void) {
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

// ─── VGSharpenFilterNode Implementation ──────────────────────────────────────

@implementation VGSharpenFilterNode {
    CVPixelBufferPoolRef _pool;       // nullable; nil = one-shot export allocation
    id<MTLDevice>        _device;
    double               _intensity;  // clamped to [0.0, 0.50]
    double               _radius;     // clamped to [0.0, 1.5]
}

@synthesize filterName = _filterName;
@synthesize enabled    = _enabled;
@synthesize nodeId     = _nodeId;
@synthesize nodeType   = _nodeType;

// ─── VGMetalFilterNode cost model ────────────────────────────────────────────

- (BOOL)isExpensive {
    // CIUnsharpMask at post-resize resolution is cheap (~1–3ms).
    // Do NOT disable under thermal pressure — cheaper than transform node.
    return NO;
}

- (float)estimatedGPUCostMs {
    // Conservative estimate: ~3ms on A14 at post-resize resolution (e.g. 1080×810).
    return 3.0f;
}

// ─── VGNode lifecycle stubs ───────────────────────────────────────────────────

- (void)prepareWithCompletion:(void (^)(NSError * _Nullable))completion {
    // No async work. Succeed immediately.
    if (completion) completion(nil);
}

- (void)invalidate {
    // One-shot: no retained resources beyond the CIContext (which is static).
}

// ─── Designated initialiser ───────────────────────────────────────────────────

- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
                   intensity:(double)intensity
                      radius:(double)radius {
    self = [super init];
    if (!self) return nil;

    _pool      = pool ? (CVPixelBufferPoolRef)CFRetain(pool) : NULL;
    _device    = device;
    // Clamp to safe UMF contract ranges.
    _intensity = MAX(0.0, MIN(0.50, intensity));
    _radius    = MAX(0.0, MIN(1.5,  radius));
    _enabled   = YES;

    _nodeId     = [[NSUUID UUID] UUIDString];
    _nodeType   = @"VGSharpenFilterNode";
    _filterName = @"Sharpen";

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
                           device:(id<MTLDevice>)device {
    // Passthrough path — enabled=NO.
    if (!_enabled) {
        CVPixelBufferRetain(inputBuffer);
        return inputBuffer;
    }

    const size_t srcW = CVPixelBufferGetWidth(inputBuffer);
    const size_t srcH = CVPixelBufferGetHeight(inputBuffer);

    // Build CIImage from the input (post-resize) buffer.
    CIImage *sourceCI = [CIImage imageWithCVPixelBuffer:inputBuffer];
    if (!sourceCI) {
        NSLog(@"[VGSharpenFilterNode] CIImage from CVPixelBuffer failed — passthrough");
        CVPixelBufferRetain(inputBuffer);
        return inputBuffer;
    }

    // Apply CIUnsharpMask.
    CIFilter *filter = [CIFilter filterWithName:@"CIUnsharpMask"];
    if (!filter) {
        NSLog(@"[VGSharpenFilterNode] CIUnsharpMask filter unavailable — passthrough");
        CVPixelBufferRetain(inputBuffer);
        return inputBuffer;
    }
    [filter setValue:sourceCI      forKey:kCIInputImageKey];
    [filter setValue:@(_intensity) forKey:@"inputIntensity"];
    [filter setValue:@(_radius)    forKey:@"inputRadius"];

    CIImage *outputCI = filter.outputImage;
    if (!outputCI) {
        NSLog(@"[VGSharpenFilterNode] CIUnsharpMask returned nil — passthrough");
        CVPixelBufferRetain(inputBuffer);
        return inputBuffer;
    }

    // Allocate output CVPixelBuffer matching (post-resize) input dimensions.
    CVPixelBufferRef outputBuffer = NULL;

    if (_pool) {
        CVReturn rv = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                         _pool,
                                                         &outputBuffer);
        if (rv != kCVReturnSuccess || !outputBuffer) {
            NSLog(@"[VGSharpenFilterNode] pool alloc failed (%d) — passthrough", rv);
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
            NSLog(@"[VGSharpenFilterNode] CVPixelBufferCreate failed (%d) — passthrough", rv);
            CVPixelBufferRetain(inputBuffer);
            return inputBuffer;
        }
    }

    // Render CIImage into the output buffer.
    // Phase 10-D fix: pass an explicit DeviceRGB color space so Core Image
    // converts from its linear working space back to the sRGB/DeviceRGB
    // destination format. Passing nil left intermediate buffers in linear
    // space, causing gamma double-application and severe tone collapse in
    // downstream nodes. Matches the pattern used in VGTransformFilterNode.m.
    CIContext *ctx = _VGSFNSharedCIContext();
    CGRect renderRect = CGRectMake(0, 0, (CGFloat)srcW, (CGFloat)srcH);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [ctx render:outputCI toCVPixelBuffer:outputBuffer bounds:renderRect colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);

    NSLog(@"[VGSharpenFilterNode] applied: %zux%zu intensity=%.2f radius=%.2f",
          srcW, srcH, _intensity, _radius);

    // outputBuffer is +1 (CVPixelBufferCreate / pool alloc). Caller releases.
    return outputBuffer;
}

// ─── VGMetalFilterNode: processEnvelope:device: ──────────────────────────────
//
// Contract (DEC-44):
//   - VGFrameEnvelope is a struct — taken and returned BY VALUE.
//   - Do NOT release envelope.payload.videoBuffer — runtime owns it.
//   - Passthrough: return input envelope unchanged.
//   - Success: copy envelope, replace payload.videoBuffer with new buffer.
//   - Failure: return envelope with payload.videoBuffer = NULL.

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

    // Copy all metadata unchanged (DEC-44), replace buffer pointer.
    VGFrameEnvelope out = envelope;
    out.payload.videoBuffer = output; // runtime releases after downstream delivery
    return out;
}

@end
