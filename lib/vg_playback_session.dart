// vg_playback_session.dart
// Vanguard Media Engine — Phase 1B, P1B-07 / Phase 2 Step 0
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
//   dispatcher uses. The sessionId is stable (UUID from VGSessionRegistry)
//   and is used for audio role operations (promoteAudio). Phase 2 Step 0:
//   VGPhase1Config deleted — registry path is unconditional.

import 'dart:async';

import 'package:flutter/services.dart';
import 'vg_filter_spec.dart';

/// A single active playback session backed by a [VanguardGraphRuntime] on the
/// native side (unconditional as of Phase 2 Step 0).
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
      'seconds': seconds,
    });
  }

  /// Applies a new filter chain to this session.
  ///
  /// [filters] is an ordered list of [VGFilterSpec] describing the filters to
  /// install. The native side assembles the actual [VGMetalFilterNode] graph
  /// from the received specs.
  ///
  /// An empty list removes all filters (passthrough).
  ///
  /// Routing note: intentionally sessionId-keyed (not textureId-keyed) because
  /// the native runtime registry lookup uses sessionId as the stable identifier.
  /// textureId can be recycled after dispose; sessionId is UUID-stable for the
  /// session lifetime.
  ///
  /// No-op if this session has already been [dispose]d.
  Future<void> setFilterChain(List<VGFilterSpec> filters) async {
    if (_disposed) return;
    // P4-10: Validate all specs against the native allowlist before dispatch.
    // assertValid() is a debug-mode assert (no-op in release). Catches typos
    // and unknown type strings early — before the method-channel round-trip
    // (RR-34 closure, DEC-42).
    for (final filter in filters) {
      filter.assertValid();
    }
    await _channel.invokeMethod<void>('setFilterChain', {
      'sessionId': sessionId,
      'filters': List<Map<String, Object?>>.unmodifiable(
        filters.map((f) => f.toJson()).toList(),
      ),
    });
  }

  /// Requests promotion of this session to the active audio role.
  ///
  /// Delegates to `VGSessionRegistry.promoteToActiveAudio(sessionId:)` on the
  /// native side, which acquires the [VGResourceAllocator] active-audio slot if
  /// available and transitions the runtime's effective role.
  ///
  /// Returns `true` if the native side confirmed the promotion.
  /// Returns `false` if:
  ///   - this session has already been [dispose]d, or
  ///   - the native allocator denied the promotion (slot already held), or
  ///   - native returned null (unexpected).
  ///
  /// Routing note: intentionally sessionId-keyed, not textureId-keyed, because
  /// the registry lookup for audio role transitions uses sessionId as the
  /// stable identifier (textureId can be recycled after dispose).
  Future<bool> promoteToActiveAudio() async {
    if (_disposed) return false;
    final result = await _channel.invokeMethod<bool>('promoteAudio', {
      'sessionId': sessionId,
    });
    return result ?? false;
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
