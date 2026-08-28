// android_camera2_thermal_load_shedding_monitor_physical_smoke.dart
// Vanguard Media Engine — Phase 3-Unit V: Android Camera2 Thermal Load-Shedding
// Monitor & Telemetry Coordinator Physical Smoke Foundation Harness.
//
// Proof lanes:
//   Lane 1: getThermalState valid and monitor evaluateOnce initial plan created.
//   Lane 2: monitor start() running and subscription stream active.
//   Lane 3: serious event observed and evaluation emitted.
//   Lane 4: serious evaluation decision dropSecondaryCamera, notifyDart true,
//           safe boundary true, no mutation nonClaims all false.
//   Lane 5: critical event observed and evaluation emitted.
//   Lane 6: critical evaluation decision stopRecording, preservesEncoderContract false,
//           no mutation nonClaims all false.
//   Lane 7: nominal reset observed and evaluation emitted.
//   Lane 8: nominal evaluation decision maintain, notifyDart false, no boundary.
//   Lane 9: history bounded/non-empty/latest coherent and observed order contains
//           serious -> critical -> nominal subsequence, tolerating initial real nominal.
//   Lane 10: stop/dispose lifecycle leaves isDisposed true and no post-dispose emitted snapshot.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidCamera2ThermalLoadSheddingMonitorPhysicalSmokeApp());
}

class AndroidCamera2ThermalLoadSheddingMonitorPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidCamera2ThermalLoadSheddingMonitorPhysicalSmokeApp({super.key});

  @override
  State<AndroidCamera2ThermalLoadSheddingMonitorPhysicalSmokeApp>
  createState() =>
      _AndroidCamera2ThermalLoadSheddingMonitorPhysicalSmokeAppState();
}

class _AndroidCamera2ThermalLoadSheddingMonitorPhysicalSmokeAppState
    extends State<AndroidCamera2ThermalLoadSheddingMonitorPhysicalSmokeApp> {
  static const String _proofBoundary =
      'thermal_load_shedding_monitor_advisory_no_camera_session_mutation';

  String _status = 'Initializing Camera2 Thermal Load-Shedding Monitor Smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<VGCamera2ThermalLoadSheddingEvaluation?> _waitForEvaluation(
    List<VGCamera2ThermalLoadSheddingEvaluation> received,
    VGThermalState expectedState, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      for (final eval in received) {
        if (eval.thermalState == expectedState) return eval;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    for (final eval in received) {
      if (eval.thermalState == expectedState) return eval;
    }
    return null;
  }

  Future<void> _runSmoke() async {
    print(
      'ANDROID_CAMERA_PHASE3_UNIT_V_THERMAL_LOAD_SHEDDING_MONITOR_SMOKE_START',
    );
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
    var lane10Pass = false;

    int? initialRaw;
    final receivedEvaluations = <VGCamera2ThermalLoadSheddingEvaluation>[];
    StreamSubscription<VGCamera2ThermalLoadSheddingEvaluation>?
    evaluationsSubscription;

    final monitor = VGCamera2ThermalLoadSheddingMonitor();
    VGCamera2ThermalLoadSheddingEvaluation? initialEval;
    VGCamera2ThermalLoadSheddingEvaluation? seriousEval;
    VGCamera2ThermalLoadSheddingEvaluation? criticalEval;
    VGCamera2ThermalLoadSheddingEvaluation? nominalEval;

    try {
      // 1. Initial getThermalState() query and evaluateOnce initial state.
      final currentState = await VGThermalMonitor.getThermalState().timeout(
        const Duration(seconds: 15),
      );
      initialRaw = currentState.index;

      monitor.updateSessionState(
        wasRecording: true,
        hadSecondaryCamera: true,
        currentFps: 30,
        currentResolutionScale: 1.0,
        canPreserveEncoderContract: true,
      );

      initialEval = monitor.evaluateOnce(currentState);

      lane1Pass =
          VGThermalState.values.contains(currentState) &&
          VGCamera2ThermalLoadSheddingDecision.values.contains(
            initialEval.decision,
          ) &&
          initialEval.diagnostics['proofBoundary'] == _proofBoundary &&
          initialEval.sequence >= 1;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_V_SMOKE_LANE_1: pass=$lane1Pass '
        'currentState=${currentState.name} raw=$initialRaw decision=${initialEval.decision.name}',
      );

      // 2. Start monitor and verify active subscription.
      evaluationsSubscription = monitor.evaluations.listen(
        receivedEvaluations.add,
      );
      monitor.start();
      lane2Pass = monitor.isRunning && !monitor.isDisposed;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_V_SMOKE_LANE_2: pass=$lane2Pass '
        'isRunning=${monitor.isRunning} isDisposed=${monitor.isDisposed}',
      );

      // 3 & 4. Simulate serious thermal state: recording + secondary camera.
      // Expected: dropSecondaryCamera, notifyDart true, safe boundary true, nonClaims false.
      await VGThermalMonitor.simulateThermalState(VGThermalState.serious);
      seriousEval = await _waitForEvaluation(
        receivedEvaluations,
        VGThermalState.serious,
      );
      lane3Pass = seriousEval != null;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_V_SMOKE_LANE_3: pass=$lane3Pass '
        'seriousEvalSequence=${seriousEval?.sequence}',
      );

      final seriousNonClaims = Map<String, dynamic>.from(
        seriousEval?.diagnostics['nonClaims'] as Map? ?? const {},
      );
      final seriousNonClaimsAllFalse =
          seriousNonClaims.isNotEmpty &&
          seriousNonClaims.values.every((v) => v == false);

      lane4Pass =
          seriousEval != null &&
          seriousEval.decision ==
              VGCamera2ThermalLoadSheddingDecision.dropSecondaryCamera &&
          seriousEval.notifyDart == true &&
          seriousEval.requiresSafeGraphBoundary == true &&
          seriousEval.shouldDropSecondaryCamera == true &&
          seriousEval.shouldStopRecording == false &&
          seriousEval.cameraSessionMutated == false &&
          seriousEval.captureRequestUpdated == false &&
          seriousEval.rendererTouched == false &&
          seriousEval.encoderTouched == false &&
          seriousNonClaimsAllFalse;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_V_SMOKE_LANE_4: pass=$lane4Pass '
        'decision=${seriousEval?.decision.name} shouldDropSecondaryCamera=${seriousEval?.shouldDropSecondaryCamera} '
        'seriousNonClaimsAllFalse=$seriousNonClaimsAllFalse',
      );

      // 5 & 6. Update session state (canPreserveEncoderContract = false) and simulate critical.
      // Expected: stopRecording, preservesEncoderContract false, nonClaims false.
      monitor.updateSessionState(
        wasRecording: true,
        hadSecondaryCamera: true,
        canPreserveEncoderContract: false,
      );
      await VGThermalMonitor.simulateThermalState(VGThermalState.critical);
      criticalEval = await _waitForEvaluation(
        receivedEvaluations,
        VGThermalState.critical,
      );
      lane5Pass = criticalEval != null;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_V_SMOKE_LANE_5: pass=$lane5Pass '
        'criticalEvalSequence=${criticalEval?.sequence}',
      );

      final criticalNonClaims = Map<String, dynamic>.from(
        criticalEval?.diagnostics['nonClaims'] as Map? ?? const {},
      );
      final criticalNonClaimsAllFalse =
          criticalNonClaims.isNotEmpty &&
          criticalNonClaims.values.every((v) => v == false);

      lane6Pass =
          criticalEval != null &&
          criticalEval.decision ==
              VGCamera2ThermalLoadSheddingDecision.stopRecording &&
          criticalEval.notifyDart == true &&
          criticalEval.requiresSafeGraphBoundary == true &&
          criticalEval.shouldStopRecording == true &&
          criticalEval.preservesEncoderContract == false &&
          criticalEval.cameraSessionMutated == false &&
          criticalEval.captureRequestUpdated == false &&
          criticalEval.rendererTouched == false &&
          criticalEval.encoderTouched == false &&
          criticalEval.reasons.contains('encoder_contract_not_preserved') &&
          criticalNonClaimsAllFalse;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_V_SMOKE_LANE_6: pass=$lane6Pass '
        'decision=${criticalEval?.decision.name} shouldStopRecording=${criticalEval?.shouldStopRecording} '
        'preservesEncoderContract=${criticalEval?.preservesEncoderContract}',
      );

      // 7 & 8. Update session state (recording, secondary=false) and simulate nominal reset.
      // Expected: maintain, notifyDart false, no safe boundary.
      monitor.updateSessionState(
        wasRecording: true,
        hadSecondaryCamera: false,
        canPreserveEncoderContract: true,
      );
      await VGThermalMonitor.simulateThermalState(VGThermalState.nominal);
      nominalEval = await _waitForEvaluation(
        receivedEvaluations,
        VGThermalState.nominal,
      );
      lane7Pass = nominalEval != null;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_V_SMOKE_LANE_7: pass=$lane7Pass '
        'nominalEvalSequence=${nominalEval?.sequence}',
      );

      lane8Pass =
          nominalEval != null &&
          nominalEval.decision ==
              VGCamera2ThermalLoadSheddingDecision.maintain &&
          nominalEval.notifyDart == false &&
          nominalEval.requiresSafeGraphBoundary == false &&
          nominalEval.shouldDropSecondaryCamera == false &&
          nominalEval.shouldStopRecording == false &&
          nominalEval.preservesEncoderContract == true &&
          nominalEval.reasons.contains('thermal_nominal');
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_V_SMOKE_LANE_8: pass=$lane8Pass '
        'decision=${nominalEval?.decision.name} notifyDart=${nominalEval?.notifyDart} '
        'requiresSafeGraphBoundary=${nominalEval?.requiresSafeGraphBoundary}',
      );

      // 9. History bounded/non-empty/latest coherent and observed sequence order.
      final history = monitor.history;
      final latest = monitor.latest;
      final historyNonEmpty =
          history.isNotEmpty &&
          history.length <= monitor.config.maxHistoryLength;
      final latestCoherent = latest != null && latest == history.last;

      final seriousIdx = receivedEvaluations.indexWhere(
        (e) => e.thermalState == VGThermalState.serious,
      );
      final criticalIdx = seriousIdx >= 0
          ? receivedEvaluations.indexWhere(
              (e) => e.thermalState == VGThermalState.critical,
              seriousIdx + 1,
            )
          : -1;
      final nominalIdx = criticalIdx >= 0
          ? receivedEvaluations.indexWhere(
              (e) => e.thermalState == VGThermalState.nominal,
              criticalIdx + 1,
            )
          : -1;

      final sequenceOrdered =
          seriousIdx >= 0 &&
          criticalIdx > seriousIdx &&
          nominalIdx > criticalIdx;

      lane9Pass = historyNonEmpty && latestCoherent && sequenceOrdered;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_V_SMOKE_LANE_9: pass=$lane9Pass '
        'historyLength=${history.length} latestCoherent=$latestCoherent '
        'seriousIdx=$seriousIdx criticalIdx=$criticalIdx nominalIdx=$nominalIdx',
      );

      // 10. Stop and dispose lifecycle.
      monitor.stop();
      final wasRunningAfterStop = monitor.isRunning;
      await monitor.dispose();
      final isDisposedAfterDispose = monitor.isDisposed;

      final countBeforePostDispose = receivedEvaluations.length;
      final postDisposeEval = monitor.evaluateOnce(VGThermalState.fair);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final noPostDisposeEmitted =
          receivedEvaluations.length == countBeforePostDispose;

      lane10Pass =
          !wasRunningAfterStop &&
          isDisposedAfterDispose &&
          noPostDisposeEmitted &&
          postDisposeEval == latest;
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_V_SMOKE_LANE_10: pass=$lane10Pass '
        'isDisposed=$isDisposedAfterDispose noPostDisposeEmitted=$noPostDisposeEmitted',
      );
    } on TimeoutException catch (te) {
      topLevelError =
          'Watchdog timeout: Thermal load-shedding monitor smoke exceeded 15 seconds: $te';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_V_THERMAL_LOAD_SHEDDING_MONITOR_SMOKE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_CAMERA_PHASE3_UNIT_V_THERMAL_LOAD_SHEDDING_MONITOR_SMOKE_ERROR: $topLevelError',
      );
    } finally {
      await evaluationsSubscription?.cancel();
      await monitor.dispose();

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
        'unit': 'AndroidCamera2ThermalLoadSheddingMonitor',
        'slice':
            'Phase 3-Unit V — Android Camera2 Thermal Load-Shedding Monitor & Telemetry Coordinator Foundation',
        'target': 'android_physical',
        'pass': allPass,
        'proofBoundary': _proofBoundary,
        'initialRaw': initialRaw,
        'receivedEvaluationsCount': receivedEvaluations.length,
        'lanes': <String, dynamic>{
          'lane1_initialStateAndEvaluationValid': {
            'pass': lane1Pass,
            'initialRaw': initialRaw,
            'evaluation': initialEval?.toMap(),
          },
          'lane2_monitorStartRunning': {'pass': lane2Pass},
          'lane3_seriousEventObserved': {'pass': lane3Pass},
          'lane4_seriousDropSecondaryEvaluation': {
            'pass': lane4Pass,
            'evaluation': seriousEval?.toMap(),
          },
          'lane5_criticalEventObserved': {'pass': lane5Pass},
          'lane6_criticalStopRecordingEvaluation': {
            'pass': lane6Pass,
            'evaluation': criticalEval?.toMap(),
          },
          'lane7_nominalResetObserved': {'pass': lane7Pass},
          'lane8_nominalMaintainEvaluation': {
            'pass': lane8Pass,
            'evaluation': nominalEval?.toMap(),
          },
          'lane9_historyAndSequenceCoherence': {'pass': lane9Pass},
          'lane10_disposalLifecycleAndInvariants': {'pass': lane10Pass},
        },
        'nonClaims': VGCamera2ThermalLoadSheddingMonitor.nonClaims,
        'error': topLevelError,
      };

      print(
        'ANDROID_CAMERA_PHASE3_UNIT_V_THERMAL_LOAD_SHEDDING_MONITOR_JSON:${jsonEncode(payload)}',
      );
      print(
        allPass
            ? 'ANDROID_CAMERA_PHASE3_UNIT_V_THERMAL_LOAD_SHEDDING_MONITOR_PHYSICAL_PASS'
            : 'ANDROID_CAMERA_PHASE3_UNIT_V_THERMAL_LOAD_SHEDDING_MONITOR_PHYSICAL_FAIL',
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
