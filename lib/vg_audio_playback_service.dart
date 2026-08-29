// vg_audio_playback_service.dart
// vanguard_media_engine — Phase 8.16 / Phase 5-Unit Y / Phase 4-Unit G
//
// Dart bridge for the native standalone audio playback service (iOS AVPlayer,
// Android MediaPlayer).
//
// Scope:
//   - VGAudioPlaybackService: static API calling audioPlayback_* MethodChannel methods.
//
// Non-goals (Phase 8.16):
//   - No real-time audio graph (Phase 15).
//   - No EventChannel/stream for position/state — poll getPosition() if needed.
//   - No setRate/setSpeed (Phase 15).
//   - No looping.
//   - No AVAudioSession configuration (handled by native plugin at startup).

import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// VGAudioPlaybackService
// ─────────────────────────────────────────────────────────────────────────────

/// Standalone native audio playback service (iOS AVPlayer, Android MediaPlayer).
///
/// Routes through the `audioPlayback_*` MethodChannel methods.
/// Supports exactly one active audio file at a time — calling [load] while
/// audio is playing stops the prior audio automatically on the native side.
///
/// On iOS, the native service does NOT configure AVAudioSession; the
/// pre-activated `.playback` session shared with the rest of the Vanguard
/// engine is used.
///
/// Errors:
///   - [ArgumentError] for invalid Dart-side arguments.
///   - [PlatformException] for native failures. Check [PlatformException.code]:
///       'LOAD_FAILED'    — asset could not be loaded (bad path, no audio track)
///       'INVALID_ARG'    — native argument validation failure
abstract final class VGAudioPlaybackService {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');

  /// Loads a local audio file at [path] and prepares for playback.
  ///
  /// [path] must be a non-empty absolute path to a readable local file.
  /// Any previously loaded audio is stopped and released before loading.
  ///
  /// Returns the duration of the audio file in seconds.
  /// Returns 0.0 if the duration cannot be determined (e.g. streaming source).
  ///
  /// Throws [ArgumentError] if [path] is empty.
  /// Throws [PlatformException] for native load failures.
  static Future<double> load({required String path}) async {
    if (path.isEmpty) {
      throw ArgumentError.value(path, 'path', 'must be non-empty');
    }
    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'audioPlayback_load',
      {'path': path},
    );
    return (raw?['durationSeconds'] as num?)?.toDouble() ?? 0.0;
  }

  /// Resumes playback from the current position.
  ///
  /// No-op if no audio is loaded.
  /// Throws [PlatformException] for unexpected native failures.
  static Future<void> play() async {
    await _channel.invokeMethod<void>('audioPlayback_play');
  }

  /// Pauses playback at the current position.
  ///
  /// No-op if no audio is loaded or already paused.
  static Future<void> pause() async {
    await _channel.invokeMethod<void>('audioPlayback_pause');
  }

  /// Stops playback and releases the native AVPlayer.
  ///
  /// Idempotent — safe to call even when no audio is loaded.
  /// After stop, [getPosition] returns 0.0.
  static Future<void> stop() async {
    await _channel.invokeMethod<void>('audioPlayback_stop');
  }

  /// Seeks to [seconds] in the currently loaded audio.
  ///
  /// [seconds] must be finite and >= 0.
  ///
  /// Throws [ArgumentError] if [seconds] is negative or non-finite.
  /// No-op natively if no audio is loaded.
  static Future<void> seekTo(double seconds) async {
    if (!seconds.isFinite || seconds < 0.0) {
      throw ArgumentError.value(seconds, 'seconds', 'must be finite and >= 0');
    }
    await _channel.invokeMethod<void>('audioPlayback_seekTo', {
      'seconds': seconds,
    });
  }

  /// Sets the playback volume.
  ///
  /// [volume] must be finite and in the range [0.0, 1.0].
  /// The native side also clamps, but Dart validates first to provide a
  /// clean ArgumentError instead of a silent clamp.
  ///
  /// Throws [ArgumentError] if [volume] is out of range or non-finite.
  static Future<void> setVolume(double volume) async {
    if (!volume.isFinite || volume < 0.0 || volume > 1.0) {
      throw ArgumentError.value(
        volume,
        'volume',
        'must be finite and in range [0.0, 1.0]',
      );
    }
    await _channel.invokeMethod<void>('audioPlayback_setVolume', {
      'volume': volume,
    });
  }

  /// Returns the current playback position in seconds.
  ///
  /// Returns 0.0 if no audio is loaded or position is unavailable.
  static Future<double> getPosition() async {
    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'audioPlayback_getPosition',
    );
    return (raw?['seconds'] as num?)?.toDouble() ?? 0.0;
  }
}
