// TRANSITIONAL WRAPPER — Phase 1 only. Internals will be replaced in Phase 2.
//
// VanguardGraphRuntime.m
// Vanguard Media Engine — Phase 1B, P1B-01
//
// Thin coordinator that delegates to VanguardMetalRenderer and the appropriate
// Vanguard source class. Proofs that the VGGraphRuntime contract works end-to-end
// without altering any production code paths (C-2, C-4, C-6).
//
// Pixel-buffer pool is sourced exclusively from [VGResourceAllocator sharedInstance],
// ending the pool-backfill hack (VanguardFileMediaSource.pixelBufferPool write site
// is no longer required in this code path).
//
// Constraints honoured:
//   C-2  — not wired to any plugin/production path.
//   C-4  — zero opportunistic fixes.
//   C-6  — VanguardMetalRenderer, VanguardEngineMode shim, camera/export files untouched.

#import "VanguardGraphRuntime.h"

// Vanguard concrete classes
#import "VanguardMetalRenderer.h"
#import "VanguardFileMediaSource.h"
#import "VanguardImageMediaSource.h"
#import "VanguardImageProcessor.h"

// UMF shared infrastructure
#import <UMF/VGResourceAllocator.h>
#import <stdatomic.h>

// ─── Image-type UTI helpers ───────────────────────────────────────────────────
// A lightweight set of known image extensions; avoids importing MobileCoreServices.
static BOOL VGRIsImageURL(NSURL *url) {
    static NSSet<NSString *> *kImageExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        kImageExtensions = [NSSet setWithObjects:
            @"jpg", @"jpeg", @"png", @"heic", @"heif", @"webp", @"gif",
            @"tif", @"tiff", @"bmp", nil];
    });
    return [kImageExtensions containsObject:url.pathExtension.lowercaseString];
}

// ─── VanguardGraphRuntime (private extension) ─────────────────────────────────

@interface VanguardGraphRuntime ()

// Flutter dependencies — injected at init, never nil after init.
@property (nonatomic, strong, readonly) id<FlutterTextureRegistry> textureRegistry;
@property (nonatomic, strong, readonly) FlutterMethodChannel       *methodChannel;

// Live graph components — nil until prepareWithURL:completion: succeeds.
@property (nonatomic, strong, nullable) VanguardMetalRenderer      *renderer;
@property (nonatomic, strong, nullable) id<VanguardMediaSource, VGMediaNode> source;

// Pool acquired from VGResourceAllocator — runtime owns the +1 reference
// for the session lifetime; released in _teardownResources.
@property (nonatomic, assign, nullable) CVPixelBufferPoolRef        sessionPool;

// Redeclare base-class properties as readwrite for internal mutation.
@property (nonatomic, readwrite) VGRuntimeState state;
@property (nonatomic, readwrite) int64_t        textureId;
@property (nonatomic, readwrite, nullable) id<VGMasterClock> masterClock;

// Phase 2 audio role — readwrite internally; readonly on public interface.
@property (nonatomic, readwrite) VGAudioRole desiredAudioRole;
@property (atomic, readwrite)   VGAudioRole effectiveAudioRole;
@property (nonatomic, readwrite) CGSize     renderSize;

// Preparation + post-prepare serial queue.
@property (nonatomic, strong) dispatch_queue_t prepareQueue;

@end

// ─── VGGraphRuntime Base Implementation ─────────────────────────────────────────
// UMF constraint C-7 dictates no @implementation inside UMF.
// But Objective-C requires it for VanguardGraphRuntime to subclass it.
@implementation VGGraphRuntime
@end

// ─── VanguardGraphRuntime ─────────────────────────────────────────────────────

@implementation VanguardGraphRuntime {
    // Atomic invalidation flag. Written exactly once (YES) in -invalidate.
    // Declared in .m so it is not part of the frozen public header.
    _Atomic(BOOL) _invalidated;
}

@synthesize state = _vg_state;
@synthesize textureId = _vg_textureId;
@synthesize masterClock = _vg_masterClock;
@synthesize desiredAudioRole   = _desiredAudioRole;
@synthesize effectiveAudioRole = _effectiveAudioRole;
@synthesize renderSize         = _renderSize;

// ─── Init ──────────────────────────────────────────────────────────────────────

/// Phase 2 designated initialiser — stores the desired audio role.
- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                          methodChannel:(FlutterMethodChannel *)channel
                       desiredAudioRole:(VGAudioRole)role {
    NSParameterAssert(registry != nil);
    NSParameterAssert(channel  != nil);

    self = [super init];
    if (!self) return nil;

    _textureRegistry    = registry;
    _methodChannel      = channel;
    _desiredAudioRole   = role;
    // Conservative default — prepare() resolves the effective role through the allocator.
    _effectiveAudioRole = VGAudioRoleMuted;
    _vg_state           = VGRuntimeStateIdle;
    _vg_textureId       = -1;
    _invalidated        = NO;
    _renderSize         = CGSizeZero;

    // Serial FIFO queue for source/renderer setup and post-prepare operations.
    _prepareQueue = dispatch_queue_create(
        "com.vanguard.graph_runtime.prepare",
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

// ─── prepareWithURL:completion: ───────────────────────────────────────────────

- (void)prepareWithURL:(NSURL *)url
            completion:(void (^)(int64_t textureId, NSError * _Nullable error))completion {

    NSParameterAssert(url        != nil);
    NSParameterAssert(completion != nil);

    // Dispatch all setup off the calling thread (contract: completion fires on
    // a background queue, never synchronously on the caller).
    dispatch_async(_prepareQueue, ^{

        // Guard against invalidate racing with prepare.
        if (self->_invalidated) {
            NSError *err = [NSError errorWithDomain:@"VanguardGraphRuntimeErrorDomain"
                                              code:1
                                          userInfo:@{NSLocalizedDescriptionKey: @"Runtime already invalidated."}];
            completion(-1, err);
            return;
        }

        // ── 1. Source the pixel buffer pool from VGResourceAllocator ──────────
        //
        //    We obtain a pool sized for a common video canvas (1080 × 1920 BGRA).
        //    In Phase 2 this will be driven by the actual source render size.
        //    The pool is held by the runtime for the session lifetime.
        VGResourceAllocator *allocator = [VGResourceAllocator sharedInstance];
        CVPixelBufferPoolRef pool = [allocator pixelBufferPoolWithWidth:1080
                                                                 height:1920
                                                                 format:kCVPixelFormatType_32BGRA];
        // pool carries a +1 retain (CF_RETURNS_RETAINED).
        self.sessionPool = pool;
        if (pool) {
            // Balance the +1 we are holding: the property stores its own
            // reference via normal ObjC memory management (see _teardownResources).
            // The CF_RETURNS_RETAINED means we must release the extra +1 here.
            CVPixelBufferPoolRelease(pool);
        }

        // ── 1.5 Resolve effective audio role through VGResourceAllocator ──────
        //
        // This must happen before source construction so the resolved role can be
        // passed into VanguardFileMediaSource via the 3-arg designated initialiser.
        // (Step-enforced blocker RR-06 is satisfied by the prepareQueue dispatch above.)
        VGAudioRole resolvedRole;
        if (self->_desiredAudioRole == VGAudioRoleActive) {
            BOOL granted = [[VGResourceAllocator sharedInstance] requestAudioActivation:self];
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
            sourceError = [NSError errorWithDomain:@"VanguardGraphRuntimeErrorDomain"
                                              code:2
                                          userInfo:@{NSLocalizedDescriptionKey:
                                              @"Failed to create media source for URL."}];
            completion(-1, sourceError);
            return;
        }

        // ── 3. Warm up the source via VGMediaNode.prepareWithCompletion: ──────

        // semaphore lets us stay on _prepareQueue without nesting queues.
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSError *prepError = nil;

        [self.source prepareWithCompletion:^(NSError * _Nullable error) {
            prepError = error;
            dispatch_semaphore_signal(sem);
        }];

        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

        if (prepError || self->_invalidated) {
            NSError *err = prepError ?: [NSError errorWithDomain:@"VanguardGraphRuntimeErrorDomain"
                                                            code:1
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Runtime invalidated during prepare."}];
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
            self->_renderSize = (sz.width > 0 && sz.height > 0)
                ? sz : CGSizeMake(1080.0, 1920.0);
        }

        // ── 4. Create VanguardMetalRenderer ───────────────────────────────────
        //
        //    The renderer takes ownership of the source but does NOT create its
        //    own pixel buffer pool (the pool was pre-wired into the source and is
        //    managed by VGResourceAllocator — this ends the pool-backfill hack).

        VanguardMetalRenderer *renderer =
            [[VanguardMetalRenderer alloc] initWithSource:self.source
                                          textureRegistry:self.textureRegistry
                                            methodChannel:self.methodChannel];

        if (!renderer || self->_invalidated) {
            NSError *err = [NSError errorWithDomain:@"VanguardGraphRuntimeErrorDomain"
                                              code:3
                                          userInfo:@{NSLocalizedDescriptionKey:
                                              @"Failed to create VanguardMetalRenderer."}];
            completion(-1, err);
            return;
        }

        self.renderer = renderer;

        // ── 5. Capture textureId and expose masterClock ───────────────────────

        int64_t tid = renderer.textureId;
        self.textureId = tid;

        // VanguardFileMediaSource conforms to VanguardAudioEngine which vends a
        // masterClock. We resolve it via the VGMasterClock protocol if possible.
        if ([self.source conformsToProtocol:@protocol(VGMasterClock)]) {
            self.masterClock = (id<VGMasterClock>)self.source;
        } else if ([self.source respondsToSelector:@selector(masterClock)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
            id maybeClock = [self.source performSelector:@selector(masterClock)];
#pragma clang diagnostic pop
            if ([maybeClock conformsToProtocol:@protocol(VGMasterClock)]) {
                self.masterClock = (id<VGMasterClock>)maybeClock;
            }
        }

        // ── 6. Transition state ───────────────────────────────────────────────

        self.state = VGRuntimeStatePrepared;
        completion(tid, nil);
    });
}

// ─── Playback control — main thread only ──────────────────────────────────────

- (void)play {
    NSAssert([NSThread isMainThread], @"VanguardGraphRuntime.play must be called on the main thread.");
    if (_invalidated || !_renderer) return;

    [_renderer play];
    self.state = VGRuntimeStateRunning;
}

- (void)pause {
    NSAssert([NSThread isMainThread], @"VanguardGraphRuntime.pause must be called on the main thread.");
    if (_invalidated || !_renderer) return;

    [_renderer pause];
    self.state = VGRuntimeStatePaused;
}

- (void)seekTo:(double)seconds {
    NSAssert([NSThread isMainThread], @"VanguardGraphRuntime.seekTo: must be called on the main thread.");
    if (_invalidated || !_renderer) return;

    [_renderer seek:seconds];
    // State remains as-is (running stays running; paused stays paused).
}

// ─── invalidate — thread-safe, idempotent ─────────────────────────────────────

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
    _source   = nil;

    // Dispose renderer synchronously (tears down GPU state and unregisters texture).
    [renderer dispose];

    // Invalidate source (cancels in-flight decode, drains queues).
    [source invalidate];

    // Release the session pixel buffer pool.
    [self _releaseSessionPool];

    self.state = VGRuntimeStateIdle;
}

// ─── transitionToRole:completion: (Phase 2, Step 3) ─────────────────────────

- (void)transitionToRole:(VGAudioRole)role
              completion:(nullable void (^)(BOOL success))completion {
    dispatch_async(_prepareQueue, ^{
        // Guard: no transitions after invalidation.
        if (self->_invalidated) {
            if (completion) completion(NO);
            return;
        }

        // Already at the requested role — nothing to do.
        if (self.effectiveAudioRole == role) {
            if (completion) completion(YES);
            return;
        }

        id<VanguardMediaSource, VGMediaNode> source = self.source;

        if (role == VGAudioRoleMuted) {
            // Demote: deactivate audio engine and release allocator slot.
            if ([source respondsToSelector:@selector(deactivateAudioIfNeeded)]) {
                [(id)source deactivateAudioIfNeeded];
            }
            self.effectiveAudioRole = VGAudioRoleMuted;
            if (completion) completion(YES);

        } else {
            // Promote: attempt to acquire slot, then activate source audio.
            BOOL granted = [[VGResourceAllocator sharedInstance] requestAudioActivation:self];
            if (!granted) {
                if (completion) completion(NO);
                return;
            }
            if ([source respondsToSelector:@selector(activateAudioIfNeeded)]) {
                [(id)source activateAudioIfNeeded];
            }
            self.effectiveAudioRole = VGAudioRoleActive;
            if (completion) completion(YES);
        }
    });
}

// ─── invalidateAsync: (Phase 2, Step 3) ───────────────────────────────────────

- (void)invalidateAsync:(dispatch_block_t)completion {
    // Capture source strongly BEFORE invalidate nils it out.
    id<VanguardMediaSource, VGMediaNode> capturedSource = _source;
    [self invalidate];
    if (capturedSource &&
        [capturedSource respondsToSelector:@selector(awaitDecoderDrainWithCompletion:)]) {
        // Drain pending video decode work through the source abstraction.
        // awaitDecoderDrainWithCompletion: dispatches onto the source's internal
        // video queue; completion fires when the queue drains.
        [(id)capturedSource awaitDecoderDrainWithCompletion:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion();
            });
        }];
    } else {
        // No drain needed (image source, or source not yet prepared).
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion();
        });
    }
}

// ─── Playback rate and seek-preview forwarding (Phase 2, Step 3) ──────────────
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

// ─── Private helpers ──────────────────────────────────────────────────────────

- (void)_releaseSessionPool {
    // sessionPool is a CVPixelBufferPoolRef (CF type). The property is declared
    // as `assign nullable` — we manage the lifetime manually.
    if (_sessionPool) {
        CVPixelBufferPoolRelease(_sessionPool);
        _sessionPool = NULL;
    }
}

// ─── dealloc ──────────────────────────────────────────────────────────────────

- (void)dealloc {
    // Safety net: if the caller forgot to call invalidate, clean up now.
    // We cannot guarantee ordering here, so we do a best-effort teardown
    // without transitioning state (state property may already be gone).
    if (!_invalidated) {
        [_renderer dispose];
        [_source invalidate];
        [self _releaseSessionPool];
    }
}

@end
