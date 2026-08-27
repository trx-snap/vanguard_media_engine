// android_camera2_concurrent_session_runtime_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit G: Android Camera2 Granted-Permission
// Concurrent SessionConfiguration Runtime Validation Physical Smoke Harness.
//
// Proof lanes:
//   Lane 1: probe success true, apiLevel >= 35, cameraCount >= 2, cameras length >= 2.
//   Lane 2: report.hasCameraPermission == true (grant runner worked; no app permission dialog request).
//   Lane 3: primary/secondary camera ids selected and distinct, both in report.cameras.
//   Lane 4: synthetic plan has decision concurrentValidationCandidate, 2 selected ids, 4 surface plans, all positive sizes.
//   Lane 5: validation success true and validation apiLevel >= 35.
//   Lane 6: validation.hasCameraPermission == true.
//   Lane 7: validation.attemptedRuntimeValidation == true.
//   Lane 8: validation decision is one of supported, notSupported, validationFailed; it must not be permissionRequired, notCandidate, or unsupportedApi.
//   Lane 9: validation.selectedConcurrentCameraIds equals synthetic selected ids and surfacePlanCount == 4.
//   Lane 10: no validation reason camera_permission_absent; if validationFailed then reasons contains runtime_validation_threw and diagnostics contains error. If supported/notSupported, supported boolean must match the decision.
//   Lane 11: getters/toMap are coherent.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2ConcurrentSessionRuntimePhysicalSmokeApp());
}

class AndroidCamera2ConcurrentSessionRuntimePhysicalSmokeApp
    extends StatefulWidget {
  const AndroidCamera2ConcurrentSessionRuntimePhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2ConcurrentSessionRuntimePhysicalSmokeApp> createState() =>
      _AndroidCamera2ConcurrentSessionRuntimePhysicalSmokeAppState();
}

class _AndroidCamera2ConcurrentSessionRuntimePhysicalSmokeAppState
    extends State<AndroidCamera2ConcurrentSessionRuntimePhysicalSmokeApp> {
  String _status = 'Initializing Camera2 Granted Runtime Validation Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(
      'ANDROID_CAMERA_PHASE3_UNIT_G_GRANTED_RUNTIME_VALIDATION_SMOKE_START',
    );
    String? topLevelError;
    VGCameraHardwareCapabilityReport? report;
    VGCameraHardwareDeviceCapability? primary;
    VGCameraHardwareDeviceCapability? secondary;
    VGCamera2SessionConfigurationPlan? syntheticPlan;
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
    var lane11Pass = false;
    var gettersCoherent = false;
    var mapMatches = false;

    try {
      // 0. Wait 5 seconds before probing to let the runner grant CAMERA after install/start
      await Future<void>.delayed(const Duration(seconds: 5));

      // 1. Invoke public probe API
      report =
          await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities()
              .timeout(const Duration(seconds: 15));

      // Lane 1: probe success true, apiLevel >= 35, cameraCount >= 2, cameras length >= 2
      lane1Pass =
          report.success == true &&
          report.apiLevel >= 35 &&
          report.cameraCount >= 2 &&
          report.cameras.length >= 2;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_G_SMOKE_LANE_1: pass=$lane1Pass success=${report.success} apiLevel=${report.apiLevel} cameraCount=${report.cameraCount} camerasLength=${report.cameras.length}',
      );

      // Lane 2: report.hasCameraPermission == true (grant runner worked; no app permission dialog request)
      lane2Pass = report.hasCameraPermission == true;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_G_SMOKE_LANE_2: pass=$lane2Pass hasCameraPermission=${report.hasCameraPermission}',
      );

      // 2. Pick primary camera: first back-facing camera else first camera
      for (final camera in report.cameras) {
        if (camera.lensFacing == 'back') {
          primary = camera;
          break;
        }
      }
      primary ??= report.cameras.isNotEmpty ? report.cameras.first : null;

      // 3. Pick secondary camera: first front-facing camera with different id else first different camera
      if (primary != null) {
        for (final camera in report.cameras) {
          if (camera.lensFacing == 'front' &&
              camera.cameraId != primary.cameraId) {
            secondary = camera;
            break;
          }
        }
        if (secondary == null) {
          for (final camera in report.cameras) {
            if (camera.cameraId != primary.cameraId) {
              secondary = camera;
              break;
            }
          }
        }
      }

      // Lane 3: primary/secondary camera ids selected and distinct, both in report.cameras
      lane3Pass =
          primary != null &&
          secondary != null &&
          primary.cameraId != secondary.cameraId &&
          report.cameras.any((c) => c.cameraId == primary!.cameraId) &&
          report.cameras.any((c) => c.cameraId == secondary!.cameraId);
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_G_SMOKE_LANE_3: pass=$lane3Pass primaryId=${primary?.cameraId} secondaryId=${secondary?.cameraId}',
      );

      // 4. Build a synthetic VGCamera2SessionConfigurationPlan
      final surfaces = <VGCamera2SessionSurfacePlan>[];
      if (primary != null && primary.previewSizes.isNotEmpty) {
        surfaces.add(
          VGCamera2SessionSurfacePlan(
            cameraId: primary.cameraId,
            role: VGCamera2SessionSurfaceRole.preview,
            formatName: 'PRIVATE',
            size: primary.previewSizes.first,
            streamUseCaseName: 'PREVIEW',
          ),
        );
      }
      if (primary != null && primary.videoSizes.isNotEmpty) {
        surfaces.add(
          VGCamera2SessionSurfacePlan(
            cameraId: primary.cameraId,
            role: VGCamera2SessionSurfaceRole.videoRecord,
            formatName: 'PRIVATE',
            size: primary.videoSizes.first,
            streamUseCaseName: 'VIDEO_RECORD',
          ),
        );
      }
      if (secondary != null && secondary.previewSizes.isNotEmpty) {
        surfaces.add(
          VGCamera2SessionSurfacePlan(
            cameraId: secondary.cameraId,
            role: VGCamera2SessionSurfaceRole.preview,
            formatName: 'PRIVATE',
            size: secondary.previewSizes.first,
            streamUseCaseName: 'PREVIEW',
          ),
        );
      }
      if (secondary != null && secondary.videoSizes.isNotEmpty) {
        surfaces.add(
          VGCamera2SessionSurfacePlan(
            cameraId: secondary.cameraId,
            role: VGCamera2SessionSurfaceRole.videoRecord,
            formatName: 'PRIVATE',
            size: secondary.videoSizes.first,
            streamUseCaseName: 'VIDEO_RECORD',
          ),
        );
      }

      final selectedIds = <String>[
        if (primary != null) primary.cameraId,
        if (secondary != null) secondary.cameraId,
      ];

      syntheticPlan = VGCamera2SessionConfigurationPlan(
        decision:
            VGCamera2SessionConfigurationDecision.concurrentValidationCandidate,
        reasons: const <String>[],
        surfacePlans: surfaces,
        selectedConcurrentCameraIds: selectedIds,
        requiresCameraPermission: false,
        requiresRuntimeSessionValidation: true,
        diagnostics: <String, Object?>{
          'synthetic': true,
          'slice': 'Phase 3-Unit G',
          'primaryCameraId': primary?.cameraId,
          'secondaryCameraId': secondary?.cameraId,
        },
      );

      // Lane 4: synthetic plan has decision concurrentValidationCandidate, 2 selected ids, 4 surface plans, all positive sizes
      lane4Pass =
          syntheticPlan.decision ==
              VGCamera2SessionConfigurationDecision
                  .concurrentValidationCandidate &&
          syntheticPlan.selectedConcurrentCameraIds.length == 2 &&
          syntheticPlan.surfacePlans.length == 4 &&
          syntheticPlan.surfacePlans.every(
            (s) => s.size.width > 0 && s.size.height > 0,
          );
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_G_SMOKE_LANE_4: pass=$lane4Pass decision=${syntheticPlan.decision.name} selectedIds=${syntheticPlan.selectedConcurrentCameraIds} surfacesCount=${syntheticPlan.surfacePlans.length}',
      );

      // 5. Invoke native runtime validation route with synthetic plan
      if (lane4Pass) {
        validationReport =
            await VGCamera2ConcurrentSessionValidationReport.validateAndroidCamera2ConcurrentSessionConfiguration(
              plan: syntheticPlan,
            ).timeout(const Duration(seconds: 15));

        // Lane 5: validation success true and validation apiLevel >= 35
        lane5Pass =
            validationReport.success == true && validationReport.apiLevel >= 35;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_G_SMOKE_LANE_5: pass=$lane5Pass success=${validationReport.success} apiLevel=${validationReport.apiLevel}',
        );

        // Lane 6: validation.hasCameraPermission == true
        lane6Pass = validationReport.hasCameraPermission == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_G_SMOKE_LANE_6: pass=$lane6Pass hasCameraPermission=${validationReport.hasCameraPermission}',
        );

        // Lane 7: validation.attemptedRuntimeValidation == true
        lane7Pass = validationReport.attemptedRuntimeValidation == true;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_G_SMOKE_LANE_7: pass=$lane7Pass attemptedRuntimeValidation=${validationReport.attemptedRuntimeValidation}',
        );

        // Lane 8: validation decision is one of supported, notSupported, validationFailed; it must not be permissionRequired, notCandidate, or unsupportedApi
        final decision = validationReport.decision;
        final isAllowedDecision =
            decision ==
                VGCamera2ConcurrentSessionValidationDecision.supported ||
            decision ==
                VGCamera2ConcurrentSessionValidationDecision.notSupported ||
            decision ==
                VGCamera2ConcurrentSessionValidationDecision.validationFailed;
        final isDisallowedDecision =
            decision ==
                VGCamera2ConcurrentSessionValidationDecision
                    .permissionRequired ||
            decision ==
                VGCamera2ConcurrentSessionValidationDecision.notCandidate ||
            decision ==
                VGCamera2ConcurrentSessionValidationDecision.unsupportedApi;
        lane8Pass = isAllowedDecision && !isDisallowedDecision;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_G_SMOKE_LANE_8: pass=$lane8Pass decision=${validationReport.decision.name}',
        );

        // Lane 9: validation.selectedConcurrentCameraIds equals synthetic selected ids and surfacePlanCount == 4
        lane9Pass =
            listEquals(
              validationReport.selectedConcurrentCameraIds,
              syntheticPlan.selectedConcurrentCameraIds,
            ) &&
            validationReport.surfacePlanCount == 4;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_G_SMOKE_LANE_9: pass=$lane9Pass selectedIds=${validationReport.selectedConcurrentCameraIds} surfacePlanCount=${validationReport.surfacePlanCount}',
        );

        // Lane 10: no validation reason camera_permission_absent; if validationFailed then reasons contains runtime_validation_threw and diagnostics contains error. If supported/notSupported, supported boolean must match the decision.
        final noPermissionAbsent = !validationReport.reasons.contains(
          'camera_permission_absent',
        );
        var outcomeMatches = false;
        if (validationReport.decision ==
            VGCamera2ConcurrentSessionValidationDecision.validationFailed) {
          outcomeMatches =
              validationReport.reasons.contains('runtime_validation_threw') &&
              validationReport.diagnostics.containsKey('error') &&
              validationReport.diagnostics['error'] != null;
        } else if (validationReport.decision ==
            VGCamera2ConcurrentSessionValidationDecision.supported) {
          outcomeMatches = validationReport.supported == true;
        } else if (validationReport.decision ==
            VGCamera2ConcurrentSessionValidationDecision.notSupported) {
          outcomeMatches = validationReport.supported == false;
        }
        lane10Pass = noPermissionAbsent && outcomeMatches;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_G_SMOKE_LANE_10: pass=$lane10Pass noPermissionAbsent=$noPermissionAbsent outcomeMatches=$outcomeMatches reasons=${validationReport.reasons} supported=${validationReport.supported}',
        );

        // Lane 11: getters/toMap are coherent
        final map = validationReport.toMap();
        gettersCoherent =
            validationReport.isPermissionRequired == false &&
            validationReport.isRuntimeValidationAttempted ==
                validationReport.attemptedRuntimeValidation &&
            validationReport.isRuntimeSupported ==
                (validationReport.attemptedRuntimeValidation &&
                    validationReport.decision ==
                        VGCamera2ConcurrentSessionValidationDecision
                            .supported) &&
            validationReport.isRuntimeRejected ==
                (validationReport.attemptedRuntimeValidation &&
                    validationReport.decision ==
                        VGCamera2ConcurrentSessionValidationDecision
                            .notSupported);
        mapMatches =
            map['success'] == validationReport.success &&
            map['apiLevel'] == validationReport.apiLevel &&
            map['hasCameraPermission'] ==
                validationReport.hasCameraPermission &&
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

        lane11Pass = gettersCoherent && mapMatches;
        print(
          'ANDROID_CAMERA_PHASE3_UNIT_G_SMOKE_LANE_11: pass=$lane11Pass gettersCoherent=$gettersCoherent mapMatches=$mapMatches',
        );
      }
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Granted concurrent session validation smoke exceeded timeout: $te';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_G_GRANTED_RUNTIME_VALIDATION_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_G_GRANTED_RUNTIME_VALIDATION_SMOKE_ERROR: $topLevelError',
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
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2ConcurrentSessionValidator',
        'slice': 'Phase 3-Unit G',
        'target': 'android_physical',
        'pass': allPass,
        'lanes': <String, dynamic>{
          'lane1_probeSuccessApiLevelGte35CameraCountGte2': {
            'pass': lane1Pass,
            'success': report?.success,
            'apiLevel': report?.apiLevel,
            'cameraCount': report?.cameraCount,
            'camerasLength': report?.cameras.length,
          },
          'lane2_probeHasCameraPermissionTrue': {
            'pass': lane2Pass,
            'hasCameraPermission': report?.hasCameraPermission,
          },
          'lane3_cameraIdsSelectedAndDistinct': {
            'pass': lane3Pass,
            'primaryCameraId': primary?.cameraId,
            'secondaryCameraId': secondary?.cameraId,
          },
          'lane4_syntheticPlanCandidateSurfacesPositive': {
            'pass': lane4Pass,
            'decision': syntheticPlan?.decision.name,
            'selectedIds': syntheticPlan?.selectedConcurrentCameraIds,
            'surfacePlanCount': syntheticPlan?.surfacePlans.length,
          },
          'lane5_validationSuccessApiLevelGte35': {
            'pass': lane5Pass,
            'success': validationReport?.success,
            'apiLevel': validationReport?.apiLevel,
          },
          'lane6_validationHasCameraPermissionTrue': {
            'pass': lane6Pass,
            'hasCameraPermission': validationReport?.hasCameraPermission,
          },
          'lane7_validationAttemptedRuntimeValidationTrue': {
            'pass': lane7Pass,
            'attemptedRuntimeValidation':
                validationReport?.attemptedRuntimeValidation,
          },
          'lane8_validationDecisionAllowed': {
            'pass': lane8Pass,
            'decision': validationReport?.decision.name,
          },
          'lane9_validationSelectedIdsAndSurfaceCountMatch': {
            'pass': lane9Pass,
            'selectedConcurrentCameraIds':
                validationReport?.selectedConcurrentCameraIds,
            'surfacePlanCount': validationReport?.surfacePlanCount,
          },
          'lane10_validationReasonsAndDiagnosticsCoherent': {
            'pass': lane10Pass,
            'reasons': validationReport?.reasons,
            'supported': validationReport?.supported,
            'diagnostics': validationReport?.diagnostics,
          },
          'lane11_validationToMapAndGettersCoherent': {
            'pass': lane11Pass,
            'gettersCoherent': gettersCoherent,
            'mapMatches': mapMatches,
          },
        },
        'report': report?.toMap(),
        'syntheticPlan': syntheticPlan?.toMap(),
        'validationReport': validationReport?.toMap(),
        'error': topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_G_GRANTED_RUNTIME_VALIDATION_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_G_GRANTED_RUNTIME_VALIDATION_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_G_GRANTED_RUNTIME_VALIDATION_PHYSICAL_FAIL',
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
