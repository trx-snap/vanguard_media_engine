// vg_audio_recording_slice_m_test.dart
// Vanguard Media Engine — Audio Slice M
//
// Dart tests for:
//   1. VGAudioRecordingStartResult / VGAudioRecordingStopResult model parsing.
//   2. VGEditorController.startAudioRecording / stopAudioRecording channel binding.
//
// Tests:
//   SM-D1  VGAudioRecordingStartResult.fromMap parses a valid map.
//   SM-D2  VGAudioRecordingStartResult.fromMap returns null for missing filePath.
//   SM-D3  VGAudioRecordingStartResult.fromMap returns null for missing startPTS.
//   SM-D4  VGAudioRecordingStopResult.fromMap parses a valid map.
//   SM-D5  VGAudioRecordingStopResult.fromMap returns null for incomplete map.
//   SM-D6  startAudioRecording invokes 'startAudioRecording' with outputPath arg.
//   SM-D7  startAudioRecording throws PlatformException on incomplete native map.
//   SM-D8  stopAudioRecording invokes 'stopAudioRecording' with no args.
//   SM-D9  stopAudioRecording throws PlatformException on incomplete native map.
//   SM-D10 Both methods throw StateError after controller is disposed.

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
    test('SM-D1 parses a valid map', () {
      final map = <Object?, Object?>{
        'filePath': '/tmp/rec.m4a',
        'startPTS': 3.14,
        'isHeadphonesConnected': true,
      };
      final r = VGAudioRecordingStartResult.fromMap(map);
      expect(r, isNotNull);
      expect(r!.filePath, '/tmp/rec.m4a');
      expect(r.startPTS, closeTo(3.14, 1e-9));
      expect(r.isHeadphonesConnected, isTrue);
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
    test('SM-D4 parses a valid map', () {
      final map = <Object?, Object?>{
        'filePath': '/tmp/rec.m4a',
        'startPTS': 3.0,
        'durationSeconds': 4.012,
      };
      final r = VGAudioRecordingStopResult.fromMap(map);
      expect(r, isNotNull);
      expect(r!.filePath, '/tmp/rec.m4a');
      expect(r.startPTS, closeTo(3.0, 1e-9));
      expect(r.durationSeconds, closeTo(4.012, 1e-9));
    });

    test('SM-D5 returns null for incomplete map', () {
      final map = <Object?, Object?>{
        'filePath': '/tmp/rec.m4a',
        // startPTS missing
        'durationSeconds': 4.012,
      };
      expect(VGAudioRecordingStopResult.fromMap(map), isNull);
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
          };
        }
        return null;
      });

      final result = await controller.stopAudioRecording();

      expect(capturedMethod, 'stopAudioRecording');
      expect(result.filePath, '/tmp/out.m4a');
      expect(result.startPTS, closeTo(3.5, 1e-9));
      expect(result.durationSeconds, closeTo(4.1, 1e-9));
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
