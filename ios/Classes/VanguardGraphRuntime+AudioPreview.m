// VanguardGraphRuntime+AudioPreview.m
// Vanguard Media Engine — Phase 10-C Slice D / S-P2 MOV audio repair
//
// Category implementation: graph-audio lifecycle gate, latest-request-wins
// replacement, and audio cleanup join for VanguardGraphRuntime.
//
// All associated-object state is main-queue-confined.

#import "VanguardGraphRuntime+AudioPreview.h"

#if VG_USE_V2_GRAPH

#import "VGAudioPreviewFileResolver.h"
#import "VGTimelineStateSnapshot.h"
#import "VanguardAudioPreviewRuntime.h"
#import <UMF/VGAudioSidecarPlan.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

// ─── Graph-audio lifecycle state ─────────────────────────────────────────────
//
// Main-queue-confined. All reads and writes must occur on the main queue.

typedef NS_ENUM(NSInteger, VGGraphAudioLifecycleState) {
  VGGraphAudioLifecycleActive = 0, ///< Accepts new audio runtime installation.
  VGGraphAudioLifecycleShuttingDown =
      1, ///< Graph teardown initiated; rejects installs.
  VGGraphAudioLifecycleShutDown = 2, ///< Permanently closed; all waiters fired.
};

// ─── Associated-object keys
// ─────────────────────────────────────────────────── Using static char
// variables as unique pointer-keys for objc_setAssociatedObject.

static char kAudioPreviewRuntimeKey; ///< VanguardAudioPreviewRuntime *
static char kAudioPreviewEpochKey;   ///< NSNumber (uint64_t) — lifecycle epoch
static char
    kAudioPreviewLifecycleKey; ///< NSNumber (VGGraphAudioLifecycleState)
static char kAudioPreviewGenerationKey; ///< NSNumber (uint64_t) — replacement
                                        ///< generation
static char
    kAudioPreviewShutdownWaitersKey; ///< NSMutableArray<dispatch_block_t> *
static char kAudioPreviewFileResolverKey; ///< VGAudioPreviewFileResolver * —
                                          ///< current resolver

// ─── Private category (runtime internals) ────────────────────────────────────

@interface VanguardGraphRuntime (AudioPreviewPrivate)

// ─── Current audio preview runtime (main-queue-confined) ─────────────────────

- (nullable VanguardAudioPreviewRuntime *)audioPreviewRuntime;
- (void)_setAudioPreviewRuntime:(nullable VanguardAudioPreviewRuntime *)runtime;

// ─── Lifecycle epoch (monotonic counter for audio runtime construction)
// ───────

- (uint64_t)_audioPreviewEpoch;
- (void)_incrementAudioPreviewEpoch;

// ─── Lifecycle state (main-queue-confined)
// ────────────────────────────────────

- (VGGraphAudioLifecycleState)_graphAudioLifecycleState;
- (void)_setGraphAudioLifecycleState:(VGGraphAudioLifecycleState)state;

// ─── Replacement generation (main-queue-confined) ────────────────────────────

- (uint64_t)_audioReplacementGeneration;
- (uint64_t)_incrementAudioReplacementGeneration;

// ─── Shutdown waiters (main-queue-confined)
// ───────────────────────────────────

- (NSMutableArray<dispatch_block_t> *)_audioShutdownWaiters;

// ─── Current file resolver (main-queue-confined) ─────────────────────────────

- (nullable VGAudioPreviewFileResolver *)_audioFileResolver;
- (void)_setAudioFileResolver:(nullable VGAudioPreviewFileResolver *)resolver;

@end

@implementation VanguardGraphRuntime (AudioPreviewPrivate)

- (nullable VanguardAudioPreviewRuntime *)audioPreviewRuntime {
  return objc_getAssociatedObject(self, &kAudioPreviewRuntimeKey);
}

- (void)_setAudioPreviewRuntime:
    (nullable VanguardAudioPreviewRuntime *)runtime {
  objc_setAssociatedObject(self, &kAudioPreviewRuntimeKey, runtime,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (uint64_t)_audioPreviewEpoch {
  NSNumber *n = objc_getAssociatedObject(self, &kAudioPreviewEpochKey);
  return n ? n.unsignedLongLongValue : 0;
}

- (void)_incrementAudioPreviewEpoch {
  uint64_t next = [self _audioPreviewEpoch] + 1;
  objc_setAssociatedObject(self, &kAudioPreviewEpochKey, @(next),
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (VGGraphAudioLifecycleState)_graphAudioLifecycleState {
  NSNumber *n = objc_getAssociatedObject(self, &kAudioPreviewLifecycleKey);
  return n ? (VGGraphAudioLifecycleState)n.integerValue
           : VGGraphAudioLifecycleActive;
}

- (void)_setGraphAudioLifecycleState:(VGGraphAudioLifecycleState)state {
  objc_setAssociatedObject(self, &kAudioPreviewLifecycleKey, @(state),
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (uint64_t)_audioReplacementGeneration {
  NSNumber *n = objc_getAssociatedObject(self, &kAudioPreviewGenerationKey);
  return n ? n.unsignedLongLongValue : 0;
}

- (uint64_t)_incrementAudioReplacementGeneration {
  uint64_t next = [self _audioReplacementGeneration] + 1;
  objc_setAssociatedObject(self, &kAudioPreviewGenerationKey, @(next),
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return next;
}

- (NSMutableArray<dispatch_block_t> *)_audioShutdownWaiters {
  NSMutableArray *arr =
      objc_getAssociatedObject(self, &kAudioPreviewShutdownWaitersKey);
  if (!arr) {
    arr = [NSMutableArray new];
    objc_setAssociatedObject(self, &kAudioPreviewShutdownWaitersKey, arr,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return arr;
}

- (nullable VGAudioPreviewFileResolver *)_audioFileResolver {
  return objc_getAssociatedObject(self, &kAudioPreviewFileResolverKey);
}

- (void)_setAudioFileResolver:(nullable VGAudioPreviewFileResolver *)resolver {
  objc_setAssociatedObject(self, &kAudioPreviewFileResolverKey, resolver,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

// ─── Public category implementation ──────────────────────────────────────────

@implementation VanguardGraphRuntime (AudioPreview)

// ─── invalidateAudioPreviewWithCompletion:
// ────────────────────────────────────
//
// Private graph-audio lifecycle gate. Called from VanguardGraphRuntime.m:
//   1. By invalidateAsync: on main, BEFORE dispatching video/graph cleanup.
//   2. By invalidateAsync: again inside afterVideoCleanup, to join audio
//   shutdown.
//
// LIFECYCLE:
//   Active → ShuttingDown:
//     Increment replacement generation, invalidate current runtime.
//     Any join caller appends to shutdown waiters.
//   ShuttingDown (join call):
//     Append waiter. Waiter fires when audio cleanup completes.
//   ShutDown:
//     Fire completion immediately (permanent closed state).
//
// S-P2: On graph shutdown, if a resolver is in flight and no runtime is
//   installed, the resolver is cancelled and joined before
//   _finishAudioShutdown. If a runtime exists, the runtime is invalidated
//   first; then the resolver (if any) is cancelled and joined; then
//   _finishAudioShutdown fires.
//
// Must be called on the main queue.
//
// This method is NOT declared in the public header. It is accessed from
// VanguardGraphRuntime.m via the AudioPreviewPrivate category declaration
// in that file's private interface.

- (void)invalidateAudioPreviewWithCompletion:
    (nullable dispatch_block_t)completion {
  NSAssert([NSThread isMainThread], @"invalidateAudioPreviewWithCompletion: "
                                    @"must be called on the main queue.");

  VGGraphAudioLifecycleState state = [self _graphAudioLifecycleState];

  if (state == VGGraphAudioLifecycleShutDown) {
    // Already shut down — fire immediately.
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion();
      });
    }
    return;
  }

  if (state == VGGraphAudioLifecycleShuttingDown) {
    // Cleanup in progress — join the waiter list.
    if (completion) {
      [[self _audioShutdownWaiters] addObject:[completion copy]];
    }
    return;
  }

  // state == VGGraphAudioLifecycleActive — we initiate shutdown.
  // 1. Increment replacement generation to stale any in-flight replacement.
  [self _incrementAudioReplacementGeneration];

  // 2. Transition lifecycle: Active → ShuttingDown.
  [self _setGraphAudioLifecycleState:VGGraphAudioLifecycleShuttingDown];

  // 3. Append our own completion waiter (may be nil for fire-and-forget).
  if (completion) {
    [[self _audioShutdownWaiters] addObject:[completion copy]];
  }

  // 4. Capture and retain the current runtime strongly through audio cleanup.
  VanguardAudioPreviewRuntime *currentRuntime = [self audioPreviewRuntime];

  // S-P2: Capture any in-flight resolver so we can cancel and join it.
  // Clear the association so new requests (which are stale anyway after
  // lifecycle transition) cannot reference it.
  VGAudioPreviewFileResolver *currentResolver = [self _audioFileResolver];
  if (currentResolver) {
    [self _setAudioFileResolver:nil];
  }

  // Helper: cancel-and-join resolver then finish shutdown.
  // Always called on the main queue after runtime invalidation (or
  // immediately when no runtime is installed).
  //
  // weakSelf is used by the runtime-invalidation identity guard (below) which
  // races with replacement installs and must tolerate a nil graph owner.
  //
  // The resolver callback is the *terminal* shutdown path: the resolver was
  // already detached from the graph before cancelAndCleanupWithCompletion: is
  // called, so no retain cycle is introduced by capturing self strongly here.
  // If weakSelf were used here and the graph owner had been deallocated,
  // _finishAudioShutdown would never fire and all shutdown waiters would be
  // permanently stranded — including the graph-completion block that delivers
  // result(nil) back to Dart.
  __weak VanguardGraphRuntime *weakSelf = self;
  __strong VanguardGraphRuntime *strongSelf = self;

  dispatch_block_t finishAfterResolverCleanup = ^{
    if (currentResolver) {
      [currentResolver cancelAndCleanupWithCompletion:^{
        // Fires on main queue after ExtAudioFile dispose and temp removal.
        // Use strongSelf here (not weakSelf) — _finishAudioShutdown MUST be
        // reached to drain shutdown waiters. The resolver is already detached
        // so there is no retain cycle.
        [strongSelf _finishAudioShutdown];
      }];
    } else {
      [strongSelf _finishAudioShutdown];
    }
  };

  if (!currentRuntime) {
    // No audio runtime — handle resolver then transition to ShutDown.
    finishAfterResolverCleanup();
    return;
  }

  VanguardAudioPreviewRuntime *capturedRuntime = currentRuntime;

  [currentRuntime invalidateAsync:^{
    // Fires on main queue (VanguardAudioPreviewRuntime drains waiters on main).
    dispatch_async(dispatch_get_main_queue(), ^{
      VanguardGraphRuntime *ss = weakSelf;
      if (!ss) {
        return;
      }

      // Identity guard: only clear if the installed runtime is still
      // the one we invalidated (a replacement may have already installed).
      if ([ss audioPreviewRuntime] == capturedRuntime) {
        [ss _setAudioPreviewRuntime:nil];
      }

      finishAfterResolverCleanup();
    });
  }];
}

/// Transitions lifecycle to ShutDown and drains all pending shutdown waiters on
/// main. Called from invalidateAudioPreviewWithCompletion: when audio cleanup
/// completes.
- (void)_finishAudioShutdown {
  NSAssert([NSThread isMainThread],
           @"_finishAudioShutdown must be called on the main queue.");

  [self _setGraphAudioLifecycleState:VGGraphAudioLifecycleShutDown];

  NSArray<dispatch_block_t> *waiters = [[self _audioShutdownWaiters] copy];
  [[self _audioShutdownWaiters] removeAllObjects];

  for (dispatch_block_t w in waiters) {
    w();
  }
}

// ─── setAudioSidecarPlan:timelineDuration:completion:
// ─────────────────────────
//
// Latest-request-wins audio runtime replacement with five-gate lifecycle safety
// and one-shot file resolution for audiovisual sidecar URLs (S-P2).
//
// Five gates (all main-queue-confined):
//   1. Lifecycle must be Active at entry.
//   2. Lifecycle must still be Active after old runtime cleanup.
//   3. Replacement generation must still match (no newer request raced in).
//   4. Associated runtime identity must still match (no newer runtime
//   installed).
//   5. Lifecycle and generation must still match before final installation.
//
// S-P2 addition:
//   After old runtime teardown and before runtime construction, a one-shot
//   VGAudioPreviewFileResolver resolves any audiovisual-container URLs in
//   the sidecar plan to temporary CAF files. After resolution completes on
//   the main queue, gates 2–5 are rechecked and a resolver-identity gate
//   is applied before constructing VanguardAudioPreviewRuntime.
//
// Every code path invokes completion exactly once.
// No runtime installs after graph shutdown begins.
// Stale completions never clear or install over a newer runtime/resolver.

- (void)setAudioSidecarPlan:(nullable VGAudioSidecarPlan *)plan
           timelineDuration:(NSTimeInterval)timelineDuration
                 completion:(dispatch_block_t)completion {
  NSAssert([NSThread isMainThread],
           @"setAudioSidecarPlan:timelineDuration:completion: must be called "
           @"on the main queue.");
  NSParameterAssert(completion != nil);

  // Phase 10F Slice 1: timing instrumentation (captured by value in blocks).
  CFAbsoluteTime requestStart = CFAbsoluteTimeGetCurrent();

  // ── Gate 1: lifecycle must be Active at entry ──────────────────────────────
  if ([self _graphAudioLifecycleState] != VGGraphAudioLifecycleActive) {
    NSLog(@"[VanguardGraphRuntime+AudioPreview][D] "
          @"setAudioSidecarPlan: rejected at gate 1 — graph not active");
    completion();
    return;
  }

  // ── Increment replacement generation for this request ─────────────────────
  uint64_t myGeneration = [self _incrementAudioReplacementGeneration];

  // ── Tear down existing runtime (fire-and-forget; new runtime built after
  // resolve) ──
  VanguardAudioPreviewRuntime *oldRuntime = [self audioPreviewRuntime];

  // ── Capture the previous resolver (if any) ────────────────────────────────
  //
  // Cancellation and cleanup are sequenced after old-runtime invalidation
  // in the branches below: runtime → resolver → beginResolution.
  // No fire-and-forget cleanup here.
  VGAudioPreviewFileResolver *oldResolver = [self _audioFileResolver];

  // Weak self for all async completions.
  __weak VanguardGraphRuntime *weakSelf = self;

  // ── Block: begin resolution then install new runtime ─────────────────────
  //
  // Runs on main queue after old runtime teardown.
  dispatch_block_t beginResolution = ^{
    VanguardGraphRuntime *ss = weakSelf;
    if (!ss) {
      completion();
      return;
    }

    // ── Gate 2: lifecycle must still be Active after old cleanup ─────────
    if ([ss _graphAudioLifecycleState] != VGGraphAudioLifecycleActive) {
      NSLog(@"[VanguardGraphRuntime+AudioPreview][D] "
            @"setAudioSidecarPlan: rejected at gate 2 — graph shutdown during "
            @"old cleanup");
      completion();
      return;
    }

    // ── Gate 3: replacement generation must still match ──────────────────
    if ([ss _audioReplacementGeneration] != myGeneration) {
      NSLog(@"[VanguardGraphRuntime+AudioPreview][D] "
            @"setAudioSidecarPlan: stale at gate 3 — generation mismatch");
      completion();
      return;
    }

    // ── Gate 4: associated runtime identity must still match ─────────────
    if (oldRuntime && [ss audioPreviewRuntime] != nil &&
        [ss audioPreviewRuntime] != oldRuntime) {
      NSLog(
          @"[VanguardGraphRuntime+AudioPreview][D] "
          @"setAudioSidecarPlan: stale at gate 4 — runtime identity replaced");
      completion();
      return;
    }

    // ── Gate 5: lifecycle and generation still match before resolution ────
    if ([ss _graphAudioLifecycleState] != VGGraphAudioLifecycleActive ||
        [ss _audioReplacementGeneration] != myGeneration) {
      NSLog(@"[VanguardGraphRuntime+AudioPreview][D] "
            @"setAudioSidecarPlan: stale at gate 5 — pre-resolve check failed");
      completion();
      return;
    }

    // ── Create and register a new one-shot resolver ──────────────────────
    VGAudioPreviewFileResolver *myResolver =
        [[VGAudioPreviewFileResolver alloc] init];
    [ss _setAudioFileResolver:myResolver];

    // Phase 10F Slice 1: teardown of the previous runtime/resolver is the
    // time between request entry and this point.
    CFAbsoluteTime resolveStart = CFAbsoluteTimeGetCurrent();
    NSUInteger tracksIn = plan.tracks.count;
    NSLog(@"[VanguardGraphRuntime+AudioPreview][TIMING] beginResolution "
          @"teardownMs=%d tracksIn=%lu generation=%llu",
          (int)((resolveStart - requestStart) * 1000.0),
          (unsigned long)tracksIn, (unsigned long long)myGeneration);

    // ── Start resolution ─────────────────────────────────────────────────
    [myResolver
        resolvePlan:plan
         completion:^(VGAudioSidecarPlan *_Nullable resolvedPlan) {
           // Fires on main queue.
           int resolveMs =
               (int)((CFAbsoluteTimeGetCurrent() - resolveStart) * 1000.0);
           NSLog(@"[VanguardGraphRuntime+AudioPreview][TIMING] resolvePlan "
                 @"elapsedMs=%d tracksIn=%lu tracksOut=%lu generation=%llu",
                 resolveMs, (unsigned long)tracksIn,
                 (unsigned long)resolvedPlan.tracks.count,
                 (unsigned long long)myGeneration);

           VanguardGraphRuntime *ss2 = weakSelf;
           if (!ss2) {
             completion();
             return;
           }

           // ── Post-resolve gate A: lifecycle ───────────────────────────────
           if ([ss2 _graphAudioLifecycleState] != VGGraphAudioLifecycleActive) {
             NSLog(
                 @"[VanguardGraphRuntime+AudioPreview][D] "
                 @"setAudioSidecarPlan: stale after resolve — graph shutdown");
             completion();
             return;
           }

           // ── Post-resolve gate B: generation ─────────────────────────────
           if ([ss2 _audioReplacementGeneration] != myGeneration) {
             NSLog(@"[VanguardGraphRuntime+AudioPreview][D] "
                   @"setAudioSidecarPlan: stale after resolve — generation "
                   @"mismatch");
             completion();
             return;
           }

           // ── Post-resolve gate C: resolver identity ───────────────────────
           //
           // A newer request would have replaced the associated resolver.
           // If ours is no longer installed, our result is stale.
           if ([ss2 _audioFileResolver] != myResolver) {
             NSLog(@"[VanguardGraphRuntime+AudioPreview][D] "
                   @"setAudioSidecarPlan: stale after resolve — resolver "
                   @"identity replaced");
             completion();
             return;
           }

           // ── Increment lifecycle epoch for the new runtime ────────────────
           [ss2 _incrementAudioPreviewEpoch];
           uint64_t epoch = [ss2 _audioPreviewEpoch];

           // ── Snapshot provider (weak ref to graph runtime) ────────────────
           __weak VanguardGraphRuntime *weakSS2 = ss2;
           VGTimelineSnapshotProvider provider = ^VGTimelineStateSnapshot {
             VanguardGraphRuntime *rt = weakSS2;
             if (!rt) {
               return (VGTimelineStateSnapshot){.isValid = NO};
             }
             return [rt readTimelineStateSnapshot];
           };

           // ── Construct new runtime ────────────────────────────────────────
           VanguardAudioPreviewRuntime *newRuntime =
               [[VanguardAudioPreviewRuntime alloc]
                   initWithSnapshotProvider:provider
                             lifecycleEpoch:epoch];

           // Use resolved plan (with CAF URLs) if resolution succeeded.
           // A nil resolved plan means all tracks were dropped or extraction
           // was cancelled — prepare silent mode; never retry the original
           // MOV URL which is known to fail AVAudioFile initForReading:.
           VGAudioSidecarPlan *planForPreparation = resolvedPlan;

           CFAbsoluteTime prepareStart = CFAbsoluteTimeGetCurrent();
           VGAudioPreviewPreparationResult result =
               [newRuntime prepareWithSidecarPlan:planForPreparation
                                 timelineDuration:timelineDuration];
           CFAbsoluteTime prepareEnd = CFAbsoluteTimeGetCurrent();

           // Phase 10F Slice 1: prepareMs covers prepareWithSidecarPlan only;
           // totalMs covers the whole setAudioSidecarPlan request so far
           // (old teardown + resolve + prepare).
           NSLog(@"[VanguardGraphRuntime+AudioPreview][D] prepare result=%ld "
                 @"epoch=%llu prepareMs=%d resolveMs=%d totalMs=%d",
                 (long)result, (unsigned long long)epoch,
                 (int)((prepareEnd - prepareStart) * 1000.0), resolveMs,
                 (int)((prepareEnd - requestStart) * 1000.0));

           // ── Final guard: if a newer request raced in during prepare ──────
           if ([ss2 _graphAudioLifecycleState] != VGGraphAudioLifecycleActive ||
               [ss2 _audioReplacementGeneration] != myGeneration) {
             NSLog(@"[VanguardGraphRuntime+AudioPreview][D] "
                   @"setAudioSidecarPlan: raced out after prepare — "
                   @"invalidating stale runtime");
             [newRuntime invalidateAsync:^{
               NSLog(@"[VanguardGraphRuntime+AudioPreview][D] stale new "
                     @"runtime invalidated");
             }];
             completion();
             return;
           }

           // ── Install the new runtime ──────────────────────────────────────
           [ss2 _setAudioPreviewRuntime:newRuntime];
           completion();
         }];
  };

  if (oldRuntime) {
    // Retain old runtime strongly through its own cleanup.
    // Sequencing: await runtime invalidation → await resolver cleanup →
    // beginResolution.
    VanguardAudioPreviewRuntime *retainedOld = oldRuntime;
    [self _setAudioPreviewRuntime:nil];
    [retainedOld invalidateAsync:^{
      // Runtime is now fully invalidated. If there is a prior resolver,
      // join it before starting the new request so that its temp files
      // are not deleted while AVAudioFile holds them open.
      dispatch_async(dispatch_get_main_queue(), ^{
        if (oldResolver) {
          [oldResolver cancelAndCleanupWithCompletion:^{
            dispatch_async(dispatch_get_main_queue(), beginResolution);
          }];
        } else {
          beginResolution();
        }
      });
    }];
  } else if (oldResolver) {
    // No runtime, but a prior resolver is in flight (e.g. a rapid
    // second call before the first resolve finished). Join its cleanup
    // before beginning the new resolution.
    [self _setAudioFileResolver:nil];
    [oldResolver cancelAndCleanupWithCompletion:^{
      dispatch_async(dispatch_get_main_queue(), beginResolution);
    }];
  } else {
    // No existing runtime or resolver — begin resolution immediately.
    dispatch_async(dispatch_get_main_queue(), beginResolution);
  }
}

// ─── recoverAudioPreviewAfterSessionTransitionWithCompletion:
// ─────────────────
//
// Thin forwarder: passes the Slice N recovery command through to the
// installed VanguardAudioPreviewRuntime.  Swift callers receive
// the clean Swift-renamed form:
//   recoverAudioPreviewAfterSessionTransition(completion:)
//
// Must be called on the main thread.

- (void)recoverAudioPreviewAfterSessionTransitionWithCompletion:
    (void (^)(NSError *_Nullable))completion {
  NSAssert([NSThread isMainThread],
           @"recoverAudioPreviewAfterSessionTransitionWithCompletion: "
           @"must be called on the main queue.");
  NSParameterAssert(completion != nil);

  VanguardAudioPreviewRuntime *runtime = [self audioPreviewRuntime];
  if (!runtime) {
    // No audio runtime (silent-mode project or not yet installed).
    NSLog(@"[VanguardGraphRuntime+AudioPreview][N] "
          @"recoverAudioPreview: no runtime installed — no-op");
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(nil);
    });
    return;
  }

  [runtime commandRecoverAfterSessionTransitionWithCompletion:completion];
}

// ─── setMixGainForTrackId:gain: ──────────────────────────────────────────────
//
// V-B1/V-B2: Thin forwarder from the Swift plugin to the installed
// VanguardAudioPreviewRuntime. Dispatches asynchronously to the audio
// scheduler queue inside the runtime — no main-thread blocking.

- (void)setMixGainForTrackId:(NSString *)trackId gain:(float)gain {
  NSParameterAssert(trackId.length > 0);

  VanguardAudioPreviewRuntime *runtime = [self audioPreviewRuntime];
  if (!runtime) {
    // No audio runtime (silent-mode project or not yet installed) — no-op.
    return;
  }

  [runtime setMixGainForTrackId:trackId gain:gain];
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
