// android_audio_mix_bus_physical_smoke.dart
// vanguard_media_engine — P4-AUDIO-MIXBUS: Android True-DAG Phase 4
// AudioMixBusNode PCM16 mix-math diagnostic smoke physical harness.
//
// Proof lanes:
//   - Mixed-Math group: stereoStereoDeterministic, monoToStereoUpmix,
//     stereoToMonoDownmix, positiveSaturation, negativeSaturation,
//     oddSampleTruncation, negativeDownmixDivision, shorterTrackSilence,
//     longerTrackShortWindowMix, fourTrackDeterministicMix, noPrematureClip,
//     finalSaturation, eightTrackCapacity.
//   - Error Rejection group: invalidGainRejection, nonFiniteGainRejection,
//     sampleRateMismatchRejection, invalidTrackChannelCountRejection,
//     insufficientOutputCapacityRejection, invalidSessionRejection,
//     nineTrackReject.
//   - Topology & Lifecycle group: topologyPorts, destroyIdempotent.
//   - Proof-Boundary & Summary group: hasCanonicalProofBoundary,
//     allNativeLanesPass, laneCount, lanePassCount, lastError.
//
// Target / proof boundary:
//   native_audio_mix_bus_node_pcm16_mix_math_only_no_decoder_no_aac_no_export_no_realtime_no_playback_no_product
//   Pure in-memory native C++ PCM16 mix-math and session lifecycle validation only.
//   No decoder, no AAC, no export/mixdown, no realtime playback, and no product/editor UI.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidAudioMixBusPhysicalSmokeApp());
}

class AndroidAudioMixBusPhysicalSmokeApp extends StatefulWidget {
  const AndroidAudioMixBusPhysicalSmokeApp({super.key});

  @override
  State<AndroidAudioMixBusPhysicalSmokeApp> createState() =>
      _AndroidAudioMixBusPhysicalSmokeAppState();
}

class _AndroidAudioMixBusPhysicalSmokeAppState
    extends State<AndroidAudioMixBusPhysicalSmokeApp> {
  String _status = 'Running Android DAG Phase 4 AudioMixBus smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    print('ANDROID_DAG_PHASE4_AUDIO_MIXBUS_SMOKE_START');

    VGAudioMixBusSmokeReport? report;
    String? topLevelError;

    try {
      report =
          await VGAudioMixBusSmokeReport.runAndroidDagPhase4AudioMixBusSmoke(
            timeout: const Duration(seconds: 15),
          ).timeout(const Duration(seconds: 25));
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print('ANDROID_DAG_PHASE4_AUDIO_MIXBUS_ERROR: $topLevelError');
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print('ANDROID_DAG_PHASE4_AUDIO_MIXBUS_ERROR: $topLevelError');
    }

    final activeReport =
        report ??
        const VGAudioMixBusSmokeReport(
          pass: false,
          proofBoundary: '',
          raw: <String, String>{
            'status': 'FAIL',
            'reason': 'invocation_failed',
          },
          metrics: <String, Object?>{'status': 'FAIL', 'lanePassCount': 0},
          lastError: 'invocation_failed',
        );

    // 1. Math group
    print(
      '  [LANE] Mixed-Math: '
      'stereoStereoDeterministic=${activeReport.stereoStereoDeterministic}, '
      'monoToStereoUpmix=${activeReport.monoToStereoUpmix}, '
      'stereoToMonoDownmix=${activeReport.stereoToMonoDownmix}, '
      'positiveSaturation=${activeReport.positiveSaturation}, '
      'negativeSaturation=${activeReport.negativeSaturation}, '
      'oddSampleTruncation=${activeReport.oddSampleTruncation}, '
      'negativeDownmixDivision=${activeReport.negativeDownmixDivision}, '
      'shorterTrackSilence=${activeReport.shorterTrackSilence}, '
      'longerTrackShortWindowMix=${activeReport.longerTrackShortWindowMix}, '
      'fourTrackDeterministicMix=${activeReport.fourTrackDeterministicMix}, '
      'noPrematureClip=${activeReport.noPrematureClip}, '
      'finalSaturation=${activeReport.finalSaturation}, '
      'eightTrackCapacity=${activeReport.eightTrackCapacity}',
    );

    // 2. Rejection group
    print(
      '  [LANE] Error Rejection: '
      'invalidGain=${activeReport.invalidGainRejection}, '
      'nonFiniteGain=${activeReport.nonFiniteGainRejection}, '
      'sampleRateMismatch=${activeReport.sampleRateMismatchRejection}, '
      'invalidTrackChannelCount=${activeReport.invalidTrackChannelCountRejection}, '
      'insufficientOutputCapacity=${activeReport.insufficientOutputCapacityRejection}, '
      'invalidSession=${activeReport.invalidSessionRejection}, '
      'nineTrackReject=${activeReport.nineTrackReject}',
    );

    // 3. Topology & Lifecycle group
    print(
      '  [LANE] Topology & Lifecycle: '
      'topologyPorts=${activeReport.topologyPorts}, '
      'destroyIdempotent=${activeReport.destroyIdempotent}',
    );

    // 4. Proof Boundary & Summary group
    print(
      '  [LANE] Proof Boundary & Summary: '
      'canonical=${activeReport.hasCanonicalProofBoundary}, '
      'allNativeLanesPass=${activeReport.allNativeLanesPass}, '
      'laneCount=${activeReport.laneCount}, '
      'lanePassCount=${activeReport.lanePassCount}, '
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
      'unit': 'AndroidAudioMixBusSmokeHarness',
      'slice': 'P4-AUDIO-MIXBUS',
      'target': VGAudioMixBusSmokeReport.proofBoundaryConstant,
      'pass': pass,
      'report': activeReport.toMap(),
      'error': topLevelError,
    };

    print('ANDROID_DAG_PHASE4_AUDIO_MIXBUS_JSON:${jsonEncode(summaryPayload)}');
    print(
      pass
          ? 'ANDROID_DAG_PHASE4_AUDIO_MIXBUS_SMOKE_PASS'
          : 'ANDROID_DAG_PHASE4_AUDIO_MIXBUS_SMOKE_FAIL',
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
