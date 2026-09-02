// android_realtime_playback_pipeline_pause_resume_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-PAUSE-RESUME (Y6b): Android True-DAG Phase 4
// realtime playback pipeline pause/resume diagnostic physical harness.
//
// Proof lanes:
//   - Format Probe: formatProbeOk, sourceMime, sourceDurationUs, sampleRate, channelCount, pcmEncoding, declaredFrameCount.
//   - Pre-Roll: preRollOk, preRollFrames, preRollRingFullObserved, preRollPartialWriteObserved, preRollStatePrepared.
//   - Initial Drain & Park: initialDrainOk, framesWrittenBeforePark, drainCallsBeforePark, sinkParkAckOk, sinkParkAckLatencyMs, sinkParkCount, sinkPlayStateAtPark.
//   - Pause Command & Hold: pauseCommandOk, pauseState, holdStartPositionFrame, holdEndPositionFrame, holdDispatchDelta, holdPushedDelta, holdDrainCallsDelta, holdWrittenDelta, holdActualMs, sinkPausedOk, pauseHoldFrozenOk.
//   - Unpark & Resume: sinkResumedOk, sinkUnparkAckWaitMs, sinkUnparkCount, sinkPlayStateAfterUnpark, sinkParkedHoldMs, resumeCommandOk, resumeState.
//   - Post-Resume Drain & Sink Accounting: postResumeDrainOk, sinkWriteAccountingOk, framesReadFromTransport, framesWrittenToSink, partialWriteCount, zeroWriteCount, drainCalls, emptyDrainCount.
//   - Checksum Identity: checksumIdentityOk, kotlinDecoderChecksumHex, nativePushedChecksumHex, nativeDrainedChecksumHex, kotlinSinkChecksumHex.
//   - Playback Head & EOS: playbackHeadAdvancedOk, playbackHeadFinal, playbackHeadCaughtUp, eosPushed, eosDrained.
//   - Transport & Thread Ownership: transportCompletedOk, threadOwnershipOk, ingestCallbacksOnOwner, ingestCallbacksOffOwner, listenerCallbacksOnOwner, listenerCallbacksOffOwner, decoderThreadId, sinkThreadId, transportCommandsIssued.
//   - Lifecycle & Dispose: lifecycleDisposeOk, mediaReleaseClean, mediaReleaseCount, audioTrackReleaseCount, transportDisposeCalls, decoderThreadJoined, sinkThreadJoined, transportStateFinal.
//   - Proof Boundary & Canonical: proofBoundaryOk, canonical.
//
// Target / proof boundary:
//   realtime_playback_pipeline_pause_resume_diagnostic_only_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_single_track_forward_playthrough_pause_resume_only_sink_park_before_transport_pause_sink_unpark_before_transport_resume_no_seek_no_flush_no_feed_reanchor_no_presentation_clock_no_av_sync_no_interactive_controls_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_product_no_editor_no_app_wiring_no_ios_no_streaming_no_cache_no_cpp_changes

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidRealtimePlaybackPipelinePauseResumePhysicalSmokeApp());
}

class AndroidRealtimePlaybackPipelinePauseResumePhysicalSmokeApp
    extends StatefulWidget {
  const AndroidRealtimePlaybackPipelinePauseResumePhysicalSmokeApp({super.key});

  @override
  State<AndroidRealtimePlaybackPipelinePauseResumePhysicalSmokeApp>
  createState() =>
      _AndroidRealtimePlaybackPipelinePauseResumePhysicalSmokeAppState();
}

class _AndroidRealtimePlaybackPipelinePauseResumePhysicalSmokeAppState
    extends State<AndroidRealtimePlaybackPipelinePauseResumePhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Realtime Playback Pipeline Pause/Resume smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(VGRealtimePlaybackPipelinePauseResumeSmokeReport.startMarkerConstant);

    VGRealtimePlaybackPipelinePauseResumeSmokeReport? report;
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
        final tempDir = Directory.systemTemp;
        final timestamp = DateTime.now().microsecondsSinceEpoch;
        tempSourceFile = File(
          '${tempDir.path}/p4_realtime_playback_pipeline_pause_resume_source_$timestamp.$ext',
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
            await VGRealtimePlaybackPipelinePauseResumeSmokeReport.runRealtimePlaybackPipelinePauseResumeSmoke(
              sourcePath: tempSourceFile.path,
              maxDurationSec: 3.0,
              maxFramesPerMix: 256,
              baseVolume: 0.5,
              deadlineMs: 30000,
              pauseHoldMs: 150,
              timeout: const Duration(seconds: 40),
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
          'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_PAUSE_RESUME_ERROR ($candidate): $topLevelError',
        );
      } catch (e, st) {
        topLevelError = '$e\n$st';
        print(
          'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_PAUSE_RESUME_ERROR ($candidate): $topLevelError',
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
        VGRealtimePlaybackPipelinePauseResumeSmokeReport.fromMap(null);

    // 1. Format Probe
    print(
      '  [LANE] Format Probe: '
      'formatProbeOk=${activeReport.formatProbeOk}, '
      'sourceMime=${activeReport.metrics['sourceMime']}, '
      'sourceDurationUs=${activeReport.metrics['sourceDurationUs']}, '
      'sampleRate=${activeReport.metrics['sampleRate']}, '
      'channelCount=${activeReport.metrics['channelCount']}, '
      'pcmEncoding=${activeReport.metrics['pcmEncoding']}, '
      'declaredFrameCount=${activeReport.metrics['declaredFrameCount']}',
    );

    // 2. Pre-Roll
    print(
      '  [LANE] Pre-Roll: '
      'preRollOk=${activeReport.preRollOk}, '
      'preRollFrames=${activeReport.metrics['preRollFrames']}, '
      'preRollRingFullObserved=${activeReport.metrics['preRollRingFullObserved']}, '
      'preRollPartialWriteObserved=${activeReport.metrics['preRollPartialWriteObserved']}, '
      'preRollStatePrepared=${activeReport.metrics['preRollStatePrepared']}',
    );

    // 3. Initial Drain & Park
    print(
      '  [LANE] Initial Drain & Park: '
      'initialDrainOk=${activeReport.initialDrainOk}, '
      'framesWrittenBeforePark=${activeReport.metrics['framesWrittenBeforePark']}, '
      'drainCallsBeforePark=${activeReport.metrics['drainCallsBeforePark']}, '
      'sinkParkAckOk=${activeReport.sinkParkAckOk}, '
      'sinkParkAckLatencyMs=${activeReport.metrics['sinkParkAckLatencyMs']}, '
      'sinkParkCount=${activeReport.metrics['sinkParkCount']}, '
      'sinkPlayStateAtPark=${activeReport.metrics['sinkPlayStateAtPark']}',
    );

    // 4. Pause Command & Hold
    print(
      '  [LANE] Pause Command & Hold: '
      'pauseCommandOk=${activeReport.pauseCommandOk}, '
      'pauseState=${activeReport.metrics['pauseState']}, '
      'holdStartPositionFrame=${activeReport.metrics['holdStartPositionFrame']}, '
      'holdEndPositionFrame=${activeReport.metrics['holdEndPositionFrame']}, '
      'holdDispatchDelta=${activeReport.metrics['holdDispatchDelta']}, '
      'holdPushedDelta=${activeReport.metrics['holdPushedDelta']}, '
      'holdDrainCallsDelta=${activeReport.metrics['holdDrainCallsDelta']}, '
      'holdWrittenDelta=${activeReport.metrics['holdWrittenDelta']}, '
      'holdActualMs=${activeReport.metrics['holdActualMs']}, '
      'sinkPausedOk=${activeReport.sinkPausedOk}, '
      'pauseHoldFrozenOk=${activeReport.pauseHoldFrozenOk}',
    );

    // 5. Unpark & Resume
    print(
      '  [LANE] Unpark & Resume: '
      'sinkResumedOk=${activeReport.sinkResumedOk}, '
      'sinkUnparkAckWaitMs=${activeReport.metrics['sinkUnparkAckWaitMs']}, '
      'sinkUnparkCount=${activeReport.metrics['sinkUnparkCount']}, '
      'sinkPlayStateAfterUnpark=${activeReport.metrics['sinkPlayStateAfterUnpark']}, '
      'sinkParkedHoldMs=${activeReport.metrics['sinkParkedHoldMs']}, '
      'resumeCommandOk=${activeReport.resumeCommandOk}, '
      'resumeState=${activeReport.metrics['resumeState']}',
    );

    // 6. Post-Resume Drain & Sink Accounting
    print(
      '  [LANE] Post-Resume Drain & Sink Accounting: '
      'postResumeDrainOk=${activeReport.postResumeDrainOk}, '
      'sinkWriteAccountingOk=${activeReport.sinkWriteAccountingOk}, '
      'framesReadFromTransport=${activeReport.metrics['framesReadFromTransport']}, '
      'framesWrittenToSink=${activeReport.metrics['framesWrittenToSink']}, '
      'partialWriteCount=${activeReport.metrics['partialWriteCount']}, '
      'zeroWriteCount=${activeReport.metrics['zeroWriteCount']}, '
      'drainCalls=${activeReport.metrics['drainCalls']}, '
      'emptyDrainCount=${activeReport.metrics['emptyDrainCount']}',
    );

    // 7. Checksum Identity
    print(
      '  [LANE] Checksum Identity: '
      'checksumIdentityOk=${activeReport.checksumIdentityOk}, '
      'kotlinDecoderChecksumHex=${activeReport.metrics['kotlinDecoderChecksumHex']}, '
      'nativePushedChecksumHex=${activeReport.metrics['nativePushedChecksumHex']}, '
      'nativeDrainedChecksumHex=${activeReport.metrics['nativeDrainedChecksumHex']}, '
      'kotlinSinkChecksumHex=${activeReport.metrics['kotlinSinkChecksumHex']}',
    );

    // 8. Playback Head & EOS
    print(
      '  [LANE] Playback Head & EOS: '
      'playbackHeadAdvancedOk=${activeReport.playbackHeadAdvancedOk}, '
      'playbackHeadFinal=${activeReport.metrics['playbackHeadFinal']}, '
      'playbackHeadCaughtUp=${activeReport.metrics['playbackHeadCaughtUp']}, '
      'eosPushed=${activeReport.metrics['eosPushed']}, '
      'eosDrained=${activeReport.metrics['eosDrained']}',
    );

    // 9. Transport & Thread Ownership
    print(
      '  [LANE] Transport & Thread Ownership: '
      'transportCompletedOk=${activeReport.transportCompletedOk}, '
      'threadOwnershipOk=${activeReport.threadOwnershipOk}, '
      'ingestCallbacksOnOwner=${activeReport.metrics['ingestCallbacksOnOwner']}, '
      'ingestCallbacksOffOwner=${activeReport.metrics['ingestCallbacksOffOwner']}, '
      'listenerCallbacksOnOwner=${activeReport.metrics['listenerCallbacksOnOwner']}, '
      'listenerCallbacksOffOwner=${activeReport.metrics['listenerCallbacksOffOwner']}, '
      'decoderThreadId=${activeReport.metrics['decoderThreadId']}, '
      'sinkThreadId=${activeReport.metrics['sinkThreadId']}, '
      'transportCommandsIssued=${activeReport.metrics['transportCommandsIssued']}',
    );

    // 10. Lifecycle & Dispose
    print(
      '  [LANE] Lifecycle & Dispose: '
      'lifecycleDisposeOk=${activeReport.lifecycleDisposeOk}, '
      'mediaReleaseClean=${activeReport.metrics['mediaReleaseClean']}, '
      'mediaReleaseCount=${activeReport.metrics['mediaReleaseCount']}, '
      'audioTrackReleaseCount=${activeReport.metrics['audioTrackReleaseCount']}, '
      'transportDisposeCalls=${activeReport.metrics['transportDisposeCalls']}, '
      'decoderThreadJoined=${activeReport.metrics['decoderThreadJoined']}, '
      'sinkThreadJoined=${activeReport.metrics['sinkThreadJoined']}, '
      'transportStateFinal=${activeReport.metrics['transportStateFinal']}',
    );

    // 11. Proof Boundary & Verification
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
        (topLevelError == null) &&
        activeReport.pass &&
        activeReport.isVerifiedPass &&
        activeReport.hasCanonicalProofBoundary &&
        activeReport.hasPassMarker &&
        lastErrorOk;

    print(
      pass
          ? VGRealtimePlaybackPipelinePauseResumeSmokeReport.passMarkerConstant
          : VGRealtimePlaybackPipelinePauseResumeSmokeReport.failMarkerConstant,
    );

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidRealtimePlaybackPipelinePauseResumePhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-PAUSE-RESUME',
      'target': VGRealtimePlaybackPipelinePauseResumeSmokeReport
          .proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      '${VGRealtimePlaybackPipelinePauseResumeSmokeReport.jsonMarkerConstant}:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_PAUSE_RESUME_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_PAUSE_RESUME_PHYSICAL_SMOKE_FAIL',
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
