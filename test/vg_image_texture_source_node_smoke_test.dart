// vg_image_texture_source_node_smoke_test.dart
// vanguard_media_engine -- P5-IMAGE-TEXTURE-SOURCE-NODE-A
// Unit tests for VGImageTextureSourceNodeSmokeReport and VGImageTextureSourceNodeSmokeRunner.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_image_texture_source_node_smoke.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Constants', () {
    test('canonical method channel name matches native declaration', () {
      expect(
        kImageTextureSourceNodeMethodName,
        'runAndroidDagPhase5ImageTextureSourceNodeSmoke',
      );
      expect(
        VGImageTextureSourceNodeSmokeReport.methodName,
        'runAndroidDagPhase5ImageTextureSourceNodeSmoke',
      );
    });

    test('canonical proof boundary constant matches expected boundary', () {
      const expected =
          'platform_neutral_image_texture_source_node_logical_dag_source_'
          'no_texture_ownership_no_image_decoder_lifecycle_'
          'no_product_app_editor_wiring';
      expect(kImageTextureSourceNodeProofBoundary, expected);
      expect(
        VGImageTextureSourceNodeSmokeReport.requiredProofBoundary,
        expected,
      );
    });

    test('physical smoke markers match required protocol strings', () {
      expect(
        kImageTextureSourceNodeStartMarker,
        'ANDROID_DAG_PHASE5_IMAGE_TEXTURE_SOURCE_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        VGImageTextureSourceNodeSmokeReport.startMarker,
        'ANDROID_DAG_PHASE5_IMAGE_TEXTURE_SOURCE_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        kImageTextureSourceNodePassMarker,
        'ANDROID_DAG_PHASE5_IMAGE_TEXTURE_SOURCE_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        VGImageTextureSourceNodeSmokeReport.passMarker,
        'ANDROID_DAG_PHASE5_IMAGE_TEXTURE_SOURCE_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        kImageTextureSourceNodeFailMarker,
        'ANDROID_DAG_PHASE5_IMAGE_TEXTURE_SOURCE_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        VGImageTextureSourceNodeSmokeReport.failMarker,
        'ANDROID_DAG_PHASE5_IMAGE_TEXTURE_SOURCE_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        kImageTextureSourceNodeJsonPrefix,
        'ANDROID_DAG_PHASE5_IMAGE_TEXTURE_SOURCE_NODE_JSON:',
      );
      expect(
        VGImageTextureSourceNodeSmokeReport.jsonPrefix,
        'ANDROID_DAG_PHASE5_IMAGE_TEXTURE_SOURCE_NODE_JSON:',
      );
    });

    test('lane count constants match 15', () {
      expect(kImageTextureSourceNodeExpectedTotalLanes, 15);
      expect(kImageTextureSourceNodeExpectedPassedLanes, 15);
      expect(VGImageTextureSourceNodeSmokeReport.expectedTotalLanes, 15);
      expect(VGImageTextureSourceNodeSmokeReport.expectedPassedLanes, 15);
    });

    test('required boundary tokens contains all 6 mandatory tokens', () {
      expect(
        VGImageTextureSourceNodeSmokeReport.requiredBoundaryTokens,
        containsAll(<String>[
          'platform_neutral',
          'image_texture_source_node',
          'logical_dag_source',
          'no_texture_ownership',
          'no_image_decoder_lifecycle',
          'no_product_app_editor_wiring',
        ]),
      );
      expect(
        VGImageTextureSourceNodeSmokeReport.requiredBoundaryTokens.length,
        6,
      );
    });
  });

  group('fromMap and toMap roundtrip', () {
    test('successfully parses native result map with pass == true', () {
      final nativeMap = <String, Object?>{
        'pass': true,
        'raw':
            'status=PASS;totalLanes=15;passedLanes=15;'
            'proofBoundary=$kImageTextureSourceNodeProofBoundary',
        'proofBoundary': kImageTextureSourceNodeProofBoundary,
        'totalLanes': 15,
        'passedLanes': 15,
      };

      final report = VGImageTextureSourceNodeSmokeReport.fromMap(nativeMap);
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 15);
      expect(report.passedLanes, 15);
      expect(report.proofBoundary, kImageTextureSourceNodeProofBoundary);

      final map = report.toMap();
      expect(map['pass'], isTrue);
      expect(map['nativePass'], isTrue);
      expect(map['boundaryOk'], isTrue);
      expect(map['totalLanes'], 15);
      expect(map['passedLanes'], 15);
      expect(map['proofBoundary'], kImageTextureSourceNodeProofBoundary);

      final roundTrip = VGImageTextureSourceNodeSmokeReport.fromMap(map);
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
      expect(roundTrip!.pass, isTrue);
    });

    test('roundtrip preserves failing nativePass', () {
      const report = VGImageTextureSourceNodeSmokeReport(
        pass: false,
        nativePass: false,
        boundaryOk: true,
        raw: 'status=FAIL;',
        proofBoundary: kImageTextureSourceNodeProofBoundary,
        totalLanes: 15,
        passedLanes: 14,
      );

      final map = report.toMap();
      final restored = VGImageTextureSourceNodeSmokeReport.fromMap(map);
      expect(restored, equals(report));
      expect(restored!.pass, isFalse);
      expect(restored.nativePass, isFalse);
    });

    test('toString includes all key fields', () {
      const report = VGImageTextureSourceNodeSmokeReport(
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
      expect(VGImageTextureSourceNodeSmokeReport.fromMap(null), isNull);
      expect(
        VGImageTextureSourceNodeSmokeReport.fromMap('string_not_map'),
        isNull,
      );
      expect(VGImageTextureSourceNodeSmokeReport.fromMap(12345), isNull);
      expect(VGImageTextureSourceNodeSmokeReport.fromMap(<Object?>[]), isNull);
    });

    test('empty map returns null', () {
      expect(
        VGImageTextureSourceNodeSmokeReport.fromMap(<String, Object?>{}),
        isNull,
      );
    });

    test('missing or invalid pass returns null', () {
      expect(
        VGImageTextureSourceNodeSmokeReport.fromMap(<String, Object?>{
          'raw': 'status=PASS;',
          'proofBoundary': kImageTextureSourceNodeProofBoundary,
          'totalLanes': 15,
          'passedLanes': 15,
        }),
        isNull,
      );
      expect(
        VGImageTextureSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': 'true', // string instead of bool
          'raw': 'status=PASS;',
          'proofBoundary': kImageTextureSourceNodeProofBoundary,
          'totalLanes': 15,
          'passedLanes': 15,
        }),
        isNull,
      );
    });

    test('missing or invalid raw returns null', () {
      expect(
        VGImageTextureSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'proofBoundary': kImageTextureSourceNodeProofBoundary,
          'totalLanes': 15,
          'passedLanes': 15,
        }),
        isNull,
      );
      expect(
        VGImageTextureSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 999, // int instead of string
          'proofBoundary': kImageTextureSourceNodeProofBoundary,
          'totalLanes': 15,
          'passedLanes': 15,
        }),
        isNull,
      );
    });

    test('missing or invalid proofBoundary returns null', () {
      expect(
        VGImageTextureSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'totalLanes': 15,
          'passedLanes': 15,
        }),
        isNull,
      );
      expect(
        VGImageTextureSourceNodeSmokeReport.fromMap(<String, Object?>{
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
        VGImageTextureSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kImageTextureSourceNodeProofBoundary,
          'totalLanes': '15', // string instead of number
          'passedLanes': 15,
        }),
        isNull,
      );
      expect(
        VGImageTextureSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kImageTextureSourceNodeProofBoundary,
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
            VGImageTextureSourceNodeSmokeReport.fromMap(<String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kImageTextureSourceNodeProofBoundary,
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
        VGImageTextureSourceNodeSmokeReport.validateBoundary(
          raw: '',
          proofBoundary: kImageTextureSourceNodeProofBoundary,
        ),
        isTrue,
      );
    });

    test('boundaryOk is true when all 6 tokens are in raw', () {
      expect(
        VGImageTextureSourceNodeSmokeReport.validateBoundary(
          raw: kImageTextureSourceNodeProofBoundary,
          proofBoundary: '',
        ),
        isTrue,
      );
    });

    test(
      'boundaryOk is true when tokens are split across raw and proofBoundary',
      () {
        expect(
          VGImageTextureSourceNodeSmokeReport.validateBoundary(
            raw:
                'platform_neutral image_texture_source_node logical_dag_source',
            proofBoundary:
                'no_texture_ownership no_image_decoder_lifecycle no_product_app_editor_wiring',
          ),
          isTrue,
        );
      },
    );

    test('boundaryOk fails if any of the 6 tokens is missing', () {
      const allTokens = <String>[
        'platform_neutral',
        'image_texture_source_node',
        'logical_dag_source',
        'no_texture_ownership',
        'no_image_decoder_lifecycle',
        'no_product_app_editor_wiring',
      ];

      for (final missingToken in allTokens) {
        final remaining = allTokens.where((t) => t != missingToken).join('_');
        expect(
          VGImageTextureSourceNodeSmokeReport.validateBoundary(
            raw: remaining,
            proofBoundary: '',
          ),
          isFalse,
          reason: 'Token $missingToken was missing but validation passed',
        );

        final report =
            VGImageTextureSourceNodeSmokeReport.fromMap(<String, Object?>{
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
          VGImageTextureSourceNodeSmokeReport.fromMap(<String, Object?>{
            'pass': false,
            'raw': 'status=FAIL;',
            'proofBoundary': kImageTextureSourceNodeProofBoundary,
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
          VGImageTextureSourceNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kImageTextureSourceNodeProofBoundary,
            'totalLanes': 14,
            'passedLanes': 14,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.totalLanes, 14);
    });

    test('pass is false when passedLanes != 15', () {
      final report =
          VGImageTextureSourceNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kImageTextureSourceNodeProofBoundary,
            'totalLanes': 15,
            'passedLanes': 14,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.passedLanes, 14);
    });

    test('pass is true only when all 4 conditions are met', () {
      final report =
          VGImageTextureSourceNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kImageTextureSourceNodeProofBoundary,
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

  group('VGImageTextureSourceNodeSmokeRunner', () {
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
              'runAndroidDagPhase5ImageTextureSourceNodeSmoke',
            );
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;totalLanes=15;passedLanes=15;',
              'proofBoundary': kImageTextureSourceNodeProofBoundary,
              'totalLanes': 15,
              'passedLanes': 15,
            };
          });

      const runner = VGImageTextureSourceNodeSmokeRunner(channel: mockChannel);
      final report = await runner.runSmoke();

      expect(callCount, 1);
      expect(report.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 15);
      expect(report.passedLanes, 15);
      expect(report.proofBoundary, kImageTextureSourceNodeProofBoundary);
    });

    test('runner passes channel override to runSmoke', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kImageTextureSourceNodeProofBoundary,
              'totalLanes': 15,
              'passedLanes': 15,
            };
          });

      const runner = VGImageTextureSourceNodeSmokeRunner();
      final report = await runner.runSmoke(channel: mockChannel);
      expect(report.pass, isTrue);
    });

    test('runner throws StateError when native route returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return null;
          });

      const runner = VGImageTextureSourceNodeSmokeRunner(channel: mockChannel);
      expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
    });

    test(
      'runner throws StateError when native route returns invalid map',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
              return <String, Object?>{'unexpected_key': 42};
            });

        const runner = VGImageTextureSourceNodeSmokeRunner(
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

        const runner = VGImageTextureSourceNodeSmokeRunner(
          channel: mockChannel,
        );
        expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
      },
    );
  });
}
