// vg_graphic_overlay_compositor_node_smoke_test.dart
// vanguard_media_engine -- P5-GRAPHIC-OVERLAY-COMPOSITOR-NODE-A
// Unit tests for VGGraphicOverlayCompositorNodeSmokeReport and
// VGGraphicOverlayCompositorNodeSmokeRunner.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_graphic_overlay_compositor_node_smoke.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Constants', () {
    test('canonical method channel name matches native declaration', () {
      expect(
        kGraphicOverlayCompositorNodeMethodName,
        'runAndroidDagPhase5GraphicOverlayCompositorNodeSmoke',
      );
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.methodName,
        'runAndroidDagPhase5GraphicOverlayCompositorNodeSmoke',
      );
    });

    test('canonical proof boundary constant matches expected boundary', () {
      const expected =
          'platform_neutral_graphic_overlay_compositor_node_logical_dag_'
          'compositor_no_png_decode_no_rasterizer_no_shader_ownership_'
          'no_texture_ownership_no_gpu_lifecycle_no_product_app_editor_wiring';
      expect(kGraphicOverlayCompositorNodeProofBoundary, expected);
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.requiredProofBoundary,
        expected,
      );
    });

    test('physical smoke markers match required protocol strings', () {
      expect(
        kGraphicOverlayCompositorNodeStartMarker,
        'ANDROID_DAG_PHASE5_GRAPHIC_OVERLAY_COMPOSITOR_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.startMarker,
        'ANDROID_DAG_PHASE5_GRAPHIC_OVERLAY_COMPOSITOR_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        kGraphicOverlayCompositorNodePassMarker,
        'ANDROID_DAG_PHASE5_GRAPHIC_OVERLAY_COMPOSITOR_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.passMarker,
        'ANDROID_DAG_PHASE5_GRAPHIC_OVERLAY_COMPOSITOR_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        kGraphicOverlayCompositorNodeFailMarker,
        'ANDROID_DAG_PHASE5_GRAPHIC_OVERLAY_COMPOSITOR_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.failMarker,
        'ANDROID_DAG_PHASE5_GRAPHIC_OVERLAY_COMPOSITOR_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        kGraphicOverlayCompositorNodeJsonPrefix,
        'ANDROID_DAG_PHASE5_GRAPHIC_OVERLAY_COMPOSITOR_NODE_JSON:',
      );
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.jsonPrefix,
        'ANDROID_DAG_PHASE5_GRAPHIC_OVERLAY_COMPOSITOR_NODE_JSON:',
      );
    });

    test('lane count constants match 16', () {
      expect(kGraphicOverlayCompositorNodeExpectedTotalLanes, 16);
      expect(kGraphicOverlayCompositorNodeExpectedPassedLanes, 16);
      expect(VGGraphicOverlayCompositorNodeSmokeReport.expectedTotalLanes, 16);
      expect(VGGraphicOverlayCompositorNodeSmokeReport.expectedPassedLanes, 16);
    });

    test('required boundary tokens contains all 9 mandatory tokens', () {
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.requiredBoundaryTokens,
        containsAll(<String>[
          'platform_neutral',
          'graphic_overlay_compositor_node',
          'logical_dag_compositor',
          'no_png_decode',
          'no_rasterizer',
          'no_shader_ownership',
          'no_texture_ownership',
          'no_gpu_lifecycle',
          'no_product_app_editor_wiring',
        ]),
      );
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.requiredBoundaryTokens.length,
        9,
      );
    });
  });

  group('fromMap and toMap roundtrip', () {
    test('successfully parses native result map with pass == true', () {
      final nativeMap = <String, Object?>{
        'pass': true,
        'raw':
            'status=PASS;totalLanes=16;passedLanes=16;'
            'proofBoundary=$kGraphicOverlayCompositorNodeProofBoundary',
        'proofBoundary': kGraphicOverlayCompositorNodeProofBoundary,
        'totalLanes': 16,
        'passedLanes': 16,
      };

      final report = VGGraphicOverlayCompositorNodeSmokeReport.fromMap(
        nativeMap,
      );
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 16);
      expect(report.passedLanes, 16);
      expect(report.proofBoundary, kGraphicOverlayCompositorNodeProofBoundary);

      final map = report.toMap();
      expect(map['pass'], isTrue);
      expect(map['nativePass'], isTrue);
      expect(map['boundaryOk'], isTrue);
      expect(map['totalLanes'], 16);
      expect(map['passedLanes'], 16);
      expect(map['proofBoundary'], kGraphicOverlayCompositorNodeProofBoundary);

      final roundTrip = VGGraphicOverlayCompositorNodeSmokeReport.fromMap(map);
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
      expect(roundTrip!.pass, isTrue);
    });

    test('roundtrip preserves failing nativePass', () {
      const report = VGGraphicOverlayCompositorNodeSmokeReport(
        pass: false,
        nativePass: false,
        boundaryOk: true,
        raw: 'status=FAIL;',
        proofBoundary: kGraphicOverlayCompositorNodeProofBoundary,
        totalLanes: 16,
        passedLanes: 15,
      );

      final map = report.toMap();
      final restored = VGGraphicOverlayCompositorNodeSmokeReport.fromMap(map);
      expect(restored, equals(report));
      expect(restored!.pass, isFalse);
      expect(restored.nativePass, isFalse);
    });

    test('toString includes all key fields', () {
      const report = VGGraphicOverlayCompositorNodeSmokeReport(
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
      expect(VGGraphicOverlayCompositorNodeSmokeReport.fromMap(null), isNull);
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.fromMap('string_not_map'),
        isNull,
      );
      expect(VGGraphicOverlayCompositorNodeSmokeReport.fromMap(12345), isNull);
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<Object?>[]),
        isNull,
      );
    });

    test('empty map returns null', () {
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<String, Object?>{}),
        isNull,
      );
    });

    test('missing or invalid pass returns null', () {
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<String, Object?>{
          'raw': 'status=PASS;',
          'proofBoundary': kGraphicOverlayCompositorNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<String, Object?>{
          'pass': 'true', // string instead of bool
          'raw': 'status=PASS;',
          'proofBoundary': kGraphicOverlayCompositorNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
    });

    test('missing or invalid raw returns null', () {
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'proofBoundary': kGraphicOverlayCompositorNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 999, // int instead of string
          'proofBoundary': kGraphicOverlayCompositorNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
    });

    test('missing or invalid proofBoundary returns null', () {
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<String, Object?>{
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
        VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kGraphicOverlayCompositorNodeProofBoundary,
          'totalLanes': '16', // string instead of number
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kGraphicOverlayCompositorNodeProofBoundary,
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
            VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kGraphicOverlayCompositorNodeProofBoundary,
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
        VGGraphicOverlayCompositorNodeSmokeReport.validateBoundary(
          raw: '',
          proofBoundary: kGraphicOverlayCompositorNodeProofBoundary,
        ),
        isTrue,
      );
    });

    test('boundaryOk is true when all 9 tokens are in raw', () {
      expect(
        VGGraphicOverlayCompositorNodeSmokeReport.validateBoundary(
          raw: kGraphicOverlayCompositorNodeProofBoundary,
          proofBoundary: '',
        ),
        isTrue,
      );
    });

    test(
      'boundaryOk is true when tokens are split across raw and proofBoundary',
      () {
        expect(
          VGGraphicOverlayCompositorNodeSmokeReport.validateBoundary(
            raw:
                'platform_neutral graphic_overlay_compositor_node '
                'logical_dag_compositor no_png_decode no_rasterizer',
            proofBoundary:
                'no_shader_ownership no_texture_ownership no_gpu_lifecycle '
                'no_product_app_editor_wiring',
          ),
          isTrue,
        );
      },
    );

    test('boundaryOk fails if any of the 9 tokens is missing', () {
      const allTokens = <String>[
        'platform_neutral',
        'graphic_overlay_compositor_node',
        'logical_dag_compositor',
        'no_png_decode',
        'no_rasterizer',
        'no_shader_ownership',
        'no_texture_ownership',
        'no_gpu_lifecycle',
        'no_product_app_editor_wiring',
      ];

      for (final missingToken in allTokens) {
        final remaining = allTokens.where((t) => t != missingToken).join('_');
        expect(
          VGGraphicOverlayCompositorNodeSmokeReport.validateBoundary(
            raw: remaining,
            proofBoundary: '',
          ),
          isFalse,
          reason: 'Token $missingToken was missing but validation passed',
        );

        final report =
            VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<String, Object?>{
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
          VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<String, Object?>{
            'pass': false,
            'raw': 'status=FAIL;',
            'proofBoundary': kGraphicOverlayCompositorNodeProofBoundary,
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
          VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kGraphicOverlayCompositorNodeProofBoundary,
            'totalLanes': 15,
            'passedLanes': 15,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.totalLanes, 15);
    });

    test('pass is false when passedLanes != 16', () {
      final report =
          VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kGraphicOverlayCompositorNodeProofBoundary,
            'totalLanes': 16,
            'passedLanes': 15,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.passedLanes, 15);
    });

    test('pass is true only when all 4 conditions are met', () {
      final report =
          VGGraphicOverlayCompositorNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kGraphicOverlayCompositorNodeProofBoundary,
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

  group('VGGraphicOverlayCompositorNodeSmokeRunner', () {
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
              'runAndroidDagPhase5GraphicOverlayCompositorNodeSmoke',
            );
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;totalLanes=16;passedLanes=16;',
              'proofBoundary': kGraphicOverlayCompositorNodeProofBoundary,
              'totalLanes': 16,
              'passedLanes': 16,
            };
          });

      const runner = VGGraphicOverlayCompositorNodeSmokeRunner(
        channel: mockChannel,
      );
      final report = await runner.runSmoke();

      expect(callCount, 1);
      expect(report.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 16);
      expect(report.passedLanes, 16);
      expect(report.proofBoundary, kGraphicOverlayCompositorNodeProofBoundary);
    });

    test('runner passes channel override to runSmoke', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kGraphicOverlayCompositorNodeProofBoundary,
              'totalLanes': 16,
              'passedLanes': 16,
            };
          });

      const runner = VGGraphicOverlayCompositorNodeSmokeRunner();
      final report = await runner.runSmoke(channel: mockChannel);
      expect(report.pass, isTrue);
    });

    test('runner throws StateError when native route returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return null;
          });

      const runner = VGGraphicOverlayCompositorNodeSmokeRunner(
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

        const runner = VGGraphicOverlayCompositorNodeSmokeRunner(
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

        const runner = VGGraphicOverlayCompositorNodeSmokeRunner(
          channel: mockChannel,
        );
        expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
      },
    );
  });
}
