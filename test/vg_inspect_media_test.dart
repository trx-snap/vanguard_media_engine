// vg_inspect_media_test.dart
// Unit tests for VanguardMediaPreparer.inspectMedia:
//   - Android content:// URI preflight bypass and native method channel dispatch
//   - POSIX local file existence and non-zero length preflight guards
//   - Remote HTTP/HTTPS URL rejection
//   - Native response parsing into MediaInfo
//   - PlatformException / null native result handling

import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vanguard_media_engine');

  final dummyNativeResponse = <Object?, Object?>{
    'kind': 'video',
    'container': 'mp4',
    'videoCodec': 'h264',
    'audioCodec': 'aac',
    'width': 1080,
    'height': 1920,
    'displayWidth': 1080,
    'displayHeight': 1920,
    'durationSeconds': 12.5,
    'bitrateKbps': 4000,
    'fps': 30.0,
    'fileSizeBytes': 5242880,
    'hasVideo': true,
    'hasAudio': true,
    'isHDR': false,
    'hasMoovAtFront': true,
    'hasRotationTransform': false,
    'hasEmbeddedMetadata': false,
  };

  group('VanguardMediaPreparer.inspectMedia', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      '1. Android content:// URI bypasses Dart File preflight and invokes native',
      () async {
        String? capturedMethod;
        dynamic capturedArgs;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              capturedMethod = call.method;
              capturedArgs = call.arguments;
              return dummyNativeResponse;
            });

        const contentUri = 'content://media/external/video/media/287';
        final info = await VanguardMediaPreparer.inspectMedia(contentUri);

        expect(capturedMethod, equals('inspectMedia'));
        expect((capturedArgs as Map?)!['path'], equals(contentUri));
        expect(info, isNotNull);
        expect(info!.kind, equals(MediaKind.video));
        expect(info.hasVideo, isTrue);
        expect(info.displayWidth, equals(1080));
        expect(info.displayHeight, equals(1920));
        expect(info.durationSeconds, equals(12.5));
      },
    );

    test(
      '2. Missing POSIX file returns null without invoking native channel',
      () async {
        bool channelCalled = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              channelCalled = true;
              return dummyNativeResponse;
            });

        final result = await VanguardMediaPreparer.inspectMedia(
          '/tmp/non_existent_file_${DateTime.now().microsecondsSinceEpoch}.mp4',
        );

        expect(result, isNull);
        expect(channelCalled, isFalse);
      },
    );

    test(
      '3. Zero-length POSIX file returns null without invoking native channel',
      () async {
        bool channelCalled = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              channelCalled = true;
              return dummyNativeResponse;
            });

        final emptyFile = File(
          '${Directory.systemTemp.path}/vg_empty_${DateTime.now().microsecondsSinceEpoch}.mp4',
        );
        await emptyFile.create();
        try {
          final result = await VanguardMediaPreparer.inspectMedia(
            emptyFile.path,
          );
          expect(result, isNull);
          expect(channelCalled, isFalse);
        } finally {
          await emptyFile.delete();
        }
      },
    );

    test(
      '4. Non-empty POSIX file passes preflight and invokes native channel',
      () async {
        String? capturedMethod;
        dynamic capturedArgs;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              capturedMethod = call.method;
              capturedArgs = call.arguments;
              return dummyNativeResponse;
            });

        final validFile = File(
          '${Directory.systemTemp.path}/vg_valid_${DateTime.now().microsecondsSinceEpoch}.mp4',
        );
        await validFile.writeAsBytes([0x00, 0x00, 0x00, 0x18]);
        try {
          final info = await VanguardMediaPreparer.inspectMedia(validFile.path);
          expect(capturedMethod, equals('inspectMedia'));
          expect((capturedArgs as Map?)!['path'], equals(validFile.path));
          expect(info, isNotNull);
          expect(info!.durationSeconds, equals(12.5));
        } finally {
          await validFile.delete();
        }
      },
    );

    test(
      '5. Remote HTTP/HTTPS URLs return null without invoking native channel',
      () async {
        bool channelCalled = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              channelCalled = true;
              return dummyNativeResponse;
            });

        final httpResult = await VanguardMediaPreparer.inspectMedia(
          'http://example.com/video.mp4',
        );
        expect(httpResult, isNull);

        final httpsResult = await VanguardMediaPreparer.inspectMedia(
          'https://example.com/video.mp4',
        );
        expect(httpsResult, isNull);

        expect(channelCalled, isFalse);
      },
    );

    test('6. Null native response returns null to Dart', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);

      const contentUri = 'content://media/external/video/media/999';
      final info = await VanguardMediaPreparer.inspectMedia(contentUri);
      expect(info, isNull);
    });

    test(
      '7. PlatformException from native is caught and returns null',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              throw PlatformException(
                code: 'INSPECT_FAILED',
                message: 'test error',
              );
            });

        const contentUri = 'content://media/external/video/media/999';
        final info = await VanguardMediaPreparer.inspectMedia(contentUri);
        expect(info, isNull);
      },
    );
  });
}
