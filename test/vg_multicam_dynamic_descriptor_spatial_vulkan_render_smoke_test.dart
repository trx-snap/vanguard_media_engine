// vg_multicam_dynamic_descriptor_spatial_vulkan_render_smoke_test.dart
// vanguard_media_engine - P3-MULTICAM-NODE-VULKAN-DYNAMIC-DESCRIPTOR-SPATIAL-RENDER:
// Android True-DAG Dart layout descriptor -> native Vulkan spatial render
// diagnostic smoke Dart model & MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_dual_camera_descriptor.dart';
import 'package:vanguard_media_engine/vg_multicam_dynamic_descriptor_spatial_render_smoke.dart';
import 'package:vanguard_media_engine/vg_multicam_dynamic_descriptor_spatial_vulkan_render_smoke.dart';

const String _proofBoundary =
    'native_multicam_dynamic_descriptor_spatial_vulkan_render_readback_only_no_gles_no_camera_no_oes_no_ahb_no_opacity_no_corner_radius_no_recording_no_product';
const String _passMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_VULKAN_RENDER_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_VULKAN_RENDER_FAIL';
const String _method =
    'runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke';

const List<String> _gateKeys = <String>[
  'descriptorParseOk',
  'descriptorRejectedBeforeVulkanOk',
  'vulkanSetupOk',
  'syntheticImportOk',
  'layoutConvertOk',
  'renderReadbackOk',
  'helperResourcesReleasedOk',
  'diagnosticTeardownOk',
];

Map<String, Object?> _createSamplePassRawMap([
  Map<String, Object?>? overrides,
]) => {
  'pass': true,
  'status': 'PASS',
  'marker': _passMarker,
  'proofBoundary': _proofBoundary,
  'failureReason': '',
  'descriptorParseOk': true,
  'descriptorRejectedBeforeVulkanOk': false,
  'vulkanSetupOk': true,
  'syntheticImportOk': true,
  'layoutConvertOk': true,
  'renderReadbackOk': true,
  'helperResourcesReleasedOk': true,
  'diagnosticTeardownOk': true,
  'allNativeLanesPass': true,
  'nativeAllLanesPass': true,
  'details': const <String, Object?>{
    'deviceName': 'Samsung Xclipse 540',
    'apiVersion': '1.3.279',
    'driverVersion': 12345,
    'layoutModeRaw': 'pip',
    'pipAnchorRaw': 'freeFloating',
    'splitDirectionRaw': 'topBottom',
    'layoutModeResolved': 'pip',
    'pipAnchorResolved': 'freeFloating',
    'splitDirectionResolved': 'topBottom',
    'rejectionReason': '',
    'primaryRectPx': '0,0,64,64',
    'secondaryRectPx': '38,42,13,12',
    'checksum': '1234567',
    'helperTemporaryObjectsCreated': 4,
    'helperTemporaryObjectsReleased': 4,
    'shaderSource': 'aot_passthrough_vert_frag_spv_no_new_shaders',
  },
  'raw': '{"pass":true,"status":"PASS"}',
  if (overrides != null) ...overrides,
};

Map<String, Object?> _createSampleRejectionRawMap([
  Map<String, Object?>? overrides,
]) => {
  'pass': false,
  'status': 'FAIL',
  'marker': _failMarker,
  'proofBoundary': _proofBoundary,
  'failureReason': 'descriptor_rejected:unknown_layout_mode',
  'descriptorParseOk': false,
  'descriptorRejectedBeforeVulkanOk': true,
  'vulkanSetupOk': false,
  'syntheticImportOk': false,
  'layoutConvertOk': false,
  'renderReadbackOk': false,
  'helperResourcesReleasedOk': false,
  'diagnosticTeardownOk': false,
  'allNativeLanesPass': false,
  'nativeAllLanesPass': false,
  'details': const <String, Object?>{
    'layoutModeRaw': 'unknownLayoutMode',
    'pipAnchorRaw': 'freeFloating',
    'splitDirectionRaw': 'topBottom',
    'layoutModeResolved': '',
    'pipAnchorResolved': '',
    'splitDirectionResolved': '',
    'rejectionReason': 'unknown_layout_mode',
    'vulkanSetupState': 'not_run',
    'vulkanObjectsCreatedAtRejection': 0,
  },
  'raw': '{"pass":false,"status":"FAIL"}',
  if (overrides != null) ...overrides,
};

VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
_createSamplePassReport([Map<String, Object?>? overrides]) =>
    VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.fromMap(
      _createSamplePassRawMap(overrides),
    );

VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
_createSampleRejectionReport([Map<String, Object?>? overrides]) =>
    VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.fromMap(
      _createSampleRejectionRawMap(overrides),
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
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
            .proofBoundaryConstant,
        equals(_proofBoundary),
      );
      expect(
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.passMarker,
        equals(_passMarker),
      );
      expect(
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.failMarker,
        equals(_failMarker),
      );
      expect(
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.methodName,
        equals(_method),
      );
      expect(
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.allGateKeys,
        orderedEquals(_gateKeys),
      );
      expect(
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
            .validPassGateKeys,
        orderedEquals(const <String>[
          'descriptorParseOk',
          'vulkanSetupOk',
          'syntheticImportOk',
          'layoutConvertOk',
          'renderReadbackOk',
          'helperResourcesReleasedOk',
          'diagnosticTeardownOk',
        ]),
      );
      expect(
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
            .descriptorRejectionGateKeys,
        orderedEquals(const <String>['descriptorRejectedBeforeVulkanOk']),
      );
      expect(
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
            .descriptorGateKeys
            .length,
        2,
      );
      expect(
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
            .setupGateKeys
            .length,
        2,
      );
      expect(
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
            .renderGateKeys
            .length,
        2,
      );
      expect(
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
            .resourceLifecycleGateKeys
            .length,
        2,
      );
      expect(_gateKeys.toSet().length, _gateKeys.length, reason: 'unique');
    });

    test(
      'proof boundary and markers name Vulkan and dynamic descriptor, not GLES',
      () {
        expect(_proofBoundary, contains('vulkan'));
        expect(_proofBoundary, contains('dynamic_descriptor'));
        expect(_proofBoundary, isNot(contains('no_vulkan')));
        expect(_proofBoundary, contains('no_gles'));
        expect(_proofBoundary, contains('no_ahb'));
        expect(_passMarker, contains('VULKAN'));
        expect(_passMarker, contains('DYNAMIC_DESCRIPTOR'));
        expect(_failMarker, contains('VULKAN'));
      },
    );

    test(
      'reuses VGMultiCamDynamicDescriptorSpatialRenderInput enum values',
      () {
        final freeFloating =
            VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip();
        final leftRight =
            VGMultiCamDynamicDescriptorSpatialRenderInput.leftRightSplit();

        expect(
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
              .expectedFreeFloatingPipLayoutMode,
          equals(freeFloating.layoutMode.value),
        );
        expect(
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
              .expectedFreeFloatingPipAnchor,
          equals(freeFloating.pipAnchor.value),
        );
        expect(
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
              .expectedLeftRightSplitLayoutMode,
          equals(leftRight.layoutMode.value),
        );
        expect(
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
              .expectedLeftRightSplitDirection,
          equals(leftRight.splitDirection.value),
        );
        expect(
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
              .expectedFreeFloatingPipLayoutMode,
          'pip',
        );
        expect(
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
              .expectedLeftRightSplitDirection,
          'leftRight',
        );
      },
    );
  });

  group(
    'VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision enum & fromRaw',
    () {
      test('enum has exact expected 4 values in order', () {
        expect(
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.values,
          orderedEquals(const [
            VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.pass,
            VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fail,
            VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
                .unsupported,
            VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
                .harnessException,
          ]),
        );
      });

      test('fromRaw maps all known decision strings', () {
        expect(
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fromRaw(
            'pass',
          ),
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.pass,
        );
        expect(
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fromRaw(
            'PASS',
          ),
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.pass,
        );
        expect(
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fromRaw(
            'fail',
          ),
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fail,
        );
        expect(
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fromRaw(
            'UNSUPPORTED',
          ),
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
              .unsupported,
        );
        expect(
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fromRaw(
            'harnessException',
          ),
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
              .harnessException,
        );
        expect(
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fromRaw(
            'harness_exception',
          ),
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
              .harnessException,
        );
      });

      test('fromRaw falls back to harnessException for unknown values', () {
        for (final invalid in <Object?>['bogus', '', null, 1, 2.0, true, []]) {
          expect(
            VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fromRaw(
              invalid,
            ),
            VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
                .harnessException,
          );
        }
      });
    },
  );

  group('VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport fromMap / toMap', () {
    test('pass report parses every gate and round-trips', () {
      final report = _createSamplePassReport();

      expect(report.pass, isTrue);
      expect(
        report.decision,
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.pass,
      );
      expect(report.isPass, isTrue);
      expect(report.isFail, isFalse);
      expect(report.isUnsupported, isFalse);
      expect(report.isHarnessException, isFalse);
      expect(report.status, 'PASS');
      expect(report.marker, _passMarker);
      expect(report.proofBoundary, _proofBoundary);
      expect(report.failureReason, isEmpty);

      // Descriptor resolution
      expect(report.descriptorParseOk, isTrue);
      expect(report.descriptorRejectedBeforeVulkanOk, isFalse);

      // Setup
      expect(report.vulkanSetupPass, isTrue);
      expect(report.syntheticImportPass, isTrue);
      expect(report.setupPass, isTrue);

      // Render
      expect(report.layoutConvertPass, isTrue);
      expect(report.renderReadbackPass, isTrue);
      expect(report.renderPass, isTrue);

      // Resource lifecycle
      expect(report.helperResourcesReleasedOk, isTrue);
      expect(report.diagnosticTeardownOk, isTrue);
      expect(report.resourceLifecyclePass, isTrue);

      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.nativeAllLanesPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.isVerifiedDescriptorRejection, isFalse);

      // Resolved descriptor detail getters
      expect(report.layoutModeResolved, 'pip');
      expect(report.pipAnchorResolved, 'freeFloating');
      expect(report.splitDirectionResolved, 'topBottom');
      expect(report.rejectionReason, isEmpty);
      expect(report.details['deviceName'], 'Samsung Xclipse 540');
      expect(report.details['helperTemporaryObjectsCreated'], 4);

      final serialized = report.toMap();
      expect(serialized['pass'], isTrue);
      expect(serialized['decision'], 'pass');
      expect(serialized['marker'], _passMarker);
      expect(serialized['proofBoundary'], _proofBoundary);
      for (final key in _gateKeys) {
        expect(
          serialized[key],
          key == 'descriptorRejectedBeforeVulkanOk' ? isFalse : isTrue,
          reason: key,
        );
      }
      expect(serialized['allNativeLanesPass'], isTrue);
      expect(serialized['nativeAllLanesPass'], isTrue);

      final roundTrip =
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.fromMap(
            serialized,
          );
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
    });

    test('verified descriptor rejection report parses correctly', () {
      final report = _createSampleRejectionReport();

      expect(report.pass, isFalse);
      expect(
        report.decision,
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fail,
      );
      expect(report.isFail, isTrue);
      expect(report.status, 'FAIL');
      expect(report.marker, _failMarker);
      expect(report.hasFailMarker, isTrue);
      expect(report.hasPassMarker, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);

      expect(report.descriptorParseOk, isFalse);
      expect(report.descriptorRejectedBeforeVulkanOk, isTrue);
      expect(report.vulkanSetupPass, isFalse);
      expect(report.syntheticImportPass, isFalse);
      expect(report.layoutConvertPass, isFalse);
      expect(report.renderReadbackPass, isFalse);

      expect(report.rejectionReason, 'unknown_layout_mode');
      expect(report.layoutModeResolved, isEmpty);
      expect(report.details['vulkanSetupState'], 'not_run');
      expect(report.details['vulkanObjectsCreatedAtRejection'], 0);

      expect(report.isVerifiedPass, isFalse);
      expect(report.isVerifiedDescriptorRejection, isTrue);
    });

    test(
      'fail report with descriptor not rejected before Vulkan is neither a verified pass nor a verified rejection',
      () {
        final report = _createSampleRejectionReport({
          'descriptorRejectedBeforeVulkanOk': false,
        });
        expect(report.descriptorParseOk, isFalse);
        expect(report.descriptorRejectedBeforeVulkanOk, isFalse);
        expect(report.isVerifiedPass, isFalse);
        expect(report.isVerifiedDescriptorRejection, isFalse);
      },
    );

    test(
      'every single gate failure flips allNativeLanesPass and isVerifiedPass',
      () {
        for (final key in _gateKeys) {
          if (key == 'descriptorRejectedBeforeVulkanOk') continue;
          final report = _createSamplePassReport({key: false});
          expect(report.gates[key], isFalse, reason: key);
          expect(report.allNativeLanesPass, isFalse, reason: key);
          expect(report.isVerifiedPass, isFalse, reason: key);
        }
        // descriptorRejectedBeforeVulkanOk flipping true on an otherwise-pass
        // report also flips both aggregates: it is not consistent with a
        // successful render having actually happened.
        final flipped = _createSamplePassReport({
          'descriptorRejectedBeforeVulkanOk': true,
        });
        expect(flipped.allNativeLanesPass, isFalse);
        expect(flipped.isVerifiedPass, isFalse);
      },
    );

    test('lane group getters reflect only their own keys', () {
      final setupFail = _createSamplePassReport({'vulkanSetupOk': false});
      expect(setupFail.setupPass, isFalse);
      expect(setupFail.vulkanSetupPass, isFalse);
      expect(setupFail.syntheticImportPass, isTrue);
      expect(setupFail.renderPass, isTrue);
      expect(setupFail.resourceLifecyclePass, isTrue);

      final renderFail = _createSamplePassReport({'renderReadbackOk': false});
      expect(renderFail.renderPass, isFalse);
      expect(renderFail.renderReadbackPass, isFalse);
      expect(renderFail.layoutConvertPass, isTrue);
      expect(renderFail.setupPass, isTrue);
      expect(renderFail.resourceLifecyclePass, isTrue);

      final lifecycleFail = _createSamplePassReport({
        'helperResourcesReleasedOk': false,
      });
      expect(lifecycleFail.resourceLifecyclePass, isFalse);
      expect(lifecycleFail.helperResourcesReleasedOk, isFalse);
      expect(lifecycleFail.diagnosticTeardownOk, isTrue);
      expect(lifecycleFail.renderPass, isTrue);

      final teardownFail = _createSamplePassReport({
        'diagnosticTeardownOk': false,
      });
      expect(teardownFail.resourceLifecyclePass, isFalse);
      expect(teardownFail.diagnosticTeardownOk, isFalse);
      expect(teardownFail.setupPass, isTrue);
    });

    test(
      'non-empty failureReason prevents verified pass even if pass is true',
      () {
        final report = _createSamplePassReport({
          'failureReason': 'diagnostic_teardown_incomplete',
        });
        expect(report.pass, isTrue);
        expect(report.allNativeLanesPass, isTrue);
        expect(report.isVerifiedPass, isFalse);
      },
    );

    test('wrong marker fails verified pass even when all gates pass', () {
      final report = _createSamplePassReport({'marker': 'SOME_OTHER_MARKER'});
      expect(report.pass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.hasPassMarker, isFalse);
      expect(report.isVerifiedPass, isFalse);

      final failMarkerReport = _createSamplePassReport({'marker': _failMarker});
      expect(failMarkerReport.hasFailMarker, isTrue);
      expect(failMarkerReport.isVerifiedPass, isFalse);

      // The static Vulkan sibling's PASS marker must never satisfy this route.
      final siblingMarkerReport = _createSamplePassReport({
        'marker':
            'ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_VULKAN_RENDER_SMOKE_PASS',
      });
      expect(siblingMarkerReport.hasPassMarker, isFalse);
      expect(siblingMarkerReport.isVerifiedPass, isFalse);
    });

    test('wrong proof boundary fails verified pass', () {
      final report = _createSamplePassReport({
        'proofBoundary': 'incorrect_proof_boundary',
      });
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.isVerifiedPass, isFalse);

      final glesBoundaryReport = _createSamplePassReport({
        'proofBoundary':
            'native_multicam_dynamic_descriptor_spatial_gles_oes_render_readback_only_no_vulkan_no_camera_no_opacity_no_corner_radius_no_ycbcr_color_claim_no_recording_no_product',
      });
      expect(glesBoundaryReport.hasCanonicalProofBoundary, isFalse);
      expect(glesBoundaryReport.isVerifiedPass, isFalse);
    });

    test('native aggregate disagreement fails verified pass', () {
      final report = _createSamplePassReport({'allNativeLanesPass': false});
      expect(report.allNativeLanesPass, isTrue);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
    });

    test(
      'nativeAllLanesPass spelling is accepted when allNativeLanesPass is absent',
      () {
        final raw = _createSamplePassRawMap()..remove('allNativeLanesPass');
        final report =
            VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.fromMap(
              raw,
            );
        expect(report.nativeAllLanesPass, isTrue);
        expect(report.isVerifiedPass, isTrue);

        final rawFalse = _createSamplePassRawMap({'nativeAllLanesPass': false})
          ..remove('allNativeLanesPass');
        final reportFalse =
            VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.fromMap(
              rawFalse,
            );
        expect(reportFalse.nativeAllLanesPass, isFalse);
        expect(reportFalse.isVerifiedPass, isFalse);
      },
    );

    test('string "true"/"false" gate values are accepted', () {
      final report = _createSamplePassReport({
        'vulkanSetupOk': 'true',
        'renderReadbackOk': 'false',
        'allNativeLanesPass': 'true',
      });
      expect(report.vulkanSetupPass, isTrue);
      expect(report.renderReadbackPass, isFalse);
      expect(report.nativeAllLanesPass, isTrue);
    });

    test('fromMap handles malformed non-map inputs defensively', () {
      for (final invalid in <Object?>[null, 'not_a_map', 12345, 3.14, []]) {
        final report =
            VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.fromMap(
              invalid,
            );
        expect(report.pass, isFalse);
        expect(
          report.decision,
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
              .harnessException,
        );
        expect(report.isHarnessException, isTrue);
        expect(report.failureReason, 'native_result_not_a_map');
        expect(report.marker, _failMarker);
        expect(report.proofBoundary, _proofBoundary);
        expect(report.allNativeLanesPass, isFalse);
        expect(report.isVerifiedPass, isFalse);
        expect(report.isVerifiedDescriptorRejection, isFalse);
        for (final key in _gateKeys) {
          expect(report.gates[key], isFalse, reason: key);
        }
      }
    });

    test('fromMap handles missing/null fields defensively', () {
      final report =
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.fromMap({
            for (final key in _createSamplePassRawMap().keys) key: null,
          });
      expect(report.pass, isFalse);
      expect(
        report.decision,
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fail,
      );
      expect(report.status, 'FAIL');
      expect(report.marker, isEmpty);
      expect(report.proofBoundary, isEmpty);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.details, isEmpty);
      expect(report.allNativeLanesPass, isFalse);
      expect(report.nativeAllLanesPass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.isVerifiedDescriptorRejection, isFalse);
    });

    test('native UNSUPPORTED status (no Vulkan device) is unsupported', () {
      final report =
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.fromMap({
            'pass': false,
            'status': 'UNSUPPORTED',
            'marker': _failMarker,
            'proofBoundary': _proofBoundary,
            'failureReason': 'vulkan_unsupported:vulkan_no_physical_devices',
            for (final key in _gateKeys) key: false,
            'allNativeLanesPass': false,
            'nativeAllLanesPass': false,
            'details': const <String, Object?>{'vulkanUnsupported': true},
          });
      expect(
        report.decision,
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.unsupported,
      );
      expect(report.isUnsupported, isTrue);
      expect(report.isFail, isFalse);
      expect(report.vulkanSetupPass, isFalse);
      expect(report.failureReason, startsWith('vulkan_unsupported:'));
      expect(report.isVerifiedPass, isFalse);
      expect(report.isVerifiedDescriptorRejection, isFalse);
    });

    test('contradictory pass=false with PASS status is a plain fail', () {
      final report =
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.fromMap({
            'pass': false,
            'status': 'PASS',
            'marker': _passMarker,
            'proofBoundary': _proofBoundary,
            for (final key in _gateKeys) key: true,
            'allNativeLanesPass': true,
          });
      expect(
        report.decision,
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision.fail,
      );
      expect(report.isVerifiedPass, isFalse);
    });

    test('explicit decision field wins over status for failed reports', () {
      final report =
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.fromMap({
            'pass': false,
            'status': 'FAIL',
            'decision': 'harnessException',
          });
      expect(
        report.decision,
        VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeDecision
            .harnessException,
      );
    });

    test('unsupported and harnessFailure factories are fail-shaped', () {
      final unsupported =
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.unsupported(
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
      expect(unsupported.isVerifiedDescriptorRejection, isFalse);
      expect(unsupported.gates.length, _gateKeys.length);

      final harness =
          VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.harnessFailure(
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
      expect(harness.isVerifiedDescriptorRejection, isFalse);
    });
  });

  group(
    'malformed descriptor fail-shaped payload (no cornerRadius/opacity)',
    () {
      test('descriptor rejection detail fields are surfaced', () {
        final report = _createSampleRejectionReport();
        expect(report.descriptorRejectedBeforeVulkanOk, isTrue);
        expect(report.rejectionReason, 'unknown_layout_mode');
        expect(report.details['vulkanSetupState'], 'not_run');
        expect(report.details['vulkanObjectsCreatedAtRejection'], 0);
      });

      test('fail-shaped report never carries cornerRadius/opacity keys', () {
        final report = _createSampleRejectionReport();
        final map = report.toMap();
        expect(map.containsKey('cornerRadius'), isFalse);
        expect(map.containsKey('opacity'), isFalse);
        expect(map.containsKey('secondaryOpacity'), isFalse);
        expect(map.containsKey('cornerRadiusFractionOfCanvasWidth'), isFalse);
        expect(report.details.containsKey('cornerRadius'), isFalse);
        expect(report.details.containsKey('opacity'), isFalse);
      });
    },
  );

  group(
    'VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport value semantics',
    () {
      test('equal values are equal with equal hash codes', () {
        final a = _createSamplePassReport();
        final b = _createSamplePassReport();
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
        expect(
          a.toString(),
          contains(
            'VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport(',
          ),
        );
        expect(a.toString(), contains('marker: $_passMarker'));
      });

      test('inequality when any single field differs', () {
        final base = _createSamplePassReport();
        const diffs = <Map<String, Object?>>[
          {'pass': false},
          {'status': 'FAIL'},
          {'marker': 'other'},
          {'proofBoundary': 'other'},
          {'failureReason': 'x'},
          {'renderReadbackOk': false},
          {'helperResourcesReleasedOk': false},
          {'allNativeLanesPass': false},
          {
            'details': <String, Object?>{'k': 'v'},
          },
          {'raw': '{}'},
        ];
        for (final diff in diffs) {
          final variant = _createSamplePassReport(diff);
          expect(base, isNot(equals(variant)), reason: diff.toString());
        }
      });
    },
  );

  group('MethodChannel runner invocation', () {
    test(
      'invokes the exact route name with the freeFloatingPip descriptor primitives (no cornerRadius/opacity)',
      () async {
        MethodCall? capturedCall;
        const channel = MethodChannel(
          'test_multicam_dyndesc_vulkan_render_channel',
        );
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return _createSamplePassRawMap();
        });

        final descriptor =
            VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip();
        final report =
            await VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
              descriptor: descriptor,
              channel: channel,
            );

        expect(capturedCall, isNotNull);
        expect(capturedCall!.method, _method);
        final arguments = capturedCall!.arguments as Map<Object?, Object?>;
        expect(arguments['layoutMode'], descriptor.layoutMode.value);
        expect(arguments['pipAnchor'], descriptor.pipAnchor.value);
        expect(arguments['pipCenterX'], descriptor.pipCenterX);
        expect(arguments['pipCenterY'], descriptor.pipCenterY);
        expect(arguments['pipWidthFraction'], descriptor.pipWidthFraction);
        expect(arguments['pipAspectRatio'], descriptor.pipAspectRatio);
        expect(arguments['pipMarginFraction'], descriptor.pipMarginFraction);
        expect(arguments['splitDirection'], descriptor.splitDirection.value);
        expect(arguments['splitRatio'], descriptor.splitRatio);
        expect(arguments.containsKey('cornerRadius'), isFalse);
        expect(arguments.containsKey('opacity'), isFalse);
        expect(arguments, equals(descriptor.toMap()));
        expect(report.pass, isTrue);
        expect(report.isVerifiedPass, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test(
      'sends the leftRightSplit descriptor primitives (no cornerRadius/opacity)',
      () async {
        MethodCall? capturedCall;
        const channel = MethodChannel(
          'test_multicam_dyndesc_vulkan_render_leftright',
        );
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return _createSamplePassRawMap();
        });

        final descriptor =
            VGMultiCamDynamicDescriptorSpatialRenderInput.leftRightSplit();
        final report =
            await VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
              descriptor: descriptor,
              channel: channel,
            );

        final arguments = capturedCall!.arguments as Map<Object?, Object?>;
        expect(arguments['layoutMode'], 'splitScreen');
        expect(arguments['splitDirection'], 'leftRight');
        expect(arguments['splitRatio'], descriptor.splitRatio);
        expect(arguments.containsKey('cornerRadius'), isFalse);
        expect(arguments.containsKey('opacity'), isFalse);
        expect(arguments, equals(descriptor.toMap()));
        expect(report.pass, isTrue);
        expect(report.isVerifiedPass, isTrue);
        expect(report.allNativeLanesPass, isTrue);
      },
    );

    test('uses default vanguard_media_engine channel when omitted', () async {
      MethodCall? capturedCall;
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
        capturedCall = call;
        return _createSamplePassRawMap();
      });

      final report =
          await VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
            descriptor:
                VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
          );

      expect(capturedCall, isNotNull);
      expect(capturedCall!.method, _method);
      expect(report.pass, isTrue);
    });

    test(
      'diagnostic raw-descriptor route sends a malformed layoutMode map verbatim and native rejects it',
      () async {
        MethodCall? capturedCall;
        const channel = MethodChannel(
          'test_multicam_dyndesc_vulkan_render_malformed',
        );
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return _createSampleRejectionRawMap();
        });

        const malformedDescriptor = <String, Object?>{
          'layoutMode': 'unknownLayoutMode',
          'pipAnchor': 'freeFloating',
          'pipCenterX': 0.5,
          'pipCenterY': 0.5,
          'pipWidthFraction': 0.3,
          'pipAspectRatio': 9.0 / 16.0,
          'pipMarginFraction': 0.05,
          'splitDirection': 'topBottom',
          'splitRatio': 0.5,
        };

        final report =
            await VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmokeWithRawDescriptor(
              malformedDescriptor,
              channel: channel,
            );

        expect(capturedCall, isNotNull);
        expect(capturedCall!.method, _method);
        expect(capturedCall!.arguments, equals(malformedDescriptor));
        final arguments = capturedCall!.arguments as Map<Object?, Object?>;
        expect(arguments.containsKey('cornerRadius'), isFalse);
        expect(arguments.containsKey('opacity'), isFalse);
        expect(report.isVerifiedDescriptorRejection, isTrue);
        expect(report.isVerifiedPass, isFalse);
        expect(report.allNativeLanesPass, isFalse);
      },
    );

    test('missing plugin yields an unsupported report', () async {
      const channel = MethodChannel(
        'test_multicam_dyndesc_vulkan_render_missing',
      );
      // No handler registered -> MissingPluginException.
      final report =
          await VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
            descriptor:
                VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, startsWith('missing_plugin'));
      expect(report.isVerifiedPass, isFalse);
    });

    test('UNAVAILABLE platform exception yields an unsupported report', () async {
      const channel = MethodChannel(
        'test_multicam_dyndesc_vulkan_render_unavail',
      );
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'UNAVAILABLE', message: 'no coordinator');
      });
      final report =
          await VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
            descriptor:
                VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
            channel: channel,
          );
      expect(report.isUnsupported, isTrue);
      expect(report.failureReason, 'platform_exception:UNAVAILABLE');
      expect(report.isVerifiedPass, isFalse);
    });

    test('other platform exception yields a harnessException report', () async {
      const channel = MethodChannel('test_multicam_dyndesc_vulkan_render_pe');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'NATIVE_CRASH', message: 'Simulated');
      });
      final report =
          await VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
            descriptor:
                VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
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
      const channel = MethodChannel(
        'test_multicam_dyndesc_vulkan_render_timeout',
      );
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _createSamplePassRawMap();
      });
      final report =
          await VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
            descriptor:
                VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
            timeout: const Duration(milliseconds: 20),
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, 'timeout');
      expect(report.isVerifiedPass, isFalse);
    });

    test('generic exception yields a harnessException report', () async {
      const channel = MethodChannel(
        'test_multicam_dyndesc_vulkan_render_generic',
      );
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw StateError('Generic unexpected error');
      });
      final report =
          await VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
            descriptor:
                VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
            channel: channel,
          );
      expect(report.pass, isFalse);
      expect(report.isHarnessException, isTrue);
      expect(
        report.failureReason,
        anyOf(startsWith('platform_exception:'), startsWith('exception:')),
      );
      expect(report.isVerifiedPass, isFalse);
    });

    test('non-map native result yields a harnessException report', () async {
      const channel = MethodChannel(
        'test_multicam_dyndesc_vulkan_render_nonmap',
      );
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return 'status=PASS';
      });
      final report =
          await VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
            descriptor:
                VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
            channel: channel,
          );
      expect(report.isHarnessException, isTrue);
      expect(report.failureReason, 'native_result_not_a_map');
      expect(report.details['received'], 'status=PASS');
    });

    test('native UNSUPPORTED payload surfaces as unsupported', () async {
      const channel = MethodChannel(
        'test_multicam_dyndesc_vulkan_render_unsup',
      );
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return _createSamplePassRawMap({
          'pass': false,
          'status': 'UNSUPPORTED',
          'marker': _failMarker,
          'failureReason': 'vulkan_unsupported:vulkan_instance_unavailable:-9',
          for (final key in _gateKeys) key: false,
          'allNativeLanesPass': false,
          'nativeAllLanesPass': false,
        });
      });
      final report =
          await VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
            descriptor:
                VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
            channel: channel,
          );
      expect(report.isUnsupported, isTrue);
      expect(report.vulkanSetupPass, isFalse);
      expect(report.failureReason, startsWith('vulkan_unsupported:'));
      expect(report.isVerifiedPass, isFalse);
    });

    test('native fail payload surfaces the failing gate and reason', () async {
      const channel = MethodChannel('test_multicam_dyndesc_vulkan_render_fail');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return _createSamplePassRawMap({
          'pass': false,
          'status': 'FAIL',
          'marker': _failMarker,
          'failureReason': 'pixel_ownership_mismatch',
          'renderReadbackOk': false,
          'helperResourcesReleasedOk': false,
          'allNativeLanesPass': false,
          'nativeAllLanesPass': false,
        });
      });
      final report =
          await VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
            descriptor:
                VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
            channel: channel,
          );
      expect(report.isFail, isTrue);
      expect(report.renderReadbackPass, isFalse);
      expect(report.renderPass, isFalse);
      expect(report.resourceLifecyclePass, isFalse);
      expect(report.failureReason, 'pixel_ownership_mismatch');
      expect(report.hasFailMarker, isTrue);
      expect(report.isVerifiedPass, isFalse);
    });
  });
}
