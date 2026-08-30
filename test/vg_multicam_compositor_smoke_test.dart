// vg_multicam_compositor_smoke_test.dart
// vanguard_media_engine — P3-MULTICAM-NODE: Android True-DAG MultiCamCompositorNode
// native topology + PiP/split layout-math diagnostic smoke Dart model & MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) => {
  'pass': true,
  'decision': 'pass',
  'raw':
      'status=PASS;'
      'nodeOk=true;'
      'pipFreeFloatOk=true;'
      'anchorsOk=true;'
      'splitOk=true;'
      'clampOk=true;'
      'proofBoundary=native_multicam_compositor_node_topology_and_layout_math_only_no_render_no_camera_no_recording',
  'proofBoundary':
      'native_multicam_compositor_node_topology_and_layout_math_only_no_render_no_camera_no_recording',
  'metrics': const <String, String>{
    'status': 'PASS',
    'nodeOk': 'true',
    'pipFreeFloatOk': 'true',
    'anchorsOk': 'true',
    'splitOk': 'true',
    'clampOk': 'true',
    'proofBoundary':
        'native_multicam_compositor_node_topology_and_layout_math_only_no_render_no_camera_no_recording',
  },
  if (overrides != null) ...overrides,
};

VGMultiCamCompositorSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGMultiCamCompositorSmokeReport.fromMap(_createSampleRawMap(overrides));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGMultiCamCompositorSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 3 values in order', () {
      expect(
        VGMultiCamCompositorSmokeDecision.values,
        orderedEquals(const [
          VGMultiCamCompositorSmokeDecision.pass,
          VGMultiCamCompositorSmokeDecision.fail,
          VGMultiCamCompositorSmokeDecision.harnessException,
        ]),
      );
      expect(VGMultiCamCompositorSmokeDecision.values.length, equals(3));
    });

    test('fromRaw maps all known valid decision strings', () {
      expect(
        VGMultiCamCompositorSmokeDecision.fromRaw('pass'),
        equals(VGMultiCamCompositorSmokeDecision.pass),
      );
      expect(
        VGMultiCamCompositorSmokeDecision.fromRaw('PASS'),
        equals(VGMultiCamCompositorSmokeDecision.pass),
      );
      expect(
        VGMultiCamCompositorSmokeDecision.fromRaw('fail'),
        equals(VGMultiCamCompositorSmokeDecision.fail),
      );
      expect(
        VGMultiCamCompositorSmokeDecision.fromRaw('FAIL'),
        equals(VGMultiCamCompositorSmokeDecision.fail),
      );
      expect(
        VGMultiCamCompositorSmokeDecision.fromRaw('harnessException'),
        equals(VGMultiCamCompositorSmokeDecision.harnessException),
      );
      expect(
        VGMultiCamCompositorSmokeDecision.fromRaw('harness_exception'),
        equals(VGMultiCamCompositorSmokeDecision.harnessException),
      );
    });

    test(
      'fromRaw falls back to harnessException for unknown, non-string, or null values',
      () {
        const invalidValues = <Object?>[
          'unknownDecision',
          '',
          null,
          123,
          3.14,
          true,
          <String>[],
          <String, Object?>{},
        ];
        for (final invalid in invalidValues) {
          expect(
            VGMultiCamCompositorSmokeDecision.fromRaw(invalid),
            equals(VGMultiCamCompositorSmokeDecision.harnessException),
          );
        }
      },
    );
  });

  group('VGMultiCamCompositorSmokeReport fromMap and toMap', () {
    test('pass report parses and round-trips all fields cleanly', () {
      final report = VGMultiCamCompositorSmokeReport.fromMap(
        _createSampleRawMap(),
      );

      expect(report.pass, isTrue);
      expect(report.decision, equals(VGMultiCamCompositorSmokeDecision.pass));
      expect(report.isPass, isTrue);
      expect(report.isFail, isFalse);
      expect(report.isHarnessException, isFalse);

      expect(report.nodeTopologyPass, isTrue);
      expect(report.pipFreeFloatingPass, isTrue);
      expect(report.anchorsPass, isTrue);
      expect(report.splitPass, isTrue);
      expect(report.clampPass, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isTrue);

      expect(
        report.proofBoundary,
        equals(
          'native_multicam_compositor_node_topology_and_layout_math_only_no_render_no_camera_no_recording',
        ),
      );
      expect(
        report.raw,
        contains('status=PASS;nodeOk=true;pipFreeFloatOk=true'),
      );
      expect(report.metrics['nodeOk'], equals('true'));
      expect(report.metrics['pipFreeFloatOk'], equals('true'));
      expect(report.metrics['anchorsOk'], equals('true'));
      expect(report.metrics['splitOk'], equals('true'));
      expect(report.metrics['clampOk'], equals('true'));

      final serialized = report.toMap();
      expect(serialized['pass'], isTrue);
      expect(serialized['decision'], equals('pass'));
      expect(serialized['raw'], equals(report.raw));
      expect(serialized['proofBoundary'], equals(report.proofBoundary));
      expect(serialized['metrics'], equals(report.metrics));

      final roundTrip = VGMultiCamCompositorSmokeReport.fromMap(serialized);
      expect(roundTrip, equals(report));
    });

    test('fail report parses failure decision and lanes correctly', () {
      final report = VGMultiCamCompositorSmokeReport.fromMap(
        _createSampleRawMap({
          'pass': false,
          'decision': 'fail',
          'raw':
              'status=FAIL;'
              'nodeOk=true;'
              'pipFreeFloatOk=false;'
              'anchorsOk=true;'
              'splitOk=true;'
              'clampOk=true;'
              'proofBoundary=native_multicam_compositor_node_topology_and_layout_math_only_no_render_no_camera_no_recording',
          'metrics': const <String, String>{
            'status': 'FAIL',
            'nodeOk': 'true',
            'pipFreeFloatOk': 'false',
            'anchorsOk': 'true',
            'splitOk': 'true',
            'clampOk': 'true',
          },
        }),
      );

      expect(report.pass, isFalse);
      expect(report.decision, equals(VGMultiCamCompositorSmokeDecision.fail));
      expect(report.isPass, isFalse);
      expect(report.isFail, isTrue);
      expect(report.isHarnessException, isFalse);

      expect(report.nodeTopologyPass, isTrue);
      expect(report.pipFreeFloatingPass, isFalse);
      expect(report.anchorsPass, isTrue);
      expect(report.splitPass, isTrue);
      expect(report.clampPass, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isFalse);
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in [
        null,
        'not_a_map',
        12345,
        3.14,
        <Object?>['a', 'b'],
      ]) {
        final report = VGMultiCamCompositorSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(
          report.decision,
          equals(VGMultiCamCompositorSmokeDecision.harnessException),
        );
        expect(report.isHarnessException, isTrue);
        expect(report.proofBoundary, isEmpty);
        expect(
          report.metrics,
          equals(const <String, String>{'reason': 'native_result_not_a_map'}),
        );
        expect(report.allNativeLanesPass, isFalse);
        expect(report.hasCanonicalProofBoundary, isFalse);
      }
    });

    test(
      'fromMap handles missing/null/malformed metrics defensively and falls back to raw string',
      () {
        // Missing metrics map, but raw string present -> fallback parse
        final reportFromRaw = VGMultiCamCompositorSmokeReport.fromMap({
          'pass': true,
          'decision': 'pass',
          'raw':
              'status=PASS;nodeOk=true;pipFreeFloatOk=true;anchorsOk=true;splitOk=true;clampOk=true;proofBoundary=native_multicam_compositor_node_topology_and_layout_math_only_no_render_no_camera_no_recording',
          'proofBoundary':
              'native_multicam_compositor_node_topology_and_layout_math_only_no_render_no_camera_no_recording',
        });
        expect(reportFromRaw.pass, isTrue);
        expect(reportFromRaw.nodeTopologyPass, isTrue);
        expect(reportFromRaw.pipFreeFloatingPass, isTrue);
        expect(reportFromRaw.anchorsPass, isTrue);
        expect(reportFromRaw.splitPass, isTrue);
        expect(reportFromRaw.clampPass, isTrue);
        expect(reportFromRaw.allNativeLanesPass, isTrue);
        expect(reportFromRaw.hasCanonicalProofBoundary, isTrue);

        // Malformed non-string metric map entries converted to string
        final reportWithHeterogeneousMetrics =
            VGMultiCamCompositorSmokeReport.fromMap({
              'pass': true,
              'decision': 'pass',
              'metrics': <Object?, Object?>{
                'nodeOk': 'true',
                'pipFreeFloatOk': true,
                'anchorsOk': 'true',
                'splitOk': 'true',
                'clampOk': 'true',
                123: 456,
              },
            });
        expect(reportWithHeterogeneousMetrics.pass, isTrue);
        expect(reportWithHeterogeneousMetrics.nodeTopologyPass, isTrue);
        expect(reportWithHeterogeneousMetrics.anchorsPass, isTrue);
        expect(reportWithHeterogeneousMetrics.metrics['123'], equals('456'));

        // Entirely null map
        final reportNullMap = VGMultiCamCompositorSmokeReport.fromMap({
          for (final key in _createSampleRawMap().keys) key: null,
        });
        expect(reportNullMap.pass, isFalse);
        expect(
          reportNullMap.decision,
          equals(VGMultiCamCompositorSmokeDecision.harnessException),
        );
        expect(reportNullMap.raw, isEmpty);
        expect(reportNullMap.proofBoundary, isEmpty);
        expect(reportNullMap.metrics, isEmpty);
      },
    );
  });

  group('VGMultiCamCompositorSmokeReport lane getters', () {
    test('lane getters strictly reflect metric keys', () {
      final reportPass = _createSampleReport();
      expect(reportPass.nodeTopologyPass, isTrue);
      expect(reportPass.pipFreeFloatingPass, isTrue);
      expect(reportPass.anchorsPass, isTrue);
      expect(reportPass.splitPass, isTrue);
      expect(reportPass.clampPass, isTrue);
      expect(reportPass.hasCanonicalProofBoundary, isTrue);
      expect(reportPass.allNativeLanesPass, isTrue);

      final reportNodeFail = _createSampleReport({
        'metrics': {'nodeOk': 'false'},
      });
      expect(reportNodeFail.nodeTopologyPass, isFalse);
      expect(reportNodeFail.allNativeLanesPass, isFalse);

      final reportPipFail = _createSampleReport({
        'metrics': {'pipFreeFloatOk': 'false'},
      });
      expect(reportPipFail.pipFreeFloatingPass, isFalse);
      expect(reportPipFail.allNativeLanesPass, isFalse);

      final reportAnchorsFail = _createSampleReport({
        'metrics': {'anchorsOk': 'false'},
      });
      expect(reportAnchorsFail.anchorsPass, isFalse);
      expect(reportAnchorsFail.allNativeLanesPass, isFalse);

      final reportSplitFail = _createSampleReport({
        'metrics': {'splitOk': 'false'},
      });
      expect(reportSplitFail.splitPass, isFalse);
      expect(reportSplitFail.allNativeLanesPass, isFalse);

      final reportClampFail = _createSampleReport({
        'metrics': {'clampOk': 'false'},
      });
      expect(reportClampFail.clampPass, isFalse);
      expect(reportClampFail.allNativeLanesPass, isFalse);

      final reportBadProofBoundary = _createSampleReport({
        'proofBoundary': 'incorrect_proof_boundary',
      });
      expect(reportBadProofBoundary.hasCanonicalProofBoundary, isFalse);
    });
  });

  group('VGMultiCamCompositorSmokeReport value semantics', () {
    test('identical instances and identical values evaluate equal', () {
      final a = _createSampleReport();
      final b = _createSampleReport();

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGMultiCamCompositorSmokeReport('));
      expect(a.toString(), contains('pass: true'));
      expect(
        a.toString(),
        contains('decision: VGMultiCamCompositorSmokeDecision.pass'),
      );
      expect(
        a.toString(),
        contains(
          'proofBoundary: native_multicam_compositor_node_topology_and_layout_math_only_no_render_no_camera_no_recording',
        ),
      );
    });

    test(
      'stable metrics hash produces equal hash and equality with different map key order',
      () {
        final report1 = _createSampleReport({
          'metrics': const {'alpha': '1', 'beta': '2', 'gamma': '3'},
        });
        final report2 = _createSampleReport({
          'metrics': const {'gamma': '3', 'alpha': '1', 'beta': '2'},
        });

        expect(report1, equals(report2));
        expect(report1.hashCode, equals(report2.hashCode));
      },
    );

    test('inequality when any single field differs', () {
      final base = _createSampleReport();
      const diffs = <Map<String, Object?>>[
        {'pass': false},
        {'decision': 'fail'},
        {'raw': 'status=FAIL'},
        {'proofBoundary': 'other_boundary'},
        {
          'metrics': <String, String>{'nodeOk': 'false'},
        },
      ];

      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)));
        expect(base.hashCode, isNot(equals(variant.hashCode)));
      }
    });
  });

  group('MethodChannel runner invocation', () {
    test(
      'invokes runAndroidDagPhase3MultiCamCompositorSmoke successfully',
      () async {
        MethodCall? capturedCall;
        const channel = MethodChannel('test_multicam_smoke_channel');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGMultiCamCompositorSmokeReport.runAndroidDagPhase3MultiCamCompositorSmoke(
              channel: channel,
            );

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase3MultiCamCompositorSmoke'),
        );
        expect(report.pass, isTrue);
        expect(report.decision, equals(VGMultiCamCompositorSmokeDecision.pass));
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test('uses default vanguard_media_engine channel when omitted', () async {
      MethodCall? capturedCall;
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGMultiCamCompositorSmokeReport.runAndroidDagPhase3MultiCamCompositorSmoke();

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('runAndroidDagPhase3MultiCamCompositorSmoke'),
      );
      expect(report.pass, isTrue);
    });

    test(
      'handles PlatformException safely returning harnessException report',
      () async {
        const channel = MethodChannel('test_multicam_smoke_platform_exception');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'NATIVE_CRASH',
            message: 'Simulated JNI error',
          );
        });

        final report =
            await VGMultiCamCompositorSmokeReport.runAndroidDagPhase3MultiCamCompositorSmoke(
              channel: channel,
            );

        expect(report.pass, isFalse);
        expect(
          report.decision,
          equals(VGMultiCamCompositorSmokeDecision.harnessException),
        );
        expect(report.isHarnessException, isTrue);
        expect(report.raw, contains('platform_exception:NATIVE_CRASH'));
        expect(report.metrics['code'], equals('NATIVE_CRASH'));
        expect(report.metrics['message'], equals('Simulated JNI error'));
        expect(report.allNativeLanesPass, isFalse);
      },
    );

    test('handles timeout safely returning harnessException report', () async {
      const channel = MethodChannel('test_multicam_smoke_timeout');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        // Intentionally delay longer than the timeout
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });

      final report =
          await VGMultiCamCompositorSmokeReport.runAndroidDagPhase3MultiCamCompositorSmoke(
            timeout: const Duration(milliseconds: 20),
            channel: channel,
          );

      expect(report.pass, isFalse);
      expect(
        report.decision,
        equals(VGMultiCamCompositorSmokeDecision.harnessException),
      );
      expect(report.isHarnessException, isTrue);
      expect(report.raw, contains('status=FAIL;reason=timeout'));
      expect(report.metrics['reason'], equals('timeout'));
      expect(report.allNativeLanesPass, isFalse);
    });

    test(
      'handles generic exception safely returning harnessException report',
      () async {
        const channel = MethodChannel('test_multicam_smoke_generic_exception');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw StateError('Generic unexpected error');
        });

        final report =
            await VGMultiCamCompositorSmokeReport.runAndroidDagPhase3MultiCamCompositorSmoke(
              channel: channel,
            );

        expect(report.pass, isFalse);
        expect(
          report.decision,
          equals(VGMultiCamCompositorSmokeDecision.harnessException),
        );
        expect(report.isHarnessException, isTrue);
        expect(report.raw, contains('status=FAIL;reason='));
        expect(report.allNativeLanesPass, isFalse);
      },
    );
  });
}
