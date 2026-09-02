// android_realtime_playback_audiotrack_sink_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-AUDIOTRACK-SINK (Y2): Android True-DAG Phase 4
// realtime playback AudioTrack sink diagnostic physical harness.
//
// Proof lanes:
//   - AudioTrack Init & Muting: audioTrackInitOk, mutedOutputOk.
//   - Transport & Lifecycle: transportCompletedOk, playbackHeadAdvancedOk, audioTrackReleasedOk, lifecycleOk.
//   - Checksum & Write Accounting: checksumIdentityOk, sinkWriteAccountingOk, canonical.
//   - Metrics: sampleRate, channelCount, maxFramesPerMix, declaredFrameCount, framesReadFromTransport, framesWrittenToSink, partialWriteCount, zeroWriteCount, playbackHeadFinal, releaseCount, kotlinSinkChecksumHex, nativeDrainedChecksumHex, transportState.
//
// Target / proof boundary:
//   muted_diagnostic_audiotrack_sink_only_synthetic_pcm_input_expected_from_y1_transport_no_mediacodec_no_mediaextractor_no_audio_focus_no_route_change_no_dead_object_recovery_no_presentation_clock_no_av_sync_no_audible_output_claim_no_product_editor_app_wiring_no_ios_no_native_cpp_changes

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidRealtimePlaybackAudioTrackSinkPhysicalSmokeApp());
}

class AndroidRealtimePlaybackAudioTrackSinkPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidRealtimePlaybackAudioTrackSinkPhysicalSmokeApp({super.key});

  @override
  State<AndroidRealtimePlaybackAudioTrackSinkPhysicalSmokeApp> createState() =>
      _AndroidRealtimePlaybackAudioTrackSinkPhysicalSmokeAppState();
}

class _AndroidRealtimePlaybackAudioTrackSinkPhysicalSmokeAppState
    extends State<AndroidRealtimePlaybackAudioTrackSinkPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Realtime Playback AudioTrack Sink smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(VGRealtimePlaybackAudioTrackSinkSmokeReport.startMarkerConstant);

    VGRealtimePlaybackAudioTrackSinkSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGRealtimePlaybackAudioTrackSinkSmokeReport.runRealtimePlaybackAudioTrackSinkSmoke(
            timeout: const Duration(seconds: 20),
          );
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_ERROR: $topLevelError',
      );
    }

    final activeReport =
        report ??
        const VGRealtimePlaybackAudioTrackSinkSmokeReport(
          pass: false,
          status: 'fail',
          marker:
              VGRealtimePlaybackAudioTrackSinkSmokeReport.failMarkerConstant,
          proofBoundary: '',
          nativeProofBoundary: '',
          failureReason: 'invocation_failed',
          details: '',
          audioTrackInitOk: false,
          mutedOutputOk: false,
          transportCompletedOk: false,
          checksumIdentityOk: false,
          sinkWriteAccountingOk: false,
          playbackHeadAdvancedOk: false,
          audioTrackReleasedOk: false,
          lifecycleOk: false,
          canonical: false,
          sampleRate: 0,
          channelCount: 0,
          maxFramesPerMix: 0,
          declaredFrameCount: 0,
          framesReadFromTransport: 0,
          framesWrittenToSink: 0,
          partialWriteCount: 0,
          zeroWriteCount: 0,
          playbackHeadFinal: 0,
          releaseCount: 0,
          kotlinSinkChecksumHex: '',
          nativeDrainedChecksumHex: '',
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

    // 2. Transport & Lifecycle
    print(
      '  [LANE] Transport & Lifecycle: '
      'transportCompletedOk=${activeReport.transportCompletedOk}, '
      'playbackHeadAdvancedOk=${activeReport.playbackHeadAdvancedOk}, '
      'audioTrackReleasedOk=${activeReport.audioTrackReleasedOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'releaseCount=${activeReport.releaseCount}, '
      'playbackHeadFinal=${activeReport.playbackHeadFinal}, '
      'transportState=${activeReport.transportState}',
    );

    // 3. Checksum & Write Accounting
    print(
      '  [LANE] Checksum & Write Accounting: '
      'checksumIdentityOk=${activeReport.checksumIdentityOk}, '
      'sinkWriteAccountingOk=${activeReport.sinkWriteAccountingOk}, '
      'declaredFrameCount=${activeReport.declaredFrameCount}, '
      'framesReadFromTransport=${activeReport.framesReadFromTransport}, '
      'framesWrittenToSink=${activeReport.framesWrittenToSink}, '
      'partialWriteCount=${activeReport.partialWriteCount}, '
      'zeroWriteCount=${activeReport.zeroWriteCount}, '
      'kotlinSinkChecksumHex=${activeReport.kotlinSinkChecksumHex}, '
      'nativeDrainedChecksumHex=${activeReport.nativeDrainedChecksumHex}',
    );

    // 4. Proof Boundary & Summary
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
          ? VGRealtimePlaybackAudioTrackSinkSmokeReport.passMarkerConstant
          : VGRealtimePlaybackAudioTrackSinkSmokeReport.failMarkerConstant,
    );

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidRealtimePlaybackAudioTrackSinkPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-AUDIOTRACK-SINK',
      'target':
          VGRealtimePlaybackAudioTrackSinkSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      '${VGRealtimePlaybackAudioTrackSinkSmokeReport.jsonMarkerConstant}:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_PHYSICAL_SMOKE_FAIL',
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
