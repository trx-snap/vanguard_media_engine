// vg_photo_library_save_test.dart
// vanguard_media_engine — UMF V2 Slice 2A
//
// Unit tests for VanguardEngine.saveVideoToPhotoLibrary Dart bridge.
//
// Coverage:
//   PL-1: saveVideoToPhotoLibrary sends method name 'saveVideoToPhotoLibrary'.
//   PL-2: filePath argument is correctly passed in the arguments map.
//   PL-3: native returning true resolves to true.
//   PL-4: native returning false or null resolves to false.
//   PL-5: PlatformException propagates unchanged.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  const channel = MethodChannel('vanguard_media_engine');
  late List<MethodCall> capturedCalls;

  setUp(() {
    capturedCalls = [];
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void setHandler(Future<dynamic> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          capturedCalls.add(call);
          return handler(call);
        });
  }

  test(
    'PL-1 & PL-2: passes filePath to method saveVideoToPhotoLibrary',
    () async {
      setHandler((call) async {
        if (call.method == 'saveVideoToPhotoLibrary') {
          return true;
        }
        return null;
      });

      const testPath = '/tmp/rendered_test_video.mp4';
      final result = await VanguardEngine.saveVideoToPhotoLibrary(
        testPath,
        channel: channel,
      );

      expect(result, isTrue);
      expect(capturedCalls.length, equals(1));
      expect(capturedCalls.first.method, equals('saveVideoToPhotoLibrary'));
      expect(
        capturedCalls.first.arguments,
        equals(<String, dynamic>{'filePath': testPath}),
      );
    },
  );

  test('PL-3: returns true when native succeeds', () async {
    setHandler((call) async => true);

    final result = await VanguardEngine.saveVideoToPhotoLibrary(
      '/tmp/video.mov',
      channel: channel,
    );
    expect(result, isTrue);
  });

  test('PL-4: returns false when native returns null or false', () async {
    setHandler((call) async => false);

    final resultFalse = await VanguardEngine.saveVideoToPhotoLibrary(
      '/tmp/video.mp4',
      channel: channel,
    );
    expect(resultFalse, isFalse);

    setHandler((call) async => null);

    final resultNull = await VanguardEngine.saveVideoToPhotoLibrary(
      '/tmp/video.mp4',
      channel: channel,
    );
    expect(resultNull, isFalse);
  });

  test('PL-5: rethrows PlatformException on native error', () async {
    setHandler((call) async {
      throw PlatformException(
        code: 'permission_denied',
        message: 'Photo library permission was denied.',
      );
    });

    expect(
      () => VanguardEngine.saveVideoToPhotoLibrary(
        '/tmp/video.mp4',
        channel: channel,
      ),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'permission_denied',
        ),
      ),
    );
  });
}
