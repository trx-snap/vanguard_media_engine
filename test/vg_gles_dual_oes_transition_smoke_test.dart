// vg_gles_dual_oes_transition_smoke_test.dart
// vanguard_media_engine - P5-GLES-EXPORT-DUAL-OES-PRERESOLVE-TRANSITION-
// READINESS: diagnostic-only Android True-DAG GLES dual-OES transition smoke
// Dart model & MethodChannel tests.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_gles_dual_oes_transition_smoke.dart';

const String _proofBoundary =
    'diagnostic_dual_mediacodec_surfacetexture_oes_to_canvas2d_preresolve_to_gles_transition_compositor_no_export';
const String _passMarker =
    'ANDROID_DAG_PHASE5_GLES_DUAL_OES_TRANSITION_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_GLES_DUAL_OES_TRANSITION_PHYSICAL_SMOKE_FAIL';
const String _method = 'runAndroidDagPhase5GlesDualOesTransitionSmoke';

const List<String> _gateKeys = <String>[
  'argumentValidationOk',
  'eglSetupOk',
  'es3ContextVerifiedOk',
  'dualDecoderSetupOk',
  'bothFramesAvailableOk',
  'bothUpdateTexImageOk',
  'bothOesResolveOk',
  'resolvedContentOk',
  'nativeTransitionDrawOk',
  'pixelProofOk',
  'stateRestoredOk',
  'cleanupOk',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) => {
  'pass': true,
  'status': 'PASS',
  'marker': _passMarker,
  'proofBoundary': _proofBoundary,
  'failureReason': '',
  for (final key in _gateKeys) key: true,
  'glMajorVersion': 3,
  'fromPtsUs': 0,
  'toPtsUs': 33000,
  'nativeRaw': '{"pass":true,"status":"PASS"}',
  'details': const <String, Object?>{
    'glMajorVersion': 3,
    'fromPtsUs': 0,
    'toPtsUs': 33000,
    'nativeRaw': '{"pass":true,"status":"PASS"}',
    'probeCenter': '120,80,60,255',
  },
  'raw': '{"pass":true,"status":"PASS"}',
  if (overrides != null) ...overrides,
};

VGGlesDualOesTransitionSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) =>
    VGGlesDualOesTransitionSmokeReport.fromMap(_createSampleRawMap(overrides));

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
        VGGlesDualOesTransitionSmokeReport.proofBoundaryConstant,
        equals(_proofBoundary),
      );
      expect(
        VGGlesDualOesTransitionSmokeReport.passMarker,
        equals(_passMarker),
      );
      expect(
        VGGlesDualOesTransitionSmokeReport.failMarker,
        equals(_failMarker),
      );
      expect(VGGlesDualOesTransitionSmokeReport.methodName, equals(_method));
      expect(
        VGGlesDualOesTransitionSmokeReport.allGateKeys,
        orderedEquals(_gateKeys),
      );
      expect(
        VGGlesDualOesTransitionSmokeReport.argumentValidationGateKeys.length,
        1,
      );
      expect(VGGlesDualOesTransitionSmokeReport.setupGateKeys.length, 1);
      expect(VGGlesDualOesTransitionSmokeReport.es3ContextGateKeys.length, 1);
      expect(VGGlesDualOesTransitionSmokeReport.decodeGateKeys.length, 3);
      expect(VGGlesDualOesTransitionSmokeReport.resolveGateKeys.length, 2);
      expect(VGGlesDualOesTransitionSmokeReport.transitionGateKeys.length, 2);
      expect(VGGlesDualOesTransitionSmokeReport.stateGateKeys.length, 1);
      expect(VGGlesDualOesTransitionSmokeReport.cleanupGateKeys.length, 1);
      expect(_gateKeys.toSet().length, 12, reason: 'unique');
      expect(_gateKeys.length, 12);
    });
  });

  group('VGGlesDualOesTransitionSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 4 values in order', () {
      expect(
        VGGlesDualOesTransitionSmokeDecision.values,
        orderedEquals(const [
          VGGlesDualOesTransitionSmokeDecision.pass,
          VGGlesDualOesTransitionSmokeDecision.fail,
          VGGlesDualOesTransitionSmokeDecision.unsupported,
          VGGlesDualOesTransitionSmokeDecision.harnessException,
        ]),
      );
    });

    test('fromRaw maps all known decision strings', () {
      expect(
        VGGlesDualOesTransitionSmokeDecision.fromRaw('pass'),
        VGGlesDualOesTransitionSmokeDecision.pass,
      );
      expect(
        VGGlesDualOesTransitionSmokeDecision.fromRaw('PASS'),
        VGGlesDualOesTransitionSmokeDecision.pass,
      );
      expect(
        VGGlesDualOesTransitionSmokeDecision.fromRaw('fail'),
        VGGlesDualOesTransitionSmokeDecision.fail,
      );
      expect(
        VGGlesDualOesTransitionSmokeDecision.fromRaw('UNSUPPORTED'),
        VGGlesDualOesTransitionSmokeDecision.unsupported,
      );
      expect(
        VGGlesDualOesTransitionSmokeDecision.fromRaw('harnessException'),
        VGGlesDualOesTransitionSmokeDecision.harnessException,
      );
      expect(
        VGGlesDualOesTransitionSmokeDecision.fromRaw('harness_exception'),
        VGGlesDualOesTransitionSmokeDecision.harnessException,
      );
    });

    test('fromRaw falls back to harnessException for unknown values', () {
      for (final invalid in <Object?>['bogus', '', null, 1, 2.0, true, []]) {
        expect(
          VGGlesDualOesTransitionSmokeDecision.fromRaw(invalid),
          VGGlesDualOesTransitionSmokeDecision.harnessException,
        );
      }
    });
  });

  group('VGGlesDualOesTransitionSmokeReport fromMap / toMap', () {
    test('pass report parses every gate and round-trips', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(report.decision, VGGlesDualOesTransitionSmokeDecision.pass);
      expect(report.isPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.isFail, isFalse);
      expect(report.isUnsupported, isFalse);
      expect(report.isHarnessException, isFalse);
      expect(report.status, 'PASS');
      expect(report.marker, _passMarker);
      expect(report.proofBoundary, _proofBoundary);
      expect(report.failureReason, isEmpty);
      expect(report.glMajorVersion, 3);
      expect(report.fromPtsUs, 0);
      expect(report.toPtsUs, 33000);
      expect(report.nativeRaw, '{"pass":true,"status":"PASS"}');

      expect(report.argumentValidationPass, isTrue);
      expect(report.argumentValidationGroupPass, isTrue);

      expect(report.eglSetupPass, isTrue);
      expect(report.setupPass, isTrue);

      expect(report.es3ContextVerifiedPass, isTrue);
      expect(report.es3ContextGroupPass, isTrue);

      expect(report.dualDecoderSetupPass, isTrue);
      expect(report.bothFramesAvailablePass, isTrue);
      expect(report.bothUpdateTexImagePass, isTrue);
      expect(report.decodeGroupPass, isTrue);

      expect(report.bothOesResolvePass, isTrue);
      expect(report.resolvedContentPass, isTrue);
      expect(report.resolveGroupPass, isTrue);

      expect(report.nativeTransitionDrawPass, isTrue);
      expect(report.pixelProofPass, isTrue);
      expect(report.transitionGroupPass, isTrue);

      expect(report.stateRestoredPass, isTrue);
      expect(report.statePass, isTrue);

      expect(report.cleanupPass, isTrue);
      expect(report.cleanupGroupPass, isTrue);

      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);
      expect(report.allGatesPass, isTrue);

      expect(report.details['probeCenter'], '120,80,60,255');

      final serialized = report.toMap();
      expect(serialized['pass'], isTrue);
      expect(serialized['decision'], 'pass');
      expect(serialized['marker'], _passMarker);
      expect(serialized['proofBoundary'], _proofBoundary);
      expect(serialized['glMajorVersion'], 3);
      expect(serialized['fromPtsUs'], 0);
      expect(serialized['toPtsUs'], 33000);
      for (final key in _gateKeys) {
        expect(serialized[key], isTrue, reason: key);
      }

      final roundTrip = VGGlesDualOesTransitionSmokeReport.fromMap(serialized);
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
    });

    test('fail report with one failed gate is not a pass', () {
      final report = _createSampleReport({
        'pass': false,
        'status': 'FAIL',
        'marker': _failMarker,
        'failureReason':
            'pixel_proof_failed:non_sentinel_or_nonzero_check_failed',
        'pixelProofOk': false,
      });

      expect(report.pass, isFalse);
      expect(report.decision, VGGlesDualOesTransitionSmokeDecision.fail);
      expect(report.isFail, isTrue);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.pixelProofPass, isFalse);
      expect(report.transitionGroupPass, isFalse);
      expect(report.nativeTransitionDrawPass, isTrue);
      expect(report.decodeGroupPass, isTrue);
      expect(report.hasFailMarker, isTrue);
      expect(report.hasPassMarker, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(
        report.failureReason,
        'pixel_proof_failed:non_sentinel_or_nonzero_check_failed',
      );
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
      final argFail = _createSampleReport({'argumentValidationOk': false});
      expect(argFail.argumentValidationGroupPass, isFalse);
      expect(argFail.setupPass, isTrue);

      final setupFail = _createSampleReport({'eglSetupOk': false});
      expect(setupFail.setupPass, isFalse);
      expect(setupFail.es3ContextGroupPass, isTrue);
      expect(setupFail.decodeGroupPass, isTrue);

      final es3ContextFail = _createSampleReport({
        'es3ContextVerifiedOk': false,
      });
      expect(es3ContextFail.es3ContextGroupPass, isFalse);
      expect(es3ContextFail.setupPass, isTrue);
      expect(es3ContextFail.decodeGroupPass, isTrue);

      final decodeFail = _createSampleReport({'dualDecoderSetupOk': false});
      expect(decodeFail.decodeGroupPass, isFalse);
      expect(decodeFail.es3ContextGroupPass, isTrue);
      expect(decodeFail.resolveGroupPass, isTrue);
      expect(decodeFail.transitionGroupPass, isTrue);

      final framesFail = _createSampleReport({'bothFramesAvailableOk': false});
      expect(framesFail.decodeGroupPass, isFalse);
      expect(framesFail.dualDecoderSetupPass, isTrue);

      final updateTexFail = _createSampleReport({
        'bothUpdateTexImageOk': false,
      });
      expect(updateTexFail.decodeGroupPass, isFalse);
      expect(updateTexFail.bothFramesAvailablePass, isTrue);
      expect(updateTexFail.resolveGroupPass, isTrue);

      final resolveFail = _createSampleReport({'bothOesResolveOk': false});
      expect(resolveFail.resolveGroupPass, isFalse);
      expect(resolveFail.bothOesResolvePass, isFalse);
      expect(resolveFail.resolvedContentPass, isTrue);
      expect(resolveFail.decodeGroupPass, isTrue);
      expect(resolveFail.transitionGroupPass, isTrue);

      final resolvedContentFail = _createSampleReport({
        'resolvedContentOk': false,
      });
      expect(resolvedContentFail.resolveGroupPass, isFalse);
      expect(resolvedContentFail.bothOesResolvePass, isTrue);
      expect(resolvedContentFail.resolvedContentPass, isFalse);

      final transitionFail = _createSampleReport({
        'nativeTransitionDrawOk': false,
      });
      expect(transitionFail.transitionGroupPass, isFalse);
      expect(transitionFail.decodeGroupPass, isTrue);
      expect(transitionFail.resolveGroupPass, isTrue);
      expect(transitionFail.statePass, isTrue);

      final stateFail = _createSampleReport({'stateRestoredOk': false});
      expect(stateFail.statePass, isFalse);
      expect(stateFail.transitionGroupPass, isTrue);
      expect(stateFail.cleanupGroupPass, isTrue);

      final cleanupFail = _createSampleReport({'cleanupOk': false});
      expect(cleanupFail.cleanupGroupPass, isFalse);
      expect(cleanupFail.statePass, isTrue);
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
        'dualDecoderSetupOk': 'false',
      });
      expect(report.eglSetupPass, isTrue);
      expect(report.dualDecoderSetupPass, isFalse);
      expect(report.isPass, isFalse);
    });

    test('numeric telemetry parses ints and doubles defensively', () {
      final report = _createSampleReport({
        'glMajorVersion': 3.0,
        'fromPtsUs': 12345,
        'toPtsUs': 67890.0,
      });
      expect(report.glMajorVersion, 3);
      expect(report.fromPtsUs, 12345);
      expect(report.toPtsUs, 67890);
    });

    test('raw String JSON parses successfully to valid pass report', () {
      final rawMap = _createSampleRawMap();
      final jsonStr = jsonEncode(rawMap);
      final report = VGGlesDualOesTransitionSmokeReport.fromMap(jsonStr);

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
        final report = VGGlesDualOesTransitionSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(
          report.decision,
          VGGlesDualOesTransitionSmokeDecision.harnessException,
        );
        expect(report.isHarnessException, isTrue);
        expect(report.failureReason, 'native_result_not_a_map');
        expect(report.marker, _failMarker);
        expect(report.proofBoundary, _proofBoundary);
        expect(report.allGatesPass, isFalse);
        expect(report.isPass, isFalse);
        expect(report.isVerifiedPass, isFalse);
        expect(report.glMajorVersion, 0);
        expect(report.fromPtsUs, -1);
        expect(report.toPtsUs, -1);
        for (final key in _gateKeys) {
          expect(report.gates[key], isFalse, reason: key);
        }
      }
    });

    test('fromMap handles missing/null fields defensively', () {
      final report = VGGlesDualOesTransitionSmokeReport.fromMap({
        for (final key in _createSampleRawMap().keys) key: null,
      });
      expect(report.pass, isFalse);
      expect(report.decision, VGGlesDualOesTransitionSmokeDecision.fail);
      expect(report.status, 'FAIL');
      expect(report.marker, isEmpty);
      expect(report.proofBoundary, isEmpty);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.details, isEmpty);
      expect(report.allGatesPass, isFalse);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.glMajorVersion, 0);
      expect(report.fromPtsUs, -1);
      expect(report.toPtsUs, -1);
      expect(report.nativeRaw, isEmpty);

      final unsupported = VGGlesDualOesTransitionSmokeReport.fromMap({
        'pass': false,
        'status': 'UNSUPPORTED',
      });
      expect(
        unsupported.decision,
        VGGlesDualOesTransitionSmokeDecision.unsupported,
      );
      expect(unsupported.isUnsupported, isTrue);
    });

    test('contradictory pass=false with PASS status is a plain fail', () {
      final report = VGGlesDualOesTransitionSmokeReport.fromMap({
        'pass': false,
        'status': 'PASS',
        'marker': _passMarker,
        'proofBoundary': _proofBoundary,
        for (final key in _gateKeys) key: true,
      });
      expect(report.decision, VGGlesDualOesTransitionSmokeDecision.fail);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('explicit decision field wins over status for failed reports', () {
      final report = VGGlesDualOesTransitionSmokeReport.fromMap({
        'pass': false,
        'status': 'FAIL',
        'decision': 'harnessException',
      });
      expect(
        report.decision,
        VGGlesDualOesTransitionSmokeDecision.harnessException,
      );
    });

    test('unsupported and harnessFailure factories are fail-shaped', () {
      final unsupported = VGGlesDualOesTransitionSmokeReport.unsupported(
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

      final harness = VGGlesDualOesTransitionSmokeReport.harnessFailure(
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

  group('VGGlesDualOesTransitionSmokeReport value semantics', () {
    test('equal values are equal with equal hash codes', () {
      final a = _createSampleReport();
      final b = _createSampleReport();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGGlesDualOesTransitionSmokeReport('));
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
        {'pixelProofOk': false},
        {'glMajorVersion': 2},
        {'fromPtsUs': 99},
        {'toPtsUs': 99},
        {'nativeRaw': '{}'},
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
    test(
      'invokes the exact route name with fromClipPath/toClipPath arguments',
      () async {
        MethodCall? capturedCall;
        const channel = MethodChannel('test_gles_dual_oes_transition_channel');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return _createSampleRawMap();
        });

        final report =
            await VGGlesDualOesTransitionSmokeReport.runAndroidDagPhase5GlesDualOesTransitionSmoke(
              fromClipPath: '/tmp/clip_a.mov',
              toClipPath: '/tmp/clip_b.mov',
              channel: channel,
            );

        expect(capturedCall, isNotNull);
        expect(capturedCall!.method, _method);
        expect(capturedCall!.arguments, {
          'fromClipPath': '/tmp/clip_a.mov',
          'toClipPath': '/tmp/clip_b.mov',
        });
        expect(report.pass, isTrue);
        expect(report.isPass, isTrue);
        expect(report.isVerifiedPass, isTrue);
      },
    );

    test('uses default vanguard_media_engine channel when omitted', () async {
      MethodCall? capturedCall;
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGGlesDualOesTransitionSmokeReport.runAndroidDagPhase5GlesDualOesTransitionSmoke(
            fromClipPath: '/tmp/clip_a.mov',
            toClipPath: '/tmp/clip_b.mov',
          );

      expect(capturedCall, isNotNull);
      expect(capturedCall!.method, _method);
      expect(report.pass, isTrue);
    });

    test('missing plugin yields an unsupported report', () async {
      const channel = MethodChannel('test_gles_dual_oes_transition_missing');
      final report =
          await VGGlesDualOesTransitionSmokeReport.runAndroidDagPhase5GlesDualOesTransitionSmoke(
            fromClipPath: '/tmp/clip_a.mov',
            toClipPath: '/tmp/clip_b.mov',
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, startsWith('missing_plugin'));
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('UNAVAILABLE platform exception yields an unsupported report', () async {
      const channel = MethodChannel('test_gles_dual_oes_transition_unavail');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'UNAVAILABLE', message: 'no coordinator');
      });
      final report =
          await VGGlesDualOesTransitionSmokeReport.runAndroidDagPhase5GlesDualOesTransitionSmoke(
            fromClipPath: '/tmp/clip_a.mov',
            toClipPath: '/tmp/clip_b.mov',
            channel: channel,
          );
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, 'platform_exception:UNAVAILABLE');
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('other platform exception yields a harnessException report', () async {
      const channel = MethodChannel('test_gles_dual_oes_transition_pe');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'NATIVE_CRASH', message: 'Simulated');
      });
      final report =
          await VGGlesDualOesTransitionSmokeReport.runAndroidDagPhase5GlesDualOesTransitionSmoke(
            fromClipPath: '/tmp/clip_a.mov',
            toClipPath: '/tmp/clip_b.mov',
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
      const channel = MethodChannel('test_gles_dual_oes_transition_timeout');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });
      final report =
          await VGGlesDualOesTransitionSmokeReport.runAndroidDagPhase5GlesDualOesTransitionSmoke(
            fromClipPath: '/tmp/clip_a.mov',
            toClipPath: '/tmp/clip_b.mov',
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
      const channel = MethodChannel('test_gles_dual_oes_transition_generic');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw StateError('Generic unexpected error');
      });
      final report =
          await VGGlesDualOesTransitionSmokeReport.runAndroidDagPhase5GlesDualOesTransitionSmoke(
            fromClipPath: '/tmp/clip_a.mov',
            toClipPath: '/tmp/clip_b.mov',
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
        const channel = MethodChannel('test_gles_dual_oes_transition_nonmap');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          return 'status=PASS';
        });
        final report =
            await VGGlesDualOesTransitionSmokeReport.runAndroidDagPhase5GlesDualOesTransitionSmoke(
              fromClipPath: '/tmp/clip_a.mov',
              toClipPath: '/tmp/clip_b.mov',
              channel: channel,
            );
        expect(report.isHarnessException, isTrue);
        expect(report.failureReason, 'native_result_not_a_map');
        expect(report.details['received'], 'status=PASS');
      },
    );

    test('raw String JSON return over channel parses successfully', () async {
      const channel = MethodChannel('test_gles_dual_oes_transition_raw_json');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return jsonEncode(_createSampleRawMap());
      });
      final report =
          await VGGlesDualOesTransitionSmokeReport.runAndroidDagPhase5GlesDualOesTransitionSmoke(
            fromClipPath: '/tmp/clip_a.mov',
            toClipPath: '/tmp/clip_b.mov',
            channel: channel,
          );
      expect(report.pass, isTrue);
      expect(report.isPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.hasPassMarker, isTrue);
    });

    test('native fail payload surfaces the failing lane and reason', () async {
      const channel = MethodChannel('test_gles_dual_oes_transition_fail');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return _createSampleRawMap({
          'pass': false,
          'status': 'FAIL',
          'marker': _failMarker,
          'failureReason':
              'native_transition_draw_failed:gles_timeline_transition_compositor_invalid_geometry',
          'nativeTransitionDrawOk': false,
          'pixelProofOk': false,
          'stateRestoredOk': false,
        });
      });
      final report =
          await VGGlesDualOesTransitionSmokeReport.runAndroidDagPhase5GlesDualOesTransitionSmoke(
            fromClipPath: '/tmp/clip_a.mov',
            toClipPath: '/tmp/clip_b.mov',
            channel: channel,
          );
      expect(report.isFail, isTrue);
      expect(report.nativeTransitionDrawPass, isFalse);
      expect(report.transitionGroupPass, isFalse);
      expect(report.pixelProofPass, isFalse);
      expect(report.stateRestoredPass, isFalse);
      expect(report.decodeGroupPass, isTrue);
      expect(
        report.failureReason,
        'native_transition_draw_failed:gles_timeline_transition_compositor_invalid_geometry',
      );
      expect(report.hasFailMarker, isTrue);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });
  });
}
