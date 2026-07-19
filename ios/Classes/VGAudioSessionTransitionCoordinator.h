// VGAudioSessionTransitionCoordinator.h
// Vanguard Media Engine — Audio Slice N
//
// Exclusively owns AVAudioSession category transitions, activation,
// rollback, normalization, and route inspection for the recording lifecycle.
//
// VISIBILITY: Module-visible (not in private_header_files) because Swift
// (VGAudioRecordingHandler) imports it directly.
//
// States:
//   playback        — session is in Playback category; safe to start recording.
//   enteringRecord  — transient; category switch in progress (not externally
//                     observable).
//   record          — session is in PlayAndRecord category and active.
//   restoringPlayback — transient; Playback restoration in progress.
//   unknown         — session is in an unproven state after a rollback failure.
//                     Only normalizationAttempt may proceed.
//
// PlayAndRecord options used:
//   MixWithOthers      — allows AVAudioEngine preview to keep playing.
//   AllowBluetoothHFP  — enables Bluetooth HFP microphone input.
//   AllowBluetoothA2DP — allows high-quality A2DP output alongside recording.
//
// Playback restoration always calls:
//   setCategory:AVAudioSessionCategoryPlayback
//   setActive:YES
// Never calls setActive:NO (that would silence AVAudioEngine playback).
//
// All public methods are main-thread confined.
// All methods return VGSessionTransitionOutcome — no NSError** parameters
// are exposed to Swift.

#pragma once

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "VGAudioRouteSnapshot.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// ─── VGSessionTransitionStatus ───────────────────────────────────────────────

typedef NS_ENUM(NSInteger, VGSessionTransitionStatus) {
    /// Transition completed successfully.
    VGSessionTransitionStatusSuccess            = 0,
    /// setCategory failed; no AVAudioSession state was mutated.
    VGSessionTransitionStatusFailedNoMutation   = 1,
    /// Transition failed; session was rolled back to a known Playback state.
    VGSessionTransitionStatusFailedKnownPlayback = 2,
    /// Transition failed and rollback also failed; session state is unknown.
    VGSessionTransitionStatusFailedUnknown      = 3,
};

// ─── VGSessionCoordinatorState ───────────────────────────────────────────────

typedef NS_ENUM(NSInteger, VGSessionCoordinatorState) {
    VGSessionCoordinatorStatePlayback         = 0,
    VGSessionCoordinatorStateEnteringRecord   = 1,
    VGSessionCoordinatorStateRecord           = 2,
    VGSessionCoordinatorStateRestoringPlayback = 3,
    VGSessionCoordinatorStateUnknown          = 4,
};

// ─── VGSessionTransitionOutcome ──────────────────────────────────────────────

/// Immutable result object returned by all coordinator transition methods.
/// No NSError** parameters are exposed — all errors are carried here so
/// Swift callers receive clean non-throwing call sites.
@interface VGSessionTransitionOutcome : NSObject

@property(nonatomic, readonly) VGSessionTransitionStatus status;

/// The error that caused a non-Success status (nil on Success).
@property(nonatomic, readonly, nullable) NSError *primaryError;

/// The additional error from rollback/normalization failure, when applicable.
@property(nonatomic, readonly, nullable) NSError *secondaryError;

+ (instancetype)success
    NS_SWIFT_NAME(success());
+ (instancetype)failureWithStatus:(VGSessionTransitionStatus)status
                     primaryError:(NSError *)primaryError
                   secondaryError:(nullable NSError *)secondaryError
    NS_SWIFT_NAME(failure(status:primaryError:secondaryError:));
- (instancetype)init NS_UNAVAILABLE;

@end

// ─── VGAudioSessionBackend ────────────────────────────────────────────────────
//
// Testable seam. Production implementation wraps AVAudioSession. Tests inject a
// fake that returns plain VGRouteSnapshot / VGPortSnapshot values without
// needing real AVFoundation hardware objects.

@protocol VGAudioSessionBackend <NSObject>

- (BOOL)setCategory:(AVAudioSessionCategory)category
         withOptions:(AVAudioSessionCategoryOptions)options
               error:(NSError * _Nullable * _Nullable)outError;

- (BOOL)setActiveYesWithError:(NSError * _Nullable * _Nullable)outError;

/// Returns the current route as a plain VGRouteSnapshot (no AVFoundation types
/// cross the seam boundary).
- (VGRouteSnapshot *)currentRoute;

/// Returns available input ports as plain VGPortSnapshot values.
- (NSArray<VGPortSnapshot *> *)availableInputs;

@end

// ─── VGAudioSessionTransitionCoordinator ─────────────────────────────────────

@interface VGAudioSessionTransitionCoordinator : NSObject

/// Current coordinator state. Main-thread confined; read only for diagnostics.
@property(nonatomic, readonly) VGSessionCoordinatorState state;

/// Designated initialiser. Pass nil to use the production AVAudioSession backend.
- (instancetype)initWithSessionBackend:(nullable id<VGAudioSessionBackend>)backend
    NS_DESIGNATED_INITIALIZER;

/// Convenience init using the production backend.
- (instancetype)init;

// ── Transition methods (main-thread only) ─────────────────────────────────────

/// Switches AVAudioSession to PlayAndRecord.
///
/// Valid from state: playback only.
/// On success:                  state → record,   returns Success.
/// setCategory failure:         state unchanged,  returns FailedNoMutation.
/// setActive failure, rollback OK:  state → playback, returns FailedKnownPlayback.
/// setActive failure, rollback fail: state → unknown, returns FailedUnknown.
- (VGSessionTransitionOutcome *)switchToPlayAndRecord
    NS_SWIFT_NAME(switchToPlayAndRecord());

/// Restores AVAudioSession to Playback.
///
/// Valid from any state.
/// playback:    idempotent no-op, returns Success.
/// record:      perform Playback restore, returns Success or FailedUnknown.
/// unknown:     attempt restore, returns Success or FailedUnknown.
- (VGSessionTransitionOutcome *)restorePlayback
    NS_SWIFT_NAME(restorePlayback());

/// Attempts to normalise an unknown session state back to Playback.
///
/// Valid from any state (no-op from playback).
/// Success:  state → playback, returns Success.
/// Failure:  state → unknown,  returns FailedUnknown.
- (VGSessionTransitionOutcome *)normalizationAttempt
    NS_SWIFT_NAME(normalizationAttempt());

/// Captures the current route state and builds a VGAudioRouteSnapshot.
///
/// Always returns a non-nil snapshot. When no active input exists,
/// inputAvailable is NO and activeInputType is "none".
/// Must be called after category activation so the route reflects PlayAndRecord.
- (VGAudioRouteSnapshot *)captureRouteSnapshot
    NS_SWIFT_NAME(captureRouteSnapshot());

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
