// android_timeline_transition_gles_render_physical_smoke.dart
// Vanguard Media Engine — P5-COMPOSITOR-TRANS (sub-slice GLES-RENDER):
// Android True-DAG GlesTimelineTransitionCompositor shader/raster proof
// diagnostic smoke physical harness.
//
// Proof lanes:
//   Lane 1: smoke report pass == true, eglSetupPass == true and
//           paramValidationPass == true (texture 0, zero dimensions,
//           non-finite progress/weights, unsupported targets fail closed).
//   Lane 2: smoke report crossfadePass == true (kNone hard cut red,
//           crossfade p=0.0 red, p=0.5 purple mix, p=1.0 blue via
//           glReadPixels uniform-canvas checks).
//   Lane 3: smoke report slidePass == true (left/right/up/down at p=0.5,
//           quadrant-texture pixel ownership proving viewport translation).
//   Lane 4: smoke report wipePass == true (left/right/up/down at p=0.5,
//           quadrant-texture pixel ownership proving crop regions).
//   Lane 5: smoke report textureTargetPass == true (GL_TEXTURE_2D fully
//           accepted, GL_TEXTURE_EXTERNAL_OES structurally accepted through
//           every sampler permutation, unsupported targets still rejected).
//   Lane 6: smoke report isVerifiedPass == true && allNativeLanesPass ==
//           nativeAllLanesPass && stateRestorePass && canonical PASS marker
//           && canonical proof boundary && toMap() round-trips.
//
// Target / proof boundary:
//   native_gles_timeline_transition_compositor_shader_raster_only_no_vulkan_no_decode_no_export
//   Native temporary EGL pbuffer + synthetic GL_TEXTURE_2D textures + private
//   GLES transition helper + glReadPixels only. No Vulkan, no MediaCodec
//   decode, no SurfaceTexture/decoder OES frame proof, no export session,
//   and no app/editor UI.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_timeline_transition_gles_render_smoke.dart';

const String _passMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_GLES_RENDER_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_GLES_RENDER_PHYSICAL_SMOKE_FAIL';
const String _logPrefix = 'ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_GLES_RENDER';

void main() {
  runApp(const AndroidTimelineTransitionGlesRenderPhysicalSmokeApp());
}

class AndroidTimelineTransitionGlesRenderPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidTimelineTransitionGlesRenderPhysicalSmokeApp({super.key});

  @override
  State<AndroidTimelineTransitionGlesRenderPhysicalSmokeApp> createState() =>
      _AndroidTimelineTransitionGlesRenderPhysicalSmokeAppState();
}

class _AndroidTimelineTransitionGlesRenderPhysicalSmokeAppState
    extends State<AndroidTimelineTransitionGlesRenderPhysicalSmokeApp> {
  String _status =
      'Initializing GlesTimelineTransitionCompositor Render Physical Smoke…';

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
    VGTimelineTransitionGlesRenderSmokeReport? report;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;

    try {
      report =
          await VGTimelineTransitionGlesRenderSmokeReport.runAndroidDagPhase5TimelineTransitionGlesRenderSmoke(
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
        'nonFiniteProgressRejectedOk=${report.nonFiniteProgressRejectedPass} '
        'nonFiniteWeightRejectedOk=${report.nonFiniteWeightRejectedPass} '
        'unsupportedTargetRejectedOk=${report.unsupportedTargetRejectedPass} '
        'failureReason=${report.failureReason} '
        'glVersion=${report.details['glVersion']} '
        'glRenderer=${report.details['glRenderer']} '
        'eglClientVersion=${report.details['eglClientVersion']}',
      );

      lane2Pass = report.crossfadePass;
      print(
        '${_logPrefix}_LANE_2: pass=$lane2Pass crossfadePass=${report.crossfadePass} '
        'hardCutNoneOk=${report.hardCutNonePass} '
        'crossfadeStartOk=${report.crossfadeStartPass} '
        'crossfadeMidOk=${report.crossfadeMidPass} '
        'crossfadeEndOk=${report.crossfadeEndPass} '
        'hardCutNoneCenterRgb=${report.details['hardCutNoneCenterRgb']} '
        'crossfadeStartCenterRgb=${report.details['crossfadeStartCenterRgb']} '
        'crossfadeMidCenterRgb=${report.details['crossfadeMidCenterRgb']} '
        'crossfadeEndCenterRgb=${report.details['crossfadeEndCenterRgb']} '
        'crossfadeMidChecksum=${report.details['crossfadeMidChecksum']}',
      );

      lane3Pass = report.slidePass;
      print(
        '${_logPrefix}_LANE_3: pass=$lane3Pass slidePass=${report.slidePass} '
        'slideLeftOk=${report.slideLeftPass} '
        'slideRightOk=${report.slideRightPass} '
        'slideUpOk=${report.slideUpPass} '
        'slideDownOk=${report.slideDownPass} '
        'slideLeftProbes=${report.details['slideLeftProbeTl']}|'
        '${report.details['slideLeftProbeTr']}|'
        '${report.details['slideLeftProbeBl']}|'
        '${report.details['slideLeftProbeBr']} '
        'slideUpProbes=${report.details['slideUpProbeTl']}|'
        '${report.details['slideUpProbeTr']}|'
        '${report.details['slideUpProbeBl']}|'
        '${report.details['slideUpProbeBr']} '
        'viewportAfterSlide=${report.details['viewportAfterSlide']}',
      );

      lane4Pass = report.wipePass;
      print(
        '${_logPrefix}_LANE_4: pass=$lane4Pass wipePass=${report.wipePass} '
        'wipeLeftOk=${report.wipeLeftPass} '
        'wipeRightOk=${report.wipeRightPass} '
        'wipeUpOk=${report.wipeUpPass} '
        'wipeDownOk=${report.wipeDownPass} '
        'wipeLeftProbes=${report.details['wipeLeftProbeTl']}|'
        '${report.details['wipeLeftProbeTr']}|'
        '${report.details['wipeLeftProbeBl']}|'
        '${report.details['wipeLeftProbeBr']} '
        'wipeUpProbes=${report.details['wipeUpProbeTl']}|'
        '${report.details['wipeUpProbeTr']}|'
        '${report.details['wipeUpProbeBl']}|'
        '${report.details['wipeUpProbeBr']}',
      );

      lane5Pass = report.textureTargetPass;
      print(
        '${_logPrefix}_LANE_5: pass=$lane5Pass textureTargetPass=${report.textureTargetPass} '
        'texture2dTargetAcceptedOk=${report.texture2dTargetAcceptedPass} '
        'oesTargetStructuralOk=${report.oesTargetStructuralPass} '
        'unsupportedTargetStillRejectedOk=${report.unsupportedTargetStillRejectedPass} '
        'oesExtensionAvailable=${report.details['oesExtensionAvailable']} '
        'oesFromMixDrawOk=${report.details['oesFromMixDrawOk']} '
        'oesToMixDrawOk=${report.details['oesToMixDrawOk']} '
        'oesBothMixDrawOk=${report.details['oesBothMixDrawOk']} '
        'oesFromOpaqueDrawOk=${report.details['oesFromOpaqueDrawOk']} '
        'oesToOpaqueDrawOk=${report.details['oesToOpaqueDrawOk']} '
        'oesProofScope=${report.details['oesProofScope']}',
      );

      final map = report.toMap();
      final roundTrip = VGTimelineTransitionGlesRenderSmokeReport.fromMap(map);
      final mapMatches = roundTrip == report;
      lane6Pass =
          report.isVerifiedPass &&
          report.allNativeLanesPass == report.nativeAllLanesPass &&
          report.stateRestorePass &&
          report.hasPassMarker &&
          report.hasCanonicalProofBoundary &&
          mapMatches;
      print(
        '${_logPrefix}_LANE_6: pass=$lane6Pass isVerifiedPass=${report.isVerifiedPass} '
        'allNativeLanesPass=${report.allNativeLanesPass} '
        'nativeAllLanesPass=${report.nativeAllLanesPass} '
        'viewportRestoredOk=${report.viewportRestoredPass} '
        'glStateRestoredOk=${report.glStateRestoredPass} '
        'marker=${report.marker} '
        'proofBoundary=${report.proofBoundary} mapMatches=$mapMatches',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: GLES transition render smoke exceeded timeout: $te';
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
          topLevelError == null;

      final payload = <String, dynamic>{
        'unit': 'AndroidTimelineTransitionGlesRenderSmokeHarness',
        'slice': 'P5-COMPOSITOR-TRANS-GLES-RENDER',
        'target':
            VGTimelineTransitionGlesRenderSmokeReport.proofBoundaryConstant,
        'pass': allPass,
        'marker': allPass ? _passMarker : _failMarker,
        'lanes': <String, dynamic>{
          'lane1_paramValidation': {
            'pass': lane1Pass,
            'reportPass': report?.pass,
            'eglSetupPass': report?.eglSetupPass,
            'paramValidationPass': report?.paramValidationPass,
          },
          'lane2_crossfade': {
            'pass': lane2Pass,
            'crossfadePass': report?.crossfadePass,
          },
          'lane3_slide': {'pass': lane3Pass, 'slidePass': report?.slidePass},
          'lane4_wipe': {'pass': lane4Pass, 'wipePass': report?.wipePass},
          'lane5_textureTarget': {
            'pass': lane5Pass,
            'textureTargetPass': report?.textureTargetPass,
          },
          'lane6_telemetry': {
            'pass': lane6Pass,
            'isVerifiedPass': report?.isVerifiedPass,
            'allNativeLanesPass': report?.allNativeLanesPass,
            'nativeAllLanesPass': report?.nativeAllLanesPass,
            'stateRestorePass': report?.stateRestorePass,
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
