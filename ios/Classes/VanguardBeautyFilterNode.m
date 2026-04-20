// VanguardBeautyFilterNode.m
#import "VanguardBeautyFilterNode.h"

typedef struct { float sigmaSpace; float sigmaColor; int radius; } BilateralParams;

@implementation VanguardBeautyFilterNode {
    CVPixelBufferPoolRef          _pool;
    id<MTLDevice>                 _device;
    id<MTLCommandQueue>           _queue;
    id<MTLComputePipelineState>   _pso;
}

@synthesize filterName = _filterName;
@synthesize enabled    = _enabled;
@synthesize intensity  = _intensity;
@synthesize radius     = _radius;

- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool device:(id<MTLDevice>)device {
    self = [super init];
    if (!self) return nil;
    _pool       = pool;
    _device     = device;
    _queue      = [device newCommandQueue];
    _enabled    = YES;
    _intensity  = 0.5f;
    _radius     = 2;
    _filterName = @"Beauty";
    [self _compilePSO];
    return self;
}

- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)t
                           device:(id<MTLDevice>)device {
    // Gate: disabled or radius=0 or PSO unavailable → passthrough (P4-FN-6)
    if (!_enabled || _radius <= 0 || !_pso) {
        CVPixelBufferRetain(input); return input;
    }
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(input);
    if (!surface) { CVPixelBufferRetain(input); return input; }

    size_t w = CVPixelBufferGetWidth(input);
    size_t h = CVPixelBufferGetHeight(input);

    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:w height:h mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage       = MTLTextureUsageShaderRead;
    id<MTLTexture> inTex = [_device newTextureWithDescriptor:td iosurface:surface plane:0];
    if (!inTex) { CVPixelBufferRetain(input); return input; }

    CVPixelBufferRef output = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(nil, _pool, &output) != kCVReturnSuccess) {
        CVPixelBufferRetain(input); return input;
    }
    IOSurfaceRef outSurf = CVPixelBufferGetIOSurface(output);
    if (!outSurf) { CVPixelBufferRelease(output); CVPixelBufferRetain(input); return input; }

    td.usage = MTLTextureUsageShaderWrite;
    id<MTLTexture> outTex = [_device newTextureWithDescriptor:td iosurface:outSurf plane:0];
    if (!outTex) { CVPixelBufferRelease(output); CVPixelBufferRetain(input); return input; }

    // Map intensity [0,1] → sigmaColor [0.001, 0.3]
    // At intensity=0: sigmaColor=0.001 (near-identity, satisfies P4-FN-5).
    float sigmaColor = 0.001f + _intensity * 0.299f;
    float sigmaSpace = 2.0f;   // fixed spatial Gaussian
    BilateralParams params = { sigmaSpace, sigmaColor, _radius };

    id<MTLBuffer> paramsBuf = [_device newBufferWithBytes:&params
                                                   length:sizeof(params)
                                                  options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer>        cmd = [_queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_pso];
    [enc setTexture:inTex  atIndex:0];
    [enc setTexture:outTex atIndex:1];
    [enc setBuffer:paramsBuf offset:0 atIndex:0];
    MTLSize threads = MTLSizeMake(_pso.threadExecutionWidth, 1, 1);
    [enc dispatchThreads:MTLSizeMake(w,h,1) threadsPerThreadgroup:threads];
    [enc endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];

    return output;
}

// P5: No-op — bilateral Metal compute is synchronous (cmd waitUntilCompleted).
- (void)invalidate { }


- (void)_compilePSO {
    id<MTLLibrary> lib = [_device newDefaultLibrary];
    id<MTLFunction> fn = [lib newFunctionWithName:@"vanguard_bilateral_filter"];
    if (!fn) { NSLog(@"[VanguardBeauty] bilateral kernel not found"); return; }
    NSError *err = nil;
    _pso = [_device newComputePipelineStateWithFunction:fn error:&err];
    if (!_pso) NSLog(@"[VanguardBeauty] PSO compile: %@", err);
}

@end
