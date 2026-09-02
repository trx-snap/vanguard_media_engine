// android_realtime_playback_interactive_controls_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-INTERACTIVE-CONTROLS (Y3): Android True-DAG Phase 4
// realtime playback interactive transport controls diagnostic physical harness.
//
// Proof lanes:
//   - AudioTrack Init & Muting: audioTrackInitOk, mutedOutputOk.
//   - Interactive Pause/Resume: initialDrainOk, pauseCommandOk, sinkPausedOk, pauseHoldFrozenOk, resumeCommandOk, sinkResumedOk.
//   - Interactive Seek: activeBeforeSeekOk, seekCommandOk, sinkFlushAtSeekOk, postSeekDrainOk.
//   - Transport & Lifecycle: transportCompletedOk, audioTrackReleasedOk, lifecycleOk.
//   - Checksum & Write Accounting: checksumIdentityOk, sinkWriteAccountingOk, canonical.
//   - Metrics: sampleRate, channelCount, maxFramesPerMix, declaredFrameCount, pauseHoldMs, preControlFrames, seekTargetFrame, framesReadFromTransport, framesWrittenPreSeek, sinkFramesDiscardedAtSeek, framesWrittenPostSeek, totalFramesWrittenToSink, expectedFramesWrittenToSink, playbackHeadAtPause, playbackHeadAtSeek, playbackHeadFinal, pauseSnapshotDispatchCount, pauseSnapshotPushedFrames, pauseHoldDispatchDelta, pauseHoldPushedDelta, activeProbeAttempts, activeProbeDrainedFrames, seekGenerationBefore, seekGenerationAfter, seekReplyPositionFrame, seekReplyDiscardedFrames, finalReplyPositionFrame, finalReplyDiscardedFrames, drainIterations, partialWriteCount, zeroWriteCount, flushCount, releaseCount, kotlinSinkChecksumHex, nativeDrainedChecksumHex, transportStopCalled, transportStopAccepted, transportState.
//
// Target / proof boundary:
//   muted_diagnostic_audiotrack_interactive_controls_only_synthetic_pcm_from_y1_transport_no_mediacodec_no_mediaextractor_no_audio_focus_no_route_change_no_dead_object_recovery_no_production_presentation_clock_no_av_sync_no_audible_output_no_product_editor_app_wiring_no_ios_no_streaming_cache_no_native_cpp_changes

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidRealtimePlaybackInteractiveControlsPhysicalSmokeApp());
}

class AndroidRealtimePlaybackInteractiveControlsPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidRealtimePlaybackInteractiveControlsPhysicalSmokeApp({super.key});

  @override
  State<AndroidRealtimePlaybackInteractiveControlsPhysicalSmokeApp>
  createState() =>
      _AndroidRealtimePlaybackInteractiveControlsPhysicalSmokeAppState();
}

class _AndroidRealtimePlaybackInteractiveControlsPhysicalSmokeAppState
    extends State<AndroidRealtimePlaybackInteractiveControlsPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Realtime Playback Interactive Controls smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(VGRealtimePlaybackInteractiveControlsSmokeReport.startMarkerConstant);

    VGRealtimePlaybackInteractiveControlsSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGRealtimePlaybackInteractiveControlsSmokeReport.runRealtimePlaybackInteractiveControlsSmoke(
            timeout: const Duration(seconds: 20),
          );
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_ERROR: $topLevelError',
      );
    }

    final activeReport =
        report ??
        const VGRealtimePlaybackInteractiveControlsSmokeReport(
          pass: false,
          status: 'fail',
          marker: VGRealtimePlaybackInteractiveControlsSmokeReport
              .failMarkerConstant,
          proofBoundary: '',
          nativeProofBoundary: '',
          failureReason: 'invocation_failed',
          details: '',
          audioTrackInitOk: false,
          mutedOutputOk: false,
          initialDrainOk: false,
          pauseCommandOk: false,
          sinkPausedOk: false,
          pauseHoldFrozenOk: false,
          resumeCommandOk: false,
          sinkResumedOk: false,
          activeBeforeSeekOk: false,
          seekCommandOk: false,
          sinkFlushAtSeekOk: false,
          postSeekDrainOk: false,
          transportCompletedOk: false,
          checksumIdentityOk: false,
          sinkWriteAccountingOk: false,
          audioTrackReleasedOk: false,
          lifecycleOk: false,
          canonical: false,
          sampleRate: 0,
          channelCount: 0,
          maxFramesPerMix: 0,
          declaredFrameCount: 0,
          pauseHoldMs: 0,
          preControlFrames: 0,
          seekTargetFrame: 0,
          framesReadFromTransport: 0,
          framesWrittenPreSeek: 0,
          sinkFramesDiscardedAtSeek: 0,
          framesWrittenPostSeek: 0,
          totalFramesWrittenToSink: 0,
          expectedFramesWrittenToSink: 0,
          playbackHeadAtPause: 0,
          playbackHeadAtSeek: 0,
          playbackHeadFinal: 0,
          pauseSnapshotDispatchCount: 0,
          pauseSnapshotPushedFrames: 0,
          pauseHoldDispatchDelta: 0,
          pauseHoldPushedDelta: 0,
          activeProbeAttempts: 0,
          activeProbeDrainedFrames: 0,
          seekGenerationBefore: 0,
          seekGenerationAfter: 0,
          seekReplyPositionFrame: -1,
          seekReplyDiscardedFrames: -1,
          finalReplyPositionFrame: -1,
          finalReplyDiscardedFrames: -1,
          drainIterations: 0,
          partialWriteCount: 0,
          zeroWriteCount: 0,
          flushCount: 0,
          releaseCount: 0,
          kotlinSinkChecksumHex: '',
          nativeDrainedChecksumHex: '',
          transportStopCalled: false,
          transportStopAccepted: false,
          transportState: '',
          lanes: <String, Object?>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          metrics: <String, Object?>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          lastError: 'invocation_failed',
        );

    // 1. AudioTrack Init & Muting
    print(
      '  [LANE] AudioTrack Init & Muting: '
      'audioTrackInitOk=${activeReport.audioTrackInitOk}, '
      'mutedOutputOk=${activeReport.mutedOutputOk}',
    );

    // 2. Interactive Pause/Resume
    print(
      '  [LANE] Interactive Pause/Resume: '
      'initialDrainOk=${activeReport.initialDrainOk}, '
      'pauseCommandOk=${activeReport.pauseCommandOk}, '
      'sinkPausedOk=${activeReport.sinkPausedOk}, '
      'pauseHoldFrozenOk=${activeReport.pauseHoldFrozenOk}, '
      'resumeCommandOk=${activeReport.resumeCommandOk}, '
      'sinkResumedOk=${activeReport.sinkResumedOk}, '
      'pauseHoldMs=${activeReport.pauseHoldMs}, '
      'pauseHoldDispatchDelta=${activeReport.pauseHoldDispatchDelta}, '
      'pauseHoldPushedDelta=${activeReport.pauseHoldPushedDelta}',
    );

    // 3. Interactive Seek
    print(
      '  [LANE] Interactive Seek: '
      'activeBeforeSeekOk=${activeReport.activeBeforeSeekOk}, '
      'seekCommandOk=${activeReport.seekCommandOk}, '
      'sinkFlushAtSeekOk=${activeReport.sinkFlushAtSeekOk}, '
      'postSeekDrainOk=${activeReport.postSeekDrainOk}, '
      'seekTargetFrame=${activeReport.seekTargetFrame}, '
      'seekGenerationBefore=${activeReport.seekGenerationBefore}, '
      'seekGenerationAfter=${activeReport.seekGenerationAfter}',
    );

    // 4. Transport & Lifecycle
    print(
      '  [LANE] Transport & Lifecycle: '
      'transportCompletedOk=${activeReport.transportCompletedOk}, '
      'audioTrackReleasedOk=${activeReport.audioTrackReleasedOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'releaseCount=${activeReport.releaseCount}, '
      'playbackHeadFinal=${activeReport.playbackHeadFinal}, '
      'transportState=${activeReport.transportState}',
    );

    // 5. Checksum & Write Accounting
    print(
      '  [LANE] Checksum & Write Accounting: '
      'checksumIdentityOk=${activeReport.checksumIdentityOk}, '
      'sinkWriteAccountingOk=${activeReport.sinkWriteAccountingOk}, '
      'declaredFrameCount=${activeReport.declaredFrameCount}, '
      'preControlFrames=${activeReport.preControlFrames}, '
      'framesWrittenPreSeek=${activeReport.framesWrittenPreSeek}, '
      'framesWrittenPostSeek=${activeReport.framesWrittenPostSeek}, '
      'totalFramesWrittenToSink=${activeReport.totalFramesWrittenToSink}, '
      'expectedFramesWrittenToSink=${activeReport.expectedFramesWrittenToSink}, '
      'partialWriteCount=${activeReport.partialWriteCount}, '
      'zeroWriteCount=${activeReport.zeroWriteCount}, '
      'kotlinSinkChecksumHex=${activeReport.kotlinSinkChecksumHex}, '
      'nativeDrainedChecksumHex=${activeReport.nativeDrainedChecksumHex}',
    );

    // 6. Proof Boundary & Summary
    print(
      '  [LANE] Proof Boundary & Summary: '
      'hasCanonicalProofBoundary=${activeReport.hasCanonicalProofBoundary}, '
      'hasPassMarker=${activeReport.hasPassMarker}, '
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
        activeReport.allNativeLanesPass &&
        activeReport.hasCanonicalProofBoundary &&
        activeReport.hasPassMarker &&
        lastErrorOk;

    print(
      pass
          ? VGRealtimePlaybackInteractiveControlsSmokeReport.passMarkerConstant
          : VGRealtimePlaybackInteractiveControlsSmokeReport.failMarkerConstant,
    );

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidRealtimePlaybackInteractiveControlsPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-INTERACTIVE-CONTROLS',
      'target': VGRealtimePlaybackInteractiveControlsSmokeReport
          .proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      '${VGRealtimePlaybackInteractiveControlsSmokeReport.jsonMarkerConstant}:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_PHYSICAL_SMOKE_FAIL',
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
