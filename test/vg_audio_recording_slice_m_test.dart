// vg_audio_recording_slice_m_test.dart
// Vanguard Media Engine — Audio Slice N
//
// Dart tests for:
//   1. VGAudioRecordingStartResult / VGAudioRecordingStopResult / VGTransitionStatus model parsing.
//   2. VGEditorController.startAudioRecording / stopAudioRecording channel binding.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_audio_recording_models.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_editor_controller.dart';
import 'package:vanguard_media_engine/vg_editor_draft.dart';

// ── Fixture helpers ────────────────────────────────────────────────────────────

VGClipDescriptor _clip({required String id, double trimEnd = 5.0}) =>
    VGClipDescriptor(
      id: id,
      sourcePath: '/tmp/fixture_$id.mp4',
      durationSeconds: trimEnd,
      trimStartSeconds: 0.0,
      trimEndSeconds: trimEnd,
    );

// ── Mock channel helper ────────────────────────────────────────────────────────

void _setMockHandler(
  Future<Object?> Function(String method, dynamic args) handler,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('vanguard_media_engine'),
    (call) => handler(call.method, call.arguments),
  );
}

void _clearMockHandler() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('vanguard_media_engine'),
    null,
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(_clearMockHandler);

  // ── Model parsing ──────────────────────────────────────────────────────────

  group('VGAudioRecordingStartResult.fromMap', () {
    test('SM-D1 parses a valid map with nested audioRoute', () {
      final map = <Object?, Object?>{
        'filePath': '/tmp/rec.m4a',
        'startPTS': 3.14,
        'isHeadphonesConnected': true,
        'audioRoute': {
          'activeInputType': 'builtInMic',
          'activeInputName': 'Built-in Microphone',
          'activeInputUID': 'mic_uid',
          'activeInputDataSourceName': 'Front',
          'availableInputTypes': ['builtInMic', 'headsetMic'],
          'activeOutputTypes': ['builtInSpeaker'],
          'hasHeadphoneOutput': false,
          'activeInputIsExternal': false,
          'inputAvailable': true,
        }
      };
      final r = VGAudioRecordingStartResult.fromMap(map);
      expect(r, isNotNull);
      expect(r!.filePath, '/tmp/rec.m4a');
      expect(r.startPTS, closeTo(3.14, 1e-9));
      expect(r.isHeadphonesConnected, isTrue);

      final route = r.audioRoute;
      expect(route, isNotNull);
      expect(route!.activeInputType, 'builtInMic');
      expect(route.activeInputName, 'Built-in Microphone');
      expect(route.activeInputUID, 'mic_uid');
      expect(route.activeInputDataSourceName, 'Front');
      expect(route.availableInputTypes, containsAll(['builtInMic', 'headsetMic']));
      expect(route.activeOutputTypes, contains('builtInSpeaker'));
      expect(route.hasHeadphoneOutput, isFalse);
      expect(route.activeInputIsExternal, isFalse);
      expect(route.inputAvailable, isTrue);
    });

    test('SM-D2 returns null for missing filePath', () {
      final map = <Object?, Object?>{
        'startPTS': 3.14,
        'isHeadphonesConnected': false,
      };
      expect(VGAudioRecordingStartResult.fromMap(map), isNull);
    });

    test('SM-D3 returns null for missing startPTS', () {
      final map = <Object?, Object?>{
        'filePath': '/tmp/rec.m4a',
        'isHeadphonesConnected': false,
      };
      expect(VGAudioRecordingStartResult.fromMap(map), isNull);
    });

    test('SM-D1b isHeadphonesConnected defaults to false when absent', () {
      final map = <Object?, Object?>{
        'filePath': '/tmp/rec.m4a',
        'startPTS': 1.0,
      };
      final r = VGAudioRecordingStartResult.fromMap(map);
      expect(r, isNotNull);
      expect(r!.isHeadphonesConnected, isFalse);
    });
  });

  group('VGAudioRecordingStopResult.fromMap', () {
    test('SM-D4 parses a valid map with nested transitionStatus', () {
      final map = <Object?, Object?>{
        'filePath': '/tmp/rec.m4a',
        'startPTS': 3.0,
        'durationSeconds': 4.012,
        'transitionStatus': {
          'sessionRestored': true,
          'previewRecovered': false,
          'sessionErrorCode': null,
          'previewErrorCode': 'RECOVERY_RUNTIME_NIL',
        }
      };
      final r = VGAudioRecordingStopResult.fromMap(map);
      expect(r, isNotNull);
      expect(r!.filePath, '/tmp/rec.m4a');
      expect(r.startPTS, closeTo(3.0, 1e-9));
      expect(r.durationSeconds, closeTo(4.012, 1e-9));

      final ts = r.transitionStatus;
      expect(ts.sessionRestored, isTrue);
      expect(ts.previewRecovered, isFalse);
      expect(ts.sessionErrorCode, isNull);
      expect(ts.previewErrorCode, 'RECOVERY_RUNTIME_NIL');

      // Compatibility getter delegates to transitionStatus.sessionRestored
      expect(r.sessionRestored, isTrue);
    });

    test('SM-D5 returns null for incomplete map', () {
      final map = <Object?, Object?>{
        'filePath': '/tmp/rec.m4a',
        'durationSeconds': 4.012,
      };
      expect(VGAudioRecordingStopResult.fromMap(map), isNull);
    });

    test('SM-D5b missing transitionStatus map defaults booleans to false', () {
      final map = <Object?, Object?>{
        'filePath': '/tmp/rec.m4a',
        'startPTS': 3.0,
        'durationSeconds': 4.012,
      };
      final r = VGAudioRecordingStopResult.fromMap(map);
      expect(r, isNotNull);
      expect(r!.transitionStatus, isNotNull);
      expect(r.transitionStatus.sessionRestored, isFalse);
      expect(r.transitionStatus.previewRecovered, isFalse);
      expect(r.sessionRestored, isFalse);
    });
  });

  // ── Channel binding ────────────────────────────────────────────────────────

  group('VGEditorController recording channel binding', () {
    late VGEditorController controller;

    setUp(() {
      controller = VGEditorController(
        initialDraft: VGEditorDraft(
          id: 'draft-sliceM',
          clips: [_clip(id: 'clip-sm')],
        ),
      );
    });

    tearDown(() {
      controller.dispose();
    });

    test('SM-D6 startAudioRecording sends correct channel call', () async {
      String? capturedMethod;
      dynamic capturedArgs;

      _setMockHandler((method, args) async {
        capturedMethod = method;
        capturedArgs = args;
        if (method == 'startAudioRecording') {
          return {
            'filePath': '/tmp/out.m4a',
            'startPTS': 3.5,
            'isHeadphonesConnected': false,
            'audioRoute': {
              'activeInputType': 'builtInMic',
              'activeInputName': 'Built-in Microphone',
              'activeInputUID': 'mic_uid',
              'activeInputDataSourceName': null,
              'availableInputTypes': ['builtInMic'],
              'activeOutputTypes': ['builtInSpeaker'],
              'hasHeadphoneOutput': false,
              'activeInputIsExternal': false,
              'inputAvailable': true,
            }
          };
        }
        return null;
      });

      final result = await controller.startAudioRecording('/tmp/out.m4a');

      expect(capturedMethod, 'startAudioRecording');
      expect((capturedArgs as Map)['outputPath'], '/tmp/out.m4a');
      expect(result.filePath, '/tmp/out.m4a');
      expect(result.startPTS, closeTo(3.5, 1e-9));
      expect(result.isHeadphonesConnected, isFalse);
      expect(result.audioRoute?.activeInputType, 'builtInMic');
    });

    test('SM-D7 startAudioRecording throws PlatformException on incomplete native map',
        () async {
      _setMockHandler((method, args) async {
        if (method == 'startAudioRecording') {
          // Missing startPTS — fromMap will return null.
          return {'filePath': '/tmp/out.m4a'};
        }
        return null;
      });

      await expectLater(
        controller.startAudioRecording('/tmp/out.m4a'),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'INVALID_RESPONSE')),
      );
    });

    test('SM-D8 stopAudioRecording sends correct channel call', () async {
      String? capturedMethod;

      _setMockHandler((method, args) async {
        capturedMethod = method;
        if (method == 'stopAudioRecording') {
          return {
            'filePath': '/tmp/out.m4a',
            'startPTS': 3.5,
            'durationSeconds': 4.1,
            'transitionStatus': {
              'sessionRestored': true,
              'previewRecovered': true,
            }
          };
        }
        return null;
      });

      final result = await controller.stopAudioRecording();

      expect(capturedMethod, 'stopAudioRecording');
      expect(result.filePath, '/tmp/out.m4a');
      expect(result.startPTS, closeTo(3.5, 1e-9));
      expect(result.durationSeconds, closeTo(4.1, 1e-9));
      expect(result.sessionRestored, isTrue);
      expect(result.transitionStatus.previewRecovered, isTrue);
    });

    test('SM-D9 stopAudioRecording throws PlatformException on incomplete native map',
        () async {
      _setMockHandler((method, args) async {
        if (method == 'stopAudioRecording') {
          // Missing durationSeconds — fromMap returns null.
          return {'filePath': '/tmp/out.m4a', 'startPTS': 3.5};
        }
        return null;
      });

      await expectLater(
        controller.stopAudioRecording(),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'INVALID_RESPONSE')),
      );
    });

    test('SM-D10 methods throw StateError after dispose', () async {
      _setMockHandler((method, args) async => null);
      controller.dispose();

      expect(
        () => controller.startAudioRecording('/tmp/out.m4a'),
        throwsStateError,
      );
      expect(
        () => controller.stopAudioRecording(),
        throwsStateError,
      );
    });
  });
}
