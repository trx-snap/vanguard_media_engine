// vg_playback_client.dart
// Vanguard Media Engine — Phase 1B, P1B-08 / Phase 2 Step 0
//
// Factory for [VGPlaybackSession]. Calls the `createTexture` method channel and
// safely normalises the returned map into a [VGPlaybackSession].
//
// Design constraints honoured:
//   C-2 — Not exported from the public barrel file yet.
//   C-4 — No changes to any existing production code path.
//   C-6 — Zero reference to VanguardMetalRenderer or C++ FFI bindings.
//
// Phase 2 Step 0: VGPhase1Config.useGraphRuntime deleted. The registry path
// (VGSessionRegistry + VanguardGraphRuntime) is now unconditional. Native
// always returns a Map with {textureId, sessionId, width, height}. The
// synthetic 'legacy-{textureId}' sessionId fallback is retained defensively
// for any call site that may omit sessionId, but is not expected to be reached.

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
  /// When [muted] is true the native session is created with [VGAudioRole.muted],
  /// so it never contends for the active audio slot. Defaults to false (active).
  ///
  /// Throws a [PlatformException] or [StateError] if the native side fails to
  /// create the texture (e.g. file not found, GPU out of memory).
  static Future<VGPlaybackSession> createSession(
    String url, {
    bool muted = false,
  }) async {
    final (:session, raw: _) = await createSessionRaw(url, muted: muted);
    return session;
  }

  /// Like [createSession] but also returns the raw native map so callers can
  /// extract extra fields (e.g. `width`, `height`) without a second channel call.
  ///
  /// [muted] is forwarded to the native `createTexture` handler as the
  /// `muted` key. See [createSession] for the full contract.
  ///
  /// Returns a record `({VGPlaybackSession session, Map<Object?, Object?>? raw})`.
  static Future<({VGPlaybackSession session, Map<Object?, Object?>? raw})>
      createSessionRaw(String url, {bool muted = false}) async {
    final raw = await _channel.invokeMethod<Object>(
      'createTexture',
      {'path': url, 'muted': muted},
    );

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

  // ── P4-10: Gallery image session factory ──────────────────────────────────

  /// Creates a [VGPlaybackSession] for a gallery-picked or local image file.
  ///
  /// Calls the native `createImageTexture` handler, which:
  ///   1. Allocates a [VGResourceAllocator] pixel-buffer pool for the image.
  ///   2. Registers the runtime in [VGSessionRegistry] under a stable UUID.
  ///   3. Returns `{textureId, sessionId, width, height}`.
  ///
  /// Unlike [VanguardEngine.createImageTexture] (which discards `sessionId`),
  /// this factory preserves both identifiers so the caller can invoke
  /// [VGPlaybackSession.setFilterChain] on the resulting session — the primary
  /// use case for P4-10 gallery image filtering.
  ///
  /// The existing [VanguardEngine.createImageTexture] static method is
  /// **unchanged** — existing callers that only need a `textureId` continue
  /// to work identically (backward-compatible, additive).
  ///
  /// Throws [StateError] or [PlatformException] if the native side fails.
  ///
  /// Usage:
  /// ```dart
  /// final session = await VGPlaybackClient.createImageSession(path);
  /// await session.setFilterChain([VGFilterSpecs.beauty()]);
  /// // Display: Texture(textureId: session.textureId)
  /// ```
  static Future<({VGPlaybackSession session, int width, int height})>
      createImageSession(String path) async {
    final raw = await _channel.invokeMethod<Object>(
      'createImageTexture',
      {'path': path},
    );

    if (raw == null) {
      throw StateError(
          '[VGPlaybackClient] createImageTexture returned null for: $path');
    }

    final Map<Object?, Object?> map;
    if (raw is Map) {
      map = raw;
    } else {
      // Bare int fallback — legacy path (should not occur with current plugin).
      final legacyId = (raw as num?)?.toInt() ?? -1;
      if (legacyId < 0) {
        throw StateError(
            '[VGPlaybackClient] createImageTexture returned invalid id for: $path');
      }
      final session = VGPlaybackSession(
        sessionId: 'legacy-img-$legacyId',
        textureId: legacyId,
      );
      return (session: session, width: 0, height: 0);
    }

    final textureId = (map['textureId'] as num?)?.toInt() ?? -1;
    if (textureId < 0) {
      throw StateError(
          '[VGPlaybackClient] createImageTexture returned textureId=$textureId for: $path');
    }

    // sessionId is present because the plugin routes createImageTexture through
    // VGSessionRegistry.createSession (plugin:302). Fallback to a synthetic id
    // only on unexpected legacy shapes.
    final sessionId =
        (map['sessionId'] as String?) ?? 'legacy-img-$textureId';

    final w = (map['width'] as num?)?.toInt() ?? 0;
    final h = (map['height'] as num?)?.toInt() ?? 0;

    final session = VGPlaybackSession(sessionId: sessionId, textureId: textureId);
    return (session: session, width: w, height: h);
  }
}
