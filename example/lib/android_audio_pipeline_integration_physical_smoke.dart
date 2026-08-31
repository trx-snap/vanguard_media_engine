// android_audio_pipeline_integration_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice F: Android True-DAG Phase 4
// native closed-loop ingest-to-transport audio graph pipeline integration diagnostic proof physical harness.
//
// Proof lanes:
//   - Route, Start & Closed-Loop group: routeSelectivityOk, startAwaitAckGateOk, closedLoopIdentityOk.
//   - Seek, Silence & Source Boundary group: coordinatorSeekIdentityOk, firstPostSeekSilenceOk, sourceSeekAckBoundaryOk.
//   - Allocation, Shortfall, Lifecycle & Scope group: noSteadyStateAllocationOk, noRingPushShortfallOk, lifecycleOk, stackScoped.
//   - Metrics group: closedLoopFramesVerified, closedLoopChecksum, closedLoopExpectedChecksum, closedLoopClippedSamples, seekTargetFrame, sourceSeekTargetFrame, firstPostSeekUnderrunEvents, firstPostSeekFramesZeroFilled, steadyStateDispatches, steadyStateFramesPushed.
//   - Proof-Boundary & Summary group: hasCanonicalProofBoundary, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   native_closed_loop_audio_pipeline_integration_proof_only_no_mediacodec_no_mediaextractor_no_audio_track_no_aaudio_no_opensl_no_oboe_no_realtime_playback_no_audible_output_no_os_callback_no_threads_no_locks_no_file_io_no_wall_clock_read_no_resample_no_speed_change_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_no_source_node_pcm_ingest_topology_anchor_only_writer_local_eos_only_caller_supplied_systime_only_single_threaded
//   Closed-loop ingest-to-transport audio graph pipeline integration native proof.
//   Pure in-memory C++ proof only; no MediaCodec, no MediaExtractor,
//   no AudioTrack, no AAudio, no OpenSL, no Oboe, no realtime playback,
//   no audible output, no OS callbacks, no threads, no locks, no file IO,
//   no wall-clock read (caller-supplied sysTimeNs only), no resample,
//   no speed change, no export reroute, no pass-2 graph reroute,
//   no streaming, no cache, no iOS, no product/editor UI.
//   DecodedAudioPcmSourceNode remains topology anchor only (no PCM
//   ingest/retention). Writer-local EOS only. Single-threaded native call.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAudioPipelineIntegrationPhysicalSmokeApp());
}

class AndroidAudioPipelineIntegrationPhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioPipelineIntegrationPhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioPipelineIntegrationPhysicalSmokeApp> createState() =>
      _AndroidAudioPipelineIntegrationPhysicalSmokeAppState();
}

class _AndroidAudioPipelineIntegrationPhysicalSmokeAppState
    extends State<AndroidAudioPipelineIntegrationPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Audio Pipeline Integration smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_AUDIO_PIPELINE_INTEGRATION_SMOKE_START');

    VGAudioPipelineIntegrationSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGAudioPipelineIntegrationSmokeReport.runAndroidDagPhase4AudioPipelineIntegrationSmoke(
            timeout: const Duration(seconds: 15),
          ).timeout(const Duration(seconds: 25));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_PIPELINE_INTEGRATION_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_PIPELINE_INTEGRATION_ERROR: $topLevelError',
      );
    }

    final activeReport =
        report ??
        const VGAudioPipelineIntegrationSmokeReport(
          pass: false,
          proofBoundary: '',
          raw: <String, String>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          metrics: <String, Object?>{'status': 'FAIL'},
          lastError: 'invocation_failed',
        );

    // 1. Route, Start & Closed-Loop group
    print(
      '  [LANE] Route, Start & Closed-Loop: '
      'routeSelectivityOk=${activeReport.routeSelectivityOk}, '
      'startAwaitAckGateOk=${activeReport.startAwaitAckGateOk}, '
      'closedLoopIdentityOk=${activeReport.closedLoopIdentityOk}',
    );

    // 2. Seek, Silence & Source Boundary group
    print(
      '  [LANE] Seek, Silence & Source Boundary: '
      'coordinatorSeekIdentityOk=${activeReport.coordinatorSeekIdentityOk}, '
      'firstPostSeekSilenceOk=${activeReport.firstPostSeekSilenceOk}, '
      'sourceSeekAckBoundaryOk=${activeReport.sourceSeekAckBoundaryOk}',
    );

    // 3. Allocation, Shortfall, Lifecycle & Scope group
    print(
      '  [LANE] Allocation, Shortfall, Lifecycle & Scope: '
      'noSteadyStateAllocationOk=${activeReport.noSteadyStateAllocationOk}, '
      'noRingPushShortfallOk=${activeReport.noRingPushShortfallOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'stackScoped=${activeReport.stackScoped}',
    );

    // 4. Metrics group
    print(
      '  [LANE] Metrics: '
      'closedLoopFramesVerified=${activeReport.closedLoopFramesVerified}, '
      'closedLoopChecksum=${activeReport.closedLoopChecksum}, '
      'closedLoopExpectedChecksum=${activeReport.closedLoopExpectedChecksum}, '
      'closedLoopClippedSamples=${activeReport.closedLoopClippedSamples}, '
      'seekTargetFrame=${activeReport.seekTargetFrame}, '
      'sourceSeekTargetFrame=${activeReport.sourceSeekTargetFrame}, '
      'firstPostSeekUnderrunEvents=${activeReport.firstPostSeekUnderrunEvents}, '
      'firstPostSeekFramesZeroFilled=${activeReport.firstPostSeekFramesZeroFilled}, '
      'steadyStateDispatches=${activeReport.steadyStateDispatches}, '
      'steadyStateFramesPushed=${activeReport.steadyStateFramesPushed}',
    );

    // 5. Proof Boundary & Summary group
    print(
      '  [LANE] Proof Boundary & Summary: '
      'canonical=${activeReport.hasCanonicalProofBoundary}, '
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
        activeReport.hasCanonicalProofBoundary &&
        activeReport.allNativeLanesPass &&
        lastErrorOk;

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAudioPipelineIntegrationPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-GRAPH-TRANSPORT-CLOCK',
      'target': VGAudioPipelineIntegrationSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_AUDIO_PIPELINE_INTEGRATION_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AUDIO_PIPELINE_INTEGRATION_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AUDIO_PIPELINE_INTEGRATION_SMOKE_FAIL',
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
