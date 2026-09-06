// vg_image_optimizer_sink_node_smoke_test.dart
// vanguard_media_engine -- P5-IMAGE-OPTIMIZER-SINK-NODE-A
// Unit tests for VGImageOptimizerSinkNodeSmokeReport and
// VGImageOptimizerSinkNodeSmokeRunner.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_image_optimizer_sink_node_smoke.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Constants', () {
    test('canonical method channel name matches native declaration', () {
      expect(
        kImageOptimizerSinkNodeMethodName,
        'runAndroidDagPhase5ImageOptimizerSinkNodeSmoke',
      );
      expect(
        VGImageOptimizerSinkNodeSmokeReport.methodName,
        'runAndroidDagPhase5ImageOptimizerSinkNodeSmoke',
      );
    });

    test('canonical proof boundary constant matches expected boundary', () {
      const expected =
          'platform_neutral_image_optimizer_sink_node_logical_dag_sink_'
          'no_decode_no_downscale_no_encode_no_file_io_no_gpu_lifecycle_'
          'no_product_app_editor_wiring';
      expect(kImageOptimizerSinkNodeProofBoundary, expected);
      expect(
        VGImageOptimizerSinkNodeSmokeReport.requiredProofBoundary,
        expected,
      );
    });

    test('physical smoke markers match required protocol strings', () {
      expect(
        kImageOptimizerSinkNodeStartMarker,
        'ANDROID_DAG_PHASE5_IMAGE_OPTIMIZER_SINK_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        VGImageOptimizerSinkNodeSmokeReport.startMarker,
        'ANDROID_DAG_PHASE5_IMAGE_OPTIMIZER_SINK_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        kImageOptimizerSinkNodePassMarker,
        'ANDROID_DAG_PHASE5_IMAGE_OPTIMIZER_SINK_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        VGImageOptimizerSinkNodeSmokeReport.passMarker,
        'ANDROID_DAG_PHASE5_IMAGE_OPTIMIZER_SINK_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        kImageOptimizerSinkNodeFailMarker,
        'ANDROID_DAG_PHASE5_IMAGE_OPTIMIZER_SINK_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        VGImageOptimizerSinkNodeSmokeReport.failMarker,
        'ANDROID_DAG_PHASE5_IMAGE_OPTIMIZER_SINK_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        kImageOptimizerSinkNodeJsonPrefix,
        'ANDROID_DAG_PHASE5_IMAGE_OPTIMIZER_SINK_NODE_JSON:',
      );
      expect(
        VGImageOptimizerSinkNodeSmokeReport.jsonPrefix,
        'ANDROID_DAG_PHASE5_IMAGE_OPTIMIZER_SINK_NODE_JSON:',
      );
    });

    test('lane count constants match 15', () {
      expect(kImageOptimizerSinkNodeExpectedTotalLanes, 15);
      expect(kImageOptimizerSinkNodeExpectedPassedLanes, 15);
      expect(VGImageOptimizerSinkNodeSmokeReport.expectedTotalLanes, 15);
      expect(VGImageOptimizerSinkNodeSmokeReport.expectedPassedLanes, 15);
    });

    test('required boundary tokens contains all 9 mandatory tokens', () {
      expect(
        VGImageOptimizerSinkNodeSmokeReport.requiredBoundaryTokens,
        containsAll(<String>[
          'platform_neutral',
          'image_optimizer_sink_node',
          'logical_dag_sink',
          'no_decode',
          'no_downscale',
          'no_encode',
          'no_file_io',
          'no_gpu_lifecycle',
          'no_product_app_editor_wiring',
        ]),
      );
      expect(
        VGImageOptimizerSinkNodeSmokeReport.requiredBoundaryTokens.length,
        9,
      );
    });
  });

  group('fromMap and toMap roundtrip', () {
    test('successfully parses native result map with pass == true', () {
      final nativeMap = <String, Object?>{
        'pass': true,
        'raw':
            'status=PASS;totalLanes=15;passedLanes=15;'
            'proofBoundary=$kImageOptimizerSinkNodeProofBoundary',
        'proofBoundary': kImageOptimizerSinkNodeProofBoundary,
        'totalLanes': 15,
        'passedLanes': 15,
      };

      final report = VGImageOptimizerSinkNodeSmokeReport.fromMap(nativeMap);
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 15);
      expect(report.passedLanes, 15);
      expect(report.proofBoundary, kImageOptimizerSinkNodeProofBoundary);

      final map = report.toMap();
      expect(map['pass'], isTrue);
      expect(map['nativePass'], isTrue);
      expect(map['boundaryOk'], isTrue);
      expect(map['totalLanes'], 15);
      expect(map['passedLanes'], 15);
      expect(map['proofBoundary'], kImageOptimizerSinkNodeProofBoundary);

      final roundTrip = VGImageOptimizerSinkNodeSmokeReport.fromMap(map);
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
      expect(roundTrip!.pass, isTrue);
    });

    test('roundtrip preserves failing nativePass', () {
      const report = VGImageOptimizerSinkNodeSmokeReport(
        pass: false,
        nativePass: false,
        boundaryOk: true,
        raw: 'status=FAIL;',
        proofBoundary: kImageOptimizerSinkNodeProofBoundary,
        totalLanes: 15,
        passedLanes: 14,
      );

      final map = report.toMap();
      final restored = VGImageOptimizerSinkNodeSmokeReport.fromMap(map);
      expect(restored, equals(report));
      expect(restored!.pass, isFalse);
      expect(restored.nativePass, isFalse);
    });

    test('toString includes all key fields', () {
      const report = VGImageOptimizerSinkNodeSmokeReport(
        pass: true,
        nativePass: true,
        boundaryOk: true,
        raw: 'status=PASS;',
        proofBoundary: 'boundary',
        totalLanes: 15,
        passedLanes: 15,
      );
      final str = report.toString();
      expect(str, contains('pass: true'));
      expect(str, contains('nativePass: true'));
      expect(str, contains('boundaryOk: true'));
      expect(str, contains('totalLanes: 15'));
      expect(str, contains('passedLanes: 15'));
    });
  });

  group('Invalid map handling', () {
    test('non-map or null inputs return null', () {
      expect(VGImageOptimizerSinkNodeSmokeReport.fromMap(null), isNull);
      expect(
        VGImageOptimizerSinkNodeSmokeReport.fromMap('string_not_map'),
        isNull,
      );
      expect(VGImageOptimizerSinkNodeSmokeReport.fromMap(12345), isNull);
      expect(VGImageOptimizerSinkNodeSmokeReport.fromMap(<Object?>[]), isNull);
    });

    test('empty map returns null', () {
      expect(
        VGImageOptimizerSinkNodeSmokeReport.fromMap(<String, Object?>{}),
        isNull,
      );
    });

    test('missing or invalid pass returns null', () {
      expect(
        VGImageOptimizerSinkNodeSmokeReport.fromMap(<String, Object?>{
          'raw': 'status=PASS;',
          'proofBoundary': kImageOptimizerSinkNodeProofBoundary,
          'totalLanes': 15,
          'passedLanes': 15,
        }),
        isNull,
      );
      expect(
        VGImageOptimizerSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': 'true', // string instead of bool
          'raw': 'status=PASS;',
          'proofBoundary': kImageOptimizerSinkNodeProofBoundary,
          'totalLanes': 15,
          'passedLanes': 15,
        }),
        isNull,
      );
    });

    test('missing or invalid raw returns null', () {
      expect(
        VGImageOptimizerSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'proofBoundary': kImageOptimizerSinkNodeProofBoundary,
          'totalLanes': 15,
          'passedLanes': 15,
        }),
        isNull,
      );
      expect(
        VGImageOptimizerSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 999, // int instead of string
          'proofBoundary': kImageOptimizerSinkNodeProofBoundary,
          'totalLanes': 15,
          'passedLanes': 15,
        }),
        isNull,
      );
    });

    test('missing or invalid proofBoundary returns null', () {
      expect(
        VGImageOptimizerSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'totalLanes': 15,
          'passedLanes': 15,
        }),
        isNull,
      );
      expect(
        VGImageOptimizerSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': true, // bool instead of string
          'totalLanes': 15,
          'passedLanes': 15,
        }),
        isNull,
      );
    });

    test('non-numeric totalLanes or passedLanes returns null', () {
      expect(
        VGImageOptimizerSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kImageOptimizerSinkNodeProofBoundary,
          'totalLanes': '15', // string instead of number
          'passedLanes': 15,
        }),
        isNull,
      );
      expect(
        VGImageOptimizerSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kImageOptimizerSinkNodeProofBoundary,
          'totalLanes': 15,
          'passedLanes': false, // bool instead of number
        }),
        isNull,
      );
    });

    test(
      'absent totalLanes and passedLanes default to 0 and pass is false',
      () {
        final report =
            VGImageOptimizerSinkNodeSmokeReport.fromMap(<String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kImageOptimizerSinkNodeProofBoundary,
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
    test('boundaryOk is true when all 9 tokens are in proofBoundary', () {
      expect(
        VGImageOptimizerSinkNodeSmokeReport.validateBoundary(
          raw: '',
          proofBoundary: kImageOptimizerSinkNodeProofBoundary,
        ),
        isTrue,
      );
    });

    test('boundaryOk is true when all 9 tokens are in raw', () {
      expect(
        VGImageOptimizerSinkNodeSmokeReport.validateBoundary(
          raw: kImageOptimizerSinkNodeProofBoundary,
          proofBoundary: '',
        ),
        isTrue,
      );
    });

    test(
      'boundaryOk is true when tokens are split across raw and proofBoundary',
      () {
        expect(
          VGImageOptimizerSinkNodeSmokeReport.validateBoundary(
            raw:
                'platform_neutral image_optimizer_sink_node '
                'logical_dag_sink no_decode no_downscale',
            proofBoundary:
                'no_encode no_file_io no_gpu_lifecycle '
                'no_product_app_editor_wiring',
          ),
          isTrue,
        );
      },
    );

    test('boundaryOk fails if any of the 9 tokens is missing', () {
      const allTokens = <String>[
        'platform_neutral',
        'image_optimizer_sink_node',
        'logical_dag_sink',
        'no_decode',
        'no_downscale',
        'no_encode',
        'no_file_io',
        'no_gpu_lifecycle',
        'no_product_app_editor_wiring',
      ];

      for (final missingToken in allTokens) {
        final remaining = allTokens.where((t) => t != missingToken).join('_');
        expect(
          VGImageOptimizerSinkNodeSmokeReport.validateBoundary(
            raw: remaining,
            proofBoundary: '',
          ),
          isFalse,
          reason: 'Token $missingToken was missing but validation passed',
        );

        final report =
            VGImageOptimizerSinkNodeSmokeReport.fromMap(<String, Object?>{
              'pass': true,
              'raw': remaining,
              'proofBoundary': remaining,
              'totalLanes': 15,
              'passedLanes': 15,
            });
        expect(report, isNotNull);
        expect(report!.boundaryOk, isFalse);
        expect(report.pass, isFalse);
      }
    });

    test('pass is false when nativePass is false', () {
      final report =
          VGImageOptimizerSinkNodeSmokeReport.fromMap(<String, Object?>{
            'pass': false,
            'raw': 'status=FAIL;',
            'proofBoundary': kImageOptimizerSinkNodeProofBoundary,
            'totalLanes': 15,
            'passedLanes': 15,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.nativePass, isFalse);
      expect(report.boundaryOk, isTrue);
    });

    test('pass is false when totalLanes != 15', () {
      final report =
          VGImageOptimizerSinkNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kImageOptimizerSinkNodeProofBoundary,
            'totalLanes': 14,
            'passedLanes': 14,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.totalLanes, 14);
    });

    test('pass is false when passedLanes != 15', () {
      final report =
          VGImageOptimizerSinkNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kImageOptimizerSinkNodeProofBoundary,
            'totalLanes': 15,
            'passedLanes': 14,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.passedLanes, 14);
    });

    test('pass is true only when all 4 conditions are met', () {
      final report =
          VGImageOptimizerSinkNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kImageOptimizerSinkNodeProofBoundary,
            'totalLanes': 15,
            'passedLanes': 15,
          });
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 15);
      expect(report.passedLanes, 15);
    });
  });

  group('VGImageOptimizerSinkNodeSmokeRunner', () {
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
              'runAndroidDagPhase5ImageOptimizerSinkNodeSmoke',
            );
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;totalLanes=15;passedLanes=15;',
              'proofBoundary': kImageOptimizerSinkNodeProofBoundary,
              'totalLanes': 15,
              'passedLanes': 15,
            };
          });

      const runner = VGImageOptimizerSinkNodeSmokeRunner(channel: mockChannel);
      final report = await runner.runSmoke();

      expect(callCount, 1);
      expect(report.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 15);
      expect(report.passedLanes, 15);
      expect(report.proofBoundary, kImageOptimizerSinkNodeProofBoundary);
    });

    test('runner passes channel override to runSmoke', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kImageOptimizerSinkNodeProofBoundary,
              'totalLanes': 15,
              'passedLanes': 15,
            };
          });

      const runner = VGImageOptimizerSinkNodeSmokeRunner();
      final report = await runner.runSmoke(channel: mockChannel);
      expect(report.pass, isTrue);
    });

    test('runner throws StateError when native route returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return null;
          });

      const runner = VGImageOptimizerSinkNodeSmokeRunner(channel: mockChannel);
      expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
    });

    test(
      'runner throws StateError when native route returns invalid map',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
              return <String, Object?>{'unexpected_key': 42};
            });

        const runner = VGImageOptimizerSinkNodeSmokeRunner(
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

        const runner = VGImageOptimizerSinkNodeSmokeRunner(
          channel: mockChannel,
        );
        expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
      },
    );
  });
}
