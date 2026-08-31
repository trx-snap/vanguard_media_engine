// android_audio_graph_transport_clock_physical_smoke.dart
// vanguard_media_engine — P4-AUDIO-GRAPH-TRANSPORT-CLOCK: Android True-DAG Phase 4
// synchronous graph-edge-routed audio window scheduler proof physical harness.
//
// Proof lanes:
//   - Routing, Window Math & Timebase group: schedulerGraphEdgeRoutingOk, frameWindowMathExactOk, ptsDerivationOk, noMicrosecondDriftOk, timelineGatingWindowOk.
//   - Scheduler Mix, Silence & Error Guards group: mixRoutingChecksumOk, silenceWindowOk, staleGenerationRejectOk, sampleRateMismatchRejectOk, capacityGuardOk, noPerWindowAllocationOk, deterministicPortOrderOk.
//   - Lifecycle & Scope group: lifecycleOk, stackScoped.
//   - Metrics group: renderedFrames, mixChecksum, expectedChecksum, schedulerMixCallCount, silenceMixCallCount, windowCount, partialFinalWindowFrames, microsecondAccumulationDriftFrames.
//   - Proof-Boundary & Summary group: hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   native_graph_edge_routed_audio_window_scheduler_proof_only_no_realtime_no_audio_track_no_playback_no_queue_no_backpressure_no_threads_no_export_reroute_no_product
//   Pure in-memory native C++ graph-edge-routed audio window scheduler proof only.
//   No audible or realtime playback, no AudioTrack, AAudio, OpenSL, or Oboe,
//   no threads, locks, queues, or backpressure, no file IO, no MediaCodec or MediaExtractor,
//   no export reroute, no editor or product UI, no streaming, no iOS,
//   does not close P4-AUDIO-GRAPH-TRANSPORT-CLOCK or P4-AUDIO-MIXBUS.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAudioGraphTransportClockPhysicalSmokeApp());
}

class AndroidAudioGraphTransportClockPhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioGraphTransportClockPhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioGraphTransportClockPhysicalSmokeApp> createState() =>
      _AndroidAudioGraphTransportClockPhysicalSmokeAppState();
}

class _AndroidAudioGraphTransportClockPhysicalSmokeAppState
    extends State<AndroidAudioGraphTransportClockPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Audio Graph Transport Clock smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_AUDIO_GRAPH_TRANSPORT_CLOCK_SMOKE_START');

    VGAudioGraphTransportClockSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGAudioGraphTransportClockSmokeReport.runAndroidDagPhase4AudioGraphTransportClockSmoke(
            timeout: const Duration(seconds: 15),
          ).timeout(const Duration(seconds: 25));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_GRAPH_TRANSPORT_CLOCK_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_GRAPH_TRANSPORT_CLOCK_ERROR: $topLevelError',
      );
    }

    final activeReport =
        report ??
        const VGAudioGraphTransportClockSmokeReport(
          pass: false,
          proofBoundary: '',
          raw: <String, String>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          metrics: <String, Object?>{'status': 'FAIL'},
          lastError: 'invocation_failed',
        );

    // 1. Routing, Window Math & Timebase group
    print(
      '  [LANE] Routing, Window Math & Timebase: '
      'schedulerGraphEdgeRoutingOk=${activeReport.schedulerGraphEdgeRoutingOk}, '
      'frameWindowMathExactOk=${activeReport.frameWindowMathExactOk}, '
      'ptsDerivationOk=${activeReport.ptsDerivationOk}, '
      'noMicrosecondDriftOk=${activeReport.noMicrosecondDriftOk}, '
      'timelineGatingWindowOk=${activeReport.timelineGatingWindowOk}',
    );

    // 2. Scheduler Mix, Silence & Error Guards group
    print(
      '  [LANE] Scheduler Mix, Silence & Error Guards: '
      'mixRoutingChecksumOk=${activeReport.mixRoutingChecksumOk}, '
      'silenceWindowOk=${activeReport.silenceWindowOk}, '
      'staleGenerationRejectOk=${activeReport.staleGenerationRejectOk}, '
      'sampleRateMismatchRejectOk=${activeReport.sampleRateMismatchRejectOk}, '
      'capacityGuardOk=${activeReport.capacityGuardOk}, '
      'noPerWindowAllocationOk=${activeReport.noPerWindowAllocationOk}, '
      'deterministicPortOrderOk=${activeReport.deterministicPortOrderOk}',
    );

    // 3. Lifecycle & Scope group
    print(
      '  [LANE] Lifecycle & Scope: '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'stackScoped=${activeReport.stackScoped}',
    );

    // 4. Metrics group
    print(
      '  [LANE] Metrics: '
      'renderedFrames=${activeReport.renderedFrames}, '
      'mixChecksum=${activeReport.mixChecksum}, '
      'expectedChecksum=${activeReport.expectedChecksum}, '
      'schedulerMixCallCount=${activeReport.schedulerMixCallCount}, '
      'silenceMixCallCount=${activeReport.silenceMixCallCount}, '
      'windowCount=${activeReport.windowCount}, '
      'partialFinalWindowFrames=${activeReport.partialFinalWindowFrames}, '
      'microsecondAccumulationDriftFrames=${activeReport.microsecondAccumulationDriftFrames}',
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
      'unit': 'AndroidAudioGraphTransportClockPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-GRAPH-TRANSPORT-CLOCK',
      'target': VGAudioGraphTransportClockSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_AUDIO_GRAPH_TRANSPORT_CLOCK_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AUDIO_GRAPH_TRANSPORT_CLOCK_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AUDIO_GRAPH_TRANSPORT_CLOCK_SMOKE_FAIL',
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
