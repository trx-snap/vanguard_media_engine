// android_realtime_playback_pipeline_sink_fault_tolerance_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SINK-FAULT-TOLERANCE (Y6e):
// Android True-DAG Phase 4 realtime playback pipeline sink fault tolerance
// diagnostic physical harness.
//
// Runs two scenarios (EOS_WITH_DEAD_OBJECT_RECOVERY,
// ROUTE_DISCONNECT_TERMINAL) over the real MediaExtractor/MediaCodec -> Y5a
// external ingest -> Y1 transport -> non-zero-gain AudioTrack pipeline with
// the Y4b routing listener attached and synthetic routing / dead-object
// faults applied on the sink thread.
// Proof boundary: see
// VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.proofBoundaryConstant.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(
    const AndroidRealtimePlaybackPipelineSinkFaultTolerancePhysicalSmokeApp(),
  );
}

class AndroidRealtimePlaybackPipelineSinkFaultTolerancePhysicalSmokeApp
    extends StatefulWidget {
  const AndroidRealtimePlaybackPipelineSinkFaultTolerancePhysicalSmokeApp({
    super.key,
  });

  @override
  State<AndroidRealtimePlaybackPipelineSinkFaultTolerancePhysicalSmokeApp>
  createState() =>
      _AndroidRealtimePlaybackPipelineSinkFaultTolerancePhysicalSmokeAppState();
}

class _AndroidRealtimePlaybackPipelineSinkFaultTolerancePhysicalSmokeAppState
    extends
        State<
          AndroidRealtimePlaybackPipelineSinkFaultTolerancePhysicalSmokeApp
        > {
  String _status =
      'Running Android DAG Phase 4 Realtime Playback Pipeline Sink Fault Tolerance smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(
      VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
          .startMarkerConstant,
    );

    VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport? report;
    String? topLevelError;

    final candidates = <String>[
      'assets/manual_test_clips/clip_B.mov',
      'assets/manual_test_clips/clip_A.mov',
      'assets/manual_test_clips/clip_A.mp3',
    ];

    for (final candidate in candidates) {
      File? tempSourceFile;
      try {
        ByteData assetData;
        try {
          assetData = await rootBundle.load(candidate);
        } catch (loadErr) {
          print('  [CANDIDATE_SKIP] Could not load $candidate: $loadErr');
          continue;
        }
        final ext = candidate.endsWith('.mp3') ? 'mp3' : 'mov';
        final timestamp = DateTime.now().microsecondsSinceEpoch;
        tempSourceFile = File(
          '${Directory.systemTemp.path}/p4_realtime_playback_pipeline_sink_fault_tolerance_source_$timestamp.$ext',
        );
        await tempSourceFile.writeAsBytes(
          assetData.buffer.asUint8List(
            assetData.offsetInBytes,
            assetData.lengthInBytes,
          ),
          flush: true,
        );
        print('  [SETUP] Extracted asset $candidate to ${tempSourceFile.path}');

        final candidateReport =
            await VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.runRealtimePlaybackPipelineSinkFaultToleranceSmoke(
              sourcePath: tempSourceFile.path,
              maxDurationSec: 3.0,
              maxFramesPerMix: 256,
              baseVolume: 0.5,
              deadlineMs: 60000,
              pauseHoldMs: 150,
              phaseFrames: 2048,
              timeout: const Duration(seconds: 70),
            );
        report = candidateReport;
        topLevelError = null;
        if (candidateReport.isVerifiedPass) {
          print('  [CANDIDATE_PASS] Verified pass achieved with $candidate');
          break;
        } else {
          print(
            '  [CANDIDATE_FAIL] Candidate $candidate failed: status=${candidateReport.status}, reason=${candidateReport.failureReason}. Trying next candidate...',
          );
        }
      } on TimeoutException catch (te) {
        topLevelError = 'timeout: $te';
        print(
          'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SINK_FAULT_TOLERANCE_ERROR ($candidate): $topLevelError',
        );
      } catch (e, st) {
        topLevelError = '$e\n$st';
        print(
          'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SINK_FAULT_TOLERANCE_ERROR ($candidate): $topLevelError',
        );
      } finally {
        if (tempSourceFile != null) {
          try {
            if (await tempSourceFile.exists()) {
              await tempSourceFile.delete();
              print('  [CLEANUP] Deleted temp file ${tempSourceFile.path}');
            }
          } catch (cleanupErr) {
            print('  [CLEANUP_WARN] Failed to delete temp file: $cleanupErr');
          }
        }
      }
    }

    final activeReport =
        report ??
        VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.fromMap(null);

    for (final key
        in VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
            .requiredGateKeys) {
      print('  [LANE] $key=${activeReport.gate(key)}');
    }
    for (final scenario in <String>[
      'eos_with_dead_object_recovery',
      'route_disconnect_terminal',
    ]) {
      final m = activeReport.metrics[scenario];
      final scenarioMetrics = m is Map ? m : const <Object?, Object?>{};
      print(
        '  [SCENARIO] $scenario: pass=${activeReport.metrics['${scenario}ScenarioPass']}, '
        'failureReason=${scenarioMetrics['failureReason']}, '
        'sinkExitReason=${scenarioMetrics['sinkExitReason']}, '
        'decoderExitReason=${scenarioMetrics['decoderExitReason']}, '
        'framesWrittenToSink=${scenarioMetrics['framesWrittenToSink']}, '
        'declaredFrameCount=${scenarioMetrics['declaredFrameCount']}, '
        'audioTracksCreated=${scenarioMetrics['audioTracksCreated']}, '
        'audioTracksReleased=${scenarioMetrics['audioTracksReleased']}, '
        'audioTrackReleaseCount=${scenarioMetrics['audioTrackReleaseCount']}, '
        'setVolumeCalls=${scenarioMetrics['setVolumeCalls']}, '
        'routeChangedAppliedCount=${scenarioMetrics['routeChangedAppliedCount']}, '
        'syntheticRouteChangedAppliedCount=${scenarioMetrics['syntheticRouteChangedAppliedCount']}, '
        'routeDisconnectAppliedCount=${scenarioMetrics['routeDisconnectAppliedCount']}, '
        'syntheticDeadObjectInjectedCount=${scenarioMetrics['syntheticDeadObjectInjectedCount']}, '
        'deadObjectObservedCount=${scenarioMetrics['deadObjectObservedCount']}, '
        'deadObjectSinkFramesWrittenBeforeRecovery=${scenarioMetrics['deadObjectSinkFramesWrittenBeforeRecovery']}, '
        'deadObjectRemainderFramesWrittenOnNewTrack=${scenarioMetrics['deadObjectRemainderFramesWrittenOnNewTrack']}, '
        'deadObjectNewTrackPlayState=${scenarioMetrics['deadObjectNewTrackPlayState']}, '
        'autoResumeAllowed=${scenarioMetrics['autoResumeAllowed']}, '
        'sinkParkCount=${scenarioMetrics['sinkParkCount']}, '
        'holdDispatchDelta=${scenarioMetrics['holdDispatchDelta']}, '
        'holdPushedDelta=${scenarioMetrics['holdPushedDelta']}, '
        'holdDrainCallsDelta=${scenarioMetrics['holdDrainCallsDelta']}, '
        'holdWrittenDelta=${scenarioMetrics['holdWrittenDelta']}, '
        'kotlinSinkChecksumHex=${scenarioMetrics['kotlinSinkChecksumHex']}, '
        'kotlinSinkChecksumAtParkHex=${scenarioMetrics['kotlinSinkChecksumAtParkHex']}, '
        'prefixNativeDrainedChecksumHex=${scenarioMetrics['prefixNativeDrainedChecksumHex']}, '
        'nativeDrainedChecksumHex=${scenarioMetrics['nativeDrainedChecksumHex']}, '
        'transportStateTransitions=${scenarioMetrics['transportStateTransitions']}, '
        'transportStateFinal=${scenarioMetrics['transportStateFinal']}, '
        'stopCalls=${scenarioMetrics['stopCalls']}, '
        'routing_attachCount=${scenarioMetrics['routing_attachCount']}, '
        'routing_detachCount=${scenarioMetrics['routing_detachCount']}, '
        'routing_eventsEnqueued=${scenarioMetrics['routing_eventsEnqueued']}, '
        'routing_eventsDrained=${scenarioMetrics['routing_eventsDrained']}, '
        'routing_eventsDropped=${scenarioMetrics['routing_eventsDropped']}, '
        'lateSyntheticPostRejected=${scenarioMetrics['lateSyntheticPostRejected']}',
      );
    }
    print(
      '  [LANE] Proof Boundary & Verification: '
      'proofBoundaryOk=${activeReport.proofBoundaryOk}, '
      'canonical=${activeReport.canonical}, '
      'hasCanonicalProofBoundary=${activeReport.hasCanonicalProofBoundary}, '
      'hasPassMarker=${activeReport.hasPassMarker}, '
      'isVerifiedPass=${activeReport.isVerifiedPass}, '
      'failureReason=${activeReport.failureReason}, '
      'lastError=${activeReport.lastError}',
    );

    final lastErrorOk =
        activeReport.lastError.isEmpty ||
        activeReport.lastError == 'none' ||
        activeReport.lastError == 'null';
    final pass =
        topLevelError == null &&
        activeReport.pass &&
        activeReport.isVerifiedPass &&
        activeReport.hasCanonicalProofBoundary &&
        activeReport.hasPassMarker &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit':
          'AndroidRealtimePlaybackPipelineSinkFaultTolerancePhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SINK-FAULT-TOLERANCE',
      'target': VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
          .proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };
    print(
      '${VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport.jsonMarkerConstant}:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
                .passMarkerConstant
          : VGRealtimePlaybackPipelineSinkFaultToleranceSmokeReport
                .failMarkerConstant,
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (isVerifiedPass=true, hasCanonicalProofBoundary=true)'
            : 'FAIL: lastError=${activeReport.lastError}, failureReason=${activeReport.failureReason}, error=$topLevelError';
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
