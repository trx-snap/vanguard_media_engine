// vg_filter_node_smoke_test.dart
// vanguard_media_engine -- P5-FILTER-NODE-A
// Unit tests for VGFilterNodeSmokeReport and VGFilterNodeSmokeRunner.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_filter_node_smoke.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Constants', () {
    test('canonical method channel name matches native declaration', () {
      expect(kFilterNodeMethodName, 'runAndroidDagPhase5FilterNodeSmoke');
      expect(
        VGFilterNodeSmokeReport.methodName,
        'runAndroidDagPhase5FilterNodeSmoke',
      );
    });

    test('canonical proof boundary constant matches expected boundary', () {
      const expected =
          'platform_neutral_filter_node_logical_dag_filter_'
          'no_shader_ownership_no_texture_ownership_no_gpu_lifecycle_'
          'no_product_app_editor_wiring';
      expect(kFilterNodeProofBoundary, expected);
      expect(VGFilterNodeSmokeReport.requiredProofBoundary, expected);
    });

    test('physical smoke markers match required protocol strings', () {
      expect(
        kFilterNodeStartMarker,
        'ANDROID_DAG_PHASE5_FILTER_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        VGFilterNodeSmokeReport.startMarker,
        'ANDROID_DAG_PHASE5_FILTER_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        kFilterNodePassMarker,
        'ANDROID_DAG_PHASE5_FILTER_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        VGFilterNodeSmokeReport.passMarker,
        'ANDROID_DAG_PHASE5_FILTER_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        kFilterNodeFailMarker,
        'ANDROID_DAG_PHASE5_FILTER_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        VGFilterNodeSmokeReport.failMarker,
        'ANDROID_DAG_PHASE5_FILTER_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(kFilterNodeJsonPrefix, 'ANDROID_DAG_PHASE5_FILTER_NODE_JSON:');
      expect(
        VGFilterNodeSmokeReport.jsonPrefix,
        'ANDROID_DAG_PHASE5_FILTER_NODE_JSON:',
      );
    });

    test('lane count constants match 16', () {
      expect(kFilterNodeExpectedTotalLanes, 16);
      expect(kFilterNodeExpectedPassedLanes, 16);
      expect(VGFilterNodeSmokeReport.expectedTotalLanes, 16);
      expect(VGFilterNodeSmokeReport.expectedPassedLanes, 16);
    });

    test('required boundary tokens contains all 7 mandatory tokens', () {
      expect(
        VGFilterNodeSmokeReport.requiredBoundaryTokens,
        containsAll(<String>[
          'platform_neutral',
          'filter_node',
          'logical_dag_filter',
          'no_shader_ownership',
          'no_texture_ownership',
          'no_gpu_lifecycle',
          'no_product_app_editor_wiring',
        ]),
      );
      expect(VGFilterNodeSmokeReport.requiredBoundaryTokens.length, 7);
    });
  });

  group('fromMap and toMap roundtrip', () {
    test('successfully parses native result map with pass == true', () {
      final nativeMap = <String, Object?>{
        'pass': true,
        'raw':
            'status=PASS;totalLanes=16;passedLanes=16;'
            'proofBoundary=$kFilterNodeProofBoundary',
        'proofBoundary': kFilterNodeProofBoundary,
        'totalLanes': 16,
        'passedLanes': 16,
      };

      final report = VGFilterNodeSmokeReport.fromMap(nativeMap);
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 16);
      expect(report.passedLanes, 16);
      expect(report.proofBoundary, kFilterNodeProofBoundary);

      final map = report.toMap();
      expect(map['pass'], isTrue);
      expect(map['nativePass'], isTrue);
      expect(map['boundaryOk'], isTrue);
      expect(map['totalLanes'], 16);
      expect(map['passedLanes'], 16);
      expect(map['proofBoundary'], kFilterNodeProofBoundary);

      final roundTrip = VGFilterNodeSmokeReport.fromMap(map);
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
      expect(roundTrip!.pass, isTrue);
    });

    test('roundtrip preserves failing nativePass', () {
      const report = VGFilterNodeSmokeReport(
        pass: false,
        nativePass: false,
        boundaryOk: true,
        raw: 'status=FAIL;',
        proofBoundary: kFilterNodeProofBoundary,
        totalLanes: 16,
        passedLanes: 15,
      );

      final map = report.toMap();
      final restored = VGFilterNodeSmokeReport.fromMap(map);
      expect(restored, equals(report));
      expect(restored!.pass, isFalse);
      expect(restored.nativePass, isFalse);
    });

    test('toString includes all key fields', () {
      const report = VGFilterNodeSmokeReport(
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
      expect(VGFilterNodeSmokeReport.fromMap(null), isNull);
      expect(VGFilterNodeSmokeReport.fromMap('string_not_map'), isNull);
      expect(VGFilterNodeSmokeReport.fromMap(12345), isNull);
      expect(VGFilterNodeSmokeReport.fromMap(<Object?>[]), isNull);
    });

    test('empty map returns null', () {
      expect(VGFilterNodeSmokeReport.fromMap(<String, Object?>{}), isNull);
    });

    test('missing or invalid pass returns null', () {
      expect(
        VGFilterNodeSmokeReport.fromMap(<String, Object?>{
          'raw': 'status=PASS;',
          'proofBoundary': kFilterNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGFilterNodeSmokeReport.fromMap(<String, Object?>{
          'pass': 'true', // string instead of bool
          'raw': 'status=PASS;',
          'proofBoundary': kFilterNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
    });

    test('missing or invalid raw returns null', () {
      expect(
        VGFilterNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'proofBoundary': kFilterNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGFilterNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 999, // int instead of string
          'proofBoundary': kFilterNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
    });

    test('missing or invalid proofBoundary returns null', () {
      expect(
        VGFilterNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGFilterNodeSmokeReport.fromMap(<String, Object?>{
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
        VGFilterNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kFilterNodeProofBoundary,
          'totalLanes': '16', // string instead of number
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGFilterNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kFilterNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': false, // bool instead of number
        }),
        isNull,
      );
    });

    test(
      'absent totalLanes and passedLanes default to 0 and pass is false',
      () {
        final report = VGFilterNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kFilterNodeProofBoundary,
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
        VGFilterNodeSmokeReport.validateBoundary(
          raw: '',
          proofBoundary: kFilterNodeProofBoundary,
        ),
        isTrue,
      );
    });

    test('boundaryOk is true when all 7 tokens are in raw', () {
      expect(
        VGFilterNodeSmokeReport.validateBoundary(
          raw: kFilterNodeProofBoundary,
          proofBoundary: '',
        ),
        isTrue,
      );
    });

    test(
      'boundaryOk is true when tokens are split across raw and proofBoundary',
      () {
        expect(
          VGFilterNodeSmokeReport.validateBoundary(
            raw:
                'platform_neutral filter_node logical_dag_filter no_shader_ownership',
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
        'filter_node',
        'logical_dag_filter',
        'no_shader_ownership',
        'no_texture_ownership',
        'no_gpu_lifecycle',
        'no_product_app_editor_wiring',
      ];

      for (final missingToken in allTokens) {
        final remaining = allTokens.where((t) => t != missingToken).join('_');
        expect(
          VGFilterNodeSmokeReport.validateBoundary(
            raw: remaining,
            proofBoundary: '',
          ),
          isFalse,
          reason: 'Token $missingToken was missing but validation passed',
        );

        final report = VGFilterNodeSmokeReport.fromMap(<String, Object?>{
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
      final report = VGFilterNodeSmokeReport.fromMap(<String, Object?>{
        'pass': false,
        'raw': 'status=FAIL;',
        'proofBoundary': kFilterNodeProofBoundary,
        'totalLanes': 16,
        'passedLanes': 16,
      });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.nativePass, isFalse);
      expect(report.boundaryOk, isTrue);
    });

    test('pass is false when totalLanes != 16', () {
      final report = VGFilterNodeSmokeReport.fromMap(<String, Object?>{
        'pass': true,
        'raw': 'status=PASS;',
        'proofBoundary': kFilterNodeProofBoundary,
        'totalLanes': 15,
        'passedLanes': 15,
      });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.totalLanes, 15);
    });

    test('pass is false when passedLanes != 16', () {
      final report = VGFilterNodeSmokeReport.fromMap(<String, Object?>{
        'pass': true,
        'raw': 'status=PASS;',
        'proofBoundary': kFilterNodeProofBoundary,
        'totalLanes': 16,
        'passedLanes': 15,
      });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.passedLanes, 15);
    });

    test('pass is true only when all 4 conditions are met', () {
      final report = VGFilterNodeSmokeReport.fromMap(<String, Object?>{
        'pass': true,
        'raw': 'status=PASS;',
        'proofBoundary': kFilterNodeProofBoundary,
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

  group('VGFilterNodeSmokeRunner', () {
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
            expect(call.method, 'runAndroidDagPhase5FilterNodeSmoke');
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;totalLanes=16;passedLanes=16;',
              'proofBoundary': kFilterNodeProofBoundary,
              'totalLanes': 16,
              'passedLanes': 16,
            };
          });

      const runner = VGFilterNodeSmokeRunner(channel: mockChannel);
      final report = await runner.runSmoke();

      expect(callCount, 1);
      expect(report.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 16);
      expect(report.passedLanes, 16);
      expect(report.proofBoundary, kFilterNodeProofBoundary);
    });

    test('runner passes channel override to runSmoke', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kFilterNodeProofBoundary,
              'totalLanes': 16,
              'passedLanes': 16,
            };
          });

      const runner = VGFilterNodeSmokeRunner();
      final report = await runner.runSmoke(channel: mockChannel);
      expect(report.pass, isTrue);
    });

    test('runner throws StateError when native route returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return null;
          });

      const runner = VGFilterNodeSmokeRunner(channel: mockChannel);
      expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
    });

    test(
      'runner throws StateError when native route returns invalid map',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
              return <String, Object?>{'unexpected_key': 42};
            });

        const runner = VGFilterNodeSmokeRunner(channel: mockChannel);
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

        const runner = VGFilterNodeSmokeRunner(channel: mockChannel);
        expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
      },
    );
  });
}
