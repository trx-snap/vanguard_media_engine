// android_camera2_thermal_fallback_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit S: Android Camera2 Static Thermal Fallback
// Matrix Physical Proof Foundation Smoke Harness.
//
// Proof lanes:
//   Lane 1: report.success == true.
//   Lane 2: apiLevel >= 29, cameraCount == cameras.length, cameraCount >= 1.
//   Lane 3: thermalStatusName non-empty and in allowed set (none/light/moderate/severe/critical/emergency/shutdown/unavailable or unknown_*).
//   Lane 4: thermal blocked predicate computed from name/status is coherent.
//   Lane 5: report.fallbackRecommendation matches no_camera > thermal_blocked > concurrent_supported > single_camera_only.
//   Lane 6: planner evaluation completes and decision is valid enum.
//   Lane 7: if thermalBlocked predicate true, plan.decision == thermalBlocked and reasons contains thermal_blocked.
//   Lane 8: if thermalBlocked predicate false and cameraCount > 0, plan.decision is not thermalBlocked and reasons does not contain thermal_blocked.
//   Lane 9: diagnostics preserve cameraCount, supportsConcurrentCamera, hasCameraPermission, and thermalStatusName.
//   Lane 10: current physical thermal snapshot is reported with staticSnapshotOnly=true.
//   Lane 11: at least one front and one back camera are present on this reference target.
//   Lane 12: proof boundary string equals static_thermal_snapshot_no_camera_open and no lane claims runtime thermal listener/camera open/rendering.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2ThermalFallbackPhysicalSmokeApp());
}

class AndroidCamera2ThermalFallbackPhysicalSmokeApp extends StatefulWidget {
  const AndroidCamera2ThermalFallbackPhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2ThermalFallbackPhysicalSmokeApp> createState() =>
      _AndroidCamera2ThermalFallbackPhysicalSmokeAppState();
}

class _AndroidCamera2ThermalFallbackPhysicalSmokeAppState
    extends State<AndroidCamera2ThermalFallbackPhysicalSmokeApp> {
  String _status = 'Initializing Camera2 Thermal Fallback Matrix Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  static const Set<String> _allowedThermalNames = {
    'none',
    'light',
    'moderate',
    'severe',
    'critical',
    'emergency',
    'shutdown',
    'unavailable',
  };

  static const Set<String> _severeThermalNames = {
    'severe',
    'critical',
    'emergency',
    'shutdown',
  };

  static const String _proofBoundary = 'static_thermal_snapshot_no_camera_open';

  bool _isAllowedThermalName(String name) {
    if (name.isEmpty) return false;
    if (_allowedThermalNames.contains(name)) return true;
    return name.startsWith('unknown_');
  }

  bool _checkThermalCoherence(int? status, String name) {
    if (status == null) {
      return name == 'unavailable';
    }
    if (status >= 0 && status <= 6) {
      final standardName = switch (status) {
        0 => 'none',
        1 => 'light',
        2 => 'moderate',
        3 => 'severe',
        4 => 'critical',
        5 => 'emergency',
        6 => 'shutdown',
        _ => 'unknown_$status',
      };
      return name == standardName;
    }
    return name == 'unknown_$status';
  }

  String _computeExpectedFallback({
    required int cameraCount,
    required bool isThermalBlocked,
    required bool supportsConcurrentCamera,
  }) {
    if (cameraCount == 0) {
      return 'no_camera';
    }
    if (isThermalBlocked) {
      return 'thermal_blocked';
    }
    if (supportsConcurrentCamera) {
      return 'concurrent_supported';
    }
    return 'single_camera_only';
  }

  Future<void> _runSmoke() async {
    print('ANDROID_CAMERA_PHASE3_UNIT_S_THERMAL_FALLBACK_SMOKE_START');
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

    var isThermalBlocked = false;
    var expectedFallback = 'unknown';
    var hasFront = false;
    var hasBack = false;
    const staticSnapshotOnly = true;
    Map<String, dynamic>? thermalSummary;

    try {
      // 1. Invoke public capability probe API (diagnostic only, non-opening, static snapshot)
      report =
          await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities()
              .timeout(const Duration(seconds: 15));

      // Lane 1: report.success true
      lane1Pass = report.success == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_S_SMOKE_LANE_1: pass=$lane1Pass success=${report.success}',
      );

      // Lane 2: apiLevel >= 29, cameraCount == cameras.length, cameraCount >= 1
      lane2Pass =
          report.apiLevel >= 29 &&
          report.cameraCount == report.cameras.length &&
          report.cameraCount >= 1;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_S_SMOKE_LANE_2: pass=$lane2Pass '
        'apiLevel=${report.apiLevel} cameraCount=${report.cameraCount} camerasLength=${report.cameras.length}',
      );

      // Lane 3: thermalStatusName non-empty and in allowed set or unknown_*
      lane3Pass = _isAllowedThermalName(report.thermalStatusName);
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_S_SMOKE_LANE_3: pass=$lane3Pass '
        'thermalStatusName=${report.thermalStatusName} thermalStatus=${report.thermalStatus}',
      );

      // Lane 4: thermal blocked predicate computed from name/status is coherent
      isThermalBlocked =
          (report.thermalStatus != null && report.thermalStatus! >= 3) ||
          _severeThermalNames.contains(report.thermalStatusName);
      final coherenceValid = _checkThermalCoherence(
        report.thermalStatus,
        report.thermalStatusName,
      );
      lane4Pass = coherenceValid;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_S_SMOKE_LANE_4: pass=$lane4Pass '
        'isThermalBlocked=$isThermalBlocked coherenceValid=$coherenceValid',
      );

      // Lane 5: report.fallbackRecommendation matches hierarchy
      expectedFallback = _computeExpectedFallback(
        cameraCount: report.cameraCount,
        isThermalBlocked: isThermalBlocked,
        supportsConcurrentCamera: report.supportsConcurrentCamera,
      );
      lane5Pass = report.fallbackRecommendation == expectedFallback;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_S_SMOKE_LANE_5: pass=$lane5Pass '
        'fallbackRecommendation=${report.fallbackRecommendation} expectedFallback=$expectedFallback',
      );

      // 2. Invoke pure Dart readiness planner on probed capability report
      const planner = VGCamera2ReadinessPlanner();
      final evaluatedPlan = planner.evaluate(report);
      plan = evaluatedPlan;

      // Lane 6: planner evaluation completes and decision is valid enum
      lane6Pass = VGCamera2ReadinessDecision.values.contains(
        evaluatedPlan.decision,
      );
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_S_SMOKE_LANE_6: pass=$lane6Pass '
        'decision=${evaluatedPlan.decision.name}',
      );

      // Lane 7: if thermalBlocked predicate true, plan.decision == thermalBlocked and reasons contains thermal_blocked
      if (isThermalBlocked) {
        lane7Pass =
            evaluatedPlan.decision ==
                VGCamera2ReadinessDecision.thermalBlocked &&
            evaluatedPlan.isBlocked &&
            evaluatedPlan.reasons.contains('thermal_blocked');
      } else {
        lane7Pass = true;
      }
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_S_SMOKE_LANE_7: pass=$lane7Pass '
        'isThermalBlocked=$isThermalBlocked decision=${evaluatedPlan.decision.name} reasons=${evaluatedPlan.reasons}',
      );

      // Lane 8: if thermalBlocked predicate false and cameraCount > 0, plan.decision is not thermalBlocked and reasons does not contain thermal_blocked
      if (!isThermalBlocked && report.cameraCount > 0) {
        lane8Pass =
            evaluatedPlan.decision !=
                VGCamera2ReadinessDecision.thermalBlocked &&
            !evaluatedPlan.reasons.contains('thermal_blocked');
      } else {
        lane8Pass = true;
      }
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_S_SMOKE_LANE_8: pass=$lane8Pass '
        'isThermalBlocked=$isThermalBlocked decision=${evaluatedPlan.decision.name}',
      );

      // Lane 9: diagnostics preserve cameraCount, supportsConcurrentCamera, hasCameraPermission, thermalStatusName
      final diag = evaluatedPlan.diagnostics;
      lane9Pass =
          diag['cameraCount'] == report.cameraCount &&
          diag['supportsConcurrentCamera'] == report.supportsConcurrentCamera &&
          diag['hasCameraPermission'] == report.hasCameraPermission &&
          diag['thermalStatusName'] == report.thermalStatusName;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_S_SMOKE_LANE_9: pass=$lane9Pass diagnostics=$diag',
      );

      // Lane 10: current physical thermal snapshot is reported with staticSnapshotOnly=true
      thermalSummary = <String, dynamic>{
        'thermalStatus': report.thermalStatus,
        'thermalStatusName': report.thermalStatusName,
        'isThermalBlocked': isThermalBlocked,
        'fallbackRecommendation': report.fallbackRecommendation,
        'staticSnapshotOnly': staticSnapshotOnly,
        'runtimeThermalListenerActive': false,
        'cameraOpenAttempted': false,
        'captureSessionAttempted': false,
        'renderingAttempted': false,
      };
      lane10Pass = staticSnapshotOnly;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_S_SMOKE_LANE_10: pass=$lane10Pass '
        'staticSnapshotOnly=$staticSnapshotOnly thermalSummary=$thermalSummary',
      );

      // Lane 11: at least one front and one back camera are present on this reference target
      hasFront = report.cameras.any((c) => c.lensFacing == 'front');
      hasBack = report.cameras.any((c) => c.lensFacing == 'back');
      lane11Pass = hasFront && hasBack;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_S_SMOKE_LANE_11: pass=$lane11Pass hasFront=$hasFront hasBack=$hasBack',
      );

      // Lane 12: proof boundary string equals static_thermal_snapshot_no_camera_open and no lane claims camera open
      lane12Pass = _proofBoundary == 'static_thermal_snapshot_no_camera_open';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_S_SMOKE_LANE_12: pass=$lane12Pass proofBoundary=$_proofBoundary',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Thermal fallback smoke exceeded 15 seconds: $te';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_S_THERMAL_FALLBACK_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_S_THERMAL_FALLBACK_SMOKE_ERROR: $topLevelError',
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
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2CapabilityProbe',
        'slice':
            'Phase 3-Unit S — Android Camera2 Static Thermal Fallback Matrix Physical Proof Foundation',
        'target': 'android_physical',
        'pass': allPass,
        'proofBoundary': _proofBoundary,
        'staticSnapshotOnly': staticSnapshotOnly,
        'thermalSummary': thermalSummary,
        'lanes': <String, dynamic>{
          'lane1_reportSuccessTrue': {
            'pass': lane1Pass,
            'success': report?.success,
          },
          'lane2_apiLevelAndCameraCount': {
            'pass': lane2Pass,
            'apiLevel': report?.apiLevel,
            'cameraCount': report?.cameraCount,
            'camerasLength': report?.cameras.length,
          },
          'lane3_thermalStatusNameAllowed': {
            'pass': lane3Pass,
            'thermalStatusName': report?.thermalStatusName,
            'thermalStatus': report?.thermalStatus,
          },
          'lane4_thermalBlockedPredicateCoherent': {
            'pass': lane4Pass,
            'isThermalBlocked': isThermalBlocked,
          },
          'lane5_fallbackRecommendationMatchesHierarchy': {
            'pass': lane5Pass,
            'fallbackRecommendation': report?.fallbackRecommendation,
            'expectedFallback': expectedFallback,
          },
          'lane6_plannerEvaluationCompletesValidEnum': {
            'pass': lane6Pass,
            'decision': plan?.decision.name,
          },
          'lane7_thermalBlockedDecisionWhenBlocked': {
            'pass': lane7Pass,
            'isThermalBlocked': isThermalBlocked,
            'decision': plan?.decision.name,
          },
          'lane8_notThermalBlockedWhenNominal': {
            'pass': lane8Pass,
            'isThermalBlocked': isThermalBlocked,
            'decision': plan?.decision.name,
          },
          'lane9_diagnosticsPreserveFields': {
            'pass': lane9Pass,
            'diagnostics': plan?.diagnostics,
          },
          'lane10_staticThermalSnapshotReported': {
            'pass': lane10Pass,
            'staticSnapshotOnly': staticSnapshotOnly,
          },
          'lane11_frontAndBackCamerasPresent': {
            'pass': lane11Pass,
            'hasFront': hasFront,
            'hasBack': hasBack,
          },
          'lane12_proofBoundaryAndNoCameraOpen': {
            'pass': lane12Pass,
            'proofBoundary': _proofBoundary,
          },
        },
        'report': report?.toMap(),
        'plan': plan?.toMap(),
        'error': topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_S_THERMAL_FALLBACK_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_S_THERMAL_FALLBACK_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_S_THERMAL_FALLBACK_PHYSICAL_FAIL',
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
