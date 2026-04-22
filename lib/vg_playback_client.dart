// vg_playback_client.dart
// Vanguard Media Engine — Phase 1B, P1B-08
//
// Factory for [VGPlaybackSession]. Calls the `createTexture` method channel and
// safely normalises both the legacy integer return and the new map return into a
// [VGPlaybackSession].
//
// Design constraints honoured:
//   C-2 — Not exported from the public barrel file yet.
//   C-4 — No changes to any existing production code path.
//   C-6 — Zero reference to VanguardMetalRenderer or C++ FFI bindings.
//
// Return-type flexibility:
//   Legacy path (useGraphRuntime = false): native returns a Map with at minimum
//     { 'textureId': int }; may also have 'width' and 'height'.
//   New graph-runtime path (useGraphRuntime = true): same Map shape with an
//     additional 'sessionId' String key.
//   In both cases this client constructs a VGPlaybackSession. When sessionId is
//   absent (legacy path), a synthetic placeholder is used so the VGPlaybackSession
//   contract (non-null sessionId) is always satisfied.

import 'package:flutter/services.dart';
import 'vg_playback_session.dart';

/// Factory that creates [VGPlaybackSession] instances via the Vanguard
/// method channel.
///
/// Usage:
/// ```dart
/// final session = await VGPlaybackClient.createSession('/path/to/video.mp4');
/// // Display with: Texture(textureId: session.textureId)
/// await session.play();
/// // ...
/// await session.dispose();
/// ```
abstract final class VGPlaybackClient {
  // ── Channel ─────────────────────────────────────────────────────────────────

  static const _channel = MethodChannel('vanguard_media_engine');

  // ── Factory ──────────────────────────────────────────────────────────────────

  /// Creates a new playback session for the media file at [url].
  ///
  /// Calls the native `createTexture` handler. Safely handles both return shapes:
  ///   - New graph-runtime path: `{ 'textureId': int, 'sessionId': String, ...}`
  ///   - Legacy renderer path:   `{ 'textureId': int, 'width': int, 'height': int }`
  ///
  /// Throws a [PlatformException] or [StateError] if the native side fails to
  /// create the texture (e.g. file not found, GPU out of memory).
  static Future<VGPlaybackSession> createSession(String url) async {
    final (:session, raw: _) = await createSessionRaw(url);
    return session;
  }

  /// Like [createSession] but also returns the raw native map so callers can
  /// extract extra fields (e.g. `width`, `height`) without a second channel call.
  ///
  /// Returns a record `({VGPlaybackSession session, Map<Object?, Object?>? raw})`.
  static Future<({VGPlaybackSession session, Map<Object?, Object?>? raw})>
      createSessionRaw(String url) async {
    final raw = await _channel.invokeMethod<Object>('createTexture', {'path': url});

    if (raw == null) {
      throw StateError('[VGPlaybackClient] createTexture returned null for: $url');
    }

    // ── Normalise the native return type ──────────────────────────────────────
    final Map<Object?, Object?> map;

    if (raw is Map) {
      map = raw;
    } else {
      // Defensive: handle a bare integer return (should not occur with current
      // iOS plugin but guards against unexpected shapes).
      final legacyId = (raw as num?)?.toInt() ?? -1;
      if (legacyId < 0) {
        throw StateError('[VGPlaybackClient] createTexture returned invalid id '
            'for: $url');
      }
      final session = VGPlaybackSession(
        sessionId: 'legacy-$legacyId',
        textureId: legacyId,
      );
      return (session: session, raw: null);
    }

    // ── Extract textureId (required) ──────────────────────────────────────────
    final textureId = (map['textureId'] as num?)?.toInt() ?? -1;
    if (textureId < 0) {
      throw StateError('[VGPlaybackClient] createTexture returned textureId=$textureId '
          'for: $url');
    }

    // ── Extract sessionId (optional — absent on legacy path) ──────────────────
    final sessionId = (map['sessionId'] as String?) ?? 'legacy-$textureId';

    final session = VGPlaybackSession(sessionId: sessionId, textureId: textureId);
    return (session: session, raw: map);
  }
}
