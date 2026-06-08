// VGAudioPlaybackService.h
// vanguard_media_engine — Phase 8.16
//
// Standalone AVPlayer-backed audio playback service.
//
// Architecture:
//   Service-level wrapper (DEC-V2-067 boundary model, Level 1-2 only).
//   Uses AVPlayer for simple file-based audio playback.
//   Does NOT use AVAudioEngine, AVAudioPlayerNode, mixer topologies, EQ,
//   or any real-time audio graph (those are Phase 15).
//
// Ownership:
//   One VGAudioPlaybackService instance is held by VanguardMediaEnginePlugin.
//   The service owns exactly one AVPlayer at a time.
//   A new load() call stops/releases the old player before creating a new one.
//
// Threading:
//   All public methods must be called on the main thread.
//   Completion callbacks fire on the main thread.
//
// AVAudioSession:
//   Does NOT configure or activate AVAudioSession.
//   The existing pre-activated .playback session (set up by
//   VanguardFileMediaSource.preActivateAudioSession) is shared.
//
// Lifecycle:
//   stop/dispose is idempotent.
//   Registers AVPlayerItemDidPlayToEndTimeNotification; does NOT auto-loop.

#pragma once

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGAudioPlaybackService ───────────────────────────────────────────────────

/// Standalone AVPlayer-backed audio playback service.
///
/// Supports exactly one active player at a time.
/// All methods must be called on the main thread.
@interface VGAudioPlaybackService : NSObject

/// Loads a local audio file at [path] and prepares for playback.
///
/// If a player is already active it is stopped and released before the
/// new player is created. On success fires [completion] with
/// durationSeconds > 0 and error == nil. On failure fires completion with
/// durationSeconds == 0 and a non-nil error.
///
/// Must be called on the main thread.
- (void)loadWithPath:(NSString *)path
          completion:(void (^)(double durationSeconds, NSError * _Nullable error))completion;

/// Resumes playback from the current position.
/// No-op if no player is loaded.
- (void)play;

/// Pauses playback at the current position.
/// No-op if no player is loaded or already paused.
- (void)pause;

/// Stops playback and releases the AVPlayer.
/// Seeks to zero before releasing. Idempotent.
- (void)stop;

/// Seeks to [seconds] in the current player item with zero tolerance.
/// No-op (completion called immediately) if no player is loaded.
/// [completion] is always invoked exactly once on the main thread.
- (void)seekToSeconds:(double)seconds completion:(void (^)(void))completion;

/// Sets playback volume in range [0.0, 1.0].
/// Clamped to [0.0, 1.0] if out of range.
/// No-op if no player is loaded.
- (void)setVolume:(float)volume;

/// Returns the current playback position in seconds.
/// Returns 0.0 if no player is loaded or position is invalid.
- (double)currentPositionSeconds;

@end

NS_ASSUME_NONNULL_END
