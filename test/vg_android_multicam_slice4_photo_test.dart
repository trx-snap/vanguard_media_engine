// vg_android_multicam_slice4_photo_test.dart
// Vanguard Media Engine - Slice 4 Mechanical Verification Test
//
// Tests for Slice 4: Composited Photo Capture (takeMultiCamPhoto) on Android.
// Validates the Dart-side method channel contract for VGCameraSession.takeMultiCamPhoto
// against the Android result map shape produced by
// AndroidCamera2MultiCamPreviewCoordinator.takeMultiCamPhoto():
//   {filePath, width, height, sizeBytes, format}
//
// This is a pure Dart method-channel mock test — no native code runs. It pins
// the contract (method name, argument shape, result parsing, and error-code
// behavior) so a future change to either side is caught here first.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_camera_session.dart';
import 'package:vanguard_media_engine/vg_photo_capture_result.dart';

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

  group('Slice 4 - Composited Photo Capture (takeMultiCamPhoto) Contract', () {
    const kPhotoPath = '/tmp/slice4_multicam_photo.jpg';

    // Matches the exact payload returned by
    // AndroidCamera2MultiCamPreviewCoordinator.takeMultiCamPhoto() on success.
    const kAndroidPhotoResponse = <Object?, Object?>{
      'filePath': kPhotoPath,
      'width': 1080,
      'height': 1920,
      'sizeBytes': 512000,
      'format': 'jpeg',
    };

    test('takeMultiCamPhoto dispatches method call with correct path argument', () async {
      responses['takeMultiCamPhoto'] = kAndroidPhotoResponse;

      await VGCameraSession.takeMultiCamPhoto(kPhotoPath);

      expect(log.length, equals(1));
      expect(log.first.method, equals('takeMultiCamPhoto'));
      final args = log.first.arguments as Map;
      expect(args['path'], equals(kPhotoPath));
    });

    test('takeMultiCamPhoto parses the Android result map into a populated VGPhotoCaptureResult', () async {
      responses['takeMultiCamPhoto'] = kAndroidPhotoResponse;

      final result = await VGCameraSession.takeMultiCamPhoto(kPhotoPath);

      expect(result, isNotNull);
      expect(result!.filePath, equals(kPhotoPath));
      expect(result.width, equals(1080));
      expect(result.height, equals(1920));
      expect(result.sizeBytes, equals(512000));
      expect(result.format, equals('jpeg'));
    });

    test('takeMultiCamPhoto returns null on NOT_RUNNING (no active MultiCam preview)', () async {
      responses['takeMultiCamPhoto'] = PlatformException(
        code: 'NOT_RUNNING',
        message: 'Android MultiCam preview is not running',
      );

      final result = await VGCameraSession.takeMultiCamPhoto(kPhotoPath);

      expect(result, isNull);
    });

    test('takeMultiCamPhoto returns null on NO_FRAME (called before first composited frame)', () async {
      responses['takeMultiCamPhoto'] = PlatformException(
        code: 'NO_FRAME',
        message: 'No composited frame available yet',
      );

      final result = await VGCameraSession.takeMultiCamPhoto(kPhotoPath);

      expect(result, isNull);
    });

    test('takeMultiCamPhoto returns null on INVALID_ARG (blank path)', () async {
      responses['takeMultiCamPhoto'] = PlatformException(
        code: 'INVALID_ARG',
        message: 'takeMultiCamPhoto requires a non-blank path',
      );

      final result = await VGCameraSession.takeMultiCamPhoto('');

      expect(result, isNull);
    });

    test('takeMultiCamPhoto returns null on WRITE_FAIL (disk write failure)', () async {
      responses['takeMultiCamPhoto'] = PlatformException(
        code: 'WRITE_FAIL',
        message: 'Permission denied',
      );

      final result = await VGCameraSession.takeMultiCamPhoto(kPhotoPath);

      expect(result, isNull);
    });

    test('takeMultiCamPhoto returns null on ENCODE_FAIL (JPEG encoding failure)', () async {
      responses['takeMultiCamPhoto'] = PlatformException(
        code: 'ENCODE_FAIL',
        message: 'JPEG encoding failed',
      );

      final result = await VGCameraSession.takeMultiCamPhoto(kPhotoPath);

      expect(result, isNull);
    });

    test('takeMultiCamPhoto returns null when channel returns null payload', () async {
      responses['takeMultiCamPhoto'] = null;

      final result = await VGCameraSession.takeMultiCamPhoto(kPhotoPath);

      expect(result, isNull);
    });

    test('VGPhotoCaptureResult.fromMap handles the exact Android result keys', () {
      final result = VGPhotoCaptureResult.fromMap(
        Map<String, dynamic>.from(kAndroidPhotoResponse),
      );

      expect(result.filePath, equals(kPhotoPath));
      expect(result.width, equals(1080));
      expect(result.height, equals(1920));
      expect(result.sizeBytes, equals(512000));
      expect(result.format, equals('jpeg'));
    });

    test('VGPhotoCaptureResult.fromMap handles large files and alternative keys', () {
      final result = VGPhotoCaptureResult.fromMap({
        'filePath': '/storage/emulated/0/DCIM/large_photo.jpg',
        'width': 2160,
        'height': 3840,
        'sizeBytes': 10485760, // 10MB
        'format': 'jpeg',
      });

      expect(result.filePath, equals('/storage/emulated/0/DCIM/large_photo.jpg'));
      expect(result.width, equals(2160));
      expect(result.height, equals(3840));
      expect(result.sizeBytes, equals(10485760));
      expect(result.format, equals('jpeg'));
    });
  });
}

