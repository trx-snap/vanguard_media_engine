// vg_android_multicam_capability_routes_smoke_test.dart
// vanguard_media_engine - P3-CAM-CONCURRENT-ANDROID-MULTICAM-CAPABILITY-WIRING:
// Android static MultiCam capability routes unit and smoke contract tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // 1. Constants and Proof Boundary Tokens
  // ---------------------------------------------------------------------------
  group('Android static MultiCam capability routes constants and markers', () {
    test('proof boundary has exact required string value', () {
      expect(
        kAndroidMultiCamCapabilityRoutesProofBoundary,
        equals(
          'android_multicam_capability_static_routes_read_only_probe_consistency_no_camera_open_no_preview_no_capture',
        ),
      );
    });

    test('start marker has exact required token', () {
      expect(
        kAndroidMultiCamCapabilityRoutesStartMarker,
        equals(
          'ANDROID_DAG_PHASE3_MULTICAM_CAPABILITY_ROUTES_PHYSICAL_SMOKE_START',
        ),
      );
    });

    test('pass marker has exact required token', () {
      expect(
        kAndroidMultiCamCapabilityRoutesPassMarker,
        equals(
          'ANDROID_DAG_PHASE3_MULTICAM_CAPABILITY_ROUTES_PHYSICAL_SMOKE_PASS',
        ),
      );
    });

    test('fail marker has exact required token', () {
      expect(
        kAndroidMultiCamCapabilityRoutesFailMarker,
        equals(
          'ANDROID_DAG_PHASE3_MULTICAM_CAPABILITY_ROUTES_PHYSICAL_SMOKE_FAIL',
        ),
      );
    });

    test('JSON prefix has exact required token', () {
      expect(
        kAndroidMultiCamCapabilityRoutesJsonPrefix,
        equals('ANDROID_DAG_PHASE3_MULTICAM_CAPABILITY_ROUTES_JSON:'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 2. Report Serialization & Deserialization (toMap / fromMap)
  // ---------------------------------------------------------------------------
  group('VGAndroidMultiCamCapabilityRoutesSmokeReport toMap and fromMap', () {
    test('toMap and fromMap roundtrip preserves all fields', () {
      const report = VGAndroidMultiCamCapabilityRoutesSmokeReport(
        pass: true,
        proofBoundary: kAndroidMultiCamCapabilityRoutesProofBoundary,
        staticSupported: true,
        probeSupported: true,
        deviceSetCount: 1,
        probeConcurrentSetCount: 1,
        unsupportedFailClosed: true,
        staticSupportedMatchesProbe: true,
        deviceSetCountMatchesProbe: true,
        deviceMapShapeOk: true,
        reasons: <String>['multicam_routes_supported_probe_consistent_pass'],
        diagnostics: <String, Object?>{
          'proofBoundary': kAndroidMultiCamCapabilityRoutesProofBoundary,
          'isPhysicalDualCamera': true,
          'deviceSetCount': 1,
        },
      );

      final map = report.toMap();
      expect(map['pass'], isTrue);
      expect(
        map['proofBoundary'],
        equals(kAndroidMultiCamCapabilityRoutesProofBoundary),
      );
      expect(map['staticSupported'], isTrue);
      expect(map['probeSupported'], isTrue);
      expect(map['deviceSetCount'], equals(1));
      expect(map['probeConcurrentSetCount'], equals(1));
      expect(map['unsupportedFailClosed'], isTrue);
      expect(map['staticSupportedMatchesProbe'], isTrue);
      expect(map['deviceSetCountMatchesProbe'], isTrue);
      expect(map['deviceMapShapeOk'], isTrue);
      expect(map['reasons'], isA<List<String>>());
      expect(map['diagnostics'], isA<Map<String, Object?>>());

      final roundtripped = VGAndroidMultiCamCapabilityRoutesSmokeReport.fromMap(
        map,
      );
      expect(roundtripped, isNotNull);
      expect(roundtripped, equals(report));
      expect(roundtripped!.hashCode, equals(report.hashCode));
      expect(roundtripped.pass, isTrue);
      expect(roundtripped.diagnostics['isPhysicalDualCamera'], isTrue);
    });

    test('fromMap returns null on non-map input', () {
      expect(
        VGAndroidMultiCamCapabilityRoutesSmokeReport.fromMap(null),
        isNull,
      );
      expect(
        VGAndroidMultiCamCapabilityRoutesSmokeReport.fromMap('not_a_map'),
        isNull,
      );
      expect(VGAndroidMultiCamCapabilityRoutesSmokeReport.fromMap(123), isNull);
    });

    test('toString includes key report fields', () {
      const report = VGAndroidMultiCamCapabilityRoutesSmokeReport(
        pass: true,
        proofBoundary: kAndroidMultiCamCapabilityRoutesProofBoundary,
        staticSupported: false,
        probeSupported: false,
        deviceSetCount: 0,
        probeConcurrentSetCount: 0,
        unsupportedFailClosed: true,
        staticSupportedMatchesProbe: true,
        deviceSetCountMatchesProbe: true,
        deviceMapShapeOk: true,
        reasons: <String>['multicam_routes_unsupported_probe_consistent_pass'],
        diagnostics: <String, Object?>{'isPhysicalDualCamera': false},
      );

      final str = report.toString();
      expect(str, contains('pass: true'));
      expect(str, contains(kAndroidMultiCamCapabilityRoutesProofBoundary));
      expect(str, contains('staticSupported: false'));
      expect(str, contains('probeSupported: false'));
    });
  });

  // ---------------------------------------------------------------------------
  // 3. Unsupported Hardware PASS Shape (e.g. SM-A566B)
  // ---------------------------------------------------------------------------
  group('Unsupported device PASS verification (SM-A566B profile)', () {
    test(
      'Unsupported device: probeSupported=false, staticSupported=false, empty device sets -> PASS',
      () async {
        final hardwareReport = VGCameraHardwareCapabilityReport.fromMap(
          const <String, Object?>{
            'success': true,
            'apiLevel': 34,
            'hasCameraPermission': false,
            'cameraCount': 2,
            'supportsConcurrentCamera': false,
            'concurrentCameraIdSets': <List<String>>[],
            'cameras': <Map<String, Object?>>[
              {'cameraId': '0', 'lensFacing': 'back'},
              {'cameraId': '1', 'lensFacing': 'front'},
            ],
            'fallbackRecommendation': 'single_camera_only',
          },
        );

        final runner = VGAndroidMultiCamCapabilityRoutesSmokeRunner(
          probeHardwareReport: ({MethodChannel? channel}) async =>
              hardwareReport,
          isMultiCamSupported: ({MethodChannel? channel}) async => false,
          getMultiCamDeviceSets: ({MethodChannel? channel}) async =>
              const <List<Map<String, Object?>>>[],
        );

        final report = await runner.runSmoke();

        expect(report.pass, isTrue);
        expect(
          report.proofBoundary,
          equals(kAndroidMultiCamCapabilityRoutesProofBoundary),
        );
        expect(report.staticSupported, isFalse);
        expect(report.probeSupported, isFalse);
        expect(report.deviceSetCount, equals(0));
        expect(report.probeConcurrentSetCount, equals(0));
        expect(report.unsupportedFailClosed, isTrue);
        expect(report.staticSupportedMatchesProbe, isTrue);
        expect(report.deviceSetCountMatchesProbe, isTrue);
        expect(report.deviceMapShapeOk, isTrue);
        expect(report.diagnostics['isPhysicalDualCamera'], isFalse);
        expect(
          report.reasons,
          contains('multicam_routes_unsupported_probe_consistent_pass'),
        );
      },
    );

    test(
      'Unsupported device with single-element ID sets (< 2) -> PASS',
      () async {
        final hardwareReport = VGCameraHardwareCapabilityReport.fromMap(
          const <String, Object?>{
            'success': true,
            'apiLevel': 34,
            'hasCameraPermission': false,
            'cameraCount': 1,
            'supportsConcurrentCamera': false,
            'concurrentCameraIdSets': <List<String>>[
              ['0'],
            ],
            'cameras': <Map<String, Object?>>[
              {'cameraId': '0', 'lensFacing': 'back'},
            ],
            'fallbackRecommendation': 'single_camera_only',
          },
        );

        final runner = VGAndroidMultiCamCapabilityRoutesSmokeRunner(
          probeHardwareReport: ({MethodChannel? channel}) async =>
              hardwareReport,
          isMultiCamSupported: ({MethodChannel? channel}) async => false,
          getMultiCamDeviceSets: ({MethodChannel? channel}) async =>
              const <List<Map<String, Object?>>>[],
        );

        final report = await runner.runSmoke();

        expect(report.pass, isTrue);
        expect(report.probeConcurrentSetCount, equals(0));
        expect(report.deviceSetCount, equals(0));
        expect(report.unsupportedFailClosed, isTrue);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 4. Real Supported Hardware PASS Shape (e.g. Pixel 8 / Pixel 9)
  // ---------------------------------------------------------------------------
  group('Real supported hardware PASS verification', () {
    test(
      'Supported hardware: probeSupported=true, staticSupported=true, matching device sets -> PASS',
      () async {
        final hardwareReport = VGCameraHardwareCapabilityReport.fromMap(
          const <String, Object?>{
            'success': true,
            'apiLevel': 34,
            'hasCameraPermission': false,
            'cameraCount': 2,
            'supportsConcurrentCamera': true,
            'concurrentCameraIdSets': <List<String>>[
              ['0', '1'],
            ],
            'cameras': <Map<String, Object?>>[
              {'cameraId': '0', 'lensFacing': 'back'},
              {'cameraId': '1', 'lensFacing': 'front'},
            ],
            'fallbackRecommendation': 'concurrent_supported',
          },
        );

        final returnedDeviceSets = <List<Map<String, Object?>>>[
          <Map<String, Object?>>[
            <String, Object?>{
              'uniqueId': '0',
              'localizedName': 'Back Camera 0',
              'position': 'back',
              'deviceType': 'camera2',
            },
            <String, Object?>{
              'uniqueId': '1',
              'localizedName': 'Front Camera 1',
              'position': 'front',
              'deviceType': 'camera2',
            },
          ],
        ];

        final runner = VGAndroidMultiCamCapabilityRoutesSmokeRunner(
          probeHardwareReport: ({MethodChannel? channel}) async =>
              hardwareReport,
          isMultiCamSupported: ({MethodChannel? channel}) async => true,
          getMultiCamDeviceSets: ({MethodChannel? channel}) async =>
              returnedDeviceSets,
        );

        final report = await runner.runSmoke();

        expect(report.pass, isTrue);
        expect(
          report.proofBoundary,
          equals(kAndroidMultiCamCapabilityRoutesProofBoundary),
        );
        expect(report.staticSupported, isTrue);
        expect(report.probeSupported, isTrue);
        expect(report.deviceSetCount, equals(1));
        expect(report.probeConcurrentSetCount, equals(1));
        expect(report.unsupportedFailClosed, isTrue);
        expect(report.staticSupportedMatchesProbe, isTrue);
        expect(report.deviceSetCountMatchesProbe, isTrue);
        expect(report.deviceMapShapeOk, isTrue);
        expect(report.diagnostics['isPhysicalDualCamera'], isTrue);
        expect(
          report.reasons,
          contains('multicam_routes_supported_probe_consistent_pass'),
        );
      },
    );

    test('Supported hardware with 2 concurrent combos -> PASS', () async {
      final hardwareReport = VGCameraHardwareCapabilityReport.fromMap(
        const <String, Object?>{
          'success': true,
          'apiLevel': 34,
          'hasCameraPermission': false,
          'cameraCount': 3,
          'supportsConcurrentCamera': true,
          'concurrentCameraIdSets': <List<String>>[
            ['0', '1'],
            ['0', '2'],
          ],
          'cameras': <Map<String, Object?>>[
            {'cameraId': '0', 'lensFacing': 'back'},
            {'cameraId': '1', 'lensFacing': 'front'},
            {'cameraId': '2', 'lensFacing': 'back'},
          ],
          'fallbackRecommendation': 'concurrent_supported',
        },
      );

      final returnedDeviceSets = <List<Map<String, Object?>>>[
        <Map<String, Object?>>[
          <String, Object?>{
            'uniqueId': '0',
            'localizedName': 'Back Camera 0',
            'position': 'back',
            'deviceType': 'camera2',
          },
          <String, Object?>{
            'uniqueId': '1',
            'localizedName': 'Front Camera 1',
            'position': 'front',
            'deviceType': 'camera2',
          },
        ],
        <Map<String, Object?>>[
          <String, Object?>{
            'uniqueId': '0',
            'localizedName': 'Back Camera 0',
            'position': 'back',
            'deviceType': 'camera2',
          },
          <String, Object?>{
            'uniqueId': '2',
            'localizedName': 'Back Camera 2',
            'position': 'back',
            'deviceType': 'logicalMultiCamera',
          },
        ],
      ];

      final report = await VGAndroidMultiCamCapabilityRoutesSmokeRunner.run(
        runner: VGAndroidMultiCamCapabilityRoutesSmokeRunner(
          probeHardwareReport: ({MethodChannel? channel}) async =>
              hardwareReport,
          isMultiCamSupported: ({MethodChannel? channel}) async => true,
          getMultiCamDeviceSets: ({MethodChannel? channel}) async =>
              returnedDeviceSets,
        ),
      );

      expect(report.pass, isTrue);
      expect(report.deviceSetCount, equals(2));
      expect(report.probeConcurrentSetCount, equals(2));
      expect(report.deviceSetCountMatchesProbe, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // 5. Mismatched Supported FAIL Shapes
  // ---------------------------------------------------------------------------
  group('Mismatched supported FAIL verification', () {
    test(
      'Probe unsupported but static route returns supported=true -> FAIL',
      () async {
        final hardwareReport =
            VGCameraHardwareCapabilityReport.fromMap(const <String, Object?>{
              'success': true,
              'apiLevel': 34,
              'hasCameraPermission': false,
              'cameraCount': 2,
              'supportsConcurrentCamera': false,
              'concurrentCameraIdSets': <List<String>>[],
              'fallbackRecommendation': 'single_camera_only',
            });

        final runner = VGAndroidMultiCamCapabilityRoutesSmokeRunner(
          probeHardwareReport: ({MethodChannel? channel}) async =>
              hardwareReport,
          isMultiCamSupported: ({MethodChannel? channel}) async =>
              true, // MISMATCH
          getMultiCamDeviceSets: ({MethodChannel? channel}) async =>
              const <List<Map<String, Object?>>>[],
        );

        final report = await runner.runSmoke();

        expect(report.pass, isFalse);
        expect(report.staticSupportedMatchesProbe, isFalse);
        expect(report.unsupportedFailClosed, isFalse);
        expect(report.reasons, contains('static_supported_mismatches_probe'));
        expect(
          report.reasons,
          contains('unsupported_hardware_not_fail_closed'),
        );
      },
    );

    test(
      'Probe supported=true but static route returns supported=false -> FAIL',
      () async {
        final hardwareReport = VGCameraHardwareCapabilityReport.fromMap(
          const <String, Object?>{
            'success': true,
            'apiLevel': 34,
            'hasCameraPermission': false,
            'cameraCount': 2,
            'supportsConcurrentCamera': true,
            'concurrentCameraIdSets': <List<String>>[
              ['0', '1'],
            ],
            'fallbackRecommendation': 'concurrent_supported',
          },
        );

        final runner = VGAndroidMultiCamCapabilityRoutesSmokeRunner(
          probeHardwareReport: ({MethodChannel? channel}) async =>
              hardwareReport,
          isMultiCamSupported: ({MethodChannel? channel}) async =>
              false, // MISMATCH
          getMultiCamDeviceSets: ({MethodChannel? channel}) async =>
              const <List<Map<String, Object?>>>[],
        );

        final report = await runner.runSmoke();

        expect(report.pass, isFalse);
        expect(report.staticSupportedMatchesProbe, isFalse);
        expect(report.reasons, contains('static_supported_mismatches_probe'));
      },
    );

    test(
      'Probe concurrent sets count does not match returned device set count -> FAIL',
      () async {
        final hardwareReport = VGCameraHardwareCapabilityReport.fromMap(
          const <String, Object?>{
            'success': true,
            'apiLevel': 34,
            'hasCameraPermission': false,
            'cameraCount': 2,
            'supportsConcurrentCamera': true,
            'concurrentCameraIdSets': <List<String>>[
              ['0', '1'],
            ],
            'fallbackRecommendation': 'concurrent_supported',
          },
        );

        final runner = VGAndroidMultiCamCapabilityRoutesSmokeRunner(
          probeHardwareReport: ({MethodChannel? channel}) async =>
              hardwareReport,
          isMultiCamSupported: ({MethodChannel? channel}) async => true,
          getMultiCamDeviceSets: ({MethodChannel? channel}) async =>
              const <List<Map<String, Object?>>>[], // MISMATCH: 0 vs 1
        );

        final report = await runner.runSmoke();

        expect(report.pass, isFalse);
        expect(report.deviceSetCountMatchesProbe, isFalse);
        expect(report.reasons, contains('device_set_count_mismatches_probe'));
      },
    );

    test('Unsupported device returns non-empty device sets -> FAIL', () async {
      final hardwareReport =
          VGCameraHardwareCapabilityReport.fromMap(const <String, Object?>{
            'success': true,
            'apiLevel': 34,
            'hasCameraPermission': false,
            'cameraCount': 2,
            'supportsConcurrentCamera': false,
            'concurrentCameraIdSets': <List<String>>[],
            'fallbackRecommendation': 'single_camera_only',
          });

      final runner = VGAndroidMultiCamCapabilityRoutesSmokeRunner(
        probeHardwareReport: ({MethodChannel? channel}) async => hardwareReport,
        isMultiCamSupported: ({MethodChannel? channel}) async => false,
        getMultiCamDeviceSets: ({MethodChannel? channel}) async =>
            <List<Map<String, Object?>>>[
              <Map<String, Object?>>[
                <String, Object?>{
                  'uniqueId': '0',
                  'localizedName': 'Back Camera 0',
                  'position': 'back',
                  'deviceType': 'camera2',
                },
                <String, Object?>{
                  'uniqueId': '1',
                  'localizedName': 'Front Camera 1',
                  'position': 'front',
                  'deviceType': 'camera2',
                },
              ],
            ], // ILLEGAL: 1 set on unsupported hardware
      );

      final report = await runner.runSmoke();

      expect(report.pass, isFalse);
      expect(report.unsupportedFailClosed, isFalse);
      expect(report.deviceSetCountMatchesProbe, isFalse);
      expect(report.reasons, contains('unsupported_hardware_not_fail_closed'));
    });
  });

  // ---------------------------------------------------------------------------
  // 6. Malformed Device-Map FAIL Shapes
  // ---------------------------------------------------------------------------
  group('Malformed device-map FAIL verification', () {
    final supportedReport = VGCameraHardwareCapabilityReport.fromMap(
      const <String, Object?>{
        'success': true,
        'apiLevel': 34,
        'hasCameraPermission': false,
        'cameraCount': 2,
        'supportsConcurrentCamera': true,
        'concurrentCameraIdSets': <List<String>>[
          ['0', '1'],
        ],
        'fallbackRecommendation': 'concurrent_supported',
      },
    );

    test('Descriptor with empty uniqueId -> FAIL', () async {
      final runner = VGAndroidMultiCamCapabilityRoutesSmokeRunner(
        probeHardwareReport: ({MethodChannel? channel}) async =>
            supportedReport,
        isMultiCamSupported: ({MethodChannel? channel}) async => true,
        getMultiCamDeviceSets: ({MethodChannel? channel}) async => [
          [
            {
              'uniqueId': '', // EMPTY
              'localizedName': 'Back Camera 0',
              'position': 'back',
              'deviceType': 'camera2',
            },
            {
              'uniqueId': '1',
              'localizedName': 'Front Camera 1',
              'position': 'front',
              'deviceType': 'camera2',
            },
          ],
        ],
      );

      final report = await runner.runSmoke();
      expect(report.pass, isFalse);
      expect(report.deviceMapShapeOk, isFalse);
      expect(report.reasons, contains('malformed_device_descriptor_shape'));
    });

    test('Descriptor missing localizedName -> FAIL', () async {
      final runner = VGAndroidMultiCamCapabilityRoutesSmokeRunner(
        probeHardwareReport: ({MethodChannel? channel}) async =>
            supportedReport,
        isMultiCamSupported: ({MethodChannel? channel}) async => true,
        getMultiCamDeviceSets: ({MethodChannel? channel}) async => [
          [
            {
              'uniqueId': '0',
              // missing localizedName
              'position': 'back',
              'deviceType': 'camera2',
            },
            {
              'uniqueId': '1',
              'localizedName': 'Front Camera 1',
              'position': 'front',
              'deviceType': 'camera2',
            },
          ],
        ],
      );

      final report = await runner.runSmoke();
      expect(report.pass, isFalse);
      expect(report.deviceMapShapeOk, isFalse);
      expect(report.reasons, contains('malformed_device_descriptor_shape'));
    });

    test('Descriptor with non-string position -> FAIL', () async {
      final runner = VGAndroidMultiCamCapabilityRoutesSmokeRunner(
        probeHardwareReport: ({MethodChannel? channel}) async =>
            supportedReport,
        isMultiCamSupported: ({MethodChannel? channel}) async => true,
        getMultiCamDeviceSets: ({MethodChannel? channel}) async => [
          [
            {
              'uniqueId': '0',
              'localizedName': 'Back Camera 0',
              'position': 42, // Non-string
              'deviceType': 'camera2',
            },
            {
              'uniqueId': '1',
              'localizedName': 'Front Camera 1',
              'position': 'front',
              'deviceType': 'camera2',
            },
          ],
        ],
      );

      final report = await runner.runSmoke();
      expect(report.pass, isFalse);
      expect(report.deviceMapShapeOk, isFalse);
      expect(report.reasons, contains('malformed_device_descriptor_shape'));
    });

    test('Descriptor with empty deviceType -> FAIL', () async {
      final runner = VGAndroidMultiCamCapabilityRoutesSmokeRunner(
        probeHardwareReport: ({MethodChannel? channel}) async =>
            supportedReport,
        isMultiCamSupported: ({MethodChannel? channel}) async => true,
        getMultiCamDeviceSets: ({MethodChannel? channel}) async => [
          [
            {
              'uniqueId': '0',
              'localizedName': 'Back Camera 0',
              'position': 'back',
              'deviceType': '', // EMPTY
            },
            {
              'uniqueId': '1',
              'localizedName': 'Front Camera 1',
              'position': 'front',
              'deviceType': 'camera2',
            },
          ],
        ],
      );

      final report = await runner.runSmoke();
      expect(report.pass, isFalse);
      expect(report.deviceMapShapeOk, isFalse);
      expect(report.reasons, contains('malformed_device_descriptor_shape'));
    });

    test('Device set with fewer than 2 descriptors -> FAIL', () async {
      final runner = VGAndroidMultiCamCapabilityRoutesSmokeRunner(
        probeHardwareReport: ({MethodChannel? channel}) async =>
            supportedReport,
        isMultiCamSupported: ({MethodChannel? channel}) async => true,
        getMultiCamDeviceSets: ({MethodChannel? channel}) async => [
          [
            {
              'uniqueId': '0',
              'localizedName': 'Back Camera 0',
              'position': 'back',
              'deviceType': 'camera2',
            },
          ],
        ],
      );

      final report = await runner.runSmoke();
      expect(report.pass, isFalse);
      expect(report.reasons, contains('device_set_member_count_lt_2'));
    });
  });

  // ---------------------------------------------------------------------------
  // 7. Static MethodChannel Dispatch using Mocks
  // ---------------------------------------------------------------------------
  group('Static MethodChannel dispatch using mock channel', () {
    const channel = MethodChannel('vanguard_media_engine');
    final log = <MethodCall>[];
    final responses = <String, Object?>{};

    setUp(() {
      log.clear();
      responses.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            log.add(call);
            if (responses.containsKey(call.method)) {
              final res = responses[call.method];
              if (res is Exception) throw res;
              return res;
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'Executes all 3 static queries and passes for unsupported hardware',
      () async {
        responses['runAndroidDagPhase3UnitACameraCapabilityProbe'] = {
          'success': true,
          'apiLevel': 34,
          'hasCameraPermission': false,
          'cameraCount': 2,
          'supportsConcurrentCamera': false,
          'concurrentCameraIdSets': <List<String>>[],
          'cameras': [
            {'cameraId': '0', 'lensFacing': 'back'},
            {'cameraId': '1', 'lensFacing': 'front'},
          ],
          'fallbackRecommendation': 'single_camera_only',
        };
        responses['isMultiCamSupported'] = false;
        responses['getMultiCamDeviceSets'] = <Object?>[];

        final report = await VGAndroidMultiCamCapabilityRoutesSmokeRunner.run();

        expect(report.pass, isTrue);
        expect(report.staticSupported, isFalse);
        expect(report.probeSupported, isFalse);
        expect(report.deviceSetCount, equals(0));
        expect(report.diagnostics['isPhysicalDualCamera'], isFalse);

        final calledMethods = log.map((c) => c.method).toList();
        expect(
          calledMethods,
          contains('runAndroidDagPhase3UnitACameraCapabilityProbe'),
        );
        expect(calledMethods, contains('isMultiCamSupported'));
        expect(calledMethods, contains('getMultiCamDeviceSets'));
      },
    );

    test(
      'Executes all 3 static queries and passes for supported hardware',
      () async {
        responses['runAndroidDagPhase3UnitACameraCapabilityProbe'] = {
          'success': true,
          'apiLevel': 34,
          'hasCameraPermission': false,
          'cameraCount': 2,
          'supportsConcurrentCamera': true,
          'concurrentCameraIdSets': [
            ['0', '1'],
          ],
          'cameras': [
            {'cameraId': '0', 'lensFacing': 'back'},
            {'cameraId': '1', 'lensFacing': 'front'},
          ],
          'fallbackRecommendation': 'concurrent_supported',
        };
        responses['isMultiCamSupported'] = true;
        responses['getMultiCamDeviceSets'] = [
          [
            {
              'uniqueId': '0',
              'localizedName': 'Back Camera 0',
              'position': 'back',
              'deviceType': 'camera2',
            },
            {
              'uniqueId': '1',
              'localizedName': 'Front Camera 1',
              'position': 'front',
              'deviceType': 'camera2',
            },
          ],
        ];

        final report = await VGAndroidMultiCamCapabilityRoutesSmokeRunner.run();

        expect(report.pass, isTrue);
        expect(report.staticSupported, isTrue);
        expect(report.probeSupported, isTrue);
        expect(report.deviceSetCount, equals(1));
        expect(report.diagnostics['isPhysicalDualCamera'], isTrue);
      },
    );

    test('PlatformException on static routes fails closed gracefully', () async {
      responses['runAndroidDagPhase3UnitACameraCapabilityProbe'] = {
        'success': true,
        'apiLevel': 34,
        'hasCameraPermission': false,
        'cameraCount': 2,
        'supportsConcurrentCamera': false,
        'concurrentCameraIdSets': <List<String>>[],
        'fallbackRecommendation': 'single_camera_only',
      };
      responses['isMultiCamSupported'] = PlatformException(
        code: 'UNAVAILABLE',
        message: 'Native method failed',
      );
      responses['getMultiCamDeviceSets'] = PlatformException(
        code: 'UNAVAILABLE',
        message: 'Native method failed',
      );

      final report = await VGAndroidMultiCamCapabilityRoutesSmokeRunner.run();

      // Because probe is unsupported and static routes fail closed (false and empty list),
      // consistency holds and report passes.
      expect(report.pass, isTrue);
      expect(report.staticSupported, isFalse);
      expect(report.deviceSetCount, equals(0));
      expect(report.unsupportedFailClosed, isTrue);
    });

    test('Probe exception fails closed with pass=false', () async {
      responses['runAndroidDagPhase3UnitACameraCapabilityProbe'] =
          PlatformException(
            code: 'PROBE_FAILED',
            message: 'Camera service error',
          );

      final report = await VGAndroidMultiCamCapabilityRoutesSmokeRunner.run();

      expect(report.pass, isFalse);
      expect(report.diagnostics['isPhysicalDualCamera'], isFalse);
      expect(
        report.reasons.any((r) => r.startsWith('exception_during_smoke_run')),
        isTrue,
      );
    });
  });
}
