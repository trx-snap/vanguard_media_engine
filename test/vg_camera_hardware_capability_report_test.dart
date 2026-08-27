// vg_camera_hardware_capability_report_test.dart
// vanguard_media_engine — Phase 3-Unit A: Android Camera2 hardware/thermal
// capability probe report Dart model & MethodChannel contract tests.

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
  // 1. VGCameraHardwareDeviceCapability Unit Tests
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

        final fromRoundTrip = VGCameraHardwareDeviceCapability.fromMap(
          roundTripMap,
        );
        expect(fromRoundTrip, equals(capability));
        expect(fromRoundTrip.hashCode, equals(capability.hashCode));
        expect(capability.toString(), contains('cameraId: 0'));
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

    test('equality and hashCode verify value semantics', () {
      const a = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
      );
      const b = VGCameraHardwareDeviceCapability(
        cameraId: '0',
        lensFacing: 'back',
        sensorOrientation: 90,
        hardwareLevel: 'full',
        isLogicalMultiCamera: true,
        physicalCameraIds: ['2', '3'],
        capabilities: ['BACKWARD_COMPATIBLE'],
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

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(diffId)));
      expect(a, isNot(equals(diffOrientation)));
      expect(a, isNot(equals(diffFacing)));
      expect(a, isNot(equals(diffHwLevel)));
      expect(a, isNot(equals(diffLogical)));
      expect(a, isNot(equals(diffPhysicalIds)));
      expect(a, isNot(equals(diffCapabilities)));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. VGCameraHardwareCapabilityReport Unit Tests
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
  // 3. MethodChannel Contract Tests
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
