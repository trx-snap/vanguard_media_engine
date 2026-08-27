// vg_camera_hardware_capability_report_test.dart
// vanguard_media_engine — Phase 3-Unit B: Android Camera2 stream configuration,
// sensor output inspector, and hardware/thermal capability probe Dart model &
// MethodChannel contract tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const defaultChannel = MethodChannel('vanguard_media_engine');
  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 1. VGCameraSize Helper Tests
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCameraSize', () {
    test('fromMap parses valid size and converts toMap', () {
      final map = <Object?, Object?>{'width': 1920, 'height': 1080};
      final size = VGCameraSize.fromMap(map);
      expect(size, isNotNull);
      expect(size!.width, equals(1920));
      expect(size.height, equals(1080));

      final roundTrip = size.toMap();
      expect(
        roundTrip,
        equals(<String, Object?>{'width': 1920, 'height': 1080}),
      );
      expect(VGCameraSize.fromMap(roundTrip), equals(size));
    });

    test('fromMap returns null on non-map or missing/null fields', () {
      expect(VGCameraSize.fromMap(null), isNull);
      expect(VGCameraSize.fromMap('not_a_map'), isNull);
      expect(VGCameraSize.fromMap(123), isNull);
      expect(VGCameraSize.fromMap(<Object?, Object?>{'width': 1920}), isNull);
      expect(VGCameraSize.fromMap(<Object?, Object?>{'height': 1080}), isNull);
      expect(
        VGCameraSize.fromMap(<Object?, Object?>{'width': null, 'height': 1080}),
        isNull,
      );
      expect(
        VGCameraSize.fromMap(<Object?, Object?>{'width': 1920, 'height': null}),
        isNull,
      );
    });

    test('equality, hashCode, and toString verify value semantics', () {
      const a = VGCameraSize(1920, 1080);
      const b = VGCameraSize(1920, 1080);
      const diffW = VGCameraSize(1280, 1080);
      const diffH = VGCameraSize(1920, 720);

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(diffW)));
      expect(a, isNot(equals(diffH)));
      expect(a.toString(), equals('VGCameraSize(width: 1920, height: 1080)'));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. VGCameraRect Helper Tests
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCameraRect', () {
    test('fromMap parses valid rect and converts toMap', () {
      final map = <Object?, Object?>{
        'left': 0,
        'top': 0,
        'right': 4000,
        'bottom': 3000,
      };
      final rect = VGCameraRect.fromMap(map);
      expect(rect, isNotNull);
      expect(rect!.left, equals(0));
      expect(rect.top, equals(0));
      expect(rect.right, equals(4000));
      expect(rect.bottom, equals(3000));

      final roundTrip = rect.toMap();
      expect(
        roundTrip,
        equals(<String, Object?>{
          'left': 0,
          'top': 0,
          'right': 4000,
          'bottom': 3000,
        }),
      );
      expect(VGCameraRect.fromMap(roundTrip), equals(rect));
    });

    test('fromMap returns null on non-map or missing/null fields', () {
      expect(VGCameraRect.fromMap(null), isNull);
      expect(VGCameraRect.fromMap('not_a_map'), isNull);
      expect(VGCameraRect.fromMap(456), isNull);
      expect(
        VGCameraRect.fromMap(<Object?, Object?>{
          'left': 0,
          'top': 0,
          'right': 4000,
        }),
        isNull,
      );
      expect(
        VGCameraRect.fromMap(<Object?, Object?>{
          'left': null,
          'top': 0,
          'right': 4000,
          'bottom': 3000,
        }),
        isNull,
      );
    });

    test('equality, hashCode, and toString verify value semantics', () {
      const a = VGCameraRect(0, 0, 4000, 3000);
      const b = VGCameraRect(0, 0, 4000, 3000);
      const diffLeft = VGCameraRect(10, 0, 4000, 3000);
      const diffTop = VGCameraRect(0, 10, 4000, 3000);
      const diffRight = VGCameraRect(0, 0, 3840, 3000);
      const diffBottom = VGCameraRect(0, 0, 4000, 2160);

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(diffLeft)));
      expect(a, isNot(equals(diffTop)));
      expect(a, isNot(equals(diffRight)));
      expect(a, isNot(equals(diffBottom)));
      expect(
        a.toString(),
        equals('VGCameraRect(left: 0, top: 0, right: 4000, bottom: 3000)'),
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. VGCameraFpsRange Helper Tests
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCameraFpsRange', () {
    test('fromMap parses valid fps range and converts toMap', () {
      final map = <Object?, Object?>{'lower': 15, 'upper': 30};
      final range = VGCameraFpsRange.fromMap(map);
      expect(range, isNotNull);
      expect(range!.lower, equals(15));
      expect(range.upper, equals(30));

      final roundTrip = range.toMap();
      expect(roundTrip, equals(<String, Object?>{'lower': 15, 'upper': 30}));
      expect(VGCameraFpsRange.fromMap(roundTrip), equals(range));
    });

    test('fromMap returns null on non-map or missing/null fields', () {
      expect(VGCameraFpsRange.fromMap(null), isNull);
      expect(VGCameraFpsRange.fromMap('not_a_map'), isNull);
      expect(VGCameraFpsRange.fromMap(789), isNull);
      expect(VGCameraFpsRange.fromMap(<Object?, Object?>{'lower': 15}), isNull);
      expect(VGCameraFpsRange.fromMap(<Object?, Object?>{'upper': 30}), isNull);
      expect(
        VGCameraFpsRange.fromMap(<Object?, Object?>{
          'lower': null,
          'upper': 30,
        }),
        isNull,
      );
      expect(
        VGCameraFpsRange.fromMap(<Object?, Object?>{
          'lower': 15,
          'upper': null,
        }),
        isNull,
      );
    });

    test('equality, hashCode, and toString verify value semantics', () {
      const a = VGCameraFpsRange(15, 30);
      const b = VGCameraFpsRange(15, 30);
      const diffLower = VGCameraFpsRange(10, 30);
      const diffUpper = VGCameraFpsRange(15, 60);

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(diffLower)));
      expect(a, isNot(equals(diffUpper)));
      expect(a.toString(), equals('VGCameraFpsRange(lower: 15, upper: 30)'));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. VGCameraHardwareDeviceCapability Unit Tests
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCameraHardwareDeviceCapability', () {
    test(
      'fromMap parses valid camera device capability and converts toMap',
      () {
        final map = <Object?, Object?>{
          'cameraId': '0',
          'lensFacing': 'back',
          'sensorOrientation': 90,
          'hardwareLevel': 'full',
          'isLogicalMultiCamera': true,
          'physicalCameraIds': <Object?>['2', '3'],
          'capabilities': <Object?>[
            'BACKWARD_COMPATIBLE',
            'LOGICAL_MULTI_CAMERA',
          ],
          'previewSizes': <Object?>[
            <Object?, Object?>{'width': 1920, 'height': 1080},
            <Object?, Object?>{'width': 1280, 'height': 720},
          ],
          'videoSizes': <Object?>[
            <Object?, Object?>{'width': 3840, 'height': 2160},
            <Object?, Object?>{'width': 1920, 'height': 1080},
          ],
          'jpegSizes': <Object?>[
            <Object?, Object?>{'width': 4000, 'height': 3000},
          ],
          'yuv420Sizes': <Object?>[
            <Object?, Object?>{'width': 1920, 'height': 1080},
          ],
          'fpsRanges': <Object?>[
            <Object?, Object?>{'lower': 15, 'upper': 30},
            <Object?, Object?>{'lower': 30, 'upper': 30},
          ],
          'flashAvailable': true,
          'videoStabilizationModes': <Object?>['off', 'on'],
          'opticalStabilizationModes': <Object?>['off', 'on'],
          'sensorActiveArraySize': <Object?, Object?>{
            'left': 0,
            'top': 0,
            'right': 4000,
            'bottom': 3000,
          },
          'sensorPixelArraySize': <Object?, Object?>{
            'width': 4032,
            'height': 3024,
          },
        };

        final capability = VGCameraHardwareDeviceCapability.fromMap(map);
        expect(capability, isNotNull);
        expect(capability!.cameraId, equals('0'));
        expect(capability.lensFacing, equals('back'));
        expect(capability.sensorOrientation, equals(90));
        expect(capability.hardwareLevel, equals('full'));
        expect(capability.isLogicalMultiCamera, isTrue);
        expect(capability.physicalCameraIds, equals(['2', '3']));
        expect(
          capability.capabilities,
          equals(['BACKWARD_COMPATIBLE', 'LOGICAL_MULTI_CAMERA']),
        );
        expect(
          capability.previewSizes,
          equals([
            const VGCameraSize(1920, 1080),
            const VGCameraSize(1280, 720),
          ]),
        );
        expect(
          capability.videoSizes,
          equals([
            const VGCameraSize(3840, 2160),
            const VGCameraSize(1920, 1080),
          ]),
        );
        expect(capability.jpegSizes, equals([const VGCameraSize(4000, 3000)]));
        expect(
          capability.yuv420Sizes,
          equals([const VGCameraSize(1920, 1080)]),
        );
        expect(
          capability.fpsRanges,
          equals([
            const VGCameraFpsRange(15, 30),
            const VGCameraFpsRange(30, 30),
          ]),
        );
        expect(capability.flashAvailable, isTrue);
        expect(capability.videoStabilizationModes, equals(['off', 'on']));
        expect(capability.opticalStabilizationModes, equals(['off', 'on']));
        expect(
          capability.sensorActiveArraySize,
          equals(const VGCameraRect(0, 0, 4000, 3000)),
        );
        expect(
          capability.sensorPixelArraySize,
          equals(const VGCameraSize(4032, 3024)),
        );

        final roundTripMap = capability.toMap();
        expect(roundTripMap['cameraId'], equals('0'));
        expect(roundTripMap['lensFacing'], equals('back'));
        expect(roundTripMap['sensorOrientation'], equals(90));
        expect(roundTripMap['hardwareLevel'], equals('full'));
        expect(roundTripMap['isLogicalMultiCamera'], isTrue);
        expect(roundTripMap['physicalCameraIds'], equals(['2', '3']));
        expect(
          roundTripMap['capabilities'],
          equals(['BACKWARD_COMPATIBLE', 'LOGICAL_MULTI_CAMERA']),
        );
        expect(
          roundTripMap['previewSizes'],
          equals([
            {'width': 1920, 'height': 1080},
            {'width': 1280, 'height': 720},
          ]),
        );
        expect(
          roundTripMap['videoSizes'],
          equals([
            {'width': 3840, 'height': 2160},
            {'width': 1920, 'height': 1080},
          ]),
        );
        expect(
          roundTripMap['jpegSizes'],
          equals([
            {'width': 4000, 'height': 3000},
          ]),
        );
        expect(
          roundTripMap['yuv420Sizes'],
          equals([
            {'width': 1920, 'height': 1080},
          ]),
        );
        expect(
          roundTripMap['fpsRanges'],
          equals([
            {'lower': 15, 'upper': 30},
            {'lower': 30, 'upper': 30},
          ]),
        );
        expect(roundTripMap['flashAvailable'], isTrue);
        expect(roundTripMap['videoStabilizationModes'], equals(['off', 'on']));
        expect(
          roundTripMap['opticalStabilizationModes'],
          equals(['off', 'on']),
        );
        expect(
          roundTripMap['sensorActiveArraySize'],
          equals({'left': 0, 'top': 0, 'right': 4000, 'bottom': 3000}),
        );
        expect(
          roundTripMap['sensorPixelArraySize'],
          equals({'width': 4032, 'height': 3024}),
        );

        final fromRoundTrip = VGCameraHardwareDeviceCapability.fromMap(
          roundTripMap,
        );
        expect(fromRoundTrip, equals(capability));
        expect(fromRoundTrip.hashCode, equals(capability.hashCode));
        expect(capability.toString(), contains('cameraId: 0'));
        expect(
          capability.toString(),
          contains('previewSizes: [VGCameraSize(width: 1920, height: 1080)'),
        );
        expect(capability.toString(), contains('flashAvailable: true'));
      },
    );

    test('fromMap returns null on non-map input', () {
      expect(VGCameraHardwareDeviceCapability.fromMap(null), isNull);
      expect(VGCameraHardwareDeviceCapability.fromMap('not_a_map'), isNull);
      expect(VGCameraHardwareDeviceCapability.fromMap(42), isNull);
      expect(
        VGCameraHardwareDeviceCapability.fromMap(const <Object?>[]),
        isNull,
      );
    });

    test('fromMap returns null when cameraId is missing or empty', () {
      expect(
        VGCameraHardwareDeviceCapability.fromMap(<Object?, Object?>{
          'lensFacing': 'back',
        }),
        isNull,
      );
      expect(
        VGCameraHardwareDeviceCapability.fromMap(<Object?, Object?>{
          'cameraId': null,
          'lensFacing': 'back',
        }),
        isNull,
      );
      expect(
        VGCameraHardwareDeviceCapability.fromMap(<Object?, Object?>{
          'cameraId': '',
          'lensFacing': 'back',
        }),
        isNull,
      );
    });

    test('fromMap defaults optional and malformed fields gracefully', () {
      final map = <Object?, Object?>{
        'cameraId': '1',
        'lensFacing': null,
        'sensorOrientation': null,
        'hardwareLevel': null,
        'isLogicalMultiCamera': null,
        'physicalCameraIds': 'not_a_list',
        'capabilities': null,
        'previewSizes': 'not_a_list',
        'videoSizes': null,
        'jpegSizes': 'not_a_list',
        'yuv420Sizes': null,
        'fpsRanges': 'not_a_list',
        'flashAvailable': null,
        'videoStabilizationModes': 'not_a_list',
        'opticalStabilizationModes': null,
        'sensorActiveArraySize': 'not_a_map',
        'sensorPixelArraySize': null,
      };

      final capability = VGCameraHardwareDeviceCapability.fromMap(map);
      expect(capability, isNotNull);
      expect(capability!.cameraId, equals('1'));
      expect(capability.lensFacing, equals('unknown'));
      expect(capability.sensorOrientation, isNull);
      expect(capability.hardwareLevel, equals('unknown'));
      expect(capability.isLogicalMultiCamera, isFalse);
      expect(capability.physicalCameraIds, isEmpty);
      expect(capability.capabilities, isEmpty);
      expect(capability.previewSizes, isEmpty);
      expect(capability.videoSizes, isEmpty);
      expect(capability.jpegSizes, isEmpty);
      expect(capability.yuv420Sizes, isEmpty);
      expect(capability.fpsRanges, isEmpty);
      expect(capability.flashAvailable, isFalse);
      expect(capability.videoStabilizationModes, isEmpty);
      expect(capability.opticalStabilizationModes, isEmpty);
      expect(capability.sensorActiveArraySize, isNull);
      expect(capability.sensorPixelArraySize, isNull);
    });

    test(
      'fromMap stringifies non-string items in physicalCameraIds and capabilities',
      () {
        final map = <Object?, Object?>{
          'cameraId': '0',
          'physicalCameraIds': <Object?>[2, 3],
          'capabilities': <Object?>[10, true],
        };

        final capability = VGCameraHardwareDeviceCapability.fromMap(map);
        expect(capability, isNotNull);
        expect(capability!.physicalCameraIds, equals(['2', '3']));
        expect(capability.capabilities, equals(['10', 'true']));
      },
    );

    test('fromMap filters out invalid entries in size and fps range lists', () {
      final map = <Object?, Object?>{
        'cameraId': '0',
        'previewSizes': <Object?>[
          null,
          'invalid',
          <Object?, Object?>{'width': 1920, 'height': 1080},
          <Object?, Object?>{'width': null, 'height': 720},
        ],
        'fpsRanges': <Object?>[
          null,
          'invalid',
          <Object?, Object?>{'lower': 30, 'upper': 30},
          <Object?, Object?>{'lower': 15, 'upper': null},
        ],
      };

      final capability = VGCameraHardwareDeviceCapability.fromMap(map);
      expect(capability, isNotNull);
      expect(
        capability!.previewSizes,
        equals([const VGCameraSize(1920, 1080)]),
      );
      expect(capability.fpsRanges, equals([const VGCameraFpsRange(30, 30)]));
    });

    test('equality and hashCode verify value semantics', () {
      const a = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
        previewSizes: [VGCameraSize(1920, 1080)],
        videoSizes: [VGCameraSize(1920, 1080)],
        jpegSizes: [VGCameraSize(4000, 3000)],
        yuv420Sizes: [VGCameraSize(1920, 1080)],
        fpsRanges: [VGCameraFpsRange(15, 30)],
        flashAvailable: true,
        videoStabilizationModes: ['off', 'on'],
        opticalStabilizationModes: ['off'],
        sensorActiveArraySize: VGCameraRect(0, 0, 4000, 3000),
        sensorPixelArraySize: VGCameraSize(4032, 3024),
      );
      const b = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
        previewSizes: [VGCameraSize(1920, 1080)],
        videoSizes: [VGCameraSize(1920, 1080)],
        jpegSizes: [VGCameraSize(4000, 3000)],
        yuv420Sizes: [VGCameraSize(1920, 1080)],
        fpsRanges: [VGCameraFpsRange(15, 30)],
        flashAvailable: true,
        videoStabilizationModes: ['off', 'on'],
        opticalStabilizationModes: ['off'],
        sensorActiveArraySize: VGCameraRect(0, 0, 4000, 3000),
        sensorPixelArraySize: VGCameraSize(4032, 3024),
      );
      const diffId = VGCameraHardwareDeviceCapability(
        cameraId: '1',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
      );
      const diffOrientation = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 270,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
      );
      const diffFacing = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'front',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
      );
      const diffHwLevel = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'limited',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
      );
      const diffLogical = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: false,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
      );
      const diffPhysicalIds = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '4'],
        capabilities: ['BACKWARD_COMPATIBLE'],
      );
      const diffCapabilities = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['RAW'],
      );
      const diffPreviewSizes = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
        previewSizes: [VGCameraSize(1280, 720)],
      );
      const diffVideoSizes = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
        videoSizes: [VGCameraSize(1280, 720)],
      );
      const diffJpegSizes = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
        jpegSizes: [VGCameraSize(1280, 720)],
      );
      const diffYuv420Sizes = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
        yuv420Sizes: [VGCameraSize(1280, 720)],
      );
      const diffFpsRanges = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
        fpsRanges: [VGCameraFpsRange(30, 60)],
      );
      const diffFlash = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
        flashAvailable: false,
      );
      const diffVideoStab = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
        videoStabilizationModes: ['off'],
      );
      const diffOpticalStab = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
        opticalStabilizationModes: ['on'],
      );
      const diffActiveArray = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
        sensorActiveArraySize: VGCameraRect(10, 10, 4000, 3000),
      );
      const diffPixelArray = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
        sensorPixelArraySize: VGCameraSize(1920, 1080),
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(diffId)));
      expect(a, isNot(equals(diffOrientation)));
      expect(a, isNot(equals(diffFacing)));
      expect(a, isNot(equals(diffHwLevel)));
      expect(a, isNot(equals(diffLogical)));
      expect(a, isNot(equals(diffPhysicalIds)));
      expect(a, isNot(equals(diffCapabilities)));
      expect(a, isNot(equals(diffPreviewSizes)));
      expect(a, isNot(equals(diffVideoSizes)));
      expect(a, isNot(equals(diffJpegSizes)));
      expect(a, isNot(equals(diffYuv420Sizes)));
      expect(a, isNot(equals(diffFpsRanges)));
      expect(a, isNot(equals(diffFlash)));
      expect(a, isNot(equals(diffVideoStab)));
      expect(a, isNot(equals(diffOpticalStab)));
      expect(a, isNot(equals(diffActiveArray)));
      expect(a, isNot(equals(diffPixelArray)));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 5. VGCameraHardwareCapabilityReport Unit Tests
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCameraHardwareCapabilityReport', () {
    test('fromMap parses valid full capability report and converts toMap', () {
      final rawMap = <Object?, Object?>{
        'success': true,
        'apiLevel': 34,
        'hasCameraPermission': false,
        'thermalStatus': 0,
        'thermalStatusName': 'none',
        'cameraCount': 2,
        'supportsConcurrentCamera': true,
        'concurrentCameraIdSets': <Object?>[
          <Object?>['0', '1'],
        ],
        'cameras': <Object?>[
          <Object?, Object?>{
            'cameraId': '0',
            'lensFacing': 'back',
            'sensorOrientation': 90,
            'hardwareLevel': 'full',
            'isLogicalMultiCamera': false,
            'physicalCameraIds': <Object?>[],
            'capabilities': <Object?>['BACKWARD_COMPATIBLE'],
          },
          <Object?, Object?>{
            'cameraId': '1',
            'lensFacing': 'front',
            'sensorOrientation': 270,
            'hardwareLevel': 'limited',
            'isLogicalMultiCamera': false,
            'physicalCameraIds': <Object?>[],
            'capabilities': <Object?>['BACKWARD_COMPATIBLE'],
          },
        ],
        'fallbackRecommendation': 'concurrent_supported',
      };

      final report = VGCameraHardwareCapabilityReport.fromMap(rawMap);
      expect(report.success, isTrue);
      expect(report.apiLevel, equals(34));
      expect(report.hasCameraPermission, isFalse);
      expect(report.thermalStatus, equals(0));
      expect(report.thermalStatusName, equals('none'));
      expect(report.cameraCount, equals(2));
      expect(report.supportsConcurrentCamera, isTrue);
      expect(
        report.concurrentCameraIdSets,
        equals([
          ['0', '1'],
        ]),
      );
      expect(report.cameras.length, equals(2));
      expect(report.cameras[0].cameraId, equals('0'));
      expect(report.cameras[1].cameraId, equals('1'));
      expect(report.fallbackRecommendation, equals('concurrent_supported'));

      final roundTripMap = report.toMap();
      expect(roundTripMap['success'], isTrue);
      expect(roundTripMap['apiLevel'], equals(34));
      expect(roundTripMap['hasCameraPermission'], isFalse);
      expect(roundTripMap['thermalStatus'], equals(0));
      expect(roundTripMap['thermalStatusName'], equals('none'));
      expect(roundTripMap['cameraCount'], equals(2));
      expect(roundTripMap['supportsConcurrentCamera'], isTrue);
      expect(
        roundTripMap['concurrentCameraIdSets'],
        equals([
          ['0', '1'],
        ]),
      );
      expect((roundTripMap['cameras'] as List).length, equals(2));
      expect(
        roundTripMap['fallbackRecommendation'],
        equals('concurrent_supported'),
      );

      final fromRoundTrip = VGCameraHardwareCapabilityReport.fromMap(
        roundTripMap,
      );
      expect(fromRoundTrip, equals(report));
      expect(fromRoundTrip.hashCode, equals(report.hashCode));
      expect(report.toString(), contains('apiLevel: 34'));
    });

    test(
      'fromMap parses nested stream config and sensor fields through cameras list',
      () {
        final rawMap = <Object?, Object?>{
          'success': true,
          'apiLevel': 34,
          'hasCameraPermission': false,
          'thermalStatus': 0,
          'thermalStatusName': 'none',
          'cameraCount': 1,
          'supportsConcurrentCamera': false,
          'concurrentCameraIdSets': <Object?>[],
          'cameras': <Object?>[
            <Object?, Object?>{
              'cameraId': '0',
              'lensFacing': 'back',
              'sensorOrientation': 90,
              'hardwareLevel': 'full',
              'isLogicalMultiCamera': false,
              'physicalCameraIds': <Object?>[],
              'capabilities': <Object?>['BACKWARD_COMPATIBLE'],
              'previewSizes': <Object?>[
                <Object?, Object?>{'width': 1920, 'height': 1080},
              ],
              'videoSizes': <Object?>[
                <Object?, Object?>{'width': 1920, 'height': 1080},
              ],
              'jpegSizes': <Object?>[
                <Object?, Object?>{'width': 4000, 'height': 3000},
              ],
              'yuv420Sizes': <Object?>[
                <Object?, Object?>{'width': 1920, 'height': 1080},
              ],
              'fpsRanges': <Object?>[
                <Object?, Object?>{'lower': 15, 'upper': 30},
                <Object?, Object?>{'lower': 30, 'upper': 30},
              ],
              'flashAvailable': true,
              'videoStabilizationModes': <Object?>['off', 'on'],
              'opticalStabilizationModes': <Object?>['off', 'on'],
              'sensorActiveArraySize': <Object?, Object?>{
                'left': 0,
                'top': 0,
                'right': 4000,
                'bottom': 3000,
              },
              'sensorPixelArraySize': <Object?, Object?>{
                'width': 4032,
                'height': 3024,
              },
            },
          ],
          'fallbackRecommendation': 'single_camera_only',
        };

        final report = VGCameraHardwareCapabilityReport.fromMap(rawMap);
        expect(report.cameras.length, equals(1));
        final cam = report.cameras.first;
        expect(cam.previewSizes, equals([const VGCameraSize(1920, 1080)]));
        expect(cam.videoSizes, equals([const VGCameraSize(1920, 1080)]));
        expect(cam.jpegSizes, equals([const VGCameraSize(4000, 3000)]));
        expect(cam.yuv420Sizes, equals([const VGCameraSize(1920, 1080)]));
        expect(
          cam.fpsRanges,
          equals([
            const VGCameraFpsRange(15, 30),
            const VGCameraFpsRange(30, 30),
          ]),
        );
        expect(cam.flashAvailable, isTrue);
        expect(cam.videoStabilizationModes, equals(['off', 'on']));
        expect(cam.opticalStabilizationModes, equals(['off', 'on']));
        expect(
          cam.sensorActiveArraySize,
          equals(const VGCameraRect(0, 0, 4000, 3000)),
        );
        expect(
          cam.sensorPixelArraySize,
          equals(const VGCameraSize(4032, 3024)),
        );

        final roundTrip = VGCameraHardwareCapabilityReport.fromMap(
          report.toMap(),
        );
        expect(roundTrip, equals(report));
        expect(roundTrip.hashCode, equals(report.hashCode));
      },
    );

    test('fromMap parses defensively when input is empty or non-map', () {
      final report = VGCameraHardwareCapabilityReport.fromMap(null);
      expect(report.success, isFalse);
      expect(report.apiLevel, equals(0));
      expect(report.hasCameraPermission, isFalse);
      expect(report.thermalStatus, isNull);
      expect(report.thermalStatusName, equals('unavailable'));
      expect(report.cameraCount, equals(0));
      expect(report.supportsConcurrentCamera, isFalse);
      expect(report.concurrentCameraIdSets, isEmpty);
      expect(report.cameras, isEmpty);
      expect(report.fallbackRecommendation, equals('no_camera'));
    });

    test('fromMap defaults cameraCount to cameras.length when omitted', () {
      final rawMap = <Object?, Object?>{
        'success': true,
        'cameras': <Object?>[
          <Object?, Object?>{
            'cameraId': '0',
            'lensFacing': 'back',
            'hardwareLevel': 'full',
          },
        ],
      };

      final report = VGCameraHardwareCapabilityReport.fromMap(rawMap);
      expect(report.cameraCount, equals(1));
      expect(report.cameras.length, equals(1));
    });

    test('fromMap drops invalid camera entries while keeping valid ones', () {
      final rawMap = <Object?, Object?>{
        'success': true,
        'cameras': <Object?>[
          null,
          'invalid_camera_type',
          <Object?, Object?>{'cameraId': null},
          <Object?, Object?>{'cameraId': ''},
          <Object?, Object?>{
            'cameraId': 'valid_0',
            'lensFacing': 'back',
            'hardwareLevel': 'full',
          },
          <Object?, Object?>{
            'cameraId': 'valid_1',
            'lensFacing': 'front',
            'hardwareLevel': 'limited',
          },
        ],
      };

      final report = VGCameraHardwareCapabilityReport.fromMap(rawMap);
      expect(report.cameras.length, equals(2));
      expect(report.cameras[0].cameraId, equals('valid_0'));
      expect(report.cameras[1].cameraId, equals('valid_1'));
    });

    test('fromMap parses nested concurrentCameraIdSets defensively', () {
      final rawMap = <Object?, Object?>{
        'concurrentCameraIdSets': <Object?>[
          <Object?>['0', '1'],
          'not_a_list',
          <Object?>[2, 3],
        ],
      };

      final report = VGCameraHardwareCapabilityReport.fromMap(rawMap);
      expect(report.concurrentCameraIdSets.length, equals(3));
      expect(report.concurrentCameraIdSets[0], equals(['0', '1']));
      expect(report.concurrentCameraIdSets[1], isEmpty);
      expect(report.concurrentCameraIdSets[2], equals(['2', '3']));
    });

    test('equality and hashCode verify report comparison semantics', () {
      const a = VGCameraHardwareCapabilityReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: false,
        thermalStatus: 0,
        thermalStatusName: 'none',
        cameraCount: 1,
        supportsConcurrentCamera: false,
        concurrentCameraIdSets: [],
        cameras: [
          VGCameraHardwareDeviceCapability(
            cameraId: '0',
            lensFacing: 'back',
            sensorOrientation: 90,
            hardwareLevel: 'full',
            isLogicalMultiCamera: false,
            physicalCameraIds: [],
            capabilities: ['BACKWARD_COMPATIBLE'],
          ),
        ],
        fallbackRecommendation: 'single_camera_only',
      );

      const b = VGCameraHardwareCapabilityReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: false,
        thermalStatus: 0,
        thermalStatusName: 'none',
        cameraCount: 1,
        supportsConcurrentCamera: false,
        concurrentCameraIdSets: [],
        cameras: [
          VGCameraHardwareDeviceCapability(
            cameraId: '0',
            lensFacing: 'back',
            sensorOrientation: 90,
            hardwareLevel: 'full',
            isLogicalMultiCamera: false,
            physicalCameraIds: [],
            capabilities: ['BACKWARD_COMPATIBLE'],
          ),
        ],
        fallbackRecommendation: 'single_camera_only',
      );

      const diffConcurrent = VGCameraHardwareCapabilityReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: false,
        thermalStatus: 0,
        thermalStatusName: 'none',
        cameraCount: 1,
        supportsConcurrentCamera: true,
        concurrentCameraIdSets: [
          ['0', '1'],
        ],
        cameras: [
          VGCameraHardwareDeviceCapability(
            cameraId: '0',
            lensFacing: 'back',
            sensorOrientation: 90,
            hardwareLevel: 'full',
            isLogicalMultiCamera: false,
            physicalCameraIds: [],
            capabilities: ['BACKWARD_COMPATIBLE'],
          ),
        ],
        fallbackRecommendation: 'concurrent_supported',
      );

      const diffRecommendation = VGCameraHardwareCapabilityReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: false,
        thermalStatus: 0,
        thermalStatusName: 'none',
        cameraCount: 1,
        supportsConcurrentCamera: false,
        concurrentCameraIdSets: [],
        cameras: [
          VGCameraHardwareDeviceCapability(
            cameraId: '0',
            lensFacing: 'back',
            sensorOrientation: 90,
            hardwareLevel: 'full',
            isLogicalMultiCamera: false,
            physicalCameraIds: [],
            capabilities: ['BACKWARD_COMPATIBLE'],
          ),
        ],
        fallbackRecommendation: 'thermal_blocked',
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(diffConcurrent)));
      expect(a, isNot(equals(diffRecommendation)));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 6. MethodChannel Contract Tests
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities', () {
    test(
      'invokes runAndroidDagPhase3UnitACameraCapabilityProbe on injected channel and parses response',
      () async {
        const customChannel = MethodChannel('test_vanguard_media_engine');
        MethodCall? recordedCall;

        binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
          recordedCall = call;
          if (call.method == 'runAndroidDagPhase3UnitACameraCapabilityProbe') {
            return <Object?, Object?>{
              'success': true,
              'apiLevel': 34,
              'hasCameraPermission': false,
              'thermalStatus': 0,
              'thermalStatusName': 'none',
              'cameraCount': 2,
              'supportsConcurrentCamera': true,
              'concurrentCameraIdSets': <Object?>[
                <Object?>['0', '1'],
              ],
              'cameras': <Object?>[
                <Object?, Object?>{
                  'cameraId': '0',
                  'lensFacing': 'back',
                  'sensorOrientation': 90,
                  'hardwareLevel': 'full',
                  'isLogicalMultiCamera': false,
                  'physicalCameraIds': <Object?>[],
                  'capabilities': <Object?>['BACKWARD_COMPATIBLE'],
                },
                <Object?, Object?>{
                  'cameraId': '1',
                  'lensFacing': 'front',
                  'sensorOrientation': 270,
                  'hardwareLevel': 'limited',
                  'isLogicalMultiCamera': false,
                  'physicalCameraIds': <Object?>[],
                  'capabilities': <Object?>['BACKWARD_COMPATIBLE'],
                },
              ],
              'fallbackRecommendation': 'concurrent_supported',
            };
          }
          return null;
        });

        final report =
            await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities(
              channel: customChannel,
            );

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('runAndroidDagPhase3UnitACameraCapabilityProbe'),
        );
        expect(recordedCall!.arguments, isNull);

        expect(report.success, isTrue);
        expect(report.apiLevel, equals(34));
        expect(report.hasCameraPermission, isFalse);
        expect(report.thermalStatus, equals(0));
        expect(report.thermalStatusName, equals('none'));
        expect(report.cameraCount, equals(2));
        expect(report.supportsConcurrentCamera, isTrue);
        expect(
          report.concurrentCameraIdSets,
          equals([
            ['0', '1'],
          ]),
        );
        expect(report.cameras.length, equals(2));
        expect(report.fallbackRecommendation, equals('concurrent_supported'));

        binaryMessenger.setMockMethodCallHandler(customChannel, null);
      },
    );

    test('invokes default channel when channel parameter is omitted', () async {
      MethodCall? recordedCall;

      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        recordedCall = call;
        if (call.method == 'runAndroidDagPhase3UnitACameraCapabilityProbe') {
          return <Object?, Object?>{
            'success': true,
            'apiLevel': 33,
            'hasCameraPermission': false,
            'thermalStatusName': 'unavailable',
            'cameraCount': 1,
            'supportsConcurrentCamera': false,
            'concurrentCameraIdSets': <Object?>[],
            'cameras': <Object?>[
              <Object?, Object?>{
                'cameraId': '0',
                'lensFacing': 'back',
                'hardwareLevel': 'full',
              },
            ],
            'fallbackRecommendation': 'single_camera_only',
          };
        }
        return null;
      });

      final report =
          await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities();

      expect(recordedCall, isNotNull);
      expect(
        recordedCall!.method,
        equals('runAndroidDagPhase3UnitACameraCapabilityProbe'),
      );
      expect(report.success, isTrue);
      expect(report.apiLevel, equals(33));
      expect(report.cameraCount, equals(1));
    });
  });
}
