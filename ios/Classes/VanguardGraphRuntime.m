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
#import "VanguardGraphScheduler.h" // P4-3
#import "VanguardImageMediaSource.h"
#import "VanguardImageProcessor.h"
#import "VanguardMetalRenderer.h"

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

  // P4-8: Idempotency guard for pool release.
  // Written exactly once (YES) by whichever release path fires first —
  // GPU fence addCompletedHandler or dispatch_after fallback.
  // Prevents double-CVPixelBufferPoolRelease and double-reportPoolReleased:.
  // (RR-37 mitigation — DEC-59)
  _Atomic(BOOL) _poolReleased;

  // P4-8: Byte count reserved via canAllocatePoolBytes: at prepare time.
  // poolBytes is a block-local variable in prepareWithURL: and is out of
  // scope at teardown. Storing it here is the only way to pass the correct
  // value to reportPoolReleased: in invalidateAsync and _releaseSessionPool.
  // Zero when no budget was reserved (budget denied or pool creation failed).
  NSUInteger _sessionPoolBytes;
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
  _poolReleased = NO;    // P4-8: reset per-session on each new runtime instance
  _sessionPoolBytes = 0; // P4-8: populated in prepareWithURL: after pool creation
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

    // ── 1. Resolve effective audio role ───────────────────────────────────
    //
    // Audio role must be resolved before source construction so the resolved
    // role can be passed into VanguardFileMediaSource via the 3-arg designated
    // initialiser. (Step-enforced blocker RR-06 is satisfied by the
    // prepareQueue dispatch above.)
    VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];

    VGAudioRole resolvedRole;
    if (self->_desiredAudioRole == VGAudioRoleActive) {
      BOOL granted = [allocator requestAudioActivation:self];
      resolvedRole = granted ? VGAudioRoleActive : VGAudioRoleMuted;
    } else {
      resolvedRole = VGAudioRoleMuted;
    }
    self.effectiveAudioRole = resolvedRole; // atomic setter

    // ── 2. Construct the appropriate source class (nil pool for now) ───────
    //
    // P4-7B: Pool is NOT created yet — we need the actual source renderSize
    // which is only available after prepareWithCompletion: completes.
    // VanguardFileMediaSource.pixelBufferPool is nullable; passing nil here
    // is safe — the source does not dereference the pool until decode begins,
    // which happens only after start() is called (always post-prepare).
    // VanguardImageProcessor also accepts a nil pool at construction; we
    // backfill it below after pool creation (same pattern as before P4-7B).

    NSError *sourceError = nil;
    // Retain processor for image path so we can backfill its pool post-prepare.
    __block VanguardImageProcessor *imageProcessor = nil;

    if (VGRIsImageURL(url)) {
      // ── Image source ──────────────────────────────────────────────────
      // Pool not yet created — processor receives nil pool; backfilled below.
      VanguardImageProcessor *processor =
          [[VanguardImageProcessor alloc] initWithDevice:allocator.metalDevice
                                                    pool:nil];
      imageProcessor = processor;
      VanguardImageMediaSource *imageSrc =
          [[VanguardImageMediaSource alloc] initWithURL:url
                                              processor:processor];
      self.source = (id<VanguardMediaSource, VGMediaNode>)imageSrc;

    } else {
      // ── File / video source ───────────────────────────────────────────
      // Phase 2: use 3-arg init to pass resolved role at construction time.
      // Pool is nil here; backfilled after prepare (P4-7B).
      VanguardFileMediaSource *fileSrc =
          [[VanguardFileMediaSource alloc] initWithURL:url
                                       pixelBufferPool:nil
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

    // ── 3.6 P4-7B: Capture render size and create budget-aware session pool ─
    //
    // Now that prepareWithCompletion: has completed, the source has probed
    // the asset and populated renderSize. We use the actual source dimensions
    // rather than a hardcoded 1080×1920 fallback.

    // (a) Read actual render size — fall back to 1080×1920 if unavailable.
    CGSize renderSz = CGSizeZero;
    if ([self.source respondsToSelector:@selector(renderSize)]) {
      renderSz = [(id)self.source renderSize];
    }
    if (renderSz.width <= 0 || renderSz.height <= 0) {
      NSLog(@"[VanguardGraphRuntime] P4-7B: source renderSize unavailable — "
            @"falling back to 1080×1920");
      renderSz = CGSizeMake(1080.0, 1920.0);
    }
    self->_renderSize = renderSz;

    const size_t poolW = (size_t)renderSz.width;
    const size_t poolH = (size_t)renderSz.height;
    const NSUInteger kBytesPerPixel = 4; // BGRA (ADR-006)

    // (b) Choose initial desired buffer count (DEC-39).
    // Transitional rule: active-audio runtimes may later acquire a filter chain
    // (count=5 is pre-allocated conservatively). Muted runtimes always use 3.
    // Filter-chain-aware sizing is deferred to the P4-9 cost-budget step.
    NSUInteger desiredCount = (resolvedRole == VGAudioRoleActive) ? 5 : 3;

    // (c) Budget check — consult VGResourceAllocator before allocating (RR-29).
    NSUInteger poolBytes = poolW * poolH * kBytesPerPixel * desiredCount;
    BOOL budgetReserved = NO;

    if ([allocator canAllocatePoolBytes:poolBytes]) {
      budgetReserved = YES; // bytes reserved; must create pool or release them
    } else if (desiredCount == 5) {
      // Budget denied at count=5 — try count=3 (RR-25 / DEC-39 fallback).
      NSLog(@"[VanguardGraphRuntime] P4-7B: budget denied at count=5; "
            @"falling back to count=3");
      desiredCount = 3;
      poolBytes = poolW * poolH * kBytesPerPixel * desiredCount;
      if ([allocator canAllocatePoolBytes:poolBytes]) {
        budgetReserved = YES;
      } else {
        // Budget denied at count=3 too. Allocate anyway (session must start)
        // but log clearly. Do NOT crash — product must remain functional.
        NSLog(@"[VanguardGraphRuntime] P4-7B: WARNING — budget denied at "
              @"count=3 (tracked=%lu budget=150MB); proceeding without "
              @"budget reservation",
              (unsigned long)[allocator estimatedPoolMemoryBytes]);
        budgetReserved = NO;
      }
    }

    // (d) Create the session pool from the allocator (replaces old pre-prepare
    // hardcoded 1080×1920 allocation; addresses P4-7 plan "use actual
    // renderSize").
    CVPixelBufferPoolRef pool =
        [allocator pixelBufferPoolWithWidth:poolW
                                     height:poolH
                                     format:kCVPixelFormatType_32BGRA
                         minimumBufferCount:desiredCount];

    if (!pool && budgetReserved) {
      // Pool creation failed after budget was reserved — release the
      // reservation so the allocator's byte counter does not drift (P4-7A
      // contract).
      [allocator reportPoolReleased:poolBytes];
      budgetReserved = NO;
      NSLog(@"[VanguardGraphRuntime] P4-7B: pool creation failed (w=%zu h=%zu "
            @"count=%lu) — session will proceed without a session pool",
            poolW, poolH, (unsigned long)desiredCount);
    }

    NSLog(@"[VanguardGraphRuntime] P4-7B: pool created pool=%p size=%zux%zu "
          @"count=%lu bytes=%luMB budgetReserved=%d",
          pool, poolW, poolH, (unsigned long)desiredCount,
          (unsigned long)(poolBytes / (1024 * 1024)), budgetReserved);

    // pool carries a +1 retain (CF_RETURNS_RETAINED from
    // pixelBufferPoolWithWidth). sessionPool is declared `assign` — it does NOT
    // add a CF retain. Do NOT call CVPixelBufferPoolRelease here: that would
    // immediately free the pool, leaving self.sessionPool as a dangling pointer
    // for the entire session. The +1 is held for the session lifetime and
    // released via GPU fence deferred release in invalidateAsync (P4-8).
    self.sessionPool = pool;

    // P4-8: Store pool byte count as ivar so teardown paths can call
    // reportPoolReleased: with the exact reserved amount. poolBytes is a local
    // variable in this block and will be out of scope at invalidation time.
    // Only store when a budget reservation was actually made — if budgetReserved
    // is NO we must not later decrement a budget we never incremented.
    self->_sessionPoolBytes = budgetReserved ? poolBytes : 0;

    // (e) Backfill pool to source now that both source and pool exist.
    // VanguardFileMediaSource.pixelBufferPool is an `assign` property — setting
    // it here is safe because the source does not read it until start() is
    // called, which always follows prepare.
    if ([self.source respondsToSelector:@selector(setPixelBufferPool:)]) {
      [(id)self.source setPixelBufferPool:pool];
    }
    // Image path: backfill the processor's pool directly (mirroring the old
    // plugin-side backfill that was removed in P4-7 Step 1).
    if (imageProcessor && pool) {
      imageProcessor.pool = pool;
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
    //   scheduler.sink = renderer — scheduler delivers to renderer via
    //   presentEnvelope: renderer.frameDelegate = scheduler — renderer forwards
    //   raw frames to scheduler
    // Both are weak refs; runtime owns both objects for the session lifetime.
    self.scheduler.sink = renderer;
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

  // P4-8: Capture pool + reserved byte count atomically before dispatch.
  // Zeroing both ivars immediately prevents a concurrent second invalidateAsync
  // call from capturing the same pool pointer (invalidateAsync is idempotent
  // via _invalidated, but defence-in-depth here costs nothing).
  CVPixelBufferPoolRef capturedPool  = _sessionPool;
  NSUInteger capturedBytes           = _sessionPoolBytes;
  _sessionPool      = NULL;
  _sessionPoolBytes = 0;

  dispatch_async(_prepareQueue, ^{
    NSLog(@"[TRACE][IA1] invalidate started on prepareQueue");
    [self invalidate];

    dispatch_block_t afterCompletion = ^{
      dispatch_async(dispatch_get_main_queue(), ^{
        if (completion)
          completion();
        [capturedRenderer doUnregisterTexture];

        // ── P4-8: GPU-fence deferred pool release ──────────────────────────
        //
        // Design (RR-37, DEC-59):
        //   Primary  — sentinel MTLCommandBuffer on a fresh queue created from
        //              the allocator's shared Metal device. addCompletedHandler:
        //              fires after the GPU drains all preceding IOSurface work.
        //   Fallback — dispatch_after(5s) fires unconditionally. If the fence
        //              handler already ran, the _poolReleased CAS makes this a
        //              no-op. If the device was lost, this is the only path.
        //   Guard    — _Atomic(BOOL) _poolReleased: first atomic_exchange wins;
        //              second is a silent no-op. Prevents double-release and
        //              double reportPoolReleased:. (DEC-59 idempotency rule)
        //
        // Note: we create a NEW command queue from allocator.metalDevice rather
        // than accessing the renderer's private _commandQueue ivar (which is not
        // exposed in VanguardMetalRenderer.h). The allocator uses the same
        // system default MTLDevice — the sentinel drains the same GPU timeline.

        if (!capturedPool) {
          return; // No pool allocated this session — nothing to release.
        }

        id<MTLDevice> device = [VGResourceAllocator sharedInstance].metalDevice;
        id<MTLCommandQueue> sentinelQueue = device ? [device newCommandQueue] : nil;
        id<MTLCommandBuffer> sentinelBuf  = sentinelQueue
                                           ? [sentinelQueue commandBuffer]
                                           : nil;

        if (sentinelBuf) {
          // Primary path: GPU fence via addCompletedHandler:.
          [sentinelBuf addCompletedHandler:^(id<MTLCommandBuffer> __unused cb) {
            BOOL already = atomic_exchange(&self->_poolReleased, YES);
            if (!already) {
              CVPixelBufferPoolRelease(capturedPool);
              if (capturedBytes > 0) {
                [[VGResourceAllocator sharedInstance]
                    reportPoolReleased:capturedBytes];
              }
              NSLog(@"[VanguardGraphRuntime] P4-8: pool=%p released via "
                    @"GPU fence", capturedPool);
            }
          }];
          [sentinelBuf commit];
        } else {
          // Device unavailable — fence cannot be submitted. The dispatch_after
          // fallback below is the only release path. Log for diagnostics.
          NSLog(@"[VanguardGraphRuntime] P4-8: pool=%p Metal device unavailable "
                @"— relying on dispatch_after fallback", capturedPool);
        }

        // Fallback: unconditional 5-second timer (RR-37 mitigation).
        // Fires regardless of whether a fence was submitted. If the fence
        // handler already ran, the CAS makes this a no-op (zero cost).
        // If the device was lost and the fence never fires, this reclaims.
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
            dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0),
            ^{
              BOOL already = atomic_exchange(&self->_poolReleased, YES);
              if (!already) {
                CVPixelBufferPoolRelease(capturedPool);
                if (capturedBytes > 0) {
                  [[VGResourceAllocator sharedInstance]
                      reportPoolReleased:capturedBytes];
                }
                NSLog(@"[VanguardGraphRuntime] P4-8: GPU fence timeout — "
                      @"pool=%p released via dispatch_after fallback",
                      capturedPool);
              }
            });
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

// P4-8: Dealloc-path pool release.
//
// Called ONLY from -dealloc (abnormal teardown — caller skipped -invalidate).
//
// Per RR-37 mitigation 3: MUST NOT submit an MTLCommandBuffer from dealloc.
// Metal objects (device, command queue) may already be partially torn down.
// dispatch_after(5s) gives in-flight GPU work time to drain before the
// IOSurface is reclaimed by the OS — no active fence needed in this path.
//
// Uses reportPoolReleased: directly (not via fence) because dealloc never
// calls the fence path, so there is no in-flight fence count to coordinate.
//
// _Atomic(BOOL) _poolReleased CAS guards against the edge case where
// invalidateAsync was called and raced with dealloc on the same pool pointer.
- (void)_releaseSessionPool {
  if (_sessionPool) {
    CVPixelBufferPoolRef poolToRelease = _sessionPool;
    NSUInteger bytesToRelease          = _sessionPoolBytes;
    _sessionPool      = NULL;
    _sessionPoolBytes = 0;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0),
        ^{
          BOOL already = atomic_exchange(&self->_poolReleased, YES);
          if (!already) {
            CVPixelBufferPoolRelease(poolToRelease);
            if (bytesToRelease > 0) {
              [[VGResourceAllocator sharedInstance]
                  reportPoolReleased:bytesToRelease];
            }
            NSLog(@"[VanguardGraphRuntime] P4-8 dealloc: pool=%p released "
                  @"via dispatch_after fallback", poolToRelease);
          }
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
