// vg_gles_export_overlay_production_smoke_test.dart
// vanguard_media_engine - P5-GLES-EXPORT-OVERLAY-PRODUCTION-ROUTE-A:
// Dart model & MethodChannel tests for production GLES export overlay verification harness.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_gles_export_overlay_production_smoke.dart';

const String _proofBoundary =
    'production_android_timeline_gles_overlay_export_forced_encoder_route_a';
const String _passMarker =
    'ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_PRODUCTION_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_PRODUCTION_PHYSICAL_SMOKE_FAIL';
const String _method = 'runAndroidDagPhase5GlesExportOverlayProductionSmoke';

const List<String> _gateKeys = <String>[
  'inputValidationOk',
  'sourceMetadataOk',
  'baselineEncodeOk',
  'overlayEncodeOk',
  'overlayFrameCountOk',
  'frameExtractOk',
  'pixelDeltaOk',
  'missingBridgeRejectedOk',
  'stillImageOverlayEncodeOk',
  'glMajorVersionOk',
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
    'baselineWrittenSamples': 30,
    'overlayWrittenSamples': 30,
    'overlayFrameCount': 30,
    'changedPixels': 240,
    'meanDelta': 42.5,
    'baselineGlMajorVersion': 3,
    'overlayGlMajorVersion': 3,
    'stillImageOverlayGlMajorVersion': 3,
    'expectedPhysicalMinGlMajorVersion': 3,
    'glMajorVersionDetails':
        'baseline=3 overlay=3 stillImageOverlay=3 expectedPhysicalMin=3(SM-A566B)',
  },
  'raw': '{"pass":true,"status":"PASS"}',
  if (overrides != null) ...overrides,
};

VGGlesExportOverlayProductionSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGGlesExportOverlayProductionSmokeReport.fromMap(
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
    test('canonical strings and gate keys match frozen contract', () {
      expect(
        VGGlesExportOverlayProductionSmokeReport.proofBoundaryConstant,
        equals(_proofBoundary),
      );
      expect(
        VGGlesExportOverlayProductionSmokeReport.passMarker,
        equals(_passMarker),
      );
      expect(
        VGGlesExportOverlayProductionSmokeReport.failMarker,
        equals(_failMarker),
      );
      expect(
        VGGlesExportOverlayProductionSmokeReport.methodName,
        equals(_method),
      );
      expect(
        VGGlesExportOverlayProductionSmokeReport.allGateKeys,
        orderedEquals(_gateKeys),
      );
      expect(
        VGGlesExportOverlayProductionSmokeReport.validationGateKeys.length,
        2,
      );
      expect(VGGlesExportOverlayProductionSmokeReport.encodeGateKeys.length, 3);
      expect(VGGlesExportOverlayProductionSmokeReport.pixelGateKeys.length, 2);
      expect(
        VGGlesExportOverlayProductionSmokeReport.failClosedGateKeys.length,
        1,
      );
      expect(
        VGGlesExportOverlayProductionSmokeReport
            .stillImageOverlayGateKeys
            .length,
        1,
      );
      expect(
        VGGlesExportOverlayProductionSmokeReport.glMajorVersionGateKeys.length,
        1,
      );
      expect(
        VGGlesExportOverlayProductionSmokeReport.cleanupGateKeys.length,
        1,
      );
      expect(
        VGGlesExportOverlayProductionSmokeReport.canonicalGateKeys.length,
        1,
      );
      expect(_gateKeys.toSet().length, 12, reason: 'unique');
      expect(_gateKeys.length, 12);
    });
  });

  group('VGGlesExportOverlayProductionSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 4 values in order', () {
      expect(
        VGGlesExportOverlayProductionSmokeDecision.values,
        orderedEquals(const [
          VGGlesExportOverlayProductionSmokeDecision.pass,
          VGGlesExportOverlayProductionSmokeDecision.fail,
          VGGlesExportOverlayProductionSmokeDecision.unsupported,
          VGGlesExportOverlayProductionSmokeDecision.harnessException,
        ]),
      );
    });

    test('fromRaw maps all known decision strings', () {
      expect(
        VGGlesExportOverlayProductionSmokeDecision.fromRaw('pass'),
        VGGlesExportOverlayProductionSmokeDecision.pass,
      );
      expect(
        VGGlesExportOverlayProductionSmokeDecision.fromRaw('PASS'),
        VGGlesExportOverlayProductionSmokeDecision.pass,
      );
      expect(
        VGGlesExportOverlayProductionSmokeDecision.fromRaw('fail'),
        VGGlesExportOverlayProductionSmokeDecision.fail,
      );
      expect(
        VGGlesExportOverlayProductionSmokeDecision.fromRaw('UNSUPPORTED'),
        VGGlesExportOverlayProductionSmokeDecision.unsupported,
      );
      expect(
        VGGlesExportOverlayProductionSmokeDecision.fromRaw('harnessException'),
        VGGlesExportOverlayProductionSmokeDecision.harnessException,
      );
      expect(
        VGGlesExportOverlayProductionSmokeDecision.fromRaw('harness_exception'),
        VGGlesExportOverlayProductionSmokeDecision.harnessException,
      );
    });

    test('fromRaw falls back to harnessException for unknown values', () {
      for (final invalid in <Object?>['unknown', '', null, 123, false, []]) {
        expect(
          VGGlesExportOverlayProductionSmokeDecision.fromRaw(invalid),
          VGGlesExportOverlayProductionSmokeDecision.harnessException,
        );
      }
    });
  });

  group('VGGlesExportOverlayProductionSmokeReport fromMap / toMap', () {
    test('pass report parses every gate and round-trips', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(report.decision, VGGlesExportOverlayProductionSmokeDecision.pass);
      expect(report.isPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.isFail, isFalse);
      expect(report.isUnsupported, isFalse);
      expect(report.isHarnessException, isFalse);
      expect(report.status, 'PASS');
      expect(report.marker, _passMarker);
      expect(report.proofBoundary, _proofBoundary);
      expect(report.failureReason, isEmpty);

      expect(report.inputValidationPass, isTrue);
      expect(report.sourceMetadataPass, isTrue);
      expect(report.validationPass, isTrue);

      expect(report.baselineEncodePass, isTrue);
      expect(report.overlayEncodePass, isTrue);
      expect(report.overlayFrameCountPass, isTrue);
      expect(report.encodeGroupPass, isTrue);

      expect(report.frameExtractPass, isTrue);
      expect(report.pixelDeltaPass, isTrue);
      expect(report.pixelPass, isTrue);

      expect(report.missingBridgeRejectedPass, isTrue);
      expect(report.failClosedPass, isTrue);

      expect(report.stillImageOverlayEncodePass, isTrue);
      expect(report.stillImageOverlayPass, isTrue);

      expect(report.glMajorVersionOkPass, isTrue);
      expect(report.glMajorVersionPass, isTrue);
      expect(report.baselineGlMajorVersion, 3);
      expect(report.overlayGlMajorVersion, 3);
      expect(report.stillImageOverlayGlMajorVersion, 3);
      expect(report.expectedPhysicalMinGlMajorVersion, 3);
      expect(report.glMajorVersionDetails, isNotNull);

      expect(report.cleanupPass, isTrue);
      expect(report.cleanupGroupPass, isTrue);

      expect(report.canonicalPass, isTrue);
      expect(report.canonical, isTrue);

      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);
      expect(report.allGatesPass, isTrue);

      final serialized = report.toMap();
      expect(serialized['pass'], isTrue);
      expect(serialized['decision'], 'pass');
      expect(serialized['marker'], _passMarker);
      expect(serialized['proofBoundary'], _proofBoundary);
      for (final key in _gateKeys) {
        expect(serialized[key], isTrue, reason: key);
      }

      final roundTrip = VGGlesExportOverlayProductionSmokeReport.fromMap(
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
        'failureReason': 'pixel_delta_insufficient',
        'pixelDeltaOk': false,
      });

      expect(report.pass, isFalse);
      expect(report.decision, VGGlesExportOverlayProductionSmokeDecision.fail);
      expect(report.isFail, isTrue);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.pixelDeltaPass, isFalse);
      expect(report.pixelPass, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(report.hasPassMarker, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.failureReason, 'pixel_delta_insufficient');
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
      final inputFail = _createSampleReport({'inputValidationOk': false});
      expect(inputFail.validationPass, isFalse);
      expect(inputFail.encodeGroupPass, isTrue);
      expect(inputFail.pixelPass, isTrue);

      final encodeFail = _createSampleReport({'overlayEncodeOk': false});
      expect(encodeFail.encodeGroupPass, isFalse);
      expect(encodeFail.validationPass, isTrue);

      final pixelFail = _createSampleReport({'frameExtractOk': false});
      expect(pixelFail.pixelPass, isFalse);
      expect(pixelFail.failClosedPass, isTrue);

      final failClosedFail = _createSampleReport({
        'missingBridgeRejectedOk': false,
      });
      expect(failClosedFail.failClosedPass, isFalse);
      expect(failClosedFail.cleanupGroupPass, isTrue);

      final glMajorVersionFail = _createSampleReport({
        'glMajorVersionOk': false,
      });
      expect(glMajorVersionFail.glMajorVersionPass, isFalse);
      expect(glMajorVersionFail.stillImageOverlayPass, isTrue);
      expect(glMajorVersionFail.cleanupGroupPass, isTrue);
      expect(glMajorVersionFail.canonicalPass, isTrue);
      expect(
        glMajorVersionFail.isPass,
        isFalse,
        reason:
            'a native glMajorVersionOk=false (e.g. an ES2 fallback on the '
            'ES3-expected physical device, or a version mismatch across '
            'baseline/overlay/still-image encodes) must flip overall isPass '
            'to false even when every other gate reports true',
      );

      final cleanupFail = _createSampleReport({'cleanupOk': false});
      expect(cleanupFail.cleanupGroupPass, isFalse);
    });

    test('JSON string input parses correctly', () {
      final jsonStr = jsonEncode(_createSampleRawMap());
      final report = VGGlesExportOverlayProductionSmokeReport.fromMap(jsonStr);
      expect(report.isPass, isTrue);
      expect(report.raw, equals(jsonStr));
    });

    test('null / invalid input returns harnessFailure report', () {
      final report = VGGlesExportOverlayProductionSmokeReport.fromMap(null);
      expect(report.isHarnessException, isTrue);
      expect(report.isPass, isFalse);
      expect(report.failureReason, 'native_result_not_a_map');
    });

    test(
      'contradictory payload (pass=false with status=PASS) resolves to fail',
      () {
        final report = _createSampleReport({'pass': false, 'status': 'PASS'});
        expect(report.isPass, isFalse);
        expect(
          report.decision,
          equals(VGGlesExportOverlayProductionSmokeDecision.fail),
        );
      },
    );
  });

  group('synthetic report factories', () {
    test('unsupported factory creates well-formed unsupported report', () {
      final report = VGGlesExportOverlayProductionSmokeReport.unsupported(
        'not_android',
      );
      expect(report.pass, isFalse);
      expect(report.isUnsupported, isTrue);
      expect(report.status, 'UNSUPPORTED');
      expect(report.failureReason, 'not_android');
      expect(report.marker, _failMarker);
      expect(report.proofBoundary, _proofBoundary);
      expect(report.allGatesPass, isFalse);
      expect(report.canonicalPass, isFalse);
    });

    test('harnessFailure factory creates well-formed failure report', () {
      final report = VGGlesExportOverlayProductionSmokeReport.harnessFailure(
        'timed_out',
        extraDetails: const {'detail': 'foo'},
      );
      expect(report.pass, isFalse);
      expect(report.isHarnessException, isTrue);
      expect(report.status, 'FAIL');
      expect(report.failureReason, 'timed_out');
      expect(report.details['detail'], 'foo');
    });
  });

  group('MethodChannel invocation', () {
    test('invokes method channel and parses result correctly', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        if (call.method == _method) {
          final args = call.arguments as Map<dynamic, dynamic>;
          expect(args['videoPath'], equals('/path/to/video.mp4'));
          expect(args['stickerPath'], equals('/path/to/sticker.png'));
          expect(args['outputDir'], equals('/path/to/out'));
          return _createSampleRawMap();
        }
        return null;
      });

      final report =
          await VGGlesExportOverlayProductionSmokeReport.runAndroidDagPhase5GlesExportOverlayProductionSmoke(
            videoPath: '/path/to/video.mp4',
            stickerPath: '/path/to/sticker.png',
            outputDir: '/path/to/out',
          );

      expect(report.isVerifiedPass, isTrue);
    });

    test('handles timeout correctly', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return _createSampleRawMap();
      });

      final report =
          await VGGlesExportOverlayProductionSmokeReport.runAndroidDagPhase5GlesExportOverlayProductionSmoke(
            videoPath: '/path/to/video.mp4',
            stickerPath: '/path/to/sticker.png',
            outputDir: '/path/to/out',
            timeout: const Duration(milliseconds: 10),
          );

      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, equals('timeout'));
    });

    test('handles MissingPluginException correctly', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        throw MissingPluginException();
      });

      final report =
          await VGGlesExportOverlayProductionSmokeReport.runAndroidDagPhase5GlesExportOverlayProductionSmoke(
            videoPath: '/path/to/video.mp4',
            stickerPath: '/path/to/sticker.png',
            outputDir: '/path/to/out',
          );

      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, startsWith('missing_plugin:'));
    });

    test('handles PlatformException UNAVAILABLE correctly', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        throw PlatformException(code: 'UNAVAILABLE', message: 'Not available');
      });

      final report =
          await VGGlesExportOverlayProductionSmokeReport.runAndroidDagPhase5GlesExportOverlayProductionSmoke(
            videoPath: '/path/to/video.mp4',
            stickerPath: '/path/to/sticker.png',
            outputDir: '/path/to/out',
          );

      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, equals('platform_exception:UNAVAILABLE'));
    });

    test('handles generic PlatformException as harnessFailure', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        throw PlatformException(code: 'CODEC_ERR', message: 'Codec crashed');
      });

      final report =
          await VGGlesExportOverlayProductionSmokeReport.runAndroidDagPhase5GlesExportOverlayProductionSmoke(
            videoPath: '/path/to/video.mp4',
            stickerPath: '/path/to/sticker.png',
            outputDir: '/path/to/out',
          );

      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, equals('platform_exception:CODEC_ERR'));
    });

    test('handles generic exception as harnessFailure', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        throw StateError('generic error');
      });

      final report =
          await VGGlesExportOverlayProductionSmokeReport.runAndroidDagPhase5GlesExportOverlayProductionSmoke(
            videoPath: '/path/to/video.mp4',
            stickerPath: '/path/to/sticker.png',
            outputDir: '/path/to/out',
          );

      expect(report.isHarnessException, isTrue);
      expect(
        report.failureReason,
        anyOf(startsWith('platform_exception:'), startsWith('exception:')),
      );
    });
  });
}
