// android_audio_graph_export_session_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-PASS2-GRAPH-NATIVE-SESSION: Android True-DAG Phase 4
// N-source node-owned ring audio graph export session diagnostic physical harness
// (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS).
//
// Proof lanes:
//   - Session Lifecycle & Admission group: sessionCreateOk, longTimelineAdmissionOk, addEightTracksOk, totalTrackLimitRejectOk, prepareBarrierOk, lifecycleDestroyIdempotentOk.
//   - Routing & Render Execution group: routedSourceCountOk, contiguousWindowOk, renderTwoWindowsOk, checksumNonZeroOk, underrunFailClosedOk.
//   - Architecture & Non-claims group: proofBoundaryOk, noProductionRouteSwapOk, canonical.
//   - Metrics & Diagnostics group: requestedTrackCount, routedSourceCount, windowCount, silentWindowCount, framesRendered, longTimelineFrames, totalTrackLimitReason, nonContiguousReason, underrunReason, checksumWindow0Hex, checksumWindow1Hex.
//   - Proof Boundary & Summary group: hasCanonicalProofBoundary, hasPassMarker, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   native_true_dag_pass2_graph_export_session_diagnostic_only_n_source_node_owned_ring_graph_scheduler_mixbus_unit_gain_no_production_route_swap_no_android_mixdown_engine_change_no_legacy_chunk_mixer_change_no_runtime_realtime_sink_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_mediacodec_no_mediaextractor_no_file_io_no_native_worker_threads_no_app_no_editor_no_product_no_streaming_no_cache_no_ios

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAudioGraphExportSessionPhysicalSmokeApp());
}

class AndroidAudioGraphExportSessionPhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioGraphExportSessionPhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioGraphExportSessionPhysicalSmokeApp> createState() =>
      _AndroidAudioGraphExportSessionPhysicalSmokeAppState();
}

class _AndroidAudioGraphExportSessionPhysicalSmokeAppState
    extends State<AndroidAudioGraphExportSessionPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Audio Graph Export Session smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_AUDIO_GRAPH_EXPORT_SESSION_SMOKE_START');

    VGAudioGraphExportSessionSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGAudioGraphExportSessionSmokeReport.runAndroidDagPhase4AudioGraphExportSessionSmoke(
            timeout: const Duration(seconds: 20),
          );
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_GRAPH_EXPORT_SESSION_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_GRAPH_EXPORT_SESSION_ERROR: $topLevelError',
      );
    }

    final activeReport =
        report ??
        const VGAudioGraphExportSessionSmokeReport(
          pass: false,
          status: 'fail',
          marker: VGAudioGraphExportSessionSmokeReport.failMarkerConstant,
          proofBoundary: '',
          failureReason: 'invocation_failed',
          details: '',
          sessionCreateOk: false,
          longTimelineAdmissionOk: false,
          addEightTracksOk: false,
          totalTrackLimitRejectOk: false,
          prepareBarrierOk: false,
          routedSourceCountOk: false,
          contiguousWindowOk: false,
          renderTwoWindowsOk: false,
          checksumNonZeroOk: false,
          underrunFailClosedOk: false,
          lifecycleDestroyIdempotentOk: false,
          proofBoundaryOk: false,
          noProductionRouteSwapOk: false,
          canonical: false,
          requestedTrackCount: 0,
          routedSourceCount: 0,
          windowCount: 0,
          silentWindowCount: 0,
          framesRendered: 0,
          longTimelineFrames: 0,
          totalTrackLimitReason: '',
          nonContiguousReason: '',
          underrunReason: '',
          checksumWindow0Hex: '',
          checksumWindow1Hex: '',
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

    // 1. Session Lifecycle & Admission group
    print(
      '  [LANE] Session Lifecycle & Admission: '
      'sessionCreateOk=${activeReport.sessionCreateOk}, '
      'longTimelineAdmissionOk=${activeReport.longTimelineAdmissionOk}, '
      'addEightTracksOk=${activeReport.addEightTracksOk}, '
      'totalTrackLimitRejectOk=${activeReport.totalTrackLimitRejectOk}, '
      'prepareBarrierOk=${activeReport.prepareBarrierOk}, '
      'lifecycleDestroyIdempotentOk=${activeReport.lifecycleDestroyIdempotentOk}',
    );

    // 2. Routing & Render Execution group
    print(
      '  [LANE] Routing & Render Execution: '
      'routedSourceCountOk=${activeReport.routedSourceCountOk}, '
      'contiguousWindowOk=${activeReport.contiguousWindowOk}, '
      'renderTwoWindowsOk=${activeReport.renderTwoWindowsOk}, '
      'checksumNonZeroOk=${activeReport.checksumNonZeroOk}, '
      'underrunFailClosedOk=${activeReport.underrunFailClosedOk}',
    );

    // 3. Architecture & Non-claims group
    print(
      '  [LANE] Architecture & Non-claims: '
      'proofBoundaryOk=${activeReport.proofBoundaryOk}, '
      'noProductionRouteSwapOk=${activeReport.noProductionRouteSwapOk}, '
      'canonical=${activeReport.canonical}',
    );

    // 4. Metrics & Diagnostics group
    print(
      '  [LANE] Metrics & Diagnostics: '
      'requestedTrackCount=${activeReport.requestedTrackCount}, '
      'routedSourceCount=${activeReport.routedSourceCount}, '
      'windowCount=${activeReport.windowCount}, '
      'silentWindowCount=${activeReport.silentWindowCount}, '
      'framesRendered=${activeReport.framesRendered}, '
      'longTimelineFrames=${activeReport.longTimelineFrames}, '
      'totalTrackLimitReason=${activeReport.totalTrackLimitReason}, '
      'nonContiguousReason=${activeReport.nonContiguousReason}, '
      'underrunReason=${activeReport.underrunReason}, '
      'checksumWindow0Hex=${activeReport.checksumWindow0Hex}, '
      'checksumWindow1Hex=${activeReport.checksumWindow1Hex}',
    );

    // 5. Proof Boundary & Summary group
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
          ? VGAudioGraphExportSessionSmokeReport.passMarkerConstant
          : VGAudioGraphExportSessionSmokeReport.failMarkerConstant,
    );

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAudioGraphExportSessionPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-PASS2-GRAPH-NATIVE-SESSION',
      'target': VGAudioGraphExportSessionSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_AUDIO_GRAPH_EXPORT_SESSION_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AUDIO_GRAPH_EXPORT_SESSION_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AUDIO_GRAPH_EXPORT_SESSION_PHYSICAL_SMOKE_FAIL',
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
