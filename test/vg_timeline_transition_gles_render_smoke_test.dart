// vg_timeline_transition_gles_render_smoke_test.dart
// vanguard_media_engine — P5-COMPOSITOR-TRANS (sub-slice GLES-RENDER):
// Android True-DAG GlesTimelineTransitionCompositor shader/raster diagnostic
// smoke Dart model & MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_timeline_transition_gles_render_smoke.dart';

const String _proofBoundary =
    'native_gles_timeline_transition_compositor_shader_raster_only_no_vulkan_no_decode_no_export';
const String _passMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_GLES_RENDER_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_GLES_RENDER_PHYSICAL_SMOKE_FAIL';
const String _method = 'runAndroidDagPhase5TimelineTransitionGlesRenderSmoke';

const List<String> _gateKeys = <String>[
  'eglSetupOk',
  'invalidTextureRejectedOk',
  'invalidDimensionsRejectedOk',
  'nonFiniteProgressRejectedOk',
  'nonFiniteWeightRejectedOk',
  'unsupportedTargetRejectedOk',
  'hardCutNoneOk',
  'crossfadeStartOk',
  'crossfadeMidOk',
  'crossfadeEndOk',
  'slideLeftOk',
  'slideRightOk',
  'slideUpOk',
  'slideDownOk',
  'wipeLeftOk',
  'wipeRightOk',
  'wipeUpOk',
  'wipeDownOk',
  'texture2dTargetAcceptedOk',
  'oesTargetStructuralOk',
  'unsupportedTargetStillRejectedOk',
  'viewportRestoredOk',
  'glStateRestoredOk',
];

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) => {
  'pass': true,
  'status': 'PASS',
  'marker': _passMarker,
  'proofBoundary': _proofBoundary,
  'failureReason': '',
  for (final key in _gateKeys) key: true,
  'allNativeLanesPass': true,
  'nativeAllLanesPass': true,
  'details': const <String, Object?>{
    'glVersion': 'OpenGL ES 3.2',
    'eglClientVersion': 3,
    'oesExtensionAvailable': true,
    'crossfadeMidCenterRgb': '128,0,128',
    'slideLeftMismatchTl': 0,
    'oesProofScope':
        'structural_target_validation_and_sampler_compile_only_no_surfacetexture_no_decoder_frame',
  },
  'raw': '{"pass":true,"status":"PASS"}',
  if (overrides != null) ...overrides,
};

VGTimelineTransitionGlesRenderSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGTimelineTransitionGlesRenderSmokeReport.fromMap(
  _createSampleRawMap(overrides),
);

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
        VGTimelineTransitionGlesRenderSmokeReport.proofBoundaryConstant,
        equals(_proofBoundary),
      );
      expect(
        VGTimelineTransitionGlesRenderSmokeReport.passMarker,
        equals(_passMarker),
      );
      expect(
        VGTimelineTransitionGlesRenderSmokeReport.failMarker,
        equals(_failMarker),
      );
      expect(
        VGTimelineTransitionGlesRenderSmokeReport.methodName,
        equals(_method),
      );
      expect(
        VGTimelineTransitionGlesRenderSmokeReport.allGateKeys,
        orderedEquals(_gateKeys),
      );
      expect(VGTimelineTransitionGlesRenderSmokeReport.setupGateKeys.length, 1);
      expect(
        VGTimelineTransitionGlesRenderSmokeReport
            .paramValidationGateKeys
            .length,
        5,
      );
      expect(
        VGTimelineTransitionGlesRenderSmokeReport.crossfadeGateKeys.length,
        4,
      );
      expect(VGTimelineTransitionGlesRenderSmokeReport.slideGateKeys.length, 4);
      expect(VGTimelineTransitionGlesRenderSmokeReport.wipeGateKeys.length, 4);
      expect(
        VGTimelineTransitionGlesRenderSmokeReport.textureTargetGateKeys.length,
        3,
      );
      expect(
        VGTimelineTransitionGlesRenderSmokeReport.stateRestoreGateKeys.length,
        2,
      );
      expect(_gateKeys.toSet().length, _gateKeys.length, reason: 'unique');
    });
  });

  group('VGTimelineTransitionGlesRenderSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 4 values in order', () {
      expect(
        VGTimelineTransitionGlesRenderSmokeDecision.values,
        orderedEquals(const [
          VGTimelineTransitionGlesRenderSmokeDecision.pass,
          VGTimelineTransitionGlesRenderSmokeDecision.fail,
          VGTimelineTransitionGlesRenderSmokeDecision.unsupported,
          VGTimelineTransitionGlesRenderSmokeDecision.harnessException,
        ]),
      );
    });

    test('fromRaw maps all known decision strings', () {
      expect(
        VGTimelineTransitionGlesRenderSmokeDecision.fromRaw('pass'),
        VGTimelineTransitionGlesRenderSmokeDecision.pass,
      );
      expect(
        VGTimelineTransitionGlesRenderSmokeDecision.fromRaw('PASS'),
        VGTimelineTransitionGlesRenderSmokeDecision.pass,
      );
      expect(
        VGTimelineTransitionGlesRenderSmokeDecision.fromRaw('fail'),
        VGTimelineTransitionGlesRenderSmokeDecision.fail,
      );
      expect(
        VGTimelineTransitionGlesRenderSmokeDecision.fromRaw('UNSUPPORTED'),
        VGTimelineTransitionGlesRenderSmokeDecision.unsupported,
      );
      expect(
        VGTimelineTransitionGlesRenderSmokeDecision.fromRaw('harnessException'),
        VGTimelineTransitionGlesRenderSmokeDecision.harnessException,
      );
      expect(
        VGTimelineTransitionGlesRenderSmokeDecision.fromRaw(
          'harness_exception',
        ),
        VGTimelineTransitionGlesRenderSmokeDecision.harnessException,
      );
    });

    test('fromRaw falls back to harnessException for unknown values', () {
      for (final invalid in <Object?>['bogus', '', null, 1, 2.0, true, []]) {
        expect(
          VGTimelineTransitionGlesRenderSmokeDecision.fromRaw(invalid),
          VGTimelineTransitionGlesRenderSmokeDecision.harnessException,
        );
      }
    });
  });

  group('VGTimelineTransitionGlesRenderSmokeReport fromMap / toMap', () {
    test('pass report parses every gate and round-trips', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(report.decision, VGTimelineTransitionGlesRenderSmokeDecision.pass);
      expect(report.isPass, isTrue);
      expect(report.isFail, isFalse);
      expect(report.isUnsupported, isFalse);
      expect(report.isHarnessException, isFalse);
      expect(report.status, 'PASS');
      expect(report.marker, _passMarker);
      expect(report.proofBoundary, _proofBoundary);
      expect(report.failureReason, isEmpty);

      expect(report.eglSetupPass, isTrue);

      // Lane 1.
      expect(report.invalidTextureRejectedPass, isTrue);
      expect(report.invalidDimensionsRejectedPass, isTrue);
      expect(report.nonFiniteProgressRejectedPass, isTrue);
      expect(report.nonFiniteWeightRejectedPass, isTrue);
      expect(report.unsupportedTargetRejectedPass, isTrue);
      expect(report.paramValidationPass, isTrue);

      // Lane 2.
      expect(report.hardCutNonePass, isTrue);
      expect(report.crossfadeStartPass, isTrue);
      expect(report.crossfadeMidPass, isTrue);
      expect(report.crossfadeEndPass, isTrue);
      expect(report.crossfadePass, isTrue);

      // Lane 3.
      expect(report.slideLeftPass, isTrue);
      expect(report.slideRightPass, isTrue);
      expect(report.slideUpPass, isTrue);
      expect(report.slideDownPass, isTrue);
      expect(report.slidePass, isTrue);

      // Lane 4.
      expect(report.wipeLeftPass, isTrue);
      expect(report.wipeRightPass, isTrue);
      expect(report.wipeUpPass, isTrue);
      expect(report.wipeDownPass, isTrue);
      expect(report.wipePass, isTrue);

      // Lane 5.
      expect(report.texture2dTargetAcceptedPass, isTrue);
      expect(report.oesTargetStructuralPass, isTrue);
      expect(report.unsupportedTargetStillRejectedPass, isTrue);
      expect(report.textureTargetPass, isTrue);

      // State restoration.
      expect(report.viewportRestoredPass, isTrue);
      expect(report.glStateRestoredPass, isTrue);
      expect(report.stateRestorePass, isTrue);

      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.nativeAllLanesPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.details['glVersion'], 'OpenGL ES 3.2');
      expect(report.details['crossfadeMidCenterRgb'], '128,0,128');
      expect(report.details['slideLeftMismatchTl'], 0);

      final serialized = report.toMap();
      expect(serialized['pass'], isTrue);
      expect(serialized['decision'], 'pass');
      expect(serialized['marker'], _passMarker);
      expect(serialized['proofBoundary'], _proofBoundary);
      for (final key in _gateKeys) {
        expect(serialized[key], isTrue, reason: key);
      }
      expect(serialized['allNativeLanesPass'], isTrue);
      expect(serialized['nativeAllLanesPass'], isTrue);

      final roundTrip = VGTimelineTransitionGlesRenderSmokeReport.fromMap(
        serialized,
      );
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
    });

    test('fail report with one failed wipe gate is not a verified pass', () {
      final report = _createSampleReport({
        'pass': false,
        'status': 'FAIL',
        'marker': _failMarker,
        'failureReason': 'wipeUp_pixel_ownership_mismatch',
        'wipeUpOk': false,
        'allNativeLanesPass': false,
        'nativeAllLanesPass': false,
      });

      expect(report.pass, isFalse);
      expect(report.decision, VGTimelineTransitionGlesRenderSmokeDecision.fail);
      expect(report.isFail, isTrue);
      expect(report.wipeUpPass, isFalse);
      expect(report.wipeLeftPass, isTrue);
      expect(report.wipePass, isFalse);
      expect(report.slidePass, isTrue);
      expect(report.crossfadePass, isTrue);
      expect(report.paramValidationPass, isTrue);
      expect(report.textureTargetPass, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(report.hasPassMarker, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.failureReason, 'wipeUp_pixel_ownership_mismatch');
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

    test('lane group getters reflect only their own keys', () {
      final paramFail = _createSampleReport({
        'nonFiniteProgressRejectedOk': false,
      });
      expect(paramFail.paramValidationPass, isFalse);
      expect(paramFail.crossfadePass, isTrue);
      expect(paramFail.slidePass, isTrue);
      expect(paramFail.wipePass, isTrue);
      expect(paramFail.textureTargetPass, isTrue);
      expect(paramFail.stateRestorePass, isTrue);

      final crossfadeFail = _createSampleReport({'crossfadeMidOk': false});
      expect(crossfadeFail.crossfadePass, isFalse);
      expect(crossfadeFail.paramValidationPass, isTrue);

      final slideFail = _createSampleReport({'slideDownOk': false});
      expect(slideFail.slidePass, isFalse);
      expect(slideFail.wipePass, isTrue);

      final targetFail = _createSampleReport({'oesTargetStructuralOk': false});
      expect(targetFail.textureTargetPass, isFalse);
      expect(targetFail.slidePass, isTrue);

      final stateFail = _createSampleReport({'viewportRestoredOk': false});
      expect(stateFail.stateRestorePass, isFalse);
      expect(stateFail.textureTargetPass, isTrue);

      final setupFail = _createSampleReport({'eglSetupOk': false});
      expect(setupFail.eglSetupPass, isFalse);
      expect(setupFail.allNativeLanesPass, isFalse);
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

    test(
      'nativeAllLanesPass spelling is accepted when allNativeLanesPass is absent',
      () {
        final raw = _createSampleRawMap()..remove('allNativeLanesPass');
        final report = VGTimelineTransitionGlesRenderSmokeReport.fromMap(raw);
        expect(report.nativeAllLanesPass, isTrue);
        expect(report.isVerifiedPass, isTrue);

        final rawFalse = _createSampleRawMap({'nativeAllLanesPass': false})
          ..remove('allNativeLanesPass');
        final reportFalse = VGTimelineTransitionGlesRenderSmokeReport.fromMap(
          rawFalse,
        );
        expect(reportFalse.nativeAllLanesPass, isFalse);
        expect(reportFalse.isVerifiedPass, isFalse);
      },
    );

    test('string "true"/"false" gate values are accepted', () {
      final report = _createSampleReport({
        'eglSetupOk': 'true',
        'slideLeftOk': 'false',
        'allNativeLanesPass': 'true',
      });
      expect(report.eglSetupPass, isTrue);
      expect(report.slideLeftPass, isFalse);
      expect(report.nativeAllLanesPass, isTrue);
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in <Object?>[null, 'not_a_map', 12345, 3.14, []]) {
        final report = VGTimelineTransitionGlesRenderSmokeReport.fromMap(
          invalid,
        );
        expect(report.pass, isFalse);
        expect(
          report.decision,
          VGTimelineTransitionGlesRenderSmokeDecision.harnessException,
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
      final report = VGTimelineTransitionGlesRenderSmokeReport.fromMap({
        for (final key in _createSampleRawMap().keys) key: null,
      });
      expect(report.pass, isFalse);
      expect(report.decision, VGTimelineTransitionGlesRenderSmokeDecision.fail);
      expect(report.status, 'FAIL');
      expect(report.marker, isEmpty);
      expect(report.proofBoundary, isEmpty);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.details, isEmpty);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.isVerifiedPass, isFalse);

      final unsupported = VGTimelineTransitionGlesRenderSmokeReport.fromMap({
        'pass': false,
        'status': 'UNSUPPORTED',
      });
      expect(
        unsupported.decision,
        VGTimelineTransitionGlesRenderSmokeDecision.unsupported,
      );
      expect(unsupported.isUnsupported, isTrue);
    });

    test('contradictory pass=false with PASS status is a plain fail', () {
      final report = VGTimelineTransitionGlesRenderSmokeReport.fromMap({
        'pass': false,
        'status': 'PASS',
        'marker': _passMarker,
        'proofBoundary': _proofBoundary,
        for (final key in _gateKeys) key: true,
        'allNativeLanesPass': true,
      });
      expect(report.decision, VGTimelineTransitionGlesRenderSmokeDecision.fail);
      expect(report.isVerifiedPass, isFalse);
    });

    test('explicit decision field wins over status for failed reports', () {
      final report = VGTimelineTransitionGlesRenderSmokeReport.fromMap({
        'pass': false,
        'status': 'FAIL',
        'decision': 'harnessException',
      });
      expect(
        report.decision,
        VGTimelineTransitionGlesRenderSmokeDecision.harnessException,
      );
    });

    test('unsupported and harnessFailure factories are fail-shaped', () {
      final unsupported = VGTimelineTransitionGlesRenderSmokeReport.unsupported(
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

      final harness = VGTimelineTransitionGlesRenderSmokeReport.harnessFailure(
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

  group('VGTimelineTransitionGlesRenderSmokeReport value semantics', () {
    test('equal values are equal with equal hash codes', () {
      final a = _createSampleReport();
      final b = _createSampleReport();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(
        a.toString(),
        contains('VGTimelineTransitionGlesRenderSmokeReport('),
      );
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
        {'crossfadeMidOk': false},
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
      const channel = MethodChannel('test_transition_gles_render_channel');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGTimelineTransitionGlesRenderSmokeReport.runAndroidDagPhase5TimelineTransitionGlesRenderSmoke(
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
          await VGTimelineTransitionGlesRenderSmokeReport.runAndroidDagPhase5TimelineTransitionGlesRenderSmoke();

      expect(capturedCall, isNotNull);
      expect(capturedCall!.method, _method);
      expect(report.pass, isTrue);
    });

    test('missing plugin yields an unsupported report', () async {
      const channel = MethodChannel('test_transition_gles_render_missing');
      // No handler registered -> MissingPluginException.
      final report =
          await VGTimelineTransitionGlesRenderSmokeReport.runAndroidDagPhase5TimelineTransitionGlesRenderSmoke(
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, startsWith('missing_plugin'));
      expect(report.isVerifiedPass, isFalse);
    });

    test('UNAVAILABLE platform exception yields an unsupported report', () async {
      const channel = MethodChannel('test_transition_gles_render_unavail');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'UNAVAILABLE', message: 'no coordinator');
      });
      final report =
          await VGTimelineTransitionGlesRenderSmokeReport.runAndroidDagPhase5TimelineTransitionGlesRenderSmoke(
            channel: channel,
          );
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, 'platform_exception:UNAVAILABLE');
      expect(report.isVerifiedPass, isFalse);
    });

    test('other platform exception yields a harnessException report', () async {
      const channel = MethodChannel('test_transition_gles_render_pe');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'NATIVE_CRASH', message: 'Simulated');
      });
      final report =
          await VGTimelineTransitionGlesRenderSmokeReport.runAndroidDagPhase5TimelineTransitionGlesRenderSmoke(
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
      const channel = MethodChannel('test_transition_gles_render_timeout');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });
      final report =
          await VGTimelineTransitionGlesRenderSmokeReport.runAndroidDagPhase5TimelineTransitionGlesRenderSmoke(
            timeout: const Duration(milliseconds: 20),
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, 'timeout');
      expect(report.isVerifiedPass, isFalse);
    });

    test('generic exception yields a harnessException report', () async {
      const channel = MethodChannel('test_transition_gles_render_generic');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw StateError('Generic unexpected error');
      });
      final report =
          await VGTimelineTransitionGlesRenderSmokeReport.runAndroidDagPhase5TimelineTransitionGlesRenderSmoke(
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
      const channel = MethodChannel('test_transition_gles_render_nonmap');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return 'status=PASS';
      });
      final report =
          await VGTimelineTransitionGlesRenderSmokeReport.runAndroidDagPhase5TimelineTransitionGlesRenderSmoke(
            channel: channel,
          );
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, 'native_result_not_a_map');
      expect(report.details['received'], 'status=PASS');
    });

    test('native fail payload surfaces the failing lane and reason', () async {
      const channel = MethodChannel('test_transition_gles_render_fail');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return _createSampleRawMap({
          'pass': false,
          'status': 'FAIL',
          'marker': _failMarker,
          'failureReason': 'crossfadeMid_color_mismatch',
          'crossfadeMidOk': false,
          'texture2dTargetAcceptedOk': false,
          'allNativeLanesPass': false,
          'nativeAllLanesPass': false,
        });
      });
      final report =
          await VGTimelineTransitionGlesRenderSmokeReport.runAndroidDagPhase5TimelineTransitionGlesRenderSmoke(
            channel: channel,
          );
      expect(report.isFail, isTrue);
      expect(report.crossfadePass, isFalse);
      expect(report.textureTargetPass, isFalse);
      expect(report.slidePass, isTrue);
      expect(report.failureReason, 'crossfadeMid_color_mismatch');
      expect(report.hasFailMarker, isTrue);
      expect(report.isVerifiedPass, isFalse);
    });
  });
}
