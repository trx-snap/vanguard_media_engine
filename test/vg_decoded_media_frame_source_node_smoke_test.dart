// vg_decoded_media_frame_source_node_smoke_test.dart
// vanguard_media_engine -- P2-DECODED-MEDIA-FRAME-SOURCE-NODE-A
// Unit tests for VGDecodedMediaFrameSourceNodeSmokeReport and VGDecodedMediaFrameSourceNodeSmokeRunner.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_decoded_media_frame_source_node_smoke.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Constants', () {
    test('canonical method channel name matches native declaration', () {
      expect(
        kDecodedMediaFrameSourceNodeMethodName,
        'runAndroidDagPhase2DecodedMediaFrameSourceNodeSmoke',
      );
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.methodName,
        'runAndroidDagPhase2DecodedMediaFrameSourceNodeSmoke',
      );
    });

    test('canonical proof boundary constant matches expected boundary', () {
      const expected =
          'platform_neutral_decoded_media_frame_source_node_logical_dag_source_'
          'no_decoder_framebuffer_ownership_no_android_lifecycle_no_product_app_editor_wiring';
      expect(kDecodedMediaFrameSourceNodeProofBoundary, expected);
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.requiredProofBoundary,
        expected,
      );
    });

    test('physical smoke markers match required protocol strings', () {
      expect(
        kDecodedMediaFrameSourceNodeStartMarker,
        'ANDROID_DAG_PHASE2_DECODED_MEDIA_FRAME_SOURCE_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.startMarker,
        'ANDROID_DAG_PHASE2_DECODED_MEDIA_FRAME_SOURCE_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        kDecodedMediaFrameSourceNodePassMarker,
        'ANDROID_DAG_PHASE2_DECODED_MEDIA_FRAME_SOURCE_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.passMarker,
        'ANDROID_DAG_PHASE2_DECODED_MEDIA_FRAME_SOURCE_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        kDecodedMediaFrameSourceNodeFailMarker,
        'ANDROID_DAG_PHASE2_DECODED_MEDIA_FRAME_SOURCE_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.failMarker,
        'ANDROID_DAG_PHASE2_DECODED_MEDIA_FRAME_SOURCE_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        kDecodedMediaFrameSourceNodeJsonPrefix,
        'ANDROID_DAG_PHASE2_DECODED_MEDIA_FRAME_SOURCE_NODE_JSON:',
      );
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.jsonPrefix,
        'ANDROID_DAG_PHASE2_DECODED_MEDIA_FRAME_SOURCE_NODE_JSON:',
      );
    });

    test('lane count constants match 13', () {
      expect(kDecodedMediaFrameSourceNodeExpectedTotalLanes, 13);
      expect(kDecodedMediaFrameSourceNodeExpectedPassedLanes, 13);
      expect(VGDecodedMediaFrameSourceNodeSmokeReport.expectedTotalLanes, 13);
      expect(VGDecodedMediaFrameSourceNodeSmokeReport.expectedPassedLanes, 13);
    });

    test('required boundary tokens contains all 6 mandatory tokens', () {
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.requiredBoundaryTokens,
        containsAll(<String>[
          'platform_neutral',
          'decoded_media_frame_source_node',
          'logical_dag_source',
          'no_decoder_framebuffer_ownership',
          'no_android_lifecycle',
          'no_product_app_editor_wiring',
        ]),
      );
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.requiredBoundaryTokens.length,
        6,
      );
    });
  });

  group('fromMap and toMap roundtrip', () {
    test('successfully parses native result map with pass == true', () {
      final nativeMap = <String, Object?>{
        'pass': true,
        'raw':
            'status=PASS;totalLanes=13;passedLanes=13;'
            'proofBoundary=$kDecodedMediaFrameSourceNodeProofBoundary',
        'proofBoundary': kDecodedMediaFrameSourceNodeProofBoundary,
        'totalLanes': 13,
        'passedLanes': 13,
      };

      final report = VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(
        nativeMap,
      );
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 13);
      expect(report.passedLanes, 13);
      expect(report.proofBoundary, kDecodedMediaFrameSourceNodeProofBoundary);

      final map = report.toMap();
      expect(map['pass'], isTrue);
      expect(map['nativePass'], isTrue);
      expect(map['boundaryOk'], isTrue);
      expect(map['totalLanes'], 13);
      expect(map['passedLanes'], 13);
      expect(map['proofBoundary'], kDecodedMediaFrameSourceNodeProofBoundary);

      final roundTrip = VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(map);
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
      expect(roundTrip!.pass, isTrue);
    });

    test('roundtrip preserves failing nativePass', () {
      const report = VGDecodedMediaFrameSourceNodeSmokeReport(
        pass: false,
        nativePass: false,
        boundaryOk: true,
        raw: 'status=FAIL;',
        proofBoundary: kDecodedMediaFrameSourceNodeProofBoundary,
        totalLanes: 13,
        passedLanes: 12,
      );

      final map = report.toMap();
      final restored = VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(map);
      expect(restored, equals(report));
      expect(restored!.pass, isFalse);
      expect(restored.nativePass, isFalse);
    });

    test('toString includes all key fields', () {
      const report = VGDecodedMediaFrameSourceNodeSmokeReport(
        pass: true,
        nativePass: true,
        boundaryOk: true,
        raw: 'status=PASS;',
        proofBoundary: 'boundary',
        totalLanes: 13,
        passedLanes: 13,
      );
      final str = report.toString();
      expect(str, contains('pass: true'));
      expect(str, contains('nativePass: true'));
      expect(str, contains('boundaryOk: true'));
      expect(str, contains('totalLanes: 13'));
      expect(str, contains('passedLanes: 13'));
    });
  });

  group('Invalid map handling', () {
    test('non-map or null inputs return null', () {
      expect(VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(null), isNull);
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.fromMap('string_not_map'),
        isNull,
      );
      expect(VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(12345), isNull);
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<Object?>[]),
        isNull,
      );
    });

    test('empty map returns null', () {
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<String, Object?>{}),
        isNull,
      );
    });

    test('missing or invalid pass returns null', () {
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<String, Object?>{
          'raw': 'status=PASS;',
          'proofBoundary': kDecodedMediaFrameSourceNodeProofBoundary,
          'totalLanes': 13,
          'passedLanes': 13,
        }),
        isNull,
      );
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': 'true', // string instead of bool
          'raw': 'status=PASS;',
          'proofBoundary': kDecodedMediaFrameSourceNodeProofBoundary,
          'totalLanes': 13,
          'passedLanes': 13,
        }),
        isNull,
      );
    });

    test('missing or invalid raw returns null', () {
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'proofBoundary': kDecodedMediaFrameSourceNodeProofBoundary,
          'totalLanes': 13,
          'passedLanes': 13,
        }),
        isNull,
      );
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 999, // int instead of string
          'proofBoundary': kDecodedMediaFrameSourceNodeProofBoundary,
          'totalLanes': 13,
          'passedLanes': 13,
        }),
        isNull,
      );
    });

    test('missing or invalid proofBoundary returns null', () {
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'totalLanes': 13,
          'passedLanes': 13,
        }),
        isNull,
      );
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': true, // bool instead of string
          'totalLanes': 13,
          'passedLanes': 13,
        }),
        isNull,
      );
    });

    test('non-numeric totalLanes or passedLanes returns null', () {
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kDecodedMediaFrameSourceNodeProofBoundary,
          'totalLanes': '13', // string instead of number
          'passedLanes': 13,
        }),
        isNull,
      );
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kDecodedMediaFrameSourceNodeProofBoundary,
          'totalLanes': 13,
          'passedLanes': false, // bool instead of number
        }),
        isNull,
      );
    });

    test(
      'absent totalLanes and passedLanes default to 0 and pass is false',
      () {
        final report =
            VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kDecodedMediaFrameSourceNodeProofBoundary,
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
        VGDecodedMediaFrameSourceNodeSmokeReport.validateBoundary(
          raw: '',
          proofBoundary: kDecodedMediaFrameSourceNodeProofBoundary,
        ),
        isTrue,
      );
    });

    test('boundaryOk is true when all 6 tokens are in raw', () {
      expect(
        VGDecodedMediaFrameSourceNodeSmokeReport.validateBoundary(
          raw: kDecodedMediaFrameSourceNodeProofBoundary,
          proofBoundary: '',
        ),
        isTrue,
      );
    });

    test(
      'boundaryOk is true when tokens are split across raw and proofBoundary',
      () {
        expect(
          VGDecodedMediaFrameSourceNodeSmokeReport.validateBoundary(
            raw:
                'platform_neutral decoded_media_frame_source_node logical_dag_source',
            proofBoundary:
                'no_decoder_framebuffer_ownership no_android_lifecycle no_product_app_editor_wiring',
          ),
          isTrue,
        );
      },
    );

    test('boundaryOk fails if any of the 6 tokens is missing', () {
      const allTokens = <String>[
        'platform_neutral',
        'decoded_media_frame_source_node',
        'logical_dag_source',
        'no_decoder_framebuffer_ownership',
        'no_android_lifecycle',
        'no_product_app_editor_wiring',
      ];

      for (final missingToken in allTokens) {
        final remaining = allTokens.where((t) => t != missingToken).join('_');
        expect(
          VGDecodedMediaFrameSourceNodeSmokeReport.validateBoundary(
            raw: remaining,
            proofBoundary: '',
          ),
          isFalse,
          reason: 'Token $missingToken was missing but validation passed',
        );

        final report =
            VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<String, Object?>{
              'pass': true,
              'raw': remaining,
              'proofBoundary': remaining,
              'totalLanes': 13,
              'passedLanes': 13,
            });
        expect(report, isNotNull);
        expect(report!.boundaryOk, isFalse);
        expect(report.pass, isFalse);
      }
    });

    test('pass is false when nativePass is false', () {
      final report =
          VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<String, Object?>{
            'pass': false,
            'raw': 'status=FAIL;',
            'proofBoundary': kDecodedMediaFrameSourceNodeProofBoundary,
            'totalLanes': 13,
            'passedLanes': 13,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.nativePass, isFalse);
      expect(report.boundaryOk, isTrue);
    });

    test('pass is false when totalLanes != 13', () {
      final report =
          VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kDecodedMediaFrameSourceNodeProofBoundary,
            'totalLanes': 12,
            'passedLanes': 12,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.totalLanes, 12);
    });

    test('pass is false when passedLanes != 13', () {
      final report =
          VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kDecodedMediaFrameSourceNodeProofBoundary,
            'totalLanes': 13,
            'passedLanes': 12,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.passedLanes, 12);
    });

    test('pass is true only when all 4 conditions are met', () {
      final report =
          VGDecodedMediaFrameSourceNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kDecodedMediaFrameSourceNodeProofBoundary,
            'totalLanes': 13,
            'passedLanes': 13,
          });
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 13);
      expect(report.passedLanes, 13);
    });
  });

  group('VGDecodedMediaFrameSourceNodeSmokeRunner', () {
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
              'runAndroidDagPhase2DecodedMediaFrameSourceNodeSmoke',
            );
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;totalLanes=13;passedLanes=13;',
              'proofBoundary': kDecodedMediaFrameSourceNodeProofBoundary,
              'totalLanes': 13,
              'passedLanes': 13,
            };
          });

      const runner = VGDecodedMediaFrameSourceNodeSmokeRunner(
        channel: mockChannel,
      );
      final report = await runner.runSmoke();

      expect(callCount, 1);
      expect(report.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 13);
      expect(report.passedLanes, 13);
      expect(report.proofBoundary, kDecodedMediaFrameSourceNodeProofBoundary);
    });

    test('runner passes channel override to runSmoke', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kDecodedMediaFrameSourceNodeProofBoundary,
              'totalLanes': 13,
              'passedLanes': 13,
            };
          });

      const runner = VGDecodedMediaFrameSourceNodeSmokeRunner();
      final report = await runner.runSmoke(channel: mockChannel);
      expect(report.pass, isTrue);
    });

    test('runner throws StateError when native route returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return null;
          });

      const runner = VGDecodedMediaFrameSourceNodeSmokeRunner(
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

        const runner = VGDecodedMediaFrameSourceNodeSmokeRunner(
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

        const runner = VGDecodedMediaFrameSourceNodeSmokeRunner(
          channel: mockChannel,
        );
        expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
      },
    );
  });
}
