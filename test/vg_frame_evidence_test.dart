// vg_frame_evidence_test.dart
// ROI-5B.1 — Dart-layer method-channel contract tests for
// VanguardMediaPreparer.extractDisplayOrientedFrameEvidence.
//
// Tests verify:
//   T1 — correct method-channel name is invoked
//   T2 — videoPath argument key is correct
//   T3 — returned map is passed through intact
//   T4 — null native result is handled (returns null)
//   T5 — PlatformException is caught and returns null
//   T6 — empty videoPath short-circuits before channel call
//
// NO video fixtures. All inputs are synthetic path strings.
// The native channel is mocked via TestDefaultBinaryMessengerBinding.

import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_preparer.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vanguard_media_engine');

  // ── T1 + T2 + T3 — correct channel name, argument key, map pass-through ──
  test(
    'T1/T2/T3 — extractDisplayOrientedFrameEvidence sends correct channel '
    'call and returns native map intact',
    () async {
      String? capturedMethod;
      dynamic capturedArgs;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        capturedMethod = call.method;
        capturedArgs   = call.arguments;
        return <Object?, Object?>{
          'extractedFrameWidth':     1080,
          'extractedFrameHeight':    1920,
          'method':                  'AVAssetImageGenerator',
          'rotationHandling':        'appliesPreferredTrackTransform',
          'displayTransformApplied': true,
          'requestedTimeSeconds':    0.0,
          'actualTimeSeconds':       0.033,
        };
      });

      // Use a non-existent path that satisfies the File.existsSync() guard by
      // relying on the fact that our test environment does not have the file —
      // however the Dart guard checks existsSync() before the channel call.
      // To bypass the guard in a unit-test context, we need the file to appear
      // to exist. Since we cannot create real files here, we verify the channel
      // plumbing by directly patching the mock and trusting that the guard
      // will short-circuit for genuinely missing files (covered in T6).
      //
      // Approach: call with a temp path that exists on the test runner's OS.
      // Using Directory.systemTemp so the file path is valid and non-empty,
      // even though the file itself is absent. The guard returns null early.
      // We therefore test the channel plumbing separately from the guard path.
      //
      // Clean approach: test channel plumbing via a path that passes the guard.
      // We create a temporary file for this one test.
      final tmp = await _createTempVideo();
      try {
        final result =
            await VanguardMediaPreparer.extractDisplayOrientedFrameEvidence(
          videoPath: tmp,
        );

        expect(capturedMethod, equals('extractDisplayOrientedFrameEvidence'),
            reason: 'T1: method-channel name must be exact');
        expect((capturedArgs as Map?)!['videoPath'], equals(tmp),
            reason: 'T2: videoPath argument key must match');
        expect(result, isNotNull, reason: 'T3: non-null native response is forwarded');
        expect(result!['extractedFrameWidth'],  equals(1080));
        expect(result['extractedFrameHeight'],  equals(1920));
        expect(result['method'],                equals('AVAssetImageGenerator'));
        expect(result['rotationHandling'],      equals('appliesPreferredTrackTransform'));
        expect(result['displayTransformApplied'], isTrue);
        expect(result['requestedTimeSeconds'],  equals(0.0));
        expect(result['actualTimeSeconds'],     equals(0.033));
      } finally {
        await _deleteTempVideo(tmp);
      }
    },
  );

  // ── T4 — null native result returns null to Dart ─────────────────────────
  test(
    'T4 — null native result is returned as null without crash',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);

      final tmp = await _createTempVideo();
      try {
        final result =
            await VanguardMediaPreparer.extractDisplayOrientedFrameEvidence(
          videoPath: tmp,
        );
        expect(result, isNull, reason: 'T4: null native result must become null');
      } finally {
        await _deleteTempVideo(tmp);
      }
    },
  );

  // ── T5 — PlatformException is caught and returns null ────────────────────
  test(
    'T5 — PlatformException from native is caught and returns null',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'DECODE_FAILED', message: 'test error');
      });

      final tmp = await _createTempVideo();
      try {
        final result =
            await VanguardMediaPreparer.extractDisplayOrientedFrameEvidence(
          videoPath: tmp,
        );
        expect(result, isNull,
            reason: 'T5: PlatformException must be swallowed and return null');
      } finally {
        await _deleteTempVideo(tmp);
      }
    },
  );

  // ── T6 — missing/empty file returns null without channel call ─────────────
  test(
    'T6 — non-existent file short-circuits before channel call (returns null)',
    () async {
      bool channelCalled = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'extractDisplayOrientedFrameEvidence') {
          channelCalled = true;
        }
        return null;
      });

      final result =
          await VanguardMediaPreparer.extractDisplayOrientedFrameEvidence(
        videoPath: '/non/existent/path/video.mp4',
      );

      expect(result, isNull,
          reason: 'T6: missing file must return null immediately');
      expect(channelCalled, isFalse,
          reason: 'T6: channel must NOT be called for a missing file');
    },
  );
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Creates a minimal non-empty temp file so File.existsSync() and
/// File.lengthSync() pass the Dart guard in extractDisplayOrientedFrameEvidence.
/// Content is irrelevant — native decoding is mocked.
Future<String> _createTempVideo() async {
  final tmp = File(
    '${Directory.systemTemp.path}/vg_frame_evidence_test_${DateTime.now().microsecondsSinceEpoch}.mp4',
  );
  await tmp.writeAsBytes([0x00, 0x00, 0x00, 0x18]); // 4-byte placeholder
  return tmp.path;
}

Future<void> _deleteTempVideo(String path) async {
  try {
    await File(path).delete();
  } catch (_) {}
}
