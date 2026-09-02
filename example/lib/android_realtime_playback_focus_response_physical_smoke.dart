// android_realtime_playback_focus_response_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-FOCUS-RESPONSE (Y4a): Android True-DAG Phase 4
// realtime playback audio focus and becoming noisy response diagnostic physical harness.
//
// Proof lanes:
//   - Focus & Receiver Lifecycle: focusGrantedOk, noisyReceiverRegisteredOk, focusAbandonedOk, receiverUnregisteredOk, eventsDroppedZeroOk, lifecycleOk.
//   - Realtime Gain & Ducking: baseGainSetOk, duckAppliedOk, duckRestoreOk, baseGain, duckGain.
//   - Transient Pause & Resume: transientPauseResumeOk, becomingNoisyPauseOk, permanentStopNoAutoResumeOk.
//   - Transport & AudioTrack: transportStoppedOk, transportCompletedOk, checksumIdentityOk, sinkWriteAccountingOk, audioTrackReleasedOk.
//   - Scenarios: eosScenarioPass, noisyTerminalScenarioPass, permanentTerminalScenarioPass, allNativeLanesPass, canonical.
//
// Target / proof boundary:
//   realtime_playback_focus_noisy_response_diagnostic_only_nonzero_gain_audiotrack_sink_base_gain_0_5_duck_gain_0_1_setvolume_telemetry_only_synthetic_pcm_from_y1_transport_no_mediacodec_no_mediaextractor_no_route_change_no_dead_object_recovery_no_presentation_clock_no_av_sync_no_os_focus_arbitration_claim_no_audible_output_claim_no_product_editor_app_wiring_no_ios_no_native_cpp_changes

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidRealtimePlaybackFocusResponsePhysicalSmokeApp());
}

class AndroidRealtimePlaybackFocusResponsePhysicalSmokeApp
    extends StatefulWidget {
  const AndroidRealtimePlaybackFocusResponsePhysicalSmokeApp({super.key});

  @override
  State<AndroidRealtimePlaybackFocusResponsePhysicalSmokeApp> createState() =>
      _AndroidRealtimePlaybackFocusResponsePhysicalSmokeAppState();
}

class _AndroidRealtimePlaybackFocusResponsePhysicalSmokeAppState
    extends State<AndroidRealtimePlaybackFocusResponsePhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Realtime Playback Focus Response smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(VGRealtimePlaybackFocusResponseSmokeReport.startMarkerConstant);

    VGRealtimePlaybackFocusResponseSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGRealtimePlaybackFocusResponseSmokeReport.runRealtimePlaybackFocusResponseSmoke(
            timeout: const Duration(seconds: 30),
          );
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_ERROR: $topLevelError',
      );
    }

    final activeReport =
        report ?? VGRealtimePlaybackFocusResponseSmokeReport.fromMap(null);

    // 1. Focus & Receiver Lifecycle
    print(
      '  [LANE] Focus & Receiver Lifecycle: '
      'focusGrantedOk=${activeReport.focusGrantedOk}, '
      'noisyReceiverRegisteredOk=${activeReport.noisyReceiverRegisteredOk}, '
      'focusAbandonedOk=${activeReport.focusAbandonedOk}, '
      'receiverUnregisteredOk=${activeReport.receiverUnregisteredOk}, '
      'eventsDroppedZeroOk=${activeReport.eventsDroppedZeroOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}',
    );

    // 2. Realtime Gain & Ducking
    print(
      '  [LANE] Realtime Gain & Ducking: '
      'baseGainSetOk=${activeReport.baseGainSetOk}, '
      'duckAppliedOk=${activeReport.duckAppliedOk}, '
      'duckRestoreOk=${activeReport.duckRestoreOk}, '
      'baseGain=${activeReport.metrics['baseGain']}, '
      'duckGain=${activeReport.metrics['duckGain']}',
    );

    // 3. Transient Pause & Terminal Responses
    print(
      '  [LANE] Transient Pause & Terminal Responses: '
      'transientPauseResumeOk=${activeReport.transientPauseResumeOk}, '
      'becomingNoisyPauseOk=${activeReport.becomingNoisyPauseOk}, '
      'permanentStopNoAutoResumeOk=${activeReport.permanentStopNoAutoResumeOk}, '
      'noisyHoldDispatchDelta=${activeReport.metrics['noisyHoldDispatchDelta']}, '
      'noisyHoldPushedDelta=${activeReport.metrics['noisyHoldPushedDelta']}',
    );

    // 4. Transport & AudioTrack Sink
    print(
      '  [LANE] Transport & AudioTrack Sink: '
      'transportStoppedOk=${activeReport.transportStoppedOk}, '
      'transportCompletedOk=${activeReport.transportCompletedOk}, '
      'checksumIdentityOk=${activeReport.checksumIdentityOk}, '
      'sinkWriteAccountingOk=${activeReport.sinkWriteAccountingOk}, '
      'audioTrackReleasedOk=${activeReport.audioTrackReleasedOk}, '
      'eosTransportState=${activeReport.metrics['eosTransportState']}, '
      'noisyTransportState=${activeReport.metrics['noisyTransportState']}, '
      'permanentTransportState=${activeReport.metrics['permanentTransportState']}',
    );

    // 5. Scenarios & Aggregates
    print(
      '  [LANE] Scenarios & Aggregates: '
      'eosScenarioPass=${activeReport.eosScenarioPass}, '
      'noisyTerminalScenarioPass=${activeReport.noisyTerminalScenarioPass}, '
      'permanentTerminalScenarioPass=${activeReport.permanentTerminalScenarioPass}, '
      'allNativeLanesPass=${activeReport.allNativeLanesPass}, '
      'canonical=${activeReport.canonical}',
    );

    // 6. Proof Boundary & Verification
    print(
      '  [LANE] Proof Boundary & Verification: '
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
          ? VGRealtimePlaybackFocusResponseSmokeReport.passMarkerConstant
          : VGRealtimePlaybackFocusResponseSmokeReport.failMarkerConstant,
    );

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidRealtimePlaybackFocusResponsePhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-FOCUS-RESPONSE',
      'target':
          VGRealtimePlaybackFocusResponseSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      '${VGRealtimePlaybackFocusResponseSmokeReport.jsonMarkerConstant}:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_FOCUS_RESPONSE_PHYSICAL_SMOKE_FAIL',
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
