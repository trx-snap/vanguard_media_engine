// android_realtime_audio_playback_production_physical_smoke.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SINK-CLOCK (Y8a): Android True-DAG Phase 4
// realtime audio playback production sink and clock diagnostic physical smoke target.
//
// Component diagnostic smoke: drives production VanguardRealtimeAudioPlaybackSession
// (real MediaExtractor / MediaCodec -> Y5a external ingest -> Y1 transport ->
// sink-thread-owned non-zero-gain AudioTrack + presentation clock).
//
// Honest non-claims (Proof Boundary):
// production_engine_component_diagnostic_route_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_sink_thread_owned_audiotrack_and_presentation_clock_bounded_pause_resume_closes_reopens_clock_epoch_at_last_published_position_stop_dispose_release_once_no_seek_no_dead_object_recovery_no_product_no_editor_no_app_no_connectsapp_no_ios_no_streaming_no_cache_no_cpp_no_jni
//
// This is a component diagnostic smoke. It must not claim
// product/editor/UI/ConnectsApp/iOS/streaming/cache/CPP/JNI proof.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  if (!Platform.isAndroid) {
    print(
      'FAIL: android_realtime_audio_playback_production_physical_smoke is Android-only. Current OS: ${Platform.operatingSystem}',
    );
    print(VGRealtimeAudioPlaybackProductionSmokeReport.failMarkerConstant);
    exit(1);
  }

  runApp(const AndroidRealtimeAudioPlaybackProductionPhysicalSmokeApp());
}

class AndroidRealtimeAudioPlaybackProductionPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidRealtimeAudioPlaybackProductionPhysicalSmokeApp({super.key});

  @override
  State<AndroidRealtimeAudioPlaybackProductionPhysicalSmokeApp> createState() =>
      _AndroidRealtimeAudioPlaybackProductionPhysicalSmokeAppState();
}

class _AndroidRealtimeAudioPlaybackProductionPhysicalSmokeAppState
    extends State<AndroidRealtimeAudioPlaybackProductionPhysicalSmokeApp> {
  String _status =
      'Running Android DAG Phase 4 Realtime Audio Playback Production Sink & Clock smoke...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    // Print START marker before calling wrapper as required by contract.
    print(VGRealtimeAudioPlaybackProductionSmokeReport.startMarkerConstant);

    VGRealtimeAudioPlaybackProductionSmokeReport? report;
    String? topLevelError;
    File? tempSourceFile;
    String? selectedFixturePath;

    final candidates = <String>[
      'assets/manual_test_clips/clip_B.mov',
      'assets/manual_test_clips/clip_A.mov',
      'assets/manual_test_clips/clip_A.mp3',
    ];

    try {
      // 1. Choose first available fixture.
      for (final candidate in candidates) {
        ByteData? assetData;
        try {
          assetData = await rootBundle.load(candidate);
        } catch (_) {
          final directFile = File(candidate);
          if (directFile.existsSync()) {
            final bytes = await directFile.readAsBytes();
            assetData = ByteData.view(bytes.buffer);
          }
        }

        if (assetData == null) {
          print('  [CANDIDATE_SKIP] Fixture not found: $candidate');
          continue;
        }

        final ext = candidate.endsWith('.mp3') ? 'mp3' : 'mov';
        final tempDir = Directory.systemTemp;
        final timestamp = DateTime.now().microsecondsSinceEpoch;
        final targetFile = File(
          '${tempDir.path}/p4_y8a_realtime_audio_playback_production_source_$timestamp.$ext',
        );

        await targetFile.writeAsBytes(
          assetData.buffer.asUint8List(
            assetData.offsetInBytes,
            assetData.lengthInBytes,
          ),
          flush: true,
        );

        tempSourceFile = targetFile;
        selectedFixturePath = tempSourceFile.path;
        print(
          '  [FIXTURE] Selected fixture: $candidate extracted to $selectedFixturePath',
        );
        break;
      }

      if (tempSourceFile == null || selectedFixturePath == null) {
        throw StateError(
          'No available fixture found from candidates: ${candidates.join(', ')}',
        );
      }

      // Print selected fixture path as required by contract.
      print('Selected fixture path: $selectedFixturePath');

      // 2. Invoke wrapper over production component diagnostic route.
      report =
          await VGRealtimeAudioPlaybackProductionSmokeReport.runRealtimeAudioPlaybackProductionSmoke(
            sourcePath: selectedFixturePath,
            maxDurationSec: 3.0,
            maxFramesPerMix: 256,
            gain: 0.5,
            deadlineMs: 30000,
            pauseHoldMs: 400,
            stopAfterMs: 300,
            timeout: const Duration(seconds: 40),
          );
    } on TimeoutException catch (te) {
      topLevelError = 'timeout: $te';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_ERROR: $topLevelError',
      );
    } catch (e, st) {
      topLevelError = '$e\n$st';
      print(
        'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_ERROR: $topLevelError',
      );
    } finally {
      if (tempSourceFile != null) {
        try {
          if (await tempSourceFile.exists()) {
            await tempSourceFile.delete();
            print(
              '  [CLEANUP] Deleted temp source file: ${tempSourceFile.path}',
            );
          }
        } catch (cleanupErr) {
          print(
            '  [CLEANUP_WARN] Failed to delete temp source file: $cleanupErr',
          );
        }
      }
    }

    final activeReport =
        report ??
        VGRealtimeAudioPlaybackProductionSmokeReport.fromMap(<String, Object?>{
          'pass': false,
          'status': 'fail',
          'marker':
              VGRealtimeAudioPlaybackProductionSmokeReport.failMarkerConstant,
          'failureReason': topLevelError ?? 'invocation_failed',
        });

    // 3. Print every lane needed for human/Codex review.
    print('--- LANES ---');
    print('  [LANE] formatProbeOk: ${activeReport.formatProbeOk}');
    print('  [LANE] preRollOk: ${activeReport.preRollOk}');
    print('  [LANE] startOk: ${activeReport.startOk}');
    print(
      '  [LANE] nonZeroGainAudioTrackOk: ${activeReport.nonZeroGainAudioTrackOk}',
    );
    print(
      '  [LANE] playthroughAccountingOk: ${activeReport.playthroughAccountingOk}',
    );
    print('  [LANE] checksumIdentityOk: ${activeReport.checksumIdentityOk}');
    print('  [LANE] clockAnchoredOk: ${activeReport.clockAnchoredOk}');
    print('  [LANE] clockMonotonicOk: ${activeReport.clockMonotonicOk}');
    print(
      '  [LANE] clockEpochBalancedOk: ${activeReport.clockEpochBalancedOk}',
    );
    print('  [LANE] clockPauseFrozenOk: ${activeReport.clockPauseFrozenOk}');
    print(
      '  [LANE] boundedPauseResumeOk: ${activeReport.boundedPauseResumeOk}',
    );
    print('  [LANE] stopDisposeOk: ${activeReport.stopDisposeOk}');
    print(
      '  [LANE] decoderCancelledOnStopOk: ${activeReport.decoderCancelledOnStopOk}',
    );
    print('  [LANE] transportDisposedOk: ${activeReport.transportDisposedOk}');
    print(
      '  [LANE] audioTrackReleasedOnceOk: ${activeReport.audioTrackReleasedOnceOk}',
    );
    print('  [LANE] threadOwnershipOk: ${activeReport.threadOwnershipOk}');
    print('  [LANE] noFeedbackOk: ${activeReport.noFeedbackOk}');
    print('  [LANE] proofBoundaryOk: ${activeReport.proofBoundaryOk}');
    print('  [LANE] canonical: ${activeReport.canonical}');

    // 4. Print key metrics needed for human/Codex review.
    Map<String, Object?> asStringKeyedMap(Object? raw) {
      if (raw is Map) {
        return raw.map((k, v) => MapEntry(k.toString(), v));
      }
      return const <String, Object?>{};
    }

    const playthroughScenarioKey = 'PLAYTHROUGH_BOUNDED_PAUSE_RESUME_TO_EOS';
    const stopDisposeScenarioKey = 'STOP_DISPOSE_MID_PLAYBACK';

    final topMetrics = activeReport.metrics;
    final playthroughMetrics = asStringKeyedMap(
      topMetrics[playthroughScenarioKey],
    );
    final stopDisposeMetrics = asStringKeyedMap(
      topMetrics[stopDisposeScenarioKey],
    );

    Object? lookupMetric(String key) {
      return topMetrics[key] ??
          playthroughMetrics[key] ??
          stopDisposeMetrics[key];
    }

    Map<String, Object?> extractCompactScenario(
      Map<String, Object?> source,
      List<String> keys,
    ) {
      final result = <String, Object?>{};
      for (final key in keys) {
        if (source.containsKey(key)) {
          result[key] = source[key];
        }
      }
      return result;
    }

    final compactPlaythrough =
        extractCompactScenario(playthroughMetrics, const <String>[
          'sourceMime',
          'sampleRate',
          'channelCount',
          'declaredFrameCount',
          'preRollFrames',
          'pauseHoldObservedMs',
          'decoderAcceptedFrames',
          'decoderPaddedFrames',
          'decoderChecksumHex',
          'decoderExitReason',
          'decoderMediaReleaseCount',
          'audioTrackReleaseCount',
          'framesReadFromTransport',
          'framesWrittenToSink',
          'sinkChecksumHex',
          'playbackHeadFinal',
          'nativePushedFrames',
          'nativeDrainedFrames',
          'nativeDiscardedFrames',
          'nativePushedChecksumHex',
          'nativeDrainedChecksumHex',
          'clockPositionFrames',
          'stateAtCompletion',
          'scenarioWallMs',
          'failureReason',
        ]);

    final compactStopDispose =
        extractCompactScenario(stopDisposeMetrics, const <String>[
          'declaredFrameCount',
          'decoderAcceptedFrames',
          'decoderChecksumHex',
          'decoderExitReason',
          'decoderMediaReleaseCount',
          'audioTrackReleaseCount',
          'framesWrittenBeforeStop',
          'framesWrittenToSink',
          'sinkChecksumHex',
          'stopAccepted',
          'stopReason',
          'stateAfterStop',
          'stateAfterDispose',
          'stateAfterSecondDispose',
          'scenarioWallMs',
          'failureReason',
        ]);

    print('--- METRICS ---');
    print('  [METRIC] sourceMime: ${lookupMetric('sourceMime')}');
    print('  [METRIC] sampleRate: ${lookupMetric('sampleRate')}');
    print('  [METRIC] channelCount: ${lookupMetric('channelCount')}');
    print(
      '  [METRIC] declaredFrameCount: ${lookupMetric('declaredFrameCount')}',
    );
    print('  [METRIC] maxDurationSec: ${lookupMetric('maxDurationSec')}');
    print('  [METRIC] maxFramesPerMix: ${lookupMetric('maxFramesPerMix')}');
    print('  [METRIC] gain: ${lookupMetric('gain')}');
    print('  [METRIC] deadlineMs: ${lookupMetric('deadlineMs')}');
    print('  [METRIC] pauseHoldMs: ${lookupMetric('pauseHoldMs')}');
    print(
      '  [METRIC] pauseHoldObservedMs: ${lookupMetric('pauseHoldObservedMs')}',
    );
    print('  [METRIC] stopAfterMs: ${lookupMetric('stopAfterMs')}');
    print('  [METRIC] preRollFrames: ${lookupMetric('preRollFrames')}');
    print(
      '  [METRIC] decoderAcceptedFrames: ${lookupMetric('decoderAcceptedFrames')}',
    );
    print(
      '  [METRIC] decoderChecksumHex: ${lookupMetric('decoderChecksumHex')}',
    );
    print('  [METRIC] decoderExitReason: ${lookupMetric('decoderExitReason')}');
    print(
      '  [METRIC] decoderMediaReleaseCount: ${lookupMetric('decoderMediaReleaseCount')}',
    );
    print(
      '  [METRIC] audioTrackReleaseCount: ${lookupMetric('audioTrackReleaseCount')}',
    );
    print(
      '  [METRIC] framesWrittenBeforeStop: ${lookupMetric('framesWrittenBeforeStop')}',
    );
    print('  [METRIC] stopAccepted: ${lookupMetric('stopAccepted')}');
    print('  [METRIC] stateAfterStop: ${lookupMetric('stateAfterStop')}');
    print('  [METRIC] stateAfterDispose: ${lookupMetric('stateAfterDispose')}');
    print('  [METRIC] failureReason: ${activeReport.failureReason}');
    print('  [METRIC] lastError: ${activeReport.lastError}');
    print('--- SCENARIO METRICS ---');
    print('  [SCENARIO] $playthroughScenarioKey: $compactPlaythrough');
    print('  [SCENARIO] $stopDisposeScenarioKey: $compactStopDispose');

    // 5. Verification evaluation.
    final pass =
        (topLevelError == null) &&
        activeReport.pass &&
        activeReport.isVerifiedPass &&
        activeReport.hasCanonicalProofBoundary &&
        activeReport.hasPassMarker;

    final compactScenarioMetrics = <String, dynamic>{
      playthroughScenarioKey: compactPlaythrough,
      stopDisposeScenarioKey: compactStopDispose,
    };

    // 6. Print JSON marker with compact JSON payload.
    final summaryPayload = <String, dynamic>{
      'unit': 'AndroidRealtimeAudioPlaybackProductionPhysicalSmokeHarness',
      'slice': 'P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SINK-CLOCK',
      'subSlice': 'Y8a',
      'target':
          VGRealtimeAudioPlaybackProductionSmokeReport.proofBoundaryConstant,
      'selectedFixture': selectedFixturePath,
      'pass': pass,
      'status': activeReport.status,
      'failureReason': activeReport.failureReason,
      'lanes': activeReport.lanes,
      'scenarioMetrics': compactScenarioMetrics,
      'scenarios': compactScenarioMetrics,
      'metrics': <String, dynamic>{
        'sourceMime': lookupMetric('sourceMime'),
        'sampleRate': lookupMetric('sampleRate'),
        'channelCount': lookupMetric('channelCount'),
        'declaredFrameCount': lookupMetric('declaredFrameCount'),
        'maxDurationSec': lookupMetric('maxDurationSec'),
        'maxFramesPerMix': lookupMetric('maxFramesPerMix'),
        'gain': lookupMetric('gain'),
        'deadlineMs': lookupMetric('deadlineMs'),
        'pauseHoldMs': lookupMetric('pauseHoldMs'),
        'pauseHoldObservedMs': lookupMetric('pauseHoldObservedMs'),
        'stopAfterMs': lookupMetric('stopAfterMs'),
        'preRollFrames': lookupMetric('preRollFrames'),
        'decoderAcceptedFrames': lookupMetric('decoderAcceptedFrames'),
        'decoderChecksumHex': lookupMetric('decoderChecksumHex'),
        'decoderExitReason': lookupMetric('decoderExitReason'),
        'decoderMediaReleaseCount': lookupMetric('decoderMediaReleaseCount'),
        'audioTrackReleaseCount': lookupMetric('audioTrackReleaseCount'),
        'framesWrittenBeforeStop': lookupMetric('framesWrittenBeforeStop'),
        'stopAccepted': lookupMetric('stopAccepted'),
        'stateAfterStop': lookupMetric('stateAfterStop'),
        'stateAfterDispose': lookupMetric('stateAfterDispose'),
      },
      'error': topLevelError,
    };
    print(
      '${VGRealtimeAudioPlaybackProductionSmokeReport.jsonMarkerConstant}:${jsonEncode(summaryPayload)}',
    );

    // 7. Print PASS marker only when wrapper validation passes; otherwise print FAIL marker.
    if (pass) {
      print(VGRealtimeAudioPlaybackProductionSmokeReport.passMarkerConstant);
    } else {
      print(VGRealtimeAudioPlaybackProductionSmokeReport.failMarkerConstant);
    }

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (isVerifiedPass=true, allLanesPass=true)'
            : 'FAIL: lastError=${activeReport.lastError}, failureReason=${activeReport.failureReason}, error=$topLevelError';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 1000));
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
