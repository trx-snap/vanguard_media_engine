// vg_timeline_overlay_text_rasterizer_smoke_test.dart
// vanguard_media_engine — P5-OVERLAYS-TEXT-RASTERIZER-DIAGNOSTIC:
// Android True-DAG AndroidTimelineOverlayTextRasterizer diagnostic
// smoke Dart model & MethodChannel tests.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_timeline_overlay_text_rasterizer_smoke.dart';

const String _proofBoundary =
    'android_kotlin_text_overlay_rasterizer_rgba_buffer_diagnostic_only_no_export_no_native_no_jni_no_product';
const String _passMarker =
    'ANDROID_DAG_PHASE5_OVERLAY_TEXT_RASTERIZER_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_OVERLAY_TEXT_RASTERIZER_PHYSICAL_SMOKE_FAIL';
const String _method = 'runAndroidDagPhase5TimelineOverlayTextRasterizerSmoke';

const List<String> _gateKeys = <String>[
  'validationPass',
  'backgroundPass',
  'transparentPass',
  'packingPass',
  'canonicalPass',
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
    'validationErrorsChecked': 7,
    'validationErrorsFound': 0,
    'bgWidth': 320,
    'bgHeight': 96,
    'bgRowStrideBytes': 1280,
    'bgCapacity': 122880,
    'bgNonZeroAlphaPixels': 30000,
    'bgWhiteLikePixels': 1200,
    'bgBlackBackgroundPixels': 28800,
    'transCornerAlpha': 0,
    'transTransparentAlphaPixels': 29520,
    'transWhiteLikePixels': 1200,
    'bgBufferDirect': true,
    'transBufferDirect': true,
    'bgBufferOrder': 'LITTLE_ENDIAN',
    'bgBufferPosition': 0,
    'transBufferPosition': 0,
  },
  'raw': '{"pass":true,"status":"PASS"}',
  if (overrides != null) ...overrides,
};

VGTimelineOverlayTextRasterizerSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGTimelineOverlayTextRasterizerSmokeReport.fromMap(
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
        VGTimelineOverlayTextRasterizerSmokeReport.proofBoundaryConstant,
        equals(_proofBoundary),
      );
      expect(
        VGTimelineOverlayTextRasterizerSmokeReport.passMarker,
        equals(_passMarker),
      );
      expect(
        VGTimelineOverlayTextRasterizerSmokeReport.failMarker,
        equals(_failMarker),
      );
      expect(
        VGTimelineOverlayTextRasterizerSmokeReport.methodName,
        equals(_method),
      );
      expect(
        VGTimelineOverlayTextRasterizerSmokeReport.allGateKeys,
        orderedEquals(_gateKeys),
      );
      expect(
        VGTimelineOverlayTextRasterizerSmokeReport.gateKeys,
        orderedEquals(_gateKeys),
      );
      expect(_gateKeys.length, 5);
      expect(_gateKeys.toSet().length, 5, reason: 'unique gate keys');
    });
  });

  group('VGTimelineOverlayTextRasterizerSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 4 values in order', () {
      expect(
        VGTimelineOverlayTextRasterizerSmokeDecision.values,
        orderedEquals(const [
          VGTimelineOverlayTextRasterizerSmokeDecision.pass,
          VGTimelineOverlayTextRasterizerSmokeDecision.fail,
          VGTimelineOverlayTextRasterizerSmokeDecision.unsupported,
          VGTimelineOverlayTextRasterizerSmokeDecision.harnessException,
        ]),
      );
    });

    test('fromRaw maps all known decision strings', () {
      expect(
        VGTimelineOverlayTextRasterizerSmokeDecision.fromRaw('pass'),
        VGTimelineOverlayTextRasterizerSmokeDecision.pass,
      );
      expect(
        VGTimelineOverlayTextRasterizerSmokeDecision.fromRaw('PASS'),
        VGTimelineOverlayTextRasterizerSmokeDecision.pass,
      );
      expect(
        VGTimelineOverlayTextRasterizerSmokeDecision.fromRaw('fail'),
        VGTimelineOverlayTextRasterizerSmokeDecision.fail,
      );
      expect(
        VGTimelineOverlayTextRasterizerSmokeDecision.fromRaw('UNSUPPORTED'),
        VGTimelineOverlayTextRasterizerSmokeDecision.unsupported,
      );
      expect(
        VGTimelineOverlayTextRasterizerSmokeDecision.fromRaw(
          'harnessException',
        ),
        VGTimelineOverlayTextRasterizerSmokeDecision.harnessException,
      );
      expect(
        VGTimelineOverlayTextRasterizerSmokeDecision.fromRaw(
          'harness_exception',
        ),
        VGTimelineOverlayTextRasterizerSmokeDecision.harnessException,
      );
    });

    test('fromRaw falls back to harnessException for unknown values', () {
      for (final invalid in <Object?>['bogus', '', null, 1, 2.0, true, []]) {
        expect(
          VGTimelineOverlayTextRasterizerSmokeDecision.fromRaw(invalid),
          VGTimelineOverlayTextRasterizerSmokeDecision.harnessException,
        );
      }
    });
  });

  group('VGTimelineOverlayTextRasterizerSmokeReport fromMap / toMap', () {
    test('pass report parses every gate and round-trips', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(
        report.decision,
        VGTimelineOverlayTextRasterizerSmokeDecision.pass,
      );
      expect(report.isPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.isFail, isFalse);
      expect(report.isUnsupported, isFalse);
      expect(report.isHarnessException, isFalse);
      expect(report.status, 'PASS');
      expect(report.marker, _passMarker);
      expect(report.proofBoundary, _proofBoundary);
      expect(report.failureReason, isEmpty);

      // Lanes
      expect(report.validationPass, isTrue);
      expect(report.backgroundPass, isTrue);
      expect(report.transparentPass, isTrue);
      expect(report.packingPass, isTrue);
      expect(report.canonicalPass, isTrue);
      expect(report.canonical, isTrue);

      // Aggregates
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.nativeAllLanesPass, isTrue);

      expect(report.details['bgWidth'], 320);
      expect(report.details['bgHeight'], 96);
      expect(report.details['bgRowStrideBytes'], 1280);

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

      final roundTrip = VGTimelineOverlayTextRasterizerSmokeReport.fromMap(
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
        'failureReason': 'lane2_background:bg_no_whitelike_pixels',
        'backgroundPass': false,
        'allNativeLanesPass': false,
        'nativeAllLanesPass': false,
      });

      expect(report.pass, isFalse);
      expect(
        report.decision,
        VGTimelineOverlayTextRasterizerSmokeDecision.fail,
      );
      expect(report.isFail, isTrue);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.backgroundPass, isFalse);
      expect(report.validationPass, isTrue);
      expect(report.transparentPass, isTrue);
      expect(report.packingPass, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(report.hasPassMarker, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.failureReason, 'lane2_background:bg_no_whitelike_pixels');
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

    test('wrong marker fails isPass even when all gates pass', () {
      final report = _createSampleReport({'marker': 'SOME_OTHER_MARKER'});
      expect(report.pass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.hasPassMarker, isFalse);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
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

    test('raw String JSON parses successfully to valid pass report', () {
      final rawMap = _createSampleRawMap();
      final jsonStr = jsonEncode(rawMap);
      final report = VGTimelineOverlayTextRasterizerSmokeReport.fromMap(
        jsonStr,
      );

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
        final report = VGTimelineOverlayTextRasterizerSmokeReport.fromMap(
          invalid,
        );
        expect(report.pass, isFalse);
        expect(
          report.decision,
          VGTimelineOverlayTextRasterizerSmokeDecision.harnessException,
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
      final report = VGTimelineOverlayTextRasterizerSmokeReport.fromMap({
        for (final key in _createSampleRawMap().keys) key: null,
      });
      expect(report.pass, isFalse);
      expect(
        report.decision,
        VGTimelineOverlayTextRasterizerSmokeDecision.fail,
      );
      expect(report.status, 'FAIL');
      expect(report.marker, isEmpty);
      expect(report.proofBoundary, isEmpty);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.details, isEmpty);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);

      final unsupported = VGTimelineOverlayTextRasterizerSmokeReport.fromMap({
        'pass': false,
        'status': 'UNSUPPORTED',
      });
      expect(
        unsupported.decision,
        VGTimelineOverlayTextRasterizerSmokeDecision.unsupported,
      );
      expect(unsupported.isUnsupported, isTrue);
    });

    test('unsupported and harnessFailure factories are fail-shaped', () {
      final unsupported =
          VGTimelineOverlayTextRasterizerSmokeReport.unsupported(
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

      final harness = VGTimelineOverlayTextRasterizerSmokeReport.harnessFailure(
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

  group('MethodChannel runner invocation', () {
    test('invokes the exact route name and parses a pass report', () async {
      MethodCall? capturedCall;
      const channel = MethodChannel('test_overlay_text_channel');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGTimelineOverlayTextRasterizerSmokeReport.runAndroidDagPhase5TimelineOverlayTextRasterizerSmoke(
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
          await VGTimelineOverlayTextRasterizerSmokeReport.runAndroidDagPhase5TimelineOverlayTextRasterizerSmoke();

      expect(capturedCall, isNotNull);
      expect(capturedCall!.method, _method);
      expect(report.pass, isTrue);
      expect(report.isPass, isTrue);
    });

    test('missing plugin yields an unsupported report', () async {
      const channel = MethodChannel('test_overlay_text_missing');
      final report =
          await VGTimelineOverlayTextRasterizerSmokeReport.runAndroidDagPhase5TimelineOverlayTextRasterizerSmoke(
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, startsWith('missing_plugin'));
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('UNAVAILABLE platform exception yields an unsupported report', () async {
      const channel = MethodChannel('test_overlay_text_unavail');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'UNAVAILABLE', message: 'no coordinator');
      });
      final report =
          await VGTimelineOverlayTextRasterizerSmokeReport.runAndroidDagPhase5TimelineOverlayTextRasterizerSmoke(
            channel: channel,
          );
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, 'platform_exception:UNAVAILABLE');
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('other platform exception yields a harnessException report', () async {
      const channel = MethodChannel('test_overlay_text_pe');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'INTERNAL_ERROR', message: 'Simulated');
      });
      final report =
          await VGTimelineOverlayTextRasterizerSmokeReport.runAndroidDagPhase5TimelineOverlayTextRasterizerSmoke(
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, 'platform_exception:INTERNAL_ERROR');
      expect(report.details['code'], 'INTERNAL_ERROR');
      expect(report.details['message'], 'Simulated');
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('timeout yields a harnessException report', () async {
      const channel = MethodChannel('test_overlay_text_timeout');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });
      final report =
          await VGTimelineOverlayTextRasterizerSmokeReport.runAndroidDagPhase5TimelineOverlayTextRasterizerSmoke(
            timeout: const Duration(milliseconds: 20),
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, 'timeout');
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test(
      'non-map non-json native result yields a harnessException report',
      () async {
        const channel = MethodChannel('test_overlay_text_nonmap');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          return 'status=PASS';
        });
        final report =
            await VGTimelineOverlayTextRasterizerSmokeReport.runAndroidDagPhase5TimelineOverlayTextRasterizerSmoke(
              channel: channel,
            );
        expect(report.isHarnessException, isTrue);
        expect(report.failureReason, 'native_result_not_a_map');
        expect(report.details['received'], 'status=PASS');
      },
    );
  });
}
