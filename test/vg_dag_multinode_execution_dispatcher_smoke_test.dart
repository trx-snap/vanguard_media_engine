// vg_dag_multinode_execution_dispatcher_smoke_test.dart
// vanguard_media_engine -- P1-DAG-MULTINODE-EXECUTION-DISPATCHER
// Unit tests for VGDagMultinodeExecutionDispatcherSmokeReport and VGDagMultinodeExecutionDispatcherSmokeRunner.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_dag_multinode_execution_dispatcher_smoke.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Constants', () {
    test('canonical method channel name matches native declaration', () {
      expect(
        kDagMultinodeExecutionDispatcherMethodName,
        'runAndroidDagPhase1DagMultinodeExecutionDispatcherSmoke',
      );
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.methodName,
        'runAndroidDagPhase1DagMultinodeExecutionDispatcherSmoke',
      );
    });

    test('canonical proof boundary constant matches expected boundary', () {
      const expected =
          'platform_neutral_dag_execution_dispatcher_diagnostic_only_no_node_execute_'
          'no_os_resource_ownership_no_render_no_gpu_transport_no_product_app_editor_wiring';
      expect(kDagMultinodeExecutionDispatcherProofBoundary, expected);
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.requiredProofBoundary,
        expected,
      );
    });

    test('physical smoke markers match required protocol strings', () {
      expect(
        kDagMultinodeExecutionDispatcherStartMarker,
        'ANDROID_DAG_PHASE1_DAG_MULTINODE_EXECUTION_DISPATCHER_PHYSICAL_SMOKE_START',
      );
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.startMarker,
        'ANDROID_DAG_PHASE1_DAG_MULTINODE_EXECUTION_DISPATCHER_PHYSICAL_SMOKE_START',
      );
      expect(
        kDagMultinodeExecutionDispatcherPassMarker,
        'ANDROID_DAG_PHASE1_DAG_MULTINODE_EXECUTION_DISPATCHER_PHYSICAL_SMOKE_PASS',
      );
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.passMarker,
        'ANDROID_DAG_PHASE1_DAG_MULTINODE_EXECUTION_DISPATCHER_PHYSICAL_SMOKE_PASS',
      );
      expect(
        kDagMultinodeExecutionDispatcherFailMarker,
        'ANDROID_DAG_PHASE1_DAG_MULTINODE_EXECUTION_DISPATCHER_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.failMarker,
        'ANDROID_DAG_PHASE1_DAG_MULTINODE_EXECUTION_DISPATCHER_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        kDagMultinodeExecutionDispatcherJsonPrefix,
        'ANDROID_DAG_PHASE1_DAG_MULTINODE_EXECUTION_DISPATCHER_JSON:',
      );
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.jsonPrefix,
        'ANDROID_DAG_PHASE1_DAG_MULTINODE_EXECUTION_DISPATCHER_JSON:',
      );
    });

    test('lane count constants match 10', () {
      expect(kDagMultinodeExecutionDispatcherExpectedTotalLanes, 10);
      expect(kDagMultinodeExecutionDispatcherExpectedPassedLanes, 10);
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.expectedTotalLanes,
        10,
      );
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.expectedPassedLanes,
        10,
      );
    });

    test('required boundary tokens contains all 7 mandatory tokens', () {
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.requiredBoundaryTokens,
        containsAll(<String>[
          'dag_execution_dispatcher',
          'diagnostic_only',
          'no_node_execute',
          'no_os_resource_ownership',
          'no_render',
          'no_gpu_transport',
          'no_product_app_editor_wiring',
        ]),
      );
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport
            .requiredBoundaryTokens
            .length,
        7,
      );
    });
  });

  group('fromMap and toMap roundtrip', () {
    test('successfully parses native result map with pass == true', () {
      final nativeMap = <String, Object?>{
        'pass': true,
        'raw':
            'status=PASS;totalLanes=10;passedLanes=10;'
            'proofBoundary=$kDagMultinodeExecutionDispatcherProofBoundary',
        'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
        'totalLanes': 10,
        'passedLanes': 10,
      };

      final report = VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(
        nativeMap,
      );
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 10);
      expect(report.passedLanes, 10);
      expect(
        report.proofBoundary,
        kDagMultinodeExecutionDispatcherProofBoundary,
      );

      final map = report.toMap();
      expect(map['pass'], isTrue);
      expect(map['nativePass'], isTrue);
      expect(map['boundaryOk'], isTrue);
      expect(map['totalLanes'], 10);
      expect(map['passedLanes'], 10);
      expect(
        map['proofBoundary'],
        kDagMultinodeExecutionDispatcherProofBoundary,
      );

      final roundTrip = VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(
        map,
      );
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
      expect(roundTrip!.pass, isTrue);
    });

    test('roundtrip preserves failing nativePass', () {
      const report = VGDagMultinodeExecutionDispatcherSmokeReport(
        pass: false,
        nativePass: false,
        boundaryOk: true,
        raw: 'status=FAIL;',
        proofBoundary: kDagMultinodeExecutionDispatcherProofBoundary,
        totalLanes: 10,
        passedLanes: 9,
      );

      final map = report.toMap();
      final restored = VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(
        map,
      );
      expect(restored, equals(report));
      expect(restored!.pass, isFalse);
      expect(restored.nativePass, isFalse);
    });

    test('accepts nativePass key in map', () {
      final map = <String, Object?>{
        'nativePass': true,
        'raw': 'status=PASS;',
        'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
        'totalLanes': 10,
        'passedLanes': 10,
      };
      final report = VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(map);
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
    });

    test('equality and hashCode distinguish different reports', () {
      const base = VGDagMultinodeExecutionDispatcherSmokeReport(
        pass: true,
        nativePass: true,
        boundaryOk: true,
        raw: 'status=PASS;',
        proofBoundary: kDagMultinodeExecutionDispatcherProofBoundary,
        totalLanes: 10,
        passedLanes: 10,
      );

      const differentPass = VGDagMultinodeExecutionDispatcherSmokeReport(
        pass: false,
        nativePass: true,
        boundaryOk: true,
        raw: 'status=PASS;',
        proofBoundary: kDagMultinodeExecutionDispatcherProofBoundary,
        totalLanes: 10,
        passedLanes: 10,
      );

      const differentNativePass = VGDagMultinodeExecutionDispatcherSmokeReport(
        pass: true,
        nativePass: false,
        boundaryOk: true,
        raw: 'status=PASS;',
        proofBoundary: kDagMultinodeExecutionDispatcherProofBoundary,
        totalLanes: 10,
        passedLanes: 10,
      );

      const differentBoundaryOk = VGDagMultinodeExecutionDispatcherSmokeReport(
        pass: true,
        nativePass: true,
        boundaryOk: false,
        raw: 'status=PASS;',
        proofBoundary: kDagMultinodeExecutionDispatcherProofBoundary,
        totalLanes: 10,
        passedLanes: 10,
      );

      const differentRaw = VGDagMultinodeExecutionDispatcherSmokeReport(
        pass: true,
        nativePass: true,
        boundaryOk: true,
        raw: 'different_raw',
        proofBoundary: kDagMultinodeExecutionDispatcherProofBoundary,
        totalLanes: 10,
        passedLanes: 10,
      );

      const differentProofBoundary =
          VGDagMultinodeExecutionDispatcherSmokeReport(
            pass: true,
            nativePass: true,
            boundaryOk: true,
            raw: 'status=PASS;',
            proofBoundary: 'other_boundary',
            totalLanes: 10,
            passedLanes: 10,
          );

      const differentTotalLanes = VGDagMultinodeExecutionDispatcherSmokeReport(
        pass: true,
        nativePass: true,
        boundaryOk: true,
        raw: 'status=PASS;',
        proofBoundary: kDagMultinodeExecutionDispatcherProofBoundary,
        totalLanes: 8,
        passedLanes: 10,
      );

      const differentPassedLanes = VGDagMultinodeExecutionDispatcherSmokeReport(
        pass: true,
        nativePass: true,
        boundaryOk: true,
        raw: 'status=PASS;',
        proofBoundary: kDagMultinodeExecutionDispatcherProofBoundary,
        totalLanes: 10,
        passedLanes: 8,
      );

      expect(base, equals(base));
      expect(base, isNot(equals(differentPass)));
      expect(base, isNot(equals(differentNativePass)));
      expect(base, isNot(equals(differentBoundaryOk)));
      expect(base, isNot(equals(differentRaw)));
      expect(base, isNot(equals(differentProofBoundary)));
      expect(base, isNot(equals(differentTotalLanes)));
      expect(base, isNot(equals(differentPassedLanes)));
      expect(base.hashCode, isNot(equals(differentPass.hashCode)));
    });

    test('toString includes all key fields', () {
      const report = VGDagMultinodeExecutionDispatcherSmokeReport(
        pass: true,
        nativePass: true,
        boundaryOk: true,
        raw: 'status=PASS;',
        proofBoundary: 'boundary',
        totalLanes: 10,
        passedLanes: 10,
      );
      final str = report.toString();
      expect(str, contains('pass: true'));
      expect(str, contains('nativePass: true'));
      expect(str, contains('boundaryOk: true'));
      expect(str, contains('totalLanes: 10'));
      expect(str, contains('passedLanes: 10'));
    });
  });

  group('Invalid map handling', () {
    test('non-map or null inputs return null', () {
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(null),
        isNull,
      );
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.fromMap('string_not_map'),
        isNull,
      );
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(12345),
        isNull,
      );
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(<Object?>[]),
        isNull,
      );
    });

    test('empty map returns null', () {
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(
          <String, Object?>{},
        ),
        isNull,
      );
    });

    test('missing or invalid pass returns null', () {
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(<String, Object?>{
          'raw': 'status=PASS;',
          'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
          'totalLanes': 10,
          'passedLanes': 10,
        }),
        isNull,
      );
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(<String, Object?>{
          'pass': 'true', // string instead of bool
          'raw': 'status=PASS;',
          'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
          'totalLanes': 10,
          'passedLanes': 10,
        }),
        isNull,
      );
    });

    test('missing or invalid raw returns null', () {
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
          'totalLanes': 10,
          'passedLanes': 10,
        }),
        isNull,
      );
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 999, // int instead of string
          'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
          'totalLanes': 10,
          'passedLanes': 10,
        }),
        isNull,
      );
    });

    test('missing or invalid proofBoundary returns null', () {
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'totalLanes': 10,
          'passedLanes': 10,
        }),
        isNull,
      );
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': true, // bool instead of string
          'totalLanes': 10,
          'passedLanes': 10,
        }),
        isNull,
      );
    });

    test('non-numeric totalLanes or passedLanes returns null', () {
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
          'totalLanes': '10', // string instead of number
          'passedLanes': 10,
        }),
        isNull,
      );
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
          'totalLanes': 10,
          'passedLanes': false, // bool instead of number
        }),
        isNull,
      );
    });

    test(
      'absent totalLanes and passedLanes default to 0 and pass is false',
      () {
        final report = VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(
          <String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
          },
        );
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
        VGDagMultinodeExecutionDispatcherSmokeReport.validateBoundary(
          raw: '',
          proofBoundary: kDagMultinodeExecutionDispatcherProofBoundary,
        ),
        isTrue,
      );
    });

    test('boundaryOk is true when all 7 tokens are in raw', () {
      expect(
        VGDagMultinodeExecutionDispatcherSmokeReport.validateBoundary(
          raw: kDagMultinodeExecutionDispatcherProofBoundary,
          proofBoundary: '',
        ),
        isTrue,
      );
    });

    test(
      'boundaryOk is true when tokens are split across raw and proofBoundary',
      () {
        expect(
          VGDagMultinodeExecutionDispatcherSmokeReport.validateBoundary(
            raw:
                'dag_execution_dispatcher diagnostic_only no_node_execute no_os_resource_ownership',
            proofBoundary:
                'no_render no_gpu_transport no_product_app_editor_wiring',
          ),
          isTrue,
        );
      },
    );

    test('boundaryOk fails if any of the 7 tokens is missing', () {
      const allTokens = <String>[
        'dag_execution_dispatcher',
        'diagnostic_only',
        'no_node_execute',
        'no_os_resource_ownership',
        'no_render',
        'no_gpu_transport',
        'no_product_app_editor_wiring',
      ];

      for (final missingToken in allTokens) {
        final remaining = allTokens.where((t) => t != missingToken).join('_');
        expect(
          VGDagMultinodeExecutionDispatcherSmokeReport.validateBoundary(
            raw: remaining,
            proofBoundary: '',
          ),
          isFalse,
          reason: 'Token $missingToken was missing but validation passed',
        );

        final report = VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(
          <String, Object?>{
            'pass': true,
            'raw': remaining,
            'proofBoundary': remaining,
            'totalLanes': 10,
            'passedLanes': 10,
          },
        );
        expect(report, isNotNull);
        expect(report!.boundaryOk, isFalse);
        expect(report.pass, isFalse);
      }
    });

    test('pass is false when nativePass is false', () {
      final report = VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(
        <String, Object?>{
          'pass': false,
          'raw': 'status=FAIL;',
          'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
          'totalLanes': 10,
          'passedLanes': 10,
        },
      );
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.nativePass, isFalse);
      expect(report.boundaryOk, isTrue);
    });

    test('pass recomputation overrides true pass when nativePass is false', () {
      final report = VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(
        <String, Object?>{
          'pass': true,
          'nativePass': false,
          'raw': 'status=FAIL;',
          'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
          'totalLanes': 10,
          'passedLanes': 10,
        },
      );
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.nativePass, isFalse);
    });

    test('pass is false when totalLanes != 10', () {
      final report = VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(
        <String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
          'totalLanes': 9,
          'passedLanes': 9,
        },
      );
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.totalLanes, 9);
    });

    test('pass is false when passedLanes != 10', () {
      final report = VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(
        <String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
          'totalLanes': 10,
          'passedLanes': 9,
        },
      );
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.passedLanes, 9);
    });

    test('pass is true only when all 4 conditions are met', () {
      final report = VGDagMultinodeExecutionDispatcherSmokeReport.fromMap(
        <String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
          'totalLanes': 10,
          'passedLanes': 10,
        },
      );
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 10);
      expect(report.passedLanes, 10);
    });
  });

  group('VGDagMultinodeExecutionDispatcherSmokeRunner', () {
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
              'runAndroidDagPhase1DagMultinodeExecutionDispatcherSmoke',
            );
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;totalLanes=10;passedLanes=10;',
              'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
              'totalLanes': 10,
              'passedLanes': 10,
            };
          });

      const runner = VGDagMultinodeExecutionDispatcherSmokeRunner(
        channel: mockChannel,
      );
      final report = await runner.runSmoke();

      expect(callCount, 1);
      expect(report.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 10);
      expect(report.passedLanes, 10);
      expect(
        report.proofBoundary,
        kDagMultinodeExecutionDispatcherProofBoundary,
      );
    });

    test('runner passes channel override to runSmoke', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kDagMultinodeExecutionDispatcherProofBoundary,
              'totalLanes': 10,
              'passedLanes': 10,
            };
          });

      const runner = VGDagMultinodeExecutionDispatcherSmokeRunner();
      final report = await runner.runSmoke(channel: mockChannel);
      expect(report.pass, isTrue);
    });

    test('runner throws StateError when native route returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return null;
          });

      const runner = VGDagMultinodeExecutionDispatcherSmokeRunner(
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

        const runner = VGDagMultinodeExecutionDispatcherSmokeRunner(
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

        const runner = VGDagMultinodeExecutionDispatcherSmokeRunner(
          channel: mockChannel,
        );
        expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
      },
    );

    test('runner propagates PlatformException when channel throws', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            throw PlatformException(
              code: 'UNAVAILABLE',
              message: 'Native execution dispatcher route unavailable',
            );
          });

      const runner = VGDagMultinodeExecutionDispatcherSmokeRunner(
        channel: mockChannel,
      );
      expect(() => runner.runSmoke(), throwsA(isA<PlatformException>()));
    });
  });
}
