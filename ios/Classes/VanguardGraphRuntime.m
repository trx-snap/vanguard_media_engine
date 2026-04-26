// TRANSITIONAL WRAPPER — Phase 1 only. Internals will be replaced in Phase 2.
//
// VanguardGraphRuntime.m
// Vanguard Media Engine — Phase 1B, P1B-01
//
// Thin coordinator that delegates to VanguardMetalRenderer and the appropriate
// Vanguard source class. Proofs that the VGGraphRuntime contract works
// end-to-end without altering any production code paths (C-2, C-4, C-6).
//
// Pixel-buffer pool is sourced exclusively from [VGResourceAllocator
// sharedInstance], ending the pool-backfill hack
// (VanguardFileMediaSource.pixelBufferPool write site is no longer required in
// this code path).
//
// Constraints honoured:
//   C-2  — not wired to any plugin/production path.
//   C-4  — zero opportunistic fixes.
//   C-6  — VanguardMetalRenderer, VanguardEngineMode shim, camera/export files
//   untouched.

#import "VanguardGraphRuntime.h"

// Vanguard concrete classes
#import "VanguardFileMediaSource.h"
#import "VanguardImageMediaSource.h"
#import "VanguardImageProcessor.h"
#import "VanguardMetalRenderer.h"
#import "VanguardGraphScheduler.h" // P4-3

// UMF shared infrastructure
#import <UMF/VGResourceAllocator.h>
#import <stdatomic.h>

// Package-internal: serial queue shared with VanguardFileMediaSource for
// audio engine stop + pixel buffer pool release serialization.
// Defined in VanguardFileMediaSource.m; extern linkage keeps them on the
// same queue without requiring a shared header.
extern dispatch_queue_t VanguardAudioTeardownQueue(void);

// ─── Image-type UTI helpers
// ─────────────────────────────────────────────────── A lightweight set of
// known image extensions; avoids importing MobileCoreServices.
static BOOL VGRIsImageURL(NSURL *url) {
  static NSSet<NSString *> *kImageExtensions;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    kImageExtensions =
        [NSSet setWithObjects:@"jpg", @"jpeg", @"png", @"heic", @"heif",
                              @"webp", @"gif", @"tif", @"tiff", @"bmp", nil];
  });
  return [kImageExtensions containsObject:url.pathExtension.lowercaseString];
}

// ─── VanguardGraphRuntime (private extension)
// ─────────────────────────────────

@interface VanguardGraphRuntime ()

// Flutter dependencies — injected at init, never nil after init.
@property(nonatomic, strong, readonly) id<FlutterTextureRegistry>
    textureRegistry;
@property(nonatomic, strong, readonly) FlutterMethodChannel *methodChannel;

// Live graph components — nil until prepareWithURL:completion: succeeds.
@property(nonatomic, strong, nullable) VanguardMetalRenderer *renderer;
@property(nonatomic, strong, nullable) id<VanguardMediaSource, VGMediaNode>
    source;

// Pool acquired from VGResourceAllocator — runtime owns the +1 reference
// for the session lifetime; released in _teardownResources.
@property(nonatomic, assign, nullable) CVPixelBufferPoolRef sessionPool;

// Redeclare base-class properties as readwrite for internal mutation.
@property(nonatomic, readwrite) VGRuntimeState state;
@property(nonatomic, readwrite) int64_t textureId;
@property(nonatomic, readwrite, nullable) id<VGMasterClock> masterClock;

// Phase 2 audio role — readwrite internally; readonly on public interface.
@property(nonatomic, readwrite) VGAudioRole desiredAudioRole;
@property(atomic, readwrite) VGAudioRole effectiveAudioRole;
@property(nonatomic, readwrite) CGSize renderSize;

// Preparation + post-prepare serial queue.
@property(nonatomic, strong) dispatch_queue_t prepareQueue;

// P3-3 TRANSITIONAL — remove in Phase 4 (DEC-50, RR-31).
// Logical owner of the runtime filter chain. Forwarded to renderer on mutation.
@property(nonatomic, strong, nullable)
    NSArray<id<VGMetalFilterNode>> *filterChainStorage;

// P4-3: Dormant scheduler. Created in prepareWithURL:, torn down in
// invalidate/dealloc. Does NOT drive frame execution (that is P4-5+).
@property(nonatomic, strong, nullable) VanguardGraphScheduler *scheduler;

@end

// ─── VGGraphRuntime Base Implementation
// ───────────────────────────────────────── UMF constraint C-7 dictates no
// @implementation inside UMF. But Objective-C requires it for
// VanguardGraphRuntime to subclass it.
@implementation VGGraphRuntime
@end

// ─── VanguardGraphRuntime
// ─────────────────────────────────────────────────────

@implementation VanguardGraphRuntime {
  // Atomic invalidation flag. Written exactly once (YES) in -invalidate.
  // Declared in .m so it is not part of the frozen public header.
  _Atomic(BOOL) _invalidated;
}

@synthesize state = _vg_state;
@synthesize textureId = _vg_textureId;
@synthesize masterClock = _vg_masterClock;
@synthesize desiredAudioRole = _desiredAudioRole;
@synthesize effectiveAudioRole = _effectiveAudioRole;
@synthesize renderSize = _renderSize;

// ─── Init
// ──────────────────────────────────────────────────────────────────────

/// Phase 2 designated initialiser — stores the desired audio role.
- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                          methodChannel:(FlutterMethodChannel *)channel
                       desiredAudioRole:(VGAudioRole)role {
  NSParameterAssert(registry != nil);
  NSParameterAssert(channel != nil);

  self = [super init];
  if (!self)
    return nil;

  _textureRegistry = registry;
  _methodChannel = channel;
  _desiredAudioRole = role;
  // Conservative default — prepare() resolves the effective role through the
  // allocator.
  _effectiveAudioRole = VGAudioRoleMuted;
  _vg_state = VGRuntimeStateIdle;
  _vg_textureId = -1;
  _invalidated = NO;
  _renderSize = CGSizeZero;

  // Serial FIFO queue for source/renderer setup and post-prepare operations.
  _prepareQueue = dispatch_queue_create("com.vanguard.graph_runtime.prepare",
                                        DISPATCH_QUEUE_SERIAL);

  return self;
}

/// Phase 1 compatible convenience initialiser. Defaults to VGAudioRoleActive.
- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                          methodChannel:(FlutterMethodChannel *)channel {
  return [self initWithTextureRegistry:registry
                         methodChannel:channel
                      desiredAudioRole:VGAudioRoleActive];
}

// ─── prepareWithURL:completion:
// ───────────────────────────────────────────────

- (void)prepareWithURL:(NSURL *)url
            completion:(void (^)(int64_t textureId,
                                 NSError *_Nullable error))completion {

  NSParameterAssert(url != nil);
  NSParameterAssert(completion != nil);

  // Dispatch all setup off the calling thread (contract: completion fires on
  // a background queue, never synchronously on the caller).
  dispatch_async(_prepareQueue, ^{
    NSLog(@"[TRACE][N3] runtime.prepare entered url=%@", url.lastPathComponent);

    // Guard against invalidate racing with prepare.
    if (self->_invalidated) {
      NSError *err = [NSError
          errorWithDomain:@"VanguardGraphRuntimeErrorDomain"
                     code:1
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Runtime already invalidated."
                 }];
      completion(-1, err);
      return;
    }

    // ── 1. Source the pixel buffer pool from VGResourceAllocator ──────────
    //
    //    We obtain a pool sized for a common video canvas (1080 × 1920 BGRA).
    //    In Phase 2 this will be driven by the actual source render size.
    //    The pool is held by the runtime for the session lifetime.
    VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];
    CVPixelBufferPoolRef pool =
        [allocator pixelBufferPoolWithWidth:1080
                                     height:1920
                                     format:kCVPixelFormatType_32BGRA];
    // pool carries a +1 retain (CF_RETURNS_RETAINED from
    // pixelBufferPoolWithWidth). sessionPool is declared `assign` — it does NOT
    // add a CF retain. Do NOT call CVPixelBufferPoolRelease here: that would
    // immediately free the pool, leaving self.sessionPool as a dangling pointer
    // for the entire session. The +1 is kept alive intentionally; it is
    // consumed (noop'd as intentional leak) in invalidateAsync's
    // afterCompletion block (IOSurface fence safety).
    self.sessionPool = pool;

    // ── 1.5 Resolve effective audio role through VGResourceAllocator ──────
    //
    // This must happen before source construction so the resolved role can be
    // passed into VanguardFileMediaSource via the 3-arg designated initialiser.
    // (Step-enforced blocker RR-06 is satisfied by the prepareQueue dispatch
    // above.)
    VGAudioRole resolvedRole;
    if (self->_desiredAudioRole == VGAudioRoleActive) {
      BOOL granted =
          [[VGResourceAllocator sharedInstance] requestAudioActivation:self];
      resolvedRole = granted ? VGAudioRoleActive : VGAudioRoleMuted;
    } else {
      resolvedRole = VGAudioRoleMuted;
    }
    self.effectiveAudioRole = resolvedRole; // atomic setter

    // ── 2. Construct the appropriate source class ─────────────────────────

    NSError *sourceError = nil;

    if (VGRIsImageURL(url)) {
      // ── Image source ──────────────────────────────────────────────────
      VanguardImageProcessor *processor =
          [[VanguardImageProcessor alloc] initWithDevice:allocator.metalDevice
                                                    pool:self.sessionPool];
      VanguardImageMediaSource *imageSrc =
          [[VanguardImageMediaSource alloc] initWithURL:url
                                              processor:processor];
      self.source = (id<VanguardMediaSource, VGMediaNode>)imageSrc;

    } else {
      // ── File / video source ───────────────────────────────────────────
      // Phase 2: use 3-arg init to pass resolved role at construction time.
      // This ensures _setupAudioEngine role gate is correctly set before
      // prepareWithCompletion: runs any AVFoundation setup.
      VanguardFileMediaSource *fileSrc =
          [[VanguardFileMediaSource alloc] initWithURL:url
                                       pixelBufferPool:self.sessionPool
                                      desiredAudioRole:resolvedRole];
      self.source = (id<VanguardMediaSource, VGMediaNode>)fileSrc;
    }

    if (!self.source) {
      sourceError =
          [NSError errorWithDomain:@"VanguardGraphRuntimeErrorDomain"
                              code:2
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Failed to create media source for URL."
                          }];
      completion(-1, sourceError);
      return;
    }

    // ── 3. Warm up the source via VGMediaNode.prepareWithCompletion: ──────

    // semaphore lets us stay on _prepareQueue without nesting queues.
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSError *prepError = nil;

    [self.source prepareWithCompletion:^(NSError *_Nullable error) {
      prepError = error;
      dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (prepError || self->_invalidated) {
      NSError *err =
          prepError
              ?: [NSError errorWithDomain:@"VanguardGraphRuntimeErrorDomain"
                                     code:1
                                 userInfo:@{
                                   NSLocalizedDescriptionKey :
                                       @"Runtime invalidated during prepare."
                                 }];
      completion(-1, err);
      return;
    }

    // ── 3.5 Phase 2 migration glue ─────────────────────────────────────────
    //
    // Push owning runtime reference into source so _teardownAudioEngine can
    // call relinquishAudioActivation: on the correct allocator slot.
    // For VanguardFileMediaSource, effectiveAudioRole was already set via the
    // 3-arg init; we re-push for consistency and to support image sources.
    if ([self.source respondsToSelector:@selector(setOwningRuntime:)]) {
      [(id)self.source setOwningRuntime:self];
    }
    if ([self.source respondsToSelector:@selector(setEffectiveAudioRole:)]) {
      [(id)self.source setEffectiveAudioRole:resolvedRole];
    }

    // Capture render size from source now that preparation has completed.
    // Falls back to a safe 1080×1920 default for sources that do not expose it.
    {
      CGSize sz = CGSizeZero;
      if ([self.source respondsToSelector:@selector(renderSize)]) {
        sz = [(id)self.source renderSize];
      }
      self->_renderSize =
          (sz.width > 0 && sz.height > 0) ? sz : CGSizeMake(1080.0, 1920.0);
    }

    VanguardMetalRenderer *renderer =
        [[VanguardMetalRenderer alloc] initWithSource:self.source
                                      textureRegistry:self.textureRegistry
                                        methodChannel:self.methodChannel
                                          sessionPool:self.sessionPool];

    if (!renderer || self->_invalidated) {
      NSLog(@"[VanguardGraphRuntime] FATAL: renderer nil or invalidated — "
            @"aborting prepare");
      NSError *err =
          [NSError errorWithDomain:@"VanguardGraphRuntimeErrorDomain"
                              code:3
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Failed to create VanguardMetalRenderer."
                          }];
      completion(-1, err);
      return;
    }

    self.renderer = renderer;

    // ── 5. Capture textureId and expose masterClock ───────────────────────

    int64_t tid = renderer.textureId;
    self.textureId = tid;

    // VanguardFileMediaSource conforms to VanguardAudioEngine which vends a
    // masterClock. We resolve it via the VGMasterClock protocol if possible.
    BOOL sourceConformsClock =
        [self.source conformsToProtocol:@protocol(VGMasterClock)];
    if (sourceConformsClock) {
      self.masterClock = (id<VGMasterClock>)self.source;
    }
    // VanguardFileMediaSource.masterClock returns CMTime (a struct), not
    // id<VGMasterClock>. No further resolution path exists — runtime
    // masterClock stays nil for this source type.

    // ── 6. Transition state ───────────────────────────────────────────────

    // P4-3: Create scheduler. P4-5: Wire sink and delegate, then start.
    self.scheduler = [[VanguardGraphScheduler alloc] init];

    // P4-5: Wire the scheduler–renderer handoff.
    //   scheduler.sink = renderer — scheduler delivers to renderer via presentEnvelope:
    //   renderer.frameDelegate = scheduler — renderer forwards raw frames to scheduler
    // Both are weak refs; runtime owns both objects for the session lifetime.
    self.scheduler.sink    = renderer;
    renderer.frameDelegate = self.scheduler;

    // P4-5: Start the scheduler — supplies clock and Metal device via the
    // VGGraphScheduler protocol (VGGraphScheduler.h:16). The device is the
    // same allocator.metalDevice already used for the pixel buffer pool.
    // clock may be nil for image sources; startWithClock:device: guards this.
    id<MTLDevice> schedulerDevice = allocator.metalDevice;
    if (schedulerDevice) {
      [self.scheduler startWithClock:self.masterClock device:schedulerDevice];
    }

    self.state = VGRuntimeStatePrepared;
    completion(tid, nil);
  });
}

// ─── Playback control — main thread only
// ──────────────────────────────────────

- (void)play {
  NSAssert([NSThread isMainThread],
           @"VanguardGraphRuntime.play must be called on the main thread.");
  if (_invalidated || !_renderer) {
    return;
  }
  [_renderer play];
  self.state = VGRuntimeStateRunning;
}

- (void)pause {
  NSAssert([NSThread isMainThread],
           @"VanguardGraphRuntime.pause must be called on the main thread.");
  if (_invalidated || !_renderer) {
    return;
  }
  [_renderer pause];
  self.state = VGRuntimeStatePaused;
}

- (void)seekTo:(double)seconds {
  NSAssert([NSThread isMainThread],
           @"VanguardGraphRuntime.seekTo: must be called on the main thread.");
  if (_invalidated || !_renderer)
    return;

  [_renderer seek:seconds];
  // State remains as-is (running stays running; paused stays paused).
}

// ─── invalidate — thread-safe, idempotent
// ─────────────────────────────────────

- (void)invalidate {
  // Atomically set _invalidated = YES. This is the sentinel that makes all
  // other methods no-ops from this point forward.
  // Order is mandated by AC-5: set flag FIRST, dispose renderer, then source.
  BOOL alreadyInvalidated = atomic_exchange(&_invalidated, YES);
  if (alreadyInvalidated) {
    return; // Idempotent — second call is a no-op.
  }

  // Phase 2 (Step 3): relinquish the audio activation slot as the very first
  // teardown action. This frees the slot for the next session immediately,
  // independent of how long the remaining renderer/source teardown takes.
  [[VGResourceAllocator sharedInstance] relinquishAudioActivation:self];

  // Capture locals so ARC does not race with the nil-out below.
  VanguardMetalRenderer *renderer = _renderer;
  id<VanguardMediaSource, VGMediaNode> source = _source;

  _renderer = nil;
  _source = nil;

  // Dispose renderer synchronously (tears down GPU state and unregisters
  // texture).
  [renderer dispose];
  [source invalidate];
  // Pool release deferred to invalidateAsync's post-completion callback.
  // (See INV_C comment — IOSurface fence safety.)

  // P4-3: Tear down dormant scheduler.
  [self.scheduler invalidate];
  self.scheduler = nil;

  self.state = VGRuntimeStateIdle;
}

// ─── transitionToRole:completion: (Phase 2, Step 3) ─────────────────────────

- (void)transitionToRole:(VGAudioRole)role
              completion:(nullable void (^)(BOOL success))completion {
  dispatch_async(_prepareQueue, ^{
    // Guard: no transitions after invalidation.
    if (self->_invalidated) {
      if (completion)
        completion(NO);
      return;
    }

    // Already at the requested role — nothing to do.
    if (self.effectiveAudioRole == role) {
      if (completion)
        completion(YES);
      return;
    }

    id<VanguardMediaSource, VGMediaNode> source = self.source;

    if (role == VGAudioRoleMuted) {
      // Demote: deactivate audio engine and release allocator slot.
      if ([source respondsToSelector:@selector(deactivateAudioIfNeeded)]) {
        [(id)source deactivateAudioIfNeeded];
      }
      self.effectiveAudioRole = VGAudioRoleMuted;
      if (completion)
        completion(YES);

    } else {
      // Promote: attempt to acquire slot, then activate source audio.
      BOOL granted =
          [[VGResourceAllocator sharedInstance] requestAudioActivation:self];
      if (!granted) {
        if (completion)
          completion(NO);
        return;
      }
      if ([source respondsToSelector:@selector(activateAudioIfNeeded)]) {
        [(id)source activateAudioIfNeeded];
      }
      self.effectiveAudioRole = VGAudioRoleActive;
      if (completion)
        completion(YES);
    }
  });
}

// ─── invalidateAsync: (Phase 2, Step 3)
// ───────────────────────────────────────

- (void)invalidateAsync:(dispatch_block_t)completion {
  // Capture source and renderer strongly on the caller thread BEFORE
  // dispatching. invalidate will nil both _source and _renderer; we need
  // the pre-invalidate values for the drain step and post-completion cleanup.
  id<VanguardMediaSource, VGMediaNode> capturedSource = _source;
  VanguardMetalRenderer *capturedRenderer = _renderer;
  // Capture the session pool HERE, before invalidate nils _sessionPool via
  // _releaseSessionPool. We release it AFTER result(nil) reaches Dart so that
  // the IOSurface kernel reclamation cannot freeze the process before Dart
  // unblocks. _releaseSessionPool is skipped inside invalidate (see comment
  // at INV_C).
  CVPixelBufferPoolRef capturedPool = _sessionPool;
  _sessionPool = NULL;

  dispatch_async(_prepareQueue, ^{
    NSLog(@"[TRACE][IA1] invalidate started on prepareQueue");
    [self invalidate];

    dispatch_block_t afterCompletion = ^{
      dispatch_async(dispatch_get_main_queue(), ^{
        if (completion)
          completion();
        [capturedRenderer doUnregisterTexture];
        if (capturedPool) {
          // INTENTIONAL LEAK (KEEP TEMPORARILY): Do NOT call
          // CVPixelBufferPoolRelease. CVPixelBufferPoolRelease triggers
          // IOSurface fence wait in the kernel. When concurrent session is
          // rendering via Metal, fence waits 5+ min. OS reclaims IOSurface/GPU
          // memory at process exit.
          NSLog(@"[VanguardGraphRuntime] pool=%p deferred to process exit "
                @"(IOSurface fence safety)",
                capturedPool);
          (void)capturedPool;
        }
      });
    };

    if (capturedSource && [capturedSource respondsToSelector:@selector
                                          (awaitDecoderDrainWithCompletion:)]) {
      [(id)capturedSource awaitDecoderDrainWithCompletion:afterCompletion];
    } else {
      afterCompletion();
    }
  });
}

// ─── Playback rate and seek-preview forwarding (Phase 2, Step 3)
// ──────────────
//
// Phase 2:
// Playback rate support is infrastructure-only.
// Supported range: 1.0x–2.0x.
// Product behavior (autoplay speed, UX, pitch correction)
// is deferred to later phases.

- (void)setPlaybackRate:(double)rate {
  // Enforce safe rate range: 1.0x–2.0x.
  // Values outside this range are clamped silently — no crash, no assertion.
  // The renderer's own internal clamp is broader; the runtime enforces the
  // tighter Phase 2 contract so the renderer never sees out-of-spec values
  // from this layer.
  rate = MAX(1.0, MIN(rate, 2.0));

  // Safe regardless of runtime state:
  //   - nil before prepare or after invalidate → forwarding is a no-op.
  //   - muted runtime → renderer/source store the rate; applied on activate.
  //   - called on any thread → renderer executes on main (NSAssert inside).
  [_renderer setPlaybackRate:rate];
}

- (void)setSeekPreviewPaused:(BOOL)paused {
  _renderer.seekPreviewPaused = paused;
}

- (BOOL)seekPreviewPaused {
  return _renderer.seekPreviewPaused;
}

// ─── P3-3 TRANSITIONAL filter chain ownership ────────────────────────────────
// Remove in Phase 4 when VGGraphScheduler owns callback interception (DEC-50).

/// Stores the runtime-owned UMF filter chain and forwards it to the renderer
/// via the narrow Option-B adapter seam (setRuntimeFilterChain:).
///
/// Lifecycle: nodes being removed from the chain have -invalidate called
/// synchronously on the caller thread BEFORE the new chain is forwarded to
/// the renderer. This mirrors the invalidate-before-swap guarantee in
/// replaceFilterChain: (RR-26).
///
/// If the renderer is not yet prepared (nil), the chain is stored and will be
/// applied when prepare completes.
- (void)setFilterChain:(NSArray<id<VGMetalFilterNode>> *)chain {
  NSArray<id<VGMetalFilterNode>> *newChain = chain ? [chain copy] : @[];

  // Invalidate nodes being removed from the chain BEFORE forwarding.
  // This mirrors the replaceFilterChain: invalidate-before-swap guarantee.
  NSArray<id<VGMetalFilterNode>> *current = self.filterChainStorage ?: @[];
  NSSet<id<VGMetalFilterNode>> *newSet = [NSSet setWithArray:newChain];
  for (id<VGMetalFilterNode> node in current) {
    if (![newSet containsObject:node]) {
      [node invalidate];
    }
  }

  // Store as logical owner.
  self.filterChainStorage = newChain;

  // Forward to scheduler ONLY (P4-5: renderer no longer executes filters).
  // RR-31 CLOSED: setRuntimeFilterChain: renderer forward removed.
  [self.scheduler setFilterChain:newChain];
}

// ─── P3-4 Thermal back-pressure
// ────────────────────────────────────────────────

/// Applies the 3-tier thermal degradation policy to all VGMetalFilterNode
/// objects in filterChainStorage. Does NOT swap or invalidate the chain — only
/// toggles node.enabled to adjust GPU load.
///
/// Tier policy (mirrors VGPluginLifecycleObserver G-04 handler):
///   nominal / fair   → all nodes enabled
///   serious          → segmentation node(s) disabled; LUT and Beauty remain
///   active critical         → all nodes disabled (chain stays in place; zero
///   GPU work)
///
/// Thread-safety: called from main thread via VGPluginLifecycleObserver
/// (registered with queue: .main). node.enabled is @property (nonatomic,
/// assign), but since the runtime chain is always accessed from the renderer's
/// videoDecodeQueue for reads, and we only write from main here, the window for
/// a data race is identical to the pre-existing _filterChainEnabled pattern
/// in VanguardMetalRenderer (same queue contract). Acceptable in P3-3/P3-4;
/// Phase 4 scheduler will own this coordination.
- (void)setRuntimeThermalState:(NSProcessInfoThermalState)state {
  NSArray<id<VGMetalFilterNode>> *chain = self.filterChainStorage;
  if (!chain.count)
    return; // no runtime chain — nothing to degrade

  switch (state) {
  case NSProcessInfoThermalStateNominal:
  case NSProcessInfoThermalStateFair:
    // Full quality: enable all runtime filter nodes.
    for (id<VGMetalFilterNode> node in chain) {
      node.enabled = YES;
    }
    NSLog(@"[VanguardGraphRuntime] Thermal ≤Fair → all filter nodes enabled");
    break;

  case NSProcessInfoThermalStateSerious:
    // Reduce GPU load: disable expensive nodes (segmentation: Vision + Metal
    // ≤5ms). Non-expensive nodes (LUT ≤2ms, Beauty ≤3ms) remain active. Node
    // cost is declared via the isExpensive protocol property
    // (VGMetalFilterNode.h). VanguardMLGate handles its own interval step-up
    // independently.
    for (id<VGMetalFilterNode> node in chain) {
      node.enabled = !node.isExpensive;
    }
    NSLog(@"[VanguardGraphRuntime] Thermal Serious → expensive filter nodes "
          @"disabled");
    break;

  case NSProcessInfoThermalStateCritical:
    // Emergency: disable ALL nodes. Chain stays installed (no invalidate, no
    // swap). Frame delivery continues with passthrough — no frame drop.
    // Recovery (nominal/fair above) re-enables nodes without chain re-install.
    for (id<VGMetalFilterNode> node in chain) {
      node.enabled = NO;
    }
    NSLog(
        @"[VanguardGraphRuntime] Thermal Critical → all filter nodes disabled");
    break;

  default:
    break;
  }

  // P4-3: Dual-forward to dormant scheduler. Scheduler stores state only;
  // no execution. Renderer/node logic above remains sole active path.
  [self.scheduler applyThermalState:state];
}

// ─── Private helpers
// ──────────────────────────────────────────────────────────

- (void)_releaseSessionPool {
  if (_sessionPool) {
    CVPixelBufferPoolRef poolToRelease = _sessionPool;
    _sessionPool = NULL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
      CVPixelBufferPoolRelease(poolToRelease);
    });
  }
}

// ─── dealloc
// ──────────────────────────────────────────────────────────────────

- (void)dealloc {
  // Safety net: if the caller forgot to call invalidate, clean up now.
  // We cannot guarantee ordering here, so we do a best-effort teardown
  // without transitioning state (state property may already be gone).
  if (!_invalidated) {
    [_renderer dispose];
    [_source invalidate];
    [self _releaseSessionPool];
  }
  // P4-3: Safety net for scheduler regardless of _invalidated path.
  // invalidate is idempotent so double-call is safe.
  if (self.scheduler) {
    [self.scheduler invalidate];
  }
}

@end
