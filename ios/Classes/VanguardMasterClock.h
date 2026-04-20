// VanguardMasterClock.h
// Vanguard Media Engine — Phase 1A, P1A-04
//
// Concrete implementation of <VGMasterClock> extracted from VanguardFileMediaSource.
// Encapsulates all clock-related state: audio-clock path, wall-clock fallback,
// self-calibration, and monotonic floor enforcement.
//
// PACKAGE BOUNDARY (C-7):
//   Protocol: packages/UMF/ios/Classes/VGMasterClock.h
//   Concrete:  packages/vanguard_media_engine/ios/Classes/VanguardMasterClock.h  ← this file
//
// BEHAVIORAL CONTRACT:
//   This class is a structural extraction. All clock formulas are preserved
//   verbatim from VanguardFileMediaSource.masterClock. No logic changes.
//
// THREAD SAFETY:
//   All mutable state is accessed on the main thread only, mirroring the
//   pre-extraction threading model. calibrateWithPlayerNode: may only be called
//   from the main thread (mirrors the dispatch_async(main_queue) write sites).
//
// WALL-CLOCK FALLBACK:
//   Safe to query immediately after -init. _wallStartTime is set to
//   CACurrentMediaTime() in -init so currentTime returns a valid non-zero
//   advancing value from the moment of creation (guards against RR-5).
//
// The concrete graph runtime ships in Phase 1B (P1B-01 — VanguardGraphRuntime).

#import <Foundation/Foundation.h>
#import <CoreMedia/CMTime.h>
#import <AVFoundation/AVFoundation.h>

// UMF protocol (C-7: protocol in UMF package, concrete in Vanguard package)
#import "VGMasterClock.h"

NS_ASSUME_NONNULL_BEGIN

@interface VanguardMasterClock : NSObject <VGMasterClock>

// ─── VGMasterClock protocol properties ────────────────────────────────────────

/// Current output-timeline position.
/// Audio-clock path (when ready): _audioBaseTimeOffset + sampleTime/sampleRate.
/// Wall-clock fallback: CACurrentMediaTime() - _wallStartTime + _wallOffsetAtPause.
/// Paused: returns _wallOffsetAtPause.
/// Never returns a value less than the previously returned value (monotonic).
@property (nonatomic, readonly) CMTime currentTime;

/// Current playback rate. 1.0 = normal. Set externally by VanguardFileMediaSource.
/// Informational only — does not affect the clock formula (rate-correction happens
/// upstream in the renderer / VanguardFileMediaSource._timeProvider).
@property (nonatomic) double rate;

/// CACurrentMediaTime value recorded when the audio engine's clock origin was
/// established (i.e. when wallStartTime was last set). Returns 0 before
/// the first play() call.
@property (nonatomic, readonly) double hostTimeAtOrigin;

// ─── Calibration ──────────────────────────────────────────────────────────────

/// Wire the clock to the active AVAudioPlayerNode.
/// Stores a __weak reference to playerNode (ADR-009) to prevent retain cycles.
/// Main thread only. Safe to call before the node is playing (audioClockReady
/// guards the actual query).
- (void)calibrateWithPlayerNode:(AVAudioPlayerNode *)playerNode;

// ─── State setters — used by VanguardFileMediaSource internal write sites ──────
// These mirror the direct ivar writes in the pre-extraction implementation.
// All must be called on the main thread.

/// Set the seek-derived audio base time offset.
/// Called by VanguardFileMediaSource._rebuildAudioReaderForSecs: and
/// VanguardFileMediaSource._setupAudioEngine.
@property (nonatomic) double audioBaseTimeOffset;

/// Guards masterClock from querying the player node while [_playerNode play]
/// is running on a background thread (G-02-T3 fix). Main thread only.
@property (nonatomic) BOOL audioClockReady;

/// ONE-TIME self-calibration flag. Reset to NO at the start of each play/seek
/// session so the first valid sampleTime observation re-derives the offset.
@property (nonatomic) BOOL audioBaseTimeCalibrated;

/// CACurrentMediaTime at the start of the current play segment.
/// Set by VanguardFileMediaSource.play() and seekToTime: (when _isPlaying).
@property (nonatomic) double wallStartTime;

/// Accumulated time position when paused, or the last seek target.
/// Used as both the pause snapshot and the paused-state return value.
@property (nonatomic) CMTime wallOffsetAtPause;

/// Monotonic floor — prevents clock from going backwards.
/// Reset to 0 by play() and seek. Reset to 0 by _teardownAudioEngine.
@property (nonatomic) double lastMasterClockSecs;

/// Whether the source is currently in a playing state.
/// Forwarded from VanguardFileMediaSource._isPlaying so the fallback
/// path knows whether to advance the wall clock.
@property (nonatomic) BOOL isPlaying;

@end

NS_ASSUME_NONNULL_END
