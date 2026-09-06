// vg_external_surface_source_node_smoke_test.dart
// vanguard_media_engine -- P1-EXTERNAL-SURFACE-SOURCE-NODE-A
// Unit tests for VGExternalSurfaceSourceNodeSmokeReport and VGExternalSurfaceSourceNodeSmokeRunner.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_external_surface_source_node_smoke.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Constants', () {
    test('canonical method channel name matches native declaration', () {
      expect(
        kExternalSurfaceSourceNodeMethodName,
        'runAndroidDagPhase1ExternalSurfaceSourceNodeSmoke',
      );
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.methodName,
        'runAndroidDagPhase1ExternalSurfaceSourceNodeSmoke',
      );
    });

    test('canonical proof boundary constant matches expected boundary', () {
      const expected =
          'platform_neutral_external_surface_source_node_logical_dag_source_'
          'no_external_surface_ownership_no_android_lifecycle_'
          'no_product_app_editor_wiring';
      expect(kExternalSurfaceSourceNodeProofBoundary, expected);
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.requiredProofBoundary,
        expected,
      );
    });

    test('physical smoke markers match required protocol strings', () {
      expect(
        kExternalSurfaceSourceNodeStartMarker,
        'ANDROID_DAG_PHASE1_EXTERNAL_SURFACE_SOURCE_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.startMarker,
        'ANDROID_DAG_PHASE1_EXTERNAL_SURFACE_SOURCE_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        kExternalSurfaceSourceNodePassMarker,
        'ANDROID_DAG_PHASE1_EXTERNAL_SURFACE_SOURCE_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.passMarker,
        'ANDROID_DAG_PHASE1_EXTERNAL_SURFACE_SOURCE_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        kExternalSurfaceSourceNodeFailMarker,
        'ANDROID_DAG_PHASE1_EXTERNAL_SURFACE_SOURCE_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.failMarker,
        'ANDROID_DAG_PHASE1_EXTERNAL_SURFACE_SOURCE_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        kExternalSurfaceSourceNodeJsonPrefix,
        'ANDROID_DAG_PHASE1_EXTERNAL_SURFACE_SOURCE_NODE_JSON:',
      );
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.jsonPrefix,
        'ANDROID_DAG_PHASE1_EXTERNAL_SURFACE_SOURCE_NODE_JSON:',
      );
    });

    test('lane count constants match 14', () {
      expect(kExternalSurfaceSourceNodeExpectedTotalLanes, 14);
      expect(kExternalSurfaceSourceNodeExpectedPassedLanes, 14);
      expect(VGExternalSurfaceSourceNodeSmokeReport.expectedTotalLanes, 14);
      expect(VGExternalSurfaceSourceNodeSmokeReport.expectedPassedLanes, 14);
    });

    test('required boundary tokens contains all 6 mandatory tokens', () {
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.requiredBoundaryTokens,
        containsAll(<String>[
          'platform_neutral',
          'external_surface_source_node',
          'logical_dag_source',
          'no_external_surface_ownership',
          'no_android_lifecycle',
          'no_product_app_editor_wiring',
        ]),
      );
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.requiredBoundaryTokens.length,
        6,
      );
    });
  });

  group('fromMap and toMap roundtrip', () {
    test('successfully parses native result map with pass == true', () {
      final nativeMap = <String, Object?>{
        'pass': true,
        'raw':
            'status=PASS;totalLanes=14;passedLanes=14;'
            'proofBoundary=$kExternalSurfaceSourceNodeProofBoundary',
        'proofBoundary': kExternalSurfaceSourceNodeProofBoundary,
        'totalLanes': 14,
        'passedLanes': 14,
      };

      final report = VGExternalSurfaceSourceNodeSmokeReport.fromMap(nativeMap);
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 14);
      expect(report.passedLanes, 14);
      expect(report.proofBoundary, kExternalSurfaceSourceNodeProofBoundary);

      final map = report.toMap();
      expect(map['pass'], isTrue);
      expect(map['nativePass'], isTrue);
      expect(map['boundaryOk'], isTrue);
      expect(map['totalLanes'], 14);
      expect(map['passedLanes'], 14);
      expect(map['proofBoundary'], kExternalSurfaceSourceNodeProofBoundary);

      final roundTrip = VGExternalSurfaceSourceNodeSmokeReport.fromMap(map);
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
      expect(roundTrip!.pass, isTrue);
    });

    test('roundtrip preserves failing nativePass', () {
      const report = VGExternalSurfaceSourceNodeSmokeReport(
        pass: false,
        nativePass: false,
        boundaryOk: true,
        raw: 'status=FAIL;',
        proofBoundary: kExternalSurfaceSourceNodeProofBoundary,
        totalLanes: 14,
        passedLanes: 13,
      );

      final map = report.toMap();
      final restored = VGExternalSurfaceSourceNodeSmokeReport.fromMap(map);
      expect(restored, equals(report));
      expect(restored!.pass, isFalse);
      expect(restored.nativePass, isFalse);
    });

    test('toString includes all key fields', () {
      const report = VGExternalSurfaceSourceNodeSmokeReport(
        pass: true,
        nativePass: true,
        boundaryOk: true,
        raw: 'status=PASS;',
        proofBoundary: 'boundary',
        totalLanes: 14,
        passedLanes: 14,
      );
      final str = report.toString();
      expect(str, contains('pass: true'));
      expect(str, contains('nativePass: true'));
      expect(str, contains('boundaryOk: true'));
      expect(str, contains('totalLanes: 14'));
      expect(str, contains('passedLanes: 14'));
    });
  });

  group('Invalid map handling', () {
    test('non-map or null inputs return null', () {
      expect(VGExternalSurfaceSourceNodeSmokeReport.fromMap(null), isNull);
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.fromMap('string_not_map'),
        isNull,
      );
      expect(VGExternalSurfaceSourceNodeSmokeReport.fromMap(12345), isNull);
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.fromMap(<Object?>[]),
        isNull,
      );
    });

    test('empty map returns null', () {
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.fromMap(<String, Object?>{}),
        isNull,
      );
    });

    test('missing or invalid pass returns null', () {
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.fromMap(<String, Object?>{
          'raw': 'status=PASS;',
          'proofBoundary': kExternalSurfaceSourceNodeProofBoundary,
          'totalLanes': 14,
          'passedLanes': 14,
        }),
        isNull,
      );
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': 'true', // string instead of bool
          'raw': 'status=PASS;',
          'proofBoundary': kExternalSurfaceSourceNodeProofBoundary,
          'totalLanes': 14,
          'passedLanes': 14,
        }),
        isNull,
      );
    });

    test('missing or invalid raw returns null', () {
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'proofBoundary': kExternalSurfaceSourceNodeProofBoundary,
          'totalLanes': 14,
          'passedLanes': 14,
        }),
        isNull,
      );
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 999, // int instead of string
          'proofBoundary': kExternalSurfaceSourceNodeProofBoundary,
          'totalLanes': 14,
          'passedLanes': 14,
        }),
        isNull,
      );
    });

    test('missing or invalid proofBoundary returns null', () {
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'totalLanes': 14,
          'passedLanes': 14,
        }),
        isNull,
      );
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': true, // bool instead of string
          'totalLanes': 14,
          'passedLanes': 14,
        }),
        isNull,
      );
    });

    test('non-numeric totalLanes or passedLanes returns null', () {
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kExternalSurfaceSourceNodeProofBoundary,
          'totalLanes': '14', // string instead of number
          'passedLanes': 14,
        }),
        isNull,
      );
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kExternalSurfaceSourceNodeProofBoundary,
          'totalLanes': 14,
          'passedLanes': false, // bool instead of number
        }),
        isNull,
      );
    });

    test(
      'absent totalLanes and passedLanes default to 0 and pass is false',
      () {
        final report =
            VGExternalSurfaceSourceNodeSmokeReport.fromMap(<String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kExternalSurfaceSourceNodeProofBoundary,
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
    test('boundaryOk is true when all 6 tokens are in proofBoundary', () {
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.validateBoundary(
          raw: '',
          proofBoundary: kExternalSurfaceSourceNodeProofBoundary,
        ),
        isTrue,
      );
    });

    test('boundaryOk is true when all 6 tokens are in raw', () {
      expect(
        VGExternalSurfaceSourceNodeSmokeReport.validateBoundary(
          raw: kExternalSurfaceSourceNodeProofBoundary,
          proofBoundary: '',
        ),
        isTrue,
      );
    });

    test(
      'boundaryOk is true when tokens are split across raw and proofBoundary',
      () {
        expect(
          VGExternalSurfaceSourceNodeSmokeReport.validateBoundary(
            raw:
                'platform_neutral external_surface_source_node logical_dag_source',
            proofBoundary:
                'no_external_surface_ownership no_android_lifecycle no_product_app_editor_wiring',
          ),
          isTrue,
        );
      },
    );

    test('boundaryOk fails if any of the 6 tokens is missing', () {
      const allTokens = <String>[
        'platform_neutral',
        'external_surface_source_node',
        'logical_dag_source',
        'no_external_surface_ownership',
        'no_android_lifecycle',
        'no_product_app_editor_wiring',
      ];

      for (final missingToken in allTokens) {
        final remaining = allTokens.where((t) => t != missingToken).join('_');
        expect(
          VGExternalSurfaceSourceNodeSmokeReport.validateBoundary(
            raw: remaining,
            proofBoundary: '',
          ),
          isFalse,
          reason: 'Token $missingToken was missing but validation passed',
        );

        final report =
            VGExternalSurfaceSourceNodeSmokeReport.fromMap(<String, Object?>{
              'pass': true,
              'raw': remaining,
              'proofBoundary': remaining,
              'totalLanes': 14,
              'passedLanes': 14,
            });
        expect(report, isNotNull);
        expect(report!.boundaryOk, isFalse);
        expect(report.pass, isFalse);
      }
    });

    test('pass is false when nativePass is false', () {
      final report =
          VGExternalSurfaceSourceNodeSmokeReport.fromMap(<String, Object?>{
            'pass': false,
            'raw': 'status=FAIL;',
            'proofBoundary': kExternalSurfaceSourceNodeProofBoundary,
            'totalLanes': 14,
            'passedLanes': 14,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.nativePass, isFalse);
      expect(report.boundaryOk, isTrue);
    });

    test('pass is false when totalLanes != 14', () {
      final report =
          VGExternalSurfaceSourceNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kExternalSurfaceSourceNodeProofBoundary,
            'totalLanes': 13,
            'passedLanes': 13,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.totalLanes, 13);
    });

    test('pass is false when passedLanes != 14', () {
      final report =
          VGExternalSurfaceSourceNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kExternalSurfaceSourceNodeProofBoundary,
            'totalLanes': 14,
            'passedLanes': 13,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.passedLanes, 13);
    });

    test('pass is true only when all 4 conditions are met', () {
      final report =
          VGExternalSurfaceSourceNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kExternalSurfaceSourceNodeProofBoundary,
            'totalLanes': 14,
            'passedLanes': 14,
          });
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 14);
      expect(report.passedLanes, 14);
    });
  });

  group('VGExternalSurfaceSourceNodeSmokeRunner', () {
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
            expect(
              call.method,
              'runAndroidDagPhase1ExternalSurfaceSourceNodeSmoke',
            );
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;totalLanes=14;passedLanes=14;',
              'proofBoundary': kExternalSurfaceSourceNodeProofBoundary,
              'totalLanes': 14,
              'passedLanes': 14,
            };
          });

      const runner = VGExternalSurfaceSourceNodeSmokeRunner(
        channel: mockChannel,
      );
      final report = await runner.runSmoke();

      expect(callCount, 1);
      expect(report.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 14);
      expect(report.passedLanes, 14);
      expect(report.proofBoundary, kExternalSurfaceSourceNodeProofBoundary);
    });

    test('runner passes channel override to runSmoke', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kExternalSurfaceSourceNodeProofBoundary,
              'totalLanes': 14,
              'passedLanes': 14,
            };
          });

      const runner = VGExternalSurfaceSourceNodeSmokeRunner();
      final report = await runner.runSmoke(channel: mockChannel);
      expect(report.pass, isTrue);
    });

    test('runner throws StateError when native route returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return null;
          });

      const runner = VGExternalSurfaceSourceNodeSmokeRunner(
        channel: mockChannel,
      );
      expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
    });

    test(
      'runner throws StateError when native route returns invalid map',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
              return <String, Object?>{'unexpected_key': 42};
            });

        const runner = VGExternalSurfaceSourceNodeSmokeRunner(
          channel: mockChannel,
        );
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

        const runner = VGExternalSurfaceSourceNodeSmokeRunner(
          channel: mockChannel,
        );
        expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
      },
    );
  });
}
