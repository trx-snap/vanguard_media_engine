// vg_android_multicam_slice5_recording_test.dart
// Vanguard Media Engine - Slice 5 Mechanical Verification Test
//
// Tests for Slice 5: Composited Video Recording (startMultiCamRecording /
// stopMultiCamRecording) on Android. Validates the Dart-side method channel
// contract against the Android result map shape produced by
// AndroidMultiCamVideoRecorder.stop() via AndroidCamera2MultiCamPreviewCoordinator:
//   {filePath, durationSeconds, width, height, framesOffered, framesAppended,
//    framesDroppedWriterNotReady, writerStatus, fileSizeBytes}
//
// This is a pure Dart method-channel mock test — no native code runs. It pins
// the contract (method names, argument shape, result parsing, and error-code
// behavior) so a future change to either side is caught here first.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_camera_session.dart';
import 'package:vanguard_media_engine/vg_multicam_recording_stats.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('vanguard_media_engine');
  final List<MethodCall> log = <MethodCall>[];
  final Map<String, dynamic> responses = <String, dynamic>{};

  setUp(() {
    log.clear();
    responses.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      log.add(methodCall);
      if (responses.containsKey(methodCall.method)) {
        final dynamic resp = responses[methodCall.method];
        if (resp is Exception) throw resp;
        return resp;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('Slice 5 - startMultiCamRecording Contract', () {
    const kVideoPath = '/tmp/slice5_multicam_video.mp4';

    test('dispatches method call with correct path argument', () async {
      responses['startMultiCamRecording'] = true;

      await VGCameraSession.startMultiCamRecording(kVideoPath);

      expect(log.length, equals(1));
      expect(log.first.method, equals('startMultiCamRecording'));
      final args = log.first.arguments as Map;
      expect(args['path'], equals(kVideoPath));
    });

    test('returns true on native success', () async {
      responses['startMultiCamRecording'] = true;

      final result = await VGCameraSession.startMultiCamRecording(kVideoPath);

      expect(result, isTrue);
    });

    for (final code in [
      'NOT_RUNNING',
      'NOT_RENDERING',
      'ALREADY_RECORDING',
      'DISK_SPACE',
      'WRITER_INIT_FAIL',
      'INVALID_ARG',
    ]) {
      test('returns false on $code', () async {
        responses['startMultiCamRecording'] = PlatformException(
          code: code,
          message: 'startMultiCamRecording failed with $code',
        );

        final result = await VGCameraSession.startMultiCamRecording(kVideoPath);

        expect(result, isFalse);
      });
    }
  });

  group('Slice 5 - stopMultiCamRecording Contract', () {
    const kVideoPath = '/tmp/slice5_multicam_video.mp4';

    // Matches the exact payload returned by
    // AndroidMultiCamVideoRecorder.stop() via the coordinator on success,
    // with audio present (mic permission granted).
    const kAndroidStopResponseWithAudio = <Object?, Object?>{
      'filePath': kVideoPath,
      'durationSeconds': 12.5,
      'width': 1080,
      'height': 1920,
      'framesOffered': 375,
      'framesAppended': 373,
      'framesDroppedWriterNotReady': 2,
      'writerStatus': 2,
      'fileSizeBytes': 15728640,
    };

    // MC-20 video-only fallback: identical stats shape — audio presence is
    // not observable at the Dart layer, so the same fields must parse.
    const kAndroidStopResponseVideoOnly = <Object?, Object?>{
      'filePath': kVideoPath,
      'durationSeconds': 8.0,
      'width': 1080,
      'height': 1920,
      'framesOffered': 240,
      'framesAppended': 240,
      'framesDroppedWriterNotReady': 0,
      'writerStatus': 2,
      'fileSizeBytes': 9437184,
    };

    test('dispatches method call with no arguments', () async {
      responses['stopMultiCamRecording'] = kAndroidStopResponseWithAudio;

      await VGCameraSession.stopMultiCamRecording();

      expect(log.length, equals(1));
      expect(log.first.method, equals('stopMultiCamRecording'));
    });

    test('parses the Android stats map into a populated VGMultiCamRecordingStats', () async {
      responses['stopMultiCamRecording'] = kAndroidStopResponseWithAudio;

      final stats = await VGCameraSession.stopMultiCamRecording();

      expect(stats, isNotNull);
      expect(stats!.filePath, equals(kVideoPath));
      expect(stats.durationSeconds, equals(12.5));
      expect(stats.width, equals(1080));
      expect(stats.height, equals(1920));
      expect(stats.framesOffered, equals(375));
      expect(stats.framesAppended, equals(373));
      expect(stats.framesDroppedWriterNotReady, equals(2));
      expect(stats.writerStatus, equals(2));
      expect(stats.fileSizeBytes, equals(15728640));
    });

    test('MC-20: a video-only stats map (no audio track) parses identically', () async {
      responses['stopMultiCamRecording'] = kAndroidStopResponseVideoOnly;

      final stats = await VGCameraSession.stopMultiCamRecording();

      expect(stats, isNotNull);
      expect(stats!.filePath, equals(kVideoPath));
      expect(stats.durationSeconds, equals(8.0));
      expect(stats.width, equals(1080));
      expect(stats.height, equals(1920));
      expect(stats.framesOffered, equals(240));
      expect(stats.framesAppended, equals(240));
      expect(stats.framesDroppedWriterNotReady, equals(0));
      expect(stats.writerStatus, equals(2));
      expect(stats.fileSizeBytes, equals(9437184));
    });

    test('returns null when channel returns null payload', () async {
      responses['stopMultiCamRecording'] = null;

      final stats = await VGCameraSession.stopMultiCamRecording();

      expect(stats, isNull);
    });

    for (final code in ['NOT_RUNNING', 'NOT_RECORDING', 'WRITER_FINISH_FAIL']) {
      test('returns null on $code', () async {
        responses['stopMultiCamRecording'] = PlatformException(
          code: code,
          message: 'stopMultiCamRecording failed with $code',
        );

        final stats = await VGCameraSession.stopMultiCamRecording();

        expect(stats, isNull);
      });
    }

    test('VGMultiCamRecordingStats.fromMap handles the exact Android result keys', () {
      final stats = VGMultiCamRecordingStats.fromMap(
        Map<String, dynamic>.from(kAndroidStopResponseWithAudio),
      );

      expect(stats.filePath, equals(kVideoPath));
      expect(stats.durationSeconds, equals(12.5));
      expect(stats.width, equals(1080));
      expect(stats.height, equals(1920));
      expect(stats.framesOffered, equals(375));
      expect(stats.framesAppended, equals(373));
      expect(stats.framesDroppedWriterNotReady, equals(2));
      expect(stats.writerStatus, equals(2));
      expect(stats.fileSizeBytes, equals(15728640));
    });
  });
}
