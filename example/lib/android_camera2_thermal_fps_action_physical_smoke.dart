// android_camera2_thermal_fps_action_physical_smoke.dart
// Vanguard Media Engine - P3-CAM-THERMAL-ACT-FPS-REQUEST-ACTION: Android
// Camera2 Repeating-Request AE Target FPS Range Mutation Physical Smoke.
//
// Proof lanes:
//   Lane 1: probe success true, apiLevel >= 24, cameraCount >= 1, cameras not empty.
//   Lane 2: probe hasCameraPermission true, proving adb grant path active with no permission UI.
//   Lane 3: selected primary camera id nonblank and exists in probe cameras.
//   Lane 4: smoke report success true and decision == fpsRangeMutated.
//   Lane 5: report.hasCameraPermission true and attemptedOpen true.
//   Lane 6: report.opened true, sessionConfigured true, sessionConfigureCount == 1.
//   Lane 7: report.initialRepeatingStarted true, initialCaptureCompleted true, events contains initialRepeatingRequestStarted.
//   Lane 8: report.updatedRepeatingStarted true, events contains syntheticThermalActionTriggered and updatedRepeatingRequestStarted.
//   Lane 9: report.updatedCaptureCompleted true and updatedConsecutiveCaptureCount >= 2.
//   Lane 10: reduced AE FPS range upper strictly lower than initial AE FPS range upper (isReducedRangeStrictlyLower true).
//   Lane 11: report.syntheticPolicyInput true, thermalStateRaw == 2, wasRecordingPolicyInput true, hadSecondaryCameraPolicyInput false, recordingActive false.
//   Lane 12: report.aeTargetFpsRangeMutated true, frameCadenceChangeProven false.
//   Lane 13: report.proofBoundary matches the exact expected string verbatim.
//   Lane 14: report.sessionConfigureCount == 1, surfaceCount == 1, reusedRequestBuilder true, cameraSessionReconfigured false.
//   Lane 15: all nonclaim booleans false (realForcedOverheat, powerManagerThermalStateMutated, osThermalListenerTriggered, mediaRecorderCreated, encoderTouched, rendererTouched, productUiTouched, secondaryCameraOpened, secondaryCameraDisabled, productCameraSessionTouched, cameraSessionReconfigured).
//   Lane 16: report.sessionClosed true, deviceClosed true, imageReaderClosed true, isCleanedUp true.
//   Lane 17: getters/toMap coherent.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _expectedProofBoundary =
    'single_camera_repeating_request_ae_fps_range_mutation_synthetic_thermal_no_forced_heat_no_recording_no_encoder';

void main() {
  runApp(const AndroidCamera2ThermalFpsActionPhysicalSmokeApp());
}

class AndroidCamera2ThermalFpsActionPhysicalSmokeApp extends StatefulWidget {
  const AndroidCamera2ThermalFpsActionPhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2ThermalFpsActionPhysicalSmokeApp> createState() =>
      _AndroidCamera2ThermalFpsActionPhysicalSmokeAppState();
}

class _AndroidCamera2ThermalFpsActionPhysicalSmokeAppState
    extends State<AndroidCamera2ThermalFpsActionPhysicalSmokeApp> {
  String _status = 'Initializing Camera2 Thermal FPS Action Physical Smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_PHYSICAL_SMOKE_START');
    String? topLevelError;
    VGCameraHardwareCapabilityReport? probeReport;
    VGCameraHardwareDeviceCapability? primary;
    VGCamera2ThermalFpsActionSmokeReport? smokeReport;

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
    var lane16Pass = false;
    var lane17Pass = false;
    var gettersCoherent = false;
    var mapMatches = false;

    try {
      // 0. Wait 5 seconds before probing/running to allow grant runner to grant CAMERA after install/start.
      await Future<void>.delayed(const Duration(seconds: 5));

      // 1. Probe Android Camera2 capabilities.
      probeReport =
          await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities()
              .timeout(const Duration(seconds: 15));

      // Lane 1: probe success true, apiLevel >= 24, cameraCount >= 1, cameras not empty.
      lane1Pass =
          probeReport.success == true &&
          probeReport.apiLevel >= 24 &&
          probeReport.cameraCount >= 1 &&
          probeReport.cameras.isNotEmpty;
      print(
        'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_1: pass=$lane1Pass success=${probeReport.success} apiLevel=${probeReport.apiLevel} cameraCount=${probeReport.cameraCount} camerasLength=${probeReport.cameras.length}',
      );

      // Lane 2: probe hasCameraPermission true, proving adb grant path active with no permission UI.
      lane2Pass = probeReport.hasCameraPermission == true;
      print(
        'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_2: pass=$lane2Pass hasCameraPermission=${probeReport.hasCameraPermission}',
      );

      // 2. Select primary camera: first lensFacing == 'back', else first camera.
      for (final camera in probeReport.cameras) {
        if (camera.lensFacing == 'back') {
          primary = camera;
          break;
        }
      }
      primary ??= probeReport.cameras.isNotEmpty
          ? probeReport.cameras.first
          : null;

      final primaryCam = primary;

      // Lane 3: selected primary camera id nonblank and exists in probe cameras.
      lane3Pass =
          primaryCam != null &&
          primaryCam.cameraId.trim().isNotEmpty &&
          probeReport.cameras.any((c) => c.cameraId == primaryCam.cameraId);
      print(
        'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_3: pass=$lane3Pass primaryCameraId=${primaryCam?.cameraId} lensFacing=${primaryCam?.lensFacing}',
      );

      // 3. Execute Camera2 Thermal FPS Action Smoke.
      if (lane1Pass && lane2Pass && lane3Pass) {
        smokeReport =
            await VGCamera2ThermalFpsActionSmokeReport.runAndroidCamera2ThermalFpsActionSmoke(
              cameraId: primaryCam.cameraId,
              timeout: const Duration(seconds: 10),
              maxWidth: 640,
              maxHeight: 480,
            ).timeout(const Duration(seconds: 30));

        // Lane 4: smoke report success true and decision == fpsRangeMutated.
        lane4Pass =
            smokeReport.success == true &&
            smokeReport.decision ==
                VGCamera2ThermalFpsActionSmokeDecision.fpsRangeMutated;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_4: pass=$lane4Pass success=${smokeReport.success} decision=${smokeReport.decision.name}',
        );

        // Lane 5: report.hasCameraPermission true and attemptedOpen true.
        lane5Pass =
            smokeReport.hasCameraPermission == true &&
            smokeReport.attemptedOpen == true;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_5: pass=$lane5Pass hasCameraPermission=${smokeReport.hasCameraPermission} attemptedOpen=${smokeReport.attemptedOpen}',
        );

        // Lane 6: report.opened true, sessionConfigured true, sessionConfigureCount == 1.
        lane6Pass =
            smokeReport.opened == true &&
            smokeReport.sessionConfigured == true &&
            smokeReport.sessionConfigureCount == 1;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_6: pass=$lane6Pass opened=${smokeReport.opened} sessionConfigured=${smokeReport.sessionConfigured} sessionConfigureCount=${smokeReport.sessionConfigureCount}',
        );

        // Lane 7: report.initialRepeatingStarted true, initialCaptureCompleted true, events contains initialRepeatingRequestStarted.
        lane7Pass =
            smokeReport.initialRepeatingStarted == true &&
            smokeReport.initialCaptureCompleted == true &&
            smokeReport.events.contains('initialRepeatingRequestStarted');
        print(
          'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_7: pass=$lane7Pass initialRepeatingStarted=${smokeReport.initialRepeatingStarted} initialCaptureCompleted=${smokeReport.initialCaptureCompleted} events=${smokeReport.events}',
        );

        // Lane 8: report.updatedRepeatingStarted true, events contains syntheticThermalActionTriggered and updatedRepeatingRequestStarted.
        lane8Pass =
            smokeReport.updatedRepeatingStarted == true &&
            smokeReport.events.contains('syntheticThermalActionTriggered') &&
            smokeReport.events.contains('updatedRepeatingRequestStarted');
        print(
          'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_8: pass=$lane8Pass updatedRepeatingStarted=${smokeReport.updatedRepeatingStarted} events=${smokeReport.events}',
        );

        // Lane 9: report.updatedCaptureCompleted true and updatedConsecutiveCaptureCount >= 2.
        lane9Pass =
            smokeReport.updatedCaptureCompleted == true &&
            smokeReport.updatedConsecutiveCaptureCount >= 2;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_9: pass=$lane9Pass updatedCaptureCompleted=${smokeReport.updatedCaptureCompleted} updatedConsecutiveCaptureCount=${smokeReport.updatedConsecutiveCaptureCount}',
        );

        // Lane 10: reduced AE FPS range upper strictly lower than initial AE FPS range upper.
        lane10Pass = smokeReport.isReducedRangeStrictlyLower == true;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_10: pass=$lane10Pass initial=${smokeReport.initialAeTargetFpsRange} reduced=${smokeReport.reducedAeTargetFpsRange}',
        );

        // Lane 11: synthetic policy tuple exact.
        lane11Pass =
            smokeReport.syntheticPolicyInput == true &&
            smokeReport.thermalStateRaw == 2 &&
            smokeReport.wasRecordingPolicyInput == true &&
            smokeReport.hadSecondaryCameraPolicyInput == false &&
            smokeReport.recordingActive == false;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_11: pass=$lane11Pass syntheticPolicyInput=${smokeReport.syntheticPolicyInput} thermalStateRaw=${smokeReport.thermalStateRaw} wasRecordingPolicyInput=${smokeReport.wasRecordingPolicyInput} hadSecondaryCameraPolicyInput=${smokeReport.hadSecondaryCameraPolicyInput} recordingActive=${smokeReport.recordingActive}',
        );

        // Lane 12: aeTargetFpsRangeMutated true, captureRequestUpdated true,
        // repeatingRequestMutated true, frameCadenceChangeProven false.
        lane12Pass =
            smokeReport.aeTargetFpsRangeMutated == true &&
            smokeReport.captureRequestUpdated == true &&
            smokeReport.repeatingRequestMutated == true &&
            smokeReport.frameCadenceChangeProven == false;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_12: pass=$lane12Pass aeTargetFpsRangeMutated=${smokeReport.aeTargetFpsRangeMutated} captureRequestUpdated=${smokeReport.captureRequestUpdated} repeatingRequestMutated=${smokeReport.repeatingRequestMutated} frameCadenceChangeProven=${smokeReport.frameCadenceChangeProven}',
        );

        // Lane 13: proofBoundary matches the exact expected string verbatim.
        lane13Pass = smokeReport.proofBoundary == _expectedProofBoundary;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_13: pass=$lane13Pass proofBoundary=${smokeReport.proofBoundary}',
        );

        // Lane 14: sessionConfigureCount == 1, surfaceCount == 1, reusedRequestBuilder true, cameraSessionReconfigured false.
        lane14Pass =
            smokeReport.sessionConfigureCount == 1 &&
            smokeReport.surfaceCount == 1 &&
            smokeReport.reusedRequestBuilder == true &&
            smokeReport.cameraSessionReconfigured == false;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_14: pass=$lane14Pass sessionConfigureCount=${smokeReport.sessionConfigureCount} surfaceCount=${smokeReport.surfaceCount} reusedRequestBuilder=${smokeReport.reusedRequestBuilder} cameraSessionReconfigured=${smokeReport.cameraSessionReconfigured}',
        );

        // Lane 15: all nonclaim booleans false.
        lane15Pass =
            smokeReport.realForcedOverheat == false &&
            smokeReport.powerManagerThermalStateMutated == false &&
            smokeReport.osThermalListenerTriggered == false &&
            smokeReport.mediaRecorderCreated == false &&
            smokeReport.encoderTouched == false &&
            smokeReport.rendererTouched == false &&
            smokeReport.productUiTouched == false &&
            smokeReport.secondaryCameraOpened == false &&
            smokeReport.secondaryCameraDisabled == false &&
            smokeReport.productCameraSessionTouched == false &&
            smokeReport.cameraSessionReconfigured == false;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_15: pass=$lane15Pass realForcedOverheat=${smokeReport.realForcedOverheat} powerManagerThermalStateMutated=${smokeReport.powerManagerThermalStateMutated} osThermalListenerTriggered=${smokeReport.osThermalListenerTriggered} mediaRecorderCreated=${smokeReport.mediaRecorderCreated} encoderTouched=${smokeReport.encoderTouched} rendererTouched=${smokeReport.rendererTouched} productUiTouched=${smokeReport.productUiTouched} secondaryCameraOpened=${smokeReport.secondaryCameraOpened} secondaryCameraDisabled=${smokeReport.secondaryCameraDisabled} productCameraSessionTouched=${smokeReport.productCameraSessionTouched}',
        );

        // Lane 16: report.sessionClosed true, deviceClosed true, imageReaderClosed true, isCleanedUp true.
        lane16Pass =
            smokeReport.sessionClosed == true &&
            smokeReport.deviceClosed == true &&
            smokeReport.imageReaderClosed == true &&
            smokeReport.isCleanedUp == true;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_16: pass=$lane16Pass sessionClosed=${smokeReport.sessionClosed} deviceClosed=${smokeReport.deviceClosed} imageReaderClosed=${smokeReport.imageReaderClosed} isCleanedUp=${smokeReport.isCleanedUp}',
        );

        // Lane 17: getters/toMap coherent.
        final map = smokeReport.toMap();
        gettersCoherent =
            smokeReport.isFpsRangeMutated ==
                (smokeReport.decision ==
                    VGCamera2ThermalFpsActionSmokeDecision.fpsRangeMutated) &&
            smokeReport.isPermissionRequired ==
                (smokeReport.decision ==
                    VGCamera2ThermalFpsActionSmokeDecision
                        .permissionRequired) &&
            smokeReport.isAttempted == smokeReport.attemptedOpen &&
            smokeReport.isCleanedUp ==
                (smokeReport.sessionClosed &&
                    smokeReport.deviceClosed &&
                    smokeReport.imageReaderClosed);

        mapMatches =
            map['success'] == smokeReport.success &&
            map['decision'] == smokeReport.decision.name &&
            listEquals(map['reasons'] as List?, smokeReport.reasons) &&
            listEquals(map['events'] as List?, smokeReport.events) &&
            mapEquals(
              map['diagnostics'] as Map<String, Object?>?,
              smokeReport.diagnostics,
            ) &&
            map['proofBoundary'] == smokeReport.proofBoundary &&
            map['apiLevel'] == smokeReport.apiLevel &&
            map['hasCameraPermission'] == smokeReport.hasCameraPermission &&
            map['attemptedOpen'] == smokeReport.attemptedOpen &&
            map['opened'] == smokeReport.opened &&
            map['sessionConfigured'] == smokeReport.sessionConfigured &&
            map['initialRepeatingStarted'] ==
                smokeReport.initialRepeatingStarted &&
            map['updatedRepeatingStarted'] ==
                smokeReport.updatedRepeatingStarted &&
            map['initialCaptureCompleted'] ==
                smokeReport.initialCaptureCompleted &&
            map['updatedCaptureCompleted'] ==
                smokeReport.updatedCaptureCompleted &&
            map['updatedConsecutiveCaptureCount'] ==
                smokeReport.updatedConsecutiveCaptureCount &&
            map['cameraId'] == smokeReport.cameraId &&
            map['selectedLensFacing'] == smokeReport.selectedLensFacing &&
            map['selectedWidth'] == smokeReport.selectedWidth &&
            map['selectedHeight'] == smokeReport.selectedHeight &&
            map['imageFormatName'] == smokeReport.imageFormatName &&
            map['templateUsed'] == smokeReport.templateUsed &&
            map['policyTargetFps'] == smokeReport.policyTargetFps &&
            map['syntheticPolicyInput'] == smokeReport.syntheticPolicyInput &&
            map['thermalStateRaw'] == smokeReport.thermalStateRaw &&
            map['wasRecordingPolicyInput'] ==
                smokeReport.wasRecordingPolicyInput &&
            map['hadSecondaryCameraPolicyInput'] ==
                smokeReport.hadSecondaryCameraPolicyInput &&
            map['recordingActive'] == smokeReport.recordingActive &&
            map['aeTargetFpsRangeMutated'] ==
                smokeReport.aeTargetFpsRangeMutated &&
            map['captureRequestUpdated'] == smokeReport.captureRequestUpdated &&
            map['repeatingRequestMutated'] ==
                smokeReport.repeatingRequestMutated &&
            map['hardwareAppliedRangeConfirmed'] ==
                smokeReport.hardwareAppliedRangeConfirmed &&
            map['frameCadenceChangeProven'] ==
                smokeReport.frameCadenceChangeProven &&
            map['sessionConfigureCount'] == smokeReport.sessionConfigureCount &&
            map['surfaceCount'] == smokeReport.surfaceCount &&
            map['reusedRequestBuilder'] == smokeReport.reusedRequestBuilder &&
            map['sessionClosed'] == smokeReport.sessionClosed &&
            map['deviceClosed'] == smokeReport.deviceClosed &&
            map['imageReaderClosed'] == smokeReport.imageReaderClosed &&
            map['durationMs'] == smokeReport.durationMs &&
            map['realForcedOverheat'] == smokeReport.realForcedOverheat &&
            map['powerManagerThermalStateMutated'] ==
                smokeReport.powerManagerThermalStateMutated &&
            map['osThermalListenerTriggered'] ==
                smokeReport.osThermalListenerTriggered &&
            map['mediaRecorderCreated'] == smokeReport.mediaRecorderCreated &&
            map['encoderTouched'] == smokeReport.encoderTouched &&
            map['rendererTouched'] == smokeReport.rendererTouched &&
            map['productUiTouched'] == smokeReport.productUiTouched &&
            map['secondaryCameraOpened'] == smokeReport.secondaryCameraOpened &&
            map['secondaryCameraDisabled'] ==
                smokeReport.secondaryCameraDisabled &&
            map['productCameraSessionTouched'] ==
                smokeReport.productCameraSessionTouched &&
            map['cameraSessionReconfigured'] ==
                smokeReport.cameraSessionReconfigured;

        lane17Pass = gettersCoherent && mapMatches;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_LANE_17: pass=$lane17Pass gettersCoherent=$gettersCoherent mapMatches=$mapMatches',
        );
      }
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Camera2 Thermal FPS Action Smoke exceeded timeout: $te';
      print(
        'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_PHYSICAL_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_PHYSICAL_SMOKE_ERROR: $topLevelError',
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
          lane16Pass &&
          lane17Pass &&
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2ThermalFpsActionSmokeHarness',
        'slice': 'P3-CAM-THERMAL-ACT-FPS-REQUEST-ACTION',
        'target': 'android_physical',
        'pass': allPass,
        'lanes': <String, dynamic>{
          'lane1_probeSuccessApiLevelGte24CameraCountGte1': {
            'pass': lane1Pass,
            'success': probeReport?.success,
            'apiLevel': probeReport?.apiLevel,
            'cameraCount': probeReport?.cameraCount,
            'camerasLength': probeReport?.cameras.length,
          },
          'lane2_probeHasCameraPermissionTrue': {
            'pass': lane2Pass,
            'hasCameraPermission': probeReport?.hasCameraPermission,
          },
          'lane3_primaryCameraIdSelectedAndExists': {
            'pass': lane3Pass,
            'primaryCameraId': primary?.cameraId,
            'lensFacing': primary?.lensFacing,
          },
          'lane4_smokeReportSuccessTrueDecisionFpsRangeMutated': {
            'pass': lane4Pass,
            'success': smokeReport?.success,
            'decision': smokeReport?.decision.name,
          },
          'lane5_smokeReportHasCameraPermissionAndAttemptedOpenTrue': {
            'pass': lane5Pass,
            'hasCameraPermission': smokeReport?.hasCameraPermission,
            'attemptedOpen': smokeReport?.attemptedOpen,
          },
          'lane6_smokeReportOpenedSessionConfiguredConfigureCountOne': {
            'pass': lane6Pass,
            'opened': smokeReport?.opened,
            'sessionConfigured': smokeReport?.sessionConfigured,
            'sessionConfigureCount': smokeReport?.sessionConfigureCount,
          },
          'lane7_smokeReportInitialRepeatingStartedAndCaptureCompleted': {
            'pass': lane7Pass,
            'initialRepeatingStarted': smokeReport?.initialRepeatingStarted,
            'initialCaptureCompleted': smokeReport?.initialCaptureCompleted,
            'events': smokeReport?.events,
          },
          'lane8_smokeReportUpdatedRepeatingStartedAndThermalActionTriggered': {
            'pass': lane8Pass,
            'updatedRepeatingStarted': smokeReport?.updatedRepeatingStarted,
            'events': smokeReport?.events,
          },
          'lane9_smokeReportUpdatedCaptureCompletedConsecutiveCountGte2': {
            'pass': lane9Pass,
            'updatedCaptureCompleted': smokeReport?.updatedCaptureCompleted,
            'updatedConsecutiveCaptureCount':
                smokeReport?.updatedConsecutiveCaptureCount,
          },
          'lane10_reducedRangeStrictlyLowerThanInitialRange': {
            'pass': lane10Pass,
            'initialAeTargetFpsRange': smokeReport?.initialAeTargetFpsRange
                ?.toMap(),
            'reducedAeTargetFpsRange': smokeReport?.reducedAeTargetFpsRange
                ?.toMap(),
          },
          'lane11_syntheticPolicyTupleExact': {
            'pass': lane11Pass,
            'syntheticPolicyInput': smokeReport?.syntheticPolicyInput,
            'thermalStateRaw': smokeReport?.thermalStateRaw,
            'wasRecordingPolicyInput': smokeReport?.wasRecordingPolicyInput,
            'hadSecondaryCameraPolicyInput':
                smokeReport?.hadSecondaryCameraPolicyInput,
            'recordingActive': smokeReport?.recordingActive,
          },
          'lane12_aeTargetFpsRangeMutatedTrueFrameCadenceProvenFalse': {
            'pass': lane12Pass,
            'aeTargetFpsRangeMutated': smokeReport?.aeTargetFpsRangeMutated,
            'captureRequestUpdated': smokeReport?.captureRequestUpdated,
            'repeatingRequestMutated': smokeReport?.repeatingRequestMutated,
            'frameCadenceChangeProven': smokeReport?.frameCadenceChangeProven,
          },
          'lane13_proofBoundaryVerbatim': {
            'pass': lane13Pass,
            'proofBoundary': smokeReport?.proofBoundary,
            'expected': _expectedProofBoundary,
          },
          'lane14_sessionConfigureCountSurfaceCountReusedBuilderNotReconfigured':
              {
                'pass': lane14Pass,
                'sessionConfigureCount': smokeReport?.sessionConfigureCount,
                'surfaceCount': smokeReport?.surfaceCount,
                'reusedRequestBuilder': smokeReport?.reusedRequestBuilder,
                'cameraSessionReconfigured':
                    smokeReport?.cameraSessionReconfigured,
              },
          'lane15_allNonclaimsFalse': {
            'pass': lane15Pass,
            'realForcedOverheat': smokeReport?.realForcedOverheat,
            'powerManagerThermalStateMutated':
                smokeReport?.powerManagerThermalStateMutated,
            'osThermalListenerTriggered':
                smokeReport?.osThermalListenerTriggered,
            'mediaRecorderCreated': smokeReport?.mediaRecorderCreated,
            'encoderTouched': smokeReport?.encoderTouched,
            'rendererTouched': smokeReport?.rendererTouched,
            'productUiTouched': smokeReport?.productUiTouched,
            'secondaryCameraOpened': smokeReport?.secondaryCameraOpened,
            'secondaryCameraDisabled': smokeReport?.secondaryCameraDisabled,
            'productCameraSessionTouched':
                smokeReport?.productCameraSessionTouched,
          },
          'lane16_smokeReportSessionDeviceReaderClosedAndIsCleanedUpTrue': {
            'pass': lane16Pass,
            'sessionClosed': smokeReport?.sessionClosed,
            'deviceClosed': smokeReport?.deviceClosed,
            'imageReaderClosed': smokeReport?.imageReaderClosed,
            'isCleanedUp': smokeReport?.isCleanedUp,
          },
          'lane17_smokeReportGettersAndToMapCoherent': {
            'pass': lane17Pass,
            'gettersCoherent': gettersCoherent,
            'mapMatches': mapMatches,
          },
        },
        'probeReport': probeReport?.toMap(),
        'smokeReport': smokeReport?.toMap(),
        'error': topLevelError,
      };

      print(
        'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_PHYSICAL_SMOKE_PASS'
            : 'ANDROID_DAG_PHASE3_THERMAL_FPS_ACTION_PHYSICAL_SMOKE_FAIL',
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
