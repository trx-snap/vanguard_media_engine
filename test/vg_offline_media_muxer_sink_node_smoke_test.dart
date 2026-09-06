// vg_offline_media_muxer_sink_node_smoke_test.dart
// vanguard_media_engine -- P2-OFFLINE-MEDIA-MUXER-SINK-NODE-A
// Unit tests for VGOfflineMediaMuxerSinkNodeSmokeReport and VGOfflineMediaMuxerSinkNodeSmokeRunner.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_offline_media_muxer_sink_node_smoke.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Constants', () {
    test('canonical method channel name matches native declaration', () {
      expect(
        kOfflineMediaMuxerSinkNodeMethodName,
        'runAndroidDagPhase2OfflineMediaMuxerSinkNodeSmoke',
      );
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.methodName,
        'runAndroidDagPhase2OfflineMediaMuxerSinkNodeSmoke',
      );
    });

    test('canonical proof boundary constant matches expected boundary', () {
      const expected =
          'platform_neutral_offline_media_muxer_sink_node_logical_dag_sink_'
          'no_muxer_ownership_no_android_lifecycle_'
          'no_product_app_editor_wiring';
      expect(kOfflineMediaMuxerSinkNodeProofBoundary, expected);
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.requiredProofBoundary,
        expected,
      );
    });

    test('physical smoke markers match required protocol strings', () {
      expect(
        kOfflineMediaMuxerSinkNodeStartMarker,
        'ANDROID_DAG_PHASE2_OFFLINE_MEDIA_MUXER_SINK_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.startMarker,
        'ANDROID_DAG_PHASE2_OFFLINE_MEDIA_MUXER_SINK_NODE_PHYSICAL_SMOKE_START',
      );
      expect(
        kOfflineMediaMuxerSinkNodePassMarker,
        'ANDROID_DAG_PHASE2_OFFLINE_MEDIA_MUXER_SINK_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.passMarker,
        'ANDROID_DAG_PHASE2_OFFLINE_MEDIA_MUXER_SINK_NODE_PHYSICAL_SMOKE_PASS',
      );
      expect(
        kOfflineMediaMuxerSinkNodeFailMarker,
        'ANDROID_DAG_PHASE2_OFFLINE_MEDIA_MUXER_SINK_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.failMarker,
        'ANDROID_DAG_PHASE2_OFFLINE_MEDIA_MUXER_SINK_NODE_PHYSICAL_SMOKE_FAIL',
      );
      expect(
        kOfflineMediaMuxerSinkNodeJsonPrefix,
        'ANDROID_DAG_PHASE2_OFFLINE_MEDIA_MUXER_SINK_NODE_JSON:',
      );
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.jsonPrefix,
        'ANDROID_DAG_PHASE2_OFFLINE_MEDIA_MUXER_SINK_NODE_JSON:',
      );
    });

    test('lane count constants match 16', () {
      expect(kOfflineMediaMuxerSinkNodeExpectedTotalLanes, 16);
      expect(kOfflineMediaMuxerSinkNodeExpectedPassedLanes, 16);
      expect(VGOfflineMediaMuxerSinkNodeSmokeReport.expectedTotalLanes, 16);
      expect(VGOfflineMediaMuxerSinkNodeSmokeReport.expectedPassedLanes, 16);
    });

    test('required boundary tokens contains all 6 mandatory tokens', () {
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.requiredBoundaryTokens,
        containsAll(<String>[
          'platform_neutral',
          'offline_media_muxer_sink_node',
          'logical_dag_sink',
          'no_muxer_ownership',
          'no_android_lifecycle',
          'no_product_app_editor_wiring',
        ]),
      );
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.requiredBoundaryTokens.length,
        6,
      );
    });
  });

  group('fromMap and toMap roundtrip', () {
    test('successfully parses native result map with pass == true', () {
      final nativeMap = <String, Object?>{
        'pass': true,
        'raw':
            'status=PASS;totalLanes=16;passedLanes=16;'
            'proofBoundary=$kOfflineMediaMuxerSinkNodeProofBoundary',
        'proofBoundary': kOfflineMediaMuxerSinkNodeProofBoundary,
        'totalLanes': 16,
        'passedLanes': 16,
      };

      final report = VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(nativeMap);
      expect(report, isNotNull);
      expect(report!.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 16);
      expect(report.passedLanes, 16);
      expect(report.proofBoundary, kOfflineMediaMuxerSinkNodeProofBoundary);

      final map = report.toMap();
      expect(map['pass'], isTrue);
      expect(map['nativePass'], isTrue);
      expect(map['boundaryOk'], isTrue);
      expect(map['totalLanes'], 16);
      expect(map['passedLanes'], 16);
      expect(map['proofBoundary'], kOfflineMediaMuxerSinkNodeProofBoundary);

      final roundTrip = VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(map);
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
      expect(roundTrip!.pass, isTrue);
    });

    test('roundtrip preserves failing nativePass', () {
      const report = VGOfflineMediaMuxerSinkNodeSmokeReport(
        pass: false,
        nativePass: false,
        boundaryOk: true,
        raw: 'status=FAIL;',
        proofBoundary: kOfflineMediaMuxerSinkNodeProofBoundary,
        totalLanes: 16,
        passedLanes: 15,
      );

      final map = report.toMap();
      final restored = VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(map);
      expect(restored, equals(report));
      expect(restored!.pass, isFalse);
      expect(restored.nativePass, isFalse);
    });

    test('toString includes all key fields', () {
      const report = VGOfflineMediaMuxerSinkNodeSmokeReport(
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
      expect(VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(null), isNull);
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap('string_not_map'),
        isNull,
      );
      expect(VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(12345), isNull);
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<Object?>[]),
        isNull,
      );
    });

    test('empty map returns null', () {
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<String, Object?>{}),
        isNull,
      );
    });

    test('missing or invalid pass returns null', () {
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<String, Object?>{
          'raw': 'status=PASS;',
          'proofBoundary': kOfflineMediaMuxerSinkNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': 'true', // string instead of bool
          'raw': 'status=PASS;',
          'proofBoundary': kOfflineMediaMuxerSinkNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
    });

    test('missing or invalid raw returns null', () {
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'proofBoundary': kOfflineMediaMuxerSinkNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 999, // int instead of string
          'proofBoundary': kOfflineMediaMuxerSinkNodeProofBoundary,
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
    });

    test('missing or invalid proofBoundary returns null', () {
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'totalLanes': 16,
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<String, Object?>{
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
        VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kOfflineMediaMuxerSinkNodeProofBoundary,
          'totalLanes': '16', // string instead of number
          'passedLanes': 16,
        }),
        isNull,
      );
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<String, Object?>{
          'pass': true,
          'raw': 'status=PASS;',
          'proofBoundary': kOfflineMediaMuxerSinkNodeProofBoundary,
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
            VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kOfflineMediaMuxerSinkNodeProofBoundary,
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
        VGOfflineMediaMuxerSinkNodeSmokeReport.validateBoundary(
          raw: '',
          proofBoundary: kOfflineMediaMuxerSinkNodeProofBoundary,
        ),
        isTrue,
      );
    });

    test('boundaryOk is true when all 6 tokens are in raw', () {
      expect(
        VGOfflineMediaMuxerSinkNodeSmokeReport.validateBoundary(
          raw: kOfflineMediaMuxerSinkNodeProofBoundary,
          proofBoundary: '',
        ),
        isTrue,
      );
    });

    test(
      'boundaryOk is true when tokens are split across raw and proofBoundary',
      () {
        expect(
          VGOfflineMediaMuxerSinkNodeSmokeReport.validateBoundary(
            raw:
                'platform_neutral offline_media_muxer_sink_node logical_dag_sink',
            proofBoundary:
                'no_muxer_ownership no_android_lifecycle no_product_app_editor_wiring',
          ),
          isTrue,
        );
      },
    );

    test('boundaryOk fails if any of the 6 tokens is missing', () {
      const allTokens = <String>[
        'platform_neutral',
        'offline_media_muxer_sink_node',
        'logical_dag_sink',
        'no_muxer_ownership',
        'no_android_lifecycle',
        'no_product_app_editor_wiring',
      ];

      for (final missingToken in allTokens) {
        final remaining = allTokens.where((t) => t != missingToken).join('_');
        expect(
          VGOfflineMediaMuxerSinkNodeSmokeReport.validateBoundary(
            raw: remaining,
            proofBoundary: '',
          ),
          isFalse,
          reason: 'Token $missingToken was missing but validation passed',
        );

        final report =
            VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<String, Object?>{
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
          VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<String, Object?>{
            'pass': false,
            'raw': 'status=FAIL;',
            'proofBoundary': kOfflineMediaMuxerSinkNodeProofBoundary,
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
          VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kOfflineMediaMuxerSinkNodeProofBoundary,
            'totalLanes': 15,
            'passedLanes': 15,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.totalLanes, 15);
    });

    test('pass is false when passedLanes != 16', () {
      final report =
          VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kOfflineMediaMuxerSinkNodeProofBoundary,
            'totalLanes': 16,
            'passedLanes': 15,
          });
      expect(report, isNotNull);
      expect(report!.pass, isFalse);
      expect(report.passedLanes, 15);
    });

    test('pass is true only when all 4 conditions are met', () {
      final report =
          VGOfflineMediaMuxerSinkNodeSmokeReport.fromMap(<String, Object?>{
            'pass': true,
            'raw': 'status=PASS;',
            'proofBoundary': kOfflineMediaMuxerSinkNodeProofBoundary,
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

  group('VGOfflineMediaMuxerSinkNodeSmokeRunner', () {
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
              'runAndroidDagPhase2OfflineMediaMuxerSinkNodeSmoke',
            );
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;totalLanes=16;passedLanes=16;',
              'proofBoundary': kOfflineMediaMuxerSinkNodeProofBoundary,
              'totalLanes': 16,
              'passedLanes': 16,
            };
          });

      const runner = VGOfflineMediaMuxerSinkNodeSmokeRunner(
        channel: mockChannel,
      );
      final report = await runner.runSmoke();

      expect(callCount, 1);
      expect(report.pass, isTrue);
      expect(report.nativePass, isTrue);
      expect(report.boundaryOk, isTrue);
      expect(report.totalLanes, 16);
      expect(report.passedLanes, 16);
      expect(report.proofBoundary, kOfflineMediaMuxerSinkNodeProofBoundary);
    });

    test('runner passes channel override to runSmoke', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return <String, Object?>{
              'pass': true,
              'raw': 'status=PASS;',
              'proofBoundary': kOfflineMediaMuxerSinkNodeProofBoundary,
              'totalLanes': 16,
              'passedLanes': 16,
            };
          });

      const runner = VGOfflineMediaMuxerSinkNodeSmokeRunner();
      final report = await runner.runSmoke(channel: mockChannel);
      expect(report.pass, isTrue);
    });

    test('runner throws StateError when native route returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(mockChannel, (MethodCall call) async {
            return null;
          });

      const runner = VGOfflineMediaMuxerSinkNodeSmokeRunner(
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

        const runner = VGOfflineMediaMuxerSinkNodeSmokeRunner(
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

        const runner = VGOfflineMediaMuxerSinkNodeSmokeRunner(
          channel: mockChannel,
        );
        expect(() => runner.runSmoke(), throwsA(isA<StateError>()));
      },
    );
  });
}
