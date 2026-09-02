// android_realtime_playback_pipeline_seek_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SEEK (Y6c): Android True-DAG Phase 4
// realtime playback pipeline seek diagnostic physical harness.
//
// Proof lanes:
//   - Format Probe: formatProbeOk, sourceMime, sourceDurationUs, sampleRate, channelCount, pcmEncoding, declaredFrameCount.
//   - Pre-Roll: preRollOk, preRollFrames, preRollRingFullObserved, preRollPartialWriteObserved, preRollStatePrepared.
//   - Initial Drain & Quiescence: initialDrainOk, seekQuiesceAccountingOk, framesWrittenBeforeHold, drainCallsBeforeHold, quiesceFeedHeld, quiesceSinkReadFrames, quiesceSinkWrittenFrames, preSeekPositionFrame, preSeekPushedFrames, preSeekDrainedFrames.
//   - Park & Pause: sinkParkAckOk, sinkParkCount, sinkPlayStateAtPark, pauseCommandOk, pauseState, postPauseNativeState, sinkPausedOk.
//   - Flush & Seek: sinkFlushAtSeekOk, sinkFlushCount, sinkPlayStateAfterFlush, sinkPlaybackHeadBeforeFlush, sinkPlaybackHeadAfterFlush, seekCommandOk, seekState, postSeekPositionFrame, postSeekPushedFrames, postSeekDrainedFrames.
//   - Re-Anchor & Stale Probe: realDecoderSeekReanchorOk, feedReanchorAcked, seekTargetUs, seekLandedUs, staleGenerationRejectedOk, seekStaleProbeCalls, seekStaleRejected, postSeekPreRollAcked, postSeekPreRollFrames.
//   - Unpark & Resume: sinkResumedOk, sinkUnparkAckWaitMs, sinkUnparkCount, sinkPlayStateAfterUnpark, resumeAccepted, resumeState.
//   - Post-Seek Drain & Sink Accounting: postSeekDrainOk, sinkWriteAccountingOk, framesReadFromTransport, framesWrittenToSink, sinkFramesWrittenAtFlush, postSeekFramesWritten, drainCalls, emptyDrainCount.
//   - Checksum Identity: checksumIdentityOk, kotlinDecoderChecksumHex, nativePushedChecksumHex, nativeDrainedChecksumHex, kotlinSinkChecksumHex.
//   - Playback Head & EOS: postSeekPlaybackHeadAdvancedOk, sinkPlaybackHeadEpochBase, postSeekPlaybackHeadFrames, eosPushed, eosDrained.
//   - Transport & Thread Ownership: transportCompletedOk, threadOwnershipOk, ingestCallbacksOnOwner, ingestCallbacksOffOwner, listenerCallbacksOnOwner, listenerCallbacksOffOwner, decoderThreadId, sinkThreadId, transportCommandsIssued.
//   - Lifecycle & Dispose: lifecycleDisposeOk, mediaReleaseClean, mediaReleaseCount, audioTrackReleaseCount, transportDisposeCalls, decoderThreadJoined, sinkThreadJoined, transportStateFinal.
//   - Proof Boundary & Canonical: proofBoundaryOk, canonical.
//
// Target / proof boundary:
//   realtime_playback_pipeline_seek_diagnostic_only_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_single_track_one_forward_mid_stream_seek_while_paused_feed_held_at_window_aligned_anchor_quiescent_pushed_eq_drained_eq_anchor_discarded_0_sink_park_before_transport_pause_audiotrack_flush_once_on_sink_thread_before_transport_seek_feed_reanchor_generation_pinned_stale_pre_seek_ingest_rejected_before_jni_two_epoch_sink_accounting_epoch_relative_playback_head_no_presentation_clock_no_av_sync_no_latency_no_glitch_no_loudness_no_snr_no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_interactive_ui_no_product_no_editor_no_app_wiring_no_ios_no_streaming_no_cache_no_cpp_changes

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidRealtimePlaybackPipelineSeekPhysicalSmokeApp());
}

class AndroidRealtimePlaybackPipelineSeekPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidRealtimePlaybackPipelineSeekPhysicalSmokeApp({super.key});

  @override
  State<AndroidRealtimePlaybackPipelineSeekPhysicalSmokeApp> createState() =>
      _AndroidRealtimePlaybackPipelineSeekPhysicalSmokeAppState();
}

class _AndroidRealtimePlaybackPipelineSeekPhysicalSmokeAppState
    extends State<AndroidRealtimePlaybackPipelineSeekPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Realtime Playback Pipeline Seek smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(VGRealtimePlaybackPipelineSeekSmokeReport.startMarkerConstant);

    VGRealtimePlaybackPipelineSeekSmokeReport? report;
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
          '${tempDir.path}/p4_realtime_playback_pipeline_seek_source_$timestamp.$ext',
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
            await VGRealtimePlaybackPipelineSeekSmokeReport.runRealtimePlaybackPipelineSeekSmoke(
              sourcePath: tempSourceFile.path,
              maxDurationSec: 3.0,
              maxFramesPerMix: 256,
              baseVolume: 0.5,
              deadlineMs: 30000,
              seekTargetSec: 1.5,
              preSeekHoldWindows: 64,
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
          'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_ERROR ($candidate): $topLevelError',
        );
      } catch (e, st) {
        topLevelError = '$e\n$st';
        print(
          'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_ERROR ($candidate): $topLevelError',
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
        report ?? VGRealtimePlaybackPipelineSeekSmokeReport.fromMap(null);

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

    // 3. Initial Drain & Quiescence
    print(
      '  [LANE] Initial Drain & Quiescence: '
      'initialDrainOk=${activeReport.initialDrainOk}, '
      'seekQuiesceAccountingOk=${activeReport.seekQuiesceAccountingOk}, '
      'framesWrittenBeforeHold=${activeReport.metrics['framesWrittenBeforeHold']}, '
      'drainCallsBeforeHold=${activeReport.metrics['drainCallsBeforeHold']}, '
      'quiesceFeedHeld=${activeReport.metrics['quiesceFeedHeld']}, '
      'quiesceSinkReadFrames=${activeReport.metrics['quiesceSinkReadFrames']}, '
      'quiesceSinkWrittenFrames=${activeReport.metrics['quiesceSinkWrittenFrames']}, '
      'preSeekPositionFrame=${activeReport.metrics['preSeekPositionFrame']}, '
      'preSeekPushedFrames=${activeReport.metrics['preSeekPushedFrames']}, '
      'preSeekDrainedFrames=${activeReport.metrics['preSeekDrainedFrames']}',
    );

    // 4. Park & Pause
    print(
      '  [LANE] Park & Pause: '
      'sinkParkCount=${activeReport.metrics['sinkParkCount']}, '
      'sinkPlayStateAtPark=${activeReport.metrics['sinkPlayStateAtPark']}, '
      'pauseCommandOk=${activeReport.pauseCommandOk}, '
      'pauseState=${activeReport.metrics['pauseState']}, '
      'postPauseNativeState=${activeReport.metrics['postPauseNativeState']}, '
      'sinkPausedOk=${activeReport.sinkPausedOk}',
    );

    // 5. Flush & Seek
    print(
      '  [LANE] Flush & Seek: '
      'sinkFlushAtSeekOk=${activeReport.sinkFlushAtSeekOk}, '
      'sinkFlushCount=${activeReport.metrics['sinkFlushCount']}, '
      'sinkPlayStateAfterFlush=${activeReport.metrics['sinkPlayStateAfterFlush']}, '
      'sinkPlaybackHeadBeforeFlush=${activeReport.metrics['sinkPlaybackHeadBeforeFlush']}, '
      'sinkPlaybackHeadAfterFlush=${activeReport.metrics['sinkPlaybackHeadAfterFlush']}, '
      'seekCommandOk=${activeReport.seekCommandOk}, '
      'seekState=${activeReport.metrics['seekState']}, '
      'postSeekPositionFrame=${activeReport.metrics['postSeekPositionFrame']}, '
      'postSeekPushedFrames=${activeReport.metrics['postSeekPushedFrames']}, '
      'postSeekDrainedFrames=${activeReport.metrics['postSeekDrainedFrames']}',
    );

    // 6. Re-Anchor & Stale Probe
    print(
      '  [LANE] Re-Anchor & Stale Probe: '
      'realDecoderSeekReanchorOk=${activeReport.realDecoderSeekReanchorOk}, '
      'feedReanchorAcked=${activeReport.metrics['feedReanchorAcked']}, '
      'seekTargetUs=${activeReport.metrics['seekTargetUs']}, '
      'seekLandedUs=${activeReport.metrics['seekLandedUs']}, '
      'staleGenerationRejectedOk=${activeReport.staleGenerationRejectedOk}, '
      'seekStaleProbeCalls=${activeReport.metrics['seekStaleProbeCalls']}, '
      'seekStaleRejected=${activeReport.metrics['seekStaleRejected']}, '
      'postSeekPreRollAcked=${activeReport.metrics['postSeekPreRollAcked']}, '
      'postSeekPreRollFrames=${activeReport.metrics['postSeekPreRollFrames']}',
    );

    // 7. Unpark & Resume
    print(
      '  [LANE] Unpark & Resume: '
      'sinkResumedOk=${activeReport.sinkResumedOk}, '
      'sinkUnparkAckWaitMs=${activeReport.metrics['sinkUnparkAckWaitMs']}, '
      'sinkUnparkCount=${activeReport.metrics['sinkUnparkCount']}, '
      'sinkPlayStateAfterUnpark=${activeReport.metrics['sinkPlayStateAfterUnpark']}, '
      'resumeAccepted=${activeReport.metrics['resumeAccepted']}, '
      'resumeState=${activeReport.metrics['resumeState']}',
    );

    // 8. Post-Seek Drain & Sink Accounting
    print(
      '  [LANE] Post-Seek Drain & Sink Accounting: '
      'postSeekDrainOk=${activeReport.postSeekDrainOk}, '
      'sinkWriteAccountingOk=${activeReport.sinkWriteAccountingOk}, '
      'framesReadFromTransport=${activeReport.metrics['framesReadFromTransport']}, '
      'framesWrittenToSink=${activeReport.metrics['framesWrittenToSink']}, '
      'sinkFramesWrittenAtFlush=${activeReport.metrics['sinkFramesWrittenAtFlush']}, '
      'postSeekFramesWritten=${activeReport.metrics['postSeekFramesWritten']}, '
      'drainCalls=${activeReport.metrics['drainCalls']}, '
      'emptyDrainCount=${activeReport.metrics['emptyDrainCount']}',
    );

    // 9. Checksum Identity
    print(
      '  [LANE] Checksum Identity: '
      'checksumIdentityOk=${activeReport.checksumIdentityOk}, '
      'kotlinDecoderChecksumHex=${activeReport.metrics['kotlinDecoderChecksumHex']}, '
      'nativePushedChecksumHex=${activeReport.metrics['nativePushedChecksumHex']}, '
      'nativeDrainedChecksumHex=${activeReport.metrics['nativeDrainedChecksumHex']}, '
      'kotlinSinkChecksumHex=${activeReport.metrics['kotlinSinkChecksumHex']}',
    );

    // 10. Post-Seek Playback Head & EOS
    print(
      '  [LANE] Post-Seek Playback Head & EOS: '
      'postSeekPlaybackHeadAdvancedOk=${activeReport.postSeekPlaybackHeadAdvancedOk}, '
      'sinkPlaybackHeadEpochBase=${activeReport.metrics['sinkPlaybackHeadEpochBase']}, '
      'postSeekPlaybackHeadFrames=${activeReport.metrics['postSeekPlaybackHeadFrames']}, '
      'playbackHeadCaughtUp=${activeReport.metrics['playbackHeadCaughtUp']}, '
      'eosPushed=${activeReport.metrics['eosPushed']}, '
      'eosDrained=${activeReport.metrics['eosDrained']}',
    );

    // 11. Transport & Thread Ownership
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

    // 12. Lifecycle & Dispose
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

    // 13. Proof Boundary & Verification
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
          ? VGRealtimePlaybackPipelineSeekSmokeReport.passMarkerConstant
          : VGRealtimePlaybackPipelineSeekSmokeReport.failMarkerConstant,
    );

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidRealtimePlaybackPipelineSeekPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SEEK',
      'target': VGRealtimePlaybackPipelineSeekSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      '${VGRealtimePlaybackPipelineSeekSmokeReport.jsonMarkerConstant}:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_SEEK_PHYSICAL_SMOKE_FAIL',
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
