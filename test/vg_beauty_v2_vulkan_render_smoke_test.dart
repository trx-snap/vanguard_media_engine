// vg_beauty_v2_vulkan_render_smoke_test.dart
// vanguard_media_engine — P5-BEAUTY-V2-VULKAN-RENDER:
// Android True-DAG VulkanBeautyV2Compositor shader/raster + CPU parity diagnostic
// smoke Dart model & MethodChannel tests.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_beauty_v2_vulkan_render_smoke.dart';

const String _proofBoundary =
    'native_vulkan_beauty_v2_compositor_shader_raster_only_no_decode_no_export_no_product';
const String _passMarker =
    'ANDROID_DAG_PHASE5_BEAUTY_V2_VULKAN_RENDER_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_BEAUTY_V2_VULKAN_RENDER_PHYSICAL_SMOKE_FAIL';
const String _method = 'runAndroidDagPhase5BeautyV2VulkanRenderSmoke';

const List<String> _primaryGateKeys = <String>[
  'vulkanSetupOk',
  'invalidImageRejectedOk',
  'invalidDimensionsRejectedOk',
  'invalidIntensityRejectedOk',
  'invalidParameterRejectedOk',
  'nonePresetFlatIdentityOk',
  'nonePresetGradientMinimumRampOk',
  'softPresetCpuParityOk',
  'strongPresetCpuParityOk',
  'maxPresetCpuParityOk',
  'maxPresetBoundsOk',
  'maxPresetMidtoneLiftOk',
  'helperResourcesReleasedOk',
  'diagnosticTeardownOk',
  'structParityOk',
  'canonical',
];

const List<String> _telemetryKeys = <String>[
  'softPresetSmoothingObservedOk',
  'strongPresetEdgePreservationOk',
];

const List<String> _allGateKeys = <String>[
  'vulkanSetupOk',
  'invalidImageRejectedOk',
  'invalidDimensionsRejectedOk',
  'invalidIntensityRejectedOk',
  'invalidParameterRejectedOk',
  'nonePresetFlatIdentityOk',
  'nonePresetGradientMinimumRampOk',
  'softPresetCpuParityOk',
  'softPresetSmoothingObservedOk',
  'strongPresetCpuParityOk',
  'strongPresetEdgePreservationOk',
  'maxPresetCpuParityOk',
  'maxPresetBoundsOk',
  'maxPresetMidtoneLiftOk',
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
  for (final key in _allGateKeys) key: true,
  'allNativeLanesPass': true,
  'nativeAllLanesPass': true,
  'details': const <String, Object?>{
    'deviceName': 'Adreno (TM) 740',
    'deviceType': 2,
    'apiVersion': '1.3.128',
    'driverVersion': 512,
    'queueFamilyIndex': 0,
    'canvasWidth': 64,
    'canvasHeight': 64,
    'softMae': '0.12',
    'strongMae': '0.18',
    'maxMae': '0.22',
    'paramsStructFields':
        'radius,sigma,rangeSigma,smoothStrength,sharpenStrength,theta,detailDamping,toneStrength,midtoneLift',
  },
  'raw': '{"pass":true,"status":"PASS"}',
  if (overrides != null) ...overrides,
};

VGBeautyV2VulkanRenderSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGBeautyV2VulkanRenderSmokeReport.fromMap(_createSampleRawMap(overrides));

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
        VGBeautyV2VulkanRenderSmokeReport.proofBoundaryConstant,
        equals(_proofBoundary),
      );
      expect(VGBeautyV2VulkanRenderSmokeReport.passMarker, equals(_passMarker));
      expect(VGBeautyV2VulkanRenderSmokeReport.failMarker, equals(_failMarker));
      expect(VGBeautyV2VulkanRenderSmokeReport.methodName, equals(_method));
      expect(
        VGBeautyV2VulkanRenderSmokeReport.allGateKeys,
        orderedEquals(_allGateKeys),
      );
      expect(
        VGBeautyV2VulkanRenderSmokeReport.primaryGateKeys,
        orderedEquals(_primaryGateKeys),
      );
      expect(
        VGBeautyV2VulkanRenderSmokeReport.telemetryKeys,
        orderedEquals(_telemetryKeys),
      );
      expect(VGBeautyV2VulkanRenderSmokeReport.setupGateKeys.length, 1);
      expect(VGBeautyV2VulkanRenderSmokeReport.validationGateKeys.length, 4);
      expect(
        VGBeautyV2VulkanRenderSmokeReport.paramValidationGateKeys.length,
        4,
      );
      expect(VGBeautyV2VulkanRenderSmokeReport.nonePresetGateKeys.length, 2);
      expect(VGBeautyV2VulkanRenderSmokeReport.softPresetGateKeys.length, 1);
      expect(VGBeautyV2VulkanRenderSmokeReport.strongPresetGateKeys.length, 1);
      expect(VGBeautyV2VulkanRenderSmokeReport.maxPresetGateKeys.length, 3);
      expect(VGBeautyV2VulkanRenderSmokeReport.lifecycleGateKeys.length, 2);
      expect(
        VGBeautyV2VulkanRenderSmokeReport.lifecycleStateGateKeys.length,
        2,
      );
      expect(
        VGBeautyV2VulkanRenderSmokeReport.resourceLifecycleGateKeys.length,
        2,
      );
      expect(
        VGBeautyV2VulkanRenderSmokeReport.lifecycleTeardownGateKeys.length,
        2,
      );
      expect(VGBeautyV2VulkanRenderSmokeReport.stateGateKeys.length, 2);
      expect(VGBeautyV2VulkanRenderSmokeReport.structParityGateKeys.length, 1);
      expect(VGBeautyV2VulkanRenderSmokeReport.parityGateKeys.length, 1);
      expect(VGBeautyV2VulkanRenderSmokeReport.canonicalGateKeys.length, 1);
      expect(_allGateKeys.toSet().length, 18, reason: 'unique');
      expect(_allGateKeys.length, 18);
      expect(_primaryGateKeys.length, 16);
      expect(_telemetryKeys.length, 2);
    });
  });

  group('VGBeautyV2VulkanRenderSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 4 values in order', () {
      expect(
        VGBeautyV2VulkanRenderSmokeDecision.values,
        orderedEquals(const [
          VGBeautyV2VulkanRenderSmokeDecision.pass,
          VGBeautyV2VulkanRenderSmokeDecision.fail,
          VGBeautyV2VulkanRenderSmokeDecision.unsupported,
          VGBeautyV2VulkanRenderSmokeDecision.harnessException,
        ]),
      );
    });

    test('fromRaw maps all known decision strings', () {
      expect(
        VGBeautyV2VulkanRenderSmokeDecision.fromRaw('pass'),
        VGBeautyV2VulkanRenderSmokeDecision.pass,
      );
      expect(
        VGBeautyV2VulkanRenderSmokeDecision.fromRaw('PASS'),
        VGBeautyV2VulkanRenderSmokeDecision.pass,
      );
      expect(
        VGBeautyV2VulkanRenderSmokeDecision.fromRaw('fail'),
        VGBeautyV2VulkanRenderSmokeDecision.fail,
      );
      expect(
        VGBeautyV2VulkanRenderSmokeDecision.fromRaw('UNSUPPORTED'),
        VGBeautyV2VulkanRenderSmokeDecision.unsupported,
      );
      expect(
        VGBeautyV2VulkanRenderSmokeDecision.fromRaw('harnessException'),
        VGBeautyV2VulkanRenderSmokeDecision.harnessException,
      );
      expect(
        VGBeautyV2VulkanRenderSmokeDecision.fromRaw('harness_exception'),
        VGBeautyV2VulkanRenderSmokeDecision.harnessException,
      );
    });

    test('fromRaw falls back to harnessException for unknown values', () {
      for (final invalid in <Object?>['bogus', '', null, 1, 2.0, true, []]) {
        expect(
          VGBeautyV2VulkanRenderSmokeDecision.fromRaw(invalid),
          VGBeautyV2VulkanRenderSmokeDecision.harnessException,
        );
      }
    });
  });

  group('VGBeautyV2VulkanRenderSmokeReport fromMap / toMap & all 27 keys', () {
    test('pass report parses every gate, mirrors 27 keys, and round-trips', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(report.decision, VGBeautyV2VulkanRenderSmokeDecision.pass);
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
      expect(report.invalidIntensityRejectedPass, isTrue);
      expect(report.invalidParameterRejectedPass, isTrue);
      expect(report.validationPass, isTrue);
      expect(report.paramValidationPass, isTrue);

      // Lane 2: none preset
      expect(report.nonePresetFlatIdentityPass, isTrue);
      expect(report.nonePresetGradientMinimumRampPass, isTrue);
      expect(report.nonePresetPass, isTrue);

      // Lane 3: soft preset
      expect(report.softPresetCpuParityPass, isTrue);
      expect(report.softPresetSmoothingObserved, isTrue);
      expect(report.softPresetSmoothingObservedPass, isTrue);
      expect(report.softPresetPass, isTrue);

      // Lane 4: strong preset
      expect(report.strongPresetCpuParityPass, isTrue);
      expect(report.strongPresetEdgePreservationObserved, isTrue);
      expect(report.strongPresetEdgePreservationPass, isTrue);
      expect(report.strongPresetPass, isTrue);

      // Lane 5: max preset
      expect(report.maxPresetCpuParityPass, isTrue);
      expect(report.maxPresetBoundsPass, isTrue);
      expect(report.maxPresetMidtoneLiftPass, isTrue);
      expect(report.maxPresetPass, isTrue);

      // Lane 6: lifecycle & teardown
      expect(report.helperResourcesReleasedPass, isTrue);
      expect(report.diagnosticTeardownPass, isTrue);
      expect(report.lifecyclePass, isTrue);
      expect(report.lifecycleTeardownPass, isTrue);
      expect(report.statePass, isTrue);
      expect(report.resourceLifecyclePass, isTrue);
      expect(report.teardownPass, isTrue);

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

      expect(report.details['deviceName'], 'Adreno (TM) 740');
      expect(report.details['apiVersion'], '1.3.128');

      final serialized = report.toMap();
      expect(serialized['pass'], isTrue);
      expect(serialized['decision'], 'pass');
      expect(serialized['status'], 'PASS');
      expect(serialized['marker'], _passMarker);
      expect(serialized['proofBoundary'], _proofBoundary);
      expect(serialized['failureReason'], isEmpty);

      // Check all 18 gates in serialized map
      for (final key in _allGateKeys) {
        expect(serialized[key], isTrue, reason: key);
      }
      expect(serialized['allNativeLanesPass'], isTrue);
      expect(serialized['nativeAllLanesPass'], isTrue);
      expect(serialized['details'], isA<Map<String, Object?>>());

      // Total 27 native wire keys verified
      const expectedWireKeys = <String>[
        'pass',
        'status',
        'marker',
        'proofBoundary',
        'failureReason',
        'vulkanSetupOk',
        'invalidImageRejectedOk',
        'invalidDimensionsRejectedOk',
        'invalidIntensityRejectedOk',
        'invalidParameterRejectedOk',
        'nonePresetFlatIdentityOk',
        'nonePresetGradientMinimumRampOk',
        'softPresetCpuParityOk',
        'softPresetSmoothingObservedOk',
        'strongPresetCpuParityOk',
        'strongPresetEdgePreservationOk',
        'maxPresetCpuParityOk',
        'maxPresetBoundsOk',
        'maxPresetMidtoneLiftOk',
        'helperResourcesReleasedOk',
        'diagnosticTeardownOk',
        'structParityOk',
        'canonical',
        'allNativeLanesPass',
        'nativeAllLanesPass',
        'details',
        'raw',
      ];
      expect(expectedWireKeys.length, 27);
      for (final wireKey in expectedWireKeys) {
        expect(serialized.containsKey(wireKey), isTrue, reason: wireKey);
      }

      final roundTrip = VGBeautyV2VulkanRenderSmokeReport.fromMap(serialized);
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
    });

    test('fail report with failed primary gate is not a pass', () {
      final report = _createSampleReport({
        'pass': false,
        'status': 'FAIL',
        'marker': _failMarker,
        'failureReason': 'softPresetCpuParity_delta_exceeded',
        'softPresetCpuParityOk': false,
        'allNativeLanesPass': false,
        'nativeAllLanesPass': false,
      });

      expect(report.pass, isFalse);
      expect(report.decision, VGBeautyV2VulkanRenderSmokeDecision.fail);
      expect(report.isFail, isTrue);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.softPresetCpuParityPass, isFalse);
      expect(report.softPresetPass, isFalse);
      expect(report.nonePresetPass, isTrue);
      expect(report.validationPass, isTrue);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.hasFailMarker, isTrue);
      expect(report.hasPassMarker, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.failureReason, 'softPresetCpuParity_delta_exceeded');
    });

    test(
      'every single primary gate failure flips allNativeLanesPass and isPass',
      () {
        for (final key in _primaryGateKeys) {
          final report = _createSampleReport({key: false});
          expect(report.gates[key], isFalse, reason: key);
          expect(report.allNativeLanesPass, isFalse, reason: key);
          expect(report.isPass, isFalse, reason: key);
          expect(report.isVerifiedPass, isFalse, reason: key);
        }
      },
    );

    test('telemetry false does NOT fail allNativeLanesPass or isPass', () {
      // Soft preset smoothing observed false
      final softTelemetryFail = _createSampleReport({
        'softPresetSmoothingObservedOk': false,
      });
      expect(softTelemetryFail.softPresetSmoothingObserved, isFalse);
      expect(softTelemetryFail.softPresetSmoothingObservedPass, isFalse);
      expect(softTelemetryFail.softPresetCpuParityPass, isTrue);
      expect(softTelemetryFail.allNativeLanesPass, isTrue);
      expect(softTelemetryFail.isPass, isTrue);
      expect(softTelemetryFail.isVerifiedPass, isTrue);

      // Strong preset edge preservation false
      final strongTelemetryFail = _createSampleReport({
        'strongPresetEdgePreservationOk': false,
      });
      expect(strongTelemetryFail.strongPresetEdgePreservationObserved, isFalse);
      expect(strongTelemetryFail.strongPresetEdgePreservationPass, isFalse);
      expect(strongTelemetryFail.strongPresetCpuParityPass, isTrue);
      expect(strongTelemetryFail.allNativeLanesPass, isTrue);
      expect(strongTelemetryFail.isPass, isTrue);
      expect(strongTelemetryFail.isVerifiedPass, isTrue);

      // Both telemetry booleans false
      final bothTelemetryFail = _createSampleReport({
        'softPresetSmoothingObservedOk': false,
        'strongPresetEdgePreservationOk': false,
      });
      expect(bothTelemetryFail.softPresetSmoothingObserved, isFalse);
      expect(bothTelemetryFail.strongPresetEdgePreservationObserved, isFalse);
      expect(bothTelemetryFail.allNativeLanesPass, isTrue);
      expect(bothTelemetryFail.isPass, isTrue);
      expect(bothTelemetryFail.isVerifiedPass, isTrue);
    });

    test('lane group getters reflect only their own keys', () {
      final setupFail = _createSampleReport({'vulkanSetupOk': false});
      expect(setupFail.setupPass, isFalse);
      expect(setupFail.vulkanSetupPass, isFalse);
      expect(setupFail.validationPass, isTrue);

      final valFail = _createSampleReport({
        'invalidDimensionsRejectedOk': false,
      });
      expect(valFail.validationPass, isFalse);
      expect(valFail.setupPass, isTrue);
      expect(valFail.nonePresetPass, isTrue);

      final noneFail = _createSampleReport({'nonePresetFlatIdentityOk': false});
      expect(noneFail.nonePresetPass, isFalse);
      expect(noneFail.nonePresetFlatIdentityPass, isFalse);
      expect(noneFail.validationPass, isTrue);
      expect(noneFail.softPresetPass, isTrue);

      final softFail = _createSampleReport({'softPresetCpuParityOk': false});
      expect(softFail.softPresetPass, isFalse);
      expect(softFail.softPresetCpuParityPass, isFalse);
      expect(softFail.nonePresetPass, isTrue);
      expect(softFail.strongPresetPass, isTrue);

      final strongFail = _createSampleReport({
        'strongPresetCpuParityOk': false,
      });
      expect(strongFail.strongPresetPass, isFalse);
      expect(strongFail.strongPresetCpuParityPass, isFalse);
      expect(strongFail.softPresetPass, isTrue);
      expect(strongFail.maxPresetPass, isTrue);

      final maxFail = _createSampleReport({'maxPresetBoundsOk': false});
      expect(maxFail.maxPresetPass, isFalse);
      expect(maxFail.maxPresetBoundsPass, isFalse);
      expect(maxFail.strongPresetPass, isTrue);
      expect(maxFail.lifecyclePass, isTrue);

      final lifecycleFail = _createSampleReport({
        'diagnosticTeardownOk': false,
      });
      expect(lifecycleFail.lifecyclePass, isFalse);
      expect(lifecycleFail.diagnosticTeardownPass, isFalse);
      expect(lifecycleFail.teardownPass, isFalse);
      expect(lifecycleFail.statePass, isFalse);
      expect(lifecycleFail.resourceLifecyclePass, isFalse);
      expect(lifecycleFail.helperResourcesReleasedPass, isTrue);
      expect(lifecycleFail.maxPresetPass, isTrue);
      expect(lifecycleFail.parityPass, isTrue);

      final parityFail = _createSampleReport({'structParityOk': false});
      expect(parityFail.parityPass, isFalse);
      expect(parityFail.structParityPass, isFalse);
      expect(parityFail.lifecyclePass, isTrue);
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
      // nativeAllLanesPass is false while Dart gates pass
      final report = _createSampleReport({'allNativeLanesPass': false});
      expect(report.allNativeLanesPass, isTrue);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);

      // nativeAllLanesPass is true while Dart gates fail
      final report2 = _createSampleReport({
        'vulkanSetupOk': false,
        'allNativeLanesPass': true,
        'nativeAllLanesPass': true,
      });
      expect(report2.allNativeLanesPass, isFalse);
      expect(report2.nativeAllLanesPass, isTrue);
      expect(report2.isPass, isFalse);
      expect(report2.isVerifiedPass, isFalse);
    });

    test(
      'nativeAllLanesPass spelling accepted when allNativeLanesPass is absent',
      () {
        final raw = _createSampleRawMap()..remove('allNativeLanesPass');
        final report = VGBeautyV2VulkanRenderSmokeReport.fromMap(raw);
        expect(report.nativeAllLanesPass, isTrue);
        expect(report.isPass, isTrue);

        final rawFalse = _createSampleRawMap({'nativeAllLanesPass': false})
          ..remove('allNativeLanesPass');
        final reportFalse = VGBeautyV2VulkanRenderSmokeReport.fromMap(rawFalse);
        expect(reportFalse.nativeAllLanesPass, isFalse);
        expect(reportFalse.isPass, isFalse);
      },
    );

    test('string "true"/"false" gate values are accepted', () {
      final report = _createSampleReport({
        'vulkanSetupOk': 'true',
        'softPresetCpuParityOk': 'false',
        'allNativeLanesPass': 'true',
      });
      expect(report.vulkanSetupPass, isTrue);
      expect(report.softPresetCpuParityPass, isFalse);
      expect(report.nativeAllLanesPass, isTrue);
      expect(report.isPass, isFalse);
    });

    test('raw String JSON parses successfully to valid pass report', () {
      final rawMap = _createSampleRawMap();
      final jsonStr = jsonEncode(rawMap);
      final report = VGBeautyV2VulkanRenderSmokeReport.fromMap(jsonStr);

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
        final report = VGBeautyV2VulkanRenderSmokeReport.fromMap(invalid);
        expect(report.pass, isFalse);
        expect(
          report.decision,
          VGBeautyV2VulkanRenderSmokeDecision.harnessException,
        );
        expect(report.isHarnessException, isTrue);
        expect(report.failureReason, 'native_result_not_a_map');
        expect(report.marker, _failMarker);
        expect(report.proofBoundary, _proofBoundary);
        expect(report.allNativeLanesPass, isFalse);
        expect(report.isPass, isFalse);
        expect(report.isVerifiedPass, isFalse);
        for (final key in _allGateKeys) {
          expect(report.gates[key], isFalse, reason: key);
        }
      }
    });

    test('fromMap handles missing/null fields defensively', () {
      final report = VGBeautyV2VulkanRenderSmokeReport.fromMap({
        for (final key in _createSampleRawMap().keys) key: null,
      });
      expect(report.pass, isFalse);
      expect(report.decision, VGBeautyV2VulkanRenderSmokeDecision.fail);
      expect(report.status, 'FAIL');
      expect(report.marker, isEmpty);
      expect(report.proofBoundary, isEmpty);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.details, isEmpty);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);

      final unsupported = VGBeautyV2VulkanRenderSmokeReport.fromMap({
        'pass': false,
        'status': 'UNSUPPORTED',
      });
      expect(
        unsupported.decision,
        VGBeautyV2VulkanRenderSmokeDecision.unsupported,
      );
      expect(unsupported.isUnsupported, isTrue);
      expect(unsupported.isPass, isFalse);
    });

    test('contradictory pass=false with PASS status is a plain fail', () {
      final report = VGBeautyV2VulkanRenderSmokeReport.fromMap({
        'pass': false,
        'status': 'PASS',
        'marker': _passMarker,
        'proofBoundary': _proofBoundary,
        for (final key in _allGateKeys) key: true,
        'allNativeLanesPass': true,
      });
      expect(report.decision, VGBeautyV2VulkanRenderSmokeDecision.fail);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('explicit decision field wins over status for failed reports', () {
      final report = VGBeautyV2VulkanRenderSmokeReport.fromMap({
        'pass': false,
        'status': 'FAIL',
        'decision': 'harnessException',
      });
      expect(
        report.decision,
        VGBeautyV2VulkanRenderSmokeDecision.harnessException,
      );
    });

    test('unsupported and harnessFailure factories are fail-shaped', () {
      final unsupported = VGBeautyV2VulkanRenderSmokeReport.unsupported(
        'vulkan_driver_missing',
      );
      expect(unsupported.pass, isFalse);
      expect(unsupported.isUnsupported, isTrue);
      expect(unsupported.status, 'UNSUPPORTED');
      expect(unsupported.marker, _failMarker);
      expect(unsupported.proofBoundary, _proofBoundary);
      expect(unsupported.failureReason, 'vulkan_driver_missing');
      expect(unsupported.allNativeLanesPass, isFalse);
      expect(unsupported.isPass, isFalse);
      expect(unsupported.isVerifiedPass, isFalse);
      expect(unsupported.gates.length, _allGateKeys.length);

      final harness = VGBeautyV2VulkanRenderSmokeReport.harnessFailure(
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

  group('VGBeautyV2VulkanRenderSmokeReport value semantics', () {
    test('equal values are equal with equal hash codes', () {
      final a = _createSampleReport();
      final b = _createSampleReport();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGBeautyV2VulkanRenderSmokeReport('));
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
        {'softPresetCpuParityOk': false},
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
      const channel = MethodChannel('test_beauty_v2_vulkan_render_channel');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        capturedCall = call;
        return _createSampleRawMap();
      });

      final report =
          await VGBeautyV2VulkanRenderSmokeReport.runAndroidDagPhase5BeautyV2VulkanRenderSmoke(
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
          await VGBeautyV2VulkanRenderSmokeReport.runAndroidDagPhase5BeautyV2VulkanRenderSmoke();

      expect(capturedCall, isNotNull);
      expect(capturedCall!.method, _method);
      expect(report.pass, isTrue);
      expect(report.isPass, isTrue);
    });

    test('missing plugin yields an unsupported report', () async {
      const channel = MethodChannel('test_beauty_v2_vulkan_render_missing');
      final report =
          await VGBeautyV2VulkanRenderSmokeReport.runAndroidDagPhase5BeautyV2VulkanRenderSmoke(
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, startsWith('missing_plugin'));
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('UNAVAILABLE platform exception yields an unsupported report', () async {
      const channel = MethodChannel('test_beauty_v2_vulkan_render_unavail');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'UNAVAILABLE', message: 'no coordinator');
      });
      final report =
          await VGBeautyV2VulkanRenderSmokeReport.runAndroidDagPhase5BeautyV2VulkanRenderSmoke(
            channel: channel,
          );
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, 'platform_exception:UNAVAILABLE');
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('other platform exception yields a harnessException report', () async {
      const channel = MethodChannel('test_beauty_v2_vulkan_render_pe');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'NATIVE_CRASH', message: 'Simulated');
      });
      final report =
          await VGBeautyV2VulkanRenderSmokeReport.runAndroidDagPhase5BeautyV2VulkanRenderSmoke(
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
      const channel = MethodChannel('test_beauty_v2_vulkan_render_timeout');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSampleRawMap();
      });
      final report =
          await VGBeautyV2VulkanRenderSmokeReport.runAndroidDagPhase5BeautyV2VulkanRenderSmoke(
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
      const channel = MethodChannel('test_beauty_v2_vulkan_render_generic');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw StateError('Generic unexpected error');
      });
      final report =
          await VGBeautyV2VulkanRenderSmokeReport.runAndroidDagPhase5BeautyV2VulkanRenderSmoke(
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
        const channel = MethodChannel('test_beauty_v2_vulkan_render_nonmap');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          return 'status=PASS';
        });
        final report =
            await VGBeautyV2VulkanRenderSmokeReport.runAndroidDagPhase5BeautyV2VulkanRenderSmoke(
              channel: channel,
            );
        expect(report.isHarnessException, isTrue);
        expect(report.failureReason, 'native_result_not_a_map');
        expect(report.details['received'], 'status=PASS');
      },
    );

    test('raw String JSON return over channel parses successfully', () async {
      const channel = MethodChannel('test_beauty_v2_vulkan_render_raw_json');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return jsonEncode(_createSampleRawMap());
      });
      final report =
          await VGBeautyV2VulkanRenderSmokeReport.runAndroidDagPhase5BeautyV2VulkanRenderSmoke(
            channel: channel,
          );
      expect(report.pass, isTrue);
      expect(report.isPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.hasPassMarker, isTrue);
    });

    test('native fail payload surfaces the failing lane and reason', () async {
      const channel = MethodChannel('test_beauty_v2_vulkan_render_fail');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return _createSampleRawMap({
          'pass': false,
          'status': 'FAIL',
          'marker': _failMarker,
          'failureReason': 'nonePresetFlatIdentity_pixel_mismatch',
          'nonePresetFlatIdentityOk': false,
          'allNativeLanesPass': false,
          'nativeAllLanesPass': false,
        });
      });
      final report =
          await VGBeautyV2VulkanRenderSmokeReport.runAndroidDagPhase5BeautyV2VulkanRenderSmoke(
            channel: channel,
          );
      expect(report.isFail, isTrue);
      expect(report.nonePresetFlatIdentityPass, isFalse);
      expect(report.nonePresetPass, isFalse);
      expect(report.validationPass, isTrue);
      expect(report.failureReason, 'nonePresetFlatIdentity_pixel_mismatch');
      expect(report.hasFailMarker, isTrue);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test('native UNSUPPORTED payload surfaces unsupported decision', () async {
      const channel = MethodChannel('test_beauty_v2_vulkan_render_unsupported');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return _createSampleRawMap({
          'pass': false,
          'status': 'UNSUPPORTED',
          'marker': _failMarker,
          'failureReason': 'vulkan_unsupported:vkCreateInstance_failed',
          'vulkanSetupOk': false,
          'allNativeLanesPass': false,
          'nativeAllLanesPass': false,
          'details': const <String, Object?>{
            'vulkanUnsupported': true,
            'vulkanSetupError': 'vkCreateInstance_failed',
          },
        });
      });
      final report =
          await VGBeautyV2VulkanRenderSmokeReport.runAndroidDagPhase5BeautyV2VulkanRenderSmoke(
            channel: channel,
          );
      expect(report.isUnsupported, isTrue);
      expect(report.isPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.vulkanSetupPass, isFalse);
      expect(report.status, 'UNSUPPORTED');
      expect(
        report.failureReason,
        'vulkan_unsupported:vkCreateInstance_failed',
      );
      expect(report.details['vulkanUnsupported'], isTrue);
    });
  });
}
