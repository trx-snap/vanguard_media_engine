// vg_gles_export_overlay_seam_smoke_test.dart
// vanguard_media_engine - P5-GLES-EXPORT-OVERLAY-SEAM-A: diagnostic-only
// Android True-DAG GLES export overlay seam smoke Dart model & MethodChannel
// tests.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_gles_export_overlay_seam_smoke.dart';

const String _proofBoundary =
    'native_gles_export_overlay_seam_caller_current_context_diagnostic_only_no_production_export';
const String _passMarker =
    'ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_SEAM_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_SEAM_PHYSICAL_SMOKE_FAIL';
const String _method = 'runAndroidDagPhase5GlesExportOverlaySeamSmoke';

const List<String> _gateKeys = <String>[
  'eglSetupOk',
  'invalidArgumentsRejectedOk',
  'decodeOk',
  'updateTexImageOk',
  'baseDrawOk',
  'seamCallOk',
  'compositeAssertionOk',
  'stateRestoredOk',
  'cleanupOk',
  'canonical',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) => {
  'pass': true,
  'status': 'PASS',
  'marker': _passMarker,
  'proofBoundary': _proofBoundary,
  'failureReason': '',
  for (final key in _gateKeys) key: true,
  'details': const <String, Object?>{
    'seamRaw': '{"pass":true,"status":"PASS"}',
    'beforeOutsideRgba': '10,10,10,255',
    'afterOutsideRgba': '10,10,10,255',
    'beforeInsideRgba': '10,10,10,255',
    'afterInsideRgba': '132,5,5,255',
  },
  'raw': '{"pass":true,"status":"PASS"}',
  if (overrides != null) ...overrides,
};

VGGlesExportOverlaySeamSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) =>
    VGGlesExportOverlaySeamSmokeReport.fromMap(_createSampleRawMap(overrides));

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
        VGGlesExportOverlaySeamSmokeReport.proofBoundaryConstant,
        equals(_proofBoundary),
      );
      expect(
        VGGlesExportOverlaySeamSmokeReport.passMarker,
        equals(_passMarker),
      );
      expect(
        VGGlesExportOverlaySeamSmokeReport.failMarker,
        equals(_failMarker),
      );
      expect(VGGlesExportOverlaySeamSmokeReport.methodName, equals(_method));
      expect(
        VGGlesExportOverlaySeamSmokeReport.allGateKeys,
        orderedEquals(_gateKeys),
      );
      expect(VGGlesExportOverlaySeamSmokeReport.setupGateKeys.length, 1);
      expect(VGGlesExportOverlaySeamSmokeReport.validationGateKeys.length, 1);
      expect(VGGlesExportOverlaySeamSmokeReport.decodeGateKeys.length, 2);
      expect(VGGlesExportOverlaySeamSmokeReport.drawGateKeys.length, 2);
      expect(VGGlesExportOverlaySeamSmokeReport.compositeGateKeys.length, 1);
      expect(VGGlesExportOverlaySeamSmokeReport.stateGateKeys.length, 1);
      expect(VGGlesExportOverlaySeamSmokeReport.cleanupGateKeys.length, 1);
      expect(VGGlesExportOverlaySeamSmokeReport.canonicalGateKeys.length, 1);
      expect(_gateKeys.toSet().length, 10, reason: 'unique');
      expect(_gateKeys.length, 10);
    });
  });

  group('VGGlesExportOverlaySeamSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 4 values in order', () {
      expect(
        VGGlesExportOverlaySeamSmokeDecision.values,
        orderedEquals(const [
          VGGlesExportOverlaySeamSmokeDecision.pass,
          VGGlesExportOverlaySeamSmokeDecision.fail,
          VGGlesExportOverlaySeamSmokeDecision.unsupported,
          VGGlesExportOverlaySeamSmokeDecision.harnessException,
        ]),
      );
    });

    test('fromRaw maps all known decision strings', () {
      expect(
        VGGlesExportOverlaySeamSmokeDecision.fromRaw('pass'),
        VGGlesExportOverlaySeamSmokeDecision.pass,
      );
      expect(
        VGGlesExportOverlaySeamSmokeDecision.fromRaw('PASS'),
        VGGlesExportOverlaySeamSmokeDecision.pass,
      );
      expect(
        VGGlesExportOverlaySeamSmokeDecision.fromRaw('fail'),
        VGGlesExportOverlaySeamSmokeDecision.fail,
      );
      expect(
        VGGlesExportOverlaySeamSmokeDecision.fromRaw('UNSUPPORTED'),
        VGGlesExportOverlaySeamSmokeDecision.unsupported,
      );
      expect(
        VGGlesExportOverlaySeamSmokeDecision.fromRaw('harnessException'),
        VGGlesExportOverlaySeamSmokeDecision.harnessException,
      );
      expect(
        VGGlesExportOverlaySeamSmokeDecision.fromRaw('harness_exception'),
        VGGlesExportOverlaySeamSmokeDecision.harnessException,
      );
    });

    test('fromRaw falls back to harnessException for unknown values', () {
      for (final invalid in <Object?>['bogus', '', null, 1, 2.0, true, []]) {
        expect(
          VGGlesExportOverlaySeamSmokeDecision.fromRaw(invalid),
          VGGlesExportOverlaySeamSmokeDecision.harnessException,
        );
      }
    });
  });

  group('VGGlesExportOverlaySeamSmokeReport fromMap / toMap', () {
    test('pass report parses every gate and round-trips', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(report.decision, VGGlesExportOverlaySeamSmokeDecision.pass);
      expect(report.isPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.isFail, isFalse);
      expect(report.isUnsupported, isFalse);
      expect(report.isHarnessException, isFalse);
      expect(report.status, 'PASS');
      expect(report.marker, _passMarker);
      expect(report.proofBoundary, _proofBoundary);
      expect(report.failureReason, isEmpty);

      expect(report.eglSetupPass, isTrue);
      expect(report.setupPass, isTrue);

      expect(report.invalidArgumentsRejectedPass, isTrue);
      expect(report.validationPass, isTrue);

      expect(report.decodePass, isTrue);
      expect(report.updateTexImagePass, isTrue);
      expect(report.decodeGroupPass, isTrue);

      expect(report.baseDrawPass, isTrue);
      expect(report.seamCallPass, isTrue);
      expect(report.drawGroupPass, isTrue);

      expect(report.compositeAssertionPass, isTrue);
      expect(report.compositePass, isTrue);

      expect(report.stateRestoredPass, isTrue);
      expect(report.statePass, isTrue);

      expect(report.cleanupPass, isTrue);
      expect(report.cleanupGroupPass, isTrue);

      expect(report.canonicalPass, isTrue);
      expect(report.canonical, isTrue);

      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);
      expect(report.allGatesPass, isTrue);

      expect(report.details['beforeOutsideRgba'], '10,10,10,255');
      expect(report.details['afterInsideRgba'], '132,5,5,255');

      final serialized = report.toMap();
      expect(serialized['pass'], isTrue);
      expect(serialized['decision'], 'pass');
      expect(serialized['marker'], _passMarker);
      expect(serialized['proofBoundary'], _proofBoundary);
      for (final key in _gateKeys) {
        expect(serialized[key], isTrue, reason: key);
      }

      final roundTrip = VGGlesExportOverlaySeamSmokeReport.fromMap(serialized);
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
    });

    test('fail report with one failed gate is not a pass', () {
      final report = _createSampleReport({
        'pass': false,
        'status': 'FAIL',
        'marker': _failMarker,
        'failureReason': 'composite_assertion_failed',
        'compositeAssertionOk': false,
      });

      expect(report.pass, isFalse);
      expect(report.decision, VGGlesExportOverlaySeamSmokeDecision.fail);
      expect(report.isFail, isTrue);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.compositeAssertionPass, isFalse);
      expect(report.compositePass, isFalse);
      expect(report.decodeGroupPass, isTrue);
      expect(report.hasFailMarker, isTrue);
      expect(report.hasPassMarker, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.failureReason, 'composite_assertion_failed');
    });

    test('every single gate failure flips allGatesPass and isPass', () {
      for (final key in _gateKeys) {
        final report = _createSampleReport({key: false});
        expect(report.gates[key], isFalse, reason: key);
        expect(report.allGatesPass, isFalse, reason: key);
        expect(report.isPass, isFalse, reason: key);
        expect(report.isVerifiedPass, isFalse, reason: key);
      }
    });

    test('lane group getters reflect only their own keys', () {
      final setupFail = _createSampleReport({'eglSetupOk': false});
      expect(setupFail.setupPass, isFalse);
      expect(setupFail.validationPass, isTrue);
      expect(setupFail.decodeGroupPass, isTrue);

      final validationFail = _createSampleReport({
        'invalidArgumentsRejectedOk': false,
      });
      expect(validationFail.validationPass, isFalse);
      expect(validationFail.setupPass, isTrue);
      expect(validationFail.decodeGroupPass, isTrue);

      final decodeFail = _createSampleReport({'decodeOk': false});
      expect(decodeFail.decodeGroupPass, isFalse);
      expect(decodeFail.validationPass, isTrue);
      expect(decodeFail.drawGroupPass, isTrue);

      final drawFail = _createSampleReport({'seamCallOk': false});
      expect(drawFail.drawGroupPass, isFalse);
      expect(drawFail.decodeGroupPass, isTrue);
      expect(drawFail.compositePass, isTrue);

      final compositeFail = _createSampleReport({
        'compositeAssertionOk': false,
      });
      expect(compositeFail.compositePass, isFalse);
      expect(compositeFail.drawGroupPass, isTrue);
      expect(compositeFail.statePass, isTrue);

      final stateFail = _createSampleReport({'stateRestoredOk': false});
      expect(stateFail.statePass, isFalse);
      expect(stateFail.compositePass, isTrue);
      expect(stateFail.cleanupGroupPass, isTrue);

      final cleanupFail = _createSampleReport({'cleanupOk': false});
      expect(cleanupFail.cleanupGroupPass, isFalse);
      expect(cleanupFail.statePass, isTrue);
      expect(cleanupFail.canonicalPass, isTrue);

      final canonicalFail = _createSampleReport({'canonical': false});
      expect(canonicalFail.canonicalPass, isFalse);
      expect(canonicalFail.canonical, isFalse);
      expect(canonicalFail.cleanupGroupPass, isTrue);
    });

    test('wrong marker fails isPass even when all gates pass', () {
      final report = _createSampleReport({'marker': 'SOME_OTHER_MARKER'});
      expect(report.pass, isTrue);
      expect(report.allGatesPass, isTrue);
      expect(report.hasPassMarker, isFalse);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);

      final failMarkerReport = _createSampleReport({'marker': _failMarker});
      expect(failMarkerReport.hasFailMarker, isTrue);
      expect(failMarkerReport.isPass, isFalse);
      expect(failMarkerReport.isVerifiedPass, isFalse);
    });

    test('wrong proof boundary fails isPass', () {
      final report = _createSampleReport({
        'proofBoundary': 'incorrect_proof_boundary',
      });
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.allGatesPass, isTrue);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('string "true"/"false" gate values are accepted', () {
      final report = _createSampleReport({
        'eglSetupOk': 'true',
        'decodeOk': 'false',
      });
      expect(report.eglSetupPass, isTrue);
      expect(report.decodePass, isFalse);
      expect(report.isPass, isFalse);
    });

    test('raw String JSON parses successfully to valid pass report', () {
      final rawMap = _createSampleRawMap();
      final jsonStr = jsonEncode(rawMap);
      final report = VGGlesExportOverlaySeamSmokeReport.fromMap(jsonStr);

      expect(report.pass, isTrue);
      expect(report.isPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allGatesPass, isTrue);
      expect(report.raw, equals(jsonStr));
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in <Object?>['not_a_map', null, 12345, 3.14, []]) {
        final report = VGGlesExportOverlaySeamSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(
          report.decision,
          VGGlesExportOverlaySeamSmokeDecision.harnessException,
        );
        expect(report.isHarnessException, isTrue);
        expect(report.failureReason, 'native_result_not_a_map');
        expect(report.marker, _failMarker);
        expect(report.proofBoundary, _proofBoundary);
        expect(report.allGatesPass, isFalse);
        expect(report.isPass, isFalse);
        expect(report.isVerifiedPass, isFalse);
        for (final key in _gateKeys) {
          expect(report.gates[key], isFalse, reason: key);
        }
      }
    });

    test('fromMap handles missing/null fields defensively', () {
      final report = VGGlesExportOverlaySeamSmokeReport.fromMap({
        for (final key in _createSampleRawMap().keys) key: null,
      });
      expect(report.pass, isFalse);
      expect(report.decision, VGGlesExportOverlaySeamSmokeDecision.fail);
      expect(report.status, 'FAIL');
      expect(report.marker, isEmpty);
      expect(report.proofBoundary, isEmpty);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.details, isEmpty);
      expect(report.allGatesPass, isFalse);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);

      final unsupported = VGGlesExportOverlaySeamSmokeReport.fromMap({
        'pass': false,
        'status': 'UNSUPPORTED',
      });
      expect(
        unsupported.decision,
        VGGlesExportOverlaySeamSmokeDecision.unsupported,
      );
      expect(unsupported.isUnsupported, isTrue);
    });

    test('contradictory pass=false with PASS status is a plain fail', () {
      final report = VGGlesExportOverlaySeamSmokeReport.fromMap({
        'pass': false,
        'status': 'PASS',
        'marker': _passMarker,
        'proofBoundary': _proofBoundary,
        for (final key in _gateKeys) key: true,
      });
      expect(report.decision, VGGlesExportOverlaySeamSmokeDecision.fail);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('explicit decision field wins over status for failed reports', () {
      final report = VGGlesExportOverlaySeamSmokeReport.fromMap({
        'pass': false,
        'status': 'FAIL',
        'decision': 'harnessException',
      });
      expect(
        report.decision,
        VGGlesExportOverlaySeamSmokeDecision.harnessException,
      );
    });

    test('unsupported and harnessFailure factories are fail-shaped', () {
      final unsupported = VGGlesExportOverlaySeamSmokeReport.unsupported(
        'missing_plugin',
      );
      expect(unsupported.pass, isFalse);
      expect(unsupported.isUnsupported, isTrue);
      expect(unsupported.status, 'UNSUPPORTED');
      expect(unsupported.marker, _failMarker);
      expect(unsupported.proofBoundary, _proofBoundary);
      expect(unsupported.failureReason, 'missing_plugin');
      expect(unsupported.allGatesPass, isFalse);
      expect(unsupported.isPass, isFalse);
      expect(unsupported.isVerifiedPass, isFalse);
      expect(unsupported.gates.length, _gateKeys.length);

      final harness = VGGlesExportOverlaySeamSmokeReport.harnessFailure(
        'timeout',
        extraDetails: const {'error': 'x'},
      );
      expect(harness.pass, isFalse);
      expect(harness.isHarnessException, isTrue);
      expect(harness.status, 'FAIL');
      expect(harness.marker, _failMarker);
      expect(harness.failureReason, 'timeout');
      expect(harness.details['error'], 'x');
      expect(harness.isPass, isFalse);
      expect(harness.isVerifiedPass, isFalse);
    });
  });

  group('VGGlesExportOverlaySeamSmokeReport value semantics', () {
    test('equal values are equal with equal hash codes', () {
      final a = _createSampleReport();
      final b = _createSampleReport();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGGlesExportOverlaySeamSmokeReport('));
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
        {'seamCallOk': false},
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
    test('invokes the exact route name with the videoPath argument', () async {
      MethodCall? capturedCall;
      const channel = MethodChannel('test_gles_export_overlay_seam_channel');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGGlesExportOverlaySeamSmokeReport.runAndroidDagPhase5GlesExportOverlaySeamSmoke(
            videoPath: '/tmp/clip_b.mov',
            channel: channel,
          );

      expect(capturedCall, isNotNull);
      expect(capturedCall!.method, _method);
      expect(capturedCall!.arguments, {'videoPath': '/tmp/clip_b.mov'});
      expect(report.pass, isTrue);
      expect(report.isPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
    });

    test('uses default vanguard_media_engine channel when omitted', () async {
      MethodCall? capturedCall;
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGGlesExportOverlaySeamSmokeReport.runAndroidDagPhase5GlesExportOverlaySeamSmoke(
            videoPath: '/tmp/clip_b.mov',
          );

      expect(capturedCall, isNotNull);
      expect(capturedCall!.method, _method);
      expect(report.pass, isTrue);
    });

    test('missing plugin yields an unsupported report', () async {
      const channel = MethodChannel('test_gles_export_overlay_seam_missing');
      final report =
          await VGGlesExportOverlaySeamSmokeReport.runAndroidDagPhase5GlesExportOverlaySeamSmoke(
            videoPath: '/tmp/clip_b.mov',
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, startsWith('missing_plugin'));
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('UNAVAILABLE platform exception yields an unsupported report', () async {
      const channel = MethodChannel('test_gles_export_overlay_seam_unavail');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'UNAVAILABLE', message: 'no coordinator');
      });
      final report =
          await VGGlesExportOverlaySeamSmokeReport.runAndroidDagPhase5GlesExportOverlaySeamSmoke(
            videoPath: '/tmp/clip_b.mov',
            channel: channel,
          );
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, 'platform_exception:UNAVAILABLE');
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('other platform exception yields a harnessException report', () async {
      const channel = MethodChannel('test_gles_export_overlay_seam_pe');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'NATIVE_CRASH', message: 'Simulated');
      });
      final report =
          await VGGlesExportOverlaySeamSmokeReport.runAndroidDagPhase5GlesExportOverlaySeamSmoke(
            videoPath: '/tmp/clip_b.mov',
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, 'platform_exception:NATIVE_CRASH');
      expect(report.details['code'], 'NATIVE_CRASH');
      expect(report.details['message'], 'Simulated');
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('timeout yields a harnessException report', () async {
      const channel = MethodChannel('test_gles_export_overlay_seam_timeout');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });
      final report =
          await VGGlesExportOverlaySeamSmokeReport.runAndroidDagPhase5GlesExportOverlaySeamSmoke(
            videoPath: '/tmp/clip_b.mov',
            timeout: const Duration(milliseconds: 20),
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, 'timeout');
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('generic exception yields a harnessException report', () async {
      const channel = MethodChannel('test_gles_export_overlay_seam_generic');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw StateError('Generic unexpected error');
      });
      final report =
          await VGGlesExportOverlaySeamSmokeReport.runAndroidDagPhase5GlesExportOverlaySeamSmoke(
            videoPath: '/tmp/clip_b.mov',
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isHarnessException, isTrue);
      expect(
        report.failureReason,
        anyOf(startsWith('platform_exception:'), startsWith('exception:')),
      );
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test(
      'non-map non-json native result yields a harnessException report',
      () async {
        const channel = MethodChannel('test_gles_export_overlay_seam_nonmap');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          return 'status=PASS';
        });
        final report =
            await VGGlesExportOverlaySeamSmokeReport.runAndroidDagPhase5GlesExportOverlaySeamSmoke(
              videoPath: '/tmp/clip_b.mov',
              channel: channel,
            );
        expect(report.isHarnessException, isTrue);
        expect(report.failureReason, 'native_result_not_a_map');
        expect(report.details['received'], 'status=PASS');
      },
    );

    test('raw String JSON return over channel parses successfully', () async {
      const channel = MethodChannel('test_gles_export_overlay_seam_raw_json');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return jsonEncode(_createSampleRawMap());
      });
      final report =
          await VGGlesExportOverlaySeamSmokeReport.runAndroidDagPhase5GlesExportOverlaySeamSmoke(
            videoPath: '/tmp/clip_b.mov',
            channel: channel,
          );
      expect(report.pass, isTrue);
      expect(report.isPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.hasPassMarker, isTrue);
    });

    test('native fail payload surfaces the failing lane and reason', () async {
      const channel = MethodChannel('test_gles_export_overlay_seam_fail');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return _createSampleRawMap({
          'pass': false,
          'status': 'FAIL',
          'marker': _failMarker,
          'failureReason':
              'seam_call_failed:gles_overlay_compositor_draw_failed',
          'seamCallOk': false,
          'compositeAssertionOk': false,
        });
      });
      final report =
          await VGGlesExportOverlaySeamSmokeReport.runAndroidDagPhase5GlesExportOverlaySeamSmoke(
            videoPath: '/tmp/clip_b.mov',
            channel: channel,
          );
      expect(report.isFail, isTrue);
      expect(report.seamCallPass, isFalse);
      expect(report.drawGroupPass, isFalse);
      expect(report.compositeAssertionPass, isFalse);
      expect(report.decodeGroupPass, isTrue);
      expect(
        report.failureReason,
        'seam_call_failed:gles_overlay_compositor_draw_failed',
      );
      expect(report.hasFailMarker, isTrue);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });
  });
}
