// android_audio_transport_coordinator_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice D: Android True-DAG Phase 4
// native ClockedAudioTransportCoordinator diagnostic proof physical harness.
//
// Proof lanes:
//   - Constructor, Start Gate & Monotonic Dispatch group: coordinatorConstructorValidationOk, startAwaitAckGateOk, clockDrivenDispatchOk.
//   - Catch-up, Backpressure & Pause/Resume group: boundedCatchUpOk, backpressureNoClockMutationOk, pauseResumeNoDispatchOk.
//   - Seek Gate, Silence & Error Recovery group: seekAwaitAckGateOk, silenceWindowPushedOk, schedulerErrorNoCursorAdvanceOk, nonUnitySpeedRejectOk, frameConversionOverflowOk, noSteadyStateAllocationOk.
//   - Lifecycle & Scope group: lifecycleOk, stackScoped.
//   - Metrics group: clockDrivenFramesRendered, boundedCatchUpCalls, boundedCatchUpTotalFrames, silenceFramesPushed, frameOfPositionSaturated.
//   - Proof-Boundary & Summary group: hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   native_clock_driven_audio_transport_coordinator_proof_only_no_audio_track_no_os_callback_no_decoder_writer_no_export_reroute_no_streaming_no_ios_no_product_no_internal_wall_clock_read_no_threads_no_locks_no_float_timebase_no_resample_no_speed_change_no_source_provider_ring_seek_output_ring_only_unity_speed_only
//   Caller-clocked, clock-driven audio transport coordinator native proof.
//   Pure in-memory C++ proof only; no AudioTrack/AAudio/OpenSL/Oboe, no OS callbacks,
//   no production decoder writer, no export reroute, no streaming, no iOS,
//   no product/editor UI, no internal wall-clock read, no threads, no locks,
//   no float timebase, no resample, no speed change, no source provider ring seek,
//   output ring only, unity speed only.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAudioTransportCoordinatorPhysicalSmokeApp());
}

class AndroidAudioTransportCoordinatorPhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioTransportCoordinatorPhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioTransportCoordinatorPhysicalSmokeApp> createState() =>
      _AndroidAudioTransportCoordinatorPhysicalSmokeAppState();
}

class _AndroidAudioTransportCoordinatorPhysicalSmokeAppState
    extends State<AndroidAudioTransportCoordinatorPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Audio Transport Coordinator smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_AUDIO_TRANSPORT_COORDINATOR_SMOKE_START');

    VGAudioTransportCoordinatorSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGAudioTransportCoordinatorSmokeReport.runAndroidDagPhase4AudioTransportCoordinatorSmoke(
            timeout: const Duration(seconds: 15),
          ).timeout(const Duration(seconds: 25));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_TRANSPORT_COORDINATOR_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_TRANSPORT_COORDINATOR_ERROR: $topLevelError',
      );
    }

    final activeReport =
        report ??
        const VGAudioTransportCoordinatorSmokeReport(
          pass: false,
          proofBoundary: '',
          raw: <String, String>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          metrics: <String, Object?>{'status': 'FAIL'},
          lastError: 'invocation_failed',
        );

    // 1. Constructor, Start Gate & Monotonic Dispatch group
    print(
      '  [LANE] Constructor, Start Gate & Monotonic Dispatch: '
      'coordinatorConstructorValidationOk=${activeReport.coordinatorConstructorValidationOk}, '
      'startAwaitAckGateOk=${activeReport.startAwaitAckGateOk}, '
      'clockDrivenDispatchOk=${activeReport.clockDrivenDispatchOk}',
    );

    // 2. Catch-up, Backpressure & Pause/Resume group
    print(
      '  [LANE] Catch-up, Backpressure & Pause/Resume: '
      'boundedCatchUpOk=${activeReport.boundedCatchUpOk}, '
      'backpressureNoClockMutationOk=${activeReport.backpressureNoClockMutationOk}, '
      'pauseResumeNoDispatchOk=${activeReport.pauseResumeNoDispatchOk}',
    );

    // 3. Seek Gate, Silence & Error Recovery group
    print(
      '  [LANE] Seek Gate, Silence & Error Recovery: '
      'seekAwaitAckGateOk=${activeReport.seekAwaitAckGateOk}, '
      'silenceWindowPushedOk=${activeReport.silenceWindowPushedOk}, '
      'schedulerErrorNoCursorAdvanceOk=${activeReport.schedulerErrorNoCursorAdvanceOk}, '
      'nonUnitySpeedRejectOk=${activeReport.nonUnitySpeedRejectOk}, '
      'frameConversionOverflowOk=${activeReport.frameConversionOverflowOk}, '
      'noSteadyStateAllocationOk=${activeReport.noSteadyStateAllocationOk}',
    );

    // 4. Lifecycle & Scope group
    print(
      '  [LANE] Lifecycle & Scope: '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'stackScoped=${activeReport.stackScoped}',
    );

    // 5. Metrics group
    print(
      '  [LANE] Metrics: '
      'clockDrivenFramesRendered=${activeReport.clockDrivenFramesRendered}, '
      'boundedCatchUpCalls=${activeReport.boundedCatchUpCalls}, '
      'boundedCatchUpTotalFrames=${activeReport.boundedCatchUpTotalFrames}, '
      'silenceFramesPushed=${activeReport.silenceFramesPushed}, '
      'frameOfPositionSaturated=${activeReport.frameOfPositionSaturated}',
    );

    // 6. Proof Boundary & Summary group
    print(
      '  [LANE] Proof Boundary & Summary: '
      'canonical=${activeReport.hasCanonicalProofBoundary}, '
      'allNativeLanesPass=${activeReport.allNativeLanesPass}, '
      'lastError=${activeReport.lastError}',
    );

    final lastErrorOk =
        activeReport.lastError.isEmpty ||
        activeReport.lastError == 'none' ||
        activeReport.lastError == 'null';

    final pass =
        (topLevelError == null) &&
        activeReport.pass &&
        activeReport.hasCanonicalProofBoundary &&
        activeReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAudioTransportCoordinatorPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-GRAPH-TRANSPORT-CLOCK',
      'target': VGAudioTransportCoordinatorSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_AUDIO_TRANSPORT_COORDINATOR_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AUDIO_TRANSPORT_COORDINATOR_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AUDIO_TRANSPORT_COORDINATOR_SMOKE_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (allNativeLanesPass=true, hasCanonicalProofBoundary=true)'
            : 'FAIL: lastError=${activeReport.lastError}, error=$topLevelError';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 1500));
    exit(pass ? 0 : 1);
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
