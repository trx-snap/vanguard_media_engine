// VanguardBeautyFilterNode.m
#import "VanguardBeautyFilterNode.h"
#import "VGMetalLibraryResolver.h"

typedef struct {
  float sigmaSpace;
  float sigmaColor;
  int radius;
} BilateralParams;

@implementation VanguardBeautyFilterNode {
  CVPixelBufferPoolRef _pool;
  id<MTLDevice> _device;
  id<MTLCommandQueue> _queue;
  id<MTLComputePipelineState> _pso;
}

@synthesize filterName = _filterName;
@synthesize enabled = _enabled;
@synthesize intensity = _intensity;
@synthesize radius = _radius;
// Phase 3 (P3-1) — VGMediaNode
@synthesize nodeId = _nodeId;
@synthesize nodeType = _nodeType;

// P3-4: isExpensive — NO because Beauty is a bilateral filter (≤3ms).
// Not disabled at thermal Serious tier; only disabled at Critical (all nodes
// off).
- (BOOL)isExpensive {
  return NO;
}

// P4-2: VGMediaNode topology role.
- (VGNodeRole)nodeRole {
  return VGNodeRoleFilter;
}

// P4-2: Scalar GPU cost estimate (A14, nominal thermal, 1080p BGRA).
- (float)estimatedGPUCostMs {
  return 3.0f;
}

- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device {
  self = [super init];
  if (!self)
    return nil;
  _pool = pool;
  _device = device;
  _queue = [device newCommandQueue];
  _enabled = YES;
  _intensity = 0.5f;
  _radius = 4;
  _filterName = @"Beauty";
  // Phase 3 (P3-1) — VGMediaNode identity
  _nodeId = [[NSUUID UUID] UUIDString];
  _nodeType = @"VGBeautyFilterNode";
  [self _compilePSO];
  return self;
}

- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)t
                           device:(id<MTLDevice>)device {
  // Gate: disabled or radius=0 or PSO unavailable → passthrough (P4-FN-6)
  if (!_enabled || _radius <= 0 || !_pso) {
    CVPixelBufferRetain(input);
    return input;
  }
  IOSurfaceRef surface = CVPixelBufferGetIOSurface(input);
  if (!surface) {
    CVPixelBufferRetain(input);
    return input;
  }

  size_t w = CVPixelBufferGetWidth(input);
  size_t h = CVPixelBufferGetHeight(input);

  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:w
                                  height:h
                               mipmapped:NO];
  td.storageMode = MTLStorageModeShared;
  td.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> inTex = [_device newTextureWithDescriptor:td
                                                 iosurface:surface
                                                     plane:0];
  if (!inTex) {
    CVPixelBufferRetain(input);
    return input;
  }

  CVPixelBufferRef output = NULL;
  if (CVPixelBufferPoolCreatePixelBuffer(nil, _pool, &output) !=
      kCVReturnSuccess) {
    CVPixelBufferRetain(input);
    return input;
  }
  IOSurfaceRef outSurf = CVPixelBufferGetIOSurface(output);
  if (!outSurf) {
    CVPixelBufferRelease(output);
    CVPixelBufferRetain(input);
    return input;
  }

  td.usage = MTLTextureUsageShaderWrite;
  id<MTLTexture> outTex = [_device newTextureWithDescriptor:td
                                                  iosurface:outSurf
                                                      plane:0];
  if (!outTex) {
    CVPixelBufferRelease(output);
    CVPixelBufferRetain(input);
    return input;
  }

  float sigmaColor = 0.001f + _intensity * 0.299f; // [0.001, 0.3]
  float sigmaSpace = 5.0f;
  BilateralParams params = {sigmaSpace, sigmaColor, _radius};

  id<MTLBuffer> paramsBuf =
      [_device newBufferWithBytes:&params
                           length:sizeof(params)
                          options:MTLResourceStorageModeShared];
  id<MTLCommandBuffer> cmd = [_queue commandBuffer];
  id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
  [enc setComputePipelineState:_pso];
  [enc setTexture:inTex atIndex:0];
  [enc setTexture:outTex atIndex:1];
  [enc setBuffer:paramsBuf offset:0 atIndex:0];
  MTLSize threads = MTLSizeMake(_pso.threadExecutionWidth, 1, 1);
  [enc dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:threads];
  [enc endEncoding];
  [cmd commit];
  [cmd waitUntilCompleted];

  return output;
}

// P5: No-op — bilateral Metal compute is synchronous (cmd waitUntilCompleted).
- (void)invalidate {
}

// ───────────────────────────────────────────────────────────────────────────────
// MARK: VGMediaNode (Phase 3 P3-1 — additive)
// ───────────────────────────────────────────────────────────────────────────────

// P3-2 call-site migration note (DEC-49): see VanguardLUTFilterNode.m for full
// comment. Pool guard ensures the runtime catches a missing pool before
// processEnvelope: is called.
- (void)prepareWithCompletion:(void (^)(NSError *_Nullable))completion {
  if (!_pool) {
    NSError *err = [NSError errorWithDomain:@"VGBeautyFilterNode"
                                       code:1
                                   userInfo:@{
                                     NSLocalizedDescriptionKey :
                                         @"[VGBeautyFilterNode] "
                                         @"prepareWithCompletion: _pool is NULL"
                                   }];
    if (completion)
      completion(err);
    return;
  }
  if (completion)
    completion(nil);
}

// ───────────────────────────────────────────────────────────────────────────────
// MARK: VGMetalFilterNode (Phase 3 P3-1 — additive)
// ───────────────────────────────────────────────────────────────────────────────

/// See VanguardLUTFilterNode for full ownership contract comment (DEC-44 /
/// RR-28).
- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                            device:(id<MTLDevice>)device {
  if (!_enabled || _radius <= 0 || !_pso) {
    return envelope;
  }
  CVPixelBufferRef input = (CVPixelBufferRef)envelope.payload.videoBuffer;
  if (!input)
    return envelope;

  CVPixelBufferRef output = [self processBuffer:input
                                         atTime:envelope.pts
                                         device:device];

  if (output == input) {
    CVPixelBufferRelease(output);
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

- (void)_compilePSO {
  id<MTLLibrary> lib = [VGMetalLibraryResolver libraryForDevice:_device caller:@"VGBeauty"];
  if (!lib) {
    NSLog(@"[VGFilter] Failed to load Metal library — see VGMetalLibraryResolver logs");
    return;
  }
  id<MTLFunction> fn = [lib newFunctionWithName:@"vanguard_bilateral_filter"];
  if (!fn) {
    NSLog(@"[VanguardBeauty] bilateral kernel not found");
    return;
  }
  NSError *err = nil;
  _pso = [_device newComputePipelineStateWithFunction:fn error:&err];
  if (!_pso)
    NSLog(@"[VanguardBeauty] PSO compile: %@", err);
}

@end
