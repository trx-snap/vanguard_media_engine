// vg_timeline_compositor_smoke_test.dart
// vanguard_media_engine — P5-COMPOSITOR-TRANS (sub-slice NODE-TOPOLOGY-MATH):
// Android True-DAG VGTimelineCompositorNode native topology + transition-math
// diagnostic smoke Dart model & MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_timeline_compositor_smoke.dart';

const String _proofBoundary =
    'native_vg_timeline_compositor_node_topology_and_transition_math_only_no_render_no_decode';
const String _passMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_COMPOSITOR_NODE_TOPOLOGY_MATH_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_COMPOSITOR_NODE_TOPOLOGY_MATH_PHYSICAL_SMOKE_FAIL';
const String _method = 'runAndroidDagPhase5TimelineCompositorSmoke';

const List<String> _gateKeys = <String>[
  'kindOk',
  'typeOk',
  'inputPortCountOk',
  'outputPortCountOk',
  'portIdsOk',
  'hardCutOk',
  'crossfadeStartOk',
  'crossfadeMidOk',
  'crossfadeEndOk',
  'slideLeftMidOk',
  'wipeLeftMidOk',
  'speedMappingOk',
  'outsideTimelineOk',
  'invalidTransitionIgnoredOk',
  'zeroDurationSafeOk',
  'overflowSafeOk',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) => {
  'pass': true,
  'status': 'PASS',
  'marker': _passMarker,
  'proofBoundary': _proofBoundary,
  'failureReason': '',
  for (final key in _gateKeys) key: true,
  'allNativeLanesPass': true,
  'details': const <String, Object?>{
    'inputPortCount': '2',
    'outputPortCount': '1',
    'inputPort0': 'clip_0_video_in',
    'inputPort1': 'clip_1_video_in',
    'outputPort0': 'composited_video_out',
    'crossfadeEndPolicy': 'end_exclusive_window_to_clip_solo',
    'zeroDurationPolicy': 'zero_duration_transition_never_active_hard_cut',
    'overlapWithoutTransitionPolicy': 'later_start_clip_wins',
  },
  'raw': '{"pass":true,"status":"PASS"}',
  if (overrides != null) ...overrides,
};

VGTimelineCompositorSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGTimelineCompositorSmokeReport.fromMap(_createSampleRawMap(overrides));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('contract constants', () {
    test('canonical strings and gate keys match the frozen contract', () {
      expect(
        VGTimelineCompositorSmokeReport.proofBoundaryConstant,
        equals(_proofBoundary),
      );
      expect(VGTimelineCompositorSmokeReport.passMarker, equals(_passMarker));
      expect(VGTimelineCompositorSmokeReport.failMarker, equals(_failMarker));
      expect(VGTimelineCompositorSmokeReport.methodName, equals(_method));
      expect(
        VGTimelineCompositorSmokeReport.allGateKeys,
        orderedEquals(_gateKeys),
      );
      expect(VGTimelineCompositorSmokeReport.topologyGateKeys.length, 5);
      expect(VGTimelineCompositorSmokeReport.mathGateKeys.length, 11);
    });
  });

  group('VGTimelineCompositorSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 4 values in order', () {
      expect(
        VGTimelineCompositorSmokeDecision.values,
        orderedEquals(const [
          VGTimelineCompositorSmokeDecision.pass,
          VGTimelineCompositorSmokeDecision.fail,
          VGTimelineCompositorSmokeDecision.unsupported,
          VGTimelineCompositorSmokeDecision.harnessException,
        ]),
      );
    });

    test('fromRaw maps all known decision strings', () {
      expect(
        VGTimelineCompositorSmokeDecision.fromRaw('pass'),
        VGTimelineCompositorSmokeDecision.pass,
      );
      expect(
        VGTimelineCompositorSmokeDecision.fromRaw('PASS'),
        VGTimelineCompositorSmokeDecision.pass,
      );
      expect(
        VGTimelineCompositorSmokeDecision.fromRaw('fail'),
        VGTimelineCompositorSmokeDecision.fail,
      );
      expect(
        VGTimelineCompositorSmokeDecision.fromRaw('UNSUPPORTED'),
        VGTimelineCompositorSmokeDecision.unsupported,
      );
      expect(
        VGTimelineCompositorSmokeDecision.fromRaw('harnessException'),
        VGTimelineCompositorSmokeDecision.harnessException,
      );
      expect(
        VGTimelineCompositorSmokeDecision.fromRaw('harness_exception'),
        VGTimelineCompositorSmokeDecision.harnessException,
      );
    });

    test('fromRaw falls back to harnessException for unknown values', () {
      for (final invalid in <Object?>['bogus', '', null, 1, 2.0, true, []]) {
        expect(
          VGTimelineCompositorSmokeDecision.fromRaw(invalid),
          VGTimelineCompositorSmokeDecision.harnessException,
        );
      }
    });
  });

  group('VGTimelineCompositorSmokeReport fromMap / toMap', () {
    test('pass report parses every gate and round-trips', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(report.decision, VGTimelineCompositorSmokeDecision.pass);
      expect(report.isPass, isTrue);
      expect(report.isFail, isFalse);
      expect(report.isUnsupported, isFalse);
      expect(report.isHarnessException, isFalse);
      expect(report.status, 'PASS');
      expect(report.marker, _passMarker);
      expect(report.proofBoundary, _proofBoundary);
      expect(report.failureReason, isEmpty);

      // Topology gates.
      expect(report.kindPass, isTrue);
      expect(report.typePass, isTrue);
      expect(report.inputPortCountPass, isTrue);
      expect(report.outputPortCountPass, isTrue);
      expect(report.portIdsPass, isTrue);
      expect(report.topologyPass, isTrue);

      // Math gates.
      expect(report.hardCutPass, isTrue);
      expect(report.crossfadeStartPass, isTrue);
      expect(report.crossfadeMidPass, isTrue);
      expect(report.crossfadeEndPass, isTrue);
      expect(report.slideLeftMidPass, isTrue);
      expect(report.wipeLeftMidPass, isTrue);
      expect(report.speedMappingPass, isTrue);
      expect(report.outsideTimelinePass, isTrue);
      expect(report.invalidTransitionIgnoredPass, isTrue);
      expect(report.zeroDurationSafePass, isTrue);
      expect(report.overflowSafePass, isTrue);
      expect(report.mathPass, isTrue);

      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.nativeAllLanesPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.details['inputPort0'], 'clip_0_video_in');
      expect(report.details['outputPort0'], 'composited_video_out');

      final serialized = report.toMap();
      expect(serialized['pass'], isTrue);
      expect(serialized['decision'], 'pass');
      expect(serialized['marker'], _passMarker);
      expect(serialized['proofBoundary'], _proofBoundary);
      for (final key in _gateKeys) {
        expect(serialized[key], isTrue, reason: key);
      }
      expect(serialized['allNativeLanesPass'], isTrue);

      final roundTrip = VGTimelineCompositorSmokeReport.fromMap(serialized);
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
    });

    test('fail report with one failed math gate is not a verified pass', () {
      final report = _createSampleReport({
        'pass': false,
        'status': 'FAIL',
        'marker': _failMarker,
        'failureReason': 'wipe_left_mid_mismatch',
        'wipeLeftMidOk': false,
        'allNativeLanesPass': false,
      });

      expect(report.pass, isFalse);
      expect(report.decision, VGTimelineCompositorSmokeDecision.fail);
      expect(report.isFail, isTrue);
      expect(report.wipeLeftMidPass, isFalse);
      expect(report.slideLeftMidPass, isTrue);
      expect(report.topologyPass, isTrue);
      expect(report.mathPass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(report.hasPassMarker, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.failureReason, 'wipe_left_mid_mismatch');
      expect(report.isVerifiedPass, isFalse);
    });

    test('every single gate failure flips allNativeLanesPass', () {
      for (final key in _gateKeys) {
        final report = _createSampleReport({key: false});
        expect(report.gates[key], isFalse, reason: key);
        expect(report.allNativeLanesPass, isFalse, reason: key);
        expect(report.isVerifiedPass, isFalse, reason: key);
      }
    });

    test('wrong marker fails verified pass even when all gates pass', () {
      final report = _createSampleReport({'marker': 'SOME_OTHER_MARKER'});
      expect(report.pass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.hasPassMarker, isFalse);
      expect(report.isVerifiedPass, isFalse);

      final failMarkerReport = _createSampleReport({'marker': _failMarker});
      expect(failMarkerReport.hasFailMarker, isTrue);
      expect(failMarkerReport.isVerifiedPass, isFalse);
    });

    test('wrong proof boundary fails verified pass', () {
      final report = _createSampleReport({
        'proofBoundary': 'incorrect_proof_boundary',
      });
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.isVerifiedPass, isFalse);
    });

    test('native aggregate disagreement fails verified pass', () {
      final report = _createSampleReport({'allNativeLanesPass': false});
      expect(report.allNativeLanesPass, isTrue);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('string "true"/"false" gate values are accepted', () {
      final report = _createSampleReport({
        'kindOk': 'true',
        'typeOk': 'false',
        'allNativeLanesPass': 'true',
      });
      expect(report.kindPass, isTrue);
      expect(report.typePass, isFalse);
      expect(report.nativeAllLanesPass, isTrue);
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in <Object?>[null, 'not_a_map', 12345, 3.14, []]) {
        final report = VGTimelineCompositorSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(
          report.decision,
          VGTimelineCompositorSmokeDecision.harnessException,
        );
        expect(report.isHarnessException, isTrue);
        expect(report.failureReason, 'native_result_not_a_map');
        expect(report.marker, _failMarker);
        expect(report.proofBoundary, _proofBoundary);
        expect(report.allNativeLanesPass, isFalse);
        expect(report.isVerifiedPass, isFalse);
        for (final key in _gateKeys) {
          expect(report.gates[key], isFalse, reason: key);
        }
      }
    });

    test('fromMap handles missing/null fields defensively', () {
      final report = VGTimelineCompositorSmokeReport.fromMap({
        for (final key in _createSampleRawMap().keys) key: null,
      });
      expect(report.pass, isFalse);
      expect(report.decision, VGTimelineCompositorSmokeDecision.fail);
      expect(report.status, 'FAIL');
      expect(report.marker, isEmpty);
      expect(report.proofBoundary, isEmpty);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.details, isEmpty);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.isVerifiedPass, isFalse);

      final unsupported = VGTimelineCompositorSmokeReport.fromMap({
        'pass': false,
        'status': 'UNSUPPORTED',
      });
      expect(
        unsupported.decision,
        VGTimelineCompositorSmokeDecision.unsupported,
      );
      expect(unsupported.isUnsupported, isTrue);
    });

    test('explicit decision field wins over status for failed reports', () {
      final report = VGTimelineCompositorSmokeReport.fromMap({
        'pass': false,
        'status': 'FAIL',
        'decision': 'harnessException',
      });
      expect(
        report.decision,
        VGTimelineCompositorSmokeDecision.harnessException,
      );
    });

    test('unsupported and harnessFailure factories are fail-shaped', () {
      final unsupported = VGTimelineCompositorSmokeReport.unsupported(
        'missing_plugin',
      );
      expect(unsupported.pass, isFalse);
      expect(unsupported.isUnsupported, isTrue);
      expect(unsupported.status, 'UNSUPPORTED');
      expect(unsupported.marker, _failMarker);
      expect(unsupported.proofBoundary, _proofBoundary);
      expect(unsupported.failureReason, 'missing_plugin');
      expect(unsupported.allNativeLanesPass, isFalse);
      expect(unsupported.isVerifiedPass, isFalse);
      expect(unsupported.gates.length, _gateKeys.length);

      final harness = VGTimelineCompositorSmokeReport.harnessFailure(
        'timeout',
        extraDetails: const {'error': 'x'},
      );
      expect(harness.pass, isFalse);
      expect(harness.isHarnessException, isTrue);
      expect(harness.status, 'FAIL');
      expect(harness.marker, _failMarker);
      expect(harness.failureReason, 'timeout');
      expect(harness.details['error'], 'x');
      expect(harness.isVerifiedPass, isFalse);
    });
  });

  group('VGTimelineCompositorSmokeReport value semantics', () {
    test('equal values are equal with equal hash codes', () {
      final a = _createSampleReport();
      final b = _createSampleReport();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGTimelineCompositorSmokeReport('));
      expect(a.toString(), contains('marker: $_passMarker'));
    });

    test('inequality when any single field differs', () {
      final base = _createSampleReport();
      const diffs = <Map<String, Object?>>[
        {'pass': false},
        {'status': 'FAIL'},
        {'marker': 'other'},
        {'proofBoundary': 'other'},
        {'failureReason': 'x'},
        {'kindOk': false},
        {'allNativeLanesPass': false},
        {
          'details': <String, Object?>{'k': 'v'},
        },
        {'raw': '{}'},
      ];
      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)), reason: diff.toString());
      }
    });
  });

  group('MethodChannel runner invocation', () {
    test('invokes the exact route name and parses a pass report', () async {
      MethodCall? capturedCall;
      const channel = MethodChannel('test_timeline_compositor_smoke_channel');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGTimelineCompositorSmokeReport.runAndroidDagPhase5TimelineCompositorSmoke(
            channel: channel,
          );

      expect(capturedCall, isNotNull);
      expect(capturedCall!.method, _method);
      expect(capturedCall!.arguments, isNull);
      expect(report.pass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
    });

    test('uses default vanguard_media_engine channel when omitted', () async {
      MethodCall? capturedCall;
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGTimelineCompositorSmokeReport.runAndroidDagPhase5TimelineCompositorSmoke();

      expect(capturedCall, isNotNull);
      expect(capturedCall!.method, _method);
      expect(report.pass, isTrue);
    });

    test('missing plugin yields an unsupported report', () async {
      const channel = MethodChannel('test_timeline_compositor_smoke_missing');
      // No handler registered -> MissingPluginException.
      final report =
          await VGTimelineCompositorSmokeReport.runAndroidDagPhase5TimelineCompositorSmoke(
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, startsWith('missing_plugin'));
      expect(report.isVerifiedPass, isFalse);
    });

    test('UNAVAILABLE platform exception yields an unsupported report', () async {
      const channel = MethodChannel('test_timeline_compositor_smoke_unavail');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'UNAVAILABLE', message: 'no coordinator');
      });
      final report =
          await VGTimelineCompositorSmokeReport.runAndroidDagPhase5TimelineCompositorSmoke(
            channel: channel,
          );
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, 'platform_exception:UNAVAILABLE');
      expect(report.isVerifiedPass, isFalse);
    });

    test('other platform exception yields a harnessException report', () async {
      const channel = MethodChannel('test_timeline_compositor_smoke_pe');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'NATIVE_CRASH', message: 'Simulated');
      });
      final report =
          await VGTimelineCompositorSmokeReport.runAndroidDagPhase5TimelineCompositorSmoke(
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, 'platform_exception:NATIVE_CRASH');
      expect(report.details['code'], 'NATIVE_CRASH');
      expect(report.details['message'], 'Simulated');
      expect(report.isVerifiedPass, isFalse);
    });

    test('timeout yields a harnessException report', () async {
      const channel = MethodChannel('test_timeline_compositor_smoke_timeout');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });
      final report =
          await VGTimelineCompositorSmokeReport.runAndroidDagPhase5TimelineCompositorSmoke(
            timeout: const Duration(milliseconds: 20),
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, 'timeout');
      expect(report.isVerifiedPass, isFalse);
    });

    test('generic exception yields a harnessException report', () async {
      const channel = MethodChannel('test_timeline_compositor_smoke_generic');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw StateError('Generic unexpected error');
      });
      final report =
          await VGTimelineCompositorSmokeReport.runAndroidDagPhase5TimelineCompositorSmoke(
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isHarnessException, isTrue);
      // The test messenger surfaces handler throws as a PlatformException
      // with code 'error'; a raw Dart throw maps to 'exception:'.
      expect(
        report.failureReason,
        anyOf(startsWith('platform_exception:'), startsWith('exception:')),
      );
      expect(report.isVerifiedPass, isFalse);
    });

    test('non-map native result yields a harnessException report', () async {
      const channel = MethodChannel('test_timeline_compositor_smoke_nonmap');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return 'status=PASS';
      });
      final report =
          await VGTimelineCompositorSmokeReport.runAndroidDagPhase5TimelineCompositorSmoke(
            channel: channel,
          );
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, 'native_result_not_a_map');
      expect(report.details['received'], 'status=PASS');
    });
  });
}
