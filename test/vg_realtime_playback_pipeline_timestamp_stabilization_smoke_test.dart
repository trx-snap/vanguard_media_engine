// vg_realtime_playback_pipeline_timestamp_stabilization_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-TIMESTAMP-STABILIZATION (Y6f):
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kProofBoundary =
    VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
        .proofBoundaryConstant;
const _kPassMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_TIMESTAMP_STABILIZATION_PHYSICAL_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_TIMESTAMP_STABILIZATION_PHYSICAL_SMOKE_FAIL';
const _kStartMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_TIMESTAMP_STABILIZATION_SMOKE_START';
const _kJsonMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_TIMESTAMP_STABILIZATION_JSON';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    for (final k
        in VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
            .requiredGateKeys)
      k: true,
    'canonical': true,
  };
  final metrics = <String, Object?>{
    'maxDurationSec': 3.0,
    'maxFramesPerMix': 256,
    'baseVolume': 0.5,
    'phaseFrames': 2048,
    'scenarioOrder': <String>[
      'FORWARD_PLAYTHROUGH_TIMESTAMP',
      'DEAD_OBJECT_EPOCH_RESET_TIMESTAMP',
    ],
    'forward_playthrough_timestampScenarioPass': true,
    'dead_object_epoch_reset_timestampScenarioPass': true,
    'timestampPollAttemptsTotal': 1120,
    'timestampPollSuccessesTotal': 0,
    'timestampPollUnavailableTotal': 1120,
    'timestampFrameRegressionTotal': 0,
    'timestampWrapTotal': 0,
    'timestampPollViolationsTotal': 0,
    'forward_playthrough_timestamp': <String, Object?>{
      'scenario': 'FORWARD_PLAYTHROUGH_TIMESTAMP',
      'sampleRate': 48000,
      'channelCount': 2,
      'declaredFrameCount': 144000,
      'framesWrittenToSink': 144000,
      'audioTracksCreated': 1,
      'audioTracksReleased': 1,
      'timestampEpochOpenCount': 1,
      'timestampEpochBaselineResetCount': 0,
      'timestampPollAttempts': 560,
      'timestampPollSuccesses': 0,
      'timestampMaxPollsInOnePass': 1,
      'transportStateFinal': 'DISPOSED',
      'sinkExitReason': 'eos',
    },
    'dead_object_epoch_reset_timestamp': <String, Object?>{
      'scenario': 'DEAD_OBJECT_EPOCH_RESET_TIMESTAMP',
      'audioTracksCreated': 2,
      'audioTracksReleased': 2,
      'syntheticDeadObjectInjectedCount': 1,
      'deadObjectObservedCount': 1,
      'timestampEpochOpenCount': 2,
      'timestampEpochBaselineResetCount': 1,
      'timestampCrossEpochComparisonCount': 0,
      'sinkExitReason': 'eos',
    },
    'failureReason': '',
  };
  final result = <String, Object?>{
    'pass': true,
    'status': 'pass',
    'marker': _kPassMarker,
    'proofBoundary': _kProofBoundary,
    'nativeProofBoundary': _kProofBoundary,
    'failureReason': '',
    'details':
        'Y6f realtime playback pipeline timestamp stabilization harness pass=true',
    'lanes': lanes,
    'metrics': metrics,
    'lastError': null,
    'raw': 'pass=true;status=pass;marker=$_kPassMarker',
  };
  if (overrides != null) {
    for (final entry in overrides.entries) {
      if (lanes.containsKey(entry.key)) lanes[entry.key] = entry.value;
      if (metrics.containsKey(entry.key)) metrics[entry.key] = entry.value;
      result[entry.key] = entry.value;
    }
  }
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group(
    'VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport constants',
    () {
      test('static constants match expected native contracts', () {
        expect(
          VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
              .methodName,
          equals('runRealtimePlaybackPipelineTimestampStabilizationSmoke'),
        );
        expect(
          VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
              .passMarkerConstant,
          equals(_kPassMarker),
        );
        expect(
          VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
              .failMarkerConstant,
          equals(_kFailMarker),
        );
        expect(
          VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
              .startMarkerConstant,
          equals(_kStartMarker),
        );
        expect(
          VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
              .jsonMarkerConstant,
          equals(_kJsonMarker),
        );
        expect(
          VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
              .requiredGateKeys
              .length,
          equals(24),
        );
        for (final key in <String>[
          'formatProbeOk',
          'preRollOk',
          'preStartDrainEmptyOk',
          'timestampPollCadenceOk',
          'timestampPollAfterWriteOnlyOk',
          'timestampNoPollWhileParkedOk',
          'timestampWarmupGatedOnPlayingOk',
          'timestampPollAccountingOk',
          'epochFramePositionMonotonicOk',
          'epochBaselineResetOk',
          'noCrossEpochComparisonOk',
          'playbackHeadMonotonicPerEpochOk',
          'timestampInertNoFeedbackOk',
          'deadObjectInjectedOnceOk',
          'deadObjectOldTrackReleasedOk',
          'deadObjectNewTrackInitVolumePlayOk',
          'deadObjectRemainderResumedOk',
          'deadObjectNoDoubleCountOk',
          'sinkWriteAccountingOk',
          'checksumIdentityOk',
          'transportCompletedOk',
          'audioTrackLifecycleOk',
          'threadOwnershipOk',
          'proofBoundaryOk',
        ]) {
          expect(
            VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
                .requiredGateKeys,
            contains(key),
          );
        }
      });

      test('proof boundary names every non-claim of the slice', () {
        const boundary =
            VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
                .proofBoundaryConstant;
        for (final fragment in <String>[
          'diagnostic_only',
          'sink_thread_owns_audiotrack_and_gettimestamp',
          'one_poll_per_drain_pass_after_write',
          'epoch_opens_after_playing',
          'per_epoch_unsigned32_frame_position_nondecreasing_one_wrap_tolerated',
          'no_cross_epoch_comparison',
          'synthetic_dead_object_epoch_reset_only',
          'gettimestamp_false_never_fails',
          'timestamp_inert_telemetry',
          'no_hal_output_latency',
          'no_presentation_clock',
          'no_av_sync',
          'no_timestamp_derived_position',
          'no_seek_accuracy',
          'no_clock_ownership',
          'no_gettimestamp_availability_sla',
          'no_drift_correction',
          'no_latency_no_glitch_no_loudness_no_snr',
          'no_real_os_fault_forcing',
          'no_seamless_hot_swap',
          'no_product_no_editor_no_app_wiring_no_connectsapp',
          'no_ios',
          'no_streaming_no_cache',
          'no_cpp_no_jni_changes',
        ]) {
          expect(boundary, contains(fragment), reason: fragment);
        }
        expect(boundary, isNot(contains('drift_window')));
        expect(boundary, isNot(contains('route_change')));
      });
    },
  );

  group('VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.fromMap', () {
    test('pass payload parses true with all gates and metrics', () {
      final report =
          VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.fromMap(
            _createSampleRawMap(),
          );
      expect(report.pass, isTrue);
      expect(report.status, equals('pass'));
      expect(report.hasPassMarker, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.allRequiredGatesTrue, isTrue);
      expect(report.timestampPollCadenceOk, isTrue);
      expect(report.timestampPollAfterWriteOnlyOk, isTrue);
      expect(report.timestampNoPollWhileParkedOk, isTrue);
      expect(report.timestampWarmupGatedOnPlayingOk, isTrue);
      expect(report.timestampPollAccountingOk, isTrue);
      expect(report.epochFramePositionMonotonicOk, isTrue);
      expect(report.epochBaselineResetOk, isTrue);
      expect(report.noCrossEpochComparisonOk, isTrue);
      expect(report.playbackHeadMonotonicPerEpochOk, isTrue);
      expect(report.timestampInertNoFeedbackOk, isTrue);
      expect(report.deadObjectInjectedOnceOk, isTrue);
      expect(report.deadObjectNewTrackInitVolumePlayOk, isTrue);
      expect(report.deadObjectNoDoubleCountOk, isTrue);
      expect(report.transportCompletedOk, isTrue);
      expect(report.canonical, isTrue);
      expect(report.lastError, isEmpty);
      expect(report.metrics['scenarioOrder'], hasLength(2));
      expect(report.metrics['forward_playthrough_timestamp'], isA<Map>());
      expect(report.metrics['dead_object_epoch_reset_timestamp'], isA<Map>());
    });

    test(
      'zero getTimestamp successes is still a verified pass (success floor zero)',
      () {
        final raw = _createSampleRawMap();
        final metrics = Map<String, Object?>.from(raw['metrics'] as Map);
        metrics['timestampPollSuccessesTotal'] = 0;
        metrics['timestampPollUnavailableTotal'] =
            metrics['timestampPollAttemptsTotal'];
        raw['metrics'] = metrics;
        final report =
            VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.fromMap(
              raw,
            );
        expect(report.isVerifiedPass, isTrue);
        expect(report.metrics['timestampPollSuccessesTotal'], equals(0));
      },
    );

    test('every required gate false causes isVerifiedPass to fail', () {
      for (final gateKey
          in VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
              .requiredGateKeys) {
        final raw = _createSampleRawMap();
        final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
        lanes[gateKey] = false;
        raw['lanes'] = lanes;
        final report =
            VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.fromMap(
              raw,
            );
        expect(report.isVerifiedPass, isFalse, reason: gateKey);
        expect(report.pass, isFalse, reason: gateKey);
        expect(report.marker, equals(_kFailMarker));
        expect(report.lastError, equals('gate_failed'));
      }
    });

    test('missing required gate fails closed', () {
      final raw = _createSampleRawMap();
      final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
      lanes.remove('epochFramePositionMonotonicOk');
      raw['lanes'] = lanes;
      final report =
          VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.fromMap(
            raw,
          );
      expect(report.pass, isFalse);
      expect(report.status, equals('missing_gate'));
      expect(
        report.lastError,
        equals('missing_gate_epochFramePositionMonotonicOk'),
      );
    });

    test('bad proof boundary / marker / status / failureReason fail closed', () {
      final badBoundary =
          VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.fromMap(
            _createSampleRawMap({'proofBoundary': 'invalid'}),
          );
      expect(badBoundary.pass, isFalse);
      expect(badBoundary.lastError, equals('proof_boundary_mismatch'));

      final badMarker =
          VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.fromMap(
            _createSampleRawMap({'marker': 'INVALID_MARKER'}),
          );
      expect(badMarker.pass, isFalse);
      expect(badMarker.lastError, equals('marker_mismatch'));

      final badStatus =
          VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.fromMap(
            _createSampleRawMap({'status': 'fail'}),
          );
      expect(badStatus.pass, isFalse);
      expect(badStatus.marker, equals(_kFailMarker));

      final withReason =
          VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.fromMap(
            _createSampleRawMap({
              'failureReason':
                  'dead_object_epoch_reset_timestamp:timestamp_frame_regression:epoch1:100->90',
            }),
          );
      expect(withReason.pass, isFalse);
      expect(
        withReason.lastError,
        equals(
          'dead_object_epoch_reset_timestamp:timestamp_frame_regression:epoch1:100->90',
        ),
      );
    });

    test('non-map payload produces fail-shaped report', () {
      final report =
          VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.fromMap(
            null,
          );
      expect(report.pass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('native_result_not_a_map'));
      expect(report.epochFramePositionMonotonicOk, isFalse);
      final asString =
          VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.fromMap(
            'x',
          );
      expect(asString.isVerifiedPass, isFalse);
    });

    test('string-encoded booleans and round trip', () {
      final raw = <String, Object?>{
        'pass': 'true',
        'status': 'PASS',
        'marker': _kPassMarker,
        'proofBoundary': _kProofBoundary,
        'failureReason': '',
        'lanes': <String, Object?>{
          for (final k
              in VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport
                  .requiredGateKeys)
            k: 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{'phaseFrames': 2048},
      };
      final report =
          VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.fromMap(
            raw,
          );
      expect(report.isVerifiedPass, isTrue);
      expect(report.metrics['phaseFrames'], equals(2048));
      final map = report.toMap();
      expect(map['lanes'], isA<Map>());
      expect(report.toJson(), equals(map));
      expect(
        report.toString(),
        contains('VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport'),
      );
    });
  });

  group('MethodChannel invocation', () {
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
          if (call.method ==
              'runRealtimePlaybackPipelineTimestampStabilizationSmoke') {
            return _createSampleRawMap();
          }
          return null;
        });

        final report =
            await VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.runRealtimePlaybackPipelineTimestampStabilizationSmoke(
              sourcePath: '/tmp/test_clip.mov',
              maxDurationSec: 3.0,
              maxFramesPerMix: 512,
              baseVolume: 0.5,
              deadlineMs: 45000,
              phaseFrames: 2048,
            );

        expect(
          invokedMethod,
          equals('runRealtimePlaybackPipelineTimestampStabilizationSmoke'),
        );
        expect(invokedArguments?['sourcePath'], equals('/tmp/test_clip.mov'));
        expect(invokedArguments?['maxFramesPerMix'], equals(512));
        expect(invokedArguments?['baseVolume'], equals(0.5));
        expect(invokedArguments?['deadlineMs'], equals(45000));
        expect(invokedArguments?['phaseFrames'], equals(2048));
        // Y6f carries no pause hold, seek or duck parameters.
        expect(invokedArguments?.containsKey('pauseHoldMs'), isFalse);
        expect(invokedArguments?.containsKey('seekTargetFrame'), isFalse);
        expect(invokedArguments?.containsKey('duckVolume'), isFalse);
        expect(report.isVerifiedPass, isTrue);
      },
    );

    test('PlatformException produces fallback report', () async {
      binaryMessenger.setMockMethodCallHandler(defaultChannel, (
        MethodCall call,
      ) async {
        throw PlatformException(
          code:
              'P4_REALTIME_PLAYBACK_PIPELINE_TIMESTAMP_STABILIZATION_SMOKE_BUSY',
          message: 'Diagnostic already running',
        );
      });
      final report =
          await VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.runRealtimePlaybackPipelineTimestampStabilizationSmoke(
            sourcePath: '/tmp/test_clip.mov',
          );
      expect(report.pass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_REALTIME_PLAYBACK_PIPELINE_TIMESTAMP_STABILIZATION_SMOKE_BUSY',
        ),
      );
    });

    test('TimeoutException produces fallback report', () async {
      const customChannel = MethodChannel(
        'vanguard_media_engine_pipeline_timestamp_stabilization_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });
      final report =
          await VGRealtimePlaybackPipelineTimestampStabilizationSmokeReport.runRealtimePlaybackPipelineTimestampStabilizationSmoke(
            sourcePath: '/tmp/test_clip.mov',
            timeout: const Duration(milliseconds: 10),
            channel: customChannel,
          );
      expect(report.pass, isFalse);
      expect(report.failureReason, equals('timeout'));
      expect(report.lastError, contains('timeout:'));
    });
  });
}
