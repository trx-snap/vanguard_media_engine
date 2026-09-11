// android_duet_vulkan_pixel_proof_physical_smoke.dart
// Vanguard Media Engine — DUET-VULKAN-GREENSCREEN-PIXEL-PROOF: Android
// VulkanGreenScreenCompositor synthetic mask-blend pixel proof diagnostic
// smoke physical harness.
//
// Proof lanes:
//   Lane 1: smoke report pass == true and vulkanCoreReadyPass == true (the
//           temporary VkInstance/VkDevice/VkQueue/VkCommandPool were created,
//           or the device honestly reported UNSUPPORTED).
//   Lane 2: smoke report uploadPass == true (synthetic background/foreground
//           RGBA8_UNORM images and the R8_UNORM mask image, offscreen
//           attachment, and readback buffer were created and uploaded).
//   Lane 3: smoke report parityPass == true (maskResolutionMismatchOk: the
//           17x19 mask resolution differs from the 64x48 output resolution
//           and the blend still matched everywhere; cpuReferenceParityOk:
//           zero mismatches against the pure CPU reference).
//   Lane 4: smoke report alphaPass == true (alphaZeroPreservesBackgroundOk:
//           mask alpha 0 reproduces the background exactly;
//           alphaFullForegroundOk: mask alpha 255 reproduces the foreground
//           exactly; alphaFractionalBlendOk: fractional mask alpha values
//           are a true blend matching the CPU reference).
//   Lane 5: smoke report contractPass == true (colorContractPinnedOk: pinned
//           RGBA8_UNORM/R8_UNORM format constants and tolerance, plus the
//           helper's fail-closed input validation rejecting every bad
//           target/image/mask-size case before creating any Vulkan object).
//   Lane 6: smoke report capabilityPass == true (capabilityFallbackReportedOk:
//           device capability facts honestly reported, or a non-empty
//           fallback reason on UNSUPPORTED).
//   Lane 7: smoke report resourceLifecyclePass == true (cleanupOk: helper
//           temporary object created == released, diagnostic teardown with
//           device wait idle and all handles nulled).
//   Lane 8: smoke report isPass == true && allNativeLanesPass ==
//           nativeAllLanesPass && canonical && canonical PASS marker &&
//           canonical proof boundary && output/mask sizes differ (details
//           outputWidth/outputHeight != maskWidth/maskHeight) && toMap()
//           round-trips.
//
// Target / proof boundary:
//   native_vulkan_duet_greenscreen_mask_blend_pixel_proof_synthetic_only_no_camera_no_decode_no_export_no_product
//   Native temporary VkInstance/VkDevice/VkQueue/VkCommandPool + synthetic
//   sampled images + offscreen color attachment + host readback buffer +
//   private VulkanGreenScreenCompositor helper. No camera, no decode, no
//   export session, no production VulkanBackend mutation, and no production
//   Duet preview/export route. A device without a usable Vulkan driver
//   reports status `UNSUPPORTED`.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vg_duet_vulkan_pixel_proof_smoke.dart';

const String _passMarker = 'ANDROID_DUET_VULKAN_PIXEL_PROOF_PHYSICAL_PASS';
const String _failMarker = 'ANDROID_DUET_VULKAN_PIXEL_PROOF_PHYSICAL_FAIL';
const String _logPrefix = 'ANDROID_DUET_VULKAN_PIXEL_PROOF';

void main() {
  runApp(const AndroidDuetVulkanPixelProofPhysicalSmokeApp());
}

class AndroidDuetVulkanPixelProofPhysicalSmokeApp extends StatefulWidget {
  const AndroidDuetVulkanPixelProofPhysicalSmokeApp({super.key});

  @override
  State<AndroidDuetVulkanPixelProofPhysicalSmokeApp> createState() =>
      _AndroidDuetVulkanPixelProofPhysicalSmokeAppState();
}

class _AndroidDuetVulkanPixelProofPhysicalSmokeAppState
    extends State<AndroidDuetVulkanPixelProofPhysicalSmokeApp> {
  String _status = 'Initializing VulkanGreenScreenCompositor Pixel Proof…';

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
    VGDuetVulkanPixelProofSmokeReport? report;

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
          await VGDuetVulkanPixelProofSmokeReport.runAndroidDuetVulkanPixelProofSmoke(
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

      lane1Pass = report.pass == true && report.vulkanCoreReadyPass;
      print(
        '${_logPrefix}_LANE_1: pass=$lane1Pass reportPass=${report.pass} '
        'status=${report.status} vulkanCoreReadyOk=${report.vulkanCoreReadyPass} '
        'failureReason=${report.failureReason} '
        'deviceName=${report.details['deviceName']} '
        'deviceType=${report.details['deviceType']} '
        'apiVersion=${report.details['apiVersion']} '
        'driverVersion=${report.details['driverVersion']} '
        'queueFamilyIndex=${report.details['queueFamilyIndex']}',
      );

      lane2Pass = report.uploadPass;
      print(
        '${_logPrefix}_LANE_2: pass=$lane2Pass uploadPass=$lane2Pass '
        'maskUploadOk=${report.maskUploadPass} '
        'syntheticResourcesOk=${report.details['syntheticResourcesOk']} '
        'readbackMemoryCoherent=${report.details['readbackMemoryCoherent']}',
      );

      lane3Pass = report.parityPass;
      print(
        '${_logPrefix}_LANE_3: pass=$lane3Pass parityPass=$lane3Pass '
        'maskResolutionMismatchOk=${report.maskResolutionMismatchPass} '
        'cpuReferenceParityOk=${report.cpuReferenceParityPass} '
        'outputWidth=${report.details['outputWidth']} '
        'outputHeight=${report.details['outputHeight']} '
        'maskWidth=${report.details['maskWidth']} '
        'maskHeight=${report.details['maskHeight']} '
        'colorTolerance=${report.details['colorTolerance']} '
        'mismatchCount=${report.details['mismatchCount']} '
        'firstMismatch=${report.details['firstMismatch']}',
      );

      lane4Pass = report.alphaPass;
      print(
        '${_logPrefix}_LANE_4: pass=$lane4Pass alphaPass=$lane4Pass '
        'alphaZeroPreservesBackgroundOk=${report.alphaZeroPreservesBackgroundPass} '
        'alphaFullForegroundOk=${report.alphaFullForegroundPass} '
        'alphaFractionalBlendOk=${report.alphaFractionalBlendPass} '
        'alphaZeroPixelCount=${report.details['alphaZeroPixelCount']} '
        'alphaFullPixelCount=${report.details['alphaFullPixelCount']} '
        'alphaFractionalPixelCount=${report.details['alphaFractionalPixelCount']}',
      );

      lane5Pass = report.contractPass;
      print(
        '${_logPrefix}_LANE_5: pass=$lane5Pass contractPass=$lane5Pass '
        'colorContractPinnedOk=${report.colorContractPinnedPass} '
        'colorContract=${report.details['colorContract']} '
        'blendFormula=${report.details['blendFormula']} '
        'shaderSource=${report.details['shaderSource']} '
        'noVulkanObjectsFromValidation=${report.details['noVulkanObjectsFromValidation']} '
        'lastValidationError=${report.details['lastValidationError']}',
      );

      lane6Pass = report.capabilityPass;
      print(
        '${_logPrefix}_LANE_6: pass=$lane6Pass capabilityPass=$lane6Pass '
        'capabilityFallbackReportedOk=${report.capabilityFallbackReportedPass}',
      );

      lane7Pass = report.resourceLifecyclePass;
      print(
        '${_logPrefix}_LANE_7: pass=$lane7Pass resourceLifecyclePass=$lane7Pass '
        'cleanupOk=${report.cleanupPass} '
        'helperTemporaryObjectsCreated=${report.details['helperTemporaryObjectsCreated']} '
        'helperTemporaryObjectsReleased=${report.details['helperTemporaryObjectsReleased']} '
        'teardownWaitIdleOk=${report.details['teardownWaitIdleOk']} '
        'teardownHandlesNull=${report.details['teardownHandlesNull']}',
      );

      final outputWidth = report.details['outputWidth'];
      final outputHeight = report.details['outputHeight'];
      final maskWidth = report.details['maskWidth'];
      final maskHeight = report.details['maskHeight'];
      final sizesDiffer =
          outputWidth != null &&
          maskWidth != null &&
          outputHeight != null &&
          maskHeight != null &&
          outputWidth != maskWidth &&
          outputHeight != maskHeight;

      final map = report.toMap();
      final roundTrip = VGDuetVulkanPixelProofSmokeReport.fromMap(map);
      final mapMatches = roundTrip == report;
      lane8Pass =
          report.isPass &&
          report.allNativeLanesPass == report.nativeAllLanesPass &&
          report.canonical &&
          report.hasPassMarker &&
          report.hasCanonicalProofBoundary &&
          sizesDiffer &&
          mapMatches;
      print(
        '${_logPrefix}_LANE_8: pass=$lane8Pass isPass=${report.isPass} '
        'allNativeLanesPass=${report.allNativeLanesPass} '
        'nativeAllLanesPass=${report.nativeAllLanesPass} '
        'canonical=${report.canonical} '
        'marker=${report.marker} '
        'proofBoundary=${report.proofBoundary} '
        'sizesDiffer=$sizesDiffer mapMatches=$mapMatches',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Duet Vulkan pixel proof smoke exceeded timeout: $te';
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
        'unit': 'AndroidDuetVulkanPixelProofSmokeHarness',
        'slice': 'DUET-VULKAN-GREENSCREEN-PIXEL-PROOF',
        'target': VGDuetVulkanPixelProofSmokeReport.proofBoundaryConstant,
        'pass': allPass,
        'marker': allPass ? _passMarker : _failMarker,
        'lanes': <String, dynamic>{
          'lane1_setup': {
            'pass': lane1Pass,
            'reportPass': report?.pass,
            'vulkanCoreReadyPass': report?.vulkanCoreReadyPass,
          },
          'lane2_upload': {'pass': lane2Pass, 'uploadPass': report?.uploadPass},
          'lane3_parity': {'pass': lane3Pass, 'parityPass': report?.parityPass},
          'lane4_alpha': {'pass': lane4Pass, 'alphaPass': report?.alphaPass},
          'lane5_contract': {
            'pass': lane5Pass,
            'contractPass': report?.contractPass,
          },
          'lane6_capability': {
            'pass': lane6Pass,
            'capabilityPass': report?.capabilityPass,
          },
          'lane7_lifecycle': {
            'pass': lane7Pass,
            'resourceLifecyclePass': report?.resourceLifecyclePass,
          },
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
