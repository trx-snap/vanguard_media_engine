// android_audio_scheduler_envelope_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-SCHEDULER-ENVELOPE-WIRING: Android True-DAG Phase 4
// GraphAudioScheduler per-source static-gain/envelope wiring diagnostic proof physical harness
// (sub-slice S under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS).
//
// Proof lanes:
//   - Wiring & Origin Math group: schedulerEnvelopeAppliedOk, windowPtsOriginOk, multiSourceParamsOk, nullEnvelopeBackCompatOk, mixOutputEnvelopeMetricsPropagatedOk.
//   - Rejection & Safety group: invalidSourceGainFailClosedOk, invalidEnvelopeGainFailClosedOk, windowPtsOverflowRejectOk, staleGenerationFailClosedOk.
//   - Architecture & Scope group: noPerWindowAllocationOk, lifecycleOk, stackScoped, canonical.
//   - Metrics & Checksums group: nativeStatus, routedSourceCount, windowFrames, windowPtsUs0, windowPtsUs1, framesRenderedWindow0, framesRenderedWindow1, envelopeEvaluationsWindow0, envelopeEvaluationsWindow1, sampleRate, channelCount, maxFramesPerMix, minEffectiveGainWindow0, maxEffectiveGainWindow0, schedulerChecksumWindow0Hex, schedulerChecksumWindow1Hex, referenceChecksumWindow0Hex, referenceChecksumWindow1Hex, unitGainChecksumWindow0Hex, wrongOriginChecksumWindow1Hex, window0MatchesReference, window1MatchesReference.
//   - Proof Boundary & Summary group: hasCanonicalProofBoundary, hasPassMarker, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   native_graph_audio_scheduler_envelope_wiring_diagnostic_only_scheduler_stamps_window_pts_origin_non_owning_per_source_static_gain_and_envelope_params_no_production_mixdown_change_no_export_reroute_no_pass2_reroute_no_runtime_queue_no_backpressure_no_realtime_sink_no_audio_track_no_aaudio_no_opensl_no_oboe_no_media_codec_no_media_extractor_no_file_io_no_native_worker_threads_no_app_no_editor_no_product_no_streaming_no_cache_no_ios

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAudioSchedulerEnvelopePhysicalSmokeApp());
}

class AndroidAudioSchedulerEnvelopePhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioSchedulerEnvelopePhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioSchedulerEnvelopePhysicalSmokeApp> createState() =>
      _AndroidAudioSchedulerEnvelopePhysicalSmokeAppState();
}

class _AndroidAudioSchedulerEnvelopePhysicalSmokeAppState
    extends State<AndroidAudioSchedulerEnvelopePhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Audio Scheduler Envelope smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_AUDIO_SCHEDULER_ENVELOPE_SMOKE_START');

    VGAudioSchedulerEnvelopeSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGAudioSchedulerEnvelopeSmokeReport.runAndroidDagPhase4AudioSchedulerEnvelopeSmoke(
            timeout: const Duration(seconds: 20),
          );
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_SCHEDULER_ENVELOPE_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_AUDIO_SCHEDULER_ENVELOPE_ERROR: $topLevelError',
      );
    }

    final activeReport =
        report ??
        const VGAudioSchedulerEnvelopeSmokeReport(
          pass: false,
          status: 'fail',
          marker: VGAudioSchedulerEnvelopeSmokeReport.failMarkerConstant,
          proofBoundary: '',
          failureReason: 'invocation_failed',
          details: '',
          schedulerEnvelopeAppliedOk: false,
          windowPtsOriginOk: false,
          multiSourceParamsOk: false,
          nullEnvelopeBackCompatOk: false,
          mixOutputEnvelopeMetricsPropagatedOk: false,
          invalidSourceGainFailClosedOk: false,
          invalidEnvelopeGainFailClosedOk: false,
          windowPtsOverflowRejectOk: false,
          staleGenerationFailClosedOk: false,
          noPerWindowAllocationOk: false,
          lifecycleOk: false,
          stackScoped: false,
          canonical: false,
          nativeStatus: 'FAIL',
          routedSourceCount: 0,
          windowFrames: 0,
          windowPtsUs0: 0,
          windowPtsUs1: 0,
          framesRenderedWindow0: 0,
          framesRenderedWindow1: 0,
          envelopeEvaluationsWindow0: 0,
          envelopeEvaluationsWindow1: 0,
          sampleRate: 0,
          channelCount: 0,
          maxFramesPerMix: 0,
          minEffectiveGainWindow0: 0.0,
          maxEffectiveGainWindow0: 0.0,
          schedulerChecksumWindow0Hex: '',
          schedulerChecksumWindow1Hex: '',
          referenceChecksumWindow0Hex: '',
          referenceChecksumWindow1Hex: '',
          unitGainChecksumWindow0Hex: '',
          wrongOriginChecksumWindow1Hex: '',
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

    // 1. Wiring & Origin Math group
    print(
      '  [LANE] Wiring & Origin Math: '
      'schedulerEnvelopeAppliedOk=${activeReport.schedulerEnvelopeAppliedOk}, '
      'windowPtsOriginOk=${activeReport.windowPtsOriginOk}, '
      'multiSourceParamsOk=${activeReport.multiSourceParamsOk}, '
      'nullEnvelopeBackCompatOk=${activeReport.nullEnvelopeBackCompatOk}, '
      'mixOutputEnvelopeMetricsPropagatedOk=${activeReport.mixOutputEnvelopeMetricsPropagatedOk}',
    );

    // 2. Rejection & Safety group
    print(
      '  [LANE] Rejection & Safety: '
      'invalidSourceGainFailClosedOk=${activeReport.invalidSourceGainFailClosedOk}, '
      'invalidEnvelopeGainFailClosedOk=${activeReport.invalidEnvelopeGainFailClosedOk}, '
      'windowPtsOverflowRejectOk=${activeReport.windowPtsOverflowRejectOk}, '
      'staleGenerationFailClosedOk=${activeReport.staleGenerationFailClosedOk}',
    );

    // 3. Architecture & Scope group
    print(
      '  [LANE] Architecture & Scope: '
      'noPerWindowAllocationOk=${activeReport.noPerWindowAllocationOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'stackScoped=${activeReport.stackScoped}, '
      'canonical=${activeReport.canonical}',
    );

    // 4. Metrics & Checksums group
    print(
      '  [LANE] Metrics & Checksums: '
      'nativeStatus=${activeReport.nativeStatus}, '
      'routedSourceCount=${activeReport.routedSourceCount}, '
      'windowFrames=${activeReport.windowFrames}, '
      'windowPtsUs0=${activeReport.windowPtsUs0}, '
      'windowPtsUs1=${activeReport.windowPtsUs1}, '
      'framesRenderedWindow0=${activeReport.framesRenderedWindow0}, '
      'framesRenderedWindow1=${activeReport.framesRenderedWindow1}, '
      'envelopeEvaluationsWindow0=${activeReport.envelopeEvaluationsWindow0}, '
      'envelopeEvaluationsWindow1=${activeReport.envelopeEvaluationsWindow1}, '
      'sampleRate=${activeReport.sampleRate}, '
      'channelCount=${activeReport.channelCount}, '
      'maxFramesPerMix=${activeReport.maxFramesPerMix}, '
      'minEffectiveGainWindow0=${activeReport.minEffectiveGainWindow0}, '
      'maxEffectiveGainWindow0=${activeReport.maxEffectiveGainWindow0}, '
      'schedulerChecksumWindow0Hex=${activeReport.schedulerChecksumWindow0Hex}, '
      'schedulerChecksumWindow1Hex=${activeReport.schedulerChecksumWindow1Hex}, '
      'referenceChecksumWindow0Hex=${activeReport.referenceChecksumWindow0Hex}, '
      'referenceChecksumWindow1Hex=${activeReport.referenceChecksumWindow1Hex}, '
      'unitGainChecksumWindow0Hex=${activeReport.unitGainChecksumWindow0Hex}, '
      'wrongOriginChecksumWindow1Hex=${activeReport.wrongOriginChecksumWindow1Hex}, '
      'window0MatchesReference=${activeReport.window0MatchesReference}, '
      'window1MatchesReference=${activeReport.window1MatchesReference}',
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
        activeReport.window0MatchesReference &&
        activeReport.window1MatchesReference &&
        lastErrorOk;

    print(
      pass
          ? VGAudioSchedulerEnvelopeSmokeReport.passMarkerConstant
          : VGAudioSchedulerEnvelopeSmokeReport.failMarkerConstant,
    );

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAudioSchedulerEnvelopePhysicalSmokeHarness',
      'slice': 'P4-AUDIO-SCHEDULER-ENVELOPE-WIRING',
      'target': VGAudioSchedulerEnvelopeSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_AUDIO_SCHEDULER_ENVELOPE_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AUDIO_SCHEDULER_ENVELOPE_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AUDIO_SCHEDULER_ENVELOPE_PHYSICAL_SMOKE_FAIL',
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
