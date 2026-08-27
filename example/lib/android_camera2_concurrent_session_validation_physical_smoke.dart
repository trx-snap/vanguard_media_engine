// android_camera2_concurrent_session_validation_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit F: Android Camera2 Guarded Concurrent
// SessionConfiguration Validation Physical Smoke Harness.
//
// Proof lanes:
//   Lane 1: probe success true, cameraCount >= 1, cameras non-empty.
//   Lane 2: probe hasCameraPermission == false; proves no permission grant/prompt path.
//   Lane 3: session plan decision == singleCameraFallback and requiresCameraPermission == true.
//   Lane 4: validation route returns success true and apiLevel >= 30.
//   Lane 5: validation decision == permissionRequired.
//   Lane 6: validation hasCameraPermission == false.
//   Lane 7: attemptedRuntimeValidation == false and supported == false.
//   Lane 8: reasons contains camera_permission_absent.
//   Lane 9: selectedConcurrentCameraIds and surfacePlanCount mirror the input session plan enough to prove the route saw the plan.
//   Lane 10: report.toMap() mirrors all major fields and getters are coherent.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2ConcurrentSessionValidationPhysicalSmokeApp());
}

class AndroidCamera2ConcurrentSessionValidationPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidCamera2ConcurrentSessionValidationPhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2ConcurrentSessionValidationPhysicalSmokeApp>
  createState() =>
      _AndroidCamera2ConcurrentSessionValidationPhysicalSmokeAppState();
}

class _AndroidCamera2ConcurrentSessionValidationPhysicalSmokeAppState
    extends State<AndroidCamera2ConcurrentSessionValidationPhysicalSmokeApp> {
  String _status = 'Initializing Camera2 Concurrent Session Validation Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(
      'ANDROID_CAMERA_PHASE3_UNIT_F_CONCURRENT_SESSION_VALIDATION_SMOKE_START',
    );
    String? topLevelError;
    VGCameraHardwareCapabilityReport? report;
    VGCamera2ReadinessPlan? readiness;
    VGCamera2SessionConfigurationPlan? sessionPlan;
    VGCamera2ConcurrentSessionValidationReport? validationReport;

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
    var gettersCoherent = false;
    var mapMatches = false;

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
        'ANDROID_CAMERA_PHASE3_UNIT_F_SMOKE_LANE_1: pass=$lane1Pass success=${report.success} cameraCount=${report.cameraCount}',
      );

      // Lane 2: probe hasCameraPermission == false; proves no permission grant/prompt path
      lane2Pass = report.hasCameraPermission == false;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_F_SMOKE_LANE_2: pass=$lane2Pass hasCameraPermission=${report.hasCameraPermission}',
      );

      // 2. Invoke pure Dart readiness planner on probed capability report
      const readinessPlanner = VGCamera2ReadinessPlanner();
      readiness = readinessPlanner.evaluate(report);

      // 3. Invoke pure Dart session configuration planner
      const sessionPlanner = VGCamera2SessionConfigurationPlanner();
      sessionPlan = sessionPlanner.evaluate(
        report: report,
        readinessPlan: readiness,
      );

      // Lane 3: session plan decision == singleCameraFallback and requiresCameraPermission == true
      lane3Pass =
          sessionPlan.decision ==
              VGCamera2SessionConfigurationDecision.singleCameraFallback &&
          sessionPlan.requiresCameraPermission == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_F_SMOKE_LANE_3: pass=$lane3Pass decision=${sessionPlan.decision.name} requiresCameraPermission=${sessionPlan.requiresCameraPermission}',
      );

      // 4. Invoke native guarded concurrent SessionConfiguration validation route
      validationReport =
          await VGCamera2ConcurrentSessionValidationReport.validateAndroidCamera2ConcurrentSessionConfiguration(
            plan: sessionPlan,
          ).timeout(const Duration(seconds: 15));

      // Lane 4: validation route returns success true and apiLevel >= 30
      lane4Pass =
          validationReport.success == true && validationReport.apiLevel >= 30;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_F_SMOKE_LANE_4: pass=$lane4Pass success=${validationReport.success} apiLevel=${validationReport.apiLevel}',
      );

      // Lane 5: validation decision == permissionRequired
      lane5Pass =
          validationReport.decision ==
          VGCamera2ConcurrentSessionValidationDecision.permissionRequired;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_F_SMOKE_LANE_5: pass=$lane5Pass decision=${validationReport.decision.name}',
      );

      // Lane 6: validation hasCameraPermission == false
      lane6Pass = validationReport.hasCameraPermission == false;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_F_SMOKE_LANE_6: pass=$lane6Pass hasCameraPermission=${validationReport.hasCameraPermission}',
      );

      // Lane 7: attemptedRuntimeValidation == false and supported == false
      lane7Pass =
          validationReport.attemptedRuntimeValidation == false &&
          validationReport.supported == false;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_F_SMOKE_LANE_7: pass=$lane7Pass attemptedRuntimeValidation=${validationReport.attemptedRuntimeValidation} supported=${validationReport.supported}',
      );

      // Lane 8: reasons contains camera_permission_absent
      lane8Pass = validationReport.reasons.contains('camera_permission_absent');
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_F_SMOKE_LANE_8: pass=$lane8Pass reasons=${validationReport.reasons}',
      );

      // Lane 9: selectedConcurrentCameraIds and surfacePlanCount mirror the input session plan enough to prove the route saw the plan
      lane9Pass =
          listEquals(
            validationReport.selectedConcurrentCameraIds,
            sessionPlan.selectedConcurrentCameraIds,
          ) &&
          validationReport.surfacePlanCount == sessionPlan.surfacePlans.length;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_F_SMOKE_LANE_9: pass=$lane9Pass selectedIds=${validationReport.selectedConcurrentCameraIds} surfacePlanCount=${validationReport.surfacePlanCount}',
      );

      // Lane 10: report.toMap() mirrors all major fields and getters are coherent
      final map = validationReport.toMap();
      gettersCoherent =
          validationReport.isPermissionRequired == true &&
          validationReport.isRuntimeSupported == false &&
          validationReport.isRuntimeRejected == false &&
          validationReport.isRuntimeValidationAttempted == false;
      mapMatches =
          map['success'] == validationReport.success &&
          map['apiLevel'] == validationReport.apiLevel &&
          map['hasCameraPermission'] == validationReport.hasCameraPermission &&
          map['attemptedRuntimeValidation'] ==
              validationReport.attemptedRuntimeValidation &&
          map['supported'] == validationReport.supported &&
          map['decision'] == validationReport.decision.name &&
          listEquals(map['reasons'] as List?, validationReport.reasons) &&
          listEquals(
            map['selectedConcurrentCameraIds'] as List?,
            validationReport.selectedConcurrentCameraIds,
          ) &&
          map['surfacePlanCount'] == validationReport.surfacePlanCount &&
          map['diagnostics'] is Map;

      lane10Pass = gettersCoherent && mapMatches;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_F_SMOKE_LANE_10: pass=$lane10Pass gettersCoherent=$gettersCoherent mapMatches=$mapMatches',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Concurrent session validation smoke exceeded 15 seconds: $te';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_F_CONCURRENT_SESSION_VALIDATION_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_F_CONCURRENT_SESSION_VALIDATION_SMOKE_ERROR: $topLevelError',
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
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2ConcurrentSessionValidator',
        'slice': 'Phase 3-Unit F',
        'target': 'android_physical',
        'pass': allPass,
        'lanes': <String, dynamic>{
          'lane1_probeSuccessAndCameraCountGte1': {
            'pass': lane1Pass,
            'success': report?.success,
            'cameraCount': report?.cameraCount,
          },
          'lane2_probeHasCameraPermissionFalse': {
            'pass': lane2Pass,
            'hasCameraPermission': report?.hasCameraPermission,
          },
          'lane3_sessionPlanSingleFallbackRequiresPermission': {
            'pass': lane3Pass,
            'decision': sessionPlan?.decision.name,
            'requiresCameraPermission': sessionPlan?.requiresCameraPermission,
          },
          'lane4_validationSuccessAndApiLevelGte30': {
            'pass': lane4Pass,
            'success': validationReport?.success,
            'apiLevel': validationReport?.apiLevel,
          },
          'lane5_validationDecisionPermissionRequired': {
            'pass': lane5Pass,
            'decision': validationReport?.decision.name,
          },
          'lane6_validationHasCameraPermissionFalse': {
            'pass': lane6Pass,
            'hasCameraPermission': validationReport?.hasCameraPermission,
          },
          'lane7_validationAttemptedFalseSupportedFalse': {
            'pass': lane7Pass,
            'attemptedRuntimeValidation':
                validationReport?.attemptedRuntimeValidation,
            'supported': validationReport?.supported,
          },
          'lane8_validationReasonsContainsCameraPermissionAbsent': {
            'pass': lane8Pass,
            'reasons': validationReport?.reasons,
          },
          'lane9_validationSelectedIdsAndSurfaceCountMirrorSessionPlan': {
            'pass': lane9Pass,
            'selectedConcurrentCameraIds':
                validationReport?.selectedConcurrentCameraIds,
            'surfacePlanCount': validationReport?.surfacePlanCount,
          },
          'lane10_validationToMapAndGettersCoherent': {
            'pass': lane10Pass,
            'gettersCoherent': gettersCoherent,
            'mapMatches': mapMatches,
          },
        },
        'report': ?report?.toMap(),
        'readinessPlan': ?readiness?.toMap(),
        'sessionPlan': ?sessionPlan?.toMap(),
        'validationReport': ?validationReport?.toMap(),
        'error': ?topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_F_CONCURRENT_SESSION_VALIDATION_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_F_CONCURRENT_SESSION_VALIDATION_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_F_CONCURRENT_SESSION_VALIDATION_PHYSICAL_FAIL',
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
