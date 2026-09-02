// android_timeline_transition_vulkan_render_physical_smoke.dart
// Vanguard Media Engine — P5-COMPOSITOR-TRANS (sub-slice VULKAN-RENDER):
// Android True-DAG VulkanTimelineTransitionCompositor shader/raster proof
// diagnostic smoke physical harness.
//
// Proof lanes:
//   Lane 1: smoke report pass == true, vulkanSetupPass == true and
//           paramValidationPass == true (null handles, zero extents /
//           undersized readback, non-finite progress/weights, invalid
//           geometry fail closed with no Vulkan objects created).
//   Lane 2: smoke report crossfadePass == true (kNone hard cut red,
//           crossfade p=0.0 red, p=0.5 purple via fixed-function
//           constant-alpha blend, p=1.0 blue via offscreen readback
//           uniform-canvas checks).
//   Lane 3: smoke report slidePass == true (left/right/up/down at p=0.5,
//           quadrant-image pixel ownership proving viewport/scissor
//           translation).
//   Lane 4: smoke report wipePass == true (left/right/up/down at p=0.5,
//           quadrant-image pixel ownership proving push-constant crop UVs).
//   Lane 5: smoke report resourceLifecyclePass == true (helper temporary
//           Vulkan objects created == released, diagnostic device drained and
//           every owned handle nulled).
//   Lane 6: smoke report isVerifiedPass == true && allNativeLanesPass ==
//           nativeAllLanesPass && canonical PASS marker && canonical proof
//           boundary && toMap() round-trips.
//
// Target / proof boundary:
//   native_vulkan_timeline_transition_compositor_shader_raster_only_no_decode_no_export
//   Native temporary VkDevice + synthetic RGBA8 sampled images + private
//   Vulkan transition helper (existing AOT passthrough SPIR-V, no new
//   shaders) + offscreen attachment readback only. No MediaCodec decode, no
//   AHardwareBuffer import, no export session, no production VulkanBackend
//   mutation, and no app/editor UI. A device without a usable Vulkan driver
//   reports UNSUPPORTED (FAIL marker, no crash).

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_timeline_transition_vulkan_render_smoke.dart';

const String _passMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_VULKAN_RENDER_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_VULKAN_RENDER_PHYSICAL_SMOKE_FAIL';
const String _logPrefix =
    'ANDROID_DAG_PHASE5_TIMELINE_TRANSITION_VULKAN_RENDER';

void main() {
  runApp(const AndroidTimelineTransitionVulkanRenderPhysicalSmokeApp());
}

class AndroidTimelineTransitionVulkanRenderPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidTimelineTransitionVulkanRenderPhysicalSmokeApp({super.key});

  @override
  State<AndroidTimelineTransitionVulkanRenderPhysicalSmokeApp> createState() =>
      _AndroidTimelineTransitionVulkanRenderPhysicalSmokeAppState();
}

class _AndroidTimelineTransitionVulkanRenderPhysicalSmokeAppState
    extends State<AndroidTimelineTransitionVulkanRenderPhysicalSmokeApp> {
  String _status =
      'Initializing VulkanTimelineTransitionCompositor Render Physical Smoke…';

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
    VGTimelineTransitionVulkanRenderSmokeReport? report;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;

    try {
      report =
          await VGTimelineTransitionVulkanRenderSmokeReport.runAndroidDagPhase5TimelineTransitionVulkanRenderSmoke(
            timeout: const Duration(seconds: 30),
          ).timeout(const Duration(seconds: 40));

      lane1Pass =
          report.pass == true &&
          report.vulkanSetupPass &&
          report.paramValidationPass;
      print(
        '${_logPrefix}_LANE_1: pass=$lane1Pass reportPass=${report.pass} '
        'status=${report.status} vulkanSetupOk=${report.vulkanSetupPass} '
        'paramValidationPass=${report.paramValidationPass} '
        'invalidHandleRejectedOk=${report.invalidHandleRejectedPass} '
        'invalidDimensionsRejectedOk=${report.invalidDimensionsRejectedPass} '
        'nonFiniteProgressRejectedOk=${report.nonFiniteProgressRejectedPass} '
        'nonFiniteWeightRejectedOk=${report.nonFiniteWeightRejectedPass} '
        'invalidGeometryRejectedOk=${report.invalidGeometryRejectedPass} '
        'noVulkanObjectsAfterValidation=${report.details['noVulkanObjectsAfterValidation']} '
        'failureReason=${report.failureReason} '
        'deviceName=${report.details['deviceName']} '
        'apiVersion=${report.details['apiVersion']} '
        'driverVersion=${report.details['driverVersion']} '
        'vulkanUnsupported=${report.details['vulkanUnsupported']} '
        'shaderSource=${report.details['shaderSource']}',
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
        'slideLeftSentinelPixels=${report.details['slideLeftSentinelPixels']}',
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
        '${report.details['wipeUpProbeBr']} '
        'wipeLeftSentinelPixels=${report.details['wipeLeftSentinelPixels']}',
      );

      lane5Pass = report.resourceLifecyclePass;
      print(
        '${_logPrefix}_LANE_5: pass=$lane5Pass resourceLifecyclePass=${report.resourceLifecyclePass} '
        'helperResourcesReleasedOk=${report.helperResourcesReleasedPass} '
        'diagnosticTeardownOk=${report.diagnosticTeardownPass} '
        'helperTemporaryObjectsCreated=${report.details['helperTemporaryObjectsCreated']} '
        'helperTemporaryObjectsReleased=${report.details['helperTemporaryObjectsReleased']} '
        'teardownWaitIdleOk=${report.details['teardownWaitIdleOk']} '
        'teardownHandlesNull=${report.details['teardownHandlesNull']} '
        'readbackMemoryCoherent=${report.details['readbackMemoryCoherent']}',
      );

      final map = report.toMap();
      final roundTrip = VGTimelineTransitionVulkanRenderSmokeReport.fromMap(
        map,
      );
      final mapMatches = roundTrip == report;
      lane6Pass =
          report.isVerifiedPass &&
          report.allNativeLanesPass == report.nativeAllLanesPass &&
          report.hasPassMarker &&
          report.hasCanonicalProofBoundary &&
          mapMatches;
      print(
        '${_logPrefix}_LANE_6: pass=$lane6Pass isVerifiedPass=${report.isVerifiedPass} '
        'allNativeLanesPass=${report.allNativeLanesPass} '
        'nativeAllLanesPass=${report.nativeAllLanesPass} '
        'marker=${report.marker} '
        'proofBoundary=${report.proofBoundary} mapMatches=$mapMatches',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Vulkan transition render smoke exceeded timeout: $te';
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
        'unit': 'AndroidTimelineTransitionVulkanRenderSmokeHarness',
        'slice': 'P5-COMPOSITOR-TRANS-VULKAN-RENDER',
        'target':
            VGTimelineTransitionVulkanRenderSmokeReport.proofBoundaryConstant,
        'pass': allPass,
        'marker': allPass ? _passMarker : _failMarker,
        'lanes': <String, dynamic>{
          'lane1_setupAndParamValidation': {
            'pass': lane1Pass,
            'reportPass': report?.pass,
            'status': report?.status,
            'vulkanSetupPass': report?.vulkanSetupPass,
            'paramValidationPass': report?.paramValidationPass,
          },
          'lane2_crossfade': {
            'pass': lane2Pass,
            'crossfadePass': report?.crossfadePass,
          },
          'lane3_slide': {'pass': lane3Pass, 'slidePass': report?.slidePass},
          'lane4_wipe': {'pass': lane4Pass, 'wipePass': report?.wipePass},
          'lane5_resourceLifecycle': {
            'pass': lane5Pass,
            'resourceLifecyclePass': report?.resourceLifecyclePass,
          },
          'lane6_telemetry': {
            'pass': lane6Pass,
            'isVerifiedPass': report?.isVerifiedPass,
            'allNativeLanesPass': report?.allNativeLanesPass,
            'nativeAllLanesPass': report?.nativeAllLanesPass,
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
