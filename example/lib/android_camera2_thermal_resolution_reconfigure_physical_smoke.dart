// android_camera2_thermal_resolution_reconfigure_physical_smoke.dart
// Vanguard Media Engine - P3-CAM-THERMAL-ACT-RESOLUTION-RECONFIG-DIAGNOSTIC:
// Android Camera2 Single-Camera Resolution Session Reconfiguration Physical
// Smoke.
//
// Proof lanes:
//   Lane 1: probe success true, apiLevel >= 24, cameraCount >= 1, cameras not empty.
//   Lane 2: probe hasCameraPermission true, proving adb grant path active with no permission UI.
//   Lane 3: selected primary camera id nonblank and exists in probe cameras.
//   Lane 4: opt-in load-shedding plan decision == reduceResolution, targetResolutionScale == 0.5.
//   Lane 5: smoke report success true and decision == resolutionReconfigured.
//   Lane 6: report.hasCameraPermission true and attemptedOpen true.
//   Lane 7: report.opened true, cameraDeviceOpenCount == 1, sameCameraDeviceReused true.
//   Lane 8: report.firstSessionConfigured true, firstRepeatingStarted true, firstFrameObserved true.
//   Lane 9: report.firstSessionClosed true, firstReaderClosed true, events show close before second configure.
//   Lane 10: report.secondSessionConfigured true, secondRepeatingStarted true, secondFrameObserved true.
//   Lane 11: reduced area strictly lower than initial area (isReducedAreaStrictlyLower true).
//   Lane 12: report.sessionConfigureCount == 2, surfaceCountPerSession == 1.
//   Lane 13: report.resolutionReconfigured true and cameraSessionReconfigured true.
//   Lane 14: report.syntheticPolicyInput true, thermalStateRaw == 2, wasRecordingPolicyInput true, hadSecondaryCameraPolicyInput false, recordingActive false.
//   Lane 15: all nonclaim booleans false (realForcedOverheat, powerManagerThermalStateMutated, osThermalListenerTriggered, mediaRecorderCreated, encoderTouched, rendererTouched, productUiTouched, secondaryCameraOpened, secondaryCameraDisabled, productCameraSessionTouched, cameraXPathProven, productionRecordingRebindProven, frameCadenceChangeProven).
//   Lane 16: report.deviceClosed true, isCleanedUp true.
//   Lane 17: report.proofBoundary matches the exact expected string verbatim.
//   Lane 18: getters/toMap coherent.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _expectedProofBoundary =
    'single_camera_resolution_session_reconfigure_policy_derived_no_forced_heat_no_recording_no_encoder_no_product';

void main() {
  runApp(const AndroidCamera2ThermalResolutionReconfigurePhysicalSmokeApp());
}

class AndroidCamera2ThermalResolutionReconfigurePhysicalSmokeApp
    extends StatefulWidget {
  const AndroidCamera2ThermalResolutionReconfigurePhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2ThermalResolutionReconfigurePhysicalSmokeApp>
  createState() =>
      _AndroidCamera2ThermalResolutionReconfigurePhysicalSmokeAppState();
}

class _AndroidCamera2ThermalResolutionReconfigurePhysicalSmokeAppState
    extends State<AndroidCamera2ThermalResolutionReconfigurePhysicalSmokeApp> {
  String _status =
      'Initializing Camera2 Thermal Resolution Reconfigure Physical Smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(
      'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_PHYSICAL_SMOKE_START',
    );
    String? topLevelError;
    VGCameraHardwareCapabilityReport? probeReport;
    VGCameraHardwareDeviceCapability? primary;
    VGCamera2ThermalLoadSheddingPlan? plan;
    VGCamera2ThermalResolutionReconfigureSmokeReport? smokeReport;

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
    var lane18Pass = false;
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
        'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_1: pass=$lane1Pass success=${probeReport.success} apiLevel=${probeReport.apiLevel} cameraCount=${probeReport.cameraCount} camerasLength=${probeReport.cameras.length}',
      );

      // Lane 2: probe hasCameraPermission true, proving adb grant path active with no permission UI.
      lane2Pass = probeReport.hasCameraPermission == true;
      print(
        'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_2: pass=$lane2Pass hasCameraPermission=${probeReport.hasCameraPermission}',
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
        'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_3: pass=$lane3Pass primaryCameraId=${primaryCam?.cameraId} lensFacing=${primaryCam?.lensFacing}',
      );

      // 3. Derive the opt-in resolution-step thermal policy plan; assert reduceResolution
      //    before invoking the native typed client - the native harness never invents policy.
      const planner = VGCamera2ThermalLoadSheddingPlanner(
        allowResolutionStep: true,
      );
      plan = planner.evaluate(
        thermalState: VGThermalState.serious,
        wasRecording: true,
        hadSecondaryCamera: false,
        currentFps: 15,
        currentResolutionScale: 1.0,
        canPreserveEncoderContract: true,
      );

      // Lane 4: opt-in load-shedding plan decision == reduceResolution, targetResolutionScale == 0.5.
      lane4Pass =
          plan.decision ==
              VGCamera2ThermalLoadSheddingDecision.reduceResolution &&
          plan.targetResolutionScale == 0.5;
      print(
        'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_4: pass=$lane4Pass decision=${plan.decision.name} targetResolutionScale=${plan.targetResolutionScale}',
      );

      // 4. Execute Camera2 Thermal Resolution Reconfigure Smoke.
      if (lane1Pass && lane2Pass && lane3Pass && lane4Pass) {
        smokeReport =
            await VGCamera2ThermalResolutionReconfigureSmokeReport.runAndroidCamera2ThermalResolutionReconfigureSmoke(
              cameraId: primaryCam.cameraId,
              policyDecision: plan.decision.name,
              policyTargetResolutionScale: plan.targetResolutionScale,
              timeout: const Duration(seconds: 10),
              maxWidth: 640,
              maxHeight: 480,
            ).timeout(const Duration(seconds: 30));

        // Lane 5: smoke report success true and decision == resolutionReconfigured.
        lane5Pass =
            smokeReport.success == true &&
            smokeReport.decision ==
                VGCamera2ThermalResolutionReconfigureSmokeDecision
                    .resolutionReconfigured;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_5: pass=$lane5Pass success=${smokeReport.success} decision=${smokeReport.decision.name}',
        );

        // Lane 6: report.hasCameraPermission true and attemptedOpen true.
        lane6Pass =
            smokeReport.hasCameraPermission == true &&
            smokeReport.attemptedOpen == true;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_6: pass=$lane6Pass hasCameraPermission=${smokeReport.hasCameraPermission} attemptedOpen=${smokeReport.attemptedOpen}',
        );

        // Lane 7: report.opened true, cameraDeviceOpenCount == 1, sameCameraDeviceReused true.
        lane7Pass =
            smokeReport.opened == true &&
            smokeReport.cameraDeviceOpenCount == 1 &&
            smokeReport.sameCameraDeviceReused == true;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_7: pass=$lane7Pass opened=${smokeReport.opened} cameraDeviceOpenCount=${smokeReport.cameraDeviceOpenCount} sameCameraDeviceReused=${smokeReport.sameCameraDeviceReused}',
        );

        // Lane 8: report.firstSessionConfigured true, firstRepeatingStarted true, firstFrameObserved true.
        lane8Pass =
            smokeReport.firstSessionConfigured == true &&
            smokeReport.firstRepeatingStarted == true &&
            smokeReport.firstFrameObserved == true;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_8: pass=$lane8Pass firstSessionConfigured=${smokeReport.firstSessionConfigured} firstRepeatingStarted=${smokeReport.firstRepeatingStarted} firstFrameObserved=${smokeReport.firstFrameObserved}',
        );

        // Lane 9: report.firstSessionClosed true, firstReaderClosed true, events show close before second configure.
        final firstClosedIndex = smokeReport.events.indexOf(
          'onFirstSessionClosed',
        );
        final secondConfiguredIndex = smokeReport.events.indexOf(
          'onSecondConfigured',
        );
        lane9Pass =
            smokeReport.firstSessionClosed == true &&
            smokeReport.firstReaderClosed == true &&
            firstClosedIndex >= 0 &&
            secondConfiguredIndex >= 0 &&
            firstClosedIndex < secondConfiguredIndex;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_9: pass=$lane9Pass firstSessionClosed=${smokeReport.firstSessionClosed} firstReaderClosed=${smokeReport.firstReaderClosed} firstClosedIndex=$firstClosedIndex secondConfiguredIndex=$secondConfiguredIndex',
        );

        // Lane 10: report.secondSessionConfigured true, secondRepeatingStarted true, secondFrameObserved true.
        lane10Pass =
            smokeReport.secondSessionConfigured == true &&
            smokeReport.secondRepeatingStarted == true &&
            smokeReport.secondFrameObserved == true;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_10: pass=$lane10Pass secondSessionConfigured=${smokeReport.secondSessionConfigured} secondRepeatingStarted=${smokeReport.secondRepeatingStarted} secondFrameObserved=${smokeReport.secondFrameObserved}',
        );

        // Lane 11: reduced area strictly lower than initial area.
        lane11Pass = smokeReport.isReducedAreaStrictlyLower == true;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_11: pass=$lane11Pass initialSize=${smokeReport.initialSize} reducedSize=${smokeReport.reducedSize} initialArea=${smokeReport.initialArea} reducedArea=${smokeReport.reducedArea}',
        );

        // Lane 12: report.sessionConfigureCount == 2, surfaceCountPerSession == 1.
        lane12Pass =
            smokeReport.sessionConfigureCount == 2 &&
            smokeReport.surfaceCountPerSession == 1;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_12: pass=$lane12Pass sessionConfigureCount=${smokeReport.sessionConfigureCount} surfaceCountPerSession=${smokeReport.surfaceCountPerSession}',
        );

        // Lane 13: report.resolutionReconfigured true and cameraSessionReconfigured true.
        lane13Pass =
            smokeReport.resolutionReconfigured == true &&
            smokeReport.cameraSessionReconfigured == true;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_13: pass=$lane13Pass resolutionReconfigured=${smokeReport.resolutionReconfigured} cameraSessionReconfigured=${smokeReport.cameraSessionReconfigured}',
        );

        // Lane 14: synthetic policy tuple exact.
        lane14Pass =
            smokeReport.syntheticPolicyInput == true &&
            smokeReport.thermalStateRaw == 2 &&
            smokeReport.wasRecordingPolicyInput == true &&
            smokeReport.hadSecondaryCameraPolicyInput == false &&
            smokeReport.recordingActive == false;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_14: pass=$lane14Pass syntheticPolicyInput=${smokeReport.syntheticPolicyInput} thermalStateRaw=${smokeReport.thermalStateRaw} wasRecordingPolicyInput=${smokeReport.wasRecordingPolicyInput} hadSecondaryCameraPolicyInput=${smokeReport.hadSecondaryCameraPolicyInput} recordingActive=${smokeReport.recordingActive}',
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
            smokeReport.cameraXPathProven == false &&
            smokeReport.productionRecordingRebindProven == false &&
            smokeReport.frameCadenceChangeProven == false;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_15: pass=$lane15Pass realForcedOverheat=${smokeReport.realForcedOverheat} powerManagerThermalStateMutated=${smokeReport.powerManagerThermalStateMutated} osThermalListenerTriggered=${smokeReport.osThermalListenerTriggered} mediaRecorderCreated=${smokeReport.mediaRecorderCreated} encoderTouched=${smokeReport.encoderTouched} rendererTouched=${smokeReport.rendererTouched} productUiTouched=${smokeReport.productUiTouched} secondaryCameraOpened=${smokeReport.secondaryCameraOpened} secondaryCameraDisabled=${smokeReport.secondaryCameraDisabled} productCameraSessionTouched=${smokeReport.productCameraSessionTouched} cameraXPathProven=${smokeReport.cameraXPathProven} productionRecordingRebindProven=${smokeReport.productionRecordingRebindProven} frameCadenceChangeProven=${smokeReport.frameCadenceChangeProven}',
        );

        // Lane 16: report.deviceClosed true, isCleanedUp true.
        lane16Pass =
            smokeReport.deviceClosed == true && smokeReport.isCleanedUp == true;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_16: pass=$lane16Pass deviceClosed=${smokeReport.deviceClosed} isCleanedUp=${smokeReport.isCleanedUp}',
        );

        // Lane 17: proofBoundary matches the exact expected string verbatim.
        lane17Pass = smokeReport.proofBoundary == _expectedProofBoundary;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_17: pass=$lane17Pass proofBoundary=${smokeReport.proofBoundary}',
        );

        // Lane 18: getters/toMap coherent.
        final map = smokeReport.toMap();
        gettersCoherent =
            smokeReport.isResolutionReconfigured ==
                (smokeReport.decision ==
                    VGCamera2ThermalResolutionReconfigureSmokeDecision
                        .resolutionReconfigured) &&
            smokeReport.isPermissionRequired ==
                (smokeReport.decision ==
                    VGCamera2ThermalResolutionReconfigureSmokeDecision
                        .permissionRequired) &&
            smokeReport.isAttempted == smokeReport.attemptedOpen &&
            smokeReport.isCleanedUp ==
                (smokeReport.firstSessionClosed &&
                    smokeReport.firstReaderClosed &&
                    smokeReport.secondSessionClosed &&
                    smokeReport.secondReaderClosed &&
                    smokeReport.deviceClosed) &&
            smokeReport.isReducedAreaStrictlyLower ==
                (smokeReport.initialArea != null &&
                    smokeReport.reducedArea != null &&
                    smokeReport.reducedArea! < smokeReport.initialArea!);

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
            map['cameraDeviceOpenCount'] == smokeReport.cameraDeviceOpenCount &&
            map['sameCameraDeviceReused'] ==
                smokeReport.sameCameraDeviceReused &&
            map['cameraId'] == smokeReport.cameraId &&
            map['selectedLensFacing'] == smokeReport.selectedLensFacing &&
            map['initialArea'] == smokeReport.initialArea &&
            map['reducedArea'] == smokeReport.reducedArea &&
            map['policyDecision'] == smokeReport.policyDecision &&
            map['policyTargetResolutionScale'] ==
                smokeReport.policyTargetResolutionScale &&
            map['policyDerivedResolutionTarget'] ==
                smokeReport.policyDerivedResolutionTarget &&
            map['syntheticPolicyInput'] == smokeReport.syntheticPolicyInput &&
            map['thermalStateRaw'] == smokeReport.thermalStateRaw &&
            map['wasRecordingPolicyInput'] ==
                smokeReport.wasRecordingPolicyInput &&
            map['hadSecondaryCameraPolicyInput'] ==
                smokeReport.hadSecondaryCameraPolicyInput &&
            map['recordingActive'] == smokeReport.recordingActive &&
            map['firstSessionConfigured'] ==
                smokeReport.firstSessionConfigured &&
            map['firstRepeatingStarted'] == smokeReport.firstRepeatingStarted &&
            map['firstFrameObserved'] == smokeReport.firstFrameObserved &&
            map['firstSessionClosed'] == smokeReport.firstSessionClosed &&
            map['firstReaderClosed'] == smokeReport.firstReaderClosed &&
            map['secondSessionConfigured'] ==
                smokeReport.secondSessionConfigured &&
            map['secondRepeatingStarted'] ==
                smokeReport.secondRepeatingStarted &&
            map['secondFrameObserved'] == smokeReport.secondFrameObserved &&
            map['secondSessionClosed'] == smokeReport.secondSessionClosed &&
            map['secondReaderClosed'] == smokeReport.secondReaderClosed &&
            map['deviceClosed'] == smokeReport.deviceClosed &&
            map['sessionConfigureCount'] == smokeReport.sessionConfigureCount &&
            map['surfaceCountPerSession'] ==
                smokeReport.surfaceCountPerSession &&
            map['resolutionReconfigured'] ==
                smokeReport.resolutionReconfigured &&
            map['cameraSessionReconfigured'] ==
                smokeReport.cameraSessionReconfigured &&
            map['frameCadenceChangeProven'] ==
                smokeReport.frameCadenceChangeProven &&
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
            map['cameraXPathProven'] == smokeReport.cameraXPathProven &&
            map['productionRecordingRebindProven'] ==
                smokeReport.productionRecordingRebindProven;

        lane18Pass = gettersCoherent && mapMatches;
        print(
          'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_LANE_18: pass=$lane18Pass gettersCoherent=$gettersCoherent mapMatches=$mapMatches',
        );
      }
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Camera2 Thermal Resolution Reconfigure Smoke exceeded timeout: $te';
      print(
        'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_PHYSICAL_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_PHYSICAL_SMOKE_ERROR: $topLevelError',
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
          lane18Pass &&
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCamera2ThermalResolutionReconfigureSmokeHarness',
        'slice': 'P3-CAM-THERMAL-ACT-RESOLUTION-RECONFIG-DIAGNOSTIC',
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
          'lane4_planReduceResolutionTargetScaleHalf': {
            'pass': lane4Pass,
            'decision': plan?.decision.name,
            'targetResolutionScale': plan?.targetResolutionScale,
          },
          'lane5_smokeReportSuccessTrueDecisionResolutionReconfigured': {
            'pass': lane5Pass,
            'success': smokeReport?.success,
            'decision': smokeReport?.decision.name,
          },
          'lane6_smokeReportHasCameraPermissionAndAttemptedOpenTrue': {
            'pass': lane6Pass,
            'hasCameraPermission': smokeReport?.hasCameraPermission,
            'attemptedOpen': smokeReport?.attemptedOpen,
          },
          'lane7_smokeReportOpenedOneDeviceOpenReused': {
            'pass': lane7Pass,
            'opened': smokeReport?.opened,
            'cameraDeviceOpenCount': smokeReport?.cameraDeviceOpenCount,
            'sameCameraDeviceReused': smokeReport?.sameCameraDeviceReused,
          },
          'lane8_smokeReportFirstSessionConfiguredRepeatingFrameObserved': {
            'pass': lane8Pass,
            'firstSessionConfigured': smokeReport?.firstSessionConfigured,
            'firstRepeatingStarted': smokeReport?.firstRepeatingStarted,
            'firstFrameObserved': smokeReport?.firstFrameObserved,
          },
          'lane9_smokeReportFirstSessionReaderClosedBeforeSecondConfigure': {
            'pass': lane9Pass,
            'firstSessionClosed': smokeReport?.firstSessionClosed,
            'firstReaderClosed': smokeReport?.firstReaderClosed,
            'events': smokeReport?.events,
          },
          'lane10_smokeReportSecondSessionConfiguredRepeatingFrameObserved': {
            'pass': lane10Pass,
            'secondSessionConfigured': smokeReport?.secondSessionConfigured,
            'secondRepeatingStarted': smokeReport?.secondRepeatingStarted,
            'secondFrameObserved': smokeReport?.secondFrameObserved,
          },
          'lane11_reducedAreaStrictlyLowerThanInitialArea': {
            'pass': lane11Pass,
            'initialSize': smokeReport?.initialSize?.toMap(),
            'reducedSize': smokeReport?.reducedSize?.toMap(),
            'initialArea': smokeReport?.initialArea,
            'reducedArea': smokeReport?.reducedArea,
          },
          'lane12_sessionConfigureCountTwoSurfaceCountPerSessionOne': {
            'pass': lane12Pass,
            'sessionConfigureCount': smokeReport?.sessionConfigureCount,
            'surfaceCountPerSession': smokeReport?.surfaceCountPerSession,
          },
          'lane13_resolutionReconfiguredAndCameraSessionReconfiguredTrue': {
            'pass': lane13Pass,
            'resolutionReconfigured': smokeReport?.resolutionReconfigured,
            'cameraSessionReconfigured': smokeReport?.cameraSessionReconfigured,
          },
          'lane14_syntheticPolicyTupleExact': {
            'pass': lane14Pass,
            'syntheticPolicyInput': smokeReport?.syntheticPolicyInput,
            'thermalStateRaw': smokeReport?.thermalStateRaw,
            'wasRecordingPolicyInput': smokeReport?.wasRecordingPolicyInput,
            'hadSecondaryCameraPolicyInput':
                smokeReport?.hadSecondaryCameraPolicyInput,
            'recordingActive': smokeReport?.recordingActive,
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
            'cameraXPathProven': smokeReport?.cameraXPathProven,
            'productionRecordingRebindProven':
                smokeReport?.productionRecordingRebindProven,
            'frameCadenceChangeProven': smokeReport?.frameCadenceChangeProven,
          },
          'lane16_smokeReportDeviceClosedAndIsCleanedUpTrue': {
            'pass': lane16Pass,
            'deviceClosed': smokeReport?.deviceClosed,
            'isCleanedUp': smokeReport?.isCleanedUp,
          },
          'lane17_proofBoundaryVerbatim': {
            'pass': lane17Pass,
            'proofBoundary': smokeReport?.proofBoundary,
            'expected': _expectedProofBoundary,
          },
          'lane18_smokeReportGettersAndToMapCoherent': {
            'pass': lane18Pass,
            'gettersCoherent': gettersCoherent,
            'mapMatches': mapMatches,
          },
        },
        'probeReport': probeReport?.toMap(),
        'plan': plan?.toMap(),
        'smokeReport': smokeReport?.toMap(),
        'error': topLevelError,
      };

      print(
        'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_PHYSICAL_SMOKE_PASS'
            : 'ANDROID_DAG_PHASE3_THERMAL_RESOLUTION_RECONFIGURE_PHYSICAL_SMOKE_FAIL',
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
