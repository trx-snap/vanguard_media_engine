// VGAudioPreviewAutomationCoordinator.h
// Vanguard Media Engine — Audio Slice J
//
// Coordinator that owns keyframe envelope evaluation and automation timer
// management for the preview runtime.
//
// Ownership:
//   VanguardAudioPreviewRuntime (strong)
//     → VGAudioPreviewAutomationCoordinator (strong)
//         → id<VGAudioPreviewAutomationTimer> (strong)
//
// The runtime must not manipulate the coordinator's timer directly.
// All methods are scheduler-queue confined.
//
// Package-internal only.  Do NOT add to public_header_files.

#pragma once

#import "VGAudioPreviewAutomationTimer.h"
#import "VGAudioPreviewVolumeKeyframe.h"
#import <Foundation/Foundation.h>

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

@interface VGAudioPreviewAutomationCoordinator : NSObject

/// Designated initializer.
///
/// @param timer     Production or mock automation timer.
/// @param gainSink  Block called with the interpolated gain value.
///                  The runtime creates this block with a __weak capture of
///                  itself so that the coordinator cannot form a retain cycle.
- (instancetype)
    initWithTimer:(id<VGAudioPreviewAutomationTimer>)timer
         gainSink:(void (^)(float volume))gainSink NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

// ─── Lifecycle API (all scheduler-queue confined) ─────────────────────────────

/// Called during descriptor activation for a keyframed descriptor.
/// Cancels any existing polling, normalizes the keyframes, caches the envelope,
/// and if a usable envelope exists evaluates and applies the initial gain.
/// Does NOT start the polling timer.
- (void)activateWithRawKeyframes:(nullable NSArray *)rawKeyframes
                   timelineStart:(NSTimeInterval)timelineStart
                    effectiveEnd:(NSTimeInterval)effectiveEnd
                      initialPTS:(NSTimeInterval)initialPTS;

/// Re-evaluates the active envelope at |pts| and applies gain immediately.
/// Preserves the current envelope.  Does NOT start the polling timer.
/// No-op if no active envelope.
- (void)reevaluateAtPTS:(NSTimeInterval)pts;

/// Starts the repeating polling timer using the runtime-created validated tick
/// block.  No-op if no active envelope.  Must be called after [player play].
- (void)startPollingWithTickBlock:(dispatch_block_t)tickBlock;

/// Evaluates the active envelope at |pts| and emits gain through the gainSink
/// if the value changed by more than 1e-6.
/// Called by the runtime-created tick block on each timer fire.
- (void)evaluateAtPTS:(NSTimeInterval)pts;

/// Cancels the polling timer.  Preserves the current envelope for
/// same-descriptor seek/resume.  Called from _cancelAndIncrementSerial:.
- (void)pause;

/// Cancels the polling timer and clears the envelope and last-volume state.
/// Used when entering a gap, activating a static descriptor, or during
/// prepare/reprepare (reusable — preserves the gain sink).
- (void)deactivate;

/// Terminal teardown: cancels the timer and replaces the gain sink with a
/// no-op, permanently breaking gain delivery.
/// Called only from final runtime invalidation cleanup.
- (void)invalidate;

/// Whether a usable normalized envelope is currently cached.
@property(nonatomic, readonly) BOOL hasActiveEnvelope;

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
