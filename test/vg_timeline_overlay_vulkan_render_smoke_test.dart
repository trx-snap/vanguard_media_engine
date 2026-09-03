// vg_timeline_overlay_vulkan_render_smoke_test.dart
// vanguard_media_engine — P5-OVERLAYS-TRANS (sub-slice VULKAN-RENDER):
// Android True-DAG VulkanOverlayCompositor shader/raster diagnostic
// smoke Dart model & MethodChannel tests.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_timeline_overlay_vulkan_render_smoke.dart';

const String _proofBoundary =
    'native_vulkan_timeline_overlay_compositor_shader_raster_only_no_decode_no_export_no_product';
const String _passMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_VULKAN_RENDER_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_VULKAN_RENDER_PHYSICAL_SMOKE_FAIL';
const String _method = 'runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke';

const List<String> _gateKeys = <String>[
  'vulkanSetupOk',
  'invalidImageRejectedOk',
  'invalidDimensionsRejectedOk',
  'nonFiniteTransformRejectedOk',
  'invalidOpacityRejectedOk',
  'mixedListRejectedBeforeDrawOk',
  'singleLayerTransformOk',
  'arbitraryRotationOk',
  'opacityBlendOk',
  'alphaAccumulationOk',
  'multiLayerZOrderOk',
  'existingContentsCompositeOk',
  'helperResourcesReleasedOk',
  'diagnosticTeardownOk',
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
    'deviceName': 'Adreno (TM) 740',
    'deviceType': 2,
    'apiVersion': '1.3.0',
    'driverVersion': 12345,
    'queueFamilyIndex': 0,
    'canvasWidth': 64,
    'canvasHeight': 64,
    'colorTolerance': 8,
    'vulkanDeviceInitOk': true,
    'syntheticResourcesOk': true,
    'readbackMemoryCoherent': true,
    'helperTemporaryObjectsCreated': 8,
    'helperTemporaryObjectsReleased': 8,
  },
  'raw': '{"pass":true,"status":"PASS"}',
  if (overrides != null) ...overrides,
};

VGTimelineOverlayVulkanRenderSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGTimelineOverlayVulkanRenderSmokeReport.fromMap(
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
        VGTimelineOverlayVulkanRenderSmokeReport.proofBoundaryConstant,
        equals(_proofBoundary),
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeReport.passMarker,
        equals(_passMarker),
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeReport.failMarker,
        equals(_failMarker),
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeReport.methodName,
        equals(_method),
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeReport.allGateKeys,
        orderedEquals(_gateKeys),
      );
      expect(VGTimelineOverlayVulkanRenderSmokeReport.setupGateKeys.length, 1);
      expect(
        VGTimelineOverlayVulkanRenderSmokeReport.validationGateKeys.length,
        5,
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeReport.paramValidationGateKeys.length,
        5,
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeReport.transformGateKeys.length,
        2,
      );
      expect(VGTimelineOverlayVulkanRenderSmokeReport.blendGateKeys.length, 2);
      expect(VGTimelineOverlayVulkanRenderSmokeReport.zOrderGateKeys.length, 2);
      expect(
        VGTimelineOverlayVulkanRenderSmokeReport.stackingGateKeys.length,
        2,
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeReport.compositeGateKeys.length,
        2,
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeReport
            .resourceLifecycleGateKeys
            .length,
        2,
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeReport.cleanupGateKeys.length,
        2,
      );
      expect(VGTimelineOverlayVulkanRenderSmokeReport.parityGateKeys.length, 1);
      expect(
        VGTimelineOverlayVulkanRenderSmokeReport.structParityGateKeys.length,
        1,
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeReport.canonicalGateKeys.length,
        1,
      );
      expect(_gateKeys.toSet().length, 16, reason: 'unique');
      expect(_gateKeys.length, 16);
    });
  });

  group('VGTimelineOverlayVulkanRenderSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 4 values in order', () {
      expect(
        VGTimelineOverlayVulkanRenderSmokeDecision.values,
        orderedEquals(const [
          VGTimelineOverlayVulkanRenderSmokeDecision.pass,
          VGTimelineOverlayVulkanRenderSmokeDecision.fail,
          VGTimelineOverlayVulkanRenderSmokeDecision.unsupported,
          VGTimelineOverlayVulkanRenderSmokeDecision.harnessException,
        ]),
      );
    });

    test('fromRaw maps all known decision strings', () {
      expect(
        VGTimelineOverlayVulkanRenderSmokeDecision.fromRaw('pass'),
        VGTimelineOverlayVulkanRenderSmokeDecision.pass,
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeDecision.fromRaw('PASS'),
        VGTimelineOverlayVulkanRenderSmokeDecision.pass,
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeDecision.fromRaw('fail'),
        VGTimelineOverlayVulkanRenderSmokeDecision.fail,
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeDecision.fromRaw('FAIL'),
        VGTimelineOverlayVulkanRenderSmokeDecision.fail,
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeDecision.fromRaw('unsupported'),
        VGTimelineOverlayVulkanRenderSmokeDecision.unsupported,
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeDecision.fromRaw('UNSUPPORTED'),
        VGTimelineOverlayVulkanRenderSmokeDecision.unsupported,
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeDecision.fromRaw('harnessException'),
        VGTimelineOverlayVulkanRenderSmokeDecision.harnessException,
      );
      expect(
        VGTimelineOverlayVulkanRenderSmokeDecision.fromRaw('harness_exception'),
        VGTimelineOverlayVulkanRenderSmokeDecision.harnessException,
      );
    });

    test('fromRaw falls back to harnessException for unknown values', () {
      for (final invalid in <Object?>['bogus', '', null, 1, 2.0, true, []]) {
        expect(
          VGTimelineOverlayVulkanRenderSmokeDecision.fromRaw(invalid),
          VGTimelineOverlayVulkanRenderSmokeDecision.harnessException,
        );
      }
    });
  });

  group('VGTimelineOverlayVulkanRenderSmokeReport fromMap / toMap', () {
    test('pass report parses every gate and round-trips', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(report.decision, VGTimelineOverlayVulkanRenderSmokeDecision.pass);
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
      expect(report.vulkanSetupPass, isTrue);
      expect(report.setupPass, isTrue);

      // Lane 1: validation
      expect(report.invalidImageRejectedPass, isTrue);
      expect(report.invalidDimensionsRejectedPass, isTrue);
      expect(report.nonFiniteTransformRejectedPass, isTrue);
      expect(report.invalidOpacityRejectedPass, isTrue);
      expect(report.mixedListRejectedBeforeDrawPass, isTrue);
      expect(report.validationPass, isTrue);
      expect(report.paramValidationPass, isTrue);

      // Lane 2: transform & rotation
      expect(report.singleLayerTransformPass, isTrue);
      expect(report.arbitraryRotationPass, isTrue);
      expect(report.transformPass, isTrue);

      // Lane 3: blend & alpha accumulation
      expect(report.opacityBlendPass, isTrue);
      expect(report.alphaAccumulationPass, isTrue);
      expect(report.blendPass, isTrue);

      // Lane 4: z-order & composite
      expect(report.multiLayerZOrderPass, isTrue);
      expect(report.existingContentsCompositePass, isTrue);
      expect(report.zOrderPass, isTrue);
      expect(report.stackingPass, isTrue);
      expect(report.compositePass, isTrue);

      // Lane 5: resource lifecycle & teardown
      expect(report.helperResourcesReleasedPass, isTrue);
      expect(report.diagnosticTeardownPass, isTrue);
      expect(report.resourceLifecyclePass, isTrue);
      expect(report.cleanupPass, isTrue);

      // Lane 6: struct parity
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

      expect(report.details['deviceName'], 'Adreno (TM) 740');
      expect(report.details['apiVersion'], '1.3.0');
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

      final roundTrip = VGTimelineOverlayVulkanRenderSmokeReport.fromMap(
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
      expect(report.decision, VGTimelineOverlayVulkanRenderSmokeDecision.fail);
      expect(report.isFail, isTrue);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.opacityBlendPass, isFalse);
      expect(report.blendPass, isFalse);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.hasPassMarker, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(report.failureReason, 'opacityBlend_pixel_mismatch');
    });

    test('accepts raw JSON string and parses correctly', () {
      final jsonStr = jsonEncode(_createSampleRawMap());
      final report = VGTimelineOverlayVulkanRenderSmokeReport.fromMap(jsonStr);
      expect(report.pass, isTrue);
      expect(report.isPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.raw, equals(jsonStr));
    });

    test('returns harnessFailure when input is null or invalid', () {
      final nullReport = VGTimelineOverlayVulkanRenderSmokeReport.fromMap(null);
      expect(nullReport.pass, isFalse);
      expect(
        nullReport.decision,
        VGTimelineOverlayVulkanRenderSmokeDecision.harnessException,
      );
      expect(nullReport.isHarnessException, isTrue);
      expect(nullReport.isPass, isFalse);
      expect(nullReport.failureReason, 'native_result_not_a_map');

      final stringReport = VGTimelineOverlayVulkanRenderSmokeReport.fromMap(
        'not a json string',
      );
      expect(stringReport.pass, isFalse);
      expect(
        stringReport.decision,
        VGTimelineOverlayVulkanRenderSmokeDecision.harnessException,
      );
    });
  });

  group('individual gate failures fail closed', () {
    for (final gateKey in _gateKeys) {
      test('failing gate $gateKey makes report non-pass', () {
        final report = _createSampleReport({
          'pass': false,
          'status': 'FAIL',
          'marker': _failMarker,
          'failureReason': '$gateKey failed',
          gateKey: false,
          'allNativeLanesPass': false,
          'nativeAllLanesPass': false,
        });

        expect(report.pass, isFalse, reason: 'pass should be false');
        expect(report.isPass, isFalse, reason: 'isPass should be false');
        expect(
          report.isVerifiedPass,
          isFalse,
          reason: 'isVerifiedPass should be false',
        );
        expect(
          report.gates[gateKey],
          isFalse,
          reason: 'gate $gateKey should be false',
        );
        expect(
          report.allNativeLanesPass,
          isFalse,
          reason: 'allNativeLanesPass should be false',
        );
      });
    }

    test('vulkanSetupOk false fails setup lane', () {
      final report = _createSampleReport({'vulkanSetupOk': false});
      expect(report.vulkanSetupPass, isFalse);
      expect(report.setupPass, isFalse);
    });

    test('validation gate failures fail validation lane', () {
      expect(
        _createSampleReport({'invalidImageRejectedOk': false}).validationPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'invalidDimensionsRejectedOk': false,
        }).validationPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'nonFiniteTransformRejectedOk': false,
        }).validationPass,
        isFalse,
      );
      expect(
        _createSampleReport({'invalidOpacityRejectedOk': false}).validationPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'mixedListRejectedBeforeDrawOk': false,
        }).validationPass,
        isFalse,
      );
    });

    test('transform gate failures fail transform lane', () {
      expect(
        _createSampleReport({'singleLayerTransformOk': false}).transformPass,
        isFalse,
      );
      expect(
        _createSampleReport({'arbitraryRotationOk': false}).transformPass,
        isFalse,
      );
    });

    test('blend gate failures fail blend lane', () {
      expect(_createSampleReport({'opacityBlendOk': false}).blendPass, isFalse);
      expect(
        _createSampleReport({'alphaAccumulationOk': false}).blendPass,
        isFalse,
      );
    });

    test('z-order gate failures fail zOrder lane', () {
      expect(
        _createSampleReport({'multiLayerZOrderOk': false}).zOrderPass,
        isFalse,
      );
      expect(
        _createSampleReport({
          'existingContentsCompositeOk': false,
        }).compositePass,
        isFalse,
      );
    });

    test('lifecycle gate failures fail resourceLifecycle lane', () {
      expect(
        _createSampleReport({
          'helperResourcesReleasedOk': false,
        }).resourceLifecyclePass,
        isFalse,
      );
      expect(
        _createSampleReport({'diagnosticTeardownOk': false}).cleanupPass,
        isFalse,
      );
    });

    test('parity gate failure fails parity lane', () {
      expect(
        _createSampleReport({'structParityOk': false}).parityPass,
        isFalse,
      );
    });

    test('canonical gate failure fails canonical check', () {
      expect(_createSampleReport({'canonical': false}).canonicalPass, isFalse);
    });
  });

  group('status UNSUPPORTED and error handling', () {
    test(
      'UNSUPPORTED status is treated as non-pass but preserves status and raw',
      () {
        final rawStr =
            '{"pass":false,"status":"UNSUPPORTED","failureReason":"vulkan_instance_unavailable"}';
        final report = VGTimelineOverlayVulkanRenderSmokeReport.fromMap({
          'pass': false,
          'status': 'UNSUPPORTED',
          'marker': _failMarker,
          'proofBoundary': _proofBoundary,
          'failureReason': 'vulkan_instance_unavailable',
          for (final key in _gateKeys) key: false,
          'allNativeLanesPass': false,
          'nativeAllLanesPass': false,
          'details': <String, Object?>{
            'reason': 'vulkan_instance_unavailable',
            'vulkanUnsupported': true,
          },
          'raw': rawStr,
        });

        expect(report.pass, isFalse);
        expect(
          report.decision,
          VGTimelineOverlayVulkanRenderSmokeDecision.unsupported,
        );
        expect(report.status, 'UNSUPPORTED');
        expect(report.isUnsupported, isTrue);
        expect(report.isPass, isFalse);
        expect(report.isVerifiedPass, isFalse);
        expect(report.isFail, isFalse);
        expect(report.failureReason, 'vulkan_instance_unavailable');
        expect(report.raw, rawStr);
        expect(report.details['vulkanUnsupported'], isTrue);
      },
    );

    test('unsupported factory creates correctly structured report', () {
      final report = VGTimelineOverlayVulkanRenderSmokeReport.unsupported(
        'no_vulkan_driver',
      );
      expect(report.pass, isFalse);
      expect(
        report.decision,
        VGTimelineOverlayVulkanRenderSmokeDecision.unsupported,
      );
      expect(report.status, 'UNSUPPORTED');
      expect(report.marker, _failMarker);
      expect(report.proofBoundary, _proofBoundary);
      expect(report.failureReason, 'no_vulkan_driver');
      expect(report.isUnsupported, isTrue);
      expect(report.isPass, isFalse);
      for (final key in _gateKeys) {
        expect(report.gates[key], isFalse);
      }
    });

    test('harnessFailure factory creates correctly structured report', () {
      final report = VGTimelineOverlayVulkanRenderSmokeReport.harnessFailure(
        'timeout',
        extraDetails: {'duration': '30s'},
      );
      expect(report.pass, isFalse);
      expect(
        report.decision,
        VGTimelineOverlayVulkanRenderSmokeDecision.harnessException,
      );
      expect(report.status, 'FAIL');
      expect(report.marker, _failMarker);
      expect(report.failureReason, 'timeout');
      expect(report.isHarnessException, isTrue);
      expect(report.isPass, isFalse);
      expect(report.details['duration'], '30s');
    });

    test(
      'contradictory payload (pass: false, status: PASS) treated as fail',
      () {
        final report = _createSampleReport({'pass': false, 'status': 'PASS'});
        expect(report.pass, isFalse);
        expect(
          report.decision,
          VGTimelineOverlayVulkanRenderSmokeDecision.fail,
        );
        expect(report.isPass, isFalse);
        expect(report.isFail, isTrue);
      },
    );

    test('wrong proof boundary prevents verified pass', () {
      final report = _createSampleReport({
        'proofBoundary': 'wrong_proof_boundary',
      });
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('wrong marker prevents verified pass', () {
      final report = _createSampleReport({'marker': 'SOME_OTHER_MARKER'});
      expect(report.hasPassMarker, isFalse);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });
  });

  group('MethodChannel invocation tests with mocks', () {
    test('successful invocation parses pass report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        expect(call.method, equals(_method));
        return _createSampleRawMap();
      });

      final report =
          await VGTimelineOverlayVulkanRenderSmokeReport.runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke();

      expect(report.pass, isTrue);
      expect(report.decision, VGTimelineOverlayVulkanRenderSmokeDecision.pass);
      expect(report.isPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
    });

    test('unsupported platform returns unsupported report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        return <String, Object?>{
          'pass': false,
          'status': 'UNSUPPORTED',
          'marker': _failMarker,
          'proofBoundary': _proofBoundary,
          'failureReason': 'vulkan_no_physical_devices',
          for (final k in _gateKeys) k: false,
          'allNativeLanesPass': false,
          'nativeAllLanesPass': false,
          'details': <String, Object?>{'vulkanUnsupported': true},
          'raw': '{"pass":false,"status":"UNSUPPORTED"}',
        };
      });

      final report =
          await VGTimelineOverlayVulkanRenderSmokeReport.runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke();

      expect(report.pass, isFalse);
      expect(
        report.decision,
        VGTimelineOverlayVulkanRenderSmokeDecision.unsupported,
      );
      expect(report.status, 'UNSUPPORTED');
      expect(report.isUnsupported, isTrue);
      expect(report.isPass, isFalse);
    });

    test(
      'PlatformException UNSUPPORTED/UNAVAILABLE yields unsupported report',
      () async {
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          throw PlatformException(code: 'UNSUPPORTED', message: 'No Vulkan');
        });

        final report1 =
            await VGTimelineOverlayVulkanRenderSmokeReport.runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke();
        expect(
          report1.decision,
          VGTimelineOverlayVulkanRenderSmokeDecision.unsupported,
        );
        expect(report1.isUnsupported, isTrue);

        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          throw PlatformException(
            code: 'UNAVAILABLE',
            message: 'Not available',
          );
        });

        final report2 =
            await VGTimelineOverlayVulkanRenderSmokeReport.runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke();
        expect(
          report2.decision,
          VGTimelineOverlayVulkanRenderSmokeDecision.unsupported,
        );
        expect(report2.isUnsupported, isTrue);

        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          throw PlatformException(
            code: 'UNIMPLEMENTED',
            message: 'Not implemented',
          );
        });

        final report3 =
            await VGTimelineOverlayVulkanRenderSmokeReport.runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke();
        expect(
          report3.decision,
          VGTimelineOverlayVulkanRenderSmokeDecision.unsupported,
        );
        expect(report3.isUnsupported, isTrue);
      },
    );

    test('MissingPluginException yields unsupported report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw MissingPluginException('Not implemented');
      });

      final report =
          await VGTimelineOverlayVulkanRenderSmokeReport.runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke();

      expect(
        report.decision,
        VGTimelineOverlayVulkanRenderSmokeDecision.unsupported,
      );
      expect(report.isUnsupported, isTrue);
    });

    test('arbitrary PlatformException yields harnessFailure report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        throw PlatformException(code: 'FAILED', message: 'Native error');
      });

      final report =
          await VGTimelineOverlayVulkanRenderSmokeReport.runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke();

      expect(
        report.decision,
        VGTimelineOverlayVulkanRenderSmokeDecision.harnessException,
      );
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, contains('platform_exception:FAILED'));
    });

    test('timeout yields harnessFailure report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return _createSampleRawMap();
      });

      final report =
          await VGTimelineOverlayVulkanRenderSmokeReport.runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke(
            timeout: const Duration(milliseconds: 10),
          );

      expect(
        report.decision,
        VGTimelineOverlayVulkanRenderSmokeDecision.harnessException,
      );
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, 'timeout');
    });

    test('custom MethodChannel injection works', () async {
      const customChannel = MethodChannel('custom_channel');
      binaryMessenger.setMockMethodCallHandler(customChannel, (call) async {
        expect(call.method, equals(_method));
        return _createSampleRawMap();
      });

      final report =
          await VGTimelineOverlayVulkanRenderSmokeReport.runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke(
            channel: customChannel,
          );

      expect(report.pass, isTrue);
      expect(report.isPass, isTrue);
    });
  });
}
