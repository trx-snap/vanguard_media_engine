// VanguardAudioPreviewRuntime.h
// Vanguard Media Engine — Phase 10-C Slice D
//
// One external-track timing proof.
// Package-internal only. Do NOT add to public_header_files.
// Do NOT import from VanguardGraphRuntime.h.
//
// Owns an AVAudioEngine and a single AVAudioPlayerNode. Receives coherent
// VGTimelineStateSnapshot values from VanguardGraphRuntime via the
// VGTimelineSnapshotProvider block; schedules, pauses, seeks and stops the
// player node in lock-step with the timeline clock.
//
// Thread-safety:
//   All mutable state is confined to the private serial queue
//   'com.vanguard.audioPreviewScheduler' (USER_INTERACTIVE QoS).
//   The only public methods that may be called from any thread are:
//     -prepareWithSidecarPlan:timelineDuration:
//     -commandPlay / -commandPause / -commandSeek / -commandEOS
//     -invalidateAsync:
//   All other methods are queue-confined and must not be called directly.

#pragma once

#import "VGTimelineStateSnapshot.h"
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <os/lock.h>
#import <stdatomic.h>

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// ─── Forward declarations
// ─────────────────────────────────────────────────────

@protocol VGAudioPreviewClock;
@protocol VGAudioPreviewTimer;
@protocol VGAudioPreviewAutomationTimer;
@protocol VGAudioPreviewFileProvider;
@protocol VGAudioPreviewEngine;
@protocol VGAudioPreviewPlayer;
@protocol VGAudioPreviewCommandQueue;
@class VanguardAudioPreviewRuntime;
@class VGAudioSidecarPlan;
@class VGAudioPreviewAutomationCoordinator;

// ─── VGAudioPreviewWorkToken
// ──────────────────────────────────────────────────
//
// Captures a moment in the runtime's lifecycle for stale-work rejection.
// Timers and player-node completion handlers capture the active token at the
// moment they are scheduled. On execution they compare the captured token
// against current queue-confined state; any mismatch or _acceptingCommands==NO
// causes the callback to discard its work silently.

typedef struct {
  uint64_t lifecycleEpoch; ///< Incremented per runtime construction.
  uint64_t commandSerial;  ///< Incremented on every command (play/pause/seek…).
  uint64_t timelineGeneration; ///< Copied from snapshot.generation.
} VGAudioPreviewWorkToken;

NS_INLINE BOOL VGAudioPreviewWorkTokenEqual(VGAudioPreviewWorkToken a,
                                            VGAudioPreviewWorkToken b) {
  return a.lifecycleEpoch == b.lifecycleEpoch &&
         a.commandSerial == b.commandSerial &&
         a.timelineGeneration == b.timelineGeneration;
}

// ─── VGAudioPreviewPreparationResult ─────────────────────────────────────────

typedef NS_ENUM(NSInteger, VGAudioPreviewPreparationResult) {
  VGAudioPreviewPreparationResultReady = 0,
  VGAudioPreviewPreparationResultSilentNoEligibleTrack = 1,
  VGAudioPreviewPreparationResultFailedMalformedTrack = 2,
  VGAudioPreviewPreparationResultFailedMissingFile = 3,
  VGAudioPreviewPreparationResultFailedUnsupportedFormat = 4,
  VGAudioPreviewPreparationResultFailedInvalidDuration = 5,
  VGAudioPreviewPreparationResultFailedEnginePreparation = 6,
};

// ─── VGAudioPreviewInvalidationState ─────────────────────────────────────────
//
// Three-state invalidation lifecycle.
// All transitions are protected by _invalidationLock (os_unfair_lock).

typedef NS_ENUM(NSInteger, VGAudioPreviewInvalidationState) {
  VGAudioPreviewInvalidationStateAccepting = 0,    ///< Normal operation.
  VGAudioPreviewInvalidationStateInvalidating = 1, ///< Cleanup in progress.
  VGAudioPreviewInvalidationStateInvalidated = 2,  ///< Permanently closed.
};

// ─── VGAudioPreviewRuntimeState
// ───────────────────────────────────────────────

typedef NS_ENUM(NSInteger, VGAudioPreviewRuntimeState) {
  VGAudioPreviewRuntimeStateUnprepared = 0,
  VGAudioPreviewRuntimeStateReadySilent = 1,          ///< No eligible track.
  VGAudioPreviewRuntimeStateWaitingForTrackStart = 2, ///< Timer armed.
  VGAudioPreviewRuntimeStatePlaying = 3,
  VGAudioPreviewRuntimeStatePaused = 4,
  VGAudioPreviewRuntimeStateEnded = 5,
  VGAudioPreviewRuntimeStateFailed = 6,
  VGAudioPreviewRuntimeStateInvalidated = 7,
};

// ─── Collaborator protocols for deterministic testing
// ─────────────────────────

/// Returns the current host-clock wall time (seconds). Maps to
/// CACurrentMediaTime().
@protocol VGAudioPreviewClock <NSObject>
- (NSTimeInterval)currentTime;
@end

/// Abstracts the one-shot dispatch_source_t boundary timer.
@protocol VGAudioPreviewTimer <NSObject>
/// Arms a one-shot timer firing after |delay| seconds (+/- leeway 10 ms).
/// Calls |block| on the owner's serial queue.
- (void)armWithDelay:(NSTimeInterval)delay block:(dispatch_block_t)block;
/// Cancels any armed timer. Idempotent.
- (void)cancel;
@end

/// Opens an AVAudioFile at a URL and checks file existence.
@protocol VGAudioPreviewFileProvider <NSObject>
- (nullable AVAudioFile *)openFileAtURL:(NSURL *)url
                                  error:(NSError *_Nullable *_Nullable)error;
/// Returns YES if the file at the given URL exists on disk.
- (BOOL)fileExistsAtURL:(NSURL *)url;
@end

/// Abstracts AVAudioEngine.
@protocol VGAudioPreviewEngine <NSObject>
- (void)attachNode:(AVAudioNode *)node;
- (void)connect:(AVAudioNode *)node1
             to:(AVAudioNode *)node2
         format:(nullable AVAudioFormat *)format;
- (void)prepare;
- (BOOL)startAndReturnError:(NSError *_Nullable *_Nullable)error;
- (void)stop;
- (AVAudioMixerNode *)mainMixerNode;
@end

/// Abstracts AVAudioPlayerNode.
@protocol VGAudioPreviewPlayer <NSObject>
- (void)scheduleSegment:(AVAudioFile *)file
             startingFrame:(AVAudioFramePosition)startFrame
                frameCount:(AVAudioFrameCount)frameCount
                    atTime:(nullable AVAudioTime *)when
    completionCallbackType:(AVAudioPlayerNodeCompletionCallbackType)callbackType
         completionHandler:
             (nullable AVAudioPlayerNodeCompletionHandler)completionHandler;
- (void)play;
- (void)stop;
- (void)setVolume:(float)volume;
@end

/// Provides a queue-identity key for VGAudioAssertQueue().
@protocol VGAudioPreviewCommandQueue <NSObject>
- (dispatch_queue_t)queue;
@end

/// Provides the latest timeline-state snapshot (non-owning, safe from
/// scheduling queue).
typedef VGTimelineStateSnapshot (^VGTimelineSnapshotProvider)(void);

// ─── VanguardAudioPreviewRuntime
// ──────────────────────────────────────────────

@interface VanguardAudioPreviewRuntime : NSObject

/// Designated production initialiser.
///
/// @param snapshotProvider  Block returning the latest VGTimelineStateSnapshot.
///                          Called on the scheduling queue. Must not capture
///                          strong references that outlive the runtime.
/// @param lifecycleEpoch    Monotonically increasing epoch shared across
///                          replacement runtimes. Callers should increment
///                          before constructing a new runtime.
- (instancetype)initWithSnapshotProvider:
                    (VGTimelineSnapshotProvider)snapshotProvider
                          lifecycleEpoch:(uint64_t)lifecycleEpoch
    NS_DESIGNATED_INITIALIZER;

/// Package-internal test initialiser. Injects all collaborators.
/// Pass nil for |timer| to use the production dispatch_source_t boundary timer.
/// Pass nil for |automationTimer| to use the production automation timer.
- (instancetype)
    initWithSnapshotProvider:(VGTimelineSnapshotProvider)snapshotProvider
              lifecycleEpoch:(uint64_t)lifecycleEpoch
                       clock:(id<VGAudioPreviewClock>)clock
                       timer:(nullable id<VGAudioPreviewTimer>)timer
             automationTimer:(nullable id<VGAudioPreviewAutomationTimer>)automationTimer
                fileProvider:(id<VGAudioPreviewFileProvider>)fileProvider
                      engine:(id<VGAudioPreviewEngine>)engine
                      player:(id<VGAudioPreviewPlayer>)player;

- (instancetype)init NS_UNAVAILABLE;

// ─── Preparation ─────────────────────────────────────────────────────────────

/// Prepares the runtime for one external music track.
///
/// Selects the first valid @"music" track in plan.tracks, validates and
/// normalises it into VGAudioPreviewTrackDescriptor, opens the file, and
/// configures AVAudioEngine. Falls through to ReadySilent on any non-fatal
/// condition (missing file, wrong format, no music track). Video preview always
/// continues regardless of the result.
///
/// Must be called before any command methods. Not thread-confined — may be
/// called from the Swift plugin on any queue (dispatches internally).
///
/// @param plan             The normalized sidecar plan. May be nil
/// (ReadySilent).
/// @param timelineDuration Authoritative project duration in seconds
///                         (from VGEditorDraft.durationSeconds). Used to clip
///                         the track's active interval.
- (VGAudioPreviewPreparationResult)
    prepareWithSidecarPlan:(nullable VGAudioSidecarPlan *)plan
          timelineDuration:(NSTimeInterval)timelineDuration;

// ─── Timeline event commands
// ──────────────────────────────────────────────────
//
// All commands are dispatched internally to the scheduling queue.
// May be called from the main thread after _timelinePlay/_timelinePause/
// seekTimelineTo:/EOS/invalidation hooks in VanguardGraphRuntime.m.

/// Called when the timeline transitions to playing.
- (void)commandPlay;

/// Called when the timeline transitions to paused.
- (void)commandPause;

/// Called when the timeline is seeked (before or after publishing the new
/// snapshot).
- (void)commandSeek;

/// Called when the timeline reaches end-of-stream.
- (void)commandEOS;

// ─── Invalidation
// ─────────────────────────────────────────────────────────────

/// Atomically closes command acceptance, dispatches queue cleanup, then calls
/// |completion| on the main queue after cleanup completes.
///
/// Three-state invalidation (Accepting → Invalidating → Invalidated):
///   - First caller: transitions to Invalidating, initiates cleanup, appends
///     completion to waiter list.
///   - Additional callers during Invalidating: append completion to waiter
///   list.
///   - Callers after Invalidated: completion fires immediately on main.
///
/// The runtime is strongly retained through cleanup until all waiters fire.
/// May be called from any thread. completion must not be nil.
- (void)invalidateAsync:(dispatch_block_t)completion;

// ─── Queue assertion
// ──────────────────────────────────────────────────────────

/// Asserts (debug builds only) that the caller is on the scheduling queue.
- (void)assertOnSchedulerQueue;

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
