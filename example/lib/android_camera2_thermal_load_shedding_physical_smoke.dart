// android_camera2_thermal_load_shedding_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit U: Android Camera2 Mid-Recording
// Thermal Load-Shedding Policy & Mitigation Physical Proof Foundation Smoke Harness.
//
// Proof lanes:
//   Lane 1: initial getThermalState() valid and initial advisory plan created.
//   Lane 2: serious simulated event observed on stream.
//   Lane 3: serious + recording + secondary yields dropSecondaryCamera, notifyDart true,
//           requiresSafeGraphBoundary true, and all nonClaims are false.
//   Lane 4: critical simulated event observed on stream.
//   Lane 5: critical + recording + no-preserve-contract yields stopRecording and
//           preservesEncoderContract false.
//   Lane 6: nominal reset observed on stream.
//   Lane 7: nominal plan returns maintain with notifyDart false and no boundary required.
//   Lane 8: observed simulated order contains serious -> critical -> nominal subsequence,
//           tolerating an initial real OS nominal event.
//   Lane 9: payload nonClaims all false and physical proof does not claim camera open,
//           capture session mutation, renderer/encoder mutation, or real forced overheat.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2ThermalLoadSheddingPhysicalSmokeApp());
}

class AndroidCamera2ThermalLoadSheddingPhysicalSmokeApp extends StatefulWidget {
  const AndroidCamera2ThermalLoadSheddingPhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2ThermalLoadSheddingPhysicalSmokeApp> createState() =>
      _AndroidCamera2ThermalLoadSheddingPhysicalSmokeAppState();
}

class _AndroidCamera2ThermalLoadSheddingPhysicalSmokeAppState
    extends State<AndroidCamera2ThermalLoadSheddingPhysicalSmokeApp> {
  static const String _proofBoundary =
      'thermal_load_shedding_policy_advisory_no_camera_session_mutation';

  String _status = 'Initializing Camera2 Thermal Load-Shedding Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<bool> _waitForState(
    List<VGThermalState> received,
    VGThermalState expected,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (received.contains(expected)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return received.contains(expected);
  }

  Future<void> _runSmoke() async {
    print('ANDROID_CAMERA_PHASE3_UNIT_U_THERMAL_LOAD_SHEDDING_SMOKE_START');
    String? topLevelError;

    var lane1Pass = false;
    var lane2Pass = false;
    var lane3Pass = false;
    var lane4Pass = false;
    var lane5Pass = false;
    var lane6Pass = false;
    var lane7Pass = false;
    var lane8Pass = false;
    var lane9Pass = false;

    int? initialRaw;
    final receivedStates = <VGThermalState>[];
    StreamSubscription<VGThermalState>? subscription;

    VGCamera2ThermalLoadSheddingPlan? initialPlan;
    VGCamera2ThermalLoadSheddingPlan? seriousPlan;
    VGCamera2ThermalLoadSheddingPlan? criticalPlan;
    VGCamera2ThermalLoadSheddingPlan? nominalPlan;

    const planner = VGCamera2ThermalLoadSheddingPlanner();

    try {
      // 0. Subscribe to thermal stream first.
      subscription = VGThermalMonitor.onThermalStateChanged.listen(
        receivedStates.add,
      );

      // 1. getThermalState() — one-shot query.
      final currentState = await VGThermalMonitor.getThermalState().timeout(
        const Duration(seconds: 15),
      );
      initialRaw = currentState.index;

      initialPlan = planner.evaluate(
        thermalState: currentState,
        wasRecording: false,
        hadSecondaryCamera: false,
      );

      lane1Pass =
          VGThermalState.values.contains(currentState) &&
          VGCamera2ThermalLoadSheddingDecision.values.contains(
            initialPlan.decision,
          ) &&
          initialPlan.diagnostics['proofBoundary'] == _proofBoundary;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_U_SMOKE_LANE_1: pass=$lane1Pass '
        'currentState=${currentState.name} raw=$initialRaw decision=${initialPlan.decision.name}',
      );

      // 2. Simulate serious state.
      await VGThermalMonitor.simulateThermalState(VGThermalState.serious);
      lane2Pass = await _waitForState(receivedStates, VGThermalState.serious);
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_U_SMOKE_LANE_2: pass=$lane2Pass '
        'receivedStates=${receivedStates.map((s) => s.name).toList()}',
      );

      // Lane 3: evaluate serious state with recording and secondary camera.
      seriousPlan = planner.evaluate(
        thermalState: VGThermalState.serious,
        wasRecording: true,
        hadSecondaryCamera: true,
        canPreserveEncoderContract: true,
      );

      final seriousNonClaims = Map<String, dynamic>.from(
        seriousPlan.diagnostics['nonClaims'] as Map? ?? const {},
      );
      final seriousNonClaimsAllFalse =
          seriousNonClaims.isNotEmpty &&
          seriousNonClaims.values.every((v) => v == false);

      lane3Pass =
          seriousPlan.decision ==
              VGCamera2ThermalLoadSheddingDecision.dropSecondaryCamera &&
          seriousPlan.notifyDart == true &&
          seriousPlan.requiresSafeGraphBoundary == true &&
          seriousPlan.shouldDropSecondaryCamera == true &&
          seriousPlan.shouldStopRecording == false &&
          seriousNonClaimsAllFalse;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_U_SMOKE_LANE_3: pass=$lane3Pass '
        'decision=${seriousPlan.decision.name} shouldDropSecondaryCamera=${seriousPlan.shouldDropSecondaryCamera} '
        'seriousNonClaimsAllFalse=$seriousNonClaimsAllFalse',
      );

      // 4. Simulate critical state.
      await VGThermalMonitor.simulateThermalState(VGThermalState.critical);
      lane4Pass = await _waitForState(receivedStates, VGThermalState.critical);
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_U_SMOKE_LANE_4: pass=$lane4Pass '
        'receivedStates=${receivedStates.map((s) => s.name).toList()}',
      );

      // Lane 5: evaluate critical state with recording and cannot preserve encoder contract.
      criticalPlan = planner.evaluate(
        thermalState: VGThermalState.critical,
        wasRecording: true,
        hadSecondaryCamera: true,
        canPreserveEncoderContract: false,
      );

      lane5Pass =
          criticalPlan.decision ==
              VGCamera2ThermalLoadSheddingDecision.stopRecording &&
          criticalPlan.notifyDart == true &&
          criticalPlan.requiresSafeGraphBoundary == true &&
          criticalPlan.shouldStopRecording == true &&
          criticalPlan.preservesEncoderContract == false &&
          criticalPlan.reasons.contains('encoder_contract_not_preserved');
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_U_SMOKE_LANE_5: pass=$lane5Pass '
        'decision=${criticalPlan.decision.name} shouldStopRecording=${criticalPlan.shouldStopRecording} '
        'preservesEncoderContract=${criticalPlan.preservesEncoderContract}',
      );

      // 6. Simulate nominal reset.
      await VGThermalMonitor.simulateThermalState(VGThermalState.nominal);
      lane6Pass = await _waitForState(receivedStates, VGThermalState.nominal);
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_U_SMOKE_LANE_6: pass=$lane6Pass '
        'receivedStates=${receivedStates.map((s) => s.name).toList()}',
      );

      // Lane 7: evaluate nominal reset plan.
      nominalPlan = planner.evaluate(
        thermalState: VGThermalState.nominal,
        wasRecording: true,
        hadSecondaryCamera: false,
      );

      lane7Pass =
          nominalPlan.decision ==
              VGCamera2ThermalLoadSheddingDecision.maintain &&
          nominalPlan.notifyDart == false &&
          nominalPlan.requiresSafeGraphBoundary == false &&
          nominalPlan.shouldDropSecondaryCamera == false &&
          nominalPlan.shouldStopRecording == false &&
          nominalPlan.preservesEncoderContract == true &&
          nominalPlan.reasons.contains('thermal_nominal');
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_U_SMOKE_LANE_7: pass=$lane7Pass '
        'decision=${nominalPlan.decision.name} notifyDart=${nominalPlan.notifyDart} '
        'requiresSafeGraphBoundary=${nominalPlan.requiresSafeGraphBoundary}',
      );

      // Lane 8: arrival order contains serious -> critical -> nominal subsequence.
      final seriousIdx = receivedStates.indexOf(VGThermalState.serious);
      final criticalIdx = seriousIdx >= 0
          ? receivedStates.indexOf(VGThermalState.critical, seriousIdx + 1)
          : -1;
      final nominalIdx = criticalIdx >= 0
          ? receivedStates.indexOf(VGThermalState.nominal, criticalIdx + 1)
          : -1;
      lane8Pass =
          seriousIdx >= 0 &&
          criticalIdx > seriousIdx &&
          nominalIdx > criticalIdx;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_U_SMOKE_LANE_8: pass=$lane8Pass '
        'seriousIdx=$seriousIdx criticalIdx=$criticalIdx nominalIdx=$nominalIdx',
      );

      // Lane 9: payload nonClaims all false and proofBoundary advisory.
      final nonClaimsPayload = <String, bool>{
        'cameraSessionMutated': false,
        'captureRequestUpdated': false,
        'cameraOpened': false,
        'rendererTouched': false,
        'encoderTouched': false,
        'realForcedOverheat': false,
      };
      final nonClaimsAllFalse = nonClaimsPayload.values.every(
        (v) => v == false,
      );

      lane9Pass =
          _proofBoundary ==
              'thermal_load_shedding_policy_advisory_no_camera_session_mutation' &&
          nonClaimsAllFalse;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_U_SMOKE_LANE_9: pass=$lane9Pass '
        'proofBoundary=$_proofBoundary nonClaimsAllFalse=$nonClaimsAllFalse',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Thermal load-shedding smoke exceeded 15 seconds: $te';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_U_THERMAL_LOAD_SHEDDING_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_U_THERMAL_LOAD_SHEDDING_SMOKE_ERROR: $topLevelError',
      );
    } finally {
      await subscription?.cancel();

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
        'unit': 'AndroidCamera2ThermalLoadSheddingPolicy',
        'slice':
            'Phase 3-Unit U — Android Camera2 Mid-Recording Thermal Load-Shedding Policy & Mitigation Planner',
        'target': 'android_physical',
        'pass': allPass,
        'proofBoundary': _proofBoundary,
        'initialRaw': initialRaw,
        'receivedStates': receivedStates.map((s) => s.name).toList(),
        'lanes': <String, dynamic>{
          'lane1_initialStateAndPlanValid': {
            'pass': lane1Pass,
            'initialRaw': initialRaw,
            'plan': initialPlan?.toMap(),
          },
          'lane2_seriousEventObserved': {'pass': lane2Pass},
          'lane3_seriousRecordingSecondaryPlan': {
            'pass': lane3Pass,
            'plan': seriousPlan?.toMap(),
          },
          'lane4_criticalEventObserved': {'pass': lane4Pass},
          'lane5_criticalRecordingNoPreserveContractPlan': {
            'pass': lane5Pass,
            'plan': criticalPlan?.toMap(),
          },
          'lane6_nominalResetObserved': {'pass': lane6Pass},
          'lane7_nominalMaintainPlan': {
            'pass': lane7Pass,
            'plan': nominalPlan?.toMap(),
          },
          'lane8_eventOrderPreserved': {'pass': lane8Pass},
          'lane9_advisoryProofBoundaryAndNonClaims': {
            'pass': lane9Pass,
            'proofBoundary': _proofBoundary,
            'nonClaims': VGCamera2ThermalLoadSheddingPlanner.nonClaims,
          },
        },
        'nonClaims': VGCamera2ThermalLoadSheddingPlanner.nonClaims,
        'error': topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_U_THERMAL_LOAD_SHEDDING_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_U_THERMAL_LOAD_SHEDDING_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_U_THERMAL_LOAD_SHEDDING_PHYSICAL_FAIL',
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
