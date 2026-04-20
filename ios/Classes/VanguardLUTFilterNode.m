// VanguardLUTFilterNode.m
#import "VanguardLUTFilterNode.h"
#import <os/lock.h>

// BilateralParams must match the struct in VanguardEffects.metal exactly.
// Declared here only for size verification; the Metal kernel uses its own definition.
typedef struct { float sigmaSpace; float sigmaColor; int radius; } _BilateralParamsLayout;

@implementation VanguardLUTFilterNode {
    CVPixelBufferPoolRef      _pool;
    id<MTLDevice>             _device;
    id<MTLCommandQueue>       _queue;
    id<MTLComputePipelineState> _pso;   // nil until first LUT load

    id<MTLTexture>            _lut;     // nil when no LUT loaded / clearLUT called
    os_unfair_lock            _lutLock;

    id<MTLTexture>            _defaultLUT;  // 1³ identity LUT for passthrough via shader
}

@synthesize filterName = _filterName;
@synthesize enabled    = _enabled;
@synthesize intensity  = _intensity;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Init
// ─────────────────────────────────────────────────────────────────────────────

- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool device:(id<MTLDevice>)device {
    self = [super init];
    if (!self) return nil;
    _pool      = pool;
    _device    = device;
    _queue     = [device newCommandQueue];
    _lutLock   = OS_UNFAIR_LOCK_INIT;
    _enabled   = YES;
    _intensity = 1.0f;
    _filterName = @"LUT";
    [self _compilePSO];
    [self _buildDefaultLUT];
    return self;
}

- (void)dealloc {
    _pso = nil; _lut = nil; _defaultLUT = nil; _queue = nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: VanguardFilterNode
// ─────────────────────────────────────────────────────────────────────────────

- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)t
                           device:(id<MTLDevice>)device {
    os_unfair_lock_lock(&_lutLock);
    id<MTLTexture> activeLUT = _lut ?: _defaultLUT;
    os_unfair_lock_unlock(&_lutLock);

    // Passthrough: no PSO, no LUT, or disabled
    if (!_enabled || !_pso || !activeLUT) {
        CVPixelBufferRetain(input);
        return input;
    }

    // Wrap input as MTLTexture
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(input);
    if (!surface) { CVPixelBufferRetain(input); return input; }

    size_t w = CVPixelBufferGetWidth(input);
    size_t h = CVPixelBufferGetHeight(input);
    MTLTextureDescriptor *inDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:w height:h mipmapped:NO];
    inDesc.storageMode = MTLStorageModeShared;
    inDesc.usage       = MTLTextureUsageShaderRead;
    id<MTLTexture> inTex = [_device newTextureWithDescriptor:inDesc iosurface:surface plane:0];
    if (!inTex) { CVPixelBufferRetain(input); return input; }

    // Allocate output buffer from pool
    CVPixelBufferRef output = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(nil, _pool, &output) != kCVReturnSuccess) {
        CVPixelBufferRetain(input); return input;
    }
    IOSurfaceRef outSurface = CVPixelBufferGetIOSurface(output);
    if (!outSurface) { CVPixelBufferRelease(output); CVPixelBufferRetain(input); return input; }

    MTLTextureDescriptor *outDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:w height:h mipmapped:NO];
    outDesc.storageMode = MTLStorageModeShared;
    outDesc.usage       = MTLTextureUsageShaderWrite;
    id<MTLTexture> outTex = [_device newTextureWithDescriptor:outDesc iosurface:outSurface plane:0];
    if (!outTex) { CVPixelBufferRelease(output); CVPixelBufferRetain(input); return input; }

    // Encode compute pass
    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:_pso];
    [enc setTexture:inTex  atIndex:0];
    [enc setTexture:outTex atIndex:1];
    [enc setTexture:activeLUT atIndex:2];
    MTLSize threads = MTLSizeMake(_pso.threadExecutionWidth, 1, 1);
    MTLSize grid    = MTLSizeMake(w, h, 1);
    [enc dispatchThreads:grid threadsPerThreadgroup:threads];
    [enc endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];

    return output;   // caller owns; ARC/CF releases return it to pool
}

// P5: No-op — Metal compute shaders are synchronous (cmd waitUntilCompleted).
// No in-flight async requests to cancel.
- (void)invalidate { }


// ─────────────────────────────────────────────────────────────────────────────
// MARK: LUT Loading
// ─────────────────────────────────────────────────────────────────────────────

- (void)loadLUTFromCubeURL:(NSURL *)url completion:(void (^)(NSError *_Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        NSString *src = [NSString stringWithContentsOfURL:url
                                                 encoding:NSUTF8StringEncoding error:&err];
        if (!src || err) { if (completion) completion(err); return; }

        NSInteger size = 0;
        NSMutableArray<NSNumber *> *values = [NSMutableArray array];
        for (NSString *rawLine in [src componentsSeparatedByCharactersInSet:
                                       [NSCharacterSet newlineCharacterSet]]) {
            NSString *line = [rawLine stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
            if ([line hasPrefix:@"#"] || line.length == 0) continue;
            if ([line hasPrefix:@"LUT_3D_SIZE"]) {
                size = [[line componentsSeparatedByString:@" "].lastObject integerValue];
                continue;
            }
            NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
            if (parts.count >= 3) {
                [values addObject:@(parts[0].floatValue)];   // R
                [values addObject:@(parts[1].floatValue)];   // G
                [values addObject:@(parts[2].floatValue)];   // B
            }
        }
        if (size == 0 || values.count < (NSUInteger)(size*size*size*3)) {
            if (completion) completion([NSError errorWithDomain:@"VanguardLUT"
                code:1 userInfo:@{NSLocalizedDescriptionKey:@"Invalid .cube file"}]);
            return;
        }
        NSMutableData *data = [NSMutableData dataWithLength:size*size*size*4];
        UInt8 *d = (UInt8 *)data.mutableBytes;
        for (NSInteger i = 0; i < size*size*size; i++) {
            d[i*4+0] = (UInt8)([values[i*3+0] floatValue] * 255.0f);   // R
            d[i*4+1] = (UInt8)([values[i*3+1] floatValue] * 255.0f);   // G
            d[i*4+2] = (UInt8)([values[i*3+2] floatValue] * 255.0f);   // B
            d[i*4+3] = 255;
        }
        [self loadLUTWithSize:size data:data];
        if (completion) completion(nil);
    });
}

- (void)loadLUTWithSize:(NSInteger)size data:(NSData *)data {
    NSAssert(data.length == (NSUInteger)(size*size*size*4),
             @"LUT data length mismatch: got %zu, expected %ld", data.length, size*size*size*4);
    MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = MTLTextureType3D;
    desc.pixelFormat = MTLPixelFormatRGBA8Unorm;
    desc.width  = (NSUInteger)size;
    desc.height = (NSUInteger)size;
    desc.depth  = (NSUInteger)size;
    desc.usage       = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [_device newTextureWithDescriptor:desc];
    if (!tex) { NSLog(@"[VanguardLUT] 3D texture alloc failed"); return; }
    [tex replaceRegion:MTLRegionMake3D(0,0,0,size,size,size)
           mipmapLevel:0 slice:0
             withBytes:data.bytes
           bytesPerRow:size*4
         bytesPerImage:size*size*4];
    os_unfair_lock_lock(&_lutLock);
    _lut = tex;
    os_unfair_lock_unlock(&_lutLock);
}

- (void)clearLUT {
    os_unfair_lock_lock(&_lutLock);
    _lut = nil;
    os_unfair_lock_unlock(&_lutLock);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Private
// ─────────────────────────────────────────────────────────────────────────────

- (void)_compilePSO {
    id<MTLLibrary> lib = [_device newDefaultLibrary];
    id<MTLFunction> fn = [lib newFunctionWithName:@"vanguard_lut_apply"];
    if (!fn) {
        NSLog(@"[VanguardLUT] vanguard_lut_apply not found in default library");
        return;
    }
    NSError *err = nil;
    _pso = [_device newComputePipelineStateWithFunction:fn error:&err];
    if (!_pso) NSLog(@"[VanguardLUT] PSO compile failed: %@", err);
}

- (void)_buildDefaultLUT {
    // 2³ identity LUT used when passthrough must go through the shader path.
    // Normally enabled=NO will blit instead; this is the safety default.
    const NSInteger N = 2;
    MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = MTLTextureType3D; desc.pixelFormat = MTLPixelFormatRGBA8Unorm;
    desc.width=N; desc.height=N; desc.depth=N;
    desc.usage=MTLTextureUsageShaderRead; desc.storageMode=MTLStorageModeShared;
    _defaultLUT = [_device newTextureWithDescriptor:desc];
    if (!_defaultLUT) return;
    UInt8 px[2*2*2*4];
    for (int b=0; b<N; b++) for (int g=0; g<N; g++) for (int r=0; r<N; r++) {
        int i=(b*4+g*2+r)*4;
        px[i]=(UInt8)(r*255); px[i+1]=(UInt8)(g*255); px[i+2]=(UInt8)(b*255); px[i+3]=255;
    }
    [_defaultLUT replaceRegion:MTLRegionMake3D(0,0,0,N,N,N) mipmapLevel:0 slice:0
                     withBytes:px bytesPerRow:N*4 bytesPerImage:N*N*4];
}

@end
