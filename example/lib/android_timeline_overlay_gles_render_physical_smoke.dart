// android_timeline_overlay_gles_render_physical_smoke.dart
// Vanguard Media Engine — P5-OVERLAYS-TRANS (sub-slice GLES-RENDER):
// Android True-DAG GlesOverlayCompositor multi-layer shader/raster proof
// diagnostic smoke physical harness.
//
// Proof lanes:
//   Lane 1: smoke report pass == true, eglSetupPass == true and
//           paramValidationPass == true (texture 0, zero dimensions,
//           non-finite transform parameters, invalid opacity, unsupported
//           targets fail closed).
//   Lane 2: smoke report transformPass == true (translate+scale,
//           90 deg rotation, 180 deg rotation, off-canvas clipping via
//           glReadPixels quadrant-texture checks).
//   Lane 3: smoke report blendPass == true (uniform opacity, texture alpha,
//           alpha*opacity, zero, opaque Porter-Duff source-over blend).
//   Lane 4: smoke report zOrderPass == true (multi-layer forward order,
//           reversed order, and empty-list no-op).
//   Lane 5: smoke report targetPass == true (GL_TEXTURE_2D fully accepted,
//           GL_TEXTURE_EXTERNAL_OES structurally accepted through target
//           validation and sampler compile/link, unsupported still rejected).
//   Lane 6: smoke report statePass == true (blend, viewport, and GL active
//           texture / binding / program restoration).
//   Lane 7: smoke report parityPass == true (GlesOverlayLayerDescriptor layout
//           and pure-math ComputeOverlayTransform parity).
//   Lane 8: smoke report isPass == true && allNativeLanesPass ==
//           nativeAllLanesPass && canonical && canonical PASS marker &&
//           canonical proof boundary && toMap() round-trips.
//
// Target / proof boundary:
//   native_gles_timeline_overlay_compositor_shader_raster_only_no_vulkan_no_decode_no_export_no_product
//   Native temporary EGL pbuffer + synthetic GL_TEXTURE_2D textures + private
//   GLES overlay helper + glReadPixels only. No Vulkan, no MediaCodec decode,
//   no SurfaceTexture/decoder OES frame proof, no export session, and no
//   product/editor UI.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_timeline_overlay_gles_render_smoke.dart';

const String _passMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_GLES_RENDER_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_GLES_RENDER_PHYSICAL_SMOKE_FAIL';
const String _logPrefix = 'ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_GLES_RENDER';

void main() {
  runApp(const AndroidTimelineOverlayGlesRenderPhysicalSmokeApp());
}

class AndroidTimelineOverlayGlesRenderPhysicalSmokeApp extends StatefulWidget {
  const AndroidTimelineOverlayGlesRenderPhysicalSmokeApp({super.key});

  @override
  State<AndroidTimelineOverlayGlesRenderPhysicalSmokeApp> createState() =>
      _AndroidTimelineOverlayGlesRenderPhysicalSmokeAppState();
}

class _AndroidTimelineOverlayGlesRenderPhysicalSmokeAppState
    extends State<AndroidTimelineOverlayGlesRenderPhysicalSmokeApp> {
  String _status = 'Initializing GlesOverlayCompositor Render Physical Smoke…';

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
    VGTimelineOverlayGlesRenderSmokeReport? report;

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
          await VGTimelineOverlayGlesRenderSmokeReport.runAndroidDagPhase5TimelineOverlayGlesRenderSmoke(
            timeout: const Duration(seconds: 20),
          ).timeout(const Duration(seconds: 30));

      lane1Pass =
          report.pass == true &&
          report.eglSetupPass &&
          report.paramValidationPass;
      print(
        '${_logPrefix}_LANE_1: pass=$lane1Pass reportPass=${report.pass} '
        'status=${report.status} eglSetupOk=${report.eglSetupPass} '
        'paramValidationPass=${report.paramValidationPass} '
        'invalidTextureRejectedOk=${report.invalidTextureRejectedPass} '
        'invalidDimensionsRejectedOk=${report.invalidDimensionsRejectedPass} '
        'nonFiniteTransformRejectedOk=${report.nonFiniteTransformRejectedPass} '
        'invalidOpacityRejectedOk=${report.invalidOpacityRejectedPass} '
        'unsupportedTargetRejectedOk=${report.unsupportedTargetRejectedPass} '
        'failureReason=${report.failureReason} '
        'glVersion=${report.details['glVersion']} '
        'glRenderer=${report.details['glRenderer']} '
        'eglClientVersion=${report.details['eglClientVersion']}',
      );

      lane2Pass = report.transformPass;
      print(
        '${_logPrefix}_LANE_2: pass=$lane2Pass transformPass=${report.transformPass} '
        'singleLayerTransformOk=${report.singleLayerTransformPass} '
        'translateScaleChecksum=${report.details['translateScaleChecksum']} '
        'rotate90Checksum=${report.details['rotate90Checksum']} '
        'rotate180Checksum=${report.details['rotate180Checksum']} '
        'offCanvasClipChecksum=${report.details['offCanvasClipChecksum']}',
      );

      lane3Pass = report.blendPass;
      print(
        '${_logPrefix}_LANE_3: pass=$lane3Pass blendPass=${report.blendPass} '
        'opacityBlendOk=${report.opacityBlendPass} '
        'opacityHalfUniformCenterRgba=${report.details['opacityHalfUniformCenterRgba']} '
        'textureAlphaBlendCenterRgba=${report.details['textureAlphaBlendCenterRgba']} '
        'textureAlphaTimesOpacityCenterRgba=${report.details['textureAlphaTimesOpacityCenterRgba']}',
      );

      lane4Pass = report.zOrderPass;
      print(
        '${_logPrefix}_LANE_4: pass=$lane4Pass zOrderPass=${report.zOrderPass} '
        'multiLayerZOrderOk=${report.multiLayerZOrderPass} '
        'stackForwardChecksum=${report.details['stackForwardChecksum']} '
        'stackReversedChecksum=${report.details['stackReversedChecksum']} '
        'emptyListNoOpOk=${report.details['emptyListNoOpOk']}',
      );

      lane5Pass = report.targetPass;
      print(
        '${_logPrefix}_LANE_5: pass=$lane5Pass targetPass=${report.targetPass} '
        'texture2dTargetAcceptedOk=${report.texture2dTargetAcceptedPass} '
        'oesTargetStructuralOk=${report.oesTargetStructuralPass} '
        'unsupportedTargetStillRejectedOk=${report.unsupportedTargetStillRejectedPass} '
        'oesExtensionAvailable=${report.details['oesExtensionAvailable']} '
        'oesSingleDrawOk=${report.details['oesSingleDrawOk']} '
        'oesMixedWith2dDrawOk=${report.details['oesMixedWith2dDrawOk']} '
        'oesProofScope=${report.details['oesProofScope']}',
      );

      lane6Pass = report.statePass;
      print(
        '${_logPrefix}_LANE_6: pass=$lane6Pass statePass=${report.statePass} '
        'blendStateRestoredOk=${report.blendStateRestoredPass} '
        'viewportRestoredOk=${report.viewportRestoredPass} '
        'glStateRestoredOk=${report.glStateRestoredPass} '
        'priorBlendStateRestored=${report.details['priorBlendStateRestored']} '
        'defaultBlendStateRestored=${report.details['defaultBlendStateRestored']}',
      );

      lane7Pass = report.parityPass;
      print(
        '${_logPrefix}_LANE_7: pass=$lane7Pass parityPass=${report.parityPass} '
        'structParityOk=${report.structParityPass} '
        'descriptorFields=${report.details['descriptorFields']} '
        'mirroredDartFields=${report.details['mirroredDartFields']} '
        'descriptorStandardLayout=${report.details['descriptorStandardLayout']}',
      );

      final map = report.toMap();
      final roundTrip = VGTimelineOverlayGlesRenderSmokeReport.fromMap(map);
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
        'proofBoundary=${report.proofBoundary} mapMatches=$mapMatches',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: GLES overlay render smoke exceeded timeout: $te';
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
        'unit': 'AndroidTimelineOverlayGlesRenderSmokeHarness',
        'slice': 'P5-OVERLAYS-TRANS-GLES-RENDER',
        'target': VGTimelineOverlayGlesRenderSmokeReport.proofBoundaryConstant,
        'pass': allPass,
        'marker': allPass ? _passMarker : _failMarker,
        'lanes': <String, dynamic>{
          'lane1_validation': {
            'pass': lane1Pass,
            'reportPass': report?.pass,
            'eglSetupPass': report?.eglSetupPass,
            'paramValidationPass': report?.paramValidationPass,
          },
          'lane2_transform': {
            'pass': lane2Pass,
            'transformPass': report?.transformPass,
          },
          'lane3_blend': {'pass': lane3Pass, 'blendPass': report?.blendPass},
          'lane4_zOrder': {'pass': lane4Pass, 'zOrderPass': report?.zOrderPass},
          'lane5_target': {'pass': lane5Pass, 'targetPass': report?.targetPass},
          'lane6_state': {'pass': lane6Pass, 'statePass': report?.statePass},
          'lane7_parity': {'pass': lane7Pass, 'parityPass': report?.parityPass},
          'lane8_telemetry': {
            'pass': lane8Pass,
            'isPass': report?.isPass,
            'allNativeLanesPass': report?.allNativeLanesPass,
            'nativeAllLanesPass': report?.nativeAllLanesPass,
            'canonical': report?.canonical,
            'marker': report?.marker,
            'proofBoundary': report?.proofBoundary,
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
