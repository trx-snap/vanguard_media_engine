// android_timeline_overlay_vulkan_render_physical_smoke.dart
// Vanguard Media Engine — P5-OVERLAYS-TRANS (sub-slice VULKAN-RENDER):
// Android True-DAG VulkanOverlayCompositor multi-layer shader/raster proof
// diagnostic smoke physical harness.
//
// Proof lanes:
//   Lane 1: smoke report pass == true, vulkanSetupPass == true and
//           paramValidationPass == true (null handles, zero dimensions,
//           non-finite transform parameters, invalid opacity, mixed list
//           fail closed).
//   Lane 2: smoke report transformPass == true (singleLayerTransformPass:
//           translate+scale, 90 deg rotation, 180 deg rotation, off-canvas
//           clipping; arbitraryRotationPass: 45 deg rotation with transparent
//           border clamp).
//   Lane 3: smoke report blendPass == true (opacityBlendPass: uniform
//           opacity, texture alpha, alpha*opacity, zero, opaque Porter-Duff
//           source-over blend; alphaAccumulationPass: destination alpha
//           accumulation over transparent black).
//   Lane 4: smoke report compositePass == true (multiLayerZOrderPass:
//           multi-layer forward order, reversed order, empty-list no-op;
//           existingContentsCompositePass: loadOp LOAD composite over
//           existing attachment contents).
//   Lane 5: smoke report resourceLifecyclePass == true (helper resources
//           released, diagnostic teardown with device wait idle and all
//           handles nulled).
//   Lane 6: smoke report parityPass == true (VulkanOverlayLayerDescriptor
//           layout and pure-math ComputeVulkanOverlayPlacement parity).
//   Lane 7: smoke report isPass == true && allNativeLanesPass ==
//           nativeAllLanesPass && canonical && canonical PASS marker &&
//           canonical proof boundary && toMap() round-trips.
//
// Target / proof boundary:
//   native_vulkan_timeline_overlay_compositor_shader_raster_only_no_decode_no_export_no_product
//   Native temporary VkInstance/VkDevice/VkQueue/VkCommandPool + synthetic
//   sampled images + offscreen color attachment + host readback buffer +
//   private Vulkan overlay helper. No decode, no export session, no
//   keyframe evaluation, no AHardwareBuffer import, no production
//   VulkanBackend mutation, and no product/editor UI. A device without
//   a usable Vulkan driver reports status `UNSUPPORTED`.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_timeline_overlay_vulkan_render_smoke.dart';

const String _passMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_VULKAN_RENDER_PHYSICAL_SMOKE_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_VULKAN_RENDER_PHYSICAL_SMOKE_FAIL';
const String _logPrefix = 'ANDROID_DAG_PHASE5_TIMELINE_OVERLAY_VULKAN_RENDER';

void main() {
  runApp(const AndroidTimelineOverlayVulkanRenderPhysicalSmokeApp());
}

class AndroidTimelineOverlayVulkanRenderPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidTimelineOverlayVulkanRenderPhysicalSmokeApp({super.key});

  @override
  State<AndroidTimelineOverlayVulkanRenderPhysicalSmokeApp> createState() =>
      _AndroidTimelineOverlayVulkanRenderPhysicalSmokeAppState();
}

class _AndroidTimelineOverlayVulkanRenderPhysicalSmokeAppState
    extends State<AndroidTimelineOverlayVulkanRenderPhysicalSmokeApp> {
  String _status =
      'Initializing VulkanOverlayCompositor Render Physical Smoke…';

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
    VGTimelineOverlayVulkanRenderSmokeReport? report;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    var lane7Pass = false;

    try {
      report =
          await VGTimelineOverlayVulkanRenderSmokeReport.runAndroidDagPhase5TimelineOverlayVulkanRenderSmoke(
            timeout: const Duration(seconds: 20),
          ).timeout(const Duration(seconds: 30));

      if (report.isUnsupported) {
        print(
          '${_logPrefix}_UNSUPPORTED: status=${report.status} '
          'failureReason=${report.failureReason} '
          'vulkanUnsupported=${report.details['vulkanUnsupported']} '
          'reason=${report.details['reason']}',
        );
      }

      lane1Pass =
          report.pass == true &&
          report.vulkanSetupPass &&
          report.paramValidationPass;
      print(
        '${_logPrefix}_LANE_1: pass=$lane1Pass reportPass=${report.pass} '
        'status=${report.status} vulkanSetupOk=${report.vulkanSetupPass} '
        'paramValidationPass=${report.paramValidationPass} '
        'invalidImageRejectedOk=${report.invalidImageRejectedPass} '
        'invalidDimensionsRejectedOk=${report.invalidDimensionsRejectedPass} '
        'nonFiniteTransformRejectedOk=${report.nonFiniteTransformRejectedPass} '
        'invalidOpacityRejectedOk=${report.invalidOpacityRejectedPass} '
        'mixedListRejectedBeforeDrawOk=${report.mixedListRejectedBeforeDrawPass} '
        'failureReason=${report.failureReason} '
        'deviceName=${report.details['deviceName']} '
        'deviceType=${report.details['deviceType']} '
        'apiVersion=${report.details['apiVersion']} '
        'driverVersion=${report.details['driverVersion']} '
        'queueFamilyIndex=${report.details['queueFamilyIndex']}',
      );

      lane2Pass = report.transformPass;
      print(
        '${_logPrefix}_LANE_2: pass=$lane2Pass transformPass=${report.transformPass} '
        'singleLayerTransformOk=${report.singleLayerTransformPass} '
        'arbitraryRotationOk=${report.arbitraryRotationPass} '
        'translateScaleChecksum=${report.details['translateScaleChecksum']} '
        'rotate90Checksum=${report.details['rotate90Checksum']} '
        'rotate180Checksum=${report.details['rotate180Checksum']} '
        'offCanvasClipChecksum=${report.details['offCanvasClipChecksum']} '
        'rotate45Checksum=${report.details['rotate45Checksum']} '
        'rotate45InsidePixels=${report.details['rotate45InsidePixels']} '
        'rotate45ProbesOk=${report.details['rotate45ProbesOk']}',
      );

      lane3Pass = report.blendPass;
      print(
        '${_logPrefix}_LANE_3: pass=$lane3Pass blendPass=${report.blendPass} '
        'opacityBlendOk=${report.opacityBlendPass} '
        'alphaAccumulationOk=${report.alphaAccumulationPass} '
        'opacityHalfUniformCenterRgba=${report.details['opacityHalfUniformCenterRgba']} '
        'textureAlphaBlendCenterRgba=${report.details['textureAlphaBlendCenterRgba']} '
        'textureAlphaTimesOpacityCenterRgba=${report.details['textureAlphaTimesOpacityCenterRgba']}',
      );

      lane4Pass = report.compositePass;
      print(
        '${_logPrefix}_LANE_4: pass=$lane4Pass compositePass=${report.compositePass} '
        'multiLayerZOrderOk=${report.multiLayerZOrderPass} '
        'existingContentsCompositeOk=${report.existingContentsCompositePass} '
        'stackForwardChecksum=${report.details['stackForwardChecksum']} '
        'stackReversedChecksum=${report.details['stackReversedChecksum']} '
        'emptyListNoOpOk=${report.details['emptyListNoOpOk']} '
        'existingBaseChecksum=${report.details['existingBaseChecksum']} '
        'existingCompositeChecksum=${report.details['existingCompositeChecksum']}',
      );

      lane5Pass = report.resourceLifecyclePass;
      print(
        '${_logPrefix}_LANE_5: pass=$lane5Pass resourceLifecyclePass=${report.resourceLifecyclePass} '
        'helperResourcesReleasedOk=${report.helperResourcesReleasedPass} '
        'diagnosticTeardownOk=${report.diagnosticTeardownPass} '
        'helperTemporaryObjectsCreated=${report.details['helperTemporaryObjectsCreated']} '
        'helperTemporaryObjectsReleased=${report.details['helperTemporaryObjectsReleased']} '
        'teardownWaitIdleOk=${report.details['teardownWaitIdleOk']} '
        'teardownHandlesNull=${report.details['teardownHandlesNull']}',
      );

      lane6Pass = report.parityPass;
      print(
        '${_logPrefix}_LANE_6: pass=$lane6Pass parityPass=${report.parityPass} '
        'structParityOk=${report.structParityPass} '
        'descriptorFields=${report.details['descriptorFields']} '
        'mirroredDartFields=${report.details['mirroredDartFields']} '
        'glesDescriptorFields=${report.details['glesDescriptorFields']} '
        'descriptorStandardLayout=${report.details['descriptorStandardLayout']} '
        'descriptorSizeBytes=${report.details['descriptorSizeBytes']} '
        'zIndexRole=${report.details['zIndexRole']}',
      );

      final map = report.toMap();
      final roundTrip = VGTimelineOverlayVulkanRenderSmokeReport.fromMap(map);
      final mapMatches = roundTrip == report;
      lane7Pass =
          report.isPass &&
          report.allNativeLanesPass == report.nativeAllLanesPass &&
          report.canonical &&
          report.hasPassMarker &&
          report.hasCanonicalProofBoundary &&
          mapMatches;
      print(
        '${_logPrefix}_LANE_7: pass=$lane7Pass isPass=${report.isPass} '
        'allNativeLanesPass=${report.allNativeLanesPass} '
        'nativeAllLanesPass=${report.nativeAllLanesPass} '
        'canonical=${report.canonical} '
        'marker=${report.marker} '
        'proofBoundary=${report.proofBoundary} mapMatches=$mapMatches',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Vulkan overlay render smoke exceeded timeout: $te';
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
          topLevelError == null;

      final payload = <String, dynamic>{
        'unit': 'AndroidTimelineOverlayVulkanRenderSmokeHarness',
        'slice': 'P5-OVERLAYS-TRANS-VULKAN-RENDER',
        'target':
            VGTimelineOverlayVulkanRenderSmokeReport.proofBoundaryConstant,
        'pass': allPass,
        'marker': allPass ? _passMarker : _failMarker,
        'lanes': <String, dynamic>{
          'lane1_validation': {
            'pass': lane1Pass,
            'reportPass': report?.pass,
            'vulkanSetupPass': report?.vulkanSetupPass,
            'paramValidationPass': report?.paramValidationPass,
          },
          'lane2_transform': {
            'pass': lane2Pass,
            'transformPass': report?.transformPass,
          },
          'lane3_blend': {'pass': lane3Pass, 'blendPass': report?.blendPass},
          'lane4_composite': {
            'pass': lane4Pass,
            'compositePass': report?.compositePass,
          },
          'lane5_lifecycle': {
            'pass': lane5Pass,
            'resourceLifecyclePass': report?.resourceLifecyclePass,
          },
          'lane6_parity': {'pass': lane6Pass, 'parityPass': report?.parityPass},
          'lane7_telemetry': {
            'pass': lane7Pass,
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
          _status = allPass ? 'PASS' : (report?.status ?? 'FAIL');
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
