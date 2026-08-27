// android_camera2_session_configuration_plan_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit E: Android Camera2 Session Configuration
// Eligibility Planner Physical Smoke Harness.
//
// Proof lanes:
//   Lane 1: probe success true, cameraCount >= 1, cameras non-empty.
//   Lane 2: hasCameraPermission == false on current example app; proves no permission prompt route was used.
//   Lane 3: readiness planner produces singleCameraOnly on current SM-A566B/no-concurrent target.
//   Lane 4: session configuration planner runs synchronously and decision enum is valid.
//   Lane 5: plan.decision == singleCameraFallback.
//   Lane 6: plan.requiresCameraPermission == true.
//   Lane 7: plan.requiresRuntimeSessionValidation == false.
//   Lane 8: plan.reasons contains camera_permission_absent and either no_matching_concurrent_camera_set or no_secondary_camera.
//   Lane 9: plan.selectedConcurrentCameraIds has length 1 and matches a detected camera.
//   Lane 10: surfacePlans non-empty and every surface has positive size, non-empty cameraId, role preview/videoRecord, formatName PRIVATE, streamUseCaseName PREVIEW or VIDEO_RECORD.
//   Lane 11: diagnostics mirror report/readiness: cameraCount, supportsConcurrentCamera, hasCameraPermission, readinessDecision, surfacePlanCount, mandatory counts are ints >= 0.
//   Lane 12: plan.toMap() shape is valid and mirrors decision/reasons/surfaces/permission/runtime flags.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2SessionConfigurationPlanPhysicalSmokeApp());
}

class AndroidCamera2SessionConfigurationPlanPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidCamera2SessionConfigurationPlanPhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2SessionConfigurationPlanPhysicalSmokeApp> createState() =>
      _AndroidCamera2SessionConfigurationPlanPhysicalSmokeAppState();
}

class _AndroidCamera2SessionConfigurationPlanPhysicalSmokeAppState
    extends State<AndroidCamera2SessionConfigurationPlanPhysicalSmokeApp> {
  String _status = 'Initializing Camera2 Session Configuration Plan Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_CAMERA_PHASE3_UNIT_E_SESSION_CONFIG_PLAN_SMOKE_START');
    String? topLevelError;
    VGCameraHardwareCapabilityReport? report;
    VGCamera2ReadinessPlan? readiness;
    VGCamera2SessionConfigurationPlan? plan;

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

    try {
      // 1. Invoke public probe API (diagnostic only, non-prompting, no camera opened)
      report =
          await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities()
              .timeout(const Duration(seconds: 15));

      // Lane 1: probe success true, cameraCount >= 1, cameras non-empty
      lane1Pass =
          report.success == true &&
          report.cameraCount >= 1 &&
          report.cameras.isNotEmpty;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_E_SMOKE_LANE_1: pass=$lane1Pass success=${report.success} cameraCount=${report.cameraCount}',
      );

      // Lane 2: hasCameraPermission == false (non-prompting capability probe)
      lane2Pass = report.hasCameraPermission == false;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_E_SMOKE_LANE_2: pass=$lane2Pass hasCameraPermission=${report.hasCameraPermission}',
      );

      // 2. Invoke pure Dart readiness planner on probed capability report
      const readinessPlanner = VGCamera2ReadinessPlanner();
      readiness = readinessPlanner.evaluate(report);

      // Lane 3: readiness planner produces singleCameraOnly on current SM-A566B/no-concurrent target
      lane3Pass =
          readiness.decision == VGCamera2ReadinessDecision.singleCameraOnly;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_E_SMOKE_LANE_3: pass=$lane3Pass readinessDecision=${readiness.decision.name}',
      );

      // 3. Invoke pure Dart session configuration planner
      const sessionPlanner = VGCamera2SessionConfigurationPlanner();
      final evaluatedPlan = sessionPlanner.evaluate(
        report: report,
        readinessPlan: readiness,
      );
      plan = evaluatedPlan;

      // Lane 4: session configuration planner runs synchronously and decision enum is valid
      lane4Pass = VGCamera2SessionConfigurationDecision.values.contains(
        evaluatedPlan.decision,
      );
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_E_SMOKE_LANE_4: pass=$lane4Pass decision=${evaluatedPlan.decision.name}',
      );

      // Lane 5: plan.decision == singleCameraFallback
      lane5Pass =
          evaluatedPlan.decision ==
          VGCamera2SessionConfigurationDecision.singleCameraFallback;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_E_SMOKE_LANE_5: pass=$lane5Pass decision=${evaluatedPlan.decision.name}',
      );

      // Lane 6: plan.requiresCameraPermission == true
      lane6Pass = evaluatedPlan.requiresCameraPermission == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_E_SMOKE_LANE_6: pass=$lane6Pass requiresCameraPermission=${evaluatedPlan.requiresCameraPermission}',
      );

      // Lane 7: plan.requiresRuntimeSessionValidation == false
      lane7Pass = evaluatedPlan.requiresRuntimeSessionValidation == false;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_E_SMOKE_LANE_7: pass=$lane7Pass requiresRuntimeSessionValidation=${evaluatedPlan.requiresRuntimeSessionValidation}',
      );

      // Lane 8: plan.reasons contains camera_permission_absent and either no_matching_concurrent_camera_set or no_secondary_camera
      lane8Pass =
          evaluatedPlan.reasons.contains('camera_permission_absent') &&
          (evaluatedPlan.reasons.contains(
                'no_matching_concurrent_camera_set',
              ) ||
              evaluatedPlan.reasons.contains('no_secondary_camera'));
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_E_SMOKE_LANE_8: pass=$lane8Pass reasons=${evaluatedPlan.reasons}',
      );

      // Lane 9: plan.selectedConcurrentCameraIds has length 1 and matches a detected camera
      lane9Pass =
          evaluatedPlan.selectedConcurrentCameraIds.length == 1 &&
          report.cameras.any(
            (c) =>
                c.cameraId == evaluatedPlan.selectedConcurrentCameraIds.first,
          );
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_E_SMOKE_LANE_9: pass=$lane9Pass selectedIds=${evaluatedPlan.selectedConcurrentCameraIds}',
      );

      // Lane 10: surfacePlans non-empty and every surface has positive size, non-empty cameraId, role preview/videoRecord, formatName PRIVATE, streamUseCaseName PREVIEW or VIDEO_RECORD
      lane10Pass =
          evaluatedPlan.surfacePlans.isNotEmpty &&
          evaluatedPlan.surfacePlans.every((s) {
            final validSize = s.size.width > 0 && s.size.height > 0;
            final validId = s.cameraId.isNotEmpty;
            final validRole =
                s.role == VGCamera2SessionSurfaceRole.preview ||
                s.role == VGCamera2SessionSurfaceRole.videoRecord;
            final validFormat = s.formatName == 'PRIVATE';
            final validUseCase =
                s.streamUseCaseName == 'PREVIEW' ||
                s.streamUseCaseName == 'VIDEO_RECORD';
            return validSize &&
                validId &&
                validRole &&
                validFormat &&
                validUseCase;
          });
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_E_SMOKE_LANE_10: pass=$lane10Pass surfaceCount=${evaluatedPlan.surfacePlans.length}',
      );

      // Lane 11: diagnostics mirror report/readiness: cameraCount, supportsConcurrentCamera, hasCameraPermission, readinessDecision, surfacePlanCount, mandatory counts are ints >= 0
      final diag = evaluatedPlan.diagnostics;
      final combCount = diag['mandatoryConcurrentCombinationCount'];
      final streamCount = diag['mandatoryConcurrentStreamCount'];
      lane11Pass =
          diag['cameraCount'] == report.cameraCount &&
          diag['supportsConcurrentCamera'] == report.supportsConcurrentCamera &&
          diag['hasCameraPermission'] == report.hasCameraPermission &&
          diag['readinessDecision'] == readiness.decision.name &&
          diag['surfacePlanCount'] == evaluatedPlan.surfacePlans.length &&
          combCount is int &&
          combCount >= 0 &&
          streamCount is int &&
          streamCount >= 0;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_E_SMOKE_LANE_11: pass=$lane11Pass diagnostics=$diag',
      );

      // Lane 12: plan.toMap() shape is valid and mirrors decision/reasons/surfaces/permission/runtime flags
      final map = evaluatedPlan.toMap();
      lane12Pass =
          map['decision'] == evaluatedPlan.decision.name &&
          map['reasons'] is List &&
          map['surfacePlans'] is List &&
          map['selectedConcurrentCameraIds'] is List &&
          map['requiresCameraPermission'] ==
              evaluatedPlan.requiresCameraPermission &&
          map['requiresRuntimeSessionValidation'] ==
              evaluatedPlan.requiresRuntimeSessionValidation &&
          map['diagnostics'] is Map;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_E_SMOKE_LANE_12: pass=$lane12Pass mapDecision=${map['decision']}',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Session configuration plan smoke exceeded 15 seconds: $te';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_E_SESSION_CONFIG_PLAN_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_E_SESSION_CONFIG_PLAN_SMOKE_ERROR: $topLevelError',
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
        'unit': 'AndroidCamera2SessionConfigurationPlan',
        'slice': 'Phase 3-Unit E',
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
          'lane3_readinessDecisionSingleCameraOnly': {
            'pass': lane3Pass,
            'readinessDecision': readiness?.decision.name,
          },
          'lane4_sessionPlannerSynchronousValid': {
            'pass': lane4Pass,
            'decision': plan?.decision.name,
          },
          'lane5_decisionSingleCameraFallback': {
            'pass': lane5Pass,
            'decision': plan?.decision.name,
          },
          'lane6_requiresCameraPermissionTrue': {
            'pass': lane6Pass,
            'requiresCameraPermission': plan?.requiresCameraPermission,
          },
          'lane7_requiresRuntimeSessionValidationFalse': {
            'pass': lane7Pass,
            'requiresRuntimeSessionValidation':
                plan?.requiresRuntimeSessionValidation,
          },
          'lane8_reasonsPermissionAbsentAndNoConcurrentSet': {
            'pass': lane8Pass,
            'reasons': plan?.reasons,
          },
          'lane9_selectedConcurrentCameraIdsSingleDetected': {
            'pass': lane9Pass,
            'selectedConcurrentCameraIds': plan?.selectedConcurrentCameraIds,
          },
          'lane10_surfacePlansValid': {
            'pass': lane10Pass,
            'surfacePlanCount': plan?.surfacePlans.length,
            'surfacePlans': plan?.surfacePlans.map((s) => s.toMap()).toList(),
          },
          'lane11_diagnosticsIntegrity': {
            'pass': lane11Pass,
            'diagnostics': plan?.diagnostics,
          },
          'lane12_toMapSerialization': {'pass': lane12Pass},
        },
        'report': ?report?.toMap(),
        'readinessPlan': ?readiness?.toMap(),
        'sessionPlan': ?plan?.toMap(),
        'error': ?topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_E_SESSION_CONFIG_PLAN_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_E_SESSION_CONFIG_PLAN_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_E_SESSION_CONFIG_PLAN_PHYSICAL_FAIL',
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
