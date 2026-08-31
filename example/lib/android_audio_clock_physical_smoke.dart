// android_audio_clock_physical_smoke.dart
// vanguard_media_engine — P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice C: Android True-DAG Phase 4
// platform-neutral native AudioClock diagnostic proof physical harness.
//
// Proof lanes:
//   - Lock-Free, Math & Exactness group: audioClockLockFreeOk, clockMathOk, rationalExactnessOk, doubleDivergenceOk, speedMathOk.
//   - State Transitions, Seek & Fuzz group: playPauseResumeOk, seekOk, monotonicityFuzzOk, overflowSaturationOk, invalidSpeedRejectOk.
//   - Telemetry, Ring Coordination & Lifecycle group: driftTelemetryInertOk, ringSeekCoordinationOk, lifecycleOk, stackScoped.
//   - Metrics group: finalPositionUs, pausedPositionUs, resumedPositionUs, seekPositionUs, driftDeltaUs, driftSampleCount, fuzzIterations.
//   - Proof-Boundary & Summary group: hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   native_audio_clock_monotonic_timebase_and_drift_proof_only_no_audio_track_no_aaudio_no_audible_playback_no_decoder_writer_no_export_reroute_no_streaming_no_ios_no_product_no_internal_wall_clock_read
//   Caller-clocked, lock-free monotonic media-position tracker + drift-telemetry native proof.
//   Pure in-memory C++ lock-free monotonic timebase; no AudioTrack/AAudio/OpenSL/Oboe,
//   no audible playback, no production decoder writer, no export reroute, no streaming,
//   no iOS, no product/editor UI, no internal wall-clock read.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAudioClockPhysicalSmokeApp());
}

class AndroidAudioClockPhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioClockPhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioClockPhysicalSmokeApp> createState() =>
      _AndroidAudioClockPhysicalSmokeAppState();
}

class _AndroidAudioClockPhysicalSmokeAppState
    extends State<AndroidAudioClockPhysicalSmokeApp> {
  String _status = 'Running Android DAG Phase 4 Audio Clock smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_AUDIO_CLOCK_SMOKE_START');

    VGAudioClockSmokeReport? report;
    String? topLevelError;

    try {
      report = await VGAudioClockSmokeReport.runAndroidDagPhase4AudioClockSmoke(
        timeout: const Duration(seconds: 15),
      ).timeout(const Duration(seconds: 25));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print('ANDROID_DAG_PHASE4_AUDIO_CLOCK_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('ANDROID_DAG_PHASE4_AUDIO_CLOCK_ERROR: $topLevelError');
    }

    final activeReport =
        report ??
        const VGAudioClockSmokeReport(
          pass: false,
          proofBoundary: '',
          raw: <String, String>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          metrics: <String, Object?>{'status': 'FAIL'},
          lastError: 'invocation_failed',
        );

    // 1. Lock-Free, Math & Exactness group
    print(
      '  [LANE] Lock-Free, Math & Exactness: '
      'audioClockLockFreeOk=${activeReport.audioClockLockFreeOk}, '
      'clockMathOk=${activeReport.clockMathOk}, '
      'rationalExactnessOk=${activeReport.rationalExactnessOk}, '
      'doubleDivergenceOk=${activeReport.doubleDivergenceOk}, '
      'speedMathOk=${activeReport.speedMathOk}',
    );

    // 2. State Transitions, Seek & Fuzz group
    print(
      '  [LANE] State Transitions, Seek & Fuzz: '
      'playPauseResumeOk=${activeReport.playPauseResumeOk}, '
      'seekOk=${activeReport.seekOk}, '
      'monotonicityFuzzOk=${activeReport.monotonicityFuzzOk}, '
      'overflowSaturationOk=${activeReport.overflowSaturationOk}, '
      'invalidSpeedRejectOk=${activeReport.invalidSpeedRejectOk}',
    );

    // 3. Telemetry, Ring Coordination & Lifecycle group
    print(
      '  [LANE] Telemetry, Ring Coordination & Lifecycle: '
      'driftTelemetryInertOk=${activeReport.driftTelemetryInertOk}, '
      'ringSeekCoordinationOk=${activeReport.ringSeekCoordinationOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'stackScoped=${activeReport.stackScoped}',
    );

    // 4. Metrics group
    print(
      '  [LANE] Metrics: '
      'finalPositionUs=${activeReport.finalPositionUs}, '
      'pausedPositionUs=${activeReport.pausedPositionUs}, '
      'resumedPositionUs=${activeReport.resumedPositionUs}, '
      'seekPositionUs=${activeReport.seekPositionUs}, '
      'driftDeltaUs=${activeReport.driftDeltaUs}, '
      'driftSampleCount=${activeReport.driftSampleCount}, '
      'fuzzIterations=${activeReport.fuzzIterations}',
    );

    // 5. Proof Boundary & Summary group
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
      'unit': 'AndroidAudioClockPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-GRAPH-TRANSPORT-CLOCK',
      'target': VGAudioClockSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print('ANDROID_DAG_PHASE4_AUDIO_CLOCK_JSON:${jsonEncode(summaryPayload)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AUDIO_CLOCK_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AUDIO_CLOCK_SMOKE_FAIL',
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
