// vg_preview_surface_sink_node_smoke_test.dart
// vanguard_media_engine -- P1-DAG-MULTINODE-PREVIEW-SURFACE-SINK-NODE
// Unit tests for VGPreviewSurfaceSinkNodeSmokeReport and VGPreviewSurfaceSinkNodeSmokeRunner.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_preview_surface_sink_node_smoke.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Constants', () {
    test('canonical method channel name matches native declaration', () {
      expect(
        kPreviewSurfaceSinkNodeMethodName,
        'runAndroidDagPhase1PreviewSurfaceSinkNodeSmoke',
      );
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.methodName,
        'runAndroidDagPhase1PreviewSurfaceSinkNodeSmoke',
      );
    });

    test('canonical proof boundary constant matches expected boundary', () {
      const expected =
          'platform_neutral_preview_surface_sink_node_logical_dag_sink_'
          'no_surface_ownership_no_android_lifecycle_no_product_app_editor_wiring';
      expect(kPreviewSurfaceSinkNodeProofBoundary, expected);
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.requiredProofBoundary,
        expected,
      );
    });

    test('physical smoke markers match required protocol strings', () {
      expect(
        kPreviewSurfaceSinkNodeStartMarker,
        'ANDROID_DAG_PHASE1_PREVIEW_SURFACE_SINK_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.startMarker,
        'ANDROID_DAG_PHASE1_PREVIEW_SURFACE_SINK_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        kPreviewSurfaceSinkNodePassMarker,
        'ANDROID_DAG_PHASE1_PREVIEW_SURFACE_SINK_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.passMarker,
        'ANDROID_DAG_PHASE1_PREVIEW_SURFACE_SINK_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        kPreviewSurfaceSinkNodeFailMarker,
        'ANDROID_DAG_PHASE1_PREVIEW_SURFACE_SINK_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.failMarker,
        'ANDROID_DAG_PHASE1_PREVIEW_SURFACE_SINK_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        kPreviewSurfaceSinkNodeJsonPrefix,
        'ANDROID_DAG_PHASE1_PREVIEW_SURFACE_SINK_NODE_JSON:',
      );
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.jsonPrefix,
        'ANDROID_DAG_PHASE1_PREVIEW_SURFACE_SINK_NODE_JSON:',
      );
    });

    test('lane count constants match 10', () {
      expect(kPreviewSurfaceSinkNodeExpectedTotalLanes, 10);
      expect(kPreviewSurfaceSinkNodeExpectedPassedLanes, 10);
      expect(VGPreviewSurfaceSinkNodeSmokeReport.expectedTotalLanes, 10);
      expect(VGPreviewSurfaceSinkNodeSmokeReport.expectedPassedLanes, 10);
    });

    test('required boundary tokens contains all 6 mandatory tokens', () {
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.requiredBoundaryTokens,
        containsAll(<String>[
          'platform_neutral',
          'preview_surface_sink_node',
          'logical_dag_sink',
          'no_surface_ownership',
          'no_android_lifecycle',
          'no_product_app_editor_wiring',
        ]),
      );
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.requiredBoundaryTokens.length,
        6,
      );
    });
  });

  group('fromMap and toMap roundtrip', () {
    test('successfully parses native result map with pass == true', () {
      final nativeMap = <String, Object?>{
        'pass': true,
        'raw':
            'status=PASS;totalLanes=10;passedLanes=10;'
            'proofBoundary=$kPreviewSurfaceSinkNodeProofBoundary',
        'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
        'totalLanes': 10,
        'passedLanes': 10,
      };

      final report = VGPreviewSurfaceSinkNodeSmokeReport.fromMap(nativeMap);
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 10);
      expect(report.passedLanes, 10);
      expect(report.proofBoundary, kPreviewSurfaceSinkNodeProofBoundary);

      final map = report.toMap();
      expect(map['pass'], isTrue);
      expect(map['nativePass'], isTrue);
      expect(map['boundaryOk'], isTrue);
      expect(map['totalLanes'], 10);
      expect(map['passedLanes'], 10);
      expect(map['proofBoundary'], kPreviewSurfaceSinkNodeProofBoundary);

      final roundTrip = VGPreviewSurfaceSinkNodeSmokeReport.fromMap(map);
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
      expect(roundTrip!.pass, isTrue);
    });

    test('roundtrip preserves failing nativePass', () {
      final report = const VGPreviewSurfaceSinkNodeSmokeReport(
        pass: false,
        nativePass: false,
        boundaryOk: true,
        raw: 'status=FAIL;',
        proofBoundary: kPreviewSurfaceSinkNodeProofBoundary,
        totalLanes: 10,
        passedLanes: 9,
      );

      final map = report.toMap();
      final restored = VGPreviewSurfaceSinkNodeSmokeReport.fromMap(map);
      expect(restored, equals(report));
      expect(restored!.pass, isFalse);
      expect(restored.nativePass, isFalse);
    });

    test('accepts nativePass key in map', () {
      final map = <String, Object?>{
        'nativePass': true,
        'raw': 'status=PASS;',
        'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
        'totalLanes': 10,
        'passedLanes': 10,
      };
      final report = VGPreviewSurfaceSinkNodeSmokeReport.fromMap(map);
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
    });

    test('toString includes all key fields', () {
      const report = VGPreviewSurfaceSinkNodeSmokeReport(
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
      expect(VGPreviewSurfaceSinkNodeSmokeReport.fromMap(null), isNull);
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.fromMap('string_not_map'),
        isNull,
      );
      expect(VGPreviewSurfaceSinkNodeSmokeReport.fromMap(12345), isNull);
      expect(VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<Object?>[]), isNull);
    });

    test('empty map returns null', () {
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<String, Object?>{}),
        isNull,
      );
    });

    test('missing or invalid pass returns null', () {
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<String, Object?>{
          'raw': 'status=PASS;',
          'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
          'totalLanes': 10,
          'passedLanes': 10,
        }),
        isNull,
      );
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': 'true', // string instead of bool
          'raw': 'status=PASS;',
          'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
          'totalLanes': 10,
          'passedLanes': 10,
        }),
        isNull,
      );
    });

    test('missing or invalid raw returns null', () {
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
          'totalLanes': 10,
          'passedLanes': 10,
        }),
        isNull,
      );
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 999, // int instead of string
          'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
          'totalLanes': 10,
          'passedLanes': 10,
        }),
        isNull,
      );
    });

    test('missing or invalid proofBoundary returns null', () {
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'totalLanes': 10,
          'passedLanes': 10,
        }),
        isNull,
      );
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<String, Object?>{
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
        VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
          'totalLanes': '10', // string instead of number
          'passedLanes': 10,
        }),
        isNull,
      );
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
          'totalLanes': 10,
          'passedLanes': false, // bool instead of number
        }),
        isNull,
      );
    });

    test(
      'absent totalLanes and passedLanes default to 0 and pass is false',
      () {
        final report =
            VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
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
        VGPreviewSurfaceSinkNodeSmokeReport.validateBoundary(
          raw: '',
          proofBoundary: kPreviewSurfaceSinkNodeProofBoundary,
        ),
        isTrue,
      );
    });

    test('boundaryOk is true when all 6 tokens are in raw', () {
      expect(
        VGPreviewSurfaceSinkNodeSmokeReport.validateBoundary(
          raw: kPreviewSurfaceSinkNodeProofBoundary,
          proofBoundary: '',
        ),
        isTrue,
      );
    });

    test(
      'boundaryOk is true when tokens are split across raw and proofBoundary',
      () {
        expect(
          VGPreviewSurfaceSinkNodeSmokeReport.validateBoundary(
            raw: 'platform_neutral preview_surface_sink_node logical_dag_sink',
            proofBoundary:
                'no_surface_ownership no_android_lifecycle no_product_app_editor_wiring',
          ),
          isTrue,
        );
      },
    );

    test('boundaryOk fails if any of the 6 tokens is missing', () {
      const allTokens = <String>[
        'platform_neutral',
        'preview_surface_sink_node',
        'logical_dag_sink',
        'no_surface_ownership',
        'no_android_lifecycle',
        'no_product_app_editor_wiring',
      ];

      for (final missingToken in allTokens) {
        final remaining = allTokens.where((t) => t != missingToken).join('_');
        expect(
          VGPreviewSurfaceSinkNodeSmokeReport.validateBoundary(
            raw: remaining,
            proofBoundary: '',
          ),
          isFalse,
          reason: 'Token $missingToken was missing but validation passed',
        );

        final report =
            VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<String, Object?>{
              'pass': true,
              'raw': remaining,
              'proofBoundary': remaining,
              'totalLanes': 10,
              'passedLanes': 10,
            });
        expect(report, isNotNull);
        expect(report!.boundaryOk, isFalse);
        expect(report.pass, isFalse);
      }
    });

    test('pass is false when nativePass is false', () {
      final report =
          VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<String, Object?>{
            'pass': false,
            'raw': 'status=FAIL;',
            'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
            'totalLanes': 10,
            'passedLanes': 10,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.nativePass, isFalse);
      expect(report.boundaryOk, isTrue);
    });

    test('pass is false when totalLanes != 10', () {
      final report =
          VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
            'totalLanes': 9,
            'passedLanes': 9,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.totalLanes, 9);
    });

    test('pass is false when passedLanes != 10', () {
      final report =
          VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
            'totalLanes': 10,
            'passedLanes': 9,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.passedLanes, 9);
    });

    test('pass is true only when all 4 conditions are met', () {
      final report =
          VGPreviewSurfaceSinkNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
            'totalLanes': 10,
            'passedLanes': 10,
          });
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 10);
      expect(report.passedLanes, 10);
    });
  });

  group('VGPreviewSurfaceSinkNodeSmokeRunner', () {
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
              'runAndroidDagPhase1PreviewSurfaceSinkNodeSmoke',
            );
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;totalLanes=10;passedLanes=10;',
              'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
              'totalLanes': 10,
              'passedLanes': 10,
            };
          });

      const runner = VGPreviewSurfaceSinkNodeSmokeRunner(channel: mockChannel);
      final report = await runner.runSmoke();

      expect(callCount, 1);
      expect(report.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 10);
      expect(report.passedLanes, 10);
      expect(report.proofBoundary, kPreviewSurfaceSinkNodeProofBoundary);
    });

    test('runner passes channel override to runSmoke', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kPreviewSurfaceSinkNodeProofBoundary,
              'totalLanes': 10,
              'passedLanes': 10,
            };
          });

      const runner = VGPreviewSurfaceSinkNodeSmokeRunner();
      final report = await runner.runSmoke(channel: mockChannel);
      expect(report.pass, isTrue);
    });

    test('runner throws StateError when native route returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return null;
          });

      const runner = VGPreviewSurfaceSinkNodeSmokeRunner(channel: mockChannel);
      expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
    });

    test(
      'runner throws StateError when native route returns invalid map',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
              return <String, Object?>{'unexpected_key': 42};
            });

        const runner = VGPreviewSurfaceSinkNodeSmokeRunner(
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

        const runner = VGPreviewSurfaceSinkNodeSmokeRunner(
          channel: mockChannel,
        );
        expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
      },
    );
  });
}
