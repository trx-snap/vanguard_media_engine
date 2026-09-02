// android_realtime_playback_pipeline_clock_sync_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-CLOCK-SYNCHRONIZATION (Y7):
// Android True-DAG Phase 4 realtime playback pipeline clock synchronization
// diagnostic physical harness.
//
// Runs two sequential scenarios (FORWARD_PLAYTHROUGH_CLOCK_SYNC,
// DEAD_OBJECT_CLOCK_EPOCH_RESET) preceded by a deterministic clock self-check
// over the real MediaExtractor/MediaCodec -> Y5a external ingest -> Y1 native
// transport -> non-zero-gain AudioTrack pipeline with sink thread owning every
// AudioTrack method and presentation clock updates, monotonic downstream
// presentation clock snapshots, bounded extrapolation, and one synthetic
// dead-object epoch reset.
// Proof boundary: see
// VGRealtimePlaybackPipelineClockSyncSmokeReport.proofBoundaryConstant.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidRealtimePlaybackPipelineClockSyncPhysicalSmokeApp());
}

class AndroidRealtimePlaybackPipelineClockSyncPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidRealtimePlaybackPipelineClockSyncPhysicalSmokeApp({super.key});

  @override
  State<AndroidRealtimePlaybackPipelineClockSyncPhysicalSmokeApp>
  createState() =>
      _AndroidRealtimePlaybackPipelineClockSyncPhysicalSmokeAppState();
}

class _AndroidRealtimePlaybackPipelineClockSyncPhysicalSmokeAppState
    extends State<AndroidRealtimePlaybackPipelineClockSyncPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Realtime Playback Pipeline Clock Sync smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(VGRealtimePlaybackPipelineClockSyncSmokeReport.startMarkerConstant);

    VGRealtimePlaybackPipelineClockSyncSmokeReport? report;
    String? topLevelError;
    String? selectedSource;

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
          '${Directory.systemTemp.path}/p4_realtime_playback_pipeline_clock_sync_source_$timestamp.$ext',
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
            await VGRealtimePlaybackPipelineClockSyncSmokeReport.runRealtimePlaybackPipelineClockSyncSmoke(
              sourcePath: tempSourceFile.path,
              maxDurationSec: 3.0,
              maxFramesPerMix: 256,
              baseVolume: 0.5,
              deadlineMs: 60000,
              phaseFrames: 2048,
              extrapolationHorizonMs: 250,
              timeout: const Duration(seconds: 70),
            );
        report = candidateReport;
        topLevelError = null;
        selectedSource = candidate;
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
          'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_CLOCK_SYNC_ERROR ($candidate): $topLevelError',
        );
      } catch (e, st) {
        topLevelError = '$e\n$st';
        print(
          'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_CLOCK_SYNC_ERROR ($candidate): $topLevelError',
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
        report ?? VGRealtimePlaybackPipelineClockSyncSmokeReport.fromMap(null);

    print('  [SELECTED_SOURCE] ${selectedSource ?? "none"}');

    for (final key
        in VGRealtimePlaybackPipelineClockSyncSmokeReport.requiredGateKeys) {
      print('  [LANE] $key=${activeReport.gate(key)}');
    }
    print(
      '  [CLOCK_SYNC_TOTALS] '
      'attempts=${activeReport.metrics['timestampPollAttemptsTotal']}, '
      'successes=${activeReport.metrics['timestampPollSuccessesTotal']}, '
      'unavailable=${activeReport.metrics['timestampPollUnavailableTotal']}, '
      'regressions=${activeReport.metrics['timestampFrameRegressionTotal']}, '
      'wraps=${activeReport.metrics['timestampWrapTotal']}, '
      'violations=${activeReport.metrics['timestampPollViolationsTotal']}, '
      'clockAnchored=${activeReport.metrics['clockAnchoredTotal']}, '
      'clockExtrapolated=${activeReport.metrics['clockExtrapolatedTotal']}, '
      'clockStale=${activeReport.metrics['clockStaleTotal']}, '
      'clockNoAnchor=${activeReport.metrics['clockNoAnchorTotal']}, '
      'clockRejected=${activeReport.metrics['clockRejectedTotal']}, '
      'clockSnapshots=${activeReport.metrics['clockCoordinatorSnapshotsTotal']}',
    );
    for (final scenario in <String>[
      'forward_playthrough_clock_sync',
      'dead_object_clock_epoch_reset',
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
        'clockAnchoredCount=${scenarioMetrics['clockAnchoredCount']}, '
        'clockExtrapolatedCount=${scenarioMetrics['clockExtrapolatedCount']}, '
        'clockStaleCount=${scenarioMetrics['clockStaleCount']}, '
        'clockNoAnchorCount=${scenarioMetrics['clockNoAnchorCount']}, '
        'clockRejectedCount=${scenarioMetrics['clockRejectedCount']}, '
        'clockSampleCount=${scenarioMetrics['clockSampleCount']}, '
        'clockSampleAdvanceCount=${scenarioMetrics['clockSampleAdvanceCount']}, '
        'clockSampleRegressionCount=${scenarioMetrics['clockSampleRegressionCount']}, '
        'clockSampleStaleHoldCount=${scenarioMetrics['clockSampleStaleHoldCount']}, '
        'clockFirstPositionFrames=${scenarioMetrics['clockFirstPositionFrames']}, '
        'clockLastPositionFrames=${scenarioMetrics['clockLastPositionFrames']}, '
        'syntheticDeadObjectInjectedCount=${scenarioMetrics['syntheticDeadObjectInjectedCount']}, '
        'deadObjectObservedCount=${scenarioMetrics['deadObjectObservedCount']}, '
        'deadObjectSinkFramesWrittenBeforeRecovery=${scenarioMetrics['deadObjectSinkFramesWrittenBeforeRecovery']}, '
        'deadObjectRemainderFramesWrittenOnNewTrack=${scenarioMetrics['deadObjectRemainderFramesWrittenOnNewTrack']}, '
        'deadObjectNewTrackPlayState=${scenarioMetrics['deadObjectNewTrackPlayState']}, '
        'deadObjectPollsInsideRecoveryWindow=${scenarioMetrics['deadObjectPollsInsideRecoveryWindow']}, '
        'deadObjectClockResetCount=${scenarioMetrics['deadObjectClockResetCount']}, '
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
      'unit': 'AndroidRealtimePlaybackPipelineClockSyncPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-CLOCK-SYNCHRONIZATION',
      'target':
          VGRealtimePlaybackPipelineClockSyncSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'selectedSource': selectedSource,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };
    print(
      '${VGRealtimePlaybackPipelineClockSyncSmokeReport.jsonMarkerConstant}:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? VGRealtimePlaybackPipelineClockSyncSmokeReport.passMarkerConstant
          : VGRealtimePlaybackPipelineClockSyncSmokeReport.failMarkerConstant,
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (isVerifiedPass=true, hasCanonicalProofBoundary=true, source=$selectedSource)'
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
