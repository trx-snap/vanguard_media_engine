// VanguardGraphRuntime+AudioPreview.m
// Vanguard Media Engine — Phase 10-C Slice D
//
// Category implementation: graph-audio lifecycle gate, latest-request-wins
// replacement, and audio cleanup join for VanguardGraphRuntime.
//
// All associated-object state is main-queue-confined.

#import "VanguardGraphRuntime+AudioPreview.h"

#if VG_USE_V2_GRAPH

#import "VanguardAudioPreviewRuntime.h"
#import "VGTimelineStateSnapshot.h"
#import <UMF/VGAudioSidecarPlan.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

// ─── Graph-audio lifecycle state ─────────────────────────────────────────────
//
// Main-queue-confined. All reads and writes must occur on the main queue.

typedef NS_ENUM(NSInteger, VGGraphAudioLifecycleState) {
    VGGraphAudioLifecycleActive      = 0, ///< Accepts new audio runtime installation.
    VGGraphAudioLifecycleShuttingDown = 1, ///< Graph teardown initiated; rejects installs.
    VGGraphAudioLifecycleShutDown    = 2, ///< Permanently closed; all waiters fired.
};

// ─── Associated-object keys ───────────────────────────────────────────────────
// Using static char variables as unique pointer-keys for objc_setAssociatedObject.

static char kAudioPreviewRuntimeKey;        ///< VanguardAudioPreviewRuntime *
static char kAudioPreviewEpochKey;          ///< NSNumber (uint64_t) — lifecycle epoch
static char kAudioPreviewLifecycleKey;      ///< NSNumber (VGGraphAudioLifecycleState)
static char kAudioPreviewGenerationKey;     ///< NSNumber (uint64_t) — replacement generation
static char kAudioPreviewShutdownWaitersKey; ///< NSMutableArray<dispatch_block_t> *

// ─── Private category (runtime internals) ────────────────────────────────────

@interface VanguardGraphRuntime (AudioPreviewPrivate)

// ─── Current audio preview runtime (main-queue-confined) ─────────────────────

- (nullable VanguardAudioPreviewRuntime *)audioPreviewRuntime;
- (void)_setAudioPreviewRuntime:(nullable VanguardAudioPreviewRuntime *)runtime;

// ─── Lifecycle epoch (monotonic counter for audio runtime construction) ───────

- (uint64_t)_audioPreviewEpoch;
- (void)_incrementAudioPreviewEpoch;

// ─── Lifecycle state (main-queue-confined) ────────────────────────────────────

- (VGGraphAudioLifecycleState)_graphAudioLifecycleState;
- (void)_setGraphAudioLifecycleState:(VGGraphAudioLifecycleState)state;

// ─── Replacement generation (main-queue-confined) ────────────────────────────

- (uint64_t)_audioReplacementGeneration;
- (uint64_t)_incrementAudioReplacementGeneration;

// ─── Shutdown waiters (main-queue-confined) ───────────────────────────────────

- (NSMutableArray<dispatch_block_t> *)_audioShutdownWaiters;

@end

@implementation VanguardGraphRuntime (AudioPreviewPrivate)

- (nullable VanguardAudioPreviewRuntime *)audioPreviewRuntime {
    return objc_getAssociatedObject(self, &kAudioPreviewRuntimeKey);
}

- (void)_setAudioPreviewRuntime:(nullable VanguardAudioPreviewRuntime *)runtime {
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
    return n ? (VGGraphAudioLifecycleState)n.integerValue : VGGraphAudioLifecycleActive;
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
    NSMutableArray *arr = objc_getAssociatedObject(self, &kAudioPreviewShutdownWaitersKey);
    if (!arr) {
        arr = [NSMutableArray new];
        objc_setAssociatedObject(self, &kAudioPreviewShutdownWaitersKey, arr,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return arr;
}

@end

// ─── Public category implementation ──────────────────────────────────────────

@implementation VanguardGraphRuntime (AudioPreview)

// ─── invalidateAudioPreviewWithCompletion: ────────────────────────────────────
//
// Private graph-audio lifecycle gate. Called from VanguardGraphRuntime.m:
//   1. By invalidateAsync: on main, BEFORE dispatching video/graph cleanup.
//   2. By invalidateAsync: again inside afterVideoCleanup, to join audio shutdown.
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
// Must be called on the main queue.
//
// This method is NOT declared in the public header. It is accessed from
// VanguardGraphRuntime.m via the AudioPreviewPrivate category declaration
// in that file's private interface.

- (void)invalidateAudioPreviewWithCompletion:(nullable dispatch_block_t)completion {
    NSAssert([NSThread isMainThread],
             @"invalidateAudioPreviewWithCompletion: must be called on the main queue.");

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

    if (!currentRuntime) {
        // No audio runtime — transition directly to ShutDown and drain waiters.
        [self _finishAudioShutdown];
        return;
    }

    // 5. Weak self for the identity guard inside the completion.
    __weak VanguardGraphRuntime *weakSelf = self;
    VanguardAudioPreviewRuntime *capturedRuntime = currentRuntime;

    [currentRuntime invalidateAsync:^{
        // Fires on main queue (VanguardAudioPreviewRuntime drains waiters on main).
        dispatch_async(dispatch_get_main_queue(), ^{
            VanguardGraphRuntime *ss = weakSelf;
            if (!ss) return;

            // Identity guard: only clear if the installed runtime is still
            // the one we invalidated (a replacement may have already installed).
            if ([ss audioPreviewRuntime] == capturedRuntime) {
                [ss _setAudioPreviewRuntime:nil];
            }

            [ss _finishAudioShutdown];
        });
    }];
}

/// Transitions lifecycle to ShutDown and drains all pending shutdown waiters on main.
/// Called from invalidateAudioPreviewWithCompletion: when audio cleanup completes.
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

// ─── setAudioSidecarPlan:timelineDuration:completion: ─────────────────────────
//
// Latest-request-wins audio runtime replacement with five-gate lifecycle safety.
//
// Five gates (all main-queue-confined):
//   1. Lifecycle must be Active at entry.
//   2. Lifecycle must still be Active after old runtime cleanup.
//   3. Replacement generation must still match (no newer request raced in).
//   4. Associated runtime identity must still match (no newer runtime installed).
//   5. Lifecycle and generation must still match before final installation.
//
// Every code path invokes completion exactly once.
// No runtime installs after graph shutdown begins.
// Stale completions never clear or install over a newer runtime.

- (void)setAudioSidecarPlan:(nullable VGAudioSidecarPlan *)plan
           timelineDuration:(NSTimeInterval)timelineDuration
                 completion:(dispatch_block_t)completion {
    NSAssert([NSThread isMainThread],
             @"setAudioSidecarPlan:timelineDuration:completion: must be called on the main queue.");
    NSParameterAssert(completion != nil);

    // ── Gate 1: lifecycle must be Active at entry ──────────────────────────────
    if ([self _graphAudioLifecycleState] != VGGraphAudioLifecycleActive) {
        NSLog(@"[VanguardGraphRuntime+AudioPreview][D] "
              @"setAudioSidecarPlan: rejected at gate 1 — graph not active");
        completion();
        return;
    }

    // ── Increment replacement generation for this request ─────────────────────
    uint64_t myGeneration = [self _incrementAudioReplacementGeneration];

    // ── Tear down existing runtime (fire-and-forget; new runtime built in completion) ──
    VanguardAudioPreviewRuntime *oldRuntime = [self audioPreviewRuntime];

    // Weak self for all async completions.
    __weak VanguardGraphRuntime *weakSelf = self;

    dispatch_block_t installNewRuntime = ^{
        // ── Gate 2: lifecycle must still be Active after old cleanup ─────────
        VanguardGraphRuntime *ss = weakSelf;
        if (!ss) { completion(); return; }

        if ([ss _graphAudioLifecycleState] != VGGraphAudioLifecycleActive) {
            NSLog(@"[VanguardGraphRuntime+AudioPreview][D] "
                  @"setAudioSidecarPlan: rejected at gate 2 — graph shutdown during old cleanup");
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
        // If a newer request already installed a runtime, the old runtime that
        // we cleaned up is no longer the current one. Guard: if the installed
        // runtime is NOT the oldRuntime (or oldRuntime was nil), proceed.
        // (For the nil-oldRuntime case this gate always passes.)
        if (oldRuntime && [ss audioPreviewRuntime] != nil &&
            [ss audioPreviewRuntime] != oldRuntime) {
            NSLog(@"[VanguardGraphRuntime+AudioPreview][D] "
                  @"setAudioSidecarPlan: stale at gate 4 — runtime identity replaced");
            completion();
            return;
        }

        // ── Gate 5: lifecycle and generation still match before installation ──
        if ([ss _graphAudioLifecycleState] != VGGraphAudioLifecycleActive ||
            [ss _audioReplacementGeneration] != myGeneration) {
            NSLog(@"[VanguardGraphRuntime+AudioPreview][D] "
                  @"setAudioSidecarPlan: stale at gate 5 — pre-install check failed");
            completion();
            return;
        }

        // ── Increment lifecycle epoch for the new runtime ────────────────────
        [ss _incrementAudioPreviewEpoch];
        uint64_t epoch = [ss _audioPreviewEpoch];

        // ── Snapshot provider (weak ref to graph runtime) ────────────────────
        __weak VanguardGraphRuntime *weakSS = ss;
        VGTimelineSnapshotProvider provider = ^VGTimelineStateSnapshot {
            VanguardGraphRuntime *rt = weakSS;
            if (!rt) {
                return (VGTimelineStateSnapshot){ .isValid = NO };
            }
            return [rt readTimelineStateSnapshot];
        };

        // ── Construct new runtime ────────────────────────────────────────────
        VanguardAudioPreviewRuntime *newRuntime =
            [[VanguardAudioPreviewRuntime alloc]
                initWithSnapshotProvider:provider
                          lifecycleEpoch:epoch];

        VGAudioPreviewPreparationResult result =
            [newRuntime prepareWithSidecarPlan:plan timelineDuration:timelineDuration];

        NSLog(@"[VanguardGraphRuntime+AudioPreview][D] prepare result=%ld epoch=%llu",
              (long)result, (unsigned long long)epoch);

        // ── Final guard: if a newer request raced in during prepare, stale this one ──
        if ([ss _graphAudioLifecycleState] != VGGraphAudioLifecycleActive ||
            [ss _audioReplacementGeneration] != myGeneration) {
            NSLog(@"[VanguardGraphRuntime+AudioPreview][D] "
                  @"setAudioSidecarPlan: raced out after prepare — invalidating stale runtime");
            [newRuntime invalidateAsync:^{
                NSLog(@"[VanguardGraphRuntime+AudioPreview][D] stale new runtime invalidated");
            }];
            completion();
            return;
        }

        // ── Install the new runtime ──────────────────────────────────────────
        [ss _setAudioPreviewRuntime:newRuntime];
        completion();
    };

    if (oldRuntime) {
        // Retain old runtime strongly through its own cleanup.
        VanguardAudioPreviewRuntime *retainedOld = oldRuntime;
        [self _setAudioPreviewRuntime:nil];
        [retainedOld invalidateAsync:^{
            dispatch_async(dispatch_get_main_queue(), installNewRuntime);
        }];
    } else {
        // No existing runtime — install immediately.
        dispatch_async(dispatch_get_main_queue(), installNewRuntime);
    }
}

// ─── recoverAudioPreviewAfterSessionTransitionWithCompletion: ─────────────────
//
// Thin forwarder: passes the Slice N recovery command through to the
// installed VanguardAudioPreviewRuntime.  Swift callers receive
// the clean Swift-renamed form:
//   recoverAudioPreviewAfterSessionTransition(completion:)
//
// Must be called on the main thread.

- (void)recoverAudioPreviewAfterSessionTransitionWithCompletion:
    (void (^)(NSError * _Nullable))completion {
    NSAssert([NSThread isMainThread],
             @"recoverAudioPreviewAfterSessionTransitionWithCompletion: "
             @"must be called on the main queue.");
    NSParameterAssert(completion != nil);

    VanguardAudioPreviewRuntime *runtime = [self audioPreviewRuntime];
    if (!runtime) {
        // No audio runtime (silent-mode project or not yet installed).
        NSLog(@"[VanguardGraphRuntime+AudioPreview][N] "
              @"recoverAudioPreview: no runtime installed — no-op");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    [runtime commandRecoverAfterSessionTransitionWithCompletion:completion];
}

@end


NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
