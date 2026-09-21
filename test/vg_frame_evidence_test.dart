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

  // ── ROI-5C.1 tests ───────────────────────────────────────────────────────
  _runFaceScanEvidenceTests();
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

// ── ROI-5C.1: extractImportedFaceScanEvidence tests ─────────────────────────

void _runFaceScanEvidenceTests() {
  const channel = MethodChannel('vanguard_media_engine');

  // ── FC1 + FC2 + FC3 — method name, argument key, map pass-through ─────────
  test(
    'FC1/FC2/FC3 — extractImportedFaceScanEvidence sends correct channel '
    'call and returns native map intact',
    () async {
      String? capturedMethod;
      dynamic capturedArgs;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        capturedMethod = call.method;
        capturedArgs   = call.arguments;
        return <Object?, Object?>{
          'frameWidth':           1080,
          'frameHeight':          1920,
          'method':               'VNDetectFaceRectanglesRequest',
          'frameExtractionMethod':'AVAssetImageGenerator',
          'visionOrientation':    'up',
          'coordinateSpace':      'displayTopLeftNormalizedAndPixels',
          'faceCount':            1,
          'faces': [
            {
              'index':            0,
              'visionX':          0.35,
              'visionY':          0.40,
              'visionWidth':      0.22,
              'visionHeight':     0.25,
              'normalizedX':      0.35,
              'normalizedY':      0.35,
              'normalizedWidth':  0.22,
              'normalizedHeight': 0.25,
              'pixelX':           378.0,
              'pixelY':           672.0,
              'pixelWidth':       237.6,
              'pixelHeight':      480.0,
              'clamped':          false,
            }
          ],
          'requestedTimeSeconds': 0.0,
          'actualTimeSeconds':    0.0,
        };
      });

      final tmp = await _createTempVideo();
      try {
        final result =
            await VanguardMediaPreparer.extractImportedFaceScanEvidence(
          videoPath: tmp,
        );

        expect(capturedMethod, equals('extractImportedFaceScanEvidence'),
            reason: 'FC1: method-channel name must be exact');
        expect((capturedArgs as Map?)!['videoPath'], equals(tmp),
            reason: 'FC2: videoPath argument key must match');
        expect(result, isNotNull, reason: 'FC3: non-null native response is forwarded');
        expect(result!['frameWidth'],            equals(1080));
        expect(result['frameHeight'],            equals(1920));
        expect(result['method'],                 equals('VNDetectFaceRectanglesRequest'));
        expect(result['frameExtractionMethod'],  equals('AVAssetImageGenerator'));
        expect(result['visionOrientation'],      equals('up'));
        expect(result['coordinateSpace'],        equals('displayTopLeftNormalizedAndPixels'));
        expect(result['faceCount'],              equals(1));
        expect(result['requestedTimeSeconds'],   equals(0.0));
        expect(result['actualTimeSeconds'],      equals(0.0));

        final faces = result['faces'] as List?;
        expect(faces, isNotNull, reason: 'FC3: faces list must be present');
        expect(faces!.length, equals(1), reason: 'FC3: one face expected');
        final face = faces[0] as Map;
        expect(face['index'],            equals(0));
        expect(face['visionX'],          equals(0.35));
        expect(face['visionY'],          equals(0.40));
        expect(face['visionWidth'],      equals(0.22));
        expect(face['visionHeight'],     equals(0.25));
        expect(face['normalizedX'],      equals(0.35));
        expect(face['normalizedY'],      equals(0.35));
        expect(face['normalizedWidth'],  equals(0.22));
        expect(face['normalizedHeight'], equals(0.25));
        expect(face['pixelX'],           equals(378.0));
        expect(face['pixelY'],           equals(672.0));
        expect(face['pixelWidth'],       equals(237.6));
        expect(face['pixelHeight'],      equals(480.0));
        expect(face['clamped'],          isFalse);
      } finally {
        await _deleteTempVideo(tmp);
      }
    },
  );

  // ── FC4 — no-face case: faceCount=0, faces=[] is not an error ─────────────
  test(
    'FC4 — no-face result (faceCount=0, faces=[]) is returned intact without error',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => <Object?, Object?>{
                'frameWidth':           1920,
                'frameHeight':          1080,
                'method':               'VNDetectFaceRectanglesRequest',
                'frameExtractionMethod':'AVAssetImageGenerator',
                'visionOrientation':    'up',
                'coordinateSpace':      'displayTopLeftNormalizedAndPixels',
                'faceCount':            0,
                'faces':                <Object?>[],
                'requestedTimeSeconds': 0.0,
                'actualTimeSeconds':    0.0,
              });

      final tmp = await _createTempVideo();
      try {
        final result =
            await VanguardMediaPreparer.extractImportedFaceScanEvidence(
          videoPath: tmp,
        );
        expect(result, isNotNull, reason: 'FC4: non-null result for no-face case');
        expect(result!['faceCount'], equals(0), reason: 'FC4: faceCount must be 0');
        final faces = result['faces'] as List?;
        expect(faces, isNotNull);
        expect(faces!.isEmpty, isTrue, reason: 'FC4: faces list must be empty');
      } finally {
        await _deleteTempVideo(tmp);
      }
    },
  );

  // ── FC5 — null native result returns null ──────────────────────────────────
  test(
    'FC5 — null native result is returned as null without crash',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);

      final tmp = await _createTempVideo();
      try {
        final result =
            await VanguardMediaPreparer.extractImportedFaceScanEvidence(
          videoPath: tmp,
        );
        expect(result, isNull, reason: 'FC5: null native result must become null');
      } finally {
        await _deleteTempVideo(tmp);
      }
    },
  );

  // ── FC6 — PlatformException (UNSUPPORTED_PLATFORM / Android) returns null ──
  test(
    'FC6 — PlatformException (UNSUPPORTED_PLATFORM) is caught and returns null',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'UNSUPPORTED_PLATFORM',
          message: 'ROI-5C Android face scan evidence is blocked until '
              'ROI-5B Android smoke passes',
        );
      });

      final tmp = await _createTempVideo();
      try {
        final result =
            await VanguardMediaPreparer.extractImportedFaceScanEvidence(
          videoPath: tmp,
        );
        expect(result, isNull,
            reason: 'FC6: PlatformException must be swallowed and return null');
      } finally {
        await _deleteTempVideo(tmp);
      }
    },
  );

  // ── FC7 — DECODE_FAILED PlatformException returns null ────────────────────
  test(
    'FC7 — DECODE_FAILED PlatformException from native is caught and returns null',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'DECODE_FAILED', message: 'test decode error');
      });

      final tmp = await _createTempVideo();
      try {
        final result =
            await VanguardMediaPreparer.extractImportedFaceScanEvidence(
          videoPath: tmp,
        );
        expect(result, isNull,
            reason: 'FC7: DECODE_FAILED PlatformException must return null');
      } finally {
        await _deleteTempVideo(tmp);
      }
    },
  );

  // ── FC8 — missing file short-circuits before channel call ─────────────────
  test(
    'FC8 — non-existent file short-circuits before channel call (returns null)',
    () async {
      bool channelCalled = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'extractImportedFaceScanEvidence') {
          channelCalled = true;
        }
        return null;
      });

      final result =
          await VanguardMediaPreparer.extractImportedFaceScanEvidence(
        videoPath: '/non/existent/path/video.mp4',
      );

      expect(result, isNull,
          reason: 'FC8: missing file must return null immediately');
      expect(channelCalled, isFalse,
          reason: 'FC8: channel must NOT be called for a missing file');
    },
  );

  // ── FC9 — Android MediaPipe FaceDetector payload passes through intact ────
  test(
    'FC9 — Android MediaPipe FaceDetector response is forwarded and schema-valid',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        return <Object?, Object?>{
          'frameWidth':           1080,
          'frameHeight':          1920,
          'method':               'MediaPipeTasksVisionFaceDetector',
          'frameExtractionMethod':'MediaMetadataRetriever',
          'visionOrientation':    'up',
          'coordinateSpace':      'displayTopLeftNormalizedAndPixels',
          'faceCount':            1,
          'faces': [
            {
              'index':            0,
              'visionX':          0.30,
              'visionY':          0.20,
              'visionWidth':      0.40,
              'visionHeight':     0.35,
              'normalizedX':      0.30,
              'normalizedY':      0.20,
              'normalizedWidth':  0.40,
              'normalizedHeight': 0.35,
              'pixelX':           324.0,
              'pixelY':           384.0,
              'pixelWidth':       432.0,
              'pixelHeight':      672.0,
              'clamped':          false,
              'confidence':       0.92,
            }
          ],
          'requestedTimeSeconds': 0.0,
          'actualTimeSeconds':    0.0,
        };
      });

      final tmp = await _createTempVideo();
      try {
        final result =
            await VanguardMediaPreparer.extractImportedFaceScanEvidence(
          videoPath: tmp,
        );
        expect(result, isNotNull, reason: 'FC9: Android native map is returned');
        expect(result!['method'], equals('MediaPipeTasksVisionFaceDetector'));
        expect(result['frameExtractionMethod'], equals('MediaMetadataRetriever'));
        expect(result['faceCount'], equals(1));
        final faces = result['faces'] as List?;
        expect(faces?.length, equals(1));
        final face = faces![0] as Map;
        expect(face['confidence'], equals(0.92));
      } finally {
        await _deleteTempVideo(tmp);
      }
    },
  );
}

