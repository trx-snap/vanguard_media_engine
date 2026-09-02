// android_realtime_playback_pipeline_timestamp_stabilization_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-TIMESTAMP-STABILIZATION (Y6f):
// Android True-DAG Phase 4 realtime playback pipeline timestamp
// stabilization diagnostic physical harness.
//
// Runs two scenarios (FORWARD_PLAYTHROUGH_TIMESTAMP,
// DEAD_OBJECT_EPOCH_RESET_TIMESTAMP) over the real MediaExtractor/MediaCodec
// -> Y5a external ingest -> Y1 transport -> non-zero-gain AudioTrack
// pipeline with AudioTrack.getTimestamp() polled at most once per drain pass
// on the sink thread, per-epoch framePosition monotonicity and one synthetic
// dead-object epoch reset.
// Proof boundary: see
// VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.proofBoundaryConstant.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(
    const AndroidRealtimePlaybackPipelineTimestampStabilizationPhysicalSmokeApp(),
  );
}

class AndroidRealtimePlaybackPipelineTimestampStabilizationPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidRealtimePlaybackPipelineTimestampStabilizationPhysicalSmokeApp({
    super.key,
  });

  @override
  State<AndroidRealtimePlaybackPipelineTimestampStabilizationPhysicalSmokeApp>
  createState() =>
      _AndroidRealtimePlaybackPipelineTimestampStabilizationPhysicalSmokeAppState();
}

class _AndroidRealtimePlaybackPipelineTimestampStabilizationPhysicalSmokeAppState
    extends
        State<
          AndroidRealtimePlaybackPipelineTimestampStabilizationPhysicalSmokeApp
        > {
  String _status =
      'Running Android DAG Phase 4 Realtime Playback Pipeline Timestamp Stabilization smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(
      VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
          .startMarkerConstant,
    );

    VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport? report;
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
          '${Directory.systemTemp.path}/p4_realtime_playback_pipeline_timestamp_stabilization_source_$timestamp.$ext',
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
            await VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.runRealtimePlaybackPipelineTimestampStabilizationSmoke(
              sourcePath: tempSourceFile.path,
              maxDurationSec: 3.0,
              maxFramesPerMix: 256,
              baseVolume: 0.5,
              deadlineMs: 60000,
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
          'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_TIMESTAMP_STABILIZATION_ERROR ($candidate): $topLevelError',
        );
      } catch (e, st) {
        topLevelError = '$e\n$st';
        print(
          'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_TIMESTAMP_STABILIZATION_ERROR ($candidate): $topLevelError',
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
        VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.fromMap(
          null,
        );

    for (final key
        in VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
            .requiredGateKeys) {
      print('  [LANE] $key=${activeReport.gate(key)}');
    }
    print(
      '  [TIMESTAMP_TOTALS] '
      'attempts=${activeReport.metrics['timestampPollAttemptsTotal']}, '
      'successes=${activeReport.metrics['timestampPollSuccessesTotal']}, '
      'unavailable=${activeReport.metrics['timestampPollUnavailableTotal']}, '
      'regressions=${activeReport.metrics['timestampFrameRegressionTotal']}, '
      'wraps=${activeReport.metrics['timestampWrapTotal']}, '
      'violations=${activeReport.metrics['timestampPollViolationsTotal']}',
    );
    for (final scenario in <String>[
      'forward_playthrough_timestamp',
      'dead_object_epoch_reset_timestamp',
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
        'productiveDrainPasses=${scenarioMetrics['productiveDrainPasses']}, '
        'audioTracksCreated=${scenarioMetrics['audioTracksCreated']}, '
        'audioTracksReleased=${scenarioMetrics['audioTracksReleased']}, '
        'audioTrackReleaseCount=${scenarioMetrics['audioTrackReleaseCount']}, '
        'setVolumeCalls=${scenarioMetrics['setVolumeCalls']}, '
        'timestampPollAttempts=${scenarioMetrics['timestampPollAttempts']}, '
        'timestampPollSuccesses=${scenarioMetrics['timestampPollSuccesses']}, '
        'timestampPollUnavailable=${scenarioMetrics['timestampPollUnavailable']}, '
        'timestampMaxPollsInOnePass=${scenarioMetrics['timestampMaxPollsInOnePass']}, '
        'timestampPollViolations=${scenarioMetrics['timestampPollViolations']}, '
        'timestampFrameAdvanceCount=${scenarioMetrics['timestampFrameAdvanceCount']}, '
        'timestampFrameEqualCount=${scenarioMetrics['timestampFrameEqualCount']}, '
        'timestampFrameRegressionCount=${scenarioMetrics['timestampFrameRegressionCount']}, '
        'timestampWrapCount=${scenarioMetrics['timestampWrapCount']}, '
        'timestampEpochOpenCount=${scenarioMetrics['timestampEpochOpenCount']}, '
        'timestampEpochCloseCount=${scenarioMetrics['timestampEpochCloseCount']}, '
        'timestampEpochBaselineResetCount=${scenarioMetrics['timestampEpochBaselineResetCount']}, '
        'timestampCrossEpochComparisonCount=${scenarioMetrics['timestampCrossEpochComparisonCount']}, '
        'epoch0_pollAttempts=${scenarioMetrics['epoch0_pollAttempts']}, '
        'epoch0_pollSuccesses=${scenarioMetrics['epoch0_pollSuccesses']}, '
        'epoch0_firstFramePosition=${scenarioMetrics['epoch0_firstFramePosition']}, '
        'epoch0_lastFramePosition=${scenarioMetrics['epoch0_lastFramePosition']}, '
        'epoch1_pollAttempts=${scenarioMetrics['epoch1_pollAttempts']}, '
        'epoch1_pollSuccesses=${scenarioMetrics['epoch1_pollSuccesses']}, '
        'epoch1_firstFramePosition=${scenarioMetrics['epoch1_firstFramePosition']}, '
        'epoch1_lastFramePosition=${scenarioMetrics['epoch1_lastFramePosition']}, '
        'headSampleCount=${scenarioMetrics['headSampleCount']}, '
        'headRegressionCount=${scenarioMetrics['headRegressionCount']}, '
        'playbackHeadFinal=${scenarioMetrics['playbackHeadFinal']}, '
        'syntheticDeadObjectInjectedCount=${scenarioMetrics['syntheticDeadObjectInjectedCount']}, '
        'deadObjectObservedCount=${scenarioMetrics['deadObjectObservedCount']}, '
        'deadObjectSinkFramesWrittenBeforeRecovery=${scenarioMetrics['deadObjectSinkFramesWrittenBeforeRecovery']}, '
        'deadObjectRemainderFramesWrittenOnNewTrack=${scenarioMetrics['deadObjectRemainderFramesWrittenOnNewTrack']}, '
        'deadObjectNewTrackPlayState=${scenarioMetrics['deadObjectNewTrackPlayState']}, '
        'deadObjectPollsInsideRecoveryWindow=${scenarioMetrics['deadObjectPollsInsideRecoveryWindow']}, '
        'kotlinSinkChecksumHex=${scenarioMetrics['kotlinSinkChecksumHex']}, '
        'nativeDrainedChecksumHex=${scenarioMetrics['nativeDrainedChecksumHex']}, '
        'transportStateTransitions=${scenarioMetrics['transportStateTransitions']}, '
        'transportStateFinal=${scenarioMetrics['transportStateFinal']}, '
        'transportCommandsIssued=${scenarioMetrics['transportCommandsIssued']}',
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
          'AndroidRealtimePlaybackPipelineTimestampStabilizationPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-TIMESTAMP-STABILIZATION',
      'target': VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
          .proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };
    print(
      '${VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.jsonMarkerConstant}:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
                .passMarkerConstant
          : VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
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
