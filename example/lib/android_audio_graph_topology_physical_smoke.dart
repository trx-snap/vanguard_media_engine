// android_audio_graph_topology_physical_smoke.dart
// vanguard_media_engine — P4-AUDIO-GRAPH-TOPOLOGY: Android True-DAG Phase 4
// AudioMixBusNode DAG topology & graph-gated diagnostic mix physical harness.
//
// Proof lanes:
//   - DAG Topology & Order group: topologyOk, topoOrderOk, portTypeOk, capacityOk, cycleRejectOk, inputFanInRejectOk.
//   - Graph Evaluation & Gating group: staleGenerationOk, mediaFlagsOk, graphGatedMixOk, invalidGainOk.
//   - Lifecycle & Scope group: lifecycleOk, stackScoped, hasAudio, hasVideo.
//   - Metrics group: nodeCount, edgeCount, activeNodeCount, mixCallCount, staleMixCallCount, framesMixed, mixChecksum, expectedChecksum, maxAccumulatorAbs.
//   - Proof-Boundary & Summary group: hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   native_audio_mix_bus_graph_topology_and_graph_gated_diagnostic_mix_only_no_realtime_no_playback_no_audio_track_no_graph_buffer_transport_no_product
//   Pure in-memory native C++ AudioMixBusNode DAG topology and graph-gated diagnostic mix only.
//   No audible or realtime playback, no C++ graph buffer transport, no audio timeline gating,
//   no Pass-2 export graph reroute, does not close P4-AUDIO-MIXBUS.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAudioGraphTopologyPhysicalSmokeApp());
}

class AndroidAudioGraphTopologyPhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioGraphTopologyPhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioGraphTopologyPhysicalSmokeApp> createState() =>
      _AndroidAudioGraphTopologyPhysicalSmokeAppState();
}

class _AndroidAudioGraphTopologyPhysicalSmokeAppState
    extends State<AndroidAudioGraphTopologyPhysicalSmokeApp> {
  String _status = 'Running Android DAG Phase 4 Audio Graph Topology smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_AUDIO_GRAPH_TOPOLOGY_SMOKE_START');

    VGAudioGraphTopologySmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGAudioGraphTopologySmokeReport.runAndroidDagPhase4AudioGraphTopologySmoke(
            timeout: const Duration(seconds: 15),
          ).timeout(const Duration(seconds: 25));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print('ANDROID_DAG_PHASE4_AUDIO_GRAPH_TOPOLOGY_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('ANDROID_DAG_PHASE4_AUDIO_GRAPH_TOPOLOGY_ERROR: $topLevelError');
    }

    final activeReport =
        report ??
        const VGAudioGraphTopologySmokeReport(
          pass: false,
          proofBoundary: '',
          raw: <String, String>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          metrics: <String, Object?>{'status': 'FAIL'},
          lastError: 'invocation_failed',
        );

    // 1. Topology & Order group
    print(
      '  [LANE] Topology & Order: '
      'topologyOk=${activeReport.topologyOk}, '
      'topoOrderOk=${activeReport.topoOrderOk}, '
      'portTypeOk=${activeReport.portTypeOk}, '
      'capacityOk=${activeReport.capacityOk}, '
      'cycleRejectOk=${activeReport.cycleRejectOk}, '
      'inputFanInRejectOk=${activeReport.inputFanInRejectOk}',
    );

    // 2. Graph Evaluation & Gating group
    print(
      '  [LANE] Graph Evaluation & Gating: '
      'staleGenerationOk=${activeReport.staleGenerationOk}, '
      'mediaFlagsOk=${activeReport.mediaFlagsOk}, '
      'graphGatedMixOk=${activeReport.graphGatedMixOk}, '
      'invalidGainOk=${activeReport.invalidGainOk}',
    );

    // 3. Lifecycle & Scope group
    print(
      '  [LANE] Lifecycle & Scope: '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'stackScoped=${activeReport.stackScoped}, '
      'hasAudio=${activeReport.hasAudio}, '
      'hasVideo=${activeReport.hasVideo}',
    );

    // 4. Metrics group
    print(
      '  [LANE] Metrics: '
      'nodeCount=${activeReport.nodeCount}, '
      'edgeCount=${activeReport.edgeCount}, '
      'activeNodeCount=${activeReport.activeNodeCount}, '
      'mixCallCount=${activeReport.mixCallCount}, '
      'staleMixCallCount=${activeReport.staleMixCallCount}, '
      'framesMixed=${activeReport.framesMixed}, '
      'mixChecksum=${activeReport.mixChecksum}, '
      'expectedChecksum=${activeReport.expectedChecksum}, '
      'maxAccumulatorAbs=${activeReport.maxAccumulatorAbs}',
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
      'unit': 'AndroidAudioGraphTopologySmokeHarness',
      'slice': 'P4-AUDIO-GRAPH-TOPOLOGY',
      'target': VGAudioGraphTopologySmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_AUDIO_GRAPH_TOPOLOGY_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AUDIO_GRAPH_TOPOLOGY_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AUDIO_GRAPH_TOPOLOGY_SMOKE_FAIL',
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
