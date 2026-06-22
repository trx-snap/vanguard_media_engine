// VGDenoiseFilterNode.m
// vanguard_media_engine — Phase 10-D
//
// CINoiseReduction denoise filter node for still-image derivative export.
//
// Processing contract:
//   processBuffer:atTime:device:
//     1. If enabled=NO: CVPixelBufferRetain(input); return input.
//     2. Apply CINoiseReduction to input at full source resolution.
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
// This context is NOT the VGTransformFilterNode context — each node class
// owns its own static context per the Opus correction.
//
// Buffer allocation: CVPixelBufferCreate for one-shot export (pool=nil path).
// The output buffer always matches the input dimensions; no resize is performed.
//
// Failure-safe: any CIFilter or rendering failure → passthrough + log.
// Export continues on the baseline resize/compress path.
//
// Phase 10-D — derivative-only. Master export path is never invoked.

#import "VGDenoiseFilterNode.h"
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>

// ─── Shared CIContext ─────────────────────────────────────────────────────────
//
// Separate from VGTransformFilterNode._VGTFNSharedCIContext (file-static there).
// Per Opus correction: each node class defines its own static context.
// Metal-backed. kCIContextCacheIntermediates=NO for one-shot export.

static CIContext *_VGDFNSharedCIContext(void) {
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

// ─── VGDenoiseFilterNode Implementation ──────────────────────────────────────

@implementation VGDenoiseFilterNode {
    CVPixelBufferPoolRef _pool;   // nullable; nil = one-shot export allocation
    id<MTLDevice>        _device;
    double               _noiseLevel;  // clamped to [0.0, 0.06]
    double               _sharpness;   // clamped to [0.0, 1.0]
}

@synthesize filterName = _filterName;
@synthesize enabled    = _enabled;
@synthesize nodeId     = _nodeId;
@synthesize nodeType   = _nodeType;

// ─── VGMetalFilterNode cost model ────────────────────────────────────────────

- (BOOL)isExpensive {
    // CINoiseReduction at source resolution is moderate-expensive.
    // Mark YES so thermal manager can disable it under Serious pressure.
    return YES;
}

- (float)estimatedGPUCostMs {
    // Conservative estimate: ~15ms on A14 at source resolution (e.g. 5712×4284).
    return 15.0f;
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
                  noiseLevel:(double)noiseLevel
                   sharpness:(double)sharpness {
    self = [super init];
    if (!self) return nil;

    _pool       = pool ? (CVPixelBufferPoolRef)CFRetain(pool) : NULL;
    _device     = device;
    // Clamp to safe UMF contract ranges.
    _noiseLevel = MAX(0.0, MIN(0.06, noiseLevel));
    _sharpness  = MAX(0.0, MIN(1.0,  sharpness));
    _enabled    = YES;

    _nodeId     = [[NSUUID UUID] UUIDString];
    _nodeType   = @"VGDenoiseFilterNode";
    _filterName = @"Denoise";

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

    // Build CIImage from the input buffer.
    CIImage *sourceCI = [CIImage imageWithCVPixelBuffer:inputBuffer];
    if (!sourceCI) {
        NSLog(@"[VGDenoiseFilterNode] CIImage from CVPixelBuffer failed — passthrough");
        CVPixelBufferRetain(inputBuffer);
        return inputBuffer;
    }

    // Apply CINoiseReduction.
    CIFilter *filter = [CIFilter filterWithName:@"CINoiseReduction"];
    if (!filter) {
        NSLog(@"[VGDenoiseFilterNode] CINoiseReduction filter unavailable — passthrough");
        CVPixelBufferRetain(inputBuffer);
        return inputBuffer;
    }
    [filter setValue:sourceCI   forKey:kCIInputImageKey];
    [filter setValue:@(_noiseLevel) forKey:@"inputNoiseLevel"];
    [filter setValue:@(_sharpness)  forKey:@"inputSharpness"];

    CIImage *outputCI = filter.outputImage;
    if (!outputCI) {
        NSLog(@"[VGDenoiseFilterNode] CINoiseReduction returned nil — passthrough");
        CVPixelBufferRetain(inputBuffer);
        return inputBuffer;
    }

    // Allocate output CVPixelBuffer matching input dimensions.
    CVPixelBufferRef outputBuffer = NULL;

    if (_pool) {
        CVReturn rv = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                         _pool,
                                                         &outputBuffer);
        if (rv != kCVReturnSuccess || !outputBuffer) {
            NSLog(@"[VGDenoiseFilterNode] pool alloc failed (%d) — passthrough", rv);
            CVPixelBufferRetain(inputBuffer);
            return inputBuffer;
        }
    } else {
        // Standalone allocation matching input pixel format.
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
            NSLog(@"[VGDenoiseFilterNode] CVPixelBufferCreate failed (%d) — passthrough", rv);
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
    CIContext *ctx = _VGDFNSharedCIContext();
    CGRect renderRect = CGRectMake(0, 0, (CGFloat)srcW, (CGFloat)srcH);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [ctx render:outputCI toCVPixelBuffer:outputBuffer bounds:renderRect colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);

    NSLog(@"[VGDenoiseFilterNode] applied: %zux%zu noiseLevel=%.3f sharpness=%.2f",
          srcW, srcH, _noiseLevel, _sharpness);

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
