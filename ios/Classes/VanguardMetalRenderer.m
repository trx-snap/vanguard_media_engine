// VanguardMetalRenderer.m
// Phase 2 — _timeProvider now queries AVAudioTime master clock via
// source.currentTime
// ─────────────────────────────────────────────────────────────────────────────
// Phase 1 preservations (unchanged):
//   T1  – CVPixelBufferPool (3 IOSurface-backed buffers)
//   P1-T2 – Renderer holds id<VanguardMediaSource>; no direct AVFoundation
//   imports P1-T3 – filterChain NSArray<id<VanguardFilterNode>> — empty; zero
//   cost T7  – os_unfair_lock on pixel buffer swap
// Phase 2 change (ONLY ONE):
//   P2-T1 – _timeProvider body → [source currentTime] (AVAudioTime or
//   wall-clock fallback)
//            _displayLinkFired is NOT modified (honours Phase 1 contract)

#import "VanguardMetalRenderer.h"
#import "VanguardAudioEngine.h" // P2-T1: master clock protocol
#import "VanguardFileMediaSource.h"
#import "VanguardFilterNode.h"  // Full protocol
#import "VanguardMediaSource.h" // Full protocol
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#include <os/lock.h>
#include <os/signpost.h>

static os_log_t _rendererLog;

@implementation VanguardMetalRenderer {
  // ── Source (Phase 1: any id<VanguardMediaSource>) ──────────────────────
  id<VanguardMediaSource> _source;

  // ── Metal GPU pipeline ──────────────────────────────────────────────────
  id<MTLDevice> _device;
  id<MTLCommandQueue> _commandQueue;
  id<MTLRenderPipelineState> _pipelineState;
  CVMetalTextureCacheRef _textureCache;
  id<MTLTexture> _outputTexture;
  // GPU rotation blit pipeline (live preview orientation)
  id<MTLRenderPipelineState> _blitPipelineState;
  uint32_t _rotationIndex; // 0=identity 1=+90 2=-90 3=180
  CGSize _renderSize; // display-correct dimensions; used to detect seek frames

  // ── Frame buffer ─────────────────────────────────────────────────────────
  // P0-T7: os_unfair_lock — non-recursive, priority-aware.
  CVPixelBufferRef _latestPixelBuffer;
  os_unfair_lock _pixelBufferLock;

  // P0-T1: Shared pool supplied to the source; 3 IOSurface-backed Metal
  // buffers.
  CVPixelBufferPoolRef _pixelBufferPool;

  // ── Filter chain (P1-T3) — empty array in Phase 1 ──────────────────────
  NSArray<id<VanguardFilterNode>> *_filterChain;
  BOOL _filterChainEnabled;

  // ── Playback clock (P1-T5 rate-aware _timeProvider) ─────────────────────
  CADisplayLink *_displayLink;
  double _playbackStartWall; // wall time of t=0 (recalibrated on rate change)
  double _playbackRate;      // default 1.0
  double _currentTime;       // output-timeline position
  double _videoDuration;     // SOURCE duration (seconds)
  BOOL _isPlaying;
  // One-shot end-of-clip flag: prevents repeated onPlaybackComplete
  // callbacks while keeping the displayLink running so Flutter's Dart
  // event loop stays alive until the caller calls pause().
  BOOL _playbackCompleted;

  // _timeProvider: returns the current OUTPUT-TIMELINE position.
  // Default: wall-clock × _playbackRate.
  // Phase 2 replaces the body with AVAudioTime query — the block signature
  // never changes.
  double (^_timeProvider)(void);

  // ── Flutter ──────────────────────────────────────────────────────────────
  id<FlutterTextureRegistry> _textureRegistry;
  FlutterMethodChannel *_methodChannel;
  int64_t _textureId;
  double _lastDecodedPTS;
  double _seekTargetPTS; // gate: don't pull sequential frames until masterClock
                         // >= this
  BOOL _isFetchingFrame;
}

@synthesize textureId = _textureId;
@synthesize videoDuration = _videoDuration;
@synthesize filterChain = _filterChain;
@synthesize filterChainEnabled = _filterChainEnabled;
// Phase A1-S1: expose pool for backfill into VanguardImageProcessor
@synthesize pixelBufferPool = _pixelBufferPool;

/// G-02: currentTimeSeconds — diagnostic accessor for A/V sync test.
- (double)currentTimeSeconds {
  return CMTimeGetSeconds([_source currentTime]);
}

/// G-02-T3: seekPreviewPaused — forwards to VanguardFileMediaSource.
/// Safe cast: in practice _source is always a VanguardFileMediaSource.
- (BOOL)seekPreviewPaused {
  if ([_source isKindOfClass:[VanguardFileMediaSource class]]) {
    return ((VanguardFileMediaSource *)_source).seekPreviewPaused;
  }
  return NO;
}

- (void)setSeekPreviewPaused:(BOOL)paused {
  if ([_source isKindOfClass:[VanguardFileMediaSource class]]) {
    ((VanguardFileMediaSource *)_source).seekPreviewPaused = paused;
  }
}

+ (void)initialize {
  if (self == [VanguardMetalRenderer class]) {
    _rendererLog = os_log_create("com.vanguard.engine", "renderer");
  }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Init
// ─────────────────────────────────────────────────────────────────────────────

- (instancetype)initWithSource:(id<VanguardMediaSource>)source
               textureRegistry:(id<FlutterTextureRegistry>)registry
                 methodChannel:(FlutterMethodChannel *)channel {
  self = [super init];
  if (!self)
    return nil;

  // I-5 / Renderer invariant: a renderer without a source will never produce
  // frames. Fail loudly in debug builds rather than silently showing a black
  // texture.
  NSAssert(
      source != nil,
      @"[VanguardRenderer] INVARIANT: initWithSource: called with nil source. "
      @"Renderer requires a valid VanguardMediaSource to produce frames.");
  if (!source) {
    NSLog(@"[VanguardRenderer] ERROR: nil source — renderer will produce no "
          @"frames.");
    return nil;
  }

  _source = source;
  _textureRegistry = registry;
  _methodChannel = channel;
  _pixelBufferLock = OS_UNFAIR_LOCK_INIT;
  _playbackRate = 1.0;
  _currentTime = 0.0;
  _filterChain = @[];
  _filterChainEnabled = YES;

  [self _setupMetal];
  [self _setupPixelBufferPoolFromSource:source];
  [self _allocateOutputTexture];

  // Derive rotation index and render size once from source preferredTransform.
  // These are immutable for the lifetime of one VanguardFileMediaSource.
  if ([source isKindOfClass:[VanguardFileMediaSource class]]) {
    VanguardFileMediaSource *fs = (VanguardFileMediaSource *)source;
    _renderSize = fs.renderSize;
    CGAffineTransform t = fs.imageGenTransform;
    if (fabs(t.b - 1.0) < 0.01 && fabs(t.c + 1.0) < 0.01) {
      _rotationIndex = 1; // +90 back-camera portrait
    } else if (fabs(t.b + 1.0) < 0.01 && fabs(t.c - 1.0) < 0.01) {
      _rotationIndex = 2; // -90 front-camera portrait
    } else if (fabs(t.a + 1.0) < 0.01 && fabs(t.d + 1.0) < 0.01) {
      _rotationIndex = 3; // 180 upside-down
    } else {
      _rotationIndex = 0; // identity / landscape
    }
    NSLog(@"[VanguardRenderer] rotationIndex=%u renderSize={%.0f,%.0f}",
          _rotationIndex, _renderSize.width, _renderSize.height);
  }

  // P2-T1: _timeProvider body swapped to query source master clock.
  // VanguardFileMediaSource.currentTime returns AVAudioTime-derived position
  // (or wall-clock fallback for video-only). The block SIGNATURE is frozen —
  // _displayLinkFired is never modified again (Phase 1 contract honoured).
  __weak __typeof(self) weakSelf = self;
  __weak id<VanguardMediaSource> weakSource = source;
  _timeProvider = ^double {
    __strong id<VanguardMediaSource> s = weakSource;
    if (!s)
      return 0.0;
    // source.currentTime is the output-timeline position (already
    // rate-corrected by AVAudioUnitTimePitch). The renderer multiplies by
    // _playbackRate only for the SOURCE-time seek — that multiplication happens
    // in _displayLinkFired.
    return CMTimeGetSeconds([s currentTime]);
  };

  // Wire video callback from source → renderer frame handler
  [_source setVideoCallback:^(CVPixelBufferRef frame, CMTime pts) {
    __strong __typeof(weakSelf) s = weakSelf;
    if (s)
      [s _onVideoFrame:frame pts:pts];
  }];

  // Register texture with Flutter
  _textureId = [registry registerTexture:self];

  // Report duration to Dart timeline manager
  _videoDuration = CMTimeGetSeconds([_source duration]);
  if (_videoDuration > 0) {
    // source.renderSize is populated during source init
    VanguardFileMediaSource *fileSource = (VanguardFileMediaSource *)source;
    if ([source isKindOfClass:[VanguardFileMediaSource class]]) {
      NSString *path =
          ((VanguardFileMediaSource *)fileSource).description; // best-effort
      (void)path;
    }
    [channel invokeMethod:@"onNodeDurationProbed"
                arguments:@{@"duration" : @(_videoDuration)}];
  }

  return self;
}

/// Convenience initialiser — backward compat. Creates VanguardFileMediaSource
/// internally.
- (instancetype)initWithVideoPath:(NSString *)videoPath
                  textureRegistry:(id<FlutterTextureRegistry>)registry
                    methodChannel:(FlutterMethodChannel *)channel {
  NSURL *url = [NSURL fileURLWithPath:videoPath];
  // Pool created in initWithSource:; pass nil for now — source gets pool
  // reference after setup.
  VanguardFileMediaSource *source =
      [[VanguardFileMediaSource alloc] initWithURL:url pixelBufferPool:nil];
  self = [self initWithSource:source
              textureRegistry:registry
                methodChannel:channel];
  if (!self)
    return nil;

  // PATCH-8: Wire the renderer's CVPixelBufferPool to the source now that
  // initWithSource: has created the pool. Seek frames
  // (_pixelBufferFromCGImage:) will use pool allocation instead of
  // CVPixelBufferCreate, eliminating one VM round-trip per seek frame during
  // scrubbing.
  if (_pixelBufferPool) {
    source.pixelBufferPool = _pixelBufferPool;
  }

  // Report duration with path (convenience init has the path)
  _videoDuration = CMTimeGetSeconds([source duration]);
  [channel
      invokeMethod:@"onNodeDurationProbed"
         arguments:@{@"path" : videoPath, @"duration" : @(_videoDuration)}];

  return self;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Metal Setup (GPU only — no AVFoundation)
// ─────────────────────────────────────────────────────────────────────────────

- (void)_setupMetal {
  _device = MTLCreateSystemDefaultDevice();
  _commandQueue = [_device newCommandQueue];

  CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, _device, nil,
                            &_textureCache);

  // FIX: [_device newDefaultLibrary] loads from the MAIN app bundle, which
  // has no .metal shaders. The shaders (VanguardCompositor.metal,
  // VanguardEffects.metal) are compiled into default.metallib inside the
  // vanguard_media_engine.framework bundle. Use bundleForClass: to locate
  // the framework bundle that loaded this class — correct on all deployment
  // configurations (CocoaPods use_frameworks!, SwiftPM, static xcframework).
  NSBundle *bundle = [NSBundle bundleForClass:[VanguardMetalRenderer class]];
  NSError *libraryError = nil;
  id<MTLLibrary> library = [_device newDefaultLibraryWithBundle:bundle
                                                          error:&libraryError];
  if (!library) {
    NSLog(@"[VanguardRenderer] FATAL: Metal library not found in bundle %@: %@",
          bundle.bundleURL.lastPathComponent,
          libraryError.localizedDescription);
    return;
  }
  NSLog(@"[VanguardRenderer] [1/4] Metal library loaded from bundle: %@",
        bundle.bundleURL.lastPathComponent);

  id<MTLFunction> vertexFn = [library newFunctionWithName:@"vanguard_vertex"];
  id<MTLFunction> fragmentFn =
      [library newFunctionWithName:@"vanguard_composite"];

  if (!vertexFn || !fragmentFn) {
    NSLog(@"[VanguardRenderer] FATAL: Shader not found — vertexFn=%@ "
          @"fragmentFn=%@",
          vertexFn, fragmentFn);
    return;
  }

  // MTLVertexDescriptor matching VertexIn{ float2 position [[attribute(0)]];
  //                                        float2 texCoord [[attribute(1)]]; }
  // stride = 2 × sizeof(float2) = 2 × 8 = 16 bytes; both attrs from buffer slot
  // 0.
  MTLVertexDescriptor *vtxDesc = [MTLVertexDescriptor vertexDescriptor];
  vtxDesc.attributes[0].format = MTLVertexFormatFloat2; // position
  vtxDesc.attributes[0].offset = 0;
  vtxDesc.attributes[0].bufferIndex = 0;
  vtxDesc.attributes[1].format = MTLVertexFormatFloat2; // texCoord
  vtxDesc.attributes[1].offset = 8;                     // sizeof(float2)
  vtxDesc.attributes[1].bufferIndex = 0;
  vtxDesc.layouts[0].stride = 16; // sizeof(VertexIn)
  vtxDesc.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

  MTLRenderPipelineDescriptor *desc =
      [[MTLRenderPipelineDescriptor alloc] init];
  desc.vertexFunction = vertexFn;
  desc.fragmentFunction = fragmentFn;
  desc.vertexDescriptor = vtxDesc;
  desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

  NSError *error = nil;
  _pipelineState = [_device newRenderPipelineStateWithDescriptor:desc
                                                           error:&error];
  if (error) {
    NSLog(@"[VanguardRenderer] FATAL: Pipeline error: %@",
          error.localizedDescription);
  } else {
    NSLog(@"[VanguardRenderer] [4/4] pipeline state created OK — Metal "
          @"renderer ready");
  }

  [self _setupBlitPipeline:library];
}

- (void)_setupPixelBufferPoolFromSource:(id<VanguardMediaSource>)source {
  CGSize size = CGSizeMake(1080, 1920); // fallback

  if ([source isKindOfClass:[VanguardFileMediaSource class]]) {
    CGSize s = ((VanguardFileMediaSource *)source).renderSize;
    if (s.width > 0 && s.height > 0)
      size = s;
  }

  [self _setupPixelBufferPoolWithWidth:(size_t)size.width
                                height:(size_t)size.height];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - GPU Rotation Blit
// ─────────────────────────────────────────────────────────────────────────────

/// Builds the render pipeline state for vanguard_blit_rotated.
/// Called once from _setupMetal after the main library is loaded.
- (void)_setupBlitPipeline:(id<MTLLibrary>)library {
  if (!library) {
    return;
  }
  id<MTLFunction> blitFrag =
      [library newFunctionWithName:@"vanguard_blit_rotated"];
  id<MTLFunction> vertexFn = [library newFunctionWithName:@"vanguard_vertex"];
  if (!blitFrag || !vertexFn) {
    NSLog(@"[VanguardRenderer] vanguard_blit_rotated not found — GPU rotation "
          @"unavailable");
    return;
  }
  // Vertex layout matching VertexIn { float2 position [[attribute(0)]];
  //                                   float2 texCoord [[attribute(1)]]; }
  // 4 floats per vertex = 16 bytes stride; both attributes in buffer slot 0.
  MTLVertexDescriptor *vtxDesc = [MTLVertexDescriptor vertexDescriptor];
  vtxDesc.attributes[0].format = MTLVertexFormatFloat2; // position
  vtxDesc.attributes[0].offset = 0;
  vtxDesc.attributes[0].bufferIndex = 0;
  vtxDesc.attributes[1].format = MTLVertexFormatFloat2; // texCoord
  vtxDesc.attributes[1].offset = sizeof(float) * 2;
  vtxDesc.attributes[1].bufferIndex = 0;
  vtxDesc.layouts[0].stride = sizeof(float) * 4;
  vtxDesc.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
  MTLRenderPipelineDescriptor *desc =
      [[MTLRenderPipelineDescriptor alloc] init];
  desc.vertexFunction = vertexFn;
  desc.fragmentFunction = blitFrag;
  desc.vertexDescriptor = vtxDesc;
  desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  NSError *error = nil;
  _blitPipelineState = [_device newRenderPipelineStateWithDescriptor:desc
                                                               error:&error];
  if (error) {
    NSLog(@"[VanguardRenderer] Blit pipeline error: %@",
          error.localizedDescription);
    _blitPipelineState = nil;
  } else {
    NSLog(@"[VanguardRenderer] GPU blit pipeline ready");
  }
}

/// Applies GPU rotation to `src` using `_blitPipelineState`.
/// Returns a retained CVPixelBuffer from `_pixelBufferPool` containing the
/// rotated frame, or NULL on failure (caller must fall back to `src`).
/// The caller must independently retain `src` before calling and release it
/// in the Metal completion handler — this method captures that retained ref.
- (CVPixelBufferRef _Nullable)_rotatePixelBufferGPU:(CVPixelBufferRef)src
                                              isHLG:(uint32_t)isHLG {
  if (!_blitPipelineState || !_pixelBufferPool || !_textureCache ||
      !_commandQueue) {
    return NULL;
  }

  // Allocate destination from pool (IOSurface-backed, display-correct size).
  CVPixelBufferRef dst = NULL;
  CVReturn pstat = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                      _pixelBufferPool, &dst);
  if (pstat != kCVReturnSuccess || !dst) {
    NSLog(@"[VanguardRenderer] GPU blit: pool exhausted");
    return NULL;
  }

  // Source texture (read-only sampling).
  CVMetalTextureRef srcMTLRef = NULL;
  CVReturn srcStat = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, _textureCache, src, nil, MTLPixelFormatBGRA8Unorm,
      CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), 0, &srcMTLRef);
  if (srcStat != kCVReturnSuccess || !srcMTLRef) {
    CVPixelBufferRelease(dst);
    NSLog(@"[VanguardRenderer] GPU blit: src texture wrap failed (%d)",
          srcStat);
    return NULL;
  }
  id<MTLTexture> srcTex = CVMetalTextureGetTexture(srcMTLRef);

  // Destination texture (render target). Must request RenderTarget usage
  // explicitly.
  NSDictionary *dstAttrs = @{
    (id)kCVMetalTextureUsage :
        @(MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead)
  };
  CVMetalTextureRef dstMTLRef = NULL;
  CVReturn dstStat = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, _textureCache, dst,
      (__bridge CFDictionaryRef)dstAttrs, MTLPixelFormatBGRA8Unorm,
      CVPixelBufferGetWidth(dst), CVPixelBufferGetHeight(dst), 0, &dstMTLRef);
  if (dstStat != kCVReturnSuccess || !dstMTLRef) {
    CFRelease(srcMTLRef);
    CVPixelBufferRelease(dst);
    NSLog(@"[VanguardRenderer] GPU blit: dst texture wrap failed (%d)",
          dstStat);
    return NULL;
  }
  id<MTLTexture> dstTex = CVMetalTextureGetTexture(dstMTLRef);

  // Full-screen quad: position in [0,1] NDC-pre-transform, texCoord in [0,1].
  // vanguard_vertex converts position to NDC [-1,1] with y-flip.
  static const float kQuad[] = {
      // position  texCoord
      0.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 1.0f, 0.0f,
      0.0f, 1.0f, 0.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f,
  };
  id<MTLBuffer> quadBuf =
      [_device newBufferWithBytes:kQuad
                           length:sizeof(kQuad)
                          options:MTLResourceStorageModeShared];

  uint32_t rotIdx = _rotationIndex;
  id<MTLBuffer> rotBuf =
      [_device newBufferWithBytes:&rotIdx
                           length:sizeof(uint32_t)
                          options:MTLResourceStorageModeShared];

  MTLRenderPassDescriptor *pass =
      [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = dstTex;
  pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];

  // Retain Metal texture wrappers and dst CVPixelBuffer for the completion
  // handler. src is separately retained by the caller before passing here.
  CFRetain(srcMTLRef);
  CFRetain(dstMTLRef);
  CVPixelBufferRetain(src); // completion handler releases this
  [cmdBuf addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull __unused cb) {
    CFRelease(srcMTLRef);
    CFRelease(dstMTLRef);
    CVPixelBufferRelease(src);
  }];

  id<MTLRenderCommandEncoder> enc =
      [cmdBuf renderCommandEncoderWithDescriptor:pass];
  [enc setRenderPipelineState:_blitPipelineState];
  [enc setVertexBuffer:quadBuf offset:0 atIndex:0];
  [enc setFragmentTexture:srcTex atIndex:0];
  id<MTLBuffer> isHLGBuf =
      [_device newBufferWithBytes:&isHLG
                           length:sizeof(uint32_t)
                          options:MTLResourceStorageModeShared];

  [enc setFragmentBuffer:rotBuf offset:0 atIndex:0];
  [enc setFragmentBuffer:isHLGBuf offset:0 atIndex:1];
  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
          vertexStart:0
          vertexCount:4];
  [enc endEncoding];
  [cmdBuf commit];

  // Release the local CVMetalTextureRef wrappers (completed handler holds its
  // own CFRetain).
  CFRelease(srcMTLRef);
  CFRelease(dstMTLRef);
  // Propagate colour-space metadata from src to dst so Flutter receives a
  // correctly-tagged buffer regardless of rotation. Without this the pool
  // buffer has no colour attachments, causing downstream display pipelines
  // to treat the pixels as untagged (missing primaries / transfer function).
  CFDictionaryRef colorAttachments =
      CVBufferCopyAttachments(src, kCVAttachmentMode_ShouldPropagate);
  if (colorAttachments) {
    bool isHLG =
        CFDictionaryContainsKey(colorAttachments,
                                kCVImageBufferTransferFunctionKey) &&
        CFEqual(CFDictionaryGetValue(colorAttachments,
                                     kCVImageBufferTransferFunctionKey),
                kCVImageBufferTransferFunction_ITU_R_2100_HLG);
    if (isHLG)
      NSLog(@"[VanguardRenderer] GPU blit: HLG detected");
    CVBufferSetAttachments(dst, colorAttachments,
                           kCVAttachmentMode_ShouldPropagate);
    CFRelease(colorAttachments);
  }

  return dst; // retained; caller takes ownership
}

// P0-T1: Creates a pool of 3 Metal-compatible BGRA pixel buffers.
- (void)_setupPixelBufferPoolWithWidth:(size_t)w height:(size_t)h {
  if (_pixelBufferPool) {
    CVPixelBufferPoolFlush(_pixelBufferPool, 0);
    CFRelease(_pixelBufferPool);
    _pixelBufferPool = NULL;
  }
  NSDictionary *poolAttrs = @{(id)kCVPixelBufferPoolMinimumBufferCountKey : @3};
  NSDictionary *bufAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(w),
    (id)kCVPixelBufferHeightKey : @(h),
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
    (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
    // IOSurface backing required for Flutter's Metal texture-cache upload path.
    // Without this key Flutter cannot map the CVPixelBuffer to an MTLTexture
    // and renders a black frame even when copyPixelBuffer returns a valid
    // buffer.
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  CVReturn status = CVPixelBufferPoolCreate(
      kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttrs,
      (__bridge CFDictionaryRef)bufAttrs, &_pixelBufferPool);
  if (status != kCVReturnSuccess) {
    NSLog(@"[VanguardRenderer] CVPixelBufferPool creation failed: %d", status);
    _pixelBufferPool = NULL;
  }
}

- (void)_allocateOutputTexture {
  CGSize size = CGSizeMake(1080, 1920); // fallback

  if ([_source isKindOfClass:[VanguardFileMediaSource class]]) {
    CGSize s = ((VanguardFileMediaSource *)_source).renderSize;
    if (s.width > 0 && s.height > 0)
      size = s;
  }

  int w = (int)size.width;
  int h = (int)size.height;
  if (w <= 0 || h <= 0)
    return;

  MTLTextureDescriptor *desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:w
                                  height:h
                               mipmapped:NO];
  desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  _outputTexture = [_device newTextureWithDescriptor:desc];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Playback Control
// ─────────────────────────────────────────────────────────────────────────────

- (void)seek:(double)seconds {
  _currentTime = seconds;
  // Reset the sequential-reader's last-known PTS to the seek position.
  _lastDecodedPTS = seconds;
  // _seekTargetPTS gates pullNextFrameAsync in _renderFrameAtSourceTime:
  _seekTargetPTS = seconds;
  // Reset end-of-clip guard so seeking back into content works.
  _playbackCompleted = NO;
  [_source seekTo:CMTimeMakeWithSeconds(seconds, 600)];
}

- (void)play {
  if (_isPlaying)
    return;
  _isPlaying = YES;
  // Reset end-of-clip guard so replay (play after onPlaybackComplete) works.
  _playbackCompleted = NO;
  // Calibrate wall-clock so _timeProvider returns _currentTime at this instant.
  _playbackStartWall =
      CACurrentMediaTime() -
      (_playbackRate > 0 ? _currentTime / _playbackRate : _currentTime);
  [_source start];
  if ([_source respondsToSelector:@selector(play)]) {
    [(id<VanguardAudioEngine>)_source play];
  }
  _displayLink =
      [CADisplayLink displayLinkWithTarget:self
                                  selector:@selector(_displayLinkFired)];
  [_displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                     forMode:NSRunLoopCommonModes];
}

- (void)pause {
  _isPlaying = NO;
  [_displayLink invalidate];
  _displayLink = nil;
  if ([_source respondsToSelector:@selector(pause)]) {
    [(id<VanguardAudioEngine>)_source pause];
  }
}

// P1-T5: Rate setter — recalibrates wall-clock start so position doesn't jump.
- (void)setPlaybackRate:(double)rate {
  NSAssert([NSThread isMainThread],
           @"setPlaybackRate must be called on main thread");
  double currentPos = _timeProvider();
  _playbackRate = MAX(0.05, MIN(8.0, rate));
  _playbackStartWall = CACurrentMediaTime() - (currentPos / _playbackRate);
  [_source setPlaybackRate:_playbackRate];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Display Link (P1-T5 rate-aware)
// ─────────────────────────────────────────────────────────────────────────────

- (void)_displayLinkFired {
  // ── Timing probe: detect large gaps between consecutive ticks ─────────────
  // Fires only when the main thread was blocked >40ms between ticks.
  static CFAbsoluteTime _lastTickTime = 0;
  CFAbsoluteTime _tickNow = CFAbsoluteTimeGetCurrent();
  if (_lastTickTime > 0) {
    double gapMs = (_tickNow - _lastTickTime) * 1000.0;
    if (gapMs > 40.0) {
      NSLog(@"[VanguardRenderer] TICK-GAP %.1fms at CAT=%.3f", gapMs, _tickNow);
    }
  }
  _lastTickTime = _tickNow;

  // ── Step 1: masterClock ───────────────────────────────────────────────────
  CFAbsoluteTime _ta = CFAbsoluteTimeGetCurrent();
  double t = _timeProvider();
  double _taMs = (CFAbsoluteTimeGetCurrent() - _ta) * 1000.0;
  if (_taMs > 5.0) {
    NSLog(@"[VanguardRenderer] _timeProvider slow: %.1fms", _taMs);
  }

  double displayDuration =
      _playbackRate > 0 ? _videoDuration / _playbackRate : _videoDuration;

  if (t > displayDuration) {
    if (!_playbackCompleted) {
      _playbackCompleted = YES;
      [_methodChannel invokeMethod:@"onPlaybackComplete" arguments:nil];
    }
    CFAbsoluteTime _tx = CFAbsoluteTimeGetCurrent();
    [_textureRegistry textureFrameAvailable:_textureId];
    double _txMs = (CFAbsoluteTimeGetCurrent() - _tx) * 1000.0;
    if (_txMs > 5.0) {
      NSLog(@"[VanguardRenderer] textureFrameAvailable(EOS) slow: %.1fms",
            _txMs);
    }
    return;
  }

  _currentTime = t;

  // ── Step 2: renderFrameAtSourceTime ──────────────────────────────────────
  double sourceT = t * _playbackRate;
  CFAbsoluteTime _tb = CFAbsoluteTimeGetCurrent();
  [self _renderFrameAtSourceTime:sourceT];
  double _tbMs = (CFAbsoluteTimeGetCurrent() - _tb) * 1000.0;
  if (_tbMs > 5.0) {
    NSLog(@"[VanguardRenderer] _renderFrameAtSourceTime slow: %.1fms", _tbMs);
  }

  // ── Step 3: textureFrameAvailable ────────────────────────────────────────
  // NOTE: textureFrameAvailable is NOT called here. It is called from the
  // dispatch_async(main) block inside _onVideoFrame: (see below) so that
  // Flutter is notified ONLY when an actual decoded frame has landed, at
  // real frame-rate (≤30fps). Calling it here at 60fps with no new frame
  // causes IntegrationTestWidgetsFlutterBinding to drive the Dart/UI isolate
  // synchronously on the platform (main) thread, blocking
  // getMasterClockSeconds() during the T3 settle window — the G-02-T3 deadlock.
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - P5: Safe Filter Chain Replacement
// ─────────────────────────────────────────────────────────────────────────────

/// Replaces the filter chain, guaranteeing that all nodes being REMOVED have
/// their in-flight async work cancelled BEFORE the chain pointer is swapped.
///
/// Ordering guarantee (enforced, not conventional):
///   1. Compute the set of nodes present in current chain but absent in
///   newChain.
///   2. Call [node invalidate] synchronously on each \u2014 cancels
///   CoreML/Vision requests.
///   3. dispatch_barrier_async on the source decode queue to swap _filterChain.
///      The barrier ensures _onVideoFrame: cannot be mid-execution during the
///      swap.
///
/// Thread-safe: may be called from any thread.
- (void)replaceFilterChain:(NSArray<id<VanguardFilterNode>> *)newChain {
  NSSet *newSet = [NSSet setWithArray:newChain];

  dispatch_queue_t decodeQ = nil;
  if ([_source isKindOfClass:[VanguardFileMediaSource class]]) {
    decodeQ = ((VanguardFileMediaSource *)_source).videoDecodeQueue;
  }

  if (decodeQ) {
    NSArray *safeChain = [newChain copy];
    // FIX-E: Take the current-chain snapshot AND invalidate removed nodes
    // inside a dispatch_sync on videoDecodeQueue. This gives the snapshot
    // serial ordering with respect to both concurrent replaceFilterChain:
    // callers and in-flight _onVideoFrame: executions. The sync completes
    // before the barrier is enqueued, preserving the invalidate-before-swap
    // guarantee.
    dispatch_sync(decodeQ, ^{
      NSArray<id<VanguardFilterNode>> *current = self->_filterChain ?: @[];
      for (id<VanguardFilterNode> node in current) {
        if (![newSet containsObject:node]) {
          [node invalidate];
        }
      }
    });
    dispatch_barrier_async(decodeQ, ^{
      self->_filterChain = safeChain;
    });
  } else {
    // Camera source or unknown -- no serial decode queue; caller is always main
    // (thermal observer and plugin handler both are on main before calling
    // here).
    NSArray<id<VanguardFilterNode>> *current = _filterChain ?: @[];
    for (id<VanguardFilterNode> node in current) {
      if (![newSet containsObject:node]) {
        [node invalidate];
      }
    }
    _filterChain = [newChain copy];
  }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Frame Callbacks from Source
// ─────────────────────────────────────────────────────────────────────────────

/// Fired by the source on its decode queue (not main thread).
- (void)_onVideoFrame:(CVPixelBufferRef)rawFrame pts:(CMTime)pts {
  __weak __typeof(self) weakSelf = self;
  _lastDecodedPTS = CMTimeGetSeconds(pts);
  CVPixelBufferRef frame = rawFrame;

  // [VANGUARD_DIAG_COLOR] remove after color investigation
  {
    static int _vdcFrameCount = 0;
    if (_vdcFrameCount < 10) {
      _vdcFrameCount++;
      NSLog(@"[VANGUARD_DIAG_COLOR] frameIndex=%d", _vdcFrameCount);
      OSType pixFmt = CVPixelBufferGetPixelFormatType(rawFrame);
      size_t dw = CVPixelBufferGetWidth(rawFrame);
      size_t dh = CVPixelBufferGetHeight(rawFrame);
      NSLog(@"[VANGUARD_DIAG_COLOR] pixelFormat=%u width=%zu height=%zu",
            (unsigned)pixFmt, dw, dh);
      CVPixelBufferLockBaseAddress(rawFrame, kCVPixelBufferLock_ReadOnly);
      uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(rawFrame);
      if (base) {
        NSLog(@"[VANGUARD_DIAG_COLOR] pixel[0] B=%d G=%d R=%d A=%d",
              (int)base[0], (int)base[1], (int)base[2], (int)base[3]);
      }
      CVPixelBufferUnlockBaseAddress(rawFrame, kCVPixelBufferLock_ReadOnly);
      CFStringRef primaries = CVBufferCopyAttachment(
          rawFrame, kCVImageBufferColorPrimariesKey, NULL);
      CFStringRef transfer = CVBufferCopyAttachment(
          rawFrame, kCVImageBufferTransferFunctionKey, NULL);
      CFStringRef matrix =
          CVBufferCopyAttachment(rawFrame, kCVImageBufferYCbCrMatrixKey, NULL);
      NSLog(@"[VANGUARD_DIAG_COLOR] primaries=%@  transfer=%@  matrix=%@",
            (__bridge NSString *)primaries, (__bridge NSString *)transfer,
            (__bridge NSString *)matrix);
      BOOL isHLG = transfer && CFGetTypeID(transfer) == CFStringGetTypeID() &&
                   CFStringCompare(
                       transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                       0) == kCFCompareEqualTo;
      NSLog(@"[VANGUARD_DIAG_COLOR] isHLG=%@", isHLG ? @"YES" : @"NO");
      if (primaries)
        CFRelease(primaries);
      if (transfer)
        CFRelease(transfer);
      if (matrix)
        CFRelease(matrix);
    }
  }
  // [VANGUARD_DIAG_COLOR end]

  // P1-T3: Apply filter chain (empty in Phase 1 — zero cost)
  if (_filterChainEnabled && _filterChain.count > 0) {
    for (id<VanguardFilterNode> node in _filterChain) {
      if (!node.enabled)
        continue;
      CVPixelBufferRef out = [node processBuffer:frame
                                          atTime:pts
                                          device:_device];
      // FIX-C: NULL guard — a filter node may return NULL under memory pressure
      // (e.g. ML input pool exhaustion) or after invalidate(). Without this
      // check CVPixelBufferRetain(NULL) below crashes on some OS versions, and
      // passing NULL into the next node is undefined behaviour. On NULL:
      // release any in-flight intermediate and fall through with the last valid
      // frame.
      if (!out) {
        if (frame != rawFrame)
          CVPixelBufferRelease(frame); // release dangling intermediate
        frame = rawFrame; // revert to the original unfiltered frame
        break;            // skip remaining nodes; deliver raw frame
      }
      if (frame != rawFrame)
        CVPixelBufferRelease(frame); // release previous intermediate
      frame = out;
    }
  }

  // Detect HLG from the live source frame for GPU-side colour correction.
  CFStringRef _hlgTransfer =
      CVBufferCopyAttachment(rawFrame, kCVImageBufferTransferFunctionKey, NULL);
  uint32_t isHLGFrame =
      (_hlgTransfer &&
       CFStringCompare(_hlgTransfer,
                       kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                       0) == kCFCompareEqualTo)
          ? 1
          : 0;
  if (_hlgTransfer)
    CFRelease(_hlgTransfer);

  // GPU rotation/colour pass — live preview only.
  // Seek frames arrive already display-sized (from _pixelBufferFromCGImage:),
  // so we skip rotation when incoming dimensions already match _renderSize.
  // Live frames arrive at naturalSize (sensor dimensions). Only live frames
  // with a non-identity rotation need the GPU blit pass.
  // HLG identity clips (rotationIndex==0) also route through the GPU blit so
  // the fragment shader can apply the HLG→sRGB colour correction.
  if ((_rotationIndex != 0 || isHLGFrame) && _renderSize.width > 0) {
    size_t fw = CVPixelBufferGetWidth(frame);
    size_t fh = CVPixelBufferGetHeight(frame);
    BOOL alreadyDisplaySized =
        (fw == (size_t)_renderSize.width && fh == (size_t)_renderSize.height);
    // HLG identity clips ARE already display-sized but still need the colour
    // correction pass — skip the size guard for that case only.
    if (!alreadyDisplaySized || (isHLGFrame && _rotationIndex == 0)) {
      CVPixelBufferRef rotated = [self _rotatePixelBufferGPU:frame
                                                       isHLG:isHLGFrame];
      if (rotated) {
        if (frame != rawFrame)
          CVPixelBufferRelease(frame);
        frame = rotated; // rotated is retained by _rotatePixelBufferGPU:
      }
      // On GPU failure, fall through with original frame (safe degraded
      // output).
    }
  }

  // P0-T7: Swap _latestPixelBuffer with os_unfair_lock
  CVPixelBufferRef old = NULL;
  os_unfair_lock_lock(&_pixelBufferLock);
  old = _latestPixelBuffer;
  _latestPixelBuffer = CVPixelBufferRetain(frame);
  os_unfair_lock_unlock(&_pixelBufferLock);
  if (old)
    CVPixelBufferRelease(old);
  if (frame != rawFrame)
    CVPixelBufferRelease(frame);

  // Caller passed a retained pixel buffer. We must release it now that we've
  // either retained it into `_latestPixelBuffer` or discarded it.
  CVPixelBufferRelease(rawFrame);

  // Notify Flutter to pull the latest buffer.
  // IMPORTANT: called here (on the actual frame-decode completion) rather than
  // in _displayLinkFired so that Flutter is only woken at real frame-rate.
  // Calling textureFrameAvailable at 60fps from the display link (even with no
  // new frame) drove IntegrationTestWidgetsFlutterBinding to pump the
  // Dart/UI isolate synchronously on the platform thread, permanently blocking
  // getMasterClockSeconds() during the G-02-T3 settle window.
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong __typeof(weakSelf) strong = weakSelf;
    if (!strong)
      return;
    strong->_isFetchingFrame = NO;
    [strong->_textureRegistry textureFrameAvailable:strong->_textureId];
  });
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Sequential playback frame pull (CADisplayLink path)
// ─────────────────────────────────────────────────────────────────────────────

- (void)_renderFrameAtSourceTime:(double)sourceSeconds {
  // For the sequential playback path (not seek), pull from AVAssetReader via
  // source.
  if ([_source isKindOfClass:[VanguardFileMediaSource class]]) {
    if (_isFetchingFrame)
      return; // Primary guard: only ONE async pull in flight at any time.

    // Gate 1 (post-seek flood prevention):
    // After a seek to _seekTargetPTS, readNextFrameForPlayback fast-forwards
    // the sequential reader on the decode queue. During that one pull,
    // _isFetchingFrame=YES so we're guarded above. If for any reason
    // _lastDecodedPTS is still far below the seek target (e.g. the fast-forward
    // loop hasn't fired yet), suppress additional pulls to protect the main
    // queue. _seekTargetPTS is cleared once _lastDecodedPTS is close to the
    // target.
    if (_seekTargetPTS > 0) {
      if (_lastDecodedPTS < _seekTargetPTS - 0.066) {
        // Still recovering: allow at most ONE pull (already guarded by
        // _isFetchingFrame above). If we somehow reach here with
        // _isFetchingFrame=NO AND _lastDecodedPTS<<target, that means the
        // fast-forward hasn't completed yet — do nothing this tick.
        return;
      }
      _seekTargetPTS = 0; // _lastDecodedPTS has caught up: clear gate.
    }

    // Gate 2 (normal throttle): only fetch if master clock has advanced past
    // the last decoded frame.
    if (_lastDecodedPTS <= sourceSeconds + 0.016) {
      _isFetchingFrame = YES;
      [(VanguardFileMediaSource *)_source pullNextFrameAsync];
    }
  }
  // Camera source: frames arrive via _videoCallback at capture rate — no pull
  // needed.
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - FlutterTexture Protocol
// ─────────────────────────────────────────────────────────────────────────────

// P0-T7: os_unfair_lock — priority-aware; non-recursive.
// The Flutter rasterizer thread (high priority) is always served before decode
// thread.
- (CVPixelBufferRef _Nullable)copyPixelBuffer {
  os_unfair_lock_lock(&_pixelBufferLock);
  CVPixelBufferRef result =
      _latestPixelBuffer ? CVPixelBufferRetain(_latestPixelBuffer) : NULL;
  os_unfair_lock_unlock(&_pixelBufferLock);

  return result;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Memory Pressure (P0-T5)
// ─────────────────────────────────────────────────────────────────────────────

- (void)handleMemoryPressure {
  [_source stop]; // drains AVAssetReader (T2 lives in VanguardFileMediaSource)

  os_unfair_lock_lock(&_pixelBufferLock);
  if (_latestPixelBuffer) {
    CVPixelBufferRelease(_latestPixelBuffer);
    _latestPixelBuffer = NULL;
  }
  os_unfair_lock_unlock(&_pixelBufferLock);

  if (_pixelBufferPool) {
    CVPixelBufferPoolFlush(_pixelBufferPool,
                           kCVPixelBufferPoolFlushExcessBuffers);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Dispose
// ─────────────────────────────────────────────────────────────────────────────

- (void)dispose {
  [self pause];   // also calls [_source stop]
  [_source stop]; // idempotent; ensure stopped even if not playing

  if (_displayLink) {
    [_displayLink invalidate];
    _displayLink = nil;
  }

  os_unfair_lock_lock(&_pixelBufferLock);
  if (_latestPixelBuffer) {
    CVPixelBufferRelease(_latestPixelBuffer);
    _latestPixelBuffer = NULL;
  }
  os_unfair_lock_unlock(&_pixelBufferLock);

  if (_pixelBufferPool) {
    CVPixelBufferPoolFlush(_pixelBufferPool, 0);
    CFRelease(_pixelBufferPool);
    _pixelBufferPool = NULL;
  }
  if (_textureCache) {
    CVMetalTextureCacheFlush(_textureCache, 0);
    CFRelease(_textureCache);
    _textureCache = NULL;
  }
  [_textureRegistry unregisterTexture:_textureId];
}

/// Async dispose — the ONLY entry point used by the MethodChannel `dispose`
/// case. Guarantees that Dart's `await disposeTexture()` does NOT return until
/// T1's _decodeQueue has fully drained. This eliminates the circular
/// mediaserverd deadlock: T2 cannot call startAndReturnError: while T1 still
/// holds a decode slot.
- (void)disposeAsync:(dispatch_block_t)completion {
  // 1. Perform all synchronous GPU teardown (DisplayLink, PixelBuffer, pool,
  // etc.)
  //    This also calls [_source stop] which: sets _schedulingChunks=NO,
  //    nil-ifies _audioAssetReader/_videoOutput, and dispatches cancelReading
  //    onto _decodeQueue as an async block.
  [self dispose];

  // PATCH-3: Drain _videoDecodeQueue — not _decodeQueue (audio).
  // [_source stop] dispatches _drainAndCancelAssetReader to _videoDecodeQueue.
  // A sentinel on _decodeQueue has no ordering relationship with that work:
  // the two queues are independent serial queues. The sentinel must target
  // _videoDecodeQueue so Dart is not unblocked before cancelReading completes.
  dispatch_queue_t videoDecodeQ = nil;
  if ([_source isKindOfClass:[VanguardFileMediaSource class]]) {
    videoDecodeQ = ((VanguardFileMediaSource *)_source).videoDecodeQueue;
  }

  if (videoDecodeQ) {
    NSLog(@"[VanguardRenderer] disposeAsync: waiting for videoDecodeQueue "
          @"drain...");
    dispatch_async(videoDecodeQ, ^{
      // ─ videoDecodeQueue is now idle: cancelReading has completed ─
      NSLog(@"[VanguardRenderer] disposeAsync: videoDecodeQueue drained — "
            @"signalling Dart");
      dispatch_async(dispatch_get_main_queue(), ^{
        if (completion)
          completion();
      });
    });
  } else {
    // Camera source or unknown source — no videoDecodeQueue, invoke
    // immediately.
    dispatch_async(dispatch_get_main_queue(), ^{
      if (completion)
        completion();
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Test Accessors
// ─────────────────────────────────────────────────────────────────────────────

- (int)outputTextureWidth {
  return _outputTexture ? (int)_outputTexture.width : 0;
}
- (int)outputTextureHeight {
  return _outputTexture ? (int)_outputTexture.height : 0;
}

@end
