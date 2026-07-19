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

@interface VanguardGraphRuntime (AudioPreview)

/// Arms the audio preview runtime after the video compositor is ready.
///
/// Tears down any existing audio runtime, constructs a new one, prepares it
/// from the supplied sidecar plan, and calls |completion| on the main queue
/// when the runtime is installed (or when silent fallback is applied).
///
/// Safe to call with nil plan (silent mode). Must be called on the main thread.
///
/// @param plan              Normalized VGAudioSidecarPlan, or nil for silence.
/// @param timelineDuration  Project duration in seconds (VGEditorDraft.durationSeconds).
/// @param completion        Called exactly once on the main queue when audio
///                          setup is complete (success or silent fallback).
- (void)setAudioSidecarPlan:(nullable VGAudioSidecarPlan *)plan
           timelineDuration:(NSTimeInterval)timelineDuration
                 completion:(dispatch_block_t)completion
    NS_SWIFT_NAME(setAudioSidecarPlan(_:timelineDuration:completion:));

/// Forwards the Slice N recovery command to the installed audio preview runtime.
///
/// Called by VGAudioRecordingHandler (Swift) immediately after an AVAudioSession
/// category transition (start or stop) to re-anchor the AVAudioEngine and
/// reschedule player nodes under the new session configuration.
///
/// No-op (calls completion with nil) when no audio preview runtime is installed
/// (e.g. silent-mode project). Must be called on the main thread.
///
/// completion fires exactly once on the main queue:
///   nil   — engine restarted and preview recovered (or ReadySilent no-op).
///   error — engine restart failed; caller should log and continue; preview
///           may be silent until the next play command recovers it.
- (void)recoverAudioPreviewAfterSessionTransitionWithCompletion:
    (void (^)(NSError * _Nullable error))completion
    NS_SWIFT_NAME(recoverAudioPreviewAfterSessionTransition(completion:));

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
