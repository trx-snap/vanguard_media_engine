// android_camerax_thermal_fps_bridge_physical_smoke.dart
// Vanguard Media Engine -- P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE: Android
// True-DAG foundation production bridge physical smoke.
//
// Proof boundary:
//   camerax_repeating_request_ae_fps_mutation_synthetic_thermal_no_rebind_no_forced_heat_no_product
//
// Proof lanes:
//   Lane 1: startCamera returns a valid non-negative textureId.
//   Lane 2: isCameraReady polls true within the timeout window.
//   Lane 3: diagnostics-before is a running session with the expected
//     textureId, bindGeneration/bindCount/surfaceRequestCount >= 1, an
//     observed AE target FPS upper bound, and no applied range yet.
//   Lane 4: VGCamera2ThermalLoadSheddingPlanner (serious, wasRecording=true,
//     hadSecondaryCamera=false, currentFps=observedUpper) decides
//     reduceFrameRate with a strictly-lower targetFps.
//   Lane 5: applyAndroidCameraXThermalTargetFps(plan.targetFps) selects a
//     range whose upper bound is strictly below the pre-apply observed upper.
//   Lane 6: diagnostics polled after apply reach >= 2 consecutive completed
//     captures observing the applied/selected range.
//   Lane 7: no-rebind proof -- textureId/bindGeneration/bindCount/
//     surfaceRequestCount/cameraProviderIdentity are unchanged across the
//     apply.
//   Lane 8: isRecording and isRecordingActive are false throughout.
//   Lane 9: the apply result's proofBoundary matches the expected boundary
//     and its nonClaims match this file's expected all-false map.
//
// Nonclaims (all false): midRecordingActuationProven, osThermalListenerWired,
// resolutionReconfigured, secondaryCameraTouched, realForcedOverheat,
// encoderTouched, rendererTouched, productUiWired.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _expectedProofBoundary =
    'camerax_repeating_request_ae_fps_mutation_synthetic_thermal_no_rebind_no_forced_heat_no_product';

const Map<String, bool> _nonClaims = <String, bool>{
  'midRecordingActuationProven': false,
  'osThermalListenerWired': false,
  'resolutionReconfigured': false,
  'secondaryCameraTouched': false,
  'realForcedOverheat': false,
  'encoderTouched': false,
  'rendererTouched': false,
  'productUiWired': false,
};

void main() {
  runApp(const AndroidCameraXThermalFpsBridgePhysicalSmokeApp());
}

class AndroidCameraXThermalFpsBridgePhysicalSmokeApp extends StatefulWidget {
  const AndroidCameraXThermalFpsBridgePhysicalSmokeApp({super.key});

  @override
  State<AndroidCameraXThermalFpsBridgePhysicalSmokeApp> createState() =>
      _AndroidCameraXThermalFpsBridgePhysicalSmokeAppState();
}

class _AndroidCameraXThermalFpsBridgePhysicalSmokeAppState
    extends State<AndroidCameraXThermalFpsBridgePhysicalSmokeApp> {
  String _status = 'Initializing CameraX Thermal FPS Bridge Physical Smoke...';

  static const MethodChannel _rawChannel = MethodChannel(
    'vanguard_media_engine',
  );
  static final bridge = VGCameraXThermalFpsBridge();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<bool> _pollIsCameraReady(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final ready = await _rawChannel.invokeMethod<bool>('isCameraReady');
      if (ready == true) return true;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  Future<VGCameraXThermalFpsDiagnostics> _pollDiagnosticsUntil(
    bool Function(VGCameraXThermalFpsDiagnostics) predicate,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    var last = await bridge.getAndroidCameraXThermalFpsDiagnostics();
    while (!predicate(last) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      last = await bridge.getAndroidCameraXThermalFpsDiagnostics();
    }
    return last;
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE3_CAMERAX_THERMAL_BRIDGE_PHYSICAL_SMOKE_START');
    String? topLevelError;
    int? textureId;
    VGCameraXThermalFpsDiagnostics? diagnosticsBefore;
    VGCamera2ThermalLoadSheddingPlan? plan;
    VGCameraXThermalFpsApplyResult? applyResult;
    VGCameraXThermalFpsDiagnostics? diagnosticsAfter;
    var cameraStarted = false;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    var lane7Pass = false;
    var lane8Pass = false;
    var lane9Pass = false;

    try {
      // 0. Wait to allow the grant runner to grant CAMERA after install/start.
      await Future<void>.delayed(const Duration(seconds: 5));

      // 1. Start the production camera session.
      textureId = await VanguardEngine.startCamera(
        position: 1,
        fps: 30,
      ).timeout(const Duration(seconds: 15));
      cameraStarted = true;

      lane1Pass = textureId >= 0;
      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_BRIDGE_LANE_1: pass=$lane1Pass textureId=$textureId',
      );

      // 2. Poll isCameraReady.
      final ready = await _pollIsCameraReady(const Duration(seconds: 15));
      lane2Pass = ready;
      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_BRIDGE_LANE_2: pass=$lane2Pass ready=$ready',
      );

      if (lane1Pass && lane2Pass) {
        // 3. Diagnostics before actuation.
        diagnosticsBefore = await _pollDiagnosticsUntil(
          (d) => d.observedAeTargetFpsUpper != null,
          const Duration(seconds: 10),
        );

        lane3Pass =
            diagnosticsBefore.running == true &&
            diagnosticsBefore.textureId == textureId &&
            diagnosticsBefore.bindGeneration >= 1 &&
            diagnosticsBefore.bindCount >= 1 &&
            diagnosticsBefore.surfaceRequestCount >= 1 &&
            diagnosticsBefore.observedAeTargetFpsUpper != null &&
            diagnosticsBefore.appliedAeTargetFpsLower == null &&
            diagnosticsBefore.appliedAeTargetFpsUpper == null;
        print(
          'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_BRIDGE_LANE_3: pass=$lane3Pass diagnosticsBefore=$diagnosticsBefore',
        );

        // 4. Derive the reduced-FPS plan from the observed current upper bound.
        final observedUpper = diagnosticsBefore.observedAeTargetFpsUpper ?? 30;
        const planner = VGCamera2ThermalLoadSheddingPlanner();
        plan = planner.evaluate(
          thermalState: VGThermalState.serious,
          wasRecording: true,
          hadSecondaryCamera: false,
          currentFps: observedUpper,
        );

        lane4Pass =
            plan.decision ==
                VGCamera2ThermalLoadSheddingDecision.reduceFrameRate &&
            plan.targetFps < observedUpper;
        print(
          'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_BRIDGE_LANE_4: pass=$lane4Pass decision=${plan.decision.name} observedUpper=$observedUpper targetFps=${plan.targetFps}',
        );

        if (lane3Pass && lane4Pass) {
          // 5. Apply the planner-derived targetFps.
          applyResult = await bridge
              .applyAndroidCameraXThermalTargetFps(plan.targetFps)
              .timeout(const Duration(seconds: 10));

          lane5Pass =
              applyResult.requestedTargetFps == plan.targetFps &&
              applyResult.selectedUpper <
                  diagnosticsBefore.observedAeTargetFpsUpper!;
          print(
            'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_BRIDGE_LANE_5: pass=$lane5Pass applyResult=$applyResult',
          );

          // 6. Poll for >= 2 consecutive completed captures on the applied range.
          diagnosticsAfter = await _pollDiagnosticsUntil(
            (d) => d.consecutiveAppliedRangeCompletedCaptures >= 2,
            const Duration(seconds: 15),
          );

          lane6Pass =
              diagnosticsAfter.consecutiveAppliedRangeCompletedCaptures >= 2 &&
              diagnosticsAfter.appliedAeTargetFpsUpper ==
                  applyResult.selectedUpper &&
              diagnosticsAfter.appliedAeTargetFpsUpper! <
                  diagnosticsBefore.observedAeTargetFpsUpper!;
          print(
            'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_BRIDGE_LANE_6: pass=$lane6Pass diagnosticsAfter=$diagnosticsAfter',
          );

          // 7. No-rebind proof.
          lane7Pass =
              diagnosticsAfter.textureId == diagnosticsBefore.textureId &&
              diagnosticsAfter.bindGeneration ==
                  diagnosticsBefore.bindGeneration &&
              diagnosticsAfter.bindCount == diagnosticsBefore.bindCount &&
              diagnosticsAfter.surfaceRequestCount ==
                  diagnosticsBefore.surfaceRequestCount &&
              diagnosticsAfter.cameraProviderIdentity ==
                  diagnosticsBefore.cameraProviderIdentity;
          print(
            'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_BRIDGE_LANE_7: pass=$lane7Pass before=$diagnosticsBefore after=$diagnosticsAfter',
          );

          // 8. Not recording throughout.
          lane8Pass =
              diagnosticsBefore.isRecording == false &&
              diagnosticsBefore.isRecordingActive == false &&
              diagnosticsAfter.isRecording == false &&
              diagnosticsAfter.isRecordingActive == false;
          print(
            'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_BRIDGE_LANE_8: pass=$lane8Pass',
          );

          // 9. Frozen-contract proof-boundary telemetry on the apply result.
          lane9Pass =
              applyResult.proofBoundary == _expectedProofBoundary &&
              mapEquals(applyResult.nonClaims, _nonClaims);
          print(
            'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_BRIDGE_LANE_9: pass=$lane9Pass '
            'proofBoundary=${applyResult.proofBoundary} nonClaims=${applyResult.nonClaims}',
          );
        }
      }
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: CameraX Thermal FPS Bridge Physical Smoke exceeded timeout: $te';
      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_BRIDGE_PHYSICAL_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_BRIDGE_PHYSICAL_SMOKE_ERROR: $topLevelError',
      );
    } finally {
      if (cameraStarted) {
        try {
          await VanguardEngine.stopCamera();
        } catch (_) {
          // Best-effort teardown -- do not mask the original failure/result.
        }
      }

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
          (topLevelError == null);

      final payload = <String, dynamic>{
        'unit': 'AndroidCameraXThermalFpsActuator',
        'slice': 'P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE',
        'target': 'android_physical',
        'pass': allPass,
        'proofBoundary': _expectedProofBoundary,
        'nonClaims': _nonClaims,
        'lanes': <String, dynamic>{
          'lane1_startCameraValidTextureId': {
            'pass': lane1Pass,
            'textureId': textureId,
          },
          'lane2_isCameraReadyPolledTrue': {'pass': lane2Pass},
          'lane3_diagnosticsBeforeCoherent': {
            'pass': lane3Pass,
            'diagnosticsBefore': diagnosticsBefore?.toMap(),
          },
          'lane4_plannerReduceFrameRate': {
            'pass': lane4Pass,
            'decision': plan?.decision.name,
            'targetFps': plan?.targetFps,
          },
          'lane5_applyResultStrictlyLower': {
            'pass': lane5Pass,
            'applyResult': applyResult?.toMap(),
          },
          'lane6_consecutiveAppliedCapturesObserved': {
            'pass': lane6Pass,
            'diagnosticsAfter': diagnosticsAfter?.toMap(),
          },
          'lane7_noRebindProof': {'pass': lane7Pass},
          'lane8_notRecording': {'pass': lane8Pass},
          'lane9_proofBoundaryAndNonClaims': {
            'pass': lane9Pass,
            'proofBoundary': applyResult?.proofBoundary,
            'nonClaims': applyResult?.nonClaims,
          },
        },
        'error': topLevelError,
      };

      print(
        'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_BRIDGE_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_BRIDGE_PHYSICAL_SMOKE_PASS'
            : 'ANDROID_DAG_PHASE3_CAMERAX_THERMAL_BRIDGE_PHYSICAL_SMOKE_FAIL',
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
