// android_realtime_playback_sink_fault_tolerance_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-SINK-FAULT-TOLERANCE (Y4b): Android True-DAG Phase 4
// realtime playback AudioTrack sink fault tolerance diagnostic physical harness.
//
// Proof lanes:
//   - Routing Listener Lifecycle: audioTrackInitOk, baseGainSetOk, routingListenerRegisteredOk, routingListenerUnregisteredOk, routeChangeObservationOk, eventsDroppedZeroOk, lifecycleOk.
//   - Synthetic Dead Object Recovery: deadObjectInjectedOnceOk, deadObjectOldTrackReleasedOk, deadObjectNewTrackStateInitializedOk, deadObjectNewTrackVolumeSetOk, deadObjectNewTrackPlayOk, deadObjectRemainderResumedOk, deadObjectNoDoubleCountOk.
//   - Route Disconnect Terminal: routeDisconnectFailClosedPauseOk, disconnectRouteDisconnectAppliedCount, disconnectHoldDispatchDelta, disconnectHoldPushedDelta, disconnectTransportStateAtTailEnd, disconnectTransportState.
//   - Transport & AudioTrack Accounting: transportCompletedOk, transportStoppedOk, checksumIdentityOk, sinkWriteAccountingOk, audioTrackReleasedOk.
//   - Scenarios: eosScenarioPass, routeDisconnectTerminalScenarioPass, allNativeLanesPass, canonical.
//
// Target / proof boundary:
//   realtime_playback_sink_fault_tolerance_diagnostic_only_nonzero_gain_audiotrack_sink_base_gain_0_5_synthetic_pcm_from_y1_transport_synthetic_dead_object_recovery_only_route_change_listener_handoff_and_fail_closed_pause_only_no_mediacodec_no_mediaextractor_no_presentation_clock_no_av_sync_no_os_route_arbitration_claim_no_real_os_dead_object_forcing_claim_no_seamless_hot_swap_claim_no_audible_output_claim_no_product_editor_app_wiring_no_ios_no_native_cpp_changes

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidRealtimePlaybackSinkFaultTolerancePhysicalSmokeApp());
}

class AndroidRealtimePlaybackSinkFaultTolerancePhysicalSmokeApp
    extends StatefulWidget {
  const AndroidRealtimePlaybackSinkFaultTolerancePhysicalSmokeApp({super.key});

  @override
  State<AndroidRealtimePlaybackSinkFaultTolerancePhysicalSmokeApp>
  createState() =>
      _AndroidRealtimePlaybackSinkFaultTolerancePhysicalSmokeAppState();
}

class _AndroidRealtimePlaybackSinkFaultTolerancePhysicalSmokeAppState
    extends State<AndroidRealtimePlaybackSinkFaultTolerancePhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Realtime Playback Sink Fault Tolerance smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(VGRealtimePlaybackSinkFaultToleranceSmokeReport.startMarkerConstant);

    VGRealtimePlaybackSinkFaultToleranceSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGRealtimePlaybackSinkFaultToleranceSmokeReport.runRealtimePlaybackSinkFaultToleranceSmoke(
            timeout: const Duration(seconds: 30),
          );
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_ERROR: $topLevelError',
      );
    }

    final activeReport =
        report ?? VGRealtimePlaybackSinkFaultToleranceSmokeReport.fromMap(null);

    // 1. Routing Listener Lifecycle
    print(
      '  [LANE] Routing Listener Lifecycle: '
      'audioTrackInitOk=${activeReport.audioTrackInitOk}, '
      'baseGainSetOk=${activeReport.baseGainSetOk}, '
      'routingListenerRegisteredOk=${activeReport.routingListenerRegisteredOk}, '
      'routingListenerUnregisteredOk=${activeReport.routingListenerUnregisteredOk}, '
      'routeChangeObservationOk=${activeReport.routeChangeObservationOk}, '
      'eventsDroppedZeroOk=${activeReport.eventsDroppedZeroOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}',
    );

    // 2. Synthetic Dead Object Recovery
    print(
      '  [LANE] Synthetic Dead Object Recovery: '
      'deadObjectInjectedOnceOk=${activeReport.deadObjectInjectedOnceOk}, '
      'deadObjectOldTrackReleasedOk=${activeReport.deadObjectOldTrackReleasedOk}, '
      'deadObjectNewTrackStateInitializedOk=${activeReport.deadObjectNewTrackStateInitializedOk}, '
      'deadObjectNewTrackVolumeSetOk=${activeReport.deadObjectNewTrackVolumeSetOk}, '
      'deadObjectNewTrackPlayOk=${activeReport.deadObjectNewTrackPlayOk}, '
      'deadObjectRemainderResumedOk=${activeReport.deadObjectRemainderResumedOk}, '
      'deadObjectNoDoubleCountOk=${activeReport.deadObjectNoDoubleCountOk}, '
      'eosSyntheticDeadObjectInjectedCount=${activeReport.metrics['eosSyntheticDeadObjectInjectedCount']}, '
      'eosDeadObjectObservedCount=${activeReport.metrics['eosDeadObjectObservedCount']}, '
      'eosPlayStateAfterRecreatePlay=${activeReport.metrics['eosPlayStateAfterRecreatePlay']}',
    );

    // 3. Route Disconnect Terminal
    print(
      '  [LANE] Route Disconnect Terminal: '
      'routeDisconnectFailClosedPauseOk=${activeReport.routeDisconnectFailClosedPauseOk}, '
      'disconnectRouteDisconnectAppliedCount=${activeReport.metrics['disconnectRouteDisconnectAppliedCount']}, '
      'disconnectHoldDispatchDelta=${activeReport.metrics['disconnectHoldDispatchDelta']}, '
      'disconnectHoldPushedDelta=${activeReport.metrics['disconnectHoldPushedDelta']}, '
      'disconnectTransportStateAtTailEnd=${activeReport.metrics['disconnectTransportStateAtTailEnd']}, '
      'disconnectTransportState=${activeReport.metrics['disconnectTransportState']}',
    );

    // 4. Transport & AudioTrack Accounting
    print(
      '  [LANE] Transport & AudioTrack Accounting: '
      'transportCompletedOk=${activeReport.transportCompletedOk}, '
      'transportStoppedOk=${activeReport.transportStoppedOk}, '
      'checksumIdentityOk=${activeReport.checksumIdentityOk}, '
      'sinkWriteAccountingOk=${activeReport.sinkWriteAccountingOk}, '
      'audioTrackReleasedOk=${activeReport.audioTrackReleasedOk}, '
      'eosTransportState=${activeReport.metrics['eosTransportState']}, '
      'eosFramesWrittenToSink=${activeReport.metrics['eosFramesWrittenToSink']}, '
      'disconnectFramesWrittenToSink=${activeReport.metrics['disconnectFramesWrittenToSink']}',
    );

    // 5. Scenarios & Aggregates
    print(
      '  [LANE] Scenarios & Aggregates: '
      'eosScenarioPass=${activeReport.eosScenarioPass}, '
      'routeDisconnectTerminalScenarioPass=${activeReport.routeDisconnectTerminalScenarioPass}, '
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
          ? VGRealtimePlaybackSinkFaultToleranceSmokeReport.passMarkerConstant
          : VGRealtimePlaybackSinkFaultToleranceSmokeReport.failMarkerConstant,
    );

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidRealtimePlaybackSinkFaultTolerancePhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-SINK-FAULT-TOLERANCE',
      'target':
          VGRealtimePlaybackSinkFaultToleranceSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      '${VGRealtimePlaybackSinkFaultToleranceSmokeReport.jsonMarkerConstant}:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_SINK_FAULT_TOLERANCE_PHYSICAL_SMOKE_FAIL',
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
