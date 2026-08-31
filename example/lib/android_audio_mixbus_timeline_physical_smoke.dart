// android_audio_mixbus_timeline_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-MIXBUS-TIMELINE-OWNERSHIP: Android True-DAG Phase 4
// AudioMixBusNode timeline-aware per-frame volume envelope diagnostic proof physical harness
// (under P4-AUDIO-MIXBUS).
//
// Proof lanes:
//   - Envelope Parity & Math group: envelopeNormalizationParityOk, envelopeStaticFadePathParityOk, envelopeForTrackFallbackParityOk, envelopeEvaluationParityOk, emptyEnvelopeSilenceParityOk, subMillisecondHoldOk, boundaryInclusivityOk, mixGainNormalizationOk, normalizedKeyframeCount, staticFadeKeyframeCount, evaluationSampleCount, maxGainDiffScaled, envelopeEvaluations.
//   - Mix-Path & Gain Composition group: perFrameEnvelopeAppliedOk, staticGainCompositionOk, nullEnvelopeBackCompatOk, singleQuantizationOk, envelopeCursorMonotonicOk, envelopeCursorResetPerCallOk, floorPtsDerivationOk, framesMixed, sampleRate, channelCount, maxFramesPerMix, minEffectiveGain, maxEffectiveGain.
//   - Checksums & Parity Identity group: staticGainChecksumHex, envelopeMixChecksumHex, nullEnvelopeChecksumHex, baselineStaticChecksumHex, prescaleApproxChecksumHex, singleQuantChecksumHex, roundPtsChecksumHex, nullEnvelopeMatchesBaseline.
//   - Rejection & Safety group: unsupportedInterpolationRejectOk, keyframeCapRejectOk, invalidEnvelopeRangeRejectOk, invalidEnvelopeStartPtsRejectOk, invalidEnvelopeGainRejectOk, envelopeGainRejectVia.
//   - Architecture & Lifecycle group: noPerMixAllocationOk, schedulerUnchangedOk, productionMixdownUntouchedOk, lifecycleOk, stackScoped, canonical, timelineOwnershipHonesty.
//   - Proof Boundary & Summary group: hasCanonicalProofBoundary, hasPassMarker, allNativeLanesPass, lastError.
//
// Target / proof boundary:
//   native_audio_mix_bus_per_frame_volume_envelope_diagnostic_only_linear_interpolation_only_kotlin_android_audio_volume_envelope_parity_normalize_static_fade_and_evaluate_ported_to_cpp_node_owns_gain_math_caller_owns_window_origin_no_scheduler_wiring_no_production_mixdown_change_no_export_reroute_no_pass2_reroute_no_runtime_queue_no_backpressure_no_realtime_sink_no_threads_no_audio_track_no_aaudio_no_media_codec_no_file_io_no_streaming_no_cache_no_ios_no_product_no_editor_no_connects_app

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAudioMixBusTimelinePhysicalSmokeApp());
}

class AndroidAudioMixBusTimelinePhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioMixBusTimelinePhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioMixBusTimelinePhysicalSmokeApp> createState() =>
      _AndroidAudioMixBusTimelinePhysicalSmokeAppState();
}

class _AndroidAudioMixBusTimelinePhysicalSmokeAppState
    extends State<AndroidAudioMixBusTimelinePhysicalSmokeApp> {
  String _status = 'Running Android DAG Phase 4 Audio MixBus Timeline smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_AUDIO_MIXBUS_TIMELINE_SMOKE_START');

    VGAudioMixBusTimelineSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGAudioMixBusTimelineSmokeReport.runAndroidDagPhase4AudioMixBusTimelineSmoke(
            timeout: const Duration(seconds: 20),
          );
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print('ANDROID_DAG_PHASE4_AUDIO_MIXBUS_TIMELINE_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('ANDROID_DAG_PHASE4_AUDIO_MIXBUS_TIMELINE_ERROR: $topLevelError');
    }

    final activeReport =
        report ??
        const VGAudioMixBusTimelineSmokeReport(
          pass: false,
          status: 'fail',
          marker: VGAudioMixBusTimelineSmokeReport.failMarkerConstant,
          proofBoundary: '',
          failureReason: 'invocation_failed',
          details: '',
          envelopeNormalizationParityOk: false,
          envelopeStaticFadePathParityOk: false,
          envelopeForTrackFallbackParityOk: false,
          envelopeEvaluationParityOk: false,
          emptyEnvelopeSilenceParityOk: false,
          subMillisecondHoldOk: false,
          boundaryInclusivityOk: false,
          mixGainNormalizationOk: false,
          perFrameEnvelopeAppliedOk: false,
          staticGainCompositionOk: false,
          nullEnvelopeBackCompatOk: false,
          singleQuantizationOk: false,
          envelopeCursorMonotonicOk: false,
          envelopeCursorResetPerCallOk: false,
          floorPtsDerivationOk: false,
          unsupportedInterpolationRejectOk: false,
          keyframeCapRejectOk: false,
          invalidEnvelopeRangeRejectOk: false,
          invalidEnvelopeStartPtsRejectOk: false,
          invalidEnvelopeGainRejectOk: false,
          noPerMixAllocationOk: false,
          schedulerUnchangedOk: false,
          productionMixdownUntouchedOk: false,
          lifecycleOk: false,
          stackScoped: false,
          canonical: false,
          normalizedKeyframeCount: 0,
          staticFadeKeyframeCount: 0,
          evaluationSampleCount: 0,
          maxGainDiffScaled: 0,
          envelopeEvaluations: 0,
          framesMixed: 0,
          sampleRate: 0,
          channelCount: 0,
          maxFramesPerMix: 0,
          minEffectiveGain: 0.0,
          maxEffectiveGain: 0.0,
          staticGainChecksumHex: '',
          envelopeMixChecksumHex: '',
          nullEnvelopeChecksumHex: '',
          baselineStaticChecksumHex: '',
          prescaleApproxChecksumHex: '',
          singleQuantChecksumHex: '',
          roundPtsChecksumHex: '',
          envelopeGainRejectVia: '',
          timelineOwnershipHonesty: '',
          lanes: <String, Object?>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          metrics: <String, Object?>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          raw: <String, String>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          lastError: 'invocation_failed',
        );

    // 1. Envelope Parity & Math group
    print(
      '  [LANE] Envelope Parity & Math: '
      'envelopeNormalizationParityOk=${activeReport.envelopeNormalizationParityOk}, '
      'envelopeStaticFadePathParityOk=${activeReport.envelopeStaticFadePathParityOk}, '
      'envelopeForTrackFallbackParityOk=${activeReport.envelopeForTrackFallbackParityOk}, '
      'envelopeEvaluationParityOk=${activeReport.envelopeEvaluationParityOk}, '
      'emptyEnvelopeSilenceParityOk=${activeReport.emptyEnvelopeSilenceParityOk}, '
      'subMillisecondHoldOk=${activeReport.subMillisecondHoldOk}, '
      'boundaryInclusivityOk=${activeReport.boundaryInclusivityOk}, '
      'mixGainNormalizationOk=${activeReport.mixGainNormalizationOk}, '
      'normalizedKeyframeCount=${activeReport.normalizedKeyframeCount}, '
      'staticFadeKeyframeCount=${activeReport.staticFadeKeyframeCount}, '
      'evaluationSampleCount=${activeReport.evaluationSampleCount}, '
      'maxGainDiffScaled=${activeReport.maxGainDiffScaled}, '
      'envelopeEvaluations=${activeReport.envelopeEvaluations}',
    );

    // 2. Mix-Path & Gain Composition group
    print(
      '  [LANE] Mix-Path & Gain Composition: '
      'perFrameEnvelopeAppliedOk=${activeReport.perFrameEnvelopeAppliedOk}, '
      'staticGainCompositionOk=${activeReport.staticGainCompositionOk}, '
      'nullEnvelopeBackCompatOk=${activeReport.nullEnvelopeBackCompatOk}, '
      'singleQuantizationOk=${activeReport.singleQuantizationOk}, '
      'envelopeCursorMonotonicOk=${activeReport.envelopeCursorMonotonicOk}, '
      'envelopeCursorResetPerCallOk=${activeReport.envelopeCursorResetPerCallOk}, '
      'floorPtsDerivationOk=${activeReport.floorPtsDerivationOk}, '
      'framesMixed=${activeReport.framesMixed}, '
      'sampleRate=${activeReport.sampleRate}, '
      'channelCount=${activeReport.channelCount}, '
      'maxFramesPerMix=${activeReport.maxFramesPerMix}, '
      'minEffectiveGain=${activeReport.minEffectiveGain}, '
      'maxEffectiveGain=${activeReport.maxEffectiveGain}',
    );

    // 3. Checksums & Parity Identity group
    print(
      '  [LANE] Checksums & Parity Identity: '
      'staticGainChecksumHex=${activeReport.staticGainChecksumHex}, '
      'envelopeMixChecksumHex=${activeReport.envelopeMixChecksumHex}, '
      'nullEnvelopeChecksumHex=${activeReport.nullEnvelopeChecksumHex}, '
      'baselineStaticChecksumHex=${activeReport.baselineStaticChecksumHex}, '
      'prescaleApproxChecksumHex=${activeReport.prescaleApproxChecksumHex}, '
      'singleQuantChecksumHex=${activeReport.singleQuantChecksumHex}, '
      'roundPtsChecksumHex=${activeReport.roundPtsChecksumHex}, '
      'nullEnvelopeMatchesBaseline=${activeReport.nullEnvelopeMatchesBaseline}',
    );

    // 4. Rejection & Safety group
    print(
      '  [LANE] Rejection & Safety: '
      'unsupportedInterpolationRejectOk=${activeReport.unsupportedInterpolationRejectOk}, '
      'keyframeCapRejectOk=${activeReport.keyframeCapRejectOk}, '
      'invalidEnvelopeRangeRejectOk=${activeReport.invalidEnvelopeRangeRejectOk}, '
      'invalidEnvelopeStartPtsRejectOk=${activeReport.invalidEnvelopeStartPtsRejectOk}, '
      'invalidEnvelopeGainRejectOk=${activeReport.invalidEnvelopeGainRejectOk}, '
      'envelopeGainRejectVia=${activeReport.envelopeGainRejectVia}',
    );

    // 5. Architecture & Lifecycle group
    print(
      '  [LANE] Architecture & Lifecycle: '
      'noPerMixAllocationOk=${activeReport.noPerMixAllocationOk}, '
      'schedulerUnchangedOk=${activeReport.schedulerUnchangedOk}, '
      'productionMixdownUntouchedOk=${activeReport.productionMixdownUntouchedOk}, '
      'lifecycleOk=${activeReport.lifecycleOk}, '
      'stackScoped=${activeReport.stackScoped}, '
      'canonical=${activeReport.canonical}, '
      'timelineOwnershipHonesty=${activeReport.timelineOwnershipHonesty}',
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
        activeReport.nullEnvelopeMatchesBaseline &&
        activeReport.analyticBoundsPass &&
        activeReport.gainBoundsPass &&
        activeReport.audioFormatPass &&
        lastErrorOk;

    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AUDIO_MIXBUS_TIMELINE_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AUDIO_MIXBUS_TIMELINE_SMOKE_FAIL',
    );

    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidAudioMixBusTimelinePhysicalSmokeHarness',
      'slice': 'P4-AUDIO-MIXBUS-TIMELINE-OWNERSHIP',
      'target': VGAudioMixBusTimelineSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print(
      'ANDROID_DAG_PHASE4_AUDIO_MIXBUS_TIMELINE_JSON:${jsonEncode(summaryPayload)}',
    );
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AUDIO_MIXBUS_TIMELINE_PHYSICAL_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AUDIO_MIXBUS_TIMELINE_PHYSICAL_SMOKE_FAIL',
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
