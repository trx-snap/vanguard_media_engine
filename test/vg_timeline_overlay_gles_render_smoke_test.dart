// vg_timeline_overlay_gles_render_smoke_test.dart
// vanguard_media_engine — P5-OVERLAYS-TRANS (sub-slice GLES-RENDER):
// Android True-DAG GlesOverlayCompositor shader/raster diagnostic
// smoke Dart model & MethodChannel tests.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_timeline_overlay_gles_render_smoke.dart';

const String _proofBoundary =
    'native_gles_timeline_overlay_compositor_shader_raster_only_no_vulkan_no_decode_no_export_no_product';
const String _passMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_GLES_RENDER_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_GLES_RENDER_PHYSICAL_SMOKE_FAIL';
const String _method = 'runAndroidDagPhase5TimelineOverlayGlesRenderSmoke';

const List<String> _gateKeys = <String>[
  'eglSetupOk',
  'invalidTextureRejectedOk',
  'invalidDimensionsRejectedOk',
  'nonFiniteTransformRejectedOk',
  'invalidOpacityRejectedOk',
  'unsupportedTargetRejectedOk',
  'singleLayerTransformOk',
  'opacityBlendOk',
  'multiLayerZOrderOk',
  'texture2dTargetAcceptedOk',
  'oesTargetStructuralOk',
  'unsupportedTargetStillRejectedOk',
  'blendStateRestoredOk',
  'viewportRestoredOk',
  'glStateRestoredOk',
  'structParityOk',
  'canonical',
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
    'glRenderer': 'Adreno (TM) 740',
    'eglClientVersion': 3,
    'oesExtensionAvailable': true,
    'surfaceWidth': 64,
    'surfaceHeight': 64,
    'colorTolerance': 8,
    'oesProofScope':
        'structural_target_validation_and_sampler_compile_only_no_surfacetexture_no_decoder_frame',
  },
  'raw': '{"pass":true,"status":"PASS"}',
  if (overrides != null) ...overrides,
};

VGTimelineOverlayGlesRenderSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGTimelineOverlayGlesRenderSmokeReport.fromMap(
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
        VGTimelineOverlayGlesRenderSmokeReport.proofBoundaryConstant,
        equals(_proofBoundary),
      );
      expect(
        VGTimelineOverlayGlesRenderSmokeReport.passMarker,
        equals(_passMarker),
      );
      expect(
        VGTimelineOverlayGlesRenderSmokeReport.failMarker,
        equals(_failMarker),
      );
      expect(
        VGTimelineOverlayGlesRenderSmokeReport.methodName,
        equals(_method),
      );
      expect(
        VGTimelineOverlayGlesRenderSmokeReport.allGateKeys,
        orderedEquals(_gateKeys),
      );
      expect(VGTimelineOverlayGlesRenderSmokeReport.setupGateKeys.length, 1);
      expect(
        VGTimelineOverlayGlesRenderSmokeReport.validationGateKeys.length,
        5,
      );
      expect(
        VGTimelineOverlayGlesRenderSmokeReport.paramValidationGateKeys.length,
        5,
      );
      expect(
        VGTimelineOverlayGlesRenderSmokeReport.transformGateKeys.length,
        1,
      );
      expect(VGTimelineOverlayGlesRenderSmokeReport.blendGateKeys.length, 1);
      expect(VGTimelineOverlayGlesRenderSmokeReport.zOrderGateKeys.length, 1);
      expect(VGTimelineOverlayGlesRenderSmokeReport.targetGateKeys.length, 3);
      expect(
        VGTimelineOverlayGlesRenderSmokeReport.textureTargetGateKeys.length,
        3,
      );
      expect(VGTimelineOverlayGlesRenderSmokeReport.stateGateKeys.length, 3);
      expect(
        VGTimelineOverlayGlesRenderSmokeReport.stateRestoreGateKeys.length,
        3,
      );
      expect(VGTimelineOverlayGlesRenderSmokeReport.parityGateKeys.length, 1);
      expect(
        VGTimelineOverlayGlesRenderSmokeReport.structParityGateKeys.length,
        1,
      );
      expect(
        VGTimelineOverlayGlesRenderSmokeReport.canonicalGateKeys.length,
        1,
      );
      expect(_gateKeys.toSet().length, 17, reason: 'unique');
      expect(_gateKeys.length, 17);
    });
  });

  group('VGTimelineOverlayGlesRenderSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 4 values in order', () {
      expect(
        VGTimelineOverlayGlesRenderSmokeDecision.values,
        orderedEquals(const [
          VGTimelineOverlayGlesRenderSmokeDecision.pass,
          VGTimelineOverlayGlesRenderSmokeDecision.fail,
          VGTimelineOverlayGlesRenderSmokeDecision.unsupported,
          VGTimelineOverlayGlesRenderSmokeDecision.harnessException,
        ]),
      );
    });

    test('fromRaw maps all known decision strings', () {
      expect(
        VGTimelineOverlayGlesRenderSmokeDecision.fromRaw('pass'),
        VGTimelineOverlayGlesRenderSmokeDecision.pass,
      );
      expect(
        VGTimelineOverlayGlesRenderSmokeDecision.fromRaw('PASS'),
        VGTimelineOverlayGlesRenderSmokeDecision.pass,
      );
      expect(
        VGTimelineOverlayGlesRenderSmokeDecision.fromRaw('fail'),
        VGTimelineOverlayGlesRenderSmokeDecision.fail,
      );
      expect(
        VGTimelineOverlayGlesRenderSmokeDecision.fromRaw('UNSUPPORTED'),
        VGTimelineOverlayGlesRenderSmokeDecision.unsupported,
      );
      expect(
        VGTimelineOverlayGlesRenderSmokeDecision.fromRaw('harnessException'),
        VGTimelineOverlayGlesRenderSmokeDecision.harnessException,
      );
      expect(
        VGTimelineOverlayGlesRenderSmokeDecision.fromRaw('harness_exception'),
        VGTimelineOverlayGlesRenderSmokeDecision.harnessException,
      );
    });

    test('fromRaw falls back to harnessException for unknown values', () {
      for (final invalid in <Object?>['bogus', '', null, 1, 2.0, true, []]) {
        expect(
          VGTimelineOverlayGlesRenderSmokeDecision.fromRaw(invalid),
          VGTimelineOverlayGlesRenderSmokeDecision.harnessException,
        );
      }
    });
  });

  group('VGTimelineOverlayGlesRenderSmokeReport fromMap / toMap', () {
    test('pass report parses every gate and round-trips', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(report.decision, VGTimelineOverlayGlesRenderSmokeDecision.pass);
      expect(report.isPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.isFail, isFalse);
      expect(report.isUnsupported, isFalse);
      expect(report.isHarnessException, isFalse);
      expect(report.status, 'PASS');
      expect(report.marker, _passMarker);
      expect(report.proofBoundary, _proofBoundary);
      expect(report.failureReason, isEmpty);

      // Setup lane
      expect(report.eglSetupPass, isTrue);
      expect(report.setupPass, isTrue);

      // Lane 1: validation
      expect(report.invalidTextureRejectedPass, isTrue);
      expect(report.invalidDimensionsRejectedPass, isTrue);
      expect(report.nonFiniteTransformRejectedPass, isTrue);
      expect(report.invalidOpacityRejectedPass, isTrue);
      expect(report.unsupportedTargetRejectedPass, isTrue);
      expect(report.validationPass, isTrue);
      expect(report.paramValidationPass, isTrue);

      // Lane 2: transform
      expect(report.singleLayerTransformPass, isTrue);
      expect(report.transformPass, isTrue);

      // Lane 3: blend
      expect(report.opacityBlendPass, isTrue);
      expect(report.blendPass, isTrue);

      // Lane 4: z-order
      expect(report.multiLayerZOrderPass, isTrue);
      expect(report.zOrderPass, isTrue);

      // Lane 5: targets
      expect(report.texture2dTargetAcceptedPass, isTrue);
      expect(report.oesTargetStructuralPass, isTrue);
      expect(report.unsupportedTargetStillRejectedPass, isTrue);
      expect(report.targetPass, isTrue);
      expect(report.textureTargetPass, isTrue);

      // Lane 6: state restoration
      expect(report.blendStateRestoredPass, isTrue);
      expect(report.viewportRestoredPass, isTrue);
      expect(report.glStateRestoredPass, isTrue);
      expect(report.statePass, isTrue);
      expect(report.stateRestorePass, isTrue);

      // Lane 7: struct parity
      expect(report.structParityPass, isTrue);
      expect(report.parityPass, isTrue);

      // Canonical
      expect(report.canonicalPass, isTrue);
      expect(report.canonical, isTrue);

      // Aggregates
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.nativeAllLanesPass, isTrue);

      expect(report.details['glVersion'], 'OpenGL ES 3.2');
      expect(report.details['glRenderer'], 'Adreno (TM) 740');
      expect(report.details['colorTolerance'], 8);

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

      final roundTrip = VGTimelineOverlayGlesRenderSmokeReport.fromMap(
        serialized,
      );
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
    });

    test('fail report with one failed gate is not a pass', () {
      final report = _createSampleReport({
        'pass': false,
        'status': 'FAIL',
        'marker': _failMarker,
        'failureReason': 'opacityBlend_pixel_mismatch',
        'opacityBlendOk': false,
        'allNativeLanesPass': false,
        'nativeAllLanesPass': false,
      });

      expect(report.pass, isFalse);
      expect(report.decision, VGTimelineOverlayGlesRenderSmokeDecision.fail);
      expect(report.isFail, isTrue);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.opacityBlendPass, isFalse);
      expect(report.blendPass, isFalse);
      expect(report.singleLayerTransformPass, isTrue);
      expect(report.transformPass, isTrue);
      expect(report.validationPass, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(report.hasPassMarker, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.failureReason, 'opacityBlend_pixel_mismatch');
    });

    test('every single gate failure flips allNativeLanesPass and isPass', () {
      for (final key in _gateKeys) {
        final report = _createSampleReport({key: false});
        expect(report.gates[key], isFalse, reason: key);
        expect(report.allNativeLanesPass, isFalse, reason: key);
        expect(report.isPass, isFalse, reason: key);
        expect(report.isVerifiedPass, isFalse, reason: key);
      }
    });

    test('lane group getters reflect only their own keys', () {
      final setupFail = _createSampleReport({'eglSetupOk': false});
      expect(setupFail.setupPass, isFalse);
      expect(setupFail.eglSetupPass, isFalse);
      expect(setupFail.validationPass, isTrue);
      expect(setupFail.transformPass, isTrue);

      final valFail = _createSampleReport({
        'invalidDimensionsRejectedOk': false,
      });
      expect(valFail.validationPass, isFalse);
      expect(valFail.setupPass, isTrue);
      expect(valFail.transformPass, isTrue);

      final transFail = _createSampleReport({'singleLayerTransformOk': false});
      expect(transFail.transformPass, isFalse);
      expect(transFail.validationPass, isTrue);
      expect(transFail.blendPass, isTrue);

      final blendFail = _createSampleReport({'opacityBlendOk': false});
      expect(blendFail.blendPass, isFalse);
      expect(blendFail.transformPass, isTrue);
      expect(blendFail.zOrderPass, isTrue);

      final zFail = _createSampleReport({'multiLayerZOrderOk': false});
      expect(zFail.zOrderPass, isFalse);
      expect(zFail.blendPass, isTrue);
      expect(zFail.targetPass, isTrue);

      final targetFail = _createSampleReport({'oesTargetStructuralOk': false});
      expect(targetFail.targetPass, isFalse);
      expect(targetFail.textureTargetPass, isFalse);
      expect(targetFail.zOrderPass, isTrue);
      expect(targetFail.statePass, isTrue);

      final stateFail = _createSampleReport({'blendStateRestoredOk': false});
      expect(stateFail.statePass, isFalse);
      expect(stateFail.stateRestorePass, isFalse);
      expect(stateFail.targetPass, isTrue);
      expect(stateFail.parityPass, isTrue);

      final parityFail = _createSampleReport({'structParityOk': false});
      expect(parityFail.parityPass, isFalse);
      expect(parityFail.structParityPass, isFalse);
      expect(parityFail.statePass, isTrue);
      expect(parityFail.canonicalPass, isTrue);

      final canonicalFail = _createSampleReport({'canonical': false});
      expect(canonicalFail.canonicalPass, isFalse);
      expect(canonicalFail.canonical, isFalse);
      expect(canonicalFail.parityPass, isTrue);
    });

    test('wrong marker fails isPass even when all gates pass', () {
      final report = _createSampleReport({'marker': 'SOME_OTHER_MARKER'});
      expect(report.pass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
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
      expect(report.allNativeLanesPass, isTrue);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('native aggregate disagreement fails isPass', () {
      final report = _createSampleReport({'allNativeLanesPass': false});
      expect(report.allNativeLanesPass, isTrue);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test(
      'nativeAllLanesPass spelling accepted when allNativeLanesPass is absent',
      () {
        final raw = _createSampleRawMap()..remove('allNativeLanesPass');
        final report = VGTimelineOverlayGlesRenderSmokeReport.fromMap(raw);
        expect(report.nativeAllLanesPass, isTrue);
        expect(report.isPass, isTrue);

        final rawFalse = _createSampleRawMap({'nativeAllLanesPass': false})
          ..remove('allNativeLanesPass');
        final reportFalse = VGTimelineOverlayGlesRenderSmokeReport.fromMap(
          rawFalse,
        );
        expect(reportFalse.nativeAllLanesPass, isFalse);
        expect(reportFalse.isPass, isFalse);
      },
    );

    test('string "true"/"false" gate values are accepted', () {
      final report = _createSampleReport({
        'eglSetupOk': 'true',
        'singleLayerTransformOk': 'false',
        'allNativeLanesPass': 'true',
      });
      expect(report.eglSetupPass, isTrue);
      expect(report.singleLayerTransformPass, isFalse);
      expect(report.nativeAllLanesPass, isTrue);
      expect(report.isPass, isFalse);
    });

    test('raw String JSON parses successfully to valid pass report', () {
      final rawMap = _createSampleRawMap();
      final jsonStr = jsonEncode(rawMap);
      final report = VGTimelineOverlayGlesRenderSmokeReport.fromMap(jsonStr);

      expect(report.pass, isTrue);
      expect(report.isPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.nativeAllLanesPass, isTrue);
      expect(report.raw, equals(jsonStr));
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in <Object?>['not_a_map', null, 12345, 3.14, []]) {
        final report = VGTimelineOverlayGlesRenderSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(
          report.decision,
          VGTimelineOverlayGlesRenderSmokeDecision.harnessException,
        );
        expect(report.isHarnessException, isTrue);
        expect(report.failureReason, 'native_result_not_a_map');
        expect(report.marker, _failMarker);
        expect(report.proofBoundary, _proofBoundary);
        expect(report.allNativeLanesPass, isFalse);
        expect(report.isPass, isFalse);
        expect(report.isVerifiedPass, isFalse);
        for (final key in _gateKeys) {
          expect(report.gates[key], isFalse, reason: key);
        }
      }
    });

    test('fromMap handles missing/null fields defensively', () {
      final report = VGTimelineOverlayGlesRenderSmokeReport.fromMap({
        for (final key in _createSampleRawMap().keys) key: null,
      });
      expect(report.pass, isFalse);
      expect(report.decision, VGTimelineOverlayGlesRenderSmokeDecision.fail);
      expect(report.status, 'FAIL');
      expect(report.marker, isEmpty);
      expect(report.proofBoundary, isEmpty);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.details, isEmpty);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);

      final unsupported = VGTimelineOverlayGlesRenderSmokeReport.fromMap({
        'pass': false,
        'status': 'UNSUPPORTED',
      });
      expect(
        unsupported.decision,
        VGTimelineOverlayGlesRenderSmokeDecision.unsupported,
      );
      expect(unsupported.isUnsupported, isTrue);
    });

    test('contradictory pass=false with PASS status is a plain fail', () {
      final report = VGTimelineOverlayGlesRenderSmokeReport.fromMap({
        'pass': false,
        'status': 'PASS',
        'marker': _passMarker,
        'proofBoundary': _proofBoundary,
        for (final key in _gateKeys) key: true,
        'allNativeLanesPass': true,
      });
      expect(report.decision, VGTimelineOverlayGlesRenderSmokeDecision.fail);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('explicit decision field wins over status for failed reports', () {
      final report = VGTimelineOverlayGlesRenderSmokeReport.fromMap({
        'pass': false,
        'status': 'FAIL',
        'decision': 'harnessException',
      });
      expect(
        report.decision,
        VGTimelineOverlayGlesRenderSmokeDecision.harnessException,
      );
    });

    test('unsupported and harnessFailure factories are fail-shaped', () {
      final unsupported = VGTimelineOverlayGlesRenderSmokeReport.unsupported(
        'missing_plugin',
      );
      expect(unsupported.pass, isFalse);
      expect(unsupported.isUnsupported, isTrue);
      expect(unsupported.status, 'UNSUPPORTED');
      expect(unsupported.marker, _failMarker);
      expect(unsupported.proofBoundary, _proofBoundary);
      expect(unsupported.failureReason, 'missing_plugin');
      expect(unsupported.allNativeLanesPass, isFalse);
      expect(unsupported.isPass, isFalse);
      expect(unsupported.isVerifiedPass, isFalse);
      expect(unsupported.gates.length, _gateKeys.length);

      final harness = VGTimelineOverlayGlesRenderSmokeReport.harnessFailure(
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

  group('VGTimelineOverlayGlesRenderSmokeReport value semantics', () {
    test('equal values are equal with equal hash codes', () {
      final a = _createSampleReport();
      final b = _createSampleReport();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGTimelineOverlayGlesRenderSmokeReport('));
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
        {'singleLayerTransformOk': false},
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
      const channel = MethodChannel('test_overlay_gles_render_channel');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGTimelineOverlayGlesRenderSmokeReport.runAndroidDagPhase5TimelineOverlayGlesRenderSmoke(
            channel: channel,
          );

      expect(capturedCall, isNotNull);
      expect(capturedCall!.method, _method);
      expect(capturedCall!.arguments, isNull);
      expect(report.pass, isTrue);
      expect(report.isPass, isTrue);
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
          await VGTimelineOverlayGlesRenderSmokeReport.runAndroidDagPhase5TimelineOverlayGlesRenderSmoke();

      expect(capturedCall, isNotNull);
      expect(capturedCall!.method, _method);
      expect(report.pass, isTrue);
      expect(report.isPass, isTrue);
    });

    test('missing plugin yields an unsupported report', () async {
      const channel = MethodChannel('test_overlay_gles_render_missing');
      final report =
          await VGTimelineOverlayGlesRenderSmokeReport.runAndroidDagPhase5TimelineOverlayGlesRenderSmoke(
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, startsWith('missing_plugin'));
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('UNAVAILABLE platform exception yields an unsupported report', () async {
      const channel = MethodChannel('test_overlay_gles_render_unavail');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'UNAVAILABLE', message: 'no coordinator');
      });
      final report =
          await VGTimelineOverlayGlesRenderSmokeReport.runAndroidDagPhase5TimelineOverlayGlesRenderSmoke(
            channel: channel,
          );
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, 'platform_exception:UNAVAILABLE');
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('other platform exception yields a harnessException report', () async {
      const channel = MethodChannel('test_overlay_gles_render_pe');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'NATIVE_CRASH', message: 'Simulated');
      });
      final report =
          await VGTimelineOverlayGlesRenderSmokeReport.runAndroidDagPhase5TimelineOverlayGlesRenderSmoke(
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
      const channel = MethodChannel('test_overlay_gles_render_timeout');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });
      final report =
          await VGTimelineOverlayGlesRenderSmokeReport.runAndroidDagPhase5TimelineOverlayGlesRenderSmoke(
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
      const channel = MethodChannel('test_overlay_gles_render_generic');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw StateError('Generic unexpected error');
      });
      final report =
          await VGTimelineOverlayGlesRenderSmokeReport.runAndroidDagPhase5TimelineOverlayGlesRenderSmoke(
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
        const channel = MethodChannel('test_overlay_gles_render_nonmap');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          return 'status=PASS';
        });
        final report =
            await VGTimelineOverlayGlesRenderSmokeReport.runAndroidDagPhase5TimelineOverlayGlesRenderSmoke(
              channel: channel,
            );
        expect(report.isHarnessException, isTrue);
        expect(report.failureReason, 'native_result_not_a_map');
        expect(report.details['received'], 'status=PASS');
      },
    );

    test('raw String JSON return over channel parses successfully', () async {
      const channel = MethodChannel('test_overlay_gles_render_raw_json');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return jsonEncode(_createSampleRawMap());
      });
      final report =
          await VGTimelineOverlayGlesRenderSmokeReport.runAndroidDagPhase5TimelineOverlayGlesRenderSmoke(
            channel: channel,
          );
      expect(report.pass, isTrue);
      expect(report.isPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.hasPassMarker, isTrue);
    });

    test('native fail payload surfaces the failing lane and reason', () async {
      const channel = MethodChannel('test_overlay_gles_render_fail');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return _createSampleRawMap({
          'pass': false,
          'status': 'FAIL',
          'marker': _failMarker,
          'failureReason': 'singleLayerTransform_pixel_mismatch',
          'singleLayerTransformOk': false,
          'texture2dTargetAcceptedOk': false,
          'allNativeLanesPass': false,
          'nativeAllLanesPass': false,
        });
      });
      final report =
          await VGTimelineOverlayGlesRenderSmokeReport.runAndroidDagPhase5TimelineOverlayGlesRenderSmoke(
            channel: channel,
          );
      expect(report.isFail, isTrue);
      expect(report.singleLayerTransformPass, isFalse);
      expect(report.transformPass, isFalse);
      expect(report.texture2dTargetAcceptedPass, isFalse);
      expect(report.targetPass, isFalse);
      expect(report.blendPass, isTrue);
      expect(report.failureReason, 'singleLayerTransform_pixel_mismatch');
      expect(report.hasFailMarker, isTrue);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });
  });
}
