// VanguardGraphRuntime+AudioPreview.h
// Vanguard Media Engine — Phase 10-C Slice D
//
// Package-internal category on VanguardGraphRuntime.
// Bridges the VGAudioSidecarPlan received through the 'updateTimeline'
// MethodChannel route into the native VanguardAudioPreviewRuntime.
//
// VISIBILITY: Module-visible (not in private_header_files) so Swift can
// call setAudioSidecarPlan:timelineDuration:completion:.
// Do NOT import from VanguardGraphRuntime.h.
// Runtime internals remain private to the category .m file.

#pragma once

#import "VanguardGraphRuntime.h"

#if VG_USE_V2_GRAPH

// Forward-declare VGAudioSidecarPlan — full definition comes from UMF
// module (available to Swift and ObjC callers through import UMF).
@class VGAudioSidecarPlan;

NS_ASSUME_NONNULL_BEGIN

// ─── Phase 10F Slice 3: audio arming outcome ─────────────────────────────────
//
// Reported exactly once per setAudioSidecarPlan: request through the
// completion callback. The Swift plugin is the single choke point that
// translates this outcome into the `onTimelineAudioStateChanged` MethodChannel
// event; the ObjC category never talks to Flutter directly.
//
//   Ready      — a new VanguardAudioPreviewRuntime was installed with at least
//                one audible track and is now driven by the timeline snapshot.
//   Silent     — a new runtime was installed in ReadySilent mode (nil plan, or
//                no eligible/audible track). Terminal; nothing further arrives.
//   Failed     — a new runtime was installed but preparation failed
//                (malformed track, missing file, unsupported format, invalid
//                duration, engine preparation). Video preview continues.
//   Superseded — this request was rejected at a lifecycle gate, went stale
//                because a newer request raced in, or the graph shut down.
//                Callers must NOT surface this to Dart: a newer request (or a
//                teardown) owns the observable state.
typedef NS_ENUM(NSInteger, VGGraphAudioArmOutcome) {
  VGGraphAudioArmOutcomeReady = 0,
  VGGraphAudioArmOutcomeSilent = 1,
  VGGraphAudioArmOutcomeFailed = 2,
  VGGraphAudioArmOutcomeSuperseded = 3,
};

/// Completion callback for setAudioSidecarPlan:timelineDuration:completion:.
/// Invoked exactly once on the main queue.
typedef void (^VGGraphAudioArmCompletion)(VGGraphAudioArmOutcome outcome);

@interface VanguardGraphRuntime (AudioPreview)

/// Arms the audio preview runtime after the video compositor is ready.
///
/// Tears down any existing audio runtime, constructs a new one, prepares it
/// from the supplied sidecar plan, installs it, issues an unconditional
/// commandPlay (the runtime's own scheduler consults the live timeline
/// snapshot and no-ops unless the timeline is currently playing), and calls
/// |completion| on the main queue with the arming outcome.
///
/// Safe to call with nil plan (silent mode). Must be called on the main thread.
///
/// @param plan              Normalized VGAudioSidecarPlan, or nil for silence.
/// @param timelineDuration  Project duration in seconds
/// (VGEditorDraft.durationSeconds).
/// @param completion        Called exactly once on the main queue with a
///                          VGGraphAudioArmOutcome. Every code path — install,
///                          silent fallback, preparation failure, lifecycle
///                          gate rejection, stale generation, graph shutdown —
///                          reports exactly one outcome.
- (void)setAudioSidecarPlan:(nullable VGAudioSidecarPlan *)plan
           timelineDuration:(NSTimeInterval)timelineDuration
                 completion:(VGGraphAudioArmCompletion)completion
    NS_SWIFT_NAME(setAudioSidecarPlan(_:timelineDuration:completion:));

/// Forwards the Slice N recovery command to the installed audio preview
/// runtime.
///
/// Called by VGAudioRecordingHandler (Swift) immediately after an
/// AVAudioSession category transition (start or stop) to re-anchor the
/// AVAudioEngine and reschedule player nodes under the new session
/// configuration.
///
/// No-op (calls completion with nil) when no audio preview runtime is installed
/// (e.g. silent-mode project). Must be called on the main thread.
///
/// completion fires exactly once on the main queue:
///   nil   — engine restarted and preview recovered (or ReadySilent no-op).
///   error — engine restart failed; caller should log and continue; preview
///           may be silent until the next play command recovers it.
- (void)recoverAudioPreviewAfterSessionTransitionWithCompletion:
    (void (^)(NSError *_Nullable error))completion
    NS_SWIFT_NAME(recoverAudioPreviewAfterSessionTransition(completion:));

/// Forwards a live per-track mix-gain update to the installed audio preview
/// runtime without rebuilding the timeline.
///
/// |trackId| must be non-empty. |gain| is clamped to [0.0, 1.0] before
/// forwarding. No-op when no runtime is installed (silent-mode project).
/// Thread-safe: forwards asynchronously to the audio scheduler queue.
- (void)setMixGainForTrackId:(NSString *)trackId gain:(float)gain
    NS_SWIFT_NAME(setMixGain(trackId:gain:));

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
