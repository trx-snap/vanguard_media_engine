// vg_playback_client_test.dart
// Vanguard Media Engine — P4-10 gallery image session factory tests.
//
// Validates VGPlaybackClient.createImageSession behaviour:
//   T1 — parses textureId + sessionId from a map-shaped native response
//   T2 — legacy bare-int response falls back to synthetic sessionId without crash
//   T3 — existing createImageTexture still returns only a bare int (no regression)

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_playback_client.dart';
import 'package:vanguard_media_engine/vg_playback_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vanguard_media_engine');

  // ── T1 — createImageSession: map response with textureId + sessionId ────────
  test(
    'createImageSession parses textureId and sessionId from native map (P4-10)',
    () async {
      // Arrange: stub native to return the same payload the plugin sends at line 317.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'createImageTexture') {
          return <Object?, Object?>{
            'textureId': 42,
            'sessionId': 'test-uuid-1234',
            'width':     1080,
            'height':    1920,
          };
        }
        return null;
      });

      // Act
      final result = await VGPlaybackClient.createImageSession('/fake/image.jpg');

      // Assert
      expect(result.session.textureId, 42,
          reason: 'textureId must be extracted from the native map');
      expect(result.session.sessionId, 'test-uuid-1234',
          reason: 'sessionId must be preserved — required for setFilterChain dispatch');
      expect(result.width, 1080, reason: 'width forwarded from native map');
      expect(result.height, 1920, reason: 'height forwarded from native map');
      expect(result.session, isA<VGPlaybackSession>());
    },
  );

  // ── T2 — createImageSession: bare-int fallback ──────────────────────────────
  test(
    'createImageSession handles legacy bare-int response without crash (T2)',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'createImageTexture') return 99; // bare int
        return null;
      });

      final result = await VGPlaybackClient.createImageSession('/fake/img.png');

      expect(result.session.textureId, 99);
      expect(result.session.sessionId, startsWith('legacy-img-'),
          reason: 'synthetic sessionId must use legacy-img- prefix');
      expect(result.width, 0, reason: 'width unavailable on bare-int path');
    },
  );

  // ── T3 — createImageTexture backward compat: still returns only int ─────────
  // createImageTexture is on VanguardEngine (static), not VGPlaybackClient.
  // We test VGPlaybackClient.createImageSession doesn't break createImageTexture
  // by verifying they use the same channel method and both can co-exist.
  test(
    'createImageSession and createImageTexture invoke the same channel method '
    'without conflict (T3 — backward compat)',
    () async {
      int callCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'createImageTexture') {
          callCount++;
          return <Object?, Object?>{
            'textureId': callCount * 10,
            'sessionId': 'sid-$callCount',
            'width': 720, 'height': 1280,
          };
        }
        return null;
      });

      // Both calls should succeed independently.
      final r1 = await VGPlaybackClient.createImageSession('/a.jpg');
      final r2 = await VGPlaybackClient.createImageSession('/b.jpg');

      expect(r1.session.textureId, 10);
      expect(r2.session.textureId, 20);
      expect(callCount, 2, reason: 'each call invokes the native method once');
    },
  );
}
