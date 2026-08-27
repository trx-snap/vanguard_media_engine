// android_camera2_readiness_plan_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit C: Android Camera2 Readiness & Fallback
// Planner Physical Smoke Harness.
//
// Proof lanes:
//   Lane 1: Probe returns report.success == true and report.cameraCount >= 1.
//   Lane 2: hasCameraPermission == false (non-prompting capability probe).
//   Lane 3: thermalStatusName is non-blocked (none/light/moderate, thermalStatus < 3).
//   Lane 4: supportsConcurrentCamera is false on current SM-A566B test target.
//   Lane 5: Planner evaluation runs synchronously without error and produces a valid plan.
//   Lane 6: plan.decision == VGCamera2ReadinessDecision.singleCameraOnly.
//   Lane 7: plan.isSingleCameraOnly is true, isDualCameraCandidate is false, isBlocked is false.
//   Lane 8: plan.reasons contains 'camera_permission_absent'.
//   Lane 9: plan.reasons contains 'no_matching_concurrent_camera_set' (or 'no_secondary_camera').
//   Lane 10: plan.selectedPrimaryCameraId is non-null and matches a detected camera (prefers back).
//   Lane 11: plan.selectedPreviewSize is non-null with width > 0, height > 0 (matches primary first size).
//   Lane 12: plan.selectedVideoSize is non-null with width > 0, height > 0 (matches primary first size).
//   Lane 13: plan.selectedFpsRange is non-null with lower > 0, upper >= lower (highest upper/lower).
//   Lane 14: plan.diagnostics contains valid fields consistent with probe report.
//   Lane 15: plan.toMap() produces valid structure matching all fields.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2ReadinessPlanPhysicalSmokeApp());
}

class AndroidCamera2ReadinessPlanPhysicalSmokeApp extends StatefulWidget {
  const AndroidCamera2ReadinessPlanPhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2ReadinessPlanPhysicalSmokeApp> createState() =>
      _AndroidCamera2ReadinessPlanPhysicalSmokeAppState();
}

class _AndroidCamera2ReadinessPlanPhysicalSmokeAppState
    extends State<AndroidCamera2ReadinessPlanPhysicalSmokeApp> {
  String _status = 'Initializing Camera2 Readiness Plan Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  static const Set<String> _severeThermalNames = {
    'severe',
    'critical',
    'emergency',
    'shutdown',
  };

  Future<void> _runSmoke() async {
    print('ANDROID_CAMERA_PHASE3_UNIT_C_READINESS_PLAN_SMOKE_START');
    String? topLevelError;
    VGCameraHardwareCapabilityReport? report;
    VGCamera2ReadinessPlan? plan;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    var lane7Pass = false;
    var lane8Pass = false;
    var lane9Pass = false;
    var lane10Pass = false;
    var lane11Pass = false;
    var lane12Pass = false;
    var lane13Pass = false;
    var lane14Pass = false;
    var lane15Pass = false;

    try {
      // 1. Invoke public probe API (diagnostic only, non-prompting, no camera opened)
      report =
          await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities()
              .timeout(const Duration(seconds: 15));

      // Lane 1: Probe returns success == true and cameraCount >= 1
      lane1Pass =
          report.success == true &&
          report.cameraCount >= 1 &&
          report.cameras.isNotEmpty;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_SMOKE_LANE_1: pass=$lane1Pass success=${report.success} cameraCount=${report.cameraCount}',
      );

      // Lane 2: hasCameraPermission == false (non-prompting probe)
      lane2Pass = report.hasCameraPermission == false;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_SMOKE_LANE_2: pass=$lane2Pass hasCameraPermission=${report.hasCameraPermission}',
      );

      // Lane 3: thermalStatusName is non-blocked (none/light/moderate/unavailable, thermalStatus < 3)
      final isThermalBlocked =
          _severeThermalNames.contains(report.thermalStatusName) ||
          (report.thermalStatus != null && report.thermalStatus! >= 3);
      lane3Pass = !isThermalBlocked;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_SMOKE_LANE_3: pass=$lane3Pass thermalStatusName=${report.thermalStatusName} thermalStatus=${report.thermalStatus}',
      );

      // Lane 4: supportsConcurrentCamera is false on current physical device target
      lane4Pass = report.supportsConcurrentCamera == false;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_SMOKE_LANE_4: pass=$lane4Pass supportsConcurrentCamera=${report.supportsConcurrentCamera}',
      );

      // 2. Invoke pure Dart readiness planner on probed capability report
      const planner = VGCamera2ReadinessPlanner();
      final evaluatedPlan = planner.evaluate(report);
      plan = evaluatedPlan;

      // Lane 5: Planner evaluation runs synchronously without error and produces a valid plan
      lane5Pass = VGCamera2ReadinessDecision.values.contains(
        evaluatedPlan.decision,
      );
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_SMOKE_LANE_5: pass=$lane5Pass decision=${evaluatedPlan.decision.name}',
      );

      // Lane 6: plan.decision == VGCamera2ReadinessDecision.singleCameraOnly
      lane6Pass =
          evaluatedPlan.decision == VGCamera2ReadinessDecision.singleCameraOnly;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_SMOKE_LANE_6: pass=$lane6Pass decision=${evaluatedPlan.decision.name}',
      );

      // Lane 7: plan.isSingleCameraOnly is true, isDualCameraCandidate is false, isBlocked is false
      lane7Pass =
          evaluatedPlan.isSingleCameraOnly &&
          !evaluatedPlan.isDualCameraCandidate &&
          !evaluatedPlan.isBlocked;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_SMOKE_LANE_7: pass=$lane7Pass isSingle=${evaluatedPlan.isSingleCameraOnly} isDual=${evaluatedPlan.isDualCameraCandidate} isBlocked=${evaluatedPlan.isBlocked}',
      );

      // Lane 8: plan.reasons contains 'camera_permission_absent'
      lane8Pass = evaluatedPlan.reasons.contains('camera_permission_absent');
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_SMOKE_LANE_8: pass=$lane8Pass reasons=${evaluatedPlan.reasons}',
      );

      // Lane 9: plan.reasons contains 'no_matching_concurrent_camera_set' (or 'no_secondary_camera' if single camera)
      lane9Pass =
          evaluatedPlan.reasons.contains('no_matching_concurrent_camera_set') ||
          evaluatedPlan.reasons.contains('no_secondary_camera');
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_SMOKE_LANE_9: pass=$lane9Pass reasons=${evaluatedPlan.reasons}',
      );

      // Lane 10: plan.selectedPrimaryCameraId is non-null and matches a detected camera (prefers back)
      final primaryCam = report.cameras
          .where((c) => c.cameraId == evaluatedPlan.selectedPrimaryCameraId)
          .firstOrNull;
      lane10Pass =
          evaluatedPlan.selectedPrimaryCameraId != null &&
          primaryCam != null &&
          (primaryCam.lensFacing == 'back' ||
              report.cameras.every((c) => c.lensFacing != 'back'));
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_SMOKE_LANE_10: pass=$lane10Pass selectedPrimaryCameraId=${evaluatedPlan.selectedPrimaryCameraId} primaryLensFacing=${primaryCam?.lensFacing}',
      );

      // Lane 11: plan.selectedPreviewSize is non-null with width > 0, height > 0 (matches primary first size)
      final expectedPreview = primaryCam?.previewSizes.firstOrNull;
      lane11Pass =
          evaluatedPlan.selectedPreviewSize != null &&
          evaluatedPlan.selectedPreviewSize!.width > 0 &&
          evaluatedPlan.selectedPreviewSize!.height > 0 &&
          evaluatedPlan.selectedPreviewSize == expectedPreview;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_SMOKE_LANE_11: pass=$lane11Pass selectedPreviewSize=${evaluatedPlan.selectedPreviewSize} expected=$expectedPreview',
      );

      // Lane 12: plan.selectedVideoSize is non-null with width > 0, height > 0 (matches primary first size)
      final expectedVideo = primaryCam?.videoSizes.firstOrNull;
      lane12Pass =
          evaluatedPlan.selectedVideoSize != null &&
          evaluatedPlan.selectedVideoSize!.width > 0 &&
          evaluatedPlan.selectedVideoSize!.height > 0 &&
          evaluatedPlan.selectedVideoSize == expectedVideo;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_SMOKE_LANE_12: pass=$lane12Pass selectedVideoSize=${evaluatedPlan.selectedVideoSize} expected=$expectedVideo',
      );

      // Lane 13: plan.selectedFpsRange is non-null with lower > 0, upper >= lower (highest upper/lower)
      lane13Pass =
          evaluatedPlan.selectedFpsRange != null &&
          evaluatedPlan.selectedFpsRange!.lower > 0 &&
          evaluatedPlan.selectedFpsRange!.upper >=
              evaluatedPlan.selectedFpsRange!.lower;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_SMOKE_LANE_13: pass=$lane13Pass selectedFpsRange=${evaluatedPlan.selectedFpsRange}',
      );

      // Lane 14: plan.diagnostics contains valid fields consistent with probe report
      final diag = evaluatedPlan.diagnostics;
      lane14Pass =
          diag['cameraCount'] == report.cameraCount &&
          diag['supportsConcurrentCamera'] == report.supportsConcurrentCamera &&
          diag['hasCameraPermission'] == report.hasCameraPermission &&
          diag['thermalStatusName'] == report.thermalStatusName &&
          diag['primaryLensFacing'] == primaryCam?.lensFacing;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_SMOKE_LANE_14: pass=$lane14Pass diagnostics=$diag',
      );

      // Lane 15: plan.toMap() produces valid structure matching all fields
      final map = evaluatedPlan.toMap();
      lane15Pass =
          map['decision'] == evaluatedPlan.decision.name &&
          map['reasons'] is List &&
          map['diagnostics'] is Map &&
          map['selectedPrimaryCameraId'] ==
              evaluatedPlan.selectedPrimaryCameraId &&
          map['selectedPreviewSize'] != null &&
          map['selectedVideoSize'] != null &&
          map['selectedFpsRange'] != null;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_SMOKE_LANE_15: pass=$lane15Pass mapDecision=${map['decision']}',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Readiness plan smoke exceeded 15 seconds: $te';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_READINESS_PLAN_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_READINESS_PLAN_SMOKE_ERROR: $topLevelError',
      );
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
          lane9Pass &&
          lane10Pass &&
          lane11Pass &&
          lane12Pass &&
          lane13Pass &&
          lane14Pass &&
          lane15Pass &&
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2ReadinessPlan',
        'slice': 'Phase 3-Unit C',
        'target': 'android_physical',
        'pass': allPass,
        'lanes': <String, dynamic>{
          'lane1_probeSuccessAndCameraCountGte1': {
            'pass': lane1Pass,
            'success': report?.success,
            'cameraCount': report?.cameraCount,
          },
          'lane2_hasCameraPermissionFalse': {
            'pass': lane2Pass,
            'hasCameraPermission': report?.hasCameraPermission,
          },
          'lane3_thermalStatusNominal': {
            'pass': lane3Pass,
            'thermalStatusName': report?.thermalStatusName,
            'thermalStatus': report?.thermalStatus,
          },
          'lane4_supportsConcurrentCameraFalse': {
            'pass': lane4Pass,
            'supportsConcurrentCamera': report?.supportsConcurrentCamera,
          },
          'lane5_plannerEvaluationSuccess': {
            'pass': lane5Pass,
            'decision': plan?.decision.name,
          },
          'lane6_decisionSingleCameraOnly': {
            'pass': lane6Pass,
            'decision': plan?.decision.name,
          },
          'lane7_decisionConvenienceGetters': {
            'pass': lane7Pass,
            'isSingleCameraOnly': plan?.isSingleCameraOnly,
            'isDualCameraCandidate': plan?.isDualCameraCandidate,
            'isBlocked': plan?.isBlocked,
          },
          'lane8_reasonPermissionAbsent': {
            'pass': lane8Pass,
            'reasons': plan?.reasons,
          },
          'lane9_reasonNoMatchingConcurrentSet': {
            'pass': lane9Pass,
            'reasons': plan?.reasons,
          },
          'lane10_selectedPrimaryCamera': {
            'pass': lane10Pass,
            'selectedPrimaryCameraId': plan?.selectedPrimaryCameraId,
          },
          'lane11_selectedPreviewSize': {
            'pass': lane11Pass,
            'selectedPreviewSize': plan?.selectedPreviewSize?.toMap(),
          },
          'lane12_selectedVideoSize': {
            'pass': lane12Pass,
            'selectedVideoSize': plan?.selectedVideoSize?.toMap(),
          },
          'lane13_selectedFpsRange': {
            'pass': lane13Pass,
            'selectedFpsRange': plan?.selectedFpsRange?.toMap(),
          },
          'lane14_diagnosticsIntegrity': {
            'pass': lane14Pass,
            'diagnostics': plan?.diagnostics,
          },
          'lane15_toMapSerialization': {'pass': lane15Pass},
        },
        'report': ?report?.toMap(),
        'plan': ?plan?.toMap(),
        'error': ?topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_C_READINESS_PLAN_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_C_READINESS_PLAN_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_C_READINESS_PLAN_PHYSICAL_FAIL',
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
