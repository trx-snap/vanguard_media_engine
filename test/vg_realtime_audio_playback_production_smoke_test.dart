// vg_realtime_audio_playback_production_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SINK-CLOCK (Y8a): Android True-DAG Phase 4
// realtime audio playback production sink and clock diagnostic smoke foundation
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'production_engine_component_diagnostic_route_real_mediaextractor_mediacodec_to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_sink_thread_owned_audiotrack_and_presentation_clock_bounded_pause_resume_closes_reopens_clock_epoch_at_last_published_position_stop_dispose_release_once_no_seek_no_dead_object_recovery_no_product_no_editor_no_app_no_connectsapp_no_ios_no_streaming_no_cache_no_cpp_no_jni';

const _kPassMarker =
    'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_PHYSICAL_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_PHYSICAL_SMOKE_FAIL';
const _kStartMarker =
    'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_SMOKE_START';
const _kJsonMarker =
    'ANDROID_DAG_PHASE4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_JSON';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    'formatProbeOk': true,
    'preRollOk': true,
    'startOk': true,
    'nonZeroGainAudioTrackOk': true,
    'playthroughAccountingOk': true,
    'checksumIdentityOk': true,
    'clockAnchoredOk': true,
    'clockMonotonicOk': true,
    'clockEpochBalancedOk': true,
    'clockPauseFrozenOk': true,
    'boundedPauseResumeOk': true,
    'stopDisposeOk': true,
    'decoderCancelledOnStopOk': true,
    'transportDisposedOk': true,
    'audioTrackReleasedOnceOk': true,
    'threadOwnershipOk': true,
    'noFeedbackOk': true,
    'proofBoundaryOk': true,
    'canonical': true,
  };

  final metrics = <String, Object?>{
    'sourceMime': 'audio/mp4a-latm',
    'sampleRate': 48000,
    'channelCount': 2,
    'declaredFrameCount': 144000,
    'maxDurationSec': 3.0,
    'maxFramesPerMix': 256,
    'gain': 0.5,
    'deadlineMs': 30000,
    'pauseHoldMs': 400,
    'maxPauseHoldMs': 3000,
    'stopAfterMs': 300,
    'coordinatorThreadId': 100,
    'preRollFrames': 4096,
    'pauseHoldObservedMs': 402,
    'decoderAcceptedFrames': 144000,
    'decoderChecksumHex': '0000000012345678',
    'decoderExitReason': 'eos',
    'decoderMediaReleaseCount': 1,
    'decoderMediaReleaseClean': true,
    'audioTrackReleaseCount': 1,
    'audioTrackReleaseClean': true,
    'framesWrittenBeforeStop': 14400,
    'stopAccepted': true,
    'stopReason': 'user_stop',
    'stateAfterStop': 'STOPPED',
    'stateAfterDispose': 'DISPOSED',
    'stateAfterSecondDispose': 'DISPOSED',
    'failureReason': '',
    'lastError': 'none',
  };

  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kCanonicalProofBoundary,
    'nativeProofBoundary': _kCanonicalProofBoundary,
    'failureReason': '',
    'details':
        'Y8a realtime audio playback production sink/clock smoke pass=true scenarios=PLAYTHROUGH_BOUNDED_PAUSE_RESUME_TO_EOS,STOP_DISPOSE_MID_PLAYBACK',
    'lanes': lanes,
    'metrics': metrics,
    'lastError': null,
    'raw': 'pass=true;status=pass;marker=$_kPassMarker',
  };

  if (overrides != null) {
    for (final entry in overrides.entries) {
      if (lanes.containsKey(entry.key)) {
        lanes[entry.key] = entry.value;
      }
      if (metrics.containsKey(entry.key)) {
        metrics[entry.key] = entry.value;
      }
      result[entry.key] = entry.value;
    }
  }

  return result;
}

VGRealtimeAudioPlaybackProductionSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGRealtimeAudioPlaybackProductionSmokeReport.fromMap(
  _createSampleRawMap(overrides),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGRealtimeAudioPlaybackProductionSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGRealtimeAudioPlaybackProductionSmokeReport.methodName,
        equals('runRealtimeAudioPlaybackProductionSmoke'),
      );
      expect(
        VGRealtimeAudioPlaybackProductionSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGRealtimeAudioPlaybackProductionSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGRealtimeAudioPlaybackProductionSmokeReport.startMarkerConstant,
        equals(_kStartMarker),
      );
      expect(
        VGRealtimeAudioPlaybackProductionSmokeReport.jsonMarkerConstant,
        equals(_kJsonMarker),
      );
      expect(
        VGRealtimeAudioPlaybackProductionSmokeReport.proofBoundaryConstant,
        equals(_kCanonicalProofBoundary),
      );
      expect(
        VGRealtimeAudioPlaybackProductionSmokeReport
            .requiredNonCanonicalLanes
            .length,
        equals(18),
      );
      expect(
        VGRealtimeAudioPlaybackProductionSmokeReport.requiredLanes.length,
        equals(19),
      );

      final expectedLanes = <String>[
        'formatProbeOk',
        'preRollOk',
        'startOk',
        'nonZeroGainAudioTrackOk',
        'playthroughAccountingOk',
        'checksumIdentityOk',
        'clockAnchoredOk',
        'clockMonotonicOk',
        'clockEpochBalancedOk',
        'clockPauseFrozenOk',
        'boundedPauseResumeOk',
        'stopDisposeOk',
        'decoderCancelledOnStopOk',
        'transportDisposedOk',
        'audioTrackReleasedOnceOk',
        'threadOwnershipOk',
        'noFeedbackOk',
        'proofBoundaryOk',
        'canonical',
      ];

      for (final lane in expectedLanes) {
        expect(
          VGRealtimeAudioPlaybackProductionSmokeReport.requiredLanes,
          contains(lane),
        );
      }
    });
  });

  group('VGRealtimeAudioPlaybackProductionSmokeReport.fromMap parsing', () {
    test('pass payload parses true with all lanes and metrics', () {
      final report = _createSampleReport();

      expect(report.pass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.status, equals('pass'));
      expect(report.marker, equals(_kPassMarker));
      expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
      expect(report.nativeProofBoundary, equals(_kCanonicalProofBoundary));
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);

      expect(report.formatProbeOk, isTrue);
      expect(report.preRollOk, isTrue);
      expect(report.startOk, isTrue);
      expect(report.nonZeroGainAudioTrackOk, isTrue);
      expect(report.playthroughAccountingOk, isTrue);
      expect(report.checksumIdentityOk, isTrue);
      expect(report.clockAnchoredOk, isTrue);
      expect(report.clockMonotonicOk, isTrue);
      expect(report.clockEpochBalancedOk, isTrue);
      expect(report.clockPauseFrozenOk, isTrue);
      expect(report.boundedPauseResumeOk, isTrue);
      expect(report.stopDisposeOk, isTrue);
      expect(report.decoderCancelledOnStopOk, isTrue);
      expect(report.transportDisposedOk, isTrue);
      expect(report.audioTrackReleasedOnceOk, isTrue);
      expect(report.threadOwnershipOk, isTrue);
      expect(report.noFeedbackOk, isTrue);
      expect(report.proofBoundaryOk, isTrue);
      expect(report.canonical, isTrue);
      expect(report.allRequiredNonCanonicalLanesPass, isTrue);

      expect(report.metrics['sampleRate'], equals(48000));
      expect(report.metrics['gain'], equals(0.5));
    });

    test('missing required lane fails validation', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes.remove('clockAnchoredOk');
      raw['lanes'] = lanes;

      final report = VGRealtimeAudioPlaybackProductionSmokeReport.fromMap(raw);
      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('missing_lane'));
      expect(report.lastError, equals('missing_lane_clockAnchoredOk'));
    });

    test('failing lane fails validation', () {
      final report = _createSampleReport(<String, Object?>{
        'clockMonotonicOk': false,
      });

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('lane_failed'));
      expect(report.lastError, equals('lane_failed'));
    });

    test('failing canonical lane fails validation', () {
      final report = _createSampleReport(<String, Object?>{'canonical': false});

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('canonical_failed'));
      expect(report.lastError, equals('canonical_failed'));
    });

    test('proof boundary mismatch fails validation', () {
      final report = _createSampleReport(<String, Object?>{
        'proofBoundary': 'corrupted_boundary',
      });

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasCanonicalProofBoundary, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.status, equals('proof_boundary_mismatch'));
      expect(report.lastError, equals('proof_boundary_mismatch'));
    });

    test('marker mismatch fails validation', () {
      final report = _createSampleReport(<String, Object?>{
        'marker': 'UNEXPECTED_PASS_MARKER',
      });

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.hasPassMarker, isFalse);
      expect(report.status, equals('marker_mismatch'));
      expect(report.lastError, equals('marker_mismatch'));
    });

    test('non-map input returns fallback failure report', () {
      final report = VGRealtimeAudioPlaybackProductionSmokeReport.fromMap(
        'not_a_map',
      );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('native_result_not_a_map'));
    });

    test('explicit failure payload parses with error reason', () {
      final report = _createSampleReport(<String, Object?>{
        'pass': false,
        'status': 'fail',
        'marker': _kFailMarker,
        'failureReason': 'source_path_required',
      });

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('source_path_required'));
      expect(report.lastError, equals('source_path_required'));
    });

    test('nested lane and metric maps are preserved with serialization', () {
      final sample = _createSampleRawMap();
      final report = VGRealtimeAudioPlaybackProductionSmokeReport.fromMap(
        sample,
      );

      expect(report.metrics['sourceMime'], equals('audio/mp4a-latm'));
      expect(report.lanes['audioTrackReleasedOnceOk'], isTrue);

      final map = report.toMap();
      expect(map['lanes'], isA<Map>());
      expect(map['metrics'], isA<Map>());
      expect(report.toJson(), equals(map));
    });

    test('toString produces diagnostic representation', () {
      final report = _createSampleReport();
      expect(
        report.toString(),
        contains('VGRealtimeAudioPlaybackProductionSmokeReport'),
      );
      expect(report.toString(), contains('clockAnchoredOk: true'));
      expect(report.toString(), contains('isVerifiedPass: true'));
    });
  });

  group('VGRealtimeAudioPlaybackProductionSmokeReport MethodChannel invocation', () {
    test(
      'method route invoked with parameters and returns pass report',
      () async {
        String? invokedMethod;
        Map<Object?, Object?>? invokedArguments;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (
          MethodCall call,
        ) async {
          invokedMethod = call.method;
          invokedArguments = call.arguments as Map<Object?, Object?>?;
          if (call.method == 'runRealtimeAudioPlaybackProductionSmoke') {
            return _createSampleRawMap();
          }
          return null;
        });

        final report =
            await VGRealtimeAudioPlaybackProductionSmokeReport.runRealtimeAudioPlaybackProductionSmoke(
              sourcePath: '/tmp/test_clip.mov',
              maxDurationSec: 3.0,
              maxFramesPerMix: 256,
              gain: 0.5,
              deadlineMs: 30000,
              pauseHoldMs: 400,
              maxPauseHoldMs: 3000,
              stopAfterMs: 300,
            );

        expect(
          invokedMethod,
          equals('runRealtimeAudioPlaybackProductionSmoke'),
        );
        expect(invokedArguments?['sourcePath'], equals('/tmp/test_clip.mov'));
        expect(invokedArguments?['maxDurationSec'], equals(3.0));
        expect(invokedArguments?['maxFramesPerMix'], equals(256));
        expect(invokedArguments?['gain'], equals(0.5));
        expect(invokedArguments?['deadlineMs'], equals(30000));
        expect(invokedArguments?['pauseHoldMs'], equals(400));
        expect(invokedArguments?['maxPauseHoldMs'], equals(3000));
        expect(invokedArguments?['stopAfterMs'], equals(300));
        expect(report.pass, isTrue);
        expect(report.isVerifiedPass, isTrue);
        expect(report.hasPassMarker, isTrue);
      },
    );

    test(
      'PlatformException produces failed report instead of uncaught exception',
      () async {
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (
          MethodCall call,
        ) async {
          if (call.method == 'runRealtimeAudioPlaybackProductionSmoke') {
            throw PlatformException(
              code: 'P4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_SMOKE_BUSY',
              message:
                  'runRealtimeAudioPlaybackProductionSmoke: diagnostic already running',
            );
          }
          return null;
        });

        final report =
            await VGRealtimeAudioPlaybackProductionSmokeReport.runRealtimeAudioPlaybackProductionSmoke(
              sourcePath: '/tmp/test_clip.mov',
            );

        expect(report.pass, isFalse);
        expect(report.isVerifiedPass, isFalse);
        expect(report.marker, equals(_kFailMarker));
        expect(
          report.failureReason,
          equals(
            'platform_exception:P4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_SMOKE_BUSY',
          ),
        );
        expect(
          report.lastError,
          contains('P4_REALTIME_AUDIO_PLAYBACK_PRODUCTION_SMOKE_BUSY'),
        );
      },
    );

    test('TimeoutException produces fallback error report', () async {
      final customChannel = const MethodChannel(
        'vanguard_media_engine_production_smoke_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });

      final report =
          await VGRealtimeAudioPlaybackProductionSmokeReport.runRealtimeAudioPlaybackProductionSmoke(
            sourcePath: '/tmp/test_clip.mov',
            timeout: const Duration(milliseconds: 10),
            channel: customChannel,
          );

      expect(report.pass, isFalse);
      expect(report.isVerifiedPass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('timeout'));
      expect(report.lastError, contains('timeout:'));
    });
  });
}
