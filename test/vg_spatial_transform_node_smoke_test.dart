// vg_spatial_transform_node_smoke_test.dart
// vanguard_media_engine -- P5-SPATIAL-TRANSFORM-NODE-A
// Unit tests for VGSpatialTransformNodeSmokeReport and VGSpatialTransformNodeSmokeRunner.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_spatial_transform_node_smoke.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Constants', () {
    test('canonical method channel name matches native declaration', () {
      expect(
        kSpatialTransformNodeMethodName,
        'runAndroidDagPhase5SpatialTransformNodeSmoke',
      );
      expect(
        VGSpatialTransformNodeSmokeReport.methodName,
        'runAndroidDagPhase5SpatialTransformNodeSmoke',
      );
    });

    test('canonical proof boundary constant matches expected boundary', () {
      const expected =
          'platform_neutral_spatial_transform_node_logical_dag_transform_'
          'no_render_ownership_no_texture_ownership_no_gpu_lifecycle_'
          'no_product_app_editor_wiring';
      expect(kSpatialTransformNodeProofBoundary, expected);
      expect(VGSpatialTransformNodeSmokeReport.requiredProofBoundary, expected);
    });

    test('physical smoke markers match required protocol strings', () {
      expect(
        kSpatialTransformNodeStartMarker,
        'ANDROID_DAG_PHASE5_SPATIAL_TRANSFORM_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        VGSpatialTransformNodeSmokeReport.startMarker,
        'ANDROID_DAG_PHASE5_SPATIAL_TRANSFORM_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        kSpatialTransformNodePassMarker,
        'ANDROID_DAG_PHASE5_SPATIAL_TRANSFORM_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        VGSpatialTransformNodeSmokeReport.passMarker,
        'ANDROID_DAG_PHASE5_SPATIAL_TRANSFORM_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        kSpatialTransformNodeFailMarker,
        'ANDROID_DAG_PHASE5_SPATIAL_TRANSFORM_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        VGSpatialTransformNodeSmokeReport.failMarker,
        'ANDROID_DAG_PHASE5_SPATIAL_TRANSFORM_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        kSpatialTransformNodeJsonPrefix,
        'ANDROID_DAG_PHASE5_SPATIAL_TRANSFORM_NODE_JSON:',
      );
      expect(
        VGSpatialTransformNodeSmokeReport.jsonPrefix,
        'ANDROID_DAG_PHASE5_SPATIAL_TRANSFORM_NODE_JSON:',
      );
    });

    test('lane count constants match 16', () {
      expect(kSpatialTransformNodeExpectedTotalLanes, 16);
      expect(kSpatialTransformNodeExpectedPassedLanes, 16);
      expect(VGSpatialTransformNodeSmokeReport.expectedTotalLanes, 16);
      expect(VGSpatialTransformNodeSmokeReport.expectedPassedLanes, 16);
    });

    test('required boundary tokens contains all 7 mandatory tokens', () {
      expect(
        VGSpatialTransformNodeSmokeReport.requiredBoundaryTokens,
        containsAll(<String>[
          'platform_neutral',
          'spatial_transform_node',
          'logical_dag_transform',
          'no_render_ownership',
          'no_texture_ownership',
          'no_gpu_lifecycle',
          'no_product_app_editor_wiring',
        ]),
      );
      expect(
        VGSpatialTransformNodeSmokeReport.requiredBoundaryTokens.length,
        7,
      );
    });
  });

  group('fromMap and toMap roundtrip', () {
    test('successfully parses native result map with pass == true', () {
      final nativeMap = <String, Object?>{
        'pass': true,
        'raw':
            'status=PASS;totalLanes=16;passedLanes=16;'
            'proofBoundary=$kSpatialTransformNodeProofBoundary',
        'proofBoundary': kSpatialTransformNodeProofBoundary,
        'totalLanes': 16,
        'passedLanes': 16,
      };

      final report = VGSpatialTransformNodeSmokeReport.fromMap(nativeMap);
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 16);
      expect(report.passedLanes, 16);
      expect(report.proofBoundary, kSpatialTransformNodeProofBoundary);

      final map = report.toMap();
      expect(map['pass'], isTrue);
      expect(map['nativePass'], isTrue);
      expect(map['boundaryOk'], isTrue);
      expect(map['totalLanes'], 16);
      expect(map['passedLanes'], 16);
      expect(map['proofBoundary'], kSpatialTransformNodeProofBoundary);

      final roundTrip = VGSpatialTransformNodeSmokeReport.fromMap(map);
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
      expect(roundTrip!.pass, isTrue);
    });

    test('roundtrip preserves failing nativePass', () {
      const report = VGSpatialTransformNodeSmokeReport(
        pass: false,
        nativePass: false,
        boundaryOk: true,
        raw: 'status=FAIL;',
        proofBoundary: kSpatialTransformNodeProofBoundary,
        totalLanes: 16,
        passedLanes: 15,
      );

      final map = report.toMap();
      final restored = VGSpatialTransformNodeSmokeReport.fromMap(map);
      expect(restored, equals(report));
      expect(restored!.pass, isFalse);
      expect(restored.nativePass, isFalse);
    });

    test('toString includes all key fields', () {
      const report = VGSpatialTransformNodeSmokeReport(
        pass: true,
        nativePass: true,
        boundaryOk: true,
        raw: 'status=PASS;',
        proofBoundary: 'boundary',
        totalLanes: 16,
        passedLanes: 16,
      );
      final str = report.toString();
      expect(str, contains('pass: true'));
      expect(str, contains('nativePass: true'));
      expect(str, contains('boundaryOk: true'));
      expect(str, contains('totalLanes: 16'));
      expect(str, contains('passedLanes: 16'));
    });
  });

  group('Invalid map handling', () {
    test('non-map or null inputs return null', () {
      expect(VGSpatialTransformNodeSmokeReport.fromMap(null), isNull);
      expect(
        VGSpatialTransformNodeSmokeReport.fromMap('string_not_map'),
        isNull,
      );
      expect(VGSpatialTransformNodeSmokeReport.fromMap(12345), isNull);
      expect(VGSpatialTransformNodeSmokeReport.fromMap(<Object?>[]), isNull);
    });

    test('empty map returns null', () {
      expect(
        VGSpatialTransformNodeSmokeReport.fromMap(<String, Object?>{}),
        isNull,
      );
    });

    test('missing or invalid pass returns null', () {
      expect(
        VGSpatialTransformNodeSmokeReport.fromMap(<String, Object?>{
          'raw': 'status=PASS;',
          'proofBoundary': kSpatialTransformNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGSpatialTransformNodeSmokeReport.fromMap(<String, Object?>{
          'pass': 'true', // string instead of bool
          'raw': 'status=PASS;',
          'proofBoundary': kSpatialTransformNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
    });

    test('missing or invalid raw returns null', () {
      expect(
        VGSpatialTransformNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'proofBoundary': kSpatialTransformNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGSpatialTransformNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 999, // int instead of string
          'proofBoundary': kSpatialTransformNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
    });

    test('missing or invalid proofBoundary returns null', () {
      expect(
        VGSpatialTransformNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGSpatialTransformNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': true, // bool instead of string
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
    });

    test('non-numeric totalLanes or passedLanes returns null', () {
      expect(
        VGSpatialTransformNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kSpatialTransformNodeProofBoundary,
          'totalLanes': '16', // string instead of number
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGSpatialTransformNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kSpatialTransformNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': false, // bool instead of number
        }),
        isNull,
      );
    });

    test(
      'absent totalLanes and passedLanes default to 0 and pass is false',
      () {
        final report =
            VGSpatialTransformNodeSmokeReport.fromMap(<String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kSpatialTransformNodeProofBoundary,
            });
        expect(report, isNotNull);
        expect(report!.totalLanes, 0);
        expect(report.passedLanes, 0);
        expect(report.pass, isFalse);
        expect(report.nativePass, isTrue);
        expect(report.boundaryOk, isTrue);
      },
    );
  });

  group('Boundary token enforcement and pass conditions', () {
    test('boundaryOk is true when all 7 tokens are in proofBoundary', () {
      expect(
        VGSpatialTransformNodeSmokeReport.validateBoundary(
          raw: '',
          proofBoundary: kSpatialTransformNodeProofBoundary,
        ),
        isTrue,
      );
    });

    test('boundaryOk is true when all 7 tokens are in raw', () {
      expect(
        VGSpatialTransformNodeSmokeReport.validateBoundary(
          raw: kSpatialTransformNodeProofBoundary,
          proofBoundary: '',
        ),
        isTrue,
      );
    });

    test(
      'boundaryOk is true when tokens are split across raw and proofBoundary',
      () {
        expect(
          VGSpatialTransformNodeSmokeReport.validateBoundary(
            raw:
                'platform_neutral spatial_transform_node logical_dag_transform no_render_ownership',
            proofBoundary:
                'no_texture_ownership no_gpu_lifecycle no_product_app_editor_wiring',
          ),
          isTrue,
        );
      },
    );

    test('boundaryOk fails if any of the 7 tokens is missing', () {
      const allTokens = <String>[
        'platform_neutral',
        'spatial_transform_node',
        'logical_dag_transform',
        'no_render_ownership',
        'no_texture_ownership',
        'no_gpu_lifecycle',
        'no_product_app_editor_wiring',
      ];

      for (final missingToken in allTokens) {
        final remaining = allTokens.where((t) => t != missingToken).join('_');
        expect(
          VGSpatialTransformNodeSmokeReport.validateBoundary(
            raw: remaining,
            proofBoundary: '',
          ),
          isFalse,
          reason: 'Token $missingToken was missing but validation passed',
        );

        final report =
            VGSpatialTransformNodeSmokeReport.fromMap(<String, Object?>{
              'pass': true,
              'raw': remaining,
              'proofBoundary': remaining,
              'totalLanes': 16,
              'passedLanes': 16,
            });
        expect(report, isNotNull);
        expect(report!.boundaryOk, isFalse);
        expect(report.pass, isFalse);
      }
    });

    test('pass is false when nativePass is false', () {
      final report =
          VGSpatialTransformNodeSmokeReport.fromMap(<String, Object?>{
            'pass': false,
            'raw': 'status=FAIL;',
            'proofBoundary': kSpatialTransformNodeProofBoundary,
            'totalLanes': 16,
            'passedLanes': 16,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.nativePass, isFalse);
      expect(report.boundaryOk, isTrue);
    });

    test('pass is false when totalLanes != 16', () {
      final report =
          VGSpatialTransformNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kSpatialTransformNodeProofBoundary,
            'totalLanes': 15,
            'passedLanes': 15,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.totalLanes, 15);
    });

    test('pass is false when passedLanes != 16', () {
      final report =
          VGSpatialTransformNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kSpatialTransformNodeProofBoundary,
            'totalLanes': 16,
            'passedLanes': 15,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.passedLanes, 15);
    });

    test('pass is true only when all 4 conditions are met', () {
      final report =
          VGSpatialTransformNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kSpatialTransformNodeProofBoundary,
            'totalLanes': 16,
            'passedLanes': 16,
          });
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 16);
      expect(report.passedLanes, 16);
    });
  });

  group('VGSpatialTransformNodeSmokeRunner', () {
    const channelName = 'vanguard_media_engine_test_channel';
    const mockChannel = MethodChannel(channelName);

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, null);
    });

    test('runner success using a mock MethodChannel', () async {
      var callCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            callCount++;
            expect(call.method, 'runAndroidDagPhase5SpatialTransformNodeSmoke');
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;totalLanes=16;passedLanes=16;',
              'proofBoundary': kSpatialTransformNodeProofBoundary,
              'totalLanes': 16,
              'passedLanes': 16,
            };
          });

      const runner = VGSpatialTransformNodeSmokeRunner(channel: mockChannel);
      final report = await runner.runSmoke();

      expect(callCount, 1);
      expect(report.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 16);
      expect(report.passedLanes, 16);
      expect(report.proofBoundary, kSpatialTransformNodeProofBoundary);
    });

    test('runner passes channel override to runSmoke', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kSpatialTransformNodeProofBoundary,
              'totalLanes': 16,
              'passedLanes': 16,
            };
          });

      const runner = VGSpatialTransformNodeSmokeRunner();
      final report = await runner.runSmoke(channel: mockChannel);
      expect(report.pass, isTrue);
    });

    test('runner throws StateError when native route returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return null;
          });

      const runner = VGSpatialTransformNodeSmokeRunner(channel: mockChannel);
      expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
    });

    test(
      'runner throws StateError when native route returns invalid map',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
              return <String, Object?>{'unexpected_key': 42};
            });

        const runner = VGSpatialTransformNodeSmokeRunner(channel: mockChannel);
        expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
      },
    );

    test(
      'runner throws StateError when native route returns non-map object',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
              return 'unexpected_string_result';
            });

        const runner = VGSpatialTransformNodeSmokeRunner(channel: mockChannel);
        expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
      },
    );
  });
}
