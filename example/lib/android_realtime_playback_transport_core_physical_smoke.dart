// android_realtime_playback_transport_core_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-TRANSPORT-CORE (Y1): Android True-DAG Phase 4
// realtime playback transport core diagnostic physical harness.
//
// Proof lanes:
//   - Track Admission group: trackAdmissionOk, trackAdmission1Ok, trackAdmission2Ok, trackAdmission8Ok, trackAdmission9RejectedOk.
//   - Partial EOS Tail group: partialEosTailOk, partialEosTailRenderedFrames, partialEosTailPushedFrames, partialEosTailDrainedFrames, partialEosTailPushedChecksumHex, partialEosTailDrainedChecksumHex.
//   - Reentrant Sequence group: reentrantSequenceOk, reentrantHoldDispatchUnchangedOk, reentrantHoldPushedUnchangedOk, reentrantForwardSeekNonQuiescentOk, reentrantSeekForwardOk, reentrantSeekBackwardOk, reentrantRestartAndEosOk.
//   - Paused Seek group: pausedSeekStaysPausedOk, pausedSeekStayedPaused.
//   - Direct Probes & Native Lifecycle group: wrongOwnerDirectProbeOk, wrongOwnerStatus, wrongOwnerFlag, registryCapacityOk, registryCapacityCount, registryFifthFailedOk, destroyIdempotenceOk, firstDestroyStatus, firstDestroyWorkerJoined, firstDestroyWorkerExited, nativeSecondDestroyStatus, wrapperSecondDestroyStatus.
//   - Proof Boundary & Summary group: hasCanonicalProofBoundary, hasPassMarker, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   synthetic_pcm_only, no_audiotrack, no_mediacodec, no_mediaextractor, no_audiomanager, no_audible_output, no_product_editor_app_wiring, no_ios

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidRealtimePlaybackTransportCorePhysicalSmokeApp());
}

class AndroidRealtimePlaybackTransportCorePhysicalSmokeApp
    extends StatefulWidget {
  const AndroidRealtimePlaybackTransportCorePhysicalSmokeApp({super.key});

  @override
  State<AndroidRealtimePlaybackTransportCorePhysicalSmokeApp> createState() =>
      _AndroidRealtimePlaybackTransportCorePhysicalSmokeAppState();
}

class _AndroidRealtimePlaybackTransportCorePhysicalSmokeAppState
    extends State<AndroidRealtimePlaybackTransportCorePhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Realtime Playback Transport Core smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print(VGRealtimePlaybackTransportCoreSmokeReport.startMarkerConstant);

    VGRealtimePlaybackTransportCoreSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGRealtimePlaybackTransportCoreSmokeReport.runRealtimePlaybackTransportCoreSmoke(
            timeout: const Duration(seconds: 20),
          );
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_ERROR: $topLevelError',
      );
    }

    final activeReport =
        report ??
        const VGRealtimePlaybackTransportCoreSmokeReport(
          pass: false,
          status: 'fail',
          marker: VGRealtimePlaybackTransportCoreSmokeReport.failMarkerConstant,
          proofBoundary: '',
          nativeProofBoundary: '',
          failureReason: 'invocation_failed',
          details: '',
          trackAdmissionOk: false,
          partialEosTailOk: false,
          reentrantSequenceOk: false,
          pausedSeekStaysPausedOk: false,
          wrongOwnerDirectProbeOk: false,
          registryCapacityOk: false,
          destroyIdempotenceOk: false,
          proofBoundaryOk: false,
          canonical: false,
          trackAdmission1Ok: false,
          trackAdmission2Ok: false,
          trackAdmission8Ok: false,
          trackAdmission9RejectedOk: false,
          partialEosTailRenderedFrames: 0,
          partialEosTailPushedFrames: 0,
          partialEosTailDrainedFrames: 0,
          partialEosTailPushedChecksumHex: '',
          partialEosTailDrainedChecksumHex: '',
          reentrantHoldDispatchUnchangedOk: false,
          reentrantHoldPushedUnchangedOk: false,
          reentrantForwardSeekNonQuiescentOk: false,
          reentrantSeekForwardOk: false,
          reentrantSeekBackwardOk: false,
          reentrantRestartAndEosOk: false,
          pausedSeekStayedPaused: false,
          wrongOwnerStatus: '',
          wrongOwnerFlag: false,
          registryCapacityCount: 0,
          registryFifthFailedOk: false,
          firstDestroyStatus: '',
          firstDestroyWorkerJoined: false,
          firstDestroyWorkerExited: false,
          nativeSecondDestroyStatus: '',
          wrapperSecondDestroyStatus: '',
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

    // 1. Track Admission group
    print(
      '  [LANE] Track Admission: '
      'trackAdmissionOk=${activeReport.trackAdmissionOk}, '
      'trackAdmission1Ok=${activeReport.trackAdmission1Ok}, '
      'trackAdmission2Ok=${activeReport.trackAdmission2Ok}, '
      'trackAdmission8Ok=${activeReport.trackAdmission8Ok}, '
      'trackAdmission9RejectedOk=${activeReport.trackAdmission9RejectedOk}',
    );

    // 2. Partial EOS Tail group
    print(
      '  [LANE] Partial EOS Tail: '
      'partialEosTailOk=${activeReport.partialEosTailOk}, '
      'renderedFrames=${activeReport.partialEosTailRenderedFrames}, '
      'pushedFrames=${activeReport.partialEosTailPushedFrames}, '
      'drainedFrames=${activeReport.partialEosTailDrainedFrames}, '
      'pushedChecksumHex=${activeReport.partialEosTailPushedChecksumHex}, '
      'drainedChecksumHex=${activeReport.partialEosTailDrainedChecksumHex}',
    );

    // 3. Reentrant Sequence group
    print(
      '  [LANE] Reentrant Sequence: '
      'reentrantSequenceOk=${activeReport.reentrantSequenceOk}, '
      'reentrantHoldDispatchUnchangedOk=${activeReport.reentrantHoldDispatchUnchangedOk}, '
      'reentrantHoldPushedUnchangedOk=${activeReport.reentrantHoldPushedUnchangedOk}, '
      'reentrantForwardSeekNonQuiescentOk=${activeReport.reentrantForwardSeekNonQuiescentOk}, '
      'reentrantSeekForwardOk=${activeReport.reentrantSeekForwardOk}, '
      'reentrantSeekBackwardOk=${activeReport.reentrantSeekBackwardOk}, '
      'reentrantRestartAndEosOk=${activeReport.reentrantRestartAndEosOk}',
    );

    // 4. Paused Seek group
    print(
      '  [LANE] Paused Seek: '
      'pausedSeekStaysPausedOk=${activeReport.pausedSeekStaysPausedOk}, '
      'pausedSeekStayedPaused=${activeReport.pausedSeekStayedPaused}',
    );

    // 5. Direct Probes & Native Lifecycle group
    print(
      '  [LANE] Direct Probes & Native Lifecycle: '
      'wrongOwnerDirectProbeOk=${activeReport.wrongOwnerDirectProbeOk}, '
      'wrongOwnerStatus=${activeReport.wrongOwnerStatus}, '
      'wrongOwnerFlag=${activeReport.wrongOwnerFlag}, '
      'registryCapacityOk=${activeReport.registryCapacityOk}, '
      'registryCapacityCount=${activeReport.registryCapacityCount}, '
      'registryFifthFailedOk=${activeReport.registryFifthFailedOk}, '
      'destroyIdempotenceOk=${activeReport.destroyIdempotenceOk}, '
      'firstDestroyStatus=${activeReport.firstDestroyStatus}, '
      'firstDestroyWorkerJoined=${activeReport.firstDestroyWorkerJoined}, '
      'firstDestroyWorkerExited=${activeReport.firstDestroyWorkerExited}, '
      'nativeSecondDestroyStatus=${activeReport.nativeSecondDestroyStatus}, '
      'wrapperSecondDestroyStatus=${activeReport.wrapperSecondDestroyStatus}',
    );

    // 6. Proof Boundary & Summary group
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
          ? VGRealtimePlaybackTransportCoreSmokeReport.passMarkerConstant
          : VGRealtimePlaybackTransportCoreSmokeReport.failMarkerConstant,
    );

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidRealtimePlaybackTransportCorePhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-TRANSPORT-CORE',
      'target':
          VGRealtimePlaybackTransportCoreSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      '${VGRealtimePlaybackTransportCoreSmokeReport.jsonMarkerConstant}:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_PHYSICAL_SMOKE_FAIL',
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
