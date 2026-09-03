// android_beauty_v2_gles_render_physical_smoke.dart
// Vanguard Media Engine — P5-BEAUTY-V2-GLES-RENDER:
// Android True-DAG GlesBeautyV2Compositor 3-pass bilateral beauty smoothing
// shader/raster + CPU reference parity diagnostic smoke physical harness.
//
// Proof lanes:
//   Lane 1: smoke report pass == true, eglSetupPass == true, glVersionPass == true
//           and paramValidationPass == true (texture 0, zero dimensions,
//           invalid intensity, invalid parameters fail closed).
//   Lane 2: smoke report nonePresetPass == true (flat identity and gradient
//           minimum ramp pass within tolerance).
//   Lane 3: smoke report softPresetCpuParityPass == true (primary CPU parity gate
//           under 0.5 intensity; softPresetSmoothingObserved logged as telemetry).
//   Lane 4: smoke report strongPresetCpuParityPass == true (primary CPU parity gate
//           under 0.75 intensity; strongPresetEdgePreservationObserved logged as telemetry).
//   Lane 5: smoke report maxPresetPass == true (CPU parity under 1.0 intensity,
//           maxPresetBoundsPass within [0, 255], and maxPresetMidtoneLiftPass > 0).
//   Lane 6: smoke report statePass == true (all temporary GL objects released and
//           GL state restored bit-for-bit).
//   Lane 7: smoke report structParityPass == true (GlesBeautyV2Parameters layout parity).
//   Lane 8: smoke report isPass == true && allNativeLanesPass ==
//           nativeAllLanesPass && canonical && canonical PASS marker &&
//           canonical proof boundary && toMap() round-trips.
//
// Target / proof boundary:
//   native_gles_beauty_v2_compositor_shader_raster_only_no_vulkan_no_decode_no_export_no_product
//   Native temporary EGL pbuffer + synthetic GL_TEXTURE_2D textures + private
//   GLES beauty helper + glReadPixels only. No Vulkan, no MediaCodec decode,
//   no export session, and no product/editor UI.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_beauty_v2_gles_render_smoke.dart';

const String _passMarker =
    'ANDROID_DAG_PHASE5_BEAUTY_V2_GLES_RENDER_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_BEAUTY_V2_GLES_RENDER_PHYSICAL_SMOKE_FAIL';
const String _logPrefix = 'ANDROID_DAG_PHASE5_BEAUTY_V2_GLES_RENDER';

void main() {
  runApp(const AndroidBeautyV2GlesRenderPhysicalSmokeApp());
}

class AndroidBeautyV2GlesRenderPhysicalSmokeApp extends StatefulWidget {
  const AndroidBeautyV2GlesRenderPhysicalSmokeApp({super.key});

  @override
  State<AndroidBeautyV2GlesRenderPhysicalSmokeApp> createState() =>
      _AndroidBeautyV2GlesRenderPhysicalSmokeAppState();
}

class _AndroidBeautyV2GlesRenderPhysicalSmokeAppState
    extends State<AndroidBeautyV2GlesRenderPhysicalSmokeApp> {
  String _status = 'Initializing GlesBeautyV2Compositor Render Physical Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('${_logPrefix}_SMOKE_START');
    String? topLevelError;
    VGBeautyV2GlesRenderSmokeReport? report;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    var lane7Pass = false;
    var lane8Pass = false;

    try {
      report =
          await VGBeautyV2GlesRenderSmokeReport.runAndroidDagPhase5BeautyV2GlesRenderSmoke(
            timeout: const Duration(seconds: 20),
          ).timeout(const Duration(seconds: 30));

      lane1Pass =
          report.pass == true &&
          report.eglSetupPass &&
          report.glVersionPass &&
          report.paramValidationPass;
      print(
        '${_logPrefix}_LANE_1: pass=$lane1Pass reportPass=${report.pass} '
        'status=${report.status} eglSetupOk=${report.eglSetupPass} '
        'glVersionOk=${report.glVersionPass} '
        'paramValidationPass=${report.paramValidationPass} '
        'invalidTextureRejectedOk=${report.invalidTextureRejectedPass} '
        'invalidDimensionsRejectedOk=${report.invalidDimensionsRejectedPass} '
        'invalidIntensityRejectedOk=${report.invalidIntensityRejectedPass} '
        'invalidParameterRejectedOk=${report.invalidParameterRejectedPass} '
        'failureReason=${report.failureReason} '
        'glVersion=${report.details['glVersion']} '
        'glRenderer=${report.details['glRenderer']} '
        'eglClientVersion=${report.details['eglClientVersion']}',
      );

      lane2Pass = report.nonePresetPass;
      print(
        '${_logPrefix}_LANE_2: pass=$lane2Pass nonePresetPass=${report.nonePresetPass} '
        'nonePresetFlatIdentityOk=${report.nonePresetFlatIdentityPass} '
        'nonePresetGradientMinimumRampOk=${report.nonePresetGradientMinimumRampPass} '
        'nonePresetFlatDelta=${report.details['nonePresetFlatDelta']} '
        'nonePresetGradientMae=${report.details['nonePresetGradientMae']}',
      );

      lane3Pass = report.softPresetCpuParityPass;
      print(
        '${_logPrefix}_LANE_3: pass=$lane3Pass softPresetCpuParityPass=${report.softPresetCpuParityPass} '
        'softPresetSmoothingObservedOk=${report.softPresetSmoothingObserved} '
        'softMae=${report.details['softMae']} '
        'softMaxLsb=${report.details['softMaxLsb']} '
        'softVarianceBefore=${report.details['softVarianceBefore']} '
        'softVarianceAfter=${report.details['softVarianceAfter']}',
      );

      lane4Pass = report.strongPresetCpuParityPass;
      print(
        '${_logPrefix}_LANE_4: pass=$lane4Pass strongPresetCpuParityPass=${report.strongPresetCpuParityPass} '
        'strongPresetEdgePreservationOk=${report.strongPresetEdgePreservationObserved} '
        'strongMae=${report.details['strongMae']} '
        'strongMaxLsb=${report.details['strongMaxLsb']} '
        'strongEdgeStepBefore=${report.details['strongEdgeStepBefore']} '
        'strongEdgeStepAfter=${report.details['strongEdgeStepAfter']}',
      );

      lane5Pass = report.maxPresetPass;
      print(
        '${_logPrefix}_LANE_5: pass=$lane5Pass maxPresetPass=${report.maxPresetPass} '
        'maxPresetCpuParityOk=${report.maxPresetCpuParityPass} '
        'maxPresetBoundsOk=${report.maxPresetBoundsPass} '
        'maxPresetMidtoneLiftOk=${report.maxPresetMidtoneLiftPass} '
        'maxMae=${report.details['maxMae']} '
        'maxMaxLsb=${report.details['maxMaxLsb']} '
        'maxLumaBefore=${report.details['maxLumaBefore']} '
        'maxLumaAfter=${report.details['maxLumaAfter']}',
      );

      lane6Pass = report.statePass;
      print(
        '${_logPrefix}_LANE_6: pass=$lane6Pass statePass=${report.statePass} '
        'lifecycleResourcesReleasedOk=${report.lifecycleResourcesReleasedPass} '
        'glStateRestoredOk=${report.glStateRestoredPass} '
        'glObjectsAllocated=${report.details['glObjectsAllocated']} '
        'glObjectsReleased=${report.details['glObjectsReleased']}',
      );

      lane7Pass = report.parityPass;
      print(
        '${_logPrefix}_LANE_7: pass=$lane7Pass parityPass=${report.parityPass} '
        'structParityOk=${report.structParityPass} '
        'paramsStructSizeBytes=${report.details['paramsStructSizeBytes']} '
        'paramsStructFields=${report.details['paramsStructFields']} '
        'presetRampTableOk=${report.details['presetRampTableOk']}',
      );

      final map = report.toMap();
      final roundTrip = VGBeautyV2GlesRenderSmokeReport.fromMap(map);
      final mapMatches = roundTrip == report;
      lane8Pass =
          report.isPass &&
          report.allNativeLanesPass == report.nativeAllLanesPass &&
          report.canonical &&
          report.hasPassMarker &&
          report.hasCanonicalProofBoundary &&
          mapMatches;
      print(
        '${_logPrefix}_LANE_8: pass=$lane8Pass isPass=${report.isPass} '
        'allNativeLanesPass=${report.allNativeLanesPass} '
        'nativeAllLanesPass=${report.nativeAllLanesPass} '
        'canonical=${report.canonical} '
        'marker=${report.marker} '
        'proofBoundary=${report.proofBoundary} '
        'softPresetSmoothingObserved=${report.softPresetSmoothingObserved} '
        'strongPresetEdgePreservationObserved=${report.strongPresetEdgePreservationObserved} '
        'mapMatches=$mapMatches',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: GLES beauty render smoke exceeded timeout: $te';
      print('${_logPrefix}_SMOKE_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('${_logPrefix}_SMOKE_ERROR: $topLevelError');
    } finally {
      final allPass =
          lane1Pass &&
          lane2Pass &&
          lane3Pass &&
          lane4Pass &&
          lane5Pass &&
          lane6Pass &&
          lane7Pass &&
          lane8Pass &&
          topLevelError == null;

      final payload = <String, dynamic>{
        'unit': 'AndroidBeautyV2GlesRenderPhysicalSmokeHarness',
        'slice': 'P5-BEAUTY-V2-GLES-RENDER',
        'target': VGBeautyV2GlesRenderSmokeReport.proofBoundaryConstant,
        'pass': allPass,
        'marker': allPass ? _passMarker : _failMarker,
        'lanes': <String, dynamic>{
          'lane1_validation_and_setup': {
            'pass': lane1Pass,
            'reportPass': report?.pass,
            'eglSetupPass': report?.eglSetupPass,
            'glVersionPass': report?.glVersionPass,
            'paramValidationPass': report?.paramValidationPass,
          },
          'lane2_none_preset': {
            'pass': lane2Pass,
            'nonePresetPass': report?.nonePresetPass,
            'nonePresetFlatIdentityPass': report?.nonePresetFlatIdentityPass,
            'nonePresetGradientMinimumRampPass':
                report?.nonePresetGradientMinimumRampPass,
          },
          'lane3_soft_preset': {
            'pass': lane3Pass,
            'softPresetCpuParityPass': report?.softPresetCpuParityPass,
            'softPresetSmoothingObserved': report?.softPresetSmoothingObserved,
          },
          'lane4_strong_preset': {
            'pass': lane4Pass,
            'strongPresetCpuParityPass': report?.strongPresetCpuParityPass,
            'strongPresetEdgePreservationObserved':
                report?.strongPresetEdgePreservationObserved,
          },
          'lane5_max_preset': {
            'pass': lane5Pass,
            'maxPresetPass': report?.maxPresetPass,
            'maxPresetCpuParityPass': report?.maxPresetCpuParityPass,
            'maxPresetBoundsPass': report?.maxPresetBoundsPass,
            'maxPresetMidtoneLiftPass': report?.maxPresetMidtoneLiftPass,
          },
          'lane6_lifecycle_and_state': {
            'pass': lane6Pass,
            'statePass': report?.statePass,
            'lifecycleResourcesReleasedPass':
                report?.lifecycleResourcesReleasedPass,
            'glStateRestoredPass': report?.glStateRestoredPass,
          },
          'lane7_struct_parity': {
            'pass': lane7Pass,
            'parityPass': report?.parityPass,
            'structParityPass': report?.structParityPass,
          },
          'lane8_telemetry_and_aggregates': {
            'pass': lane8Pass,
            'isPass': report?.isPass,
            'allNativeLanesPass': report?.allNativeLanesPass,
            'nativeAllLanesPass': report?.nativeAllLanesPass,
            'canonical': report?.canonical,
            'marker': report?.marker,
            'proofBoundary': report?.proofBoundary,
            'softPresetSmoothingObserved': report?.softPresetSmoothingObserved,
            'strongPresetEdgePreservationObserved':
                report?.strongPresetEdgePreservationObserved,
          },
        },
        'smokeReport': report?.toMap(),
        'error': topLevelError,
      };

      print('${_logPrefix}_JSON:${jsonEncode(payload)}');
      print(allPass ? _passMarker : _failMarker);

      if (mounted) {
        setState(() {
          _status = allPass ? 'PASS' : 'FAIL';
        });
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(allPass ? 0 : 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}
