// VGColorMatrixFilterNode.m
// vanguard_media_engine — Phase 10-C-3L.1C
//
// Applies a 4×5 row-major color matrix via the `vanguard_color_matrix_apply`
// Metal compute kernel. Buffer ownership follows DEC-44 / RR-28.

#import "VGColorMatrixFilterNode.h"
#import "VGMetalLibraryResolver.h"
#import <os/lock.h>

// ─── CPU-side struct matching the Metal ColorMatrixParams struct exactly ───────
// Layout: 20 × float = 80 bytes.
// Must match `struct ColorMatrixParams` in VanguardEffects.metal exactly.
typedef struct {
    float m[20];
} _ColorMatrixParamsLayout;

@implementation VGColorMatrixFilterNode {
    CVPixelBufferPoolRef        _pool;
    id<MTLDevice>               _device;
    id<MTLCommandQueue>         _queue;
    id<MTLComputePipelineState> _pso;   // nil until first _compilePSO

    // Protected by _matrixLock
    float               _mat[20];      // current 4×5 matrix (row-major)
    os_unfair_lock      _matrixLock;
}

@synthesize filterName = _filterName;
@synthesize enabled    = _enabled;
@synthesize nodeId     = _nodeId;
@synthesize nodeType   = _nodeType;

// ─── VGMetalFilterNode cost model (P4-2) ─────────────────────────────────────

// Color matrix is an ALU-only kernel (no texture fetch beyond the input).
// Faster than LUT (2ms). Measured ~1.5ms on A14 at 1080p BGRA.
- (BOOL)isExpensive {
    return NO;
}

- (VGNodeRole)nodeRole {
    return VGNodeRoleFilter;
}

- (float)estimatedGPUCostMs {
    return 1.5f;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Init
// ─────────────────────────────────────────────────────────────────────────────

- (instancetype)initWithPool:(nullable CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device
                      matrix:(NSArray<NSNumber *> *)matrix {
    NSParameterAssert(device != nil);
    NSParameterAssert(matrix != nil && matrix.count == 20);

    self = [super init];
    if (!self) return nil;

    _pool        = pool;
    _device      = device;
    _queue       = [device newCommandQueue];
    _matrixLock  = OS_UNFAIR_LOCK_INIT;
    _enabled     = YES;
    _filterName  = @"ColorMatrix";
    _nodeId      = [[NSUUID UUID] UUIDString];
    _nodeType    = @"VGColorMatrixFilterNode";

    // Copy the initial matrix values.
    for (NSUInteger i = 0; i < 20 && i < matrix.count; i++) {
        _mat[i] = [matrix[i] floatValue];
    }

    [self _compilePSO];
    return self;
}

- (void)dealloc {
    _pso   = nil;
    _queue = nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: colorMatrix property
// ─────────────────────────────────────────────────────────────────────────────

- (NSArray<NSNumber *> *)colorMatrix {
    os_unfair_lock_lock(&_matrixLock);
    NSMutableArray<NSNumber *> *copy = [NSMutableArray arrayWithCapacity:20];
    for (int i = 0; i < 20; i++) {
        [copy addObject:@(_mat[i])];
    }
    os_unfair_lock_unlock(&_matrixLock);
    return [copy copy];
}

- (void)setColorMatrix:(NSArray<NSNumber *> *)colorMatrix {
    NSParameterAssert(colorMatrix != nil && colorMatrix.count == 20);
    os_unfair_lock_lock(&_matrixLock);
    for (NSUInteger i = 0; i < 20 && i < colorMatrix.count; i++) {
        _mat[i] = [colorMatrix[i] floatValue];
    }
    os_unfair_lock_unlock(&_matrixLock);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: VanguardFilterNode — processBuffer:atTime:device:
// ─────────────────────────────────────────────────────────────────────────────

- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)t
                           device:(id<MTLDevice>)device {
    // Passthrough: disabled or no PSO.
    if (!_enabled || !_pso) {
        CVPixelBufferRetain(input);
        return input;
    }

    // Input must be IOSurface-backed for Metal texture creation.
    IOSurfaceRef inSurface = CVPixelBufferGetIOSurface(input);
    if (!inSurface) {
        CVPixelBufferRetain(input);
        return input;
    }

    size_t w = CVPixelBufferGetWidth(input);
    size_t h = CVPixelBufferGetHeight(input);

    // ── Input texture ──────────────────────────────────────────────────────
    MTLTextureDescriptor *inDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:w
                                    height:h
                                 mipmapped:NO];
    inDesc.storageMode = MTLStorageModeShared;
    inDesc.usage       = MTLTextureUsageShaderRead;
    id<MTLTexture> inTex = [_device newTextureWithDescriptor:inDesc
                                                   iosurface:inSurface
                                                       plane:0];
    if (!inTex) {
        CVPixelBufferRetain(input);
        return input;
    }

    // ── Output buffer from pool or direct allocation ─────────────────────
    CVPixelBufferRef output = NULL;
    if (_pool) {
        if (CVPixelBufferPoolCreatePixelBuffer(nil, _pool, &output) != kCVReturnSuccess) {
            CVPixelBufferRetain(input);
            return input;
        }
    } else {
        OSType pixelFormat = CVPixelBufferGetPixelFormatType(input);
        // Ensure compatibility with standard 32-bit pixel formats
        if (pixelFormat != kCVPixelFormatType_32BGRA &&
            pixelFormat != kCVPixelFormatType_32RGBA) {
            pixelFormat = kCVPixelFormatType_32BGRA;
        }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferMetalCompatibilityKey:           @YES,
            (id)kCVPixelBufferIOSurfacePropertiesKey:          @{},
            (id)kCVPixelBufferCGImageCompatibilityKey:         @YES,
            (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        };
        CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                              w,
                                              h,
                                              pixelFormat,
                                              (__bridge CFDictionaryRef)attrs,
                                              &output);
        if (status != kCVReturnSuccess || !output) {
            CVPixelBufferRetain(input);
            return input;
        }
    }
    IOSurfaceRef outSurface = CVPixelBufferGetIOSurface(output);
    if (!outSurface) {
        CVPixelBufferRelease(output);
        CVPixelBufferRetain(input);
        return input;
    }

    MTLTextureDescriptor *outDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:w
                                    height:h
                                 mipmapped:NO];
    outDesc.storageMode = MTLStorageModeShared;
    outDesc.usage       = MTLTextureUsageShaderWrite;
    id<MTLTexture> outTex = [_device newTextureWithDescriptor:outDesc
                                                    iosurface:outSurface
                                                        plane:0];
    if (!outTex) {
        CVPixelBufferRelease(output);
        CVPixelBufferRetain(input);
        return input;
    }

    // ── Copy current matrix under lock ────────────────────────────────────
    _ColorMatrixParamsLayout params;
    os_unfair_lock_lock(&_matrixLock);
    memcpy(params.m, _mat, sizeof(float) * 20);
    os_unfair_lock_unlock(&_matrixLock);

    id<MTLBuffer> paramBuf = [_device newBufferWithBytes:&params
                                                   length:sizeof(_ColorMatrixParamsLayout)
                                                  options:MTLResourceStorageModeShared];
    if (!paramBuf) {
        CVPixelBufferRelease(output);
        CVPixelBufferRetain(input);
        return input;
    }

    // ── Encode and commit ─────────────────────────────────────────────────
    id<MTLCommandBuffer>        cmd = [_queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_pso];
    [enc setTexture:inTex  atIndex:0];
    [enc setTexture:outTex atIndex:1];
    [enc setBuffer:paramBuf offset:0 atIndex:0];

    MTLSize threads = MTLSizeMake(_pso.threadExecutionWidth, 1, 1);
    MTLSize grid    = MTLSizeMake(w, h, 1);
    [enc dispatchThreads:grid threadsPerThreadgroup:threads];
    [enc endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];

    return output; // caller owns; pool reclaims via ARC/CF after release
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: invalidate — no async work; no-op
// ─────────────────────────────────────────────────────────────────────────────

- (void)invalidate {
    // Synchronous Metal compute — no in-flight async requests to cancel.
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: VGMediaNode — prepareWithCompletion: (P3-2)
// ─────────────────────────────────────────────────────────────────────────────

- (void)prepareWithCompletion:(void (^)(NSError *_Nullable))completion {
    // nil pool is valid for one-shot still-image export.
    // The node will allocate a standalone output buffer per frame.
    if (completion) completion(nil);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: VGMetalFilterNode — processEnvelope:device: (P3-1 additive)
// ─────────────────────────────────────────────────────────────────────────────

/// Wraps processBuffer:atTime:device: into the VGFrameEnvelope contract.
///
/// Ownership contract (DEC-44 / RR-28):
///   - Passthrough: returns input envelope unchanged (no buffer operations).
///   - Active:      allocates new output buffer (+1 retain). Runtime releases it.
///   - Input buffer is NOT released here — runtime owns that retain.
///   - Failure (pool/GPU error): returns envelope with NULL videoBuffer.
- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                             device:(id<MTLDevice>)device {
    if (!_enabled || !_pso) {
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

    VGFrameEnvelope out = envelope;     // copies all metadata fields (DEC-44)
    out.payload.videoBuffer = output;   // runtime releases after downstream delivery
    return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Private — PSO compilation
// ─────────────────────────────────────────────────────────────────────────────

- (void)_compilePSO {
    id<MTLLibrary> lib = [VGMetalLibraryResolver libraryForDevice:_device
                                                           caller:@"VGColorMatrix"];
    if (!lib) {
        NSLog(@"[VGColorMatrix] Failed to load Metal library");
        return;
    }
    id<MTLFunction> fn = [lib newFunctionWithName:@"vanguard_color_matrix_apply"];
    if (!fn) {
        NSLog(@"[VGColorMatrix] vanguard_color_matrix_apply not found in Metal library");
        return;
    }
    NSError *err = nil;
    _pso = [_device newComputePipelineStateWithFunction:fn error:&err];
    if (!_pso) {
        NSLog(@"[VGColorMatrix] PSO compile failed: %@", err);
    }
}

@end
