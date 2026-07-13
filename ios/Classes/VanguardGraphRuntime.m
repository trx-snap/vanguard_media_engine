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
// P4-10: filter node classes — required by setFilterChainFromSpecs: (RR-34)
#import "VanguardBeautyFilterNode.h"
#import "VanguardLUTFilterNode.h"
#import "VanguardSegmentationFilterNode.h"
// Phase 4B: Beauty V2 — opt-in only, never the default (Step 4 controlled
// wiring)
#import "BeautyV2FilterGroup.h"
// Phase 4F: VGSegmentationNode — face detection + mask generation (DEC-100)
#import "VGSegmentationNode.h"
// Phase 9B-4: gated factory helper (VG_ML_SEGMENTATION_ENABLED defaults 0 — no
// behaviour change in production builds).
#import "VGCameraGraphFactory.h"

// Phase 4 Batch 3: V2 graph scheduler feature gate.
// VGUseV2Graph.h is imported OUTSIDE any #if guard so the preprocessor can
// read VG_USE_V2_GRAPH before encountering the guarded imports below.
#import "VGUseV2Graph.h"
#if VG_USE_V2_GRAPH
#import "VGGraphSchedulerV2.h"
#import "VGPlaybackGraphFactory.h"
#import <UMF/VGGraphExecutionContext.h>
// Phase 7 Stage 7.5C: timeline playback proof factory and node.
#import "VGRendererSinkAdapter.h"
#import "VGTimelineCompositorNode.h"
#import "VGTimelinePlaybackGraphFactory.h"
#import <QuartzCore/QuartzCore.h>
#import <UMF/VGFrameEnvelope.h>
#import <UMF/VGFrameRequest.h>
#import <UMF/VGFrameResult.h>
#import <UMF/VGRenderMode.h>
#import <UMF/VGSourceNode.h>
// Phase 10-C Slice C: timeline-state snapshot for cross-thread readers.
#import <os/lock.h>
#import "VGTimelineStateSnapshot.h"
// Phase 10-C Slice D: audio preview runtime category.
#import "VanguardGraphRuntime+AudioPreview.h"
#import "VanguardAudioPreviewRuntime.h"

// Phase 10-C Slice D: private forward declarations for graph-audio lifecycle
// methods defined in VanguardGraphRuntime+AudioPreview.m. Declared here so
// the invalidate/invalidateAsync: implementations can call them without
// importing the category header (which is module-visible, not private).
@interface VanguardGraphRuntime (AudioPreviewPrivate)
- (nullable VanguardAudioPreviewRuntime *)audioPreviewRuntime;
- (void)invalidateAudioPreviewWithCompletion:(nullable dispatch_block_t)completion;
@end

#endif

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

// Image-path filter support: stored during prepare for image sessions only.
// Both are nil for video sessions. Used by setFilterChain: to re-push the
// filtered image buffer to the renderer without touching the video path.
@property(nonatomic, strong, nullable) VanguardImageProcessor *imageProcessor;
@property(nonatomic, weak, nullable) VanguardImageMediaSource *imageSrc;

// P4-3: Dormant scheduler. Created in prepareWithURL:, torn down in
// invalidate/dealloc. Does NOT drive frame execution (that is P4-5+).
@property(nonatomic, strong, nullable) VanguardGraphScheduler *scheduler;

// Phase 4 Batch 3: V2 scheduler and execution context.
// Only compiled and used when VG_USE_V2_GRAPH=1.
// Both properties remain nil on the V1 path (VG_USE_V2_GRAPH=0).
#if VG_USE_V2_GRAPH
@property(nonatomic, strong, nullable) VGGraphSchedulerV2 *schedulerV2;
@property(nonatomic, strong, nullable)
    VGGraphExecutionContext *executionContext;
// Phase 7 Stage 7.5C / Phase 7.x-D: timeline pull-loop state.
// All nil/zero unless prepareWithSourceNode:completion: was used.
// activeSourceNode: stores any id<VGSourceNode> (e.g.
// VGTimelineCompositorNode). Timeline-specific properties (seek, cache) only
// act when activeSourceNode is a VGTimelineCompositorNode (guarded by
// isKindOfClass: at each call site).
@property(nonatomic, strong, nullable) id<VGSourceNode> activeSourceNode;
@property(nonatomic, strong, nullable)
    VGRendererSinkAdapter *timelineSinkAdapter;
@property(nonatomic, strong, nullable) CADisplayLink *timelineDisplayLink;
// Atomic generation counter for the pull loop seek invalidation.
// Incremented on each seekTimelineTo: to flush stale in-flight pull requests.
@property(atomic, assign) uint64_t timelineGeneration;
// PTS tracking for the pull loop.
// Protected by main-thread-only access (CADisplayLink fires on main thread).
@property(nonatomic, assign) double timelineCurrentPTS;
@property(nonatomic, assign) BOOL timelineIsPlaying;
// [7.5C] Wall-clock playback clock anchors.
// timelinePlayStartTime: CACurrentMediaTime() captured at play (or
// seek-while-playing). timelineBasePTS: timelineCurrentPTS captured at that
// same moment. Used to compute timelineCurrentPTS = timelineBasePTS +
// (CACurrentMediaTime() - timelinePlayStartTime).
@property(nonatomic, assign) double timelinePlayStartTime;
@property(nonatomic, assign) double timelineBasePTS;
// When YES the display link must pull exactly one preview frame even while
// paused, then clear this flag. Set on prepare and every seekTimelineTo:.
@property(nonatomic, assign) BOOL timelineNeedsPreviewFrame;
#endif

- (NSDictionary *)vg_timelineFrameArgumentsForPTS:(double)pts
                                       generation:(NSInteger)generation;

- (NSDictionary *)vg_timelineEOSArguments;

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
  // Atomic invalidation flag. Set in two places:
  //   1. invalidateAsync: — set IMMEDIATELY on the calling thread (main) so
  //      the CADisplayLink callback sees it on the very next tick and
  //      self-invalidates without rendering even one more frame. This is the
  //      primary quiesce signal.
  //   2. invalidate — belt-and-suspenders set for direct callers that bypass
  //      invalidateAsync:. Harmless if already YES.
  // Declared in .m so it is not part of the frozen public header.
  _Atomic(BOOL) _invalidated;

  // Cleanup idempotency guard for the body of invalidate.
  // Separate from _invalidated so that _invalidated can be set early in
  // invalidateAsync: (for quiescing) while the actual cleanup body in
  // invalidate still runs exactly once on _prepareQueue.
  // Written exactly once (YES) by the first call to invalidate.
  _Atomic(BOOL) _cleanupDone;

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

#if VG_USE_V2_GRAPH
  // Phase 10-C Slice C: coherent timeline-state snapshot.
  // Protects _timelineSnapshotState against torn cross-thread reads.
  // os_unfair_lock is priority-aware and has nanosecond-scale hold time
  // (one struct copy). Safe for the Classification B scheduling queue in
  // Slice D. MUST NOT be acquired from a hard real-time render callback.
  os_unfair_lock _timelineSnapshotLock;
  // The snapshot is zero-initialised (isValid == NO) until the first
  // successful prepareWithSourceNode:completion: call.
  VGTimelineStateSnapshot _timelineSnapshotState;
#endif
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
  _cleanupDone = NO;
  _poolReleased = NO; // P4-8: reset per-session on each new runtime instance
  _sessionPoolBytes =
      0; // P4-8: populated in prepareWithURL: after pool creation
  _renderSize = CGSizeZero;

#if VG_USE_V2_GRAPH
  // Phase 10-C Slice C: initialise snapshot lock and zero-initialise state.
  // isValid remains NO — an unprepared runtime is not a valid timeline.
  _timelineSnapshotLock = OS_UNFAIR_LOCK_INIT;
  _timelineSnapshotState = (VGTimelineStateSnapshot){0};
#endif

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
      // Store for setFilterChain: image re-apply.
      self.imageProcessor = processor;
      self.imageSrc = imageSrc;

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
    // Only store when a budget reservation was actually made — if
    // budgetReserved is NO we must not later decrement a budget we never
    // incremented.
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

    // ── Phase 4 Batch 3: V2/V1 scheduler wiring gate ─────────────────────────
    //
    // When VG_USE_V2_GRAPH=1: try to build the V2 graph via
    // VGPlaybackGraphFactory.
    //   On success: wire VGGraphSchedulerV2 as renderer.frameDelegate and
    //   start. On failure: fall back to V1 VanguardGraphScheduler (same as
    //   #else below).
    // When VG_USE_V2_GRAPH=0: V1 path compiled exclusively (pre-Batch-3
    // behavior).
#if VG_USE_V2_GRAPH
    NSError *v2GraphError = nil;
    NSDictionary<NSString *, id> *v2GraphResult =
        [VGPlaybackGraphFactory buildGraphWithSource:self.source
                                         filterChain:self.filterChainStorage
                                            renderer:renderer
                                               error:&v2GraphError];

    if (v2GraphResult) {
      // ── V2 SUCCESS: wire V2 scheduler ───────────────────────────────────
      VGGraphDescriptor *v2Descriptor = v2GraphResult[@"descriptor"];
      NSDictionary<NSString *, id<VGNode>> *v2Nodes = v2GraphResult[@"nodes"];
      VGExecutionPlan *v2Plan = v2GraphResult[@"plan"];

      // Create execution context (pure data container — no lifecycle calls).
      VGGraphExecutionContext *v2Context =
          [[VGGraphExecutionContext alloc] initWithDescriptor:v2Descriptor
                                                         plan:v2Plan
                                                        nodes:v2Nodes
                                                        clock:self.masterClock
                                            resourceAllocator:allocator];
      self.executionContext = v2Context;

      // Create V2 scheduler.
      VGGraphSchedulerV2 *v2Scheduler =
          [[VGGraphSchedulerV2 alloc] initWithPlan:v2Plan
                                             nodes:v2Nodes
                                           context:v2Context];
      self.schedulerV2 = v2Scheduler;

      // Wire sink: find the VGFrameSink node in the nodes map.
      // VGRendererSinkAdapter conforms to VGFrameSink; found by protocol check.
      for (id<VGNode> node in v2Nodes.allValues) {
        if ([node conformsToProtocol:@protocol(VGFrameSink)]) {
          v2Scheduler.sink = (id<VGFrameSink>)node;
          break;
        }
      }

      // Wire: renderer delivers raw frames to V2 scheduler.
      renderer.frameDelegate = v2Scheduler;

      // Start the V2 scheduler so _running = YES before the first frame
      // arrives.
      //
      // startWithClock: sets _running=YES, calls [sourceNode startProducing],
      // and transitions context to VGGraphStateRunning.
      //
      // startProducing → VGFileSourceAdapter → [source start].
      // VanguardFileMediaSource.start is guarded by _started flag (idempotent).
      // Frame delivery does NOT begin until VanguardMetalRenderer.play wires
      // the CADisplayLink (_displayLinkFired → _renderFrameAtSourceTime:). So
      // calling startWithClock: here is safe — no frame can arrive before play.
      [v2Scheduler startWithClock:self.masterClock];

      // V1 scheduler is NOT created on the V2 success path.
      self.scheduler = nil;

      NSLog(@"[VanguardGraphRuntime] V2 graph scheduler activated "
            @"(VG_USE_V2_GRAPH=1, execOrderCount=%lu)",
            (unsigned long)v2Plan.topologicalOrder.count);

    } else {
      // ── V2 FAILED: fall back to V1 scheduler ────────────────────────────
      // VGPlaybackGraphFactory returned nil (validation or planning failure).
      // Log and create the V1 scheduler identically to the #else path below.
      NSLog(@"[VanguardGraphRuntime] V2 graph construction failed: %@ "
            @"— falling back to V1 scheduler",
            v2GraphError);

      self.scheduler = [[VanguardGraphScheduler alloc] init];
      self.scheduler.sink = renderer;
      renderer.frameDelegate = self.scheduler;
      id<MTLDevice> schedulerDevice = allocator.metalDevice;
      if (schedulerDevice) {
        [self.scheduler startWithClock:self.masterClock device:schedulerDevice];
      }
    }
#else
    // ── V1 path (unchanged from pre-Batch-3) ─────────────────────────────
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
#endif

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
  // Belt-and-suspenders: ensure _invalidated is set even when invalidate is
  // called directly (bypassing invalidateAsync:). For the normal path this
  // is a no-op because invalidateAsync: already set it on the calling thread.
  atomic_store(&_invalidated, YES);

  // _cleanupDone guards the cleanup body. Use atomic_exchange for a single
  // racy write — first caller proceeds, any concurrent second call returns
  // immediately. This is separate from _invalidated so that the early quiesce
  // in invalidateAsync: does not skip the cleanup body.
  BOOL alreadyCleaned = atomic_exchange(&_cleanupDone, YES);
  if (alreadyCleaned) {
    return; // Idempotent — cleanup has already run or is running.
  }

#if VG_USE_V2_GRAPH
  // Phase 10-C Slice C: mark snapshot invalid immediately — before any
  // cleanup — so pending callbacks that passed the _invalidated check above
  // cannot republish a valid snapshot. _publishTimelineSnapshot also checks
  // _invalidated under the lock, providing a second safety net.
  os_unfair_lock_lock(&_timelineSnapshotLock);
  _timelineSnapshotState.isValid = NO;
  _timelineSnapshotState.isPlaying = NO;
  os_unfair_lock_unlock(&_timelineSnapshotLock);
#endif

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

  // Phase 4 Batch 3: Tear down V2 scheduler if active.
  // When V1 path is active (VG_USE_V2_GRAPH=0 or V2 fallback), schedulerV2 is
  // nil and [nil invalidate] is a no-op. When V2 path is active, scheduler is
  // nil. Both teardown calls are unconditional — no runtime path check needed.
#if VG_USE_V2_GRAPH
  // Phase 7 Stage 7.5C: Break the CADisplayLink retain cycle immediately.
  //
  // CADisplayLink was created with `target: self`, forming a strong reference
  // cycle: runtime → displayLink → runtime. The previous safety net in
  // _timelineDisplayLinkFired: only fires if the link ticks again after
  // invalidation. If the runtime is invalidated while the timeline is paused
  // or the display link is otherwise quiesced, that tick never arrives and
  // the runtime leaks. Calling -invalidate here breaks the cycle synchronously,
  // exactly once, regardless of whether a tick is pending.
  // Safe: [nil invalidate] is a no-op (timeline path may never have been used).
  if (self.timelineDisplayLink) {
    [self.timelineDisplayLink invalidate];
    self.timelineDisplayLink = nil;
  }
  [self.schedulerV2 invalidate];
  self.schedulerV2 = nil;
  self.executionContext = nil;
  // Phase 10-C Slice D: audio preview lifecycle invariant.
  //
  // INVARIANT: synchronous invalidate must only be called from invalidateAsync:
  // (which calls invalidateAudioPreviewWithCompletion:nil on the main queue
  // BEFORE dispatching this method to _prepareQueue). By the time we reach here:
  //   - The audio lifecycle gate is already Active → ShuttingDown.
  //   - The replacement generation has already been incremented.
  //   - Any in-flight setAudioSidecarPlan: will be rejected at gate 2 or 3.
  //
  // Production audio-capable runtimes (i.e. _timelineRuntime) must always be
  // torn down through invalidateAsync:, never through direct invalidate calls.
  //
  // If audioPreviewRuntime is still non-nil here (e.g. direct invalidate on a
  // non-audio-capable runtime, or an unexpected direct caller), initiate its
  // own cleanup as a defensive fallback. The lifecycle gate is already closed.
  VanguardAudioPreviewRuntime *audioRT = [self audioPreviewRuntime];
  if (audioRT) {
      [audioRT invalidateAsync:^{
          NSLog(@"[VanguardGraphRuntime][D] audio preview runtime cleanup from invalidate");
      }];
  }
#endif

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
  // ── Immediate quiesce (Phase 10-C Slice D teardown fix) ────────────────────
  //
  // Set _invalidated atomically on the calling thread (main in production)
  // BEFORE dispatching any work to _prepareQueue. This ensures:
  //   - _timelineDisplayLinkFired: sees _invalidated==YES on the very next
  //     main-thread tick and self-invalidates without rendering another frame.
  //   - _publishTimelineSnapshot forces isValid=NO / isPlaying=NO so the
  //     audio runtime's snapshot provider returns an invalid snapshot,
  //     gating any queued commandPlay calls.
  //
  // If _invalidated was already YES this is a concurrent/repeated call.
  // Fire completion asynchronously and return — cleanup runs only once.
  BOOL alreadyInvalidated = atomic_exchange(&_invalidated, YES);
  if (alreadyInvalidated) {
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), completion);
    }
    return;
  }

#if VG_USE_V2_GRAPH
  // Invalidate snapshot immediately on the calling thread so readers on
  // other queues see isValid=NO before any asynchronous cleanup begins.
  os_unfair_lock_lock(&_timelineSnapshotLock);
  _timelineSnapshotState.isValid = NO;
  _timelineSnapshotState.isPlaying = NO;
  os_unfair_lock_unlock(&_timelineSnapshotLock);
#endif

  // Capture source and renderer strongly on the caller thread BEFORE
  // dispatching. invalidate will nil both _source and _renderer; we need
  // the pre-invalidate values for the drain step and post-completion cleanup.
  id<VanguardMediaSource, VGMediaNode> capturedSource = _source;
  VanguardMetalRenderer *capturedRenderer = _renderer;

  // P4-8: Capture pool + reserved byte count atomically before dispatch.
  // Zeroing both ivars immediately prevents a concurrent second invalidateAsync
  // call from capturing the same pool pointer (invalidateAsync is idempotent
  // via _invalidated, but defence-in-depth here costs nothing).
  CVPixelBufferPoolRef capturedPool = _sessionPool;
  NSUInteger capturedBytes = _sessionPoolBytes;
  _sessionPool = NULL;
  _sessionPoolBytes = 0;

#if VG_USE_V2_GRAPH
  // Phase 10-C Slice D: initiate graph-audio shutdown on the main queue BEFORE
  // dispatching video/graph cleanup to _prepareQueue. This ensures:
  //   - The audio lifecycle gate transitions Active → ShuttingDown on main.
  //   - The replacement generation is incremented before any in-flight
  //     setAudioSidecarPlan: can install a new runtime on main.
  //   - Any stale setAudioSidecarPlan: completions are rejected at gate 2 or 3.
  // The second join (inside afterVideoCleanup below) ensures the graph
  // completion fires only after BOTH video and audio cleanup complete.
  if ([NSThread isMainThread]) {
      [self invalidateAudioPreviewWithCompletion:nil];
  } else {
      dispatch_sync(dispatch_get_main_queue(), ^{
          [self invalidateAudioPreviewWithCompletion:nil];
      });
  }
#endif

  dispatch_async(_prepareQueue, ^{
    NSLog(@"[TRACE][IA1] invalidate started on prepareQueue");
    [self invalidate];

    dispatch_block_t afterCompletion = ^{
      dispatch_async(dispatch_get_main_queue(), ^{
#if VG_USE_V2_GRAPH
        // Phase 10-C Slice D: join audio cleanup before firing the graph
        // completion. This is the second call to invalidateAudioPreviewWithCompletion:.
        // If the audio lifecycle gate is already ShutDown (because no audio was
        // active, or because it completed before video), this fires immediately.
        // If audio cleanup is still in progress (ShuttingDown), we append ourselves
        // as a waiter and fire only after audio cleanup completes.
        // The graph completion is therefore deferred until BOTH video and audio
        // cleanup are fully done.
        [self invalidateAudioPreviewWithCompletion:^{
            if (completion)
                completion();
        }];
#else
        if (completion)
          completion();
#endif
        [capturedRenderer doUnregisterTexture];

        // ── P4-8: GPU-fence deferred pool release ──────────────────────────
        //
        // Design (RR-37, DEC-59):
        //   Primary  — sentinel MTLCommandBuffer on a fresh queue created from
        //              the allocator's shared Metal device.
        //              addCompletedHandler: fires after the GPU drains all
        //              preceding IOSurface work.
        //   Fallback — dispatch_after(5s) fires unconditionally. If the fence
        //              handler already ran, the _poolReleased CAS makes this a
        //              no-op. If the device was lost, this is the only path.
        //   Guard    — _Atomic(BOOL) _poolReleased: first atomic_exchange wins;
        //              second is a silent no-op. Prevents double-release and
        //              double reportPoolReleased:. (DEC-59 idempotency rule)
        //
        // Note: we create a NEW command queue from allocator.metalDevice rather
        // than accessing the renderer's private _commandQueue ivar (which is
        // not exposed in VanguardMetalRenderer.h). The allocator uses the same
        // system default MTLDevice — the sentinel drains the same GPU timeline.

        if (!capturedPool) {
          return; // No pool allocated this session — nothing to release.
        }

        id<MTLDevice> device = [VGResourceAllocator sharedInstance].metalDevice;
        id<MTLCommandQueue> sentinelQueue =
            device ? [device newCommandQueue] : nil;
        id<MTLCommandBuffer> sentinelBuf =
            sentinelQueue ? [sentinelQueue commandBuffer] : nil;

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
                    @"GPU fence",
                    capturedPool);
            }
          }];
          [sentinelBuf commit];
        } else {
          // Device unavailable — fence cannot be submitted. The dispatch_after
          // fallback below is the only release path. Log for diagnostics.
          NSLog(
              @"[VanguardGraphRuntime] P4-8: pool=%p Metal device unavailable "
              @"— relying on dispatch_after fallback",
              capturedPool);
        }

        // Fallback: unconditional 5-second timer (RR-37 mitigation).
        // Fires regardless of whether a fence was submitted. If the fence
        // handler already ran, the CAS makes this a no-op (zero cost).
        // If the device was lost and the fence never fires, this reclaims.
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
            dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
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

  // Phase 4B: V2 graph hot-swap implemented below.
  // When VG_USE_V2_GRAPH=1 and schedulerV2 is active, rebuild the entire V2
  // graph from the new filter chain and atomically swap the scheduler.
  //
  // Design: build-then-swap (no invalidation of old scheduler).
  //   1. Build new graph via VGPlaybackGraphFactory.
  //   2. Create new VGGraphExecutionContext + VGGraphSchedulerV2.
  //   3. Wire sink and start new scheduler BEFORE delegate swap.
  //   4. Atomically reassign renderer.frameDelegate to new scheduler.
  //   5. ARC releases old scheduler when self.schedulerV2 is overwritten.
  //
  // NOTE: old scheduler is NOT invalidated. Invalidating it would call
  // [_sourceNode stopProducing] on the same underlying VanguardFileMediaSource
  // that the new graph shares, killing frame delivery. We rely on ARC + weak
  // frameDelegate: after step 4 no new frames route to the old scheduler.
  // _running on the old scheduler becomes irrelevant once frameDelegate is
  // swapped.
  //
  // On rebuild failure: old scheduler kept active. No V1 fallback.
#if VG_USE_V2_GRAPH
  if (self.schedulerV2) {
    // Guard: bail out if source or renderer is nil (pre-prepare or
    // invalidated).
    if (!self.source || !self.renderer) {
      NSLog(@"[VanguardGraphRuntime] V2 hot-swap skipped: "
            @"source=%@ renderer=%@ (pre-prepare or invalidated)",
            self.source, self.renderer);
    } else {
      NSError *rebuildError = nil;
      NSDictionary<NSString *, id> *newGraph =
          [VGPlaybackGraphFactory buildGraphWithSource:self.source
                                           filterChain:newChain
                                              renderer:self.renderer
                                                 error:&rebuildError];

      if (!newGraph) {
        // Rebuild failed — keep old V2 scheduler. Do NOT fall back to V1.
        NSLog(@"[VanguardGraphRuntime] V2 graph rebuild failed: %@ "
              @"— keeping current V2 scheduler",
              rebuildError);
      } else {
        // Rebuild succeeded — construct and wire new scheduler.
        VGGraphDescriptor *newDesc = newGraph[@"descriptor"];
        NSDictionary<NSString *, id<VGNode>> *newNodes = newGraph[@"nodes"];
        VGExecutionPlan *newPlan = newGraph[@"plan"];
        VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];

        // Create new execution context.
        VGGraphExecutionContext *newCtx =
            [[VGGraphExecutionContext alloc] initWithDescriptor:newDesc
                                                           plan:newPlan
                                                          nodes:newNodes
                                                          clock:self.masterClock
                                              resourceAllocator:allocator];

        // Create new V2 scheduler.
        VGGraphSchedulerV2 *newScheduler =
            [[VGGraphSchedulerV2 alloc] initWithPlan:newPlan
                                               nodes:newNodes
                                             context:newCtx];

        // Wire sink: find VGFrameSink node in new node map.
        id<VGFrameSink> newSink = nil;
        for (id<VGNode> node in newNodes.allValues) {
          if ([node conformsToProtocol:@protocol(VGFrameSink)]) {
            newSink = (id<VGFrameSink>)node;
            break;
          }
        }

        if (!newSink) {
          // No sink found — treat as rebuild failure. Old scheduler survives.
          NSLog(@"[VanguardGraphRuntime] V2 hot-swap: no VGFrameSink in new "
                @"graph "
                @"— keeping current V2 scheduler");
        } else {
          newScheduler.sink = newSink;

          // Start new scheduler (_running = YES) BEFORE swapping frameDelegate.
          // startWithClock: sets _running=YES and calls [_sourceNode
          // startProducing]. VanguardFileMediaSource.start is idempotent
          // (_started flag guard); safe to call while source is already running
          // via old scheduler.
          [newScheduler startWithClock:self.masterClock];

          // ── ATOMIC SWAP ───────────────────────────────────────────────────
          // renderer.frameDelegate is a weak property
          // (VanguardMetalRenderer.h:147). ARC weak property assignment is
          // atomic on ARM64 — thread-safe against a concurrent _onVideoFrame:
          // call that loads _frameDelegate once.
          //
          // After this point, new frames route to newScheduler.
          // Old scheduler receives no new frames (frameDelegate no longer
          // points to it). Old scheduler released by ARC when self.schedulerV2
          // is overwritten below.
          self.schedulerV2 = newScheduler;
          self.executionContext = newCtx;
          self.renderer.frameDelegate = newScheduler;
          // (old scheduler and old context released by ARC here)

          NSLog(@"[VanguardGraphRuntime] V2 graph hot-swapped "
                @"(newExecOrderCount=%lu)",
                (unsigned long)newPlan.topologicalOrder.count);
        }
      }
    }
  }
#endif

  // ── Image-path re-apply (image sessions only) ──────────────────────────────
  // Independent of the video/scheduler path. Nil for video sessions.
  // Reads original raw buffer from imageSrc (not renderer) to prevent
  // cumulative filter accumulation across repeated taps.
  VanguardImageProcessor *imgProc = self.imageProcessor;
  VanguardImageMediaSource *imgSrc = self.imageSrc;
  VanguardMetalRenderer *rend = self.renderer;
  id<MTLDevice> dev = [VGResourceAllocator sharedInstance].metalDevice;

  if (imgProc && imgSrc && rend && dev) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      // Always read from the original unfiltered image buffer, not from the
      // renderer's current display buffer. This prevents cumulative filter
      // accumulation (Beauty+Beauty+Beauty) and makes Clear correctly restore
      // the original image by applying an empty chain to the raw source buffer.
      CVPixelBufferRef raw = [imgSrc copyRawBuffer]; // +1 retain
      if (!raw)
        return;

      CVPixelBufferRef filtered = [imgProc applyFilterChain:newChain
                                                   toBuffer:raw
                                                     atTime:kCMTimeZero
                                                     device:dev];
      // Push filtered buffer to renderer via the public GPU-sink API.
      VGFrameEnvelope envelope;
      memset(&envelope, 0, sizeof(envelope));
      envelope.mediaType = VGMediaTypeVideo;
      envelope.pts = kCMTimeZero;
      envelope.payload.videoBuffer = (void *)filtered;
      [rend presentEnvelope:envelope];

      // Balance the extra +1 if the filter produced a new buffer.
      if (filtered != raw) {
        CVPixelBufferRelease(filtered);
      }
      CVPixelBufferRelease(raw); // balance copyRawBuffer
    });
  }
}

// P4-10: Spec-based filter chain construction (RR-34 closure).
//
// All three filter node classes (VanguardLUTFilterNode,
// VanguardBeautyFilterNode, VanguardSegmentationFilterNode) declare `init`
// NS_UNAVAILABLE — they must be constructed with initWithPool:device:. The
// Swift plugin layer has no access to the runtime-owned CVPixelBufferPool or
// MTLDevice, so construction must happen here where both resources are
// available (post-prepare).
//
// The method validates all type strings FIRST, then constructs + applies the
// chain atomically via -setFilterChain: on success. On any unknown type it
// returns NO and sets *unknown without mutating the chain.
- (BOOL)setFilterChainFromSpecs:(NSArray<NSDictionary *> *)specs
                        unknown:(NSString *__autoreleasing *_Nullable)unknown {
  if (unknown)
    *unknown = nil;

  CVPixelBufferPoolRef pool = self.sessionPool;
  id<MTLDevice> device = [VGResourceAllocator sharedInstance].metalDevice;

  // If the session pool or device is not yet available (called before prepare),
  // apply an empty chain. Callers should not invoke before prepare completes,
  // but we degrade gracefully rather than crashing.
  if (!pool || !device) {
    NSLog(@"[VGRuntime] setFilterChainFromSpecs: pool or device nil (called "
          @"before prepare?)");
    [self setFilterChain:@[]];
    return YES; // not an unknown-type error
  }

  // ── 1. Validate all types before constructing any nodes ───────────────────
  static NSSet<NSString *> *knownTypes;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    knownTypes = [NSSet setWithObjects:@"lut", @"beauty", @"segmentation", nil];
  });

  for (NSDictionary *spec in specs) {
    NSString *type = spec[@"type"];
    if (![type isKindOfClass:[NSString class]] ||
        ![knownTypes containsObject:type]) {
      if (unknown)
        *unknown = type ?: @"(nil)";
      return NO;
    }
  }

  // ── 2. Construct nodes (all types validated) ───────────────────────────────
  NSMutableArray<id<VGMetalFilterNode>> *nodes =
      [NSMutableArray arrayWithCapacity:specs.count];

  for (NSDictionary *spec in specs) {
    NSString *type = spec[@"type"];
    NSDictionary *params = spec[@"parameters"];
    BOOL enabled = [spec[@"enabled"] boolValue]; // nil → NO → fixed below
    // Default enabled=YES when the key is absent (Dart default is true).
    if (spec[@"enabled"] == nil)
      enabled = YES;

    id<VGMetalFilterNode> node = nil;

    if ([type isEqualToString:@"lut"]) {
      VanguardLUTFilterNode *lut =
          [[VanguardLUTFilterNode alloc] initWithPool:pool device:device];
      if ([params[@"intensity"] isKindOfClass:[NSNumber class]]) {
        lut.intensity = [params[@"intensity"] floatValue];
      }
      lut.enabled = enabled;
      node = lut;

    } else if ([type isEqualToString:@"beauty"]) {
      // ── Beauty version switch (Phase 4B Step 4)
      // ───────────────────────────── V2 is opt-in only. V1 is the default for
      // all existing and new specs. Select V2 when params contain:
      //   "beautyVersion": 2   (preferred canonical key)
      //   "version": 2         (alternative accepted key)
      // Any other value, or no version key at all, selects V1 (RR-45 safe).
      BOOL wantV2 = NO;
      if ([params[@"beautyVersion"] isKindOfClass:[NSNumber class]]) {
        wantV2 = ([params[@"beautyVersion"] integerValue] == 2);
      } else if ([params[@"version"] isKindOfClass:[NSNumber class]]) {
        wantV2 = ([params[@"version"] integerValue] == 2);
      }

      if (wantV2) {
        // ── Beauty V2 path ───────────────────────────────────────────────────
        // BeautyV2FilterGroup owns node-local intermediate pools;
        // it borrows the runtime session pool (pool) for final output only.
        // Sanitization (clamp) is performed inside processEnvelope: — do NOT
        // sanitize values here; pass them through as-is (RR-38 §sanitization).
        BeautyV2FilterGroup *v2 =
            [[BeautyV2FilterGroup alloc] initWithPool:pool device:device];
        if (v2) {
          v2.enabled = enabled;

          // ── Optional param mapping (Phase 4B Step 6B) ────────────────────
          // Parameter precedence contract:
          //   intensity alone  → useIntensityRamp=YES  (ramp drives all 5
          //   params) any granular key → useIntensityRamp=NO   (ramp disabled,
          //   explicit wins)
          //
          // Default: useIntensityRamp=YES (set in initWithPool:device:)
          // so absent keys leave the ramp active at intensity=0.75.
          if ([params[@"intensity"] isKindOfClass:[NSNumber class]]) {
            v2.intensity = [params[@"intensity"] floatValue];
            // Keep useIntensityRamp=YES (default) — intensity drives the ramp.
          }
          // Granular params: each one disables the ramp and takes direct
          // effect.
          BOOL hasGranular = NO;
          if ([params[@"radius"] isKindOfClass:[NSNumber class]]) {
            v2.radius = [params[@"radius"] intValue];
            hasGranular = YES;
          }
          if ([params[@"sigma"] isKindOfClass:[NSNumber class]]) {
            v2.sigma = [params[@"sigma"] floatValue];
            hasGranular = YES;
          }
          if ([params[@"smoothStrength"] isKindOfClass:[NSNumber class]]) {
            v2.smoothStrength = [params[@"smoothStrength"] floatValue];
            hasGranular = YES;
          }
          if ([params[@"sharpenStrength"] isKindOfClass:[NSNumber class]]) {
            v2.sharpenStrength = [params[@"sharpenStrength"] floatValue];
            hasGranular = YES;
          }
          if ([params[@"theta"] isKindOfClass:[NSNumber class]]) {
            v2.theta = [params[@"theta"] floatValue];
            hasGranular = YES;
          }
          // Phase 4B.5 (DEC-59): range sigma override — disables intensity
          // ramp. Dart callers do not send this key; reserved for advanced
          // dev/QA use.
          if ([params[@"rangeSigma"] isKindOfClass:[NSNumber class]]) {
            v2.rangeSigma = [params[@"rangeSigma"] floatValue];
            hasGranular = YES;
          }
          // Phase 4B.6 (DEC-60): perceptual composite param overrides.
          // Step 1: CPU-plumbed only — values are stored on the ObjC node but
          // not yet consumed by the GPU composite kernel (BeautyCompositeParams
          // struct unchanged until Step 2).
          if ([params[@"detailDamping"] isKindOfClass:[NSNumber class]]) {
            v2.detailDamping = [params[@"detailDamping"] floatValue];
            hasGranular = YES;
          }
          if ([params[@"toneStrength"] isKindOfClass:[NSNumber class]]) {
            v2.toneStrength = [params[@"toneStrength"] floatValue];
            hasGranular = YES;
          }
          if ([params[@"midtoneLift"] isKindOfClass:[NSNumber class]]) {
            v2.midtoneLift = [params[@"midtoneLift"] floatValue];
            hasGranular = YES;
          }
          // Phase 4C (DEC-61/63): face-aware beauty DEV toggle.
          // Independent of the intensity ramp — does NOT set hasGranular.
          // When absent, default remains NO (exact Phase 4B.6 behavior).
          if ([params[@"faceAwareEnabled"] isKindOfClass:[NSNumber class]]) {
            v2.faceAwareEnabled = [params[@"faceAwareEnabled"] boolValue];
          }
          // Phase 4C.1 (DEC-66/67): face-weighted boost param overrides.
          // Independent of the intensity ramp — do NOT set hasGranular.
          // When absent, ObjC defaults are used (0.40, 0.12, 0.025, 0.15).
          if ([params[@"faceSmoothBoost"] isKindOfClass:[NSNumber class]]) {
            v2.faceSmoothBoost = [params[@"faceSmoothBoost"] floatValue];
          }
          if ([params[@"faceToneBoost"] isKindOfClass:[NSNumber class]]) {
            v2.faceToneBoost = [params[@"faceToneBoost"] floatValue];
          }
          if ([params[@"faceLiftBoost"] isKindOfClass:[NSNumber class]]) {
            v2.faceLiftBoost = [params[@"faceLiftBoost"] floatValue];
          }
          if ([params[@"faceDampingReduce"] isKindOfClass:[NSNumber class]]) {
            v2.faceDampingReduce = [params[@"faceDampingReduce"] floatValue];
          }
          // Phase 4C.2 (DEC-70/71): color aesthetic param overrides.
          // Independent of the intensity ramp — do NOT set hasGranular.
          // When absent, ObjC defaults are used (0.30, 0.25, 0.35, 0.20).
          if ([params[@"faceWhitenStrength"] isKindOfClass:[NSNumber class]]) {
            v2.faceWhitenStrength = [params[@"faceWhitenStrength"] floatValue];
          }
          if ([params[@"faceRosyStrength"] isKindOfClass:[NSNumber class]]) {
            v2.faceRosyStrength = [params[@"faceRosyStrength"] floatValue];
          }
          if ([params[@"faceToneUnifyStrength"]
                  isKindOfClass:[NSNumber class]]) {
            v2.faceToneUnifyStrength =
                [params[@"faceToneUnifyStrength"] floatValue];
          }
          if ([params[@"faceGlowStrength"] isKindOfClass:[NSNumber class]]) {
            v2.faceGlowStrength = [params[@"faceGlowStrength"] floatValue];
          }
          // Phase 4C.3 (DEC-76/78): feature protection & enhancement overrides.
          // Independent of the intensity ramp — do NOT set hasGranular.
          // When absent, ObjC defaults are used (0.40, 0.35, 0.25, 0.20).
          if ([params[@"featureRestoreStrength"]
                  isKindOfClass:[NSNumber class]]) {
            v2.featureRestoreStrength =
                [params[@"featureRestoreStrength"] floatValue];
          }
          if ([params[@"featureDetailRestore"]
                  isKindOfClass:[NSNumber class]]) {
            v2.featureDetailRestore =
                [params[@"featureDetailRestore"] floatValue];
          }
          if ([params[@"featureContrastBoost"]
                  isKindOfClass:[NSNumber class]]) {
            v2.featureContrastBoost =
                [params[@"featureContrastBoost"] floatValue];
          }
          if ([params[@"featureSatBoost"] isKindOfClass:[NSNumber class]]) {
            v2.featureSatBoost = [params[@"featureSatBoost"] floatValue];
          }
          // Phase 4D (DEC-82/84): perceptual feature enhancement overrides.
          // Independent of the intensity ramp — do NOT set hasGranular.
          // When absent, ObjC defaults are used (0.0 — 4D disabled).
          if ([params[@"eyeEnhanceStrength"] isKindOfClass:[NSNumber class]]) {
            v2.eyeEnhanceStrength = [params[@"eyeEnhanceStrength"] floatValue];
          }
          if ([params[@"lipEnhanceStrength"] isKindOfClass:[NSNumber class]]) {
            v2.lipEnhanceStrength = [params[@"lipEnhanceStrength"] floatValue];
          }
          if ([params[@"browEnhanceStrength"] isKindOfClass:[NSNumber class]]) {
            v2.browEnhanceStrength =
                [params[@"browEnhanceStrength"] floatValue];
          }
          // Phase 4E (DEC-90/92): tone polish layer overrides.
          // Independent of the intensity ramp — do NOT set hasGranular.
          // When absent, ObjC defaults are used (0.0 — 4E disabled).
          if ([params[@"polishGlowStrength"] isKindOfClass:[NSNumber class]]) {
            v2.polishGlowStrength = [params[@"polishGlowStrength"] floatValue];
          }
          if ([params[@"polishSmoothStrength"]
                  isKindOfClass:[NSNumber class]]) {
            v2.polishSmoothStrength =
                [params[@"polishSmoothStrength"] floatValue];
          }
          if ([params[@"polishWarmthStrength"]
                  isKindOfClass:[NSNumber class]]) {
            v2.polishWarmthStrength =
                [params[@"polishWarmthStrength"] floatValue];
          }
          if ([params[@"polishBloomStrength"] isKindOfClass:[NSNumber class]]) {
            v2.polishBloomStrength =
                [params[@"polishBloomStrength"] floatValue];
          }
          if (hasGranular) {
            // Explicit granular params present — disable ramp so they survive
            // every processEnvelope: call without being overwritten.
            v2.useIntensityRamp = NO;
          }

          node = v2;
          NSLog(@"[VGRuntime] Beauty V2 selected (beautyVersion=2)");
        } else {
          // V2 allocation failed — fall back to V1 silently.
          NSLog(@"[VGRuntime] Beauty V2 alloc failed — falling back to V1");
          wantV2 = NO; // fall through to V1 block below
        }
      }

      if (!wantV2) {
        // ── Beauty V1 path (default) ─────────────────────────────────────────
        // Exactly as before Step 4 — no behavioral change.
        VanguardBeautyFilterNode *beauty =
            [[VanguardBeautyFilterNode alloc] initWithPool:pool device:device];
        if ([params[@"intensity"] isKindOfClass:[NSNumber class]]) {
          beauty.intensity = [params[@"intensity"] floatValue];
        }
        if ([params[@"radius"] isKindOfClass:[NSNumber class]]) {
          beauty.radius = [params[@"radius"] intValue];
        }
        beauty.enabled = enabled;
        node = beauty;
      }

    } else if ([type isEqualToString:@"segmentation"]) {
      VanguardSegmentationFilterNode *seg =
          [[VanguardSegmentationFilterNode alloc] initWithPool:pool
                                                        device:device];
      seg.enabled = enabled;
      node = seg;
    }

    if (node)
      [nodes addObject:node];
  }

  // ── Phase 4F (DEC-100, DEC-109 UPDATE): always insert VGSegmentationNode ──
  // Always insert VGSegmentationNode before BeautyV2FilterGroup, with enabled
  // mirrored from beauty.faceAwareEnabled. This supports runtime toggling
  // without requiring a graph rebuild:
  //   enabled=YES → face detection + mask gen + metadata attachment (normal)
  //   enabled=NO  → true passthrough: no face detection, no CPU work, no
  //                  metadata (processEnvelope: returns envelope unchanged)
  NSMutableArray<id<VGMetalFilterNode>> *finalNodes =
      [NSMutableArray arrayWithCapacity:nodes.count + 1];
  BOOL segInserted = NO;
  for (id<VGMetalFilterNode> n in nodes) {
    if (!segInserted && [n isKindOfClass:[BeautyV2FilterGroup class]]) {
      BeautyV2FilterGroup *beauty = (BeautyV2FilterGroup *)n;
      // Phase 9B-4: delegate construction to the gated factory helper.
      // With VG_ML_SEGMENTATION_ENABLED=0 (default) this expands to the
      // identical [[VGSegmentationNode alloc] initWithPool:pool device:device]
      // call — zero production behaviour change.
      VGSegmentationNode *segNode =
          [VGCameraGraphFactory makeSegmentationNodeWithPool:pool device:device];
      segNode.enabled = beauty.faceAwareEnabled;
      [finalNodes addObject:segNode];
      segInserted = YES;
      NSLog(@"[VGRuntime] VGSegmentationNode auto-inserted before BeautyV2 "
             "(Phase 4F, enabled=%d)",
            (int)beauty.faceAwareEnabled);
    }
    [finalNodes addObject:n];
  }

  // ── 3. Apply via the existing thread-safe setter ──────────────────────────
  [self setFilterChain:[finalNodes copy]];
  return YES;
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
///   critical         → all nodes disabled (chain stays in place; zero GPU
///   work)
///
/// Thread-safety: called from main thread via VGPluginLifecycleObserver
/// (registered with queue: .main). node.enabled is @property (nonatomic,
/// assign), but since the runtime chain is always accessed from the renderer's
/// videoDecodeQueue for reads, and we only write from main here, the window for
/// a data race is identical to the pre-existing _filterChainEnabled pattern
/// in VanguardMetalRenderer (same queue contract). Acceptable in P3-3/P3-4.
///
/// Phase 4C: V2 path applies the identical algorithm directly to
/// filterChainStorage nodes because VGLegacyFilterAdapter.enabled delegates
/// to the wrapped VGMetalFilterNode, and VGGraphSchedulerV2 checks
/// transform.enabled before processing (DEC-55). No graph rebuild required.
- (void)setRuntimeThermalState:(NSProcessInfoThermalState)state {
#if VG_USE_V2_GRAPH
  if (self.schedulerV2) {
    // Phase 4C: V2 thermal policy.
    // Apply cost-budget directly to filterChainStorage nodes.
    // VGGraphSchedulerV2 checks transform.enabled via VGLegacyFilterAdapter
    // passthrough (VGGraphSchedulerV2.m:300, VGLegacyFilterAdapter.m:71-76).
    // No graph rebuild or scheduler hot-swap is required.
    [self _applyThermalBudgetToChain:self.filterChainStorage state:state];
    return;
  }
#endif
  // V1 path unchanged.
  // P4-9: Thermal policy owned by VanguardGraphScheduler (cost-budget
  // model, DEC-55 / RR-33 closure). Runtime delegates unconditionally.
  [self.scheduler applyThermalState:state];
}

// ─── Private helpers
// ──────────────────────────────────────────────────────────

// Phase 4C: V2 thermal cost-budget helper.
//
// Implements the identical 5-step algorithm from
// VanguardGraphScheduler.applyThermalState: (lines 111-202), operating
// directly on the VGMetalFilterNode objects in filterChainStorage.
//
// V2 path: VGLegacyFilterAdapter.enabled delegates to wrapped filter.enabled.
// VGGraphSchedulerV2 checks transform.enabled and skips disabled nodes
// (DEC-55).
//
// Algorithm:
//   1. Empty chain → no-op.
//   2. Budget: Nominal/Fair → FLT_MAX, Serious → 5.0ms, Critical → 0.0ms.
//   3. Enable all nodes.
//   4. Compute totalCostMs.
//   5. Greedy-disable most expensive first until totalCostMs <= budget.
//
// Thread-safety: same main-thread write / _videoDecodeQueue read window as V1.
// No lock required — identical race profile to
// VanguardGraphScheduler.m:121-125.
- (void)_applyThermalBudgetToChain:(NSArray<id<VGMetalFilterNode>> *)chain
                             state:(NSProcessInfoThermalState)state {
  if (!chain.count) {
    NSLog(@"[VanguardGraphRuntime] V2 applyThermalBudget: empty chain — no-op");
    return;
  }

  // ── 1. Select tier budget ────────────────────────────────────────────────
  // Thresholds identical to VanguardGraphScheduler.m (P4-9, RR-33).
  float budgetMs;
  switch (state) {
  case NSProcessInfoThermalStateNominal:
  case NSProcessInfoThermalStateFair:
    budgetMs = FLT_MAX;
    break;
  case NSProcessInfoThermalStateSerious:
    budgetMs = 5.0f;
    break;
  case NSProcessInfoThermalStateCritical:
    budgetMs = 0.0f;
    break;
  default:
    NSLog(@"[VanguardGraphRuntime] V2 applyThermalBudget: unknown state %ld — "
          @"no-op",
          (long)state);
    return;
  }

  // ── 2. Enable all nodes ──────────────────────────────────────────────────
  for (id<VGMetalFilterNode> node in chain) {
    node.enabled = YES;
  }

  // ── 3. Compute total estimated GPU cost ──────────────────────────────────
  float totalCostMs = 0.0f;
  for (id<VGMetalFilterNode> node in chain) {
    totalCostMs += node.estimatedGPUCostMs;
  }

  // ── 4. Greedy disable: most expensive first until totalCost <= budget ────
  if (totalCostMs > budgetMs) {
    NSArray<id<VGMetalFilterNode>> *sorted =
        [chain sortedArrayUsingComparator:^NSComparisonResult(
                   id<VGMetalFilterNode> a, id<VGMetalFilterNode> b) {
          float costA = a.estimatedGPUCostMs;
          float costB = b.estimatedGPUCostMs;
          if (costA > costB)
            return NSOrderedAscending; // most expensive first
          if (costA < costB)
            return NSOrderedDescending;
          return NSOrderedSame;
        }];

    for (id<VGMetalFilterNode> node in sorted) {
      if (totalCostMs <= budgetMs)
        break;
      node.enabled = NO;
      totalCostMs -= node.estimatedGPUCostMs;
    }
  }

  NSLog(@"[VanguardGraphRuntime] V2 applyThermalBudget: state=%ld "
        @"budget=%.1fms remaining=%.1fms nodes=%lu",
        (long)state, budgetMs, totalCostMs, (unsigned long)chain.count);
}

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
    NSUInteger bytesToRelease = _sessionPoolBytes;
    _sessionPool = NULL;
    _sessionPoolBytes = 0;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
          BOOL already = atomic_exchange(&self->_poolReleased, YES);
          if (!already) {
            CVPixelBufferPoolRelease(poolToRelease);
            if (bytesToRelease > 0) {
              [[VGResourceAllocator sharedInstance]
                  reportPoolReleased:bytesToRelease];
            }
            NSLog(@"[VanguardGraphRuntime] P4-8 dealloc: pool=%p released "
                  @"via dispatch_after fallback",
                  poolToRelease);
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
  // Phase 4 Batch 3: V2 scheduler safety net.
#if VG_USE_V2_GRAPH
  if (self.schedulerV2) {
    [self.schedulerV2 invalidate];
  }
  // Phase 7 Stage 7.5C: timeline display link safety net.
  if (self.timelineDisplayLink) {
    [self.timelineDisplayLink invalidate];
    self.timelineDisplayLink = nil;
  }
#endif
}

// ─── Phase 7 Stage 7.5C: Timeline Playback Proof ─────────────────────────────
//
// All code in this section is gated behind #if VG_USE_V2_GRAPH.
// When VG_USE_V2_GRAPH=0, this section is entirely removed by the preprocessor.
// The V1 playback path (prepareWithURL:completion:) is completely unmodified.
//
// Implementation pattern:
//
//   1. prepareWithTimelineCompositorNode:completion:
//      - Dispatches off-main via _prepareQueue (matches prepareWithURL:
//      contract).
//      - Calls prepareWithContext:completion: on the compositor node.
//      - Creates a VanguardMetalRenderer (no media source — compositor drives
//      frames).
//      - Builds the graph via VGTimelinePlaybackGraphFactory.
//      - Registers a Flutter texture from the renderer.
//      - Wires a CADisplayLink (target = self, selector =
//      _timelineDisplayLinkFired:).
//      - CADisplayLink is created on the main thread (CADisplayLink
//      requirement).
//      - completion fires on the main thread with textureId.
//
//   2. _timelineDisplayLinkFired:
//      - Fires on the main thread at ~60fps (CADisplayLink default).
//      - When timelineIsPlaying: advances timelineCurrentPTS by
//      displayLink.duration.
//      - Creates VGFrameRequest at current PTS.
//      - Calls [timelineCompositor pullFrame:request] on a background serial
//      queue
//        (to avoid blocking the main thread for AVAssetReader decode work).
//      - On VGFrameStatusDelivered: calls [timelineSinkAdapter
//      presentEnvelope:]
//        → [renderer presentEnvelope:] → Flutter texture update.
//      - On VGFrameStatusSkipped: no-op (stale generation after seek).
//      - On VGFrameStatusEndOfStream: stops display link (pauses at EOS).
//
//   3. play / pause / seekTimelineTo:
//      - play: sets timelineIsPlaying = YES (display link is already running).
//      - pause: sets timelineIsPlaying = NO (display link still ticks for
//      scrub).
//      - seekTimelineTo: increments generation, updates currentPTS,
//        calls [compositor seekTo:generation:], optionally pulls one preview
//        frame.
//
// Apple Framework Contract Verification:
//
//   CADisplayLink:
//     - Must be created on the main thread and added to NSRunLoop.main.
//     - Target must not be retained by a strong reference in the display link
//       (strong would create a retain cycle: runtime → displayLink → runtime).
//       Solution: __weak self in _timelineDisplayLinkFired:.
//     - displayLink.duration ≈ 1/60 on 60Hz, 1/120 on ProMotion.
//       We advance PTS by duration per tick (not hardcoded 1/30) for smooth
//       cadence on all display types.
//     - Reference: UIKit / QuartzCore docs, WWDC 2021 "Optimize for Variable
//       Refresh Rate Displays".
//
//   VGFrameRequest:
//     - initWithRequestedPTS:duration:generation:renderSize:mode: is the
//       designated initializer (VGFrameRequest.h).
//     - mode = VGRenderModePlayback for this path.
//     - generation must match the compositor's atomic generation to receive
//       VGFrameStatusDelivered; mismatches return VGFrameStatusSkipped.
//
//   VGRendererSinkAdapter.presentEnvelope: (VGRendererSinkAdapter.m:74):
//     - Delegates to [renderer presentEnvelope:].
//     - renderer stores the CVPixelBuffer under os_unfair_lock (+1 retain)
//       and dispatches textureFrameAvailable: to main queue.
//     - Safe to call from the pull queue (VGRendererSinkAdapter is
//     thread-safe).
//
//   VanguardMetalRenderer (no source):
//     - initWithSource: requires a non-nil id<VanguardMediaSource>.
//     - WORKAROUND for Stage 7.5C: we need the renderer for Flutter texture
//       registration and Metal device access, but the source is the compositor.
//     - The compositor is not a VanguardMediaSource (it's a UMF VGSourceNode).
//     - Therefore: create the renderer with the compositor as a nil source
//     stand-in
//       by using a synthetic minimal source adapter that satisfies the
//       renderer's init guard but never produces frames.
//     - This is the ONLY place a synthetic source adapter is used.
//     - The renderer's CADisplayLink / decode-queue path is NEVER started
//       (we never call renderer.play). All frame delivery goes through
//       VGRendererSinkAdapter.presentEnvelope: instead.
//
// BLOCKED_BY_RUNTIME_INTEGRATION_GAP assessment:
//   The issue is VanguardMetalRenderer requires a non-nil VanguardMediaSource.
//   The compositor does NOT conform to VanguardMediaSource (it's a UMF
//   VGSourceNode). RESOLUTION: we pass a zero-frame VanguardImageMediaSource as
//   the nominal source to satisfy renderer's init. The display link is never
//   started, so the image source never produces frames. The compositor drives
//   all frame delivery directly through VGRendererSinkAdapter.presentEnvelope:.
//   This is safe because renderer.play is never called in this path.
//   Reference:
//   VanguardMetalRenderer.initWithSource:textureRegistry:methodChannel:
//              sessionPool: does not call [source start] at init time.

#if VG_USE_V2_GRAPH

// ─── Pull queue (created once per runtime, shared across sessions)
// ─────────────
static dispatch_queue_t _VGTimelinePullQueue(void) {
  static dispatch_queue_t q;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    q = dispatch_queue_create("com.vanguard.timeline.pull",
                              DISPATCH_QUEUE_SERIAL);
  });
  return q;
}

// ─── prepareWithTimelineCompositorNode:completion:
// ────────────────────────────

- (void)prepareWithSourceNode:(id<VGSourceNode>)sourceNode
                   completion:(void (^)(int64_t textureId,
                                       NSError *_Nullable error))completion {
  NSParameterAssert(sourceNode != nil);
  NSParameterAssert(completion != nil);

  // Rename incoming arg to compositorNode for local use, preserving all
  // existing logic unchanged. activeSourceNode stores the generic reference.
  id<VGSourceNode> compositorNode = sourceNode;

  dispatch_async(_prepareQueue, ^{
    // ── Guard ──────────────────────────────────────────────────────────
    if (self->_invalidated) {
      NSError *err =
          [NSError errorWithDomain:@"VanguardGraphRuntimeErrorDomain"
                              code:1
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"[7.5C] Runtime already invalidated."
                          }];
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(-1, err);
      });
      return;
    }

    // ── 1. Prepare the compositor node ─────────────────────────────────
    //
    // VGGraphExecutionContext is required by prepareWithContext:completion:.
    // We create a minimal context. The compositor reads renderSize from it
    // during prepare to configure its AVAssetReader output settings.
    VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];
    VGGraphExecutionContext *ctx =
        [[VGGraphExecutionContext alloc] initWithDescriptor:nil
                                                       plan:nil
                                                      nodes:@{}
                                                      clock:nil
                                          resourceAllocator:allocator];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSError *prepError = nil;

    [compositorNode prepareWithContext:ctx
                            completion:^(NSError *err) {
                              prepError = err;
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
                                       @"[7.5C] Runtime invalidated during "
                                       @"compositor prepare."
                                 }];
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(-1, err);
      });
      return;
    }

    // ── 2. Create renderer with a minimal image source stand-in ────────
    //
    // VanguardMetalRenderer.initWithSource: requires non-nil
    // id<VanguardMediaSource>. VGTimelineCompositorNode is a UMF VGSourceNode,
    // not a VanguardMediaSource.
    //
    // Resolution (see Apple Framework Contract above):
    //   Pass a VanguardImageMediaSource backed by a zero-frame synthetic
    //   asset. The renderer's CADisplayLink / decode path is NEVER started
    //   (we do not call renderer.play). All frame delivery is via
    //   VGRendererSinkAdapter.presentEnvelope: from our pull loop.
    //
    // We use the standard 1×1 pixel transparent PNG inline (no bundled asset,
    // MOD-6 compliant). VanguardImageMediaSource reads it; the render size
    // will be 1×1, but the compositor provides 1920×1080 buffers anyway.
    //
    // NOTE: This is the ONLY approved workaround in Stage 7.5C for the
    // renderer-requires-source constraint. It must be revisited in Stage 7.6
    // when VanguardMetalRenderer gains a source-free init path.
    NSString *syntheticImagePath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"vg_7_5c_placeholder.png"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:syntheticImagePath]) {
      // Write a 1×1 transparent PNG (89-byte minimal PNG).
      static const uint8_t kMinimalPNG[] = {
          0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
          0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
          0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1×1
          0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, // RGBA 8-bit
          0x89, 0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41, // IDAT chunk
          0x54, 0x08, 0xD7, 0x63, 0x60, 0x60, 0x60, 0x60,
          0x00, 0x00, 0x00, 0x05, 0x00, 0x01, 0xA5, 0xF6,
          0x45, 0x40, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, // IEND chunk
          0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82};
      NSData *pngData = [NSData dataWithBytes:kMinimalPNG
                                       length:sizeof(kMinimalPNG)];
      [pngData writeToFile:syntheticImagePath atomically:YES];
    }

    NSURL *placeholderURL = [NSURL fileURLWithPath:syntheticImagePath];
    VanguardImageMediaSource *placeholderSource =
        [[VanguardImageMediaSource alloc] initWithURL:placeholderURL
                                            processor:nil];

    // Create a minimal pool for the renderer (1×1 — renderer needs one).
    CVPixelBufferPoolRef tinyPool =
        [allocator pixelBufferPoolWithWidth:1
                                     height:1
                                     format:kCVPixelFormatType_32BGRA
                         minimumBufferCount:1];

    VanguardMetalRenderer *renderer =
        [[VanguardMetalRenderer alloc] initWithSource:placeholderSource
                                      textureRegistry:self.textureRegistry
                                        methodChannel:self.methodChannel
                                          sessionPool:tinyPool];

    if (tinyPool) {
      CVPixelBufferPoolRelease(tinyPool);
    }

    if (!renderer || self->_invalidated) {
      NSError *err =
          [NSError errorWithDomain:@"VanguardGraphRuntimeErrorDomain"
                              code:3
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"[7.5C] Failed to create "
                                @"VanguardMetalRenderer for timeline."
                          }];
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(-1, err);
      });
      return;
    }

    // ── 3. Build graph via VGTimelinePlaybackGraphFactory ──────────────
    NSError *factoryError = nil;
    NSDictionary<NSString *, id> *graphResult = [VGTimelinePlaybackGraphFactory
        buildTimelineGraphWithCompositorNode:compositorNode
                                    renderer:renderer
                                       error:&factoryError];

    if (!graphResult || self->_invalidated) {
      NSError *err =
          factoryError
              ?: [NSError errorWithDomain:@"VanguardGraphRuntimeErrorDomain"
                                     code:4
                                 userInfo:@{
                                   NSLocalizedDescriptionKey :
                                       @"[7.5C] VGTimelinePlaybackGraphFactory "
                                       @"failed."
                                 }];
      [renderer dispose];
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(-1, err);
      });
      return;
    }

    VGRendererSinkAdapter *sinkAdapter = graphResult[@"sinkAdapter"];

    // ── 4. Store all timeline state ────────────────────────────────────
    self.renderer = renderer;
    self.activeSourceNode = compositorNode;
    self.timelineSinkAdapter = sinkAdapter;
    self.timelineGeneration = 0;
    self.timelineCurrentPTS = 0.0;
    self.timelineIsPlaying = NO;
    // [7.5C] Init wall-clock anchors.
    self.timelinePlayStartTime = 0.0;
    self.timelineBasePTS = 0.0;
    self.timelineNeedsPreviewFrame = YES;

    int64_t tid = renderer.textureId;
    self.textureId = tid;
    self.state = VGRuntimeStatePrepared;

    // Phase 10-C Slice C: publish initial valid snapshot before completion
    // fires. All five mapped fields are at their zero/prepared values.
    [self _publishTimelineSnapshot];

    NSLog(@"[VanguardGraphRuntime][7.5C] timeline runtime prepared "
           "textureId=%lld nodeId=%@",
          (long long)tid, compositorNode.nodeId);

    // ── 5. Wire CADisplayLink on main thread ───────────────────────────
    //
    // CADisplayLink must be created on the thread whose run loop it
    // will be added to. We create it on the main thread.
    // References:
    //   - CADisplayLink.h: "displayLink should be added to a run loop"
    //   - Apple doc "Optimizing ProMotion Refresh Rates"
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self->_invalidated) {
        completion(
            -1,
            [NSError
                errorWithDomain:@"VanguardGraphRuntimeErrorDomain"
                           code:1
                       userInfo:@{
                         NSLocalizedDescriptionKey :
                             @"[7.5C] Invalidated before display link created."
                       }]);
        return;
      }

      CADisplayLink *displayLink = [CADisplayLink
          displayLinkWithTarget:self
                       selector:@selector(_timelineDisplayLinkFired:)];
      // Do NOT set preferredFramesPerSecond — let the display choose its
      // native rate (60 or 120 Hz). The pull loop only pulls a new frame
      // when timelineIsPlaying or when a seek was requested, so there is
      // no decode overhead from ticking at 120Hz while paused.
      [displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                        forMode:NSRunLoopCommonModes];
      self.timelineDisplayLink = displayLink;

      completion(tid, nil);
    });
  });
}

// ─── Display link pull loop
// ────────────────────────────────────────────────────

- (void)_timelineDisplayLinkFired:(CADisplayLink *)displayLink {
  // Must be on the main thread (CADisplayLink contract).
  NSAssert([NSThread isMainThread],
           @"[7.5C] _timelineDisplayLinkFired: must fire on the main thread");

  if (_invalidated) {
    [displayLink invalidate];
    return;
  }

  // [7.5C] Suppress continuous pulls while paused.
  // Only proceed if actively playing OR a one-shot preview frame is pending.
  if (!self.timelineIsPlaying && !self.timelineNeedsPreviewFrame) {
    return;
  }
  self.timelineNeedsPreviewFrame = NO;

  id<VGSourceNode> sourceNode = self.activeSourceNode;
  VGRendererSinkAdapter *sink = self.timelineSinkAdapter;
  if (!sourceNode || !sink)
    return;

  // [7.5C] Advance PTS using wall-clock elapsed time anchored at play start.
  // Do NOT accumulate displayLink.duration — that path drifts at high display
  // rates and was consuming frames during the paused window before play.
  if (self.timelineIsPlaying) {
    double elapsed = CACurrentMediaTime() - self.timelinePlayStartTime;
    self.timelineCurrentPTS = self.timelineBasePTS + elapsed;
    // Phase 10-C Slice C: publish updated PTS before dispatching the pull.
    // Must occur after timelineCurrentPTS is written and before the pull
    // block captures currentPTS below.
    [self _publishTimelineSnapshot];
  }

  // Capture snapshot of PTS and generation for this tick.
  double currentPTS = self.timelineCurrentPTS;
  uint64_t generation = self.timelineGeneration;

  // Build the frame request.
  CMTime pts = CMTimeMakeWithSeconds(currentPTS, 600);
  CMTime duration = CMTimeMakeWithSeconds(displayLink.duration, 600);
  VGFrameRequest *request =
      [[VGFrameRequest alloc] initWithRequestedPTS:pts
                                          duration:duration
                                        generation:generation
                                        renderSize:CGSizeMake(1920, 1080)
                                              mode:VGRenderModePreview];

  // Pull on the serial pull queue so AVAssetReader.copyNextSampleBuffer
  // does not block the main thread.
  __weak id<VGSourceNode> weakSourceNode = sourceNode;
  __weak VGRendererSinkAdapter *weakSink = sink;
  __weak typeof(self) weakSelf = self;

  dispatch_async(_VGTimelinePullQueue(), ^{
    id<VGSourceNode> c = weakSourceNode;
    VGRendererSinkAdapter *s = weakSink;
    if (!c || !s)
      return;

    VGFrameResult *result = [c pullFrame:request];
    if (!result)
      return;

    switch (result.status) {
    case VGFrameStatusDelivered: {
      // Forward the envelope to the sink.
      // VGRendererSinkAdapter.presentEnvelope: retains the pixel buffer
      // and dispatches textureFrameAvailable: to main queue.
      [s presentEnvelope:result.envelope];

      // Update PTS display on main thread.
      double pts_s = CMTimeGetSeconds(result.envelope.pts);
      dispatch_async(dispatch_get_main_queue(), ^{
        // Post a method channel notification for Dart PTS overlay.
        // Dart playground listens on the same channel for 'onTimelineFrame'.
        typeof(self) ss = weakSelf;
        if (!ss || ss->_invalidated)
          return;
        [ss.methodChannel
            invokeMethod:@"onTimelineFrame"
               arguments:[ss vg_timelineFrameArgumentsForPTS:pts_s
                                                  generation:generation]];
      });
      break;
    }
    case VGFrameStatusSkipped:
      // Stale generation — no action.
      break;
    case VGFrameStatusEndOfStream: {
      // Reached EOS — stop playing, notify Dart.
      dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) ss = weakSelf;
        if (!ss || ss->_invalidated)
          return;
        ss.timelineIsPlaying = NO;
        // Phase 10-C Slice C: publish stopped state after EOS.
        // Snapshot remains isValid == YES — the runtime is still prepared.
        [ss _publishTimelineSnapshot];
        // Phase 10-C Slice D: stop audio preview on EOS.
        [ss.audioPreviewRuntime commandEOS];
        [ss.methodChannel invokeMethod:@"onTimelineEOS"
                             arguments:[ss vg_timelineEOSArguments]];
        NSLog(@"[VanguardGraphRuntime][7.5C] timeline EOS reached "
               "PTS=%.3f",
              currentPTS);
      });
      break;
    }
    case VGFrameStatusError:
      NSLog(@"[VanguardGraphRuntime][7.5C] pullFrame error: %@",
            result.error.localizedDescription);
      break;
    }
  });
}

// ─── play / pause forwarding for timeline path
// ────────────────────────────────
//
// The base class play/pause call [renderer play] / [renderer pause] which
// drives the VanguardMetalRenderer's CADisplayLink. In the timeline path, the
// renderer's CADisplayLink must NOT be started (it has a placeholder image
// source and would produce garbage frames). We override the start/stop in
// _timelineDisplayLinkFired: via timelineIsPlaying — no change to the base
// class play/pause is required because the timeline path is entered via
// prepareWithTimelineCompositorNode: rather than prepareWithURL:, and the
// renderer's play/pause are wrapped here.
//
// The Dart playground calls play/pause/seekTo via the standard dev_ method
// channel routes which call [runtime play] / [runtime pause] / [runtime
// seekTo:]. Those call [renderer play] etc. — which is a no-op for the
// placeholder source. The effective timeline play/pause state is
// timelineIsPlaying.
//
// For Stage 7.5C: the Dart playground controls timelineIsPlaying directly via
// the dev_createTimelineTexture / dev_ play/pause/seekTo method channel cases
// in VanguardMediaEnginePlugin.swift, which call the timeline-specific methods
// below.

// ─── seekTimelineTo: ─────────────────────────────────────────────────────────

- (void)seekTimelineTo:(double)seconds {
  // May be called from any thread (Dart method channel arrives on main queue).
  // Update PTS and increment generation on the main queue for CADisplayLink
  // safety.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_invalidated)
      return;

    // Increment generation atomically.
    uint64_t newGeneration = self.timelineGeneration + 1;
    self.timelineGeneration = newGeneration;
    self.timelineCurrentPTS = MAX(0.0, seconds);

    // [7.5C] Request one preview frame so the seek position is rendered
    // even while paused. The display link normally returns early when
    // paused (!timelineIsPlaying && !timelineNeedsPreviewFrame).
    self.timelineNeedsPreviewFrame = YES;

    // [7.5C] Re-anchor wall-clock if playing, so PTS doesn't jump after seek.
    if (self.timelineIsPlaying) {
      self.timelinePlayStartTime = CACurrentMediaTime();
      self.timelineBasePTS = self.timelineCurrentPTS;
    }

    // Phase 10-C Slice C: all seek mutations are complete; publish one coherent
    // snapshot before dispatching the compositor seek (which runs on the pull
    // queue and does not touch snapshot state).
    [self _publishTimelineSnapshot];
    // Phase 10-C Slice D: forward seek command to audio preview runtime.
    // Must be called after the snapshot is published so the audio runtime
    // reads the updated PTS and generation when it rereads the snapshot.
    [self.audioPreviewRuntime commandSeek];

    // Forward seek to compositor (timeline path) on pull queue.
    // Guard: only VGTimelineCompositorNode supports seekTo:generation:.
    id<VGSourceNode> node = self.activeSourceNode;
    if (![node isKindOfClass:[VGTimelineCompositorNode class]])
      return;
    VGTimelineCompositorNode *compositor = (VGTimelineCompositorNode *)node;

    CMTime seekTime = CMTimeMakeWithSeconds(seconds, 600);
    dispatch_async(_VGTimelinePullQueue(), ^{
      [compositor seekTo:seekTime generation:newGeneration];
      NSLog(@"[VanguardGraphRuntime][7.5C] seekTimelineTo: %.3f "
             "generation=%llu",
            seconds, (unsigned long long)newGeneration);
    });
  });
}

// ─── Timeline play/pause convenience ─────────────────────────────────────────

- (void)_timelinePlay {
  NSAssert([NSThread isMainThread],
           @"[7.5C] _timelinePlay must be on main thread");
  // [7.5C] Anchor the wall-clock at the moment play is pressed.
  // All subsequent PTS advances are computed as:
  //   timelineCurrentPTS = timelineBasePTS + (CACurrentMediaTime() - timelinePlayStartTime)
  self.timelinePlayStartTime = CACurrentMediaTime();
  self.timelineBasePTS = self.timelineCurrentPTS;
  self.timelineIsPlaying = YES;
  self.state = VGRuntimeStateRunning;
  // Phase 10-C Slice C: publish after all play anchors are set.
  [self _publishTimelineSnapshot];
  // Phase 10-C Slice D: forward play command to audio preview runtime.
  [self.audioPreviewRuntime commandPlay];
  NSLog(@"[VanguardGraphRuntime][7.5C] timeline play — PTS=%.3f",
        self.timelineCurrentPTS);
}

- (void)_timelinePause {
  NSAssert([NSThread isMainThread],
           @"[7.5C] _timelinePause must be on main thread");
  self.timelineIsPlaying = NO;
  self.state = VGRuntimeStatePaused;
  // Phase 10-C Slice C: publish frozen PTS after pause.
  // timelineCurrentPTS retains its last display-link-computed value (correct).
  [self _publishTimelineSnapshot];
  // Phase 10-C Slice D: forward pause command to audio preview runtime.
  [self.audioPreviewRuntime commandPause];
  NSLog(@"[VanguardGraphRuntime][7.5C] timeline pause — PTS=%.3f",
        self.timelineCurrentPTS);
}

// ─── Phase 7.18B1: Cache metrics forwarding ───────────────────────────────
// These methods forward to the active source node's timeline cache.
// Both guard: only VGTimelineCompositorNode supports cacheStatistics/flushFrameCache.
// For any other id<VGSourceNode> (e.g. future VGDualCameraCompositorNode),
// these methods safely no-op or return empty defaults.

- (NSDictionary<NSString *, NSNumber *> *)timelineCacheStatistics {
  id<VGSourceNode> node = self.activeSourceNode;
  if (![node isKindOfClass:[VGTimelineCompositorNode class]]) {
    return @{};
  }
  return [(VGTimelineCompositorNode *)node cacheStatistics];
}

- (void)flushTimelineCaches {
  id<VGSourceNode> node = self.activeSourceNode;
  if (![node isKindOfClass:[VGTimelineCompositorNode class]]) {
    return;
  }
  [(VGTimelineCompositorNode *)node flushFrameCache];
}

// ─── Phase 10-C Slice C: snapshot publication and reader ─────────────────────

/// Copies the current timeline state into _timelineSnapshotState under lock.
///
/// Called on the main thread at the end of each logical state transition,
/// AFTER all property mutations for that transition are complete.
/// Exception: the initial call in prepareWithSourceNode: runs on _prepareQueue
/// before the completion callback fires, when no reader can yet exist.
///
/// If _invalidated is YES, forces isValid and isPlaying to NO without copying
/// active state. Once the snapshot is invalid it cannot become valid again.
- (void)_publishTimelineSnapshot {
  os_unfair_lock_lock(&_timelineSnapshotLock);
  if (!_invalidated) {
    _timelineSnapshotState.timelinePTS       = self.timelineCurrentPTS;
    _timelineSnapshotState.playStartHostTime = self.timelinePlayStartTime;
    _timelineSnapshotState.playStartPTS      = self.timelineBasePTS;
    _timelineSnapshotState.generation        = self.timelineGeneration;
    _timelineSnapshotState.isPlaying         = self.timelineIsPlaying;
    // Explicit valid-state predicate — do not use numerical enum ordering.
    _timelineSnapshotState.isValid = (
        self.state == VGRuntimeStatePrepared ||
        self.state == VGRuntimeStateRunning  ||
        self.state == VGRuntimeStatePaused   ||
        self.state == VGRuntimeStateEnded);
  } else {
    // Monotonic invalidity: once invalid, never restore isValid.
    _timelineSnapshotState.isValid   = NO;
    _timelineSnapshotState.isPlaying = NO;
    // Timing and generation fields are preserved for forensic readers.
  }
  os_unfair_lock_unlock(&_timelineSnapshotLock);
}

- (VGTimelineStateSnapshot)readTimelineStateSnapshot {
  os_unfair_lock_lock(&_timelineSnapshotLock);
  VGTimelineStateSnapshot copy = _timelineSnapshotState;
  os_unfair_lock_unlock(&_timelineSnapshotLock);
  return copy;
}

#endif // VG_USE_V2_GRAPH

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Channel payload helpers
// ─────────────────────────────────────────────────────────────────────────────
//
// Private instance helpers — single authoritative source for argument
// dictionary shapes used by production dispatch sites and the
// VGGraphRuntimeLifecycleTest argument-capture seams. Kept implementation-
// private; declared only in the class extension above.

- (NSDictionary *)vg_timelineFrameArgumentsForPTS:(double)pts
                                        generation:(NSInteger)generation {
  return @{
    @"textureId" : @(self.textureId),
    @"pts"       : @(pts),
    @"generation": @(generation)
  };
}

- (NSDictionary *)vg_timelineEOSArguments {
  return @{@"textureId" : @(self.textureId)};
}

@end
