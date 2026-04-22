// vg_playback_session.dart
// Vanguard Media Engine — Phase 1B, P1B-07
//
// Represents a single active playback session as a thin value object that routes
// lifecycle calls through the Vanguard method channel.
//
// Design constraints honoured:
//   C-2 — The class is not exported from the public barrel file yet.
//   C-4 — No changes to existing VanguardEngine internals.
//   C-6 — Zero reference to VanguardMetalRenderer or any C++ FFI binding.
//
// Channel key:
//   Playback commands (play / pause / seekTo / dispose) are all keyed by
//   textureId because that is what the native plugin's method-channel
//   dispatcher uses. The sessionId is stored for diagnostics and future
//   expansion (Phase 2 multi-session routing will promote it as the primary key).

import 'package:flutter/services.dart';

/// A single active playback session backed by a [VanguardGraphRuntime] on the
/// native side (when `VGPhase1Config.useGraphRuntime == true`) or by a
/// [VanguardMetalRenderer] on the legacy path.
///
/// Obtain instances via [VGPlaybackClient.createSession].
/// Call [dispose] when the widget is torn down to release native resources.
final class VGPlaybackSession {
  // ── Channel ─────────────────────────────────────────────────────────────────

  static const _channel = MethodChannel('vanguard_media_engine');

  // ── Identity ─────────────────────────────────────────────────────────────---

  /// Native session identifier (UUID string). Opaque from Dart's perspective;
  /// used for logging and Phase 2 multi-session routing.
  final String sessionId;

  /// Flutter texture ID. Pass to `Texture(textureId: textureId)` to display frames.
  final int textureId;

  // ── State ────────────────────────────────────────────────────────────────────

  /// Guards against duplicate `dispose()` calls (AC-3 idempotency).
  bool _disposed = false;

  // ── Constructor ─────────────────────────────────────────────────────────────

  /// Internal constructor. Use [VGPlaybackClient.createSession] to create instances.
  VGPlaybackSession({required this.sessionId, required this.textureId});

  // ── Playback control ─────────────────────────────────────────────────────────

  /// Starts or resumes playback.
  Future<void> play() async {
    if (_disposed) return;
    await _channel.invokeMethod<void>('play', {'textureId': textureId});
  }

  /// Pauses playback. Safe to call when already paused.
  Future<void> pause() async {
    if (_disposed) return;
    await _channel.invokeMethod<void>('pause', {'textureId': textureId});
  }

  /// Seeks the playback position to [seconds] seconds from the start.
  Future<void> seekTo(double seconds) async {
    if (_disposed) return;
    await _channel.invokeMethod<void>('seekTo', {
      'textureId': textureId,
      'seconds':   seconds,
    });
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  /// Releases the native GPU texture and associated media pipeline resources.
  ///
  /// Idempotent: subsequent calls are silent no-ops.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _channel.invokeMethod<void>('dispose', {'textureId': textureId});
  }

  // ── Debug ────────────────────────────────────────────────────────────────────

  @override
  String toString() =>
      'VGPlaybackSession(sessionId: $sessionId, textureId: $textureId, '
      'disposed: $_disposed)';
}
