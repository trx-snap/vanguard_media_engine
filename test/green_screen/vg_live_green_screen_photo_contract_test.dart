// Copyright 2026, Connects. All rights reserved.
// Unit tests for the generic live green-screen still-photo Dart contract:
// result serialization, MethodChannel routing, and error-code mapping.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_live_green_screen.dart';

const String _kChannelName = 'vanguard_media_engine';
const String _kTakePhoto = 'takeLiveGreenScreenPhoto';

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
  group('VGLiveGreenScreenPhotoResult', () {
    test('toMap has exact wire keys and fromMap round-trips', () {
      const result = VGLiveGreenScreenPhotoResult(
        filePath: '/cache/live_gs_photo.jpg',
        width: 720,
        height: 1280,
        fileSizeBytes: 262144,
      );

      final map = result.toMap();
      expect(map, <String, dynamic>{
        'filePath': '/cache/live_gs_photo.jpg',
        'width': 720,
        'height': 1280,
        'fileSizeBytes': 262144,
      });

      final parsed = VGLiveGreenScreenPhotoResult.fromMap(map);
      expect(parsed, equals(result));
      expect(parsed.hashCode, equals(result.hashCode));
      expect(parsed.toString(), contains('live_gs_photo.jpg'));
      expect(parsed.toString(), contains('720x1280'));
    });

    test('fromMap defaults absent numeric fields to zero', () {
      final parsed = VGLiveGreenScreenPhotoResult.fromMap(<String, dynamic>{
        'filePath': '/cache/photo.jpg',
      });
      expect(parsed.filePath, '/cache/photo.jpg');
      expect(parsed.width, 0);
      expect(parsed.height, 0);
      expect(parsed.fileSizeBytes, 0);
    });

    test('fromMap accepts doubles for numeric fields', () {
      final parsed = VGLiveGreenScreenPhotoResult.fromMap(<String, dynamic>{
        'filePath': '/cache/photo.jpg',
        'width': 720.0,
        'height': 1280.0,
        'fileSizeBytes': 2048.0,
      });
      expect(parsed.width, 720);
      expect(parsed.height, 1280);
      expect(parsed.fileSizeBytes, 2048);
    });

    test('fromMap throws on missing filePath', () {
      expect(
        () => VGLiveGreenScreenPhotoResult.fromMap(<String, dynamic>{
          'width': 720,
          'height': 1280,
          'fileSizeBytes': 10,
        }),
        throwsArgumentError,
      );
    });

    test('fromMap throws on empty filePath', () {
      expect(
        () => VGLiveGreenScreenPhotoResult.fromMap(<String, dynamic>{
          'filePath': '',
        }),
        throwsArgumentError,
      );
    });

    test('fromMap throws on non-string filePath', () {
      expect(
        () => VGLiveGreenScreenPhotoResult.fromMap(<String, dynamic>{
          'filePath': 42,
        }),
        throwsArgumentError,
      );
    });

    test('fromMap throws on non-numeric numeric field', () {
      for (final key in const ['width', 'height', 'fileSizeBytes']) {
        expect(
          () => VGLiveGreenScreenPhotoResult.fromMap(<String, dynamic>{
            'filePath': '/cache/photo.jpg',
            key: 'x',
          }),
          throwsArgumentError,
          reason: key,
        );
      }
    });

    test('equality distinguishes every field', () {
      const base = VGLiveGreenScreenPhotoResult(
        filePath: '/a.jpg',
        width: 1,
        height: 2,
        fileSizeBytes: 3,
      );
      expect(
        base,
        isNot(
          equals(
            const VGLiveGreenScreenPhotoResult(
              filePath: '/b.jpg',
              width: 1,
              height: 2,
              fileSizeBytes: 3,
            ),
          ),
        ),
      );
      expect(
        base,
        isNot(
          equals(
            const VGLiveGreenScreenPhotoResult(
              filePath: '/a.jpg',
              width: 9,
              height: 2,
              fileSizeBytes: 3,
            ),
          ),
        ),
      );
      expect(
        base,
        isNot(
          equals(
            const VGLiveGreenScreenPhotoResult(
              filePath: '/a.jpg',
              width: 1,
              height: 9,
              fileSizeBytes: 3,
            ),
          ),
        ),
      );
      expect(
        base,
        isNot(
          equals(
            const VGLiveGreenScreenPhotoResult(
              filePath: '/a.jpg',
              width: 1,
              height: 2,
              fileSizeBytes: 9,
            ),
          ),
        ),
      );
    });
  });

  group('MethodChannelVGLiveGreenScreenPlatform photo route', () {
    late _FakeMethodChannel fakeChannel;
    late MethodChannelVGLiveGreenScreenPlatform platform;

    setUp(() {
      fakeChannel = _FakeMethodChannel();
      platform = MethodChannelVGLiveGreenScreenPlatform(channel: fakeChannel);
    });

    test(
      'takePhoto sends sessionId and outputPath and parses the map',
      () async {
        fakeChannel.returnValue = <String, dynamic>{
          'filePath': '/cache/out.jpg',
          'width': 720,
          'height': 1280,
          'fileSizeBytes': 65536,
        };

        final result = await platform.takeLiveGreenScreenPhoto(
          sessionId: 'session-1',
          outputPath: '/cache/out.jpg',
        );

        expect(fakeChannel.lastMethod, _kTakePhoto);
        expect(fakeChannel.lastArgs, <String, dynamic>{
          'sessionId': 'session-1',
          'outputPath': '/cache/out.jpg',
        });
        expect(result.filePath, '/cache/out.jpg');
        expect(result.width, 720);
        expect(result.height, 1280);
        expect(result.fileSizeBytes, 65536);
      },
    );

    test('takePhoto parses a non-generic native map', () async {
      fakeChannel.returnValue = <Object?, Object?>{
        'filePath': '/cache/out.jpg',
        'width': 720,
        'height': 1280,
        'fileSizeBytes': 65536,
      };

      final result = await platform.takeLiveGreenScreenPhoto(
        sessionId: 'session-1',
        outputPath: '/cache/out.jpg',
      );
      expect(result.filePath, '/cache/out.jpg');
      expect(result.fileSizeBytes, 65536);
    });

    test(
      'takePhoto with a null native result throws recordingFailed',
      () async {
        fakeChannel.returnValue = null;
        try {
          await platform.takeLiveGreenScreenPhoto(
            sessionId: 'session-1',
            outputPath: '/cache/out.jpg',
          );
          fail('Expected VGLiveGreenScreenException');
        } on VGLiveGreenScreenException catch (e) {
          expect(e.code, VGLiveGreenScreenErrorCode.recordingFailed);
          expect(e.message, contains(_kTakePhoto));
        }
      },
    );

    test(
      'takePhoto with a malformed native result throws recordingFailed',
      () async {
        fakeChannel.returnValue = <String, dynamic>{'width': 720};
        try {
          await platform.takeLiveGreenScreenPhoto(
            sessionId: 'session-1',
            outputPath: '/cache/out.jpg',
          );
          fail('Expected VGLiveGreenScreenException');
        } on VGLiveGreenScreenException catch (e) {
          expect(e.code, VGLiveGreenScreenErrorCode.recordingFailed);
          expect(e.cause, isA<ArgumentError>());
        }
      },
    );
  });

  group('photo error-code mapping', () {
    test('PlatformException codes surface as typed exceptions', () async {
      final fakeChannel = _FakeMethodChannel();
      final platform = MethodChannelVGLiveGreenScreenPlatform(
        channel: fakeChannel,
      );
      final cases = <String, VGLiveGreenScreenErrorCode>{
        'session_not_found': VGLiveGreenScreenErrorCode.sessionNotFound,
        'INVALID_ARG': VGLiveGreenScreenErrorCode.invalidArgument,
        'recording_failed': VGLiveGreenScreenErrorCode.recordingFailed,
        'composition_failed': VGLiveGreenScreenErrorCode.compositionFailed,
        'something_else': VGLiveGreenScreenErrorCode.unknown,
      };
      for (final entry in cases.entries) {
        fakeChannel.errorToThrow = PlatformException(
          code: entry.key,
          message: 'native says ${entry.key}',
          details: <String, dynamic>{'sessionId': 'session-1'},
        );
        try {
          await platform.takeLiveGreenScreenPhoto(
            sessionId: 'session-1',
            outputPath: '/cache/out.jpg',
          );
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
        await platform.takeLiveGreenScreenPhoto(
          sessionId: 'session-1',
          outputPath: '/cache/out.jpg',
        );
        fail('Expected VGLiveGreenScreenException');
      } on VGLiveGreenScreenException catch (e) {
        expect(e.code, VGLiveGreenScreenErrorCode.unknown);
      }
    });
  });
}
