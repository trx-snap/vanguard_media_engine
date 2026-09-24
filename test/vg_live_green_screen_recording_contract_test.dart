// Copyright 2026, Connects. All rights reserved.
// Unit tests for the generic live green-screen recording Dart contract:
// result serialization, MethodChannel routing, and error-code mapping.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_live_green_screen.dart';

const String _kChannelName = 'vanguard_media_engine';
const String _kStartRecording = 'startLiveGreenScreenRecording';
const String _kStopRecording = 'stopLiveGreenScreenRecording';
const String _kCancelRecording = 'cancelLiveGreenScreenRecording';

/// Test double for [MethodChannel] recording calls and returning stubbed
/// responses.
class _FakeMethodChannel extends Fake implements MethodChannel {
  String? lastMethod;
  dynamic lastArgs;
  dynamic returnValue;
  Object? errorToThrow;

  @override
  String get name => _kChannelName;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    lastMethod = method;
    lastArgs = arguments;
    if (errorToThrow != null) {
      throw errorToThrow!;
    }
    if (returnValue is T?) {
      return returnValue as T?;
    }
    return null;
  }
}

void main() {
  group('VGLiveGreenScreenRecordingResult', () {
    test('toMap has exact wire keys and fromMap round-trips', () {
      const result = VGLiveGreenScreenRecordingResult(
        filePath: '/cache/live_gs_take.mp4',
        durationMs: 4200,
        fileSizeBytes: 1048576,
        width: 720,
        height: 1280,
        hasAudio: true,
      );

      final map = result.toMap();
      expect(map, <String, dynamic>{
        'filePath': '/cache/live_gs_take.mp4',
        'durationMs': 4200,
        'fileSizeBytes': 1048576,
        'width': 720,
        'height': 1280,
        'hasAudio': true,
      });

      final parsed = VGLiveGreenScreenRecordingResult.fromMap(map);
      expect(parsed, equals(result));
      expect(parsed.hashCode, equals(result.hashCode));
      expect(parsed.toString(), contains('live_gs_take.mp4'));
    });

    test('fromMap defaults absent numeric and bool fields', () {
      final parsed = VGLiveGreenScreenRecordingResult.fromMap(<String, dynamic>{
        'filePath': '/cache/take.mp4',
      });
      expect(parsed.filePath, '/cache/take.mp4');
      expect(parsed.durationMs, 0);
      expect(parsed.fileSizeBytes, 0);
      expect(parsed.width, 0);
      expect(parsed.height, 0);
      expect(parsed.hasAudio, isFalse);
    });

    test('fromMap accepts doubles for numeric fields', () {
      final parsed = VGLiveGreenScreenRecordingResult.fromMap(<String, dynamic>{
        'filePath': '/cache/take.mp4',
        'durationMs': 1500.0,
        'fileSizeBytes': 2048.0,
      });
      expect(parsed.durationMs, 1500);
      expect(parsed.fileSizeBytes, 2048);
    });

    test('fromMap throws on missing filePath', () {
      expect(
        () => VGLiveGreenScreenRecordingResult.fromMap(<String, dynamic>{
          'durationMs': 10,
          'fileSizeBytes': 10,
        }),
        throwsArgumentError,
      );
    });

    test('fromMap throws on empty filePath', () {
      expect(
        () => VGLiveGreenScreenRecordingResult.fromMap(<String, dynamic>{
          'filePath': '',
        }),
        throwsArgumentError,
      );
    });

    test('fromMap throws on non-string filePath', () {
      expect(
        () => VGLiveGreenScreenRecordingResult.fromMap(<String, dynamic>{
          'filePath': 42,
        }),
        throwsArgumentError,
      );
    });

    test('fromMap throws on non-numeric numeric field', () {
      expect(
        () => VGLiveGreenScreenRecordingResult.fromMap(<String, dynamic>{
          'filePath': '/cache/take.mp4',
          'durationMs': 'x',
        }),
        throwsArgumentError,
      );
    });
  });

  group('MethodChannelVGLiveGreenScreenPlatform recording routes', () {
    late _FakeMethodChannel fakeChannel;
    late MethodChannelVGLiveGreenScreenPlatform platform;

    setUp(() {
      fakeChannel = _FakeMethodChannel();
      platform = MethodChannelVGLiveGreenScreenPlatform(channel: fakeChannel);
    });

    test('start sends sessionId and outputPath', () async {
      await platform.startLiveGreenScreenRecording(
        sessionId: 'session-1',
        outputPath: '/cache/out.mp4',
      );
      expect(fakeChannel.lastMethod, _kStartRecording);
      expect(fakeChannel.lastArgs, <String, dynamic>{
        'sessionId': 'session-1',
        'outputPath': '/cache/out.mp4',
      });
    });

    test('start omits outputPath when null', () async {
      await platform.startLiveGreenScreenRecording(sessionId: 'session-1');
      expect(fakeChannel.lastMethod, _kStartRecording);
      expect(fakeChannel.lastArgs, <String, dynamic>{'sessionId': 'session-1'});
    });

    test('stop sends sessionId and parses the result map', () async {
      fakeChannel.returnValue = <String, dynamic>{
        'filePath': '/cache/out.mp4',
        'durationMs': 3000,
        'fileSizeBytes': 65536,
        'width': 720,
        'height': 1280,
        'hasAudio': false,
      };

      final result = await platform.stopLiveGreenScreenRecording(
        sessionId: 'session-1',
      );

      expect(fakeChannel.lastMethod, _kStopRecording);
      expect(fakeChannel.lastArgs, <String, dynamic>{'sessionId': 'session-1'});
      expect(result.filePath, '/cache/out.mp4');
      expect(result.durationMs, 3000);
      expect(result.fileSizeBytes, 65536);
      expect(result.width, 720);
      expect(result.height, 1280);
      expect(result.hasAudio, isFalse);
    });

    test('stop with a null native result throws recordingFailed', () async {
      fakeChannel.returnValue = null;
      try {
        await platform.stopLiveGreenScreenRecording(sessionId: 'session-1');
        fail('Expected VGLiveGreenScreenException');
      } on VGLiveGreenScreenException catch (e) {
        expect(e.code, VGLiveGreenScreenErrorCode.recordingFailed);
      }
    });

    test(
      'stop with a malformed native result throws recordingFailed',
      () async {
        fakeChannel.returnValue = <String, dynamic>{'durationMs': 10};
        try {
          await platform.stopLiveGreenScreenRecording(sessionId: 'session-1');
          fail('Expected VGLiveGreenScreenException');
        } on VGLiveGreenScreenException catch (e) {
          expect(e.code, VGLiveGreenScreenErrorCode.recordingFailed);
          expect(e.cause, isA<ArgumentError>());
        }
      },
    );

    test('cancel sends sessionId', () async {
      await platform.cancelLiveGreenScreenRecording(sessionId: 'session-1');
      expect(fakeChannel.lastMethod, _kCancelRecording);
      expect(fakeChannel.lastArgs, <String, dynamic>{'sessionId': 'session-1'});
    });
  });

  group('recording error-code mapping', () {
    test('fromPlatformCode maps every recording code', () {
      expect(
        VGLiveGreenScreenErrorCode.fromPlatformCode('recording_active'),
        VGLiveGreenScreenErrorCode.recordingActive,
      );
      expect(
        VGLiveGreenScreenErrorCode.fromPlatformCode('recording_not_active'),
        VGLiveGreenScreenErrorCode.recordingNotActive,
      );
      expect(
        VGLiveGreenScreenErrorCode.fromPlatformCode('recording_failed'),
        VGLiveGreenScreenErrorCode.recordingFailed,
      );
      expect(
        VGLiveGreenScreenErrorCode.fromPlatformCode('disk_full'),
        VGLiveGreenScreenErrorCode.diskFull,
      );
      expect(
        VGLiveGreenScreenErrorCode.fromPlatformCode('session_not_found'),
        VGLiveGreenScreenErrorCode.sessionNotFound,
      );
      expect(
        VGLiveGreenScreenErrorCode.fromPlatformCode('something_else'),
        VGLiveGreenScreenErrorCode.unknown,
      );
    });

    test('PlatformException codes surface as typed exceptions', () async {
      final fakeChannel = _FakeMethodChannel();
      final platform = MethodChannelVGLiveGreenScreenPlatform(
        channel: fakeChannel,
      );
      final cases = <String, VGLiveGreenScreenErrorCode>{
        'recording_active': VGLiveGreenScreenErrorCode.recordingActive,
        'recording_not_active': VGLiveGreenScreenErrorCode.recordingNotActive,
        'recording_failed': VGLiveGreenScreenErrorCode.recordingFailed,
        'disk_full': VGLiveGreenScreenErrorCode.diskFull,
      };
      for (final entry in cases.entries) {
        fakeChannel.errorToThrow = PlatformException(
          code: entry.key,
          message: 'native says ${entry.key}',
          details: <String, dynamic>{'sessionId': 'session-1'},
        );
        try {
          await platform.startLiveGreenScreenRecording(sessionId: 'session-1');
          fail('Expected VGLiveGreenScreenException for ${entry.key}');
        } on VGLiveGreenScreenException catch (e) {
          expect(e.code, entry.value, reason: entry.key);
          expect(e.message, 'native says ${entry.key}');
          expect(e.details, <String, dynamic>{'sessionId': 'session-1'});
          expect(e.cause, isA<PlatformException>());
        }
      }
    });

    test('MissingPluginException maps to unknown', () async {
      final fakeChannel = _FakeMethodChannel()
        ..errorToThrow = MissingPluginException('not implemented');
      final platform = MethodChannelVGLiveGreenScreenPlatform(
        channel: fakeChannel,
      );
      try {
        await platform.cancelLiveGreenScreenRecording(sessionId: 'session-1');
        fail('Expected VGLiveGreenScreenException');
      } on VGLiveGreenScreenException catch (e) {
        expect(e.code, VGLiveGreenScreenErrorCode.unknown);
      }
    });
  });
}
