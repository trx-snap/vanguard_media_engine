// android_multicam_dynamic_descriptor_spatial_vulkan_render_physical_smoke.dart
// Vanguard Media Engine - P3-MULTICAM-NODE-VULKAN-DYNAMIC-DESCRIPTOR-SPATIAL-RENDER:
// Android True-DAG Dart layout descriptor -> native Vulkan spatial render
// diagnostic smoke physical harness.
//
// Proof lanes -- each is its own caller-driven MethodChannel invocation,
// proving Dart descriptor primitives (not native-hardcoded values) drive
// the render:
//   Lane 1: a VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip()
//           descriptor's report isVerifiedPass == true (descriptor
//           resolved, temporary Vulkan instance/device + synthetic sampled
//           images created, layout converted, red-primary/blue-secondary
//           rendered and read back, helper resources released, diagnostic
//           torn down).
//   Lane 2: a VGMultiCamDynamicDescriptorSpatialRenderInput.leftRightSplit()
//           descriptor's report isVerifiedPass == true.
//   Lane 3: a deliberately malformed (`layoutMode: "unknownLayoutMode"`) raw
//           descriptor map's report isVerifiedDescriptorRejection == true --
//           rejected before VulkanScratch::Setup() or any other Vulkan
//           object/resource creation.
//   Lane 4: all three reports' canonical PASS/FAIL markers, canonical proof
//           boundary, and toMap() round-trips agree with the above.
//
// Target / proof boundary:
//   native_multicam_dynamic_descriptor_spatial_vulkan_render_readback_only_no_gles_no_camera_no_oes_no_ahb_no_opacity_no_corner_radius_no_recording_no_product
//   Native temporary VkDevice + synthetic RGBA8 sampled images + private
//   Vulkan spatial helper (existing AOT passthrough SPIR-V, no new shaders) +
//   offscreen attachment readback only, driven by caller-supplied Dart layout
//   descriptor primitives strictly resolved via ComputeMultiCamLayout(). No
//   Camera2, no GLES, no OES/AHardwareBuffer import, no opacity, no corner
//   radius, no recording, no export, no production VulkanBackend mutation,
//   and no app/editor UI. A device without a usable Vulkan driver reports
//   UNSUPPORTED (FAIL marker, no crash).

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _passMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_VULKAN_RENDER_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_VULKAN_RENDER_FAIL';
const String _logPrefix =
    'ANDROID_DAG_PHASE3_MULTICAM_DYNAMIC_DESCRIPTOR_SPATIAL_VULKAN_RENDER';

/// Deliberately malformed descriptor map (unrecognized `layoutMode`) used
/// only to exercise the native fail-closed rejection path. The typed
/// [VGMultiCamDynamicDescriptorSpatialRenderInput] model cannot represent
/// this shape -- its `layoutMode` is a real enum -- so this raw map is sent
/// via the diagnostic-only
/// `runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmokeWithRawDescriptor`
/// escape route instead of widening the public descriptor model.
const Map<String, Object?> _malformedUnknownLayoutModeDescriptor =
    <String, Object?>{
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

void main() {
  runApp(
    const AndroidMulticamDynamicDescriptorSpatialVulkanRenderPhysicalSmokeApp(),
  );
}

class AndroidMulticamDynamicDescriptorSpatialVulkanRenderPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidMulticamDynamicDescriptorSpatialVulkanRenderPhysicalSmokeApp({
    super.key,
  });

  @override
  State<AndroidMulticamDynamicDescriptorSpatialVulkanRenderPhysicalSmokeApp>
  createState() =>
      _AndroidMulticamDynamicDescriptorSpatialVulkanRenderPhysicalSmokeAppState();
}

class _AndroidMulticamDynamicDescriptorSpatialVulkanRenderPhysicalSmokeAppState
    extends
        State<
          AndroidMulticamDynamicDescriptorSpatialVulkanRenderPhysicalSmokeApp
        > {
  String _status =
      'Initializing MultiCam Dynamic-Descriptor Spatial Vulkan Render Physical Smoke...';

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
    VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport?
    freeFloatingReport;
    VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport? leftRightReport;
    VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport? malformedReport;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;

    try {
      freeFloatingReport =
          await VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
            descriptor:
                VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
            timeout: const Duration(seconds: 30),
          ).timeout(const Duration(seconds: 40));

      lane1Pass = freeFloatingReport.isVerifiedPass;
      print(
        '${_logPrefix}_LANE_1: pass=$lane1Pass reportPass=${freeFloatingReport.pass} '
        'status=${freeFloatingReport.status} '
        'descriptorParseOk=${freeFloatingReport.descriptorParseOk} '
        'vulkanSetupOk=${freeFloatingReport.vulkanSetupPass} '
        'syntheticImportOk=${freeFloatingReport.syntheticImportPass} '
        'layoutConvertOk=${freeFloatingReport.layoutConvertPass} '
        'renderReadbackOk=${freeFloatingReport.renderReadbackPass} '
        'helperResourcesReleasedOk=${freeFloatingReport.helperResourcesReleasedOk} '
        'diagnosticTeardownOk=${freeFloatingReport.diagnosticTeardownOk} '
        'layoutModeResolved=${freeFloatingReport.layoutModeResolved} '
        'pipAnchorResolved=${freeFloatingReport.pipAnchorResolved} '
        'deviceName=${freeFloatingReport.details['deviceName']} '
        'apiVersion=${freeFloatingReport.details['apiVersion']} '
        'vulkanUnsupported=${freeFloatingReport.details['vulkanUnsupported']} '
        'failureReason=${freeFloatingReport.failureReason}',
      );

      leftRightReport =
          await VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmoke(
            descriptor:
                VGMultiCamDynamicDescriptorSpatialRenderInput.leftRightSplit(),
            timeout: const Duration(seconds: 30),
          ).timeout(const Duration(seconds: 40));

      lane2Pass = leftRightReport.isVerifiedPass;
      print(
        '${_logPrefix}_LANE_2: pass=$lane2Pass reportPass=${leftRightReport.pass} '
        'status=${leftRightReport.status} '
        'descriptorParseOk=${leftRightReport.descriptorParseOk} '
        'layoutModeResolved=${leftRightReport.layoutModeResolved} '
        'splitDirectionResolved=${leftRightReport.splitDirectionResolved} '
        'renderReadbackOk=${leftRightReport.renderReadbackPass} '
        'helperResourcesReleasedOk=${leftRightReport.helperResourcesReleasedOk} '
        'diagnosticTeardownOk=${leftRightReport.diagnosticTeardownOk} '
        'failureReason=${leftRightReport.failureReason}',
      );

      malformedReport =
          await VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.runAndroidDagPhase3MultiCamDynamicDescriptorSpatialVulkanRenderSmokeWithRawDescriptor(
            _malformedUnknownLayoutModeDescriptor,
            timeout: const Duration(seconds: 30),
          ).timeout(const Duration(seconds: 40));

      lane3Pass = malformedReport.isVerifiedDescriptorRejection;
      print(
        '${_logPrefix}_LANE_3: pass=$lane3Pass reportPass=${malformedReport.pass} '
        'status=${malformedReport.status} '
        'descriptorParseOk=${malformedReport.descriptorParseOk} '
        'descriptorRejectedBeforeVulkanOk=${malformedReport.descriptorRejectedBeforeVulkanOk} '
        'rejectionReason=${malformedReport.rejectionReason} '
        'vulkanSetupOk=${malformedReport.vulkanSetupPass} '
        'failureReason=${malformedReport.failureReason}',
      );

      final reports = [freeFloatingReport, leftRightReport, malformedReport];
      final mapMatches = reports.every((r) {
        final roundTrip =
            VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport.fromMap(
              r.toMap(),
            );
        return roundTrip == r;
      });
      lane4Pass =
          freeFloatingReport.hasPassMarker &&
          freeFloatingReport.hasCanonicalProofBoundary &&
          leftRightReport.hasPassMarker &&
          leftRightReport.hasCanonicalProofBoundary &&
          malformedReport.hasFailMarker &&
          malformedReport.hasCanonicalProofBoundary &&
          mapMatches;
      print(
        '${_logPrefix}_LANE_4: pass=$lane4Pass '
        'freeFloatingMarker=${freeFloatingReport.marker} '
        'leftRightMarker=${leftRightReport.marker} '
        'malformedMarker=${malformedReport.marker} '
        'mapMatches=$mapMatches',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: dynamic-descriptor Vulkan spatial render smoke exceeded timeout: $te';
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
          topLevelError == null;

      final payload = <String, dynamic>{
        'unit':
            'AndroidMulticamDynamicDescriptorSpatialVulkanRenderSmokeHarness',
        'slice': 'P3-MULTICAM-NODE-VULKAN-DYNAMIC-DESCRIPTOR-SPATIAL-RENDER',
        'target': VGMultiCamDynamicDescriptorSpatialVulkanRenderSmokeReport
            .proofBoundaryConstant,
        'pass': allPass,
        'marker': allPass ? _passMarker : _failMarker,
        'lanes': <String, dynamic>{
          'lane1_freeFloatingPip': {
            'pass': lane1Pass,
            'isVerifiedPass': freeFloatingReport?.isVerifiedPass,
            'reportPass': freeFloatingReport?.pass,
            'status': freeFloatingReport?.status,
          },
          'lane2_leftRightSplit': {
            'pass': lane2Pass,
            'isVerifiedPass': leftRightReport?.isVerifiedPass,
            'reportPass': leftRightReport?.pass,
            'status': leftRightReport?.status,
          },
          'lane3_malformedRejection': {
            'pass': lane3Pass,
            'isVerifiedDescriptorRejection':
                malformedReport?.isVerifiedDescriptorRejection,
            'descriptorRejectedBeforeVulkanOk':
                malformedReport?.descriptorRejectedBeforeVulkanOk,
            'status': malformedReport?.status,
          },
          'lane4_telemetry': {
            'pass': lane4Pass,
            'freeFloatingMarker': freeFloatingReport?.marker,
            'leftRightMarker': leftRightReport?.marker,
            'malformedMarker': malformedReport?.marker,
          },
        },
        'freeFloatingReport': freeFloatingReport?.toMap(),
        'leftRightReport': leftRightReport?.toMap(),
        'malformedReport': malformedReport?.toMap(),
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
