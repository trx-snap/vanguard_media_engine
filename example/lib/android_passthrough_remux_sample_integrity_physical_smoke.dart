// android_passthrough_remux_sample_integrity_physical_smoke.dart
// Vanguard Media Engine - Phase 2-Unit Y
// Android Native Passthrough Remux Redesigned Sample-Integrity PTS Equivalence Proof Physical Smoke.
//
// Validates strict sample count, SHA-256 payload digest, sample size sequence,
// keyframe sequence, and trackType-aware PTS ordering parity / conditional monotonicity across
// video and audio tracks, with bounded timestamp normalization tolerance derived
// from source inter-sample deltas.
// Exact absolute tail-PTS equivalence, absolute PTS monotonicity, DTS,
// composition reordering semantics, and audio adjacent-delta sign parity are intentionally non-claims.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidPassthroughRemuxSampleIntegrityPhysicalSmokeApp());
}

class AndroidPassthroughRemuxSampleIntegrityPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidPassthroughRemuxSampleIntegrityPhysicalSmokeApp({super.key});

  @override
  State<AndroidPassthroughRemuxSampleIntegrityPhysicalSmokeApp> createState() =>
      _AndroidPassthroughRemuxSampleIntegrityPhysicalSmokeAppState();
}

class _AndroidPassthroughRemuxSampleIntegrityPhysicalSmokeAppState
    extends State<AndroidPassthroughRemuxSampleIntegrityPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  static const String _expectedProofBoundary =
      'native_passthrough_remux_sample_integrity_redesigned_mediaextractor_mediamuxer_no_codec_no_exporttimeline';

  String _status =
      'Initializing Android Passthrough Remux Sample Integrity Physical Smoke (Unit Y)...';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(const Duration(seconds: 60), () {
      print(
        'ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y: TIMEOUT (60s exceeded)',
      );
      print('ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y_PHYSICAL_FAIL');
      exit(1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _runSmoke() async {
    print('ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y: START');
    final runId = 'unit_y_${DateTime.now().millisecondsSinceEpoch}';
    final tempDir = Directory.systemTemp;

    File? primaryFixtureFile;
    File? secondFixtureFile;

    var overallPass = false;
    Map<String, dynamic> resultMap = <String, dynamic>{};

    try {
      // ── Copy Asset Fixtures to System Temp ──────────────────────────────────
      print(
        'ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y: Copying clip_B.mov (primary) and clip_A.mov (second) to temp...',
      );

      final clipBBytes = await rootBundle.load(
        'assets/manual_test_clips/clip_B.mov',
      );
      primaryFixtureFile = File('${tempDir.path}/${runId}_clip_b_primary.mov');
      await primaryFixtureFile.writeAsBytes(
        clipBBytes.buffer.asUint8List(
          clipBBytes.offsetInBytes,
          clipBBytes.lengthInBytes,
        ),
        flush: true,
      );

      final clipABytes = await rootBundle.load(
        'assets/manual_test_clips/clip_A.mov',
      );
      secondFixtureFile = File('${tempDir.path}/${runId}_clip_a_second.mov');
      await secondFixtureFile.writeAsBytes(
        clipABytes.buffer.asUint8List(
          clipABytes.offsetInBytes,
          clipABytes.lengthInBytes,
        ),
        flush: true,
      );

      print(
        'ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y: Fixtures ready: primary=${primaryFixtureFile.path} (${await primaryFixtureFile.length()} bytes), second=${secondFixtureFile.path} (${await secondFixtureFile.length()} bytes)',
      );

      // ── Invoke Native Unit Y MethodChannel Route ───────────────────────────
      final response = await _channel.invokeMethod<Object?>(
        'runAndroidPassthroughRemuxSampleIntegritySmoke',
        <String, Object>{
          'sourcePath': primaryFixtureFile.path,
          'secondSourcePath': secondFixtureFile.path,
          'outputDir': tempDir.path,
        },
      );

      if (response is Map) {
        resultMap = _deepStringKeyed(response);
      } else {
        resultMap = <String, dynamic>{
          'pass': false,
          'error': 'Unexpected response type: ${response.runtimeType}',
        };
      }

      final nativeTopLevelPass = resultMap['pass'] == true;
      final proofBoundary = resultMap['proofBoundary'] as String? ?? '';
      final proofBoundaryValid = proofBoundary == _expectedProofBoundary;
      final rawResult = resultMap['raw'] as String? ?? '';

      // ── Validate Lane 1: A/V fixture (both video and audio tracks) ─────────
      final lane1 =
          resultMap['lane1'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final lane1Pass = lane1['pass'] == true;
      final lane1RemuxSuccess = lane1['remuxSuccess'] == true;
      final lane1VideoSamples = (lane1['videoSamples'] as num?)?.toInt() ?? 0;
      final lane1AudioSamples = (lane1['audioSamples'] as num?)?.toInt() ?? 0;

      final lane1Video =
          lane1['video'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final lane1VideoPass = _validateTrackResult(
        trackMap: lane1Video,
        expectedTrackType: 'video',
      );

      final lane1Audio =
          lane1['audio'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final lane1AudioPass = _validateTrackResult(
        trackMap: lane1Audio,
        expectedTrackType: 'audio',
      );

      final lane1OverallValid =
          lane1Pass &&
          lane1RemuxSuccess &&
          lane1VideoSamples > 0 &&
          lane1AudioSamples > 0 &&
          lane1VideoPass &&
          lane1AudioPass;

      print(
        'ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y_LANE1: pass=$lane1Pass remuxSuccess=$lane1RemuxSuccess vSamples=$lane1VideoSamples aSamples=$lane1AudioSamples vPass=$lane1VideoPass aPass=$lane1AudioPass',
      );
      _printTrackStats('LANE1_VIDEO', lane1Video);
      _printTrackStats('LANE1_AUDIO', lane1Audio);

      // ── Validate Lane 2: Video-only / distinct second source ───────────────
      final lane2 =
          resultMap['lane2'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final lane2Pass = lane2['pass'] == true;
      final lane2RemuxSuccess = lane2['remuxSuccess'] == true;
      final lane2UsedSecondSource = lane2['usedSecondSourcePath'] == true;
      final lane2VideoSamples = (lane2['videoSamples'] as num?)?.toInt() ?? 0;

      final lane2Video =
          lane2['video'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final lane2VideoPass = _validateTrackResult(
        trackMap: lane2Video,
        expectedTrackType: 'video',
      );

      final lane2OverallValid =
          lane2Pass &&
          lane2RemuxSuccess &&
          lane2UsedSecondSource &&
          lane2VideoSamples > 0 &&
          lane2VideoPass;

      print(
        'ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y_LANE2: pass=$lane2Pass remuxSuccess=$lane2RemuxSuccess usedSecondSource=$lane2UsedSecondSource vSamples=$lane2VideoSamples vPass=$lane2VideoPass',
      );
      _printTrackStats('LANE2_VIDEO', lane2Video);

      // ── Validate Lane 3: Negative control ──────────────────────────────────
      final lane3 =
          resultMap['lane3'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final lane3Pass = lane3['pass'] == true;
      final lane3VideoPass = lane3['videoPass'] == true;
      final lane3AudioPass = lane3['audioPass'] == true;
      final lane3NegSource =
          lane3['negativeControlSource'] as String? ?? 'none';

      final lane3VideoComparison =
          lane3['videoComparison'] as Map<String, dynamic>? ??
          <String, dynamic>{};
      final lane3VideoSourceFound =
          lane3VideoComparison['sourceTrackFound'] == true;
      final lane3VideoComparisonPass = lane3VideoComparison['pass'] == true;

      final lane3AudioComparison =
          lane3['audioComparison'] as Map<String, dynamic>? ??
          <String, dynamic>{};
      final lane3AudioSourceFound =
          lane3AudioComparison['sourceTrackFound'] == true;
      final lane3AudioOutputFound =
          lane3AudioComparison['outputTrackFound'] == true;
      final lane3AudioComparisonPass = lane3AudioComparison['pass'] == true;
      final lane3AudioReason = lane3AudioComparison['reason'] as String? ?? '';

      const forbiddenAudioReasons = <String>{
        'output_track_missing',
        'source_track_missing',
        'source_and_output_track_missing',
      };

      final lane3VideoValid =
          lane3VideoPass && lane3VideoSourceFound && !lane3VideoComparisonPass;

      final lane3AudioValid =
          lane3AudioPass &&
          lane3AudioSourceFound &&
          lane3AudioOutputFound &&
          !lane3AudioComparisonPass &&
          !forbiddenAudioReasons.contains(lane3AudioReason);

      final lane3OverallValid = lane3Pass && lane3VideoValid && lane3AudioValid;

      print(
        'ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y_LANE3: pass=$lane3Pass videoPass=$lane3VideoPass audioPass=$lane3AudioPass source=$lane3NegSource videoSourceFound=$lane3VideoSourceFound videoComparisonPass=$lane3VideoComparisonPass audioSourceFound=$lane3AudioSourceFound audioOutputFound=$lane3AudioOutputFound audioComparisonPass=$lane3AudioComparisonPass audioReason=$lane3AudioReason (valid=$lane3OverallValid)',
      );

      // ── Validate Lane 4: Missing source guard ──────────────────────────────
      final lane4 =
          resultMap['lane4'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final lane4Pass = lane4['pass'] == true;
      final lane4OutputExists = lane4['outputExists'] == true;
      final lane4Reason = lane4['reason'] as String? ?? '';
      final lane4OverallValid =
          lane4Pass && !lane4OutputExists && lane4Reason.isNotEmpty;

      print(
        'ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y_LANE4: pass=$lane4Pass outExists=$lane4OutputExists reason=$lane4Reason (valid=$lane4OverallValid)',
      );

      // ── Validate Non-Claims ────────────────────────────────────────────────
      final nonClaims =
          resultMap['nonClaims'] as Map<String, dynamic>? ??
          <String, dynamic>{};
      final nonClaimsValid =
          nonClaims['mediaCodecAllocated'] == false &&
          nonClaims['productionExportTimelineBypass'] == false &&
          nonClaims['cppPassthroughRemuxSinkNode'] == false &&
          nonClaims['videoDecoded'] == false &&
          nonClaims['audioDecoded'] == false &&
          nonClaims['connectAppTouched'] == false &&
          nonClaims['exactAbsolutePtsEquivalence'] == false &&
          nonClaims['absolutePtsMonotonicityAsserted'] == false &&
          nonClaims['decodeTimestampDtsVerified'] == false &&
          nonClaims['compositionReorderingSemanticsVerified'] == false &&
          nonClaims['audioAdjacentDeltaSignParityAsserted'] == false;

      print(
        'ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y_NON_CLAIMS: valid=$nonClaimsValid mediaCodecAllocated=${nonClaims['mediaCodecAllocated']} productionExportTimelineBypass=${nonClaims['productionExportTimelineBypass']} cppPassthroughRemuxSinkNode=${nonClaims['cppPassthroughRemuxSinkNode']} videoDecoded=${nonClaims['videoDecoded']} audioDecoded=${nonClaims['audioDecoded']} connectAppTouched=${nonClaims['connectAppTouched']} exactAbsolutePtsEquivalence=${nonClaims['exactAbsolutePtsEquivalence']} absolutePtsMonotonicityAsserted=${nonClaims['absolutePtsMonotonicityAsserted']} decodeTimestampDtsVerified=${nonClaims['decodeTimestampDtsVerified']} compositionReorderingSemanticsVerified=${nonClaims['compositionReorderingSemanticsVerified']} audioAdjacentDeltaSignParityAsserted=${nonClaims['audioAdjacentDeltaSignParityAsserted']}',
      );

      // ── Overall Pass Evaluation ────────────────────────────────────────────
      overallPass =
          nativeTopLevelPass &&
          proofBoundaryValid &&
          lane1OverallValid &&
          lane2OverallValid &&
          lane3OverallValid &&
          lane4OverallValid &&
          nonClaimsValid;

      print(
        'ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y_SUMMARY: overallPass=$overallPass nativeTopLevelPass=$nativeTopLevelPass proofBoundaryValid=$proofBoundaryValid lane1Valid=$lane1OverallValid lane2Valid=$lane2OverallValid lane3Valid=$lane3OverallValid lane4Valid=$lane4OverallValid nonClaimsValid=$nonClaimsValid raw=$rawResult',
      );
    } catch (e, st) {
      print(
        'ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y: ERROR: $e\n$st',
      );
      resultMap = <String, dynamic>{'pass': false, 'error': '$e'};
      overallPass = false;
    } finally {
      // ── Clean up copied asset fixture files in temp ────────────────────────
      if (primaryFixtureFile != null) {
        try {
          if (await primaryFixtureFile.exists()) {
            await primaryFixtureFile.delete();
          }
        } catch (_) {}
      }
      if (secondFixtureFile != null) {
        try {
          if (await secondFixtureFile.exists()) {
            await secondFixtureFile.delete();
          }
        } catch (_) {}
      }
    }

    final payload = <String, dynamic>{
      'unit': 'Phase2UnitY',
      'target': 'android_physical',
      'pass': overallPass,
      'result': resultMap,
    };

    print(
      'ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y_JSON:${jsonEncode(payload)}',
    );
    print(
      overallPass
          ? 'ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y_PHYSICAL_PASS'
          : 'ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = overallPass ? 'PASS' : 'FAIL';
      });
    }

    _timeoutTimer?.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(overallPass ? 0 : 1);
  }

  static bool _validateTrackResult({
    required Map<String, dynamic> trackMap,
    required String expectedTrackType,
  }) {
    final trackType = trackMap['trackType'] as String? ?? '';
    final sourceTrackFound = trackMap['sourceTrackFound'] == true;
    final outputTrackFound = trackMap['outputTrackFound'] == true;
    final sourceSampleCount =
        (trackMap['sourceSampleCount'] as num?)?.toInt() ?? 0;
    final outputSampleCount =
        (trackMap['outputSampleCount'] as num?)?.toInt() ?? 0;
    final sampleCountEqual = trackMap['sampleCountEqual'] == true;
    final digestEqual = trackMap['digestEqual'] == true;
    final sampleSizeSequenceEqual = trackMap['sampleSizeSequenceEqual'] == true;
    final keyframeSequenceEqual = trackMap['keyframeSequenceEqual'] == true;
    final sourcePtsNonDecreasingObserved =
        trackMap['sourcePtsNonDecreasing'] is bool;
    final outputPtsNonDecreasingObserved =
        trackMap['outputPtsNonDecreasing'] is bool;
    final sourcePtsNonDecreasing = trackMap['sourcePtsNonDecreasing'] == true;
    final outputPtsNonDecreasing = trackMap['outputPtsNonDecreasing'] == true;
    final ptsOrderingParityEqual = trackMap['ptsOrderingParityEqual'] == true;
    final mismatchCountObserved =
        trackMap['ptsOrderingParityMismatchCount'] is int;
    final firstMismatchIndexObserved =
        trackMap['ptsOrderingParityFirstMismatchIndex'] is int;

    final conditionalMonotonicityValid =
        !sourcePtsNonDecreasing || outputPtsNonDecreasing;

    final bool trackOrderingGatePass;
    if (expectedTrackType == 'video') {
      trackOrderingGatePass =
          ptsOrderingParityEqual && conditionalMonotonicityValid;
    } else if (expectedTrackType == 'audio') {
      if (sourcePtsNonDecreasing) {
        trackOrderingGatePass = outputPtsNonDecreasing;
      } else {
        trackOrderingGatePass =
            ptsOrderingParityEqual && conditionalMonotonicityValid;
      }
    } else {
      trackOrderingGatePass = false;
    }

    final payloadGatesPass =
        sampleCountEqual &&
        digestEqual &&
        sampleSizeSequenceEqual &&
        keyframeSequenceEqual;

    final strictPass = trackMap['strictPass'] == true;
    final boundedPass = trackMap['boundedPass'] == true;
    final pass = trackMap['pass'] == true;

    return trackType == expectedTrackType &&
        sourceTrackFound &&
        outputTrackFound &&
        sourceSampleCount > 0 &&
        outputSampleCount > 0 &&
        payloadGatesPass &&
        sourcePtsNonDecreasingObserved &&
        outputPtsNonDecreasingObserved &&
        mismatchCountObserved &&
        firstMismatchIndexObserved &&
        trackOrderingGatePass &&
        strictPass &&
        boundedPass &&
        pass;
  }

  static void _printTrackStats(String label, Map<String, dynamic> trackMap) {
    final trackType = trackMap['trackType'] ?? 'unknown';
    final srcCount = trackMap['sourceSampleCount'] ?? 0;
    final outCount = trackMap['outputSampleCount'] ?? 0;
    final digestEqual = trackMap['digestEqual'] ?? false;
    final sizeSeqEqual = trackMap['sampleSizeSequenceEqual'] ?? false;
    final kfSeqEqual = trackMap['keyframeSequenceEqual'] ?? false;
    final srcNonDecreasing = trackMap['sourcePtsNonDecreasing'] ?? false;
    final outNonDecreasing = trackMap['outputPtsNonDecreasing'] ?? false;
    final ptsOrderingParityEqual = trackMap['ptsOrderingParityEqual'] ?? false;
    final mismatchCount = trackMap['ptsOrderingParityMismatchCount'] ?? -1;
    final firstMismatchIndex =
        trackMap['ptsOrderingParityFirstMismatchIndex'] ?? -1;
    final toleranceUs = trackMap['toleranceUs'] ?? 0;
    final firstPtsDeltaUs = trackMap['firstPtsDeltaUs'] ?? 0;
    final lastPtsDeltaUs = trackMap['lastPtsDeltaUs'] ?? 0;
    final maxAbsPtsDeltaUs = trackMap['maxAbsPtsDeltaUs'] ?? 0;
    final normalizationObserved =
        trackMap['muxerTimestampNormalizationObserved'] ?? false;
    final strictPass = trackMap['strictPass'] ?? false;
    final boundedPass = trackMap['boundedPass'] ?? false;
    final pass = trackMap['pass'] ?? false;
    final reason = trackMap['reason'] ?? '';

    print(
      'ANDROID_PASSTHROUGH_REMUX_SAMPLE_INTEGRITY_UNIT_Y_$label: '
      'type=$trackType srcCount=$srcCount outCount=$outCount '
      'digestEqual=$digestEqual sizeSeq=$sizeSeqEqual kfSeq=$kfSeqEqual '
      'srcNonDecreasing=$srcNonDecreasing outNonDecreasing=$outNonDecreasing '
      'ptsOrderingParityEqual=$ptsOrderingParityEqual '
      'mismatchCount=$mismatchCount firstMismatchIndex=$firstMismatchIndex '
      'firstDelta=${firstPtsDeltaUs}us lastDelta=${lastPtsDeltaUs}us maxAbsDelta=${maxAbsPtsDeltaUs}us '
      'tolerance=${toleranceUs}us normalizationObserved=$normalizationObserved '
      'strictPass=$strictPass boundedPass=$boundedPass pass=$pass reason=$reason',
    );
  }

  Map<String, dynamic> _deepStringKeyed(Map<Object?, Object?> map) {
    final out = <String, dynamic>{};
    map.forEach((key, value) {
      out['$key'] = value is Map<Object?, Object?>
          ? _deepStringKeyed(value)
          : value;
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_status, textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
