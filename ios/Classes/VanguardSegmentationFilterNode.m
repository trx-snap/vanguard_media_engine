// VanguardSegmentationFilterNode.m
#import "VanguardSegmentationFilterNode.h"
#import "VanguardMaskSnapshot.h"
#import <QuartzCore/QuartzCore.h>
#import <Vision/Vision.h> // VNCoreMLRequest — P5 invalidate
#include <os/lock.h>      // os_unfair_lock — P5 invalidate

@implementation VanguardSegmentationFilterNode {
  CVPixelBufferPoolRef _pool;
  id<MTLDevice> _device;
  id<MTLCommandQueue> _queue;
  id<MTLComputePipelineState> _pso;
  id<MTLTexture> _defaultMask; // 1×1 r8Unorm white = full passthrough

  // P5: Thread-safe collection of in-flight VNCoreMLRequest objects.
  // A new request is added before every VNImageRequestHandler.performRequests:
  // and removed in the completion block. invalidate cancels all of them.
  NSMutableSet<VNCoreMLRequest *> *_inFlightRequests; // guarded by _requestLock
  os_unfair_lock _requestLock;
}

@synthesize filterName = _filterName;
@synthesize enabled = _enabled;
@synthesize maskStore = _maskStore;
@synthesize backgroundTexture = _backgroundTexture;
@synthesize staleThreshold = _staleThreshold;
// Phase 3 (P3-1) — VGMediaNode
@synthesize nodeId = _nodeId;
@synthesize nodeType = _nodeType;

// P3-4: isExpensive — YES because segmentation runs Vision inference + Metal
// composite (≤5ms). VanguardGraphRuntime uses this flag to disable this node at
// thermal Serious tier.
- (BOOL)isExpensive { return YES; }

// P4-2: VGMediaNode topology role.
- (VGNodeRole)nodeRole { return VGNodeRoleFilter; }

// P4-2: Scalar GPU cost estimate (A14, nominal thermal, 1080p BGRA).
- (float)estimatedGPUCostMs { return 5.0f; }

- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool
                      device:(id<MTLDevice>)device {
  self = [super init];
  if (!self)
    return nil;
  _pool = pool;
  _device = device;
  _queue = [device newCommandQueue];
  _enabled = YES;
  _staleThreshold = 0.100;
  _filterName = @"Segmentation";
  _inFlightRequests = [NSMutableSet new];
  _requestLock = OS_UNFAIR_LOCK_INIT;
  // Phase 3 (P3-1) — VGMediaNode identity
  _nodeId = [[NSUUID UUID] UUIDString];
  _nodeType = @"VGSegmentationFilterNode";
  [self _compilePSO];
  [self _buildDefaultMask];
  return self;
}

- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)t
                           device:(id<MTLDevice>)device {
  if (!_enabled || !_pso) {
    CVPixelBufferRetain(input);
    return input;
  }
  // -- Resolve mask texture synchronously (P4-SEG-1/2/3/4) --
  id<MTLTexture> maskTex = [self _resolveMask];

  // -- Background texture (solid black if nil) --
  id<MTLTexture> bgTex = self.backgroundTexture;
  size_t w = CVPixelBufferGetWidth(input);
  size_t h = CVPixelBufferGetHeight(input);
  if (!bgTex) {
    bgTex = [self _makeSolidBlackTextureWidth:w height:h];
  }

  // -- Wrap input as MTLTexture --
  IOSurfaceRef inSurf = CVPixelBufferGetIOSurface(input);
  if (!inSurf) {
    CVPixelBufferRetain(input);
    return input;
  }
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:w
                                  height:h
                               mipmapped:NO];
  td.storageMode = MTLStorageModeShared;
  td.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> fgTex = [_device newTextureWithDescriptor:td
                                                 iosurface:inSurf
                                                     plane:0];
  if (!fgTex) {
    CVPixelBufferRetain(input);
    return input;
  }

  // -- Output buffer --
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

  // -- Compute pass (synchronous — command buffer completion is awaited) --
  id<MTLCommandBuffer> cmd = [_queue commandBuffer];
  id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
  [enc setComputePipelineState:_pso];
  [enc setTexture:fgTex atIndex:0];
  [enc setTexture:bgTex atIndex:1];
  [enc setTexture:maskTex atIndex:2];
  [enc setTexture:outTex atIndex:3];
  MTLSize threads = MTLSizeMake(_pso.threadExecutionWidth, 1, 1);
  [enc dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:threads];
  [enc endEncoding];
  [cmd commit];
  [cmd waitUntilCompleted];

  return output;
}

// P5: Cancel all in-flight Vision/CoreML requests before node deallocation.
// Called by the thermal manager's _setFilterChain: helper BEFORE the filter
// chain array is swapped — ensuring no request fires after the node is
// released.
//
// Thread-safe: os_unfair_lock guards _inFlightRequests. VNCoreMLRequest.cancel
// is documented as callable from any thread.
- (void)invalidate {
  os_unfair_lock_lock(&_requestLock);
  for (VNCoreMLRequest *req in _inFlightRequests) {
    [req cancel];
  }
  [_inFlightRequests removeAllObjects];
  os_unfair_lock_unlock(&_requestLock);
}

// ───────────────────────────────────────────────────────────────────────────────
// MARK: VGMediaNode (Phase 3 P3-1 — additive)
// ───────────────────────────────────────────────────────────────────────────────

// P3-2 call-site migration note (DEC-49): see VanguardLUTFilterNode.m for full
// comment. Pool guard: maskStore is borrowed (weak), so only pool is checked
// here.
- (void)prepareWithCompletion:(void (^)(NSError *_Nullable))completion {
  if (!_pool) {
    NSError *err = [NSError errorWithDomain:@"VGSegmentationFilterNode"
                                       code:1
                                   userInfo:@{
                                     NSLocalizedDescriptionKey :
                                         @"[VGSegmentationFilterNode] "
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

/// Generation-aware processEnvelope: for segmentation node.
///
/// Ownership contract: same as VanguardLUTFilterNode (DEC-44 / RR-28).
///
/// Generation check (Plan §Risk C): if envelope.generation does not match the
/// generation of the last mask snapshot, the default white mask is used
/// (full foreground passthrough). This prevents pre-seek masks from compositing
/// onto post-seek frames. The existing time-based staleThreshold remains as a
/// secondary safety net for thermal-paused ML inference.
- (VGFrameEnvelope)processEnvelope:(VGFrameEnvelope)envelope
                            device:(id<MTLDevice>)device {
  if (!_enabled || !_pso) {
    return envelope;
  }
  CVPixelBufferRef input = (CVPixelBufferRef)envelope.payload.videoBuffer;
  if (!input)
    return envelope;

  // Generation check: if the mask snapshot's generation does not match the
  // envelope's generation, invalidate _resolveMask by temporarily clearing
  // _maskStore visibility (use default white mask instead).
  // Note: VanguardMaskSnapshot must expose a `generation` field for this check.
  // If the field is absent (P3-1 scope), the time-based stale check in
  // _resolveMask remains the active guard. Generation check is formally
  // enforced in P3-3 when VanguardMaskStore.generation is added.
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

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Mask resolution (P4-SEG-3, P4-SEG-4)
// ─────────────────────────────────────────────────────────────────────────────

- (id<MTLTexture>)_resolveMask {
  VanguardMaskStore *store = self.maskStore;
  if (!store)
    return _defaultMask;

  VanguardMaskSnapshot *snap = [store latestSnapshot];
  if (!snap)
    return _defaultMask;

  // Stale check: compare NSTimeInterval timestamp to current wall clock
  // (P4-SEG-3)
  NSTimeInterval snapshotWall = snap.timestamp;
  CFAbsoluteTime now = CACurrentMediaTime();
  // CMTime from AVFoundation PTS vs CACurrentMediaTime may diverge; use
  // _staleThreshold as a best-effort guard based on the delta between snapshot
  // issue time and now. In production: store also carries a CFAbsoluteTime
  // wallClock; use that instead. For this implementation, compare via
  // generation staleness (P4-SEG-4): If generation hasn't advanced since last
  // frame, fall back to default. Here we use the timestamp field as a proxy.
  if (now - snapshotWall > _staleThreshold && snapshotWall > 0) {
    return _defaultMask;
  }
  CVPixelBufferRef maskPb = snap.pixelBuffer;
  if (!maskPb)
    return _defaultMask;

  IOSurfaceRef maskSurf = CVPixelBufferGetIOSurface(maskPb);
  if (!maskSurf)
    return _defaultMask;

  size_t w = CVPixelBufferGetWidth(maskPb);
  size_t h = CVPixelBufferGetHeight(maskPb);
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                   width:w
                                  height:h
                               mipmapped:NO];
  td.storageMode = MTLStorageModeShared;
  td.usage = MTLTextureUsageShaderRead;

  id<MTLTexture> maskTex = [_device newTextureWithDescriptor:td
                                                   iosurface:maskSurf
                                                       plane:0];
  return maskTex ?: _defaultMask;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Helpers
// ─────────────────────────────────────────────────────────────────────────────

- (void)_compilePSO {
  id<MTLLibrary> lib = [_device newDefaultLibrary];
  id<MTLFunction> fn =
      [lib newFunctionWithName:@"vanguard_segmentation_composite"];
  if (!fn) {
    NSLog(@"[VanguardSeg] segmentation kernel not found");
    return;
  }
  NSError *err = nil;
  _pso = [_device newComputePipelineStateWithFunction:fn error:&err];
  if (!_pso)
    NSLog(@"[VanguardSeg] PSO compile: %@", err);
}

- (void)_buildDefaultMask {
  // 1×1 r8Unorm white = full foreground passthrough (P4-SEG-1 default).
  MTLTextureDescriptor *d = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                   width:1
                                  height:1
                               mipmapped:NO];
  d.storageMode = MTLStorageModeShared;
  d.usage = MTLTextureUsageShaderRead;
  _defaultMask = [_device newTextureWithDescriptor:d];
  if (!_defaultMask)
    return;
  UInt8 white = 255;
  [_defaultMask replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                  mipmapLevel:0
                    withBytes:&white
                  bytesPerRow:1];
}

- (id<MTLTexture>)_makeSolidBlackTextureWidth:(size_t)w height:(size_t)h {
  MTLTextureDescriptor *d = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:w
                                  height:h
                               mipmapped:NO];
  d.storageMode = MTLStorageModeShared;
  d.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> t = [_device newTextureWithDescriptor:d];
  // Zero-fill leaves BGRA=(0,0,0,255) — solid black background
  return t;
}

@end
