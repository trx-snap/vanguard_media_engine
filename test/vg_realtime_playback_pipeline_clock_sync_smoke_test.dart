// vg_realtime_playback_pipeline_clock_sync_smoke_test.dart
// vanguard_media_engine - P4-AUDIO-REALTIME-PLAYBACK-CLOCK-SYNCHRONIZATION (Y7):
// Dart model and MethodChannel unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kProofBoundary =
    VGRealtimePlaybackPipelineClockSyncSmokeReport.proofBoundaryConstant;
const _kPassMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_CLOCK_SYNC_PHYSICAL_SMOKE_PASS';
const _kFailMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_CLOCK_SYNC_PHYSICAL_SMOKE_FAIL';
const _kStartMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_CLOCK_SYNC_SMOKE_START';
const _kJsonMarker =
    'ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_PIPELINE_CLOCK_SYNC_JSON';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) {
  final lanes = <String, Object?>{
    for (final k
        in VGRealtimePlaybackPipelineClockSyncSmokeReport.requiredGateKeys)
      k: true,
    'canonical': true,
  };
  final metrics = <String, Object?>{
    'maxDurationSec': 3.0,
    'maxFramesPerMix': 256,
    'baseVolume': 0.5,
    'phaseFrames': 2048,
    'extrapolationHorizonMs': 250,
    'extrapolationHorizonNs': 250000000,
    'scenarioOrder': <String>[
      'FORWARD_PLAYTHROUGH_CLOCK_SYNC',
      'DEAD_OBJECT_CLOCK_EPOCH_RESET',
    ],
    'forward_playthrough_clock_syncScenarioPass': true,
    'dead_object_clock_epoch_resetScenarioPass': true,
    'clockSelfCheck': <String, Object?>{
      'pass': true,
      'allOk': true,
      'firstFailure': '',
    },
    'timestampPollAttemptsTotal': 1120,
    'timestampPollSuccessesTotal': 0,
    'timestampPollUnavailableTotal': 1120,
    'timestampFrameRegressionTotal': 0,
    'timestampWrapTotal': 0,
    'timestampPollViolationsTotal': 0,
    'clockAnchoredTotal': 0,
    'clockExtrapolatedTotal': 1120,
    'clockStaleTotal': 0,
    'clockNoAnchorTotal': 0,
    'clockRejectedTotal': 0,
    'clockCoordinatorSnapshotsTotal': 80,
    'forward_playthrough_clock_sync': <String, Object?>{
      'scenario': 'FORWARD_PLAYTHROUGH_CLOCK_SYNC',
      'sampleRate': 48000,
      'channelCount': 2,
      'declaredFrameCount': 144000,
      'framesWrittenToSink': 144000,
      'audioTracksCreated': 1,
      'audioTracksReleased': 1,
      'clockAnchoredCount': 0,
      'clockExtrapolatedCount': 560,
      'clockStaleCount': 0,
      'clockNoAnchorCount': 0,
      'clockRejectedCount': 0,
      'clockSampleCount': 40,
      'transportStateFinal': 'DISPOSED',
      'sinkExitReason': 'eos',
    },
    'dead_object_clock_epoch_reset': <String, Object?>{
      'scenario': 'DEAD_OBJECT_CLOCK_EPOCH_RESET',
      'audioTracksCreated': 2,
      'audioTracksReleased': 2,
      'syntheticDeadObjectInjectedCount': 1,
      'deadObjectObservedCount': 1,
      'clockAnchoredCount': 0,
      'clockExtrapolatedCount': 560,
      'clockStaleCount': 0,
      'clockNoAnchorCount': 0,
      'clockRejectedCount': 0,
      'clockSampleCount': 40,
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
    'details': 'Y7 realtime playback pipeline clock sync harness pass=true',
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

  group('VGRealtimePlaybackPipelineClockSyncSmokeReport constants', () {
    test('static constants match expected native contracts', () {
      expect(
        VGRealtimePlaybackPipelineClockSyncSmokeReport.methodName,
        equals('runRealtimePlaybackPipelineClockSyncSmoke'),
      );
      expect(
        VGRealtimePlaybackPipelineClockSyncSmokeReport.passMarkerConstant,
        equals(_kPassMarker),
      );
      expect(
        VGRealtimePlaybackPipelineClockSyncSmokeReport.failMarkerConstant,
        equals(_kFailMarker),
      );
      expect(
        VGRealtimePlaybackPipelineClockSyncSmokeReport.startMarkerConstant,
        equals(_kStartMarker),
      );
      expect(
        VGRealtimePlaybackPipelineClockSyncSmokeReport.jsonMarkerConstant,
        equals(_kJsonMarker),
      );
      expect(
        VGRealtimePlaybackPipelineClockSyncSmokeReport.requiredGateKeys.length,
        equals(23),
      );
      for (final key in <String>[
        'formatProbeOk',
        'preRollOk',
        'preStartDrainEmptyOk',
        'timestampPollCadenceOk',
        'presentationClockAnchoredOk',
        'presentationClockMonotonicOk',
        'presentationClockExtrapolatedOk',
        'presentationClockStaleBoundOk',
        'presentationClockEpochResetOk',
        'snapshotProvenanceOk',
        'clockNoFeedbackOk',
        'timestampFailureNonterminalOk',
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
          VGRealtimePlaybackPipelineClockSyncSmokeReport.requiredGateKeys,
          contains(key),
        );
      }
    });

    test('proof boundary names every non-claim of the slice', () {
      const boundary =
          VGRealtimePlaybackPipelineClockSyncSmokeReport.proofBoundaryConstant;
      for (final fragment in <String>[
        'diagnostic_only',
        'sink_thread_owns_audiotrack_gettimestamp_and_presentation_clock_updates',
        'coordinator_owns_transport_commands',
        'presentation_clock_read_only_downstream_any_thread_snapshots_monotonic_published_position',
        'one_poll_per_drain_pass_after_write',
        'epoch_opens_after_playing',
        'epoch_model_audiotrack_instance_per_epoch',
        'unsigned32_unwrap_one_wrap_tolerated_regression_fails_closed',
        'continuity_by_base_offset_accumulation',
        'gettimestamp_false_nonterminal_bounded_extrapolation_stale_after_horizon',
        'no_fabricated_position',
        'synthetic_dead_object_epoch_reset_only',
        'no_seek_no_flush',
        'no_av_sync_no_drift_correction',
        'no_hal_output_latency',
        'no_gettimestamp_availability_sla',
        'no_pacing_no_write_feedback',
        'no_drain_gating_no_checksum_feedback_no_underrun_handling',
        'no_real_os_fault_forcing_no_seamless_hot_swap',
        'no_product_no_editor_no_app_wiring_no_connectsapp_no_ios_no_streaming_no_cache_no_cpp_no_jni_changes',
      ]) {
        expect(boundary, contains(fragment), reason: fragment);
      }
      expect(boundary, isNot(contains('drift_window')));
      expect(boundary, isNot(contains('route_change')));
    });
  });

  group('VGRealtimePlaybackPipelineClockSyncSmokeReport.fromMap', () {
    test('pass payload parses true with all gates and metrics', () {
      final report = VGRealtimePlaybackPipelineClockSyncSmokeReport.fromMap(
        _createSampleRawMap(),
      );
      expect(report.pass, isTrue);
      expect(report.status, equals('pass'));
      expect(report.hasPassMarker, isTrue);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.allRequiredGatesTrue, isTrue);
      expect(report.formatProbeOk, isTrue);
      expect(report.preRollOk, isTrue);
      expect(report.preStartDrainEmptyOk, isTrue);
      expect(report.timestampPollCadenceOk, isTrue);
      expect(report.presentationClockAnchoredOk, isTrue);
      expect(report.presentationClockMonotonicOk, isTrue);
      expect(report.presentationClockExtrapolatedOk, isTrue);
      expect(report.presentationClockStaleBoundOk, isTrue);
      expect(report.presentationClockEpochResetOk, isTrue);
      expect(report.snapshotProvenanceOk, isTrue);
      expect(report.clockNoFeedbackOk, isTrue);
      expect(report.timestampFailureNonterminalOk, isTrue);
      expect(report.deadObjectInjectedOnceOk, isTrue);
      expect(report.deadObjectOldTrackReleasedOk, isTrue);
      expect(report.deadObjectNewTrackInitVolumePlayOk, isTrue);
      expect(report.deadObjectRemainderResumedOk, isTrue);
      expect(report.deadObjectNoDoubleCountOk, isTrue);
      expect(report.sinkWriteAccountingOk, isTrue);
      expect(report.checksumIdentityOk, isTrue);
      expect(report.transportCompletedOk, isTrue);
      expect(report.audioTrackLifecycleOk, isTrue);
      expect(report.threadOwnershipOk, isTrue);
      expect(report.proofBoundaryOk, isTrue);
      expect(report.canonical, isTrue);
      expect(report.lastError, isEmpty);
      expect(report.metrics['scenarioOrder'], hasLength(2));
      expect(report.metrics['forward_playthrough_clock_sync'], isA<Map>());
      expect(report.metrics['dead_object_clock_epoch_reset'], isA<Map>());
    });

    test(
      'extrapolated / unavailable getTimestamp is still a verified pass',
      () {
        final raw = _createSampleRawMap();
        final metrics = Map<String, Object?>.from(raw['metrics'] as Map);
        metrics['clockAnchoredTotal'] = 0;
        metrics['clockExtrapolatedTotal'] = 1120;
        raw['metrics'] = metrics;
        final report = VGRealtimePlaybackPipelineClockSyncSmokeReport.fromMap(
          raw,
        );
        expect(report.isVerifiedPass, isTrue);
        expect(report.metrics['clockAnchoredTotal'], equals(0));
        expect(report.metrics['clockExtrapolatedTotal'], equals(1120));
      },
    );

    test('every required gate false causes isVerifiedPass to fail', () {
      for (final gateKey
          in VGRealtimePlaybackPipelineClockSyncSmokeReport.requiredGateKeys) {
        final raw = _createSampleRawMap();
        final lanes = Map<String, Object?>.from(raw['lanes'] as Map);
        lanes[gateKey] = false;
        raw['lanes'] = lanes;
        final report = VGRealtimePlaybackPipelineClockSyncSmokeReport.fromMap(
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
      lanes.remove('presentationClockMonotonicOk');
      raw['lanes'] = lanes;
      final report = VGRealtimePlaybackPipelineClockSyncSmokeReport.fromMap(
        raw,
      );
      expect(report.pass, isFalse);
      expect(report.status, equals('missing_gate'));
      expect(
        report.lastError,
        equals('missing_gate_presentationClockMonotonicOk'),
      );
    });

    test('bad proof boundary / marker / status / failureReason fail closed', () {
      final badBoundary =
          VGRealtimePlaybackPipelineClockSyncSmokeReport.fromMap(
            _createSampleRawMap({'proofBoundary': 'invalid'}),
          );
      expect(badBoundary.pass, isFalse);
      expect(badBoundary.lastError, equals('proof_boundary_mismatch'));

      final badMarker = VGRealtimePlaybackPipelineClockSyncSmokeReport.fromMap(
        _createSampleRawMap({'marker': 'INVALID_MARKER'}),
      );
      expect(badMarker.pass, isFalse);
      expect(badMarker.lastError, equals('marker_mismatch'));

      final badStatus = VGRealtimePlaybackPipelineClockSyncSmokeReport.fromMap(
        _createSampleRawMap({'status': 'fail'}),
      );
      expect(badStatus.pass, isFalse);
      expect(badStatus.marker, equals(_kFailMarker));

      final withReason = VGRealtimePlaybackPipelineClockSyncSmokeReport.fromMap(
        _createSampleRawMap({
          'failureReason':
              'forward_playthrough_clock_sync:presentation_clock_regression:100->90',
        }),
      );
      expect(withReason.pass, isFalse);
      expect(
        withReason.lastError,
        equals(
          'forward_playthrough_clock_sync:presentation_clock_regression:100->90',
        ),
      );
    });

    test('non-map payload produces fail-shaped report', () {
      final report = VGRealtimePlaybackPipelineClockSyncSmokeReport.fromMap(
        null,
      );
      expect(report.pass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(report.failureReason, equals('native_result_not_a_map'));
      expect(report.presentationClockMonotonicOk, isFalse);
      final asString = VGRealtimePlaybackPipelineClockSyncSmokeReport.fromMap(
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
              in VGRealtimePlaybackPipelineClockSyncSmokeReport
                  .requiredGateKeys)
            k: 'true',
          'canonical': 'true',
        },
        'metrics': <String, Object?>{
          'phaseFrames': 2048,
          'extrapolationHorizonMs': 250,
        },
      };
      final report = VGRealtimePlaybackPipelineClockSyncSmokeReport.fromMap(
        raw,
      );
      expect(report.isVerifiedPass, isTrue);
      expect(report.metrics['phaseFrames'], equals(2048));
      expect(report.metrics['extrapolationHorizonMs'], equals(250));
      final map = report.toMap();
      expect(map['lanes'], isA<Map>());
      expect(report.toJson(), equals(map));
      expect(
        report.toString(),
        contains('VGRealtimePlaybackPipelineClockSyncSmokeReport'),
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
          if (call.method == 'runRealtimePlaybackPipelineClockSyncSmoke') {
            return _createSampleRawMap();
          }
          return null;
        });

        final report =
            await VGRealtimePlaybackPipelineClockSyncSmokeReport.runRealtimePlaybackPipelineClockSyncSmoke(
              sourcePath: '/tmp/test_clip.mov',
              maxDurationSec: 3.0,
              maxFramesPerMix: 512,
              baseVolume: 0.5,
              deadlineMs: 45000,
              phaseFrames: 2048,
              extrapolationHorizonMs: 250,
            );

        expect(
          invokedMethod,
          equals('runRealtimePlaybackPipelineClockSyncSmoke'),
        );
        expect(invokedArguments?['sourcePath'], equals('/tmp/test_clip.mov'));
        expect(invokedArguments?['maxDurationSec'], equals(3.0));
        expect(invokedArguments?['maxFramesPerMix'], equals(512));
        expect(invokedArguments?['baseVolume'], equals(0.5));
        expect(invokedArguments?['deadlineMs'], equals(45000));
        expect(invokedArguments?['phaseFrames'], equals(2048));
        expect(invokedArguments?['extrapolationHorizonMs'], equals(250));
        // Y7 carries no pause hold, seek or duck parameters.
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
          code: 'P4_REALTIME_PLAYBACK_PIPELINE_CLOCK_SYNC_SMOKE_BUSY',
          message: 'Diagnostic already running',
        );
      });
      final report =
          await VGRealtimePlaybackPipelineClockSyncSmokeReport.runRealtimePlaybackPipelineClockSyncSmoke(
            sourcePath: '/tmp/test_clip.mov',
          );
      expect(report.pass, isFalse);
      expect(report.marker, equals(_kFailMarker));
      expect(
        report.failureReason,
        equals(
          'platform_exception:P4_REALTIME_PLAYBACK_PIPELINE_CLOCK_SYNC_SMOKE_BUSY',
        ),
      );
    });

    test('TimeoutException produces fallback report', () async {
      const customChannel = MethodChannel(
        'vanguard_media_engine_pipeline_clock_sync_timeout_test',
      );
      binaryMessenger.setMockMethodCallHandler(customChannel, (
        MethodCall call,
      ) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _createSampleRawMap();
      });
      final report =
          await VGRealtimePlaybackPipelineClockSyncSmokeReport.runRealtimePlaybackPipelineClockSyncSmoke(
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
