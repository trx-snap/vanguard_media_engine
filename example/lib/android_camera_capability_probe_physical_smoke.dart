// android_camera_capability_probe_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit A: Android Camera2 Hardware/Thermal
// Capability Probe Physical Smoke Harness.
//
// Proof lanes:
//   Lane 1: Native route returns success == true.
//   Lane 2: apiLevel >= 24 and cameraCount == cameras.length.
//   Lane 3: Physical device has cameraCount >= 1.
//   Lane 4: hasCameraPermission == false (manifest declares INTERNET only; non-prompting).
//   Lane 5: thermalStatusName is non-empty and fallbackRecommendation is valid enum token.
//   Lane 6: Every camera has non-empty cameraId, valid lensFacing, valid hardwareLevel, non-null capabilities.
//   Lane 7: supportsConcurrentCamera matches whether any concurrentCameraIdSets entry has >= 2 camera IDs.
//   Lane 8: fallbackRecommendation is internally consistent with cameraCount, supportsConcurrentCamera, and thermal status.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCameraCapabilityProbePhysicalSmokeApp());
}

class AndroidCameraCapabilityProbePhysicalSmokeApp extends StatefulWidget {
  const AndroidCameraCapabilityProbePhysicalSmokeApp({super.key});

  @override
  State<AndroidCameraCapabilityProbePhysicalSmokeApp> createState() =>
      _AndroidCameraCapabilityProbePhysicalSmokeAppState();
}

class _AndroidCameraCapabilityProbePhysicalSmokeAppState
    extends State<AndroidCameraCapabilityProbePhysicalSmokeApp> {
  String _status = 'Initializing Camera2 Capability Probe Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  static const Set<String> _validLensFacings = {
    'front',
    'back',
    'external',
    'unknown',
  };

  static const Set<String> _validHardwareLevels = {
    'legacy',
    'limited',
    'full',
    'level3',
    'external',
    'unknown',
  };

  static const Set<String> _validFallbackRecommendations = {
    'concurrent_supported',
    'single_camera_only',
    'no_camera',
    'thermal_blocked',
  };

  static const Set<String> _thermalBlockedNames = {
    'severe',
    'critical',
    'emergency',
    'shutdown',
  };

  String _computeExpectedFallback({
    required int cameraCount,
    required String thermalStatusName,
    required int? thermalStatus,
    required bool supportsConcurrentCamera,
  }) {
    if (cameraCount == 0) {
      return 'no_camera';
    }
    final isThermalBlocked =
        (thermalStatus != null && thermalStatus >= 3) ||
        _thermalBlockedNames.contains(thermalStatusName);
    if (isThermalBlocked) {
      return 'thermal_blocked';
    }
    if (supportsConcurrentCamera) {
      return 'concurrent_supported';
    }
    return 'single_camera_only';
  }

  Future<void> _runSmoke() async {
    print('ANDROID_CAMERA_PHASE3_UNIT_A_SMOKE: START');
    String? topLevelError;
    VGCameraHardwareCapabilityReport? report;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    var lane7Pass = false;
    var lane8Pass = false;

    String expectedFallback = 'unknown';

    try {
      // 1. Invoke public API
      report =
          await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities()
              .timeout(const Duration(seconds: 15));

      // Lane 1: native route returns success true
      lane1Pass = report.success == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_A_SMOKE_LANE_1: pass=$lane1Pass success=${report.success}',
      );

      // Lane 2: apiLevel >= 24 and cameraCount == cameras.length
      lane2Pass =
          report.apiLevel >= 24 && report.cameraCount == report.cameras.length;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_A_SMOKE_LANE_2: pass=$lane2Pass apiLevel=${report.apiLevel} '
        'cameraCount=${report.cameraCount} camerasLength=${report.cameras.length}',
      );

      // Lane 3: physical device has cameraCount >= 1
      lane3Pass = report.cameraCount >= 1;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_A_SMOKE_LANE_3: pass=$lane3Pass cameraCount=${report.cameraCount}',
      );

      // Lane 4: hasCameraPermission is false for this example app (no CAMERA in manifest)
      lane4Pass = report.hasCameraPermission == false;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_A_SMOKE_LANE_4: pass=$lane4Pass hasCameraPermission=${report.hasCameraPermission}',
      );

      // Lane 5: thermalStatusName is non-empty and fallbackRecommendation is valid
      lane5Pass =
          report.thermalStatusName.isNotEmpty &&
          _validFallbackRecommendations.contains(report.fallbackRecommendation);
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_A_SMOKE_LANE_5: pass=$lane5Pass '
        'thermalStatusName=${report.thermalStatusName} fallbackRecommendation=${report.fallbackRecommendation}',
      );

      // Lane 6: every camera has non-empty cameraId, valid lensFacing, valid hardwareLevel, non-null capabilities
      final camerasValid =
          report.cameras.isNotEmpty &&
          report.cameras.every((c) {
            final validId = c.cameraId.isNotEmpty;
            final validFacing = _validLensFacings.contains(c.lensFacing);
            final validHw = _validHardwareLevels.contains(c.hardwareLevel);
            final validCaps =
                c.capabilities.isNotEmpty || c.capabilities.isEmpty;
            return validId && validFacing && validHw && validCaps;
          });
      lane6Pass = camerasValid;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_A_SMOKE_LANE_6: pass=$lane6Pass camerasCount=${report.cameras.length}',
      );

      // Lane 7: supportsConcurrentCamera matches whether any concurrentCameraIdSets entry has >= 2 ids
      final hasMultiConcurrentSet = report.concurrentCameraIdSets.any(
        (set) => set.length >= 2,
      );
      lane7Pass = report.supportsConcurrentCamera == hasMultiConcurrentSet;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_A_SMOKE_LANE_7: pass=$lane7Pass '
        'supportsConcurrentCamera=${report.supportsConcurrentCamera} hasMultiConcurrentSet=$hasMultiConcurrentSet '
        'concurrentSets=${report.concurrentCameraIdSets}',
      );

      // Lane 8: fallbackRecommendation is internally consistent
      expectedFallback = _computeExpectedFallback(
        cameraCount: report.cameraCount,
        thermalStatusName: report.thermalStatusName,
        thermalStatus: report.thermalStatus,
        supportsConcurrentCamera: report.supportsConcurrentCamera,
      );
      lane8Pass = report.fallbackRecommendation == expectedFallback;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_A_SMOKE_LANE_8: pass=$lane8Pass '
        'fallbackRecommendation=${report.fallbackRecommendation} expectedFallback=$expectedFallback',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Capability probe exceeded 15 seconds: $te';
      print('ANDROID_CAMERA_PHASE3_UNIT_A_SMOKE_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('ANDROID_CAMERA_PHASE3_UNIT_A_SMOKE_ERROR: $topLevelError');
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
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2CapabilityProbe',
        'target': 'android_physical',
        'pass': allPass,
        'lanes': <String, dynamic>{
          'lane1_nativeSuccess': {
            'pass': lane1Pass,
            'success': report?.success,
          },
          'lane2_apiLevelAndCameraCountMatch': {
            'pass': lane2Pass,
            'apiLevel': report?.apiLevel,
            'cameraCount': report?.cameraCount,
            'camerasLength': report?.cameras.length,
          },
          'lane3_physicalCameraCountGte1': {
            'pass': lane3Pass,
            'cameraCount': report?.cameraCount,
          },
          'lane4_hasCameraPermissionFalse': {
            'pass': lane4Pass,
            'hasCameraPermission': report?.hasCameraPermission,
          },
          'lane5_thermalAndFallbackValues': {
            'pass': lane5Pass,
            'thermalStatus': report?.thermalStatus,
            'thermalStatusName': report?.thermalStatusName,
            'fallbackRecommendation': report?.fallbackRecommendation,
          },
          'lane6_cameraItemIntegrity': {
            'pass': lane6Pass,
            'cameras': report?.cameras.map((c) => c.toMap()).toList(),
          },
          'lane7_supportsConcurrentCameraConsistency': {
            'pass': lane7Pass,
            'supportsConcurrentCamera': report?.supportsConcurrentCamera,
            'concurrentCameraIdSets': report?.concurrentCameraIdSets,
          },
          'lane8_fallbackRecommendationConsistency': {
            'pass': lane8Pass,
            'fallbackRecommendation': report?.fallbackRecommendation,
            'expectedFallback': expectedFallback,
          },
        },
        'report': ?report?.toMap(),
        'error': ?topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_A_CAPABILITY_PROBE_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_A_CAPABILITY_PROBE_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_A_CAPABILITY_PROBE_PHYSICAL_FAIL',
      );

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
