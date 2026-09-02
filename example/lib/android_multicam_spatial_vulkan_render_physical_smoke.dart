// android_multicam_spatial_vulkan_render_physical_smoke.dart
// Vanguard Media Engine - P3-MULTICAM-NODE (sub-slice SPATIAL-VULKAN-RENDER):
// Android True-DAG VulkanMultiCamSpatialCompositor two-texture spatial layout
// proof diagnostic smoke physical harness.
//
// Proof lanes:
//   Lane 1: smoke report pass == true, vulkanSetupPass == true and
//           syntheticImportPass == true (temporary Vulkan instance/device,
//           synthetic sampled images, color attachment, readback buffer created).
//   Lane 2: smoke report paramValidationPass == true (null handles, zero extents,
//           undersized readback, invalid/out-of-bounds/overflowing rects fail
//           closed with no Vulkan objects created).
//   Lane 3: smoke report spatialLayoutPass == true (top/bottom split, left/right
//           split, PiP top-left, PiP free-floating, and partial coverage sentinel
//           pixel ownership checks all pass).
//   Lane 4: smoke report resourceLifecyclePass == true (helper temporary Vulkan
//           objects created == released, diagnostic device drained and every
//           owned handle nulled).
//   Lane 5: smoke report isVerifiedPass == true && allNativeLanesPass ==
//           nativeAllLanesPass && canonical PASS marker && canonical proof
//           boundary && toMap() round-trips.
//
// Target / proof boundary:
//   native_multicam_spatial_vulkan_two_texture_layout_render_readback_only_no_gles_no_camera_no_oes_no_opacity_no_corner_radius_no_recording_no_product
//   Native temporary VkDevice + synthetic RGBA8 sampled images + private
//   Vulkan spatial helper (existing AOT passthrough SPIR-V, no new shaders) +
//   offscreen attachment readback only. No Camera2, no GLES, no OES/AHardwareBuffer
//   import, no opacity, no corner radius, no recording, no export, no production
//   VulkanBackend mutation, and no app/editor UI. A device without a usable Vulkan
//   driver reports UNSUPPORTED (FAIL marker, no crash).

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_multicam_spatial_vulkan_render_smoke.dart';

const String _passMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_VULKAN_RENDER_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_VULKAN_RENDER_SMOKE_FAIL';
const String _logPrefix = 'ANDROID_DAG_PHASE3_MULTICAM_SPATIAL_VULKAN_RENDER';

void main() {
  runApp(const AndroidMulticamSpatialVulkanRenderPhysicalSmokeApp());
}

class AndroidMulticamSpatialVulkanRenderPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidMulticamSpatialVulkanRenderPhysicalSmokeApp({super.key});

  @override
  State<AndroidMulticamSpatialVulkanRenderPhysicalSmokeApp> createState() =>
      _AndroidMulticamSpatialVulkanRenderPhysicalSmokeAppState();
}

class _AndroidMulticamSpatialVulkanRenderPhysicalSmokeAppState
    extends State<AndroidMulticamSpatialVulkanRenderPhysicalSmokeApp> {
  String _status =
      'Initializing VulkanMultiCamSpatialCompositor Render Physical Smoke...';

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
    VGMultiCamSpatialVulkanRenderSmokeReport? report;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;

    try {
      report =
          await VGMultiCamSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamSpatialVulkanRenderSmoke(
            timeout: const Duration(seconds: 30),
          ).timeout(const Duration(seconds: 40));

      lane1Pass =
          report.pass == true &&
          report.vulkanSetupPass &&
          report.syntheticImportPass;
      print(
        '${_logPrefix}_LANE_1: pass=$lane1Pass reportPass=${report.pass} '
        'status=${report.status} vulkanSetupOk=${report.vulkanSetupPass} '
        'syntheticImportOk=${report.syntheticImportPass} '
        'deviceName=${report.details['deviceName']} '
        'apiVersion=${report.details['apiVersion']} '
        'driverVersion=${report.details['driverVersion']} '
        'vulkanUnsupported=${report.details['vulkanUnsupported']} '
        'shaderSource=${report.details['shaderSource']} '
        'drawModel=${report.details['drawModel']} '
        'failureReason=${report.failureReason}',
      );

      lane2Pass = report.paramValidationPass;
      print(
        '${_logPrefix}_LANE_2: pass=$lane2Pass paramValidationPass=${report.paramValidationPass} '
        'invalidArgumentRejectedOk=${report.invalidArgumentRejectedPass} '
        'invalidRectRejectedOk=${report.invalidRectRejectedPass} '
        'invalidArgumentError=${report.details['invalidArgumentError']} '
        'invalidRectError=${report.details['invalidRectError']} '
        'noVulkanObjectsAfterValidation=${report.details['noVulkanObjectsAfterValidation']}',
      );

      lane3Pass = report.spatialLayoutPass;
      print(
        '${_logPrefix}_LANE_3: pass=$lane3Pass spatialLayoutPass=${report.spatialLayoutPass} '
        'topBottomSplitOk=${report.topBottomSplitPass} '
        'leftRightSplitOk=${report.leftRightSplitPass} '
        'pipTopLeftOk=${report.pipTopLeftPass} '
        'pipFreeFloatingOk=${report.pipFreeFloatingPass} '
        'partialCoverageSentinelOk=${report.partialCoverageSentinelPass} '
        'topBottomSplitExpectedPrimary=${report.details['topBottomSplitExpectedPrimaryRectPx']} '
        'topBottomSplitChecksum=${report.details['topBottomSplitChecksum']} '
        'leftRightSplitChecksum=${report.details['leftRightSplitChecksum']} '
        'pipTopLeftChecksum=${report.details['pipTopLeftChecksum']} '
        'pipFreeFloatingChecksum=${report.details['pipFreeFloatingChecksum']} '
        'partialCoverageChecksum=${report.details['partialCoverageChecksum']}',
      );

      lane4Pass = report.resourceLifecyclePass;
      print(
        '${_logPrefix}_LANE_4: pass=$lane4Pass resourceLifecyclePass=${report.resourceLifecyclePass} '
        'helperResourcesReleasedOk=${report.helperResourcesReleasedPass} '
        'diagnosticTeardownOk=${report.diagnosticTeardownPass} '
        'helperTemporaryObjectsCreated=${report.details['helperTemporaryObjectsCreated']} '
        'helperTemporaryObjectsReleased=${report.details['helperTemporaryObjectsReleased']} '
        'teardownWaitIdleOk=${report.details['teardownWaitIdleOk']} '
        'teardownHandlesNull=${report.details['teardownHandlesNull']} '
        'readbackMemoryCoherent=${report.details['readbackMemoryCoherent']}',
      );

      final map = report.toMap();
      final roundTrip = VGMultiCamSpatialVulkanRenderSmokeReport.fromMap(map);
      final mapMatches = roundTrip == report;
      lane5Pass =
          report.isVerifiedPass &&
          report.allNativeLanesPass == report.nativeAllLanesPass &&
          report.hasPassMarker &&
          report.hasCanonicalProofBoundary &&
          mapMatches;
      print(
        '${_logPrefix}_LANE_5: pass=$lane5Pass isVerifiedPass=${report.isVerifiedPass} '
        'allNativeLanesPass=${report.allNativeLanesPass} '
        'nativeAllLanesPass=${report.nativeAllLanesPass} '
        'marker=${report.marker} '
        'proofBoundary=${report.proofBoundary} mapMatches=$mapMatches',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Vulkan spatial render smoke exceeded timeout: $te';
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
          topLevelError == null;

      final payload = <String, dynamic>{
        'unit': 'AndroidMulticamSpatialVulkanRenderSmokeHarness',
        'slice': 'P3-MULTICAM-SPATIAL-VULKAN-RENDER',
        'target':
            VGMultiCamSpatialVulkanRenderSmokeReport.proofBoundaryConstant,
        'pass': allPass,
        'marker': allPass ? _passMarker : _failMarker,
        'lanes': <String, dynamic>{
          'lane1_setupAndSyntheticImport': {
            'pass': lane1Pass,
            'reportPass': report?.pass,
            'status': report?.status,
            'vulkanSetupPass': report?.vulkanSetupPass,
            'syntheticImportPass': report?.syntheticImportPass,
          },
          'lane2_paramValidation': {
            'pass': lane2Pass,
            'paramValidationPass': report?.paramValidationPass,
            'invalidArgumentRejectedPass': report?.invalidArgumentRejectedPass,
            'invalidRectRejectedPass': report?.invalidRectRejectedPass,
          },
          'lane3_spatialLayouts': {
            'pass': lane3Pass,
            'spatialLayoutPass': report?.spatialLayoutPass,
            'topBottomSplitPass': report?.topBottomSplitPass,
            'leftRightSplitPass': report?.leftRightSplitPass,
            'pipTopLeftPass': report?.pipTopLeftPass,
            'pipFreeFloatingPass': report?.pipFreeFloatingPass,
            'partialCoverageSentinelPass': report?.partialCoverageSentinelPass,
          },
          'lane4_resourceLifecycle': {
            'pass': lane4Pass,
            'resourceLifecyclePass': report?.resourceLifecyclePass,
            'helperResourcesReleasedPass': report?.helperResourcesReleasedPass,
            'diagnosticTeardownPass': report?.diagnosticTeardownPass,
          },
          'lane5_telemetry': {
            'pass': lane5Pass,
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
